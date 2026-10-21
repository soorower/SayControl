// Resolves "open <something>": the short list of names everyone means,
// then whatever is installed on this Mac, then a spoken domain
// ("reqkey.com"). Nothing else — an unknown name is not a command, so
// the words stay ordinary text. Executing is one NSWorkspace call.
import AppKit

enum OpenTarget {

    enum Resolution {
        case app(URL, String)   // bundle to launch + name for the HUD
        case web(URL, String)   // page to open + name for the HUD
    }

    /// Known names, spoken form → Mac-app bundle ids (tried first, in
    /// order) and the site that stands in when no app is installed.
    /// Web-only names have no ids. Cleaned keys only — see normalize().
    private static let curated: [String: (ids: [String], web: String)] = [
        "chatgpt":         (["com.openai.chat"], "https://chatgpt.com"),
        "claude":          (["com.anthropic.claudefordesktop"], "https://claude.ai"),
        "grok":            (["ai.x.grok", "com.x.grok"], "https://grok.com"),
        "perplexity":      (["ai.perplexity.mac", "ai.perplexity.PerplexityMac"], "https://www.perplexity.ai"),
        "gemini":          ([], "https://gemini.google.com"),
        "copilot":         ([], "https://copilot.microsoft.com"),
        "google":          ([], "https://www.google.com"),
        "gmail":           ([], "https://mail.google.com"),
        "google docs":     ([], "https://docs.google.com"),
        "google drive":    ([], "https://drive.google.com"),
        "google maps":     ([], "https://maps.google.com"),
        "maps":            (["com.apple.Maps"], "https://maps.google.com"),
        "google calendar": ([], "https://calendar.google.com"),
        "youtube":         ([], "https://www.youtube.com"),
        "facebook":        ([], "https://www.facebook.com"),
        "instagram":       ([], "https://www.instagram.com"),
        "twitter":         ([], "https://x.com"),
        "x":               ([], "https://x.com"),
        "reddit":          ([], "https://www.reddit.com"),
        "linkedin":        ([], "https://www.linkedin.com"),
        "tiktok":          ([], "https://www.tiktok.com"),
        "netflix":         ([], "https://www.netflix.com"),
        "amazon":          ([], "https://www.amazon.com"),
        "wikipedia":       ([], "https://www.wikipedia.org"),
        "pinterest":       ([], "https://www.pinterest.com"),
        "github":          ([], "https://github.com"),
        "stack overflow":  ([], "https://stackoverflow.com"),
        "stackoverflow":   ([], "https://stackoverflow.com"),
        "whatsapp":        (["net.whatsapp.WhatsApp"], "https://web.whatsapp.com"),
        "telegram":        (["ru.keepcoder.Telegram", "org.telegram.desktop"], "https://web.telegram.org"),
        "messenger":       (["com.facebook.archon"], "https://www.messenger.com"),
        "discord":         (["com.hnc.Discord"], "https://discord.com/channels/@me"),
        "slack":           (["com.tinyspeck.slackmacgap"], "https://app.slack.com/client"),
        "spotify":         (["com.spotify.client"], "https://open.spotify.com"),
        "notion":          (["notion.id"], "https://www.notion.so"),
        "figma":           (["com.figma.Desktop"], "https://www.figma.com"),
        "finder":          (["com.apple.finder"], "https://support.apple.com/guide/mac-help/mchlp2605/mac"),
    ]

    /// Names whose capitalization .capitalized gets wrong in the HUD.
    private static let brandNames: [String: String] = [
        "chatgpt": "ChatGPT", "youtube": "YouTube", "tiktok": "TikTok",
        "linkedin": "LinkedIn", "github": "GitHub", "whatsapp": "WhatsApp",
    ]

    /// Words that carry no aim: "open the Arc browser app, please" → "arc".
    private static let filler: Set<String> =
        ["the", "a", "an", "my", "up", "app", "application", "browser",
         "website", "web", "site", "page", "please"]

    /// The recognizer's usual misses, applied after filler stripping.
    private static let mishearings: [String: String] = [
        "cloud": "claude", "chat gbt": "chatgpt", "chatgbt": "chatgpt",
        "chat gpt": "chatgpt", "chat g p t": "chatgpt",
        "grock": "grok", "groc": "grok",
    ]

    static func normalize(_ spoken: String) -> String {
        var s = spoken.lowercased()
            .replacingOccurrences(of: " dot ", with: ".")
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        s = s.split(separator: " ").filter { !filler.contains(String($0)) }.joined(separator: " ")
        return mishearings[s] ?? s
    }

