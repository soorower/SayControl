// The missed paste. A dictation's words are pressed into whatever has the
// focus with a blind ⌘V, and the clipboard is handed back a second later —
// so when nothing that takes text has the focus (Finder in front, a list or
// a button holding it, the desktop), the words went nowhere AND left the
// clipboard. Now the paste looks first: when the focus is plainly not a text
// box, the words stay on the clipboard and this card grows out of the pill
// to hold them. Click into any text box and the card arms: Return, or its
// Paste button, puts the words there.
//
// The look is decided, not guessed: PasteTarget says "not editable" only
// for a focus that is clearly not text in an app whose accessibility can be
// believed. Anything it can't read — terminals, Electron and Chromium,
// canvases and spreadsheets, a web page — pastes exactly as before, because
// blocking a paste that would have worked is worse than the miss.
//
// Same overlay recipe as the pill (see Pill.init in main.swift): a fixed
// window that never resizes while visible — only the glass inside moves —
// at screen-saver level, borderless and non-activating. Unlike the pill it
// takes clicks, first-mouse like FirstMouseButton, and it can never become
// key: the app you are pasting into keeps its focus the whole time.
import AppKit

// MARK: - Where would a paste land?

enum PasteTarget {

    enum Verdict: String {
        case editable
        case notEditable = "not editable"
        case unknown
    }

    struct Reading {
        let verdict: Verdict
        /// The focused element's role (and subrole), or "none".
        let role: String
        let bundleID: String
        /// The app in front, by the name it shows — the card's title.
        let appName: String
        /// Why the verdict, in a few words, for the log.
        let why: String
        /// SayControl itself is in front: never a place to paste into.
        let ours: Bool

        var summary: String { "\(verdict.rawValue) — \(role) in \(bundleID) (\(why))" }
    }

    /// Roles that take typing outright.
    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    static let textSubroles: Set<String> = ["AXSearchField", "AXSecureTextField"]

    /// Roles that plainly do not take a paste of words: collections, controls,
    /// containers and pictures. Only believed in an app whose accessibility
    /// is native and reliable (see unreliable(_:terminal:)).
    static let notTextRoles: Set<String> = [
        "AXList", "AXOutline", "AXTable", "AXBrowser", "AXButton", "AXWindow", "AXScrollArea",
        "AXGroup", "AXImage", "AXCell", "AXRow", "AXColumn", "AXCheckBox", "AXRadioButton",
        "AXPopUpButton", "AXMenuButton", "AXSlider", "AXTabGroup", "AXToolbar", "AXSplitGroup",
        "AXSplitter", "AXStaticText", "AXDisclosureTriangle", "AXLayoutArea", "AXLayoutItem",
        "AXSheet", "AXDrawer", "AXApplication", "AXRadioGroup", "AXLevelIndicator",
        "AXProgressIndicator", "AXValueIndicator", "AXColorWell", "AXIncrementor",
    ]

    /// Apps whose accessibility can't be taken at its word: a paste into them
    /// often works whatever the focused element claims. Matched by bundle-id
    /// prefix. Spreadsheets take a paste into a selected cell; canvases turn
    /// it into a text object; the custom-drawn editors often report a bare
    /// window or group for a perfectly good text view.
    private static let unreliablePrefixes = [
        // Browsers other than Safari: without the assistive switch flipped
        // (CorrectionWatcher.requestAccessibilityTree) their tree is empty.
        "com.google.Chrome", "org.chromium.", "company.thebrowser.", "com.brave.Browser",
        "com.microsoft.edgemac", "com.vivaldi.", "com.operasoftware.", "org.mozilla.",
        "app.zen-browser.",
        // Canvases, spreadsheets, office suites.
        "com.figma.", "com.bohemiancoding.", "com.apple.iWork.", "com.apple.freeform",
        "com.microsoft.", "com.adobe.", "com.seriflabs.", "com.omnigroup.OmniGraffle",
        "com.linearity.", "com.pixelmatorteam.",
        // Editors that draw their own text.
        "com.jetbrains.", "com.google.android.studio", "com.sublimetext.", "dev.zed.",
        "org.gnu.Emacs", "org.vim.", "com.qvacua.VimR",
    ]

    /// Apps whose page takes a paste with no field focused — a canvas turns
    /// it into an object, a sheet into a cell, an editor into its buffer.
    private static let pageTakesPaste = [
        "com.figma.", "com.bohemiancoding.", "com.apple.iWork.", "com.apple.freeform",
        "com.microsoft.", "com.adobe.", "com.seriflabs.", "com.linearity.", "notion.id",
        "com.tinyspeck.slackmacgap", "md.obsidian",
    ]

    /// Frameworks that mean the app draws its own UI and reports it loosely.
    private static let unreliableFrameworks = [
        "Electron Framework.framework", "Chromium Embedded Framework.framework",
        "QtCore.framework", "FlutterMacOS.framework",
    ]
    private static var frameworkVerdicts: [String: String?] = [:]
    private static let cacheLock = NSLock()

    /// Why an app's accessibility can't be believed, or nil when it can.
    /// `terminal` is AppDelegate.frontAppIsTerminal — the app's own way of
    /// knowing a terminal, by bundle id and by name.
    static func unreliable(_ app: NSRunningApplication, terminal: Bool) -> String? {
        if terminal { return "terminal" }
        let id = app.bundleIdentifier ?? ""
        if unreliablePrefixes.contains(where: { id.hasPrefix($0) }) { return "loose accessibility" }
        guard let bundle = app.bundleURL else { return nil }
        let key = bundle.path
        cacheLock.lock()
        if let known = frameworkVerdicts[key] { cacheLock.unlock(); return known }
        cacheLock.unlock()
        let frameworks = bundle.appendingPathComponent("Contents/Frameworks")
        let fm = FileManager.default
        var found: String?
        for name in unreliableFrameworks where fm.fileExists(atPath: frameworks.appendingPathComponent(name).path) {
            found = name.replacingOccurrences(of: ".framework", with: "")
            break
        }
        // A Java app (the JetBrains family ships its own runtime) is the same story.
        if found == nil, fm.fileExists(atPath: bundle.appendingPathComponent("Contents/jbr").path) {
            found = "Java"
        }
        cacheLock.lock()
        frameworkVerdicts[key] = .some(found)
        cacheLock.unlock()
        return found
    }

