// What a click on the resting pill opens: one small glass card that grows
// out of the pill, holding three things and nothing else —
//
//   · the last transcript, readable at once, with Copy and Paste
//   · Scratchpad: a note that lives in the card; while it's open, holding
//     fn writes into it instead of into your app
//   · Hands-free: a take without holding a key, for long dictation — the
//     pill grows a stop square, and a click on it (or fn) finishes
//
// It replaced the sun menu (Transcript / Polish / Email / Move / Close) in
// 2.3: Tones already polish, the seat moves by dragging, and a click outside
// closes the card, so what was left worth a click were these three.
//
// The overlay recipe of the paste card: a fixed window that never resizes
// while visible, the glass springing from the pill's shape to the card's and
// back, screen-saver level, non-activating. It takes the keyboard only while
// the scratchpad is open — typing into a note needs it — and gives it back
// the moment the pad closes.
import AppKit

final class PillMenuPanel: NSPanel {
    /// Key only for the scratchpad's typing; never main.
    var keyable = false
    override var canBecomeKey: Bool { keyable }
    override var canBecomeMain: Bool { false }
}

final class PillMenu {
    static let shared = PillMenu()

    static let width: CGFloat = 252
    static let pad: CGFloat = 14
    static let radius: CGFloat = 16
    /// Room around the tallest page for the spring's overshoot and shadow.
    private static let margin: CGFloat = 24
    private static let maxHeight: CGFloat = 220

    enum Page { case home, pad }

    private let panel: PillMenuPanel
    private let glass: NSView
    private var content: NSView?
    private weak var host: AppDelegate?
    private(set) var isOpen = false
    private(set) var page: Page = .home
    /// The scratchpad is up: a dictation lands in it instead of in an app.
    var holdsPad: Bool { isOpen && page == .pad }

    // Geometry, in panel coordinates.
    private var pillRect = NSRect.zero
    private var dock: PillDock = .bottomCenter
    private var maxCard = NSRect.zero

    // Motion: the glass springs between two rects.
    private var fromRect = NSRect.zero, toRect = NSRect.zero
    private var fromRadius: CGFloat = 0, toRadius: CGFloat = 0
    private var motionStart: CFTimeInterval = 0
    private var motionTimer: Timer?
    private var closing = false
    private var afterClose: (() -> Void)?

    private var mouseMonitor: Any?
    private var keyMonitors: [Any] = []

    // The scratchpad's own pieces, kept while its page is up.
    private weak var padText: NSTextView?
    private weak var padHint: NSTextField?

    private init() {
        panel = PillMenuPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        panel.level = .screenSaver   // same level as the pill — see Pill.init
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let size = NSSize(width: Self.width + 2 * Self.margin, height: Self.maxHeight + 2 * Self.margin)
        panel.setContentSize(size)
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        glass = PillView.glassBackdrop(cornerRadius: Self.radius)
        root.addSubview(glass)
        panel.contentView = root
    }

    // MARK: Open and close

    func toggle(host: AppDelegate) {
        if isOpen { close() } else { open(host: host) }
    }

    func open(host: AppDelegate) {
        guard !isOpen else { return }
        self.host = host
        isOpen = true
        closing = false
        page = .home
        let pill = host.pill!
        dock = pill.dock
        let cap = pill.capsuleFrame
        let screen = pill.panel.screen ?? mouseScreen()
        // Placed for the tallest page, so every page — anchored to the edge
        // the pill hugs — fits the fixed window.
        let tallest = PasteCard.cardFrame(size: NSSize(width: Self.width, height: Self.maxHeight),
                                          from: cap, dock: dock, in: screen.visibleFrame)
        let (origin, _) = placePanel(panel.frame.size, card: tallest)
        panel.setFrameOrigin(origin)
        let local = { (r: NSRect) in r.offsetBy(dx: -origin.x, dy: -origin.y) }
        pillRect = local(cap)
        maxCard = local(tallest)

        let view = homeView()
        install(view)
        let card = cardRect(for: view.frame.height)
        setGlass(pillRect, radius: min(pillRect.width, pillRect.height) / 2)
        view.frame.origin = card.origin
        prepareEntrance(view)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        host.setPillHiddenByMenu(true)
        spring(to: card, radius: Self.radius)
        watchOutside()
        host.log("Pill menu: opened")
    }

