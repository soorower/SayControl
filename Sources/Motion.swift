// Motion: the few small movements the app makes, in one place.
//
// Things arrive the same way everywhere — a short fade while they lift a few
// points into place, top to bottom, a beat apart — so the first-run window
// and the main window's pages feel like one app. Numbers count up to their
// value and meter columns fill from the floor when a page opens. Everything
// here is Core Animation on the view's own layer: the model value is already
// the final one, so a missed frame or a cancelled animation leaves the view
// where it belongs, never half-way. Reduce Motion turns all of it off.
import Cocoa

/// A chart that can draw itself part-way filled: 0 is empty, 1 is the real
/// value. Page entrances run it from 0 to 1.
protocol Growable: AnyObject {
    var grow: CGFloat { get set }
}

enum Motion {
    static var reduced: Bool { still || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Set by --snapshot: a capture taken mid-fade showed one section's
    /// title over the last one's page.
    static var still = false

    /// Ease out, the curve everything arrives on.
    static let ease = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
    /// Ease out with a small overshoot, for things that pop.
    static let pop = CAMediaTimingFunction(controlPoints: 0.3, 1.45, 0.5, 1)

    /// "Subtle", the page motion picked in design/welcome-redesign.html.
    enum Page {
        static let outDuration: TimeInterval = 0.11
        static let distance: CGFloat = 10
        static let duration: TimeInterval = 0.38
        static let stagger: TimeInterval = 0.04
    }

    /// A translation that reads as "down" on screen for this view: layers
    /// move in their superlayer's space, which is flipped when the superview is.
    private static func down(_ d: CGFloat, _ view: NSView) -> CGFloat {
        (view.superview?.isFlipped ?? false) ? d : -d
    }

    /// Fades a view in while it lifts `distance` points into place.
    /// Negative distance comes down from above instead.
    static func rise(_ view: NSView, delay: TimeInterval = 0, duration: TimeInterval = Page.duration,
                     distance: CGFloat = Page.distance, scale: CGFloat = 1) {
        view.wantsLayer = true
        view.alphaValue = 1
        guard let layer = view.layer, !reduced else { return }
        let begin = CACurrentMediaTime() + delay
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let move = CABasicAnimation(keyPath: "transform.translation.y")
        move.fromValue = down(distance, view)
        move.toValue = 0
        var parts: [CAAnimation] = [fade, move]
        if scale != 1 {
            let s = CABasicAnimation(keyPath: "transform.scale")
            s.fromValue = scale
            s.toValue = 1
            parts.append(s)
        }
        for a in parts {
            a.beginTime = begin
            a.duration = duration
            a.timingFunction = ease
            a.fillMode = .backwards
        }
        layer.add(fade, forKey: "motion.fade")
        layer.add(move, forKey: "motion.move")
        if parts.count > 2 { layer.add(parts[2], forKey: "motion.scale") }
    }

    /// Fades a view in, no movement.
    static func fadeIn(_ view: NSView, delay: TimeInterval = 0, duration: TimeInterval = 0.4) {
        view.wantsLayer = true
        view.alphaValue = 1
        guard let layer = view.layer, !reduced else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.beginTime = CACurrentMediaTime() + delay
        fade.duration = duration
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        fade.fillMode = .backwards
        layer.add(fade, forKey: "motion.fade")
    }

    /// Fades a view out while it drifts `lift` points up, then runs `done`.
    /// The view ends at alpha 0; whoever shows it again sets it back.
    static func leave(_ view: NSView, delay: TimeInterval = 0, duration: TimeInterval = Page.outDuration,
                      lift: CGFloat = 4, done: (() -> Void)? = nil) {
        view.wantsLayer = true
        guard let layer = view.layer, !reduced else {
            view.alphaValue = 0
            done?()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { done?() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = view.alphaValue
        fade.toValue = 0
        let move = CABasicAnimation(keyPath: "transform.translation.y")
        move.fromValue = 0
        move.toValue = -down(lift, view)
        for a in [fade, move] {
            a.beginTime = CACurrentMediaTime() + delay
            a.duration = duration
            a.timingFunction = CAMediaTimingFunction(name: .easeIn)
            a.fillMode = .both
            a.isRemovedOnCompletion = false
        }
        layer.add(fade, forKey: "motion.fade")
        layer.add(move, forKey: "motion.move")
        CATransaction.commit()
    }

    /// Takes a view out of any motion it is in and puts it back at rest.
    static func settle(_ view: NSView) {
        view.layer?.removeAnimation(forKey: "motion.fade")
        view.layer?.removeAnimation(forKey: "motion.move")
        view.layer?.removeAnimation(forKey: "motion.scale")
        view.alphaValue = 1
    }

    // MARK: Tweens that CA can't do on its own

    private final class Tween {
        let start: CFTimeInterval
        let duration: TimeInterval
        let step: (CGFloat) -> Void
        init(start: CFTimeInterval, duration: TimeInterval, step: @escaping (CGFloat) -> Void) {
            self.start = start; self.duration = duration; self.step = step
        }
    }
    private static var tweens: [Tween] = []
    private static var ticker: Timer?

    /// Calls `step` with an eased 0…1 every frame for `duration`, after `delay`.
    /// `step(1)` always runs last, so the end state is exact.
    static func tween(duration: TimeInterval, delay: TimeInterval = 0, _ step: @escaping (CGFloat) -> Void) {
        if reduced { step(1); return }
        step(0)
        tweens.append(Tween(start: CACurrentMediaTime() + delay, duration: duration, step: step))
        guard ticker == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            let now = CACurrentMediaTime()
            tweens = tweens.filter { tw in
                let k = min(1, max(0, (now - tw.start) / tw.duration))
                guard now >= tw.start else { return true }
                tw.step(CGFloat(1 - pow(1 - k, 3)))
                return k < 1
            }
            if tweens.isEmpty { ticker?.invalidate(); ticker = nil }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    /// Counts a figure up from zero to what it already says: "3,763",
    /// "35m", "2/30". The text it ends on is exactly the text it had.
    static func countUp(_ field: NSTextField, delay: TimeInterval = 0.12, duration: TimeInterval = 0.65) {
        let final = field.attributedStringValue
        let s = final.string
        guard let range = s.range(of: #"[0-9][0-9,]*(\.[0-9]+)?"#, options: .regularExpression) else { return }
        let numberText = String(s[range])
        guard let value = Double(numberText.replacingOccurrences(of: ",", with: "")), value > 0 else { return }
        let decimals = numberText.split(separator: ".").dropFirst().first?.count ?? 0
        let grouped = numberText.contains(",") || value >= 1000
        let prefix = String(s[..<range.lowerBound]), suffix = String(s[range.upperBound...])
        let attrs = final.length > 0 ? final.attributes(at: 0, effectiveRange: nil) : [:]
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = grouped
        f.minimumFractionDigits = decimals
        f.maximumFractionDigits = decimals
        tween(duration: duration, delay: delay) { [weak field] k in
            guard let field = field else { return }
            if k >= 1 { field.attributedStringValue = final; return }
            let n = f.string(from: NSNumber(value: value * Double(k))) ?? ""
            field.attributedStringValue = NSAttributedString(string: prefix + n + suffix, attributes: attrs)
        }
    }

    // MARK: A page arriving

    /// The page's blocks, top to bottom: the arranged views of the first
    /// vertical stack that holds more than one of them. Panes are built as a
    /// column of blocks (title, banner, cards), so this finds that column.
    static func blocks(in root: NSView) -> [NSView] {
        var queue: [NSView] = [root]
        while !queue.isEmpty {
            let v = queue.removeFirst()
            if let stack = v as? NSStackView, stack.orientation == .vertical {
                let shown = stack.arrangedSubviews.filter { !$0.isHidden }
                if shown.count > 1 { return shown }
            }
            queue += v.subviews
        }
        return [root]
    }

    /// Everything in `root` that asks to be animated on arrival: figures
    /// marked `countUp`, and charts that can grow.
    private static func collect(_ root: NSView, fields: inout [NSTextField], charts: inout [Growable]) {
        if let f = root as? NSTextField, f.identifier == countUpID { fields.append(f) }
        if let g = root as? Growable { charts.append(g) }
        for v in root.subviews where !v.isHidden { collect(v, fields: &fields, charts: &charts) }
    }

    /// Mark a figure to count up when its page opens.
    static let countUpID = NSUserInterfaceItemIdentifier("motion.countUp")

    /// A page opening: its blocks arrive top to bottom, figures count up and
    /// meters fill. `direction` is +1 moving down the sidebar, -1 moving up,
    /// so the page comes from the side the row is on. `extraDelay` gives a
    /// window a moment to appear first.
    static func arrive(_ page: NSView, direction: CGFloat = 1, extraDelay: TimeInterval = 0) {
        guard !reduced else { return }
        page.layoutSubtreeIfNeeded()
        let blocks = blocks(in: page)
        for (i, b) in blocks.enumerated() {
            rise(b, delay: extraDelay + Double(min(i, 8)) * Page.stagger, distance: Page.distance * direction)
        }
        var fields: [NSTextField] = [], charts: [Growable] = []
        collect(page, fields: &fields, charts: &charts)
        fields.forEach { countUp($0, delay: extraDelay + 0.12) }
        for c in charts {
            tween(duration: Page.duration + 0.16, delay: extraDelay + 0.16) { [weak c] k in c?.grow = k }
        }
    }
}
