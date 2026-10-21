// What was already written where the dictation is going: the last few
// sentences before the caret, read when recording starts. A recognizer told
// what came before hears the next sentence in its light — the name already
// spelled two lines up, the thread's topic. It is also saved with the take
// (HistoryEntry.context), so a context idea can be measured on real
// dictations later instead of guessed at.
//
// The focused field is read through Accessibility, the same grant the paste
// uses. Many fields answer nothing (terminals, some web views, secure
// fields); then there is no earlier text, only the names and screen words.
//
// Measured on 95 bench takes (2026-10-02): the takes said just before as
// context took Qwen3 from 8.6% to 7.3% errors, at ~0.1 s more decode. A
// fallback to the user's own recent dictations (same app, last ten minutes)
// was tried and removed the same day: history keeps the raw text, mistakes
// included, after the user has fixed them in the field — the field shows
// the fix, history never does.
import Cocoa
import ApplicationServices

/// The context a take was transcribed with, saved beside it.
struct TakeContext: Codable {
    /// The names list the local / own-GPU Qwen3 was given.
    var terms: [String]
    /// The unusual words the screen scan found.
    var screen: [String]
    /// The text before the caret, most recent last.
    var before: String
    /// "field" when read from the focused element, "" when it gave nothing.
    var beforeSource: String
    /// Bundle id of the app the take went to.
    var app: String?
}

enum TypingContext {
    /// At most this much text, cut at a sentence start: about 5–10 sentences.
    static let maxChars = 700

    private static var captured = ""
    private static var source = ""
    private static var frontApp: String?

    /// Called when recording starts. Cheap: one range and one bounded string,
    /// never the whole document.
    static func capture() {
        captured = ""; source = ""
        frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let text = fromField(), !text.isEmpty {
            captured = trim(text); source = "field"
        }
    }

    static var before: String { captured }
    static var beforeSource: String { source }
    static var app: String? { frontApp }

    /// The text left of the caret in the focused element, asked for by range.
    private static func fromField() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        for el in CorrectionWatcher.candidateRoots().prefix(2) {
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &v) == .success,
                  let av = v, CFGetTypeID(av) == AXValueGetTypeID() else { continue }
            var range = CFRange()
            guard AXValueGetValue(unsafeBitCast(av, to: AXValue.self), .cfRange, &range) else { continue }
            if range.location <= 0 { return "" }
            let want = min(range.location, maxChars * 2)
            var ask = CFRange(location: range.location - want, length: want)
            var param: CFTypeRef?
            if let axAsk = AXValueCreate(.cfRange, &ask),
               AXUIElementCopyParameterizedAttributeValue(
                   el, kAXStringForRangeParameterizedAttribute as CFString, axAsk, &param) == .success,
               let s = param as? String {
                return s
            }
            if let s = CorrectionWatcher.stringValue(of: el), s.utf16.count < 400_000 {
                let ns = s as NSString
                guard range.location <= ns.length else { continue }
                let from = max(0, range.location - want)
                return ns.substring(with: NSRange(location: from, length: range.location - from))
            }
        }
        return nil
    }

    /// The tail of `text`, no longer than maxChars, starting at a sentence.
    static func trim(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        guard flat.count > maxChars else { return flat }
        let tail = String(flat.suffix(maxChars))
        if let cut = tail.range(of: #"[.!?]\s+"#, options: .regularExpression) {
            return String(tail[cut.upperBound...])
        }
        return tail
    }
}
