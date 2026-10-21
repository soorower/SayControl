// How it works — the sheet the Overview's hero and the foot of the sidebar
// open. It used to be every command in long lists; it shows instead now.
// Three tabs, one per way of using SayControl — Dictation (just talk),
// Controls (say it mid-sentence) and Command mode (change text you've
// written) — and on each a dial. The knob turns through the tab's points,
// one at a time, and only the point it's on opens: a title of a few words,
// one line, and a demo a few seconds long (DemoStage.swift). The others
// stay faint titles. The dial moves on by itself every 3.8 seconds, with a
// soft tick; the wheel, a drag, a click on a tick or a title, and the arrow
// keys turn it too, and pointing at a demo holds it. "See more" under the
// last point of Controls and Command mode opens the rest in place, and the
// terminal point opens every terminal command, while the dial waits.
//
// Drawn from design/howto-redesign.html (v2.1): its CSS pixels through
// How.px, Theme's colours light and dark, Bricolage for the display lines,
// ember only on what is said and what is live. Every phrase on it is one
// SayControl hears: Commands.swift (inline, attach, open, ask, scratch,
// send), CommandMode.swift and Shell.swift's table. The keys are the ones
// set in Settings. Both builds show the same sheet; Controls and Command
// mode wear a quiet Pro tag on the Free plan.
import Cocoa

// MARK: - What it shows

/// The three tabs, in the order they sit.
enum HowTab: Int, CaseIterable {
    case dictation, controls, command

    var title: String { ["Dictation", "Controls", "Command mode"][rawValue] }
    var subtitle: String { ["Just talk", "Say it mid-sentence", "Change text you’ve written"][rawValue] }
    var symbol: String { ["mic", "bolt", "wand.and.stars"][rawValue] }
    /// Spoken controls and command mode are Pro's on the cloud, and free
    /// off it (Account.controlsFree, Account.commandModeFree).
    var isPro: Bool { self != .dictation }
    var unlocked: Bool {
        switch self {
        case .dictation: return true
        case .controls:  return Account.controlsFree
        case .command:   return Account.commandModeFree
        }
    }
    /// Mockup pixels. A tab's demos share one height, so the list doesn't
    /// jump as the dial turns.
    var stageHeight: CGFloat { [72, 104, 150][rawValue] }
}

/// One stop on a tab's dial: a title of a few words, one line, a demo.
struct HowPoint {
    enum Extra {
        /// The assistants "ask …" can open, as chips over the demo.
        case services
        /// "All terminal commands" under the demo.
        case terminal
    }
    let title: String
    /// The page this is set up on, beside the title while it's open.
    var tag: String? = nil
    let line: String
    /// How long the dial stays before it moves on.
    var dwell: TimeInterval = 3.8
    var extra: Extra? = nil
    /// Built each time it plays, so it shows what's true now: your
    /// address, your keys.
    let demo: () -> Demo
}

extension HowTab {
    var points: [HowPoint] {
        switch self {
        case .dictation: return Self.dictationPoints
        case .controls:  return Self.controlPoints
        case .command:   return Self.commandPoints
        }
    }

    /// Typed as heard, then `part` (nil: all of it) turned into what lands.
    private static func heard(_ said: String, fix part: String? = nil, to: String) -> [Beat] {
        [.wait(0.2), .type(said), .wait(0.35), .fix(part, to: to)]
    }

    /// What happens to every dictation with nothing said for it: cleanup,
    /// the dictionary, phrases, tones, spoken formats, the names on screen.
    private static var dictationPoints: [HowPoint] {[
        HowPoint(title: "No more ums", line: "Ums and restarts are cleaned away.") {
            Demo(.line(), [.wait(0.2), .type("um, so I, I think it works"),
                           .wait(0.35), .strike("um, so I, "), .wait(0.65), .vanish, .wait(0.35), .add(".")])
        },
        HowPoint(title: "Fix a word once", tag: "Dictionary", line: "Correct it once, and it stays right.") {
            Demo(.line(), heard("open the art browser", fix: "art", to: "Arc"))
        },
        HowPoint(title: "Your saved text", tag: "Phrases", line: "Say a few words, get the rest.") {
            Demo(.line(), heard("my email address", to: Account.exampleEmail))
        },
        HowPoint(title: "The right tone", tag: "Tones", line: "Brief in Slack, an email in Mail.") {
            Demo(.line(lead: Demo.Chip(text: "Mail", symbol: "envelope")),
                 heard("can you review this today", to: "Could you review this today?"))
        },
        HowPoint(title: "Emails, links, numbers", line: "Written out, not spelled out.") {
            Demo(.line(), heard(Account.spokenExampleEmail, to: Account.exampleEmail))
        },
        HowPoint(title: "Names spelled right", line: "Names on your screen come out right.") {
            Demo(.line(corner: .window("Mimestream")),
                 heard("send it to the mime stream inbox", fix: "mime stream", to: "Mimestream"))
        },
    ]}

    /// Commands.swift's inline families, open, ask, scratch and send, and
    /// Shell.swift's terminal.
    private static var controlPoints: [HowPoint] {[
        HowPoint(title: "Take a screenshot", line: "It lands right where you said it.") {
            Demo(.line(), [.wait(0.15), .type("Here’s the dashboard, "), .wait(0.1), .say("take a screenshot"),
                           .wait(0.9), .unsay, .wait(0.2), .land(.shot), .wait(0.45), .type(" the totals look wrong.")])
        },
        HowPoint(title: "Copy the link", line: "The address of the tab you’re on.") {
            Demo(.line(), [.wait(0.15), .type("The full list is at "), .wait(0.1), .say("copy the link"),
                           .wait(0.9), .unsay, .wait(0.2), .land(.link("saycontrol.com/controls")), .wait(0.4), .type(".")])
        },
        HowPoint(title: "Attach a file", line: "The newest match joins your chat.") {
            Demo(.line(), [.wait(0.15), .type("Numbers for August, "), .wait(0.1),
                           .say("attach the payout PDF from downloads"), .wait(1.0), .unsay, .wait(0.2),
                           .attach("payout-august.pdf"), .wait(0.4), .type("does page two read right?", per: 0.026)])
        },
        HowPoint(title: "Open an app", line: "Or its website, if the app isn’t here.") {
            Demo(.line(caret: false), [.wait(0.25), .say("open Claude"), .wait(0.9), .open("Claude")])
        },
        // "…and ask Claude" said last: what came before it, the screenshot
        // too, is the message, already in Claude's composer.
        HowPoint(title: "Ask an AI", line: "Opens the site with your words already in.", dwell: 5.6, extra: .services) {
            Demo(.line(), [.wait(0.15), .type("Why is this total wrong? ", per: 0.022), .wait(0.06),
                           .say("take a screenshot"), .wait(0.59), .type(" and ", per: 0.034), .wait(0.04),
                           .say("ask Claude"), .wait(0.86), .fly, .wait(0.15), .browser("Claude", url: "claude.ai"),
                           .wait(0.35), .compose("Why is this total wrong?"), .wait(0.25), .composeShot])
        },
        // Under Reduce Motion it stops at the strike, so there's still
        // something to see.
        HowPoint(title: "Scratch that", line: "Takes back what you just said.") {
            Demo(.line(), [.wait(0.15), .type("…and I think we should ship it Friday. ", per: 0.024), .wait(0.1),
                           .say("scratch that"), .wait(0.85), .unsay, .strike(nil), .wait(0.65), .moving(.vanish)])
        },
        HowPoint(title: "Send it", line: "Presses Return for you.") {
            Demo(.line(corner: .key("return")), [.wait(0.15), .type("On my way, ten minutes. "), .wait(0.1),
                                                 .say("send it"), .wait(0.85), .press, .wait(0.2), .release, .fly,
                                                 .wait(0.3), .done("Message sent")])
        },
        HowPoint(title: "In a terminal", line: "Plain words become the command.", extra: .terminal) {
            Demo(.terminal("~/Projects/app"), [.wait(0.25), .say("list the files"), .wait(1.0), .becomes("ls")])
        },
    ]}

    /// Six of the instructions CommandMode.swift primes the recognizer with,
    /// each on text it would actually be said over.
    private static let rewrites: [(title: String, line: String, say: String, before: String, after: String)] = [
        ("Make it shorter", "Same point, fewer words.", "make it shorter",
         "I just wanted to check whether you maybe had a chance to look at the draft I sent over on Monday.",
         "Did you get a chance to look at Monday’s draft?"),
        ("Polish it", "Cleaner, and still in your voice.", "polish it",
         "so the launch is moving to friday because qa found some stuff",
         "The launch is moving to Friday because QA found a few issues."),
        ("Make it an email", "Greeting, body and sign-off.", "make it an email",
         "sam the q3 numbers are in the shared folder take a look before friday",
         "Hi Sam,\nThe Q3 numbers are in the shared folder. Could you take a look before Friday?\nThanks"),
        ("Fix the grammar", "Mistakes fixed, nothing else touched.", "fix the grammar",
         "Me and him was at the office when the files gets deleted.",
         "He and I were at the office when the files got deleted."),
        ("Bullet points", "A sentence becomes a list.", "bullet points",
         "We need the slides, the budget and a date for the review.",
         "• The slides\n• The budget\n• A date for the review"),
        ("Translate to English", "Your text, rewritten in English.", "translate to English",
         "¿Podemos mover la reunión al jueves?",
         "Can we move the meeting to Thursday?"),
    ]

    private static var commandPoints: [HowPoint] {
        rewrites.map { r in
            HowPoint(title: r.title, line: r.line) {
                Demo(.field(r.before), [.wait(0.15), .select, .wait(0.45), .press, .wait(0.1), .say(r.say, per: 0.028),
                                        .wait(0.4), .release, .wait(0.15), .rewrite(r.after)])
            }
        }
    }

    /// "See more" under Controls: the rest of what can be said there.
    static let moreControls: [(group: String, rows: [(say: String, does: String)])] = [
        ("Files", [
            ("“copy the file path”", "The path of what Finder has selected"),
            ("“copy the PDF path from downloads”", "That file’s path, as text"),
            ("“upload…”, “add…”, “insert…”", "Work the same as “attach”"),
            ("“the second one”", "Picks one when several files match"),
            ("“cancel”", "Closes that list"),
        ]),
        ("Open and ask", [
            ("“open terminal in the projects folder”", "A terminal already in that folder"),
            ("“open terminal here”", "In the folder Finder is showing"),
            ("“ask Claude how to fix this”", "Opens with your question in it"),
            ("“…and ask ChatGPT”", "Said last, what came before is the message"),
        ]),
        ("Fix and send", [
            ("“scratch the last sentence”", "Takes back just that sentence"),
            ("“…and send it”", "Said last, your words, then Return"),
        ]),
    ]

