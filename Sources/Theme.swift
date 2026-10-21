// Shared look & feel for the settings window: colours, text helpers, and the
// handful of composite views (cards, toggle rows, status rows) the panes are built from.
import Cocoa

enum Theme {

    static func dyn(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    /// #RRGGBB, the way the prototype writes them.
    static func hex(_ v: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                green:   CGFloat((v >> 8)  & 0xFF) / 255,
                blue:    CGFloat(v & 0xFF) / 255, alpha: alpha)
    }

    // Graphite on warm porcelain; ember only when something is live or on.
    // Light value first, dark value second. The 2.3 refresh, second pass:
    // the light neutrals moved up a step and warmer — near-white paper, a
    // sand-grey sidebar, beige for the row you are on — so the page reads
    // clean rather than grey-on-grey. The ember is still spent on recording,
    // today's meter column and switched-on toggles, never on navigation.
    static let ember = dyn(hex(0xE5501F), hex(0xFF6A3D))
    /// Ember as text: the plain ember is too light to read at small sizes
    /// (3.8:1 on white); this is 5.2:1.
    static let emberInk = dyn(hex(0xC2410C), hex(0xFF8A63))
    static let moss  = dyn(hex(0x1A7A50), hex(0x3CC48A))
    static let amber = dyn(hex(0x9A6412), hex(0xF0B44C))
    /// Destructive actions. Not the ember: red means "gone", ember means "live".
    static let danger = dyn(hex(0xC6362B), hex(0xFF6B5E))

    static let ink   = dyn(hex(0x1C1B19), hex(0xF3F3F1))
    static let ink2  = dyn(hex(0x44423E), hex(0xC8C8CD))
    /// 5.2:1 on paper.
    static let muted = dyn(hex(0x6C6963), hex(0x95959B))
    /// Decoration and meta only — never a sentence.
    static let faint = dyn(hex(0x9A968F), hex(0x6A6A70))

    static let paper       = dyn(hex(0xFAF9F7), hex(0x111113))
    /// The floating sidebar panel. It carries its own hairline and lift, so
    /// its fill only needs to sit a step off the paper.
    static let sidebarFill = dyn(hex(0xF1EFEB), hex(0x1C1C1F))
    static let sidebarLine = dyn(hex(0xE5E2DC), hex(0x2B2B30))
    /// A card that sits *on* the sidebar — the shortcut card under the logo.
    static let sideCard    = dyn(hex(0xFFFFFF), hex(0x26262A))
    static let surface     = dyn(hex(0xFFFFFF), hex(0x1B1B1E))
    static let hairline    = dyn(hex(0xE8E6E1), hex(0x2B2B30))
    /// The softer rule used *inside* a card, between its rows.
    static let hairsoft    = dyn(hex(0xF0EEEA), hex(0x232327))
    /// Sunk wells: the strip behind an add-row, a pill switcher's trough.
    static let wellFill    = dyn(hex(0xF2F0EC), hex(0x0C0C0E))
    /// A keycap's face: a step off white, so a cap reads on a white card.
    static let keyFill     = dyn(hex(0xF6F4F0), hex(0x2E2E33))
    /// Unlit meter segments and empty bars.
    static let barFill     = dyn(hex(0x1C1B19, 0.06), NSColor.white.withAlphaComponent(0.07))
    /// Lit meter segments on days that aren't today.
    static let barLit      = dyn(hex(0x1C1B19, 0.42), NSColor.white.withAlphaComponent(0.62))
    /// The one-point bottom lip under a keycap or a plain button.
    static let lipColor    = dyn(hex(0xDDDAD3), hex(0x0A0A0B))

    /// Ember at low alpha — the live chip, the focus halo.
    static let emberSoft = dyn(hex(0xE5501F, 0.10), hex(0xFF6A3D, 0.14))
    static let emberRing = dyn(hex(0xE5501F, 0.32), hex(0xFF6A3D, 0.40))
    static let mossSoft  = dyn(hex(0x1A7A50, 0.10), hex(0x3CC48A, 0.13))
    static let amberSoft = dyn(hex(0xB7791F, 0.13), hex(0xF0B44C, 0.13))
    static let dangerSoft = dyn(hex(0xC6362B, 0.08), hex(0xFF6B5E, 0.12))
    static let dangerRing = dyn(hex(0xC6362B, 0.26), hex(0xFF6B5E, 0.32))

    static let cardFill   = surface
    static let cardStroke = hairline
    /// The selected sidebar row: warm beige, not a lifted white card.
    static let navPick    = dyn(hex(0xE7E3DA), NSColor.white.withAlphaComponent(0.09))
    static let navHover   = dyn(hex(0xECE9E3), NSColor.white.withAlphaComponent(0.05))
    /// The picked chip in a segmented switcher. White on the light well; on
    /// the dark one a lifted grey, well clear of the near-black trough —
    /// `surface` there was two shades off it, and which one was picked had
    /// to be read from the weight of the words.
    static let segPick    = dyn(hex(0xFFFFFF), hex(0x3A3A40))
    static let segEdge    = dyn(hex(0xE8E6E1), NSColor.white.withAlphaComponent(0.12))