    func close(then: (() -> Void)? = nil) {
        guard isOpen, !closing else { return }
        closing = true
        afterClose = then
        releaseKeyboard()
        stopWatching()
        // The rows go first; then the glass puts itself away into the pill.
        if let view = content {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.11
                view.animator().alphaValue = 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [weak self] in
            guard let self = self, self.closing else { return }
            let rest = self.restPillRect
            self.spring(to: rest, radius: rest.height / 2, stiff: true)
        }
    }

    /// Gone at once — a take is starting and the pill is about to be it.
    func dismissNow() {
        guard isOpen else { return }
        motionTimer?.invalidate()
        motionTimer = nil
        releaseKeyboard()
        stopWatching()
        finishClose()
    }

    /// The pill at rest, where the glass folds back to: the card opened from
    /// the hovered pill, which is bigger, and folding to that size left a
    /// box standing where the pill should be. Anchored the way the pill
    /// anchors its capsule, so the handover is seamless.
    private var restPillRect: NSRect {
        let s = Pill.idleSize
        let x: CGFloat
        switch dock.hAlign {
        case .left:   x = pillRect.minX
        case .center: x = pillRect.midX - s.width / 2
        case .right:  x = pillRect.maxX - s.width
        }
        let y = dock.vAlign == .top ? pillRect.maxY - s.height : pillRect.minY
        return NSRect(x: x, y: y, width: s.width, height: s.height)
    }

    private func finishClose() {
        panel.orderOut(nil)
        content?.removeFromSuperview()
        content = nil
        isOpen = false
        closing = false
        page = .home
        host?.setPillHiddenByMenu(false)
        let then = afterClose
        afterClose = nil
        then?()
    }

    /// A take is starting. With the scratchpad open it is the pad's take and
    /// the card stays; otherwise the card makes way for the pill.
    func recordingStarted() {
        guard isOpen else { return }
        if page == .pad {
            padHint?.stringValue = "Listening…"
            padHint?.textColor = PillView.voiceEmber
        } else {
            dismissNow()
        }
    }

