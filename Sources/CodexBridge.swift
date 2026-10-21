// Codex, the second agent the voice speaks for — and the one that needs
// nothing installed to be heard.
//
// Codex writes every session to a rollout file as it works, and that file
// already says what the voice needs to say: a turn finished, what the
// agent's last message was, what was asked. CodexWatcher below tails
// those files, so the whole loop — a session finishes, SayCtrl says so,
// your spoken reply goes back in — costs the user no setup at all.
//
// Talking back needs no window either: `codex queue --thread <id>` puts a
// message into a running session the way Claude's inbox socket does.
//
// An earlier build did this with Codex hooks instead. That worked, but it
// asked the user to install a file and then trust it in a terminal UI the
// desktop app doesn't have — and an untrusted hook fails silently, which
// is the worst way for a feature to be broken. CodexHooks at the bottom
// of this file is now only the tidying-up of those installs.
//
// Verified against codex-cli 0.149.0-alpha.4.1 on 2026-08-24: a real
// session's finish reaches the voice through the rollout alone, and the
// queue reaches the shared app-server daemon.
import Foundation

enum Codex {

    /// ~/.codex, or wherever CODEX_HOME points — the same folder the CLI
    /// and the desktop app both read.
    static var home: URL {
        if let p = ProcessInfo.processInfo.environment["CODEX_HOME"], !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    /// The codex binary. Usually not on PATH: the desktop app ships it
    /// inside its own bundle, and that copy drives the same sessions.
    /// Looked up once — an install that lands mid-session is found at the
    /// next launch, which is soon enough.
    private static var cachedBinary: String??
    static var binary: String? {
        if let hit = cachedBinary { return hit }
        let ownApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path,
                          "/Applications/ChatGPT.app/Contents/Resources/codex",
                          ownApps.appendingPathComponent("ChatGPT.app/Contents/Resources/codex").path,
                          // The plugin app-server keeps a whole copy of the
                          // CLI inside the codex home — the last resort when
                          // the app lives somewhere this list doesn't guess.
                          home.appendingPathComponent("plugins/.plugin-appserver/codex").path]
        let found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        cachedBinary = .some(found)
        return found
    }

    /// Is Codex on this Mac at all? The pane asks, so it can say "not
    /// installed" instead of offering hooks for something that isn't there.
    static var installed: Bool { binary != nil || FileManager.default.fileExists(atPath: home.path) }

    // MARK: Talking back

