// Settings — seven sections in a sheet of its own: General, Model, System,
// Account, Billing, Permissions, Privacy. One short line of explanation under
// a control at most.
//
// It floats over the window instead of living in the sidebar like the other
// panes, because settings are a detour: you come, you change one thing, you
// leave — and the pane you were reading is still there behind the glass when
// you get back. The sections sit in a sunk rail on the left, built the same
// way the window's own sidebar is, and the one you picked fills the right.
//
// The look is the refresh mockup's sheet (design/sayctrl-refresh.html): every
// section is uppercase-labelled groups of rows in one white box each, label
// left, control right, one line of help under the label.
//
// Account and Billing are the shapes of a plan that has no server behind it
// yet; see Account.swift. Everything else writes straight to ~/.config/sayctrl.
//
// The user-facing build (Config.retail) has no Model section at all: no
// providers, no key boxes, no list of models. Billing becomes Plans — Free,
// Pro and Enterprise across, then the one local model picked for this Mac.
// The developers' build keeps the lot, so models can be weighed against
// each other.
import Cocoa
import AVFoundation

final class SettingsSheet: PaneView {

    // ── the sections ──────────────────────────────────────────────────────
    /// Three groups, and the gap between them is the whole grouping: what the
    /// app does, then who you are, then what it is allowed to touch — the
    /// rail labels the last two "You" and "Trust". Flattened, the order is
    /// the order the tabs used to sit in, so an index stored anywhere still
    /// means the section it always meant; the rail draws Trust in the
    /// mockup's order (Privacy above Permissions) without moving an index.
    static let groups: [[(key: String, symbol: String, title: String)]] = [
        [("general", "gearshape", "General"),
         ("model", "waveform", "Models"),
         ("system", "desktopcomputer", "System")],
        [("account", "person.crop.circle", "Account"),
         ("billing", "creditcard", "Plan")],
        [("permissions", "lock.shield", "Permissions"),
         ("privacy", "hand.raised", "Privacy")],
    ]
    private static let groupLabels: [String?] = [nil, "You", "Trust"]
    private static let railOrder: [String: [String]] = ["permissions": ["privacy", "permissions"]]
    static let sections = groups.flatMap { $0 }
    static let tabKeys = sections.map { $0.key }
    static let tabTitles = sections.map { $0.title }

    /// Whether a section has a row in this build. A user's copy has no
    /// Model section: the model is picked for the Mac and sits under Plans.
    /// Account waits for accounts to launch; Plans is always there for a
    /// user, since Free is a plan too.
    static func shows(_ key: String) -> Bool {
        switch key {
        case "model":   return !Config.retail
        case "account": return Account.available
        case "billing": return Account.available || Config.retail
        default:        return true
        }
    }
    static var visibleTabKeys: [String] { tabKeys.filter(shows) }
    /// Survives the window rebuild a text-size change triggers.
    static var lastTab = 0
    private var railRows: [NavRow] = []
    private let bodyHost = NSView()
    private var bodies: [Int: NSView] = [:]
    /// The section's name over its groups, in the display face at medium —
    /// a name, not a headline. Built with a word in it: a display label
    /// keeps its tracking only while it has text to carry the attributes.
    private let sectionTitle = Theme.hero("General", 21, 500, tracking: -0.035)

    /// The sheet's own size: design/settings-redesign.html's 980 × 690 in a
    /// 1240-wide window, scaled to this 1260-wide one. It shrinks to fit
    /// rather than hanging off a small window — see SettingsUI.showSettings.
    static var sheetWidth: CGFloat { Theme.m(925) }
    static var sheetHeight: CGFloat { Theme.m(645) }
    /// The rail's width, and the gap it floats in.
    private static var railWidth: CGFloat { Theme.m(212) }
    private static var railInset: CGFloat { Theme.m(8) }

    /// Wired to the overlay's dismissal, so Done closes the same way esc does.
    var onClose: () -> Void = {}

    // ── Models ────────────────────────────────────────────────────────────
    /// Settings › Models, built when the section is first shown.
    private var modelsPage: ModelsPage?

    // ── the user-facing Plans section ─────────────────────────────────────
    /// The picked model's row (and the one in use, when that is another),
    /// redrawn from LocalEngine's state while Plans is on screen.

    /// The same sentence in Dictation and in Privacy: what the switch reads,
    /// and the one case where the words leave the Mac. It is the only
    /// setting that sends anything beyond your voice, so it says so.
    static let screenVocabDetail = "Names and jargon in the front window get spelled right. Two dozen words at most, and they travel with your voice only when a cloud model is listening — never on a local one."
    /// The row's one line; the sentence above is its tooltip.
    static let screenVocabLine = "Gets names in the front window spelled right."

    // ── privacy ───────────────────────────────────────────────────────────
    /// Held on to so the audio switch can follow the history switch, and the
    /// clip line can be re-counted after a delete.
    private var audioRow: SwitchRow?
    private var clipsRow: FormRow?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(accountChanged),
                                               name: .sayctrlAccountChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(openTab(_:)),
                                               name: .sayctrlOpenSettingsTab, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(shortcutsChanged),
                                               name: Shortcuts.changed, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Shell

