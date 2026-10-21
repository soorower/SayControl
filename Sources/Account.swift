// The account button in the corner of the window, and the popover behind it.
//
// The account lives on api.saycontrol.com (Cloud.swift): signing in is with
// Google or with an address and a password, the plan and what is left of it
// are the server's. What is kept
// here is a cache of the name, address and plan, so the screens draw before
// the network answers.
import Cocoa

enum Account {
    /// Whether the account screens show. On in both builds since accounts
    /// launched for users (2026-10-03): the sign-in is the way in, and the
    /// plan does the listening. SAYCTRL_ACCOUNTS=0 shows a build without
    /// them, the way the shipping app looked before.
    static let available: Bool = {
        if let v = ProcessInfo.processInfo.environment["SAYCTRL_ACCOUNTS"] { return v == "1" }
        return true
    }()

    /// Accounts are on and nobody is signed in: the app does nothing until
    /// someone does — no dictation, no main window, just the sign-in.
    static var required: Bool {
        available && !signedIn && !Onboarding.demo
            && !CommandLine.arguments.contains { ["--snapshot", "--windowshot", "--onboardingshot", "--cloudtest"].contains($0) }
    }

    /// The first-run window's welcome, which is the sign-in.
    static func askToSignIn() {
        if OnboardingWindow.shared.isVisible { return NSApp.activate(ignoringOtherApps: true) }
        OnboardingWindow.shared.present(at: 0)
    }

    /// Snapshots draw the signed-in and signed-out screens without touching
    /// the real account: signing out for a picture would revoke it.
    static var preview: Bool?

    static var signedIn: Bool { preview ?? Cloud.shared.signedIn }

    /// The name the account was made with (Google's, or the one typed at
    /// sign-up), else the Mac's.
    static var name: String { Config.shared.env()["ACCOUNT_NAME"] ?? NSFullUserName() }
    static var email: String { Config.shared.env()["ACCOUNT_EMAIL"] ?? "" }
    /// Signed in with an address and a password rather than Google.
    static var withPassword: Bool { Config.shared.env()["ACCOUNT_VIA"] == "password" }

    /// "free" or "pro". Pro is a subscription.
    static var plan: String { Config.shared.env()["ACCOUNT_PLAN"] == "pro" ? "pro" : "free" }

    /// Command mode, spoken controls (screenshots, files, links, terminal,
    /// open) and Ask ChatGPT/Claude/Grok/Perplexity are Pro's since
    /// 2026-10-03; dictation, cleanup, tones, the dictionary and phrases stay
    /// on Free. A build with no accounts — a developer's own keys — keeps
    /// them all. The server refuses Free's command mode too: this is the
    /// app saying so first.
    static var proFeatures: Bool { !available || plan == "pro" }

    /// Pro is what the cloud sells, so off it nothing is locked (owner,
    /// 2026-10-22): words heard on this Mac or by a provider on your own key
    /// get the spoken controls and Ask whatever the plan.
    static var controlsFree: Bool { proFeatures || !Config.shared.cloudOn }
    /// Command mode is a polish call, so it is free when that call goes to
    /// your own key: a take off the cloud, or polish set to your key.
    static var commandModeFree: Bool { proFeatures || !(Config.shared.cloudOn && Config.shared.modelsViaCloud) }

    /// The plans as the server serves them (SayCtrl-Cloud src/plans.ts). The
    /// usage the server reports carries its own limits; these are for the
    /// screens that describe a plan you are not on.
    static let proDollarsPerMonth = 12
    static let freeWordsPerWeek = 2_000
    static let proHoursPerMonth = 30

    /// What the server last said is left, or nil before it has answered.
    static var usage: CloudUsage? { Cloud.shared.usage }

    static func signInWithGoogle(then done: ((Bool) -> Void)? = nil) {
        Cloud.shared.signIn { result in
            switch result {
            case .success:
                done?(true)
            case .failure(.cancelled):
                done?(false)
            case .failure(let error):
                Config.shared.log("Cloud: sign-in failed — \(error.localizedDescription)")
                AppAlerts.shared.post(AppAlert(id: "signin", title: "Couldn't sign in",
                                               message: Self.signInProblem(error), severe: false))
                done?(false)
            }
        }
    }

