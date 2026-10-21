// Settings › Models, drawn from design/models-pane-redesign.html: where each
// job runs, kept apart. Transcription runs on SayControl's cloud, on this Mac
// or on a provider's API with your own key; polish on the cloud or a key (a
// model on this Mac comes later). The agent voice is the cloud's and lives in
// Agents. Across the top, the route your words take and one line on where
// your audio and your text go; at the bottom, every key saved on this Mac,
// ready for either job.
import Cocoa

final class ModelsPage: NSView {
    /// Opens another Settings section — Account, to sign in.
    var onOpenTab: (String) -> Void = { _ in }
    weak var scroll: NSScrollView?

    private let column = NSStackView()
    private var sections: [String: NSView] = [:]

    /// The key provider whose tile is picked, apart from the one in use:
    /// picking a tile shows its key box; only a working key switches to it.
    private var trTile: Provider
    private var poTile: PolishProvider
    /// "tr:openai" while that key is being checked.
    private var checking: String?
    /// A key's last refusal, per tile, in the provider's words.
    private var problems: [String: String] = [:]
    private var keyFields: [String: NSTextField] = [:]
    /// Per local family, the size whose row is showing.
    private var sizes: [String: String] = [:]
    private var search = ""
    private var trying = false
    private var tryResult: (text: String, ms: Int, ok: Bool)?
    private var loadingModels: Set<PolishProvider> = []
    /// A polish key's chat models, read once per run.
    private static var polishModels: [PolishProvider: [String]] = [:]

    private var progress: [String: (bar: MeterBar, label: NSTextField)] = [:]
    private var timer: Timer?
    private var installedSig = ""

