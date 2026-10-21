import AppKit

/// The agent voice's conversation on screen: a chat card in the bottom
/// right corner. The header names the session the way the Claude app's own
/// sidebar does — the owner's mark, then its name / folder / title — SayCtrl's
/// lines sit on the left and arrive a sentence at a time as the audio
/// reaches them, the user's lines sit on the right, and a × closes the
/// episode. While the agent's mic is open the card absorbs the pill: the
/// nine ember bars and the timer live in a strip at the card's foot, and
/// the live transcription types itself into a forming bubble — the pill
/// has nothing left to say and goes invisible (see AppDelegate). While the
/// voice talks, the same strip carries WHITE bars: ember is the user's
/// voice, white the agent's. What the user said is set in the serif, the
/// agent's side in the sans. The card never takes focus (a non-activating
/// panel) and leaves a second after the episode ends.
final class AgentPanel {
    static let shared = AgentPanel()

    private static let width: CGFloat = 400
    private static let pad: CGFloat = 12
    private static let bubbleMax: CGFloat = 312
    private static let margin: CGFloat = 18
    private static let footH: CGFloat = 36
    private let panel: NSPanel
    private let glass: NSView
    private let headerIcon: NSImageView
    private let headerLabel: NSTextField
    private let closeButton: NSButton
    private let body: NSView
    private let foot: AgentFootView
    private var hideTimer: Timer?
    /// What the × does — set by the bridge.
    var onClose: (() -> Void)?

    private enum Who { case sayctrl, user, note, list }
    /// One session as its own little card on the stack — number badge,
    /// name, when, and the last thing it said.
    private struct AgentCard {
        let n: Int
        let title: String
        let sub: String
        let preview: String
        /// Whose session this is — the card wears the owner's mark.
        let agent: AgentKind
        /// When this card lands. The cards pop in one after another, and
        /// the schedule lives in the data so re-renders don't reset it.
        let appearAt: Date
    }
    private struct Line {
        let who: Who
        var sentences: [String]
        var shown: Int      // how many sentences are visible
        var card: AgentCard? = nil
        /// Still being spoken by the user — the live transcription typing
        /// itself in. heard() swaps it for the real bubble.
        var forming = false
        /// A closing line ("Sent.") earns a moss ✓ once fully shown.
        var tick = false
    }
    private var lines: [Line] = []
    /// SayCtrl's own dialogs ("Agents", "New session") wear the pill's
    /// mark and a plain name; a session episode wears its owner's.
    private enum Header { case plain(String), session(agent: AgentKind, folder: String, title: String) }
    private var header: Header = .plain("")
    /// The foot strip is on while a reply is being taken or carried.
    private(set) var footOn = false
    private var me: String {
        let first = Account.name.split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? "You" : first
    }

