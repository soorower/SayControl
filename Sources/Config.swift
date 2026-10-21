// Everything that lives in ~/.config/sayctrl: .env settings, the log file,
// and the dictation history. Shared by the menu-bar app and the settings window.
import Cocoa
import ServiceManagement

let DEFAULT_MODEL = "openai/gpt-4o-mini-transcribe"
let OPENROUTER_URL = "https://openrouter.ai/api/v1/audio/transcriptions"
let OPENROUTER_KEY_URL = "https://openrouter.ai/api/v1/key"
let OPENAI_URL = "https://api.openai.com/v1/audio/transcriptions"
let OPENAI_KEY_URL = "https://api.openai.com/v1/models"
/// Transcription sessions take `?intent=transcription`. Passing the model as a
/// `?model=` query param instead is rejected with `invalid_model` — that param is
/// for voice-agent models only, so the model goes in the session.update payload.
let OPENAI_REALTIME_URL = "wss://api.openai.com/v1/realtime?intent=transcription"
/// ElevenLabs Scribe. The upload endpoint is OpenAI-shaped enough to share the
/// batch path (multipart, `text` in the reply), but it authenticates with its
/// own `xi-api-key` header and names the model field `model_id`.
let ELEVEN_URL = "https://api.elevenlabs.io/v1/speech-to-text"
let ELEVEN_KEY_URL = "https://api.elevenlabs.io/v1/user/subscription"
/// Scribe v2 Realtime. Unlike OpenAI's socket, every option is a query
/// parameter — there is no session.update handshake to negotiate with.
let ELEVEN_REALTIME_URL = "wss://api.elevenlabs.io/v1/speech-to-text/realtime"
/// Local has no URL of any kind: Whisper, Parakeet and Cohere run inside
/// this process via LocalEngine, so the batch path short-circuits before it ever
/// builds a request. Kept as a page to point people at when they ask where
/// the local models come from.
let LOCAL_HELP_URL = "https://saycontrol.com/#offline"
/// Single source of truth is Info.plist — the DMG is named from the same value.
let APP_VERSION = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.1"

let SUGGESTED_MODELS = [
    "microsoft/mai-transcribe-2",
    "microsoft/mai-transcribe-1.5",
    "openai/gpt-4o-transcribe",
    "openai/gpt-4o-mini-transcribe",
    "openai/whisper-1",
    "mistralai/voxtral-mini-transcribe",
    // Voxtral Mini Transcribe 2, pinned. The bare id above is an alias that
    // resolves to this build today; the dated one stays put if the alias moves.
    "mistralai/voxtral-mini-transcribe-2602",
    // Voxtral Small's transcription endpoint is the "-stt" id; the bare one is
    // the chat model, which takes audio but isn't in the transcriptions catalogue.
    "mistralai/voxtral-small-24b-2507-stt",
    "nvidia/nemotron-3.5-asr-streaming-multilingual-0.6b",
    // OpenRouter's transcription catalogue is separate from /api/v1/models and
    // only registers the DATED id — the bare "qwen/qwen3-asr-flash" alias 400s.
    "qwen/qwen3-asr-flash-2026-02-10",
]

/// Where the audio goes. OpenRouter is one key for many vendors' models; OpenAI
/// direct is the only way to reach models OpenRouter hasn't picked up yet;
/// ElevenLabs is Scribe, which OpenRouter's transcriptions catalogue doesn't
/// carry. OpenAI and ElevenLabs are the two with a realtime streaming socket.
enum Provider: String, CaseIterable {
    case openrouter, openai, elevenlabs, assemblyai, gemini, smallest, meta, xai, soniox, local, gpu

    var title: String {
        switch self {
        case .openrouter: return "OpenRouter"
        case .openai:     return "OpenAI"
        case .elevenlabs: return "ElevenLabs"
        case .assemblyai: return "AssemblyAI"
        case .gemini:     return "Google"
        case .smallest:   return "Smallest.ai"
        case .meta:       return "Meta"
        case .xai:        return "xAI"
        case .soniox:     return "Soniox"
        case .local:      return "Local"
        case .gpu:        return "Own GPU"
        }
    }
    var keyVar: String {
        switch self {
        case .openrouter: return "OPENROUTER_API_KEY"
        case .openai:     return "OPENAI_API_KEY"
        case .elevenlabs: return "ELEVENLABS_API_KEY"
        case .assemblyai: return "ASSEMBLYAI_API_KEY"
        case .gemini:     return "GEMINI_API_KEY"
        case .smallest:   return "SMALLEST_API_KEY"
        case .meta:       return "META_API_KEY"
        case .xai:        return "XAI_API_KEY"
        case .soniox:     return "SONIOX_API_KEY"
        case .local:      return "LOCAL_API_KEY"
        case .gpu:        return "GPU_API_KEY"
        }
    }
    var modelVar: String {
        switch self {
        case .openrouter: return "MODEL"
        case .openai:     return "OPENAI_MODEL"
        case .elevenlabs: return "ELEVENLABS_MODEL"
        case .assemblyai: return "ASSEMBLYAI_MODEL"
        case .gemini:     return "GEMINI_MODEL"
        case .smallest:   return "SMALLEST_MODEL"
        case .meta:       return "META_MODEL"
        case .xai:        return "XAI_MODEL"
        case .soniox:     return "SONIOX_MODEL"
        case .local:      return "LOCAL_MODEL"
        case .gpu:        return "GPU_MODEL"
        }
    }
    var keyPlaceholder: String {
        switch self {
        case .openrouter: return "sk-or-v1-…"
        case .openai:     return "sk-…"
        case .elevenlabs: return "sk_…"
        case .assemblyai: return "32-character key"
        case .gemini:     return "AIza… or AQ.…"
        case .smallest:   return "key from app.smallest.ai"
        case .meta:       return "LLM_…"
        case .xai:        return "xai-…"
        case .soniox:     return "snx_…"
        case .local:      return "no key needed"
        case .gpu:        return "no key needed"
        }
    }
    /// Empty for a live-only provider — `transcribe()` refuses before it ever
    /// builds a URL, so there is nothing to point at here.
    var transcriptionsURL: String {
        switch self {
        case .openrouter: return OPENROUTER_URL
        case .openai:     return OPENAI_URL
        case .elevenlabs: return ELEVEN_URL
        case .assemblyai: return ""
        case .gemini:     return ""
        case .smallest:   return SMALLEST_URL
        case .meta:       return ""
        case .xai:        return XAI_URL
        case .soniox:     return ""
        // Never used: transcribe() hands local recordings to LocalEngine
        // before it looks at this.
        case .local:      return ""
        case .gpu:        return ""
        }
    }
    var keysPage: String {
        switch self {
        case .openrouter: return "https://openrouter.ai/settings/keys"
        case .openai:     return "https://platform.openai.com/api-keys"
        case .elevenlabs: return "https://elevenlabs.io/app/settings/api-keys"
        case .assemblyai: return "https://www.assemblyai.com/app/api-keys"
        case .gemini:     return "https://aistudio.google.com/apikey"
        case .smallest:   return "https://app.smallest.ai/dashboard/api-keys"
        case .meta:       return "https://dev.meta.ai/"
        case .xai:        return "https://console.x.ai/"
        case .soniox:     return "https://console.soniox.com/"
        case .local:      return LOCAL_HELP_URL
        case .gpu:        return GPU_HELP_URL
        }
    }

    /// ElevenLabs and Google take a bare key in their own headers, AssemblyAI a
    /// bare key in the standard one — none of them wants a "Bearer" prefix, and
    /// sending one is rejected. Both the upload and the realtime socket use this.
    var authHeaderName: String {
        switch self {
        case .elevenlabs: return "xi-api-key"
        case .gemini:     return "x-goog-api-key"
        default:          return "Authorization"
        }
    }
    func authHeaderValue(_ key: String) -> String {
        switch self {
        case .elevenlabs, .assemblyai, .gemini: return key
        default:                                return "Bearer \(key)"
        }
    }

    /// The multipart field the transcriptions endpoint reads the model from.
    var modelField: String { self == .elevenlabs ? "model_id" : "model" }

