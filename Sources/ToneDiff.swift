// What a tone does to your words, shown on the card you point at.
//
// Every tone card carries the tab's spoken line the way that tone would type
// it (Tones.swift). Read cold, three samples side by side leave the question
// open: Balanced — compared with what? So pointing at a card lays its sample
// over the words as they were SAID and washes what changed: a capital, a
// comma, a contraction written out, a line break. What went away can't be
// washed in place, so it is listed under the sample instead.
//
// The baseline is the spoken line, not the neighbouring card, on purpose.
// The samples are all written FROM the spoken line and may only ever tidy
// it, so against it every change is something the tone did. Against a
// neighbour they are not: Work's Formal next to Balanced shows "So" and
// "and" as words Formal ADDED (Balanced had dropped them), Email's Formal
// next to Professional shows a line break taken away, and the first card of
// a row has no neighbour at all. Each card measured against what you said
// stands on its own, and moving from card to card compares them.
import Cocoa

// MARK: - The kinds of change

/// The ways a tone's sample can differ from what was said. Each is a
/// category with a hue of its own, the same wash in the text and the same
/// dot in the legend under it.
enum ToneChangeKind: CaseIterable {
    case capitals, punctuation, words, lineBreaks, removed

    var hue: Theme.Hue {
        switch self {
        case .capitals:    return .blue
        case .punctuation: return .green
        case .words:       return .violet
        case .lineBreaks:  return .amber
        case .removed:     return .rose
        }
    }

    var label: String {
        switch self {
        case .capitals:    return "Capitals"
        case .punctuation: return "Punctuation"
        // The one word change a tone may make is writing a contraction out
        // (Tones.swift, contractionBullet), so this says exactly that.
        case .words:       return "Written out"
        case .lineBreaks:  return "Line breaks"
        case .removed:     return "Removed"
        }
    }
}

// MARK: - The diff

/// What changed between the spoken line and a tone's sample, found word by
/// word: a longest common subsequence over words and punctuation marks,
/// matched without case, so a word that only gained a capital still lines up
/// with the one that was said.
struct ToneDiff {
    /// A stretch of the written sample to wash, and why.
    struct Mark { let range: NSRange; let kind: ToneChangeKind }
    /// Words that were said and didn't make it into the sample. `echo` is the
    /// copy that stayed when the cut was a stutter: a lone "is" in the list
    /// says nothing, "is ~~is~~" says what happened.
    struct Cut { let words: String; let echo: String?; let echoFirst: Bool }

    let marks: [Mark]
    let cuts: [Cut]
    /// Where the cut words sit in what was said, for striking them through
    /// in place.
    let cutRanges: [NSRange]
    /// Words that were said and written differently ("don't" → "do not"),
    /// where they sit in what was said, for underlining them in place.
    let rewrittenRanges: [NSRange]

    /// The kinds present, in the legend's order.
    var kinds: [ToneChangeKind] {
        ToneChangeKind.allCases.filter { kind in
            kind == .removed ? !cuts.isEmpty : marks.contains { $0.kind == kind }
        }
    }

