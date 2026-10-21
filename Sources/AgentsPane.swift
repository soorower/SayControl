// The Agents pages. The sidebar shows one row — the hub (AgentsHubPane,
// end of this file), with the roster, the tallies and the live sessions —
// and each agent's own page opens from a tile on it. Claude Code and
// Codex are wired up, and there is nothing on either page to set up: one
// switch turns the voice on and SayCtrl connects itself to both (Claude
// Code through its hooks, written for you; Codex by reading the files it
// already writes). The other two pages hold the layout open for the
// agents that come next.
//
// The grouped-row kit at the foot of this file (Hub, HubGroup, HubChip)
// lays the refresh's grouped containers out on a pane — the rows in them
// are the shared FormRow and SwitchRow — and Tones and Help are built
// from it too.
import AppKit

final class AgentsPane: PaneView {
    /// The four agents the hub lists. Claude and Codex have something
    /// behind them; the rest render their future home so the roster
    /// reads as a roster, not a single feature.
    enum Kind: String, CaseIterable {
        case claude, codex, cursor, opencode

        /// The pane key — what select("agent-claude") answers to.
        var key: String { "agent-" + rawValue }

        /// The agent this pane speaks for, for the panes that have one.
        var agent: AgentKind? {
            switch self {
            case .claude: return .claude
            case .codex:  return .codex
            default:      return nil
            }
        }

        var navTitle: String {
            switch self {
            case .claude:   return "Claude"
            case .codex:    return "Codex"
            case .cursor:   return "Cursor"
            case .opencode: return "OpenCode"
            }
        }

        var paneTitle: String {
            switch self {
            case .claude:   return "Claude Code"
            case .codex:    return "Codex"
            case .cursor:   return "Cursor"
            case .opencode: return "OpenCode"
            }
        }

        /// The agent's face at `side` points. Claude keeps its own
        /// terracotta — the colour the voice's card draws it in — and the
        /// rest are template images that take the page's ink.
        func mark(_ side: CGFloat) -> NSImage? {
            switch self {
            case .claude:   return AgentMark.starburst(side, color: Theme.hex(0xD97757))
            case .codex:    return AgentMark.blossom(side * 0.9)
            case .cursor:   return Theme.symbol("cursorarrow", side * 0.86, .regular)
            case .opencode: return Theme.symbol("chevron.left.forwardslash.chevron.right", side * 0.72, .regular)
            }
        }

        /// The word of state a tile and a page wear, and the chip it goes in.
        /// Live beats everything: a session running now is the news.
        func state(live: Int) -> (String, HubChip.Tone) {
            if live > 0 { return ("\(live) live", .live) }
            let on = Config.shared.agentVoice
            switch self {
            case .claude:            return on ? ("On", .ok) : ("Off", .neutral)
            case .codex:             return !Codex.installed ? ("Not installed", .neutral)
                                                             : (on ? ("On", .ok) : ("Off", .neutral))
            case .cursor, .opencode: return ("Coming soon", .neutral)
            }
        }

        init?(_ agent: AgentKind) { self.init(rawValue: agent.rawValue) }
    }

    private let kind: Kind

    // Wired-up pane state — the status chip and line, and the sessions list.
    private let statusChip = HubChip("", .neutral)
    private let agentStatus = Hub.para("", 12)
    private let statusIcon = NSImageView()
    private var statusLine: NSView!
    private let recentRows = HubGroup()

