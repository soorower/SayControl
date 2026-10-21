// The clips themselves — what you actually said, kept next to the transcript.
//
// Recent used to draw a waveform that was pure decoration: there was no audio
// behind it, so pressing it did nothing. Every dictation now leaves a 16 kHz
// mono WAV in ~/.config/sayctrl/recordings, named after its history entry, so a
// row can play the clip back and run it through the model again.
//
// Two paths write here. An upload dictation is already a WAV on disk — the
// recorder wrote it — and is simply moved in. A live dictation never touches
// the disk, so `AudioTape` catches the same 16-bit frames on their way to the
// socket and writes the file as they stream.
//
// Nothing leaves the Mac: this is the same folder your transcripts live in,
// the switch is in Settings › Privacy, and the oldest clips are dropped once
// the folder passes its ceiling.
import Cocoa
import AVFoundation

// MARK: - Streaming WAV writer

/// Writes 16-bit PCM to a WAV file as it arrives, then patches the two length
/// fields on close — the sizes aren't known until the talking stops.
final class AudioTape {
    private let handle: FileHandle
    private let url: URL
    private var frames = 0
    private let sampleRate: Double
    private let channels: Int
    private var closed = false
    private let queue = DispatchQueue(label: "sayctrl.tape", qos: .utility)

    init?(url: URL, sampleRate: Double = 16000, channels: Int = 1) {
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: Self.header(sampleRate: sampleRate,
                                                                                     channels: channels,
                                                                                     dataBytes: 0)),
              let h = try? FileHandle(forWritingTo: url) else { return nil }
        handle = h
        _ = try? handle.seekToEnd()
    }

    /// Interleaved little-endian 16-bit samples, exactly as they go to the wire.
    func write(_ pcm: Data) {
        queue.async { [weak self] in
            guard let self = self, !self.closed, !pcm.isEmpty else { return }
            try? self.handle.write(contentsOf: pcm)
            self.frames += pcm.count / (2 * self.channels)
        }
    }

    /// Returns the finished file, or nil if nothing was ever spoken into it.
    @discardableResult
    func close() -> URL? {
        var result: URL?
        queue.sync {
            guard !closed else { return }
            closed = true
            let dataBytes = frames * 2 * channels
            if dataBytes > 0 {
                try? handle.seek(toOffset: 0)
                try? handle.write(contentsOf: Self.header(sampleRate: sampleRate, channels: channels,
                                                          dataBytes: dataBytes))
                result = url
            }
            try? handle.close()
            if dataBytes == 0 { try? FileManager.default.removeItem(at: url) }
        }
        return result
    }

    /// The canonical 44-byte RIFF/WAVE header for signed 16-bit PCM.
    private static func header(sampleRate: Double, channels: Int, dataBytes: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let byteRate = UInt32(sampleRate) * UInt32(channels) * 2
        d.append(contentsOf: Array("RIFF".utf8))
        u32(UInt32(36 + dataBytes))
        d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16)                       // PCM chunk size
        u16(1)                        // format: PCM
        u16(UInt16(channels))
        u32(UInt32(sampleRate))
        u32(byteRate)
        u16(UInt16(channels * 2))     // block align
        u16(16)                       // bits per sample
        d.append(contentsOf: Array("data".utf8))
        u32(UInt32(dataBytes))
        return d
    }
}

// MARK: - The folder

final class Recordings {
    static let shared = Recordings()

    /// Ceilings, whichever comes first, the oldest clips going first. A
    /// 16 kHz mono minute is about 1.9 MB, so 1 GB is roughly nine hours of
    /// speech.
    private let maxClips = 1_000
    private let maxBytes: Int64 = 1_000_000_000

    private let io = DispatchQueue(label: "sayctrl.recordings", qos: .utility)

    var folder: URL { Config.shared.dataDir.appendingPathComponent("recordings", isDirectory: true) }

    /// Off means nothing is written and playback quietly disappears from Recent.
    /// Keeping no history at all necessarily keeps no audio either.
    var isEnabled: Bool {
        Config.shared.flag("KEEP_AUDIO", default: true)
            && Config.shared.flag("KEEP_HISTORY", default: true)
    }

    private init() {}

