// Insights — the last thirty days, plus the year in squares.
//
// Everything here counts from StatsStore — the per-day totals in stats.json,
// written once per clip and never pruned. history.json holds the transcripts
// and is capped, so counting from it meant a busy day read as zero as soon as
// it scrolled off the end of the list. Only "most used words" still reads the
// transcripts, because only they have the words.
//
// No range picker: it is always the last 30 days, plus the year in squares.
//
// Drawn in the refresh's language (design/sayctrl-refresh.html), as a sibling
// of the Overview: figures in New York, every chart a level meter of ink
// segments, and ember spent on one thing only — today. The charts are the
// pane's pictures, so they are kept quiet: the unlit segments are a
// whisper, the data is the only thing with weight.
import Cocoa

// MARK: - Level meter pieces

/// The segment sizes every meter here shares with the Overview's week: 5 by
/// 3 mockup pixels, corner 2. Kept in one place so the three charts on this
/// pane read as one instrument.
private enum Meter {
    static var segH: CGFloat { Theme.m(5) }
    static var segGap: CGFloat { Theme.m(3) }
    /// Part of a column, while a page's entrance fills it.
    static func grown(_ lit: Int, _ grow: CGFloat) -> Int {
        grow >= 1 ? lit : Int((CGFloat(lit) * grow).rounded(.up))
    }
    static func stackH(_ n: Int) -> CGFloat { CGFloat(n) * segH + CGFloat(n - 1) * segGap }

    /// How many of `n` segments a value lights. Rounded to the nearest, but
    /// anything above zero lights at least one — a quiet day isn't an empty one.
    static func lit(_ value: Int, of top: Int, _ n: Int) -> Int {
        guard value > 0 else { return 0 }
        return max(1, Int((CGFloat(value) / CGFloat(max(1, top)) * CGFloat(n)).rounded()))
    }

    /// How much of the unlit fill an unlit segment wears. Thirty columns of
    /// full-strength ghosts read as a grey wall with the data lost in it;
    /// at a little over half they are a texture the lit ones stand on.
    static let ghost: CGFloat = 0.55

    /// Fills a segment in the unlit colour, at the ghost's strength.
    static func fillGhost(_ path: NSBezierPath) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.saveGState()
        cg.setAlpha(ghost)
        Theme.barFill.setFill()
        path.fill()
        cg.restoreGState()
    }

    /// A column of `n` segments standing on `floor` (flipped coordinates).
    static func column(x: CGFloat, width: CGFloat, floor: CGFloat, n: Int, lit: Int, today: Bool) {
        for s in 0..<n {
            let y = floor - CGFloat(s + 1) * segH - CGFloat(s) * segGap
            let seg = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: segH),
                                   xRadius: 2, yRadius: 2)
            guard s < lit else { fillGhost(seg); continue }
            (today ? Theme.ember : Theme.barLit).setFill()
            seg.fill()
        }
    }

    /// The charts' numbers and hours: tabular SF digits, never the
    /// typewriter face — monospace is for code, and this is a date.
    static func digits(_ v: CGFloat, _ w: NSFont.Weight = .regular) -> NSFont {
        Theme.digits(v, w)
    }
}

// MARK: - The thirty days

/// One column of segments per day for minutes, with the word count riding
/// over the top as a thin ink line — so one chart answers both questions.
/// A faint grid at nothing, half and the busiest day carries the scale.
final class DayChart: TipView, Growable {
    /// 0 empty, 1 the real value: the page's entrance fills it.
    var grow: CGFloat = 1 { didSet { needsDisplay = true } }
    struct Day { let date: Date; let minutes: Int; let words: Int }
    var days: [Day] = [] { didSet { rebuildTips(); needsDisplay = true } }

    static let segments = 16
    override var isFlipped: Bool { true }

