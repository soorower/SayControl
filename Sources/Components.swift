// The 2.1 controls, straight off design/sayctrl-ui-prototype.html: text tabs,
// pill switchers, list rows, model rows, chips, meters. Every pane is built
// out of these, so the look lives in one place.
import Cocoa

// MARK: - Hover

/// A row that lights up under the cursor.
protocol Hoverable: AnyObject {
    func setHovering(_ on: Bool)
}

/// Exactly one row is lit at a time.
///
/// AppKit drops a `mouseExited` whenever rows are rebuilt or shift under a
/// stationary cursor — scroll the Dictionary quickly and half the list used to
/// stay highlighted. Every row reports through here, and the row that lights up
/// puts the previous one out.
final class HoverArbiter {
    static let shared = HoverArbiter()
    private weak var current: (AnyObject & Hoverable)?

    func enter(_ row: AnyObject & Hoverable) {
        if let old = current, old !== row { old.setHovering(false) }
        current = row
        row.setHovering(true)
    }

    func exit(_ row: AnyObject & Hoverable) {
        row.setHovering(false)
        if current === row { current = nil }
    }
}

/// Holds its content's full size at all times and fades it in and out, so a
/// row's actions can appear on hover without the row changing shape. Hidden,
/// it is also invisible to the mouse.
final class FadeBox: NSView {
    var shown = false {
        didSet {
            guard shown != oldValue else { return }
            alphaValue = shown ? 1 : 0
        }
    }

    init(_ content: NSView) {
        super.init(frame: .zero)
        alphaValue = 0
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { shown ? super.hitTest(point) : nil }
}

// MARK: - Text tabs (they replaced every NSSegmentedControl)

/// A row of underlined text labels over a hairline. `.sub` is the smaller
/// second rank, with an ember underline instead of an ink one.
final class TextTabs: NSView {
    private var labels: [TabLabel] = []
    private let rule = ColorView(color: Theme.hairline)
    private let sub: Bool
    private(set) var index = 0
    var onPick: (Int) -> Void = { _ in }

    /// `centered` puts the names in the middle of the rule instead of at its
    /// left end; `size` overrides the face the style would pick; `accessory`
    /// sits at the right end of the row, level with the names.
    ///
    /// The names ride a FlowRow rather than a stack view because they have to
    /// WRAP. Theme.text gives every label tail truncation and a compression
    /// resistance of 250, so a row that runs out of width doesn't overflow —
    /// it quietly eats itself: at nine providers the ninth rendered as "…"
    /// and Local vanished off the end, neither one pickable.
    init(_ titles: [String], selected: Int = 0, sub: Bool = false, centered: Bool = false,
         size: CGFloat? = nil, accessory: NSView? = nil, onPick: @escaping (Int) -> Void = { _ in }) {
        self.sub = sub
        self.onPick = onPick
        self.index = selected
        super.init(frame: .zero)

        labels = titles.enumerated().map { i, t in
            let l = TabLabel(t, sub: sub, size: size)
            l.onClick = { [weak self] in self?.pick(i) }
            return l
        }
        let row = FlowRow(hgap: sub ? 22 : 26, vgap: sub ? 9 : 11, centered: centered)
        // A name is wider selected than not, and `fittingSize` would hand the
        // packing that difference — so a click could shuffle the row, or push
        // the last name onto a second line. Every box is measured selected.
        row.measure = { view in
            guard let tab = view as? TabLabel else { return view.fittingSize }
            return NSSize(width: tab.reservedWidth, height: tab.fittingSize.height)
        }
        row.set(labels)
        row.translatesAutoresizingMaskIntoConstraints = false
        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        addSubview(rule)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.topAnchor.constraint(equalTo: row.bottomAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        if let accessory = accessory, let first = labels.first {
            accessory.translatesAutoresizingMaskIntoConstraints = false
            addSubview(accessory)
            NSLayoutConstraint.activate([
                row.trailingAnchor.constraint(equalTo: accessory.leadingAnchor, constant: -Theme.m(16)),
                accessory.trailingAnchor.constraint(equalTo: trailingAnchor),
                accessory.centerYAnchor.constraint(equalTo: first.textCenterY),
                accessory.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            ])
        } else {
            row.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
        }
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// A disabled row keeps its look from whoever dims it (the pattern is a
    /// FormRow at 0.45) — this only makes the clicks land nowhere.
    var isEnabled = true

    func pick(_ i: Int) {
        guard isEnabled, i != index, i >= 0, i < labels.count else { return }
        index = i
        restyle()
        onPick(i)
    }

    /// Move the selection without calling back — for restoring a remembered tab.
    func setIndex(_ i: Int) {
        guard i >= 0, i < labels.count else { return }
        index = i
        restyle()
    }

    private func restyle() {
        for (i, l) in labels.enumerated() { l.selected = (i == index) }
        rule.color = sub ? Theme.hairsoft : Theme.hairline
    }
    override func viewDidChangeEffectiveAppearance() { restyle() }
}

/// One label in a TextTabs row, with its own underline.
final class TabLabel: NSView {
    private let field: NSTextField
    private let bar = ColorView(color: .clear, radius: 1)
    private let sub: Bool
    private let size: CGFloat
    private var hovering = false { didSet { restyle() } }
    var selected = false { didSet { restyle() } }
    var onClick: () -> Void = {}

    init(_ title: String, sub: Bool, size: CGFloat? = nil) {
        self.sub = sub
        self.size = size ?? (sub ? 13.5 : 14.5)
        field = Theme.text(title, self.size, .medium, Theme.muted)
        super.init(frame: .zero)
        field.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        addSubview(bar)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: topAnchor),
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: field.bottomAnchor, constant: Theme.px(sub ? 9 : 11) - 2),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 2),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The width this name reserves in a row — always measured at the SELECTED
    /// weight, the wider of the two, so moving the selection can never reflow
    /// the row or bump a later name onto another line. An unselected name is a
    /// hair narrower than its box and sits at the left of it, which at 22 pt
    /// of spacing is invisible.
    var reservedWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: Theme.px(size), weight: .semibold)
        return ceil((field.stringValue as NSString).size(withAttributes: [.font: font]).width)
    }

    /// The middle of the name, for lining something up with the row.
    var textCenterY: NSLayoutYAxisAnchor { field.centerYAnchor }

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

    private func restyle() {
        field.textColor = selected ? Theme.ink : (hovering ? Theme.ink2 : Theme.muted)
        field.font = .systemFont(ofSize: Theme.px(size), weight: selected ? .semibold : .medium)
        // Through `color`, not the layer: a ColorView repaints its own colour
        // at the next display, and a bar written to the layer vanished until
        // the first click.
        bar.color = selected ? (sub ? Theme.ink2 : Theme.ink) : .clear
    }
    override func viewDidChangeEffectiveAppearance() { restyle() }
}

