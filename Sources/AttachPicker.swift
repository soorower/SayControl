// The "which one did you mean?" picker: up to five newest candidates, each
// with its number, on a glass card that rises out of the pill — above a
// bottom seat, below the top one (pillOverlayFrame).
// Click one, or say "the first one" as the next dictation; the card's own
// header says so, so there is no separate notice to read somewhere else.
//
// Same overlay recipe as the pill: a fixed window that NEVER changes size
// while visible (the card inside sizes to however many candidates there
// are), screen-saver level, non-activating so a click never steals focus
// from the chat app the attachment is headed for.
import AppKit

final class AttachPicker {
    static let cell = NSSize(width: 112, height: 118)
    static let gap: CGFloat = 8
    static let pad: CGFloat = 12
    static let headH: CGFloat = 30
    /// How far the card travels as it arrives.
    static let travel: CGFloat = 12
    static let maxCard = cardSize(for: 5)
    static let panelSize = NSSize(width: maxCard.width + 2 * travel, height: maxCard.height + 2 * travel)

    static func cardSize(for n: Int) -> NSSize {
        let k = CGFloat(max(1, n))
        let cells = k * cell.width + (k - 1) * gap
        return NSSize(width: max(cells, 300) + 2 * pad, height: pad + headH + cell.height + pad)
    }

    private let panel: NSPanel
    private let card: NSView
    private let glass: NSView
    private let strip: AttachStripView
    private var onChoose: ((URL) -> Void)?
    private(set) var candidates: [URL] = []
    private var hideTimer: Timer?
    private var dock: PillDock = .bottomCenter

    private var motionTimer: Timer?
    private var motionStart: CFTimeInterval = 0
    private var leaving = false
    private var leavingThen: (() -> Void)?
    private var rest = NSPoint.zero

    var isVisible: Bool { panel.isVisible && !leaving }

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .screenSaver   // same level as the pill — see Pill.init
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        card = NSView(frame: NSRect(origin: .zero, size: Self.maxCard))
        card.wantsLayer = true
        glass = PillView.glassBackdrop(cornerRadius: 18)
        glass.frame = card.bounds
        glass.autoresizingMask = [.width, .height]
        strip = AttachStripView(frame: card.bounds)
        strip.autoresizingMask = [.width, .height]
        card.addSubview(glass)
        card.addSubview(strip)
        let root = NSView(frame: NSRect(origin: .zero, size: Self.panelSize))
        root.addSubview(card)
        panel.contentView = root
        strip.onTap = { [weak self] index in self?.choose(index + 1) }
        strip.onClose = { [weak self] in self?.hide() }
    }

    /// `title` says what the candidates are ("3 matches", "2 “zillow”
    /// folders"); the header's hint always says how to pick.
    func show(_ urls: [URL], title: String? = nil, near capsule: NSRect, dock: PillDock,
              onChoose: @escaping (URL) -> Void) {
        candidates = Array(urls.prefix(5))
        self.onChoose = onChoose
        self.dock = dock
        strip.set(candidates, title: title ?? "\(candidates.count) matches")
        leaving = false
        leavingThen = nil
        place(near: capsule)
        card.alphaValue = 0
        panel.orderFrontRegardless()
        startMotion()
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    /// 1-based, newest first; -1 means the last one shown.
    func choose(_ n: Int) {
        guard isVisible else { return }
        let index = n == -1 ? candidates.count - 1 : n - 1
        guard index >= 0, index < candidates.count else { return }
        let url = candidates[index]
        let deliver = onChoose
        strip.picked = index
        hide()
        deliver?(url)
    }

    /// Someone spoke without saying which: the hint lights up and the card
    /// gives a small nod toward it.
    func nudge() {
        guard isVisible else { return }
        strip.nudge()
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        candidates = []
        onChoose = nil
        guard panel.isVisible, !leaving else { return }
        leaving = true
        startMotion()
    }

    func reposition(near capsule: NSRect, dock: PillDock) {
        guard isVisible else { return }
        self.dock = dock
        place(near: capsule)
    }

    /// The window goes where the card's resting spot comes out right, with
    /// room to travel and the window itself on the screen (placePanel).
    private func place(near capsule: NSRect) {
        let size = Self.cardSize(for: candidates.count)
        let target = pillOverlayFrame(size: size, from: capsule, dock: dock, gap: 12)
        let (origin, local) = placePanel(Self.panelSize, card: target)
        // Same rule as the pill: only move when the target really changed.
        if abs(panel.frame.origin.x - origin.x) > 0.5 || abs(panel.frame.origin.y - origin.y) > 0.5 {
            panel.setFrameOrigin(origin)
        }
        rest = local
        card.frame = NSRect(origin: local, size: size)
        panel.invalidateShadow()
    }

    /// Space switches can leave a composited panel transition-scaled —
    /// re-assert, like the pill does.
    func refresh() {
        if isVisible { panel.orderFrontRegardless() }
    }

    // MARK: Motion

    private func startMotion() {
        motionStart = CACurrentMediaTime()
        strip.entranceStart = leaving ? nil : motionStart
        if motionTimer == nil {
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.stepMotion() }
            RunLoop.main.add(t, forMode: .common)
            motionTimer = t
        }
        stepMotion()
    }

    /// In: the card rises out of the pill on a light spring and the cells
    /// follow one after another. Out: a short fade drifting on the same way.
    private func stepMotion() {
        let t = CACurrentMediaTime() - motionStart
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let out = dock.outward
        var alpha: CGFloat, along: CGFloat
        if leaving {
            let e = CGFloat(min(1, t / 0.2))
            alpha = 1 - e
            along = still ? 0 : e * 5
        } else {
            alpha = CGFloat(min(1, t / 0.16))
            along = still ? 0 : -(1 - Pill.spring(t, stiffness: 230, damping: 21)) * Self.travel
        }
        card.alphaValue = alpha
        card.setFrameOrigin(NSPoint(x: rest.x + out.dx * along, y: rest.y + out.dy * along))
        strip.needsDisplay = true
        panel.invalidateShadow()
        let done = leaving ? t >= 0.2 : t >= 0.75
        guard done else { return }
        motionTimer?.invalidate()
        motionTimer = nil
        if leaving {
            leaving = false
            panel.orderOut(nil)
            strip.picked = nil
        }
    }
}