    private var topPad: CGFloat { Theme.m(7) }
    private var floorY: CGFloat { topPad + Meter.stackH(Self.segments) }
    private var axisH: CGFloat { Theme.m(8) + Theme.m(13) }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: floorY + axisH)
    }

    private var topMinutes: Int { max(1, days.map { $0.minutes }.max() ?? 1) }

    private func scaleLabel(_ minutes: Int) -> NSAttributedString {
        NSAttributedString(string: minutes == 0 ? "0" : Insights.hhmm(minutes), attributes: [
            .font: Meter.digits(10.5), .foregroundColor: Theme.faint,
        ])
    }

    /// Room on the left for the scale, as wide as its longest label.
    private var gutter: CGFloat { scaleLabel(topMinutes).size().width + Theme.m(10) }

    private func slot(_ i: Int) -> NSRect {
        let n = max(1, days.count)
        let gap = Theme.m(5)
        let x0 = gutter
        let w = (bounds.width - x0 - gap * CGFloat(n - 1)) / CGFloat(n)
        return NSRect(x: x0 + CGFloat(i) * (w + gap), y: 0, width: w, height: bounds.height)
    }

    private func rebuildTips() {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE d MMM"
        setTips(days.enumerated().map { i, d in
            (slot(i), d.minutes == 0
                ? "\(fmt.string(from: d.date)) — nothing dictated"
                : "\(fmt.string(from: d.date)) — \(Insights.hhmm(d.minutes)), \(Insights.number(d.words)) words")
        })
    }
    override func layout() { super.layout(); rebuildTips() }

    override func draw(_ dirtyRect: NSRect) {
        guard !days.isEmpty else { return }
        let n = Self.segments
        let topM = topMinutes
        let topW = CGFloat(max(1, days.map { $0.words }.max() ?? 1))
        let step = Meter.segH + Meter.segGap

        // The grid runs through the gaps between segment rows, so it never
        // cuts a segment: the floor, halfway, and the busiest day's top. A
        // scale with nothing on it, or too little to halve, names each value
        // once.
        let spoke = days.contains { $0.minutes > 0 }
        var named: Set<Int> = []
        for level in [0, n / 2, n] {
            let y = (floorY - CGFloat(level) * step + Meter.segGap / 2).rounded() - 0.5
            Theme.hairsoft.setFill()
            NSRect(x: gutter - Theme.m(4), y: y, width: bounds.width - gutter + Theme.m(4), height: 1).fill()
            let minutes = !spoke ? 0 : level == n ? topM : level == 0 ? 0 : Int((Double(topM) / 2).rounded())
            guard named.insert(minutes).inserted else { continue }
            let label = scaleLabel(minutes)
            let size = label.size()
            label.draw(at: NSPoint(x: gutter - Theme.m(10) - size.width + Theme.m(2), y: y - size.height / 2))
        }

        // Columns — minutes. Today's lit segments are the only ember here.
        for (i, d) in days.enumerated() {
            let s = slot(i)
            let w = min(s.width, Theme.m(40))
            Meter.column(x: s.midX - w / 2, width: w, floor: floorY, n: n,
                         lit: Meter.grown(Meter.lit(d.minutes, of: topM, n), grow), today: i == days.count - 1)
        }

        // Line — words, over the top. A casing in the card's own surface
        // lifts it off the lit segments it crosses. No words, no line: a
        // flat rule along the floor would read as a reading of zero.
        guard days.contains(where: { $0.words > 0 }) else { return drawAxis() }
        let points = days.enumerated().map { i, d in
            NSPoint(x: slot(i).midX, y: min(floorY - 1, floorY - Meter.stackH(n) * CGFloat(d.words) / topW))
        }
        let line = Self.smooth(points)
        line.lineJoinStyle = .round
        line.lineCapStyle = .round
        Theme.surface.withAlphaComponent(grow).setStroke()
        line.lineWidth = Theme.m(3.5)
        line.stroke()
        Theme.ink2.withAlphaComponent(grow).setStroke()
        line.lineWidth = 1.25
        line.stroke()
        drawAxis()
    }

    /// A curve through every point that never swings past its neighbours
    /// (monotone cubic, Fritsch–Carlson). Thirty straight segments made a
    /// saw blade over the columns; a spline that overshoots would draw a
    /// day as busier, or quieter, than it was.
    private static func smooth(_ p: [NSPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = p.first else { return path }
        path.move(to: first)
        guard p.count > 2 else { p.dropFirst().forEach { path.line(to: $0) }; return path }
        let n = p.count
        var slope = [CGFloat](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) { slope[i] = (p[i + 1].y - p[i].y) / max(0.001, p[i + 1].x - p[i].x) }
        var tangent = [CGFloat](repeating: 0, count: n)
        tangent[0] = slope[0]
        tangent[n - 1] = slope[n - 2]
        for i in 1..<(n - 1) {
            // A peak or a trough keeps a flat tangent, so the curve turns
            // on the day itself instead of beyond it.
            tangent[i] = slope[i - 1] * slope[i] <= 0 ? 0 : (slope[i - 1] + slope[i]) / 2
        }
        for i in 0..<(n - 1) where slope[i] != 0 {
            let a = tangent[i] / slope[i], b = tangent[i + 1] / slope[i]
            let h = a * a + b * b
            if h > 9 {
                let t = 3 / sqrt(h)
                tangent[i] = t * a * slope[i]
                tangent[i + 1] = t * b * slope[i]
            }
        }
        for i in 0..<(n - 1) {
            let dx = (p[i + 1].x - p[i].x) / 3
            path.curve(to: p[i + 1],
                       controlPoint1: NSPoint(x: p[i].x + dx, y: p[i].y + tangent[i] * dx),
                       controlPoint2: NSPoint(x: p[i + 1].x - dx, y: p[i + 1].y - tangent[i + 1] * dx))
        }
        return path
    }

    /// The date every fifth day, and today's in ember ink.
    private func drawAxis() {
        let last = days.count - 1
        let cal = Calendar.current
        for (i, d) in days.enumerated() where i == 0 || i == last || i % 5 == 0 {
            let text = NSAttributedString(string: "\(cal.component(.day, from: d.date))", attributes: [
                .font: Meter.digits(11), .foregroundColor: i == last ? Theme.emberInk : Theme.faint,
            ])
            let size = text.size()
            text.draw(at: NSPoint(x: slot(i).midX - size.width / 2, y: floorY + Theme.m(8)))
        }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// The day folded into twenty-four hours: the same thirty days as the rest of
/// the pane, one column per hour of the clock. It is the picture behind "around
/// 3pm", so every column is ink — nothing on it is live.
///
/// It stands in whatever height its card has left over, adding whole segments
/// rather than stretching them, so it always reads as the same meter.
final class HourChart: TipView, Growable {
    var grow: CGFloat = 1 { didSet { needsDisplay = true } }
    var minutes: [Int] = [] { didSet { rebuildTips(); needsDisplay = true } }

    static let fewestSegments = 8
    override var isFlipped: Bool { true }
    private var labelH: CGFloat { Theme.m(8) + Theme.m(13) }
    private var floorY: CGFloat { bounds.height - labelH }
    private var segments: Int {
        let step = Meter.segH + Meter.segGap
        return max(Self.fewestSegments, Int((floorY + Meter.segGap) / step))
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Meter.stackH(Self.fewestSegments) + labelH)
    }

    private func slot(_ h: Int) -> NSRect {
        let gap = Theme.m(3)
        let w = (bounds.width - gap * 23) / 24
        return NSRect(x: CGFloat(h) * (w + gap), y: 0, width: w, height: bounds.height)
    }

    private func rebuildTips() {
        setTips(minutes.enumerated().map { h, m in
            (slot(h), "\(Insights.hourLabel(h)) · \(m == 0 ? "nothing" : Insights.hhmm(m))")
        })
    }
    override func layout() { super.layout(); rebuildTips() }

    override func draw(_ dirtyRect: NSRect) {
        guard minutes.count == 24 else { return }
        let top = max(1, minutes.max() ?? 1)
        let n = segments
        for h in 0..<24 {
            let s = slot(h)
            Meter.column(x: s.minX, width: s.width, floor: floorY, n: n,
                         lit: Meter.grown(Meter.lit(minutes[h], of: top, n), grow), today: false)
        }
        for h in stride(from: 0, to: 24, by: 6) {
            let text = NSAttributedString(string: Insights.hourLabel(h), attributes: [
                .font: Meter.digits(11), .foregroundColor: Theme.faint,
            ])
            text.draw(at: NSPoint(x: slot(h).minX, y: floorY + Theme.m(8)))
        }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// One word's count as a meter lying on its side: the charts' segment,
/// drawn as one run rather than cut up — ten rows of tiny dashes read as
/// dotted rules, and the word beside them is the thing to read.
private final class SegmentBar: NSView {
    private let fraction: CGFloat
    init(fraction: Double) {
        self.fraction = CGFloat(max(0, min(1, fraction)))
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Meter.segH) }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.height / 2
        // The track runs the full width, so every bar in the list ends in
        // the same place; the lit run is never shorter than its own round
        // ends, so a rare word still shows.
        Meter.fillGhost(NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r))
        let w = max(bounds.height * 2, (bounds.width * fraction).rounded())
        Theme.barLit.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: bounds.height),
                     xRadius: r, yRadius: r).fill()
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: - The year

