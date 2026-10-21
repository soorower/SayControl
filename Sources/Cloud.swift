// SayControl cloud: the account, and the calls that spend its plan.
//
// api.saycontrol.com (the SayCtrl-Cloud repo, a Cloudflare Worker) signs you
// in — with Google through saycontrol.com in the browser, or with an address
// and password from the app — relays every cloud dictation to the vendor on its own key,
// and runs polish on its own key too. No provider key or vendor token ever
// reaches this Mac: the app holds only our own tokens — an hour-long access
// token in memory and a refresh token in a file only you can read (see the
// store at the bottom).
//
// Takes: LiveTranscriber opens /v1/listen with the access token and speaks
// AssemblyAI's protocol to it. The Worker counts the words as they pass and
// ends the take itself when the plan runs out, so the app reports nothing.
import Cocoa
import CryptoKit
import Security
import IOKit
import DeviceCheck

/// What the server said about the plan: the Worker's `usage` object.
struct CloudUsage {
    struct Allowance {
        let used: Int
        let limit: Int?
        var left: Int? { limit.map { max(0, $0 - used) } }
        var fraction: Double { limit.map { $0 > 0 ? min(1, Double(used) / Double($0)) : 1 } ?? 0 }
    }
    /// Free's extra takes once the week's words are gone: a few, typed
    /// when you let go, within a day of the first. nil on Pro, and from a
    /// server that doesn't offer them.
    struct Grace {
        let used: Int
        let limit: Int
        let left: Int
        let endsAt: Date?
    }
    let plan: String
    let period: String
    let resetsAt: Date
    let words: Allowance
    let speechMs: Allowance
    let grace: Grace?

    private init(plan: String, period: String, resetsAt: Date, words: Allowance, speechMs: Allowance, grace: Grace?) {
        self.plan = plan
        self.period = period
        self.resetsAt = resetsAt
        self.words = words
        self.speechMs = speechMs
        self.grace = grace
    }

    /// What a take just spent, until the server's own count comes back with
    /// the next take's Begin.
    func adding(words n: Int) -> CloudUsage {
        CloudUsage(plan: plan, period: period, resetsAt: resetsAt,
                   words: Allowance(used: words.used + n, limit: words.limit), speechMs: speechMs, grace: grace)
    }

    /// A date as the server writes it: milliseconds, or an ISO string.
    fileprivate static func date(_ v: Any?) -> Date? {
        if let ms = v as? Double { return Date(timeIntervalSince1970: ms / 1000) }
        if let s = v as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        }
        return nil
    }

    init?(_ json: [String: Any]) {
        func allowance(_ key: String) -> Allowance? {
            guard let a = json[key] as? [String: Any], let used = a["used"] as? Int else { return nil }
            return Allowance(used: used, limit: a["limit"] as? Int)
        }
        guard let plan = json["plan"] as? String, let period = json["period"] as? String,
              let resets = json["resetsAt"] as? Double,
              let words = allowance("words"), let speech = allowance("speechMs") else { return nil }
        self.plan = plan
        self.period = period
        self.resetsAt = Date(timeIntervalSince1970: resets / 1000)
        self.words = words
        self.speechMs = speech
        if let g = json["grace"] as? [String: Any], let limit = g["limit"] as? Int {
            grace = Grace(used: g["used"] as? Int ?? 0, limit: limit, left: g["left"] as? Int ?? 0,
                          endsAt: Self.date(g["endsAt"]))
        } else {
            grace = nil
        }
    }
}

/// The agent voice's allowance, as the server counts it (the Worker's
/// `agent` object): the plan's conversations — Free's ten, once; Pro's
/// month — and the bought ones beside them, kept until they are used.
struct AgentAllowance {
    let limit: Int
    /// Free's are once, to try the voice; Pro's come back each month.
    let once: Bool
    let used: Int
    let left: Int
    /// Bought in packs and not used yet.
    let credits: Int
    /// When the plan's come back. nil for Free's.
    let resetsAt: Date?
    /// What can be bought — 500, 1,000, 5,000, 10,000 — and for how much,
    /// each at the same price per conversation.
    let packs: [(conversations: Int, dollars: Int)]

    /// Whether a conversation can start now.
    var any: Bool { left > 0 || credits > 0 }

    init?(_ json: [String: Any]) {
        guard let limit = json["limit"] as? Int, let used = json["used"] as? Int,
              let left = json["left"] as? Int else { return nil }
        self.limit = limit
        once = (json["per"] as? String) == "once"
        self.used = used
        self.left = left
        credits = json["credits"] as? Int ?? 0
        resetsAt = (json["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        packs = (json["packs"] as? [[String: Any]] ?? []).compactMap { p in
            guard let n = p["conversations"] as? Int, let usd = p["priceUsd"] as? Int else { return nil }
            return (n, usd)
        }
    }
}

enum CloudError: LocalizedError {
    case signedOut
    /// The plan's allowance is spent: "words", "speech" or "llm".
    case limitReached(String)
    case server(Int, String)
    case transport(Error)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .signedOut: return "Not signed in to SayControl"
        case .limitReached(let what):
            switch what {
            case "words": return "This week's free words are used up"
            case "grace": return "This week's free words and extra takes are used up"
            // A user's Pro is sold as unlimited, so the fair-use stop says
            // what happens next rather than naming a quota they never saw.
            case "speech": return Config.retail ? "Cloud dictation is paused until next month"
                                                : "This month's Pro hours are used up"
            default: return "This period's cloud allowance is used up"
            }
        // This Mac and Apple's DeviceCheck (the Worker's devicecheck.ts).
        case .server(_, "device_unverified"): return "SayControl couldn't confirm this Mac with Apple. Try again in a minute"
        case .server(_, "mac_refused"): return "This Mac's free plan is already in use. Upgrade to Pro to keep dictating"
        case .server(let status, let code): return "SayControl cloud said \(code) (HTTP \(status))"
        case .transport(let error): return error.localizedDescription
        case .cancelled: return "Cancelled"
        }
    }
}