    init(_ kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        kind.agent == nil ? buildPlaceholder() : buildAgent()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func paneAppeared() {
        guard kind.agent != nil else { return }
        refreshStatus()
        drawRecents()
    }

    // MARK: - An agent that is wired up

    private func buildAgent() {
        let agent = kind.agent ?? .claude
        let header = makePaneHeader(
            kind.paneTitle,
            agent == .codex
                ? "The voice speaks when a Codex session finishes, and your reply goes back in."
                : "The voice speaks when a session finishes or needs you. Your answer goes back in.",
            trailing: FlatButton("All agents") { SettingsUI.shared.select("agents") })

        let voice = HubGroup()
        let speak = SwitchRow("Speak when an agent finishes or needs me",
                              "A one-line summary, read aloud. Nothing else to set up.",
                              isOn: Config.shared.agentVoice) { [weak self] on in
            Config.shared.setFlag("AGENT_VOICE", on)
            AgentBridge.shared.apply()
            Config.shared.log("Agent voice toggled: \(on)")
            self?.refreshStatus()
        }
        if agent == .claude {
            speak.toolTip = "Spoken replies to sessions running with permission prompts off need your OK to a Claude Code setting, which also lets those sessions take messages from other apps on this Mac. You're asked once; turning the voice off takes it back out."
        }
        voice.add(speak)
        // One line under each switch; the rest of the story is a hover away.
        let openMic = SwitchRow("Listen without a key press",
                                "Talk over the voice to cut in. The key still works.",
                                isOn: Config.shared.agentOpenMic) { Config.shared.setFlag("AGENT_OPEN_MIC", $0) }
        openMic.toolTip = "The mic opens around each line. Talk over the voice to cut in; quiet ends the reply. The key still works."
        voice.add(openMic)
        let voices = VoiceIO.relayVoices
        let whose = PillSwitcher(voices.map(\.name),
                                 selected: voices.firstIndex { $0.id == VoiceIO.relayVoice() } ?? 0) { i in
            Config.shared.set("AGENT_CLOUD_VOICE", voices[i].id)
            Config.shared.log("Agent voice set to \(voices[i].id)")
        }
        voice.add(FormRow("Voice", "Who reads the summaries.", controls: [whose]))
        voice.add(FormRow("Try it", "Hear a sample summary or question and answer it.",
                          controls: [FlatButton("Play a sample") { AgentBridge.shared.playSample(agent: agent) },
                                     FlatButton("Play a question") { AgentBridge.shared.playQuestionSample(agent: agent) }]))

        // What the voice is doing, under the switches: a triangle only when
        // something needs a look, so a healthy page reads as one quiet line.
        statusIcon.image = Theme.symbol("exclamationmark.triangle.fill", Theme.m(10.5), .medium)
        statusIcon.contentTintColor = Theme.amber
        statusIcon.setContentHuggingPriority(.required, for: .horizontal)
        let line = Theme.hstack([statusIcon, agentStatus], spacing: Theme.m(6))
        line.alignment = .firstBaseline
        line.distribution = .fill
        statusLine = Hub.inset(line)

        let voiceSection = Hub.section(
            Hub.head("Agent voice", "The same switches sit on every agent's page.",
                     accessories: [statusChip]),
            voice, foot: statusLine)
        let sessions = Hub.section(
            Hub.head("Recent sessions", "Continue one and your words land there, even in the background."),
            recentRows)

        Hub.scroll([header, voiceSection, sessions]).fill(self)
        refreshStatus()
        drawRecents()
    }

    /// One line, and only what the user could act on. With the voice off
    /// the chip says so; with it on, the only thing worth reporting is the
    /// rare case where something didn't come up.
    private func refreshStatus() {
        let agent = kind.agent ?? .claude
        var lines: [String] = []
        var trouble = false
        guard Config.shared.agentVoice else {
            agentStatus.stringValue = "Off."
            statusChip.set("Off", .neutral)
            // "Off." is all the line would say, and the chip already does.
            statusLine.isHidden = true
            return
        }
        switch agent {
        case .claude:
            if !AgentBridge.shared.running { lines.append("Not listening — see the log."); trouble = true }
            else if !AgentHooks.installed(port: Config.shared.agentPort) {
                lines.append("Couldn't write to ~/.claude/settings.json — see the log.")
                trouble = true
            } else {
                lines.append("On. New Claude sessions report here.")
            }
        case .codex:
            if !Codex.installed { lines.append("Codex doesn't look installed on this Mac."); trouble = true }
            else if CodexWatcher.shared.running { lines.append("On. Reading along with your Codex sessions.") }
            else { lines.append("Not reading — see the log."); trouble = true }
        }
        if !Config.shared.hasModelAccess {
            lines.append("No Polish key — summaries will read the agent's own words.")
            trouble = true
        }
        if let e = VoiceIO.shared.lastVoiceError { lines.append(e); trouble = true }
        agentStatus.stringValue = lines.joined(separator: " ")
        let word = agent == .codex && !Codex.installed ? "Not installed" : "On"
        statusChip.set(word, trouble ? .warn : .ok)
        statusIcon.isHidden = !trouble
        statusLine.isHidden = false
    }

    private func drawRecents() {
        recentRows.removeAll()
        let agent = kind.agent ?? .claude
        let list = AgentBridge.shared.recents.filter { $0.agent == agent }
        guard !list.isEmpty else {
            recentRows.add(Hub.note("No sessions yet — each \(kind.paneTitle) session the voice hears from lives here for a day."))
            return
        }
        for r in list {
            let title = AgentBridge.shared.displayName(
                sessionID: r.sessionID,
                fallback: "Agent on " + r.folder.replacingOccurrences(of: "-", with: " "))
            // The session's own title — the one its sidebar shows — with
            // the short id filling in until it earns one.
            let sTitle = SessionTitles.title(for: r.sessionID, cwd: r.cwd, agent: r.agent)
                ?? String(r.sessionID.prefix(8))
            let firstLine = r.line.split(separator: "\n").first.map(String.init) ?? r.line
            // Cut at 90 as it always was — with the ellipsis that says so.
            let said = firstLine.count > 90 ? String(firstLine.prefix(90)) + "…" : firstLine
            recentRows.add(SessionRow(title: title,
                                      meta: "\(sTitle) · \(AgentBridge.ago(r.when))",
                                      said: said,
                                      live: !r.ended) { AgentBridge.shared.resume(r) })
        }
    }

    // MARK: - The agents to come

    private func buildPlaceholder() {
        let header = makePaneHeader(kind.paneTitle, "",
                                    trailing: FlatButton("All agents") { SettingsUI.shared.select("agents") })
        let name: String
        switch kind {
        case .cursor:   name = "Cursor"
        case .opencode: name = "OpenCode"
        default:        name = kind.paneTitle   // never reached
        }
        let group = HubGroup()
        let about = Hub.para("\(name) isn't wired up yet. Its voice and sessions will live on this page.",
                             13, .regular, Theme.ink2, lineHeight: 1.3)
        let (word, tone) = kind.state(live: 0)
        let lead = Theme.hstack([MarkWell(kind, muted: true), about], spacing: Theme.m(12))
        lead.distribution = .fill
        let intro = NSView()
        splitRow(lead, HubChip(word, tone), into: intro, vertical: 0)
        group.add(intro, padY: 14)
        group.add(FormRow("Works today", "Claude Code and Codex have the full agent voice.",
                          controls: [FlatButton("Open Claude") { SettingsUI.shared.select("agent-claude") },
                                     FlatButton("Open Codex") { SettingsUI.shared.select("agent-codex") }]))
        Hub.scroll([header, group]).fill(self)
    }
}

// MARK: - The Agents hub

/// The sidebar's one Agents page: which agents you have been talking to
/// and how often, the sessions running right now, and a tile per agent
/// that opens its own page — the four panes above stopped being sidebar
/// rows and live behind these tiles instead.
final class AgentsHubPane: PaneView {
    private let latelyRows = HubGroup()
    private let activeRows = HubGroup()
    /// "2 live" beside Running now — ember, because those sessions are.
    private let liveChip = HubChip("", .live)
    private var tiles: [AgentTile] = []
    /// The hero's picture, which also shows who is live.
    private let voiceMap = VoiceMap()
    /// On SayControl's cloud: how many agent conversations are left, and
    /// the way to more.
    private let freeStrip = AgentAllowanceStrip()