    init() {
        let provider = Config.shared.provider
        trTile = (provider == .local) ? Config.shared.lastKeyProvider : provider
        poTile = Config.shared.polishProvider
        super.init(frame: .zero)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: Theme.m(4)),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(changed), name: LocalSpeed.changed, object: nil)
        nc.addObserver(self, selector: #selector(changed), name: .sayctrlAccountChanged, object: nil)
        render()
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit {
        NotificationCenter.default.removeObserver(self)
        timer?.invalidate()
    }

    @objc private func changed() { render() }

    func appeared() {
        render()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        if Config.shared.transcriptionSource == .mac { LocalEngine.shared.warmUp() }
    }

    func disappeared() {
        timer?.invalidate()
        timer = nil
    }

    /// Download progress moves in place; a finished download redraws.
    private func tick() {
        let rows = LocalEngine.shared.rows()
        let sig = rows.map { "\($0["id"] ?? "")\($0["installed"] ?? "")\($0["downloading"] ?? "")" }.joined()
        if sig != installedSig { return render() }
        for row in rows where row["downloading"] as? Bool == true {
            guard let id = row["id"] as? String, let views = progress[id] else { continue }
            let pct = row["progress"] as? Double ?? 0
            views.bar.fraction = pct / 100
            views.label.stringValue = String(format: "%.0f%%", pct)
        }
    }

    // MARK: - The page

    private func render() {
        installedSig = LocalEngine.shared.rows()
            .map { "\($0["id"] ?? "")\($0["installed"] ?? "")\($0["downloading"] ?? "")" }.joined()
        column.arrangedSubviews.forEach { $0.removeFromSuperview() }
        progress = [:]
        keyFields = [:]
        sections = [:]
        place(RouteCard(transcription: transcriptionStep(), polish: polishStep(),
                        transcriptionIcon: sourceIcon, privacy: privacyLine()) { [weak self] which in
            self?.jump(to: which)
        })
        place(transcriptionSection(), gap: 28, key: "transcription")
        place(polishSection(), gap: 30, key: "polish")
        place(savedKeysSection(), gap: 22)
        if !Config.retail, Config.shared.transcriptionSource == .mac { place(meshSection(), gap: 4) }
    }

    private func place(_ view: NSView, gap: CGFloat = 0, key: String? = nil) {
        if let last = column.arrangedSubviews.last { column.setCustomSpacing(Theme.m(gap), after: last) }
        column.addArrangedSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        if let key = key { sections[key] = view }
    }

    private func jump(to key: String) {
        guard let target = sections[key], let scroll = scroll, let doc = scroll.documentView else { return }
        let y = target.convert(NSPoint.zero, to: doc).y - Theme.m(6)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            scroll.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: max(0, y)))
        }
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: - Where things stand

    struct Step {
        var ok: Bool
        var off = false
        var busy = false
        let value: String
        let place: String
    }

    private var sourceIcon: (String, Theme.Hue) {
        switch Config.shared.transcriptionSource {
        case .cloud: return ("cloud", .blue)
        case .mac:   return ("laptopcomputer", .green)
        case .key:   return ("key", .amber)
        }
    }

    private func transcriptionStep() -> Step {
        let config = Config.shared
        switch config.transcriptionSource {
        case .cloud:
            return Account.signedIn ? Step(ok: true, value: "SayControl Cloud", place: "Cloud")
                                    : Step(ok: false, value: "SayControl Cloud", place: "Sign in first")
        case .mac:
            if let entry = LocalEngine.shared.selectedEntry() {
                return Step(ok: true, value: entry.name, place: "On this Mac")
            }
            if let row = LocalEngine.shared.rows().first(where: { $0["downloading"] as? Bool == true }) {
                return Step(ok: false, busy: true, value: row["name"] as? String ?? "",
                            place: String(format: "Downloading %.0f%%", row["progress"] as? Double ?? 0))
            }
            return Step(ok: false, value: "No model yet", place: "Download one")
        case .key:
            let p = config.provider
            if p == .gpu { return Step(ok: true, value: config.model, place: "Own GPU") }
            guard config.apiKey(for: p) != nil else { return Step(ok: false, value: "No model yet", place: "Add a key") }
            return Step(ok: true, value: config.model, place: "\(p.title) key")
        }
    }

    /// Cloud polish answers only takes the cloud heard (they carry its
    /// receipt), so it is the route only while transcription is there too.
    private var polishOnCloud: Bool {
        Config.shared.transcriptionSource == .cloud && Config.shared.modelsViaCloud
    }

    private func polishStep() -> Step {
        let config = Config.shared
        if !config.refine { return Step(ok: true, off: true, value: "Off", place: "Pastes what it heard") }
        if polishOnCloud { return Step(ok: true, value: "SayControl Cloud", place: "Cloud") }
        if config.transcriptionSource == .cloud, !Account.signedIn, config.flag("POLISH_CLOUD", default: true) {
            return Step(ok: false, value: "SayControl Cloud", place: "Sign in first")
        }
        guard config.refineKey != nil else { return Step(ok: false, value: "No model yet", place: "Add a key") }
        return Step(ok: true, value: config.refineModel, place: "\(config.polishProvider.title) key")
    }

    /// One line: where the audio goes, then where the text goes.
    private func privacyLine() -> NSAttributedString {
        let config = Config.shared
        let out = NSMutableAttributedString()
        let size = Theme.m(12.5)
        func plain(_ s: String) { out.append(NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: Theme.ink2])) }
        func bold(_ s: String) { out.append(NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: Theme.ink2])) }
        var heardBy: String?
        switch config.transcriptionSource {
        case .mac:
            bold("Your audio stays on this Mac.")
        case .cloud:
            heardBy = "SayControl Cloud"
            bold("Your audio goes to SayControl Cloud")
            plain(", which doesn’t keep it.")
        case .key:
            if config.provider == .gpu {
                heardBy = "your GPU"
                bold("Your audio goes to your own GPU.")
            } else if config.apiKey(for: config.provider) != nil {
                heardBy = config.provider.title
                bold("Your audio goes to \(config.provider.title)")
                plain(", on your key.")
            } else {
                plain("Transcription isn’t set up yet.")
            }
        }
        let polishedBy: String? = !config.refine ? nil
            : polishOnCloud ? "SayControl Cloud"
            : config.refineKey != nil ? config.polishProvider.company : ""
        switch polishedBy {
        case nil:
            if config.transcriptionSource == .mac { plain(" Nothing is polished, so "); bold("nothing leaves this Mac"); plain(".") }
            else { plain(" Nothing is polished.") }
        case "":
            plain(" Polish isn’t set up yet.")
        case let by?:
            if config.transcriptionSource == .mac { plain(" Only the text goes to \(by), for polish.") }
            else if by == heardBy { plain(" The text is polished there too.") }
            else { plain(" The text then goes to \(by) for polish.") }
        }
        return out
    }

    private func chip(_ step: Step) -> NSView {
        if step.off { return GrantChip("Off", .neutral) }
        if step.busy || !step.ok { return GrantChip(step.place, .warn) }
        return GrantChip("Ready", .ok)
    }

    // MARK: - Transcription

    private func transcriptionSection() -> NSView {
        let config = Config.shared
        let source = config.transcriptionSource
        let head = JobHeader(symbol: "waveform", hue: .rose, title: "Transcription",
                             info: "Turns your voice into text. Live models put the words on screen while you talk.",
                             trailing: [chip(transcriptionStep())])
        let plan = PlanState.current
        let cloudMeta: String
        switch plan {
        case .signedOut: cloudMeta = "Needs an account"
        case .pro, .ending: cloudMeta = "Unlimited on Pro"
        default: cloudMeta = "2,000 words a week free"
        }
        let cards = SourceCards([
            SourceCard(symbol: "cloud", hue: .blue, title: "SayControl Cloud", line: "Best accuracy. Nothing to set up.",
                       meta: cloudMeta, metaSymbol: "creditcard", picked: source == .cloud) { [weak self] in
                self?.setSource(.cloud)
            },
            SourceCard(symbol: "laptopcomputer", hue: .green, title: "This Mac", line: "Private, and works offline.",
                       meta: "Free, no account", metaSymbol: "wifi.slash", picked: source == .mac) { [weak self] in
                self?.setSource(.mac)
            },
            SourceCard(symbol: "key", hue: .amber, title: "API key", line: "Your provider, any model it has.",
                       meta: "Your provider bills you", metaSymbol: "creditcard", picked: source == .key) { [weak self] in
                self?.setSource(.key)
            },
        ])
        let panel: NSView
        switch source {
        case .cloud: panel = cloudPanel()
        case .mac:   panel = macPanel()
        case .key:   panel = keyPanel()
        }
        return stack([head, cards, panel], gaps: [12, 10])
    }

    private func setSource(_ source: Config.TranscriptionSource) {
        guard source != Config.shared.transcriptionSource else { return }
        if source == .key, Config.shared.provider == .local {
            // Back to the key last in use, or the tile on screen when there is none.
            if Config.shared.apiKey(for: Config.shared.lastKeyProvider) == nil { Config.shared.set("LAST_PAID_PROVIDER", trTile.rawValue) }
        }
        Config.shared.setTranscriptionSource(source)
        if source == .mac { LocalEngine.shared.warmUp() }
        if source == .key { trTile = Config.shared.provider }
        render()
    }

    private func cloudPanel() -> NSView {
        let group = RowGroup()
        guard Account.signedIn else {
            group.add(FormRow("Sign in to use SayControl Cloud", "Free gives you 2,000 words a week. No card.",
                              controls: [FlatButton("Sign in", .primary) { [weak self] in self?.onOpenTab("account") }],
                              icon: Self.tile("cloud", .blue)), vertical: 10)
            return group
        }
        group.add(FormRow("SayControl Cloud", "The most accurate live models we’ve measured. We pick them and keep them current.",
                          controls: [GrantChip("Live", .live)], icon: Self.tile("cloud", .blue)), vertical: 10)
        switch PlanState.current {
        case .pro, .ending:
            group.add(FormRow("Unlimited on Pro", "No word count.",
                              controls: [FlatButton("Manage plan", .quiet) { [weak self] in self?.onOpenTab("billing") }],
                              icon: Self.tile("infinity", .green)))
        case .free(let used, let limit), .low(let used, let limit):
            group.add(usageRow(used: used, limit: limit), vertical: 12)
        case .out(let limit):
            group.add(usageRow(used: limit, limit: limit), vertical: 12)
        case .signedOut:
            break
        }
        return group
    }

    private func usageRow(used: Int, limit: Int) -> NSView {
        let words = mLabel("\(used.formatted()) of \(limit.formatted()) words this week", 12.5, .medium, Theme.ink2)
        let when = mLabel("Starts again \(PlanState.refillDay)", 12, .regular, Theme.muted)
        let more = FlatButton("Go unlimited", .quiet) { [weak self] in self?.onOpenTab("billing") }
        let top = Theme.hstack([words, Theme.spacer(), when, more], spacing: Theme.m(8))
        top.alignment = .centerY
        let bar = PlanBar(Double(used) / Double(max(1, limit)), color: used >= limit ? Theme.amber : Theme.moss)
        let col = Theme.vstack([top, bar], spacing: Theme.m(8))
        top.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        bar.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        return col
    }

    // MARK: This Mac

    private func macPanel() -> NSView {
        let engine = LocalEngine.shared
        let rows = Dictionary(uniqueKeysWithValues: engine.rows().compactMap { r in (r["id"] as? String).map { ($0, r) } })
        let live = Config.shared.localLive
        let families = Self.families
        let liveHere = families.filter { live && LocalSpeed.shared.verdict($0.entries[0]) == .live }
        let rest = families.filter { f in !liveHere.contains { $0.key == f.key } }

        let group = RowGroup()
        let mac = LocalEngine.Machine.current
        let liveHead = Theme.hstack([
            RowGroup.caps("Live", color: live ? Theme.emberInk : Theme.faint),
            InfoDot("Words appear while you talk. Which models keep up is measured on this Mac (\(mac.label)); the rest write when you let go."),
            Theme.spacer(),
            Self.toggle(isOn: live) { [weak self] in
                Config.shared.setFlag("LOCAL_LIVE", !Config.shared.localLive)
                Config.shared.log("Live on this Mac: \(Config.shared.localLive)")
                self?.render()
            },
        ], spacing: Theme.m(4))
        liveHead.alignment = .centerY
        group.add(liveHead, vertical: 6)
        for f in liveHere { group.add(familyRow(f, rows: rows, liveHere: true), vertical: 8) }
        if !rest.isEmpty {
            group.add(RowGroup.caps("Writes when you let go"), vertical: 6)
            for f in rest { group.add(familyRow(f, rows: rows, liveHere: false), vertical: 8) }
        }
        let used = engine.installedIDs().compactMap(LocalEngine.entry).reduce(Int64(0)) { $0 + $1.bytes }
        let note = (used > 0 ? "\(LocalEngine.humanSize(used)) downloaded. " : "")
            + "Models run on this Mac and work with no internet. Your audio never leaves it."
        group.foot(note)
        return group
    }

    private struct Family {
        let key: String
        let name: String
        let note: String
        let hue: Theme.Hue
        /// Smallest first, with the label each size goes by.
        let entries: [LocalCatalogEntry]
        let labels: [String]
    }

    /// LOCAL_CATALOG as families with their sizes, live-capable first —
    /// the order the design lists them in.
    private static let families: [Family] = {
        func pick(_ ids: [String]) -> [LocalCatalogEntry] { ids.compactMap(LocalEngine.entry) }
        return [
            Family(key: "cohere", name: "Cohere Transcribe", note: "The most accurate", hue: .ember,
                   entries: pick(["cohere-transcribe", "cohere-transcribe-full"]), labels: ["Standard", "Full"]),
            Family(key: "qwen3", name: "Qwen3-ASR", note: "Reads your dictionary for names", hue: .violet,
                   entries: pick(["qwen3-asr-english"]), labels: ["English"]),
            Family(key: "parakeet", name: "Parakeet v3", note: "Light and quick", hue: .green,
                   entries: pick(["parakeet-v3-small", "parakeet-v3", "parakeet-v3-full"]), labels: ["Small", "Standard", "Full"]),
            Family(key: "nemotron", name: "Nemotron 3.5", note: "Many languages, small download", hue: .slate,
                   entries: pick(["nemotron-3.5", "nemotron-3.5-full"]), labels: ["Standard", "Full"]),
            Family(key: "voxtral", name: "Voxtral Realtime", note: "The biggest, most careful", hue: .amber,
                   entries: pick(["voxtral-realtime", "voxtral-realtime-full"]), labels: ["Standard", "Full"]),
            Family(key: "whisper", name: "Whisper", note: "The most languages", hue: .blue,
                   entries: pick(["whisper-small", "whisper-turbo", "whisper-large"]), labels: ["Small", "Turbo", "Large"]),
        ].filter { !$0.entries.isEmpty }
    }()

    private func familyRow(_ f: Family, rows: [String: [String: Any]], liveHere: Bool) -> NSView {
        let engine = LocalEngine.shared
        let inUse = engine.selectedEntry()?.id
        // The size on show: the one picked here, else one downloaded, else Standard.
        let shown = sizes[f.key]
            ?? f.entries.first { $0.id == inUse }?.id
            ?? f.entries.first(where: engine.isInstalled)?.id
            ?? f.entries[f.labels.firstIndex { $0 == "Standard" || $0 == "Turbo" } ?? 0].id
        let entry = LocalEngine.entry(shown) ?? f.entries[0]
        let row = rows[shown] ?? [:]

        var controls: [NSView] = []
        if f.entries.count > 1 {
            let at = f.entries.firstIndex { $0.id == shown } ?? 0
            controls.append(PillSwitcher(f.labels, selected: at) { [weak self] i in
                self?.sizes[f.key] = f.entries[i].id
                self?.render()
            })
        }
        let action: NSView
        if row["downloading"] as? Bool == true {
            let pct = row["progress"] as? Double ?? 0
            let bar = MeterBar(fraction: pct / 100)
            let label = mLabel(String(format: "%.0f%%", pct), 11.5, .medium, Theme.muted)
            progress[shown] = (bar, label)
            let cancel = IconButton("xmark", size: 24, icon: 11, tip: "Stop the download") { [weak self] in
                engine.cancel(shown)
                self?.render()
            }
            action = Theme.hstack([bar, label, cancel], spacing: Theme.m(6))
            bar.widthAnchor.constraint(equalToConstant: Theme.m(80)).isActive = true
        } else if engine.isInstalled(entry) && inUse == shown {
            action = GrantChip("In use", .ok)
        } else if engine.isInstalled(entry) {
            action = Theme.hstack([
                IconButton("trash", size: 26, icon: 12, tip: "Delete from this Mac") { [weak self] in
                    if let problem = engine.delete(shown) { SettingsUI.shared.toast(problem) }
                    self?.render()
                },
                FlatButton("Use") { [weak self] in
                    Config.shared.set(Provider.local.modelVar, shown)
                    Config.shared.log("Local model set to \(shown)")
                    engine.warmUp()
                    self?.render()
                },
            ], spacing: Theme.m(6))
        } else {
            let failed = row["error"] != nil
            action = FlatButton(failed ? "Retry" : LocalEngine.humanSize(entry.bytes), symbol: "arrow.down.to.line") { [weak self] in
                engine.download(shown)
                self?.render()
            }
        }
        controls.append(Self.actionColumn(action))

        // A model that can stream but doesn't keep up here says why, quietly.
        let slow = Config.shared.localLive && entry.family.streams && !liveHere
            ? InfoDot("Too heavy to run live on this Mac, so it writes when you let go.", symbol: "bolt.slash") : nil
        let languages = entry.languages == 1 ? "English" : "\(entry.languages) languages"
        return FormRow(f.name, "\(f.note) · \(languages)", controls: controls,
                       icon: IconTile(liveHere ? "bolt.fill" : "waveform", f.hue, side: 28, icon: 13), badge: slow)
    }

    /// The row's last column, flush right and never narrower than a download
    /// button, so the size switchers before it line up down the list. It
    /// holds its width harder than the words' help line (250) does, or the
    /// row's slack lands here: Delete and Use sat beside the switcher with
    /// the space after them, the switcher beside the name.
    private static func actionColumn(_ action: NSView) -> NSView {
        let column = NSView()
        action.translatesAutoresizingMaskIntoConstraints = false
        column.addSubview(action)
        let snug = column.widthAnchor.constraint(equalToConstant: 0)
        snug.priority = .init(500)
        NSLayoutConstraint.activate([
            column.widthAnchor.constraint(greaterThanOrEqualToConstant: Theme.m(96)),
            action.leadingAnchor.constraint(greaterThanOrEqualTo: column.leadingAnchor),
            action.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            action.topAnchor.constraint(equalTo: column.topAnchor),
            action.bottomAnchor.constraint(equalTo: column.bottomAnchor),
            snug,
        ])
        return column
    }

    // MARK: API key (transcription)

    /// Every provider with a speech API the app drives. Own GPU is the
    /// developers' RunPod, reached through its tunnel.
    private static var keyProviders: [Provider] {
        var list: [Provider] = [.openai, .elevenlabs, .assemblyai, .soniox, .xai, .gemini, .openrouter, .meta, .smallest]
        if !Config.retail { list.append(.gpu) }
        return list
    }

    private func keyPanel() -> NSView {
        let config = Config.shared
        let tiles = TileGrid(Self.keyProviders.map { p in
            ProviderTile(mono: Self.mono(p.title), hue: Self.hue(p), name: p.title,
                         sub: p == .gpu ? "Tunnel" : config.apiKey(for: p) != nil ? "Key saved" : Self.count(Self.transcriptionModels(p).count, "model"),
                         saved: p != .gpu && config.apiKey(for: p) != nil, picked: p == trTile) { [weak self] in
                guard let self = self else { return }
                self.trTile = p
                // A saved key switches over at once; a new one waits for Connect.
                if p == .gpu || config.apiKey(for: p) != nil { self.useTranscriptionProvider(p) }
                self.render()
            }
        }, columns: 4)

        let group = RowGroup()
        let p = trTile
        if p == .gpu {
            group.add(FormRow("Own GPU", "No key — reached through gpu-server/tunnel.sh.", controls: [],
                              icon: Self.monoTile("GPU", .ember)), vertical: 10)
            addModelRows(to: group, transcription: p)
        } else if let key = config.env()[p.keyVar], !key.isEmpty {
            group.add(FormRow(p.title, Self.mask(key), controls: [
                GrantChip("Connected", .ok),
                FlatButton("Remove", .quiet) { [weak self] in self?.removeKey(p.keyVar) },
            ], icon: Self.monoTile(Self.mono(p.title), Self.hue(p))), vertical: 10)
            addModelRows(to: group, transcription: p)
        } else {
            addKeyForm(to: group, id: "tr:\(p.rawValue)", name: p.title, placeholder: p.keyPlaceholder,
                       help: p.keysPage) { [weak self] key in self?.connect(p, key: key) }
        }
        return stack([tiles, group], gaps: [10])
    }

    private func useTranscriptionProvider(_ p: Provider) {
        guard Config.shared.provider != p else { return }
        Config.shared.provider = p
        Config.shared.set("LAST_PAID_PROVIDER", p.rawValue)
        Config.shared.log("Provider set to \(p.rawValue)")
    }

    /// The models this app drives for a provider, its live ones first.
    private static func transcriptionModels(_ p: Provider) -> [String] {
        if p == .gpu { return [GPU_LIVE_MODEL] }
        var ids = p.supportsLive ? p.liveModels : []
        for m in p.suggestedModels where !ids.contains(m) { ids.append(m) }
        return ids
    }

    private func addModelRows(to group: RowGroup, transcription p: Provider) {
        let live = p.supportsLive ? p.liveModels : []
        let ids = Self.transcriptionModels(p)
        let inUse = Config.shared.provider == p ? Config.shared.model : nil
        group.add(RowGroup.caps(Self.count(ids.count, "model") + (p == .gpu ? "" : " on this key")), vertical: 6)
        for id in ids {
            let isLive = live.contains(id)
            group.add(ModelChoice(id: id, tag: isLive ? GrantChip("Live", .live) : RowText.help("Writes when you let go"),
                                  picked: id == inUse) { [weak self] in
                self?.pickTranscriptionModel(id, provider: p, live: isLive)
            }, vertical: 6)
        }
    }

    private func pickTranscriptionModel(_ id: String, provider p: Provider, live: Bool) {
        useTranscriptionProvider(p)
        // Live keeps its own model slot, so a realtime-only name never leaks
        // into the upload setting.
        if !p.liveOnly { Config.shared.setFlag("LIVE", live) }
        Config.shared.set(live ? p.liveModelVar : p.modelVar, id)
        Config.shared.log("Model set to \(id)")
        render()
    }

    private func connect(_ p: Provider, key: String) {
        let id = "tr:\(p.rawValue)"
        checking = id
        problems[id] = nil
        render()
        let model = p.liveOnly ? p.defaultLiveModel : p.defaultModel
        KeyCheck.verify(p, key: key, model: model) { [weak self] outcome in
            guard let self = self else { return }
            self.checking = nil
            if outcome.ok {
                Config.shared.set(p.keyVar, key)
                Config.shared.log("\(p.title) key saved (\(outcome.line))")
                self.useTranscriptionProvider(p)
            } else {
                self.problems[id] = outcome.line
            }
            self.render()
        }
    }

    // MARK: - Polish

    private func polishSection() -> NSView {
        let config = Config.shared
        let on = config.refine
        let toggle = Self.toggle(isOn: on) { [weak self] in
            Config.shared.setFlag("REFINE", !Config.shared.refine)
            Config.shared.log("Polish toggled: \(Config.shared.refine)")
            self?.render()
        }
        let head = JobHeader(symbol: "sparkles", hue: .violet, title: "Polish",
                             info: "Tidies the text before it pastes: drops the ums and false starts, fixes punctuation, and runs command mode.",
                             trailing: on ? [chip(polishStep()), toggle] : [toggle])
        var views: [NSView] = [head]
        var gaps: [CGFloat] = []
        if !on {
            views.append(OffNote("Polish is off: SayControl pastes exactly what it heard. Command mode still uses the model below."))
            gaps.append(12)
        }
        let cloudTranscribes = config.transcriptionSource == .cloud
        let onCloud = cloudTranscribes && config.flag("POLISH_CLOUD", default: true)
        let cards = SourceCards([
            SourceCard(symbol: "cloud", hue: .blue, title: "SayControl Cloud", line: "Fast and tuned for dictation.",
                       meta: cloudTranscribes ? (Account.signedIn ? "Included in your plan" : "Needs an account")
                                              : "Polishes what the cloud transcribes",
                       metaSymbol: "creditcard", picked: onCloud, enabled: cloudTranscribes) { [weak self] in
                Config.shared.setFlag("POLISH_CLOUD", true)
                self?.tryResult = nil
                self?.render()
            },
            SourceCard(symbol: "key", hue: .amber, title: "API key", line: "Any chat model from your provider.",
                       meta: "Your provider bills you", metaSymbol: "creditcard", picked: !onCloud) { [weak self] in
                if cloudTranscribes { Config.shared.setFlag("POLISH_CLOUD", false) }
                self?.tryResult = nil
                self?.render()
            },
        ])
        if !cloudTranscribes {
            cards.toolTip = "SayControl Cloud polishes the takes it transcribed. Pick Cloud under Transcription to use it."
        }
        views.append(cards)
        gaps.append(on ? 12 : 10)
        let panel = onCloud ? polishCloudPanel() : polishKeyPanel()
        views.append(panel)
        gaps.append(10)
        let section = stack(views, gaps: gaps)
        // Dimmed, not inert: command mode still runs on what is picked here.
        if !on { cards.alphaValue = 0.55; panel.alphaValue = 0.55 }
        return section
    }

    private func polishCloudPanel() -> NSView {
        let group = RowGroup()
        guard Account.signedIn else {
            group.add(FormRow("Sign in to polish on SayControl Cloud", "Included with Free and Pro.",
                              controls: [FlatButton("Sign in", .primary) { [weak self] in self?.onOpenTab("account") }],
                              icon: Self.tile("cloud", .blue)), vertical: 10)
            return group
        }
        group.add(FormRow("SayControl Cloud", "A fast model tuned for dictation. Part of your plan, nothing to pick.",
                          controls: [], icon: Self.tile("cloud", .blue)), vertical: 10)
        group.add(tryRow(through: "SayControl Cloud"), vertical: 12)
        return group
    }

    private func polishKeyPanel() -> NSView {
        let config = Config.shared
        let tiles = TileGrid(PolishProvider.allCases.map { p in
            let saved = config.polishKey(p) != nil
            return ProviderTile(mono: Self.mono(p.title), hue: Self.hue(p), name: p.title,
                                sub: saved ? "Key saved" : "Chat models", saved: saved, picked: p == poTile) { [weak self] in
                guard let self = self else { return }
                self.poTile = p
                self.search = ""
                if config.polishKey(p) != nil { self.usePolishProvider(p) }
                self.render()
            }
        }, columns: 3)

        let group = RowGroup()
        let p = poTile
        var views: [NSView] = [tiles, group]
        if let key = config.polishKey(p) {
            let also = Self.alsoUsedForTranscription(p) ? " · also used for transcription" : ""
            group.add(FormRow(p.title, Self.mask(key) + also, controls: [
                GrantChip("Connected", .ok),
                FlatButton("Remove", .quiet) { [weak self] in self?.removeKey(p.keyVar) },
            ], icon: Self.monoTile(Self.mono(p.title), Self.hue(p))), vertical: 10)
            addPolishModels(to: group, provider: p, key: key)
            if config.polishProvider == p {
                let tryBox = RowGroup()
                tryBox.add(tryRow(through: config.refineModel), vertical: 12)
                views.append(tryBox)
            }
        } else {
            addKeyForm(to: group, id: "po:\(p.rawValue)", name: p.title, company: p.company, placeholder: p.keyPlaceholder,
                       help: p.keyHelpURL) { [weak self] key in self?.connect(p, key: key) }
        }
        return stack(views, gaps: [10, 10])
    }

    private func usePolishProvider(_ p: PolishProvider) {
        guard Config.shared.polishProvider != p else { return }
        Config.shared.set("POLISH_PROVIDER", p.rawValue)
        Config.shared.log("Polish provider set to \(p.rawValue)")
        tryResult = nil
    }

    private func addPolishModels(to group: RowGroup, provider p: PolishProvider, key: String) {
        guard let models = Self.polishModels[p] else {
            group.add(RowText.help("Reading the models on this key…"), vertical: 10)
            if !loadingModels.contains(p) {
                loadingModels.insert(p)
                PolishModels.fetch(p, key: key) { [weak self] result in
                    self?.loadingModels.remove(p)
                    if case .success(let ids) = result { Self.polishModels[p] = ids }
                    else if case .failure(let error) = result { Self.polishModels[p] = []; self?.problems["po:\(p.rawValue)"] = error.localizedDescription }
                    self?.render()
                }
            }
            return
        }
        if models.isEmpty {
            group.add(RowText.help(problems["po:\(p.rawValue)"] ?? "This key lists no chat models."), vertical: 10)
            return
        }
        let picked = Config.shared.polishProvider == p ? Config.shared.refineModel : nil
        if models.count > 8 {
            let field = FocusField()
            field.placeholderString = "Search \(p.title)’s \(models.count) models"
            field.stringValue = search
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.font = .systemFont(ofSize: Theme.m(12.5))
            let box = FieldBox(field)
            field.target = self
            field.action = #selector(searched(_:))
            field.cell?.sendsActionOnEndEditing = false
            NotificationCenter.default.addObserver(self, selector: #selector(searchTyped(_:)),
                                                   name: NSControl.textDidChangeNotification, object: field)
            group.add(box, vertical: 8)
        }
        let q = search.lowercased()
        let shown = models.filter { q.isEmpty || $0.lowercased().contains(q) }
        group.add(RowGroup.caps(Self.count(models.count, "model") + " on this key"), vertical: 6)
        // The picked one always shows, even past the first dozen.
        var rows = Array(shown.prefix(12))
        if let picked = picked, shown.contains(picked), !rows.contains(picked) { rows.append(picked) }
        for id in rows {
            group.add(ModelChoice(id: id, tag: PolishModels.isFast(id) ? RowText.help("Fast") : nil, picked: id == picked) { [weak self] in
                self?.usePolishProvider(p)
                Config.shared.set(p.modelVar, id)
                Config.shared.log("Polish model set to \(id)")
                self?.tryResult = nil
                self?.render()
            }, vertical: 6)
        }
        if shown.count > rows.count {
            group.add(RowText.help("\(shown.count - rows.count) more — search to find one."), vertical: 8)
        }
    }

    @objc private func searchTyped(_ note: Notification) {
        guard let field = note.object as? NSTextField else { return }
        search = field.stringValue
        // Redraw after the keystroke lands, then give the field its focus back.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.render()
            if let again = self.findSearchField() {
                self.window?.makeFirstResponder(again)
                again.currentEditor()?.selectedRange = NSRange(location: again.stringValue.count, length: 0)
            }
        }
    }
    @objc private func searched(_ sender: NSTextField) { search = sender.stringValue }

    private func findSearchField() -> NSTextField? {
        func walk(_ v: NSView) -> NSTextField? {
            if let f = v as? FocusField, f.placeholderString?.hasPrefix("Search") == true { return f }
            for s in v.subviews { if let f = walk(s) { return f } }
            return nil
        }
        return walk(self)
    }

    private func connect(_ p: PolishProvider, key: String) {
        let id = "po:\(p.rawValue)"
        checking = id
        problems[id] = nil
        render()
        PolishModels.fetch(p, key: key) { [weak self] result in
            guard let self = self else { return }
            self.checking = nil
            switch result {
            case .success(let ids):
                Config.shared.set(p.keyVar, key)
                Self.polishModels[p] = ids
                Config.shared.log("\(p.title) polish key saved (\(ids.count) chat models)")
                self.usePolishProvider(p)
                // The default if this key has it, else its fastest.
                if !ids.contains(Config.shared.polishModel(p)), let first = ids.first { Config.shared.set(p.modelVar, first) }
            case .failure(let error):
                self.problems[id] = error.localizedDescription
            }
            self.render()
        }
    }

    private func tryRow(through: String) -> NSView {
        let title = RowText.title("Try it")
        let line = mLabel("A messy sentence, through \(through).", 12, .regular, Theme.muted)
        let words = Theme.vstack([title, line], spacing: Theme.m(2))
        words.alignment = .leading
        words.setHuggingPriority(.init(1), for: .horizontal)
        var right: [NSView] = []
        if let r = tryResult, r.ok { right.append(GrantChip(String(format: "Answered in %.1f s", Double(r.ms) / 1000), .ok)) }
        let go = FlatButton(trying ? "Polishing…" : "Try it", symbol: "play.fill") { [weak self] in self?.runTry() }
        go.isEnabled = !trying
        right.append(go)
        let top = Theme.hstack([words] + right, spacing: Theme.m(8))
        top.alignment = .centerY

        let heard = NSMutableAttributedString()
        let size = Theme.m(12.5)
        for (piece, cut) in [("um so", true), (" I think we should ", false), ("uh", true), (" ship it on friday ", false),
                             ("no wait", true), (" after the review", false)] {
            heard.append(NSAttributedString(string: piece, attributes: cut
                ? [.font: NSFont.systemFont(ofSize: size), .foregroundColor: Theme.faint, .strikethroughStyle: 1]
                : [.font: NSFont.systemFont(ofSize: size), .foregroundColor: Theme.ink2]))
        }
        let out: NSAttributedString
        if trying {
            out = NSAttributedString(string: "Polishing…", attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: Theme.faint])
        } else if let r = tryResult {
            out = NSAttributedString(string: r.text, attributes: [.font: NSFont.systemFont(ofSize: size),
                                                                   .foregroundColor: r.ok ? Theme.ink : Theme.amber])
        } else {
            out = NSAttributedString(string: "Press Try it to see what this model does.",
                                     attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: Theme.faint])
        }
        let arrow = NSImageView(image: Theme.symbol("arrow.right", Theme.m(12), .medium) ?? NSImage())
        arrow.contentTintColor = Theme.faint
        let pair = Theme.hstack([SampleBox("Heard", heard), arrow, SampleBox("Pasted", out, done: tryResult?.ok == true)],
                                spacing: Theme.m(8))
        pair.alignment = .centerY
        pair.distribution = .fill
        if let a = pair.arrangedSubviews.first, let b = pair.arrangedSubviews.last {
            a.widthAnchor.constraint(equalTo: b.widthAnchor).isActive = true
        }
        let col = Theme.vstack([top, pair], spacing: Theme.m(10))
        top.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        pair.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        return col
    }

    private func runTry() {
        trying = true
        tryResult = nil
        render()
        Refiner.shared.tryPolish(Refiner.testSample) { [weak self] result, ms in
            guard let self = self else { return }
            self.trying = false
            switch result {
            case .success(let text): self.tryResult = (text, ms, true)
            case .failure(let error): self.tryResult = (error.localizedDescription, ms, false)
            }
            self.render()
        }
    }

    // MARK: - Keys

    /// A key box: paste, Connect, and where to get one. Nothing is saved
    /// until the provider has said yes.
    private func addKeyForm(to group: RowGroup, id: String, name: String, company: String? = nil, placeholder: String,
                            help: String, connect: @escaping (String) -> Void) {
        let field = FocusSecureField()
        field.placeholderString = "Paste your \(name) key   \(placeholder)"
        field.font = .monospacedSystemFont(ofSize: Theme.m(12), weight: .regular)
        let box = FieldBox(field)
        keyFields[id] = field
        let busy = checking == id
        field.isEnabled = !busy
        let go = FlatButton(busy ? "Checking…" : "Connect", .primary) { [weak self, weak field] in
            guard let self = self, let field = field else { return }
            let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                self.window?.makeFirstResponder(field)
                return
            }
            connect(key)
        }
        go.isEnabled = !busy
        let row = Theme.hstack([box, go], spacing: Theme.m(8))
        row.alignment = .centerY
        group.add(row, vertical: 12)

        let lock = NSImageView(image: Theme.symbol("lock.fill", Theme.m(10), .medium) ?? NSImage())
        lock.contentTintColor = Theme.moss
        let said = problems[id].map { Theme.para("✕ \($0)", 12 * 1.2, .regular, Theme.danger, lineHeight: 1.22) }
            ?? RowText.help("Saved on this Mac and sent only to \(company ?? name).")
        let get = FlatButton("Get a key", .quiet, symbol: "arrow.up.right") {
            if let url = URL(string: help) { NSWorkspace.shared.open(url) }
        }
        let foot = Theme.hstack(problems[id] == nil ? [lock, said, Theme.spacer(), get] : [said, Theme.spacer(), get],
                                spacing: Theme.m(6))
        foot.alignment = .centerY
        group.add(foot, vertical: 4)
    }

    private struct SavedKey {
        let title: String
        let keyVar: String
        let value: String
        let hue: Theme.Hue
        let uses: [String]
    }

    /// Every key in .env a provider here can use, once each.
    private func savedKeys() -> [SavedKey] {
        let config = Config.shared
        let env = config.env()
        var seen: Set<String> = []
        var out: [SavedKey] = []
        func uses(_ keyVar: String) -> [String] {
            var u: [String] = []
            if config.transcriptionSource == .key, config.provider.keyVar == keyVar { u.append("Transcription") }
            if config.refine, !polishOnCloud, config.refineKey != nil,
               config.polishProvider.keyVar == keyVar || (keyVar == "REFINE_API_KEY" && env[config.polishProvider.keyVar] == nil) {
                u.append("Polish")
            }
            return u
        }
        for p in Self.keyProviders where p != .gpu {
            guard let v = env[p.keyVar], !v.isEmpty, seen.insert(p.keyVar).inserted else { continue }
            out.append(SavedKey(title: p.title, keyVar: p.keyVar, value: v, hue: Self.hue(p), uses: uses(p.keyVar)))
        }
        for p in PolishProvider.allCases {
            guard let v = env[p.keyVar], !v.isEmpty, seen.insert(p.keyVar).inserted else { continue }
            out.append(SavedKey(title: p.title, keyVar: p.keyVar, value: v, hue: Self.hue(p), uses: uses(p.keyVar)))
        }
        if let v = env["REFINE_API_KEY"], !v.isEmpty {
            let p: PolishProvider = v.hasPrefix("csk-") ? .cerebras : .openrouter
            if env[p.keyVar] == nil {
                out.append(SavedKey(title: p.title, keyVar: "REFINE_API_KEY", value: v, hue: Self.hue(p), uses: uses("REFINE_API_KEY")))
            }
        }
        return out
    }

    private func savedKeysSection() -> NSView {
        let group = RowGroup("Saved keys")
        let keys = savedKeys()
        if keys.isEmpty {
            group.add(RowText.help("No keys yet. Keys you add above show up here, ready for either job."), vertical: 12)
        }
        for k in keys {
            var controls: [NSView] = k.uses.map { GrantChip($0, .neutral) }
            if k.uses.isEmpty { controls.append(mLabel("Not in use", 11.5, .regular, Theme.faint)) }
            controls.append(FlatButton("Remove", .quiet) { [weak self] in self?.removeKey(k.keyVar) })
            group.add(FormRow(k.title, Self.mask(k.value), controls: controls,
                              icon: Self.monoTile(Self.mono(k.title), k.hue)), vertical: 8)
        }
        group.foot("Each key is saved on this Mac and only ever sent to its own provider. Your provider bills you for what you use.")
        return group
    }

    private func removeKey(_ keyVar: String) {
        let config = Config.shared
        let value = config.env()[keyVar] ?? ""
        config.set(keyVar, nil)
        // The old single polish key stands in for Cerebras and OpenRouter;
        // removing theirs removes it too, or the key would come straight back.
        if let legacy = config.env()["REFINE_API_KEY"], legacy == value || keyVar == PolishProvider.cerebras.keyVar && legacy.hasPrefix("csk-")
            || keyVar == PolishProvider.openrouter.keyVar && !legacy.hasPrefix("csk-") {
            config.set("REFINE_API_KEY", nil)
        }
        for p in PolishProvider.allCases where p.keyVar == keyVar || keyVar == "REFINE_API_KEY" { Self.polishModels[p] = nil }
        config.log("Key removed: \(keyVar)")
        render()
    }

    private static func alsoUsedForTranscription(_ p: PolishProvider) -> Bool {
        Config.shared.transcriptionSource == .key && Config.shared.provider.keyVar == p.keyVar
    }

    // MARK: - Voice mesh (developers' build)

    private static let meshProviders: [Provider] = [.gemini, .assemblyai, .elevenlabs, .openai, .smallest, .meta, .xai, .soniox]
    private static let meshWindows: [Double] = [2, 3, 4, 5]

    /// Local dictation with a paid provider covering the first seconds —
    /// where short commands land and the local models are weakest.
    private func meshSection() -> NSView {
        let config = Config.shared
        let group = RowGroup("Voice mesh")
        let paid = config.meshProvider
        let detail: String
        if !config.liveEnabled { detail = "Needs a model that runs live on this Mac." }
        else if config.apiKey(for: paid) == nil { detail = "Add a \(paid.title) key first." }
        else { detail = "\(paid.title) hears the first seconds; the rest stays on this Mac." }
        group.add(SwitchRow("Voice mesh", detail, isOn: config.mesh) { [weak self] on in
            Config.shared.setFlag("MESH", on)
            Config.shared.log("Voice mesh toggled: \(on)")
            self?.render()
        })
        if config.mesh {
            let ear = PopButton(Self.meshProviders.map { $0.title },
                                selected: Self.meshProviders.firstIndex(of: paid) ?? 0) { [weak self] i in
                Config.shared.set("MESH_PROVIDER", Self.meshProviders[i].rawValue)
                self?.render()
            }
            group.add(FormRow("Paid ear", "", controls: [ear]))
            let window = PillSwitcher(Self.meshWindows.map { "\(Int($0))s" },
                                      selected: Self.meshWindows.firstIndex(of: config.meshSeconds) ?? 1) { i in
                Config.shared.set("MESH_SECONDS", String(Int(Self.meshWindows[i])))
            }
            group.add(FormRow("Hands over after", "", controls: [window]))
        }
        return group
    }

    // MARK: - Small helpers

    private func stack(_ views: [NSView], gaps: [CGFloat]) -> NSView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = 0
        for (i, v) in views.enumerated() {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
            if i < gaps.count { s.setCustomSpacing(Theme.m(gaps[i]), after: v) }
        }
        return s
    }

    static func tile(_ symbol: String, _ hue: Theme.Hue) -> IconTile { IconTile(symbol, hue, side: 28, icon: 13) }

    static func monoTile(_ text: String, _ hue: Theme.Hue) -> NSView { MonoTile(text, hue, side: 28) }

    static func toggle(isOn: Bool, _ flip: @escaping () -> Void) -> ToggleSwitch {
        let t = ToggleSwitch(isOn: isOn)
        t.onClick = flip
        return t
    }

    /// "sk-proj-…a91f": enough to tell keys apart, never enough to use one.
    static func mask(_ key: String) -> String {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard k.count > 8 else { return "…" }
        var head = ""
        for part in k.split(separator: "-", omittingEmptySubsequences: false).prefix(3) {
            guard part.count <= 5, part.allSatisfy({ $0.isLetter || $0.isNumber }) else { break }
            head += part + "-"
        }
        if head.isEmpty, let underscore = k.firstIndex(of: "_"), k.distance(from: k.startIndex, to: underscore) <= 4 {
            head = String(k[...underscore])
        }
        return head + "…" + k.suffix(4)
    }

    static func mono(_ title: String) -> String {
        switch title {
        case "OpenAI": return "OA"
        case "OpenRouter": return "OR"
        case "ElevenLabs": return "XI"
        case "AssemblyAI": return "AA"
        case "Smallest.ai": return "Sm"
        case "xAI": return "x"
        case "Own GPU": return "GPU"
        default: return String(title.prefix(2))
        }
    }

    static func hue(_ p: Provider) -> Theme.Hue {
        switch p {
        case .openai, .xai: return .slate
        case .elevenlabs: return .violet
        case .assemblyai, .meta: return .blue
        case .soniox: return .green
        case .gemini: return .rose
        case .openrouter: return .teal
        case .smallest: return .amber
        case .local, .gpu: return .ember
        }
    }

    static func hue(_ p: PolishProvider) -> Theme.Hue {
        switch p {
        case .anthropic: return .amber
        case .openai: return .slate
        case .openrouter: return .teal
        case .cerebras: return .ember
        case .groq: return .violet
        case .google: return .rose
        }
    }

    static func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
}

