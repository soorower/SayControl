// The ways in: "Continue with Google", which opens saycontrol.com in the
// browser (Account.signInWithGoogle → Cloud.signIn), and the email form
// under it, which signs in or makes an account without leaving the app.
import Cocoa

// MARK: - The Google mark

/// The four-colour "G", drawn rather than shipped: a ring in four arcs and the
/// bar across the middle. Same at 18 px as at 40.
final class GoogleMark: NSView {
    init(size: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let side = min(bounds.width, bounds.height)
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let outer = side / 2
        let stroke = side * 0.21
        let inner = outer - stroke

        func arc(_ from: CGFloat, _ to: CGFloat, _ color: NSColor) {
            let p = NSBezierPath()
            p.appendArc(withCenter: c, radius: outer, startAngle: from, endAngle: to, clockwise: false)
            p.appendArc(withCenter: c, radius: inner, startAngle: to, endAngle: from, clockwise: true)
            p.close()
            color.setFill()
            p.fill()
        }
        // Red over the top, yellow down the left, green along the bottom, blue
        // up the right — and the blue bar from the middle out to the edge.
        arc(45, 180, Theme.hex(0xEA4335))
        arc(180, 240, Theme.hex(0xFBBC05))
        arc(240, 330, Theme.hex(0x34A853))
        arc(330, 360, Theme.hex(0x4285F4))
        let bar = NSRect(x: c.x, y: c.y - stroke / 2, width: outer, height: stroke)
        Theme.hex(0x4285F4).setFill()
        bar.fill()
    }
}

// MARK: - The button

/// "Continue with Google": white, hairline, the mark on the left. The shape
/// every sign-in page has, so nobody has to work out what it does.
final class GoogleSignInButton: NSView {
    private var hovering = false { didSet { needsDisplay = true } }
    var onClick: () -> Void = {}
    /// The first-run window's way in: ink filled, the G on a white disc.
    private let dark: Bool

    init(_ title: String = "Continue with Google", dark: Bool = false, onClick: @escaping () -> Void = {}) {
        self.onClick = onClick
        self.dark = dark
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(dark ? 9 : 8)
        layer?.borderWidth = dark ? 0 : 1

        // The refresh's secondary button, a size up: surface, hairline and
        // the one-point lip, the mark where an icon would go.
        let mark = GoogleMark(size: Theme.m(15))
        let label = Theme.text(title, 13, .medium, dark ? Theme.paper : Theme.ink)
        label.font = .systemFont(ofSize: Theme.m(dark ? 13.5 : 13), weight: .medium)
        var lead: NSView = mark
        if dark {
            let disc = ColorView(color: .white)
            disc.wantsLayer = true
            disc.layer?.cornerRadius = Theme.m(9)
            disc.translatesAutoresizingMaskIntoConstraints = false
            disc.addSubview(mark)
            NSLayoutConstraint.activate([
                disc.widthAnchor.constraint(equalToConstant: Theme.m(18)),
                disc.heightAnchor.constraint(equalToConstant: Theme.m(18)),
                mark.centerXAnchor.constraint(equalTo: disc.centerXAnchor),
                mark.centerYAnchor.constraint(equalTo: disc.centerYAnchor),
            ])
            lead = disc
        }
        let row = Theme.hstack([lead, label], spacing: Theme.m(9))
        row.setHuggingPriority(.required, for: .horizontal)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: centerXAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Theme.m(14)),
            heightAnchor.constraint(equalToConstant: Theme.m(dark ? 40 : 34)),
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
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override var mouseDownCanMoveWindow: Bool { false }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        if dark {
            layer?.backgroundColor = (hovering ? Theme.ink2 : Theme.ink).cgColor
            return
        }
        layer?.backgroundColor = (hovering ? Theme.wellFill : Theme.surface).cgColor
        layer?.borderColor = Theme.hairline.cgColor
        Theme.lip(layer)
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: - The email form

/// "or", then one box for an address. Continue asks the server whether the
/// address has an account: a new one grows a Full name and a Password box and
/// becomes "Create account"; a known one grows a Password box and becomes
/// "Sign in"; a Google one says so and hands over to Google. Editing the
/// address folds it back. Return in any box presses the button.
///
/// "Forgot password?" under a known address's Password box mails a 6-digit
/// code: the form grows a Code box, then, once the code checks out, a New
/// password box, and setting it signs in (every other Mac is signed out).
final class EmailSignInForm: NSView, NSTextFieldDelegate {
    private enum Mode { case address, signUp, logIn, google, code, newPassword }
    private var mode = Mode.address
    /// A request is out: the button dims and says what is happening, the
    /// links go quiet, and nothing is sent twice.
    private var busy = false {
        didSet {
            button.isEnabled = !busy
            for l in [forgotLink, resendLink, backLink] { l?.isEnabled = !busy }
            if !busy {
                button.title = title(for: mode)
                forgotLink?.title = "Forgot password?"
                resendLink?.title = "Send a new code"
            }
        }
    }

