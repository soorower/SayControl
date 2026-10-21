// Nemotron 3.5, samples in as they arrive → text out as it settles.
//
// Nemotron is a cache-aware streaming model: every encoder frame sees its own
// 4-frame chunk and up to 56 frames of left context, never the future past
// its chunk. CrispASR runs it over a finished clip (nemotron_transcribe) and
// has the chunked encoder with per-layer caches, but no way to feed audio a
// piece at a time. This is that: the clip's own pipeline, run on just the new
// audio each time.
//
//   samples → log-mel (only the frames whose window is complete)
//           → causal pre-encode, 8× down (only the frames no padding touches)
//           → conformer, one 4-frame chunk at a time, caches kept per layer
//           → language prompt kernel → greedy RNN-T, predictor state kept
//
// Every stage is causal, so a frame computed now never changes later and the
// finished stream matches the batch path. Key-up (`finish`) runs the tail the
// batch path would: the last mel frames over the zero pad and a short last
// chunk, then a final decode — a few chunks of work, not the whole clip.
//
// The file includes nemotron.cpp itself rather than linking against it: the
// pieces it reuses (the pre-encode and block builders, the predictor and
// joint steps) are file-static there, and this keeps CrispASR's source
// untouched. CMakeLists compiles this file in nemotron.cpp's place.
#include "nemotron.cpp"

namespace {

// How many pre-encode frames of left context the windowed pre-encode re-runs
// in front of the new ones. Its causal convs zero-pad the window's start, and
// that padding reaches two frames in (three stride-2 stages, kernel 3); the
// third is margin.
constexpr int kPreEncodeMargin = 3;

// The three causal stride-2 stages of the pre-encode, as frame counts. `full`
// counts what the graph emits for M mel frames (the last outputs reach into
// the right pad); `settled` counts only the outputs that see real frames on
// both sides, which is all a frame needs to never change again.
int pre_encode_frames(int M, bool full) {
    int n = M;
    for (int stage = 0; stage < 3; stage++)
        n = full ? n / 2 + 1 : (n - 1) / 2 + 1;
    return n;
}

} // namespace

struct sayctrl_nemotron_stream {
    nemotron_context* ctx = nullptr;

    std::vector<float> pcm; // every sample fed, 16 kHz mono
    bool finished = false;

    // Mel inputs, read off the model once.
    std::vector<float> mel_window, mel_fb;

    // Pre-encode frames handed on so far, and the ones still short of a chunk.
    int pre_done = 0;
    std::vector<float> pending; // (d_model, n_pending), frame-major
    int n_pending = 0;

    // The language prompt kernel, as CPU floats (it runs per frame).
    std::vector<float> pk_l0_w, pk_l0_b, pk_l2_w, pk_l2_b;
    std::vector<float> lang_onehot;

    // Greedy RNN-T: the predictor's state and its last output carry across
    // calls, so decoding a chunk is exactly decoding the next frames of the clip.
    nemotron_lstm_state state;
    std::vector<float> pred_out;
    std::vector<nemotron_emitted_token> emitted;
    int enc_frames = 0;

    // One graph's metadata, reused for every graph this stream builds.
    std::vector<uint8_t> meta;
};