    /// The soft hues behind an icon tile (see IconTile) — the one place the
    /// page wears colour that isn't a state. Each is a glyph colour and a
    /// wash, light then dark.
    enum Hue {
        case blue, violet, green, amber, rose, slate, ember, teal
        var ink: NSColor {
            switch self {
            case .blue:   return Theme.dyn(Theme.hex(0x2F6FDB), Theme.hex(0x7AA8FF))
            case .violet: return Theme.dyn(Theme.hex(0x6D4ED8), Theme.hex(0xB09CFF))
            case .green:  return Theme.dyn(Theme.hex(0x1F8A5B), Theme.hex(0x4FD39A))
            case .amber:  return Theme.dyn(Theme.hex(0xB06A0C), Theme.hex(0xF3B652))
            case .rose:   return Theme.dyn(Theme.hex(0xC23A5E), Theme.hex(0xFF8FAE))
            case .slate:  return Theme.dyn(Theme.hex(0x55606E), Theme.hex(0xB4BDC9))
            case .ember:  return Theme.dyn(Theme.hex(0xD9481A), Theme.hex(0xFF7A4D))
            case .teal:   return Theme.dyn(Theme.hex(0x0F7C86), Theme.hex(0x5CD3DD))
            }
        }
        var wash: NSColor {
            switch self {
            case .blue:   return Theme.dyn(Theme.hex(0x2F6FDB, 0.11), Theme.hex(0x7AA8FF, 0.16))
            case .violet: return Theme.dyn(Theme.hex(0x6D4ED8, 0.11), Theme.hex(0xB09CFF, 0.16))
            case .green:  return Theme.dyn(Theme.hex(0x1F8A5B, 0.11), Theme.hex(0x4FD39A, 0.15))
            case .amber:  return Theme.dyn(Theme.hex(0xB06A0C, 0.12), Theme.hex(0xF3B652, 0.15))
            case .rose:   return Theme.dyn(Theme.hex(0xC23A5E, 0.10), Theme.hex(0xFF8FAE, 0.15))
            case .slate:  return Theme.dyn(Theme.hex(0x55606E, 0.10), Theme.hex(0xB4BDC9, 0.14))
            case .ember:  return Theme.dyn(Theme.hex(0xD9481A, 0.11), Theme.hex(0xFF7A4D, 0.16))
            case .teal:   return Theme.dyn(Theme.hex(0x0F7C86, 0.11), Theme.hex(0x5CD3DD, 0.15))
            }
        }
    }

    // MARK: - Text

    /// Global text scale from the "Text size" setting. Every font that goes
    /// through these helpers multiplies by it, so cards, rows and buttons all
    /// grow together. Set from Config at launch and when the setting changes.
    static var scale: CGFloat = 1.0
    static func s(_ v: CGFloat) -> CGFloat { (v * scale * 2).rounded() / 2 }

    /// The prototype is drawn at Moderate, so its pixel values are what the
    /// window renders when `scale` is 1.25. `px()` takes a number straight off
    /// design/sayctrl-ui-prototype.html and returns the size that lands exactly
    /// there at Moderate — and grows or shrinks with the Text size setting.
    static let designScale: CGFloat = 1.25
    static func px(_ v: CGFloat) -> CGFloat { s(v / designScale) }

    /// A number read off design/sayctrl-refresh.html. That mockup draws the
    /// window 1040 wide; the real one is 1260, so its CSS pixels land at 1.2×
    /// at Moderate — and grow or shrink with the Text size setting like the rest.
    static func m(_ v: CGFloat) -> CGFloat { s(v * 0.96) }