    /// The pad's take came back: the words go on the end of the note.
    func appendToPad(_ text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        padHint?.stringValue = Self.padHintText
        padHint?.textColor = PillView.glassMuted
        guard !words.isEmpty, let tv = padText else { return }
        var note = tv.string
        if !note.isEmpty && !note.hasSuffix("\n") { note += note.hasSuffix(" ") ? "" : " " }
        let start = (note as NSString).length
        note += words
        tv.string = note
        Self.savePad(note)
        tv.scrollRangeToVisible(NSRange(location: (note as NSString).length, length: 0))
        // The new words glow for a moment so you can see where they went.
        tv.textStorage?.addAttribute(.backgroundColor, value: PillView.voiceEmber.withAlphaComponent(0.22),
                                     range: NSRange(location: start, length: (words as NSString).length))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak tv] in
            guard let tv = tv, let storage = tv.textStorage else { return }
            storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
        }
    }

    /// A pad take that came back empty or failed: the hint returns.
    func padTakeEnded() {
        padHint?.stringValue = Self.padHintText
        padHint?.textColor = PillView.glassMuted
    }

    // MARK: Pages

    private func show(_ next: Page) {
        guard isOpen, !closing, next != page else { return }
        page = next
        let old = content
        let view = next == .home ? homeView() : padView()
        install(view)
        let card = cardRect(for: view.frame.height)
        view.frame.origin = card.origin
        prepareEntrance(view)
        if let old = old {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.1
                old.animator().alphaValue = 0
            }, completionHandler: { old.removeFromSuperview() })
        }
        spring(to: card, radius: Self.radius)
        if next == .pad {
            panel.keyable = true
            panel.makeKey()
            if let tv = padText {
                panel.makeFirstResponder(tv)
                tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            }
        } else {
            releaseKeyboard()
        }
    }

    /// The page's view goes on top of the glass. show() fades the old one
    /// out itself; open() has none.
    private func install(_ view: NSView) {
        content = view
        panel.contentView?.addSubview(view)
    }

    /// The card's rect for a page of `height`: anchored to the edge the
    /// pill hugs — its foot on a bottom seat, its head at the top one.
    private func cardRect(for height: CGFloat) -> NSRect {
        let y = dock.vAlign == .top ? maxCard.maxY - height : maxCard.minY
        return NSRect(x: maxCard.minX, y: y, width: Self.width, height: height)
    }

    private func releaseKeyboard() {
        guard panel.keyable else { return }
        panel.keyable = false
        panel.resignKey()
    }

    // MARK: Motion

    private func setGlass(_ r: NSRect, radius: CGFloat) {
        glass.frame = r
        PillView.setGlassCorner(glass, radius)
    }

    private func spring(to target: NSRect, radius: CGFloat, stiff: Bool = false) {
        fromRect = glass.frame
        fromRadius = glass.layer?.cornerRadius ?? Self.radius
        toRect = target
        toRadius = radius
        motionStart = CACurrentMediaTime()
        motionStiff = stiff
        if motionTimer == nil {
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.step() }
            RunLoop.main.add(t, forMode: .common)
            motionTimer = t
        }
        step()
    }
    private var motionStiff = false

    private func step() {
        let t = CACurrentMediaTime() - motionStart
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let p = still ? 1 : (motionStiff ? Pill.spring(t, stiffness: 300, damping: 36)
                                         : Pill.spring(t, stiffness: 230, damping: 21))
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * p }
        let r = NSRect(x: mix(fromRect.minX, toRect.minX), y: mix(fromRect.minY, toRect.minY),
                       width: max(1, mix(fromRect.width, toRect.width)),
                       height: max(1, mix(fromRect.height, toRect.height)))
        setGlass(r, radius: min(mix(fromRadius, toRadius), min(r.width, r.height) / 2))
        if let view = content, !closing { entrance(view, at: t) }
        panel.invalidateShadow()
        // Closing hands over to the pill the moment the glass has arrived —
        // waiting out the opening's clock left an empty box on screen.
        let arrived = closing ? (p >= 0.985 || t >= 0.45) : t >= 0.7
        guard still || arrived else { return }
        motionTimer?.invalidate()
        motionTimer = nil
        setGlass(toRect, radius: toRadius)
        if closing { finishClose() }
    }

    /// Rows start hidden a few points low; entrance(at:) brings them up
    /// one after another, 40 ms apart, 110 ms after the glass starts.
    private func prepareEntrance(_ view: NSView) {
        view.alphaValue = 1
        for row in view.subviews {
            row.alphaValue = 0
        }
        rowHomes[ObjectIdentifier(view)] = view.subviews.map { $0.frame.origin }
    }
    private var rowHomes: [ObjectIdentifier: [NSPoint]] = [:]

    private func entrance(_ view: NSView, at t: CFTimeInterval) {
        guard let homes = rowHomes[ObjectIdentifier(view)] else { return }
        // Rows in reading order: top first (the view is flipped).
        let order = view.subviews.indices.sorted { homes[$0].y < homes[$1].y }
        for (k, i) in order.enumerated() {
            let row = view.subviews[i]
            let u = CGFloat(min(1, max(0, (t - 0.11 - Double(k) * 0.04) / 0.22)))
            let e = 1 - (1 - u) * (1 - u)
            row.alphaValue = e
            row.setFrameOrigin(NSPoint(x: homes[i].x, y: homes[i].y + (1 - e) * 5))
        }
        if t > 0.11 + Double(order.count) * 0.04 + 0.22 { rowHomes[ObjectIdentifier(view)] = nil }
    }

    // MARK: Outside clicks and Esc

    private func watchOutside() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self, self.isOpen else { return }
            if !NSMouseInRect(NSEvent.mouseLocation, self.cardScreenRect, false) { self.close() }
        }
        let esc: (NSEvent) -> Bool = { [weak self] e in
            guard let self = self, self.isOpen, e.keyCode == 53 else { return false }
            if self.page == .pad { self.show(.home) } else { self.close() }
            return true
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { _ = esc($0) }) { keyMonitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { esc($0) ? nil : $0 }) { keyMonitors.append(m) }
    }

    private func stopWatching() {
        if let m = mouseMonitor { NSEvent.removeMonitor(m) }
        mouseMonitor = nil
        keyMonitors.forEach(NSEvent.removeMonitor)
        keyMonitors = []
    }

    private var cardScreenRect: NSRect {
        glass.frame.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
    }

    // MARK: The home page

    private func homeView() -> NSView {
        let host = self.host
        let w = Self.width, p = Self.pad, inner = w - 2 * p
        let v = MenuPageView(frame: NSRect(x: 0, y: 0, width: w, height: 100))
        var y = p

        let last = (host?.lastTranscript ?? snapshotLast ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let cap = Self.capLabel(Self.lastCaption(host: host))
        cap.frame = NSRect(x: p, y: y, width: inner, height: 12)
        v.addSubview(cap)
        y += 12 + 6

        let words = NSTextField(wrappingLabelWithString: last.isEmpty ? "Nothing dictated yet." : last)
        words.font = Self.serif(13.5)
        words.textColor = last.isEmpty ? PillView.glassMuted : PillView.glassInk
        words.maximumNumberOfLines = 2
        words.lineBreakMode = .byWordWrapping   // truncating-tail would make it one line
        words.cell?.truncatesLastVisibleLine = true
        words.isSelectable = false
        // Two lines at most: measure the words, cap at two of the serif's lines.
        let font = Self.serif(13.5)
        let lineH = ceil(font.ascender - font.descender + font.leading) + 1
        let full = ceil((words.stringValue as NSString).boundingRect(
            with: NSSize(width: inner - 4, height: 400), options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]).height)
        let h = min(max(full, lineH), lineH * 2)
        words.frame = NSRect(x: p, y: y, width: inner, height: h)
        v.addSubview(words)
        y += h + 9

        let copy = MenuButton(title: "Copy", symbol: "doc.on.doc", look: .plain, alt: "Copied") { [weak self] b in
            self?.copyLast(b)
        }
        let paste = MenuButton(title: "Paste", key: "⏎", look: .ember) { [weak self] _ in
            self?.pasteLast()
        }
        copy.isEnabled = !last.isEmpty
        paste.isEnabled = !last.isEmpty
        copy.frame = NSRect(x: p, y: y, width: copy.fittingWidth, height: 22)
        paste.frame = NSRect(x: copy.frame.maxX + 6, y: y, width: paste.fittingWidth, height: 22)
        v.addSubview(copy)
        v.addSubview(paste)
        y += 22 + 10

        let rule = MenuRule(frame: NSRect(x: 0, y: y, width: w, height: 1))
        v.addSubview(rule)
        y += 1 + 10

        let half = (inner - 6) / 2
        let scratch = MenuButton(title: "Scratchpad", symbol: "note.text", look: .row(PillView.amberBadge)) { [weak self] _ in
            self?.show(.pad)
        }
        let free = MenuButton(title: "Hands-free", symbol: "mic", look: .row(PillView.voiceEmber)) { [weak self] _ in
            self?.startHandsFree()
        }
        scratch.frame = NSRect(x: p, y: y, width: half, height: 32)
        free.frame = NSRect(x: p + half + 6, y: y, width: half, height: 32)
        v.addSubview(scratch)
        v.addSubview(free)
        y += 32 + p

        v.setFrameSize(NSSize(width: w, height: y))
        return v
    }

    private static func lastCaption(host: AppDelegate?) -> String {
        guard let host = host, !host.lastTranscript.isEmpty else { return "LAST" }
        var parts = ["LAST"]
        if let at = host.lastPasteMoment {
            let s = Int(Date().timeIntervalSince(at))
            parts.append(s < 60 ? "JUST NOW" : s < 3600 ? "\(s / 60) MIN AGO" : "\(s / 3600) H AGO")
        }
        if let app = host.lastPasteAppName { parts.append(app.uppercased()) }
        return parts.joined(separator: " · ")
    }

    private func copyLast(_ button: MenuButton) {
        guard let text = host?.lastTranscript, !text.isEmpty else { return }
        host?.putOnClipboard(text)
        button.flash("Copied")
    }

    /// The card folds away first, so the words land in the text box you
    /// were in — the card never took the keyboard on this page.
    private func pasteLast() {
        guard let host = host, !host.lastTranscript.isEmpty else { return }
        let text = host.lastTranscript
        close { [weak host] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { host?.pasteText(text, learn: false) }
        }
    }

    private func startHandsFree() {
        close { [weak self] in self?.host?.startHandsFreeFromMenu() }
    }

    /// For --snapshot: the pages on their glass, with no app behind them.
    var snapshotLast: String?
    func snapshotPage(_ page: Page) -> NSView { page == .home ? homeView() : padView() }

    // MARK: The scratchpad page

    static let padHintText = "Hold fn to add"

    private func padView() -> NSView {
        let w = Self.width, p = Self.pad, inner = w - 2 * p
        let v = MenuPageView(frame: NSRect(x: 0, y: 0, width: w, height: 100))
        var y = p

        let back = MenuButton(title: "Back", symbol: "chevron.left", look: .bare) { [weak self] _ in
            self?.show(.home)
        }
        back.frame = NSRect(x: p - 4, y: y - 3, width: back.fittingWidth, height: 18)
        v.addSubview(back)
        let cap = Self.capLabel("SCRATCHPAD", alignment: .right)
        // Right of Back only: a label spanning the row sat on top of the
        // button and ate its clicks.
        let capX = back.frame.maxX + 8
        cap.frame = NSRect(x: capX, y: y, width: w - p - capX, height: 12)
        v.addSubview(cap)
        y += 12 + 9

        let well = PadWell(frame: NSRect(x: p, y: y, width: inner, height: 116))
        let scroll = NSScrollView(frame: well.bounds.insetBy(dx: 1, dy: 1))
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        well.addSubview(scroll)
        let tv = PadTextView(frame: NSRect(x: 0, y: 0, width: inner - 2, height: 114))
        tv.isRichText = false
        tv.drawsBackground = false
        tv.font = Self.serif(13.5)
        tv.textColor = PillView.glassInk
        tv.insertionPointColor = PillView.voiceEmber
        tv.textContainerInset = NSSize(width: 6, height: 7)
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.allowsUndo = true
        tv.string = Self.loadPad()
        tv.onChange = { Self.savePad($0) }
        scroll.documentView = tv
        v.addSubview(well)
        padText = tv
        y += 116 + 9

        let hint = NSTextField(labelWithString: Self.padHintText)
        hint.font = .systemFont(ofSize: 11, weight: .medium)
        hint.textColor = PillView.glassMuted
        let clear = MenuButton(title: "Clear", look: .plain) { [weak self] _ in
            self?.padText?.string = ""
            Self.savePad("")
        }
        let copy = MenuButton(title: "Copy all", look: .plain, alt: "Copied") { [weak self] b in
            guard let text = self?.padText?.string, !text.isEmpty else { return }
            self?.host?.putOnClipboard(text)
            b.flash("Copied")
        }
        clear.frame = NSRect(x: w - p - clear.fittingWidth, y: y, width: clear.fittingWidth, height: 22)
        copy.frame = NSRect(x: clear.frame.minX - 6 - copy.fittingWidth, y: y, width: copy.fittingWidth, height: 22)
        hint.frame = NSRect(x: p, y: y + 4, width: copy.frame.minX - 6 - p, height: 15)
        v.addSubview(hint)
        v.addSubview(copy)
        v.addSubview(clear)
        padHint = hint
        y += 22 + p

        v.setFrameSize(NSSize(width: w, height: y))
        return v
    }

    private static var padURL: URL { Config.shared.dir.appendingPathComponent("scratchpad.txt") }
    static func loadPad() -> String { (try? String(contentsOf: padURL, encoding: .utf8)) ?? "" }
    static func savePad(_ s: String) { try? s.write(to: padURL, atomically: true, encoding: .utf8) }

    // MARK: Type

    static func serif(_ size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size)
        return NSFont(descriptor: base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor, size: size) ?? base
    }

    static func capLabel(_ s: String, alignment: NSTextAlignment = .left) -> NSTextField {
        let f = NSTextField(labelWithString: "")
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        f.attributedStringValue = NSAttributedString(string: s, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium),
            .foregroundColor: PillView.glassMuted,
            .kern: 0.8,
            .paragraphStyle: style,
        ])
        f.lineBreakMode = .byTruncatingTail
        return f
    }
}