final class Cloud: NSObject {
    static let shared = Cloud()

    /// SAYCTRL_CLOUD_URL points a dev build at `wrangler dev`. A shipping
    /// copy ignores it: its audio, tokens and sign-in only ever go to
    /// SayControl's own server, whatever a settings file says.
    static let base: URL = devOverride("SAYCTRL_CLOUD_URL") ?? URL(string: "https://api.saycontrol.com")!

    /// A URL override from the environment or the settings file, honoured in
    /// the dev build only.
    private static func devOverride(_ key: String) -> URL? {
        guard Config.isDev else { return nil }
        let value = ProcessInfo.processInfo.environment[key] ?? Config.shared.env()[key]
        return value.flatMap(URL.init(string:))
    }

    /// The header this Mac's id rides in, on every call to our cloud and on
    /// every take's socket.
    static let macHeader = "SayControl-Device"

    /// This Mac, as the cloud counts the free plan: a SHA-256 of the Mac's
    /// hardware UUID, never the UUID itself. It reads the same under every
    /// account and after a reinstall, so every free account on this Mac
    /// shares one free allowance. The Worker refuses a free cloud take
    /// without it. nil only if IOKit has no platform UUID, which a real Mac
    /// always has.
    static let macID: String? = {
        let expert = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard expert != 0 else { return nil }
        defer { IOObjectRelease(expert) }
        guard let uuid = IORegistryEntryCreateCFProperty(expert, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String, !uuid.isEmpty else { return nil }
        return SHA256.hash(data: Data("SayControl Mac v1 \(uuid)".utf8)).map { String(format: "%02x", $0) }.joined()
    }()

    /// Names this Mac on a request to our cloud, with Apple's word that it
    /// is a real Mac until the server has taken it.
    static func nameMac(on req: inout URLRequest) {
        guard let id = macID else { return }
        req.setValue(id, forHTTPHeaderField: macHeader)
        // Only where the server checks it: a token spent on a sign-in refresh
        // is one the take after it doesn't have.
        if !macVouched, checkPaths.contains(req.url?.path ?? ""), let token = checkToken.take() {
            req.setValue(token, forHTTPHeaderField: checkHeader)
            makeCheckToken()
        }
    }

    // MARK: Apple's DeviceCheck

    /// Where Apple's DeviceCheck token rides. The free plan is one per real
    /// Mac: the server asks Apple about the token once, and from then on the
    /// Mac's id is enough (the Worker's devicecheck.ts). A token says nothing
    /// about who you are; Apple only tells us whether this device already
    /// has a free plan with us.
    static let checkHeader = "SayControl-Device-Check"
    private static let checkPaths: Set<String> = ["/v1/me", "/v1/listen", "/v1/transcribe", "/v1/agent/start"]

    /// A token made ahead of the request that needs it (~20 ms to make);
    /// each goes out once, and the next is made as it leaves.
    private static let checkToken = TokenSlot()

    final class TokenSlot {
        private let lock = NSLock()
        private var token: String?
        private var making = false
        func take() -> String? { lock.lock(); defer { lock.unlock() }; let t = token; token = nil; return t }
        func peek() -> Bool { lock.lock(); defer { lock.unlock() }; return token != nil }
        /// true when the caller should make one: none in hand, none on its way.
        func claimMaking() -> Bool { lock.lock(); defer { lock.unlock() }; guard token == nil, !making else { return false }; making = true; return true }
        func put(_ t: String?) { lock.lock(); token = t ?? token; making = false; lock.unlock() }
    }

    /// The server has said this Mac is vouched for (/v1/me's `device`), so
    /// no token need go with the id. Kept per server and per Mac.
    private static var vouchedKey: String { "cloud.vouchedMac.\(base.host ?? "")" }
    static var macVouched: Bool {
        get { macID != nil && UserDefaults.standard.string(forKey: vouchedKey) == macID }
        set { UserDefaults.standard.set(newValue ? macID : nil, forKey: vouchedKey) }
    }

    /// Asks Apple for a token, unless one is in hand or the Mac is vouched for.
    /// Off since 2026-10-13: Apple never accepted our DeviceCheck key (401 on
    /// every check for two days, two keys), so the server stopped asking it
    /// and the free plan's abuse gets another answer. No token is made or
    /// sent; the rest stays for the day it comes back.
    static let deviceCheck = false

    static func makeCheckToken(then done: ((Bool) -> Void)? = nil) {
        guard deviceCheck, !macVouched, macID != nil, DCDevice.current.isSupported else { done?(false); return }
        guard checkToken.claimMaking() else { done?(checkToken.peek()); return }
        DCDevice.current.generateToken { data, error in
            checkToken.put(data?.base64EncodedString())
            if let error = error { Config.shared.log("Cloud: DeviceCheck token failed — \(error.localizedDescription)") }
            DispatchQueue.main.async { done?(data != nil) }
        }
    }

    /// The server's word on this Mac, from /v1/me or a refusal. "unverified"
    /// once more brings a token with the next request.
    private var askedWithToken = false
    func adoptDevice(_ state: String?) {
        guard let state = state else { return }
        let vouched = state == "verified"
        if vouched != Self.macVouched { Config.shared.log("Cloud: this Mac is \(state) with Apple's DeviceCheck") }
        Self.macVouched = vouched
        // Refused: tokens go along again, for the server's hourly second look.
        if state == "refused" { Self.makeCheckToken(); return }
        guard state == "unverified" else { return }
        // A token for the next request, whatever it is.
        guard !askedWithToken else { Self.makeCheckToken(); return }
        // The first /v1/me can go before the launch's token is made: ask once
        // more, with it.
        askedWithToken = true
        Self.makeCheckToken { [weak self] made in
            if made { self?.refreshAccount() }
        }
    }

    /// Where a cloud take's socket goes: the same host, over wss (ws for a
    /// local `wrangler dev`).
    static var listenURL: URL {
        var c = URLComponents(url: base.appendingPathComponent("v1/listen"), resolvingAgainstBaseURL: false)!
        c.scheme = c.scheme == "http" ? "ws" : "wss"
        return c.url!
    }

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        return URLSession(configuration: c)
    }()