    /// Read the focus. Cheap — a handful of attribute reads — so the card
    /// can ask four times a second while it waits for a text box.
    static func read(terminal: Bool) -> Reading {
        let front = NSWorkspace.shared.frontmostApplication
        let id = front?.bundleIdentifier ?? "?"
        let name = front?.localizedName ?? "this app"
        func reading(_ v: Verdict, _ role: String, _ why: String, ours: Bool = false) -> Reading {
            Reading(verdict: v, role: role, bundleID: id, appName: name, why: why, ours: ours)
        }
        guard let front = front else { return reading(.unknown, "none", "no app in front") }
        if front.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return reading(.unknown, "none", "SayControl's own window", ours: true)
        }
        let el = CorrectionWatcher.element(of: AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute)
            ?? CorrectionWatcher.element(of: AXUIElementCreateApplication(front.processIdentifier),
                                         kAXFocusedUIElementAttribute)
        let role = el.map(describeRole) ?? "none"
        // Anything that says it takes text is believed, in every app.
        if let el = el, let why = editable(el) { return reading(.editable, role, why) }
        // The page itself holds the focus: in a browser or an Electron app
        // (Claude, Slack) whose tree is up, a focused field reports itself
        // as AXTextArea/AXTextField — measured 2026-09-29 in Claude, where a
        // click on the conversation left the web area focused and the paste
        // vanished. So a bare web area means no text box. An empty tree
        // reports no focus at all and stays unknown below; canvases and
        // office apps catch ⌘V on the page and keep the blind paste.
        if let el = el, string(el, kAXRoleAttribute) == "AXWebArea", bool(el, "AXEditable") != true,
           !terminal, !pageTakesPaste.contains(where: { id.hasPrefix($0) }) {
            return reading(.notEditable, role, "page focused, no text box")
        }
        // Somewhere inside a page — the YouTube player in Arc, a message
        // bubble in Claude — and not in anything that takes typing (checked
        // above, AXEditableAncestor included). A live tree reports a focused
        // field as one, so this is a page with no text box focused. Sites
        // that take a paste on the page itself (canvases, sheets) keep the
        // blind paste, by the address the web area reports.
        if let el = el, !terminal, !pageTakesPaste.contains(where: { id.hasPrefix($0) }),
           let area = webArea(of: el) {
            var pid: pid_t = 0
            AXUIElementGetPid(el, &pid)
            if pid == front.processIdentifier {
                if let host = urlHost(area), canvasHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                    return reading(.unknown, role, "canvas site \(host)")
                }
                return reading(.notEditable, role, "in a page, no text box")
            }
        }
        if let why = unreliable(front, terminal: terminal) { return reading(.unknown, role, why) }
        let finder = id == "com.apple.finder"
        guard let el = el else {
            // Finder with nothing focused is the desktop, or a window with
            // nothing selected: no text box anywhere. Elsewhere, silence
            // proves nothing.
            return finder ? reading(.notEditable, role, "Finder, nothing focused")
                          : reading(.unknown, role, "no focused element")
        }
        // The focus sits in some other process — a floating panel, a
        // launcher — so the app in front can't vouch for it.
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        if pid != front.processIdentifier { return reading(.unknown, role, "focus in another process") }
        // A web page catches ⌘V in its own script whether or not a field
        // has the focus (Docs, Figma, Slack in a browser tab).
        if inWebArea(el) { return reading(.unknown, role, "web content") }
        if finder { return reading(.notEditable, role, "Finder, no text box focused") }
        if notTextRoles.contains(string(el, kAXRoleAttribute) ?? "") {
            return reading(.notEditable, role, "not a text role")
        }
        return reading(.unknown, role, "role not on either list")
    }

    /// Why this element takes typing, or nil. The element itself first,
    /// then a few ancestors — a web editor's focus is often a paragraph or
    /// a span inside the editable region, which says so on the region.
    private static func editable(_ el: AXUIElement) -> String? {
        var node: AXUIElement? = el
        for depth in 0..<5 {
            guard let n = node else { break }
            let role = string(n, kAXRoleAttribute) ?? ""
            if textRoles.contains(role) { return depth == 0 ? "text role" : "inside \(role)" }
            if depth == 0, let sub = string(n, kAXSubroleAttribute), textSubroles.contains(sub) { return "text subrole" }
            if bool(n, "AXEditable") == true { return "AXEditable" }
            // WebKit and Chromium mark everything inside a contenteditable.
            if CorrectionWatcher.element(of: n, "AXEditableAncestor") != nil { return "AXEditableAncestor" }
            // A custom text view that exposes a caret and lets its value or
            // selection be written is a text box whatever its role says.
            if depth == 0, has(n, kAXSelectedTextRangeAttribute),
               settable(n, kAXValueAttribute) || settable(n, kAXSelectedTextAttribute) {
                return "settable text"
            }
            node = CorrectionWatcher.element(of: n, kAXParentAttribute)
        }
        return nil
    }

    /// Sites whose page catches ⌘V with no field focused.
    private static let canvasHosts = [
        "figma.com", "canva.com", "miro.com", "excalidraw.com", "tldraw.com", "whimsical.com",
        "docs.google.com", "sheets.google.com", "slides.google.com", "notion.so", "notion.site",
        "app.slack.com", "airtable.com", "lucid.app", "framer.com",
    ]

    /// The web area `el` sits in (itself included), or nil.
    private static func webArea(of el: AXUIElement) -> AXUIElement? {
        var node: AXUIElement? = el
        for _ in 0..<40 {
            guard let n = node else { return nil }
            if string(n, kAXRoleAttribute) == "AXWebArea" { return n }
            node = CorrectionWatcher.element(of: n, kAXParentAttribute)
        }
        return nil
    }

    /// The page's host, from the web area's AXURL.
    private static func urlHost(_ area: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(area, "AXURL" as CFString, &v) == .success, let v = v else { return nil }
        if let url = v as? URL { return url.host?.lowercased() }
        if let s = v as? String { return URL(string: s)?.host?.lowercased() }
        return nil
    }

    private static func inWebArea(_ el: AXUIElement) -> Bool {
        var node: AXUIElement? = el
        for _ in 0..<12 {
            guard let n = node else { return false }
            if string(n, kAXRoleAttribute) == "AXWebArea" { return true }
            node = CorrectionWatcher.element(of: n, kAXParentAttribute)
        }
        return false
    }

    private static func describeRole(_ el: AXUIElement) -> String {
        let role = string(el, kAXRoleAttribute) ?? "?"
        guard let sub = string(el, kAXSubroleAttribute), !sub.isEmpty else { return role }
        return "\(role)/\(sub)"
    }

    private static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private static func bool(_ el: AXUIElement, _ attr: String) -> Bool? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return (v as? NSNumber)?.boolValue
    }

    private static func has(_ el: AXUIElement, _ attr: String) -> Bool {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success && v != nil
    }

    private static func settable(_ el: AXUIElement, _ attr: String) -> Bool {
        var s: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(el, attr as CFString, &s) == .success && s.boolValue
    }
}

