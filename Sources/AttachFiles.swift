// Finds the file "attach the image from downloads" means: kind filter,
// folder scope, newest first — leaning on the Finder selection when no
// folder was named, the same mental model as "copy the file path". The
// .folder kind hunts directories instead: "upload the Redfin folder from
// the ideas folder" attaches the Redfin directory itself. Which folder a
// spoken name means is FolderSearch's question, asked here and by "open
// terminal in …". The first read of Downloads/Desktop/Documents shows
// macOS's one-time folder-access consent.
import AppKit

enum AttachFiles {

    enum Outcome {
        case one(URL)       // exactly what you meant — paste it
        case many([URL])    // newest first, capped at 5 — show the picker
        case issue(String)  // HUD text saying why nothing attached
    }

    /// Resolution is async when it asks Finder or hunts a folder by name
    /// through Spotlight. Completion lands on main.
    static func resolve(_ cmd: AttachCommand, completion: @escaping (Outcome) -> Void) {
        if let word = cmd.folder {
            return FolderSearch.find(word, within: cmd.parent) { dir in
                guard let dir = dir else {
                    return completion(.issue("🤷 No “\(word)” folder found"))
                }
                completion(pick(in: dir, cmd))
            }
        }
        if cmd.kind == .screenshot {
            // Screenshots have a home of their own — wherever macOS saves
            // them — so no folder word is needed.
            return completion(pick(in: screenshotFolder(), cmd))
        }
        FinderPaths.sample { result in
            switch result {
            case .success(let paths):
                let urls = paths.map { URL(fileURLWithPath: $0) }
                if cmd.kind == .folder {
                    // "upload the redfin folder" with no "from": the
                    // selected folder(s) — or the front window's folder
                    // when nothing is selected — ARE the candidates; a
                    // named folder Finder isn't showing is hunted instead.
                    let dirs = urls.filter { FolderSearch.isDirectory($0) }
                    let frag = (cmd.fragment ?? "").lowercased()
                    if dirs.contains(where: { frag.isEmpty || $0.lastPathComponent.lowercased().contains(frag) }) {
                        return completion(fromCandidates(sortNewest(dirs), cmd, where: "in the selection"))
                    }
                    return huntFolder(cmd, completion: completion)
                }
                let files = urls.filter { !FolderSearch.isDirectory($0) }
                let matching = files.filter { matches($0, cmd.kind) }
                if !matching.isEmpty {
                    completion(fromCandidates(sortNewest(matching), cmd, where: "in the selection"))
                } else if urls.count == 1, FolderSearch.isDirectory(urls[0]) {
                    completion(pick(in: urls[0], cmd))
                } else {
                    completion(.issue("🤷 No \(cmd.kind.noun) in the Finder selection — try “…from downloads”"))
                }
            case .failure:
                if cmd.kind == .folder {
                    return huntFolder(cmd, completion: completion)
                }
                completion(.issue("🤷 Say which folder — “attach the \(cmd.kind.noun) from downloads”"))
            }
        }
    }

    /// "upload the Redfin folder" with nothing helpful on screen: the
    /// spoken name IS the search — the same known-names-then-Spotlight
    /// hunt a "from" clause gets. Several folders wearing the name go to
    /// the picker, same as several files would.
    private static func huntFolder(_ cmd: AttachCommand, completion: @escaping (Outcome) -> Void) {
        guard let frag = cmd.fragment, !frag.isEmpty else {
            return completion(.issue("🤷 Say which — “upload the ideas folder” or “…the folder from desktop”"))
        }
        FolderSearch.findAll(frag, within: cmd.parent) { dirs in
            guard !dirs.isEmpty else {
                return completion(.issue("🤷 No “\(frag)” folder found"))
            }
            if let n = cmd.ordinal {
                let index = n == -1 ? dirs.count - 1 : n - 1
                guard index >= 0, index < dirs.count else {
                    return completion(.issue("🤷 Only \(dirs.count) “\(frag)” folder\(dirs.count == 1 ? "" : "s") found"))
                }
                return completion(.one(dirs[index]))
            }
            completion(dirs.count == 1 ? .one(dirs[0]) : .many(Array(dirs.prefix(5))))
        }
    }

    // MARK: - The search itself

    private static func pick(in dir: URL, _ cmd: AttachCommand) -> Outcome {
        // contentsOfDirectory refuses a symlink URL outright ("Not a
        // directory") — resolve it, or a linked folder lists as empty.
        let dir = dir.resolvingSymlinksInPath()
        let listing = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles])) ?? []
        var files = cmd.kind == .folder
            ? listing.filter { FolderSearch.isDirectory($0) }
            : listing.filter { !FolderSearch.isDirectory($0) && matches($0, cmd.kind) }
        if cmd.kind == .screenshot {
            // Prefer real screenshot names; fall back to any image so a
            // renamed shot still counts.
            let named = files.filter { screenshotName($0.lastPathComponent) }
            if !named.isEmpty { files = named }
        }
        return fromCandidates(sortNewest(files), cmd, where: "in \(dir.lastPathComponent)")
    }

    private static func fromCandidates(_ all: [URL], _ cmd: AttachCommand, where place: String) -> Outcome {
        var sorted = all
        // "the payout PDF" — names containing the fragment win; when none
        // do, the fragment was probably misheard, so show everything.
        if let frag = cmd.fragment?.lowercased(), !frag.isEmpty {
            let narrowed = sorted.filter { $0.lastPathComponent.lowercased().contains(frag) }
            if !narrowed.isEmpty { sorted = narrowed }
        }
        guard !sorted.isEmpty else { return .issue("🤷 No \(cmd.kind.noun) \(place)") }
        if let n = cmd.ordinal {
            let index = n == -1 ? sorted.count - 1 : n - 1
            guard index >= 0, index < sorted.count else {
                return .issue("🤷 Only \(sorted.count) \(cmd.kind.noun)\(sorted.count == 1 ? "" : "s") \(place)")
            }
            return .one(sorted[index])
        }
        return sorted.count == 1 ? .one(sorted[0]) : .many(Array(sorted.prefix(5)))
    }

    // MARK: - Small helpers

    private static func matches(_ url: URL, _ kind: AttachKind) -> Bool {
        kind == .any || kind.extensions.contains(url.pathExtension.lowercased())
    }

    private static func screenshotName(_ name: String) -> Bool {
        let low = name.lowercased()
        return low.hasPrefix("screenshot") || low.hasPrefix("screen shot")
            || low.hasPrefix("cleanshot") || low.hasPrefix("sayctrl-shot")
    }

    private static func sortNewest(_ urls: [URL]) -> [URL] {
        urls.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a > b
        }
    }

    /// Where ⇧⌘3 actually saves — configurable, so read the setting.
    private static func screenshotFolder() -> URL {
        if let loc = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let expanded = (loc as NSString).expandingTildeInPath
            if FolderSearch.isDirectory(URL(fileURLWithPath: expanded)) {
                return URL(fileURLWithPath: expanded)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }
}