    private static func signInProblem(_ error: CloudError) -> String {
        if case .server(_, let code) = error {
            switch code {
            case "sign_in_unavailable": return "Signing in with Google isn't switched on yet. Everything on this Mac keeps working."
            case "browser_failed": return "The browser didn't open. Try again, or sign in with your email."
            case "invalid_grant": return "That sign-in link had expired. Try again."
            default: break
            }
        }
        return problemLine(error)
    }

    /// A failed sign-in, said the way a person would.
    static func problemLine(_ error: CloudError) -> String {
        switch error {
        case .transport: return "Couldn't reach SayControl. Check your connection and try again."
        case .server(_, let code):
            switch code {
            case "wrong_password": return "That password isn't right."
            case "weak_password": return "Use at least 8 characters."
            case "invalid_email": return "That address doesn't look right."
            case "invalid_name": return "Add your name."
            case "rate_limited": return "Too many tries. Wait a minute, then try again."
            case "use_google": return "This address signs in with Google."
            case "wrong_code": return "That code isn't right. Check the email and try again."
            case "code_expired": return "That code has run out. Send a new one."
            case "too_many_codes": return "That's all the codes for today. Try again tomorrow, or write to \(HelpPane.supportEmail)."
            case "email_failed": return "We couldn't send the email just now. Try again in a moment."
            case "pro_active": return "Your Pro plan is still on. Cancel it first, or write to \(HelpPane.supportEmail)."
            default: return "Something went wrong on our side (\(code)). Try again."
            }
        default: return error.localizedDescription
        }
    }

    static func signOut() {
        Cloud.shared.signOut()
    }

    // MARK: Paying

    /// Upgrade: Paddle's checkout in the browser. The plan turns Pro when
    /// Paddle tells our server, and the app picks it up on the way back.
    static func upgrade() {
        guard signedIn else { return askToSignIn() }
        SettingsUI.shared.toast("Opening the checkout in your browser…")
        Cloud.shared.openCheckout { result in
            guard case .failure(let error) = result else { return }
            if case .server(_, "already_pro") = error {
                Cloud.shared.refreshAccount()
                return SettingsUI.shared.toast("You're already on Pro")
            }
            Config.shared.log("Cloud: checkout failed — \(error.localizedDescription)")
            AppAlerts.shared.post(AppAlert(id: "billing", title: "The checkout didn't open",
                                           message: billingProblem(error), severe: false))
        }
    }

    /// More agent conversations — one of the amounts on sale — through
    /// Paddle's checkout, on Pro. The count grows when Paddle tells our
    /// server it's paid, and the app picks it up on the way back.
    static func buyAgentPack(conversations: Int) {
        guard signedIn else { return askToSignIn() }
        SettingsUI.shared.toast("Opening the checkout in your browser…")
        Cloud.shared.openCheckout(.agentPack, conversations: conversations) { result in
            guard case .failure(let error) = result else { return }
            if case .limitReached = error {
                Cloud.shared.refreshAccount()
                return SettingsUI.shared.toast("Packs of agent conversations come with Pro")
            }
            Config.shared.log("Cloud: pack checkout failed — \(error.localizedDescription)")
            AppAlerts.shared.post(AppAlert(id: "billing", title: "The checkout didn't open",
                                           message: billingProblem(error), severe: false))
        }
    }

    /// Manage: Paddle's portal, to cancel, change the card or get a receipt.
    static func manageBilling() {
        Cloud.shared.openPortal { result in
            guard case .failure(let error) = result else { return }
            Config.shared.log("Cloud: billing portal failed — \(error.localizedDescription)")
            AppAlerts.shared.post(AppAlert(id: "billing", title: "Billing didn't open",
                                           message: billingProblem(error), severe: false))
        }
    }

    private static func billingProblem(_ error: CloudError) -> String {
        if case .server(_, let code) = error {
            switch code {
            case "no_subscription": return "There's no subscription on this account yet."
            case "billing_unavailable": return "Our payment provider didn't answer. Nothing was charged; try again in a minute."
            case "browser_failed": return "The browser didn't open. Try again."
            default: break
            }
        }
        return problemLine(error)
    }


