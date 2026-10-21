// Tones: how your words come out, once they've been heard.
//
// SayCtrl already knew WHERE a paste was headed (AppStyle.swift picks the front
// app apart into email, chat, code). Tones is the other half — you say how
// each of those should read. Four contexts, one chosen tone each:
//
//   Personal   friends, family, your own notes
//   Work       team chat, tickets, documents
//   Email      any mail client, and webmail in a browser tab
//   Agents     ChatGPT, Claude, Cursor, and the terminal an agent is reading
//
// plus Auto cleanup, which isn't a place but a strength: how hard the polish
// pass scrubs, everywhere. None skips the polish pass altogether (it is the
// same switch as Settings › Models › Polish); Light keeps your phrasing and
// only takes the "um"s; Moderate also drops false starts and lays out lists.
//
// A tone is a rule clause appended to the polish prompt (plus, where prose
// isn't enough, a worked example of its own), never code that rewrites text
// itself. That is the whole safety story: a tone can steer punctuation, casing
// and layout, and it rides under the same guardrails as everything else in
// Refine.swift — the model still may not add words, answer the dictation, or
// change what you said. Pick the loudest tone in the app and the worst it can
// do is tidy harder.
//
// HOW A TONE GETS ITS WAY (measured against gpt-oss-120b at low reasoning
// effort — the polish model — 2026-08-20, and the reason this file is shaped
// the way it is): the prompt's bullet list is the only thing the model really
// obeys. A tone rule stated BELOW the list, in the destination block, reads as
// description and loses; the same rule stated AS a bullet lands. "No closing
// period on a short line" and "write contractions out" both failed as prose
// and both worked as bullets — so ToneOption.bullets is where the work
// happens, and `rules` only carries voice-level guidance underneath.
//
// What still doesn't work at this tier: RESTRUCTURING PROSE. An Agents tone
// asking for a chained request ("…and then fix it and also add a test") to
// come out as a numbered list was ignored in four builds — stated as an
// override, with the conflicting base bullet deleted, and with one and then
// two worked examples of its own. It was dropped rather than shipped as a
// switch that quietly does nothing. Before adding a tone that reshapes rather
// than repunctuates, prove it against the live model first.

import Foundation

// MARK: - The hint that reaches the model

/// What AppStyle hands Refine: where the paste is going, and how the user
/// asked that place to read. Kept in two pieces on purpose — the destination
/// is context, the rules are an instruction, and folding them into one
/// sentence made the model read the rules as more description (measured
/// against the live model 2026-08-20: a tone asking for a numbered list was
/// ignored until the two were framed apart).
struct ToneHint {
    /// "Slack, a work message" — the app and the kind of place it is.
    let place: String
    /// The chosen tone's rule clause.
    let rules: String
    /// The bullets this tone contributes to the prompt's rule list, in place
    /// of its punctuation bullet (ToneOption.bullets).
    var bullets: [String] = []
    /// The tone's own worked examples, appended after the shared few-shots —
    /// a rule the tone's prose alone can't carry sometimes lands as an example.
    var shots: [(String, String)] = []
    /// A code editor: text for a file, which nothing may restyle — not a
    /// tone, and not the rules you wrote for prose (CustomRules.swift).
    var leaveAlone = false
    /// The same pick as SayControl's cloud rebuilds it (the Worker's
    /// prompts.ts): the context and tone, or code, with the app and the kind
    /// of place. The cloud writes its own prompt from these.
    var wire: [String: Any] = [:]
}

// MARK: - Contexts

/// Where the words are headed, in the four groups a person actually thinks in.
/// Code editors are deliberately NOT here: an editor is left strictly alone,
/// which is not a tone anyone should be able to turn off (see AppStyle).
enum ToneContext: String, CaseIterable {
    case personal, work, email, agents

    var title: String {
        switch self {
        case .personal: return "Personal"
        case .work:     return "Work"
        case .email:    return "Email"
        case .agents:   return "Agents"
        }
    }

    var envKey: String { "TONE_\(rawValue.uppercased())" }

    /// The line under the card title — what this context covers.
    var blurb: String {
        switch self {
        case .personal:
            return "Messages to people you know, and the notes you keep for yourself."
        case .work:
            return "Team chat, tickets and documents — anything a colleague will read."
        case .email:
            return "Mail clients and webmail, where a message has a greeting and a sign-off."
        case .agents:
            return "Prompts you dictate to an AI: chat apps, AI editors, and the terminal a coding agent is reading."
        }
    }

