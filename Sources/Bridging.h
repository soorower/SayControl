// Everything Swift needs from the speech engines. All three C APIs are small
// and stable, so this is the entire bridge — no wrapper layer in between.
// Parakeet ships in whisper.cpp's repository and links as its own library
// alongside whisper; Cohere Transcribe, Voxtral Realtime, Nemotron and
// Qwen3-ASR come from CrispASR, compiled against the same ggml
// (scripts/engines/CMakeLists.txt).
#pragma once
#include "whisper.h"
#include "parakeet.h"
#include "cohere.h"
#include "voxtral4b.h"
#include "nemotron.h"
#include "qwen3_asr.h"

/// scripts/engines/voxtral4b_run.cpp: voxtral4b.h stops at single model steps,
/// so the decode loop that joins them is the app's own. malloc'd, or NULL.
char *sayctrl_voxtral4b_transcribe(struct voxtral4b_context *ctx, const float *samples, int n_samples);

/// scripts/engines/qwen3_run.cpp: qwen3_asr_transcribe() is a stub, so the
/// decode loop is the app's own. `context` goes in the system turn (the
/// user's names), `language` is forced ("English"), `draft` is the last live
/// pass's text, checked in batches rather than rewritten; any may be NULL.
/// malloc'd, or NULL.
char *sayctrl_qwen3_transcribe(struct qwen3_asr_context *ctx, const float *samples, int n_samples,
                               const char *context, const char *language, const char *draft);
/// Stops the Qwen3 decode in flight between tokens; that call returns "".
void sayctrl_qwen3_abort(void);

/// scripts/engines/nemotron_stream.cpp: Nemotron fed as the audio arrives.
/// Open one per take on a loaded context (one at a time), feed 16 kHz mono as
/// it comes, read the text whenever; `finish` runs the tail at key-up. The
/// text is malloc'd. Feed and finish return 0, or <0 on failure.
struct sayctrl_nemotron_stream;
struct sayctrl_nemotron_stream *sayctrl_nemotron_stream_open(struct nemotron_context *ctx);
int sayctrl_nemotron_stream_feed(struct sayctrl_nemotron_stream *s, const float *samples, int n_samples);
int sayctrl_nemotron_stream_finish(struct sayctrl_nemotron_stream *s);
char *sayctrl_nemotron_stream_text(struct sayctrl_nemotron_stream *s);
/// How much of the audio fed has been decoded, in seconds.
double sayctrl_nemotron_stream_seconds_done(struct sayctrl_nemotron_stream *s);
void sayctrl_nemotron_stream_close(struct sayctrl_nemotron_stream *s);