    /// Shell.swift's table, in three folding groups: each row a recipe or
    /// the literal layer, as written there.
    static let terminal: [(group: String, open: Bool, rows: [(say: String, lands: String)])] = [
        ("Files and folders", true, [
            ("list the files", "ls"), ("show me everything", "ls -la"),
            ("make a new folder called scripts", "mkdir scripts"),
            ("make a new file called notes dot md", "touch notes.md"),
            ("go to the src folder", "cd src"), ("change directory to downloads", "cd ~/Downloads"),
            ("go up one", "cd .."), ("go home", "cd ~"), ("where am I", "pwd"), ("clear the screen", "clear"),
        ]),
        ("Git", false, [
            ("add everything", "git add ."), ("add package dot json", "git add package.json"),
            ("commit saying fixed the login bug", "git commit -m \"fixed the login bug\""),
            ("commit everything saying fixed the login bug", "git commit -a -m \"fixed the login bug\""),
            ("add everything and commit saying ship it", "git add . && git commit -m \"ship it\""),
            ("push", "git push"), ("push to main", "git push origin main"), ("pull", "git pull"),
            ("fetch", "git fetch"), ("status", "git status"), ("what changed", "git status"),
            ("show me the diff", "git diff"), ("show me the last commit", "git log --oneline -1"),
            ("show me last five commits", "git log --oneline -5"),
            ("what branch am I on", "git branch --show-current"),
            ("switch to the fix-login branch", "git checkout fix-login"),
            ("make a new branch called auth redesign", "git checkout -b auth-redesign"),
            ("stash everything", "git stash"),
        ]),
        ("Anything else you name a tool for", false, [
            ("pnpm run dev", "pnpm run dev"), ("docker compose up dash d", "docker compose up -d"),
            ("touch package dot json", "touch package.json"),
            ("tail dash f logs slash server dot log", "tail -f logs/server.log"),
        ]),
    ]
}

// MARK: - The tick

/// The dial's tick: a short filtered click, made here rather than shipped —
/// a burst of noise through a band-pass at 2.8 kHz, with a blip falling from
/// 1.5 kHz to 700 Hz under it, the mockup's WebAudio recipe in an in-memory
/// WAV. Quiet on purpose. It plays only while How it works' speaker is on
/// and Settings' Sound cues is too.
enum HowTick {
    /// Read when the sheet opens and when its speaker is clicked, not on
    /// every tick: the settings file is read from disk.
    static var armed = false

    static func refresh() { armed = Config.shared.sounds && Config.shared.howtoTicks }

    static func play() {
        guard armed, !Motion.still, let s = sound else { return }
        s.stop()
        s.play()
    }

    private static let sound: NSSound? = NSSound(data: wav())

    private static func wav() -> Data {
        let rate = 44_100.0
        let n = Int(rate * 0.035)
        var out = [Double](repeating: 0, count: n)
        // The click: noise under a fast decay, band-passed (RBJ's constant
        // 0 dB band-pass, which is WebAudio's).
        let burst = Int(rate * 0.022)
        let w0 = 2 * Double.pi * 2800 / rate, q = 2.2
        let alpha = sin(w0) / (2 * q)
        let b0 = alpha, b2 = -alpha, a0 = 1 + alpha, a1 = -2 * cos(w0), a2 = 1 - alpha
        var seed: UInt32 = 0x9E37_79B9
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in 0..<n {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Double(seed >> 8) / Double(1 << 24) * 2 - 1
            let x = i < burst ? noise * pow(1 - Double(i) / Double(burst), 5) : 0
            let y = (b0 * x + b2 * x2 - a1 * y1 - a2 * y2) / a0
            x2 = x1; x1 = x; y2 = y1; y1 = y
            out[i] = y * 0.16
        }
        // The blip: a sine sliding down, fading out.
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / rate
            let f = 1500 * pow(700.0 / 1500.0, min(t, 0.02) / 0.02)
            phase += 2 * Double.pi * f / rate
            out[i] += sin(phase) * 0.025 * pow(0.0001 / 0.025, min(t, 0.03) / 0.03)
        }
        var data = Data()
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); put32(UInt32(36 + n * 2))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); put32(16); put16(1); put16(1)
        put32(UInt32(rate)); put32(UInt32(rate) * 2); put16(2); put16(16)
        data.append(contentsOf: Array("data".utf8)); put32(UInt32(n * 2))
        for v in out { put16(UInt16(bitPattern: Int16(max(-1, min(1, v)) * 32_767))) }
        return data
    }
}

// MARK: - The sheet

/// How it works, over the window the way Settings is: a header with the
/// title, the speaker and ×, the three tabs under it, and the picked tab's
/// page scrolling beneath. The page scrolls inside a clipped layer; the
/// sheet itself isn't clipped, or its rounded mask would take the lifted
/// shadow with it. It's built fresh every time it opens.
final class CommandsSheet: PaneView {
    /// The mockup's 940 × 748. It shrinks to fit a smaller window rather
    /// than hang off it — see SettingsUI.showCommands.
    static var sheetWidth: CGFloat { How.px(940) }
    static var sheetHeight: CGFloat { How.px(748) }
    /// The tab it opens on: the last one looked at.
    private static var lastTab: HowTab = .dictation

    /// Wired to the overlay's dismissal, so × closes the way esc does.
    var onClose: () -> Void = {}

    private let clip = NSView()
    private let head = NSView()
    private let headRow: NSStackView
    private let shade = HeadShade()
    private var speaker: IconButton!
    private let tabs = HowTabs()
    private let scroll = QuietScroll()
    private let doc = PageGround()
    private var page: HowPage?
    private var tab = CommandsSheet.lastTab
    /// Which tab change is the latest, so a slow fade-out from an earlier
    /// click doesn't put its page back over the newer one.
    private var turn = 0
    private var open = false
    private var placedHeight: CGFloat = 0