// MARK: - The card

/// Never key, never main: a click on the card must not take the keyboard
/// from the text box the words are about to go into.
final class PasteCardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class PasteCard {
    static let shared = PasteCard()

    /// How long the card waits, not counting time with the pointer on it.
    static let life: TimeInterval = 15
    /// Room around the glass inside the fixed window, for the spring's
    /// overshoot and the Paste button's glow.
    private static let margin: CGFloat = 20

    private let panel: PasteCardPanel
    private let root: NSView
    private let backdrop: NSView
    private var view: PasteCardView?
    private weak var host: AppDelegate?
    private(set) var isVisible = false
    private var words = ""
    /// How the held dictation goes in once a text box has the focus. nil:
    /// the words alone (pasteText). A dictation with a screenshot or a file
    /// riding along replays its whole sequence instead.
    private var replay: (() -> Void)?

    /// The glass's two shapes in window coordinates: the pill it grew out
    /// of, and the card.
    private var pillRect = NSRect.zero
    private var cardRect = NSRect.zero
    /// Where the pill rests, in window coordinates — what the glass goes
    /// back to on the way out.
    private var restRect = NSRect.zero
    private var restRadius: CGFloat = 6

    private enum Phase { case opening, open, closing }
    private var phase = Phase.open
    private var motionStart: CFTimeInterval = 0
    private var motionTimer: Timer?
    private var clockTimer: Timer?
    private var pollTimer: Timer?
    private var polling = false
    private var lastTick: CFTimeInterval = 0
    private var remaining = PasteCard.life
    private var armed = false
    private var copiedWork: DispatchWorkItem?
    private var afterClose: (() -> Void)?
    private let axQueue = DispatchQueue(label: "com.sayctrl.pastecard.ax", qos: .userInitiated)

    // The Return hook: a session tap of the card's own, alive while the
    // card is — the app's fn tap is listen-only for the default bindings,
    // so it can't keep a Return from the text box.
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var escMonitor: Any?
    /// The Return whose press became a paste: its repeats and its key-up
    /// are swallowed too, so the text box never sees half a keystroke.
    fileprivate var swallowing: Int64?

    private init() {
        panel = PasteCardPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                               styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.level = .screenSaver   // same level as the pill — see Pill.init
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        root = NSView(frame: panel.contentView!.bounds)
        root.wantsLayer = true
        root.autoresizingMask = [.width, .height]
        backdrop = PillView.glassBackdrop(cornerRadius: PasteCardView.radius)
        root.addSubview(backdrop)   // glass under, content on top
        panel.contentView = root
    }

    // MARK: Show

