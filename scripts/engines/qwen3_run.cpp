// Qwen3-ASR 1.7B, samples in → text out.
//
// CrispASR's qwen3_asr_transcribe() is still a stub that returns "" — its
// working pipeline lives in the CLI (examples/cli/crispasr_backend_qwen3.cpp).
// This is that pipeline's greedy path, trimmed to what the app calls: mel →
// audio encoder → ChatML prompt with the audio spliced in → greedy decode
// over the KV cache → one malloc'd UTF-8 string, or NULL.
//
// Two things go into the prompt that the CLI leaves empty:
//   context   the system turn. Qwen3-ASR reads it as background, and a list
//             of the user's names there is how it learns to spell them —
//             measured on 279 real dictations (2026-10-01), names heard right
//             went from 41% to 67%. Undocumented for the open model; the app
//             guards its one failure (reading the list back out on a near-silent
//             clip) on the Swift side.
//   language  forced, as Qwen's own API does it: the answer is started with
//             "language English<asr_text>". Left to detect, it answered
//             "language None" (nothing) on short clips once given a context,
//             and wrote an English command in Devanagari without one.
//
// And one thing the CLI does not do: check a draft. Live dictation re-reads
// the whole take every pass, and each pass's text is nearly the next one's.
// Given that text as `draft`, its tokens go through the model in one batch
// and the longest run the model would have written itself is kept; decoding
// goes on one token at a time from the first disagreement, and the draft is
// picked up again where the last tokens written are found in it. Only tokens
// the model itself picks are ever kept, so the text is the one plain greedy
// decoding writes (94 of 95 bench takes identical; the one difference was
// float rounding between batched and single-token math), at a fraction of
// the calls: key-up on 15 s+ takes went from 1.99 s to 0.60 s median on an
// M-series Mac (2026-10-02, bench-experiments/SUMMARY-draft-verify.md).
//
// sayctrl_qwen3_abort() stops a decode between tokens — a live pass still
// running when the key comes up, which the final pass would otherwise wait
// behind. The aborted call returns "".
#include "qwen3_asr.h"
#include "core/bpe.h"

#include <atomic>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

// The patched runtime's batch call with a logits row per position
// (scripts/engines/qwen3_all_logits.patch).
extern "C" float* qwen3_asr_run_llm_kv_all(qwen3_asr_context* ctx, const float* inputs_embeds, int n_tokens,
                                           int n_past, int* out_n_tokens, int* out_vocab_size);

// One resident Qwen3 at a time takes live passes, so one flag will do.
static std::atomic<bool> g_abort{false};

extern "C" void sayctrl_qwen3_abort(void) { g_abort = true; }

static int argmax(const float* v, int n) {
    int best = 0;
    for (int i = 1; i < n; i++)
        if (v[i] > v[best])
            best = i;
    return best;
}

static int single_token(qwen3_asr_context* ctx, const char* text) {
    int n = 0;
    int32_t* ids = qwen3_asr_tokenize(ctx, text, &n);
    int id = (ids && n >= 1) ? ids[0] : -1;
    std::free(ids);
    return id;
}

// Where the draft goes on after what has been written. `hint` is the draft
// index the model was expected to write next. The last 3, 2 or 1 tokens
// written are looked for close to it (a few tokens either side: the model
// added, dropped or changed a word), nearest first; a match further away is
// usually a different comma or "the", which loses the place for the rest of
// the take. Nothing near: the draft resumes where it was.
static int draft_continuation(const std::vector<int32_t>& out, const std::vector<int32_t>& draft, int hint) {
    const int n = (int)draft.size();
    for (int m = 3; m >= 1; m--) {
        if ((int)out.size() < m)
            continue;
        // A last token that is draft[hint] ends at hint + 1: search out from there.
        for (int d = 0; d <= 6; d++) {
            for (int end : {hint + 1 + d, hint + 1 - d}) {   // `end` = index after the match
                int i = end - m;
                if (i < 0 || end > n)
                    continue;
                bool same = true;
                for (int j = 0; j < m && same; j++)
                    same = draft[i + j] == out[out.size() - m + j];
                if (same)
                    return end;
            }
        }
    }
    return hint < n ? hint : -1;
}