    // Main-thread state.
    private var accessToken: String?
    private var accessExpiry = Date.distantPast
    private var refreshWaiters: [(Result<String, CloudError>) -> Void]?
    private(set) var usage: CloudUsage?
    /// The agent voice's conversations: from /v1/me, and from every answer
    /// that carries the count (a conversation opened, or refused).
    private(set) var agent: AgentAllowance?

    /// The plan has nothing left this period. Free then has its few extra
    /// takes (`graceLeft`); after those, nothing until the reset.
    /// A count from before the reset says nothing about the new week: the
    /// next take asks the server, whose Begin brings the fresh one.
    var spent: Bool {
        guard let u = usage, u.resetsAt > Date() else { return false }
        return u.words.left == 0 || u.speechMs.left == 0
    }

    /// Extra takes Free has left this week, 0 when there are none (or the
    /// day they were good for is over).
    var graceLeft: Int {
        guard let g = usage?.grace, usage?.plan != "pro" else { return 0 }
        if let end = g.endsAt, end <= Date() { return 0 }
        return g.left
    }

    // MARK: Signed in

    /// A stored refresh token is what signed in means. Read once; every
    /// screen asks.
    private lazy var hasRefreshToken: Bool = {
        // Dev builds only: SAYCTRL_CLOUD_REFRESH hands a run a refresh token
        // without the sign-in sheet (--cloudtest), stored as Google's would be.
        if !Config.retail, TokenStore.read(Self.refreshKey) == nil,
           let token = ProcessInfo.processInfo.environment["SAYCTRL_CLOUD_REFRESH"], !token.isEmpty {
            TokenStore.write(Self.refreshKey, token)
        }
        return TokenStore.read(Self.refreshKey) != nil
    }()
    var signedIn: Bool { hasRefreshToken }

    private static let refreshKey = "refresh-token"

    private func signedOutLocally() {
        TokenStore.delete(Self.refreshKey)
        hasRefreshToken = false
        accessToken = nil
        accessExpiry = .distantPast
        usage = nil
        subscription = nil
        checkoutOpenedAt = nil
        portalOpenedAt = nil
        for key in ["ACCOUNT_ID", "ACCOUNT_NAME", "ACCOUNT_EMAIL", "ACCOUNT_PLAN", "ACCOUNT_VIA"] { Config.shared.set(key, nil) }
        AccountPhoto.clear()
        Config.shared.useAccount(nil)
        NotificationCenter.default.post(name: .sayctrlAccountChanged, object: nil)
    }

    // MARK: Sign-in with Google

    /// The website, where Google's leg of signing in starts and ends.
    /// SAYCTRL_SITE_URL points a dev build at `npm run dev` in SayCtrl-Web;
    /// a shipping copy ignores it, as it does SAYCTRL_CLOUD_URL.
    static let site: URL = devOverride("SAYCTRL_SITE_URL") ?? URL(string: "https://www.saycontrol.com")!

    /// The scheme this build answers to (Info.plist; build.sh gives the dev
    /// build saycontrol-dev, so the two copies on one Mac never catch each
    /// other's sign-in).
    static let urlScheme: String = {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        return (types?.first?["CFBundleURLSchemes"] as? [String])?.first ?? "saycontrol"
    }()

    /// A Google sign-in waiting on the browser: the verifier only this app
    /// holds, and who to tell.
    private var pendingGoogle: (verifier: String, completion: (Result<Void, CloudError>) -> Void)?

    /// Opens saycontrol.com/signin in the browser, which goes on to Google.
    /// It ends back here at saycontrol://auth (handleURL) with a one-time
    /// code, which only this call's PKCE verifier can trade for tokens. A
    /// second call replaces the first; the first reports cancelled.
    func signIn(completion: @escaping (Result<Void, CloudError>) -> Void) {
        let verifier = Self.randomURLSafe(32)
        let challenge = Self.base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        var start = URLComponents(url: Self.site.appendingPathComponent("signin"), resolvingAgainstBaseURL: false)!
        start.queryItems = [URLQueryItem(name: "challenge", value: challenge)]
        if Self.urlScheme == "saycontrol-dev" { start.queryItems?.append(URLQueryItem(name: "app", value: "dev")) }

        let earlier = pendingGoogle
        pendingGoogle = (verifier, completion)
        earlier?.completion(.failure(.cancelled))
        guard NSWorkspace.shared.open(start.url!) else {
            pendingGoogle = nil
            return completion(.failure(.server(0, "browser_failed")))
        }
        Config.shared.log("Cloud: sign-in opened in the browser")
    }

    /// Whether a Google sign-in is waiting on the browser.
    var waitingOnBrowser: Bool { pendingGoogle != nil }

    /// Stops waiting on the browser; the sign-in reports cancelled.
    func cancelGoogle() {
        let pending = pendingGoogle
        pendingGoogle = nil
        pending?.completion(.failure(.cancelled))
    }

