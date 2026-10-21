// Settings › Plan's own pieces: where your plan stands, the card across
// the top that says so, and the table that puts Free against Pro.
// design/settings-redesign.html is the picture these are drawn from.
import Cocoa

// MARK: - Where you stand

/// The account as the Plan page draws it. Free splits three ways because
/// the card changes with how much of the week is left: plenty, nearly
/// gone, gone.
enum PlanState {
    case signedOut
    case free(used: Int, limit: Int)
    case low(used: Int, limit: Int)
    case out(limit: Int)
    case pro(renews: Date?)
    case ending(Date)

    static var current: PlanState {
        if Account.available && !Account.signedIn { return .signedOut }
        if Account.plan == "pro" {
            if let end = Cloud.shared.subscription?.endsAt { return .ending(end) }
            return .pro(renews: Cloud.shared.subscription?.renewsAt)
        }
        let limit = Account.usage?.words.limit ?? Account.freeWordsPerWeek
        let used = min(Account.usage?.words.used ?? 0, limit)
        if used >= limit { return .out(limit: limit) }
        if Double(used) / Double(max(1, limit)) >= 0.9 { return .low(used: used, limit: limit) }
        return .free(used: used, limit: limit)
    }

    var isPro: Bool {
        switch self { case .pro, .ending: return true; default: return false }
    }

    /// "Monday": the day the free week starts again.
    static var refillDay: String {
        guard let at = Account.usage?.resetsAt else { return "Monday" }
        let f = DateFormatter()
        f.dateFormat = "EEEE"
        return f.string(from: at)
    }
}

// MARK: - The card across the top

/// Your plan as the page's headline: its name big in the display face, a
/// line on where you stand, and on the right the one number that matters —
/// words this week, days of Pro left, or Unlimited. The card wears the
/// site's sky behind it: blue on Pro, amber when the week is nearly or
/// wholly used, red when Pro is cancelled. Dark mode keeps the glow and
/// drops the grid.
final class PlanHero: NSView {
    enum Tone { case plain, blue, amber, red }
    private let tone: Tone
    private let glows = [CAGradientLayer(), CAGradientLayer(), CAGradientLayer()]
    private let grid = CAShapeLayer()
    private let gridMask = CAGradientLayer()