    /// The display face (SF Pro Display at these sizes), tightened the way the
    /// refresh sets titles and big figures.
    static func display(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight = .semibold,
                        _ color: NSColor = Theme.ink, tracking: CGFloat = -0.012) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        let font = NSFont.systemFont(ofSize: m(size), weight: weight)
        f.font = font
        f.textColor = color
        f.lineBreakMode = .byTruncatingTail
        f.maximumNumberOfLines = 1
        f.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        f.attributedStringValue = NSAttributedString(string: s, attributes: [
            .font: font, .foregroundColor: color, .kern: m(size) * tracking,
        ])
        return f
    }

    /// Sets a `display` label's text without losing its tracking.
    static func setDisplay(_ f: NSTextField, _ s: String) {
        let attrs = f.attributedStringValue.length > 0
            ? f.attributedStringValue.attributes(at: 0, effectiveRange: nil) : [:]
        f.attributedStringValue = NSAttributedString(string: s, attributes: attrs)
    }

    // ── The second pass's type rules ─────────────────────────────────────
    // One family for the interface: SF Pro. The words you said, in a list,
    // are SF Pro Text regular — `said`. New York is kept for the few big
    // moments: figures and hero headlines (`figure`), and the live card.
    // Times, counts and durations are tabular SF digits (`digits`), not
    // monospace; monospace is only for literal code, paths and keys.

    /// The words you said, as a list shows them.
    static func saidFont(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: m(size), weight: weight)
    }

    /// New York at a display size — a big number, a hero headline.
    static func figureFont(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        let sz = m(size)
        let base = NSFont.systemFont(ofSize: sz, weight: weight)
        guard let desc = base.fontDescriptor.withDesign(.serif),
              let serif = NSFont(descriptor: desc, size: sz) else { return base }
        return serif
    }

    static func figure(_ s: String, _ size: CGFloat, _ color: NSColor = Theme.ink,
                       weight: NSFont.Weight = .regular, tracking: CGFloat = -0.01) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        let font = figureFont(size, weight)
        f.font = font
        f.textColor = color
        f.lineBreakMode = .byTruncatingTail
        f.maximumNumberOfLines = 1
        f.attributedStringValue = NSAttributedString(string: s, attributes: [
            .font: font, .foregroundColor: color, .kern: font.pointSize * tracking,
        ])
        return f
    }

    /// Tabular SF digits: numbers that line up without the typewriter look.
    static func digits(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: m(size), weight: weight)
    }

    /// A time, a count, a duration — faint tabular digits.
    static func meta(_ s: String, _ size: CGFloat = 11.5, _ color: NSColor = Theme.faint,
                     _ weight: NSFont.Weight = .regular) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = digits(size, weight)
        f.textColor = color
        f.lineBreakMode = .byTruncatingTail
        f.maximumNumberOfLines = 1
        return f
    }

    /// Wrapping paragraph label. Claims no intrinsic width, so a long sentence
    /// wraps inside its container instead of stretching the window.
    static func label(_ s: String, _ size: CGFloat = 12,
                      _ weight: NSFont.Weight = .regular,
                      _ color: NSColor = Theme.ink) -> NSTextField {
        let f = WrapLabel(labelWithString: s)
        f.font = .systemFont(ofSize: Theme.s(size), weight: weight)
        f.textColor = color
        f.lineBreakMode = .byWordWrapping
        f.maximumNumberOfLines = 0
        f.usesSingleLineMode = false
        f.cell?.wraps = true
        f.cell?.isScrollable = false
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        f.setContentCompressionResistancePriority(.init(rawValue: 200), for: .horizontal)
        return f
    }

    /// Single-line label that keeps its natural width (titles, nav rows, table cells).
    static func line(_ s: String, _ size: CGFloat = 12,
                     _ weight: NSFont.Weight = .regular,
                     _ color: NSColor = Theme.ink) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = .systemFont(ofSize: Theme.s(size), weight: weight)
        f.textColor = color
        f.lineBreakMode = .byTruncatingTail
        f.maximumNumberOfLines = 1
        return f
    }

    static func dim(_ s: String, _ size: CGFloat = 11.5) -> NSTextField {
        label(s, size, .regular, Theme.muted)
    }

    static func dimLine(_ s: String, _ size: CGFloat = 11.5) -> NSTextField {
        line(s, size, .regular, Theme.muted)
    }

    /// New York (the system serif) — pane titles and the stat numbers.
    static func serifFont(_ size: CGFloat, _ weight: NSFont.Weight = .medium) -> NSFont {
        let sz = Theme.s(size)
        let base = NSFont.systemFont(ofSize: sz, weight: weight)
        guard let desc = base.fontDescriptor.withDesign(.serif),
              let serif = NSFont(descriptor: desc, size: sz) else { return base }
        return serif
    }

    static func serifLine(_ s: String, _ size: CGFloat,
                          _ weight: NSFont.Weight = .medium,
                          _ color: NSColor = Theme.ink) -> NSTextField {
        let f = line(s, size, weight, color)
        f.font = serifFont(size, weight)
        return f
    }

    /// Uppercase, letter-spaced group label — the section eyebrow.
    static func caps(_ s: String, _ size: CGFloat = 10.5,
                     _ color: NSColor = Theme.muted) -> NSTextField {
        let f = line("", size, .semibold, color)
        f.attributedStringValue = NSAttributedString(
            string: s.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: Theme.s(size), weight: .semibold),
                .foregroundColor: color,
                .kern: size * 0.11,
            ])
        return f
    }

    // ── Prototype-native text ────────────────────────────────────────────
    // `size` here is a pixel read straight off the prototype. New panes use
    // these; the `line`/`label`/`dim` above stay until each old pane is redrawn.

    /// One line, natural width, truncates rather than widening the window.
    static func text(_ s: String, _ size: CGFloat,
                     _ weight: NSFont.Weight = .regular,
                     _ color: NSColor = Theme.ink) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = .systemFont(ofSize: px(size), weight: weight)
        f.textColor = color
        f.lineBreakMode = .byTruncatingTail
        f.maximumNumberOfLines = 1
        // Truncate rather than shove: a long line must never widen the window.
        f.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        return f
    }

    /// A paragraph: wraps inside whatever width it is given.
    static func para(_ s: String, _ size: CGFloat,
                     _ weight: NSFont.Weight = .regular,
                     _ color: NSColor = Theme.muted,
                     lineHeight: CGFloat = 1.5,
                     align: NSTextAlignment = .natural) -> NSTextField {
        let f = WrapLabel(labelWithString: s)
        let font = NSFont.systemFont(ofSize: px(size), weight: weight)
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = lineHeight
        // Set it here, not on the field: an attributed string carries its own
        // paragraph style and would ignore `alignment` afterwards.
        style.alignment = align
        f.attributedStringValue = NSAttributedString(string: s, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: style,
        ])
        f.font = font
        f.textColor = color
        f.lineBreakMode = .byWordWrapping
        f.maximumNumberOfLines = 0
        f.usesSingleLineMode = false
        f.cell?.wraps = true
        f.cell?.isScrollable = false
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        f.setContentCompressionResistancePriority(.init(rawValue: 200), for: .horizontal)
        return f
    }

    static func serifText(_ s: String, _ size: CGFloat,
                          _ weight: NSFont.Weight = .medium,
                          _ color: NSColor = Theme.ink) -> NSTextField {
        let f = text(s, size, weight, color)
        let sz = px(size)
        let base = NSFont.systemFont(ofSize: sz, weight: weight)
        if let desc = base.fontDescriptor.withDesign(.serif), let serif = NSFont(descriptor: desc, size: sz) {
            f.font = serif
        }
        return f
    }

    static func monoText(_ s: String, _ size: CGFloat,
                         _ weight: NSFont.Weight = .regular,
                         _ color: NSColor = Theme.faint) -> NSTextField {
        let f = text(s, size, weight, color)
        f.font = .monospacedSystemFont(ofSize: px(size), weight: weight)
        return f
    }

    /// The section eyebrow: uppercase, letter-spaced, faint.
    static func eyebrow(_ s: String, _ size: CGFloat = 11.5,
                        _ color: NSColor = Theme.faint) -> NSTextField {
        let f = text("", size, .semibold, color)
        f.attributedStringValue = NSAttributedString(
            string: s.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: px(size), weight: .semibold),
                .foregroundColor: color,
                .kern: px(size) * 0.085,
            ])
        return f
    }

    /// Shadows are for things that float: the sidebar, popovers, sheets, the
    /// pill. A card on the page is a hairline and nothing else, so the plain
    /// call clears any shadow, and only `lift` casts one.
    static func shadow(_ layer: CALayer?, lift: Bool = false) {
        guard let layer = layer else { return }
        layer.shadowColor = hex(0x14161C).cgColor
        layer.shadowOpacity = lift ? 0.22 : 0
        layer.shadowRadius = lift ? 22 : 0
        layer.shadowOffset = CGSize(width: 0, height: lift ? -10 : 0)
    }

    /// The one-point lip under a keycap or a plain button: a shadow with no
    /// blur, straight down.
    static func lip(_ layer: CALayer?) {
        guard let layer = layer else { return }
        layer.shadowColor = lipColor.cgColor
        layer.shadowOpacity = 1
        layer.shadowRadius = 0
        layer.shadowOffset = CGSize(width: 0, height: -1)
    }

    static func mono(_ s: String, _ size: CGFloat = 11) -> NSTextField {
        let f = label(s, size)
        f.font = .monospacedSystemFont(ofSize: size, weight: .regular)
        return f
    }

    static func symbol(_ name: String, _ size: CGFloat = 13,
                       _ weight: NSFont.Weight = .semibold) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
    }

    // MARK: - The mark

    /// The app mark, on the 256 grid it is drawn on everywhere else — the
    /// website, the film and scripts/make_icon.swift all use these numbers, so
    /// changing them here means changing them there too.
    ///
    /// Three ink bars rising, then the ember arrow: the bars are what you say,
    /// the arrow is the app acting on it.
    private enum MarkGrid {
        /// Bar centres, and the half-height of each.
        static let barX: [CGFloat] = [50, 88, 126]
        static let barHalf: [CGFloat] = [37.5, 64.5, 84]
        /// Bar thickness, which is also twice the round cap radius.
        static let stroke: CGFloat = 24
        static let arrow: [(CGFloat, CGFloat)] = [(158, 71), (158, 185), (206, 128)]
        /// The arrow is filled and then outlined in its own colour, which is
        /// what rounds its three corners without shrinking it.
        static let join: CGFloat = 12
        /// The painted bounds on the grid: bar caps at x38, arrow apex at x214.
        /// Everything is symmetric about y128, so this survives AppKit's
        /// bottom-up y without a flip.
        static let inkX: CGFloat = 38, inkY: CGFloat = 44
        static let inkW: CGFloat = 176, inkH: CGFloat = 168
    }

    /// Paints the mark to fill `rect`, ink bars and accent arrow.
    ///
    /// It fits the *painted* bounds rather than the 256 square, so a 20pt menu
    /// bar item doesn't inherit the padding an app icon wants. Pass the same
    /// colour for both to get a flat silhouette for a template image.
    static func drawMark(in rect: NSRect, ink inkColor: NSColor, accent: NSColor) {
        let g = MarkGrid.self
        let scale = min(rect.width / g.inkW, rect.height / g.inkH)
        let ox = rect.minX + (rect.width - g.inkW * scale) / 2 - g.inkX * scale
        let oy = rect.minY + (rect.height - g.inkH * scale) / 2 - g.inkY * scale
        func at(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: ox + x * scale, y: oy + y * scale)
        }

        inkColor.setFill()
        let half = g.stroke / 2 * scale
        for (i, x) in g.barX.enumerated() {
            let top = at(x - g.stroke / 2, 128 - g.barHalf[i])
            let bar = NSRect(x: top.x, y: top.y,
                             width: g.stroke * scale, height: g.barHalf[i] * 2 * scale)
            NSBezierPath(roundedRect: bar, xRadius: half, yRadius: half).fill()
        }

        let wedge = NSBezierPath()
        wedge.move(to: at(g.arrow[0].0, g.arrow[0].1))
        wedge.line(to: at(g.arrow[1].0, g.arrow[1].1))
        wedge.line(to: at(g.arrow[2].0, g.arrow[2].1))
        wedge.close()
        wedge.lineJoinStyle = .round
        wedge.lineWidth = g.join * scale
        accent.setFill()
        wedge.fill()
        accent.setStroke()
        wedge.stroke()
    }

    /// The mark set in a rounded tile, the way the menu bar shows it.
    ///
    /// The tile is the 256 grid shrunk to the square in `rect`, corners at
    /// radius 62; the mark sits at 0.86 of the grid with its painted middle
    /// (126, 128) on the tile's centre. A bare mark at 16pt reads as three
    /// scratches; a tile holds its shape against any wallpaper. (0.6, then
    /// 0.78, left the mark small inside its square in the real menu bar.)
    ///
    /// With no `markColor` the mark is cut out of the tile rather than painted
    /// on it, so a template image gets real holes the menu bar shows through
    /// — painting it black on black would leave macOS one solid square to tint.
    static func drawMarkTile(in rect: NSRect, tile tileColor: NSColor, mark markColor: NSColor?) {
        let side = min(rect.width, rect.height)
        let tile = NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        let unit = side / 256
        tileColor.setFill()
        NSBezierPath(roundedRect: tile, xRadius: 62 * unit, yRadius: 62 * unit).fill()

        // drawMark fits the painted bounds, so a rect of exactly those bounds
        // at 0.86 scale, centred, is the 0.86 transform about (126, 128).
        let g = MarkGrid.self
        let s = 0.86 * unit
        let inner = NSRect(x: tile.midX - g.inkW * s / 2, y: tile.midY - g.inkH * s / 2,
                           width: g.inkW * s, height: g.inkH * s)
        guard let markColor else {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            drawMark(in: inner, ink: .black, accent: .black)
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        drawMark(in: inner, ink: markColor, accent: markColor)
    }

    /// The mark as an image. `inkColor` overrides the page ink, for the dark
    /// glass of the HUD and the pill.
    static func mark(_ side: CGFloat, inkColor: NSColor? = nil) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            drawMark(in: rect, ink: inkColor ?? ink, accent: ember)
            return true
        }
    }

    // MARK: - Buttons

    static func accentButton(_ title: String, target: AnyObject?, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .rounded
        b.bezelColor = ink
        b.contentTintColor = paper
        b.font = .systemFont(ofSize: Theme.s(12), weight: .medium)
        return b
    }

    static func plainButton(_ title: String, target: AnyObject?, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .rounded
        b.font = .systemFont(ofSize: Theme.s(12))
        return b
    }

    static func field(_ placeholder: String) -> NSTextField {
        let f = NSTextField()
        f.placeholderString = placeholder
        f.font = .systemFont(ofSize: Theme.s(12.5))
        f.bezelStyle = .roundedBezel
        return f
    }

    // MARK: - Layout helpers

    static func hstack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = spacing
        s.alignment = .centerY
        return s
    }

    static func vstack(_ views: [NSView], spacing: CGFloat = 6) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.spacing = spacing
        s.alignment = .leading
        return s
    }

    static func spacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        return v
    }

    static func divider() -> NSView {
        let v = ColorView(color: hairline)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return v
    }
}

