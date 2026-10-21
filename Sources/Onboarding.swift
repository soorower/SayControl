// First run, in one window that never shows a step number.
//
// The entrance: the dictation pill appears on its own over the desktop,
// hears "Welcome to SayControl" a word at a time, and opens into the window
// (SayCtrlWelcome.wav is timed to it). The window is the website's hero on
// the right — the sky, and the headline the pill keeps finishing — and the
// ways in on the left: Continue with Google, which finishes in the browser on
// saycontrol.com, or an email address, which grows a name and a password box
// right there (EmailSignInForm).
//
// Signed in, it says so ("Welcome, Sorower.") and moves on by itself to the
// switches: Microphone and Accessibility, which dictation needs; the Voice
// model, only on a Mac with nothing to transcribe with; then Input
// Monitoring and the Globe key, which make fn reliable. One row is open at a
// time with one button, the sky shows what that switch is for, and each
// ticks green with its own note when macOS says it is on — nothing here is
// pretended, the rows read what macOS actually granted. With the needed ones
// on, "Skip for now →" in the corner opens the app; with all of them on, it
// opens by itself.
//
// Opening the app: the window grows into the main one. The name stays at
// the top and the account at the foot while the checklist becomes the
// sidebar, and then the pill says hello once, where it will always be.
//
// Designed in design/welcome-redesign.html. It shows once; `--onboarding`
// brings it back, as does "Run the setup again" on the Help pane, and
// `--onboarding-demo` plays it with sign-in and permissions pretended, to
// look at without touching this Mac's grants.
import Cocoa
import AVFoundation

/// The app's fn handling lives on the delegate; the setup borrows it.
private var appDelegate: AppDelegate { NSApp.delegate as! AppDelegate }

enum Onboarding {
    static var done: Bool {
        get { Config.shared.flag("ONBOARDED", default: false) }
        set { Config.shared.setFlag("ONBOARDED", newValue) }
    }
    static var forced: Bool { CommandLine.arguments.contains("--onboarding") || demo }
    /// A dev flag: the whole first run with sign-in and the grants played by
    /// stand-ins, so it can be watched on a Mac that already has them.
    static var demo: Bool { CommandLine.arguments.contains("--onboarding-demo") || autoplay }
    /// The demo, clicking its own buttons: the whole run hands-free, then a
    /// short tour of the main window's pages.
    static var autoplay: Bool { CommandLine.arguments.contains("--onboarding-autoplay") }
    /// Show it at launch: never finished, asked for, or stopped partway (the
    /// relaunch macOS does after an Input Monitoring grant lands here).
    static var due: Bool { forced || !done || savedStep != nil }
    /// Where the user was: 0 signing in, 1 the switches. Granting Input
    /// Monitoring makes macOS quit and reopen the app; the setup comes back
    /// to the switches, not to the start. (Older builds saved 1–4 here; any
    /// of them means the switches now.)
    static var savedStep: Int? {
        get { Int(Config.shared.env()["ONBOARDING_STEP"] ?? "") }
        set { Config.shared.set("ONBOARDING_STEP", newValue.map(String.init)) }
    }
}

/// Whether anything can turn a voice into words yet: the cloud plan, a key
/// for a provider, or a model on this Mac.
enum VoiceEngine {
    static var ready: Bool { Config.shared.cloudOn || readyWithoutCloud }
    static var readyWithoutCloud: Bool {
        let cfg = Config.shared
        if cfg.provider != .local, cfg.apiKey != nil { return true }
        return LocalEngine.shared.selectedEntry() != nil
    }
}

// MARK: - The switches

/// One thing the setup asks for.
private enum Switch: CaseIterable {
    case mic, ax, voice, input, globe

    var title: String {
        switch self {
        case .mic: return "Microphone"
        case .ax: return "Accessibility"
        case .voice: return "Voice"
        case .input: return "Input Monitoring"
        case .globe: return "Globe key"
        }
    }
    /// Dictation can't happen without these; the others make fn reliable.
    var required: Bool { self == .mic || self == .ax || self == .voice }
    var symbol: String {
        switch self {
        case .mic: return "mic.fill"
        case .ax: return "accessibility"
        case .voice: return "waveform"
        case .input: return "keyboard"
        case .globe: return "globe"
        }
    }
    var tint: NSColor {
        switch self {
        case .mic: return Theme.hex(0xE5484D)
        case .ax: return Theme.hex(0x2C6FE0)
        case .voice: return Theme.hex(0xE5501F)
        case .input, .globe: return Theme.hex(0x7C5CF0)
        }
    }
    var why: String {
        switch self {
        case .mic: return "So it can hear you while you hold fn."
        case .ax: return "So words land where you type."
        case .voice: return "Something has to turn your voice into words. This one runs on this Mac."
        case .input: return "So fn works in every app, every time."
        case .globe: return "Set it to Do Nothing, so a tap of fn doesn’t open the emoji picker."
        }
    }
    var button: String {
        switch self {
        case .mic: return "Allow"
        case .voice: return "Download"
        default: return "Open Settings"
        }
    }
}

// MARK: - The window

