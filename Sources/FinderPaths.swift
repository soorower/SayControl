// Reads the Finder selection so "copy the file path" knows what you mean.
//
// Asks Finder over Apple Events — the only supported way to see its
// selection — through /usr/bin/osascript, the same shell-out style the
// screenshot command uses with /usr/sbin/screencapture. Works even when
// Finder is in the background: whatever was last selected is still the
// selection. First use shows the one-time "SayCtrl wants to control Finder"
// consent (NSAppleEventsUsageDescription in Info.plist).
import Foundation

enum FinderPaths {

    enum Issue: Error {
        case nothingSelected   // Finder answered, but has no selection and no window
        case notAuthorized     // the Automation grant is missing or denied (-1743)
        case failed(String)    // anything else — Finder not running, timeout…
    }

    /// Every selected item's POSIX path, one per line. With no selection,
    /// the folder the front window is showing — but only when a window is
    /// actually open, so a bare "copy the path" with Finder closed doesn't
    /// silently hand out ~/Desktop.
    private static let script = """
    tell application "Finder"
        set out to {}
        repeat with f in (get selection)
            try
                set end of out to POSIX path of (f as alias)
            end try
        end repeat
        if out is {} and (count of Finder windows) > 0 then
            try
                set end of out to POSIX path of (insertion location as alias)
            end try
        end if
    end tell
    set AppleScript's text item delimiters to linefeed
    return out as text
    """

    /// Sample the selection now, off the main thread; completion lands back
    /// on main. Success is always non-empty. Folder paths lose their
    /// trailing slash so they paste terminal-ready.
    static func sample(_ completion: @escaping (Result<[String], Issue>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            func finish(_ r: Result<[String], Issue>) { DispatchQueue.main.async { completion(r) } }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            let outPipe = Pipe(), errPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = errPipe
            do { try p.run() } catch {
                return finish(.failure(.failed(error.localizedDescription)))
            }
            // The first call can sit on the system's consent dialog for a
            // while — give the user time, but never hang a paste forever.
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: killer)
            let out = outPipe.fileHandleForReading.readDataToEndOfFile()
            let err = errPipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            killer.cancel()
            guard p.terminationStatus == 0 else {
                let msg = (String(data: err, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if msg.contains("-1743") || msg.localizedCaseInsensitiveContains("not authorized") {
                    return finish(.failure(.notAuthorized))
                }
                return finish(.failure(.failed(msg.isEmpty ? "Finder didn't answer" : msg)))
            }
            let paths = (String(data: out, encoding: .utf8) ?? "")
                .split(separator: "\n")
                .map { line -> String in
                    var s = String(line)
                    while s.count > 1, s.hasSuffix("/") { s.removeLast() }
                    return s
                }
                .filter { !$0.isEmpty }
            guard !paths.isEmpty else { return finish(.failure(.nothingSelected)) }
            finish(.success(paths))
        }
    }
}