// MARK: - Small building blocks

/// A label that reports its wrapped height for whatever width it ends up with.
final class WrapLabel: NSTextField {
    /// Measured at the width the text is drawn in, not the frame's. A text
    /// field's frame runs 2 pt past its alignment rect on each side, and the
    /// text is laid out inside the alignment rect — so a line that just fits
    /// when measured at the frame width wraps when drawn, and the last line
    /// of the paragraph falls off the bottom. Subtracting exactly the insets
    /// is what keeps this stable: the measured width is the alignment width,
    /// which is what the constraints set, so a second pass changes nothing.
    override func layout() {
        let insets = alignmentRectInsets
        let width = bounds.width - insets.left - insets.right
        if abs(preferredMaxLayoutWidth - width) > 0.5 {
            preferredMaxLayoutWidth = width
            invalidateIntrinsicContentSize()
        }
        super.layout()
    }
}

/// A flat rectangle of one (appearance-aware) colour.
final class ColorView: NSView {
    /// Settable, so a status dot can change colour and keep it — a colour
    /// written straight to the layer is painted over at the next display.
    var color: NSColor { didSet { needsDisplay = true } }
    private let radius: CGFloat
    init(color: NSColor, radius: CGFloat = 0) {
        self.color = color
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = color.cgColor }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// Rounded translucent panel with an optional title/subtitle header.
final class Card: NSView {
    private let stack = NSStackView()

