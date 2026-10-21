// The spoken-command grammar: spots "take a screenshot", "copy the file
// path", "copy the link" and "ask ChatGPT …" inside a dictation and splits
// the transcript into the text runs around each command, in spoken order.
// Whole-utterance meta commands ("scratch that", "send it", "use the local
// model") live here too, as metaCommand().
// Pure string work — no AppKit — so the grammar can be exercised on its own.
import Foundation

/// A command spotted inside a dictation, sitting between two text runs.
enum SpokenCommand: Equatable {
    case screenshot   // paste a picture of the cursor's screen
    case filePath     // paste the Finder selection's path(s)
    case pageURL      // paste the frontmost browser tab's address
}

/// Where an "ask …" command can send its question. Each site publishes a
/// prefill link — the same one the "ask ChatGPT" buttons around the web
/// use. ChatGPT and Perplexity submit it on arrival; Claude and Grok land
/// with the composer filled, one Enter from sent (their choice, not ours).
enum AIService: CaseIterable, Equatable {
    case chatgpt, claude, grok, perplexity, google

    var displayName: String {
        switch self {
        case .chatgpt:    return "ChatGPT"
        case .claude:     return "Claude"
        case .grok:       return "Grok"
        case .perplexity: return "Perplexity"
        case .google:     return "Google"
        }
    }

    /// The recognizer's spellings of the name. The grammar bounds these
    /// with a word break, so "Cloudflare" never counts as Claude.
    var spoken: String {
        switch self {
        case .chatgpt:    return "chat\\s*g\\.?\\s*[pb]\\.?\\s*t\\.?"   // "ChatGPT", "chat g p t", "chat GBT"
        case .claude:     return "claude|cloud"                          // "cloud" is the usual mishearing
        case .grok:       return "gro[ck]k?"                             // "Grok", "grock", "groc"
        case .perplexity: return "perplexity"
        case .google:     return "google"
        }
    }

    private var homepage: String {
        switch self {
        case .chatgpt:    return "https://chatgpt.com"
        case .claude:     return "https://claude.ai"
        case .grok:       return "https://grok.com"
        case .perplexity: return "https://www.perplexity.ai"
        case .google:     return "https://www.google.com"
        }
    }

    /// The prefill link; an empty question opens the site's front door.
    func url(for question: String) -> URL {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, var comps = URLComponents(string: homepage) else {
            return URL(string: homepage)!
        }
        switch self {
        case .claude:     comps.path = "/new"
        case .perplexity: comps.path = "/search"
        case .google:     comps.path = "/search"
        case .chatgpt, .grok: break
        }
        comps.queryItems = [URLQueryItem(name: "q", value: q)]
        return comps.url ?? URL(string: homepage)!
    }
}

/// An "ask <service> <question>" spotted at the tail of a dictation.
struct AskCommand: Equatable {
    let service: AIService
    let question: String
}

/// What kind of file "attach the …" is hunting for. .folder attaches a
/// directory itself ("upload the Redfin folder from the ideas folder").
enum AttachKind: Equatable {
    case image, screenshot, pdf, video, text, markdown, folder, any

    var extensions: Set<String> {
        switch self {
        case .image, .screenshot: return ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff", "bmp"]
        case .pdf:      return ["pdf"]
        case .video:    return ["mov", "mp4", "m4v", "avi", "mkv", "webm"]
        case .text:     return ["txt", "text", "rtf"]
        case .markdown: return ["md", "markdown"]
        case .folder:   return []
        case .any:      return []
        }
    }

    var noun: String {
        switch self {
        case .image:      return "image"
        case .screenshot: return "screenshot"
        case .pdf:        return "PDF"
        case .video:      return "video"
        case .text:       return "text file"
        case .markdown:   return "Markdown file"
        case .folder:     return "folder"
        case .any:        return "file"
        }
    }
}

/// "attach the (second)? (payout)? PDF (from downloads)?" — ordinal counts
/// from the newest, the fragment narrows by filename, no folder means
/// "what Finder is showing". The same shape drives "copy the … path"
/// queries — only the delivery differs: the file itself, or its path as
/// text at the cursor.
struct AttachCommand: Equatable {
    enum Delivery { case attachment, path }
    let kind: AttachKind
    let ordinal: Int?      // 1 = newest
    let folder: String?    // spoken folder word(s), already lowercased
    let fragment: String?  // filename fragment ("payout"), lowercased
    var parent: String? = nil     // "…folder IN DESKTOP" — where the folder lives
    var delivery: Delivery = .attachment
}

/// "open terminal in the downloads folder" — a terminal, opened already
/// standing in the folder you named. `app` is the terminal spoken for
/// ("iterm", "ghostty"); nil means the plain word "terminal" and whatever
/// this Mac calls that. Which folder the name means is FolderSearch's
/// question — the grammar only cuts the words.
struct TerminalCommand: Equatable {
    let app: String?       // spoken terminal name, lowercased; nil = "terminal"
    /// The folder named, lowercased. nil is the "here" form ("open terminal
    /// here", "…in this folder") — whatever Finder is showing.
    let folder: String?
    var parent: String?    // "…the stocks folder IN DESKTOP" — where it lives
}

/// How much of the last paste "scratch that" takes back.
enum ScratchScope: Equatable {
    case all       // the whole last dictation
    case sentence  // just its last sentence
}

/// A command about SayCtrl itself — take back the last paste, press Return,
/// switch the transcription model. These act on the app instead of pasting
/// words, so they only fire when the utterance is JUST the command: said
/// inside a dictation they stay ordinary text.
enum MetaCommand: Equatable {
    case scratch(ScratchScope)  // backspace over the last paste (or its last sentence)
    case send                   // press Return in the focused app
    case useLocalModel          // switch transcription to the local server
    case usePaidModel           // switch back to the paid provider
}

enum Commands {

    /// The spoken controls — screenshot, file path, page URL, attach, path
    /// query, open, terminal and ask — are Pro's. Off, every one of their
    /// splitters finds nothing, so the words paste as said. Set from the
    /// plan when a take starts rather than read per call: the live checks
    /// run on every word the stream sends, and the plan lives in a file.
    /// Scratch that, send it and the picker's replies aren't gated: they
    /// edit the dictation, they don't reach outside it.
    static var controlsOn = true

    /// Whether `text` asks for a control — for saying "that's Pro" when
    /// the controls are off and the words would have been one.
    static func wouldControl(_ text: String) -> Bool {
        let was = controlsOn
        controlsOn = true
        defer { controlsOn = was }
        return segment(text) != nil || splitAsk(text) != nil || splitOpen(text) != nil
            || splitTerminal(text) != nil || splitAttach(text) != nil || splitPathQuery(text) != nil
    }

    /// Say a command anywhere in a dictation — start, end, or as its own
    /// sentence in the middle — and its result lands in the spot you said
    /// it. A mid-sentence MENTION ("the screenshot looks wrong", "say take
    /// a screenshot") stays ordinary text: the middle form only fires as
    /// its own clause, right after punctuation.

