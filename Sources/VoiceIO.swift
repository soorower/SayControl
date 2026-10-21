import AVFoundation
import Foundation

/// The agent voice's mouth and ear.
///
/// One plain AVAudioEngine per episode — built when the first word is
/// about to play, released when the ear closes — carries the voice OUT
/// through a player node and the reply IN through the input tap. Plain,
/// because the echo-cancelling voice-processing unit silences every other
/// audio engine in the process for as long as it exists (measured
/// 2026-08-24: the dictation mic returned zero buffers after one episode
/// until the app was relaunched). Talking over the voice is still heard:
/// the ear measures how loud the voice comes back through the microphone
/// and only counts what is clearly louder than that as the user.
///
/// The words come from ElevenLabs when a key is set (streamed, so speech
/// starts before the whole line is rendered), and from the Mac's own
/// voice otherwise.
final class VoiceIO: NSObject, AVSpeechSynthesizerDelegate, URLSessionDataDelegate {
    static let shared = VoiceIO()

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                       channels: 1, interleaved: false)!
    /// What the player is wired for: ElevenLabs' PCM and the Mac voice both
    /// come as 22.05 kHz mono float.
    private let voiceFormat = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)!

    private let synth = AVSpeechSynthesizer()

    /// Owns `samples` and the endpointer — the tap runs on an audio thread.
    private let queue = DispatchQueue(label: "sayctrl.voiceio")
    private var samples: [Float] = []
    private var capturing = false

    // Speaking (main-queue state)
    private(set) var speaking = false
    private var speakDone: ((Bool) -> Void)?
    private var onProgress: ((Double) -> Void)?
    private var interrupted = false
    /// Bumped by every speak, so a voice that answers after a newer line
    /// began (the relay waits on a token first) is dropped.
    private var utterance = 0
    private var pendingBuffers = 0
    private var sourceFinished = false
    /// More of the line is on its way (an update's summary, after "… finished."
    /// is already playing): when the audio in hand runs out the turn stays
    /// open, and `follow` hands over the rest.
    private var awaitingMore = false
    /// The rest, waiting for the stream in flight to end before its own starts.
    private var queuedMore: String?
    /// A piece is being fetched (from startSource to its sourceDone), token
    /// wait included, so a second never runs beside it.
    private var sourceBusy = false
    private var scheduledFrames: AVAudioFramePosition = 0
    private var playedFrames: AVAudioFramePosition = 0
    private var expectedFrames: AVAudioFramePosition = 0
    private var progressTimer: Timer?

    // The TTS stream (ElevenLabs or OpenAI — same delegate, same player)
    private var streamSession: URLSession?
    private var streamTask: URLSessionDataTask?
    private var streamLeftover = Data()
    private var streamBytes = 0
    private var streamStatus = 0
    private var streamFallback = ""
    /// What the current stream delivers: ElevenLabs sends 22.05 kHz,
    /// OpenAI 24 kHz — anything off the player's wiring is resampled.
    private var streamRate: Double = 22050
    private var streamConverter: AVAudioConverter?
    private var streamProvider = "ElevenLabs"
    /// A failed request's body — the API says why in there ("quota_
    /// exceeded"), and an HTTP status alone cost a morning of guessing.
    private var streamErrorBody = Data()
    /// Inworld's stream is newline-delimited JSON, not raw PCM — the
    /// delegate parses lines instead of counting bytes while this is set.
    private var streamJSONL = false
    /// The last failure, said for the settings pane ("key out of credits");
    /// nil while the voice is working.
    private(set) var lastVoiceError: String?

    // Endpointer (queue-owned)
    private enum Phase { case off, waiting(Date), speech(began: Date, lastVoice: Date) }
    private var phase: Phase = .off
    private var loudRun = 0
    private let base: Float = 0.006
    private var silenceAfter: TimeInterval = 2.0
    private var maxSeconds: TimeInterval = 30
    private var onSpeech: (() -> Void)?
    private var listenDone: (([Float]?) -> Void)?
    /// The streaming Silero: fed every frame while the ear is open, state
    /// carried, so it knows a voice the moment one starts — a fresh-state
    /// batch call scored the opening of any reply near zero (measured
    /// 2026-08-24, the "not a voice" era).
    private var earVAD: EarVAD?
    private var lastStrongVoice = Date.distantPast   // prob ≥ 0.5: a voice began
    private var lastAnyVoice = Date.distantPast      // prob ≥ 0.35: still talking
    private var lastProb: Float = 0
    /// The first beat of a listen is the app's own "recording started" chime
    /// — it scored vad 0.5–0.6 and opened takes nobody was speaking into
    /// (measured 2026-08-24). The VAD's word only counts from here on; the
    /// dictation is already rolling, so nothing said early is lost.
    private var triggerArmedAt = Date.distantPast
    /// Strips the sub-bass the chassis and the room press into the mic.
    /// Measured 2026-08-24: a desk rumble at rms 0.17 carried 99% of a real
    /// dictation's energy below 500 Hz — ASR reads speech per-band and sailed
    /// through it, but the VAD reads the raw waveform and drowned, which is
    /// why the ear worked at a quiet desk at night and went deaf by day.
    /// Second-order high-pass, 120 Hz at 16 kHz; speech lives above.
    private struct HighPass {
        private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
        private let b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
        init(cutoff: Double = 120, rate: Double = 16000) {
            let w0 = 2 * Double.pi * cutoff / rate
            let alpha = sin(w0) / (2 * 0.707)
            let c = cos(w0), a0 = 1 + alpha
            b0 = Float((1 + c) / 2 / a0); b1 = Float(-(1 + c) / a0); b2 = Float((1 + c) / 2 / a0)
            a1 = Float(-2 * c / a0); a2 = Float((1 - alpha) / a0)
        }
        mutating func run(_ x: inout [Float]) {
            for i in 0..<x.count {
                let x0 = x[i]
                let y0 = b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                x[i] = y0
                x2 = x1; x1 = x0; y2 = y1; y1 = y0
            }
        }
    }
    private var hpf = HighPass()

    /// How loud the voice comes back through the mic (queue-owned, decays).
    private var echo: Float = 0
    /// The room: follows the quiet between words, so a fan or a street
    /// doesn't count as someone talking.
    private var floor: Float = 0.002
    private var voiceOn = false
    private var voiceOnSince = Date.distantPast

    private override init() {
        super.init()
        synth.delegate = self
    }

    // MARK: Engine

    private func ensureEngine() -> Bool {
        if let e = engine, e.isRunning { return true }
        hpf = HighPass()   // fresh filter state for a fresh tap
        let e = AVAudioEngine()
        let p = AVAudioPlayerNode()
        e.attach(p)
        e.connect(p, to: e.mainMixerNode, format: voiceFormat)
        let outRate = e.outputNode.outputFormat(forBus: 0).sampleRate
        if let outFmt = AVAudioFormat(standardFormatWithSampleRate: outRate > 0 ? outRate : 48000, channels: 2) {
            e.connect(e.mainMixerNode, to: e.outputNode, format: outFmt)
        }
        // The tap goes on BEFORE start: installing it on a running engine
        // reconfigures the graph and stops the player (measured 2026-08-24:
        // buffers queued, nothing rendered, isPlaying false).
        let input = e.inputNode
        let inFmt = input.outputFormat(forBus: 0)
        if inFmt.sampleRate > 0, inFmt.channelCount > 0, let conv = AVAudioConverter(from: inFmt, to: target) {
            converter = conv
            input.installTap(onBus: 0, bufferSize: 1024, format: inFmt) { [weak self] buf, _ in
                self?.ingest(buf)
            }
            Config.shared.log("Agent voice: engine up — mic \(AudioInputs.default?.name ?? "?") "
                + "at \(Int(inFmt.sampleRate)) Hz ×\(inFmt.channelCount), out \(Int(outRate)) Hz")
        } else {
            Config.shared.log("Agent voice: no microphone input — the voice plays, the ear stays shut")
            converter = nil
        }
        e.prepare()
        do { try e.start() } catch {
            Config.shared.log("Agent voice: audio engine failed — \(error.localizedDescription)")
            if converter != nil { input.removeTap(onBus: 0) }
            converter = nil
            return false
        }
        // A route change (new default mic, AirPods joining) invalidates the
        // wiring; the engine may keep "running" while its formats no longer
        // match the device. Drop it and let the next episode rebuild fresh.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                               object: e, queue: .main) { [weak self] _ in
            guard let self = self, self.engine === e else { return }
            Config.shared.log("Agent voice: audio configuration changed — dropping the engine")
            self.stopAll()
        }
        engine = e
        player = p
        return true
    }

    private func teardownEngine() {
        guard let e = engine else { return }
        if converter != nil { e.inputNode.removeTap(onBus: 0) }
        player?.stop()
        e.stop()
        engine = nil
        player = nil
        converter = nil
    }

    /// Stop everything: the voice, the ear, and the engine.
    func stopAll() {
        let wasSpeaking = speaking
        endSpeech()
        queue.sync {
            phase = .off
            capturing = false
            samples = []
            onSpeech = nil
        }
        let ld = listenDone; listenDone = nil
        teardownEngine()
        if wasSpeaking {
            let d = speakDone; speakDone = nil
            d?(true)
        }
        ld?(nil)
    }

    private func endSpeech() {
        speaking = false
        interrupted = true
        progressTimer?.invalidate()
        progressTimer = nil
        streamTask?.cancel()
        streamTask = nil
        synth.stopSpeaking(at: .immediate)
        player?.stop()
        queue.async { self.voiceOn = false }
    }

    // MARK: Speaking

    /// Say `text`. `onProgress` gets the fraction of the audio that has
    /// played (main queue, ~10 Hz); `completion(true)` means it was cut
    /// short — by `stopAll`, or by the listener hearing the user start.
    /// `mood` is an ElevenLabs v3 audio tag ("excited", "curious") put in
    /// front of the line; the other models would read it out, so it only
    /// goes to v3.
    /// `more` says the line goes on: what `follow(with:)` brings later is
    /// played straight after it, in the same turn, and `completion` waits for
    /// that too — so an update can start speaking while its summary is still
    /// being written.
    func speak(_ text: String, mood: String? = nil, more: Bool = false, onProgress: ((Double) -> Void)? = nil,
               completion: @escaping (Bool) -> Void) {
        if speaking { stopSpeaking() }
        utterance += 1
        interrupted = false
        speaking = true
        speakDone = completion
        self.onProgress = onProgress
        pendingBuffers = 0
        sourceFinished = false
        awaitingMore = more
        queuedMore = nil
        sourceBusy = false
        scheduledFrames = 0
        playedFrames = 0
        // The line's length says how long the audio should be, until the
        // stream says better — the panel paces itself on this.
        expectedFrames = AVAudioFramePosition(Double(text.count) / 15.0 * voiceFormat.sampleRate)
        guard ensureEngine(), let player = player else {
            Config.shared.log("Agent voice: speaking without the engine")
            let utt = AVSpeechUtterance(string: text)
            if let v = Self.appleVoice() { utt.voice = v }
            synth.speak(utt)
            return
        }
        _ = player
        queue.async { self.voiceOn = true; self.voiceOnSince = Date(); self.echo = 0 }
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tickProgress()
        }
        startSource(text, mood: mood)
    }

    /// The rest of a line begun with `speak(more: true)`: queued behind the
    /// audio already playing, so the two run as one. nil or empty means
    /// there is no more, and the turn ends when what's playing does. Too
    /// late (the voice was cut off, or a newer line began) it does nothing.
    func follow(with text: String?) {
        guard speaking, !interrupted, awaitingMore else { return }
        awaitingMore = false
        guard let text = text, !text.isEmpty else {
            if !sourceBusy, queuedMore == nil { sourceDone() }
            return
        }
        guard engine != nil else {
            let utt = AVSpeechUtterance(string: text)
            if let v = Self.appleVoice() { utt.voice = v }
            synth.speak(utt)
            return
        }
        expectedFrames = scheduledFrames + AVAudioFramePosition(Double(text.count) / 15.0 * voiceFormat.sampleRate)
        if sourceBusy { queuedMore = text } else { startSource(text, mood: nil) }
    }

    /// One piece of the line into the player, from whichever provider speaks:
    /// a canned take, SayControl's cloud, or the developers' own keys.
    private func startSource(_ text: String, mood: String?) {
        sourceBusy = true
        // On SayControl's cloud the server speaks, in its own model; the
        // developers' voice settings below never come into it.
        let relay = Config.shared.agentCloud
        let model = relay ? Self.relayModel : (Config.shared.env()["AGENT_TTS_MODEL"] ?? Self.defaultModel)
        // Only the models that read bracket tags as moods get one in front —
        // the rest would say the word "excited" out loud.
        let text = (mood != nil && (model.hasPrefix("eleven_v3") || model.hasPrefix("inworld-") || model.hasPrefix("soniox-")))
            ? "[\(mood!)] \(text)" : text
        // The everyday one-liners — "Sent.", "Okay.", an update's "… finished."
        // — play from disk whichever provider renders them; a mood-tagged
        // line is a fresh render by definition. A miss still streams (nothing waits on the
        // cache) and quietly earns its takes for next time. See CannedClips.
        let tagged = text.hasPrefix("[")
        func cannedOrNil(voice: String, speed: String?) -> Bool {
            guard !tagged,
                  let pcm = CannedClips.shared.clip(for: text, voice: voice, model: model, speed: speed),
                  let buf = Self.pcm16ToBuffer(pcm, format: voiceFormat) else { return false }
            expectedFrames = scheduledFrames + AVAudioFramePosition(buf.frameLength)
            schedule(buf)
            sourceDone()
            Config.shared.log("Agent voice: “\(text)” from a canned take")
            return true
        }
        if relay {
            let voice = Self.relayVoice()
            let speed = Config.shared.env()["AGENT_VOICE_SPEED"]
            if cannedOrNil(voice: voice, speed: speed) { return }
            return streamRelay(text, voice: voice, speed: speed, fill: !tagged)
        }
        // Inworld goes by model id and wins over the compat base URL — an
        // "inworld-…" model means Inworld, whatever else .env still carries.
        if let key = Self.inworldKey(model: model) {
            let voice = Self.inworldVoice()
            let speed = Config.shared.env()["AGENT_VOICE_SPEED"]
            if cannedOrNil(voice: voice, speed: speed) { return }
            if !tagged { CannedClips.shared.fill(for: text, key: key, voice: voice, model: model, speed: speed) }
            streamInworld(text, key: key, model: model)
        } else if let compat = Self.compatTTS(model: model) {
            let voice = Self.openAIVoice()
            if cannedOrNil(voice: voice, speed: nil) { return }
            if !tagged { CannedClips.shared.fill(for: text, key: compat.key, voice: voice, model: model, speed: nil) }
            streamCompat(text, endpoint: compat, mood: mood)
        } else if let key = Config.shared.env()["ELEVENLABS_API_KEY"], !key.isEmpty {
            let voice = Config.shared.env()["AGENT_VOICE_ID"] ?? "nPczCjzI2devNBz1zQrb"
            let speed = Config.shared.env()["AGENT_VOICE_SPEED"]
            if cannedOrNil(voice: voice, speed: speed) { return }
            if !tagged { CannedClips.shared.fill(for: text, key: key, voice: voice, model: model, speed: speed) }
            streamEleven(text, key: key)
        } else {
            speakApple(text)
        }
    }

    /// Cut the voice off but keep the ear open — the user started talking
    /// over it.
    func stopSpeaking() {
        guard speaking else { return }
        endSpeech()
        let d = speakDone; speakDone = nil
        d?(true)
    }

    private func finishSpeaking() {
        guard speaking else { return }
        onProgress?(1)
        speaking = false
        progressTimer?.invalidate()
        progressTimer = nil
        queue.async { self.voiceOn = false }
        let d = speakDone; speakDone = nil
        d?(false)
    }

    private func tickProgress() {
        guard speaking, let p = player, p.isPlaying, let nodeTime = p.lastRenderTime,
              nodeTime.isSampleTimeValid || nodeTime.isHostTimeValid,
              let t = p.playerTime(forNodeTime: nodeTime) else { return }
        playedFrames = t.sampleTime
        let total = sourceFinished ? scheduledFrames : max(scheduledFrames, expectedFrames)
        guard total > 0 else { return }
        onProgress?(min(0.999, Double(playedFrames) / Double(total)))
    }

    /// One buffer of voice into the player. The last one, once the source
    /// is done, ends the speech when it has actually been heard.
    private func schedule(_ pcm: AVAudioPCMBuffer) {
        guard speaking, !interrupted, let player = player else { return }
        pendingBuffers += 1
        scheduledFrames += AVAudioFramePosition(pcm.frameLength)
        // play() before anything is scheduled is ignored (measured
        // 2026-08-24: buffers queued, nothing rendered) — start on the first.
        // And play() on a stopped ENGINE throws an NSException that Swift
        // cannot catch (crashed 2026-08-26, SIGABRT in StartImpl — a config
        // change had stopped the engine mid-speak): never play into one.
        if !player.isPlaying {
            guard let e = engine, e.isRunning else {
                Config.shared.log("Agent voice: engine stopped under the player — dropping the line")
                stopSpeaking()
                return
            }
            player.play()
        }
        player.scheduleBuffer(pcm, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.pendingBuffers -= 1
                if self.sourceFinished && self.pendingBuffers == 0 { self.finishSpeaking() }
            }
        }
    }

    private func sourceDone() {
        guard speaking, !interrupted else { return }
        sourceBusy = false
        // The rest of the line came while this piece streamed: it starts now,
        // its audio queued behind what is still playing.
        if let more = queuedMore {
            queuedMore = nil
            return startSource(more, mood: nil)
        }
        // More is still being written: hold the turn open for it.
        guard !awaitingMore else { return }
        sourceFinished = true
        if pendingBuffers == 0 { finishSpeaking() }
    }

    // MARK: ElevenLabs

    /// v3 is the expressive one — it takes mood tags and lands closer to a
    /// person talking; measured 2026-08-24 it costs ~0.6 s more to the first
    /// word than turbo. Stability is Natural (0.5): Creative (0.0) can run
    /// away with a line. An Inworld key moves the default there: tts-2-flash
    /// reads the same mood tags and answers faster than either.
    static var defaultModel: String {
        let key = Config.shared.env()["INWORLD_API_KEY"]
        return (key?.isEmpty == false) ? "inworld-tts-2-flash" : "eleven_v3"
    }

    /// Streams 16-bit PCM at 22.05 kHz; every 0.2 s of audio that arrives is
    /// scheduled at once, so the first words play while the rest renders.
    private func streamEleven(_ text: String, key: String) {
        let voice = Config.shared.env()["AGENT_VOICE_ID"] ?? "nPczCjzI2devNBz1zQrb"   // Brian, warm US narrator
        let model = Config.shared.env()["AGENT_TTS_MODEL"] ?? Self.defaultModel
        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voice)/stream?output_format=pcm_22050")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var settings: [String: Any] = model.hasPrefix("eleven_v3")
            ? ["stability": 0.5, "similarity_boost": 0.85, "use_speaker_boost": true]
            : ["stability": 0.3, "similarity_boost": 0.8, "style": 0.65, "use_speaker_boost": true]
        // AGENT_VOICE_SPEED in .env — 1.0 is the voice's own pace; the API
        // takes 0.7–1.2. Only sent when set, so the request stays exactly
        // as it was for everyone who never touches it.
        if let raw = Config.shared.env()["AGENT_VOICE_SPEED"], let v = Double(raw) {
            settings["speed"] = min(1.2, max(0.7, v))
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "text": text,
            "model_id": model,
            "voice_settings": settings,
        ])
        req.timeoutInterval = 15
        if streamSession == nil {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 15
            streamSession = URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
        }
        streamLeftover = Data()
        streamBytes = 0
        streamStatus = 0
        streamFallback = text
        streamErrorBody = Data()
        streamRate = 22050
        streamConverter = nil
        streamProvider = "ElevenLabs"
        streamJSONL = false
        let task = streamSession!.dataTask(with: req)
        streamTask = task
        task.resume()
    }

    // MARK: SayControl's cloud

    /// The model SayControl's cloud speaks in: our own, Kokoro, on the
    /// server's voice box (AGENT_VOICE_VENDOR; Soniox stands in when the box
    /// is down). It is named here for the cache's file names, so a change of
    /// voice grows fresh takes of "Sent." and the rest; Kokoro reads no mood
    /// tags, so none go in front.
    static let relayModel = "kokoro-82m"
    /// The cloud's two voices, as the Agents pane offers them.
    static let relayVoices = [(id: "af_heart", name: "Woman"), (id: "am_puck", name: "Man")]
    /// The voice it speaks in: the one picked in the Agents pane
    /// (AGENT_CLOUD_VOICE), Heart, a woman's, until one is.
    static func relayVoice() -> String {
        let picked = Config.shared.env()["AGENT_CLOUD_VOICE"] ?? ""
        return relayVoices.contains { $0.id == picked } ? picked : relayVoices[0].id
    }

    /// The line, spoken by SayControl's cloud in the open agent
    /// conversation, which the server takes its characters off: the same
    /// Inworld stream as below, on the server's key. With no conversation
    /// open, or no way to sign the request, the Mac's own voice says it.
    private func streamRelay(_ text: String, voice: String, speed: String?, fill: Bool) {
        guard let conversation = AgentBridge.shared.conversationID else {
            Config.shared.log("Agent voice: no conversation open — the Mac voice says it")
            return speakApple(text)
        }
        let turn = utterance
        Cloud.shared.speakRequest(conversation: conversation, text: text, voice: voice,
                                  speed: speed.flatMap(Double.init)) { [weak self] req in
            guard let self = self, turn == self.utterance, self.speaking, !self.interrupted else { return }
            guard let req = req else {
                Config.shared.log("Agent voice: not signed in — the Mac voice says it")
                return self.speakApple(text)
            }
            if fill { CannedClips.shared.fill(for: text, conversation: conversation, voice: voice, speed: speed) }
            self.startJSONL(req, text: text, provider: "SayControl")
        }
    }

    // MARK: Inworld

    /// The Inworld leg: any "inworld-…" model with INWORLD_API_KEY set —
    /// the Base64 "key:secret" pair from the portal, sent back verbatim as
    /// Basic auth. AGENT_INWORLD_VOICE names the speaker; Shaun — a
    /// friendly, conversational male — keeps the agent's persona when
    /// nobody has picked one.
    static func inworldKey(model: String) -> String? {
        guard model.hasPrefix("inworld-"),
              let key = Config.shared.env()["INWORLD_API_KEY"], !key.isEmpty else { return nil }
        return key
    }
    static func inworldVoice() -> String {
        Config.shared.env()["AGENT_INWORLD_VOICE"] ?? "Shaun"
    }

    /// The audio_config every Inworld request sends: PCM in a WAV wrapper
    /// at the player's own 22.05 kHz, so nothing needs resampling — and
    /// AGENT_VOICE_SPEED rides along as speaking_rate (Inworld takes
    /// 0.5–1.5) exactly like the ElevenLabs leg.
    static func inworldAudioConfig(speed: String?) -> [String: Any] {
        var audio: [String: Any] = ["audio_encoding": "LINEAR16", "sample_rate_hertz": 22050]
        if let raw = speed, let v = Double(raw) { audio["speaking_rate"] = min(1.5, max(0.5, v)) }
        return audio
    }

    /// Streams newline-delimited JSON: each complete line carries a small
    /// base64 WAV (~0.5 s of 16-bit PCM), scheduled as it lands so the
    /// first words play while the rest renders — same player, same
    /// fallback as the other providers.
    private func streamInworld(_ text: String, key: String, model: String) {
        var req = URLRequest(url: URL(string: "https://api.inworld.ai/tts/v1/voice:stream")!)
        req.httpMethod = "POST"
        req.setValue("Basic \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "text": text,
            "voice_id": Self.inworldVoice(),
            "model_id": model,
            "audio_config": Self.inworldAudioConfig(speed: Config.shared.env()["AGENT_VOICE_SPEED"]),
        ])
        req.timeoutInterval = 15
        startJSONL(req, text: text, provider: "Inworld")
    }

    /// Inworld's newline-delimited stream, from Inworld or from SayControl's
    /// cloud passing it through: 22.05 kHz WAV pieces, played as they land.
    private func startJSONL(_ req: URLRequest, text: String, provider: String) {
        if streamSession == nil {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 15
            streamSession = URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
        }
        streamLeftover = Data()
        streamBytes = 0
        streamStatus = 0
        streamFallback = text
        streamErrorBody = Data()
        streamRate = 22050
        streamConverter = nil
        streamProvider = provider
        streamJSONL = true
        let task = streamSession!.dataTask(with: req)
        streamTask = task
        task.resume()
    }

    /// Complete lines out of the stream buffer — a partial line waits for
    /// the next packet (`final` flushes it at end of stream). Each line's
    /// WAV loses its header and the samples go straight to the player.
    private func ingestInworld(final: Bool) {
        let nl = UInt8(ascii: "\n")
        let whole = final || streamLeftover.last == nl
        var lines = streamLeftover.split(separator: nl, omittingEmptySubsequences: true)
        streamLeftover = whole ? Data() : Data(lines.popLast() ?? Data())
        for line in lines {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let b64 = (obj["result"] as? [String: Any])?["audioContent"] as? String,
                  let wav = Data(base64Encoded: b64),
                  let pcm = Self.wavBody(wav), pcm.count >= 2 else { continue }
            streamBytes += pcm.count
            scheduleStream(pcm)
        }
    }

    /// The samples inside a WAV container: everything past the "data"
    /// chunk header. The tag is found, not assumed at byte 36 — writers
    /// differ on the fmt chunk's size.
    static func wavBody(_ wav: Data) -> Data? {
        guard let tag = wav.range(of: Data("data".utf8), options: [],
                                  in: 0..<min(wav.count, 256)),
              wav.count > tag.upperBound + 4 else { return nil }
        return wav.subdata(in: (tag.upperBound + 4)..<wav.count)
    }

    // MARK: OpenAI-compatible TTS (OpenAI, OpenRouter, DeepInfra, a local server)

    /// Where the OpenAI-shaped speech endpoint lives, when one is
    /// configured: AGENT_TTS_BASE_URL points anywhere that speaks the
    /// /audio/speech dialect (OpenRouter, DeepInfra, a local OmniVoice or
    /// Qwen server), and a bare "gpt-…" model means OpenAI itself. The key
    /// is AGENT_TTS_KEY, or the account key that matches the host.
    static func compatTTS(model: String) -> (url: URL, key: String)? {
        let env = Config.shared.env()
        let base = env["AGENT_TTS_BASE_URL"] ?? (model.hasPrefix("gpt-") ? "https://api.openai.com/v1" : nil)
        guard var base = base else { return nil }
        if base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/audio/speech") else { return nil }
        let key = env["AGENT_TTS_KEY"]
            ?? (base.contains("openrouter") ? env["OPENROUTER_API_KEY"] : env["OPENAI_API_KEY"])
        guard let key = key, !key.isEmpty else { return nil }
        return (url, key)
    }

    /// What the endpoint's PCM comes back as. OpenAI renders 24 kHz;
    /// another host can differ — AGENT_TTS_PCM_RATE says so.
    static func compatRate() -> Double {
        Double(Config.shared.env()["AGENT_TTS_PCM_RATE"] ?? "") ?? 24000
    }

    /// The host's short name, for the log and the settings pane.
    static func compatProvider(_ url: URL) -> String {
        let host = url.host ?? "TTS"
        if host.contains("openai.com") { return "OpenAI" }
        if host.contains("openrouter") { return "OpenRouter" }
        if host.contains("deepinfra") { return "DeepInfra" }
        return host
    }

    /// The stand-in persona the voice wears — a young colleague, not a
    /// narrator. AGENT_TTS_INSTRUCTIONS in .env overrides the whole
    /// thing; a mood ("excited") rides on the end either way.
    static func openAIVoice() -> String {
        Config.shared.env()["AGENT_TTS_VOICE"] ?? Config.shared.env()["AGENT_OPENAI_VOICE"] ?? "ash"
    }
    static func openAIInstructions(mood: String? = nil) -> String {
        var s = Config.shared.env()["AGENT_TTS_INSTRUCTIONS"]
            ?? "Voice: a bright, friendly engineer in his mid-twenties — a helpful colleague across the desk, not an announcer. Tone: warm, casual, human; natural pauses, a smile in the voice. Pace: brisk but easy."
        if let mood = mood { s += " Right now, sound \(mood)." }
        return s
    }

    /// Any OpenAI-shaped speech endpoint — gpt-4o-mini-tts on OpenAI, a
    /// model behind OpenRouter, or a local server: streams 16-bit PCM
    /// (rate per AGENT_TTS_PCM_RATE, 24 kHz by default), scheduled through
    /// the same player — the delegate resamples to the wiring. No speed
    /// parameter here; the instructions carry the pace.
    private func streamCompat(_ text: String, endpoint: (url: URL, key: String), mood: String?) {
        let model = Config.shared.env()["AGENT_TTS_MODEL"] ?? "gpt-4o-mini-tts"
        var req = URLRequest(url: endpoint.url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(endpoint.key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model,
            "input": text,
            "voice": Self.openAIVoice(),
            "instructions": Self.openAIInstructions(mood: mood),
            "response_format": "pcm",
        ])
        req.timeoutInterval = 15
        if streamSession == nil {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 15
            streamSession = URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
        }
        streamLeftover = Data()
        streamBytes = 0
        streamStatus = 0
        streamFallback = text
        streamErrorBody = Data()
        streamRate = Self.compatRate()
        streamConverter = nil
        streamProvider = Self.compatProvider(endpoint.url)
        streamJSONL = false
        let task = streamSession!.dataTask(with: req)
        streamTask = task
        task.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        streamStatus = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === streamTask else { return }
        if streamStatus != 200 {
            if streamErrorBody.count < 2048 { streamErrorBody.append(data) }
            return
        }
        guard speaking, !interrupted else { return }
        streamLeftover.append(data)
        if streamJSONL { return ingestInworld(final: false) }
        // Whole samples only; hand the player ≥0.2 s at a time.
        let frames = streamLeftover.count / 2
        guard frames >= Int(streamRate / 5) else { return }
        let take = frames * 2
        let chunk = streamLeftover.prefix(take)
        streamLeftover.removeFirst(take)
        streamBytes += take
        scheduleStream(chunk)
    }

    /// A chunk of the stream's PCM into the player — resampled first when
    /// the source rate isn't the player's wiring (OpenAI's 24 kHz).
    private func scheduleStream(_ chunk: Data) {
        if streamRate == voiceFormat.sampleRate {
            if let pcm = Self.pcm16ToBuffer(chunk, format: voiceFormat) { schedule(pcm) }
            return
        }
        guard let srcFormat = AVAudioFormat(standardFormatWithSampleRate: streamRate, channels: 1),
              let src = Self.pcm16ToBuffer(chunk, format: srcFormat) else { return }
        if streamConverter == nil { streamConverter = AVAudioConverter(from: srcFormat, to: voiceFormat) }
        guard let conv = streamConverter else { return }
        let ratio = voiceFormat.sampleRate / streamRate
        guard let out = AVAudioPCMBuffer(pcmFormat: voiceFormat,
                                         frameCapacity: AVAudioFrameCount(Double(src.frameLength) * ratio) + 16) else { return }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, st in
            if fed { st.pointee = .noDataNow; return nil }
            fed = true; st.pointee = .haveData; return src
        }
        if err == nil, out.frameLength > 0 { schedule(out) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === streamTask else { return }
        streamTask = nil
        guard speaking, !interrupted else { return }
        if streamStatus != 200 || (error != nil && streamBytes == 0) {
            // The body names the actual problem — "quota_exceeded" reads as
            // "out of credits", which a bare 401 never said. ElevenLabs
            // wraps it in "detail", OpenAI in "error".
            var why = error.map { " — \($0.localizedDescription)" } ?? ""
            let obj = (try? JSONSerialization.jsonObject(with: streamErrorBody)) as? [String: Any]
            if let detail = (obj?["detail"] ?? obj?["error"]) as? [String: Any] {
                let code = (detail["status"] as? String) ?? (detail["code"] as? String) ?? ""
                why = " — \(detail["message"] as? String ?? code)"
                lastVoiceError = code == "quota_exceeded"
                    ? "The \(streamProvider) key is out of credits — the Mac's voice is standing in."
                    : "\(streamProvider) refused (\(code.isEmpty ? "HTTP \(streamStatus)" : code)) — the Mac's voice is standing in."
            } else if streamStatus != 0 {
                lastVoiceError = "\(streamProvider) refused (HTTP \(streamStatus)) — the Mac's voice is standing in."
            }
            Config.shared.log("Agent voice: \(streamProvider) failed (HTTP \(streamStatus)\(why)) — using the Mac voice")
            speakApple(streamFallback)
            return
        }
        if streamJSONL {
            ingestInworld(final: true)
        } else if streamLeftover.count >= 2 {
            scheduleStream(streamLeftover.prefix(streamLeftover.count / 2 * 2))
        }
        streamLeftover = Data()
        lastVoiceError = nil
        Config.shared.log("Agent voice: \(streamProvider) streamed \(Int(Double(streamBytes) / (streamRate * 2))) s of audio")
        sourceDone()
    }

    /// 16-bit mono PCM at one rate to another, whole — for the canned-clip
    /// cache, which stores every take at the player's 22.05 kHz no matter
    /// which provider rendered it.
    static func resamplePCM16(_ data: Data, from: Double, to: Double) -> Data? {
        guard from != to else { return data }
        guard let srcF = AVAudioFormat(standardFormatWithSampleRate: from, channels: 1),
              let dstF = AVAudioFormat(standardFormatWithSampleRate: to, channels: 1),
              let src = pcm16ToBuffer(data, format: srcF),
              let conv = AVAudioConverter(from: srcF, to: dstF),
              let out = AVAudioPCMBuffer(pcmFormat: dstF,
                                         frameCapacity: AVAudioFrameCount(Double(src.frameLength) * to / from) + 16)
        else { return nil }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, st in
            if fed { st.pointee = .noDataNow; return nil }
            fed = true; st.pointee = .haveData; return src
        }
        guard err == nil, out.frameLength > 0, let ch = out.floatChannelData else { return nil }
        var pcm = Data(capacity: Int(out.frameLength) * 2)
        for i in 0..<Int(out.frameLength) {
            var v = Int16(max(-1, min(1, ch[0][i])) * 32767).littleEndian
            withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
        }
        return pcm
    }

    private static func pcm16ToBuffer(_ data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let n = data.count / 2
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { return nil }
        buf.frameLength = AVAudioFrameCount(n)
        let out = buf.floatChannelData![0]
        data.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in 0..<n { out[i] = Float(Int16(littleEndian: s[i])) / 32768 }
        }
        return buf
    }

    // MARK: The Mac's voice

    private func speakApple(_ text: String) {
        let utt = AVSpeechUtterance(string: text)
        utt.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        if let v = Self.appleVoice() { utt.voice = v }
        var converter: AVAudioConverter?
        synth.write(utt) { [weak self] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            DispatchQueue.main.async {
                guard let self = self, self.speaking, !self.interrupted else { return }
                if pcm.frameLength == 0 { self.sourceDone(); return }
                if pcm.format == self.voiceFormat { return self.schedule(pcm) }
                // A voice that renders at another rate: convert to the wiring.
                if converter == nil { converter = AVAudioConverter(from: pcm.format, to: self.voiceFormat) }
                guard let conv = converter else { return }
                let ratio = self.voiceFormat.sampleRate / pcm.format.sampleRate
                guard let out = AVAudioPCMBuffer(pcmFormat: self.voiceFormat,
                                                 frameCapacity: AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 16) else { return }
                var fed = false
                var err: NSError?
                conv.convert(to: out, error: &err) { _, st in
                    if fed { st.pointee = .noDataNow; return nil }
                    fed = true; st.pointee = .haveData; return pcm
                }
                if err == nil, out.frameLength > 0 { self.schedule(out) }
            }
        }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // Only the engine-less path speaks through the synthesiser directly;
        // a line with more to come, or more queued in it, isn't over yet.
        if speaking && engine == nil && !awaitingMore && !s.isSpeaking { finishSpeaking() }
    }

    /// The stand-in keeps the persona: the agent is a young man, so the
    /// best male voice installed speaks — quality first, and Samantha only
    /// when there is no male voice at all. Before this, the fallback
    /// picked pure quality and the agent changed gender whenever the
    /// ElevenLabs key faltered.
    private static func appleVoice() -> AVSpeechSynthesisVoice? {
        let lang = AVSpeechSynthesisVoice.currentLanguageCode()
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == lang }
        let males = voices.filter { $0.gender == .male }
        return (males.isEmpty ? voices : males).max { a, b in a.quality.rawValue < b.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    // MARK: Listening

    /// Open the ear. `onSpeech` fires (main queue) the moment talking starts
    /// — the bridge uses it to cut the voice off. `completion` gets the
    /// 16 kHz mono samples of what was said, or nil when nobody spoke before
    /// `startWithin` ran out (or the ear was closed). False if there is no
    /// microphone to open.
    @discardableResult
    func listen(startWithin: TimeInterval, silenceAfter: TimeInterval, maxSeconds: TimeInterval,
                onSpeech: @escaping () -> Void,
                completion: @escaping ([Float]?) -> Void) -> Bool {
        guard ensureEngine(), converter != nil else { return false }
        listenDone = completion
        queue.async {
            self.samples = []
            self.capturing = true
            self.loudRun = 0
            self.silenceAfter = silenceAfter
            self.maxSeconds = maxSeconds
            self.onSpeech = onSpeech
            self.phase = .waiting(Date().addingTimeInterval(startWithin))
            self.candidates = 0
            if self.earVAD == nil { self.earVAD = EarVAD() }
            self.earVAD?.reset()
            self.lastStrongVoice = .distantPast
            self.lastAnyVoice = .distantPast
            self.lastProb = 0
            self.triggerArmedAt = Date().addingTimeInterval(0.8)
        }
        Config.shared.log("Agent voice: ear open for \(Int(startWithin)) s")
        return true
    }

    /// Is the ear open right now (waiting or mid-utterance)?
    var listening: Bool {
        queue.sync { if case .off = phase { return false } else { return true } }
    }

    /// While the ear is still waiting for the first word, move the moment it
    /// gives up — the voice has just finished, give the reply some quiet.
    func waitUntil(_ deadline: Date) {
        queue.async {
            if case .waiting = self.phase { self.phase = .waiting(deadline) }
        }
    }

    /// Close the ear without a result.
    func stopListening() {
        queue.sync { phase = .off; capturing = false; samples = []; onSpeech = nil }
        let d = listenDone; listenDone = nil
        if !speaking { teardownEngine() }
        d?(nil)
    }

    /// Close the ear and swallow its verdict — the reply was accepted on
    /// other evidence (the live transcript), so the completion must not
    /// fire and discard the take it was timing.
    func abandonListening() {
        queue.sync { phase = .off; capturing = false; samples = []; onSpeech = nil }
        listenDone = nil
        if !speaking { teardownEngine() }
    }

    private func ingest(_ buf: AVAudioPCMBuffer) {
        guard var converter = converter else { return }
        // A buffer whose rate no longer matches what the converter was built
        // for means the device changed under a live tap: convert it as it
        // claims to be, or every sample downstream is time-stretched — loud
        // enough to trip the level gate, wrong enough that the VAD (rightly)
        // refuses to call it a voice.
        if buf.format.sampleRate != converter.inputFormat.sampleRate
            || buf.format.channelCount != converter.inputFormat.channelCount {
            guard let fresh = AVAudioConverter(from: buf.format, to: target) else { return }
            Config.shared.log("Agent voice: mic format moved \(Int(converter.inputFormat.sampleRate)) → "
                + "\(Int(buf.format.sampleRate)) Hz mid-tap; converter rebuilt")
            self.converter = fresh
            converter = fresh
        }
        let ratio = target.sampleRate / buf.format.sampleRate
        let cap = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buf
        }
        guard err == nil, let ch = out.floatChannelData, out.frameLength > 0 else { return }
        let n = Int(out.frameLength)
        var chunk = Array(UnsafeBufferPointer(start: ch[0], count: n))
        // Rumble off first — the level gate, the VAD and the transcription all
        // work from this filtered feed, so the floor they see is the room's
        // voice band, not the desk.
        hpf.run(&chunk)
        var sum: Float = 0
        for s in chunk { sum += s * s }
        let rms = (sum / Float(max(n, 1))).squareRoot()
        queue.async { self.step(chunk, rms: rms) }
    }

    /// The endpointer. Loudness is only the cheap first look; the streaming
    /// Silero, fed every frame with its state carried, says whether it is a
    /// voice. While the line plays, `echo` follows how loud it comes back
    /// through the mic and only sound well above that is even looked at; the
    /// first half-second of a line is never counted. About 130 ms of loud
    /// frames with the VAD lately over 0.5 opens the utterance; the VAD
    /// under 0.35 for `silenceAfter` closes it.
    private var candidates = 0
    private var peak: Float = 0
    private func step(_ chunk: [Float], rms: Float) {
        guard capturing else { return }
        let now = Date()
        if let p = earVAD?.feed(chunk) {
            lastProb = p
            if now > triggerArmedAt {
                if p >= 0.5 { lastStrongVoice = now }
                if p >= 0.35 { lastAnyVoice = now }
            }
        }
        // The floor drops to meet a quiet frame at once and climbs slowly,
        // so speech never becomes the floor.
        if rms < floor { floor = rms } else { floor = min(floor * 1.01 + 0.00002, rms) }
        var threshold = max(base * 0.5, floor * 3)
        if voiceOn {
            echo = max(rms, echo * 0.97)
            threshold = max(threshold * 2, echo * 3)
            if now.timeIntervalSince(voiceOnSince) < 0.6 { threshold = .greatestFiniteMagnitude }
        } else {
            echo *= 0.9
        }
        let loud = rms > threshold
        loudRun = loud ? loudRun + 1 : 0
        switch phase {
        case .off:
            return
        case .waiting(let deadline):
            // Keep everything heard since the ear opened (a listen is 12 s at
            // most, so this stays small). The VAD wants to hear the room and
            // the words in one take — a suffix snipped mid-word scores speech
            // low, and it is also what gets dumped when the ear misjudges.
            samples.append(contentsOf: chunk)
            if samples.count > 240_000 { samples.removeFirst(samples.count - 240_000) }
            peak = max(peak, rms)
            // The VAD opens the take: one loud chunk while the streaming
            // Silero has just scored ≥ 0.5 is a person starting to talk.
            // Six-in-a-row loudness — the old trigger — missed soft speech
            // that dips around the threshold (measured 2026-08-24: a real
            // reply peaking at rms 0.065 never strung six together). With
            // no detector at all, the old streak stands alone.
            let voiceFresh = earVAD == nil ? loudRun >= 6 : now.timeIntervalSince(lastStrongVoice) < 0.4
            if loud && voiceFresh {
                Config.shared.log("Agent voice: ear — voice (rms \(String(format: "%.4f", rms)), floor \(String(format: "%.4f", floor)), vad \(String(format: "%.2f", lastProb)))")
                // The transcription wants the utterance, not the wait: keep
                // one second before this moment and let speech grow from there.
                if samples.count > 16000 { samples.removeFirst(samples.count - 16000) }
                phase = .speech(began: now, lastVoice: now)
                let cb = onSpeech
                DispatchQueue.main.async { cb?() }
            } else if loudRun >= 6 {
                loudRun = 0
                candidates += 1
                if candidates <= 3 { Config.shared.log("Agent voice: ear — loud, not a voice (rms \(String(format: "%.4f", rms)), floor \(String(format: "%.4f", floor)), vad \(String(format: "%.2f", lastProb)))") }
                dumpRejected(samples)
                // A fan, a door: learn it as the room — but never so
                // far that a quiet speaker across the desk (rms ~0.02)
                // falls under the bar.
                floor = max(floor, min(rms * 0.5, 0.008))
            } else if now > deadline {
                Config.shared.log("Agent voice: ear closed — nothing (peak rms \(String(format: "%.4f", peak)), floor \(String(format: "%.4f", floor)), \(candidates) loud moments)")
                peak = 0
                finishListening(nil)
            }
        case .speech(let began, var lastVoice):
            samples.append(contentsOf: chunk)
            // Still talking while the streaming VAD keeps scoring ≥ 0.35 —
            // the lower bar (Silero's own hysteresis) rides out the dips
            // inside a sentence.
            if lastAnyVoice > lastVoice { lastVoice = lastAnyVoice }
            phase = .speech(began: began, lastVoice: lastVoice)
            if now.timeIntervalSince(lastVoice) >= silenceAfter
                || now.timeIntervalSince(began) >= maxSeconds {
                finishListening(samples)
            }
        }
    }

    /// A loud moment the VAD refused, kept as a clip (dev builds, first few
    /// per launch) — the one artefact that says whether the ear's audio was
    /// ever speech-shaped, or arrived stretched, resampled or otherwise not
    /// what the microphone heard. Replay it; TESTING.md "Agent voice" says how.
    private var rejectsDumped = 0
    private func dumpRejected(_ window: [Float]) {
        guard Config.isDev, rejectsDumped < 3 else { return }
        rejectsDumped += 1
        let url = Config.shared.dir.appendingPathComponent("recordings", isDirectory: true)
            .appendingPathComponent("ear-reject-\(Int(Date().timeIntervalSince1970)).wav")
        guard let tape = AudioTape(url: url) else { return }
        var pcm = Data(capacity: window.count * 2)
        for s in window {
            var v = Int16(max(-1, min(1, s)) * 32767).littleEndian
            withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
        }
        tape.write(pcm)
        tape.close()
        Config.shared.log("Agent voice: rejected window kept — \(url.lastPathComponent)")
    }

    private func finishListening(_ result: [Float]?) {
        phase = .off
        capturing = false
        samples = []
        onSpeech = nil
        DispatchQueue.main.async {
            let d = self.listenDone
            self.listenDone = nil
            if !self.speaking { self.teardownEngine() }
            d?(result)
        }
    }
}
