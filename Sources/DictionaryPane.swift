// The Dictionary pane: the words SayControl swaps after every transcription,
// typed in by hand or learned when you fix one right after a paste.
import Cocoa

// MARK: - Dictionary

final class DictionaryPane: PaneView {

    private let panel = ListPanel()
    private var addRow: AddRow!
    private let caseCheck = NSButton(checkboxWithTitle: "Match capitalisation exactly", target: nil, action: nil)
    private var addWrap = NSStackView()
    private let empty = Theme.para("", 13 * 1.2, .regular, Theme.muted)
    private let forget = FlatButton("Forget learned…", .quiet)
    private var needle = ""
    /// Set while the add row is standing in for an existing rule.
    private var editingID: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
        reload()
        NotificationCenter.default.addObserver(self, selector: #selector(reload),
                                               name: .owRulesChanged, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    private func build() {
        let search = SearchToggle { [weak self] text in
            self?.needle = text.trimmingCharacters(in: .whitespaces).lowercased()
            self?.reload()
        }
        let add = FlatButton("Add new", .primary, symbol: "plus") { [weak self] in self?.openAdd() }
        let header = makePaneHeader("Dictionary", trailing: Theme.hstack([search, add], spacing: Theme.m(8)))
        // The picture says what the page is for, so the header doesn't.
        let hero = HeroBanner(title: "Fix a word once. It stays fixed.",
                              subtitle: "Correct a word by hand right after it lands, and SayControl learns it.",
                              art: .view(DictionarySketch()))

        addRow = AddRow(leftPlaceholder: "Heard as", rightPlaceholder: "Write it as",
                        onSave: { [weak self] a, b in self?.save(a, b) },
                        onCancel: { [weak self] in self?.closeAdd() })
        // The option belongs to the rule being written, so it sits in the
        // well with the fields rather than under it.
        caseCheck.font = .systemFont(ofSize: Theme.m(12))
        caseCheck.attributedTitle = NSAttributedString(string: caseCheck.title, attributes: [
            .font: NSFont.systemFont(ofSize: Theme.m(12)), .foregroundColor: Theme.muted,
        ])
        caseCheck.contentTintColor = Theme.ember
        addRow.addFooter(Theme.hstack([caseCheck, Theme.spacer()], spacing: 0))
        addWrap = Theme.vstack([addRow], spacing: 0)
        addWrap.isHidden = true

        forget.onClick = { [weak self] in self?.forgetLearned() }
        let footer = Theme.hstack([Theme.spacer(), forget], spacing: 0)

        makeCardScroll([header, hero, addWrap, panel, empty, footer]).fill(self, inset: 0)
    }

    override func paneAppeared() { reload() }

    // MARK: Rows

    @objc private func reload() {
        let all = ReplacementStore.shared.rules.sorted { $0.created > $1.created }
        let shown = all.filter { rule in
            guard !needle.isEmpty else { return true }
            return rule.from.lowercased().contains(needle) || rule.to.lowercased().contains(needle)
        }
        let rows: [NSView] = shown.map { rule in
            let row = ListRow(from: rule.from, to: rule.to, hits: rule.hits, learned: rule.learned && !rule.hintOnly,
                              onEdit: { [weak self] in self?.openAdd(editing: rule) },
                              onDelete: { [weak self] in self?.delete(rule) })
            return row
        }
        (rows.last as? ListRow)?.hideRule()
        panel.set(rows)
        panel.isHidden = rows.isEmpty
        empty.isHidden = !rows.isEmpty
        empty.stringValue = all.isEmpty
            ? "Nothing here yet. Add a word, or fix one by hand right after it lands."
            : "Nothing matches that filter."
        forget.isHidden = !all.contains { $0.learned }
        SettingsUI.shared.refreshChip()
    }

    /// The trash is one small button next to the pencil, and a mis-hit used to
    /// take a word out with nothing to undo it — so it asks first, and names
    /// the word it is about to forget.
    private func delete(_ rule: ReplacementRule) {
        let alert = NSAlert()
        alert.messageText = "Delete “\(rule.from) → \(rule.to)”?"
        alert.informativeText = rule.hits > 0
            ? "SayControl has used this \(rule.hits) time\(rule.hits == 1 ? "" : "s"). It won't fix that word again."
            : "It won't fix that word again."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ReplacementStore.shared.remove(id: rule.id)
        reload()
        SettingsUI.shared.toast("Deleted")
    }

    // MARK: Add / edit

    private func openAdd(editing rule: ReplacementRule? = nil) {
        editingID = rule?.id
        addRow.left.stringValue = rule?.from ?? ""
        addRow.right.stringValue = rule?.to ?? ""
        caseCheck.state = (rule?.caseSensitive ?? false) ? .on : .off
        addWrap.isHidden = false
        addRow.focus()
    }

    private func closeAdd() {
        editingID = nil
        addRow.clear()
        addWrap.isHidden = true
    }

    private func save(_ from: String, _ to: String) {
        let a = from.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !b.isEmpty else { return SettingsUI.shared.toast("Fill both sides") }
        guard a.caseInsensitiveCompare(b) != .orderedSame || caseCheck.state == .on else {
            return SettingsUI.shared.toast("Those are the same word")
        }
        if let id = editingID {
            ReplacementStore.shared.update(id: id, from: a, to: b)
            ReplacementStore.shared.setCaseSensitive(id: id, caseCheck.state == .on)
        } else {
            ReplacementStore.shared.upsert(from: a, to: b, caseSensitive: caseCheck.state == .on)
        }
        closeAdd()
        reload()
        SettingsUI.shared.toast(editingID == nil ? "Added" : "Saved")
    }

    private func forgetLearned() {
        let alert = NSAlert()
        alert.messageText = "Forget every learned word?"
        alert.informativeText = "The words you typed in by hand stay. Anything SayControl picked up from your corrections goes."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        ReplacementStore.shared.removeAllLearned()
        reload()
        SettingsUI.shared.toast("Learned words forgotten")
    }
}

// MARK: - The hero's picture

/// "art browser" heard, the fix, "Arc browser" from then on — the pair
/// Corrections.swift learns from, drawn the way the list shows a rule.
private final class DictionarySketch: HeroSketch {
    private let heard = "art browser"
    private let fixed = "Arc browser"

