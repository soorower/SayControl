// Phrases: "say this short thing -> type that long thing."
//
// The sibling of the replacement dictionary, and deliberately not the same
// feature. A Dictionary rule fixes a word the recognizer got WRONG — it is a
// repair, one word wide, and you never notice it working. A Phrase is a
// shortcut you invented: the words you say are correct, you simply do not want
// to say the whole thing. "my email address" is heard perfectly; it just types
// jane@example.com instead.
//
// That difference is why expansion happens where it does. A dictionary swap is
// prose and the AI polish is welcome to reflow it; a phrase is EXACT text you
// chose — an address, a wallet, a signature block — so it lands after the
// model has had its say and nothing runs behind it (see deliverDictation).
import Foundation

struct Phrase: Codable, Equatable {
    var id: String
    /// What you say. Matched whole, ignoring case, tolerant of the stray commas
    /// speech cleanup leaves behind ("my, email address").
    var trigger: String
    /// What gets typed — verbatim, newlines and all. Never re-capitalised: an
    /// address at the start of a sentence is still lowercase.
    var expansion: String
    /// Off keeps the row (and its recognizer hint) without expanding it.
    var enabled: Bool
    var hits: Int
    var created: Date

    init(trigger: String, expansion: String, enabled: Bool = true) {
        self.id = UUID().uuidString
        self.trigger = trigger
        self.expansion = expansion
        self.enabled = enabled
        self.hits = 0
        self.created = Date()
    }

    // Hand-written so an older/partial file still loads instead of throwing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        trigger = (try? c.decode(String.self, forKey: .trigger)) ?? ""
        expansion = (try? c.decode(String.self, forKey: .expansion)) ?? ""
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        hits = (try? c.decode(Int.self, forKey: .hits)) ?? 0
        created = (try? c.decode(Date.self, forKey: .created)) ?? Date()
    }
}

private struct PhrasesFile: Codable {
    var version: Int
    var phrases: [Phrase]
}

final class PhraseStore {
    static let shared = PhraseStore()

    private(set) var phrases: [Phrase] = []

    private init() { load() }

    // MARK: - Persistence

    private var lastLoadedModified: Date?

    func load() {
        // No file is no phrases: another account's folder may have none yet.
        guard let data = try? Data(contentsOf: Config.shared.phrasesURL) else {
            phrases = []
            lastLoadedModified = nil
            Self.matchers.removeAll()
            return
        }
        if let file = try? JSONDecoder().decode(PhrasesFile.self, from: data) {
            phrases = file.phrases
        } else if let bare = try? JSONDecoder().decode([Phrase].self, from: data) {
            phrases = bare
        }
        lastLoadedModified = fileModified()
        Self.matchers.removeAll()
    }

