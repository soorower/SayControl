// Phrases — say the short thing, type the long thing.
//
// The sibling of the Dictionary and deliberately not the same feature: a
// dictionary rule repairs a word the model misheard, a phrase expands words it
// heard perfectly. See Phrases.swift for why expansion runs last.
import Cocoa

final class PhrasesPane: PaneView {

    private let panel = ListPanel()
    private var addRow: AddRow!
    private var addWrap = NSStackView()
    private let empty = Theme.para("", 13 * 1.2, .regular, Theme.muted)
    private var needle = ""
    private var editingID: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
        reload()
        NotificationCenter.default.addObserver(self, selector: #selector(reload),
                                               name: .owPhrasesChanged, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    private func build() {
        let search = SearchToggle { [weak self] text in
            self?.needle = text.trimmingCharacters(in: .whitespaces).lowercased()
            self?.reload()
        }
        let add = FlatButton("Add new", .primary, symbol: "plus") { [weak self] in self?.openAdd() }
        let header = makePaneHeader("Phrases", trailing: Theme.hstack([search, add], spacing: Theme.m(8)))
        let hero = HeroBanner(title: "Say a few words. Get it all.",
                              subtitle: "Save your email, a link or a sign-off once. Say its phrase and it lands exactly as written.",
                              art: .view(PhrasesSketch()))

        addRow = AddRow(leftPlaceholder: "Say this", rightPlaceholder: "Type this", rightFlex: 1.6,
                        onSave: { [weak self] a, b in self?.save(a, b) },
                        onCancel: { [weak self] in self?.closeAdd() })
        addWrap = Theme.vstack([addRow], spacing: 0)
        addWrap.isHidden = true

        // One line; the why behind "exactly" is there on hover.
        let note = Theme.text("Use Edit for a long one, like a signature across several lines.", 12 * 1.2, .regular, Theme.muted)
        note.font = .systemFont(ofSize: Theme.m(12))
        note.toolTip = "The AI polish never rewrites a phrase, and nothing in it is re-capitalised."

        makeCardScroll([header, hero, addWrap, panel, empty, note]).fill(self, inset: 0)
    }

    override func paneAppeared() { reload() }

    @objc private func reload() {
        let all = PhraseStore.shared.phrases
        let shown = all.filter { p in
            guard !needle.isEmpty else { return true }
            return p.trigger.lowercased().contains(needle) || p.expansion.lowercased().contains(needle)
        }
        let rows: [NSView] = shown.map { phrase in
            let row = ListRow(from: phrase.trigger, to: phrase.expansion, hits: phrase.hits,
                              learned: false,
                              onEdit: { [weak self] in self?.edit(phrase) },
                              onDelete: { [weak self] in
                                  PhraseStore.shared.remove(phrase.id)
                                  self?.reload()
                                  SettingsUI.shared.toast("Deleted")
                              })
            row.alphaValue = phrase.enabled ? 1 : 0.5
            return row
        }
        (rows.last as? ListRow)?.hideRule()
        panel.set(rows)
        panel.isHidden = rows.isEmpty
        empty.isHidden = !rows.isEmpty
        empty.stringValue = all.isEmpty
            ? "No phrases yet. Add your email address, a calendar link or a sign-off."
            : "Nothing matches that filter."
    }

    // MARK: Add / edit

    private func openAdd() {
        editingID = nil
        addRow.clear()
        addWrap.isHidden = false
        addRow.focus()
    }

    private func closeAdd() {
        editingID = nil
        addRow.clear()
        addWrap.isHidden = true
    }

    private func save(_ trigger: String, _ expansion: String) {
        let t = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let e = expansion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !e.isEmpty else { return SettingsUI.shared.toast("Fill both sides") }
        guard t.caseInsensitiveCompare(e) != .orderedSame else {
            return SettingsUI.shared.toast("That types what you already said")
        }
        if let id = editingID {
            PhraseStore.shared.setTrigger(id, to: t)
            PhraseStore.shared.setExpansion(id, to: e)
        } else {
            PhraseStore.shared.upsert(trigger: t, expansion: e)
        }
        closeAdd()
        reload()
        SettingsUI.shared.toast("Saved")
    }

    /// A single line edits inline; anything with a line break in it gets the
    /// bigger box, because that layout is the point of the phrase.
    private func edit(_ phrase: Phrase) {
        guard phrase.expansion.contains("\n") else {
            editingID = phrase.id
            addRow.left.stringValue = phrase.trigger
            addRow.right.stringValue = phrase.expansion
            addWrap.isHidden = false
            addRow.focus()
            return
        }
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 380, height: 130))
        text.string = phrase.expansion
        text.font = .systemFont(ofSize: 12.5)
        text.isRichText = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.textContainerInset = NSSize(width: 4, height: 6)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 130))
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let alert = NSAlert()
        alert.messageText = "“\(phrase.trigger)” types"
        alert.informativeText = "Exactly what you write here is what lands at the cursor — line breaks and all."
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = text

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = text.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        PhraseStore.shared.setExpansion(phrase.id, to: value)
        reload()
        SettingsUI.shared.toast("Saved")
    }
}