    private func ensureFolder() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func url(for name: String?) -> URL? {
        guard let name = name, !name.isEmpty else { return nil }
        let url = folder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Where a live session should tape this dictation, or nil when keeping
    /// audio is switched off. The header must carry the session's real rate:
    /// OpenAI live streams 24 kHz, and a 16 kHz header on those frames plays
    /// the clip a third slow — and reads that slow to anything replaying it.
    func tape(id: String, sampleRate: Double = 16000) -> AudioTape? {
        guard isEnabled else { return nil }
        ensureFolder()
        return AudioTape(url: folder.appendingPathComponent("\(id).wav"), sampleRate: sampleRate)
    }

    /// Moves the recorder's scratch file in. Returns the stored file name.
    @discardableResult
    func keep(_ source: URL, id: String) -> String? {
        guard isEnabled, FileManager.default.fileExists(atPath: source.path) else { return nil }
        ensureFolder()
        let name = "\(id).wav"
        let dest = folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: source, to: dest)
        } catch {
            Config.shared.log("Could not keep the clip: \(error.localizedDescription)")
            return nil
        }
        prune()
        return name
    }

    func delete(_ name: String?) {
        guard let url = url(for: name) else { return }
        if ClipPlayer.shared.playingID == name { ClipPlayer.shared.stop() }
        try? FileManager.default.removeItem(at: url)
    }

    func clear() {
        ClipPlayer.shared.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    /// Every clip on disk, newest first.
    private func clips() -> [(url: URL, date: Date, size: Int64)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder,
                                                                  includingPropertiesForKeys: keys)) ?? []
        return files.filter { $0.pathExtension == "wav" }.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return (url, values?.contentModificationDate ?? .distantPast, Int64(values?.fileSize ?? 0))
        }.sorted { $0.date > $1.date }
    }

    /// Count and total size, for the line in Settings › Privacy.
    func summary(_ done: @escaping (Int, Int64) -> Void) {
        io.async { [weak self] in
            guard let self = self else { return }
            let all = self.clips()
            let bytes = all.reduce(Int64(0)) { $0 + $1.size }
            DispatchQueue.main.async { done(all.count, bytes) }
        }
    }

    /// The clip's shape, as `bars` peaks — what a Recent row draws instead of
    /// the deterministic sketch once the audio has been read.
    func envelope(for name: String, bars: Int, done: @escaping ([CGFloat]) -> Void) {
        guard let url = url(for: name) else { return }
        io.async {
            guard let samples = try? LocalEngine.samples(from: url), !samples.isEmpty else { return }
            let per = max(1, samples.count / bars)
            var peaks: [CGFloat] = []
            peaks.reserveCapacity(bars)
            for b in 0..<bars {
                let start = b * per
                guard start < samples.count else { break }
                let end = min(samples.count, start + per)
                var peak: Float = 0
                for i in start..<end { peak = max(peak, abs(samples[i])) }
                peaks.append(CGFloat(peak))
            }
            // Normalise, so a quiet clip still draws as a waveform rather than
            // a flat line — the shape is what carries the meaning here.
            let loudest = peaks.max() ?? 0
            let shaped = loudest > 0.001
                ? peaks.map { max(0.1, min(1, $0 / loudest)) }
                : peaks.map { _ in CGFloat(0.1) }
            guard !shaped.isEmpty else { return }
            DispatchQueue.main.async { done(shaped) }
        }
    }

    /// Drops the oldest clips once the folder passes either ceiling.
    func prune() {
        io.async { [weak self] in
            guard let self = self else { return }
            var all = self.clips()
            var bytes = all.reduce(Int64(0)) { $0 + $1.size }
            while all.count > self.maxClips || bytes > self.maxBytes {
                guard let oldest = all.popLast() else { break }
                bytes -= oldest.size
                try? FileManager.default.removeItem(at: oldest.url)
            }
        }
    }
}

// MARK: - Playback

extension Notification.Name {
    /// A clip started or stopped playing — the Recent rows redraw off this.
    static let sayctrlClipPlayback = Notification.Name("sayctrl.clipPlayback")
}

/// One clip plays at a time; pressing play on another swaps to it.
final class ClipPlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = ClipPlayer()

    private var player: AVAudioPlayer?
    /// The file name of the clip on air, or nil when nothing is playing.
    private(set) var playingID: String?

    private override init() { super.init() }

    var isPlaying: Bool { player?.isPlaying ?? false }

    /// How far through the clip playback has got, 0…1 — the playhead the
    /// Recent waveform burns ember behind.
    var position: CGFloat? {
        guard let p = player, p.isPlaying, p.duration > 0 else { return nil }
        return CGFloat(max(0, min(1, p.currentTime / p.duration)))
    }

    func toggle(name: String) {
        if playingID == name { return stop() }
        guard let url = Recordings.shared.url(for: name) else { return }
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else {
            Config.shared.log("Could not play back \(name)")
            return
        }
        p.delegate = self
        player = p
        playingID = name
        p.play()
        NotificationCenter.default.post(name: .sayctrlClipPlayback, object: nil)
    }

    func stop() {
        guard player != nil else { return }
        player?.stop()
        player = nil
        playingID = nil
        NotificationCenter.default.post(name: .sayctrlClipPlayback, object: nil)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        self.player = nil
        playingID = nil
        NotificationCenter.default.post(name: .sayctrlClipPlayback, object: nil)
    }
}