namespace {

// Log-mel frames [t0, t1) of the clip so far: a slice of the pre-emphasised
// signal, zero beyond either end — the same numbers the batch path computes
// over the whole clip, without recomputing the frames already used.
bool stream_mel(sayctrl_nemotron_stream* s, int t0, int t1, std::vector<float>& out) {
    const auto& hp = s->ctx->model.hparams;
    const int n_fft = (int)hp.n_fft, hop = (int)hp.hop_length, win = (int)hp.win_length;
    const int n_freqs = n_fft / 2 + 1;
    const int n = (int)s->pcm.size();
    const int T = t1 - t0;
    if (T <= 0)
        return false;

    const int len = (T - 1) * hop + n_fft;
    const int start = t0 * hop - n_fft / 2; // frame t0's window, in clip samples
    std::vector<float> slice((size_t)len, 0.0f);
    for (int i = 0; i < len; i++) {
        const int j = start + i;
        if (j < 0 || j >= n)
            continue;
        // y[0] = x[0], y[j] = x[j] − 0.97·x[j−1]: NeMo's pre-emphasis, done
        // here so the slice's first sample still sees the one before it.
        slice[(size_t)i] = j == 0 ? s->pcm[0] : s->pcm[(size_t)j] - 0.97f * s->pcm[(size_t)j - 1];
    }

    core_mel::Params p;
    p.n_fft = n_fft;
    p.hop_length = hop;
    p.win_length = win;
    p.n_mels = (int)hp.n_mels;
    p.log_base = core_mel::LogBase::Ln;
    p.norm = core_mel::Normalization::None;
    p.layout = core_mel::Layout::TimeMels;
    p.log_eps = (float)(1.0 / (1 << 24));
    p.center_pad = false; // the slice already carries the pad
    p.drop_last_frame = false;
    p.preemph = 0.0f; // already applied

    int T_out = 0;
    out = core_mel::compute(slice.data(), len, s->mel_window.data(), win, s->mel_fb.data(), n_freqs,
                            nemotron_fft_r2c, p, T_out);
    return T_out == T && !out.empty();
}

// Runs the causal pre-encode over mel frames [8·js, M) and appends its outputs
// from `pre_done` up to `upto` to the pending frames.
bool stream_pre_encode(sayctrl_nemotron_stream* s, int M, int upto) {
    nemotron_context* ctx = s->ctx;
    const auto& hp = ctx->model.hparams;
    const int js = std::max(0, s->pre_done - kPreEncodeMargin);
    const int ms = js * 8;
    std::vector<float> mel;
    if (!stream_mel(s, ms, M, mel))
        return false;
    const int T_mel = M - ms;

    ggml_init_params ip = {s->meta.size(), s->meta.data(), true};
    ggml_context* ctx0 = ggml_init(ip);
    ggml_cgraph* gf = ggml_new_graph_custom(ctx0, 1024, false);
    ggml_tensor* mel_t = ggml_new_tensor_2d(ctx0, GGML_TYPE_F32, (int)hp.n_mels, T_mel);
    ggml_set_name(mel_t, "mel");
    ggml_set_input(mel_t);
    int T_pre = 0;
    ggml_tensor* pre = nemotron_build_pre_encode(ctx0, mel_t, ctx->model.pre_encode, (int)hp.subsampling_channels, &T_pre);
    ggml_set_name(pre, "pre_enc");
    ggml_set_output(pre);
    ggml_build_forward_expand(gf, pre);

    bool ok = nemotron_ensure_sched(ctx);
    if (ok) {
        ggml_backend_sched_reset(ctx->sched);
        ok = ggml_backend_sched_alloc_graph(ctx->sched, gf);
    }
    if (ok) {
        ggml_backend_tensor_set(ggml_graph_get_tensor(gf, "mel"), mel.data(), 0, mel.size() * sizeof(float));
        ok = ggml_backend_sched_graph_compute(ctx->sched, gf) == GGML_STATUS_SUCCESS;
    }
    if (ok) {
        ggml_tensor* out = ggml_graph_get_tensor(gf, "pre_enc");
        const int d = (int)out->ne[0];
        const int T_out = (int)out->ne[1];
        const int from = s->pre_done - js, to = std::min(upto - js, T_out);
        if (to > from) {
            std::vector<float> all((size_t)T_out * d);
            ggml_backend_tensor_get(out, all.data(), 0, all.size() * sizeof(float));
            s->pending.insert(s->pending.end(), all.begin() + (size_t)from * d, all.begin() + (size_t)to * d);
            s->n_pending += to - from;
            s->pre_done = js + to;
        }
    }
    ggml_free(ctx0);
    return ok;
}

// One chunk of `n_new` pre-encode frames through all the conformer layers, in
// one graph: each layer reads its cache of the last L post-FFN1 frames and
// the K−1 frames before its depthwise conv, and hands back the new ones.
bool stream_encode_chunk(sayctrl_nemotron_stream* s, int n_new, std::vector<float>& out) {
    nemotron_context* ctx = s->ctx;
    const auto& hp = ctx->model.hparams;
    const int n_layers = (int)hp.n_layers;
    const int d = (int)hp.d_model;
    const int K = (int)hp.conv_kernel;
    const int L = hp.att_context_left[ctx->att_context_preset];
    // Every layer's cache grows in step, so one window size fits them all.
    const int n_ctx = std::min(ctx->enc_cache[0].n_cached, L);
    const bool has_conv = ctx->enc_cache[0].conv_cached > 0;

    core_conformer::BlockParams bp = {};
    bp.d = d;
    bp.n_heads = (int)hp.n_heads;
    bp.head_dim = (int)hp.head_dim;
    bp.K = K;
    bp.ln_eps = kLayerNormEps;

    ggml_init_params ip = {s->meta.size(), s->meta.data(), true};
    ggml_context* ctx0 = ggml_init(ip);
    ggml_cgraph* gf = ggml_new_graph_custom(ctx0, 8192, false);

    ggml_tensor* cur = ggml_new_tensor_2d(ctx0, GGML_TYPE_F32, d, n_new);
    ggml_set_name(cur, "chunk_in");
    ggml_set_input(cur);
    ggml_tensor* pos = ggml_new_tensor_2d(ctx0, GGML_TYPE_F32, d, 2 * (n_ctx + n_new) - 1);
    ggml_set_name(pos, "pos_enc");
    ggml_set_input(pos);

    char name[48];
    for (int il = 0; il < n_layers; il++) {
        ggml_tensor* cache = nullptr;
        if (n_ctx > 0) {
            cache = ggml_new_tensor_2d(ctx0, GGML_TYPE_F32, d, n_ctx);
            snprintf(name, sizeof(name), "cache_in_%d", il);
            ggml_set_name(cache, name);
            ggml_set_input(cache);
        }
        ggml_tensor* conv = nullptr;
        if (has_conv) {
            conv = ggml_new_tensor_2d(ctx0, GGML_TYPE_F32, d, K - 1);
            snprintf(name, sizeof(name), "conv_in_%d", il);
            ggml_set_name(conv, name);
            ggml_set_input(conv);
        }
        cur = nemotron_build_block_streaming(ctx0, cur, cache, conv, pos, n_new, n_ctx, ctx->model.enc[il], bp);
        // The builder names its cache outputs the same in every layer; give
        // this layer's their own names before the next layer adds more.
        for (ggml_tensor* t = ggml_get_first_tensor(ctx0); t; t = ggml_get_next_tensor(ctx0, t)) {
            if (strcmp(t->name, "cache_ch_out") == 0) {
                snprintf(name, sizeof(name), "cache_out_%d", il);
                ggml_set_name(t, name);
                ggml_build_forward_expand(gf, t);
            } else if (strcmp(t->name, "conv_cache_out") == 0) {
                snprintf(name, sizeof(name), "conv_out_%d", il);
                ggml_set_name(t, name);
                ggml_build_forward_expand(gf, t);
            }
        }
    }
    ggml_set_name(cur, "chunk_out");
    ggml_set_output(cur);
    ggml_build_forward_expand(gf, cur);

    ggml_backend_sched_reset(ctx->sched);
    bool ok = ggml_backend_sched_alloc_graph(ctx->sched, gf);
    if (ok) {
        ggml_backend_tensor_set(ggml_graph_get_tensor(gf, "chunk_in"), s->pending.data(), 0,
                                (size_t)n_new * d * sizeof(float));
        const auto pe = core_conformer::make_pos_enc(d, n_ctx + n_new);
        ggml_backend_tensor_set(ggml_graph_get_tensor(gf, "pos_enc"), pe.data(), 0, pe.size() * sizeof(float));
        for (int il = 0; il < n_layers; il++) {
            auto& c = ctx->enc_cache[il];
            if (n_ctx > 0) {
                snprintf(name, sizeof(name), "cache_in_%d", il);
                ggml_backend_tensor_set(ggml_graph_get_tensor(gf, name), c.k_cache.data() + (size_t)(c.n_cached - n_ctx) * d,
                                        0, (size_t)n_ctx * d * sizeof(float));
            }
            if (has_conv) {
                snprintf(name, sizeof(name), "conv_in_%d", il);
                ggml_backend_tensor_set(ggml_graph_get_tensor(gf, name), c.conv_cache.data(), 0,
                                        (size_t)(K - 1) * d * sizeof(float));
            }
        }
        ok = ggml_backend_sched_graph_compute(ctx->sched, gf) == GGML_STATUS_SUCCESS;
    }
    if (ok) {
        out.resize((size_t)n_new * d);
        ggml_backend_tensor_get(ggml_graph_get_tensor(gf, "chunk_out"), out.data(), 0, out.size() * sizeof(float));
        // The caches, exactly as nemotron_run_encoder_chunked keeps them.
        std::vector<float> fresh((size_t)n_new * d);
        for (int il = 0; il < n_layers; il++) {
            auto& c = ctx->enc_cache[il];
            snprintf(name, sizeof(name), "cache_out_%d", il);
            ggml_backend_tensor_get(ggml_graph_get_tensor(gf, name), fresh.data(), 0, fresh.size() * sizeof(float));
            c.k_cache.insert(c.k_cache.end(), fresh.begin(), fresh.end());
            c.n_cached += n_new;
            if (c.n_cached > L) {
                const int excess = c.n_cached - L;
                std::memmove(c.k_cache.data(), c.k_cache.data() + (size_t)excess * d, (size_t)L * d * sizeof(float));
                c.k_cache.resize((size_t)L * d);
                c.n_cached = L;
            }
            snprintf(name, sizeof(name), "conv_out_%d", il);
            ggml_tensor* co = ggml_graph_get_tensor(gf, name);
            const int frames = (int)co->ne[1];
            if (frames == K - 1) {
                ggml_backend_tensor_get(co, c.conv_cache.data(), 0, (size_t)(K - 1) * d * sizeof(float));
            } else {
                // A chunk shorter than the conv's reach (4 frames against 8)
                // hands back only its own frames: slide the window along and
                // put them at its end. nemotron_run_encoder_chunked zeroes the
                // older half instead, which drifts from the third chunk on.
                std::memmove(c.conv_cache.data(), c.conv_cache.data() + (size_t)frames * d,
                             (size_t)(K - 1 - frames) * d * sizeof(float));
                ggml_backend_tensor_get(co, c.conv_cache.data() + (size_t)(K - 1 - frames) * d, 0,
                                        (size_t)frames * d * sizeof(float));
            }
            c.conv_cached = K - 1;
        }
    }
    ggml_free(ctx0);
    return ok;
}

// The language prompt kernel over freshly encoded frames, in place — the
// same per-frame MLP nemotron_transcribe applies to the whole clip.
void stream_prompt(sayctrl_nemotron_stream* s, std::vector<float>& enc, int n) {
    if (s->pk_l0_w.empty())
        return;
    const auto& hp = s->ctx->model.hparams;
    const int d = (int)hp.d_model;
    const int n_prompts = (int)hp.num_prompts;
    const int pk_in = d + n_prompts;
    const int pk_mid = (int)hp.prompt_kernel_mid;
    std::vector<float> cat((size_t)pk_in), mid((size_t)pk_mid);
    std::memcpy(cat.data() + d, s->lang_onehot.data(), (size_t)n_prompts * sizeof(float));
    for (int t = 0; t < n; t++) {
        float* frame = enc.data() + (size_t)t * d;
        std::memcpy(cat.data(), frame, (size_t)d * sizeof(float));
        for (int i = 0; i < pk_mid; i++) {
            float acc = s->pk_l0_b[(size_t)i];
            const float* row = s->pk_l0_w.data() + (size_t)i * pk_in;
            for (int k = 0; k < pk_in; k++)
                acc += row[k] * cat[(size_t)k];
            mid[(size_t)i] = acc > 0.0f ? acc : 0.0f;
        }
        for (int i = 0; i < d; i++) {
            float acc = s->pk_l2_b[(size_t)i];
            const float* row = s->pk_l2_w.data() + (size_t)i * pk_mid;
            for (int k = 0; k < pk_mid; k++)
                acc += row[k] * mid[(size_t)k];
            frame[i] = acc;
        }
    }
}

// Greedy RNN-T over the new frames, picking up where the last call stopped —
// nemotron_rnnt_decode's loop with its state kept on the stream.
void stream_decode(sayctrl_nemotron_stream* s, const std::vector<float>& enc, int n) {
    nemotron_context* ctx = s->ctx;
    const auto& W = ctx->pred_w;
    const auto& J = ctx->joint_w;
    const int d = (int)ctx->model.hparams.d_model;
    const int blank_id = (int)ctx->model.hparams.blank_id;
    const int max_symbols_per_frame = 10;
    std::vector<float> proj_e, logits;
    for (int t = 0; t < n; t++) {
        joint_proj_enc(J, enc.data() + (size_t)t * d, proj_e);
        for (int sym = 0; sym < max_symbols_per_frame; sym++) {
            joint_step(J, proj_e.data(), s->pred_out.data(), logits);
            int tok = 0;
            for (int v = 1; v < J.vocab_total; v++)
                if (logits[(size_t)v] > logits[(size_t)tok])
                    tok = v;
            if (tok == blank_id)
                break;
            float maxl = logits[(size_t)tok], sum = 0.0f;
            for (float l : logits)
                sum += expf(l - maxl);
            nemotron_emitted_token et;
            et.id = tok;
            et.t_start = s->enc_frames + t;
            et.t_end = s->enc_frames + t + 1;
            et.p = 1.0f / sum;
            s->emitted.push_back(et);
            predictor_step(W, tok, s->state, s->pred_out);
        }
    }
    s->enc_frames += n;
}

// Pushes everything that has settled through the pipeline; with `final`,
// everything there is.
bool stream_advance(sayctrl_nemotron_stream* s, bool final) {
    const auto& hp = s->ctx->model.hparams;
    const int hop = (int)hp.hop_length;
    const int n = (int)s->pcm.size();
    // Mel frame t's window ends n_fft/2 past t·hop; until the audio reaches
    // there, the frame would be computed over zeros that are really speech.
    const int M = final ? n / hop + 1 : (n >= (int)hp.n_fft / 2 ? (n - (int)hp.n_fft / 2) / hop + 1 : 0);
    if (M <= 0)
        return true;
    const int upto = pre_encode_frames(M, final);
    if (upto > s->pre_done && !stream_pre_encode(s, M, upto))
        return false;

    const int chunk = hp.att_context_right[s->ctx->att_context_preset] + 1;
    const int d = (int)hp.d_model;
    std::vector<float> enc;
    while (s->n_pending >= chunk || (final && s->n_pending > 0)) {
        const int n_new = std::min(chunk, s->n_pending);
        if (!stream_encode_chunk(s, n_new, enc))
            return false;
        s->pending.erase(s->pending.begin(), s->pending.begin() + (size_t)n_new * d);
        s->n_pending -= n_new;
        stream_prompt(s, enc, n_new);
        stream_decode(s, enc, n_new);
    }
    return true;
}

} // namespace