    private func build() {
        wantsLayer = true
        layer?.cornerRadius = Theme.m(18)
        layer?.borderWidth = 1

        // The rail floats inside the sheet as its own panel, the way the
        // window's sidebar floats on the window: a sand fill with its own
        // hairline, a few points in from the sheet's edge.
        let rail = SettingsRail()
        for v in [rail, bodyHost, sectionTitle] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        // Closing is one click, one esc, or one click on the app behind it.
        // A small ×: the sheet has no primary action of its own, and
        // everything in it saves as it changes.
        let done = IconButton("xmark", size: 26, icon: 12, tip: "Close Settings (esc)") { [weak self] in self?.onClose() }
        done.translatesAutoresizingMaskIntoConstraints = false
        addSubview(done)

        // The mockup's `.sbody` padding: 18 above, 24 at the sides. The title
        // line is the height of a button, and both names — "Settings" in the
        // rail and the section's — sit on its centre.
        let line = Theme.m(22) + Theme.m(14)
        let inset = Self.railInset
        NSLayoutConstraint.activate([
            rail.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            rail.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            rail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            rail.widthAnchor.constraint(equalToConstant: Self.railWidth),

            sectionTitle.leadingAnchor.constraint(equalTo: rail.trailingAnchor, constant: Theme.m(28)),
            sectionTitle.centerYAnchor.constraint(equalTo: topAnchor, constant: line),
            sectionTitle.trailingAnchor.constraint(lessThanOrEqualTo: done.leadingAnchor, constant: -Theme.m(12)),
            done.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.m(18)),
            done.centerYAnchor.constraint(equalTo: sectionTitle.centerYAnchor),

            // The groups scroll out under the title line and down to the
            // bottom edge, so a long section runs under the corner rather
            // than stopping short of it.
            bodyHost.topAnchor.constraint(equalTo: topAnchor, constant: Theme.m(22) + Theme.m(28) + Theme.m(10)),
            bodyHost.bottomAnchor.constraint(equalTo: bottomAnchor),
            bodyHost.leadingAnchor.constraint(equalTo: rail.trailingAnchor, constant: Theme.m(4)),
            bodyHost.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        buildRail(in: rail, titleLine: line)
        showTab(Self.lastTab)
    }

    /// The rail: the word "Settings" where the window's sidebar carries the
    /// wordmark, then the sections, the second and third groups under their
    /// labels. Same NavRow the sidebar uses — a section here should read
    /// exactly like a pane there.
    private func buildRail(in rail: NSView, titleLine: CGFloat) {
        self.rail = rail
        let title = Theme.hero("Settings", 18, 500, tracking: -0.03)
        title.translatesAutoresizingMaskIntoConstraints = false
        rail.addSubview(title)
        railRows = []
        var column: [NSView] = []
        for (g, group) in Self.groups.enumerated() {
            // A section this build doesn't show keeps its place in `groups`,
            // so every stored index still means what it meant; only its row
            // is left out of the rail, and a group left empty loses its label.
            let group = group.filter { Self.shows($0.key) }
            if group.isEmpty { continue }
            if let label = Self.groupLabels[g] { column.append(railLabel(label)) }
            var items = group
            if let order = Self.railOrder[group[0].key] {
                items = order.compactMap { key in group.first { $0.key == key } }
            }
            for item in items {
                let row = NavRow(key: item.key, symbol: item.symbol, title: item.title)
                row.onClick = { [weak self] key in self?.select(tab: key) }
                railRows.append(row)
                column.append(row)
            }
        }

        // One pixel between rows, as in the sidebar.
        let nav = Theme.vstack(column, spacing: Theme.m(1))
        nav.alignment = .leading
        nav.translatesAutoresizingMaskIntoConstraints = false
        rail.addSubview(nav)

        // The foot: whether SayControl can dictate right now, and which
        // version this is. Not your name or plan — those are a click away
        // under Account and Plan.
        let health = HealthFoot { [weak self] in self?.select(tab: "permissions") }
        healthFoot = health
        health.translatesAutoresizingMaskIntoConstraints = false
        rail.addSubview(health)

        let pad = Theme.m(8)
        let railTop = Self.railInset
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: rail.leadingAnchor, constant: pad + Theme.m(10)),
            title.centerYAnchor.constraint(equalTo: rail.topAnchor, constant: titleLine - railTop),
            title.trailingAnchor.constraint(lessThanOrEqualTo: rail.trailingAnchor, constant: -pad),
            nav.topAnchor.constraint(equalTo: rail.topAnchor, constant: Theme.m(58) - railTop),
            nav.leadingAnchor.constraint(equalTo: rail.leadingAnchor, constant: pad),
            nav.trailingAnchor.constraint(equalTo: rail.trailingAnchor, constant: -pad),
            health.leadingAnchor.constraint(equalTo: rail.leadingAnchor, constant: pad),
            health.trailingAnchor.constraint(equalTo: rail.trailingAnchor, constant: -pad),
            health.bottomAnchor.constraint(equalTo: rail.bottomAnchor, constant: -pad),
            health.topAnchor.constraint(greaterThanOrEqualTo: nav.bottomAnchor, constant: Theme.m(12)),
        ])
        for v in column { v.widthAnchor.constraint(equalTo: nav.widthAnchor).isActive = true }
    }

    /// The sidebar's `.lbl`: 14 px above, 5 below, the text indented to sit
    /// over the row titles' icons.
    private func railLabel(_ text: String) -> NSView {
        let host = NSView()
        let f = RowGroup.caps(text)
        f.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(f)
        NSLayoutConstraint.activate([
            f.topAnchor.constraint(equalTo: host.topAnchor, constant: Theme.m(14) + 2),
            f.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -Theme.m(5) - 2),
            f.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: Theme.m(10)),
        ])
        return host
    }

    /// Jump straight to a section — the account popover's "Plan & billing" and
    /// the snapshot tool both arrive this way.
    @objc private func openTab(_ note: Notification) {
        guard let key = note.object as? String else { return }
        select(tab: key)
    }

    func select(tab key: String) {
        // A user's copy has no Model section: anything still asking for it
        // lands on Plan.
        let key = (Config.retail && key == "model") ? "billing" : key
        guard let i = Self.tabKeys.firstIndex(of: key) else { return }
        // A section with no row in the rail is not a place to land.
        if !Self.shows(key) { return }
        if i == Self.lastTab && !bodyHost.subviews.isEmpty { return }
        showTab(i, animated: window != nil)
    }

    /// Which tab change is the latest, so a slow fade-out from an earlier
    /// click doesn't put its page back over the newer one.
    private var tabTurn = 0
    private weak var rail: NSView?
    private var healthFoot: HealthFoot?

    /// The picked row's fill travels to the new row instead of jumping —
    /// the same slide the window's sidebar does.
    private func slideSelection(from old: NavRow?, to new: NavRow?) {
        guard let old = old, let new = new, old !== new, let rail = rail, old.window != nil else { return }
        let slider = ColorView(color: Theme.navPick)
        slider.wantsLayer = true
        slider.layer?.cornerRadius = Theme.m(8)
        slider.frame = old.convert(old.bounds, to: rail)
        rail.addSubview(slider, positioned: .below, relativeTo: nil)
        new.paintsSelection = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.32
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 1.2, 0.5, 1)
            ctx.allowsImplicitAnimation = true
            slider.animator().frame = new.convert(new.bounds, to: rail)
        }, completionHandler: {
            new.paintsSelection = true
            slider.removeFromSuperview()
        })
    }

    private func showTab(_ i: Int, animated: Bool = false) {
        // A remembered section this build doesn't show lands on General.
        let i = Self.shows(Self.tabKeys[i]) ? i : 0
        let from = Self.lastTab
        Self.lastTab = i
        let was = railRows.first { $0.selected }
        railRows.forEach { $0.selected = ($0.key == Self.tabKeys[i]) }
        Theme.setDisplay(sectionTitle, Self.tabTitles[i])
        let body = bodies[i] ?? make(tab: i)
        bodies[i] = body
        // The old page fades up and out in a beat, then the new one arrives
        // block by block — the main window's page motion, so moving between
        // sections feels like moving between panes.
        let turn = tabTurn &+ 1
        tabTurn = turn
        let old = bodyHost.subviews
        let place = { [weak self] in
            guard let self = self, self.tabTurn == turn else { return }
            self.bodyHost.subviews.forEach { $0.removeFromSuperview() }
            old.forEach { $0.alphaValue = 1; Motion.settle($0) }
            Motion.settle(body)
            body.alphaValue = 1
            body.fill(self.bodyHost)
            if animated { Motion.arrive(body, direction: i >= from ? 1 : -1) }
        }
        if animated, !old.isEmpty, !Motion.reduced {
            slideSelection(from: was, to: railRows.first { $0.selected })
            old.forEach { Motion.leave($0, done: place) }
        } else {
            place()
        }
        if Self.tabKeys[i] == "model" { modelsPage?.appeared() } else { modelsPage?.disappeared() }
        if Self.tabKeys[i] == "privacy" { refreshClips(); refreshVoicePromise() }
        if Self.tabKeys[i] == "permissions" { startPermissionPolling() } else { stopPermissionPolling() }
        // Plans can change outside the app (Paddle's portal, another Mac).
        if Self.tabKeys[i] == "billing" || Self.tabKeys[i] == "account" { Cloud.shared.refreshAccountIfStale() }
    }

    override var wantsUpdateLayer: Bool { true }
    /// The window's own colour, so the white groups read as the things to
    /// touch; a ring of ink at 10% for an edge, and the mockup's sheet
    /// shadow — deeper than a popover's, since a sheet sits highest.
    override func updateLayer() {
        layer?.backgroundColor = Theme.paper.cgColor
        layer?.borderColor = Self.ring.cgColor
        layer?.shadowColor = Theme.hex(0x141822).cgColor
        layer?.shadowOpacity = isDark ? 0.6 : 0.26
        layer?.shadowRadius = 30
        layer?.shadowOffset = CGSize(width: 0, height: -24)
    }
    private static let ring = Theme.dyn(Theme.hex(0x000000, 0.10), NSColor.white.withAlphaComponent(0.08))
    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Theme.m(18), cornerHeight: Theme.m(18), transform: nil)
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    /// The sheet is a surface of its own — dragging it must not drag the
    /// window, and a click on its background must stop here rather than
    /// travelling up the responder chain to whatever is behind it.
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {}

    private func make(tab i: Int) -> NSView {
        switch Self.tabKeys[i] {
        case "model":       return makeModelTab()
        case "system":      return makeSystemTab()
        case "account":     return makeAccountTab()
        case "billing":     return makeBillingTab()
        case "permissions": return makePermissionsTab()
        case "privacy":     return makePrivacyTab()
        default:            return makeGeneralTab()
        }
    }

    override func paneAppeared() {
        healthFoot?.refresh()
        if Self.tabKeys[Self.lastTab] == "model" { modelsPage?.appeared() }
        if Self.tabKeys[Self.lastTab] == "permissions" { startPermissionPolling() }
        if Self.tabKeys[Self.lastTab] == "privacy" { refreshClips(); refreshVoicePromise() }
    }

    // MARK: - General

    private func makeGeneralTab() -> NSView {
        // One key per job, as keycaps with Change after them; Change
        // listens for the next key. Cancel is esc and has no Change.
        let reset = FlatButton("Reset to default", .quiet) { Shortcuts.resetToDefault() }
        reset.isHidden = Shortcuts.isDefault
        shortcutsReset = reset
        let shortcuts = RowGroup("Shortcuts", trailing: reset)
        // A picture per key's job: the two ways to talk wear the voice's
        // rose, command mode the blue it wears on Model, cancel is slate.
        shortcuts.add(FormRow("Hold to dictate", "Held down, it listens. Let go and it types.",
                              controls: [ShortcutRow(.dictate)], icon: Self.tile("mic.fill", .rose)))
        shortcuts.add(FormRow("Hands-free", "Press to start. Say “send it” to finish.",
                              controls: [ShortcutRow(.handsFree)], icon: Self.tile("record.circle", .rose),
                              tip: "Or press the key again. Start Dictation in the menu bar does the same."))
        // Command mode is Pro's: on Free the row says so, the way the Plan
        // page's table does.
        shortcuts.add(FormRow("Command mode", "Hold both, then say what to change.",
                              controls: [ShortcutRow(.commandModifier)], icon: Self.tile("command", .blue),
                              tip: "Hold both and say what to do to the text you have selected.",
                              badge: Account.plan == "pro" ? nil : ProTag()))
        shortcuts.add(FormRow("Cancel", "Throws away what you just said.",
                              controls: [ShortcutRow(.fixed, parts: [KeyPart("esc", symbol: "escape")])],
                              icon: Self.tile("escape", .slate)))

        // The mockup's segmented controls: words only, each its own width.
        let look = RowGroup("Appearance")
        let appearance = PillSwitcher(["System", "Light", "Dark"],
                                      selected: ["system", "light", "dark"].firstIndex(of: Config.shared.appearance) ?? 0) { i in
            let picked = ["system", "light", "dark"][i]
            Config.shared.appearance = picked
            Config.shared.applyAppearance()
            Config.shared.log("Appearance set to \(picked)")
        }
        look.add(FormRow("Theme", "", controls: [appearance]))
        let sizes = Self.fontScales
        let nearest = sizes.enumerated().min {
            abs($0.1 - Config.shared.fontScale) < abs($1.1 - Config.shared.fontScale)
        }?.0 ?? 1
        let textSize = PillSwitcher(["Smallest", "Moderate", "Larger"], selected: nearest) { [weak self] i in
            self?.setFontScale(sizes[i])
        }
        look.add(FormRow("Text size", "", controls: [textSize]))
        let wordModes = ["line", "card", "off"]
        let words = PillSwitcher(["One line", "Full card", "Off"],
                                 selected: wordModes.firstIndex(of: Config.shared.liveWords) ?? 0) { i in
            Config.shared.liveWords = wordModes[i]
            Config.shared.log("Words while you speak set to \(wordModes[i])")
        }
        look.add(FormRow("Words while you speak", "", controls: [words]))
        // The pill out of the way while you read or watch: it fades after a
        // few idle seconds and comes back for a dictation or a pointer.
        let pill = PillSwitcher(["Always shown", "Hide after 5 s"], selected: Config.shared.pillAutoHide ? 1 : 0) { i in
            Config.shared.pillAutoHide = i == 1
            Config.shared.log("Pill when idle set to \(i == 1 ? "hide" : "always")")
            NotificationCenter.default.post(name: Notification.Name("sayctrlPillAutoHideChanged"), object: nil)
        }
        look.add(FormRow("Pill when idle", "Hidden, it comes back when you dictate or point at it.", controls: [pill]))

        return makeSheetScroll([shortcuts, look])
    }

    private weak var shortcutsReset: FlatButton?
    @objc private func shortcutsChanged() { shortcutsReset?.isHidden = Shortcuts.isDefault }

    /// The three sizes the picker offers. Moderate is the size the 2.1 window
    /// is drawn at; Config clamps to 0.7…1.4, so Larger sits on the ceiling.
    static let fontScales: [Double] = [1.12, 1.25, 1.40]

    private func setFontScale(_ scale: Double) {
        guard scale != Config.shared.fontScale else { return }
        Config.shared.fontScale = scale
        Theme.scale = CGFloat(scale)
        Config.shared.log("Text size set to \(scale)")
        // Fonts bake in at view construction, so the whole window rebuilds.
        SettingsUI.shared.rebuildAfterScaleChange()
    }

    // MARK: - Models

    /// design/models-pane-redesign.html, built in ModelsPage.swift.
    private func makeModelTab() -> NSView {
        let page = ModelsPage()
        page.onOpenTab = { [weak self] key in self?.select(tab: key) }
        modelsPage = page
        let scroll = makeSheetScroll([page])
        page.scroll = scroll
        return scroll
    }

    // MARK: - System

    private func makeSystemTab() -> NSView {
        // Each switch shows what it does instead of saying it: red is what
        // comes out, green is what goes in. The sentence is the tooltip.
        let dictation = RowGroup("Dictation")
        dictation.add(SwitchRow("Clean up speech", isOn: Config.shared.cleanup,
                                tip: "Strips “um”, stutters and cut-off fragments before pasting.",
                                example: ExampleStrip([.cut("um"), .text("I think"), .cut("uh"), .text("it works")])) {
            Config.shared.setFlag("CLEANUP", $0)
        })
        dictation.add(SwitchRow("Learn my corrections", isOn: Config.shared.autoLearn,
                                tip: "Fix a word right after a paste and it becomes a dictionary rule.",
                                example: ExampleStrip([.cut("Jon"), .arrow, .add("John")])) {
            Config.shared.setFlag("AUTOLEARN", $0)
        })
        dictation.add(SwitchRow("Read the screen for names", isOn: Config.shared.screenVocab,
                                tip: Self.screenVocabDetail,
                                example: ExampleStrip([.cut("cooper netties"), .arrow, .add("Kubernetes")])) {
            Config.shared.setFlag("SCREEN_VOCAB", $0)
        })
        dictation.add(SwitchRow("Commands in the terminal", isOn: Config.shared.shell,
                                tip: "Talking into a terminal writes the everyday commands — listing, folders, git. Anything else stays prose, and nothing runs until you press Return.",
                                example: ExampleStrip([.text("“list files”"), .arrow, .code("ls")])) {
            Config.shared.setFlag("TERMINAL_COMMANDS", $0)
        })

        let mac = RowGroup("On this Mac")
        mac.add(SwitchRow("Sound cues", isOn: Config.shared.sounds,
                          tip: "A click when recording starts and stops.") { Config.shared.setFlag("SOUNDS", $0) })
        mac.add(SwitchRow("Launch at login", isOn: Config.shared.launchAtLogin,
                          tip: "Takes effect at your next login.") { Config.shared.launchAtLogin = $0 })

        // Pointers, not settings: each is a page of its own in the sidebar,
        // so each wears that page's symbol. The agent voice lived on this
        // tab through 2.2 — the pointer stays so the people who learned
        // that path aren't stranded.
        let elsewhere = RowGroup("In the sidebar")
        elsewhere.add(FormRow("Tones", "Where you dictate picks the register.",
                              controls: [FlatButton("Open Tones") { SettingsUI.shared.select("tones") }],
                              icon: Self.tile("slider.vertical.3", .amber)))
        elsewhere.add(FormRow("Agents", "The agent voice lives in Agents now.",
                              controls: [FlatButton("Open Claude") { SettingsUI.shared.select("agent-claude") }],
                              icon: Self.tile("sparkles", .violet)))

        return makeSheetScroll([dictation, mac, elsewhere])
    }

    // MARK: - Account

    private func makeAccountTab() -> NSView {
        guard Account.signedIn else {
            let group = RowGroup("Sign in")
            group.add(FormRow("Not signed in",
                              Config.retail ? "Sign in to start dictating."
                                            : "SayControl works fully without an account, on your own keys.",
                              controls: [], icon: Self.tile("person.crop.circle", .blue),
                              tip: Config.retail ? "Free gives you 2,000 cloud words a week, and Pro when you want more."
                                                 : "Signing in gives you the cloud plans; your own keys keep working either way."),
                      vertical: 12)
            let go = GoogleSignInButton { [weak self] in
                Account.signInWithGoogle { ok in
                    guard ok else { return }
                    self?.rebuildAccountTabs()
                    SettingsUI.shared.toast("Signed in")
                }
            }
            go.translatesAutoresizingMaskIntoConstraints = false
            go.widthAnchor.constraint(equalToConstant: Theme.m(260)).isActive = true
            let form = EmailSignInForm()
            form.onGoogle = { go.onClick() }
            form.onSignedIn = { [weak self] in
                self?.rebuildAccountTabs()
                SettingsUI.shared.toast("Signed in")
            }
            form.translatesAutoresizingMaskIntoConstraints = false
            let ways = Theme.vstack([go, form], spacing: Theme.m(12))
            // After the stack: a rule between views with no common ancestor
            // throws, and the tab is left blank.
            form.widthAnchor.constraint(equalTo: go.widthAnchor).isActive = true
            group.add(Theme.hstack([ways, Theme.spacer()], spacing: 0), vertical: 12)
            return makeSheetScroll([group])
        }

        // Name and address: Google's, or the ones given at sign-up.
        let profile = RowGroup("Profile")
        let av = AvatarButton(size: 40)
        let who = Theme.vstack([RowText.title(Account.name),
                                RowText.help(Account.email.isEmpty ? "Signed in" : Account.email)],
                               spacing: Theme.m(1))
        who.setHuggingPriority(.init(1), for: .horizontal)
        profile.add(Theme.hstack([av, who], spacing: Theme.m(12)), vertical: 10)
        profile.add(Theme.hstack([
            RowText.help(Account.withPassword ? "You sign in with your email address and password."
                                              : "Your name and address come from your Google account."),
            Theme.spacer(),
            FlatButton("Sign out", .quiet) { [weak self] in
                Account.signOut()
                self?.rebuildAccountTabs()
                SettingsUI.shared.toast("Signed out")
            },
        ], spacing: Theme.m(8)))

        // The developers' build can turn the cloud off for its own keys. A
        // user's copy is cloud-only, so it has no switch to turn it off with.
        let dictation = RowGroup("Dictation")
        dictation.add(SwitchRow("Dictate on SayControl cloud",
                                "Your plan does the listening and the polish, instead of your keys. When it runs out, they take over.",
                                isOn: Config.shared.cloud) { on in
            Config.shared.setFlag("CLOUD", on)
            Cloud.shared.cloudSwitched()
            NotificationCenter.default.post(name: .sayctrlAccountChanged, object: nil)
        })

        // Unlabelled and on its own, so the one irreversible button is never
        // a row away from Save.
        let danger = RowGroup()
        danger.add(FormRow("Delete account",
                           "Your dictionary, phrases and history stay on this Mac.",
                           controls: [FlatButton("Delete", .danger) { [weak self] in self?.deleteAccount() }],
                           titleColor: Theme.danger,
                           tip: "Removes your name, address and sign-ins from SayControl. Dictionary, phrases and history stay on this Mac."))

        return makeSheetScroll(Config.retail ? [profile, danger] : [profile, dictation, danger])
    }

    @objc private func accountChanged() { rebuildAccountTabs() }

    /// Asked once, then done on the server; signing out follows, which
    /// closes the window to the sign-in.
    private func deleteAccount() {
        let alert = NSAlert()
        alert.messageText = "Delete your SayControl account?"
        alert.informativeText = "Your name, address and sign-ins are removed, and every Mac is signed out. "
            + "It can't be undone. Your dictionary, phrases and history stay on this Mac."
        alert.addButton(withTitle: "Delete account")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Cloud.shared.deleteAccount { result in
            switch result {
            case .success: SettingsUI.shared.toast("Account deleted")
            case .failure(let e): SettingsUI.shared.toast(Account.problemLine(e))
            }
        }
    }

    /// Never posts sayctrlAccountChanged itself: this runs on that very
    /// notification, and posting it here recursed until the stack ran out
    /// (2026-09-28, the first signed-in dev build). Whatever changed the
    /// account — Cloud's sign-in, sign-out and refresh — already posted it.
    private func rebuildAccountTabs() {
        bodies[Self.tabKeys.firstIndex(of: "account")!] = nil
        bodies[Self.tabKeys.firstIndex(of: "billing")!] = nil
        showTab(Self.lastTab)
    }

    // MARK: - Plan

    /// One page in both builds, drawn after design/settings-redesign.html:
    /// your plan as a card across the top, Free against Pro as one table,
    /// Enterprise, then billing while you're on Pro. Nothing about this
    /// Mac's own model: the user build is cloud-only since 2026-10-03, and
    /// the developers' build keeps its models under Model.
    private func makeBillingTab() -> NSView {
        let state = PlanState.current
        var groups: [NSView] = [PlanHero(state, actions: heroActions(state))]
        let compare = RowGroup("Compare plans")
        compare.replaceBox(with: CompareTable(state, free: freeHead(state), pro: proHead(state)))
        groups.append(compare)
        groups.append(enterpriseGroup())
        if state.isPro {
            let pay = RowGroup("Billing")
            pay.add(FormRow("Card and receipts", "Paddle keeps the card; SayControl never sees it.",
                            controls: [FlatButton("Manage", symbol: "arrow.up.right") { Account.manageBilling() }],
                            icon: Self.tile("creditcard", .slate)))
            groups.append(pay)
        }
        // What the server says is fresh the moment the tab opens. Only when
        // it's stale: the refresh's answer rebuilds this tab, so asking every
        // time would ask forever.
        Cloud.shared.refreshAccountIfStale()
        return makeSheetScroll(groups)
    }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    /// The buttons under the hero: what you'd do next from where you are.
    private func heroActions(_ state: PlanState) -> [NSView] {
        switch state {
        case .signedOut:
            return [FlatButton("Sign in") { [weak self] in self?.select(tab: "account") }]
        case .free, .low, .out:
            if Config.retail && !Account.available {
                let b = FlatButton("Coming soon", .plain)
                b.isEnabled = false
                return [b]
            }
            return [FlatButton("Upgrade to Pro · $\(Account.proDollarsPerMonth) a month", .ember) { Account.upgrade() }]
        case .pro:
            return [FlatButton("Manage billing", symbol: "arrow.up.right") { Account.manageBilling() },
                    FlatButton("Switch to Free", .quiet) { [weak self] in self?.switchToFree() }]
        case .ending:
            return [FlatButton("Keep Pro", .primary) { [weak self] in self?.keepPro() },
                    FlatButton("Manage billing", .quiet, symbol: "arrow.up.right") { Account.manageBilling() }]
        }
    }

    private func off(_ title: String) -> FlatButton {
        let b = FlatButton(title, .plain)
        b.isEnabled = false
        return b
    }

    /// The Free column's head: its chip and its one button.
    private func freeHead(_ state: PlanState) -> (chip: GrantChip?, button: NSView) {
        switch state {
        case .pro:
            return (nil, FlatButton("Switch to Free") { [weak self] in self?.switchToFree() })
        case .ending(let end):
            let day = Self.dayFormat.string(from: end)
            return (GrantChip("From \(day)", .warn), off("Starts \(day)"))
        case .signedOut:
            return (nil, off("Free"))
        default:
            return (GrantChip("Current", .ok), off("Your plan"))
        }
    }

    /// The Pro column's head.
    private func proHead(_ state: PlanState) -> (chip: GrantChip?, button: NSView) {
        switch state {
        case .pro:
            return (GrantChip("Current", .ok), FlatButton("Manage") { Account.manageBilling() })
        case .ending(let end):
            return (GrantChip("Ends \(Self.dayFormat.string(from: end))", .bad),
                    FlatButton("Keep Pro", .primary) { [weak self] in self?.keepPro() })
        default:
            if Config.retail && !Account.available { return (nil, off("Coming soon")) }
            return (nil, FlatButton("Upgrade", .ember) { Account.upgrade() })
        }
    }

    /// Teams, priced by conversation: a row under the table, not a third
    /// column squeezing the two that most people choose between.
    private func enterpriseGroup() -> NSView {
        let group = RowGroup("For teams")
        let contact = FlatButton("Contact us") {
            let subject = "SayControl for teams".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let url = URL(string: "mailto:\(HelpPane.supportEmail)?subject=\(subject)") {
                NSWorkspace.shared.open(url)
            }
        }
        group.add(FormRow("Enterprise", "Everything in Pro, one bill for the team, and help rolling it out.",
                          controls: [contact], icon: Self.tile("building.2", .slate)))
        return group
    }

    /// Back to Free: Pro is cancelled at the end of the month already paid
    /// for, and stays on until then.
    private func switchToFree() {
        let until = Cloud.shared.subscription?.renewsAt.map { Self.dayFormat.string(from: $0) }
        let alert = NSAlert()
        alert.messageText = "Switch to Free?"
        alert.informativeText = "Pro stays on until \(until ?? "the end of the month you paid for"), and you won't be charged again. "
            + "Then you're on Free: \(Account.grouped(Account.freeWordsPerWeek)) cloud words a week."
        alert.addButton(withTitle: "Switch to Free")
        alert.addButton(withTitle: "Keep Pro")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Cloud.shared.changePro(cancel: true) { result in
            switch result {
            case .success: SettingsUI.shared.toast(until.map { "Pro stays on until \($0)" } ?? "Pro is cancelled")
            case .failure(let e): SettingsUI.shared.toast(Account.problemLine(e))
            }
        }
    }

    private func keepPro() {
        Cloud.shared.changePro(cancel: false) { result in
            switch result {
            case .success: SettingsUI.shared.toast("You're keeping Pro")
            case .failure(let e): SettingsUI.shared.toast(Account.problemLine(e))
            }
        }
    }

    // MARK: - Permissions

    private var permissionRows: [String: GrantRow] = [:]
    private var permSummary: GrantSummary?
    private var permTimer: Timer?

    /// The tile beside a settings row: the System Settings size, a notch
    /// under the promise cards' and the summary's.
    fileprivate static func tile(_ symbol: String, _ hue: Theme.Hue) -> IconTile {
        IconTile(symbol, hue, side: 28, icon: 13)
    }

    /// A summary, then two cards. The summary is the answer at a glance —
    /// how many of the four are on, and which one isn't. The first card is
    /// what dictation needs, in the order you'd explain it: the ear, the
    /// hands, the key. Every row the same shape: a picture, the name macOS
    /// gives it, one line of what it is for, and on the right either the
    /// green chip or Set Up; the longer why is the row's tooltip. The second
    /// card is grants that each unlock one command and nothing else, kept
    /// apart so they do not read as more setup. The rows read what macOS
    /// actually granted and poll while the tab is up, so a switch flipped in
    /// System Settings shows here as it lands.
    private func makePermissionsTab() -> NSView {
        let summary = GrantSummary()
        permSummary = summary
        let top = RowGroup()
        top.add(summary, vertical: 14)

        // Hues are what the thing is: the microphone is the voice's rose
        // everywhere, both keyboard grants share violet.
        let card = RowGroup("For dictation")
        let mic = GrantRow("Microphone", "Hears you while the key is held.",
                           icon: Self.tile("mic.fill", .rose)) {
            Permissions.requestMicrophone {}
        }
        let ax = GrantRow("Accessibility", "Types your words where the cursor is.",
                          icon: Self.tile("accessibility", .blue),
                          tip: "Lets SayControl paste where the cursor is and read the text a command acts on.") { [weak self] in
            self?.guide(.accessibility)
        }
        let input = GrantRow("Input Monitoring", "Notices the \(Shortcuts.dictate.text) key in every app.",
                             icon: Self.tile("keyboard", .violet),
                             tip: "Lets SayControl see the \(Shortcuts.dictate.text) key while another app is in front.") { [weak self] in
            self?.guide(.inputMonitoring)
        }
        let globe = GrantRow("Globe key", "Set “Press 🌐 key to” to Do Nothing.",
                             icon: Self.tile("globe", .violet),
                             tip: "System Settings → Keyboard → “Press 🌐 key to” → Do Nothing, so a tap of fn opens nothing else.") {
            Permissions.openKeyboardSettings()
        }
        [mic, ax, input, globe].forEach { card.add($0) }

        // Automation is the odd one out: the pane lists only apps that have
        // asked, and takes no dragged-in icon. So Set Up asks — Apple's own
        // dialog — and only once refused does it open the pane, where the
        // switch now exists to flip.
        let optional = Theme.meta("Optional", 11.5)
        optional.toolTip = "Each one unlocks a command. Nothing here stops dictation."
        let features = RowGroup("For commands", trailing: optional)
        let shot = GrantRow("Screen Recording", "For “take a screenshot” and reading names on screen.",
                            icon: Self.tile("rectangle.dashed.badge.record", .teal), optional: true) { [weak self] in
            self?.guide(.screenRecording)
        }
        let finder = GrantRow("Finder", Self.finderDetail, icon: Self.tile("folder", .slate), optional: true) { [weak self] in
            self?.requestAutomation([Self.finderID])
        }
        let browser = GrantRow("Web browser", Self.browserDetail, icon: Self.tile("safari", .slate), optional: true) { [weak self] in
            guard let self = self else { return }
            let running = BrowserURL.runningScriptableBrowsers().map(\.bundleID)
            if running.isEmpty {
                SettingsUI.shared.toast("Open Safari or Chrome first, then Set Up")
                return
            }
            self.requestAutomation(running)
        }
        [shot, finder, browser].forEach { features.add($0) }
        permissionRows = ["ax": ax, "input": input, "mic": mic, "globe": globe,
                          "shot": shot, "finder": finder, "browser": browser]
        return makeSheetScroll([top, card, features])
    }

    /// Set Up for a switch in a System Settings list: the pane and the
    /// drag-me panel on every click, and back here once it is on.
    private func guide(_ grant: Permissions.Listed) {
        Permissions.guide(grant) { [weak self] in
            SettingsUI.shared.present()
            self?.refreshPermissions()
        }
    }

    private static let finderID = "com.apple.finder"
    private static let finderDetail = "For “copy the file path”."
    private static let browserDetail = "For “copy the link”."

    /// Apple's consent dialog for each target in turn; a target that already
    /// said no gets the pane instead, since the dialog never comes twice.
    private func requestAutomation(_ targets: [String]) {
        guard let id = targets.first else { return }
        let rest = Array(targets.dropFirst())
        if Automation.status(for: id) == -1743 {
            Permissions.open("Privacy_Automation")
            requestAutomation(rest)
            return
        }
        Automation.request(id) { [weak self] status in
            Config.shared.log("Automation for \(id): \(status)")
            self?.refreshPermissions()
            self?.requestAutomation(rest)
        }
    }

    private func startPermissionPolling() {
        refreshPermissions()
        permTimer?.invalidate()
        permTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshPermissions()
        }
    }
    private func stopPermissionPolling() {
        permTimer?.invalidate()
        permTimer = nil
    }

    private func refreshPermissions() {
        guard !permissionRows.isEmpty else { return }
        let mic = Permissions.microphone == .granted
        let ax = Permissions.accessibility == .granted
        let input = Permissions.inputMonitoring == .granted
        let globe = Permissions.globeKeyIsQuiet
        permissionRows["mic"]?.granted = mic
        permissionRows["ax"]?.granted = ax
        permissionRows["input"]?.granted = input
        permissionRows["globe"]?.set(granted: globe, chip: "Ready", missing: "Not set")
        permissionRows["shot"]?.granted = Permissions.screenRecording == .granted
        // What each missing one costs, said the way the user will notice it.
        permSummary?.update([
            ("Microphone", mic, "Microphone is off, so SayControl can't hear you."),
            ("Accessibility", ax, "Accessibility is off, so your words can't be typed in."),
            ("Input Monitoring", input, "Input Monitoring is off, so the \(Shortcuts.dictate.text) key does nothing."),
            ("the Globe key", globe, "The Globe key isn't set, so a tap of fn may open emoji."),
        ])

        // TCC answers for a live process only. Finder is always one; a
        // browser has to be open to be asked about, and the row says so.
        let finderStatus = Automation.status(for: Self.finderID)
        permissionRows["finder"]?.granted = finderStatus == 0
        permissionRows["finder"]?.detail = finderStatus == 0 ? Self.finderDetail
            : finderStatus == -1743 ? "Refused once. Switch it on in Automation."
            : Self.finderDetail + " macOS asks once."

        let browsers = BrowserURL.runningScriptableBrowsers()
        let statuses = browsers.map { ($0.name, Automation.status(for: $0.bundleID)) }
        let allowed = statuses.filter { $0.1 == 0 }.map(\.0)
        let refused = statuses.filter { $0.1 == -1743 }.map(\.0)
        let row = permissionRows["browser"]
        if browsers.isEmpty {
            row?.granted = false
            row?.detail = Self.browserDetail + " Open Safari or Chrome first."
        } else if allowed.count == browsers.count {
            row?.granted = true
            row?.detail = Self.browserDetail + " \(allowed.joined(separator: " and ")) \(allowed.count == 1 ? "allows" : "allow") it."
        } else {
            row?.granted = false
            let waiting = statuses.filter { $0.1 != 0 }.map(\.0)
            row?.detail = refused.isEmpty
                ? Self.browserDetail + " Asks \(waiting.joined(separator: " and ")), once."
                : "\(refused.joined(separator: " and ")) refused once. Switch it on in Automation."
        }
    }

    // MARK: - Privacy

    /// Three promises across the top, as pictures; then what is kept, with
    /// the switches; then where it is, with the ways to take it out or throw
    /// it away. The paragraph that used to open the tab is the promises'
    /// tooltips now.
    private func makePrivacyTab() -> NSView {
        let voice = PromiseCard()
        voiceCard = voice
        refreshVoicePromise()
        let promises = NSStackView(views: [
            voice,
            PromiseCard("eye.slash", .slate, "No tracking", "SayControl ships with no telemetry."),
            PromiseCard("clock.arrow.circlepath", .blue, "History is yours", "Kept on this Mac. Export or clear it below.",
                        tip: "Dictionary, phrases, tones, history and the clips behind it are files on this Mac and are never uploaded."),
        ])
        promises.orientation = .horizontal
        promises.distribution = .fillEqually
        promises.alignment = .top
        promises.spacing = Theme.m(8)
        for card in promises.arrangedSubviews where card !== voice {
            card.heightAnchor.constraint(equalTo: voice.heightAnchor).isActive = true
        }
        let top = RowGroup()
        top.replaceBox(with: promises)

        // Same thing, same picture: history is blue and the audio is the
        // voice's rose in both groups, the screen is Screen Recording's teal.
        let toggles = RowGroup("What SayControl keeps")
        toggles.add(SwitchRow("Keep dictation history", "For Insights and Recent. The last 2,000.",
                              isOn: Config.shared.flag("KEEP_HISTORY", default: true),
                              icon: Self.tile("clock.arrow.circlepath", .blue)) { [weak self] on in
            Config.shared.setFlag("KEEP_HISTORY", on)
            self?.audioRow?.isEnabled = on
        })
        audioRow = SwitchRow("Keep the audio", "So Recent can replay a clip or run it again.",
                             isOn: Config.shared.flag("KEEP_AUDIO", default: true),
                             icon: Self.tile("waveform", .rose),
                             tip: "The clip behind each dictation, so Recent can play it back and run it through the model again.") { [weak self] on in
            Config.shared.setFlag("KEEP_AUDIO", on)
            self?.refreshClips()
        }
        audioRow?.isEnabled = Config.shared.flag("KEEP_HISTORY", default: true)
        toggles.add(audioRow!)
        toggles.add(SwitchRow("Read the screen for names", Self.screenVocabLine,
                              isOn: Config.shared.screenVocab, icon: Self.tile("text.viewfinder", .teal),
                              tip: Self.screenVocabDetail) { Config.shared.setFlag("SCREEN_VOCAB", $0) })
        toggles.add(FormRow("Share anonymous usage", controls: [GrantChip("Never", .ok)],
                            icon: Self.tile("chart.bar", .slate), tip: "Off. SayControl ships with no telemetry."))

        // What is kept, where, and the way to take it out or throw it away.
        let files = RowGroup("Stored on this Mac")
        let kept = HistoryStore.shared.entries.count
        files.add(FormRow("Dictation history", "\(kept.formatted()) dictation\(kept == 1 ? "" : "s") kept.",
                          controls: [FlatButton("Export") { [weak self] in self?.exportHistory() },
                                     FlatButton("Clear", .danger) { [weak self] in self?.clearHistory() }],
                          icon: Self.tile("clock.arrow.circlepath", .blue)))
        clipsRow = FormRow("Voice clips", "Counting…",
                           controls: [FlatButton("Show") { NSWorkspace.shared.open(Recordings.shared.folder) },
                                      FlatButton("Delete all", .danger) { [weak self] in self?.clearClips() }],
                           icon: Self.tile("waveform", .rose),
                           tip: (Recordings.shared.folder.path as NSString).abbreviatingWithTildeInPath)
        files.add(clipsRow!)
        refreshClips()
        files.add(FormRow("Config folder",
                          Config.retail ? "Dictionary, phrases and the log." : "Keys, dictionary, phrases and the log.",
                          controls: [FlatButton("Open") { NSWorkspace.shared.open(Config.shared.dir) }],
                          icon: Self.tile("folder", .slate),
                          tip: (Config.shared.dir.path as NSString).abbreviatingWithTildeInPath))
        if !Config.retail {
            files.add(FormRow("API keys", "", controls: [FlatButton("Open ↗") {
                NSWorkspace.shared.open(URL(string: Config.shared.provider.keysPage)!)
            }], icon: Self.tile("key", .amber)))
        }

        return makeSheetScroll([top, toggles, files])
    }

    /// The first promise is the one that depends on where takes go — the
    /// cloud, this Mac, or a developer's provider — so it is redrawn every
    /// time the tab shows, in case Plans or the Model tab moved it.
    private var voiceCard: PromiseCard?
    private func refreshVoicePromise() {
        guard let card = voiceCard else { return }
        if Config.shared.cloudOn {
            card.set("icloud.and.arrow.up", .slate, "Sent to be written down", "Through SayControl's servers, and not kept.",
                     tip: "Cloud dictation streams your audio while you speak and sends back the words. Neither is stored.")
        } else if Config.retail {
            card.set("icloud.and.arrow.up", .slate, "Sent to be written down", "Once you're signed in, through SayControl's servers, and not kept.")
        } else if Config.shared.provider == .local && !Config.shared.meshEnabled {
            card.set("lock.fill", .green, "Your voice stays here", "The local model never sends it anywhere.")
        } else if Config.shared.provider == .local {
            card.set("icloud.and.arrow.up", .slate, "First seconds go out", "A cloud model hears them. The rest stays here.")
        } else {
            card.set("icloud.and.arrow.up", .slate, "Sent to your provider", "The one you picked, on your own key.",
                     tip: "Your audio goes to the transcription provider you picked, using your key.")
        }
    }

    /// How much of the Mac the kept clips are using, once the folder has been
    /// counted off the main thread.
    private func refreshClips() {
        Recordings.shared.summary { [weak self] count, bytes in
            guard let row = self?.clipsRow else { return }
            row.detail = count == 0
                ? (Recordings.shared.isEnabled ? "Nothing kept yet." : "Not being kept.")
                : "\(count.formatted()) clip\(count == 1 ? "" : "s") · \(LocalEngine.humanSize(bytes))"
        }
    }

    private func clearClips() {
        let alert = NSAlert()
        alert.messageText = "Delete every kept clip?"
        alert.informativeText = "The transcripts stay. The audio behind them goes, and Recent can't play them back."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Recordings.shared.clear()
        refreshClips()
        SettingsUI.shared.toast("Clips deleted")
    }

    private func exportHistory() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "sayctrl-history.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        let text = HistoryStore.shared.entries
            .map { "[\(fmt.string(from: $0.date))] \($0.text)" }
            .joined(separator: "\n\n")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        SettingsUI.shared.toast("Exported")
    }

    private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear every dictation?"
        alert.informativeText = "Recent and Insights both read from this. It cannot be undone."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        HistoryStore.shared.clear()
        SettingsUI.shared.toast("History cleared")
    }

    @objc private func openTones() { SettingsUI.shared.select("tones") }

    override func paneDisappeared() {
        modelsPage?.disappeared()
        // The sheet is discarded every time it closes, so a timer left running
        // here is one more every time it opens — polling for a view that is no
        // longer on screen.
        stopPermissionPolling()
    }
}