    /// saycontrol://auth?code=… (or ?error=…), from the website's done page;
    /// saycontrol://billing from the checkout page, back from paying for Pro,
    /// and saycontrol://agents back from paying for a pack.
    /// Answers whether the URL was ours.
    @discardableResult
    func handleURL(_ url: URL) -> Bool {
        if url.scheme == Self.urlScheme, url.host == "billing" {
            // Back from paying: Plans, where Pro shows as soon as the server says.
            SettingsUI.shared.present(selecting: "billing")
            checkoutReturned()
            return true
        }
        if url.scheme == Self.urlScheme, url.host == "agents" {
            // Back from a pack: Agents, where the count grows as soon as the server says.
            SettingsUI.shared.present(selecting: "agents")
            checkoutReturned()
            return true
        }
        guard url.scheme == Self.urlScheme, url.host == "auth" else { return false }
        guard let pending = pendingGoogle else {
            Config.shared.log("Cloud: a sign-in link arrived with no sign-in waiting")
            return true
        }
        pendingGoogle = nil
        // The browser had the focus; the app takes it back now, not after
        // the code is traded.
        NSApp.activate(ignoringOtherApps: true)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let problem = items.first(where: { $0.name == "error" })?.value {
            pending.completion(.failure(problem == "cancelled" ? .cancelled : .server(0, problem)))
            return true
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            pending.completion(.failure(.server(0, "no_code")))
            return true
        }
        post("v1/auth/token", ["code": code, "verifier": pending.verifier], auth: false) { [weak self] result in
            self?.signedIn(result, "Google", pending.completion)
        }
        return true
    }

    /// A token pair from any way in: kept, announced, and the plan fetched.
    private func signedIn(_ result: Result<[String: Any], CloudError>, _ how: String,
                          _ completion: (Result<Void, CloudError>) -> Void) {
        switch result {
        case .failure(let e): completion(.failure(e))
        case .success(let json):
            guard adopt(json) else { return completion(.failure(.server(0, "bad_tokens"))) }
            Config.shared.log("Cloud: signed in (\(how))")
            NotificationCenter.default.post(name: .sayctrlAccountChanged, object: nil)
            refreshAccount()
            completion(.success(()))
        }
    }

    // MARK: Sign-in with an address

    /// How the account at an address signs in: "password", "google", or
    /// "none" when there is no account yet.
    func lookUp(email: String, completion: @escaping (Result<String, CloudError>) -> Void) {
        post("v1/auth/email", ["email": email], auth: false) { result in
            completion(result.map { $0["account"] as? String ?? "none" })
        }
    }

    func signUp(email: String, password: String, name: String, completion: @escaping (Result<Void, CloudError>) -> Void) {
        post("v1/auth/signup", ["email": email, "password": password, "name": name], auth: false) { [weak self] result in
            self?.signedIn(result, "new account", completion)
        }
    }

    func logIn(email: String, password: String, completion: @escaping (Result<Void, CloudError>) -> Void) {
        post("v1/auth/login", ["email": email, "password": password], auth: false) { [weak self] result in
            self?.signedIn(result, "password", completion)
        }
    }

    // MARK: Forgot password

    /// Mails a 6-digit code to the address. Answers the same whether or not
    /// there is an account there; a Google account is mailed a pointer to
    /// Google instead of a code.
    func forgotPassword(email: String, completion: @escaping (Result<Void, CloudError>) -> Void) {
        post("v1/auth/password/forgot", ["email": email], auth: false) { result in
            completion(result.map { _ in () })
        }
    }

    /// Whether the code is right, before the new-password box shows. A right
    /// code keeps its try.
    func checkResetCode(email: String, code: String, completion: @escaping (Result<Void, CloudError>) -> Void) {
        post("v1/auth/password/check", ["email": email, "code": code], auth: false) { result in
            completion(result.map { _ in () })
        }
    }

    /// Sets the new password and signs this Mac in; every other Mac is signed out.
    func resetPassword(email: String, code: String, password: String, completion: @escaping (Result<Void, CloudError>) -> Void) {
        post("v1/auth/password/reset", ["email": email, "code": code, "password": password], auth: false) { [weak self] result in
            self?.signedIn(result, "password reset", completion)
        }
    }

    /// Deletes the account on the server (everything that names you, every
    /// sign-in on every Mac), then signs this Mac out. A Pro plan is
    /// cancelled first: the server answers pro_active.
    func deleteAccount(completion: @escaping (Result<Void, CloudError>) -> Void) {
        post("v1/account/delete", ["confirm": "delete"]) { [weak self] result in
            switch result {
            case .failure(let e): completion(.failure(e))
            case .success:
                Config.shared.log("Cloud: account deleted")
                self?.signedOutLocally()
                completion(.success(()))
            }
        }
    }

    func signOut() {
        // The refresh token to revoke, read before the local state goes, and
        // sent as it is — never through a refresh, which would write a new
        // one back and sign you in again.
        let refresh = TokenStore.read(Self.refreshKey)
        signedOutLocally()
        if let refresh = refresh { fire("v1/auth/logout", ["refreshToken": refresh], bearer: nil) }
        Config.shared.log("Cloud: signed out")
    }

    /// A POST nobody waits on.
    private func fire(_ path: String, _ body: [String: Any], bearer: String?) {
        var req = URLRequest(url: Self.base.appendingPathComponent(path))
        req.httpMethod = "POST"
        if let bearer = bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        session.dataTask(with: req) { _, _, _ in }.resume()
    }

    /// Takes a token pair (and the user it names) from /v1/auth/token or /refresh.
    @discardableResult
    private func adopt(_ json: [String: Any]) -> Bool {
        guard let access = json["accessToken"] as? String,
              let expires = json["accessTokenExpiresAt"] as? Double,
              let refresh = json["refreshToken"] as? String else { return false }
        TokenStore.write(Self.refreshKey, refresh)
        hasRefreshToken = true
        accessToken = access
        accessExpiry = Date(timeIntervalSince1970: expires / 1000)
        if let user = json["user"] as? [String: Any] { cacheProfile(user) }
        return true
    }

