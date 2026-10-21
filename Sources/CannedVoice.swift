// The short lines the agent voice says on every episode — "Sent.",
// "Okay.", "Allowed." — used to cost an ElevenLabs round-trip apiece,
// every time, for one word whose rendering never needed to be fresh.
// Now each phrase is rendered a few times, kept on disk as the same
// 22.05 kHz PCM the stream delivers, and played from there ever after:
// no latency, no credits, and three takes in rotation so the voice
// doesn't stamp the identical "Sent." twice in a row.
//
// The first time a phrase is spoken it still streams (nothing waits on
// the cache), and the takes render in the background for every episode
// after. The file name carries the voice, model and speed, so changing
// any of them in .env simply grows fresh takes and strands the old.
import Foundation

final class CannedClips {
    static let shared = CannedClips()

    /// Exactly the strings the bridge speaks verbatim — a phrase reworded
    /// in AgentBridge must be added here to earn its cache.
    static let phrases: Set<String> = [
        "Sent.", "Okay.", "Goodbye.", "Allowed.", "Denied.",
        "Anything else?", "Go ahead.", "Okay, cancelled.", "Dropped.",
    ]
    static let takes = 3

    /// A canned phrase, or an update's opening — "Your agent on Say Control
    /// finished." — which is said for the same few projects again and again,
    /// and so plays from disk from the second time on instead of waiting on
    /// the voice.
    static func isCanned(_ text: String) -> Bool {
        if phrases.contains(text) { return true }
        return text.hasSuffix(" finished.") && text.count <= 90
            && text.dropLast().allSatisfy { !".!?".contains($0) }
    }

    /// The fixed lines that ship inside the app (Resources/VoiceClips, made
    /// by scripts/make_voice_clips.py on the cloud's own voice box): every
    /// line the bridge says word for word, in each voice the Agents pane
    /// offers, at the cloud's own pace — so "Okay." plays at once, and in
    /// the voice picked, from the very first time. voice → line → file.
    private static let shipped: [String: [String: String]] = {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("VoiceClips/manifest.json"),
              let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              json["model"] as? String == VoiceIO.relayModel,
              let voices = json["voices"] as? [String: [String: String]] else { return [:] }
        return voices
    }()

    /// This line, as it ships in the app for this voice, when the cloud is
    /// the one speaking. At the cloud's own pace even when a developers'
    /// AGENT_VOICE_SPEED asks for another: a word or two a shade off the
    /// rest beats a different voice, and users have no speed to set.
    private func shippedClip(for text: String, voice: String, model: String, speed: String?) -> Data? {
        guard model == VoiceIO.relayModel, let file = Self.shipped[voice]?[text],
              let url = Bundle.main.resourceURL?.appendingPathComponent("VoiceClips/\(file)") else { return nil }
        return try? Data(contentsOf: url)
    }

    private var generating: Set<String> = []
    private var dir: URL { Config.shared.dir.appendingPathComponent("voice-clips", isDirectory: true) }

    /// A random cached take of this phrase, or nil — not a canned phrase,
    /// or not rendered yet.
    func clip(for text: String, voice: String, model: String, speed: String?) -> Data? {
        if let shipped = shippedClip(for: text, voice: voice, model: model, speed: speed) { return shipped }
        guard Self.isCanned(text) else { return nil }
        let stem = Self.stem(text, voice: voice, model: model, speed: speed)
        let files = (1...Self.takes).compactMap { n -> Data? in
            try? Data(contentsOf: dir.appendingPathComponent("\(stem)-\(n).pcm"))
        }.filter { $0.count > 4410 * 2 }   // anything under 0.2 s is a failed render, not a word
        return files.randomElement()
    }

    /// Render whatever takes this phrase is missing, quietly, off the
    /// speaking path. Safe to call on every miss — one flight per phrase.
    func fill(for text: String, key: String, voice: String, model: String, speed: String?) {
        guard Self.isCanned(text), !generating.contains(text) else { return }
        let stem = Self.stem(text, voice: voice, model: model, speed: speed)
        let missing = (1...Self.takes).filter {
            !FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(stem)-\($0).pcm").path)
        }
        guard !missing.isEmpty else { return }
        generating.insert(text)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        render(text, takes: missing, stem: stem, key: key, voice: voice, model: model, speed: speed)
    }

