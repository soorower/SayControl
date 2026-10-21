import AppKit
import Foundation
import Network

/// Which coding agent a session belongs to. One voice, one card, one
/// queue, one list of sessions: the kind only decides how a session's
/// hooks are installed, how a reply gets back in, and what the thing is
/// called when it is named aloud.
enum AgentKind: String {
    case claude, codex

    /// What it is called on the card and in the log.
    var display: String { self == .claude ? "Claude" : "Codex" }
    /// What it is called aloud — the voice reads "Claude" as a name and
    /// "Codex" as a word, and both survive the recogniser.
    var spoken: String { self == .claude ? "Claude" : "Codex" }
}

/// One thing an agent session told us through its hooks.
extension AgentEvent {
    /// A shell command that can't be taken back (Shell.isRisky, on the whole
    /// line and on each part of a chain): denied by voice if the user likes,
    /// approved only on the screen.
    var risky: Bool {
        guard kind == .permission, let tool = toolName,
              ["Bash", "shell", "local_shell", "unified_exec", "exec_command"].contains(tool) else { return false }
        let raw = toolInput["command"]
        let command = (raw as? String) ?? (raw as? [String])?.joined(separator: " ") ?? ""
        let parts = command.components(separatedBy: CharacterSet(charactersIn: ";&|\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return Shell.isRisky(command) || parts.contains(where: Shell.isRisky)
    }
}

struct AgentEvent {
    enum Kind { case finished, needsInput, permission, question }
    struct Question {
        let text: String
        let header: String
        let options: [String]
        let multiSelect: Bool
    }
    let kind: Kind
    let sessionID: String
    let cwd: String
    /// What was said — the agent's last message, the notification line, or
    /// the tool request spelled out for the ear.
    let message: String
    /// The prompt the agent was answering (Stop only, read off the transcript).
    let asked: String?
    let toolName: String?
    /// The tool's input as it came, echoed back when a question is answered.
    let toolInput: [String: Any]
    let questions: [Question]
    /// Where the session lives, from the environment the hook forwarded.
    let termProgram: String?
    let itermSession: String?
    let tmuxPane: String?
    /// The session's inbox socket and its token (CLAUDE_CODE_MESSAGING_*),
    /// forwarded by the hook: a message written there reaches the session
    /// with nothing on screen moving.
    let socket: String?
    let token: String?
    /// Claude unless the hook came in on the codex route. Defaulted, so
    /// every place that builds a Claude event reads as it always did.
    var agent: AgentKind = .claude
    let received = Date()

    /// "my-app" → "my app", the way it is said.
    var project: String {
        let name = folder
        let spoken = name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return spoken.isEmpty ? agent.spoken : spoken
    }
    /// The folder as written, for the screen.
    var folder: String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? agent.display : name
    }
    var shortID: String { String(sessionID.prefix(8)) }
}

/// The agent voice. Claude Code posts its Stop, Notification and
/// PermissionRequest hooks to a loopback HTTP port this class listens on;
/// the bridge says what happened, keeps an ear open for the reply, and
/// carries the reply back — a permission answer or a multiple-choice
/// answer through the hook's own response, a next prompt typed into the
/// session. See VoiceIO for the mouth and ear, AgentPanel for the words on
/// screen, Refiner.summarize / .relay for the words themselves, AgentHooks
/// for the settings.json side.
final class AgentBridge {
    static let shared = AgentBridge()

    private var listener: NWListener?
    private(set) var port: Int = 0
    private(set) var running = false

    /// Work in the order it arrived; one episode at a time so two sessions
    /// finishing together don't talk over each other.
    private struct Pending {
        let event: AgentEvent
        /// The hook is still waiting on this (permission and question).
        var respond: ((String) -> Void)?
        /// What the voice said to open the episode (for "say that again").
        var spoken = ""
        /// The reply so far, across "anything else?" rounds.
        var reply: [String] = []
        /// Screenshots taken for this reply ("take a screenshot" spoken
        /// mid-answer), saved as files; deliver() names them in the message.
        var shotPaths: [String] = []
        var rounds = 0
        /// Multiple-choice answers so far, and which question is up.
        var answers: [String: String] = [:]
        var qIndex = 0
        /// The bridge's own capture came back empty once — one more listen.
        var earRetries = 0
        /// What the ear is waiting for. The last three walk a new session
        /// into being: which folder, what to build, and the final go;
        /// checkStuck is the watchdog's "want me to check on it?".
        var stage: Stage = .answer
        enum Stage { case answer, more, pick, projectPick, brief, confirmLaunch, checkStuck }
        /// The folder a new session will start in (projectPick onward).
        var projectDir: URL?
        /// Where the user asked the session to open; nil follows their habit.
        var launchHost: LaunchHost?
    }
    /// Where a voice-created session opens: a terminal window running the
    /// CLI, or the Claude desktop app via its code/new deep link.
    enum LaunchHost { case terminal, desktopApp }
    private var queue: [Pending] = []
    private var current: Pending?
    /// Sessions whose permission prompt we already voiced — the
    /// Notification that follows six seconds later says nothing new.
    private var voicedPermission: [String: Date] = [:]
    /// Stalls already announced — see stalled(agent:…).
    private var stallSpoken: [String: Date] = [:]
    /// Finishes already announced, so the watcher and a Stop hook telling
    /// the same story don't speak twice. Keyed by session and message,
    /// kept five minutes.
    private var spokenAlready: [String: Date] = [:]
    /// The ear was shut (open mic off): the key may still answer until then.
    private var hotkeyArmedUntil = Date.distantPast
    /// The key cut in: the ear closing with nothing is not the end.
    private var keyTookOver = false
    /// The bridge started a real dictation for the reply — the same pipeline
    /// the key drives — and its transcript belongs here, not on the screen.
    private var agentCapture = false
    /// Is the dictation running (or about to run) as the agent's reply?
    /// The recording pipeline asks, to route the live preview into the
    /// chat card's forming bubble instead of the speech card.
    var capturingReply: Bool { current != nil && (agentCapture || keyTookOver) }
    private var replyTimer: Timer?
    /// The live transcript of the running reply capture, and when it last
    /// grew. A short answer — "The first one." — can end before the ear's
    /// VAD ever opens a take (measured 2026-08-26: rejected as "loud, not
    /// a voice", then discarded at the deadline with the words sitting in
    /// the preview). The transcript growing is better evidence than the
    /// VAD's: words on screen mean speech, whatever the ear thought. So
    /// once the preview has words and they stop growing for
    /// `settleQuiet` — the ear's own silence gate — the reply is taken.
    private var liveReply = ""
    private var liveReplyGrewAt = Date.distantPast
    private var settleTimer: Timer?
    private let settleQuiet: TimeInterval = 2.0

    private var app: AppDelegate? { NSApp.delegate as? AppDelegate }
    private func log(_ s: String) { Config.shared.log("Agent voice: " + s) }

    // MARK: Quiet hours

    /// "Don't do any monitoring for the next hour": until this moment the
    /// bridge spawns no episodes — arriving hooks are released at once,
    /// the news is remembered for later, and the watchdog holds its
    /// tongue. Questions the USER asks ("any updates?") still answer.
    private var quietUntil = Date.distantPast

    /// "Pause monitoring for 30 minutes", "no agent updates for the next
    /// two hours", "go quiet for an hour" → seconds. A mute verb, an
    /// agent/monitoring anchor AND an explicit duration are all required —
    /// "stop monitoring the file watcher" said TO a session must never
    /// trip this, and it carries no "for N minutes".
    static func quietCommand(_ b: String) -> TimeInterval? {
        guard b.split(separator: " ").count <= 14 else { return nil }
        let anchored = ["monitor", "monitoring", "agent updates", "agent activity", "interrupt",
                        "notification", "go quiet", "stay quiet", "be quiet", "agent voice"]
            .contains { b.contains($0) }
        let muted = ["pause", "stop", "mute", "silence", "hold", "dont", "don't", "do not", "no ", "quiet"]
            .contains { b.contains($0) }
        guard anchored, muted else { return nil }
        let numbers: [String: Double] = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4,
                                         "five": 5, "ten": 10, "fifteen": 15, "twenty": 20, "thirty": 30,
                                         "forty five": 45, "sixty": 60, "ninety": 90, "half an": 0.5, "half a": 0.5]
        guard let re = try? NSRegularExpression(
                  pattern: "(?:for|next)\\s+(?:the\\s+)?(?:next\\s+)?(half an|half a|forty five|[a-z]+|\\d+)\\s+(minutes?|hours?)"),
              let m = re.firstMatch(in: b, range: NSRange(b.startIndex..., in: b)),
              let nr = Range(m.range(at: 1), in: b), let ur = Range(m.range(at: 2), in: b) else { return nil }
        let word = String(b[nr])
        guard let n = Double(word) ?? numbers[word] else { return nil }
        let unit: Double = b[ur].hasPrefix("hour") ? 3600 : 60
        return max(60, min(n * unit, 12 * 3600))
    }

    static func resumeCommand(_ b: String) -> Bool {
        ["resume monitoring", "start monitoring again", "start monitoring", "monitoring back on",
         "unmute the agents", "unmute agents", "you can talk again", "back to monitoring"]
            .contains { b.contains($0) }
    }

    private func startQuiet(_ secs: TimeInterval) {
        quietUntil = Date().addingTimeInterval(secs)
        let mins = Int(secs / 60)
        let spokenTime = mins % 60 == 0 && mins >= 60
            ? "\(mins / 60) hour\(mins == 60 ? "" : "s")" : "\(mins) minutes"
        log("quiet for \(spokenTime)")
        if current != nil { finishQuietly() }
        sayLine("Quiet for \(spokenTime) — say resume monitoring when you want me back.", reason: "quiet hours")
    }

    private func endQuiet() {
        quietUntil = .distantPast
        log("monitoring resumed by voice")
        if current != nil { finishQuietly() }
        sayLine("Back on watch.", reason: "monitoring resumed")
    }

    /// A one-line answer outside any conversation — quiet hours on or off.
    /// Never counted; past the server's few a day it shows without a voice.
    private func sayLine(_ s: String, reason: String) {
        AgentPanel.shared.begin(header: "Agents", saying: "")
        claim(.line) { [weak self] ok in
            guard let self = self else { return }
            guard ok else {
                AgentPanel.shared.say(s)
                return AgentPanel.shared.dismiss(after: 4)
            }
            self.say(s) { [weak self] in self?.finish(reason: reason) }
        }
    }

    // MARK: Broadcast