// MARK: - The page's own pieces

/// A label at a size in the sheet's own measure (Theme.m) — Theme.text
/// takes the mockup's pixels.
private func mLabel(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular,
                    _ color: NSColor = Theme.ink) -> NSTextField {
    let f = Theme.text(s, size, weight, color)
    f.font = .systemFont(ofSize: Theme.m(size), weight: weight)
    return f
}

/// A paragraph that wraps to whatever width it is given.
private func wrapping(_ text: NSAttributedString) -> WrapLabel {
    let f = WrapLabel(labelWithString: "")
    f.attributedStringValue = text
    f.usesSingleLineMode = false
    f.cell?.wraps = true
    f.cell?.isScrollable = false
    f.lineBreakMode = .byWordWrapping
    f.maximumNumberOfLines = 0
    f.setContentHuggingPriority(.init(1), for: .horizontal)
    f.setContentCompressionResistancePriority(.init(200), for: .horizontal)
    return f
}

private func mMono(_ s: String, _ size: CGFloat, _ color: NSColor = Theme.ink) -> NSTextField {
    let f = Theme.text(s, size, .regular, color)
    f.font = .monospacedSystemFont(ofSize: Theme.m(size), weight: .regular)
    return f
}

/// Across the top: Talk → Transcription → Polish → Pasted, the dot running
/// along whatever is set up, and one line on where your audio and your text
/// go. A step that still needs something is outlined; a click on it goes to
/// its section.
final class RouteCard: NSView {
    private let glow = CAGradientLayer()
    private let glow2 = CAGradientLayer()

