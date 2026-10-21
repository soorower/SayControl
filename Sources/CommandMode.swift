// Command mode: hold fn+control and SPEAK AN INSTRUCTION instead of text —
// "make it shorter", "fix the grammar", "turn this into a polite email".
//
// What the instruction acts on is decided the moment recording starts, from
// the field under the caret (the user's design, 2026-08-20):
//   • text selected            → rewrite just the selection (⌘V replaces it)
//   • no selection, field full → rewrite the whole box (⌘A then ⌘V)
//   • field empty / unreadable → write fresh from the instruction and paste
// Capturing at press, not at paste, means the text the user was looking at
// is the text that gets edited, whatever the recognizer does meanwhile.
//
// Reading the field rides the same Accessibility plumbing auto-learn uses
// (CorrectionWatcher); replacing goes through the normal paste pipeline, so
// one ⌘Z in the target app undoes the whole edit.
import Cocoa
import ApplicationServices

struct CommandTarget {
    enum Mode {
        case replaceSelection   // paste over the live selection
        case replaceAll         // select the whole field first, then paste
        case insert             // nothing to edit — paste fresh at the caret
    }
    let mode: Mode
    let text: String

    var label: String {
        switch mode {
        case .replaceSelection: return "the selection"
        case .replaceAll:       return "the text box"
        case .insert:           return "fresh text"
        }
    }
}

enum CommandMode {
    /// Longer than this and a whole-field rewrite is more risk than help —
    /// the user should select the part they mean.
    static let maxChars = 12_000

    /// True while the CURRENT recording is a command-mode instruction — set
    /// per dictation in startRecording, read by the recognizer's hint list.
    static var armed = false

    /// What people actually say in command mode, offered to the recognizer as
    /// keyterms while armed. Mishearing the instruction is this feature's
    /// whole failure mode ("polish the prompt" → "what is the prompt"), and
    /// being heard right is the only fix that happens before the LLM.
    /// Every phrase ≤ 20 chars — ElevenLabs hard-rejects longer keyterms.
    static let spokenPhrases = [
        "polish it", "polish the prompt", "make it shorter", "make it longer",
        "fix the grammar", "fix the spelling", "fix typos",
        "make it an email", "make it a list", "bullet points", "numbered list",
        "make it formal", "make it casual", "make it polite",
        "summarize it", "rewrite it", "simplify it", "translate to English",
    ]

    static func captureTarget() -> CommandTarget {
        let roots = CorrectionWatcher.candidateRoots()
        // A live selection wins: it is the most explicit "this text" there is.
        for root in roots {
            if let sel = string(of: root, kAXSelectedTextAttribute), !sel.isEmpty {
                return CommandTarget(mode: .replaceSelection, text: sel)
            }
        }
        // No selection: the whole field, but only one that really is an
        // editable text element — ⌘A anywhere else selects who knows what.
        for root in roots {
            guard let value = string(of: root, kAXValueAttribute),
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            var settable = DarwinBoolean(false)
            AXUIElementIsAttributeSettable(root, kAXValueAttribute as CFString, &settable)
            let role = string(of: root, kAXRoleAttribute) ?? ""
            guard settable.boolValue || role.contains("Text") else { continue }
            return CommandTarget(mode: .replaceAll, text: value)
        }
        return CommandTarget(mode: .insert, text: "")
    }

    private static func string(of element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let s = value as? String else { return nil }
        return s
    }
}