    init(_ state: PlanState, actions: [NSView]) {
        switch state {
        case .pro: tone = .blue
        case .ending: tone = .red
        case .low, .out: tone = .amber
        default: tone = .plain
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(16)
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        for g in glows { layer?.addSublayer(g) }
        grid.fillColor = nil
        grid.lineWidth = 1
        gridMask.type = .radial
        gridMask.colors = [NSColor.black.cgColor, NSColor.black.withAlphaComponent(0).cgColor]
        gridMask.locations = [0.1, 1]
        grid.mask = gridMask
        layer?.addSublayer(grid)

        let fmt = { (d: Date) in Self.day.string(from: d) }
        let pro = Account.proDollarsPerMonth

        // Left: name, chip, the line on where you stand.
        let name = Theme.hero(state.isPro ? "Pro" : "Free", 44, 500, tracking: -0.05)
        var nameRow: [NSView] = [name]
        let sub: NSAttributedString
        switch state {
        case .signedOut:
            sub = Self.line("Sign in to dictate with the cloud: \(Account.grouped(Account.freeWordsPerWeek)) words a week, free.")
        case .free(_, let limit):
            sub = Self.line("\(Account.grouped(limit)) cloud words a week, cleaned up as you go. Commands, spoken controls and Ask AI come with Pro.")
        case .low(let used, let limit):
            sub = Self.line("\(Account.grouped(limit - used)) words left this week. Pro never runs out, and adds commands and spoken controls.", bold: "\(Account.grouped(limit - used)) words left this week.")
        case .out(let limit):
            nameRow.append(GrantChip("Words used up", .warn))
            sub = Cloud.shared.graceLeft > 0
                ? Self.line("You’ve used this week’s \(Account.grouped(limit)) words. A few more takes are on us: they’re typed when you let go, without live words. Then dictation pauses until \(PlanState.refillDay).")
                : Self.line("You’ve used this week’s \(Account.grouped(limit)) cloud words. They refill \(PlanState.refillDay).")
        case .pro(let renews):
            nameRow.append(GrantChip("Active", .ok))
            sub = Self.line("Unlimited dictation, commands and spoken controls. "
                + (renews.map { "Renews \(fmt($0)) for $\(pro), billed by Paddle." } ?? "$\(pro) a month, billed by Paddle."))
        case .ending(let end):
            nameRow.append(GrantChip("Cancelled", .bad))
            sub = Self.line("Pro stays on until \(fmt(end)), then you’re on Free. You won’t be charged again.",
                            danger: fmt(end))
        }
        let nameLine = Theme.hstack(nameRow, spacing: Theme.m(10))
        nameLine.alignment = .centerY
        let subField = NSTextField(labelWithAttributedString: sub)
        subField.maximumNumberOfLines = 3
        subField.lineBreakMode = .byWordWrapping
        subField.preferredMaxLayoutWidth = Theme.m(380)
        subField.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        let left = Theme.vstack([nameLine, subField], spacing: Theme.m(6))
        left.alignment = .leading

        // Right: the number.
        let right = Self.figureColumn(state)

        let caps = RowGroup.caps("Your plan")
        let top = NSView()
        for v in [left, right] { v.translatesAutoresizingMaskIntoConstraints = false; top.addSubview(v) }
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: top.leadingAnchor),
            left.topAnchor.constraint(equalTo: top.topAnchor),
            left.bottomAnchor.constraint(lessThanOrEqualTo: top.bottomAnchor),
            left.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -Theme.m(24)),
            right.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            right.bottomAnchor.constraint(equalTo: top.bottomAnchor),
            right.topAnchor.constraint(greaterThanOrEqualTo: top.topAnchor),
            right.widthAnchor.constraint(equalToConstant: Theme.m(250)),
            top.heightAnchor.constraint(greaterThanOrEqualTo: left.heightAnchor),
        ])
        let buttons = Theme.hstack(actions, spacing: Theme.m(8))
        let column = Theme.vstack([caps, top, buttons], spacing: Theme.m(8))
        column.alignment = .leading
        column.setCustomSpacing(Theme.m(18), after: top)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        let pad = Theme.m(22)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.m(20)),
            top.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    /// The line under the name, with one phrase in bold or in red.
    private static func line(_ s: String, bold: String? = nil, danger: String? = nil) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = 1.15
        let font = NSFont.systemFont(ofSize: Theme.m(13.5))
        let out = NSMutableAttributedString(string: s, attributes: [.font: font, .foregroundColor: Theme.ink2, .paragraphStyle: para])
        if let b = bold, let r = s.range(of: b) {
            out.addAttributes([.font: NSFont.systemFont(ofSize: Theme.m(13.5), weight: .semibold), .foregroundColor: Theme.ink],
                              range: NSRange(r, in: s))
        }
        if let d = danger, let r = s.range(of: d) {
            out.addAttributes([.font: NSFont.systemFont(ofSize: Theme.m(13.5), weight: .semibold), .foregroundColor: Theme.danger],
                              range: NSRange(r, in: s))
        }
        return out
    }

    /// A big figure with its small words after it: "1,640 of 2,000 this week".
    private static func figure(_ value: String, _ words: String, countUp: Bool = true) -> NSView {
        let big = Theme.hero(value, 32, 500, tracking: -0.045)
        if countUp { big.identifier = Motion.countUpID }
        let small = Theme.text(words, 12.5, .regular, Theme.muted)
        small.font = .systemFont(ofSize: Theme.m(12.5))
        let row = Theme.hstack([big, small], spacing: Theme.m(5))
        row.alignment = .firstBaseline
        return row
    }

    /// Two small words at either end, under the bar: "This week · Refills Monday".
    private static func ends(_ l: String, _ r: String) -> NSView {
        let a = Theme.text(l, 11.5, .regular, Theme.muted), b = Theme.text(r, 11.5, .regular, Theme.muted)
        a.font = .systemFont(ofSize: Theme.m(11.5)); b.font = .systemFont(ofSize: Theme.m(11.5))
        return Theme.hstack([a, Theme.spacer(), b], spacing: 4)
    }

    private static func figureColumn(_ state: PlanState) -> NSView {
        var rows: [NSView]
        switch state {
        case .signedOut:
            rows = [figure(Account.grouped(Account.freeWordsPerWeek), "words a week, free", countUp: false)]
        case .free(let used, let limit), .low(let used, let limit):
            let low: Bool = { if case .low = state { return true }; return false }()
            rows = [figure(Account.grouped(used), "of \(Account.grouped(limit)) this week"),
                    PlanBar(Double(used) / Double(max(1, limit)), color: low ? Theme.danger : Theme.moss),
                    ends("This week", "Refills \(PlanState.refillDay)")]
        case .out(let limit):
            if let g = Cloud.shared.usage?.grace, g.limit > 0, Cloud.shared.graceLeft > 0 {
                // The extra takes, one tick each, the ones still left lit.
                let left = Cloud.shared.graceLeft
                let until = g.endsAt.map { Calendar.current.isDateInToday($0) ? "Until tonight" : "Until tomorrow" } ?? "For a day"
                rows = [figure("\(left)", left == 1 ? "extra take left" : "extra takes left"),
                        TickStrip(total: g.limit, left: left, color: Theme.amber),
                        ends(until, "Refills \(PlanState.refillDay)")]
            } else {
                rows = [figure(Account.grouped(limit), "of \(Account.grouped(limit)) this week"),
                        PlanBar(1, color: Theme.amber),
                        ends("Used up", "Refills \(PlanState.refillDay)")]
            }
        case .pro:
            let inf = GlyphView(symbol: "infinity", size: Theme.m(22), weight: .medium, side: Theme.m(30))
            inf.tint = Theme.ink
            let word = Theme.hero("Unlimited", 30, 500, tracking: -0.045)
            let line = Theme.hstack([Theme.spacer(), inf, word], spacing: Theme.m(6))
            line.alignment = .centerY
            let note = Theme.text("No meter to watch", 11.5, .regular, Theme.muted)
            note.font = .systemFont(ofSize: Theme.m(11.5))
            rows = [line, Theme.hstack([Theme.spacer(), note], spacing: 0)]
        case .ending(let end):
            let cal = Calendar.current
            let left = max(0, cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: end)).day ?? 0)
            let start = cal.date(byAdding: .month, value: -1, to: end) ?? end
            let total = max(left, cal.dateComponents([.day], from: start, to: end).day ?? 30)
            rows = [figure("\(left)", left == 1 ? "day of Pro left" : "days of Pro left"),
                    TickStrip(total: total, left: left, color: Theme.danger),
                    ends("Today", "Ends \(day.string(from: end))")]
        }
        let col = Theme.vstack(rows, spacing: Theme.m(10))
        col.alignment = .leading
        for r in rows { r.translatesAutoresizingMaskIntoConstraints = false; r.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true }
        if rows.count > 2 { col.setCustomSpacing(Theme.m(7), after: rows[1]) }
        return col
    }

    // Glow colours, light then dark, per tone: the site's hero sky.
    private static func sky(_ tone: Tone) -> [NSColor] {
        func c(_ l: UInt32, _ la: CGFloat, _ d: UInt32, _ da: CGFloat) -> NSColor { Theme.dyn(Theme.hex(l, la), Theme.hex(d, da)) }
        switch tone {
        case .blue:  return [c(0x7AA8FF, 0.42, 0x608AF0, 0.26), c(0xA8C6FF, 0.34, 0x4064C8, 0.16), c(0xE2ECFF, 0.7, 0x162658, 0.30)]
        case .red:   return [c(0xFF7864, 0.30, 0xFF5A46, 0.22), c(0xFFAA96, 0.22, 0xC83C32, 0.14), c(0xFFECE6, 0.8, 0x501412, 0.32)]
        case .amber: return [c(0xFFBE5A, 0.32, 0xF0AA3C, 0.20), c(0xFFD696, 0.24, 0xC88228, 0.12), c(0xFFF4E0, 0.8, 0x462C0C, 0.30)]
        case .plain: return [.clear, .clear, Theme.hairsoft]
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Unit space has y up: 1 is the card's top edge.
        let b = bounds
        glows[0].type = .radial
        glows[0].startPoint = CGPoint(x: 0.85, y: 1)
        glows[0].endPoint = CGPoint(x: 0.85 + 0.7, y: 1 - 0.9)
        glows[1].type = .radial
        glows[1].startPoint = CGPoint(x: 0.1, y: 1)
        glows[1].endPoint = CGPoint(x: 0.1 + 0.5, y: 1 - 0.7)
        glows[2].type = .axial
        glows[2].startPoint = CGPoint(x: 0.5, y: 1)
        glows[2].endPoint = CGPoint(x: 0.5, y: 0.15)
        for g in glows { g.frame = b }
        let path = CGMutablePath()
        let step = Theme.m(44)
        var x: CGFloat = 0
        while x <= b.width { path.move(to: CGPoint(x: x + 0.5, y: 0)); path.addLine(to: CGPoint(x: x + 0.5, y: b.height)); x += step }
        var y = b.height
        while y >= 0 { path.move(to: CGPoint(x: 0, y: y - 0.5)); path.addLine(to: CGPoint(x: b.width, y: y - 0.5)); y -= step }
        grid.path = path
        grid.frame = b
        gridMask.frame = b
        gridMask.startPoint = CGPoint(x: 0.8, y: 1)
        gridMask.endPoint = CGPoint(x: 0.8 + 0.7, y: 1 - 1.0)
        CATransaction.commit()
    }

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Theme.surface.cgColor
        layer?.borderColor = (tone == .red ? Theme.dangerRing : Theme.hairline).cgColor
        let sky = Self.sky(tone)
        for (i, g) in glows.enumerated() { g.colors = [sky[i].cgColor, sky[i].withAlphaComponent(0).cgColor] }
        glows[2].colors = [sky[2].cgColor, NSColor.clear.cgColor]
        grid.strokeColor = Theme.hairline.cgColor
        grid.opacity = 0.5
        grid.isHidden = isDark || tone == .plain
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: - Bars

/// A rounded bar, filled to a fraction. It fills from empty when its page
/// arrives (Motion.arrive grows it).
final class PlanBar: NSView, Growable {
    private let fraction: Double
    private let color: NSColor
    var grow: CGFloat = 1 { didSet { needsDisplay = true } }
    init(_ fraction: Double, color: NSColor) {
        self.fraction = max(0, min(1, fraction))
        self.color = color
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: Theme.m(8)).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.height / 2
        Theme.wellFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
        Theme.hairline.setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: r, yRadius: r).stroke()
        let w = bounds.width * CGFloat(fraction) * grow
        guard w > 0 else { return }
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: max(w, bounds.height), height: bounds.height), xRadius: r, yRadius: r).fill()
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// One tick per day of the paid month, the days still left lit: a
/// cancelled Pro's countdown. The ticks rise from the floor on arrival.
final class TickStrip: NSView, Growable {
    private let total: Int, left: Int
    private let color: NSColor
    var grow: CGFloat = 1 { didSet { needsDisplay = true } }
    init(total: Int, left: Int, color: NSColor) {
        self.total = max(1, total)
        self.left = left
        self.color = color
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: Theme.m(16)).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let gap: CGFloat = 2
        let w = (bounds.width - gap * CGFloat(total - 1)) / CGFloat(total)
        let gone = total - left
        for i in 0..<total {
            // Each tick a little after the one before it.
            let k = max(0, min(1, grow * 1.6 - CGFloat(i) / CGFloat(total) * 0.6))
            let h = bounds.height * k
            guard h > 0.5 else { continue }
            let rect = NSRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: h)
            (i < gone ? color.withAlphaComponent(0.18) : color.withAlphaComponent(0.85)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: min(3, w / 2), yRadius: min(3, w / 2)).fill()
        }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: - Free against Pro

