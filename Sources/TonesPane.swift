// The Tones pane: one list, the way Settings reads.
//
// Under a banner that pictures each place and its tone, the four kinds of
// place you write — Personal, Work, Email, Agents — a row each: what it
// is, its apps, and the tone it writes in as a switch. Click a row and it
// opens to what you said over what its tone types, the changes washed in
// colour (ToneDiff.swift). In an open row, pointing at another
// tone turns the preview to that tone, and moving off goes back to the one
// in use. One row is open at a time. Under the list, one box holds the
// cleanup every app gets first, and your own rules.
//
// It replaced four tabs and three cards side by side (2026-10-04,
// design/tones-redesign.html): too much to read before the point landed.
// The banner went with them and came back the same day, so the page opens
// like the others. The first list opened a row when you pointed at a tone,
// which pushed the rows under it down: a row above the pointer could never close
// without sliding the one you were on away, so rows stayed open until you
// left the list, and the list jumped when they folded. Rows now open on a
// click (design/tones-preview-options.html, option B, picked the same day).
// See Tones.swift for the model and AppStyle.swift for which app lands in
// which row.
import Cocoa

// MARK: - What you said, what it types

/// What you said over what it types: the preview a row opens to, and the
/// cleanup's example. Words that went are struck through where they were
/// said, words written differently are underlined there, and what changed
/// is washed in the typed line. No key under it — the strikes and washes say
/// it, with less to read.
final class ToneBeforeAfter: NSView {
    init(said: String, written: String, typedLabel: String = "It types") {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(10)
        layer?.borderWidth = 1

        let typed = ToneSampleView(written, said: said, size: 14, color: Theme.ink)
        typed.showsChanges = true

        let saidFont = Theme.saidFont(13)
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.35
        let line = NSMutableAttributedString(string: said, attributes: [
            .font: saidFont, .foregroundColor: Theme.muted, .paragraphStyle: style,
        ])
        let gone = ToneChangeKind.removed.hue.ink
        for r in typed.diff.cutRanges where NSMaxRange(r) <= line.length {
            line.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                .strikethroughColor: gone, .foregroundColor: gone], range: r)
        }
        let reworded = ToneChangeKind.words.hue.ink
        for r in typed.diff.rewrittenRanges where NSMaxRange(r) <= line.length {
            line.addAttributes([.underlineStyle: NSUnderlineStyle([.single, .patternDot]).rawValue,
                                .underlineColor: reworded, .foregroundColor: reworded], range: r)
        }
        let saidField = Hub.para("", 13)
        saidField.attributedStringValue = line

        func label(_ s: String) -> NSTextField {
            let f = Theme.meta(s, 10, Theme.faint)
            f.attributedStringValue = Self.label(s)
            f.lineBreakMode = .byClipping
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: Self.labelWidth).isActive = true
            return f
        }
        let saidLabel = label("You say"), typedLabel = label(typedLabel)
        for v in [saidLabel, saidField, typedLabel, typed] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let padX = Theme.m(14), gap = Theme.m(12)
        NSLayoutConstraint.activate([
            saidLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padX),
            saidLabel.firstBaselineAnchor.constraint(equalTo: saidField.firstBaselineAnchor),
            saidField.topAnchor.constraint(equalTo: topAnchor, constant: Theme.m(11)),
            saidField.leadingAnchor.constraint(equalTo: saidLabel.trailingAnchor, constant: gap),
            saidField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padX),

            typedLabel.leadingAnchor.constraint(equalTo: saidLabel.leadingAnchor),
            typedLabel.topAnchor.constraint(equalTo: typed.topAnchor, constant: Theme.m(4)),
            typed.topAnchor.constraint(equalTo: saidField.bottomAnchor, constant: Theme.m(7)),
            typed.leadingAnchor.constraint(equalTo: saidField.leadingAnchor),
            typed.trailingAnchor.constraint(equalTo: saidField.trailingAnchor),
            // Never shorter than its words; as short as them unless a
            // neighbour asks for more (the cleanup's three, kept one height).
            typed.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Theme.m(11)),
        ])
        let hug = typed.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.m(11))
        hug.priority = .defaultLow
        hug.isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Self.fill.cgColor
        layer?.borderColor = Theme.hairsoft.cgColor
    }
    /// A shade under the card it sits in, so the sample reads as a quote.
    private static let fill = Theme.dyn(Theme.hex(0xF4F2EE), NSColor.black.withAlphaComponent(0.24))
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    private static func label(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: Theme.m(10), weight: .semibold),
            .foregroundColor: Theme.faint, .kern: Theme.m(10) * 0.08,
        ])
    }
    /// As wide as the longest label, "Would type", so every well's two lines
    /// start in one place whichever label it wears.
    private static var labelWidth: CGFloat {
        ceil(max(Theme.m(58), label("Would type").size().width)) + 1
    }
}

// MARK: - One tone's preview

/// One tone, as an open row shows it: its name and what it does, whether
/// it's the one in use, and what you said over what it types. When tones
/// aren't being applied (cleanup None, no plan or key, tones off) it still
/// shows what the tone does — the colours are the point — but the second
/// line says "Would type" and a note under it says why it's paused. Showing
/// the words unchanged instead read as "this tone does nothing".
private final class TonePreview: NSView {
    private let status = NSTextField(labelWithString: "")