    var defaultModel: String {
        switch self {
        case .openrouter: return DEFAULT_MODEL
        case .openai:     return "gpt-4o-mini-transcribe"
        case .elevenlabs: return "scribe_v2"
        case .assemblyai: return ASSEMBLY_LIVE_MODEL
        case .gemini:     return GEMINI_LIVE_MODEL
        case .smallest:   return SMALLEST_LIVE_MODEL
        case .meta:       return META_LIVE_MODEL
        case .xai:        return XAI_LIVE_MODEL
        case .soniox:     return SONIOX_LIVE_MODEL
        // Turbo is the one to land on cold: large-v3 accuracy without the
        // large-v3 wait, and it covers every language the others do.
        case .local:      return "whisper-large-v3-turbo"
        case .gpu:        return GPU_LIVE_MODEL
        }
    }

    var suggestedModels: [String] {
        switch self {
        case .openrouter: return SUGGESTED_MODELS
        case .openai:     return ["gpt-4o-transcribe", "gpt-4o-mini-transcribe", "whisper-1"]
        case .elevenlabs: return ["scribe_v2", "scribe_v1"]
        case .assemblyai: return ASSEMBLY_LIVE_MODELS
        case .gemini:     return GEMINI_LIVE_MODELS
        case .smallest:   return ["pulse", "pulse-pro"]
        case .meta:       return META_LIVE_MODELS
        case .xai:        return XAI_LIVE_MODELS
        case .soniox:     return SONIOX_LIVE_MODELS
        // The whole catalogue; the settings pane narrows this to whatever is
        // actually downloaded as soon as one of them is.
        case .local:      return LOCAL_CATALOG.map(\.id)
        case .gpu:        return [GPU_LIVE_MODEL]
        }
    }

    // MARK: Live (streaming) transcription

    /// Only these have a realtime socket, so the Live toggle is hidden
    /// elsewhere rather than sitting there as a switch that does nothing.
    var supportsLive: Bool {
        self == .openai || self == .elevenlabs || self == .assemblyai || self == .gemini
            || self == .smallest || self == .meta || self == .xai || self == .soniox || self == .local
            || self == .gpu
    }

    /// AssemblyAI has no upload path here at all, so live isn't a preference —
    /// it is the only way this provider works. The toggle is hidden and
    /// `liveEnabled` ignores the flag rather than letting you switch dictation
    /// off by accident. Google's upload path is a two-step Files-then-
    /// Interactions flow that would add seconds, so it is live-only too.
    /// Meta's upload endpoint is its own multipart shape (a JSON `request`
    /// part beside the WAV) that nothing here speaks yet, so it joins them.
    /// Soniox uploads are an upload-then-create-then-poll job on a separate
    /// async model, so it streams only too. Our own GPU is a socket only:
    /// Nemotron needs the audio as it is spoken.
    var liveOnly: Bool { self == .assemblyai || self == .gemini || self == .meta || self == .soniox || self == .gpu }

    /// Live keeps its own model slot per provider, for the same reason the batch
    /// models do: a realtime-only name would break the upload path if it leaked
    /// into the batch setting.
    var liveModelVar: String {
        switch self {
        case .elevenlabs: return "ELEVENLABS_LIVE_MODEL"
        case .assemblyai: return "ASSEMBLYAI_LIVE_MODEL"
        case .gemini:     return "GEMINI_LIVE_MODEL"
        case .smallest:   return "SMALLEST_LIVE_MODEL"
        case .meta:       return "META_LIVE_MODEL"
        case .xai:        return "XAI_LIVE_MODEL"
        case .soniox:     return "SONIOX_LIVE_MODEL"
        case .local:      return "LOCAL_MODEL"
        case .gpu:        return "GPU_LIVE_MODEL"
        default:          return "LIVE_MODEL"
        }
    }

    var defaultLiveModel: String {
        switch self {
        case .elevenlabs: return ELEVEN_LIVE_MODEL
        case .assemblyai: return ASSEMBLY_LIVE_MODEL
        case .gemini:     return GEMINI_LIVE_MODEL
        case .smallest:   return SMALLEST_LIVE_MODEL
        case .meta:       return META_LIVE_MODEL
        case .xai:        return XAI_LIVE_MODEL
        case .soniox:     return SONIOX_LIVE_MODEL
        case .local:      return defaultModel
        case .gpu:        return GPU_LIVE_MODEL
        default:          return LIVE_MODEL
        }
    }

    var liveModels: [String] {
        switch self {
        case .elevenlabs: return ELEVEN_LIVE_MODELS
        case .assemblyai: return ASSEMBLY_LIVE_MODELS
        case .gemini:     return GEMINI_LIVE_MODELS
        case .smallest:   return SMALLEST_LIVE_MODELS
        case .meta:       return META_LIVE_MODELS
        case .xai:        return XAI_LIVE_MODELS
        case .soniox:     return SONIOX_LIVE_MODELS
        case .local:      return LOCAL_CATALOG.map(\.id)
        case .gpu:        return [GPU_LIVE_MODEL]
        default:          return LIVE_MODELS
        }
    }

    /// What the socket wants the mic resampled to. Scribe, Universal and
    /// Gemini all run at 16 kHz natively, so sending more is bandwidth for
    /// nothing; OpenAI and Meta both ask for 24 kHz.
    var liveSampleRate: Double {
        self == .openai || self == .meta ? LIVE_SAMPLE_RATE : 16000
    }

    /// Smallest audio frame worth sending. AssemblyAI asks for 50 ms or more,
    /// Google recommends ~100 ms, smallest.ai recommends ~4 KB chunks, Meta's
    /// own example sends 80 ms, xAI's sends 100 ms, and our mic tap produces
    /// about 43 ms, so their frames are coalesced.
    var liveMinChunkBytes: Int? {
        self == .assemblyai || self == .gemini || self == .smallest || self == .meta
            || self == .xai || self == .gpu
            ? Int(liveSampleRate * 0.1) * 2 : nil
    }

    /// How long to wait for the last of the text after you release fn. Measured:
    /// AssemblyAI's closing turn lands 1–1.5 s after `Terminate`, and its last
    /// partial is often wrong where the final is right, so it gets more room.
    /// Gemini's closing final lands right behind `audioStreamEnd` (measured
    /// 2026-08-27), but this is also its only net for a slow one — the socket
    /// has no Termination-style goodbye to fall back on. Meta's final lands
    /// 0.3–0.5 s behind `endStream` (measured 2026-09-02) — but its handshake
    /// takes 1.5–2 s to be acknowledged, a short command is released before
    /// that, and `endStream` can't go out until it is: the net has to cover
    /// the rest of the handshake as well as the final.
    var liveGrace: TimeInterval {
        switch self {
        case .assemblyai: return 3.0
        case .gemini:     return 2.5
        case .meta:       return 3.0
        // Only a net: the final message ends the take. It has to cover Qwen3
        // on a long take plus the round trip to the pod (~0.26 s from here).
        case .gpu:        return 6.0
        default:          return 2.0
        }
    }
}

// MARK: - Live (streaming) transcription

/// Streams transcript deltas over a WebSocket while you are still talking,
/// instead of uploading a finished clip. OpenAI-only — OpenRouter has no
/// realtime endpoint.
let LIVE_MODEL = "gpt-live-transcribe"
/// The transcription intent accepts ONLY transcription models — the socket
/// rejects voice-agent models (gpt-realtime-2.1 etc.) with invalid_value, so
/// they don't belong here no matter what the pricing page groups them with.
let LIVE_MODELS = ["gpt-live-transcribe", "gpt-transcribe", "gpt-4o-transcribe", "gpt-4o-mini-transcribe", "gpt-realtime-whisper"]
/// The realtime session speaks 24 kHz mono PCM16 both ways.
let LIVE_SAMPLE_RATE: Double = 24000

/// AssemblyAI streams over a v3 socket that takes RAW BINARY PCM frames, not
/// base64 in JSON, and ends on a `Terminate` message rather than a commit.
/// Their upload API is a three-step upload/create/poll flow, which would add
/// seconds to a dictation, so this provider is live-only in SayCtrl.
let ASSEMBLY_REALTIME_URL = "wss://streaming.assemblyai.com/v3/ws"
let ASSEMBLY_KEY_URL = "https://api.assemblyai.com/v2/transcript?limit=1"
/// The only speech_model this account can open — every other candidate id the
/// docs and blog mention is refused, so don't list them speculatively.
let ASSEMBLY_LIVE_MODEL = "universal-3-5-pro"
let ASSEMBLY_LIVE_MODELS = [ASSEMBLY_LIVE_MODEL]

/// ElevenLabs' streaming models. The socket refuses anything else — including
/// the batch `scribe_v2`. It also serves a `scribe_v2_realtime_lite`, left out
/// on purpose: it is gated per workspace ("not available for this workspace"),
/// so listing it would offer a model most accounts cannot open.
let ELEVEN_LIVE_MODEL = "scribe_v2_realtime"
let ELEVEN_LIVE_MODELS = ["scribe_v2_realtime", "scribe_v2_realtime_turbo"]