    /// The header row, so a pane can hang a note or a button off the right of it.
    private(set) var headRow: NSStackView?
    private let padX = Theme.px(22)

    init(_ title: String? = nil, _ subtitle: String? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(12)
        layer?.borderWidth = 1

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.px(14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Theme.px(20)),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padX),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padX),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.px(20)),
        ])

        if let title = title {
            let h = Theme.hstack([Theme.display(title, 15, .medium, tracking: -0.005), Theme.spacer()],
                                 spacing: Theme.px(10))
            headRow = h
            add(h)
            if let subtitle = subtitle { add(Theme.para(subtitle, 13)) }
        }
    }

    /// Puts a view at the right end of the card's title row.
    func addToHead(_ view: NSView) { headRow?.addArrangedSubview(view) }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Theme.cardFill.cgColor
        layer?.borderColor = Theme.cardStroke.cgColor
        Theme.shadow(layer)
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    /// Adds a row stretched to the card's width.
    func add(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    /// A rule between rows. It runs edge to edge — the card's padding is
    /// cancelled out, the way `.rule` does in the prototype.
    func addDivider() {
        let rule = ColorView(color: Theme.hairsoft)
        let host = NSView()
        rule.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(rule)
        NSLayoutConstraint.activate([
            rule.heightAnchor.constraint(equalToConstant: 1),
            rule.topAnchor.constraint(equalTo: host.topAnchor),
            rule.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            rule.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: -padX),
            rule.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: padX),
        ])
        add(host)
    }
}





