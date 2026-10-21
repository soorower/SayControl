// Alerts: when something the app does in the background goes wrong, it says
// so in one place — a card at the top right of the window, over whatever
// pane is open.
//
// Polish used to report its failures in a strip inside the Tones pane, which
// is the one place nobody is looking when a paste comes out raw: the key's
// account ran out of credit and every polish failed for four days while the
// pane looked fine (2026-09-27). A failure now posts here; the next success
// clears it. Each alert has an id, so a repeat replaces rather than stacks,
// and a dismissed one stays gone until something new goes wrong.
import Cocoa

struct AppAlert: Equatable {
    /// One alert per id: "polish", "tones"…
    let id: String
    let title: String
    let message: String
    /// The button that fixes it, when there is one.
    var actionTitle: String?
    var action: (() -> Void)?
    /// Red for something failing; amber for a switch left off.
    var severe = true

    static func == (a: AppAlert, b: AppAlert) -> Bool {
        a.id == b.id && a.title == b.title && a.message == b.message
    }
}

extension Notification.Name {
    static let sayctrlAlertsChanged = Notification.Name("sayctrlAlertsChanged")
}

final class AppAlerts {
    static let shared = AppAlerts()
    private(set) var current: [AppAlert] = []
    /// What was dismissed, by id and wording: the same failure again stays
    /// quiet, a different one comes back.
    private var dismissed: [String: String] = [:]

    /// The alerts still worth showing, newest first.
    var visible: [AppAlert] {
        current.filter { dismissed[$0.id] != $0.title + $0.message }.reversed()
    }

    func post(_ alert: AppAlert) {
        dispatchPrecondition(condition: .onQueue(.main))
        if let i = current.firstIndex(where: { $0.id == alert.id }) {
            guard current[i] != alert else { return }
            current.remove(at: i)
        }
        current.append(alert)
        NotificationCenter.default.post(name: .sayctrlAlertsChanged, object: nil)
    }

    /// The problem is over: its alert goes, and a later one of the same
    /// kind will show even if this one had been dismissed.
    func clear(_ id: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        dismissed[id] = nil
        guard current.contains(where: { $0.id == id }) else { return }
        current.removeAll { $0.id == id }
        NotificationCenter.default.post(name: .sayctrlAlertsChanged, object: nil)
    }

    func dismiss(_ alert: AppAlert) {
        dismissed[alert.id] = alert.title + alert.message
        NotificationCenter.default.post(name: .sayctrlAlertsChanged, object: nil)
    }
}

// MARK: - The card

/// One alert: a tinted card with its icon, what went wrong, the button that
/// fixes it and a close button. Stacked at the window's top right.
final class AlertCard: NSView {
    private let alert: AppAlert

    init(_ alert: AppAlert) {
        self.alert = alert
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(12)
        layer?.borderWidth = 1

        let tint = alert.severe ? Theme.danger : Theme.amber
        let icon = GlyphView(symbol: alert.severe ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill",
                             size: Theme.m(14), weight: .medium, side: Theme.m(18))
        icon.tint = tint
        let title = Theme.text(alert.title, 13, .semibold, Theme.ink)
        let message = Theme.para(alert.message, 12, .regular, Theme.ink2, lineHeight: 1.35)
        var column: [NSView] = [title, message]
        if let label = alert.actionTitle, let run = alert.action {
            let button = FlatButton(label, alert.severe ? .danger : .plain) { [weak self] in
                guard let self = self else { return }
                AppAlerts.shared.dismiss(self.alert)
                run()
            }
            column.append(button)
        }
        let text = Theme.vstack(column, spacing: Theme.m(4))
        text.alignment = .leading
        if column.count > 2 { text.setCustomSpacing(Theme.m(10), after: message) }
        let close = IconButton("xmark", size: 22, icon: 10, tip: "Dismiss") { [weak self] in
            guard let self = self else { return }
            AppAlerts.shared.dismiss(self.alert)
        }

        for v in [icon, text, close] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let pad = Theme.m(14)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Theme.m(340)),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: pad - 1),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Theme.m(10)),
            text.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
            text.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -Theme.m(6)),
            message.widthAnchor.constraint(equalTo: text.widthAnchor),
            close.topAnchor.constraint(equalTo: topAnchor, constant: Theme.m(9)),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.m(9)),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(alert.title + ". " + alert.message)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        // An opaque card under the tint, so the pane doesn't show through.
        let tint = alert.severe ? Theme.danger : Theme.amber
        layer?.backgroundColor = Theme.surface.blended(withFraction: 0.08, of: tint)?.cgColor
            ?? Theme.surface.cgColor
        layer?.borderColor = tint.withAlphaComponent(0.45).cgColor
        Theme.shadow(layer, lift: true)
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// The column of alert cards, pinned to the window's top right. Passes
/// clicks through wherever there is no card.
final class AlertStack: NSStackView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        orientation = .vertical
        alignment = .trailing
        spacing = Theme.m(8)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
                                               name: .sayctrlAlertsChanged, object: nil)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func refresh() {
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        for alert in AppAlerts.shared.visible.prefix(3) { addArrangedSubview(AlertCard(alert)) }
        isHidden = arrangedSubviews.isEmpty
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
