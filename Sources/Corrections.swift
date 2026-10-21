// Auto-learn: after a paste, watch the field we pasted into and notice when you
// fix words by hand ("Janish" -> "Janice"). What each fix becomes — a rule, a
// hint, or nothing — is the app delegate's call (`learned(_:original:edited:)`).
//
// The edit is judged once, when it is FINISHED: the text leaves the field (sent
// or cleared), the next dictation starts, or the watch runs out. Judged after a
// pause instead, it learned half-typed words ("SayCTroll", "cloude", "Ped") and
// both halves of a two-step fix. Then the pasted words are lined up against the
// final ones, and only a one-for-one word swap counts; a message rewritten
// wholesale teaches nothing.
//
// Reads the focused field through the Accessibility API (a grant the app already
// needs in order to paste). Nothing is stored but the word pair, nothing leaves
// the Mac. Fields that don't expose their text (terminals, some Electron apps)
// simply can't be watched — we log it and move on.
import Cocoa
import ApplicationServices

final class CorrectionWatcher {

    /// One word you changed: what was pasted, what you made it.
    struct Fix: Equatable {
        let heard: String
        let meant: String
    }

    /// The finished edit's fixes, with the text as pasted and as you left it —
    /// the handler anchors a fix to its neighbour, or asks the model about it.
    var onEdit: (([Fix], _ original: String, _ edited: String) -> Void)?

    private var timer: Timer?
    private var element: AXUIElement?
    private var baseline: [Character] = []
    private var regionStart = 0          // where our pasted text sits in the field
    private var regionLen = 0
    /// The paste as it landed, and as it stood after the last settled edit.
    private var original = ""
    private var lastRegion = ""
    /// The paste as the last poll saw it, and whether it had held still for a
    /// poll — so a message sent a moment after its last fix keeps that fix.
    private var seenRegion = ""
    private var seenStill = false
    /// What stood there the instant before the field emptied at once.
    private var sentRegion: String?
    private var deadline = Date.distantPast
    private var misses = 0
    private var attempt = 0
    private var pendingPasted = ""
    private var retryWork: DispatchWorkItem?

    // Debounce state: an edit must look the same across polls before we judge it.
    private var pendingKey = ""
    private var pendingSince = Date.distantPast

    private let pollInterval: TimeInterval = 0.4
    private let stableDelay: TimeInterval = 1.1
    private let watchWindow: TimeInterval = 90
    private let maxLearns = 4
    /// More of the pasted words swapped than this is a rewrite, not a fix.
    private let rewriteShare = 0.3
    // Chrome took ~5s to publish its tree after being asked, so keep trying for ~9s.
    private let maxAttempts = 13
    private let retryDelay: TimeInterval = 0.7
    private let maxMisses = 4

    // MARK: - Lifecycle

    /// Ends the watch, judging what was edited so far.
    func stop() {
        judge()
        reset()
    }

    private func reset() {
        timer?.invalidate()
        timer = nil
        retryWork?.cancel()
        retryWork = nil
        element = nil
        baseline = []
        original = ""
        lastRegion = ""
        seenRegion = ""
        seenStill = false
        sentRegion = nil
        pendingKey = ""
        misses = 0
    }

    /// The finished edit, lined up against the paste.
    private func judge() {
        guard element != nil, !original.isEmpty, lastRegion != original else { return }
        guard let fixes = Self.fixes(from: original, to: lastRegion, rewriteShare: rewriteShare) else {
            Config.shared.log("Auto-learn: the paste was rewritten, not corrected — nothing learned")
            return
        }
        guard !fixes.isEmpty else { return }
        onEdit?(Array(fixes.prefix(maxLearns)), original, lastRegion)
    }

    func begin(pasted: String) {
        stop()
        guard pasted.count >= 2, pasted.count < 20_000 else { return }
        guard AXIsProcessTrusted() else {
            Config.shared.log("Auto-learn: no Accessibility permission — skipped")
            return
        }
        pendingPasted = pasted
        attempt = 0
        attach()
    }

