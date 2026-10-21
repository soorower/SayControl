// The demos in How it works: a few seconds of motion on one small surface,
// one for each point the dial stops on (CommandsPane.swift). A demo is a
// script of beats — words typed a character at a time, a command said in
// its ember wash, a screenshot dropping in where it was said, words struck
// and squeezed away, a word turning into its fixed spelling, a key pressed,
// a text box rewriting itself — and the stage plays it on timers and Core
// Animation. Each point writes its demo as a few beats; nothing here knows
// which point it is playing.
//
// Drawn from design/howto-redesign.html: its CSS pixels go through How.px,
// its curves are its cubic-beziers and its timings are its own. Under
// Reduce Motion (and in --snapshot) a demo is its last frame: every beat
// lands at once and nothing moves. Nothing runs unless a stage is playing,
// and stop() takes every timer and tween it started with it.
import Cocoa

// MARK: - Measures

/// How it works' measures, its faces, and the few colours Theme has no
/// token for.
enum How {
    /// A pixel off design/howto-redesign.html. That mockup draws the window
    /// 1240 wide; the real one is 1260, so a pixel there is 1.016 here at the
    /// default text size — Theme.m's number × 0.944, the way Settings turns
    /// its own mockup into points — and it grows with the Text size setting.
    static func px(_ v: CGFloat) -> CGFloat { Theme.m(v * 0.944) }

    static func sans(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: px(size), weight: weight)
    }
    static func mono(_ size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: px(size), weight: .regular) }
    /// Theme.saidFont, the face for words somebody says, at a mockup size.
    static func said(_ size: CGFloat) -> NSFont { Theme.saidFont(size * 0.944) }
    /// Bricolage Grotesque, the site's display face: the sheet's title, the
    /// points, the dial's number.
    static func display(_ size: CGFloat, _ weight: CGFloat = 500) -> NSFont { Theme.heroFont(size * 0.944, weight) }

    /// Selected text, in the blue a Mac paints behind it, at `k` of its strength.
    static func selection(_ k: CGFloat = 1) -> NSColor {
        Theme.dyn(Theme.hex(0x2F6FDB, 0.19 * k), Theme.hex(0x7AA8FF, 0.30 * k))
    }
    /// A terminal: dark in either appearance, like the ones it stands for.
    static let term = Theme.dyn(Theme.hex(0x1B1B1E), Theme.hex(0x0B0B0D))
    static let termInk = Theme.hex(0xE8E8E6)
    static let termPrompt = Theme.hex(0x8FBF7F)
    static let termSigil = NSColor.white.withAlphaComponent(0.5)
    static let termCursor = NSColor.white.withAlphaComponent(0.75)
    static let termSaid = Theme.hex(0xFF9A78)
    static let termSaidFill = Theme.hex(0xFF6A3D, 0.18)
    /// The wash a fixed word lands in, on the terminal's dark.
    static let termWash = NSColor.white.withAlphaComponent(0.14)
    /// The desk behind a screenshot's window.
    static let deskTop = Theme.dyn(Theme.hex(0xD9DFE8), Theme.hex(0x29303D))
    static let deskEnd = Theme.dyn(Theme.hex(0xEBE6E0), Theme.hex(0x2B292F))
    /// The thin lit edge along the top of a key or the knob.
    static let shine = Theme.dyn(NSColor.white.withAlphaComponent(0.9), NSColor.white.withAlphaComponent(0.08))

    /// A shadow `dy` points down the screen. Only unflipped views cast
    /// one here, the way KeyChip casts its lip: a layer shadow under a
    /// flipped view's own layer doesn't fall the same way in every renderer.
    static func drop(_ dy: CGFloat) -> CGSize { CGSize(width: 0, height: -dy) }
}

// MARK: - Curves and tweens

/// A cubic-bezier, the way the mockup's CSS writes its curves: for what
/// Core Animation moves (`timing`) and for what has to be laid out again
/// on every frame, which a Tween moves.
struct Curve: Equatable {
    let x1, y1, x2, y2: Double
    init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2
    }

    /// Motion.ease: everything arrives on it.
    static let ease = Curve(0.2, 0.8, 0.2, 1)
    /// The knob's spring: a little past where it is going, then back.
    static let spring = Curve(0.34, 1.42, 0.5, 1)
    /// The picked tab sliding over, a chevron turning.
    static let glide = Curve(0.3, 1.18, 0.45, 1)
    static let easeIn = Curve(0.42, 0, 1, 1)
    static let linear = Curve(0, 0, 1, 1)

    var timing: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: Float(x1), Float(y1), Float(x2), Float(y2))
    }

    private static func at(_ s: Double, _ a: Double, _ b: Double) -> Double {
        let c = 3 * a, bb = 3 * (b - a) - c, aa = 1 - c - bb
        return ((aa * s + bb) * s + c) * s
    }
    private static func slope(_ s: Double, _ a: Double, _ b: Double) -> Double {
        let c = 3 * a, bb = 3 * (b - a) - c, aa = 1 - c - bb
        return (3 * aa * s + 2 * bb) * s + c
    }

    /// How far along the value is when `t` of the time has gone: Newton's
    /// method on the curve's x, bisection when that stalls.
    func callAsFunction(_ t: CGFloat) -> CGFloat {
        let t = Double(t)
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        var s = t
        for _ in 0..<8 {
            let x = Self.at(s, x1, x2) - t
            if abs(x) < 1e-5 { return CGFloat(Self.at(s, y1, y2)) }
            let d = Self.slope(s, x1, x2)
            if abs(d) < 1e-6 { break }
            s -= x / d
        }
        var lo = 0.0, hi = 1.0
        s = t
        while hi - lo > 1e-5 {
            if Self.at(s, x1, x2) < t { lo = s } else { hi = s }
            s = (lo + hi) / 2
        }
        return CGFloat(Self.at(s, y1, y2))
    }
}

/// A value eased from 0 to 1 over a few frames, for what has to be laid out
/// again while it moves: words squeezing away, a row opening, a width
/// becoming another. One timer serves every tween on screen and stops when
/// the last one ends; `owner` lets a stage cancel all of its own at once.
/// Under Reduce Motion a tween is its last step, taken at once.
final class Tween {
    private static var live: [Tween] = []
    private static var ticker: Timer?

    private let begin: CFTimeInterval
    private let duration: TimeInterval
    private let curve: Curve
    private let step: (CGFloat) -> Void
    private weak var owner: AnyObject?
    private var over = false

    private init(begin: CFTimeInterval, duration: TimeInterval, curve: Curve, owner: AnyObject?,
                 step: @escaping (CGFloat) -> Void) {
        self.begin = begin
        self.duration = duration
        self.curve = curve
        self.owner = owner
        self.step = step
    }

    /// `step` gets 0 at once — the value it starts from holds through any
    /// delay — then the eased fraction every frame, and exactly 1 last.
    @discardableResult
    static func run(_ duration: TimeInterval, delay: TimeInterval = 0, curve: Curve = .ease,
                    owner: AnyObject? = nil, _ step: @escaping (CGFloat) -> Void) -> Tween {
        let t = Tween(begin: CACurrentMediaTime() + delay, duration: duration, curve: curve, owner: owner, step: step)
        if Motion.reduced || (duration <= 0 && delay <= 0) {
            step(1)
            t.over = true
            return t
        }
        step(0)
        live.append(t)
        if ticker == nil {
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in tick() }
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        }
        return t
    }

    func cancel() { over = true }

    static func cancel(owner: AnyObject) {
        for t in live where t.owner === owner { t.over = true }
    }

    private static func tick() {
        let now = CACurrentMediaTime()
        for t in live where !t.over && now >= t.begin {
            let k = min(1, CGFloat((now - t.begin) / max(t.duration, 0.001)))
            t.step(t.curve(k))
            if k >= 1 { t.over = true }
        }
        live.removeAll { $0.over }
        if live.isEmpty {
            ticker?.invalidate()
            ticker = nil
        }
    }
}