/// Gemini 3.5 Transcribe Live rides Google's Live API socket: a `setup`
/// message opens the session, audio goes out base64'd in `realtimeInput`
/// envelopes, and transcripts come back as JSON in BINARY frames. The key
/// travels in the `x-goog-api-key` header (measured working 2026-08-27), so
/// nothing secret ever rides the URL. Sessions cap out at 10 minutes.
let GEMINI_REALTIME_URL = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
/// Listing models is the cheapest call that actually authenticates.
let GEMINI_KEY_URL = "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1"
let GEMINI_LIVE_MODEL = "gemini-3.5-transcribe-live"
let GEMINI_LIVE_MODELS = [GEMINI_LIVE_MODEL]

/// smallest.ai Pulse. The upload endpoint takes the RAW WAV BYTES as the whole
/// body — no multipart envelope — with the model in the query string, and
/// answers with `transcription` rather than `text`. The realtime socket is
/// ElevenLabs-shaped (every option a query parameter, no handshake) but reads
/// RAW BINARY PCM frames like AssemblyAI, and ends on a `close_stream` message
/// answered by a final marked `is_last`. Docs: docs.smallest.ai.
let SMALLEST_URL = "https://api.smallest.ai/waves/v1/stt/"
let SMALLEST_REALTIME_URL = "wss://api.smallest.ai/waves/v1/stt/live"
/// There is no account endpoint this key can read, and the API refuses GET
/// outright — so the key check is the STT endpoint itself, POSTed with an
/// empty body: a bad key is refused with 401 before the body is looked at.
let SMALLEST_KEY_URL = "https://api.smallest.ai/waves/v1/stt/?model=pulse"
/// pulse streams and uploads; pulse-pro is upload-only, so it stays out of
/// the live list.
let SMALLEST_LIVE_MODEL = "pulse"
let SMALLEST_LIVE_MODELS = [SMALLEST_LIVE_MODEL]

/// Meta's Muse Voice Transcribe. The client speaks first, like Google: the
/// first text frame is the handshake, and the key rides INSIDE it as
/// `authorization.accessToken` — the socket upgrade itself is accepted for
/// anyone, and a bad key comes back as an in-band `error` event
/// (`errorCode: invalid_api_key`). The server answers a good one with a bare
/// `{sessionId}`. Audio goes as RAW BINARY PCM frames, 24 kHz preferred, and
/// the stream ends on `endStream`. PUSH_TO_TALK is the dictation shape: one
/// rolling cumulative transcript, then the same text marked `final` 0.3–0.5 s
/// behind `endStream` (measured 2026-09-02). ENDPOINTING instead chops the
/// take into VAD turns that arrive unpunctuated as `speechComplete`, with an
/// EMPTY closing final — not what a paste wants. The upload endpoint is
/// multipart with a JSON `request` part beside the WAV: its own shape, not
/// wired, so the provider is live-only here. Docs: dev.meta.ai/docs.
let META_REALTIME_URL = "wss://api.meta.ai/v1/asr/realtime"
/// Listing models is the cheapest call that authenticates, and it answers in
/// OpenAI's shape, so the key check shares OpenAI's branch.
let META_KEY_URL = "https://api.meta.ai/v1/models"
let META_LIVE_MODEL = "muse-voice-transcribe-1.0"
let META_LIVE_MODELS = [META_LIVE_MODEL]

/// xAI's Grok Voice Transcribe. Both paths are plain: the upload is an
/// OpenAI-shaped multipart POST answering with `text`, and the realtime
/// socket configures entirely in the URL like ElevenLabs while reading RAW
/// BINARY PCM frames like AssemblyAI. Transcripts come back as
/// `transcript.partial` events SEGMENTED BY THEIR `start` OFFSET — a rolling
/// partial per segment, closed by `is_final` — and the stream ends on
/// `audio.done`, answered by a `transcript.done` whose text is ALWAYS EMPTY
/// (measured 2026-09-19). So the segments themselves are the dictation: they
/// accumulate here like AssemblyAI's turns rather than waiting for a closing
/// summary that never comes.
///
/// `format` (spoken numbers and currency written out) is deliberately left
/// off: the API refuses it with "Field 'language' is required when 'format'
/// is true", and pinning a language would cost the code-switching a
/// bilingual dictation depends on. Polish does that job downstream anyway.
/// Docs: docs.x.ai/developers/model-capabilities/audio.
let XAI_URL = "https://api.x.ai/v1/stt"
let XAI_REALTIME_URL = "wss://api.x.ai/v1/stt"
/// The one endpoint that answers for the KEY rather than for the models it
/// can reach: its name, its scopes, and whether it or the team is blocked.
let XAI_KEY_URL = "https://api.x.ai/v1/api-key"
/// 2.0 is the one worth defaulting to — xAI puts it at twice 1.0's accuracy
/// for the same $0.10/hour — but 1.0 stays listed as something to fall back
/// to and to measure against.
let XAI_LIVE_MODEL = "grok-voice-transcribe-2.0"
let XAI_LIVE_MODELS = [XAI_LIVE_MODEL, "grok-voice-transcribe-1.0"]

/// Soniox. The client speaks first, like Meta: the first text frame is the
/// config, key included (`api_key`), and nothing answers it — the socket
/// being open is the go-ahead, and a bad key or config comes back in-band as
/// `{error_code, error_message}` before the socket closes. Audio goes as RAW
/// BINARY PCM frames. Every response carries TOKENS, not text: the final ones
/// are said once and never again, so they append; the non-final ones are the
/// whole provisional tail each time, so they replace. Tokens carry their own
/// leading spaces. The take ends on ~200 ms of silence and a `finalize`
/// (their guidance), answered by a `<fin>` token once every token is final —
/// measured 0.47 s after key-up (2026-09-29). Billing runs for as long as the
/// socket is open, so the session closes the moment `<fin>` lands.
/// Docs: soniox.com/docs/stt/api-reference/websocket-api.
let SONIOX_REALTIME_URL = "wss://stt-rt.soniox.com/transcribe-websocket"
/// Lists the models the key can reach — the key check, with a Bearer header.
let SONIOX_KEY_URL = "https://api.soniox.com/v1/models"
/// The older real-time ids (stt-rt-v3, -v4, -preview) are all aliases of
/// v5 now, so there is only one model to offer.
let SONIOX_LIVE_MODEL = "stt-rt-v5"
/// Our own GPU (gpu-server/ in this repo): Nemotron Speech Streaming writes the
/// live text, Qwen3-ASR 1.7B with your names writes the final text at key-up.
/// The gateway listens on the pod's 127.0.0.1 only; gpu-server/tunnel.sh
/// forwards it here. GPU_URL in the settings file points elsewhere.
let GPU_LIVE_MODEL = "nemotron-live+qwen3-final"
let GPU_DEFAULT_URL = "ws://127.0.0.1:8765/v1/listen"
let GPU_HELP_URL = "https://www.runpod.io/console/pods"
let SONIOX_LIVE_MODELS = [SONIOX_LIVE_MODEL]

// MARK: - AI polish (LLM transcript cleanup — see Refine.swift)

/// Polish requests go to Cerebras for the sub-half-second round-trips the
/// paste deadline depends on — directly with a Cerebras key (csk-…), else
/// through OpenRouter's chat endpoint pinned Cerebras-first.
let OPENROUTER_CHAT_URL = "https://openrouter.ai/api/v1/chat/completions"
let CEREBRAS_CHAT_URL = "https://api.cerebras.ai/v1/chat/completions"
/// A tiny authenticated endpoint for the pre-dictation TLS warm-up.
let CEREBRAS_MODELS_URL = "https://api.cerebras.ai/v1/models"
/// What to assume Cerebras allows per minute until a reply's headers say
/// otherwise. Their free tier is 5, and assuming nothing — the old behaviour —
/// left the rate predictor switched off until a request survived long enough
/// to read a header, which under load is exactly the request that doesn't.
let CEREBRAS_DEFAULT_RPM = 5
let REFINE_DEFAULT_MODEL = "openai/gpt-oss-120b"