// MARK: - Pill switcher

/// How big a switcher's pills are: small for a setting in a row, medium for
/// a switch that leads its row (a place's tone), large for a section's main
/// control.
enum PillSize {
    case small, medium, large
    var pillRadius: CGFloat { Theme.m(self == .large ? 8 : self == .medium ? 7 : 6) }
}

/// The small segmented switcher that survived the redesign — appearance,
/// text size, cleanup level. A sunk trough with one raised pill in it.
final class PillSwitcher: NSView {
    private var pills: [PillLabel] = []
    private let row: NSStackView
    private let fixedWidth: CGFloat?
    /// The trough's padding around the pills.
    private let inset: CGFloat
    private(set) var index = 0
    var onPick: (Int) -> Void = { _ in }
    /// Which pill the pointer is on, nil when it leaves them — for a
    /// switcher whose choices preview on hover (Tones).
    var onHover: (Int?) -> Void = { _ in }
    /// The raised chip under the picked pill, when it slides (`previews`).
    private var thumb: PillThumb?
    private var thumbPins: [NSLayoutConstraint] = []

    /// `symbols` puts an SF Symbol before each title; `width` fixes the whole
    /// trough and shares it equally, so two switchers can line up; `large`
    /// is the size for a switcher that is the section's main control rather
    /// than a setting in a row. `previews` is for a switcher whose choices
    /// preview on hover (Tones): the picked one rides a raised chip that
    /// slides to the next pick, the one under the pointer gets a soft fill,
    /// and pointing answers with the app in the background too, the way a
    /// page in a browser does.
    init(_ titles: [String], selected: Int = 0, symbols: [String]? = nil, width: CGFloat? = nil,
         size: PillSize = .small, previews: Bool = false, onPick: @escaping (Int) -> Void = { _ in }) {
        self.onPick = onPick
        self.index = selected
        self.fixedWidth = width
        inset = size == .medium ? Theme.m(3) : 2
        let made = titles.enumerated().map { i, t in PillLabel(t, symbol: symbols?[i], size: size) }
        row = NSStackView(views: made)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(size == .small ? 8 : 10)
        layer?.borderWidth = 1

        pills = made
        for (i, p) in pills.enumerated() {
            p.onClick = { [weak self] in self?.pick(i) }
            p.onHover = { [weak self] on in self?.onHover(on ? i : nil) }
            if previews {
                p.raised = false
                p.hoverFill = true
                p.inBackground = true
            }
        }
        if previews {
            let t = PillThumb(radius: size.pillRadius)
            t.translatesAutoresizingMaskIntoConstraints = false
            addSubview(t)
            thumb = t
        }
        row.orientation = .horizontal
        // The medium switch's pills touch, as the mockup's do.
        row.spacing = size == .medium ? 0 : 2
        // Keep its natural width — a form row would otherwise stretch the
        // trough across the whole card — and never give it up to the row's
        // words: squeezed, it cut "Always shown" to "Always sh".
        row.setHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        if let width = width {
            row.distribution = .fillEqually
            widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
        ])
        restyle()
        moveThumb(animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Its natural width, so "hug" means something: a plain view has no
    /// intrinsic size, and without one a form row hands the trough all of
    /// the row's slack and stretches "Light" across the card.
    override var intrinsicContentSize: NSSize {
        if fixedWidth != nil { return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
        return NSSize(width: row.fittingSize.width + inset * 2, height: NSView.noIntrinsicMetric)
    }

    func pick(_ i: Int) {
        guard i != index, i >= 0, i < pills.count else { return }
        index = i
        restyle()
        moveThumb(animated: true)
        onPick(i)
    }
    func setIndex(_ i: Int) {
        guard i >= 0, i < pills.count else { return }
        index = i
        restyle()
        moveThumb(animated: false)
    }

    private func restyle() { for (i, p) in pills.enumerated() { p.selected = (i == index) } }

    /// Pins the chip under the picked pill; on a click it glides there over
    /// 300 ms with a touch of overshoot, as design/tones-redesign.html's does.
    private func moveThumb(animated: Bool) {
        guard let thumb = thumb, index < pills.count else { return }
        NSLayoutConstraint.deactivate(thumbPins)
        let pill = pills[index]
        thumbPins = [
            thumb.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
            thumb.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
            thumb.topAnchor.constraint(equalTo: pill.topAnchor),
            thumb.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
        ]
        NSLayoutConstraint.activate(thumbPins)
        guard animated, window != nil, !Motion.reduced else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.18, 0.45, 1)
            ctx.allowsImplicitAnimation = true
            layoutSubtreeIfNeeded()
        }
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Theme.wellFill.cgColor
        layer?.borderColor = Theme.hairsoft.cgColor
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true; restyle() }
}

