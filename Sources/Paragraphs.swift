// Fallback paragraph layout: the deterministic net under the AI polish.
//
// Paragraphs normally come from the polish pass (CleanupLevel.paragraphRule).
// When that pass cannot serve the paste — deadline hit, request failed or
// rejected, polish switched off — the raw transcript used to land as one
// unbroken block: a 126-second, 1395-char take pasted as a wall of text
// (2026-09-01), and a week of polish-off dictations did the same. The words
// in a blob are all there, but nobody reads them.
//
// This is NOT a rewrite. It inserts blank lines between sentences and
// changes nothing else — the same promise paragraphRule extracts from the
// model, enforced here by construction, so it is safe to run on words the
// user never agreed to have reworded. Two signals place the breaks:
//
//   1. A discourse marker opening a sentence — "So", "Anyway", "Also",
//      "Like", "But", "Basically"… — once the paragraph has a few sentences
//      behind it. Spoken topic shifts genuinely start this way (the
//      paragraphRule teaches the model the same openers), but early in a
//      paragraph the same words are just how the next thought connects, so
//      a marker can only break a paragraph that has already grown.
//   2. A cap, so a stretch with no markers still breathes: past six
//      sentences, or past a screen-line-heavy run of characters, the next
//      sentence starts a paragraph regardless.
//
// The result is paragraphs of roughly three to six sentences — not the
// model's judgement, but never a wall, and never a sentence on its own: a
// lone sentence left at the end joins the paragraph before it, so "So…" and
// "Because…" closing a dictation stay with what they close (2026-10-12).

import Foundation

enum Paragraphs {

    /// A marker may only break a paragraph this many sentences in — any
    /// earlier and "So we could…" as the second sentence would shear off a
    /// paragraph of one.
    private static let markerMin = 3
    /// No paragraph runs past this many sentences, marker or no marker.
    private static let cap = 6
    /// Dictated sentences run long; two of them past this many characters
    /// are already a paragraph's worth of reading, so the next sentence
    /// starts fresh even without a marker.
    private static let softChars = 550
    /// Below this many sentences the text is one short block and reads fine
    /// as it is — inserting a break would be layout for layout's sake.
    private static let minTotal = 5

    /// Sentence openers that mark a topic shift when spoken. Kept tight: a
    /// generous list turns every connective into a break and the paragraphs
    /// come out choppy ("And"/"Because" are continuations, not shifts).
    private static let markerWords: Set<String> = [
        "so", "anyway", "also", "then", "basically", "like", "but", "now",
        "okay", "alright", "next", "plus", "finally", "lastly",
        "first", "second", "third", "secondly", "thirdly",
    ]
    private static let markerPhrases = [
        "one more thing", "another thing", "and another thing", "by the way",
        "moving on", "other than that", "apart from that", "on the other hand",
    ]

    /// Sentence boundary: end punctuation (closing quote allowed), whitespace,
    /// then a capital, digit or opening quote. Requiring the whitespace keeps
    /// "2.5 seconds" whole; requiring the capital keeps "e.g. lowercase" whole.
    private static let boundary = try! NSRegularExpression(
        pattern: "[.!?]+[”\"')\\]]*\\s+(?=[A-Z0-9“\"'(])")

    /// Titles and shorthands whose trailing period ends no sentence.
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "st", "vs", "etc", "eg", "ie", "no",
    ]

    /// Lay a long, line-less transcript out in paragraphs. Text that already
    /// has any layout — a polished result, an expansion with its own lines —
    /// passes through untouched, and so does anything short.
    static func layout(_ text: String) -> String {
        guard !text.contains("\n") else { return text }
        let sentences = split(text)
        guard sentences.count >= minTotal else { return text }

        var paragraphs: [[String]] = []
        var current: [String] = []
        var chars = 0
        for sentence in sentences {
            let markerBreak = current.count >= markerMin && opensWithMarker(sentence)
            let capBreak = current.count >= cap
            let sizeBreak = current.count >= 2 && chars >= softChars
            if markerBreak || capBreak || sizeBreak {
                paragraphs.append(current)
                current = []
                chars = 0
            }
            current.append(sentence)
            chars += sentence.count
        }
        if !current.isEmpty { paragraphs.append(current) }
        // Every break above needs two sentences behind it, so only the last
        // paragraph can be a single sentence.
        if paragraphs.count > 1, paragraphs[paragraphs.count - 1].count == 1 {
            let last = paragraphs.removeLast()
            paragraphs[paragraphs.count - 1] += last
        }
        guard paragraphs.count > 1 else { return text }
        return paragraphs.map { $0.joined(separator: " ") }.joined(separator: "\n\n")
    }

    /// The text as whole sentences, punctuation kept, whitespace trimmed.
    private static func split(_ text: String) -> [String] {
        let ns = text as NSString
        var sentences: [String] = []
        var start = 0
        for match in boundary.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let end = match.range.location + match.range.length
            let candidate = ns.substring(with: NSRange(location: start, length: end - start))
            if endsInAbbreviation(candidate) { continue }   // not a boundary — keep growing
            sentences.append(candidate.trimmingCharacters(in: .whitespaces))
            start = end
        }
        if start < ns.length {
            sentences.append(ns.substring(from: start).trimmingCharacters(in: .whitespaces))
        }
        return sentences.filter { !$0.isEmpty }
    }

    private static func endsInAbbreviation(_ sentence: String) -> Bool {
        let trimmed = sentence.trimmingCharacters(in: .whitespaces)
        // Strip the end punctuation and read the word in front of it.
        let word = trimmed.reversed().drop { "”\"')].!?".contains($0) }
            .prefix { !$0.isWhitespace && $0 != "." }
        return abbreviations.contains(String(word.reversed()).lowercased())
    }

    private static func opensWithMarker(_ sentence: String) -> Bool {
        let lower = sentence.lowercased()
        for phrase in markerPhrases where lower.hasPrefix(phrase) { return true }
        let first = lower.prefix { !$0.isWhitespace }
            .trimmingCharacters(in: CharacterSet(charactersIn: ",.:;!?"))
        return markerWords.contains(first)
    }
}