    private static let ink = PillView.glassInk
    /// The user's own words wear the serif, here as everywhere.
    private static let saidFont: NSFont = {
        let base = NSFont.systemFont(ofSize: 14)
        return base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: 14) } ?? base
    }()
    private static let sayTint = NSColor(srgbRed: 0.48, green: 0.72, blue: 1.0, alpha: 1)
    private static let youTint = NSColor(srgbRed: 1.0, green: 0.78, blue: 0.45, alpha: 1)
    private static let claudeTint = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)   // #D97757

    /// The owners' marks, colored for the dark glass. The drawings live in
    /// AgentMark (end of this file) so the settings sidebar can wear the
    /// same shapes as tinted templates.
    private static let claudeMark = AgentMark.starburst(14, color: claudeTint)
    private static let codexMark = AgentMark.blossom(14, color: NSColor(white: 0.92, alpha: 1))

    /// The mark for whichever agent owns a session — worn by the header
    /// and by each card in the "which one?" list, where two agents now
    /// report into one stack and the folder name alone can't say whose.
    private static func mark(for agent: AgentKind) -> NSImage {
        agent == .codex ? codexMark : claudeMark
    }

    /// SayCtrl's mark for its own dialogs: the pill's bars, at rest — the
    /// logo's three rising bars, in ink, not ember (nothing is live).
    private static let sayMark: NSImage = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { r in
        PillView.drawMark(in: r, vertical: false, color: ink.withAlphaComponent(0.7))
        return true
    }

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 120),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        // One notch below the pill family (.screenSaver): the pill hides
        // while the agent listens now, but a notice HUD can still appear —
        // it must sit on top of this card, not vanish behind it.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = false   // the × is clickable; nothing else cares
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)

        glass = PillView.glassBackdrop(cornerRadius: 16)
        glass.frame = panel.contentView!.bounds
        glass.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(glass)

        headerIcon = NSImageView()
        headerIcon.imageScaling = .scaleProportionallyDown
        panel.contentView?.addSubview(headerIcon)

        headerLabel = NSTextField(labelWithString: "")
        headerLabel.lineBreakMode = .byTruncatingTail
        panel.contentView?.addSubview(headerLabel)

        closeButton = NSButton(title: "", target: nil, action: nil)
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        closeButton.contentTintColor = Self.ink.withAlphaComponent(0.6)
        closeButton.imageScaling = .scaleProportionallyDown
        panel.contentView?.addSubview(closeButton)

        body = NSView()
        panel.contentView?.addSubview(body)

        foot = AgentFootView()
        foot.isHidden = true
        panel.contentView?.addSubview(foot)

        closeButton.target = self
        closeButton.action = #selector(closeTapped)
    }

    @objc private func closeTapped() {
        let cb = onClose
        voiceStopped(render: false)
        lines.removeAll()
        panel.orderOut(nil)
        cb?()
    }

    // MARK: What goes on it

    /// A fresh episode under SayCtrl's own name ("Agents", "New session").
    func begin(header: String, saying s: String) {
        self.header = .plain(header)
        start(saying: s)
    }

    /// A fresh session episode: the owner's mark, then its name / folder /
    /// title. The title is the session's own — the one the app's sidebar
    /// shows — with the short id filling in until a session earns one.
    func begin(folder: String, title: String, agent: AgentKind = .claude, saying s: String) {
        header = .session(agent: agent, folder: folder, title: title)
        start(saying: s)
    }

    private func start(saying s: String) {
        hideTimer?.invalidate()
        footOn = false
        lines = s.isEmpty ? [] : [Line(who: .sayctrl, sentences: Self.sentences(of: s), shown: 0)]
        if !s.isEmpty { voiceStarted() }
        render()
    }

    /// Another SayCtrl line in the same episode ("Anything else?"). The
    /// voice is talking, so the mic strip hands over to the voice's white
    /// bars; a `tick` line ("Sent.") wears the moss ✓ once its audio has
    /// fully played.
    func say(_ s: String, tick: Bool = false) {
        hideTimer?.invalidate()
        footOn = false
        lines.removeAll { $0.who == .note || $0.forming }
        lines.append(Line(who: .sayctrl, sentences: Self.sentences(of: s), shown: 0, tick: tick))
        voiceStarted()
        render()
    }

    /// More of the line being spoken: an update's summary joins its
    /// "… finished." in the same bubble, each sentence shown as it is heard.
    func extend(_ s: String) {
        hideTimer?.invalidate()
        lines.removeAll { $0.who == .note }
        guard let i = lines.lastIndex(where: { $0.who == .sayctrl }) else { return say(s) }
        lines[i].sentences += Self.sentences(of: s)
        render()
    }

    // MARK: The voice's bars

    private var voiceTimer: Timer?
    private var voiceSince = Date.distantPast
    private var voiceHeard = false

    /// A line is going out loud: the foot carries the voice's white bars
    /// until it stops. VoiceIO is asked rather than told — the bridge starts
    /// the audio a beat after the words land here, and a line that never
    /// gets audio (the voice off, a cut) lets the foot go after a second.
    private func voiceStarted() {
        voiceSince = Date()
        voiceHeard = false
        foot.live = false
        foot.speaking = true
        foot.label = "Speaking…"
        footOn = true
        guard voiceTimer == nil else { return }
        voiceTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            self?.voiceTick()
        }
    }

    private func voiceTick() {
        // The mic or a status took the strip over: nothing left to animate.
        guard footOn, foot.speaking else { return voiceStopped(render: false) }
        if VoiceIO.shared.speaking {
            voiceHeard = true
        } else if voiceHeard || Date().timeIntervalSince(voiceSince) > 1.2 {
            return voiceStopped(render: true)
        }
        foot.phase += 0.30
        foot.needsDisplay = true
    }

    private func voiceStopped(render again: Bool) {
        voiceTimer?.invalidate()
        voiceTimer = nil
        guard foot.speaking else { return }
        foot.speaking = false
        footOn = false
        if again { render() }
    }

    /// The fraction of the current SayCtrl line's audio that has played.
    func progress(_ fraction: Double) {
        guard let i = lines.lastIndex(where: { $0.who == .sayctrl }) else { return }
        let total = lines[i].sentences.reduce(0) { $0 + $1.count }
        guard total > 0 else { return }
        var acc = 0
        var n = 0
        for s in lines[i].sentences {
            // A sentence shows as its first words are heard, not its last.
            if Double(acc) / Double(total) <= fraction + 0.02 { n += 1 }
            acc += s.count
        }
        n = max(n, 1)
        if fraction >= 0.999 { n = lines[i].sentences.count }
        // A line that grew (extend) makes the fraction fall back; what was
        // shown stays shown.
        n = max(n, lines[i].shown)
        guard n != lines[i].shown else { return }
        lines[i].shown = n
        render()
    }

    /// Everything of the current line, now — it was cut off, or it is a
    /// line with no audio pacing.
    func revealAll() {
        var changed = false
        for i in lines.indices where lines[i].shown != lines[i].sentences.count {
            lines[i].shown = lines[i].sentences.count
            changed = true
        }
        if changed { render() }
    }

    /// What the user said — the settled bubble. Takes the forming one's
    /// place if the live stream had been typing it in.
    func heard(_ s: String) {
        hideTimer?.invalidate()
        revealAll()
        lines.removeAll { $0.who == .note || $0.forming }
        lines.append(Line(who: .user, sentences: [s], shown: 1))
        render()
    }

    /// The live transcription so far, typing itself into the chat while
    /// the user is still talking: a bubble that isn't a message yet —
    /// dashed edge, ember-warm caret — where the reply will land.
    func forming(_ s: String) {
        guard !s.isEmpty else { return }
        hideTimer?.invalidate()
        if let i = lines.lastIndex(where: { $0.forming }) {
            lines[i] = Line(who: .user, sentences: [s], shown: 1, forming: true)
        } else {
            revealAll()
            lines.removeAll { $0.who == .note }
            lines.append(Line(who: .user, sentences: [s], shown: 1, forming: true))
        }
        render()
    }

    /// A capture that came to nothing takes its half-bubble with it.
    func dropForming() {
        let n = lines.count
        lines.removeAll { $0.forming }
        if lines.count != n { render() }
    }

    // MARK: The absorbed pill (the foot strip)

    /// The agent's mic opened (or closed): the pill's bars and timer live
    /// in the card's foot for the duration. `label` names the mode —
    /// "Listening…", "Listening (key)…".
    func listening(_ on: Bool, label: String = "Listening…") {
        if on {
            hideTimer?.invalidate()
            if !(footOn && foot.live) { foot.startedAt = Date() }
            foot.speaking = false
            foot.live = true
            foot.label = label
            footOn = true
        } else {
            footOn = false
            dropForming()
        }
        render()
    }

    /// The strip between hearing and answering: bars flat and gray, the
    /// label saying what is in flight — "…" for the transcript,
    /// "Sending…" for the reply on its way.
    func footStatus(_ s: String) {
        hideTimer?.invalidate()
        foot.speaking = false
        foot.live = false
        foot.label = s
        footOn = true
        render()
    }

    /// The mic level and wobble phase, from the same 24 fps tick that
    /// drives the pill — one heartbeat for every copy of the bars.
    func tickFoot(level: CGFloat, phase: CGFloat) {
        guard footOn, foot.live else { return }
        foot.level = level
        foot.phase = phase
        foot.needsDisplay = true
    }

    /// The recent sessions, numbered, for "which one?" — read, not spoken.
    func list(_ rows: [String]) {
        hideTimer?.invalidate()
        lines.removeAll { $0.who == .note || $0.who == .list }
        for r in rows { lines.append(Line(who: .list, sentences: [r], shown: 1)) }
        render()
    }

    /// The sessions as their own numbered cards, landing on the stack one
    /// after another — "which one?" deals a hand, not a wall of text.
    /// Card 1 — the freshest session — sits at the BOTTOM, by the pill:
    /// the panel clips from the top when the hand is big, so what falls
    /// off is the high numbers, not the sessions the user is about to
    /// name. The deal still starts with 1, each card landing above the
    /// last.
    func listCards(_ items: [(title: String, sub: String, preview: String, agent: AgentKind)]) {
        hideTimer?.invalidate()
        lines.removeAll { $0.who == .note || $0.who == .list }
        let first = Date().addingTimeInterval(0.05)
        for (i, item) in items.enumerated().reversed() {
            lines.append(Line(who: .list, sentences: [item.title], shown: 1,
                              card: AgentCard(n: i + 1, title: item.title, sub: item.sub,
                                              preview: item.preview, agent: item.agent,
                                              appearAt: first.addingTimeInterval(0.15 * Double(i)))))
        }
        render()
    }

    /// A short status, not spoken ("Hold the key to reply"). One at a
    /// time, always last.
    func note(_ s: String) {
        hideTimer?.invalidate()
        revealAll()
        if let last = lines.last, last.who == .note, last.sentences == [s] { return }
        lines.removeAll { $0.who == .note }
        lines.append(Line(who: .note, sentences: [s], shown: 1))
        render()
    }

    func dismiss(after seconds: TimeInterval) {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.voiceStopped(render: false)
            self?.lines.removeAll()
            self?.panel.orderOut(nil)
        }
    }

    func hideNow() {
        hideTimer?.invalidate()
        voiceStopped(render: false)
        footOn = false
        lines.removeAll()
        panel.orderOut(nil)
    }

    /// A screenshot taken for a reply is of the user's work — the card
    /// leaves the picture for the moment of capture and comes right back.
    func concealed(_ on: Bool) {
        panel.alphaValue = on ? 0 : 1
    }

    /// The card as it stands, for --snapshot (Snapshots.swift).
    var snapshotView: NSView? { panel.contentView }

    // MARK: Drawing

    private static func sentences(of s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in s {
            cur.append(ch)
            if ".!?".contains(ch) {
                let t = cur.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { out.append(t) }
                cur = ""
            }
        }
        let t = cur.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { out.append(t) }
        return out.isEmpty ? [s] : out
    }

    /// A session's card: number badge, name, when, and its last line.
    private func cardBox(_ c: AgentCard) -> (NSView, NSSize) {
        let w = Self.width - Self.pad * 2
        let inset: CGFloat = 12
        let badgeSize: CGFloat = 26
        let textX = inset + badgeSize + 10
        let textW = w - textX - inset

        let title = NSTextField(labelWithString: c.title)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Self.ink
        title.lineBreakMode = .byTruncatingTail

        let sub = NSTextField(labelWithString: c.sub)
        sub.font = .systemFont(ofSize: 11, weight: .regular)
        sub.textColor = Self.ink.withAlphaComponent(0.5)
        sub.lineBreakMode = .byTruncatingTail

        let preview = NSTextField(wrappingLabelWithString: c.preview)
        preview.font = .systemFont(ofSize: 12)
        preview.textColor = Self.ink.withAlphaComponent(0.8)
        preview.isSelectable = false
        preview.maximumNumberOfLines = 2
        preview.lineBreakMode = .byTruncatingTail
        let previewH: CGFloat = c.preview.isEmpty ? 0
            : min(ceil(preview.sizeThatFits(NSSize(width: textW, height: 100)).height), 34)

        let h = inset + 16 + 2 + 13 + (previewH > 0 ? 5 + previewH : 0) + inset
        let box = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        box.wantsLayer = true
        box.layer?.cornerRadius = 14
        box.layer?.cornerCurve = .continuous
        box.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor

        let badge = NSView(frame: NSRect(x: inset, y: h - inset - badgeSize, width: badgeSize, height: badgeSize))
        badge.wantsLayer = true
        badge.layer?.cornerRadius = badgeSize / 2
        badge.layer?.backgroundColor = Self.sayTint.withAlphaComponent(0.18).cgColor
        let digit = NSTextField(labelWithString: "\(c.n)")
        digit.font = .systemFont(ofSize: 12, weight: .bold)
        digit.textColor = Self.sayTint
        digit.sizeToFit()
        digit.frame.origin = NSPoint(x: (badgeSize - digit.frame.width) / 2,
                                     y: (badgeSize - digit.frame.height) / 2)
        badge.addSubview(digit)
        box.addSubview(badge)

        // The owner's mark rides the title row's right edge — Claude's
        // starburst or Codex's blossom, saying whose session this card is.
        let markSize: CGFloat = 14
        let mark = NSImageView(frame: NSRect(x: w - inset - markSize,
                                             y: h - inset - 16 + (16 - markSize) / 2,
                                             width: markSize, height: markSize))
        mark.image = Self.mark(for: c.agent)
        mark.imageScaling = .scaleProportionallyUpOrDown
        box.addSubview(mark)

        title.frame = NSRect(x: textX, y: h - inset - 16, width: textW - markSize - 8, height: 16)
        sub.frame = NSRect(x: textX, y: h - inset - 16 - 2 - 13, width: textW, height: 13)
        box.addSubview(title)
        box.addSubview(sub)
        if previewH > 0 {
            preview.frame = NSRect(x: textX, y: inset, width: textW, height: previewH)
            box.addSubview(preview)
        }
        return (box, box.frame.size)
    }

    /// One bubble: a rounded backdrop and a wrapped label. Returns its size.
    private func bubble(for line: Line) -> (NSView, NSSize) {
        if let card = line.card { return cardBox(card) }
        // What the user said is theirs: the serif. The agent's side, the
        // notes and the lists stay in the sans.
        let font = line.who == .user ? Self.saidFont : NSFont.systemFont(ofSize: 13, weight: .regular)
        let inset: CGFloat = 10
        let text: String
        switch line.who {
        case .note, .list: text = line.sentences.joined(separator: " ")
        default:
            let shown = line.sentences.prefix(line.shown).joined(separator: " ")
            text = shown.isEmpty ? "…" : shown
        }
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.isSelectable = false
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        // The forming bubble's live ember dot and the closing line's
        // moss ✓ ride in the string itself, so the wrap measures them.
        if line.forming {
            let a = NSMutableAttributedString(string: text + " ", attributes: [
                .font: font, .foregroundColor: Self.ink.withAlphaComponent(0.9)])
            a.append(NSAttributedString(string: "●", attributes: [
                .font: NSFont.systemFont(ofSize: 8), .foregroundColor: PillView.emberBar]))
            label.attributedStringValue = a
        } else if line.tick, line.shown == line.sentences.count {
            let a = NSMutableAttributedString(string: text + "  ", attributes: [
                .font: font, .foregroundColor: Self.ink])
            a.append(NSAttributedString(string: "✓", attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .bold),
                .foregroundColor: PillView.mossBadge]))
            label.attributedStringValue = a
        }
        let maxText = (line.who == .note || line.who == .list ? Self.width - Self.pad * 2 : Self.bubbleMax) - inset * 2
        let size = label.sizeThatFits(NSSize(width: maxText, height: 2000))
        let w = min(max(size.width, 24), maxText)
        let h = ceil(size.height)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: w + inset * 2, height: h + inset * 2 - 2))
        box.wantsLayer = true
        box.layer?.cornerRadius = 12
        box.layer?.cornerCurve = .continuous
        switch line.who {
        case .sayctrl:
            box.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
            label.textColor = Self.ink
        case .user:
            box.layer?.backgroundColor = Self.youTint.withAlphaComponent(0.18).cgColor
            label.textColor = Self.ink
        case .note:
            box.layer?.backgroundColor = .clear
            label.textColor = Self.ink.withAlphaComponent(0.5)
            label.alignment = .center
        case .list:
            box.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
            label.textColor = Self.ink.withAlphaComponent(0.85)
            label.font = .systemFont(ofSize: 12, weight: .regular)
        }
        if line.forming {
            // Not a message yet: faint fill and a dashed amber edge (a
            // layer border can't dash, so a shape layer draws it).
            box.layer?.backgroundColor = Self.youTint.withAlphaComponent(0.08).cgColor
            let edge = CAShapeLayer()
            edge.path = CGPath(roundedRect: box.bounds.insetBy(dx: 0.5, dy: 0.5),
                               cornerWidth: 11.5, cornerHeight: 11.5, transform: nil)
            edge.strokeColor = Self.youTint.withAlphaComponent(0.45).cgColor
            edge.fillColor = nil
            edge.lineWidth = 1
            edge.lineDashPattern = [4, 3]
            box.layer?.addSublayer(edge)
        }
        label.frame = NSRect(x: inset, y: inset - 1, width: w, height: h)
        box.addSubview(label)
        return (box, box.frame.size)
    }

    /// The header's mark and words for the current mode.
    private func headerContent() -> (NSImage, NSAttributedString) {
        switch header {
        case .plain(let s):
            return (Self.sayMark, NSAttributedString(
                string: s.isEmpty ? "SayControl" : s,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: Self.ink.withAlphaComponent(0.55),
                ]))
        case .session(let agent, let folder, let title):
            let sep: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: Self.ink.withAlphaComponent(0.28),
            ]
            let a = NSMutableAttributedString(string: agent.display, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
                .foregroundColor: Self.ink.withAlphaComponent(0.92),
            ])
            a.append(NSAttributedString(string: "  /  ", attributes: sep))
            a.append(NSAttributedString(string: folder, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular),
                .foregroundColor: PillView.glassMuted,
            ]))
            a.append(NSAttributedString(string: "  /  ", attributes: sep))
            a.append(NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .regular),
                .foregroundColor: Self.ink.withAlphaComponent(0.68),
            ]))
            return (Self.mark(for: agent), a)
        }
    }

    private func render() {
        body.subviews.forEach { $0.removeFromSuperview() }
        let screen = mouseScreen().visibleFrame
        let maxBody = screen.height * 0.45
        let nameFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let gap: CGFloat = 8
        let nameH: CGFloat = 14

        // Build from the newest line up, so when the card is full it is the
        // oldest that goes.
        var placed: [(NSView, NSView?, CGFloat, Line)] = []   // bubble, name label, row height, its line
        var total: CGFloat = 0
        for line in lines.reversed() {
            let (box, size) = bubble(for: line)
            var name: NSView?
            var rowH = size.height
            if line.who == .sayctrl || line.who == .user {
                let l = NSTextField(labelWithString: line.who == .sayctrl ? "SayControl" : me)
                l.font = nameFont
                l.textColor = line.who == .sayctrl ? Self.sayTint : Self.youTint
                l.sizeToFit()
                name = l
                rowH += nameH
            }
            if total + rowH + (placed.isEmpty ? 0 : gap) > maxBody, !placed.isEmpty { break }
            total += rowH + (placed.isEmpty ? 0 : gap)
            placed.append((box, name, rowH, line))
        }
        // Lay out top-down in the original order.
        var y = total
        for (box, name, rowH, line) in placed.reversed() {
            y -= rowH
            let isUser = line.who == .user
            let x: CGFloat
            switch line.who {
            case .user: x = Self.width - Self.pad * 2 - box.frame.width
            case .note: x = (Self.width - Self.pad * 2 - box.frame.width) / 2
            case .sayctrl, .list: x = 0
            }
            if let name = name {
                name.frame.origin = NSPoint(x: isUser ? Self.width - Self.pad * 2 - name.frame.width : 0, y: y + rowH - nameH + 1)
                body.addSubview(name)
            }
            box.frame.origin = NSPoint(x: x, y: y)
            body.addSubview(box)
            // A card lands when its schedule says so — invisible until its
            // moment, then a short rise-and-fade in. The schedule lives on
            // the line, so the re-renders in between don't reset the deal.
            if let card = line.card, card.appearAt.timeIntervalSinceNow > 0 {
                let targetY = box.frame.origin.y
                box.alphaValue = 0
                box.frame.origin.y = targetY - 8
                DispatchQueue.main.asyncAfter(deadline: .now() + card.appearAt.timeIntervalSinceNow) { [weak box] in
                    guard let box = box, box.superview != nil else { return }
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.3
                        ctx.allowsImplicitAnimation = true
                        box.animator().alphaValue = 1
                        box.animator().frame.origin.y = targetY
                    }
                }
            }
            y -= gap
        }

        let headerH: CGFloat = 24
        let footSpace: CGFloat = footOn ? Self.footH + 8 : 0
        let height = Self.pad + headerH + (total > 0 ? 6 + total : 0) + footSpace + Self.pad
        let origin = NSPoint(x: screen.maxX - Self.width - Self.margin, y: screen.minY + Self.margin)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: Self.width, height: height)), display: true)
        body.frame = NSRect(x: Self.pad, y: Self.pad + footSpace, width: Self.width - Self.pad * 2, height: total)
        foot.isHidden = !footOn
        if footOn {
            foot.frame = NSRect(x: Self.pad, y: Self.pad, width: Self.width - Self.pad * 2, height: Self.footH)
            foot.needsDisplay = true
        }
        let (icon, words) = headerContent()
        headerIcon.image = icon
        headerIcon.frame = NSRect(x: Self.pad + 2, y: height - Self.pad - headerH + 5, width: 14, height: 14)
        headerLabel.attributedStringValue = words
        headerLabel.frame = NSRect(x: Self.pad + 2 + 14 + 7, y: height - Self.pad - headerH + 4,
                                   width: Self.width - Self.pad * 2 - 30 - 21, height: 16)
        closeButton.frame = NSRect(x: Self.width - Self.pad - 18, y: height - Self.pad - headerH + 3, width: 18, height: 18)
        panel.invalidateShadow()
        if !lines.isEmpty || footOn { panel.orderFrontRegardless() }
    }
}