final class PillLabel: NSView {
    private let field: NSTextField
    private let icon: NSImageView?
    private var hovering = false {
        didSet {
            restyle()
            fadeNext = hoverFill && hovering != oldValue
            needsDisplay = true
            if hovering != oldValue { onHover(hovering) }
        }
    }
    var selected = false { didSet { restyle(); needsDisplay = true } }
    var onClick: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }
    private let size: CGFloat
    /// Paints its own raised chip when picked. Off in a switcher whose chip
    /// slides (PillThumb), which paints it instead.
    var raised = true
    /// A soft fill while pointed at, so the pill you're on reads apart from
    /// the picked one.
    var hoverFill = false
    /// Answers the pointer while the app is in the background too.
    var inBackground = false { didSet { updateTrackingAreas() } }
    /// The hover fill fades in and out rather than snapping.
    private var fadeNext = false

    /// The mockup's `.seg b`: 12 px words, 3 px above and below, 11 at the
    /// sides; the selected one semibold ink on the raised white chip. Medium
    /// is the tone switch in design/tones-preview-options.html: 12.5 px
    /// words, 28 tall, 13 at the sides. Large is 14.5 px words with room to
    /// be a button: 7 above and below, 18 at the sides.
    init(_ title: String, symbol: String? = nil, size pill: PillSize = .small) {
        let large = pill == .large
        size = pill == .large ? 14.5 : pill == .medium ? 12.5 : 12
        field = Theme.text(title, size, .medium, Theme.muted)
        icon = symbol.flatMap { Theme.symbol($0, Theme.m(large ? 13 : 11), .medium) }.map { NSImageView(image: $0) }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = pill.pillRadius
        var views: [NSView] = []
        if let icon = icon {
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: Theme.m(large ? 16 : 13)).isActive = true
            views.append(icon)
        }
        views.append(field)
        let row = Theme.hstack(views, spacing: Theme.m(large ? 7 : 5))
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        let padX = Theme.m(pill == .large ? 18 : pill == .medium ? 13 : 11)
        let padY = Theme.m(large ? 7 : 3)
        // As wide as the title is when picked: semibold is wider than
        // medium, and a chip that grew on the click clipped its own word.
        let bold = (title as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: Theme.m(size), weight: .semibold)]).width
        let iconW = icon == nil ? 0 : Theme.m(large ? 16 : 13) + Theme.m(large ? 7 : 5)
        widthAnchor.constraint(greaterThanOrEqualToConstant: ceil(bold + iconW + padX * 2) + 1).isActive = true
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: centerXAnchor),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: padX),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -padX),
        ])
        if pill == .medium {
            // A set height, the words centred in it.
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: Theme.m(28)),
                row.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: topAnchor, constant: padY),
                row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padY),
            ])
        }
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .inVisibleRect,
                                                              inBackground ? .activeAlways : .activeInActiveApp],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onClick() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { inBackground }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override var mouseDownCanMoveWindow: Bool { false }

    private func restyle() {
        field.textColor = selected ? Theme.ink : (hovering ? Theme.ink : Theme.muted)
        field.font = .systemFont(ofSize: Theme.m(size), weight: selected ? .semibold : .medium)
        icon?.contentTintColor = selected ? Theme.ink : (hovering ? Theme.ink : Theme.muted)
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        guard let layer = layer else { return }
        let chip = selected && raised
        let fill: NSColor = chip ? Theme.segPick : (hoverFill && hovering && !selected ? Theme.navHover : .clear)
        if fadeNext, !Motion.reduced {
            let fade = CABasicAnimation(keyPath: "backgroundColor")
            fade.fromValue = layer.presentation()?.backgroundColor ?? layer.backgroundColor ?? NSColor.clear.cgColor
            fade.toValue = fill.cgColor
            fade.duration = 0.15
            layer.add(fade, forKey: "hover")
        }
        fadeNext = false
        layer.backgroundColor = fill.cgColor
        layer.borderWidth = chip ? 0.5 : 0
        layer.borderColor = Theme.segEdge.cgColor
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = chip ? (isDark ? 0.35 : 0.10) : 0
        layer.shadowRadius = 1.5
        layer.shadowOffset = CGSize(width: 0, height: -1)
    }
    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// The picked pill's raised chip, as its own view so it can slide from one
/// pill to the next instead of jumping (PillSwitcher, `previews`).
private final class PillThumb: NSView {
    init(radius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = Theme.segPick.cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = Theme.segEdge.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = dark ? 0.35 : 0.10
        layer?.shadowRadius = 1.5
        layer?.shadowOffset = CGSize(width: 0, height: -1)
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: - Small pieces

/// The little uppercase tag: LIVE, NO LIVE, CURRENT.
final class Badge: NSView {
    enum Look { case ember, grey, moss }
    private let look: Look

    init(_ text: String, _ look: Look = .ember) {
        self.look = look
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.px(5)
        layer?.borderWidth = look == .grey ? 1 : 0
        let color: NSColor = look == .ember ? Theme.emberInk : (look == .moss ? Theme.moss : Theme.muted)
        let f = Theme.text("", 10.5, .semibold, color)
        f.attributedStringValue = NSAttributedString(string: text.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: Theme.px(10.5), weight: .semibold),
            .foregroundColor: color, .kern: Theme.px(10.5) * 0.04,
        ])
        f.translatesAutoresizingMaskIntoConstraints = false
        addSubview(f)
        NSLayoutConstraint.activate([
            f.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.px(7)),
            f.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.px(7)),
            f.topAnchor.constraint(equalTo: topAnchor, constant: Theme.px(3)),
            f.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.px(3)),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        switch look {
        case .ember: layer?.backgroundColor = Theme.emberSoft.cgColor
        case .grey:  layer?.backgroundColor = Theme.wellFill.cgColor
                     layer?.borderColor = Theme.hairline.cgColor
        case .moss:  layer?.backgroundColor = Theme.mossSoft.cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// The refresh's `.chip`: a capsule on a soft fill, no outline. The Insights
/// peak chips are the neutral one, sunk, with their figures in ink. A list
/// row's "Learned" is the moss one, which carries a dot as well as a colour,
/// the way every state chip does.
final class Chip: NSView {
    enum Look { case neutral, ok }
    private let look: Look

    /// "busiest day **Mon · 49m**": the lead muted, the figures in ink —
    /// tabular digits a step up in weight, not a bold that shouts.
    init(_ lead: String, _ bold: [String]) {
        look = .neutral
        super.init(frame: .zero)
        let s = NSMutableAttributedString()
        let plain: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: Theme.m(11.5)),
            .foregroundColor: Theme.muted,
        ]
        let strong: [NSAttributedString.Key: Any] = [
            .font: Theme.digits(11.5, .medium),
            .foregroundColor: Theme.ink,
        ]
        if !lead.isEmpty { s.append(NSAttributedString(string: lead + " ", attributes: plain)) }
        for (i, b) in bold.enumerated() {
            if i > 0 { s.append(NSAttributedString(string: " · ", attributes: plain)) }
            s.append(NSAttributedString(string: b, attributes: strong))
        }
        build(NSTextField(labelWithAttributedString: s), dot: false, height: 22, pad: 10)
    }

    /// A one-word tag. `compact` is the size that sits inside a list row
    /// (the mockup's 19 px row chip) rather than on its own.
    init(tag: String, _ look: Look, compact: Bool = false) {
        self.look = look
        super.init(frame: .zero)
        let f = NSTextField(labelWithString: tag)
        f.font = .systemFont(ofSize: Theme.m(compact ? 10.5 : 11.5), weight: .medium)
        f.textColor = look == .ok ? Theme.moss : Theme.muted
        build(f, dot: look == .ok, height: compact ? 19 : 22, pad: compact ? 7 : 9)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build(_ label: NSTextField, dot: Bool, height: CGFloat, pad: CGFloat) {
        wantsLayer = true
        var parts: [NSView] = []
        if dot {
            let side = Theme.m(height < 22 ? 5 : 6)
            let d = ColorView(color: Theme.moss, radius: side / 2)
            d.translatesAutoresizingMaskIntoConstraints = false
            d.widthAnchor.constraint(equalToConstant: side).isActive = true
            d.heightAnchor.constraint(equalToConstant: side).isActive = true
            parts.append(d)
        }
        parts.append(label)
        let row = Theme.hstack(parts, spacing: Theme.m(5))
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(pad)),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.m(pad)),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Theme.m(height)),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = (look == .ok ? Theme.mossSoft : Theme.wellFill).cgColor
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// Big serif number over a small uppercase label. Overview and Insights both
/// open on a row of these.
final class StatTile: NSView {
    private let number: NSTextField
    private let unit: NSTextField

