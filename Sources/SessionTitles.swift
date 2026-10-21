// What a Claude session is called — "Voice agent chat UI layout", not a
// hex id — so the chat card's header can read Claude / folder / title the
// way the app's own sidebar does.
//
// Two places keep titles, and hook events carry the id that unlocks both
// (verified on disk 2026-08-24; 265 of 295 transcripts here had one):
//   • The Claude desktop app: one JSON per session under
//     ~/Library/Application Support/Claude/claude-code-sessions/<acct>/<ws>/
//     local_<uuid>.json — a `title` field beside `cliSessionId`, which is
//     exactly the transcript's file name, so an app session and its hook
//     events meet on the same id. Deleted sessions wear a deleted_ prefix.
//   • The CLI: {"type":"custom-title","customTitle":…} lines inside the
//     transcript at ~/.claude/projects/<encoded-cwd>/<session-id>.jsonl.
//     The last one wins; a brand-new session hasn't earned one yet.
import Foundation

enum SessionTitles {

    /// The session's title, or nil when neither store has named it yet.
    /// Cached for a minute — an episode asks several times in a breath,
    /// and a title that changes mid-episode can wait for the next one.
    ///
    /// Codex keeps the same thing in one place rather than two: a line
    /// per thread in ~/.codex/session_index.jsonl (see Codex.title).
    static func title(for sessionID: String, cwd: String, agent: AgentKind = .claude) -> String? {
        guard !sessionID.isEmpty else { return nil }
        if let hit = cache[sessionID], Date().timeIntervalSince(hit.at) < 60 { return hit.title }
        let t = agent == .codex
            ? Codex.title(for: sessionID)
            : appTitle(for: sessionID) ?? transcriptTitle(for: sessionID, cwd: cwd)
        cache[sessionID] = (t, Date())
        return t
    }

    private static var cache: [String: (title: String?, at: Date)] = [:]

    // MARK: The desktop app's store

    private static var appStoreDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    }

    /// Walk <account>/<workspace>/local_*.json for the one whose
    /// cliSessionId is this session. The store holds one small JSON per
    /// live session — a few dozen reads at worst, and only on cache misses.
    private static func appTitle(for sessionID: String) -> String? {
        let fm = FileManager.default
        guard let accounts = try? fm.contentsOfDirectory(at: appStoreDir, includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles]) else { return nil }
        for account in accounts {
            let workspaces = (try? fm.contentsOfDirectory(at: account, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles])) ?? []
            for ws in workspaces {
                let files = (try? fm.contentsOfDirectory(at: ws, includingPropertiesForKeys: nil,
                                                         options: [.skipsHiddenFiles])) ?? []
                for f in files where f.lastPathComponent.hasPrefix("local_") && f.pathExtension == "json" {
                    guard let data = try? Data(contentsOf: f),
                          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                          obj["cliSessionId"] as? String == sessionID,
                          let title = obj["title"] as? String, !title.isEmpty else { continue }
                    return title
                }
            }
        }
        return nil
    }

    // MARK: The transcript's own title lines

    /// "/Users/x/CODE_FILES/App" → "-Users-x-CODE-FILES-App" — the projects
    /// folder flattens every path character that isn't a letter, digit or
    /// hyphen into a hyphen.
    static func encoded(_ cwd: String) -> String {
        String(cwd.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
    }

    /// The last custom-title line in the transcript. The CLI rewrites it as
    /// the session goes, sometimes at the very top of the file, so the tail
    /// is read first and the head is the fallback.
    private static func transcriptTitle(for sessionID: String, cwd: String) -> String? {
        guard !cwd.isEmpty else { return nil }
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(encoded(cwd))/\(sessionID).jsonl").path
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { h.closeFile() }
        let size = h.seekToEndOfFile()
        let want: UInt64 = 262_144
        h.seek(toFileOffset: size > want ? size - want : 0)
        if let t = lastTitle(in: h.readDataToEndOfFile()) { return t }
        guard size > want else { return nil }
        h.seek(toFileOffset: 0)
        return lastTitle(in: h.readData(ofLength: 65_536))
    }

    private static func lastTitle(in data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() {
            guard line.contains("\"type\":\"custom-title\""),
                  let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  obj["type"] as? String == "custom-title",
                  let t = obj["customTitle"] as? String, !t.isEmpty else { continue }
            return t
        }
        return nil
    }
}

/// The recent back-and-forth of a session, read off its transcript — the
/// material a human answer to "what did it change?" is made from: what
/// the developer asked, what the agent said it did. Tool noise, harness
/// turns and subagent chatter are left out.
enum SessionTranscript {

    /// The last few real exchanges, in order, as prose blocks for the
    /// recap model — or nil when the transcript can't be read.
    static func recentStory(sessionID: String, cwd: String) -> String? {
        guard !sessionID.isEmpty, !cwd.isEmpty else { return nil }
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(SessionTitles.encoded(cwd))/\(sessionID).jsonl").path
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
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
                  let type = obj["type"] as? String, type == "user" || type == "assistant",
                  obj["isSidechain"] as? Bool != true,
                  let msg = obj["message"] as? [String: Any] else { continue }
            var s: String?
            if let c = msg["content"] as? String { s = c }
            else if let parts = msg["content"] as? [[String: Any]] {
                if parts.contains(where: { $0["type"] as? String == "tool_result" }) { continue }
                s = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                    .joined(separator: "\n")
            }
            guard var t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty,
                  !t.hasPrefix("<") else { continue }   // "<command-…>", "<system-reminder>" — the harness, not the people
            if let r = t.range(of: "<system-reminder>") {
                t = String(t[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !t.isEmpty else { continue }
            if type == "user" {
                guard users < 2 else { continue }
                users += 1
                entries.append((i, type, String(t.prefix(600))))
            } else {
                guard agents < 4 else { continue }
                agents += 1
                entries.append((i, type, String(t.prefix(1200))))
            }
        }
        guard !entries.isEmpty else { return nil }
        return entries.sorted { $0.idx > $1.idx }
            .map { "\($0.role == "user" ? "The developer said" : "The agent said"):\n\($0.text)" }
            .joined(separator: "\n\n")
    }
}