/// Top-down layout for the pages.
final class MenuPageView: NSView {
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The hairline between the last transcript and the two actions.
final class MenuRule: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.07).setFill()
        bounds.fill()
    }
}

/// The scratchpad's well: a faint rounded field on the glass.
final class PadWell: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        NSColor.white.withAlphaComponent(0.05).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.09).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// The scratchpad's text view: saves as you type.
final class PadTextView: NSTextView {
    var onChange: ((String) -> Void)?
    override func didChangeText() {
        super.didChangeText()
        onChange?(string)
    }
}

/// The card's buttons, drawn on the glass: plain (a faint glass chip), ember
/// (the one action that sends your words somewhere), row (a tinted icon well
/// and a title — the two ways into the pad and a hands-free take), and bare
/// (text only — Back).
final class MenuButton: NSControl {
    enum Look { case plain, ember, bare, row(NSColor) }

    private var title: String
    /// The other thing it says ("Copied"): the width is set for the longer
    /// of the two, so the flash never runs past the button's edge.
    private let alt: String?
    private let symbol: String?
    private let key: String?
    private let look: Look
    private let onPress: (MenuButton) -> Void
    private var hovered = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }

    static let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    static let rowFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

    init(title: String, symbol: String? = nil, key: String? = nil, look: Look, alt: String? = nil,
         action: @escaping (MenuButton) -> Void) {
        self.title = title
        self.alt = alt
        self.symbol = symbol
        self.key = key
        self.look = look
        self.onPress = action
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { true }

    var fittingWidth: CGFloat {
        let t = [title, alt].compactMap { $0 }
            .map { ceil(NSAttributedString(string: $0, attributes: [.font: Self.font]).size().width) }.max() ?? 0
        switch look {
        case .bare:  return t + (symbol == nil ? 8 : 18)
        case .row:   return t + 44
        default:
            return t + 20 + (symbol == nil ? 0 : 16) + (key == nil ? 0 : 20)
        }
    }

    func flash(_ text: String) {
        let old = title
        title = text
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
            self?.title = old
            self?.needsDisplay = true
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { if isEnabled { pressed = true } }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        let fire = pressed && inside && isEnabled
        pressed = false
        if fire { onPress(self) }
    }

    private func symbolImage(_ name: String, _ size: CGFloat, _ color: NSColor) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold).applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
    }

    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = isEnabled ? 1 : 0.4
        let r = bounds
        switch look {
        case .bare:
            let ink = (hovered ? PillView.glassInk : PillView.glassMuted).withAlphaComponent(alpha)
            var x: CGFloat = 4
            if let s = symbol, let img = symbolImage(s, 9, ink) {
                img.draw(in: NSRect(x: x, y: r.midY - 5, width: 7, height: 10))
                x += 12
            }
            drawText(title, font: Self.font, color: ink, x: x, in: r)
        case .row(let tint):
            let bg = NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9)
            NSColor.white.withAlphaComponent(pressed ? 0.14 : hovered ? 0.10 : 0.05).setFill()
            bg.fill()
            // Well and title centred together, so neither hugs an edge.
            let tw = ceil(NSAttributedString(string: title, attributes: [.font: Self.rowFont]).size().width)
            let x0 = max(6, (r.width - (20 + 8 + tw)) / 2)
            let well = NSRect(x: x0, y: r.midY - 10, width: 20, height: 20)
            tint.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: well, xRadius: 6, yRadius: 6).fill()
            if let s = symbol, let img = symbolImage(s, 10, tint) {
                let sz = img.size
                img.draw(in: NSRect(x: well.midX - sz.width / 2, y: well.midY - sz.height / 2, width: sz.width, height: sz.height))
            }
            drawText(title, font: Self.rowFont, color: PillView.glassInk, x: well.maxX + 8, in: r)
        case .plain, .ember:
            let ember: Bool
            if case .ember = look { ember = true } else { ember = false }
            let bg = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
            if ember {
                PillView.emberBar.withAlphaComponent(alpha * (pressed ? 0.85 : 1)).setFill()
                bg.fill()
            } else {
                NSColor.white.withAlphaComponent((pressed ? 0.16 : hovered ? 0.13 : 0.08) * alpha).setFill()
                bg.fill()
                NSColor.white.withAlphaComponent(0.10 * alpha).setStroke()
                bg.lineWidth = 1
                bg.stroke()
            }
            let ink = (ember ? NSColor(srgbRed: 0.110, green: 0.102, blue: 0.086, alpha: 1) : PillView.glassInk)
                .withAlphaComponent(alpha)
            let tw0 = ceil(NSAttributedString(string: title, attributes: [.font: Self.font]).size().width)
            let content = tw0 + (symbol == nil ? 0 : 16) + (key == nil ? 0 : 21)
            var x: CGFloat = max(10, (r.width - content) / 2)
            if let s = symbol, let img = symbolImage(s, 9.5, ink) {
                let sz = img.size
                img.draw(in: NSRect(x: x, y: r.midY - sz.height / 2, width: sz.width, height: sz.height))
                x += 16
            }
            let tw = drawText(title, font: Self.font, color: ink, x: x, in: r)
            if let k = key {
                let cap = NSRect(x: x + tw + 6, y: r.midY - 7, width: 15, height: 14)
                NSColor.black.withAlphaComponent(0.14 * alpha).setFill()
                NSBezierPath(roundedRect: cap, xRadius: 3.5, yRadius: 3.5).fill()
                let a = NSAttributedString(string: k, attributes: [.font: NSFont.systemFont(ofSize: 9.5, weight: .bold), .foregroundColor: ink])
                let s = a.size()
                a.draw(at: NSPoint(x: cap.midX - s.width / 2, y: cap.midY - s.height / 2))
            }
        }
    }

    @discardableResult
    private func drawText(_ s: String, font: NSFont, color: NSColor, x: CGFloat, in r: NSRect) -> CGFloat {
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        let size = a.size()
        a.draw(at: NSPoint(x: x, y: r.midY - size.height / 2))
        return ceil(size.width)
    }
}
