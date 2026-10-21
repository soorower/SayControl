// Speak into a terminal and the words land as a command.
//
// The other half of "open terminal in the projects folder" (TerminalTarget): that
// one puts a prompt in front of you, this one writes at it. Nothing to learn
// and no wake word to remember — the terminal you were already talking into IS
// the mode. "add everything and commit with the message fixed the login bug"
// becomes `git add . && git commit -m "fixed the login bug"`, sitting at the
// prompt, waiting for a Return you press yourself.
//
// Everything here is a fixed table, on purpose. An LLM would read far more
// phrasings, and it was tried (2026-08-21) and taken back out: asked to make
// the build script executable it answered `chmod +x build-script`, a file that
// does not exist. A plausible command is not a correct one, and a wrong
// command that LOOKS right is the one you press Return on. So the only
// commands SayCtrl writes are the ones written down below, where they can be
// read — and the literal layer, which invents nothing and only spells out what
// you actually said.
//
// A terminal is also where Claude Code, Codex and aider read, and dictating a
// paragraph AT an agent has to keep working. So the grammar is the gate, the
// same discipline every other family here follows: words that are not
// unmistakably a command return nil and stay ordinary prose. An utterance
// qualifies two ways only —
//
//   • it leads with a tool that exists (`git …`, `npm …`, `cd …`, `ls`), or
//   • it matches a recipe whose trigger no one says by accident ("make a new
//     folder called …", "list the files", "where am I", "go up one").
//
// The bare git verbs are the interesting case: "add everything" is a command,
// "add a test for the login flow" is a sentence for an agent. The object
// decides — everything/all, or something shaped like a path.
//
// WHAT COMES OUT is written the way a developer writes in a document: lower
// case, because that is how commands are typed. Two things keep the case they
// were spoken in, because in both the capital carries meaning — a MESSAGE (a
// commit message is prose, and "Fixed the login bug" should stay that way) and
// a NAME (a file, a folder, a branch: `cd SayCtrl` is not `cd sayctrl`). Every
// other word is lowered, which is also what kills the capital the recognizer
// puts on the first word of every sentence: "Git add." → `git add .`.
//
// A command SayCtrl has no recipe for is NOT a dead end — that is the whole
// point of the literal layer. `pnpm run dev`, `docker compose up -d`,
// `pytest -k login` are typed out as spoken, spoken symbols and all ("dash m"
// → `-m`, "package dot json" → `package.json`), because the alternative is
// guessing at a command, and a wrong command is worse than no feature.
//
// Nothing is ever executed here. SayCtrl types; the human presses Return. The
// dangerous corner of the shell is marked `risky` so that even "send it" —
// which presses Return for you everywhere else — declines to do it.
//
// Pure string work, no AppKit, like Commands.swift, so the grammar can be
// exercised on its own.
import Foundation

enum Shell {

    /// One line, ready for the prompt.
    struct Line: Equatable {
        /// What gets typed.
        let command: String
        /// The shell's dangerous corner — never gets a Return pressed for it.
        let risky: Bool
        /// Whether SayCtrl may press Return on this itself.
        var mayAutoReturn: Bool { !risky }
    }

    // MARK: - Entry

    /// The command these words mean, or nil when they are not a command and
    /// belong to the ordinary paste path.
    static func line(for spoken: String) -> Line? {
        let clause = tidy(spoken)
        if let line = build(clause) { return line }
        // The recognizer punctuates speech like a sentence, and a comma can
        // land anywhere in a command — "commit saying, ship the fix", "add
        // everything, then push", "cd projects, folder". Each grammar piece
        // tolerates the common spots on its own; this second look covers the
        // rest by taking the punctuation out altogether. Second, not first,
        // so a message keeps its own commas whenever the words matched
        // without help.
        let loosened = loosen(clause)
        guard loosened != clause else { return nil }
        return build(loosened)
    }