    init(said: String, written: String) {
        let a = Self.tokens(said), b = Self.tokens(written)
        let n = a.count, m = b.count

        // Suffix table: lcs[i][j] is the longest match of a[i...] and b[j...].
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i][j] = a[i].key == b[j].key ? lcs[i + 1][j + 1] + 1
                                                     : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }

        var marks: [Mark] = []
        var cuts: [Cut] = []
        var cutRanges: [NSRange] = []
        var rewrittenRanges: [NSRange] = []
        // Everything between two matched tokens is one block: what was said
        // there (gone) against what was written there (new). A block holding
        // both a gone word and a new one is a word written differently.
        var gone: [Int] = [], new: [Int] = []

        func flush() {
            defer { gone.removeAll(); new.removeAll() }
            let newWords = new.filter { b[$0].kind == .word }
            let goneWords = gone.filter { a[$0].kind == .word }
            // "don't" → "do not": the contraction is what was rewritten. A
            // filler that happened to sit beside it still counts as cut.
            var rewritten: Set<Int> = []
            if !newWords.isEmpty {
                let contracted = goneWords.filter { a[$0].text.contains("'") || a[$0].text.contains("’") }
                rewritten = Set(contracted.isEmpty ? goneWords : contracted)
            }
            rewrittenRanges += rewritten.sorted().map { a[$0].range }
            // Consecutive new tokens of one kind wash as one box: "do not",
            // not "do" and "not".
            var run: (kind: ToneChangeKind, first: Int, last: Int)?
            func close() {
                guard let r = run else { return }
                let range = NSUnionRange(b[r.first].range, b[r.last].range)
                marks.append(Mark(range: range, kind: r.kind))
                run = nil
            }
            for j in new {
                let kind: ToneChangeKind
                switch b[j].kind {
                case .word:    kind = .words
                case .mark:    kind = .punctuation
                case .newline: kind = .lineBreaks
                }
                // Punctuation stays one box per mark — ", " and "." are two
                // changes, and one wash across the space between them would
                // read as a single one.
                if let r = run, r.kind == kind, r.last == j - 1, kind != .punctuation {
                    run = (kind, r.first, j)
                } else {
                    close()
                    run = (kind, j, j)
                }
            }
            close()

            let cut = goneWords.filter { !rewritten.contains($0) }
            cutRanges += cut.map { a[$0].range }
            guard let first = cut.first, let last = cut.last else { return }
            let words = cut.map { a[$0].text }
            let key = cut.map { a[$0].key }
            // A stutter: the same words said right before or right after.
            func said(_ range: Range<Int>) -> [Int] {
                range.clamped(to: 0..<n).filter { a[$0].kind == .word }
            }
            let before = Array(said((first - key.count * 2)..<first).suffix(key.count))
            let after = Array(said((last + 1)..<(last + 1 + key.count * 2)).prefix(key.count))
            if before.map({ a[$0].key }) == key {
                cuts.append(Cut(words: words.joined(separator: " "),
                                echo: before.map { a[$0].text }.joined(separator: " "), echoFirst: true))
            } else if after.map({ a[$0].key }) == key {
                cuts.append(Cut(words: words.joined(separator: " "),
                                echo: after.map { a[$0].text }.joined(separator: " "), echoFirst: false))
            } else {
                cuts.append(Cut(words: words.joined(separator: " "), echo: nil, echoFirst: false))
            }
        }

        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i].key == b[j].key {
                flush()
                marks += Self.capitals(said: a[i], written: b[j])
                i += 1; j += 1
            } else if j < m, i == n || lcs[i][j + 1] >= lcs[i + 1][j] {
                new.append(j); j += 1
            } else {
                gone.append(i); i += 1
            }
        }
        flush()
        self.marks = marks
        self.cuts = cuts
        self.cutRanges = cutRanges
        self.rewrittenRanges = rewrittenRanges
    }

    /// The letters of a matched word that only changed case: the "H" of
    /// "Hey", not the whole word.
    private static func capitals(said: Token, written: Token) -> [Mark] {
        guard said.text != written.text else { return [] }
        let s = Array(said.text), w = Array(written.text)
        guard s.count == w.count else { return [Mark(range: written.range, kind: .capitals)] }
        var out: [Mark] = []
        var offset = written.range.location
        for (x, y) in zip(s, w) {
            let length = String(y).utf16.count
            // Only a change of case: "don’t" for "don't" is the same word.
            if x != y, x.lowercased() == y.lowercased() {
                let r = NSRange(location: offset, length: length)
                if let last = out.last, NSMaxRange(last.range) == offset {
                    out[out.count - 1] = Mark(range: NSUnionRange(last.range, r), kind: .capitals)
                } else {
                    out.append(Mark(range: r, kind: .capitals))
                }
            }
            offset += length
        }
        return out
    }

    // MARK: Tokens

    fileprivate enum TokenKind { case word, mark, newline }

    fileprivate struct Token {
        let text: String
        let range: NSRange
        let kind: TokenKind
        /// What two tokens are compared by: case and apostrophe style don't
        /// make a different word.
        var key: String {
            kind == .word ? text.lowercased().replacingOccurrences(of: "’", with: "'") : text
        }
    }

    /// Words, single punctuation marks and line breaks, each with its range
    /// in the string. Spaces only separate. An apostrophe between letters
    /// stays inside its word, so "don't" is one word and writing it out is
    /// one change.
    private static func tokens(_ s: String) -> [Token] {
        var out: [Token] = []
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c.isNewline {
                let next = s.index(after: i)
                out.append(Token(text: "\n", range: NSRange(i..<next, in: s), kind: .newline))
                i = next
            } else if c.isWhitespace {
                i = s.index(after: i)
            } else if c.isLetter || c.isNumber {
                var end = s.index(after: i)
                while end < s.endIndex {
                    let d = s[end]
                    if d.isLetter || d.isNumber { end = s.index(after: end); continue }
                    if d == "'" || d == "’" {
                        let next = s.index(after: end)
                        if next < s.endIndex, s[next].isLetter { end = s.index(after: next); continue }
                    }
                    break
                }
                out.append(Token(text: String(s[i..<end]), range: NSRange(i..<end, in: s), kind: .word))
                i = end
            } else {
                let next = s.index(after: i)
                out.append(Token(text: String(c), range: NSRange(i..<next, in: s), kind: .mark))
                i = next
            }
        }
        return out
    }
}

// MARK: - The sample, with its changes

