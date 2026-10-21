// Pictures for the panes: the hero banner at the top of a page, the tinted
// icon tile beside a row, and an SF Symbol drawn at its own size.
import Cocoa

// MARK: - Glyph

/// An SF Symbol drawn at its natural size, centred, in its tint — never
/// scaled. NSImageView scales a symbol to whatever frame layout hands it:
/// the sidebar's gear came out squashed, and a fold caught the icons
/// mid-animation at a few points across and left them there, tiny. This
/// view only ever paints the glyph at the point size it was made with, and
/// its layer never stretches old pixels while its frame moves.
final class GlyphView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var tint: NSColor = Theme.muted { didSet { needsDisplay = true } }

    init(_ image: NSImage?, side: CGFloat) {
        self.image = image
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layerContentsPlacement = .center
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    convenience init(symbol: String, size: CGFloat, weight: NSFont.Weight = .regular, side: CGFloat) {
        self.init(Theme.symbol(symbol, size, weight), side: side)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Decoration: the row or button it sits in takes the click.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let img = image else { return }
        let size = img.size
        let r = backingAlignedRect(
            NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                   width: size.width, height: size.height),
            options: [.alignMinXNearest, .alignMinYNearest, .alignWidthNearest, .alignHeightNearest])
        let tint = self.tint
        NSImage(size: size, flipped: false) { rect in
            img.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }.draw(in: r)
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: - Icon tile

/// A symbol on a soft coloured square — the picture beside a Settings row,
/// a permission, a privacy promise. The hue is a category, never a state:
/// state stays with the chips (moss, amber, ember).
final class IconTile: NSView {
    private let glyph: GlyphView
    var hue: Theme.Hue { didSet { glyph.tint = hue.ink; needsDisplay = true } }

    /// `side` and `icon` are mockup pixels (Theme.m).
    init(_ symbol: String, _ hue: Theme.Hue, side: CGFloat = 30, icon: CGFloat = 14) {
        self.hue = hue
        let s = Theme.m(side)
        glyph = GlyphView(symbol: symbol, size: Theme.m(icon), weight: .medium, side: s)
        glyph.tint = hue.ink
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = (s * 0.28).rounded()
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: s),
            heightAnchor.constraint(equalToConstant: s),
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setSymbol(_ symbol: String, icon: CGFloat = 14) {
        glyph.image = Theme.symbol(symbol, Theme.m(icon), .medium)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = hue.wash.cgColor }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: - Hero banner

/// The picture at the top of a page: a warm dark panel lit by an ember glow,
/// a New York headline, a line of explanation, up to two actions, and art on
/// the right — the apps it works in, or a small drawing of the idea. It is
/// the same in light and dark mode: a photograph-like panel, not a surface.
final class HeroBanner: NSView {
    enum Art {
        /// App icons in frosted circles, by bundle id; the installed ones,
        /// in the order given.
        case apps([String])
        /// Anything else, centred in the right-hand part.
        case view(NSView)
    }

    /// The panel's own palette — fixed, like the pill's.
    static let cream     = Theme.hex(0xF6F1EA)
    static let creamSoft = Theme.hex(0xF6F1EA, 0.74)
    /// Dark words on something cream — a filled button, a picked chip.
    static let ink       = Theme.hex(0x1C1B19)
    private static let deep  = Theme.hex(0x1D1510)
    private static let mid   = Theme.hex(0x33211A)
    private static let warm  = Theme.hex(0x5A2C18)

    private let artHost = NSView()
    private var subField: NSTextField?

    /// Replaces the line under the headline — a page whose line names a
    /// setting (the dictation key) keeps it current.
    func setSubtitle(_ text: String) {
        guard let f = subField, f.stringValue != text else { return }
        let attrs = f.attributedStringValue.length > 0
            ? f.attributedStringValue.attributes(at: 0, effectiveRange: nil) : [:]
        f.attributedStringValue = NSAttributedString(string: text, attributes: attrs)
    }

    init(title: String, subtitle: String,
         primary: (title: String, run: () -> Void)? = nil,
         secondary: (title: String, run: () -> Void)? = nil,
         art: Art, height: CGFloat = 156,
         lineWidth: CGFloat = 400, maxLineWidth: CGFloat = 470) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(16)
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Theme.m(height)).isActive = true

        let head = Theme.figure(title, 25, Self.cream)
        let sub = Theme.para(subtitle, 13, .regular, Self.creamSoft, lineHeight: 1.3)
        sub.font = .systemFont(ofSize: Theme.m(13))
        sub.attributedStringValue = NSAttributedString(string: subtitle, attributes: [
            .font: NSFont.systemFont(ofSize: Theme.m(13)), .foregroundColor: Self.creamSoft,
            .paragraphStyle: { let p = NSMutableParagraphStyle(); p.lineHeightMultiple = 1.3; return p }(),
        ])
        subField = sub
        var buttons: [NSView] = []
        if let p = primary { buttons.append(HeroButton(p.title, filled: true, run: p.run)) }
        if let s = secondary { buttons.append(HeroButton(s.title, filled: false, run: s.run)) }

        let text = NSStackView(views: [head, sub])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Theme.m(6)
        if !buttons.isEmpty {
            let row = Theme.hstack(buttons, spacing: Theme.m(6))
            text.addArrangedSubview(row)
            text.setCustomSpacing(Theme.m(16), after: sub)
        }
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)

        artHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(artHost, positioned: .below, relativeTo: text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(30)),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.58),
            sub.widthAnchor.constraint(lessThanOrEqualToConstant: Theme.m(maxLineWidth)),
            // The line claims its own width rather than wrapping to the
            // headline's, which left it three lines tall under a short title.
            // Below the window's stay-put priority: a wish, never a reason
            // for the window to grow.
            { let c = sub.widthAnchor.constraint(equalToConstant: Theme.m(lineWidth))
              c.priority = .init(450); return c }(),

            artHost.topAnchor.constraint(equalTo: topAnchor),
            artHost.bottomAnchor.constraint(equalTo: bottomAnchor),
            artHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            artHost.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.42),
        ])

        switch art {
        case .apps(let ids): placeApps(ids)
        case .view(let v):
            v.translatesAutoresizingMaskIntoConstraints = false
            artHost.addSubview(v)
            NSLayoutConstraint.activate([
                v.centerXAnchor.constraint(equalTo: artHost.centerXAnchor),
                v.centerYAnchor.constraint(equalTo: artHost.centerYAnchor),
            ])
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Slots on the art's own grid (fractions of its width and height), and
    /// a scale each — some run off the edges, so the cluster reads as a
    /// glimpse of many apps rather than a row of five.
    private static let slots: [(x: CGFloat, y: CGFloat, s: CGFloat)] = [
        (0.24, 0.30, 1.00), (0.50, 0.30, 1.00), (0.76, 0.30, 1.00),
        (0.37, 0.72, 1.00), (0.63, 0.72, 1.00), (0.11, 0.72, 0.94),
        (0.89, 0.72, 0.94), (1.00, 0.30, 0.90),
    ]

    /// Apps people dictate into, most familiar first. Only installed ones
    /// are drawn; the page never shows an app you don't have.
    static let everyday = [
        "com.tinyspeck.slackmacgap", "com.apple.mail", "com.apple.Notes",
        "com.apple.MobileSMS", "com.google.Chrome", "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92", "com.anthropic.claudefordesktop",
        "com.apple.Terminal", "notion.id", "com.linear", "com.apple.Safari",
        "com.openai.chat", "com.figma.Desktop", "com.apple.Pages",
    ]

    private func placeApps(_ ids: [String]) {
        var icons: [NSImage] = []
        for id in ids {
            guard icons.count < Self.slots.count,
                  let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
            icons.append(NSWorkspace.shared.icon(forFile: url.path))
        }
        for (i, icon) in icons.enumerated() {
            let slot = Self.slots[i]
            let d = (Theme.m(48) * slot.s).rounded()
            let bubble = AppBubble(icon, diameter: d)
            artHost.addSubview(bubble)
            NSLayoutConstraint.activate([
                NSLayoutConstraint(item: bubble, attribute: .centerX, relatedBy: .equal,
                                   toItem: artHost, attribute: .trailing, multiplier: max(0.01, slot.x), constant: 0),
                NSLayoutConstraint(item: bubble, attribute: .centerY, relatedBy: .equal,
                                   toItem: artHost, attribute: .bottom, multiplier: max(0.01, slot.y), constant: 0),
            ])
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        NSGradient(colors: [Self.deep, Self.mid, Self.warm], atLocations: [0, 0.55, 1],
                   colorSpace: .sRGB)?.draw(in: b, angle: 0)
        // The glow: ember, low and to the right, where the art sits.
        let glow = NSGradient(starting: Theme.hex(0xE5501F, 0.42), ending: Theme.hex(0xE5501F, 0))
        let c = NSPoint(x: b.maxX - b.width * 0.22, y: b.minY + b.height * 0.2)
        glow?.draw(fromCenter: c, radius: 0, toCenter: c, radius: b.height * 1.25, options: [])
        // A cool lift along the top edge, so the panel reads lit from above.
        NSGradient(starting: NSColor.white.withAlphaComponent(0.06), ending: .clear)?
            .draw(in: NSRect(x: b.minX, y: b.maxY - b.height * 0.5, width: b.width, height: b.height * 0.5), angle: -90)
        let edge = NSBezierPath(roundedRect: b.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: Theme.m(16) - 0.5, yRadius: Theme.m(16) - 0.5)
        edge.lineWidth = 1
        NSColor.white.withAlphaComponent(0.07).setStroke()
        edge.stroke()
    }
}

// MARK: - Hero sketches

/// A small drawing of a pane's idea, for the right-hand side of its
/// HeroBanner. The banner is a dark panel in either appearance, so the
/// sketch draws as dark too, in the banner's palette: frosted white for the
/// words you say, cream for what lands, and a touch of ember.
/// Dictionary, Phrases and Commands each draw theirs from these pieces.
class HeroSketch: NSView {
    enum Look { case said, landed }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The drawing, in the sketch's own flipped space. Colours resolve as
    /// dark here whatever the window is — the panel under it always is.
    /// (Setting `appearance` on the view instead left the snapshot's pane
    /// ground black: the override leaked up the layer tree.)
    func sketch() {}

    override func draw(_ dirtyRect: NSRect) {
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance { sketch() }
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The banner only centres its art. A sketch takes the whole side, so it
    /// can place things by fraction and let the odd one run off the edge.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let host = superview else { return }
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: host.leadingAnchor),
            trailingAnchor.constraint(equalTo: host.trailingAnchor),
            topAnchor.constraint(equalTo: host.topAnchor),
            bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
    }

    func capsuleWidth(_ text: String, font: NSFont, height: CGFloat,
                      lead: CGFloat = 0, trail: CGFloat = 0) -> CGFloat {
        let tw = (text as NSString).size(withAttributes: [.font: font]).width
        return ceil(tw + height + lead + trail)
    }

    /// A capsule with its words, top-left at `origin`. `lead` and `trail`
    /// leave room inside for a mark the caller draws. Returns where it went.
    @discardableResult
    func capsule(_ text: String, at origin: NSPoint, font: NSFont, height: CGFloat, look: Look,
                 alpha: CGFloat = 1, lead: CGFloat = 0, trail: CGFloat = 0) -> NSRect {
        let r = NSRect(x: origin.x, y: origin.y,
                       width: capsuleWidth(text, font: font, height: height, lead: lead, trail: trail),
                       height: height)
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: height / 2 - 0.5, yRadius: height / 2 - 0.5)
        let ink: NSColor
        switch look {
        case .said:
            NSColor.white.withAlphaComponent(0.09 * alpha).setFill()
            path.fill()
            path.lineWidth = 1
            NSColor.white.withAlphaComponent(0.20 * alpha).setStroke()
            path.stroke()
            ink = HeroBanner.cream.withAlphaComponent(0.88 * alpha)
        case .landed:
            HeroBanner.cream.withAlphaComponent(alpha).setFill()
            path.fill()
            ink = Theme.paper.withAlphaComponent(alpha)
        }
        let size = (text as NSString).size(withAttributes: [.font: font])
        (text as NSString).draw(at: NSPoint(x: r.minX + height / 2 + lead,
                                            y: (r.midY - size.height / 2).rounded()),
                                withAttributes: [.font: font, .foregroundColor: ink])
        return r
    }

    /// A capsule's outline and nothing else: an echo of one.
    func ghost(_ r: NSRect, alpha: CGFloat) {
        let path = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: r.height / 2 - 0.5, yRadius: r.height / 2 - 0.5)
        HeroBanner.cream.withAlphaComponent(alpha * 0.35).setFill()
        path.fill()
        path.lineWidth = 1
        HeroBanner.cream.withAlphaComponent(alpha).setStroke()
        path.stroke()
    }

    /// A hand-drawn curve with a small open head: this became that.
    func arrow(from a: NSPoint, to b: NSPoint) {
        let u = Theme.m(1)
        let path = NSBezierPath()
        path.move(to: a)
        path.curve(to: b, controlPoint1: NSPoint(x: a.x, y: a.y + (b.y - a.y) * 0.8),
                   controlPoint2: NSPoint(x: a.x + (b.x - a.x) * 0.3, y: b.y))
        path.lineWidth = 1.5 * u
        path.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.42).setStroke()
        path.stroke()
        let head = NSBezierPath()
        head.move(to: NSPoint(x: b.x - 5 * u, y: b.y - 4.5 * u))
        head.line(to: b)
        head.line(to: NSPoint(x: b.x - 5 * u, y: b.y + 4.5 * u))
        head.lineWidth = 1.5 * u
        head.lineCapStyle = .round
        head.lineJoinStyle = .round
        head.stroke()
    }

    /// The wavy underline a spelling checker draws, in ember.
    func squiggle(from start: NSPoint, width: CGFloat) {
        let u = Theme.m(1)
        let path = NSBezierPath()
        let step = 3 * u
        var x = start.x
        path.move(to: start)
        var up = true
        while x < start.x + width {
            let next = min(x + step, start.x + width)
            path.curve(to: NSPoint(x: next, y: start.y),
                       controlPoint1: NSPoint(x: x + step * 0.5, y: start.y + (up ? -2 : 2) * u),
                       controlPoint2: NSPoint(x: next - step * 0.5, y: start.y + (up ? -2 : 2) * u))
            up.toggle()
            x = next
        }
        path.lineWidth = 1.3 * u
        path.lineCapStyle = .round
        Theme.ember.setStroke()
        path.stroke()
    }

    /// An SF Symbol in one colour, centred on a point.
    func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .semibold,
                color: NSColor, center: NSPoint) {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) else { return }
        let s = img.size
        img.draw(in: NSRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height),
                 from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// A few bars of a voice, the way the pill draws one — ember, because it
    /// is somebody talking.
    func voice(at origin: NSPoint, height: CGFloat) {
        let u = Theme.m(1)
        let w = 2 * u, gap = 2 * u
        for (i, f) in [0.45, 0.9, 0.62, 1.0, 0.5].enumerated() {
            let bh = (height * CGFloat(f)).rounded()
            let r = NSRect(x: origin.x + CGFloat(i) * (w + gap), y: origin.y + (height - bh) / 2, width: w, height: bh)
            Theme.ember.setFill()
            NSBezierPath(roundedRect: r, xRadius: w / 2, yRadius: w / 2).fill()
        }
    }
    static func voiceWidth() -> CGFloat { Theme.m(1) * (5 * 2 + 4 * 2) }
}