    /// The recognizer's commas, semicolons, colons and dashes — the ones that
    /// sit between words, never the ones inside a token (`localhost:3000`).
    private static func loosen(_ clause: String) -> String {
        let out = clause
            .replacingOccurrences(of: "[,;:]+(?=\\s|$)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s*[—–]+\\s*", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        return tidy(out)
    }

    private static func build(_ clause: String) -> Line? {
        // A command is a short thing. Past this the words are a paragraph,
        // and a paragraph in a terminal is a prompt for an agent.
        guard !clause.isEmpty, clause.count <= 240, !isProse(clause) else { return nil }
        // "add everything and then commit with the message …" — the pair the
        // hands type most often, joined the way a shell joins them. Only when
        // BOTH halves are commands: one half short of it means the split was
        // an ordinary "and", and the whole clause gets one more try.
        if let parts = compound(clause) {
            let built = parts.filter { !isProse($0) }.compactMap { one($0) }
            if built.count == parts.count {
                let command = built.joined(separator: " && ")
                return Line(command: command, risky: isRisky(command))
            }
        }
        guard let command = one(clause) else { return nil }
        return Line(command: command, risky: isRisky(command))
    }

    /// A recipe first — the natural phrasings — then the literal layer for
    /// anything that simply names a tool. The recipe gets a second look with
    /// the recognizer's punctuation gone BEFORE the literal layer gets its
    /// first, so "git add, everything" is still `git add .` and not a typed-
    /// out `git add everything`.
    private static func one(_ clause: String) -> String? {
        recipe(clause) ?? recipe(loosen(clause)) ?? literal(clause)
    }

    /// Trailing sentence punctuation is the recognizer's, not the shell's.
    ///
    /// Except when it is a path: Go's `./...` really does end in dots, and a
    /// slash in the last word is the tell. Everything else still loses the
    /// full stop the recognizer puts on the end of every sentence.
    private static func tidy(_ s: String) -> String {
        var out = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let keepDots = (out.split(separator: " ").last?.contains("/")) ?? false
        while let last = out.last {
            if last == ".", keepDots { break }
            guard ".!?,;… \t\n".contains(last) else { break }
            out.removeLast()
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Politeness and connectives the shell has no use for, allowed in front
    /// of every recipe.
    private static let lead = "(?:(?:please|now|ok|okay|alright|just|then|and)[,;:]?\\s+)*"

    /// Openings that mean a sentence is coming, not a command. A terminal is
    /// full of agents to talk to, and talking to one must not run anything.
    private static func isProse(_ clause: String) -> Bool {
        if clause.contains("?") { return true }
        let openers = "can|could|would|will|shall|should|do|does|did|is|are|am|was|were|"
            + "have|has|had|why|what|when|where|who|whom|which|how|tell|explain|describe|"
            + "write|draft|help|think|look|read|review|check|see|try|let['’]?s|let\\s+us|"
            + "i|we|you|he|she|they|it|there|hey|hi|hello|thanks|thank|sorry|"
            + "also|but|so|because|if|maybe|actually|make\\s+sure|find\\s+out"
        // "where am I" and "what changed" are recipes, not prose — the
        // question-word gate lets those two through by name.
        // Anchored at BOTH ends: "which node" is a command, "which one should
        // we use" is a question. The difference is whether anything follows.
        let ok = "^(?:where\\s+am\\s+i|what\\s*['’]?s?\\s+(?:changed|in\\s+(?:here|this\\s+\\w+))|"
            + "what\\s+folder\\s+am\\s+i\\s+in|what\\s+branch|which\\s+[\\w.+/-]+$)"
        if clause.range(of: ok, options: [.regularExpression, .caseInsensitive]) != nil { return false }
        return clause.range(of: "^(?:\(openers))(?![\\w'’-])",
                            options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// "<command> and then <command>" split in two, or nil when there is no
    /// connective to split on.
    private static func compound(_ clause: String) -> [String]? {
        let ns = clause as NSString
        guard let re = try? NSRegularExpression(pattern: "[,;]?\\s+(?:and\\s+then|then|and)\\s+",
                                                options: [.caseInsensitive]) else { return nil }
        let hits = re.matches(in: clause, range: NSRange(location: 0, length: ns.length))
        guard !hits.isEmpty, hits.count <= 3 else { return nil }
        var parts: [String] = []
        var cursor = 0
        for h in hits {
            parts.append(ns.substring(with: NSRange(location: cursor, length: h.range.location - cursor)))
            cursor = h.range.location + h.range.length
        }
        parts.append(ns.substring(from: cursor))
        let cleaned = parts.map { tidy($0) }.filter { !$0.isEmpty }
        return cleaned.count >= 2 ? cleaned : nil
    }

    // MARK: - Recipes

    /// One spoken shape and the command it means. `build` gets the capture
    /// groups (0 is the whole match) and may return nil to decline — the gate
    /// that keeps "add a test for the login flow" from becoming a `git add`.
    private struct Recipe {
        let pattern: String
        let build: ([String?]) -> String?
        init(_ pattern: String, _ build: @escaping ([String?]) -> String?) {
            self.pattern = pattern
            self.build = build
        }
    }

    /// A name as spoken, up to four words — spoken punctuation included, so
    /// "old dot txt" is one name. Folders get called "test scripts" out loud
    /// far more often than they get called "testscripts".
    ///
    /// `stopping` lists the words that END a name rather than joining it: the
    /// noun the phrase closes on ("…the src FOLDER") and the preposition the
    /// next argument opens with ("rename old dot txt TO new dot txt"). Without
    /// it the capture is greedy and swallows them.
    private static func name(stopping stop: String = "") -> String {
        let guardWord = stop.isEmpty ? "" : "(?!(?:\(stop))(?![\\w'’-]))"
        let head = "\(guardWord)[A-Za-z0-9_~.][\\w.\\-/~@+]*"
        let tail = "\(guardWord)[A-Za-z0-9_][\\w.\\-/~@+]*"
        // Six, not three: spoken punctuation spends a word each, so
        // "Sources slash Shell dot swift" is five words for two names.
        return "(\(head)(?:\\s+\(tail)){0,6})"
    }
    private static let one1 = "([A-Za-z0-9_~.][\\w.\\-/~@+]*)"
    private static let many = name()
    private static let folderName = name(stopping: "folder|directory|dir")
    /// A commit message runs to the end of the clause.
    private static let rest = "(.+)"
    /// The ways a commit message gets introduced — including the flag itself,
    /// said out loud, which is how anyone who types git all day says it. The
    /// recognizer hears a pause after "saying" and writes a comma or a colon
    /// there; either is allowed, so the message still gets captured whole.
    private static let said =
        "(?:with\\s+(?:the\\s+)?message|saying|that\\s+says|message|-m|dash\\s+m)[,;:]?"
    private static let folderNoun = "(?:folder|directory|dir)"
    /// Nobody dictates "5". A count arrives as a word, so the grammar has to
    /// take one — and the recognizer only writes digits for the big ones.
    private static let spokenNumbers: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        "fifteen": 15, "twenty": 20, "thirty": 30, "fifty": 50, "hundred": 100,
        "a": 1, "an": 1, "a couple": 2, "a couple of": 2, "a few": 3, "a dozen": 12, "dozen": 12,
    ]
    /// Longest first, so "a couple of" is not read as the "a" inside it.
    private static let count: String = {
        let words = spokenNumbers.keys.sorted { $0.count > $1.count }
            .map { $0.replacingOccurrences(of: " ", with: "\\s+") }
        return "(\\d+|" + words.joined(separator: "|") + ")"
    }()

    private static func number(_ raw: String) -> Int? {
        if let n = Int(raw) { return n }
        let key = raw.lowercased().replacingOccurrences(of: "\\s+", with: " ",
                                                       options: .regularExpression)
        return spokenNumbers[key]
    }
    /// The recognizer hears "git" as "get" about as often as it gets it right,
    /// and only ever in front of a git verb — so it is safe to accept here.
    private static let git = "(?:git|get)\\s+"

    private static let recipes: [Recipe] = [
        // ── git ───────────────────────────────────────────────────────────
        // "add everything" is the one people say; "git add ." is what it means.
        Recipe("(?:\(git))?(?:add|stage)\\s+(?:everything|all|it\\s+all|all\\s+(?:the\\s+)?(?:changes|files))") { _ in
            "git add ."
        },
        // "Git add." — the recognizer ate the argument as a full stop. Bare
        // `git add` is not a command git accepts anyway, so the dot it was
        // missing is the only thing it could have been.
        Recipe("\(git)(?:add|stage)") { _ in "git add ." },
        // Bare "add <thing>" only when the thing looks like a file. Without
        // this gate every "add a test for the login flow" said to an agent
        // would become a git command.
        Recipe("(?:\(git))?(?:add|stage)\\s+(?:the\\s+file\\s+)?\(many)") { g in
            guard let raw = g[1] else { return nil }
            let name = nameToken(raw)
            let explicit = (g[0] ?? "").range(of: "^(?:git|get)\\s", options: [.regularExpression, .caseInsensitive]) != nil
            guard explicit || looksLikePath(name) else { return nil }
            return "git add \(name)"
        },
        // "commit everything with the message …" — -a stages the tracked ones.
        Recipe("(?:\(git))?commit\\s+(?:everything|all|-a|dash\\s+a)\\s+\(said)\\s+\(rest)") { g in
            g[1].map { "git commit -a -m \(message($0))" }
        },
        Recipe("(?:\(git))?commit\\s+\(said)\\s+\(rest)") { g in
            g[1].map { "git commit -m \(message($0))" }
        },
        Recipe("(?:\(git))?commit\\s+(?:everything|all|the\\s+changes)") { _ in "git commit -a" },
        Recipe("(?:\(git))?commit") { _ in "git commit" },

        Recipe("(?:\(git))?push\\s+to\\s+(?:the\\s+)?\(one1)(?:\\s+branch)?") { g in
            g[1].map { "git push origin \(nameToken($0))" }
        },
        Recipe("(?:\(git))?push(?:\\s+(?:it|them|the\\s+changes|everything))?") { _ in "git push" },
        Recipe("(?:\(git))?pull(?:\\s+(?:it|the\\s+changes|everything))?") { _ in "git pull" },
        Recipe("(?:\(git))?fetch") { _ in "git fetch" },
        Recipe("(?:\(git))?(?:status|what\\s+changed)") { _ in "git status" },
        Recipe("(?:\(git))?(?:diff|show\\s+(?:me\\s+)?the\\s+diff)") { _ in "git diff" },
        // "show me last five commits" — no "the", and the count is a word.
        // This is the shape the phrasing actually arrives in.
        Recipe("(?:(?:show|list|give|see)\\s+(?:me\\s+)?)?(?:the\\s+)?last\\s+\(count)\\s+commits?") { g in
            g[1].flatMap(number).map { "git log --oneline -\($0)" }
        },
        Recipe("(?:(?:show|list|give)\\s+(?:me\\s+)?)?(?:the\\s+)?last\\s+commit") { _ in "git log --oneline -1" },
        Recipe("(?:\(git))?log") { _ in "git log --oneline" },
        Recipe("what\\s+branch(?:\\s+am\\s+i\\s+on)?") { _ in "git branch --show-current" },
        Recipe("(?:make|create|start)\\s+(?:a\\s+)?(?:new\\s+)?branch\\s+(?:called\\s+|named\\s+)?\(many)") { g in
            g[1].map { "git checkout -b \(nameToken($0))" }
        },
        Recipe("(?:\(git))?(?:checkout|switch\\s+to)\\s+(?:the\\s+)?\(name(stopping: "branch"))(?:\\s+branch)?") { g in
            g[1].map { "git checkout \(nameToken($0))" }
        },
        Recipe("(?:\(git))?stash(?:\\s+(?:everything|it|the\\s+changes))?") { _ in "git stash" },

        // ── folders and files ─────────────────────────────────────────────
        Recipe("(?:make|create)\\s+(?:a\\s+)?(?:new\\s+)?\(folderNoun)\\s+(?:called\\s+|named\\s+|for\\s+)?\(folderName)") { g in
            g[1].map { "mkdir \(nameToken($0))" }
        },
        Recipe("(?:make|create)\\s+(?:a\\s+)?(?:new\\s+)?file\\s+(?:called\\s+|named\\s+|for\\s+)?\(many)") { g in
            g[1].map { "touch \(nameToken($0))" }
        },
        Recipe("(?:go|move)\\s+(?:up|back)(?:\\s+(?:one|a)(?:\\s+level)?)?(?:\\s+\(folderNoun))?") { _ in "cd .." },
        Recipe("(?:go|cd)\\s+home|(?:go|cd)\\s+to\\s+(?:the\\s+)?home\\s+\(folderNoun)") { _ in "cd ~" },
        Recipe("(?:go|cd|change\\s+(?:the\\s+)?director(?:y|ies)|switch)\\s+"
               + "(?:in)?to\\s+(?:the\\s+|my\\s+)?\(folderName)(?:\\s+\(folderNoun))?") { g in
            g[1].map { "cd \(folderPath($0))" }
        },
        // "list the files", "show me everything in here"
        Recipe("(?:list|show)\\s+(?:me\\s+)?(?:all|everything|all\\s+the\\s+files?|"
               + "the\\s+hidden\\s+files?)(?:\\s+in\\s+(?:here|this\\s+\(folderNoun)))?") { _ in "ls -la" },
        Recipe("(?:list|show)\\s+(?:me\\s+)?(?:the\\s+)?(?:files?|contents)"
               + "(?:\\s+in\\s+(?:here|this\\s+\(folderNoun)))?|what['’]?s\\s+in\\s+(?:here|this\\s+\(folderNoun))") { _ in "ls" },
        Recipe("(?:where\\s+am\\s+i|what\\s+folder\\s+am\\s+i\\s+in|print\\s+the\\s+working\\s+director(?:y|ies))") { _ in "pwd" },
        Recipe("clear(?:\\s+the\\s+(?:screen|terminal|window))?") { _ in "clear" },
        // Deliberately absent: rm, cp, mv and cat. Deleting or overwriting a
        // file is not something a MISHEARD sentence should be allowed to
        // write, and "move the retry logic into its own function" is a
        // sentence you say to an agent, not an order to a shell. Say
        // "rm build dot log" and the literal layer still types it — that is
        // you spelling out a command, not SayCtrl guessing at one.
    ]

    private static func recipe(_ clause: String) -> String? {
        let ns = clause as NSString
        let whole = NSRange(location: 0, length: ns.length)
        for r in recipes {
            guard let re = try? NSRegularExpression(pattern: "^\(lead)(?:\(r.pattern))\\s*$",
                                                   options: [.caseInsensitive]),
                  let m = re.firstMatch(in: clause, range: whole) else { continue }
            let groups = (0..<m.numberOfRanges).map { i -> String? in
                let g = m.range(at: i)
                return g.location == NSNotFound ? nil : ns.substring(with: g)
            }
            if let out = r.build(groups) { return out }
        }
        return nil
    }

    // MARK: - The literal layer

    /// Tools worth typing for. A command SayCtrl has no recipe for still lands
    /// as long as it names one of these first — which is the difference
    /// between "we don't know that one" and "we can't help you".
    private static let binaries: Set<String> = [
        "git", "gh", "npm", "npx", "pnpm", "yarn", "bun", "bunx", "deno", "node",
        "python", "python3", "pip", "pip3", "uv", "poetry", "pytest", "ruby", "rails",
        "cargo", "rustc", "go", "swift", "swiftc", "xcodebuild", "java", "mvn", "gradle",
        "dotnet", "php", "composer", "make", "cmake", "docker", "kubectl", "helm",
        "terraform", "vercel", "wrangler", "flyctl", "heroku", "aws", "gcloud",
        "brew", "apt", "curl", "wget", "ssh", "scp", "rsync", "tar", "zip", "unzip",
        "ls", "cd", "pwd", "mkdir", "rmdir", "rm", "cp", "mv", "touch", "cat", "less",
        "head", "tail", "grep", "rg", "find", "fd", "sed", "awk", "sort", "uniq", "wc",
        "chmod", "chown", "ln", "df", "du", "ps", "top", "kill", "killall", "which",
        "whoami", "man", "echo", "export", "source", "open", "code", "vim", "nvim",
        "nano", "emacs", "clear", "history", "diff", "jq", "tsc", "eslint", "prettier",
        "jest", "vitest", "playwright", "psql", "mysql", "sqlite3", "redis-cli", "sudo",
    ]

    /// Words the shell owns, so they are lowered even when the recognizer
    /// capitalises them. Anything NOT here is a name and keeps its case —
    /// which is exactly the rule that saves `cd SayCtrl` and `git checkout Fix-Login`.
    private static let shellWords: Set<String> = [
        "add", "stage", "commit", "push", "pull", "fetch", "merge", "rebase", "clone",
        "status", "diff", "log", "checkout", "switch", "branch", "stash", "reset",
        "remote", "tag", "init", "restore", "revert", "cherry-pick", "blame", "show",
        "install", "uninstall", "run", "start", "stop", "restart", "build", "dev",
        "test", "lint", "format", "watch", "serve", "publish", "deploy", "update",
        "upgrade", "list", "exec", "create", "delete", "remove", "compose", "up",
        "down", "logs", "images", "ps", "prune", "login", "logout", "link", "unlink",
        "all", "force", "help", "version", "global", "save", "latest", "local",
        "and", "the", "a", "an", "to", "in", "on", "at", "of", "it", "everything",
        "clean", "amend", "cached", "hard", "soft", "oneline", "graph", "staged",
        "recursive", "verbose", "quiet", "watch", "coverage", "production",
    ]

    /// Spoken punctuation. A terminal is mostly punctuation, and none of it
    /// survives a recognizer that is trying to write English.
    private static let symbols: [String: String] = [
        "dash": "-", "hyphen": "-", "minus": "-",
        "dot": ".", "period": ".", "point": ".",
        "slash": "/", "backslash": "\\",
        "tilde": "~", "star": "*", "asterisk": "*", "underscore": "_",
        "pipe": "|", "ampersand": "&", "equals": "=", "colon": ":", "semicolon": ";",
        "plus": "+", "caret": "^", "percent": "%", "hash": "#", "pound": "#",
        "dollar": "$", "backtick": "`", "quote": "\"", "comma": ",",
    ]

    /// Two-word symbols, tried before the one-word table.
    private static let symbolPairs: [String: String] = [
        "double dash": "--", "dash dash": "--", "double hyphen": "--",
        "dot dot": "..", "dot slash": "./", "greater than": ">", "less than": "<",
        "double ampersand": "&&", "dollar sign": "$", "hash tag": "#",
        "open paren": "(", "close paren": ")", "open brace": "{", "close brace": "}",
        "open bracket": "[", "close bracket": "]", "question mark": "?",
    ]

    /// Tools whose names are also ordinary English verbs. "git" in front of
    /// words is proof of a command; "go", "make", "clear" and "find" are how
    /// half the sentences a developer dictates to an agent begin. These need
    /// a tail that looks like a shell's — a flag, a path, or nothing but the
    /// shell's own words — before they count.
    private static let ambiguous: Set<String> = [
        "go", "make", "open", "find", "clear", "head", "tail", "top", "kill",
        "less", "man", "sort", "touch", "diff", "history", "source", "code",
        "cat", "which", "export", "test", "watch", "list", "show", "run",
    ]

    private enum Atom {
        case word(String)
        case symbol(String)
    }

    /// Words in, words and symbols out — the spoken punctuation resolved and
    /// the shell's own vocabulary lowered.
    ///
    /// `lowerFirst` is the tool rule: the word that opens a command is lowered
    /// whatever the recognizer did with it ("Git" → `git`, "Touch" → `touch`).
    /// A NAME gets this off, because the first word of a name is the name —
    /// lowering it would turn `Shell.swift` into `shell.swift`.
    private static func atomise(_ clause: String, lowerFirst: Bool = true) -> [Atom] {
        let raw = clause.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        var out: [Atom] = []
        var i = 0
        while i < raw.count {
            let word = raw[i]
            let key = word.lowercased()
            if i + 1 < raw.count {
                let pair = "\(key) \(raw[i + 1].lowercased())"
                if let sym = symbolPairs[pair] {
                    out.append(.symbol(sym))
                    i += 2
                    continue
                }
            }
            if let sym = symbols[key] {
                out.append(.symbol(sym))
                i += 1
                continue
            }
            // A token the recognizer already wrote as punctuation.
            if word.count <= 2, word.allSatisfy({ "-./~*|&=:;+^%#$`\\<>".contains($0) }) {
                out.append(.symbol(word))
                i += 1
                continue
            }
            // The first word is the tool, always lower. After that, lower only
            // what the shell owns — everything else is a name, and a name keeps
            // the case it was spoken in.
            let lowered = (out.isEmpty && lowerFirst) || shellWords.contains(key)
            out.append(.word(lowered ? key : word))
            i += 1
        }
        return out
    }

    /// Symbols that bind to whatever follows with no space between: a flag,
    /// a home path, a leading "./".
    private static let bindsRight: Set<String> = ["-", "--", "~", "./", "../", "$"]
    /// Symbols that bind on BOTH sides when a word sits either side, so
    /// "package dot json" is one filename and not three tokens.
    private static let bindsBoth: Set<String> = [".", "/", "_", "@", ":", "-", "+", "="]

    /// A "-" is a flag after the tool or one of the shell's own words, and a
    /// hyphen inside a name anywhere else: `docker compose up -d`, but
    /// `cd sayctrl-web`. "--" is never anything but a flag.
    ///
    /// After a word the shell does not own, the LENGTH of what follows decides:
    /// flags are one or two letters (`-fd`, `-rf`, `-b`), the second half of a
    /// hyphenated name is a word. Spelling a hyphen aloud is rare and a wrong
    /// guess is visible at the prompt, so this leans towards the flag.
    private static func isFlag(_ symbol: String, after previous: String?, before next: String?) -> Bool {
        if symbol != "-" { return true }
        guard let p = previous?.lowercased() else { return true }   // opens the line
        if shellWords.contains(p) || binaries.contains(p) { return true }
        return (next?.count ?? 0) <= 2
    }

    private static func glue(_ atoms: [Atom]) -> String {
        var out = ""
        // Set by a symbol that binds rightwards: the next word joins it flush.
        var joinNext = false
        func word(_ n: Int) -> String? {
            guard n >= 0, n < atoms.count, case .word(let w) = atoms[n] else { return nil }
            return w
        }
        func space() { if !out.isEmpty, !out.hasSuffix(" ") { out += " " } }
        for (i, atom) in atoms.enumerated() {
            switch atom {
            case .word(let w):
                if joinNext { out += w } else { space(); out += w }
                joinNext = false
            case .symbol(let sym):
                if bindsRight.contains(sym), word(i + 1) != nil,
                   isFlag(sym, after: word(i - 1), before: word(i + 1)) {
                    space()
                    out += sym
                    joinNext = true
                } else if bindsBoth.contains(sym), word(i - 1) != nil, word(i + 1) != nil {
                    // "package dot json" → package.json. A dot with nothing
                    // after it is the shell's own "here" argument and stands
                    // alone, which is what `git add .` is made of.
                    out += sym
                    joinNext = true
                } else {
                    space()
                    out += sym
                    joinNext = false
                }
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// A tool name in front is all the proof needed that this is a command —
    /// unless the tool is also a word, in which case the tail has to prove it.
    private static func literal(_ clause: String) -> String? {
        let atoms = atomise(clause)
        guard let first = atoms.first, case .word(let w) = first,
              binaries.contains(w.lowercased()) else { return nil }
        let command = unpunctuate(quoteProseFlag(glue(atoms)))
        // Judged AFTER glue, never before: the recognizer writes "package.json"
        // as one token, so there is no separate "." atom to find, and a tail
        // read atom by atom looks like plain English. Glued, the same tail is
        // obviously a filename. (This is what made "Touch package.json" fall
        // through to prose and come back sentence-cased.)
        if ambiguous.contains(w.lowercased()), !isShellShaped(command) { return nil }
        return command
    }

    /// The recognizer's commas, semicolons and colons, taken out of the part
    /// of the line that is shell — "git add, everything" is not a command any
    /// shell takes. The quoted message at the end is prose and keeps its own.
    private static func unpunctuate(_ command: String) -> String {
        var head = command
        var tail = ""
        // The first unescaped quote opens the message; nothing after it is
        // the shell's business.
        var escaped = false
        for (i, ch) in command.enumerated() {
            if escaped { escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "\"" {
                let cut = command.index(command.startIndex, offsetBy: i)
                head = String(command[..<cut])
                tail = String(command[cut...])
                break
            }
        }
        head = head.replacingOccurrences(of: "[,;:]+(?=\\s|$)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        return (head + tail).trimmingCharacters(in: .whitespaces)
    }

    /// Flags whose argument is a sentence. Said aloud they arrive as loose
    /// words — `git commit -m fixed the login bug` hands git one word and
    /// three paths — so the tail is gathered back into one quoted argument,
    /// with the case it was spoken in, exactly as the recipes do it.
    private static let proseFlags = ["-m", "--message", "--title", "-am"]

    private static func quoteProseFlag(_ command: String) -> String {
        let parts = command.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard let i = parts.lastIndex(where: { proseFlags.contains($0) }),
              i + 2 < parts.count else { return command }
        let tail = parts[(i + 1)...].joined(separator: " ")
        // Already one argument, or the user quoted it themselves.
        guard !tail.hasPrefix("\""), !tail.hasPrefix("'") else { return command }
        return (parts[...i] + [message(tail)]).joined(separator: " ")
    }

    /// Every token after the tool is something a shell would actually take:
    /// a flag, a path or filename, a number, a quoted string, or one of the
    /// shell's own words. One ordinary English word in there and this was a
    /// sentence — "clear up the confusion in the README" is not `clear`.
    private static func isShellShaped(_ command: String) -> Bool {
        let tail = command.split(separator: " ").dropFirst().map(String.init)
        if tail.isEmpty { return true }
        return tail.allSatisfy { token in
            if token.hasPrefix("-") { return true }                 // a flag
            if token.contains("/") || token.contains(".") || token.contains("~") { return true }
            if token.hasPrefix("\"") || token.hasPrefix("$") || token.hasPrefix("*") { return true }
            if Int(token) != nil { return true }
            let key = token.lowercased()
            // A tool is a fine argument to another tool: `which node`,
            // `man git`, `kill node`.
            return shellWords.contains(key) || binaries.contains(key)
        }
    }

    // MARK: - Names and messages

    /// A name as it should be typed. Spoken symbols are resolved, and a name
    /// said as several words becomes one the way developers write one —
    /// "test scripts" is `test-scripts`. A guess, but a visible one: it sits
    /// at the prompt until the human presses Return.
    private static func nameToken(_ raw: String) -> String {
        let glued = glue(atomise(tidy(raw), lowerFirst: false))
        if !glued.contains(" ") { return glued }
        // A flag among the words means these were never one name — "checkout
        // dash b feature slash auth" is a branch behind a flag, and joining it
        // up would make `-b-feature/auth`. Hand it back as spoken instead.
        let pieces = glued.split(separator: " ")
        if pieces.contains(where: { $0.hasPrefix("-") }) { return glued }
        return pieces.joined(separator: "-")
    }

    /// The standard home folders, said by name, mean the ones in your home —
    /// "go to downloads" is `cd ~/Downloads`, which is what you meant and
    /// what you would have typed.
    private static let homeFolders = ["downloads": "Downloads", "desktop": "Desktop",
                                      "documents": "Documents", "applications": "/Applications",
                                      "home": "~", "root": "/"]

    private static func folderPath(_ raw: String) -> String {
        let name = nameToken(raw)
        if let known = homeFolders[name.lowercased()] {
            return known.hasPrefix("/") || known == "~" ? known : "~/\(known)"
        }
        return name
    }

    /// A commit message is prose, so it keeps every capital it was spoken
    /// with — the one place in a command where case is the user's, not the
    /// shell's. Quoted so the shell reads it as one argument.
    private static func message(_ raw: String) -> String {
        var m = tidy(raw)
        // A recognizer that already quoted it must not get quoted twice.
        for (open, close) in [("\"", "\""), ("“", "”"), ("'", "'"), ("‘", "’")] {
            if m.hasPrefix(open), m.hasSuffix(close), m.count > 1 {
                m = String(m.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            }
        }
        // Curly quotes are the recognizer's idea of typography and a syntax
        // error in a shell; everything the shell would expand is escaped.
        m = m.replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "‘", with: "'").replacingOccurrences(of: "’", with: "'")
        var escaped = ""
        for ch in m {
            if ch == "\\" || ch == "\"" || ch == "$" || ch == "`" { escaped.append("\\") }
            escaped.append(ch)
        }
        return "\"\(escaped)\""
    }

    /// Something shaped like a file or a folder rather than a phrase — an
    /// extension, a path separator, or one bare word.
    private static func looksLikePath(_ name: String) -> Bool {
        if name.contains("/") || name.contains(".") || name.contains("~") { return true }
        return !name.contains(" ") && !name.contains("-")
    }

    // MARK: - The dangerous corner

    /// Commands that cannot be taken back. These still get typed — refusing to
    /// write `rm` would be its own kind of broken — but "send it" will not
    /// press Return on one, and the HUD says so.
    static func isRisky(_ command: String) -> Bool {
        let c = command.lowercased()
        let patterns = [
            "^rm\\b", "\\brm\\s+-[a-z]*[rf]", "^sudo\\b", "^dd\\b", "\\bmkfs",
            // A word boundary will not match between a space and a dash, so a
            // flag is anchored on the space in front of it, not on \\b.
            "^chmod\\s+777", "^chown\\b", "(?:^|\\s)--force(?:\\b|$)", "\\bpush\\s+-[a-z]*f\\b",
            "\\breset\\s+--hard\\b", "\\bclean\\s+-[a-z]*[fd]", "^killall\\b",
            "\\bkill\\s+-9\\b", "^shutdown\\b", "^reboot\\b", "^diskutil\\b",
            "\\|\\s*(?:sh|bash|zsh)\\b", "\\bprune\\b", "\\bpublish\\b",
            "^:\\(\\)", ">\\s*/dev/", "\\bdrop\\s+(?:table|database)\\b",
        ]
        return patterns.contains { c.range(of: $0, options: .regularExpression) != nil }
    }
}