    /// The ladder: known name (its app first, its site second) → installed
    /// app → spoken domain. Never a guessed domain, never a search —
    /// nil means "not a name we know", and the words stay text.
    static func resolve(_ spoken: String) -> Resolution? {
        let cleaned = normalize(spoken)
        if let entry = curated[cleaned] {
            for id in entry.ids {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                    return .app(url, appName(url))
                }
            }
            if let url = URL(string: entry.web) {
                return .web(url, brandNames[cleaned] ?? cleaned.capitalized)
            }
        }
        if let (url, name) = installedApp(cleaned) { return .app(url, name) }
        // A spoken domain opens exactly domain.tld — "reqkey.com right
        // now" opens reqkey.com and everything past the domain is ignored.
        if let first = cleaned.split(separator: " ").first.map(String.init),
           first.range(of: "^[a-z0-9][a-z0-9-]*(\\.[a-z0-9-]+)*\\.[a-z]{2,}$",
                       options: .regularExpression) != nil,
           let url = URL(string: "https://\(first)") {
            return .web(url, first)
        }
        return nil
    }

    /// "open club", "open closed": the recognizer had the sounds and not the
    /// spelling. With "open" being the WHOLE utterance there is nothing else
    /// the words could be — pasting "Open club." helps no one — so the name
    /// is matched by sound against the apps actually on this Mac and the
    /// curated sites: same opening consonant, and the consonant skeleton
    /// close enough ("clb" → "cld" for Claude), with no near-tie. Anything
    /// less stays nil, and the words stay text. Only ever called for a bare
    /// "open …"; a name inside a sentence is never guessed at.
    static func resolveBySound(_ spoken: String) -> (Resolution, String)? {
        let cleaned = normalize(spoken)
        guard !cleaned.isEmpty, cleaned.count <= 24 else { return nil }
        var names: [String: () -> Resolution?] = [:]
        for (key, _) in curated { names[key] = { resolve(key) } }
        for dir in appDirs {
            for item in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            where item.hasSuffix(".app") {
                let name = String(item.dropLast(4))
                let url = URL(fileURLWithPath: dir).appendingPathComponent(item)
                names[name.lowercased()] = { .app(url, name) }
                // "Google Chrome" is said as "Chrome": a word of a long name
                // answers for it when it is a name people say (favoured) and
                // no app owns it outright. Not every word — "Player" from
                // QuickTime Player would catch "plot".
                let words = name.lowercased().split(separator: " ").map(String.init)
                if words.count > 1 {
                    for w in words where favoured.contains(w) && names[w] == nil { names[w] = { .app(url, name) } }
                }
            }
        }
        let heard = skeleton(cleaned)
        guard heard.count >= 2 else { return nil }
        var best: (name: String, score: Double)?
        var runnerUp = 0.0
        for name in names.keys {
            let sk = skeleton(name)
            guard sk.first == heard.first, sk.count >= 2 else { continue }
            // The names people say to SayCtrl get a little credit: "club"
            // sits between Claude and Clock by sound, and it is Claude that
            // gets asked for.
            let score = similarity(heard, sk) + (favoured.contains(name) ? 0.1 : 0)
            if best == nil || score > best!.score {
                if let b = best { runnerUp = max(runnerUp, b.score) }
                best = (name, score)
            } else {
                runnerUp = max(runnerUp, score)
            }
        }
        guard let hit = best, hit.score >= 0.65, hit.score - runnerUp >= 0.08,
              let resolution = names[hit.name]?() else { return nil }
        return (resolution, hit.name)
    }

    /// The curated names plus the apps "open …" is usually aimed at.
    private static let favoured: Set<String> = Set(curated.keys).union([
        "chrome", "safari", "arc", "cursor", "xcode", "vs code", "visual studio code",
        "terminal", "iterm", "warp", "zoom", "mail", "messages", "notes", "calendar",
    ])

    private static let appDirs = ["/Applications", "/Applications/Utilities",
                                  "/System/Applications", "/System/Applications/Utilities",
                                  NSHomeDirectory() + "/Applications"]

    /// The consonants of a name, in order, the opening letter kept whatever
    /// it is — the part of a word the recognizer gets right when it gets the
    /// vowels wrong. Doubled letters collapse; the common two-letter sounds
    /// become one.
    private static func skeleton(_ s: String) -> String {
        var t = s.lowercased()
        for (a, b) in [("ck", "k"), ("ph", "f"), ("gh", ""), ("wh", "w"), ("qu", "k"), ("x", "ks")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        var out = ""
        for (i, ch) in t.enumerated() {
            guard ch.isLetter || ch.isNumber else { continue }
            if i > 0, "aeiouy".contains(ch) { continue }
            if let last = out.last, last == ch { continue }
            out.append(ch)
        }
        return out
    }

    /// 1 − (edit distance ÷ longer length).
    private static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }

    private static func appName(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    /// Case-insensitive search of the usual app folders: exact name beats
    /// prefix beats contains ("chrome" → Google Chrome), shorter name
    /// breaks ties ("code" → Xcode over Visual Studio Code).
    private static func installedApp(_ cleaned: String) -> (URL, String)? {
        guard !cleaned.isEmpty else { return nil }
        var best: (score: Int, len: Int, url: URL, name: String)?
        for dir in appDirs {
            for item in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            where item.hasSuffix(".app") {
                let name = String(item.dropLast(4))
                let low = name.lowercased()
                let score: Int
                if low == cleaned { score = 0 }
                else if low.hasPrefix(cleaned) { score = 1 }
                else if low.contains(cleaned) { score = 2 }
                else { continue }
                if best == nil || (score, low.count) < (best!.score, best!.len) {
                    best = (score, low.count, URL(fileURLWithPath: dir).appendingPathComponent(item), name)
                }
            }
        }
        return best.map { ($0.url, $0.name) }
    }
}
