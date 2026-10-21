// The Overview pane — the window opens here. Your numbers and your recent
// words, read from the stores that already exist (history + replacements):
// no new storage. Recent is also what replaced the Activity pane.
//
// Laid out after design/sayctrl-refresh.html: a picture of where it works,
// one number leads (this week's words, in New York), the week is a level
// meter, and the recent rows keep their actions on the row itself instead
// of behind a ⋯.
import Cocoa

// MARK: - The week as a level meter

/// Seven columns of twelve segments, one column per day, all on one scale —
/// the meter on a mixing desk. Today's lit segments are ember; the other
/// days are ink. Every column names the value it reaches.
final class WeekMeterView: TipView, Growable {
    /// 0 empty, 1 the real value: the page's entrance fills it.
    var grow: CGFloat = 1 { didSet { needsDisplay = true } }
    var days: [(label: String, words: Int)] = [] {
        didSet {
            needsDisplay = true
            refreshTips()
        }
    }

    static let segments = 12
    override var isFlipped: Bool { true }

    private var segH: CGFloat { Theme.m(5) }
    private var segGap: CGFloat { Theme.m(3) }
    private var valueH: CGFloat { Theme.m(14) }
    private var labelH: CGFloat { Theme.m(14) }
    private var stackH: CGFloat { CGFloat(Self.segments) * segH + CGFloat(Self.segments - 1) * segGap }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: valueH + Theme.m(6) + stackH + Theme.m(8) + labelH)
    }

    private func column(_ i: Int) -> NSRect {
        let n = max(1, days.count)
        let gap = Theme.m(14)
        let w = (bounds.width - gap * CGFloat(n - 1)) / CGFloat(n)
        return NSRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: bounds.height)
    }

    private func refreshTips() {
        setTips(days.enumerated().map { i, day in
            (column(i), "\(Self.format(day.words)) word\(day.words == 1 ? "" : "s")")
        })
    }

    override func layout() {
        super.layout()
        refreshTips()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !days.isEmpty else { return }
        let peak = max(1, days.map { $0.words }.max() ?? 1)
        for (i, day) in days.enumerated() {
            let c = column(i)
            let today = i == days.count - 1
            // Round to the nearest segment, but a day with any words at all
            // lights at least one — a quiet day is not an empty one.
            var lit = Int((CGFloat(day.words) / CGFloat(peak) * CGFloat(Self.segments)).rounded())
            if day.words > 0 { lit = max(1, lit) }
            if grow < 1 { lit = Int((CGFloat(lit) * grow).rounded(.up)) }

            let valueAttrs: [NSAttributedString.Key: Any] = [
                .font: Theme.digits(10.5, .medium), .foregroundColor: today ? Theme.emberInk : Theme.muted,
            ]
            let value = NSAttributedString(string: Self.format(day.words), attributes: valueAttrs)
            let vs = value.size()
            value.draw(at: NSPoint(x: c.midX - vs.width / 2, y: 0))

            let w = min(c.width, Theme.m(40))
            let top = valueH + Theme.m(6)
            for s in 0..<Self.segments {
                // Segment 0 is the bottom one; lit ones fill from the floor up.
                let y = top + stackH - CGFloat(s + 1) * segH - CGFloat(s) * segGap
                let r = NSRect(x: c.midX - w / 2, y: y, width: w, height: segH)
                let on = s < lit
                (on ? (today ? Theme.ember : Theme.barLit) : Theme.barFill).setFill()
                NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
            }

            let name = NSAttributedString(string: day.label.uppercased(), attributes: [
                .font: NSFont.systemFont(ofSize: Theme.m(10), weight: .medium),
                .foregroundColor: today ? Theme.emberInk : Theme.faint,
                .kern: Theme.m(10.5) * 0.05,
            ])
            let ns = name.size()
            name.draw(at: NSPoint(x: c.midX - ns.width / 2, y: top + stackH + Theme.m(8)))
        }
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    static func format(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

// MARK: - Small pieces

/// A grouped container: surface, one hairline, radius 12, no shadow. The
/// corners clip, so a hovered row's wash follows them.
private final class OverviewBox: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(12)
        layer?.borderWidth = 1
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Theme.surface.cgColor
        layer?.borderColor = Theme.hairline.cgColor
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// A neutral capsule with a glyph — "Kept on this Mac".
private final class QuietChip: NSView {
    init(_ text: String, symbol: String) {
        super.init(frame: .zero)
        wantsLayer = true
        let icon = GlyphView(symbol: symbol, size: Theme.m(9), weight: .semibold, side: Theme.m(11))
        icon.tint = Theme.muted
        let f = Theme.text(text, 11.5, .regular, Theme.muted)
        f.font = .systemFont(ofSize: Theme.m(11.5))
        let row = Theme.hstack([icon, f], spacing: Theme.m(5))
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(9)),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.m(9)),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Theme.m(22)),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Theme.wellFill.cgColor }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// The two-point ember line along a row's foot while its clip plays.
private final class ProgressLine: NSView {
    var fraction: CGFloat? { didSet { isHidden = fraction == nil; needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        guard let f = fraction else { return }
        Theme.ember.setFill()
        NSRect(x: 0, y: 0, width: bounds.width * max(0, min(1, f)), height: bounds.height).fill()
    }
}

// MARK: - A Recent row

/// Time, the words that landed (up to two lines), how many words and how
/// long — and, on hover, what you can do with it: play what you said, copy
/// it, a ⋯ for the rest, delete it.
///
/// The ⋯ holds "Transcribe again" — the kept clip back through the same
/// cloud ear a dictation uses — and "Undo AI polish", which puts the words
/// back the way they were heard. The developers' build adds every model
/// that could hear the clip under "Transcribe again with", so one take can
/// be run through different ears and compared, without saying it again.
/// Every dictation leaves a WAV in ~/.config/sayctrl/recordings
/// (Recordings.swift), so play plays the real audio.
final class RecentRow: NSView, Hoverable {
    /// What the ⋯ asks the Overview to do with the take.
    enum Action {
        /// The clip again: through the cloud (nil), or through one model.
        case transcribe(override: (provider: Provider, model: String, live: Bool)?)
        case undoPolish
    }
    private let audio: String?
    private let text: String
    private let polished: Bool
    /// The model that produced the words standing in the row — the checked
    /// item in the picker, so a comparison never loses track of where it is.
    private let heardBy: String
    private let onAction: (Action) -> Void
    private let onDelete: () -> Void
    private let play: IconButton
    private let more: IconButton
    private let actions: FadeBox
    private let progress = ProgressLine()
    private let rule = ColorView(color: Theme.hairsoft)
    private var progressTimer: Timer?
    private var playing = false
    /// The ⋯ menu is up: the row keeps its actions showing under it.
    private var menuOpen = false
    private var hovering = false {
        didSet {
            actions.shown = hovering || playing || menuOpen
            needsDisplay = true
        }
    }
    /// The first row has no rule above it.
    var isFirst = false { didSet { rule.isHidden = isFirst } }

