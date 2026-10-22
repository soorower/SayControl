// SayControl: dictation and spoken controls for the Mac.
// fn (hold or tap) -> record mic -> transcribe -> paste at cursor.
//
// Two ways to transcribe: upload the finished clip (OpenRouter or OpenAI), or
// stream it live over OpenAI's realtime socket and watch the text arrive as you
// speak. Both meet again in finishTranscription().
//
// This file is the menu-bar app itself. See also:
//   Config.swift        settings/log/history on disk
//   LiveTranscribe.swift  the streaming realtime path
//   Replacements.swift  the "heard this -> type that" dictionary
//   Corrections.swift   learns a replacement when you fix a word after a paste
//   Theme.swift, SettingsUI.swift, SettingsPanes.swift   the settings window
import Cocoa
import AVFoundation
import ApplicationServices

let MIN_CLIP_SECONDS: TimeInterval = 0.4 // discard accidental blips
/// How long the mic stays open after the key comes up. People let go of fn
/// on the last syllable, and a word's final consonant is the quietest,
/// latest part of it: nine "open Claude" clips from 2026-08-22 all ended
/// mid-word, still at a third of peak level on the last sample, and came
/// back as club, cloud, closed, floor. A third of a second catches the "d"
/// and the beat of silence after it that the recognizer expects a word to
/// end on.
let STOP_TAIL_SECONDS: TimeInterval = 0.35
let MAX_CLIP_SECONDS: TimeInterval = 300 // safety auto-stop
/// A hands-free take stops on its own after this long with no new words. One
/// left running by mistake would otherwise stream silence to the five-minute
/// cap, and on the cloud that silence is billed.
let HANDS_FREE_IDLE_SECONDS: TimeInterval = 60
let FN_KEYCODE: UInt16 = 63

enum AppState { case idle, recording, transcribing }
/// What the pill shows. `attention` is "copied, not pasted";
/// `needsAccess` is a keystroke Accessibility would have allowed;
/// `nothingHeard` is a take that came back empty.
/// `holdHint` is a tap too short to be a take: the pill shakes its head
/// and says how the gesture goes.
enum PillState { case idle, recording, transcribing, attention, needsAccess, learned, nothingHeard, holdHint }

func mouseScreen() -> NSScreen {
    let loc = NSEvent.mouseLocation
    return NSScreen.screens.first { NSMouseInRect(loc, $0.frame, false) }
        ?? NSScreen.main ?? NSScreen.screens[0]
}

final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Pill (floating status bar)

/// Warm ash frost capsule: the screen shows through blurred, dimmed the
/// same over white and black. At rest it is a slim strip with three dots —
/// two ash, one ember, the mark's bars and arrow reduced to a signature —
/// and says nothing; bars appear only while your voice is live (ember), and
/// a command's bars are white, so the two can't be mistaken for each other.
/// This view draws only the CONTENT — the frost itself is a sibling view
/// underneath (glassBackdrop), because a subview would render on top of
/// draw().
final class PillView: NSView {
    var state: PillState = .idle {
        didSet {
            if state == .recording && oldValue != .recording { recordingStarted = Date() }
            if state != .recording { stopMark = false }
            // The command look belongs to one take — past it, nothing that
            // borrows the transcribing capsule later inherits it.
            if state != .recording && state != .transcribing { command = false }
            needsDisplay = true
        }
    }
    var level: CGFloat = 0      // mic level 0..1 while recording
    var phase: CGFloat = 0      // animation phase
    /// This take is a command-mode instruction, not words to paste: white
    /// bars with the command key in front of them. Ember means dictation.
    var command = false { didSet { needsDisplay = true } }
    /// The word the last correction taught, for "Learned <word>" — cut to
    /// fit once, here, not on every draw.
    var learnedWord: String? {
        didSet {
            shownWord = learnedWord.map { Self.fitted($0, font: Self.wordFont, width: Self.maxWordWidth) }
            needsDisplay = true
        }
    }
    private(set) var shownWord: String?
    var onClick: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragMoved: ((NSPoint) -> Void)?   // screen coordinates
    var onDragEnded: ((NSPoint) -> Void)?
    /// Which window edge the capsule hugs — follows the pill's dock.
    var dock: PillDock = .bottomCenter { didSet { needsDisplay = true } }
    /// When the take began — the last-seconds countdown counts from here.
    /// Settable so --snapshot can show a take seven seconds in.
    var recordingStarted = Date()
    /// The live take's words, one line beside the bars (PillLine). Set for
    /// the length of a live take in the "line" mode, nil otherwise.
    var line: PillLine? { didSet { needsDisplay = true } }
    /// The size the capsule is drawn at this frame while it springs from
    /// one shape to the next (Pill.reshape); nil once it has arrived.
    var shownSize: NSSize?
    /// The pointer is over the resting pill: it swells a little and its
    /// dots brighten — "this is a thing you can press" — and says nothing.
    var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    /// A hands-free take from the pill menu: a stop square at the capsule's
    /// far end says "click here to finish" (a click anywhere on the
    /// recording pill does it; the square is the invitation).
    var stopMark = false { didSet { if stopMark != oldValue { needsDisplay = true } } }
    static let stopSide: CGFloat = 20
    private var pressed = false
    private var pressPoint = NSPoint.zero
    private(set) var dragging = false

    // The pill floats over every wallpaper, so its palette is fixed, not dynamic.
    /// Made once, not 24 times a second: the timer fonts. The app died
    /// twice on 2026-08-24 (the pill's timer, then the agent foot's)
    /// inside CoreText building font attributes mid-draw — the system
    /// font cache handing back something unusable under per-frame churn.
    /// One font object per role, created at load, ends the churn.
    static let timerFont      = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    static let timerFontSmall = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
    static let badgeFont      = NSFont.systemFont(ofSize: 12.5, weight: .medium)
    static let glyphFont      = NSFont.systemFont(ofSize: 10, weight: .bold)
    static let keyFont        = NSFont.systemFont(ofSize: 10.5, weight: .medium)
    /// The word you taught it is yours, so it wears the serif, in italic.
    static let wordFont: NSFont = {
        let base = NSFont.systemFont(ofSize: 13.5)
        let serif = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
        return NSFont(descriptor: serif.withSymbolicTraits(.italic), size: 13.5) ?? base
    }()

    static let glass      = NSColor(srgbRed: 0.110, green: 0.102, blue: 0.086, alpha: 0.94) // #1C1A16
    static let glassInk   = NSColor(srgbRed: 0.925, green: 0.910, blue: 0.875, alpha: 1)    // #ECE8DF
    static let glassMuted = NSColor(srgbRed: 0.600, green: 0.570, blue: 0.540, alpha: 1)    // #9A9488
    static let emberBar   = NSColor(srgbRed: 0.950, green: 0.420, blue: 0.250, alpha: 1)    // #F26A3F
    /// Your voice's bars: ember let down a step. Full ember at the corner
    /// of your eye for minutes at a time pulled focus off the work; this
    /// still reads "listening" at a glance and stops there.
    static let voiceEmber = NSColor(srgbRed: 0.910, green: 0.604, blue: 0.486, alpha: 1)    // #E89A7C
    /// One colour per spoken action, the same on its highlight, its chip in
    /// the line and its toast: muted so they sit beside the bars on dark glass.
    static let skyAction   = NSColor(srgbRed: 0.490, green: 0.722, blue: 0.961, alpha: 1)   // #7DB8F5 screenshot
    static let lilacAction = NSColor(srgbRed: 0.718, green: 0.631, blue: 0.949, alpha: 1)   // #B7A1F2 link
    static let mossBadge  = NSColor(srgbRed: 0.373, green: 0.765, blue: 0.584, alpha: 1)    // #5FC395
    static let amberBadge = NSColor(srgbRed: 0.850, green: 0.660, blue: 0.330, alpha: 1)    // #D9A855
    /// "Didn't catch that" is news, not a problem — a grey circle, no hue.
    static let quietBadge = NSColor(white: 0.62, alpha: 1)
    /// The other voice: a command's bars, and the agent's on its card.
    static let voiceWhite = NSColor.white.withAlphaComponent(0.86)
    /// The logo's bars, where the mark is drawn on glass.
    static let markInk    = NSColor.white.withAlphaComponent(0.55)
    /// The resting dots under the pointer.
    static let hoverDot = NSColor(srgbRed: 0.925, green: 0.910, blue: 0.875, alpha: 0.92)
    /// The resting pill's ash dots.
    static let ashDot     = NSColor(srgbRed: 0.78, green: 0.76, blue: 0.72, alpha: 0.62)
    static let timerDim   = NSColor.white.withAlphaComponent(0.5)
    private static let glyphInk = NSColor(srgbRed: 0.110, green: 0.102, blue: 0.086, alpha: 1)

    // The edge (see drawGlassEdge).
    static let edgeDark = NSColor.black.withAlphaComponent(0.55)
    static let edgeRing = NSColor.white.withAlphaComponent(0.07)
    static let edgeLip  = NSColor.white.withAlphaComponent(0.16)

    /// Translucent backing for the pill and its sibling overlays: real
    /// behind-window frost with SayCtrl's warm ash wash over it. The wash is
    /// heavy enough that the capsule reads as the SAME dark ash on every
    /// screen — a white page can only lighten it a hair, so the light ink
    /// needs no per-state dimming. NOT NSGlassEffectView:
    /// its clear glass adapts to the backdrop with no way to pin it (a
    /// dark appearance doesn't stop it), going near-invisible over white
    /// and re-adapting with a visible blip whenever the pill lands on a
    /// new screen (tried 2026-08-20, twice).
    ///
    /// The edge rides on top of the wash (GlassEdgeView). The old one-point
    /// 9% white border was the whole edge, and on a white page it vanished.
    static func glassBackdrop(cornerRadius: CGFloat) -> NSView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        v.wantsLayer = true
        v.layer?.cornerRadius = cornerRadius
        v.layer?.masksToBounds = true
        let wash = NSView()
        wash.wantsLayer = true
        wash.layer?.backgroundColor = glass.withAlphaComponent(0.60).cgColor
        wash.autoresizingMask = [.width, .height]
        v.addSubview(wash)
        let edge = GlassEdgeView()
        edge.radius = cornerRadius
        edge.autoresizingMask = [.width, .height]
        v.addSubview(edge)
        return v
    }

    static func setGlassCorner(_ backdrop: NSView, _ radius: CGFloat) {
        backdrop.layer?.cornerRadius = radius
        for case let edge as GlassEdgeView in backdrop.subviews { edge.radius = radius }
    }

    /// The edge, drawn inside `r` because the frost masks to its own shape:
    /// outermost a half-point dark line — what separates the capsule from a
    /// white page — then a faint light ring, and along the top a one-point
    /// light lip. The mockup's box-shadow, turned inward.
    static func drawGlassEdge(in r: NSRect, radius: CGFloat) {
        guard r.width > 3, r.height > 3 else { return }
        func rounded(_ inset: CGFloat) -> NSBezierPath {
            let rr = max(0, min(radius, min(r.width, r.height) / 2) - inset)
            return NSBezierPath(roundedRect: r.insetBy(dx: inset, dy: inset), xRadius: rr, yRadius: rr)
        }
        // The lip: the shape minus itself a point lower leaves a sliver along
        // the top that thins away down the sides.
        NSGraphicsContext.saveGraphicsState()
        let inner = rounded(0.5)
        inner.addClip()
        let lower = rounded(0.5)
        lower.transform(using: AffineTransform(translationByX: 0, byY: -1))
        inner.append(lower)
        inner.windingRule = .evenOdd
        edgeLip.setFill()
        inner.fill()
        NSGraphicsContext.restoreGraphicsState()
        let ring = rounded(1)
        ring.lineWidth = 1
        edgeRing.setStroke()
        ring.stroke()
        let outline = rounded(0.25)
        outline.lineWidth = 0.5
        edgeDark.setStroke()
        outline.stroke()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The click fires on mouse-UP so a press can become a drag instead:
    /// hold and move a few points and the capsule tears off toward the six
    /// dock slots (see AppDelegate.pillDragBegan). The window is bigger
    /// than the capsule (see Pill.panelSize) — presses in the transparent
    /// margin are not pill presses.
    override func mouseDown(with event: NSEvent) {
        pressed = capsuleRect.contains(convert(event.locationInWindow, from: nil))
        pressPoint = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressed else { return }
        let p = NSEvent.mouseLocation
        if !dragging, hypot(p.x - pressPoint.x, p.y - pressPoint.y) > 6 {
            dragging = true
            onDragBegan?()
        }
        if dragging { onDragMoved?(p) }
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = dragging, wasPressed = pressed
        dragging = false
        pressed = false
        if wasDragging {
            onDragEnded?(NSEvent.mouseLocation)
        } else if wasPressed {
            onClick?()
        }
    }

    /// The capsule the current state wants, anchored to the dock's edge of
    /// the fixed window — edge-anchored, not centered, so the visible
    /// capsule stays pinned to the screen edge as states change size. The
    /// WINDOW never resizes — a frame change landing mid Space-switch
    /// renders the panel transition-scaled — only the drawing inside changes.
    var capsuleRect: NSRect {
        let s = shownSize ?? targetSize
        let x: CGFloat
        switch dock.hAlign {
        case .left:   x = 0
        case .center: x = (bounds.width - s.width) / 2
        case .right:  x = bounds.width - s.width
        }
        let y: CGFloat
        switch dock.vAlign {
        case .bottom: y = 0
        case .middle: y = (bounds.height - s.height) / 2
        case .top:    y = bounds.height - s.height
        }
        return NSRect(x: x, y: y, width: s.width, height: s.height)
    }

    /// The shape the current state wants — where the spring is headed.
    var targetSize: NSSize {
        let s = Pill.size(for: state, vertical: dock.isVertical, command: command, word: shownWord,
                          line: line?.isOpen == true && !dock.isVertical ? PillLine.maxWidth : 0,
                          countdown: countdown != nil)
        if stopMark && state == .recording && !dock.isVertical {
            return NSSize(width: s.width + 8 + Self.stopSide, height: s.height)
        }
        // Hovered it swells to a comfortable target: 72 × 22 from 50 × 12.
        return state == .idle && hovered ? NSSize(width: s.width + 22, height: s.height + 10) : s
    }

    /// "25 s left" through a take's last half minute, nil before that and
    /// once the words are coming back. The pill kept a running clock
    /// through 2.2; with nothing billed by the minute any more the clock
    /// only made people hurry, and the one moment time matters is the
    /// five-minute cap on a single take.
    var countdown: String? {
        guard state == .recording else { return nil }
        return Self.countdown(since: recordingStarted)
    }

    static func countdown(since start: Date) -> String? {
        let left = Int(MAX_CLIP_SECONDS - Date().timeIntervalSince(start))
        return (0...30).contains(left) ? "\(left) s left" : nil
    }
    /// What the capsule reserves for the countdown: its widest reading, so
    /// the capsule doesn't twitch as the digits change.
    static var countdownWidth: CGFloat { ceil(width("30 s left", timerFont)) }

    override func draw(_ dirtyRect: NSRect) {
        let r = capsuleRect
        let vertical = dock.isVertical
        switch state {
        case .idle:
            Self.drawDots(in: r, vertical: vertical, ember: hovered ? Self.hoverDot : Self.ashDot,
                          ash: hovered ? Self.hoverDot : Self.ashDot)
        case .recording, .transcribing:
            let flat = state == .transcribing
            vertical ? drawVoiceUpright(in: r, flat: flat) : drawVoice(in: r, flat: flat)
        case .attention, .needsAccess, .learned, .nothingHeard, .holdHint:
            drawBadge(in: r, vertical: vertical)
        }
    }

    // MARK: The mark and the bars

    /// The pill at rest: three ash dots, left to right (top to bottom in an
    /// upright seat) — the mark's three bars reduced to a signature. It used
    /// to draw the bars themselves, which read as a signal-strength icon.
    /// The third dot was ember through 2.2, and an orange dot that never
    /// goes out is exactly macOS's own "the microphone is on" light: the
    /// pill looked like it was always listening. Ember is for when it is.
    /// `ember` still colours the third dot for callers that want the old
    /// signature (the drag ghosts tint all three).
    static func drawDots(in r: NSRect, vertical: Bool, ember: NSColor = ashDot, ash: NSColor = ashDot) {
        let d: CGFloat = 4, gap: CGFloat = 4.5
        let block = 3 * d + 2 * gap
        for i in 0..<3 {
            let step = CGFloat(i) * (d + gap)
            let dot = vertical
                ? NSRect(x: r.midX - d / 2, y: r.midY + block / 2 - d - step, width: d, height: d)
                : NSRect(x: r.midX - block / 2 + step, y: r.midY - d / 2, width: d, height: d)
            (i == 2 ? ember : ash).setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
    }

    /// The logo's three rising bars, quiet — the pill signing the screen
    /// without a word. An upright seat turns the mark on its side, the bars
    /// reaching sideways, shortest at the top.
    static func drawMark(in r: NSRect, vertical: Bool, color: NSColor = markInk) {
        let lengths: [CGFloat] = [4, 7, 9]
        let w: CGFloat = 3, gap: CGFloat = 3
        let block = 3 * w + 2 * gap
        color.setFill()
        for (i, len) in lengths.enumerated() {
            let step = CGFloat(i) * (w + gap)
            let bar = vertical
                ? NSRect(x: r.midX - len / 2, y: r.midY + block / 2 - w - step, width: len, height: w)
                : NSRect(x: r.midX - block / 2 + step, y: r.midY - len / 2, width: w, height: len)
            NSBezierPath(roundedRect: bar, xRadius: w / 2, yRadius: w / 2).fill()
        }
    }

    /// Nine bars, three points wide with three between: 51 points of row.
    static let barsSpan: CGFloat = 51

    /// How far bar `i` of nine reaches at this mic level — the one wobble
    /// every copy of the bars shares (the pill, the speech card, the agent
    /// card's foot), between `low` and `high`.
    static func liveBar(_ i: Int, level: CGFloat, phase: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        let fi = CGFloat(i), mid: CGFloat = 4
        let centerWeight = 1.0 - abs(fi - mid) / mid * 0.45
        let s = sin(phase + fi * 0.85)
        let wobble = 0.30 + 0.70 * s * s
        let effLevel = 0.25 + 0.75 * level
        return max(low, min(low + (high - low) * effLevel * wobble * centerWeight, high))
    }

    /// Transcribing: how lit bar `i` is as the sweep passes, 0 (a resting
    /// dot) to 1. One pass every 1.4 s, left to right, each bar 0.09 s
    /// behind the one before it. The tick adds 0.30 of phase 24 times a
    /// second, so phase / 7.2 is seconds.
    static func sweepLight(_ i: Int, phase: CGFloat) -> CGFloat {
        let t = Double(phase) / 7.2 - Double(i) * 0.09
        var u = t.truncatingRemainder(dividingBy: 1.4) / 1.4
        if u < 0 { u += 1 }
        let x = u < 0.18 ? u / 0.18 : u < 0.55 ? 1 - (u - 0.18) / 0.37 : 0
        return CGFloat(x * x * (3 - 2 * x))
    }

    /// Working, not listening: a smooth swell that travels along the nine
    /// bars, 0 (low, dim) to 1, one pass every 1.1 s, on the wall clock so
    /// it glides at whatever rate the view redraws. The old flat dots with
    /// a lit one hopping along read as stuck — a network of dots, not a
    /// thing at work.
    static func workLight(_ i: Int) -> CGFloat {
        let t = CACurrentMediaTime()
        let u = 0.5 + 0.5 * sin(2 * .pi * t / 1.1 - Double(i) * 0.62)
        return CGFloat(u * u)
    }

    /// The nine bars in a row from `x`, centered on `midY`. Flat (the words
    /// are coming back), they carry the working swell in white.
    static func drawBars(x: CGFloat, midY: CGFloat, level: CGFloat, phase: CGFloat,
                         color: NSColor, flat: Bool, high: CGFloat = 22) {
        for i in 0..<9 {
            let light = flat ? workLight(i) : 0
            let h = flat ? 4 + (high * 0.6 - 4) * light : liveBar(i, level: level, phase: phase, low: 4, high: high)
            (flat ? NSColor.white.withAlphaComponent(0.30 + 0.60 * light) : color).setFill()
            let bar = NSRect(x: x + CGFloat(i) * 6, y: midY - h / 2, width: 3, height: h)
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    /// The same nine stood on end: rows reaching sideways, walking down
    /// from `top`.
    static func drawBarsSideways(midX: CGFloat, top: CGFloat, level: CGFloat, phase: CGFloat,
                                 color: NSColor, flat: Bool, high: CGFloat) {
        for i in 0..<9 {
            let light = flat ? workLight(i) : 0
            let w = flat ? 4 + (high * 0.6 - 4) * light : liveBar(i, level: level, phase: phase, low: 4, high: high)
            (flat ? NSColor.white.withAlphaComponent(0.30 + 0.60 * light) : color).setFill()
            let bar = NSRect(x: midX - w / 2, y: top - 3 - CGFloat(i) * 6, width: w, height: 3)
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    static func clock(_ seconds: Int) -> String { String(format: "%d:%02d", seconds / 60, seconds % 60) }

    /// The command key as the keyboard prints it: ⌃ unless the command
    /// modifier was moved in Settings.
    static var commandGlyph: String {
        switch Shortcuts.commandModifier {
        case .option:  return "⌥"
        case .shift:   return "⇧"
        case .command: return "⌘"
        default:       return "⌃"
        }
    }

    /// A small keycap on the glass — ⌘ and V in "press ⌘V", the command
    /// key in front of a command's bars. A dark point along the bottom is
    /// its lip.
    static let keyCap: CGFloat = 18
    static func keyWidth(_ label: String) -> CGFloat { max(keyCap, ceil(width(label, keyFont)) + 8) }
    static func drawKey(_ label: String, in r: NSRect) {
        let cap = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
        NSColor.white.withAlphaComponent(0.12).setFill()
        cap.fill()
        NSGraphicsContext.saveGraphicsState()
        cap.addClip()
        NSColor.black.withAlphaComponent(0.4).setFill()
        NSBezierPath(rect: NSRect(x: r.minX, y: r.minY, width: r.width, height: 1)).fill()
        NSGraphicsContext.restoreGraphicsState()
        drawCentered(label, font: keyFont, color: .white, in: r)
    }

    /// One line of text centered in `r` on its capitals, the way the eye
    /// finds the middle of a glyph.
    static func drawCentered(_ s: String, font: NSFont, color: NSColor, in r: NSRect) {
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        let w = a.size().width
        a.draw(at: NSPoint(x: r.midX - w / 2, y: r.midY - font.capHeight / 2 + font.descender))
    }

    /// Widths the badges ask for over and over (every hover poll sizes the
    /// capsule) — measured once per string.
    private static var widths: [String: CGFloat] = [:]
    static func width(_ s: String, _ font: NSFont) -> CGFloat {
        let key = "\(font.fontName) \(font.pointSize) \(s)"
        if let w = widths[key] { return w }
        let w = NSAttributedString(string: s, attributes: [.font: font]).size().width
        widths[key] = w
        return w
    }

    /// Room for the learned word: what's left of the window's 228 points
    /// once the circle, "Learned" and the padding have theirs.
    static let maxWordWidth: CGFloat = 120
    static func fitted(_ s: String, font: NSFont, width limit: CGFloat) -> String {
        guard width(s, font) > limit else { return s }
        var t = s
        while t.count > 1, width(t + "…", font) > limit { t.removeLast() }
        return t + "…"
    }

    /// Soft-ember bars while you talk, and in a live take the newest words
    /// beside them on one line; while the words come back the same capsule
    /// holds still — bars flat under the sweep, the line where it stopped.
    /// A command puts its key in front and turns the bars white. The last
    /// half minute of a take adds the countdown at the far end.
    private func drawVoice(in r: NSRect, flat: Bool) {
        let left = countdown.map {
            NSAttributedString(string: $0, attributes: [.font: Self.timerFont, .foregroundColor: Self.amberBadge])
        }
        let ls = left?.size() ?? .zero
        let keyW = command ? Self.keyCap + 9 : 0
        let stopW = stopMark && !flat ? 8 + Self.stopSide : 0
        let leftW = (left == nil ? 0 : 9 + Self.countdownWidth) + stopW
        // With a line the capsule is laid out from its left end — the bars
        // stay put while the words open out beside them. Without one the
        // bars sit centred, as they always have.
        let lined = line?.isOpen == true
        var x = lined ? r.minX + 14 : r.midX - (keyW + Self.barsSpan + leftW) / 2
        if command {
            Self.drawKey(Self.commandGlyph, in: NSRect(x: x, y: r.midY - 9, width: Self.keyCap, height: Self.keyCap))
            x += keyW
        }
        Self.drawBars(x: x, midY: r.midY, level: level, phase: phase,
                      color: command ? Self.voiceWhite : Self.voiceEmber, flat: flat, high: 22)
        x += Self.barsSpan
        if lined, let line = line {
            let right = r.maxX - 14 - leftW
            line.draw(in: NSRect(x: x + 11, y: r.minY, width: max(0, right - x - 11), height: r.height), working: flat)
        }
        left?.draw(at: NSPoint(x: lined ? r.maxX - 14 - stopW - ls.width : x + 9, y: r.midY - ls.height / 2))
        if stopW > 0 {
            let s = Self.stopSide
            let box = NSRect(x: r.maxX - 9 - s, y: r.midY - s / 2, width: s, height: s)
            NSColor.white.withAlphaComponent(0.13).setFill()
            NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
            PillView.glassInk.setFill()
            NSBezierPath(roundedRect: box.insetBy(dx: 6, dy: 6), xRadius: 2, yRadius: 2).fill()
        }
    }

    /// The recording capsule stood upright (the side seats): the same nine
    /// bars stacked as rows reaching sideways, the command key on top, the
    /// countdown at the foot in a take's last half minute.
    private func drawVoiceUpright(in r: NSRect, flat: Bool) {
        let timer = countdown.map {
            NSAttributedString(string: $0.replacingOccurrences(of: " s left", with: "s"), attributes: [
                .font: Self.timerFontSmall,
                .foregroundColor: Self.amberBadge,
            ])
        }
        let ts = timer?.size() ?? .zero
        let keyH = command ? Self.keyCap + 8 : 0
        let timerH = timer == nil ? 0 : 8 + ts.height
        var top = r.midY + (keyH + Self.barsSpan + timerH) / 2   // walks down from here
        if command {
            Self.drawKey(Self.commandGlyph, in: NSRect(x: r.midX - Self.keyCap / 2, y: top - Self.keyCap,
                                                       width: Self.keyCap, height: Self.keyCap))
            top -= keyH
        }
        Self.drawBarsSideways(midX: r.midX, top: top, level: level, phase: phase,
                              color: command ? Self.voiceWhite : Self.voiceEmber, flat: flat, high: r.width - 14)
        timer?.draw(at: NSPoint(x: r.midX - ts.width / 2, y: top - Self.barsSpan - 8 - ts.height))
    }

    // MARK: Badges

    /// What a badge says, piece by piece: words, keycaps, and your own word.
    enum Piece { case text(String), key(String), word(String) }

    /// A badge without a circle (the hold hint) is words alone: the pill is
    /// answering the key you just touched, not reporting news.
    static func badge(_ state: PillState, word: String?) -> (circle: NSColor?, glyph: String, pieces: [Piece])? {
        switch state {
        case .holdHint:     return (nil, "fn", [.text("Hold"), .key("fn"), .text("to talk")])
        case .attention:    return (amberBadge, "!", [.text("Copied · press"), .key("⌘"), .key("V")])
        case .needsAccess:  return (amberBadge, "!", [.text("Needs Accessibility")])
        case .learned:      return (mossBadge, "+", [Piece.text("Learned")] + (word.map { [Piece.word($0)] } ?? []))
        case .nothingHeard: return (quietBadge, "?", [.text("Didn’t catch that")])
        case .idle, .recording, .transcribing: return nil
        }
    }

    private static func width(of p: Piece) -> CGFloat {
        switch p {
        case .text(let s): return width(s, badgeFont)
        case .key(let k):  return keyWidth(k)
        case .word(let w): return width(w, wordFont)
        }
    }

    /// Circle, then each piece eight points apart; eight in front, fourteen
    /// behind. Without a circle the words start six in.
    static func badgeWidth(_ pieces: [Piece], circle: Bool = true) -> CGFloat {
        pieces.reduce(circle ? 8 + 16 + 14 : 6 + 14) { $0 + 8 + width(of: $1) }
    }

    /// A colored circle with a glyph, then its words. An upright seat (no
    /// room for words along a screen edge) draws the circle alone.
    private func drawBadge(in r: NSRect, vertical: Bool) {
        guard let b = Self.badge(state, word: shownWord) else { return }
        let d: CGFloat = 16
        let circle = NSRect(x: vertical ? r.midX - d / 2 : r.minX + 8, y: r.midY - d / 2, width: d, height: d)
        if let fill = b.circle {
            fill.setFill()
            NSBezierPath(ovalIn: circle).fill()
            Self.drawCentered(b.glyph, font: Self.glyphFont, color: Self.glyphInk, in: circle)
        } else if vertical {
            // No room for words on a screen edge: the key alone.
            Self.drawKey(b.glyph, in: NSRect(x: r.midX - Self.keyCap / 2, y: r.midY - Self.keyCap / 2,
                                             width: Self.keyCap, height: Self.keyCap))
        }
        guard !vertical else { return }
        // Words and the serif word share one baseline, set by the sans caps.
        let baseline = r.midY - Self.badgeFont.capHeight / 2
        var x = b.circle == nil ? r.minX + 6 : circle.maxX
        for p in b.pieces {
            x += 8
            switch p {
            case .text(let s):
                NSAttributedString(string: s, attributes: [.font: Self.badgeFont, .foregroundColor: Self.glassInk])
                    .draw(at: NSPoint(x: x, y: baseline + Self.badgeFont.descender))
            case .key(let k):
                Self.drawKey(k, in: NSRect(x: x, y: r.midY - Self.keyCap / 2, width: Self.keyWidth(k), height: Self.keyCap))
            case .word(let w):
                NSAttributedString(string: w, attributes: [.font: Self.wordFont, .foregroundColor: NSColor.white])
                    .draw(at: NSPoint(x: x, y: baseline + Self.wordFont.descender))
            }
            x += Self.width(of: p)
        }
    }
}

/// The glass's edge, over the frost and its wash (the frost masks to its
/// rounded shape, so the edge lives inside it). Redrawn whenever the glass
/// changes shape — the pill and the cards resize it from state to state.
final class GlassEdgeView: NSView {
    var radius: CGFloat = 0 { didSet { if radius != oldValue { needsDisplay = true } } }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }
    /// Decoration only: clicks go to whatever the glass is behind.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        PillView.drawGlassEdge(in: bounds, radius: radius)
    }
}

final class Pill {
    /// The resting strip: three dots. 50 wide (40 through 2.2) so it's
    /// easier to find and to grab for a drag.
    static let idleSize = NSSize(width: 50, height: 12)
    /// The window is as big as the largest state and NEVER changes size
    /// while states come and go — resizing an on-screen panel while macOS
    /// animates a Space switch renders it transition-scaled (the
    /// shrunken-pill bug). States only redraw the capsule inside; the
    /// margin stays transparent. The one sanctioned resize is a dock
    /// change (a deliberate user action, never a background tick), which
    /// swaps between the two orientations' fixed sizes.
    /// 420 wide since the live line moved into the pill: bars, the line
    /// at its full width and the countdown, with room to spare.
    static let panelSize = NSSize(width: 440, height: 46)
    static let verticalPanelSize = NSSize(width: 46, height: 228)
    /// Talking: tall enough that the line's serif reads at a glance from
    /// the corner of your eye (32 through the first cut of the line).
    static let recordingHeight: CGFloat = 38
    static func windowSize(for dock: PillDock) -> NSSize {
        dock.isVertical ? verticalPanelSize : panelSize
    }

    /// Every size stays inside the fixed window above; 228 points (the
    /// upright window's length) is the budget a badge and a long learned
    /// word are cut to. `line` is the width the live line has opened to,
    /// `countdown` whether a take's last half minute is showing.
    static func size(for state: PillState, vertical: Bool, command: Bool = false, word: String? = nil,
                     line: CGFloat = 0, countdown: Bool = false) -> NSSize {
        // A command's key in front of the bars: the cap and its gap.
        let key: CGFloat = command ? PillView.keyCap + 9 : 0
        if vertical {
            switch state {
            // The mark on its side.
            case .idle:                     return NSSize(width: idleSize.height, height: idleSize.width)
            // 9 bars stacked as rows, the countdown at the foot when it runs.
            case .recording, .transcribing: return NSSize(width: 38, height: 80 + key + (countdown ? 22 : 0))
            // No room for words along a screen edge — the badge circle
            // alone carries the state (the HUD already said the words).
            case .attention, .needsAccess, .learned, .nothingHeard, .holdHint:
                return NSSize(width: 28, height: 28)
            }
        }
        switch state {
        case .idle:                         return idleSize
        // The 9 bars and their padding — the capsule hugs its content
        // instead of floating in padding — then the line and the countdown
        // when they're showing. It stays put while transcribing: snapping to
        // the idle strip read as "stopped".
        case .recording, .transcribing:
            let words = line > 0 ? 11 + line + 3 : 0
            let left = countdown ? 9 + PillView.countdownWidth : 0
            return NSSize(width: 14 + key + PillView.barsSpan + words + left + 14, height: recordingHeight)
        case .attention, .needsAccess, .learned, .nothingHeard, .holdHint:
            let b = PillView.badge(state, word: word)
            let pieces = b?.pieces ?? []
            return NSSize(width: min(ceil(PillView.badgeWidth(pieces, circle: b?.circle != nil)), verticalPanelSize.height),
                          height: 28)
        }
    }

    let panel: NSPanel
    let view: PillView
    private let backdrop: NSView
    /// Glass and content together — what the idle fade dims and the head-
    /// shake moves. Not the panel: its alpha is the conceal switch.
    private let root: NSView
    private var hoverTimer: Timer?

    var state: PillState = .idle {
        didSet {
            view.state = state
            restedSince = Date()
            if faded { setFaded(false) }
            reshape()
            // The working swell and the line's shimmer glide on the wall
            // clock; the 24 fps heartbeat would step them visibly.
            if state == .transcribing, workTimer == nil {
                let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                    guard let self = self, self.panel.alphaValue > 0 else { return }
                    self.view.needsDisplay = true
                }
                RunLoop.main.add(t, forMode: .common)
                workTimer = t
            } else if state != .transcribing {
                workTimer?.invalidate()
                workTimer = nil
            }
        }
    }
    private var workTimer: Timer?

    /// This take is a command (see PillView.command). Set before the state
    /// goes to .recording; any state past the take clears it.
    var command: Bool {
        get { view.command }
        set {
            guard newValue != view.command else { return }
            view.command = newValue
            reshape()
        }
    }

    /// The word for the next "Learned" — set before the state.
    var learnedWord: String? {
        get { view.learnedWord }
        set {
            view.learnedWord = newValue
            reshape()
        }
    }

    /// The capsule changed shape. It used to snap; now it springs there —
    /// the glass, the shadow and the clickable region following frame by
    /// frame — the way the paste card and the live line open. Growing
    /// overshoots a hair, shrinking settles without one, so the pill seems
    /// to open up to you and put itself away. Content-level only: the
    /// window never changes size (see panelSize).
    private func reshape() {
        let to = view.targetSize
        let from = view.shownSize ?? shapeTo
        shapeTo = to
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || panel.alphaValue == 0 || view.dragging
        guard from != to, !still else {
            shapeTimer?.invalidate()
            shapeTimer = nil
            view.shownSize = nil
            applyShape()
            return
        }
        shapeFrom = from
        shapeStart = CACurrentMediaTime()
        shapeGrows = to.width * to.height >= from.width * from.height
        if shapeTimer == nil {
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.stepShape() }
            RunLoop.main.add(t, forMode: .common)
            shapeTimer = t
        }
        stepShape()
    }

    /// Something the capsule's size depends on changed without a state
    /// change — the line opened, the countdown began.
    func refreshShape() {
        if view.targetSize != shapeTo { reshape() }
    }

    private var shapeTimer: Timer?
    private var shapeFrom = NSSize.zero
    private var shapeTo = NSSize.zero
    private var shapeStart: CFTimeInterval = 0
    private var shapeGrows = true

    private func stepShape() {
        let t = CACurrentMediaTime() - shapeStart
        let p = shapeGrows ? Pill.spring(t, stiffness: 230, damping: 21)
                           : Pill.spring(t, stiffness: 300, damping: 36)
        if t >= 0.8 {
            shapeTimer?.invalidate()
            shapeTimer = nil
            view.shownSize = nil
        } else {
            view.shownSize = NSSize(width: shapeFrom.width + (shapeTo.width - shapeFrom.width) * p,
                                    height: shapeFrom.height + (shapeTo.height - shapeFrom.height) * p)
        }
        applyShape()
    }

    /// A unit mass on a damped spring let go at 0, heading for 1: where it
    /// is `t` seconds later. 230/21 settles in about 0.45 s with a slight
    /// overshoot; 300/36 is critically damped and doesn't cross 1.
    static func spring(_ t: Double, stiffness k: Double, damping c: Double) -> CGFloat {
        let w0 = k.squareRoot()
        let zeta = c / (2 * w0)
        if zeta >= 1 {
            return CGFloat(1 - exp(-w0 * t) * (1 + w0 * t))
        }
        let wd = w0 * (1 - zeta * zeta).squareRoot()
        let decay = exp(-zeta * w0 * t)
        return CGFloat(1 - decay * (cos(wd * t) + zeta * w0 / wd * sin(wd * t)))
    }

    private func applyShape() {
        layoutBackdrop()
        view.needsDisplay = true
        panel.invalidateShadow()
        syncClickability()
    }

    // MARK: Resting fade

    /// At rest, untouched for five seconds, the pill fades most of the way
    /// back into the wallpaper; the pointer over it, or any state change,
    /// brings it straight back.
    private var restedSince = Date()
    private var faded = false

    /// "Hide the pill when idle" (Config.pillAutoHide): the same rest, but
    /// the fade goes all the way to nothing. The panel stays ordered in at
    /// full alpha — only the glass and content go — so the hover poll
    /// below still finds the pointer on the empty seat and brings it back.
    /// Cached: Config reads the .env file on every ask, and the poll asks
    /// eight times a second.
    private var autoHide = Config.shared.pillAutoHide
    /// Anything outside the pill that should keep a hiding pill out — a
    /// card, a notice, the menu, a Move. AppDelegate answers.
    var keepAwake: (() -> Bool)?
    /// A hidden pill isn't pressable until it has faded back in: a click
    /// on what looks like empty screen goes to the app underneath, and the
    /// hover that came before it is what reveals the pill.
    private var pressableAfter = Date.distantPast
    /// Faded to nothing (or on its way there) — not the 0.38 dim.
    private var hidden: Bool { faded && autoHide }

    private func setFaded(_ on: Bool) {
        if !on && hidden {
            pressableAfter = Date().addingTimeInterval(Motion.reduced ? 0 : 0.2)
        }
        faded = on
        let alpha: CGFloat = on ? (autoHide ? 0 : 0.38) : 1
        if autoHide && Motion.reduced {
            root.alphaValue = alpha
            panel.invalidateShadow()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            if autoHide {
                ctx.duration = on ? 0.35 : 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            } else {
                ctx.duration = on ? 0.6 : 0.18
            }
            root.animator().alphaValue = alpha
        }, completionHandler: { [weak self] in self?.panel.invalidateShadow() })
    }

    private func checkRest(pointerOver over: Bool) {
        let hover = over && state == .idle && !view.dragging
        if view.hovered != hover {
            view.hovered = hover
            refreshShape()
        }
        // Hiding, the pill also waits out everything of its own that's up.
        // A concealed panel counts: the speech card or the menu is standing
        // in for it, and the pill should be there when they hand it back,
        // not vanish the moment they go.
        let busy = autoHide && (panel.alphaValue == 0 || keepAwake?() == true)
        guard state == .idle, !over, !view.dragging, !busy else {
            restedSince = Date()
            if faded { setFaded(false) }
            return
        }
        if !faded, Date().timeIntervalSince(restedSince) >= 5 { setFaded(true) }
    }

    /// Settings flipped auto-hide. Back on screen either way, the rest
    /// clock restarting — on, it goes again five seconds from now.
    private func autoHideChanged() {
        let on = Config.shared.pillAutoHide
        guard on != autoHide else { return }
        if faded { setFaded(false) }   // under the old mode, so a hidden pill fades in
        autoHide = on
        restedSince = Date()
    }

    // MARK: Head-shake

    /// "No" in the language of a wrong password: a short damped wobble of
    /// the whole capsule. The hold hint wears it.
    func shake() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        shakeTimer?.invalidate()
        let start = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let e = CACurrentMediaTime() - start
            let dx = e >= 0.45 ? 0 : 7 * exp(-6.5 * e) * sin(2 * .pi * 7.5 * e)
            self.root.setFrameOrigin(NSPoint(x: CGFloat(dx), y: 0))
            if e >= 0.45 { timer.invalidate(); self.shakeTimer = nil }
        }
        RunLoop.main.add(t, forMode: .common)
        shakeTimer = t
    }
    private var shakeTimer: Timer?

    /// Which of the six screen seats the pill occupies — persisted in
    /// Config (PILL_POS), so it wakes up where you left it.
    var dock: PillDock {
        didSet {
            view.dock = dock
            // Crossing between a flat and an upright seat swaps the fixed
            // window between its two orientations — a one-off on a user
            // action, never one of the ticks the never-resize rule fears.
            let size = Pill.windowSize(for: dock)
            if panel.frame.size != size {
                panel.setFrame(NSRect(origin: panel.frame.origin, size: size), display: true)
            }
            reshape()   // the capsule moved to another window edge
        }
    }

    init(onClick: @escaping () -> Void) {
        dock = PillDock.saved(Config.shared.pillPosition)
        let initialSize = Pill.windowSize(for: dock)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: initialSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        // Screen-saver level — the system volume bezel's recipe. Status-bar
        // level windows ride the Space-switch animation and render
        // transition-scaled (tiny), sometimes staying stuck that way; this
        // level sits above the transition compositing entirely.
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // The window is bigger than the capsule (fixed size — see panelSize)
        // and its transparent margin must never eat a click meant for the app
        // underneath (a chat box sitting right above the pill, say). Ignore
        // the mouse except while the pointer is over the capsule itself.
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backdrop = PillView.glassBackdrop(cornerRadius: Pill.idleSize.height / 2)
        view = PillView(frame: NSRect(origin: .zero, size: initialSize))
        view.autoresizingMask = [.width, .height]
        view.onClick = onClick
        view.dock = dock
        root = NSView(frame: NSRect(origin: .zero, size: initialSize))
        root.autoresizingMask = [.width, .height]
        root.wantsLayer = true
        root.addSubview(backdrop)   // glass under, content on top
        root.addSubview(view)
        let host = NSView(frame: NSRect(origin: .zero, size: initialSize))
        host.autoresizingMask = [.width, .height]
        host.addSubview(root)
        panel.contentView = host
        shapeTo = view.targetSize
        layoutBackdrop()
        panel.orderFrontRegardless()
        // A mouse-ignoring window gets no tracking events to toggle back on,
        // so a cheap poll does it: one point-in-rect check per tick.
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            self?.syncClickability()
            self?.refreshShape()   // the countdown's arrival changes the shape on its own
        }
        hoverTimer?.tolerance = 0.05
        NotificationCenter.default.addObserver(forName: .sayctrlPillAutoHideChanged, object: nil,
                                               queue: .main) { [weak self] _ in self?.autoHideChanged() }
    }

    /// The glass sits exactly where the capsule for the current state is —
    /// a content-level change, invisible to the window server, so it can't
    /// glitch a running Space switch the way a window resize would.
    private func layoutBackdrop() {
        let r = view.capsuleRect
        if backdrop.frame != r { backdrop.frame = r }
        PillView.setGlassCorner(backdrop, min(r.width, r.height) / 2)
    }

    /// Clickable exactly over the visible capsule, click-through everywhere
    /// else in the fixed window frame.
    private func syncClickability() {
        // Mid-drag the panel must keep receiving the drag no matter where
        // the pointer sits relative to the (following) capsule.
        if view.dragging {
            if panel.ignoresMouseEvents { panel.ignoresMouseEvents = false }
            restedSince = Date()   // a long drag isn't rest: it mustn't fade on the drop
            return
        }
        let r = view.capsuleRect   // view fills the panel, same coordinates
        let screenRect = NSRect(x: panel.frame.origin.x + r.origin.x,
                                y: panel.frame.origin.y + r.origin.y,
                                width: r.width, height: r.height)
        // At rest the capsule is only 12 points tall, so the pointer counts as
        // over it a few points early — it swells under the pointer instead
        // of making you find a sliver.
        let slop: CGFloat = view.state == .idle ? 6 : 0
        let over = NSMouseInRect(NSEvent.mouseLocation, screenRect.insetBy(dx: -slop, dy: -slop), false)
        // Hidden, the pointer on the seat only reveals (checkRest); the
        // window takes clicks once the pill can be seen again.
        let pressable = over && !hidden && Date() >= pressableAfter
        if panel.ignoresMouseEvents == pressable { panel.ignoresMouseEvents = !pressable }
        checkRest(pointerOver: over)
    }

    var frame: NSRect { panel.frame }

    /// The visible capsule in screen coordinates — what popups anchor to.
    var capsuleFrame: NSRect {
        let r = view.capsuleRect
        return NSRect(x: panel.frame.origin.x + r.origin.x,
                      y: panel.frame.origin.y + r.origin.y,
                      width: r.width, height: r.height)
    }

    /// Mid-drag: the capsule rides under the pointer.
    func follow(mouse p: NSPoint) {
        let r = view.capsuleRect
        panel.setFrameOrigin(NSPoint(x: p.x - r.midX, y: p.y - r.midY))
    }

    func reposition(on screen: NSScreen) {
        guard !view.dragging else { return }   // the hand has it
        let origin = dock.aligned(size: panel.frame.size, in: screen.visibleFrame).origin
        // Only move when the target actually changed: repositioning on every
        // 0.4s tick re-inserts the panel into a running Space-switch
        // animation, where it renders transition-scaled (tiny) until the new
        // Space settles.
        if abs(panel.frame.origin.x - origin.x) > 0.5 || abs(panel.frame.origin.y - origin.y) > 0.5 {
            panel.setFrameOrigin(origin)
        }
    }
}

