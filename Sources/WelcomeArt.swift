// The drawn pieces of the first-run window (Onboarding.swift): the website's
// hero on the right — its morning sky, tiles, the headline that finishes
// itself and the pill that says the phrase — the picture for each switch,
// the rows of the checklist, and the pill the entrance starts from.
//
// Designed in design/welcome-redesign.html; the numbers here are that page's
// CSS pixels through Theme.m, so the Text size setting scales them too.
import Cocoa
import CoreText

// MARK: - The website's display face

extension Theme {
    /// Bricolage Grotesque, the site's headline face, from the bundle.
    /// Registered for this process on first use; SF Pro stands in if the
    /// file is missing.
    private static let heroDescriptor: CTFontDescriptor? = {
        guard let url = Bundle.main.url(forResource: "BricolageGrotesque", withExtension: "ttf", subdirectory: "Fonts")
                ?? Bundle.main.url(forResource: "BricolageGrotesque", withExtension: "ttf") else { return nil }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        return (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])?.first
    }()

    /// The display face at a weight (400–800) and a mockup size. The optical
    /// size follows the point size, as the site's `font-optical-sizing: auto`.
    static func heroFont(_ size: CGFloat, _ weight: CGFloat = 500) -> NSFont {
        let pt = m(size)
        guard let d = heroDescriptor else {
            return .systemFont(ofSize: pt, weight: weight >= 600 ? .semibold : .medium)
        }
        func tag(_ s: String) -> NSNumber { NSNumber(value: s.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }) }
        let axes: [NSNumber: NSNumber] = [tag("wght"): NSNumber(value: Double(weight)),
                                          tag("opsz"): NSNumber(value: Double(min(96, max(12, pt))))]
        let v = CTFontDescriptorCreateCopyWithAttributes(d, [kCTFontVariationAttribute: axes] as CFDictionary)
        return CTFontCreateWithFontDescriptor(v, pt, nil) as NSFont
    }

    /// A line in the display face, tracked the way the site tracks it.
    static func hero(_ s: String, _ size: CGFloat, _ weight: CGFloat = 500,
                     _ color: NSColor = Theme.ink, tracking: CGFloat = -0.04) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        let font = heroFont(size, weight)
        f.font = font
        f.textColor = color
        f.attributedStringValue = NSAttributedString(string: s, attributes: [
            .font: font, .foregroundColor: color, .kern: font.pointSize * tracking,
        ])
        return f
    }

    /// Two-tone display text: `plain` in ink, then `em` in ember — the
    /// captions under each picture ("It listens *while you hold fn.*").
    static func caption(_ plain: String, _ em: String, _ size: CGFloat = 24) -> NSTextField {
        // A paragraph field, so it wraps; the text is replaced below.
        let f = para("", size, .regular, Theme.ink, lineHeight: 1.05, align: .center)
        f.preferredMaxLayoutWidth = m(340)
        let font = heroFont(size, 500)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineHeightMultiple = 1.05
        let s = NSMutableAttributedString(string: plain, attributes: [
            .font: font, .foregroundColor: Theme.ink, .kern: font.pointSize * -0.035, .paragraphStyle: style])
        s.append(NSAttributedString(string: em, attributes: [
            .font: font, .foregroundColor: Theme.ember, .kern: font.pointSize * -0.035, .paragraphStyle: style]))
        f.attributedStringValue = s
        return f
    }
}

// MARK: - The sky

/// The site's hero backdrop: a blue glow falling from the top edge over a
/// pale sky, and a grid of soft tiles fading out from the top middle. The
/// tile shades are the site's fixed table, so it is the same grid.
final class SkyView: NSView {
    /// Each fades in on its own in the entrance.
    var glowAlpha: CGFloat = 1 { didSet { needsDisplay = true } }
    var tileAlpha: CGFloat = 1 { didSet { needsDisplay = true } }

