// Where the pill lives, and what a click on it opens.
//
//   • PillDock: the six seats the pill can occupy — bottom corners, bottom
//     center (the classic), the two side middles, top center. Together they
//     trace an oval around the screen.
//   • DockPicker: six ghost slots at those seats. Shown while the pill is
//     dragged (drop to snap) and from the sun menu's Move button (click a
//     slot to send the pill there).
//   • SunMenu: one click on the idle pill opens a small sun over it, rays
//     out to five actions — Transcript, Polish, Email, Move, Close.
//
// Same overlay recipe as the pill (see Pill.init in main.swift): borderless
// non-activating panels at screen-saver level, dark-glass drawing.
import AppKit

// MARK: - The four seats

/// Where the pill sits: the three along the bottom and one at the top.
/// The two mid-screen side seats went in 2.3 — upright, the pill had no
/// room for the live line, the chips or a single word of a notice, so it
/// was a lesser pill there. A saved side seat moves to the corner below it
/// (see `saved(_:)`).
enum PillDock: String, CaseIterable {
    case bottomLeft   = "bottom-left"
    case bottomCenter = "bottom-center"
    case bottomRight  = "bottom-right"
    case topCenter    = "top-center"

    /// The seat a PILL_POS value names; the retired side seats land in the
    /// bottom corner on their side.
    static func saved(_ raw: String) -> PillDock {
        if let d = PillDock(rawValue: raw) { return d }
        switch raw {
        case "mid-left":  return .bottomLeft
        case "mid-right": return .bottomRight
        default:          return .bottomCenter
        }
    }

    static let sideMargin: CGFloat = 16
    /// Tucked against the Dock (or the screen's foot when the Dock hides),
    /// so the resting pill sits under your work instead of floating in it.
    /// It was 26 through 2.2.
    static let bottomMargin: CGFloat = 14

    enum HAlign { case left, center, right }
    enum VAlign { case bottom, middle, top }

    var hAlign: HAlign {
        switch self {
        case .bottomLeft:                return .left
        case .bottomCenter, .topCenter:  return .center
        case .bottomRight:               return .right
        }
    }

    var vAlign: VAlign {
        switch self {
        case .bottomLeft, .bottomCenter, .bottomRight: return .bottom
        case .topCenter:                               return .top
        }
    }

    /// The side seats stood the pill upright. None is left; the upright
    /// drawing stays behind this switch until it's cleared out.
    var isVertical: Bool { false }

    /// Align a box of `size` to this seat inside a screen's visible frame.
    /// Serves double duty: the ghost slots draw here, and the pill WINDOW
    /// takes this origin — with the capsule edge-anchored inside the window
    /// (see PillView.capsuleRect), the visible capsule lands on this same
    /// spot whatever state it's in.
    func aligned(size: NSSize, in f: NSRect) -> NSRect {
        let x: CGFloat
        switch hAlign {
        case .left:   x = f.minX + Self.sideMargin
        case .center: x = f.midX - size.width / 2
        case .right:  x = f.maxX - Self.sideMargin - size.width
        }
        let y: CGFloat
        switch vAlign {
        case .bottom: y = f.minY + Self.bottomMargin
        case .middle: y = f.midY - size.height / 2
        case .top:    y = f.maxY - Self.sideMargin - size.height
        }
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Which way the sun menu fans — degrees, 0 = right, 90 = up. Always
    /// into the screen, away from this seat's edge.
    var menuAngle: CGFloat {
        switch self {
        case .bottomCenter: return 90
        case .bottomLeft:   return 55
        case .bottomRight:  return 125
        case .topCenter:    return 270
        }
    }

    /// Corners get a narrower fan so no button dips off-screen.
    var menuSpread: CGFloat {
        self == .bottomLeft || self == .bottomRight ? 120 : 140
    }
}

/// Seat an overlay next to the capsule: above it by `gap`, flipped below
/// when the screen runs out (a top-docked pill), always clamped inside the
/// visible frame (an edge-docked pill must not push its popup off).
func overlayFrame(size: NSSize, near cap: NSRect, gap: CGFloat) -> NSRect {
    let center = NSPoint(x: cap.midX, y: cap.midY)
    let screen = NSScreen.screens.first { NSPointInRect(center, $0.frame) }
        ?? NSScreen.main ?? NSScreen.screens[0]
    let f = screen.visibleFrame
    var x = cap.midX - size.width / 2
    x = max(f.minX + 8, min(x, f.maxX - 8 - size.width))
    var y = cap.maxY + gap
    if y + size.height > f.maxY - 8 { y = cap.minY - gap - size.height }
    y = max(f.minY + 8, y)
    return NSRect(x: x, y: y, width: size.width, height: size.height)
}

// MARK: - Dock picker (the six ghost slots)

final class DockPicker {
    static let slotSize = NSSize(width: 96, height: 30)
    /// Side seats show an upright slot — the shape the pill will take there.
    static func slotBox(for dock: PillDock) -> NSSize {
        dock.isVertical ? NSSize(width: slotSize.height, height: slotSize.width) : slotSize
    }
    /// A drop or click further than this from every slot means "cancel",
    /// not "snap to whichever happens to be least far".
    static let reach: CGFloat = 130