    /// The paste found no text box: hold `words` on the card, grown out of
    /// the pill's seat. The words are already on the clipboard.
    func show(words: String, extras: [PasteExtra] = [], replay: (() -> Void)? = nil,
              target: PasteTarget.Reading, host: AppDelegate) {
        if isVisible { dismiss(animated: false) }
        self.host = host
        self.words = words
        self.replay = replay
        let pill = host.pill!
        let dock = pill.dock
        // The pill as it looks right now (mid-take it is the thinking
        // capsule), and where it will rest once the card is gone.
        let now = pill.capsuleFrame
        let restSize = Pill.size(for: .idle, vertical: dock.isVertical)
        let rest = Self.anchored(restSize, in: pill.frame, dock: dock)

        let v = PasteCardView(words: words, app: target.appName, extras: extras)
        let size = v.frame.size
        let screen = pill.panel.screen ?? mouseScreen()
        let card = Self.cardFrame(size: size, from: rest, dock: dock, in: screen.visibleFrame)
        // Never past the screen's edge: macOS pulls an overhanging window
        // back in and the card would be cut with it (see placePanel).
        let frame = card.union(now).union(rest).insetBy(dx: -Self.margin, dy: -Self.margin)
            .intersection(screen.frame).integral
        panel.setFrame(frame, display: false)
        let local = { (r: NSRect) in r.offsetBy(dx: -frame.minX, dy: -frame.minY) }
        cardRect = local(card)
        pillRect = local(now)
        restRect = local(rest)
        restRadius = min(rest.width, rest.height) / 2

        view?.removeFromSuperview()
        v.frame.origin = cardRect.origin
        v.onClose = { [weak self] in self?.dismiss(reason: "✕") }
        v.onCopy = { [weak self] in self?.copyWords() }
        v.onPaste = { [weak self] in self?.pasteNow(via: "the Paste button") }
        root.addSubview(v)
        view = v

        armed = false
        remaining = Self.life
        v.armed = false
        v.life = 1
        swallowing = nil
        isVisible = true
        panel.alphaValue = 1
        panel.ignoresMouseEvents = true

        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if still {
            // A cross-fade: the card simply appears where it will sit.
            setGlass(cardRect, radius: PasteCardView.radius)
            v.entrance(at: .infinity)
            panel.alphaValue = 0
            phase = .open
        } else {
            setGlass(pillRect, radius: min(pillRect.width, pillRect.height) / 2)
            v.entrance(at: 0)
            phase = .opening
        }
        // Fresh pixels before the window comes on (see SpeechCard.show).
        root.needsDisplay = true
        panel.displayIfNeeded()
        panel.orderFrontRegardless()
        // The card takes over the pill's seat: the pill goes invisible,
        // then settles to rest underneath, ready for the way back.
        host.concealPill(true)
        pill.state = .idle
        if still {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                panel.animator().alphaValue = 1
            }
        } else {
            startMotion()
        }
        startClock()
        startPolling()
        startTap()
        host.playSound("SayCtrlNudge")
        host.log("Paste card: holding \(words.count) chars — \(target.summary)")
    }

    /// A box of `size` edge-anchored in `window` the way the pill anchors
    /// its capsule (PillView.capsuleRect).
    private static func anchored(_ size: NSSize, in window: NSRect, dock: PillDock) -> NSRect {
        let x: CGFloat
        switch dock.hAlign {
        case .left:   x = window.minX
        case .center: x = window.midX - size.width / 2
        case .right:  x = window.maxX - size.width
        }
        let y: CGFloat
        switch dock.vAlign {
        case .bottom: y = window.minY
        case .middle: y = window.midY - size.height / 2
        case .top:    y = window.maxY - size.height
        }
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// The card sits on the pill's seat and grows into the screen: up from
    /// a bottom seat, down from the top one, sideways out of a side one —
    /// the edge the pill hugs stays where it is. Kept on the screen.
    static func cardFrame(size: NSSize, from pill: NSRect, dock: PillDock, in visible: NSRect) -> NSRect {
        var x: CGFloat
        switch dock.hAlign {
        case .left:   x = pill.minX
        case .center: x = pill.midX - size.width / 2
        case .right:  x = pill.maxX - size.width
        }
        var y: CGFloat
        switch dock.vAlign {
        case .bottom: y = pill.minY
        case .middle: y = pill.midY - size.height / 2
        case .top:    y = pill.maxY - size.height
        }
        let f = visible.insetBy(dx: 8, dy: 8)
        x = max(f.minX, min(x, f.maxX - size.width))
        y = max(f.minY, min(y, f.maxY - size.height))
        return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    // MARK: Motion

    /// The glass follows a spring from one shape to another; the rows ride
    /// the same clock. Frame by frame, like the pill's own reshape: the
    /// frost is a behind-window blur the window server cuts to the view's
    /// shape, and only the view's real frame moves that cut.
    private func startMotion() {
        motionStart = CACurrentMediaTime()
        guard motionTimer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.stepMotion() }
        RunLoop.main.add(t, forMode: .common)
        motionTimer = t
        stepMotion()
    }

    private func stopMotion() {
        motionTimer?.invalidate()
        motionTimer = nil
    }

    private func stepMotion() {
        let t = CACurrentMediaTime() - motionStart
        switch phase {
        case .opening:
            let p = Self.spring(t, stiffness: 230, damping: 21)
            setGlass(Self.lerp(pillRect, cardRect, p),
                     radius: Self.lerp(min(pillRect.width, pillRect.height) / 2, PasteCardView.radius, min(p, 1)))
            view?.entrance(at: t)
            if t >= 0.7 {
                stopMotion()
                setGlass(cardRect, radius: PasteCardView.radius)
                view?.entrance(at: .infinity)
                phase = .open
            }
        case .closing:
            // The rows go first; then the glass puts itself away.
            let fade = 0.11
            view?.exit(at: t / fade)
            let s = max(0, t - fade)
            let p = Self.spring(s, stiffness: 300, damping: 36)
            setGlass(Self.lerp(cardRect, restRect, p),
                     radius: Self.lerp(PasteCardView.radius, restRadius, min(p, 1)))
            if s >= 0.42 { finishClose() }
        case .open:
            stopMotion()
        }
    }

    private func setGlass(_ r: NSRect, radius: CGFloat) {
        if backdrop.frame != r { backdrop.frame = r }
        PillView.setGlassCorner(backdrop, min(radius, min(r.width, r.height) / 2))
        panel.invalidateShadow()
    }

    /// A unit mass on a damped spring let go at 0, heading for 1. 230/21
    /// settles in about 0.45 s with a slight overshoot; 300/36 is a touch
    /// past critical and never crosses 1.
    static func spring(_ t: Double, stiffness k: Double, damping c: Double) -> CGFloat {
        guard t > 0 else { return 0 }
        let w0 = k.squareRoot()
        let zeta = c / (2 * w0)
        if zeta > 1 {
            let root = (zeta * zeta - 1).squareRoot()
            let r1 = -w0 * (zeta - root), r2 = -w0 * (zeta + root)
            return CGFloat(1 - (r2 * exp(r1 * t) - r1 * exp(r2 * t)) / (r2 - r1))
        }
        if zeta == 1 { return CGFloat(1 - exp(-w0 * t) * (1 + w0 * t)) }
        let wd = w0 * (1 - zeta * zeta).squareRoot()
        let decay = exp(-zeta * w0 * t)
        return CGFloat(1 - decay * (cos(wd * t) + zeta * w0 / wd * sin(wd * t)))
    }

    static func lerp(_ a: CGFloat, _ b: CGFloat, _ p: CGFloat) -> CGFloat { a + (b - a) * p }
    static func lerp(_ a: NSRect, _ b: NSRect, _ p: CGFloat) -> NSRect {
        let minX = lerp(a.minX, b.minX, p), maxX = lerp(a.maxX, b.maxX, p)
        let minY = lerp(a.minY, b.minY, p), maxY = lerp(a.maxY, b.maxY, p)
        return NSRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
    }

    // MARK: Dismiss

    /// Put the card away. Animated, it folds back into the pill, which
    /// reappears once the glass has landed on its seat. Not animated — a
    /// new dictation is starting — it is simply gone.
    func dismiss(animated: Bool = true, reason: String? = nil, then: (() -> Void)? = nil) {
        guard isVisible else { return }
        if let reason = reason { host?.log("Paste card: closed by \(reason)") }
        stopWatching()
        panel.ignoresMouseEvents = true
        afterClose = then
        guard animated else {
            stopMotion()
            finishClose()
            return
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            stopMotion()
            phase = .closing
            host?.concealPill(false)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard self?.phase == .closing else { return }
                self?.finishClose()
            })
            return
        }
        // Mid-opening, the way out starts from wherever the glass is.
        if phase == .opening { cardRect = backdrop.frame }
        phase = .closing
        startMotion()
    }

    private func finishClose() {
        stopMotion()
        guard isVisible else { return }
        isVisible = false
        phase = .open
        host?.concealPill(false)
        panel.orderOut(nil)
        panel.alphaValue = 1
        view?.removeFromSuperview()
        view = nil
        words = ""
        let then = afterClose
        afterClose = nil
        then?()
    }

    private func stopWatching() {
        clockTimer?.invalidate()
        clockTimer = nil
        pollTimer?.invalidate()
        pollTimer = nil
        copiedWork?.cancel()
        copiedWork = nil
        armed = false
        stopTap()
    }

    // MARK: The clock and the pointer

    /// Thirty times a second: the card takes clicks only while the pointer
    /// is over it (the window's transparent margin must never eat a click
    /// meant for the app underneath — see Pill.syncClickability), and its
    /// life runs down only while the pointer is elsewhere.
    private func startClock() {
        lastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tickClock() }
        RunLoop.main.add(t, forMode: .common)
        clockTimer = t
    }

    private func tickClock() {
        let now = CACurrentMediaTime()
        let dt = now - lastTick
        lastTick = now
        guard isVisible, phase != .closing else { return }
        let card = cardRect.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
        let over = NSMouseInRect(NSEvent.mouseLocation, card, false)
        if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
        guard !over else { return }
        remaining -= dt
        view?.life = CGFloat(max(0, remaining / Self.life))
        if remaining <= 0 { dismiss(reason: "its clock running out") }
    }

    // MARK: Arming

    /// Four times a second, off the main thread (an app that has hung must
    /// not hang the card): has a text box taken the focus?
    private func startPolling() {
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
    }

    private func poll() {
        guard isVisible, !polling, let host = host else { return }
        polling = true
        let terminal = host.frontAppIsTerminal
        axQueue.async { [weak self] in
            let reading = PasteTarget.read(terminal: terminal)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.polling = false
                guard self.isVisible, self.phase != .closing else { return }
                // Whatever the paste itself would have gone ahead with arms
                // the card: a text box, and the apps the look can't read
                // (a terminal is the everyday case) — never SayControl.
                let ready = reading.verdict != .notEditable && !reading.ours
                self.setArmed(ready, app: reading.appName)
            }
        }
    }

    private func setArmed(_ on: Bool, app: String) {
        guard let v = view else { return }
        if on { v.target = app } else if !armed { v.missedApp = app }
        guard on != armed else { return }
        armed = on
        v.armed = on
        host?.log("Paste card: \(on ? "armed — a text box in \(app)" : "disarmed")")
    }

    // MARK: Paste and Copy

    func pasteNow(via: String) {
        guard isVisible, armed, let host = host else { return }
        host.log("Paste card: pasting \(words.count) chars into \(view?.target ?? "?") via \(via)")
        armed = false
        let text = words
        // pasteText with learn off: the words go back on the clipboard (the
        // user may have copied something since), ⌘V, the pill's success,
        // and no look for a text box — there is one, the poll just saw it.
        // A held sequence (words, screenshot, words; a file behind them)
        // replays in spoken order instead.
        if let replay = replay {
            self.replay = nil
            replay()
        } else {
            host.pasteText(text, learn: false)
        }
        host.playSound("SayCtrlMatch")
        dismiss()
    }

    private func copyWords() {
        guard isVisible else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(words, forType: .string)
        host?.log("Paste card: words copied")
        view?.copied = true
        copiedWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.view?.copied = false }
        copiedWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3, execute: work)
    }

    // MARK: The Return hook

    private func startTap() {
        stopTap()
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let card = Unmanaged<PasteCard>.fromOpaque(refcon!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = card.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if let held = card.swallowing, code == held {
                if type == .keyUp { card.swallowing = nil }
                return nil   // the rest of the Return that pasted
            }
            guard type == .keyDown else { return Unmanaged.passUnretained(event) }
            let mods = event.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate])
            if (code == 36 || code == 76), mods.isEmpty, card.armed {
                card.swallowing = code
                DispatchQueue.main.async { card.pasteNow(via: "Return") }
                return nil
            }
            if code == 53 {
                // Esc closes the card and still reaches the app.
                DispatchQueue.main.async { card.dismiss(reason: "Esc") }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let made = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            // No tap, no Return: the button still pastes, and Esc still closes.
            host?.log("Paste card: key tap unavailable — Return won't paste, the button will")
            escMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
                if e.keyCode == 53 { self?.dismiss(reason: "Esc") }
            }
            return
        }
        tap = made
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, made, 0)
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: made, enable: true)
    }

    private func stopTap() {
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            CFMachPortInvalidate(tap)
        }
        tap = nil
        tapSource = nil
        if let m = escMonitor { NSEvent.removeMonitor(m) }
        escMonitor = nil
        // A Return mid-press keeps its key-up hook until the key-up lands;
        // the tap goes, so the flag goes too.
        swallowing = nil
    }
}