    private static let shades: [Int] = [
        0, 3, 1, 0, 2, 0, 0, 3, 0, 1, 0, 2, 0, 1, 0, 0, 2, 0, 3, 1, 0, 0, 2, 0, 0, 3,
        0, 2, 0, 0, 3, 0, 0, 1, 0, 0, 3, 0, 1, 3, 0, 1, 0, 0, 2, 0, 0, 2, 0, 1, 0, 0,
        1, 0, 3, 0, 0, 1, 0, 0, 3, 0, 0,
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(10)
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    private var dark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        let d = dark
        (d ? Theme.hex(0x0D1220) : Theme.hex(0xEEF2FB)).setFill()
        b.fill()

        if glowAlpha > 0 {
            let g1 = d ? NSColor(srgbRed: 96/255, green: 138/255, blue: 240/255, alpha: 0.30)
                       : NSColor(srgbRed: 122/255, green: 168/255, blue: 255/255, alpha: 0.50)
            let g2 = d ? NSColor(srgbRed: 64/255, green: 100/255, blue: 200/255, alpha: 0.18)
                       : NSColor(srgbRed: 168/255, green: 198/255, blue: 255/255, alpha: 0.40)
            let g3 = d ? NSColor(srgbRed: 22/255, green: 38/255, blue: 88/255, alpha: 0.32)
                       : NSColor(srgbRed: 226/255, green: 236/255, blue: 255/255, alpha: 0.80)
            let a = glowAlpha
            NSGradient(colorsAndLocations: (g3.withAlphaComponent(g3.alphaComponent * a), 0),
                       (g3.withAlphaComponent(0), 0.8))?.draw(in: b, angle: 90)
            ellipse(NSPoint(x: b.midX, y: 0), rx: b.width * 0.6, ry: b.height * 0.5, g1, a)
            ellipse(NSPoint(x: b.width * 0.1, y: 0), rx: b.width * 0.45, ry: b.height * 0.4, g2, a)
            ellipse(NSPoint(x: b.width * 0.9, y: 0), rx: b.width * 0.45, ry: b.height * 0.4, g2, a)
        }

        guard tileAlpha > 0 else { return }
        let side = Theme.m(88), cols = 9, rows = 7
        let x0 = b.midX - CGFloat(cols) * side / 2
        let gridW = CGFloat(cols) * side, gridH = CGFloat(rows) * side
        let line = d ? NSColor.white.withAlphaComponent(0.035) : NSColor.white.withAlphaComponent(0.35)
        let fill = d ? NSColor.white.withAlphaComponent(0.04) : NSColor.white.withAlphaComponent(0.5)
        for r in 0..<rows {
            for c in 0..<cols {
                let rect = NSRect(x: x0 + CGFloat(c) * side, y: CGFloat(r) * side, width: side, height: side)
                // The site's mask: radial, 60% × 75% of the grid at its top
                // middle, solid to 25%, gone by 85%.
                let dx = (rect.midX - b.midX) / (gridW * 0.6), dy = rect.midY / (gridH * 0.75)
                let dist = sqrt(dx * dx + dy * dy)
                let k = max(0, min(1, 1 - (dist - 0.25) / 0.6)) * tileAlpha
                guard k > 0 else { continue }
                if Self.shades[(r * cols + c) % Self.shades.count] >= 2 {
                    fill.withAlphaComponent(fill.alphaComponent * k).setFill()
                    rect.fill()
                }
                line.withAlphaComponent(line.alphaComponent * k).setFill()
                NSRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: side).fill()
                NSRect(x: rect.minX, y: rect.maxY - 1, width: side, height: 1).fill()
            }
        }
    }

    private func ellipse(_ c: NSPoint, rx: CGFloat, ry: CGFloat, _ color: NSColor, _ a: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: c.x, yBy: c.y)
        t.scaleX(by: 1, yBy: ry / rx)
        t.concat()
        NSGradient(colorsAndLocations: (color.withAlphaComponent(color.alphaComponent * a), 0),
                   (color.withAlphaComponent(0), 0.72))?
            .draw(fromCenter: .zero, radius: 0, toCenter: .zero, radius: rx, options: [])
        NSGraphicsContext.restoreGraphicsState()
    }

    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: - The pill's bars

/// Eleven bars as the dictation pill draws them (the site's DictationPill):
/// rippling while it listens, lying low when it has stopped.
final class PillBars: NSView {
    enum Mode { case ripple, still }
    static let heights: [CGFloat] = [0.45, 0.75, 1, 0.62, 0.88, 0.5, 0.72, 0.95, 0.55, 0.8, 0.42]
    private var bars: [CALayer] = []
    var color: NSColor = Theme.hex(0xECE8DF) { didSet { bars.forEach { $0.backgroundColor = color.cgColor } } }
    var mode: Mode = .ripple { didSet { if mode != oldValue { apply() } } }

    init(height: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        let w = Theme.m(2.5), gap = Theme.m(3)
        let total = CGFloat(Self.heights.count) * w + CGFloat(Self.heights.count - 1) * gap
        widthAnchor.constraint(equalToConstant: total).isActive = true
        heightAnchor.constraint(equalToConstant: height).isActive = true
        for (i, h) in Self.heights.enumerated() {
            let l = CALayer()
            l.backgroundColor = color.cgColor
            l.cornerRadius = w / 2
            l.opacity = Float(0.22 + 0.62 * h)
            l.frame = NSRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: height * h)
            layer?.addSublayer(l)
            bars.append(l)
        }
        apply()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = Theme.m(2.5), gap = Theme.m(3)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, l) in bars.enumerated() {
            let h = bounds.height * Self.heights[i]
            l.bounds = NSRect(x: 0, y: 0, width: w, height: h)
            l.position = NSPoint(x: CGFloat(i) * (w + gap) + w / 2, y: bounds.midY)
        }
        CATransaction.commit()
    }

    private func apply() {
        for (i, l) in bars.enumerated() {
            l.removeAnimation(forKey: "ripple")
            switch mode {
            case .ripple:
                l.transform = CATransform3DIdentity
                guard !Motion.reduced else { continue }
                let a = CABasicAnimation(keyPath: "transform.scale.y")
                a.fromValue = 0.42
                a.toValue = 1
                a.duration = 0.85
                a.autoreverses = true
                a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                a.beginTime = CACurrentMediaTime() + Double(i) * 0.07
                a.fillMode = .backwards
                l.add(a, forKey: "ripple")
            case .still:
                l.transform = CATransform3DMakeScale(1, 0.3, 1)
            }
        }
    }

}

