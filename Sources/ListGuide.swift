// The helper Set Up shows while the user is over in System Settings, option A
// of design/permission-guide-options.html: a tray slides out from under the
// System Settings window, right below the list, holding SayControl's icon to
// drag in and one line saying so. A click-through overlay draws the way: every
// few seconds a hand picks the icon up and glides it along a dotted path into
// the list. The tray stays glued to the window when it moves, steps aside
// while another app is in front, and once the switch takes it shows a tick,
// slides back under the window and hands the user back to SayControl.
import Cocoa

// MARK: - System Settings' window

/// Where System Settings' window is. Its frame comes from the window list
/// with no permission at all (only a window's title needs Screen Recording);
/// what is inside it can't be seen without Accessibility, the very grant
/// being asked for, so the list's place is read off the window's shape.
enum SettingsWindow {
    static let bundleID = "com.apple.systempreferences"

    /// macOS's own consent prompts: the password a switch asks for, and
    /// Apple's "would like to control this computer" alert. The tray and the
    /// hand go away while one is in front, so nothing of ours is ever drawn
    /// over, beside or moving near a prompt that is asking the user to
    /// decide; they come back with System Settings.
    static let consentPrompts: Set<String> = ["com.apple.SecurityAgent",
                                              "com.apple.accessibility.universalAccessAuthWarn"]

    /// Its front window: the id, to follow it cheaply, and its frame in
    /// AppKit's screen coordinates.
    static func find() -> (id: CGWindowID, frame: NSRect)? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        // Front to back: the first window of a real size on the normal level.
        for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == pid
            && (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let id = w[kCGWindowNumber as String] as? CGWindowID, let f = frame(w),
                  f.width > 300, f.height > 200 else { continue }
            return (id, f)
        }
        return nil
    }

    /// One window's frame by id, the check made every frame while it is
    /// followed. Nil once it is closed, minimised or on another Space.
    static func frame(of id: CGWindowID) -> NSRect? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let w = list.first, (w[kCGWindowIsOnscreen as String] as? Bool) == true else { return nil }
        return frame(w)
    }

    private static func frame(_ w: [String: Any]) -> NSRect? {
        guard let dict = w[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return nil }
        // The window list counts down from the top of the primary display.
        let top = NSScreen.screens.first?.frame.maxY ?? r.maxY
        return NSRect(x: r.minX, y: top - r.maxY, width: r.width, height: r.height)
    }

    /// The list's column: Privacy & Security keeps its sidebar down the left
    /// third and the list in the rest.
    static func listColumn(_ f: NSRect) -> NSRect {
        let side = f.width >= 560 ? min(max(f.width * 0.31, 190), 250) : 0
        return NSRect(x: f.minX + side, y: f.minY, width: f.width - side, height: f.height)
    }

    /// Where a dropped icon lands: the top rows of the list.
    static func dropPoint(_ f: NSRect) -> NSPoint {
        NSPoint(x: listColumn(f).midX, y: f.maxY - min(170, f.height * 0.45))
    }
}

// MARK: - The icon

/// The app's icon, draggable. System Settings' privacy lists take a dropped
/// app: it goes in switched on, once macOS has the password.
final class DraggableAppIcon: NSImageView, NSDraggingSource {
    /// True when a drag begins, false when it ends, wherever it landed.
    var onDrag: ((Bool) -> Void)?
    /// Picked up: the glide is carrying it, or the user is.
    var lifted = false { didSet { if lifted != oldValue { restyle() } } }
    private var hovering = false { didSet { if hovering != oldValue { restyle() } } }

    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext)
        -> NSDragOperation { [.copy, .link, .generic] }
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) { onDrag?(true) }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDrag?(false)
    }
    // The tray is a panel of an app in the background: the first click has
    // to count, and the pointer has to change without the app in front.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func cursorUpdate(with event: NSEvent) { NSCursor.openHand.set() }

    /// Lifted: faded and a size down, the way a picked-up icon leaves its
    /// spot. Pointed at: up a little, a size up. 0.2 s either way.
    private func restyle() {
        guard let layer = layer else { return }
        let (scale, dy): (CGFloat, CGFloat) = lifted ? (0.94, 0) : hovering ? (1.04, 2) : (1, 0)
        let b = bounds
        var t = CATransform3DMakeTranslation(b.midX, b.midY + dy, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        t = CATransform3DTranslate(t, -b.midX, -b.midY, 0)
        let move = CABasicAnimation(keyPath: "transform")
        move.fromValue = layer.presentation()?.transform ?? layer.transform
        move.toValue = t
        move.duration = Motion.reduced ? 0 : 0.25
        move.timingFunction = Motion.pop
        layer.add(move, forKey: "lift")
        layer.transform = t
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            animator().alphaValue = lifted ? 0.35 : 1
        }
    }
}