// MARK: - The card's drawing

/// The card's content: the header, the words, the actions and the life bar,
/// each its own row so the entrance can bring them in one after another.
/// Fixed width; the height follows the words (one line or two).
final class PasteCardView: NSView {
    static let width: CGFloat = 256
    static let radius: CGFloat = 14
    static let padTop: CGFloat = 11, padBottom: CGFloat = 11
    static let padLeft: CGFloat = 13, padRight: CGFloat = 12
    static let gap: CGFloat = 7
    static let headH: CGFloat = 18
    static let actionsH: CGFloat = 22
    static let lineH: CGFloat = 19

    /// Made once (see PillView's fonts).
    static let wordsFont: NSFont = {
        let base = NSFont.systemFont(ofSize: 14)
        let serif = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
        return NSFont(descriptor: serif, size: 14) ?? base
    }()
    static let titleFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    static let hintFont = NSFont.systemFont(ofSize: 11.5)
    static let buttonFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    static let emberInk = NSColor(srgbRed: 0.110, green: 0.102, blue: 0.086, alpha: 1)   // #1C1A16

    static let wordsStyle: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = lineH
        p.maximumLineHeight = lineH
        p.lineBreakMode = .byWordWrapping
        return p
    }()
    /// One line on a baseline, cut with an ellipsis when it runs out of
    /// `width` — a long app name mustn't run under the buttons.
    static func drawLine(_ text: String, font: NSFont, color: NSColor,
                         x: CGFloat, baseline: CGFloat, width: CGFloat) {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        let s = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
        // Laid out from the top of the box: its top is the ascender above
        // the baseline.
        let h = ceil(font.ascender - font.descender)
        s.draw(with: NSRect(x: x, y: baseline + font.ascender - h, width: max(0, width), height: h),
               options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    static func wordsHeight(_ words: String) -> CGFloat {
        let h = (words as NSString).boundingRect(
            with: NSSize(width: width - padLeft - padRight, height: 10_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: wordsFont, .paragraphStyle: wordsStyle]).height
        return h > lineH * 1.5 ? lineH * 2 : lineH
    }

    var onClose: (() -> Void)?
    var onCopy: (() -> Void)?
    var onPaste: (() -> Void)?

    let header: PasteCardHeader
    let body: PasteCardWords
    let actions: PasteCardActions
    let lifeBar: PasteCardLife
    /// What rides with the words — "Screenshot", "photo.heic" — when there is.
    let extrasRow: PasteCardExtras?
    private var homes: [NSPoint] = []
    private var rows: [NSView] { [header, body] + (extrasRow.map { [$0] } ?? []) + [actions, lifeBar] }

    var missedApp: String {
        get { header.app }
        set { header.app = newValue }
    }
    /// The app a paste would go into now, for the armed hint.
    var target = "" { didSet { actions.target = target } }
    var armed = false { didSet { actions.armed = armed } }
    var copied = false { didSet { actions.copied = copied } }
    /// 1 → 0 as the card's clock runs down.
    var life: CGFloat = 1 { didSet { lifeBar.fraction = life } }

    init(words: String, app: String, extras: [PasteExtra] = []) {
        let wordsH = Self.wordsHeight(words)
        let extrasH: CGFloat = extras.isEmpty ? 0 : PasteCardExtras.height + Self.gap
        let h = Self.padTop + Self.headH + Self.gap + wordsH + extrasH + Self.gap + Self.actionsH + Self.padBottom
        let w = Self.width
        header = PasteCardHeader(frame: NSRect(x: 0, y: h - Self.padTop - Self.headH, width: w, height: Self.headH))
        let above = Self.padBottom + Self.actionsH + Self.gap
        extrasRow = extras.isEmpty ? nil
            : PasteCardExtras(frame: NSRect(x: 0, y: above, width: w, height: PasteCardExtras.height), extras: extras)
        body = PasteCardWords(frame: NSRect(x: 0, y: above + extrasH, width: w, height: wordsH))
        // The actions row reaches past the buttons so the Paste glow fits.
        actions = PasteCardActions(frame: NSRect(x: 0, y: Self.padBottom - 5, width: w, height: Self.actionsH + 10))
        lifeBar = PasteCardLife(frame: NSRect(x: 0, y: 0, width: w, height: 4))
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: h))
        wantsLayer = true
        header.app = app
        body.words = words
        header.close.target = self
        header.close.action = #selector(closeClicked)
        actions.copy.target = self
        actions.copy.action = #selector(copyClicked)
        actions.paste.target = self
        actions.paste.action = #selector(pasteClicked)
        for r in rows { r.wantsLayer = true; addSubview(r) }
        homes = rows.map { $0.frame.origin }
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func closeClicked() { onClose?() }
    @objc private func copyClicked() { onCopy?() }
    @objc private func pasteClicked() { onPaste?() }

    /// The rows arrive one after another as the glass opens: 110 ms in,
    /// 40 ms apart, each fading up and rising five points over 220 ms.
    /// The life bar only fades — it sits on the card's edge.
    func entrance(at t: Double) {
        for (i, row) in rows.enumerated() {
            let local = min(1, max(0, (t - 0.11 - 0.04 * Double(i)) / 0.22))
            let e = CGFloat(1 - pow(1 - local, 3))   // ease-out
            row.alphaValue = e
            let rise: CGFloat = row === lifeBar ? 0 : 5 * (1 - e)
            row.setFrameOrigin(NSPoint(x: homes[i].x, y: homes[i].y - rise))
        }
    }

    /// On the way out the rows fade together, over `p` 0 → 1.
    func exit(at p: Double) {
        let a = CGFloat(1 - min(1, max(0, p)))
        for (i, row) in rows.enumerated() {
            row.alphaValue = a * a
            row.setFrameOrigin(homes[i])
        }
    }

    /// A click on the card's own surface is the card's, not the app's below.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
}