// MARK: - The sheet's own pieces

/// The rail's panel: the window sidebar's sand and hairline, rounded on
/// every corner, floating a few points inside the sheet.
final class SettingsRail: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
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

/// The rail's foot: a dot and a line saying whether a dictation would work
/// right now, then the version and Check for updates. Green means the
/// microphone is there, the two grants dictation can't do without are in,
/// and you're signed in; anything else is amber, says what's missing, and a
/// click goes where it's fixed.
final class HealthFoot: NSView {
    private let dot = ColorView(color: Theme.moss, radius: Theme.m(4))
    private let halo = ColorView(color: Theme.mossSoft, radius: Theme.m(7))
    private let status = Theme.text("Ready to dictate", 12.5, .medium)
    private let fix: () -> Void
    private var problem = false

    init(onFix: @escaping () -> Void) {
        fix = onFix
        super.init(frame: .zero)
        status.font = .systemFont(ofSize: Theme.m(12.5), weight: .medium)
        for v in [halo, dot] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let version = Theme.text("SayControl \(APP_VERSION)", 11.5, .regular, Theme.muted)
        version.font = .systemFont(ofSize: Theme.m(11.5))
        let update = RailLink("Check for updates") { Updates.controller.checkForUpdates(nil) }
        let lines = Theme.vstack([status, version, update], spacing: Theme.m(2))
        lines.alignment = .leading
        lines.setCustomSpacing(Theme.m(5), after: status)
        lines.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lines)
        NSLayoutConstraint.activate([
            halo.widthAnchor.constraint(equalToConstant: Theme.m(14)),
            halo.heightAnchor.constraint(equalToConstant: Theme.m(14)),
            halo.centerXAnchor.constraint(equalTo: dot.centerXAnchor),
            halo.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: Theme.m(8)),
            dot.heightAnchor.constraint(equalToConstant: Theme.m(8)),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(12)),
            dot.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            lines.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: Theme.m(9)),
            lines.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Theme.m(8)),
            lines.topAnchor.constraint(equalTo: topAnchor, constant: Theme.m(10)),
            lines.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.m(10)),
        ])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        let issue: String?
        if AudioInputs.default == nil { issue = "No microphone" }
        else if Permissions.microphone != .granted { issue = "Microphone access needed" }
        else if Permissions.accessibility != .granted { issue = "Accessibility needed" }
        else if Account.available && !Account.signedIn { issue = "Not signed in" }
        else { issue = nil }
        problem = issue != nil
        status.stringValue = issue ?? "Ready to dictate"
        dot.color = problem ? Theme.amber : Theme.moss
        halo.color = problem ? Theme.amberSoft : Theme.mossSoft
        toolTip = problem ? "Click to fix" : "Microphone, permissions and your account all check out"
    }

    override func mouseDown(with event: NSEvent) { if problem { fix() } }
    override func resetCursorRects() { if problem { addCursorRect(bounds, cursor: .pointingHand) } }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// Words that act like a link, small: ember ink, ink on hover.
