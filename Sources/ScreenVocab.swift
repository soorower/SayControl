// Screen-aware vocabulary: when recording starts, skim the frontmost window
// for the words a recognizer is most likely to fumble — names, products,
// jargon — and offer them as hints alongside the dictionary. The contact you
// are replying to, the file names in your project, the app you are about to
// say "open" at: they are all sitting on screen, already spelled right.
//
// Same Accessibility grant the paste and auto-learn already use; nothing is
// stored, and the words ride the existing hint channel to whichever
// recognizer you picked (so with a cloud provider they leave the Mac exactly
// as far as your voice already does — the Settings toggle says so).
//
// The scan runs on a background queue and takes as long as it takes: the
// dictation being spoken meanwhile is the time budget. Whatever is ready
// when transcription asks is what gets used — typically the fresh scan, or
// the previous one of the same app while the fresh one is still walking.
import Cocoa
import ApplicationServices

final class ScreenVocab {
    static let shared = ScreenVocab()

    private let lock = NSLock()
    private var scannedBundle: String?
    private var scannedAt = Date.distantPast
    private var scanned: [String] = []
    private var generation = 0
    private let queue = DispatchQueue(label: "sayctrl.screenvocab", qos: .userInitiated)

    private let maxWords = 24            // leave room under the provider hint caps
    private let maxAge: TimeInterval = 300
    // Electron/Chromium windows nest their content 20–30 levels deep behind
    // the UI chrome — a shallow walk sees the sidebar and nothing else.
    // Auto-learn reaches the text area in those apps at 4000 nodes; give the
    // scan more, it runs on its own queue while you talk.
    private let nodeBudget = 6000
    private let maxDepth = 40
    private let maxTextPerNode = 4000
    private let maxTotalText = 60_000

    /// Best available screen words right now: what the last completed scan
    /// found — as long as it is warm and from the app still in front — then
    /// running app names (the things you say "open" at). The scan outranks
    /// the app names: it is fresher and closer to what you're about to say,
    /// and tight provider caps cut from the tail.
    var words: [String] {
        guard Config.shared.screenVocab else { return [] }
        return scannedWords + Self.runningAppNames()
    }

    /// The scan's own words alone, without the running apps' names.
    var scannedWords: [String] {
        guard Config.shared.screenVocab else { return [] }
        lock.lock(); defer { lock.unlock() }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard scannedBundle != nil, scannedBundle == front,
              Date().timeIntervalSince(scannedAt) < maxAge else { return [] }
        return scanned
    }

    /// Kick off a scan of the frontmost app. Called when recording starts, so
    /// the words are ready by the time the audio needs transcribing.
    func beginScan() {
        guard Config.shared.screenVocab, AXIsProcessTrusted() else { return }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        // Chromium/Electron windows publish no text until asked (same dance
        // auto-learn does) — the first scan of such an app comes up empty and
        // the next one sees it.
        CorrectionWatcher.requestAccessibilityTree(for: app)
        let pid = app.processIdentifier
        let bundle = app.bundleIdentifier
        lock.lock()
        generation += 1
        let gen = generation
        lock.unlock()

        queue.async { [weak self] in
            guard let self = self else { return }
            let (texts, nodes) = Self.collectTexts(pid: pid,
                                                   nodeBudget: self.nodeBudget,
                                                   maxDepth: self.maxDepth,
                                                   maxPerNode: self.maxTextPerNode,
                                                   maxTotal: self.maxTotalText)
            // The spell checker is AppKit — filter on the main thread.
            DispatchQueue.main.async {
                let words = Self.pickVocabulary(from: texts, cap: self.maxWords)
                self.lock.lock()
                // A newer scan may already be running — don't overwrite its target.
                if self.generation == gen {
                    self.scannedBundle = bundle
                    self.scannedAt = Date()
                    self.scanned = words
                }
                self.lock.unlock()
                Config.shared.log("Screen vocab: \(words.count) word(s) "
                                  + "(\(nodes) nodes, \(texts.count) strings) — "
                                  + (words.isEmpty ? "nothing unusual on screen"
                                     : Config.words(words.prefix(8).joined(separator: ", ")
                                       + (words.count > 8 ? ", …" : ""))))
            }
        }
    }

    // MARK: - Collecting (background queue)

    /// Walk the app's focused window and gather every string it shows —
    /// values, titles and descriptions, since chat text sits in values,
    /// names of buttons/tabs/files sit in titles, and Electron apps often
    /// label things through descriptions. The focused element goes first:
    /// it is the caret's neighborhood, the cheapest place to look.
    static func collectTexts(pid: pid_t, nodeBudget: Int, maxDepth: Int,
                             maxPerNode: Int, maxTotal: Int) -> (texts: [String], nodes: Int) {
        let appEl = AXUIElementCreateApplication(pid)
        var roots: [AXUIElement] = []
        if let el = CorrectionWatcher.element(of: appEl, kAXFocusedUIElementAttribute) { roots.append(el) }
        if let win = CorrectionWatcher.element(of: appEl, kAXFocusedWindowAttribute) { roots.append(win) }
        if roots.isEmpty, let win = CorrectionWatcher.element(of: appEl, kAXMainWindowAttribute) { roots.append(win) }
        var out: [String] = []
        var budget = nodeBudget
        var total = 0
        for root in roots {
            gather(node: root, depth: 0, budget: &budget, total: &total,
                   maxDepth: maxDepth, maxPerNode: maxPerNode, maxTotal: maxTotal, into: &out)
        }
        return (out, nodeBudget - budget)
    }