// MARK: - Transcript popup (the sun menu's Transcript / Polish / Email)

final class TranscriptPopup {
    private let panel: NSPanel
    private let card: NSView
    private let title: NSTextField
    private let scroll: NSScrollView
    private let textView: NSTextView
    private let copyButton: FirstMouseButton
    private(set) var isVisible = false
    /// What the card is showing right now — what Copy copies.
    private(set) var shownText = ""
    var onCopy: (() -> Void)?

    private let width: CGFloat = 340
    private let pad: CGFloat = 14

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 120),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .screenSaver   // same level as the pill — see Pill.init
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Same glass family as the pill, biased dark so the light ink reads.
        panel.appearance = NSAppearance(named: .darkAqua)

        card = NSView(frame: panel.contentView!.bounds)
        card.autoresizingMask = [.width, .height]
        let glass = PillView.glassBackdrop(cornerRadius: 14)
        glass.frame = card.bounds
        glass.autoresizingMask = [.width, .height]
        card.addSubview(glass)
        panel.contentView?.addSubview(card)

        title = NSTextField(labelWithString: "")

        textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        // The transcript is your writing, not UI — it wears the serif.
        textView.font = Theme.serifFont(13.5, .regular)
        textView.textColor = PillView.glassInk
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.documentView = textView

        copyButton = FirstMouseButton(title: "Copy", target: nil, action: nil)
        copyButton.bezelStyle = .rounded

        card.addSubview(title)
        card.addSubview(scroll)
        card.addSubview(copyButton)

        copyButton.target = self
        copyButton.action = #selector(copyClicked)
    }

    @objc private func copyClicked() { onCopy?() }

    func show(title titleText: String = "LAST TRANSCRIPT", text: String, near cap: NSRect) {
        shownText = text
        title.attributedStringValue = NSAttributedString(
            string: titleText,
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: PillView.glassMuted,
                .kern: 1.1,
            ])
        textView.string = text
        let textW = width - pad * 2
        let measured = (text as NSString).boundingRect(
            with: NSSize(width: textW - 6, height: 10_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: Theme.serifFont(13.5, .regular)]).height
        let textH = min(max(measured + 10, 26), 150)

        let buttonH: CGFloat = 26
        let titleH: CGFloat = 15
        let panelH = pad + buttonH + 8 + textH + 6 + titleH + 10

        copyButton.frame = NSRect(x: width - pad - 70, y: pad, width: 70, height: buttonH)
        scroll.frame = NSRect(x: pad, y: pad + buttonH + 8, width: textW, height: textH)
        textView.frame = NSRect(x: 0, y: 0, width: textW, height: textH)
        title.frame = NSRect(x: pad, y: pad + buttonH + 8 + textH + 6, width: textW, height: titleH)

        panel.setFrame(overlayFrame(size: NSSize(width: width, height: panelH), near: cap, gap: 10),
                       display: true)
        panel.orderFrontRegardless()
        isVisible = true
    }

    func repositionNear(capsule cap: NSRect) {
        panel.setFrameOrigin(overlayFrame(size: panel.frame.size, near: cap, gap: 10).origin)
    }

    func hide() {
        panel.orderOut(nil)
        isVisible = false
    }
}

// MARK: - Transient message bubble

final class HUD {
    /// Fixed window, for the same reason as the pill: only the glass card
    /// inside moves and resizes to the message — a window frame change
    /// landing mid Space-switch renders transition-scaled. Tall enough for
    /// the card plus the few points it travels as it arrives.
    private static let panelSize = NSSize(width: 560, height: 56)
    private static let cardH: CGFloat = 32
    private static let travel: CGFloat = 9
    private let panel: NSPanel
    private let card: NSView
    private let well: NSView
    private let iconView: NSImageView
    private let label: NSTextField
    private var hideTimer: Timer?

    /// Where the pill is and which seat it holds, so a notice rises out of
    /// it (pillOverlayFrame). nil, or a concealed pill (the speech card is
    /// fronting for it), puts the notice at the screen's foot as before.
    var anchor: (() -> (cap: NSRect, dock: PillDock)?)?

    /// The card's furniture: icon well, then the message.
    private static let wellSide: CGFloat = 22
    private static let padLeft: CGFloat = 5
    private static let gap: CGFloat = 8
    private static let padRight: CGFloat = 14
    private static let textLeft = padLeft + wellSide + gap

    /// What a notice's leading emoji meant, as a symbol and a colour. The
    /// call sites still write "⚠️ …", "🤷 …", "✓ …"; the HUD draws them as
    /// the pill's own badges instead of emoji.
    private struct Kind {
        let symbol: String?
        let tint: NSColor
    }
    private static let kinds: [(prefix: String, kind: Kind)] = [
        ("⚠️", Kind(symbol: "exclamationmark.triangle.fill", tint: PillView.amberBadge)),
        ("🤷", Kind(symbol: "questionmark", tint: PillView.quietBadge)),
        ("✓", Kind(symbol: "checkmark", tint: PillView.mossBadge)),
        ("⌫", Kind(symbol: "delete.left", tint: PillView.quietBadge)),
        ("❯", Kind(symbol: "terminal", tint: PillView.glassInk)),
        ("📸", Kind(symbol: "camera", tint: PillView.skyAction)),
        ("📁", Kind(symbol: "folder", tint: PillView.mossBadge)),
        ("🔗", Kind(symbol: "link", tint: PillView.lilacAction)),
    ]

    private var motionTimer: Timer?
    private var motionStart: CFTimeInterval = 0
    private var leaving = false
    private var rest = NSPoint.zero
    private var outward = CGVector(dx: 0, dy: 1)

