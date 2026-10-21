// Which keys do what, and the box on the General tab that shows and
// records them.
//
// Three bindings, each with room for several keys. Hold to dictate is a
// key held down: fn out of the box, or any other modifier key, an F-key,
// or a key with modifiers (⌃F) — up to four of them, any one works.
// Command mode is the dictate gesture plus one modifier (control, out of
// the box). Hands-free is a press that starts and stops a dictation; it
// has no key until one is given, the menu bar does it meanwhile. Cancel is
// esc and stays esc.
//
// The app reads these through `Shortcuts` on every key event — they are
// cached here, reloaded when the box saves one.
import Cocoa

/// One key, with the modifiers held alongside it. A modifier key on its
/// own (fn, the right option key) is a key too: keyCode set, no modifiers.
struct KeyShortcut: Equatable {
    var keyCode: UInt16
    /// Command, option, shift and control only — the bits a person holds
    /// on purpose. Caps lock, the numeric pad and fn-as-a-flag are left out
    /// so "F5" matches F5 however it was reached.
    var modifiers: NSEvent.ModifierFlags
    /// What the key is called: "F5", "space", "D". Modifier keys and the
    /// special keys name themselves; anything else keeps the character the
    /// recorder saw, since working a name out of a key code again later
    /// would need the same keyboard layout.
    var label: String

    static let fn = KeyShortcut(keyCode: 63, modifiers: [], label: "fn")

    static let heldModifiers: NSEvent.ModifierFlags = [.command, .option, .shift, .control]

    /// The flag a modifier key carries, when it is one.
    static func flag(forModifierKey code: UInt16) -> NSEvent.ModifierFlags? {
        switch code {
        case 63:     return .function
        case 59, 62: return .control
        case 58, 61: return .option
        case 56, 60: return .shift
        case 54, 55: return .command
        default:     return nil
        }
    }
    /// Both keys that carry a flag, left then right.
    static func keyCodes(for flag: NSEvent.ModifierFlags) -> [UInt16] {
        switch flag {
        case .function: return [63]
        case .control:  return [59, 62]
        case .option:   return [58, 61]
        case .shift:    return [56, 60]
        case .command:  return [54, 55]
        default:        return []
        }
    }
    var modifierFlag: NSEvent.ModifierFlags? { Self.flag(forModifierKey: keyCode) }
    var isModifierKey: Bool { modifierFlag != nil }
    /// Two or more modifiers pressed together — fn + option, control +
    /// command — with no other key. The key is one of them (fn whenever fn
    /// is in it), the rest ride in `modifiers`.
    var isChord: Bool { isModifierKey && !modifiers.isEmpty }
    /// Every flag the gesture holds, for a modifier key or a chord; empty
    /// for a key press.
    var chordFlags: NSEvent.ModifierFlags {
        guard let flag = modifierFlag else { return [] }
        return modifiers.union(flag)
    }
    /// The bits a chord is compared against: the held modifiers and fn.
    static let allModifierFlags: NSEvent.ModifierFlags = heldModifiers.union(.function)

    static let fKeys: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
        100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13",
        107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19",
    ]
    static let specialKeys: [UInt16: String] = [
        49: "space", 36: "return", 48: "tab", 51: "delete", 53: "esc",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "home", 119: "end",
        116: "page up", 121: "page down", 117: "⌦", 76: "enter",
    ]

    /// The name a key goes by, from the event that carried it.
    static func label(for event: NSEvent) -> String {
        let code = event.keyCode
        if let flag = flag(forModifierKey: code) { return modifierName(flag, code: code) }
        if let f = fKeys[code] { return f }
        if let s = specialKeys[code] { return s }
        let chars = event.charactersIgnoringModifiers ?? ""
        return chars.isEmpty ? "key \(code)" : chars.uppercased()
    }
    static func modifierName(_ flag: NSEvent.ModifierFlags, code: UInt16? = nil) -> String {
        switch flag {
        case .function: return "fn"
        case .control:  return "control"
        case .option:   return "option"
        case .shift:    return "shift"
        case .command:  return "command"
        default:        return "?"
        }
    }

    // MARK: Storage — "keyCode|modifierBits|label"

    var stored: String { "\(keyCode)|\(modifiers.rawValue)|\(label)" }

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.heldModifiers)
        self.label = label
    }
    init?(stored: String) {
        let bits = stored.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard bits.count == 3, let code = UInt16(bits[0]), let raw = UInt(bits[1]) else { return nil }
        self.init(keyCode: code, modifiers: NSEvent.ModifierFlags(rawValue: raw), label: String(bits[2]))
    }

    // MARK: Display

    /// The pieces the box draws, modifiers first, the way they are written.
    /// A chord reads in the order it is pressed: its key, then the rest.
    var parts: [KeyPart] {
        var out: [KeyPart] = []
        if let flag = modifierFlag, isChord { out.append(KeyPart(flag)) }
        for flag in [NSEvent.ModifierFlags.control, .option, .shift, .command] where modifiers.contains(flag) {
            out.append(KeyPart(flag))
        }
        if let flag = modifierFlag { if !isChord { out.append(KeyPart(flag)) } }
        else { out.append(KeyPart(label, symbol: Self.specialKeys[keyCode] == "esc" ? "escape" : nil)) }
        return out
    }
    /// One line for the menu bar and the log: "fn", "right option", "⌃F5".
    var text: String { parts.map { $0.name }.joined(separator: " ") }

    /// Does this key press match the combo exactly? Chords never do — they
    /// are matched on flags, not on a press.
    func matches(_ event: NSEvent) -> Bool {
        !isModifierKey && event.keyCode == keyCode
            && event.modifierFlags.intersection(Self.heldModifiers) == modifiers
    }

    /// A chord from the modifiers held together. fn is the key when it is
    /// in the set, otherwise the one pressed first, so the cap reads the
    /// way the fingers went down.
    static func chord(_ flags: NSEvent.ModifierFlags, first: UInt16) -> KeyShortcut? {
        let set = flags.intersection(allModifierFlags)
        guard set.rawValue.nonzeroBitCount >= 2 else { return nil }
        let keyCode: UInt16
        if set.contains(.function) { keyCode = 63 }
        else if let f = flag(forModifierKey: first), set.contains(f) { keyCode = first }
        else { return nil }
        let keyFlag = flag(forModifierKey: keyCode)!
        return KeyShortcut(keyCode: keyCode, modifiers: set.subtracting(keyFlag), label: modifierName(keyFlag))
    }

    /// Would this key type something while held? A modifier key, an F-key,
    /// or any key with a modifier on it is safe; a bare letter, space or
    /// arrow is not.
    var isHoldable: Bool {
        isModifierKey || !modifiers.isEmpty || Self.fKeys[keyCode] != nil
    }
}