final class RailLink: NSView {
    private let field: NSTextField
    private let action: () -> Void
    private var hovering = false { didSet { needsDisplay = true } }
    init(_ text: String, _ action: @escaping () -> Void) {
        self.action = action
        field = Theme.text(text, 11.5, .medium, Theme.emberInk)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(4)
        field.font = .systemFont(ofSize: Theme.m(11.5), weight: .medium)
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            field.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }
    override func mouseDown(with event: NSEvent) {}
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override var mouseDownCanMoveWindow: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { field.textColor = hovering ? Theme.ink : Theme.emberInk }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}
//
// Straight off design/sayctrl-refresh.html's Settings sheet: `.gl` group
// labels over `.grp` containers of `.srow` rows, `.pop` popups and `.field`
// boxes. They live here rather than in Components.swift because nothing
// outside the sheet is built from them.

/// One group of settings: an uppercase label, then one surface box whose
/// rows are split by full-width soft rules, then any footnotes. Hiding the
/// group hides all three together.
final class RowGroup: NSView {
    private let column = NSStackView()
    private let rows = NSStackView()
    let box = GroupBox()
    private var rowCount = 0

    /// `trailing` sits at the right end of the label line — "Reset to
    /// default", a count — centred on the label so it never makes the line
    /// taller than the label itself.
    init(_ label: String? = nil, trailing: NSView? = nil) {
        super.init(frame: .zero)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = Theme.m(8)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // The label's line box in the mockup is taller than AppKit's, so the
        // padding carries the difference: 12 px above, 2 below, plus the
        // two points each way the line box adds.
        let head = NSView()
        let top = Theme.m(12) + 2, bottom = Theme.m(2) + 2
        if let label = label {
            let f = RowGroup.caps(label)
            f.translatesAutoresizingMaskIntoConstraints = false
            head.addSubview(f)
            var pins = [
                f.topAnchor.constraint(equalTo: head.topAnchor, constant: top),
                f.bottomAnchor.constraint(equalTo: head.bottomAnchor, constant: -bottom),
                f.leadingAnchor.constraint(equalTo: head.leadingAnchor, constant: Theme.m(2)),
            ]
            if let trailing = trailing {
                trailing.translatesAutoresizingMaskIntoConstraints = false
                head.addSubview(trailing)
                pins += [
                    trailing.trailingAnchor.constraint(equalTo: head.trailingAnchor),
                    trailing.centerYAnchor.constraint(equalTo: f.centerYAnchor),
                    f.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -Theme.m(8)),
                ]
            }
            NSLayoutConstraint.activate(pins)
        } else {
            // No label, same rhythm: the box still starts where it would.
            head.heightAnchor.constraint(equalToConstant: top - Theme.m(8)).isActive = true
        }
        add(toColumn: head)
        if label == nil { column.setCustomSpacing(0, after: head) }

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.topAnchor.constraint(equalTo: box.topAnchor),
            rows.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            rows.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        add(toColumn: box)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The mockup's `.gl`: 11 px semibold capitals, 0.06 em apart, faint.
    static func caps(_ s: String, color: NSColor = Theme.faint) -> NSTextField {
        let f = Theme.text("", 11, .semibold, color)
        let font = NSFont.systemFont(ofSize: Theme.m(11), weight: .semibold)
        f.attributedStringValue = NSAttributedString(string: s.uppercased(), attributes: [
            .font: font, .foregroundColor: color, .kern: Theme.m(11) * 0.06,
        ])
        return f
    }