    /// A notice is up (or arriving) — a hiding pill stays out for it, since
    /// the notice rises out of the pill.
    var isShowing: Bool { panel.isVisible && !leaving }

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .screenSaver   // same level as the pill — see Pill.init
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        // No scale-pop on orderFront: a Space switch makes the system re-order
        // this panel, and the default utility animation replays as a visible
        // shrink-and-regrow mid-dictation.
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)

        card = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: Self.cardH))
        card.wantsLayer = true
        let glass = PillView.glassBackdrop(cornerRadius: Self.cardH / 2)
        glass.frame = card.bounds
        glass.autoresizingMask = [.width, .height]
        card.addSubview(glass)

        well = NSView(frame: NSRect(x: Self.padLeft, y: (Self.cardH - Self.wellSide) / 2,
                                    width: Self.wellSide, height: Self.wellSide))
        well.wantsLayer = true
        well.layer?.cornerRadius = Self.wellSide / 2
        iconView = NSImageView(frame: well.bounds.insetBy(dx: 5, dy: 5))
        iconView.imageScaling = .scaleProportionallyUpOrDown
        well.addSubview(iconView)

        label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = PillView.glassInk
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: Self.textLeft, y: (Self.cardH - 17) / 2, width: 100, height: 17)

        card.addSubview(well)
        card.addSubview(label)
        panel.contentView?.addSubview(card)
    }

    func show(_ text: String, autohide: TimeInterval? = nil) {
        DispatchQueue.main.async {
            self.hideTimer?.invalidate()
            let (kind, message) = Self.kind(of: text)
            self.label.stringValue = message
            if let symbol = kind?.symbol, let tint = kind?.tint {
                let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
                    .applying(.init(paletteColors: [tint]))
                self.iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(cfg)
                self.iconView.frame = self.well.bounds.insetBy(dx: 5, dy: 5)
                self.well.layer?.backgroundColor = tint.withAlphaComponent(0.18).cgColor
            } else {
                // No news colour: the mark says who is talking.
                self.iconView.image = Theme.mark(14, inkColor: PillView.glassInk)
                self.iconView.frame = self.well.bounds.insetBy(dx: 4, dy: 4)
                self.well.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
            }
            // The card sizes to the message; the window stays as it is.
            let measured = ceil((message as NSString).size(withAttributes: [.font: self.label.font!]).width)
            let chrome = Self.textLeft + Self.padRight
            let width = min(max(measured + chrome, 120), Self.panelSize.width - 2 * Self.travel)
            self.label.frame.size.width = width - chrome

            // Out of the pill when there is one to come out of.
            let size = NSSize(width: width, height: Self.cardH)
            let target: NSRect
            if let a = self.anchor?() {
                target = pillOverlayFrame(size: size, from: a.cap, dock: a.dock, gap: 8)
                self.outward = a.dock.outward
            } else {
                let f = mouseScreen().visibleFrame
                target = NSRect(x: f.midX - width / 2, y: f.minY + 76, width: width, height: Self.cardH)
                self.outward = CGVector(dx: 0, dy: 1)
            }
            // Place the window so the card's resting spot is `target`, with
            // room to travel, and the window itself on the screen.
            let (origin, local) = placePanel(Self.panelSize, card: target)
            let wasVisible = self.panel.isVisible && !self.leaving
            let moved = abs(self.panel.frame.origin.x - origin.x) > 0.5 || abs(self.panel.frame.origin.y - origin.y) > 0.5
            if moved { self.panel.setFrameOrigin(origin) }
            self.rest = local
            self.card.frame = NSRect(origin: self.card.frame.origin, size: size)
            self.panel.invalidateShadow()   // shadow follows the card, not the window
            self.panel.orderFrontRegardless()
            // A notice replacing one already up just changes its words; a new
            // one rises out of the pill.
            if wasVisible && !moved && local == self.card.frame.origin {
                self.card.setFrameOrigin(local)
                self.card.alphaValue = 1
            } else {
                self.leaving = false
                self.startMotion()
            }
            // Ordering front is not always enough. Measured 2026-08-21: a
            // 40-minute-old process kept calling show() — the live preview,
            // "No speech detected", everything — and the window server never
            // put the panel back on screen, while the pill (ordered in once at
            // launch and never taken out) stayed perfectly visible. Relaunching
            // was the only cure, and nothing in the log said a word about it.
            //
            // So: confirm it landed. Only the FIRST frame of a bubble pays for
            // the check, and it waits a runloop turn first, because the window
            // server needs one before it reports the window at all (measured:
            // false inline, true by 20 ms).
            if !wasVisible {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.confirmOnScreen() }
            }
            if let t = autohide {
                self.hideTimer = Timer.scheduledTimer(withTimeInterval: t, repeats: false) { _ in
                    self.leave()
                }
            }
        }
    }

    /// The leading emoji, read as a kind, and the words without it.
    private static func kind(of text: String) -> (Kind?, String) {
        for (prefix, kind) in kinds where text.hasPrefix(prefix) {
            let rest = text.dropFirst(prefix.count).drop { $0 == " " || $0 == "\u{FE0F}" }
            return (kind, String(rest))
        }
        return (nil, text)
    }

    // MARK: Motion

    /// In on a light spring from a few points back toward the pill; out
    /// with a short fade that keeps drifting the same way.
    private func startMotion() {
        motionStart = CACurrentMediaTime()
        if motionTimer == nil {
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.stepMotion() }
            RunLoop.main.add(t, forMode: .common)
            motionTimer = t
        }
        stepMotion()
    }

    private func stepMotion() {
        let t = CACurrentMediaTime() - motionStart
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var alpha: CGFloat, along: CGFloat
        if leaving {
            let e = CGFloat(min(1, t / 0.2))
            alpha = 1 - e
            along = still ? 0 : e * 4
        } else {
            alpha = CGFloat(min(1, t / 0.14))
            along = still ? 0 : -(1 - Pill.spring(t, stiffness: 260, damping: 20)) * Self.travel
        }
        card.alphaValue = alpha
        card.setFrameOrigin(NSPoint(x: rest.x + outward.dx * along, y: rest.y + outward.dy * along))
        panel.invalidateShadow()
        let done = leaving ? t >= 0.2 : t >= 0.6
        if done {
            motionTimer?.invalidate()
            motionTimer = nil
            if leaving {
                leaving = false
                panel.orderOut(nil)
            }
        }
    }

    private func leave() {
        guard panel.isVisible, !leaving else { return }
        leaving = true
        startMotion()
    }

    /// Did the window server actually take the panel? `isVisible` says what
    /// AppKit believes, which in the failure above stayed true while nothing
    /// was drawn, so this asks the window server itself.
    private static func isOnScreen(_ window: NSWindow) -> Bool {
        guard window.windowNumber > 0,
              let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        for entry in list where (entry[kCGWindowNumber as String] as? Int) == Int(window.windowNumber) {
            return (entry[kCGWindowIsOnscreen as String] as? Bool) ?? false
        }
        return false
    }

    /// The re-assertion, plus a log line either way. The line is the point:
    /// the failure used to be silent, and a silent overlay is
    /// indistinguishable from a transcriber that stopped working.
    ///
    /// `isVisible` true while the window server says otherwise is the exact
    /// signature of a window ordered in on a Space you are not looking at, so
    /// the all-Spaces membership is restated before the window goes off and
    /// back on — a panel that lost it would show up on the Space it was first
    /// ordered onto and nowhere else, for the rest of the run.
    private func confirmOnScreen() {
        // Hidden again in the meantime (an autohide fired, a screenshot took
        // the screen) is not a failure — there is nothing to put back.
        guard panel.isVisible, !Self.isOnScreen(panel) else { return }
        Config.shared.log("HUD: show() left the panel off screen — isVisible=\(panel.isVisible) "
            + "screen=\(panel.screen?.localizedName ?? "nil") alpha=\(panel.alphaValue) "
            + "behavior=\(panel.collectionBehavior.rawValue) "
            + "appHidden=\(NSApp.isHidden) policy=\(NSApp.activationPolicy().rawValue)")
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.orderOut(nil)
        panel.orderFrontRegardless()
        // Same runloop-turn rule as above — asking right now would always
        // report a miss and turn a fix into a false alarm in the log.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self else { return }
            Config.shared.log("HUD: re-asserted — on screen now: \(Self.isOnScreen(self.panel))")
        }
    }

    /// `immediately` is for a screenshot about to be taken: no fade for
    /// the camera to catch.
    func hide(immediately: Bool = false) {
        DispatchQueue.main.async {
            self.hideTimer?.invalidate()
            guard immediately else { return self.leave() }
            self.motionTimer?.invalidate()
            self.motionTimer = nil
            self.leaving = false
            self.panel.orderOut(nil)
        }
    }

    /// Re-assert the panel after a Space switch, dropping any transition
    /// transform the window server left on it.
    func refresh() {
        DispatchQueue.main.async {
            if self.panel.isVisible { self.panel.orderFrontRegardless() }
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var hud = HUD()
    /// The live transcript, unfolding out of the pill's seat — the HUD
    /// strip's replacement for dictation (the HUD keeps the notices).
    let speechCard = SpeechCard()
    /// The live take's words in the pill itself (Config.liveWords "line"),
    /// and the toast that rises from the pill when a spoken action lands.
    let pillLine = PillLine()
    let actionToast = PillToast()
    var pill: Pill!
    var popup = TranscriptPopup()
    let attachPicker = AttachPicker()
    let dockPicker = DockPicker()
    let sunMenu = SunMenu()
    /// One Polish/Email rewrite at a time — the Cerebras key is 5 req/min.
    var rewriteBusy = false
    var state: AppState = .idle
    var recorder: AVAudioRecorder?
    /// The dictation being recorded right now: the id its history row will
    /// carry, and — in live mode, where nothing else touches the disk — the
    /// tape catching the frames on their way to the socket.
    var clipID = HistoryEntry.newID()
    var clipTape: AudioTape?
    /// Non-nil only in live mode — it replaces `recorder` for that dictation.
    /// Either a socket to a provider or the on-device model re-reading the
    /// utterance; the difference stops mattering past this point.
    var live: (any LiveSession)?
    var liveStartedAt = Date()
    /// The live session when it is a SayControl cloud take — reported to
    /// the server however it ends.
    var cloudEar: LiveTranscriber?
    /// Whether the take in hand runs on the cloud, for the history's model name.
    var takeOnCloud = false
    /// This take is one of Free's extra takes: recorded whole, sent to the
    /// server's upload model when you let go.
    var takeIsExtra = false
    /// When the live transcript last changed: a hands-free take with nothing
    /// new for HANDS_FREE_IDLE_SECONDS stops itself.
    var lastLiveText = ""
    var lastHeardAt = Date()
    var idleTimer: Timer?
    var fnMonitor: Any?
    /// Key presses, for a dictate key that is an F-key and for the
    /// hands-free combo; the modifier keys come through the flags monitors.
    var keyMonitor: Any?
    var keyLocalMonitor: Any?
    /// The HID tap and the monitors both hear a press; the hands-free toggle
    /// must fire once, so the last press acted on is remembered by its time.
    var lastHandsFreePress: TimeInterval = 0
    /// Events land here instead of the global monitor while one of SayCtrl's
    /// own windows is in front — the onboarding's "say something" box, say.
    var fnLocalMonitor: Any?
    var fnTap: CFMachPort?
    /// True when the tap is active and can keep a key from the app in front;
    /// false for the listen-only stand-in made before Accessibility landed.
    var fnTapSwallows = false
    var fnTapSource: CFRunLoopSource?
    var fnIsDown = false
    /// The dictate key whose press is holding the recording open — the one
    /// whose release ends it, with several keys bound.
    var heldDictate: KeyShortcut?
    /// The hands-free chord whose modifiers are still down after it fired.
    var firedChord: KeyShortcut?
    /// Set by the onboarding's key step: fn goes here instead of starting a
    /// dictation, so the user can try the gesture with nothing riding on it.
    var fnProbe: ((Bool) -> Void)?
    /// This recording was opened by the fn press currently down, so its release
    /// is what ends it. False for a hands-free session started from the menu.
    var startedByThisPress = false
    /// Consecutive animation ticks that found fn no longer held while a
    /// hold-to-talk recording was still open — see the watchdog in startAnim().
    var fnReleaseTicks = 0
    /// This recording has seen the live flags report fn held at least once,
    /// so their word can be trusted when they stop reporting it.
    var fnFlagSeen = false
    /// Control was held when fn went down — the next recording is a spoken
    /// INSTRUCTION for command mode, not words to paste.
    var commandArmed = false
    /// What that instruction acts on, captured the moment recording starts —
    /// the selection or field the user was looking at (see CommandMode.swift).
    var pendingCommand: CommandTarget?
    /// A terminal was in front when this recording started, so the words may
    /// be a shell command (Shell.swift). Captured at press for the same reason
    /// command mode captures its target then: the app you are TALKING INTO is
    /// the one that decides, whatever ends up frontmost by the time the
    /// transcript comes back.
    var shellArmed = false
    var maxLenTimer: Timer?
    var animTimer: Timer?
    var screenTimer: Timer?
    var clipboardRestoreWork: DispatchWorkItem?
    /// Live mode grabs a screenshot the moment you SAY the command — one per
    /// command — so each picture shows the screen you were on then, not
    /// wherever the cursor ends up when the paste lands. Held here until
    /// finishTranscription pairs them with the text runs around each command.
    var pendingShots: [Data] = []
    var pendingShotCapturing = false
    let shotCaptureGroup = DispatchGroup()
    /// Same idea for "copy the file path": the Finder selection is sampled
    /// the moment you SAY it — one batch of paths per command — so you get
    /// what was selected then, even if you click elsewhere while talking.
    var pendingPathBatches: [[String]] = []
    var pendingPathSampling = false
    var pathSampleFailedLive = false
    let pathSampleGroup = DispatchGroup()
    /// And for "copy the link": the frontmost browser tab's address is read
    /// the moment you SAY it — one URL per command — so you get the page
    /// you were on then, even if you keep browsing while talking.
    var pendingURLs: [String] = []
    var pendingURLSampling = false
    var urlSampleFailedLive = false
    let urlSampleGroup = DispatchGroup()
    /// "attach the image…" resolves while you SAY it, so the picker floats
    /// up mid-dictation and "the first one" works in the same breath. The
    /// spoken command grows across stream deltas ("upload image" → "…from
    /// desktop folder"), so resolution waits for it to hold still, and
    /// re-runs when it grows. The chosen file waits for the finish paste.
    var pendingAttachURL: URL?
    var liveAttachCmd: AttachCommand?
    var liveAttachTimer: Timer?
    var liveAttachResolving = false
    var lastTranscript = ""
    /// Exactly what the last pasteText put at the cursor — what "scratch
    /// that" will backspace over. Only the final text run of a multi-part
    /// paste; screenshots and attachments are not scratchable.
    var lastPasted = ""
    /// A trailing "…and send it" was spoken: pasteText presses Return once
    /// its paste has landed.
    var sendAfterPaste = false
    /// The attachment paste of this dictation, queued behind the words:
    /// the paste pipeline fires it the moment its last ⌘V is done.
    var attachAfterPaste: (() -> Void)?
    /// The queued attachment's file name, when it's known before the
    /// paste — for the paste card's chip if the words find no text box.
    var attachAfterPasteName: String?
    /// What the clipboard held before this dictation's pastes — the value
    /// a queued restore owes it, so a follow-on attachment paste restores
    /// the user's clipboard, not our own text.
    var clipboardToRestore: String?
    var infoMenuItem: NSMenuItem!
    var cleanupMenuItem: NSMenuItem!
    var autoLearnMenuItem: NSMenuItem!
    var agentVoiceMenuItem: NSMenuItem!
    var learnedTimer: Timer?
    let watcher = CorrectionWatcher()

    let audioURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sayctrl.wav")

    // MARK: - Config / logging (all state lives in Config.shared)

    func apiKey() -> String? { Config.shared.apiKey }

    /// Why polish or a command cannot run right now, for the HUD. A user is
    /// told what buys it; a developer, which box to fill.
    var noPolishReason: String {
        Config.retail && Config.shared.cloudOn
            ? "AI polish comes with SayControl cloud — switch it back on in Settings › Models"
            : "Needs a polish key — add one in Settings › Models"
    }
    func modelName() -> String { takeOnCloud ? "SayControl cloud" : Config.shared.model }
    func log(_ msg: String) { Config.shared.log(msg) }
    var cleanupEnabled: Bool { Config.shared.cleanup }
    var autoLearnEnabled: Bool { Config.shared.autoLearn }

    func playSound(_ name: String) {
        guard Config.shared.sounds else { return }
        NSSound(named: name)?.play()
    }

    // MARK: - Lifecycle

    /// ggml's Metal device is torn down by a C++ static destructor on the way
    /// out. A whisper, parakeet or cohere context still holding it crashes there, so
    /// the model is released while there is still a running app to release it.
    /// saycontrol://auth, from the website's page at the end of signing in
    /// with Google in the browser.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where !Cloud.shared.handleURL(url) {
            Config.shared.log("Opened with a link that isn't ours: \(url.scheme ?? "?")://")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AgentBridge.shared.stop()
        LocalEngine.shared.unload()
    }

    /// A take found Accessibility off and opened the Permissions page.
    private static var sentToPermissions = false

    /// The open-application event macOS sends a login item says so. Read at
    /// launch, while that event is still the current one.
    static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // First, while the launch event is still the current one.
        let openedAtLogin = Self.launchedAsLoginItem
        // The screenshot runs draw and quit. They start no updater — a bare
        // binary outside a bundle has no feed, and Sparkle says so in a modal
        // "Unable to Check for Updates" that someone has to click away — and
        // load no model, so several can run side by side.
        // --guide-preview is the same kind of run: Set Up's tray and nothing else.
        let shooting = ["--snapshot", "--windowshot", "--onboardingshot", "--guide-preview", "--modelsshot", "--localbench", "--polishcheck"]
            .contains { CommandLine.arguments.contains($0) }
        // Touching the controller starts the updater; it checks the feed on
        // its own schedule from here.
        if !shooting { _ = Updates.controller }
        LocalEngine.shared.migrateSelection()
        // Local dictation should be instant on the first hold of fn, not after
        // a multi-second model load.
        // A user's copy loads one only when it dictates on this Mac.
        if !shooting && (!Config.retail || Config.shared.transcriptionSource == .mac) { LocalEngine.shared.warmUp() }
        // Whatever the last run left open on the cloud is closed, and the
        // first take's token fetched, before anyone presses fn.
        if !shooting { Cloud.shared.launch() }
        // The daily totals rebuild themselves from the log the first time they
        // are asked for. Doing it now keeps that off the first dictation.
        DispatchQueue.global(qos: .utility).async { _ = StatsStore.shared }
        Theme.scale = CGFloat(Config.shared.fontScale)
        Config.shared.applyAppearance()
        Shortcuts.load()   // before any pane is built, the snapshots' included
        if runSnapshotsIfRequested() || runWindowShotsIfRequested() || runOnboardingShotsIfRequested()
            || runModelsShotsIfRequested() || runLocalBenchIfRequested() || runPolishCheckIfRequested() {
            // Straight out, past the C++ destructors: ggml's Metal teardown
            // aborts when the app quits moments after launch, and a
            // screenshot run has nothing to save on the way out.
            _exit(0)
        }
        if runGuidePreviewIfRequested() { return }
        if !claimSingleInstance() { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setStatusIcon("🎤")
        buildMenu()

        pill = Pill(onClick: { [weak self] in self?.pillClicked() })
        // Notices rise out of the pill, wherever it sits — unless another
        // surface is fronting for it, when they keep to the screen's foot.
        hud.anchor = { [weak self] in
            guard let self = self, !self.pillConcealed else { return nil }
            return (self.pill.capsuleFrame, self.pill.dock)
        }
        // A hiding pill stays out while anything of its own is up: a take,
        // fn held, a card, a notice, the menu, a Move half done.
        pill.keepAwake = { [weak self] in
            guard let self = self else { return false }
            return self.state != .idle || self.fnIsDown || PillMenu.shared.isOpen
                || PasteCard.shared.isVisible || self.speechCard.isVisible || self.hud.isShowing
                || self.popup.isVisible || self.attachPicker.isVisible
                || self.sunMenu.isVisible || self.dockPicker.isVisible
        }
        pill.view.onDragBegan = { [weak self] in self?.pillDragBegan() }
        pill.view.onDragMoved = { [weak self] p in self?.pillDragMoved(to: p) }
        pill.view.onDragEnded = { [weak self] p in self?.pillDragEnded(at: p) }
        sunMenu.onAction = { [weak self] action in self?.sunMenuAction(action) }
        repositionUI()
        screenTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.repositionUI()
        }
        // Once a Space switch settles, re-assert the overlays: a panel that
        // was composited into the animation can otherwise stay stuck at
        // transition scale until something reorders it.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.pill.panel.orderFrontRegardless()
            self.hud.refresh()
            self.attachPicker.refresh()
            self.sunMenu.refresh()   // after the pill, so the menu stays on top of it
            self.repositionUI()
        }

        // First run: the permissions are asked for on the onboarding's own
        // step, each with a line of why, instead of two system dialogs landing
        // on a window nobody has read yet.
        // Quiet when the login item opened us (or the old LaunchAgent's flag).
        let background = CommandLine.arguments.contains("--background") || openedAtLogin
        Config.shared.removeLegacyLaunchAgent()
        Config.shared.clearWordsFromOldLog()
        Config.shared.settleRoutesFromCloudOnly()
        // Signed out, the welcome is the only way in: it is the sign-in.
        // Set up once, but a required switch is off now (a reinstall that
        // came with a new signature, or a switch turned off in System
        // Settings): the setup opens on its switches again, rather than the
        // key failing with no word of why.
        let grantsMissing = Onboarding.done && !Onboarding.forced
            && (Permissions.microphone != .granted || Permissions.accessibility != .granted)
        let onboarding = (Onboarding.due || Account.required || grantsMissing) && !background
        if onboarding {
            log("Launched. First run — onboarding. Accessibility trusted: \(AXIsProcessTrusted()). Model: \(modelName())")
        } else {
            let axOpts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            let trusted = AXIsProcessTrustedWithOptions(axOpts)
            log("Launched. Accessibility trusted: \(trusted). Model: \(modelName())")

            AVCaptureDevice.requestAccess(for: .audio) { granted in
                self.log("Microphone access granted: \(granted)")
            }
        }

        NotificationCenter.default.addObserver(forName: Shortcuts.changed, object: nil, queue: .main) { [weak self] _ in
            self?.infoMenuItem.title = self?.infoTitle ?? ""
            self?.fnIsDown = false
            self?.heldDictate = nil
            self?.firedChord = nil
            self?.restartFnTapIfNeeded()   // a combo needs an active tap; fn does not
        }
        fnMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.handleKey(event)
        }
        keyLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.handleKey(event)
            return event
        }
        // The global monitor hears every app but this one. Dictating into
        // SayCtrl's own window — the first dictation of all happens there —
        // needs the local one too; the fnIsDown guard drops the duplicate.
        fnLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }
        // The monitor above goes deaf while macOS animates a Space switch; a
        // listen-only HID tap still hears fn there. Both run — duplicate
        // events are dropped by the fnIsDown guard in handleFlagsChanged.
        startFnTap()

        watcher.onEdit = { [weak self] fixes, original, edited in
            self?.learned(fixes, original: original, edited: edited)
        }

        // The polish cache must speak the same text the paste pipeline will ask
        // about, so it cleans and dictionary-applies its chunks the same way.
        Refiner.shared.canonicalize = { [weak self] text in
            guard let self = self else { return text }
            return ReplacementStore.shared.apply(to: self.cleanTranscript(text))
        }

        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
                                               name: .owSettingsChanged, object: nil)
        // The agent voice: the hooks of Claude Code and Codex both reach a
        // loopback port when a session finishes or needs an answer
        // (AgentBridge.swift, CodexBridge.swift).
        AgentBridge.shared.apply()

        ReplacementStore.shared.demoteRealWordRules()
        let ruleCount = ReplacementStore.shared.rules.count
        if ruleCount > 0 { log("Loaded \(ruleCount) replacement rule(s)") }

        // Only the developers' build can be keyless: a user's copy transcribes
        // on this Mac, and the onboarding fetched the model for it.
        if apiKey() == nil && !onboarding && !Config.retail {
            hud.show("⚠️ No API key — add one in the window that just opened", autohide: 3)
        }

        // Show the window on launch so the app is never just an invisible menu-bar
        // icon. Skipped when macOS opens us at login, where stealing focus
        // would be rude.
        if onboarding {
            OnboardingWindow.shared.present(at: grantsMissing && Account.signedIn ? 1 : nil)
        } else if !background {
            let pane = CommandLine.arguments.firstIndex(of: "--settings").flatMap { i in
                CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : nil
            }
            SettingsUI.shared.present(selecting: pane ?? "overview")
        }
    }

    /// Two copies of SayCtrl at once means two menu-bar icons, two pills and
    /// every fn press answered twice. A copy that finds another running, from
    /// any path, asks which of the two should live; the other is quit.
    func claimSingleInstance() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        let id = Bundle.main.bundleIdentifier ?? "com.sayctrl.app"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != me }
        guard let other = others.first else { return true }
        let otherURL = other.bundleURL
        let otherPath = otherURL?.deletingLastPathComponent().path ?? "another folder"
        let myPath = Bundle.main.bundleURL.deletingLastPathComponent().path
        // A copy whose bundle is gone (dragged to the Trash while it ran) or
        // that was launched from this very path is a leftover, not a choice:
        // it is replaced without asking.
        let ghost = otherURL.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true
        let samePlace = otherURL?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
        var takeOver = ghost || samePlace
        if !takeOver {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "SayControl is already open"
            alert.informativeText = "A copy is running from \(otherPath). This one is in \(myPath). Only one can listen for fn at a time."
            alert.addButton(withTitle: "Quit that one, open this")
            alert.addButton(withTitle: "Keep that one")
            takeOver = alert.runModal() == .alertFirstButtonReturn
        }
        guard takeOver else {
            other.activate(options: [.activateIgnoringOtherApps])
            NSApp.terminate(nil)
            return false
        }
        // Wait for them to go, so their menu-bar icon and fn monitors are
        // gone before ours arrive; a copy that will not quit is made to.
        for app in others { app.terminate() }
        let deadline = Date().addingTimeInterval(2.5)
        while others.contains(where: { !$0.isTerminated }) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        for app in others where !app.isTerminated { app.forceTerminate() }
        log("Took over from another copy at \(otherPath)\(ghost ? " (its bundle was gone)" : "")")
        return true
    }

    @objc func settingsChanged() {
        cleanupMenuItem.state = cleanupEnabled ? .on : .off
        autoLearnMenuItem.state = autoLearnEnabled ? .on : .off
        agentVoiceMenuItem.state = Config.shared.agentVoice ? .on : .off
        AgentBridge.shared.apply()
    }

    /// The menu bar item: the app mark in a 16pt rounded tile, drawn from the
    /// one grid in Theme (Theme.drawMarkTile). Only the menu bar gets the tile;
    /// the Dock icon and Theme.mark stay the bare mark.
    ///
    /// Idle is a template image with the mark knocked out of a solid tile, so
    /// macOS tints the tile to the menu bar's own colour and the bar shows
    /// through the mark — right in dark mode, on a tinted wallpaper and under
    /// Reduce Transparency. A colour is only passed to say something is
    /// happening: then the tile is that colour with the mark in white on it
    /// (ember while listening, grey while transcribing), which is what makes
    /// "it is listening" readable at a glance.
    func makeStatusImage(color: NSColor?) -> NSImage {
        let img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            Theme.drawMarkTile(in: rect, tile: color ?? .black, mark: color == nil ? nil : .white)
            return true
        }
        img.isTemplate = (color == nil)
        return img
    }

    lazy var iconIdle = makeStatusImage(color: nil)
    lazy var iconRecording = makeStatusImage(color: Theme.ember)
    lazy var iconTranscribing = makeStatusImage(color: .systemGray)

    func setStatusIcon(_ s: String) {
        DispatchQueue.main.async {
            guard let button = self.statusItem.button else { return }
            button.title = ""
            switch s {
            case "🔴": button.image = self.iconRecording
            case "✨": button.image = self.iconTranscribing
            default: button.image = self.iconIdle
            }
        }
    }

    /// The menu bar menu: which key to hold, the main window, the three
    /// switches people actually flip, and Quit. Everything else lives in the
    /// main window. Each row carries an SF Symbol so it reads at a glance.
    func buildMenu() {
        let menu = NSMenu()
        let info = NSMenuItem(title: infoTitle, action: nil, keyEquivalent: "")
        info.isEnabled = false
        info.image = menuSymbol("mic.fill")
        infoMenuItem = info
        menu.addItem(info)
        menu.addItem(.separator())
        let openItem = NSMenuItem(title: "Open SayControl", action: #selector(menuSettings), keyEquivalent: "")
        openItem.target = self
        openItem.image = menuSymbol("macwindow")
        menu.addItem(openItem)
        menu.addItem(.separator())
        cleanupMenuItem = menuSwitch("Clean Up Speech", subtitle: "Drops fillers and stutters",
                                     symbol: "wand.and.stars", action: #selector(menuToggleCleanup), on: cleanupEnabled)
        menu.addItem(cleanupMenuItem)
        autoLearnMenuItem = menuSwitch("Learn My Corrections", subtitle: "Remembers words you fix",
                                       symbol: "brain", action: #selector(menuToggleAutoLearn), on: autoLearnEnabled)
        menu.addItem(autoLearnMenuItem)
        agentVoiceMenuItem = menuSwitch("Agent Voice", subtitle: "Claude Code and Codex speak to you",
                                        symbol: "speaker.wave.2.fill", action: #selector(menuToggleAgentVoice), on: Config.shared.agentVoice)
        menu.addItem(agentVoiceMenuItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit SayControl", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.image = menuSymbol("power")
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    func menuSymbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    /// A checkmark row with an icon; the subtitle shows under the title where
    /// macOS supports it (14.4+) and as the tooltip everywhere.
    func menuSwitch(_ title: String, subtitle: String, symbol: String, action: Selector, on: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = menuSymbol(symbol)
        item.state = on ? .on : .off
        item.toolTip = subtitle
        if #available(macOS 14.4, *) { item.subtitle = subtitle }
        return item
    }

    // MARK: - Pill UI

    func repositionUI() {
        // Mid-drag or mid-pick the pill is the user's, not the timer's; and
        // while the sun menu is open the pill must not teleport out from
        // under it when the mouse visits another screen.
        guard !pill.view.dragging, !dockPicker.isVisible, !sunMenu.isVisible, !PillMenu.shared.isOpen else { return }
        let screen = mouseScreen()
        pill.reposition(on: screen)
        if popup.isVisible { popup.repositionNear(capsule: pill.capsuleFrame) }
        if attachPicker.isVisible { attachPicker.reposition(near: pill.capsuleFrame, dock: pill.dock) }
    }

    func pillClicked() {
        switch state {
        case .recording:
            stopAndTranscribe()
        case .transcribing:
            break
        case .idle:
            // The card with the last transcript, the scratchpad and a
            // hands-free take (PillMenu) — the sun menu's successor.
            if pill.state == .attention || pill.state == .needsAccess { pill.state = .idle }
            popup.hide()
            sunMenu.hide()
            PillMenu.shared.toggle(host: self)
        }
    }

    // MARK: - Moving the pill (drag, or the sun menu's Move)

    func pillDragBegan() {
        popup.hide()
        sunMenu.hide()
        dockPicker.show(on: mouseScreen(), current: pill.dock)
    }

    func pillDragMoved(to p: NSPoint) {
        pill.follow(mouse: p)
        // Crossing onto another display drags the slot map along.
        if !NSPointInRect(p, dockPicker.frame) {
            dockPicker.show(on: mouseScreen(), current: pill.dock)
        }
        dockPicker.highlight(nearestTo: p)
    }

    func pillDragEnded(at p: NSPoint) {
        let dock = dockPicker.dock(at: p) ?? pill.dock   // a wild drop keeps the old seat
        dockPicker.hide()
        setPillDock(dock)
    }

    func setPillDock(_ dock: PillDock) {
        pill.dock = dock
        Config.shared.pillPosition = dock.rawValue
        pill.reposition(on: mouseScreen())
        if popup.isVisible { popup.repositionNear(capsule: pill.capsuleFrame) }
        if attachPicker.isVisible { attachPicker.reposition(near: pill.capsuleFrame, dock: pill.dock) }
        log("Pill docked: \(dock.rawValue)")
    }

    // MARK: - Sun menu actions

    func sunMenuAction(_ action: SunMenu.Action) {
        sunMenu.hide()
        switch action {
        case .close:
            break
        case .transcript:
            guard !lastTranscript.isEmpty else { return hud.show("Nothing dictated yet", autohide: 1.2) }
            popup.onCopy = { [weak self] in self?.copyPopupText() }
            popup.show(text: lastTranscript, near: pill.capsuleFrame)
        case .polish:
            rewriteLastTranscript(
                instruction: "Polish this text: fix grammar, punctuation, and phrasing without changing the meaning or the language.",
                title: "POLISHED", progress: "✨ Polishing…")
        case .email:
            rewriteLastTranscript(
                instruction: "Write this as a polite, ready-to-send email with a greeting and a sign-off.",
                title: "EMAIL DRAFT", progress: "✉️ Drafting an email…")
        case .move:
            dockPicker.choose(on: pill.panel.screen ?? mouseScreen(), current: pill.dock) { [weak self] dock in
                guard let self = self, let dock = dock else { return }
                self.setPillDock(dock)
            }
        }
    }

    /// The sun menu's Polish / Email: run the last transcript through the
    /// command model and show the result in the popup, Copy included —
    /// nothing is pasted, the user decides where it goes.
    func rewriteLastTranscript(instruction: String, title: String, progress: String) {
        guard !lastTranscript.isEmpty else { return hud.show("Nothing dictated yet", autohide: 1.2) }
        guard Config.shared.hasModelAccess else {
            return hud.show("⚠️ \(noPolishReason)", autohide: 2.5)
        }
        guard !rewriteBusy else { return hud.show("Still working on the last one…", autohide: 1.4) }
        rewriteBusy = true
        if state == .idle {
            pill.state = .transcribing
            startAnim()
        }
        hud.show(progress, autohide: 1.6)
        log("Pill menu: \(title.lowercased()) on \(lastTranscript.count) chars")
        Refiner.shared.command(instruction, text: lastTranscript) { [weak self] result in
            guard let self = self else { return }
            self.rewriteBusy = false
            // Only settle the pill if a real dictation hasn't taken it over.
            if self.state == .idle && self.pill.state == .transcribing {
                self.stopAnim()
                self.pill.state = .idle
            }
            switch result {
            case .success(let out):
                self.popup.onCopy = { [weak self] in self?.copyPopupText() }
                self.popup.show(title: title, text: out, near: self.pill.capsuleFrame)
            case .failure(let error):
                self.hud.show("⚠️ \(error.localizedDescription)", autohide: 2.5)
                self.playSound("SayCtrlMiss")
            }
        }
    }

    /// Copy whatever the popup is showing — the raw transcript, or a
    /// Polish/Email rewrite of it.
    func copyPopupText() {
        let text = popup.shownText.isEmpty ? lastTranscript : popup.shownText
        clipboardRestoreWork?.cancel()
        clipboardRestoreWork = nil
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        popup.hide()
        if pill.state == .attention { pill.state = .idle }
        hud.show("✓ Copied", autohide: 1)
        log("Popup text copied")
    }

    func startAnim() {
        animTimer?.invalidate()
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.checkFnStillHeld()
            if self.state == .recording, let rec = self.recorder {
                rec.updateMeters()
                let db = CGFloat(rec.averagePower(forChannel: 0))
                self.pill.view.level = max(0, min(1, (db + 50) / 45))
            }
            self.pill.view.phase += 0.30
            // A concealed pill (the speech card or the agent foot is
            // fronting for it) skips its redraws entirely — no need to
            // rebuild text lines for a window nobody can see.
            if self.pill.panel.alphaValue > 0 { self.pill.view.needsDisplay = true }
            // The same heartbeat drives every copy of the bars: the pill,
            // the speech card's header, the agent card's foot.
            if self.speechCard.isVisible {
                self.speechCard.setLevel(self.pill.view.level, phase: self.pill.view.phase)
            }
            AgentPanel.shared.tickFoot(level: self.pill.view.level, phase: self.pill.view.phase)
        }
    }

    /// The pill goes invisible while another surface carries its bars —
    /// the speech card during a live dictation, the agent card's foot
    /// while the agent listens. One flag, so a screenshot's own hide-and-
    /// restore can't resurrect it mid-episode (captureCursorScreenAsync).
    private(set) var pillConcealed = false
    func concealPill(_ on: Bool) {
        guard pillConcealed != on else { return }
        pillConcealed = on
        applyPillAlpha()
    }

    /// The pill menu grows out of the pill and stands in for it while it's
    /// open — a separate switch from the conceal flag, so a take finishing
    /// under the scratchpad can't bring the pill back through the card.
    private(set) var pillHiddenByMenu = false
    func setPillHiddenByMenu(_ on: Bool) {
        pillHiddenByMenu = on
        applyPillAlpha()
    }
    func applyPillAlpha() {
        pill.panel.alphaValue = (pillConcealed || pillHiddenByMenu) ? 0 : 1
    }

    /// The pill menu's Hands-free: a take started without a held key, the
    /// pill wearing a stop square until a click on it (or fn) finishes.
    func startHandsFreeFromMenu() {
        guard state == .idle else { return }
        startRecording()
        if state == .recording { pill.view.stopMark = true; pill.refreshShape() }
    }

    /// What the pill menu shows under the last transcript.
    var lastPasteMoment: Date? { lastPasteAt == .distantPast ? nil : lastPasteAt }
    var lastPasteAppName: String? {
        guard let id = lastPasteApp else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.localizedName
    }

    /// Words onto the clipboard for keeps: nothing will restore the old
    /// contents over them.
    func putOnClipboard(_ text: String) {
        clipboardRestoreWork?.cancel()
        clipboardRestoreWork = nil
        clipboardToRestore = nil
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    func stopAnim() {
        animTimer?.invalidate()
        animTimer = nil
        fnReleaseTicks = 0
        fnFlagSeen = false
    }

    /// Belt to the key-up's braces. A flagsChanged can go missing — the global
    /// monitor goes deaf while macOS animates a Space switch, and a tap the
    /// system disables mid-gesture drops whatever was in flight — which used
    /// to leave the mic open on a key nobody was holding. The live flags say
    /// what the hardware is doing right now, no event required. Three ticks
    /// (~125 ms) of disagreement before acting, so a momentary blip in the
    /// flags can't chop a sentence in half.
    func checkFnStillHeld() {
        guard state == .recording, startedByThisPress else {
            fnReleaseTicks = 0
            return
        }
        // An F-key carries no flag to watch; its key-up is the only word.
        guard let flags = heldDictate?.chordFlags, !flags.isEmpty else { return }
        if NSEvent.modifierFlags.isSuperset(of: flags) {
            fnFlagSeen = true
            fnReleaseTicks = 0
            return
        }
        // Never act on a signal that hasn't proved itself: if this Mac never
        // reports the fn bit, the key-up event stays the only word on it and
        // the watchdog stays out of the way.
        guard fnFlagSeen else { return }
        fnReleaseTicks += 1
        guard fnReleaseTicks >= 3 else { return }
        fnReleaseTicks = 0
        fnIsDown = false          // the key-up we never saw
        heldDictate = nil
        log("fn is no longer held but no key-up arrived — stopping the dictation")
        fnUp()
    }

    /// Paste done. No badge — the pill settling back to idle IS the signal
    /// (the "✓ Pasted" flash read as noise; user asked for quiet success).
    func flashSuccess() {
        pill.state = .idle
    }

    // MARK: - fn key handling

    /// Tap at the HID level, where events still flow during Space-switch
    /// animations. Needs the Accessibility/Input Monitoring grants the app
    /// already requires; silently skipped when unavailable (the NSEvent
    /// monitor keeps working on stable ground).
    ///
    /// Listen-only while the bindings are modifier keys, which nothing needs
    /// to hide. Active once a dictate key is an F-key or a combination (F5,
    /// ⌃F), or a hands-free combo is set: those are swallowed here, so
    /// holding one for SayCtrl is not also pressing it in the app in front.
    /// Everything else passes through untouched.
    var wantsActiveTap: Bool {
        Shortcuts.dictateKeys.contains { !$0.isModifierKey } || Shortcuts.handsFreeKeys.contains { !$0.isModifierKey }
    }

    func startFnTap() {
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()
            // The system disables a tap it thinks is slow — turn it back on.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = delegate.fnTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            if let ns = NSEvent(cgEvent: event) {
                if type == .flagsChanged {
                    delegate.handleFlagsChanged(ns)
                } else if delegate.handleKey(ns) {
                    return nil   // ours — the app in front never sees it
                }
            }
            return Unmanaged.passUnretained(event)
        }
        // An active tap needs Accessibility; with only Input Monitoring in
        // hand, a listen-only one still hears the key (it just cannot keep
        // an F-key from the app in front).
        let make = { (options: CGEventTapOptions) in
            CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: options,
                              eventsOfInterest: mask, callback: callback,
                              userInfo: Unmanaged.passUnretained(self).toOpaque())
        }
        var swallows = wantsActiveTap
        var made = make(swallows ? .defaultTap : .listenOnly)
        if made == nil, swallows { swallows = false; made = make(.listenOnly) }
        guard let tap = made else {
            log("fn event tap unavailable — relying on the global monitor only")
            return
        }
        fnTap = tap
        fnTapSwallows = swallows
        let kind = swallows ? "active" : wantsActiveTap
            ? "listen-only — Accessibility missing, so the dictate key held for SayControl also reaches the app in front"
            : "listen-only"
        log("fn event tap: \(kind)")
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        fnTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// A tap asked for before Accessibility or Input Monitoring was granted
    /// never came to be, or came to be listen-only when it should swallow.
    /// Once the grant lands — the onboarding watches for it — or the
    /// bindings change what the tap must do, make it again, so the
    /// Space-switch-proof path and the swallowing work without a relaunch.
    func restartFnTapIfNeeded() {
        if let tap = fnTap {
            let shouldSwallow = wantsActiveTap && AXIsProcessTrusted()
            guard fnTapSwallows != shouldSwallow else { return }
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = fnTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            fnTap = nil
            fnTapSource = nil
        }
        startFnTap()
    }

    /// The menu bar's first line: which key to hold.
    var infoTitle: String {
        "Hold \(Shortcuts.dictate.text) to dictate" + (Config.isDev ? " (Dev)" : "")
    }

    func handleFlagsChanged(_ event: NSEvent) {
        if Shortcuts.recording { return }   // a box on the General tab is taking the key
        let held = event.modifierFlags.intersection(KeyShortcut.allModifierFlags)
        if let hold = Shortcuts.dictateKey(forModifierCode: event.keyCode), let flag = hold.modifierFlag {
            let down = event.modifierFlags.contains(flag)
            guard down != fnIsDown else { return }
            // Another dictate key is the one being held; this one's release
            // is not the end of that press.
            if !down, let held = heldDictate, held != hold { return }
            fnIsDown = down
            heldDictate = down ? hold : nil
            DispatchQueue.main.async { down ? self.fnDown() : self.fnUp() }
            return
        }
        // A dictate chord: down when its modifiers are all held and nothing
        // else is; up when any of them lets go.
        if let chord = heldDictate, chord.isChord {
            if !held.isSuperset(of: chord.chordFlags) {
                fnIsDown = false
                heldDictate = nil
                DispatchQueue.main.async { self.fnUp() }
                return
            }
            // Still held: fall through, so the command modifier can arm late.
        } else if !fnIsDown, let chord = Shortcuts.dictateChord(held: held) {
            fnIsDown = true
            heldDictate = chord
            DispatchQueue.main.async { self.fnDown() }
            return
        }
        // A hands-free chord fires once, as its last modifier lands; it is
        // armed again when the fingers come off. Queued behind the dictate
        // key's own press, so fn + option finds the hold already open.
        if let fired = firedChord, !held.isSuperset(of: fired.chordFlags) { firedChord = nil }
        if firedChord == nil, let chord = Shortcuts.handsFreeChord(held: held) {
            firedChord = chord
            DispatchQueue.main.async { self.handsFreeChordPressed(chord) }
        }
        // The command modifier landing while the dictate key already holds a
        // recording open: pressed "together" arrives in either order, so
        // modifier-second arms command mode too (the key going DOWN).
        let cmd = Shortcuts.commandModifier
        if KeyShortcut.keyCodes(for: cmd).contains(event.keyCode),
           event.modifierFlags.contains(cmd), fnIsDown {
            DispatchQueue.main.async { self.armCommandModeLate() }
        }
    }

    /// A dictate key that is an F-key or a combination is held like fn —
    /// down starts, up stops, key repeat ignored. The hands-free combo is a
    /// press. Returns true for an event that belongs to one of them, so the
    /// tap can keep it from the app in front: the press that starts, the
    /// repeats while held, and the release — whatever modifiers are still
    /// down by then.
    @discardableResult
    func handleKey(_ event: NSEvent) -> Bool {
        if Shortcuts.recording { return false }
        if Shortcuts.isDictateKeyCode(event.keyCode) {
            let heldHere = fnIsDown && heldDictate?.keyCode == event.keyCode && !(heldDictate?.isModifierKey ?? true)
            if event.type == .keyDown {
                if heldHere { return true }   // a repeat, or the monitor's copy
                guard !fnIsDown, !event.isARepeat, let hold = Shortcuts.dictateKey(matching: event) else { return false }
                fnIsDown = true
                heldDictate = hold
                DispatchQueue.main.async { self.fnDown() }
                return true
            } else if event.type == .keyUp, heldHere {
                fnIsDown = false
                heldDictate = nil
                DispatchQueue.main.async { self.fnUp() }
                return true
            }
            return false
        }
        if let combo = Shortcuts.handsFreeKey(matching: event) {
            guard event.type == .keyDown else { return true }   // its key-up, swallowed too
            guard !event.isARepeat else { return true }
            // The tap and a monitor both deliver this press; once is enough.
            guard event.timestamp != lastHandsFreePress else { return true }
            lastHandsFreePress = event.timestamp
            DispatchQueue.main.async { self.toggleDictation() }
            return true
        }
        return false
    }

    /// A hands-free chord landed. Idle: a hands-free session starts, as from
    /// the menu bar. Holding the dictate key already (fn + option, with fn
    /// the key): that hold turns hands-free — let go of fn and it keeps
    /// listening. Hands-free already running: this ends it.
    func handsFreeChordPressed(_ chord: KeyShortcut) {
        switch state {
        case .idle:
            startedByThisPress = false
            startRecording()
        case .recording:
            if startedByThisPress {
                startedByThisPress = false
                log("Hands-free latched by \(chord.text)")
                hud.show("Hands-free — say “send it” or press \(chord.text) to finish", autohide: 2.5)
            } else {
                stopAndTranscribe()
            }
        case .transcribing:
            break
        }
    }

    /// Control arrived after fn had already started the recording — same
    /// gesture, other order. The recognizer's keyterms were negotiated when
    /// the socket opened, so a late arm only skips the instruction-phrase
    /// biasing; everything else works the same. Idempotent: the monitor and
    /// the HID tap both hear the event.
    func armCommandModeLate() {
        guard state == .recording, pendingCommand == nil else { return }
        guard Account.commandModeFree else {
            hud.show("Command mode comes with Pro", autohide: 2.5)
            return
        }
        guard Config.shared.hasModelAccess else {
            hud.show("⚠️ Command mode: \(noPolishReason)", autohide: 2.5)
            return
        }
        let target = CommandMode.captureTarget()
        pendingCommand = target
        CommandMode.armed = true
        pill.command = true          // white bars and the command key, from now on
        speechCard.setCommand(true)
        log("Command mode armed (control after fn): \(target.label) (\(target.text.count) chars)")
        hud.show("Command — say what to do with \(target.label)", autohide: 2.5)
    }

    func fnDown() {
        if let probe = fnProbe { probe(true); return }
        switch state {
        case .idle:
            startedByThisPress = true
            // Dictate key + the command modifier = command mode: the utterance
            // will be an instruction applied to the selection or text box,
            // not words to paste.
            commandArmed = NSEvent.modifierFlags.contains(Shortcuts.commandModifier)
            // The agent voice is talking or listening: the key cuts it off,
            // and what is dictated now is the reply to it.
            _ = AgentBridge.shared.hotkeyInterrupt()
            startRecording()
        case .recording:
            startedByThisPress = false
            stopAndTranscribe()
        case .transcribing:
            break
        }
    }

    /// Letting go of fn always ends the dictation that press opened — the mic
    /// is never left listening on a key that isn't held. A quick tap used to
    /// latch the recording open until the next press, so a brushed fn sat
    /// there recording the room with nothing on screen having asked for it.
    /// Hands-free still exists, but only where it is deliberate and visible:
    /// "Start Dictation" in the menu bar (that session ends on the next fn
    /// press, a pill click, or the menu item again).
    func fnUp() {
        if let probe = fnProbe { probe(false); return }
        if state == .recording && startedByThisPress { stopAndTranscribe() }
        startedByThisPress = false
    }

    /// The hands-free key: start a take, or finish the one running.
    func toggleDictation() {
        switch state {
        case .idle: startRecording()
        case .recording: stopAndTranscribe()
        case .transcribing: break
        }
    }

    @objc func menuToggleCleanup() {
        let on = !cleanupEnabled
        Config.shared.setFlag("CLEANUP", on)
        cleanupMenuItem.state = on ? .on : .off
        hud.show(on ? "✓ Cleanup on" : "Cleanup off", autohide: 1.2)
        log("Cleanup toggled: \(on)")
    }

    @objc func menuToggleAgentVoice() {
        let on = !Config.shared.agentVoice
        Config.shared.setFlag("AGENT_VOICE", on)
        AgentBridge.shared.apply()
        hud.show(on ? "🤖 Agent voice on" : "Agent voice off", autohide: 1.6)
        log("Agent voice toggled: \(on)")
    }

    @objc func menuToggleAutoLearn() {
        let on = !autoLearnEnabled
        Config.shared.setFlag("AUTOLEARN", on)
        autoLearnMenuItem.state = on ? .on : .off
        if !on { watcher.stop() }
        hud.show(on ? "✓ Learning corrections" : "Not learning corrections", autohide: 1.4)
        log("Auto-learn toggled: \(on)")
    }

    @objc func menuSettings() { SettingsUI.shared.present() }

    // MARK: - Learned corrections

    /// Called by CorrectionWatcher with the words you changed in a paste, once
    /// you're done with it. The question for each is whether the recognizer
    /// MISHEARD you or you REWORDED — only a mishearing is worth learning,
    /// and a month of learning every edit left "it" → "It" firing 912 times,
    /// "his" → "her", "first" → "fast" and half-typed words in the dictionary.
    ///
    /// - A made-up word fixed ("Sorwer" → "Sorower", "Reki" → "Reqkey") is a
    ///   mishearing: nobody means a word that doesn't exist. It becomes a rule.
    /// - A capital changed on an ordinary word ("it" → "It") is about where
    ///   the word sat in the sentence, not the word: never learned. On a word
    ///   of your own ("reqkey" → "Reqkey") it is how you spell it: a rule.
    /// - A real word changed could be either, so the model reads the sentence
    ///   before and after and says which, when polish is on. A mishearing
    ///   becomes a hint — a name for the recognizers, a known mishearing for
    ///   polish, which fixes it only where the sentence is about it — plus a
    ///   phrase rule when the word stood next to one with meaning ("art
    ///   browser" → "Arc browser"). Without the model, a real word fixed to a
    ///   name is taken as a mishearing and one fixed to another word isn't.
    func learned(_ fixes: [CorrectionWatcher.Fix], original: String, edited: String) {
        for fix in fixes { judgeFix(fix.heard, fix.meant, original: original, edited: edited) }
    }

    private func judgeFix(_ heard: String, _ meant: String, original: String, edited: String) {
        guard CorrectionWatcher.plausible(from: heard, to: meant) || CorrectionWatcher.knownTarget(meant) else {
            log("Auto-learn: ignored “\(Config.words(heard))” → “\(Config.words(meant))” (doesn't look like a misheard-word fix)")
            return
        }
        let heardReal = Lexicon.isRealWord(heard)
        if heard.lowercased() == meant.lowercased() {
            guard !heardReal else {
                log("Auto-learn: ignored “\(Config.words(heard))” → “\(Config.words(meant))” — a capital follows the sentence, not the word")
                return
            }
            learnRule(heard, meant, caseSensitive: true)
            return
        }
        guard heardReal else {
            learnRule(heard, meant, caseSensitive: false)
            return
        }
        // A name, to a person reading: not a word the dictionary knows, or
        // one it knows but you capitalised where the recognizer didn't ("art"
        // → "Arc", "cloud" → "Claude").
        let first = { (w: String) in w.first?.isUppercase == true }
        let nameLike = !Lexicon.isRealWord(meant) || (first(meant) && !first(heard))
        guard Config.shared.refineEnabled else {
            if nameLike { keepMishearing(heard, meant, original: original, name: true) }
            else { log("Auto-learn: “\(Config.words(heard))” → “\(Config.words(meant))” reads as rewording (no model to ask) — not learned") }
            return
        }
        Refiner.shared.editKind(original: original, edited: edited, heard: heard, meant: meant) { [weak self] kind in
            guard let self = self else { return }
            switch kind {
            case .misheard:
                self.keepMishearing(heard, meant, original: original, name: nameLike)
            case .reworded:
                self.log("Auto-learn: “\(Config.words(heard))” → “\(Config.words(meant))” — the model reads it as rewording; not learned")
            case .unknown:
                if nameLike { self.keepMishearing(heard, meant, original: original, name: true) }
                else { self.log("Auto-learn: “\(Config.words(heard))” → “\(Config.words(meant))” — no answer from the model; not learned") }
            }
        }
    }

    /// A made-up word, or a capital on a word of your own: swapped wherever it turns up.
    private func learnRule(_ heard: String, _ meant: String, caseSensitive: Bool) {
        guard ReplacementStore.shared.upsert(from: heard, to: meant, learned: true,
                                             caseSensitive: caseSensitive) else { return }
        log("Learned correction: \(Config.words(heard)) -> \(Config.words(meant))")
        hud.show("✓ Learned “\(heard)” → “\(meant)”", autohide: 2.6)
        flashLearned(meant)
    }

    /// A real word the recognizer wrote for another: never swapped blindly.
    /// It is kept as a hint, and anchored to a neighbour with meaning when it
    /// is a name ("art browser" → "Arc browser").
    private func keepMishearing(_ heard: String, _ meant: String, original: String, name: Bool) {
        let seen = ReplacementStore.shared.noteHint(from: heard, to: meant)
        if name, let phrase = CorrectionWatcher.contextPhrase(for: heard, to: meant, in: original),
           ReplacementStore.shared.upsert(from: phrase.from, to: phrase.to, learned: true) {
            log("Learned phrase: \(Config.words(phrase.from)) -> \(Config.words(phrase.to)) — “\(Config.words(heard))” is a real word, so the fix is anchored to its neighbor")
            hud.show("✓ Learned “\(phrase.from)” → “\(phrase.to)” — bare “\(heard)” still types normally",
                     autohide: 3.2)
            flashLearned(meant)
            return
        }
        guard let seen = seen else { return }
        log("Learned hint: \(Config.words(heard)) -> \(Config.words(meant)) — a real word, so it is never auto-replaced")
        hud.show(seen >= 3
                 ? "✓ Noted “\(meant)” again (\(seen)×) — make it automatic in Dictionary"
                 : "✓ Noted “\(meant)” — “\(heard)” still types normally", autohide: 3.2)
        flashLearned(meant)
    }

    /// The pill says what it learned: "Learned" and your word, in the serif.
    func flashLearned(_ word: String? = nil) {
        pill.learnedWord = word
        pill.state = .learned
        startAnim()
        learnedTimer?.invalidate()
        learnedTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            if self.pill.state == .learned {
                self.pill.state = .idle
                if self.state == .idle { self.stopAnim() }
            }
        }
    }

    /// "Didn't catch that" for a moment, then back to rest. Shares the
    /// learned flash's timer — one flash at a time.
    func flashNothingHeard() {
        pill.state = .nothingHeard
        learnedTimer?.invalidate()
        learnedTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { [weak self] _ in
            guard let self = self, self.pill.state == .nothingHeard else { return }
            self.pill.state = .idle
        }
    }

    // MARK: - Disfluency cleanup

    /// Remove filler words ("um"/"uh"), cut-off word fragments ("al- already"),
    /// and comma-separated repeats ("I, I" -> "I") before pasting. Pure text, no
    /// network — it never changes which real words you said, only trims noise.
    func cleanTranscript(_ raw: String) -> String {
        let raw = Self.latinizeStrayCJKPunctuation(raw)
        if !cleanupEnabled { return raw }
        var s = raw

        func sub(_ pattern: String, _ template: String, caseInsensitive: Bool = true) {
            var opts: NSRegularExpression.Options = []
            if caseInsensitive { opts.insert(.caseInsensitive) }
            guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return }
            let range = NSRange(s.startIndex..<s.endIndex, in: s)
            s = re.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: template)
        }

        // Cut-off fragments: a word ending in a hyphen then a space ("al- already", "No- Node").
        sub("\\b\\p{L}+-\\s+", " ")
        // Filler words, optionally eating one trailing comma. \b guards real words/names.
        sub("\\b(?:u+h+|u+m+|e+r+|a+h+|h+m+|m+h+m+|erm|mm+)\\b,?", "")
        // Immediate comma-separated repeats ("how, how, how" -> "how"); apostrophes kept
        // so contractions survive. Never number words: "five five five, zero
        // one seven three" is a phone number, not a stutter.
        let digitWords = "zero|oh|one|two|three|four|five|six|seven|eight|nine|ten"
        sub("\\b(?!(?:\(digitWords))\\b)([\\p{L}']+)(?:\\s*,\\s*\\1\\b)+", "$1")
        // Space-separated repeats ("we we" -> "we"), but never "that that" / "had had",
        // which are valid English doubles, nor number words.
        sub("\\b(?!(?:that|had|\(digitWords))\\b)([\\p{L}']+)(?:\\s+\\1\\b)+", "$1")
        // Tidy leftover whitespace and punctuation.
        sub("\\s+", " ")
        sub("\\s+([,.;:!?])", "$1")
        sub("(?:,\\s*){2,}", ", ")
        sub("^[\\s,]+", "")
        // Lone lowercase "i" -> "I".
        sub("\\bi\\b", "I", caseInsensitive: false)

        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return capitalizeSentences(s)
    }

    /// The multilingual recognizer sometimes closes an English utterance with
    /// CJK punctuation — "Take a screenshot。" (U+3002, live 2026-08-20) — which
    /// no command regex and no chat box expects: the shot was dropped and the
    /// words pasted literally. In text with no CJK script of its own those
    /// marks are artifacts, so they become the ASCII they stand for. A real
    /// Chinese or Japanese dictation keeps its own punctuation untouched.
    static func latinizeStrayCJKPunctuation(_ s: String) -> String {
        let map: [Character: Character] = [
            "。": ".", "｡": ".", "，": ",", "、": ",", "､": ",",
            "！": "!", "？": "?", "：": ":", "；": ";",
            "（": "(", "）": ")", "\u{3000}": " ",
        ]
        guard s.contains(where: { map[$0] != nil }) else { return s }
        let cjk = s.unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value)        // kana
                || (0x3400...0x9FFF).contains(scalar.value) // han
                || (0xAC00...0xD7AF).contains(scalar.value) // hangul
        }
        guard !cjk else { return s }
        return String(s.map { map[$0] ?? $0 })
    }

    /// Re-capitalize the first letter and any letter after . ! ? — our edits above
    /// can lowercase a new leading word once a filler is stripped.
    func capitalizeSentences(_ text: String) -> String {
        var chars = Array(text)
        var capNext = true
        for i in chars.indices {
            let c = chars[i]
            if c.isLetter {
                if capNext { chars[i] = Character(c.uppercased()) }
                capNext = false
            } else if ".!?".contains(c) {
                // Sentence end only when followed by whitespace/end — so "Node.js",
                // "e.g." and decimals don't trigger a mid-word capital.
                let next = i + 1 < chars.count ? chars[i + 1] : " "
                capNext = next.isWhitespace
            } else if !c.isWhitespace {
                capNext = false
            }
        }
        return String(chars)
    }

    // MARK: - Recording

    func startRecording() {
        guard state == .idle else { return }
        guard !Account.required else {
            hud.show("Sign in to start dictating", autohide: 2.5)
            playSound("SayCtrlMiss")
            Account.askToSignIn()
            return
        }
        // On the cloud until the plan is spent. Then Free gets a few extra
        // takes, sent whole when you let go to the server's cheaper upload
        // model; after those, nothing until the week starts again. A user's
        // copy on the cloud never falls back to a model on this Mac by
        // itself (Settings › Models is where they move); the developers'
        // build still does, as if the cloud were off.
        let spent = Config.shared.cloudOn && Cloud.shared.spent
        let cloud = Config.shared.cloudOn && !spent
        let extraTake = spent && !Account.proFeatures && Cloud.shared.graceLeft > 0
        // A take off the cloud (the developers' build on its own engines)
        // has no receipt, and an earlier take's would vouch for other words:
        // its model calls go on this Mac's own key (Refine.perform).
        if !cloud && !extraTake { Cloud.shared.forgetReceipts() }
        // Spent: ask the server now and then, so an upgrade or a new week
        // puts the next take back on the cloud.
        if spent { Cloud.shared.refreshAccountIfStale() }
        if Config.retail, Config.shared.transcriptionSource == .cloud, !cloud, !extraTake {
            let why = !Config.shared.cloudOn ? "Cloud dictation is off"
                : Cloud.shared.usage?.words.left == 0
                    ? "This week's free words are used up. They refill \(PlanState.refillDay)"
                    : CloudError.limitReached("speech").localizedDescription
            hud.show("⚠️ \(why) — Pro never runs out", autohide: 3.5)
            playSound("SayCtrlMiss")
            log("Dictation: \(why.lowercased()) — sent to Plan")
            SettingsUI.shared.present(selecting: "billing")
            return
        }
        // The plan decides the controls for the whole take: the live checks
        // read this on every word, so it's set once here.
        Commands.controlsOn = Account.controlsFree
        guard cloud || extraTake || apiKey() != nil else {
            // Local always has its placeholder key, so this is a provider
            // picked under API key with none saved for it.
            hud.show("⚠️ No API key — add one in Settings › Models", autohide: 2.5)
            playSound("SayCtrlMiss")
            SettingsUI.shared.showSettings(tab: "model")
            return
        }
        popup.hide()
        sunMenu.hide()
        // A missed paste's card gives way at once — no fold back into the
        // pill, which is about to be the recording. The words stay in Recent.
        PasteCard.shared.dismiss(animated: false, reason: "a new dictation")
        // The pill menu makes way — unless the scratchpad is open, whose take this is.
        PillMenu.shared.recordingStarted()
        discardClipAudio()   // a tape the last dictation never closed
        clipID = HistoryEntry.newID()
        dockPicker.hide()   // a half-finished Move mustn't eat clicks mid-dictation
        pendingShots.removeAll()   // shots from an abandoned dictation must not leak into this one
        pendingPathBatches.removeAll()
        pathSampleFailedLive = false
        pendingURLs.removeAll()
        urlSampleFailedLive = false
        pendingAttachURL = nil     // the picker itself may stay up: this new
        liveAttachCmd = nil        // dictation could be its "the first one"
        liveAttachTimer?.invalidate()
        liveAttachTimer = nil
        sendAfterPaste = false     // a send the last dictation never consumed
        attachAfterPaste = nil     // ditto an attachment that never pasted
        watcher.stop()   // whatever you were editing, you've moved on
        // Give a Chromium/Electron target the record+transcribe window to build its
        // accessibility tree, so we can see your edit once the text lands.
        if autoLearnEnabled { CorrectionWatcher.prepareFrontmostApp() }
        // Skim the front window for names while you talk — the words you are
        // about to say are usually already on screen, spelled right.
        ScreenVocab.shared.beginScan()
        // And what is already written before the caret (or what was just said).
        if Config.shared.screenVocab { TypingContext.capture() }
        // Reset the AI-polish cache and open its TLS connection while you talk.
        Refiner.shared.beginDictation()
        // Command mode captures its target NOW — the selection or field the
        // user is looking at, before anything else can steal focus.
        pendingCommand = nil
        if commandArmed {
            commandArmed = false
            if !Account.commandModeFree {
                hud.show("Command mode comes with Pro — continuing as dictation", autohide: 2.5)
                log("Command mode: Free plan — continuing as dictation")
            } else if !Config.shared.hasModelAccess {
                hud.show("⚠️ \(noPolishReason) — continuing as dictation", autohide: 2.5)
            } else {
                let target = CommandMode.captureTarget()
                pendingCommand = target
                log("Command mode armed: \(target.label) (\(target.text.count) chars)")
                hud.show("Command — say what to do with \(target.label)", autohide: 2.5)
            }
        }
        // The recognizer's hint list leads with instruction phrasing while a
        // command is armed ("polish it", "make it shorter") — refreshed every
        // dictation so a normal one gets its normal command hints back.
        CommandMode.armed = pendingCommand != nil
        // ...and the pill wears it: white bars and the command key, so a
        // command never looks like dictation.
        pill.command = CommandMode.armed
        // Dictating into a terminal: the words get one look at the shell
        // grammar before they get polished as prose.
        shellArmed = pendingCommand == nil && Config.shared.shell && frontAppIsTerminal && Commands.controlsOn
        // Where the words are landing, for the recognizer's hint list: a
        // terminal expects the shell's words, a picker expects an answer.
        Hints.context = Hints.Context(terminal: frontAppIsTerminal, picker: attachPicker.isVisible)
        if Hints.context.terminal || Hints.context.picker {
            log("Hints: \(Hints.context.picker ? "picker replies, " : "")"
                + "\(Hints.context.terminal ? "shell words, " : "")leading \(Hints.ranked().count)")
        }
        // The app in front is where the paste will land — its tone steers the
        // polish ("an email", "a chat message"), never the words themselves.
        if pendingCommand == nil, Config.shared.refineEnabled {
            AppStyle.capture { hint in
                Refiner.shared.styleHint = hint
                if let hint = hint { Config.shared.log("Refine: tone — \(hint.place): \(Config.words(hint.rules))") }
            }
        }
        takeOnCloud = cloud
        takeIsExtra = extraTake
        if extraTake { log("Dictation: an extra take (\(Cloud.shared.graceLeft) left) — sent whole when you let go") }
        // Live mode never touches the disk — it streams straight to the socket.
        // The cloud is always live; an extra take never is.
        if cloud || (Config.shared.liveEnabled && !extraTake) {
            startLiveRecording(cloud: cloud)
            return
        }
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            try? FileManager.default.removeItem(at: audioURL)
            let rec = try AVAudioRecorder(url: audioURL, settings: settings)
            rec.isMeteringEnabled = true
            rec.prepareToRecord()
            guard rec.record() else { throw NSError(domain: "SayCtrl", code: 1, userInfo: [NSLocalizedDescriptionKey: "recorder.record() returned false"]) }
            recorder = rec
            state = .recording
            pill.state = .recording
            startAnim()
            setStatusIcon("🔴")
            playSound("SayCtrlStart")
            maxLenTimer = Timer.scheduledTimer(withTimeInterval: MAX_CLIP_SECONDS, repeats: false) { [weak self] _ in
                self?.stopAndTranscribe()
            }
            log("Recording started")
        } catch {
            log("Recording failed to start: \(error.localizedDescription)")
            hud.show("⚠️ Mic error — check permissions", autohide: 2.5)
            playSound("SayCtrlMiss")
        }
    }

    // MARK: - The agent voice borrows the mic

    /// The agent voice's turn to listen: the SAME dictation the key drives —
    /// same models, same pill, same history entry and saved clip — started
    /// without a key. The bridge's ear only times it: says when the reply
    /// has ended, or that nothing was said.
    func beginAgentCapture() -> Bool {
        guard state == .idle else { return false }
        startRecording()
        return state == .recording
    }

    /// The ear heard the reply end (stop and transcribe — the transcript
    /// comes back through takeReply), or heard nothing at all (throw the
    /// take away without a sound or a history entry).
    func endAgentCapture(discard: Bool) {
        guard state == .recording else { return }
        if !discard { return stopAndTranscribe() }
        maxLenTimer?.invalidate()
        if let session = live {
            live = nil
            session.cancel()
            closeCloudTake(words: 0)
        }
        recorder?.stop()
        recorder = nil
        discardClipAudio()
        hud.hide()
        state = .idle
        stopAnim()
        pill.state = .idle
        setStatusIcon("🎤")
        log("Agent capture discarded — nothing said")
    }


    /// The stop that is waiting out STOP_TAIL_SECONDS. A second key-up in
    /// that window changes nothing; the key going down again is ignored
    /// too, since the state is still .recording.
    private var stopTail: DispatchWorkItem?

    /// The key came up. The mic stays open a beat longer (STOP_TAIL_SECONDS)
    /// so the word you were finishing gets its last consonant; the length
    /// the blip test sees is what was held, not the tail.
    func stopAndTranscribe() {
        guard state == .recording, stopTail == nil else { return }
        maxLenTimer?.invalidate()
        idleTimer?.invalidate()
        idleTimer = nil
        let spoken = live != nil ? Date().timeIntervalSince(liveStartedAt) : (recorder?.currentTime ?? 0)
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.stopTail = nil
            if self.live != nil { self.stopLive(spoken: spoken) } else { self.stopClip(spoken: spoken) }
        }
        stopTail = work
        DispatchQueue.main.asyncAfter(deadline: .now() + STOP_TAIL_SECONDS, execute: work)
    }

    private func stopClip(spoken: TimeInterval) {
        guard state == .recording, let rec = recorder else { return }
        let duration = rec.currentTime
        rec.stop()
        recorder = nil

        if spoken < MIN_CLIP_SECONDS {
            state = .idle
            stopAnim()
            pill.state = .idle
            discardClipAudio()
            setStatusIcon("🎤")
            // Nothing to paste, and the start sound already played — say what
            // the gesture is, so a tap doesn't just look broken.
            if !AgentBridge.shared.captureFailed() {
                showHoldHint()
            }
            log("Clip too short (\(String(format: "%.2f", spoken))s), discarded")
            return
        }

        state = .transcribing
        pill.state = .transcribing
        setStatusIcon("✨")
        playSound("SayCtrlStop")
        log("Recording stopped (\(String(format: "%.1f", duration))s), transcribing")

        if takeIsExtra {
            transcribeExtraTake(fileURL: audioURL) { [weak self] result in
                self?.finishTranscription(result, duration: duration)
            }
            return
        }
        transcribe(fileURL: audioURL) { [weak self] result in
            self?.finishTranscription(result, duration: duration)
        }
    }

    /// Free's extra take, once the week's words are gone: the clip goes to
    /// the server's upload model, and the pill says how many are left — the
    /// reminder comes with every one of them, not just the last.
    private func transcribeExtraTake(fileURL: URL, completion: @escaping (Result<String, Error>) -> Void) {
        guard let wav = try? Data(contentsOf: fileURL) else {
            return completion(.failure(NSError(domain: "SayCtrl", code: 2,
                                               userInfo: [NSLocalizedDescriptionKey: "The recording couldn't be read"])))
        }
        Cloud.shared.transcribeExtraTake(wav, language: "en", terms: Hints.ranked()) { [weak self] result in
            switch result {
            case .success(let text):
                let left = Cloud.shared.graceLeft
                self?.log("Extra take: \(text.count) chars, \(left) left")
                completion(.success(text))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self?.hud.show(left > 0
                        ? "Words used up · \(left) extra take\(left == 1 ? "" : "s") left — Pro never runs out"
                        : "That was the last extra take — words refill \(PlanState.refillDay), or go Pro", autohide: 3.5)
                }
            case .failure(let e):
                completion(.failure(e))
                if case .limitReached = e { SettingsUI.shared.present(selecting: "billing") }
            }
        }
    }

    /// The finished clip's file name, or nil when audio isn't being kept.
    /// Live taped as it streamed; an upload dictation is already a WAV in the
    /// temp folder, waiting to be moved in.
    private func keepClipAudio() -> String? {
        if let tape = clipTape {
            clipTape = nil
            guard let url = tape.close() else { return nil }
            Recordings.shared.prune()
            return url.lastPathComponent
        }
        return Recordings.shared.keep(audioURL, id: clipID)
    }

    /// Nothing was said, or the transcription failed — throw the clip away
    /// rather than leaving an orphan in the folder.
    private func discardClipAudio() {
        if let tape = clipTape {
            clipTape = nil
            if let url = tape.close() { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// The tail both paths share: clean it up, apply your dictionary, remember it,
    /// paste it. Whether the words arrived in one upload or streamed in live makes
    /// no difference from here on.
    func finishTranscription(_ result: Result<String, Error>, duration: TimeInterval) {
        PillMenu.shared.padTakeEnded()
        state = .idle
        stopAnim()
        speechCard.hide()
        concealPill(false)
        endLine()
        setStatusIcon("🎤")
        switch result {
        case .success(let text):
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty {
                pill.state = .idle
                discardClipAudio()
                // A reply the agent voice was waiting on: tell the bridge
                // rather than the screen. Otherwise the pill says so, quietly
                // — a take that just went idle looked dropped. An upright
                // seat has no room for words, so there the HUD still does.
                if !AgentBridge.shared.captureFailed() {
                    flashNothingHeard()
                    if pill.dock.isVertical { hud.show("🤷 No speech detected", autohide: 1.2) }
                }
                log("Empty transcript")
            } else {
                var cleaned = cleanTranscript(clean)
                // Qwen3 writes numbers as said ("two hundred sixty-five
                // milliseconds"); the others already write "265 ms".
                if Config.shared.provider == .gpu
                    || (Config.shared.provider == .local && Config.shared.model(for: .local).hasPrefix("qwen3")) {
                    let formatted = NumberFormat.apply(cleaned)
                    if formatted != cleaned { log("Numbers: \(Config.words(cleaned, upTo: 120)) → \(Config.words(formatted, upTo: 120))") }
                    cleaned = formatted
                }
                // Your dictionary runs last so its exact spelling ("ReqKey") survives.
                let final = ReplacementStore.shared.apply(to: cleaned)
                lastTranscript = final
                if final != clean {
                    log("Transcript raw (\(clean.count)): \(Config.words(clean, upTo: 160))")
                    log("Transcript final (\(final.count)): \(Config.words(final, upTo: 160))")
                } else {
                    log("Transcript (\(final.count) chars): \(Config.words(final, upTo: 160))")
                }
                // The context (names, screen words, the text before the
                // caret) is kept for measuring recognition ideas, in the dev
                // build only: a shipping copy never saves what was on screen
                // or already typed.
                HistoryStore.shared.add(text: final, seconds: duration, model: modelName(),
                                        audio: keepClipAudio(), id: clipID,
                                        context: Config.shared.screenVocab && !Config.retail
                                            ? TakeContext(terms: Hints.names(cap: 40),
                                                          screen: ScreenVocab.shared.scannedWords,
                                                          before: TypingContext.before,
                                                          beforeSource: TypingContext.beforeSource,
                                                          app: TypingContext.app)
                                            : nil)
                // Command mode: the whole utterance is an instruction for the
                // captured target — no command grammar, no polish, no paste of
                // the words themselves.
                if let target = pendingCommand {
                    pendingCommand = nil
                    executeCommandMode(instruction: final, target: target)
                    return
                }
                // A visible picker owns short ordinal replies: "the first
                // one" picks a candidate instead of pasting as text; any
                // real dictation dismisses it and flows on as usual.
                if attachPicker.isVisible {
                    // Heard exactly, near enough, or twice over: "That hard
                    // one" is "the third one" said to a picker, "the fifth
                    // one, the fifth one." is the recognizer echoing one
                    // "the fifth one" — and the picker is the only thing a
                    // three-word utterance can be answering.
                    if let (n, plain) = Commands.pickReply(final) {
                        if !plain { log("Picker: heard “\(Config.words(final))” as #\(n)") }
                        // Not every picker ends in a paste — an "open
                        // terminal" pick just launches — so settle the pill
                        // here. A candidate that DOES paste repaints it
                        // itself, including the amber "not pasted" badge,
                        // which choose() sets synchronously below.
                        pill.state = .idle
                        attachPicker.choose(n)   // the paste lands via onChoose
                        return
                    }
                    if Commands.isCancelReply(final) {
                        attachPicker.hide()   // "cancel" — drop it, paste nothing
                        pill.state = .idle
                        return
                    }
                    attachPicker.hide()   // you moved on
                }
                // The agent voice asked something and the key was the
                // answer: the words go to the agent, not to the screen.
                if AgentBridge.shared.takeReply(final) {
                    pill.state = .idle
                    return
                }
                // "Any agent updates?" / "talk to the agent": a question for
                // the agent voice, not words to paste.
                if AgentBridge.shared.handleQuery(final) {
                    pill.state = .idle
                    return
                }
                // "Scratch that", "send it", "use the local model": the
                // whole utterance is an instruction to SayCtrl, not words
                // to paste.
                if let meta = Commands.metaCommand(final) {
                    executeMeta(meta)
                    return
                }
                // "Scratch that." said INSIDE the dictation, its own
                // sentence: erase backwards before the rest of the words
                // land. Opening the take with it reaches back into the
                // previous paste; whatever survives flows on as usual.
                if let cut = Commands.splitScratch(final) {
                    log("Scratch command: in-dictation — \(cut.leading.count) reaching back, \(cut.text.count) chars flow on")
                    if !cut.leading.isEmpty {
                        executeScratch(cut.leading) { [weak self] in
                            guard let self = self, !cut.text.isEmpty else { return }
                            self.routeDictation(cut.text)
                        }
                    } else if cut.text.isEmpty {
                        // The dictation scratched itself away — the words
                        // never landed, so there is nothing to take back.
                        pill.state = .idle
                        hud.show("⌫ Scratched", autohide: 1.8)
                        playSound("SayCtrlMatch")
                    } else {
                        routeDictation(cut.text)
                    }
                    return
                }
                routeDictation(final)
            }
        case .failure(let err):
            pill.state = .idle
            discardClipAudio()
            log("Transcription error: \(err.localizedDescription)")
            _ = AgentBridge.shared.captureFailed()
            hud.show("⚠️ \(err.localizedDescription)", autohide: 2.5)
            playSound("SayCtrlMiss")
        }
    }

    /// Everything after the transcript is settled: split off the ask /
    /// send / open / attach commands and paste what remains. Runs once
    /// per dictation — and once more after a leading scratch has cleared
    /// the previous paste out of the way of the rest of the take.
    func routeDictation(_ final: String) {
        // The scratchpad is open: the take is the pad's, not an app's.
        if PillMenu.shared.holdsPad {
            PillMenu.shared.appendToPad(final)
            lastTranscript = final
            // The paste path is what settles the pill; this take skips it,
            // so the pill is put back to rest here (it was left on the
            // working wave until the next take).
            pill.state = .idle
            log("Scratchpad: \(final.count) chars added")
            return
        }
        // On Free the controls are off and their words paste as said; when
        // they were meant as one, the pill says why nothing else happened.
        if !Commands.controlsOn, Commands.wouldControl(final) {
            log("Spoken control on the Free plan — pasted as words")
            hud.show("Spoken controls come with Pro — pasted as words", autohide: 2.8)
        }
        // The shutter already fired for a phrase the final pass misheard:
        // put the phrase back so the picture has somewhere to land.
        var final = final
        let liveShots = pendingShots.count + (pendingShotCapturing ? 1 : 0)
        let finalShots = (Commands.segmentScreenshots(final)?.count ?? 1) - 1
        if liveShots > finalShots {
            let repaired = Commands.repairLostScreenshots(final, missing: liveShots - finalShots)
            if repaired != final {
                log("Screenshot: live took \(liveShots), final heard \(finalShots) — read back as “\(Config.words(repaired, upTo: 160))”")
                final = repaired
            }
        }
        // "ask ChatGPT <question>" hands the question to the browser
        // and the words before it to the paste pipeline. A bare
        // trailing "ask ChatGPT" flips that: everything you just
        // composed — screenshots included — IS the message, routed
        // into the site instead of pasted where you were.
        let askSplit = Commands.splitAsk(final)
        let remaining = askSplit?.before ?? final
        if let split = askSplit, split.ask.question.isEmpty, !remaining.isEmpty {
            lastTranscript = final
            let (runs, commands) = Commands.segment(remaining) ?? ([remaining], [])
            log("Ask command: routing \(runs.count) run(s) + \(commands.count) command(s) into \(split.ask.service.displayName)")
            routeToAsk(split.ask.service, runs: runs, commands: commands)
        } else if let split = askSplit, let (qRuns, qCommands) = Commands.segment(split.ask.question) {
            // "Ask ChatGPT do you like this version? Take a screenshot." A
            // picture can't ride the ?q= link, and the shutter already
            // fired — so the question is a composed message like the
            // trailing form's, not text with "Take a screenshot." in it.
            lastTranscript = final
            let service = split.ask.service
            if remaining.isEmpty || Commands.segment(remaining) != nil {
                // Nothing before, or the words before carry commands of
                // their own: one message, every shot in spoken order.
                let (runs, commands) = remaining.isEmpty ? (qRuns, qCommands)
                    : Commands.segment(remaining + " " + split.ask.question) ?? (qRuns, qCommands)
                log("Ask command: question carries \(commands.count) command(s) — composing into \(service.displayName)")
                routeToAsk(service, runs: runs, commands: commands)
                return
            }
            // Plain words before the ask are still yours to paste where you
            // were; the shots belong to the question, so they sit out the
            // local paste (which drops shots it has no phrase for).
            log("Ask command: \(remaining.count) chars pasted here, question with \(qCommands.count) command(s) into \(service.displayName)")
            shotCaptureGroup.notify(queue: .main) { [weak self] in
                guard let self = self else { return }
                let shots = self.pendingShots
                self.pendingShots.removeAll()
                self.pasteText(self.continuationSpace(before: remaining) + remaining)
                DispatchQueue.main.asyncAfter(deadline: .now() + self.askOpenDelay(for: remaining)) {
                    self.pendingShots = shots
                    self.routeToAsk(service, runs: qRuns, commands: qCommands)
                }
            }
        } else {
            // "…and send it" at the tail: the words before it are
            // the message, and Return follows once the paste has
            // landed. You said send — the Enter is not a surprise.
            var pasteable = remaining
            var sendAfter = false
            if let before = Commands.splitTrailingSend(pasteable), !before.isEmpty {
                sendAfter = true
                pasteable = before
                log("Send command: Return once the paste lands")
            }
            // "open terminal in the downloads folder": a terminal, already
            // standing in the folder you named. Read BEFORE the plain open
            // command, which would otherwise swallow the whole clause as
            // one app name. A terminal this Mac hasn't got is no command at
            // all — those words stay in the text.
            var terminal: (app: TerminalTarget.App, cmd: TerminalCommand)?
            if let (b, cmd, a) = Commands.splitTerminal(pasteable) {
                if let app = TerminalTarget.app(named: cmd.app) {
                    terminal = (app, cmd)
                    pasteable = [b, a].filter { !$0.isEmpty }.joined(separator: " ")
                    log("Terminal command: \(app.name) in \(cmd.folder.map { "“\(Config.detail($0))”" } ?? "the Finder folder")"
                        + (cmd.parent.map { " in \(Config.detail($0))" } ?? ""))
                } else {
                    log("Terminal command: no “\(cmd.app ?? "terminal")” on this Mac — kept as text")
                }
            }
            // "open Chrome" / "open facebook" / "open reqkey.com":
            // the target clause leaves the transcript, the rest of
            // the words keep flowing. A name SayCtrl doesn't know is
            // no command at all — the words stay in the text.
            var opening: OpenTarget.Resolution?
            if let (b, target, a) = Commands.splitOpen(pasteable) {
                if let resolution = OpenTarget.resolve(target) {
                    opening = resolution
                    pasteable = [b, a].filter { !$0.isEmpty }.joined(separator: " ")
                    log("Open command: \(Config.detail(target))")
                } else if b.isEmpty, a.isEmpty, let (resolution, name) = OpenTarget.resolveBySound(target) {
                    // "Open club." on its own is an open that was misheard,
                    // not a sentence — the nearest name by sound takes it.
                    opening = resolution
                    pasteable = ""
                    log("Open command: “\(Config.detail(target))” sounds like \(name)")
                } else {
                    log("Open command: unknown target “\(Config.detail(target))” — kept as text")
                }
            }
            // "attach the image from downloads" — the file joins
            // whatever app you're talking to, after the words land.
            var attaching: AttachCommand?
            if let (b, cmd, a) = Commands.splitAttach(pasteable) {
                attaching = cmd
                pasteable = [b, a].filter { !$0.isEmpty }.joined(separator: " ")
                log("Attach command: \(cmd.kind.noun)"
                    + (cmd.ordinal.map { " #\($0)" } ?? "")
                    + (cmd.fragment.map { " ~\(Config.detail($0))" } ?? "")
                    + (cmd.folder.map { " from \(Config.detail($0))" } ?? ""))
            } else if let (b, cmd, a) = Commands.splitPathQuery(pasteable) {
                // "copy the pdf path from downloads" — same hunt as attach,
                // but the file's PATH lands as text at the cursor.
                attaching = cmd
                pasteable = [b, a].filter { !$0.isEmpty }.joined(separator: " ")
                log("Path query: \(cmd.kind.noun)"
                    + (cmd.ordinal.map { " #\($0)" } ?? "")
                    + (cmd.fragment.map { " ~\(Config.detail($0))" } ?? "")
                    + (cmd.folder.map { " from \(Config.detail($0))" } ?? "")
                    + (cmd.parent.map { " in \(Config.detail($0))" } ?? ""))
            } else if liveAttachCmd != nil {
                // The stream heard an attach the final transcript
                // didn't confirm — drop the live capture.
                pendingAttachURL = nil
                attachPicker.hide()
            }
            let asking = askSplit?.ask
            // Talking into a terminal: a short list of commands, written
            // down in Shell.swift where they can be read. It runs entirely on
            // this Mac — no key, no request, nothing to pay for — so a local
            // model has the whole feature.
            //
            // A command skips the prose pipeline whole: polish and tones would
            // restyle it into something that does not run. Words that are NOT
            // a command come back nil and are pasted as dictated, which is
            // what keeps dictating a paragraph at Claude Code working.
            if shellArmed, let line = Shell.line(for: pasteable) {
                return typeShellCommand(line, original: final, sendAfter: sendAfter,
                                        asking: asking, opening: opening,
                                        attaching: attaching, terminal: terminal)
            }
            polishAndPaste(pasteable, original: final, sendAfter: sendAfter,
                           asking: asking, opening: opening,
                           attaching: attaching, terminal: terminal)
        }
    }

    /// A command lands at the prompt and nothing else happens to it — no
    /// polish, no tone, no Return. Whether a recipe or the model wrote it, the
    /// risky half of the shell is judged the same way and never gets the
    /// Return that "send it" presses everywhere else.
    private func typeShellCommand(_ line: Shell.Line, original: String, sendAfter: Bool,
                                  asking: AskCommand?, opening: OpenTarget.Resolution?,
                                  attaching: AttachCommand?,
                                  terminal: (app: TerminalTarget.App, cmd: TerminalCommand)?) {
        var sendAfter = sendAfter
        log("Shell command: \(Config.words(line.command))" + (line.mayAutoReturn ? "" : " — no auto-Return"))
        ControlStats.shared.note(.shell)
        if sendAfter, !line.mayAutoReturn {
            // "send it" presses Return everywhere else in SayCtrl. Not on the
            // half of the shell that cannot be undone.
            sendAfter = false
            hud.show("⚠️ \(line.command) — press Return yourself", autohide: 4)
        } else {
            hud.show("❯ \(line.command)", autohide: 2.5)
        }
        deliverDictation(line.command, original: original, sendAfter: sendAfter,
                         asking: asking, opening: opening,
                         attaching: attaching, terminal: terminal)
    }

    /// The ordinary tail of a dictation: AI polish, then paste.
    ///
    /// The polish sees only the words that survived the command grammar — a
    /// spoken command can never be reworded away — and its output passes the
    /// dictionary once more before pasting, so your exact spellings ("ReqKey")
    /// survive the model too.
    private func polishAndPaste(_ pasteable: String, original: String, sendAfter: Bool,
                                asking: AskCommand?, opening: OpenTarget.Resolution?,
                                attaching: AttachCommand?,
                                terminal: (app: TerminalTarget.App, cmd: TerminalCommand)?) {
        // The take this polish belongs to, for the Recent list's "Undo AI
        // polish" — read now, before another take can start.
        let takeID = clipID
        if let (runs, commands) = Commands.segment(pasteable) {
            // Inline screenshot/path/link phrases live inside this text. The
            // model must never SEE one — a reworded "take a screenshot" is a
            // command that no longer fires — so each run of words BETWEEN the
            // phrases is polished on its own and the phrases carry on
            // untouched, in their exact spots.
            //
            // Dropping the polish for the whole dictation instead was the
            // simple version of that rule, and it was too blunt: one spoken
            // "take a screenshot" in the middle cost a 185-second take every
            // paragraph break and every fix in it (measured 2026-08-21).
            return polish(runs: runs) { [weak self] polished in
                guard let self = self else { return }
                let before = Commands.joinSpoken(runs)
                let after = Commands.joinSpoken(polished)
                if after != before {
                    self.log("Refined \(runs.count) runs around \(commands.count) command(s) "
                        + "(\(before.count)→\(after.count) chars): \(Config.words(after, upTo: 160))")
                    HistoryStore.shared.setPolished(id: takeID, Self.spokenWithCommands(polished, commands))
                }
                self.deliverDictation(pasteable, original: original, sendAfter: sendAfter,
                                      asking: asking, opening: opening, attaching: attaching,
                                      terminal: terminal,
                                      segmented: (runs: polished, commands: commands))
            }
        }
        Refiner.shared.polish(pasteable) { [weak self] polished in
            guard let self = self else { return }
            var text = polished
            if polished != pasteable {
                text = ReplacementStore.shared.apply(to: polished)
                self.lastTranscript = text
                self.log("Refined (\(pasteable.count)→\(text.count) chars): \(Config.words(text, upTo: 160))")
                HistoryStore.shared.setPolished(id: takeID, text)
            }
            self.deliverDictation(text, original: original, sendAfter: sendAfter,
                                  asking: asking, opening: opening, attaching: attaching,
                                  terminal: terminal)
        }
    }

    /// Polished runs with the inline commands put back where they were said,
    /// for the Recent list — the picture can't go in a row, its phrase can.
    private static func spokenWithCommands(_ runs: [String], _ commands: [SpokenCommand]) -> String {
        var parts: [String] = []
        for (i, run) in runs.enumerated() {
            parts.append(run)
            guard i < commands.count else { continue }
            switch commands[i] {
            case .screenshot: parts.append("take a screenshot")
            case .filePath:   parts.append("copy the file path")
            case .pageURL:    parts.append("copy the link")
            }
        }
        return Commands.joinSpoken(parts.map { $0.trimmingCharacters(in: .whitespaces) })
    }

    /// Polish the text runs around inline commands — every run at once, so a
    /// dictation with three commands in it still waits for one round trip and
    /// not three. Each run goes through the same polish and the same
    /// dictionary the whole-dictation path uses; a run too short to be worth a
    /// pass comes back exactly as it went in (Refiner.polish's own floor), and
    /// so does a run whose pass failed or ran out of time.
    private func polish(runs: [String], completion: @escaping ([String]) -> Void) {
        var out = runs
        let group = DispatchGroup()
        for (i, run) in runs.enumerated() where !run.trimmingCharacters(in: .whitespaces).isEmpty {
            group.enter()
            // Every completion lands on the main queue, so `out` needs no lock.
            Refiner.shared.polish(run) { polished in
                if polished != run { out[i] = ReplacementStore.shared.apply(to: polished) }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(out) }
    }

    /// The last leg of a dictation, after the command grammar and the optional
    /// AI polish: schedule the ask/open/terminal/attach side-effects and paste
    /// the words.
    ///
    /// `segmented` is polishAndPaste handing over work already done: the text
    /// runs around the inline commands, polished one by one. When it is there
    /// the split is not recomputed — the polished runs are what pastes, while
    /// `pasteable` stays the words as spoken and is read for timing only, so a
    /// dictation that is nothing BUT a command still behaves as it always did.
    private func deliverDictation(_ pasteable: String, original: String, sendAfter: Bool,
                                  asking: AskCommand?, opening: OpenTarget.Resolution?,
                                  attaching: AttachCommand?,
                                  terminal: (app: TerminalTarget.App, cmd: TerminalCommand)?,
                                  segmented: (runs: [String], commands: [SpokenCommand])? = nil) {
        // Phrases expand here and nowhere else: past the command grammar, past
        // the AI polish, with nothing left to rewrite them. An expansion is
        // exact text the user wrote down — an address, a handle, a signature —
        // so the model never gets a chance to improve it into something else.
        var pasteable = pasteable
        var segmented = segmented
        if let split = segmented {
            // Run by run, so an expansion can never straddle a command phrase
            // and move where it fires.
            var runs: [String] = []
            var fired: [String] = []
            for run in split.runs {
                let (expanded, hits) = PhraseStore.shared.expand(in: run)
                runs.append(expanded)
                fired += hits
            }
            if !fired.isEmpty {
                let joined = Commands.joinSpoken(runs)
                log("Phrases: \(fired.count) expanded (\(Config.words(fired.joined(separator: ", ")))) — "
                    + "\(Commands.joinSpoken(split.runs).count)→\(joined.count) chars")
                segmented = (runs: runs, commands: split.commands)
                lastTranscript = joined
            }
        } else {
            let (expanded, fired) = PhraseStore.shared.expand(in: pasteable)
            if !fired.isEmpty {
                log("Phrases: \(fired.count) expanded (\(Config.words(fired.joined(separator: ", ")))) — "
                    + "\(pasteable.count)→\(expanded.count) chars")
                pasteable = expanded
                lastTranscript = expanded
            }
        }
        var sendAfter = sendAfter
        if asking != nil { ControlStats.shared.note(.ask) }
        if opening != nil { ControlStats.shared.note(.open) }
        if terminal != nil { ControlStats.shared.note(.terminal) }
        if attaching != nil { ControlStats.shared.note(.attach) }
        if let ask = asking {
            // The browser must not steal focus mid-paste — it
            // opens only after the local pastes have landed.
            let delay = pasteable.isEmpty ? 0 : askOpenDelay(for: pasteable)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.executeAsk(ask) }
        }
        if let resolution = opening {
            let delay = pasteable.isEmpty ? 0 : askOpenDelay(for: pasteable)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.executeOpen(resolution) }
        }
        if let t = terminal {
            // A terminal comes forward and takes the keyboard, so it waits
            // for the words the same way the open command does.
            let delay = pasteable.isEmpty ? 0 : askOpenDelay(for: pasteable)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.executeTerminal(t.app, t.cmd) }
        }
        if let cmd = attaching {
            // The file's ⌘V must not race the words' — but a
            // guessed timer overshoots by seconds. The paste
            // pipeline fires attachAfterPaste the moment its
            // last ⌘V is actually done; with no words at all
            // the attachment goes right now.
            var job: (() -> Void)?
            attachAfterPasteName = nil
            if let url = pendingAttachURL {
                // Live mode already resolved (and maybe picked) it.
                pendingAttachURL = nil
                attachAfterPasteName = url.lastPathComponent
                job = { self.pasteAttachment(url) }
            } else if attachPicker.isVisible {
                if let n = cmd.ordinal {
                    // Ordinal confirmed by the final transcript —
                    // the picker closure pastes now that live is over.
                    job = { self.attachPicker.choose(n) }
                } else {
                    attachPicker.nudge()   // its header already says how
                }
            } else {
                let afterWords = !pasteable.isEmpty
                job = { self.executeAttach(cmd, afterWords: afterWords) }
            }
            if let job = job {
                if pasteable.isEmpty { job() } else { attachAfterPaste = job }
            }
        }
        // An attachment pastes as an upload whose timing we
        // can't see — pressing Return blind could send the
        // message before the file is on it.
        if sendAfter, attaching != nil {
            sendAfter = false
            log("Send command: skipped — an attachment is pasting, press Return yourself")
        }
        sendAfterPaste = sendAfter
        // "take a screenshot" / "copy the file path" anywhere in
        // what you said means: paste its result in that exact spot,
        // with the rest of the words around it.
        if let (runs, commands) = segmented ?? Commands.segment(pasteable) {
            let spoken = Commands.joinSpoken(runs)
            lastTranscript = spoken.isEmpty ? original : spoken
            let shots = commands.filter { $0 == .screenshot }.count
            let paths = commands.filter { $0 == .filePath }.count
            let links = commands.filter { $0 == .pageURL }.count
            log("Commands: \(shots) screenshot(s), \(paths) path(s), \(links) link(s), \(spoken.count) chars of text in \(runs.count) runs")
            ControlStats.shared.note(commands)
            executeCommands(runs: runs, commands: commands)
        } else {
            // Partial-stream captures the final transcript didn't confirm.
            pendingShots.removeAll()
            pendingPathBatches.removeAll()
            pendingURLs.removeAll()
            if !pasteable.isEmpty {
                pasteText(continuationSpace(before: pasteable) + pasteable)
            } else if asking != nil || opening != nil || attaching != nil || terminal != nil {
                flashSuccess()   // the command WAS the dictation
            }
        }
    }

    // MARK: - Live transcription

    /// Same lifecycle as the file path — start, stop, hand the text to
    /// finishTranscription — except the words arrive while you are still talking.
    func startLiveRecording(cloud: Bool = false) {
        let model = cloud ? ASSEMBLY_LIVE_MODEL : Config.shared.model
        // Local has no socket to open — it re-runs the model over the audio so
        // far instead. Everything downstream is identical. The mesh, when it
        // is on and can run, is local plus a paid ear for the first seconds.
        // The cloud is our relay, which speaks AssemblyAI's protocol.
        let session: any LiveSession
        if cloud {
            let ear = LiveTranscriber(provider: .assemblyai, model: model, key: "")
            ear.onCloudMessage = { [weak self] message in
                Cloud.shared.adoptUsage(from: message)
                // Which vendor the relay picked is the server's call.
                if message["type"] as? String == "Begin" {
                    self?.log("Cloud: relay listening on \(message["vendor"] as? String ?? "?") \(message["model"] as? String ?? "")")
                }
                // The plan ran out mid-take: the words so far still paste.
                if message["type"] as? String == "Limit", let text = message["message"] as? String {
                    self?.log("Cloud: \(text)")
                    self?.hud.show("⚠️ \(text)", autohide: 3)
                }
            }
            cloudEar = ear
            session = ear
        } else if Config.shared.provider == .local {
            cloudEar = nil
            session = MeshLiveTranscriber.make() ?? LocalLiveTranscriber()
        } else {
            guard let key = apiKey() else { return }
            cloudEar = nil
            session = LiveTranscriber(provider: Config.shared.provider, model: model, key: key)
        }
        session.onLevel = { [weak self] level in self?.pill.view.level = level }
        session.onText = { [weak self] text in
            if let self = self, text != self.lastLiveText {
                self.lastLiveText = text
                self.lastHeardAt = Date()
            }
            self?.checkLiveScreenshot(text)
            self?.checkLivePathCommand(text)
            self?.checkLiveURLCommand(text)
            self?.checkLiveAttach(text)
            // Finished sentences get cleaned in the background as you talk.
            Refiner.shared.observeLive(text)
            // The bridge watches the reply capture's words settle — the
            // ear alone misses short answers (see liveHeard).
            AgentBridge.shared.liveHeard(text)
            self?.showLivePreview(text)
        }
        session.onFinish = { [weak self] result in
            guard let self = self, self.live != nil else { return }
            self.live = nil
            self.hud.hide()
            self.closeCloudTake(words: (try? result.get()).map { Cloud.words(in: $0) } ?? 0)
            self.finishTranscription(result, duration: Date().timeIntervalSince(self.liveStartedAt))
        }
        // Live streams straight to the socket, so this is the only copy of the
        // audio that ever exists — the same frames, written as they go, at
        // whatever rate the provider streams.
        clipTape = Recordings.shared.tape(id: clipID, sampleRate: session.sampleRate)
        session.tape = clipTape
        do {
            if let ear = cloudEar { try startCloudEar(ear) } else { try session.start() }
        } catch {
            cloudEar = nil
            log("Live session failed to start: \(error.localizedDescription)")
            hud.show("⚠️ \(error.localizedDescription)", autohide: 2.5)
            playSound("SayCtrlMiss")
            return
        }
        live = session
        liveStartedAt = Date()
        // A capture that never called back — screencapture can hang — would
        // otherwise leave this latch set for the rest of the run, and
        // showLivePreview reads it as "a shot is in flight, stay off screen":
        // the preview would be dead for every later dictation too.
        pendingShotCapturing = false
        state = .recording
        pill.state = .recording
        // A live dictation shows its words as you say them (Config.liveWords):
        // on one line inside the pill, which opens out once the first words
        // arrive; or in the speech card the pill grows into, at whichever
        // seat it's docked (a side seat has no room for a line, so it gets
        // the card); or not at all. The agent's reply capture types into
        // the chat card instead — the bridge owns that surface.
        if !AgentBridge.shared.capturingReply, !PillMenu.shared.holdsPad {
            let words = Config.shared.liveWords
            if words == "card" || (words == "line" && pill.dock.isVertical) {
                // Its foot names where the words are going and in what tone,
                // when AppStyle.capture already knew at key-down.
                speechCard.show(dock: pill.dock, startedAt: liveStartedAt,
                                command: pendingCommand != nil, hint: Refiner.shared.styleHint)
                concealPill(true)
            } else if words == "line" {
                pillLine.reset()
                pill.view.line = pillLine
            }
        }
        startAnim()
        setStatusIcon("🔴")
        playSound("SayCtrlStart")
        maxLenTimer = Timer.scheduledTimer(withTimeInterval: MAX_CLIP_SECONDS, repeats: false) { [weak self] _ in
            self?.stopAndTranscribe()
        }
        lastLiveText = ""
        lastHeardAt = Date()
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.checkHandsFreeIdle()
        }
        log("Live session started (\(cloud ? "SayControl cloud" : model))")
    }

    /// A cloud take opens the relay with the access token in hand — at
    /// once, unless it needs a refresh. The mic starts first either way and
    /// the audio waits for the socket, so the first word survives.
    private func startCloudEar(_ ear: LiveTranscriber) throws {
        try ear.startAwaitingBearer()
        Cloud.shared.withAccessToken { [weak self, weak ear] result in
            switch result {
            case .success(let token):
                ear?.connect(bearer: token)
            case .failure(let error):
                self?.log("Cloud: no access token for this take — \(error.localizedDescription)")
                ear?.abandon(error.localizedDescription)
            }
        }
    }

    /// A cloud take ended, however it did. The relay counted its words; the
    /// meter moves by the app's own count until the next take brings the
    /// server's.
    func closeCloudTake(words: Int) {
        guard cloudEar != nil else { return }
        cloudEar = nil
        Cloud.shared.noteTake(words: words)
    }

    /// Hands-free only: a take started by a press you let go of, or from
    /// the menu, with nothing new heard for a minute is stopped. A held fn
    /// is you choosing to wait; the agent's reply capture keeps its own ear.
    private func checkHandsFreeIdle() {
        guard state == .recording, live != nil else {
            idleTimer?.invalidate()
            idleTimer = nil
            return
        }
        guard !startedByThisPress, !AgentBridge.shared.capturingReply,
              Date().timeIntervalSince(lastHeardAt) >= HANDS_FREE_IDLE_SECONDS else { return }
        idleTimer?.invalidate()
        idleTimer = nil
        log("Hands-free: nothing new heard for \(Int(HANDS_FREE_IDLE_SECONDS)) s — stopping")
        stopAndTranscribe()
    }

    private func stopLive(spoken: TimeInterval) {
        guard let session = live else { return }
        let duration = Date().timeIntervalSince(liveStartedAt)

        if spoken < MIN_CLIP_SECONDS {
            live = nil
            session.cancel()
            closeCloudTake(words: 0)
            discardClipAudio()
            hud.hide()
            speechCard.hide()
            concealPill(false)
            endLine()
            state = .idle
            stopAnim()
            pill.state = .idle
            setStatusIcon("🎤")
            // Nothing to paste, and the start sound already played — say what
            // the gesture is, so a tap doesn't just look broken.
            if !AgentBridge.shared.captureFailed() {
                showHoldHint()
            }
            log("Clip too short (\(String(format: "%.2f", spoken))s), discarded")
            return
        }

        state = .transcribing
        pill.state = .transcribing
        speechCard.thinking()   // bars hand over to the dots; the words hold
        setStatusIcon("✨")
        playSound("SayCtrlStop")
        log("Live recording stopped (\(String(format: "%.1f", duration))s), finalising")
        // The words past the last polished sentence go to the model right now,
        // racing the provider's own finalisation of the same audio — scrubbed
        // exactly as finishTranscription will scrub them, so this pass and the
        // paste are asking about the same words.
        Refiner.shared.flushRemainder { ReplacementStore.shared.apply(to: cleanTranscript($0)) }
        // Most of the transcript is already in hand, so this usually returns in
        // well under the grace period rather than the full upload round-trip.
        session.finish()
    }

    /// The point of live mode: the words show up as you say them — in the
    /// speech card at the pill's seat, or typing into the agent card's
    /// forming bubble when the take is the agent's reply. (The bottom HUD
    /// strip used to carry this; it keeps only the notices now.)
    func showLivePreview(_ text: String) {
        // Stay off-screen while a shot is in flight, or the card photobombs it.
        guard live != nil, !text.isEmpty, !pendingShotCapturing else { return }
        // One 📸/📁/🔗/📎 per screenshot, path batch, link or file in the can.
        let cams = pendingShots.isEmpty ? "" : String(repeating: "📸", count: min(pendingShots.count, 3)) + " "
        let folders = pendingPathBatches.isEmpty ? "" : String(repeating: "📁", count: min(pendingPathBatches.count, 3)) + " "
        let links = pendingURLs.isEmpty ? "" : String(repeating: "🔗", count: min(pendingURLs.count, 3)) + " "
        let clips = pendingAttachURL == nil ? "" : ""
        if AgentBridge.shared.capturingReply {
            let tail = text.count > 220 ? "…" + String(text.suffix(220)) : text
            AgentPanel.shared.forming(cams + folders + links + clips + tail)
            return
        }
        // The line shows commands as chips of its own; the card keeps the
        // tail that fits its lines on its own, emoji in front.
        if pill.view.line != nil {
            pillLine.update(text)
            pill.refreshShape()
        } else {
            speechCard.update(cams + folders + links + clips + text)
        }
    }

    /// A tap too short to be a take: the pill itself shakes its head and
    /// says how the gesture goes, with the quiet nudge. It used to be a
    /// separate strip above the pill, which read as a notice arriving from
    /// somewhere else; the answer now comes from the thing you touched.
    func showHoldHint() {
        pill.state = .holdHint
        pill.shake()
        playSound("SayCtrlNudge")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.7) { [weak self] in
            guard let self = self, self.pill.state == .holdHint else { return }
            self.pill.state = .idle
        }
    }

    /// The first run is over and the app is open: the pill says hello once,
    /// where it will always be — how the gesture goes, with a soft pop
    /// rather than the nudge, and no shake: nothing was done wrong.
    func sayHello(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.state == .idle, self.pill.state == .idle else { return }
            self.pill.state = .holdHint
            NSSound(named: "SayCtrlPop")?.play()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                guard let self = self, self.pill.state == .holdHint else { return }
                self.pill.state = .idle
            }
        }
    }

    /// The take is over: the line folds away with the pill.
    func endLine() {
        guard pill.view.line != nil else { return }
        pill.view.line = nil
        pillLine.reset()
        pill.refreshShape()
    }

    /// A spoken action happened mid-take — the shot was taken, the link or
    /// the path picked up. With the line showing, a toast rises from the
    /// pill in the action's colour; otherwise the HUD says it, as before.
    func announceAction(_ command: SpokenCommand, _ text: String) {
        if pill.view.line != nil, !pillConcealed {
            actionToast.show(text, command: command, above: pill.capsuleFrame, dock: pill.dock)
        } else {
            hud.show(text)
        }
    }

    // MARK: - Batch transcription (OpenRouter or OpenAI)

    /// One-off live sessions replaying a saved clip through a realtime socket
    /// (the Recent ⋯ menu's Transcribe again: the cloud relay, or a live
    /// model) — owned here so the session outlives the call that started it;
    /// `live` stays the mic's seat.
    private var retakes: [LiveTranscriber] = []

    /// A kept clip heard again the way a dictation is heard now: through the
    /// SayControl cloud when that is where takes go — the same relay, the same
    /// ear, counted against the plan like a take — otherwise through this
    /// Mac's own provider. The Recent list's "Transcribe again".
    func transcribeAgain(fileURL: URL, completion: @escaping (Result<String, Error>) -> Void) {
        func fail(_ msg: String) {
            completion(.failure(NSError(domain: "SayCtrl", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])))
        }
        guard Config.shared.cloudOn else {
            // Signed out, a user's copy has nothing to hear with.
            if Config.retail && !Cloud.shared.signedIn { return fail("Sign in to transcribe again") }
            return transcribe(fileURL: fileURL, completion: completion)
        }
        if Cloud.shared.spent {
            return fail(Account.proFeatures ? "This month’s hours are used up"
                        : "This week’s words are used up — they refill \(PlanState.refillDay)")
        }
        let ear = LiveTranscriber(provider: .assemblyai, model: ASSEMBLY_LIVE_MODEL, key: "")
        retakes.append(ear)
        ear.onCloudMessage = { message in Cloud.shared.adoptUsage(from: message) }
        ear.onFinish = { [weak self] result in
            self?.retakes.removeAll { $0 === ear }
            Cloud.shared.noteTake(words: (try? result.get()).map { Cloud.words(in: $0) } ?? 0)
            completion(result)
        }
        Cloud.shared.withAccessToken { [weak self] result in
            switch result {
            case .success(let token):
                do { try ear.start(feeding: fileURL, bearer: token) } catch {
                    ear.cancel()
                    self?.retakes.removeAll { $0 === ear }
                    fail(error.localizedDescription)
                }
            case .failure(let error):
                self?.retakes.removeAll { $0 === ear }
                fail(error.localizedDescription)
            }
        }
    }

    /// `with` names a different ear for this one clip — the Recent rows'
    /// "transcribe again with…" — and leaves the dictation settings alone.
    /// A `live` pick has no upload endpoint at all, so the saved clip is
    /// replayed through the same realtime socket the mic feeds.
    func transcribe(fileURL: URL, with override: (provider: Provider, model: String, live: Bool)? = nil,
                    completion: @escaping (Result<String, Error>) -> Void) {
        let provider = override?.provider ?? Config.shared.provider
        let model = override?.model ?? modelName()
        func fail(_ msg: String) {
            completion(.failure(NSError(domain: "SayCtrl", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])))
        }
        // Local runs inside this process — there is no endpoint to post to and
        // no key to send. The engines want exactly what the recorder already
        // wrote (16 kHz mono PCM), so the file goes straight across.
        if provider == .local {
            Task { @MainActor in
                do {
                    let text = override == nil
                        ? try await LocalEngine.shared.transcribe(fileURL)
                        : try await LocalEngine.shared.transcribe(fileURL, modelID: model)
                    completion(.success(text))
                }
                catch { fail(error.localizedDescription) }
            }
            return
        }
        guard let key = Config.shared.apiKey(for: provider) else {
            DispatchQueue.main.async { fail("No API key configured") }
            return
        }
        if let override = override, override.live {
            let session = LiveTranscriber(provider: provider, model: model, key: key)
            retakes.append(session)
            session.onFinish = { [weak self] result in
                self?.retakes.removeAll { $0 === session }
                completion(result)
            }
            do { try session.start(feeding: fileURL) }
            catch {
                session.cancel()
                retakes.removeAll { $0 === session }
                DispatchQueue.main.async { fail(error.localizedDescription) }
            }
            return
        }
        // A live-only provider has no upload endpoint to fall back on. This
        // shouldn't be reachable — `liveEnabled` is forced on for them — so say
        // plainly what happened rather than firing a request at nothing.
        guard let url = URL(string: provider.transcriptionsURL), !provider.liveOnly else {
            DispatchQueue.main.async {
                fail("\(provider.title) transcribes over the live socket only")
            }
            return
        }
        guard let audioData = try? Data(contentsOf: fileURL) else {
            DispatchQueue.main.async { fail("Could not read recording") }
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(provider.authHeaderValue(key), forHTTPHeaderField: provider.authHeaderName)
        req.timeoutInterval = 90
        if provider == .smallest {
            // smallest.ai takes the WAV bytes as the whole body — no multipart
            // envelope — with the model in the query string. No prompt
            // parameter exists, so the hint list stays home in batch mode.
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            comps.queryItems = [URLQueryItem(name: "model", value: model)]
            req.url = comps.url
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            req.httpBody = audioData
        } else {
            // OpenAI-style transcriptions endpoint: multipart form with the model
            // plus `file`. ElevenLabs calls the model field `model_id`.
            let boundary = "sayctrl-\(UUID().uuidString)"
            var body = Data()
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(provider.modelField)\"\r\n\r\n\(model)\r\n".data(using: .utf8)!)
            // OpenAI-style endpoints take a "prompt" that biases recognition — the
            // same hint list the live socket gets as keyterms, so "copy file path"
            // doesn't come back as "copy file both" in batch mode either. The
            // screen's words ride along: the names you dictate are usually
            // already in the front window, spelled right.
            // xAI biases with repeated `keyterm` fields instead. It ignores a
            // stray `prompt` rather than refusing it, but a hint the model
            // acts on beats one it throws away — and because it acts on them
            // HARD, only the coinages go: see Hints.coinages. Its `format` (numbers and currency written out) is
            // left off on purpose: it is refused without a `language`, and
            // pinning one would cost a bilingual dictation its second half.
            if provider == .xai {
                for term in Hints.coinages(cap: 100, maxLength: 50) {
                    body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"keyterm\"\r\n\r\n\(term)\r\n".data(using: .utf8)!)
                }
            } else if provider.modelField == "model" {
                let hints = Hints.prompt()
                body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"prompt\"\r\n\r\n\(hints)\r\n".data(using: .utf8)!)
            }
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
            body.append(audioData)
            body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }

        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                if let err = err { return fail(err.localizedDescription) }
                guard let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return fail("Bad response from \(provider.title)")
                }
                if let apiErr = json["error"] as? [String: Any], let msg = apiErr["message"] as? String {
                    return fail(msg)
                }
                // ElevenLabs reports failures FastAPI-style, under `detail`: an
                // object for its own errors ("'x' is not a valid model_id"), an
                // array for schema validation, a bare string for the rest.
                if let detail = json["detail"] as? [String: Any] {
                    return fail((detail["message"] as? String) ?? (detail["status"] as? String) ?? "Rejected by \(provider.title)")
                }
                if let detail = json["detail"] as? String { return fail(detail) }
                if let detail = json["detail"] as? [[String: Any]], let first = detail.first {
                    let field = (first["loc"] as? [Any])?.last.map { "\($0): " } ?? ""
                    return fail(field + ((first["msg"] as? String) ?? "Invalid request"))
                }
                // smallest.ai answers with `transcription` where the
                // OpenAI-shaped endpoints say `text`.
                guard let text = (json["text"] as? String) ?? (json["transcription"] as? String) else {
                    // …and reports failures as a bare `message` or `error` string.
                    if let msg = (json["message"] as? String) ?? (json["error"] as? String) {
                        return fail(msg)
                    }
                    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    return fail("Unexpected response (HTTP \(status))")
                }
                completion(.success(text))
            }
        }.resume()
    }

    // MARK: - Paste

    /// The previous paste's app and moment — the fallback witness for
    /// continuation spacing in apps whose text Accessibility can't read.
    private var lastPasteApp: String?
    private var lastPasteAt = Date.distantPast

    /// " " when this dictation lands mid-flow — right on the previous
    /// sentence's full stop — so back-to-back dictations read as one
    /// passage instead of "…the end.And then". The character before the
    /// caret decides (see CorrectionWatcher.beforeCursor); when the app
    /// won't say, the previous paste into the same app within the last
    /// few minutes stands witness. A caret at a line start, after an
    /// opening bracket or quote, or already on whitespace gets nothing.
    func continuationSpace(before text: String) -> String {
        guard let first = text.first,
              first.isLetter || first.isNumber || "\"'“‘([".contains(first) else { return "" }
        func spaceAfter(_ c: Character) -> Bool {
            if c.isWhitespace || c.isNewline { return false }
            if "([{\"'“‘—–-/@#$_".contains(c) { return false }
            return c.isLetter || c.isNumber || ".,!?;:)]}»”’…%".contains(c)
        }
        switch CorrectionWatcher.beforeCursor() {
        case .start:
            return ""
        case .char(let c):
            return spaceAfter(c) ? " " : ""
        case .unknown:
            guard let c = lastPasted.last, spaceAfter(c),
                  Date().timeIntervalSince(lastPasteAt) < 600,
                  NSWorkspace.shared.frontmostApplication?.bundleIdentifier == lastPasteApp
            else { return "" }
            return " "
        }
    }

    /// `rescue`: look for a text box first, and hold the words on the paste
    /// card (PasteCard.swift) when the focus plainly isn't one. Defaults to
    /// `learn` — a dictation's words; generated text, a file path and the
    /// card's own paste go straight in.
    func pasteText(_ text: String, learn: Bool = true, rescue: Bool? = nil) {
        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)

        // Without Accessibility, CGEvent posting is silently dropped — leave the
        // transcript on the clipboard and flag the pill instead.
        guard AXIsProcessTrusted() else {
            log("Paste skipped: Accessibility not granted. Transcript left on clipboard.")
            sendAfterPaste = false   // nothing landed, so nothing to send
            attachAfterPaste = nil   // and the attachment ⌘V would be dropped too
            pill.state = .attention
            hud.show("⚠️ Copied — grant Accessibility to auto-paste (pill → Transcript for the text)", autohide: 3)
            playSound("SayCtrlMiss")
            // Once a launch, the way to fix it: SayControl's own Permissions
            // page, whose Set Up leads into the list. Apple's alert raised on
            // every take came up over System Settings mid-fix and pulled the
            // app in front, which sent the guide away again and again.
            if !Self.sentToPermissions {
                Self.sentToPermissions = true
                SettingsUI.shared.showSettings(tab: "permissions")
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            // A blind ⌘V into a list, a button or the desktop lands nowhere,
            // and the restore below would take the words off the clipboard
            // too. Only a focus that is clearly not text stops the paste —
            // anything the look can't read pastes as it always did.
            if rescue ?? learn {
                let target = PasteTarget.read(terminal: self.frontAppIsTerminal)
                self.log("Paste target: \(target.summary)")
                if target.verdict == .notEditable {
                    // Same as the no-Accessibility path: nothing landed, so
                    // there is nothing to send, attach or learn from — and
                    // the words stay on the clipboard for the card.
                    self.clipboardRestoreWork?.cancel()
                    self.clipboardRestoreWork = nil
                    self.clipboardToRestore = nil
                    self.sendAfterPaste = false
                    // A file riding behind the words is held with them and
                    // goes in after them, as it would have.
                    let attach = self.attachAfterPaste
                    let attachName = self.attachAfterPasteName
                    self.attachAfterPaste = nil
                    var extras: [PasteExtra] = []
                    var replay: (() -> Void)?
                    if let attach = attach {
                        extras.append(.file(attachName))
                        replay = { [weak self] in
                            self?.attachAfterPaste = attach
                            self?.pasteText(text, learn: false)
                        }
                    }
                    PasteCard.shared.show(words: text, extras: extras, replay: replay, target: target, host: self)
                    return
                }
            }
            self.postCmdV()
            self.flashSuccess()
            self.lastPasted = text   // what "scratch that" will take back
            self.lastPasteApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            self.lastPasteAt = Date()
            if self.sendAfterPaste {
                // The message leaves, so nothing stays on screen to watch
                // for a hand-fix — auto-learn sits this one out.
                self.fireQueuedSend()
            } else if learn, Config.shared.autoLearn {
                // Once the text has landed, watch for a hand-fix so we can learn it.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    self.watcher.begin(pasted: text)
                }
            }
            self.fireQueuedAttach()   // the file's turn, one beat behind the words
            // Give the paste a moment to land, then restore the old clipboard.
            if let previous = previous {
                self.clipboardRestoreWork?.cancel()
                self.clipboardToRestore = previous
                let work = DispatchWorkItem {
                    pb.clearContents()
                    pb.setString(previous, forType: .string)
                    self.clipboardToRestore = nil
                }
                self.clipboardRestoreWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
            }
        }
    }

    // MARK: - Terminal targets

    /// Terminals take only text: raw image data on the clipboard is the error
    /// beep the user hears (measured in Terminal running Claude Code,
    /// 2026-08-20). But every terminal AI agent — Claude Code, Codex, aider —
    /// reads an image PATH pasted into the prompt, the same convention as
    /// dropping a file on the window. So a terminal gets the picture as a
    /// file plus its path in the words; every other app gets the picture.
    /// Odd packager bundle ids (Warp, Ghostty) are caught by visible name,
    /// same trick as AppStyle.
    var frontAppIsTerminal: Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let id = (app.bundleIdentifier ?? "").lowercased()
        let name = (app.localizedName ?? "").lowercased()
        let ids = ["apple.terminal", "iterm", "alacritty", "kitty", "wezterm",
                   "hyper", "warp", "ghostty", "tabby", "termius"]
        let names = ["terminal", "iterm2", "warp", "ghostty", "wezterm",
                     "alacritty", "kitty", "tabby", "hyper"]
        return ids.contains { id.contains($0) } || names.contains(name)
    }

    /// A screenshot bound for a terminal becomes a real file the agent can
    /// read. Shots older than three days are swept on each write, so the
    /// folder never grows behind the user's back.
    func saveShotForTerminal(_ png: Data) -> URL? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("SayCtrlShots", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if let old = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for f in old {
                if let d = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   Date().timeIntervalSince(d) > 3 * 86400 {
                    try? fm.removeItem(at: f)
                }
            }
        }
        let stamp = { () -> String in
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd-HH.mm.ss"
            return df.string(from: Date())
        }()
        // No spaces in the name: the path must survive a shell prompt unquoted.
        var url = dir.appendingPathComponent("sayctrl-shot-\(stamp).png")
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("sayctrl-shot-\(stamp)-\(n).png")
            n += 1
        }
        do { try png.write(to: url) } catch {
            log("Screenshot file write failed: \(error.localizedDescription)")
            return nil
        }
        return url
    }

    /// Escape a path the way a file drop on the terminal would, so the shell
    /// and agent prompts read it as one path. Our own shot names need none of
    /// it; attached user files ("Bike Wheel Meme (1).jpg") do. Non-ASCII
    /// stays bare — a backslashed "日" is the wrong kind of careful.
    static func shellEscape(_ path: String) -> String {
        String(path.flatMap { ch -> [Character] in
            guard let ascii = ch.asciiValue else { return [ch] }
            let bare = (48...57).contains(ascii) || (65...90).contains(ascii)
                || (97...122).contains(ascii) || "/._-+=:,@%~".utf8.contains(ascii)
            return bare ? [ch] : ["\\", ch]
        })
    }

    /// Synthesise ⌘V into whatever app has focus. Needs Accessibility.
    func postCmdV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        let vUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        vDown?.flags = .maskCommand
        vUp?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
    }

    /// ⌘A — command mode's "select the whole text box" before the paste.
    func postCmdA() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let aDown = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true)
        let aUp = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
        aDown?.flags = .maskCommand
        aUp?.flags = .maskCommand
        aDown?.post(tap: .cghidEventTap)
        aUp?.post(tap: .cghidEventTap)
    }

    /// Command mode fires right after fn+control — a still-held control key
    /// would merge into the synthetic ⌘A/⌘V and turn it into a different
    /// shortcut. Wait for clean hands, but never longer than a second.
    func waitForModifiersClear(_ then: @escaping () -> Void, tries: Int = 20) {
        let held = NSEvent.modifierFlags
            .intersection([.control, .command, .option, .shift, .function])
        guard !held.isEmpty, tries > 0 else { return then() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.waitForModifiersClear(then, tries: tries - 1)
        }
    }

    // MARK: - Command mode (fn+control — see CommandMode.swift)

    /// The instruction is transcribed; apply it to the captured target and
    /// land the result: over the selection, over the whole box, or fresh at
    /// the caret. One ⌘Z in the target app undoes the edit.
    func executeCommandMode(instruction: String, target: CommandTarget) {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            pill.state = .idle
            hud.show("🤷 No instruction heard", autohide: 1.4)
            return
        }
        guard target.text.count <= CommandMode.maxChars else {
            pill.state = .idle
            hud.show("⚠️ Too much text to rewrite at once — select the part to change", autohide: 3)
            playSound("SayCtrlMiss")
            return
        }
        pill.state = .transcribing
        hud.show("\(trimmed.prefix(60))…", autohide: 1.6)
        log("Command mode (\(target.label)): “\(Config.words(trimmed, upTo: 120))” on \(target.text.count) chars")
        Refiner.shared.command(trimmed, text: target.text) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let out):
                // Character-identical output: there is nothing to change, so
                // don't churn the clipboard and selection for a no-op paste.
                guard out != target.text else {
                    self.pill.state = .idle
                    self.hud.show("✓ Nothing to change", autohide: 1.6)
                    return
                }
                self.log("Command mode result: \(target.text.count)→\(out.count) chars: \(Config.words(out, upTo: 160))")
                ControlStats.shared.note(.commandMode)
                self.lastTranscript = out
                // Generated text is not a transcript — a hand-fix to it says
                // nothing about the recognizer, so auto-learn sits it out.
                self.waitForModifiersClear {
                    if target.mode == .replaceAll { self.postCmdA() }
                    self.pasteText(out, learn: false)   // ⌘V replaces any selection
                }
            case .failure(let error):
                self.pill.state = .idle
                self.log("Command mode failed: \(error.localizedDescription)")
                self.hud.show("⚠️ \(error.localizedDescription)", autohide: 2.5)
                self.playSound("SayCtrlMiss")
            }
        }
    }

    // MARK: - Spoken commands
    // The grammar — what counts as a command and how the transcript splits
    // around it — lives in Commands.swift. This is the execution side.

    /// Resolve every path and link command, splice their text into the
    /// runs, then hand off: to the screenshot paste machinery when pictures
    /// are also due, plain pasteText otherwise.
    func executeCommands(runs: [String], commands: [SpokenCommand]) {
        let pathCount = commands.filter { $0 == .filePath }.count
        let urlCount = commands.filter { $0 == .pageURL }.count
        let shotCount = commands.filter { $0 == .screenshot }.count
        // Partial-stream captures the final transcript didn't confirm.
        if shotCount == 0 { pendingShots.removeAll() }
        resolvePathBatches(pathCount) { [weak self] batches in
            guard let self = self else { return }
            self.resolveURLs(urlCount) { urls in
                if !batches.isEmpty {
                    let n = batches.reduce(0) { $0 + $1.count }
                    self.hud.show(n > 1 ? "📁 \(n) paths inserted" : "📁 Path inserted", autohide: 1.2)
                }
                if !urls.isEmpty {
                    self.hud.show(urls.count > 1 ? "\(urls.count) links inserted" : "Link inserted", autohide: 1.2)
                }
                let segments = self.foldInlineCommands(runs: runs, commands: commands,
                                                       batches: batches, urls: urls)
                let spoken = Commands.joinSpoken(segments)
                if !spoken.isEmpty { self.lastTranscript = spoken }
                if shotCount > 0 {
                    self.pasteScreenshots(segments: segments)
                } else if !spoken.isEmpty {
                    self.pasteText(segments[0])   // no screenshots -> everything merged into one run
                }
                // else: a bare path/link command that found nothing — the
                // HUD from reportPathIssue/reportURLIssue already said so,
                // and there's nothing to paste.
                if shotCount == 0 && spoken.isEmpty { self.fireQueuedAttach(after: 0) }
            }
        }
    }

    // MARK: - File-path command

    /// "copy the file path" → what's selected in Finder right now, or the
    /// folder the front window is showing. Live mode sampled the moment the
    /// command was spoken (checkLivePathCommand); whatever is still missing
    /// — always, in batch mode — is sampled once here for all commands.
    func resolvePathBatches(_ needed: Int, completion: @escaping ([[String]]) -> Void) {
        guard needed > 0 else {
            pendingPathBatches.removeAll()   // stream captures the transcript didn't confirm
            return completion([])
        }
        pathSampleGroup.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            var batches = Array(self.pendingPathBatches.prefix(needed))
            self.pendingPathBatches.removeAll()
            if batches.count >= needed { return completion(batches) }
            FinderPaths.sample { result in
                switch result {
                case .success(let paths):
                    while batches.count < needed { batches.append(paths) }
                case .failure(let issue):
                    self.reportPathIssue(issue)
                }
                completion(batches)
            }
        }
    }

    /// Splice each path and link command's text into the words around it.
    /// One path goes inline ("look at /x and fix it"); several paths and
    /// every link land on their own line. What's left is text runs split
    /// only at screenshot commands, ready for the existing paste machinery.
    func foldInlineCommands(runs: [String], commands: [SpokenCommand],
                            batches: [[String]], urls: [String]) -> [String] {
        func glue(_ a: String, _ b: String, newline: Bool) -> String {
            if a.isEmpty { return b }
            if b.isEmpty { return a }
            return a + (newline ? "\n" : " ") + b
        }
        var segments: [String] = []
        var current = runs[0]
        var nextPath = 0
        var nextURL = 0
        for (i, cmd) in commands.enumerated() {
            let following = runs[i + 1]
            switch cmd {
            case .screenshot:
                segments.append(current)
                current = following
            case .filePath:
                let paths = nextPath < batches.count ? batches[nextPath] : []
                nextPath += 1
                let newline = paths.count > 1
                current = glue(glue(current, paths.joined(separator: "\n"), newline: newline),
                               following, newline: newline)
            case .pageURL:
                let url = nextURL < urls.count ? urls[nextURL] : ""
                nextURL += 1
                // A link gets its own line — chat apps unfurl it, and the
                // words around it stay readable. No stray break when the
                // URL couldn't be resolved.
                let newline = !url.isEmpty
                current = glue(glue(current, url, newline: newline), following, newline: newline)
            }
        }
        segments.append(current)
        return segments
    }

    /// Live mode: sample the Finder selection the moment "copy the path"
    /// shows up in the stream — what you meant is what was selected THEN,
    /// even if you keep talking and click elsewhere.
    func checkLivePathCommand(_ streamed: String) {
        guard live != nil, !pendingPathSampling, !pathSampleFailedLive,
              streamed.lowercased().contains("path") else { return }   // cheap pre-filter, runs on every delta
        let wanted = (Commands.segmentPaths(streamed)?.count ?? 1) - 1
        guard pendingPathBatches.count < wanted else { return }
        pendingPathSampling = true
        pathSampleGroup.enter()
        FinderPaths.sample { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let paths):
                self.pendingPathBatches.append(paths)
                self.playSound("SayCtrlMatch")
                self.announceAction(.filePath, paths.count > 1 ? "\(paths.count) file paths copied" : "File path copied")
            case .failure(let issue):
                // Don't retry on every delta — the finish-time sample will
                // try once more and warn properly. Surface a missing
                // Automation grant now, while the user can still react.
                self.pathSampleFailedLive = true
                if case .notAuthorized = issue { self.reportPathIssue(issue) }
            }
            self.pendingPathSampling = false
            self.pathSampleGroup.leave()
        }
    }

    func reportPathIssue(_ issue: FinderPaths.Issue) {
        switch issue {
        case .nothingSelected:
            hud.show("🤷 Nothing selected in Finder", autohide: 2)
            log("Path command: Finder has no selection and no open window")
        case .notAuthorized:
            hud.show("⚠️ Let SayControl control Finder: Privacy & Security → Automation", autohide: 3.5)
            playSound("SayCtrlMiss")
            log("Path command: Automation permission for Finder missing/denied")
        case .failed(let msg):
            hud.show("⚠️ Couldn't read the Finder selection", autohide: 2.5)
            playSound("SayCtrlMiss")
            log("Path command failed: \(msg)")
        }
    }

    // MARK: - Link command

    /// "copy the link" → the frontmost browser tab's address. Live mode
    /// sampled the moment the command was spoken (checkLiveURLCommand);
    /// whatever is still missing — always, in batch mode — is sampled once
    /// here for all commands.
    func resolveURLs(_ needed: Int, completion: @escaping ([String]) -> Void) {
        guard needed > 0 else {
            pendingURLs.removeAll()   // stream captures the transcript didn't confirm
            return completion([])
        }
        urlSampleGroup.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            var urls = Array(self.pendingURLs.prefix(needed))
            self.pendingURLs.removeAll()
            if urls.count >= needed { return completion(urls) }
            BrowserURL.sample { result in
                switch result {
                case .success(let url):
                    while urls.count < needed { urls.append(url) }
                case .failure(let issue):
                    self.reportURLIssue(issue)
                }
                completion(urls)
            }
        }
    }

    /// Live mode: read the browser tab the moment "copy the link" shows up
    /// in the stream — the page you meant is the one you were on THEN, even
    /// if you keep browsing while talking.
    func checkLiveURLCommand(_ streamed: String) {
        let lower = streamed.lowercased()   // cheap pre-filter, runs on every delta
        guard live != nil, !pendingURLSampling, !urlSampleFailedLive,
              lower.contains("url") || lower.contains("link") || lower.contains("address")
        else { return }
        let wanted = (Commands.segmentURLs(streamed)?.count ?? 1) - 1
        guard pendingURLs.count < wanted else { return }
        pendingURLSampling = true
        urlSampleGroup.enter()
        BrowserURL.sample { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let url):
                self.pendingURLs.append(url)
                self.playSound("SayCtrlMatch")
                self.announceAction(.pageURL, "Link copied")
            case .failure(let issue):
                // Don't retry on every delta — the finish-time sample will
                // try once more and warn properly. Surface a missing
                // Automation grant now, while the user can still react.
                self.urlSampleFailedLive = true
                if case .notAuthorized = issue { self.reportURLIssue(issue) }
            }
            self.pendingURLSampling = false
            self.urlSampleGroup.leave()
        }
    }

    func reportURLIssue(_ issue: BrowserURL.Issue) {
        switch issue {
        case .noBrowser:
            hud.show("🤷 No browser open to copy a link from", autohide: 2)
            log("Link command: no scriptable browser running")
        case .ambiguous:
            hud.show("🤷 Several browsers open — click the one you mean", autohide: 2.5)
            log("Link command: several browsers running, none in front")
        case .unsupported(let name):
            hud.show("⚠️ \(name) can't share its tabs — try Safari or Chrome", autohide: 3)
            log("Link command: \(name) has no tab scripting")
        case .noTab:
            hud.show("🤷 No page open in the browser", autohide: 2)
            log("Link command: browser has no window or a blank tab")
        case .notAuthorized(let name):
            hud.show("⚠️ Let SayControl control \(name): Privacy & Security → Automation", autohide: 3.5)
            playSound("SayCtrlMiss")
            log("Link command: Automation permission for \(name) missing/denied")
        case .failed(let msg):
            hud.show("⚠️ Couldn't read the browser tab", autohide: 2.5)
            playSound("SayCtrlMiss")
            log("Link command failed: \(msg)")
        }
    }

    // MARK: - Ask command

    /// "ask ChatGPT <question>" → the service's prefill link in the default
    /// browser. Needs no permission at all — the URL does the typing:
    /// ChatGPT and Perplexity submit it on arrival, Claude and Grok wait
    /// for one Enter. No synthetic keystrokes into a page we can't see.
    func executeAsk(_ ask: AskCommand) {
        NSWorkspace.shared.open(ask.service.url(for: ask.question))
        hud.show("Asking \(ask.service.displayName)…", autohide: 1.8)
        playSound("SayCtrlMatch")
        log("Ask command: \(ask.service.displayName) ← \(ask.question.isEmpty ? "(front door)" : Config.words(ask.question, upTo: 120))")
    }

    /// How long the local pastes need before the browser may take focus:
    /// a beat for plain text, one per paste step when screenshots are due.
    func askOpenDelay(for remaining: String) -> Double {
        guard let (runs, commands) = Commands.segment(remaining) else { return 1.0 }
        let shots = commands.filter { $0 == .screenshot }.count
        guard shots > 0 else { return 1.2 }   // paths/links resolve, then one pasteText
        return 2.0 + 0.75 * Double(runs.count + shots)
    }

    /// A bare trailing "ask X" after real content: what you composed IS the
    /// message. Text (with paths and links already spliced in) rides the
    /// site's ?q= link; screenshots can't, so with shots in the mix the
    /// site opens plain and the whole message is pasted into its composer
    /// once the browser is actually in front.
    func routeToAsk(_ service: AIService, runs: [String], commands: [SpokenCommand]) {
        ControlStats.shared.note(.ask)
        ControlStats.shared.note(commands)
        let pathCount = commands.filter { $0 == .filePath }.count
        let urlCount = commands.filter { $0 == .pageURL }.count
        let shotCount = commands.filter { $0 == .screenshot }.count
        // Partial-stream captures the final transcript didn't confirm.
        if shotCount == 0 { pendingShots.removeAll() }
        resolvePathBatches(pathCount) { [weak self] batches in
            guard let self = self else { return }
            self.resolveURLs(urlCount) { urls in
                let segments = self.foldInlineCommands(runs: runs, commands: commands,
                                                       batches: batches, urls: urls)
                if shotCount == 0 {
                    self.executeAsk(AskCommand(service: service, question: Commands.joinSpoken(segments)))
                    self.flashSuccess()
                    return
                }
                // Screenshots must be in hand BEFORE the browser covers the
                // screen — batch mode would otherwise photograph the AI site.
                self.shotCaptureGroup.notify(queue: .main) {
                    let needed = segments.count - 1
                    if self.pendingShots.count < needed {
                        self.captureCursorScreenAsync { png in
                            if let png = png {
                                while self.pendingShots.count < needed { self.pendingShots.append(png) }
                            }
                            self.openThenPaste(service, segments: segments)
                        }
                    } else {
                        self.openThenPaste(service, segments: segments)
                    }
                }
            }
        }
    }

    /// Open the site's front door — no ?q=, nothing to send early — and
    /// paste the composed message into its chat box once the browser is
    /// really frontmost, plus a beat for the page to focus its composer.
    func openThenPaste(_ service: AIService, segments: [String]) {
        // Whatever field has the keyboard now is NOT the site's composer —
        // a text box in the browser tab you were on stays focused until the
        // new page takes over, and pasting there would miss.
        let focusedBefore = focusedElement()
        NSWorkspace.shared.open(service.url(for: ""))
        hud.show("Opening \(service.displayName)…", autohide: 2.5)
        playSound("SayCtrlMatch")
        log("Ask command: pasting composed message into \(service.displayName)")
        waitForBrowser(until: Date().addingTimeInterval(8)) { [weak self] ok in
            guard let self = self else { return }
            guard ok else {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(Commands.joinSpoken(segments), forType: .string)
                self.pendingShots.removeAll()
                self.pill.state = .attention
                self.hud.show("⚠️ The browser didn't come forward — your words are on the clipboard", autohide: 3.5)
                self.playSound("SayCtrlMiss")
                return
            }
            // A fixed beat lost the picture whenever ChatGPT loaded slowly:
            // the image ⌘V hit a page with no composer yet and only the
            // later text landed. Paste once the composer holds the focus —
            // or, when the page never says so, at the deadline as before.
            CorrectionWatcher.requestAccessibilityTree(for: NSWorkspace.shared.frontmostApplication)
            self.waitForComposer(excluding: focusedBefore, until: Date().addingTimeInterval(12)) { found in
                self.log("Ask command: \(service.displayName) composer "
                    + (found ? "focused — pasting" : "never reported focus — pasting anyway"))
                DispatchQueue.main.asyncAfter(deadline: .now() + (found ? 0.5 : 0)) {
                    self.pasteScreenshots(segments: segments)
                }
            }
        }
    }

    /// The system-wide focused element, or nil when Accessibility has nothing.
    func focusedElement() -> AXUIElement? {
        CorrectionWatcher.element(of: AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute)
    }

    /// Poll until a text field or area OTHER than `before` holds the focus —
    /// ChatGPT, Claude and Grok focus their composer once the page is ready.
    /// Never sooner than 1.2 s, so an early focus mid-load doesn't count.
    func waitForComposer(excluding before: AXUIElement?, until deadline: Date,
                         started: Date = Date(), _ completion: @escaping (Bool) -> Void) {
        if Date().timeIntervalSince(started) >= 1.2, let el = focusedElement(),
           before.map({ !CFEqual($0, el) }) ?? true {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
            let r = role as? String
            if r == kAXTextAreaRole as String || r == kAXTextFieldRole as String || r == "AXComboBox" {
                return completion(true)
            }
        }
        guard Date() < deadline else { return completion(false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.waitForComposer(excluding: before, until: deadline, started: started, completion)
        }
    }

    // MARK: - Attach command

    /// Live mode: watch the stream for an attach command, but never trust
    /// a fresh sighting — "upload image" is usually just the front half of
    /// "upload image from desktop folder". Resolution runs 0.7s after the
    /// parsed command last CHANGED, and runs again if it grows (a folder,
    /// a fragment, "…the first one"), superseding what it showed before.
    func checkLiveAttach(_ streamed: String) {
        guard live != nil else { return }
        let low = streamed.lowercased()   // cheap pre-filter, runs on every delta
        guard low.contains("attach") || low.contains("upload")
                || low.contains("add") || low.contains("insert") else { return }
        guard let (_, cmd, _) = Commands.splitAttach(streamed), cmd != liveAttachCmd else { return }
        liveAttachCmd = cmd
        liveAttachTimer?.invalidate()
        liveAttachTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self] _ in
            self?.liveResolveAttach(cmd)
        }
    }

    func liveResolveAttach(_ cmd: AttachCommand) {
        guard live != nil, !liveAttachResolving else { return }   // finish handles it instead
        liveAttachResolving = true
        AttachFiles.resolve(cmd) { [weak self] outcome in
            guard let self = self else { return }
            self.liveAttachResolving = false
            // The command grew while we searched — chase the newer form
            // (its own timer already fired into the resolving guard).
            guard self.liveAttachCmd == cmd else {
                if let newer = self.liveAttachCmd { self.liveResolveAttach(newer) }
                return
            }
            switch outcome {
            case .one(let url):
                self.attachPicker.hide()   // supersedes an earlier spread
                self.pendingAttachURL = url
                self.playSound("SayCtrlMatch")
                self.hud.show("\(url.lastPathComponent) ready")   // live preview takes the HUD back
            case .many(let urls):
                self.pendingAttachURL = nil
                self.attachPicker.show(urls, title: "\(min(urls.count, 5)) matches", near: self.pill.capsuleFrame,
                                       dock: self.pill.dock) { [weak self] url in
                    guard let self = self else { return }
                    if self.live != nil {
                        // Chosen mid-dictation — the paste waits for the words.
                        self.pendingAttachURL = url
                        self.attachPicker.hide()
                        self.hud.show("\(url.lastPathComponent) ready")
                    } else {
                        self.pasteAttachment(url)
                    }
                }
                self.playSound("SayCtrlMatch")
            case .issue:
                break   // the finish-time resolve explains properly
            }
        }
    }

    /// "attach the image from downloads" → AttachFiles picks the file(s);
    /// one match delivers straight away, several raise the picker strip —
    /// click a cell or say "the first one" as the next dictation. The same
    /// road serves path queries: only the delivery differs.
    func executeAttach(_ cmd: AttachCommand, afterWords: Bool = false) {
        AttachFiles.resolve(cmd) { [weak self] outcome in
            guard let self = self else { return }
            switch outcome {
            case .one(let url):
                self.deliverPicked(url, cmd, afterWords: afterWords)
            case .many(let urls):
                self.attachPicker.show(urls, title: "\(min(urls.count, 5)) matches", near: self.pill.capsuleFrame,
                                       dock: self.pill.dock) { [weak self] url in
                    self?.deliverPicked(url, cmd, afterWords: afterWords)
                }
                self.playSound("SayCtrlMatch")
                self.log("Attach command: \(urls.count) candidates shown")
            case .issue(let msg):
                self.hud.show(msg, autohide: 2.5)
                self.playSound("SayCtrlMiss")
                self.log("Attach command: \(msg)")
            }
        }
    }

    /// The chosen file, delivered the way the command asked: the file
    /// itself onto the app, or its path as text at the cursor (with a
    /// space when words already landed there this dictation).
    func deliverPicked(_ url: URL, _ cmd: AttachCommand, afterWords: Bool) {
        if cmd.delivery == .path {
            pasteText((afterWords ? " " : "") + url.path, rescue: false)
        } else {
            pasteAttachment(url)
        }
    }

    /// A copied-file paste: the chat app in focus turns the file reference
    /// into a real attachment — the same ⌘V machinery as text, just a
    /// different clipboard flavor (what Finder's ⌘C puts there).
    func pasteAttachment(_ url: URL) {
        // A terminal can't take a file reference — some translate it to a
        // path on their own, others just beep. Hand the agent the path as
        // text ourselves, exactly what dropping the file on the window types.
        if frontAppIsTerminal {
            // Settle any queued restore first, so pasteText sees (and later
            // puts back) the user's own clipboard, not our pasted words.
            clipboardRestoreWork?.cancel()
            if let prev = clipboardToRestore {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(prev, forType: .string)
                clipboardToRestore = nil
            }
            pasteText(Self.shellEscape(url.path), learn: false)
            hud.show("Path pasted — \(url.lastPathComponent)", autohide: 2)
            log("Attached as path (terminal): \(Config.detail(url.path))")
            return
        }
        let pb = NSPasteboard.general
        // A text paste from this same dictation may have its clipboard
        // restore still queued — cancel it NOW, or it fires between our
        // write and our ⌘V and the old clipboard pastes instead of the
        // file (while the HUD claims success). What that restore owed the
        // clipboard (the user's own copy, not our pasted text) is ours to
        // restore instead.
        clipboardRestoreWork?.cancel()
        let previous = clipboardToRestore ?? pb.string(forType: .string)
        pb.clearContents()
        pb.writeObjects([url as NSURL])
        guard AXIsProcessTrusted() else {
            log("Attach skipped: Accessibility not granted. File reference left on clipboard.")
            pill.state = .attention
            hud.show("⚠️ Copied \(url.lastPathComponent) — grant Accessibility to auto-paste", autohide: 3)
            playSound("SayCtrlMiss")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            self.postCmdV()
            self.flashSuccess()
            self.hud.show("Attached \(url.lastPathComponent)", autohide: 2)
            self.log("Attached \(Config.detail(url.path))")
            if let previous = previous {
                self.clipboardRestoreWork?.cancel()
                self.clipboardToRestore = previous
                let work = DispatchWorkItem {
                    pb.clearContents()
                    pb.setString(previous, forType: .string)
                    self.clipboardToRestore = nil
                }
                self.clipboardRestoreWork = work
                // File pastes start an upload in chat apps — give the
                // receiver a beat longer before the clipboard changes back.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
            }
        }
    }

    // MARK: - Open command

    /// "open Chrome" → the app; "open facebook" → the site; "open
    /// reqkey.com" → that address. Unknown names never get here —
    /// OpenTarget decided — this just fires the NSWorkspace call.
    func executeOpen(_ resolution: OpenTarget.Resolution) {
        switch resolution {
        case .app(let url, let name):
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            hud.show("Opening \(name)", autohide: 1.8)
            log("Open command: app \(name) (\(url.path))")
        case .web(let url, let name):
            NSWorkspace.shared.open(url)
            hud.show("Opening \(name)", autohide: 1.8)
            log("Open command: web \(name) (\(Config.detail(String(url.absoluteString.prefix(120)))))")
        }
        playSound("SayCtrlMatch")
    }

    // MARK: - Terminal command

    /// "open terminal in the stocks folder" → the folder is chased exactly
    /// the way "attach the PDF from stocks" chases it. One match opens
    /// there; a name several folders wear raises the same picker strip the
    /// attach command uses — click a cell or say "the first one"; a name
    /// nothing wears still opens the terminal, and the HUD says why it
    /// isn't where you asked.
    func executeTerminal(_ app: TerminalTarget.App, _ cmd: TerminalCommand) {
        TerminalTarget.resolve(cmd) { [weak self] spot in
            guard let self = self else { return }
            switch spot {
            case .folder(let dir):
                self.openTerminal(app, at: dir)
            case .choose(let dirs):
                self.attachPicker.show(dirs, title: "\(min(dirs.count, 5)) “\(cmd.folder ?? "")” folders",
                                       near: self.pill.capsuleFrame, dock: self.pill.dock) { [weak self] dir in
                    self?.openTerminal(app, at: dir)
                }
                self.playSound("SayCtrlMatch")
                self.log("Terminal command: \(dirs.count) candidates shown")
            case .unmatched(let name):
                self.openTerminal(app, at: nil,
                                  note: "🤷 Folder name “\(name)” didn't match — opened \(app.name) anyway")
            case .noFinder:
                self.openTerminal(app, at: nil,
                                  note: "🤷 Finder isn't showing a folder — opened \(app.name) anyway")
            }
        }
    }

    /// The launch itself, and the one line of HUD that says what happened.
    /// `note` replaces that line when the folder was never found — the
    /// terminal still opens, because that is most of what was asked for.
    func openTerminal(_ app: TerminalTarget.App, at dir: URL?, note: String? = nil) {
        TerminalTarget.open(app, at: dir) { [weak self] ok in
            guard let self = self else { return }
            if !ok, let dir = dir {
                // Installed, but it won't take a folder — not every terminal
                // does. Open it plain rather than nothing at all.
                TerminalTarget.open(app, at: nil)
                self.hud.show("\(app.name) opened — it wouldn't start in \(dir.lastPathComponent)",
                              autohide: 3)
                self.playSound("SayCtrlMiss")
                self.log("Terminal command: \(app.name) refused \(Config.detail(dir.path)) — opened plain")
                return
            }
            self.hud.show(note ?? dir.map { "\(app.name) in \($0.lastPathComponent)" }
                               ?? "🖥 Opening \(app.name)",
                          autohide: note == nil ? 2 : 3)
            self.playSound("SayCtrlMatch")
            self.log("Terminal command: \(app.name) at \(dir.map { Config.detail($0.path) } ?? "its own default")")
        }
    }

    // MARK: - Meta commands (scratch / send / model switch)

    /// The whole utterance was an instruction to SayCtrl itself.
    func executeMeta(_ cmd: MetaCommand) {
        pill.state = .idle   // no paste will flash it — outcomes below repaint
        switch cmd {
        case .scratch(let scope): executeScratch([scope])
        case .send:               executeSend()
        case .useLocalModel:      executeModelSwitch(toLocal: true)
        case .usePaidModel:       executeModelSwitch(toLocal: false)
        }
    }

    /// "Scratch that": backspace over exactly what the last paste put at
    /// the cursor. Not the app's Undo — in many apps ⌘Z would eat edits
    /// you made since — and character-counted, so it works the same in a
    /// chat box, a terminal or a code editor. The sentence scope peels one
    /// sentence off the tail and is repeatable — `scopes` applies in
    /// order, so a dictation that opens with several is honored. `then`
    /// runs once the characters are gone: the rest of that dictation
    /// must not paste before its scratch has landed.
    func executeScratch(_ scopes: [ScratchScope], then: (() -> Void)? = nil) {
        guard !lastPasted.isEmpty else {
            pill.state = .idle
            hud.show("🤷 Nothing to scratch", autohide: 1.8)
            log("Scratch command: nothing pasted yet")
            then?()
            return
        }
        guard AXIsProcessTrusted() else {
            pill.state = .needsAccess   // nothing was copied — "press ⌘V" would mislead
            hud.show("⚠️ Grant Accessibility to let SayControl take text back", autohide: 3)
            playSound("SayCtrlMiss")
            then?()   // the words themselves still deserve their paste
            return
        }
        watcher.stop()   // our own deleting must never read as your correction
        var kept = lastPasted
        for scope in scopes {
            kept = scope == .all ? "" : Commands.dropLastSentence(kept).kept
        }
        let count = lastPasted.count - kept.count
        log("Scratch command: removing \(count) character(s)\(kept.isEmpty ? "" : " — last sentence")")
        ControlStats.shared.note(.scratch)
        postBackspaces(count) { [weak self] in
            guard let self = self else { return }
            self.lastPasted = kept
            if !kept.isEmpty { self.lastTranscript = kept }   // the popup shows what's still on screen
            self.hud.show(kept.isEmpty ? "⌫ Scratched" : "⌫ Last sentence scratched", autohide: 1.8)
            self.playSound("SayCtrlMatch")
            self.flashSuccess()
            then?()
        }
    }

    /// "Send it": one Return into the focused app. You said send, so the
    /// keystroke is not a surprise — this is deliberately the only
    /// synthetic Enter in the app.
    func executeSend() {
        guard AXIsProcessTrusted() else {
            pill.state = .needsAccess
            hud.show("⚠️ Grant Accessibility to let SayControl press Return", autohide: 3)
            playSound("SayCtrlMiss")
            return
        }
        postReturn()
        hud.show("Sent", autohide: 1.4)
        playSound("SayCtrlMatch")
        flashSuccess()
        ControlStats.shared.note(.send)
        log("Send command: Return pressed")
    }

    /// Consume a queued "…and send it": one Return, a beat after the ⌘V
    /// so the target app has taken the paste first.
    func fireQueuedSend(after delay: TimeInterval = 0.35) {
        guard sendAfterPaste else { return }
        sendAfterPaste = false
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.postReturn()
            self.hud.show("Sent", autohide: 1.4)
            self.playSound("SayCtrlMatch")
            ControlStats.shared.note(.send)
            self.log("Send command: Return pressed after paste")
        }
    }

    /// Consume a queued attachment: the file's ⌘V one pipeline beat after
    /// the words', so the target app has taken the text paste before the
    /// clipboard flips to the file.
    func fireQueuedAttach(after delay: TimeInterval = 0.6) {
        guard let job = attachAfterPaste else { return }
        attachAfterPaste = nil
        if delay == 0 { return job() }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { job() }
    }

    func postReturn() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: false)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Backspace `n` times, in short bursts with a breath between them so
    /// no app's input queue drops keys, then call `done` on the main queue.
    func postBackspaces(_ n: Int, then done: @escaping () -> Void) {
        guard n > 0 else { return done() }
        let burst = min(n, 25)
        let src = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<burst {
            let down = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: true)
            let up = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: false)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            self.postBackspaces(n - burst, then: done)
        }
    }

    // MARK: - Model switching

    /// "Use the local model" / "back to the paid model". Going local picks
    /// the biggest model downloaded to this Mac — size buys accuracy —
    /// and remembers which paid provider you left, for the trip back. The
    /// HUD always says where you landed.
    func executeModelSwitch(toLocal: Bool) {
        // A user's copy moves between the two places it has without a key:
        // the cloud and this Mac (the one picked here, else the biggest).
        if Config.retail {
            let source = Config.shared.transcriptionSource
            if toLocal {
                guard source != .mac else {
                    hud.show("Already on this Mac — \(LocalEngine.shared.selectedEntry()?.name ?? Config.shared.model)", autohide: 2.4)
                    return
                }
                guard let entry = LocalEngine.shared.selectedEntry() else {
                    hud.show("⚠️ No model on this Mac yet — download one in Settings › Models", autohide: 3.5)
                    playSound("SayCtrlMiss")
                    log("Model switch: no local model installed, still on \(source)")
                    return
                }
                Config.shared.set(Provider.local.modelVar, entry.id)
                Config.shared.setTranscriptionSource(.mac)
                LocalEngine.shared.warmUp()
                hud.show("Switched to this Mac — \(entry.name)", autohide: 2.8)
            } else {
                guard source != .cloud else {
                    hud.show("Already on SayControl Cloud", autohide: 2.4)
                    return
                }
                Config.shared.setTranscriptionSource(.cloud)
                hud.show("Switched to SayControl Cloud", autohide: 2.8)
            }
            playSound("SayCtrlMatch")
            flashSuccess()
            log("Model switch: \(source) → \(Config.shared.transcriptionSource)")
            return
        }
        let current = Config.shared.provider
        if toLocal {
            guard current != .local else {
                hud.show("Already local — \(Config.shared.model)", autohide: 2.4)
                return
            }
            // Nothing to ask over the network any more — the catalogue and what
            // is installed of it are both right here.
            guard let best = LocalEngine.shared.bestInstalledID() else {
                hud.show("⚠️ No local model downloaded — get one in Settings › Models", autohide: 3.5)
                playSound("SayCtrlMiss")
                log("Model switch: no local model installed, provider unchanged")
                return
            }
            Config.shared.set("LAST_PAID_PROVIDER", current.rawValue)
            Config.shared.set(Provider.local.modelVar, best)
            Config.shared.provider = .local
            hud.show("Switched to local — \(best)", autohide: 2.8)
            playSound("SayCtrlMatch")
            flashSuccess()
            log("Model switch: \(current.title) → local (\(best))")
        } else {
            guard current == .local else {
                hud.show("Already on \(current.title) — \(Config.shared.model)", autohide: 2.4)
                return
            }
            // The provider you left for local comes back first; otherwise
            // any paid provider that actually has a key.
            let remembered = Config.shared.env()["LAST_PAID_PROVIDER"].flatMap { Provider(rawValue: $0) }
            let candidates = (remembered.map { [$0] } ?? []) + [.openrouter, .openai, .elevenlabs, .assemblyai, .gemini, .smallest, .meta, .xai, .soniox]
            guard let target = candidates.first(where: { $0 != .local && Config.shared.apiKey(for: $0) != nil }) else {
                hud.show("⚠️ No paid API key — add one in Settings › Models", autohide: 3)
                playSound("SayCtrlMiss")
                log("Model switch: no paid provider has a key, provider unchanged")
                return
            }
            Config.shared.provider = target
            hud.show("Switched to \(target.title) — \(Config.shared.model)", autohide: 2.8)
            playSound("SayCtrlMatch")
            flashSuccess()
            log("Model switch: local → \(target.title) (\(Config.shared.model))")
        }
    }

    /// Poll until the default browser is frontmost — NSWorkspace.open gives
    /// no "it's up" signal — or the deadline passes.
    func waitForBrowser(until deadline: Date, _ completion: @escaping (Bool) -> Void) {
        if let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           BrowserURL.isBrowser(id) { return completion(true) }
        guard Date() < deadline else { return completion(false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.waitForBrowser(until: deadline, completion)
        }
    }

    // MARK: - Screenshot command

    /// PNG of the screen the cursor is on, via /usr/sbin/screencapture (the
    /// same binary ⇧⌘4 uses, so no deprecated APIs). nil on failure — most
    /// likely Screen Recording not granted, which shows as a wallpaper-only
    /// image everywhere else but an outright error here.
    func captureScreenPNG(of screen: NSScreen) -> Data? {
        // screencapture -R wants top-left-origin global points; NSScreen
        // frames are bottom-left-origin relative to the primary screen.
        let primary = NSScreen.screens.first?.frame ?? screen.frame
        let f = screen.frame
        let rect = "\(Int(f.origin.x)),\(Int(primary.maxY - f.maxY)),\(Int(f.width)),\(Int(f.height))"
        let path = NSTemporaryDirectory() + "sayctrl-shot-\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-R\(rect)", path]   // -x: no camera sound
        do { try p.run() } catch {
            log("screencapture failed to launch: \(error.localizedDescription)")
            return nil
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let data = FileManager.default.contents(atPath: path), !data.isEmpty else {
            log("screencapture exited \(p.terminationStatus) with no image")
            return nil
        }
        return data
    }

    /// Hide our own windows, capture the cursor's screen off-main, restore,
    /// hand the PNG back on the main queue. The 0.08s beat gives the window
    /// server a runloop turn to actually drop the pill/HUD from the screen.
    func captureCursorScreenAsync(_ completion: @escaping (Data?) -> Void) {
        let screen = mouseScreen()
        hud.hide(immediately: true)
        speechCard.concealed(true)
        pill.panel.alphaValue = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let png = self?.captureScreenPNG(of: screen)
                DispatchQueue.main.async {
                    // Back to whatever the moment wants: a pill another
                    // surface is fronting for stays invisible.
                    self?.applyPillAlpha()
                    self?.speechCard.concealed(false)
                    completion(png)
                }
            }
        }
    }

    /// Live mode: the words arrive while you are still talking, so each time
    /// a NEW command shows up in the stream we grab the screen right then —
    /// say it three times on three screens, get three different pictures.
    /// The shots wait in pendingShots; finishTranscription decides how many
    /// the final transcript really asked for.
    func checkLiveScreenshot(_ streamed: String) {
        guard live != nil, !pendingShotCapturing,
              streamed.lowercased().contains("screen") else { return }   // cheap pre-filter, runs on every delta
        let wanted = (Commands.segmentScreenshots(streamed)?.count ?? 1) - 1
        guard pendingShots.count < wanted, CGPreflightScreenCaptureAccess() else { return }
        pendingShotCapturing = true
        shotCaptureGroup.enter()
        captureCursorScreenAsync { [weak self] png in
            guard let self = self else { return }
            if let png = png {
                self.pendingShots.append(png)
                self.playSound("SayCtrlMatch")
                let n = self.pendingShots.count
                self.announceAction(.screenshot, n > 1 ? "Screenshot \(n) taken" : "Screenshot taken")
                self.log("Live screenshot #\(n) captured mid-dictation (\(png.count) bytes)")
            }
            self.pendingShotCapturing = false
            self.shotCaptureGroup.leave()
        }
    }

    /// The screenshot command's tail: pair the shots grabbed mid-dictation
    /// with the text runs around each command (waiting for a grab that's
    /// still in flight), then paste everything in spoken order. Missing
    /// shots — batch mode has no stream to watch — are taken now; with
    /// several commands they all show this same final moment.
    func pasteScreenshots(segments: [String]) {
        guard CGPreflightScreenCaptureAccess() else {
            log("Screenshot skipped: Screen Recording not granted")
            hud.show("⚠️ Grant Screen Recording to SayControl for screenshots", autohide: 3)
            playSound("SayCtrlMiss")
            CGRequestScreenCaptureAccess()   // one-time system prompt
            let all = Commands.joinSpoken(segments)
            if !all.isEmpty { pasteText(all) } else { fireQueuedAttach(after: 0) }
            return
        }
        shotCaptureGroup.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            let needed = segments.count - 1
            var shots = Array(self.pendingShots.prefix(needed))
            self.pendingShots.removeAll()
            if shots.count < needed {
                self.captureCursorScreenAsync { [weak self] png in
                    guard let self = self else { return }
                    if let png = png {
                        while shots.count < needed { shots.append(png) }
                    }
                    self.pasteSegments(segments, images: shots)
                }
            } else {
                self.pasteSegments(segments, images: shots)
            }
        }
    }

    /// Load-clipboard steps, each followed by ⌘V and a beat so the target
    /// app takes one paste before the next lands.
    func runPasteSteps(_ steps: [() -> Void], then done: @escaping () -> Void) {
        guard let load = steps.first else { done(); return }
        load()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            self.postCmdV()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                self.runPasteSteps(Array(steps.dropFirst()), then: done)
            }
        }
    }

    /// Paste in spoken order: text run, picture, text run, picture… Each
    /// picture lands exactly where you said "take a screenshot".
    /// `rescue`: look for a text box first, as pasteText does, and hold the
    /// whole sequence on the paste card when there plainly isn't one. The
    /// card's Paste replays it with `rescue` off.
    func pasteSegments(_ segments: [String], images: [Data], rescue: Bool = true) {
        let all = Commands.joinSpoken(segments)
        guard !images.isEmpty else {
            hud.show("⚠️ Screenshot failed — check Screen Recording permission", autohide: 3)
            playSound("SayCtrlMiss")
            if !all.isEmpty { pasteText(all) } else { fireQueuedAttach(after: 0) }
            return
        }
        // A terminal target: each picture becomes a file, its path takes the
        // picture's spot in the words, and the whole thing lands as ONE text
        // paste — the form every terminal AI agent reads (see frontAppIsTerminal).
        if frontAppIsTerminal {
            var parts: [String] = []
            for (i, seg) in segments.enumerated() {
                if !seg.isEmpty { parts.append(seg) }
                if i < images.count, let url = saveShotForTerminal(images[i]) {
                    parts.append(Self.shellEscape(url.path))
                }
            }
            let merged = parts.joined(separator: " ")
            guard !merged.isEmpty else {
                hud.show("⚠️ Screenshot failed — couldn't write the file", autohide: 3)
                playSound("SayCtrlMiss")
                return
            }
            log("Screenshot(s) for a terminal: pasted as path(s)")
            hud.show("Screenshot saved — path pasted", autohide: 1.6)
            return pasteText(merged)
        }
        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string)
        func loadImage(_ png: Data) {
            pb.clearContents()
            pb.setData(png, forType: .png)
            // Some apps only look for TIFF on the pasteboard.
            if let tiff = NSImage(data: png)?.tiffRepresentation {
                pb.setData(tiff, forType: .tiff)
            }
        }
        guard AXIsProcessTrusted() else {
            loadImage(images[0])
            if !all.isEmpty { pb.setString(all, forType: .string) }
            log("Paste skipped: Accessibility not granted. Screenshot left on clipboard.")
            attachAfterPaste = nil   // its ⌘V would be dropped too
            pill.state = .attention
            hud.show("⚠️ Copied — grant Accessibility to auto-paste", autohide: 3)
            playSound("SayCtrlMiss")
            return
        }
        // Nowhere to paste: every ⌘V of the sequence would land nowhere. The
        // words go on the clipboard and the whole take — words, pictures, a
        // file behind them — waits on the card for a text box.
        if rescue {
            let target = PasteTarget.read(terminal: frontAppIsTerminal)
            log("Paste target: \(target.summary)")
            if target.verdict == .notEditable {
                let attach = attachAfterPaste
                let attachName = attachAfterPasteName
                attachAfterPaste = nil
                sendAfterPaste = false
                clipboardRestoreWork?.cancel()
                clipboardRestoreWork = nil
                clipboardToRestore = nil
                pb.clearContents()
                if !all.isEmpty { pb.setString(all, forType: .string) }
                var extras = [PasteExtra.screenshots(images.count)]
                if attach != nil { extras.append(.file(attachName)) }
                PasteCard.shared.show(words: all, extras: extras, replay: { [weak self] in
                    self?.attachAfterPaste = attach
                    self?.pasteSegments(segments, images: images, rescue: false)
                }, target: target, host: self)
                return
            }
        }
        var steps: [() -> Void] = []
        let total = images.count
        for (i, seg) in segments.enumerated() {
            // The last text run goes through pasteText below instead, so
            // auto-learn still watches the final words.
            if !seg.isEmpty && i < segments.count - 1 {
                steps.append { pb.clearContents(); pb.setString(seg, forType: .string) }
            }
            if i < images.count {
                let png = images[i]
                let n = i + 1
                steps.append {
                    loadImage(png)
                    self.hud.show(total > 1 ? "Screenshot \(n)/\(total) pasted" : "Screenshot pasted", autohide: 1.2)
                }
            }
        }
        runPasteSteps(steps) {
            if let lastSeg = segments.last, !lastSeg.isEmpty {
                // The sequence already looked for a text box before its
                // first ⌘V; its last words don't look again.
                self.pasteText(lastSeg, rescue: false)   // consumes a queued "…and send it" / attachment
            } else {
                self.flashSuccess()
                self.fireQueuedSend()   // "take a screenshot and send it"
                self.fireQueuedAttach()
            }
            // pasteText saw an image-only clipboard, so its own restore is
            // a no-op — put the old clipboard back here.
            if let previous = previous {
                self.clipboardRestoreWork?.cancel()
                self.clipboardToRestore = previous
                let work = DispatchWorkItem {
                    pb.clearContents()
                    pb.setString(previous, forType: .string)
                    self.clipboardToRestore = nil
                }
                self.clipboardRestoreWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
            }
        }
    }
}