// MARK: - Core Animation

/// The half of the motion that Core Animation makes on its own: opacity and
/// transforms. The model always holds where a view ends up (its alpha), so
/// a capture, or an animation cut short, shows the end and never the
/// middle. A transform is only ever on its way back to none — except on a
/// view that ends invisible, which may keep it.
enum Anim {
    /// `d` points down the screen, for a view in `v`'s superview: layers
    /// move in their superlayer's space, which is flipped when the superview
    /// is (Motion.rise works the same way).
    static func down(_ d: CGFloat, _ v: NSView) -> CGFloat { (v.superview?.isFlipped ?? false) ? d : -d }

    /// A lift (or a drop) of `dy` points down the screen.
    static func lift(_ dy: CGFloat, _ v: NSView) -> CATransform3D {
        CATransform3DMakeTranslation(0, down(dy, v), 0)
    }

    /// Scaled by `s` about the view's middle, then moved `dy` down. A
    /// view's layer turns about its corner, so the middle is put there first.
    static func shrink(_ s: CGFloat, _ v: NSView, dy: CGFloat = 0) -> CATransform3D {
        let w = v.bounds.width / 2, h = v.bounds.height / 2
        var t = CATransform3DMakeTranslation(w, h, 0)
        t = CATransform3DScale(t, s, s, 1)
        t = CATransform3DTranslate(t, -w, -h, 0)
        return CATransform3DConcat(t, CATransform3DMakeTranslation(0, down(dy, v), 0))
    }

    /// Fades to `alpha` from wherever the view shows now.
    static func fade(_ v: NSView, to alpha: CGFloat, _ duration: TimeInterval, delay: TimeInterval = 0,
                     curve: Curve = .ease) {
        v.wantsLayer = true
        let from = v.layer?.presentation()?.opacity ?? Float(v.alphaValue)
        v.alphaValue = alpha
        guard let layer = v.layer, !Motion.reduced, duration > 0 else {
            // At once — and a fade still waiting to start mustn't undo it.
            v.layer?.removeAnimation(forKey: "how.fade")
            return
        }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = Float(alpha)
        a.duration = duration
        a.beginTime = CACurrentMediaTime() + delay
        a.fillMode = .backwards
        a.timingFunction = curve.timing
        layer.add(a, forKey: "how.fade")
    }

    /// Arrives from `from` — a lift, a shrink — and from nothing, to where
    /// it is laid out at full strength. A fade never overshoots, so it eases
    /// even when the move springs.
    static func enter(_ v: NSView, from: CATransform3D, _ duration: TimeInterval, delay: TimeInterval = 0,
                      curve: Curve = .ease, fade: TimeInterval? = nil) {
        v.wantsLayer = true
        v.alphaValue = 1
        guard let layer = v.layer, !Motion.reduced else { return }
        layer.removeAnimation(forKey: "how.hold")
        let begin = CACurrentMediaTime() + delay
        let move = CABasicAnimation(keyPath: "transform")
        move.fromValue = NSValue(caTransform3D: from)
        move.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        move.duration = duration
        move.beginTime = begin
        move.fillMode = .backwards
        move.timingFunction = curve.timing
        layer.add(move, forKey: "how.move")
        let f = CABasicAnimation(keyPath: "opacity")
        f.fromValue = 0
        f.toValue = 1
        f.duration = fade ?? duration
        f.beginTime = begin
        f.fillMode = .backwards
        f.timingFunction = (curve == .spring ? Curve.ease : curve).timing
        layer.add(f, forKey: "how.fade")
    }

    /// Leaves for `to` and nothing, and stays there.
    static func leave(_ v: NSView, to: CATransform3D, _ duration: TimeInterval, fade: TimeInterval? = nil,
                      curve: Curve = .ease) {
        hold(v, to, duration, curve: curve)
        Anim.fade(v, to: 0, fade ?? duration, curve: curve)
    }

    /// A transform the view keeps until it is told otherwise — a key held
    /// down. `nil` lets it go back.
    static func hold(_ v: NSView, _ to: CATransform3D?, _ duration: TimeInterval, curve: Curve = .ease) {
        v.wantsLayer = true
        guard let layer = v.layer else { return }
        let from = layer.presentation()?.transform ?? CATransform3DIdentity
        layer.removeAnimation(forKey: "how.move")
        // Reduce Motion, or no time to do it in: let go at once. Nothing
        // ends held under Reduce Motion — a pressed key comes back up.
        guard !Motion.reduced, duration > 0 || to != nil else {
            layer.removeAnimation(forKey: "how.hold")
            return
        }
        let a = CABasicAnimation(keyPath: "transform")
        a.fromValue = NSValue(caTransform3D: from)
        a.toValue = NSValue(caTransform3D: to ?? CATransform3DIdentity)
        // Zero would be Core Animation's default quarter second.
        a.duration = max(duration, 0.001)
        a.timingFunction = curve.timing
        a.fillMode = .forwards
        a.isRemovedOnCompletion = to == nil
        layer.add(a, forKey: "how.hold")
    }

    /// A background that flashes `color` and fades to nothing: the wash a
    /// fixed word or a rewritten paragraph lands in. Holds for the first
    /// 30% of `duration`, as the mockup's `wash` keyframes do.
    static func wash(_ layer: CALayer?, _ color: NSColor, _ duration: TimeInterval, in view: NSView) {
        guard let layer = layer, !Motion.reduced else { return }
        var cg: CGColor = color.cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance { cg = color.cgColor }
        let clear = cg.copy(alpha: 0) ?? NSColor.clear.cgColor
        let a = CAKeyframeAnimation(keyPath: "backgroundColor")
        a.values = [cg, cg, clear]
        a.keyTimes = [0, 0.3, 1]
        a.duration = duration
        a.timingFunctions = [Curve.linear.timing, Curve.ease.timing]
        layer.backgroundColor = NSColor.clear.cgColor
        layer.add(a, forKey: "how.wash")
    }

    /// The caret's blink: on half the time, off half, no fade between.
    static func blink(_ v: NSView) {
        guard let layer = v.layer else { return }
        layer.removeAnimation(forKey: "how.blink")
        guard !Motion.reduced else { return }
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [1, 0]
        a.keyTimes = [0, 0.5, 1]
        a.calculationMode = .discrete
        a.duration = 1.05
        a.repeatCount = .infinity
        layer.add(a, forKey: "how.blink")
    }
}

// MARK: - Words

/// Words drawn by hand rather than in a text field, so they sit exactly
/// where they're put: on a middle shared with their neighbours, struck
/// through a little at a time, flagged with a wavy line, cut off as they
/// squeeze away. As wide as the words, as tall as the face.
final class Words: NSView {
    var text: String {
        didSet { if text != oldValue { invalidateIntrinsicContentSize(); needsDisplay = true } }
    }
    var color: NSColor { didSet { needsDisplay = true } }
    let font: NSFont
    private let kern: CGFloat
    /// How much of the line through is drawn, 0 to 1. The words go grey
    /// a little ahead of it, the way the mockup's colour runs quicker.
    var strike: CGFloat = 0 { didSet { needsDisplay = true } }
    /// A word about to be fixed: a faint wavy line under it.
    var wavy = false { didSet { needsDisplay = true } }