    /// Which apps land here. Shown in the pane so the automatic pick is legible
    /// rather than mysterious — you can see why Slack got the work tone.
    var appliesTo: String {
        switch self {
        case .personal:
            return "Messages · WhatsApp · Telegram · Signal · Discord · Messenger · Notes · Bear · Obsidian · Day One"
        case .work:
            return "Slack · Teams · Linear · Jira · Asana · Notion · Google Docs · Word · Pages · Confluence · long-form writing apps"
        case .email:
            return "Mail · Outlook · Spark · Superhuman · Mimestream · Missive · Gmail · Proton · Fastmail · Zoho"
        case .agents:
            return "ChatGPT · Claude · Gemini · Perplexity · Copilot · Cursor · Windsurf · Zed · Terminal · iTerm · Warp · Ghostty"
        }
    }

    /// The spoken line the pane's preview cleans, per tone. One sentence that
    /// belongs in this context and shows what the tones actually differ on.
    var sample: String {
        switch self {
        case .personal:
            return "hey so um I was thinking maybe we could grab dinner tomorrow around seven if that works for you"
        case .work:
            return "so the deploy is is blocked on the migration and um I don't think we can ship on Wednesday we should push the release to Thursday"
        case .email:
            return "hi Sarah um thanks for sending the deck over I had a look this morning and I think the numbers on slide four need another pass let me know when you're free"
        case .agents:
            return "okay so um I was wondering if you could take a look at the login flow and figure out why the session drops after an hour and then fix it and also add a test for it"
        }
    }

    var options: [ToneOption] {
        switch self {
        case .personal: return ToneOption.personal
        case .work:     return ToneOption.work
        case .email:    return ToneOption.email
        case .agents:   return ToneOption.agents
        }
    }

    /// The tone a fresh install writes in — the one most people would have
    /// picked: relaxed with friends, plain at work, proper in email, and
    /// nothing clever at all in a prompt.
    var defaultID: String {
        switch self {
        case .personal: return "casual"
        case .work:     return "balanced"
        case .email:    return "professional"
        case .agents:   return "verbatim"
        }
    }
}

// MARK: - A tone

/// One choice inside a context: what it's called, what it does, the rules the
/// model is handed, and the sample it turns the context's spoken line into.
struct ToneOption {
    let id: String
    let title: String
    let detail: String
    /// Appended to the polish prompt after the app name and kind:
    /// "Slack, a work message: <rules>". Rules only — never a name for the
    /// place, or the line says it twice, and the same tone has to read right
    /// in a chat window, a note and a document.
    let rules: String
    /// What the context's spoken sample types as, under this tone. Written by
    /// hand and held to the same rules the model is: nothing added, nothing
    /// reordered, no word swapped for a fancier one.
    let sample: String
    /// What this tone puts in the prompt's rule list, in place of the default
    /// punctuation bullet. Empty leaves that bullet alone.
    ///
    /// THIS is where a tone actually gets its way. A rule stated below the
    /// list, in the destination block, is read as description and loses to the
    /// list every time; the same rule stated AS a bullet lands (measured
    /// 2026-08-20 — "no closing period" and "write contractions out" both
    /// failed as prose and both worked as bullets).
    var bullets: [String] = []
    /// Examples that ride along in the request, for a tone the prose alone
    /// can't carry. Each is held to the same rules as the samples — and to
    /// `plausible`, so a question mark in the input survives in the answer.
    var shots: [(String, String)] = []

    // MARK: The bullets tones are built from

    /// The prompt's own punctuation bullet — what a tone leaves in place when
    /// it has nothing to say about punctuation.
    static let defaultBullet = "Fix punctuation, casing and sentence breaks."

    /// Casual wants LESS punctuation than the default bullet gives, so it
    /// takes that bullet's place rather than arguing with it from below.
    private static let casualBullet =
        "Fix sentence breaks, spelling and obvious mistakes — but leave this one casual: light "
        + "punctuation, no period at the end of a single short line, and do not capitalize an "
        + "opening word the speaker said in lowercase."

    private static let thoroughBullet =
        "Be thorough with punctuation: every sentence closes with a full stop, and commas go "
        + "where written English wants them."

    /// The one word change any tone may make, spelled out so it can't grow.
    private static let contractionBullet =
        "Write contractions out in full (\"I'll\" → \"I will\", \"there's\" → \"there is\", "
        + "\"can't\" → \"cannot\"). That is the one word change allowed; every other word stays "
        + "exactly as spoken."

    private static let greetingBullet =
        "A spoken greeting (\"Hi Sarah,\") and a spoken sign-off (\"Thanks,\", \"Best,\") each go "
        + "on their own line, with a blank line between the greeting and the body."