    private func add(toColumn view: NSView) {
        column.addArrangedSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }

    /// A row. Padded rows get the mockup's 8 × 14 px and a 44 px floor, with
    /// the content centred; an unpadded one (a list that pads its own rows)
    /// fills the width edge to edge. Every row after the first carries the
    /// rule above it, so a hidden row takes its rule with it. Returns the
    /// row's host, which is what to hide.
    @discardableResult
    func add(_ view: NSView, padded: Bool = true, vertical: CGFloat = 8) -> NSView {
        let host = RowHost(view, padded: padded, vertical: vertical, rule: rowCount > 0)
        rowCount += 1
        rows.addArrangedSubview(host)
        host.translatesAutoresizingMaskIntoConstraints = false
        host.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        return host
    }

    /// Content that isn't rows — two plan boxes side by side, a caveat on
    /// its own fill — under the same label, in place of the white box.
    func replaceBox(with view: NSView) {
        box.isHidden = true
        add(toColumn: view)
    }

    /// A line under the box: a status, a caveat. Empty ones fold away.
    func foot(_ view: NSView) {
        let host = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: Theme.m(2)),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -Theme.m(2)),
        ])
        // A FootNote hides itself when it has nothing to say; its host has
        // to follow, or the stack keeps a gap where it was.
        if let note = view as? FootNote { note.host = host; host.isHidden = note.isHidden }
        if let last = column.arrangedSubviews.last { column.setCustomSpacing(Theme.m(8), after: last) }
        add(toColumn: host)
    }

    @discardableResult
    func foot(_ text: String, color: NSColor = Theme.muted) -> FootNote {
        let note = FootNote(text, color: color)
        foot(note)
        return note
    }
}

