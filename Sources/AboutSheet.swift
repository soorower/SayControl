// The About sheet. It used to be a pane in the sidebar; in 2.1 it opens from
// the SayCtrl wordmark and floats over whatever pane you were reading.
import Cocoa

/// The dimmed backdrop behind a sheet or a popover. Swallows the click that
/// lands on it, so anything underneath stays untouched.
final class OverlayScrim: NSView {
    /// Handed the click's location in the scrim's own coordinates, which are
    /// the window root's — so the caller can compare it against the panel it
    /// is guarding and ignore a click that landed inside it.
    var onClick: (NSPoint) -> Void = { _ in }
    /// Popovers dim nothing — they only need the click-catcher.
    var dims = true { didSet { blur.isHidden = !dims || !isDark } }
    /// In the dark theme the window is already dim, so a wash alone leaves
    /// the sidebar behind the glass as legible as the sheet's own rail. A
    /// blur under a deeper wash puts it plainly behind.
    private let blur: NSVisualEffectView = {
        let v = NSVisualEffectView()
        v.blendingMode = .withinWindow
        v.material = .fullScreenUI
        v.state = .active
        v.alphaValue = 0.8
        return v
    }()
    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    init() {
        super.init(frame: .zero)
        blur.fill(self)
        blur.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        onClick(convert(event.locationInWindow, from: nil))
    }
    override var mouseDownCanMoveWindow: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        wantsLayer = true
        blur.isHidden = !dims || !isDark
        let wash = isDark ? Theme.hex(0x000000, 0.55) : Theme.hex(0x18140E, 0.34)
        layer?.backgroundColor = dims ? wash.cgColor : NSColor.clear.cgColor
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// A rounded panel that floats over the window — the About sheet, the
/// account popover. Two elevations, as the refresh mockup draws them: a
/// sheet is the window's own colour under the deep sheet shadow, the one
/// that sits highest; a popover is white with the sidebar's hairline and a
/// soft, short shadow.
class FloatingPanel: NSView {
    enum Style { case sheet, popover }
    let body = NSStackView()
    private let style: Style