extension Notification.Name {
    static let owSettingsChanged = Notification.Name("sayctrl.settingsChanged")
    static let owRulesChanged    = Notification.Name("sayctrl.rulesChanged")
    static let owPhrasesChanged  = Notification.Name("sayctrl.phrasesChanged")
    static let owHistoryChanged  = Notification.Name("sayctrl.historyChanged")
    /// Settings flipped "hide the pill when idle" — the pill picks it up live.
    static let sayctrlPillAutoHideChanged = Notification.Name("sayctrlPillAutoHideChanged")
}

final class Config {
    static let shared = Config()

    let dir: URL

    /// Where the signed-in account's own things are kept: its history,
    /// recordings, daily totals, insights, dictionary, phrases and rules,
    /// in accounts/<user id> under `dir`. A second account on the same Mac
    /// never sees the first one's. Settings, keys, the log and the agents'
    /// sessions stay in `dir`: they belong to the Mac. Nobody signed in, or a
    /// build without accounts, uses `dir` itself.
    private(set) var dataDir: URL

    /// The bundle id this copy runs under. The dev build is
    /// com.sayctrl.app.dev: a different app to macOS, Spotlight and the
    /// privacy database, so it can sit next to the shipping one without the
    /// two being mistaken for each other.
    static let bundleID = Bundle.main.bundleIdentifier ?? "com.sayctrl.app"
    static var isDev: Bool { bundleID.hasSuffix(".dev") }

    /// The user-facing build: the shipping SayCtrl.app, as against the
    /// developers' "SayCtrl Dev". A user never meets a provider or a key: they
    /// sign in, and SayControl's cloud plan (Free, or Pro) does the listening
    /// and the polish through api.saycontrol.com; this Mac's model is the
    /// other way, free.
    /// The dev build keeps every provider and every key box, so the models
    /// can be checked against each other.
    /// SAYCTRL_RETAIL=1 previews the user-facing app in the dev build. Only
    /// the dev build listens to it: a shipping copy is the user-facing app
    /// whatever its environment says, so nothing outside it can unlock the
    /// providers and key boxes compiled into it.
    static let retail: Bool = {
        guard isDev else { return true }
        return ProcessInfo.processInfo.environment["SAYCTRL_RETAIL"] == "1"
    }()

    private init() {
        // The dev build keeps its own settings too, so a fresh-install test of
        // the shipping copy never sees the developer's keys and history.
        dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(Config.isDev ? ".config/sayctrl-dev" : ".config/sayctrl", isDirectory: true)
        if !Config.isDev { Config.migrateLegacyDirectory(into: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Config.seedDefaults(in: dir)
        dataDir = dir
        if Account.available, let id = env()["ACCOUNT_ID"], let own = accountDir(id) { dataDir = own }
    }

    // MARK: - Each account's own folder

    /// The files that are the account's rather than the Mac's.
    private static let accountFiles = ["history.json", "recordings", "stats.json", "controls.json",
                                       "replacements.json", "phrases.json", "custom-rules.txt"]

    private var accountsDir: URL { dir.appendingPathComponent("accounts", isDirectory: true) }

    /// An account has signed in here since accounts got their own folders.
    var hasAccountFolders: Bool { FileManager.default.fileExists(atPath: accountsDir.path) }

    /// A server id is a UUID; anything else is refused rather than trusted as a path.
    private func accountDir(_ id: String) -> URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        return accountsDir.appendingPathComponent(id.lowercased(), isDirectory: true)
    }

    /// Points every store at this account's folder (nil: nobody signed in)
    /// and reloads them, so the screens show only its own. Main queue.
    func useAccount(_ id: String?) {
        let next = Account.available ? id.flatMap(accountDir) ?? dir : dir
        guard next != dataDir else { return }
        if next != dir {
            claimLegacyData(into: next)
            try? FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
        }
        ClipPlayer.shared.stop()
        dataDir = next
        log("Account data: \(next == dir ? "nobody signed in" : "now the signed-in account's own")")
        CustomRules.reload()
        PhraseStore.shared.load()
        ReplacementStore.shared.load()
        ControlStats.shared.reload()
        HistoryStore.shared.reload()
        StatsStore.shared.reload()
        NotificationCenter.default.post(name: .owRulesChanged, object: nil)
        NotificationCenter.default.post(name: .owPhrasesChanged, object: nil)
    }

    /// Builds before accounts kept one set of everything beside the settings.
    /// It goes to the first account to sign in on this Mac after the update,
    /// which is the person who was using it; a Mac that already has an
    /// account folder has nothing left to hand out.
    private func claimLegacyData(into folder: URL) {
        let fm = FileManager.default
        let existing = (try? fm.contentsOfDirectory(atPath: accountsDir.path)) ?? []
        guard !existing.contains(where: { !$0.hasPrefix(".") }) else { return }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var moved = 0
        for name in Self.accountFiles {
            let from = dir.appendingPathComponent(name)
            guard fm.fileExists(atPath: from.path) else { continue }
            if (try? fm.moveItem(at: from, to: folder.appendingPathComponent(name))) != nil { moved += 1 }
        }
        log("Account data: \(moved) item(s) from before accounts moved into the account's folder")
    }

    /// First launch: write the behaviour defaults so a fresh install arrives with
    /// speech cleanup, correction-learning and sound cues already switched on.
    /// Never writes a key — that is the user's to paste in Settings.
    private static func seedDefaults(in dir: URL) {
        let env = dir.appendingPathComponent(".env")
        guard !FileManager.default.fileExists(atPath: env.path) else { return }
        let keyLine = Config.retail
            ? "# Sign in and SayControl's cloud does the listening. No keys to add."
            : "# Add your own OpenRouter key in Settings › Models (nothing ships with one)."
        let text = """
        # SayControl settings — edit here or from the settings window.
        \(keyLine)
        CLEANUP=1
        AUTOLEARN=1
        SOUNDS=1

        """
        try? text.write(to: env, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: env.path)
    }

    /// The app was Wispr-Soro (~/.config/wisprsoro), then Open-Wispr
    /// (~/.config/openwispr), then Kotha (~/.config/kotha). Carry whichever is
    /// there over once, so an upgrade keeps the key, dictionary and history
    /// instead of starting from scratch.
    private static func migrateLegacyDirectory(into dir: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dir.path) else { return }

        // Newest legacy home first.
        let candidates = [
            (".config/kotha", "kotha.log"),
            (".config/openwispr", "openwispr.log"),
            (".config/wisprsoro", "wisprsoro.log"),
        ]
        var migrated = false
        for (path, oldLogName) in candidates {
            let legacy = fm.homeDirectoryForCurrentUser
                .appendingPathComponent(path, isDirectory: true)
            guard fm.fileExists(atPath: legacy.path),
                  (try? fm.moveItem(at: legacy, to: dir)) != nil else { continue }
            let oldLog = dir.appendingPathComponent(oldLogName)
            let newLog = dir.appendingPathComponent("sayctrl.log")
            if fm.fileExists(atPath: oldLog.path), !fm.fileExists(atPath: newLog.path) {
                try? fm.moveItem(at: oldLog, to: newLog)
            }
            migrated = true
            break
        }
        guard migrated else { return }

        // Old LaunchAgents point at the old binaries — drop them. Opening at
        // login is the user's to turn back on, as Apple's login item.
        for label in ["com.kotha.app", "com.openwispr.app"] {
            let agent = fm.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents/\(label).plist")
            try? fm.removeItem(at: agent)
        }
    }

    var envURL: URL { dir.appendingPathComponent(".env") }
    var logURL: URL { dir.appendingPathComponent("sayctrl.log") }
    var rulesURL: URL { dataDir.appendingPathComponent("replacements.json") }
    var phrasesURL: URL { dataDir.appendingPathComponent("phrases.json") }
    var historyURL: URL { dataDir.appendingPathComponent("history.json") }
    /// The Cerebras-direct rate budget, kept across launches — see Refiner.
    var refineBudgetURL: URL { dir.appendingPathComponent("refine-budget.json") }

    // MARK: - .env

    func env() -> [String: String] {
        var out: [String: String] = [:]
        guard let text = try? String(contentsOf: envURL, encoding: .utf8) else { return out }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") || trimmed.isEmpty { continue }
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
            let val = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            out[key] = val
        }
        return out
    }

    func write(_ env: [String: String]) {
        let text = env.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n") + "\n"
        try? text.write(to: envURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: envURL.path)
        NotificationCenter.default.post(name: .owSettingsChanged, object: nil)
    }

    func set(_ key: String, _ value: String?) {
        var e = env()
        if let v = value, !v.isEmpty { e[key] = v } else { e.removeValue(forKey: key) }
        write(e)
    }