/// The `.grp` container: surface, a hairline, radius 12, no shadow — it
/// sits on the sheet, it doesn't float over it.
final class GroupBox: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(12)
        layer?.borderWidth = 1
        // A hovered row's wash has to stop at the rounded corners.
        layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Theme.surface.cgColor
        layer?.borderColor = Theme.hairline.cgColor
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// One row's frame inside a group, with the soft rule along its top.
private final class RowHost: NSView {
    init(_ content: NSView, padded: Bool, vertical: CGFloat, rule: Bool) {
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        if padded {
            let v = Theme.m(vertical)
            // Centred in at least 44 px, and no taller than the content plus
            // its padding: the low-priority pin is what pulls the row tight.
            let snug = content.topAnchor.constraint(equalTo: topAnchor, constant: v)
            snug.priority = .defaultLow
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(14)),
                content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.m(14)),
                content.centerYAnchor.constraint(equalTo: centerYAnchor),
                content.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: v),
                heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.m(44)),
                snug,
            ])
        } else {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: leadingAnchor),
                content.trailingAnchor.constraint(equalTo: trailingAnchor),
                content.topAnchor.constraint(equalTo: topAnchor),
                content.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
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
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// A wrapping 11.5 px line under a group — a status that comes and goes.
/// It hides itself (and the space it sat in) whenever it is emptied, so the
/// many places that write a status never have to remember to.
final class FootNote: NSTextField {
    fileprivate weak var host: NSView?