    init(transcription: ModelsPage.Step, polish: ModelsPage.Step, transcriptionIcon: (String, Theme.Hue),
         privacy: NSAttributedString, jump: @escaping (String) -> Void) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(14)
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        for g in [glow, glow2] {
            g.type = .radial
            layer?.addSublayer(g)
        }

        let talk = RouteNode(symbol: "mic.fill", hue: .rose, key: nil, value: "Talk", place: nil, state: .end)
        let heard = RouteNode(symbol: transcriptionIcon.0, hue: transcriptionIcon.1, key: "Transcription",
                              value: transcription.value, place: transcription.place,
                              state: transcription.ok ? .ok : .warn) { jump("transcription") }
        let tidied = RouteNode(symbol: "sparkles", hue: .violet, key: "Polish", value: polish.value, place: polish.place,
                               state: polish.off ? .off : polish.ok ? .ok : .warn) { jump("polish") }
        let pasted = RouteNode(symbol: "doc.on.clipboard", hue: .slate, key: nil, value: "Pasted", place: nil, state: .end)
        let w1 = RouteWire(active: transcription.ok, delay: 0)
        let w2 = RouteWire(active: transcription.ok && polish.ok && !polish.off, delay: 0.5)
        let w3 = RouteWire(active: transcription.ok && polish.ok, delay: 1.0)
        let flow = Theme.hstack([talk, w1, heard, w2, tidied, w3, pasted], spacing: Theme.m(4))
        flow.alignment = .centerY
        flow.distribution = .fill
        for w in [w1, w2] { w.widthAnchor.constraint(equalTo: w3.widthAnchor).isActive = true }
        w1.widthAnchor.constraint(greaterThanOrEqualToConstant: Theme.m(14)).isActive = true

