// How often each spoken control has been used — the Insights card that
// counts screenshots, links, opened apps and the rest.
//
// A tally per control and the day counting began, in controls.json next to
// the history. Nothing else: no transcript, no file name, no address. The
// count goes up where the control actually fires (main.swift), so a phrase
// that was heard but did nothing isn't counted.
import Foundation

enum SpokenControl: String, CaseIterable, Codable {
    case screenshot, link, filePath, attach, open, terminal, ask, send, scratch, shell, commandMode

    /// What the Insights tile calls it, as a count of things done.
    var title: String {
        switch self {
        case .screenshot:  return "Screenshots"
        case .link:        return "Links copied"
        case .filePath:    return "File paths"
        case .attach:      return "Files attached"
        case .open:        return "Apps and sites opened"
        case .terminal:    return "Terminals opened"
        case .ask:         return "Asked an AI"
        case .send:        return "Sent"
        case .scratch:     return "Scratched"
        case .shell:       return "Terminal commands"
        case .commandMode: return "Command mode"
        }
    }

    /// What you say for it — the tile's tooltip, so a zero says how to start.
    var example: String {
        switch self {
        case .screenshot:  return "“take a screenshot”"
        case .link:        return "“copy the link”"
        case .filePath:    return "“copy the file path”"
        case .attach:      return "“attach the payout PDF from downloads”"
        case .open:        return "“open Claude”"
        case .terminal:    return "“open terminal in the projects folder”"
        case .ask:         return "“ask Claude how to fix this”"
        case .send:        return "“send it”"
        case .scratch:     return "“scratch that”"
        case .shell:       return "“list the files”, in a terminal"
        case .commandMode:
            return "Hold \(Shortcuts.command.map { $0.name }.joined(separator: " + ")) and say “make it shorter”"
        }
    }

    var symbol: String {
        switch self {
        case .screenshot:  return "camera.viewfinder"
        case .link:        return "link"
        case .filePath:    return "doc.text"
        case .attach:      return "paperclip"
        case .open:        return "arrow.up.forward.app"
        case .terminal:    return "terminal"
        case .ask:         return "sparkles"
        case .send:        return "return"
        case .scratch:     return "delete.left"
        case .shell:       return "chevron.left.forwardslash.chevron.right"
        case .commandMode: return "command"
        }
    }
}

final class ControlStats {
    static let shared = ControlStats()
    static let changed = Notification.Name("sayctrl.controlStatsChanged")

    private struct File: Codable {
        var counts: [String: Int] = [:]
        var since = Date()
    }
    private var file = File()
    private var url: URL { Config.shared.dataDir.appendingPathComponent("controls.json") }
    private let io = DispatchQueue(label: "sayctrl.controls", qos: .utility)

    private init() { load() }

    private func load() {
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(File.self, from: data) {
            file = saved
        }
    }

    /// Another account's folder.
    func reload() {
        file = File()
        load()
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// The day the first count was kept — the card says "since" it.
    var since: Date { file.since }
    func count(_ control: SpokenControl) -> Int { file.counts[control.rawValue] ?? 0 }
    var total: Int { file.counts.values.reduce(0, +) }

    /// One use, or `n` of them (three screenshots in one take). Main queue.
    /// History off means nothing is kept, and that covers this too.
    func note(_ control: SpokenControl, _ n: Int = 1) {
        guard n > 0, Config.shared.flag("KEEP_HISTORY", default: true) else { return }
        if file.counts.isEmpty { file.since = Date() }
        file.counts[control.rawValue, default: 0] += n
        save()
    }

    /// The inline ones a take carried, in one go.
    func note(_ commands: [SpokenCommand]) {
        note(.screenshot, commands.filter { $0 == .screenshot }.count)
        note(.filePath, commands.filter { $0 == .filePath }.count)
        note(.link, commands.filter { $0 == .pageURL }.count)
    }

    func clear() {
        file = File()
        save()
    }

    private func save() {
        NotificationCenter.default.post(name: Self.changed, object: nil)
        let snapshot = file
        let url = self.url
        io.async {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }
}