/// One app in the hero: its icon on a frosted disc.
private final class AppBubble: NSView {
    private let icon: NSImage
    init(_ icon: NSImage, diameter d: CGFloat) {
        self.icon = icon
        super.init(frame: NSRect(x: 0, y: 0, width: d, height: d))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: d),
            heightAnchor.constraint(equalToConstant: d),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let disc = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        NSColor.white.withAlphaComponent(0.10).setFill()
        disc.fill()
        disc.lineWidth = 1
        NSColor.white.withAlphaComponent(0.16).setStroke()
        disc.stroke()
        let side = bounds.width * 0.64
        icon.draw(in: NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side),
                  from: .zero, operation: .sourceOver, fraction: 1)
    }
}

/// The hero's two buttons: cream-filled, or bare cream text.
private final class HeroButton: NSView {
    private let run: () -> Void
    private let filled: Bool
    private var hovering = false { didSet { needsDisplay = true } }

    init(_ title: String, filled: Bool, run: @escaping () -> Void) {
        self.run = run
        self.filled = filled
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(8)
        let f = Theme.text(title, 13, .medium, filled ? HeroBanner.ink : HeroBanner.cream)
        f.font = .systemFont(ofSize: Theme.m(13), weight: .medium)
        f.translatesAutoresizingMaskIntoConstraints = false
        addSubview(f)
        NSLayoutConstraint.activate([
            f.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(filled ? 14 : 10)),
            f.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.m(filled ? 14 : 10)),
            f.topAnchor.constraint(equalTo: topAnchor, constant: Theme.m(7)),
            f.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.m(7)),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
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
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        run()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override var mouseDownCanMoveWindow: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let fill: NSColor = filled
            ? (hovering ? .white : HeroBanner.cream)
            : (hovering ? NSColor.white.withAlphaComponent(0.10) : .clear)
        layer?.backgroundColor = fill.cgColor
    }
}
