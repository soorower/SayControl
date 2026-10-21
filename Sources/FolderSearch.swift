// Finds the folder a spoken name means: "downloads", "the ideas folder",
// "the stocks folder in desktop".
//
// The folders everyone names are answered from a table, instantly. Anything
// else is hunted — Spotlight AND a breadth-first walk, because neither alone
// is enough (a freshly made ~/Desktop/Stocks came back empty from mdfind
// while ~/stocks-trading matched). The union is ranked, exact names first and
// shallow before deep, so the best guess leads and the rest are there for a
// picker to offer.
//
// "attach the PDF from downloads" and "open terminal in the stocks folder"
// are the same question, so they ask it in the same place.
// Foundation only — no AppKit — so the hunt can be exercised on its own.
import Foundation

enum FolderSearch {

    /// The single best folder wearing the name, or nil. Completion on main.
    static func find(_ word: String, within parent: String? = nil,
                     completion: @escaping (URL?) -> Void) {
        findAll(word, within: parent) { completion($0.first) }
    }

    /// Every folder wearing the name, best first: exact names beat
    /// contains-matches, shallow beats deep. "…in desktop" scopes the hunt
    /// to that parent (a direct walk — Spotlight can't be trusted to have
    /// indexed a freshly made folder); with no parent it's the known names,
    /// then Spotlight over home, then a shallow walk of Desktop/Documents/
    /// Downloads/home as the net under Spotlight's gaps. Completion on main.
    static func findAll(_ word: String, within parent: String? = nil,
                        completion: @escaping ([URL]) -> Void) {
        if let parent = parent {
            return find(parent) { parentDir in
                guard let parentDir = parentDir else {
                    // The parent name failed — hunt the folder itself
                    // everywhere rather than shrugging.
                    return findAll(word, completion: completion)
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    let hits = scanForFolders(named: word, under: [parentDir], maxDepth: 4)
                    DispatchQueue.main.async {
                        // Ranked here too, or a deep near-miss found first by
                        // the walk would beat the folder actually wearing the
                        // name ("…the projects folder in desktop" → Projects-Web).
                        hits.isEmpty ? findAll(word, completion: completion)
                                     : completion(rank(hits, target: word))
                    }
                }
            }
        }
        if let known = namedFolder(word) { return completion([known]) }
        DispatchQueue.global(qos: .userInitiated).async {
            func finish(_ urls: [URL]) { DispatchQueue.main.async { completion(urls) } }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            let safe = word.replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "*", with: "")
            // Spoken names arrive with spaces where the folder wears a
            // separator, so ask for each spelling — Spotlight matches the
            // literal string and would miss CODE_FILES for "code files".
            let spellings = Set([safe,
                                 safe.replacingOccurrences(of: " ", with: "_"),
                                 safe.replacingOccurrences(of: " ", with: "-"),
                                 safe.replacingOccurrences(of: " ", with: "")])
            let names = spellings.map { "kMDItemFSName == \"*\($0)*\"c" }.joined(separator: " || ")
            p.arguments = ["-onlyin", NSHomeDirectory(),
                           "kMDItemContentType == \"public.folder\" && (\(names))"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            var hits: [String] = []
            do {
                try p.run()
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: killer)
                let out = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                hits = (String(data: out, encoding: .utf8) ?? "")
                    .split(separator: "\n").map(String.init)
                    .filter { !$0.contains("/Library/") && !$0.contains("/node_modules/") && !$0.contains("/.") }
            } catch { /* fall through to the walk */ }
            // Spotlight alone misses real folders, so the walk ALWAYS runs
            // and the union gets ranked — exact names first.
            let home = FileManager.default.homeDirectoryForCurrentUser
            let walked = scanForFolders(named: word,
                                        under: [home.appendingPathComponent("Desktop"),
                                                home.appendingPathComponent("Documents"),
                                                home.appendingPathComponent("Downloads"),
                                                home],
                                        maxDepth: 3)
            finish(rank(hits.map { URL(fileURLWithPath: $0) } + walked, target: word))
        }
    }

    /// Exact-name matches first, then shallow before deep; a symlink and
    /// its target are the same folder, so the loser of the sort is dropped;
    /// capped so a promiscuous name can't flood the picker.
    static func rank(_ urls: [URL], target: String) -> [URL] {
        let t = squash(target)
        var seen = Set<String>()
        return urls
            .filter { !isPackage($0) }   // SayCtrl.app is not "the sayctrl folder"
            .sorted {
                let ae = squash($0.lastPathComponent) == t
                let be = squash($1.lastPathComponent) == t
                if ae != be { return ae }
                return $0.pathComponents.count < $1.pathComponents.count
            }
            .map { $0.resolvingSymlinksInPath() }   // hand back the real folder
            .filter { seen.insert($0.path).inserted }
            .prefix(8).map { $0 }
    }

    /// Breadth-first walk — shallowest hits surface first, no Spotlight
    /// needed. Blocking; call it off-main.
    static func scanForFolders(named word: String, under roots: [URL], maxDepth: Int) -> [URL] {
        let target = squash(word)
        let skip: Set<String> = ["library", "applications", "node_modules"]
        var queue = roots.map { ($0, 0) }
        var found: [URL] = []
        var visited = 0
        while !queue.isEmpty, found.count < 8, visited < 600 {
            let (dir, depth) = queue.removeFirst()
            visited += 1
            let kids = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
            for kid in kids where isDirectory(kid) {
                let name = kid.lastPathComponent.lowercased()
                if !isPackage(kid), squash(name).contains(target) { found.append(kid) }
                if depth + 1 < maxDepth, !skip.contains(name), !isPackage(kid) {
                    queue.append((kid.resolvingSymlinksInPath(), depth + 1))
                }
            }
        }
        return found
    }

    /// Spoken names lose the separator the folder actually wears: "code
    /// files" has to find CODE_FILES, code-files and CodeFiles alike. Both
    /// sides squashed, one rule covers all of them.
    static func squash(_ s: String) -> String {
        s.lowercased().filter { !" _-.".contains($0) }
    }

    /// A bundle is a folder only to the filesystem. SayCtrl.app matched
    /// "the sayctrl folder" and offered to open a terminal inside itself.
    private static let packageExtensions: Set<String> = [
        "app", "bundle", "framework", "kext", "plugin", "prefpane", "qlgenerator",
        "xcodeproj", "xcworkspace", "playground", "photoslibrary", "tvlibrary",
        "aplibrary", "musiclibrary", "rtfd", "download", "pkg", "mpkg", "dsym",
    ]

    /// Every entry above is lowercase because this lowercases its input.
    static func isPackage(_ url: URL) -> Bool {
        packageExtensions.contains(url.pathExtension.lowercased())
    }

    /// fileExists follows symlinks — a linked folder ("Stocks" on the
    /// desktop pointing at ~/stocks-trading) counts as a folder.
    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// The handful everyone says out loud, answered without a search.
    static func namedFolder(_ word: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch word {
        case "downloads", "download":  return home.appendingPathComponent("Downloads")
        case "desktop":                return home.appendingPathComponent("Desktop")
        case "documents", "document":  return home.appendingPathComponent("Documents")
        case "pictures", "photos":     return home.appendingPathComponent("Pictures")
        case "music":                  return home.appendingPathComponent("Music")
        case "movies", "videos":       return home.appendingPathComponent("Movies")
        case "home", "home folder", "my home", "user folder":
                                       return home
        case "applications", "apps":   return URL(fileURLWithPath: "/Applications")
        default:                       return nil
        }
    }
}