    init(entry: HistoryEntry, time: String,
         onAction: @escaping (Action) -> Void,
         onDelete: @escaping () -> Void) {
        let text = entry.shown
        self.text = text
        polished = entry.polished != nil
        heardBy = entry.model
        self.onAction = onAction
        self.onDelete = onDelete
        audio = Recordings.shared.url(for: entry.audio) != nil ? entry.audio : nil
        let noAudio = "The audio for this one wasn’t kept"
        play = IconButton("play.fill", size: 31, icon: 11, tip: audio == nil ? noAudio : "Play what you said")
        let copy = IconButton("doc.on.doc", size: 31, icon: 12.5, tip: "Copy")
        more = IconButton("ellipsis", size: 31, icon: 13, tip: "Transcribe again, undo the polish")
        let delete = IconButton("trash", size: 31, icon: 12.5, tip: "Delete")
        actions = FadeBox(Theme.hstack([play, copy, more, delete], spacing: Theme.m(2)))
        super.init(frame: .zero)
        wantsLayer = true
        // Which model heard it is a developer's question. The shipping app
        // doesn't name its engines in passing.
        toolTip = entry.model.isEmpty || Config.retail ? text
            : "\(text)\n\nHeard by \(LocalEngine.entry(entry.model)?.name ?? entry.model)"

        let when = Theme.meta(time, 11.5)
        when.translatesAutoresizingMaskIntoConstraints = false
        when.widthAnchor.constraint(equalToConstant: Theme.m(62)).isActive = true

        // Your words in the interface face, up to two lines — the list reads
        // as what you said, not as a row of truncated fragments.
        let body = WrapLabel(labelWithString: text.replacingOccurrences(of: "\n", with: " "))
        body.font = Theme.saidFont(13.5)
        body.textColor = Theme.ink
        body.maximumNumberOfLines = 2
        body.lineBreakMode = .byWordWrapping
        body.cell?.wraps = true
        body.cell?.truncatesLastVisibleLine = true
        body.cell?.isScrollable = false
        // The words take whatever is left; the meta and the actions keep theirs.
        body.setContentHuggingPriority(.init(1), for: .horizontal)
        body.setContentCompressionResistancePriority(.init(200), for: .horizontal)

        let length = entry.seconds >= 1
            ? String(format: "%d:%02d", Int(entry.seconds) / 60, Int(entry.seconds) % 60)
            : "—"
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        let meta = Theme.meta("\(words) word\(words == 1 ? "" : "s") · \(length)", 11)
        meta.alignment = .right
        meta.setContentHuggingPriority(.required, for: .horizontal)
        meta.setContentCompressionResistancePriority(.required, for: .horizontal)

        play.onClick = { [weak self] in self?.togglePlayback() }
        copy.onClick = { [weak self] in self?.copyWords() }
        more.onClick = { [weak self] in self?.showMore() }
        delete.onClick = { [weak self] in self?.onDelete() }
        if audio == nil { play.alphaValue = 0.35 }

        let row = Theme.hstack([when, body, meta, actions], spacing: Theme.m(14))
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        for v in [rule, progress] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        progress.isHidden = true
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(16)),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.m(8)),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: Theme.m(11)),
            heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.m(46)),

            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(16)),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),

            progress.bottomAnchor.constraint(equalTo: bottomAnchor),
            progress.leadingAnchor.constraint(equalTo: leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: trailingAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(playbackChanged),
                                               name: .sayctrlClipPlayback, object: nil)
        playbackChanged()
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
        progressTimer?.invalidate()
    }

    // MARK: Playback

    private func togglePlayback() {
        guard let audio = audio else {
            return SettingsUI.shared.toast("No audio kept for that one")
        }
        ClipPlayer.shared.toggle(name: audio)
    }

    /// Playing, the row keeps its actions up and its play button goes ember
    /// — the one live thing in the list — with the clip's progress along the
    /// row's foot.
    @objc private func playbackChanged() {
        playing = audio != nil && ClipPlayer.shared.playingID == audio
        play.setSymbol(playing ? "stop.fill" : "play.fill", icon: 11)
        play.tint = playing ? Theme.ember : nil
        actions.shown = hovering || playing || menuOpen
        progressTimer?.invalidate()
        guard playing else {
            progress.fraction = nil
            return
        }
        progress.fraction = ClipPlayer.shared.position ?? 0
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1 / 20.0, repeats: true) { [weak self] t in
            guard let self = self, let at = ClipPlayer.shared.position else { return t.invalidate() }
            self.progress.fraction = at
        }
    }

    private func copyWords() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        SettingsUI.shared.toast("Copied — ⌘V puts it back")
    }

    // MARK: The ⋯ menu

    /// What one model item stands for: this provider, this model — and
    /// whether it only exists on the realtime socket, which decides how the
    /// clip travels (upload against replay).
    private struct ModelPick {
        let provider: Provider
        let model: String
        let live: Bool
    }

    private func showMore() {
        let menu = moreMenu()
        menuOpen = true
        actions.shown = true
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -Theme.px(4)), in: more)
        menuOpen = false
        actions.shown = hovering || playing
    }

    /// Transcribe again, then Undo AI polish. A clip that wasn't kept can't
    /// be heard again, and a take the polish never touched has nothing to
    /// undo: both items stay in the menu, greyed, so it always reads the same.
    private func moreMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        func item(_ title: String, _ symbol: String, enabled: Bool, action: Selector?) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
            i.target = self
            i.isEnabled = enabled
            i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            return i
        }

        let again = item("Transcribe again", "arrow.triangle.2.circlepath",
                         enabled: audio != nil, action: #selector(transcribeAgain))
        again.toolTip = audio == nil ? "The audio for this one wasn’t kept" : "Runs what you said through the cloud again"
        menu.addItem(again)
        // The developers' build: the same clip through any model on hand.
        if !Config.retail, audio != nil {
            let with = item("Transcribe again with", "waveform", enabled: true, action: nil)
            with.submenu = modelPicker()
            menu.addItem(with)
        }
        let undo = item("Undo AI polish", "arrow.uturn.backward", enabled: polished,
                        action: #selector(undoPolish))
        undo.toolTip = polished ? "Back to the words as you said them" : "The AI polish didn’t change this one"
        menu.addItem(undo)
        return menu
    }

    @objc private func transcribeAgain() { onAction(.transcribe(override: nil)) }
    @objc private func undoPolish() { onAction(.undoPolish) }

    /// Every model that could hear this clip again: the local ones actually
    /// downloaded, then a section per paid provider holding a key — its upload
    /// models first, then the realtime-only ones marked "(live)", which replay
    /// the clip through the streaming socket instead of uploading it. That is
    /// what lets AssemblyAI and Google, who have no upload endpoint at all,
    /// take part. The model behind the row's current words is checked.
    private func modelPicker() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        func header(_ title: String) {
            let h = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            h.isEnabled = false
            menu.addItem(h)
        }
        func model(_ title: String, provider: Provider, id: String, live: Bool = false) {
            let item = NSMenuItem(title: title, action: #selector(pickModel(_:)), keyEquivalent: "")
            item.target = self
            item.indentationLevel = 1
            item.representedObject = ModelPick(provider: provider, model: id, live: live)
            if id == heardBy { item.state = .on }
            menu.addItem(item)
        }

        header("On this Mac")
        let installed = LocalEngine.shared.installedIDs()
        if installed.isEmpty {
            let none = NSMenuItem(title: "No models downloaded yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            none.indentationLevel = 1
            menu.addItem(none)
        }
        for id in installed {
            model(LocalEngine.entry(id)?.name ?? id, provider: .local, id: id)
        }

        for provider in Provider.allCases
        where provider != .local && Config.shared.apiKey(for: provider) != nil {
            var batch: [String] = []
            if !provider.liveOnly, !provider.transcriptionsURL.isEmpty {
                batch = provider.suggestedModels
                // A custom id typed into Settings belongs in the list too.
                let chosen = Config.shared.model(for: provider)
                if !batch.contains(chosen) { batch.insert(chosen, at: 0) }
            }
            // A model on both endpoints keeps its upload row — same weights,
            // and the upload path is the simpler ride.
            let live = provider.supportsLive
                ? provider.liveModels.filter { !batch.contains($0) } : []
            guard !batch.isEmpty || !live.isEmpty else { continue }
            menu.addItem(.separator())
            header(provider.title)
            for id in batch { model(id, provider: provider, id: id) }
            for id in live { model("\(id) (live)", provider: provider, id: id, live: true) }
        }
        return menu
    }

    @objc private func pickModel(_ item: NSMenuItem) {
        guard let pick = item.representedObject as? ModelPick else { return }
        onAction(.transcribe(override: (pick.provider, pick.model, pick.live)))
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    func setHovering(_ on: Bool) { hovering = on }
    override func mouseEntered(with event: NSEvent) { HoverArbiter.shared.enter(self) }
    override func mouseExited(with event: NSEvent) { HoverArbiter.shared.exit(self) }
    override var mouseDownCanMoveWindow: Bool { false }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = (hovering ? Theme.navHover : .clear).cgColor }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: - Recent's day labels and foot

/// Where an older day starts in the list — "Yesterday", "Thursday",
/// "Mon 28 Sep" — set like the sidebar's group labels.
private final class RecentDayHead: NSView {
    init(_ title: String) {
        super.init(frame: .zero)
        let label = Theme.meta(title.uppercased(), 10.5, Theme.faint)
        label.attributedStringValue = NSAttributedString(string: title.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: Theme.m(10.5), weight: .semibold),
            .foregroundColor: Theme.faint, .kern: Theme.m(10.5) * 0.06,
        ])
        let rule = ColorView(color: Theme.hairsoft)
        for v in [label, rule] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(16)),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(16)),
            label.topAnchor.constraint(equalTo: topAnchor, constant: Theme.m(14)),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.m(4)),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// "Yesterday", the weekday inside the last week, else the date.
    static func title(for day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInYesterday(day) { return "Yesterday" }
        let f = DateFormatter()
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: day), to: cal.startOfDay(for: Date())).day ?? 0
        f.dateFormat = days < 7 ? "EEEE" : (cal.isDate(day, equalTo: Date(), toGranularity: .year) ? "EEE d MMM" : "d MMM yyyy")
        return f.string(from: day)
    }
}