    init(_ context: ToneContext, _ option: ToneOption, short: String, paused: String?) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        // The tone's name, then its first clause; the whole description
        // waits in the tooltip.
        let size = Theme.m(12.5)
        let named = NSMutableAttributedString(string: option.title, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: Theme.ink,
            .kern: 0])
        named.addAttribute(.kern, value: Theme.m(6), range: NSRange(location: named.length - 1, length: 1))
        named.append(NSAttributedString(string: short, attributes: [
            .font: NSFont.systemFont(ofSize: size), .foregroundColor: Theme.muted]))
        let detail = NSTextField(labelWithString: "")
        detail.attributedStringValue = named
        detail.lineBreakMode = .byTruncatingTail
        detail.maximumNumberOfLines = 1
        detail.toolTip = option.detail
        detail.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        detail.setContentHuggingPriority(.init(1), for: .horizontal)
        status.setContentCompressionResistancePriority(.required, for: .horizontal)
        status.setContentHuggingPriority(.required, for: .horizontal)

        let well = ToneBeforeAfter(said: context.sample, written: option.sample,
                                   typedLabel: paused == nil ? "It types" : "Would type")
        var views: [NSView] = [detail, status, well]
        var note: (icon: NSView, text: NSView)?
        if let why = paused {
            let icon = NSImageView()
            icon.image = Theme.symbol("pause.circle", Theme.m(12), .medium)
            icon.contentTintColor = Theme.amber
            let text = Hub.para(why, 12, .regular, Theme.amber, lineHeight: 1.3)
            note = (icon, text)
            views += [icon, text]
        }
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let last = note?.text ?? well
        NSLayoutConstraint.activate([
            detail.topAnchor.constraint(equalTo: topAnchor),
            detail.leadingAnchor.constraint(equalTo: leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: status.leadingAnchor, constant: -Theme.m(12)),
            status.trailingAnchor.constraint(equalTo: trailingAnchor),
            status.firstBaselineAnchor.constraint(equalTo: detail.firstBaselineAnchor),

            well.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: Theme.m(8)),
            well.leadingAnchor.constraint(equalTo: leadingAnchor),
            well.trailingAnchor.constraint(equalTo: trailingAnchor),
            last.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
        if let (icon, text) = note {
            // The words take the whole width, so the note wraps only when it
            // must.
            NSLayoutConstraint.activate([
                text.topAnchor.constraint(equalTo: well.bottomAnchor, constant: Theme.m(9)),
                text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Theme.m(7)),
                text.trailingAnchor.constraint(equalTo: trailingAnchor),
                icon.leadingAnchor.constraint(equalTo: leadingAnchor),
                icon.centerYAnchor.constraint(equalTo: text.firstBaselineAnchor, constant: -Theme.m(4)),
            ])
        }
        // As short as its words, unless a taller tone of the same place sets
        // the height: then the space goes under the well, not into it.
        let hug = bottomAnchor.constraint(equalTo: last.bottomAnchor)
        hug.priority = .init(200)
        hug.isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    func setStatus(inUse: Bool, paused: Bool) {
        let font = NSFont.systemFont(ofSize: Theme.m(11.5), weight: .medium)
        let (text, color): (String, NSColor) = paused ? ("Paused", Theme.amber)
            : inUse ? ("✓ In use", Theme.moss) : ("Click to use", Theme.faint)
        status.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color])
    }
}

// MARK: - Motion

/// cubic-bezier(.2, .8, .2, 1) — Motion.ease, solved for the tweens Core
/// Animation can't run itself.
private func easeOut(_ x: Double) -> CGFloat {
    if x <= 0 { return 0 }
    if x >= 1 { return 1 }
    let (x1, y1, x2, y2) = (0.2, 0.8, 0.2, 1.0)
    let cx = 3 * x1, bx = 3 * (x2 - x1) - cx, ax = 1 - cx - bx
    let cy = 3 * y1, by = 3 * (y2 - y1) - cy, ay = 1 - cy - by
    func curveX(_ u: Double) -> Double { ((ax * u + bx) * u + cx) * u }
    // Bisection: x(u) only ever rises, and twenty halvings is a millionth.
    var lo = 0.0, hi = 1.0, u = x
    for _ in 0..<20 {
        if curveX(u) < x { lo = u } else { hi = u }
        u = (lo + hi) / 2
    }
    return CGFloat(((ay * u + by) * u + cy) * u)
}

/// Heights that change on the display's own clock, laid out every frame.
/// A row opening moves the rows under it, grows the box around them and
/// lengthens the page, and laying the whole pane out each frame moves all
/// of that together, with nothing drawn at a size it isn't. (Core Animation
/// would glide each layer on its own, and the scroll view's length can't
/// ride along.) Each tween is keyed, so a click mid-way starts the next one
/// from where the last one got to.
private final class FrameTweens: NSObject {
    private struct Run {
        let from: CGFloat, to: CGFloat
        let start: CFTimeInterval, duration: CFTimeInterval
        let apply: (CGFloat) -> Void
        let done: (() -> Void)?
    }
    private var runs: [String: Run] = [:]
    private weak var host: NSView?
    private var link: AnyObject?
    private var timer: Timer?
    /// After every frame's values are in: lay the pane out once.
    var afterFrame: () -> Void = {}

    init(host: NSView) { self.host = host }

    func run(_ key: String, from: CGFloat, to: CGFloat, duration: CFTimeInterval, animated: Bool,
             apply: @escaping (CGFloat) -> Void, done: (() -> Void)? = nil) {
        guard animated, host?.window != nil, !Motion.reduced, abs(to - from) > 0.01 else {
            runs[key] = nil
            apply(to)
            afterFrame()
            done?()
            return
        }
        runs[key] = Run(from: from, to: to, start: CACurrentMediaTime(), duration: duration, apply: apply, done: done)
        start()
    }