/// A tone's sample set the way every list sets your words (`Theme.saidFont`,
/// 1.3 line height, wrapping), which can wash its changes on request. Its own
/// small text system rather than a label, because the washes are drawn
/// behind particular glyphs and a label won't say where its glyphs are.
final class ToneSampleView: NSView {
    let diff: ToneDiff
    private let storage: NSTextStorage
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: 10_000, height: CGFloat.greatestFiniteMagnitude))
    private let font: NSFont
    private let color: NSColor
    /// Where the layout's origin is drawn: a hair above the view's top (see
    /// init), and the washes move with it.
    private let origin: NSPoint

    /// On while the card is pointed at. Off, the sample is plain text.
    var showsChanges = false {
        didSet {
            guard showsChanges != oldValue else { return }
            recolor()
            needsDisplay = true
        }
    }

    init(_ written: String, said: String, size: CGFloat, color: NSColor, lineHeight: CGFloat = 1.3) {
        diff = ToneDiff(said: said, written: written)
        font = Theme.saidFont(size)
        self.color = color
        // Lines exactly where a label puts them, so a sample sits like every
        // other list's words. A label draws with string drawing, which at
        // some sizes calls a line a point taller than the layout manager
        // does (SF at 14.5: 18 against 17), and the same 1.3 set here came
        // out a point and a half tighter a line. Scale the multiple by that,
        // and lift the text by it, since the layout manager puts the extra
        // above the letters.
        let natural = NSAttributedString(string: "Ag", attributes: [.font: font])
            .boundingRect(with: NSSize(width: 10_000, height: 10_000), options: [.usesLineFragmentOrigin]).height
        let typeset = NSLayoutManager().defaultLineHeight(for: font)
        origin = NSPoint(x: 0, y: typeset - natural)
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = lineHeight * natural / typeset
        storage = NSTextStorage(string: written, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: style,
        ])
        super.init(frame: .zero)
        // Flush with the labels above it: a label's text starts at its
        // alignment edge, and so does this, with no fragment padding.
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityValue(written)
        // Hug like the label it replaces, so a card squared up to a taller
        // one leaves the slack to the stack, not to the text.
        setContentHuggingPriority(.defaultHigh, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Decoration: the card takes the click.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        layoutManager.ensureLayout(for: container)
        return NSSize(width: NSView.noIntrinsicMetric,
                      height: ceil(layoutManager.usedRect(for: container).height))
    }

    override func layout() {
        super.layout()
        // The height follows the width the column hands down, as a wrapping
        // label's does.
        guard bounds.width > 1, abs(container.size.width - bounds.width) > 0.5 else { return }
        container.size = NSSize(width: bounds.width, height: .greatestFiniteMagnitude)
        invalidateIntrinsicContentSize()
    }

    /// The changed letters take their hue's ink over its wash: a lone comma
    /// is a small thing to find, and the colour is what makes it one.
    private func recolor() {
        let all = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: color, range: all)
        if showsChanges {
            for mark in diff.marks where mark.kind != .lineBreaks {
                storage.addAttribute(.foregroundColor, value: mark.kind.hue.ink, range: mark.range)
            }
        }
        storage.endEditing()
    }

    override func draw(_ dirtyRect: NSRect) {
        if showsChanges { drawWashes() }
        layoutManager.drawGlyphs(forGlyphRange: layoutManager.glyphRange(for: container), at: origin)
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    private var radius: CGFloat { Theme.m(4) }

    private func drawWashes() {
        for mark in diff.marks {
            let glyphs = layoutManager.glyphRange(forCharacterRange: mark.range, actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            if mark.kind == .lineBreaks {
                drawBreak(glyphs, mark.kind.hue)
                continue
            }
            for box in boxes(for: glyphs) { fillWash(box, mark.kind.hue) }
        }
    }

    /// The hue's wash, laid on twice. Theme's washes are tuned for a tile on
    /// a white card; behind a lone comma on the well's grey, once is nearly
    /// nothing.
    private func fillWash(_ box: NSRect, _ hue: Theme.Hue) {
        let path = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)
        hue.wash.setFill()
        path.fill()
        path.fill()
    }

    /// The letters' own band on a line — cap height to descender, a little
    /// proud of the glyphs. The line's full height carries the 1.3 spacing,
    /// and a wash that tall would touch the one on the next line.
    private func band(baseline: CGFloat) -> (top: CGFloat, height: CGFloat) {
        let above = font.capHeight + 3, below = -font.descender + 1
        return (baseline - above, above + below)
    }

    /// One box per line the range crosses.
    private func boxes(for glyphs: NSRange) -> [NSRect] {
        var out: [NSRect] = []
        var index = glyphs.location
        while index < NSMaxRange(glyphs) {
            var line = NSRange()
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: index, effectiveRange: &line)
            let piece = NSIntersectionRange(line, glyphs)
            guard piece.length > 0 else { break }
            let ink = layoutManager.boundingRect(forGlyphRange: piece, in: container)
            let baseline = origin.y + fragment.minY + layoutManager.location(forGlyphAt: piece.location).y
            let (top, height) = band(baseline: baseline)
            // A comma or a full stop is narrower than its box wants to be.
            let pad: CGFloat = 2
            let width = max(ink.width + pad * 2, font.pointSize * 0.75)
            out.append(NSRect(x: ink.midX - width / 2, y: top, width: width, height: height))
            index = NSMaxRange(line)
        }
        return out
    }

    /// A line break can't be washed — it has no ink — so it gets a return
    /// sign at the end of the line it closed, where you'd have pressed the
    /// key. When the line is full to the edge, the sign goes on the blank
    /// line the break opened instead.
    private func drawBreak(_ glyphs: NSRange, _ hue: Theme.Hue) {
        let first = glyphs.location
        guard first > 0 else { return }
        let before = layoutManager.boundingRect(forGlyphRange: NSRange(location: first - 1, length: 1), in: container)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: first - 1, effectiveRange: nil)
        var baseline = origin.y + fragment.minY + layoutManager.location(forGlyphAt: first - 1).y
        let width = (font.pointSize * 1.3).rounded()
        var x = before.maxX + 3
        if x + width > bounds.width, glyphs.length > 1 {
            let blank = layoutManager.lineFragmentRect(forGlyphAt: first + 1, effectiveRange: nil)
            baseline = origin.y + blank.minY + layoutManager.location(forGlyphAt: first + 1).y
            x = 0
        }
        x = max(0, min(x, bounds.width - width))
        let (top, height) = band(baseline: baseline)
        let box = NSRect(x: x, y: top, width: width, height: height)
        fillWash(box, hue)

        guard let symbol = Theme.symbol("return", (font.pointSize * 0.72).rounded(), .semibold) else { return }
        let size = symbol.size
        let r = backingAlignedRect(
            NSRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height),
            options: [.alignMinXNearest, .alignMinYNearest, .alignWidthNearest, .alignHeightNearest])
        let tint = hue.ink
        NSImage(size: size, flipped: false) { rect in
            symbol.draw(in: rect)
            tint.set()
            rect.fill(using: .sourceAtop)
            return true
        }.draw(in: r)
    }

    // MARK: The legend

    /// The key under the sample: a dot and a name for each kind present,
    /// and the words that went, struck through. One wrapping line of text
    /// rather than a row of views, so a long list of cuts (Terse drops a
    /// whole clause) wraps like the sentence it is.
    static func legend(for diff: ToneDiff, size: CGFloat = 11.5) -> NSAttributedString {
        let labelFont = NSFont.systemFont(ofSize: Theme.m(size))
        let dotFont = NSFont.systemFont(ofSize: Theme.m(size * 0.62))
        let wordFont = Theme.saidFont(size)
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.3
        let out = NSMutableAttributedString()
        func add(_ s: String, _ attrs: [NSAttributedString.Key: Any]) {
            var a = attrs
            a[.paragraphStyle] = style
            out.append(NSAttributedString(string: s, attributes: a))
        }
        // Centre the smaller dot on the label's x-height.
        let lift = (labelFont.xHeight - dotFont.xHeight) / 2
        for (i, kind) in diff.kinds.enumerated() {
            // An en and a thin space between items, a no-break space inside
            // one, so a dot never wraps away from its name.
            if i > 0 { add("\u{2002}\u{2009}", [.font: labelFont]) }
            add("●", [.font: dotFont, .foregroundColor: kind.hue.ink, .baselineOffset: lift])
            add("\u{00A0}" + kind.label, [.font: labelFont, .foregroundColor: Theme.muted])
            guard kind == .removed else { continue }
            let struck: [NSAttributedString.Key: Any] = [
                .font: wordFont, .foregroundColor: Theme.ink2,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: kind.hue.ink,
            ]
            let kept: [NSAttributedString.Key: Any] = [.font: wordFont, .foregroundColor: Theme.muted]
            for (k, cut) in diff.cuts.enumerated() {
                // Glued to what comes before, so a line never ends on a
                // separator. A short cut holds together ("and then" never
                // splits across lines); a whole dropped clause wraps like the
                // words it is.
                add(k == 0 ? "\u{00A0}\u{00A0}" : "\u{00A0}·\u{00A0}", [.font: labelFont, .foregroundColor: Theme.faint])
                let short = cut.words.split(separator: " ").count <= 3
                let words = short ? cut.words.replacingOccurrences(of: " ", with: "\u{00A0}") : cut.words
                if let echo = cut.echo, cut.echoFirst { add(echo + "\u{00A0}", kept) }
                add(words, struck)
                if let echo = cut.echo, !cut.echoFirst { add("\u{00A0}" + echo, kept) }
            }
        }
        return out
    }
}