    init(padding: CGFloat, radius: CGFloat, spacing: CGFloat, alignment: NSLayoutConstraint.Attribute,
         style: Style = .popover) {
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.borderWidth = 1

        body.orientation = .vertical
        body.alignment = alignment
        body.spacing = spacing
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func add(_ view: NSView, stretch: Bool = true) {
        body.addArrangedSubview(view)
        if stretch {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.shadowColor = Theme.hex(0x141822).cgColor
        switch style {
        case .sheet:
            layer?.backgroundColor = Theme.paper.cgColor
            layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.08) : Theme.hex(0x000000, 0.10)).cgColor
            layer?.shadowOpacity = dark ? 0.6 : 0.26
            layer?.shadowRadius = 30
            layer?.shadowOffset = CGSize(width: 0, height: -24)
        case .popover:
            layer?.backgroundColor = Theme.surface.cgColor
            layer?.borderColor = Theme.sidebarLine.cgColor
            layer?.shadowOpacity = dark ? 0.35 : 0.10
            layer?.shadowRadius = 15
            layer?.shadowOffset = CGSize(width: 0, height: -10)
        }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: - About

final class AboutSheet: FloatingPanel {
    var onClose: () -> Void = {}

    init() {
        super.init(padding: Theme.m(26), radius: Theme.m(16),
                   spacing: 0, alignment: .centerX, style: .sheet)

        let side = Theme.m(36)
        let markView = NSImageView(image: Theme.mark(side))
        markView.translatesAutoresizingMaskIntoConstraints = false
        markView.widthAnchor.constraint(equalToConstant: side).isActive = true
        markView.heightAnchor.constraint(equalToConstant: side).isActive = true
        add(markView, stretch: false)

        // The name is the app talking, so it is set in the display face, at
        // medium: a name, not a shout.
        let title = Theme.display("SayControl", 22, .medium)
        let tagline = Theme.para("Hold fn, talk, release — it's written.",
                                 13 * 1.2, .regular, Theme.muted, lineHeight: 1.3, align: .center)
        add(title, stretch: false)
        add(tagline)
        body.setCustomSpacing(Theme.m(12), after: markView)
        // The Bengali gloss sat between these two and carried the 10pt; with the
        // name no longer a Bengali word, the tagline inherits the gap.
        body.setCustomSpacing(Theme.m(4), after: title)

        // A user's copy has no key to speak of, and accounts are on the way;
        // the developers' build keeps the three lines it always had. They
        // sit in one group, the way Settings holds its rows, each with the
        // tile Privacy gives the same promise.
        let facts = RowGroup()
        for (symbol, hue, line) in Config.retail ? [
            ("lock.fill", Theme.Hue.green, "Cloud dictation sends your audio out to be written down, and we don't keep it. A model on this Mac keeps it here."),
            ("creditcard", .slate, "Free has \(Account.grouped(Account.freeWordsPerWeek)) cloud words a week. Pro is $\(Account.proDollarsPerMonth) a month, unlimited. Models on this Mac and your own keys cost nothing."),
            ("eye.slash", .slate, "No telemetry. Your dictionary, phrases and history stay on this Mac."),
        ] : [
            ("key", Theme.Hue.amber, "Your audio goes to your own key. Nothing else leaves this Mac."),
            ("eye.slash", .slate, "No account, no subscription, no telemetry."),
            ("wrench.and.screwdriver", .violet, "The developers' build: every provider, every key box."),
        ] {
            facts.add(fact(symbol, hue, line), vertical: 10)
        }
        add(facts)
        body.setCustomSpacing(Theme.m(10), after: tagline)

        let siteLink = LinkLabel("saycontrol.com", url: "https://saycontrol.com")
        let version = Theme.meta("Version \(Updates.version)", 11.5)
        let foot = Theme.hstack([version, Theme.spacer(), siteLink], spacing: Theme.m(10))
        add(foot)
        body.setCustomSpacing(Theme.m(16), after: facts)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func fact(_ symbol: String, _ hue: Theme.Hue, _ line: String) -> NSView {
        let words = Theme.para(line, 12.5 * 1.2, .regular, Theme.ink2, lineHeight: 1.25)
        let row = Theme.hstack([IconTile(symbol, hue, side: 26, icon: 12), words], spacing: Theme.m(12))
        words.setContentHuggingPriority(.init(1), for: .horizontal)
        row.alignment = .centerY
        row.distribution = .fill
        return row
    }
}

/// A quiet underlined link: opens a page in the browser, or does something
/// small in place ("Forgot password?").
final class LinkLabel: NSView {
    private let field: NSTextField
    private let rule = ColorView(color: Theme.hairline)
    private let action: () -> Void
    private var hovering = false { didSet { restyle() } }

    var title: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }
    /// Off while what it started is still running: dimmed, and clicks do nothing.
    var isEnabled = true {
        didSet { alphaValue = isEnabled ? 1 : 0.5; window?.invalidateCursorRects(for: self) }
    }

    convenience init(_ title: String, url: String) {
        self.init(title) { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }
    }

    init(_ title: String, action: @escaping () -> Void) {
        self.action = action
        field = Theme.text(title, 12.5, .regular, Theme.muted)
        field.font = .systemFont(ofSize: Theme.m(12))
        super.init(frame: .zero)
        for v in [field, rule] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: topAnchor),
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 1),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor),
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
    override func mouseUp(with event: NSEvent) {
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action()
    }
    override func resetCursorRects() { if isEnabled { addCursorRect(bounds, cursor: .pointingHand) } }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Ink on hover, not ember: a link is navigation, and ember is kept
    /// for what is live or switched on.
    private func restyle() {
        field.textColor = hovering ? Theme.ink : Theme.muted
        rule.color = hovering ? Theme.ink2 : Theme.hairline
    }
}