    /// Finding the field can take a couple of tries: the paste may still be landing,
    /// and Chromium/Electron apps only publish their accessibility tree once asked.
    private func attach() {
        attempt += 1
        let pasted = pendingPasted

        if let hit = Self.locate(pasted: Array(pasted)) {
            element = hit.element
            baseline = hit.text
            regionStart = hit.start
            regionLen = pasted.count
            original = pasted
            lastRegion = pasted
            seenRegion = pasted
            seenStill = true
            sentRegion = nil
            misses = 0
            pendingKey = ""
            deadline = Date().addingTimeInterval(watchWindow)
            timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
                self?.tick()
            }
            Config.shared.log("Auto-learn: watching \(Self.describe(hit.element)) — \(hit.text.count) chars")
            return
        }

        guard attempt < maxAttempts else {
            let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "the frontmost app"
            Config.shared.log("Auto-learn: couldn't read the text of the field in \(app) "
                              + "— it may not publish its content over Accessibility. Skipped.")
            return
        }

        // Backstop for when recording didn't get there first (e.g. the user switched
        // apps mid-dictation): ask now and keep retrying while the tree is built.
        if attempt == 1 { Self.prepareFrontmostApp() }
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.attach() }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: work)
    }

    // MARK: - The diff

    enum Outcome: Equatable {
        /// Field is untouched since we last looked.
        case unchanged
        /// Edit landed outside our pasted text; re-anchor by this many characters.
        case outside(shift: Int)
        /// Edit landed inside our pasted text. `key` identifies it for debouncing.
        case inside(key: String)
    }

    /// The whole comparison, as a pure function — no AX, no clock, so it can be tested.
    static func classify(baseline a: [Character], current b: [Character],
                         regionStart: Int, regionLen: Int) -> Outcome {
        if a == b { return .unchanged }

        // Narrow the change down to the span between the common prefix and suffix.
        var p = 0
        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
        var s = 0
        while s < a.count - p, s < b.count - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        let aEnd = a.count - s
        let bEnd = b.count - s

        // Typing somewhere else in the document.
        let regionEnd = regionStart + regionLen
        if p >= regionEnd { return .outside(shift: 0) }
        if aEnd <= regionStart { return .outside(shift: bEnd - aEnd) }

        return .inside(key: "\(p)|\(aEnd)|\(String(b[p..<bEnd]))")
    }

    /// The word swaps between the paste and the finished text, found by lining
    /// the two word lists up (longest common subsequence). A gap with as many
    /// words on each side (two at most) is that many swaps; words only added
    /// or only removed, or three swapped for two, are writing, not fixing,
    /// and are passed over. nil when more than `rewriteShare` of
    /// the pasted words were swapped — a rewrite, whose swaps mean nothing.
    static func fixes(from original: String, to edited: String, rewriteShare: Double = 0.3) -> [Fix]? {
        let a = words(in: ArraySlice(Array(original)))
        let b = words(in: ArraySlice(Array(edited)))
        guard !a.isEmpty, a.count <= 1500, b.count <= 1500 else { return [] }
        // lcs[i][j]: the longest common run of a[i...] and b[j...].
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var out: [Fix] = []
        var swapped = 0
        var i = 0, j = 0
        var gapA: [String] = [], gapB: [String] = []
        func closeGap() {
            if !gapA.isEmpty, !gapB.isEmpty { swapped += gapA.count }
            // Side by side, word for word: "tell Iqra" → "Tell Ikra" is two swaps.
            if gapA.count == gapB.count, gapA.count <= 2 {
                for (heard, meant) in zip(gapA, gapB) { out.append(Fix(heard: heard, meant: meant)) }
            }
            gapA = []; gapB = []
        }
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                closeGap()
                i += 1; j += 1
            } else if j < b.count, i == a.count || lcs[i][j + 1] >= lcs[i + 1][j] {
                gapB.append(b[j]); j += 1
            } else {
                gapA.append(a[i]); i += 1
            }
        }
        closeGap()
        if Double(swapped) > max(3, Double(a.count) * rewriteShare) { return nil }
        return out
    }

    private func tick() {
        if Date() > deadline { stop(); return }
        guard let el = element else { stop(); return }
        guard let current = Self.stringValue(of: el) else {
            // A read can fail briefly (window redrawing, field rebuilt). Only give up
            // once it keeps failing.
            misses += 1
            if misses >= maxMisses { stop() }
            return
        }
        misses = 0

        let a = baseline
        let b = Array(current)

        switch Self.classify(baseline: a, current: b, regionStart: regionStart, regionLen: regionLen) {
        case .unchanged:
            pendingKey = ""
            seenRegion = lastRegion
            seenStill = true

        case .outside(let shift):
            regionStart += shift
            baseline = b
            pendingKey = ""

        case .inside(let key):
            let len = regionLen + (b.count - a.count)
            if len >= original.count / 2 {
                let end = min(b.count, regionStart + len)
                let region = regionStart < end ? String(b[regionStart..<end]) : ""
                seenStill = region == seenRegion
                seenRegion = region
            } else if seenStill, Double(len) < Double(seenRegion.count) * 0.2 {
                // Gone in one poll — sent or cleared, not backspaced away —
                // from a text that had held still: that text was the message.
                sentRegion = seenRegion
            }
            // Wait for the edit to settle — mid-word keystrokes are not corrections.
            if key != pendingKey {
                pendingKey = key
                pendingSince = Date()
                return
            }
            if Date().timeIntervalSince(pendingSince) < stableDelay { return }

            // Re-anchor, so the next poll compares against what's there now.
            baseline = b
            regionLen = max(0, regionLen + (b.count - a.count))
            pendingKey = ""

            // Most of the paste gone at once: the message was sent or the field
            // cleared. What stood there just before is the finished edit.
            if regionLen < original.count / 2 {
                if let sent = sentRegion { lastRegion = sent }
                stop()
                return
            }
            let end = min(b.count, regionStart + regionLen)
            lastRegion = regionStart < end ? String(b[regionStart..<end]) : ""
        }
    }

    /// A real-word fix ("art" → "Arc") is too dangerous as a bare rule —
    /// the heard word is still English and would be eaten from every
    /// transcript. Anchored to the word that stood next to it in the
    /// paste ("open art browser"), it becomes a phrase rule the existing
    /// machinery applies safely: "art browser" → "Arc browser". The word
    /// after wins over the word before — spoken names trail their
    /// qualifier ("arc browser", "req key") more often than they lead
    /// it. Only a plain-space neighbor counts: across a comma ("area,
    /// honestly") the words aren't really together, and the rule made
    /// from them could never match a future transcript's comma anyway.
    /// And only a word with meaning of its own: "cloud is", "agar to",
    /// "grok as" never came round again (17 such rules, not one hit in a
    /// month), while "art browser" fired 25 times and "cloud session" 7.
    /// nil = no such neighbor.
    static func contextPhrase(for from: String, to: String, in pasted: String)
        -> (from: String, to: String)? {
        let chars = Array(pasted)
        let f = Array(from.lowercased())
        guard !f.isEmpty else { return nil }
        var start = -1
        for i in 0...(max(0, chars.count - f.count)) where i + f.count <= chars.count {
            guard i == 0 || !isWordChar(chars[i - 1]) else { continue }
            guard i + f.count == chars.count || !isWordChar(chars[i + f.count]) else { continue }
            if String(chars[i..<i + f.count]).lowercased() == String(f) { start = i; break }
        }
        guard start >= 0 else { return nil }
        let end = start + f.count
        let heard = String(chars[start..<end])

        var j = end
        while j < chars.count, chars[j] == " " { j += 1 }
        if j > end, j < chars.count, isWordChar(chars[j]) {
            var k = j
            while k < chars.count, isWordChar(chars[k]) { k += 1 }
            let next = String(chars[j..<k])
            if !fillerWords.contains(next.lowercased()) { return ("\(heard) \(next)", "\(to) \(next)") }
        }
        var b = start
        while b > 0, chars[b - 1] == " " { b -= 1 }
        if b < start, b > 0, isWordChar(chars[b - 1]) {
            var a = b
            while a > 0, isWordChar(chars[a - 1]) { a -= 1 }
            let prev = String(chars[a..<b])
            if !fillerWords.contains(prev.lowercased()) { return ("\(prev) \(heard)", "\(prev) \(to)") }
        }
        return nil
    }

    /// Words that say nothing about what stands next to them.
    static let fillerWords: Set<String> = [
        "a", "an", "the", "to", "of", "in", "on", "at", "by", "for", "with", "from", "into", "about", "as",
        "and", "or", "but", "so", "if", "then", "than", "that", "this", "these", "those", "there", "here",
        "is", "are", "was", "were", "be", "been", "being", "am", "has", "have", "had", "do", "does", "did",
        "will", "would", "can", "could", "should", "may", "might", "must", "shall", "not", "no", "just",
        "also", "now", "it", "its", "it's", "i", "i'm", "me", "my", "we", "our", "us", "you", "your",
        "he", "him", "his", "she", "her", "they", "them", "their", "what", "which", "who", "when", "how",
        "all", "some", "any", "up", "out", "like", "very", "really", "okay", "ok", "yes", "yeah",
    ]

    // MARK: - Judging a candidate

    /// Is this edit shaped like "you fixed a misheard word", rather than a rewrite,
    /// a deletion, or a word being typed?
    static func plausible(from: String, to: String) -> Bool {
        guard from.count >= 2, from.count <= 40, to.count >= 1, to.count <= 40 else { return false }
        guard from != to else { return false }

        let wordish = "^[\\p{L}][\\p{L}'’\\-]*$"
        guard from.range(of: wordish, options: .regularExpression) != nil,
              to.range(of: wordish, options: .regularExpression) != nil else { return false }

        let f = from.lowercased(), t = to.lowercased()
        if f == t { return true }                                  // capitalisation fix
        if f.hasPrefix(t) && t.count < f.count - 2 { return false } // truncation / mid-typing
        let distance = levenshtein(Array(f), Array(t))
        return distance <= max(2, Int(ceil(Double(max(f.count, t.count)) * 0.5)))
    }

    /// The distance gate above judges letters, but mishearings of a name are
    /// phonetic: "Swaraj" → "Sorower" is distance 6 and still exactly the fix
    /// it looks like (rejected live, 2026-08-20). When the corrected-TO word
    /// is one the dictionary already fixes to — or a word of the user's own
    /// name — the target itself is the evidence, so the pair is trusted at
    /// any distance. The spoken-word guard after this still applies: the
    /// heard word must actually come from our paste.
    static func knownTarget(_ to: String) -> Bool {
        guard to.count >= 2, to.count <= 40,
              to.range(of: "^[\\p{L}][\\p{L}'’\\-]*$", options: .regularExpression) != nil
        else { return false }
        let t = to.lowercased()
        if Account.name.lowercased().split(separator: " ").map(String.init).contains(t) {
            return true
        }
        return ReplacementStore.shared.rules.contains { $0.to.lowercased() == t }
    }

    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var row = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            row[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                row[j] = min(prev[j] + 1, row[j - 1] + 1, prev[j - 1] + cost)
            }
            prev = row
        }
        return prev[b.count]
    }

    // MARK: - Text helpers

    static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "'" || c == "’" || c == "-"
    }

    static func words(in slice: ArraySlice<Character>) -> [String] {
        var out: [String] = []
        var buf = ""
        for c in slice {
            if isWordChar(c) { buf.append(c) }
            else if !buf.isEmpty { out.append(buf); buf = "" }
        }
        if !buf.isEmpty { out.append(buf) }
        return out
    }

    static func lastIndex(of needle: [Character], in haystack: [Character]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        var i = haystack.count - needle.count
        while i >= 0 {
            var match = true
            for k in 0..<needle.count where haystack[i + k] != needle[k] { match = false; break }
            if match { return i }
            i -= 1
        }
        return nil
    }

    // MARK: - Accessibility plumbing

    struct Located {
        let element: AXUIElement
        let text: [Character]
        let start: Int
    }

    /// Find the element whose text contains what we just pasted. The system-wide
    /// focused-element query fails outright in some apps (notably Chromium/Electron
    /// ones), so fall back to the frontmost app's own focused element and window,
    /// then search downwards for the text.
    /// Web content sits deep (window → … → web area → group → text area), so the
    /// limits are generous. This runs once when attaching; polling afterwards only
    /// touches the single element we found.
    static func locate(pasted: [Character]) -> Located? {
        for root in candidateRoots() {
            var budget = 4000
            if let hit = findText(pasted: pasted, in: root, depth: 0, budget: &budget) { return hit }
        }
        return nil
    }

    static func candidateRoots() -> [AXUIElement] {
        var out: [AXUIElement] = []
        if let el = element(of: AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute) {
            out.append(el)
        }
        if let app = NSWorkspace.shared.frontmostApplication {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            if let el = element(of: appElement, kAXFocusedUIElementAttribute) { out.append(el) }
            if let win = element(of: appElement, kAXFocusedWindowAttribute) { out.append(win) }
        }
        return out
    }

    /// Apps we have already asked to publish their accessibility tree this session.
    private static var enabledPids = Set<pid_t>()

    /// Chromium-based apps (Chrome, Electron apps like Slack or Claude) don't build
    /// an accessibility tree until an assistive client asks for one, so the focused
    /// text field is invisible to us — which is why auto-learn silently did nothing
    /// there. Setting AXEnhancedUserInterface is that ask; it's the same switch
    /// VoiceOver and other assistive tools flip. Measured: Chrome needs ~5s to build
    /// the tree, so we ask when recording starts rather than when the paste lands.
    /// Only done once per app per session, and only when auto-learn is on.
    @discardableResult
    static func requestAccessibilityTree(for app: NSRunningApplication?) -> Bool {
        guard let app = app, !app.isTerminated else { return false }
        let pid = app.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier else { return false }
        let appElement = AXUIElementCreateApplication(pid)

        // Already talking to us? Then nothing to do.
        if element(of: appElement, kAXFocusedUIElementAttribute) != nil { return false }
        guard !enabledPids.contains(pid) else { return false }
        enabledPids.insert(pid)

        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        // Harmless where unsupported; some Electron builds listen for this one instead.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        Config.shared.log("Auto-learn: asked \(app.localizedName ?? "pid \(pid)") to publish its "
                          + "accessibility tree (needed to see your edits)")
        return true
    }

    /// Called when recording starts, so the app has the whole record+transcribe
    /// window to build its tree before we need to read it.
    static func prepareFrontmostApp() {
        requestAccessibilityTree(for: NSWorkspace.shared.frontmostApplication)
    }

    /// Depth- and node-limited hunt for an element whose value contains `pasted`.
    static func findText(pasted: [Character], in node: AXUIElement,
                         depth: Int, budget: inout Int) -> Located? {
        guard budget > 0 else { return nil }
        budget -= 1
        if let s = stringValue(of: node), s.count < 400_000, s.count >= pasted.count {
            let chars = Array(s)
            if let start = lastIndex(of: pasted, in: chars) {
                return Located(element: node, text: chars, start: start)
            }
        }
        guard depth < 22 else { return nil }
        for child in children(of: node) {
            if let hit = findText(pasted: pasted, in: child, depth: depth + 1, budget: &budget) {
                return hit
            }
        }
        return nil
    }

    static func element(of parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(v, to: AXUIElement.self)
    }

    static func children(of node: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &value) == .success,
              let array = value as? [AnyObject] else { return [] }
        return array.compactMap {
            CFGetTypeID($0) == AXUIElementGetTypeID() ? unsafeBitCast($0, to: AXUIElement.self) : nil
        }
    }

    static func stringValue(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let s = value as? String else { return nil }
        return s
    }

    /// What sits immediately left of the insertion point in the focused
    /// element, when the app will say: the character, or the fact that
    /// the caret is at the very start. Secure fields, terminals and many
    /// web views answer nothing — the caller falls back to its own
    /// memory. Used by the paste to decide whether a new dictation needs
    /// a space in front of it.
    enum BeforeCursor { case char(Character), start, unknown }
    static func beforeCursor() -> BeforeCursor {
        for el in candidateRoots().prefix(2) {
            var v: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &v) == .success,
                  let av = v, CFGetTypeID(av) == AXValueGetTypeID() else { continue }
            var range = CFRange()
            guard AXValueGetValue(unsafeBitCast(av, to: AXValue.self), .cfRange, &range) else { continue }
            if range.location == 0 { return .start }
            // One character, asked for by range — never copying a document.
            // AX ranges count UTF-16 units, so slicing goes through NSString.
            var ask = CFRange(location: range.location - 1, length: 1)
            var param: CFTypeRef?
            if let axAsk = AXValueCreate(.cfRange, &ask),
               AXUIElementCopyParameterizedAttributeValue(
                   el, kAXStringForRangeParameterizedAttribute as CFString, axAsk, &param) == .success,
               let s = param as? String, let c = s.last {
                return .char(c)
            }
            if let s = stringValue(of: el), s.count < 400_000 {
                let ns = s as NSString
                guard range.location <= ns.length else { continue }
                let one = ns.substring(with: NSRange(location: range.location - 1, length: 1))
                if let c = one.last { return .char(c) }
            }
        }
        return .unknown
    }

    static func describe(_ element: AXUIElement) -> String {
        var value: CFTypeRef?
        var role = "?"
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success,
           let r = value as? String { role = r }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let app = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
        return "\(role) in \(app)"
    }
}