    private func fileModified() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: Config.shared.phrasesURL.path)[.modificationDate]) as? Date
    }

    /// Saving writes the whole array, so a copy that went stale — a second instance,
    /// or the file edited by hand — would silently wipe newer phrases. Re-read first.
    private func syncFromDisk() {
        guard let onDisk = fileModified() else { return }
        if lastLoadedModified == nil || onDisk > lastLoadedModified! { load() }
    }

    func save(notify: Bool = true) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(PhrasesFile(version: 1, phrases: phrases)) {
            try? data.write(to: Config.shared.phrasesURL, options: .atomic)
            lastLoadedModified = fileModified()
        }
        if notify { NotificationCenter.default.post(name: .owPhrasesChanged, object: nil) }
    }

    // MARK: - Editing

    /// Adds a phrase, or retargets the existing one with the same trigger.
    /// Returns true when something actually changed.
    @discardableResult
    func upsert(trigger: String, expansion: String) -> Bool {
        syncFromDisk()
        let t = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only the ends are trimmed — the inside of an expansion is the user's
        // layout (a signature's blank line between sign-off and name).
        let e = expansion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !e.isEmpty, t.caseInsensitiveCompare(e) != .orderedSame else { return false }

        if let i = phrases.firstIndex(where: { $0.trigger.caseInsensitiveCompare(t) == .orderedSame }) {
            guard phrases[i].expansion != e else { return false }
            phrases[i].expansion = e
            save()
            return true
        }
        phrases.insert(Phrase(trigger: t, expansion: e), at: 0)
        save()
        return true
    }

    func setTrigger(_ id: String, to trigger: String) {
        syncFromDisk()
        let t = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let i = phrases.firstIndex(where: { $0.id == id }),
              phrases[i].trigger != t else { return }
        // A rename onto another row's trigger would leave two rules fighting over
        // the same words; the older row loses, exactly as upsert would decide it.
        phrases.removeAll { $0.id != id && $0.trigger.caseInsensitiveCompare(t) == .orderedSame }
        guard let j = phrases.firstIndex(where: { $0.id == id }) else { return }
        phrases[j].trigger = t
        save()
    }

    func setExpansion(_ id: String, to expansion: String) {
        syncFromDisk()
        let e = expansion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !e.isEmpty, let i = phrases.firstIndex(where: { $0.id == id }),
              phrases[i].expansion != e else { return }
        phrases[i].expansion = e
        save()
    }

    func setEnabled(_ id: String, _ on: Bool) {
        syncFromDisk()
        guard let i = phrases.firstIndex(where: { $0.id == id }), phrases[i].enabled != on else { return }
        phrases[i].enabled = on
        save()
    }

    func remove(_ id: String) {
        syncFromDisk()
        guard phrases.contains(where: { $0.id == id }) else { return }
        phrases.removeAll { $0.id == id }
        save()
    }

    func remove(ids: Set<String>) {
        syncFromDisk()
        guard phrases.contains(where: { ids.contains($0.id) }) else { return }
        phrases.removeAll { ids.contains($0.id) }
        save()
    }

    func phrase(id: String) -> Phrase? { phrases.first { $0.id == id } }

    // MARK: - Recognizer vocabulary

    /// Triggers ride along as keyterms. A phrase only fires if it was heard
    /// exactly, so a trigger the recognizer fumbles is a trigger that silently
    /// never works — the same argument that puts commands at the head of the
    /// hint list in LiveTranscribe.
    var spokenTriggers: [String] {
        syncFromDisk()
        return phrases.filter { $0.enabled }.map { $0.trigger }
    }

    // MARK: - Expanding

    /// Swap every trigger for its expansion. Longest trigger first, so "my work
    /// email" beats "my email" instead of racing it.
    ///
    /// Returns the rewritten text and the triggers that fired, for the log.
    func expand(in text: String) -> (text: String, fired: [String]) {
        syncFromDisk()
        guard !phrases.isEmpty, !text.isEmpty else { return (text, []) }
        var out = text
        var fired: [String] = []

        for (index, phrase) in phrases.enumerated()
            .sorted(by: { $0.element.trigger.count > $1.element.trigger.count }) {
            guard phrase.enabled, !phrase.trigger.isEmpty, !phrase.expansion.isEmpty else { continue }
            guard let re = Self.matcher(for: phrase.trigger) else { continue }

            let matches = re.matches(in: out, options: [], range: NSRange(out.startIndex..., in: out))
            guard !matches.isEmpty else { continue }

            let buffer = NSMutableString(string: out)
            for m in matches.reversed() {
                // Verbatim: the expansion is typed exactly as it was written, with
                // no case-fitting to the sentence around it. "My email address" at
                // the start of a sentence still types a lowercase address, because
                // capitalising one would produce a different address.
                buffer.replaceCharacters(in: m.range, with: phrase.expansion)
            }
            out = buffer as String
            phrases[index].hits += matches.count
            fired.append(contentsOf: Array(repeating: phrase.trigger, count: matches.count))
        }

        // Hit counters only — don't nudge the UI mid-edit.
        if !fired.isEmpty { save(notify: false) }
        return (out, fired)
    }

    /// True when this text would expand — used to decide whether a take carries a
    /// phrase at all, without paying for the rewrite.
    func matches(_ text: String) -> Bool {
        syncFromDisk()
        guard !text.isEmpty else { return false }
        let range = NSRange(text.startIndex..., in: text)
        return phrases.contains { p in
            guard p.enabled, !p.trigger.isEmpty, !p.expansion.isEmpty,
                  let re = Self.matcher(for: p.trigger) else { return false }
            return re.firstMatch(in: text, options: [], range: range) != nil
        }
    }

    /// One compiled matcher per trigger, kept because `expand` runs on every
    /// dictation and rebuilding a handful of regexes per take is pure waste.
    /// Safe to keep across edits: a pattern is a pure function of its trigger
    /// text, so an entry can go unused but never wrong. Cleared on load only to
    /// stop a session of heavy editing from hoarding dead ones.
    private static var matchers: [String: NSRegularExpression] = [:]

    private static func matcher(for trigger: String) -> NSRegularExpression? {
        if let cached = matchers[trigger] { return cached }
        // Words joined loosely, because the text this runs against has already
        // been through speech cleanup: "my email address" arrives as "my, email
        // address" often enough that an exact-space match would just miss.
        // Lookarounds rather than \b so a trigger ending in punctuation still works.
        let words = trigger.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" })
        guard !words.isEmpty else { return nil }
        let body = words.map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: "[\\s,]+")
        let pattern = "(?<![\\p{L}\\p{N}_])" + body + "(?![\\p{L}\\p{N}_])"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        matchers[trigger] = re
        return re
    }

}