/// The amber mark, "No text box in <App>", and the close button.
final class PasteCardHeader: NSView {
    let close = PasteCardButton(look: .close, label: "")
    var app = "" { didSet { if app != oldValue { needsDisplay = true } } }

    private static let mark: NSImage? = {
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            .applying(.init(paletteColors: [PillView.amberBadge]))
        return NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        close.frame = NSRect(x: frame.width - PasteCardView.padRight - 18 + 4, y: 0, width: 18, height: 18)
        addSubview(close)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let square = NSRect(x: PasteCardView.padLeft, y: (bounds.height - 18) / 2, width: 18, height: 18)
        PillView.amberBadge.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: square, xRadius: 6, yRadius: 6).fill()
        if let m = Self.mark {
            let s = m.size
            m.draw(in: NSRect(x: (square.midX - s.width / 2).rounded(), y: (square.midY - s.height / 2).rounded(),
                              width: s.width, height: s.height))
        }
        let x = square.maxX + 7
        let font = PasteCardView.titleFont
        // Centered on the square by its cap height, like a label on a badge.
        PasteCardView.drawLine("No text box in \(app)", font: font, color: PillView.amberBadge,
                               x: x, baseline: (square.midY - font.capHeight / 2).rounded(),
                               width: close.frame.minX - 4 - x)
    }
}