        let rule = ColorView(color: Theme.hairsoft)
        let shield = NSImageView(image: Theme.symbol("checkmark.shield", Theme.m(12), .medium) ?? NSImage())
        shield.contentTintColor = Theme.moss
        let line = wrapping(privacy)
        let foot = Theme.hstack([shield, line], spacing: Theme.m(8))
        foot.alignment = .firstBaseline

        let col = Theme.vstack([flow, rule, foot], spacing: Theme.m(12))
        col.alignment = .leading
        col.translatesAutoresizingMaskIntoConstraints = false
        addSubview(col)
        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: topAnchor, constant: Theme.m(14)),
            col.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(14)),
            col.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.m(14)),
            col.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.m(12)),
            flow.widthAnchor.constraint(equalTo: col.widthAnchor),
            rule.widthAnchor.constraint(equalTo: col.widthAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            foot.widthAnchor.constraint(equalTo: col.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glow.frame = bounds
        glow2.frame = bounds
        // A blue wash from the far corner and a violet one from the near:
        // the route's two jobs, faintly.
        glow.startPoint = CGPoint(x: 1, y: 1)
        glow.endPoint = CGPoint(x: 0.35, y: -0.4)
        glow2.startPoint = CGPoint(x: 0, y: 1)
        glow2.endPoint = CGPoint(x: 0.45, y: 0)
        CATransaction.commit()
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Theme.surface.cgColor
        layer?.borderColor = Theme.hairline.cgColor
        glow.colors = [Theme.Hue.blue.wash.cgColor, NSColor.clear.cgColor]
        glow2.colors = [Theme.Hue.violet.wash.cgColor, NSColor.clear.cgColor]
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

final class RouteNode: NSView {
    enum State { case ok, warn, off, end }
    private let state: State
    private let action: (() -> Void)?

    init(symbol: String, hue: Theme.Hue, key: String?, value: String, place: String?, state: State,
         action: (() -> Void)? = nil) {
        self.state = state
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(11)
        let tile = IconTile(symbol, hue, side: 26, icon: 12)
        var lines: [NSView] = []
        if let key = key { lines.append(RowGroup.caps(key)) }
        let v = mLabel(value, 12.5, .medium, Theme.ink)
        v.lineBreakMode = .byTruncatingMiddle
        v.toolTip = value
        lines.append(v)
        if let place = place {
            lines.append(mLabel(place, 11.5, state == .warn ? .medium : .regular, state == .warn ? Theme.amber : Theme.muted))
        }
        let words = Theme.vstack(lines, spacing: Theme.m(1))
        words.alignment = .leading
        let row = Theme.hstack([tile, words], spacing: Theme.m(8))
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        let pad = state == .end ? Theme.m(2) : Theme.m(9)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: Theme.m(7)),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.m(7)),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: pad),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -pad),
            v.widthAnchor.constraint(lessThanOrEqualToConstant: Theme.m(150)),
        ])
        alphaValue = state == .off ? 0.6 : 1
        setContentHuggingPriority(.required, for: .horizontal)
        if action != nil { toolTip = "Go to \(key ?? value)" }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        guard state != .end else { return }
        layer?.backgroundColor = Theme.surface.cgColor
        layer?.borderWidth = state == .warn ? 1.5 : 1
        layer?.borderColor = (state == .warn ? Theme.amber : Theme.hairline).cgColor
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
    override func mouseDown(with event: NSEvent) { action?() }
    override func resetCursorRects() { if action != nil { addCursorRect(bounds, cursor: .pointingHand) } }
}