/// The GitHub-style year: 53 columns of 7 squares, one per day. The steps are
/// ink, the way a lit meter segment is; today is the one square in ember.
final class YearGrid: TipView {
    var levels: [(date: Date, minutes: Int)] = [] { didSet { rebuildTips(); needsDisplay = true } }
    private let cols = 53
    private var gap: CGFloat { Theme.m(3) }
    private var side: CGFloat { max(1, (bounds.width - gap * CGFloat(cols - 1)) / CGFloat(cols)) }
    private var measuredWidth: CGFloat = 0

    // The squares take their size from the width, so the height follows it.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric,
               height: bounds.width > 1 ? (7 * side + 6 * gap).rounded(.up) : Theme.m(104))
    }

    private func cell(_ w: Int, _ d: Int) -> NSRect {
        NSRect(x: CGFloat(w) * (side + gap),
               y: bounds.height - CGFloat(d + 1) * side - CGFloat(d) * gap,
               width: side, height: side)
    }

    private func rebuildTips() {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE d MMM"
        let today = Date()
        setTips(levels.enumerated().compactMap { i, item in
            guard item.date <= today else { return nil }
            return (cell(i / 7, i % 7), item.minutes > 0
                ? "\(fmt.string(from: item.date)) — \(Insights.hhmm(item.minutes))"
                : "\(fmt.string(from: item.date)) — nothing")
        })
    }
    override func layout() {
        super.layout()
        if abs(bounds.width - measuredWidth) > 0.5 {
            measuredWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
        rebuildTips()
    }

    /// Four ink steps over an unlit square, topping out at the lit segment.
    static func color(_ minutes: Int) -> NSColor {
        func ink(_ light: CGFloat, _ dark: CGFloat) -> NSColor {
            Theme.dyn(Theme.hex(0x1C1B19, light), NSColor.white.withAlphaComponent(dark))
        }
        switch minutes {
        case 0:       return Theme.barFill
        case 1..<8:   return ink(0.16, 0.18)
        case 8..<18:  return ink(0.30, 0.32)
        case 18..<30: return ink(0.44, 0.47)
        default:      return Theme.barLit
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let now = Date()
        let today = Calendar.current.startOfDay(for: now)
        for (i, item) in levels.enumerated() {
            guard item.date <= now else { continue }
            let r = cell(i / 7, i % 7)
            let isToday = Calendar.current.isDate(item.date, inSameDayAs: today)
            let square = NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2)
            // An empty day is a ghost, the way an unlit segment is: most of
            // a year is empty, and full-strength squares made it a wall.
            if item.minutes == 0 && !isToday { Meter.fillGhost(square); continue }
            (isToday && item.minutes > 0 ? Theme.ember : Self.color(item.minutes)).setFill()
            square.fill()
            // Nothing said yet today still marks where today is.
            if isToday && item.minutes == 0 {
                Theme.ember.setStroke()
                let p = NSBezierPath(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), xRadius: 2, yRadius: 2)
                p.lineWidth = 1.5
                p.stroke()
            }
        }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// The month names over the year grid, drawn at the column each month starts
/// in. A stack of 53 equal cells gave every label 19 points and clipped them
/// all to "J…".
final class MonthRow: NSView {
    /// (column, name) — one entry per month that starts in the year.
    var marks: [(week: Int, name: String)] = [] { didSet { needsDisplay = true } }
    private let cols = 53

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: Theme.m(13)) }

    override func draw(_ dirtyRect: NSRect) {
        let gap = Theme.m(3)
        let side = (bounds.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
        // The meter's own day labels: small caps-style, semibold, faint.
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: Theme.m(10.5), weight: .semibold),
            .foregroundColor: Theme.faint,
            .kern: Theme.m(10.5) * 0.05,
        ]
        var lastRight: CGFloat = -1
        for mark in marks {
            let x = CGFloat(mark.week) * (side + gap)
            let text = NSAttributedString(string: mark.name.uppercased(), attributes: attrs)
            let width = text.size().width
            // Skip a label that would run into the one before it.
            guard x > lastRight + Theme.m(4), x + width <= bounds.width else { continue }
            text.draw(at: NSPoint(x: x, y: 0))
            lastRight = x + width
        }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