/// Something held alongside the words: the screenshots and the file a
/// dictation carried. Shown as chips so nothing reads as lost, and pasted
/// with the words, in spoken order, by Paste ⏎.
struct PasteExtra {
    let symbol: String
    let label: String
    let tint: NSColor

    static func screenshots(_ n: Int) -> PasteExtra {
        PasteExtra(symbol: "camera", label: n > 1 ? "\(n) screenshots" : "Screenshot", tint: PillView.skyAction)
    }
    static func file(_ name: String?) -> PasteExtra {
        PasteExtra(symbol: "paperclip", label: name ?? "File", tint: PillView.amberBadge)
    }
}

/// The extras as a row of small chips under the words.
final class PasteCardExtras: NSView {
    static let height: CGFloat = 20
    private static let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
    private let extras: [PasteExtra]

    init(frame: NSRect, extras: [PasteExtra]) {
        self.extras = extras
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        var x = PasteCardView.padLeft
        let limit = bounds.width - PasteCardView.padRight
        for e in extras {
            let p = NSMutableParagraphStyle()
            p.lineBreakMode = .byTruncatingMiddle
            let label = NSAttributedString(string: e.label, attributes: [.font: Self.font, .foregroundColor: e.tint, .paragraphStyle: p])
            let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold).applying(.init(paletteColors: [e.tint]))
            let img = NSImage(systemSymbolName: e.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
            let iconW = ceil(img?.size.width ?? 0)
            // Icon, five points, label: laid out from the symbol's real width.
            let textX = 8 + iconW + 5
            let w = min(textX + ceil(label.size().width) + 9, limit - x)
            guard w > 40 else { break }
            let chip = NSRect(x: x, y: 0, width: w, height: Self.height)
            e.tint.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: chip, xRadius: Self.height / 2, yRadius: Self.height / 2).fill()
            if let img = img {
                let s = img.size
                img.draw(in: NSRect(x: chip.minX + 8, y: chip.midY - s.height / 2, width: s.width, height: s.height))
            }
            label.draw(with: NSRect(x: chip.minX + textX, y: chip.midY - Self.font.capHeight / 2 + Self.font.descender,
                                    width: w - textX - 8, height: 15),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            x = chip.maxX + 6
        }
    }
}

/// The words, in the serif, two lines at most.
final class PasteCardWords: NSView {
    var words = "" { didSet { needsDisplay = true } }
    private static let lift = (PasteCardView.lineH - NSLayoutManager().defaultLineHeight(for: PasteCardView.wordsFont)) / 2

    override func draw(_ dirtyRect: NSRect) {
        // A take that was only a command ("take a screenshot") has no words
        // to show — the chips below carry it.
        let empty = words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let s = NSAttributedString(string: empty ? "No words, only what's below." : words, attributes: [
            .font: PasteCardView.wordsFont,
            .foregroundColor: empty ? PillView.glassMuted : PillView.glassInk,
            .paragraphStyle: PasteCardView.wordsStyle,
            .baselineOffset: Self.lift,
        ])
        s.draw(with: NSRect(x: PasteCardView.padLeft, y: 0,
                            width: bounds.width - PasteCardView.padLeft - PasteCardView.padRight,
                            height: bounds.height),
               options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
    }
}

/// The hint, Copy, and Paste ⏎. Paste is dim until a text box has the
/// focus; armed, it wears a soft ember ring and the hint names the app.
final class PasteCardActions: NSView {
    let copy = PasteCardButton(look: .subtle, label: "Copy")
    let paste = PasteCardButton(look: .ember, label: "Paste ⏎")
    var armed = false {
        didSet {
            guard armed != oldValue else { return }
            paste.isEnabled = armed
            paste.needsDisplay = true
            needsDisplay = true
        }
    }
    var target = "" { didSet { if target != oldValue { needsDisplay = true } } }
    var copied = false {
        didSet {
            copy.label = copied ? "Copied" : "Copy"
            layoutCopy()
            needsDisplay = true   // the hint gives up the room
        }
    }
    /// The row's buttons sit this far up from the view's bottom (the view
    /// reaches past them for the glow).
    private static let inset: CGFloat = 5

