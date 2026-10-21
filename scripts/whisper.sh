#!/bin/bash
# Fetches the local speech engines at pinned revisions and builds them as
# static libraries for both Mac architectures. Sourced by build.sh; safe to
# run on its own.
#
# Three engines, two repositories, one ggml:
#   whisper.cpp  Whisper and Parakeet — upstream, at a release tag.
#   CrispASR     Cohere Transcribe, Voxtral Realtime, Nemotron 3.5 and
#                Qwen3-ASR — a whisper.cpp fork with runtimes for model shapes
#                whisper.cpp has no graph for. Only those four backends are compiled
#                (scripts/engines/CMakeLists.txt), and against whisper.cpp's
#                ggml, so the binary carries one ggml.
#                Pinned to a commit, not a tag: the repo moves daily and a
#                float would rebuild differently every week.
#
# Two separate builds rather than one universal pass: Apple Silicon gets Metal,
# Intel does not (ggml's Metal backend is arm64-only), so the two slices have
# genuinely different backends and only the final executable is lipo'd.
set -euo pipefail
cd "$(dirname "$0")/.."

WHISPER_TAG="v1.9.3"
CRISPASR_COMMIT="80c71bd5f24717d1554ba29e7f76959b5a0aef5d"   # v0.8.29, 2026-08-23
SRC="vendor/whisper.cpp"
CRISP="vendor/crispasr"
OUT="vendor/lib"

if [ ! -d "$SRC" ]; then
  echo "Fetching whisper.cpp ${WHISPER_TAG}…"
  # Shallow, single tag — a few MB, not the whole history.
  git clone --depth 1 --branch "$WHISPER_TAG" \
    https://github.com/ggml-org/whisper.cpp.git "$SRC"
fi

if [ ! -f "$CRISP/src/cohere.cpp" ]; then
  echo "Fetching CrispASR ${CRISPASR_COMMIT:0:7}…"
  # A commit can't be cloned by name, but it can be fetched by hash, still at
  # depth 1. Its ggml submodule is left alone on purpose — see the header.
  rm -rf "$CRISP"
  git init -q "$CRISP"
  git -C "$CRISP" remote add origin https://github.com/CrispStrobe/CrispASR.git
  git -C "$CRISP" fetch -q --depth 1 origin "$CRISPASR_COMMIT"
  git -C "$CRISP" checkout -q FETCH_HEAD
fi

# Two patches on top of the pinned commit, each applied once (a checkout that
# already has one is left alone):
#   qwen3_all_logits      Qwen3-ASR's LLM call can return a logits row for
#                         every position of a batch, which checking a draft of
#                         the transcript in one call needs (qwen3_run.cpp).
#   voxtral4b_stream_long Voxtral's streaming mode kept going past 15 s of
#                         audio and 41 s of decoding — it stopped at both.
for PATCH in scripts/engines/qwen3_all_logits.patch scripts/engines/voxtral4b_stream_long.patch; do
  if ! git -C "$CRISP" apply --reverse --check "$PWD/$PATCH" 2>/dev/null; then
    git -C "$CRISP" apply "$PWD/$PATCH"
  fi
done

# Silero VAD, 0.9 MB. Small enough to ship inside the app, which is the point:
# without it a tap on fn with nothing said decodes as "Yeah." or "Thank you." —
# a transducer asked to read non-speech invents the likeliest filler.
VAD="vendor/ggml-silero-v6.2.0.bin"
if [ ! -f "$VAD" ]; then
  echo "Fetching Silero VAD…"
  curl -sL --fail -o "$VAD" \
    "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin"
fi

build_arch() {
  local ARCH="$1"; shift
  local DEST="$OUT/$ARCH"
  # The libraries are the build product; if they're all here, nothing to do.
  # libcrispasr.a is the newest of them, so a tree built before it existed is
  # rebuilt rather than linked short — and so is one built before Nemotron
  # streamed, which its stream's symbol tells apart. grep
  # -c, not -q: -q stops reading at the first hit, nm dies of SIGPIPE, and
  # under pipefail a tree that is already built gets rebuilt every time.
  if [ -f "$DEST/libwhisper.a" ] && [ -f "$DEST/libcrispasr.a" ] \
     && nm "$DEST/libcrispasr.a" 2>/dev/null | grep -c sayctrl_nemotron_stream_open >/dev/null; then
    echo "  $ARCH already built"
    return
  fi
  echo "  building ${ARCH}…"
  local B="vendor/build-$ARCH"
  rm -rf "$B" "$DEST"
  # The C sources stamp their own path into every assert, so without this
  # the shipped binary carries this machine's home directory 40 times over.
  # Mapped to "whisper.cpp/…", it says where the code lives, not who built it.
  local STRIP="-ffile-prefix-map=$(cd "$SRC" && pwd)=whisper.cpp -ffile-prefix-map=$(cd "$CRISP" && pwd)=crispasr"
  cmake -S scripts/engines -B "$B" \
    -DWHISPER_DIR="$(cd "$SRC" && pwd)" \
    -DCRISPASR_DIR="$(cd "$CRISP" && pwd)" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="$STRIP" \
    -DCMAKE_CXX_FLAGS="$STRIP" \
    -DCMAKE_OBJC_FLAGS="$STRIP" \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
    -DBUILD_SHARED_LIBS=OFF \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF \
    -DWHISPER_BUILD_SERVER=OFF \
    -DGGML_NATIVE=OFF \
    "$@" > /dev/null
  cmake --build "$B" --config Release -j "$(sysctl -n hw.ncpu)" > /dev/null
  mkdir -p "$DEST"
  # Collect every static lib the build produced, wherever cmake put it.
  find "$B" -name "*.a" -exec cp {} "$DEST/" \;
  echo "    $(ls "$DEST" | tr '\n' ' ')"
}

echo "Building the local speech engines…"
# EMBED_LIBRARY compiles the Metal shaders into the archive, so the .app has no
# loose .metal file to find at runtime.
build_arch arm64  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_ACCELERATE=ON
build_arch x86_64 -DGGML_METAL=OFF -DGGML_ACCELERATE=ON

echo "Engines ready in $OUT"
