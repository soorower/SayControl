// What the recognizer should expect to hear — one list, every recognizer.
//
// A dictation recognizer is a guesser, and a guess is only as good as what it
// was told to expect. The paid providers take that as keyterms on the socket
// (ElevenLabs, AssemblyAI) or a `prompt` field on the upload (OpenAI-style),
// and whisper.cpp takes it as `initial_prompt`; Parakeet takes nothing at
// all, and for that engine the only net is the fuzzy matching downstream
// (Commands.pickOrdinalFuzzy, the "get" the shell grammar accepts for "git").
//
// Until 2026-08-22 each of the three paths carried its own copy of the list,
// and none of them knew WHERE the words were going. So "commit saying" was
// heard as "commit, same shape" in a terminal, "the third one" came back as
// "That hard one" with a picker on screen, and the local model — whose
// prompt is capped at ~223 tokens, with whisper.cpp keeping the LAST ones —
// was quietly dropping the commands off the front of its list whenever the
// screen's words pushed it over.
//
// This file is the one list, ranked by how much a miss costs:
//
//   1. A picker's replies while a picker is up — a misheard "the third one"
//      is the wrong file in the chat, and the whole utterance is an answer.
//   2. The spoken commands (or the command-mode instructions while armed):
//      mishearing one costs a feature, not a word.
//   3. The shell's vocabulary while a terminal is in front — the recipe
//      triggers and the tool names the literal layer accepts.
//   4. The user's own name, the phrase triggers.
//   5. App and site names "open …" and "ask …" aim at, and the attach
//      family's nouns and folders.
//   6. The dictionary and the screen's words, as before.
//
// Each provider then takes as many as it can carry, from the top.
import Foundation

enum Hints {

    /// Where this dictation is landing — set once per recording, before any
    /// recognizer is started, so every path sees the same answer.
    struct Context {
        /// A terminal is the front app: the shell's words are expected.
        var terminal = false
        /// A picker is on screen: a short reply is an answer to it.
        var picker = false
    }
    static var context = Context()

    // MARK: - The lists

    /// The spoken commands. Being heard right is the only fix there is —
    /// nothing downstream rewrites "copy file both" back into a command.
    static let commands = [
        "copy file path", "take a screenshot", "copy the link", "copy the URL",
        "ask ChatGPT", "ask Claude", "ask Grok", "ask Perplexity", "ask Google",
        "attach the image", "attach the screenshot", "upload the image",
        "upload the folder",
        "scratch that", "undo the last sentence", "send it",
        "use the local model", "use the paid model",
    ]

    /// How a picker gets answered. "the first one" is what people say; the
    /// rest are the shapes Commands.pickOrdinal reads.
    static let pickerReplies = [
        "the first one", "the second one", "the third one",
        "the fourth one", "the fifth one", "the last one",
        "number one", "number two", "number three", "cancel",
    ]

    /// The shell, as spoken: the recipe triggers in Shell.swift and the tools
    /// the literal layer types for — the ones the recognizer fumbles ("commit,
    /// same shape" for "commit saying"), not the ones it already hears
    /// (`cd`, `ls`, `sudo`). Spoken symbols ride along — "dash m" and "dot
    /// json" are the two that turn a sentence into a command. Kept short on
    /// purpose: every entry here is one fewer screen word that fits, and a
    /// terminal is also where Claude Code gets dictated at.
    static let terminalWords = [
        "git add", "add everything", "git commit", "commit saying",
        "git push", "git pull", "git status", "git checkout", "git stash", "git log",
        "npm run dev", "npm install", "pnpm", "npx", "pip install", "brew install",
        "docker compose", "mkdir", "touch", "chmod",
        "dash m", "dot json", "package.json", "Claude Code",
    ]

    /// The names "open …" and "ask …" aim at. The recognizer spells a brand
    /// its own way unprompted — "Chat GBT", "cloud", "grock" — and while
    /// OpenTarget forgives the usual ones, being heard right is cheaper.
    static let appNames = [
        "Google Chrome", "Arc", "Safari", "ChatGPT", "Claude", "Gemini", "Grok",
        "Perplexity", "Copilot", "Cursor", "VS Code", "Xcode", "Notion", "Slack",
        "Figma", "Spotify", "Finder", "Terminal", "iTerm", "Warp",
        "WhatsApp", "Telegram", "Discord", "YouTube", "GitHub",
    ]

