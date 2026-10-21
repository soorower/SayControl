// The settings window: a sidebar shell plus the Overview and Settings panes.
// (Dictionary and Activity live in SettingsPanes.swift.)
import Cocoa
import AVFoundation

// MARK: - Sidebar row

final class NavRow: NSView {
    let key: String
    private let iconView: GlyphView
    private let titleField: NSTextField
    private var hovering = false { didSet { needsDisplay = true } }
    var selected = false { didSet { restyle(); needsDisplay = true } }
    /// Off while the selection slides here from another row: the moving
    /// highlight is the fill until it arrives.
    var paintsSelection = true { didSet { needsDisplay = true } }
    var onClick: ((String) -> Void)?

    init(key: String, icon: NSImage?, title: String) {
        self.key = key
        titleField = Theme.text(title, 15, .regular)
        titleField.font = .systemFont(ofSize: Theme.m(13), weight: .regular)
        // Drawn at its own size, never scaled to a frame: an NSImageView
        // squashed the gear and, caught mid-fold, shrank every icon and
        // left it small.
        iconView = GlyphView(icon, side: Theme.m(18))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(8)

        let row = Theme.hstack([iconView, titleField], spacing: Theme.m(10))
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(10)),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Theme.m(8)),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Theme.m(30)),
        ])
        toolTip = title
        restyle()
    }
    /// Most rows wear an SF symbol; the agent rows hand in a brand mark.
    convenience init(key: String, symbol: String, title: String) {
        self.init(key: key, icon: Theme.symbol(symbol, Theme.m(13.5), .regular), title: title)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Icon only — the sidebar folded up. The icon stays exactly where it
    /// was: the folded panel is as wide as it takes to centre it there, so
    /// nothing slides or jumps while the panel folds. The title stays in the
    /// tooltip.
    var compact = false { didSet { titleField.isHidden = compact } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                      options: [.mouseEnteredAndExited, .activeInActiveApp],
                                      owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onClick?(key) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Rest is soft ink, hover a warm wash, selected a beige fill with
    /// medium ink. No shadow and no coloured icon: the row you are on is
    /// plain from its fill and weight.
    private func restyle() {
        titleField.textColor = selected || hovering ? Theme.ink : Theme.ink2
        iconView.tint = selected || hovering ? Theme.ink : Theme.muted
        titleField.font = .systemFont(ofSize: Theme.m(13), weight: selected ? .medium : .regular)
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        restyle()
        let bg: NSColor = selected ? (paintsSelection ? Theme.navPick : .clear) : (hovering ? Theme.navHover : .clear)
        layer?.backgroundColor = bg.cgColor
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: - Wordmark

/// The SayCtrl wordmark at the top of the sidebar. It is a button now: the
/// About page became a sheet that opens from here.
final class BrandButton: NSView {
    private let markView = NSImageView()
    private let info = NSImageView()
    private let name = Theme.display("SayControl", 14.5, .semibold, tracking: -0.01)
    private let gap = Theme.spacer()
    private var hovering = false { didSet { info.isHidden = !hovering || compact; needsDisplay = true } }
    var onClick: () -> Void = {}
    /// The mark alone, for the folded sidebar.
    var compact = false {
        didSet {
            name.isHidden = compact
            gap.isHidden = compact
            info.isHidden = !hovering || compact
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(8)
        toolTip = "About SayControl"

        let side = Theme.m(18)
        markView.image = Theme.mark(side)
        markView.translatesAutoresizingMaskIntoConstraints = false
        markView.widthAnchor.constraint(equalToConstant: side).isActive = true
        markView.heightAnchor.constraint(equalToConstant: side).isActive = true

        info.image = Theme.symbol("info.circle", Theme.px(15), .regular)
        info.contentTintColor = Theme.faint
        info.isHidden = true
        info.translatesAutoresizingMaskIntoConstraints = false
        info.widthAnchor.constraint(equalToConstant: Theme.px(16)).isActive = true

        let row = Theme.hstack([markView, name, gap, info], spacing: Theme.m(9))
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        // The mark sits on the same line as the sidebar's icons, open or
        // folded, so it doesn't hop sideways when the panel folds.
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(10)),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Theme.m(6)),
            row.topAnchor.constraint(equalTo: topAnchor, constant: Theme.m(7)),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.m(7)),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onClick() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override var mouseDownCanMoveWindow: Bool { false }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = (hovering ? Theme.navHover : .clear).cgColor
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: - Sidebar pieces

/// The sidebar as one floating panel, inset from the window's edges. It
/// starts under the title strip: the traffic lights, the fold toggle and the
/// top bar's controls share that strip, and nothing runs under the lights.
final class SidebarPanel: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(12)
        layer?.borderWidth = 1
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Theme.sidebarFill.cgColor
        layer?.borderColor = Theme.sidebarLine.cgColor
        layer?.shadowColor = Theme.hex(0x14161C).cgColor
        layer?.shadowOpacity = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.35 : 0.05
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -3)
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// An uppercase group name over a run of sidebar rows — VOICE, CODING.
final class NavGroupLabel: NSView {
    init(_ title: String) {
        super.init(frame: .zero)
        let f = Theme.text("", 11, .semibold, Theme.faint)
        f.attributedStringValue = NSAttributedString(string: title.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: Theme.m(11), weight: .semibold),
            .foregroundColor: Theme.faint, .kern: Theme.m(11) * 0.06,
        ])
        f.translatesAutoresizingMaskIntoConstraints = false
        addSubview(f)
        NSLayoutConstraint.activate([
            f.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(10)),
            f.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            f.topAnchor.constraint(equalTo: topAnchor, constant: Theme.m(12)),
            f.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.m(4)),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// The two things a new user needs most, always in view under the logo:
/// the key you hold to dictate, and the one that starts hands-free. Real
/// keycaps, read from Shortcuts, so they change when you change them. A
/// click opens Settings › General, where they are set.
final class TalkWell: NSView {
    private let column = NSStackView()
    var onClick: () -> Void = {}
    private var hovering = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(10)
        layer?.borderWidth = 1
        toolTip = "Change these in Settings › General"
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Theme.m(7)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(10)),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.m(10)),
            column.topAnchor.constraint(equalTo: topAnchor, constant: Theme.m(10)),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.m(10)),
        ])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// What a key part is called on its cap: glyphs for the modifiers, the
    /// key's own name otherwise.
    static func capText(_ part: KeyPart) -> String {
        let n = part.name.lowercased()
        if n.hasSuffix("fn") { return "fn" }
        if n.hasSuffix("control") { return "⌃" }
        if n.hasSuffix("option") { return "⌥" }
        if n.hasSuffix("shift") { return "⇧" }
        if n.hasSuffix("command") { return "⌘" }
        if n == "space" { return "Space" }
        return part.name.count == 1 ? part.name.uppercased() : part.name
    }

    private func line(_ lead: String?, _ parts: [KeyPart], _ tail: String) -> NSView {
        var views: [NSView] = []
        if let lead = lead { views.append(Theme.text(lead, 12, .regular, Theme.ink2)) }
        for part in parts { views.append(KeyCapView(Self.capText(part), small: true)) }
        let tailField = Theme.text(tail, 12, .regular, Theme.muted)
        tailField.alignment = .right
        views += [Theme.spacer(), tailField]
        views.forEach { if let f = $0 as? NSTextField { f.font = .systemFont(ofSize: Theme.m(12)) } }
        let row = Theme.hstack(views, spacing: Theme.m(4))
        return row
    }

    func refresh() {
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let dot = ColorView(color: Theme.moss, radius: Theme.m(3.5))
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: Theme.m(7)).isActive = true
        dot.heightAnchor.constraint(equalToConstant: Theme.m(7)).isActive = true
        let ready = Theme.text("Ready", 12, .medium)
        ready.font = .systemFont(ofSize: Theme.m(12), weight: .medium)
        var rows: [NSView] = [Theme.hstack([dot, ready], spacing: Theme.m(7))]
        rows.append(line("Hold", Shortcuts.dictate.parts, "to dictate"))
        if let free = Shortcuts.handsFreeKeys.first {
            rows.append(line(nil, free.parts, "hands-free"))
        } else {
            rows.append(line("Hold", Shortcuts.command, "command"))
        }
        // The switches the first run let you skip, until they are on: a
        // line here says what that costs and where to fix it.
        let fnKey = Shortcuts.dictate.parts.contains { Self.capText($0) == "fn" }
        let nudge: String? = !fnKey ? nil
            : Permissions.inputMonitoring != .granted ? "fn may miss in some apps"
            : !Permissions.globeKeyIsQuiet ? "A tap of fn opens emoji" : nil
        if let nudge = nudge {
            rows.append(ColorView(color: Theme.sidebarLine))
            let text = Theme.text(nudge, 11.5, .regular, Theme.amber)
            text.font = .systemFont(ofSize: Theme.m(11.5))
            let fix = NudgeFix { SettingsUI.shared.showSettings(tab: "permissions") }
            rows.append(Theme.hstack([text, Theme.spacer(), fix], spacing: Theme.m(6)))
        }
        for r in rows {
            column.addArrangedSubview(r)
            r.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            if r is ColorView { r.heightAnchor.constraint(equalToConstant: 1).isActive = true }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onClick() }
    override var mouseDownCanMoveWindow: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        // A white card on the sand panel. The sunk grey well it replaced was
        // lighter than the panel around it and all but vanished in light mode.
        layer?.backgroundColor = (hovering ? Theme.wellFill : Theme.sideCard).cgColor
        layer?.borderColor = Theme.sidebarLine.cgColor
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// "Fix", under the Ready card's nudge: straight to Settings › Permissions.
private final class NudgeFix: NSView {
    private let label = Theme.text("Fix", 11.5, .semibold, Theme.amber)
    private let action: () -> Void
    init(_ action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: Theme.m(11.5), weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        toolTip = "Open Settings › Permissions"
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) { action() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// The microphone SayCtrl is listening through, in the window's top corner,
/// so "is it hearing me?" has an answer on every pane. A click lists every
/// input and switches the Mac's default to the one picked, since SayCtrl
/// records from the system default.
final class MicChip: NSView {
    private let icon = GlyphView(symbol: "mic.fill", size: Theme.m(8.5), weight: .semibold, side: Theme.m(10))
    private let name = Theme.text("", 11, .regular, Theme.ink2)
    private var hovering = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = 1
        name.font = .systemFont(ofSize: Theme.m(11))
        let row = Theme.hstack([icon, name], spacing: Theme.m(5))
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(8)),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.m(10)),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Theme.m(19)),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        let input = AudioInputs.default
        name.stringValue = input?.name ?? "No microphone"
        toolTip = input == nil ? "No microphone found. Plug one in or pair one."
                               : "Listening through \(input!.name). Click to switch."
        needsDisplay = true
    }

    private func showInputs() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let inputs = AudioInputs.all()
        if inputs.isEmpty {
            let none = NSMenuItem(title: "No microphone found", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        let current = AudioInputs.defaultID
        for input in inputs {
            let item = NSMenuItem(title: input.name, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = input.id
            item.state = input.id == current ? .on : .off
            if input.isContinuity {
                item.toolTip = "Your iPhone's mic sleeps between takes, so each dictation takes a few seconds to start."
            }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + Theme.m(4)), in: self)
    }

    @objc private func pick(_ item: NSMenuItem) {
        guard let id = item.representedObject as? AudioDeviceID,
              let input = AudioInputs.all().first(where: { $0.id == id }),
              id != AudioInputs.defaultID else { return }
        if AudioInputs.makeDefault(input) {
            Config.shared.log("Input device set to \(input.name)")
            refresh()
        }
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { showInputs() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override var mouseDownCanMoveWindow: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        icon.tint = AudioInputs.default == nil ? Theme.amber : Theme.moss
        layer?.backgroundColor = (hovering ? Theme.wellFill : Theme.surface).cgColor
        layer?.borderColor = Theme.hairline.cgColor
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// Your photo (or initials), name and plan at the foot of the sidebar; a
/// click opens the account popover. Settings is its own row above it, so
/// it is still there when the sidebar is folded to icons. Only when
/// accounts exist.
final class AccountFoot: NSView {
    private let avatar = NSTextField(labelWithString: "")
    private let disc = ColorView(color: Theme.ink)
    private var photo: AccountPhotoView!
    private let nameField = Theme.text("", 12.5, .semibold)
    private let planField = Theme.text("", 11, .regular, Theme.muted)
    private let who = NSStackView()
    private let spacer = Theme.spacer()
    private var lead: NSLayoutConstraint!
    var onAccount: () -> Void = {}
    /// Folded, only the round is left, centred in the column. The spacer goes
    /// too: left in, its share of the row squeezed the round into an oval.
    var compact = false {
        didSet {
            who.isHidden = compact
            spacer.isHidden = compact
            needsLayout = true
        }
    }

    init() {
        super.init(frame: .zero)
        let d = Theme.m(28)
        disc.translatesAutoresizingMaskIntoConstraints = false
        disc.wantsLayer = true
        disc.layer?.cornerRadius = d / 2
        disc.widthAnchor.constraint(equalToConstant: d).isActive = true
        disc.heightAnchor.constraint(equalToConstant: d).isActive = true
        avatar.font = .systemFont(ofSize: Theme.m(11), weight: .semibold)
        avatar.textColor = Theme.paper
        avatar.alignment = .center
        avatar.translatesAutoresizingMaskIntoConstraints = false
        disc.addSubview(avatar)
        NSLayoutConstraint.activate([
            avatar.centerXAnchor.constraint(equalTo: disc.centerXAnchor),
            avatar.centerYAnchor.constraint(equalTo: disc.centerYAnchor),
        ])
        photo = AccountPhotoView(in: disc)
        nameField.font = .systemFont(ofSize: Theme.m(12.5), weight: .semibold)
        planField.font = .systemFont(ofSize: Theme.m(11))
        who.orientation = .vertical
        who.alignment = .leading
        who.spacing = 1
        who.addArrangedSubview(nameField)
        who.addArrangedSubview(planField)
        let row = Theme.hstack([disc, who, spacer], spacing: Theme.m(10))
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        lead = row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(6))
        let trail = row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
        NSLayoutConstraint.activate([
            lead, trail,
            row.topAnchor.constraint(equalTo: topAnchor, constant: Theme.m(8)),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.m(4)),
        ])
        toolTip = "Account"
        refresh()
    }

    override func layout() {
        // Open: the round sits over the rows' icons. Folded: it is centred.
        lead.constant = compact ? max(0, (bounds.width - Theme.m(28)) / 2) : Theme.m(6)
        super.layout()
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        avatar.stringValue = Account.signedIn ? Account.initials : "?"
        avatar.isHidden = photo.refresh()
        nameField.stringValue = Account.signedIn ? Account.firstName : "Not signed in"
        if !Account.signedIn {
            planField.stringValue = "Sign in for the cloud"
        } else if Account.plan == "pro" {
            planField.stringValue = "Pro"
        } else {
            planField.stringValue = Account.leftLine.map { "Free · \($0)" } ?? "Free"
        }
    }

    override func mouseDown(with event: NSEvent) { onAccount() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override var mouseDownCanMoveWindow: Bool { false }
}

// MARK: - Window shell

final class SettingsUI: NSObject, NSWindowDelegate {
    static let shared = SettingsUI()
    /// A --snapshot run shares the dev app's defaults: it must never save a
    /// window frame or a sidebar fold into them.
    private static let shooting = CommandLine.arguments.contains("--snapshot")

    private var window: NSWindow?
    private let contentHost = NSView()
    private var rows: [NavRow] = []
    private var panes: [String: PaneView] = [:]
    private var currentKey = ""
    /// Rebuilt with the window, because their metrics bake in at construction.
    private var foot: AccountFoot?
    private var talk = TalkWell()
    private var navStack: NSStackView?
    private var mic = MicChip()
    private var navLabels: [NSView] = []
    private var overlay: (NSView, NSView)?
    private var overlayMonitor: Any?

    // Overview first — the window opens on your numbers, not on API keys.
    // Settings and Help are pinned to the bottom; About is on the wordmark.
    // Your numbers first, then the three things that shape how you are
    // heard, then the coding agents. Settings sits at the foot with the
    // account; Help is the ? in the top bar. Commands left the list: it is
    // something you look up, not somewhere you work, so it opens as a sheet
    // (How it works) from the Overview and from the foot.
    private let items: [(key: String, symbol: String, title: String)] = [
        ("overview", "square.grid.2x2", "Overview"),
        ("insights", "chart.bar", "Insights"),
        ("dictionary", "character.book.closed", "Dictionary"),
        ("phrases", "text.append", "Phrases"),
        ("tones", "slider.vertical.3", "Tones"),
    ]
    private let bottomItems: [(key: String, symbol: String, title: String)] = [
        ("howto", "lightbulb", "How it works"),
        ("settings", "gearshape", "Settings"),
    ]

    /// Legacy pane names (menu items, --settings args, old callers) land on the
    /// pane that now owns that content. Names of Settings sections never reach
    /// here — select() sends those straight to the sheet.
    private static func canonical(_ key: String) -> String {
        switch key {
        // The agent voice moved out of Settings → System into the Agents
        // hub; asking for a specific agent by a casual name still lands on
        // its own page, while "agents" is the hub itself.
        case "agent", "claude": return "agent-claude"
        // Wispr Flow calls these "styles"; anyone arriving with that word,
        // or from the old per-app-tone toggle, lands on Tones.
        case "styles", "style": return "tones"
        // Wispr Flow calls these "snippets" — same idea, our word for it.
        case "snippets", "snippet", "phrase": return "phrases"
        // Activity was folded into Recent on the Overview. Old callers land
        // somewhere sensible.
        case "activity", "history": return "overview"
        case "stats", "insight": return "insights"
        // Commands is the How it works sheet now, whichever name asks.
        case "howto", "how", "command": return "commands"
        case "": return "overview"
        default: return key
        }
    }

    // MARK: Presenting

    func present(selecting key: String? = nil) {
        // Signed out, the app is the sign-in and nothing else.
        guard !Account.required else { return Account.askToSignIn() }
        if window == nil { build() }
        installMainMenuIfNeeded()
        // --snapshot draws the window off-screen and never takes focus: it
        // runs while someone is working, often several at once.
        if Self.shooting {
            window?.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window?.orderFrontRegardless()
        } else {
            // Become a regular app while the window is up, so it gets a proper window
            // experience and Cmd+C/V work in the text fields. Back to menu-bar-only on close.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        }
        let wanted = Self.canonical(key ?? currentKey)
        if wanted == currentKey {
            panes[wanted]?.paneAppeared()   // already showing — just refresh it
        } else {
            select(wanted)
        }
    }

    var isWindowVisible: Bool { window?.isVisible ?? false }

    func windowWillClose(_ notification: Notification) {
        panes[currentKey]?.paneDisappeared()
        // The first-run window is a proper window too; the app stays a
        // regular one while it is up.
        if !OnboardingWindow.shared.isVisible { NSApp.setActivationPolicy(.accessory) }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refreshChrome()
        panes[currentKey]?.paneAppeared()
    }

    private func build() {
        // The account foot follows sign-in and sign-out the moment they
        // happen. Once, however often the window is rebuilt.
        NotificationCenter.default.removeObserver(self, name: .sayctrlAccountChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(accountChanged),
                                               name: .sayctrlAccountChanged, object: nil)
        // 1260 × 820 is the design size. On a smaller display, come in under
        // the visible frame rather than hanging off the edges.
        var size = NSSize(width: 1260, height: 820)
        if let vis = NSScreen.main?.visibleFrame {
            size.width = min(size.width, vis.width - 40)
            size.height = min(size.height, vis.height - 40)
        }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "SayControl"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.minSize = NSSize(width: 1040, height: 720)
        w.delegate = self
        w.isReleasedWhenClosed = false

        // Remember where you put it and how big you made it. Only centre the
        // very first time, before there is anything to remember. The name
        // changed with the 2.2 default size, so the smaller window is what
        // opens once, rather than the frame saved under the old one.
        let autosave = "SayCtrlMainWindow2"
        let firstRun = UserDefaults.standard.string(forKey: "NSWindow Frame " + autosave) == nil
        if Self.shooting {
            w.center()
        } else {
            w.setFrameAutosaveName(autosave)
            if firstRun { w.center() }
        }

        // Porcelain ground; the sidebar floats on it as its own panel.
        let root = ColorView(color: Theme.paper)
        w.contentView = root
        w.backgroundColor = Theme.paper

        contentHost.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentHost)

        let side = SidebarPanel()
        side.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(side)

        // The title strip: as tall as the window's own title bar, measured
        // rather than assumed (it differs between macOS versions). The traffic
        // lights, the fold toggle and the top bar are centred on it, and the
        // sidebar panel starts under it instead of running behind the lights.
        let strip = max(28, w.frame.height - w.contentLayoutRect.height)
        let lightsEnd = w.standardWindowButton(.zoomButton).map { $0.frame.maxX } ?? 70
        let inset = Theme.m(8)
        sideWidth = side.widthAnchor.constraint(equalToConstant: Theme.m(220))
        NSLayoutConstraint.activate([
            side.topAnchor.constraint(equalTo: root.topAnchor, constant: strip + 4),
            side.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -inset),
            side.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset),
            sideWidth,

            contentHost.topAnchor.constraint(equalTo: root.topAnchor),
            contentHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            contentHost.leadingAnchor.constraint(equalTo: side.trailingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])

        // The fold toggle lives in the title strip, just past the traffic
        // lights, where macOS apps keep it: it never moves when the sidebar
        // folds, so the next click is where the last one was.
        foldButton = IconButton("sidebar.left", size: 24, icon: 14, tip: "Hide the sidebar") { [weak self] in
            guard let self = self else { return }
            self.setSidebar(collapsed: !self.sidebarCollapsed)
        }
        foldButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(foldButton)
        NSLayoutConstraint.activate([
            foldButton.centerYAnchor.constraint(equalTo: root.topAnchor, constant: strip / 2),
            foldButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: lightsEnd + Theme.m(12)),
        ])

        buildSidebar(in: side)
        sidebarView = side
        setSidebar(collapsed: UserDefaults.standard.bool(forKey: "SidebarCollapsed"), animated: false)

        // The top bar rides above every pane, in the same strip as the
        // traffic lights and at their scale: the microphone in use, and Help.
        mic = MicChip()
        let help = IconButton("questionmark.circle", size: 24, icon: 13.5, tip: "Help") { [weak self] in
            self?.select("help")
        }
        let bar = Theme.hstack([mic, help], spacing: Theme.m(4))
        bar.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.centerYAnchor.constraint(equalTo: root.topAnchor, constant: strip / 2),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Theme.m(12)),
        ])

        // What went wrong in the background (Alerts.swift), over every pane,
        // under the top bar.
        let alerts = AlertStack()
        alerts.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(alerts)
        NSLayoutConstraint.activate([
            alerts.topAnchor.constraint(equalTo: root.topAnchor, constant: strip + Theme.m(8)),
            alerts.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Theme.m(16)),
        ])

        window = w
    }

    // ── the fold ──────────────────────────────────────────────────────────
    private var sideWidth: NSLayoutConstraint!
    /// For --snapshot, which draws it on its own: through the window it
    /// whites out with the scroll views beside it.
    private(set) var sidebarView: NSView!
    private var brand: BrandButton!
    private var foldButton: IconButton!
    private(set) var sidebarCollapsed = false

    /// Icons only, or icons and names. Folding hides the names first and
    /// then narrows the panel; unfolding widens it first and brings the names
    /// back once there is room — nothing is ever squeezed into a panel too
    /// narrow for it, which is what made the icons jump and flicker.
    func setSidebar(collapsed: Bool, animated: Bool = true) {
        sidebarCollapsed = collapsed
        if !Self.shooting { UserDefaults.standard.set(collapsed, forKey: "SidebarCollapsed") }
        foldButton.setSymbol(collapsed ? "sidebar.leading" : "sidebar.left", icon: 14)
        foldButton.toolTip = collapsed ? "Show the sidebar" : "Hide the sidebar"
        // Folded: the icons' centre (row inset + half an icon) on both
        // sides of the column, plus the column's own padding.
        let width = collapsed ? 2 * (Theme.m(10) + Theme.m(18) / 2) + 2 * Theme.m(10) : Theme.m(220)
        let fold = generation &+ 1
        generation = fold
        let showNames = { [weak self] (compact: Bool) in
            guard let self = self else { return }
            self.brand.compact = compact
            self.rows.forEach { $0.compact = compact }
            self.talk.isHidden = compact
            self.navLabels.forEach { $0.isHidden = compact }
            self.foot?.compact = compact
        }
        guard animated, let root = window?.contentView else {
            showNames(collapsed)
            sideWidth.constant = width
            return
        }
        if collapsed { showNames(true); root.layoutSubtreeIfNeeded() }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            sideWidth.animator().constant = width
            root.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            // A second click mid-fold owns the sidebar now.
            guard let self = self, self.generation == fold, !collapsed else { return }
            showNames(false)
        })
    }
    /// Which fold is the latest, so an earlier one's completion stands down.
    private var generation = 0

    private func buildSidebar(in side: NSView) {
        brand = BrandButton()
        brand.onClick = { [weak self] in self?.showAbout() }

        talk = TalkWell()
        talk.onClick = { [weak self] in self?.showSettings(tab: "general") }

        rows = (items + bottomItems).map { item in
            NavRow(key: item.key, symbol: item.symbol, title: item.title)
        }
        // One row for the whole roster of coding agents — the per-agent
        // pages open from the tiles on the hub, not from the sidebar.
        let agentsRow = NavRow(key: "agents", symbol: "sparkles", title: "Agents")
        rows += [agentsRow]
        rows.forEach { r in r.onClick = { [weak self] k in self?.select(k) } }
        func row(_ key: String) -> NavRow { rows.first { $0.key == key }! }

        let voice = NavGroupLabel("Voice")
        let coding = NavGroupLabel("Coding")
        navLabels = [voice, coding]
        let navViews: [NSView] = [row("overview"), row("insights"),
                                  voice, row("dictionary"), row("phrases"), row("tones"),
                                  coding, agentsRow]
        let nav = NSStackView(views: navViews)
        navStack = nav
        nav.orientation = .vertical
        nav.alignment = .leading
        nav.spacing = Theme.m(1)
        nav.translatesAutoresizingMaskIntoConstraints = false

        let column = NSStackView(views: [brand, talk, nav])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Theme.m(12)
        column.translatesAutoresizingMaskIntoConstraints = false
        side.addSubview(column)

        // The foot: How it works (the second way into the commands, after
        // the Overview's button), then Settings, then your account once
        // accounts exist. Settings is a row of its own rather than a gear
        // beside your name, so folding the sidebar to icons keeps it.
        let howto = row("howto")
        let settings = row("settings")
        let tailView: NSView
        if Account.available {
            let f = AccountFoot()
            f.onAccount = { [weak self] in self?.toggleAccountPopover() }
            foot = f
            tailView = f
        } else {
            foot = nil
            tailView = NSView()
            tailView.heightAnchor.constraint(equalToConstant: 0).isActive = true
        }
        let rule = ColorView(color: Theme.hairline)
        rule.isHidden = !Account.available
        for v in [howto, settings, rule, tailView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            side.addSubview(v)
        }

        let pad = Theme.m(10)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: side.topAnchor, constant: Theme.m(10)),
            column.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: pad),
            column.trailingAnchor.constraint(equalTo: side.trailingAnchor, constant: -pad),
            nav.widthAnchor.constraint(equalTo: column.widthAnchor),
            brand.widthAnchor.constraint(equalTo: column.widthAnchor),
            talk.widthAnchor.constraint(equalTo: column.widthAnchor),

            howto.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: pad),
            howto.trailingAnchor.constraint(equalTo: side.trailingAnchor, constant: -pad),
            howto.bottomAnchor.constraint(equalTo: settings.topAnchor, constant: -Theme.m(1)),

            settings.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: pad),
            settings.trailingAnchor.constraint(equalTo: side.trailingAnchor, constant: -pad),
            settings.bottomAnchor.constraint(equalTo: rule.topAnchor, constant: -Theme.m(6)),

            rule.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: pad),
            rule.trailingAnchor.constraint(equalTo: side.trailingAnchor, constant: -pad),
            rule.heightAnchor.constraint(equalToConstant: 1),
            rule.bottomAnchor.constraint(equalTo: tailView.topAnchor, constant: -Theme.m(6)),

            tailView.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: pad),
            tailView.trailingAnchor.constraint(equalTo: side.trailingAnchor, constant: -pad),
            tailView.bottomAnchor.constraint(equalTo: side.bottomAnchor, constant: -pad),
        ])
        for v in navViews { v.widthAnchor.constraint(equalTo: nav.widthAnchor).isActive = true }
    }

    // MARK: Overlays — the About sheet and the account popover

    /// Both float over the whole window: a scrim that eats the click behind it,
    /// and the panel itself. Only one is ever up.
    private func present(overlay: NSView, dim: Bool = true,
                         layout: (NSView, NSView) -> [NSLayoutConstraint]) {
        guard let root = window?.contentView else { return }
        dismissOverlay()
        let scrim = OverlayScrim()
        scrim.dims = dim
        // Outside the panel only. A click on the panel's own background — the
        // rail below the last section, the space beside a card — is a click on
        // the thing you are using, and closing on it loses whatever you were
        // halfway through. The scrim sits under the panel and should never see
        // these at all; the guard is here because "clicking the panel closes
        // the panel" is bad enough to be worth making impossible rather than
        // unlikely.
        scrim.onClick = { [weak self, weak overlay] point in
            guard let overlay = overlay, !overlay.frame.contains(point) else { return }
            self?.dismissOverlay(animated: true)
        }
        scrim.fill(root)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(overlay)
        NSLayoutConstraint.activate(layout(overlay, root))
        self.overlay = (scrim, overlay)
        // Settings and How it works rise into place over a scrim that fades
        // in, rather than appearing in one frame: the main window's pages
        // move, and the sheets were the one thing that snapped.
        if overlay is SettingsSheet || overlay is CommandsSheet {
            root.layoutSubtreeIfNeeded()
            Motion.fadeIn(scrim, duration: 0.28)
            Motion.rise(overlay, duration: 0.42, distance: 14, scale: 0.965)
        }

        overlayMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard e.keyCode == 53 else { return e }   // esc
            self?.dismissOverlay(animated: true)
            return nil
        }
    }

    /// Signed in or out. Signed out, the window goes and the sign-in takes
    /// its place: nothing in the app works without an account.
    @objc private func accountChanged() {
        refreshChrome()
        guard Account.required, window?.isVisible == true else { return }
        dismissOverlay()
        window?.close()
        Account.askToSignIn()
    }

    /// The shortcut caps, the mic and the account foot read live state.
    private func refreshChrome() {
        talk.refresh()
        mic.refresh()
        foot?.refresh()
    }

    /// `animated` lets a sheet drop away — quicker than it came — when you
    /// close it; replacing one overlay with another is always instant.
    func dismissOverlay(animated: Bool = false) {
        if overlay != nil { refreshChrome() }
        (overlay?.1 as? PaneView)?.paneDisappeared()
        if animated, let (scrim, panel) = overlay, panel is SettingsSheet || panel is CommandsSheet, !Motion.reduced {
            Motion.leave(scrim, duration: 0.2, lift: 0)
            Motion.leave(panel, duration: 0.18, lift: -8) {
                scrim.removeFromSuperview()
                panel.removeFromSuperview()
            }
        } else {
            overlay?.0.removeFromSuperview()
            overlay?.1.removeFromSuperview()
        }
        overlay = nil
        rows.forEach { $0.selected = ($0.key == currentKey || ($0.key == "agents" && currentKey.hasPrefix("agent-"))) }
        if let m = overlayMonitor { NSEvent.removeMonitor(m); overlayMonitor = nil }
    }

    func showAbout() {
        if overlay?.1 is AboutSheet { return dismissOverlay() }
        let sheet = AboutSheet()
        sheet.onClose = { [weak self] in self?.dismissOverlay() }
        present(overlay: sheet) { panel, root in [
            panel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            panel.widthAnchor.constraint(equalToConstant: Theme.px(440)),
        ]}
    }

    /// Settings, over the app rather than inside it. The window keeps showing
    /// the pane you were reading, dimmed behind the scrim — plainly still
    /// there, and plainly not what you are working in.
    func showSettings(tab: String? = nil) {
        if let open = overlay?.1 as? SettingsSheet {
            if let tab = tab { open.select(tab: tab) }
            return
        }
        // Something has to be behind the glass: a window opened straight into
        // Settings has no pane showing yet.
        if currentKey.isEmpty { select("overview") }

        let sheet = SettingsSheet()
        sheet.onClose = { [weak self] in self?.dismissOverlay(animated: true) }
        present(overlay: sheet) { panel, root in
            // Its own size when the window has room, and the window's size
            // less a margin when it doesn't — a small screen or the largest
            // text setting must not push the sheet off the edges.
            let w = panel.widthAnchor.constraint(equalToConstant: SettingsSheet.sheetWidth)
            let h = panel.heightAnchor.constraint(equalToConstant: SettingsSheet.sheetHeight)
            w.priority = .defaultHigh
            h.priority = .defaultHigh
            return [
                panel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
                panel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
                w, h,
                panel.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor,
                                             constant: -Theme.px(80)),
                panel.heightAnchor.constraint(lessThanOrEqualTo: root.heightAnchor,
                                              constant: -Theme.px(64)),
            ]
        }
        if let tab = tab { sheet.select(tab: tab) }
        sheet.paneAppeared()
        // Only the Settings row is lit while its sheet is up — the pane behind
        // the glass is not what you are working in. dismissOverlay puts the
        // pane's own row back.
        rows.forEach { $0.selected = ($0.key == "settings") }
    }

    /// How it works: what SayControl does with your voice, shown a point
    /// at a time, over the app the way Settings is. It was a page in the
    /// sidebar, but nobody works in it — you look and go back to what you
    /// were doing, and the pane you were on is still there behind the glass.
    func showCommands() {
        if overlay?.1 is CommandsSheet { return }
        if currentKey.isEmpty { select("overview") }

        let sheet = CommandsSheet()
        sheet.onClose = { [weak self] in self?.dismissOverlay(animated: true) }
        present(overlay: sheet) { panel, root in
            // Its own size when the window has room, and the window's size
            // less a margin when it doesn't, the way Settings fits.
            let w = panel.widthAnchor.constraint(equalToConstant: CommandsSheet.sheetWidth)
            let h = panel.heightAnchor.constraint(equalToConstant: CommandsSheet.sheetHeight)
            w.priority = .defaultHigh
            h.priority = .defaultHigh
            return [
                panel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
                panel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
                w, h,
                panel.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -Theme.px(80)),
                panel.heightAnchor.constraint(lessThanOrEqualTo: root.heightAnchor, constant: -Theme.px(64)),
            ]
        }
        sheet.paneAppeared()
        rows.forEach { $0.selected = ($0.key == "howto") }
    }

    func toggleAccountPopover() {
        if overlay?.1 is AccountPopover { return dismissOverlay() }
        let pop = AccountPopover()
        pop.onDismiss = { [weak self] in self?.dismissOverlay() }
        pop.onGoTo = { [weak self] key in
            self?.dismissOverlay()
            self?.select(key)
        }
        guard let foot = foot else { return }
        present(overlay: pop, dim: false) { panel, root in [
            panel.bottomAnchor.constraint(equalTo: foot.topAnchor, constant: -Theme.m(10)),
            panel.leadingAnchor.constraint(equalTo: foot.leadingAnchor),
            panel.widthAnchor.constraint(equalToConstant: Theme.px(288)),
        ]}
    }

    /// The old sidebar had a replacements-count chip; callers still poke this.
    func refreshChip() {}

    /// Text size changed: fonts are baked in at construction, so drop every
    /// pane and the window and rebuild them at the new scale.
    func rebuildAfterScaleChange() {
        dismissOverlay()
        let old = window
        panes[currentKey]?.paneDisappeared()
        currentKey = ""
        panes = [:]
        rows = []
        window = nil
        old?.delegate = nil   // skip windowWillClose, or the app hops to accessory mid-rebuild
        old?.close()
        present(selecting: "settings")
    }

    // MARK: Pane switching

    private func pane(for key: String) -> PaneView {
        if let existing = panes[key] { return existing }
        let made: PaneView
        switch key {
        case "dictionary":  made = DictionaryPane()
        case "insights":    made = InsightsPane()
        case "phrases":     made = PhrasesPane()
        case "tones":       made = TonesPane()
        case "help":        made = HelpPane()
        case "agents":         made = AgentsHubPane()
        case "agent-claude":   made = AgentsPane(.claude)
        case "agent-codex":    made = AgentsPane(.codex)
        case "agent-cursor":   made = AgentsPane(.cursor)
        case "agent-opencode": made = AgentsPane(.opencode)
        default:            made = OverviewPane()
        }
        panes[key] = made
        return made
    }

    /// The pane on screen — how the snapshot dev tool reaches inside a pane
    /// that has sub-tabs of its own.
    var currentPane: PaneView? { panes[currentKey] }

    func select(_ rawKey: String) {
        // Settings is a sheet, not a pane, and its seven sections answer to
        // their own names: select("billing") opens the sheet on Billing.
        if SettingsSheet.tabKeys.contains(rawKey) { return showSettings(tab: rawKey) }
        let key = Self.canonical(rawKey)
        if key == "settings" { return showSettings() }
        if key == "commands" { return showCommands() }
        dismissOverlay()
        guard key != currentKey else { return }
        // Pages move a little (Motion.Page, "Subtle"): the old one fades
        // off as it drifts, the new one arrives top to bottom from the side
        // its row is on, and the highlight slides between the rows. Not
        // before the window is up, and never under Reduce Motion.
        let animate = window?.isVisible == true && !Self.shooting && !Motion.reduced && !currentKey.isEmpty
        let dir: CGFloat = Self.rank(key) >= Self.rank(currentKey) ? 1 : -1
        panes[currentKey]?.paneDisappeared()
        for old in contentHost.subviews {
            guard animate else { old.removeFromSuperview(); continue }
            Motion.leave(old, lift: 4 * dir) { [weak self, weak old] in
                guard let self = self, let old = old else { return }
                // Clicked back to it mid-fade: it is the page again, leave it be.
                if old !== self.panes[self.currentKey] { old.removeFromSuperview() }
                Motion.settle(old)
            }
        }
        let p = pane(for: key)
        p.removeFromSuperview()
        Motion.settle(p)
        p.fill(contentHost)
        currentKey = key
        let was = rows.first { $0.selected }
        // A per-agent page has no row of its own — the Agents row stays
        // lit for it, so the sidebar always shows where you are.
        rows.forEach { $0.selected = ($0.key == key || ($0.key == "agents" && key.hasPrefix("agent-"))) }
        p.paneAppeared()
        if animate {
            slideSelection(from: was, to: rows.first { $0.selected })
            Motion.arrive(p, direction: dir, extraDelay: 0.06)
        }
        refreshChip()
    }

    /// Where a page sits down the sidebar, so a page further down arrives
    /// from below and one further up from above.
    private static func rank(_ key: String) -> Int {
        let order = ["overview", "insights", "dictionary", "phrases", "tones", "agents", "help"]
        return order.firstIndex(of: key.hasPrefix("agent-") ? "agents" : key) ?? order.count
    }

    /// The selected row's fill travels to the new row instead of jumping.
    private func slideSelection(from old: NavRow?, to new: NavRow?) {
        guard let old = old, let new = new, old !== new, let side = sidebarView,
              !old.isHidden, old.window != nil else { return }
        let slider = ColorView(color: Theme.navPick)
        slider.wantsLayer = true
        slider.layer?.cornerRadius = Theme.m(8)
        slider.frame = old.convert(old.bounds, to: side)
        side.addSubview(slider, positioned: .below, relativeTo: nil)
        new.paintsSelection = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.2, 0.5, 1)
            ctx.allowsImplicitAnimation = true
            slider.animator().frame = new.convert(new.bounds, to: side)
        }, completionHandler: {
            new.paintsSelection = true
            slider.removeFromSuperview()
        })
    }

    // MARK: Arriving from the first run

    /// Where the main window's pieces sit, measured from its top left, for
    /// the first-run window to grow into.
    struct Arrival {
        let frame: NSRect
        let side: NSRect
        let brand: NSRect
        let foot: NSRect
    }

    /// Builds the window on `key` without showing it, and says where it
    /// will be and where its sidebar, name and account are.
    func prepareArrival(selecting key: String) -> Arrival? {
        if window == nil { build() }
        guard let w = window, let side = sidebarView, let content = w.contentView else { return nil }
        installMainMenuIfNeeded()
        let wanted = Self.canonical(key)
        if wanted != currentKey { select(wanted) }
        content.layoutSubtreeIfNeeded()
        let h = content.bounds.height
        func fromTop(_ v: NSView) -> NSRect {
            let r = v.convert(v.bounds, to: nil)
            return NSRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
        }
        let s = fromTop(side)
        return Arrival(frame: w.frame, side: s, brand: fromTop(brand),
                       foot: foot.map(fromTop) ?? NSRect(x: s.minX, y: s.maxY - Theme.m(44), width: s.width, height: Theme.m(44)))
    }

    /// The prepared window takes over from the first-run one in place: it
    /// fades up over it, the name and the account already where they were,
    /// the sidebar's rows and the page arriving between them.
    func arrive(over setup: NSWindow) {
        guard let w = window else { return present(selecting: "overview") }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        w.setFrame(setup.frame, display: false)
        w.alphaValue = 0
        w.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            w.animator().alphaValue = 1
        }
        guard !Motion.reduced else { return }
        let pieces: [NSView] = [talk] + (navStack?.arrangedSubviews ?? []) + rows.filter { $0.key == "howto" }
        for (i, v) in pieces.enumerated() {
            Motion.rise(v, delay: 0.05 + Double(i) * 0.035, distance: Theme.m(8))
        }
        if let p = panes[currentKey] { Motion.arrive(p, extraDelay: 0.12) }
    }

    // MARK: Toast

    private var toastView: ToastView?
    private var toastTimer: Timer?

    /// A short confirmation at the bottom of the window — "Copied", "Added".
    /// With an action it stays up longer, so there is time to reach it.
    func toast(_ message: String, action: (title: String, run: () -> Void)? = nil) {
        guard let root = window?.contentView else { return }
        toastTimer?.invalidate()
        toastView?.removeFromSuperview()
        let t = ToastView(message, action: action.map { a in (a.title, { [weak self] in
            self?.toastTimer?.invalidate()
            self?.toastView?.removeFromSuperview()
            self?.toastView = nil
            a.run()
        }) })
        t.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(t)
        NSLayoutConstraint.activate([
            t.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            t.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Theme.px(26)),
        ])
        toastView = t
        toastTimer = Timer.scheduledTimer(withTimeInterval: action == nil ? 1.6 : 5, repeats: false) { [weak self] _ in
            self?.toastView?.removeFromSuperview()
            self?.toastView = nil
        }
    }

    // MARK: Menu (for Cmd+C/V inside the window)

    private var menuInstalled = false
    /// Also called by the first-run window, which opens before this one
    /// ever has: without an Edit menu, the ⌘V a dictation pastes with does
    /// nothing in the app's own text boxes.
    func installMainMenuIfNeeded() {
        guard !menuInstalled else { return }
        menuInstalled = true
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide SayControl", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit SayControl", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }
}


/// NSButton that runs a closure — the model-manager rows are built dynamically,
/// so target/selector plumbing per row would be noise.
final class HandlerButton: NSButton {
    private var handler: () -> Void = {}

    convenience init(_ title: String, _ handler: @escaping () -> Void) {
        self.init(title: title, target: nil, action: nil)
        self.handler = handler
        bezelStyle = .rounded
        font = .systemFont(ofSize: 11.5)
        setButtonType(.momentaryPushIn)
        setContentHuggingPriority(.required, for: .horizontal)
        target = self
        action = #selector(fire)
    }

    @objc private func fire() { handler() }
}

// MARK: - Permissions pane