    /// The same, spoken by SayControl's cloud in the conversation that first
    /// said the phrase — a few characters off it, once per take, ever.
    func fill(for text: String, conversation: String, voice: String, speed: String?) {
        guard Self.isCanned(text), !generating.contains(text),
              shippedClip(for: text, voice: voice, model: VoiceIO.relayModel, speed: speed) == nil else { return }
        let stem = Self.stem(text, voice: voice, model: VoiceIO.relayModel, speed: speed)
        let missing = (1...Self.takes).filter {
            !FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(stem)-\($0).pcm").path)
        }
        guard !missing.isEmpty else { return }
        generating.insert(text)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // An opening's takes wait until its update has been said: made now,
        // they would queue on the voice box ahead of the summary they open.
        let wait: TimeInterval = Self.phrases.contains(text) ? 0 : 20
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            self.renderRelay(text, takes: missing, stem: stem, conversation: conversation, voice: voice, speed: speed)
        }
    }

    private func renderRelay(_ text: String, takes: [Int], stem: String,
                             conversation: String, voice: String, speed: String?) {
        guard let n = takes.first else {
            generating.remove(text)
            return
        }
        Cloud.shared.speakRequest(conversation: conversation, text: text, voice: voice,
                                  speed: speed.flatMap(Double.init), stream: false) { [weak self] req in
            guard let self = self else { return }
            guard let req = req else {
                self.generating.remove(text)
                return
            }
            self.keep(req, text: text, take: n, stem: stem, inworld: true, compat: false) {
                self.renderRelay(text, takes: Array(takes.dropFirst()), stem: stem,
                                 conversation: conversation, voice: voice, speed: speed)
            }
        }
    }

    /// One take at a time — a burst of three simultaneous requests for one
    /// word is exactly the traffic this cache exists to end.
    private func render(_ text: String, takes: [Int], stem: String,
                        key: String, voice: String, model: String, speed: String?) {
        guard let n = takes.first else {
            generating.remove(text)
            return
        }
        // Whichever provider the live stream uses renders the takes — the
        // same request each sends (see VoiceIO.streamInworld / streamEleven
        // / streamCompat), so a cached take is indistinguishable from a
        // fresh one. OpenAI delivers 24 kHz; the cache stores the player's
        // 22.05, so those takes are resampled once on the way to disk.
        // Inworld renders at 22.05 already, wrapped in a WAV the reply
        // handler unwraps.
        let inworld = model.hasPrefix("inworld-")
        let compat = inworld ? nil : VoiceIO.compatTTS(model: model)
        var req: URLRequest
        if inworld {
            req = URLRequest(url: URL(string: "https://api.inworld.ai/tts/v1/voice")!)
            req.setValue("Basic \(key)", forHTTPHeaderField: "Authorization")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "text": text, "voice_id": voice, "model_id": model,
                "audio_config": VoiceIO.inworldAudioConfig(speed: speed),
            ])
        } else if let compat = compat {
            req = URLRequest(url: compat.url)
            req.setValue("Bearer \(compat.key)", forHTTPHeaderField: "Authorization")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "model": model, "input": text, "voice": voice,
                "instructions": VoiceIO.openAIInstructions(),
                "response_format": "pcm",
            ])
        } else {
            req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voice)?output_format=pcm_22050")!)
            req.setValue(key, forHTTPHeaderField: "xi-api-key")
            var settings: [String: Any] = model.hasPrefix("eleven_v3")
                ? ["stability": 0.5, "similarity_boost": 0.85, "use_speaker_boost": true]
                : ["stability": 0.3, "similarity_boost": 0.8, "style": 0.65, "use_speaker_boost": true]
            if let raw = speed, let v = Double(raw) { settings["speed"] = min(1.2, max(0.7, v)) }
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "text": text, "model_id": model, "voice_settings": settings,
            ])
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        keep(req, text: text, take: n, stem: stem, inworld: inworld, compat: compat != nil) { [weak self] in
            self?.render(text, takes: Array(takes.dropFirst()), stem: stem,
                         key: key, voice: voice, model: model, speed: speed)
        }
    }

    /// Fetches one take and keeps it; `next` renders the take after it.
    /// A failure stops the run until a later miss asks again.
    private func keep(_ req: URLRequest, text: String, take n: Int, stem: String,
                      inworld: Bool, compat: Bool, next: @escaping () -> Void) {
        var req = req
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                var data = data
                if inworld, let raw = data {
                    let obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
                    data = (obj?["audioContent"] as? String)
                        .flatMap { Data(base64Encoded: $0) }
                        .flatMap { VoiceIO.wavBody($0) }
                } else if compat, let raw = data {
                    data = VoiceIO.resamplePCM16(raw, from: VoiceIO.compatRate(), to: 22050)
                }
                guard status == 200, let data = data, data.count > 4410 * 2 else {
                    Config.shared.log("Agent voice: canned take for “\(text)” failed "
                        + "(HTTP \(status)\(error.map { " — \($0.localizedDescription)" } ?? "")) — will retry another day")
                    self.generating.remove(text)
                    return
                }
                let url = self.dir.appendingPathComponent("\(stem)-\(n).pcm")
                try? data.write(to: url, options: .atomic)
                Config.shared.log("Agent voice: canned take \(n)/\(Self.takes) of “\(text)” kept (\(data.count / 44100) s)")
                next()
            }
        }.resume()
    }

    /// "sent" plus a short hash of voice|model|speed|text — readable in the
    /// folder, unique across configurations.
    private static func stem(_ text: String, voice: String, model: String, speed: String?) -> String {
        let word = String(text.lowercased().filter { $0.isLetter }.prefix(12))
        var h: UInt64 = 5381
        for b in "\(voice)|\(model)|\(speed ?? "")|\(text)".utf8 { h = h &* 33 &+ UInt64(b) }
        return "\(word)-\(String(h, radix: 16))"
    }
}