/// The pill, absorbed: while the agent's mic is open this strip at the
/// card's foot carries the same nine ember bars and quiet mono timer the
/// pill shows — one voice-input identity, living wherever the listening
/// actually is. Quiet mode (bars flat and gray) walks the reply out: "…"
/// while the transcript renders, "Sending…" while it travels. Speaking
/// mode is the other voice: white bars while SayCtrl's voice plays.
final class AgentFootView: NSView {
    var live = false
    /// The agent's voice is playing: white bars on a neutral strip, so it
    /// can't be read as the mic being open.
    var speaking = false
    var label = "Listening…"
    var startedAt = Date()
    var level: CGFloat = 0
    var phase: CGFloat = 0

    /// Made once — this view draws 24 times a second while listening, and
    /// per-frame font lookups are what crashed the app (see PillView).
    private static let timerFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
    private static let noteFont = NSFont.systemFont(ofSize: 12, weight: .medium)

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        let back = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 11, yRadius: 11)
        if live {
            PillView.emberBar.withAlphaComponent(0.09).setFill()
            back.fill()
            PillView.emberBar.withAlphaComponent(0.22).setStroke()
        } else {
            NSColor.white.withAlphaComponent(0.05).setFill()
            back.fill()
            NSColor.white.withAlphaComponent(0.10).setStroke()
        }
        back.lineWidth = 1
        back.stroke()

        let n = 9
        let barW: CGFloat = 2.5
        let gap: CGFloat = 2.5
        let blockW = CGFloat(n) * barW + CGFloat(n - 1) * gap
        let x0: CGFloat = 14
        let mid = CGFloat(n - 1) / 2
        for i in 0..<n {
            let fi = CGFloat(i)
            var h: CGFloat = 3.5
            if live {
                let centerWeight = 1.0 - abs(fi - mid) / mid * 0.45
                let s = sin(phase + fi * 0.85)
                let wobble = 0.30 + 0.70 * s * s
                let effLevel = 0.25 + 0.75 * level
                h = max(3.5, min(3.5 + 13 * effLevel * wobble * centerWeight, 16))
            } else if speaking {
                // No level to follow — the audio plays past the mic — so the
                // bars breathe on their own: each rises and falls over 2.2 s,
                // a sixth of a second behind its neighbor, from 28% of its
                // reach to all of it.
                let reach: [CGFloat] = [5.5, 8, 11.5, 14, 16, 14, 11.5, 8, 5.5]
                let t = phase / 7.2 + fi * 0.17
                h = max(3.5, reach[i] * (0.28 + 0.72 * (0.5 - 0.5 * cos(t * 2 * .pi / 2.2))))
            }
            let bar = NSRect(x: x0 + fi * (barW + gap), y: r.midY - h / 2, width: barW, height: h)
            (live ? PillView.emberBar : speaking ? PillView.voiceWhite : PillView.glassMuted.withAlphaComponent(0.6)).setFill()
            NSBezierPath(roundedRect: bar, xRadius: barW / 2, yRadius: barW / 2).fill()
        }

        var rightEdge = r.maxX - 14
        if live {
            let elapsed = Int(Date().timeIntervalSince(startedAt))
            let timer = NSAttributedString(
                string: String(format: "%d:%02d", elapsed / 60, elapsed % 60),
                attributes: [
                    .font: Self.timerFont,
                    .foregroundColor: PillView.glassInk,
                ])
            let ts = timer.size()
            timer.draw(at: NSPoint(x: rightEdge - ts.width, y: r.midY - ts.height / 2))
            rightEdge -= ts.width + 10
        }

        let note = NSAttributedString(string: label, attributes: [
            .font: Self.noteFont,
            .foregroundColor: PillView.glassMuted,
        ])
        let ns = note.size()
        let nx = x0 + blockW + 10
        note.draw(in: NSRect(x: nx, y: r.midY - ns.height / 2, width: max(0, rightEdge - nx), height: ns.height))
    }
}