// `SayCtrl --transcribe <file.wav>` runs one recording through the local engine
// and prints what it heard. No window, no hotkey, no menu bar item — which is
// the point: it checks that a downloaded model actually works without a second
// copy of the app fighting the running one for the fn key.
if let i = CommandLine.arguments.firstIndex(of: "--transcribe"),
   CommandLine.arguments.count > i + 1 {
    let path = CommandLine.arguments[i + 1]
    let started = Date()
    var done = false
    Task {
        do {
            // What the model is told to expect, on stderr: how a missing name gets caught.
            if let entry = LocalEngine.shared.selectedEntry() {
                let hint = LocalEngine.hint(for: entry.family)
                FileHandle.standardError.write(Data("context: \(hint.isEmpty ? "(none)" : hint)\n".utf8))
            }
            let text = try await LocalEngine.shared.transcribe(URL(fileURLWithPath: path))
            let elapsed = String(format: "%.2fs", Date().timeIntervalSince(started))
            // The loaded model, not the configured one — they differ when the
            // saved id is stale and the engine falls back.
            print("[\(LocalEngine.shared.loadedModelID ?? "?") · \(elapsed)] \(text)")
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        }
        DispatchQueue.main.async { done = true }
    }
    // The main run loop keeps turning rather than blocking on a semaphore:
    // the hints Whisper and Qwen3-ASR are given are read on the main thread
    // (Hints.coinages asks the spell checker), and a blocked main thread
    // deadlocks them.
    while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    LocalEngine.shared.unload()
    exit(0)
}

