// The auto-learn safety gate: "is this a word you might actually want to type?"
//
// Recognizers almost always mishear names *as* real words — "idea" comes out
// "area", "Claude" comes out "cloud". Fixing one of those must not create a
// blanket replacement rule, or the real word is eaten from every transcript
// after that ("area" → "idea" forever). So real words never become rules; they
// become hint-only entries instead (see ReplacementStore.noteHint).
//
// Uses the system spell checker: offline, already knows the user's languages,
// and independent of whichever voice model is selected.
import Cocoa

enum Lexicon {

    /// The user's preferred languages, narrowed to ones the spell checker knows.
    /// Locale hands out BCP-47 tags ("en-US") but the checker speaks "en_US"/"en",
    /// so try both spellings and fall back to English.
    private static let languages: [String] = {
        let available = Set(NSSpellChecker.shared.availableLanguages)
        var out: [String] = []
        for pref in Locale.preferredLanguages {
            let underscored = pref.replacingOccurrences(of: "-", with: "_")
            let base = String(pref.prefix(while: { $0 != "-" }))
            for cand in [underscored, base] where available.contains(cand) && !out.contains(cand) {
                out.append(cand)
            }
        }
        if out.isEmpty { out.append("en") }
        return out
    }()

    /// True when `word` is correctly spelled in one of the user's languages —
    /// something they might genuinely dictate, not recognizer gibberish.
    /// Main thread only (NSSpellChecker is AppKit).
    static func isRealWord(_ word: String) -> Bool {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return false }
        let checker = NSSpellChecker.shared
        if checker.hasLearnedWord(w) { return true }
        for lang in languages {
            let miss = checker.checkSpelling(of: w, startingAt: 0, language: lang,
                                             wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
            if miss.location == NSNotFound { return true }
        }
        return false
    }
}