    private func cacheProfile(_ user: [String: Any]) {
        // Sign-in names the user `id`, /v1/me `userId`. Before anything
        // redraws: the screens are about to show this account's own things.
        if let id = (user["id"] ?? user["userId"]) as? String {
            Config.shared.set("ACCOUNT_ID", id)
            Config.shared.useAccount(id)
        }
        Config.shared.set("ACCOUNT_NAME", (user["name"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        Config.shared.set("ACCOUNT_EMAIL", user["email"] as? String)
        if let via = user["signsInWith"] as? String { Config.shared.set("ACCOUNT_VIA", via == "password" ? "password" : nil) }
        // Present (a string, or null) only from a server that knows photos.
        if user.keys.contains("avatarUrl") { AccountPhoto.update(to: user["avatarUrl"] as? String) }
        if let plan = user["plan"] as? String {
            Config.shared.set("ACCOUNT_PLAN", plan == "pro" ? "pro" : nil)
        } else if let plan = user["plan"] as? [String: Any], let id = plan["id"] as? String {
            Config.shared.set("ACCOUNT_PLAN", id == "pro" ? "pro" : nil)
        }
    }

    // MARK: Access tokens

    /// A current access token, refreshing first when the one in hand is
    /// within a minute of expiring. Refreshes never overlap: the server reads
    /// a refresh token presented twice as a stolen copy and signs the user
    /// out everywhere, so everyone waiting shares the one refresh in flight.
    func withAccessToken(_ completion: @escaping (Result<String, CloudError>) -> Void) {
        if let token = accessToken, accessExpiry.timeIntervalSinceNow > 60 { return completion(.success(token)) }
        guard let refresh = TokenStore.read(Self.refreshKey) else { return completion(.failure(.signedOut)) }
        if refreshWaiters != nil { refreshWaiters?.append(completion); return }
        refreshWaiters = [completion]
        post("v1/auth/refresh", ["refreshToken": refresh], auth: false) { [weak self] result in
            guard let self = self else { return }
            let waiters = self.refreshWaiters ?? []
            self.refreshWaiters = nil
            // Signed out while this was in flight: its tokens are not kept.
            guard self.signedIn else { return waiters.forEach { $0(.failure(.signedOut)) } }
            switch result {
            case .success(let json) where self.adopt(json):
                let token = self.accessToken!
                waiters.forEach { $0(.success(token)) }
            case .failure(.server(401, _)):
                // Revoked or expired: signed out here too.
                Config.shared.log("Cloud: refresh token refused — signed out")
                self.signedOutLocally()
                waiters.forEach { $0(.failure(.signedOut)) }
            case .failure(let e):
                waiters.forEach { $0(.failure(e)) }
            default:
                waiters.forEach { $0(.failure(.server(0, "bad_tokens"))) }
            }
        }
    }

    // MARK: The account

    /// When /v1/me last answered, or was last asked.
    private var accountAskedAt = Date.distantPast

    /// A refresh for a screen that is opening, skipped when the last one is
    /// under half a minute old — the answer redraws the screen that asked.
    func refreshAccountIfStale() {
        guard Date().timeIntervalSince(accountAskedAt) > 30 else { return }
        refreshAccount()
    }

    /// Plan, usage and name from the server; the Account screens redraw.
    func refreshAccount(completion: ((Result<Void, CloudError>) -> Void)? = nil) {
        guard signedIn else { completion?(.failure(.signedOut)); return }
        accountAskedAt = Date()
        get("v1/me") { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let e): completion?(.failure(e))
            case .success(let json):
                self.cacheProfile(json)
                self.adoptDevice(json["device"] as? String)
                if let u = json["usage"] as? [String: Any] { self.usage = CloudUsage(u) }
                self.adoptAgent(from: json)
                let sub = json["subscription"] as? [String: Any]
                func date(_ key: String) -> Date? { (sub?[key] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } }
                self.subscription = sub == nil ? nil : (date("renewsAt"), date("endsAt"))
                NotificationCenter.default.post(name: .sayctrlAccountChanged, object: nil)
                completion?(.success(()))
            }
        }
    }

    // MARK: Takes

    /// The server's word on the plan, from a take's Begin, Limit or Error.
    func adoptUsage(from message: [String: Any]) {
        switch message["code"] as? String {
        case "device_unverified": adoptDevice("unverified")
        case "mac_refused": adoptDevice("refused")
        default: break
        }
        if message["type"] as? String == "Receipt", let take = message["take"] as? String,
           let receipt = message["receipt"] as? String {
            return noteReceipt(take: take, receipt: receipt)
        }
        guard let u = message["usage"] as? [String: Any], let usage = CloudUsage(u) else { return }
        self.usage = usage
        NotificationCenter.default.post(name: .sayctrlAccountChanged, object: nil)
    }

    /// A take ended with these words. The server has already counted them;
    /// this only moves the meter until the next take brings its count.
    func noteTake(words: Int) {
        guard words > 0, let u = usage else { return }
        usage = u.adding(words: words)
        NotificationCenter.default.post(name: .sayctrlAccountChanged, object: nil)
    }

    /// The relay refused the access token (the server's secret changed, say):
    /// the next take refreshes it first.
    func accessRefused() { accessExpiry = .distantPast }

    /// At launch: the plan and what is left of it.
    func launch() {
        // Back in the app after a checkout, however you got here.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.checkoutReturned()
        }
        // Keys from the vendor-token days, when takes were reported.
        for key in ["CLOUD_OPEN_SESSION", "CLOUD_DEVICE"] where Config.shared.env()[key] != nil {
            Config.shared.set(key, nil)
        }
        guard signedIn else { Self.makeCheckToken(); return }
        // The token first, so the launch's /v1/me can have the Mac vouched
        // for; it takes ~20 ms, and the plan is asked for either way.
        Self.makeCheckToken { [weak self] _ in self?.refreshAccount() }
    }

    /// The cloud was switched on or off: the meter catches up.
    func cloudSwitched() {
        if Config.shared.cloudOn { refreshAccount() }
    }

    /// Opens the connection polish will use, while the user is still
    /// talking, and gets a fresh access token if this one is nearly spent.
    func warm() {
        guard signedIn else { return }
        withAccessToken { [weak self] _ in
            guard let self = self else { return }
            self.session.dataTask(with: Self.base.appendingPathComponent("v1/plans")) { _, _, _ in }.resume()
        }
    }

