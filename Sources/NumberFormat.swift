// Spoken numbers to written ones, for recognizers that write what was said
// word for word. Qwen3-ASR answers "two hundred sixty-five milliseconds"
// where a reader wants "265 ms", "zero point four three seconds" for
// "0.43 s", "Qwen three" for "Qwen3" — and on the bench that alone cost it
// about a point and a half of word error (2026-10-02: 6.7% → 5.3% on the
// script takes once numbers were written as digits).
//
// Deliberately conservative. NVIDIA's NeMo normalizer, tried first on the
// GPU, also turned "two hours" into "2 h", "first" into "1st" and "half
// past six" into "6:30"; this does none of that. A number is only rewritten
// when the result is the obvious way to write it:
//   • ten and up become digits ("thirteen" → 13, "two thousand" → 2000);
//   • zero to nine stay words in prose ("one of the", "two things") and turn
//     into digits only with a unit, a decimal, a range, money, a time or a
//     version ("Qwen three" → Qwen3, "V two" → V2);
//   • "half", "a couple", "a hundred", ordinals outside dates, untouched.
// Pure string work, no dependencies; well under a millisecond a dictation.
import Foundation

enum NumberFormat {

    static func apply(_ text: String) -> String {
        let toks = tokenize(text)
        guard toks.contains(where: { isNumberWord($0.core) || $0.core.contains("-") || ordinals[$0.core] != nil })
        else { return text }
        var out: [Tok] = []
        var i = 0
        while i < toks.count {
            if let (rendered, next) = postcode(at: i, in: toks) {
                out.append(contentsOf: rendered); i = next; continue
            }
            if let (rendered, next, glue) = number(at: i, in: toks, out: out) {
                if glue, let first = rendered.first, !out.isEmpty {
                    out[out.count - 1].word += first.word
                    out[out.count - 1].trail = first.trail
                    out.append(contentsOf: rendered.dropFirst())
                } else {
                    out.append(contentsOf: rendered)
                }
                i = next
            } else {
                out.append(toks[i]); i += 1
            }
        }
        let result = out.map { $0.lead + $0.word + $0.trail }.joined(separator: " ")
        // A dictation that is only a number — a phone number, a code — pastes
        // without the full stop the recognizer put after it.
        if result.range(of: #"^\+?[0-9][0-9 ,()\-]*[0-9]\.$"#, options: .regularExpression) != nil {
            return String(result.dropLast()).replacingOccurrences(of: ", ", with: " ")
        }
        return result
    }

    // MARK: - Tokens

    struct Tok {
        var lead = "", word = "", trail = ""
        /// Lowercased word, letters/digits/hyphens/apostrophes only.
        var core: String { word.lowercased() }
        var endsClause: Bool { trail.contains(where: { ".,!?;:".contains($0) }) }
    }

    private static func tokenize(_ text: String) -> [Tok] {
        text.split(separator: " ", omittingEmptySubsequences: true).map { piece in
            var s = Substring(piece), t = Tok()
            while let c = s.first, "\"'(“‘[".contains(c) { t.lead.append(c); s.removeFirst() }
            // "a.m." / "p.m." keep their dots: they are the word, not its punctuation.
            for ap in ["a.m.", "p.m."] where s.lowercased().hasPrefix(ap) {
                t.word = String(s.prefix(4)); t.trail = String(s.dropFirst(4)); return t
            }
            var trail = ""
            while let c = s.last, ".,!?;:\"')”’]".contains(c) {
                trail.insert(c, at: trail.startIndex); s.removeLast()
            }
            t.word = String(s); t.trail = trail
            return t
        }
    }

    // MARK: - Words