    override func sketch() {
        let u = Theme.m(1)
        let h = Theme.m(30)
        let font = Theme.saidFont(13.5)
        let bold = Theme.saidFont(13.5, .medium)
        let heardW = capsuleWidth(heard, font: font, height: h)
        let fixedW = capsuleWidth(fixed, font: bold, height: h, trail: 16 * u)
        let step = 64 * u
        let w = max(heardW, step + fixedW), ht = h * 2 + 30 * u
        let o = NSPoint(x: (bounds.midX - w / 2).rounded(), y: (bounds.midY - ht / 2).rounded())

        // The fix, kept: two fainter copies stand behind it, the next times
        // you say it.
        let fixedAt = NSPoint(x: o.x + step, y: o.y + h + 30 * u)
        for (i, a) in [(2, 0.10), (1, 0.22)] as [(CGFloat, CGFloat)] {
            ghost(NSRect(x: fixedAt.x + i * 9 * u, y: fixedAt.y + i * 7 * u, width: fixedW, height: h), alpha: a)
        }

        let said = capsule(heard, at: o, font: font, height: h, look: .said)
        // The misheard word wears the squiggle a spelling checker would give it.
        let artW = ("art" as NSString).size(withAttributes: [.font: font]).width
        squiggle(from: NSPoint(x: said.minX + h / 2, y: said.midY + 8 * u), width: artW)

        let got = capsule(fixed, at: fixedAt, font: bold, height: h, look: .landed, trail: 16 * u)
        symbol("checkmark", size: 10.5 * u, color: Theme.paper.withAlphaComponent(0.55),
               center: NSPoint(x: got.maxX - h / 2 + 2 * u, y: got.midY))

        arrow(from: NSPoint(x: said.minX + 24 * u, y: said.maxY + 6 * u),
              to: NSPoint(x: got.minX - 8 * u, y: got.midY))
    }
}