/// The list's foot: a spinner while the next rows are on their way, a
/// quiet line once the last of them is in, nothing otherwise.
private final class RecentFoot: NSView {
    enum State: Equatable { case idle, loading, end(String) }
    private let spinner = NSProgressIndicator()
    private let line = Theme.meta("", 11.5, Theme.muted)
    private var height: NSLayoutConstraint!

    var state: State = .idle {
        didSet {
            switch state {
            case .idle:
                spinner.stopAnimation(nil)
                spinner.isHidden = true
                line.isHidden = true
            case .loading:
                spinner.isHidden = false
                spinner.startAnimation(nil)
                line.isHidden = true
            case .end(let text):
                spinner.stopAnimation(nil)
                spinner.isHidden = true
                line.stringValue = text
                line.isHidden = false
            }
            height.constant = state == .idle ? 0 : Theme.m(44)
        }
    }

    init() {
        super.init(frame: .zero)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        line.isHidden = true
        line.alignment = .center
        let rule = ColorView(color: Theme.hairsoft)
        for v in [spinner, line, rule] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        height = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            height,
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(16)),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.centerXAnchor.constraint(equalTo: centerXAnchor),
            line.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Overview

final class OverviewPane: PaneView {

    private let greeting = Theme.display("Good afternoon", 24, .medium)
    private let subLine = Theme.text("", 13, .regular, Theme.muted)
    private let weekFigure = Theme.figure("0", 44, tracking: -0.02)
    private let allTime = Theme.figure("0", 19)
    private let pace = Theme.figure("0", 19)
    private let fixes = Theme.figure("0", 19)
    private lazy var counted: Void = {
        [weekFigure, allTime, pace, fixes].forEach { $0.identifier = Motion.countUpID }
    }()
    private var hero: HeroBanner?
    private let meter = WeekMeterView()
    private let recentGroup = OverviewBox()
    private let recentList = NSStackView()
    private let recentEmpty = Theme.text("", 13, .regular, Theme.muted)
    private let emptyHost = NSView()
    private let keptChip = QuietChip("Kept on this Mac", symbol: "lock.fill")
    private let recentFoot = RecentFoot()
    private weak var scroll: NSScrollView?

