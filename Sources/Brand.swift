// The app's own name, spelled the app's way no matter how it was heard.
//
// "SayControl" is a coined word, so no recognizer writes it closed up: every
// model hands back what it sounds like instead — "Say control", "Say
// Control.", "say ctrl". The name is the one word every user is bound to say sooner or
// later (telling someone about the app, writing about it, naming a folder), so
// asking each of them to teach the app its own name in the Dictionary would be
// absurd. This fix ships with the app: it is not a replacement rule, nothing is
// written to rules.json and nothing shows up in the Dictionary pane, so a fresh
// Mac gets the name right on its very first dictation.
import Foundation

enum Brand {

    static let name = "SayControl"

    /// What makes "control" the key on the keyboard or an ordinary English noun
    /// rather than half of our name: "I'd say control C is faster", "I'd say
    /// control flow is the problem". Those sentences are left exactly as they
    /// were spoken. The single letters are the key combos (control C, control V);
    /// "a" and "i" are left out of that range because they are words in their
    /// own right, and "SayControl a" reads better than "say control a".
    private static let notTheName =
        "[b-hj-z]|alt|shift|option|command|cmd|key|keys|click|tab|enter|return"
        + "|escape|esc|space|arrow|delete|backspace"
        + "|flow|panel|group|groups|character|characters|room|freak|tower"
        + "|center|centre|theory|structure|structures|plane|unit|units|system|systems"

    /// "Say control", "Say Control.", "SayControl", "say-ctrl" — any casing, and
    /// with or without the full stop after it. The match covers the words only,
    /// so whatever punctuation stood next to them stays where it was:
    /// "Say control." comes out "SayControl.".
    ///
    /// The lookarounds are the usual whole-word guards: "hearsay control" and
    /// "say controls the budget" are not the name and never match.
    private static let heard: NSRegularExpression? = try? NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}_])say[\\s\\-]*(?:control|ctrl)(?![\\p{L}\\p{N}_])"
            + "(?!\\s+(?:" + notTheName + ")(?![\\p{L}\\p{N}_]))",
        options: [.caseInsensitive])

    /// Runs ahead of the user's dictionary on every transcript — see
    /// ReplacementStore.apply.
    static func fixName(in text: String) -> String {
        guard !text.isEmpty, let re = heard else { return text }
        return re.stringByReplacingMatches(
            in: text, options: [],
            range: NSRange(text.startIndex..., in: text),
            withTemplate: NSRegularExpression.escapedTemplate(for: name))
    }
}