/// A dashed wire with an ember dot travelling it while the step is live.
final class RouteWire: NSView {
    private let dash = CAShapeLayer()
    private let dot = CALayer()
    private let active: Bool
    private let delay: CFTimeInterval

    init(active: Bool, delay: CFTimeInterval) {
        self.active = active
        self.delay = delay
        super.init(frame: .zero)
        wantsLayer = true
        dash.lineWidth = 2
        dash.lineDashPattern = [5, 4]
        dash.fillColor = nil
        layer?.addSublayer(dash)
        dot.cornerRadius = 3
        dot.isHidden = !active
        layer?.addSublayer(dot)
        heightAnchor.constraint(equalToConstant: Theme.m(10)).isActive = true
        setContentHuggingPriority(.init(1), for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let y = bounds.midY
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: y))
        path.addLine(to: CGPoint(x: bounds.width, y: y))
        dash.path = path
        dot.frame = CGRect(x: 0, y: y - 3, width: 6, height: 6)
        CATransaction.commit()
        guard active, !Motion.reduced, bounds.width > 12 else { return }
        dot.removeAllAnimations()
        let move = CABasicAnimation(keyPath: "position.x")
        move.fromValue = 3
        move.toValue = bounds.width - 3
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.15, 0.85, 1]
        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = 2.6
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.5, 1)
        group.repeatCount = .infinity
        group.beginTime = CACurrentMediaTime() + delay
        group.fillMode = .backwards
        dot.add(group, forKey: "travel")
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        dash.strokeColor = Theme.hairline.cgColor
        dot.backgroundColor = Theme.ember.cgColor
        dot.shadowColor = Theme.ember.cgColor
        dot.shadowOpacity = 0.35
        dot.shadowRadius = 3
        dot.shadowOffset = .zero
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// A job's heading: its tile, its name in the display face, an ⓘ that says
/// what the job is on hover, and its state and switch on the right.
final class JobHeader: NSView {
    init(symbol: String, hue: Theme.Hue, title: String, info: String, trailing: [NSView]) {
        super.init(frame: .zero)
        let tile = IconTile(symbol, hue, side: 32, icon: 16)
        let name = Theme.hero(title, 19, 500, tracking: -0.03)
        let row = Theme.hstack([tile, name, InfoDot(info), Theme.spacer()] + trailing, spacing: Theme.m(8))
        row.alignment = .centerY
        row.setCustomSpacing(Theme.m(10), after: tile)
        row.setCustomSpacing(Theme.m(2), after: name)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(2)),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// ⓘ, or another quiet glyph, whose words show on hover: the page says
/// what something is without a line of text standing there for it.
final class InfoDot: NSView {
    init(_ text: String, symbol: String = "info.circle") {
        super.init(frame: .zero)
        let glyph = GlyphView(symbol: symbol, size: Theme.m(12), weight: .medium, side: Theme.m(18))
        glyph.tint = Theme.faint
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: Theme.m(20)),
            heightAnchor.constraint(equalToConstant: Theme.m(20)),
        ])
        toolTip = text
        setAccessibilityElement(true)
        setAccessibilityRole(.helpTag)
        setAccessibilityLabel(text)
        setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// The where-it-runs choices, side by side and equally wide.
