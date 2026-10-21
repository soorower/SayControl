// Live dictation with no socket in it.
//
// The cloud providers stream audio up and get text back as they go. A local
// model has nothing to stream to, so this does the equivalent the way
// whisper.cpp's own `stream` example does: keep every sample heard so far and
// re-run the model over the whole utterance a few times a second. The mel is
// recomputed from scratch on each pass — ggml offers no way to extend one —
// which is why the pass is throttled and never allowed to overlap itself.
//
// Cohere, Parakeet and Qwen3 get this; Whisper does not. It decodes a fixed
// 30-second window five times slower than either and rewrites its own output
// between passes, so the preview visibly churns. Voxtral and Nemotron stream
// by design and are fed instead: every 0.2 s, just the audio that arrived
// since, into their own streaming modes. Which families qualify, and the
// measurements behind it, live on `LocalFamily.streams`; which keep up on
// this Mac, on LocalSpeed — and a take that falls behind tells it so.
import AVFoundation
import Cocoa

/// What `startLiveRecording` drives. Two implementations: `LiveTranscriber`
/// streams to a provider's socket, `LocalLiveTranscriber` re-runs the
/// on-device model. Same three callbacks, same lifecycle, so the call site
/// doesn't care which one it holds.
protocol LiveSession: AnyObject {
    var onText: ((String) -> Void)? { get set }
    var onLevel: ((CGFloat) -> Void)? { get set }
    var onFinish: ((Result<String, Error>) -> Void)? { get set }
    /// Where to keep the audio. Live never writes a file of its own, so the
    /// frames are copied off here on their way past — see Recordings.swift.
    var tape: AudioTape? { get set }
    /// The rate the frames stream (and tape) at. The tape's header must say
    /// the same, or the clip replays at the wrong speed.
    var sampleRate: Double { get }
    func start() throws
    func finish(grace: TimeInterval?)
    func cancel()
}

extension LiveSession {
    /// The grace period is a socket concern — how long to wait for a provider's
    /// last packet. Call sites that don't care say nothing.
    func finish() { finish(grace: nil) }
}

final class LocalLiveTranscriber: LiveSession {
    var onText: ((String) -> Void)?
    var onLevel: ((CGFloat) -> Void)?
    var onFinish: ((Result<String, Error>) -> Void)?
    var tape: AudioTape?
    /// Local models always take 16 kHz mono; the tap converts to it below.
    let sampleRate: Double = 16000

    /// Slow enough that a pass finishes before the next one is due even on a
    /// long utterance, quick enough to read as live. A fed stream only does
    /// the new audio each time, so it can go three times as often.
    private var interval: TimeInterval { native ? 0.2 : 0.6 }
    /// Voxtral or Nemotron: fed the new audio each tick, not re-run.
    private var native = false
    /// Of `samples`, how many the stream has been fed (audioQueue's).
    private var fed = 0
    /// The stream opening; every feed waits on it.
    private var opening: Task<Void, Error>?
    /// The model this take runs on, and how it has kept pace: a take that
    /// keeps falling behind tells LocalSpeed, and the next one on this Mac
    /// writes when you let go.
    private var modelID = ""
    private var slowPasses = 0
    private var spent: TimeInterval = 0
    private var fedSeconds: Double = 0
    private var feeds = 0
    private var demoted = false
    /// Below this there isn't a word yet, and a pass on near-silence mostly
    /// produces hallucinated filler.
    private let minSeconds: Double = 0.4

    private let engine = AVAudioEngine()
    /// Owns `samples`: the tap runs on an audio thread and must not block.
    private let audioQueue = DispatchQueue(label: "sayctrl.locallive.audio")
    private var samples: [Float] = []
    /// What the tap actually delivered — audioQueue-owned like `samples`,
    /// and snapshotted with them — for the one log line at the end of a take
    /// that says whether an empty result was a deaf ear or a mute model.
    private var heard = Heard()
    private var tapped = false
    private var configChange: NSObjectProtocol?
    private var loggedPassError = false
    private var timer: Timer?
    /// A pass is in flight; the next tick skips rather than piling up.
    private var passRunning = false
    private var finished = false
    private var latest = ""

    // MARK: Lifecycle