    /// The next prompt, into a running session — no window brought
    /// forward, nothing typed on screen. The message is queued on the
    /// thread through the shared app-server daemon; a thread the daemon
    /// doesn't know (ended, never started) exits non-zero, and the bridge
    /// falls back to the terminal routes.
    static func queue(thread: String, message: String) -> Bool {
        guard let bin = binary, !thread.isEmpty, !message.isEmpty else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["queue", "--thread", thread, "--message", message]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    // MARK: What a session is called

    /// The thread's name — "RealtyAPI daily blog publisher", not a UUID —
    /// from the index Codex keeps beside its sessions. One JSON per line,
    /// appended as threads are renamed, so the LAST match wins.
    static func title(for sessionID: String) -> String? {
        guard !sessionID.isEmpty,
              let text = try? String(contentsOf: home.appendingPathComponent("session_index.jsonl"),
                                     encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() {
            guard line.contains(sessionID),
                  let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  obj["id"] as? String == sessionID,
                  let name = (obj["thread_name"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty else { continue }
            return name
        }
        return nil
    }

    // MARK: The transcript

    /// A session's rollout file. They are filed by date —
    /// sessions/2026/08/24/rollout-<stamp>-<id>.jsonl — so the last few
    /// days are enough to find a session the voice has heard from today.
    /// Names only, no file is opened to look.
    static func rolloutPath(for sessionID: String) -> String? {
        guard !sessionID.isEmpty else { return nil }
        let fm = FileManager.default
        let sessions = home.appendingPathComponent("sessions")
        let cal = Calendar.current
        for back in 0...3 {
            guard let day = cal.date(byAdding: .day, value: -back, to: Date()) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let dir = sessions
                .appendingPathComponent(String(format: "%04d", c.year ?? 0))
                .appendingPathComponent(String(format: "%02d", c.month ?? 0))
                .appendingPathComponent(String(format: "%02d", c.day ?? 0))
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            if let hit = files.first(where: { $0.lastPathComponent.hasSuffix("-\(sessionID).jsonl") }) {
                return hit.path
            }
        }
        return nil
    }

    /// The last few real exchanges, as prose for the recap model — the
    /// Codex-shaped twin of SessionTranscript.recentStory. A rollout line
    /// is {"type":"response_item","payload":{"type":"message","role":…,
    /// "content":[{"text":…}]}}; the developer role is the harness
    /// talking to the model, and the user turns that open with a tag
    /// (<user_instructions>, <environment_context>) are the harness too.
    static func story(for sessionID: String) -> String? {
        guard let path = rolloutPath(for: sessionID), let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { h.closeFile() }
        let size = h.seekToEndOfFile()
        let want: UInt64 = 400_000
        h.seek(toFileOffset: size > want ? size - want : 0)
        guard let text = String(data: h.readDataToEndOfFile(), encoding: .utf8) else { return nil }

        var entries: [(idx: Int, role: String, text: String)] = []
        var users = 0, agents = 0
        for (i, line) in text.split(separator: "\n").reversed().enumerated() {
            if users >= 2 && agents >= 4 { break }
            guard line.contains("\"message\""),
                  let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  obj["type"] as? String == "response_item",
                  let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "message",
                  let role = payload["role"] as? String, role == "user" || role == "assistant",
                  let parts = payload["content"] as? [[String: Any]] else { continue }
            var t = parts.compactMap { $0["text"] as? String }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !t.hasPrefix("<") else { continue }
            if let r = t.range(of: "<environment_context>") {
                t = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !t.isEmpty else { continue }
            if role == "user" {
                guard users < 2 else { continue }
                users += 1
                entries.append((i, role, String(t.prefix(600))))
            } else {
                guard agents < 4 else { continue }
                agents += 1
                entries.append((i, role, String(t.prefix(1200))))
            }
        }
        guard !entries.isEmpty else { return nil }
        return entries.sorted { $0.idx > $1.idx }
            .map { "\($0.role == "user" ? "The developer said" : "The agent said"):\n\($0.text)" }
            .joined(separator: "\n\n")
    }
}

// MARK: - Watching Codex work, with nothing installed

/// The no-setup way in. Codex writes every session to a rollout file as it
/// goes — `~/.codex/sessions/<y>/<m>/<d>/rollout-<stamp>-<id>.jsonl` — and
/// that file already says everything the voice needs:
///
///   session_meta   the session id, the folder, who started it
///   user_message   what the developer asked
///   task_complete  the turn is over, with `last_agent_message` — the very
///                  thing the Stop hook would have handed us
///
/// So the finish-speak-reply loop needs no hooks, no config, and no
/// trusting anything: SayCtrl tails the files. Hooks stay worth installing
/// for ONE thing the file can't give — a permission request, which has to
/// be answered while the agent waits.
///
/// Only threads a person is actually having are spoken: `thread_source`
/// tells a real session from a scheduled automation running at 3am, and
/// the robots are left to work in peace.
final class CodexWatcher {
    static let shared = CodexWatcher()

    /// sid, cwd, the finished message, what was asked, and whether the
    /// session lives in the desktop app.
    var onTurn: ((_ sessionID: String, _ cwd: String, _ message: String,
                  _ asked: String?, _ inDesktopApp: Bool) -> Void)?
    /// A turn that ended on an error instead of an answer — a rate limit,
    /// spent credits — with the stall said in a breath. The session is
    /// sitting there waiting for a person; this is how they find out
    /// without watching the window.
    var onStall: ((_ sessionID: String, _ cwd: String, _ reason: String,
                   _ inDesktopApp: Bool) -> Void)?

    private(set) var running = false
    private var timer: Timer?
    /// Per rollout: how far we have read, and what its header said.
    private struct Tail {
        var offset: UInt64 = 0
        var sessionID = ""
        var cwd = ""
        var mine = false          // a session worth speaking for
        var desktop = true
        var asked: String?
    }
    private var tails: [String: Tail] = [:]

    /// Start reading from the END of everything that already exists: the
    /// voice announces what happens from now on, never the day's history.
    func start() {
        guard !running, FileManager.default.fileExists(atPath: Codex.home.path) else { return }
        running = true
        for path in rollouts() {
            var t = Tail()
            readHeader(path, into: &t)
            t.offset = size(path)
            tails[path] = t
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.sweep() }
    }

    func stop() {
        running = false
        timer?.invalidate()
        timer = nil
        tails.removeAll()
    }

    /// Today's and yesterday's rollouts — a session older than that has
    /// long since dropped off the recents list anyway.
    private func rollouts() -> [String] {
        let fm = FileManager.default
        let cal = Calendar.current
        var out: [String] = []
        for back in 0...1 {
            guard let day = cal.date(byAdding: .day, value: -back, to: Date()) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let dir = Codex.home.appendingPathComponent("sessions")
                .appendingPathComponent(String(format: "%04d", c.year ?? 0))
                .appendingPathComponent(String(format: "%02d", c.month ?? 0))
                .appendingPathComponent(String(format: "%02d", c.day ?? 0))
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            out += files.filter { $0.pathExtension == "jsonl" && $0.lastPathComponent.hasPrefix("rollout-") }
                .map { $0.path }
        }
        return out
    }

    private func size(_ path: String) -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// The first line names the session. Read alone, so a file that
    /// existed before SayCtrl started is still known by name when it
    /// speaks up.
    private func readHeader(_ path: String, into t: inout Tail) {
        guard let h = FileHandle(forReadingAtPath: path) else { return }
        defer { h.closeFile() }
        guard let text = String(data: h.readData(ofLength: 65_536), encoding: .utf8),
              let first = text.split(separator: "\n").first,
              let obj = (try? JSONSerialization.jsonObject(with: Data(first.utf8))) as? [String: Any],
              obj["type"] as? String == "session_meta",
              let p = obj["payload"] as? [String: Any] else { return }
        t.sessionID = p["session_id"] as? String ?? p["id"] as? String ?? ""
        t.cwd = p["cwd"] as? String ?? ""
        // "user" is a person at the keyboard. "automation" is a scheduled
        // job, "realtime_voice" is Codex's own voice mode — neither wants
        // a second voice talking over it.
        t.mine = (p["thread_source"] as? String ?? "user") == "user" && !t.sessionID.isEmpty
        t.desktop = (p["originator"] as? String ?? "").lowercased().contains("desktop")
    }

    private func sweep() {
        guard running else { return }
        let live = rollouts()
        for path in live {
            var t = tails[path] ?? {
                var fresh = Tail()
                readHeader(path, into: &fresh)
                return fresh
            }()
            if t.sessionID.isEmpty { readHeader(path, into: &t) }   // header may not have been flushed yet
            let end = size(path)
            if end > t.offset, let h = FileHandle(forReadingAtPath: path) {
                h.seek(toFileOffset: t.offset)
                let data = h.readDataToEndOfFile()
                h.closeFile()
                // Stop at the last complete line; a half-written one is
                // read again next time round.
                if let lastNewline = data.lastIndex(of: 0x0A) {
                    let complete = data[..<lastNewline]
                    t.offset += UInt64(complete.count) + 1
                    if t.mine { consume(complete, &t) }
                }
            }
            tails[path] = t
        }
        let alive = Set(live)
        tails = tails.filter { alive.contains($0.key) }
    }

    private func consume(_ data: Data, _ t: inout Tail) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            guard line.contains("event_msg"),
                  let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  obj["type"] as? String == "event_msg",
                  let p = obj["payload"] as? [String: Any] else { continue }
            switch p["type"] as? String {
            case "user_message":
                // What was asked, for the summary to answer against. The
                // desktop app prepends a file manifest when things are
                // attached; the question is the part after it.
                var m = (p["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if let r = m.range(of: "# Files mentioned by the user:") {
                    m = String(m[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                t.asked = m.isEmpty ? nil : String(m.prefix(600))
            case "task_complete":
                let (sid, cwd, asked, desktop) = (t.sessionID, t.cwd, t.asked, t.desktop)
                // A turn ends one of two ways. `error` beside a null
                // message is the one nobody sees: the agent gave up, and
                // the window just sits there.
                if let err = p["error"] as? [String: Any] {
                    let reason = Self.stall(in: err)
                    DispatchQueue.main.async { [weak self] in self?.onStall?(sid, cwd, reason, desktop) }
                    continue
                }
                let msg = (p["last_agent_message"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !msg.isEmpty else { continue }
                DispatchQueue.main.async { [weak self] in
                    self?.onTurn?(sid, cwd, msg, asked, desktop)
                }
            default: break
            }
        }
    }

    /// The error as it should be said. Codex hands over both a sentence
    /// and a machine-readable code — `{"response_too_many_failed_attempts":
    /// {"http_status_code": 429}}` — and the code is what to trust; the
    /// sentence carries request ids nobody wants read aloud.
    static func stall(in error: [String: Any]) -> String {
        let message = (error["message"] as? String ?? "").lowercased()
        var status: Int?
        if let info = error["codex_error_info"] as? [String: Any] {
            for value in info.values {
                if let d = value as? [String: Any], let code = d["http_status_code"] as? Int { status = code }
            }
            if info["usage_limit_exceeded"] != nil { return "hit its usage limit and stopped" }
            if info["session_budget_exceeded"] != nil { return "ran out of its budget and stopped" }
            if info["context_window_exceeded"] != nil { return "ran out of context and stopped" }
        }
        switch status {
        case 429: return "hit a rate limit and stopped"
        case 402: return "ran out of credits and stopped"
        case 401, 403: return "needs you to sign in again"
        default: break
        }
        if message.contains("429") || message.contains("too many requests") || message.contains("rate limit") {
            return "hit a rate limit and stopped"
        }
        if message.contains("402") || message.contains("credit") || message.contains("payment required") {
            return "ran out of credits and stopped"
        }
        if message.contains("401") || message.contains("unauthorized") { return "needs you to sign in again" }
        return "stopped with an error"
    }
}

// MARK: - Cleaning up after an older build

/// SayCtrl used to install hooks into `~/.codex/hooks.json` so it could
/// answer permission requests by voice. It doesn't any more: hooks were
/// the one part of this feature with a setup — a file to install and,
/// because Codex will not run a hook it has not been shown, a trust step
/// in a terminal UI that the desktop app doesn't even have. Reading
/// Codex's own rollout files does the whole job with none of that.
///
/// What remains is the tidying. An install from that build is still
/// sitting in people's config, inert, pointing at a port; this takes ours
/// back out at launch and leaves everyone else's hooks exactly as they
/// are. It runs once and finds nothing thereafter.
enum CodexHooks {

    static var hooksURL: URL { Codex.home.appendingPathComponent("hooks.json") }

    /// Ours, by the marker in the command line no other hook would carry.
    private static func isOurs(_ hook: [String: Any]) -> Bool {
        (hook["command"] as? String)?.contains("/sayctrl/codex/") == true
    }

    static func anyInstalled() -> Bool {
        guard let hooks = read()?["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            (value as? [[String: Any]] ?? []).contains { g in
                ((g["hooks"] as? [[String: Any]]) ?? []).contains(where: isOurs)
            }
        }
    }

    /// Take ours out. Returns true if there was anything to take out, so
    /// the caller can say so in the log rather than every launch.
    @discardableResult
    static func cleanUp() -> Bool {
        guard anyInstalled(), var root = read() else { return false }
        let hooks = stripped(root["hooks"] as? [String: Any] ?? [:])
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        do {
            // A file we emptied out is tidier gone — but only if OUR hooks
            // were the whole of it. Anything else in there (a description,
            // someone's own key) is theirs, and the file stays.
            if root.isEmpty {
                try FileManager.default.removeItem(at: hooksURL)
            } else {
                try write(root)
            }
            return true
        } catch {
            return false
        }
    }

    private static func read() -> [String: Any]? {
        guard let data = try? Data(contentsOf: hooksURL), !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func write(_ root: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: hooksURL, options: .atomic)
    }

    private static func stripped(_ hooks: [String: Any]) -> [String: Any] {
        var out = hooks
        for (event, value) in hooks {
            guard var groups = value as? [[String: Any]] else { continue }
            groups = groups.compactMap { g in
                var g = g
                let all = (g["hooks"] as? [[String: Any]]) ?? []
                let kept = all.filter { !isOurs($0) }
                if kept.isEmpty && !all.isEmpty { return nil }
                g["hooks"] = kept
                return g
            }
            if groups.isEmpty { out.removeValue(forKey: event) } else { out[event] = groups }
        }
        return out
    }
}