    init(_ value: String, _ label: String, unit unitText: String = "") {
        number = Theme.display(value, 30, .semibold, tracking: -0.03)
        unit = Theme.text(unitText, 15, .medium, Theme.muted)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(12)
        layer?.borderWidth = 1

        unit.isHidden = unitText.isEmpty
        let top = Theme.hstack([number, unit], spacing: 2)
        top.alignment = .firstBaseline
        let column = Theme.vstack([top, Theme.eyebrow(label)], spacing: Theme.px(9))
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: Theme.px(18)),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.px(20)),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Theme.px(20)),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.px(18)),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ value: String) { Theme.setDisplay(number, value) }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Theme.surface.cgColor
        layer?.borderColor = Theme.hairline.cgColor
        Theme.shadow(layer)
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// A keyboard cap — fn, ⌥, esc.
///
/// It repaints itself when the appearance changes. Baking the colours in at
/// build time left the caps in Settings › Shortcuts white in dark mode, with
/// the label's light ink on top of them and nothing readable in between.
final class KeyCapView: NSView {
    /// `small` is the sidebar's cap: 20 tall in the refresh mockup, where the
    /// full-size one sits in Settings rows.
    init(_ text: String, small: Bool = false) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(5)
        layer?.borderWidth = 1
        let f = Theme.text(text, 12.5, .medium, Theme.ink2)
        if small { f.font = .systemFont(ofSize: Theme.m(11), weight: .medium) }
        f.alignment = .center
        f.translatesAutoresizingMaskIntoConstraints = false
        addSubview(f)
        let padX = small ? Theme.m(6) : Theme.px(9)
        NSLayoutConstraint.activate([
            f.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padX),
            f.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padX),
            f.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: small ? Theme.m(20) : Theme.px(30)),
        ])
        if small {
            heightAnchor.constraint(equalToConstant: Theme.m(20)).isActive = true
        } else {
            NSLayoutConstraint.activate([
                f.topAnchor.constraint(equalTo: topAnchor, constant: Theme.px(5)),
                f.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.px(5)),
            ])
        }
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Theme.keyFill.cgColor
        layer?.borderColor = Theme.hairline.cgColor
        Theme.lip(layer)
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

func keyCap(_ text: String) -> NSView { KeyCapView(text) }

// MARK: - Rows

/// Left column, right controls, pinned with explicit constraints rather than
/// a stack spacer — a spacer wins the width fight against a wrapping label and
/// squeezes the text into a narrow column.
func splitRow(_ left: NSView, _ right: NSView, into host: NSView,
              gap: CGFloat = 16, vertical: CGFloat = 3) {
    left.setContentHuggingPriority(.init(1), for: .horizontal)
    left.setContentCompressionResistancePriority(.init(200), for: .horizontal)
    right.setContentHuggingPriority(.required, for: .horizontal)
    right.setContentCompressionResistancePriority(.required, for: .horizontal)
    // A stack view runs its own hugging, and ignores the view-level priority —
    // without this the right-hand stack stretches and its buttons drift left.
    (right as? NSStackView)?.setHuggingPriority(.required, for: .horizontal)
    (left as? NSStackView)?.setHuggingPriority(.init(1), for: .horizontal)
    for v in [left, right] {
        v.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(v)
    }
    NSLayoutConstraint.activate([
        left.leadingAnchor.constraint(equalTo: host.leadingAnchor),
        left.topAnchor.constraint(equalTo: host.topAnchor, constant: Theme.px(vertical)),
        left.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -Theme.px(vertical)),
        left.trailingAnchor.constraint(equalTo: right.leadingAnchor, constant: -Theme.px(gap)),

        right.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        right.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        right.topAnchor.constraint(greaterThanOrEqualTo: host.topAnchor, constant: Theme.px(vertical)),
    ])
}

/// The two halves of a grouped row's left side: a 13 px regular label — the
/// weight a Mac settings row uses; medium made every row shout — and a
/// 12 px muted line of help under it, one line by rule. Anything longer
/// belongs in the row's tooltip.
enum RowText {
    static func title(_ s: String, _ color: NSColor = Theme.ink) -> NSTextField {
        let f = Theme.text(s, 13, .regular, color)
        f.font = .systemFont(ofSize: Theme.m(13))
        return f
    }
    static func help(_ s: String) -> NSTextField {
        Theme.para(s, 12 * 1.2, .regular, Theme.muted, lineHeight: 1.22)
    }

    /// New words for a help line, in its own face and leading. A plain
    /// `stringValue` drops the paragraph style, and a line that changes
    /// (a count, a browser's name) sat tighter than its neighbours.
    static func setHelp(_ f: NSTextField, _ s: String) {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.22
        f.attributedStringValue = NSAttributedString(string: s, attributes: [
            .font: f.font ?? NSFont.systemFont(ofSize: Theme.m(12)),
            .foregroundColor: f.textColor ?? Theme.muted, .paragraphStyle: style,
        ])
    }

    /// A row's left side: the picture, if it has one, then the name over its
    /// help. The help is pinned to the words' column, not the whole side —
    /// pinned wider, it would wrap as if it ran under the tile.
    static func lead(_ title: NSTextField, _ help: NSTextField, icon: NSView?, badge: NSView? = nil) -> NSView {
        // A badge rides on the title's line: the "Pro" beside a shortcut
        // only Pro has.
        let top: NSView = badge.map { b -> NSView in
            let line = Theme.hstack([title, b], spacing: Theme.m(7))
            line.alignment = .centerY
            return line
        } ?? title
        let words = Theme.vstack([top, help], spacing: Theme.m(2))
        words.alignment = .leading
        help.widthAnchor.constraint(equalTo: words.widthAnchor).isActive = true
        guard let icon = icon else { return words }
        words.setHuggingPriority(.init(1), for: .horizontal)
        let side = Theme.hstack([icon, words], spacing: Theme.m(12))
        side.alignment = .centerY
        // Fill, not the default gravity areas: the words take the width the
        // row gives them. Left at their own size, a line that arrives later
        // wrapped to the width of the title above it.
        side.distribution = .fill
        return side
    }

    /// The `.srow` layout: words left, control right, both centred on the
    /// row — splitRow pins the words to the top, which leaves a one-line
    /// label riding high beside a taller control. The row is as tall as the
    /// taller side and no taller; the 12 px gap is the mockup's.
    static func layout(_ left: NSView, _ right: NSView, into host: NSView) {
        left.setContentHuggingPriority(.init(1), for: .horizontal)
        left.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        right.setContentHuggingPriority(.required, for: .horizontal)
        right.setContentCompressionResistancePriority(.required, for: .horizontal)
        (right as? NSStackView)?.setHuggingPriority(.required, for: .horizontal)
        (left as? NSStackView)?.setHuggingPriority(.init(1), for: .horizontal)
        for v in [left, right] {
            v.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(v)
        }
        let snug = host.heightAnchor.constraint(equalToConstant: 0)
        snug.priority = .init(200)
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            left.trailingAnchor.constraint(equalTo: right.leadingAnchor, constant: -Theme.m(12)),
            left.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            left.topAnchor.constraint(greaterThanOrEqualTo: host.topAnchor),
            right.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            right.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            right.topAnchor.constraint(greaterThanOrEqualTo: host.topAnchor),
            snug,
        ])
    }
}