    func start() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw err("No microphone input available")
        }
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: 16000, channels: 1,
                                            interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw err("Can't resample the mic to 16 kHz")
        }
        // One converter for the whole session — it carries the resampler state,
        // so a fresh one per buffer would click at every boundary.
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { [weak self] buffer, _ in
            self?.handle(buffer, converter: converter, outFormat: outFormat)
        }
        tapped = true
        engine.prepare()
        try engine.start()
        // The device reconfiguring under a running engine — a new default
        // mic, a rate change — stops it without a word; the log gets one.
        configChange = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self = self, !self.finished else { return }
            Config.shared.log("Local ear: audio configuration changed mid-take — the engine stopped")
        }

        if let entry = LocalEngine.shared.selectedEntry() {
            modelID = entry.id
            native = entry.family.streamsNatively
        }
        if native { opening = Task { try await LocalEngine.shared.streamStart() } }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func finish(grace: TimeInterval? = nil) {
        guard !finished else { return }
        stopAudio()
        if native { return feed(final: true) }
        // A pass still running would hold the final one up for as long as it
        // has left — on a long Qwen3 take, a second or two. Its text is about
        // to be replaced anyway.
        if passRunning { LocalEngine.shared.abortLivePass() }
        // One last pass over everything, so the tail of the sentence is in the
        // text even if it arrived after the final tick.
        run(final: true)
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        onFinish = nil
        onText = nil
        onLevel = nil
        stopAudio()
        if native { LocalEngine.shared.streamCancel() }
    }

    private func stopAudio() {
        timer?.invalidate()
        timer = nil
        if let token = configChange {
            NotificationCenter.default.removeObserver(token)
            configChange = nil
        }
        if tapped {
            engine.inputNode.removeTap(onBus: 0)
            tapped = false
        }
        if engine.isRunning { engine.stop() }
    }

    // MARK: Audio

    private func handle(_ buffer: AVAudioPCMBuffer,
                        converter: AVAudioConverter,
                        outFormat: AVAudioFormat) {
        let loudest = report(level: buffer)

        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }

        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if let error = error {
            audioQueue.async {
                self.heard.converterFailures += 1
                if self.heard.converterError.isEmpty { self.heard.converterError = error.localizedDescription }
            }
            return
        }
        guard let channel = out.floatChannelData?[0], out.frameLength > 0 else { return }
        let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
        // The model reads floats; the tape wants the same frames as 16-bit PCM.
        if let tape = tape {
            var pcm = Data(capacity: chunk.count * 2)
            for f in chunk {
                let v = Int16(max(-1, min(1, f)) * 32767)
                withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
            }
            tape.write(pcm)
        }
        audioQueue.async {
            self.samples.append(contentsOf: chunk)
            self.heard.buffers += 1
            self.heard.peak = max(self.heard.peak, loudest)
        }
    }

    /// Same 0…1 the pill animation wants, from peak amplitude — which is
    /// also handed back raw, for the take's log line.
    @discardableResult
    private func report(level buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var peak: Float = 0
        for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[i])) }
        let level = CGFloat(min(1, peak * 3))
        DispatchQueue.main.async { self.onLevel?(level) }
        return peak
    }

    private struct Heard {
        var buffers = 0
        var peak: Float = 0
        var converterFailures = 0
        var converterError = ""

        func summary(of audio: [Float]) -> String {
            let seconds = Double(audio.count) / 16000
            let rms = audio.isEmpty ? 0
                : (audio.reduce(0) { $0 + $1 * $1 } / Float(audio.count)).squareRoot()
            var line = String(format: "heard %.1fs in %d buffers (peak %.2f, rms %.3f)",
                              seconds, buffers, peak, rms)
            if converterFailures > 0 {
                line += " — \(converterFailures) buffers failed to convert (\(converterError))"
            }
            return line
        }
    }

    // MARK: Passes

    private func tick() {
        guard !finished, !passRunning else { return }
        if native { feed(final: false) } else { run(final: false) }
    }

    /// Voxtral and Nemotron: what arrived since the last feed, into the
    /// stream; at key-up, the rest and the stream's own end.
    private func feed(final: Bool) {
        passRunning = true
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            let chunk = Array(self.samples[self.fed...])
            self.fed = self.samples.count
            let all = final ? self.samples : []
            let heard = self.heard
            Task {
                var text: String?
                let started = Date()
                do {
                    try await self.opening?.value
                    if final {
                        Config.shared.log("Local ear: \(heard.summary(of: all)) — \(LocalEngine.shared.vadSummary(all))")
                        text = try await LocalEngine.shared.streamFinish(chunk, all: all)
                    } else {
                        text = try await LocalEngine.shared.streamFeed(chunk)
                    }
                } catch {
                    if final { return await MainActor.run { self.fail(error) } }
                    await MainActor.run { self.notePassError(error) }
                }
                let took = Date().timeIntervalSince(started)
                let heardSoFar = text
                await MainActor.run {
                    self.passRunning = false
                    if !final { self.notePace(fed: Double(chunk.count) / 16000, took: took) }
                    if let text = heardSoFar { self.latest = text }
                    if final { self.complete() }
                    else if let text = heardSoFar, !text.isEmpty { self.onText?(text) }
                }
            }
        }
    }

    /// Whether this Mac is keeping up. A fed stream is behind when two
    /// feeds in a row carry more than two seconds that piled up while the
    /// last one ran, or when, past six seconds in, it has spent nine tenths
    /// of real time; a replayed one when three passes in a row took more
    /// than 0.15 s per second of speech (on an M5 Pro Cohere takes about a
    /// tenth of that, Qwen3 half). Either way the take goes on as it is.
    private func notePace(fed seconds: Double, took: TimeInterval, heard: Double = 0) {
        guard !demoted, !modelID.isEmpty else { return }
        var reason: String?
        if native {
            // The first feed carries the stream's opening; it says nothing
            // about the pace.
            feeds += 1
            guard feeds > 1 else { return }
            spent += took
            fedSeconds += seconds
            slowPasses = seconds > 2 ? slowPasses + 1 : 0
            if slowPasses >= 2 {
                reason = String(format: "%.1f s of audio waiting on the stream", seconds)
            } else if fedSeconds > 6, spent / fedSeconds > 0.9 {
                reason = String(format: "%.2f× real time", spent / fedSeconds)
            }
        } else if heard >= 4 {
            slowPasses = took / heard > 0.15 ? slowPasses + 1 : 0
            if slowPasses >= 3 { reason = String(format: "a pass over %.0f s took %.1f s", heard, took) }
        }
        guard let reason = reason else { return }
        demoted = true
        LocalSpeed.shared.demote(modelID, reason: reason)
    }

    private func run(final: Bool) {
        passRunning = true
        audioQueue.async { [weak self] in
            guard let self = self else { return }
            let audio = self.samples
            let heard = self.heard
            DispatchQueue.main.async {
                guard !self.finished || final else { return }
                // The last pass's text, for the model to check rather than rewrite.
                let draft = self.latest
                // Too short to be a word yet — but a final pass still has to
                // complete the session, even with nothing in it.
                guard Double(audio.count) / 16000 >= self.minSeconds else {
                    self.passRunning = false
                    if final {
                        // Less than a word after a whole hold is a deaf tap,
                        // not a quiet speaker.
                        Config.shared.log("Local ear: \(heard.summary(of: audio)) — nothing to decode")
                        self.complete()
                    }
                    return
                }
                Task {
                    // The final pass explains itself: what the tap delivered
                    // and what the VAD made of it, next to the transcript
                    // main.swift logs. An empty take is then a deaf ear, a
                    // rejected clip, or a model that heard nothing — not a
                    // mystery.
                    if final {
                        Config.shared.log("Local ear: \(heard.summary(of: audio)) — \(LocalEngine.shared.vadSummary(audio))")
                    }
                    var text: String? = nil
                    let started = Date()
                    do { text = try await LocalEngine.shared.transcribe(samples: audio, draft: draft) }
                    catch {
                        if final { return await MainActor.run { self.fail(error) } }
                        await MainActor.run { self.notePassError(error) }
                    }
                    let took = Date().timeIntervalSince(started)
                    await MainActor.run {
                        self.passRunning = false
                        if !final { self.notePace(fed: 0, took: took, heard: Double(audio.count) / 16000) }
                        if let text = text, !text.isEmpty { self.latest = text }
                        if final { self.complete() }
                        else if let text = text, !text.isEmpty { self.onText?(text) }
                    }
                }
            }
        }
    }

    /// A pass failing mid-take is swallowed — the next one usually lands —
    /// but the first says so, or a take that stays blank has no explanation.
    private func notePassError(_ error: Error) {
        guard !loggedPassError else { return }
        loggedPassError = true
        Config.shared.log("Local ear: a pass failed mid-take (\(error.localizedDescription))")
    }

    private func complete() {
        guard !finished else { return }
        finished = true
        let result = latest
        let done = onFinish
        onFinish = nil
        onText = nil
        onLevel = nil
        done?(.success(result))
    }

    private func fail(_ error: Error) {
        guard !finished else { return }
        finished = true
        let done = onFinish
        onFinish = nil
        onText = nil
        onLevel = nil
        done?(.failure(error))
    }

    private func err(_ message: String) -> NSError {
        NSError(domain: "SayCtrl", code: 20, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
