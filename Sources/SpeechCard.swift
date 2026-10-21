// The recording pill, grown up: while a live dictation streams, the pill's
// seat shows one card — the nine ember bars and the timer as its header,
// and the words underneath in the serif, filling line by line. The card
// grows INTO the screen from whichever seat the pill occupies (down from a
// top seat, up from a bottom one, out from a side), so the live preview
// sits where you are already looking instead of on a strip at the bottom
// edge. The pill itself goes invisible while the card is up — the card's
// header IS the pill, one organism, and two copies of the same bars would
// say the mic is open twice.
//
// Words the stream has said twice sit in full white; the newest ones, which
// the recognizer may still change, sit dimmer until a later message repeats
// them. The foot names where the words are going and the tone they'll get,
// when the app already knew both at key-down.
//
// Same overlay recipe as the pill (see Pill.init in main.swift): a fixed
// window that never resizes while visible — only the glass card inside
// moves — at screen-saver level, dark-glass drawing, mouse-transparent.
import AppKit

final class SpeechCard {

    /// As big as the widest card ever gets; the window is set once per show
    /// and never resized while on screen (the Space-switch rule).
    private static let panelSize = NSSize(width: 460, height: 250)

    private let panel: NSPanel
    private let backdrop: NSView
    private let view: SpeechCardView
    private(set) var isVisible = false
    /// What the stream said last time, to tell the words it has repeated
    /// from the ones it has only said once.
    private var lastRaw = ""

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .screenSaver   // same level as the pill — see Pill.init
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        backdrop = PillView.glassBackdrop(cornerRadius: 18)
        view = SpeechCardView(frame: NSRect(origin: .zero, size: Self.panelSize))
        view.autoresizingMask = [.width, .height]
        let root = NSView(frame: NSRect(origin: .zero, size: Self.panelSize))
        root.autoresizingMask = [.width, .height]
        root.addSubview(backdrop)   // glass under, content on top
        root.addSubview(view)
        panel.contentView = root
    }

    /// Open at the pill's seat, header only — the first words widen it.
    /// `command` gives it the command look (white bars, the command key);
    /// `hint` is the tone AppStyle picked for where the words are going.
    func show(dock: PillDock, startedAt: Date, command: Bool = false, hint: ToneHint? = nil) {
        view.dock = dock
        view.startedAt = startedAt
        view.text = ""
        view.soft = 0
        view.mode = .listening
        view.command = command
        // A command is not pasted and takes no tone: nothing to name.
        view.chips = command ? [] : Self.chips(hint: hint)
        lastRaw = ""
        let f = mouseScreen().visibleFrame
        panel.setFrame(dock.aligned(size: Self.panelSize, in: f), display: false)
        layout()
        // Fresh pixels BEFORE the window comes on: the backing store still
        // holds the last dictation's card, and ordering front shows that
        // stale frame for a beat (measured 2026-08-24: the previous words
        // flicked on for a tenth of a second at every new dictation).
        view.needsDisplay = true
        panel.displayIfNeeded()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        isVisible = true
    }

    /// Command mode armed after the dictation began (the modifier landed
    /// second): the header turns into a command's.
    func setCommand(_ on: Bool) {
        guard isVisible, view.command != on else { return }
        view.command = on
        if on { view.chips = [] }
        layout()
        view.needsDisplay = true
    }

    /// The stream's words so far. The card keeps the tail that fits its
    /// five lines — like the old HUD strip, with room to actually read.
    func update(_ text: String) {
        guard isVisible else { return }
        let settled = Self.settledLength(before: lastRaw, now: text)
        lastRaw = text
        let shown = Self.fitted(text)
        view.text = shown
        view.soft = min((text as NSString).length - settled, (shown as NSString).length)
        layout()
        view.needsDisplay = true
    }

    /// Key up: the bars flatten under the sweep while the model finishes;
    /// the words stay put.
    func thinking() {
        guard isVisible else { return }
        view.mode = .thinking
        layout()
        view.needsDisplay = true
    }

    func hide() {
        panel.orderOut(nil)
        isVisible = false
        // The words leave with the card — an off-screen backing store must
        // not keep them for the next show to flash.
        view.text = ""
        view.soft = 0
        view.needsDisplay = true
    }

    /// Off the screen for the moment of a screenshot, back right after —
    /// same as the pill in captureCursorScreenAsync.
    func concealed(_ on: Bool) {
        panel.alphaValue = on ? 0 : 1
    }

    /// The mic level and the shared wobble phase, from the same 24 fps tick
    /// that drives the pill.
    func setLevel(_ level: CGFloat, phase: CGFloat) {
        view.level = level
        view.phase = phase
        view.needsDisplay = true
    }

    /// The glass follows the card's current shape — a content-level change,
    /// invisible to the window server.
    private func layout() {
        let r = view.cardRect
        if backdrop.frame != r { backdrop.frame = r }
        PillView.setGlassCorner(backdrop, view.text.isEmpty ? r.height / 2 : SpeechCardView.radius)
        panel.invalidateShadow()
    }

    /// How much of `now` the stream had already said, cut back to the start
    /// of the first word that changed. A word counts as settled once a later
    /// message repeats it unchanged — the only settledness every recognizer
    /// shows, since the providers that commit segments and the on-device
    /// passes that don't all hand over one string.
    static func settledLength(before prev: String, now: String) -> Int {
        let a = prev as NSString, b = now as NSString
        let n = min(a.length, b.length)
        var i = 0
        while i < n && a.character(at: i) == b.character(at: i) { i += 1 }
        if i == b.length { return i }   // nothing new since last time
        let space = CharacterSet.whitespacesAndNewlines
        while i > 0, let u = Unicode.Scalar(b.character(at: i - 1)), !space.contains(u) { i -= 1 }
        return i
    }

    /// Drop words off the front until what remains draws inside the body's
    /// five lines; an ellipsis says something scrolled away.
    private static func fitted(_ text: String) -> String {
        var t = text
        let h = SpeechCardView.textHeight
        guard h(t) > SpeechCardView.bodyMaxH else { return t }
        while t.count > 24, h("…" + t) > SpeechCardView.bodyMaxH {
            t = String(t.dropFirst(24))
            if let sp = t.firstIndex(of: " ") { t = String(t[t.index(after: sp)...]) }
        }
        return "…" + t
    }

    /// The foot's capsules: the app the words will land in and the tone
    /// they'll get there. Both come from what the key-down already knew —
    /// the tone AppStyle picked, or failing that just the app in front.
    private static func chips(hint: ToneHint?) -> [String] {
        var out: [String] = []
        let front = NSWorkspace.shared.frontmostApplication
        let app: String?
        if let place = hint?.place {
            // "Slack, a work message" — the app is everything before the kind.
            app = place.range(of: ", ", options: .backwards).map { String(place[..<$0.lowerBound]) } ?? place
        } else if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            app = front?.localizedName
        } else {
            app = nil
        }
        if let app = app, !app.isEmpty { out.append("Pasting into \(app)") }
        // The tone is the one whose rules the hint carries; code editors'
        // "leave it alone" belongs to no tone, and gets no capsule.
        if let rules = hint?.rules,
           let tone = ToneContext.allCases.lazy.map({ Tones.option(for: $0) }).first(where: { $0.rules == rules }) {
            out.append(tone.title.contains(" ") ? tone.title : "\(tone.title) tone")
        }
        return out
    }
}