    private let panel: NSPanel
    private let view: DockPickerView
    private var slots: [(dock: PillDock, screen: NSRect)] = []
    private var onChoose: ((PillDock?) -> Void)?
    private var hoverTimer: Timer?
    private var cancelTimer: Timer?

    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: NSSize(width: 100, height: 100)),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .screenSaver   // same level as the pill — see Pill.init
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .none
        view = DockPickerView(frame: NSRect(origin: .zero, size: panel.frame.size))
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        view.onClick = { [weak self] screenPoint in self?.finishChoose(at: screenPoint) }
    }

    /// Drag mode: ghosts only — every mouse event stays with the drag.
    func show(on screen: NSScreen, current: PillDock) {
        stopTimers()
        onChoose = nil
        view.showHint = false
        panel.ignoresMouseEvents = true
        present(on: screen, current: current)
    }

    /// Click mode (the sun menu's Move): the next click picks the nearest
    /// slot — or cancels, anywhere else.
    func choose(on screen: NSScreen, current: PillDock, onChoose: @escaping (PillDock?) -> Void) {
        stopTimers()
        self.onChoose = onChoose
        view.showHint = true
        panel.ignoresMouseEvents = false
        present(on: screen, current: current)
        // No tracking areas on a mouse-hopping screen-size panel — the same
        // cheap poll the pill uses keeps the nearest slot lit.
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
            self?.highlight(nearestTo: NSEvent.mouseLocation)
        }
        cancelTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            self?.finishChoose(at: nil)
        }
    }

    private func present(on screen: NSScreen, current: PillDock) {
        if panel.frame != screen.frame { panel.setFrame(screen.frame, display: false) }
        let f = screen.visibleFrame
        slots = PillDock.allCases.map { ($0, $0.aligned(size: Self.slotBox(for: $0), in: f)) }
        view.slots = slots.map { (dock: $0.dock, rect: $0.screen.offsetBy(dx: -screen.frame.origin.x,
                                                                          dy: -screen.frame.origin.y)) }
        view.current = current
        view.highlighted = nil
        view.needsDisplay = true
        panel.orderFrontRegardless()
    }

    /// The drag calls this on every move; choose mode's poll reuses it.
    func highlight(nearestTo p: NSPoint) {
        var hit = nearest(to: p)
        // In choose mode a pointer far from every slot lights nothing —
        // that click will cancel, and the ghosts say so by staying dim.
        if onChoose != nil && !within(reach: p) { hit = nil }
        if view.highlighted != hit {
            view.highlighted = hit
            view.needsDisplay = true
        }
    }

    /// Where a drop at `p` snaps to — nil when it's nowhere near a slot.
    func dock(at p: NSPoint) -> PillDock? {
        within(reach: p) ? nearest(to: p) : nil
    }

    func hide() {
        stopTimers()
        onChoose = nil
        panel.orderOut(nil)
    }

    private func finishChoose(at p: NSPoint?) {
        let deliver = onChoose
        let picked = p.flatMap { dock(at: $0) }
        hide()
        deliver?(picked)
    }

    private func nearest(to p: NSPoint) -> PillDock? {
        slots.min { distance(p, $0.screen) < distance(p, $1.screen) }?.dock
    }

    private func within(reach p: NSPoint) -> Bool {
        slots.contains { distance(p, $0.screen) <= Self.reach }
    }

    private func distance(_ p: NSPoint, _ r: NSRect) -> CGFloat {
        hypot(p.x - r.midX, p.y - r.midY)
    }

    private func stopTimers() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        cancelTimer?.invalidate()
        cancelTimer = nil
    }
}