/// A key's name and the symbol that stands for it on the cap, if Apple
/// draws one.
struct KeyPart {
    let name: String
    let symbol: String?
    init(_ name: String, symbol: String? = nil) {
        self.name = name
        self.symbol = symbol
    }
    init(_ flag: NSEvent.ModifierFlags) {
        switch flag {
        case .function: self.init("fn", symbol: "globe")
        case .control:  self.init("control", symbol: "control")
        case .option:   self.init("option", symbol: "option")
        case .shift:    self.init("shift", symbol: "shift")
        case .command:  self.init("command", symbol: "command")
        default:        self.init("?")
        }
    }
}

// MARK: - The bindings

enum Shortcuts {
    /// Held to dictate: never empty. A modifier key, an F-key, or a key with
    /// modifiers — never a bare letter, which would type into the app in
    /// front while it is down. The event tap swallows the non-modifier
    /// ones, so ⌃F held for SayCtrl is not also ⌃F to the app in front.
    private(set) static var dictateKeys: [KeyShortcut] = [.fn]
    /// The first dictate key: what the menu bar and the onboarding name.
    static var dictate: KeyShortcut { dictateKeys[0] }
    /// Held with a dictate key for command mode.
    private(set) static var commandModifier: NSEvent.ModifierFlags = .control
    /// Presses that start and stop a hands-free dictation; empty means the
    /// menu bar alone.
    private(set) static var handsFreeKeys: [KeyShortcut] = []

    /// How many keys one action can have.
    static let maxKeys = 4

    /// True while a box is listening for a key: the app's own handlers stand
    /// down, so the press being recorded does not also start a dictation.
    static var recording = false

    static let changed = Notification.Name("sayctrlShortcutsChanged")

    // Stored as KEY_DICTATE, KEY_DICTATE_2, _3, _4 — one line per key, so
    // a label can be any character at all.
    private static func names(_ base: String) -> [String] {
        (1...maxKeys).map { $0 == 1 ? base : "\(base)_\($0)" }
    }
    private static func loadKeys(_ base: String, from env: [String: String]) -> [KeyShortcut] {
        var out: [KeyShortcut] = []
        for name in names(base) {
            if let k = env[name].flatMap(KeyShortcut.init(stored:)), !out.contains(k) { out.append(k) }
        }
        return out
    }
    private static func saveKeys(_ base: String, _ keys: [KeyShortcut]) {
        for (i, name) in names(base).enumerated() {
            Config.shared.set(name, i < keys.count ? keys[i].stored : nil)
        }
    }

    static func load() {
        let env = Config.shared.env()
        let d = loadKeys("KEY_DICTATE", from: env)
        dictateKeys = d.isEmpty ? [.fn] : d
        if let raw = env["KEY_COMMAND_MOD"].flatMap(UInt.init),
           [NSEvent.ModifierFlags.control, .option, .shift, .command].contains(where: { $0.rawValue == raw }) {
            commandModifier = NSEvent.ModifierFlags(rawValue: raw)
        } else {
            commandModifier = .control
        }
        handsFreeKeys = loadKeys("KEY_HANDSFREE", from: env)
    }