/// Draws the card: bars + timer in the header, the words in the body, where
/// they're going in the foot. The header hugs the screen edge — at a bottom
/// seat it stays at the bottom of the card and the words grow upward above
/// it.
final class SpeechCardView: NSView {
    enum Mode { case listening, thinking }
    var mode: Mode = .listening
    var dock: PillDock = .bottomCenter
    var startedAt = Date()
    var text = ""
    /// How many UTF-16 units at the end of `text` the recognizer may still
    /// change — drawn dimmer.
    var soft = 0
    /// A command-mode take: white bars and the command key, like the pill.
    var command = false
    /// The foot's capsules ("Pasting into Notes", "Casual tone").
    var chips: [String] = []
    var level: CGFloat = 0
    var phase: CGFloat = 0

    static let width: CGFloat = 420
    static let headH: CGFloat = 40
    static let radius: CGFloat = 18
    private static let side: CGFloat = 18        // the words' left and right margin
    private static let padTop: CGFloat = 14, padBottom: CGFloat = 16
    private static let footH: CGFloat = 22 + 12   // a capsule and the margin under it

    /// Made once — this view draws 24 times a second while recording, and
    /// per-frame font lookups are what crashed the app (see PillView).
    static let bodyFont = Theme.serifFont(14.5, .regular)   // 18 pt at the default text size
    static let chipFont = NSFont.systemFont(ofSize: 11.5)
    /// Lines a point and a half apart, the text centered in each.
    private static let lineH = ceil(bodyFont.pointSize * 1.5)
    private static let body: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = lineH
        p.maximumLineHeight = lineH
        p.lineBreakMode = .byWordWrapping
        return p
    }()
    private static let lift = (lineH - NSLayoutManager().defaultLineHeight(for: bodyFont)) / 2
    static let bodyMaxH = lineH * 5
    private static let settledInk = NSColor(srgbRed: 0.957, green: 0.949, blue: 0.925, alpha: 1)   // #F4F2EC
    private static let softInk = NSColor.white.withAlphaComponent(0.45)

    /// The live caret: two points of ember at the end of the words, the one
    /// ember in the body. Blinks by swapping to a clear twin, so the words
    /// never reflow.
    private static func caret(_ color: NSColor) -> NSAttributedString {
        let h = ceil(bodyFont.pointSize * 1.1)
        let img = NSImage(size: NSSize(width: 3, height: h), flipped: false) { r in
            color.setFill()
            NSBezierPath(roundedRect: NSRect(x: 1, y: 0, width: 2, height: r.height), xRadius: 1, yRadius: 1).fill()
            return true
        }
        let a = NSTextAttachment()
        a.image = img
        a.bounds = NSRect(x: 0, y: -3, width: 3, height: h)
        let s = NSMutableAttributedString(attachment: a)
        s.addAttributes([.paragraphStyle: body, .baselineOffset: lift], range: NSRange(location: 0, length: s.length))
        return s
    }
    private static let caretOn = caret(PillView.emberBar)
    private static let caretOff = caret(.clear)

    static func textHeight(_ s: String) -> CGFloat {
        ceil((s as NSString).boundingRect(with: NSSize(width: width - side * 2, height: 10_000),
                                          options: [.usesLineFragmentOrigin, .usesFontLeading],
                                          attributes: [.font: bodyFont, .paragraphStyle: body]).height)
    }

    /// The card the current content wants, anchored to the dock's edge of
    /// the fixed window — the same edge-anchoring the pill uses, so the
    /// card lands exactly on the pill's seat. Header only, it IS the pill's
    /// recording capsule.
    var cardRect: NSRect {
        let size: NSSize
        if text.isEmpty {
            size = Pill.size(for: .recording, vertical: false, command: command)
        } else {
            size = NSSize(width: Self.width, height: Self.headH + bodyH + (chips.isEmpty ? 0 : Self.footH))
        }
        let x: CGFloat
        switch dock.hAlign {
        case .left:   x = 0
        case .center: x = (bounds.width - size.width) / 2
        case .right:  x = bounds.width - size.width
        }
        let y: CGFloat
        switch dock.vAlign {
        case .bottom: y = 0
        case .middle: y = (bounds.height - size.height) / 2
        case .top:    y = bounds.height - size.height
        }
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private var bodyH: CGFloat {
        Self.padTop + min(Self.textHeight(text + "|"), Self.bodyMaxH) + Self.padBottom
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = cardRect
        guard !text.isEmpty else { return drawHead(in: r, spread: false) }
        // AppKit's y is up: a bottom seat's header sits at the card's
        // bottom, everyone else's at the top. The words and the foot fill
        // the rest, reading away from the header either way.
        let headAtBottom = dock.vAlign == .bottom
        let head = NSRect(x: r.minX, y: headAtBottom ? r.minY : r.maxY - Self.headH, width: r.width, height: Self.headH)
        drawHead(in: head, spread: true)
        NSColor.white.withAlphaComponent(0.07).setFill()
        NSBezierPath(rect: NSRect(x: r.minX, y: headAtBottom ? head.maxY - 1 : head.minY, width: r.width, height: 1)).fill()

        let rest = headAtBottom
            ? NSRect(x: r.minX, y: head.maxY, width: r.width, height: r.height - Self.headH)
            : NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height - Self.headH)
        let words = NSMutableAttributedString(string: text, attributes: [
            .font: Self.bodyFont,
            .foregroundColor: Self.settledInk,
            .paragraphStyle: Self.body,
            .baselineOffset: Self.lift,
        ])
        let len = (text as NSString).length
        if soft > 0 {
            words.addAttribute(.foregroundColor, value: Self.softInk,
                               range: NSRange(location: len - min(soft, len), length: min(soft, len)))
        }
        // The caret only while the mic is live: blink on 0.525 s, off 0.525 s.
        if mode == .listening {
            let blink = Int(Date().timeIntervalSinceReferenceDate / 0.525) % 2 == 0
            words.append(blink ? Self.caretOn : Self.caretOff)
        }
        let textH = min(Self.textHeight(text + "|"), Self.bodyMaxH)
        words.draw(with: NSRect(x: r.minX + Self.side, y: rest.maxY - Self.padTop - textH,
                                width: r.width - Self.side * 2, height: textH),
                   options: [.usesLineFragmentOrigin, .usesFontLeading])

        guard !chips.isEmpty else { return }
        var x = r.minX + 14
        for chip in chips {
            let label = NSAttributedString(string: chip, attributes: [
                .font: Self.chipFont,
                .foregroundColor: NSColor.white.withAlphaComponent(0.8),
            ])
            let w = min(ceil(label.size().width) + 18, r.maxX - 14 - x)
            guard w > 40 else { break }
            let capsule = NSRect(x: x, y: rest.minY + 12, width: w, height: 22)
            NSColor.white.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: capsule, xRadius: 11, yRadius: 11).fill()
            label.draw(with: NSRect(x: capsule.minX + 9, y: capsule.midY - Self.chipFont.capHeight / 2,
                                    width: capsule.width - 18, height: 16),
                       options: [.truncatesLastVisibleLine])
            x = capsule.maxX + 8
        }
    }

    /// The pill's recording drawing — same nine bars, same command key,
    /// and in a take's last half minute the same countdown — so the pill-
    /// to-card handoff is invisible. Once the card has words the header
    /// spreads out: bars on the left, the countdown on the right. Key up
    /// flattens the bars under the sweep, exactly as the pill does.
    private func drawHead(in r: NSRect, spread: Bool) {
        let flat = mode == .thinking
        let timer = (flat ? nil : PillView.countdown(since: startedAt)).map {
            NSAttributedString(string: $0, attributes: [
                .font: PillView.timerFont,
                .foregroundColor: PillView.amberBadge,
            ])
        }
        let ts = timer?.size() ?? .zero
        let keyW = command ? PillView.keyCap + 9 : 0
        var x = spread ? r.minX + 14
            : r.midX - (keyW + PillView.barsSpan + (timer == nil ? 0 : 9 + ts.width)) / 2
        if command {
            PillView.drawKey(PillView.commandGlyph, in: NSRect(x: x, y: r.midY - PillView.keyCap / 2,
                                                             width: PillView.keyCap, height: PillView.keyCap))
            x += keyW
        }
        PillView.drawBars(x: x, midY: r.midY, level: level, phase: phase,
                          color: command ? PillView.voiceWhite : PillView.voiceEmber, flat: flat)
        let tx = spread ? r.maxX - 14 - ts.width : x + PillView.barsSpan + 9
        timer?.draw(at: NSPoint(x: tx, y: r.midY - ts.height / 2))
    }
}