/// Draws the ghost slots; in choose mode, hit-tests the picking click.
final class DockPickerView: NSView {
    var slots: [(dock: PillDock, rect: NSRect)] = []
    var current: PillDock = .bottomCenter
    var highlighted: PillDock?
    var showHint = false
    var onClick: ((NSPoint) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let w = window else { return }
        let p = convert(event.locationInWindow, from: nil)
        onClick?(NSPoint(x: w.frame.origin.x + p.x, y: w.frame.origin.y + p.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        for slot in slots {
            let radius = min(slot.rect.width, slot.rect.height) / 2
            let path = NSBezierPath(roundedRect: slot.rect, xRadius: radius, yRadius: radius)
            let vertical = slot.rect.height > slot.rect.width   // upright slots turn the mark
            if slot.dock == highlighted {
                // The seat about to be picked is the one ember thing here.
                PillView.emberBar.withAlphaComponent(0.22).setFill()
                path.fill()
                PillView.emberBar.setStroke()
                path.lineWidth = 1.5
                path.stroke()
                PillView.drawDots(in: slot.rect, vertical: vertical, ember: PillView.emberBar.withAlphaComponent(0.6), ash: PillView.emberBar.withAlphaComponent(0.6))
            } else {
                NSColor.white.withAlphaComponent(0.07).setFill()
                path.fill()
                NSColor.white.withAlphaComponent(0.32).setStroke()
                path.lineWidth = 1
                path.setLineDash([6, 4], count: 2, phase: 0)
                path.stroke()
                // The seat the pill occupies now wears its resting dots.
                if slot.dock == current { PillView.drawDots(in: slot.rect, vertical: vertical) }
            }
        }
        if showHint { drawHint() }
    }

    private func drawHint() {
        let text = NSAttributedString(
            string: "Click a spot to move the mic pill — anywhere else cancels",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
                .foregroundColor: PillView.glassInk,
            ])
        let ts = text.size()
        let card = NSRect(x: bounds.midX - ts.width / 2 - 16, y: bounds.midY - ts.height / 2 - 9,
                          width: ts.width + 32, height: ts.height + 18)
        PillView.glass.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: card, xRadius: card.height / 2, yRadius: card.height / 2).fill()
        PillView.drawGlassEdge(in: card, radius: card.height / 2)
        text.draw(at: NSPoint(x: card.midX - ts.width / 2, y: card.midY - ts.height / 2))
    }
}

// MARK: - Sun menu (one click on the idle pill)

final class SunMenu {
    enum Action { case transcript, polish, email, move, close }
    struct Item {
        let action: Action
        let symbol: String     // SF Symbol — the OS's own icon set
        let fallback: String   // drawn if the symbol is somehow missing
        let label: String
    }
    static let items: [Item] = [
        Item(action: .transcript, symbol: "doc.text",       fallback: "T", label: "Transcript"),
        Item(action: .polish,     symbol: "wand.and.stars", fallback: "✦", label: "Polish"),
        Item(action: .email,      symbol: "envelope",       fallback: "@", label: "Email"),
        Item(action: .move,       symbol: "arrow.up.and.down.and.arrow.left.and.right",
                                                            fallback: "✥", label: "Move"),
        Item(action: .close,      symbol: "xmark",          fallback: "✕", label: "Close"),
    ]
    static let panelSize = NSSize(width: 260, height: 260)
    static let radius: CGFloat = 60
    static let buttonR: CGFloat = 16

