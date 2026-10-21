// The Local provider, with nothing behind it but this file and two C libraries
// on one ggml.
//
// Six model families: whisper.cpp carries a Parakeet implementation alongside
// Whisper, and Cohere Transcribe, Voxtral Realtime, Nemotron 3.5 and Qwen3-ASR
// come from CrispASR, a whisper.cpp fork with runtimes for shapes whisper.cpp has no
// graph for — built against whisper.cpp's ggml (scripts/engines), so all of
// them run everywhere the app does, Apple Silicon and Intel alike, with no
// second engine to ship.
//
// "Local" used to mean an OpenAI-shaped Python server on 127.0.0.1:8756 that
// you had to clone and start by hand — no reasonable thing to ask of someone
// who downloaded a DMG. whisper.cpp is compiled into the binary instead, so the
// only thing a user ever fetches is one file of weights. No port, no second
// process, no runtime to install.
//
// Weights are NOT in the bundle: the app ships tiny, the user picks what to
// download, and it lands in Application Support because the .app is signed and
// must stay read-only.
import AVFoundation
import CryptoKit
import Foundation

/// One downloadable model. Every engine reads a single ggml/GGUF file, which is
/// the whole reason this is so much simpler than it was: download is one URL,
/// delete is one `rm`, and "is it installed" is one `fileExists`.
enum LocalFamily {
    case whisper
    case parakeet
    /// Cohere Transcribe: the most accurate thing on the Open ASR leaderboard,
    /// and a 74-second clip takes it under a second on Apple Silicon. An
    /// encoder-decoder like Whisper, so it has no streaming mode of its own —
    /// but it is fast enough that the live path's re-decode-everything loop
    /// works on it (see `streams`). It has no language detection either: the
    /// language is chosen up front from the Mac's preferred languages.
    case cohere
    /// Voxtral Mini 4B Realtime: Mistral's streaming model, a causal
    /// Whisper-style encoder feeding a 3.4B Mistral decoder that is walked
    /// through the audio one frame at a time. Detects the language itself.
    case voxtral
    /// Nemotron 3.5 ASR: NVIDIA's cache-aware FastConformer transducer, the
    /// same size as Parakeet. Like Cohere it is told the language up front.
    case nemotron
    /// Qwen3-ASR 1.7B: an audio tower feeding a Qwen3 LLM. Offered in English
    /// only, with the user's names as context — the open model that came
    /// closest to Soniox on the user's own dictations (2026-10-01).
    case qwen3

    /// Whether this family can run live at all (LocalLive.swift). Which
    /// models actually do on a given Mac is measured there — LocalSpeed —
    /// since a pass that keeps up on an M5 Pro may not on a base M1.
    ///
    /// Two ways in. Cohere, Parakeet and Qwen3 re-run over the whole
    /// utterance every 0.6 s, which needs a pass to finish well inside the
    /// tick and what it already showed to stay put as more arrives. Parakeet
    /// qualifies by architecture — a transducer's prefix is stable. Cohere
    /// by measurement: 100–240 ms a pass for ten seconds of speech, and the
    /// prefix only ever grew. Qwen3-ASR on the owner's call (2026-10-01), at
    /// a slower cadence: 0.27 s a pass at 2 s of speech, 0.82 s at 11 s, so
    /// past about 8 s the loop skips ticks and the preview updates every
    /// second or so.
    ///
    /// Voxtral and Nemotron are streaming models by design and are fed the
    /// audio as it arrives instead (`streamsNatively`): re-running them over
    /// ten seconds took about two seconds and one, past the tick, but their
    /// own incremental paths do each piece of audio once.
    ///
    /// Whisper stays out: it decodes a fixed 30-second window five times
    /// slower than Cohere and visibly rewrites itself between passes.
    var streams: Bool { self != .whisper }

    /// Fed the audio piece by piece (scripts/engines/nemotron_stream.cpp,
    /// CrispASR's voxtral4b_stream) rather than re-run over all of it.
    var streamsNatively: Bool { self == .voxtral || self == .nemotron }
}

struct LocalCatalogEntry {
    let id: String
    let name: String
    /// How many languages the model was trained on — the one number that
    /// actually decides whether a model is usable for you.
    let languages: Int
    /// Which of the ggml runtimes reads this file.
    let family: LocalFamily
    /// Where the weights come from. Each family is published in its own
    /// repository, so each row carries its own address.
    let url: String
    let bytes: Int64
    /// Straight off HuggingFace's LFS metadata. A download that ends early
    /// otherwise fails later as an unreadable model, which tells the user
    /// nothing.
    let sha256: String

    /// The name on disk, taken from the URL so the two can never disagree.
    var file: String { String(url.split(separator: "/").last ?? "model.bin") }

    /// The whole of a row's subtitle: what it understands, what it costs.
    var detail: String { "\(languages) languages · \(LocalEngine.humanSize(bytes))" }
}