    private func start() {
        guard link == nil, timer == nil, let host = host else { return }
        if #available(macOS 14.0, *) {
            let l = host.displayLink(target: self, selector: #selector(frame(_:)))
            // A ProMotion screen runs a link at 60 unless it asks for more,
            // and the heights then step at half the rate of the fades
            // Core Animation runs beside them.
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            l.add(to: .main, forMode: .common)
            link = l
        } else {
            let t = Timer(timeInterval: 1 / 60.0, repeats: true) { [weak self] _ in self?.step(CACurrentMediaTime()) }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
    }

    private func stop() {
        if #available(macOS 14.0, *) { (link as? CADisplayLink)?.invalidate() }
        link = nil
        timer?.invalidate()
        timer = nil
    }

    @available(macOS 14.0, *)
    @objc private func frame(_ link: CADisplayLink) { step(link.targetTimestamp) }

    /// Values for the moment this frame reaches the screen.
    private func step(_ now: CFTimeInterval) {
        var finished: [() -> Void] = []
        for (key, r) in runs {
            let k = min(1, max(0, (now - r.start) / r.duration))
            r.apply(r.from + (r.to - r.from) * easeOut(k))
            if k >= 1 {
                runs[key] = nil
                if let d = r.done { finished.append(d) }
            }
        }
        afterFrame()
        finished.forEach { $0() }
        if runs.isEmpty { stop() }
    }
}

/// Fades a view to `alpha` from wherever it is now, mid-fade included.
private func fade(_ view: NSView, to alpha: CGFloat, duration: CFTimeInterval,
                  delay: CFTimeInterval = 0, timing: CAMediaTimingFunction = Motion.ease) {
    view.wantsLayer = true
    guard let layer = view.layer else { view.alphaValue = alpha; return }
    let from = layer.presentation()?.opacity ?? layer.opacity
    layer.removeAnimation(forKey: "tones.fade")
    view.alphaValue = alpha
    guard view.window != nil, !Motion.reduced, abs(CGFloat(from) - alpha) > 0.001 else { return }
    let a = CABasicAnimation(keyPath: "opacity")
    a.fromValue = from
    a.toValue = Float(alpha)
    a.duration = duration
    a.beginTime = CACurrentMediaTime() + delay
    a.fillMode = .backwards
    a.timingFunction = timing
    layer.add(a, forKey: "tones.fade")
}

// MARK: - A row's head

/// The turn that says a row opens: pointing right when shut, down when
/// open, drawn so it can stop anywhere between while it turns.
private final class Chevron: NSView {
    /// 0 points right, 1 points down.
    var turn: CGFloat = 0 { didSet { if turn != oldValue { needsDisplay = true } } }
    var open = false { didSet { needsDisplay = true } }
    /// The head is pointed at.
    var lit = false { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Theme.m(24)),
            heightAnchor.constraint(equalToConstant: Theme.m(24)),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        // The 24-unit chevron, m9 6 l6 6 l-6 6, drawn 14 points tall and
        // turned about the middle of the box.
        let unit = Theme.m(14) / 24
        var t = AffineTransform(translationByX: bounds.midX, byY: bounds.midY)
        t.rotate(byDegrees: 90 * turn)
        t.scale(unit)
        t.translate(x: -12, y: -12)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 9, y: 6))
        path.line(to: NSPoint(x: 15, y: 12))
        path.line(to: NSPoint(x: 9, y: 18))
        path.transform(using: t)
        path.lineWidth = 2 * unit
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        (lit ? Theme.ink : open ? Theme.ink2 : Theme.faint).setStroke()
        path.stroke()
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// A row's head: the part you click to open or shut it. A faint wash while
/// pointed at says it's a button; the tone switch inside it keeps its own
/// clicks.
private final class RowHead: NSView {
    var onPress: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }
    /// The tone switch inside: a click on it, or between its pills, picks
    /// rather than opens.
    weak var keepsClicks: NSView?
    /// Set by a press that began on the head itself. A click on a pill
    /// arrives here too, its mouse-up passed along the responder chain,
    /// and must not open or shut the row as well as picking.
    private var pressed = false
    private var fadeNext = false
    private var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            fadeNext = true
            needsDisplay = true
            onHover(hovering)
        }
    }
    private static let wash = Theme.dyn(Theme.hex(0xFBFAF8), NSColor.white.withAlphaComponent(0.025))

    init(title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        pressed = !(keepsClicks.map { convert($0.bounds, from: $0).contains(p) } ?? false)
    }
    override func mouseUp(with event: NSEvent) {
        defer { pressed = false }
        if pressed, bounds.contains(convert(event.locationInWindow, from: nil)) { onPress() }
    }
    /// The whole head is the button, name and logos included, so a click
    /// lands here even in a window that isn't frontmost. Only the switch
    /// keeps its own.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if let keep = keepsClicks, hit === keep || hit.isDescendant(of: keep) { return hit }
        return self
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { onPress(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override var mouseDownCanMoveWindow: Bool { false }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        guard let layer = layer else { return }
        let fill = (hovering ? Self.wash : .clear).cgColor
        if fadeNext, !Motion.reduced {
            let a = CABasicAnimation(keyPath: "backgroundColor")
            a.fromValue = layer.presentation()?.backgroundColor ?? layer.backgroundColor ?? NSColor.clear.cgColor
            a.toValue = fill
            a.duration = 0.15
            layer.add(a, forKey: "hover")
        }
        fadeNext = false
        layer.backgroundColor = fill
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: - One place

/// One kind of place: its picture, its name and a line, the apps it covers,
/// the tone switch and a chevron. Shut, that is all. Open, it shows what
/// you said over what its tone types; pointing at another tone turns that
/// to the other tone, and clicking one picks it. The pane opens and shuts
/// rows (TonesPane.toggle), one at a time.
private final class TonePlaceRow: NSView {
    let context: ToneContext
    let switcher: PillSwitcher
    let chevron = Chevron()
    private let head: RowHead
    private let clip = FlippedView()
    private let content = NSView()
    private let stage = NSView()
    /// The preview's reveal: 0 shut, the preview's height open. The pane
    /// moves it (TonesPane.setOpen).
    private(set) var clipHeight: NSLayoutConstraint!
    var isOpen = false {
        didSet { chevron.open = isOpen; head.setAccessibilityExpanded(isOpen) }
    }
    /// While the pane is moving `clipHeight`, layout leaves it alone.
    var settling = false
    /// One preview per tone, stacked in one place, the shown one opaque:
    /// the row is as tall as its longest tone, so moving along the switch
    /// changes the words and never the height.
    private var previews: [TonePreview] = []
    private var shown = 0
    private var paused: String?
    private var back: DispatchWorkItem?
    /// Asks the pane to open or shut this row.
    var onToggle: (TonePlaceRow) -> Void = { _ in }
    /// Told after a tone is picked, so the banner's picture shows it.
    var onPicked: () -> Void = {}

    /// Short enough for one line beside the switch. Tones.swift's blurbs
    /// are the long version, kept for the polish prompt's reader.
    private static func line(for context: ToneContext) -> String {
        switch context {
        case .personal: return "Friends, family and your own notes"
        case .work:     return "Team chat, tickets and documents"
        case .email:    return "Mail clients and webmail"
        case .agents:   return "AI chats, AI editors and the terminal"
        }
    }
    /// Each tone in its first clause, for the line over its sample; the
    /// whole description waits in the line's tooltip.
    private static func short(_ option: ToneOption, in context: ToneContext) -> String {
        switch (context, option.id) {
        case (.personal, "casual"):       return "Talks the way you text."
        case (.personal, "balanced"):     return "Ordinary written sentences, still relaxed."
        case (.personal, "polished"):     return "Careful punctuation and sentence breaks."
        case (.work, "casual"):           return "Standup voice. Short and plain."
        case (.work, "balanced"):         return "Complete sentences, straight to the point."
        case (.work, "formal"):           return "For the message that gets forwarded."
        case (.email, "friendly"):        return "Warm and direct, for someone you already know."
        case (.email, "professional"):    return "The everyday work email."
        case (.email, "formal"):          return "Nothing contracted, nothing casual."
        case (.agents, "verbatim"):       return "Every word you said, cleaned up."
        case (.agents, "terse"):          return "The same words, minus the polite opening."
        default:                          return option.detail
        }
    }

    private static func symbol(for context: ToneContext) -> String {
        switch context {
        case .personal: return "bubble.left.and.bubble.right"
        case .work:     return "briefcase"
        case .email:    return "envelope"
        case .agents:   return "sparkles"
        }
    }

    /// The tone in use, as an index into the switch.
    var picked: Int {
        context.options.firstIndex { $0.id == Tones.selectedID(for: context) } ?? 0
    }

    init(_ context: ToneContext) {
        self.context = context
        let options = context.options
        let picked = options.firstIndex { $0.id == Tones.selectedID(for: context) } ?? 0
        switcher = PillSwitcher(options.map { $0.title }, selected: picked, size: .medium, previews: true)
        head = RowHead(title: "\(context.title): \(Self.line(for: context))")
        super.init(frame: .zero)

        let tile = IconTile(Self.symbol(for: context), .slate, side: 32, icon: 15)
        let name = Theme.display(context.title, 15, .medium, tracking: -0.015)
        let line = Hub.text(Self.line(for: context), 12.5, .regular, Theme.muted)
        line.lineBreakMode = .byTruncatingTail
        line.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        let words = Theme.vstack([name, line], spacing: Theme.m(2))
        words.setHuggingPriority(.init(1), for: .horizontal)
        let logos = AppLogoStack()
        logos.set(AppMarks.marks(for: context))
        let bar = Theme.hstack([tile, words, logos, switcher, chevron], spacing: Theme.m(13))
        bar.alignment = .centerY
        bar.setCustomSpacing(Theme.m(16), after: words)
        bar.setCustomSpacing(Theme.m(16), after: logos)
        bar.setCustomSpacing(Theme.m(11), after: switcher)
        bar.translatesAutoresizingMaskIntoConstraints = false
        head.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: head.leadingAnchor, constant: Theme.m(18)),
            // The chevron sits 6 points into the right gutter, as the
            // mockup's -6 margin puts it.
            bar.trailingAnchor.constraint(equalTo: head.trailingAnchor, constant: -Theme.m(10)),
            bar.centerYAnchor.constraint(equalTo: head.centerYAnchor),
            bar.topAnchor.constraint(greaterThanOrEqualTo: head.topAnchor, constant: Theme.m(14)),
            head.heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.m(68)),
        ])

        clip.wantsLayer = true
        clip.layer?.masksToBounds = true
        content.wantsLayer = true
        content.alphaValue = 0
        for (v, parent) in [(content, clip), (stage, content)] as [(NSView, NSView)] {
            v.translatesAutoresizingMaskIntoConstraints = false
            parent.addSubview(v)
        }
        for v in [head, clip] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        clipHeight = clip.heightAnchor.constraint(equalToConstant: 0)
        // The preview lines up with the name: 18 in, the 32-point tile, 13.
        let indent = Theme.m(18) + Theme.m(32) + Theme.m(13)
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: topAnchor),
            head.leadingAnchor.constraint(equalTo: leadingAnchor),
            head.trailingAnchor.constraint(equalTo: trailingAnchor),

            clip.topAnchor.constraint(equalTo: head.bottomAnchor),
            clip.leadingAnchor.constraint(equalTo: leadingAnchor),
            clip.trailingAnchor.constraint(equalTo: trailingAnchor),
            clip.bottomAnchor.constraint(equalTo: bottomAnchor),
            clipHeight,

            content.topAnchor.constraint(equalTo: clip.topAnchor),
            content.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: clip.trailingAnchor),

            stage.topAnchor.constraint(equalTo: content.topAnchor),
            stage.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: indent),
            stage.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Theme.m(16)),
            stage.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Theme.m(16)),
        ])

        head.keepsClicks = switcher
        head.onPress = { [weak self] in
            guard let self = self else { return }
            self.onToggle(self)
        }
        head.onHover = { [weak self] on in self?.chevron.lit = on }
        switcher.onPick = { [weak self] i in
            guard let self = self else { return }
            Tones.select(options[i].id, for: context)
            self.onPicked()
            self.refreshStatus()
            self.show(i, animated: true)
            // A pick on a shut row opens it, to show what it now types.
            if !self.isOpen { self.onToggle(self) }
        }
        switcher.onHover = { [weak self] i in self?.pointed(at: i) }
        refreshPaused(force: true)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: The previews

    /// Why tones aren't being applied right now, or nil when they are.
    static var pausedReason: String? {
        let cfg = Config.shared
        if !cfg.refine {
            return "Auto cleanup is on None, so tones are paused and your words paste as heard."
        }
        if !cfg.hasModelAccess {
            return "Off SayControl Cloud, tones run on your own polish key, in Settings › Models. Until then, your words paste as heard."
        }
        if !cfg.refineStyle { return "Tones are off, so every app gets the same plain cleanup." }
        return nil
    }

    /// Builds the previews again when the reason they'd be paused changed.
    /// Returns whether anything did, so the pane can glide an open row to
    /// its new height.
    @discardableResult
    func refreshPaused(force: Bool = false) -> Bool {
        let why = Self.pausedReason
        switcher.alphaValue = why == nil ? 1 : 0.6
        guard force || why != paused else { return false }
        paused = why
        previews.forEach { $0.removeFromSuperview() }
        previews = context.options.map { option in
            TonePreview(context, option, short: Self.short(option, in: context), paused: why)
        }
        for p in previews {
            stage.addSubview(p)
            NSLayoutConstraint.activate([
                p.topAnchor.constraint(equalTo: stage.topAnchor),
                p.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
                p.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
                p.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            ])
        }
        refreshStatus()
        show(isOpen ? shown : picked, animated: false)
        return true
    }

    /// "In use" follows the pick.
    private func refreshStatus() {
        let inUse = switcher.index
        for (i, p) in previews.enumerated() { p.setStatus(inUse: i == inUse, paused: paused != nil) }
    }

    /// Turns the preview to tone `i`: the one going fades out quickly, the
    /// one coming fades in a beat slower, as the mockup's do.
    func show(_ i: Int, animated: Bool) {
        back?.cancel()
        shown = i
        for (k, p) in previews.enumerated() {
            let on = k == i
            guard animated else { p.layer?.removeAllAnimations(); p.alphaValue = on ? 1 : 0; continue }
            if on { fade(p, to: 1, duration: 0.16) }
            else { fade(p, to: 0, duration: 0.1, timing: CAMediaTimingFunction(name: .easeIn)) }
        }
    }

    /// The switch reports the pill under the pointer, nil off them. Off
    /// them, the preview goes back to the tone in use — a moment later, so
    /// sliding from one pill to the next never flashes it on the way.
    private func pointed(at i: Int?) {
        back?.cancel()
        guard isOpen else { return }
        if let i = i {
            if i != shown { show(i, animated: true) }
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.isOpen, self.shown != self.switcher.index else { return }
            self.show(self.switcher.index, animated: true)
        }
        back = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    // MARK: Opening and shutting

    /// The preview's height at the row's width. Two passes: the typed line
    /// learns its width in the first and reports its height in the second.
    func openHeight() -> CGFloat {
        layoutSubtreeIfNeeded()
        layoutSubtreeIfNeeded()
        return content.frame.height
    }

    /// The preview fades in a beat after the row starts opening while it
    /// settles 4 points down into place, and fades out quickly as it shuts.
    func reveal(_ open: Bool, animated: Bool) {
        guard let layer = content.layer else { return }
        let now = layer.presentation()
        // From wherever a fade under way has it; from the top when it was
        // out of sight.
        let hidden = (now?.opacity ?? layer.opacity) < 0.05
        let lift = hidden ? nil : now?.value(forKeyPath: "transform.translation.y") as? CGFloat
        layer.removeAnimation(forKey: "tones.lift")
        guard animated, window != nil, !Motion.reduced else {
            layer.removeAnimation(forKey: "tones.fade")
            content.alphaValue = open ? 1 : 0
            return
        }
        if open {
            fade(content, to: 1, duration: 0.22, delay: 0.06)
        } else {
            fade(content, to: 0, duration: 0.14)
        }
        // Up, in the clip's flipped space, is negative.
        let up = -Theme.m(4)
        let move = CABasicAnimation(keyPath: "transform.translation.y")
        move.fromValue = lift ?? (open ? up : 0)
        move.toValue = open ? 0 : up
        move.duration = open ? 0.3 : 0.24
        move.timingFunction = Motion.ease
        if !open {
            move.fillMode = .forwards
            move.isRemovedOnCompletion = false
        }
        layer.add(move, forKey: "tones.lift")
    }

    override func layout() {
        super.layout()
        // A width change rewraps the preview: keep an open row on its height.
        guard isOpen, !settling else { return }
        let h = content.frame.height
        if h > 1, abs(h - clipHeight.constant) > 0.5 { clipHeight.constant = h }
    }

    override var mouseDownCanMoveWindow: Bool { false }
}

