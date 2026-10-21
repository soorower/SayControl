// The live take's words, one line inside the pill. The pill opens once to
// hold it — the first words arrive and the capsule springs out to its full
// width beside the bars, then holds still — and the newest words fill from
// the left, scrolling off under a soft fade once the line is full. Words
// the stream has repeated sit in full ink; the newest, which the recognizer
// may still change, sit dimmer and fade in rather than jump.
//
// A spoken command — "take a screenshot", "copy the link", "copy the file
// path" — lights up in its own colour the moment the grammar (Commands)
// accepts it as a command, then folds into a small chip that stays in the
// line: the take visibly carries a picture, a link, a path. The toast that
// says the thing actually happened ("Screenshot taken") comes from the
// action itself, not from here (see AppDelegate.showActionToast).
//
// Drawing only: the pill calls draw(in:) from its own draw() on the 24 fps
// heartbeat that already moves the bars, so the fades and the chip's pop
// need no timer of their own.
import AppKit

final class PillLine {

    /// How wide the line opens: about eight words of the serif.
    static let maxWidth: CGFloat = 248

    /// The words are yours, so they wear the serif, like the speech card's.
    static let font: NSFont = {
        let base = NSFont.systemFont(ofSize: 16)
        let serif = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
        return NSFont(descriptor: serif, size: 16) ?? base
    }()
    static let chipFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)

    /// Once open the line stays open for the take, even if the recognizer
    /// takes its only word back — "opens once" is the point.
    private(set) var isOpen = false

    private var raw = ""
    /// How much of `raw` (UTF-16) the stream has said twice.
    private var settled = 0
    /// Where the newest change starts, and when it arrived — those
    /// characters fade in.
    private var grewFrom = 0
    private var grewAt: CFTimeInterval = 0
    /// The grammar's reading of `raw`, kept from update() so draw() doesn't
    /// run the regexes 24 times a second.
    private var runs: [String] = []
    private var commands: [SpokenCommand] = []
    /// Commands already announced. Only a count above this lights up, so a
    /// recognizer that wobbles a command out and back in doesn't replay it.
    private var announced = 0
    /// The newest command's own words, lit, until `until`; then its chip.
    private var hit: (index: Int, words: String, until: CFTimeInterval)?
    /// When each command's chip appeared — its pop-in runs from here.
    private var chipBorn: [Int: CFTimeInterval] = [:]

    static let hitHold: CFTimeInterval = 0.5

    func reset() {
        isOpen = false
        raw = ""
        settled = 0
        grewFrom = 0
        runs = []
        commands = []
        announced = 0
        hit = nil
        chipBorn = [:]
    }

    /// The stream's words so far.
    func update(_ text: String) {
        guard text != raw else { return }
        let now = CACurrentMediaTime()
        settled = SpeechCard.settledLength(before: raw, now: text)
        let common = Self.commonWordPrefix(raw, text)
        if (text as NSString).length > common {
            grewFrom = common
            grewAt = now
        }
        raw = text
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { isOpen = true }

        if let seg = Commands.segment(text) {
            runs = seg.runs
            commands = seg.commands
        } else {
            runs = [text]
            commands = []
        }
        if commands.count > announced {
            let i = commands.count - 1
            announced = commands.count
            let words = Self.spokenWords(of: commands[i], in: text) ?? Self.label(commands[i])
            hit = (i, words, now + Self.hitHold)
            chipBorn[i] = now + Self.hitHold
        }
    }

    /// For --snapshot: every fade and pop finished, or (`lit`) caught in
    /// the moment the newest command's words are lit.
    func settleForSnapshot(lit: Bool = false) {
        grewAt = 0
        let now = CACurrentMediaTime()
        if lit, let h = hit { hit = (h.index, h.words, now + 10) } else { hit = nil }
        for k in chipBorn.keys { chipBorn[k] = now - 10 }
    }

    // MARK: Drawing

    private enum Piece {
        case words(String, fresh: Int, fading: Int)
        case hit(String, SpokenCommand)
        case chip(SpokenCommand, born: CFTimeInterval?)
    }

    private func pieces(now: CFTimeInterval) -> [Piece] {
        var out: [Piece] = []
        let rawLen = (raw as NSString).length
        for (i, run) in runs.enumerated() {
            let text = run.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                // Dim and fade only ever touch the tail of the stream, so
                // they belong to the last run; the grammar's tidying can
                // shave a character or two, hence the clamp.
                let last = i == runs.count - 1
                let n = (text as NSString).length
                out.append(.words(text, fresh: last ? min(n, rawLen - settled) : 0,
                                  fading: last ? min(n, rawLen - grewFrom) : 0))
            }
            if i < commands.count {
                if let h = hit, h.index == i, now < h.until {
                    out.append(.hit(h.words, commands[i]))
                } else {
                    out.append(.chip(commands[i], born: chipBorn[i]))
                }
            }
        }
        return out
    }

    /// `working`: the take is over and the words are being finished — the
    /// line dims a step and a soft band of light sweeps across it, so the
    /// pause reads as work in progress rather than a frozen line.
    func draw(in rect: NSRect, working: Bool = false) {
        guard isOpen, rect.width > 8, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let now = CACurrentMediaTime()
        let ps = pieces(now: now)
        let gap: CGFloat = 5
        let widths = ps.map(width(of:))
        let total = widths.reduce(0, +) + gap * CGFloat(max(0, ps.count - 1))
        let overflow = total > rect.width - 2
        // Short: from the left, like writing. Full: the newest words hug the
        // right end and the oldest slide off under the fade. (Two points
        // short of the end, so a lit command's tint has room.)
        let x0 = overflow ? rect.maxX - 2 - total : rect.minX

        ctx.saveGState()
        ctx.clip(to: rect)
        if overflow, let mask = Self.fadeMask(width: rect.width, height: rect.height) {
            ctx.clip(to: rect, mask: mask)
        }
        drawPieces(ps, widths: widths, from: x0, gap: gap, in: rect, now: now, dim: working ? 0.5 : 1)
        if working, let band = Self.bandMask(height: rect.height) {
            // The band crosses in 1.3 s, then rests a beat off the end.
            let bw = CGFloat(band.width) / 2
            let span = rect.width + bw * 2
            let u = CGFloat((now.truncatingRemainder(dividingBy: 1.7)) / 1.3)
            let bx = rect.minX - bw + min(1, u) * span
            ctx.saveGState()
            ctx.clip(to: CGRect(x: bx, y: rect.minY, width: bw, height: rect.height), mask: band)
            drawPieces(ps, widths: widths, from: x0, gap: gap, in: rect, now: now, dim: 1)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    private func drawPieces(_ ps: [Piece], widths: [CGFloat], from x0: CGFloat, gap: CGFloat,
                            in rect: NSRect, now: CFTimeInterval, dim: CGFloat) {
        var x = x0
        let baseline = rect.midY - Self.font.capHeight / 2
        for (p, w) in zip(ps, widths) {
            if x + w >= rect.minX - 1 {
                switch p {
                case .words(let s, let fresh, let fading):
                    drawWords(s, fresh: fresh, fading: fading, now: now, dim: dim,
                              at: NSPoint(x: x, y: baseline + Self.font.descender))
                case .hit(let s, let c):
                    let color = Self.color(c)
                    let box = NSRect(x: x - 2, y: rect.midY - 11, width: w + 4, height: 22)
                    color.withAlphaComponent(0.22 * dim).setFill()
                    NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
                    NSAttributedString(string: s, attributes: [.font: Self.font, .foregroundColor: color.withAlphaComponent(dim)])
                        .draw(at: NSPoint(x: x, y: baseline + Self.font.descender))
                case .chip(let c, let born):
                    drawChip(c, born: born, now: now, dim: dim, in: NSRect(x: x, y: rect.midY - 10, width: w, height: 20))
                }
            }
            x += w + gap
        }
    }

    private func width(of p: Piece) -> CGFloat {
        switch p {
        case .words(let s, _, _):
            return ceil(NSAttributedString(string: s, attributes: [.font: Self.font]).size().width)
        case .hit(let s, _):
            return ceil(NSAttributedString(string: s, attributes: [.font: Self.font]).size().width)
        case .chip(let c, _):
            return Self.chipWidth(c)
        }
    }

    /// Settled words in full ink, the recognizer's newest guesses dimmer,
    /// and whatever just arrived fading in over a quarter second.
    private func drawWords(_ s: String, fresh: Int, fading: Int, now: CFTimeInterval, dim: CGFloat, at p: NSPoint) {
        let a = NSMutableAttributedString(string: s, attributes: [
            .font: Self.font, .foregroundColor: PillView.glassInk.withAlphaComponent(dim),
        ])
        let n = a.length
        if fresh > 0 {
            a.addAttribute(.foregroundColor, value: PillView.glassMuted.withAlphaComponent(dim),
                           range: NSRange(location: n - fresh, length: fresh))
        }
        let f = CGFloat(min(1, max(0, (now - grewAt) / 0.25)))
        if fading > 0, f < 1 {
            let range = NSRange(location: n - fading, length: fading)
            a.enumerateAttribute(.foregroundColor, in: range) { value, r, _ in
                if let c = value as? NSColor {
                    a.addAttribute(.foregroundColor, value: c.withAlphaComponent(c.alphaComponent * f), range: r)
                }
            }
        }
        a.draw(at: p)
    }

    /// The chip: the action's symbol and name on a tint of its colour. It
    /// pops in on a small spring as the lit words fold away.
    private func drawChip(_ c: SpokenCommand, born: CFTimeInterval?, now: CFTimeInterval, dim: CGFloat, in r: NSRect) {
        let t = born.map { now - $0 } ?? 1
        guard t >= 0 else { return }
        let scale = 0.6 + 0.4 * Pill.spring(t, stiffness: 260, damping: 16)
        let alpha = CGFloat(min(1, t / 0.12)) * dim
        let color = Self.color(c)
        NSGraphicsContext.saveGraphicsState()
        let xf = NSAffineTransform()
        xf.translateX(by: r.midX, yBy: r.midY)
        xf.scale(by: scale)
        xf.translateX(by: -r.midX, yBy: -r.midY)
        xf.concat()
        color.withAlphaComponent(0.18 * alpha).setFill()
        NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
        if let icon = Self.icon(c) {
            icon.draw(in: NSRect(x: r.minX + 7, y: r.midY - 6.5, width: 13, height: 13),
                      from: .zero, operation: .sourceOver, fraction: alpha)
        }
        NSAttributedString(string: Self.label(c), attributes: [
            .font: Self.chipFont, .foregroundColor: color.withAlphaComponent(alpha),
        ]).draw(at: NSPoint(x: r.minX + 23, y: r.midY - Self.chipFont.capHeight / 2 + Self.chipFont.descender))
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: The actions' faces

    static func label(_ c: SpokenCommand) -> String {
        switch c {
        case .screenshot: return "Screenshot"
        case .pageURL:    return "Link"
        case .filePath:   return "File path"
        }
    }

    static func symbol(_ c: SpokenCommand) -> String {
        switch c {
        case .screenshot: return "camera"
        case .pageURL:    return "link"
        case .filePath:   return "folder"
        }
    }

    static func color(_ c: SpokenCommand) -> NSColor {
        switch c {
        case .screenshot: return PillView.skyAction
        case .pageURL:    return PillView.lilacAction
        case .filePath:   return PillView.mossBadge
        }
    }

    private static var icons: [String: NSImage] = [:]
    static func icon(_ c: SpokenCommand) -> NSImage? {
        let name = symbol(c)
        if let i = icons[name] { return i }
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            .applying(.init(paletteColors: [color(c)]))
        let img = NSImage(systemSymbolName: name, accessibilityDescription: label(c))?.withSymbolConfiguration(cfg)
        icons[name] = img
        return img
    }

    static func chipWidth(_ c: SpokenCommand) -> CGFloat {
        23 + ceil(NSAttributedString(string: label(c), attributes: [.font: chipFont]).size().width) + 9
    }

    /// The words the speaker used for the newest command of this kind, as
    /// the stream wrote them — what lights up before the chip takes over.
    private static func spokenWords(of c: SpokenCommand, in text: String) -> String? {
        let phrase: String
        switch c {
        case .screenshot: phrase = Commands.screenshotPhrase
        case .pageURL:    phrase = Commands.urlPhrase
        case .filePath:   phrase = Commands.pathPhrase
        }
        guard let re = try? NSRegularExpression(pattern: phrase, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let m = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).last else { return nil }
        return ns.substring(with: m.range).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Where `b` stops agreeing with `a`, cut back to the start of that word.
    private static func commonWordPrefix(_ a: String, _ b: String) -> Int {
        let x = a as NSString, y = b as NSString
        let n = min(x.length, y.length)
        var i = 0
        while i < n && x.character(at: i) == y.character(at: i) { i += 1 }
        if i == y.length { return i }
        while i > 0, let u = Unicode.Scalar(y.character(at: i - 1)),
              !CharacterSet.whitespacesAndNewlines.contains(u) { i -= 1 }
        return i
    }

    /// The working shimmer's band: 70 points of light, soft at both edges.
    private static var band: (height: CGFloat, image: CGImage)?
    private static func bandMask(height: CGFloat) -> CGImage? {
        let h = ceil(height)
        if let b = band, b.height == h { return b.image }
        let scale: CGFloat = 2
        let w = Int(70 * scale), ph = Int(h * scale)
        guard ph > 0, let ctx = CGContext(data: nil, width: w, height: ph, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        for col in 0..<w {
            let v = sin(Double(col) / Double(w - 1) * .pi)
            ctx.setFillColor(gray: CGFloat(v * v), alpha: 1)
            ctx.fill(CGRect(x: col, y: 0, width: 1, height: ph))
        }
        guard let img = ctx.makeImage() else { return nil }
        band = (h, img)
        return img
    }

    /// Clear to opaque across the line's first 26 points: the words that
    /// scroll off the front go soft instead of being cut. Kept for the last
    /// size asked for — the line only changes width while it opens.
    private static var mask: (size: NSSize, image: CGImage)?
    private static func fadeMask(width: CGFloat, height: CGFloat) -> CGImage? {
        let size = NSSize(width: ceil(width), height: ceil(height))
        if let m = mask, m.size == size { return m.image }
        let scale: CGFloat = 2
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        let ramp = 26 * scale
        for col in 0..<w {
            let v = min(1, CGFloat(col) / ramp)
            ctx.setFillColor(gray: v * v * (3 - 2 * v), alpha: 1)
            ctx.fill(CGRect(x: col, y: 0, width: 1, height: h))
        }
        guard let img = ctx.makeImage() else { return nil }
        mask = (size, img)
        return img
    }
}

// MARK: - The action toast

/// "Screenshot taken", "Link copied": a small glass capsule that rises out
/// of the pill when a spoken action lands mid-take, in that action's colour,
/// holds for a beat and lifts away. It rises from the pill because that's
/// where you're already looking — the HUD at the screen's foot used to say
/// these, and read as news from somewhere else.
///
/// The overlay recipe as everywhere: a fixed window that never resizes, the
/// card moving inside it, screen-saver level, click-through.
final class PillToast {
    private static let panelSize = NSSize(width: 340, height: 50)
    private static let cardH: CGFloat = 30
    /// How far the card travels as it arrives.
    private static let rise: CGFloat = 9

    private let panel: NSPanel
    private let card: NSView
    private let glass: NSView
    private let well: NSView
    private let iconView: NSImageView
    private let label: NSTextField
    private var timer: Timer?
    private var shownAt: CFTimeInterval = 0
    /// +1 rises (the pill sits below), -1 drops (the pill sits at the top).
    private var direction: CGFloat = 1
    private var restY: CGFloat = 0

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .screenSaver   // same level as the pill — see Pill.init
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)

        card = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: Self.cardH))
        card.wantsLayer = true
        glass = PillView.glassBackdrop(cornerRadius: Self.cardH / 2)
        glass.frame = card.bounds
        glass.autoresizingMask = [.width, .height]
        well = NSView(frame: NSRect(x: 6, y: 5, width: 20, height: 20))
        well.wantsLayer = true
        well.layer?.cornerRadius = 10
        iconView = NSImageView(frame: NSRect(x: 4, y: 4, width: 12, height: 12))
        iconView.imageScaling = .scaleProportionallyUpOrDown
        well.addSubview(iconView)
        label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = PillView.glassInk
        card.addSubview(glass)
        card.addSubview(well)
        card.addSubview(label)
        let root = NSView(frame: NSRect(origin: .zero, size: Self.panelSize))
        root.addSubview(card)
        panel.contentView = root
    }

    /// Rise out of `cap` — the pill's capsule in screen coordinates.
    func show(_ text: String, command: SpokenCommand, above cap: NSRect, dock: PillDock) {
        label.stringValue = text
        let textW = ceil(label.intrinsicContentSize.width)
        let w = min(6 + 20 + 7 + textW + 13, Self.panelSize.width - 20)
        well.layer?.backgroundColor = PillLine.color(command).withAlphaComponent(0.2).cgColor
        iconView.image = PillLine.icon(command)
        label.frame = NSRect(x: 33, y: (Self.cardH - 17) / 2, width: w - 33 - 12, height: 17)

        // Above the pill, or below it at the top seat, the window kept on
        // the screen (placePanel) so a corner seat can't cut the card off.
        direction = dock.vAlign == .top ? -1 : 1
        let target = pillOverlayFrame(size: NSSize(width: w, height: Self.cardH), from: cap, dock: dock, gap: 6)
        let (origin, local) = placePanel(Self.panelSize, card: target)
        panel.setFrameOrigin(origin)
        restY = local.y
        card.frame = NSRect(x: local.x, y: restY, width: w, height: Self.cardH)
        card.alphaValue = 0
        panel.orderFrontRegardless()

        shownAt = CACurrentMediaTime()
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        step()
    }

    /// In on a light spring, hold, then up and out.
    private func step() {
        let t = CACurrentMediaTime() - shownAt
        let hold: CFTimeInterval = 1.6, out: CFTimeInterval = 0.24
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var alpha: CGFloat, offset: CGFloat
        if t < hold {
            let p = still ? 1 : Pill.spring(t, stiffness: 260, damping: 20)
            alpha = CGFloat(min(1, t / 0.15))
            offset = -(1 - p) * Self.rise
        } else {
            let e = CGFloat(min(1, (t - hold) / out))
            alpha = 1 - e
            offset = still ? 0 : e * 4
        }
        card.alphaValue = alpha
        card.setFrameOrigin(NSPoint(x: card.frame.minX, y: restY + offset * direction))
        panel.invalidateShadow()
        if t >= hold + out {
            timer?.invalidate()
            timer = nil
            panel.orderOut(nil)
        }
    }
}