    /// Phrased for a SHORT email on purpose: the level's own structure bullet
    /// ends with "a short dictation stays one paragraph", and a generic
    /// "new paragraph where the topic moves on" lost to it every time.
    private static let closingBullet =
        "A closing line — \"let me know when you are free\", \"talk soon\", \"thanks again\" — "
        + "goes in its own paragraph, with a blank line before it, however short the message is."

    private static let listLinesBullet = "Give each item of a spoken list its own line."

    /// An agent's window is full of paths, flags and identifiers, and a curly
    /// quote inside a command is a bug the user has to hunt for later. This is
    /// a punctuation rule, so it spends the punctuation bullet.
    static let asciiBullet =
        "Fix punctuation, casing and sentence breaks using plain ASCII punctuation ONLY — never a "
        + "curly quote, an en dash or an ellipsis character — and never restyle code, file paths, "
        + "commands, flags or identifiers."

    /// One worked example of writing contractions out, for the formal tones.
    private static let contractionShot = (
        "thanks for the update I'll take a look tomorrow and I'll let you know if there's anything we can't ship",
        "Thanks for the update. I will take a look tomorrow, and I will let you know if there is anything we cannot ship.")

    /// The hint for a code editor — the one destination with no tone to pick.
    /// It gets the ASCII bullet and nothing else: an editor is left alone.
    static func codeHint(_ appName: String) -> ToneHint {
        ToneHint(place: "\(appName), a code editor",
                 rules: "leave it alone — what was dictated is text for a file, not prose to tidy.",
                 bullets: [asciiBullet], leaveAlone: true,
                 wire: ["code": true, "app": appName])
    }

    // MARK: Personal

    static let personal: [ToneOption] = [
        ToneOption(
            id: "casual",
            title: "Casual",
            detail: "Talks the way you text. Light punctuation, contractions as spoken, and no full stop after a one-line message.",
            rules: "keep it casual — contractions exactly as spoken, and never add a greeting or a sign-off.",
            sample: "hey so I was thinking maybe we could grab dinner tomorrow around seven if that works for you",
            bullets: [casualBullet]),
        ToneOption(
            id: "balanced",
            title: "Balanced",
            detail: "Ordinary written sentences — capital letters and full stops, still relaxed.",
            rules: "relaxed but complete sentences — contractions as spoken, and no formal greeting or sign-off.",
            sample: "Hey, so I was thinking maybe we could grab dinner tomorrow around seven, if that works for you."),
        ToneOption(
            id: "polished",
            title: "Polished",
            detail: "Careful punctuation and sentence breaks, for the message you'd rather not look rushed.",
            rules: "careful written prose — nothing trailing off mid-thought; keep the warmth and the speaker's own words.",
            sample: "Hey, I was thinking maybe we could grab dinner tomorrow around seven if that works for you.",
            bullets: [defaultBullet, thoroughBullet]),
    ]

    // MARK: Work

    static let work: [ToneOption] = [
        ToneOption(
            id: "casual",
            title: "Casual",
            detail: "Standup voice. Short, plain, lowercase where you said it lowercase.",
            rules: "keep it brief and plain — contractions as spoken, and no greeting or sign-off.",
            sample: "so the deploy is blocked on the migration and I don't think we can ship on Wednesday; we should push the release to Thursday",
            bullets: [casualBullet]),
        ToneOption(
            id: "balanced",
            title: "Balanced",
            detail: "Complete sentences, straight to the point. A spoken list lands as a list.",
            rules: "complete sentences, and stay direct.",
            sample: "The deploy is blocked on the migration. I don't think we can ship on Wednesday — we should push the release to Thursday.",
            bullets: [defaultBullet, listLinesBullet]),
        ToneOption(
            id: "formal",
            title: "Formal",
            detail: "For the message that gets forwarded. Contractions written out, no slang, careful punctuation.",
            rules: "written for a wider audience — no slang and no abbreviations.",
            sample: "So the deploy is blocked on the migration, and I do not think we can ship on Wednesday. We should push the release to Thursday.",
            bullets: [defaultBullet, thoroughBullet, contractionBullet],
            shots: [contractionShot]),
    ]

    // MARK: Email