// MARK: - The cleanup strength

/// None, Light, Moderate as three stops on a track: the track fills in
/// ember up to the one picked, so "how much" reads as a distance. Each stop
/// says in a few words what it takes out.
private final class CleanupSteps: NSView {
    private let titles: [String]
    private let lines: [String]
    private(set) var index: Int
    private var hover: Int?
    /// The ember fill's reach, 0…1, eased between picks.
    private var shown: CGFloat
    private var tween: Timer?
    var onPick: (Int) -> Void = { _ in }

    init(titles: [String], lines: [String], selected: Int) {
        self.titles = titles
        self.lines = lines
        index = selected
        shown = CGFloat(selected) / CGFloat(max(1, titles.count - 1))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Theme.m(19) + Theme.m(7) + Theme.m(19) + Theme.m(17)).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    private var knob: CGFloat { Theme.m(19) }

    func setIndex(_ i: Int, animated: Bool = false) {
        guard i != index else { return }
        index = i
        let target = CGFloat(i) / CGFloat(max(1, titles.count - 1))
        tween?.invalidate()
        guard animated, !Motion.reduced else { shown = target; needsDisplay = true; return }
        let from = shown, start = Date(), duration = 0.45
        tween = Timer.scheduledTimer(withTimeInterval: 1 / 60.0, repeats: true) { [weak self] t in
            guard let self = self else { return t.invalidate() }
            let p = min(1, Date().timeIntervalSince(start) / duration)
            // Ease out, with the slight overshoot the track's CSS has.
            let e = 1 - pow(1 - p, 3)
            self.shown = from + (target - from) * CGFloat(e)
            self.needsDisplay = true
            if p >= 1 { t.invalidate() }
        }
    }