    private static let ones: [String: Int] = ["zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9]
    private static let teens: [String: Int] = ["ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19]
    private static let tens: [String: Int] = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
        "seventy": 70, "eighty": 80, "ninety": 90]
    private static let scales: [String: Int] = ["thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000]
    private static let ordinals: [String: Int] = ["first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12,
        "thirteenth": 13, "fourteenth": 14, "fifteenth": 15, "sixteenth": 16, "seventeenth": 17,
        "eighteenth": 18, "nineteenth": 19, "twentieth": 20, "thirtieth": 30]
    private static let months: Set<String> = ["january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december"]
    /// Written short after a number. Seconds only after a decimal ("0.43 s");
    /// "30 seconds" reads better in a sentence.
    private static let units: [String: String] = ["millisecond": "ms", "milliseconds": "ms",
        "percent": "%", "kilobytes": "KB", "megabytes": "MB", "gigabytes": "GB", "terabytes": "TB",
        "kilobyte": "KB", "megabyte": "MB", "gigabyte": "GB", "terabyte": "TB",
        "kilohertz": "kHz", "megahertz": "MHz", "gigahertz": "GHz", "kb": "KB", "mb": "MB", "gb": "GB", "tb": "TB"]
    /// Units that keep their word; a number before one is written in digits.
    private static let wordUnits: Set<String> = ["seconds", "second", "minutes", "minute", "hours", "hour",
        "milliseconds", "ms", "users", "words", "requests", "tokens", "times", "x"]
    /// Joined to a number with no space: "Qwen3".
    private static let gluedNames: Set<String> = ["qwen"]
    /// A number after one of these is a version, in digits wherever the word
    /// sits: "Gemini three is out" → "Gemini 3", "version two" → "version 2".
    /// Elsewhere a capitalised word only counts mid-sentence ("Call nine…").
    private static let versionWords: Set<String> = ["gemini", "claude", "grok", "gpt", "llama", "mistral", "nemotron",
        "parakeet", "whisper", "cohere", "soniox", "voxtral", "granite", "iphone", "ipad", "pixel", "galaxy",
        "windows", "macos", "ios", "android", "python", "swift", "java", "node", "version", "chapter", "phase",
        "step", "level", "season", "episode", "part", "round"]
    /// A number after one of these is an address part, written in digits
    /// even below ten, and a single letter after it joins it: "Flat 3B".
    private static let unitWords: Set<String> = ["flat", "apartment", "apt", "unit", "suite", "room", "floor",
        "building", "block", "house", "plot"]
    /// A number before "<Name> <one of these>" is a street number: "5 Park Road".
    private static let streetTypes: Set<String> = ["road", "street", "lane", "avenue", "drive", "close", "way",
        "court", "place", "crescent", "boulevard", "terrace", "rd", "st", "ave"]
    private static let postcodeWords: Set<String> = ["postcode", "zip", "zipcode", "postal"]

    private static func isNumberWord(_ w: String) -> Bool {
        ones[w] != nil || teens[w] != nil || tens[w] != nil || w == "hundred" || scales[w] != nil
    }

    /// "forty-five" → [forty, five]; nil when any part is not a number word.
    private static func parts(_ w: String) -> [String]? {
        let p = w.split(separator: "-").map(String.init)
        return p.count > 1 && p.allSatisfy(isNumberWord) ? p : (isNumberWord(w) ? [w] : nil)
    }

    // MARK: - Reading a number

    /// A cardinal from toks[i...]: (value, index after it, how many words,
    /// whether it ended on punctuation). Grammar enforced, so "twenty
    /// twenty" is two numbers, not forty.
    private static func cardinal(_ toks: [Tok], _ i: Int) -> (value: Int, next: Int, small: Bool, stop: Bool)? {
        var total = 0, current = 0, j = i, words: [String] = []
        enum Last { case none, one, teen, ten, hundred, scale }
        var last = Last.none
        var stop = false
        loop: while j < toks.count, !stop {
            guard toks[j].lead.isEmpty || j == i, let ps = parts(toks[j].core) else { break }
            // "and" inside "one hundred and five" is handled by the caller's peek.
            for w in ps {
                if let v = ones[w] {
                    guard last == .none || last == .ten || last == .hundred || last == .scale else { break loop }
                    if w == "zero", last != .none { break loop }
                    current += v; last = .one
                } else if let v = teens[w] {
                    guard last == .none || last == .hundred || last == .scale else { break loop }
                    current += v; last = .teen
                } else if let v = tens[w] {
                    guard last == .none || last == .hundred || last == .scale else { break loop }
                    current += v; last = .ten
                } else if w == "hundred" {
                    guard last == .one || last == .teen || last == .ten, current > 0, current < 100 else { break loop }
                    current *= 100; last = .hundred
                } else if let s = scales[w] {
                    guard last != .none, last != .scale, current > 0 else { break loop }
                    total += current * s; current = 0; last = .scale
                }
                words.append(w)
            }
            stop = toks[j].endsClause
            j += 1
            // "one hundred and five"
            if !stop, last == .hundred, j + 1 < toks.count, toks[j].core == "and",
               let ps = parts(toks[j + 1].core), ones[ps[0]] != nil || teens[ps[0]] != nil || tens[ps[0]] != nil {
                j += 1
            }
        }
        guard !words.isEmpty else { return nil }
        // "a hundred"/"hundred" alone is not a number we write.
        if words == ["hundred"] { return nil }
        let value = total + current
        return (value, j, value < 10 && words.count == 1, stop)
    }

    /// Single digits spoken one by one, three or more: a phone number, a code, "999".
    /// A comma between groups ("five five five, zero one seven three") is the
    /// pause in a phone number: the groups stay together, a space between.
    private static func digitRun(_ toks: [Tok], _ i: Int) -> (String, Int)? {
        var j = i, s = ""
        while j < toks.count, let v = ones[toks[j].core], toks[j].lead.isEmpty || j == i {
            s += String(v); j += 1
            if toks[j - 1].endsClause {
                guard toks[j - 1].trail == ",", j + 1 < toks.count, ones[toks[j].core] != nil,
                      ones[toks[j + 1].core] != nil else { break }
                s += " "
            }
        }
        return s.filter(\.isNumber).count >= 3 ? (s, j) : nil
    }

    // MARK: - Postcodes

    /// "postcode is KL Nine Four RT" → "postcode is KL9 4RT". Only when the
    /// letters and digits after the word make a real UK postcode, a US ZIP,
    /// or a 4–6 digit code; otherwise nothing changes.
    private static func postcode(at i: Int, in toks: [Tok]) -> ([Tok], Int)? {
        var k = i
        guard postcodeWords.contains(toks[k].core) || (toks[k].core == "post" && k + 1 < toks.count
                                                        && toks[k + 1].core == "code") else { return nil }
        var kept = [toks[k]]
        if toks[k].core == "post" || ((toks[k].core == "zip" || toks[k].core == "postal") && k + 1 < toks.count
                                      && toks[k + 1].core == "code") {
            k += 1; kept.append(toks[k])
        }
        guard !toks[k].endsClause || toks[k].trail.hasSuffix(":") || toks[k].trail.hasSuffix(",") else { return nil }
        k += 1
        if k < toks.count, toks[k].core == "is" { kept.append(toks[k]); k += 1 }
        var code = "", j = k
        while j < toks.count, j - k < 9 {
            let t = toks[j], w = t.word
            if let v = ones[t.core] { code += String(v) }
            else if w.count <= 3, w.allSatisfy({ $0.isLetter && $0.isUppercase }) { code += w }
            else if w.allSatisfy({ $0.isNumber || $0.isUppercase }), w.contains(where: { $0.isNumber }) { code += w }
            else { break }
            j += 1
            if t.endsClause { break }
        }
        guard j > k else { return nil }
        let formatted: String
        if code.range(of: #"^[A-Z]{1,2}[0-9][A-Z0-9]?[0-9][A-Z]{2}$"#, options: .regularExpression) != nil {
            formatted = code.dropLast(3) + " " + code.suffix(3)
        } else if code.range(of: #"^[0-9]{5}([0-9]{4})?$"#, options: .regularExpression) != nil {
            formatted = code.count == 9 ? code.prefix(5) + "-" + code.suffix(4) : code
        } else if code.range(of: #"^[0-9]{4,6}$"#, options: .regularExpression) != nil {
            formatted = code
        } else {
            return nil
        }
        return (kept + [Tok(lead: toks[k].lead, word: formatted, trail: toks[j - 1].trail)], j)
    }

    // MARK: - Writing it

    private static func grouped(_ v: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }

    /// Plain integer as written: digits, commas from 10,000 (years and
    /// "2000 words" stay unbroken).
    private static func digits(_ v: Int) -> String { v >= 10_000 ? grouped(v) : String(v) }

    /// The rewrite starting at toks[i]: tokens, the index after them, and
    /// whether the first one joins the previous word ("Qwen" + "3").
    private static func number(at i: Int, in toks: [Tok], out: [Tok]) -> ([Tok], Int, Bool)? {
        let prev = out.last
        let prevCore = prev?.core ?? ""
        let sentenceStart = prev == nil || prev!.endsClause

        // A month and an ordinal: "March third" → "March 3".
        if let o = ordinals[toks[i].core], months.contains(prevCore), !(prev?.endsClause ?? true) {
            return ([Tok(lead: toks[i].lead, word: String(o), trail: toks[i].trail)], i + 1, false)
        }
        if let (s, next) = digitRun(toks, i) {
            return ([Tok(lead: toks[i].lead, word: s, trail: toks[next - 1].trail)], next, false)
        }
        // A model number said in pairs after an all-caps name: "RTX fifty
        // ninety" → "RTX 5090".
        if let p = prev, !p.endsClause, p.word.count >= 2, p.word == p.word.uppercased(),
           p.word.contains(where: { $0.isLetter }), let a = cardinal(toks, i), (10...99).contains(a.value), !a.stop,
           let b = cardinal(toks, a.next), (10...99).contains(b.value) {
            return ([Tok(lead: toks[i].lead, word: "\(a.value)\(b.value)", trail: toks[b.next - 1].trail)], b.next, false)
        }
        // A year said in pairs: "twenty twenty six" → 2026, "nineteen ninety" → 1990.
        if ["twenty", "nineteen"].contains(toks[i].core), !toks[i].endsClause, i + 1 < toks.count {
            if let y = cardinal(toks, i + 1), (10...99).contains(y.value) {
                let century = toks[i].core == "twenty" ? 2000 : 1900
                return ([Tok(lead: toks[i].lead, word: String(century + y.value), trail: toks[y.next - 1].trail)], y.next, false)
            }
        }
        // "two fifteen" with no a.m. or p.m.: a time said loosely, or not a
        // time at all. Half in digits ("two 15") is wrong either way: words stay.
        if let p = prev, !p.endsClause, let h = ones[p.core], h > 0,
           let m = cardinal(toks, i), (10...59).contains(m.value) {
            let probe = m.next < toks.count ? toks[m.next].core : ""
            if !["a.m.", "p.m.", "am", "pm"].contains(probe) { return nil }
        }
        guard var n = cardinal(toks, i) else { return nil }
        var text = String(n.value)
        var trail = toks[n.next - 1].trail
        var forced = false          // digits even for zero to nine
        var next = n.next

        // Decimal: "zero point four three".
        if !n.stop, next < toks.count, toks[next].core == "point" {
            var k = next + 1, frac = ""
            while k < toks.count, let v = ones[toks[k].core] {
                frac += String(v); k += 1
                if toks[k - 1].endsClause { break }
            }
            if !frac.isEmpty {
                text = "\(n.value).\(frac)"; trail = toks[k - 1].trail; next = k; forced = true
                n.stop = toks[k - 1].endsClause
            }
        }
        let isDecimal = text.contains(".")

        // Money: "four dollars and fifty cents".
        if !n.stop, next < toks.count, ["dollars", "dollar", "bucks"].contains(toks[next].core) {
            var money = "$" + (isDecimal ? text : (n.value >= 1000 ? grouped(n.value) : String(n.value)))
            var k = next + 1; trail = toks[next].trail
            if !toks[next].endsClause, k + 1 < toks.count, toks[k].core == "and",
               let c = cardinal(toks, k + 1), c.value < 100, c.next < toks.count,
               ["cents", "cent"].contains(toks[c.next].core), !isDecimal {
                money += String(format: ".%02d", c.value); trail = toks[c.next].trail; k = c.next + 1
            }
            return ([Tok(lead: toks[i].lead, word: money, trail: trail)], k, false)
        }

        // Time: "four fifteen p.m.", "seven oh five a.m.".
        if !isDecimal, !n.stop, (1...12).contains(n.value), next < toks.count {
            var k = next, minutes: Int?
            if toks[k].core == "oh", k + 1 < toks.count, let v = ones[toks[k + 1].core], v > 0 { minutes = v; k += 2 }
            else if let m = cardinal(toks, k), (10...59).contains(m.value) { minutes = m.value; k = m.next }
            if let m = minutes, k < toks.count, ["a.m.", "p.m.", "am", "pm"].contains(toks[k].core) {
                let ap = toks[k].core.hasPrefix("a") ? "a.m." : "p.m."
                return ([Tok(lead: toks[i].lead, word: "\(n.value):" + String(format: "%02d", m) + " " + ap,
                             trail: toks[k].trail)], k + 1, false)
            }
        }

        // Range: "five to ten" → "5-10"; after "from", "from 5 to 10".
        if !n.stop, next + 1 < toks.count, toks[next].core == "to", let m = cardinal(toks, next + 1), m.value > n.value {
            let a = isDecimal ? text : digits(n.value), b = digits(m.value)
            var rendered: [Tok]
            if prevCore == "from" {
                rendered = [Tok(lead: toks[i].lead, word: a, trail: ""), Tok(word: "to"),
                            Tok(word: b, trail: toks[m.next - 1].trail)]
            } else {
                rendered = [Tok(lead: toks[i].lead, word: "\(a)-\(b)", trail: toks[m.next - 1].trail)]
            }
            var k = m.next
            if !toks[m.next - 1].endsClause, k < toks.count, let u = units[toks[k].core] {
                rendered[rendered.count - 1].word += u == "%" ? "%" : " " + u
                rendered[rendered.count - 1].trail = toks[k].trail; k += 1
            }
            return (rendered, k, false)
        }

        // A unit after it.
        if !n.stop, next < toks.count {
            let u = toks[next].core
            if u == "percent" || (u == "per" && next + 1 < toks.count && toks[next + 1].core == "cent") {
                let k = u == "per" ? next + 2 : next + 1
                return ([Tok(lead: toks[i].lead, word: text + "%", trail: toks[k - 1].trail)], k, false)
            }
            if let short = units[u] {
                return ([Tok(lead: toks[i].lead, word: text, trail: ""),
                         Tok(word: short, trail: toks[next].trail)], next + 1, false)
            }
            if isDecimal, u == "seconds" || u == "second" {
                return ([Tok(lead: toks[i].lead, word: text, trail: ""), Tok(word: "s", trail: toks[next].trail)], next + 1, false)
            }
            if wordUnits.contains(u) { forced = true }
        }

        // A version after a name: "Qwen three" → "Qwen3", "V two" → "V2",
        // "Gemini three" → "Gemini 3". Not at a sentence start.
        // The word before is itself the first of its sentence ("Call nine…"):
        // capitalised for the sentence, not because it is a name.
        let prevOpensSentence = out.count < 2 || out[out.count - 2].endsClause
        if let p = prev, !sentenceStart, n.value < 100, !isDecimal {
            let w = p.word
            let letter = w.count == 1 && w.first!.isUppercase && w != "I" && w != "A"
            if letter || gluedNames.contains(p.core), p.trail.isEmpty {
                return ([Tok(word: text, trail: trail)], next, true)
            }
            if versionWords.contains(p.core), n.small { forced = true }
            if w.first?.isUppercase == true, w.count > 1, w.dropFirst().contains(where: { $0.isLowercase }),
               !isNumberWord(p.core), !prevOpensSentence,
               !["I", "The", "A", "An"].contains(w), n.small { forced = true }
        }

        // Address parts: "Flat Three B" → "Flat 3B", "Five Park Road" → "5 Park Road".
        if unitWords.contains(prevCore), !(prev?.endsClause ?? true), !isDecimal {
            var word = digits(n.value)
            if !n.stop, next < toks.count, toks[next].word.count == 1, toks[next].word.first!.isUppercase,
               toks[next].word != "I", toks[next].word != "A" {
                word += toks[next].word; trail = toks[next].trail; next += 1
            }
            return ([Tok(lead: toks[i].lead, word: word, trail: trail)], next, false)
        }
        // Only when it reads as an address: the number capitalised mid-sentence
        // ("at Five Park Road") or right after "at"/"on" — not "one Big Road trip".
        let addressy = (toks[i].word.first?.isUppercase == true && !sentenceStart) || ["at", "on"].contains(prevCore)
        if addressy, !n.stop, !isDecimal, next + 1 < toks.count, toks[next].word.first?.isUppercase == true,
           !toks[next].endsClause, streetTypes.contains(toks[next + 1].core) {
            forced = true
        }

        if n.small && !forced && !isDecimal { return nil }
        return ([Tok(lead: toks[i].lead, word: isDecimal ? text : digits(n.value), trail: trail)], next, false)
    }
}