    /// "1,640 of 2,000 words this week" — the meter's line for the plan you are on.
    static var usageLine: String {
        // A user's Pro is unlimited: the fair-use ceiling is the server's
        // business, and a meter creeping towards it reads as a quota.
        if Config.retail && plan == "pro" { return "Unlimited dictation" }
        guard let u = usage else { return plan == "pro" ? "Pro" : "\(grouped(freeWordsPerWeek)) words a week" }
        if u.plan == "pro", let limit = u.speechMs.limit {
            let used = Double(u.speechMs.used) / 3_600_000
            return String(format: "%.1f of %d hours this month", min(used, Double(limit) / 3_600_000), limit / 3_600_000)
        }
        if let limit = u.words.limit {
            // The take that crosses the line finishes its sentence, so used
            // can land a few words past the limit.
            return "\(grouped(min(u.words.used, limit))) of \(grouped(limit)) words this week"
        }
        return u.plan == "pro" ? "Pro" : "Free"
    }

    /// How full the plan is, 0…1, for the meter.
    static var usageFraction: Double {
        guard let u = usage else { return 0 }
        if Config.retail && u.plan == "pro" { return 0 }
        return u.plan == "pro" ? u.speechMs.fraction : u.words.fraction
    }

    /// When the allowance comes back: "resets Monday", "resets Oct 1".
    static var resetsLine: String {
        guard let u = usage else { return plan == "pro" ? "resets monthly" : "resets weekly" }
        let f = DateFormatter()
        f.dateFormat = u.period == "week" ? "EEEE" : "MMM d"
        return "resets \(f.string(from: u.resetsAt))"
    }

    /// "1,640 words left" for the sidebar, nil when there's nothing to say.
    static var leftLine: String? {
        guard let u = usage else { return nil }
        if u.plan == "pro" { return nil }
        return u.words.left.map { "\(grouped($0)) words left" }
    }

    static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    // MARK: Examples that are the user's own

    /// The address the demos write out. Signed in, it is the account's; before
    /// that, the Mac's login name at SayControl's own domain — so a stranger's
    /// copy never shows anyone else's address, and yours shows yours.
    static var exampleEmail: String {
        if signedIn, !email.isEmpty { return email }
        let user = NSUserName().lowercased().filter { $0.isLetter || $0.isNumber || $0 == "." }
        return "\(user.isEmpty ? "you" : user)@saycontrol.com"
    }

    /// The same address as it would be dictated: "jane at saycontrol dot com".
    static var spokenExampleEmail: String {
        exampleEmail.replacingOccurrences(of: "@", with: " at ").replacingOccurrences(of: ".", with: " dot ")
    }

    /// First name, for demos that talk to the user: the account's, else the
    /// Mac's.
    static var firstName: String {
        name.split(separator: " ").first.map(String.init) ?? "you"
    }

    /// The Google account's photo, nil for an address account or until it
    /// has downloaded (AccountPhoto).
    static var photo: NSImage? { signedIn ? AccountPhoto.image : nil }

    static var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first.map(String.init) }
        return letters.isEmpty ? "?" : letters.joined().uppercased()
    }

    static var planLabel: String { plan == "pro" ? "Pro" : "Free" }
}

// MARK: - The photo

/// A Google account's photo: downloaded once from Google's own image host,
/// kept in a file beside the settings (so it draws at once on the next
/// launch), and dropped at sign-out. Address accounts have none, and show
/// their initials.
enum AccountPhoto {
    private static var file: URL { Config.shared.dir.appendingPathComponent("account-photo") }
    private static var loaded: NSImage??

    static var image: NSImage? {
        if let loaded = loaded { return loaded }
        let image = (try? Data(contentsOf: file)).flatMap(NSImage.init(data:))
        loaded = .some(image)
        return image
    }

    /// Only ever Google's image host, over https: the address came from our
    /// server, and the app must not be sent anywhere else by it.
    static func acceptable(_ url: URL) -> Bool {
        url.scheme == "https" && (url.host ?? "").hasSuffix(".googleusercontent.com")
    }