    private static func gather(node: AXUIElement, depth: Int, budget: inout Int, total: inout Int,
                               maxDepth: Int, maxPerNode: Int, maxTotal: Int, into out: inout [String]) {
        guard budget > 0, total < maxTotal else { return }
        budget -= 1
        for attr in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(node, attr as CFString, &value) == .success,
                  let s = value as? String, !s.isEmpty else { continue }
            let clipped = String(s.prefix(maxPerNode))
            out.append(clipped)
            total += clipped.count
        }
        guard depth < maxDepth else { return }
        for child in CorrectionWatcher.children(of: node) {
            gather(node: child, depth: depth + 1, budget: &budget, total: &total,
                   maxDepth: maxDepth, maxPerNode: maxPerNode, maxTotal: maxTotal, into: &out)
        }
    }

    // MARK: - Filtering (main thread — NSSpellChecker)

    /// From everything on screen, keep what a recognizer can't guess: tokens
    /// the spell checker doesn't know ("Sorower", "ReqKey", "Groq"), ranked
    /// by how often they appear. Real words don't need help; digits-heavy
    /// tokens are ids, not speech.
    static func pickVocabulary(from texts: [String], cap: Int) -> [String] {
        var counts: [String: Int] = [:]     // lowercased -> count
        var casing: [String: String] = [:]  // lowercased -> first casing seen
        for text in texts {
            var word = ""
            for ch in text + " " {
                if CorrectionWatcher.isWordChar(ch) { word.append(ch); continue }
                defer { word = "" }
                guard word.count >= 2, word.count <= 24 else { continue }
                guard word.contains(where: { $0.isLetter }) else { continue }
                guard word.filter({ $0.isNumber }).count <= 3 else { continue }
                let key = word.lowercased()
                counts[key, default: 0] += 1
                if casing[key] == nil { casing[key] = word }
            }
        }
        let ranked = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        var out: [String] = []
        for (key, _) in ranked {
            guard out.count < cap else { break }
            // Check the lowercased form: the system checker waves through
            // capitalized unknowns (Contacts names, CamelCase) that are
            // exactly the vocabulary a recognizer needs help with.
            guard let word = casing[key], !Lexicon.isRealWord(key) else { continue }
            // A lowercase word one or two letters from a real one is a typo on
            // screen ("ususally", "soemthing"), not a name: hinting it would
            // teach the recognizer the misspelling.
            if word == key, Self.isLikelyTypo(key) { continue }
            out.append(word)
        }
        return out
    }

    /// A screen typo, not a name: the spell checker's guess is the same word
    /// with two neighbouring letters swapped ("soemthing", "becuase") or, in
    /// a long word, one letter fewer ("ususally"). Names miss real words in
    /// other ways — a letter short of one ("sorower"/"sorrower",
    /// "cohere"/"cohered") or one changed ("groq"/"grog") — and stay.
    static func isLikelyTypo(_ word: String) -> Bool {
        guard word.count >= 4 else { return false }
        let guesses = NSSpellChecker.shared.guesses(
            forWordRange: NSRange(location: 0, length: (word as NSString).length),
            in: word, language: "en", inSpellDocumentWithTag: 0) ?? []
        let w = Array(word)
        for guess in guesses.prefix(4) {
            let g = Array(guess.lowercased())
            guard !g.contains(" "), !g.contains("-") else { continue }
            if g.count == w.count {
                let diff = (0..<w.count).filter { w[$0] != g[$0] }
                if diff.count == 2, diff[1] == diff[0] + 1,
                   w[diff[0]] == g[diff[1]], w[diff[1]] == g[diff[0]] { return true }
            } else if w.count == g.count + 1, w.count >= 7 {
                // not the last letter: "cerebras" is a name, not "cerebra" plus a typo
                if (0..<(w.count - 1)).contains(where: { k in Array(w[..<k] + w[(k + 1)...]) == g }) { return true }
            }
        }
        return false
    }

    /// The names of the apps actually running — what "open …" gets aimed at,
    /// and names like "Arc" that are real words the screen filter would skip.
    static func runningAppNames(limit: Int = 12) -> [String] {
        var names: [String] = []
        if let front = NSWorkspace.shared.frontmostApplication?.localizedName { names.append(front) }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let name = app.localizedName, !names.contains(name) else { continue }
            names.append(name)
            if names.count >= limit { break }
        }
        return names
    }
}
