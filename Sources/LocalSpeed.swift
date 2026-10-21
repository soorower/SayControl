import Foundation

/// Which local models keep up live on this Mac — measured on it, not read
/// off a chart. A pass that leaves room to spare on an M5 Pro can fall
/// behind on a base M1 with 8 GB, and the chip and memory are only part of
/// the story: what else is running, how hot it is. So each model is timed
/// here, the first time it is loaded, on a ten-second line of speech; and a
/// live take that keeps falling behind demotes its model for this Mac
/// (LocalLive.swift). Until a model has been timed, a cautious guess from
/// the chip stands in.
///
/// The measurements belong to the Mac, so they sit in the config folder
/// with its settings, keyed to the chip and memory they were taken on: a
/// settings folder carried to another Mac starts over.
final class LocalSpeed {
    static let shared = LocalSpeed()

    enum Verdict {
        /// Words appear while you talk.
        case live
        /// Could stream, but not fast enough here: writes when you let go.
        case tooSlow
        /// Never live, on any Mac (Whisper).
        case never
    }

    /// What a pass may cost to count as live. A model re-run over the whole
    /// utterance has to get through ten seconds of speech in a second —
    /// Cohere takes a fifth of that on Apple silicon, Qwen3 most of it — and
    /// a streamed one has to keep under half of real time, leaving the other
    /// half for everything else the Mac is doing.
    static let replayBudget: Double = 1.0
    static let nativeBudget: Double = 0.5

    private struct Record: Codable {
        /// A replayed model's pass over the clip, in seconds; a streamed
        /// one's compute per second of audio.
        var seconds: Double
        var live: Bool
        var measured: Date
        /// Set when a live take fell behind; says how.
        var demoted: String?
    }

    private struct File: Codable {
        var machine: String
        var models: [String: Record]
    }

    private var models: [String: Record] = [:]
    private let machine = LocalEngine.Machine.current.label
    private var url: URL { Config.shared.dir.appendingPathComponent("local-speed.json") }

    private init() {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data),
              file.machine == machine else { return }
        models = file.models
    }

    /// Posted on the main queue whenever a verdict changes, so Settings can
    /// move a model between its lists while it is on screen.
    static let changed = Notification.Name("sayctrl.localSpeedChanged")

    func verdict(_ entry: LocalCatalogEntry) -> Verdict {
        guard entry.family.streams else { return .never }
        if let record = models[entry.id] { return record.live ? .live : .tooSlow }
        return guess(entry) ? .live : .tooSlow
    }

    /// Whether the verdict is a measurement rather than the guess.
    func isMeasured(_ id: String) -> Bool { models[id] != nil }

    /// Before a model has been timed: Parakeet keeps up anywhere; on Apple
    /// silicon with 16 GB or more — every Pro, Max and Ultra — so does
    /// everything that streams; on a base Mac only the light ones, Nemotron
    /// streamed being as light as Parakeet.
    private func guess(_ entry: LocalCatalogEntry) -> Bool {
        let mac = LocalEngine.Machine.current
        switch entry.family {
        case .parakeet: return true
        case .whisper: return false
        case .nemotron: return mac.appleSilicon
        case .cohere, .qwen3, .voxtral: return mac.appleSilicon && mac.memoryGB >= 16
        }
    }

    /// A timing from LocalEngine's benchmark. `native` says which budget it
    /// is held to.
    func record(_ id: String, seconds: Double, native: Bool) {
        let live = seconds <= (native ? Self.nativeBudget : Self.replayBudget)
        models[id] = Record(seconds: seconds, live: live, measured: Date(), demoted: nil)
        save()
        Config.shared.log(String(format: "Local speed: %@ %@ %.2f%@ on %@ — %@", id,
                                 native ? "streams at" : "passes 10 s in", seconds, native ? "× real time" : " s",
                                 machine, live ? "live" : "writes when you let go"))
    }

    /// A live take kept falling behind: this Mac can't run it live after
    /// all, whatever the benchmark said. The take carries on; the next one
    /// writes when you let go.
    func demote(_ id: String, reason: String) {
        guard models[id]?.live ?? true else { return }
        var record = models[id] ?? Record(seconds: 0, live: false, measured: Date())
        record.live = false
        record.demoted = reason
        models[id] = record
        save()
        Config.shared.log("Local speed: \(id) fell behind live on \(machine) (\(reason)) — it writes when you let go from now on")
    }

    private func save() {
        let file = File(machine: machine, models: models)
        if let data = try? JSONEncoder().encode(file) { try? data.write(to: url, options: .atomic) }
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: nil) }
    }

    /// Ten seconds of speech to time a model on: two of the agent voice's
    /// longest lines, which ship inside the app as 24 kHz 16-bit PCM,
    /// run together and brought down to the 16 kHz the models read. nil if
    /// the clips are missing, and the guess stands.
    static func benchmarkClip() -> [Float]? {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("VoiceClips/af_heart") else { return nil }
        let names = ["your-agent-on-say-control-asks-question-1-of-2-w.pcm",
                     "i-fixed-the-login-bug-the-page-loads-in-under-a-.pcm"]
        var pcm24: [Float] = []
        for name in names {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
            data.withUnsafeBytes { raw in
                for v in raw.bindMemory(to: Int16.self) { pcm24.append(Float(Int16(littleEndian: v)) / 32768) }
            }
        }
        let n = min(Int(Double(pcm24.count) * 16000 / 24000), 160_000)
        guard n >= 80_000 else { return nil }
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let x = Double(i) * 24000 / 16000
            let j = Int(x)
            let f = Float(x - Double(j))
            out[i] = pcm24[j] * (1 - f) + (j + 1 < pcm24.count ? pcm24[j + 1] : 0) * f
        }
        return out
    }
}