extern "C" sayctrl_nemotron_stream* sayctrl_nemotron_stream_open(nemotron_context* ctx) {
    if (!ctx || !ctx->model.mel_fb || !ctx->model.mel_window || !nemotron_ensure_sched(ctx))
        return nullptr;
    auto* s = new sayctrl_nemotron_stream();
    s->ctx = ctx;
    const auto& hp = ctx->model.hparams;
    const int n_freqs = (int)hp.n_fft / 2 + 1;
    s->mel_window.resize(hp.win_length);
    ggml_backend_tensor_get(ctx->model.mel_window, s->mel_window.data(), 0, s->mel_window.size() * sizeof(float));
    s->mel_fb.resize((size_t)hp.n_mels * n_freqs);
    ggml_backend_tensor_get(ctx->model.mel_fb, s->mel_fb.data(), 0, s->mel_fb.size() * sizeof(float));
    s->meta.resize(ggml_tensor_overhead() * 8192 + ggml_graph_overhead_custom(8192, false));

    // Fresh encoder caches: one stream at a time per context, like any decode.
    const int d = (int)hp.d_model, K = (int)hp.conv_kernel;
    ctx->enc_cache.assign(hp.n_layers, {});
    for (auto& c : ctx->enc_cache)
        c.conv_cache.assign((size_t)(K - 1) * d, 0.0f);

    if (ctx->model.prompt_kernel.l0_w) {
        const auto& pk = ctx->model.prompt_kernel;
        s->pk_l0_w = tensor_to_f32(pk.l0_w);
        s->pk_l0_b = tensor_to_f32(pk.l0_b);
        s->pk_l2_w = tensor_to_f32(pk.l2_w);
        s->pk_l2_b = tensor_to_f32(pk.l2_b);
        s->lang_onehot.assign(hp.num_prompts, 0.0f);
        if (ctx->prompt_id >= 0 && ctx->prompt_id < (int)hp.num_prompts)
            s->lang_onehot[(size_t)ctx->prompt_id] = 1.0f;
    }

    nemotron_init_pred_weights(ctx);
    nemotron_init_joint_weights(ctx);
    s->state.init(ctx->pred_w.H);
    predictor_step(ctx->pred_w, (int)hp.blank_id, s->state, s->pred_out);
    return s;
}

extern "C" int sayctrl_nemotron_stream_feed(sayctrl_nemotron_stream* s, const float* samples, int n_samples) {
    if (!s || s->finished || !samples || n_samples < 0)
        return -1;
    s->pcm.insert(s->pcm.end(), samples, samples + n_samples);
    return stream_advance(s, false) ? 0 : -2;
}

extern "C" int sayctrl_nemotron_stream_finish(sayctrl_nemotron_stream* s) {
    if (!s)
        return -1;
    if (s->finished)
        return 0;
    s->finished = true;
    return stream_advance(s, true) ? 0 : -2;
}

extern "C" char* sayctrl_nemotron_stream_text(sayctrl_nemotron_stream* s) {
    if (!s)
        return nullptr;
    const std::string text = nemotron_detokenize(s->ctx->vocab, s->emitted);
    return strdup(text.c_str());
}

extern "C" double sayctrl_nemotron_stream_seconds_done(sayctrl_nemotron_stream* s) {
    if (!s)
        return 0;
    return (double)s->enc_frames * s->ctx->model.hparams.frame_dur_cs / 100.0;
}

extern "C" void sayctrl_nemotron_stream_close(sayctrl_nemotron_stream* s) {
    delete s;
}