/// Base class so the shell can tell a pane when it comes on screen.
class PaneView: NSView {
    func paneAppeared() {}
    func paneDisappeared() {}
}

extension NSView {
    /// Pins this view to fill `parent`, with optional padding.
    func fill(_ parent: NSView, inset: CGFloat = 0) {
        translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(self)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset),
            leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
        ])
    }
}

/// A view that hangs tooltips off rectangles instead of off itself.
///
/// `addToolTip(_:owner:userData:)` does **not** retain its owner, and the
/// charts used to pass a freshly-built string for every rectangle. The string
/// died at the end of the statement, AppKit kept the pointer, and the next
/// time the tooltip timer fired over a chart the app went down inside
/// `-[NSToolTipManager displayToolTip:]`. The owner is the view itself now —
/// it outlives every tooltip it owns, and AppKit drops the rectangles when it
/// goes — and the strings are held here, looked up by tag.
class TipView: NSView, NSViewToolTipOwner {
    private var tips: [String] = []

    /// Replaces every tooltip on this view in one go.
    func setTips(_ items: [(rect: NSRect, text: String)]) {
        removeAllToolTips()
        tips = items.map { $0.text }
        for (i, item) in items.enumerated() {
            // Tag 0 would be a null userData pointer, so the index is offset by one.
            addToolTip(item.rect, owner: self, userData: UnsafeMutableRawPointer(bitPattern: i + 1))
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
              point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        let i = Int(bitPattern: data) - 1
        return tips.indices.contains(i) ? tips[i] : ""
    }
}

/// Top-down coordinates, so a scroll view opens at the top of its content
/// instead of at the bottom (AppKit's default for an unflipped document view).
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Horizontal breathing room between the sidebar and a pane's content. Equal
/// on both sides — a pane fills the width it is given.
var PANE_INSET: CGFloat { Theme.px(46) }

/// A scroller that takes no width and paints nothing. The panes still scroll
/// with the wheel and the trackpad — they just never wear a bar, which is what
/// a legacy (mouse-attached) scroller would otherwise paint down the right
/// edge of every card, gutter and all.
/// A scroll view with no visible bar, whatever the system's "show scroll bars"
/// setting says. The panes scroll with the wheel and the trackpad; a grey
/// track down the right of every card is just noise.
final class QuietScroll: NSScrollView {
    override func tile() {
        super.tile()
        verticalScroller?.isHidden = true
        horizontalScroller?.isHidden = true
    }
}

final class HiddenScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override class func scrollerWidth(for controlSize: NSControl.ControlSize,
                                      scrollerStyle: NSScroller.Style) -> CGFloat { 0 }
    override func draw(_ dirtyRect: NSRect) {}
    override func drawKnob() {}
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
    override var alphaValue: CGFloat {
        get { 0 }
        set { _ = newValue }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A vertically scrolling column of cards.
func makeCardScroll(_ cards: [NSView], topInset: CGFloat = -1) -> NSScrollView {
    let top = topInset < 0 ? Theme.px(58) : topInset
    let stack = NSStackView(views: cards)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = Theme.px(14)
    stack.translatesAutoresizingMaskIntoConstraints = false

    // The side inset belongs on the stack: pinning the document view to the clip
    // view's edges would override NSScrollView.contentInsets, leaving the cards
    // flush against the sidebar.
    let doc = FlippedView()
    doc.translatesAutoresizingMaskIntoConstraints = false
    doc.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: top),
        stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: PANE_INSET),
        stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -PANE_INSET),
        stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -Theme.px(56)),
    ])
    for c in cards {
        c.translatesAutoresizingMaskIntoConstraints = false
        c.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    let scroll = QuietScroll()
    scroll.drawsBackground = false
    scroll.scrollerStyle = .overlay
    scroll.autohidesScrollers = true
    scroll.hasHorizontalScroller = false
    scroll.hasVerticalScroller = true
    scroll.verticalScroller = HiddenScroller()
    scroll.documentView = doc
    NSLayoutConstraint.activate([
        doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
        doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
    ])
    return scroll
}

