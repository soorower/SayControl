// Help — three ways to reach us, and the four things that actually go wrong.
import Cocoa

/// A tappable row: a tinted icon tile, what it does, and an arrow. The
/// shape the Help pane is made of. It reads as a link — ink, underlined
/// on hover — and never as ember: nothing here is live. The tile's hue
/// says what kind of help it is, the way System Settings colours its rows.
final class HelpRow: NSView {
    private let titleField: NSTextField
    private let title: String
    private let go: NSTextField
    private var hovering = false { didSet { restyle(); needsDisplay = true } }
    private let action: () -> Void

    /// `link` is a stretch of the detail that is itself an address — it
    /// is set in ink so it reads as one. `more` is the longer story, for
    /// the tooltip: the line under the title stays one line.
    init(symbol: String, hue: Theme.Hue, title: String, detail: String, more: String? = nil,
         link: String? = nil, arrow: String = "↗", action: @escaping () -> Void) {
        self.action = action
        self.title = title
        titleField = Hub.text(title, 13, .medium)
        let detailField = Hub.text(detail, 12, .regular, Theme.muted)
        if let link = link, let range = detail.range(of: link) {
            let text = NSMutableAttributedString(attributedString: detailField.attributedStringValue)
            text.addAttribute(.foregroundColor, value: Theme.ink, range: NSRange(range, in: detail))
            detailField.attributedStringValue = text
        }
        go = Hub.text(arrow, 13.5, .regular, Theme.faint)
        super.init(frame: .zero)
        wantsLayer = true
        toolTip = more

        let tile = IconTile(symbol, hue)

        let words = Theme.vstack([titleField, detailField], spacing: Theme.m(2))
        detailField.widthAnchor.constraint(equalTo: words.widthAnchor).isActive = true
        let row = Theme.hstack([tile, words, go], spacing: Theme.m(12))
        row.distribution = .fill
        words.setHuggingPriority(.init(1), for: .horizontal)
        go.setContentHuggingPriority(.required, for: .horizontal)
        go.setContentCompressionResistancePriority(.required, for: .horizontal)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(14)),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.m(16)),
            row.topAnchor.constraint(equalTo: topAnchor, constant: Theme.m(11)),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.m(11)),
        ])
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func restyle() {
        go.textColor = hovering ? Theme.ink : Theme.faint
        titleField.attributedStringValue = NSAttributedString(string: title, attributes: [
            .font: titleField.font ?? NSFont.systemFont(ofSize: Theme.m(13), weight: .medium),
            .foregroundColor: Theme.ink,
            .underlineStyle: hovering ? NSUnderlineStyle.single.rawValue : 0,
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        action()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override var mouseDownCanMoveWindow: Bool { false }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = (hovering ? Theme.navHover : .clear).cgColor
    }
    override func viewDidChangeEffectiveAppearance() { restyle(); needsDisplay = true }
}

final class HelpPane: PaneView {
    static let supportEmail = "support@saycontrol.com"
    static let guideURL = "https://saycontrol.com/install"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        // No hero here: the page is four ways to reach us and four answers,
        // and the tinted tiles are picture enough for that.
        let header = makePaneHeader("Help", "Something not working? Write to us.")

        let ways = HubGroup()
        ways.add(HelpRow(symbol: "envelope.fill", hue: .blue, title: "Email support",
                         detail: "\(Self.supportEmail) · we answer within a day", link: Self.supportEmail) {
            let subject = "SayControl support".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let u = URL(string: "mailto:\(Self.supportEmail)?subject=\(subject)") {
                NSWorkspace.shared.open(u)
            }
        }, padded: false)
        ways.add(HelpRow(symbol: "ladybug.fill", hue: .rose, title: "Report a problem",
                         detail: "An email to us with a diagnostics file. Never your transcripts.",
                         more: "Opens an email to us with a diagnostics file: versions, model, and what the app did when. No transcripts.",
                         arrow: "→") {
            Self.reportProblem()
        }, padded: false)
        ways.add(HelpRow(symbol: "book.closed.fill", hue: .green, title: "Getting started",
                         detail: "Setup, shortcuts and voice commands.") {
            NSWorkspace.shared.open(URL(string: Self.guideURL)!)
        }, padded: false)
        ways.add(HelpRow(symbol: "arrow.counterclockwise", hue: .violet, title: "Run the setup again",
                         detail: "Permissions, microphone, the key and a first dictation.",
                         arrow: "→") {
            OnboardingWindow.shared.present(at: 0)
        }, padded: false)

        let fixes = HubGroup()
        let faq = [
            ("Nothing types when I release fn", "Grant Accessibility, then quit and reopen SayControl."),
            ("fn opens the emoji picker", "System Settings → Keyboard → “Press 🌐 key to” → Do Nothing."),
            ("“Unexpected reply” mid-dictation", "The cloud model was slow, so the raw transcript went in. Nothing is lost."),
            ("A name keeps coming out wrong", "Fix it right after it lands, and SayControl remembers it in the Dictionary."),
        ]
        for item in faq {
            let a = Hub.para(item.1, 12, .regular, Theme.muted, lineHeight: 1.3)
            let pair = Theme.vstack([Self.question(item.0), a], spacing: Theme.m(3))
            a.widthAnchor.constraint(equalTo: pair.widthAnchor).isActive = true
            fixes.add(pair, padY: 12)
        }

        Hub.scroll([header, ways, Hub.section(Hub.head("Common fixes"), fixes)]).fill(self, inset: 0)
    }

    /// A question with its keys drawn as keys. "fn" is a thing you press, so
    /// it wears the keycap the sidebar and Settings draw it with.
    private static func question(_ s: String) -> NSView {
        var parts: [NSView] = []
        var words: [String] = []
        func flush() {
            guard !words.isEmpty else { return }
            parts.append(Hub.text(words.joined(separator: " "), 13, .medium))
            words = []
        }
        for word in s.split(separator: " ").map(String.init) {
            if word == "fn" {
                flush()
                parts.append(KeyCapView(word, small: true))
            } else {
                words.append(word)
            }
        }
        flush()
        return Theme.hstack(parts, spacing: Theme.m(6))
    }

    // MARK: - Report a problem

    /// A Mail draft to support with the diagnostics attached as a file, so
    /// the person sees exactly what is being sent and presses Send
    /// themselves. Without a mail client to hand the draft to, the text goes
    /// on the clipboard and the address opens instead.
    private static func reportProblem() {
        let text = diagnostics()
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("SayControl-diagnostics-\(Int(Date().timeIntervalSince1970)).txt")
        try? text.write(to: file, atomically: true, encoding: .utf8)

        let body = """
        Hi SayControl,

        What I was doing:

        What happened instead:

        (The attached file has my app and macOS versions, the model I use, and \
        the app's own log of what it did and when. It has none of my dictations in it.)
        """
        if let mail = NSSharingService(named: .composeEmail),
           mail.canPerform(withItems: [body, file]) {
            mail.recipients = [supportEmail]
            mail.subject = "SayControl \(Updates.version) — problem report"
            mail.perform(withItems: [body, file])
        } else {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            let subject = "SayControl \(Updates.version) — problem report"
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let u = URL(string: "mailto:\(supportEmail)?subject=\(subject)") {
                NSWorkspace.shared.open(u)
            }
            SettingsUI.shared.toast("Diagnostics copied — paste them into the email")
        }
    }

    /// Everything we would ask for in a bug report, and nothing we would not:
    /// the versions, the setup, and the log lines that say what the app DID —
    /// never the ones that say what was SAID. The log carries transcripts,
    /// dictionary words and file names, so lines are let through by prefix,
    /// not filtered out by pattern: a new kind of line is private until it is
    /// added here.
    private static func diagnostics() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let provider = Config.shared.provider
        var out = """
        SayControl \(Updates.version)
        macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)
        Mac: \(hardwareModel())
        Provider: \(provider.title)
        Model: \(Config.shared.model)
        Live streaming: \(Config.shared.liveEnabled ? "on" : "off")
        Accessibility: \(AXIsProcessTrusted() ? "granted" : "not granted")
        Cleanup: \(Config.shared.cleanup ? "on" : "off")   Auto-learn: \(Config.shared.autoLearn ? "on" : "off")   Screen words: \(Config.shared.screenVocab ? "on" : "off")

        Recent log (events and errors only; no dictation text):

        """
        out += recentLog(lines: 120).joined(separator: "\n")
        return out
    }

    /// The log line prefixes that describe behaviour without quoting anyone.
    private static let safePrefixes = [
        "Launched", "Took over", "Microphone access", "fn event tap", "Provider set",
        "Model switch", "Local model", "Live session", "Live recording", "Live streaming",
        "Recording started", "Recording stopped", "Clip too short", "Empty transcript",
        "Transcription error", "Refine: usage", "Refine: final pass", "Refine: deadline",
        "Refine: release pass", "Paste skipped", "Loaded ", "Update",
    ]

    private static func recentLog(lines count: Int) -> [String] {
        guard let text = try? String(contentsOf: Config.shared.logURL, encoding: .utf8) else {
            return ["(no log file)"]
        }
        let kept = text.split(separator: "\n").compactMap { raw -> String? in
            let line = String(raw)
            // "[2026-08-23 01:10:40] " then the message.
            guard let close = line.firstIndex(of: "]") else { return nil }
            let message = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            return safePrefixes.contains(where: { message.hasPrefix($0) }) ? line : nil
        }
        return Array(kept.suffix(count))
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        let model = String(cString: buf)
        #if arch(arm64)
        return "\(model) (Apple silicon)"
        #else
        return "\(model) (Intel)"
        #endif
    }
}