    init() {
        super.init(frame: .zero)
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(freeChanged),
                                               name: .sayctrlAccountChanged, object: nil)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func freeChanged() { freeStrip.refresh() }
    required init?(coder: NSCoder) { fatalError() }

    override func paneAppeared() {
        refresh()
        // The count is the server's; a conversation on another Mac moves it.
        if Config.shared.agentCloud { Cloud.shared.refreshAccountIfStale() }
    }

    private func build() {
        // The hero says what the header's subtitle used to, and draws it:
        // one voice in the middle, every agent on this Mac around it.
        let header = makePaneHeader("Agents")
        let hero = HeroBanner(title: "One voice for all your agents",
                              subtitle: "Hear when a coding agent finishes or needs you, and answer it out loud.",
                              primary: ("Hear a sample", { AgentBridge.shared.playSample(agent: .claude) }),
                              art: .view(voiceMap))

        let lately = Hub.section(Hub.head("Lately", "The agents you have talked with, and how often."),
                                 latelyRows)

        tiles = AgentsPane.Kind.allCases.map { AgentTile($0) }
        let row = NSStackView(views: tiles)
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = Theme.m(12)
        let roster = Hub.section(
            Hub.head("Your agents", "Open one for its voice switches and recent sessions."), row)

        let active = Hub.section(Hub.head("Running now", "Live sessions the voice can talk to.",
                                          accessories: [liveChip]),
                                 activeRows)

        let scroll = Hub.scroll([header, hero, freeStrip, lately, roster, active])
        (scroll.documentView?.subviews.first as? NSStackView)?.setCustomSpacing(Theme.m(16), after: header)
        scroll.fill(self)
        refresh()
    }