/// The pane title in SF Pro Display, with a one-line explanation under it
/// when there is something worth saying. The serif is kept for the words you
/// said — a title is the app talking, so it is set in the app's own face.
func makePaneHeader(_ title: String, _ subtitle: String = "", trailing: NSView? = nil) -> NSView {
    var column: [NSView] = [Theme.display(title, 24, .medium)]
    if !subtitle.isEmpty { column.append(Theme.para(subtitle, 13, .regular, Theme.muted, lineHeight: 1.35)) }
    let left = Theme.vstack(column, spacing: Theme.px(5))
    guard let trailing = trailing else { return left }
    let host = NSView()
    splitRow(left, trailing, into: host, vertical: 0)
    if column.count > 1 { column[1].widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true }
    return host
}

// MARK: - 2.1 controls

/// The prototype's `.btn`: a flat rounded rectangle, no macOS bezel. Four
/// looks — plain, primary (ember), quiet (no border) and danger.
final class FlatButton: NSView {
    /// `ember` is the one button that spends money: Upgrade.
    enum Look { case plain, primary, quiet, danger, ember }

    private let titleField: NSTextField
    private let iconView = NSImageView()
    private let look: Look
    private var hovering = false { didSet { needsDisplay = true } }
    var onClick: () -> Void = {}
    var isEnabled = true { didSet { alphaValue = isEnabled ? 1 : 0.5; needsDisplay = true } }