    /// Words as the server counts them: Unicode word boundaries, the same
    /// ICU rules as the Worker's Intl.Segmenter.
    static func words(in text: String) -> Int {
        var n = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in n += 1 }
        return n
    }

    // MARK: Paying

    /// What the server said about the Pro subscription: when it renews, or
    /// when a cancellation ends it. nil on Free, or before /v1/me answers.
    private(set) var subscription: (renewsAt: Date?, endsAt: Date?)?

    /// When a checkout was last opened: coming back to the app within the
    /// half hour after asks the server for the plan, a few times, since
    /// Paddle's webhook can land a moment after the page says paid.
    private var checkoutOpenedAt: Date?
    /// The same for a pack of agent conversations, with the bought count
    /// it started from: back in the app, the count is asked for until it grows.
    private var packCheckout: (openedAt: Date, credits: Int)?

    /// What a checkout is for: Pro, or a pack of agent conversations (Pro only).
    enum CheckoutItem: String { case pro, agentPack = "agent_pack" }

    /// Asks for a checkout and opens it in the browser. The page is
    /// saycontrol.com/checkout with Paddle's transaction; the dev build adds
    /// app=dev so the way back is saycontrol-dev://.
    func openCheckout(_ item: CheckoutItem = .pro, conversations: Int? = nil,
                      completion: @escaping (Result<Void, CloudError>) -> Void) {
        var body: [String: Any] = ["item": item.rawValue]
        // How many agent conversations: one of the amounts on sale.
        if item == .agentPack, let n = conversations { body["conversations"] = n }
        post("v1/billing/checkout", body) { [weak self] result in
            switch result {
            case .failure(let e): completion(.failure(e))
            case .success(let json):
                guard var c = (json["url"] as? String).flatMap({ URLComponents(string: $0) }),
                      c.scheme == "https" else { return completion(.failure(.server(0, "bad_reply"))) }
                if Self.urlScheme == "saycontrol-dev" {
                    c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "app", value: "dev")]
                }
                guard let url = c.url, NSWorkspace.shared.open(url) else {
                    return completion(.failure(.server(0, "browser_failed")))
                }
                if item == .pro { self?.checkoutOpenedAt = Date() }
                else { self?.packCheckout = (Date(), self?.agent?.credits ?? 0) }
                Config.shared.log("Cloud: \(item.rawValue) checkout opened in the browser")
                completion(.success(()))
            }
        }
    }

    /// When Paddle's portal was last opened: a cancel or a new card made
    /// there reaches us by webhook, and the app re-asks on the way back.
    private var portalOpenedAt: Date?

    /// Paddle's customer portal, signed in as this account: cancel, change
    /// the card, receipts.
    func openPortal(completion: @escaping (Result<Void, CloudError>) -> Void) {
        post("v1/billing/portal", [:]) { [weak self] result in
            switch result {
            case .failure(let e): completion(.failure(e))
            case .success(let json):
                guard let url = (json["url"] as? String).flatMap(URL.init(string:)), url.scheme == "https",
                      NSWorkspace.shared.open(url) else { return completion(.failure(.server(0, "bad_reply"))) }
                self?.portalOpenedAt = Date()
                Config.shared.log("Cloud: billing portal opened in the browser")
                completion(.success(()))
            }
        }
    }

    /// Back to Free (cancel: true), which Paddle does at the end of the month
    /// already paid for; or Keep Pro, which takes that cancel back. The
    /// server answers with the plan as it now stands.
    func changePro(cancel: Bool, completion: @escaping (Result<Void, CloudError>) -> Void) {
        post(cancel ? "v1/billing/cancel" : "v1/billing/resume", [:]) { [weak self] result in
            switch result {
            case .failure(let e): completion(.failure(e))
            case .success:
                Config.shared.log("Cloud: Pro \(cancel ? "cancelled at the end of the period" : "kept")")
                self?.refreshAccount { _ in completion(.success(())) }
            }
        }
    }

    /// Back from a checkout (the page's link, or just switching back to the
    /// app): the plan, now and again over the next few seconds, until Pro shows.
    /// Back from the portal: the same, a few times, for whatever changed there.
    func checkoutReturned() {
        if signedIn, let opened = portalOpenedAt {
            portalOpenedAt = nil
            if Date().timeIntervalSince(opened) < 30 * 60 {
                for delay in [0.0, 4, 12] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.refreshAccount() }
                }
            }
        }
        if signedIn, let pack = packCheckout {
            if Date().timeIntervalSince(pack.openedAt) < 30 * 60 {
                for delay in [0.0, 3, 8, 20] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self = self, let waiting = self.packCheckout else { return }
                        self.refreshAccount { _ in
                            guard let a = self.agent, a.credits > waiting.credits, self.packCheckout != nil else { return }
                            self.packCheckout = nil
                            Config.shared.log("Cloud: agent pack added — \(a.credits) bought conversations")
                            SettingsUI.shared.toast("\(Account.grouped(a.credits - waiting.credits)) agent conversations added.")
                        }
                    }
                }
            } else {
                packCheckout = nil
            }
        }
        guard signedIn, let opened = checkoutOpenedAt, Date().timeIntervalSince(opened) < 30 * 60 else { return }
        for delay in [0.0, 3, 8, 20] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, self.checkoutOpenedAt != nil else { return }
                self.refreshAccount { _ in
                    if Account.plan == "pro", self.checkoutOpenedAt != nil {
                        self.checkoutOpenedAt = nil
                        Config.shared.log("Cloud: Pro is on")
                        SettingsUI.shared.toast("You're on Pro. Dictate as much as you like.")
                    }
                }
            }
        }
    }

    // MARK: Model calls

    /// A model call on the server's key, model and prompt: the app says what
    /// it wants (`purpose`) and sends what it is about (`input`: the words,
    /// the tone, your rules); the prompt is the server's (the Worker's
    /// prompts.ts). Dictated words go with the receipts of the last takes,
    /// so the server can tell they were heard. Answers the reply text.
    @discardableResult
    func chat(purpose: String, input: [String: Any], conversation: String? = nil,
              completion: @escaping (Result<String, CloudError>) -> Void) -> Cancellable {
        var body: [String: Any] = ["purpose": purpose, "input": input, "receipts": receipts.map(\.receipt)]
        // An agent voice call counts against the conversation it is for.
        if let conversation = conversation { body["conversation"] = conversation }
        return post("v1/chat", body) { result in
            switch result {
            case .failure(let e): completion(.failure(e))
            case .success(let json):
                guard let choices = json["choices"] as? [[String: Any]],
                      let message = choices.first?["message"] as? [String: Any],
                      let content = message["content"] as? String else {
                    return completion(.failure(.server(0, "bad_reply")))
                }
                completion(.success(content))
            }
        }
    }

    // MARK: Take receipts

    /// What the server heard in the last few cloud takes, signed: the words
    /// a model call is about must be one of these takes' (the Worker's
    /// receipt.ts), or it is refused before the model is asked. Opaque here,
    /// newest first; a take's receipt is renewed as its words come.
    private(set) var receipts: [(take: String, receipt: String)] = []

    func noteReceipt(take: String, receipt: String) {
        receipts.removeAll { $0.take == take }
        receipts.insert((take, receipt), at: 0)
        if receipts.count > 3 { receipts.removeLast(receipts.count - 3) }
    }

    /// A take that didn't go through our cloud (the developers' build on its
    /// own engines) has no receipt, and an older take's would vouch for the
    /// wrong words.
    func forgetReceipts() { receipts.removeAll() }

    // MARK: The agent voice

    /// What the agent voice may open: a conversation (counted — Free's
    /// ten, Pro's month, then bought ones), "Hear a sample", or a one-line
    /// reply outside a conversation ("Back on watch."). The last two are
    /// never counted; the server holds them to a few a day.
    enum AgentKind: String { case conversation, sample, line }

    fileprivate func adoptAgent(from json: [String: Any]) {
        if let a = json["agent"] as? [String: Any] { agent = AgentAllowance(a) }
    }

    /// Opens one with the server, which counts it. Answers its id, which
    /// every line spoken and every model call for it then carries; or
    /// .limitReached("agent") when none are left (the count comes back with
    /// it either way, and the Agents pane redraws).
    func startAgentConversation(_ kind: AgentKind, completion: @escaping (Result<String, CloudError>) -> Void) {
        post("v1/agent/start", ["kind": kind.rawValue]) { result in
            switch result {
            case .failure(let e): completion(.failure(e))
            case .success(let json):
                guard let id = json["conversation"] as? String else { return completion(.failure(.server(0, "bad_reply"))) }
                Config.shared.log("Cloud: agent \(kind.rawValue) \(id.prefix(11)) (\(json["source"] as? String ?? "?"))")
                completion(.success(id))
            }
        }
    }

    /// A line in the agent's voice, as a request the voice player streams
    /// (or, with stream: false, one whole clip for the cache of everyday
    /// lines). The server speaks it on its own key and takes its characters
    /// off the conversation. nil when there's no token to send.
    func speakRequest(conversation: String, text: String, voice: String, speed: Double?, stream: Bool = true,
                      completion: @escaping (URLRequest?) -> Void) {
        withAccessToken { result in
            DispatchQueue.main.async {
                guard case .success(let token) = result else { return completion(nil) }
                var req = URLRequest(url: Self.base.appendingPathComponent("v1/speak"), timeoutInterval: 15)
                req.httpMethod = "POST"
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                Self.nameMac(on: &req)
                var body: [String: Any] = ["conversation": conversation, "text": text, "voice": voice, "stream": stream]
                if let speed = speed { body["speed"] = speed }
                req.httpBody = try? JSONSerialization.data(withJSONObject: body)
                completion(req)
            }
        }
    }

    // MARK: Extra takes

    /// One of Free's extra takes: the whole clip, sent when you let go, to
    /// the server's upload model — no live words, and far cheaper than the
    /// live ear. Answers the text; the server's new count of extra takes
    /// comes back with it and moves the meter.
    func transcribeExtraTake(_ wav: Data, language: String, terms: [String],
                             completion: @escaping (Result<String, CloudError>) -> Void) {
        withAccessToken { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let e): completion(.failure(e))
            case .success(let token):
                var c = URLComponents(url: Self.base.appendingPathComponent("v1/transcribe"), resolvingAgainstBaseURL: false)!
                c.queryItems = [URLQueryItem(name: "language", value: language)]
                    + terms.prefix(80).map { URLQueryItem(name: "term", value: String($0.prefix(60))) }
                var req = URLRequest(url: c.url!, timeoutInterval: 40)
                req.httpMethod = "POST"
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                req.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
                Self.nameMac(on: &req)
                req.httpBody = wav
                self.session.dataTask(with: req) { data, resp, error in
                    DispatchQueue.main.async {
                        if let error = error { return completion(.failure(.transport(error))) }
                        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                        let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                        if let u = json["usage"] as? [String: Any], let usage = CloudUsage(u) {
                            self.usage = usage
                            NotificationCenter.default.post(name: .sayctrlAccountChanged, object: nil)
                        }
                        if (200..<300).contains(status), let text = json["text"] as? String {
                            if let take = json["take"] as? String, let receipt = json["receipt"] as? String {
                                self.noteReceipt(take: take, receipt: receipt)
                            }
                            return completion(.success(text))
                        }
                        let code = json["error"] as? String ?? "http_\(status)"
                        Config.shared.log("Cloud: POST /v1/transcribe → \(status) \(code)")
                        if code == "device_unverified" || code == "mac_refused" {
                            self.adoptDevice(code == "mac_refused" ? "refused" : "unverified")
                        }
                        if status == 402 { return completion(.failure(.limitReached("grace"))) }
                        completion(.failure(.server(status, code)))
                    }
                }.resume()
            }
        }
    }

    // MARK: The wire

    final class Cancellable {
        fileprivate var task: URLSessionTask?
        fileprivate var cancelled = false
        func cancel() { cancelled = true; task?.cancel() }
    }

    private func get(_ path: String, completion: @escaping (Result<[String: Any], CloudError>) -> Void) {
        send("GET", path, nil, auth: true, completion: completion)
    }

    @discardableResult
    private func post(_ path: String, _ body: [String: Any], auth: Bool = true,
                      completion: @escaping (Result<[String: Any], CloudError>) -> Void) -> Cancellable {
        send("POST", path, body, auth: auth, completion: completion)
    }

    /// One request, answered on the main queue. Signed calls fetch a token
    /// first; a 401 on a signed call refreshes once and tries again.
    @discardableResult
    private func send(_ method: String, _ path: String, _ body: [String: Any]?, auth: Bool, retried: Bool = false,
                      handle: Cancellable = Cancellable(),
                      completion: @escaping (Result<[String: Any], CloudError>) -> Void) -> Cancellable {
        let fire: (String?) -> Void = { [weak self] token in
            guard let self = self, !handle.cancelled else { return completion(.failure(.cancelled)) }
            var req = URLRequest(url: Self.base.appendingPathComponent(path))
            req.httpMethod = method
            if let token = token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            Self.nameMac(on: &req)
            if let body = body {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            }
            let task = self.session.dataTask(with: req) { data, resp, error in
                DispatchQueue.main.async {
                    if let error = error {
                        return completion(.failure((error as NSError).code == NSURLErrorCancelled ? .cancelled : .transport(error)))
                    }
                    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                    if path != "v1/me", json["agent"] != nil {
                        self.adoptAgent(from: json)
                        NotificationCenter.default.post(name: .sayctrlAccountChanged, object: nil)
                    }
                    if (200..<300).contains(status) { return completion(.success(json)) }
                    let code = json["error"] as? String ?? "http_\(status)"
                    if status == 401, auth, !retried {
                        // The token went stale between check and use.
                        self.accessExpiry = .distantPast
                        self.send(method, path, body, auth: auth, retried: true, handle: handle, completion: completion)
                        return
                    }
                    if status == 402, let usage = json["usage"] as? [String: Any] { self.usage = CloudUsage(usage) }
                    if status == 402 { return completion(.failure(.limitReached(json["allowance"] as? String ?? ""))) }
                    Config.shared.log("Cloud: \(method) /\(path) → \(status) \(code)")
                    if code == "device_unverified" || code == "mac_refused" {
                        self.adoptDevice(code == "mac_refused" ? "refused" : "unverified")
                    }
                    completion(.failure(.server(status, code)))
                }
            }
            handle.task = task
            task.resume()
        }
        guard auth else { fire(nil); return handle }
        withAccessToken { result in
            switch result {
            case .success(let token): fire(token)
            case .failure(let e): completion(.failure(e))
            }
        }
        return handle
    }

    // MARK: Helpers

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// RFC 7636's verifier: random bytes, base64url. The system generator is
    /// the kernel's CSPRNG on macOS.
    private static func randomURLSafe(_ bytes: Int) -> String {
        var rng = SystemRandomNumberGenerator()
        return base64url(Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max, using: &rng) }))
    }
}