    private func refresh() {
        freeStrip.refresh()
        // Lately: one line per agent that has ever had a conversation,
        // most recent first.
        latelyRows.removeAll()
        let used = AgentsPane.Kind.allCases
            .compactMap { k -> (AgentsPane.Kind, Int, Date)? in
                guard let a = k.agent else { return nil }
                let u = AgentBridge.shared.usage(for: a)
                guard u.count > 0, let last = u.last else { return nil }
                return (k, u.count, last)
            }
            .sorted { $0.2 > $1.2 }
        if used.isEmpty {
            latelyRows.add(Hub.note("Nothing yet. Conversations are counted from the first one."))
        }
        for (k, count, last) in used {
            let sessions = AgentBridge.shared.recents.filter { $0.agent == k.agent }.count
            let tally = "\(count) conversation\(count == 1 ? "" : "s")"
                + (sessions > 0 ? " · \(sessions) session\(sessions == 1 ? "" : "s") today" : "")
                + " · last \(AgentBridge.ago(last))"
            latelyRows.add(LatelyRow(k, tally: tally))
        }

        // Running now: the live sessions across every agent.
        activeRows.removeAll()
        AgentBridge.shared.refreshLiveness()
        let live = AgentBridge.shared.liveRecents
        liveChip.set("\(live.count) live", .live)
        liveChip.isHidden = live.isEmpty
        if live.isEmpty { activeRows.add(Hub.note("Nothing running right now.")) }
        for r in live {
            let name = AgentBridge.shared.displayName(
                sessionID: r.sessionID,
                fallback: r.folder.replacingOccurrences(of: "-", with: " "))
            let sTitle = SessionTitles.title(for: r.sessionID, cwd: r.cwd, agent: r.agent)
                ?? String(r.sessionID.prefix(8))
            activeRows.add(SessionRow(title: "\(r.agent.display) · \(name)",
                                      meta: "\(sTitle) · \(AgentBridge.ago(r.when))",
                                      kind: AgentsPane.Kind(r.agent)) { AgentBridge.shared.resume(r) })
        }

        for tile in tiles {
            tile.refresh(live: live.filter { $0.agent == tile.kind.agent }.count)
        }
        voiceMap.live = Set(live.compactMap { AgentsPane.Kind($0.agent) })
    }
}

/// The agent voice's allowance, under the hero: what is left and the way to
/// more. Free sees its ten and See plans; Pro its month, what it bought, and
/// an amount to buy (500, 1,000, 5,000 or 10,000 conversations, all at $1
/// per 100) with "Buy for $…" beside it. Hidden on the developers' own keys,
/// where nothing is counted, and until the server has said.
private final class AgentAllowanceStrip: NSView {
    private let proTag = ProTag()
    private let title = Theme.text("", 13.5, .medium, Theme.ink)
    private let line = Theme.para("", 12.5)
    private let plans = FlatButton("See plans", .plain) { SettingsUI.shared.showSettings(tab: "billing") }
    private lazy var buy = FlatButton("Buy", .ember) { [weak self] in
        guard let self = self, self.chosen > 0 else { return }
        Account.buyAgentPack(conversations: self.chosen)
    }
    /// The amounts on offer, as the server last listed them, and the one
    /// picked: kept across redraws, so a count arriving doesn't undo a pick.
    private let row = NSStackView()
    private var amounts: PopButton?
    private var offered: [Int] = []
    private var prices: [Int: Int] = [:]
    /// The conversations picked; 0 before anything is on offer.
    private var chosen = 0

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(12)
        layer?.borderWidth = 1
        line.maximumNumberOfLines = 2
        line.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        // The words take the row's slack, so the line stays on one line.
        line.setContentHuggingPriority(.init(1), for: .horizontal)
        let words = Theme.vstack([title, line], spacing: Theme.m(2))
        words.setHuggingPriority(.init(1), for: .horizontal)
        row.orientation = .horizontal
        row.spacing = Theme.m(12)
        for v in [proTag, words, plans, buy] { row.addArrangedSubview(v) }
        row.setCustomSpacing(Theme.m(8), after: plans)
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: Theme.m(14)),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.m(14)),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(18)),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.m(14)),
        ])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    private static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: d)
    }

    private static func dollars(_ n: Int) -> String { "$\(Account.grouped(n))" }

    /// The dropdown, made again only when the server lists other amounts:
    /// "10,000 conversations" on the button, each price beside its amount
    /// in the menu, and the price picked on Buy.
    private func offer(_ a: AgentAllowance) {
        let amounts = a.packs.map { $0.conversations }
        prices = Dictionary(a.packs.map { ($0.conversations, $0.dollars) }, uniquingKeysWith: { x, _ in x })
        if amounts != offered || self.amounts == nil {
            offered = amounts
            if !offered.contains(chosen) { chosen = offered.first ?? 0 }
            self.amounts?.removeFromSuperview()
            self.amounts = nil
            if !offered.isEmpty {
                let pop = PopButton(offered.map { "\(Account.grouped($0)) conversations" },
                                    notes: offered.map { Self.dollars(prices[$0] ?? 0) },
                                    selected: offered.firstIndex(of: chosen) ?? 0) { [weak self] i in
                    guard let self = self, self.offered.indices.contains(i) else { return }
                    self.chosen = self.offered[i]
                    self.priceBuy()
                }
                pop.toolTip = "Conversations to buy, kept until you use them"
                if let at = row.arrangedSubviews.firstIndex(of: buy) { row.insertArrangedSubview(pop, at: at) }
                self.amounts = pop
            }
        }
        priceBuy()
    }

    private func priceBuy() {
        buy.title = prices[chosen].map { "Buy for \(Self.dollars($0))" } ?? "Buy"
    }

    func refresh() {
        guard Config.shared.agentCloud, let a = Cloud.shared.agent else { isHidden = true; return }
        isHidden = false
        let n = Account.grouped
        let bought = a.credits > 0 ? "\(n(a.credits)) bought" : nil
        // $5 for 500 is $1 per 100, whichever amount is picked.
        let first = a.packs.first ?? (500, 5)
        let per = Double(first.dollars) * 100 / Double(max(1, first.conversations))
        let rate = per == per.rounded() ? "$\(Int(per)) per 100" : String(format: "$%.2f per 100", per)
        let more = "more at \(rate), kept until you use them"
        let renews = a.resetsAt.map { " on \(Self.day($0))" } ?? ""
        if a.once {
            // Free: the ten to try. Bought ones from a Pro that ended still count.
            proTag.isHidden = false
            plans.isHidden = false
            buy.isHidden = true
            amounts?.isHidden = true
            if a.left > 0 {
                title.stringValue = "\(a.left) of \(a.limit) free agent conversations left"
                    + (bought.map { " · \($0)" } ?? "")
                line.stringValue = "The agent voice is Pro’s: 300 conversations a month. Hear a sample any time."
            } else if a.credits > 0 {
                title.stringValue = "\(n(a.credits)) bought agent conversations left"
                line.stringValue = "Your free ones are used. Pro gives you 300 a month."
            } else {
                title.stringValue = "Your \(a.limit) free agent conversations are used"
                line.stringValue = "The voice stays quiet until you go Pro. Hear a sample any time."
            }
        } else {
            offer(a)
            proTag.isHidden = true
            plans.isHidden = true
            buy.isHidden = offered.isEmpty
            amounts?.isHidden = offered.isEmpty
            if a.left > 0 {
                title.stringValue = "\(n(a.left)) of \(n(a.limit)) agent conversations left this month"
                    + (bought.map { " · \($0)" } ?? "")
                line.stringValue = "Back to \(n(a.limit))\(renews). Need more? Buy \(more)."
            } else if a.credits > 0 {
                title.stringValue = "This month’s \(n(a.limit)) are used · \(bought ?? "")"
                line.stringValue = "Bought ones are speaking now; the month’s come back\(renews)."
            } else {
                title.stringValue = "This month’s \(n(a.limit)) agent conversations are used"
                line.stringValue = "The voice is quiet until\(renews.isEmpty ? " next month" : renews). Or buy \(more)."
            }
        }
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Theme.surface.cgColor
        layer?.borderColor = Theme.hairline.cgColor
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// The Agents hero's picture: SayControl's mark in the middle, the four
/// agents around it, a line from the voice to each. The two that are wired
/// up hang on solid lines; the two to come on dashed ones, their marks
/// dimmed. An agent with a session running now wears an ember dot — the
/// one colour kept for live. Drawn in the hero's fixed palette.
private final class VoiceMap: NSView {
    var live: Set<AgentsPane.Kind> = [] { didSet { if live != oldValue { needsDisplay = true } } }

    /// Where each agent sits, as fractions of the picture.
    private static let spots: [AgentsPane.Kind: NSPoint] = [
        .claude: NSPoint(x: 0.09, y: 0.24), .codex: NSPoint(x: 0.09, y: 0.76),
        .cursor: NSPoint(x: 0.91, y: 0.24), .opencode: NSPoint(x: 0.91, y: 0.76),
    ]

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Theme.m(252)),
            heightAnchor.constraint(equalToConstant: Theme.m(118)),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        let hub = NSPoint(x: b.midX, y: b.midY)
        let hubR = Theme.m(26)
        let r = Theme.m(19)

        // The lines first, so the discs sit on top of their ends.
        for kind in AgentsPane.Kind.allCases {
            guard let f = Self.spots[kind] else { continue }
            let p = NSPoint(x: b.width * f.x, y: b.height * f.y)
            let toLeft = p.x < hub.x
            let start = NSPoint(x: hub.x + (toLeft ? -hubR : hubR), y: hub.y)
            let end = NSPoint(x: p.x + (toLeft ? r : -r), y: p.y)
            let mid = (start.x + end.x) / 2
            let line = NSBezierPath()
            line.move(to: start)
            line.curve(to: end, controlPoint1: NSPoint(x: mid, y: start.y), controlPoint2: NSPoint(x: mid, y: end.y))
            line.lineWidth = 1.25
            line.lineCapStyle = .round
            if kind.agent == nil { line.setLineDash([0, 4], count: 2, phase: 0) }
            NSColor.white.withAlphaComponent(kind.agent == nil ? 0.22 : 0.34).setStroke()
            line.stroke()
        }

        // The voice: SayControl's own mark, cream bars and the ember arrow.
        disc(at: hub, radius: hubR, strength: 1.3)
        let m = hubR * 1.1
        Theme.drawMark(in: NSRect(x: hub.x - m / 2, y: hub.y - m / 2, width: m, height: m),
                       ink: HeroBanner.cream, accent: Theme.ember)

        for kind in AgentsPane.Kind.allCases {
            guard let f = Self.spots[kind] else { continue }
            let p = NSPoint(x: b.width * f.x, y: b.height * f.y)
            let wired = kind.agent != nil
            disc(at: p, radius: r, strength: wired ? 1 : 0.6)
            let side = (r * 1.05).rounded()
            if let img = face(kind, side) {
                let s = img.size
                img.draw(in: NSRect(x: (p.x - s.width / 2).rounded(), y: (p.y - s.height / 2).rounded(),
                                    width: s.width, height: s.height),
                         from: .zero, operation: .sourceOver, fraction: wired ? 1 : 0.5,
                         respectFlipped: true, hints: nil)
            }
            if live.contains(kind) {
                let d = Theme.m(9)
                let dot = NSRect(x: p.x + r * 0.62, y: p.y - r * 0.92, width: d, height: d)
                Theme.ember.setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
        }
    }

    /// The frosted disc the hero's apps sit on.
    private func disc(at c: NSPoint, radius: CGFloat, strength: CGFloat) {
        let path = NSBezierPath(ovalIn: NSRect(x: c.x - radius, y: c.y - radius,
                                               width: radius * 2, height: radius * 2).insetBy(dx: 0.5, dy: 0.5))
        NSColor.white.withAlphaComponent(0.10 * strength).setFill()
        path.fill()
        path.lineWidth = 1
        NSColor.white.withAlphaComponent(0.16 * strength).setStroke()
        path.stroke()
    }

    /// An agent's mark in cream — Claude keeps its terracotta, the way the
    /// voice's own card draws it.
    private func face(_ kind: AgentsPane.Kind, _ side: CGFloat) -> NSImage? {
        switch kind {
        case .claude: return kind.mark(side)
        case .codex:  return AgentMark.blossom(side * 0.9, color: HeroBanner.cream)
        default:
            guard let img = kind.mark(side) else { return nil }
            return NSImage(size: img.size, flipped: false) { rect in
                img.draw(in: rect)
                HeroBanner.cream.set()
                rect.fill(using: .sourceAtop)
                return true
            }
        }
    }
}