    init(_ text: String, _ font: NSFont, _ color: NSColor = Theme.ink, kern: CGFloat = 0) {
        self.text = text
        self.font = font
        self.color = color
        self.kern = kern
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func attributes(_ ink: NSColor) -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        if kern != 0 { a[.kern] = kern }
        return a
    }

    /// The width the words need, to the next whole point.
    var width: CGFloat { ceil(NSAttributedString(string: text, attributes: attributes(color)).size().width) }
    /// Ascender to descender: the box the words are drawn in.
    var lineHeight: CGFloat { ceil(font.ascender - font.descender) }
    override var intrinsicContentSize: NSSize { NSSize(width: width, height: lineHeight) }
    /// Down from the top of the view to the words' baseline.
    var baseline: CGFloat { ((bounds.height - lineHeight) / 2).rounded() + font.ascender }

    override func draw(_ dirtyRect: NSRect) {
        let ink = strike > 0 ? (color.blended(withFraction: min(1, strike * 1.4), of: Theme.muted) ?? color) : color
        let top = ((bounds.height - lineHeight) / 2).rounded()
        NSAttributedString(string: text, attributes: attributes(ink)).draw(at: NSPoint(x: 0, y: top))
        let base = top + font.ascender
        if strike > 0 {
            Theme.muted.setFill()
            // Through the middle of the lowercase letters.
            NSRect(x: 0, y: (base - font.xHeight / 2 - How.px(0.75)).rounded(),
                   width: width * strike, height: How.px(1.5)).fill()
        }
        if wavy {
            let path = NSBezierPath()
            let y = base + How.px(4)
            let amp = How.px(1.2), wave = How.px(4)
            var x: CGFloat = 0
            path.move(to: NSPoint(x: 0, y: y))
            while x < width {
                x += 1
                path.line(to: NSPoint(x: x, y: y + amp * sin(x / wave * .pi * 2)))
            }
            path.lineWidth = 1
            Theme.faint.setStroke()
            path.stroke()
        }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: - The pieces a demo is made of

/// A command the moment it's said: the words in ember on a soft ember wash,
/// set apart from the words typed around them.
final class SaidMark: NSView {
    let words: Words
    private let fill: NSColor
    private let padX = How.px(6)
    private let height: CGFloat

    init(_ text: String, font: NSFont, ink: NSColor = Theme.emberInk, fill: NSColor = Theme.emberSoft) {
        words = Words(text, font, ink)
        self.fill = fill
        height = (font.pointSize * 1.45).rounded()
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = How.px(6)
        addSubview(words)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: words.width + padX * 2, height: height) }
    /// Words added to a mark that is being typed into, as command mode's is.
    func append(_ s: String) {
        words.text += s
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
    }
    override func layout() {
        super.layout()
        words.frame = NSRect(x: padX, y: 0, width: words.width, height: bounds.height)
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = fill.cgColor }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// Where the next word lands: a thin ember bar that blinks, or a
/// terminal's block cursor.
final class Caret: NSView {
    enum Look { case bar, block }
    private let look: Look
    private let size: NSSize

    init(_ look: Look, font: NSFont) {
        self.look = look
        size = look == .bar ? NSSize(width: How.px(1.5), height: (font.pointSize * 1.1).rounded())
                            : NSSize(width: How.px(8), height: How.px(15))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = look == .bar ? 1 : 0
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { size }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { Anim.blink(self) }
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = (look == .bar ? Theme.ember : How.termCursor).cgColor
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// A screenshot, small: a window on a desk with a little chart in it — what
/// "take a screenshot" leaves where it was said.
final class ShotThumb: NSView {
    private let size: NSSize

    /// Mockup pixels: 58 × 36 in a line, 44 × 28 in a chat's composer.
    init(width: CGFloat = 58, height: CGFloat = 36) {
        size = NSSize(width: How.px(width), height: How.px(height))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        // The CSS's 0 6px 12px -6px: a soft shadow under it, pulled in.
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = How.px(6)
        layer?.shadowOffset = How.drop(How.px(6))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { size }

    override func draw(_ dirtyRect: NSRect) {
        let r = How.px(5)
        NSGraphicsContext.saveGraphicsState()
        // Drawn top down; the view stays unflipped for its shadow's sake.
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).addClip()
        // The CSS's 150°: down and a little right, which is 60° in a flipped view.
        NSGradient(starting: How.deskTop, ending: How.deskEnd)?.draw(in: bounds, angle: 60)
        // The window: in from the sides and the top, open at the bottom.
        let inset = bounds.width * 6 / 58
        let win = NSRect(x: inset, y: inset, width: bounds.width - inset * 2, height: bounds.height - inset)
        Theme.surface.setFill()
        let corner = How.px(3)
        let shape = NSBezierPath()
        shape.move(to: NSPoint(x: win.minX, y: win.maxY))
        shape.line(to: NSPoint(x: win.minX, y: win.minY + corner))
        shape.appendArc(withCenter: NSPoint(x: win.minX + corner, y: win.minY + corner), radius: corner,
                        startAngle: 180, endAngle: 270)
        shape.line(to: NSPoint(x: win.maxX - corner, y: win.minY))
        shape.appendArc(withCenter: NSPoint(x: win.maxX - corner, y: win.minY + corner), radius: corner,
                        startAngle: 270, endAngle: 360)
        shape.line(to: NSPoint(x: win.maxX, y: win.maxY))
        shape.close()
        shape.fill()
        // A small bar chart in the window's corner, the last bar dark.
        let u = bounds.width / 58
        let bars: [(dx: CGFloat, dy: CGFloat, dark: Bool)] = [(-18, 8, false), (-12, 3, false), (-6, 6, false), (0, 0, true)]
        for b in bars {
            (b.dark ? Theme.ink2 : Theme.hairline).setFill()
            NSRect(x: bounds.width - 15 * u + b.dx * u, y: bounds.height - 18 * u + b.dy * u,
                   width: 4 * u, height: 14 * u).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        // Its hairline ring.
        Theme.hairline.setStroke()
        let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: r - 0.5, yRadius: r - 0.5)
        ring.lineWidth = 1
        ring.stroke()
    }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(rect: bounds.insetBy(dx: How.px(6), dy: How.px(6)), transform: nil)
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// A rounded chip: an icon and a few words on a fill — the link a command
/// copied, a file it attached, the app the words are going to.
final class DemoChip: NSView {
    enum Look {
        /// "copy the link": a capsule on the sunk fill, with a hairline.
        case link
        /// "attach …": a card that floats, with a shadow.
        case file
        /// The app or window the words are going to: small, flat, muted.
        case label
        /// One of the assistants Ask can open.
        case service
        /// A phrase command mode listens for, under See more.
        case phrase
    }
    private let look: Look
    private let glyph: GlyphView?
    private let words: Words
    private let height: CGFloat
    private let padL: CGFloat, padR: CGFloat, gap: CGFloat

    init(_ text: String, symbol: String?, _ look: Look) {
        self.look = look
        let fontSize: CGFloat, iconSize: CGFloat, ink: NSColor
        switch look {
        case .link:    (height, fontSize, iconSize, ink) = (How.px(24), 13, 12, Theme.ink2)
        case .file:    (height, fontSize, iconSize, ink) = (How.px(32), 12.5, 15, Theme.ink)
        case .label:   (height, fontSize, iconSize, ink) = (How.px(22), 11.5, 12, Theme.muted)
        case .service: (height, fontSize, iconSize, ink) = (How.px(20), 11.5, 0, Theme.muted)
        case .phrase:  (height, fontSize, iconSize, ink) = (How.px(26), 12.5, 0, Theme.ink2)
        }
        switch look {
        case .link:    (padL, padR, gap) = (How.px(9), How.px(9), How.px(5))
        case .file:    (padL, padR, gap) = (How.px(10), How.px(12), How.px(7))
        case .label, .service: (padL, padR, gap) = (How.px(8), How.px(8), How.px(5))
        case .phrase:  (padL, padR, gap) = (How.px(11), How.px(11), 0)
        }
        words = Words(text, How.sans(fontSize), ink)
        if let s = symbol {
            let g = GlyphView(symbol: s, size: How.px(iconSize) * 0.86, weight: .regular, side: How.px(iconSize))
            g.tint = Theme.muted
            glyph = g
        } else {
            glyph = nil
        }
        super.init(frame: .zero)
        wantsLayer = true
        if let g = glyph {
            // It pins its own size with constraints; laid out by hand here.
            NSLayoutConstraint.deactivate(g.constraints)
            g.translatesAutoresizingMaskIntoConstraints = true
            addSubview(g)
        }
        addSubview(words)
        layer?.borderWidth = look == .label ? 0 : 1
        layer?.masksToBounds = false
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The icon's square: a GlyphView is made at its size and keeps it.
    private var iconSide: CGFloat { glyph?.frame.width ?? 0 }
    override var intrinsicContentSize: NSSize {
        NSSize(width: padL + (glyph == nil ? 0 : iconSide + gap) + words.width + padR, height: height)
    }
    override func layout() {
        super.layout()
        var x = padL
        if let g = glyph {
            let side = iconSide
            g.frame = NSRect(x: x, y: ((bounds.height - side) / 2).rounded(), width: side, height: side)
            x += side + gap
        }
        words.frame = NSRect(x: x, y: 0, width: words.width, height: bounds.height)
        layer?.cornerRadius = look == .file ? How.px(8) : (look == .label ? How.px(6) : bounds.height / 2)
        if look == .file {
            layer?.shadowPath = CGPath(roundedRect: bounds.insetBy(dx: How.px(8), dy: How.px(8)),
                                       cornerWidth: How.px(8), cornerHeight: How.px(8), transform: nil)
        }
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        switch look {
        case .link:
            layer?.backgroundColor = Theme.wellFill.cgColor
            layer?.borderColor = Theme.hairline.cgColor
        case .file:
            layer?.backgroundColor = Theme.surface.cgColor
            layer?.borderColor = Theme.hairline.cgColor
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.3
            layer?.shadowRadius = How.px(7)
            layer?.shadowOffset = How.drop(How.px(6))
        case .label:
            layer?.backgroundColor = Theme.wellFill.cgColor
        case .service:
            layer?.backgroundColor = Theme.wellFill.cgColor
            layer?.borderColor = Theme.hairsoft.cgColor
        case .phrase:
            layer?.backgroundColor = Theme.surface.cgColor
            layer?.borderColor = Theme.hairline.cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// An app's tile with its initial, in ink — what "open Claude" opens, and
/// the favicon of the tab Ask lands in. SayControl ships nobody's artwork.
final class AppBadge: NSView {
    private let letter: Words
    private let side: CGFloat
    private let radius: CGFloat

    /// Mockup pixels: 36 for an app opening, 14 for a tab's favicon.
    init(_ name: String, side: CGFloat) {
        self.side = How.px(side)
        radius = How.px(side >= 30 ? 9 : 4)
        letter = Words(String(name.prefix(1)), How.display(side >= 30 ? 17 : 9, 600), Theme.paper)
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(letter)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }
    override func layout() {
        super.layout()
        layer?.cornerRadius = radius
        let w = letter.width
        letter.frame = NSRect(x: ((bounds.width - w) / 2).rounded(), y: 0, width: w, height: bounds.height)
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Theme.ink.cgColor }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: - A line

/// One line of a demo, laid out by hand: runs of words and the things that
/// land among them, left to right on one middle, and the caret after the
/// last of them. Never wraps — a demo's line is written to fit.
final class DemoLine: NSView {
    /// The line's faces and colours: a text box's, a chat composer's, a
    /// terminal's.
    struct Style {
        let font: NSFont
        let ink: NSColor
        let saidFont: NSFont
        let saidInk: NSColor
        let saidFill: NSColor
        let caret: Caret.Look
        let wash: NSColor
        /// The CSS line-height: what the line takes with nothing tall in it.
        let lineHeight: CGFloat

        static var text: Style {
            Style(font: How.said(15.5), ink: Theme.ink, saidFont: How.said(15.5), saidInk: Theme.emberInk,
                  saidFill: Theme.emberSoft, caret: .bar, wash: Theme.navPick, lineHeight: How.px(15.5 * 1.5))
        }
        static var compose: Style {
            Style(font: How.said(13.5), ink: Theme.ink, saidFont: How.said(13.5), saidInk: Theme.emberInk,
                  saidFill: Theme.emberSoft, caret: .bar, wash: Theme.navPick, lineHeight: How.px(13.5 * 1.5))
        }
        static var terminal: Style {
            Style(font: How.mono(13), ink: How.termInk, saidFont: How.said(14.5), saidInk: How.termSaid,
                  saidFill: How.termSaidFill, caret: .block, wash: How.termWash, lineHeight: How.px(13 * 1.5))
        }
    }

    enum Kind { case words, said, thing, morph, lead }

    /// One run of the line: a view, the room it takes, and its margins.
    final class Run {
        let kind: Kind
        var view: NSView
        /// Animated width; nil is as wide as the view wants.
        var width: CGFloat?
        var lead: CGFloat
        var trail: CGFloat
        /// Words struck through, on their way out.
        var struck = false
        /// A said mark that has faded, waiting for what lands in its place.
        var spent = false
        init(_ kind: Kind, _ view: NSView, lead: CGFloat = 0, trail: CGFloat = 0) {
            self.kind = kind
            self.view = view
            self.lead = lead
            self.trail = trail
        }
    }

    let style: Style
    private(set) var runs: [Run] = []
    let caret: Caret
    private var caretShown = true

    init(_ style: Style) {
        self.style = style
        caret = Caret(style.caret, font: style.font)
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(caret)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// As tall as the tallest thing in it, never less than a line of text.
    var contentHeight: CGFloat {
        runs.reduce(style.lineHeight) { max($0, $1.view.intrinsicContentSize.height) }
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for r in runs {
            x += r.lead
            let size = r.view.intrinsicContentSize
            let w = max(0, r.width ?? size.width)
            r.view.frame = NSRect(x: x, y: ((bounds.height - size.height) / 2).rounded(), width: w, height: size.height)
            x += w + r.trail
        }
        let c = caret.intrinsicContentSize
        let gap = style.caret == .bar ? How.px(1) : How.px(3)
        caret.frame = NSRect(x: x + gap, y: ((bounds.height - c.height) / 2).rounded(), width: c.width, height: c.height)
        caret.isHidden = !caretShown
    }

    func hideCaret() {
        caretShown = false
        needsLayout = true
    }

    private func append(_ run: Run) {
        runs.append(run)
        addSubview(run.view, positioned: .below, relativeTo: caret)
        needsLayout = true
        superview?.needsLayout = true
    }

    // MARK: What happens on it

    /// Something set before the words: the app they're going to, a prompt.
    func lead(_ v: NSView, trail: CGFloat) {
        append(Run(.lead, v, trail: trail))
    }

    /// Words typed at the caret: onto the last run when it is plain words,
    /// else into a run of their own after whatever landed last.
    func type(_ s: String) {
        if let r = runs.last, r.kind == .words, !r.struck, let w = r.view as? Words {
            w.text += s
        } else {
            append(Run(.words, Words(s, style.font, style.ink)))
        }
        needsLayout = true
    }

    /// A command, said: its mark pops in at the caret.
    @discardableResult
    func say(_ s: String, instant: Bool) -> SaidMark {
        let mark = SaidMark(s, font: style.saidFont, ink: style.saidInk, fill: style.saidFill)
        append(Run(.said, mark, lead: How.px(1), trail: How.px(1)))
        layoutSubtreeIfNeeded()
        if !instant { Anim.enter(mark, from: Anim.shrink(0.8, mark), 0.4, curve: .spring) }
        return mark
    }

    /// The last command fades out; its place waits for what it brings.
    func unsay(instant: Bool) {
        guard let r = runs.last(where: { $0.kind == .said && !$0.spent }) else { return }
        r.spent = true
        if instant { r.view.alphaValue = 0 } else { Anim.leave(r.view, to: Anim.shrink(0.85, r.view), 0.2) }
    }

    /// What a command brings lands where it was said: `drop` falls in from
    /// above, else it pops.
    func land(_ v: NSView, lead: CGFloat, trail: CGFloat, drop: Bool, instant: Bool) {
        let run = Run(.thing, v, lead: lead, trail: trail)
        if let i = runs.lastIndex(where: { $0.kind == .said && $0.spent }) {
            runs[i].view.removeFromSuperview()
            runs[i] = run
            addSubview(v, positioned: .below, relativeTo: caret)
        } else {
            append(run)
        }
        needsLayout = true
        superview?.needsLayout = true
        layoutSubtreeIfNeeded()
        guard !instant else { return }
        if drop { Anim.enter(v, from: Anim.shrink(0.7, v, dy: -How.px(18)), 0.6, curve: .spring) }
        else { Anim.enter(v, from: Anim.shrink(0.8, v), 0.45, curve: .spring) }
    }

    /// Spent marks gone at once — the slot cleared.
    func clearSpent() {
        for r in runs where r.kind == .said && r.spent { r.view.removeFromSuperview() }
        runs.removeAll { $0.kind == .said && $0.spent }
        needsLayout = true
    }

    /// Cuts `part` out of the words typed so far into a run of its own, and
    /// returns that run's index. nil is the last run of words, whole.
    private func isolate(_ part: String?) -> Int? {
        for i in runs.indices.reversed() {
            let r = runs[i]
            guard r.kind == .words, !r.struck, let w = r.view as? Words else { continue }
            guard let part = part else { return i }
            guard let range = w.text.range(of: part) else { continue }
            let before = String(w.text[..<range.lowerBound]), after = String(w.text[range.upperBound...])
            var pieces: [Run] = []
            if !before.isEmpty { pieces.append(Run(.words, Words(before, style.font, style.ink))) }
            pieces.append(Run(.words, Words(part, style.font, style.ink)))
            if !after.isEmpty { pieces.append(Run(.words, Words(after, style.font, style.ink))) }
            w.removeFromSuperview()
            runs.replaceSubrange(i...i, with: pieces)
            for p in pieces { addSubview(p.view, positioned: .below, relativeTo: caret) }
            needsLayout = true
            layoutSubtreeIfNeeded()
            return i + (before.isEmpty ? 0 : 1)
        }
        return nil
    }

    /// Words struck through, a beat after they are picked out.
    func strike(_ part: String?, instant: Bool, owner: AnyObject) {
        guard let i = isolate(part), let w = runs[i].view as? Words else { return }
        runs[i].struck = true
        w.layer?.masksToBounds = true
        if instant { w.strike = 1; return }
        Tween.run(0.35, delay: 0.1, owner: owner) { [weak w] k in w?.strike = k }
    }

    /// The struck words squeeze to nothing and fade, and any spent mark
    /// beside them goes.
    func vanish(instant: Bool, owner: AnyObject) {
        clearSpent()
        for r in runs where r.struck {
            let from = r.view.intrinsicContentSize.width
            if instant {
                r.width = 0
                r.view.alphaValue = 0
                continue
            }
            Anim.fade(r.view, to: 0, 0.35)
            Tween.run(0.5, owner: owner) { [weak self, weak r] k in
                r?.width = from * (1 - k)
                self?.needsLayout = true
            }
        }
        needsLayout = true
    }

    /// Words that fade in at the end of the line.
    func add(_ s: String, instant: Bool) {
        let w = Words(s, style.font, style.ink)
        append(Run(.words, w))
        w.alphaValue = 0
        Anim.fade(w, to: 1, instant ? 0 : 0.3)
    }

    /// `part` (nil: the last words, whole) flagged with a wavy line, then
    /// a beat later turned into `to`.
    func fix(_ part: String?, to: String, instant: Bool, owner: AnyObject) {
        guard let i = isolate(part), let w = runs[i].view as? Words else { return }
        w.wavy = true
        let morph = Morph(w, Words(to, style.font, style.ink))
        swapRun(i, to: morph)
        if instant { morph.go(in: runs[i], line: self, instant: true, wash: style.wash, owner: owner); return }
        // A zero-length tween is a timer the stage can cancel with the rest.
        Tween.run(0, delay: 0.45, owner: owner) { [weak self, weak morph] k in
            guard k >= 1, let self = self, let morph = morph,
                  let run = self.runs.first(where: { $0.view === morph }) else { return }
            morph.go(in: run, line: self, instant: false, wash: self.style.wash, owner: owner)
        }
    }

    /// The command just said turns into what it stands for — "list the
    /// files" into ls.
    func becomes(_ s: String, instant: Bool, owner: AnyObject) {
        guard let i = runs.lastIndex(where: { $0.kind == .said }) else { return }
        let morph = Morph(runs[i].view, Words(s, style.font, style.ink))
        swapRun(i, to: morph)
        morph.go(in: runs[i], line: self, instant: instant, wash: style.wash, owner: owner)
    }

    private func swapRun(_ i: Int, to morph: Morph) {
        let old = runs[i]
        let run = Run(.morph, morph, lead: old.lead, trail: old.trail)
        old.view.removeFromSuperview()
        morph.adopt()
        runs[i] = run
        addSubview(morph, positioned: .below, relativeTo: caret)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// The line lifts away and fades — its words have gone somewhere.
    func fly(instant: Bool) {
        if instant { alphaValue = 0; return }
        Anim.leave(self, to: Anim.lift(-How.px(16), self), 0.45, fade: 0.35)
    }
}

/// A word becoming another: the old fades up and out while the new one
/// comes up from under it in a wash, and the room between them eases from
/// one width to the other.
final class Morph: NSView {
    private let a: NSView
    private let b: Words
    private(set) var done = false

    init(_ a: NSView, _ b: Words) {
        self.a = a
        self.b = b
        super.init(frame: .zero)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Takes in both words, the new one hidden.
    func adopt() {
        a.removeFromSuperview()
        addSubview(a)
        addSubview(b)
        b.alphaValue = 0
        b.wantsLayer = true
        b.layer?.cornerRadius = How.px(4)
    }

    override var intrinsicContentSize: NSSize {
        let sa = a.intrinsicContentSize, sb = b.intrinsicContentSize
        return NSSize(width: done ? sb.width : sa.width, height: max(sa.height, sb.height))
    }
    override func layout() {
        super.layout()
        let sa = a.intrinsicContentSize, sb = b.intrinsicContentSize
        a.frame = NSRect(x: 0, y: ((bounds.height - sa.height) / 2).rounded(), width: sa.width, height: sa.height)
        b.frame = NSRect(x: 0, y: ((bounds.height - sb.height) / 2).rounded(), width: sb.width, height: sb.height)
    }

    func go(in run: DemoLine.Run, line: DemoLine, instant: Bool, wash: NSColor, owner: AnyObject) {
        let from = a.intrinsicContentSize.width, to = b.intrinsicContentSize.width
        done = true
        if instant {
            a.alphaValue = 0
            b.alphaValue = 1
            run.width = nil
            line.needsLayout = true
            return
        }
        run.width = from
        Tween.run(0.45, owner: owner) { [weak line, weak run] k in
            run?.width = from + (to - from) * k
            line?.needsLayout = true
        }
        Anim.leave(a, to: Anim.lift(-How.px(5), a), 0.45, fade: 0.4)
        Anim.enter(b, from: Anim.lift(How.px(5), b), 0.45, fade: 0.4)
        Anim.wash(b.layer, wash, 1.6, in: self)
    }
}

// MARK: - The stage

/// A demo: the surface it plays on, and its beats in order.
struct Demo {
    /// The few words on a chip: what it says, and its SF Symbol.
    struct Chip {
        let text: String
        let symbol: String
    }
    enum Corner {
        /// The window the names on screen come from.
        case window(String)
        /// A key at the line's right end, pressed by the demo.
        case key(String)
    }
    enum Look {
        /// A line of text as dictation lands it. `lead` sits before the
        /// words — the app they're going to; `corner` at the right end.
        /// `caret` is false for a line nothing is typed into.
        case line(lead: Chip? = nil, corner: Corner? = nil, caret: Bool = true)
        /// A terminal's prompt, in a folder.
        case terminal(String)
        /// Command mode: the keys and the instruction on top, a text box
        /// with the words in it under them.
        case field(String)
    }

    let look: Look
    let beats: [Beat]
    init(_ look: Look, _ beats: [Beat]) {
        self.look = look
        self.beats = beats
    }
}

/// What lands where a command was said.
enum Landing {
    case shot
    case link(String)
}

/// One step of a demo. Each happens the moment it's reached; `.wait` is the
/// only thing that moves time on, apart from typing, which takes as long
/// as its characters do.
indirect enum Beat {
    case wait(TimeInterval)
    /// Words typed at the caret, a character every `per` seconds.
    case type(String, per: TimeInterval = 0.03)
    /// A command said: a mark at the caret, or, in command mode, the
    /// instruction typed into its bubble a character every `per` seconds.
    case say(String, per: TimeInterval? = nil)
    /// The command's mark fades; its place waits for what it brings.
    case unsay
    /// What the command brought lands in its place.
    case land(Landing)
    /// A file drops into the chat above the line, and the mark's place goes.
    case attach(String)
    /// These words (nil: the last words, whole) struck through.
    case strike(String?)
    /// Struck words squeeze away.
    case vanish
    /// Words that fade in at the end.
    case add(String)
    /// These words (nil: the last words, whole) flagged, then fixed.
    case fix(String?, to: String)
    /// The command just said becomes what it types.
    case becomes(String)
    /// The line lifts away.
    case fly
    /// An app opens: its tile and its name, under the line.
    case open(String)
    /// A browser tab: the site's name and address over a chat's composer.
    case browser(String, url: String)
    /// Words land in the composer.
    case compose(String)
    /// A screenshot lands in the composer.
    case composeShot
    /// The demo's keys go down, and come back up.
    case press
    case release
    /// What happened, in a quiet line where the words were.
    case done(String)
    /// The text box's words selected.
    case select
    /// The text box rewritten.
    case rewrite(String)
    /// Played only with motion: Reduce Motion's last frame stops before it,
    /// so there is still something to see.
    case moving(Beat)
}

/// The surface a demo plays on: a rounded white card that clips what moves
/// in it, a fixed height per tab. Pointing at it says so (the dial holds
/// still), and a click on it plays the demo again.
final class DemoStage: NSView {
    var onHover: (Bool) -> Void = { _ in }
    var onClick: () -> Void = {}
    private let height: CGFloat
    private(set) var hovering = false

    private var look: Demo.Look = .line()
    private var timers: [Timer] = []

    // The line look.
    private var line: DemoLine?
    private var corner: NSView?
    private var attRow: NSView?
    private var attHeight: CGFloat = 0
    private var resRow: NSView?
    private var resHeight: CGFloat = 0
    private var sent: NSView?
    private var browser: NSView?
    private var composer: DemoLine?
    // The terminal.
    private var termBack: ColorView?
    // Command mode.
    private var keys: [KeyChip] = []
    private var keyRow: NSView?
    private var bubble: SaidMark?
    private var field: FieldText?

    private let padX = How.px(18)

    /// `height` in mockup pixels: 72 for Dictation, 104 for Controls, 150
    /// for Command mode.
    init(height: CGFloat) {
        self.height = How.px(height)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = How.px(12)
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: self.height).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // MARK: Playing

    /// Builds the demo's surface and plays its beats from the top — or,
    /// under Reduce Motion, lands every one of them at once.
    func play(_ demo: Demo) {
        stop()
        build(demo.look)
        if Motion.reduced {
            for b in demo.beats { apply(b, instant: true) }
        } else {
            var t: TimeInterval = 0
            for b in demo.beats { t = schedule(b, at: t) }
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// Every timer and tween this stage started, cancelled. What is on it
    /// stays where it is.
    func stop() {
        timers.forEach { $0.invalidate() }
        timers = []
        Tween.cancel(owner: self)
    }

    /// The pointer counted as gone: the stage is folding away under a
    /// pointer that hasn't moved, and AppKit may never say it left.
    func forgetPointer() {
        guard hovering else { return }
        hovering = false
        onHover(false)
    }

    private func at(_ t: TimeInterval, _ run: @escaping () -> Void) {
        let timer = Timer(timeInterval: max(0.001, t), repeats: false) { _ in run() }
        timer.tolerance = 0.005
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
    }

    private func schedule(_ beat: Beat, at t: TimeInterval) -> TimeInterval {
        switch beat {
        case .wait(let d):
            return t + d
        case .type(let s, let per):
            for (n, ch) in s.enumerated() {
                at(t + per * Double(n + 1)) { [weak self] in self?.line?.type(String(ch)); self?.needsLayout = true }
            }
            return t + per * Double(s.count)
        case .say(let s, let per?) where field != nil:
            at(t) { [weak self] in self?.showBubble("", instant: false) }
            for (n, ch) in s.enumerated() {
                at(t + per * Double(n + 1)) { [weak self] in self?.bubble?.append(String(ch)); self?.needsLayout = true }
            }
            return t + per * Double(s.count)
        case .moving(let b):
            return schedule(b, at: t)
        default:
            at(t) { [weak self] in self?.apply(beat, instant: false) }
            return t
        }
    }

    private func apply(_ beat: Beat, instant: Bool) {
        switch beat {
        case .wait:
            break
        case .type(let s, _):
            line?.type(s)
        case .say(let s, _):
            if field != nil { showBubble(s, instant: instant) } else { line?.say(s, instant: instant) }
        case .unsay:
            line?.unsay(instant: instant)
        case .land(.shot):
            line?.land(ShotThumb(), lead: How.px(4), trail: How.px(4), drop: true, instant: instant)
        case .land(.link(let url)):
            line?.land(DemoChip(url, symbol: "link", .link), lead: How.px(2), trail: How.px(2), drop: false, instant: instant)
        case .attach(let name):
            attach(name, instant: instant)
        case .strike(let part):
            line?.strike(part, instant: instant, owner: self)
        case .vanish:
            line?.vanish(instant: instant, owner: self)
        case .add(let s):
            line?.add(s, instant: instant)
        case .fix(let part, let to):
            line?.fix(part, to: to, instant: instant, owner: self)
        case .becomes(let s):
            line?.becomes(s, instant: instant, owner: self)
        case .fly:
            line?.fly(instant: instant)
        case .open(let app):
            open(app, instant: instant)
        case .browser(let name, let url):
            showBrowser(name, url: url, instant: instant)
        case .compose(let s):
            composer?.type(s)
            browser?.needsLayout = true
        case .composeShot:
            composer?.land(ShotThumb(width: 44, height: 28), lead: How.px(4), trail: How.px(4), drop: true, instant: instant)
            browser?.needsLayout = true
        case .press:
            pressKeys(true, instant: instant)
        case .release:
            pressKeys(false, instant: instant)
        case .done(let s):
            done(s, instant: instant)
        case .select:
            field?.select(instant: instant, owner: self)
        case .rewrite(let s):
            field?.rewrite(s, instant: instant)
        case .moving(let b):
            if !instant { apply(b, instant: false) }
        }
        needsLayout = true
    }

    // MARK: Building

    private func build(_ look: Demo.Look) {
        self.look = look
        subviews.forEach { $0.removeFromSuperview() }
        line = nil; corner = nil; attRow = nil; resRow = nil; sent = nil; browser = nil
        composer = nil; termBack = nil; keys = []; keyRow = nil; bubble = nil; field = nil
        attHeight = 0
        resHeight = 0
        switch look {
        case .line(let lead, let c, let caret):
            let l = DemoLine(.text)
            if !caret { l.hideCaret() }
            if let lead = lead { l.lead(DemoChip(lead.text, symbol: lead.symbol, .label), trail: How.px(10)) }
            addSubview(l)
            line = l
            let att = FlippedView()
            att.wantsLayer = true
            addSubview(att)
            attRow = att
            let res = FlippedView()
            res.wantsLayer = true
            res.layer?.masksToBounds = true
            addSubview(res)
            resRow = res
            switch c {
            case .window(let name)?:
                let chip = DemoChip(name, symbol: "macwindow", .label)
                addSubview(chip)
                corner = chip
            case .key(let name)?:
                let key = KeyChip(KeyPart(name), small: true)
                key.translatesAutoresizingMaskIntoConstraints = true
                addSubview(key)
                corner = key
                keys = [key]
            case nil:
                break
            }
        case .terminal(let prompt):
            let back = ColorView(color: How.term)
            addSubview(back)
            termBack = back
            let l = DemoLine(.terminal)
            l.lead(Words(prompt, How.mono(13), How.termPrompt), trail: 0)
            let sigil = Words("%", How.mono(13), How.termSigil)
            l.lead(sigil, trail: How.px(8))
            if let r = l.runs.last { r.lead = How.px(6) }
            addSubview(l)
            line = l
        case .field(let text):
            let row = FlippedView()
            var made: [KeyChip] = []
            for (i, part) in Shortcuts.command.enumerated() {
                if i > 0 {
                    let plus = Words("+", How.sans(12), Theme.faint)
                    row.addSubview(plus)
                }
                let k = KeyChip(part, small: true)
                k.translatesAutoresizingMaskIntoConstraints = true
                row.addSubview(k)
                made.append(k)
            }
            keys = made
            addSubview(row)
            keyRow = row
            let f = FieldText(text)
            addSubview(f)
            field = f
        }
    }

    private func showBubble(_ s: String, instant: Bool) {
        guard let row = keyRow else { return }
        let mark = SaidMark(s, font: How.said(14), ink: Theme.emberInk, fill: Theme.emberSoft)
        row.addSubview(mark)
        bubble = mark
        needsLayout = true
        layoutSubtreeIfNeeded()
        if !instant { Anim.enter(mark, from: Anim.shrink(0.8, mark), 0.4, curve: .spring) }
    }

    private func attach(_ name: String, instant: Bool) {
        line?.clearSpent()
        guard let att = attRow else { return }
        let chip = DemoChip(name, symbol: "doc", .file)
        att.addSubview(chip)
        let target = How.px(32 + 8)
        if instant {
            attHeight = target
        } else {
            Tween.run(0.4, owner: self) { [weak self] k in
                self?.attHeight = target * k
                self?.needsLayout = true
            }
        }
        layoutSubtreeIfNeeded()
        if !instant { Anim.enter(chip, from: Anim.shrink(0.7, chip, dy: -How.px(18)), 0.55, curve: .spring) }
    }

    private func open(_ app: String, instant: Bool) {
        guard let res = resRow else { return }
        let badge = AppBadge(app, side: 36)
        let name = Words(app, How.sans(13, .medium), Theme.ink)
        let opens = Words("opens", How.sans(13), Theme.muted)
        let label = Theme.hstack([name, opens], spacing: How.px(4))
        label.translatesAutoresizingMaskIntoConstraints = true
        label.frame.size = label.fittingSize
        res.addSubview(badge)
        res.addSubview(label)
        let target = How.px(40 + 8)
        if instant {
            resHeight = target
        } else {
            Tween.run(0.35, owner: self) { [weak self] k in
                self?.resHeight = target * k
                self?.needsLayout = true
            }
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        if !instant {
            Anim.enter(badge, from: Anim.shrink(0.4, badge), 0.6, curve: .spring)
            Anim.enter(label, from: Anim.lift(How.px(10), label), 0.38, delay: 0.15)
        }
    }

    private func showBrowser(_ name: String, url: String, instant: Bool) {
        let card = BrowserCard(name, url: url)
        addSubview(card)
        browser = card
        composer = card.composer
        needsLayout = true
        layoutSubtreeIfNeeded()
        if !instant { Anim.enter(card, from: Anim.lift(How.px(10), card), 0.5, fade: 0.4) }
    }

    private func pressKeys(_ down: Bool, instant: Bool) {
        for k in keys { k.setDown(down, animated: !instant) }
    }

    private func done(_ s: String, instant: Bool) {
        let check = GlyphView(symbol: "checkmark", size: How.px(12), weight: .semibold, side: How.px(14))
        check.tint = Theme.ink2
        let words = Words(s, How.sans(13), Theme.muted)
        let row = Theme.hstack([check, words], spacing: How.px(8))
        row.translatesAutoresizingMaskIntoConstraints = true
        addSubview(row)
        sent = row
        if let key = corner as? KeyChip { key.setDown(false, animated: false) }
        needsLayout = true
        layoutSubtreeIfNeeded()
        if !instant { Anim.enter(row, from: Anim.lift(How.px(8), row), 0.45, fade: 0.35) }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        switch look {
        case .line:
            guard let line = line else { return }
            let lineH = line.contentHeight
            let total = attHeight + lineH + resHeight
            var y = ((h - total) / 2).rounded()
            if let att = attRow {
                att.frame = NSRect(x: padX, y: y, width: w - padX * 2, height: attHeight)
                for v in att.subviews {
                    let s = v.intrinsicContentSize
                    v.frame = NSRect(x: 0, y: 0, width: s.width, height: s.height)
                }
            }
            y += attHeight
            line.frame = NSRect(x: padX, y: y, width: w - padX * 2, height: lineH)
            y += lineH
            if let res = resRow {
                res.frame = NSRect(x: padX, y: y, width: w - padX * 2, height: resHeight)
                var x: CGFloat = 0
                let top = How.px(8)
                for v in res.subviews {
                    let s = v is NSStackView ? v.fittingSize : v.intrinsicContentSize
                    v.frame = NSRect(x: x, y: top + ((How.px(40) - s.height) / 2).rounded(), width: s.width, height: s.height)
                    x += s.width + How.px(10)
                }
            }
            if let c = corner {
                let s = c is KeyChip ? c.fittingSize : c.intrinsicContentSize
                let right = c is KeyChip ? How.px(16) : How.px(14)
                c.frame = NSRect(x: w - right - s.width, y: ((h - s.height) / 2).rounded(), width: s.width, height: s.height)
            }
            if let row = sent {
                let s = row.fittingSize
                row.frame = NSRect(x: padX, y: ((h - s.height) / 2).rounded(), width: s.width, height: s.height)
            }
            if let card = browser {
                let ch = card.fittingSize.height
                card.frame = NSRect(x: padX, y: ((h - ch) / 2).rounded(), width: w - padX * 2, height: ch)
            }
        case .terminal:
            termBack?.frame = bounds
            guard let line = line else { return }
            let lineH = line.contentHeight
            line.frame = NSRect(x: padX, y: ((h - lineH) / 2).rounded(), width: w - padX * 2, height: lineH)
        case .field:
            guard let row = keyRow, let field = field else { return }
            let topH = How.px(32)
            let fieldW = w - padX * 2
            let fieldH = max(How.px(66), field.height(for: fieldW))
            let total = topH + How.px(10) + fieldH
            let y = ((h - total) / 2).rounded()
            row.frame = NSRect(x: padX, y: y, width: fieldW, height: topH)
            var x: CGFloat = 0
            for v in row.subviews where v !== bubble {
                let s = v is KeyChip ? v.fittingSize : v.intrinsicContentSize
                v.frame = NSRect(x: x, y: ((topH - s.height) / 2).rounded(), width: s.width, height: s.height)
                x += s.width + How.px(6)
            }
            if let b = bubble {
                let s = b.intrinsicContentSize
                b.frame = NSRect(x: x - How.px(6) + How.px(12), y: ((topH - s.height) / 2).rounded(), width: s.width, height: s.height)
            }
            field.frame = NSRect(x: padX, y: y + topH + How.px(10), width: fieldW, height: fieldH)
        }
    }

    // MARK: Pointing and clicking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) {
        hovering = true
        onHover(true)
    }
    override func mouseExited(with event: NSEvent) {
        hovering = false
        onHover(false)
    }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override var mouseDownCanMoveWindow: Bool { false }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Theme.surface.cgColor
        layer?.borderColor = Theme.hairline.cgColor
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    deinit { timers.forEach { $0.invalidate() } }
}

/// The tab "ask Claude" opens: the site's tile, name and address over its
/// composer, with what you said already in it.
private final class BrowserCard: NSView {
    let composer = DemoLine(.compose)
    private let bar = FlippedView()
    private let rule = ColorView(color: Theme.hairsoft)
    private let box = ComposeBox()
    private let fav: AppBadge
    private let name: Words
    private let url: DemoChip

    init(_ site: String, url address: String) {
        fav = AppBadge(site, side: 14)
        name = Words(site, How.sans(11.5), Theme.muted)
        url = DemoChip(address, symbol: "lock", .label)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = How.px(9)
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        for v in [fav, name, url] as [NSView] { bar.addSubview(v) }
        for v in [bar, rule, box] as [NSView] { addSubview(v) }
        box.addSubview(composer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    private var barH: CGFloat { How.px(26) }
    private var boxH: CGFloat { max(How.px(40), composer.contentHeight + How.px(8)) }
    override var fittingSize: NSSize { NSSize(width: 0, height: barH + 1 + How.px(8) * 2 + boxH) }
    override var intrinsicContentSize: NSSize { fittingSize }

    override func layout() {
        super.layout()
        let w = bounds.width
        bar.frame = NSRect(x: 0, y: 0, width: w, height: barH)
        var x = How.px(10)
        for v in [fav, name, url] as [NSView] {
            let s = v.intrinsicContentSize
            v.frame = NSRect(x: x, y: ((barH - s.height) / 2).rounded(), width: s.width, height: s.height)
            x += s.width + How.px(7)
        }
        rule.frame = NSRect(x: 0, y: barH, width: w, height: 1)
        box.frame = NSRect(x: How.px(10), y: barH + 1 + How.px(8), width: w - How.px(20), height: boxH)
        composer.frame = NSRect(x: How.px(10), y: ((boxH - composer.contentHeight) / 2).rounded(),
                                width: box.frame.width - How.px(20), height: composer.contentHeight)
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Theme.paper.cgColor
        layer?.borderColor = Theme.hairline.cgColor
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// The composer's rounded box.
private final class ComposeBox: NSView {
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = How.px(9)
        layer?.borderWidth = 1
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Theme.surface.cgColor
        layer?.borderColor = Theme.hairline.cgColor
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// Command mode's text box: the words in it, selected before the keys go
/// down — in the blue a Mac selects with, line by line — and rewritten when
/// they come up, landing in a wash.
private final class FieldText: NSView {
    private let label = NSTextField(wrappingLabelWithString: "")
    private let wash = NSView()
    private var text: String
    private var selected: CGFloat = 0

    init(_ text: String) {
        self.text = text
        super.init(frame: .zero)
        wantsLayer = true
        wash.wantsLayer = true
        wash.layer?.cornerRadius = How.px(4)
        addSubview(wash)
        label.isSelectable = false
        label.drawsBackground = false
        label.isBezeled = false
        label.wantsLayer = true
        addSubview(label)
        render()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func render() {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.24
        var a: [NSAttributedString.Key: Any] = [.font: How.sans(14.5), .foregroundColor: Theme.ink, .paragraphStyle: style]
        if selected > 0 { a[.backgroundColor] = How.selection(selected) }
        label.attributedStringValue = NSAttributedString(string: text, attributes: a)
        // New words can need new lines at the same overall height.
        needsLayout = true
    }

    func height(for width: CGFloat) -> CGFloat {
        ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)).height ?? 0)
    }

    func select(instant: Bool, owner: AnyObject) {
        Tween.run(instant ? 0 : 0.35, owner: owner) { [weak self] k in
            self?.selected = k
            self?.render()
        }
    }

    func rewrite(_ s: String, instant: Bool) {
        text = s
        selected = 0
        render()
        superview?.needsLayout = true
        guard !instant else { return }
        Anim.fade(label, to: 1, 0)
        label.alphaValue = 0
        Anim.fade(label, to: 1, 0.5)
        Anim.wash(wash.layer, Theme.navPick, 1.8, in: self)
    }

    override func layout() {
        super.layout()
        let h = height(for: bounds.width)
        label.frame = NSRect(x: 0, y: 0, width: bounds.width, height: h)
        wash.frame = NSRect(x: -How.px(4), y: 0, width: bounds.width + How.px(8), height: h)
    }
    override func viewDidChangeEffectiveAppearance() { render() }
}