    private let panel: NSPanel
    private let view: SunMenuView
    private var hoverTimer: Timer?
    private var hideTimer: Timer?
    var onAction: ((Action) -> Void)?

    var isVisible: Bool { panel.isVisible }

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .screenSaver   // same level as the pill — see Pill.init
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        view = SunMenuView(frame: NSRect(origin: .zero, size: Self.panelSize))
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        view.onHit = { [weak self] action in self?.onAction?(action) }
    }

    /// Open around the capsule, fanning `angle`-ward (see PillDock.menuAngle).
    func show(around cap: NSRect, on screen: NSScreen, angle: CGFloat, spread: CGFloat) {
        let center = NSPoint(x: cap.midX, y: cap.midY)
        let f = screen.visibleFrame
        var frame = NSRect(x: center.x - Self.panelSize.width / 2,
                           y: center.y - Self.panelSize.height / 2,
                           width: Self.panelSize.width, height: Self.panelSize.height)
        // Clamp the window, not the sun: the sun stays glued to the capsule
        // even when the panel can't center on it at a screen edge.
        frame.origin.x = max(f.minX, min(frame.origin.x, f.maxX - frame.width))
        frame.origin.y = max(f.minY, min(frame.origin.y, f.maxY - frame.height))
        panel.setFrame(frame, display: false)
        view.layout(sun: NSPoint(x: center.x - frame.origin.x, y: center.y - frame.origin.y),
                    capsule: cap.size, angleDegrees: angle, spreadDegrees: spread)
        panel.orderFrontRegardless()
        startHoverPoll()
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    func hide() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        hideTimer?.invalidate()
        hideTimer = nil
        panel.orderOut(nil)
    }

    /// Space switches can leave a composited panel transition-scaled —
    /// re-assert, like the pill does.
    func refresh() {
        if isVisible { panel.orderFrontRegardless() }
    }

    /// Hover states without tracking areas — the pill's poll recipe.
    private func startHoverPoll() {
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let p = NSEvent.mouseLocation
            self.view.updateHover(at: NSPoint(x: p.x - self.panel.frame.origin.x,
                                              y: p.y - self.panel.frame.origin.y))
        }
    }
}

/// The rays out of the pill and the five option buttons on the arc. No
/// sun disc — the pill itself is the center the options radiate from.
final class SunMenuView: NSView {
    var onHit: ((SunMenu.Action) -> Void)?
    private var origin = NSPoint.zero
    private var capsuleHalf = NSSize(width: 28, height: 6)
    private var buttons: [(item: SunMenu.Item, center: NSPoint)] = []
    private var hovered: Int?