// MARK: - The figure strip

/// The refresh's `.grp`: surface, one hairline, radius 12, no shadow — and no
/// padding of its own, so the rules between its sections run edge to edge.
private final class Group: NSView {
    init(_ views: [NSView]) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(12)
        layer?.borderWidth = 1
        let stack = Theme.vstack(views, spacing: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for v in views {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    static func rule() -> NSView {
        let r = ColorView(color: Theme.hairsoft)
        r.translatesAutoresizingMaskIntoConstraints = false
        r.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return r
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Theme.surface.cgColor
        layer?.borderColor = Theme.hairline.cgColor
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// One figure in the strip: the number in New York, what it counts under
/// it in plain muted text. A soft rule on its left when it has a neighbour
/// there.
private final class Figure: NSView {
    private let value: NSTextField

    init(_ v: String, _ label: String, rule: Bool) {
        value = Theme.figure(v, 30)
        value.identifier = Motion.countUpID
        super.init(frame: .zero)
        let column = Theme.vstack([value, Theme.text(label, 12.5 * 1.2, .regular, Theme.muted)],
                                  spacing: Theme.m(2))
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: Theme.m(18)),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(22)),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Theme.m(12)),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.m(16)),
        ])
        if rule {
            let r = ColorView(color: Theme.hairsoft)
            r.translatesAutoresizingMaskIntoConstraints = false
            addSubview(r)
            NSLayoutConstraint.activate([
                r.leadingAnchor.constraint(equalTo: leadingAnchor),
                r.topAnchor.constraint(equalTo: topAnchor),
                r.bottomAnchor.constraint(equalTo: bottomAnchor),
                r.widthAnchor.constraint(equalToConstant: 1),
            ])
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ v: String) { Theme.setDisplay(value, v) }
}

// MARK: - Spoken controls