// MARK: - The tray

/// A few words that act on a click, in a panel of an app that isn't in front.
private final class TrayClickable: NSView {
    let field: NSTextField
    var onClick: () -> Void = {}
    private let underline: Bool
    private var hovering = false { didSet { if hovering != oldValue { restyle() } } }
    private let color: NSColor, hoverColor: NSColor

    init(_ text: String, size: CGFloat, color: NSColor, hover: NSColor, underline: Bool) {
        field = Theme.text(text, size, .regular, color)
        self.color = color
        self.hoverColor = hover
        self.underline = underline
        super.init(frame: .zero)
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.topAnchor.constraint(equalTo: topAnchor),
            field.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    var text: String {
        get { field.stringValue }
        set { field.stringValue = newValue; restyle() }
    }
    private func restyle() {
        field.attributedStringValue = NSAttributedString(string: field.stringValue, attributes: [
            .font: field.font as Any, .foregroundColor: hovering ? hoverColor : color,
            .underlineStyle: hovering && underline ? NSUnderlineStyle.single.rawValue : 0,
        ])
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// The dashed spot the icon sits in: ember wash, ember dashes.
private final class IconWell: NSView {
    private let dashes = CAShapeLayer()
    private static let ring = Theme.dyn(Theme.hex(0xE5501F, 0.45), Theme.hex(0xFF6A3D, 0.5))

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Theme.px(16)
        dashes.fillColor = nil
        dashes.lineWidth = 1.5
        dashes.lineDashPattern = [4.5, 3.5]
        layer?.addSublayer(dashes)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let r = Theme.px(16)
        dashes.frame = bounds
        dashes.path = CGPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), cornerWidth: r - 0.75, cornerHeight: r - 0.75,
                             transform: nil)
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Theme.emberSoft.cgColor
        dashes.strokeColor = Self.ring.cgColor
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// The tray's face: the icon in its well, one line of what to do, one of
/// what follows, and "Already in the list?" for a switch that reads on but
/// doesn't work. Once the switch takes, a tick in their place.
final class TrayCard: NSView {
    let icon = DraggableAppIcon()
    var onClose: () -> Void = {}
    /// The fix line opened or shut, so the tray's height changed.
    var onResize: () -> Void = {}
    /// Pointed at, or left: the glide holds still while the pointer is here.
    var onHover: (Bool) -> Void = { _ in }
    /// Square-topped under the window; rounded all round when there is no
    /// room under it and the tray sits over the window's foot instead.
    var tucked = true { didSet { if tucked != oldValue { needsDisplay = true } } }

    private let row = NSStackView()
    private let well = IconWell()
    private let column = NSStackView()
    private let link = TrayClickable("Already in the list?", size: 12, color: Theme.emberInk, hover: Theme.emberInk, underline: true)
    private let fix: NSTextField
    private var plainFix = NSAttributedString()
    private let ok = NSStackView()
    private var columnWidth: NSLayoutConstraint!
    private static let top: CGFloat = 14, left: CGFloat = 16, bottom: CGFloat = 16, right: CGFloat = 40

    override init(frame: NSRect) {
        let words = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: Theme.px(12)), .foregroundColor: Theme.ink2]
        words.append(NSAttributedString(string: "Select it, click ", attributes: body))
        words.append(NSAttributedString(string: " − ", attributes: [
            .font: NSFont.systemFont(ofSize: Theme.px(12), weight: .semibold), .foregroundColor: Theme.ink,
            .backgroundColor: Theme.wellFill,
        ]))
        words.append(NSAttributedString(string: ", then drag it in again.", attributes: body))
        fix = Theme.para("", 12, .regular, Theme.ink2, lineHeight: 1.45)
        fix.attributedStringValue = words
        plainFix = words
        super.init(frame: frame)
        wantsLayer = true

        let side = Theme.px(78), art = Theme.px(58)
        well.translatesAutoresizingMaskIntoConstraints = false
        well.widthAnchor.constraint(equalToConstant: side).isActive = true
        well.heightAnchor.constraint(equalToConstant: side).isActive = true
        icon.image = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        icon.image?.size = NSSize(width: art, height: art)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.18)
            s.shadowBlurRadius = 6
            s.shadowOffset = NSSize(width: 0, height: -3)
            return s
        }()
        icon.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(icon)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: art),
            icon.heightAnchor.constraint(equalToConstant: art),
            icon.centerXAnchor.constraint(equalTo: well.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: well.centerYAnchor),
        ])

        // "↑ Drag SayControl into the list": the arrow says which way before
        // the words do.
        let arrow = Theme.text("↑", 15, .semibold, Theme.ember)
        let title = Theme.text("Drag SayControl into the list", 15, .semibold, Theme.ink)
        title.attributedStringValue = NSAttributedString(string: title.stringValue, attributes: [
            .font: NSFont.systemFont(ofSize: Theme.px(15), weight: .semibold), .foregroundColor: Theme.ink,
            .kern: -0.015 * Theme.px(15),
        ])
        let titleRow = Theme.hstack([arrow, title], spacing: Theme.px(7))
        let sub = Theme.para("macOS asks for your password, then it’s on.", 12.5, .regular, Theme.muted, lineHeight: 1.4)
        link.onClick = { [weak self] in self?.toggleFix() }
        fix.isHidden = true
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Theme.px(3)
        for v in [titleRow, sub, link, fix] as [NSView] { column.addArrangedSubview(v) }
        column.setCustomSpacing(Theme.px(7), after: sub)
        column.setCustomSpacing(Theme.px(6), after: link)
        column.translatesAutoresizingMaskIntoConstraints = false
        columnWidth = column.widthAnchor.constraint(equalToConstant: 200)
        columnWidth.isActive = true
        for v in [sub, fix] { v.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }

        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Theme.px(16)
        row.addArrangedSubview(well)
        row.addArrangedSubview(column)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        // The tick: what the tray says for the moment before it goes.
        let check = ColorView(color: Theme.moss, radius: Theme.px(14))
        let mark = NSImageView(image: Theme.symbol("checkmark", Theme.px(13), .bold) ?? NSImage())
        mark.contentTintColor = .white
        mark.translatesAutoresizingMaskIntoConstraints = false
        check.addSubview(mark)
        check.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            check.widthAnchor.constraint(equalToConstant: Theme.px(28)),
            check.heightAnchor.constraint(equalToConstant: Theme.px(28)),
            mark.centerXAnchor.constraint(equalTo: check.centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: check.centerYAnchor),
        ])
        let okTitle = Theme.text("SayControl is on", 15, .semibold, Theme.ink)
        let okSub = Theme.text("Taking you back…", 12.5, .regular, Theme.muted)
        let okWords = Theme.vstack([okTitle, okSub], spacing: Theme.px(1))
        ok.orientation = .horizontal
        ok.alignment = .centerY
        ok.spacing = Theme.px(10)
        ok.addArrangedSubview(check)
        ok.addArrangedSubview(okWords)
        ok.isHidden = true
        ok.translatesAutoresizingMaskIntoConstraints = false
        addSubview(ok)

        let close = TrayClickable("×", size: 15, color: Theme.faint, hover: Theme.ink2, underline: false)
        close.toolTip = "Close"
        close.onClick = { [weak self] in self?.onClose() }
        close.translatesAutoresizingMaskIntoConstraints = false
        addSubview(close)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: Theme.px(Self.top)),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.px(Self.left)),
            ok.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.px(Self.left + 8)),
            ok.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.topAnchor.constraint(equalTo: topAnchor, constant: Theme.px(8)),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.px(12)),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The width the tray is drawn at; the words wrap inside what is left.
    func setWidth(_ w: CGFloat) {
        let c = w - Theme.px(Self.left + 78 + 16 + Self.right)
        if abs(columnWidth.constant - c) > 0.5 { columnWidth.constant = c }
    }
    /// How tall the tray is at the width it was given.
    var fittingHeight: CGFloat {
        row.layoutSubtreeIfNeeded()
        return (row.fittingSize.height + Theme.px(Self.top + Self.bottom)).rounded()
    }

    /// Back to the ask, the fix line shut: a new Set Up click.
    func reset() {
        row.isHidden = false
        ok.isHidden = true
        fix.isHidden = true
        fix.attributedStringValue = plainFix
        link.text = "Already in the list?"
        icon.lifted = false
    }

    /// The tick, rising into the space the ask leaves.
    func showDone() {
        row.isHidden = true
        ok.isHidden = false
        Motion.rise(ok, duration: 0.35, distance: Theme.px(3))
    }

    private func toggleFix() {
        fix.isHidden.toggle()
        link.text = fix.isHidden ? "Already in the list?" : "Hide"
        if !fix.isHidden { Motion.rise(fix, duration: 0.3, distance: Theme.px(3)) }
        onResize()
    }

    /// The switch still hasn't taken after a drag, a password or a while:
    /// macOS is most likely holding an entry an older copy left in the list,
    /// which reads on and doesn't count. The fix opens by itself, saying why.
    func offerFix() {
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: Theme.px(12)), .foregroundColor: Theme.ink2]
        let strong: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: Theme.px(12), weight: .semibold),
                                                     .foregroundColor: Theme.ink]
        let words = NSMutableAttributedString()
        words.append(NSAttributedString(string: "Still off? ", attributes: strong))
        words.append(NSAttributedString(string: "The list may hold an older copy of SayControl. Select it, click ", attributes: body))
        words.append(NSAttributedString(string: " − ", attributes: strong.merging([.backgroundColor: Theme.wellFill]) { $1 }))
        words.append(NSAttributedString(string: ", then drag it in again.", attributes: body))
        fix.attributedStringValue = words
        if fix.isHidden { toggleFix() }
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
    override var mouseDownCanMoveWindow: Bool { false }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        guard let layer = layer else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer.backgroundColor = Theme.surface.cgColor
        layer.borderColor = (dark ? Theme.hex(0x34343A) : Theme.hairline).cgColor
        layer.borderWidth = 1
        layer.cornerRadius = Theme.px(16)
        // Layer corners count from the bottom: the two that show under the
        // window, or all four when it sits over the window's foot.
        layer.maskedCorners = tucked ? [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            : [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        layer.shadowColor = Theme.hex(0x141822).cgColor
        layer.shadowOpacity = dark ? 0.55 : 0.16
        layer.shadowRadius = 18
        layer.shadowOffset = CGSize(width: 0, height: -14)
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: - The glide

/// What the click-through overlay draws: the dotted path from the tray's
/// icon into the list with an arrowhead at its tip, a ghost of the icon and
/// a hand carrying it, and a ring where it lands.
private final class GlidePath: NSView {
    private let trail = CAShapeLayer(), head = CAShapeLayer(), ripple = CAShapeLayer()
    private let ghost = CALayer(), hand = CALayer()
    private let handHotSpot: NSPoint
    private let handSize: NSSize

    override init(frame: NSRect) {
        let cursor = NSCursor.pointingHand
        handHotSpot = cursor.hotSpot
        handSize = cursor.image.size
        super.init(frame: frame)
        wantsLayer = true
        trail.fillColor = nil
        trail.lineWidth = 2.4
        trail.lineCap = .round
        trail.lineDashPattern = [2, 7]
        ripple.fillColor = nil
        ripple.lineWidth = 2
        ripple.path = CGPath(ellipseIn: CGRect(x: -10, y: -10, width: 20, height: 20), transform: nil)
        ghost.bounds = CGRect(x: 0, y: 0, width: 56, height: 56)
        ghost.contents = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        ghost.contentsGravity = .resizeAspect
        ghost.shadowColor = NSColor.black.cgColor
        ghost.shadowOpacity = 0.28
        ghost.shadowRadius = 8
        ghost.shadowOffset = CGSize(width: 0, height: -10)
        hand.bounds = CGRect(origin: .zero, size: handSize)
        hand.contents = cursor.image
        // The fingertip is what sits on the icon.
        hand.anchorPoint = CGPoint(x: handHotSpot.x / handSize.width, y: 1 - handHotSpot.y / handSize.height)
        for l in [trail, head, ripple, ghost, hand] { layer?.addSublayer(l) }
        clear()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        trail.strokeColor = Theme.ember.cgColor
        head.fillColor = Theme.ember.cgColor
        ripple.strokeColor = Theme.ember.cgColor
        let scale = window?.backingScaleFactor ?? 2
        for l in [trail, head, ripple, ghost, hand] { l.contentsScale = scale }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    func clear() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trail.path = nil
        head.path = nil
        for l in [ghost, hand, ripple] { l.opacity = 0 }
        CATransaction.commit()
    }

    /// Reduce Motion: the whole path, still.
    func still(from s: NSPoint, to e: NSPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let c = Self.control(s, e)
        trail.path = Self.path(s, c, e, upto: 1)
        head.path = Self.arrow(s, c, e, at: 1)
        trail.opacity = 1
        head.opacity = 1
        for l in [ghost, hand, ripple] { l.opacity = 0 }
        CATransaction.commit()
    }

    /// One frame of the loop, `t` milliseconds in: 0–400 the hand arrives on
    /// the icon, 400–600 it presses, 600–1900 the glide, 1900–2250 the drop,
    /// then the path fades and everything rests until the next one.
    func frame(at t: Double, from s: NSPoint, to e: NSPoint) {
        func clamp(_ v: Double) -> Double { max(0, min(1, v)) }
        func ease(_ v: Double) -> Double { v < 0.5 ? 4 * v * v * v : 1 - pow(-2 * v + 2, 3) / 2 }
        let handIn = clamp(t / 400), press = clamp((t - 400) / 200)
        let glide = ease(clamp((t - 600) / 1300)), drop = clamp((t - 1900) / 350), out = clamp((t - 2250) / 500)
        let c = Self.control(s, e)
        let p = Self.point(s, c, e, glide)
        let arc = sin(glide * .pi)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ghost.position = p
        ghost.opacity = t < 450 ? 0 : Float((1 - drop) * 0.92)
        let size = CGFloat((1 - drop * 0.45) * (1 + 0.06 * arc))
        ghost.transform = CATransform3DRotate(CATransform3DMakeScale(size, size, 1), CGFloat(6 * arc * .pi / 180), 0, 0, 1)
        hand.position = NSPoint(x: p.x + 10, y: p.y - 8)
        hand.opacity = Float(handIn * (1 - drop))
        let squeeze = CGFloat(1 - 0.12 * press * (1 - drop))
        hand.transform = CATransform3DMakeScale(squeeze, squeeze, 1)
        if t >= 600 {
            trail.path = Self.path(s, c, e, upto: glide)
            head.path = glide > 0.05 ? Self.arrow(s, c, e, at: glide) : nil
            trail.opacity = Float(1 - out)
            head.opacity = Float(1 - out)
        } else {
            trail.path = nil
            head.path = nil
        }
        ripple.position = e
        ripple.opacity = drop > 0 && drop < 1 ? Float(1 - drop) : 0
        let ring = CGFloat(1 + drop * 2.6)
        ripple.transform = CATransform3DMakeScale(ring, ring, 1)
        CATransaction.commit()
    }

    // A quadratic curve that leaves the icon heading up and bends toward the
    // list: the control point sits above the start, a third of the way back
    // from the end.
    private static func control(_ s: NSPoint, _ e: NSPoint) -> NSPoint {
        NSPoint(x: s.x + (e.x - s.x) * 0.1, y: e.y + (s.y - e.y) * 0.35)
    }
    private static func point(_ s: NSPoint, _ c: NSPoint, _ e: NSPoint, _ t: Double) -> NSPoint {
        let u = CGFloat(1 - t), v = CGFloat(t)
        return NSPoint(x: u * u * s.x + 2 * u * v * c.x + v * v * e.x,
                       y: u * u * s.y + 2 * u * v * c.y + v * v * e.y)
    }
    private static func path(_ s: NSPoint, _ c: NSPoint, _ e: NSPoint, upto: Double) -> CGPath {
        let p = CGMutablePath()
        p.move(to: s)
        for i in 1...40 { p.addLine(to: point(s, c, e, upto * Double(i) / 40)) }
        return p
    }
    private static func arrow(_ s: NSPoint, _ c: NSPoint, _ e: NSPoint, at t: Double) -> CGPath {
        let tip = point(s, c, e, t), back = point(s, c, e, max(0, t - 0.02))
        let a = atan2(tip.y - back.y, tip.x - back.x)
        func at(_ d: CGFloat, _ o: CGFloat) -> NSPoint {
            NSPoint(x: tip.x - cos(a) * d + cos(a + .pi / 2) * o, y: tip.y - sin(a) * d + sin(a + .pi / 2) * o)
        }
        let p = CGMutablePath()
        p.addLines(between: [tip, at(11, 6), at(11, -6)])
        p.closeSubpath()
        return p
    }
}

// MARK: - The helper

/// The tray under System Settings' window and the overlay drawing the way,
/// for one grant at a time. Set Up shows it on every click; it goes when the
/// grant lands, on its ×, or when the setup that opened it closes.
final class DragToListPanel {
    static let shared = DragToListPanel()

    private var grant: Permissions.Listed?
    private var granted: (() -> Void)?
    /// `--guide-preview`: shown without asking macOS, never "granted", and
    /// the × quits.
    private var preview = false

    private let card = TrayCard()
    private var tray: NSPanel?
    private var overlay: NSPanel?
    private let glide = GlidePath()

    private var tick: Timer?
    private var ticks = 0
    private var windowID: CGWindowID?
    private var lastSearch = Date.distantPast
    private var settings: NSRect?
    /// The tray is out under the window.
    private var out = false
    private var done = false
    private var paused = false
    private var dragging = false
    private var loopStart: CFTimeInterval = 0
    private static let period: CFTimeInterval = 3.8
    /// When the fix should open by itself if the switch still hasn't taken:
    /// a while after Set Up, sooner after a drag or a password prompt.
    private var offerAt = Date.distantFuture
    private var offered = false
    private var lastFront = ""

    /// A Set Up is under way: the tray is out, or waiting for System
    /// Settings to come to the front.
    var isActive: Bool { grant != nil }
    var isVisible: Bool { tray?.isVisible ?? false }

    func show(for grant: Permissions.Listed, preview: Bool = false, granted: (() -> Void)? = nil) {
        if tray == nil { build() }
        self.grant = grant
        self.granted = granted
        self.preview = preview
        done = false
        paused = false
        dragging = false
        card.reset()
        offered = false
        offerAt = Date().addingTimeInterval(20)
        windowID = nil
        lastSearch = .distantPast
        // A second click while it is out starts the glide over, not the tray.
        loopStart = CACurrentMediaTime() + 0.5
        if tick == nil {
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.step() }
            RunLoop.main.add(t, forMode: .common)
            tick = t
        }
        step()
    }

    func hide() {
        tick?.invalidate()
        tick = nil
        grant = nil
        granted = nil
        out = false
        glide.clear()
        tray?.orderOut(nil)
        overlay?.orderOut(nil)
    }

    /// `--snapshot`: the tray's face at a typical width, never put on screen.
    func face(done: Bool = false) -> NSView {
        let card = TrayCard()
        card.setWidth(Theme.px(440))
        card.frame = NSRect(x: 0, y: 0, width: Theme.px(440), height: card.fittingHeight)
        if done { card.showDone() }
        return card
    }

    // MARK: Every frame

    private func step() {
        guard let grant = grant, let tray = tray, let overlay = overlay else { return }
        ticks += 1
        if !done, !preview, ticks % 30 == 0, grant.granted { return succeed() }
        if preview, ticks % 60 == 0 { report() }

        // Follow the window by its id every frame; look for it afresh twice a
        // second, or as soon as it is lost.
        var frame = windowID.flatMap(SettingsWindow.frame(of:))
        if frame == nil || Date().timeIntervalSince(lastSearch) > 0.5 {
            lastSearch = Date()
            if let found = SettingsWindow.find() {
                windowID = found.id
                frame = found.frame
            }
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        // A password or Apple's alert just closed and the switch still isn't
        // on: give it a moment, then say why.
        if SettingsWindow.consentPrompts.contains(lastFront), !SettingsWindow.consentPrompts.contains(front) {
            offerAt = min(offerAt, Date().addingTimeInterval(4))
        }
        lastFront = front
        if !done, !preview, !offered, out, Date() >= offerAt {
            offered = true
            card.offerFix()
        }
        // SayControl itself in front (its Permissions pane, the setup) is
        // still the user at it: the tray stays with System Settings.
        let atIt = front == SettingsWindow.bundleID || front == Bundle.main.bundleIdentifier
        guard let f = frame, atIt || done,
              !SettingsWindow.consentPrompts.contains(front) else {
            // Another app or a consent prompt in front, or no window: out of
            // the way until System Settings is back.
            if out, !done { stepAside() }
            return
        }
        place(under: f, tray: tray, overlay: overlay)
        if !out { emerge(tray: tray, overlay: overlay) }
        if !done { animate(f, overlay: overlay) }
    }

    /// The tray right under the list's column, its top against the window's
    /// foot; over the foot instead when the screen ends under the window.
    private func place(under f: NSRect, tray: NSPanel, overlay: NSPanel) {
        settings = f
        let column = SettingsWindow.listColumn(f)
        let width = min(max(column.width - Theme.px(32), Theme.px(380)), Theme.px(520))
        card.setWidth(width)
        let height = card.fittingHeight
        let pad = Theme.px(28)   // room for the shadow
        let floor = (NSScreen.screens.first { $0.frame.intersects(f) } ?? NSScreen.main)?.visibleFrame.minY ?? 0
        let tucked = f.minY - height - Theme.px(12) >= floor
        card.tucked = tucked
        let top = tucked ? f.minY : f.minY + height + Theme.px(14)
        let x = (column.midX - width / 2).rounded()
        let panel = NSRect(x: x - pad, y: top - height - pad, width: width + 2 * pad,
                           height: height + pad + (tucked ? 0 : pad))
        if tray.frame != panel { tray.setFrame(panel, display: true) }
        let face = NSRect(x: pad, y: pad, width: width, height: height)
        if card.frame != face { card.frame = face }
        // Under the window the tray's top edge is the window's foot, and the
        // card hides behind it on the way in and out.
        tray.contentView?.layer?.masksToBounds = tucked
        let span = f.union(panel).insetBy(dx: -40, dy: -40)
        if overlay.frame != span { overlay.setFrame(span, display: false) }
    }

    /// Out from under the window: the card starts above the tray's top
    /// edge, hidden there, and glides down into place.
    private func emerge(tray: NSPanel, overlay: NSPanel) {
        out = true
        card.layer?.removeAllAnimations()
        tray.orderFrontRegardless()
        overlay.orderFrontRegardless()
        loopStart = CACurrentMediaTime() + (Motion.reduced ? 0 : 0.9)
        guard !Motion.reduced, let layer = card.layer else { return }
        let move = CABasicAnimation(keyPath: "transform.translation.y")
        move.fromValue = card.tucked ? card.frame.height : -Theme.px(8)
        move.toValue = 0
        move.duration = 0.45
        move.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.18, 0.45, 1)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.35
        fade.timingFunction = Motion.ease
        layer.add(move, forKey: "emerge.move")
        layer.add(fade, forKey: "emerge.fade")
    }

    private func stepAside() {
        out = false
        glide.clear()
        tray?.orderOut(nil)
        overlay?.orderOut(nil)
    }

    private func animate(_ f: NSRect, overlay: NSPanel) {
        let o = overlay.frame.origin
        let icon = card.icon
        guard let window = icon.window else { return }
        let c = window.convertPoint(toScreen: icon.convert(NSPoint(x: icon.bounds.midX, y: icon.bounds.midY), to: nil))
        let d = SettingsWindow.dropPoint(f)
        let s = NSPoint(x: c.x - o.x, y: c.y - o.y), e = NSPoint(x: d.x - o.x, y: d.y - o.y)
        if Motion.reduced { return glide.still(from: s, to: e) }
        let now = CACurrentMediaTime()
        guard !paused, !dragging, now >= loopStart else {
            glide.clear()
            if !dragging { card.icon.lifted = false }
            return
        }
        let t = (now - loopStart).truncatingRemainder(dividingBy: Self.period) * 1000
        card.icon.lifted = t > 450 && t < 2300
        glide.frame(at: t, from: s, to: e)
    }

    /// `--guide-preview`'s once-a-second line.
    private func report() {
        func r(_ f: NSRect?) -> String {
            f.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "none"
        }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        print("guide: front \(front), settings \(r(settings)), tray \(out ? r(tray?.frame) : "away"), "
              + "card \(r(card.frame)) \(card.tucked ? "tucked" : "over the foot"), drop \(settings.map { SettingsWindow.dropPoint($0) }.map { "\(Int($0.x)),\(Int($0.y))" } ?? "-")")
        fflush(stdout)
    }

    // MARK: Done

    /// The switch took: a tick for a moment, back under the window, then
    /// SayControl again.
    private func succeed() {
        done = true
        glide.clear()
        card.icon.lifted = false
        guard out else { return finish() }
        card.showDone()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in self?.retract() }
    }

    private func retract() {
        guard done, let layer = card.layer, !Motion.reduced else { return finish() }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.finish() }
        let move = CABasicAnimation(keyPath: "transform.translation.y")
        move.fromValue = 0
        move.toValue = card.tucked ? card.frame.height : -Theme.px(8)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = card.tucked ? 1 : 0
        for a in [move, fade] {
            a.duration = 0.3
            a.timingFunction = CAMediaTimingFunction(name: .easeIn)
            a.fillMode = .forwards
            a.isRemovedOnCompletion = false
        }
        layer.add(move, forKey: "emerge.move")
        layer.add(fade, forKey: "emerge.fade")
        CATransaction.commit()
    }

    private func finish() {
        let back = granted
        hide()
        card.layer?.removeAllAnimations()
        back?()
    }

    // MARK: Building

    private func build() {
        func panel() -> NSPanel {
            let p = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: true)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            return p
        }
        // Over every ordinary window, since it only shows while System
        // Settings is in front; the overlay one level higher so the ghost
        // leaves the tray on top of it.
        let t = panel()
        t.level = .floating
        let clip = NSView()
        clip.wantsLayer = true
        clip.addSubview(card)
        t.contentView = clip
        tray = t

        let o = panel()
        o.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        o.ignoresMouseEvents = true
        o.contentView = glide
        overlay = o

        card.onClose = { [weak self] in
            guard let self = self else { return }
            let quit = self.preview
            self.hide()
            if quit { NSApp.terminate(nil) }
        }
        card.onResize = { [weak self] in
            guard let self = self, let f = self.settings, let t = self.tray, let o = self.overlay else { return }
            self.place(under: f, tray: t, overlay: o)
        }
        card.onHover = { [weak self] inside in
            self?.paused = inside
            if !inside { self?.loopStart = CACurrentMediaTime() + 0.3 }
        }
        card.icon.onDrag = { [weak self] began in
            guard let self = self else { return }
            self.dragging = began
            if !began { self.offerAt = min(self.offerAt, Date().addingTimeInterval(6)) }
            self.card.icon.lifted = began
            // Nothing of ours over the list while the real icon is on its
            // way there: the overlay ignores the mouse, and a drop must not
            // depend on that holding for drags too.
            if began {
                self.overlay?.orderOut(nil)
            } else {
                if self.out { self.overlay?.orderFrontRegardless() }
                self.loopStart = CACurrentMediaTime() + 0.4
            }
        }
    }
}

/// Dev tool: `SayCtrl --guide-preview [accessibility|input|screen]` opens that
/// list in System Settings and slides Set Up's tray out under it, asking macOS
/// for nothing, so it can be looked at on a Mac that already has every grant.
/// Its × quits. Once a second it prints where it put everything.
func runGuidePreviewIfRequested() -> Bool {
    guard let i = CommandLine.arguments.firstIndex(of: "--guide-preview") else { return false }
    let which = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : ""
    let grant: Permissions.Listed = which.hasPrefix("input") ? .inputMonitoring
        : which.hasPrefix("screen") ? .screenRecording : .accessibility
    Permissions.guide(grant, preview: true)
    return true
}