/// The refresh token's home: the login Keychain, one generic password per
/// build (the dev app's service name is its own bundle id, so the two never
/// share a sign-in).
///
/// macOS lets an app read back the item it wrote while the app still meets
/// the same designated requirement, and a Developer ID's names the Team ID,
/// so an update reads its sign-in without a prompt.
///
/// The file tokens lived in before the Developer ID (cloud-<account> beside
/// the settings, 0600) is the fallback: a write the Keychain refuses (locked,
/// or a prompt answered Deny) lands there instead, because losing a rotated
/// refresh token signs the account out everywhere at the next launch. So a
/// file that exists is always the newest token: it is read first and moved
/// into the Keychain, and deleted once the Keychain holds it.
enum TokenStore {
    private static let service = "\(Config.bundleID).cloud"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func legacyFile(_ account: String) -> URL {
        Config.shared.dir.appendingPathComponent("cloud-\(account)")
    }

    static func read(_ account: String) -> String? {
        // The file first: when it exists it holds the newest token.
        let file = legacyFile(account)
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                if store(account, token) { try? FileManager.default.removeItem(at: file) }
                return token
            }
        }
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data,
           let token = String(data: data, encoding: .utf8), !token.isEmpty {
            return token
        }
        if status != errSecItemNotFound { Config.shared.log("Cloud: Keychain read failed (\(status))") }
        return nil
    }

    static func write(_ account: String, _ value: String) {
        if store(account, value) {
            try? FileManager.default.removeItem(at: legacyFile(account))
            return
        }
        // Refused by the Keychain: kept in the 0600 file, where read() looks
        // first, and moved in the next time the Keychain takes it.
        let file = legacyFile(account)
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try? Data(value.utf8).write(to: file)
        Config.shared.log("Cloud: sign-in kept in the fallback file — the Keychain refused it")
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
        try? FileManager.default.removeItem(at: legacyFile(account))
    }

    /// Updates the item in place, or adds it. Never synced to iCloud: a
    /// sign-in belongs to this Mac.
    @discardableResult
    private static func store(_ account: String, _ value: String) -> Bool {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(account) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else {
            Config.shared.log("Cloud: Keychain update failed (\(status))")
            return false
        }
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "SayControl sign-in"
        add[kSecAttrSynchronizable as String] = false
        let added = SecItemAdd(add as CFDictionary, nil)
        if added != errSecSuccess { Config.shared.log("Cloud: Keychain add failed (\(added))") }
        return added == errSecSuccess
    }
}