/// One agent as a clickable tile — its mark, its name, and a chip of
/// state. A click opens that agent's own page. A hairline card like every
/// other group on the page: no lift, a wash on hover.
private final class AgentTile: NSView {
    let kind: AgentsPane.Kind
    private let chip = HubChip("", .neutral)
    private let wash = ColorView(color: Theme.navHover)

    init(_ kind: AgentsPane.Kind) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(12)
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        toolTip = "Open \(kind.paneTitle)"

        wash.isHidden = true
        wash.fill(self)

        // Stacked, not side by side: at the window's narrowest a tile is
        // too slim for the mark and "Coming soon" on one line.
        let well = MarkWell(kind, muted: kind.agent == nil)
        let name = Hub.text(kind.paneTitle, 13.5, .medium)
        let column = Theme.vstack([well, name, chip], spacing: Theme.m(6))
        column.setCustomSpacing(Theme.m(12), after: well)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: Theme.m(14)),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(14)),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.m(14)),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.m(14)),
        ])
        refresh(live: 0)
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh(live: Int) {
        let (word, tone) = kind.state(live: live)
        chip.set(word, tone)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInActiveApp],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { wash.isHidden = false }
    override func mouseExited(with event: NSEvent) { wash.isHidden = true }
    override func mouseDown(with event: NSEvent) { SettingsUI.shared.select(kind.key) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Theme.surface.cgColor
        layer?.borderColor = Theme.hairline.cgColor
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// An agent's mark in a small sunk square — the tile's face, and the lead
/// of every row that names an agent.
private final class MarkWell: NSView {
    init(_ kind: AgentsPane.Kind, side: CGFloat = 32, muted: Bool = false) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(side / 4)
        let icon = NSImageView()
        icon.image = kind.mark(Theme.m(side * 0.56))
        icon.contentTintColor = muted ? Theme.muted : Theme.ink
        icon.imageScaling = .scaleNone
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Theme.m(side)),
            heightAnchor.constraint(equalToConstant: Theme.m(side)),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Theme.wellFill.cgColor }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// Lately: the agent, and how much you have talked to it.