    /// Starts a request: busy, with the button saying what it is doing.
    private func working(_ doing: String) {
        busy = true
        button.title = doing
        say(nil)
    }

    private let email = FocusField()
    private let name = FocusField()
    private let code = FocusField()
    private let password = FocusSecureField()
    private let nameBox: FieldBox
    private let codeBox: FieldBox
    private let passwordBox: FieldBox
    private var forgotLink: LinkLabel!
    private var resendLink: LinkLabel!
    private var backLink: LinkLabel!
    private let links = NSStackView()
    private let note = Theme.text("", 12, .regular, Theme.muted)
    private let button: FlatButton
    private let stack = NSStackView()

    /// When the last code went out: the server sends one a minute at most.
    private var codeSentAt: Date?
    /// The code that checked out, sent again with the new password.
    private var goodCode = ""

    /// Signed in, either way. The account notification has already gone out.
    var onSignedIn: () -> Void = {}
    /// The address belongs to a Google account and the user pressed on.
    var onGoogle: () -> Void = {}

    /// `tall` is the first-run window's size: 36 px boxes and a 40 px button.
    init(tall: Bool = false, divider: Bool = true) {
        let height: CGFloat = tall ? 36 : 30
        nameBox = FieldBox(name, height: height)
        codeBox = FieldBox(code, height: height)
        passwordBox = FieldBox(password, height: height)
        button = FlatButton("Continue with email")
        super.init(frame: .zero)

        for (field, placeholder) in [(email, "Email address"), (name, "Full name"), (code, "6-digit code"),
                                     (password, "Password")] as [(NSTextField, String)] {
            field.placeholderString = placeholder
            field.font = .systemFont(ofSize: Theme.m(13))
            field.delegate = self
            field.target = self
            field.action = #selector(submit)
            field.cell?.sendsActionOnEndEditing = false
            field.cell?.isScrollable = true
            field.cell?.wraps = false
        }
        // So Passwords (iCloud Keychain) offers to fill and to save.
        email.contentType = .username
        password.contentType = .password
        if #available(macOS 14.0, *) { name.contentType = .name }
        // One line, like the others. (No .oneTimeCode content type: it turns
        // the field into a multi-line box whose text rides above the frame.)
        code.usesSingleLineMode = true
        let emailBox = FieldBox(email, height: height)
        // Placeholders are styled when a box watches its field; rewatch
        // after any change of placeholder.
        emailBox.watch(email)

        note.font = .systemFont(ofSize: Theme.m(12))
        note.lineBreakMode = .byWordWrapping
        // As many lines as it takes: a long address can push a message to three.
        note.maximumNumberOfLines = 0
        note.isHidden = true
        button.onClick = { [weak self] in self?.submit() }

        forgotLink = LinkLabel("Forgot password?") { [weak self] in self?.forgot() }
        resendLink = LinkLabel("Send a new code") { [weak self] in self?.forgot() }
        backLink = LinkLabel("Back to sign in") { [weak self] in
            guard let self = self, !self.busy else { return }
            self.password.stringValue = ""
            self.show(.logIn)
        }
        links.orientation = .horizontal
        links.spacing = Theme.m(16)
        for l in [forgotLink, resendLink, backLink] as [NSView] { links.addArrangedSubview(l) }

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.m(8)
        if divider { stack.addArrangedSubview(Self.orLine()) }
        for v in [emailBox, nameBox, codeBox, passwordBox, links, note, button] as [NSView] { stack.addArrangedSubview(v) }
        if divider { stack.setCustomSpacing(Theme.m(14), after: stack.arrangedSubviews[0]) }
        stack.setCustomSpacing(Theme.m(12), after: note)
        nameBox.isHidden = true
        codeBox.isHidden = true
        passwordBox.isHidden = true
        links.isHidden = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        for v in stack.arrangedSubviews where v !== note && v !== links {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        note.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        if tall { button.heightAnchor.constraint(equalToConstant: Theme.m(40)).isActive = true }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// A hairline, "or", a hairline.
    private static func orLine() -> NSView {
        let left = ColorView(color: Theme.hairline), right = ColorView(color: Theme.hairline)
        let or = Theme.text("or", 11.5, .regular, Theme.faint)
        or.font = .systemFont(ofSize: Theme.m(11.5))
        let row = Theme.hstack([left, or, right], spacing: Theme.m(10))
        row.alignment = .centerY
        for r in [left, right] {
            r.heightAnchor.constraint(equalToConstant: 1).isActive = true
        }
        left.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        return row
    }

    // MARK: Moving between modes

    private func show(_ next: Mode, _ message: String? = nil, problem: Bool = false) {
        let was = mode
        mode = next
        let choosing = next == .signUp || next == .newPassword
        nameBox.isHidden = next != .signUp
        codeBox.isHidden = next != .code
        passwordBox.isHidden = !choosing && next != .logIn
        password.placeholderString = next == .signUp ? "Password (8 or more characters)"
            : next == .newPassword ? "New password (8 or more characters)" : "Password"
        if #available(macOS 14.0, *) { password.contentType = choosing ? .newPassword : .password }
        passwordBox.watch(password)
        codeBox.watch(code)
        forgotLink.isHidden = next != .logIn
        resendLink.isHidden = next != .code
        backLink.isHidden = next != .code
        links.isHidden = next != .logIn && next != .code
        button.title = title(for: next)
        say(message, problem: problem)
        guard next != was else { return }
        switch next {
        case .signUp:
            Motion.rise(nameBox, duration: 0.32, distance: Theme.m(4))
            Motion.rise(passwordBox, delay: 0.05, duration: 0.32, distance: Theme.m(4))
            window?.makeFirstResponder(name)
        case .logIn, .newPassword:
            Motion.rise(passwordBox, duration: 0.32, distance: Theme.m(4))
            window?.makeFirstResponder(password)
        case .code:
            Motion.rise(codeBox, duration: 0.32, distance: Theme.m(4))
            window?.makeFirstResponder(code)
        case .address, .google:
            break
        }
    }

    private func title(for mode: Mode) -> String {
        switch mode {
        case .address: return "Continue with email"
        case .signUp: return "Create account"
        case .logIn: return "Sign in"
        case .google: return "Continue with Google"
        case .code: return "Continue"
        case .newPassword: return "Set password and sign in"
        }
    }

    private func say(_ message: String?, problem: Bool = false) {
        note.stringValue = message ?? ""
        note.textColor = problem ? Theme.danger : Theme.muted
        note.isHidden = message == nil
    }

    /// Return presses the button in every box, the code box included.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        submit()
        return true
    }

    /// Changing the address after the server answered about it starts over.
    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === code {
            // Digits only, six at most: a pasted "123 456" or "Code: 123456" still lands.
            let digits = String(code.stringValue.filter(\.isNumber).prefix(6))
            if digits != code.stringValue { code.stringValue = digits }
        }
        guard (obj.object as? NSTextField) === email, mode != .address else {
            if !note.isHidden, note.textColor == Theme.danger { say(nil) }
            return
        }
        show(.address)
    }