    /// "Tell all agents to commit and pause" → the message. Anchored on
    /// all/every + agents, so "tell the agent…" keeps meaning one session.
    static func broadcastCommand(_ b: String) -> String? {
        let pattern = "^(?:(?:okay|ok|yeah|yes|hey|so|now|please|um|uh|alright)\\s+){0,3}"
            + "(?:tell|ask)\\s+(?:all|all the|all of the|all my|every|each)\\s+(?:agents?|sessions?)\\s+(?:to\\s+)?(.+)$"
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: b, range: NSRange(b.startIndex..., in: b)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: b) else { return nil }
        let msg = String(b[r]).trimmingCharacters(in: .whitespaces)
        return msg.count >= 3 ? msg : nil
    }

    /// One message, every live session — through their inbox sockets and
    /// tmux panes only. The window-paste fallback is for one session; a
    /// fan of window grabs would wrestle the user for their screen.
    private func broadcast(_ words: String) {
        if current != nil { finishQuietly() }
        // Every session that can be reached without taking the screen:
        // an inbox socket, a tmux pane, or — for Codex — its own queue.
        let targets = liveRecents.filter { $0.agent == .codex || $0.socket != nil || $0.tmuxPane != nil }
        AgentPanel.shared.begin(header: "Broadcast", saying: "")
        guard !targets.isEmpty else {
            return say("No agents I can reach quietly right now.") { [weak self] in
                self?.finish(reason: "broadcast: no reachable agents")
            }
        }
        AgentPanel.shared.note("Sending to \(targets.count)…")
        Refiner.shared.relay(words) { [weak self] r in
            DispatchQueue.main.async {
                guard let self = self else { return }
                let text: String
                if case .success(let s) = r { text = s } else { text = words }
                let me = Account.name.split(separator: " ").first.map(String.init) ?? "The user"
                var reached: [Recent] = []
                for t in targets {
                    var sent = false
                    if t.agent == .codex {
                        sent = Codex.queue(thread: t.sessionID,
                                           message: "\(me) says, by voice through SayControl, to every session: \(text)")
                    }
                    if !sent, let sock = t.socket, FileManager.default.fileExists(atPath: sock),
                       Self.inboxSend(socket: sock, token: t.token,
                                      text: "\(me) says, by voice through SayControl, to every session: \(text)") {
                        sent = true
                    }
                    if !sent, let pane = t.tmuxPane, let tmux = Self.which("tmux") {
                        sent = Self.run(tmux, ["send-keys", "-t", pane, "-l", text])
                            && Self.run(tmux, ["send-keys", "-t", pane, "Enter"])
                    }
                    if sent { reached.append(t); self.workingSince[t.sessionID] = Date() }
                }
                self.log("broadcast to \(reached.count)/\(targets.count): \(Config.words(text))")
                AgentPanel.shared.list(reached.map { "→ \(self.name(of: $0))" })
                let s = reached.count == targets.count
                    ? "Sent to \(reached.count) agent\(reached.count == 1 ? "" : "s")."
                    : "Sent to \(reached.count) of \(targets.count) — the rest didn't answer their sockets."
                self.say(s) { self.finish(reason: "broadcast") }
            }
        }
    }

    // MARK: The stuck-agent watchdog

    /// When a message last went INTO each session with no word back yet.
    /// Set on every delivery (a reply, a brief, a broadcast); cleared the
    /// moment any hook arrives from the session — whatever it says, it is
    /// not silently stuck.
    private var workingSince: [String: Date] = [:]
    /// Nudged already — one nudge, then peace for a good while.
    private var nudged: [String: Date] = [:]
    private var watchdogTimer: Timer?
    private static let stuckAfter: TimeInterval = 20 * 60
    private static let renudgeAfter: TimeInterval = 45 * 60

    private func sweepStuck() {
        guard running, current == nil, Date() >= quietUntil else { return }
        for (sid, since) in workingSince {
            let mins = Int(Date().timeIntervalSince(since) / 60)
            guard Date().timeIntervalSince(since) >= Self.stuckAfter else { continue }
            if let t = nudged[sid], Date().timeIntervalSince(t) < Self.renudgeAfter { continue }
            guard let r = recents.first(where: { $0.sessionID == sid }), !r.ended, Self.seemsAlive(r) else {
                workingSince.removeValue(forKey: sid)
                continue
            }
            nudged[sid] = Date()
            log("watchdog: [\(sid.prefix(8))] quiet for \(mins) min — nudging")
            var p = Pending(event: Self.event(for: r))
            p.stage = .checkStuck
            let who = spokenWho(r)
            let s = "\(who.prefix(1).uppercased() + who.dropFirst()) has been working for \(mins) minutes without a word. Want me to check on it?"
            p.spoken = s
            current = p
            let received = p.event.received
            claim(.conversation) { [weak self] ok in
                guard let self = self, self.current?.event.received == received else { return }
                guard ok else { self.current = nil; return }
                self.beginPanel(for: p.event, saying: s)
                self.listenAndSpeak(s)
            }
            return   // one nudge per sweep
        }
    }

    /// What the app is called on screen and what it is called aloud differ:
    /// "SayControl" is written closed up but said "Say Control", and the old
    /// "SayCtrl" the voice reads "say-cackle".
    private static func spoken(_ s: String) -> String {
        var out = s
        for v in ["SayControl", "SayCtrl", "Sayctrl", "sayctrl", "SayCTRL"] {
            out = out.replacingOccurrences(of: v, with: "Say Control")
        }
        return out
    }

    // MARK: Names

    /// What the user calls each session — "call it the billing fix" — so the
    /// voice can open with a name instead of a folder. Keyed by session id,
    /// kept in agent-names.json next to the rest of the settings.
    private var names: [String: String] = [:]
    private var namesLoaded = false
    private var namesURL: URL { Config.shared.dir.appendingPathComponent("agent-names.json") }

    private func loadNamesIfNeeded() {
        guard !namesLoaded else { return }
        namesLoaded = true
        if let data = try? Data(contentsOf: namesURL),
           let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] {
            names = dict
        }
    }

    private func setName(_ name: String, for sessionID: String) {
        loadNamesIfNeeded()
        names[sessionID] = name
        if let data = try? JSONSerialization.data(withJSONObject: names, options: [.sortedKeys]) {
            try? data.write(to: namesURL, options: .atomic)
        }
    }

    /// The session as it is spoken and shown: the given name if one was
    /// given, the project folder otherwise.
    func displayName(sessionID: String, fallback: String) -> String {
        loadNamesIfNeeded()
        return names[sessionID] ?? fallback
    }
    private func name(of ev: AgentEvent) -> String { displayName(sessionID: ev.sessionID, fallback: ev.project) }
    private func name(of r: Recent) -> String {
        displayName(sessionID: r.sessionID, fallback: r.folder.replacingOccurrences(of: "-", with: " "))
    }

    /// How an episode names its session aloud: the given name plain, or
    /// "your agent on <folder>" — a session is an agent working somewhere,
    /// not the somewhere itself.
    private func spokenWho(_ ev: AgentEvent) -> String {
        loadNamesIfNeeded()
        return names[ev.sessionID] ?? "your agent on \(ev.project)"
    }
    private func spokenWhoCap(_ ev: AgentEvent) -> String {
        let s = spokenWho(ev)
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    /// Open the card under the session's identity — Claude / folder /
    /// title, the way the Claude app's own sidebar names it. The title is
    /// the name the user gave the session if they gave one, else the
    /// session's own title (the app's store or the transcript's
    /// custom-title lines — see SessionTitles), else the terminal
    /// registry's name, else the short id. Shown, never spoken.
    private func beginPanel(for ev: AgentEvent, saying s: String) {
        bumpUsage(ev.agent)
        guard !ev.sessionID.isEmpty else {
            return AgentPanel.shared.begin(header: ev.folder, saying: s)
        }
        loadNamesIfNeeded()
        let title = names[ev.sessionID]
            ?? SessionTitles.title(for: ev.sessionID, cwd: ev.cwd, agent: ev.agent)
            ?? (ev.agent == .claude ? Self.claudeSessionName(for: ev.sessionID) : nil)
            ?? String(ev.sessionID.prefix(8))
        AgentPanel.shared.begin(folder: ev.folder, title: title, agent: ev.agent, saying: s)
    }

    /// A session's title for the little list cards — its sidebar title,
    /// or the short id while it hasn't earned one.
    private func cardTitle(_ r: Recent) -> String {
        SessionTitles.title(for: r.sessionID, cwd: r.cwd, agent: r.agent) ?? String(r.sessionID.prefix(8))
    }

    /// One tiny JSON per live session, written by the Claude Code binary;
    /// `name` is what its terminal title shows. Looked up once per session.
    private static var claudeNames: [String: String] = [:]
    private static func claudeSessionName(for id: String) -> String? {
        if let hit = claudeNames[id] { return hit.isEmpty ? nil : hit }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  obj["sessionId"] as? String == id,
                  let name = obj["name"] as? String, !name.isEmpty else { continue }
            claudeNames[id] = name
            return name
        }
        claudeNames[id] = ""   // remember the miss; the registry won't grow a name mid-session
        return nil
    }

    /// Does the reply point at this session — by the folder's words or by
    /// the name the user gave it?
    private func matches(_ b: String, _ r: Recent) -> Bool {
        var words = Self.bare(r.folder.replacingOccurrences(of: "-", with: " "))
            .split(separator: " ").map(String.init)
        if let n = names[r.sessionID] { words += Self.bare(n).split(separator: " ").map(String.init) }
        return words.contains { $0.count > 2 && b.contains($0) }
    }

    /// "Call it the billing fix", "name this one deploy watcher" → the name.
    private static func nameCommand(_ text: String) -> String? {
        let b = bare(text)
        for prefix in ["call it ", "call this one ", "call this session ", "call this ",
                       "name it ", "name this one ", "name this session ", "name this ",
                       "call the session ", "name the session "] {
            if b.hasPrefix(prefix) {
                var n = String(b.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                for article in ["the ", "a "] where n.hasPrefix(article) && n.count > article.count + 2 {
                    n = String(n.dropFirst(article.count))
                }
                guard !n.isEmpty, n.split(separator: " ").count <= 5 else { return nil }
                return n.prefix(1).uppercased() + n.dropFirst()
            }
        }
        return nil
    }

    // MARK: Usage

    /// How many spoken conversations each agent has had — one bump per
    /// episode the card opens on. The Agents page reads it; on disk beside
    /// the recents so the tally survives relaunches.
    private var usageURL: URL { Config.shared.dir.appendingPathComponent("agent-usage.json") }
    private var _usage: [String: [String: Double]] = [:]
    private var usageLoaded = false

    func usage(for agent: AgentKind) -> (count: Int, last: Date?) {
        loadUsageIfNeeded()
        let u = _usage[agent.rawValue]
        let t = u?["last"] ?? 0
        return (Int(u?["count"] ?? 0), t > 0 ? Date(timeIntervalSince1970: t) : nil)
    }

    private func loadUsageIfNeeded() {
        guard !usageLoaded else { return }
        usageLoaded = true
        guard let data = try? Data(contentsOf: usageURL),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Double]] else { return }
        _usage = obj
    }

    private func bumpUsage(_ agent: AgentKind) {
        loadUsageIfNeeded()
        var u = _usage[agent.rawValue] ?? [:]
        u["count"] = (u["count"] ?? 0) + 1
        u["last"] = Date().timeIntervalSince1970
        _usage[agent.rawValue] = u
        if let data = try? JSONSerialization.data(withJSONObject: _usage, options: [.sortedKeys]) {
            try? data.write(to: usageURL, options: .atomic)
        }
    }

    // MARK: Recent sessions

    /// The last thing each session said, newest first — for "any updates?"
    /// and the menu. Kept small; a session drops off after a day.
    struct Recent { let sessionID: String; let folder: String; let cwd: String
                    let termProgram: String?; let itermSession: String?; let tmuxPane: String?
                    let socket: String?; let token: String?
                    var line: String; var when: Date
                    /// The session is gone — its SessionEnd hook said so, or a
                    /// liveness probe found nobody home. An ended row is still
                    /// remembered (its folder keeps teaching projectCandidates)
                    /// but is never offered as something to talk to.
                    var ended = false
                    /// Rows written before the second agent existed are
                    /// Claude's, which is what the default says.
                    var agent: AgentKind = .claude }
    /// On disk beside agent-names.json: the list used to live in memory,
    /// and every relaunch made "any agent updates?" draw a blank on a day
    /// full of sessions. Sockets and panes in old rows may be dead — the
    /// delivery fallbacks already handle that.
    private var _recents: [Recent] = []
    private var recentsLoaded = false
    private var recentsURL: URL { Config.shared.dir.appendingPathComponent("agent-recents.json") }
    var recents: [Recent] { loadRecentsIfNeeded(); return _recents }

    private func loadRecentsIfNeeded() {
        guard !recentsLoaded else { return }
        recentsLoaded = true
        guard let data = try? Data(contentsOf: recentsURL),
              let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
        _recents = rows.compactMap { r in
            guard let id = r["sessionID"] as? String, let folder = r["folder"] as? String,
                  let cwd = r["cwd"] as? String, let line = r["line"] as? String,
                  let t = r["when"] as? Double else { return nil }
            let when = Date(timeIntervalSince1970: t)
            guard Date().timeIntervalSince(when) <= 86400 else { return nil }
            return Recent(sessionID: id, folder: folder, cwd: cwd,
                          termProgram: r["termProgram"] as? String,
                          itermSession: r["itermSession"] as? String,
                          tmuxPane: r["tmuxPane"] as? String,
                          socket: r["socket"] as? String, token: r["token"] as? String,
                          line: line, when: when,
                          ended: r["ended"] as? Bool ?? false,
                          agent: (r["agent"] as? String).flatMap(AgentKind.init(rawValue:)) ?? .claude)
        }
    }

    private func saveRecents() {
        let rows: [[String: Any]] = _recents.map { r in
            var d: [String: Any] = ["sessionID": r.sessionID, "folder": r.folder, "cwd": r.cwd,
                                    "line": r.line, "when": r.when.timeIntervalSince1970,
                                    "ended": r.ended, "agent": r.agent.rawValue]
            if let v = r.termProgram { d["termProgram"] = v }
            if let v = r.itermSession { d["itermSession"] = v }
            if let v = r.tmuxPane { d["tmuxPane"] = v }
            if let v = r.socket { d["socket"] = v }
            if let v = r.token { d["token"] = v }
            return d
        }
        if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]) {
            try? data.write(to: recentsURL, options: .atomic)
        }
    }

    private func remember(_ ev: AgentEvent, line: String) {
        loadRecentsIfNeeded()
        _recents.removeAll { $0.sessionID == ev.sessionID }
        _recents.insert(Recent(sessionID: ev.sessionID, folder: ev.folder, cwd: ev.cwd,
                               termProgram: ev.termProgram, itermSession: ev.itermSession, tmuxPane: ev.tmuxPane,
                               socket: ev.socket, token: ev.token, line: line, when: Date(),
                               agent: ev.agent), at: 0)
        _recents.removeAll { Date().timeIntervalSince($0.when) > 86400 }
        if _recents.count > 12 { _recents.removeLast(_recents.count - 12) }
        saveRecents()
    }
    // MARK: Liveness

    /// The sessions still there to talk to. A stopped session used to sit
    /// in the list looking alive for a day — "any updates?" would offer a
    /// conversation with a ghost. Every surface that offers a session
    /// (the voice's lists, the picker, the menu) reads this instead of
    /// `recents`; the full list keeps the ended rows for what they still
    /// know (their folders feed projectCandidates).
    var liveRecents: [Recent] {
        loadRecentsIfNeeded()
        pruneDead()
        return _recents.filter { !$0.ended }
    }

    /// Read-only surfaces (the menu) poke this so ended sessions gray out
    /// without waiting for a voice query to sweep.
    func refreshLiveness() {
        loadRecentsIfNeeded()
        pruneDead()
    }

    /// Mark the rows whose sessions no longer answer. Local connects and
    /// pid checks — cheap, but throttled to one sweep per few seconds so
    /// menu rebuilds don't drum on the sockets.
    private var lastLivenessSweep = Date.distantPast
    private func pruneDead() {
        guard Date().timeIntervalSince(lastLivenessSweep) > 5 else { return }
        lastLivenessSweep = Date()
        var changed = false
        for i in _recents.indices where !_recents[i].ended && !Self.seemsAlive(_recents[i]) {
            _recents[i].ended = true
            changed = true
            log("session [\(_recents[i].sessionID.prefix(8))] on \(_recents[i].folder) is gone — marked ended")
        }
        if changed {
            saveRecents()
        }
    }

    /// Only what can be checked is judged; a session with neither socket
    /// nor registry entry keeps its seat.
    private static func seemsAlive(_ r: Recent) -> Bool {
        // Codex forwards no socket and keeps no pid registry: its own
        // SessionEnd hook is the only word we get, and it is a reliable
        // one (verified on a real session — a finished run sends it).
        // So a Codex row is taken at its word until then.
        if r.agent == .codex { return true }
        // The inbox socket is the sharpest test: a dead process leaves
        // the file behind, but nothing accepts the connect.
        if let sock = r.socket, !sock.isEmpty {
            return FileManager.default.fileExists(atPath: sock) && socketAccepts(sock)
        }
        // No socket forwarded: the ~/.claude/sessions registry knows the
        // owning pid, and a pid no longer running is a session no longer
        // running.
        if let pid = registryPID(for: r.sessionID) {
            return Darwin.kill(pid, 0) == 0 || errno == EPERM
        }
        return true
    }

    /// One connect(), nothing sent — "is anyone there?". The session's
    /// accept loop reads EOF and moves on.
    private static func socketAccepts(_ path: String) -> Bool {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }   // no socket to ask with — no verdict
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return true }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sa_family_t>.size + MemoryLayout<UInt8>.size + bytes.count + 1)
        return withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) == 0 }
        }
    }

    /// The registry's file for this session names the pid that owns it.
    private static func registryPID(for id: String) -> pid_t? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  obj["sessionId"] as? String == id else { continue }
            if let p = obj["pid"] as? Int { return pid_t(p) }
            if let p = Int32(f.deletingPathExtension().lastPathComponent) { return p }
        }
        return nil
    }

    /// The session's own word that it is over (SessionEnd), or a probe's.
    private func markEnded(_ sid: String, reason: String) {
        loadRecentsIfNeeded()
        guard let i = _recents.firstIndex(where: { $0.sessionID == sid }), !_recents[i].ended else { return }
        _recents[i].ended = true
        saveRecents()
        log("session [\(sid.prefix(8))] ended (\(reason))")
    }

    /// Back from the dead — a --resume brings the same session id with it.
    private func markAlive(_ sid: String) {
        loadRecentsIfNeeded()
        guard let i = _recents.firstIndex(where: { $0.sessionID == sid }), _recents[i].ended else { return }
        _recents[i].ended = false
        saveRecents()
    }

    /// Bring a remembered session's window forward (from the menu).
    func focusRecent(_ r: Recent) {
        activateHost(for: Self.event(for: r)) { _ in }
    }

    // MARK: Lifecycle

    /// Start if the setting is on, stop if it is off.
    func apply() {
        AgentPanel.shared.onClose = { [weak self] in
            guard let self = self, self.current != nil else { return }
            self.log("closed from the card")
            self.finishQuietly()
        }
        if Config.shared.agentVoice {
            // A newer build can carry a newer hook set — ours are replaced
            // as a set, so refresh in place rather than wait on a manual
            // remove-and-install.
            let port = Config.shared.agentPort
            // Claude Code only speaks up if its hooks are in place, so the
            // switch puts them there. There is nothing for the user to
            // install, and nothing they could forget to install: turning
            // the voice on IS the setup. (Ours are replaced as a set, so
            // a newer build's hooks land the same way.)
            if !AgentHooks.installed(port: port) || AgentHooks.needsUpgrade(port: port) {
                do { try AgentHooks.install(port: port); log("Claude hooks in place for port \(port)") }
                catch { log("Claude hooks couldn't be written — \(error.localizedDescription)") }
            }
            // Spoken replies to a prompts-off session need a setting in
            // Claude Code's own config, and that setting opens those sessions
            // to every app on this Mac. So it is asked for, once, in words
            // that say exactly that; the answer stands (AGENT_INBOUND), and
            // a yes is put back each launch, since a voice-off took it out.
            // Unanswered with the setting already there means an older build
            // wrote it without asking: that Mac is asked too.
            switch Config.shared.env()["AGENT_INBOUND"] {
            case "no": break
            case "yes": if !AgentHooks.inboundAccepted() { acceptInbound() }
            default: DispatchQueue.main.async { [weak self] in self?.askToAcceptInbound() }
            }
            // Codex needs none — it is read from its own files. Any left
            // by the build that used hooks are taken back out.
            if CodexHooks.cleanUp() { log("removed the old Codex hooks — none are needed now") }
            start()
        } else {
            stop()
            // Off means off: what the switch put in another app's config
            // comes back out, so nothing of ours is left running or
            // waiting anywhere.
            if AgentHooks.installed(port: Config.shared.agentPort) {
                do {
                    try AgentHooks.remove(port: Config.shared.agentPort)
                    // The trust grant exists only for this feature, and only
                    // one the user agreed to here is ours to take back.
                    if Config.shared.env()["AGENT_INBOUND"] == "yes" { try AgentHooks.acceptInbound(false) }
                    log("Claude hooks removed — the voice is off")
                } catch { log("Claude hooks couldn't be removed — \(error.localizedDescription)") }
            }
            CodexHooks.cleanUp()
        }
    }

    private func acceptInbound() {
        do {
            if try AgentHooks.acceptInbound(true) { log("inbound accept set with the voice, as agreed") }
            else { log("crossSessionInbound was set by hand — left alone; prompts-off sessions may hold replies") }
        } catch { log("inbound accept couldn't be set — \(error.localizedDescription)") }
    }

    /// The question is up: every settings write runs apply() again, and a
    /// main-queue block runs inside a modal, so without this a second copy
    /// of the same alert would stack on the first.
    private var askingInbound = false

    /// The one question about another app's settings: what changes, where,
    /// and what it lets in besides us. Nothing is written without a yes, and
    /// a no takes out one an older build wrote unasked.
    private func askToAcceptInbound() {
        guard !askingInbound, Config.shared.agentVoice,
              Config.shared.env()["AGENT_INBOUND"] == nil else { return }
        askingInbound = true
        defer { askingInbound = false }
        let alert = NSAlert()
        alert.messageText = "Let spoken replies reach Claude sessions with prompts off?"
        alert.informativeText = """
            Claude Code holds back messages to a session running with permission prompts off. \
            To let your spoken replies through, SayControl needs "crossSessionInbound": "accept" \
            in ~/.claude/settings.json.

            That lets any app on this Mac send messages into those sessions, not only SayControl. \
            Turning the agent voice off takes it back out. Don't Allow leaves it out (and removes it \
            if it's there); replies to those sessions then wait until you look at them, and \
            everything else works the same.
            """
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        NSApp.activate(ignoringOtherApps: true)
        let yes = alert.runModal() == .alertFirstButtonReturn
        log("inbound accept \(yes ? "allowed" : "declined") by the user")
        // Claude Code's file first, the answer after: saving the answer runs
        // apply() again, which must find the file already as agreed.
        if yes {
            acceptInbound()
        } else if AgentHooks.inboundAccepted() {
            do { try AgentHooks.acceptInbound(false); log("inbound accept an older build set is taken back out") }
            catch { log("inbound accept couldn't be taken out — \(error.localizedDescription)") }
        }
        Config.shared.set("AGENT_INBOUND", yes ? "yes" : "no")
    }

    /// A brief waiting for its session to boot (desktop-app launches): the
    /// deep link opens the app, the trust click births the session, its
    /// SessionStart hook lands here, and the brief goes in through the
    /// fresh session's inbox socket — sent, not sitting in a composer.
    private var pendingLaunch: (dir: String, brief: String, at: Date)?

    /// End the episode without a word and without the card lingering.
    private func finishQuietly() {
        respond("{}")
        current = nil
        hotkeyArmedUntil = .distantPast
        keyTookOver = false
        if agentCapture { agentCapture = false; app?.endAgentCapture(discard: true) }
        app?.concealPill(false)
        replyTimer?.invalidate()
        VoiceIO.shared.stopAll()
        AgentPanel.shared.hideNow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.next() }
    }

    // MARK: Asking about the agents

    /// A dictation that is a question for the bridge, not words to paste:
    /// "any agent updates?", "what did the agents say?", "talk to the
    /// agent". True means it was taken.
    func handleQuery(_ text: String) -> Bool {
        guard running else { return false }
        let b = Self.bare(text)
        // The spoken controls that work from a cold dictation: quiet
        // hours on and off, a broadcast, a changes ask.
        if let secs = Self.quietCommand(b) {
            log("query: quiet hours — \(Config.words(text))")
            startQuiet(secs)
            return true
        }
        if Self.resumeCommand(b), b.split(separator: " ").count <= 8 {
            log("query: resume monitoring")
            endQuiet()
            return true
        }
        if let msg = Self.broadcastCommand(b) {
            log("query: broadcast — \(Config.words(text))")
            claim(.conversation) { [weak self] ok in if ok { self?.broadcast(msg) } }
            return true
        }
        let asksChanges = ["what did the agent change", "what did claude change", "what did the agents change",
                           "what has the agent changed", "show me what the agent changed",
                           "what did the agent actually change"]
            .contains { b.contains($0) }
        if asksChanges, b.split(separator: " ").count <= 10 {
            claim(.conversation) { [weak self] ok in
                guard let self = self, ok else { return }
                guard let r = self.liveRecents.first ?? self.recents.first else {
                    AgentPanel.shared.begin(header: "Agents", saying: "")
                    return self.say("No agents have reported yet.") { [weak self] in self?.finish(reason: "no agents") }
                }
                self.log("query: changes — \(self.name(of: r))")
                if self.current != nil { self.finishQuietly() }
                self.current = Pending(event: Self.event(for: r))
                self.beginPanel(for: Self.event(for: r), saying: "")
                self.showChanges()
            }
            return true
        }
        // Question- and imperative-shaped only, always anchored on
        // agent/session words: a short dictation CONTAINING one of these
        // is taken from the paste pipeline, so nothing here may be a
        // phrase someone would dictate INTO a document or a prompt.
        let asksUpdates = ["any agent updates", "any updates from the agents", "any updates from the agent",
                           "agent updates", "any agent update", "what did the agents say", "what did the agent say",
                           "agent status", "any agents finished", "which agents finished", "any updates", "agents update",
                           "how are the agents", "how are my agents", "how is the agent doing",
                           "what are the agents doing", "what are my agents doing",
                           "check on the agents", "check on my agents", "check the agents",
                           "any news from the agents", "anything new from the agents",
                           "are the agents done", "is the agent done", "did any agent finish",
                           "status of the agents", "what's happening with the agents",
                           "whats happening with the agents",
                           // The presence shape — "is there any agent running?",
                           // "are there any agents running?" — and its session-worded twins.
                           "any agent running", "any agents running", "is an agent running",
                           "are any agents running", "any running agents", "any active agents",
                           "any session running", "any sessions running", "any running sessions",
                           "any active sessions", "any live sessions",
                           // The mailbox shape — "any recent agent messages?". A phrase
                           // listed singular also catches its plural by substring.
                           "any agent message", "any recent agent message", "any new agent message",
                           "any message from the agent", "any messages from the agent",
                           "any recent message from the agent", "any recent messages from the agent",
                           "any session update", "any session message", "any recent session message"]
            .contains { b.contains($0) }
        let asksTalk = ["talk to the agent", "talk to an agent", "reply to the agent", "reply to an agent",
                        "message the agent", "tell the agent", "talk to claude", "reply to claude",
                        "send to the agent", "open the agents", "show the agents", "list the agents",
                        "list agents", "agent list",
                        "show me my agents", "show my agents", "show me the agents",
                        "show the list of agents", "show me the list of agents", "list my agents",
                        "which agents are running", "what agents are running", "which sessions are running",
                        "show my sessions", "show me my sessions", "list my sessions",
                        "show the sessions", "talk to my agents", "talk to a session"]
            .contains { b.contains($0) }
        // "Create a new claude session on the web project" — a command to
        // start an agent, not a question about the running ones.
        if let (frag, host, agent) = Self.newSessionFragment(b), b.split(separator: " ").count <= 14 {
            log("query: new \(agent.display) session — \(Config.words(text))")
            claim(.conversation) { [weak self] ok in
                if ok { self?.startCreate(fragment: frag, host: host, agent: agent) }
            }
            return true
        }
        // People trail off — "any agent running, or any recent agent
        // messages, or something like that?" — so the filler comes off the
        // tail before the length gate, and the gate allows a doubled-up ask.
        var counted = b
        for tail in ["or something like that", "or anything like that", "or something", "or anything",
                     "or whatever", "or what", "like that"] where counted.hasSuffix(" " + tail) {
            counted = String(counted.dropLast(tail.count + 1)).trimmingCharacters(in: .whitespaces)
        }
        guard asksUpdates || asksTalk, counted.split(separator: " ").count <= 12 else { return false }
        log("query: \(Config.words(text))")
        claim(.conversation) { [weak self] ok in if ok { self?.showSessionList() } }
        return true
    }

    /// The running sessions as numbered cards plus "which one?" — from a
    /// fresh "any updates?" dictation, or mid-episode when the reply's
    /// intent turned out to be about the list rather than for the agent.
    private func showSessionList() {
        if current != nil { finishQuietly() }
        var p = Pending(event: AgentEvent(kind: .finished, sessionID: "", cwd: "", message: "", asked: nil,
                                          toolName: nil, toolInput: [:], questions: [], termProgram: nil,
                                          itermSession: nil, tmuxPane: nil, socket: nil, token: nil))
        p.stage = .pick
        current = p
        let list = liveRecents
        guard !list.isEmpty else {
            AgentPanel.shared.begin(header: "Agents", saying: "")
            // A remembered-but-ended session is told apart from a blank
            // slate — "the Files agent" the user is asking after really
            // existed; it just isn't running any more.
            let s: String
            if let gone = recents.first {
                s = "No agents running right now — the last session, on "
                    + Self.spoken(gone.folder.replacingOccurrences(of: "-", with: " ")) + ", has ended."
            } else {
                s = "No agents have reported yet."
            }
            return say(s) { [weak self] in self?.finish(reason: "no live agents") }
        }
        // Each session lands as its own numbered card; the voice only asks.
        let s = list.count == 1
            ? "One session today — \(name(of: list[0])). Talk to it?"
            : "Which one?"
        current?.spoken = s
        AgentPanel.shared.begin(header: "Agents", saying: "")
        AgentPanel.shared.listCards(list.prefix(8).map { r in
            (title: name(of: r),
             sub: "\(cardTitle(r)) · \(Self.ago(r.when))",
             preview: Self.firstSentences(of: r.line, limit: 120),
             agent: r.agent)
        })
        AgentPanel.shared.say(s)
        listenAndSpeak(s)
    }

    static func ago(_ d: Date) -> String {
        let m = Int(Date().timeIntervalSince(d) / 60)
        if m < 1 { return "just now" }
        if m < 60 { return "\(m) minute\(m == 1 ? "" : "s") ago" }
        let h = m / 60
        return "\(h) hour\(h == 1 ? "" : "s") ago"
    }

    /// The literal matchers missed the pick: hand the LLM the numbered
    /// names and the words as heard. A number back picks; anything else
    /// falls to the old re-ask, once, and then the episode lets go.
    private func fuzzyPick(_ b: String, from list: [Recent]) {
        let options = list.map { name(of: $0) + " — folder " + $0.folder }
        Refiner.shared.pick(b, options: options) { [weak self] n in
            DispatchQueue.main.async {
                guard let self = self, let p = self.current, p.stage == .pick else { return }
                if let n = n, n >= 1, n <= list.count {
                    self.log("pick: LLM matched “\(Config.words(b))” → #\(n)")
                    return self.resume(list[n - 1])
                }
                if p.rounds == 0 {
                    self.current?.rounds = 1
                    let s = "Say a number, a name, or 'read the last message'."
                    AgentPanel.shared.say(s)
                    return self.listenAndSpeak(s)
                }
                self.finish(reason: "no pick")
            }
        }
    }

    // MARK: Starting a session

    /// "^create/start/open a new (claude|codex …)? session/agent/project
    /// (on|in|for <folder words>)?" — anchored at the front so prose that
    /// merely mentions creating sessions never trips it. Returns the folder
    /// words ("" when none were given), where to open, and which agent.
    static func newSessionFragment(_ b: String) -> (frag: String, host: LaunchHost?, agent: AgentKind)? {
        // Anchored both ends: mid-prose mentions never trip it, and a tail
        // that isn't "on/in/for <folder>" (…"session token for users")
        // fails the match instead of opening an empty folder ask.
        // A few opener words are let through — "Okay, start a new…" is how
        // people actually talk, and one "okay" defeated the anchor once.
        // Between "new" and "session" is where the agent gets named, and
        // the recogniser writes both however it likes — see saidCodex.
        let pattern = "^(?:(?:okay|ok|yeah|yes|hey|so|now|please|um|uh|alright|right|and|then)\\s+){0,3}"
            + "(?:create|start|open|spin up|make)\\s+(?:a\\s+)?new\\s+((?:[a-z0-9']+\\s+){0,2})(?:session|agent|project)(?:\\s+(?:on|in|for|at)\\s+(.+))?\\s*$"
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: b, range: NSRange(b.startIndex..., in: b)) else { return nil }
        // The word or two before "session" names the agent. The recogniser
        // writes both however it likes — "cloud code", "codecs", "kodak" —
        // so they are matched by sound, not spelling, and anything that
        // sounds like neither leaves the default alone.
        let said = Range(m.range(at: 1), in: b).map { String(b[$0]) } ?? ""
        let agent: AgentKind = Self.saidCodex(said) ? .codex : .claude
        guard m.numberOfRanges > 2, let r = Range(m.range(at: 2), in: b) else { return ("", nil, agent) }
        var frag = String(b[r]).trimmingCharacters(in: .whitespaces)
        // "…in the desktop app" / "…in the terminal" names the destination,
        // not the folder — peel it off either end of the fragment.
        var host: LaunchHost?
        let apps = ["the desktop app", "the claude app", "the cloud app", "the app", "desktop app", "claude app"]
        let terms = ["the terminal", "terminal", "a terminal"]
        for a in apps where frag.hasSuffix(" in " + a) || frag.hasSuffix(" on " + a) {
            host = .desktopApp; frag = String(frag.dropLast(a.count + 4)); break
        }
        if host == nil, apps.contains(frag) { host = .desktopApp; frag = "" }
        if host == nil {
            for t in terms where frag.hasSuffix(" in " + t) || frag.hasSuffix(" on " + t) {
                host = .terminal; frag = String(frag.dropLast(t.count + 4)); break
            }
            if host == nil, terms.contains(frag) { host = .terminal; frag = "" }
        }
        frag = frag.trimmingCharacters(in: .whitespaces)
        if frag.hasPrefix("the ") { frag = String(frag.dropFirst(4)) }
        for tail in ["folder", "project", "directory", "repo"] where frag.hasSuffix(" " + tail) {
            frag = String(frag.dropLast(tail.count + 1))
        }
        return (frag.trimmingCharacters(in: .whitespaces), host, agent)
    }

    /// Did those words mean Codex? "codex", and the near misses a
    /// recogniser reaches for when it has never heard the word —
    /// "codecs", "code x", "kodak". Kept tight: nothing here may be a
    /// word someone would say meaning Claude.
    static func saidCodex(_ words: String) -> Bool {
        let bare = slug(words)
        return ["codex", "codec", "codeks", "kodex", "kodak", "codix"].contains { bare.contains($0) }
    }

    /// A new episode that walks a session into being. The folder comes
    /// from the fragment (or a follow-up answer), then the brief, then
    /// the go — money and attention start only on an explicit yes.
    func startCreate(fragment: String, host: LaunchHost? = nil, agent: AgentKind = .claude) {
        if current != nil { finishQuietly() }
        var p = Pending(event: AgentEvent(kind: .finished, sessionID: "", cwd: "", message: "", asked: nil,
                                          toolName: nil, toolInput: [:], questions: [], termProgram: nil,
                                          itermSession: nil, tmuxPane: nil, socket: nil, token: nil,
                                          agent: agent))
        p.stage = .projectPick
        p.launchHost = host
        current = p
        AgentPanel.shared.begin(header: "New \(agent.display) session", saying: "")
        matchProject(fragment)
    }

    /// Where the session opens: what the user said, else where that
    /// agent's sessions already live — a last session with no terminal
    /// forwarded means they work in the desktop app.
    private func chosenHost() -> LaunchHost {
        if let h = current?.launchHost { return h }
        // Codex's desktop app has no deep link that takes a folder AND a
        // brief, so a Codex session always opens where both fit: the
        // terminal, with the folder and the brief as arguments.
        if current?.event.agent == .codex { return .terminal }
        guard let last = recents.first(where: { $0.agent == (current?.event.agent ?? .claude) }) else { return .terminal }
        return last.termProgram == nil ? .desktopApp : .terminal
    }

    /// The folders a session could start in: everywhere the agents have
    /// run, and the folders beside those — one workspace directory usually
    /// holds every project.
    private func projectCandidates() -> [URL] {
        let fm = FileManager.default
        var seen = Set<String>()
        var out: [URL] = []
        func add(_ url: URL) {
            let p = url.standardizedFileURL.path
            var isDir: ObjCBool = false
            guard !seen.contains(p), fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { return }
            seen.insert(p)
            out.append(url)
        }
        // The session folders, the workspaces above them (two levels, so
        // "code files" finds ~/Desktop/CODE_FILES), and the folders beside
        // each — but never as high as the home folder itself.
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        for r in recents where !r.cwd.isEmpty {
            var u = URL(fileURLWithPath: r.cwd)
            for _ in 0..<3 {
                guard u.standardizedFileURL.path.count > home.count else { break }
                add(u)
                u = u.deletingLastPathComponent()
            }
        }
        let bases = out
        for parent in Set(bases.map { $0.deletingLastPathComponent() }) {
            let kids = (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey],
                                                    options: [.skipsHiddenFiles])) ?? []
            for k in kids.prefix(60) { add(k) }
        }
        return out
    }

    private static func slug(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Folder words → a folder on disk. Letter-for-letter first, then the
    /// LLM over the candidate names; a miss re-asks once.
    private func matchProject(_ fragment: String) {
        let dirs = projectCandidates()
        guard !dirs.isEmpty else {
            return say("I don't know any project folders yet — talk to an agent once, then try again.") {
                self.finish(reason: "no known folders")
            }
        }
        guard !fragment.isEmpty else {
            let known = dirs.prefix(3).map { Self.spoken($0.lastPathComponent) }.joined(separator: ", ")
            let s = "Which project? I know \(known), and more."
            AgentPanel.shared.say(s)
            return listenAndSpeak(s)
        }
        let frag = Self.slug(fragment)
        let hits = dirs.filter {
            let name = Self.slug($0.lastPathComponent)
            return name.contains(frag) || frag.contains(name)
        }
        if hits.count == 1 { return askBrief(hits[0]) }
        let options = Array(dirs.prefix(30)).map { $0.lastPathComponent }
        Refiner.shared.pick(fragment, options: options) { [weak self] n in
            DispatchQueue.main.async {
                guard let self = self, let p = self.current, p.stage == .projectPick else { return }
                if let n = n, n >= 1, n <= options.count { return self.askBrief(dirs[n - 1]) }
                if let first = hits.first { return self.askBrief(first) }
                if p.rounds == 0 {
                    self.current?.rounds = 1
                    let s = "I didn't find \(fragment). Say the folder name again, or cancel."
                    AgentPanel.shared.say(s)
                    return self.listenAndSpeak(s)
                }
                self.say("I couldn't find that folder.") { self.finish(reason: "no folder") }
            }
        }
    }

    private func askBrief(_ dir: URL) {
        current?.projectDir = dir
        current?.stage = .brief
        log("new session: folder \(Config.detail(dir.path))")
        let who = (current?.event.agent ?? .claude).spoken
        let s = "New \(who) session in \(Self.spoken(dir.lastPathComponent)). What should it work on?"
        AgentPanel.shared.say(s)
        listenAndSpeak(s)
    }

    /// Open the user's terminal at the folder and start the agent there
    /// with the brief as its first prompt. The terminal is whichever one
    /// the sessions already run in; nothing known means Terminal. The
    /// brief rides as a shell argument, so nothing depends on paste
    /// timing — which is also why Codex only ever starts here.
    private func launchSession(in dir: URL, brief: String) {
        let agent = current?.event.agent ?? .claude
        // The desktop app first when that's the ask or the habit: its
        // code/new deep link takes the folder and the brief directly
        // (claude://code/new?folder=…&q=…). A failed open — app missing,
        // link refused — falls through to the terminal, which always works.
        if agent == .claude, chosenHost() == .desktopApp {
            var comps = URLComponents()
            comps.scheme = "claude"
            comps.host = "code"
            comps.path = "/new"
            // Folder only — the brief does NOT ride the link. A ?q= would
            // just sit in the composer unsent; instead the SessionStart
            // hook of the session born from this link brings us its socket
            // and the brief goes in as a real message (see route()).
            comps.queryItems = [URLQueryItem(name: "folder", value: dir.path)]
            if let url = comps.url, NSWorkspace.shared.open(url) {
                pendingLaunch = brief.isEmpty ? nil : (dir: dir.path, brief: brief, at: Date())
                log("new session: deep link to the Claude app — \(Config.detail(dir.path))")
                // The app treats a linked folder as untrusted and asks once
                // on its own screen — say so, or the pause reads as failure.
                return say("Opened in the Claude app — confirm the folder there and I'll send your brief in.") {
                    self.finish(reason: "session started (app)")
                }
            }
            log("new session: the Claude app didn't take the link; using the terminal")
        }
        let term = (recents.first { $0.termProgram != nil }?.termProgram ?? "").lowercased()
        // Codex usually isn't on PATH — the desktop app carries its own
        // copy, and that copy drives the same sessions — so the full path
        // is used when the bare name isn't there to be found.
        let cli = agent == .codex ? Self.shellQuote(Codex.binary ?? "codex") : "claude"
        let sh = brief.isEmpty
            ? "cd \(Self.shellQuote(dir.path)) && \(cli)"
            : "cd \(Self.shellQuote(dir.path)) && \(cli) \(Self.shellQuote(brief))"
        let script: String
        if term.contains("iterm") {
            script = """
            tell application "iTerm"
                activate
                set w to (create window with default profile)
                tell current session of w to write text "\(Self.appleQuote(sh))"
            end tell
            """
        } else {
            script = """
            tell application "Terminal"
                activate
                do script "\(Self.appleQuote(sh))"
            end tell
            """
        }
        log("new session: launching in \(Config.detail(dir.path)) — \(Config.words(brief, upTo: 80))")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        do {
            try proc.run()
            say("Started. It'll report here when it has something.") { self.finish(reason: "session started") }
        } catch {
            log("new session: launch failed — \(error.localizedDescription)")
            say("I couldn't open the terminal.") { self.finish(reason: "launch failed") }
        }
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    /// Into an AppleScript string literal.
    private static func appleQuote(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Pick up a remembered session: what to tell it, by voice. From the
    /// menu, or after "which one?". A session that has meanwhile ended is
    /// said to have ended — not offered a conversation it can't hold.
    func resume(_ r: Recent) {
        // Picked from the list mid-conversation, it carries on in that one;
        // from the Agents page it is a conversation of its own.
        let within = current != nil
        if within { finishQuietly() }
        let held = Pending(event: Self.event(for: r))
        current = held
        let go = { [weak self] in
            guard let self = self else { return }
            if r.ended || !Self.seemsAlive(r) {
                self.markEnded(r.sessionID, reason: "probe on resume")
                AgentPanel.shared.begin(header: "Agents", saying: "")
                return self.say("That session has ended — it can't take messages any more.") {
                    self.finish(reason: "session ended")
                }
            }
            self.open(spoken: "What should I tell \(self.spokenWho(r))?")
        }
        if within { return go() }
        claim(.conversation) { [weak self] ok in
            guard let self = self, self.current?.event.received == held.event.received else { return }
            guard ok else { self.current = nil; return self.next() }
            go()
        }
    }

    /// Read a session's last message aloud in full, then take a reply for it
    /// — "give me the last message" after "which one?".
    private func readBack(_ r: Recent) {
        current = Pending(event: Self.event(for: r))
        let line = Self.firstSentences(of: r.line, limit: 400)
        let who = spokenWho(r)
        open(spoken: "\(who.prefix(1).uppercased() + who.dropFirst()) said: \(line) Anything to send back?")
    }

    /// The spoken identity of a remembered session — see spokenWho(_:) above.
    private func spokenWho(_ r: Recent) -> String {
        loadNamesIfNeeded()
        return names[r.sessionID] ?? "your agent on \(r.folder.replacingOccurrences(of: "-", with: " "))"
    }

    /// A remembered session, as an event the episode machinery can hold.
    private static func event(for r: Recent) -> AgentEvent {
        AgentEvent(kind: .finished, sessionID: r.sessionID, cwd: r.cwd, message: r.line, asked: nil,
                   toolName: nil, toolInput: [:], questions: [], termProgram: r.termProgram,
                   itermSession: r.itermSession, tmuxPane: r.tmuxPane, socket: r.socket, token: r.token,
                   agent: r.agent)
    }

    func start() {
        guard !running else { return }
        if accountWatch == nil {
            accountWatch = NotificationCenter.default.addObserver(forName: .sayctrlAccountChanged, object: nil,
                                                                  queue: .main) { [weak self] _ in self?.hushIfSignedOut() }
        }
        let p = Config.shared.agentPort
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(p)) else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
        do {
            let l = try NWListener(using: params)
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.log("listening on 127.0.0.1:\(p)")
                case .failed(let e):
                    self?.log("listener failed — \(e.localizedDescription)")
                    DispatchQueue.main.async { self?.stop() }
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] conn in self?.serve(conn) }
            l.start(queue: .main)
            listener = l
            port = p
            running = true
            // Codex needs nothing installed to be heard: it writes every
            // turn to its rollout file, and the watcher tails those. Hooks
            // are only for what a file can't carry — a permission request
            // waiting on an answer. Both may be live at once (installed
            // hooks, or installed-but-not-yet-trusted ones); enqueue drops
            // the second telling of the same finish.
            CodexWatcher.shared.onTurn = { [weak self] sid, cwd, message, asked, desktop in
                guard let self = self else { return }
                self.log("codex turn finished [\(sid.prefix(8))] on \(URL(fileURLWithPath: cwd).lastPathComponent)")
                self.enqueue(Pending(event: AgentEvent(
                    kind: .finished, sessionID: sid, cwd: cwd, message: message, asked: asked,
                    toolName: nil, toolInput: [:], questions: [],
                    termProgram: desktop ? nil : "codex_cli", itermSession: nil, tmuxPane: nil,
                    socket: nil, token: nil, agent: .codex)))
            }
            CodexWatcher.shared.onStall = { [weak self] sid, cwd, reason, desktop in
                self?.stalled(agent: .codex, sessionID: sid, cwd: cwd, reason: reason,
                              termProgram: desktop ? nil : "codex_cli")
            }
            // Claude's rate limits are the quietest failure it has: the
            // turn never finishes, so no Stop hook fires and nothing but
            // the window says so. Its transcripts are read for those.
            ClaudeWatcher.shared.onStall = { [weak self] sid, cwd, reason in
                self?.stalled(agent: .claude, sessionID: sid, cwd: cwd, reason: reason, termProgram: nil)
            }
            CodexWatcher.shared.start()
            ClaudeWatcher.shared.start()
            if CodexWatcher.shared.running { log("reading along with Codex at \(Codex.home.path)") }
            else if Codex.installed { log("codex is here but its sessions folder isn't readable") }
            // The stuck-agent watchdog: one look a minute at the sessions
            // a message went into that haven't said a word since.
            watchdogTimer?.invalidate()
            watchdogTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                self?.sweepStuck()
            }
        } catch {
            log("couldn't listen on \(p) — \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        running = false
        CodexWatcher.shared.stop()
        ClaudeWatcher.shared.stop()
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        if agentCapture { agentCapture = false; app?.endAgentCapture(discard: true) }
        app?.concealPill(false)
        VoiceIO.shared.stopAll()
        replyTimer?.invalidate()
        if let c = current { c.respond?("{}") }
        current = nil
        queue.forEach { $0.respond?("{}") }
        queue.removeAll()
    }

    /// An agent that stopped without finishing — rate limited, out of
    /// credits, signed out. Said like any other news, and the reply goes
    /// back into the session the usual way, so "carry on when you can" or
    /// a fresh instruction reaches it without touching the window. What a
    /// session that already knows it is stuck needs is a nudge, and the
    /// user is the one who decides when.
    ///
    /// A remembered session keeps whatever the terminal told us about it;
    /// only a brand-new one falls back to what the watcher could see.
    private func stalled(agent: AgentKind, sessionID: String, cwd: String, reason: String,
                         termProgram: String?) {
        // Said once a quarter of an hour, per session and per reason. A
        // rate limit is not a moment, it is a state: an agent that keeps
        // trying writes the same error again and again, and the general
        // two-minute dedup would let it nag.
        let mark = sessionID + "\u{1}" + reason
        if let at = stallSpoken[mark], Date().timeIntervalSince(at) < 900 { return }
        stallSpoken[mark] = Date()
        stallSpoken = stallSpoken.filter { Date().timeIntervalSince($0.value) < 3600 }
        loadRecentsIfNeeded()
        let known = _recents.first { $0.sessionID == sessionID }
        log("\(agent.display) [\(sessionID.prefix(8))] \(reason)")
        enqueue(Pending(event: AgentEvent(
            kind: .needsInput, sessionID: sessionID, cwd: cwd.isEmpty ? (known?.cwd ?? "") : cwd,
            message: reason, asked: nil, toolName: nil, toolInput: [:], questions: [],
            termProgram: known?.termProgram ?? termProgram, itermSession: known?.itermSession,
            tmuxPane: known?.tmuxPane, socket: known?.socket, token: known?.token, agent: agent)))
    }

    // MARK: HTTP

    /// Just enough HTTP/1.1 for a hook: one POST, Content-Length, one JSON
    /// reply, close.
    private func serve(_ conn: NWConnection) {
        conn.start(queue: .main)
        var buffer = Data()
        func read() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
                guard let self = self else { return conn.cancel() }
                if let data = data { buffer.append(data) }
                if error != nil { return conn.cancel() }
                if let req = Self.parse(buffer) {
                    self.route(req.path, headers: req.headers, body: req.body) { reply in
                        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                            + "Content-Length: \(reply.utf8.count)\r\nConnection: close\r\n\r\n"
                        conn.send(content: Data(head.utf8) + Data(reply.utf8), completion: .contentProcessed { _ in
                            conn.cancel()
                        })
                    }
                } else if done || buffer.count > (1 << 20) {
                    conn.cancel()
                } else {
                    read()
                }
            }
        }
        read()
    }

    private static func parse(_ data: Data) -> (path: String, headers: [String: String], body: Data)? {
        guard let headEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[..<headEnd.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let request = lines.removeFirst().split(separator: " ")
        guard request.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            guard let i = l.firstIndex(of: ":") else { continue }
            headers[l[..<i].trimmingCharacters(in: .whitespaces).lowercased()]
                = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[headEnd.upperBound...]
        guard body.count >= length else { return nil }
        return (String(request[1]), headers, Data(body.prefix(length)))
    }

    private func route(_ path: String, headers: [String: String], body: Data,
                       reply: @escaping (String) -> Void) {
        guard path.hasPrefix("/sayctrl/") else { return reply("{}") }
        if path == "/sayctrl/ping" { return reply("{\"sayctrl\":\"\(Config.isDev ? "dev" : "app")\"}") }
        // Only our own hooks get past here (AgentHooks.secret). A browser's
        // request carries an Origin, which no hook sends, so one is refused
        // even before the secret is looked at. An empty reply leaves Claude
        // Code to its own prompt.
        guard headers["origin"] == nil,
              headers[AgentHooks.tokenHeader.lowercased()] == AgentHooks.secret else {
            log("refused a request on \(path) — not from our hooks")
            return reply("{}")
        }
        guard let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            log("bad JSON on \(path)")
            return reply("{}")
        }
        let env = { (k: String) -> String? in
            let v = headers[k]?.trimmingCharacters(in: .whitespaces) ?? ""
            return v.isEmpty ? nil : v
        }
        // /sayctrl/Stop is Claude's. Nothing posts to /sayctrl/codex any
        // more — Codex is read from its own files — but a session that
        // was already running when the old hooks were removed can still
        // knock, and it should be heard as Codex rather than mistaken for
        // Claude. The payloads are the same shape either way.
        let agent: AgentKind = path.hasPrefix("/sayctrl/codex/") ? .codex : .claude
        let sid = json["session_id"] as? String ?? ""
        let cwd = json["cwd"] as? String ?? ""
        // Any hook from a session is the session speaking up — whatever
        // else it is, it is not silently stuck (see the watchdog).
        if !sid.isEmpty { workingSince.removeValue(forKey: sid) }
        let term = env("x-term-program"), iterm = env("x-iterm-session"), tmux = env("x-tmux-pane")
        let sock = env("x-messaging-socket"), token = env("x-messaging-token")
        func event(_ kind: AgentEvent.Kind, _ message: String, asked: String? = nil, tool: String? = nil,
                   input: [String: Any] = [:], questions: [AgentEvent.Question] = []) -> AgentEvent {
            AgentEvent(kind: kind, sessionID: sid, cwd: cwd, message: message, asked: asked, toolName: tool,
                       toolInput: input, questions: questions, termProgram: term, itermSession: iterm, tmuxPane: tmux,
                       socket: sock, token: token, agent: agent)
        }
        switch json["hook_event_name"] as? String ?? path.components(separatedBy: "/").last ?? "" {
        case "SessionStart":
            reply("{}")
            // A --resume brings a session id back from the dead.
            if !sid.isEmpty { markAlive(sid) }
            if let w = pendingLaunch, Date().timeIntervalSince(w.at) >= 180 { pendingLaunch = nil }
            // A voice-created desktop session booting: the brief goes in
            // now, through the fresh session's own socket. Fresh starts
            // only — a resume in the same folder is not the new session.
            guard let waiting = pendingLaunch, !waiting.brief.isEmpty,
                  (json["source"] as? String ?? "startup") == "startup",
                  URL(fileURLWithPath: cwd).standardizedFileURL.path
                      == URL(fileURLWithPath: waiting.dir).standardizedFileURL.path,
                  let sock = sock, FileManager.default.fileExists(atPath: sock) else { return }
            pendingLaunch = nil
            let me = Account.name.split(separator: " ").first.map(String.init) ?? "The user"
            if Self.inboxSend(socket: sock, token: token, text: "\(me) says, by voice through SayControl: \(waiting.brief)") {
                log("new session: brief delivered through the fresh session's socket")
                workingSince[sid] = Date()   // the watchdog watches the newborn too
                DispatchQueue.main.async { self.app?.hud.show("Brief sent to the new session", autohide: 2) }
            } else {
                log("new session: the fresh session's socket refused the brief")
            }
        case "SessionEnd":
            reply("{}")
            // The session's own goodbye — /exit, a closed window, a clean
            // quit. The row stays remembered, but stops being offered as
            // someone to talk to. (A killed terminal sends nothing; the
            // liveness probe in liveRecents catches those.)
            if !sid.isEmpty { markEnded(sid, reason: json["reason"] as? String ?? "SessionEnd") }
        case "Stop":
            reply("{}")   // never hold the agent up for a summary
            // A subagent's stop is the inside of a turn, not its end.
            guard json["agent_id"] == nil, json["stop_hook_active"] as? Bool != true else { return }
            let last = (json["last_assistant_message"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !last.isEmpty else { return log("Stop with no message (\(Config.detail(cwd)))") }
            let asked = (json["transcript_path"] as? String).flatMap(Self.lastUserPrompt(in:))
            enqueue(Pending(event: event(.finished, last, asked: asked)))
        case "Notification":
            reply("{}")
            let type = json["notification_type"] as? String ?? ""
            let msg = (json["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            switch type {
            case "permission_prompt":
                // We voiced the request itself moments ago; or the
                // PermissionRequest hook isn't installed and this is all
                // we get.
                if let t = voicedPermission[sid], Date().timeIntervalSince(t) < 120 { return }
                enqueue(Pending(event: event(.needsInput, msg.isEmpty ? "needs permission" : msg)))
            case "agent_needs_input", "elicitation_dialog", "elicitation_url_dialog":
                enqueue(Pending(event: event(.needsInput, msg.isEmpty ? "needs your input" : msg)))
            default:
                // idle_prompt comes a minute after a Stop we already spoke;
                // auth and elicitation bookkeeping say nothing to the ear.
                break
            }
        case "PermissionRequest":
            let tool = json["tool_name"] as? String ?? "a tool"
            let input = json["tool_input"] as? [String: Any] ?? [:]
            voicedPermission[sid] = Date()
            if tool == "AskUserQuestion" {
                let qs = Self.questions(in: input)
                guard !qs.isEmpty else { return reply("{}") }
                enqueue(Pending(event: event(.question, "asks", tool: tool, input: input, questions: qs), respond: reply))
            } else {
                enqueue(Pending(event: event(.permission, Self.describe(tool: tool, input: input), tool: tool, input: input),
                                respond: reply))
            }
        default:
            reply("{}")
        }
    }

    private static func questions(in input: [String: Any]) -> [AgentEvent.Question] {
        guard let list = input["questions"] as? [[String: Any]] else { return [] }
        return list.compactMap { q in
            guard let text = q["question"] as? String, !text.isEmpty else { return nil }
            let options = (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
            return AgentEvent.Question(text: text, header: q["header"] as? String ?? "",
                                       options: options, multiSelect: q["multiSelect"] as? Bool ?? false)
        }
    }

    /// "run: npm test" / "edit Config.swift" / "use WebFetch" — what the
    /// agent is asking to do, said in a breath.
    private static func describe(tool: String, input: [String: Any]) -> String {
        func short(_ s: String, _ n: Int = 140) -> String {
            let one = s.replacingOccurrences(of: "\n", with: "; ")
            return one.count > n ? String(one.prefix(n)) + "…" : one
        }
        func file(_ k: String) -> String? {
            (input[k] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        }
        /// Codex's shell tool takes its command as argv — ["bash", "-lc",
        /// "npm test"] — where Claude's is one string. Said aloud, it is
        /// the last part that matters.
        func argv(_ v: Any?) -> String? {
            if let s = v as? String { return s }
            guard let parts = v as? [String], !parts.isEmpty else { return nil }
            if parts.count >= 3, ["bash", "sh", "zsh", "/bin/bash", "/bin/sh", "/bin/zsh"].contains(parts[0]),
               parts[1].hasPrefix("-") { return parts.dropFirst(2).joined(separator: " ") }
            return parts.joined(separator: " ")
        }
        /// The command itself, never the agent's description of it: the
        /// description is the agent's own words, and an agent fed a prompt
        /// injection can make anything sound harmless. Too long to say in a
        /// breath, it is left to the screen, where the whole of it shows.
        func command(_ c: String) -> String {
            let one = c.replacingOccurrences(of: "\n", with: "; ")
            return one.count > 140 ? "run a long command. Check the screen for it" : "run: \(one)"
        }
        switch tool {
        // Codex's own names, said the same way Claude's are.
        case "shell", "local_shell", "unified_exec", "exec_command":
            return command(argv(input["command"]) ?? "")
        case "apply_patch", "edit_file":
            return "edit \(file("file_path") ?? file("path") ?? "a file")"
        case "read_file": return "read \(file("file_path") ?? file("path") ?? "a file")"
        case "write_file": return "write \(file("file_path") ?? file("path") ?? "a file")"
        case "update_plan": return "update its plan"
        case "web_search", "search": return "search the web for \(short(input["query"] as? String ?? "", 80))"
        case "Bash":
            return command(argv(input["command"]) ?? "")
        case "Edit", "MultiEdit": return "edit \(file("file_path") ?? "a file")"
        case "Write": return "write \(file("file_path") ?? "a file")"
        case "NotebookEdit": return "edit notebook \(file("notebook_path") ?? "")"
        case "WebFetch": return "fetch \(short(input["url"] as? String ?? "a web page", 80))"
        case "WebSearch": return "search the web for \(short(input["query"] as? String ?? "", 80))"
        case "ExitPlanMode": return "leave plan mode and start on the plan"
        default:
            if let c = argv(input["command"]) { return "use \(tool): \(short(c))" }
            return "use \(tool)"
        }
    }

    /// The last thing the developer typed, from the tail of the transcript:
    /// the final "user" line whose content is text and not a tool result or
    /// a slash command's machinery.
    private static func lastUserPrompt(in path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { h.closeFile() }
        let size = h.seekToEndOfFile()
        let want: UInt64 = 400_000
        h.seek(toFileOffset: size > want ? size - want : 0)
        guard let text = String(data: h.readDataToEndOfFile(), encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() {
            guard line.contains("\"type\":\"user\""),
                  let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  obj["type"] as? String == "user",
                  let msg = obj["message"] as? [String: Any] else { continue }
            var s: String?
            if let c = msg["content"] as? String { s = c }
            else if let parts = msg["content"] as? [[String: Any]] {
                if parts.contains(where: { $0["type"] as? String == "tool_result" }) { continue }
                s = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            }
            guard var t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { continue }
            // "<command-name>…", "<local-command-stdout>…", "<system-reminder>…"
            // are the harness talking, not the developer.
            if t.hasPrefix("<") { continue }
            if let r = t.range(of: "<system-reminder>") { t = String(t[..<r.lowerBound]) }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return nil
    }

    // MARK: Episodes

    private var accountWatch: NSObjectProtocol?

    /// Signed out mid-update: the voice stops and what was waiting goes, the
    /// way enqueue turns away anything new until someone signs in.
    private func hushIfSignedOut() {
        guard Account.required, current != nil || !queue.isEmpty else { return }
        log("signed out — the update in progress and \(queue.count) waiting are dropped")
        queue.forEach { $0.respond?("{}") }
        queue.removeAll()
        if current != nil { finish(reason: "signed out") }
    }

    private func enqueue(_ p: Pending) {
        // Signed out, the app does nothing until someone signs in — and an
        // update then could only speak in the Mac's voice on nobody's
        // account. The hook goes free and the news isn't kept: it belongs
        // to whoever was signed in, not to the next one.
        if Account.required {
            p.respond?("{}")
            return log("signed out — \(p.event.kind) from \(p.event.project) not spoken")
        }
        // Said once. The same news can reach here twice — a rollout watcher
        // and a Stop hook both reporting one finish, or a rate limit
        // written to the transcript on every retry — and it must never
        // become two episodes about one piece of news.
        // A sample says the same words every time on purpose: never a repeat.
        if p.event.kind == .finished || p.event.kind == .needsInput, !p.event.sessionID.isEmpty, !Self.isSample(p.event) {
            let mark = p.event.sessionID + "\u{1}" + String(p.event.message.prefix(160))
            if let at = spokenAlready[mark], Date().timeIntervalSince(at) < 120 {
                p.respond?("{}")
                return log("already said this one — \(p.event.project) [\(p.event.shortID)]")
            }
            spokenAlready[mark] = Date()
            spokenAlready = spokenAlready.filter { Date().timeIntervalSince($0.value) < 300 }
        }
        // Quiet hours: the hook goes free at once, the news is kept for
        // "any updates?", and nothing spawns or speaks.
        if Date() < quietUntil {
            log("muted (quiet hours): \(p.event.kind) from \(p.event.project)")
            p.respond?("{}")
            if !p.event.sessionID.isEmpty, p.event.sessionID != "sample", p.event.sessionID != "sample-q" {
                remember(p.event, line: Self.firstSentences(of: p.event.message))
            }
            return
        }
        // The plan's conversations are used up: the hook goes free at once
        // and the news is kept, the way quiet hours keep it — and the pill
        // says why the voice said nothing.
        if !Self.allowed, !Self.isSample(p.event) {
            log("no agent conversations left — \(p.event.kind) from \(p.event.project) not spoken")
            p.respond?("{}")
            if !p.event.sessionID.isEmpty { remember(p.event, line: Self.firstSentences(of: p.event.message)) }
            nudgeSpent()
            return
        }
        log("\(p.event.kind) from \(p.event.project) [\(p.event.sessionID.prefix(8))]")
        queue.append(p)
        next()
    }

    // MARK: Conversations

    /// The conversation the voice is speaking in, as SayControl's server
    /// knows it: every line spoken and every agent model call carries it,
    /// and the server holds it to a few thousand characters and half an
    /// hour. Each new episode opens one; what is said inside an episode —
    /// a pick from the list, "say that again" — goes on in it. nil on the
    /// developers' own keys.
    private(set) var conversationID: String?
    /// Bumped by every claim, so an answer that comes back after a newer
    /// one was asked for is dropped.
    private var claimTurn = 0

    /// The agent voice is Pro's: every update it reads out, and every reply
    /// it tidies, is a model call and a voice on SayControl's keys. The
    /// server counts conversations — Free's ten, once; Pro's month; then
    /// bought ones — and this is whether one may start, as far as the app
    /// last heard. On the developers' own keys nothing is counted.
    static var allowed: Bool {
        guard Config.shared.agentCloud, let a = Cloud.shared.agent else { return true }
        return a.any
    }

    private static func isSample(_ ev: AgentEvent) -> Bool {
        ev.sessionID == "sample" || ev.sessionID == "sample-q"
    }

    /// Opens a conversation before the voice says a word. On SayControl's
    /// cloud the server counts it and answers its id; `then(false)` means
    /// none was left, and the pill has said so. A server that can't be
    /// reached doesn't silence the voice: it goes on without an id, in the
    /// Mac's own voice.
    private func claim(_ kind: Cloud.AgentKind, then: @escaping (Bool) -> Void) {
        claimTurn += 1
        guard Config.shared.agentCloud else {
            conversationID = nil
            return then(true)
        }
        let turn = claimTurn
        Cloud.shared.startAgentConversation(kind) { [weak self] result in
            guard let self = self, turn == self.claimTurn else { return }
            switch result {
            case .success(let id):
                self.conversationID = id
                then(true)
            case .failure(.limitReached), .failure(.server(429, _)):
                self.log("no \(kind.rawValue) left — said nothing")
                self.nudgeSpent(kind)
                then(false)
            case .failure(let e) where { if case .server(_, "device_unverified") = e { return true }
                                         if case .server(_, "mac_refused") = e { return true }
                                         return false }():
                // Free's voice is held per Mac, and Apple hasn't vouched for
                // this one: going on would only make calls the server refuses.
                self.log("couldn't open a conversation — \(e.localizedDescription)")
                (NSApp.delegate as? AppDelegate)?.hud.show(e.localizedDescription, autohide: 3.5)
                then(false)
            case .failure(let e):
                self.log("couldn't open a conversation — \(e.localizedDescription); going on in the Mac's voice")
                self.conversationID = nil
                then(true)
            }
        }
    }

    private var lastSpentNudge = Date.distantPast
    /// Once a minute at most, so a burst of finishes is one line, not five —
    /// except a sample, which is a button just pressed: every press says why
    /// nothing plays, where a second press used to do nothing at all.
    private func nudgeSpent(_ kind: Cloud.AgentKind = .conversation) {
        guard kind != .line else { return }
        guard kind == .sample || Date().timeIntervalSince(lastSpentNudge) > 60 else { return }
        if kind != .sample { lastSpentNudge = Date() }
        let a = Cloud.shared.agent
        let s: String
        if kind == .sample {
            s = "All 50 of today's samples are used — more tomorrow"
        } else if a?.once ?? !Account.proFeatures {
            s = "Your \(a?.limit ?? 10) free agent conversations are used — the agent voice is Pro’s"
        } else {
            s = "This month’s \(a?.limit ?? 300) agent conversations are used — get more in Agents"
        }
        (NSApp.delegate as? AppDelegate)?.hud.show(s, autohide: 3.5)
    }

    private func next() {
        guard current == nil, !queue.isEmpty else { return }
        // Quiet hours declared while these waited: same release.
        if Date() < quietUntil {
            for p in queue {
                p.respond?("{}")
                if !p.event.sessionID.isEmpty, p.event.sessionID != "sample", p.event.sessionID != "sample-q" {
                    remember(p.event, line: Self.firstSentences(of: p.event.message))
                }
            }
            queue.removeAll()
            return
        }
        // Several finishes waiting? One rundown beats a parade of episodes.
        let finished = queue.filter { $0.respond == nil && $0.event.kind == .finished }
        if finished.count >= 2 {
            queue.removeAll { $0.respond == nil && $0.event.kind == .finished }
            return digest(finished.map { $0.event })
        }
        var p = queue.removeFirst()
        // A prompt that sat in line too long has probably been answered at
        // the keyboard — let the hook go rather than ask about stale news.
        if p.respond != nil, Date().timeIntervalSince(p.event.received) > 30 {
            p.respond?("{}")
            return next()
        }
        current = p
        // A conversation, opened (and counted) before a word is said —
        // "say that again" re-begins it in the same one.
        let received = p.event.received
        claim(Self.isSample(p.event) ? .sample : .conversation) { [weak self] ok in
            guard let self = self, self.current?.event.received == received else { return }
            guard ok else {
                p.respond?("{}")
                if !p.event.sessionID.isEmpty, !Self.isSample(p.event) {
                    self.remember(p.event, line: Self.firstSentences(of: p.event.message))
                }
                self.current = nil
                return self.next()
            }
            self.begin()
        }
    }

    /// Two or more sessions finished while the voice was busy or away: say
    /// them as one piece — name and a line each — and ask which to pick up.
    private func digest(_ events: [AgentEvent]) {
        for ev in events where !ev.sessionID.isEmpty && ev.sessionID != "sample" {
            remember(ev, line: Self.firstSentences(of: ev.message))
        }
        var p = Pending(event: AgentEvent(kind: .finished, sessionID: "", cwd: "", message: "", asked: nil,
                                          toolName: nil, toolInput: [:], questions: [], termProgram: nil,
                                          itermSession: nil, tmuxPane: nil, socket: nil, token: nil))
        p.stage = .pick
        current = p
        // One conversation for the whole rundown.
        let received = p.event.received
        claim(.conversation) { [weak self] ok in
            guard let self = self, self.current?.event.received == received else { return }
            guard ok else {
                self.current = nil
                return self.next()
            }
            self.sayDigest(events)
        }
    }

    private func sayDigest(_ events: [AgentEvent]) {
        let list = liveRecents
        // Displayed bottom-up — row 1, the freshest, lands by the pill and
        // the high numbers are what the panel clips when the list is long.
        let rows = Array(list.prefix(8).enumerated().map { i, r in
            "\(i + 1) · \(name(of: r)) · \(cardTitle(r)) · \(Self.ago(r.when))\n\(Self.firstSentences(of: r.line, limit: 140))"
        }.reversed())
        // Spoken in number order, so "the first one" means what was said first.
        let ids = Set(events.map { $0.sessionID })
        let parts = list.filter { ids.contains($0.sessionID) }
            .map { "\(name(of: $0)): \(Self.firstSentences(of: $0.line, limit: 100))" }
        let s = "\(events.count) agents finished. " + parts.joined(separator: " ") + " Which one?"
        current?.spoken = s
        log("digest of \(events.count) sessions")
        AgentPanel.shared.begin(header: "Agents", saying: "")
        AgentPanel.shared.list(rows)
        AgentPanel.shared.say(s)
        listenAndSpeak(s)
    }

    private func begin() {
        guard let p = current else { return }
        let ev = p.event
        if !ev.sessionID.isEmpty, ev.sessionID != "sample", ev.sessionID != "sample-q" {
            remember(ev, line: ev.kind == .finished ? ev.message : ev.message)
        }
        // Every episode opens with the session's name — the given one if the
        // user named it, the folder otherwise — so it is always said which
        // agent is talking.
        switch ev.kind {
        case .permission:
            open(spoken: ev.risky
                 ? "\(spokenWhoCap(ev)) wants to \(ev.message). That can't be undone, so approve it on the screen, or say deny."
                 : "\(spokenWhoCap(ev)) wants to \(ev.message). Say allow or deny.")
        case .question:
            askQuestion()
        case .needsInput:
            open(spoken: "\(spokenWhoCap(ev)) \(ev.message)")
        case .finished:
            // The update speaks at once — "Your agent on … finished." — while
            // its summary is written, and the summary follows on in the same
            // breath. It used to wait out the summary (~1 s; a stalled model,
            // up to 6) and then the voice's own first audio before a word.
            let opening = "\(spokenWhoCap(ev)) finished."
            current?.spoken = opening
            current?.stage = .answer
            log("says: \(Config.words(opening)) …")
            // The voice is asked for before the card is drawn.
            listenAndSpeak(opening, mood: "excited", more: true)
            beginPanel(for: ev, saying: opening)
            AgentPanel.shared.note("Summarising…")
            let received = ev.received
            // The summary gets three seconds, which the opening mostly covers.
            // Past that (a stalled model has taken six and then failed) the
            // agent's own words are read instead, and a summary that comes in
            // later only names the session in the list.
            var said = false
            let deliver = { [weak self] (line: String) in
                guard let self = self, !said, self.current?.event.received == received else { return }
                said = true
                if !ev.sessionID.isEmpty, ev.sessionID != "sample" { self.remember(ev, line: line) }
                self.current?.spoken = "\(opening) \(line)"
                AgentPanel.shared.extend(line)
                self.log("says: \(Config.words(line))")
                VoiceIO.shared.follow(with: Self.spoken(line))
            }
            // A sample's news is already short and plain: said as written, so it
            // is the same every time and plays from its shipped recording.
            if Self.isSample(ev) { return deliver(ev.message) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self = self, !said, self.current?.event.received == received else { return }
                self.log("summary not back in 3 s — reading the message")
                deliver(Self.firstSentences(of: ev.message))
            }
            Refiner.shared.summarize(project: ev.project, asked: ev.asked, reply: ev.message) { [weak self] r in
                guard let self = self else { return }
                switch r {
                case .success(let s) where said:
                    if !ev.sessionID.isEmpty, ev.sessionID != "sample" { self.remember(ev, line: s) }
                case .success(let s):
                    deliver(s)
                case .failure(let e):
                    guard !said else { return }
                    self.log("summary failed — \(e.localizedDescription); reading the message")
                    deliver(Self.firstSentences(of: ev.message))
                }
            }
        }
    }

    /// One multiple-choice question at a time: the question, then the
    /// options by number.
    private func askQuestion() {
        guard let p = current, p.qIndex < p.event.questions.count else { return }
        let q = p.event.questions[p.qIndex]
        var s = p.qIndex == 0 ? "\(spokenWhoCap(p.event)) asks. " : ""
        s += p.event.questions.count > 1 ? "Question \(p.qIndex + 1) of \(p.event.questions.count). " : ""
        s += q.text
        if !q.options.isEmpty {
            s += " Options: "
            s += q.options.enumerated().map { "\($0.offset + 1), \($0.element)" }.joined(separator: ". ")
            s += q.multiSelect ? ". You can pick more than one, or say something else." : ". Or say something else."
        }
        open(spoken: s, continuing: p.qIndex > 0)
    }

    private static func firstSentences(of s: String, limit: Int = 220) -> String {
        let plain = s.replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "#", with: "")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        return plain.count > limit ? String(plain.prefix(limit)) + "…" : plain
    }

    /// Say it, and listen. The ear opens with the voice (talking over it
    /// cuts it off) and stays open a while after; the dictation key cuts in
    /// too.
    private func open(spoken: String, continuing: Bool = false) {
        current?.spoken = spoken
        current?.stage = .answer
        if continuing { AgentPanel.shared.say(spoken) }
        else if let ev = current?.event { beginPanel(for: ev, saying: spoken) }
        else { AgentPanel.shared.begin(header: "", saying: spoken) }
        log("says: \(Config.words(spoken))")
        let mood: String?
        switch current?.event.kind {
        case .finished: mood = "excited"
        case .permission, .question, .needsInput: mood = "curious"
        default: mood = nil
        }
        listenAndSpeak(spoken, mood: mood)
    }

    /// Say it, then listen. Half-duplex: the ear opens only once the voice
    /// has finished and the room is quiet again, because there is no echo
    /// cancelling (it breaks dictation) and an open mic would otherwise hear
    /// the voice itself. The dictation key still cuts in WHILE it speaks.
    private func listenAndSpeak(_ line: String, silenceAfter: TimeInterval = 2.0, mood: String? = nil, more: Bool = false) {
        app?.playSound("SayCtrlMatch")
        hotkeyArmedUntil = .distantPast
        replyTimer?.invalidate()
        let io = VoiceIO.shared
        let t0 = Date()
        io.speak(Self.spoken(line), mood: mood, more: more, onProgress: { AgentPanel.shared.progress($0) }) { [weak self] cut in
            guard let self = self, self.current != nil, !self.keyTookOver else { return }
            self.log("\(cut ? "cut off" : "spoke") after \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
            AgentPanel.shared.revealAll()
            guard Config.shared.agentOpenMic else {
                // No hands-free: the key answers, for a while.
                AgentPanel.shared.note("Hold the key to reply")
                self.hotkeyArmedUntil = Date().addingTimeInterval(25)
                self.armReplyTimer(25)
                return
            }
            // A short beat so the speaker's tail isn't taken for the user,
            // then open the ear on a now-quiet room.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.openEar(silenceAfter: silenceAfter)
            }
        }
    }

    /// Take the reply with the SAME dictation the key drives — same models,
    /// same pill, same history entry and saved clip, so every exchange can
    /// be replayed from the Overview. The ear only times it: its VAD says
    /// when talking started and stopped; the words come back through
    /// takeReply like any other dictation.
    private func openEar(silenceAfter: TimeInterval) {
        let io = VoiceIO.shared
        guard current != nil, !keyTookOver, !io.speaking else { return }
        // Set before the capture starts, so the recording pipeline can
        // already tell this take is the agent's (see capturingReply) and
        // route the live preview into the chat instead of the speech card.
        agentCapture = true
        liveReply = ""
        liveReplyGrewAt = .distantPast
        settleTimer?.invalidate()
        settleTimer = nil
        guard let app = app, app.beginAgentCapture() else {
            agentCapture = false
            AgentPanel.shared.note("Hold the key to reply")
            hotkeyArmedUntil = Date().addingTimeInterval(25)
            armReplyTimer(25)
            return
        }
        let ok = io.listen(startWithin: 12, silenceAfter: silenceAfter, maxSeconds: 30,
                           onSpeech: { AgentPanel.shared.listening(true) },
                           completion: { [weak self] samples in self?.earEndpoint(heardSpeech: samples != nil) })
        if ok {
            // The card absorbs the pill: bars and timer in its foot, the
            // pill itself invisible for the duration.
            AgentPanel.shared.listening(true)
            app.concealPill(true)
        } else {
            // No ear to time the reply: give the mic back to the key.
            agentCapture = false
            app.endAgentCapture(discard: true)
            AgentPanel.shared.note("Mic didn't open — hold the key to reply")
            hotkeyArmedUntil = Date().addingTimeInterval(25)
            armReplyTimer(25)
        }
    }

    /// The ear's verdict on the running capture: talking ended (stop the
    /// dictation and let its transcript come back through takeReply), or
    /// nobody spoke (throw the take away and close the episode).
    private func earEndpoint(heardSpeech: Bool) {
        guard current != nil, agentCapture else { return }
        settleTimer?.invalidate()
        settleTimer = nil
        // The ear's "nobody spoke" is overruled by words in the preview —
        // the VAD missing a quick, quiet answer must not throw it away.
        if heardSpeech || !liveReply.isEmpty {
            if !heardSpeech { log("ear heard nothing, but the transcript has words — taking them") }
            AgentPanel.shared.footStatus("…")
            armReplyTimer(60)   // a wedge in transcription must not hang the episode
            app?.endAgentCapture(discard: false)
        } else {
            // The key may have already stopped the take — the transcript is
            // on its way; touch nothing.
            guard app?.state == .recording else { return }
            agentCapture = false
            app?.endAgentCapture(discard: true)
            AgentPanel.shared.listening(false)
            app?.concealPill(false)
            if current?.stage == .more { return compose() }   // quiet after "anything else?" means no
            finish(reason: "nothing said")
        }
    }

    /// Every partial from the reply capture's live transcription lands
    /// here (see the recording pipeline's onText). Words growing is the
    /// real signal that someone is answering; words gone quiet for
    /// `settleQuiet` is the real signal they are done — the ear only
    /// times the take, it no longer gets to starve it.
    func liveHeard(_ text: String) {
        guard Thread.isMainThread else { return DispatchQueue.main.async { self.liveHeard(text) } }
        guard current != nil, agentCapture, !keyTookOver else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if t != liveReply {
            liveReply = t
            liveReplyGrewAt = Date()
        }
        guard settleTimer == nil else { return }
        settleTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.settleTick()
        }
    }

    /// The transcript has words and they have stopped coming: accept the
    /// reply now instead of waiting out the ear — which, for a short
    /// answer it never opened a take for, would discard everything at
    /// the deadline.
    private func settleTick() {
        guard current != nil, agentCapture, !keyTookOver, app?.state == .recording,
              !liveReply.isEmpty else {
            settleTimer?.invalidate()
            settleTimer = nil
            return
        }
        guard Date().timeIntervalSince(liveReplyGrewAt) >= settleQuiet else { return }
        settleTimer?.invalidate()
        settleTimer = nil
        log("reply settled — no new words for \(Int(settleQuiet)) s; taking “\(Config.words(liveReply, upTo: 60))…”")
        VoiceIO.shared.abandonListening()
        AgentPanel.shared.footStatus("…")
        armReplyTimer(60)
        app?.endAgentCapture(discard: false)
    }

    /// The dictation the bridge was waiting on produced nothing — an empty
    /// transcript, a too-short take, a failed request. True means it was the
    /// bridge's capture and the screen should stay quiet about it. The first
    /// empty take gets one more listen — a false start must not end the
    /// exchange — and quiet after "anything else?" just means no.
    func captureFailed() -> Bool {
        guard let p = current, agentCapture else { return false }
        agentCapture = false
        replyTimer?.invalidate()
        VoiceIO.shared.stopAll()
        AgentPanel.shared.listening(false)
        app?.concealPill(false)
        if p.stage == .more, !p.reply.isEmpty { compose(); return true }
        if p.earRetries == 0 {
            current?.earRetries = 1
            log("empty take — listening again")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.openEar(silenceAfter: 2.0)
            }
            return true
        }
        finish(reason: "nothing heard")
        return true
    }

    // MARK: The dictation key

    /// Called on the key going down. True means the bridge took it: the
    /// voice stops, the ear closes, and the dictation that follows is the
    /// reply.
    func hotkeyInterrupt() -> Bool {
        guard current != nil,
              VoiceIO.shared.speaking || VoiceIO.shared.listening || Date() < hotkeyArmedUntil else { return false }
        log("cut in by key")
        keyTookOver = true
        VoiceIO.shared.stopAll()
        AgentPanel.shared.revealAll()
        AgentPanel.shared.listening(true, label: "Listening (key)…")
        app?.concealPill(true)
        armReplyTimer(60)
        return true
    }

    /// A finished dictation that belongs to the episode — the key cut in, or
    /// the bridge started the capture itself. False leaves the words to the
    /// normal paste pipeline.
    func takeReply(_ text: String) -> Bool {
        guard current != nil, keyTookOver || agentCapture else { return false }
        let how = keyTookOver ? "key" : "mic"
        keyTookOver = false
        agentCapture = false
        current?.earRetries = 0   // a heard reply earns the next round its own retry
        replyTimer?.invalidate()
        VoiceIO.shared.stopAll()
        app?.concealPill(false)
        log("heard (\(how)): \(Config.words(text))")
        AgentPanel.shared.heard(text)
        captureShots(in: text) { [weak self] words in self?.interpret(words) }
        return true
    }

    /// "Take a screenshot" said in a reply: the picture is ours to take —
    /// the words alone would only tell the agent to photograph its own
    /// blindness. Adopt the shot the live stream already grabbed at the
    /// phrase (that moment is what the user meant), or capture now; save
    /// it as a file, remember the path for deliver(), and hand the words
    /// back with the command excised. No command, or no permission: the
    /// text passes through untouched.
    private func captureShots(in text: String, then: @escaping (String) -> Void) {
        // Only a reply that travels as text can carry a picture — a
        // permission or a multiple-choice answer goes back as hook JSON.
        guard let app = app, let kind = current?.event.kind, kind == .finished || kind == .needsInput
        else { return then(text) }
        let segments = Commands.segmentScreenshots(text)
        guard CGPreflightScreenCaptureAccess() else {
            if segments != nil {
                app.hud.show("⚠️ Grant Screen Recording to SayControl for screenshots", autohide: 3)
                CGRequestScreenCaptureAccess()   // one-time system prompt
            }
            return then(text)   // keep the spoken words — they still say what was wanted
        }
        app.shotCaptureGroup.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            // The live stream grabs the screen the moment the phrase goes
            // by, and the HUD announces it. A shot the user watched happen
            // must not vanish because the final parse read the phrase as a
            // mention ("I said take a screenshot") — anything waiting in
            // pendingShots belongs to this take and rides along either way.
            let ready = app.pendingShots
            app.pendingShots.removeAll()
            if segments == nil && ready.isEmpty { return then(text) }   // no command, nothing captured
            let words: String
            if let segments = segments {
                let joined = Commands.joinSpoken(segments)
                // Words for the message even when the utterance was only the command.
                words = joined.isEmpty ? "Here's a screenshot of my screen." : joined
            } else {
                words = text   // a mention — the sentence stands, the shot rides along
            }
            func finish(_ pngs: [Data]) {
                var attached = 0
                for png in pngs {
                    if let url = app.saveShotForTerminal(png) {
                        self.current?.shotPaths.append(url.path)
                        attached += 1
                        self.log("screenshot for the reply: \(Config.detail(url.path))")
                    }
                }
                app.hud.show(attached > 0 ? "Screenshot attached to the reply" : "⚠️ Screenshot failed",
                             autohide: attached > 0 ? 1.6 : 2.5)
                then(words)
            }
            if !ready.isEmpty { return finish(ready) }
            AgentPanel.shared.concealed(true)   // the card must not photobomb
            app.captureCursorScreenAsync { png in
                AgentPanel.shared.concealed(false)
                finish(png.map { [$0] } ?? [])
            }
        }
    }

    private func armReplyTimer(_ seconds: TimeInterval) {
        replyTimer?.invalidate()
        replyTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self = self, self.current != nil else { return }
            if self.current?.stage == .more, !(self.current?.reply.isEmpty ?? true) { return self.compose() }
            self.finish(reason: "no reply in time")
        }
    }

    // MARK: What the reply means

    private static let yes = ["yes", "yeah", "yep", "yup", "sure", "allow", "allow it", "approve",
                              "approved", "go ahead", "go for it", "do it", "okay", "ok", "fine",
                              "yes please", "allowed", "confirm", "proceed", "continue"]
    private static let no = ["no", "nope", "deny", "denied", "don't", "do not", "stop", "reject",
                             "block", "no way", "not now", "cancel that", "refuse"]
    private static let dismiss = ["skip", "ignore", "dismiss", "never mind", "nevermind", "cancel",
                                  "thanks", "thank you", "got it", "okay thanks", "ok thanks",
                                  "noted", "fine", "good", "great", "cool", "nice", "alright", "all right",
                                  "okay", "ok", "yes", "yeah", "sure"]
    private static let again = ["again", "repeat", "say that again", "read it again", "what", "pardon",
                                "say again", "repeat that", "once more", "what did you say"]
    private static let show = ["show me", "open it", "show it", "go there", "switch to it", "bring it up"]
    private static let farewell = ["stop", "that's all", "thats all", "that is all", "that's it", "thats it",
                                   "that's all for now", "goodbye", "good bye", "bye", "bye bye", "we're done",
                                   "were done", "we are done", "i'm done", "im done", "i am done", "no more",
                                   "nothing else", "nothing more", "quit", "exit", "shut up", "enough", "go away",
                                   "leave it", "that's everything", "thats everything", "okay that's all",
                                   "okay bye", "ok bye", "cancel it", "never mind all this"]
    private static let done = ["no", "nope", "no that's it", "that's it", "that's all", "thats all", "that is all",
                               "nothing", "nothing else", "no thanks", "send it", "send", "that's everything",
                               "done", "i'm done", "im done", "go", "go ahead", "no send it", "that's fine", "no that's all"]

    private static func bare(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "'" }
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// "No.", "Nope, nothing else.", "No that's it, send it." — a no in the
    /// first breath, or any of the done phrases anywhere.
    private static func isDone(_ b: String) -> Bool {
        if done.contains(b) || isFarewell(b) { return true }
        let words = b.split(separator: " ").map(String.init)
        if let first = words.first, ["no", "nope", "nah", "nothing", "none"].contains(first), words.count <= 5 { return true }
        return ["that's all", "thats all", "that's it", "thats it", "nothing else", "send it", "i'm done",
                "im done", "that's everything", "all for now", "that is all", "that is it"].contains { b.contains($0) }
    }

    private static func isFarewell(_ b: String) -> Bool {
        if farewell.contains(b) { return true }
        return ["goodbye", "good bye", "bye bye", "that's all for now", "thats all for now", "stop listening",
                "go away", "shut up", "that's enough", "thats enough", "all for now", "we're done", "were done"]
            .contains { b.contains($0) }
    }

    private func interpret(_ text: String) {
        guard let p = current else { return }
        let b = Self.bare(text)
        let words = b.split(separator: " ").count
        if Self.again.contains(b) {
            // Replay what was said rather than rebuild it — a digest or a
            // question list has no single event to begin() from.
            if !p.spoken.isEmpty {
                AgentPanel.shared.say(p.spoken)
                return listenAndSpeak(p.spoken)
            }
            return begin()
        }
        // "Call it the billing fix" — name the session on deck, then carry on
        // where the episode was.
        if !p.event.sessionID.isEmpty, let n = Self.nameCommand(text) {
            setName(n, for: p.event.sessionID)
            log("named [\(p.event.sessionID.prefix(8))]: \(Config.words(n))")
            AgentPanel.shared.say("Okay — \(n).")
            return listenAndSpeak("Okay — \(n).")
        }
        // The new-session walk: which folder, what to build, the final go.
        // Handled before the farewell check — here "stop" means cancel,
        // never "send what we have".
        if p.stage == .projectPick || p.stage == .brief || p.stage == .confirmLaunch {
            if Self.no.contains(b) || b.contains("cancel") || Self.isFarewell(b) {
                return say("Okay.") { self.finish(reason: "cancelled") }
            }
            switch p.stage {
            case .projectPick:
                return matchProject(text)
            case .brief:
                guard let dir = p.projectDir else { return finish(reason: "lost the folder") }
                current?.reply = [text]
                current?.stage = .confirmLaunch
                let who = p.event.agent
                let place = chosenHost() == .desktopApp ? "the \(who.display) app" : "the terminal"
                let s = "Starting \(who.spoken) in \(Self.spoken(dir.lastPathComponent)), in \(place) — go?"
                AgentPanel.shared.say(s)
                return listenAndSpeak(s, silenceAfter: 2.0)
            case .confirmLaunch:
                guard let dir = p.projectDir else { return finish(reason: "lost the folder") }
                if Self.yes.contains(b) || b.hasPrefix("go") || b.hasPrefix("yes") {
                    return launchSession(in: dir, brief: p.reply.joined(separator: " "))
                }
                return say("Okay, cancelled.") { self.finish(reason: "cancelled") }
            default: break
            }
        }
        // The watchdog's question — a yes sends a canned status ask into
        // the session, a no leaves it working, and anything longer is
        // taken as words for the session itself.
        if p.stage == .checkStuck {
            current?.stage = .answer
            // Yes before the dismiss words — "okay" answering "want me to
            // check on it?" means check, not never-mind.
            if Self.yes.contains(b) || b.contains("check") || b.contains("status") {
                return deliver("Quick status check — what are you on right now, and are you stuck on anything? A brief reply is fine.",
                               to: p.event)
            }
            if Self.no.contains(b) || Self.dismiss.contains(b) || Self.isFarewell(b) {
                return say("Okay.") { self.finish(reason: "left it working") }
            }
            return route(reply: text)
        }
        // The spoken controls also work mid-conversation — but never on a
        // permission or a question, where a hook is waiting for its answer.
        if p.event.kind == .finished || p.event.kind == .needsInput {
            if let secs = Self.quietCommand(b) {
                log("reply is a quiet-hours command")
                return startQuiet(secs)
            }
            if let msg = Self.broadcastCommand(b) {
                log("reply is a broadcast — handing over")
                return broadcast(msg)
            }
            if ["what did it change", "what changed", "what did you change", "what has changed",
                "show me the diff", "show the diff", "what did it actually change"].contains(b) {
                return showChanges()
            }
        }
        // "Start a new claude session on X" said mid-conversation is a
        // command to SayCtrl, not words for the agent — the episode hands
        // over to the create flow. Not on a permission or a question:
        // those hold a hook waiting for a specific answer.
        if p.event.kind == .finished || p.event.kind == .needsInput,
           let (frag, host, agent) = Self.newSessionFragment(b) {
            log("reply is a new-session command — handing over")
            finishQuietly()
            return startCreate(fragment: frag, host: host, agent: agent)
        }
        // A goodbye ends the whole episode, wherever it is — but not on a
        // permission, where "stop" means deny.
        if p.event.kind != .permission, Self.isFarewell(b) {
            // Words already given go out; a bare goodbye just ends it.
            if !p.reply.isEmpty { return compose() }
            return say("Okay.") { self.finish(reason: "goodbye") }
        }
        if p.stage == .pick {
            // "the second one", "two", a name, the folder, "the last one" —
            // or "read the last message" to hear a session's message whole.
            // The same live list the cards were dealt from, so the numbers
            // still point where they pointed.
            let list = liveRecents
            var pick: Recent?
            if list.count == 1, Self.yes.contains(b) { pick = list[0] }
            if pick == nil, let n = Commands.pickReply(b)?.n ?? Self.smallNumber(b), n >= 1, n <= list.count { pick = list[n - 1] }
            if pick == nil { pick = list.first { self.matches(b, $0) } }
            let wantsRead = ["what did it say", "what did they say", "what did the agent say",
                             "last message", "last conversation", "read the", "read me", "read it",
                             "give me the last", "what was the last", "full message", "whole message",
                             "the message"].contains { b.contains($0) }
            if wantsRead, let r = pick ?? list.first { return readBack(r) }
            if pick == nil, ["last one", "latest", "newest", "most recent", "last session", "the last"]
                .contains(where: { b.contains($0) }) { pick = list.first }
            guard let r = pick else {
                // The letter of it missed — the polish model gets one read
                // before the re-ask: "the say control one" names a folder,
                // not a row number.
                return fuzzyPick(b, from: list)
            }
            return resume(r)
        }
        if Self.show.contains(b) {
            activateHost(for: p.event) { _ in }
            return finish(reason: "shown")
        }
        switch p.event.kind {
        case .permission:
            // Only the word "allow" approves: a stray "yes" or "sure" from
            // the open mic, said to someone else, must never run a command.
            if b == "allow" || b.hasPrefix("allow ") {
                // What can't be undone is the screen's to approve, never the
                // voice's (Shell.isRisky).
                if p.event.risky {
                    log("permission left to the screen — a command that can't be undone")
                    return say("That one can't be undone, so it's yours to approve on the screen.") {
                        self.finish(reason: "left to the screen")
                    }
                }
                respond("{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"allow\"}}}")
                log("permission allowed by voice")
                return say("Allowed.") { self.finish(reason: "allowed") }
            }
            if Self.no.contains(b) || b.hasPrefix("no ") || b.hasPrefix("deny ") || b.hasPrefix("don't ") {
                respond("{\"hookSpecificOutput\":{\"hookEventName\":\"PermissionRequest\",\"decision\":{\"behavior\":\"deny\",\"message\":\"Denied by voice through SayControl\"}}}")
                log("permission denied by voice")
                return say("Denied.") { self.finish(reason: "denied") }
            }
            if ["skip", "ignore", "dismiss", "never mind", "nevermind", "cancel"].contains(b) || words <= 1 {
                return finish(reason: "left to the screen")
            }
            return say(p.event.risky ? "Approve it on the screen, or say deny." : "Say allow or deny.") { [weak self] in
                guard let self = self, self.current != nil else { return }
                self.open(spoken: p.spoken, continuing: true)
            }
        case .question:
            if ["skip", "ignore", "dismiss", "never mind", "nevermind", "cancel"].contains(b) {
                return finish(reason: "left to the screen")
            }
            let q = p.event.questions[p.qIndex]
            let answer = Self.matchOption(text, options: q.options, multi: q.multiSelect)
            current?.answers[q.text] = answer
            current?.qIndex += 1
            log("answer \(p.qIndex + 1): \(Config.words(answer))")
            if (current?.qIndex ?? 0) < p.event.questions.count {
                return say("Okay.") { [weak self] in self?.askQuestion() }
            }
            return answerQuestions()
        case .finished, .needsInput:
            switch p.stage {
            case .answer:
                if Self.dismiss.contains(b) || words == 0 { return finish(reason: "dismissed") }
                if words == 1 && b.count < 5 { return finish(reason: "one short word") }
                return route(reply: text)
            case .more:
                if Self.isDone(b) { return compose() }
                if Self.yes.contains(b) {
                    current?.stage = .answer
                    AgentPanel.shared.say("Go ahead.")
                    return listenAndSpeak("Go ahead.", silenceAfter: 2.0)
                }
                return route(reply: text)
            case .pick:
                return finish(reason: "stray pick")
            case .projectPick, .brief, .confirmLaunch, .checkStuck:
                // Handled before the kind switch; reaching here is a stray.
                return finish(reason: "stray stage")
            }
        }
    }

    /// Who was that for? The user is either talking THROUGH SayCtrl (the
    /// words are a message for the session) or TO it, about the
    /// conversation itself — "drop that", "show me the other agents". No
    /// phrasebook can tell "drop it" from "drop the users table", so the
    /// model reads the whole utterance (Refiner.replyIntent) — biased
    /// toward message, and falling back to message on any failure, so
    /// this layer can only ever misfire toward what the app did before.
    private func route(reply text: String) {
        Refiner.shared.replyIntent(text) { [weak self] intent in
            DispatchQueue.main.async {
                guard let self = self, let p = self.current else { return }
                switch intent {
                case .message:
                    self.accept(reply: text)
                case .drop:
                    self.log("intent: drop — nothing goes out")
                    self.current?.reply = []
                    self.say("Dropped.") { self.finish(reason: "dropped") }
                case .list:
                    self.log("intent: list — handing over to the session list")
                    self.showSessionList()
                case .changes:
                    self.log("intent: changes — reading the diff")
                    self.showChanges()
                case .goodbye:
                    if !p.reply.isEmpty { return self.compose() }
                    self.say("Okay.") { self.finish(reason: "goodbye") }
                }
            }
        }
    }

    /// The words are for the agent. "Anything else?" is asked once; a
    /// second answer goes out with the first.
    private func accept(reply text: String) {
        guard current != nil else { return }
        current?.reply.append(text)
        current?.rounds += 1
        if current?.stage == .more || (current?.rounds ?? 0) >= 2 { return compose() }
        current?.stage = .more
        AgentPanel.shared.say("Anything else?")
        listenAndSpeak("Anything else?", silenceAfter: 2.0)
    }

    private static func smallNumber(_ b: String) -> Int? {
        let nums = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "1": 1, "2": 2, "3": 3, "4": 4, "5": 5,
                    "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5]
        for w in b.split(separator: " ") { if let n = nums[String(w)] { return n } }
        return nil
    }

    /// "the second one", "two", "number 3", the option's own words, or —
    /// none of those — the words themselves as a custom answer.
    private static func matchOption(_ text: String, options: [String], multi: Bool) -> String {
        let b = bare(text)
        func ordinal(_ s: String) -> Int? {
            if let n = Commands.pickReply(s)?.n { return n }
            let nums = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "1": 1, "2": 2, "3": 3, "4": 4, "5": 5,
                        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5]
            let w = s.split(separator: " ").map(String.init)
            for (i, x) in w.enumerated() {
                if let n = nums[x], (w.count <= 3 || (i > 0 && ["number", "option"].contains(w[i - 1]))) { return n }
            }
            return nil
        }
        func byLabel(_ s: String) -> String? {
            let sw = Set(s.split(separator: " ").map(String.init))
            var best: (String, Double)?
            for o in options {
                let ob = bare(o)
                if !ob.isEmpty && (s.contains(ob) || ob.contains(s)) { return o }
                let ow = Set(ob.split(separator: " ").map(String.init))
                guard !ow.isEmpty else { continue }
                let score = Double(ow.intersection(sw).count) / Double(ow.count)
                if score >= 0.6, score > (best?.1 ?? 0) { best = (o, score) }
            }
            return best?.0
        }
        let parts = multi ? b.replacingOccurrences(of: " and ", with: ",").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } : [b]
        var picks: [String] = []
        for part in parts where !part.isEmpty {
            if let n = ordinal(part), n >= 1, n <= options.count { picks.append(options[n - 1]); continue }
            if let o = byLabel(part) { picks.append(o); continue }
        }
        if picks.isEmpty { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return picks.joined(separator: ", ")
    }

    /// Claude only, and it has to stay that way: the answers ride back as
    /// an `updatedInput` on the permission decision, and Codex fails a
    /// PermissionRequest CLOSED the moment that field appears (its own
    /// schema calls it reserved). Nothing routes here from Codex today —
    /// AskUserQuestion is Claude's tool — but anything that wires a Codex
    /// question up must find another way home.
    private func answerQuestions() {
        guard let p = current else { return }
        var input = p.event.toolInput
        input["answers"] = p.answers
        let out: [String: Any] = ["hookSpecificOutput": [
            "hookEventName": "PermissionRequest",
            "decision": ["behavior": "allow", "updatedInput": input],
        ]]
        if let data = try? JSONSerialization.data(withJSONObject: out), let s = String(data: data, encoding: .utf8) {
            respond(s)
            log("questions answered by voice: \(Config.words("\(p.answers)"))")
            say("Sent.") { [weak self] in self?.finish(reason: "answered") }
        } else {
            finish(reason: "couldn't encode the answers")
        }
    }

    /// The rounds of reply, tidied by the LLM and handed to the agent.
    private func compose() {
        guard let p = current, !p.reply.isEmpty else { return finish(reason: "nothing to send") }
        let spoken = p.reply.joined(separator: " ")
        AgentPanel.shared.footStatus("Sending…")
        // The send is not a lockout: the key stays armed all the way
        // through "Sent.", so the user can cut in with more words for the
        // same session while the last ones are still travelling.
        hotkeyArmedUntil = Date().addingTimeInterval(45)
        Refiner.shared.relay(spoken) { [weak self] r in
            guard let self = self, self.current != nil else { return }
            let text: String
            switch r {
            case .success(let s): text = s
            case .failure(let e):
                self.log("relay failed — \(e.localizedDescription); sending as heard")
                text = spoken
            }
            self.deliver(text, to: p.event)
        }
    }

    private func respond(_ json: String) {
        current?.respond?(json)
        current?.respond = nil
    }

    private func say(_ s: String, tick: Bool = false, then: @escaping () -> Void) {
        AgentPanel.shared.say(s, tick: tick)
        VoiceIO.shared.speak(s, onProgress: { AgentPanel.shared.progress($0) }) { _ in then() }
    }

    private func finish(reason: String) {
        log("episode over — \(reason)")
        respond("{}")
        current = nil
        hotkeyArmedUntil = .distantPast
        keyTookOver = false
        if agentCapture { agentCapture = false; app?.endAgentCapture(discard: true) }
        app?.concealPill(false)
        replyTimer?.invalidate()
        VoiceIO.shared.stopAll()
        AgentPanel.shared.revealAll()
        // One second, not five: the last word has been spoken and shown —
        // a card that lingers reads as something still waiting on you.
        AgentPanel.shared.dismiss(after: 1)
        // Give the room a beat before the next one speaks.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.next() }
    }

    // MARK: Carrying the reply back

    /// The next prompt, into the session. tmux and iTerm take it by address
    /// with nothing on screen moving; everything else gets the window
    /// brought forward, the words pasted and sent, and the previous window
    /// brought back.
    private func deliver(_ text: String, to ev: AgentEvent) {
        var line = text.replacingOccurrences(of: "\n", with: " ")
        // Screenshots taken during the reply ride along as files — the
        // path is the one form every route (socket, tmux, paste) carries,
        // and the agent on the other end opens it from there.
        if let shots = current?.shotPaths, !shots.isEmpty {
            let refs = shots.map { "screenshot of my screen: \($0)" }.joined(separator: "; ")
            line += " (\(refs) — open it)"
        }
        AgentPanel.shared.note("→ \(line)")
        log("reply to \(ev.project): \(Config.words(line))")
        // Codex has no inbox socket, but it has something as quiet: the
        // queue puts the words on the thread through its own daemon, with
        // no window brought forward and nothing typed on screen. A thread
        // the daemon has lost falls through to the terminal routes below.
        if ev.agent == .codex {
            if Codex.queue(thread: ev.sessionID, message: line) {
                log("delivered through the codex queue")
                return sent(ev)
            }
            log("codex queue refused; falling back")
        }
        if let sock = ev.socket, FileManager.default.fileExists(atPath: sock) {
            let me = Account.name.split(separator: " ").first.map(String.init) ?? "The user"
            if Self.inboxSend(socket: sock, token: ev.token, text: "\(me) says, by voice through SayControl: \(line)") {
                log("delivered through the session's inbox socket")
                return sent(ev)
            }
            log("inbox socket refused; falling back")
        }
        if let pane = ev.tmuxPane, let tmux = Self.which("tmux") {
            let ok = Self.run(tmux, ["send-keys", "-t", pane, "-l", line]) && Self.run(tmux, ["send-keys", "-t", pane, "Enter"])
            if ok { return sent(ev) }
            log("tmux send-keys failed; falling back to the window")
        }
        if let sid = ev.itermSession, Self.itermWrite(session: sid, text: line) { return sent(ev) }
        let previous = NSWorkspace.shared.frontmostApplication
        activateHost(for: ev) { [weak self] ok in
            guard let self = self, let app = self.app else { return }
            guard ok else {
                let pb = NSPasteboard.general
                pb.clearContents(); pb.setString(line, forType: .string)
                app.hud.show("Couldn't bring the agent forward — your reply is on the clipboard", autohide: 4)
                app.playSound("SayCtrlMiss")
                return self.finish(reason: "no window")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                app.sendAfterPaste = true
                app.pasteText(line, learn: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                    if let prev = previous, prev.bundleIdentifier != NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                       prev.bundleIdentifier != Config.bundleID {
                        prev.activate(options: [])
                    }
                    self.sent(ev)
                }
            }
        }
    }

    private func sent(_ ev: AgentEvent) {
        // The watchdog's clock starts: a message went in, nothing back yet.
        if !ev.sessionID.isEmpty { workingSince[ev.sessionID] = Date() }
        // The reply is away: clean slate, so words that follow — the user
        // cut in during the send, or right through "Sent." — make a fresh
        // message to the same session instead of re-sending the old one.
        current?.reply = []
        current?.rounds = 0
        current?.stage = .answer
        // Already cut in: the mic has the room — show the tick, skip the
        // voice, and leave the episode open for the words on their way.
        // say() drops the listening strip, so it is put back.
        if keyTookOver {
            AgentPanel.shared.say("Sent.", tick: true)
            AgentPanel.shared.listening(true, label: "Listening (key)…")
            return
        }
        say("Sent.", tick: true) { [weak self] in
            guard let self = self, !self.keyTookOver else { return }
            self.finish(reason: "replied")
        }
    }

    /// Bring the app the session lives in to the front.
    private func activateHost(for ev: AgentEvent, _ done: @escaping (Bool) -> Void) {
        // A Codex session in the desktop app can be opened by name rather
        // than merely raised: codex://threads/<id> lands on that thread.
        // Only when no terminal was forwarded — a session in a terminal
        // window belongs to that window.
        if ev.agent == .codex, ev.termProgram == nil, !ev.sessionID.isEmpty,
           let url = URL(string: "codex://threads/\(ev.sessionID)"), NSWorkspace.shared.open(url) {
            log("opened codex://threads/\(ev.sessionID.prefix(8))")
            return DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { done(true) }
        }
        let ids = Self.hostBundleIDs(for: ev.termProgram, agent: ev.agent)
        guard let running = ids.lazy.compactMap({ NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }).first else {
            log("no running host for \(ev.termProgram ?? "Claude app") among \(ids)")
            return done(false)
        }
        running.activate(options: [.activateIgnoringOtherApps])
        let deadline = Date().addingTimeInterval(4)
        func wait() {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == running.processIdentifier { return done(true) }
            guard Date() < deadline else { return done(false) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: wait)
        }
        wait()
    }

    /// TERM_PROGRAM → the app. Nothing forwarded means the session is in
    /// the agent's own desktop app — Claude's, or the ChatGPT app that
    /// Codex ships inside.
    private static func hostBundleIDs(for term: String?, agent: AgentKind = .claude) -> [String] {
        let desktop = agent == .codex ? ["com.openai.codex", "com.openai.chat"]
                                      : ["com.anthropic.claudefordesktop", "com.anthropic.claude"]
        switch (term ?? "").lowercased() {
        case "": return desktop
        case "apple_terminal": return ["com.apple.Terminal"]
        case "iterm.app": return ["com.googlecode.iterm2"]
        case "warpterminal": return ["dev.warp.Warp-Stable", "dev.warp.Warp"]
        case "ghostty": return ["com.mitchellh.ghostty"]
        case "wezterm": return ["com.github.wez.wezterm"]
        case "alacritty": return ["org.alacritty"]
        case "kitty": return ["net.kovidgoyal.kitty"]
        case "hyper": return ["co.zeit.hyper"]
        case "vscode": return ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "com.microsoft.VSCodeInsiders"]
        case "tmux": return ["com.googlecode.iterm2", "com.apple.Terminal", "dev.warp.Warp-Stable", "com.mitchellh.ghostty"]
        // A Codex session the watcher found running in a terminal, with no
        // TERM_PROGRAM to say which one: the usual suspects, in order.
        case "codex_cli": return ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty",
                                  "dev.warp.Warp-Stable"]
        default: return desktop + ["com.apple.Terminal"]
        }
    }

    /// Claude Code's per-session inbox: newline-delimited JSON on a Unix
    /// socket — an auth line with the session's token, then the message.
    /// With the token the session takes it as its own child's message and
    /// acts on it; without, a bypass-permissions session would hold it.
    private static func inboxSend(socket path: String, token: String?, text: String) -> Bool {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sa_family_t>.size + MemoryLayout<UInt8>.size + bytes.count + 1)
        let ok = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, len) == 0 }
        }
        guard ok else { return false }
        var lines: [[String: Any]] = []
        if let token = token, !token.isEmpty { lines.append(["type": "auth", "token": token]) }
        lines.append(["type": "user", "message": ["role": "user", "content": text]])
        var out = Data()
        for l in lines {
            guard let d = try? JSONSerialization.data(withJSONObject: l) else { return false }
            out.append(d); out.append(0x0A)
        }
        var sentAll = true
        out.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { sentAll = false; break }
                off += n
            }
        }
        // Give the session a moment to read before the close.
        if sentAll { usleep(150_000) }
        return sentAll
    }

    // MARK: What did it change

    /// The session's work read off its git tree: the uncommitted diff
    /// first (that is what an agent mid-task has), the freshest commit
    /// when the tree is clean. Returns the stat lines for the card and a
    /// short line for the ear, or nil when there is nothing to show.
    private static func gitChanges(cwd: String) -> (detail: [String], spoken: String)? {
        guard !cwd.isEmpty, FileManager.default.fileExists(atPath: cwd) else { return nil }
        func git(_ args: [String]) -> String? { capture("/usr/bin/git", ["-C", cwd] + args) }
        var scope = "uncommitted"
        var lines = (git(["diff", "--stat", "HEAD"]) ?? "")
            .split(separator: "\n").map { String($0.trimmingCharacters(in: .whitespaces)) }
        if lines.isEmpty {
            // A clean tree: the last commit, if it is fresh enough to be
            // this sitting's work.
            if let ct = git(["log", "-1", "--format=%ct"]).flatMap({ Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }),
               Date().timeIntervalSince1970 - ct < 2 * 3600,
               let show = git(["log", "-1", "--stat", "--format=%s"]) {
                scope = "committed"
                lines = show.split(separator: "\n").map { String($0.trimmingCharacters(in: .whitespaces)) }
            }
        }
        guard !lines.isEmpty else { return nil }
        let summary = (lines.last ?? "")
            .replacingOccurrences(of: "(+)", with: "").replacingOccurrences(of: "(-)", with: "")
            .trimmingCharacters(in: .whitespaces)
        if lines.count > 14 { lines = ["… and \(lines.count - 13) more"] + lines.suffix(13) }
        let spoken = summary.isEmpty
            ? "The changes are on the card."
            : "\(summary), \(scope) — the file list is on the card."
        return (lines, spoken)
    }

    /// Answer "what did it change?" the way a colleague would: a short
    /// spoken recap made from the session's own transcript — what was
    /// asked, what the agent did — with the touched file NAMES on the
    /// card for grounding. Counts of lines never reach the ear or the
    /// screen; they answer "how much", and the question was "what". The
    /// git stat remains only as the fallback when there is no transcript
    /// to read. The episode stays open, so the next words still go to
    /// the session.
    private func showChanges() {
        guard let p = current else { return }
        let ev = p.event
        let story = ev.agent == .codex
            ? Codex.story(for: ev.sessionID)
            : SessionTranscript.recentStory(sessionID: ev.sessionID, cwd: ev.cwd)
        guard let story = story else {
            guard let (detail, spoken) = Self.gitChanges(cwd: ev.cwd) else {
                let s = "I don't see any work in \(Self.spoken(ev.folder)) yet."
                AgentPanel.shared.say(s)
                return listenAndSpeak(s)
            }
            AgentPanel.shared.list(detail)
            AgentPanel.shared.say(spoken)
            return listenAndSpeak(spoken)
        }
        AgentPanel.shared.note("Summarising…")
        let files = Self.changedFiles(cwd: ev.cwd)
        Refiner.shared.recap(project: ev.project, transcript: story) { [weak self] r in
            DispatchQueue.main.async {
                guard let self = self, self.current != nil else { return }
                let recap: String
                switch r {
                case .success(let s): recap = s
                case .failure(let e):
                    self.log("recap failed — \(e.localizedDescription); reading the last line")
                    recap = Self.firstSentences(
                        of: self.recents.first { $0.sessionID == ev.sessionID }?.line ?? ev.message,
                        limit: 220)
                }
                if !files.isEmpty { AgentPanel.shared.list(files) }
                AgentPanel.shared.say(recap)
                self.listenAndSpeak(recap)
            }
        }
    }

    /// The files the session's tree touched — names only, for the card.
    private static func changedFiles(cwd: String) -> [String] {
        guard !cwd.isEmpty else { return [] }
        let out = capture("/usr/bin/git", ["-C", cwd, "diff", "--name-only", "HEAD"]) ?? ""
        var files = out.split(separator: "\n").map { String($0) }
        if files.count > 10 { files = Array(files.prefix(9)) + ["… and \(files.count - 9) more"] }
        return files
    }

    /// run(), but keeping stdout — for the git reads.
    private static func capture(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    private static func which(_ name: String) -> String? {
        for d in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let p = d + "/" + name
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    private static func run(_ path: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// ITERM_SESSION_ID is "w0t1p0:UUID"; the UUID is the session's id.
    private static func itermWrite(session: String, text: String) -> Bool {
        let id = session.split(separator: ":").last.map(String.init) ?? session
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if id of s is "\(id)" then
                            tell s to write text "\(escaped)"
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "missing"
        """
        var err: NSDictionary?
        let out = NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let err = err { Config.shared.log("Agent voice: iTerm write failed — \(err)"); return false }
        return out?.stringValue == "ok"
    }

    // MARK: Try it

    /// The samples' made-up project, the one their folder name is said as:
    /// "SayControl", never a real folder on this Mac (ours is SayCtrl-dev).
    private static let sampleFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Projects/SayControl").path

    /// A sample button pressed: one sample at a time. Pressed again while
    /// that same sample plays, it does nothing — it is already playing, and
    /// each start spends one of the day's samples; the other sample's button
    /// closes it for its own. A sample already waiting is dropped, so presses
    /// never line up card after card. A real agent's update being spoken is
    /// left alone; the sample follows it.
    private func enqueueSample(_ p: Pending) {
        if let playing = current, Self.isSample(playing.event) {
            if playing.event.sessionID == p.event.sessionID { return log("sample already playing") }
            log("sample switched")
            finishQuietly()
        }
        queue.removeAll { waiting in
            guard Self.isSample(waiting.event) else { return false }
            waiting.respond?("{}")
            return true
        }
        enqueue(p)
    }

    /// What the samples say: plain news anyone follows, short, and said as
    /// written (a sample skips the summary), so each ships recorded in both
    /// voices (scripts/make_voice_clips.py) and plays at once. Change one and
    /// remake the clips.
    static let sampleNews: [AgentKind: String] = [
        .claude: "I fixed the login bug. The page loads in under a second now, and all the tests pass. Want me to open the changes?",
        .codex: "I added a dark mode to the settings page. It follows your Mac's appearance. Should I push it?",
    ]

    /// A made-up finish, to hear the voice without an agent.
    func playSample(agent: AgentKind = .claude) {
        let cwd = Self.sampleFolder
        let said = Self.sampleNews[agent] ?? Self.sampleNews[.claude]!
        enqueueSample(Pending(event: AgentEvent(
            kind: .finished, sessionID: "sample", cwd: cwd, message: said,
            asked: agent == .codex ? "Add a dark mode." : "Fix the login bug.", toolName: nil, toolInput: [:], questions: [],
            termProgram: nil, itermSession: nil, tmuxPane: nil, socket: nil, token: nil, agent: agent)))
    }

    /// A made-up multiple-choice question, to try answering by voice.
    func playQuestionSample(agent: AgentKind = .claude) {
        let cwd = Self.sampleFolder
        let input: [String: Any] = ["questions": [
            ["question": "Which color should the new button be?", "header": "Color",
             "options": [["label": "Blue"], ["label": "Green"], ["label": "Orange"]], "multiSelect": false],
            ["question": "Should I add tests for it?", "header": "Tests",
             "options": [["label": "Yes, add tests"], ["label": "No, skip them"]], "multiSelect": false],
        ]]
        enqueueSample(Pending(event: AgentEvent(
            kind: .question, sessionID: "sample-q", cwd: cwd, message: "asks", asked: nil, toolName: "AskUserQuestion",
            toolInput: input, questions: Self.questions(in: input), termProgram: nil, itermSession: nil, tmuxPane: nil,
            socket: nil, token: nil, agent: agent),
            respond: { [weak self] json in self?.log("sample answer → \(Config.words("\(json)"))") }))
    }
}

// MARK: - Claude Code settings

/// The hooks in ~/.claude/settings.json that point at the bridge. Other
/// people's hooks are left exactly as they were; ours are recognisable by
/// their URL and replaced as a set.
enum AgentHooks {
    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    private static func marker(_ port: Int) -> String { "http://127.0.0.1:\(port)/sayctrl/" }

    /// This install's secret, which every one of our hooks sends and the
    /// listener demands. Only ~/.claude/settings.json and this build's
    /// Keychain item hold it, so a web page (which can neither read the file
    /// nor add a header without a CORS preflight that is never answered) and
    /// another account on this Mac can't speak to the listener: no fake
    /// "finished", no spending a conversation, no part in a permission.
    static let tokenHeader = "X-SayControl-Token"
    static let secret: String = {
        if let saved = TokenStore.read("agent-hooks"), !saved.isEmpty { return saved }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            // No secret means no hook is ever let in, which is the safe way to fail.
            return UUID().uuidString + UUID().uuidString
        }
        let fresh = bytes.map { String(format: "%02x", $0) }.joined()
        TokenStore.write("agent-hooks", fresh)
        return fresh
    }()

    /// Our hooks carry today's secret: an older build's, written before
    /// there was one, are refreshed at launch.
    private static func carriesSecret(port: Int) -> Bool {
        guard let root = read(), let hooks = root["hooks"] as? [String: Any] else { return false }
        let groups = hooks["PermissionRequest"] as? [[String: Any]] ?? []
        return groups.contains { g in
            ((g["hooks"] as? [[String: Any]]) ?? []).contains {
                isOurs($0, port: port) && ($0["headers"] as? [String: String])?[tokenHeader] == secret
            }
        }
    }
    /// Ours means THIS build's — matched by port, not by the /sayctrl/ in
    /// the URL. The dev app and the shipping app share one settings.json
    /// and sit on different ports; since the switch now writes and erases
    /// these by itself, a build that recognised the other's hooks as its
    /// own would quietly delete them at launch.
    private static func isOurs(_ hook: [String: Any], port: Int) -> Bool {
        (hook["url"] as? String)?.hasPrefix(marker(port)) == true
    }

    static func installed(port: Int) -> Bool {
        guard let root = read(), let hooks = root["hooks"] as? [String: Any] else { return false }
        for event in ["Stop", "PermissionRequest"] {
            let groups = hooks[event] as? [[String: Any]] ?? []
            let hit = groups.contains { g in
                ((g["hooks"] as? [[String: Any]]) ?? []).contains { ($0["url"] as? String) == marker(port) + event }
            }
            if !hit { return false }
        }
        return true
    }

    /// Installed, but from an older build's set — a newer event is missing
    /// from the file. The bridge refreshes ours in place at launch.
    static func needsUpgrade(port: Int) -> Bool {
        guard installed(port: port), let root = read(),
              let hooks = root["hooks"] as? [String: Any] else { return false }
        if !carriesSecret(port: port) { return true }
        return !["SessionStart", "SessionEnd"].allSatisfy { event in
            let groups = hooks[event] as? [[String: Any]] ?? []
            return groups.contains { g in
                ((g["hooks"] as? [[String: Any]]) ?? []).contains { ($0["url"] as? String) == marker(port) + event }
            }
        }
    }

    private static func read() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func write(_ root: [String: Any]) throws {
        let url = settingsURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            let bak = url.deletingPathExtension().appendingPathExtension("json.sayctrl-bak")
            try? FileManager.default.removeItem(at: bak)
            try FileManager.default.copyItem(at: url, to: bak)
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private static func stripped(_ hooks: [String: Any], port: Int) -> [String: Any] {
        var out = hooks
        for (event, value) in hooks {
            guard var groups = value as? [[String: Any]] else { continue }
            groups = groups.compactMap { g in
                var g = g
                let kept = ((g["hooks"] as? [[String: Any]]) ?? []).filter { !isOurs($0, port: port) }
                if kept.isEmpty && ((g["hooks"] as? [[String: Any]])?.isEmpty == false) { return nil }
                g["hooks"] = kept
                return g
            }
            if groups.isEmpty { out.removeValue(forKey: event) } else { out[event] = groups }
        }
        return out
    }

    static func install(port: Int) throws {
        guard var root = read() else {
            throw NSError(domain: "SayCtrl", code: 40, userInfo: [
                NSLocalizedDescriptionKey: "~/.claude/settings.json isn't valid JSON — fix it by hand first."])
        }
        var hooks = stripped(root["hooks"] as? [String: Any] ?? [:], port: port)
        let env = ["TERM_PROGRAM", "ITERM_SESSION_ID", "TMUX_PANE", "CLAUDE_CODE_MESSAGING_SOCKET",
                   "CLAUDE_CODE_MESSAGING_TOKEN"]
        let headers = ["X-Term-Program": "$TERM_PROGRAM", "X-Iterm-Session": "$ITERM_SESSION_ID",
                       "X-Tmux-Pane": "$TMUX_PANE", "X-Messaging-Socket": "$CLAUDE_CODE_MESSAGING_SOCKET",
                       "X-Messaging-Token": "$CLAUDE_CODE_MESSAGING_TOKEN",
                       tokenHeader: secret]
        func hook(_ event: String, timeout: Int) -> [String: Any] {
            ["type": "http", "url": marker(port) + event, "timeout": timeout,
             "headers": headers, "allowedEnvVars": env]
        }
        for (event, timeout) in [("Stop", 5), ("Notification", 5), ("PermissionRequest", 120),
                                 ("SessionStart", 5), ("SessionEnd", 5)] {
            var groups = hooks[event] as? [[String: Any]] ?? []
            var group: [String: Any] = ["hooks": [hook(event, timeout: timeout)]]
            if event != "Notification" { group["matcher"] = "*" }
            groups.append(group)
            hooks[event] = groups
        }
        root["hooks"] = hooks
        // An allowlist that exists must name us, or the hook never fires.
        if var allowed = root["allowedHttpHookUrls"] as? [String] {
            let ours = marker(port) + "*"
            if !allowed.contains(where: { $0.hasPrefix("http://127.0.0.1:\(port)/sayctrl") }) { allowed.append(ours) }
            root["allowedHttpHookUrls"] = allowed
        }
        try write(root)
    }

    static func remove(port: Int) throws {
        guard var root = read() else { return }
        let hooks = stripped(root["hooks"] as? [String: Any] ?? [:], port: port)
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        try write(root)
    }

    /// The receiver-side switch that lets a spoken reply through without a
    /// hold. A session running with permission prompts off parks any inbox
    /// message whose sender didn't attest a permission mode, and the plain
    /// socket line the bridge writes cannot attest — the only lift is this
    /// key. It makes the session accept every local sender, not just us,
    /// so it rides the voice switch (on with it, off with it) and says so
    /// on the switch, rather than sitting in the hooks for good.
    static func inboundAccepted() -> Bool {
        (read()?["crossSessionInbound"] as? String) == "accept"
    }

    /// True when the file changed. A "hold" or "refuse" the user set by
    /// hand is theirs: neither direction touches it.
    @discardableResult
    static func acceptInbound(_ on: Bool) throws -> Bool {
        guard var root = read() else {
            throw NSError(domain: "SayCtrl", code: 41, userInfo: [
                NSLocalizedDescriptionKey: "~/.claude/settings.json isn't valid JSON — fix it by hand first."])
        }
        let now = root["crossSessionInbound"] as? String
        if on {
            guard now == nil else { return false }
            root["crossSessionInbound"] = "accept"
        } else {
            guard now == "accept" else { return false }
            root.removeValue(forKey: "crossSessionInbound")
        }
        try write(root)
        return true
    }
}