    static let email: [ToneOption] = [
        ToneOption(
            id: "friendly",
            title: "Friendly",
            detail: "Warm and direct, for someone you already know. Greeting on its own line, punctuation kept light.",
            rules: "warm and direct, for someone you already know — contractions exactly as spoken.",
            sample: "Hi Sarah,\n\nThanks for sending the deck over. I had a look this morning and I think the numbers on slide four need another pass. Let me know when you're free.",
            bullets: [defaultBullet, greetingBullet]),
        ToneOption(
            id: "professional",
            title: "Professional",
            detail: "The everyday work email: proper prose, greeting and sign-off on their own lines, a paragraph per topic.",
            rules: "full sentences, businesslike and clear; contractions as spoken.",
            sample: "Hi Sarah,\n\nThanks for sending the deck over. I had a look this morning and I think the numbers on slide four need another pass.\n\nLet me know when you're free.",
            bullets: [defaultBullet, greetingBullet, thoroughBullet, closingBullet]),
        ToneOption(
            id: "formal",
            title: "Formal",
            detail: "Nothing contracted, nothing casual — for people you haven't met.",
            rules: "no slang and no abbreviations.",
            sample: "Hi Sarah,\n\nThanks for sending the deck over. I had a look this morning and I think the numbers on slide four need another pass. Let me know when you are free.",
            bullets: [defaultBullet, greetingBullet, contractionBullet],
            shots: [contractionShot]),
    ]

    // MARK: Agents

    static let agents: [ToneOption] = [
        ToneOption(
            id: "verbatim",
            title: "As spoken",
            detail: "Every word you said, cleaned up — the request reads the way you asked it.",
            rules: "clean it and stop there — keep every instruction, every detail and the speaker's order.",
            sample: "Okay, so I was wondering if you could take a look at the login flow and figure out why the session drops after an hour, and then fix it and also add a test for it.",
            bullets: [asciiBullet]),
        ToneOption(
            id: "terse",
            title: "Terse",
            detail: "The same words, minus the polite opening — “okay so”, “I was wondering if you could”.",
            rules: "strip it to the instruction itself. The polite scaffolding around a request goes — "
                + "\"okay so\", \"I was wondering if\", \"can you\", \"could you\", \"please\", "
                + "\"when you get a chance\" — leaving the verb the speaker actually asked for. Every "
                + "fact, name, path, number and condition stays.",
            sample: "Take a look at the login flow and figure out why the session drops after an hour, and then fix it and also add a test for it.",
            bullets: [asciiBullet],
            shots: [("Okay so I was wondering if you could maybe take a look at the build failure on main when you get a chance.",
                     "Take a look at the build failure on main.")]),
    ]
}

// MARK: - Auto cleanup

/// How hard the polish pass scrubs — the one setting that applies everywhere,
/// tone or no tone. It rewrites the shared part of the polish prompt (the
/// bullet list in Refine.swift), so it is about WHAT gets removed, while a
/// tone is about how what's left is punctuated.
///
/// The pane offers "None" in front of these, and None is not a level: it is
/// the polish pass switched off (Config.refine), so there is one switch for
/// it, not two that can disagree. Aggressive was dropped on 2026-09-27 —
/// cutting hedges and tightening rambles is a rewrite nobody asked the
/// cleanup for; an install that had picked it reads as Moderate.
enum CleanupLevel: String, CaseIterable {
    case light, moderate

    static let envKey = "CLEANUP_LEVEL"
    static let fallback = CleanupLevel.light

    /// A stored value, including the retired "aggressive".
    init?(stored raw: String) {
        if raw == "aggressive" { self = .moderate; return }
        self.init(rawValue: raw)
    }

    var title: String {
        switch self {
        case .light:    return "Light"
        case .moderate: return "Moderate"
        }
    }

    var detail: String {
        switch self {
        case .light:
            return "The default. “Um”, “uh” and stutters, nothing more. Your phrasing survives exactly as you said it — false starts and all."
        case .moderate:
            return "Light, plus false starts, self-corrections and repeated words; a spoken list becomes a numbered list."
        }
    }

    /// What this level takes OUT — the first bullets of the polish prompt,
    /// above the punctuation rules every level shares.
    var removalRules: [String] {
        switch self {
        case .light:
            return [
                "Remove filler words (\"um\", \"uh\", \"er\") and immediate stutters (\"the the\", \"is is\").",
                "Leave everything else exactly as spoken. Keep false starts, self-corrections, repeated phrasing, hedges (\"probably\", \"kind of\", \"a little bit\") and discourse markers (\"so\", \"I mean\", \"you know\", \"like\", \"basically\", \"actually\") exactly where the speaker put them. This is the lightest possible cleanup — when in doubt, keep the word, unless one of the speaker's own rules asks for it to be written another way.",
            ]
        case .moderate:
            return [
                "Remove false starts and self-corrections, keeping the version the speaker settled on.",
                "Remove immediate repetitions and leftover filler words.",
            ]
        }
    }