/// Deliberately short. Every extra row is a decision the user has to make, and
/// each family gets the same three stops — small, standard, full — with Cohere
/// on two, because its smallest is already 1.5 GB. Listed best first, which is
/// also the order the pane shows them in. Sizes and checksums are read from
/// the model repositories.
let LOCAL_CATALOG: [LocalCatalogEntry] = [
    // Cohere first: the most accurate of the three and it streams. The 2B
    // model, quantised — Q4_K is the one to have, the card measures it fastest
    // of the six and nothing above it is known to be more accurate; Q8_0 is
    // there for whoever wants the weights as close to the original as a
    // 2.4 GB download gets.
    LocalCatalogEntry(
        id: "cohere-transcribe",
        name: "Cohere Transcribe",
        languages: 14,
        family: .cohere,
        url: COHERE_REPO + "cohere-transcribe-q4_k.gguf",
        bytes: 1_510_363_008,
        sha256: "237261c543dc9124a3f08f95b48c9c672896ef0d79dc8cadce3fb4ddc09a2ef8"),
    LocalCatalogEntry(
        id: "cohere-transcribe-full",
        name: "Cohere Transcribe Full",
        languages: 14,
        family: .cohere,
        url: COHERE_REPO + "cohere-transcribe-q8_0.gguf",
        bytes: 2_423_803_776,
        sha256: "e725a5ec9b5b9c0b7aba07b071753cae9b39ec3fbaf9f6a622c6810d5a11e3f4"),
    // Qwen3-ASR, English only, the user's names as context; live at a
    // slower cadence (see `LocalFamily.streams`). Q8_0, the build that was
    // measured: on 279 of the user's own dictations it tied Soniox without
    // terms, ahead of every other local model
    // (bench-experiments/SUMMARY-own-dictations.txt).
    LocalCatalogEntry(
        id: "qwen3-asr-english",
        name: "Qwen3-ASR English",
        languages: 1,
        family: .qwen3,
        url: QWEN3_REPO + "qwen3-asr-1.7b-q8_0.gguf",
        bytes: 2_506_723_200,
        sha256: "9851ab996591a2d0cb0efb216002764b509c86bd40c95e613d7b65b8e69c8a6e"),
    // Voxtral Realtime and Nemotron 3.5, on the finished clip only (see
    // `LocalFamily.streams`). Voxtral is the heavy one: Q4_K is 2.5 GB and
    // the most it asks of memory; Q8_0 is the near-original at 4.7 GB.
    LocalCatalogEntry(
        id: "voxtral-realtime",
        name: "Voxtral Realtime",
        languages: 13,
        family: .voxtral,
        url: VOXTRAL_REPO + "voxtral-mini-4b-realtime-q4_k.gguf",
        bytes: 2_524_137_216,
        sha256: "7dda1dba692f18c9d30a6064943b92c562853b399e96320929d2e1399c9d41cc"),
    LocalCatalogEntry(
        id: "voxtral-realtime-full",
        name: "Voxtral Realtime Full",
        languages: 13,
        family: .voxtral,
        url: VOXTRAL_REPO + "voxtral-mini-4b-realtime-q8_0.gguf",
        bytes: 4_733_486_848,
        sha256: "0289e58b62c1da39e4f6d1ed962c6d1cab8d261ca193d25a528a71a9b1b36792"),
    LocalCatalogEntry(
        id: "nemotron-3.5",
        name: "Nemotron 3.5",
        languages: 34,
        family: .nemotron,
        url: NEMOTRON_REPO + "nemotron-3.5-asr-streaming-0.6b-q8_0.gguf",
        bytes: 686_164_384,
        sha256: "96e4e60b9ecea9ef97d9eb5677af7fd77b1d43b2784c6a6ea98e1858bda4f05e"),
    LocalCatalogEntry(
        id: "nemotron-3.5-full",
        name: "Nemotron 3.5 Full",
        languages: 34,
        family: .nemotron,
        url: NEMOTRON_REPO + "nemotron-3.5-asr-streaming-0.6b-f16.gguf",
        bytes: 1_286_368_480,
        sha256: "14cbc98df495d8ab452c6a4ac367136d94ab5da55e73afaa96ba4f749dd95d09"),
    // Parakeet: the light option, a quarter of the size, and it streams.
    LocalCatalogEntry(
        id: "parakeet-v3-small",
        name: "Parakeet v3 Small",
        languages: 25,
        family: .parakeet,
        url: PARAKEET_REPO + "ggml-parakeet-tdt-0.6b-v3-q4_0.bin",
        bytes: 355_615_679,
        sha256: "aa7fe2f5fb47d863ca23e8b1d490632d63a2599f515268b6d6bd656158dad45e"),
    LocalCatalogEntry(
        id: "parakeet-v3",
        name: "Parakeet v3",
        languages: 25,
        family: .parakeet,
        url: PARAKEET_REPO + "ggml-parakeet-tdt-0.6b-v3-q8_0.bin",
        bytes: 668_757_119,
        sha256: "4d64e9e96c2792186d072fde0034df0ad670cf680a2f53069052ead827fd600e"),
    LocalCatalogEntry(
        id: "parakeet-v3-full",
        name: "Parakeet v3 Full",
        languages: 25,
        family: .parakeet,
        url: PARAKEET_REPO + "ggml-parakeet-tdt-0.6b-v3-f16.bin",
        bytes: 1_255_897_319,
        sha256: "833bffc9513b2cae867ee9e51633cfd11e4d51aaa5597c8ac02159385a2b426f"),
    // Whisper: 99 languages, no streaming.
    LocalCatalogEntry(
        id: "whisper-small",
        name: "Whisper Small",
        languages: 99,
        family: .whisper,
        url: WHISPER_REPO + "ggml-small.bin",
        bytes: 487_601_967,
        sha256: "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b"),
    LocalCatalogEntry(
        id: "whisper-turbo",
        name: "Whisper Turbo",
        languages: 99,
        family: .whisper,
        url: WHISPER_REPO + "ggml-large-v3-turbo-q5_0.bin",
        bytes: 574_041_195,
        sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"),
    LocalCatalogEntry(
        id: "whisper-large",
        name: "Whisper Large",
        languages: 99,
        family: .whisper,
        url: WHISPER_REPO + "ggml-large-v3-turbo.bin",
        bytes: 1_624_555_275,
        sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"),
]

/// The upstream model repositories. The first two are the ones whisper.cpp's
/// own download scripts use; the third is CrispASR's GGUF export of Cohere's
/// Apache-2.0 weights, the only published GGUF of them.
private let WHISPER_REPO = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"
private let PARAKEET_REPO = "https://huggingface.co/ggml-org/parakeet-GGUF/resolve/main/"
private let COHERE_REPO = "https://huggingface.co/cstr/cohere-transcribe-03-2026-GGUF/resolve/main/"
/// CrispASR's GGUF exports of Mistral's and NVIDIA's weights, in the layout
/// its runtimes read — llama.cpp's GGUFs of the same models are not.
private let VOXTRAL_REPO = "https://huggingface.co/cstr/voxtral-mini-4b-realtime-GGUF/resolve/main/"
private let NEMOTRON_REPO = "https://huggingface.co/cstr/nemotron-3.5-asr-streaming-0.6b-GGUF/resolve/main/"
private let QWEN3_REPO = "https://huggingface.co/cstr/qwen3-asr-1.7b-GGUF/resolve/main/"

// MARK: - The loaded model

/// One loaded model, and the serial queue that owns it. None of `whisper_full`,
/// `parakeet_full` or `cohere_transcribe` is reentrant and all run for seconds,
/// so the context never touches the main thread and never runs twice at once.
private final class LocalRunner {
    let modelID: String
    let family: LocalFamily
    private var ctx: OpaquePointer?
    private let queue = DispatchQueue(label: "com.sayctrl.localengine", qos: .userInitiated)
    /// Cohere only: the language every clip is decoded in, settled at load.
    private var language = "en"

    init(path: String, modelID: String, family: LocalFamily) throws {
        self.modelID = modelID
        self.family = family
        switch family {
        case .whisper:
            var params = whisper_context_default_params()
            // Metal on Apple Silicon; the Intel slice is built without it and
            // ignores this.
            params.use_gpu = true
            ctx = whisper_init_from_file_with_params(path, params)
        case .parakeet:
            var params = parakeet_context_default_params()
            params.use_gpu = true
            ctx = parakeet_init_from_file_with_params(path, params)
        case .cohere:
            var params = cohere_context_default_params()
            params.use_gpu = true
            params.n_threads = threads
            // It narrates every load to stderr otherwise — see silenceEngineLogs.
            params.verbosity = 0
            ctx = cohere_init_from_file(path, params)
            if let ctx = ctx { language = Self.cohereLanguage(ctx) }
        case .voxtral:
            var params = voxtral4b_context_default_params()
            params.use_gpu = true
            params.n_threads = threads
            params.verbosity = 0
            ctx = voxtral4b_init_from_file(path, params)
        case .nemotron:
            var params = nemotron_context_default_params()
            params.use_gpu = true
            params.n_threads = threads
            params.verbosity = 0
            ctx = nemotron_init_from_file(path, params)
            if let ctx = ctx { nemotron_set_language(ctx, Self.nemotronLanguage) }
        case .qwen3:
            var params = qwen3_asr_context_default_params()
            params.use_gpu = true
            params.n_threads = threads
            params.verbosity = 0
            ctx = qwen3_asr_init_from_file(path, params)
        }
        guard ctx != nil else {
            throw NSError(domain: "SayCtrl", code: 10, userInfo: [
                NSLocalizedDescriptionKey:
                    "Couldn't load that model file — it may be incomplete. Delete it and download again."])
        }
    }

    deinit {
        guard let ctx = ctx else { return }
        // A take still streaming holds the context's caches.
        closeStream()
        switch family {
        case .whisper:  whisper_free(ctx)
        case .parakeet: parakeet_free(ctx)
        case .cohere:   cohere_free(ctx)
        case .voxtral:  voxtral4b_free(ctx)
        case .nemotron: nemotron_free(ctx)
        case .qwen3:    qwen3_asr_free(ctx)
        }
    }

    /// Leave two cores for the UI and the paste path; ggml will happily
    /// saturate everything otherwise and the HUD starts to stutter.
    private var threads: Int32 {
        Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
    }

    /// Cohere Transcribe takes a language code and has no detector of its own:
    /// handed the wrong one it writes a fluent transcript in the wrong language
    /// and never says so. Its probe-based detection costs a decode per
    /// candidate — fourteen of them for the base model — which is no use at the
    /// end of a dictation. So the language is the first of the Mac's preferred
    /// languages the model lists, the same source Lexicon reads, and English
    /// when none matches. A GGUF without the list is told "en" too.
    private static func cohereLanguage(_ ctx: OpaquePointer) -> String {
        let supported = (0..<cohere_n_supported_languages(ctx)).compactMap { i in
            cohere_supported_language(ctx, i).map { String(cString: $0) }
        }
        guard !supported.isEmpty else { return "en" }
        for pref in Locale.preferredLanguages {
            let base = String(pref.prefix(while: { $0 != "-" && $0 != "_" })).lowercased()
            if supported.contains(base) { return base }
        }
        return supported.contains("en") ? "en" : supported[0]
    }

    /// Nemotron conditions its encoder on a language prompt and, told nothing,
    /// assumes US English. It publishes no list, so this is the one its
    /// runtime maps (nemotron.cpp): the first preferred language it has,
    /// regional form where it has one (en-GB, pt-BR, fr-CA), else the base.
    private static let nemotronLanguage: String = {
        let locales: Set<String> = [
            "en-US", "en-GB", "es-ES", "es-US", "zh-CN", "zh-TW", "hi-IN", "ar-AR", "fr-FR", "de-DE",
            "ja-JP", "ru-RU", "pt-BR", "pt-PT", "ko-KR", "it-IT", "nl-NL", "pl-PL", "tr-TR", "uk-UA",
            "ro-RO", "el-GR", "cs-CZ", "hu-HU", "sv-SE", "da-DK", "fi-FI", "nb-NO", "sk-SK", "hr-HR",
            "bg-BG", "lt-LT", "th-TH", "vi-VN", "et-EE", "lv-LV", "sl-SI", "he-IL", "fr-CA", "nn-NO",
        ]
        let bases = Set(locales.map { String($0.prefix(2)) })
        for pref in Locale.preferredLanguages {
            let parts = pref.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
            guard let base = parts.first?.lowercased(), bases.contains(base) else { continue }
            if let region = parts.last?.uppercased(), parts.count > 1, locales.contains("\(base)-\(region)") {
                return "\(base)-\(region)"
            }
            return base
        }
        return "en"
    }()

    /// `draft` is the last live pass's text — Qwen3 checks it rather than
    /// writing the take from scratch (same text, far fewer model calls); the
    /// other families ignore it.
    func transcribe(_ samples: [Float], prompt: String, draft: String = "") async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self = self, let ctx = self.ctx else {
                    return continuation.resume(throwing: NSError(
                        domain: "SayCtrl", code: 11,
                        userInfo: [NSLocalizedDescriptionKey: "Local model was unloaded mid-transcription."]))
                }
                do {
                    let text: String
                    switch self.family {
                    case .whisper:  text = try self.runWhisper(ctx, samples, prompt)
                    case .parakeet: text = try self.runParakeet(ctx, samples)
                    case .cohere:   text = try self.runCohere(ctx, samples)
                    case .voxtral:  text = try self.runVoxtral(ctx, samples)
                    case .nemotron: text = try self.runNemotron(ctx, samples)
                    case .qwen3:    text = try self.runQwen3(ctx, samples, prompt, draft)
                    }
                    continuation.resume(returning: text.trimmingCharacters(in: .whitespacesAndNewlines))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: Fed as the audio arrives (Voxtral, Nemotron)

    /// The take being streamed. One at a time: both keep their state on the
    /// model's context (Nemotron's encoder caches, Voxtral's LLM cache).
    /// Touched only on `queue`, like the context itself.
    private var stream: OpaquePointer?
    /// Voxtral hands its words over a piece at a time; they collect here.
    private var streamText = ""

    /// Runs `body` on the model's queue, the way every call into it goes.
    private func onQueue<T>(_ body: @escaping (OpaquePointer) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self = self, let ctx = self.ctx else {
                    return continuation.resume(throwing: NSError(
                        domain: "SayCtrl", code: 11,
                        userInfo: [NSLocalizedDescriptionKey: "Local model was unloaded mid-transcription."]))
                }
                do { continuation.resume(returning: try body(ctx)) } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func streamOpen() async throws {
        try await onQueue { ctx in
            self.closeStream()
            switch self.family {
            case .voxtral:
                self.stream = voxtral4b_stream_open(ctx, 0, 0)
                // Words as they decode, not all at the end.
                if let s = self.stream { voxtral4b_stream_set_live_decode(s, 1) }
            case .nemotron:
                self.stream = sayctrl_nemotron_stream_open(ctx)
            default:
                break
            }
            guard self.stream != nil else { throw LocalRunner.failed }
        }
    }

    /// Hands over the audio since the last call and answers the text so far.
    func streamFeed(_ chunk: [Float]) async throws -> String {
        try await onQueue { _ in try self.feed(chunk) }
    }

    /// The last of the audio, then the stream's own end: Voxtral's ten
    /// tokens of trailing silence, Nemotron's tail over the zero pad.
    func streamFinish(_ tail: [Float]) async throws -> String {
        try await onQueue { _ in
            defer { self.closeStream() }
            _ = try self.feed(tail)
            guard let s = self.stream else { throw LocalRunner.failed }
            switch self.family {
            case .voxtral:
                guard voxtral4b_stream_flush(s) >= 0 else { throw LocalRunner.failed }
                self.drainVoxtral(s)
                return self.streamText.trimmingCharacters(in: .whitespacesAndNewlines)
            default:
                guard sayctrl_nemotron_stream_finish(s) == 0 else { throw LocalRunner.failed }
                return self.nemotronText(s)
            }
        }
    }

    /// Voxtral and Nemotron build their Metal kernels on first use: several
    /// seconds (measured 2026-10-21, M5 Pro) that would otherwise land on
    /// the first take after a load, as words that don't come and then
    /// rush in. Two seconds of silence through the stream, straight after
    /// loading, pays for it while nobody is waiting.
    func prime() {
        guard family.streamsNatively else { return }
        queue.async { [weak self] in
            guard let self = self, let ctx = self.ctx, self.stream == nil else { return }
            defer { self.closeStream() }
            switch self.family {
            case .voxtral:
                self.stream = voxtral4b_stream_open(ctx, 0, 0)
                if let s = self.stream { voxtral4b_stream_set_live_decode(s, 1) }
            default:
                self.stream = sayctrl_nemotron_stream_open(ctx)
            }
            guard let s = self.stream else { return }
            let quiet = [Float](repeating: 0, count: 3200)
            for _ in 0..<10 { _ = try? self.feed(quiet) }
            switch self.family {
            case .voxtral: _ = voxtral4b_stream_flush(s)
            default:       _ = sayctrl_nemotron_stream_finish(s)
            }
        }
    }

    /// A take thrown away, or a model unloaded under one.
    func streamCancel() {
        queue.async { [weak self] in self?.closeStream() }
    }

    private func feed(_ chunk: [Float]) throws -> String {
        guard let s = stream else { throw LocalRunner.failed }
        if !chunk.isEmpty {
            let rc = chunk.withUnsafeBufferPointer { buf -> Int32 in
                switch family {
                case .voxtral: return voxtral4b_stream_feed(s, buf.baseAddress, Int32(buf.count))
                default:       return sayctrl_nemotron_stream_feed(s, buf.baseAddress, Int32(buf.count))
                }
            }
            guard rc == 0 else { throw LocalRunner.failed }
        }
        switch family {
        case .voxtral:
            drainVoxtral(s)
            return streamText.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            return nemotronText(s)
        }
    }

    private func drainVoxtral(_ s: OpaquePointer) {
        var buf = [CChar](repeating: 0, count: 4096)
        while voxtral4b_stream_get_text(s, &buf, Int32(buf.count), nil, nil, nil) > 0 {
            streamText += String(cString: buf)
        }
    }

    private func nemotronText(_ s: OpaquePointer) -> String {
        guard let out = sayctrl_nemotron_stream_text(s) else { return "" }
        defer { free(out) }
        return Self.withoutLanguageTag(String(cString: out))
    }

    private func closeStream() {
        guard let s = stream else { return }
        switch family {
        case .voxtral: voxtral4b_stream_close(s)
        default:       sayctrl_nemotron_stream_close(s)
        }
        stream = nil
        streamText = ""
    }

    /// Ten seconds of speech, timed: a replayed model's pass over all of
    /// it, or a streamed one's compute per second of audio fed in the
    /// pieces a take would feed. nil while a take is streaming on this
    /// context — the two would share its caches.
    func benchmark(_ clip: [Float]) async throws -> Double? {
        let prompt = LocalEngine.hint(for: family)
        if family.streamsNatively {
            return try await onQueue { ctx -> Double? in
                guard self.stream == nil else { return nil }
                defer { self.closeStream() }
                switch self.family {
                case .voxtral:
                    self.stream = voxtral4b_stream_open(ctx, 0, 0)
                    if let s = self.stream { voxtral4b_stream_set_live_decode(s, 1) }
                default:
                    self.stream = sayctrl_nemotron_stream_open(ctx)
                }
                guard self.stream != nil else { throw LocalRunner.failed }
                var spent: TimeInterval = 0
                for start in stride(from: 0, to: clip.count, by: 3200) {
                    let piece = Array(clip[start..<min(start + 3200, clip.count)])
                    let t0 = Date()
                    _ = try self.feed(piece)
                    spent += Date().timeIntervalSince(t0)
                }
                return spent / (Double(clip.count) / 16000)
            }
        }
        // The first pass pays for loading kernels, so it doesn't count; it
        // is also the earlier pass a live one has before it, whose text Qwen3
        // checks rather than writing the take again (the others ignore it).
        let draft = try await transcribe(Array(clip.prefix(clip.count / 2)), prompt: prompt)
        let t0 = Date()
        _ = try await transcribe(clip, prompt: prompt, draft: draft)
        return Date().timeIntervalSince(t0)
    }

    private func runWhisper(_ ctx: OpaquePointer, _ samples: [Float], _ prompt: String) throws -> String {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.no_context = true
        params.suppress_blank = true
        params.n_threads = threads

        // Both C strings must outlive the whisper_full call, which is why these
        // are nested closures rather than locals.
        let text: String? = "auto".withCString { lang in
            params.language = lang
            return prompt.withCString { hint -> String? in
                if !prompt.isEmpty { params.initial_prompt = hint }
                let status = samples.withUnsafeBufferPointer { buf in
                    whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
                }
                guard status == 0 else { return nil }
                var out = ""
                for i in 0..<whisper_full_n_segments(ctx) {
                    if let seg = whisper_full_get_segment_text(ctx, i) { out += String(cString: seg) }
                }
                return out
            }
        }
        guard let text = text else { throw LocalRunner.failed }
        return text
    }

    /// Parakeet's params are a smaller set — no language to pick (the model is
    /// multilingual by construction) and no prompt to bias it with.
    private func runParakeet(_ ctx: OpaquePointer, _ samples: [Float]) throws -> String {
        var params = parakeet_full_default_params(PARAKEET_SAMPLING_GREEDY)
        params.no_context = true
        params.n_threads = threads
        let status = samples.withUnsafeBufferPointer { buf in
            parakeet_full(ctx, params, buf.baseAddress, Int32(buf.count))
        }
        guard status == 0 else { throw LocalRunner.failed }
        var out = ""
        for i in 0..<parakeet_full_n_segments(ctx) {
            if let seg = parakeet_full_get_segment_text(ctx, i) { out += String(cString: seg) }
        }
        return out
    }

    /// Cohere's is the smallest interface of the three: samples in, one
    /// malloc'd string out. Clips past its 30-second window are split and
    /// joined inside the library, so nothing here cares how long one is. No
    /// prompt to bias it with either — the Dictionary does that work after.
    private func runCohere(_ ctx: OpaquePointer, _ samples: [Float]) throws -> String {
        let out = samples.withUnsafeBufferPointer { buf in
            cohere_transcribe(ctx, buf.baseAddress, Int32(buf.count), language)
        }
        guard let out = out else { throw LocalRunner.failed }
        defer { free(out) }
        return String(cString: out)
    }

    /// Voxtral: the same one-call shape as Cohere, through the app's own
    /// decode loop (scripts/engines/voxtral4b_run.cpp). It writes its own
    /// punctuation and picks its own language.
    private func runVoxtral(_ ctx: OpaquePointer, _ samples: [Float]) throws -> String {
        let out = samples.withUnsafeBufferPointer { buf in
            sayctrl_voxtral4b_transcribe(ctx, buf.baseAddress, Int32(buf.count))
        }
        guard let out = out else { throw LocalRunner.failed }
        defer { free(out) }
        return String(cString: out)
    }

    /// Nemotron closes every sentence it hears with the language it was told
    /// — "…better than others. <en-US>" — which is bookkeeping, not speech.
    private func runNemotron(_ ctx: OpaquePointer, _ samples: [Float]) throws -> String {
        let out = samples.withUnsafeBufferPointer { buf in
            nemotron_transcribe(ctx, buf.baseAddress, Int32(buf.count))
        }
        guard let out = out else { throw LocalRunner.failed }
        defer { free(out) }
        return Self.withoutLanguageTag(String(cString: out))
    }

    static func withoutLanguageTag(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s*<[a-z]{2}(-[A-Z]{2})?>"#, with: "", options: .regularExpression)
    }

    /// Qwen3-ASR, in English, with `context` (the user's names) as the
    /// system turn and `draft` to check — see scripts/engines/qwen3_run.cpp
    /// for all three.
    private func runQwen3(_ ctx: OpaquePointer, _ samples: [Float], _ context: String, _ draft: String) throws -> String {
        func decode(_ context: String) throws -> String {
            let out = samples.withUnsafeBufferPointer { buf in
                sayctrl_qwen3_transcribe(ctx, buf.baseAddress, Int32(buf.count), context, "English",
                                         draft.isEmpty ? nil : draft)
            }
            guard let out = out else { throw LocalRunner.failed }
            defer { free(out) }
            return String(cString: out)
        }
        let text = try decode(context)
        if Self.echoes(text, context) { return try decode("") }
        // With the text before the caret in the context, the failure to watch
        // for is the same one in prose: that text written back out. Eight
        // words of it in a row and the clip is decoded with the names alone.
        if let blank = context.range(of: "\n\n"),
           Self.repeatsProse(text, String(context[blank.upperBound...])) {
            return try decode(String(context[..<blank.lowerBound]))
        }
        return text
    }

    private static func repeatsProse(_ text: String, _ prose: String, run: Int = 8) -> Bool {
        func words(_ s: String) -> [String] {
            s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
        }
        let t = words(text), p = words(prose)
        guard t.count >= run, p.count >= run else { return false }
        let grams = Set((0...(p.count - run)).map { p[$0..<$0 + run].joined(separator: " ") })
        return (0...(t.count - run)).contains { grams.contains(t[$0..<$0 + run].joined(separator: " ")) }
    }

    /// Qwen3-ASR's one failure with a context: on a clip with next to no
    /// speech it can read the list back out instead of transcribing — 4 of
    /// 279 dictations, each time the list itself, from the top, comma after
    /// comma. Five of its terms in its own order is that answer; the clip is
    /// decoded again without the list.
    private static func echoes(_ text: String, _ context: String) -> Bool {
        guard text.contains(",") else { return false }
        let lower = text.lowercased()
        var from = lower.startIndex
        var inOrder = 0
        for term in context.lowercased().components(separatedBy: ", ") where !term.isEmpty {
            guard let hit = lower.range(of: term, range: from..<lower.endIndex) else { continue }
            inOrder += 1
            from = hit.upperBound
        }
        return inOrder >= 5
    }

    private static let failed = NSError(domain: "SayCtrl", code: 12, userInfo: [
        NSLocalizedDescriptionKey: "Local transcription failed."])
}

// MARK: - Downloading

/// One model download. Split out because URLSession's delegate callbacks arrive
/// off the main thread and LocalEngine is main-actor throughout.
private final class DownloadJob: NSObject, URLSessionDownloadDelegate {
    private let entry: LocalCatalogEntry
    private let destination: URL
    private let onProgress: (Double) -> Void
    private let onFinish: (Error?) -> Void
    private var session: URLSession!
    private var task: URLSessionDownloadTask?
    /// Kept so a dropped download resumes instead of restarting — it matters
    /// when the file is three gigabytes.
    private(set) var resumeData: Data?
    private var finished = false

    init(entry: LocalCatalogEntry, destination: URL, resuming: Data?,
         onProgress: @escaping (Double) -> Void, onFinish: @escaping (Error?) -> Void) {
        self.entry = entry
        self.destination = destination
        self.onProgress = onProgress
        self.onFinish = onFinish
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 24 * 3600
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        if let resuming = resuming {
            task = session.downloadTask(withResumeData: resuming)
        } else {
            task = session.downloadTask(with: URL(string: entry.url)!)
        }
        task?.resume()
    }

    /// Resume data arrives asynchronously, so the caller is told when it is
    /// actually available rather than reading `resumeData` straight after.
    func cancel(_ done: @escaping (Data?) -> Void) {
        task?.cancel { [weak self] data in
            self?.session.invalidateAndCancel()
            done(data)
        }
    }

    /// The one exit. Invalidating releases the session's strong hold on this
    /// delegate; without it every completed download leaks its job.
    private func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true
        session.finishTasksAndInvalidate()
        onFinish(error)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        // The server does not always send a length; the catalogue always knows.
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : entry.bytes
        onProgress(total > 0 ? Double(totalBytesWritten) / Double(total) : 0)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            // A partial file that hashes wrong is worse than no file, so verify
            // before it is ever moved into place.
            guard LocalEngine.sha256(of: location) == entry.sha256 else {
                try? FileManager.default.removeItem(at: location)
                throw NSError(domain: "SayCtrl", code: 13, userInfo: [
                    NSLocalizedDescriptionKey:
                        "Download finished but didn't match its checksum — try again."])
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(nil)
        } catch {
            finish(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error else { return }   // success already reported
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled {
            resumeData = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            return                                 // a cancel is not a failure
        }
        resumeData = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        finish(error)
    }
}

// MARK: - The engine

/// Catalog, downloads, storage and inference for on-device transcription.
/// Everything here is touched from the main thread, like the rest of this app —
/// the download delegate is the one exception and hops back explicitly. The
/// heavy work happens on LocalRunner's own queue either way.
final class LocalEngine {
    static let shared = LocalEngine()

    static var catalog: [LocalCatalogEntry] { LOCAL_CATALOG }

    static func entry(_ id: String) -> LocalCatalogEntry? {
        // A saved LOCAL_MODEL may carry a ":suffix" from the old server's ids.
        let base = id.components(separatedBy: ":").first ?? id
        return LOCAL_CATALOG.first { $0.id == base }
    }

    // MARK: Storage

    /// Application Support, not the bundle: the bundle is signed and read-only,
    /// and weights this large have no business inside a DMG anyway.
    static var root: URL {
        _ = migratedFromKotha
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SayCtrl/Models", isDirectory: true)
    }

    /// The app was Kotha, and its weights sat in Application Support/Kotha.
    /// These files run to gigabytes: move the folder across on first launch
    /// rather than let a rename bill the user for the same download twice.
    /// `static let` so the work happens once, on whichever thread asks first.
    private static let migratedFromKotha: Void = {
        let fm = FileManager.default
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return }
        let old = base.appendingPathComponent("Kotha", isDirectory: true)
        let new = base.appendingPathComponent("SayCtrl", isDirectory: true)
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        try? fm.moveItem(at: old, to: new)
    }()

    static func path(for entry: LocalCatalogEntry) -> URL {
        root.appendingPathComponent(entry.file)
    }

    func isInstalled(_ entry: LocalCatalogEntry) -> Bool {
        let url = Self.path(for: entry)
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64
        else { return false }
        // A truncated file would load as a corrupt model; treat it as absent so
        // the row offers Download again rather than Use.
        return size == entry.bytes
    }

    func installedIDs() -> [String] { LOCAL_CATALOG.filter(isInstalled).map(\.id) }

    /// What "use the local model" lands on: the biggest thing downloaded,
    /// because on this axis size really does buy accuracy.
    func bestInstalledID() -> String? {
        LOCAL_CATALOG.filter(isInstalled).max { $0.bytes < $1.bytes }?.id
    }

    // MARK: The model picked for this Mac

    /// The chip and the memory, which between them decide what runs well
    /// here. Memory bandwidth is the thing that really matters and macOS
    /// doesn't report it, but it tracks the chip: every Pro, Max and Ultra
    /// ships with 16 GB or more, so memory alone sorts the fast Macs from
    /// the base ones.
    struct Machine {
        let chip: String
        let memoryGB: Int
        let appleSilicon: Bool
        /// "M5 Pro · 24 GB", the chip the Plans page wears.
        var label: String { "\(chip) · \(memoryGB) GB" }

        static let current: Machine = {
            var arm: Int32 = 0
            var armSize = MemoryLayout<Int32>.size
            let appleSilicon = sysctlbyname("hw.optional.arm64", &arm, &armSize, nil, 0) == 0 && arm == 1
            var size = 0
            var brand = ""
            if sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 {
                var buf = [CChar](repeating: 0, count: size)
                if sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0) == 0 { brand = String(cString: buf) }
            }
            let chip = brand.hasPrefix("Apple ") ? String(brand.dropFirst(6))
                : (appleSilicon ? "Apple silicon" : "Intel")
            let gb = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
            return Machine(chip: chip, memoryGB: gb, appleSilicon: appleSilicon)
        }()
    }

    /// The base Cohere model's own list (config.json `supported_languages`,
    /// the same one it reports at load), and Parakeet v3's 25 European ones.
    private static let cohereLanguages: Set<String> = ["en", "fr", "de", "es", "it", "pt", "nl",
                                                       "pl", "el", "ar", "ja", "zh", "vi", "ko"]
    private static let parakeetLanguages: Set<String> = ["bg", "hr", "cs", "da", "nl", "en", "et", "fi",
                                                         "fr", "de", "el", "hu", "it", "lv", "lt", "mt",
                                                         "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk"]

    /// The one local model a user's copy offers, chosen for them rather than
    /// from a list. Cohere is the most accurate and streams, and wants a fast
    /// Mac; Parakeet is the light one and streams too; Whisper is the fallback
    /// for a language neither of them hears. The language is the Mac's first
    /// preferred one — what Cohere would be told to listen for anyway.
    static var recommendedID: String {
        let mac = Machine.current
        let pref = Locale.preferredLanguages.first ?? "en"
        let lang = String(pref.prefix(while: { $0 != "-" && $0 != "_" })).lowercased()
        guard mac.appleSilicon else {
            return parakeetLanguages.contains(lang) ? "parakeet-v3-small" : "whisper-small"
        }
        if mac.memoryGB >= 16 && cohereLanguages.contains(lang) { return "cohere-transcribe" }
        return parakeetLanguages.contains(lang) ? "parakeet-v3" : "whisper-turbo"
    }

    static func humanSize(_ bytes: Int64) -> String {
        if bytes <= 0 { return "—" }
        if bytes >= 1_000_000_000 { return String(format: "%.1f GB", Double(bytes) / 1e9) }
        return String(format: "%.0f MB", Double(bytes) / 1e6)
    }

    /// Streamed so a three-gigabyte model doesn't become a three-gigabyte
    /// allocation.
    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Download state

    private var progress: [String: Double] = [:]
    private var failures: [String: String] = [:]
    private var jobs: [String: DownloadJob] = [:]
    private var resumable: [String: Data] = [:]

    /// The Models pane reads exactly this shape — the same keys the old HTTP
    /// server answered /models with, so the table rendering never had to change.
    func rows() -> [[String: Any]] {
        LOCAL_CATALOG.map { entry in
            var row: [String: Any] = [
                "id": entry.id,
                "name": entry.name,
                "detail": entry.detail,
                // The pane dims what can't stream when Live is on, the same
                // way the paid lists do.
                "streams": entry.family.streams,
                "installed": isInstalled(entry),
                "downloading": jobs[entry.id] != nil,
                "progress": (progress[entry.id] ?? 0) * 100,
            ]
            if let err = failures[entry.id] { row["error"] = err }
            return row
        }
    }

    func download(_ id: String) {
        guard let entry = Self.entry(id), jobs[id] == nil else { return }
        failures[id] = nil
        progress[id] = 0
        Config.shared.log("Local model download started: \(id) (\(Self.humanSize(entry.bytes)))")
        jobs[id] = DownloadJob(
            entry: entry, destination: Self.path(for: entry), resuming: resumable[id],
            onProgress: { [weak self] fraction in
                DispatchQueue.main.async { self?.progress[id] = fraction }
            },
            onFinish: { [weak self] error in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.jobs[id] = nil
                    self.progress[id] = nil
                    if let error = error {
                        self.failures[id] = error.localizedDescription
                        // Stale resume data fails the same way every time, so
                        // Retry starts clean rather than replaying the fault.
                        self.resumable[id] = nil
                        Config.shared.log("Local model download failed: \(id) — \(error.localizedDescription)")
                        return
                    }
                    self.resumable[id] = nil
                    Config.shared.log("Local model installed: \(id)")
                    // First model in gets to be the one in use, so a fresh
                    // install is usable without a second click.
                    let current = Config.shared.model(for: .local)
                    if Self.entry(current).map({ !self.isInstalled($0) }) ?? true {
                        Config.shared.set(Provider.local.modelVar, id)
                    }
                }
            })
    }

    /// Multi-gigabyte downloads need a way out that isn't force-quitting. The
    /// bytes already fetched are kept, so pressing Download again resumes.
    func cancel(_ id: String) {
        guard let job = jobs[id] else { return }
        jobs[id] = nil
        progress[id] = nil
        job.cancel { [weak self] data in
            DispatchQueue.main.async { self?.resumable[id] = data }
        }
        Config.shared.log("Local model download cancelled: \(id)")
    }

    /// Returns a message on refusal, nil on success — the pane shows whatever
    /// comes back rather than guessing why a delete did nothing.
    @discardableResult
    func delete(_ id: String) -> String? {
        guard let entry = Self.entry(id) else { return "Unknown model." }
        if jobs[id] != nil { return "Still downloading — cancel it first." }
        // Drop it out of memory before the file goes, or whisper.cpp keeps
        // mapped pages alive against something that no longer exists.
        if runner?.modelID == id { runner = nil }
        do {
            try FileManager.default.removeItem(at: Self.path(for: entry))
        } catch CocoaError.fileNoSuchFile {
            // Already gone — fall through so the selection is tidied anyway.
        } catch {
            return error.localizedDescription
        }
        resumable[id] = nil
        Config.shared.log("Local model deleted: \(id)")
        // Don't leave the provider pointed at something that is no longer here.
        if Config.shared.model(for: .local).hasPrefix(id) {
            Config.shared.set(Provider.local.modelVar, installedIDs().first)
        }
        return nil
    }

    // MARK: Transcription

    private var runner: LocalRunner?

    /// Which model is actually in memory, which is not always the one named in
    /// settings — a stale or deleted id falls back to whatever is installed.
    var loadedModelID: String? { runner?.modelID }

    /// ggml narrates every Metal pipeline it compiles, straight to stderr.
    /// That is useful in a terminal and noise in a menu-bar app. (Cohere has
    /// no log hook; its own chatter is switched off per context with
    /// `verbosity = 0`, and the ggml underneath it is the same one as here.)
    private static var silenced = false
    static func silenceEngineLogs() {
        guard !silenced else { return }
        silenced = true
        let quiet: @convention(c) (ggml_log_level, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
            = { _, _, _ in }
        whisper_log_set(quiet, nil)
        parakeet_log_set(quiet, nil)
    }

    /// The server-era ids ("parakeet-tdt-0.6b-v2", "whisper-large-v3" as the
    /// server spelled it) do not exist in this catalogue. Left in place they
    /// leave the Models list with nothing marked in use, so an unrecognised
    /// selection is dropped once and the default takes over.
    func migrateSelection() {
        guard let saved = Config.shared.env()[Provider.local.modelVar], !saved.isEmpty,
              Self.entry(saved) == nil else { return }
        Config.shared.set(Provider.local.modelVar, bestInstalledID())
        Config.shared.log("Local model id '\(saved)' is no longer in the catalogue — selection reset")
    }

    /// Drop the model out of memory. Called before the app exits: ggml's Metal
    /// device is torn down by a C++ static destructor at exit, and a context
    /// still holding it crashes on the way out.
    func unload() {
        runner = nil
        vadLock.lock()
        if let vad = vad { whisper_vad_free(vad) }
        vad = nil
        vadTried = false
        vadLock.unlock()
    }

    /// The model this dictation will use. A stale or deleted selection falls
    /// back to whatever is installed rather than failing outright.
    func selectedEntry() -> LocalCatalogEntry? {
        let wanted = Config.shared.model(for: .local)
        return Self.entry(wanted).flatMap { isInstalled($0) ? $0 : nil }
            ?? bestInstalledID().flatMap(Self.entry)
    }

    /// Load the selected model ahead of time. Measured cold, the first pass
    /// spends over seven seconds mapping weights — in the live path that is
    /// seven seconds of empty preview at the start of an utterance, so the
    /// load is moved off the critical path entirely.
    func warmUp() {
        guard Config.shared.provider == .local, runner == nil, !warming,
              let entry = selectedEntry() else { return }
        warming = true
        Self.silenceEngineLogs()
        let path = Self.path(for: entry).path
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let loaded = try? LocalRunner(path: path, modelID: entry.id, family: entry.family)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.warming = false
                // A real transcription may have loaded something else while
                // this was in flight; it wins.
                guard self.runner == nil, let loaded = loaded else { return }
                self.runner = loaded
                Config.shared.log("Local model pre-loaded: \(entry.id)")
                loaded.prime()
                self.timeIfNeeded()
            }
        }
    }

    private var warming = false

    /// Which model this dictation will actually use, loading it if needed.
    private func ready() throws -> (LocalRunner, LocalCatalogEntry) {
        guard let entry = selectedEntry() else {
            throw NSError(domain: "SayCtrl", code: 14, userInfo: [
                NSLocalizedDescriptionKey:
                    "No local model downloaded — pick one in Settings › Models."])
        }
        // Loading a multi-gigabyte model takes a moment, so it is done once and
        // kept; choosing a different model is what evicts the old one.
        Self.silenceEngineLogs()
        if runner?.modelID != entry.id {
            runner = try LocalRunner(path: Self.path(for: entry).path,
                                     modelID: entry.id, family: entry.family)
            Config.shared.log("Local model loaded: \(entry.id)")
            runner?.prime()
            DispatchQueue.main.async { self.timeIfNeeded() }
        }
        guard let runner = runner else {
            throw NSError(domain: "SayCtrl", code: 15, userInfo: [
                NSLocalizedDescriptionKey: "Local engine failed to load."])
        }
        return (runner, entry)
    }

    /// The batch dictation path's whole interface to local inference.
    func transcribe(_ url: URL) async throws -> String {
        try await transcribe(samples: Self.samples(from: url))
    }

    /// One clip through one named model — the Recent list's "transcribe again
    /// with…". The dictation model stays resident: an unselected pick gets its
    /// own short-lived runner rather than evicting the warm one, so trying a
    /// comparison doesn't cost the next hold-to-talk a multi-gigabyte reload.
    func transcribe(_ url: URL, modelID: String) async throws -> String {
        guard let entry = Self.entry(modelID), isInstalled(entry) else {
            throw NSError(domain: "SayCtrl", code: 18, userInfo: [
                NSLocalizedDescriptionKey:
                    "That model isn’t downloaded — get it in Settings › Models."])
        }
        let samples = try Self.samples(from: url)
        guard worthDecoding(samples) else { return "" }
        let hint = Self.hint(for: entry.family)
        if let resident = runner, resident.modelID == entry.id {
            return try await resident.transcribe(samples, prompt: hint)
        }
        Self.silenceEngineLogs()
        let path = Self.path(for: entry).path
        let solo = try await Task.detached(priority: .userInitiated) {
            try LocalRunner(path: path, modelID: entry.id, family: entry.family)
        }.value
        Config.shared.log("Local model loaded for a one-off pass: \(entry.id)")
        return try await solo.transcribe(samples, prompt: hint)
    }

    /// The live path already holds the audio in memory and re-feeds the whole
    /// utterance on every pass, so it hands over samples directly — and the
    /// previous pass's text as the draft.
    func transcribe(samples: [Float], draft: String = "") async throws -> String {
        let (runner, entry) = try ready()
        guard worthDecoding(samples) else { return "" }
        let hint = Self.hint(for: entry.family)
        return try await runner.transcribe(samples, prompt: hint, draft: draft)
    }

    // MARK: Fed as the audio arrives

    /// Whether this take's model is fed piece by piece rather than re-run.
    var streamsNatively: Bool { selectedEntry()?.family.streamsNatively ?? false }

    func streamStart() async throws {
        let (runner, _) = try ready()
        try await runner.streamOpen()
    }

    func streamFeed(_ chunk: [Float]) async throws -> String {
        let (runner, _) = try ready()
        return try await runner.streamFeed(chunk)
    }

    /// Key-up. The VAD gets the same say over the whole take that it has on
    /// a replayed one: a tap with nothing said pastes nothing, rather than
    /// the "Yeah." a model reads into room tone.
    func streamFinish(_ tail: [Float], all: [Float]) async throws -> String {
        let (runner, _) = try ready()
        let text = try await runner.streamFinish(tail)
        return worthDecoding(all) ? text : ""
    }

    func streamCancel() { runner?.streamCancel() }

    // MARK: Speed on this Mac

    private var timing: Set<String> = []

    /// Times the loaded model once on this Mac (LocalSpeed), in the
    /// background, the first time it is loaded. A few seconds of compute,
    /// queued behind anything already running on it; skipped while a take
    /// is streaming and tried again at the next load.
    func timeIfNeeded() {
        guard let runner = runner, let entry = Self.entry(runner.modelID), entry.family.streams,
              !LocalSpeed.shared.isMeasured(entry.id), !timing.contains(entry.id) else { return }
        timing.insert(entry.id)
        Task.detached(priority: .utility) {
            let seconds = await LocalEngine.time(runner, entry)
            DispatchQueue.main.async { LocalEngine.shared.timing.remove(entry.id) }
            _ = seconds
        }
    }

    /// Times the loaded model now, whether or not it has been, and records
    /// it — `--localbench` asks for this. nil when nothing is loaded.
    func timeLoaded() async -> Double? {
        guard let runner = runner, let entry = Self.entry(runner.modelID), entry.family.streams else { return nil }
        return await Self.time(runner, entry)
    }

    private static func time(_ runner: LocalRunner, _ entry: LocalCatalogEntry) async -> Double? {
        guard let clip = LocalSpeed.benchmarkClip(),
              let seconds = (try? await runner.benchmark(clip)).flatMap({ $0 }) else { return nil }
        DispatchQueue.main.async {
            LocalSpeed.shared.record(entry.id, seconds: seconds, native: entry.family.streamsNatively)
        }
        return seconds
    }

    /// Key-up: a live pass still running is stopped between tokens, so the
    /// final pass is not queued behind it. Only Qwen3 has a pass long enough
    /// to matter (a second or two on a long take); the others finish first.
    func abortLivePass() {
        guard runner?.family == .qwen3 else { return }
        sayctrl_qwen3_abort()
    }

    // MARK: Voice activity

    /// Whether a clip is worth putting through the model. The VAD decides —
    /// except for a clip that is both long and loud, which always decodes.
    ///
    /// The VAD's job is the accidental tap on fn: decoding half a second of
    /// room tone is what produces "Yeah." out of nothing, and in a quiet room
    /// it does that job well (speech at RMS 0.0005 still passes, room noise
    /// at 0.0018 is held back). What it cannot do is hear through a loud
    /// floor. Measured 2026-09-06 with the mic sitting at RMS 0.17 of steady
    /// noise: Silero's speech probability on a clear 24-second dictation
    /// peaked at 0.66 and on a clear two-second one at 0.12, against its 0.5
    /// threshold — the noise alone scored higher than the speech — while
    /// Cohere transcribed both word for word. Every "Empty transcript" on a
    /// long local take traced to that gate. So a clip held past `vadGatesBelow`
    /// seconds at a level past `vadTrustedBelowRMS` goes to the model whatever
    /// the VAD says: it was held on purpose, and the VAD is blind in that
    /// signal anyway. The cost is a hallucinated line if fn is held through
    /// silence in a room that loud — a room the VAD could not police either.
    /// Normal dictation sits at RMS 0.02–0.07, so the floor is the bottom of
    /// that range, well clear of the noise the VAD was measured against.
    static let vadGatesBelow: Double = 2.0
    static let vadTrustedBelowRMS: Float = 0.02

    private func worthDecoding(_ samples: [Float]) -> Bool {
        if speechPresent(in: samples) { return true }
        guard Double(samples.count) / 16000 >= Self.vadGatesBelow else { return false }
        return Self.rms(samples) >= Self.vadTrustedBelowRMS
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// One line for the log — what the VAD made of a clip — so a take that
    /// came back empty explains itself. Runs the detector once more, which
    /// is cheap next to the decode that follows.
    func vadSummary(_ samples: [Float]) -> String {
        vadLock.lock()
        defer { vadLock.unlock() }
        guard let vad = ensureVAD() else { return "VAD unavailable" }
        let detected = samples.withUnsafeBufferPointer { buf in
            whisper_vad_detect_speech(vad, buf.baseAddress, Int32(buf.count))
        }
        guard detected else { return "VAD failed to run" }
        var peak: Float = 0
        let count = Int(whisper_vad_n_probs(vad))
        if count > 0, let probs = whisper_vad_probs(vad) {
            peak = UnsafeMutableBufferPointer(start: probs, count: count).max() ?? 0
        }
        let params = whisper_vad_default_params()
        guard let segments = whisper_vad_segments_from_probs(vad, params) else { return "VAD failed to run" }
        defer { whisper_vad_free_segments(segments) }
        let n = Int(whisper_vad_segments_n_segments(segments))
        let found = n == 0 ? "found no speech" : "found \(n) speech segment\(n == 1 ? "" : "s")"
        return String(format: "VAD %@ (peak probability %.2f, threshold %.2f)", found, peak, params.threshold)
    }

    /// The agent voice's ear asks the same question about its rolling
    /// window — is anyone actually talking — from its own audio queue; the
    /// lock inside makes that safe next to a dictation pass.
    func speech(in samples: [Float]) -> Bool { speechPresent(in: samples) }

    private var vad: OpaquePointer?
    private var vadTried = false
    /// One VAD context, not reentrant — and the live path asks about the
    /// utterance from overlapping passes, so two threads ran the same ggml
    /// graph at once and crashed in a matrix multiply. One at a time.
    private let vadLock = NSLock()

    /// Silero VAD over the clip. Loudness alone cannot do this job — measured,
    /// speech attenuated to RMS 0.0005 still transcribes perfectly while room
    /// noise at RMS 0.0018 hallucinates, so any threshold that catches the
    /// noise also throws away a quiet speaker.
    /// Loads once; call with the lock held.
    private func ensureVAD() -> OpaquePointer? {
        if !vadTried {
            vadTried = true
            Self.silenceEngineLogs()
            if let url = Bundle.main.resourceURL?
                .appendingPathComponent("ggml-silero-v6.2.0.bin"),
               FileManager.default.fileExists(atPath: url.path) {
                var params = whisper_vad_default_context_params()
                params.n_threads = 2
                // A 0.9 MB LSTM costs more to dispatch to the GPU than to run.
                params.use_gpu = false
                vad = whisper_vad_init_from_file_with_params(url.path, params)
            }
            if vad == nil { Config.shared.log("VAD unavailable — silence filtering off") }
        }
        return vad
    }

    private func speechPresent(in samples: [Float]) -> Bool {
        vadLock.lock()
        defer { vadLock.unlock() }
        // Fail open: a missing or broken VAD must never swallow real dictation.
        guard let vad = ensureVAD() else { return true }
        let params = whisper_vad_default_params()
        guard let segments = samples.withUnsafeBufferPointer({ buf in
            whisper_vad_segments_from_samples(vad, params, buf.baseAddress, Int32(buf.count))
        }) else { return true }
        defer { whisper_vad_free_segments(segments) }
        return whisper_vad_segments_n_segments(segments) > 0
    }

    /// Whether the selected model keeps up live on this Mac — see
    /// `LocalFamily.streams` for which can at all, and LocalSpeed for which
    /// do here.
    var liveCapable: Bool {
        guard let entry = selectedEntry() else { return false }
        return LocalSpeed.shared.verdict(entry) == .live
    }


    /// whisper.cpp wants 16 kHz mono float. The recorder already writes exactly
    /// that, so the common path is a straight read; the conversion is there for
    /// anything that isn't (a migrated recording, a changed setting).
    static func samples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                         channels: 1, interleaved: false) else {
            throw NSError(domain: "SayCtrl", code: 16, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't prepare the recording for the local model."])
        }
        guard let input = AVAudioPCMBuffer(pcmFormat: source,
                                           frameCapacity: AVAudioFrameCount(file.length)) else {
            throw NSError(domain: "SayCtrl", code: 17, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't read the recording."])
        }
        try file.read(into: input)

        let buffer: AVAudioPCMBuffer
        if source.sampleRate == target.sampleRate && source.channelCount == 1 {
            buffer = input
        } else {
            guard let converter = AVAudioConverter(from: source, to: target),
                  let output = AVAudioPCMBuffer(
                    pcmFormat: target,
                    frameCapacity: AVAudioFrameCount(Double(file.length) * target.sampleRate / source.sampleRate) + 1024)
            else {
                throw NSError(domain: "SayCtrl", code: 18, userInfo: [
                    NSLocalizedDescriptionKey: "Couldn't resample the recording."])
            }
            var supplied = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true
                status.pointee = .haveData
                return input
            }
            if let error = error { throw error }
            buffer = output
        }

        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    /// whisper.cpp takes an initial prompt that biases recognition, the same
    /// job the cloud providers' `prompt` field does — so "copy file path"
    /// doesn't come back as "copy file both" here either. Built in
    /// Hints.swift, budgeted and ordered for whisper's context window.
    static func prompt() -> String { Hints.whisperPrompt() }

    /// What a model is told about the user's words before it hears them.
    /// Whisper takes its prompt; Qwen3-ASR a context of the names alone —
    /// Hints.names, real-word names like Claude included — in the
    /// comma-separated form the echo check reads back. The rest take nothing.
    static func hint(for family: LocalFamily) -> String {
        switch family {
        case .whisper: return prompt()
        case .qwen3:
            // Dev knob: try another context on the same recordings without a rebuild.
            if let ctx = ProcessInfo.processInfo.environment["SAYCTRL_QWEN3_CONTEXT"] { return ctx }
            let names = Hints.names(cap: 40).joined(separator: ", ")
            // The text before the caret, after a blank line: what was already
            // written is what the next sentence is about (TypingContext).
            let before = TypingContext.before
            guard Config.shared.flag("QWEN3_PREV_TEXT", default: true), !before.isEmpty else { return names }
            return names + "\n\n" + before
        default:       return ""
        }
    }

    // MARK: Status

    /// What the Verify button reports. There is no server to be up any more, so
    /// the honest question is whether anything is downloaded and selected.
    func status() -> (ok: Bool, message: String) {
        let installed = installedIDs()
        if installed.isEmpty {
            return (false, "No model downloaded yet — pick one below and press Download.")
        }
        let current = Config.shared.model(for: .local)
        guard let entry = Self.entry(current), isInstalled(entry) else {
            return (false, "\(installed.count) model(s) ready, but none is selected — press Use on one.")
        }
        return (true, "✓ \(entry.name) ready on this Mac — no key, no network.")
    }
}

// MARK: - The ear's own VAD

/// The agent voice's streaming voice detector: its own Silero context, fed
/// 32 ms at a time with the recurrent state carried across frames — the way
/// the model is meant to follow a live microphone. (LocalEngine's batch
/// context answers one-shot questions about finished clips; a fresh state
/// scores the opening moments of anything near zero, which is exactly when
/// the ear needs an answer.) Not thread-safe: VoiceIO's audio queue is its
/// only caller.
final class EarVAD {
    private var ctx: OpaquePointer?
    private var pending: [Float] = []

    init?() {
        guard let url = Bundle.main.resourceURL?
            .appendingPathComponent("ggml-silero-v6.2.0.bin"),
            FileManager.default.fileExists(atPath: url.path) else { return nil }
        LocalEngine.silenceEngineLogs()
        var params = whisper_vad_default_context_params()
        params.n_threads = 1
        params.use_gpu = false
        ctx = whisper_vad_init_from_file_with_params(url.path, params)
        if ctx == nil { return nil }
    }

    deinit { if let c = ctx { whisper_vad_free(c) } }

    /// Forget the room — a new listen starts from silence.
    func reset() {
        pending.removeAll()
        if let c = ctx { whisper_vad_reset_state(c) }
    }

    /// Feed converted 16 kHz mono samples. Returns the highest speech
    /// probability among the 512-sample frames this call completed, or nil
    /// when the chunk didn't fill one.
    func feed(_ chunk: [Float]) -> Float? {
        guard let c = ctx else { return nil }
        pending.append(contentsOf: chunk)
        var best: Float?
        while pending.count >= 512 {
            let frame = Array(pending.prefix(512))
            pending.removeFirst(512)
            guard frame.withUnsafeBufferPointer({ b in
                whisper_vad_detect_speech_no_reset(c, b.baseAddress, 512)
            }), whisper_vad_n_probs(c) > 0 else { continue }
            best = max(best ?? 0, whisper_vad_probs(c)[0])
        }
        return best
    }
}