    static func setDictateKeys(_ keys: [KeyShortcut]) {
        let keys = keys.isEmpty ? [.fn] : Array(keys.prefix(maxKeys))
        saveKeys("KEY_DICTATE", keys == [.fn] ? [] : keys)
        Config.shared.log("Dictate keys set to \(keys.map(\.text).joined(separator: ", "))")
        load()
        NotificationCenter.default.post(name: changed, object: nil)
    }
    static func setCommandModifier(_ flag: NSEvent.ModifierFlags) {
        Config.shared.set("KEY_COMMAND_MOD", flag == .control ? nil : String(flag.rawValue))
        Config.shared.log("Command modifier set to \(KeyShortcut.modifierName(flag))")
        load()
        NotificationCenter.default.post(name: changed, object: nil)
    }
    static func setHandsFreeKeys(_ keys: [KeyShortcut]) {
        saveKeys("KEY_HANDSFREE", Array(keys.prefix(maxKeys)))
        Config.shared.log("Hands-free keys set to \(keys.isEmpty ? "menu bar only" : keys.map(\.text).joined(separator: ", "))")
        load()
        NotificationCenter.default.post(name: changed, object: nil)
    }
    /// Back to how the app ships: fn, control, the menu bar.
    static func resetToDefault() {
        saveKeys("KEY_DICTATE", [])
        Config.shared.set("KEY_COMMAND_MOD", nil)
        saveKeys("KEY_HANDSFREE", [])
        Config.shared.log("Shortcuts reset to default")
        load()
        NotificationCenter.default.post(name: changed, object: nil)
    }
    static var isDefault: Bool {
        dictateKeys == [.fn] && commandModifier == .control && handsFreeKeys.isEmpty
    }

    /// What the General tab and the menu bar call the command gesture.
    static var command: [KeyPart] { dictate.parts + [KeyPart(commandModifier)] }

    /// The dictate key this modifier-key event is, if any — a single
    /// modifier, not a chord.
    static func dictateKey(forModifierCode code: UInt16) -> KeyShortcut? {
        dictateKeys.first { $0.isModifierKey && !$0.isChord && $0.keyCode == code }
    }
    /// The dictate chord these held modifiers complete, if any.
    static func dictateChord(held: NSEvent.ModifierFlags) -> KeyShortcut? {
        let set = held.intersection(KeyShortcut.allModifierFlags)
        return dictateKeys.first { $0.isChord && $0.chordFlags == set }
    }
    /// The hands-free chord these held modifiers complete, if any.
    static func handsFreeChord(held: NSEvent.ModifierFlags) -> KeyShortcut? {
        let set = held.intersection(KeyShortcut.allModifierFlags)
        return handsFreeKeys.first { $0.isChord && $0.chordFlags == set }
    }
    /// The chord that is command mode: a dictate modifier plus the command
    /// modifier. Nothing else may be bound to it.
    static func isCommandChord(_ key: KeyShortcut) -> Bool {
        guard key.isChord else { return false }
        return dictateKeys.contains { d in
            guard let f = d.modifierFlag, !d.isChord else { return false }
            return key.chordFlags == f.union(commandModifier)
        }
    }
    /// The dictate key this key press is, if any — modifiers must match.
    static func dictateKey(matching event: NSEvent) -> KeyShortcut? {
        dictateKeys.first { !$0.isModifierKey && $0.matches(event) }
    }
    /// Is this key code one of the non-modifier dictate keys?
    static func isDictateKeyCode(_ code: UInt16) -> Bool {
        dictateKeys.contains { !$0.isModifierKey && $0.keyCode == code }
    }
    static func handsFreeKey(matching event: NSEvent) -> KeyShortcut? {
        handsFreeKeys.first { $0.matches(event) }
    }
}

// MARK: - The row

/// The right side of one shortcut line: the key as keycaps and a quiet
/// Change after them, flush with the group's right edge. One key per job —
/// there is no + for another. A second key saved by an older version still
/// shows, under the first, with a bin to take it away; hands-free with no
/// key at all shows "Click to add a shortcut".
///
/// Drawn the refresh mockup's way: each key a physical keycap. The Change
/// slot keeps one width whether it reads Change or Cancel, so the caps stay
/// in one column down the whole Shortcuts group.
final class ShortcutRow: NSView {
    enum Role { case dictate, commandModifier, handsFree, fixed }
    private let role: Role
    private let column = NSStackView()
    private var boxes: [ShortcutBox] = []