    /// Recent opens on the last ten takes and grows as you scroll to its
    /// foot, ten at a time, up to a hundred. The pause before a page is
    /// the spinner's moment — long enough to see that more came. Leave the
    /// page and it opens on the first ten again, at the top.
    private static let firstPage = 10
    private static let page = 10
    private static let most = 100
    private var shownCount = OverviewPane.firstPage
    private var loadingMore = false
    /// Set when the page goes off screen, so it comes back on the first ten;
    /// a new turn means a page still on its way lands on nothing.
    private var left = false
    private var loadTurn = 0

    /// Deleted rows wait here for a few seconds before they are really gone,
    /// so the toast's Undo can bring them back — audio and all.
    private var pendingDeletes: [String: Timer] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
        reload()
        NotificationCenter.default.addObserver(self, selector: #selector(historyChanged),
                                               name: .owHistoryChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(historyChanged),
                                               name: .owRulesChanged, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    private func build() {
        _ = counted
        subLine.font = .systemFont(ofSize: Theme.m(13))
        let head = Theme.vstack([greeting, subLine], spacing: Theme.m(4))

        // ── Where it works: the apps on this Mac you can talk into ──
        // One button: How it works opens the commands in their own sheet.
        // Help is the ? in the top bar.
        let hero = HeroBanner(
            title: "Talk anywhere you type",
            subtitle: Self.heroLine(),
            primary: ("How it works", { SettingsUI.shared.showCommands() }),
            art: .apps(HeroBanner.everyday))
        self.hero = hero

        // ── The strip: this week's words lead; the week sits beside them ──
        let strip = OverviewBox()
        let unit = Theme.text("words this week", 13, .regular, Theme.muted)
        unit.font = .systemFont(ofSize: Theme.m(13))
        let big = Theme.vstack([weekFigure, unit], spacing: Theme.m(1))
        func small(_ figure: NSTextField, _ label: String) -> NSView {
            let l = Theme.text(label, 11.5, .regular, Theme.muted)
            l.font = .systemFont(ofSize: Theme.m(11.5))
            return Theme.vstack([figure, l], spacing: 0)
        }
        let smalls = Theme.hstack([small(allTime, "all time"), small(pace, "wpm pace"),
                                   small(fixes, "fixes")], spacing: Theme.m(22))
        smalls.alignment = .top
        let figures = Theme.vstack([big, smalls], spacing: Theme.m(16))

        let meterTitle = Theme.text("Last 7 days", 13, .medium)
        meterTitle.font = .systemFont(ofSize: Theme.m(13), weight: .medium)
        let meterNote = Theme.text("words per day", 11.5, .regular, Theme.muted)
        meterNote.font = .systemFont(ofSize: Theme.m(11.5))
        let meterHead = Theme.hstack([meterTitle, Theme.spacer(), meterNote], spacing: 8)

        let divider = ColorView(color: Theme.hairsoft)
        for v in [figures, divider, meterHead, meter] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            strip.addSubview(v)
        }
        let figW = Theme.m(270)
        NSLayoutConstraint.activate([
            figures.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: Theme.m(22)),
            figures.topAnchor.constraint(equalTo: strip.topAnchor, constant: Theme.m(20)),
            figures.bottomAnchor.constraint(lessThanOrEqualTo: strip.bottomAnchor, constant: -Theme.m(20)),
            divider.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: figW),
            divider.topAnchor.constraint(equalTo: strip.topAnchor),
            divider.bottomAnchor.constraint(equalTo: strip.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            figures.trailingAnchor.constraint(lessThanOrEqualTo: divider.leadingAnchor, constant: -Theme.m(16)),

            meterHead.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: Theme.m(22)),
            meterHead.trailingAnchor.constraint(equalTo: strip.trailingAnchor, constant: -Theme.m(22)),
            meterHead.topAnchor.constraint(equalTo: strip.topAnchor, constant: Theme.m(16)),
            meter.leadingAnchor.constraint(equalTo: meterHead.leadingAnchor),
            meter.trailingAnchor.constraint(equalTo: meterHead.trailingAnchor),
            meter.topAnchor.constraint(equalTo: meterHead.bottomAnchor, constant: Theme.m(10)),
            meter.bottomAnchor.constraint(equalTo: strip.bottomAnchor, constant: -Theme.m(14)),
        ])
        figures.setContentHuggingPriority(.required, for: .vertical)