    /// The account's photo address as the server gave it (nil: none).
    /// Downloads when it changed or the file is missing.
    static func update(to address: String?) {
        let was = Config.shared.env()["ACCOUNT_AVATAR"]
        guard let address = address, let url = URL(string: address), acceptable(url) else {
            if was != nil || loaded != nil { clear() }
            return
        }
        guard address != was || image == nil else { return }
        Config.shared.set("ACCOUNT_AVATAR", address)
        // Google serves any size by the suffix; the icons are at most 40 pt,
        // so 128 px covers a 2x screen at 64.
        let sized = address.replacingOccurrences(of: #"=s\d+(-c)?$"#, with: "=s128-c", options: .regularExpression)
        var request = URLRequest(url: URL(string: sized) ?? url, timeoutInterval: 15)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, _ in
            guard let data = data, data.count < 2_000_000,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                // Signed out, or a newer photo, while this was on its way.
                guard Cloud.shared.signedIn, Config.shared.env()["ACCOUNT_AVATAR"] == address else { return }
                if !FileManager.default.fileExists(atPath: file.path) {
                    FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
                }
                try? data.write(to: file)
                loaded = .some(image)
                NotificationCenter.default.post(name: .sayctrlAccountChanged, object: nil)
            }
        }.resume()
    }

    static func clear() {
        try? FileManager.default.removeItem(at: file)
        loaded = .some(nil)
        Config.shared.set("ACCOUNT_AVATAR", nil)
    }
}