/// Title + explanation on the left, anything you like on the right. `icon`
/// (an IconTile) goes in front for a row that is a thing — a folder, a
/// kind of data — rather than a switch; `tip` carries whatever the one line
/// of help had no room for.
final class FormRow: NSView {
    private let detailField: NSTextField

    init(_ title: String, _ detail: String = "", controls: [NSView], titleColor: NSColor = Theme.ink,
         icon: NSView? = nil, tip: String? = nil, badge: NSView? = nil) {
        // Always built, even when empty: a line that arrives later (a count
        // still being totted up) has somewhere to land.
        detailField = RowText.help(detail)
        super.init(frame: .zero)
        detailField.isHidden = detail.isEmpty
        let left = RowText.lead(RowText.title(title, titleColor), detailField, icon: icon, badge: badge)
        let right = Theme.hstack(controls, spacing: Theme.m(8))
        // No padding of its own: the group it sits in pads every row alike.
        RowText.layout(left, right, into: self)
        toolTip = tip
    }
    required init?(coder: NSCoder) { fatalError() }

    var detail: String {
        get { detailField.stringValue }
        set {
            RowText.setHelp(detailField, newValue)
            detailField.isHidden = newValue.isEmpty
        }
    }
}

/// A permission: its picture, what it is, what it is for, and on the right
/// its state — a moss "Allowed" chip once macOS has said yes, or an amber
/// "Needs access" chip with Set Up beside it, which opens the prompt or the
/// pane. Every row the same shape, so the eye reads the column of chips as
/// the state of the Mac. An `optional` grant wears a grey chip instead of
/// the amber one: nothing is wrong while it is off.
final class GrantRow: NSView {
    private let right = NSStackView()
    private let button: FlatButton
    private let optional: Bool
    private var chipText = "Allowed"
    private var missingText: String?
    private let detailField: NSTextField

    init(_ title: String, _ detail: String, icon: NSView? = nil, tip: String? = nil,
         optional: Bool = false, setUp: @escaping () -> Void) {
        button = FlatButton("Set Up", .plain, onClick: setUp)
        self.optional = optional
        detailField = RowText.help(detail)
        super.init(frame: .zero)
        let left = RowText.lead(RowText.title(title), detailField, icon: icon)
        right.orientation = .horizontal
        right.alignment = .centerY
        right.spacing = Theme.m(10)
        RowText.layout(left, right, into: self)
        toolTip = tip
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    var granted: Bool = false { didSet { if granted != oldValue { refresh() } } }

    /// The line under the name, for a grant whose story changes — which
    /// browser is open to be asked, say.
    var detail: String {
        get { detailField.stringValue }
        set { if detailField.stringValue != newValue { RowText.setHelp(detailField, newValue) } }
    }

    /// The chip's words, for a grant that is a setting rather than a
    /// permission ("Ready", and "Not set" while it isn't).
    func set(granted: Bool, chip: String, missing: String? = nil) {
        chipText = chip
        missingText = missing
        if self.granted == granted { refresh() } else { self.granted = granted }
    }

    private func refresh() {
        right.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if granted {
            right.addArrangedSubview(GrantChip(chipText, .ok))
        } else {
            right.addArrangedSubview(optional ? GrantChip(missingText ?? "Off", .neutral)
                                              : GrantChip(missingText ?? "Needs access", .warn))
            right.addArrangedSubview(button)
        }
    }
}

/// The refresh's state chip: a capsule of soft fill, the word in the
/// state's own colour and a dot of it in front, so the state reads from
/// shape as well as hue. Ember is kept for the one that means live.
final class GrantChip: NSView {
    /// `bad` is red: something is ending (a cancelled plan), not broken.
    enum Look { case ok, warn, neutral, live, bad }
    private let look: Look
    private let dot = NSView()

    init(_ text: String, _ look: Look = .ok) {
        self.look = look
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(11)
        // Medium: the dot and the fill already say "state"; semibold on
        // top made a column of chips the loudest thing on the page.
        let f = Theme.text(text, 11.5, .medium, color)
        f.font = .systemFont(ofSize: Theme.m(11.5), weight: .medium)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = Theme.m(3)
        dot.isHidden = look == .neutral
        let row = Theme.hstack([dot, f], spacing: Theme.m(6))
        // A chip is exactly as wide as its word: without this a form row
        // hands it the row's slack and it runs across to the label.
        row.setHuggingPriority(.required, for: .horizontal)
        f.setContentHuggingPriority(.required, for: .horizontal)
        f.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: Theme.m(6)),
            dot.heightAnchor.constraint(equalToConstant: Theme.m(6)),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(9)),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.m(9)),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Theme.m(22)),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var color: NSColor {
        switch look {
        case .ok:      return Theme.moss
        case .warn:    return Theme.amber
        case .neutral: return Theme.muted
        case .live:    return Theme.emberInk
        case .bad:     return Theme.danger
        }
    }
    private var fill: NSColor {
        switch look {
        case .ok:      return Theme.mossSoft
        case .warn:    return Theme.amberSoft
        case .neutral: return Theme.wellFill
        case .live:    return Theme.emberSoft
        case .bad:     return Theme.dangerSoft
        }
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = fill.cgColor
        dot.layer?.backgroundColor = (look == .live ? Theme.ember : color).cgColor
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// The refresh's toggle: a 32 × 19 capsule with a white knob. Ember when
/// on — on and live are the only two things that earn it — and a faint
/// wash of ink when off. NSSwitch wears the system accent, which is blue
/// on most Macs and never the ember.
final class ToggleSwitch: NSView {
    private let knob = CALayer()
    /// What a click does. A SwitchRow takes the click itself, so a toggle
    /// inside one leaves this unset and lets the press travel up to the row.
    var onClick: (() -> Void)?
    var isOn: Bool { didSet { if isOn != oldValue { restyle(animated: window != nil) } } }
    var isEnabled = true

    private static let offFill = Theme.dyn(Theme.hex(0x121214, 0.16), NSColor.white.withAlphaComponent(0.18))

    init(isOn: Bool) {
        self.isOn = isOn
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(knob)
        knob.backgroundColor = NSColor.white.cgColor
        knob.shadowColor = NSColor.black.cgColor
        knob.shadowOpacity = 0.25
        knob.shadowRadius = 1
        knob.shadowOffset = CGSize(width: 0, height: -1)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Theme.m(32)),
            heightAnchor.constraint(equalToConstant: Theme.m(19)),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        // The knob is a sublayer of our own, so it would animate in from the
        // corner on first layout without this.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        placeKnob()
        CATransaction.commit()
    }

    private func placeKnob() {
        let inset = Theme.m(2)
        let side = bounds.height - inset * 2
        knob.cornerRadius = side / 2
        knob.frame = CGRect(x: isOn ? bounds.width - inset - side : inset, y: inset, width: side, height: side)
    }

    private func restyle(animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.18)
        placeKnob()
        layer?.backgroundColor = (isOn ? Theme.ember : Self.offFill).cgColor
        CATransaction.commit()
        setAccessibilityValue(isOn)
    }

    override func mouseDown(with event: NSEvent) {
        guard let onClick = onClick else { return super.mouseDown(with: event) }
        if isEnabled { onClick() }
    }
    override var mouseDownCanMoveWindow: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = (isOn ? Theme.ember : Self.offFill).cgColor
        setAccessibilityValue(isOn)
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// Title + explanation, with a switch on the right. Clicking anywhere flips
/// it. `icon` and `tip` as on FormRow.
final class SwitchRow: NSView {
    private let sw: ToggleSwitch
    private let detailField: NSTextField
    private let onChange: (Bool) -> Void