    func flag(_ key: String, default def: Bool) -> Bool {
        guard let v = env()[key]?.lowercased() else { return def }
        return !(v == "0" || v == "false" || v == "no" || v == "off")
    }

    func setFlag(_ key: String, _ on: Bool) { set(key, on ? "1" : "0") }

    /// Existing installs have no PROVIDER line and an OpenRouter key, so the
    /// default has to stay OpenRouter — an upgrade must not silently repoint
    /// their audio at a provider they have no key for.
    var provider: Provider {
        get {
            // The user-facing build's only provider is this Mac, whatever the
            // file says: there is no provider a user could hold a key for. The
            // cloud plan (`cloudOn`) sits above this, not among these.
            if Config.retail { return .local }
            // SAYCTRL_* is the name now; KOTHA_* and OPENWISPR_* still work.
            let raw = ProcessInfo.processInfo.environment["SAYCTRL_PROVIDER"]
                ?? ProcessInfo.processInfo.environment["KOTHA_PROVIDER"]
                ?? ProcessInfo.processInfo.environment["OPENWISPR_PROVIDER"]
                ?? env()["PROVIDER"] ?? ""
            return Provider(rawValue: raw.lowercased()) ?? .openrouter
        }
        set { set("PROVIDER", newValue.rawValue) }
    }

    func apiKey(for provider: Provider) -> String? {
        // Local needs no auth at all — return a placeholder so the batch
        // path's "no key" guard doesn't block dictation before it reaches
        // the in-process branch.
        if provider == .local { return "local" }
        // Our own GPU is reached through an SSH tunnel; the tunnel is the auth.
        if provider == .gpu { return "gpu" }
        if let k = ProcessInfo.processInfo.environment[provider.keyVar], !k.isEmpty { return k }
        if let k = env()[provider.keyVar], !k.isEmpty { return k }
        return nil
    }

    var apiKey: String? { apiKey(for: provider) }

    /// Where the Own GPU socket is: GPU_URL from the environment or the
    /// settings file, else the SSH tunnel's local end.
    var gpuURL: URL {
        let raw = ProcessInfo.processInfo.environment["GPU_URL"] ?? env()["GPU_URL"] ?? ""
        return URL(string: raw.isEmpty ? GPU_DEFAULT_URL : raw) ?? URL(string: GPU_DEFAULT_URL)!
    }

    /// Each provider keeps its own model, because the names aren't portable:
    /// OpenRouter wants "openai/gpt-4o-transcribe", OpenAI wants "gpt-4o-transcribe".
    /// Live mode gets its own slot again — those models only exist on the
    /// realtime endpoint, so they'd break the batch path if they leaked into it.
    func model(for provider: Provider, live: Bool = false) -> String {
        if let m = ProcessInfo.processInfo.environment["SAYCTRL_MODEL"]
            ?? ProcessInfo.processInfo.environment["KOTHA_MODEL"]
            ?? ProcessInfo.processInfo.environment["OPENWISPR_MODEL"], !m.isEmpty { return m }
        if live {
            if let m = env()[provider.liveModelVar], !m.isEmpty { return m }
            return provider.defaultLiveModel
        }
        if let m = env()[provider.modelVar], !m.isEmpty { return m }
        return provider.defaultModel
    }

    var model: String { model(for: provider, live: liveEnabled) }

    /// The realtime WebSocket path. Only OpenAI and ElevenLabs have one, so the
    /// toggle is inert elsewhere rather than being a setting that does nothing.
    /// One shared flag: "stream when you can" is a preference about how you
    /// dictate, not about which vendor you happened to pick.
    var live: Bool { flag("LIVE", default: false) }
    /// The Live switch under Settings › Models › This Mac: words while you
    /// talk on the models that keep up on this Mac. On unless turned off —
    /// its own setting, so a key's model writing when you let go doesn't
    /// switch the Mac's off.
    var localLive: Bool { flag("LOCAL_LIVE", default: true) }
    /// Local streams on the models that keep up here (LocalSpeed), never
    /// Whisper: it re-decodes a 30-second window each pass, slowly, and
    /// visibly rewrites its own preview.
    var liveEnabled: Bool {
        guard provider.supportsLive || provider.liveOnly else { return false }
        if provider == .local { return localLive && LocalEngine.shared.liveCapable }
        return provider.liveOnly || live
    }

    // MARK: - Voice mesh

    /// A paid socket rides shotgun on a local dictation for the first few
    /// seconds. Short commands ("open Claude") are exactly where the local
    /// models are weakest — they need a couple of seconds of speech before
    /// their context kicks in — and where the paid sockets are sharpest.
    /// A clip released inside the window pastes the paid text; a longer one
    /// pastes the local text, which re-decoded the whole clip including
    /// those first seconds, so the two never need merging.
    var mesh: Bool { flag("MESH", default: false) }

    /// Which paid ear covers the window. Google by default — measured best
    /// on short command words — and never local (that is the other half).
    var meshProvider: Provider {
        guard let p = Provider(rawValue: (env()["MESH_PROVIDER"] ?? "").lowercased()),
              p.supportsLive, p != .local else { return .gemini }
        return p
    }

    /// How long the paid ear listens before local takes over — also the cap
    /// on what a dictation can cost, since the socket is cancelled at the
    /// handover.
    var meshSeconds: TimeInterval {
        min(10, max(1, Double(env()["MESH_SECONDS"] ?? "") ?? 3))
    }

    /// On only when the whole arrangement can actually run: a local live
    /// session to hand over to, and a key for the paid ear. Retail stays
    /// out — it has no paid providers to point at.
    var meshEnabled: Bool {
        guard !Config.retail, provider == .local, mesh, liveEnabled else { return false }
        return apiKey(for: meshProvider) != nil
    }

    // MARK: - AI polish

    /// The polish toggle as stored; `refineEnabled` is the one to act on.
    /// On by default, with a switch in Settings › Models › Polish — polish is the
    /// one step of a local dictation that still goes over the network and still
    /// costs money, so it has to be possible to hear the model without it.
    /// It still needs a key, and refineEnabled is what the paste path asks.
    var refine: Bool { flag("REFINE", default: true) }
    /// On only when there is something to send the requests with: SayControl's
    /// cloud, or a key.
    var refineEnabled: Bool { refine && hasModelAccess }
    var hasModelAccess: Bool { modelsViaCloud || refineKey != nil }

    /// SayControl's cloud does the listening and the polish, once signed in.
    /// A user's copy is cloud-only (2026-10-03): always on, with no switch
    /// and nothing on this Mac to fall back to — an old "off" in the
    /// settings file is ignored. The developers' build starts on its own
    /// keys and turns the cloud on under Settings › Account; there a take
    /// runs on the provider below once the plan is spent.
    var cloud: Bool {
        if let v = ProcessInfo.processInfo.environment["SAYCTRL_CLOUD"] { return v == "1" }
        if Config.retail { return true }
        return flag("CLOUD", default: false)
    }
    var cloudOn: Bool { Account.available && cloud && Cloud.shared.signedIn }