    init(_ role: Role, parts: [KeyPart] = []) {
        self.role = role
        super.init(frame: .zero)
        column.orientation = .vertical
        // One width down the column, the stack's own way: a wide chord
        // widens its neighbours too.
        // Right-aligned, so a legacy second key with its bin sticks out to
        // the left of the column rather than pushing the first key over.
        column.alignment = .trailing
        column.spacing = Theme.m(4)
        column.setHuggingPriority(.required, for: .horizontal)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        rebuild(fixedParts: parts)
        NotificationCenter.default.addObserver(self, selector: #selector(changed),
                                               name: Shortcuts.changed, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func changed() {
        // A box mid-listen keeps its place; the others redraw from the store.
        guard !boxes.contains(where: { $0.isListening }) else { return }
        rebuild()
    }

    private var keys: [KeyShortcut] {
        switch role {
        case .dictate:   return Shortcuts.dictateKeys
        case .handsFree: return Shortcuts.handsFreeKeys
        default:         return []
        }
    }

    private func rebuild(fixedParts: [KeyPart] = []) {
        boxes.forEach { $0.removeFromSuperview() }
        boxes = []
        switch role {
        case .commandModifier:
            add(ShortcutBox(.commandModifier, index: 0))
        case .fixed:
            add(ShortcutBox(.fixed, index: 0, parts: fixedParts))
        case .dictate, .handsFree:
            let ks = keys
            if ks.isEmpty {
                add(ShortcutBox(role == .dictate ? .dictate : .handsFree, index: 0))   // the placeholder
            }
            for i in ks.indices { add(ShortcutBox(role == .dictate ? .dictate : .handsFree, index: i)) }
        }
    }
    private func add(_ box: ShortcutBox) {
        box.onChange = { [weak self] in self?.rebuild() }
        boxes.append(box)
        column.addArrangedSubview(box)
    }
}

// MARK: - The box

/// One key as a line: its parts as keycaps, then Change, and the bin before
/// the caps where the key can go. Clicking Change or the caps starts
/// listening — the caps give way to "Listening…" inside the ember focus
/// ring, since the box is live then — and the next key pressed becomes the
/// binding; esc or Cancel backs out.
///
/// What a box takes. Dictate: a modifier key on its own, an F-key, or any
/// key with modifiers held (⌃F, ⌥space). Hands-free: an F-key or a key
/// with modifiers. Command mode: one modifier. A modifier on its own is
/// taken when it comes back UP with nothing pressed in between — so fn can
/// also be held to reach an F-key on a Mac keyboard without becoming the
/// key itself.
final class ShortcutBox: NSView {
    typealias Role = ShortcutRow.Role
    private let role: Role
    /// Which of the action's keys this box shows; equal to the count for a
    /// box that is still empty.
    private let index: Int
    /// Where the caps sit; it wears the focus ring while listening.
    private let cap = NSView()
    private let halo = CALayer()
    private let chips = NSStackView()
    private var change: FlatButton?
    private var bin: IconButton?
    private let hint = Theme.para("", 11.5)
    private var monitor: Any?
    private(set) var isListening = false
    /// A modifier key that went down on its own while listening; it becomes
    /// the binding when it comes back up, unless another key lands first.
    private var pendingModifier: (code: UInt16, flag: NSEvent.ModifierFlags)?
    /// The most modifiers held at once since the last one went down from
    /// nothing, and which went down first: two or more is a chord, taken
    /// when the first of them comes back up.
    private var chordPeak: NSEvent.ModifierFlags = []
    private var chordFirst: UInt16?
    /// The row redraws itself from the store after a save or a removal.
    var onChange: () -> Void = {}

    /// The bin and the + are bare icon buttons of one size.
    static let iconSide: CGFloat = 26
    /// A fixed square for an icon button that may or may not be there.
    static func slot() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: Theme.px(iconSide)).isActive = true
        v.heightAnchor.constraint(equalToConstant: Theme.px(iconSide)).isActive = true
        return v
    }