    /// `example` stands where the line of help would: what the switch does,
    /// shown (an ExampleStrip) rather than told. The words go in `tip`.
    init(_ title: String, _ detail: String = "", isOn: Bool, icon: NSView? = nil, tip: String? = nil,
         example: NSView? = nil, onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        sw = ToggleSwitch(isOn: isOn)
        // Always built, even when empty: the reason a switch is unavailable can
        // arrive later, and a row that can't explain itself reads as broken.
        detailField = RowText.help(detail)
        super.init(frame: .zero)
        detailField.isHidden = detail.isEmpty
        sw.setAccessibilityLabel(title)

        let titleField = RowText.title(title)
        let left = RowText.lead(titleField, detailField, icon: icon)
        // The words column is the title's stack, beside the tile if there is one.
        if let example = example, let words = titleField.superview as? NSStackView {
            words.addArrangedSubview(example)
            words.setCustomSpacing(Theme.m(6), after: detail.isEmpty ? titleField : detailField)
        }
        RowText.layout(left, sw, into: self)
        toolTip = tip
    }
    required init?(coder: NSCoder) { fatalError() }

    var detail: String {
        get { detailField.stringValue }
        set {
            RowText.setHelp(detailField, newValue)
            detailField.isHidden = newValue.isEmpty
        }
    }

    var isOn: Bool {
        get { sw.isOn }
        set { sw.isOn = newValue }
    }
    var isEnabled: Bool {
        get { sw.isEnabled }
        set { sw.isEnabled = newValue; alphaValue = newValue ? 1 : 0.45 }
    }
    override func mouseDown(with event: NSEvent) {
        guard sw.isEnabled else { return }
        sw.isOn.toggle()
        onChange(sw.isOn)
    }
}

/// What a setting does, as a picture of it: the words it takes out struck
/// through on a red wash, what it puts in on a green one, plain words and an
/// arrow between. It stands where a row's line of help would, so a switch
/// reads at a glance instead of in a sentence.
final class ExampleStrip: NSStackView {
    enum Piece {
        /// Taken out.
        case cut(String)
        /// Put in.
        case add(String)
        /// Put in, and it is a command: monospaced.
        case code(String)
        /// Left alone.
        case text(String)
        case arrow
    }

    init(_ pieces: [Piece]) {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = Theme.m(5)
        for piece in pieces {
            switch piece {
            case .cut(let s):  addArrangedSubview(ExampleChip(s, .cut))
            case .add(let s):  addArrangedSubview(ExampleChip(s, .add))
            case .code(let s): addArrangedSubview(ExampleChip(s, .code))
            case .text(let s):
                let f = Theme.text(s, 11.5, .regular, Theme.muted)
                f.font = .systemFont(ofSize: Theme.m(11.5))
                addArrangedSubview(f)
            case .arrow:
                addArrangedSubview(GlyphView(symbol: "arrow.right", size: Theme.m(9), weight: .semibold,
                                             side: Theme.m(11)))
            }
        }
        setHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// One word of an ExampleStrip on its wash.
private final class ExampleChip: NSView {
    enum Kind { case cut, add, code }
    private let kind: Kind
    private let text: String
    private let field = NSTextField(labelWithString: "")

    private static let cutWash = Theme.dyn(Theme.hex(0xC6362B, 0.10), Theme.hex(0xFF6B5E, 0.16))

    init(_ text: String, _ kind: Kind) {
        self.kind = kind
        self.text = text
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(5)
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(6)),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.m(6)),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Theme.m(19)),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        apply()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Attributed colours are resolved when they are set, so a switch of
    /// appearance sets them again.
    private func apply() {
        let size = Theme.m(11.5)
        var attrs: [NSAttributedString.Key: Any] = [
            .font: kind == .code ? NSFont.monospacedSystemFont(ofSize: size, weight: .medium)
                                 : NSFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: kind == .cut ? Theme.danger : Theme.moss,
        ]
        if kind == .cut {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attrs[.strikethroughColor] = Theme.danger
        }
        field.attributedStringValue = NSAttributedString(string: text, attributes: attrs)
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = (kind == .cut ? Self.cutWash : Theme.mossSoft).cgColor
    }
    override func viewDidChangeEffectiveAppearance() {
        needsDisplay = true
        apply()
    }
}

// MARK: - The list panel (Dictionary and Phrases)