    /// Separators inside a phrase are \s* throughout: live recognizers
    /// sometimes fuse the words ("copyfilepath", "takeascreenshot").
    static let screenshotPhrase =
        "(?:take|grab|capture)\\s*(?:a\\s*|the\\s*|another\\s*|one\\s*more\\s*)?screen\\s*shots?" +
        // short "of/on this second page"-style tail: preposition + determiner + up to 3 words
        "(?:\\s+(?:of|on|at|from|in)\\s+(?:this|that|the|my)(?:\\s+[\\w'’-]+){0,3})?" +
        "|screen\\s*shots?\\s+(?:of\\s+)?this(?:\\s+(?:page|screen|window|tab))?"

    /// "copy/insert/paste/grab the (file/folder('s)) path(s)". The verb
    /// list is deliberately short — "get the path from the config" is
    /// something you might dictate AT an AI, not a SayCtrl command.
    static let pathPhrase =
        "(?:copy|insert|paste|grab)\\s*(?:the\\s*|this\\s*|that\\s*|its\\s*|my\\s*)?" +
        "(?:current\\s*|full\\s*|selected\\s*)?(?:files?|folders?|director(?:y|ies))?(?:['’]s)?\\s*paths?" +
        // "of this folder"-style tail, kept narrow so "of the config file" stays text
        "(?:\\s+(?:of|for|to)\\s+(?:this|that|it|them|the\\s+selected)(?:\\s+[\\w'’-]+){0,2})?"

    /// "copy/insert/paste/grab/attach the (website/page/tab('s)) URL/link".
    /// "address" only counts with a web word in front ("the web address"),
    /// so a dictated street address stays text. Recognizers write URL as
    /// "URL", "url" or "u.r.l." — the letter form tolerates dots/spaces.
    static let urlPhrase =
        "(?:copy|insert|paste|grab|attach)\\s*(?:the\\s*|this\\s*|that\\s*|its\\s*|my\\s*)?(?:current\\s*)?" +
        "(?:(?:web\\s*site|website|web\\s*page|page|tab|site|browser|web)(?:['’]s)?\\s*)?" +
        "(?:u\\s*\\.?\\s*r\\s*\\.?\\s*l\\s*\\.?s?|links?)" +
        // "of this page"-style tail, narrow so "the link in the README" stays text
        "(?:\\s+(?:of|for|from|to)\\s+(?:this|that|it|the\\s+current)(?:\\s+[\\w'’-]+){0,2})?" +
        "|(?:copy|insert|paste|grab|attach)\\s*(?:the\\s*|this\\s*|that\\s*)?(?:current\\s*)?" +
        "(?:web\\s*site|website|web\\s*page|page|site|tab|web)(?:['’]s)?\\s*address(?:es)?" +
        "(?:\\s+(?:of|for|from)\\s+(?:this|that|it|the\\s+current)(?:\\s+[\\w'’-]+){0,2})?"