    /// The text is not optional: a bare `FootNote()` would reach
    /// NSTextField's own init and come out an editable, bezelled box.
    convenience init(_ text: String, color: NSColor = Theme.muted) {
        self.init(labelWithString: text)
        font = .systemFont(ofSize: Theme.m(11.5))
        textColor = color
        lineBreakMode = .byWordWrapping
        maximumNumberOfLines = 0
        usesSingleLineMode = false
        cell?.wraps = true
        cell?.isScrollable = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.init(200), for: .horizontal)
        isHidden = text.isEmpty
    }

    override var stringValue: String {
        didSet {
            isHidden = stringValue.isEmpty
            host?.isHidden = isHidden
        }
    }

    /// The same measuring WrapLabel does, so a long status wraps to the
    /// width it is drawn at rather than the width it was first given.
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

/// The mockup's `.pop`: the current choice and a chevron on a raised white
/// key — surface, hairline, one-point lip — that opens a menu of the rest.
final class PopButton: NSView {
    private let field: NSTextField
    private let chevron = NSImageView()
    private let titles: [String]
    /// A muted word at each menu item's right edge — a price, a size — when
    /// the choices have one. The button itself shows only the title.
    private let notes: [String]?
    private(set) var index: Int
    var onPick: (Int) -> Void
    var isEnabled = true
    private var hovering = false { didSet { needsDisplay = true } }

    init(_ titles: [String], notes: [String]? = nil, selected: Int = 0, onPick: @escaping (Int) -> Void = { _ in }) {
        self.titles = titles
        self.notes = notes
        self.index = selected
        self.onPick = onPick
        field = Theme.text(titles.indices.contains(selected) ? titles[selected] : "", 12.5, .regular, Theme.ink)
        field.font = .systemFont(ofSize: Theme.m(12.5))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(7)
        layer?.borderWidth = 1
        chevron.image = Theme.symbol("chevron.down", Theme.m(9), .semibold)
        chevron.contentTintColor = Theme.muted
        let row = Theme.hstack([field, chevron], spacing: Theme.m(8))
        // As wide as the choice showing, like the mockup's inline popup —
        // never the width of whatever slack the row has.
        row.setHuggingPriority(.required, for: .horizontal)
        field.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(10)),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.m(8)),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Theme.m(26)),
        ])
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.popUpButton)
        setAccessibilityValue(field.stringValue)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Move the selection without calling back — for following a change
    /// made somewhere else.
    func setIndex(_ i: Int) {
        guard titles.indices.contains(i) else { return }
        index = i
        field.stringValue = titles[i]
        setAccessibilityValue(titles[i])
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let menu = NSMenu()
        let font = NSFont.menuFont(ofSize: 0)
        // The notes line up on one right edge, past the widest title.
        let widest = titles.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let noteWidth = (notes ?? []).map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        let tab = NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle
        tab.tabStops = [NSTextTab(textAlignment: .right, location: ceil(widest + Theme.m(28) + noteWidth))]
        for (i, t) in titles.enumerated() {
            let item = NSMenuItem(title: t, action: #selector(picked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = i == index ? .on : .off
            if let notes = notes, notes.indices.contains(i) {
                let line = NSMutableAttributedString(string: t, attributes: [.font: font, .paragraphStyle: tab])
                line.append(NSAttributedString(string: "\t" + notes[i], attributes: [
                    .font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: tab]))
                item.attributedTitle = line
            }
            menu.addItem(item)
        }
        // The current choice opens over the button, where a Mac popup puts it.
        menu.popUp(positioning: menu.item(at: index), at: NSPoint(x: Theme.m(2), y: bounds.height - Theme.m(4)), in: self)
    }
    @objc private func picked(_ item: NSMenuItem) {
        guard item.tag != index else { return }
        setIndex(item.tag)
        onPick(item.tag)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override var mouseDownCanMoveWindow: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = (hovering && isEnabled ? Theme.wellFill : Theme.surface).cgColor
        layer?.borderColor = Theme.hairline.cgColor
        Theme.lip(layer)
        chevron.contentTintColor = Theme.muted
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// A text field that says when it takes the focus, so the box around it can
/// light its ring the moment it is clicked rather than at the first key.
final class FocusField: NSTextField {
    var onFocus: (Bool) -> Void = { _ in }
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus(true) }
        return ok
    }
    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocus(false)
    }
}