// MARK: - The dark pill

/// The dictation pill as the site draws it: dark glass whatever the
/// appearance, bars and a line of words.
final class DarkPill: NSView {
    let bars: PillBars
    let label: NSTextField

    init(_ text: String, size: CGFloat = 12.5, height: CGFloat = 34) {
        bars = PillBars(height: Theme.m(16))
        label = Theme.text(text, size, .medium, Theme.hex(0xECE8DF))
        label.font = .systemFont(ofSize: Theme.m(size), weight: .medium)
        label.textColor = Theme.hex(0xECE8DF)
        label.lineBreakMode = .byClipping
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(height) / 2
        layer?.backgroundColor = NSColor(srgbRed: 28/255, green: 26/255, blue: 22/255, alpha: 0.94).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.07).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = Theme.m(16)
        layer?.shadowOffset = CGSize(width: 0, height: -Theme.m(8))
        let row = Theme.hstack([bars, label], spacing: Theme.m(10))
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(14)),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.m(15)),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Theme.m(height)),
        ])
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Pops in from small and below, the way the site's balloon does.
    func popIn(delay: TimeInterval = 0) {
        guard let l = layer, !Motion.reduced else { return }
        let begin = CACurrentMediaTime() + delay
        let s = CASpringAnimation(keyPath: "transform.scale")
        s.fromValue = 0.5
        s.toValue = 1
        s.stiffness = 520
        s.damping = 20
        s.duration = s.settlingDuration
        let o = CABasicAnimation(keyPath: "opacity")
        o.fromValue = 0
        o.toValue = 1
        o.duration = 0.18
        for a in [s, o] as [CAAnimation] { a.beginTime = begin; a.fillMode = .backwards }
        anchorBottomCentre()
        l.add(s, forKey: "pop.scale")
        l.add(o, forKey: "pop.fade")
    }

    /// Floats up and away, then removes itself.
    func floatOff() {
        guard let l = layer, !Motion.reduced else { removeFromSuperview(); return }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.removeFromSuperview() }
        let up = CABasicAnimation(keyPath: "transform.translation.y")
        up.toValue = (superview?.isFlipped ?? false) ? -Theme.m(40) : Theme.m(40)
        let o = CABasicAnimation(keyPath: "opacity")
        o.toValue = 0
        for a in [up, o] {
            a.duration = 0.9
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            a.fillMode = .forwards
            a.isRemovedOnCompletion = false
            l.add(a, forKey: nil)
        }
        CATransaction.commit()
    }

    /// Scale from the bottom middle, so it grows up out of the line.
    private func anchorBottomCentre() {
        guard let l = layer else { return }
        let f = l.frame
        l.anchorPoint = CGPoint(x: 0.5, y: 0)
        l.position = CGPoint(x: f.midX, y: f.minY)
    }
}

// MARK: - The headline

/// The site's hero headline: "Dictation that" and a second line that the
/// pill above keeps finishing — a phrase is said, the line says what it did.
/// Every phrase is verbatim from SayCtrl-Web's hero-headline.tsx (the app's
/// real grammar), and the cycle ends on the plain claim.
final class HeroHeadline: NSView {
    private struct Step { let say: String?; let does: String }
    private static let steps: [Step] = [
        Step(say: "take a screenshot", does: "takes the screenshot."),
        Step(say: "attach the PDF from downloads", does: "attaches the PDF."),
        Step(say: "copy the file path", does: "pastes the file path."),
        Step(say: "my email address", does: "types your email."),
        Step(say: "so um, we should, uh, ship it", does: "drops the ums."),
        Step(say: "polish it", does: "polishes your draft."),
        Step(say: "send it", does: "hits send."),
        Step(say: nil, does: "does what you say."),
    ]
    static let home = "does what you say."

    let balloonSlot = NSView()
    let lineOne = Theme.hero("Dictation that", 42, 500, Theme.ink, tracking: -0.045)
    let phrase = PhraseLine(size: 42)
    let sub = Theme.para("Hold fn, talk, let go. Your words land in any Mac app, and commands happen where you said them.",
                         14 * 1.25, .regular, Theme.ink2, lineHeight: 1.45, align: .center)
    private var timers: [Timer] = []
    private var index = -1