    private func center(_ i: Int) -> CGFloat {
        let n = CGFloat(max(1, titles.count - 1))
        return knob / 2 + (bounds.width - knob) * CGFloat(i) / n
    }

    override func draw(_ dirtyRect: NSRect) {
        let y = knob / 2
        let left = center(0), right = center(titles.count - 1)
        let trackH = Theme.m(3)
        let track = NSRect(x: left, y: y - trackH / 2, width: right - left, height: trackH)
        Theme.hairline.setFill()
        NSBezierPath(roundedRect: track, xRadius: trackH / 2, yRadius: trackH / 2).fill()
        var lit = track
        lit.size.width = (right - left) * shown
        Theme.ember.setFill()
        NSBezierPath(roundedRect: lit, xRadius: trackH / 2, yRadius: trackH / 2).fill()

        for i in titles.indices {
            let cx = center(i)
            let grow: CGFloat = hover == i && i != index ? 1.12 : 1
            let r = knob / 2 * grow
            let rect = NSRect(x: cx - r, y: y - r, width: r * 2, height: r * 2)
            if i == index {
                Theme.emberSoft.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: -Theme.m(4), dy: -Theme.m(4))).fill()
                Theme.ember.setFill()
                NSBezierPath(ovalIn: rect).fill()
            } else {
                Theme.surface.setFill()
                NSBezierPath(ovalIn: rect).fill()
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
                ring.lineWidth = 2
                (i < index ? Theme.ember : Theme.hairline).setStroke()
                ring.stroke()
            }

