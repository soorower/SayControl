// The apps a tone applies to, drawn rather than listed.
//
// Tones used to name its places in one long line of text — "Messages ·
// WhatsApp · Telegram · Signal · Discord · …" — which is a lot of reading for
// a point that a row of icons makes at a glance.
//
// Nothing is bundled: the icon is the one already on this Mac, asked of
// LaunchServices by bundle id. An app you don't have (or a site, which has no
// icon to ask for) falls back to a tinted tile with its initial, so the row
// reads the same either way and SayCtrl ships no one else's artwork.
import Cocoa

struct AppMark {
    let name: String
    /// Every bundle id the app has shipped under — first hit wins.
    let ids: [String]
    /// The tile behind the initial when the app isn't installed.
    let tint: NSColor

    init(_ name: String, _ ids: [String] = [], _ tint: UInt32) {
        self.name = name
        self.ids = ids
        self.tint = Theme.hex(tint)
    }
}

enum AppMarks {
    /// Looked up once per bundle id: LaunchServices is quick, but not free,
    /// and the Tones tabs redraw on every pick.
    private static var cache: [String: NSImage?] = [:]

    static func icon(for mark: AppMark) -> NSImage? {
        for id in mark.ids {
            if let cached = cache[id] {
                if let image = cached { return image }
                continue
            }
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            let image = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
            cache[id] = image
            if let image = image { return image }
        }
        return nil
    }

    /// The app that stands for a context in a picture: the first one of its
    /// marks installed on this Mac, or the first mark when none is.
    static func face(for context: ToneContext) -> (mark: AppMark, icon: NSImage?) {
        let marks = marks(for: context)
        for mark in marks {
            if let icon = icon(for: mark) { return (mark, icon) }
        }
        return (marks[0], nil)
    }

    static func marks(for context: ToneContext) -> [AppMark] {
        switch context {
        case .personal:
            return [
                AppMark("Messages", ["com.apple.MobileSMS", "com.apple.iChat"], 0x35C759),
                AppMark("WhatsApp", ["net.whatsapp.WhatsApp", "desktop.WhatsApp"], 0x25D366),
                AppMark("Telegram", ["ru.keepcoder.Telegram", "org.telegram.desktop"], 0x2AABEE),
                AppMark("Signal", ["org.whispersystems.signal-desktop"], 0x3A76F0),
                AppMark("Discord", ["com.hnc.Discord"], 0x5865F2),
                AppMark("Notes", ["com.apple.Notes"], 0xE8C547),
                AppMark("Bear", ["net.shinyfrog.bear"], 0xE0464C),
                AppMark("Obsidian", ["md.obsidian"], 0x7C3AED),
            ]
        case .work:
            return [
                AppMark("Slack", ["com.tinyspeck.slackmacgap"], 0x4A154B),
                AppMark("Teams", ["com.microsoft.teams2", "com.microsoft.teams"], 0x5059C9),
                AppMark("Linear", ["com.linear", "app.linear"], 0x5E6AD2),
                AppMark("Notion", ["notion.id"], 0x2F2F2F),
                AppMark("Jira", ["com.atlassian.jira"], 0x2684FF),
                AppMark("Google Docs", [], 0x4285F4),
                AppMark("Word", ["com.microsoft.Word"], 0x2B579A),
                AppMark("Pages", ["com.apple.iWork.Pages"], 0xF5A623),
            ]
        case .email:
            return [
                AppMark("Mail", ["com.apple.mail"], 0x3A76F0),
                AppMark("Outlook", ["com.microsoft.Outlook"], 0x0F6CBD),
                AppMark("Gmail", [], 0xEA4335),
                AppMark("Spark", ["com.readdle.smartemail-Mac"], 0xE8452C),
                AppMark("Superhuman", ["com.superhuman.electron", "com.superhuman.mac"], 0x1E1E2E),
                AppMark("Mimestream", ["com.mimestream.Mimestream"], 0x3C7BF6),
                AppMark("Proton Mail", ["ch.protonmail.desktop"], 0x6D4AFF),
                AppMark("Fastmail", [], 0x0067B9),
            ]
        case .agents:
            return [
                AppMark("ChatGPT", ["com.openai.chat"], 0x10A37F),
                AppMark("Claude", ["com.anthropic.claudefordesktop", "com.anthropic.claude"], 0xC4451A),
                AppMark("Gemini", [], 0x4285F4),
                AppMark("Perplexity", ["ai.perplexity.mac", "ai.perplexity.comet"], 0x20808D),
                AppMark("Cursor", ["com.todesktop.230313mzl4w4u92"], 0x2B2B2B),
                AppMark("Zed", ["dev.zed.Zed"], 0x0C4A6E),
                AppMark("Terminal", ["com.apple.Terminal"], 0x2E2E2E),
                AppMark("Warp", ["dev.warp.Warp-Stable"], 0x01A0C6),
            ]
        }
    }
}