final class OnboardingWindow: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindow()

    private var window: NSWindow?
    var isVisible: Bool { window?.isVisible ?? false }

    static var width: CGFloat { Theme.m(920) }
    static var height: CGFloat { Theme.m(640) }
    private static var column: CGFloat { Theme.m(380) }
    private var shooting: Bool { CommandLine.arguments.contains("--onboardingshot") }

    private enum Phase { case signIn, access, opening }
    private var phase = Phase.signIn

    // The column.
    private let root = SetupRoot()
    private let brand = Wordmark()
    private let signIn = NSStackView()
    private let signInTitle = Theme.hero("Welcome", 26, 500, Theme.ink, tracking: -0.04)
    private let signInLede = Theme.para("", 13 * 1.25, .regular, Theme.muted, lineHeight: 1.5)
    private var google: GoogleSignInButton?
    private var emailForm: EmailSignInForm?
    private let getStarted = FlatButton("Get started", .primary)
    private let who = AccountCard()
    private let fine = LegalLine()
    private let access = NSStackView()
    private let accessTitle = Theme.hero("Let it hear you.", 26, 500, Theme.ink, tracking: -0.04)
    private let accessLede = Theme.para("And type for you. macOS asks once for each, and you can turn any of them off later.",
                                        13 * 1.25, .regular, Theme.muted, lineHeight: 1.5)
    private let rowStack = NSStackView()
    private let acct = AccountChip()
    private let skip = FlatButton("Skip for now →", .quiet)

    // The sky.
    private let sky = SkyView()
    private let headline = HeroHeadline()
    private let illHost = NSView()
    private var illustration: Illustration?
    private var illKind: Switch?? = nil

    // The entrance and the way out.
    private let shell = ColorView(color: NSColor(srgbRed: 28/255, green: 26/255, blue: 22/255, alpha: 1))
    private var intro: IntroPill?
    private var ghost: SidebarGhost?
    private var brandTop: NSLayoutConstraint!, brandLeft: NSLayoutConstraint!
    private var acctLeft: NSLayoutConstraint!, acctBottom: NSLayoutConstraint!, acctWidth: NSLayoutConstraint!

    // The switches' state.
    private var kinds: [Switch] = []
    private var rows: [Switch: PermRow] = [:]
    private var granted: Set<Switch> = []
    private var current: Switch?
    private var axAsked = false
    private var axAskedAt: Date?
    private var inputAsked = false
    private var globeAsked = false
    private var voiceTimer: Timer?
    private var voiceFailed: String?
    private var demoGranted: Set<Switch> = []
    private var poll: Timer?
    private var finished = false
    private var skipShown = false
    private var timers: [Timer] = []

    // MARK: Presenting

    /// nil resumes where the last run stopped (or the start); a number goes
    /// there and forgets the saved place, the way "Run the setup again" does.
    /// A run from the top, in a window not already up, opens on the
    /// entrance; a resume after a relaunch comes back with a pop.
    func present(at step: Int? = nil) {
        Self.recordFramesIfAsked()
        let wasVisible = isVisible
        if window == nil { build() }
        if step != nil { Onboarding.savedStep = nil }
        let target = Onboarding.demo ? 0 : (step ?? Onboarding.savedStep ?? 0)
        let entrance = !wasVisible && target == 0 && !shooting
        if Onboarding.demo { Account.preview = false }
        NSApp.setActivationPolicy(.regular)
        SettingsUI.shared.installMainMenuIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        // While this window is up, fn is the window's: nothing records, and
        // the fn key in the pictures follows the real one.
        appDelegate.fnProbe = { [weak self] down in self?.fnKey(down) }
        guard let w = window else { return }
        if target == 0 {
            showSignIn()
        } else {
            showAccess(animated: false)
        }
        if entrance {
            playEntrance(w)
        } else {
            w.alphaValue = 1
            w.makeKeyAndOrderFront(nil)
            if !wasVisible && !shooting && target > 0 {
                play("SayCtrlPop")
                Motion.rise(root, duration: 0.45, distance: Theme.m(8))
            }
        }
    }

    /// Dev tool: `--onboarding-frames <dir>` (with the autoplay) photographs
    /// the screen four times a second for 40 s, so the motion can be checked
    /// frame by frame. It goes through /usr/sbin/screencapture and so
    /// borrows the app's own Screen Recording grant.
    private static var recording = false
    private static func recordFramesIfAsked() {
        guard !recording, let i = CommandLine.arguments.firstIndex(of: "--onboarding-frames"),
              CommandLine.arguments.count > i + 1 else { return }
        recording = true
        let dir = CommandLine.arguments[i + 1]
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let start = Date()
        var n = 0
        let t = Timer(timeInterval: 0.25, repeats: true) { timer in
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            if ms > 40_000 { timer.invalidate(); return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            // One file per display: the window opens on whichever has focus.
            p.arguments = ["-x", "-t", "jpg"] + (1...max(1, NSScreen.screens.count)).map {
                String(format: "%@/d%d-f%03d-%05dms.jpg", dir, $0, n, ms)
            }
            try? p.run()
            n += 1
        }
        RunLoop.main.add(t, forMode: .common)
    }

    func windowWillClose(_ notification: Notification) {
        stopEverything()
        appDelegate.fnProbe = nil
        if Onboarding.demo { Account.preview = nil }
        if !SettingsUI.shared.isWindowVisible { NSApp.setActivationPolicy(.accessory) }
    }

    private func stopEverything() {
        timers.forEach { $0.invalidate() }
        timers = []
        poll?.invalidate()
        poll = nil
        voiceTimer?.invalidate()
        voiceTimer = nil
        headline.stop()
        intro?.close()
        DragToListPanel.shared.hide()
    }

    private func later(_ t: TimeInterval, _ fn: @escaping () -> Void) {
        let timer = Timer(timeInterval: t, repeats: false) { _ in fn() }
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
    }

    private func play(_ name: String) {
        guard !shooting else { return }
        NSSound(named: name)?.play()
    }

    // MARK: Building

    private func build() {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: NSSize(width: Self.width, height: Self.height)),
                         styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Welcome to SayControl"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.delegate = self
        w.isReleasedWhenClosed = false
        w.center()
        w.backgroundColor = Theme.paper
        w.contentView = root

        // ── The column: the name, the way in, the small print ──
        signIn.orientation = .vertical
        signIn.alignment = .leading
        signIn.spacing = Theme.m(12)
        signInLede.font = .systemFont(ofSize: Theme.m(13))
        signIn.addArrangedSubview(signInTitle)
        signIn.addArrangedSubview(signInLede)
        signIn.setCustomSpacing(Theme.m(18), after: signInLede)
        if Account.available {
            let g = GoogleSignInButton(dark: true) { [weak self] in self?.continueWithGoogle() }
            google = g
            signIn.addArrangedSubview(g)
            let form = EmailSignInForm(tall: true)
            form.onGoogle = { [weak self] in self?.continueWithGoogle() }
            emailForm = form
            signIn.addArrangedSubview(form)
            signIn.setCustomSpacing(Theme.m(16), after: g)
        } else {
            getStarted.onClick = { [weak self] in self?.goAccess() }
            signIn.addArrangedSubview(getStarted)
        }
        signIn.addArrangedSubview(who)
        who.isHidden = true

        access.orientation = .vertical
        access.alignment = .leading
        access.spacing = Theme.m(8)
        accessLede.font = .systemFont(ofSize: Theme.m(13))
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = Theme.m(2)
        access.addArrangedSubview(accessTitle)
        access.addArrangedSubview(accessLede)
        access.setCustomSpacing(Theme.m(16), after: accessLede)
        access.addArrangedSubview(rowStack)
        access.isHidden = true

        skip.onClick = { [weak self] in self?.openApp() }
        skip.isHidden = true
        acct.isHidden = true
        fine.isHidden = !Account.available
        shell.isHidden = true

        for v in [sky, brand, signIn, access, fine, acct, skip, shell] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        for v in [headline, illHost] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            sky.addSubview(v)
        }
        let col = Self.column, side = Theme.m(40)
        brandTop = brand.topAnchor.constraint(equalTo: root.topAnchor, constant: Theme.m(44))
        brandLeft = brand.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: side)
        acctLeft = acct.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: side)
        acctBottom = acct.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Theme.m(20))
        acctWidth = acct.widthAnchor.constraint(equalToConstant: col - 2 * side)
        NSLayoutConstraint.activate([
            brandTop, brandLeft,
            signIn.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: side),
            signIn.widthAnchor.constraint(equalToConstant: col - 2 * side),
            signIn.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            signInLede.widthAnchor.constraint(equalTo: signIn.widthAnchor),
            ((google as NSView?) ?? getStarted).widthAnchor.constraint(equalTo: signIn.widthAnchor),
            ((emailForm as NSView?) ?? getStarted).widthAnchor.constraint(equalTo: signIn.widthAnchor),
            who.widthAnchor.constraint(equalTo: signIn.widthAnchor),

            access.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: side),
            access.widthAnchor.constraint(equalToConstant: col - 2 * side),
            access.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: Theme.m(4)),
            accessLede.widthAnchor.constraint(equalTo: access.widthAnchor),
            // The rows reach past the column's edges by their own padding, so
            // their tiles line up with the text above.
            rowStack.widthAnchor.constraint(equalTo: access.widthAnchor, constant: Theme.m(20)),

            fine.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: side),
            fine.widthAnchor.constraint(equalToConstant: col - 2 * side),
            fine.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Theme.m(22)),
            acctLeft, acctBottom, acctWidth,

            sky.topAnchor.constraint(equalTo: root.topAnchor, constant: Theme.m(10)),
            sky.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Theme.m(10)),
            sky.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Theme.m(10)),
            sky.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: col),

            headline.centerYAnchor.constraint(equalTo: sky.centerYAnchor, constant: -Theme.m(20)),
            headline.leadingAnchor.constraint(equalTo: sky.leadingAnchor, constant: Theme.m(24)),
            headline.trailingAnchor.constraint(equalTo: sky.trailingAnchor, constant: -Theme.m(24)),
            illHost.centerYAnchor.constraint(equalTo: sky.centerYAnchor),
            illHost.leadingAnchor.constraint(equalTo: sky.leadingAnchor, constant: Theme.m(28)),
            illHost.trailingAnchor.constraint(equalTo: sky.trailingAnchor, constant: -Theme.m(28)),

            skip.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Theme.m(24)),
            skip.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -Theme.m(20)),

            shell.topAnchor.constraint(equalTo: root.topAnchor),
            shell.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            shell.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            shell.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])

        NotificationCenter.default.addObserver(self, selector: #selector(accountChanged),
                                               name: .sayctrlAccountChanged, object: nil)
        window = w
    }

    // MARK: The entrance

    /// 0 s the pill pops up, listening. 0.52–1.12 s it hears "Welcome to
    /// SayControl". 1.62 s its bars settle. 1.88 s it opens into the window
    /// while the chord plays, the dark of the pill fading off the page, and
    /// 2.4 s the page arrives in reading order. Reduce Motion keeps the chord
    /// and shows the window.
    private func playEntrance(_ w: NSWindow) {
        let pieces = arrivalPieces()
        if Motion.reduced {
            play("SayCtrlAllSet")
            w.alphaValue = 1
            w.makeKeyAndOrderFront(nil)
            afterArrival()
            return
        }
        play("SayCtrlWelcome")
        pieces.forEach { $0.alphaValue = 0 }
        sky.glowAlpha = 0
        sky.tileAlpha = 0
        w.alphaValue = 0

        let intro = IntroPill()
        self.intro = intro
        intro.show(centeredOn: NSPoint(x: w.frame.midX, y: w.frame.midY))
        for (word, at) in [("Welcome", 0.52), ("to", 0.82), ("SayControl", 1.12)] {
            later(at) { intro.add(word: word) }
        }
        later(1.62) { intro.pill.bars.mode = .still }
        later(1.88) { [weak self] in self?.openOutOfPill(w) }
        later(2.4) { [weak self] in
            guard let self = self else { return }
            for (i, v) in pieces.enumerated() {
                Motion.rise(v, delay: [0.06, 0.14, 0.21, 0.29, 0.33, 0.47, 0.64, 0.70][min(i, 7)])
            }
            Motion.tween(duration: 1.3) { [weak self] k in self?.sky.glowAlpha = k }
            Motion.tween(duration: 1.5, delay: 0.25) { [weak self] k in self?.sky.tileAlpha = k }
            self.afterArrival()
        }
    }

    /// What arrives, in reading order: the name, the welcome, the way in,
    /// the headline, the small print.
    private func arrivalPieces() -> [NSView] {
        var out: [NSView] = [brand, signInTitle, signInLede]
        if let g = google { out.append(g) } else { out.append(getStarted) }
        if let form = emailForm { out.append(form) }
        out += headline.pieces
        if !fine.isHidden { out.append(fine) }
        return out
    }

    /// The pill becomes the window: the window is masked to the pill's shape
    /// and place, dark all over, and the mask grows to the whole window while
    /// the dark fades off it.
    private func openOutOfPill(_ w: NSWindow) {
        guard let pillRect = intro?.screenRect, let layer = root.layer else {
            intro?.close()
            w.alphaValue = 1
            w.makeKeyAndOrderFront(nil)
            return
        }
        let buttons = w.standardWindowButton(.closeButton)?.superview
        buttons?.alphaValue = 0
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        shell.isHidden = false
        shell.alphaValue = 1
        // The pill's rect in the root's (flipped) coordinates.
        let inWindow = w.convertFromScreen(pillRect)
        let r = root.convert(inWindow, from: nil)
        let from = CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)
        let full = root.bounds
        let to = CGPath(roundedRect: full, cornerWidth: Theme.m(12), cornerHeight: Theme.m(12), transform: nil)
        let mask = CAShapeLayer()
        mask.frame = full
        mask.path = to
        layer.mask = mask
        let grow = CABasicAnimation(keyPath: "path")
        grow.fromValue = from
        grow.toValue = to
        grow.duration = 0.76
        grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.65, 0, 0.15, 1)
        mask.add(grow, forKey: "open")

        w.alphaValue = 1
        w.makeKeyAndOrderFront(nil)
        intro?.close()
        intro = nil
        later(0.30) { [weak self] in
            guard let self = self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.52
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.shell.animator().alphaValue = 0
            }, completionHandler: { [weak self] in self?.shell.isHidden = true })
        }
        later(0.8) { [weak self] in
            guard let self = self else { return }
            self.root.layer?.mask = nil
            w.backgroundColor = Theme.paper
            w.isOpaque = true
            w.hasShadow = true
            w.invalidateShadow()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                buttons?.animator().alphaValue = 1
            }
        }
    }

    /// The window is up: the headline starts talking, and a returning
    /// account moves on by itself.
    private func afterArrival() {
        Config.shared.log("Onboarding: window up (\(phase == .signIn ? "welcome" : "switches"))")
        headline.start(after: Motion.reduced ? 0 : 2.8)
        if Onboarding.autoplay, phase == .signIn, !Account.signedIn {
            later(2.4) { [weak self] in self?.continueWithGoogle() }
        }
        if phase == .signIn, Account.available, Account.signedIn {
            later(0.8) { [weak self] in self?.goAccess() }
        }
    }

    // MARK: Signing in

    private func showSignIn() {
        phase = .signIn
        stopEverything()
        signIn.isHidden = false
        access.isHidden = true
        acct.isHidden = true
        skip.isHidden = true
        fine.isHidden = !Account.available
        headline.isHidden = false
        illHost.subviews.forEach { $0.removeFromSuperview() }
        illustration = nil
        illKind = nil
        [signIn, fine, headline].forEach { Motion.settle($0) }
        headline.pieces.forEach { Motion.settle($0) }
        headline.phrase.set(HeroHeadline.home, animated: false)
        fillSignIn()
        if !isVisible || shooting { return }
        afterArrival()
    }

    private func fillSignIn() {
        if !Account.available {
            Theme.setHero(signInTitle, "Welcome")
            setPara(signInLede, "Dictation that runs on this Mac. What you say, your dictionary and your phrases stay here.")
            return
        }
        if Account.signedIn {
            Theme.setHero(signInTitle, "Welcome, \(Account.name.split(separator: " ").first.map(String.init) ?? Account.name).")
            setPara(signInLede, "You’re signed in. Setting up this Mac…")
            google?.isHidden = true
            emailForm?.isHidden = true
            // The window outlives the sign-in: folded back now, signing out
            // later finds one empty box, not the sign-up it was left on.
            emailForm?.reset()
            who.fill()
            who.isHidden = false
        } else {
            Theme.setHero(signInTitle, "Welcome")
            setPara(signInLede, Cloud.shared.waitingOnBrowser
                    ? "Finish in your browser: pick your Google account, and it comes back here by itself."
                    : "Sign in to start dictating. Your dictionary and history stay on this Mac.")
            google?.isHidden = false
            emailForm?.isHidden = false
            who.isHidden = true
        }
    }

    private func continueWithGoogle() {
        if Onboarding.demo {
            later(1.0) {
                Account.preview = true
                NotificationCenter.default.post(name: .sayctrlAccountChanged, object: nil)
            }
            return
        }
        Account.signInWithGoogle { [weak self] _ in self?.fillSignIn() }
        fillSignIn()
    }

    @objc private func accountChanged() {
        guard phase == .signIn, Account.available else { return }
        let was = !who.isHidden
        fillSignIn()
        guard Account.signedIn, !was else { return }
        // A new account talks through the cloud plan it just got — always in
        // a user's copy, which has nothing else; in the developers' build
        // only when there's no other engine.
        if Config.retail || !VoiceEngine.readyWithoutCloud, !Config.shared.cloud, !Onboarding.demo {
            Config.shared.setFlag("CLOUD", true)
            Config.shared.log("Onboarding: signed in with no other engine, cloud dictation on")
        }
        play("SayCtrlSignedIn")
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        Motion.rise(who, duration: 0.48)
        Motion.rise(signInTitle, duration: 0.42, distance: Theme.m(6))
        later(0.8) { [weak self] in self?.goAccess() }
    }

    // MARK: The switches

    /// From the welcome to the switches: the welcome and the headline drift
    /// off, the checklist rises in their place, the account settles at the
    /// foot.
    private func goAccess() {
        guard phase == .signIn else { return }
        Onboarding.savedStep = Onboarding.demo ? nil : 1
        headline.stop()
        if Motion.reduced { return showAccess(animated: false) }
        for v in [signIn, fine] + headline.pieces { Motion.leave(v, duration: 0.36, lift: Theme.m(10)) }
        later(0.42) { [weak self] in self?.showAccess(animated: true) }
    }

    private func showAccess(animated: Bool) {
        phase = .access
        if !Onboarding.demo { Onboarding.savedStep = 1 }
        signIn.isHidden = true
        fine.isHidden = true
        headline.isHidden = true
        access.isHidden = false
        acct.isHidden = !Account.available
        acct.fill()
        [signIn, fine, headline].forEach { Motion.settle($0) }
        headline.pieces.forEach { Motion.settle($0) }
        sky.glowAlpha = 1
        sky.tileAlpha = 1
        buildRows()
        refresh(animated: false)
        if animated {
            Motion.rise(accessTitle)
            Motion.rise(accessLede, delay: 0.07)
            for (i, k) in kinds.enumerated() { if let r = rows[k] { Motion.rise(r, delay: 0.15 + Double(i) * 0.07) } }
            if !acct.isHidden { Motion.rise(acct, delay: 0.42) }
        }
        poll?.invalidate()
        // Four times a second: a grant made in System Settings ticks here
        // as good as at once. The checks are cheap reads.
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh(animated: true) }
        RunLoop.main.add(t, forMode: .common)
        poll = t
    }

    private func buildRows() {
        rowStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        rows = [:]
        granted = []
        current = nil
        finished = false
        skipShown = false
        demoGranted = []
        Theme.setHero(accessTitle, "Let it hear you.")
        setPara(accessLede, "And type for you. macOS asks once for each, and you can turn any of them off later.")
        // A user's copy is cloud-only: the account is the voice, so there is
        // no model to fetch here. The developers' build still offers one
        // when nothing else can write the words down.
        kinds = Switch.allCases.filter { $0 != .voice || (!Config.retail && !VoiceEngine.ready) }
        for k in kinds {
            let row = PermRow(name: k.title, need: k.required ? "Required" : "Recommended", symbol: k.symbol,
                              tint: k.tint, why: k.why, button: k.button) { [weak self] in self?.ask(k) }
            rows[k] = row
            rowStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowStack.widthAnchor).isActive = true
        }
        if let voice = rows[.voice], let entry = LocalEngine.entry(LocalEngine.recommendedID) {
            voice.setWhy("Something has to turn your voice into words. \(entry.name) runs on this Mac: \(LocalEngine.humanSize(entry.bytes)).")
        }
    }

    private func isOn(_ k: Switch) -> Bool {
        if Onboarding.demo { return demoGranted.contains(k) }
        switch k {
        case .mic: return Permissions.microphone == .granted
        case .ax: return Permissions.accessibility == .granted
        case .voice: return VoiceEngine.ready
        case .input: return Permissions.inputMonitoring == .granted
        case .globe: return Permissions.globeKeyIsQuiet
        }
    }

    /// Reads what macOS says now and moves the list along. Runs every second
    /// while the switches show, and right after anything is asked for.
    private func refresh(animated: Bool) {
        guard phase == .access else { return }
        for (i, k) in kinds.enumerated() where !granted.contains(k) && isOn(k) {
            granted.insert(k)
            rows[k]?.set(.done, animated: animated)
            if animated {
                play("SayCtrlGrant" + (kinds.count == 5 ? ["C5", "D5", "E5", "G5", "B5"] : ["C5", "E5", "G5", "B5"])[min(i, kinds.count - 1)])
                // Back from System Settings to the tick that just landed. A
                // tray still out under the window brings the user back itself,
                // after its own tick.
                if [.ax, .input, .globe].contains(k), !Onboarding.demo, !DragToListPanel.shared.isActive {
                    comeBack()
                }
            }
            if k == .input || k == .globe, illKind == k { (illustration?.art as? KeyArt)?.ok = true }
        }
        updateWhys()

        // The moment a switch is on, the next one opens.
        let next = kinds.first { !granted.contains($0) }
        for k in kinds where !granted.contains(k) {
            rows[k]?.set(k == next ? .current : .todo, animated: animated)
        }
        if next != current || illKind == nil {
            current = next
            showIllustration(next, animated: animated)
            Config.shared.log("Onboarding: on \(next.map { $0.title } ?? "all set")")
            if Onboarding.autoplay, let k = next, !granted.contains(k) {
                later(1.6) { [weak self] in
                    guard let self = self, self.current == k, !self.granted.contains(k) else { return }
                    self.ask(k)
                }
            }
        }

        let requiredOn = kinds.filter(\.required).allSatisfy { granted.contains($0) }
        if next == nil, !finished {
            finished = true
            allSet(animated: animated)
        } else if requiredOn, next != nil, !skipShown {
            skipShown = true
            let left = kinds.filter { !granted.contains($0) }.count
            swapHero(accessTitle, "Ready to talk.", animated: animated)
            swapPara(accessLede, "That’s all it needs. " + (left == 1 ? "The one below is optional." : "The \(left == 2 ? "two" : "rest") below are optional."), animated: animated)
            skip.isHidden = false
            if animated { Motion.fadeIn(skip, delay: 0.3, duration: 0.5) }
        }
    }

    /// This window, in front again.
    private func comeBack() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func updateWhys() {
        if let row = rows[.mic], !granted.contains(.mic), !Onboarding.demo {
            let denied = Permissions.microphone == .denied
            row.setWhy(denied ? "Turned off in System Settings. Switch it on for SayControl." : Switch.mic.why)
            row.button.title = denied ? "Open Settings" : "Allow"
        }
        if let row = rows[.ax], !granted.contains(.ax), !Onboarding.demo {
            let stale = axAskedAt.map { Date().timeIntervalSince($0) > 20 } ?? false
            row.setWhy(stale ? "Already on in the list but not recognised? Remove SayControl with the minus button, then add it back."
                       : axAsked ? "Turn SayControl on in the Accessibility list, then come back." : Switch.ax.why)
        }
        if let row = rows[.input], !granted.contains(.input), inputAsked || Permissions.inputMonitoring == .denied, !Onboarding.demo {
            row.setWhy("Turn SayControl on in the Input Monitoring list. macOS will offer to reopen it; the setup picks up here.")
        }
        if let row = rows[.globe], !granted.contains(.globe), globeAsked {
            row.setWhy("In Keyboard settings, set “Press 🌐 key to” to Do Nothing.")
        }
    }

    /// The row's one button: what macOS needs doing for that switch.
    private func ask(_ k: Switch) {
        if Onboarding.demo { return pretend(k) }
        switch k {
        case .mic:
            if Permissions.microphone == .denied {
                Permissions.open("Privacy_Microphone")
            } else {
                Permissions.requestMicrophone { [weak self] in self?.refresh(animated: true) }
            }
        case .ax:
            // One click does all of it: Apple's request (which also puts the
            // app in the list), the pane itself, and the helper saying what
            // to do.
            axAsked = true
            if axAskedAt == nil { axAskedAt = Date() }
            Permissions.guide(.accessibility) { [weak self] in self?.comeBack() }
        case .input:
            inputAsked = true
            Permissions.guide(.inputMonitoring) { [weak self] in self?.comeBack() }
        case .globe:
            globeAsked = true
            Permissions.openKeyboardSettings()
        case .voice:
            downloadVoice()
        }
        refresh(animated: true)
    }

    /// `--onboarding-demo`: each switch turns on a moment after its button,
    /// the way it would after a trip to System Settings. Input Monitoring
    /// plays the quit and reopen macOS does.
    private func pretend(_ k: Switch) {
        if k == .input, let w = window {
            later(0.4) {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    w.animator().alphaValue = 0
                }
            }
            later(1.1) { [weak self] in
                guard let self = self else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    w.animator().alphaValue = 1
                }
                self.play("SayCtrlPop")
                self.demoGranted.insert(k)
                self.refresh(animated: true)
            }
            return
        }
        later(0.4) { [weak self] in
            self?.demoGranted.insert(k)
            self?.refresh(animated: true)
        }
    }

    // MARK: The Voice row

    private func downloadVoice() {
        let id = LocalEngine.recommendedID
        guard let entry = LocalEngine.entry(id), let row = rows[.voice] else { return }
        if voiceTimer != nil {
            LocalEngine.shared.cancel(id)
            voiceTimer?.invalidate()
            voiceTimer = nil
            row.button.title = "Download"
            row.setWhy("Something has to turn your voice into words. \(entry.name) runs on this Mac: \(LocalEngine.humanSize(entry.bytes)).")
            return
        }
        let cfg = Config.shared
        if cfg.provider != .local {
            cfg.provider = .local
            cfg.log("Onboarding: the user chose the on-device model")
        }
        LocalEngine.shared.download(id)
        row.button.title = "Cancel"
        row.setWhy("Starting…")
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.pollVoice() }
        RunLoop.main.add(t, forMode: .common)
        voiceTimer = t
    }

    private func pollVoice() {
        let id = LocalEngine.recommendedID
        guard let entry = LocalEngine.entry(id), let row = rows[.voice],
              let info = LocalEngine.shared.rows().first(where: { $0["id"] as? String == id }) else { return }
        if info["installed"] as? Bool == true {
            voiceTimer?.invalidate()
            voiceTimer = nil
            Config.shared.set(Provider.local.modelVar, id)
            LocalEngine.shared.warmUp()
            row.setWhy("Ready.")
            refresh(animated: true)
            return
        }
        if let err = info["error"] as? String {
            voiceTimer?.invalidate()
            voiceTimer = nil
            row.setWhy("The download didn’t finish: \(err). Check the connection and try again.")
            row.button.title = "Try again"
            return
        }
        let p = (info["progress"] as? Double ?? 0) / 100
        row.setWhy("Downloading… \(Int(p * 100))% · \(LocalEngine.humanSize(Int64(Double(entry.bytes) * p))) of \(LocalEngine.humanSize(entry.bytes))")
    }

    // MARK: The pictures

    private func showIllustration(_ k: Switch?, animated: Bool) {
        if illKind == .some(k) { return }
        illKind = .some(k)
        let old = illustration
        let make: () -> Illustration = { [weak self] in
            guard let self = self else { return Illustration(art: MarkArt(), plain: "", em: "", small: "") }
            switch k {
            case .mic?:
                return Illustration(art: DarkPill("Listening…", size: 13.5, height: 42), plain: "It listens ",
                                    em: "while you hold fn.", small: "Let go, and the mic is off.")
            case .ax?:
                return Illustration(art: TypingArt(), plain: "Your words land ", em: "where the cursor is.",
                                    small: "In Mail, Slack, Notes, anywhere you can type.")
            case .voice?:
                return Illustration(art: MarkArt(), plain: "It runs ", em: "on this Mac.",
                                    small: "Nothing you say leaves it.")
            case .input?:
                let key = KeyArt(.input)
                key.ok = self.granted.contains(.input)
                return Illustration(art: key, plain: "fn works ", em: "in every app.",
                                    small: "Even while the screen is switching between apps.")
            case .globe?:
                let key = KeyArt(.globe)
                key.ok = self.granted.contains(.globe)
                return Illustration(art: key, plain: "A tap of fn ", em: "stays quiet.",
                                    small: "No emoji picker popping up while you talk.")
            case nil:
                return Illustration(art: MarkArt(), plain: "Hold fn, ", em: "and talk.",
                                    small: "Anywhere on your Mac. Your first words are a second away.")
            }
        }
        let place = { [weak self] in
            guard let self = self else { return }
            old?.removeFromSuperview()
            let ill = make()
            ill.translatesAutoresizingMaskIntoConstraints = false
            self.illHost.addSubview(ill)
            NSLayoutConstraint.activate([
                ill.topAnchor.constraint(equalTo: self.illHost.topAnchor),
                ill.bottomAnchor.constraint(equalTo: self.illHost.bottomAnchor),
                ill.leadingAnchor.constraint(equalTo: self.illHost.leadingAnchor),
                ill.trailingAnchor.constraint(equalTo: self.illHost.trailingAnchor),
            ])
            self.illustration = ill
            self.illHost.layoutSubtreeIfNeeded()
            if animated { for (i, p) in ill.pieces.enumerated() { Motion.rise(p, delay: Double(i) * 0.09, duration: 0.56) } }
        }
        if let old = old, animated, !Motion.reduced {
            Motion.leave(old, duration: 0.2, lift: Theme.m(8)) { place() }
        } else {
            place()
        }
    }

    /// The real fn key, while this window is up.
    private func fnKey(_ down: Bool) {
        (illustration?.art as? KeyArt)?.realPress(down)
    }

    // MARK: All set, and out

    private func allSet(animated: Bool) {
        skip.isHidden = true
        if animated { play("SayCtrlAllSet") }
        swapHero(accessTitle, "You’re all set.", animated: animated)
        swapPara(accessLede, "Hold fn anywhere and talk.", animated: animated)
        // Nothing left to decide: the app opens by itself.
        if !shooting { later(animated ? 1.0 : 0.6) { [weak self] in self?.openApp() } }
    }

    /// The window grows into the main one. The checklist and the picture
    /// go; a sidebar panel fills in where the column was while the window
    /// takes the main window's frame, the name sliding to where the main
    /// window keeps it and the account to its foot; then the main window
    /// takes over in place, its rows and page arriving, and the pill says
    /// hello.
    private func openApp() {
        guard phase == .access, let w = window else { return }
        phase = .opening
        stopEverything()
        appDelegate.fnProbe = nil
        Onboarding.done = true
        Onboarding.savedStep = nil
        if Onboarding.demo { Account.preview = nil }
        // Opening at login is never switched on for anyone: it is theirs to
        // turn on, in Settings › General.
        Config.shared.log("Onboarding finished")
        play("SayCtrlOpen")
        if Onboarding.autoplay {
            // A short tour, to watch the pages move.
            for (i, key) in ["insights", "dictionary", "tones", "overview"].enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.5 + Double(i) * 1.6) {
                    SettingsUI.shared.select(key)
                    Config.shared.log("Onboarding tour: \(key)")
                }
            }
        }

        guard let target = SettingsUI.shared.prepareArrival(selecting: "overview"), !Motion.reduced else {
            w.close()
            SettingsUI.shared.present(selecting: "overview")
            appDelegate.sayHello(after: 0.8)
            return
        }
        for v in [access, skip, illHost] as [NSView] { Motion.leave(v, duration: 0.3, lift: Theme.m(8)) }

        later(0.3) { [weak self] in
            guard let self = self else { return }
            let ghost = SidebarGhost()
            ghost.alphaValue = 0
            ghost.translatesAutoresizingMaskIntoConstraints = false
            self.root.addSubview(ghost, positioned: .below, relativeTo: self.brand)
            let gTop = ghost.topAnchor.constraint(equalTo: self.root.topAnchor, constant: 0)
            let gLeft = ghost.leadingAnchor.constraint(equalTo: self.root.leadingAnchor, constant: 0)
            let gBottom = ghost.bottomAnchor.constraint(equalTo: self.root.bottomAnchor, constant: 0)
            let gWidth = ghost.widthAnchor.constraint(equalToConstant: Self.column)
            NSLayoutConstraint.activate([gTop, gLeft, gBottom, gWidth])
            self.root.layoutSubtreeIfNeeded()
            self.ghost = ghost

            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.75
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.65, 0, 0.2, 1)
                ctx.allowsImplicitAnimation = true
                w.animator().setFrame(target.frame, display: true)
                gTop.animator().constant = target.side.minY
                gLeft.animator().constant = target.side.minX
                gBottom.animator().constant = -(target.frame.height - target.side.maxY)
                gWidth.animator().constant = target.side.width
                ghost.animator().alphaValue = 1
                self.sky.animator().alphaValue = 0
                self.brandTop.animator().constant = target.brand.minY
                self.brandLeft.animator().constant = target.brand.minX
                self.acctLeft.animator().constant = target.foot.minX
                self.acctBottom.animator().constant = -(target.frame.height - target.foot.maxY)
                self.acctWidth.animator().constant = target.foot.width
            }, completionHandler: { [weak self] in
                guard let self = self else { return }
                SettingsUI.shared.arrive(over: w)
                Config.shared.log("Onboarding: the app took over")
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.25
                    w.animator().alphaValue = 0
                }, completionHandler: {
                    w.close()
                    self.resetAfterOpening()
                })
                appDelegate.sayHello(after: 1.1)
            })
        }
    }

    /// Put the window back as it was built, for the next "Run the setup again".
    private func resetAfterOpening() {
        ghost?.removeFromSuperview()
        ghost = nil
        sky.alphaValue = 1
        brandTop.constant = Theme.m(44)
        brandLeft.constant = Theme.m(40)
        acctLeft.constant = Theme.m(40)
        acctBottom.constant = -Theme.m(20)
        acctWidth.constant = Self.column - Theme.m(80)
        [access, skip, illHost].forEach { Motion.settle($0) }
        window?.setContentSize(NSSize(width: Self.width, height: Self.height))
        window?.center()
        phase = .signIn
    }

    // MARK: Text that changes

    private func setPara(_ f: NSTextField, _ s: String) {
        let attrs = f.attributedStringValue.length > 0 ? f.attributedStringValue.attributes(at: 0, effectiveRange: nil) : [:]
        f.attributedStringValue = NSAttributedString(string: s, attributes: attrs)
    }

    private func swapHero(_ f: NSTextField, _ s: String, animated: Bool) {
        guard animated, !Motion.reduced else { return Theme.setHero(f, s) }
        Motion.leave(f, duration: 0.18, lift: 0) {
            Theme.setHero(f, s)
            Motion.settle(f)
            Motion.rise(f, duration: 0.42, distance: Theme.m(6))
        }
    }

    private func swapPara(_ f: NSTextField, _ s: String, animated: Bool) {
        guard animated, !Motion.reduced else { return setPara(f, s) }
        Motion.leave(f, duration: 0.18, lift: 0) { [weak self] in
            self?.setPara(f, s)
            Motion.settle(f)
            Motion.rise(f, duration: 0.42, distance: Theme.m(6))
        }
    }

    // MARK: For --onboardingshot

    /// The email form at one of its steps, or folded back.
    func showFormForShot(_ step: EmailSignInForm.ShotStep?) {
        if let step = step { emailForm?.showForShot(step) } else { emailForm?.reset() }
    }

    /// The switches, drawn as they stand, for the snapshot tool.
    func showSwitchesForShot() {
        if window == nil { build() }
        phase = .signIn
        showAccess(animated: false)
    }
}

