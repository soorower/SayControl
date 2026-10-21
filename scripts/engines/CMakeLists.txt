# The local speech engines, built as one project so ggml is compiled once and
# every engine links the same copy of it. Driven by scripts/whisper.sh.
#
#   whisper.cpp  →  libwhisper.a, libparakeet.a, libggml*.a   (as upstream)
#   CrispASR     →  libcrispasr.a                   (Cohere, Voxtral, Nemotron, Qwen3-ASR)
#
# CrispASR is a whisper.cpp fork that grew runtimes for models whisper.cpp has
# no graph for. Four are taken from it: Cohere Transcribe (Conformer encoder,
# Transformer decoder), Voxtral Mini 4B Realtime (causal Whisper-style encoder
# feeding a Mistral LLM), Nemotron 3.5 ASR (a cache-aware FastConformer
# transducer) and Qwen3-ASR (an audio tower feeding a Qwen3 LLM) — their .cpp
# files, the handful of core/ sources they read, and nothing else of the
# 50-odd models in the repo. They are compiled against whisper.cpp's ggml
# rather than CrispASR's own fork of it, which is older and carries patches
# (fused ops for its TTS engines) that none of the four call — so the app
# carries one ggml, not two that clash at link time.
cmake_minimum_required(VERSION 3.14)
project(sayctrl-engines C CXX OBJC OBJCXX)

set(WHISPER_DIR "" CACHE PATH "whisper.cpp checkout")
set(CRISPASR_DIR "" CACHE PATH "CrispASR checkout")
if (NOT WHISPER_DIR OR NOT CRISPASR_DIR)
    message(FATAL_ERROR "pass -DWHISPER_DIR and -DCRISPASR_DIR")
endif()

# whisper.cpp as a sub-project: it adds ggml itself and, not being the top
# level, builds no tests or examples.
add_subdirectory(${WHISPER_DIR} whisper.cpp)

add_library(crispasr STATIC
    ${CRISPASR_DIR}/src/cohere.cpp
    ${CRISPASR_DIR}/src/voxtral4b.cpp
    # Nemotron's runtime, by way of the app's streaming front-end: the file
    # #includes nemotron.cpp to reach its internals, so it is compiled in
    # that file's place rather than beside it.
    ${CMAKE_CURRENT_SOURCE_DIR}/nemotron_stream.cpp
    # Voxtral's C API stops at encoder/LLM steps; the decode loop that joins
    # them lives in CrispASR's CLI, so the app carries its own copy.
    ${CMAKE_CURRENT_SOURCE_DIR}/voxtral4b_run.cpp
    # Qwen3-ASR's audio encoder lives in CrispASR's crisp_audio module, and
    # its transcribe() is a stub — the app carries the decode loop here too.
    ${CRISPASR_DIR}/src/qwen3_asr.cpp
    ${CRISPASR_DIR}/crisp_audio/src/audio_tower.cpp
    ${CMAKE_CURRENT_SOURCE_DIR}/qwen3_run.cpp
    ${CRISPASR_DIR}/src/core/mel.cpp
    ${CRISPASR_DIR}/src/core/gguf_loader.cpp
    ${CRISPASR_DIR}/src/core/audio_resample.cpp
    ${CRISPASR_DIR}/src/crispasr_imatrix.cpp)
target_include_directories(crispasr
    PUBLIC  ${CRISPASR_DIR}/src
    PRIVATE ${CRISPASR_DIR}/src/core ${CRISPASR_DIR}/include ${CRISPASR_DIR}/crisp_audio/include
            # gguf_loader.cpp reads ggml-backend-impl.h, an internal header.
            ${WHISPER_DIR}/ggml/src)
target_compile_features(crispasr PUBLIC cxx_std_20)
# Nemotron's graph calls two ops only CrispASR's ggml fork has; the compat
# header rebuilds them from stock ones for that one file.
set_source_files_properties(${CMAKE_CURRENT_SOURCE_DIR}/nemotron_stream.cpp PROPERTIES
    COMPILE_OPTIONS "-include;${CMAKE_CURRENT_SOURCE_DIR}/crispasr_ggml_compat.h")
target_compile_options(crispasr PRIVATE -O3)
# The mel filterbank goes through cblas_sgemm; Accelerate provides it on both
# architectures. Deliberately WITHOUT ACCELERATE_NEW_LAPACK: that define binds
# cblas_sgemm$NEWLAPACK, a symbol macOS 13.3 introduced, and the app's floor is
# 13.0. The legacy symbol is deprecated but present on every 13.x, so the
# deprecation warning is the price of not crashing on 13.0–13.2.
find_library(ACCELERATE_LIB Accelerate REQUIRED)
target_compile_definitions(crispasr PRIVATE HAVE_BLAS)
target_compile_options(crispasr PRIVATE -Wno-deprecated-declarations)
if (GGML_METAL)
    target_compile_definitions(crispasr PRIVATE GGML_USE_METAL)
endif()
target_link_libraries(crispasr PUBLIC ggml ggml-base ${ACCELERATE_LIB})