    /// The attach family beyond its headline phrases: the other kinds it
    /// takes, and the folders it is pointed at.
    static let attachWords = [
        "attach the PDF", "attach the file", "attach the video",
        "from downloads", "from the desktop", "from documents",
        "the downloads folder", "the projects folder",
    ]

    // MARK: - Ranking

    /// Every hint, most important first, no duplicates, no cap. Callers
    /// take what they can carry from the front.
    static func ranked() -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ words: [String]) {
            for w in words {
                let word = w.trimmingCharacters(in: .whitespaces)
                guard !word.isEmpty, seen.insert(word.lowercased()).inserted else { continue }
                out.append(word)
            }
        }
        if context.picker { add(pickerReplies) }
        // In command mode the utterance IS an instruction, so instruction
        // phrasing takes the commands' slot — "polish" misheard as "what is"
        // answers the text instead of editing it.
        add(CommandMode.armed ? CommandMode.spokenPhrases : commands)
        if context.terminal { add(terminalWords) }
        // The dictating user's own name is the one proper noun nearly every
        // session carries — introductions, sign-offs — and the recognizer
        // invents a fresh spelling for it each time it goes unhinted (Swarup,
        // Swaraj, Swarwat for "Sorower", all in one hour, 2026-08-20).
        add(Account.name.split(separator: " ").map(String.init).filter { $0.count >= 2 })
        // A phrase fires only when its trigger is heard exactly, so one
        // fumbled word is the shortcut silently not happening.
        add(PhraseStore.shared.spokenTriggers)
        add(appNames)
        add(attachWords)
        let rules = ReplacementStore.shared.rules
        // Hint-only entries ("area" → "idea", where "area" is a real word) and
        // the screen's words go before the regular rules: nothing rewrites
        // those after the fact, so being heard right is their only chance —
        // while a regular rule's dictionary pass still catches its
        // mishearing later.
        add(rules.filter { $0.hintOnly }.map { $0.to })
        add(ScreenVocab.shared.words)
        add(rules.filter { !$0.hintOnly }.map { $0.to })
        return out
    }

    /// The first `cap` hints, skipping any longer than `maxLength` characters
    /// — ElevenLabs hard-rejects a keyterm over 20, and one long entry
    /// poisons the whole list because the socket refuses the session.
    static func list(cap: Int, maxLength: Int = Int.max) -> [String] {
        var out: [String] = []
        for word in ranked() {
            guard out.count < cap else { break }
            guard word.count <= maxLength else { continue }
            out.append(word)
        }
        return out
    }

    /// The same ranking, narrowed to what a recognizer could NOT have guessed:
    /// a term survives only if one of its words is missing from the
    /// dictionary — "Sorower", "RealtyAPI", "TanStack", "reqkey".
    ///
    /// For a provider whose keyterms BOOST rather than suggest. xAI's do, and
    /// hard: with the full list on the socket, "take a screenshot" turned a
    /// plain "Can you check if that website appears on Google search?" into
    /// "Can you take that? Website, Appyars on Google search." and "also check
    /// that" into "also take that" (measured 2026-09-19, same audio, only the
    /// list differing). Every phrase made of ordinary words is a phrase the
    /// model already hears right and a standing bribe to hear it where it
    /// wasn't said — so the commands, the attach nouns, "what", "It" and
    /// "after" all stay home, and the names still ride: "open club" comes
    /// back "Open Claude" on this list exactly as it did on the full one.
    /// Main thread only (Lexicon asks NSSpellChecker).
    static func coinages(cap: Int, maxLength: Int = Int.max) -> [String] {
        guard Thread.isMainThread else {
            return DispatchQueue.main.sync { coinages(cap: cap, maxLength: maxLength) }
        }
        var out: [String] = []
        for term in ranked() {
            guard out.count < cap else { break }
            guard term.count <= maxLength else { continue }
            let words = term.split(whereSeparator: { $0 == " " || $0 == "-" })
            // Asked in lowercase: the checker waves a capital through as a
            // name, and "It" is not one.
            let coined = words.contains { word in
                let key = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
                if let known = realWords[key] { return !known }
                let known = key.isEmpty || Lexicon.isRealWord(key)
                realWords[key] = known
                return !known
            }
            if coined { out.append(term) }
        }
        return out
    }
    /// Main-thread memo for `coinages`: the lists barely change between
    /// dictations, and each miss is a round trip to the spell server.
    private static var realWords: [String: Bool] = [:]

    /// The AI tools and products people dictate about to their agents. Qwen3
    /// heard "Open Claude" as "Open clot", "Open Cloud" and "Open close" while
    /// Claude was off its list, and right with it on (2026-10-02). No "OpenAI":
    /// with it on the list, one "Open Claude" came back "OpenAI."
    static let productNames = [
        "Claude", "Claude Code", "ChatGPT", "Gemini", "Grok", "Perplexity",
        "Qwen3", "Qwen 3", "Cohere", "Soniox", "Nemotron", "Parakeet", "Whisper", "Wispr Flow",
        "SayControl", "Anthropic", "OpenRouter", "ElevenLabs", "AssemblyAI",
        "Deepgram", "MAI Transcribe", "Cursor", "GitHub", "Cloudflare", "Vercel", "RunPod",
    ]

    /// Qwen3-ASR's context: names only, real words included. `coinages` drops
    /// any term the spell checker knows, and it knows "claude" as a first
    /// name — but Qwen3 reads the list as context rather than boosting it, so
    /// a name made of a real word is exactly the one it needs. Ordinary
    /// phrases (the commands, "from downloads") stay out: they cost Qwen3
    /// accuracy and it hears them anyway. Most important first, and short:
    /// with 30 Dictionary words ahead of the products, "Qwen 3" came back
    /// "point three" and "Qwen2", and "six out of twenty-four" "six hour
    /// twenty four"; with the products first and the list short, all three
    /// were right (2026-10-02). So: the user's name, these products, up to
    /// ten of the screen's unusual words, the Dictionary (typed-in entries,
    /// then learned ones by use), the app names, then the
    /// screen's coined words. A Dictionary entry counts as a
    /// name when it is capitalised or not a real word — "Raman" and "reqkey"
    /// go, "super fast" and "ideas" do not. Main thread only, as `coinages`.
    static func names(cap: Int) -> [String] {
        guard Thread.isMainThread else { return DispatchQueue.main.sync { names(cap: cap) } }
        var out: [String] = []
        var seen = Set<String>()
        func add(_ terms: [String]) {
            for t in terms {
                let term = t.trimmingCharacters(in: .whitespaces)
                guard out.count < cap, !term.isEmpty, term.count <= 50,
                      seen.insert(term.lowercased()).inserted else { continue }
                out.append(term)
            }
        }
        func isName(_ term: String) -> Bool {
            term.split(whereSeparator: { $0 == " " || $0 == "-" }).contains { word in
                if word.first?.isUppercase == true { return true }
                let key = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
                if let known = realWords[key] { return !known }
                let known = key.isEmpty || Lexicon.isRealWord(key)
                realWords[key] = known
                return !known
            }
        }
        add(Account.name.split(separator: " ").map(String.init).filter { $0.count >= 2 })
        add(productNames)
        // The screen's unusual words next, up to ten: they are what this take
        // is most likely about. Below the Dictionary they never made the cut.
        add(Array(ScreenVocab.shared.scannedWords.prefix(10)))
        // Entries the user typed in themselves first, then the learned ones by use.
        let rules = ReplacementStore.shared.rules.sorted {
            $0.learned != $1.learned ? !$0.learned : $0.hits > $1.hits
        }
        add(rules.map { $0.to }.filter(isName))
        add(appNames)
        add(coinages(cap: cap))
        return out
    }

    /// The OpenAI-style `prompt` field: a comma list, the front of the
    /// ranking.
    static func prompt(cap: Int = 48) -> String {
        list(cap: cap).joined(separator: ", ")
    }

    /// whisper.cpp's `initial_prompt` — and it is NOT the list the keyterm
    /// providers get. Whisper reads the prompt as the transcript that came
    /// just before the audio, and writes on in the same style. Fed the comma
    /// list, it answered "open Claude" with "open, upload," — a list — and
    /// lifted "upload" out of the hints to do it (nine clips, 2026-08-22:
    /// two usable). Fed prose that ENDS on the short commands, the same
    /// nine came back "Open Cloud" or "Open Claude" eight times, and a
    /// normal dictation kept its commas.
    ///
    /// So this is a paragraph. The names go first, inside a sentence; then
    /// a sentence of ordinary prose that carries the inline commands; then
    /// the whole-utterance commands as sentences of their own, the most
    /// important last, nearest the audio. Whisper keeps at most 223 prompt
    /// tokens and cuts from the FRONT ("will use only the last N tokens"),
    /// so the names — measured at 3.3–3.7 characters a token on these
    /// lists — are trimmed to the budget here, and the commands never are.
    static func whisperPrompt(budget: Int = 700) -> String {
        func sentence(_ s: String) -> String {
            guard let first = s.first else { return s }
            return first.uppercased() + s.dropFirst() + "."
        }
        func prose(_ words: [String]) -> String {
            guard let last = words.last else { return "" }
            return words.count == 1 ? last : words.dropLast().joined(separator: ", ") + " and " + last
        }

        // The closing sentences: the commands said on their own.
        var closing = ["use the local model", "ask Claude how to fix this",
                       "open terminal in the projects folder",
                       "open Safari", "open Chrome", "open ChatGPT", "open Claude"]
        if CommandMode.armed { closing = CommandMode.spokenPhrases }
        // A picker's replies go last, nearest the clip — but only a few, and
        // out of counting order. Whisper continues whatever it was primed
        // with: the comma list that ended "…the second one, the first one"
        // made it write one "the fifth one" as "the fifth one, the fifth
        // one," (five of fifteen saved replies), and six replies in order
        // as sentences still echoed one in fifteen. Three, unordered, ending
        // on the commonest reply, echoed none (whisper-large, 2026-08-22);
        // Commands.pickReply reads the echo anyway when it comes.
        if context.picker { closing += ["the third one", "the fifth one", "the first one"] }
        let tail = closing.map(sentence).joined(separator: " ")

        // The register: a few sentences of prose, commands in the middle.
        var middle = "Most of what I dictate is ordinary prose, a few sentences at a time, and in "
            + "the middle of it I take a screenshot, copy the file path, copy the link, or attach "
            + "the image from downloads, and sometimes I scratch that, undo the last sentence, or send it."
        if context.terminal {
            // The shell words the recognizer actually fumbles; the full list
            // would spend the names' budget, and a terminal is also where
            // Claude Code gets dictated at.
            middle += " In the terminal I say " + prose(["git add", "add everything", "commit saying",
                "git push", "git status", "git checkout", "npm run dev", "pip install",
                "docker compose", "mkdir", "touch", "dash m", "dot json", "package.json"]) + "."
        }

        // The names, as many as fit.
        let me = Account.name.split(separator: " ").first.map(String.init) ?? "I"
        let rules = ReplacementStore.shared.rules
        var seen = Set<String>()
        var vocab: [String] = []
        var pool: [String] = PhraseStore.shared.spokenTriggers
        pool += rules.filter({ $0.hintOnly }).map({ $0.to })
        pool += ScreenVocab.shared.words
        pool += rules.filter({ !$0.hintOnly }).map({ $0.to })
        pool += appNames
        for w in pool {
            let word = w.trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty, word.lowercased() != me.lowercased(),
                  seen.insert(word.lowercased()).inserted else { continue }
            vocab.append(word)
        }
        let fixed = middle.count + 1 + tail.count
        var kept: [String] = []
        var head = ""
        for word in vocab {
            let candidate = kept + [word]
            let text = "\(me) works with " + prose(candidate) + "."
            guard text.count + 1 + fixed <= budget else { break }
            kept = candidate
            head = text
        }
        return [head, middle, tail].filter { !$0.isEmpty }.joined(separator: " ")
    }
}