        // ── Recent: a header outside the group, the rows inside it ──
        // Clearing lives in Settings › Privacy, beside the export, where
        // wiping everything belongs.
        let recentTitle = Theme.display("Recent", 16, .medium, tracking: -0.005)
        let recentHead = Theme.hstack([recentTitle, keptChip, Theme.spacer()], spacing: Theme.m(10))

        recentList.orientation = .vertical
        recentList.alignment = .leading
        recentList.spacing = 0
        recentEmpty.font = .systemFont(ofSize: Theme.m(13))
        recentEmpty.translatesAutoresizingMaskIntoConstraints = false
        emptyHost.addSubview(recentEmpty)
        NSLayoutConstraint.activate([
            recentEmpty.leadingAnchor.constraint(equalTo: emptyHost.leadingAnchor, constant: Theme.m(16)),
            recentEmpty.trailingAnchor.constraint(lessThanOrEqualTo: emptyHost.trailingAnchor, constant: -Theme.m(16)),
            recentEmpty.centerYAnchor.constraint(equalTo: emptyHost.centerYAnchor),
            emptyHost.heightAnchor.constraint(equalToConstant: Theme.m(44)),
        ])
        let inner = NSStackView(views: [recentList, emptyHost, recentFoot])
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 0
        inner.translatesAutoresizingMaskIntoConstraints = false
        recentGroup.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: recentGroup.topAnchor),
            inner.leadingAnchor.constraint(equalTo: recentGroup.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: recentGroup.trailingAnchor),
            inner.bottomAnchor.constraint(equalTo: recentGroup.bottomAnchor),
            recentList.widthAnchor.constraint(equalTo: inner.widthAnchor),
            emptyHost.widthAnchor.constraint(equalTo: inner.widthAnchor),
            recentFoot.widthAnchor.constraint(equalTo: inner.widthAnchor),
        ])

        let column = NSStackView(views: [head, hero, strip, recentHead, recentGroup])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Theme.m(18)
        column.setCustomSpacing(Theme.m(22), after: head)
        column.setCustomSpacing(Theme.m(12), after: recentHead)
        for v in [hero, strip, recentHead, recentGroup] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        let scroll = makeCardScroll([column], topInset: Theme.m(40))
        scroll.fill(self, inset: 0)
        self.scroll = scroll
        // Reaching Recent's foot asks for the next page.
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
    }

    /// The hero's line names the key you actually hold.
    private static func heroLine() -> String {
        "Hold \(Shortcuts.dictate.text) in Slack, Mail, your editor or a terminal, and what you say lands at the cursor, cleaned up."
    }

    override func paneAppeared() {
        guard left else { return reload() }
        left = false
        shownCount = Self.firstPage
        reload()
        // The top is under the title bar's inset, not at zero.
        if let scroll = scroll {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: -scroll.contentInsets.top))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        // A window tall enough to show the foot of ten gets the next ten,
        // as it does the first time the page opens.
        DispatchQueue.main.async { [weak self] in self?.loadMoreIfNeeded() }
    }

    /// Off to another page or the window shut: the rows already loaded stay
    /// until it comes back, so the fade out doesn't jump.
    override func paneDisappeared() {
        left = true
        loadingMore = false
        loadTurn += 1
    }

    // MARK: Data

    /// History changes on every dictation. A pane that isn't in the window
    /// rebuilds nothing — `paneAppeared` catches it up when it comes back.
    @objc private func historyChanged() { if window?.isVisible == true { reload() } }

    @objc private func reload() {
        let entries = HistoryStore.shared.entries.filter { pendingDeletes[$0.id] == nil }
        let stats = StatsStore.shared
        let cal = Calendar.current
        let now = Date()

        let name = Account.name.split(separator: " ").first.map(String.init) ?? ""
        let hour = cal.component(.hour, from: now)
        let part = hour < 5 ? "Good evening" : hour < 12 ? "Good morning" : hour < 17 ? "Good afternoon" : "Good evening"
        Theme.setDisplay(greeting, name.isEmpty ? part : "\(part), \(name)")
        hero?.setSubtitle(Self.heroLine())

        // The totals come from the daily stats, not from the transcripts:
        // history is capped, and a busy day used to vanish off the end of it.
        let totalWords = stats.totalWords
        let totalSeconds = stats.totalSeconds
        let wpm = totalSeconds > 30 ? Int((Double(totalWords) / totalSeconds * 60).rounded()) : 0
        let fixCount = ReplacementStore.shared.rules.reduce(0) { $0 + $1.hits }
        Theme.setDisplay(allTime, WeekMeterView.format(totalWords))
        Theme.setDisplay(pace, WeekMeterView.format(wpm))
        Theme.setDisplay(fixes, WeekMeterView.format(fixCount))

        let weekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? cal.startOfDay(for: now)
        let daysThisWeek = max(1, (cal.dateComponents([.day], from: weekStart, to: now).day ?? 0) + 1)
        let weekWords = stats.window(daysThisWeek).reduce(0) { $0 + $1.stat.words }
        Theme.setDisplay(weekFigure, WeekMeterView.format(weekWords))
        let weekday = now.formatted(Date.FormatStyle().weekday(.wide))
        subLine.stringValue = weekWords > 0
            ? "\(weekday) · the week so far"
            : "\(weekday) · hold \(Shortcuts.dictate.text) and speak, and the words land at your cursor"

        let dayFmt = DateFormatter()
        dayFmt.dateFormat = "EEE"
        meter.days = stats.window(7).map { day in
            (cal.isDateInToday(day.date) ? "Today" : dayFmt.string(from: day.date), day.stat.words)
        }

        let timeFmt = DateFormatter()
        timeFmt.dateFormat = "h:mm a"
        recentList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // Today's takes stand on their own, as they always have; an older
        // day opens with its name, so a time never reads as today's.
        var lastDay: Date?
        for (i, entry) in entries.prefix(shownCount).enumerated() {
            let day = cal.startOfDay(for: entry.date)
            var opensDay = false
            if day != lastDay, !(lastDay == nil && cal.isDateInToday(day)) {
                let head = RecentDayHead(RecentDayHead.title(for: day))
                recentList.addArrangedSubview(head)
                head.translatesAutoresizingMaskIntoConstraints = false
                head.widthAnchor.constraint(equalTo: recentList.widthAnchor).isActive = true
                opensDay = true
            }
            lastDay = day
            let row = RecentRow(entry: entry,
                                time: timeFmt.string(from: entry.date).lowercased(),
                                onAction: { [weak self] action in self?.act(action, on: entry) },
                                onDelete: { [weak self] in self?.delete(entry) })
            row.isFirst = i == 0 || opensDay
            recentList.addArrangedSubview(row)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: recentList.widthAnchor).isActive = true
        }
        let limit = min(Self.most, entries.count)
        if loadingMore {
            recentFoot.state = .loading
        } else if shownCount >= Self.most, entries.count > Self.most {
            recentFoot.state = .end("That’s the last \(Self.most). Export the rest from Settings › Privacy.")
        } else if entries.count > Self.firstPage, shownCount >= limit {
            recentFoot.state = .end("That’s everything kept.")
        } else {
            recentFoot.state = .idle
        }
        let keeping = Config.shared.flag("KEEP_HISTORY", default: true)
        recentEmpty.stringValue = keeping
            ? "Nothing dictated yet. Hold \(Shortcuts.dictate.text) and speak."
            : "History is off in Settings › Privacy, so nothing is kept here."
        emptyHost.isHidden = !entries.isEmpty
        keptChip.isHidden = !keeping
    }

    // MARK: Delete, with Undo

    /// The row goes at once; the entry and its audio go when the toast does.
    /// The commit doesn't hang on the pane — a window rebuilt for a text-size
    /// change mid-toast still finishes the delete.
    private func delete(_ entry: HistoryEntry) {
        let id = entry.id
        pendingDeletes[id]?.invalidate()
        pendingDeletes[id] = Timer.scheduledTimer(withTimeInterval: 5.2, repeats: false) { _ in
            HistoryStore.shared.remove(id: id)
        }
        reload()
        SettingsUI.shared.toast("Deleted", action: ("Undo", { [weak self] in
            self?.pendingDeletes[id]?.invalidate()
            self?.pendingDeletes[id] = nil
            self?.reload()
        }))
    }

    // MARK: More rows

    /// Measured a beat later: the first layout scrolls the clip before the
    /// rows have their height, and read then, the foot looks in view and a
    /// second page loads before anyone scrolled.
    @objc private func scrolled() {
        DispatchQueue.main.async { [weak self] in self?.loadMoreIfNeeded() }
    }

    /// The foot of Recent is in view and there is more to show: a spinner,
    /// a beat, the next page.
    private func loadMoreIfNeeded() {
        guard !loadingMore, !left, window != nil, let scroll = scroll, let doc = scroll.documentView else { return }
        let available = HistoryStore.shared.entries.filter { pendingDeletes[$0.id] == nil }.count
        guard shownCount < min(Self.most, available) else { return }
        doc.layoutSubtreeIfNeeded()
        let visible = scroll.contentView.documentVisibleRect
        guard visible.maxY >= doc.bounds.height - Theme.m(120) else { return }
        loadingMore = true
        recentFoot.state = .loading
        let turn = loadTurn
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, turn == self.loadTurn else { return }
            self.loadingMore = false
            self.shownCount = min(self.shownCount + Self.page, Self.most)
            self.reload()
            // A tall window can still have the foot in view: keep going.
            DispatchQueue.main.async { self.loadMoreIfNeeded() }
        }
    }

    // MARK: The ⋯ menu

    private func act(_ action: RecentRow.Action, on entry: HistoryEntry) {
        switch action {
        case .transcribe(let override): retranscribe(entry, override: override)
        case .undoPolish:               undoPolish(entry)
        }
    }

    /// The words back the way they were heard, on the clipboard to paste
    /// over the polished ones. Undo in the toast puts the polish back.
    private func undoPolish(_ entry: HistoryEntry) {
        guard let polished = entry.polished else { return }
        HistoryStore.shared.setPolished(id: entry.id, nil)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
        reload()
        SettingsUI.shared.toast("Back to what you said — copied", action: ("Undo", { [weak self] in
            HistoryStore.shared.setPolished(id: entry.id, polished)
            self?.reload()
        }))
    }

    /// Runs the kept clip through the ear again and replaces the words with
    /// what comes back — the same cloud a dictation goes through, or, in the
    /// developers' build, the model picked off the row. Undo puts the old
    /// words back, polish and all. A live pick replays the clip over the
    /// streaming socket, so it takes a few seconds where an upload takes one
    /// round-trip.
    private func retranscribe(_ entry: HistoryEntry, override: (provider: Provider, model: String, live: Bool)?) {
        guard let url = Recordings.shared.url(for: entry.audio) else {
            return SettingsUI.shared.toast("No audio kept for that one")
        }
        guard let app = NSApp.delegate as? AppDelegate else { return }
        let before = (text: entry.text, model: entry.model, polished: entry.polished)
        let name = override.map { LocalEngine.entry($0.model)?.name ?? $0.model }
        let model = override?.model ?? (Config.shared.cloudOn ? "SayControl cloud" : Config.shared.model)
        let done: (Result<String, Error>) -> Void = { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let text):
                    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty else { return SettingsUI.shared.toast("Nothing heard that time") }
                    let final = ReplacementStore.shared.apply(to: clean)
                    HistoryStore.shared.replaceText(id: entry.id, with: final, model: model)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(final, forType: .string)
                    self?.reload()
                    SettingsUI.shared.toast(name.map { "\($0) — copied" } ?? "Transcribed again — copied",
                                            action: ("Undo", { [weak self] in
                        HistoryStore.shared.replaceText(id: entry.id, with: before.text, model: before.model)
                        HistoryStore.shared.setPolished(id: entry.id, before.polished)
                        self?.reload()
                    }))
                case .failure(let error):
                    SettingsUI.shared.toast(error.localizedDescription)
                }
            }
        }
        if let pick = override {
            SettingsUI.shared.toast(pick.live ? "Replaying through \(name ?? pick.model)…" : "Transcribing with \(name ?? pick.model)…")
            app.transcribe(fileURL: url, with: pick, completion: done)
        } else {
            SettingsUI.shared.toast("Transcribing again…")
            app.transcribeAgain(fileURL: url, completion: done)
        }
    }
}
