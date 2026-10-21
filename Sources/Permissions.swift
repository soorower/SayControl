// What macOS has let SayCtrl do, asked without side effects — and the one way
// each grant is requested: through Apple's own prompt, or by opening the pane
// where the switch lives. Nothing here writes to the privacy database.
import Cocoa
import AVFoundation
import IOKit.hid

enum Permissions {
    enum State { case granted, denied, unknown }

    // MARK: Microphone

    static var microphone: State {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:    return .granted
        case .notDetermined: return .unknown
        default:             return .denied
        }
    }

    /// First time: the system prompt. Once refused, the prompt never shows
    /// again and the only way back is the switch in System Settings.
    static func requestMicrophone(_ done: @escaping () -> Void) {
        if microphone == .unknown {
            AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async(execute: done) }
        } else {
            open("Privacy_Microphone")
            done()
        }
    }

    // MARK: Accessibility

    static var accessibility: State { AXIsProcessTrusted() ? .granted : .unknown }

    /// Apple's "would like to control this computer" dialog, which also lists
    /// the app in the Accessibility pane so the switch is there to flip.
    static func promptAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: Input Monitoring

    static var inputMonitoring: State {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied:  return .denied
        default:                      return .unknown
        }
    }

    // MARK: Screen Recording

    static var screenRecording: State { CGPreflightScreenCaptureAccess() ? .granted : .unknown }

    // MARK: The lists in System Settings

    /// The grants that are a switch in a System Settings list rather than a
    /// dialog of their own, so setting one up means a trip over there.
    enum Listed: String {
        case accessibility = "Accessibility"
        case inputMonitoring = "Input Monitoring"
        case screenRecording = "Screen Recording"

        var anchor: String {
            switch self {
            case .accessibility:   return "Privacy_Accessibility"
            case .inputMonitoring: return "Privacy_ListenEvent"
            case .screenRecording: return "Privacy_ScreenCapture"
            }
        }
        var granted: Bool {
            switch self {
            case .accessibility:   return Permissions.accessibility == .granted
            case .inputMonitoring: return Permissions.inputMonitoring == .granted
            case .screenRecording: return Permissions.screenRecording == .granted
            }
        }
    }

    /// Asked through Apple's own request this launch. macOS shows each of
    /// those dialogs once at most, so a click that only asked again did
    /// nothing the user could see.
    private static var asked: Set<Listed> = []

    /// Set Up, on every click: Apple's request the first time (it also puts
    /// SayControl in the list), then the pane, with the tray under it until
    /// the switch is on. `granted` runs when it lands. `preview` shows the
    /// tray without asking macOS for anything (`--guide-preview`).
    static func guide(_ grant: Listed, preview: Bool = false, granted: (() -> Void)? = nil) {
        if preview {
            open(grant.anchor)
            return DragToListPanel.shared.show(for: grant, preview: true)
        }
        if !asked.contains(grant) {
            asked.insert(grant)
            switch grant {
            case .accessibility:
                promptAccessibility()
            case .inputMonitoring:
                if inputMonitoring == .unknown, IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) {
                    granted?()
                    return
                }
            case .screenRecording:
                _ = CGRequestScreenCaptureAccess()
            }
        }
        open(grant.anchor)
        DragToListPanel.shared.show(for: grant, granted: granted)
    }

    // MARK: The globe key

    /// System Settings › Keyboard › "Press 🌐 key to". 0 is Do Nothing, which is
    /// the one setting under which a tap of fn does not open the emoji picker
    /// or start Apple's own dictation. nil: never set, so macOS's default
    /// applies — and the default is not Do Nothing.
    static var globeKeyAction: Int? {
        let v = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString)
        return (v as? NSNumber)?.intValue
    }
    static var globeKeyIsQuiet: Bool { globeKeyAction == 0 }

    static func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.keyboard")!)
    }

    // MARK: Panes

    /// One of the Privacy & Security anchors: Privacy_Accessibility,
    /// Privacy_Microphone, Privacy_ListenEvent, Privacy_ScreenCapture…
    static func open(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
}