/// One control's count: its picture in a quiet well, the number in the
/// figure face, what it counts under it. A control never used yet sits back
/// in faint ink, and its tooltip says what to say to use it.
private final class ControlTile: NSView {
    private let value = Theme.figure("0", 22)
    private let label = Theme.text("", 12 * 1.2, .regular, Theme.muted)
    private let well = ColorView(color: Theme.wellFill, radius: Theme.m(7))
    private let icon = NSImageView()

    init() {
        super.init(frame: .zero)
        icon.translatesAutoresizingMaskIntoConstraints = false
        well.translatesAutoresizingMaskIntoConstraints = false
        well.addSubview(icon)
        NSLayoutConstraint.activate([
            well.widthAnchor.constraint(equalToConstant: Theme.m(30)),
            well.heightAnchor.constraint(equalToConstant: Theme.m(30)),
            icon.centerXAnchor.constraint(equalTo: well.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: well.centerYAnchor),
        ])
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        let words = Theme.vstack([value, label], spacing: 0)
        let row = Theme.hstack([well, words], spacing: Theme.m(12))
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: Theme.m(10)),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.m(10)),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.m(8)),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ control: SpokenControl, count: Int) {
        let used = count > 0
        Theme.setDisplay(value, Insights.number(count))
        value.textColor = used ? Theme.ink : Theme.faint
        label.stringValue = control.title
        label.textColor = used ? Theme.muted : Theme.faint
        icon.image = Theme.symbol(control.symbol, Theme.m(13), .medium)
        icon.contentTintColor = used ? Theme.ink2 : Theme.faint
        toolTip = used ? "\(control.title): \(Insights.number(count)) — say \(control.example)"
                       : "Not used yet — say \(control.example)"
    }
}

// MARK: - Numbers

enum Insights {
    static func number(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
    static func hhmm(_ m: Int) -> String { m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m" }
    static func words(_ s: String) -> Int { s.split { $0.isWhitespace || $0.isNewline }.count }
    static func hourLabel(_ h: Int) -> String {
        h == 0 ? "midnight" : h == 12 ? "midday" : h < 12 ? "\(h)am" : "\(h - 12)pm"
    }
    static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    /// Words worth counting: skip the ones that carry no signal about you.
    static let stopwords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "if", "is", "are", "was", "were", "be", "been",
        "to", "of", "in", "on", "at", "for", "with", "from", "by", "as", "it", "its", "this",
        "that", "these", "those", "i", "you", "he", "she", "we", "they", "me", "him", "her",
        "us", "them", "my", "your", "our", "their", "so", "do", "does", "did", "have", "has",
        "had", "will", "would", "can", "could", "should", "not", "no", "yes", "up", "out",
        "about", "into", "then", "than", "there", "here", "what", "which", "who", "how",
    ]
}

// MARK: - The pane

final class InsightsPane: PaneView {

