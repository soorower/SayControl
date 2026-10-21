// Voxtral Mini 4B Realtime, samples in → text out.
//
// CrispASR's voxtral4b.h exposes the model a step at a time — mel, encoder,
// token embedding, one LLM forward — and keeps the loop that strings them
// together in its CLI (examples/cli/crispasr_backend_voxtral4b.cpp). This is
// that loop's greedy path, trimmed to what the app calls, behind the same
// shape of API as cohere_transcribe: one malloc'd UTF-8 string, or NULL.
//
// The model is a streaming one, and even run over a finished clip it decodes
// like one: every generated position gets the next audio frame ADDED to its
// embedding, one frame per step, 12.5 frames a second. It is not told what to
// write so much as walked through the audio, emitting control tokens (ids
// below 1000) where there is nothing to say yet.
#include "voxtral4b.h"
#include "core/greedy_decode.h"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

extern "C" char* sayctrl_voxtral4b_transcribe(voxtral4b_context* ctx, const float* samples, int n_samples) {
    if (!ctx || !samples || n_samples <= 0)
        return nullptr;

    // One adapter frame = hop 160 × conv stride 2 × stack 4 = 1280 samples.
    // The reference pads 32 frames of silence in front and 10 behind, plus
    // whatever right-aligns the clip to a whole frame.
    constexpr int SAMPLES_PER_TOKEN = 1280;
    constexpr int N_LEFT_PAD_TOKENS = 32;
    constexpr int N_RIGHT_PAD_TOKENS = 10;
    const int left_pad = N_LEFT_PAD_TOKENS * SAMPLES_PER_TOKEN;
    const int right_align = (SAMPLES_PER_TOKEN - (n_samples % SAMPLES_PER_TOKEN)) % SAMPLES_PER_TOKEN;
    const int right_pad = right_align + N_RIGHT_PAD_TOKENS * SAMPLES_PER_TOKEN;
    std::vector<float> padded(left_pad + (size_t)n_samples + right_pad, 0.0f);
    std::memcpy(padded.data() + left_pad, samples, (size_t)n_samples * sizeof(float));

    int n_mels = 0, T_mel = 0;
    float* mel = voxtral4b_compute_mel(ctx, padded.data(), (int)padded.size(), &n_mels, &T_mel);
    if (!mel)
        return nullptr;
    int N_enc = 0, pdim = 0;
    float* audio = voxtral4b_run_encoder(ctx, mel, n_mels, T_mel, &N_enc, &pdim);
    std::free(mel);
    if (!audio)
        return nullptr;

    // Prompt: BOS + STREAMING_PAD × (32 + 6). The 6 is the model's default
    // 480 ms delay — how far behind the audio its words run.
    constexpr int BOS = 1, STREAMING_PAD = 32, EOS = 2;
    const int T_prompt = 1 + 32 + 6;
    std::vector<int32_t> ids(T_prompt, STREAMING_PAD);
    ids[0] = BOS;
    float* prompt = voxtral4b_embed_tokens(ctx, ids.data(), T_prompt);
    if (!prompt) {
        std::free(audio);
        return nullptr;
    }
    for (int i = 0; i < std::min(N_enc, T_prompt); i++)
        for (int j = 0; j < pdim; j++)
            prompt[(size_t)i * pdim + j] += audio[(size_t)i * pdim + j];

    // One decode step per audio frame, so the cache has to hold the whole
    // clip: the CLI's fixed 4096 (5½ minutes) is its floor, not a ceiling.
    const int steps = N_enc + 64;
    if (!voxtral4b_kv_init(ctx, std::max(4096, T_prompt + steps))) {
        std::free(prompt);
        std::free(audio);
        return nullptr;
    }
    voxtral4b_kv_reset(ctx);

    int n_t = 0, vocab = 0;
    float* logits = voxtral4b_run_llm_kv(ctx, prompt, T_prompt, 0, &n_t, &vocab);
    std::free(prompt);
    if (!logits) {
        std::free(audio);
        return nullptr;
    }
    const int first = core_greedy_decode::argmax(logits, vocab);
    const float first_p = core_greedy_decode::softmax_of(logits, vocab, first, logits[first]);
    std::free(logits);

    core_greedy_decode::Config cfg;
    cfg.max_new_tokens = steps;
    cfg.eos_id = EOS;
    cfg.vocab_size = vocab;

    // Before each forward, add the next audio frame; out of frames, stop.
    int adapter_pos = T_prompt;
    auto feed_audio = [&](int, float* tail) -> bool {
        if (adapter_pos >= N_enc)
            return false;
        for (int j = 0; j < pdim; j++)
            tail[j] += audio[(size_t)adapter_pos * pdim + j];
        adapter_pos++;
        return true;
    };
    auto dec = core_greedy_decode::run_with_probs(ctx, first, first_p, T_prompt, voxtral4b_embed_tokens,
                                                  voxtral4b_run_llm_kv, feed_audio, cfg);
    std::free(audio);

    std::string text;
    for (int32_t id : dec.tokens) {
        if (id == EOS)
            break;
        if (id < 1000)
            continue; // STREAMING_PAD, STREAMING_WORD and the other controls
        int len = 0;
        const uint8_t* bytes = voxtral4b_token_text(ctx, id, &len);
        if (bytes && len > 0)
            text.append((const char*)bytes, (size_t)len);
    }
    const size_t a = text.find_first_not_of(" \t\n");
    const size_t b = text.find_last_not_of(" \t\n");
    text = (a == std::string::npos) ? std::string() : text.substr(a, b - a + 1);

    char* out = (char*)std::malloc(text.size() + 1);
    if (out)
        std::memcpy(out, text.c_str(), text.size() + 1);
    return out;
}