/// A group of rows, the refresh's `.grp`: one surface with a hairline round
/// it, radius 12, no shadow, and soft rules between the rows inside.
final class ListPanel: NSView {
    let rows = NSStackView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(12)
        layer?.borderWidth = 1
        // Clipped, so a lit first or last row keeps the group's corners.
        layer?.masksToBounds = true

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: topAnchor),
            rows.leadingAnchor.constraint(equalTo: leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ views: [NSView]) {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for v in views {
            rows.addArrangedSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Theme.surface.cgColor
        layer?.borderColor = Theme.hairline.cgColor
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// "heard this → type that", with a use count and, on hover, edit and delete.
///
/// A grouped row off the refresh mockup: 44 px, a wash under the cursor, a
/// soft rule under it. Both sides are the interface face: the side you say
/// in the plain weight of words you said, the side SayControl types a step
/// heavier, because it is the one the rule exists for. An address or a link
/// truncates in the middle, so both of its ends stay readable.
final class ListRow: NSView, Hoverable {
    private let fromField: NSTextField
    private let toField: NSTextField
    private let acts = NSStackView()
    private var actsBox: FadeBox!
    private var hovering = false { didSet { actsBox.shown = hovering; needsDisplay = true } }
    private let rule = ColorView(color: Theme.hairsoft)

    /// An address or a link: text that means nothing unless every character
    /// lands exactly as written.
    static func isLiteral(_ s: String) -> Bool {
        s.contains("://") || (s.contains("@") && !s.contains(" "))
    }

    /// `fromWidth` is in mockup pixels, the width of the column you say.
    init(from: String, to: String, hits: Int, learned: Bool, fromWidth: CGFloat = 176,
         onEdit: @escaping () -> Void, onDelete: @escaping () -> Void) {
        fromField = Theme.text(from, 13.5 * 1.2, .regular, Theme.ink)
        fromField.font = Theme.saidFont(13.5)
        let typed = to.replacingOccurrences(of: "\n", with: " ⏎ ")
        toField = Theme.text(typed, 13.5 * 1.2, .medium, Theme.ink)
        toField.font = .systemFont(ofSize: Theme.m(13.5), weight: .medium)
        if ListRow.isLiteral(to) { toField.lineBreakMode = .byTruncatingMiddle }
        super.init(frame: .zero)
        wantsLayer = true
        toolTip = to

        fromField.translatesAutoresizingMaskIntoConstraints = false
        fromField.widthAnchor.constraint(equalToConstant: Theme.m(fromWidth)).isActive = true

        let arrow = GlyphView(symbol: "arrow.right", size: Theme.m(11), weight: .medium, side: Theme.m(14))
        arrow.tint = Theme.faint
        toField.setContentHuggingPriority(.init(1), for: .horizontal)
        var parts: [NSView] = [fromField, arrow, toField]
        if learned {
            let chip = Chip(tag: "Learned", .ok, compact: true)
            chip.toolTip = "Learned from a fix you made"
            parts.append(chip)
        }
        // A fixed column, so the counts line up down the list instead of
        // drifting with the number of digits: tabular digits, like every
        // count and time on a row.
        let count = Theme.meta("\(hits)×", 11.5, Theme.faint)
        count.toolTip = hits == 1 ? "Used once" : "Used \(hits) times"
        count.alignment = .right
        count.translatesAutoresizingMaskIntoConstraints = false
        count.widthAnchor.constraint(equalToConstant: Theme.m(34)).isActive = true
        parts.append(count)

        acts.orientation = .horizontal
        acts.spacing = Theme.m(2)
        acts.setViews([IconButton("pencil", size: 26 * 1.2, icon: 13 * 1.2, tip: "Edit", onClick: onEdit),
                       IconButton("trash", size: 26 * 1.2, icon: 13 * 1.2, tip: "Delete", onClick: onDelete)],
                      in: .leading)
        // The actions keep their space whether or not they are showing: a row
        // that grows and shifts under the cursor on hover reads as clumsy, and
        // the reshuffle is what used to leave several rows lit at once.
        actsBox = FadeBox(acts)
        parts.append(actsBox)

        let row = Theme.hstack(parts, spacing: Theme.m(12))
        row.setCustomSpacing(Theme.m(4), after: count)
        row.translatesAutoresizingMaskIntoConstraints = false
        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        addSubview(rule)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Theme.m(44)),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(16)),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.m(8)),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func hideRule() { rule.isHidden = true }

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

/// The inline "Add new" strip: a sunk well over the list, two fields and an
/// ink Save. It does not exist until you ask for it.
final class AddRow: NSView {

    /// A text field that says when it has focus, so the box round it can
    /// light the focus ring.
    final class Input: NSTextField {
        var onFocus: (Bool) -> Void = { _ in }
        override func becomeFirstResponder() -> Bool {
            let took = super.becomeFirstResponder()
            if took { onFocus(true) }
            return took
        }
        override func textDidEndEditing(_ notification: Notification) {
            super.textDidEndEditing(notification)
            onFocus(false)
        }
    }

    /// The mockup's `.field`: surface, a hairline round it, radius 8, 30 px
    /// tall. With focus it takes the one focus look the refresh has
    /// everywhere, a one-point ember line with a soft ember halo outside it.
    /// The system bezel can't draw either, so the field inside is bare.
    final class Box: NSView {
        let input = Input()
        private let halo = CALayer()
        private var focused = false { didSet { needsDisplay = true } }

        init(placeholder: String) {
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = Theme.m(8)
            layer?.borderWidth = 1
            layer?.masksToBounds = false
            halo.cornerRadius = Theme.m(8) + Theme.m(3)
            halo.borderWidth = Theme.m(3)
            layer?.addSublayer(halo)

            let font = NSFont.systemFont(ofSize: Theme.m(13))
            input.isBordered = false
            input.isBezeled = false
            input.drawsBackground = false
            input.focusRingType = .none
            input.font = font
            input.textColor = Theme.ink
            input.lineBreakMode = .byTruncatingTail
            input.cell?.isScrollable = true
            input.cell?.wraps = false
            input.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
                .font: font, .foregroundColor: Theme.faint,
            ])
            input.onFocus = { [weak self] on in self?.focused = on }
            input.setContentHuggingPriority(.init(1), for: .horizontal)
            input.translatesAutoresizingMaskIntoConstraints = false
            addSubview(input)
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: Theme.m(30)),
                input.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(10) - 2),
                input.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.m(10) + 2),
                input.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        required init?(coder: NSCoder) { fatalError() }

        /// A click on the padding still lands in the text.
        override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(input) }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }

        override func layout() {
            super.layout()
            halo.frame = bounds.insetBy(dx: -Theme.m(3), dy: -Theme.m(3))
        }

        override var wantsUpdateLayer: Bool { true }
        override func updateLayer() {
            layer?.backgroundColor = Theme.surface.cgColor
            layer?.borderColor = (focused ? Theme.ember : Theme.hairline).cgColor
            halo.borderColor = (focused ? Theme.emberSoft : NSColor.clear).cgColor
        }
        override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    }

    private let leftBox: Box
    private let rightBox: Box
    private let column: NSStackView
    var left: NSTextField { leftBox.input }
    var right: NSTextField { rightBox.input }

    init(leftPlaceholder: String, rightPlaceholder: String, rightFlex: CGFloat = 1,
         onSave: @escaping (String, String) -> Void, onCancel: @escaping () -> Void) {
        leftBox = Box(placeholder: leftPlaceholder)
        rightBox = Box(placeholder: rightPlaceholder)
        column = NSStackView()
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(12)
        layer?.borderWidth = 1

        let save = FlatButton("Save", .primary) { [weak self] in
            guard let self = self else { return }
            onSave(self.left.stringValue, self.right.stringValue)
        }
        let cancel = FlatButton("Cancel", .quiet, onClick: onCancel)
        let arrow = GlyphView(symbol: "arrow.right", size: Theme.m(11), weight: .medium, side: Theme.m(14))
        arrow.tint = Theme.faint
        let row = Theme.hstack([leftBox, arrow, rightBox, save, cancel], spacing: Theme.m(10))
        row.setCustomSpacing(Theme.m(4), after: save)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Theme.m(8)
        column.addArrangedSubview(row)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(12)),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.m(10)),
            column.topAnchor.constraint(equalTo: topAnchor, constant: Theme.m(10)),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.m(10)),
            row.widthAnchor.constraint(equalTo: column.widthAnchor),
            // Both fields are in the row by now — an anchor pair needs a
            // common ancestor before it can be activated.
            rightBox.widthAnchor.constraint(equalTo: leftBox.widthAnchor, multiplier: rightFlex),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Hangs an extra line inside the well, under the fields — the
    /// Dictionary's "Match capitalisation exactly".
    func addFooter(_ view: NSView) { column.addArrangedSubview(view) }

    func clear() { left.stringValue = ""; right.stringValue = "" }
    func focus() { window?.makeFirstResponder(left) }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Theme.wellFill.cgColor
        layer?.borderColor = Theme.hairsoft.cgColor
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// A magnifier that grows into a filter field when you click it. The field is
/// the same box as the add row's, focus ring and all.
final class SearchToggle: NSView {
    private let box = AddRow.Box(placeholder: "Filter")
    var field: NSTextField { box.input }
    private var open = false
    private var widthC: NSLayoutConstraint!
    private let onChange: (String) -> Void