/// The apps a place covers, as a stack of overlapping logos — no names, so
/// the row stays one line beside the tone switch. Each logo is a rounded
/// square, the shape a Mac app icon already is (design/tones-preview-
/// options.html's `.at`), cut out of the card by a ring of its colour;
/// pointing at one names it.
///
/// Only apps installed on this Mac, with their real icons. A tinted initial
/// said nothing here: a lone "G" or "P" in a row of logos reads as a puzzle,
/// not an app.
final class AppLogoStack: NSView {
    private var marks: [(mark: AppMark, icon: NSImage)] = []
    /// The tile's edge: enough to tell one overlapping logo from the next.
    private static let edge = Theme.dyn(NSColor.black.withAlphaComponent(0.12),
                                        NSColor.white.withAlphaComponent(0.20))
    private let side = Theme.m(20)
    /// How much of each tile the next one covers.
    private let overlap = Theme.m(5)
    private let ring: CGFloat = 2
    private var widthConstraint: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        widthConstraint = widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([widthConstraint, heightAnchor.constraint(equalToConstant: side)])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func set(_ list: [AppMark]) {
        marks = list.compactMap { m in AppMarks.icon(for: m).map { (m, $0) } }
        isHidden = marks.isEmpty
        let n = CGFloat(marks.count)
        widthConstraint.constant = n == 0 ? 0 : n * side - (n - 1) * overlap
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(marks.map(\.mark.name).joined(separator: ", "))
        removeAllToolTips()
        // Each logo names itself over the part of it left showing — the
        // last one drawn is whole, the rest show a crescent.
        for (i, entry) in marks.enumerated() {
            let r = tile(i)
            let shown = i == marks.count - 1 ? r : NSRect(x: r.minX, y: r.minY, width: side - overlap, height: side)
            addToolTip(shown, owner: entry.mark.name as NSString, userData: nil)
        }
        needsDisplay = true
    }

    private func tile(_ i: Int) -> NSRect {
        NSRect(x: CGFloat(i) * (side - overlap), y: 0, width: side, height: side)
    }

    override func draw(_ dirtyRect: NSRect) {
        for (i, entry) in marks.enumerated() {
            let r = tile(i)
            // The cut-out: the card's colour, a ring wide, around the tile.
            Theme.surface.setFill()
            NSBezierPath(roundedRect: r, xRadius: r.width * 0.32, yRadius: r.width * 0.32).fill()
            let inner = r.insetBy(dx: ring, dy: ring)
            let radius = inner.width * 0.28
            let path = NSBezierPath(roundedRect: inner.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            Theme.sideCard.setFill()
            path.fill()
            // A Mac app icon carries its own margin round its rounded
            // square; drawn a fifth larger and clipped to the tile, its own
            // shape fills the tile edge to edge.
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            let s = (inner.width * 1.2).rounded()
            let rect = NSRect(x: inner.midX - s / 2, y: inner.midY - s / 2, width: s, height: s)
            entry.icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                            respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            Self.edge.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}
