// Where the paste is headed — the front app, sorted into one of the four tone
// contexts (Tones.swift) plus one that isn't a tone at all.
//
// This file answers "where", Tones.swift answers "how". The front app picks
// the context (Slack → work, Mail → email, Terminal → agents) and names the
// kind of place it is ("a work message", "a document"); the tone you chose for
// that context supplies the rules. They meet in one line appended to the
// polish prompt: "Slack, a work message: keep it brief and plain — …". A style
// can only ever steer punctuation, casing and layout; the guardrails that stop
// the model adding or changing words are untouched.
//
// Code editors are the one place with no tone to pick: Xcode and VS Code are
// left strictly alone, and that shouldn't be switchable.
//
// The front app is captured when recording starts — that is the app the
// paste is headed for. A browser is whatever site its front tab shows, but
// the tab is only asked for when the Automation grant already exists:
// a consent dialog popping mid-dictation would be worse than a generic tone.
import Cocoa

enum AppStyle {

    /// A place to paste into: one of the tone contexts, or code — which takes
    /// no tone. `kind` names the place in the model's own terms ("an email",
    /// "a document"), so the same Work tone reads right in Slack and in Pages.
    enum Target {
        case tone(ToneContext, kind: String)
        case code
    }

    /// Where the paste is headed and how that place should read, or nil when
    /// the front app wants no special treatment. Calls back on the main queue,
    /// usually synchronously — only the browser-tab question leaves the process.
    static func capture(_ completion: @escaping (ToneHint?) -> Void) {
        guard Config.shared.refineStyle,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return completion(nil)
        }
        let bundleID = app.bundleIdentifier ?? ""
        let name = app.localizedName ?? "the app"
        if let target = target(bundleID: bundleID.lowercased(), appName: name) {
            return completion(hint(for: target, appName: name))
        }
        if BrowserURL.isBrowser(bundleID), Automation.status(for: bundleID) == 0 {
            return BrowserURL.sample { result in
                guard case .success(let url) = result,
                      let target = target(url: url) else { return completion(nil) }
                completion(hint(for: target, appName: siteName(url) ?? name))
            }
        }
        completion(nil)
    }

    /// app + kind on one side, the chosen tone's rules on the other.
    static func hint(for target: Target, appName: String) -> ToneHint {
        switch target {
        case .code:
            return ToneOption.codeHint(appName)
        case .tone(let context, let kind):
            let tone = Tones.option(for: context)
            return ToneHint(place: "\(appName), \(kind)", rules: tone.rules,
                            bullets: tone.bullets, shots: tone.shots,
                            wire: ["context": context.rawValue, "id": tone.id, "app": appName, "kind": kind])
        }
    }

    // MARK: - App → context

    private static func target(bundleID id: String, appName: String) -> Target? {
        func any(_ needles: [String]) -> Bool { needles.contains { id.contains($0) } }
        // Apps that hide behind generic packager bundle ids (Cursor is
        // "com.todesktop.…") are recognised by their visible name instead.
        let nameKey = appName.lowercased()
        if ["cursor", "windsurf", "zed", "warp", "ghostty", "claude", "chatgpt",
            "msty", "lm studio"].contains(nameKey) {
            return .tone(.agents, kind: agentKind(nameKey))
        }
        if any(["com.apple.mail", "outlook", "readdle.smartemail", "superhuman",
                "mimestream", "missive", "canarymail", "loop.email", "airmail",
                "postbox", "thunderbird"]) {
            return .tone(.email, kind: "an email")
        }
        // Agent surfaces before the terminals and editors they live inside:
        // a terminal is where Claude Code and Codex read, so it takes the
        // agent tone (which keeps the same ASCII rules code would have).
        if any(["openai.chat", "anthropic.claude", "perplexity", "poe.com",
                "com.google.gemini", "quora.poe", "msty", "lmstudio"]) {
            return .tone(.agents, kind: "a prompt for an AI assistant")
        }
        if any(["apple.terminal", "iterm", "alacritty", "kitty", "wezterm",
                "hyper", "tabby", "termius"]) {
            return .tone(.agents, kind: "a terminal prompt")
        }
        if any(["mobilesms", "whatsapp", "telegram", "signal", "discord",
                "messenger", "viber", "wechat", "beeper", "texts.com"]) {
            return .tone(.personal, kind: "a personal message")
        }
        if any(["slack", "teams2", "teams", "linear", "atlassian", "jira",
                "asana", "clickup", "basecamp"]) {
            return .tone(.work, kind: "a work message")
        }
        // Notes you keep for yourself read like you, not like the office.
        if any(["apple.notes", "shinyfrog.bear", "obsidian", "dayoneapp",
                "apple.journal", "simplenote"]) {
            return .tone(.personal, kind: "a note")
        }
        if any(["notion", "craft", "coda", "confluence", "typora", "iawriter",
                "ulysses", "scrivener", "apple.iwork.pages", "microsoft.word",
                "textedit", "quip"]) {
            return .tone(.work, kind: "a document")
        }
        if any(["xcode", "vscode", "visualstudio", "sublimetext", "jetbrains",
                "intellij", "pycharm", "webstorm", "goland", "clion", "rider",
                "androidstudio", "panic.nova", "barebones", "emacs", "neovide"]) {
            return .code
        }
        return nil
    }

    /// A terminal an agent runs in and an AI chat app want the same tone but
    /// read as different places — the model is told which it is.
    private static func agentKind(_ nameKey: String) -> String {
        switch nameKey {
        case "warp", "ghostty":                     return "a terminal prompt"
        case "cursor", "windsurf", "zed":           return "an AI coding assistant"
        default:                                    return "a prompt for an AI assistant"
        }
    }

    // MARK: - Front tab → context

    /// The front tab decides: Gmail is an email no matter that Chrome hosts it.
    private static func target(url: String) -> Target? {
        guard let host = URL(string: url)?.host?.lowercased() else { return nil }
        func has(_ s: String) -> Bool { host.contains(s) }
        if has("mail.google") || has("outlook.live") || has("outlook.office")
            || has("mail.proton") || has("mail.yahoo") || has("fastmail")
            || has("mail.zoho") || has("superhuman") || has("app.hey.com") {
            return .tone(.email, kind: "an email")
        }
        if has("chatgpt.com") || has("chat.openai") || has("claude.ai")
            || has("gemini.google") || has("aistudio.google") || has("perplexity.ai")
            || has("copilot.microsoft") || has("poe.com") || has("grok.com")
            || has("chat.mistral") || has("chat.deepseek") || has("t3.chat")
            || has("openrouter.ai") {
            return .tone(.agents, kind: "a prompt for an AI assistant")
        }
        if has("slack.com") || has("teams.microsoft") || has("linear.app")
            || has("atlassian.net") || has("asana.com") || has("app.clickup") {
            return .tone(.work, kind: "a work message")
        }
        if has("discord.com") || has("web.whatsapp") || has("web.telegram")
            || has("messenger.com") || has("chat.google") {
            return .tone(.personal, kind: "a personal message")
        }
        if has("docs.google") || has("notion.s") || has("notion.so")
            || has("coda.io") || has("quip.com") || has("confluence") {
            return .tone(.work, kind: "a document")
        }
        return nil
    }

    /// "mail.google.com" → "Gmail" and friends: the site is the place, not the
    /// browser hosting it, and a name the model recognises steers better than
    /// a bare hostname.
    private static func siteName(_ url: String) -> String? {
        guard let host = URL(string: url)?.host?.lowercased() else { return nil }
        let known: [(String, String)] = [
            ("mail.google", "Gmail"), ("outlook.", "Outlook"), ("mail.proton", "Proton Mail"),
            ("fastmail", "Fastmail"), ("superhuman", "Superhuman"),
            ("chatgpt.com", "ChatGPT"), ("chat.openai", "ChatGPT"), ("claude.ai", "Claude"),
            ("gemini.google", "Gemini"), ("perplexity", "Perplexity"),
            ("slack.com", "Slack"), ("teams.microsoft", "Teams"), ("linear.app", "Linear"),
            ("discord.com", "Discord"), ("web.whatsapp", "WhatsApp"),
            ("docs.google", "Google Docs"), ("notion.s", "Notion"), ("notion.so", "Notion"),
        ]
        if let hit = known.first(where: { host.contains($0.0) }) { return hit.1 }
        // Strip "www." and the TLD: "figma.com" → "figma".
        let parts = host.replacingOccurrences(of: "www.", with: "").split(separator: ".")
        return parts.count >= 2 ? String(parts[parts.count - 2]) : nil
    }
}
