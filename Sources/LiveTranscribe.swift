// Live streaming transcription over a realtime WebSocket.
//
// The batch path in main.swift records a whole clip to disk and uploads it once.
// This one opens a socket the moment you press fn, streams mono PCM16 out of the
// mic as you speak, and gets transcript deltas back in flight — so by the time
// you let go the text is already written and the paste is instant.
//
// Eight providers serve a realtime socket, and they speak different protocols:
//   • OpenAI      session.update handshake, then `input_audio_buffer.append`
//                 frames; text arrives as per-turn deltas keyed by item_id.
//   • ElevenLabs  no handshake — every option is a query parameter — then
//                 `input_audio_chunk` frames; text arrives as one rolling
//                 partial per segment, replaced by a committed transcript.
//   • AssemblyAI  no handshake either, and audio goes as RAW BINARY frames
//                 rather than base64 in JSON; text arrives as `Turn` messages
//                 that carry the whole turn so far, and the session ends on
//                 `Terminate` instead of a commit.
//   • Google      the client speaks first: a `setup` message opens the
//                 session, `setupComplete` answers it, audio goes base64'd in
//                 `realtimeInput` envelopes and replies arrive as JSON in
//                 BINARY frames. One rolling interim per utterance, then a
//                 final that supersedes it; the stream ends on
//                 `audioStreamEnd`, which flushes a pending final but is
//                 answered with SILENCE when everything is already final.
//   • smallest    Pulse. No handshake and nothing to configure after the URL —
//                 like ElevenLabs — but audio goes as RAW BINARY frames like
//                 AssemblyAI; text arrives as one rolling partial per segment,
//                 superseded by an `is_final`, and the stream ends on a
//                 `close_stream` message answered by a final marked `is_last`.
//   • Meta        Muse. The client speaks first, like Google, but the key
//                 rides INSIDE the handshake frame rather than a header;
//                 audio goes as RAW BINARY frames like AssemblyAI; text
//                 arrives as ONE rolling cumulative transcript for the whole
//                 take, and the stream ends on `endStream`, answered by that
//                 same transcript marked `final`.
//   • xAI         Grok Voice Transcribe. Configured in the URL like
//                 ElevenLabs, raw binary frames like AssemblyAI; text arrives
//                 as `transcript.partial` events in THREE flavours — an
//                 interim, a chunk final carrying only the newest words, and
//                 a closing one carrying the whole utterance again — and the
//                 stream ends on `audio.done`, answered by a `transcript.done`
//                 that carries NO TEXT of its own.
//   • Soniox      the client speaks first, like Meta, key inside the config
//                 frame, but nothing answers it; raw binary frames; text
//                 arrives as TOKENS — finals append, the non-final tail is
//                 replaced whole each time — and the take ends on a
//                 `finalize`, answered by a `<fin>` token.
// Everything else (mic capture, resampling, level metering, the grace period,
// salvaging text from a failed session) is shared, so the differences live in
// `socketRequest`, `sendAudio`/`commitMessage`, and one event handler each.
//
// Ownership of mutable state, because two threads are involved:
//   • sendQueue  owns `ready`, `pending`, `stopping` (the audio tap runs on a
//                render thread and must never block on the main queue)
//   • main queue owns the transcript tables — the URLSession delivers every
//                socket event straight to .main, so event handling is serial
import AVFoundation
import Cocoa

final class LiveTranscriber: LiveSession {
    /// Running transcript, fired on the main queue every time it grows.
    var onText: ((String) -> Void)?
    /// Mic level 0…1 for the pill animation, main queue.
    var onLevel: ((CGFloat) -> Void)?
    /// Fired exactly once on the main queue when the session ends.
    var onFinish: ((Result<String, Error>) -> Void)?
    var tape: AudioTape?

    private let provider: Provider
    private let model: String
    private let key: String
    /// The rate this session streams (and tapes) at — 24 kHz for OpenAI,
    /// 16 kHz for everyone else.
    let sampleRate: Double
    private let engine = AVAudioEngine()
    private let sendQueue = DispatchQueue(label: "sayctrl.live.send")
    private var session: URLSession?
    private var ws: URLSessionWebSocketTask?
    private var converter: AVAudioConverter?
    private var tapped = false

    // sendQueue-owned
    private var ready = false
    /// Raw PCM held back until the session is ready. Kept raw, not base64, so
    /// each dialect can frame it its own way when it finally goes out.
    private var pending: [Data] = []
    /// Coalesces mic frames up to `liveMinChunkBytes` for providers that ask
    /// for a minimum chunk length.
    private var chunkBuffer = Data()
    private var stopping = false
    private var commitWhenReady = false
    /// What actually went out, and when the two moments that decide a live
    /// session happened. Read back for the post-mortem in `deliver`.
    private var sentBytes = 0
    private var sentFrames = 0
    private var readyAt: TimeInterval?
    private var commitAt: TimeInterval?

    // main-owned
    private var sentKeywords = true
    private var configured = false
    private var finished = false
    /// OpenAI: one entry per turn, keyed by item_id.
    private var order: [String] = []
    private var deltas: [String: String] = [:]
    private var finals: [String: String] = [:]
    /// ElevenLabs: finalised segments, plus the segment still being heard.
    private var committed: [String] = []
    private var partial = ""
    /// The words still provisional: Soniox may yet change them.
    var provisional: String { partial }
    /// A real new segment always streams a partial before it is finalised, so
    /// this tells a fresh segment apart from the same one arriving twice.
    private var heardPartial = false
    /// xAI: the chunk finals of the utterance being spoken right now. Each
    /// carries only its own new words, so they accumulate — until the
    /// utterance closes and one complete version replaces the lot.
    private var pieces: [String] = []
    /// Soniox: every final token so far, run together as they came — each
    /// carries its own leading space, so they concatenate rather than join.
    /// The non-final tail lives in `partial`.
    private var sonioxFinal = ""
    /// Own GPU: Nemotron's live text sits in `partial` (each one is the whole
    /// take so far); Qwen3's text at key-up lands here and wins.
    private var gpuFinal: String?
    /// Google: the utterance being heard right now. Its interims replace each
    /// other under this id in `deltas`; the final that closes it lands in
    /// `finals` and moves the counter on, so finals accumulate like turns.
    private var geminiSegment = 0
    private var deadline: Timer?

    /// When the socket was opened — every time in the post-mortem is measured
    /// from here, which is also when the mic started.
    let openedAt = Date()

    /// A SayControl cloud take: the socket goes to our relay (Cloud.swift)
    /// with our access token, and the relay speaks AssemblyAI's protocol
    /// back. The token can land after the mic has started — a refresh — and
    /// until then the audio waits in `pending`.
    private var cloudBearer: String?
    private var awaitingBearer = false
    /// Key-up before the token landed: the grace clock starts when it does.
    private var finishGraceOnConnect: TimeInterval?
    /// The relay's own messages — Begin (with the plan's usage), Limit and
    /// Error — for the app to read the plan from. Main queue.
    var onCloudMessage: (([String: Any]) -> Void)?
    /// Whether a final turn after key-up is the end of the take. True for
    /// AssemblyAI, whose closing turn answers Terminate; the relay says false
    /// for vendors that can finish a pause just before their real last words
    /// (measured: smallest.ai lost its last four words to an early paste), and
    /// then only Termination ends the take.
    private var finalTurnEnds = true