    /// Where Settings › Models says transcription runs: SayControl's cloud,
    /// a model on this Mac, or a provider's API on your own key.
    enum TranscriptionSource { case cloud, mac, key }
    var transcriptionSource: TranscriptionSource {
        if cloud { return .cloud }
        return provider == .local ? .mac : .key
    }
    func setTranscriptionSource(_ source: TranscriptionSource) {
        guard source != transcriptionSource else { return }
        switch source {
        case .cloud:
            setFlag("CLOUD", true)
        case .mac:
            setFlag("CLOUD", false)
            if provider != .local { set("LAST_PAID_PROVIDER", provider.rawValue) }
            provider = .local
        case .key:
            setFlag("CLOUD", false)
            if provider == .local { provider = lastKeyProvider }
        }
        log("Transcription runs on \(source)")
        Cloud.shared.cloudSwitched()
        NotificationCenter.default.post(name: .sayctrlAccountChanged, object: nil)
    }
    /// The API provider transcription was last on — the one "API key" goes
    /// back to — else the first with a key, else OpenAI.
    var lastKeyProvider: Provider {
        if provider != .local { return provider }
        if let p = env()["LAST_PAID_PROVIDER"].flatMap(Provider.init(rawValue:)), p != .local { return p }
        return Provider.allCases.first { $0 != .local && $0 != .gpu && apiKey(for: $0) != nil } ?? .openai
    }
    /// Polish, command mode and the agent voice's model calls go through
    /// SayControl's cloud whenever this Mac is signed in: its Cerebras key
    /// answers in ~0.4 s, where the developers' own keys went through
    /// OpenRouter's shared pool at up to 3.7 s (2026-10-09). The developers'
    /// build does this even with cloud dictation off, so both builds polish
    /// on the same route; POLISH_CLOUD=0 puts it back on its own keys.
    ///
    /// Settings › Models › Polish chooses between it and your own key while
    /// transcription is on the cloud. The cloud polishes only takes it heard
    /// (their receipt goes with the words), so a take from this Mac or a
    /// key polishes on your key whatever this says (Refine.perform). A
    /// user's copy is all cloud.
    var modelsViaCloud: Bool {
        guard Account.available, Cloud.shared.signedIn else { return false }
        if Config.retail { return cloudOn }
        return flag("POLISH_CLOUD", default: true)
    }
    /// Who polishes on this Mac's own key, and with what.
    var polishProvider: PolishProvider {
        if let p = env()["POLISH_PROVIDER"].flatMap(PolishProvider.init(rawValue:)) { return p }
        // Before there was a choice, REFINE_API_KEY was the key: a csk-…
        // one went to Cerebras direct, anything else to OpenRouter.
        return (env()["REFINE_API_KEY"] ?? "").hasPrefix("csk-") ? .cerebras : .openrouter
    }
    func polishKey(_ provider: PolishProvider) -> String? {
        if let k = ProcessInfo.processInfo.environment[provider.keyVar], !k.isEmpty { return k }
        if let k = env()[provider.keyVar], !k.isEmpty { return k }
        // The old single polish key, wherever it belonged.
        if let k = env()["REFINE_API_KEY"], !k.isEmpty,
           provider == (k.hasPrefix("csk-") ? .cerebras : .openrouter) { return k }
        return nil
    }
    /// The model per provider, so moving between keys keeps each one's pick.
    /// REFINE_MODEL was OpenRouter's and Cerebras's before there were others.
    func polishModel(_ provider: PolishProvider) -> String {
        if let m = env()[provider.modelVar], !m.isEmpty { return m }
        if provider == .openrouter || provider == .cerebras, let m = env()["REFINE_MODEL"], !m.isEmpty {
            // Cerebras names models bare where OpenRouter prefixes the vendor.
            return provider == .cerebras ? String(m.split(separator: "/").last ?? Substring(m)) : m
        }
        return provider.defaultModel
    }
    var refineModel: String { polishModel(polishProvider) }
    /// The key polish sends with: REFINE_API_KEY in the environment wins (a
    /// test run), then the picked provider's.
    var refineKey: String? {
        if let k = ProcessInfo.processInfo.environment["REFINE_API_KEY"], !k.isEmpty { return k }
        return polishKey(polishProvider)
    }

    /// Per-app styles: the polish prompt learns where the paste is headed
    /// (email vs chat vs code — see AppStyle.swift). On by default; polish
    /// itself being off makes this moot.
    var refineStyle: Bool { flag("REFINE_STYLE", default: true) }

    /// Speak into a terminal and the words land as a command (Shell.swift).
    /// On by default: a dictation that is not unmistakably a command stays
    /// prose either way, so the switch is for the person who dictates nothing
    /// BUT prose at an agent and wants the grammar out of the way entirely.
    /// NOT called SHELL: this is written to a file named .env, and anyone who
    /// sources it would be setting their login shell to "0".
    var shell: Bool { flag("TERMINAL_COMMANDS", default: true) }

    var cleanup: Bool { flag("CLEANUP", default: true) }
    var autoLearn: Bool { flag("AUTOLEARN", default: true) }
    var sounds: Bool { flag("SOUNDS", default: true) }
    /// The soft tick How it works' dial makes on each step. On unless its
    /// speaker was clicked off, and silent whenever `sounds` is off.
    var howtoTicks: Bool {
        get { flag("HOWTO_TICKS", default: true) }
        set { set("HOWTO_TICKS", newValue ? nil : "0") }
    }
    /// Skim the front window for names/jargon when recording starts and
    /// offer them to the recognizer as vocabulary (see ScreenVocab).
    var screenVocab: Bool { flag("SCREEN_VOCAB", default: true) }

    /// The agent voice (AgentBridge): speak when a Claude Code agent finishes
    /// or needs an answer, and take the reply by voice. Off until switched
    /// on — it installs hooks into the user's Claude Code settings.
    var agentVoice: Bool { flag("AGENT_VOICE", default: false) }
    /// The agent voice runs on SayControl's cloud — counted conversations,
    /// the server's voice and model — rather than on keys in .env. A
    /// user's copy does whenever it is signed in; the developers' build
    /// follows its cloud switch, or AGENT_CLOUD=1 for the voice alone, so
    /// the plan's counting can be tried with dictation still on its own keys.
    var agentCloud: Bool {
        cloudOn || (!Config.retail && flag("AGENT_CLOUD", default: false) && Account.available && Cloud.shared.signedIn)
    }
    /// After the summary, keep the ear open for a spoken reply without a
    /// key press. Off leaves the dictation key as the only way to answer.
    var agentOpenMic: Bool { flag("AGENT_OPEN_MIC", default: true) }
    /// The loopback port Claude Code's hooks post to. Dev and shipping
    /// builds listen on different ports so both can run at once.
    var agentPort: Int {
        Int(env()["AGENT_PORT"] ?? "") ?? (Config.isDev ? 47712 : 47711)
    }

    /// Which of the six screen seats the pill occupies — a PillDock
    /// rawValue (PillOverlays.swift). Set by dragging the pill or via the
    /// sun menu's Move button.
    var pillPosition: String {
        get { env()["PILL_POS"] ?? "bottom-center" }
        set { set("PILL_POS", newValue == "bottom-center" ? nil : newValue) }
    }

    /// How much of a live dictation shows while you talk: "line" — the
    /// newest words ride in the pill itself, one line, the pill opening once
    /// to hold them; "card" — the pill grows into the speech card and every
    /// word fills in (2.2's look); "off" — bars only, the words appear when
    /// they land. Side seats have no room for a line and use the card.
    var liveWords: String {
        get {
            let v = env()["LIVE_WORDS"]?.lowercased() ?? "line"
            return ["line", "card", "off"].contains(v) ? v : "line"
        }
        set { set("LIVE_WORDS", newValue == "line" ? nil : newValue) }
    }

    /// Whether the idle pill hides itself: off, it is always on screen; on,
    /// it fades out after a few seconds of nothing and comes back the moment
    /// you dictate or point at its seat. Settings › General › Appearance.
    var pillAutoHide: Bool {
        get { env()["PILL_AUTOHIDE"] == "1" }
        set { set("PILL_AUTOHIDE", newValue ? "1" : nil) }
    }

    // MARK: - Appearance

    /// "system", "light" or "dark" — how the app's windows draw themselves.
    /// The floating pill stays dark glass in all three.
    var appearance: String {
        get {
            let v = env()["APPEARANCE"]?.lowercased() ?? "system"
            return ["light", "dark"].contains(v) ? v : "system"
        }
        set { set("APPEARANCE", newValue == "system" ? nil : newValue) }
    }

    /// UI text scale — the "Text size" setting; the picker offers 1.12 /
    /// 1.25 / 1.40. The window is drawn at Moderate (1.25), but a fresh
    /// install opens at Smallest: the owner's call, 2026-09-27, after the
    /// second polish pass — the calmer, denser page reads better.
    static let defaultFontScale = 1.12
    var fontScale: Double {
        get {
            let v = Double(env()["FONT_SCALE"] ?? "") ?? Self.defaultFontScale
            return min(1.4, max(0.7, v))
        }
        set {
            set("FONT_SCALE", newValue == Self.defaultFontScale ? nil : String(format: "%.2f", newValue))
        }
    }