/// Draws the header and the candidate cells; hit-tests taps back to an
/// index. Card-local: the glass is its sibling underneath.
final class AttachStripView: NSView {
    var onTap: ((Int) -> Void)?
    var onClose: (() -> Void)?
    /// When the entrance began — the cells arrive one after another from
    /// here. nil once there's nothing left to animate.
    var entranceStart: CFTimeInterval?
    /// The cell just chosen, lit while the card leaves.
    var picked: Int? { didSet { needsDisplay = true } }
    private var items: [(thumb: NSImage, name: String)] = []
    private var title = ""
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var closeHovered = false { didSet { if closeHovered != oldValue { needsDisplay = true } } }
    private var nudgedAt: CFTimeInterval = 0
    private var nudgeTimer: Timer?

    static let titleFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    static let hintFont = NSFont.systemFont(ofSize: 11.5, weight: .regular)
    static let nameFont = NSFont.systemFont(ofSize: 10.5, weight: .medium)
    static let hint = "Say \u{201C}the first one\u{201D} or click"

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func set(_ urls: [URL], title: String) {
        items = urls.map { (Self.thumbnail($0), $0.lastPathComponent) }
        self.title = title
        hovered = nil
        picked = nil
        needsDisplay = true
    }

    func nudge() {
        nudgedAt = CACurrentMediaTime()
        nudgeTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            self.needsDisplay = true
            if CACurrentMediaTime() - self.nudgedAt > 1.2 { timer.invalidate() }
        }
        RunLoop.main.add(t, forMode: .common)
        nudgeTimer = t
    }

    private var closeRect: NSRect {
        NSRect(x: bounds.maxX - AttachPicker.pad - 20, y: bounds.maxY - AttachPicker.pad - 20 + 1, width: 20, height: 20)
    }

    /// Frames of the cells, centred under the header.
    private var cellFrames: [NSRect] {
        let n = CGFloat(items.count)
        guard n > 0 else { return [] }
        let c = AttachPicker.cell, g = AttachPicker.gap
        let total = n * c.width + (n - 1) * g
        let x0 = (bounds.width - total) / 2
        return (0..<items.count).map { i in
            NSRect(x: x0 + CGFloat(i) * (c.width + g), y: AttachPicker.pad, width: c.width, height: c.height)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hovered = cellFrames.firstIndex(where: { $0.contains(p) })
        closeHovered = closeRect.insetBy(dx: -4, dy: -4).contains(p)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        closeHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if closeRect.insetBy(dx: -4, dy: -4).contains(p) {
            onClose?()
            return
        }
        if let index = cellFrames.firstIndex(where: { $0.contains(p) }) {
            onTap?(index)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !items.isEmpty else { return }
        let now = CACurrentMediaTime()
        let pad = AttachPicker.pad

        // Header: what these are, and how to pick one.
        let headMid = bounds.maxY - pad - AttachPicker.headH / 2 + 3
        let titleStr = NSAttributedString(string: title, attributes: [.font: Self.titleFont, .foregroundColor: PillView.glassInk])
        titleStr.draw(at: NSPoint(x: pad + 2, y: headMid - Self.titleFont.capHeight / 2 + Self.titleFont.descender))
        // A nudge warms the hint to amber and back.
        let n = max(0, 1 - (now - nudgedAt) / 1.2)
        let warm = CGFloat(n > 0 ? sin(n * .pi) : 0)
        let hintColor = PillView.glassMuted.blended(withFraction: warm, of: PillView.amberBadge) ?? PillView.glassMuted
        let hintX = pad + 2 + ceil(titleStr.size().width) + 10
        let hintW = closeRect.minX - 8 - hintX
        if hintW > 40 {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            NSAttributedString(string: Self.hint, attributes: [
                .font: Self.hintFont, .foregroundColor: hintColor, .paragraphStyle: style,
            ]).draw(in: NSRect(x: hintX, y: headMid - Self.hintFont.capHeight / 2 + Self.hintFont.descender,
                               width: hintW, height: 16))
        }

        // ✕ — dismiss without choosing.
        let close = closeRect
        NSColor.white.withAlphaComponent(closeHovered ? 0.18 : 0.08).setFill()
        NSBezierPath(ovalIn: close).fill()
        let cross = NSBezierPath()
        cross.lineWidth = 1.4
        cross.lineCapStyle = .round
        let inset: CGFloat = 6.5
        cross.move(to: NSPoint(x: close.minX + inset, y: close.minY + inset))
        cross.line(to: NSPoint(x: close.maxX - inset, y: close.maxY - inset))
        cross.move(to: NSPoint(x: close.minX + inset, y: close.maxY - inset))
        cross.line(to: NSPoint(x: close.maxX - inset, y: close.minY + inset))
        PillView.glassInk.withAlphaComponent(closeHovered ? 0.95 : 0.6).setStroke()
        cross.stroke()

        for (i, base) in cellFrames.enumerated() {
            // Each cell arrives a beat after the one before it.
            var alpha: CGFloat = 1, lift: CGFloat = 0
            if let s = entranceStart {
                let t = now - s - 0.06 - Double(i) * 0.035
                alpha = CGFloat(min(1, max(0, t / 0.18)))
                lift = -(1 - Pill.spring(max(0, t), stiffness: 260, damping: 20)) * 6
            }
            guard alpha > 0 else { continue }
            let hot = hovered == i || picked == i
            let frame = base.offsetBy(dx: 0, dy: lift + (hot ? 2 : 0))
            let item = items[i]
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setAlpha(alpha)

            let thumbBox = NSRect(x: frame.minX, y: frame.minY + 22, width: frame.width, height: frame.height - 22)
            let box = NSBezierPath(roundedRect: thumbBox, xRadius: 10, yRadius: 10)
            NSColor.white.withAlphaComponent(hot ? 0.13 : 0.06).setFill()
            box.fill()
            if hot {
                PillView.voiceEmber.withAlphaComponent(0.8).setStroke()
                box.lineWidth = 1.5
                box.stroke()
            }
            let size = item.thumb.size
            if size.width > 0, size.height > 0 {
                let inner = thumbBox.insetBy(dx: 6, dy: 6)
                let scale = min(inner.width / size.width, inner.height / size.height, 1.5)
                let w = size.width * scale, h = size.height * scale
                let rect = NSRect(x: inner.midX - w / 2, y: inner.midY - h / 2, width: w, height: h)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).addClip()
                item.thumb.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                NSGraphicsContext.restoreGraphicsState()
            }
            // The number to say, as a key on the thumb's corner.
            let key = NSRect(x: thumbBox.minX + 6, y: thumbBox.maxY - 6 - PillView.keyCap,
                             width: PillView.keyCap, height: PillView.keyCap)
            NSColor.black.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: key, xRadius: 4, yRadius: 4).fill()
            PillView.drawKey("\(i + 1)", in: key)
            // The name under the thumb.
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byTruncatingMiddle
            NSAttributedString(string: item.name, attributes: [
                .font: Self.nameFont,
                .foregroundColor: PillView.glassInk.withAlphaComponent(hot ? 0.95 : 0.72),
                .paragraphStyle: style,
            ]).draw(in: NSRect(x: frame.minX + 2, y: frame.minY + 3, width: frame.width - 4, height: 15))
            NSGraphicsContext.restoreGraphicsState()
        }
        if let s = entranceStart, now - s > 0.8 { entranceStart = nil }
    }

    /// Small, fast previews: real thumbnails for images, the Finder icon
    /// for everything else.
    static func thumbnail(_ url: URL) -> NSImage {
        let ext = url.pathExtension.lowercased()
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff", "bmp"]
        if imageExts.contains(ext),
           let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceThumbnailMaxPixelSize: 220,
               kCGImageSourceCreateThumbnailWithTransform: true,
           ] as CFDictionary) {
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 64, height: 64)
        return icon
    }
}