final class SourceCards: NSStackView {
    init(_ cards: [SourceCard]) {
        super.init(frame: .zero)
        orientation = .horizontal
        distribution = .fillEqually
        alignment = .top
        spacing = Theme.m(10)
        cards.forEach(addArrangedSubview)
        if let first = cards.first { cards.dropFirst().forEach { $0.heightAnchor.constraint(equalTo: first.heightAnchor).isActive = true } }
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// One way a job can run: its tile and a check, its name and one line, and
/// at the foot what it costs. The picked one wears an ink ring.
final class SourceCard: NSView {
    private let picked: Bool
    private let enabled: Bool
    private let onPick: () -> Void
    private let check = CheckDot()
    private var hovering = false { didSet { needsDisplay = true } }

    init(symbol: String, hue: Theme.Hue, title: String, line: String, meta: String, metaSymbol: String,
         picked: Bool, enabled: Bool = true, onPick: @escaping () -> Void) {
        self.picked = picked
        self.enabled = enabled
        self.onPick = onPick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(14)
        check.on = picked
        let tile = IconTile(symbol, hue, side: 30, icon: 14)
        let top = Theme.hstack([tile, Theme.spacer(), check], spacing: 0)
        top.alignment = .top
        let name = mLabel(title, 14, .semibold, Theme.ink)
        let say = RowText.help(line)
        let rule = ColorView(color: Theme.hairsoft)
        let metaIcon = NSImageView(image: Theme.symbol(metaSymbol, Theme.m(10), .medium) ?? NSImage())
        metaIcon.contentTintColor = Theme.faint
        let foot = Theme.hstack([metaIcon, mLabel(meta, 11.5, .regular, Theme.faint)], spacing: Theme.m(6))
        foot.alignment = .centerY
        let col = Theme.vstack([top, name, say, rule, foot], spacing: Theme.m(2))
        col.alignment = .leading
        col.setCustomSpacing(Theme.m(10), after: top)
        col.setCustomSpacing(Theme.m(10), after: say)
        col.setCustomSpacing(Theme.m(9), after: rule)
        col.translatesAutoresizingMaskIntoConstraints = false
        addSubview(col)
        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: topAnchor, constant: Theme.m(13)),
            col.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(14)),
            col.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.m(14)),
            col.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Theme.m(12)),
            top.widthAnchor.constraint(equalTo: col.widthAnchor),
            say.widthAnchor.constraint(equalTo: col.widthAnchor),
            rule.widthAnchor.constraint(equalTo: col.widthAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
        ])
        alphaValue = enabled ? 1 : 0.5
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(title)
        setAccessibilityValue(picked)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { hovering = enabled }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { if enabled && !picked { onPick() } }
    override func resetCursorRects() { if enabled && !picked { addCursorRect(bounds, cursor: .pointingHand) } }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Theme.surface.cgColor
        layer?.borderWidth = picked ? 1.5 : 1
        layer?.borderColor = (picked ? Theme.ink : hovering ? Theme.lipColor : Theme.hairline).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = picked || hovering ? 0.08 : 0
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        layer?.masksToBounds = false
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// The round check in a card's corner: an empty ring, or ink with a tick.
final class CheckDot: NSView {
    var on = false { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: Theme.m(18), height: Theme.m(18)) }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        if on {
            Theme.ink.setFill()
            NSBezierPath(ovalIn: r).fill()
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: r.minX + r.width * 0.28, y: r.midY))
            tick.line(to: NSPoint(x: r.minX + r.width * 0.44, y: r.minY + r.height * 0.32))
            tick.line(to: NSPoint(x: r.minX + r.width * 0.72, y: r.minY + r.height * 0.68))
            tick.lineWidth = 1.8
            tick.lineCapStyle = .round
            tick.lineJoinStyle = .round
            Theme.paper.setStroke()
            tick.stroke()
        } else {
            Theme.lipColor.setStroke()
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }
    override var isFlipped: Bool { true }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// A provider's initials on its hue: a tile for a company, not a logo.