            let on = i == index
            let title = NSAttributedString(string: titles[i], attributes: [
                .font: NSFont.systemFont(ofSize: Theme.m(13.5), weight: on ? .semibold : .medium),
                .foregroundColor: on ? Theme.ink : Theme.ink2])
            let line = NSAttributedString(string: lines[i], attributes: [
                .font: NSFont.systemFont(ofSize: Theme.m(12)), .foregroundColor: Theme.muted])
            let ty = knob + Theme.m(7)
            func x(for w: CGFloat) -> CGFloat {
                // First stop flush left, last flush right, the middle centred.
                i == 0 ? 0 : i == titles.count - 1 ? bounds.width - w : cx - w / 2
            }
            title.draw(at: NSPoint(x: x(for: title.size().width), y: ty))
            line.draw(at: NSPoint(x: x(for: line.size().width), y: ty + title.size().height + Theme.m(2)))
        }
    }

    private func stop(at p: NSPoint) -> Int {
        let local = convert(p, from: nil)
        return titles.indices.min { abs(center($0) - local.x) < abs(center($1) - local.x) } ?? 0
    }
    override func mouseUp(with event: NSEvent) {
        let i = stop(at: event.locationInWindow)
        guard i != index else { return }
        setIndex(i, animated: true)
        onPick(i)
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseMoved(with event: NSEvent) {
        let i = stop(at: event.locationInWindow)
        if i != hover { hover = i; needsDisplay = true }
    }
    override func mouseExited(with event: NSEvent) { hover = nil; needsDisplay = true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override var mouseDownCanMoveWindow: Bool { false }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: - The banner's picture

/// The banner's picture: each of the four places, the app that stands for
/// it on this Mac, and the tone it writes in now. The open row's place is
/// lit, so the picture follows the list under it — and a pick shows up in
/// it at once. Drawn in the banner's own fixed palette: cream on the dark
/// panel.
private final class ToneMap: NSView {
    private struct Row { let context: ToneContext; let mark: AppMark; let icon: NSImage?; let tone: String }
    private var rows: [Row] = []
    private var open: Int?
    private let rowH = Theme.m(26)
    private let gap = Theme.m(6)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let n = CGFloat(ToneContext.allCases.count)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Theme.m(250)),
            heightAnchor.constraint(equalToConstant: n * rowH + (n - 1) * gap),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func refresh(open: Int?) {
        self.open = open
        rows = ToneContext.allCases.map { c in
            let face = AppMarks.face(for: c)
            return Row(context: c, mark: face.mark, icon: face.icon, tone: Tones.option(for: c).title)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // The banner's palette is fixed in both modes, so its dark ink is too.
        let ink = HeroBanner.ink
        let labelFont = NSFont.systemFont(ofSize: Theme.m(12))
        let toneFont = NSFont.systemFont(ofSize: Theme.m(12), weight: .medium)
        for (i, row) in rows.enumerated() {
            let lit = i == open
            let y = CGFloat(i) * (rowH + gap)
            let mid = y + rowH / 2

            // The app: its own icon, a rounded square already, as the list's
            // logos are.
            let iconRect = NSRect(x: 0, y: y, width: rowH, height: rowH)
            if let icon = row.icon {
                icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: lit || open == nil ? 1 : 0.8,
                          respectFlipped: true, hints: nil)
            } else {
                // No app to ask: a tinted tile with its initial.
                let tile = iconRect.insetBy(dx: rowH * 0.1, dy: rowH * 0.1)
                row.mark.tint.setFill()
                NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.26, yRadius: tile.width * 0.26).fill()
                let letter = NSAttributedString(string: String(row.mark.name.prefix(1)), attributes: [
                    .font: NSFont.systemFont(ofSize: Theme.m(10), weight: .bold), .foregroundColor: NSColor.white,
                ])
                let ls = letter.size()
                letter.draw(at: NSPoint(x: tile.midX - ls.width / 2, y: tile.midY - ls.height / 2))
            }

            // The place.
            let label = NSAttributedString(string: row.context.title, attributes: [
                .font: labelFont, .foregroundColor: lit ? HeroBanner.cream : HeroBanner.creamSoft,
            ])
            let labelSize = label.size()
            let labelX = rowH + Theme.m(10)
            label.draw(at: NSPoint(x: labelX, y: mid - labelSize.height / 2))

            // The tone it writes in, as a pill on the right: cream when this
            // is the open row, frosted otherwise.
            let tone = NSAttributedString(string: row.tone, attributes: [
                .font: toneFont, .foregroundColor: lit ? ink : HeroBanner.cream,
            ])
            let toneSize = tone.size()
            let pillH = Theme.m(22)
            let pillW = (toneSize.width + Theme.m(20)).rounded()
            let pill = NSRect(x: bounds.width - pillW, y: mid - pillH / 2, width: pillW, height: pillH)
            (lit ? HeroBanner.cream : NSColor.white.withAlphaComponent(0.10)).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pillH / 2, yRadius: pillH / 2).fill()
            tone.draw(at: NSPoint(x: pill.midX - toneSize.width / 2, y: mid - toneSize.height / 2))

            // A dotted leader from the place to its tone.
            let from = labelX + labelSize.width + Theme.m(8)
            let to = pill.minX - Theme.m(8)
            guard to - from > Theme.m(10) else { continue }
            let leader = NSBezierPath()
            leader.move(to: NSPoint(x: from, y: mid.rounded() + 0.5))
            leader.line(to: NSPoint(x: to, y: mid.rounded() + 0.5))
            leader.lineWidth = 1.2
            leader.lineCapStyle = .round
            leader.setLineDash([0, 4], count: 2, phase: 0)
            NSColor.white.withAlphaComponent(lit ? 0.34 : 0.20).setStroke()
            leader.stroke()
        }
    }
}