/// The plans side by side as one table: a column per plan with its price
/// and its button on top, a line per thing you get. Pro's column is washed
/// ember from head to foot so the eye reads down it; what Free doesn't have
/// is crossed out rather than left blank. Seven lines and no headings — the
/// crosses are the comparison.
final class CompareTable: NSView {
    private typealias Line = (label: String, note: String, free: Cell, pro: Cell, pro_only: Bool)
    private enum Cell { case yes, no, text(String) }

    private static var lines: [Line] {
        [("Cloud dictation", "The best models. Words appear while you talk.",
          .text("\(Account.grouped(Account.freeWordsPerWeek)) words a week"), .text("Unlimited"), false),
         ("Auto cleanup and tones per app", "The ums go; Work sounds like work.", .yes, .yes, false),
         ("Dictionary and phrases", "", .yes, .yes, false),
         ("Command mode", "“make it a list”, “fix the grammar”", .no, .yes, true),
         ("Spoken controls", "Screenshots, files, links, terminal", .no, .yes, true),
         ("Ask ChatGPT, Claude, Grok or Perplexity", "Mid-sentence, without leaving the app", .no, .yes, true),
         ("Agent conversations", "Your coding agents report out loud; you answer by voice. Pro can add more, $1 per 100",
          .text("10 to try"), .text("300 a month"), false)]
    }