    // MARK: Pressing on

    private var address: String { email.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    @objc private func submit() {
        guard !busy else { return }
        switch mode {
        case .address: check()
        case .google: onGoogle()
        case .signUp: create()
        case .logIn: logIn()
        case .code: checkCode()
        case .newPassword: setPassword()
        }
    }

    private func check() {
        let a = address
        guard a.range(of: #"^[^\s@]+@[^\s@.]+(\.[^\s@.]+)+$"#, options: .regularExpression) != nil else {
            window?.makeFirstResponder(email)
            return say(a.isEmpty ? "Enter your email address." : "That address doesn't look right.", problem: true)
        }
        working("Checking…")
        Cloud.shared.lookUp(email: a) { [weak self] result in
            guard let self = self else { return }
            self.busy = false
            guard a == self.address else { return }  // typed on while we asked
            switch result {
            case .success("password"): self.show(.logIn)
            case .success("google"): self.show(.google, "This address signs in with Google.")
            case .success: self.show(.signUp, "New here? Add your name and a password to make your account.")
            case .failure(let e): self.say(Account.problemLine(e), problem: true)
            }
        }
    }

    private func create() {
        let who = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !who.isEmpty else {
            window?.makeFirstResponder(name)
            return say("Add your name.", problem: true)
        }
        guard password.stringValue.count >= 8 else {
            window?.makeFirstResponder(password)
            return say("Use at least 8 characters for the password.", problem: true)
        }
        working("Creating account…")
        Cloud.shared.signUp(email: address, password: password.stringValue, name: who) { [weak self] result in
            self?.finished(result)
        }
    }

    private func logIn() {
        guard !password.stringValue.isEmpty else {
            window?.makeFirstResponder(password)
            return say("Enter your password.", problem: true)
        }
        working("Signing in…")
        Cloud.shared.logIn(email: address, password: password.stringValue) { [weak self] result in
            self?.finished(result)
        }
    }

    // MARK: Forgot password

    /// Mails a code to the address, or a new one from the Code box.
    private func forgot() {
        guard !busy else { return }
        if let sent = codeSentAt, mode == .code {
            let wait = Int(ceil(60 - Date().timeIntervalSince(sent)))
            if wait > 0 { return say("You can ask for a new code in \(wait) s.", problem: true) }
        }
        let a = address
        let again = mode == .code
        working("Sending code…")
        // The link that was pressed says so too: it's where the eye is.
        (again ? resendLink : forgotLink)?.title = "Sending code…"
        Cloud.shared.forgotPassword(email: a) { [weak self] result in
            guard let self = self else { return }
            self.busy = false
            guard a == self.address else { return }  // typed on while we asked
            switch result {
            case .success:
                self.codeSentAt = Date()
                self.code.stringValue = ""
                self.password.stringValue = ""
                self.show(.code, again ? "We sent a new code to \(a).\nIt works for 10 minutes."
                                       : "We sent a 6-digit code to \(a).\nIt works for 10 minutes.")
                self.window?.makeFirstResponder(self.code)
            case .failure(let e):
                self.say(Account.problemLine(e), problem: true)
            }
        }
    }

    private func checkCode() {
        let c = code.stringValue.filter(\.isNumber)
        guard c.count == 6 else {
            window?.makeFirstResponder(code)
            return say("Enter the 6-digit code from the email.", problem: true)
        }
        let a = address
        working("Checking code…")
        Cloud.shared.checkResetCode(email: a, code: c) { [weak self] result in
            guard let self = self else { return }
            self.busy = false
            guard a == self.address else { return }
            switch result {
            case .success:
                self.goodCode = c
                self.password.stringValue = ""
                self.show(.newPassword, "Now choose a new password.")
            case .failure(let e):
                self.code.stringValue = ""
                self.window?.makeFirstResponder(self.code)
                self.say(Account.problemLine(e), problem: true)
            }
        }
    }

    private func setPassword() {
        guard password.stringValue.count >= 8 else {
            window?.makeFirstResponder(password)
            return say("Use at least 8 characters for the password.", problem: true)
        }
        working("Saving…")
        Cloud.shared.resetPassword(email: address, code: goodCode, password: password.stringValue) { [weak self] result in
            self?.finished(result)
        }
    }

    private func finished(_ result: Result<Void, CloudError>) {
        busy = false
        switch result {
        case .success:
            password.stringValue = ""
            code.stringValue = ""
            goodCode = ""
            say(nil)
            onSignedIn()
        case .failure(.server(_, let reason)) where reason == "code_expired" || reason == "wrong_code":
            // The code ran out between checking it and setting the password.
            code.stringValue = ""
            password.stringValue = ""
            show(.code, Account.problemLine(.server(400, reason)), problem: true)
        case .failure(.server(_, "email_taken")):
            // Made a moment ago somewhere else: sign in to it instead.
            password.stringValue = ""
            show(.logIn, "There's already an account at this address. Enter its password.")
        case .failure(.server(_, "use_google")):
            show(.google, "This address signs in with Google.")
        case .failure(.server(_, "wrong_password")):
            password.stringValue = ""
            window?.makeFirstResponder(password)
            say(Account.problemLine(.server(401, "wrong_password")), problem: true)
        case .failure(let e):
            say(Account.problemLine(e), problem: true)
        }
    }

    /// For --onboardingshot: each step the form grows into, with no call to the server.
    enum ShotStep { case signUp, logIn, code, newPassword }
    func showForShot(_ step: ShotStep) {
        reset()
        email.stringValue = Account.exampleEmail
        switch step {
        case .signUp: show(.signUp, "New here? Add your name and a password to make your account.")
        case .logIn: show(.logIn)
        case .code:
            // A long address, so a message that wraps to three lines shows it.
            email.stringValue = "firstname.lastname+sayctrl@example.com"
            show(.code, "We sent a 6-digit code to \(email.stringValue).\nIt works for 10 minutes.")
            code.stringValue = "745345"
        case .newPassword: show(.newPassword, "Now choose a new password.")
        }
    }

    /// Back to one empty box, as after signing out.
    func reset() {
        for f in [email, name, code, password] as [NSTextField] { f.stringValue = "" }
        codeSentAt = nil
        goodCode = ""
        show(.address)
    }
}