    /// A spoken enumeration laid out as a numbered list. This one DOES edit
    /// words — "first of all, we need to ask Claude" loses its opening three
    /// to the "1. " — so Light, which promises the phrasing survives, never
    /// gets it.
    private static let listRule =
        "When the speaker enumerates two or more items — \"first of all… second of all… thirdly…\", \"number one… number two…\", \"one… two… three…\" — lay them out as a numbered list: any intro sentence on its own line, then each item on its own line as \"1. \", \"2. \", …, then any closing words on their own line. Never invent list structure that wasn't spoken."

    private static let noListRule =
        "Do not lay anything out as a list: a spoken enumeration stays the sentences the speaker said."

    /// Paragraphs, at EVERY level — Light included. Light's promise is about
    /// WORDS ("your phrasing survives exactly as you said it"), and a blank
    /// line spends none of them. Hanging the layout off the scrub strength
    /// instead meant asking for a gentler scrub silently cost you the layout:
    /// a 185-second dictation pasted as 2059 characters with no line break in
    /// it (measured 2026-08-21), which is the wall of text this rule exists
    /// to prevent.
    ///
    /// The cadence is spelled out because "a longer dictation" alone did not
    /// carry: over hundreds of words the model needs to be told that several
    /// breaks are expected, not one.
    private static let paragraphRule =
        "Lay a long dictation out in paragraphs of about two to five sentences each. Start a new paragraph where the speaker moves to a new topic or a new part of the story — often on \"anyway\", \"and another thing\", \"one more thing\", or simply a new subject — with a blank line between the two sentences. A run of requests about the same thing (the same page, feature or task) stays one paragraph, even when every sentence asks for something new or opens with \"and\", \"also\" or \"so\". Never give each sentence its own paragraph: a one-sentence paragraph is only for a line that stands apart from everything around it, like a closing question. Do not let a paragraph run past about five sentences: break it at the nearest topic shift instead. A dictation of several hundred words is several paragraphs, never one block; two or three sentences stay one paragraph. Inserting the blank lines is the ONLY change this rule allows — never reorder, reword, merge or drop a sentence to make the paragraphs come out tidier."

    /// What this level is allowed to REARRANGE. Sits below the punctuation
    /// rules, where the shared prompt used to spell them out.
    var structureRules: [String] {
        [self == .light ? Self.noListRule : Self.listRule, Self.paragraphRule]
    }

    /// Extra worked examples for this level, added to the shared few-shots.
    /// The level's whole personality is in these — a prompt bullet says what
    /// to do, an example shows how far to take it.
    var fewShots: [(String, String)] {
        switch self {
        case .light:
            return [
                ("So, um, I was thinking, you know, maybe we could, we could ship it on Friday.",
                 "So, I was thinking, you know, maybe we could ship it on Friday."),
            ]
        case .moderate:
            return []
        }
    }

    /// The spoken line the pane's preview cleans at each level.
    static let sample = "so I think we should, we should probably just um ship the thing on Friday you know and then like see what happens"

    var sampleOutput: String {
        switch self {
        case .light:
            return "So I think we should, we should probably just ship the thing on Friday, you know, and then like see what happens."
        case .moderate:
            return "So I think we should probably just ship the thing on Friday, you know, and then see what happens."
        }
    }

    /// How far a rewrite is allowed to shrink before Refine calls it a
    /// hallucination rather than a cleanup: below it, the raw words paste.
    var shrinkFloor: Double {
        switch self {
        case .light:    return 0.5
        case .moderate: return 0.3
        }
    }
}

// MARK: - Which tone is picked

/// Reads and writes the picks in ~/.config/sayctrl/.env. Nothing is written
/// until you choose, so a default that changes in a later version still
/// reaches installs that never touched the pane.
enum Tones {

    static func selectedID(for context: ToneContext) -> String {
        guard let raw = Config.shared.env()[context.envKey],
              context.options.contains(where: { $0.id == raw }) else { return context.defaultID }
        return raw
    }

    static func option(for context: ToneContext) -> ToneOption {
        let id = selectedID(for: context)
        return context.options.first { $0.id == id } ?? context.options[0]
    }

    static func select(_ id: String, for context: ToneContext) {
        Config.shared.set(context.envKey, id == context.defaultID ? nil : id)
        Config.shared.log("Tone: \(context.rawValue) → \(id)")
    }

    static var cleanupLevel: CleanupLevel {
        get {
            let raw = Config.shared.env()[CleanupLevel.envKey]?.lowercased() ?? ""
            return CleanupLevel(stored: raw) ?? .fallback
        }
        set {
            Config.shared.set(CleanupLevel.envKey,
                              newValue == .fallback ? nil : newValue.rawValue)
            Config.shared.log("Auto cleanup: \(newValue.rawValue)")
        }
    }
}