    override init(frame frameRect: NSRect) {
        let title = Theme.hero("How it works", 26 * 0.944, 500, tracking: -0.04)
        headRow = Theme.hstack([title, Theme.spacer()], spacing: How.px(6))
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(16)
        layer?.borderWidth = 1

        clip.wantsLayer = true
        clip.layer?.cornerRadius = Theme.m(16)
        clip.layer?.masksToBounds = true
        clip.fill(self)

        // The speaker: whether the dial ticks. Its own switch, under the
        // app's Sound cues.
        speaker = IconButton("speaker.wave.2", size: 34, icon: 15) { [weak self] in self?.toggleTicks() }
        let close = IconButton("xmark", size: 34, icon: 15, tip: "Close (esc)") { [weak self] in self?.onClose() }
        headRow.addArrangedSubview(speaker)
        headRow.addArrangedSubview(close)
        tabs.onPick = { [weak self] t in self?.show(t, animated: true) }

        for v in [headRow, tabs] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            head.addSubview(v)
        }
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = true
        scroll.verticalScroller = HiddenScroller()
        doc.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = doc
        for v in [scroll, head, shade] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            clip.addSubview(v)
        }
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: clip.topAnchor),
            head.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            head.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            // The mockup's head: 22 above, 32 in from the left, 22 from the
            // right; the tabs stop 10 short of the ×.
            headRow.topAnchor.constraint(equalTo: head.topAnchor, constant: How.px(22)),
            headRow.leadingAnchor.constraint(equalTo: head.leadingAnchor, constant: How.px(32)),
            headRow.trailingAnchor.constraint(equalTo: head.trailingAnchor, constant: -How.px(22)),
            headRow.heightAnchor.constraint(equalToConstant: How.px(30)),
            tabs.topAnchor.constraint(equalTo: headRow.bottomAnchor, constant: How.px(16)),
            tabs.leadingAnchor.constraint(equalTo: head.leadingAnchor, constant: How.px(32)),
            tabs.trailingAnchor.constraint(equalTo: head.trailingAnchor, constant: -How.px(32)),
            head.bottomAnchor.constraint(equalTo: tabs.bottomAnchor, constant: How.px(16)),

            scroll.topAnchor.constraint(equalTo: head.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),

            shade.topAnchor.constraint(equalTo: head.bottomAnchor),
            shade.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            shade.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            shade.heightAnchor.constraint(equalToConstant: How.px(10)),
        ])
        shade.alphaValue = 0
        tabs.select(tab, animated: false)
        syncSpeaker()

        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(planChanged), name: .sayctrlAccountChanged, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: Open and close

    override func paneAppeared() {
        open = true
        HowTick.refresh()
        syncSpeaker()
        superview?.layoutSubtreeIfNeeded()
        window?.makeFirstResponder(self)
        if let w = window {
            NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                                   name: NSWindow.didChangeOcclusionStateNotification, object: w)
        }
        // The head arrives a beat after the sheet, the page a beat after it.
        Motion.rise(headRow, delay: 0.09)
        Motion.rise(tabs, delay: 0.13)
        if page == nil { install(HowPage(tab), arrive: 0.14) }
        syncLive()
    }

    /// Everything stops: the dial's clock, the demo, the Dictation loop.
    override func paneDisappeared() {
        open = false
        page?.stop()
        if let w = window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: w)
        }
    }

    /// The dial only counts while somebody could be watching it.
    private func syncLive() {
        let visible = window.map { $0.occlusionState.contains(.visible) && !$0.isMiniaturized } ?? false
        page?.live = open && visible
    }
    @objc private func occlusionChanged() { syncLive() }

    // MARK: Tabs

    private func show(_ next: HowTab, animated: Bool) {
        guard next != tab || page == nil else { return }
        tab = next
        Self.lastTab = next
        tabs.select(next, animated: animated)
        turn += 1
        let mine = turn
        let old = page
        old?.stop()
        page = nil
        let put = { [weak self] in
            guard let self = self, self.turn == mine else { return }
            old?.removeFromSuperview()
            self.install(HowPage(next), arrive: 0)
        }
        if animated, let old = old, !Motion.reduced {
            Motion.leave(old, duration: Motion.Page.outDuration, lift: 4) { put() }
        } else {
            put()
        }
    }

    /// A page into the scroll, at the top, centred in the room it has, and
    /// its blocks rising into place `arrive` seconds from now.
    private func install(_ p: HowPage, arrive: TimeInterval) {
        page = p
        p.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(p)
        NSLayoutConstraint.activate([
            p.topAnchor.constraint(equalTo: doc.topAnchor, constant: How.px(14)),
            p.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: How.px(32)),
            p.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -How.px(32)),
            p.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -How.px(28)),
        ])
        p.onReveal = { [weak self] v in self?.reveal(v) }
        p.onTop = { [weak self] in self?.scrollTo(0) }
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        shade.alphaValue = 0
        doc.layoutSubtreeIfNeeded()
        placedHeight = scroll.contentView.bounds.height
        p.start(room: room)
        doc.layoutSubtreeIfNeeded()
        p.arrive(delay: arrive)
        syncLive()
    }

    /// The height a page has to sit in: the scroll's, less the page's own
    /// padding above and below.
    private var room: CGFloat { scroll.contentView.bounds.height - How.px(14) - How.px(28) }

    override func layout() {
        super.layout()
        // A window resized under the sheet: centre the page again in what
        // it has now, once this pass is done.
        let h = scroll.contentView.bounds.height
        if page != nil, h > 1, abs(h - placedHeight) > 0.5 {
            placedHeight = h
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.page?.place(room: self.room)
                self.scrolled()
            }
        }
    }

    // MARK: Scrolling

    @objc private func scrolled() {
        let y = scroll.contentView.bounds.origin.y
        let lifted = y > 2
        if (shade.alphaValue > 0.5) != lifted { Anim.fade(shade, to: lifted ? 1 : 0, 0.25) }
        page?.stick(visibleTop: y - How.px(14))
    }

    /// Brings a list that just opened into view, once it has finished
    /// opening: as much of it as fits, never its top off the top.
    private func reveal(_ v: NSView) {
        let wait = Motion.reduced ? 0 : 0.47
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self, weak v] in
            guard let self = self, let v = v, v.window != nil else { return }
            let clip = self.scroll.contentView
            let r = v.convert(v.bounds, to: self.doc)
            let visible = clip.documentVisibleRect
            let below = r.maxY - visible.maxY, above = r.minY - visible.minY
            guard below > 0 else { return }
            self.scrollTo(visible.minY + min(below + How.px(16), above - How.px(12)))
        }
    }

    private func scrollTo(_ y: CGFloat) {
        let clip = scroll.contentView
        let maxY = max(0, doc.frame.height - clip.bounds.height)
        let target = NSPoint(x: 0, y: min(max(0, y), maxY))
        guard !Motion.reduced else {
            clip.scroll(to: target)
            scroll.reflectScrolledClipView(clip)
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            ctx.timingFunction = Curve.ease.timing
            ctx.allowsImplicitAnimation = true
            clip.animator().setBoundsOrigin(target)
        }
        scroll.reflectScrolledClipView(clip)
    }

    // MARK: Keys

    override var acceptsFirstResponder: Bool { true }
    /// The arrows turn the dial: down and right on, up and left back.
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125, 124: page?.step(1)
        case 126, 123: page?.step(-1)
        default: super.keyDown(with: event)
        }
    }

    // MARK: Sound and plan

    private func toggleTicks() {
        guard Config.shared.sounds else { return }
        Config.shared.howtoTicks.toggle()
        HowTick.refresh()
        syncSpeaker()
        HowTick.play()
    }

    private func syncSpeaker() {
        let on = Config.shared.sounds && Config.shared.howtoTicks
        speaker.setSymbol(on ? "speaker.wave.2" : "speaker.slash", icon: 15)
        speaker.tint = on ? Theme.ink : nil
        speaker.toolTip = !Config.shared.sounds ? "Sound cues are off in Settings › System"
            : (on ? "Ticks on" : "Ticks off")
    }

    @objc private func planChanged() {
        tabs.syncPlan()
        page?.syncPlan()
    }

    // MARK: Look

    override var wantsUpdateLayer: Bool { true }
    /// The Settings sheet's paper, ring and shadow, so the two read as one
    /// kind of thing.
    override func updateLayer() {
        layer?.backgroundColor = Theme.paper.cgColor
        layer?.borderColor = Theme.dyn(Theme.hex(0x000000, 0.10), NSColor.white.withAlphaComponent(0.08)).cgColor
        layer?.shadowColor = Theme.hex(0x141822).cgColor
        layer?.shadowOpacity = isDark ? 0.6 : 0.26
        layer?.shadowRadius = 30
        layer?.shadowOffset = CGSize(width: 0, height: -24)
    }
    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layer?.shadowPath = CGPath(roundedRect: NSRect(origin: .zero, size: newSize), cornerWidth: Theme.m(16),
                                   cornerHeight: Theme.m(16), transform: nil)
    }
    /// A surface of its own: dragging it must not drag the window, and a
    /// click on its background stops here.
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

    // MARK: For the snapshot tool

    /// A tab, the point its dial is on, and whether See more and the
    /// terminal's list are open — the states --snapshot draws.
    func showForSnapshot(_ t: HowTab, point: Int = 0, more: Bool = false, terminal: Bool = false) {
        tab = t
        Self.lastTab = t
        tabs.select(t, animated: false)
        page?.stop()
        page?.removeFromSuperview()
        page = nil
        install(HowPage(t), arrive: 0)
        page?.snapshot(point: point, more: more, terminal: terminal)
        doc.layoutSubtreeIfNeeded()
        // An open list is drawn scrolled to, as it would be revealed.
        if more || terminal { scrollTo(doc.frame.height) }
    }
}

/// What the page scrolls on: the sheet's own paper, so a capture of the
/// page alone isn't transparent.
private final class PageGround: NSView {
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

/// The soft edge under the head once the page scrolls under it: a hairline
/// and a shadow that fades out below.
private final class HeadShade: NSView {
    private let fade = CAGradientLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(fade)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = bounds
        CATransaction.commit()
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let line = Theme.hairline.cgColor
        let soft = NSColor.black.withAlphaComponent(dark ? 0.22 : 0.06).cgColor
        fade.colors = [line, line, soft, NSColor.black.withAlphaComponent(0).cgColor]
        let edge = NSNumber(value: Double(1 / max(bounds.height, 1)))
        fade.locations = [0, edge, edge, 1]
        // A gradient layer runs bottom to top unless told otherwise.
        fade.startPoint = CGPoint(x: 0.5, y: layer?.contentsAreFlipped() == true ? 0 : 1)
        fade.endPoint = CGPoint(x: 0.5, y: layer?.contentsAreFlipped() == true ? 1 : 0)
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: - Tabs

/// The three tabs: a sunk well, and one raised card that slides to the tab
/// you pick.
private final class HowTabs: NSView {
    var onPick: (HowTab) -> Void = { _ in }
    private let pick = PickCard()
    private let buttons: [TabButton]
    private(set) var picked: HowTab = .dictation
    /// Where the card is drawn while it slides; nil is on the picked tab.
    private var slide: (x: CGFloat, w: CGFloat)?
    private var tween: Tween?