    /// SF Symbols tinted for the dark glass, rendered once. Index-aligned
    /// with SunMenu.items; nil falls back to the item's text glyph.
    private static let icons: [NSImage?] = SunMenu.items.map { item -> NSImage? in
        guard let base = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.label),
              let sized = base.withSymbolConfiguration(
                  NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)) else { return nil }
        let tinted = NSImage(size: sized.size, flipped: false) { rect in
            sized.draw(in: rect)
            PillView.glassInk.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return tinted
    }

    func layout(sun: NSPoint, capsule: NSSize = Pill.idleSize,
                angleDegrees: CGFloat, spreadDegrees: CGFloat) {
        origin = sun
        capsuleHalf = NSSize(width: capsule.width / 2, height: capsule.height / 2)
        let angle = angleDegrees * .pi / 180
        let spread = spreadDegrees * .pi / 180
        let n = SunMenu.items.count
        // A narrower fan (the corner seats) pushes the buttons farther out,
        // keeping the gap between neighbors constant instead of letting the
        // circles pile onto each other.
        let step = spread / CGFloat(n - 1)
        let radius = max(SunMenu.radius, (SunMenu.buttonR + 3) / sin(step / 2))
        buttons = SunMenu.items.enumerated().map { i, item in
            let a = angle + spread * (CGFloat(i) / CGFloat(n - 1) - 0.5)
            return (item, NSPoint(x: sun.x + cos(a) * radius,
                                  y: sun.y + sin(a) * radius))
        }
        hovered = nil
        needsDisplay = true
    }

    func updateHover(at p: NSPoint) {
        let hit = buttons.firstIndex { hypot(p.x - $0.center.x, p.y - $0.center.y) <= SunMenu.buttonR + 4 }
        if hit != hovered {
            hovered = hit
            needsDisplay = true
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for b in buttons where hypot(p.x - b.center.x, p.y - b.center.y) <= SunMenu.buttonR + 4 {
            onHit?(b.item.action)
            return
        }
        onHit?(.close)   // the pill itself, or the empty margin — either closes
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !buttons.isEmpty else { return }

        // One warm ray from the pill toward each option — the options
        // stream out of the icon itself; there is no sun body. Each ray
        // starts just past the capsule's edge in its direction, so an
        // upright pill (tall, thin) never gets drawn over.
        for b in buttons {
            let dx = b.center.x - origin.x, dy = b.center.y - origin.y
            let len = max(hypot(dx, dy), 1)
            let ux = dx / len, uy = dy / len
            let start = abs(ux) * capsuleHalf.width + abs(uy) * capsuleHalf.height + 8
            let end = len - SunMenu.buttonR - 5
            guard end - start > 3 else { continue }   // capsule edge already touches the button
            let path = NSBezierPath()
            path.lineWidth = 1.3
            path.lineCapStyle = .round
            path.move(to: NSPoint(x: origin.x + ux * start, y: origin.y + uy * start))
            path.line(to: NSPoint(x: origin.x + ux * end, y: origin.y + uy * end))
            // Neutral, not amber (amber means something needs you), and a
            // mid gray, so a ray reads over a white page and a dark one.
            NSColor(white: 0.55, alpha: 0.7).setStroke()
            path.stroke()
        }

        for (i, b) in buttons.enumerated() {
            let r = SunMenu.buttonR
            let circle = NSRect(x: b.center.x - r, y: b.center.y - r, width: r * 2, height: r * 2)
            let path = NSBezierPath(ovalIn: circle)
            PillView.glass.withAlphaComponent(0.96).setFill()
            path.fill()
            // The pill's glass edge, so each button holds on a white page.
            PillView.drawGlassEdge(in: circle, radius: r)
            if i == hovered {
                // The option under the pointer is the selected one: ember.
                let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 0.75, dy: 0.75))
                PillView.emberBar.setStroke()
                ring.lineWidth = 1.5
                ring.stroke()
            }

            if let icon = Self.icons[i] {
                let s = icon.size
                icon.draw(in: NSRect(x: b.center.x - s.width / 2, y: b.center.y - s.height / 2,
                                     width: s.width, height: s.height),
                          from: .zero, operation: .sourceOver, fraction: i == hovered ? 1 : 0.85)
            } else {
                let glyph = NSAttributedString(
                    string: b.item.fallback,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                        .foregroundColor: PillView.glassInk,
                    ])
                let gs = glyph.size()
                glyph.draw(at: NSPoint(x: b.center.x - gs.width / 2, y: b.center.y - gs.height / 2))
            }
        }

        // The name of just the hovered option, in a little capsule set
        // radially outward from its button — quiet until you reach for one.
        if let i = hovered {
            let b = buttons[i]
            let dx = b.center.x - origin.x, dy = b.center.y - origin.y
            let len = max(hypot(dx, dy), 1)
            let text = NSAttributedString(
                string: b.item.label,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: PillView.glassInk,
                ])
            let ts = text.size()
            let anchor = NSPoint(x: b.center.x + dx / len * (SunMenu.buttonR + 10),
                                 y: b.center.y + dy / len * (SunMenu.buttonR + 10))
            var card = NSRect(x: anchor.x - ts.width / 2 - 7, y: anchor.y - ts.height / 2 - 3,
                              width: ts.width + 14, height: ts.height + 6)
            // Shift along the ray direction so the capsule clears its button,
            // then clamp into the panel.
            card.origin.x += dx / len * (card.width / 2 - 7)
            card.origin.y += dy / len * (card.height / 2 - 3)
            card.origin.x = max(2, min(card.origin.x, bounds.width - card.width - 2))
            card.origin.y = max(2, min(card.origin.y, bounds.height - card.height - 2))
            PillView.glass.withAlphaComponent(0.96).setFill()
            NSBezierPath(roundedRect: card, xRadius: card.height / 2, yRadius: card.height / 2).fill()
            PillView.drawGlassEdge(in: card, radius: card.height / 2)
            text.draw(at: NSPoint(x: card.midX - ts.width / 2, y: card.midY - ts.height / 2))
        }
    }
}