    init(onChange: @escaping (String) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        box.translatesAutoresizingMaskIntoConstraints = false
        box.isHidden = true
        let button = IconButton("magnifyingglass", tip: "Filter")
        button.onClick = { [weak self] in self?.toggle() }

        let row = Theme.hstack([button, box], spacing: Theme.m(6))
        row.setHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        widthC = box.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthC,
        ])
        field.target = self
        field.action = #selector(changed)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() { onChange(field.stringValue) }

    private func toggle() {
        open.toggle()
        box.isHidden = !open
        widthC.constant = open ? Theme.m(180) : 0
        if open { window?.makeFirstResponder(field) }
        else if !field.stringValue.isEmpty { field.stringValue = ""; onChange("") }
    }
}

// MARK: - Waveform

/// The little amplitude sketch on a Recent row. Deterministic from the text,
/// so a row always draws the same shape — until the clip itself arrives, at
/// which point `setBars` replaces the sketch with the real envelope.
final class MiniWave: NSView {
    private var bars: [CGFloat] = []
    var active = false { didSet { needsDisplay = true } }
    /// 0…1 while the clip is playing: everything behind the playhead burns
    /// ember. nil when nothing is on air.
    var progress: CGFloat? { didSet { needsDisplay = true } }

    /// The real shape of the audio, once it has been read off the disk.
    func setBars(_ heights: [CGFloat]) {
        guard !heights.isEmpty else { return }
        bars = heights
        needsDisplay = true
    }

    init(seed: Int, count: Int = 24) {
        super.init(frame: .zero)
        var s = UInt32(truncatingIfNeeded: seed == 0 ? 1 : seed)
        func rnd() -> CGFloat {
            s = s &* 1664525 &+ 1013904223
            return CGFloat((s >> 8) & 0xFFFF) / CGFloat(0xFFFF)
        }
        bars = (0..<count).map { i in
            let envelope = pow(sin(CGFloat(i) / CGFloat(count - 1) * CGFloat.pi), 0.6)
            return max(0.12, envelope * (0.34 + rnd() * 0.66))
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Theme.px(76), height: Theme.px(20))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !bars.isEmpty else { return }
        let gap: CGFloat = 1.5
        let w: CGFloat = 2
        let total = CGFloat(bars.count) * w + CGFloat(bars.count - 1) * gap
        let scale = min(1, bounds.width / max(1, total))
        let played = progress.map { $0 * CGFloat(bars.count) }
        for (i, h) in bars.enumerated() {
            if let played = played {
                (CGFloat(i) < played ? Theme.ember : Theme.barFill).setFill()
            } else {
                (active ? Theme.ember : Theme.barFill).setFill()
            }
            let x = CGFloat(i) * (w + gap) * scale
            let bh = max(2, bounds.height * h)
            let r = NSRect(x: x, y: (bounds.height - bh) / 2, width: w * scale, height: bh)
            NSBezierPath(roundedRect: r, xRadius: 1, yRadius: 1).fill()
        }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: - Model row

/// A row of chips that wraps onto the next line when it runs out of width —
/// what flex-wrap does in the prototype, which no NSStackView will do.
final class FlowRow: NSView {
    private let hgap: CGFloat
    private let vgap: CGFloat
    private let centered: Bool

    /// What each view reserves. `fittingSize` is right for a chip, whose width
    /// never moves; a view that grows with its own state hands its steady
    /// width instead, so the packing doesn't shuffle underfoot.
    var measure: (NSView) -> NSSize = { $0.fittingSize }

    init(hgap: CGFloat = 7, vgap: CGFloat = 7, centered: Bool = false) {
        self.hgap = Theme.px(hgap)
        self.vgap = Theme.px(vgap)
        self.centered = centered
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ views: [NSView]) {
        subviews.forEach { $0.removeFromSuperview() }
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = true
            addSubview(v)
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func arrange(width: CGFloat, place: Bool) -> CGFloat {
        // Each line is packed whole before any of it is placed: centring one
        // needs its full width, which isn't known until the line has closed.
        var lines: [[(NSView, NSSize)]] = [[]]
        var used: CGFloat = 0
        for v in subviews {
            let size = measure(v)
            if used > 0, used + hgap + size.width > width {
                lines.append([(v, size)])
                used = size.width
            } else {
                used += used > 0 ? hgap + size.width : size.width
                lines[lines.count - 1].append((v, size))
            }
        }
        var y: CGFloat = 0
        for line in lines {
            if place {
                let total = line.reduce(CGFloat(0)) { $0 + $1.1.width }
                    + hgap * CGFloat(max(0, line.count - 1))
                var x = centered ? max(0, (width - total) / 2) : 0
                for (v, size) in line {
                    v.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
                    x += size.width + hgap
                }
            }
            y += (line.map(\.1.height).max() ?? 0) + vgap
        }
        return max(0, y - vgap)
    }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric,
               height: subviews.isEmpty ? 0 : arrange(width: max(1, bounds.width), place: false))
    }
    override func layout() {
        super.layout()
        _ = arrange(width: bounds.width, place: true)
        invalidateIntrinsicContentSize()
    }
}