    func applyAppearance() {
        switch appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
        default:      NSApp.appearance = nil
        }
    }

    // MARK: - Log

    /// One shared stamp formatter and one open handle: a dictation writes a
    /// dozen lines, and building a DateFormatter and reopening the file for
    /// each of them was work happening between the words and the paste.
    static let logStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
    private let logQueue = DispatchQueue(label: "sayctrl.log", qos: .utility)
    private var logHandle: FileHandle?

    func log(_ msg: String) {
        let line = "[\(Self.logStamp.string(from: Date()))] \(msg)\n"
        logQueue.async { [weak self] in
            guard let self = self, let data = line.data(using: .utf8) else { return }
            if self.logHandle == nil {
                if !FileManager.default.fileExists(atPath: self.logURL.path) {
                    FileManager.default.createFile(atPath: self.logURL.path, contents: nil)
                }
                self.logHandle = try? FileHandle(forWritingTo: self.logURL)
                _ = try? self.logHandle?.seekToEnd()
            }
            guard let handle = self.logHandle else { return }
            do {
                try handle.write(contentsOf: data)
                if let size = try? handle.offset(), size > Self.logLimit { self.rotateLog() }
            } catch {
                // The file was rotated or removed underneath us — reopen next time.
                try? handle.close()
                self.logHandle = nil
            }
        }
    }

    /// Past this the log starts over and the stretch before it is kept as
    /// sayctrl.log.1, so the file never grows without end. A shipping copy's
    /// log holds no words (Config.words) and needs far less room.
    private static let logLimit: UInt64 = Config.retail ? 2_000_000 : 50_000_000

    /// On logQueue only.
    private func rotateLog() {
        try? logHandle?.close()
        logHandle = nil
        let previous = logURL.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: logURL, to: previous)
    }

    /// Something a person said, typed, was shown or was answered, as the log
    /// may hold it: the words themselves in the dev build, where they are what
    /// a take is checked by; in a shipping copy only how many, so its log
    /// never keeps what anyone dictated, edited or read.
    /// `upTo` trims the dev build's copy; the count is always of the whole.
    static func words(_ text: String, upTo limit: Int = .max) -> String {
        guard retail else { return text.count > limit ? String(text.prefix(limit)) : text }
        let n = text.split(whereSeparator: { $0.isWhitespace }).count
        return "‹\(n) word\(n == 1 ? "" : "s")›"
    }

    /// A file path, folder, address or name a person asked for, the same way:
    /// itself in the dev build, hidden in a shipping copy.
    static func detail(_ text: String) -> String { retail ? "‹hidden›" : text }

    /// Last chunk of the log — enough for the Activity pane without loading a huge file.
    func logTail(maxBytes: Int = 120_000) -> String {
        guard let data = try? Data(contentsOf: logURL) else { return "" }
        let slice = data.count > maxBytes ? data.suffix(maxBytes) : data
        return String(decoding: slice, as: UTF8.self)
    }

    func clearLog() {
        logQueue.sync {
            try? logHandle?.close()
            logHandle = nil
        }
        try? "".write(to: logURL, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: logURL.appendingPathExtension("1"))
        log("Log cleared")
    }

    /// A shipping copy's log from before it kept counts only (Config.words)
    /// holds what was dictated. It is cleared once, so the log on this Mac
    /// matches what the privacy policy says it holds.
    func clearWordsFromOldLog() {
        guard Config.retail, env()["LOG_COUNTS_ONLY"] != "1" else { return }
        clearLog()
        set("LOG_COUNTS_ONLY", "1")
    }

    // MARK: - Launch at login

    /// Apple's login item for the app itself, listed under System Settings ›
    /// General › Login Items. Off until the user turns it on in Settings;
    /// nothing turns it on for them. Opened at login the app starts quietly
    /// (AppDelegate.launchedAsLoginItem). If they switched it off in System
    /// Settings, turning it on here sends them there to allow it.
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            let service = SMAppService.mainApp
            do {
                if newValue { try service.register() } else { try service.unregister() }
            } catch {
                log("Launch at login: \(newValue ? "register" : "unregister") failed — \(error.localizedDescription)")
            }
            if newValue, service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        }
    }

    /// The hand-written LaunchAgent copies made before the Developer ID (they
    /// switched it on for everyone at the end of Set Up). Removed, not carried
    /// over: opening at login starts off, and is the user's to choose.
    func removeLegacyLaunchAgent() {
        let agent = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(Config.bundleID).plist")
        guard FileManager.default.fileExists(atPath: agent.path) else { return }
        try? FileManager.default.removeItem(at: agent)
        log("Launch at login: removed the old LaunchAgent; Settings › General turns it on")
    }
}

// MARK: - Dictation history

struct HistoryEntry: Codable {
    /// Stable across edits and re-transcriptions — how a row finds its audio.
    var id: String
    var date: Date
    var text: String
    var seconds: Double
    var model: String
    /// The file name inside the recordings folder, when the clip was kept.
    var audio: String?
    /// What the recognizer was told: names, screen words, the text before
    /// the caret (TypingContext). Local only; how context ideas get measured.
    var context: TakeContext?
    /// The words that landed after the AI polish, when it changed them.
    /// `text` stays the words as heard, so the polish can be undone from the
    /// Recent list and every count still reads what was said.
    var polished: String?

    /// What landed at the cursor: the polish when there was one.
    var shown: String { polished ?? text }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = (try? c.decode(Date.self, forKey: .date)) ?? Date()
        text = (try? c.decode(String.self, forKey: .text)) ?? ""
        seconds = (try? c.decode(Double.self, forKey: .seconds)) ?? 0
        model = (try? c.decode(String.self, forKey: .model)) ?? ""
        audio = try? c.decode(String.self, forKey: .audio)
        context = try? c.decode(TakeContext.self, forKey: .context)
        polished = try? c.decode(String.self, forKey: .polished)
        // Older entries carry no id — one derived from the instant they were
        // spoken is stable enough to key an old row by.
        id = (try? c.decode(String.self, forKey: .id))
            ?? String(format: "%.3f", date.timeIntervalSinceReferenceDate)
    }

    init(id: String = HistoryEntry.newID(), date: Date, text: String, seconds: Double,
         model: String, audio: String? = nil, context: TakeContext? = nil) {
        self.id = id; self.date = date; self.text = text
        self.seconds = seconds; self.model = model; self.audio = audio; self.context = context
    }

    static func newID() -> String {
        String(format: "%.3f-%04d", Date().timeIntervalSinceReferenceDate, Int.random(in: 0..<10000))
    }
}

final class HistoryStore {
    static let shared = HistoryStore()
    private(set) var entries: [HistoryEntry] = []   // newest first
    /// Ten times what 2.1 kept. The transcripts are small, and a busy day used
    /// to push the day before it off the end of the list — see StatsStore for
    /// why the charts no longer depend on this number at all.
    private let cap = 2000
    private let io = DispatchQueue(label: "sayctrl.history", qos: .utility)
    private var saveScheduled = false

    private init() { load() }

    /// Another account's folder: its own list, and nothing of the last one's.
    func reload() {
        entries = []
        load()
        NotificationCenter.default.post(name: .owHistoryChanged, object: nil)
    }

    private func load() {
        guard let data = try? Data(contentsOf: Config.shared.historyURL),
              let list = try? JSONDecoder().decode([HistoryEntry].self, from: data) else { return }
        entries = list
    }

    /// Writes off the main thread, and only once per runloop turn: a dictation
    /// used to block on a pretty-printed re-encode of the whole file before the
    /// paste could land.
    private func save() {
        NotificationCenter.default.post(name: .owHistoryChanged, object: nil)
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.saveScheduled = false
            let snapshot = self.entries
            let url = Config.shared.historyURL
            self.io.async {
                if let data = try? JSONEncoder().encode(snapshot) {
                    try? data.write(to: url, options: .atomic)
                }
            }
        }
    }

    func add(text: String, seconds: Double, model: String, audio: String? = nil,
             id: String = HistoryEntry.newID(), context: TakeContext? = nil) {
        // The Privacy switch used to be decoration — history was kept either
        // way. Off now means off: no transcript, no clip, no daily total.
        guard Config.shared.flag("KEEP_HISTORY", default: true) else {
            Recordings.shared.delete(audio)
            return
        }
        let entry = HistoryEntry(id: id, date: Date(), text: text, seconds: seconds,
                                 model: model, audio: audio, context: context)
        entries.insert(entry, at: 0)
        if entries.count > cap {
            for dropped in entries.suffix(entries.count - cap) { Recordings.shared.delete(dropped.audio) }
            entries.removeLast(entries.count - cap)
        }
        StatsStore.shared.record(entry)
        save()
    }

    /// A re-transcription replaces the words; the day's totals follow it, and
    /// the entry remembers which model heard it last — two models can agree on
    /// the words, so the name is worth keeping even when the text stands.
    func replaceText(id: String, with text: String, model: String? = nil) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        let textChanged = entries[i].text != text
        let modelChanged = model.map { $0 != entries[i].model } ?? false
        guard textChanged || modelChanged else { return }
        if textChanged {
            StatsStore.shared.amend(entries[i], newText: text)
            entries[i].text = text
            // Fresh words: a polish of the old ones no longer belongs to them.
            entries[i].polished = nil
        }
        if let model = model { entries[i].model = model }
        save()
    }

    /// The polish a take got, or nil to go back to the words as heard.
    func setPolished(id: String, _ polished: String?) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        let value = polished == entries[i].text ? nil : polished
        guard entries[i].polished != value else { return }
        entries[i].polished = value
        save()
    }

    func remove(id: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        Recordings.shared.delete(entries[i].audio)
        StatsStore.shared.forget(entries[i])
        entries.remove(at: i)
        save()
    }

    func clear() {
        entries.removeAll()
        Recordings.shared.clear()
        StatsStore.shared.clear()
        ControlStats.shared.clear()
        save()
    }
}