extern "C" char* sayctrl_qwen3_transcribe(qwen3_asr_context* ctx, const float* samples, int n_samples,
                                          const char* context, const char* language, const char* draft) {
    if (!ctx || !samples || n_samples <= 0)
        return nullptr;
    g_abort = false;

    int n_mels = 0, T_mel = 0;
    float* mel = qwen3_asr_compute_mel(ctx, samples, n_samples, &n_mels, &T_mel);
    if (!mel)
        return nullptr;
    int N_enc = 0, dim = 0;
    float* audio = qwen3_asr_run_encoder(ctx, mel, n_mels, T_mel, &N_enc, &dim);
    std::free(mel);
    if (!audio)
        return nullptr;

    std::string prompt = std::string("<|im_start|>system\n") + (context ? context : "") +
                         "<|im_end|>\n<|im_start|>user\n<|audio_start|>";
    prompt.reserve(prompt.size() + (size_t)N_enc * 13 + 64);
    for (int i = 0; i < N_enc; i++)
        prompt += "<|audio_pad|>";
    prompt += "<|audio_end|><|im_end|>\n<|im_start|>assistant\n";
    if (language && *language)
        prompt += std::string("language ") + language + "<asr_text>";

    int n_ids = 0;
    int32_t* raw = qwen3_asr_tokenize(ctx, prompt.c_str(), &n_ids);
    const int pad = single_token(ctx, "<|audio_pad|>");
    const int eos = single_token(ctx, "<|im_end|>");
    if (!raw || pad < 0) {
        std::free(raw);
        std::free(audio);
        return nullptr;
    }
    std::vector<int32_t> ids(raw, raw + n_ids);
    std::free(raw);

    // Each <|audio_pad|> embedding is replaced by one encoder frame.
    float* embeds = qwen3_asr_embed_tokens(ctx, ids.data(), (int)ids.size());
    if (!embeds) {
        std::free(audio);
        return nullptr;
    }
    int spliced = 0;
    for (size_t i = 0; i < ids.size() && spliced < N_enc; i++)
        if (ids[i] == pad)
            std::memcpy(embeds + i * dim, audio + (size_t)spliced++ * dim, dim * sizeof(float));
    std::free(audio);

    const int prompt_len = (int)ids.size();
    const int max_new = 512;   // the reference implementation's default
    const int max_batch = 48;  // draft tokens checked per call
    const int kv_need = prompt_len + max_new + max_batch + 16;
    if (!qwen3_asr_kv_init(ctx, kv_need > 4096 ? kv_need : 4096)) {
        std::free(embeds);
        return nullptr;
    }
    qwen3_asr_kv_reset(ctx);

    if (g_abort) {   // the encoder ran; the prefill need not
        std::free(embeds);
        return strdup("");
    }

    std::vector<int32_t> guess;
    if (draft && *draft) {
        int n = 0;
        int32_t* d = qwen3_asr_tokenize(ctx, draft, &n);
        if (d)
            guess.assign(d, d + n);
        std::free(d);
    }

    int n_t = 0, vocab = 0;
    float* logits = qwen3_asr_run_llm_kv(ctx, embeds, prompt_len, 0, &n_t, &vocab);
    std::free(embeds);
    if (!logits)
        return nullptr;
    int next = argmax(logits + (size_t)(n_t - 1) * vocab, vocab);
    std::free(logits);

    std::vector<int32_t> out;
    int n_past = prompt_len;
    int hint = 0;
    while (next != eos && (int)out.size() < max_new) {
        if (g_abort)
            return strdup("");
        out.push_back(next);
        // The token just picked, plus what the draft says comes after it.
        std::vector<int32_t> batch = {next};
        int at = guess.empty() ? -1 : draft_continuation(out, guess, hint);
        if (at >= 0)
            for (int i = at; i < (int)guess.size() && (int)batch.size() <= max_batch; i++)
                batch.push_back(guess[i]);
        float* e = qwen3_asr_embed_tokens(ctx, batch.data(), (int)batch.size());
        if (!e)
            break;
        int nt = 0, v = 0;
        float* lg = batch.size() > 1 ? qwen3_asr_run_llm_kv_all(ctx, e, (int)batch.size(), n_past, &nt, &v)
                                     : qwen3_asr_run_llm_kv(ctx, e, 1, n_past, &nt, &v);
        std::free(e);
        if (!lg)
            break;
        // Row k is the model's pick after batch[k]: keep draft tokens while it agrees.
        int k = 0;
        int pick = argmax(lg, v);
        while (k + 1 < (int)batch.size() && pick == batch[k + 1] && pick != eos && (int)out.size() < max_new) {
            k += 1;
            out.push_back(batch[k]);
            pick = argmax(lg + (size_t)k * v, v);
        }
        std::free(lg);
        if (at >= 0)
            hint = at + k;
        n_past += 1 + k;
        next = pick;
    }

    // Drop special tokens and <tags>, and — when the language was left to the
    // model — the "language <Name>" prefix it writes first.
    std::string text;
    bool language_next = false;
    for (int32_t id : out) {
        const char* piece = qwen3_asr_token_text(ctx, id);
        if (!piece || !*piece)
            continue;
        std::string p = piece;
        if (p.size() >= 2 && p[0] == '<' && (p[1] == '|' || p.back() == '>'))
            continue;
        std::string t = core_bpe::token_bytes_to_utf8(p);
        if (text.empty() && t == "language") {
            language_next = true;
            continue;
        }
        if (language_next) {
            language_next = false;
            continue;
        }
        text += t;
    }
    size_t start = text.find_first_not_of(' ');
    return strdup(start == std::string::npos ? "" : text.c_str() + start);
}