    private var figures: [Figure] = []
    private let chart = DayChart()
    private let hours = HourChart()
    private let peakLine = NSTextField(labelWithString: "")
    private let peakChips = FlowRow()
    private let wordList = NSStackView()
    private let year = YearGrid()
    private let months = MonthRow()
    private let streakN = Theme.figure("0", 30)
    private let streakL = Theme.text("", 13 * 1.2, .regular, Theme.muted)
    private let yearNote = Theme.meta("", 12, Theme.muted)
    private let controlTiles = SpokenControl.allCases.map { _ in ControlTile() }
    private let controlsNote = Theme.meta("", 12, Theme.muted)
    private let controlsEmpty = Theme.para("", 13)
    private let controlsPro = ProTag()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        streakN.identifier = Motion.countUpID
        build()
        reload()
        NotificationCenter.default.addObserver(self, selector: #selector(historyChanged),
                                               name: .owHistoryChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(historyChanged),
                                               name: ControlStats.changed, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    private func build() {
        let header = makePaneHeader("Insights")

        // The four figures and the chart they come from share one strip, the
        // way the Overview's week sits beside its number: all five are the
        // same thirty days.
        figures = [Figure("0m", "Time dictating", rule: false), Figure("0", "Words spoken", rule: true),
                   Figure("0", "Words per minute", rule: true), Figure("0/30", "Days used", rule: true)]
        let figureRow = NSStackView(views: figures)
        figureRow.orientation = .horizontal
        figureRow.distribution = .fillEqually
        figureRow.spacing = 0

        // Titled the way a Card is, so the strip's chart and the cards
        // under it read as one set of sections.
        let chartTitle = Theme.display("Last 30 days", 15, .medium, tracking: -0.005)
        let chartHead = Theme.hstack([chartTitle, Theme.spacer(),
                                      key(bar: true, "Minutes"), key(bar: false, "Words")],
                                     spacing: Theme.m(14))
        let meter = Theme.vstack([chartHead, chart], spacing: Theme.m(14))
        chartHead.widthAnchor.constraint(equalTo: meter.widthAnchor).isActive = true
        chart.widthAnchor.constraint(equalTo: meter.widthAnchor).isActive = true
        let strip = Group([figureRow, Group.rule(), padded(meter, top: 16, side: 22, bottom: 14)])

        let peak = Card("When you speak")
        peakLine.maximumNumberOfLines = 2
        peakLine.lineBreakMode = .byWordWrapping
        peakLine.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        // The pair of cards is as tall as the taller one. The slack goes to
        // the hour chart, so the sentence hangs at the top and the chart
        // stands on the card's floor, level with the word list beside it.
        peakLine.setContentHuggingPriority(.required, for: .vertical)
        peakChips.setContentHuggingPriority(.required, for: .vertical)
        hours.setContentHuggingPriority(.init(1), for: .vertical)
        peak.add(peakLine)
        peak.add(peakChips)
        peak.add(hours)

        let words = Card("Most used words")
        wordList.orientation = .vertical
        wordList.alignment = .leading
        wordList.spacing = 0
        words.add(wordList)
        // When this is the shorter card (nothing dictated yet), its slack
        // goes under the list rather than round it.
        let filler = NSView()
        filler.setContentHuggingPriority(.init(1), for: .vertical)
        words.add(filler)

        let pair = NSStackView(views: [peak, words])
        pair.orientation = .horizontal
        pair.distribution = .fillEqually
        pair.spacing = Theme.m(14)
        pair.alignment = .top
        peak.translatesAutoresizingMaskIntoConstraints = false
        peak.heightAnchor.constraint(equalTo: words.heightAnchor).isActive = true

        // The controls you say mid-sentence, and how often each has fired:
        // four to a row, the most used first.
        let controls = Card("Spoken controls")
        controls.addToHead(controlsPro)
        controls.addToHead(controlsNote)
        controlsEmpty.maximumNumberOfLines = 2
        controls.add(controlsEmpty)
        let perRow = 4
        var rows: [NSView] = []
        for start in stride(from: 0, to: controlTiles.count, by: perRow) {
            var cells: [NSView] = Array(controlTiles[start..<min(start + perRow, controlTiles.count)])
            while cells.count < perRow { cells.append(NSView()) }
            let row = NSStackView(views: cells)
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.spacing = Theme.m(12)
            rows.append(row)
        }
        let grid = Theme.vstack(rows, spacing: 0)
        for r in rows { r.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true }
        controls.add(grid)

        let yearCard = Card("Every day you've spoken")
        yearCard.addToHead(yearNote)
        let streak = Theme.hstack([streakN, streakL], spacing: Theme.m(8))
        streak.alignment = .firstBaseline
        yearCard.add(streak)
        yearCard.add(months)
        yearCard.add(year)
        yearCard.add(legend())

        makeCardScroll([header, strip, pair, controls, yearCard]).fill(self, inset: 0)
    }

    /// Pads a section inside a `Group` by mockup pixels.
    private func padded(_ view: NSView, top: CGFloat, side: CGFloat, bottom: CGFloat) -> NSView {
        let host = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor, constant: Theme.m(top)),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: Theme.m(side)),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -Theme.m(side)),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -Theme.m(bottom)),
        ])
        return host
    }

    /// The chart's legend: a lit segment for minutes, the ink line for words.
    private func key(bar: Bool, _ label: String) -> NSView {
        let swatch = ColorView(color: bar ? Theme.barLit : Theme.ink2, radius: bar ? 2 : 0.75)
        swatch.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            swatch.widthAnchor.constraint(equalToConstant: bar ? Theme.m(12) : Theme.m(14)),
            swatch.heightAnchor.constraint(equalToConstant: bar ? Meter.segH : 1.5),
        ])
        return Theme.hstack([swatch, Theme.text(label, 11.5 * 1.2, .regular, Theme.muted)], spacing: Theme.m(6))
    }

    private func legend() -> NSView {
        var parts: [NSView] = [Theme.text("Less", 11 * 1.2, .regular, Theme.faint)]
        for m in [0, 4, 12, 24, 40] {
            let cell = ColorView(color: YearGrid.color(m), radius: 2)
            // The empty step is the grid's ghost, so it wears the same strength.
            if m == 0 { cell.alphaValue = Meter.ghost }
            cell.translatesAutoresizingMaskIntoConstraints = false
            cell.widthAnchor.constraint(equalToConstant: Theme.m(10)).isActive = true
            cell.heightAnchor.constraint(equalToConstant: Theme.m(10)).isActive = true
            parts.append(cell)
        }
        parts.append(Theme.text("More", 11 * 1.2, .regular, Theme.faint))
        parts.append(Theme.spacer())
        return Theme.hstack(parts, spacing: Theme.m(4))
    }

    override func paneAppeared() { reload() }

    // MARK: Data

    /// Off-screen panes don't rebuild: history changes on every dictation.
    @objc private func historyChanged() { if window?.isVisible == true { reload() } }

    @objc private func reload() {
        let stats = StatsStore.shared
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        // Everything here counts from the daily totals rather than from the
        // transcripts. history.json is capped, so a busy day used to drop off
        // the end of it and read as zero the next morning.
        let window = stats.window(30)
        let windowStart = window.first?.date ?? today

        func minutes(_ seconds: Double) -> Int {
            seconds <= 0 ? 0 : max(1, Int((seconds / 60).rounded()))
        }

        // --- the four figures, over 30 days
        let totalSeconds = window.reduce(0.0) { $0 + $1.stat.seconds }
        let wordCount = window.reduce(0) { $0 + $1.stat.words }
        let active = window.filter { $0.stat.clips > 0 }.count
        let wpm = totalSeconds > 30 ? Int((Double(wordCount) / totalSeconds * 60).rounded()) : 0
        figures[0].set(Insights.hhmm(minutes(totalSeconds)))
        figures[1].set(Insights.number(wordCount))
        figures[2].set(Insights.number(wpm))
        figures[3].set("\(active)/30")

        // --- the chart
        chart.days = window.map {
            DayChart.Day(date: $0.date, minutes: minutes($0.stat.seconds), words: $0.stat.words)
        }

        // --- when you speak
        //
        // Seconds are added up first and turned into minutes at the very end.
        // Rounding every clip to whole minutes first put a 40-second dictation
        // down as zero, which is most of them — the busiest hour came out as
        // whichever hour happened to sort first.
        var secondsByHour = [Double](repeating: 0, count: 24)
        var secondsByDow = [Double](repeating: 0, count: 7)
        for day in window {
            for h in 0..<24 { secondsByHour[h] += day.stat.byHour[h] }
            secondsByDow[cal.component(.weekday, from: day.date) - 1] += day.stat.seconds
        }
        let bestDow = secondsByDow.indices.max { secondsByDow[$0] < secondsByDow[$1] } ?? 0
        let bestHour = secondsByHour.indices.max { secondsByHour[$0] < secondsByHour[$1] } ?? 0
        // Only weekdays you have actually spoken on can be the quiet one —
        // otherwise "quietest day" just names a day you have never used.
        let usedDows = secondsByDow.indices.filter { secondsByDow[$0] > 0 }
        let quietDow = usedDows.min { secondsByDow[$0] < secondsByDow[$1] } ?? bestDow
        let longest = window.map { $0.stat.seconds }.max() ?? 0

        // The app's own sentence, so the app's own face: display, with the
        // two answers in ink and a step heavier rather than in a colour.
        let sentence = NSMutableAttributedString()
        let size = Theme.m(17)
        func add(_ s: String, _ strong: Bool) {
            sentence.append(NSAttributedString(string: s, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: strong ? .medium : .regular),
                .foregroundColor: strong ? Theme.ink : Theme.ink2,
                .kern: size * -0.015,
            ]))
        }
        if totalSeconds == 0 {
            add("Nothing dictated in the last thirty days.", false)
        } else {
            add("You speak most on ", false)
            add("\(Insights.weekdays[bestDow])s", true)
            add(", around ", false)
            add(Insights.hourLabel(bestHour), true)
            add(".", false)
        }
        peakLine.attributedStringValue = sentence

        peakChips.set(totalSeconds == 0 ? [] : [
            Chip("busiest day", [String(Insights.weekdays[bestDow].prefix(3)),
                                 Insights.hhmm(minutes(secondsByDow[bestDow]))]),
            Chip("busiest hour", [Insights.hourLabel(bestHour),
                                  Insights.hhmm(minutes(secondsByHour[bestHour]))]),
            Chip("quietest day", [String(Insights.weekdays[quietDow].prefix(3)),
                                  Insights.hhmm(minutes(secondsByDow[quietDow]))]),
            Chip("longest day", [Insights.hhmm(minutes(longest))]),
        ])
        hours.minutes = secondsByHour.map { minutes($0) }
        hours.isHidden = totalSeconds == 0

        // --- most used words, over the same thirty days as everything else
        var counts: [String: Int] = [:]
        var spelling: [String: [String: Int]] = [:]
        for e in HistoryStore.shared.entries where e.date >= windowStart {
            for raw in e.text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
                let w = raw.trimmingCharacters(in: .punctuationCharacters)
                let key = w.lowercased()
                guard w.count > 2, !Insights.stopwords.contains(key) else { continue }
                counts[key, default: 0] += 1
                spelling[key, default: [:]][w, default: 0] += 1
            }
        }
        // Show the casing you actually use — "SayCtrl", not "sayctrl".
        let top = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(10)
            .map { (word: spelling[$0.key]?.max { $0.value < $1.value }?.key ?? $0.key, count: $0.value) }
        wordList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let peak = top.first?.count ?? 1
        if top.isEmpty {
            wordList.addArrangedSubview(Theme.text("Nothing dictated yet.", 13 * 1.2, .regular, Theme.muted))
        }
        for item in top {
            let row = wordRow(item.word, item.count, fraction: Double(item.count) / Double(peak))
            wordList.addArrangedSubview(row)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: wordList.widthAnchor).isActive = true
        }

        // --- spoken controls, most used first; ties keep the list's order
        let tally = ControlStats.shared
        let order = SpokenControl.allCases.enumerated()
            .sorted { a, b in
                let (x, y) = (tally.count(a.element), tally.count(b.element))
                return x == y ? a.offset < b.offset : x > y
            }
            .map { $0.element }
        for (tile, control) in zip(controlTiles, order) { tile.set(control, count: tally.count(control)) }
        let sinceFmt = DateFormatter()
        sinceFmt.dateFormat = "d MMM"
        controlsNote.stringValue = tally.total == 0 ? "" : "\(Insights.number(tally.total)) since \(sinceFmt.string(from: tally.since))"
        // On Free the controls are Pro's: the tag says why nothing counts.
        controlsPro.isHidden = Account.controlsFree
        controlsEmpty.stringValue = Account.controlsFree
            ? "Say these in the middle of a sentence — “take a screenshot”, “copy the link”, “open Claude” — and each one is counted here."
            : "Screenshots, links, files, opening apps and the rest come with Pro. Each one you use is counted here."
        controlsEmpty.isHidden = tally.total > 0

        // --- the year
        func day(_ back: Int) -> Date { cal.date(byAdding: .day, value: -back, to: today) ?? today }
        var start = day(364)
        // start on a Sunday so the columns read as weeks
        let shift = cal.component(.weekday, from: start) - 1
        start = cal.date(byAdding: .day, value: -shift, to: start) ?? start
        var cells: [(date: Date, minutes: Int)] = []
        var yearSeconds = 0.0, activeDays = 0
        for i in 0..<(53 * 7) {
            let d = cal.date(byAdding: .day, value: i, to: start) ?? start
            let secs = d <= today ? stats.stat(on: d).seconds : 0
            if d <= today {
                yearSeconds += secs
                if secs > 0 { activeDays += 1 }
            }
            cells.append((d, minutes(secs)))
        }
        year.levels = cells

        let mf = DateFormatter()
        mf.dateFormat = "MMM"
        var lastMonth = -1
        var marks: [(week: Int, name: String)] = []
        for w in 0..<53 {
            let first = cal.date(byAdding: .day, value: w * 7, to: start) ?? start
            let m = cal.component(.month, from: first)
            guard m != lastMonth, cal.component(.day, from: first) <= 7 else { continue }
            lastMonth = m
            marks.append((w, mf.string(from: first)))
        }
        months.marks = marks

        // The streak only breaks on a day that has passed: nothing said yet
        // today doesn't end a run that is still going.
        var current = 0
        var back = stats.stat(on: today).seconds > 0 ? 0 : 1
        while stats.stat(on: day(back)).seconds > 0 {
            current += 1
            back += 1
        }
        var best = 0, run = 0
        for i in stride(from: 400, through: 0, by: -1) {
            run = stats.stat(on: day(i)).seconds > 0 ? run + 1 : 0
            best = max(best, run)
        }
        Theme.setDisplay(streakN, "\(current)")
        streakL.stringValue = "day streak · longest \(best) · \(activeDays) days used this year"
        yearNote.stringValue = "\(Insights.hhmm(minutes(yearSeconds))) in the last year"
    }

    /// A word you said (so in the face every list sets your words in), its
    /// count as a meter on its side, and the count itself in faint digits.
    private func wordRow(_ word: String, _ n: Int, fraction: Double) -> NSView {
        let name = Theme.text(word, 13.5 * 1.2, .regular, Theme.ink)
        name.font = Theme.saidFont(13.5)
        name.translatesAutoresizingMaskIntoConstraints = false
        name.widthAnchor.constraint(equalToConstant: Theme.m(104)).isActive = true

        let bar = SegmentBar(fraction: fraction)
        bar.setContentHuggingPriority(.init(1), for: .horizontal)

        let count = Theme.meta(Insights.number(n), 11.5, Theme.faint)
        count.alignment = .right
        count.translatesAutoresizingMaskIntoConstraints = false
        count.widthAnchor.constraint(equalToConstant: Theme.m(38)).isActive = true

        let row = Theme.hstack([name, bar, count], spacing: Theme.m(12))
        let host = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            row.topAnchor.constraint(equalTo: host.topAnchor, constant: Theme.m(6)),
            row.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -Theme.m(6)),
        ])
        return host
    }
}