    init(_ title: String, _ look: Look = .plain, symbol: String? = nil, onClick: @escaping () -> Void = {}) {
        self.look = look
        self.onClick = onClick
        let weight: NSFont.Weight = (look == .primary || look == .ember) ? .semibold : .medium
        titleField = Theme.text(title, 13, weight, .white)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(8)
        layer?.borderWidth = 1

        var parts: [NSView] = []
        if let symbol = symbol {
            iconView.image = Theme.symbol(symbol, Theme.px(14), .semibold)
            iconView.translatesAutoresizingMaskIntoConstraints = false
            iconView.widthAnchor.constraint(equalToConstant: Theme.px(14)).isActive = true
            parts.append(iconView)
        }
        parts.append(titleField)

        let row = Theme.hstack(parts, spacing: Theme.px(6))
        // Keep the button its own width — a stack would otherwise stretch it
        // across the row. A card that wants a full-width button pins it.
        row.setHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        // A caller may fix the button's width (a column of equal buttons).
        // The label then takes the slack and centres its text, so it never
        // hugs the left edge of a wider button.
        row.distribution = .fill
        titleField.alignment = .center
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.px(13)),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.px(13)),
            row.topAnchor.constraint(equalTo: topAnchor, constant: Theme.px(7)),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.px(7)),
        ])
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    var title: String {
        get { titleField.stringValue }
        set { titleField.stringValue = newValue }
    }

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
        guard isEnabled, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override var mouseDownCanMoveWindow: Bool { false }

    private func restyle() {
        let fg: NSColor
        switch look {
        case .primary: fg = Theme.paper
        case .ember:   fg = .white
        case .quiet:   fg = hovering ? Theme.ink : Theme.muted
        case .danger:  fg = Theme.danger
        case .plain:   fg = Theme.ink
        }
        titleField.textColor = fg
        iconView.contentTintColor = fg
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        restyle()
        // Primary is ink, one per view. Ember is kept for "live" and "on".
        layer?.shadowOpacity = 0
        switch look {
        case .primary:
            layer?.backgroundColor = (hovering ? Theme.ink2 : Theme.ink).cgColor
            layer?.borderColor = NSColor.clear.cgColor
        case .ember:
            layer?.backgroundColor = (hovering ? Theme.emberInk : Theme.ember).cgColor
            layer?.borderColor = NSColor.clear.cgColor
        case .quiet:
            layer?.backgroundColor = (hovering ? Theme.navHover : .clear).cgColor
            layer?.borderColor = NSColor.clear.cgColor
        case .danger:
            layer?.backgroundColor = (hovering ? Theme.danger.withAlphaComponent(0.08) : .clear).cgColor
            layer?.borderColor = Theme.danger.withAlphaComponent(0.35).cgColor
        case .plain:
            layer?.backgroundColor = (hovering ? Theme.wellFill : Theme.surface).cgColor
            layer?.borderColor = Theme.hairline.cgColor
            Theme.lip(layer)
        }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// A bare square of icon that washes ember on hover — the row actions, the
/// filter magnifier, the close on a sheet.
final class IconButton: NSView {
    private let iconView = NSImageView()
    private var hovering = false { didSet { needsDisplay = true } }
    var onClick: () -> Void = {}
    /// A resting colour, for a button that is a tile rather than a bare glyph.
    var fill: NSColor? { didSet { needsDisplay = true } }

    init(_ symbol: String, size: CGFloat = 28, icon: CGFloat = 15, tip: String? = nil,
         onClick: @escaping () -> Void = {}) {
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(7)
        toolTip = tip
        iconView.image = Theme.symbol(symbol, Theme.px(icon), .medium)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Theme.px(size)),
            heightAnchor.constraint(equalToConstant: Theme.px(size)),
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    func setSymbol(_ name: String, icon: CGFloat = 15) {
        iconView.image = Theme.symbol(name, Theme.px(icon), .medium)
        restyle()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    /// The press stops here: a button inside a clickable box (a shortcut
    /// cap) must not also count as a click on the box.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override var mouseDownCanMoveWindow: Bool { false }

    /// A resting tint for the glyph — the Recent row's play button goes
    /// ember while its clip is playing.
    var tint: NSColor? { didSet { needsDisplay = true } }

    private func restyle() { iconView.contentTintColor = tint ?? (hovering ? Theme.ink : Theme.muted) }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        restyle()
        layer?.backgroundColor = (hovering ? Theme.navPick : (fill ?? .clear)).cgColor
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// The short ink confirmation that slides up at the bottom of the window,
/// with one optional action on its right — "Deleted · Undo".
final class ToastView: NSView {
    init(_ message: String, action: (title: String, run: () -> Void)? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(10)
        let field = Theme.text(message, 13, .medium, Theme.paper)
        var parts: [NSView] = [field]
        if let action = action {
            let rule = ColorView(color: Theme.paper.withAlphaComponent(0.25))
            rule.translatesAutoresizingMaskIntoConstraints = false
            rule.widthAnchor.constraint(equalToConstant: 1).isActive = true
            rule.heightAnchor.constraint(equalToConstant: Theme.m(14)).isActive = true
            let button = ToastAction(action.title, run: action.run)
            parts += [rule, button]
        }
        let row = Theme.hstack(parts, spacing: Theme.m(12))
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(16)),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.m(action == nil ? 16 : 10)),
            row.topAnchor.constraint(equalTo: topAnchor, constant: Theme.m(9)),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.m(9)),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Theme.ink.cgColor
        Theme.shadow(layer, lift: true)
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// The toast's one button: bold paper text that washes on hover.
private final class ToastAction: NSView {
    private let run: () -> Void
    private var hovering = false { didSet { needsDisplay = true } }
    init(_ title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(6)
        let f = Theme.text(title, 13, .semibold, Theme.paper)
        f.translatesAutoresizingMaskIntoConstraints = false
        addSubview(f)
        NSLayoutConstraint.activate([
            f.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(6)),
            f.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.m(6)),
            f.topAnchor.constraint(equalTo: topAnchor, constant: Theme.m(2)),
            f.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.m(2)),
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
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        run()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override var mouseDownCanMoveWindow: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = (hovering ? Theme.paper.withAlphaComponent(0.14) : .clear).cgColor
    }
}