// MARK: - Out of the pill

/// Where a notice or a picker of `size` sits: out from the pill toward the
/// middle of the screen — above a bottom seat, below the top one — `gap`
/// clear of the capsule, and on the screen whatever the seat. Every pop-up that belongs to the pill (the HUD's notices, the
/// action toast, the file picker) lands by this one rule, so they all come
/// from the same place at all four seats.
func pillOverlayFrame(size: NSSize, from cap: NSRect, dock: PillDock, gap: CGFloat) -> NSRect {
    let center = NSPoint(x: cap.midX, y: cap.midY)
    let screen = NSScreen.screens.first { NSPointInRect(center, $0.frame) } ?? NSScreen.main ?? NSScreen.screens[0]
    let f = screen.visibleFrame.insetBy(dx: 8, dy: 8)
    var x: CGFloat, y: CGFloat
    switch dock {
    case .topCenter:
        x = cap.midX - size.width / 2
        y = cap.minY - gap - size.height
    case .bottomLeft, .bottomCenter, .bottomRight:
        x = cap.midX - size.width / 2
        y = cap.maxY + gap
    }
    x = max(f.minX, min(x, f.maxX - size.width))
    y = max(f.minY, min(y, f.maxY - size.height))
    return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
}

extension PillDock {
    /// The way out of this seat, as a unit step: what a pop-up travels
    /// along as it arrives (it comes from the pill, so it starts a few
    /// points back toward it).
    var outward: CGVector {
        switch self {
        case .topCenter: return CGVector(dx: 0, dy: -1)
        case .bottomLeft, .bottomCenter, .bottomRight: return CGVector(dx: 0, dy: 1)
        }
    }
}

/// Where a fixed window of `size` goes so the card inside it lands on
/// `card`: centred on the card when it can be, but always wholly on the
/// screen, the card moving within the window instead. A window left
/// overhanging a screen edge (the corner seats) gets pulled back in by
/// macOS, and the card inside was cut off with it — a few letters of the
/// notice and nothing else.
func placePanel(_ size: NSSize, card: NSRect) -> (origin: NSPoint, local: NSPoint) {
    let center = NSPoint(x: card.midX, y: card.midY)
    let f = (NSScreen.screens.first { NSPointInRect(center, $0.frame) } ?? NSScreen.main ?? NSScreen.screens[0]).frame
    var x = card.minX - (size.width - card.width) / 2
    var y = card.minY - (size.height - card.height) / 2
    x = max(f.minX, min(x, f.maxX - size.width))
    y = max(f.minY, min(y, f.maxY - size.height))
    let origin = NSPoint(x: x.rounded(), y: y.rounded())
    return (origin, NSPoint(x: card.minX - origin.x, y: card.minY - origin.y))
}