    /// The words (before, after) around the FIRST occurrence of a command
    /// family in `text`, or nil when the family isn't there. `bare` lists
    /// extra forms so short they only count when the whole utterance is
    /// just the command ("Screenshot.", "File path.").
    static func split(_ text: String, phrase: String, bare: String? = nil)
        -> (before: String, after: String)? {
        let pad = "[\\s,.!?;:…\\-—]*"
        let ns = text as NSString
        func match(_ pattern: String) -> NSRange? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
            return re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))?.range
        }
        // Dangling commas go; sentence-enders (.!?) stay with their sentence.
        func tidyBefore(_ s: String) -> String {
            var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            while let last = t.last, ",;:—-".contains(last) { t.removeLast() }
            return t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func tidyAfter(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

        // Spoken glue words that may sit between the sentence break and the
        // command ("…first. So take a screenshot…", "Let's copy the file
        // path…") — they go with it.
        let lead = "(?:(?:and|then|also|please|now|so|just|okay|ok|alright|let['’]?s|let\\s+us)\\s+)*"
        let bareForms = bare.map { "(?:\(phrase)|\($0))" } ?? "(?:\(phrase))"
        // The whole utterance is just the command ("Take a screenshot, please.").
        if match("^\(pad)\(lead)\(bareForms)\(pad)(?:please\(pad))?$") != nil {
            return ("", "")
        }
        // At the start: "Take a screenshot and fix the padding." — the
        // connective ("and"/"then") goes too, so the pasted text reads
        // clean. Recognizers write hesitations as "and, please…", hence the
        // optional comma after the connective.
        if let r = match("^\(pad)\(lead)(?:\(phrase))[\\s,.!?;:…\\-—]+(?:(?:and|then)[,;]?\\s+)?") {
            return ("", tidyAfter(ns.substring(from: r.location + r.length)))
        }
        // At the end: "Fix the padding, take a screenshot."
        if let r = match("[\\s,;:…\\-—]+\(lead)(?:\(phrase))\(pad)$") {
            return (tidyBefore(ns.substring(to: r.location)), "")
        }
        // In the middle, as its own clause: "…to understand. Take a
        // screenshot. And this is the text after." Needs punctuation before
        // it, and punctuation or a connective after it.
        if let r = match("(?<=[,.!?;:…\\-—])\\s+\(lead)(?:\(phrase))" +
                         "(?:\\s*[,.!?;:…\\-—]+\\s*(?:(?:and|then)[,;]?\\s+)?|\\s+(?:and|then)[,;]?\\s+)") {
            return (tidyBefore(ns.substring(to: r.location)),
                    tidyAfter(ns.substring(from: r.location + r.length)))
        }
        // Mid-clause after a connective, no pause needed: "…two folders and
        // copy the file path, and we need…" — said in one breath, the
        // recognizer writes no comma before the command, only after it.
        if let r = match("\\s+(?:and|then|or)[,;]?\\s+(?:\(phrase))" +
                         "(?:\\s*[,.!?;:…\\-—]+\\s*(?:(?:and|then)[,;]?\\s+)?|\\s+(?:and|then)[,;]?\\s+)") {
            return (tidyBefore(ns.substring(to: r.location)),
                    tidyAfter(ns.substring(from: r.location + r.length)))
        }
        return nil
    }

    static func splitScreenshot(_ text: String) -> (before: String, after: String)? {
        guard controlsOn else { return nil }
        return split(text, phrase: screenshotPhrase, bare: "screen\\s*shots?")
    }

    static func splitPath(_ text: String) -> (before: String, after: String)? {
        guard controlsOn else { return nil }
        return split(text, phrase: pathPhrase, bare: "(?:the\\s*)?(?:files?|folders?)\\s*paths?")
    }

    static func splitURL(_ text: String) -> (before: String, after: String)? {
        guard controlsOn else { return nil }
        // Bare "URL."/"The link." fire; bare "Address." stays text.
        return split(text, phrase: urlPhrase,
              bare: "(?:the\\s*)?(?:web\\s*site\\s*|website\\s*|page\\s*|tab\\s*|web\\s*)?(?:urls?|links?)")
    }

    /// Every occurrence of ONE family: the transcript split into the text
    /// runs around them, in spoken order. k commands -> k+1 entries (edge
    /// entries may be empty). nil = none anywhere.
    static func segment(_ text: String, by split: (String) -> (before: String, after: String)?) -> [String]? {
        guard let (before, after) = split(text) else { return nil }
        let head = segment(before, by: split) ?? [before]
        let tail = segment(after, by: split) ?? [after]
        return head + tail
    }

    /// The live stream heard "take a screenshot" and the shot was taken, but
    /// the final pass wrote something else in its place — "Take a spin-track
    /// and ask ChatGPT." (2026-09-27): the picture was dropped and the
    /// misheard words went out as text. With a live shot in hand the clause
    /// is known to have been the command, so a "take a <one or two words>"
    /// standing as its own clause is read back as it. Only called when live
    /// shots outnumber the final's screenshot phrases, so "take a break"
    /// with no shutter behind it stays text. Earliest clauses first, the
    /// same order the shots were taken in.
    static func repairLostScreenshots(_ text: String, missing: Int) -> String {
        guard missing > 0 else { return text }
        let lead = "(?:(?:and|then|also|please|now|so|just|okay|ok|alright|let['’]?s|let\\s+us)\\s+)*"
        let pattern = "(?:^|(?<=[,.!?;:…\\-—])\\s+|\\s+(?:and|then)[,;]?\\s+)\(lead)" +
            "(take|grab|capture)\\s+(?:a|an|the)\\s+([\\w'’-]+(?:\\s+[\\w'’-]+)?)" +
            "(?=\\s*[,.!?;:…—]|\\s*$|\\s+(?:and|then)\\b)"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let ns = text as NSString
        var out = text as NSString
        var left = missing
        var shift = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) where left > 0 {
            let noun = m.range(at: 2)
            let heard = ns.substring(with: noun).lowercased()
            // Already the command (counted by the final), or an idiom that
            // was really said — the lost phrase is elsewhere.
            if heard.contains("screen") { continue }
            if let first = heard.split(separator: " ").first,
               ["look", "break", "seat", "moment", "second", "minute", "step", "walk",
                "nap", "guess", "chance", "stab", "note", "breath", "while"].contains(String(first)) { continue }
            let at = NSRange(location: noun.location + shift, length: noun.length)
            out = out.replacingCharacters(in: at, with: "screenshot") as NSString
            shift += "screenshot".count - noun.length
            left -= 1
        }
        return out as String
    }

    static func segmentScreenshots(_ text: String) -> [String]? { segment(text, by: splitScreenshot) }
    static func segmentPaths(_ text: String) -> [String]? { segment(text, by: splitPath) }
    static func segmentURLs(_ text: String) -> [String]? { segment(text, by: splitURL) }

    /// All families at once: text runs with the commands between them, in
    /// spoken order — runs.count == commands.count + 1. nil = no commands.
    static func segment(_ text: String) -> (runs: [String], commands: [SpokenCommand])? {
        let families: [(SpokenCommand, (String) -> (before: String, after: String)?)] =
            [(.screenshot, splitScreenshot), (.filePath, splitPath), (.pageURL, splitURL)]
        func nest(_ text: String, _ i: Int) -> (runs: [String], commands: [SpokenCommand]) {
            guard i < families.count else { return ([text], []) }
            let (cmd, split) = families[i]
            let pieces = segment(text, by: split) ?? [text]
            var runs: [String] = []
            var commands: [SpokenCommand] = []
            for (j, piece) in pieces.enumerated() {
                if j > 0 { commands.append(cmd) }
                let sub = nest(piece, i + 1)
                runs += sub.runs
                commands += sub.commands
            }
            return (runs, commands)
        }
        let (runs, commands) = nest(text, 0)
        return commands.isEmpty ? nil : (runs, commands)
    }

    /// The text runs joined back up — for fallbacks that can only paste text.
    static func joinSpoken(_ segments: [String]) -> String {
        segments.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The FIRST "ask <service>" and everything after it: the question runs
    /// to the end of the utterance, so anything said after is part of the
    /// question — except the inline screenshot/path/link phrases, which the
    /// caller reads back out of it (a picture can't ride a ?q= link). The
    /// words before it go back to the normal paste pipeline. Same clause
    /// discipline as split(): "I should ask ChatGPT about it" stays text
    /// because the phrase only fires at the start, after punctuation, or
    /// after a bare connective. nil = no ask anywhere.
    static func splitAsk(_ text: String) -> (before: String, ask: AskCommand)? {
        guard controlsOn else { return nil }
        let pad = "[\\s,.!?;:…\\-—]*"
        let lead = "(?:(?:and|then|also|please|now|so|just|okay|ok|alright|let['’]?s|let\\s+us|go\\s+ahead\\s+and)\\s+)*"
        let ns = text as NSString
        var best: (range: NSRange, service: AIService)?
        for service in AIService.allCases {
            // The word break after the name keeps "Cloudflare" from being Claude.
            let phrase = "ask\\s*(?:the\\s+)?(?:\(service.spoken))(?=[\\s,.!?;:…\\-—]|$)"
            let forms = [
                "^\(pad)\(lead)\(phrase)",
                "(?<=[,.!?;:…\\-—])\\s+\(lead)\(phrase)",
                "\\s+(?:and|then|or)[,;]?\\s+\(phrase)",
            ]
            for form in forms {
                guard let re = try? NSRegularExpression(pattern: form, options: [.caseInsensitive]),
                      let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
                else { continue }
                if best == nil || m.range.location < best!.range.location {
                    best = (m.range, service)   // earliest spoken ask wins
                }
            }
        }
        guard let hit = best else { return nil }
        var before = ns.substring(to: hit.range.location)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = before.last, ",;:—-".contains(last) { before.removeLast() }
        before = before.trimmingCharacters(in: .whitespacesAndNewlines)
        var question = ns.substring(from: hit.range.location + hit.range.length)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = question.first, ",.!?;:…-—".contains(first) {
            question.removeFirst()
            question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A question the recognizer chose to quote comes unwrapped.
        for (open, close) in [("\"", "\""), ("“", "”"), ("'", "'"), ("‘", "’")] {
            if question.hasPrefix(open), question.hasSuffix(close), question.count > 1 {
                question = String(question.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return (before, AskCommand(service: hit.service, question: question))
    }

    /// The terminals SayCtrl will answer to by name, plus the generic words
    /// that just mean "a terminal". Bounded by the folder clause that has
    /// to follow, so "open Warp" alone never reaches this grammar — that
    /// is the plain open command's job. The brand names are safe because a
    /// terminal this Mac hasn't got is not a command at all.
    ///
    /// Two words people do say are deliberately absent. "Console" is a
    /// different app on a Mac (the log viewer) and usually means the
    /// browser's. "Shell" is what you dictate AT an assistant — "open a
    /// shell in the container" — and a false fire there costs the words
    /// AND puts a window on screen, which is worse than not hearing it.
    static let terminalWords =
        "terminal|iterm\\s*2?|i\\s*term\\s*2?|warp|ghostty|kitty|alacritty|" +
        "wez\\s*term|hyper|tabby|command\\s*line|command\\s*prompt"

    /// The FIRST "open/launch/start a terminal in <folder>". A folder clause
    /// is REQUIRED — a bare "open terminal" is an ordinary open command and
    /// stays with splitOpen — and it comes in two shapes: a name ("in the
    /// stocks folder") or the here form ("here", "in this folder"), which
    /// means whatever Finder is showing. The name runs to the word "folder",
    /// a connective, or the end of the clause, so "open terminal in downloads
    /// and run the build" opens one and keeps going. Same clause discipline
    /// as every other family: at the start, after punctuation, or after a
    /// bare connective, so "I had to open a terminal in that folder" stays
    /// ordinary text. What the name MEANS is FolderSearch's job.
    /// nil = no terminal command anywhere.
    static func splitTerminal(_ text: String) -> (before: String, terminal: TerminalCommand, after: String)? {
        guard controlsOn else { return nil }
        let pad = "[\\s,.!?;:…\\-—]*"
        let lead = "(?:(?:and|then|also|please|now|so|just|okay|ok|alright|let['’]?s|let\\s+us|go\\s+ahead\\s+and)\\s+)*"
        let folderNoun = "(?:folders?|director(?:y|ies)|dir)"
        // A folder name may carry hyphens and apostrophes, so \b is the wrong
        // edge everywhere here: it fires INSIDE "on-call" and after the "dir"
        // of "directions". Every word in this grammar ends where a name
        // character stops instead.
        let edge = "(?![\\w'’-])"
        // Words that end the folder name rather than joining it: the noun
        // itself, a connective, or the preposition that starts "…in desktop".
        let stop = "(?!(?:\(folderNoun)|and|then|in|on|at|inside|under|of)\(edge))"
        // "…in this folder", "…in the current directory", "…in here" — a
        // determiner and the bare noun name nothing, so they mean here.
        // Tried BEFORE the name shape, or "in the folder" would read "the"
        // as a folder name.
        let here = "(?:right\\s+)?here\(edge)" +
            "|(?:in|at|from|over)\\s+(?:right\\s+)?(?:here|there)\(edge)" +
            "|(?:in|at|inside|from|under)\\s+(?:the\\s+|this\\s+|that\\s+|my\\s+)?" +
            // A folder actually CALLED "folders" reads as here — rare enough
            // to accept, but the second noun has to be eaten too or "…the
            // folders folder" leaves a stray "folder" to paste.
            "(?:current\\s+|present\\s+|same\\s+)?\(folderNoun)\(edge)(?:\\s+\(folderNoun)\(edge))?"
        let named = "(?:in|at|inside|into|on|from|under|to)\\s+(?:the\\s+|my\\s+|this\\s+)?" +
            "(\(stop)[\\w'’-]+(?:\\s+\(stop)[\\w'’-]+){0,2})" +
            "(?:\\s+\(folderNoun)\(edge))?" +
            // "…the stocks folder IN DESKTOP" — the folder's own home.
            "(?:\\s+(?:in|on|inside|under)\\s+(?:the\\s+|my\\s+)?([\\w'’-]+)(?:\\s+\(folderNoun)\(edge))?)?"
        let phrase = "(?:open|launch|start|fire\\s+up|bring\\s+up)\\s+" +
            // "up" rides along so "open up a terminal…" counts; OpenTarget
            // strips the same word as filler for the plain open command.
            "(?:the\\s+|a\\s+|an\\s+|my\\s+|new\\s+|another\\s+|up\\s+)*" +
            "(\(terminalWords))(?:\\s+(?:app|window|tab|session))?" +
            "\\s+(?:\(here)|\(named))"
        let ns = text as NSString
        var best: NSTextCheckingResult?
        let forms = [
            "^\(pad)\(lead)\(phrase)",
            "(?<=[,.!?;:…\\-—])\\s+\(lead)\(phrase)",
            "\\s+(?:and|then)[,;]?\\s+\(phrase)",
        ]
        for form in forms {
            guard let re = try? NSRegularExpression(pattern: form, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
            else { continue }
            if best == nil || m.range.location < best!.range.location { best = m }
        }
        guard let m = best else { return nil }
        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r).lowercased()
        }
        // The recognizer's spacing is its own business: "i term 2" and
        // "wez term" are one word by the time anything looks them up.
        let spoken = (group(1) ?? "terminal")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ".", with: "")
        // No name captured means the here shape matched.
        let folder = group(2)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let f = folder, f.isEmpty { return nil }
        // The generic words carry no preference — "whichever terminal".
        let generic: Set<String> = ["terminal", "commandline", "commandprompt"]
        var before = ns.substring(to: m.range.location)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = before.last, ",;:—-".contains(last) { before.removeLast() }
        before = before.trimmingCharacters(in: .whitespacesAndNewlines)
        var after = ns.substring(from: m.range.location + m.range.length)
        while let f = after.first, ",.!?;:…—- \t\n".contains(f) { after.removeFirst() }
        if let cre = try? NSRegularExpression(pattern: "^(?:and|then)[,;]?\\s+", options: [.caseInsensitive]),
           let cm = cre.firstMatch(in: after, range: NSRange(location: 0, length: (after as NSString).length)) {
            after = (after as NSString).substring(from: cm.range.length)
        }
        if after.range(of: "^please[\\s,.!?]*$", options: [.regularExpression, .caseInsensitive]) != nil {
            after = ""
        }
        return (before,
                TerminalCommand(app: generic.contains(spoken) ? nil : spoken,
                                folder: folder, parent: group(3)),
                after)
    }

    /// The FIRST "open/launch <target>": the target runs to the end of its
    /// clause — the next punctuation or bare connective — so "Open Chrome
    /// and take a screenshot" opens one thing and keeps going. Same clause
    /// discipline as everything else ("you can open Chrome" stays text).
    /// What the target MEANS — app, site, search — is OpenTarget's job;
    /// the grammar only cuts the words. nil = no open command anywhere.
    static func splitOpen(_ text: String) -> (before: String, target: String, after: String)? {
        guard controlsOn else { return nil }
        let pad = "[\\s,.!?;:…\\-—]*"
        let lead = "(?:(?:and|then|also|please|now|so|just|okay|ok|alright|let['’]?s|let\\s+us|go\\s+ahead\\s+and)\\s+)*"
        let verb = "(?:open|launch)"
        let ns = text as NSString
        var best: NSRange?
        let forms = [
            "^\(pad)\(lead)\(verb)\\s+",
            "(?<=[,.!?;:…\\-—])\\s+\(lead)\(verb)\\s+",
            "\\s+(?:and|then)[,;]?\\s+\(verb)\\s+",
        ]
        for form in forms {
            guard let re = try? NSRegularExpression(pattern: form, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
            else { continue }
            if best == nil || m.range.location < best!.location { best = m.range }
        }
        guard let hit = best else { return nil }
        var before = ns.substring(to: hit.location)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = before.last, ",;:—-".contains(last) { before.removeLast() }
        before = before.trimmingCharacters(in: .whitespacesAndNewlines)

        var target = ns.substring(from: hit.location + hit.length)
        var after = ""
        // The clause ends at punctuation — but not a dot inside a token
        // ("reqkey.com") — or at a bare "and/then". The boundary itself
        // goes with the command; a following sentence keeps its period.
        if let re = try? NSRegularExpression(pattern: "[,.!?;:…—](?=\\s|$)"),
           let m = re.firstMatch(in: target, range: NSRange(location: 0, length: (target as NSString).length)) {
            let nst = target as NSString
            var rest = nst.substring(from: m.range.location)
            target = nst.substring(to: m.range.location)
            while let f = rest.first, ",.!?;:…—- \t\n".contains(f) { rest.removeFirst() }
            // "Open Chrome, and tell me…" — the connective goes with the
            // command, so the pasted text reads clean.
            if let cre = try? NSRegularExpression(pattern: "^(?:and|then)[,;]?\\s+", options: [.caseInsensitive]),
               let cm = cre.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length)) {
                rest = (rest as NSString).substring(from: cm.range.length)
            }
            after = rest
        }
        for conn in [" and ", " then "] {
            if let r = target.range(of: conn, options: .caseInsensitive) {
                let cut = String(target[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                after = after.isEmpty ? cut : cut + " " + after
                target = String(target[..<r.lowerBound])
            }
        }
        // A trailing courtesy isn't part of the after-text.
        if after.range(of: "^please[\\s,.!?]*$", options: [.regularExpression, .caseInsensitive]) != nil {
            after = ""
        }
        target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        return (before, target, after)
    }

    /// The FIRST "attach/upload/add/insert the (second)? (payout)? <kind>
    /// (from <folder>)?" — a point command, same clause discipline ("you
    /// should attach the image" stays text). "attach" is the canonical
    /// verb but recognizers butcher it, so the everyday synonyms count
    /// too — with one guard: add/insert need a SPECIFIC kind, so "add the
    /// file to git" stays text while "upload the file" still works. The
    /// "(?!\\s+paths?)" keeps "attach the file path" in the path world.
    /// An ordinal spoken right after ("… from downloads, the second one")
    /// folds into the command instead of pasting as words.
    static func splitAttach(_ text: String) -> (before: String, attach: AttachCommand, after: String)? {
        guard controlsOn else { return nil }
        let pad = "[\\s,.!?;:…\\-—]*"
        let lead = "(?:(?:and|then|also|please|now|so|just|okay|ok|alright|let['’]?s|let\\s+us|go\\s+ahead\\s+and)\\s+)*"
        let phrase = "(attach(?:ed)?|upload|add|insert)\\s+(?:the\\s+|a\\s+|an\\s+|my\\s+)?" +
            "(?:(first|second|third|fourth|fifth|latest|last|newest)\\s+)?" +
            "((?:[\\w'’-]+\\s+){1,2}?)??" +
            "(images?|img|pictures?|photos?|screen\\s*shots?|pdfs?|videos?|texts?|txt|markdowns?|md|files?|folders?)\\b" +
            // A kind word right before "folder" is really the folder's NAME
            // ("the files folder") — fail here so the fragment takes it and
            // the kind lands on "folder" instead. The \b above keeps the
            // backtrack honest: "files" may not shrink to "file" + stray s.
            "(?!\\s+paths?\\b|\\s+folders?\\b)" +
            "(?:\\s+files?)?" +
            "(?:\\s+from\\s+(?:the\\s+|my\\s+)?([\\w'’-]+(?:\\s+(?!(?:folder|and|then)\\b)[\\w'’-]+)?)(?:\\s+folder)?" +
            // "…from the stocks folder IN DESKTOP" — the folder's own home.
            "(?:\\s+(?:in|on|inside|under)\\s+(?:the\\s+|my\\s+)?([\\w'’-]+)(?:\\s+folder)?)?)?"
        let ns = text as NSString
        var best: NSTextCheckingResult?
        let forms = [
            "^\(pad)\(lead)\(phrase)",
            "(?<=[,.!?;:…\\-—])\\s+\(lead)\(phrase)",
            "\\s+(?:and|then)[,;]?\\s+\(phrase)",
        ]
        for form in forms {
            guard let re = try? NSRegularExpression(pattern: form, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
            else { continue }
            if best == nil || m.range.location < best!.range.location { best = m }
        }
        guard let m = best else { return nil }
        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r).lowercased()
        }
        let kind: AttachKind
        switch group(4) ?? "" {
        case let t where t.contains("screen"):                       kind = .screenshot
        case let t where t.hasPrefix("im") || t.hasPrefix("pic") || t.hasPrefix("pho"): kind = .image
        case let t where t.hasPrefix("pdf"):                         kind = .pdf
        case let t where t.hasPrefix("vid"):                         kind = .video
        case let t where t.hasPrefix("te") || t.hasPrefix("txt"):    kind = .text
        case let t where t.hasPrefix("md") || t.hasPrefix("mark"):   kind = .markdown
        case let t where t.hasPrefix("folder"):                      kind = .folder
        default:                                                     kind = .any
        }
        // The everyday verbs are too common to also claim bare "file".
        let verb = group(1) ?? "attach"
        if kind == .any, verb == "add" || verb == "insert" { return nil }
        var ordinal: Int? = group(2).map {
            switch $0 {
            case "second": return 2
            case "third":  return 3
            case "fourth": return 4
            case "fifth":  return 5
            default:       return 1   // first / latest / last / newest
            }
        }
        let fragment = group(3)?.trimmingCharacters(in: .whitespacesAndNewlines)
        var before = ns.substring(to: m.range.location)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = before.last, ",;:—-".contains(last) { before.removeLast() }
        before = before.trimmingCharacters(in: .whitespacesAndNewlines)
        var after = ns.substring(from: m.range.location + m.range.length)
        while let f = after.first, ",.!?;:…—- \t\n".contains(f) { after.removeFirst() }
        if ordinal == nil {
            let (n, rest) = stripLeadingOrdinal(after)
            if let n = n { ordinal = n; after = rest }
        }
        if let cre = try? NSRegularExpression(pattern: "^(?:and|then)[,;]?\\s+", options: [.caseInsensitive]),
           let cm = cre.firstMatch(in: after, range: NSRange(location: 0, length: (after as NSString).length)) {
            after = (after as NSString).substring(from: cm.range.length)
        }
        if after.range(of: "^please[\\s,.!?]*$", options: [.regularExpression, .caseInsensitive]) != nil {
            after = ""
        }
        return (before, AttachCommand(kind: kind, ordinal: ordinal,
                                      folder: group(5), fragment: fragment,
                                      parent: group(6)), after)
    }

    /// "copy the (second)? (zillow)? <kind> path (from|in|on <folder> (in
    /// <parent>)?)?" — the attach grammar's sibling, delivering the file's
    /// PATH as text at the cursor. Plain "copy the file/folder path" (no
    /// kind, name, folder, or ordinal) stays with the inline path family —
    /// this claims only a narrowed query: "copy the pdf path from
    /// downloads", "grab the zillow folder path", "copy the json file path
    /// on desktop".
    static func splitPathQuery(_ text: String) -> (before: String, attach: AttachCommand, after: String)? {
        guard controlsOn else { return nil }
        let pad = "[\\s,.!?;:…\\-—]*"
        let lead = "(?:(?:and|then|also|please|now|so|just|okay|ok|alright|let['’]?s|let\\s+us|go\\s+ahead\\s+and)\\s+)*"
        let phrase = "(copy|paste|grab|get|insert)\\s+(?:the\\s+|a\\s+|an\\s+|my\\s+)?" +
            "(?:(first|second|third|fourth|fifth|latest|last|newest)\\s+)?" +
            "((?:[\\w'’-]+\\s+){1,2}?)??" +
            "(images?|img|pictures?|photos?|screen\\s*shots?|pdfs?|videos?|texts?|txt|markdowns?|md|files?|folders?|director(?:y|ies))" +
            "(?:['’]s)?\\s+paths?\\b" +
            "(?:\\s+(?:from|in|on|inside)\\s+(?:the\\s+|my\\s+)?([\\w'’-]+(?:\\s+(?!(?:folder|and|then)\\b)[\\w'’-]+)?)(?:\\s+folder)?" +
            "(?:\\s+(?:in|on|inside|under)\\s+(?:the\\s+|my\\s+)?([\\w'’-]+)(?:\\s+folder)?)?)?"
        let ns = text as NSString
        var best: NSTextCheckingResult?
        let forms = [
            "^\(pad)\(lead)\(phrase)",
            "(?<=[,.!?;:…\\-—])\\s+\(lead)\(phrase)",
            "\\s+(?:and|then)[,;]?\\s+\(phrase)",
        ]
        for form in forms {
            guard let re = try? NSRegularExpression(pattern: form, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
            else { continue }
            if best == nil || m.range.location < best!.range.location { best = m }
        }
        guard let m = best else { return nil }
        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r).lowercased()
        }
        let kind: AttachKind
        switch group(4) ?? "" {
        case let t where t.contains("screen"):                       kind = .screenshot
        case let t where t.hasPrefix("im") || t.hasPrefix("pic") || t.hasPrefix("pho"): kind = .image
        case let t where t.hasPrefix("pdf"):                         kind = .pdf
        case let t where t.hasPrefix("vid"):                         kind = .video
        case let t where t.hasPrefix("te") || t.hasPrefix("txt"):    kind = .text
        case let t where t.hasPrefix("md") || t.hasPrefix("mark"):   kind = .markdown
        case let t where t.hasPrefix("folder") || t.hasPrefix("director"): kind = .folder
        default:                                                     kind = .any
        }
        let ordinal: Int? = group(2).map {
            switch $0 {
            case "second": return 2
            case "third":  return 3
            case "fourth": return 4
            case "fifth":  return 5
            default:       return 1
            }
        }
        let fragment = group(3)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = group(5)
        // Nothing narrows it — that's the classic inline command's job.
        if fragment == nil, folder == nil, ordinal == nil, kind == .any || kind == .folder {
            return nil
        }
        var before = ns.substring(to: m.range.location)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = before.last, ",;:—-".contains(last) { before.removeLast() }
        before = before.trimmingCharacters(in: .whitespacesAndNewlines)
        var after = ns.substring(from: m.range.location + m.range.length)
        while let f = after.first, ",.!?;:…—- \t\n".contains(f) { after.removeFirst() }
        if let cre = try? NSRegularExpression(pattern: "^(?:and|then)[,;]?\\s+", options: [.caseInsensitive]),
           let cm = cre.firstMatch(in: after, range: NSRange(location: 0, length: (after as NSString).length)) {
            after = (after as NSString).substring(from: cm.range.length)
        }
        if after.range(of: "^please[\\s,.!?]*$", options: [.regularExpression, .caseInsensitive]) != nil {
            after = ""
        }
        return (before, AttachCommand(kind: kind, ordinal: ordinal, folder: folder,
                                      fragment: fragment, parent: group(6),
                                      delivery: .path), after)
    }

    /// Whole-utterance "cancel / dismiss / never mind / close (the
    /// selection)" — meaningful only while the picker strip is up: drop it
    /// without pasting a word.
    static func isCancelSelection(_ text: String) -> Bool {
        let pattern = "^[\\s,.!?;:…\\-—]*(?:(?:okay|ok|alright|please|just|no)[\\s,]+)*" +
            "(?:cancel|dismiss|never\\s*mind|close)" +
            "(?:\\s+(?:the|that|this|it))?(?:\\s+(?:selection|choice|picker|one|box))?" +
            "[\\s,.!?;:…\\-—]*$"
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// "…, the second one, and explain it" → (2, "and explain it"-ish).
    /// Only a real selection clause counts: the ordinal must be followed
    /// by a boundary, a connective, or one of the picker nouns — "the
    /// first thing we should do" is left alone.
    static func stripLeadingOrdinal(_ text: String) -> (ordinal: Int?, rest: String) {
        let words = "(first|1st|second|2nd|third|3rd|fourth|4th|fifth|5th|latest|newest|last)"
        let pattern = "^(?:(?:select|choose|pick|use|take|i\\s+mean|i\\s+meant)\\s+)?" +
            "(?:the\\s+)?(?:number\\s+)?\(words)" +
            "(?:\\s+(?:one|file|image|picture|photo|screenshot|pdf|video|folder))?" +
            "(?=[\\s]*(?:[,.!?;:…—]|$)|\\s+(?:and|then)\\b)"
        let ns = text as NSString
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
        else { return (nil, text) }
        let word = ns.substring(with: m.range(at: 1)).lowercased()
        let n: Int
        switch word {
        case "first", "1st", "latest", "newest": n = 1
        case "second", "2nd":                    n = 2
        case "third", "3rd":                     n = 3
        case "fourth", "4th":                    n = 4
        case "fifth", "5th":                     n = 5
        case "last":                             n = -1
        default:                                 return (nil, text)
        }
        var rest = ns.substring(from: m.range.length)
        while let f = rest.first, ",.!?;:…—- \t\n".contains(f) { rest.removeFirst() }
        if let cre = try? NSRegularExpression(pattern: "^(?:and|then)[,;]?\\s+", options: [.caseInsensitive]),
           let cm = cre.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length)) {
            rest = (rest as NSString).substring(from: cm.range.length)
        }
        return (n, rest)
    }

    /// "…and send it" at the very END of a dictation: the words before it
    /// are the message, and SayCtrl presses Return once they have landed.
    /// "send" alone is left to metaCommand — here the phrase needs an
    /// object so a dictated "…the files I send" stays text.
    static let sendPhrase =
        "send\\s+(?:it|that|this)(?:\\s+(?:now|off))?" +
        "|send\\s+(?:the\\s+|this\\s+|that\\s+|my\\s+)?messages?" +
        "|(?:hit|press|push|tap)\\s+(?:send|enter|return)"

    /// The scratch grammar, shared by the whole-utterance form and the
    /// in-dictation form. "delete/remove" need the explicit "last …"
    /// object — a dictated "Delete that" is words you might type AT an
    /// AI. "Stress that" and "and do last sentence" are what the
    /// recognizer tends to hear "scratch that" / "undo last sentence" as.
    static let scratchVerbs = "(?:scratch|scrap|strike|undo|delete|remove)"
    static let scratchSentencePhrase =
        "\(scratchVerbs)\\s+(?:the\\s+|my\\s+|that\\s+|this\\s+)?last\\s+sentences?"
        + "|\(scratchVerbs)\\s+(?:that|this)\\s+sentence"
        + "|and\\s+do\\s+(?:the\\s+|my\\s+)?last\\s+sentences?"
    static let scratchAllPhrase =
        "(?:scratch|scrap|strike|undo|stress)\\s+(?:that|this|it)"
        + "|\(scratchVerbs)\\s+(?:the\\s+|my\\s+)?last\\s+(?:message|dictation|paste|thing|one|text)s?"
        + "|undo\\s+(?:the\\s+)?last"

    /// A meta command as the WHOLE utterance ("Scratch that.", "Send it,
    /// please.", "Switch to the local model"). nil = ordinary dictation.
    static func metaCommand(_ text: String) -> MetaCommand? {
        let pad = "[\\s,.!?;:…\\-—]*"
        // Unlike the mid-dictation lead, glue words here may carry their
        // own pause ("Okay, scratch that.") — the utterance is over, there
        // is no following text a stray comma could bleed into.
        let lead = "(?:(?:and|then|also|please|now|so|just|okay|ok|alright|let['’]?s|let\\s+us|go\\s+ahead\\s+and)[,;]?\\s+)*"
        func whole(_ phrase: String) -> Bool {
            let pattern = "^\(pad)\(lead)(?:\(phrase))\(pad)(?:please\(pad))?$"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
            return re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
        }

        // Scratch — the phrases live above so the in-dictation form
        // (splitScratch) can never drift from this one.
        if whole(scratchSentencePhrase) { return .scratch(.sentence) }
        if whole(scratchAllPhrase)      { return .scratch(.all) }

        // Send. Bare "Send." counts here — nobody dictates that one word
        // as text — but not in the trailing form above.
        if whole("(?:\(sendPhrase))|send") { return .send }

        // Model switching. "model(s)/mode" is optional after a switching
        // verb ("go local"), required for the bare form ("local model").
        let switchVerbs = "(?:(?:move|switch|go|change|swap)\\s+(?:back\\s+|over\\s+)?to|use)"
        let modelWord = "(?:\\s+(?:models?|modes?))"
        if whole("\(switchVerbs)\\s+(?:the\\s+|a\\s+)?local\(modelWord)?"
                 + "|go\\s+local|local\\s+models?") {
            return .useLocalModel
        }
        // "paid" stands on its own ("go back to paid"); the other
        // adjectives are everyday tech talk ("use the API", "switch to
        // the cloud") and only count with the model word attached.
        let paidWords = "(?:paid|cloud|online|remote|api)"
        if whole("\(switchVerbs)\\s+(?:the\\s+|a\\s+)?paid\(modelWord)?"
                 + "|\(switchVerbs)\\s+(?:the\\s+|a\\s+)?\(paidWords)\(modelWord)"
                 + "|\(paidWords)\\s+models?") {
            return .usePaidModel
        }
        return nil
    }

    /// The text before a trailing send command, or nil when there isn't
    /// one. Same tail discipline as the other families — punctuation or a
    /// bare connective must sit in front, so "I'll send it" and "please
    /// send it to me" stay ordinary text.
    static func splitTrailingSend(_ text: String) -> String? {
        let pad = "[\\s,.!?;:…\\-—]*"
        let lead = "(?:(?:and|then|also|please|now|so|just|okay|ok|alright|let['’]?s|let\\s+us|go\\s+ahead\\s+and)\\s+)*"
        let ns = text as NSString
        let forms = [
            "(?<=[,.!?;:…\\-—])\\s+\(lead)(?:\(sendPhrase))\(pad)(?:please\(pad))?$",
            "\\s+(?:and|then)[,;]?\\s+(?:\(sendPhrase))\(pad)(?:please\(pad))?$",
        ]
        for form in forms {
            guard let re = try? NSRegularExpression(pattern: form, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
            else { continue }
            var before = ns.substring(to: m.range.location)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            while let last = before.last, ",;:—-".contains(last) { before.removeLast() }
            return before.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// Scratch spoken INSIDE a dictation, standing as its own sentence:
    /// "…that I am building. Sorry, scratch that." erases the words of
    /// this take before it, and dictation flows on after. Opening the
    /// take with it ("Scratch that. My name is…") reaches back into the
    /// previous paste instead — those scopes come back in `leading` for
    /// the caller to backspace before the rest is pasted. A bare "and"
    /// works at the very END ("…the next sentence and scratch that"),
    /// same discipline as splitTrailingSend. nil = no scratch spoken.
    /// Mid-utterance the phrase must end its sentence, so "we could do
    /// X, scratch that, Y" and "scratch that itch" stay ordinary text.
    static func splitScratch(_ text: String) -> (leading: [ScratchScope], text: String)? {
        // Corrections rarely start clean — "Sorry," "no," "wait," may
        // sit in front, inside the command's own sentence — and the
        // recognizer quotes a command it hears after "…I'm saying,".
        let lead = "(?:(?:sorry|no|wait|actually|oops|okay|ok|alright|and|then|also|please|now|so|just|uh|um)[,;]?\\s+)*"
        let quote = "[\"'“‘]*"
        let phrase = "(?:(\(scratchSentencePhrase))|(\(scratchAllPhrase)))"
        var leading: [ScratchScope] = []
        var buffer = ""
        var found = false
        var rest = text

        func scratchBuffer(_ scope: ScratchScope) {
            while let last = buffer.last, last.isWhitespace { buffer.removeLast() }
            if buffer.isEmpty {
                leading.append(scope)   // nothing said yet — reaches the previous paste
            } else if scope == .all {
                buffer = ""
            } else {
                buffer = dropLastSentence(buffer).kept
                while let last = buffer.last, last.isWhitespace { buffer.removeLast() }
            }
        }

        // "…and scratch that" on the tail: cut off up front so the
        // sentence-bounded scan below works the shortened text; its scope
        // applies last, once everything before it has settled. Only the
        // unmistakable verbs here — "…and delete the last message" is a
        // plausible instruction TO an AI, so those need their own sentence.
        let safeVerbs = "(?:scratch|scrap|strike|undo)"
        let trailingPhrase = "(?:("
            + "\(safeVerbs)\\s+(?:the\\s+|my\\s+|that\\s+|this\\s+)?last\\s+sentences?"
            + "|\(safeVerbs)\\s+(?:that|this)\\s+sentence"
            + "|(?:and\\s+)?do\\s+(?:the\\s+|my\\s+)?last\\s+sentences?"
            + ")|("
            + "(?:scratch|scrap|strike|undo|stress)\\s+(?:that|this|it)"
            + "|\(safeVerbs)\\s+(?:the\\s+|my\\s+)?last\\s+(?:message|dictation|paste|thing|one|text)s?"
            + "|undo\\s+(?:the\\s+)?last"
            + "))"
        var trailing: ScratchScope?
        if let re = try? NSRegularExpression(
               pattern: "\\s+(?:and|then)[,;]?\\s+\(quote)\(trailingPhrase)[\\s,.!?;:…—\"'”’)\\]\\-]*$",
               options: [.caseInsensitive]),
           let m = re.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length)) {
            found = true
            trailing = m.range(at: 1).location != NSNotFound ? .sentence : .all
            rest = (rest as NSString).substring(to: m.range.location)
        }

        let boundary = "(^|[.!?…\\n,;:—-][\"'”’)\\]]*\\s+)"
        let tail = "\\s*(?:[.!?…]+[\"'”’)\\]]*\\s*|[,;:]?\\s*$)"
        // Group 1 is the boundary, so the phrase groups sit at 2 and 3.
        guard let re = try? NSRegularExpression(
                  pattern: boundary + quote + lead + quote + phrase + tail,
                  options: [.caseInsensitive]) else { return nil }
        // One match at a time, rescanning the remainder: back-to-back
        // commands ("Scratch that. Undo the last sentence.") each need
        // the fresh string start the previous match consumed.
        while let m = re.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length)) {
            found = true
            let ns = rest as NSString
            let b = m.range(at: 1)   // the ender before the command stays with the text
            buffer += ns.substring(to: b.location + b.length)
            scratchBuffer(m.range(at: 2).location != NSNotFound ? .sentence : .all)
            if !buffer.isEmpty { buffer += " " }
            rest = ns.substring(from: m.range.location + m.range.length)
        }
        guard found else { return nil }
        buffer += rest
        if let t = trailing { scratchBuffer(t) }
        return (leading, buffer.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The last sentence split off the rest: kept keeps its ender, removed
    /// starts at the following text — the whitespace between belongs to
    /// neither and is counted by the caller via lengths. ("", text) when
    /// there is only one sentence.
    static func dropLastSentence(_ text: String) -> (kept: String, removed: String) {
        let ns = text as NSString
        guard let re = try? NSRegularExpression(pattern: "[.!?…]+[\"'”’)\\]]*\\s+|\\n+") else {
            return ("", text)
        }
        let matches = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
        // The boundary that starts the last sentence: the last one with
        // real text after it (the ender closing the final sentence has none).
        for m in matches.reversed() {
            let end = m.range.location + m.range.length
            let after = ns.substring(from: end)
            guard !after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            var kept = ns.substring(to: end)
            while let last = kept.last, last.isWhitespace { kept.removeLast() }
            return (kept, after)
        }
        return ("", text)
    }

    /// A picker is on screen and the user answered it: "the first one",
    /// "select the second", "number three", "the latest". Whole-utterance
    /// only, so a real dictation never reads as a pick. -1 = the last one
    /// shown. nil = this was ordinary dictation.
    static func pickOrdinal(_ text: String) -> Int? {
        let words = "(first|1st|one|1|second|2nd|two|2|third|3rd|three|3|fourth|4th|four|4|fifth|5th|five|5|latest|newest|last)"
        let pattern = "^[\\s,.!?;:…\\-—]*(?:(?:select|choose|pick|use|take|attach|upload|add|insert|i\\s+mean|i\\s+meant)\\s+)?" +
            "(?:the\\s+)?(?:number\\s+)?\(words)" +
            "(?:\\s+(?:one|file|image|picture|photo|screenshot|pdf|video|folder))?" +
            "[\\s,.!?;:…\\-—]*(?:please[\\s,.!?]*)?$"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length))
        else { return nil }
        let word = (text as NSString).substring(with: m.range(at: 1)).lowercased()
        switch word {
        case "first", "1st", "one", "1", "latest", "newest": return 1
        case "second", "2nd", "two", "2":                    return 2
        case "third", "3rd", "three", "3":                   return 3
        case "fourth", "4th", "four", "4":                   return 4
        case "fifth", "5th", "five", "5":                    return 5
        case "last":                                         return -1
        default:                                             return nil
        }
    }

    /// The same answer, heard badly. A picker is up, the reply is short, and
    /// the recognizer wrote "That hard one" for "the third one" — the sounds
    /// are right and the spelling is not. Whole-utterance only and short
    /// only (a handful of words, no more letters than the longest reply),
    /// so a real sentence never reads as a pick; then the closest reply by
    /// letter-edit distance wins, if it is close enough and nothing else is
    /// nearly as close. Distances are measured on the letters alone,
    /// since the recognizer's spaces and punctuation are the least reliable
    /// part of what it wrote.
    static func pickOrdinalFuzzy(_ text: String) -> Int? {
        let letters = condensed(text)
        let wordCount = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
        guard wordCount <= 5, (3...18).contains(letters.count) else { return nil }

        // Every shape pickOrdinal reads, spelled out per candidate.
        let spellings: [(Int, [String])] = [
            (1, ["first", "one"]), (2, ["second", "two"]), (3, ["third", "three"]),
            (4, ["fourth", "four"]), (5, ["fifth", "five"]), (-1, ["last"]),
        ]
        var best: (n: Int, score: Double)? = nil
        var runnerUp = 0.0
        for (n, words) in spellings {
            var top = 0.0
            for w in words {
                for form in ["the \(w) one", "\(w) one", "the \(w)", "number \(w)",
                             "select the \(w) one", "pick the \(w) one", "the \(w) file"] {
                    top = max(top, similarity(letters, condensed(form)))
                }
            }
            if best == nil || top > best!.score {
                if let b = best { runnerUp = max(runnerUp, b.score) }
                best = (n, top)
            } else {
                runnerUp = max(runnerUp, top)
            }
        }
        guard let hit = best, hit.score >= 0.75, hit.score - runnerUp >= 0.08 else { return nil }
        return hit.n
    }

    /// What a picker reply comes to, echo and all. whisper.cpp reads its
    /// prompt as the transcript that came just before the clip and writes
    /// on in the same style — primed with the picker's replies ahead of a
    /// one-second "the fifth one", it wrote "the fifth one, the fifth one."
    /// (five of fifteen saved replies, 2026-08-22), and an echo that fails
    /// the whole-utterance test is pasted as words: the picker ignored and
    /// "The fifth one, the fifth one." in the chat box. So the utterance is
    /// read clause by clause — every clause must be a reply, heard exactly
    /// or nearly — and the last one spoken is the answer, which is also what
    /// "the second one, I mean the third one" means. `plain` is true only
    /// when the whole utterance was one reply, heard exactly — anything
    /// else is worth a line in the log.
    static func pickReply(_ text: String) -> (n: Int, plain: Bool)? {
        if let n = pickOrdinal(text) { return (n, true) }
        if let n = pickOrdinalFuzzy(text) { return (n, false) }
        let clauses = clausesOf(text)
        guard clauses.count >= 2 else { return nil }
        var last: Int?
        for clause in clauses {
            guard let n = pickOrdinal(clause) ?? pickOrdinalFuzzy(clause) else { return nil }
            last = n
        }
        return last.map { ($0, false) }
    }

    /// "cancel, cancel." — the same echo on the other reply.
    static func isCancelReply(_ text: String) -> Bool {
        if isCancelSelection(text) { return true }
        let clauses = clausesOf(text)
        return clauses.count >= 2 && clauses.allSatisfy(isCancelSelection)
    }

    /// The utterance at its punctuation: what the recognizer wrote between
    /// commas, full stops, and the rest. Hyphens stay — they join words.
    private static func clausesOf(_ text: String) -> [String] {
        text.split(whereSeparator: { ",.!?;:…—\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Lower-case letters and digits, nothing else.
    private static func condensed(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// 1 − (edit distance ÷ longer length): 1 is identical, 0 shares nothing.
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
}