/// The photo in its round, laid over the initials; hidden when there is none.
final class AccountPhotoView: NSImageView {
    /// Pinned to fill `disc`, whose round it takes.
    init(in disc: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        imageScaling = .scaleProportionallyUpOrDown
        translatesAutoresizingMaskIntoConstraints = false
        disc.addSubview(self)
        NSLayoutConstraint.activate([
            topAnchor.constraint(equalTo: disc.topAnchor),
            bottomAnchor.constraint(equalTo: disc.bottomAnchor),
            leadingAnchor.constraint(equalTo: disc.leadingAnchor),
            trailingAnchor.constraint(equalTo: disc.trailingAnchor),
        ])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Whether there is a photo to show.
    @discardableResult
    func refresh() -> Bool {
        image = Account.photo
        isHidden = image == nil
        return !isHidden
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.width / 2
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - The button

/// The refresh's `.av`: your initials in the page colour on a round of ink,
/// or a person in a sunk well when nobody is signed in. Ink, not ember — an
/// avatar is you, not something live.
final class AvatarButton: NSView {
    private let field: NSTextField
    private let icon = NSImageView()
    private var photo: AccountPhotoView!
    private var hovering = false { didSet { needsDisplay = true } }
    var onClick: () -> Void = {}

    init(size: CGFloat = 32) {
        field = Theme.text(Account.initials, 12.5, .semibold, Theme.paper)
        super.init(frame: .zero)
        wantsLayer = true
        let side = Theme.px(size)
        // The mockup's 11 px on a 28 px round, at whatever size this is.
        field.font = .systemFont(ofSize: (side * 0.39).rounded(), weight: .semibold)
        layer?.cornerRadius = side / 2
        layer?.borderWidth = 1
        toolTip = "Account"

        icon.image = Theme.symbol("person", Theme.px(size * 0.46), .regular)
        for v in [field, icon] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
            NSLayoutConstraint.activate([
                v.centerXAnchor.constraint(equalTo: centerXAnchor),
                v.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
        ])
        photo = AccountPhotoView(in: self)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        field.stringValue = Account.initials
        field.isHidden = !Account.signedIn || photo.refresh()
        icon.isHidden = Account.signedIn
        icon.contentTintColor = Theme.muted
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onClick() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override var mouseDownCanMoveWindow: Bool { false }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        field.textColor = Theme.paper
        if Account.signedIn {
            layer?.backgroundColor = (hovering ? Theme.ink2 : Theme.ink).cgColor
            layer?.borderColor = NSColor.clear.cgColor
        } else {
            layer?.backgroundColor = (hovering ? Theme.navPick : Theme.wellFill).cgColor
            layer?.borderColor = Theme.hairline.cgColor
        }
        // It sits on the page; it doesn't float.
        layer?.shadowOpacity = 0
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: - The usage meter, shared with Billing

/// "1,640 of 2,000 words this week" over a thin bar — lit in ink like a meter
/// column that isn't today's, since nothing about a balance is live. Turns
/// amber when the balance is nearly gone.
final class UsageMeter: NSView {
    private let bar = ColorView(color: Theme.barFill, radius: Theme.m(3))
    private let fill = ColorView(color: Theme.barLit, radius: Theme.m(3))
    private var fillWidth: NSLayoutConstraint!
    private let left: NSTextField
    private let right: NSTextField

    init(left: String, right: String, fraction: Double, low: Bool = false) {
        self.left = Theme.text(left, 13, .medium)
        self.left.font = Theme.digits(13, .medium)
        self.right = Theme.meta(right, 11.5)
        super.init(frame: .zero)

        let line = Theme.hstack([self.left, Theme.spacer(), self.right], spacing: Theme.m(8))
        line.alignment = .firstBaseline
        for v in [line, bar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        fill.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(fill)
        fillWidth = fill.widthAnchor.constraint(equalTo: bar.widthAnchor,
                                                multiplier: max(0.001, min(1, fraction)))
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: topAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),

            bar.topAnchor.constraint(equalTo: line.bottomAnchor, constant: Theme.m(8)),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: Theme.m(6)),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor),

            fill.topAnchor.constraint(equalTo: bar.topAnchor),
            fill.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            fill.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            fillWidth,
        ])
        // Through `color`: a ColorView repaints its own colour at the next
        // display, and one written to the layer is gone by then.
        if low { fill.color = Theme.amber }
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - The popover

final class AccountPopover: FloatingPanel {
    var onDismiss: () -> Void = {}
    /// Ask the shell to switch panes — "Plan & billing", "Help".
    var onGoTo: (String) -> Void = { _ in }

    /// The sidebar's padding and corners: the popover is one of the things
    /// that float, drawn like the panel it opens from.
    init() {
        super.init(padding: Theme.m(10), radius: Theme.m(12),
                   spacing: 0, alignment: .leading, style: .popover)
        Account.signedIn ? buildSignedIn() : buildSignedOut()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildSignedOut() {
        guard Account.available else {
            add(inset(Theme.para("Accounts and cloud plans arrive with an update. Until then everything runs on this Mac, free.",
                                 12.5 * 1.2, .regular, Theme.muted, lineHeight: 1.3)))
            return
        }
        add(inset(Theme.para("Sign in for cloud dictation: 2,000 free words a week, or Pro. Your dictionary and phrases stay on this Mac either way.",
                             12.5 * 1.2, .regular, Theme.muted, lineHeight: 1.3)))
        let go = GoogleSignInButton { [weak self] in
            self?.onDismiss()
            Account.signInWithGoogle()
        }
        add(go)
        // Typing an address and a password wants a real window, not a popover.
        add(inset(FlatButton("Sign in with email", .quiet) { [weak self] in
            self?.onDismiss()
            self?.onGoTo("settings")
            NotificationCenter.default.post(name: .sayctrlOpenSettingsTab, object: "account")
        }, vertical: 0))
        body.setCustomSpacing(Theme.m(8), after: body.arrangedSubviews[0])
        body.setCustomSpacing(Theme.m(4), after: go)
    }

    private func buildSignedIn() {
        let av = AvatarButton(size: 32)
        let name = Theme.text(Account.name, 13, .medium)
        name.font = .systemFont(ofSize: Theme.m(13), weight: .medium)
        let email = Theme.text(Account.email.isEmpty ? "Signed in on this Mac" : Account.email, 11.5, .regular, Theme.muted)
        email.font = .systemFont(ofSize: Theme.m(11.5))
        let who = Theme.hstack([av, Theme.vstack([name, email], spacing: Theme.m(1))], spacing: Theme.m(10))
        add(inset(who))

        // Free sees its week and the way up; Pro has nothing to count, and
        // the menu is no place to sell it what it already has.
        if Account.plan != "pro" {
            add(rule())
            let meter = UsageMeter(left: Account.usageLine, right: Account.planLabel,
                                   fraction: Account.usageFraction, low: Account.usageFraction >= 0.9)
            add(inset(meter))
            let upgrade = FlatButton("Upgrade to Pro — $\(Account.proDollarsPerMonth) a month", .primary) { [weak self] in
                self?.onDismiss()
                Account.upgrade()
            }
            add(inset(upgrade, vertical: 0))
            body.setCustomSpacing(Theme.m(6), after: body.arrangedSubviews[body.arrangedSubviews.count - 2])
        }

        add(rule())
        add(menuRow("person", "Account") { [weak self] in
            self?.onGoTo("settings")
            NotificationCenter.default.post(name: .sayctrlOpenSettingsTab, object: "account")
        })
        add(menuRow("creditcard", Config.retail ? "Plans" : "Plan & billing") { [weak self] in
            self?.onGoTo("settings")
            NotificationCenter.default.post(name: .sayctrlOpenSettingsTab, object: "billing")
        })
        add(menuRow("lightbulb", "How it works") { [weak self] in self?.onGoTo("commands") })
        add(menuRow("questionmark.circle", "Help") { [weak self] in self?.onGoTo("help") })
        add(menuRow("rectangle.portrait.and.arrow.right", "Sign out", danger: true) { [weak self] in
            self?.onDismiss()
            Account.signOut()
        })
    }

    /// Text lined up with the menu rows' icons: the rows' own 10 px in.
    private func inset(_ view: NSView, vertical: CGFloat = 6) -> NSView {
        let host = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor, constant: Theme.m(vertical)),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -Theme.m(vertical)),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: Theme.m(10)),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -Theme.m(10)),
        ])
        return host
    }

    /// The popover's group separator: a hairline with the group's padding
    /// baked into the space around it.
    private func rule() -> NSView {
        let host = NSView()
        let r = ColorView(color: Theme.hairsoft)
        r.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(r)
        NSLayoutConstraint.activate([
            r.heightAnchor.constraint(equalToConstant: 1),
            r.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: Theme.m(4)),
            r.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -Theme.m(4)),
            r.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            host.heightAnchor.constraint(equalToConstant: Theme.m(13)),
        ])
        return host
    }

    private func menuRow(_ symbol: String, _ label: String,
                         danger: Bool = false, action: @escaping () -> Void) -> NSView {
        MenuRow(symbol: symbol, label: label, danger: danger, action: action)
    }
}

