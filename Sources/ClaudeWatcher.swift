// The one thing SayCtrl reads out of Claude's transcripts on its own: the
// errors that stop a session dead and wait for a human.
//
// A rate limit is the quietest kind of failure. The agent doesn't finish,
// so no Stop hook fires; it just sits there with a red line in the
// scrollback until somebody looks at the window and types "carry on". The
// transcript records it the moment it happens —
//
//   {"type":"assistant","isApiErrorMessage":true,
//    "message":{"content":[{"type":"text","text":"API Error: 429 …"}]}}
//
// — so the same trick that reads Codex's rollouts reads this: tail the
// files, and speak when one of them says the session is stuck. Only the
// errors a person has to do something about are spoken; a connection
// dropped mid-response is Claude's own business and it retries.
//
// Everything here is bounded by mtime: of the 500-odd transcripts on a
// working Mac, the sweep only opens the handful touched in the last few
// minutes. See CodexWatcher for the same idea on the Codex side.
import Foundation

final class ClaudeWatcher {
    static let shared = ClaudeWatcher()

    /// sid, cwd, and the stall said in a breath ("hit a rate limit and
    /// stopped").
    var onStall: ((_ sessionID: String, _ cwd: String, _ reason: String) -> Void)?

    private(set) var running = false
    private var timer: Timer?
    private var offsets: [String: UInt64] = [:]
    /// When watching began. A transcript created after this belongs to a
    /// session that started under our eyes, so it is read from the top —
    /// a session whose FIRST prompt hits the limit writes the whole file
    /// between two sweeps, and starting at its end would miss it.
    private var since = Date.distantPast

    private var projects: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    /// Start from the end of everything that already exists: yesterday's
    /// rate limit is not news.
    func start() {
        guard !running, FileManager.default.fileExists(atPath: projects.path) else { return }
        running = true
        since = Date()
        for path in recentlyTouched(within: 3600) { offsets[path] = size(path) }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.sweep() }
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        offsets.removeAll()
    }

    /// The transcripts written to lately — the only ones worth opening.
    private func recentlyTouched(within seconds: TimeInterval) -> [String] {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-seconds)
        var out: [String] = []
        let dirs = (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil,
                                                options: [.skipsHiddenFiles])) ?? []
        for dir in dirs {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles])) ?? []
            for f in files where f.pathExtension == "jsonl" {
                let when = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let when = when, when > cutoff { out.append(f.path) }
            }
        }
        return out
    }

    private func size(_ path: String) -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func sweep() {
        guard running else { return }
        for path in recentlyTouched(within: 300) {
            let end = size(path)
            var from = offsets[path] ?? 0
            if offsets[path] == nil {
                // First sight. A file born since we started watching is a
                // new session and is read whole; one that was already here
                // is joined at its end, so a conversation in flight when
                // SayCtrl launched doesn't replay its history.
                let born = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.creationDateKey]))?.creationDate
                from = (born ?? .distantPast) > since ? 0 : end
                offsets[path] = from
            }
            guard end > from, let h = FileHandle(forReadingAtPath: path) else { continue }
            h.seek(toFileOffset: from)
            let data = h.readDataToEndOfFile()
            h.closeFile()
            guard let lastNewline = data.lastIndex(of: 0x0A) else { continue }
            let complete = data[..<lastNewline]
            offsets[path] = from + UInt64(complete.count) + 1
            read(complete, sessionID: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
        }
        // Forget files that have gone quiet, so the table doesn't grow
        // through a long day.
        let live = Set(recentlyTouched(within: 3600))
        offsets = offsets.filter { live.contains($0.key) }
    }

    private func read(_ data: Data, sessionID: String) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            guard line.contains("isApiErrorMessage"),
                  let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  obj["isApiErrorMessage"] as? Bool == true,
                  let msg = obj["message"] as? [String: Any] else { continue }
            var said = ""
            if let c = msg["content"] as? String { said = c }
            else if let parts = msg["content"] as? [[String: Any]] {
                said = parts.compactMap { $0["text"] as? String }.joined(separator: " ")
            }
            guard let reason = Self.stall(in: said) else { continue }
            let cwd = obj["cwd"] as? String ?? ""
            DispatchQueue.main.async { [weak self] in self?.onStall?(sessionID, cwd, reason) }
        }
    }

    /// Which errors are worth a person's attention, and how each is said.
    /// Nil for everything else — a connection closed mid-response is not a
    /// thing the user can do anything about, and Claude picks itself up.
    static func stall(in text: String) -> String? {
        let t = text.lowercased()
        guard t.contains("api error") || t.contains("usage limit") || t.contains("failed to authenticate")
        else { return nil }
        if t.contains("usage limit") {
            // "Claude AI usage limit reached|1787600000" — the epoch after
            // the bar is when it comes back.
            if let bar = text.firstIndex(of: "|"),
               let epoch = TimeInterval(text[text.index(after: bar)...].prefix(while: { $0.isNumber })),
               epoch > Date().timeIntervalSince1970 {
                let f = DateFormatter()
                f.dateFormat = "h:mm a"
                return "hit its usage limit and stopped — it comes back at \(f.string(from: Date(timeIntervalSince1970: epoch)))"
            }
            return "hit its usage limit and stopped"
        }
        if t.contains("429") || t.contains("rate limit") || t.contains("too many requests") {
            return "hit a rate limit and stopped"
        }
        if t.contains("402") || t.contains("credit balance") || t.contains("payment required") {
            return "ran out of credits and stopped"
        }
        if t.contains("401") || t.contains("oauth") || t.contains("authenticate") || t.contains("unauthorized") {
            return "needs you to sign in again"
        }
        return nil
    }
}