    init() {
        super.init(frame: .zero)
        for v in [balloonSlot, lineOne, phrase, sub] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        sub.font = .systemFont(ofSize: Theme.m(14))
        NSLayoutConstraint.activate([
            balloonSlot.topAnchor.constraint(equalTo: topAnchor),
            balloonSlot.centerXAnchor.constraint(equalTo: centerXAnchor),
            balloonSlot.heightAnchor.constraint(equalToConstant: Theme.m(44)),
            balloonSlot.widthAnchor.constraint(equalTo: widthAnchor),
            lineOne.topAnchor.constraint(equalTo: balloonSlot.bottomAnchor, constant: Theme.m(10)),
            lineOne.centerXAnchor.constraint(equalTo: centerXAnchor),
            phrase.topAnchor.constraint(equalTo: lineOne.bottomAnchor, constant: -Theme.m(4)),
            phrase.leadingAnchor.constraint(equalTo: leadingAnchor),
            phrase.trailingAnchor.constraint(equalTo: trailingAnchor),
            sub.topAnchor.constraint(equalTo: phrase.bottomAnchor, constant: Theme.m(16)),
            sub.centerXAnchor.constraint(equalTo: centerXAnchor),
            {
                let w = sub.widthAnchor.constraint(equalToConstant: Theme.m(380))
                w.priority = .defaultHigh
                return w
            }(),
            sub.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
            sub.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        phrase.set(Self.home, animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    /// The pieces in reading order, for an entrance.
    var pieces: [NSView] { [lineOne, phrase, sub] }

    func start(after delay: TimeInterval) {
        stop()
        guard !Motion.reduced else { return }
        later(delay) { [weak self] in self?.tick() }
    }

    func stop() {
        timers.forEach { $0.invalidate() }
        timers = []
        index = -1
        balloonSlot.subviews.forEach { $0.removeFromSuperview() }
    }

    private func later(_ t: TimeInterval, _ fn: @escaping () -> Void) {
        let timer = Timer(timeInterval: t, repeats: false) { _ in fn() }
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
    }

    private func tick() {
        index = (index + 1) % Self.steps.count
        let s = Self.steps[index]
        balloonSlot.subviews.forEach { $0.removeFromSuperview() }
        if let say = s.say {
            let pill = DarkPill("“\(say)”")
            pill.translatesAutoresizingMaskIntoConstraints = false
            balloonSlot.addSubview(pill)
            NSLayoutConstraint.activate([
                pill.centerXAnchor.constraint(equalTo: balloonSlot.centerXAnchor),
                pill.bottomAnchor.constraint(equalTo: balloonSlot.bottomAnchor),
            ])
            balloonSlot.layoutSubtreeIfNeeded()
            pill.popIn()
            later(0.52) { [weak self] in self?.phrase.set(s.does, animated: true) }
            later(1.9) { [weak pill] in pill?.floatOff() }
            later(2.6) { [weak self] in self?.tick() }
        } else {
            phrase.set(s.does, animated: true)
            later(4.2) { [weak self] in self?.tick() }
        }
    }
}

/// The ember second line, word by word: each word rises into place, the
/// old ones drift off first.
final class PhraseLine: NSView {
    private let size: CGFloat
    private var words: [NSTextField] = []
    private var generation = 0

    init(size: CGFloat) {
        self.size = size
        super.init(frame: .zero)
        wantsLayer = true
        heightAnchor.constraint(equalToConstant: Theme.m(size) * 1.18).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }

    func set(_ text: String, animated: Bool) {
        generation += 1
        let gen = generation
        let old = words
        let build = { [weak self] in
            guard let self = self, gen == self.generation else { return }
            old.forEach { $0.removeFromSuperview() }
            self.words = text.split(separator: " ").map {
                let w = Theme.hero(String($0), self.size, 500, Theme.ember, tracking: -0.045)
                w.lineBreakMode = .byClipping
                return w
            }
            self.words.forEach { self.addSubview($0) }
            self.needsLayout = true
            self.layoutSubtreeIfNeeded()
            guard animated else { return }
            for (i, w) in self.words.enumerated() {
                Motion.rise(w, delay: Double(i) * 0.055, duration: 0.5, distance: Theme.m(self.size) * 0.4)
            }
        }
        guard animated, !old.isEmpty, !Motion.reduced else { return build() }
        for (i, w) in old.enumerated() {
            Motion.leave(w, delay: Double(i) * 0.03, duration: 0.28, lift: Theme.m(size) * 0.35)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: build)
    }

    override func layout() {
        super.layout()
        let gap = Theme.m(size) * 0.24
        // Measured from the text itself: the tight tracking shaves the
        // field's own measure and it would clip the last letter.
        let sizes = words.map { w -> NSSize in
            let t = w.attributedStringValue.size()
            return NSSize(width: ceil(t.width), height: ceil(t.height) + 2)
        }
        let total = sizes.reduce(0) { $0 + $1.width } + gap * CGFloat(max(0, words.count - 1))
        var x = (bounds.width - total) / 2
        // The field draws its text 2 pt in from each side of its frame, and
        // the last letter overhangs its tracked advance: the frame gets room
        // for both, the spacing is still measured from the text.
        let inset: CGFloat = 2, spare = Theme.m(10)
        for (w, s) in zip(words, sizes) {
            w.frame = NSRect(x: x - inset, y: (bounds.height - s.height) / 2, width: s.width + inset + spare, height: s.height)
            x += s.width + gap
        }
    }
}

// MARK: - The pictures

/// A picture, a two-tone caption and a line under it, centred on the sky.
final class Illustration: NSView {
    let art: NSView
    let cap: NSTextField
    let small: NSTextField
    private let extra: NSView?

    init(art: NSView, plain: String, em: String, small text: String, extra: NSView? = nil) {
        self.art = art
        self.extra = extra
        // The coloured phrase is one piece: it goes to the next line whole
        // rather than leaving its last word there on its own.
        cap = Theme.caption(plain, em.replacingOccurrences(of: " ", with: "\u{00A0}"))
        small = Theme.para(text, 13 * 1.25, .regular, Theme.ink2, lineHeight: 1.45, align: .center)
        small.font = .systemFont(ofSize: Theme.m(13))
        super.init(frame: .zero)
        var views: [NSView] = [art, cap, small]
        if let e = extra { views.append(e) }
        let stack = Theme.vstack(views, spacing: Theme.m(12))
        stack.alignment = .centerX
        stack.setCustomSpacing(Theme.m(26), after: art)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
            // Fixed widths: a wrapping label left to find its own width in a
            // centred stack measures itself at its last width and narrows.
            cap.widthAnchor.constraint(equalToConstant: Theme.m(360)),
            small.widthAnchor.constraint(equalToConstant: Theme.m(320)),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    var pieces: [NSView] { [art, cap, small] + (extra.map { [$0] } ?? []) }

}

/// A note in an editor, the words landing at the caret — Accessibility.
final class TypingArt: NSView {
    private let typed = NSTextField(labelWithString: "")
    private let caret = ColorView(color: Theme.hex(0x2C5FD4))
    private var timer: Timer?
    private static let line = "Meet at noon, and bring the deck."

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(12)
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.14
        layer?.shadowRadius = Theme.m(18)
        layer?.shadowOffset = CGSize(width: 0, height: -Theme.m(10))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Theme.m(290)).isActive = true

        let dots = Theme.hstack((0..<3).map { _ in
            let d = ColorView(color: Theme.hairline)
            d.wantsLayer = true
            d.layer?.cornerRadius = Theme.m(4)
            d.widthAnchor.constraint(equalToConstant: Theme.m(8)).isActive = true
            d.heightAnchor.constraint(equalToConstant: Theme.m(8)).isActive = true
            return d
        }, spacing: Theme.m(6))
        let rule = ColorView(color: Theme.hairline)
        let title = Theme.text("Notes for Thursday", 12.5 * 1.25, .semibold, Theme.muted)
        title.font = .systemFont(ofSize: Theme.m(12.5), weight: .semibold)
        typed.font = .systemFont(ofSize: Theme.m(14))
        typed.textColor = Theme.ink
        caret.wantsLayer = true
        for v in [dots, rule, title, typed, caret] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            dots.topAnchor.constraint(equalTo: topAnchor, constant: Theme.m(8)),
            dots.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(10)),
            rule.topAnchor.constraint(equalTo: topAnchor, constant: Theme.m(24)),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            title.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: Theme.m(14)),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(16)),
            typed.topAnchor.constraint(equalTo: title.bottomAnchor, constant: Theme.m(4)),
            typed.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            typed.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Theme.m(20)),
            caret.leadingAnchor.constraint(equalTo: typed.trailingAnchor, constant: 1),
            caret.centerYAnchor.constraint(equalTo: typed.centerYAnchor),
            caret.widthAnchor.constraint(equalToConstant: 1.5),
            caret.heightAnchor.constraint(equalToConstant: Theme.m(17)),
            bottomAnchor.constraint(equalTo: typed.bottomAnchor, constant: Theme.m(22)),
        ])
        let blink = CABasicAnimation(keyPath: "opacity")
        blink.fromValue = 1
        blink.toValue = 0
        blink.duration = 0.5
        blink.autoreverses = true
        blink.repeatCount = .infinity
        blink.timingFunction = CAMediaTimingFunction(name: .easeIn)
        if !Motion.reduced { caret.layer?.add(blink, forKey: "blink") }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Theme.surface.cgColor }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        guard window != nil else { return }
        if Motion.reduced { typed.stringValue = Self.line; return }
        var n = 0, hold = 0
        let t = Timer(timeInterval: 0.042, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if n < Self.line.count {
                n += 1
                self.typed.stringValue = String(Self.line.prefix(n))
            } else if hold < 43 {   // about 1.8 s, then again
                hold += 1
            } else {
                n = 0; hold = 0
                self.typed.stringValue = ""
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}

/// The fn key, pressed now and then — and for real, when fn is. For Input
/// Monitoring the pill comes up while it is held; for the Globe key the
/// emoji picker pops up on a tap, until the key is set to Do Nothing.
final class KeyArt: NSView {
    enum Kind { case input, globe }
    private let kind: Kind
    private let key = NSView()
    private let ring = NSView()
    private let badge = NSView()
    private let pill = DarkPill("Listening…", size: 12)
    private let picker = NSView()
    private var timer: Timer?
    private var lastReal = Date.distantPast
    /// The switch is on: the key gets a tick, and the Globe key stays quiet.
    var ok = false { didSet { badge.isHidden = !ok; if ok && !oldValue { Motion.rise(badge, duration: 0.45, distance: 0, scale: 0.3) } } }

    init(_ kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Theme.m(240)).isActive = true
        heightAnchor.constraint(equalToConstant: Theme.m(178)).isActive = true

        let side = Theme.m(92)
        key.wantsLayer = true
        key.layer?.cornerRadius = Theme.m(16)
        key.layer?.shadowColor = NSColor.black.cgColor
        key.layer?.shadowOpacity = 0.14
        key.layer?.shadowRadius = Theme.m(14)
        key.layer?.shadowOffset = CGSize(width: 0, height: -Theme.m(4))
        key.layer?.borderWidth = 1
        let fn = Theme.text("fn", 15 * 1.25, .medium, Theme.ink)
        fn.font = .systemFont(ofSize: Theme.m(15), weight: .medium)
        let globe = GlyphView(symbol: "globe", size: Theme.m(17), weight: .regular, side: Theme.m(20))
        globe.tint = Theme.ink
        ring.wantsLayer = true
        ring.layer?.cornerRadius = Theme.m(16)
        badge.wantsLayer = true
        badge.layer?.cornerRadius = Theme.m(12)
        badge.layer?.backgroundColor = Theme.moss.cgColor
        badge.isHidden = true
        let tick = GlyphView(symbol: "checkmark", size: Theme.m(11), weight: .bold, side: Theme.m(14))
        tick.tint = .white

        picker.wantsLayer = true
        picker.layer?.cornerRadius = Theme.m(10)
        picker.layer?.shadowColor = NSColor.black.cgColor
        picker.layer?.shadowOpacity = 0.16
        picker.layer?.shadowRadius = Theme.m(13)
        picker.layer?.shadowOffset = CGSize(width: 0, height: -Theme.m(8))
        picker.layer?.borderWidth = 1
        let emoji = ["😀", "🎉", "👍", "❤️", "😂", "🙏", "🔥", "✨"].map { e -> NSTextField in
            let f = NSTextField(labelWithString: e)
            f.font = .systemFont(ofSize: Theme.m(18))
            return f
        }
        let grid = NSGridView(views: [Array(emoji[0..<4]), Array(emoji[4..<8])])
        grid.rowSpacing = Theme.m(4)
        grid.columnSpacing = Theme.m(6)

        for v in [pill, picker, ring, key] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        for v in [fn, globe, badge] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            key.addSubview(v)
        }
        tick.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(tick)
        grid.translatesAutoresizingMaskIntoConstraints = false
        picker.addSubview(grid)
        NSLayoutConstraint.activate([
            key.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.m(4)),
            key.centerXAnchor.constraint(equalTo: centerXAnchor),
            key.widthAnchor.constraint(equalToConstant: side),
            key.heightAnchor.constraint(equalToConstant: side),
            ring.centerXAnchor.constraint(equalTo: key.centerXAnchor),
            ring.centerYAnchor.constraint(equalTo: key.centerYAnchor),
            ring.widthAnchor.constraint(equalToConstant: side),
            ring.heightAnchor.constraint(equalToConstant: side),
            fn.topAnchor.constraint(equalTo: key.topAnchor, constant: Theme.m(10)),
            fn.trailingAnchor.constraint(equalTo: key.trailingAnchor, constant: -Theme.m(13)),
            globe.leadingAnchor.constraint(equalTo: key.leadingAnchor, constant: Theme.m(12)),
            globe.bottomAnchor.constraint(equalTo: key.bottomAnchor, constant: -Theme.m(12)),
            badge.topAnchor.constraint(equalTo: key.topAnchor, constant: -Theme.m(8)),
            badge.trailingAnchor.constraint(equalTo: key.trailingAnchor, constant: Theme.m(8)),
            badge.widthAnchor.constraint(equalToConstant: Theme.m(24)),
            badge.heightAnchor.constraint(equalToConstant: Theme.m(24)),
            tick.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            tick.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            pill.topAnchor.constraint(equalTo: topAnchor),
            pill.centerXAnchor.constraint(equalTo: centerXAnchor),
            picker.topAnchor.constraint(equalTo: topAnchor),
            picker.centerXAnchor.constraint(equalTo: centerXAnchor),
            grid.topAnchor.constraint(equalTo: picker.topAnchor, constant: Theme.m(8)),
            grid.bottomAnchor.constraint(equalTo: picker.bottomAnchor, constant: -Theme.m(8)),
            grid.leadingAnchor.constraint(equalTo: picker.leadingAnchor, constant: Theme.m(9)),
            grid.trailingAnchor.constraint(equalTo: picker.trailingAnchor, constant: -Theme.m(9)),
        ])
        pill.isHidden = kind != .input
        picker.isHidden = true
        pill.alphaValue = 0
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        key.layer?.backgroundColor = Theme.surface.cgColor
        key.layer?.borderColor = Theme.hairline.cgColor
        picker.layer?.backgroundColor = Theme.surface.cgColor
        picker.layer?.borderColor = Theme.hairline.cgColor
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        guard window != nil, !Motion.reduced else { return }
        // Pressed now and then on its own, unless a real fn press is showing.
        let t = Timer(timeInterval: 2.2, repeats: true) { [weak self] _ in
            guard let self = self, Date().timeIntervalSince(self.lastReal) > 3 else { return }
            self.press(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + (self.kind == .input ? 1.1 : 0.25)) { self.press(false) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self = self, self.window != nil else { return }
            self.press(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + (self.kind == .input ? 1.1 : 0.25)) { self.press(false) }
        }
    }

    /// The real key: the picture follows it.
    func realPress(_ down: Bool) {
        lastReal = Date()
        press(down)
    }

    private func press(_ down: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.allowsImplicitAnimation = true
            key.layer?.transform = down ? CATransform3DMakeTranslation(0, -Theme.m(3), 0) : CATransform3DIdentity
            key.layer?.shadowRadius = down ? Theme.m(6) : Theme.m(14)
        }
        if down, !Motion.reduced {
            let r = CABasicAnimation(keyPath: "shadowOpacity")
            ring.layer?.shadowColor = Theme.ember.cgColor
            ring.layer?.shadowRadius = Theme.m(14)
            ring.layer?.shadowOffset = .zero
            ring.layer?.shadowPath = CGPath(roundedRect: ring.bounds, cornerWidth: Theme.m(16), cornerHeight: Theme.m(16), transform: nil)
            r.fromValue = 0.55
            r.toValue = 0
            r.duration = 0.9
            ring.layer?.add(r, forKey: "ring")
        }
        switch kind {
        case .input:
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                pill.animator().alphaValue = down ? 1 : 0
            }
        case .globe:
            let show = down && !ok
            if show {
                picker.isHidden = false
                Motion.rise(picker, duration: 0.18, distance: Theme.m(4))
            } else if !picker.isHidden {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) { [weak self] in self?.picker.isHidden = true }
            }
        }
    }
}