// MARK: - Pieces of the column

/// The window's ground: paper, top-down coordinates.
private final class SetupRoot: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Theme.paper.cgColor }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// The mark and the name as the site sets them: "Say" in ink, "Control" in ember.
private final class Wordmark: NSView {
    init() {
        super.init(frame: .zero)
        let mark = MarkArt(side: 26)
        let font = Theme.heroFont(17, 600)
        let name = NSTextField(labelWithString: "")
        let s = NSMutableAttributedString(string: "Say", attributes: [.font: font, .foregroundColor: Theme.ink, .kern: font.pointSize * -0.035])
        s.append(NSAttributedString(string: "Control", attributes: [.font: font, .foregroundColor: Theme.ember, .kern: font.pointSize * -0.035]))
        name.attributedStringValue = s
        let row = Theme.hstack([mark, name], spacing: Theme.m(4))
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -Theme.m(4)),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Who signed in: a disc with the initial, the name and the address.
private final class AccountCard: NSView {
    private let disc = ColorView(color: Theme.ember)
    private let initial = NSTextField(labelWithString: "")
    private lazy var photo = AccountPhotoView(in: disc)
    private let name = Theme.text("", 13.5 * 1.25, .semibold)
    private let mail = Theme.text("", 12 * 1.25, .regular, Theme.muted)

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(10)
        layer?.borderWidth = 1
        let d = Theme.m(36)
        disc.wantsLayer = true
        disc.layer?.cornerRadius = d / 2
        initial.font = Theme.heroFont(15, 600)
        initial.textColor = .white
        initial.alignment = .center
        name.font = .systemFont(ofSize: Theme.m(13.5), weight: .semibold)
        mail.font = .systemFont(ofSize: Theme.m(12))
        initial.translatesAutoresizingMaskIntoConstraints = false
        disc.addSubview(initial)
        let text = Theme.vstack([name, mail], spacing: Theme.m(1))
        let row = Theme.hstack([disc, text], spacing: Theme.m(12))
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            disc.widthAnchor.constraint(equalToConstant: d),
            disc.heightAnchor.constraint(equalToConstant: d),
            initial.centerXAnchor.constraint(equalTo: disc.centerXAnchor),
            initial.centerYAnchor.constraint(equalTo: disc.centerYAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: Theme.m(12)),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.m(12)),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(12)),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Theme.m(12)),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func fill() {
        name.stringValue = Account.name
        mail.stringValue = Account.email.isEmpty ? "Signed in with Google" : Account.email
        initial.stringValue = String(Account.name.prefix(1)).uppercased()
        initial.isHidden = photo.refresh()
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Theme.surface.cgColor
        layer?.borderColor = Theme.hairline.cgColor
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// The account at the foot of the switches: small, over a hairline, with a
/// green "Signed in".
private final class AccountChip: NSView {
    private let disc = ColorView(color: Theme.ember)
    private let initial = NSTextField(labelWithString: "")
    private lazy var photo = AccountPhotoView(in: disc)
    private let name = Theme.text("", 12.5 * 1.25, .semibold)
    private let mail = Theme.text("", 11.5 * 1.25, .regular, Theme.muted)

    init() {
        super.init(frame: .zero)
        let rule = ColorView(color: Theme.hairline)
        let d = Theme.m(28)
        disc.wantsLayer = true
        disc.layer?.cornerRadius = d / 2
        initial.font = Theme.heroFont(12.5, 600)
        initial.textColor = .white
        initial.alignment = .center
        name.font = .systemFont(ofSize: Theme.m(12.5), weight: .semibold)
        mail.font = .systemFont(ofSize: Theme.m(11.5))
        let dot = ColorView(color: Theme.moss)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = Theme.m(3)
        let ok = Theme.text("Signed in", 11 * 1.25, .regular, Theme.moss)
        ok.font = .systemFont(ofSize: Theme.m(11))
        let status = Theme.hstack([dot, ok], spacing: Theme.m(5))
        status.alignment = .centerY
        initial.translatesAutoresizingMaskIntoConstraints = false
        disc.addSubview(initial)
        let text = Theme.vstack([name, mail], spacing: 0)
        let row = Theme.hstack([disc, text, Theme.spacer(), status], spacing: Theme.m(10))
        row.alignment = .centerY
        for v in [rule, row] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: topAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            row.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: Theme.m(12)),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            disc.widthAnchor.constraint(equalToConstant: d),
            disc.heightAnchor.constraint(equalToConstant: d),
            initial.centerXAnchor.constraint(equalTo: disc.centerXAnchor),
            initial.centerYAnchor.constraint(equalTo: disc.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: Theme.m(6)),
            dot.heightAnchor.constraint(equalToConstant: Theme.m(6)),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func fill() {
        name.stringValue = Account.name
        mail.stringValue = Account.email.isEmpty ? "Signed in with Google" : Account.email
        initial.stringValue = String(Account.name.prefix(1)).uppercased()
        initial.isHidden = photo.refresh()
    }
}

/// "By continuing you agree to the terms and privacy policy." with links.
/// A read-only text view: a label can't style its links.
private final class LegalLine: NSView {
    init() {
        super.init(frame: .zero)
        let font = NSFont.systemFont(ofSize: Theme.m(11))
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.3
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.muted, .paragraphStyle: style]
        let s = NSMutableAttributedString(string: "By continuing you agree to the ", attributes: base)
        func link(_ text: String, _ url: String) -> NSAttributedString {
            NSAttributedString(string: text, attributes: base.merging([.link: URL(string: url)!]) { $1 })
        }
        s.append(link("terms", "https://saycontrol.com/terms"))
        s.append(NSAttributedString(string: " and ", attributes: base))
        s.append(link("privacy policy", "https://saycontrol.com/privacy"))
        s.append(NSAttributedString(string: ". Free includes \(Account.grouped(Account.freeWordsPerWeek)) cloud words a week.",
                                    attributes: base))
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textStorage?.setAttributedString(s)
        tv.linkTextAttributes = [.foregroundColor: Theme.muted,
                                 .underlineStyle: NSUnderlineStyle.single.rawValue,
                                 .cursor: NSCursor.pointingHand]
        let width = Theme.m(300)
        let height = ceil(s.boundingRect(with: NSSize(width: width, height: 1000),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 2
        tv.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tv)
        NSLayoutConstraint.activate([
            tv.topAnchor.constraint(equalTo: topAnchor),
            tv.bottomAnchor.constraint(equalTo: bottomAnchor),
            tv.leadingAnchor.constraint(equalTo: leadingAnchor),
            tv.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: height),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// The sidebar panel filling in while the window grows into the app.
private final class SidebarGhost: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(12)
        layer?.borderWidth = 1
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Theme.sidebarFill.cgColor
        layer?.borderColor = Theme.sidebarLine.cgColor
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

extension Theme {
    /// Sets a `hero` label's text without losing its face and tracking.
    static func setHero(_ f: NSTextField, _ s: String) {
        let attrs = f.attributedStringValue.length > 0 ? f.attributedStringValue.attributes(at: 0, effectiveRange: nil) : [:]
        f.attributedStringValue = NSAttributedString(string: s, attributes: attrs)
    }
}