    init(_ role: Role, index: Int, parts: [KeyPart] = []) {
        self.role = role
        self.index = index
        super.init(frame: .zero)

        // The caps, with room around them for the ring to draw without the
        // line shifting when it appears.
        cap.wantsLayer = true
        cap.layer?.cornerRadius = Theme.m(8)
        cap.layer?.borderWidth = 1
        cap.layer?.masksToBounds = false
        halo.cornerRadius = Theme.m(8) + Theme.m(3)
        halo.borderWidth = Theme.m(3)
        halo.isHidden = true
        cap.layer?.addSublayer(halo)
        cap.translatesAutoresizingMaskIntoConstraints = false
        chips.orientation = .horizontal
        chips.alignment = .centerY
        chips.spacing = Theme.m(6)
        chips.setHuggingPriority(.required, for: .horizontal)
        chips.setContentCompressionResistancePriority(.required, for: .horizontal)
        chips.translatesAutoresizingMaskIntoConstraints = false
        cap.addSubview(chips)
        NSLayoutConstraint.activate([
            cap.heightAnchor.constraint(equalToConstant: Theme.m(46)),
            chips.leadingAnchor.constraint(equalTo: cap.leadingAnchor, constant: Theme.m(4)),
            chips.trailingAnchor.constraint(equalTo: cap.trailingAnchor, constant: -Theme.m(4)),
            chips.centerYAnchor.constraint(equalTo: cap.centerYAnchor),
        ])
        cap.setContentHuggingPriority(.required, for: .horizontal)

        // A bin only for a second key an older version saved — after
        // Change, at the right edge, where it can't be mistaken for the
        // way to change the first.
        let binSlot = Self.slot()
        if role == .dictate || role == .handsFree, removable {
            let b = IconButton("trash", size: Self.iconSide, icon: 12, tip: "Remove this key") { [weak self] in
                self?.remove()
            }
            bin = b
            b.translatesAutoresizingMaskIntoConstraints = false
            binSlot.addSubview(b)
            NSLayoutConstraint.activate([
                b.centerXAnchor.constraint(equalTo: binSlot.centerXAnchor),
                b.centerYAnchor.constraint(equalTo: binSlot.centerYAnchor),
            ])
        }

        // Change, quiet, after the caps. esc has nothing to change and no
        // slot for it either: its cap sits at the right edge, where Change
        // ends on the rows above.
        let c = FlatButton("Change", .quiet) { [weak self] in self?.toggleListening() }
        c.toolTip = "Change the key"
        c.isHidden = role == .fixed
        change = role == .fixed ? nil : c
        let changeSlot = NSView()
        c.translatesAutoresizingMaskIntoConstraints = false
        changeSlot.addSubview(c)
        NSLayoutConstraint.activate([
            c.leadingAnchor.constraint(equalTo: changeSlot.leadingAnchor),
            c.trailingAnchor.constraint(equalTo: changeSlot.trailingAnchor),
            c.topAnchor.constraint(equalTo: changeSlot.topAnchor),
            c.bottomAnchor.constraint(equalTo: changeSlot.bottomAnchor),
            // "Cancel" while listening is wider than "Change"; the slot is
            // sized for the wider word so nothing moves.
            changeSlot.widthAnchor.constraint(equalToConstant: Self.changeWidth),
        ])

        let line = Theme.hstack(role == .fixed ? [cap] : (bin != nil ? [cap, changeSlot, binSlot] : [cap, changeSlot]),
                                spacing: Theme.m(4))
        line.setHuggingPriority(.required, for: .horizontal)

        hint.alignment = .right
        hint.isHidden = true
        // A long hint wraps under the caps instead of squeezing the row's words.
        hint.widthAnchor.constraint(lessThanOrEqualToConstant: Theme.px(260)).isActive = true
        let column = Theme.vstack([line, hint], spacing: Theme.m(4))
        column.alignment = .trailing
        column.setHuggingPriority(.required, for: .horizontal)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        if parts.isEmpty { showCurrent() } else { show(parts) }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { stopListening() }

    /// The wider of Change and Cancel, as a quiet button draws them.
    private static var changeWidth: CGFloat {
        ["Change", "Cancel"].map { FlatButton($0, .quiet).fittingSize.width }.max() ?? 0
    }

    /// Only a second key can go: each job keeps the one it has, and Change
    /// is how that one moves.
    private var removable: Bool {
        switch role {
        case .dictate:   return index >= 1 && index < Shortcuts.dictateKeys.count
        case .handsFree: return index >= 1 && index < Shortcuts.handsFreeKeys.count
        default:         return false
        }
    }

    private var current: KeyShortcut? {
        switch role {
        case .dictate:   return index < Shortcuts.dictateKeys.count ? Shortcuts.dictateKeys[index] : nil
        case .handsFree: return index < Shortcuts.handsFreeKeys.count ? Shortcuts.handsFreeKeys[index] : nil
        default:         return nil
        }
    }

    private func showCurrent() {
        switch role {
        case .commandModifier: show(Shortcuts.command)
        case .fixed:           break
        case .dictate, .handsFree:
            if let key = current { show(key.parts) } else { showPlaceholder() }
        }
    }

    private func clearChips() { chips.arrangedSubviews.forEach { $0.removeFromSuperview() } }

    /// Caps side by side, the way the keys sit on the keyboard — no "+"
    /// between them.
    private func show(_ parts: [KeyPart]) {
        clearChips()
        for part in parts { chips.addArrangedSubview(KeyChip(part)) }
        needsDisplay = true
    }

    private func showPlaceholder() {
        clearChips()
        let f = Theme.text("Click to add a shortcut", 12, .regular, Theme.muted)
        f.font = .systemFont(ofSize: Theme.m(12))
        chips.addArrangedSubview(f)
        needsDisplay = true
    }

    private func showListening() {
        clearChips()
        let f = Theme.text("Listening…", 12, .medium, Theme.emberInk)
        f.font = .systemFont(ofSize: Theme.m(12), weight: .medium)
        chips.addArrangedSubview(f)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if role != .fixed, !isListening { beginListening() }
    }
    override func resetCursorRects() {
        if role != .fixed { addCursorRect(convert(cap.bounds, from: cap), cursor: .pointingHand) }
    }
    override func layout() {
        super.layout()
        let out = Theme.m(3)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        halo.frame = cap.bounds.insetBy(dx: -out, dy: -out)
        CATransaction.commit()
    }

    private func toggleListening() {
        isListening ? cancel() : beginListening()
    }

    func beginListening() {
        guard !isListening, !Shortcuts.recording else { return }
        isListening = true
        Shortcuts.recording = true
        pendingModifier = nil
        chordPeak = []
        chordFirst = nil
        showListening()
        change?.title = "Cancel"
        bin?.isHidden = true
        hint.isHidden = false
        switch role {
        case .dictate:         hint.stringValue = "Press a key, with modifiers or not: fn, F5, ⌃F, or two modifiers together. esc keeps the old one."
        case .commandModifier: hint.stringValue = "Press control, option, shift or command. esc keeps the old one."
        case .handsFree:       hint.stringValue = "Press an F-key, a combination like ⌥space, or two modifiers together like fn + option. esc backs out."
        case .fixed:           hint.stringValue = ""
        }
        window?.makeFirstResponder(nil)
        // System-defined events are the F-row doing its media job — the
        // only trace a bare F5 leaves on a Mac keyboard, so it is worth a
        // word about why nothing was taken.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .systemDefined]) { [weak self] event in
            guard let self = self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private func stopListening() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        if isListening { Shortcuts.recording = false }
        isListening = false
        pendingModifier = nil
    }

    private func settle() {
        stopListening()
        change?.title = "Change"
        bin?.isHidden = false
        hint.isHidden = true
    }

    private func cancel() {
        settle()
        if current == nil, role != .commandModifier, index > 0 {
            onChange()   // an empty box added with + goes away again
        } else {
            showCurrent()
        }
    }

    private func finish() {
        settle()
        onChange()
    }

    private func remove() {
        switch role {
        case .dictate:
            var keys = Shortcuts.dictateKeys
            guard keys.count > 1, index < keys.count else { return }
            keys.remove(at: index)
            Shortcuts.setDictateKeys(keys)
        case .handsFree:
            var keys = Shortcuts.handsFreeKeys
            guard index < keys.count else { return }
            keys.remove(at: index)
            Shortcuts.setHandsFreeKeys(keys)
        default:
            return
        }
        onChange()
    }

    private func save(_ key: KeyShortcut) {
        switch role {
        case .dictate:
            var keys = Shortcuts.dictateKeys
            if index < keys.count { keys[index] = key } else { keys.append(key) }
            Shortcuts.setDictateKeys(keys)
        case .handsFree:
            var keys = Shortcuts.handsFreeKeys
            if index < keys.count { keys[index] = key } else { keys.append(key) }
            Shortcuts.setHandsFreeKeys(keys)
        default:
            break
        }
    }

    /// The other keys this one must not collide with.
    private func taken(_ key: KeyShortcut) -> String? {
        let others = Shortcuts.dictateKeys.enumerated().filter { !(role == .dictate && $0.offset == index) }.map(\.element)
        if others.contains(key) { return "That is already a dictate key." }
        let free = Shortcuts.handsFreeKeys.enumerated().filter { !(role == .handsFree && $0.offset == index) }.map(\.element)
        if free.contains(key) { return "That is already a hands-free key." }
        return nil
    }

    /// True when the event was consumed. A key that does not fit the role
    /// leaves the box listening and says why.
    private func handle(_ event: NSEvent) -> Bool {
        if event.type == .systemDefined {
            // Subtype 8: a media key — brightness, volume, the keyboard light.
            guard event.subtype.rawValue == 8 else { return false }
            hint.stringValue = "That is a media key here. Hold fn with it, or turn on “Use F1, F2… as standard function keys” in Keyboard settings."
            return true
        }
        if event.type == .keyDown, event.keyCode == 53 { cancel(); return true }   // esc
        if event.type == .flagsChanged { return handleModifier(event) }
        guard event.type == .keyDown else { return true }
        pendingModifier = nil   // a real key landed; whatever modifier is held belongs to it
        chordPeak = []
        chordFirst = nil

        let key = KeyShortcut(keyCode: event.keyCode, modifiers: event.modifierFlags,
                              label: KeyShortcut.label(for: event))
        switch role {
        case .dictate:
            guard key.isHoldable else {
                hint.stringValue = "A bare \(key.label) would type while held. Add a modifier, or use an F-key."
                return true
            }
            if key.modifiers.contains(Shortcuts.commandModifier) {
                hint.stringValue = "\(KeyShortcut.modifierName(Shortcuts.commandModifier)) is the command-mode modifier. Pick a combination without it."
                return true
            }
            if let why = taken(key) { hint.stringValue = why; return true }
            save(key)
            finish()
        case .handsFree:
            guard key.isHoldable else {
                hint.stringValue = "A bare \(key.label) would fire while you type. Add a modifier, or use an F-key."
                return true
            }
            if let why = taken(key) { hint.stringValue = why; return true }
            save(key)
            finish()
        case .commandModifier:
            hint.stringValue = "Modifiers only: control, option, shift or command."
        case .fixed:
            return false
        }
        return true
    }

    /// A modifier key on its own. Down: remembered. Up, with nothing pressed
    /// in between: that is the key. Two or more down together: a chord,
    /// taken when the first of them lets go.
    private func handleModifier(_ event: NSEvent) -> Bool {
        guard let flag = KeyShortcut.flag(forModifierKey: event.keyCode) else { return true }
        let down = event.modifierFlags.contains(flag)
        let held = event.modifierFlags.intersection(KeyShortcut.allModifierFlags)
        if down {
            pendingModifier = (event.keyCode, flag)
            if chordPeak.isEmpty { chordFirst = event.keyCode }
            chordPeak.formUnion(held)
            return true
        }
        let peak = chordPeak
        let first = chordFirst
        if held.isEmpty { chordPeak = []; chordFirst = nil }
        if peak.rawValue.nonzeroBitCount >= 2 {
            // A chord: the set that was down together, taken on its first release.
            chordPeak = []
            chordFirst = nil
            pendingModifier = nil
            guard let chord = KeyShortcut.chord(peak, first: first ?? event.keyCode) else { return true }
            return took(chord: chord)
        }
        guard let pending = pendingModifier, pending.code == event.keyCode else { return true }
        pendingModifier = nil
        switch role {
        case .dictate:
            if flag == Shortcuts.commandModifier {
                hint.stringValue = "That is the command-mode modifier. Pick another key."
                return true
            }
            let key = KeyShortcut(keyCode: event.keyCode, modifiers: [], label: KeyShortcut.modifierName(flag))
            if let why = taken(key) { hint.stringValue = why; return true }
            save(key)
            finish()
        case .commandModifier:
            if flag == .function {
                hint.stringValue = "Modifiers only: control, option, shift or command."
                return true
            }
            if Shortcuts.dictateKeys.contains(where: { $0.chordFlags.contains(flag) || $0.modifiers.contains(flag) }) {
                hint.stringValue = "That is part of a dictate key. Pick another modifier."
                return true
            }
            Shortcuts.setCommandModifier(flag)
            finish()
        case .handsFree:
            hint.stringValue = "A modifier alone would fire with every shortcut. Add a second one, or use an F-key."
        case .fixed:
            return false
        }
        return true
    }

    /// Two modifiers together. Command mode owns one such chord; a chord
    /// that contains a dictate key is fine for hands-free — it latches the
    /// dictation that key is already holding — but pointless for dictate,
    /// where the key on its own already fires first.
    private func took(chord: KeyShortcut) -> Bool {
        if Shortcuts.isCommandChord(chord) {
            hint.stringValue = "That is command mode. Change its modifier first, or pick another pair."
            return true
        }
        switch role {
        case .dictate:
            if chord.chordFlags.contains(Shortcuts.commandModifier) {
                hint.stringValue = "\(KeyShortcut.modifierName(Shortcuts.commandModifier)) is the command-mode modifier. Pick a pair without it."
                return true
            }
            if let solo = Shortcuts.dictateKeys.first(where: { !$0.isChord && $0.isModifierKey && chord.chordFlags.contains($0.modifierFlag!) }) {
                hint.stringValue = "\(solo.text) already dictates on its own, so the pair would never be reached."
                return true
            }
            if let why = taken(chord) { hint.stringValue = why; return true }
            save(chord)
            finish()
        case .handsFree:
            if let why = taken(chord) { hint.stringValue = why; return true }
            save(chord)
            finish()
        case .commandModifier:
            hint.stringValue = "One modifier, not two: control, option, shift or command."
        case .fixed:
            return false
        }
        return true
    }

    /// At rest the caps stand on the row with nothing around them; while
    /// listening they sit in the focus ring — ember, the one colour for
    /// something live.
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        cap.layer?.backgroundColor = (isListening ? Theme.surface : .clear).cgColor
        cap.layer?.borderColor = (isListening ? Theme.ember : .clear).cgColor
        halo.borderColor = Theme.emberSoft.cgColor
        halo.isHidden = !isListening
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// One part of a key as a Mac keycap, the way the keyboard prints it: the
/// modifier's glyph in the top corner and its word along the bottom (⌃ over
/// "control"), the globe under "fn", "esc" on its own. A letter or an F-key
/// is one label in the middle. Taller than a chip, with a lit top edge and
/// a lip, so the row reads as keys you press rather than tags.
///
/// `small` is How it works' cap, inside a demo; `setDown` presses it there.
final class KeyChip: NSView {
    private static let glyphs = ["control": "⌃", "option": "⌥", "shift": "⇧", "command": "⌘", "return": "↩"]
    private let face = CAGradientLayer()
    /// The ember ring a pressed key wears.
    private let halo = CALayer()
    private let radius: CGFloat
    /// Every label on the cap, and the colour it rests in.
    private var labels: [(field: NSTextField, ink: NSColor)] = []
    private var globe: GlyphView?
    private(set) var isDown = false

    init(_ part: KeyPart, small: Bool = false) {
        // Mockup pixels through Theme.m: the Settings cap, or the demo's.
        let height: CGFloat = small ? 28 : 38, pad = Theme.m(small ? 5 : 6)
        let wordSize: CGFloat = small ? 8.5 : 10, glyphSize: CGFloat = small ? 9.5 : 11
        radius = Theme.m(small ? 6.5 : 7)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.borderWidth = 1
        layer?.masksToBounds = false
        halo.opacity = 0
        layer?.addSublayer(halo)
        face.cornerRadius = radius
        layer?.addSublayer(face)

        let glyph = Self.glyphs[part.name]
        let wide = glyph != nil
        var pins: [NSLayoutConstraint] = [heightAnchor.constraint(equalToConstant: Theme.m(height))]
        // A cap is exactly as wide as its widest label needs, never less
        // than a key: with no width of its own, a row's stack stretched it.
        var widest: CGFloat = 0
        func put(_ v: NSView) {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
            widest = max(widest, v.fittingSize.width)
        }
        func word(_ s: String) -> NSTextField {
            let f = Theme.text(s, wordSize, .medium, Theme.ink2)
            f.font = .systemFont(ofSize: Theme.m(wordSize), weight: .medium)
            labels.append((f, Theme.ink2))
            return f
        }
        if part.name == "fn" {
            // fn: the word up in the corner, the globe down at the start.
            let top = word("fn")
            let g = GlyphView(symbol: "globe", size: Theme.m(small ? 9 : 10.5), weight: .regular, side: Theme.m(small ? 10.5 : 12))
            g.tint = Theme.ink2
            globe = g
            put(top); put(g)
            pins += [top.topAnchor.constraint(equalTo: topAnchor, constant: pad - 1),
                     top.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
                     g.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
                     g.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad + 1)]
        } else if let glyph = glyph {
            let top = Theme.text(glyph, glyphSize, .regular, Theme.muted)
            top.font = .systemFont(ofSize: Theme.m(glyphSize))
            labels.append((top, Theme.muted))
            let bottom = word(part.name)
            put(top); put(bottom)
            pins += [top.topAnchor.constraint(equalTo: topAnchor, constant: pad - 2),
                     top.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
                     bottom.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
                     bottom.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -pad),
                     bottom.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad + 1)]
        } else if part.name.count <= 3 && part.name != "esc" {
            // A letter, a digit, F5: one label in the middle of the cap.
            let size: CGFloat = small ? 11 : 12.5
            let mid = Theme.text(part.name.count == 1 ? part.name.uppercased() : part.name, size, .medium, Theme.ink2)
            mid.font = .systemFont(ofSize: Theme.m(size), weight: .medium)
            labels.append((mid, Theme.ink2))
            put(mid)
            pins += [mid.centerXAnchor.constraint(equalTo: centerXAnchor),
                     mid.centerYAnchor.constraint(equalTo: centerYAnchor),
                     mid.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: pad)]
        } else {
            // esc, space, tab: the word along the bottom.
            let bottom = word(part.name)
            put(bottom)
            pins += [bottom.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
                     bottom.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -pad),
                     bottom.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad + 1)]
        }
        let least: CGFloat = small ? (wide ? 46 : 31) : (wide ? 58 : 42)
        pins.append(widthAnchor.constraint(equalToConstant: max(Theme.m(least), ceil(widest) + 2 * pad)))
        NSLayoutConstraint.activate(pins)
        toolTip = part.name
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Pressed, the way a demo presses it: two points of travel, the lip
    /// gone under it, an ember ring and ember words — then back up.
    func setDown(_ down: Bool, animated: Bool) {
        guard down != isDown else { return }
        isDown = down
        for l in labels { l.field.textColor = down ? Theme.emberInk : l.ink }
        globe?.tint = down ? Theme.emberInk : Theme.ink2
        Anim.hold(self, down ? Anim.lift(2, self) : nil, animated ? 0.12 : 0)
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.12 : 0)
        CATransaction.setDisableActions(!animated)
        halo.opacity = down ? 1 : 0
        CATransaction.commit()
        needsDisplay = true
    }

    /// A white top fading to the key colour, light; a lifted graphite,
    /// dark. The lip is two points here, a key's worth of travel.
    static let top  = Theme.dyn(Theme.hex(0xFFFFFF), Theme.hex(0x3A3A40))
    static let edge = Theme.dyn(Theme.hex(0x000000, 0.10), Theme.hex(0x000000, 0.55))

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        face.frame = bounds
        let ring = Theme.m(4)
        halo.frame = bounds.insetBy(dx: -ring, dy: -ring)
        halo.cornerRadius = radius + ring
        halo.borderWidth = ring
        CATransaction.commit()
    }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        face.colors = [Self.top.cgColor, Theme.keyFill.cgColor]
        halo.borderColor = Theme.emberSoft.cgColor
        layer?.borderColor = Self.edge.cgColor
        layer?.shadowColor = Theme.lipColor.cgColor
        layer?.shadowOpacity = isDown ? 0 : 1
        layer?.shadowRadius = 0
        layer?.shadowOffset = CGSize(width: 0, height: -2)
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}