// MARK: - Daily totals

/// What one day added up to. A dozen bytes a day, kept forever.
struct DayStat: Codable {
    var words = 0
    var seconds = 0.0
    var clips = 0
    /// Seconds spoken in each hour of the day — what "when you speak" reads.
    var byHour = [Double](repeating: 0, count: 24)

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        words = (try? c.decode(Int.self, forKey: .words)) ?? 0
        seconds = (try? c.decode(Double.self, forKey: .seconds)) ?? 0
        clips = (try? c.decode(Int.self, forKey: .clips)) ?? 0
        let hours = (try? c.decode([Double].self, forKey: .byHour)) ?? []
        byHour = hours.count == 24 ? hours : [Double](repeating: 0, count: 24)
    }
}

/// Per-day totals that outlive the transcripts.
///
/// history.json holds the words themselves and is capped, so the charts used
/// to forget a day as soon as it scrolled off the end of the list — a busy
/// yesterday read as zero while today looked right. These totals are written
/// once per clip, never pruned, and every chart counts from them.
final class StatsStore {
    static let shared = StatsStore()

    private(set) var days: [String: DayStat] = [:]
    /// Everything spoken up to here is already in `days` — the backfill picks
    /// up from it, so replaying history can't double-count.
    private var countedThrough = Date.distantPast
    private let io = DispatchQueue(label: "sayctrl.stats", qos: .utility)
    private var saveScheduled = false

    private var url: URL { Config.shared.dataDir.appendingPathComponent("stats.json") }

    private struct File: Codable {
        var days: [String: DayStat]
        var countedThrough: Date
    }

    private init() { load() }

    /// Another account's folder. History reloads first: the backfill reads it.
    func reload() {
        days = [:]
        countedThrough = .distantPast
        load()
    }

    private func load() {
        if let data = try? Data(contentsOf: url),
           let file = try? JSONDecoder().decode(File.self, from: data) {
            days = file.days
            countedThrough = file.countedThrough
            backfill()
        } else {
            // Nothing counted yet: the log remembers further back than the capped
            // history does, so the days that fell off the end come back. The
            // log is the Mac's, so only outside an account's folder: a new
            // account would start with whoever spoke before it.
            if !Config.shared.hasAccountFolders { backfillFromLog() }
            backfill()
        }
    }

    /// A day key in the local calendar: "2026-08-21".
    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func dayKey(_ date: Date) -> String { Self.keyFormatter.string(from: date) }

    static func words(_ s: String) -> Int { s.split { $0.isWhitespace || $0.isNewline }.count }

    // MARK: Reading

    func stat(on date: Date) -> DayStat { days[dayKey(date)] ?? DayStat() }

    /// The last `count` days, oldest first, ending today.
    func window(_ count: Int, endingAt end: Date = Date()) -> [(date: Date, stat: DayStat)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: end)
        return (0..<count).reversed().compactMap { back in
            guard let d = cal.date(byAdding: .day, value: -back, to: today) else { return nil }
            return (d, stat(on: d))
        }
    }

    var totalWords: Int { days.values.reduce(0) { $0 + $1.words } }
    var totalSeconds: Double { days.values.reduce(0) { $0 + $1.seconds } }

    // MARK: Writing

    func record(_ entry: HistoryEntry) {
        add(date: entry.date, words: Self.words(entry.text), seconds: entry.seconds, clips: 1)
        if entry.date > countedThrough { countedThrough = entry.date }
        save()
    }

    /// A re-transcription: only the word count moves.
    func amend(_ entry: HistoryEntry, newText: String) {
        add(date: entry.date, words: Self.words(newText) - Self.words(entry.text), seconds: 0, clips: 0)
        save()
    }

    func forget(_ entry: HistoryEntry) {
        add(date: entry.date, words: -Self.words(entry.text), seconds: -entry.seconds, clips: -1)
        save()
    }

    private func add(date: Date, words: Int, seconds: Double, clips: Int) {
        let key = dayKey(date)
        var stat = days[key] ?? DayStat()
        stat.words = max(0, stat.words + words)
        stat.seconds = max(0, stat.seconds + seconds)
        stat.clips = max(0, stat.clips + clips)
        let hour = Calendar.current.component(.hour, from: date)
        if stat.byHour.count == 24 { stat.byHour[hour] = max(0, stat.byHour[hour] + seconds) }
        days[key] = stat
    }

    func clear() {
        days.removeAll()
        countedThrough = Date()
        save()
    }

    /// Upgrading from a build that kept no totals — replay whatever history
    /// still has, once. Anything already pruned is gone for good, but from here
    /// on the days stand on their own.
    private func backfill() {
        let unseen = HistoryStore.shared.entries.filter { $0.date > countedThrough }
        guard !unseen.isEmpty else { return }
        for entry in unseen {
            add(date: entry.date, words: Self.words(entry.text), seconds: entry.seconds, clips: 1)
        }
        countedThrough = unseen.map { $0.date }.max() ?? countedThrough
        save()
    }

    /// Rebuilds the daily totals from sayctrl.log — the one place a dictation
    /// that has scrolled out of history still leaves a trace.
    ///
    /// Every dictation writes a "stopped (Ns)" line and then a transcript line,
    /// so a clip is a duration and a word count with a timestamp on it. Long
    /// transcripts are logged truncated to 160 characters but carry their real
    /// length in the header, so their word count is scaled back up from the
    /// part that was written.
    private func backfillFromLog() {
        guard let text = try? String(contentsOf: Config.shared.logURL, encoding: .utf8) else { return }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var pendingSeconds: Double?
        var newest = Date.distantPast
        var clips = 0

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let when = stamp.date(from: String(line[line.index(after: line.startIndex)..<close]))
            guard let when = when else { continue }
            let body = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)

            if let range = body.range(of: "recording stopped (", options: .caseInsensitive),
               let end = body[range.upperBound...].firstIndex(of: "s") {
                pendingSeconds = Double(body[range.upperBound..<end])
                continue
            }
            // "Transcript raw (…)" is the same clip as the "final" line that
            // follows it — only one of the pair may be counted.
            let plain = body.hasPrefix("Transcript (") && body.contains("chars): ")
            let polished = body.hasPrefix("Transcript final (")
            guard plain || polished else { continue }
            guard let open = body.firstIndex(of: "("),
                  let shut = body.firstIndex(of: ")"),
                  let colon = body.range(of: ": ") else { continue }
            let declared = Int(body[body.index(after: open)..<shut]
                .replacingOccurrences(of: " chars", with: "")) ?? 0
            let logged = String(body[colon.upperBound...])
            var words = Self.words(logged)
            if let n = Self.loggedCount(logged) {
                words = n   // a shipping copy's log: the count, never the words
            } else if declared > logged.count, logged.count > 0 {
                words = Int((Double(words) * Double(declared) / Double(logged.count)).rounded())
            }
            add(date: when, words: words, seconds: pendingSeconds ?? 0, clips: 1)
            pendingSeconds = nil
            clips += 1
            if when > newest { newest = when }
        }
        guard clips > 0 else { return }
        countedThrough = max(countedThrough, newest)
        Config.shared.log("Stats: rebuilt \(clips) clip(s) across \(days.count) day(s) from the log")
    }

    /// "‹12 words›", as Config.words writes a transcript in a shipping copy.
    private static func loggedCount(_ logged: String) -> Int? {
        guard logged.hasPrefix("‹"), logged.hasSuffix("›") else { return nil }
        return Int(logged.dropFirst().prefix { $0.isNumber })
    }

    private func save() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.saveScheduled = false
            let file = File(days: self.days, countedThrough: self.countedThrough)
            let url = self.url
            self.io.async {
                if let data = try? JSONEncoder().encode(file) {
                    try? data.write(to: url, options: .atomic)
                }
            }
        }
    }
}
