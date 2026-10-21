// Asks the browser you're looking at for its current tab's address, so
// "copy the link" knows what you mean.
//
// Same shape as FinderPaths: one Apple Events question through
// /usr/bin/osascript. Safari and the whole Chromium family (Chrome, Arc,
// Brave, Edge, Vivaldi, Opera) all answer it; Firefox and its forks have
// no scripting dictionary for tabs, so they get a clear "can't" instead
// of a wrong guess. First use per browser shows the one-time "SayCtrl wants
// to control …" consent (NSAppleEventsUsageDescription in Info.plist).
import AppKit
import ApplicationServices

/// Asks TCC how the Automation grant for one target app stands, without
/// prompting — the Permissions pane's status dots. 0 granted, -1744 not
/// asked yet, -1743 denied, -600 target not running (TCC can only answer
/// for a live process).
enum Automation {
    static func status(for bundleID: String) -> OSStatus {
        let desc = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        return AEDeterminePermissionToAutomateTarget(
            desc.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
    }

    /// The same question, asked out loud: Apple's "SayCtrl wants access to
    /// control …" dialog, when it has never been shown for this target. It
    /// is what puts SayCtrl in the Automation list at all — that pane only
    /// lists apps that have asked, and takes no dragged-in icon. The call
    /// blocks on the dialog, so it runs off the main thread; the answer
    /// lands back on main. A grant refused before cannot be asked again,
    /// only switched on in the pane.
    static func request(_ bundleID: String, done: @escaping (OSStatus) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let desc = NSAppleEventDescriptor(bundleIdentifier: bundleID)
            let r = AEDeterminePermissionToAutomateTarget(
                desc.aeDesc, AEEventClass(typeWildCard), AEEventID(typeWildCard), true)
            DispatchQueue.main.async { done(r) }
        }
    }
}

enum BrowserURL {

    enum Issue: Error {
        case noBrowser              // no scriptable browser running at all
        case ambiguous              // several browsers, none of them in front
        case unsupported(String)    // the browser you're in can't be asked (Firefox…)
        case noTab                  // browser answered, but no window or a blank tab
        case notAuthorized(String)  // the Automation grant is missing or denied (-1743)
        case failed(String)         // anything else — timeout, odd reply…
    }

    private struct Browser {
        let name: String   // for HUD messages ("Let SayCtrl control Chrome")
        let tab: String    // how its dictionary names the frontmost tab
    }

    /// AppleScript-savvy browsers by bundle id. Safari says "current tab";
    /// Chromium descendants — Arc included — all say "active tab".
    private static let scriptable: [String: Browser] = [
        "com.apple.Safari":                  Browser(name: "Safari", tab: "current tab"),
        "com.apple.SafariTechnologyPreview": Browser(name: "Safari", tab: "current tab"),
        "com.google.Chrome":                 Browser(name: "Chrome", tab: "active tab"),
        "com.google.Chrome.beta":            Browser(name: "Chrome", tab: "active tab"),
        "com.google.Chrome.canary":          Browser(name: "Chrome", tab: "active tab"),
        "org.chromium.Chromium":             Browser(name: "Chromium", tab: "active tab"),
        "company.thebrowser.Browser":        Browser(name: "Arc", tab: "active tab"),
        "com.brave.Browser":                 Browser(name: "Brave", tab: "active tab"),
        "com.brave.Browser.beta":            Browser(name: "Brave", tab: "active tab"),
        "com.brave.Browser.nightly":         Browser(name: "Brave", tab: "active tab"),
        "com.microsoft.edgemac":             Browser(name: "Edge", tab: "active tab"),
        "com.vivaldi.Vivaldi":               Browser(name: "Vivaldi", tab: "active tab"),
        "com.operasoftware.Opera":           Browser(name: "Opera", tab: "active tab"),
        "com.operasoftware.OperaGX":         Browser(name: "Opera GX", tab: "active tab"),
    ]

    /// Browsers we recognise but cannot ask — no tab scripting at all.
    private static let mute: [String: String] = [
        "org.mozilla.firefox":                 "Firefox",
        "org.mozilla.firefoxdeveloperedition": "Firefox",
        "org.mozilla.nightly":                 "Firefox",
        "app.zen-browser.zen":                 "Zen",
    ]