private final class LatelyRow: NSView {
    init(_ kind: AgentsPane.Kind, tally: String) {
        super.init(frame: .zero)
        let name = RowText.title(kind.paneTitle)
        let left = Theme.hstack([MarkWell(kind, side: 24), name], spacing: Theme.m(10))
        let meta = Theme.meta(tally, 12, Theme.muted)
        splitRow(left, meta, into: self, vertical: 0)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// A session you can pick up again: its name, which session and when, the
/// last thing it said, and the button that carries your next words there.
/// What the agent said is the agent talking, so it is set as body text, a
/// shade under ink.
private final class SessionRow: NSView {
    init(title: String, meta: String, said: String? = nil, live: Bool = false,
         kind: AgentsPane.Kind? = nil, resume: @escaping () -> Void) {
        super.init(frame: .zero)
        var titleParts: [NSView] = [RowText.title(title)]
        if live { titleParts.append(HubChip("Live", .live)) }
        let titleRow = Theme.hstack(titleParts, spacing: Theme.m(8))
        let metaLine = Theme.meta(meta, 11.5, Theme.muted)
        // Truncate rather than shove, like every other line here.
        metaLine.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        var column: [NSView] = [titleRow, metaLine]
        var line: NSTextField?
        if let said = said, !said.isEmpty {
            let f = Hub.para(said, 12, .regular, Theme.ink2, lineHeight: 1.3)
            f.maximumNumberOfLines = 2
            f.lineBreakMode = .byTruncatingTail
            line = f
            column.append(f)
        }
        let words = Theme.vstack(column, spacing: Theme.m(2))
        if line != nil { words.setCustomSpacing(Theme.m(5), after: column[1]) }
        let left: NSView
        if let kind = kind {
            let lead = Theme.hstack([MarkWell(kind, side: 24), words], spacing: Theme.m(10))
            lead.alignment = .top
            lead.distribution = .fill
            words.setHuggingPriority(.init(1), for: .horizontal)
            left = lead
        } else {
            left = words
        }
        let button = FlatButton("Continue by voice", onClick: resume)
        splitRow(left, Theme.hstack([button], spacing: 0), into: self, vertical: 0)
        line?.widthAnchor.constraint(equalTo: words.widthAnchor).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Grouped rows (Agents, Tones and Help)

/// Sizes read off the refresh mockup, in and out. `Theme.text` and
/// `Theme.para` take the older prototype's pixels, which run 1.2 × smaller
/// than the refresh's, so a refresh size goes through them scaled back up —
/// the same points `Theme.m` gives, and the same Text size behaviour.
enum Hub {
    static func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular,
                     _ color: NSColor = Theme.ink) -> NSTextField {
        Theme.text(s, size * 1.2, weight, color)
    }

    static func para(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular,
                     _ color: NSColor = Theme.muted, lineHeight: CGFloat = 1.4) -> NSTextField {
        Theme.para(s, size * 1.2, weight, color, lineHeight: lineHeight)
    }

    /// Words somebody said, wrapping, in the face every list sets them in
    /// (`Theme.saidFont`) — SF, not the serif, which is kept for figures and
    /// hero headlines.
    static func said(_ s: String, _ size: CGFloat, _ color: NSColor = Theme.ink,
                     lineHeight: CGFloat = 1.3) -> NSTextField {
        let f = para(s, size, .regular, color, lineHeight: lineHeight)
        let font = Theme.saidFont(size)
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = lineHeight
        f.font = font
        f.attributedStringValue = NSAttributedString(string: s, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: style,
        ])
        return f
    }

    /// A section's heading, in the app's own face: the title, anything
    /// that rides beside it (a chip), and the line that says what it is.
    static func head(_ title: String, _ subtitle: String? = nil, accessories: [NSView] = [],
                     trailing: NSView? = nil) -> NSView {
        let row = Theme.hstack([Theme.display(title, 15, .medium, tracking: -0.005)] + accessories
                               + [Theme.spacer()] + (trailing.map { [$0] } ?? []),
                               spacing: Theme.m(10))
        // Fill, so the spacer takes the slack and a trailing view sits at
        // the right edge instead of in the leading gravity area.
        row.distribution = .fill
        guard let subtitle = subtitle else { return row }
        let sub = para(subtitle, 12)
        let column = Theme.vstack([row, sub], spacing: Theme.m(3))
        row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        sub.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return column
    }

    /// Heading over body, with an optional footnote under the body.
    static func section(_ head: NSView, _ body: NSView, foot: NSView? = nil) -> NSView {
        var parts = [head, body]
        if let foot = foot { parts.append(foot) }
        let column = Theme.vstack(parts, spacing: Theme.m(10))
        for v in parts { v.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        return column
    }

    /// A line under a group, nudged in to the rows' text edge.
    static func inset(_ view: NSView) -> NSView {
        let host = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: Theme.m(16)),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -Theme.m(16)),
        ])
        return host
    }

    /// The one line a group holds while it has nothing else.
    static func note(_ s: String) -> NSView { para(s, 12.5, .regular, Theme.muted) }

    /// The pane's column, spaced the way the refresh spaces its blocks.
    @discardableResult
    static func scroll(_ views: [NSView]) -> NSScrollView {
        let scroll = makeCardScroll(views)
        (scroll.documentView?.subviews.first as? NSStackView)?.spacing = Theme.m(22)
        return scroll
    }
}