/// One line in the account popover, drawn like a sidebar row: 30 px, radius
/// 8, a wash on hover. Sign out goes red on hover — red means gone.
final class MenuRow: NSView {
    private let field: NSTextField
    private let icon = NSImageView()
    private let danger: Bool
    private var hovering = false { didSet { needsDisplay = true } }
    private let action: () -> Void

    init(symbol: String, label: String, danger: Bool, action: @escaping () -> Void) {
        self.danger = danger
        self.action = action
        field = Theme.text(label, 13, .medium, Theme.muted)
        field.font = .systemFont(ofSize: Theme.m(13), weight: .medium)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(8)

        icon.image = Theme.symbol(symbol, Theme.m(13), .regular)
        icon.contentTintColor = Theme.muted
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: Theme.m(17)).isActive = true

        let row = Theme.hstack([icon, field], spacing: Theme.m(10))
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(10)),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Theme.m(8)),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Theme.m(30)),
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
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override var mouseDownCanMoveWindow: Bool { false }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = (hovering ? Theme.navHover : .clear).cgColor
        let fg = hovering ? (danger ? Theme.danger : Theme.ink) : Theme.muted
        field.textColor = fg
        icon.contentTintColor = fg
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

extension Notification.Name {
    /// Signed in or out — the avatar and the Account tab both redraw.
    static let sayctrlAccountChanged = Notification.Name("sayctrlAccountChanged")
    /// Object is the tab key ("billing", "account", …).
    static let sayctrlOpenSettingsTab = Notification.Name("sayctrlOpenSettingsTab")
}