// `SayCtrl --polish "<text>" [--tone agents]` runs one line through the
// cleanup pass, with Your rules applied (CustomRules.swift), and prints what
// would paste. How a rule gets checked against the live model without
// dictating it. There is no front app to take a tone from, so `--tone` names
// the context (personal, work, email, agents) and its picked tone rides along.
if let i = CommandLine.arguments.firstIndex(of: "--polish"),
   CommandLine.arguments.count > i + 1 {
    if let t = CommandLine.arguments.firstIndex(of: "--tone"), CommandLine.arguments.count > t + 1,
       let context = ToneContext(rawValue: CommandLine.arguments[t + 1]) {
        Refiner.shared.styleHint = AppStyle.hint(for: .tone(context, kind: "a test"), appName: "SayControl")
    }
    var done = false
    Refiner.shared.polish(CommandLine.arguments[i + 1]) { out in
        print(out)
        done = true
    }
    while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    exit(0)
}

// `SayCtrl --cloudtest <file.wav> [--realtime] [--direct [provider]]` replays a recording
// through the signed-in cloud path — the relay at api.saycontrol.com, the
// words polished on the server's key — and prints each step with its timing
// and what the plan has left. How the cloud gets checked end to end without a
// hotkey, and without a second app fighting the running one for fn.
// --realtime feeds the clip at the pace a mic would, so "final" is the wait
// after the last word; --direct runs the same clip straight to AssemblyAI on
// this Mac's own key, for the comparison — or to the provider named after it
// (`--direct soniox`), on its live model.
if let i = CommandLine.arguments.firstIndex(of: "--cloudtest"),
   CommandLine.arguments.count > i + 1 {
    let url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    let realtime = CommandLine.arguments.contains("--realtime")
    let direct: Provider? = CommandLine.arguments.firstIndex(of: "--direct").map { d in
        CommandLine.arguments.dropFirst(d + 1).first.flatMap { Provider(rawValue: $0) } ?? .assemblyai
    }
    setvbuf(stdout, nil, _IOLBF, 0)   // each step as it happens, even into a file
    var done = false
    func ms(_ seconds: TimeInterval?) -> String { seconds.map { "\(Int($0 * 1000)) ms" } ?? "never" }
    func step(_ label: String, since: Date) {
        print(String(format: "%-10@ %5d ms", label as NSString, Int(Date().timeIntervalSince(since) * 1000)))
    }
    // The app's key-up, replayed: the live text at that moment goes to the
    // polish (the release pass), and the final text is polished as a paste
    // would be, so whether the two agree, and what the paste waits, shows.
    var liveText = ""
    var keyUp: Date?
    func run(_ ear: LiveTranscriber, bearer: String?, then: @escaping (String) -> Void) {
        ear.onText = { text in
            // After key-up, every change is the tail catching up — when it
            // lands against the final shows how early the last words exist.
            if let keyUp = keyUp, text != liveText {
                print(String(format: "live +%4d ms  …%@", Int(Date().timeIntervalSince(keyUp) * 1000),
                             String(text.suffix(50)) as NSString))
            }
            liveText = text
        }
        ear.onFedAll = {
            keyUp = Date()
            print("key-up     \(liveText)")
            print("unsettled  [\(ear.provisional)]")
            Refiner.shared.observeLive(liveText)
            Refiner.shared.flushRemainder { $0 }
        }
        ear.onCloudMessage = { message in
            if message["type"] as? String == "Begin" {
                print("relay      \(message["vendor"] as? String ?? "?") \(message["model"] as? String ?? "")")
            } else {
                print("relay      \(message)")
            }
        }
        ear.onFinish = { result in
            let heard = Date().timeIntervalSince(ear.openedAt)
            let (ready, commit) = ear.timings
            print("ready      \(ms(ready)) after connecting")
            print("final      \(ms(commit.map { heard - $0 })) after the last audio")
            if case .failure(let e) = result { print("error: \(e.localizedDescription)") }
            then((try? result.get()) ?? "")
        }
        do { try ear.start(feeding: url, bearer: bearer, realtime: realtime) } catch {
            print("error: \(error.localizedDescription)")
            exit(1)
        }
    }
    if let provider = direct {
        guard provider.supportsLive, provider != .local, let key = Config.shared.apiKey(for: provider) else {
            FileHandle.standardError.write(Data("error: no \(provider.title) key in this Mac's settings, or no live socket\n".utf8))
            exit(1)
        }
        let model = Config.shared.model(for: provider, live: true)
        print("direct     \(provider.title) \(model)")
        run(LiveTranscriber(provider: provider, model: model, key: key), bearer: nil) { raw in
            print("raw        \(raw)")
            done = true
        }
    } else {
        guard Cloud.shared.signedIn else {
            FileHandle.standardError.write(Data("error: not signed in to SayControl\n".utf8))
            exit(1)
        }
        let began = Date()
        Cloud.shared.refreshAccount { result in
            step("account", since: began)
            if case .failure(let e) = result { print("error: \(e.localizedDescription)"); exit(1) }
            print("plan       \(Account.usageLine)")
            // What fn going down does: the polish connection warms while you talk.
            Refiner.shared.beginDictation()
            Cloud.shared.withAccessToken { token in
                guard case .success(let bearer) = token else { print("error: no access token"); exit(1) }
                run(LiveTranscriber(provider: .assemblyai, model: ASSEMBLY_LIVE_MODEL, key: ""), bearer: bearer) { raw in
                    print("raw        \(raw) (\(Cloud.words(in: raw)) words)")
                    let polishing = Date()
                    if let keyUp = keyUp { step("text", since: keyUp) }
                    Refiner.shared.polish(raw) { out in
                        step("polish", since: polishing)
                        if let keyUp = keyUp { step("paste", since: keyUp) }
                        print("polished   \(out)")
                        // The relay writes the take down as it closes; give it a moment.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            Cloud.shared.refreshAccount { _ in
                                print("plan       \(Account.usageLine)")
                                done = true
                            }
                        }
                    }
                }
            }
        }
    }
    while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    exit(0)
}

// `SayCtrl --livetest <file.wav>` replays a recording the way the live path sees
// it — one pass every 0.6 s over everything heard so far — and prints each
// partial with how long the pass took. It answers the two questions that
// decide whether streaming is worth having: does the text stay stable as it
// grows, and does a pass finish before the next one is due?
if let i = CommandLine.arguments.firstIndex(of: "--livetest"),
   CommandLine.arguments.count > i + 1 {
    let url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    var done = false
    Task {
        do {
            let all = try LocalEngine.samples(from: url)
            let step = Int(0.6 * 16000)
            var at = step
            while at < all.count + step {
                let slice = Array(all.prefix(min(at, all.count)))
                let started = Date()
                let text = try await LocalEngine.shared.transcribe(samples: slice)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                print(String(format: "%5.1fs  pass %4dms  %@",
                             Double(slice.count) / 16000, ms, text))
                at += step
            }
            print("model: \(LocalEngine.shared.loadedModelID ?? "?")")
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
        }
        DispatchQueue.main.async { done = true }
    }
    // A turning run loop, not a semaphore, for the reason `--transcribe` gives.
    while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    LocalEngine.shared.unload()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