    /// When the session became ready and when the commit went out, seconds
    /// after `openedAt` — what --cloudtest prints.
    var timings: (ready: TimeInterval?, commit: TimeInterval?) { sendQueue.sync { (readyAt, commitAt) } }

    init(provider: Provider, model: String, key: String) {
        self.provider = provider
        self.model = model
        self.key = key
        self.sampleRate = provider.liveSampleRate
    }

    /// Everything we have heard so far: a completed transcript wins over the
    /// deltas that built it, and unfinished turns still show their partial text.
    /// AssemblyAI shares the OpenAI tables: its `turn_order` plays the part of
    /// an item_id, and a finished turn likewise wins over the running one.
    private var transcript: String {
        let parts: [String]
        switch provider {
        // smallest.ai's segments behave exactly like ElevenLabs': one rolling
        // partial, finals accumulate — so the two share tables. Meta is the
        // degenerate case of the same shape: one rolling partial for the
        // whole take, and one final that replaces it.
        case .elevenlabs, .smallest, .meta:
            parts = committed + [partial]
        // xAI is the same shape with one more layer: closed utterances, then
        // the pieces of the one being spoken, then the words still in the air.
        case .xai:
            parts = committed + pieces + [partial]
        case .soniox:
            return (sonioxFinal + partial).trimmingCharacters(in: .whitespacesAndNewlines)
        case .gpu:
            return (gpuFinal ?? partial).trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            parts = order.map { finals[$0] ?? deltas[$0] ?? "" }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: - Start

    func start() throws {
        openSocket(withKeywords: true)
        try startEngine()
    }

    /// A cloud take: the mic starts now, the socket when `connect(bearer:)`
    /// brings the access token — at once, unless it needed a refresh.
    func startAwaitingBearer() throws {
        awaitingBearer = true
        try startEngine()
    }

    /// Opens the socket to the relay. False when the take already ended
    /// (too short, or cancelled).
    @discardableResult
    func connect(bearer: String) -> Bool {
        guard !finished, awaitingBearer else { return false }
        awaitingBearer = false
        cloudBearer = bearer
        openSocket(withKeywords: true)
        if let grace = finishGraceOnConnect {
            finishGraceOnConnect = nil
            armDeadline(grace)
        }
        return true
    }

    /// No token is coming: signed out, or the cloud is out of reach.
    func abandon(_ message: String) {
        awaitingBearer = false
        fail(message)
    }

    /// Streams a saved clip through the socket instead of the microphone — how
    /// a live-only model transcribes an old recording (the Recent rows'
    /// "transcribe again with…"). The mic never starts; the file's PCM rides
    /// the same append/commit path the tap feeds.
    ///
    /// Paced at 4× real time rather than blasted: these sockets are built for
    /// a microphone, and the dialects cap what one frame may carry (ElevenLabs
    /// answers `chunk_size_exceeded`, AssemblyAI wants 50–1000 ms per frame) —
    /// 200 ms frames every 50 ms stay inside every limit while a 30-second
    /// clip still feeds in under eight. `realtime` paces it like a mic
    /// instead, for measuring how long the text takes after the last word.
    func start(feeding fileURL: URL, bearer: String? = nil, realtime: Bool = false) throws {
        cloudBearer = bearer
        feedInterval = realtime ? 0.2 : 0.05
        let pcm = try Self.pcm16(from: fileURL, at: sampleRate)
        guard !pcm.isEmpty else { throw err("Couldn't read the recording") }
        // A mic session waits liveGrace because the server heard everything in
        // real time; a replay can leave the recogniser trailing the feed, so
        // long clips get more room. The early-complete paths still end the
        // session the moment every turn is final — this only moves the net.
        feedGrace = provider.liveGrace + min(10, Double(pcm.count) / (sampleRate * 2) * 0.25)
        openSocket(withKeywords: true)
        feed(pcm, from: 0, frame: Int(sampleRate * 0.2) * 2)
    }

    private var feedGrace: TimeInterval?
    private var feedInterval: TimeInterval = 0.05
    /// A fed clip's key-up: the last of the audio has gone out.
    var onFedAll: (() -> Void)?

    /// Main queue, like every other event here. Ends by arming the usual
    /// finish/grace path, so a fed clip completes exactly like a dictation.
    private func feed(_ pcm: Data, from offset: Int, frame: Int) {
        guard !finished else { return }
        guard offset < pcm.count else {
            onFedAll?()
            return finish(grace: feedGrace)
        }
        append(pcm.subdata(in: offset..<min(offset + frame, pcm.count)))
        DispatchQueue.main.asyncAfter(deadline: .now() + feedInterval) { [weak self] in
            self?.feed(pcm, from: offset + frame, frame: frame)
        }
    }

    /// The whole clip as the PCM16 mono this session speaks, resampled from
    /// whatever the file holds — 16 kHz recordings upsample for OpenAI's
    /// 24 kHz socket. One-shot, so the converter is drained to end-of-stream.
    private static func pcm16(from url: URL, at rate: Double) throws -> Data {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        guard let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate,
                                         channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: source, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: source,
                                           frameCapacity: AVAudioFrameCount(file.length)),
              let output = AVAudioPCMBuffer(
                  pcmFormat: target,
                  frameCapacity: AVAudioFrameCount(Double(file.length) * rate / source.sampleRate) + 1024)
        else {
            throw NSError(domain: "SayCtrl", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't prepare the recording for the live session."])
        }
        try file.read(into: input)
        var fed = false
        var convError: NSError?
        let status = converter.convert(to: output, error: &convError) { _, state in
            if fed {
                state.pointee = .endOfStream
                return nil
            }
            fed = true
            state.pointee = .haveData
            return input
        }
        guard convError == nil, status != .error, let pcm = output.int16ChannelData else {
            throw NSError(domain: "SayCtrl", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Couldn't read the recording."])
        }
        return Data(bytes: pcm[0], count: Int(output.frameLength) * 2)
    }

    /// The one ranked list in Hints.swift, as many as this provider carries.
    /// Measurably works: the same clip came back "Whisper" without it and
    /// "Whispr" with it.
    private var hints: [String] {
        switch provider {
        // ElevenLabs hard-rejects any keyterm over 20 characters — and one
        // long phrase poisons the WHOLE list, because the socket refuses the
        // session and the retry drops every hint. Measured 2026-08-20: 229
        // sessions had silently run hint-less over a 21-char command.
        case .elevenlabs: return Hints.list(cap: 30, maxLength: 20)
        case .assemblyai: return Hints.list(cap: 50)
        // Google takes up to 1,000 vocabulary terms but says accuracy is best
        // around 100, so that's the cap.
        case .gemini:     return Hints.list(cap: 100)
        // Meta took 80 in one handshake and refused 150 and 300 alike with
        // "backend temporarily unavailable" (measured 2026-09-02) — there is
        // no documented cap, so that refusal is the only word on it. It now
        // refuses any keyword over 20 characters too ("ASR keyword 10
        // exceeds the maximum length of 20 characters", 2026-09-29 on) —
        // every take was paying a refused handshake plus a hint-less
        // reconnect, ready at 3.0–3.8 s instead of ~1.4 s.
        case .meta:       return Hints.list(cap: 80, maxLength: 20)
        // 100 terms of at most 50 characters is the documented limit, and one
        // session took all of it (measured 2026-09-19) — but xAI's keyterms
        // BOOST, and the full list rewrote ordinary speech into the commands
        // on it. Only the words it could not have known go out; see
        // Hints.coinages.
        case .xai:        return Hints.coinages(cap: 100, maxLength: 50)
        // Soniox's `context.terms` takes up to 8,000 tokens of context, but
        // whether its terms suggest or boost is unmeasured — and xAI showed
        // what a boosting list of ordinary words does. Soniox heard "Open
        // Claude" right with no hints at all (bench, 2026-09-29), so only the
        // words it could not have known go out until the full list is tested.
        case .soniox:     return Hints.coinages(cap: 100, maxLength: 50)
        // The same 50 the local Qwen3 gets as context (LocalEngine.hint): the
        // gateway hands them to Qwen3 and boosts them in Nemotron. More terms
        // cost Qwen3 names (bench, 2026-10-01: 53 → 410 terms, 35 → 40 errors).
        case .gpu:        return Hints.names(cap: 40)
        default:          return Hints.list(cap: 80)
        }
    }

    private func socketRequest(withKeywords: Bool) -> URLRequest {
        var req: URLRequest
        if provider == .assemblyai {
            // A cloud take goes to our relay, which picks the vendor, the
            // model and its settings itself; only the rate and the hints are
            // ours to say.
            var comps = URLComponents(url: cloudBearer != nil ? Cloud.listenURL : URL(string: ASSEMBLY_REALTIME_URL)!,
                                      resolvingAgainstBaseURL: false)!
            var items = [URLQueryItem(name: "sample_rate", value: String(Int(sampleRate)))]
            if cloudBearer == nil {
                items += [
                    URLQueryItem(name: "speech_model", value: model),
                    // The preset AssemblyAI's own playground snippet was tested
                    // with. max_accuracy trades a little latency for word
                    // accuracy, which is the right side of that trade for
                    // dictation.
                    URLQueryItem(name: "mode", value: "max_accuracy"),
                    URLQueryItem(name: "voice_focus", value: "near-field"),
                    URLQueryItem(name: "voice_focus_threshold", value: "0.7"),
                ]
            } else {
                if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
                    items.append(URLQueryItem(name: "app_version", value: version))
                }
                // Dev builds only: SAYCTRL_CLOUD_VENDOR asks the relay for a
                // vendor of its own. The server honours it only for accounts
                // on its tester list; everyone else gets the server's pick.
                if !Config.retail, let vendor = ProcessInfo.processInfo.environment["SAYCTRL_CLOUD_VENDOR"]
                    ?? Config.shared.env()["SAYCTRL_CLOUD_VENDOR"], !vendor.isEmpty {
                    items.append(URLQueryItem(name: "vendor", value: vendor))
                }
                // The relay may hand the take to a vendor whose hints BOOST
                // (xAI), where the full list rewrites ordinary speech into
                // the commands on it — so the names-only list rides too, and
                // the relay picks whichever its vendor wants.
                let coinages = Hints.coinages(cap: 100, maxLength: 50)
                if withKeywords, !coinages.isEmpty,
                   let json = try? JSONSerialization.data(withJSONObject: coinages),
                   let text = String(data: json, encoding: .utf8) {
                    items.append(URLQueryItem(name: "coinages_prompt", value: text))
                }
            }
            // ⚠️ keyterms_prompt is ONE query parameter holding a JSON array.
            // Repeating the parameter instead closes the socket with code 3006.
            if withKeywords, !hints.isEmpty,
               let json = try? JSONSerialization.data(withJSONObject: hints),
               let text = String(data: json, encoding: .utf8) {
                items.append(URLQueryItem(name: "keyterms_prompt", value: text))
            }
            comps.queryItems = items
            req = URLRequest(url: comps.url!)
        } else if provider == .elevenlabs {
            // Everything is configured up front here, so a bad parameter kills
            // the connection outright instead of being negotiable afterwards.
            var comps = URLComponents(string: ELEVEN_REALTIME_URL)!
            var items = [
                URLQueryItem(name: "model_id", value: model),
                URLQueryItem(name: "audio_format", value: "pcm_\(Int(sampleRate))"),
                // Manual commits mean the socket finalises exactly once — when
                // you let go of fn. Their VAD would instead chop the dictation
                // into turns on every pause, which costs the model the sentence
                // context that makes it accurate.
                URLQueryItem(name: "commit_strategy", value: "manual"),
            ]
            if withKeywords { items += hints.map { URLQueryItem(name: "keyterms", value: $0) } }
            comps.queryItems = items
            req = URLRequest(url: comps.url!)
        } else if provider == .smallest {
            // Pulse configures in the URL like ElevenLabs — nothing to
            // negotiate after the handshake. No keyterm or vocabulary
            // parameter is documented, so the hint list stays home.
            var comps = URLComponents(string: SMALLEST_REALTIME_URL)!
            comps.queryItems = [
                URLQueryItem(name: "model", value: model),
                URLQueryItem(name: "encoding", value: "linear16"),
                URLQueryItem(name: "sample_rate", value: String(Int(sampleRate))),
            ]
            req = URLRequest(url: comps.url!)
        } else if provider == .meta {
            // Everything is configured in the handshake frame, key included.
            // The session id is optional — the server mints one otherwise —
            // but naming it makes the log and the server's error events
            // line up.
            var comps = URLComponents(string: META_REALTIME_URL)!
            comps.queryItems = [URLQueryItem(name: "sessionId",
                                             value: "sayctrl-\(UUID().uuidString.lowercased())")]
            req = URLRequest(url: comps.url!)
        } else if provider == .xai {
            // Configured entirely in the URL, like ElevenLabs — there is no
            // handshake to negotiate after it. `interim_results` is what puts
            // text in the pill while you are still talking; without it the
            // socket says nothing until a segment closes. No `language` is
            // sent: the model detects it per take, and pinning one is what
            // would make a bilingual dictation come back half-translated.
            var comps = URLComponents(string: XAI_REALTIME_URL)!
            var items = [
                URLQueryItem(name: "model", value: model),
                URLQueryItem(name: "encoding", value: "pcm"),
                URLQueryItem(name: "sample_rate", value: String(Int(sampleRate))),
                URLQueryItem(name: "interim_results", value: "true"),
            ]
            // One term per repeated parameter — ElevenLabs' shape, not
            // AssemblyAI's single parameter holding a JSON array.
            if withKeywords { items += hints.map { URLQueryItem(name: "keyterm", value: $0) } }
            comps.queryItems = items
            req = URLRequest(url: comps.url!)
        } else if provider == .soniox {
            // Everything, key included, rides the config frame.
            req = URLRequest(url: URL(string: SONIOX_REALTIME_URL)!)
        } else if provider == .gpu {
            // Everything rides the start frame; the SSH tunnel is the auth.
            req = URLRequest(url: Config.shared.gpuURL)
        } else if provider == .gemini {
            // Everything is configured in the setup message, not the URL — and
            // the key rides the x-goog-api-key header rather than the ?key=
            // query parameter the docs lead with, so the URL stays loggable.
            req = URLRequest(url: URL(string: GEMINI_REALTIME_URL)!)
        } else {
            req = URLRequest(url: URL(string: OPENAI_REALTIME_URL)!)
        }
        if let bearer = cloudBearer {
            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            // In a header, not the query, so the logged URL never carries it.
            Cloud.nameMac(on: &req)
        } else {
            req.setValue(provider.authHeaderValue(key), forHTTPHeaderField: provider.authHeaderName)
        }
        return req
    }

    private func openSocket(withKeywords: Bool) {
        ws?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        // Delivering socket events on .main keeps event handling serial, so the
        // transcript tables below need no locking.
        let session = URLSession(configuration: .default, delegate: nil, delegateQueue: .main)
        self.session = session
        let request = socketRequest(withKeywords: withKeywords)
        // The query string IS the configuration for two of the three dialects,
        // so log it — a rejected session is otherwise very hard to explain.
        // Keys and tokens travel in headers, never here.
        Config.shared.log("Live: connecting \(request.url?.absoluteString ?? "?")")
        let task = session.webSocketTask(with: request)
        ws = task
        task.resume()
        listen(on: task)
        // Google's server says nothing until the client does: the setup goes
        // out now and URLSession holds it until the handshake lands.
        if provider == .gemini { configureGemini(withKeywords: withKeywords) }
        // Meta likewise: the handshake frame carries the key, and the server
        // says nothing until it has read it.
        if provider == .meta { configureMeta(withKeywords: withKeywords) }
        // Soniox never acknowledges its config, so audio flows right behind
        // it: the config goes out first here, and markReady's flush queues
        // after it.
        if provider == .soniox {
            configureSoniox(withKeywords: withKeywords)
            markReady()
        }
        // smallest.ai has no session-started message of any kind — the first
        // thing it ever says is a transcript — so audio flows immediately;
        // URLSession holds the frames until the handshake lands.
        if provider == .smallest { markReady() }
        // Own GPU: the start frame goes first and the audio queues behind it,
        // like Soniox; the gateway's `ready` only marks the session as opened.
        if provider == .gpu {
            configureGPU(withKeywords: withKeywords)
            markReady()
        }
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw err("No microphone input available")
        }
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                            sampleRate: sampleRate,
                                            channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw err("Can't resample the mic to \(Int(sampleRate / 1000)) kHz")
        }
        // One converter for the whole session — it carries the resampler state,
        // so a fresh one per buffer would click at every boundary.
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            self?.handle(buffer, converter: converter, outFormat: outFormat)
        }
        tapped = true
        engine.prepare()
        try engine.start()
    }

    // MARK: - Audio

    private func handle(_ buffer: AVAudioPCMBuffer,
                        converter: AVAudioConverter,
                        outFormat: AVAudioFormat) {
        report(level: buffer)

        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }

        // The converter pulls until it is satisfied; we have exactly one buffer to
        // give, so every later pull reports "nothing right now" rather than EOF —
        // an endOfStream here would tear down the resampler mid-session.
        var consumed = false
        var convError: NSError?
        converter.convert(to: out, error: &convError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard convError == nil, out.frameLength > 0, let pcm = out.int16ChannelData else { return }
        append(Data(bytes: pcm[0], count: Int(out.frameLength) * 2))
    }

    private func report(level buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let samples = channel[0]
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += samples[i] * samples[i] }
        let db = 20 * log10(max(sqrt(sum / Float(n)), 1e-7))
        // Same curve the AVAudioRecorder meter feeds the pill, so the bars move
        // identically in both modes.
        let level = CGFloat(max(0, min(1, (db + 50) / 45)))
        DispatchQueue.main.async { self.onLevel?(level) }
    }

    private func append(_ pcm: Data) {
        tape?.write(pcm)
        sendQueue.async {
            guard !self.stopping else { return }
            guard let minBytes = self.provider.liveMinChunkBytes else {
                return self.enqueue(pcm)
            }
            self.chunkBuffer.append(pcm)
            guard self.chunkBuffer.count >= minBytes else { return }
            let full = self.chunkBuffer
            self.chunkBuffer.removeAll(keepingCapacity: true)
            self.enqueue(full)
        }
    }

    /// sendQueue only. Send it now, or hold it until the session is ready.
    private func enqueue(_ pcm: Data) {
        if ready {
            sendAudio(pcm)
        } else if pending.count < 500 {
            // Audio recorded before the session handshake lands — held back
            // rather than dropped, so the first word survives.
            pending.append(pcm)
        }
    }

    // MARK: - Socket

    /// One frame of microphone audio. AssemblyAI, smallest.ai and Meta read
    /// raw binary off the socket; the others want it base64'd inside JSON.
    private func sendAudio(_ pcm: Data) {
        sentBytes += pcm.count
        sentFrames += 1
        guard provider != .assemblyai, provider != .smallest, provider != .meta,
              provider != .xai, provider != .soniox, provider != .gpu else {
            ws?.send(.data(pcm)) { [weak self] error in
                guard let self = self, let error = error else { return }
                DispatchQueue.main.async { self.fail("Connection lost — \(error.localizedDescription)") }
            }
            return
        }
        send(audioMessage(pcm.base64EncodedString()))
    }

    private func audioMessage(_ base64: String, commit: Bool = false) -> [String: Any] {
        switch provider {
        case .elevenlabs:
            return ["message_type": "input_audio_chunk",
                    "audio_base_64": base64,
                    "commit": commit,
                    "sample_rate": Int(sampleRate)]
        case .gemini:
            return ["realtimeInput": ["audio": [
                "data": base64,
                "mimeType": "audio/pcm;rate=\(Int(sampleRate))",
            ]]]
        default:
            return ["type": "input_audio_buffer.append", "audio": base64]
        }
    }

    /// What ends the dictation. OpenAI commits the turn; ElevenLabs carries the
    /// commit flag on an audio frame, so it gets a short tail of silence to hang
    /// it on; AssemblyAI has no commit at all and ends the session outright,
    /// which is also what makes it flush the closing turn; Google ends the
    /// STREAM, which finalises whatever its VAD still had open.
    private func commitMessage() -> [String: Any] {
        switch provider {
        case .assemblyai:
            return ["type": "Terminate"]
        // smallest.ai flushes whatever its VAD still had open and answers
        // with a final marked `is_last`.
        case .smallest:
            return ["type": "close_stream"]
        // Meta drains what is queued and answers with the whole take marked
        // final.
        case .meta:
            return ["type": "endStream"]
        // xAI finalises whatever its VAD still had open and answers with
        // `transcript.done` — measured 0.4 s behind, with the closing
        // segment's own final just ahead of it.
        case .xai:
            return ["type": "audio.done"]
        // Soniox makes every token final and answers with `<fin>`; the
        // silence it wants ahead of this goes out in `commit`.
        case .soniox:
            return ["type": "finalize"]
        // Own GPU: Qwen3 re-hears the whole take and answers with `final`.
        case .gpu:
            return ["type": "end"]
        case .elevenlabs:
            let silence = Data(count: Int(sampleRate * 0.2) * 2)
            return audioMessage(silence.base64EncodedString(), commit: true)
        case .gemini:
            return ["realtimeInput": ["audioStreamEnd": true]]
        default:
            return ["type": "input_audio_buffer.commit"]
        }
    }

    private func send(_ payload: [String: Any]) {
        guard let ws = ws,
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        ws.send(.string(text)) { [weak self] error in
            guard let self = self, let error = error else { return }
            DispatchQueue.main.async { self.fail("Connection lost — \(error.localizedDescription)") }
        }
    }

    /// The task is captured, so a reconnect's stale receive callback is dropped
    /// instead of being read as this session failing.
    private func listen(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self = self, self.ws === task else { return }
            switch result {
            case .failure(let error):
                guard !self.finished, !self.stopping else { return }
                // A server that closes the socket on purpose says why in the
                // close frame — Google spells billing out in words there
                // ("Your prepayment credits are depleted…") — and that reason
                // beats both URLSession's posix-level "Socket is not
                // connected" and our guess about what went wrong.
                let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let detail = reason.isEmpty ? error.localizedDescription : reason
                // ElevenLabs and xAI take their hint lists in the URL and
                // Google takes its vocabulary in the setup message, but all
                // three report a rejected hint the same way: a refused/closed
                // connection rather than a recoverable error frame. Worth one
                // retry with nothing but the model set — losing live mode over
                // an optional hint would be a bad trade.
                if self.provider == .elevenlabs || self.provider == .gemini || self.provider == .xai,
                   !self.configured, self.sentKeywords, !self.hints.isEmpty {
                    self.sentKeywords = false
                    Config.shared.log("Live: \(self.provider.title) socket refused (\(detail)); retrying without keyterms")
                    self.openSocket(withKeywords: false)
                    return
                }
                // smallest.ai is "ready" the moment the socket opens — there is
                // no handshake — so ready can't tell a refused handshake from a
                // mid-session drop there. Whether the server ever said anything
                // can: a 401 at the upgrade reads as "bad response from the
                // server", and "check the key" is the useful translation.
                // Soniox is the same: ready the moment its config goes out.
                let opened = self.provider == .smallest || self.provider == .soniox
                    ? self.configured : self.ready
                // The relay turns a stale token away before the upgrade; the
                // next take refreshes first.
                if self.cloudBearer != nil, (task.response as? HTTPURLResponse)?.statusCode == 401 {
                    Cloud.shared.accessRefused()
                }
                let refused = self.cloudBearer != nil ? "Couldn't reach SayControl's cloud — try again"
                                                      : "Couldn't open the live session — check the key has access to \(self.model)"
                self.fail(opened ? "Connection lost — \(detail)" : reason.isEmpty ? refused : reason)
            case .success(let message):
                switch message {
                case .string(let text): self.event(text)
                case .data(let data): self.event(String(decoding: data, as: UTF8.self))
                @unknown default: break
                }
                self.listen(on: task)
            }
        }
    }

    /// `turn_detection` stays null: gpt-live-transcribe rejects it outright
    /// ("Turn detection is not supported for this transcription model"), and the
    /// deltas stream while you talk regardless — the turn only has to be closed
    /// by hand with a commit when you let go. Measured against the live API.
    private func configure(withKeywords: Bool) {
        var transcription: [String: Any] = ["model": model]
        let list = hints
        if withKeywords, !list.isEmpty { transcription["keywords"] = list }

        let input: [String: Any] = [
            "format": ["type": "audio/pcm", "rate": Int(sampleRate)],
            "transcription": transcription,
            "turn_detection": NSNull(),
        ]
        send(["type": "session.update",
              "session": ["type": "transcription", "audio": ["input": input]]])
    }

    /// SMART mode over VERBATIM on purpose: measured on the same clip, verbatim
    /// keeps every "um, so" and doubled word, smart drops the fillers and
    /// formats numbers and dates ("$25", "March 3rd") — which is what a pasted
    /// dictation should look like. Language stays unset for auto-detection.
    private func configureGemini(withKeywords: Bool) {
        var transcription: [String: Any] = ["mode": "SMART"]
        let list = hints
        if withKeywords, !list.isEmpty { transcription["customVocabulary"] = list }
        send(["setup": [
            "model": "models/\(model)",
            "generationConfig": ["responseModalities": ["TEXT"]],
            "inputAudioTranscription": transcription,
        ]])
    }

    /// PUSH_TO_TALK over ENDPOINTING on purpose: measured on the same
    /// 142-second clip (2026-09-02), push-to-talk keeps one cumulative
    /// transcript with its punctuation and closes on one final; endpointing
    /// chops it into VAD turns that arrive unpunctuated as `speechComplete`,
    /// and its closing `final` is an empty string. CUMULATIVE partials make
    /// each event the whole text so far — exactly what the preview shows.
    /// Language stays unset: the model code-switches on its own.
    private func configureMeta(withKeywords: Bool) {
        var handshake: [String: Any] = [
            "authorization": ["accessToken": "Bearer \(key)"],
            "model": model,
            "audioEncoding": Int(sampleRate) == 24000 ? "PCM_24KHZ" : "PCM_16KHZ",
            "mode": "PUSH_TO_TALK",
            "partialMode": "CUMULATIVE",
            "emitAudioProgress": false,
        ]
        let list = hints
        if withKeywords, !list.isEmpty { handshake["keywords"] = list }
        send(handshake)
    }

    /// Their example config, less what a dictation doesn't want: no endpoint
    /// detection, because the take ends when you let go, not at a pause.
    ///
    /// The language hint is English ALONE, on purpose. "Take a screenshot"
    /// (1.7 s) sounds like Hindi "ठीक है" ("okay"), and with Bengali or
    /// Hindi anywhere in the hints — or no hints at all — it came back
    /// "ठीक है, स्क्रीनशॉट।" or its Bengali, Urdu or Marathi twin; with English
    /// alone it came back right. Identification stays on, so a Bangla or
    /// Hindi take still comes back in its own script, a 1.4 s "আমি ভালো আছি"
    /// and a take that switches mid-sentence included (measured on the
    /// user's recordings, 2026-09-29: six of six the same as with all three
    /// hinted).
    private func configureSoniox(withKeywords: Bool) {
        var config: [String: Any] = [
            "api_key": key,
            "model": model,
            "audio_format": "pcm_s16le",
            "sample_rate": Int(sampleRate),
            "num_channels": 1,
            "language_hints": ["en"],
            "enable_language_identification": true,
        ]
        let list = hints
        if withKeywords, !list.isEmpty { config["context"] = ["terms": list] }
        send(config)
    }

    /// Own GPU (gpu-server/server.py). English only: both models are.
    private func configureGPU(withKeywords: Bool) {
        var start: [String: Any] = ["type": "start", "sample_rate": Int(sampleRate)]
        let list = hints
        if withKeywords, !list.isEmpty { start["terms"] = list }
        // The text before the caret, when the Qwen3 context option is on (LocalEngine.hint).
        if Config.shared.flag("QWEN3_PREV_TEXT", default: true), !TypingContext.before.isEmpty {
            start["context_text"] = TypingContext.before
        }
        send(start)
    }

    /// The handshake landed: let the audio flow, oldest first.
    private func markReady() {
        sendQueue.async {
            guard !self.ready else { return }
            self.ready = true
            self.readyAt = Date().timeIntervalSince(self.openedAt)
            for chunk in self.pending { self.sendAudio(chunk) }
            self.pending.removeAll()
            if self.commitWhenReady { self.commit() }
        }
    }

    /// sendQueue only. The commit always follows the audio it closes, so the
    /// moment it goes out is the one worth recording: a commit stamped ahead
    /// of the audio is a bug the post-mortem can name.
    private func commit() {
        commitAt = Date().timeIntervalSince(openedAt)
        // Soniox finalises best with ~200 ms of silence after the last word
        // (their guidance), and a take released mid-word has none. One frame,
        // so it costs no wait.
        if provider == .soniox { sendAudio(Data(count: Int(sampleRate * 0.2) * 2)) }
        send(commitMessage())
    }

    private func event(_ raw: String) {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if provider == .elevenlabs { return elevenEvent(json) }
        if provider == .assemblyai { return assemblyEvent(json) }
        if provider == .gemini { return geminiEvent(json) }
        if provider == .smallest { return smallestEvent(json) }
        if provider == .meta { return metaEvent(json) }
        if provider == .xai { return xaiEvent(json) }
        if provider == .soniox { return sonioxEvent(json) }
        if provider == .gpu { return gpuEvent(json) }
        guard let type = json["type"] as? String else { return }

        switch type {
        case "session.created", "transcription_session.created":
            configure(withKeywords: sentKeywords)

        case "session.updated", "transcription_session.updated":
            configured = true
            markReady()

        case "conversation.item.input_audio_transcription.delta":
            guard let id = json["item_id"] as? String,
                  let delta = json["delta"] as? String else { return }
            if deltas[id] == nil, finals[id] == nil { order.append(id) }
            deltas[id, default: ""] += delta
            onText?(transcript)

        case "conversation.item.input_audio_transcription.completed":
            guard let id = json["item_id"] as? String else { return }
            let text = (json["transcript"] as? String) ?? deltas[id] ?? ""
            if deltas[id] == nil, finals[id] == nil { order.append(id) }
            finals[id] = text
            onText?(transcript)
            // Once every turn we know about is final there is nothing left to
            // wait for — don't sit out the rest of the grace period.
            if stoppingOnMain, order.allSatisfy({ finals[$0] != nil }) { complete() }

        case "conversation.item.input_audio_transcription.failed":
            let error = json["error"] as? [String: Any]
            fail((error?["message"] as? String) ?? "The model couldn't transcribe that audio")

        case "error":
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? "Realtime API error"
            // Models differ in which context fields they accept — turn detection
            // is already known to be refused by this one — so a rejected
            // handshake is worth one retry with nothing but the model set,
            // rather than losing live mode over an optional hint.
            if !configured, sentKeywords {
                sentKeywords = false
                Config.shared.log("Live: session.update rejected (\(message)); retrying without keyword hints")
                configure(withKeywords: false)
                return
            }
            fail(message)

        default:
            break
        }
    }

    /// Scribe v2 Realtime. One rolling `partial_transcript` per segment, then a
    /// committed one that supersedes it — so partials are replaced, never
    /// appended, and only committed text accumulates.
    private func elevenEvent(_ json: [String: Any]) {
        guard let type = json["message_type"] as? String else { return }

        switch type {
        case "session_started":
            configured = true
            markReady()

        case "partial_transcript":
            partial = (json["text"] as? String) ?? partial
            heardPartial = true
            onText?(transcript)

        case "committed_transcript", "final_transcript", "committed_transcript_with_timestamps":
            let text = ((json["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // `final_transcript` and `committed_transcript` cover the same
            // ground in the docs. If one segment ever arrives under both names,
            // appending twice would silently double the dictation — so an
            // identical repeat with no partial in between is treated as an echo.
            let echo = text == committed.last && !heardPartial
            if !text.isEmpty, !echo { committed.append(text) }
            heardPartial = false
            partial = ""
            onText?(transcript)
            // Manual commits only happen because we asked, so the one that lands
            // after fn is released is the last of the dictation. (Their ~36 s
            // safety commit is the exception, and costs nothing here: any text
            // it hasn't covered is still sitting in `partial`.)
            if stoppingOnMain { complete() }

        case "error", "auth_error", "quota_exceeded", "rate_limited",
             "chunk_size_exceeded", "invalid_request":
            let message = (json["error"] as? String) ?? "\(provider.title) realtime error (\(type))"
            // The socket opens even for a rejected request and reports the
            // problem as a message, so a hint list this account or model won't
            // take surfaces here rather than as a dropped connection. Worth one
            // reconnect with nothing but the model set — losing live mode over
            // an optional hint would be a bad trade.
            if type == "invalid_request", !configured, sentKeywords, !hints.isEmpty {
                sentKeywords = false
                Config.shared.log("Live: \(provider.title) rejected the session (\(message)); retrying without keyterms")
                openSocket(withKeywords: false)
                return
            }
            fail(message)

        default:
            break
        }
    }

    /// smallest.ai Pulse. One rolling partial per segment (`is_final` false)
    /// that REPLACES what came before, then a final that closes the segment —
    /// so finals accumulate in `committed`, exactly like ElevenLabs. The final
    /// that answers `close_stream` carries `is_last`, and that is the end of
    /// the dictation; a final without it may just be the VAD closing a pause,
    /// with the tail of the sentence still in flight, so it never completes on
    /// its own — the grace timer is the net if `is_last` goes missing.
    private func smallestEvent(_ json: [String: Any]) {
        // Any message at all proves the handshake was accepted — that is what
        // `listen` reads to tell a refused key from a lost connection.
        configured = true
        // Auth failures close the socket with a reason and land in `listen`;
        // an in-band error frame, if one comes, carries no transcript.
        if json["transcript"] == nil {
            if let error = (json["error"] as? String) ?? (json["message"] as? String) {
                fail(error)
            }
            return
        }
        if let text = json["transcript"] as? String {
            if (json["is_final"] as? Bool) == true {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { committed.append(trimmed) }
                partial = ""
            } else {
                partial = text
            }
            onText?(transcript)
        }
        if (json["is_last"] as? Bool) == true { complete() }
    }

    /// Meta's Muse. The handshake is answered by a bare `{sessionId}`; after
    /// that, in PUSH_TO_TALK mode, every `transcript` carries the WHOLE take
    /// so far (partialMode CUMULATIVE) and replaces what came before, and the
    /// one marked `final` — the answer to `endStream`, measured 0.3–0.5 s
    /// behind it — is the dictation. So there is a single rolling partial and
    /// a single committed segment, never a list.
    private func metaEvent(_ json: [String: Any]) {
        guard let type = json["type"] as? String else {
            // The handshake ack: the key was accepted and audio may flow.
            if json["sessionId"] != nil {
                configured = true
                markReady()
            }
            return
        }
        switch type {
        case "transcript":
            let text = (json["transcript"] as? String) ?? ""
            if (json["final"] as? Bool) == true {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                // An empty final is a closed stream with nothing new to say;
                // the rolling partial is still the best text there is.
                if !trimmed.isEmpty { committed = [trimmed] }
                else if !partial.isEmpty { committed = [partial] }
                partial = ""
                onText?(transcript)
                if stoppingOnMain { complete() }
            } else {
                partial = text
                onText?(transcript)
            }

        case "error":
            let message = (json["message"] as? String) ?? "\(provider.title) streaming error"
            // A refused key is final. Anything else that stops the handshake
            // — the hint list, a hiccup in their backend ("temporarily
            // unavailable") — is worth one reconnect with nothing but the
            // model set, rather than losing live mode over an optional hint.
            let refusedKey = (json["errorType"] as? String) == "authentication_error"
            if !refusedKey, !configured, sentKeywords, !hints.isEmpty {
                sentKeywords = false
                Config.shared.log("Live: \(provider.title) rejected the session (\(message)); retrying without keywords")
                openSocket(withKeywords: false)
                return
            }
            fail(message)

        default:
            // speechStart / speechEnd / speechComplete / audioProgress —
            // ENDPOINTING-mode events this session never asks for.
            break
        }
    }

    /// Grok Voice Transcribe. Every `transcript.partial` is one of three
    /// things, and the pair of flags — not the `start` offset — says which:
    ///
    ///   is_final=false                 an interim: the words being heard
    ///                                  right now, REPLACING the last interim
    ///   is_final=true, speech_final=false
    ///                                  a chunk final: ONLY THE NEW WORDS
    ///                                  since the last chunk, to be APPENDED
    ///   is_final=true, speech_final=true
    ///                                  the utterance is over, and this is the
    ///                                  WHOLE of it again — it REPLACES the
    ///                                  chunks that built it
    ///
    /// The `start` offset cannot key any of this, because two different ones
    /// are in flight at once: chunk finals carry the offset of the UTTERANCE
    /// while the interims between them carry the offset of their own CHUNK.
    /// Keying by it (measured 2026-09-19 on a 13.8 s take) left the interims
    /// standing as segments that never closed, and the closing utterance was
    /// pasted with those same words trailing it — "…Can you actually recheck?
    /// couple of sentences here and there. Can you actually recheck?" — while
    /// the chunk finals, all sharing the utterance's offset, overwrote one
    /// another and lost every sentence but the last.
    private func xaiEvent(_ json: [String: Any]) {
        switch json["type"] as? String {
        case "transcript.created":
            configured = true
            markReady()

        case "transcript.partial":
            let text = ((json["text"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let final = (json["is_final"] as? Bool) == true
            let spoken = (json["speech_final"] as? Bool) == true
            if spoken {
                // The best version of everything just said: it supersedes the
                // chunks, so they go rather than being added to. But 1.0 can
                // close with ONLY the last chunk again (measured 2026-10-02:
                // three chunk finals, then a speech_final holding the third
                // alone), and replacing would drop the first two. A closing
                // text with far fewer words than the chunks is not the whole.
                let chunks = pieces.joined(separator: " ")
                let words = { (s: String) in s.split(whereSeparator: { $0.isWhitespace }).count }
                if !text.isEmpty, words(text) * 10 >= words(chunks) * 8 { committed.append(text) }
                else if !chunks.isEmpty { committed.append(chunks) }
                else if !text.isEmpty { committed.append(text) }
                pieces.removeAll()
                partial = ""
            } else if final {
                if !text.isEmpty { pieces.append(text) }
                partial = ""
            } else {
                partial = text
            }
            onText?(transcript)

        case "transcript.done":
            // The end of the stream — and the whole reason the segments above
            // are kept, because its own `text` is always empty (measured).
            // It is also why finishing on "every segment is final" would be
            // wrong here: the last of the audio can still open a NEW segment
            // 0.35 s after `audio.done`, long after the earlier ones closed.
            complete()

        case "error":
            fail((json["message"] as? String) ?? (json["error"] as? String)
                 ?? "\(provider.title) streaming error")

        default:
            break
        }
    }

    /// Soniox. Each response is a list of tokens: `is_final` ones are settled
    /// and never sent again, so they APPEND; the rest are the whole
    /// provisional tail as it stands now, so they REPLACE the last tail.
    /// `<fin>` is the answer to `finalize` — every token before it is final,
    /// and that is the dictation. `<end>` would mark an endpoint, which this
    /// session never asks for. Neither is text.
    private func sonioxEvent(_ json: [String: Any]) {
        if let code = json["error_code"], !(code is NSNull) {
            let message = (json["error_message"] as? String) ?? "\(provider.title) error \(code)"
            // A refused config (400) before any text is worth one reconnect
            // with nothing but the model set — the context is the optional
            // part, and losing it beats losing live mode, even though the
            // audio the refused socket already took goes with it. A bad key
            // is 401 and final.
            if (code as? Int) == 400, !configured, sentKeywords, !hints.isEmpty {
                sentKeywords = false
                Config.shared.log("Live: \(provider.title) rejected the session (\(message)); retrying without terms")
                openSocket(withKeywords: false)
                return
            }
            return fail(message)
        }
        // Any answer that isn't an error means the config was taken — what
        // `listen` reads to tell a refused key from a dropped connection.
        configured = true
        var tail = ""
        var finalized = false
        for token in (json["tokens"] as? [[String: Any]]) ?? [] {
            guard let text = token["text"] as? String else { continue }
            if text == "<fin>" { finalized = true; continue }
            if text == "<end>" { continue }
            if (token["is_final"] as? Bool) == true { sonioxFinal += text } else { tail += text }
        }
        partial = tail
        onText?(transcript)
        // `finished` is the stream closing on its own — the net if `<fin>`
        // never comes.
        if finalized || (json["finished"] as? Bool) == true { complete() }
    }

    /// Own GPU. `partial` is Nemotron's whole take so far, every 560 ms chunk;
    /// `final` is Qwen3's text over the whole take, after `end`. The gateway
    /// closes the socket behind it.
    private func gpuEvent(_ json: [String: Any]) {
        switch json["type"] as? String {
        case "ready":
            configured = true
        case "partial":
            configured = true
            partial = (json["text"] as? String) ?? ""
            onText?(transcript)
        case "final":
            let text = (json["text"] as? String) ?? ""
            // An empty Qwen3 answer over real speech: keep what Nemotron heard.
            gpuFinal = text.isEmpty ? (json["live_text"] as? String) : text
            if let t = json["timing"] as? [String: Any] {
                Config.shared.log("Live: Own GPU final by \(json["source"] as? String ?? "?") — "
                    + "\(t["audio_s"] ?? "?")s take, gateway key-up→final \(t["keyup_to_final_ms"] ?? "?") ms; "
                    + "Nemotron heard: \(Config.words(json["live_text"] as? String ?? ""))")
            }
            onText?(transcript)
            complete()
        case "error":
            fail((json["message"] as? String) ?? "Own GPU error")
        default:
            break
        }
    }

    /// AssemblyAI streaming v3. A `Turn` carries the whole turn transcribed so
    /// far — it REPLACES what came before rather than extending it — and
    /// `end_of_turn` marks the version worth keeping. Measured: the last
    /// unfinished turn is often wrong ("using a symbol") where the finished one
    /// is right ("using AssemblyAI"), so the distinction matters.
    private func assemblyEvent(_ json: [String: Any]) {
        switch json["type"] as? String {
        case "Begin":
            configured = true
            if cloudBearer != nil {
                finalTurnEnds = (json["finalTurnEnds"] as? Bool) ?? true
                onCloudMessage?(json)
            }
            markReady()

        // The relay's: the plan ran out mid-take. The words so far still
        // arrive, then Termination, so the take ends as it would on key-up.
        case "Limit":
            onCloudMessage?(json)

        case "Turn":
            let id = String(json["turn_order"] as? Int ?? 0)
            let text = (json["transcript"] as? String) ?? ""
            if deltas[id] == nil, finals[id] == nil { order.append(id) }
            if (json["end_of_turn"] as? Bool) == true { finals[id] = text }
            else { deltas[id] = text }
            onText?(transcript)
            // Measured: the closing turn lands ~0.37 s after you release fn,
            // but `Termination` trails it by roughly another second. Waiting
            // for the teardown to paste made this provider feel a second
            // slower than it is, so finish on the text, not on the goodbye.
            if finalTurnEnds, stoppingOnMain, order.allSatisfy({ finals[$0] != nil }) { complete() }

        case "Termination":
            // Backstop: the session ended without a final turn ever arriving.
            complete()

        case "Receipt":
            // What the relay heard, signed: the take's model calls carry it
            // (Cloud.noteReceipt).
            if cloudBearer != nil { onCloudMessage?(json) }

        case "Error", "error":
            if cloudBearer != nil { onCloudMessage?(json) }
            fail((json["error"] as? String) ?? "\(provider.title) streaming error")

        default:
            // "SpeechStarted" and anything else informational.
            break
        }
    }

    /// Gemini 3.5 Transcribe Live. One rolling `interimInputTranscription` per
    /// utterance that REPLACES what came before, then an `inputTranscription`
    /// that finalises the utterance and supersedes its interims — so finals
    /// accumulate, one per pause, exactly like AssemblyAI's turns. Measured:
    /// the final is also the better text ("Testing 1 2 3." interim against
    /// "Testing one two three." final on the same clip).
    private func geminiEvent(_ json: [String: Any]) {
        if json["setupComplete"] != nil {
            configured = true
            markReady()
            return
        }
        // Not observed in testing — refusals arrive as a closed socket — but
        // the Live API documents in-band errors, so read one if it comes.
        if let error = json["error"] as? [String: Any] {
            fail((error["message"] as? String) ?? "\(provider.title) streaming error")
            return
        }
        // The server pads the stream with empty serverContent frames; every
        // field here is optional, including all of them at once.
        guard let content = json["serverContent"] as? [String: Any] else { return }

        if let interim = (content["interimInputTranscription"] as? [String: Any])?["text"] as? String {
            let id = String(geminiSegment)
            if deltas[id] == nil, finals[id] == nil { order.append(id) }
            deltas[id] = interim
            onText?(transcript)
        }
        if let final = (content["inputTranscription"] as? [String: Any])?["text"] as? String {
            let id = String(geminiSegment)
            geminiSegment += 1
            if deltas[id] == nil, finals[id] == nil { order.append(id) }
            finals[id] = final
            onText?(transcript)
            // After audioStreamEnd the final flushes at once (measured ~0.2 s),
            // so finish on it rather than sitting out the grace period.
            if stoppingOnMain, order.allSatisfy({ finals[$0] != nil }) { complete() }
        }
        // Follows every final; a backstop in case a final somehow didn't parse.
        if (content["generationComplete"] as? Bool) == true,
           stoppingOnMain, order.allSatisfy({ finals[$0] != nil }) {
            complete()
        }
    }

    // MARK: - Stop

    /// Called when you release fn. The mic stops immediately, but the socket gets
    /// a short grace period to turn the last of the audio into text.
    func finish(grace: TimeInterval? = nil) {
        guard !finished else { return }
        stopEngine()

        // Committing closes the turn and is what produces the final transcript.
        // It queues behind the audio already in flight, so nothing is truncated.
        sendQueue.async {
            // Whatever is short of a full chunk is still the tail of a sentence.
            if !self.chunkBuffer.isEmpty {
                let tail = self.chunkBuffer
                self.chunkBuffer.removeAll(keepingCapacity: true)
                self.enqueue(tail)
            }
            // If the handshake hasn't landed yet the audio is still queued, so the
            // commit has to wait for the flush or it would close an empty turn.
            if self.ready { self.commit() }
            else { self.commitWhenReady = true }
            self.stopping = true
        }
        stoppingOnMain = true
        // No socket yet (a cloud token still on its way): the grace clock
        // starts when it opens, or it would run out on audio never sent.
        if awaitingBearer {
            finishGraceOnConnect = grace ?? effectiveGrace
            return
        }
        armDeadline(grace ?? effectiveGrace)
    }

    private func armDeadline(_ grace: TimeInterval) {
        deadline?.invalidate()
        deadline = Timer.scheduledTimer(withTimeInterval: grace, repeats: false) { [weak self] _ in
            // Grace expired: the deltas we already have are the transcript. This
            // is the safety net that makes the whole thing robust — we never lose
            // text just because a `completed` event didn't arrive.
            self?.complete()
        }
    }

    /// Almost always `provider.liveGrace` — except Google after a pause.
    /// Gemini answers `audioStreamEnd` with a final only when an utterance is
    /// still open; when the VAD already finalised everything it answers with
    /// nothing at all, so the timer here IS the normal exit, not a safety net.
    /// A second and a half is enough for words that were mid-flight without
    /// an interim yet (measured: their final lands ~0.2 s after the end), and
    /// without it every release-after-a-pause would cost the full grace.
    private var effectiveGrace: TimeInterval {
        // Only shorten once something was actually heard AND finalised — with
        // nothing heard yet, text may still be entirely in flight, and that
        // deserves the whole grace period.
        guard provider == .gemini, !order.isEmpty,
              order.allSatisfy({ finals[$0] != nil }) else {
            return provider.liveGrace
        }
        return 1.5
    }

    /// Abandon the session without pasting anything (clip too short, or an error).
    func cancel() {
        guard !finished else { return }
        finished = true
        onFinish = nil
        onText = nil
        onLevel = nil
        onCloudMessage = nil
        teardown()
    }

    private var stoppingOnMain = false

    private func complete() {
        guard !finished else { return }
        finished = true
        deliver(.success(transcript))
    }

    private func fail(_ message: String) {
        guard !finished else { return }
        // Deltas already on screen beat an error message — if we heard anything
        // at all, hand it over instead of throwing the dictation away.
        let salvaged = transcript
        finished = true
        if salvaged.isEmpty {
            deliver(.failure(err(message)))
        } else {
            Config.shared.log("Live: \(message) — keeping the \(salvaged.count) chars already transcribed")
            deliver(.success(salvaged))
        }
    }

    /// The callback is what drops the app's last reference to this object, so it
    /// runs on the next turn of the runloop — after this call stack has unwound
    /// and nothing here will touch `self` again.
    /// A one-line post-mortem for every cloud live session — the answer to the
    /// local ear's "heard 31.1s in 311 buffers". An empty paste otherwise looks
    /// identical whether the handshake never landed, the audio never went out,
    /// the commit raced ahead of it, or the model simply heard nothing.
    private func logSummary() {
        let (bytes, frames, ready, commit) = sendQueue.sync {
            (sentBytes, sentFrames, readyAt, commitAt)
        }
        func at(_ t: TimeInterval?) -> String {
            t.map { String(format: "%.1fs", $0) } ?? "never"
        }
        // Soniox keeps tokens, not segments: the take is one.
        let segments = provider == .soniox || provider == .gpu ? (transcript.isEmpty ? 0 : 1)
            : order.isEmpty ? committed.count + (partial.isEmpty ? 0 : 1) : order.count
        Config.shared.log(String(
            format: "Live: %@ ready %@, commit %@, streamed %.1fs in %d frame(s) — %d segment(s), %d chars",
            provider.title, at(ready), at(commit),
            Double(bytes) / (sampleRate * 2), frames, segments, transcript.count))
    }

    private func deliver(_ result: Result<String, Error>) {
        logSummary()
        teardown()
        let callback = onFinish
        onFinish = nil
        onText = nil
        onLevel = nil
        onCloudMessage = nil
        DispatchQueue.main.async { callback?(result) }
    }

    private func stopEngine() {
        if tapped {
            engine.inputNode.removeTap(onBus: 0)
            tapped = false
        }
        if engine.isRunning { engine.stop() }
    }

    private func teardown() {
        deadline?.invalidate()
        deadline = nil
        stopEngine()
        ws?.cancel(with: .goingAway, reason: nil)
        ws = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func err(_ message: String) -> NSError {
        NSError(domain: "SayCtrl", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