// MARK: - The owners' marks

/// The coding agents' brand marks, drawn once and shared by every surface
/// that says whose a session is. The agent voice's card colors them for
/// its dark glass; the settings sidebar takes them with no color — a
/// template image — and tints them like its SF-symbol neighbours.
enum AgentMark {
    /// Claude's starburst, on the panel's original 14-point grid; any
    /// other side scales from there.
    static func starburst(_ side: CGFloat, color: NSColor? = nil) -> NSImage {
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            (color ?? .black).setStroke()
            let k = side / 14
            let c = NSPoint(x: side / 2, y: side / 2)
            for i in 0..<8 {
                let a = CGFloat(i) * .pi / 4
                let ray = NSBezierPath()
                ray.lineWidth = 1.6 * k
                ray.lineCapStyle = .round
                ray.move(to: NSPoint(x: c.x + cos(a) * 2.6 * k, y: c.y + sin(a) * 2.6 * k))
                ray.line(to: NSPoint(x: c.x + cos(a) * 6.4 * k, y: c.y + sin(a) * 6.4 * k))
                ray.stroke()
            }
            return true
        }
        img.isTemplate = color == nil
        return img
    }

    /// Codex's mark, the OpenAI blossom: the official 24-grid vector baked
    /// down to a 14 grid as bezier rows — 2 numbers move, 6 curve, none
    /// close. A weave this involved can't be drawn from first principles
    /// the way the starburst is, so the shape ships as data.
    private static let knot: [[CGFloat]] = [
        [13.00, 8.27], [13.31, 9.22, 13.20, 10.27, 12.70, 11.14],
        [11.93, 12.46, 10.40, 13.15, 8.90, 12.83], [8.05, 13.77, 6.77, 14.18, 5.54, 13.92],
        [4.30, 13.66, 3.30, 12.76, 2.91, 11.56], [1.92, 11.36, 1.07, 10.74, 0.57, 9.87],
        [-0.20, 8.54, -0.02, 6.87, 1.01, 5.73], [0.69, 4.78, 0.80, 3.73, 1.30, 2.86],
        [2.07, 1.53, 3.61, 0.85, 5.10, 1.17], [5.77, 0.42, 6.73, -0.01, 7.73, 0.00],
        [9.27, -0.00, 10.63, 0.99, 11.10, 2.45], [12.09, 2.66, 12.94, 3.27, 13.43, 4.15],
        [14.20, 5.47, 14.02, 7.13, 13.00, 8.27], [], [7.73, 0.92],
        [7.12, 0.92, 6.53, 1.13, 6.06, 1.52], [6.06, 1.52, 6.14, 1.57, 6.14, 1.57],
        [6.14, 1.57, 8.93, 3.18, 8.93, 3.18], [9.07, 3.26, 9.16, 3.41, 9.16, 3.58],
        [9.16, 3.58, 9.16, 7.51, 9.16, 7.51], [9.16, 7.51, 10.33, 6.82, 10.33, 6.82],
        [10.35, 6.82, 10.35, 6.81, 10.36, 6.79], [10.36, 6.79, 10.36, 3.54, 10.36, 3.54],
        [10.35, 2.09, 9.18, 0.92, 7.73, 0.92], [], [2.10, 3.32],
        [1.79, 3.85, 1.68, 4.48, 1.79, 5.08], [1.79, 5.08, 1.87, 5.03, 1.87, 5.03],
        [1.87, 5.03, 4.66, 3.42, 4.66, 3.42], [4.80, 3.34, 4.98, 3.34, 5.12, 3.42],
        [5.12, 3.42, 8.52, 5.39, 8.52, 5.39], [8.52, 5.39, 8.52, 4.03, 8.52, 4.03],
        [8.52, 4.01, 8.52, 4.00, 8.50, 3.99], [8.50, 3.99, 5.68, 2.36, 5.68, 2.36],
        [4.43, 1.64, 2.82, 2.07, 2.10, 3.32], [], [1.37, 9.39],
        [1.68, 9.93, 2.16, 10.34, 2.75, 10.55], [2.75, 10.55, 2.75, 7.23, 2.75, 7.23],
        [2.74, 7.07, 2.83, 6.92, 2.97, 6.84], [2.97, 6.84, 6.36, 4.88, 6.36, 4.88],
        [6.36, 4.88, 5.18, 4.20, 5.18, 4.20], [5.17, 4.19, 5.16, 4.19, 5.14, 4.20],
        [5.14, 4.20, 2.33, 5.83, 2.33, 5.83], [1.07, 6.55, 0.64, 8.15, 1.37, 9.41], [],
        [11.05, 7.15], [11.05, 7.15, 7.64, 9.12, 7.64, 9.12],
        [7.64, 9.12, 8.82, 9.80, 8.82, 9.80], [8.83, 9.81, 8.85, 9.81, 8.86, 9.80],
        [8.86, 9.80, 11.68, 8.17, 11.68, 8.17], [12.56, 7.66, 13.07, 6.69, 12.98, 5.68],
        [12.90, 4.67, 12.24, 3.80, 11.28, 3.44], [11.28, 3.44, 11.28, 6.76, 11.28, 6.76],
        [11.28, 6.92, 11.19, 7.07, 11.05, 7.15], [],
        [12.22, 8.91], [12.22, 8.91, 12.14, 8.96, 12.14, 8.96],
        [12.14, 8.96, 9.35, 10.58, 9.35, 10.58], [9.21, 10.66, 9.04, 10.66, 8.89, 10.58],
        [8.89, 10.58, 5.49, 8.62, 5.49, 8.62], [5.49, 8.62, 5.49, 9.98, 5.49, 9.98],
        [5.49, 9.99, 5.49, 10.00, 5.51, 10.01], [5.51, 10.01, 8.32, 11.64, 8.32, 11.64],
        [9.20, 12.15, 10.30, 12.10, 11.13, 11.52], [11.97, 10.93, 12.39, 9.92, 12.22, 8.92], [],
        [4.85, 6.50], [4.85, 6.50, 3.67, 7.18, 3.67, 7.18], [3.66, 7.18, 3.65, 7.19, 3.64, 7.21],
        [3.64, 7.21, 3.64, 10.46, 3.64, 10.46], [3.65, 11.47, 4.24, 12.40, 5.16, 12.83],
        [6.08, 13.26, 7.17, 13.12, 7.95, 12.47], [7.95, 12.47, 7.86, 12.42, 7.86, 12.42],
        [7.86, 12.42, 5.08, 10.82, 5.08, 10.82], [4.94, 10.73, 4.85, 10.58, 4.85, 10.42], [],
        [5.49, 7.88], [5.49, 7.88, 7.00, 8.75, 7.00, 8.75], [7.00, 8.75, 8.52, 7.88, 8.52, 7.88],
        [8.52, 7.88, 8.52, 6.13, 8.52, 6.13], [8.52, 6.13, 7.01, 5.25, 7.01, 5.25],
        [7.01, 5.25, 5.49, 6.13, 5.49, 6.13], [],
    ]

    static func blossom(_ side: CGFloat, color: NSColor? = nil) -> NSImage {
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let k = side / 14
            let p = NSBezierPath()
            for row in knot {
                switch row.count {
                case 2: p.move(to: NSPoint(x: row[0] * k, y: row[1] * k))
                case 6: p.curve(to: NSPoint(x: row[4] * k, y: row[5] * k),
                                controlPoint1: NSPoint(x: row[0] * k, y: row[1] * k),
                                controlPoint2: NSPoint(x: row[2] * k, y: row[3] * k))
                default: p.close()
                }
            }
            (color ?? .black).setFill()
            p.fill()
            return true
        }
        img.isTemplate = color == nil
        return img
    }
}