    override init(frame frameRect: NSRect) {
        buttons = HowTab.allCases.map { TabButton($0) }
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = How.px(14)
        layer?.borderWidth = 1
        addSubview(pick)
        for b in buttons {
            addSubview(b)
            let tab = b.tab
            b.onClick = { [weak self] in self?.onPick(tab) }
        }
        heightAnchor.constraint(equalToConstant: How.px(66)).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    private var pad: CGFloat { How.px(4) }
    private func frame(of i: Int) -> NSRect {
        let w = (bounds.width - pad * 2 - pad * 2) / 3
        return NSRect(x: pad + CGFloat(i) * (w + pad), y: pad, width: w, height: bounds.height - pad * 2)
    }

    func select(_ tab: HowTab, animated: Bool) {
        let from = pick.frame
        picked = tab
        for b in buttons { b.set(picked: b.tab == tab, animated: animated) }
        tween?.cancel()
        guard animated, from.width > 0, !Motion.reduced else {
            slide = nil
            needsLayout = true
            return
        }
        let to = frame(of: tab.rawValue)
        tween = Tween.run(0.36, curve: .glide, owner: self) { [weak self] k in
            self?.slide = (from.minX + (to.minX - from.minX) * k, from.width + (to.width - from.width) * k)
            if k >= 1 { self?.slide = nil }
            self?.needsLayout = true
        }
    }

    func syncPlan() { buttons.forEach { $0.syncPlan() } }

    override func layout() {
        super.layout()
        for (i, b) in buttons.enumerated() { b.frame = frame(of: i) }
        let home = frame(of: picked.rawValue)
        pick.frame = slide.map { NSRect(x: $0.x, y: home.minY, width: $0.w, height: home.height) } ?? home
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Theme.wellFill.cgColor
        layer?.borderColor = Theme.hairline.cgColor
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// The picked tab's card: white in the light well, a lifted grey in the
/// dark one, a hairline and a soft shadow.
private final class PickCard: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = How.px(10)
        layer?.borderWidth = 1
        layer?.masksToBounds = false
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = Theme.segPick.cgColor
        layer?.borderColor = Theme.segEdge.cgColor
        layer?.shadowColor = (dark ? NSColor.black : Theme.hex(0x141822)).cgColor
        layer?.shadowOpacity = dark ? 0.55 : 0.16
        layer?.shadowRadius = How.px(9)
        layer?.shadowOffset = CGSize(width: 0, height: -How.px(5))
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// One tab: its icon in a small tile (ink when picked), its name and what
/// it's for, and on the Free plan a quiet Pro tag.
private final class TabButton: NSView {
    let tab: HowTab
    var onClick: () -> Void = {}
    private let tile = CALayer()
    private let glyph: GlyphView
    private let glyphOn: GlyphView
    private let name: Lit
    private let sub: Lit
    private let pro: ProTag?
    private var picked = false
    private var hovering = false { didSet { needsDisplay = true } }

    init(_ tab: HowTab) {
        self.tab = tab
        glyph = GlyphView(symbol: tab.symbol, size: How.px(13.5), weight: .medium, side: How.px(18))
        glyph.tint = Theme.faint
        glyphOn = GlyphView(symbol: tab.symbol, size: How.px(13.5), weight: .medium, side: How.px(18))
        glyphOn.tint = Theme.paper
        glyphOn.alphaValue = 0
        name = Lit(tab.title, How.sans(14, .medium), dim: Theme.muted, lit: Theme.ink, litFont: How.sans(14, .semibold))
        sub = Lit(tab.subtitle, How.sans(12), dim: Theme.faint, lit: Theme.muted)
        pro = tab.isPro ? ProTag(quiet: true) : nil
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = How.px(10)
        tile.cornerRadius = How.px(9)
        layer?.addSublayer(tile)
        for v in [glyph, glyphOn, name, sub] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = true
            addSubview(v)
        }
        if let p = pro {
            p.translatesAutoresizingMaskIntoConstraints = true
            p.toolTip = "Part of Pro. Dictation, Dictionary, Phrases and Tones are on every plan."
            addSubview(p)
        }
        syncPlan()
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(tab.title)
    }
    required init?(coder: NSCoder) { fatalError() }

    func syncPlan() { pro?.isHidden = tab.unlocked }

    func set(picked: Bool, animated: Bool) {
        self.picked = picked
        name.set(picked, animated: animated, duration: 0.2)
        sub.set(picked, animated: animated, duration: 0.2)
        Anim.fade(glyphOn, to: picked ? 1 : 0, animated ? 0.25 : 0)
        setAccessibilityValue(picked)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        let side = How.px(32)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tile.frame = NSRect(x: How.px(12), y: ((h - side) / 2).rounded(), width: side, height: side)
        CATransaction.commit()
        for g in [glyph, glyphOn] {
            let s = g.frame.size.width > 0 ? g.frame.size : g.fittingSize
            g.frame = NSRect(x: tile.frame.midX - s.width / 2, y: tile.frame.midY - s.height / 2, width: s.width, height: s.height)
        }
        let x = How.px(12) + side + How.px(12)
        let n = name.intrinsicContentSize, s = sub.intrinsicContentSize
        let gap = How.px(2)
        // Unflipped: the name sits above the line that says what it's for.
        let top = ((h + n.height + gap + s.height) / 2).rounded()
        name.frame = NSRect(x: x, y: top - n.height, width: n.width, height: n.height)
        sub.frame = NSRect(x: x, y: top - n.height - gap - s.height, width: s.width, height: s.height)
        if let p = pro {
            let ps = p.fittingSize
            p.frame = NSRect(x: bounds.width - How.px(14) - ps.width, y: ((h - ps.height) / 2).rounded(),
                             width: ps.width, height: ps.height)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override var mouseDownCanMoveWindow: Bool { false }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = (hovering && !picked ? Theme.navHover : .clear).cgColor
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.25)
        tile.backgroundColor = (picked ? Theme.ink : .clear).cgColor
        tile.borderColor = Theme.hairline.cgColor
        tile.borderWidth = picked ? 0 : 1
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: - A tab's page

/// One tab's page: its sentence on top, then the dial on the left and the
/// points on the right. Built when the tab is picked, thrown away when
/// another is; only one is ever running.
private final class HowPage: NSView {
    let tab: HowTab
    private let points: [HowPoint]
    var onReveal: (NSView) -> Void = { _ in }
    var onTop: () -> Void = {}

    private let intro: NSView
    private var hold: HoldLine?
    private var introPro: ProTag?
    private let wrap = DialWrap()
    private let dial: HowDial
    private let list = NSStackView()
    private var rows: [PointRow] = []
    private var more: MoreRow?
    private var term: TermList?
    private var listTop: NSLayoutConstraint!
    private var dialTop: NSLayoutConstraint!
    /// The space above the dial and the list, once centred, and the dial's
    /// own drop to sit level with the middle of the list.
    private var pad: CGFloat = 0
    private var dialRest: CGFloat = 0

    private(set) var index = 0
    private var started = false
    private var pending: Timer?

    // What holds the dial still.
    var live = false { didSet { if live != oldValue { syncClock() } } }
    private var hovering = false
    private var holding = false
    private var moreOpen = false
    private var termOpen = false
    // The clock: time banked while it was paused, and when it last started.
    private var banked: TimeInterval = 0
    private var since: CFTimeInterval?
    private var deadline: Timer?

    init(_ tab: HowTab) {
        self.tab = tab
        points = tab.points
        dial = HowDial(count: points.count)
        if tab == .dictation {
            let h = HoldLine()
            hold = h
            intro = h
        } else {
            let text = tab == .controls
                ? "While you dictate, say one of these and it happens right there."
                : "Select text, hold \(Shortcuts.command.map(\.name).joined(separator: " + ")) and say what you want; ⌘Z undoes it."
            let f = NSTextField(labelWithString: text)
            f.font = How.sans(14)
            f.textColor = Theme.muted
            f.lineBreakMode = .byTruncatingTail
            f.setContentCompressionResistancePriority(.init(250), for: .horizontal)
            let tag = ProTag(quiet: true)
            tag.toolTip = "Part of Pro on SayControl Cloud, and free on a model on this Mac or your own key."
            introPro = tag
            intro = Theme.hstack([f, tag], spacing: How.px(10))
        }
        super.init(frame: .zero)
        build()
        syncPlan()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func build() {
        for v in [intro, wrap] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        dial.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(dial)
        wrap.addSubview(list)

        for (i, p) in points.enumerated() {
            var extra: NSView?
            if p.extra == .terminal {
                let t = TermList()
                t.onToggle = { [weak self, weak t] open in
                    self?.termOpen = open
                    self?.syncClock()
                    if open, let t = t { self?.onReveal(t) }
                }
                term = t
                extra = t
            }
            let row = PointRow(i + 1, p, stageHeight: tab.stageHeight, extra: extra)
            row.onPick = { [weak self] in self?.go(to: i) }
            row.stage.onHover = { [weak self] on in
                self?.hovering = on
                self?.syncClock()
            }
            row.stage.onClick = { [weak self] in self?.go(to: i, sound: false) }
            rows.append(row)
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        if tab != .dictation {
            let m = MoreRow(tab)
            m.onToggle = { [weak self, weak m] open in
                guard let self = self else { return }
                self.moreOpen = open
                Anim.fade(self.dial, to: open ? 0.45 : 1, 0.45)
                self.syncClock()
                if open, let m = m { self.onReveal(m) } else { self.onTop() }
            }
            more = m
            list.addArrangedSubview(m)
            m.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }

        dial.onPick = { [weak self] i in self?.go(to: i) }
        dial.onStep = { [weak self] in self?.step(1) }
        dial.onHold = { [weak self] on in
            self?.holding = on
            self?.syncClock()
        }
        wrap.dial = dial
        wrap.onTurn = { [weak self] d in self?.step(d) }
        wrap.panelsOpen = { [weak self] in (self?.moreOpen ?? false) || (self?.termOpen ?? false) }

        listTop = list.topAnchor.constraint(equalTo: wrap.topAnchor)
        dialTop = dial.topAnchor.constraint(equalTo: wrap.topAnchor)
        NSLayoutConstraint.activate([
            intro.topAnchor.constraint(equalTo: topAnchor),
            intro.leadingAnchor.constraint(equalTo: leadingAnchor, constant: How.px(2)),
            intro.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -How.px(2)),
            intro.heightAnchor.constraint(greaterThanOrEqualToConstant: How.px(44)),
            wrap.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: How.px(6)),
            wrap.leadingAnchor.constraint(equalTo: leadingAnchor),
            wrap.trailingAnchor.constraint(equalTo: trailingAnchor),
            wrap.bottomAnchor.constraint(equalTo: bottomAnchor),
            // The mockup's grid: a 272 column for the dial, 40 between.
            dial.centerXAnchor.constraint(equalTo: wrap.leadingAnchor, constant: How.px(136)),
            dialTop,
            listTop,
            list.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: How.px(272 + 40)),
            list.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
            wrap.bottomAnchor.constraint(equalTo: list.bottomAnchor),
        ])
    }

    func syncPlan() { introPro?.isHidden = tab.unlocked }

    // MARK: Start, place, stop

    /// Opens on the first point, at once; its demo waits for the page to
    /// have arrived.
    func start(room: CGFloat) {
        go(to: 0, sound: false, delay: 0.42, animated: false)
        place(room: room)
        hold?.start()
    }

    /// Centres the dial and the list in the room the page has, and the knob
    /// against the list — once: a list opening later only grows the page
    /// downward, nothing jumps.
    func place(room: CGFloat) {
        guard !moreOpen, !termOpen else { return }
        listTop.constant = 0
        dialTop.constant = 0
        layoutSubtreeIfNeeded()
        let used = intro.frame.height + How.px(6) + list.frame.height
        pad = max(0, ((room - used) / 2).rounded())
        dialRest = max(0, ((list.frame.height - dial.side) / 2).rounded())
        listTop.constant = pad
        dialTop.constant = pad + dialRest
    }

    /// The knob stays in view as a long list scrolls under it, 12 points
    /// from the top, and never past the end of the list.
    func stick(visibleTop: CGFloat) {
        let natural = pad + dialRest
        let y = visibleTop + How.px(12) - wrap.frame.minY
        let last = max(natural, pad + list.frame.height - dial.side)
        let to = min(max(natural, y), last)
        if abs(dialTop.constant - to) > 0.5 { dialTop.constant = to }
    }

    /// Rises into place, top to bottom: the sentence, the dial, the points.
    func arrive(delay: TimeInterval) {
        guard !Motion.reduced else { return }
        Motion.rise(intro, delay: delay)
        Motion.rise(dial, delay: delay + Motion.Page.stagger)
        Motion.rise(list, delay: delay + Motion.Page.stagger * 2)
    }

    func stop() {
        live = false
        pending?.invalidate()
        pending = nil
        deadline?.invalidate()
        deadline = nil
        rows.forEach { $0.stage.stop() }
        hold?.stop()
        Tween.cancel(owner: self)
    }

    // MARK: Turning

    func step(_ d: Int) { go(to: index + d) }

    /// The dial on point `raw` (wrapping round): its row opens, the others
    /// close, the knob turns, it ticks, and the demo plays from the top.
    func go(to raw: Int, sound: Bool = true, delay: TimeInterval = 0, animated: Bool = true) {
        let n = points.count
        let i = ((raw % n) + n) % n
        let changed = i != index || !started
        if i != index, termOpen {
            term?.set(open: false, animated: animated)
            termOpen = false
        }
        index = i
        started = true
        for (j, r) in rows.enumerated() { r.set(open: j == i, animated: animated) }
        dial.set(index: i, animated: animated)
        if changed && sound { HowTick.play() }
        pending?.invalidate()
        pending = nil
        rows.forEach { $0.stage.stop() }
        let stage = rows[i].stage
        let demo = points[i].demo()
        if delay > 0 && !Motion.reduced {
            let t = Timer(timeInterval: delay, repeats: false) { [weak stage] _ in stage?.play(demo) }
            RunLoop.main.add(t, forMode: .common)
            pending = t
        } else {
            stage.play(demo)
        }
        banked = 0
        since = nil
        deadline?.invalidate()
        deadline = nil
        syncClock()
    }

    // MARK: The clock

    private var dwell: TimeInterval { points[index].dwell }
    private var paused: Bool { !live || hovering || holding || moreOpen || termOpen }

    /// Counts toward the next point while nobody is holding the dial still,
    /// and banks what it counted when somebody does. No clock at all under
    /// Reduce Motion: nothing moves on by itself.
    private func syncClock() {
        guard !Motion.reduced else { return }
        if paused {
            if let s = since { banked += CACurrentMediaTime() - s }
            since = nil
            deadline?.invalidate()
            deadline = nil
            dial.hold(progress: CGFloat(min(1, banked / dwell)), paused: true)
        } else if since == nil {
            since = CACurrentMediaTime()
            let left = max(0.05, dwell - banked)
            dial.run(from: CGFloat(min(1, banked / dwell)), over: left)
            let t = Timer(timeInterval: left, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                self.deadline = nil
                self.go(to: self.index + 1)
            }
            RunLoop.main.add(t, forMode: .common)
            deadline = t
        }
    }

    // MARK: For the snapshot tool

    func snapshot(point: Int, more open: Bool, terminal: Bool) {
        go(to: point, sound: false, animated: false)
        // See more says so itself (onToggle); the terminal's list is told.
        if open { more?.set(open: true, animated: false) }
        if terminal {
            term?.set(open: true, animated: false)
            termOpen = true
        }
        layoutSubtreeIfNeeded()
    }
}

/// The dial and the list side by side, taking the wheel: over either, a
/// notch turns the dial rather than scrolling the page. With a list open
/// below, the wheel scrolls it — except over the knob itself.
private final class DialWrap: NSView {
    weak var dial: HowDial?
    var onTurn: (Int) -> Void = { _ in }
    var panelsOpen: () -> Bool = { false }
    private var spun: CGFloat = 0
    private var last: CFTimeInterval = 0

    override var isFlipped: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if panelsOpen(), !(dial?.frame.contains(p) ?? false) { return super.scrollWheel(with: event) }
        // A flick's momentum isn't a turn.
        guard event.momentumPhase.isEmpty else { return }
        let d = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
        // Down the page is on to the next point. A mouse wheel's notch is a
        // line, a trackpad's deltas are points.
        spun -= event.hasPreciseScrollingDeltas ? d : d * 40
        let now = CACurrentMediaTime()
        if abs(spun) >= 40, now - last > 0.16 {
            onTurn(spun > 0 ? 1 : -1)
            spun = 0
            last = now
        }
    }
}

// MARK: - The dial

/// The knob: one tick for each point round a 270° arc, the arc lit up to
/// the point it's on, the knob itself turned there on a soft spring with an
/// ember dot for a pointer, "N of M" in the middle, and a thin ring that
/// fills toward the next step. Drag it, click a tick, or click the knob to
/// step on.
private final class HowDial: NSView {
    private static let a0: CGFloat = -135, a1: CGFloat = 135
    let count: Int
    private(set) var index = 0
    var onPick: (Int) -> Void = { _ in }
    var onStep: () -> Void = {}
    var onHold: (Bool) -> Void = { _ in }

    let side = How.px(256)
    /// The mockup draws the dial on a 224 grid.
    private var unit: CGFloat { side / 224 }

    private let track = CAShapeLayer(), lit = CAShapeLayer(), prog = CAShapeLayer()
    private var ticks: [CAShapeLayer] = []
    private let drop = CAGradientLayer(), lip = CAShapeLayer(), edge = CAShapeLayer()
    private let body = CAGradientLayer(), sheen = CAShapeLayer()
    private let knob = CALayer(), knurl = CAShapeLayer(), halo = CAShapeLayer(), dot = CAShapeLayer()
    private let number = Words("1", How.display(40), Theme.ink, kern: How.px(40) * -0.04)
    private let of: Words
    private var dragging = false
    private var moved = false
    private var paused = true

    init(count: Int) {
        self.count = count
        of = Words("of \(count)", How.sans(11), Theme.muted)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        for l in [track, lit, prog] {
            l.fillColor = nil
            layer?.addSublayer(l)
        }
        track.lineCap = .round
        lit.lineCap = .round
        lit.strokeEnd = 0
        prog.lineCap = .butt
        prog.strokeEnd = 0
        prog.opacity = 0.12
        for _ in 0..<count {
            let t = CAShapeLayer()
            t.lineCap = .round
            layer?.addSublayer(t)
            ticks.append(t)
        }
        for l in [drop, lip, edge, body, sheen] { layer?.addSublayer(l) }
        sheen.fillColor = nil
        sheen.lineCap = .round
        drop.type = .radial
        drop.startPoint = CGPoint(x: 0.5, y: 0.5)
        drop.endPoint = CGPoint(x: 1, y: 1)
        body.type = .radial
        body.masksToBounds = true
        layer?.addSublayer(knob)
        for l in [knurl, halo, dot] { knob.addSublayer(l) }
        addSubview(number)
        addSubview(of)
        widthAnchor.constraint(equalToConstant: side).isActive = true
        heightAnchor.constraint(equalToConstant: side).isActive = true

        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Point")
        set(index: 0, animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func angle(_ i: Int) -> CGFloat {
        count > 1 ? Self.a0 + (Self.a1 - Self.a0) * CGFloat(i) / CGFloat(count - 1) : 0
    }
    /// A point `r` grid units out at `deg` clockwise from the top.
    private func pol(_ deg: CGFloat, _ r: CGFloat) -> CGPoint {
        let a = deg * .pi / 180, c = side / 2
        return CGPoint(x: c + r * unit * sin(a), y: c - r * unit * cos(a))
    }
    private var bodyRect: CGRect {
        let d = (side * 0.59).rounded()
        return CGRect(x: (side - d) / 2, y: (side - d) / 2, width: d, height: d)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let c = CGPoint(x: side / 2, y: side / 2)
        for l in [track, lit, prog] { l.frame = bounds }
        // The arc runs clockwise from the lower left, over the top, to the
        // lower right — 135° to 405° measured the y-down way.
        let arc = CGMutablePath()
        arc.addRelativeArc(center: c, radius: 100 * unit, startAngle: .pi * 0.75, delta: .pi * 1.5)
        track.path = arc
        lit.path = arc
        track.lineWidth = 3 * unit
        lit.lineWidth = 3 * unit
        let ring = CGMutablePath()
        ring.addRelativeArc(center: c, radius: 78 * unit, startAngle: -.pi / 2, delta: .pi * 2)
        prog.path = ring
        prog.lineWidth = 2 * unit
        for (i, t) in ticks.enumerated() {
            t.frame = bounds
            let p = CGMutablePath()
            p.move(to: pol(angle(i), 107))
            p.addLine(to: pol(angle(i), 116))
            t.path = p
        }

        let r = bodyRect, d = r.width
        let circle = CGPath(ellipseIn: CGRect(origin: .zero, size: r.size), transform: nil)
        // The knob's shadow, the CSS's 0 14px 30px -12px rgb(0 0 0 / .4):
        // a disc pulled in by 12 and dropped 14, blurred over 15 either way
        // — painted as a radial gradient, which every renderer draws alike.
        let solid = d / 2 - How.px(12), sigma = How.px(15)
        let reach = solid + sigma * 3
        drop.frame = CGRect(x: c.x - reach, y: c.y + How.px(14) - reach, width: reach * 2, height: reach * 2)
        // Its edge falls off the way a blur's does: the normal curve's tail.
        let edgeStops: [(CGFloat, CGFloat)] = [(-2, 0.977), (-1, 0.841), (0, 0.5), (1, 0.159), (2, 0.023), (3, 0)]
        drop.locations = [0] + edgeStops.map { NSNumber(value: Double((solid + $0.0 * sigma) / reach)) }
        drop.colors = ([1] + edgeStops.map { $0.1 }).map { NSColor.black.withAlphaComponent(0.4 * $0).cgColor }
        lip.frame = r.offsetBy(dx: 0, dy: How.px(2))
        lip.path = circle
        edge.frame = r.insetBy(dx: -1, dy: -1)
        edge.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: d + 2, height: d + 2), transform: nil)
        body.frame = r
        body.cornerRadius = d / 2
        // The CSS's radial-gradient(circle at 50% 28%, top, key 78%): the
        // light sits high on the knob, and stays there as it turns.
        body.startPoint = CGPoint(x: 0.5, y: 0.28)
        body.endPoint = CGPoint(x: 0.5 + 0.684, y: 0.28 + 0.684)
        sheen.frame = r
        let top = CGMutablePath()
        top.addArc(center: CGPoint(x: d / 2, y: d / 2), radius: d / 2 - 1, startAngle: .pi * 1.18, endAngle: .pi * 1.82,
                   clockwise: false)
        sheen.path = top
        sheen.lineWidth = 1

        knob.bounds = CGRect(origin: .zero, size: r.size)
        knob.position = c
        knurl.frame = knob.bounds
        // 48 fine ridges round the rim, from 83% of the way out to the edge.
        let ridges = CGMutablePath()
        let outer = d / 2 - How.px(4), inner = outer * 0.83
        let mid = CGPoint(x: d / 2, y: d / 2)
        for j in 0..<48 {
            let from = CGFloat(j) * 7.5 * .pi / 180 - .pi / 2, to = from + 1.4 * .pi / 180
            ridges.move(to: CGPoint(x: mid.x + inner * cos(from), y: mid.y + inner * sin(from)))
            ridges.addArc(center: mid, radius: inner, startAngle: from, endAngle: to, clockwise: false)
            ridges.addLine(to: CGPoint(x: mid.x + outer * cos(to), y: mid.y + outer * sin(to)))
            ridges.addArc(center: mid, radius: outer, startAngle: to, endAngle: from, clockwise: true)
            ridges.closeSubpath()
        }
        knurl.path = ridges
        // The pointer: an ember dot 12 down from the top, in a soft ring.
        let dotC = CGPoint(x: d / 2, y: How.px(12) + How.px(3.5))
        dot.frame = knob.bounds
        dot.path = CGPath(ellipseIn: CGRect(x: dotC.x - How.px(3.5), y: dotC.y - How.px(3.5),
                                            width: How.px(7), height: How.px(7)), transform: nil)
        halo.frame = knob.bounds
        halo.path = CGPath(ellipseIn: CGRect(x: dotC.x - How.px(6.5), y: dotC.y - How.px(6.5),
                                             width: How.px(13), height: How.px(13)), transform: nil)
        CATransaction.commit()

        // "N of M", together on the middle.
        let nh = How.px(40), oh = How.px(13)
        let blockTop = side / 2 - (nh + How.px(3) + oh) / 2
        number.frame = NSRect(x: 0, y: blockTop.rounded(), width: side, height: nh)
        of.frame = NSRect(x: 0, y: (blockTop + nh + How.px(3)).rounded(), width: side, height: oh)
        centre(number)
        centre(of)
    }

    /// Words are drawn from their left edge; this puts them on the middle.
    private func centre(_ w: Words) {
        let width = w.width
        w.frame = NSRect(x: ((side - width) / 2).rounded(), y: w.frame.minY, width: width, height: w.frame.height)
    }

    // MARK: Turning

    func set(index i: Int, animated: Bool) {
        let changed = i != index
        index = i
        let animate = animated && !Motion.reduced
        CATransaction.begin()
        CATransaction.setAnimationDuration(animate ? 0.3 : 0)
        CATransaction.setDisableActions(!animate)
        paintTicks()
        CATransaction.commit()

        let end = count > 1 ? CGFloat(i) / CGFloat(count - 1) : 1
        let turn = angle(i) * .pi / 180
        let fromEnd = lit.presentation()?.strokeEnd ?? lit.strokeEnd
        let fromTurn = (knob.presentation()?.value(forKeyPath: "transform.rotation.z") as? CGFloat)
            ?? (knob.value(forKeyPath: "transform.rotation.z") as? CGFloat) ?? 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lit.strokeEnd = end
        knob.transform = CATransform3DMakeRotation(turn, 0, 0, 1)
        CATransaction.commit()
        if animate {
            let a = CABasicAnimation(keyPath: "strokeEnd")
            a.fromValue = fromEnd
            a.toValue = end
            a.duration = 0.7
            a.timingFunction = Curve.spring.timing
            lit.add(a, forKey: "turn")
            let r = CABasicAnimation(keyPath: "transform.rotation.z")
            r.fromValue = fromTurn
            r.toValue = turn
            r.duration = 0.7
            r.timingFunction = Curve.spring.timing
            knob.add(r, forKey: "turn")
        }
        number.text = "\(i + 1)"
        needsLayout = true
        if animate && changed {
            layoutSubtreeIfNeeded()
            Anim.enter(number, from: Anim.lift(How.px(6), number), 0.38)
        }
        setAccessibilityValue("\(i + 1) of \(count)")
    }

    private func paintTicks() {
        for (j, t) in ticks.enumerated() {
            t.strokeColor = (j == index ? Theme.ink : (j < index ? Theme.ink2 : Theme.faint)).cgColor
            t.lineWidth = (j == index ? 3.5 : 2) * unit
        }
    }

    /// The ring fills from `f` to full over `t` seconds — the time left
    /// before the dial moves on.
    func run(from f: CGFloat, over t: TimeInterval) {
        prog.removeAnimation(forKey: "run")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        prog.strokeEnd = 1
        CATransaction.commit()
        let a = CABasicAnimation(keyPath: "strokeEnd")
        a.fromValue = f
        a.toValue = 1
        a.duration = t
        a.timingFunction = Curve.linear.timing
        prog.add(a, forKey: "run")
        setPaused(false)
    }

    /// The ring stops where it is, and dims.
    func hold(progress f: CGFloat, paused: Bool) {
        prog.removeAnimation(forKey: "run")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        prog.strokeEnd = f
        CATransaction.commit()
        setPaused(paused)
    }

    private func setPaused(_ p: Bool) {
        guard p != paused else { return }
        paused = p
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        prog.opacity = p ? 0.12 : 0.32
        CATransaction.commit()
    }

    // MARK: Mouse

    /// The point a press at `p` asks for: the nearest tick to its angle,
    /// or nil off the arc's ends.
    private func pick(_ p: NSPoint) -> Int? {
        let dx = p.x - side / 2, dy = p.y - side / 2
        let deg = atan2(dx, -dy) * 180 / .pi
        guard deg >= Self.a0 - 25, deg <= Self.a1 + 25, count > 1 else { return nil }
        let step = (Self.a1 - Self.a0) / CGFloat(count - 1)
        return max(0, min(count - 1, Int(((deg - Self.a0) / step).rounded())))
    }

    /// A press on one of the ticks: out on the ring, near its angle.
    private func tick(at p: NSPoint) -> Int? {
        let dx = p.x - side / 2, dy = p.y - side / 2
        let r = hypot(dx, dy) / unit
        guard r >= 96, r <= 126, let i = pick(p) else { return nil }
        let deg = atan2(dx, -dy) * 180 / .pi
        return abs(deg - angle(i)) <= 7 ? i : nil
    }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        moved = false
        NSCursor.closedHand.set()
        onHold(true)
    }
    override func mouseDragged(with event: NSEvent) {
        guard dragging, let i = pick(convert(event.locationInWindow, from: nil)), i != index else { return }
        moved = true
        onPick(i)
    }
    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        NSCursor.openHand.set()
        onHold(false)
        guard !moved else { return }
        if let i = tick(at: convert(event.locationInWindow, from: nil)) { onPick(i) } else { onStep() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformIncrement() -> Bool { onStep(); return true }
    override func accessibilityPerformDecrement() -> Bool { onPick(max(0, index - 1)); return true }

    // MARK: Look

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.strokeColor = Theme.hairline.cgColor
        lit.strokeColor = Theme.ink.cgColor
        prog.strokeColor = Theme.ink.cgColor
        paintTicks()
        lip.fillColor = Theme.lipColor.cgColor
        edge.fillColor = KeyChip.edge.cgColor
        body.colors = [KeyChip.top.cgColor, Theme.keyFill.cgColor]
        sheen.strokeColor = How.shine.cgColor
        knurl.fillColor = Theme.barFill.cgColor
        halo.fillColor = Theme.emberSoft.cgColor
        dot.fillColor = Theme.ember.cgColor
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: - The points

/// One point: its number and title, faint until the dial is on it; then
/// ink, and open to its one line and its demo.
private final class PointRow: NSView {
    let stage: DemoStage
    var onPick: () -> Void = {}
    private let head: PointHead
    private let body: Collapser
    private let inner: NSStackView
    private(set) var isOpen = false

    init(_ n: Int, _ point: HowPoint, stageHeight: CGFloat, extra: NSView?) {
        stage = DemoStage(height: stageHeight)
        head = PointHead(n, point.title, tag: point.tag)
        let line = NSTextField(labelWithString: point.line)
        line.font = How.sans(14)
        line.textColor = Theme.muted
        line.lineBreakMode = .byTruncatingTail
        // The line, 10 over the demo; Ask's assistants between them (the
        // mockup's -3 above, 10 below); the terminal's list 6 under it.
        var views: [NSView] = [line]
        var services: NSStackView?
        if point.extra == .services {
            let chips = AIService.allCases.map { DemoChip($0.displayName, symbol: nil, .service) as NSView }
            let row = Theme.hstack(chips + [Theme.spacer()], spacing: How.px(5))
            services = row
            views.append(row)
        }
        views.append(stage)
        if let e = extra { views.append(e) }
        inner = Theme.vstack(views, spacing: 0)
        inner.edgeInsets = NSEdgeInsets(top: 0, left: How.px(28), bottom: How.px(12), right: 0)
        inner.setCustomSpacing(How.px(services == nil ? 10 : 7), after: line)
        if let row = services { inner.setCustomSpacing(How.px(10), after: row) }
        if extra != nil { inner.setCustomSpacing(How.px(6), after: stage) }
        body = Collapser(inner)
        super.init(frame: .zero)
        head.onClick = { [weak self] in self?.onPick() }
        for v in [head, body] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        for v in views where v !== line {
            v.widthAnchor.constraint(equalTo: inner.widthAnchor, constant: -How.px(28)).isActive = true
        }
        line.widthAnchor.constraint(lessThanOrEqualTo: inner.widthAnchor, constant: -How.px(28)).isActive = true
        services?.alignment = .centerY
        NSLayoutConstraint.activate([
            head.topAnchor.constraint(equalTo: topAnchor),
            head.leadingAnchor.constraint(equalTo: leadingAnchor),
            head.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.topAnchor.constraint(equalTo: head.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// Opening, the title goes to ink and the body slides open, its words
    /// following a beat behind; closing, the body fades as it folds.
    func set(open: Bool, animated: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        if !open { stage.forgetPointer() }
        head.set(open, animated: animated)
        body.set(open, animated: animated, duration: 0.5)
        guard animated, !Motion.reduced else {
            inner.alphaValue = open ? 1 : 0
            return
        }
        if open {
            inner.alphaValue = 1
            Anim.enter(inner, from: Anim.lift(How.px(6), inner), 0.45, delay: 0.12, fade: 0.35)
        } else {
            Anim.fade(inner, to: 0, 0.2)
        }
    }
}

/// A point's title row: its number in a narrow column, its title in the
/// display face, and its page's name after it while it's open.
private final class PointHead: NSView {
    var onClick: () -> Void = {}
    private let number: Lit
    private let title: Lit
    private let page: Words?
    private var hovering = false { didSet { syncHover() } }

    init(_ n: Int, _ text: String, tag: String?) {
        number = Lit("\(n)", .monospacedDigitSystemFont(ofSize: How.px(12), weight: .medium), dim: Theme.faint, lit: Theme.ink)
        title = Lit(text, How.display(20), dim: Theme.faint, lit: Theme.ink, kern: How.px(20) * -0.025)
        page = tag.map { Words($0, How.sans(12), Theme.muted) }
        super.init(frame: .zero)
        for v in [number, title] as [NSView] { addSubview(v) }
        if let t = page {
            t.alphaValue = 0
            addSubview(t)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(text)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    private var padY: CGFloat { How.px(5) }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: title.intrinsicContentSize.height + padY * 2)
    }

    func set(_ open: Bool, animated: Bool) {
        number.set(open, animated: animated, duration: 0.3)
        title.set(open, animated: animated, duration: 0.35)
        if let t = page { Anim.fade(t, to: open ? 1 : 0, animated ? 0.3 : 0) }
    }

    private func syncHover() { title.dim = hovering ? Theme.muted : Theme.faint }

    override func layout() {
        super.layout()
        // Everything on the title's baseline.
        let ts = title.intrinsicContentSize
        title.frame = NSRect(x: How.px(28), y: padY, width: ts.width, height: ts.height)
        let base = padY + title.baseline
        let ns = number.intrinsicContentSize
        number.frame = NSRect(x: 0, y: (base - number.baseline).rounded(), width: ns.width, height: ns.height)
        if let t = page {
            let s = t.intrinsicContentSize
            t.frame = NSRect(x: title.frame.maxX + How.px(12), y: (base - t.font.ascender - (s.height - t.lineHeight) / 2).rounded(),
                             width: s.width, height: s.height)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override var mouseDownCanMoveWindow: Bool { false }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }
}

/// "See more" under the last point of Controls and Command mode, and the
/// rest of the tab's phrases opening in place under it — with "See less" at
/// their foot to fold them away.
private final class MoreRow: NSView {
    var onToggle: (Bool) -> Void = { _ in }
    private let seeMore = LinkButton("See more")
    private let seeLess = LinkButton("See less", angle: 180)
    private let panel: Collapser
    private let blocks: [NSView]
    private var moreHeight: NSLayoutConstraint!
    private(set) var isOpen = false

    init(_ tab: HowTab) {
        var blocks: [NSView] = []
        if tab == .controls {
            for g in HowTab.moreControls {
                let caps = NSTextField(labelWithAttributedString: NSAttributedString(string: g.group.uppercased(), attributes: [
                    .font: How.sans(10, .semibold), .foregroundColor: Theme.faint, .kern: How.px(10) * 0.09]))
                var views: [NSView] = [caps]
                for (i, r) in g.rows.enumerated() {
                    views.append(PairRow(r.say, r.does, share: 1.15 / 2.15, gap: How.px(14), sayFont: How.sans(13.5),
                                         doesFont: How.sans(12.5), doesColor: Theme.muted, inset: How.px(5), indent: 0,
                                         rule: i > 0))
                }
                let group = Theme.vstack(views, spacing: 0)
                group.setCustomSpacing(How.px(4), after: caps)
                for v in views.dropFirst() { v.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true }
                blocks.append(group)
            }
        } else {
            let flow = FlowRow(hgap: 6.8, vgap: 6.8)
            flow.measure = { $0.frame.size }
            flow.set(CommandMode.spokenPhrases.map { p in
                let chip = DemoChip(p, symbol: nil, .phrase)
                chip.frame.size = chip.intrinsicContentSize
                return chip
            })
            blocks.append(flow)
            blocks.append(Self.foot(NSAttributedString(string: "Any instruction works. SayControl listens hardest for these.",
                                                        attributes: [.font: How.sans(12.5), .foregroundColor: Theme.muted])))
        }
        self.blocks = blocks
        let column = Theme.vstack(blocks + [seeLess], spacing: tab == .controls ? How.px(12) : How.px(10))
        column.edgeInsets = NSEdgeInsets(top: How.px(6), left: How.px(28), bottom: 0, right: 0)
        column.setCustomSpacing(How.px(6), after: blocks.last!)
        for b in blocks { b.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -How.px(28)).isActive = true }
        panel = Collapser(column)
        super.init(frame: .zero)
        seeMore.onClick = { [weak self] in self?.set(open: true, animated: true) }
        seeLess.onClick = { [weak self] in self?.set(open: false, animated: true) }
        for v in [seeMore, panel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        moreHeight = seeMore.heightAnchor.constraint(equalToConstant: seeMore.intrinsicContentSize.height)
        NSLayoutConstraint.activate([
            seeMore.topAnchor.constraint(equalTo: topAnchor),
            seeMore.leadingAnchor.constraint(equalTo: leadingAnchor, constant: How.px(28)),
            moreHeight,
            panel.topAnchor.constraint(equalTo: seeMore.bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    static func foot(_ s: NSAttributedString) -> NSTextField {
        let f = WrapLabel(labelWithAttributedString: s)
        f.lineBreakMode = .byWordWrapping
        f.maximumNumberOfLines = 0
        f.cell?.wraps = true
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        f.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        return f
    }

    func set(open: Bool, animated: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        // See more steps out of the way; the rest opens where it was.
        seeMore.isHidden = open
        moreHeight.constant = open ? 0 : seeMore.intrinsicContentSize.height
        panel.set(open, animated: animated, duration: 0.45)
        if open && animated && !Motion.reduced {
            layoutSubtreeIfNeeded()
            for (j, b) in (blocks + [seeLess]).enumerated() {
                Motion.rise(b, delay: 0.08 + Double(min(j, 3)) * Motion.Page.stagger)
            }
        }
        onToggle(open)
    }
}

/// "All terminal commands" under the terminal point's demo: Shell.swift's
/// table in three groups that fold, and how to say what's written.
private final class TermList: NSView {
    var onToggle: (Bool) -> Void = { _ in }
    private let link = LinkButton("All terminal commands")
    private let panel: Collapser
    private(set) var isOpen = false

    override init(frame frameRect: NSRect) {
        var views: [NSView] = []
        for (i, g) in HowTab.terminal.enumerated() {
            views.append(FoldGroup(g.group, g.rows, open: g.open, rule: i > 0))
        }
        let foot = NSMutableAttributedString()
        let plain: [NSAttributedString.Key: Any] = [.font: How.sans(12.5), .foregroundColor: Theme.muted]
        let code: [NSAttributedString.Key: Any] = [.font: How.mono(11.5), .foregroundColor: Theme.ink2]
        foot.append(NSAttributedString(string: "Say it as written: “dash m” for ", attributes: plain))
        foot.append(NSAttributedString(string: "-m", attributes: code))
        foot.append(NSAttributedString(string: ", “dot” for a dot. Turn on Commands in the terminal in Settings.",
                                       attributes: plain))
        let f = MoreRow.foot(foot)
        views.append(f)
        let column = Theme.vstack(views, spacing: 0)
        column.edgeInsets = NSEdgeInsets(top: How.px(6), left: 0, bottom: 0, right: 0)
        column.setCustomSpacing(How.px(10), after: views[views.count - 2])
        for v in views { v.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        panel = Collapser(column)
        super.init(frame: frameRect)
        link.onClick = { [weak self] in
            guard let self = self else { return }
            self.set(open: !self.isOpen, animated: true)
            self.onToggle(self.isOpen)
        }
        for v in [link, panel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            link.topAnchor.constraint(equalTo: topAnchor),
            link.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.topAnchor.constraint(equalTo: link.bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func set(open: Bool, animated: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        link.turn(to: open ? 180 : 0, animated: animated)
        panel.set(open, animated: animated, duration: 0.45)
    }
}

/// One of the terminal table's groups: a header that folds it, with how
/// many it holds, and its rows under it.
private final class FoldGroup: NSView {
    private let chevron: Chevron
    private let panel: Collapser
    private var isOpen: Bool

    init(_ title: String, _ rows: [(say: String, lands: String)], open: Bool, rule: Bool) {
        isOpen = open
        chevron = Chevron(side: 12, angle: open ? 0 : -90)
        let views = rows.map { r in
            PairRow("“\(r.say)”", r.lands, share: 1.3 / 2.3, gap: How.px(12), sayFont: How.sans(13),
                    doesFont: How.mono(11.5), doesColor: Theme.ink2, inset: How.px(3), indent: How.px(20), rule: false,
                    code: true) as NSView
        }
        let column = Theme.vstack(views, spacing: 0)
        column.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: How.px(6), right: 0)
        for v in views { v.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        panel = Collapser(column, open: open)
        super.init(frame: .zero)
        let name = Words(title, How.sans(13, .medium), Theme.ink)
        let count = Words("\(rows.count)", How.sans(11.5), Theme.faint)
        let header = Pressable()
        header.onClick = { [weak self] in self?.toggle() }
        for v in [chevron, name, count] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(v)
        }
        for v in [header, panel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        if rule {
            let line = ColorView(color: Theme.hairsoft)
            line.translatesAutoresizingMaskIntoConstraints = false
            addSubview(line)
            NSLayoutConstraint.activate([
                line.topAnchor.constraint(equalTo: topAnchor),
                line.leadingAnchor.constraint(equalTo: leadingAnchor),
                line.trailingAnchor.constraint(equalTo: trailingAnchor),
                line.heightAnchor.constraint(equalToConstant: 1),
            ])
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: How.px(30)),
            chevron.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            chevron.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            name.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: How.px(8)),
            name.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            count.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            count.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            panel.topAnchor.constraint(equalTo: header.bottomAnchor),
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func toggle() {
        isOpen.toggle()
        chevron.turn(to: isOpen ? 0 : -90, animated: true)
        panel.set(isOpen, animated: true, duration: 0.4)
    }
}

/// A phrase and what it does (or what it types), side by side on one
/// baseline, the phrase taking `share` of the width.
private final class PairRow: NSView {
    init(_ say: String, _ does: String, share: CGFloat, gap: CGFloat, sayFont: NSFont, doesFont: NSFont,
         doesColor: NSColor, inset: CGFloat, indent: CGFloat, rule: Bool, code: Bool = false) {
        super.init(frame: .zero)
        let left = MoreRow.foot(NSAttributedString(string: say, attributes: [.font: sayFont, .foregroundColor: Theme.ink]))
        let right = MoreRow.foot(NSAttributedString(string: does, attributes: [.font: doesFont, .foregroundColor: doesColor]))
        // A long command breaks anywhere rather than overflowing its column.
        if code { right.lineBreakMode = .byCharWrapping }
        for v in [left, right] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        if rule {
            let line = ColorView(color: Theme.hairsoft)
            line.translatesAutoresizingMaskIntoConstraints = false
            addSubview(line)
            NSLayoutConstraint.activate([
                line.topAnchor.constraint(equalTo: topAnchor),
                line.leadingAnchor.constraint(equalTo: leadingAnchor),
                line.trailingAnchor.constraint(equalTo: trailingAnchor),
                line.heightAnchor.constraint(equalToConstant: 1),
            ])
        }
        let hug = heightAnchor.constraint(equalToConstant: 0)
        hug.priority = .init(1)
        NSLayoutConstraint.activate([
            left.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: indent),
            left.widthAnchor.constraint(equalTo: widthAnchor, multiplier: share, constant: -(indent + gap) * share),
            right.leadingAnchor.constraint(equalTo: left.trailingAnchor, constant: gap),
            right.trailingAnchor.constraint(equalTo: trailingAnchor),
            right.firstBaselineAnchor.constraint(equalTo: left.firstBaselineAnchor),
            bottomAnchor.constraint(greaterThanOrEqualTo: left.bottomAnchor, constant: inset),
            bottomAnchor.constraint(greaterThanOrEqualTo: right.bottomAnchor, constant: inset),
            hug,
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
}

// MARK: - Small pieces

/// Opens to its content's height and folds to nothing, the content clipped
/// while it moves. At rest open it follows the content, so a list opening
/// inside it carries it along.
private final class Collapser: NSView {
    let content: NSView
    private var height: NSLayoutConstraint!
    private var pin: NSLayoutConstraint!
    private var tween: Tween?
    private(set) var isOpen: Bool

    init(_ content: NSView, open: Bool = false) {
        self.content = content
        isOpen = open
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        height = heightAnchor.constraint(equalToConstant: 0)
        pin = content.bottomAnchor.constraint(equalTo: bottomAnchor)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        height.isActive = !open
        pin.isActive = open
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func set(_ open: Bool, animated: Bool, duration: TimeInterval) {
        guard open != isOpen else { return }
        isOpen = open
        tween?.cancel()
        guard animated, !Motion.reduced, window != nil else {
            pin.isActive = false
            height.constant = 0
            height.isActive = !open
            pin.isActive = open
            return
        }
        // Measure where it is and where it's going, then hold it by its
        // height while it gets there.
        let from = frame.height
        pin.isActive = false
        height.constant = from
        height.isActive = true
        superview?.layoutSubtreeIfNeeded()
        let to = open ? content.fittingSize.height.rounded(.up) : 0
        tween = Tween.run(duration, owner: self) { [weak self] k in
            guard let self = self else { return }
            self.height.constant = from + (to - from) * k
            if k >= 1, self.isOpen == open {
                self.height.isActive = !open
                self.height.constant = 0
                self.pin.isActive = open
            }
        }
    }
}

/// Anything that does something on a click, with the pointing hand.
private class Pressable: NSView {
    var onClick: () -> Void = {}
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// A quiet text button with a chevron after it — See more, See less, All
/// terminal commands: muted, ink under the pointer.
private final class LinkButton: Pressable {
    private let label: Words
    private let chevron: Chevron
    private var hovering = false {
        didSet {
            label.color = hovering ? Theme.ink : Theme.muted
            chevron.tint = label.color
        }
    }

    init(_ title: String, angle: CGFloat = 0) {
        label = Words(title, How.sans(13), Theme.muted)
        chevron = Chevron(side: 13, angle: angle)
        super.init(frame: .zero)
        addSubview(label)
        addSubview(chevron)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: label.width + How.px(5) + chevron.side, height: label.lineHeight + How.px(14))
    }
    override func layout() {
        super.layout()
        let s = label.intrinsicContentSize
        label.frame = NSRect(x: 0, y: ((bounds.height - s.height) / 2).rounded(), width: s.width, height: s.height)
        chevron.frame = NSRect(x: s.width + How.px(5), y: ((bounds.height - chevron.side) / 2).rounded(),
                               width: chevron.side, height: chevron.side)
    }
    func turn(to angle: CGFloat, animated: Bool) { chevron.turn(to: angle, animated: animated) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }
}

/// A chevron drawn as two strokes, turned to any angle: 0 points down, and
/// it turns clockwise.
private final class Chevron: NSView {
    var angle: CGFloat { didSet { needsDisplay = true } }
    var tint: NSColor = Theme.muted { didSet { needsDisplay = true } }
    let side: CGFloat

    /// `side` in mockup pixels.
    init(side: CGFloat, angle: CGFloat = 0) {
        self.side = How.px(side)
        self.angle = angle
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: self.side).isActive = true
        heightAnchor.constraint(equalToConstant: self.side).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func turn(to: CGFloat, animated: Bool) {
        let from = angle
        Tween.run(animated ? 0.32 : 0, curve: .glide, owner: self) { [weak self] k in
            self?.angle = from + (to - from) * k
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Lucide's chevron-down on its 24 grid: m6 9 6 6 6-6.
        let u = bounds.width / 24
        let t = NSAffineTransform()
        t.translateX(by: bounds.midX, yBy: bounds.midY)
        t.rotate(byDegrees: angle)
        t.translateX(by: -12 * u, yBy: -12 * u)
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 6 * u, y: 9 * u))
        p.line(to: NSPoint(x: 12 * u, y: 15 * u))
        p.line(to: NSPoint(x: 18 * u, y: 9 * u))
        p.transform(using: t as AffineTransform)
        p.lineWidth = 1.7 * u
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        tint.setStroke()
        p.stroke()
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// Words that light up: a dim copy with a lit one over it, faded in and
/// out — a change of colour Core Animation can make on its own. When the
/// lit copy is a heavier weight the dim one fades out under it, or its
/// narrower letters would show through.
private final class Lit: NSView {
    private let base: Words
    private let top: Words
    private let crossfade: Bool
    private(set) var on = false

    init(_ text: String, _ font: NSFont, dim: NSColor, lit: NSColor, litFont: NSFont? = nil, kern: CGFloat = 0) {
        base = Words(text, font, dim, kern: kern)
        top = Words(text, litFont ?? font, lit, kern: kern)
        crossfade = litFont != nil
        super.init(frame: .zero)
        top.alphaValue = 0
        addSubview(base)
        addSubview(top)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    var dim: NSColor {
        get { base.color }
        set { base.color = newValue }
    }
    var baseline: CGFloat { top.font.ascender + ((bounds.height - top.lineHeight) / 2).rounded() }
    override var intrinsicContentSize: NSSize {
        let a = base.intrinsicContentSize, b = top.intrinsicContentSize
        return NSSize(width: max(a.width, b.width), height: max(a.height, b.height))
    }
    override func layout() {
        super.layout()
        base.frame = NSRect(x: 0, y: 0, width: base.width, height: bounds.height)
        top.frame = NSRect(x: 0, y: 0, width: top.width, height: bounds.height)
    }

    func set(_ on: Bool, animated: Bool, duration: TimeInterval = 0.35) {
        self.on = on
        let d = animated ? duration : 0
        Anim.fade(top, to: on ? 1 : 0, d)
        if crossfade {
            Anim.fade(base, to: on ? 0 : 1, d)
        } else if on {
            // Once the lit copy covers it the dim one goes: the same words
            // drawn twice, one over the other, read heavier than once.
            Anim.fade(base, to: 0, d > 0 ? 0.01 : 0, delay: d)
        } else {
            Anim.fade(base, to: 1, 0)
        }
    }
}

/// Dictation's one line: "Hold [fn] Talk. Let go." — the key pressing and
/// each word lighting in turn, round and round every 3.2 seconds, and what
/// happens after it. Under Reduce Motion every word is lit and nothing
/// moves.
private final class HoldLine: NSView {
    private let hold = Lit("Hold", How.display(24), dim: Theme.faint, lit: Theme.ink, kern: How.px(24) * -0.035)
    private let talk = Lit("Talk.", How.display(24), dim: Theme.faint, lit: Theme.ink, kern: How.px(24) * -0.035)
    private let letGo = Lit("Let go.", How.display(24), dim: Theme.faint, lit: Theme.ink, kern: How.px(24) * -0.035)
    private let keys: [KeyChip]
    private var timers: [Timer] = []

    override init(frame frameRect: NSRect) {
        keys = Shortcuts.dictate.parts.map { KeyChip($0) }
        super.init(frame: frameRect)
        var row: [NSView] = [hold]
        for (i, k) in keys.enumerated() {
            if i > 0 { row.append(Words("+", How.sans(12), Theme.faint)) }
            row.append(k)
        }
        let sub = NSTextField(labelWithString: "Your words land at the cursor.")
        sub.font = How.sans(14)
        sub.textColor = Theme.muted
        sub.lineBreakMode = .byTruncatingTail
        sub.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        row += [talk, letGo, sub]
        let stack = Theme.hstack(row, spacing: How.px(10))
        stack.setCustomSpacing(How.px(20), after: letGo)
        stack.fill(self)
        for l in [hold, talk, letGo] { l.set(true, animated: false) }
        if !Motion.reduced {
            talk.set(false, animated: false)
            letGo.set(false, animated: false)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func start() {
        stop()
        guard !Motion.reduced else { return }
        cycle()
    }

    func stop() {
        timers.forEach { $0.invalidate() }
        timers = []
    }

    /// One turn of the mockup's 3.2-second keyframes: Hold, the key going
    /// down, Talk., Let go. as it comes back up — then round again.
    private func cycle() {
        timers.forEach { $0.invalidate() }
        timers = []
        let t = 3.2
        func at(_ f: Double, _ run: @escaping (HoldLine) -> Void) {
            let timer = Timer(timeInterval: f * t, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                run(self)
            }
            RunLoop.main.add(timer, forMode: .common)
            timers.append(timer)
        }
        hold.set(true, animated: false)
        at(0.08) { $0.keys.forEach { $0.setDown(true, animated: true) } }
        at(0.22) { $0.hold.set(false, animated: true, duration: 0.256) }
        at(0.24) { $0.talk.set(true, animated: true, duration: 0.192) }
        at(0.64) { $0.talk.set(false, animated: true, duration: 0.256) }
        at(0.66) {
            $0.letGo.set(true, animated: true, duration: 0.192)
            $0.keys.forEach { $0.setDown(false, animated: true) }
        }
        at(0.98) { $0.letGo.set(false, animated: true, duration: 0.064) }
        at(1.0) { $0.cycle() }
    }

    deinit { timers.forEach { $0.invalidate() } }
}