/// The same, for a key.
final class FocusSecureField: NSSecureTextField {
    var onFocus: (Bool) -> Void = { _ in }
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus(true) }
        return ok
    }
    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        onFocus(false)
    }
}

/// The mockup's `.field`: a flat white box, a hairline, radius 8. Focused,
/// the hairline turns ember with a soft ember halo outside it — the one
/// focus ring used everywhere. The field inside loses its own bezel.
final class FieldBox: NSView {
    private let halo = CALayer()
    private var focused = false { didSet { if focused != oldValue { needsDisplay = true } } }

    /// With a field, it is pinned inside at the mockup's 10 px and the box
    /// is 30 px tall; without one (or `height: nil`) the caller lays out.
    init(_ field: NSTextField? = nil, height: CGFloat? = 30) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(8)
        layer?.borderWidth = 1
        layer?.masksToBounds = false
        halo.cornerRadius = Theme.m(8) + Theme.m(3)
        halo.borderWidth = Theme.m(3)
        halo.isHidden = true
        layer?.addSublayer(halo)
        if let height = height {
            heightAnchor.constraint(equalToConstant: Theme.m(height)).isActive = true
        }
        if let field = field {
            watch(field)
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(10) - 2),
                field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.m(10) + 2),
                field.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        setContentHuggingPriority(.init(1), for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Strips a field down to its text and follows its focus.
    func watch(_ field: NSTextField) {
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = Theme.ink
        if let placeholder = field.placeholderString {
            field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
                .font: field.font ?? .systemFont(ofSize: Theme.m(13)), .foregroundColor: Theme.faint,
            ])
        }
        if let f = field as? FocusField { f.onFocus = { [weak self] on in self?.focused = on } }
        if let f = field as? FocusSecureField { f.onFocus = { [weak self] on in self?.focused = on } }
        // Called again when a placeholder changes, so it drops what it had.
        let nc = NotificationCenter.default
        nc.removeObserver(self, name: NSControl.textDidBeginEditingNotification, object: field)
        nc.removeObserver(self, name: NSControl.textDidEndEditingNotification, object: field)
        nc.addObserver(self, selector: #selector(began), name: NSControl.textDidBeginEditingNotification, object: field)
        nc.addObserver(self, selector: #selector(ended), name: NSControl.textDidEndEditingNotification, object: field)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func began() { focused = true }
    @objc private func ended() { focused = false }

    override func layout() {
        super.layout()
        let out = Theme.m(3)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        halo.frame = bounds.insetBy(dx: -out, dy: -out)
        CATransaction.commit()
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Theme.surface.cgColor
        layer?.borderColor = (focused ? Theme.ember : Theme.hairline).cgColor
        halo.borderColor = Theme.emberSoft.cgColor
        halo.isHidden = !focused
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// The top of Permissions: how many of the grants dictation needs are on,
/// and — when one isn't — what that costs, in one line. The row of ticks on
/// the right is the same count as a picture: moss for on, amber for not.
final class GrantSummary: NSView {
    private let tile = IconTile("lock.shield", .blue, side: 40, icon: 19)
    private let title: NSTextField
    private let line: NSTextField
    private let ticks = GrantTicks()
    private var shown = ""

    init() {
        title = Theme.text(" ", 15, .medium)
        title.font = .systemFont(ofSize: Theme.m(15), weight: .medium)
        line = RowText.help(" ")
        super.init(frame: .zero)
        let words = Theme.vstack([title, line], spacing: Theme.m(3))
        line.widthAnchor.constraint(equalTo: words.widthAnchor).isActive = true
        words.setHuggingPriority(.init(1), for: .horizontal)
        let left = Theme.hstack([tile, words], spacing: Theme.m(14))
        left.distribution = .fill
        RowText.layout(left, ticks, into: self)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Each grant's name, whether it is on, and the sentence for when it
    /// is the only one missing. Called on every poll; redraws on a change.
    func update(_ items: [(name: String, on: Bool, cost: String)]) {
        let missing = items.filter { !$0.on }
        let sig = items.map { $0.on ? "1" : "0" }.joined()
        guard sig != shown else { return }
        shown = sig
        ticks.states = items.map(\.on)
        if missing.isEmpty {
            title.stringValue = "Ready to dictate"
            RowText.setHelp(line, "Everything dictation needs is allowed.")
            tile.setSymbol("checkmark.shield", icon: 19)
        } else {
            title.stringValue = "\(items.count - missing.count) of \(items.count) ready"
            let names = missing.map(\.name)
            RowText.setHelp(line, missing.count == 1 ? missing[0].cost
                : "Still needed: " + names.dropLast().joined(separator: ", ") + " and " + names.last!)
            tile.setSymbol("lock.shield", icon: 19)
        }
    }
}

/// One short capsule per grant, side by side.
private final class GrantTicks: NSView {
    var states: [Bool] = [] { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    private let w = Theme.m(16), h = Theme.m(6), gap = Theme.m(4)

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(states.count) * w + CGFloat(max(0, states.count - 1)) * gap, height: h)
    }
    override func draw(_ dirtyRect: NSRect) {
        for (i, on) in states.enumerated() {
            let r = NSRect(x: CGFloat(i) * (w + gap), y: (bounds.height - h) / 2, width: w, height: h)
            (on ? Theme.moss : Theme.amber).setFill()
            NSBezierPath(roundedRect: r, xRadius: h / 2, yRadius: h / 2).fill()
        }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// One promise on Privacy: a tile, a short headline, one line under it — a
/// card of its own, so three sit side by side and read as pictures rather
/// than a paragraph. The fine print is the card's tooltip.
final class PromiseCard: NSView {
    private let tile: IconTile
    private let title: NSTextField
    private let line: NSTextField

    init(_ symbol: String = "lock.fill", _ hue: Theme.Hue = .green, _ title: String = " ", _ line: String = " ",
         tip: String? = nil) {
        tile = IconTile(symbol, hue, side: 32, icon: 15)
        self.title = Theme.para(title, 13 * 1.2, .medium, Theme.ink, lineHeight: 1.1)
        self.line = RowText.help(line)
        super.init(frame: .zero)
        GroupBox().fill(self)
        let column = Theme.vstack([tile, self.title, self.line], spacing: Theme.m(3))
        column.setCustomSpacing(Theme.m(9), after: tile)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        let pad = Theme.m(14)
        // As short as the words allow; the row then evens the three out.
        let snug = heightAnchor.constraint(equalToConstant: 0)
        snug.priority = .init(1)
        NSLayoutConstraint.activate([
            snug,
            column.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            column.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -pad),
            self.title.widthAnchor.constraint(equalTo: column.widthAnchor),
            self.line.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
        toolTip = tip
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ symbol: String, _ hue: Theme.Hue, _ title: String, _ line: String, tip: String? = nil) {
        tile.setSymbol(symbol, icon: 15)
        tile.hue = hue
        Theme.setDisplay(self.title, title)
        RowText.setHelp(self.line, line)
        toolTip = tip
    }
}

/// A scrolling column of groups for one section: the sheet's 24 px sides,
/// and the 8 px rhythm between groups that the mockup's grid gap sets.
func makeSheetScroll(_ views: [NSView]) -> NSScrollView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = Theme.m(8)
    stack.translatesAutoresizingMaskIntoConstraints = false

    let doc = FlippedView()
    doc.translatesAutoresizingMaskIntoConstraints = false
    doc.addSubview(stack)
    NSLayoutConstraint.activate([
        stack.topAnchor.constraint(equalTo: doc.topAnchor),
        stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: Theme.m(24)),
        stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -Theme.m(24)),
        stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -Theme.m(22)),
    ])
    for v in views {
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
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