    /// Fresh-tab placeholders that would paste as noise, not a link.
    private static func isBlankPage(_ url: String) -> Bool {
        url.isEmpty || url == "missing value" || url == "about:blank"
            || url == "favorites://" || url.contains("://newtab")
            || url.contains("://new-tab-page")
    }

    /// Which browser did you mean? The one you're in; failing that, the
    /// front-most browser window on this Space (dictating into a terminal
    /// with Chrome behind it still works); failing that, the only browser
    /// running. Never guesses between several — a wrong link pasted into a
    /// message is worse than a HUD shrug.
    private static func pickTarget() -> Result<(id: String, browser: Browser), Issue> {
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            if let b = scriptable[front] { return .success((front, b)) }
            if let name = mute[front] { return .failure(.unsupported(name)) }
        }
        let onScreen = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in onScreen {   // front-to-back order
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? Int,
                  let id = NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier
            else { continue }
            if let b = scriptable[id] { return .success((id, b)) }
            if let name = mute[id] { return .failure(.unsupported(name)) }
        }
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        let candidates = running.filter { scriptable[$0] != nil }
        if candidates.count == 1, let only = candidates.first {
            return .success((only, scriptable[only]!))
        }
        if candidates.count > 1 { return .failure(.ambiguous) }
        if let muted = running.first(where: { mute[$0] != nil }) {
            return .failure(.unsupported(mute[muted]!))
        }
        return .failure(.noBrowser)
    }

    /// Any browser we know of, scriptable or not — the ask command uses
    /// this to notice the default browser actually coming forward.
    static func isBrowser(_ bundleID: String) -> Bool {
        scriptable[bundleID] != nil || mute[bundleID] != nil
    }

    /// For the Permissions pane: every scriptable browser running right
    /// now, deduped by display name (Chrome beta counts as Chrome).
    static func runningScriptableBrowsers() -> [(name: String, bundleID: String)] {
        var seen = Set<String>()
        var out: [(name: String, bundleID: String)] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, let b = scriptable[id],
                  seen.insert(b.name).inserted else { continue }
            out.append((b.name, id))
        }
        return out.sorted { $0.name < $1.name }
    }

    /// Sample the current tab's URL now, off the main thread; completion
    /// lands back on main. The target browser is chosen on the calling
    /// thread first — what you meant is the browser in front NOW, not
    /// whichever is in front when osascript gets around to answering.
    static func sample(_ completion: @escaping (Result<String, Issue>) -> Void) {
        let target: (id: String, browser: Browser)
        switch pickTarget() {
        case .failure(let issue): return DispatchQueue.main.async { completion(.failure(issue)) }
        case .success(let t): target = t
        }
        // Targeting by bundle id survives renamed apps. The target is
        // already running (that's how it was found), so `tell` won't
        // launch anything.
        let script = """
        tell application id "\(target.id)"
            if (count of windows) is 0 then return ""
            return URL of \(target.browser.tab) of front window as text
        end tell
        """
        DispatchQueue.global(qos: .userInitiated).async {
            func finish(_ r: Result<String, Issue>) { DispatchQueue.main.async { completion(r) } }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            let outPipe = Pipe(), errPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = errPipe
            do { try p.run() } catch {
                return finish(.failure(.failed(error.localizedDescription)))
            }
            // The first call per browser can sit on the system's consent
            // dialog for a while — give the user time, never hang a paste.
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: killer)
            let out = outPipe.fileHandleForReading.readDataToEndOfFile()
            let err = errPipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            killer.cancel()
            guard p.terminationStatus == 0 else {
                let msg = (String(data: err, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if msg.contains("-1743") || msg.localizedCaseInsensitiveContains("not authorized") {
                    return finish(.failure(.notAuthorized(target.browser.name)))
                }
                // -1728: the front window has no tab to ask (rare, e.g. a
                // devtools or picture-in-picture window in front).
                if msg.contains("-1728") { return finish(.failure(.noTab)) }
                return finish(.failure(.failed(msg.isEmpty ? "\(target.browser.name) didn't answer" : msg)))
            }
            let url = (String(data: out, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !isBlankPage(url) else { return finish(.failure(.noTab)) }
            finish(.success(url))
        }
    }
}
