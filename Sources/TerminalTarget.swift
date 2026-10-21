// Resolves "open terminal in the downloads folder": which terminal, and
// which folder it should already be standing in.
//
// The terminal is a short list of the ones people say by name, matched by
// bundle id — a name SayCtrl can't find on this Mac is not a command, so the
// words stay ordinary text, the same rule OpenTarget follows. The plain word
// "terminal" means Terminal.app: literal, and on every Mac.
//
// The folder is FolderSearch's answer, unchanged — the same hunt "attach the
// PDF from downloads" gets, so the two commands agree about what "the stocks
// folder" means. A name that finds nothing is NOT a dead end: the terminal
// still opens, just wherever it would have opened anyway.
import AppKit

enum TerminalTarget {

    /// A terminal that is actually installed here.
    struct App: Equatable {
        let url: URL
        let name: String   // for the HUD — the app's own name on disk
    }

    /// Where the terminal should open, once the spoken folder has been chased.
    enum Spot {
        case folder(URL)      // exactly one — open there
        case choose([URL])    // several wear the name — let the user pick
        case unmatched(String)   // the name matched nothing
        case noFinder         // "here", but Finder isn't showing a folder
    }

    /// Spoken name → the bundle ids that app has shipped under. Order is the
    /// preference used when the generic word "terminal" has to fall back.
    private static let known: [(spoken: String, ids: [String])] = [
        ("terminal",  ["com.apple.Terminal"]),
        ("iterm",     ["com.googlecode.iterm2"]),
        ("iterm2",    ["com.googlecode.iterm2"]),
        ("ghostty",   ["com.mitchellh.ghostty"]),
        ("warp",      ["dev.warp.Warp-Stable", "dev.warp.Warp"]),
        ("wezterm",   ["com.github.wez.wezterm"]),
        ("kitty",     ["net.kovidgoyal.kitty"]),
        ("alacritty", ["org.alacritty", "io.alacritty"]),
        ("hyper",     ["co.zeit.hyper"]),
        ("tabby",     ["org.tabby"]),
    ]

    /// The terminal a command names, or nil when this Mac hasn't got it —
    /// in which case the words were never a command. `spoken` is nil for the
    /// generic "terminal"/"console"/"shell", which means Terminal.app.
    static func app(named spoken: String?) -> App? {
        guard let spoken = spoken else {
            // Terminal.app ships with macOS, so this is all but certain;
            // the fallback is for the Mac where it has been removed.
            return bundle(["com.apple.Terminal"]) ?? known.lazy.compactMap { bundle($0.ids) }.first
        }
        guard let entry = known.first(where: { $0.spoken == spoken }) else { return nil }
        return bundle(entry.ids)
    }

    private static func bundle(_ ids: [String]) -> App? {
        for id in ids {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return App(url: url, name: url.deletingPathExtension().lastPathComponent)
            }
        }
        return nil
    }

    /// The folder the command means. Async — it may ask Finder or hunt the
    /// name through Spotlight. Completion lands on main.
    static func resolve(_ cmd: TerminalCommand, completion: @escaping (Spot) -> Void) {
        guard let name = cmd.folder else {
            // "here": whatever Finder is showing — the selected folder, the
            // folder holding the selected file, or the front window's folder.
            // The same reading "copy the file path" gives an empty selection.
            return FinderPaths.sample { result in
                switch result {
                case .success(let paths):
                    let url = URL(fileURLWithPath: paths[0])
                    completion(.folder(FolderSearch.isDirectory(url)
                                       ? url : url.deletingLastPathComponent()))
                case .failure:
                    completion(.noFinder)
                }
            }
        }
        FolderSearch.findAll(name, within: cmd.parent) { hits in
            // A hit that has since been moved or deleted would open the
            // terminal nowhere — drop it before it reaches a picker.
            let dirs = hits.filter { FolderSearch.isDirectory($0) }
            guard !dirs.isEmpty else { return completion(.unmatched(name)) }
            // Five is what the picker strip can show.
            completion(dirs.count == 1 ? .folder(dirs[0]) : .choose(Array(dirs.prefix(5))))
        }
    }

    /// Launch it. With a folder, that's the same event Finder's "New Terminal
    /// at Folder" sends — a new window already standing there. Terminals that
    /// don't accept a folder report an error, and the caller opens them plain.
    /// `ok` says whether the folder took; completion lands on main.
    static func open(_ app: App, at dir: URL?, completion: @escaping (_ ok: Bool) -> Void = { _ in }) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        func done(_ ok: Bool) { DispatchQueue.main.async { completion(ok) } }
        guard let dir = dir else {
            return NSWorkspace.shared.openApplication(at: app.url, configuration: config) { _, err in
                done(err == nil)
            }
        }
        NSWorkspace.shared.open([dir], withApplicationAt: app.url, configuration: config) { _, err in
            done(err == nil)
        }
    }
}