    private let wash = ColorView(color: CompareTable.washColor, radius: Theme.m(12))
    private static let washColor = Theme.dyn(Theme.hex(0xE5501F, 0.045), Theme.hex(0xFF6A3D, 0.06))
    private static var colWidth: CGFloat { Theme.m(170) }

    init(_ state: PlanState, free: (chip: GrantChip?, button: NSView), pro: (chip: GrantChip?, button: NSView)) {
        super.init(frame: .zero)
        let box = GroupBox()
        box.fill(self)
        wash.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        wash.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(wash)

        var rows: [NSView] = [head(free: free, pro: pro)]
        for (i, l) in Self.lines.enumerated() {
            rows.append(line(l, rule: i > 0))
        }
        let stack = Theme.vstack(rows, spacing: 0)
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        let inset = Theme.m(6)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -inset),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -inset),
            wash.topAnchor.constraint(equalTo: box.topAnchor, constant: inset),
            wash.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -inset),
            wash.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            wash.widthAnchor.constraint(equalToConstant: Self.colWidth),
        ])
        for r in rows { r.translatesAutoresizingMaskIntoConstraints = false; r.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Label on the left, the two plan cells pinned to the right.
    private func three(_ left: NSView, _ free: NSView, _ pro: NSView, top: CGFloat, bottom: CGFloat,
                       rule: Bool, align: NSLayoutConstraint.Attribute = .top) -> NSView {
        let row = NSView()
        if rule {
            let line = ColorView(color: Theme.hairsoft)
            line.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(line)
            NSLayoutConstraint.activate([
                line.topAnchor.constraint(equalTo: row.topAnchor),
                line.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: Theme.m(8)),
                line.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                line.heightAnchor.constraint(equalToConstant: 1),
            ])
        }
        let pad = Theme.m(14)
        let w = Self.colWidth
        for v in [left, free, pro] { v.translatesAutoresizingMaskIntoConstraints = false; row.addSubview(v) }
        var c: [NSLayoutConstraint] = [
            left.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: pad),
            left.trailingAnchor.constraint(lessThanOrEqualTo: free.leadingAnchor, constant: -pad),
            free.leadingAnchor.constraint(equalTo: row.trailingAnchor, constant: -2 * w + pad),
            free.widthAnchor.constraint(equalToConstant: w - 2 * pad),
            pro.leadingAnchor.constraint(equalTo: row.trailingAnchor, constant: -w + pad),
            pro.widthAnchor.constraint(equalToConstant: w - 2 * pad),
        ]
        for v in [left, free, pro] {
            c.append(v.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: top))
            c.append(v.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor, constant: -bottom))
            let pin = align == .bottom ? v.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -bottom)
                                       : v.topAnchor.constraint(equalTo: row.topAnchor, constant: top)
            pin.priority = .defaultHigh
            c.append(pin)
        }
        NSLayoutConstraint.activate(c)
        return row
    }

    private func head(free: (chip: GrantChip?, button: NSView), pro: (chip: GrantChip?, button: NSView)) -> NSView {
        func col(_ name: String, _ price: String, _ h: (chip: GrantChip?, button: NSView)) -> NSView {
            var top: [NSView] = [Theme.hero(name, 16, 500, tracking: -0.02)]
            if let chip = h.chip { top.append(chip) }
            let nameRow = Theme.hstack(top, spacing: Theme.m(7))
            nameRow.alignment = .centerY
            nameRow.heightAnchor.constraint(equalToConstant: Theme.m(22)).isActive = true
            let per = Theme.text("/ month", 12, .regular, Theme.muted)
            per.font = .systemFont(ofSize: Theme.m(12))
            let priceRow = Theme.hstack([Theme.hero(price, 26, 500, tracking: -0.04), per], spacing: Theme.m(4))
            priceRow.alignment = .firstBaseline
            let v = Theme.vstack([nameRow, priceRow, h.button], spacing: Theme.m(6))
            v.alignment = .leading
            v.setCustomSpacing(Theme.m(10), after: priceRow)
            h.button.translatesAutoresizingMaskIntoConstraints = false
            h.button.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
            return v
        }
        let label = RowGroup.caps("What you get")
        let row = three(label, col("Free", "$0", free), col("Pro", "$\(Account.proDollarsPerMonth)", pro),
                        top: Theme.m(16), bottom: Theme.m(14), rule: false, align: .bottom)
        let line = ColorView(color: Theme.hairline)
        line.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(line)
        NSLayoutConstraint.activate([
            line.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
        return row
    }

    private func line(_ l: Line, rule: Bool) -> NSView {
        let title = Theme.text(l.label, 13, .medium, Theme.ink)
        title.font = .systemFont(ofSize: Theme.m(13), weight: .medium)
        var titleRow: [NSView] = [title]
        if l.pro_only { titleRow.append(ProTag()) }
        let tr = Theme.hstack(titleRow, spacing: Theme.m(7))
        tr.alignment = .centerY
        var left: [NSView] = [tr]
        if !l.note.isEmpty {
            let note = Theme.text(l.note, 12, .regular, Theme.muted)
            note.font = .systemFont(ofSize: Theme.m(12))
            left.append(note)
        }
        let leftCol = Theme.vstack(left, spacing: Theme.m(2))
        leftCol.alignment = .leading
        return three(leftCol, cell(l.free, pro: false), cell(l.pro, pro: true),
                     top: Theme.m(11), bottom: Theme.m(11), rule: rule)
    }

    private func cell(_ c: Cell, pro: Bool) -> NSView {
        switch c {
        case .yes:
            let g = GlyphView(symbol: "checkmark", size: Theme.m(11), weight: .bold, side: Theme.m(16))
            g.tint = pro ? Theme.emberInk : Theme.moss
            return Theme.hstack([g, Theme.spacer()], spacing: 0)
        case .no:
            let g = GlyphView(symbol: "xmark", size: Theme.m(9.5), weight: .bold, side: Theme.m(16))
            g.tint = Theme.faint
            let t = Theme.text("Not on Free", 12.5, .regular, Theme.faint)
            t.font = .systemFont(ofSize: Theme.m(12.5))
            return Theme.hstack([g, t, Theme.spacer()], spacing: Theme.m(5))
        case .text(let s):
            let t = Theme.para(s, 12.5 * 1.2, .regular, Theme.ink2, lineHeight: 1.25)
            return t
        }
    }
}

/// The small ember "Pro" beside a line only Pro has. `quiet` is a grey
/// outline instead, for a tag that marks a whole tab (How it works), where
/// an ember one would read as something live.
final class ProTag: NSView {
    private let quiet: Bool
    /// The quiet tag's outline.
    private static let ring = Theme.dyn(Theme.hex(0x000000, 0.12), NSColor.white.withAlphaComponent(0.2))

    init(quiet: Bool = false) {
        self.quiet = quiet
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(8)
        layer?.borderWidth = quiet ? 1 : 0
        let f = Theme.text("Pro", 10, .semibold, quiet ? Theme.muted : Theme.emberInk)
        let font = NSFont.systemFont(ofSize: Theme.m(10), weight: .semibold)
        f.font = font
        if quiet {
            f.attributedStringValue = NSAttributedString(string: "Pro", attributes: [
                .font: font, .foregroundColor: Theme.muted, .kern: font.pointSize * 0.05])
        }
        f.translatesAutoresizingMaskIntoConstraints = false
        addSubview(f)
        NSLayoutConstraint.activate([
            f.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(quiet ? 7 : 6)),
            f.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.m(quiet ? 7 : 6)),
            f.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: Theme.m(quiet ? 17 : 16)),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        if quiet { layer?.cornerRadius = bounds.height / 2 }
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = (quiet ? NSColor.clear : Theme.emberSoft).cgColor
        layer?.borderColor = Self.ring.cgColor
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}