/// The mark, big, for the last picture and the Voice row.
final class MarkArt: NSView {
    private let side: CGFloat
    init(side: CGFloat = 72) {
        self.side = Theme.m(side)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: self.side).isActive = true
        heightAnchor.constraint(equalToConstant: self.side).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        Theme.drawMark(in: bounds, ink: Theme.ink, accent: Theme.ember)
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: - The checklist's rows

/// One switch: its coloured tile, its name and whether it is needed; when it
/// is the one being set up, a line of why and the one button that does it;
/// a green tick once it is on.
final class PermRow: NSView {
    enum State { case todo, current, done }

    let tile = NSView()
    let name: NSTextField
    let need: NSTextField
    let why: NSTextField
    let button: FlatButton
    private let tick = NSView()
    private let detail: NSStackView
    private(set) var state: State = .todo

    init(name title: String, need needText: String, symbol: String, tint: NSColor,
         why whyText: String, button buttonTitle: String, onClick: @escaping () -> Void) {
        name = Theme.text(title, 13.5 * 1.25, .semibold)
        name.font = .systemFont(ofSize: Theme.m(13.5), weight: .semibold)
        need = Theme.text(needText, 11 * 1.25, .regular, Theme.muted)
        need.font = .systemFont(ofSize: Theme.m(11))
        why = Theme.para(whyText, 12.5 * 1.25, .regular, Theme.ink2, lineHeight: 1.4)
        why.font = .systemFont(ofSize: Theme.m(12.5))
        button = FlatButton(buttonTitle, .primary, onClick: onClick)
        detail = Theme.vstack([why, button], spacing: Theme.m(10))
        detail.alignment = .leading
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(10)

        tile.wantsLayer = true
        tile.layer?.cornerRadius = Theme.m(8)
        tile.layer?.backgroundColor = tint.cgColor
        let glyph = GlyphView(symbol: symbol, size: Theme.m(14), weight: .semibold, side: Theme.m(18))
        glyph.tint = .white
        glyph.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(glyph)

        tick.wantsLayer = true
        tick.layer?.cornerRadius = Theme.m(10)
        tick.layer?.backgroundColor = Theme.moss.cgColor
        let check = GlyphView(symbol: "checkmark", size: Theme.m(10), weight: .bold, side: Theme.m(12))
        check.tint = .white
        check.translatesAutoresizingMaskIntoConstraints = false
        tick.addSubview(check)
        tick.isHidden = true

        let line = Theme.hstack([name, need], spacing: Theme.m(8))
        line.alignment = .firstBaseline
        let text = Theme.vstack([line, detail], spacing: Theme.m(4))
        text.alignment = .leading
        for v in [tile, text, tick] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let pad = Theme.m(9)
        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(10)),
            tile.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            tile.widthAnchor.constraint(equalToConstant: Theme.m(30)),
            tile.heightAnchor.constraint(equalToConstant: Theme.m(30)),
            glyph.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: Theme.m(12)),
            text.trailingAnchor.constraint(equalTo: tick.leadingAnchor, constant: -Theme.m(8)),
            text.topAnchor.constraint(equalTo: topAnchor, constant: pad + Theme.m(6)),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
            line.heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.m(18)),
            detail.widthAnchor.constraint(equalTo: text.widthAnchor),
            why.widthAnchor.constraint(equalTo: detail.widthAnchor),
            tick.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.m(10)),
            tick.topAnchor.constraint(equalTo: topAnchor, constant: pad + Theme.m(5)),
            tick.widthAnchor.constraint(equalToConstant: Theme.m(20)),
            tick.heightAnchor.constraint(equalToConstant: Theme.m(20)),
            check.centerXAnchor.constraint(equalTo: tick.centerXAnchor),
            check.centerYAnchor.constraint(equalTo: tick.centerYAnchor),
            bottomAnchor.constraint(greaterThanOrEqualTo: tile.bottomAnchor, constant: pad),
        ])
        name.setContentCompressionResistancePriority(.required, for: .horizontal)
        need.setContentCompressionResistancePriority(.required, for: .horizontal)
        detail.isHidden = true
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ new: State, animated: Bool) {
        guard new != state else { return }
        let was = state
        state = new
        let open = new == .current
        if animated, !Motion.reduced, detail.isHidden == open {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                ctx.timingFunction = Motion.ease
                ctx.allowsImplicitAnimation = true
                detail.isHidden = !open
                superview?.layoutSubtreeIfNeeded()
            }
            if open { Motion.rise(detail, delay: 0.08, duration: 0.35, distance: Theme.m(6)) }
        } else {
            detail.isHidden = !open
        }
        tick.isHidden = new != .done
        if new == .done, was != .done, animated {
            Motion.rise(tick, duration: 0.45, distance: 0, scale: 0.3)
        }
        restyle()
    }

    /// The line of why, as it stands now ("Turn SayControl on in the list…").
    func setWhy(_ text: String) {
        guard why.stringValue != text else { return }
        let attrs = why.attributedStringValue.length > 0
            ? why.attributedStringValue.attributes(at: 0, effectiveRange: nil) : [:]
        why.attributedStringValue = NSAttributedString(string: text, attributes: attrs)
    }

    private func restyle() {
        let todo = state == .todo
        tile.alphaValue = todo ? 0.5 : 1
        name.textColor = todo ? Theme.muted : Theme.ink
        name.font = .systemFont(ofSize: Theme.m(13.5), weight: todo ? .medium : .semibold)
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = state == .current
            ? Theme.dyn(Theme.hex(0x17150F, 0.045), NSColor.white.withAlphaComponent(0.05)).cgColor
            : NSColor.clear.cgColor
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: - The entrance pill

/// The pill that opens the very first launch, on its own over the desktop:
/// it listens, hears "Welcome to SayControl", then opens into the window.
final class IntroPill {
    private(set) var panel: NSPanel?
    let pill = DarkPill("", size: 14, height: 40)

    func show(centeredOn p: NSPoint) {
        let size = NSSize(width: Theme.m(420), height: Theme.m(120))
        let panel = NSPanel(contentRect: NSRect(x: p.x - size.width / 2, y: p.y - size.height / 2,
                                                width: size.width, height: size.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSView(frame: NSRect(origin: .zero, size: size))
        host.wantsLayer = true
        panel.contentView = host
        pill.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(pill)
        NSLayoutConstraint.activate([
            pill.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            pill.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
        pill.label.stringValue = ""
        host.layoutSubtreeIfNeeded()
        panel.orderFrontRegardless()
        self.panel = panel
        guard let l = pill.layer else { return }
        let f = l.frame
        l.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        l.position = CGPoint(x: f.midX, y: f.midY)
        let s = CABasicAnimation(keyPath: "transform.scale")
        s.fromValue = 0.6
        s.toValue = 1
        s.duration = 0.42
        s.timingFunction = Motion.pop
        let o = CABasicAnimation(keyPath: "opacity")
        o.fromValue = 0
        o.toValue = 1
        o.duration = 0.2
        l.add(s, forKey: nil)
        l.add(o, forKey: nil)
    }

    /// The next word lands; the pill widens to take it.
    func add(word: String) {
        let text = pill.label.stringValue.isEmpty ? word : pill.label.stringValue + " " + word
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.26
            ctx.timingFunction = Motion.ease
            ctx.allowsImplicitAnimation = true
            pill.label.stringValue = text
            pill.superview?.layoutSubtreeIfNeeded()
        }
    }

    /// The pill in screen coordinates, for the window to open out of.
    var screenRect: NSRect? {
        guard let panel = panel else { return nil }
        return panel.convertToScreen(pill.convert(pill.bounds, to: nil))
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}