// MARK: - The hero's picture

/// A short thing said, opening out into a whole block of text: the phrase
/// on the left in the frosted look of words you say, what it types on a
/// cream card, the caret still ember at the end of it.
private final class PhrasesSketch: HeroSketch {
    private let said = "my sign-off"

    override func sketch() {
        let u = Theme.m(1)
        let h = Theme.m(30)
        let font = Theme.saidFont(13)
        let lead = HeroSketch.voiceWidth() + 7 * u
        let chipW = capsuleWidth(said, font: font, height: h, lead: lead)
        let card = NSSize(width: 132 * u, height: 88 * u)
        let gap = 30 * u
        let w = chipW + gap + card.width
        let o = NSPoint(x: (bounds.midX - w / 2).rounded(), y: (bounds.midY - card.height / 2).rounded())
        let chipAt = NSPoint(x: o.x, y: (bounds.midY - h / 2).rounded())
        let cardR = NSRect(x: o.x + chipW + gap, y: o.y, width: card.width, height: card.height)

        // The opening-out: a soft wedge from the phrase to the card.
        let wedge = NSBezierPath()
        wedge.move(to: NSPoint(x: chipAt.x + chipW - h / 2, y: chipAt.y + 3 * u))
        wedge.line(to: NSPoint(x: cardR.minX + 2 * u, y: cardR.minY + 8 * u))
        wedge.line(to: NSPoint(x: cardR.minX + 2 * u, y: cardR.maxY - 8 * u))
        wedge.line(to: NSPoint(x: chipAt.x + chipW - h / 2, y: chipAt.y + h - 3 * u))
        wedge.close()
        NSGradient(starting: NSColor.white.withAlphaComponent(0.02),
                   ending: NSColor.white.withAlphaComponent(0.10))?.draw(in: wedge, angle: 0)

        let chip = capsule(said, at: chipAt, font: font, height: h, look: .said, lead: lead)
        voice(at: NSPoint(x: chip.minX + h / 2 - 2 * u, y: chip.midY - 6 * u), height: 12 * u)

        let body = NSBezierPath(roundedRect: cardR, xRadius: 10 * u, yRadius: 10 * u)
        HeroBanner.cream.setFill()
        body.fill()
        // The text it types, as lines rather than words: any text you save.
        let inset = 14 * u
        let lineW = cardR.width - inset * 2
        var y = cardR.minY + 17 * u
        var last = NSRect.zero
        for f in [0.40, 0.92, 0.78, 0.52] as [CGFloat] {
            last = NSRect(x: cardR.minX + inset, y: y, width: (lineW * f).rounded(), height: 5 * u)
            Theme.paper.withAlphaComponent(0.20).setFill()
            NSBezierPath(roundedRect: last, xRadius: 2.5 * u, yRadius: 2.5 * u).fill()
            y += 15 * u
        }
        Theme.ember.setFill()
        NSBezierPath(roundedRect: NSRect(x: last.maxX + 4 * u, y: last.midY - 6 * u, width: 2 * u, height: 12 * u),
                     xRadius: 1 * u, yRadius: 1 * u).fill()
    }
}