final class MonoTile: NSView {
    private let hue: Theme.Hue
    init(_ text: String, _ hue: Theme.Hue, side: CGFloat) {
        self.hue = hue
        super.init(frame: .zero)
        wantsLayer = true
        let s = Theme.m(side)
        layer?.cornerRadius = (s * 0.28).rounded()
        let label = mLabel(text, text.count > 2 ? 9.5 : 12, .semibold, hue.ink)
        label.font = NSFont.systemFont(ofSize: Theme.m(text.count > 2 ? 9.5 : 12), weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: s),
            heightAnchor.constraint(equalToConstant: s),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = hue.wash.cgColor }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// A provider to pick: initials, name, and whether its key is saved.
final class ProviderTile: NSView {
    private let picked: Bool
    private let onPick: () -> Void
    private var hovering = false { didSet { needsDisplay = true } }

    init(mono: String, hue: Theme.Hue, name: String, sub: String, saved: Bool, picked: Bool, onPick: @escaping () -> Void) {
        self.picked = picked
        self.onPick = onPick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(12)
        let words = Theme.vstack([mLabel(name, 13, .semibold, Theme.ink),
                                  mLabel(sub, 11, saved ? .medium : .regular, saved ? Theme.moss : Theme.faint)],
                                 spacing: Theme.m(1))
        words.alignment = .leading
        let row = Theme.hstack([MonoTile(mono, hue, side: 28), words], spacing: Theme.m(9))
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: Theme.m(9)),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.m(9)),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(10)),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Theme.m(8)),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(name)
        setAccessibilityValue(picked)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { if !picked { onPick() } }
    override func resetCursorRects() { if !picked { addCursorRect(bounds, cursor: .pointingHand) } }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Theme.surface.cgColor
        layer?.borderWidth = picked ? 1.5 : 1
        layer?.borderColor = (picked ? Theme.ink : hovering ? Theme.lipColor : Theme.hairline).cgColor
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// Tiles in rows of `columns`, every tile the same width.
final class TileGrid: NSStackView {
    init(_ tiles: [NSView], columns: Int) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = Theme.m(8)
        var i = 0
        while i < tiles.count {
            var row = Array(tiles[i..<min(i + columns, tiles.count)])
            while row.count < columns { row.append(NSView()) }
            let line = NSStackView(views: row)
            line.orientation = .horizontal
            line.distribution = .fillEqually
            line.spacing = Theme.m(8)
            addArrangedSubview(line)
            line.translatesAutoresizingMaskIntoConstraints = false
            line.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            i += columns
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// One model to pick: a radio, its id, what it does, and "In use".
final class ModelChoice: NSView {
    private let onPick: () -> Void
    private let picked: Bool

    init(id: String, tag: NSView?, picked: Bool, onPick: @escaping () -> Void) {
        self.onPick = onPick
        self.picked = picked
        super.init(frame: .zero)
        let radio = RadioDot()
        radio.on = picked
        let name = mMono(id, 12.5, Theme.ink)
        name.lineBreakMode = .byTruncatingMiddle
        var views: [NSView] = [radio, name, Theme.spacer()]
        if let tag = tag { views.append(tag) }
        if picked { views.append(GrantChip("In use", .ok)) }
        let row = Theme.hstack(views, spacing: Theme.m(10))
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: Theme.m(24)),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(id)
        setAccessibilityValue(picked)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseDown(with event: NSEvent) { if !picked { onPick() } }
    override func resetCursorRects() { if !picked { addCursorRect(bounds, cursor: .pointingHand) } }
}

final class RadioDot: NSView {
    var on = false { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: Theme.m(16), height: Theme.m(16)) }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1.5, dy: 1.5)
        (on ? Theme.ink : Theme.lipColor).setStroke()
        let ring = NSBezierPath(ovalIn: r)
        ring.lineWidth = 1.5
        ring.stroke()
        if on {
            Theme.ink.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: r.width * 0.27, dy: r.height * 0.27)).fill()
        }
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// A thin progress bar, moved in place while a model downloads.
final class MeterBar: NSView {
    var fraction: Double { didSet { needsDisplay = true } }
    init(fraction: Double) {
        self.fraction = fraction
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: Theme.m(5)).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.height / 2
        Theme.wellFill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: r, yRadius: r).fill()
        let w = bounds.width * CGFloat(max(0, min(1, fraction)))
        guard w > 0 else { return }
        Theme.ember.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: max(w, bounds.height), height: bounds.height), xRadius: r, yRadius: r).fill()
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// The note in place of Polish's choices while it is off.
final class OffNote: NSView {
    init(_ text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(12)
        layer?.borderWidth = 1
        let icon = NSImageView(image: Theme.symbol("power", Theme.m(12), .medium) ?? NSImage())
        icon.contentTintColor = Theme.muted
        let label = wrapping(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: Theme.m(12.5)), .foregroundColor: Theme.ink2]))
        let row = Theme.hstack([icon, label], spacing: Theme.m(10))
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: Theme.m(10)),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.m(10)),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(14)),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.m(14)),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Theme.wellFill.cgColor
        layer?.borderColor = Theme.hairline.cgColor
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

/// Try it's two boxes: what was heard, fillers struck through, and what
/// would paste.
final class SampleBox: NSView {
    private let done: Bool
    init(_ caption: String, _ text: NSAttributedString, done: Bool = false) {
        self.done = done
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.m(10)
        let cap = RowGroup.caps(caption)
        let body = wrapping(text)
        let col = Theme.vstack([cap, body], spacing: Theme.m(4))
        col.alignment = .leading
        col.translatesAutoresizingMaskIntoConstraints = false
        addSubview(col)
        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: topAnchor, constant: Theme.m(10)),
            col.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Theme.m(10)),
            col.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.m(12)),
            col.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.m(12)),
            body.widthAnchor.constraint(equalTo: col.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = (done ? Theme.mossSoft : Theme.wellFill).cgColor
        layer?.borderWidth = done ? 0 : 1
        layer?.borderColor = Theme.hairline.cgColor
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}