// MARK: - The pane

final class TonesPane: PaneView {

    private var rows: [TonePlaceRow] = []
    /// The banner's picture, redrawn with every pick and every row opened.
    private let toneMap = ToneMap()
    private lazy var tweens: FrameTweens = {
        let t = FrameTweens(host: self)
        t.afterFrame = { [weak self] in self?.layoutSubtreeIfNeeded() }
        return t
    }()
    private var steps: CleanupSteps!
    private let cleanupSample = NSView()
    /// Your rules, inside the cleanup box — hidden while cleanup is None,
    /// since there is no pass for them to ride on.
    private var rulesSection: NSView!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Polish can be switched off elsewhere too, so the cleanup is read
    /// back every time the pane comes round.
    override func paneAppeared() {
        steps.setIndex(Self.cleanupIndex)
        refreshCleanup()
        refreshAlerts()
        refreshMap()
    }

    /// None, then the levels. None is the polish switch, not a level
    /// (CleanupLevel), so both places that show it agree.
    private static let cleanupTitles = ["None"] + CleanupLevel.allCases.map { $0.title }
    private static let cleanupLines = ["Pastes what was heard", "Takes the ums and stutters", "Drops false starts too"]
    private static var cleanupIndex: Int {
        guard Config.shared.refine else { return 0 }
        return 1 + (CleanupLevel.allCases.firstIndex(of: Tones.cleanupLevel) ?? 0)
    }

    // MARK: Assembly

    private func build() {
        // The banner says what the page is for, as Phrases' and the
        // Dictionary's do, with a picture of it: each place and its tone.
        let header = makePaneHeader("Tones")
        let hero = HeroBanner(title: "The right tone in every app",
                              subtitle: "You talk the same way everywhere. SayControl writes it to fit the app you’re in.",
                              art: .view(toneMap),
                              // One line, as the page's line was in the mockup.
                              lineWidth: 540, maxLineWidth: 560)

        let places = HubGroup()
        rows = ToneContext.allCases.map { TonePlaceRow($0) }
        for row in rows {
            row.onToggle = { [weak self] row in self?.toggle(row) }
            row.onPicked = { [weak self] in self?.refreshMap() }
            places.add(row, padded: false)
        }

        let scroll = Hub.scroll([header, hero, places, makeCleanupBox()])
        if let column = scroll.documentView?.subviews.first as? NSStackView {
            column.setCustomSpacing(Theme.px(14), after: header)
        }
        scroll.fill(self, inset: 0)
        refreshCleanup()
        // The first place starts open, so the page shows what a row holds.
        if let first = rows.first { setOpen(first, true, animated: false) }
    }

    // MARK: Opening and shutting

    /// A click on a row's head: it opens, and the open one shuts — or it
    /// shuts, if it was the open one. Both glide in the same frames.
    private func toggle(_ row: TonePlaceRow) {
        let opening = !row.isOpen
        for other in rows where other !== row && other.isOpen { setOpen(other, false, animated: true) }
        setOpen(row, opening, animated: true)
    }

    /// The row's height glides over 300 ms on Motion.ease while its preview
    /// fades in and settles (or fades out), and the chevron turns.
    private func setOpen(_ row: TonePlaceRow, _ open: Bool, animated: Bool) {
        guard let k = rows.firstIndex(where: { $0 === row }) else { return }
        if open { row.show(row.picked, animated: false) }
        row.isOpen = open
        row.reveal(open, animated: animated)
        row.settling = true
        tweens.run("height.\(k)", from: row.clipHeight.constant, to: open ? row.openHeight() : 0,
                   duration: 0.3, animated: animated,
                   apply: { row.clipHeight.constant = $0 },
                   done: { row.settling = false })
        tweens.run("turn.\(k)", from: row.chevron.turn, to: open ? 1 : 0, duration: 0.28, animated: animated,
                   apply: { row.chevron.turn = $0 })
        refreshMap()
    }

    /// The banner's picture: the tones in use, the open row's place lit.
    private func refreshMap() {
        toneMap.refresh(open: rows.firstIndex { $0.isOpen })
    }