/// One grouped container: surface, a hairline, radius 12, no shadow. Its
/// rows sit on inset rules, the System Settings way, and the corners clip
/// so a hovered row's wash follows them.
final class HubGroup: NSView {
    private let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(12)
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.fill(self)
    }
    required init?(coder: NSCoder) { fatalError() }

    var isEmpty: Bool { stack.arrangedSubviews.isEmpty }

    /// Adds a row under an inset rule. A padded row gets the group's
    /// gutters and the 44-point floor; a flush one (a row that paints its
    /// own hover) brings its own.
    func add(_ row: NSView, padded: Bool = true, padY: CGFloat = 9) {
        if !isEmpty { place(HubRule()) }
        guard padded else { place(row); return }
        let host = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: Theme.m(16)),
            row.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -Theme.m(16)),
            row.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            row.topAnchor.constraint(greaterThanOrEqualTo: host.topAnchor, constant: Theme.m(padY)),
            host.heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.m(44)),
        ])
        let hug = row.topAnchor.constraint(equalTo: host.topAnchor, constant: Theme.m(padY))
        hug.priority = .defaultHigh
        hug.isActive = true
        place(host)
    }

    func removeAll() { stack.arrangedSubviews.forEach { $0.removeFromSuperview() } }

    private func place(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Theme.surface.cgColor
        layer?.borderColor = Theme.hairline.cgColor
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// The rule between two rows: hairsoft, starting at the text's edge.
private final class HubRule: NSView {
    init() {
        super.init(frame: .zero)
        let line = ColorView(color: Theme.hairsoft)
        line.translatesAutoresizingMaskIntoConstraints = false
        addSubview(line)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 1),
            line.topAnchor.constraint(equalTo: topAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(16)),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// A state chip that can change its word — the shared GrantChip, swapped
/// in place, so the Agents chips are the Settings chips: live is ember and
/// appears only while something is live, ok is moss, warn is amber,
/// neutral is a sunk grey.
final class HubChip: NSView {
    enum Tone { case live, ok, warn, neutral }
    private var chip: GrantChip?

    init(_ text: String, _ tone: Tone) {
        super.init(frame: .zero)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        set(text, tone)
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ text: String, _ tone: Tone) {
        chip?.removeFromSuperview()
        let look: GrantChip.Look
        switch tone {
        case .live:    look = .live
        case .ok:      look = .ok
        case .warn:    look = .warn
        case .neutral: look = .neutral
        }
        let made = GrantChip(text, look)
        made.fill(self)
        chip = made
    }
}