    override init(frame: NSRect) {
        super.init(frame: frame)
        let h = PasteCardView.actionsH
        let pw = PasteCardButton.width(for: "Paste ⏎", look: .ember)
        paste.frame = NSRect(x: frame.width - PasteCardView.padRight - pw, y: Self.inset, width: pw, height: h)
        layoutCopy()
        paste.isEnabled = false
        addSubview(copy)
        addSubview(paste)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Copy hugs its label and hangs off Paste's left edge, so "Copied"
    /// grows leftward into the hint for its moment instead of shifting Paste.
    private func layoutCopy() {
        let w = PasteCardButton.width(for: copy.label, look: .subtle)
        copy.frame = NSRect(x: paste.frame.minX - 6 - w, y: Self.inset, width: w, height: PasteCardView.actionsH)
    }

    override func draw(_ dirtyRect: NSRect) {
        if armed {
            // The glow: four points of ember at 22% around the button.
            let ring = paste.frame.insetBy(dx: -4, dy: -4)
            PillView.emberBar.withAlphaComponent(0.22).setFill()
            NSBezierPath(roundedRect: ring, xRadius: 11, yRadius: 11).fill()
        }
        let font = PasteCardView.hintFont
        let x = PasteCardView.padLeft
        let room = copy.frame.minX - 8 - x
        // The whole sentence when it fits; beside two buttons on a 256-point
        // card it doesn't (131 points for 104), and a clipped "…to p" reads
        // worse than the short form, which Paste's own label finishes.
        let long = "Click a text box to paste"
        let fits = (long as NSString).size(withAttributes: [.font: font]).width <= room
        let hint = armed ? "Paste into \(target)" : fits ? long : "Click a text box"
        let midY = Self.inset + PasteCardView.actionsH / 2
        PasteCardView.drawLine(hint, font: font, color: armed ? PillView.glassInk : PillView.glassMuted,
                               x: x, baseline: (midY - font.capHeight / 2).rounded(), width: room)
    }
}

/// Two points along the card's bottom edge: the time the card has left,
/// running down from the right. Clipped to the card's rounded corners.
final class PasteCardLife: NSView {
    var fraction: CGFloat = 1 { didSet { if fraction != oldValue { needsDisplay = true } } }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let card = NSRect(x: 0, y: 0, width: bounds.width, height: 60).insetBy(dx: 1, dy: 1)
        let r = PasteCardView.radius - 1
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: card, xRadius: r, yRadius: r).addClip()
        let bar = NSRect(x: 0, y: 1, width: bounds.width, height: 2)
        NSColor.white.withAlphaComponent(0.07).setFill()
        bar.fill()
        PillView.amberBadge.withAlphaComponent(0.55).setFill()
        NSRect(x: 0, y: 1, width: (bounds.width * fraction).rounded(), height: 2).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// The card's buttons, drawn by hand in the glass's palette. First-mouse
/// like FirstMouseButton (which is final, so the override is repeated
/// here): the first click on the card is a click, not a wake-up — the card
/// belongs to an app that is never in front.
final class PasteCardButton: NSButton {
    enum Look { case subtle, ember, close }
    let look: Look
    var label: String { didSet { if label != oldValue { needsDisplay = true } } }
    private var hovering = false

    private static let closeMark: NSImage? = {
        let cfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        return NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")?.withSymbolConfiguration(cfg)
    }()

    static func width(for label: String, look: Look) -> CGFloat {
        let w = (label as NSString).size(withAttributes: [.font: PasteCardView.buttonFont]).width
        return ceil(w) + 18
    }

    init(look: Look, label: String) {
        self.look = look
        self.label = label
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
        refusesFirstResponder = true
        setAccessibilityLabel(look == .close ? "Close" : label)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        // activeAlways: the card's app is never the active one.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let pressed = isHighlighted
        switch look {
        case .close:
            guard let m = Self.closeMark else { return }
            let ink = hovering ? PillView.glassInk : PillView.glassMuted
            if hovering {
                NSColor.white.withAlphaComponent(pressed ? 0.14 : 0.08).setFill()
                NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
            }
            let s = m.size
            let tinted = NSImage(size: s, flipped: false) { r in
                m.draw(in: r)
                ink.set()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: (bounds.midX - s.width / 2).rounded(), y: (bounds.midY - s.height / 2).rounded(),
                                   width: s.width, height: s.height))
        case .subtle:
            let fill = NSColor.white.withAlphaComponent(pressed ? 0.16 : hovering ? 0.12 : 0.08)
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
            fill.setFill()
            shape.fill()
            NSColor.white.withAlphaComponent(0.10).setStroke()
            shape.lineWidth = 1
            shape.stroke()
            drawLabel(PillView.glassInk)
        case .ember:
            let enabled = isEnabled
            let base = PillView.emberBar
            let fill = !enabled ? base.withAlphaComponent(0.4)
                : pressed ? base.blended(withFraction: 0.15, of: .black) ?? base
                : hovering ? base.blended(withFraction: 0.08, of: .white) ?? base
                : base
            fill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
            drawLabel(PasteCardView.emberInk.withAlphaComponent(enabled ? 1 : 0.55))
        }
    }

    private func drawLabel(_ ink: NSColor) {
        let font = PasteCardView.buttonFont
        let s = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: ink])
        let w = ceil(s.size().width)
        s.draw(at: NSPoint(x: ((bounds.width - w) / 2).rounded(),
                           y: (bounds.midY - font.capHeight / 2).rounded() + font.descender))
    }
}