    /// Auto cleanup — the strength, then what it does to a line — and,
    /// under it in the same box, your rules: instructions to this same pass.
    private func makeCleanupBox() -> NSView {
        let levels = CleanupLevel.allCases
        let tile = IconTile("wand.and.stars", .ember, side: 32, icon: 15)
        let title = Hub.text("Auto cleanup", 13.5, .medium)
        let line = Hub.text("Runs first, in every app, before the tone.", 12, .regular, Theme.muted)
        let words = Theme.vstack([title, line], spacing: Theme.m(2))
        let head = Theme.hstack([tile, words], spacing: Theme.m(13))
        head.alignment = .centerY

        steps = CleanupSteps(titles: Self.cleanupTitles, lines: Self.cleanupLines, selected: Self.cleanupIndex)
        steps.toolTip = levels.map { "\($0.title): \($0.detail)" }.joined(separator: "\n\n")
        steps.onPick = { [weak self] i in
            let cfg = Config.shared
            if i == 0 {
                cfg.setFlag("REFINE", false)
                cfg.log("Auto cleanup: none — polish off")
            } else {
                if !cfg.refine { cfg.setFlag("REFINE", true) }
                Tones.cleanupLevel = levels[i - 1]
            }
            self?.refreshCleanup()
            self?.refreshAlerts()
        }

        let body = NSView()
        let indent = Theme.m(32) + Theme.m(13)
        for v in [head, steps!, cleanupSample] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(v)
        }
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: body.topAnchor, constant: Theme.m(16)),
            head.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: Theme.m(18)),
            steps.topAnchor.constraint(equalTo: head.bottomAnchor, constant: Theme.m(18)),
            steps.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: Theme.m(18) + indent + Theme.m(6)),
            steps.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -Theme.m(24)),
            cleanupSample.topAnchor.constraint(equalTo: steps.bottomAnchor, constant: Theme.m(16)),
            cleanupSample.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: Theme.m(18) + indent),
            cleanupSample.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -Theme.m(18)),
            cleanupSample.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -Theme.m(16)),
        ])

        // Your own rules for the cleanup, in your words (CustomRules.swift),
        // under a rule of their own so the pair can go together.
        let divider = ColorView(color: Theme.hairsoft)
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        let rules = CustomRulesGroup(embedded: true)
        let rulesStack = Theme.vstack([divider, rules], spacing: 0)
        for v in [divider, rules] { v.widthAnchor.constraint(equalTo: rulesStack.widthAnchor).isActive = true }
        rulesSection = rulesStack

        let column = Theme.vstack([body, rulesStack], spacing: 0)
        for v in [body, rulesStack] { v.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        let box = HubGroup()
        box.add(column, padded: false)
        return box
    }

    /// The cleanup's example at the picked strength, the rules while there
    /// is a pass for them, and every row's previews, which say they're
    /// paused under None.
    ///
    /// All three examples are built once and stacked in one place, the
    /// shown one opaque: the box is as tall as the tallest of them, so a
    /// pick never makes it jump (None's unchanged line wraps a word later
    /// than Light's), and nothing under the pointer moves.
    private func refreshCleanup() {
        let i = Self.cleanupIndex
        if cleanupSample.subviews.isEmpty {
            let said = CleanupLevel.sample
            for k in 0..<Self.cleanupTitles.count {
                let written = k == 0 ? said : CleanupLevel.allCases[k - 1].sampleOutput
                let sample = ToneBeforeAfter(said: said, written: written)
                sample.translatesAutoresizingMaskIntoConstraints = false
                cleanupSample.addSubview(sample)
                NSLayoutConstraint.activate([
                    sample.topAnchor.constraint(equalTo: cleanupSample.topAnchor),
                    sample.leadingAnchor.constraint(equalTo: cleanupSample.leadingAnchor),
                    sample.trailingAnchor.constraint(equalTo: cleanupSample.trailingAnchor),
                    sample.bottomAnchor.constraint(equalTo: cleanupSample.bottomAnchor),
                ])
            }
        }
        for (k, sample) in cleanupSample.subviews.enumerated() {
            let alpha: CGFloat = k == i ? 1 : 0
            if window != nil, !Motion.reduced {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    sample.animator().alphaValue = alpha
                }
            } else {
                sample.alphaValue = alpha
            }
        }
        rulesSection.isHidden = !Config.shared.refine
        // A preview that gained or lost its "paused" note changes height:
        // an open one glides to the new one.
        for row in rows where row.refreshPaused() && row.isOpen {
            setOpen(row, true, animated: window != nil)
        }
    }

    /// Open a place's row from outside — what the snapshot dev tool walks
    /// the pane with. Anything past the last place shuts them all.
    func select(tab: Int) {
        for (k, row) in rows.enumerated() where row.isOpen != (k == tab) {
            setOpen(row, k == tab, animated: false)
        }
    }

    // MARK: Why tones might not apply

    /// The switches that leave tones inert, told in the window's alert
    /// corner (Alerts.swift) as well as in the previews. Cleanup: None is a
    /// choice the box already shows, so it says nothing; a missing key and
    /// tones switched off are things you'd want to know.
    private func refreshAlerts() {
        let cfg = Config.shared
        let alerts = AppAlerts.shared
        if cfg.refine && !cfg.hasModelAccess {
            // The same id the paste path posts a missing key under, so the
            // two never stack.
            alerts.clear("tones")
            alerts.post(AppAlert(id: "polish", title: "Polish has no key",
                                 message: "Off SayControl Cloud, auto cleanup, tones and your rules run on your own polish key.",
                                 actionTitle: "Open Settings", action: {
                                     SettingsUI.shared.select("settings")
                                     NotificationCenter.default.post(name: .sayctrlOpenSettingsTab, object: "model")
                                 }))
        } else if cfg.refine && !cfg.refineStyle {
            alerts.post(AppAlert(id: "tones", title: "Tones are off",
                                 message: "Every app gets the same plain cleanup.",
                                 actionTitle: "Turn tones on", action: {
                                     Config.shared.setFlag("REFINE_STYLE", true)
                                     Config.shared.log("Tones turned on from the alert")
                                     AppAlerts.shared.clear("tones")
                                     NotificationCenter.default.post(name: .owSettingsChanged, object: nil)
                                 }, severe: false))
        } else {
            alerts.clear("tones")
        }
    }
}
