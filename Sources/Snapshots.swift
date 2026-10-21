// Dev tool: `SayCtrl --snapshot <dir>` renders every settings pane (light
// and dark) and every pill state to PNGs in <dir>, then exits. No Screen
// Recording permission needed — the views draw themselves off-screen.
import Cocoa

func runSnapshotsIfRequested() -> Bool {
    guard let i = CommandLine.arguments.firstIndex(of: "--snapshot"),
          CommandLine.arguments.count > i + 1 else { return false }
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    Motion.still = true

    func write(_ view: NSView, _ name: String) {
        view.layoutSubtreeIfNeeded()
        let size = view.bounds.size
        guard size.width > 1, size.height > 1 else { return }

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: dir.appendingPathComponent(name))
    }

    /// The whole window as its layers composite it — sidebar, pane and top
    /// bar together. `cacheDisplay` whites out behind a scroll view; the
    /// layer tree doesn't, so this is the one that shows the real layout.
    func writeLayers(_ view: NSView, _ name: String) {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard view.layer != nil else { return }
        let scale: CGFloat = 2
        let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
        guard w > 1, h > 1,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        func scrolls(_ v: NSView) -> [NSScrollView] {
            if let s = v as? NSScrollView { return [s] }
            return v.subviews.flatMap(scrolls)
        }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            // The window paints its own background outside the layer tree.
            if let bg = view.window?.backgroundColor {
                ctx.setFillColor(bg.cgColor)
                ctx.fill(CGRect(origin: .zero, size: view.bounds.size))
            }
            // Back to front, one top-level view at a time, so a sheet over a
            // pane covers it. The layer tree leaves scroll views empty: each
            // one's visible document is painted in right after its own view.
            for sub in view.subviews where !sub.isHidden {
                guard let subLayer = sub.layer else { continue }
                let y = view.isFlipped ? view.bounds.height - sub.frame.maxY : sub.frame.minY
                ctx.saveGState()
                ctx.translateBy(x: sub.frame.minX, y: y)
                subLayer.render(in: ctx)
                ctx.restoreGState()
                for sv in scrolls(sub) {
                    guard let doc = sv.documentView, !sv.isHidden else { continue }
                    let visible = sv.contentView.documentVisibleRect
                    guard visible.width > 1, visible.height > 1,
                          let rep = doc.bitmapImageRepForCachingDisplay(in: visible),
                          let frame = sv.superview?.convert(sv.frame, to: view) else { continue }
                    doc.cacheDisplay(in: visible, to: rep)
                    guard let cg = rep.cgImage else { continue }
                    let fy = view.isFlipped ? view.bounds.height - frame.maxY : frame.minY
                    ctx.draw(cg, in: CGRect(x: frame.minX, y: fy, width: frame.width, height: frame.height))
                }
            }
        }
        guard let image = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
    }

    // The plan's numbers are the server's: wait for them, a few seconds at
    // most, so the panes that show an allowance (Agents, Plans) draw it.
    if Cloud.shared.signedIn {
        var answered = false
        Cloud.shared.refreshAccount { _ in answered = true }
        let until = Date().addingTimeInterval(6)
        while !answered, Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    // The settings window, every pane, both appearances.
    SettingsUI.shared.present(selecting: "overview")
    guard let window = NSApp.windows.first(where: { $0.title == "SayControl" }),
          let content = window.contentView else { return true }
    for mode in ["light", "dark"] {
        NSApp.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
        for pane in ["overview", "dictionary", "insights", "phrases", "tones",
                     "agents", "agent-claude", "agent-codex", "agent-cursor", "agent-opencode", "help"] {
            SettingsUI.shared.select(pane)
            // The alert corner (Alerts.swift), shown over the Tones pane so
            // its card is in the pictures; cleared before the next pane.
            if pane == "tones" {
                AppAlerts.shared.post(AppAlert(
                    id: "snapshot", title: "Polish is failing: the key's account is out of credit",
                    message: "Your words pasted as spoken. Top up the account, or save another key.",
                    actionTitle: "Open Settings", action: {}))
            } else {
                AppAlerts.shared.clear("snapshot")
            }
            // Give auto layout and the appearance switch a real runloop turn —
            // without it the capture sees a half-settled window.
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            window.layoutIfNeeded()
            window.displayIfNeeded()
            // Card-scroll panes white out when captured through NSScrollView —
            // capture their document view directly (full height, same pixels).
            func findDoc(_ v: NSView) -> NSView? {
                if v is FlippedView { return v }
                for s in v.subviews { if let f = findDoc(s) { return f } }
                return nil
            }
            write(findDoc(content) ?? content, "window-\(pane)-\(mode).png")
            write(content, "window-\(pane)-\(mode)-full.png")
            writeLayers(content, "window-\(pane)-\(mode)-comp.png")
            // A Recent row's actions only show on hover — light the second
            // row up so they can be seen.
            if pane == "overview" {
                func rows(_ v: NSView) -> [RecentRow] {
                    if let r = v as? RecentRow { return [r] }
                    return v.subviews.flatMap(rows)
                }
                if let row = rows(content).dropFirst().first {
                    row.setHovering(true)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                    window.displayIfNeeded()
                    writeLayers(content, "window-overview-\(mode)-hover-comp.png")
                    row.setHovering(false)
                }
            }
        }
    }

    // How it works, in its sheet over the Overview: each tab on its first
    // point, Controls with See more open, the terminal point with every
    // terminal command open, and Ask an AI. The tool runs under Reduce
    // Motion (Motion.still), so every demo is drawn at its last frame. Each
    // is the window as it composites, then the tab's page at full length.
    for mode in ["light", "dark"] {
        NSApp.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
        SettingsUI.shared.select("overview")
        SettingsUI.shared.showCommands()
        guard let sheet = content.subviews.first(where: { $0 is CommandsSheet }) as? CommandsSheet else { continue }
        let shots: [(name: String, tab: HowTab, point: Int, more: Bool, terminal: Bool)] = [
            ("dictation", .dictation, 0, false, false),
            ("controls", .controls, 0, false, false),
            ("command", .command, 0, false, false),
            ("controls-more", .controls, 0, true, false),
            ("controls-terminal", .controls, 7, false, true),
            ("controls-ask", .controls, 4, false, false),
        ]
        func findDoc(_ v: NSView) -> NSView? {
            if let s = v as? NSScrollView { return s.documentView }
            for s in v.subviews { if let f = findDoc(s) { return f } }
            return nil
        }
        for shot in shots {
            sheet.showForSnapshot(shot.tab, point: shot.point, more: shot.more, terminal: shot.terminal)
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            window.layoutIfNeeded()
            window.displayIfNeeded()
            writeLayers(content, "howto-\(shot.name)-\(mode).png")
            if let doc = findDoc(sheet) { write(doc, "howto-\(shot.name)-\(mode)-page.png") }
        }
        SettingsUI.shared.dismissOverlay()
    }

    // The sidebar on its own, open and folded, both appearances.
    if let side = SettingsUI.shared.sidebarView {
        let wasFolded = SettingsUI.shared.sidebarCollapsed
        for mode in ["light", "dark"] {
            NSApp.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
            for folded in [false, true] {
                SettingsUI.shared.setSidebar(collapsed: folded, animated: false)
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                window.layoutIfNeeded()
                window.displayIfNeeded()
                write(side, "sidebar-\(folded ? "folded" : "open")-\(mode).png")
            }
        }
        SettingsUI.shared.setSidebar(collapsed: wasFolded, animated: false)
    }

    // Every Settings section. Settings is a sheet over the window now, so what
    // gets captured is the whole window: the sheet, its rail, and the pane it
    // is floating over. (cacheDisplay paints the scrim but not the backdrop
    // under it, so the app behind comes out flat grey here rather than dimmed.
    // Use --windowshot for what it really looks like.)
    for mode in ["light", "dark"] {
        NSApp.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
        SettingsUI.shared.select("overview")
        for tab in SettingsSheet.visibleTabKeys {
            SettingsUI.shared.showSettings(tab: tab)
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            window.layoutIfNeeded()
            window.displayIfNeeded()
            write(content, "settings-\(tab)-\(mode).png")
            writeLayers(content, "settings-\(tab)-\(mode)-comp.png")
        }
        SettingsUI.shared.dismissOverlay()
    }

    // Tones: the list folded, then each place's row open on its picked
    // tone — the washes are on whenever a row is open.
    for mode in ["light", "dark"] {
        NSApp.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
        SettingsUI.shared.select("tones")
        for tab in 0...ToneContext.allCases.count {
            (SettingsUI.shared.currentPane as? TonesPane)?.select(tab: tab)
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            window.layoutIfNeeded()
            window.displayIfNeeded()
            let name = tab < ToneContext.allCases.count ? ToneContext.allCases[tab].rawValue : "folded"
            // Same as the pane loop above: capture the scroll's document view,
            // so the whole column shows instead of the window's first screen.
            func findDoc(_ v: NSView) -> NSView? {
                if v is FlippedView { return v }
                for s in v.subviews { if let f = findDoc(s) { return f } }
                return nil
            }
            write(findDoc(content) ?? content, "tones-\(name)-\(mode).png")
        }
    }

    // The tray Set Up slides out under System Settings, asking and done, on
    // a stand-in of the window's foot.
    for (mode, look) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        NSApp.appearance = NSAppearance(named: look)
        for done in [false, true] {
            let face = DragToListPanel.shared.face(done: done)
            let pad: CGFloat = 40
            let stage = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: face.frame.width + 2 * pad,
                                                     height: face.frame.height + 2 * pad + 30),
                                 styleMask: .borderless, backing: .buffered, defer: false)
            stage.backgroundColor = look == .aqua ? Theme.hex(0xD9DEE8) : Theme.hex(0x22252E)
            let root = NSView()
            root.wantsLayer = true
            let foot = ColorView(color: look == .aqua ? Theme.hex(0xF3F3F3) : Theme.hex(0x232325), radius: 0)
            foot.frame = NSRect(x: 0, y: face.frame.height + pad, width: face.frame.width + 2 * pad, height: 30)
            face.frame.origin = NSPoint(x: pad, y: pad)
            root.addSubview(face)
            root.addSubview(foot)
            stage.contentView = root
            stage.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            writeLayers(root, "guide-tray-\(done ? "done" : "ask")-\(mode).png")
            stage.orderOut(nil)
        }
    }

    // The Settings pane's General sub-section, at the largest text size — this
    // also exercises the window rebuild that the Text size setting triggers.
    NSApp.appearance = NSAppearance(named: .aqua)
    Theme.scale = 1.40
    SettingsSheet.lastTab = 0
    SettingsUI.shared.rebuildAfterScaleChange()
    RunLoop.main.run(until: Date().addingTimeInterval(0.25))
    if let w2 = NSApp.windows.first(where: { $0.isVisible && $0.title == "SayControl" }), let c2 = w2.contentView {
        w2.layoutIfNeeded()
        w2.displayIfNeeded()
        write(c2, "window-settings-general-largest.png")
    }
    Theme.scale = CGFloat(Config.defaultFontScale)
    SettingsSheet.lastTab = 0

    // The pill, every state, on the pages its edge has to hold against: a
    // white document (the hard case), a dark editor and a wallpaper. The
    // frost is a behind-window blur that only exists on a live screen, so a
    // stand-in paints what it lands as — ash over the page, the real edge,
    // and the drop shadow the window server gives the panel.
    final class GlassStage: NSView {
        enum Page { case white, code, photo }
        var page = Page.white
        var glass: [(rect: NSRect, radius: CGFloat)] = []

        override func draw(_ dirtyRect: NSRect) {
            let b = bounds
            func line(_ hex: UInt32, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat) {
                NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                        blue: CGFloat(hex & 0xFF) / 255, alpha: 1).setFill()
                NSBezierPath(rect: NSRect(x: x, y: b.maxY - y - 5, width: w, height: 5)).fill()
            }
            switch page {
            case .white:
                NSColor.white.setFill()
                NSBezierPath(rect: b).fill()
                var y: CGFloat = 16
                for (i, f) in [0.55, 0.78, 0.70, 0.82, 0.64, 0.75, 0.58, 0.8, 0.7, 0.66, 0.77, 0.6].enumerated() {
                    line(i == 0 ? 0xDADADA : 0xE6E6E6, 14, y, b.width * CGFloat(f))
                    y += 14
                }
            case .code:
                NSColor(srgbRed: 0.118, green: 0.122, blue: 0.133, alpha: 1).setFill()
                NSBezierPath(rect: b).fill()
                var y: CGFloat = 16
                let rows: [(UInt32, CGFloat, CGFloat)] = [(0xC678DD, 14, 0.18), (0x5C6370, 26, 0.5), (0x98C379, 26, 0.38),
                                                          (0xE5C07B, 14, 0.24), (0x61AFEF, 26, 0.44), (0x5C6370, 26, 0.3)]
                for i in 0..<12 {
                    let r = rows[i % rows.count]
                    line(r.0, r.1, y, b.width * r.2)
                    y += 14
                }
            case .photo:
                NSGradient(colors: [NSColor(srgbRed: 0.914, green: 0.725, blue: 0.541, alpha: 1),
                                    NSColor(srgbRed: 0.557, green: 0.435, blue: 0.525, alpha: 1),
                                    NSColor(srgbRed: 0.184, green: 0.275, blue: 0.376, alpha: 1)])?
                    .draw(in: b, angle: -70)
            }
            for g in glass {
                let path = NSBezierPath(roundedRect: g.rect, xRadius: g.radius, yRadius: g.radius)
                // The panel's shadow falls outside the glass only.
                for (blur, dy, a) in [(CGFloat(22), CGFloat(-8), CGFloat(0.26)), (3, -1, 0.28)] {
                    NSGraphicsContext.saveGraphicsState()
                    let outside = NSBezierPath(rect: b)
                    outside.append(path)
                    outside.windingRule = .evenOdd
                    outside.addClip()
                    let s = NSShadow()
                    s.shadowBlurRadius = blur
                    s.shadowOffset = NSSize(width: 0, height: dy)
                    s.shadowColor = NSColor.black.withAlphaComponent(a)
                    s.set()
                    NSColor.black.setFill()
                    path.fill()
                    NSGraphicsContext.restoreGraphicsState()
                }
                PillView.glass.withAlphaComponent(0.9).setFill()
                path.fill()
                PillView.drawGlassEdge(in: g.rect, radius: g.radius)
            }
        }
    }

    let pillStates: [(state: PillState, name: String, command: Bool)] = [
        (.idle, "idle", false), (.recording, "recording", false), (.recording, "recording-command", true),
        (.transcribing, "transcribing", false), (.transcribing, "transcribing-command", true),
        (.attention, "attention", false), (.needsAccess, "needs-access", false),
        (.learned, "learned", false), (.nothingHeard, "nothing-heard", false),
    ]
    func pillCell(_ state: PillState, command: Bool, vertical: Bool, page: GlassStage.Page,
                  word: String = "Kubernetes") -> GlassStage {
        let cell = vertical ? NSSize(width: 90, height: 210) : NSSize(width: 250, height: 84)
        let stage = GlassStage(frame: NSRect(origin: .zero, size: cell))
        stage.page = page
        let pill = PillView(frame: .zero)
        pill.dock = .bottomCenter
        pill.command = command            // before the state, as startRecording does
        pill.learnedWord = word
        // Seven seconds into a take; transcribing freezes the timer there.
        pill.state = state == .transcribing ? .recording : state
        pill.recordingStarted = Date().addingTimeInterval(-7.2)
        pill.state = state
        pill.level = 0.7
        pill.phase = 2.2
        let size = Pill.size(for: state, vertical: vertical, command: command, word: pill.shownWord)
        pill.frame = NSRect(x: ((cell.width - size.width) / 2).rounded(), y: ((cell.height - size.height) / 2).rounded(),
                            width: size.width, height: size.height)
        stage.glass = [(pill.frame, min(size.width, size.height) / 2)]
        stage.addSubview(pill)
        return stage
    }
    for p in pillStates {
        write(pillCell(p.state, command: p.command, vertical: false, page: .white), "pill-\(p.name).png")
        write(pillCell(p.state, command: p.command, vertical: true, page: .white), "pill-\(p.name)-vertical.png")
    }
    // The live line: a few words, a full line sliding under the fade, a
    // command lit and then folded to its chip, and a take's last half minute.
    func lineCell(_ text: String, lit: Bool = false, countdown: Bool = false, page: GlassStage.Page = .white) -> GlassStage {
        let cell = NSSize(width: 470, height: 84)
        let stage = GlassStage(frame: NSRect(origin: .zero, size: cell))
        stage.page = page
        let pill = PillView(frame: .zero)
        pill.dock = .bottomCenter
        pill.state = .recording
        pill.recordingStarted = Date().addingTimeInterval(countdown ? -(MAX_CLIP_SECONDS - 25.5) : -7.2)
        let line = PillLine()
        line.update(text)
        line.settleForSnapshot(lit: lit)
        pill.line = line
        pill.level = 0.7
        pill.phase = 2.2
        let size = pill.targetSize
        pill.frame = NSRect(x: ((cell.width - size.width) / 2).rounded(), y: ((cell.height - size.height) / 2).rounded(),
                            width: size.width, height: size.height)
        stage.glass = [(pill.frame, min(size.width, size.height) / 2)]
        stage.addSubview(pill)
        return stage
    }
    write(lineCell("Can we move the design"), "pill-line-short.png")
    write(lineCell("Can we move the design review to Thursday afternoon and invite the whole platform team"), "pill-line-full.png")
    write(lineCell("The padding on the pricing card looks off. Take a screenshot", lit: true), "pill-line-command-lit.png")
    write(lineCell("The padding on the pricing card looks off. Take a screenshot, and match it to this page. Copy the link"), "pill-line-chips.png")
    write(lineCell("The padding on the pricing card looks off. Take a screenshot, and match it", page: .photo), "pill-line-photo.png")
    write(lineCell("and that's everything for the review", countdown: true), "pill-line-countdown.png")
    write(pillCell(.holdHint, command: false, vertical: false, page: .white), "pill-hold-hint.png")
    // Working: the take is over, the words are being finished.
    do {
        let c = lineCell("Can we move the design review to Thursday afternoon and invite the whole team")
        if let pill = c.subviews.first as? PillView { pill.state = .transcribing }
        write(c, "pill-line-working.png")
    }
    // The pill menu's two pages, on the photo page.
    for (page, name) in [(PillMenu.Page.home, "home"), (.pad, "pad")] {
        PillMenu.shared.snapshotLast = "Can we move the design review to Thursday afternoon and invite the whole platform team? I want to walk through the new pill."
        let v = PillMenu.shared.snapshotPage(page)
        let stage = GlassStage(frame: NSRect(origin: .zero, size: NSSize(width: v.frame.width + 60, height: v.frame.height + 60)))
        stage.page = .photo
        v.frame.origin = NSPoint(x: 30, y: 30)
        stage.glass = [(v.frame, PillMenu.radius)]
        stage.addSubview(v)
        write(stage, "pill-menu-\(name).png")
    }
    // The file picker's card, on the photo page.
    do {
        let size = AttachPicker.cardSize(for: 3)
        let stage = GlassStage(frame: NSRect(origin: .zero, size: NSSize(width: size.width + 60, height: size.height + 60)))
        stage.page = .photo
        let frame = NSRect(x: 30, y: 30, width: size.width, height: size.height)
        stage.glass = [(frame, 18)]
        let strip = AttachStripView(frame: frame)
        let pics = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let files = ((try? FileManager.default.contentsOfDirectory(at: pics, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }.prefix(3)
        strip.set(Array(files), title: "3 matches")
        stage.addSubview(strip)
        write(stage, "attach-picker.png")
    }
    // A long learned word is cut to the window's width, not the window to the word.
    write(pillCell(.learned, command: false, vertical: false, page: .white,
                   word: "Supercalifragilisticexpialidocious"), "pill-learned-long.png")
    // One board per page, three states to a row — the mockup's pill rows.
    for (page, name) in [(GlassStage.Page.white, "white"), (.code, "code"), (.photo, "photo")] {
        let board = NSView(frame: NSRect(x: 0, y: 0, width: 750, height: 252))
        for (i, p) in pillStates.enumerated() {
            let c = pillCell(p.state, command: p.command, vertical: false, page: page)
            c.frame.origin = NSPoint(x: CGFloat(i % 3) * 250, y: 252 - CGFloat(i / 3 + 1) * 84)
            board.addSubview(c)
        }
        write(board, "pill-board-\(name).png")
    }
    let upright = NSView(frame: NSRect(x: 0, y: 0, width: 810, height: 210))
    for (i, p) in pillStates.enumerated() {
        let c = pillCell(p.state, command: p.command, vertical: true, page: .white)
        c.frame.origin = NSPoint(x: CGFloat(i) * 90, y: 0)
        upright.addSubview(c)
    }
    write(upright, "pill-board-vertical.png")

    // The speech card: header only (it IS the pill's recording capsule),
    // then with words — settled white, the newest dimmer, the ember caret —
    // and its foot; at a top seat and a bottom one, at key-up, and as a
    // command.
    func speechCard(_ name: String, page: GlassStage.Page = .white, _ set: (SpeechCardView) -> Void) {
        let v = SpeechCardView(frame: NSRect(x: 20, y: 20, width: 460, height: 250))
        v.dock = .topCenter
        v.startedAt = Date().addingTimeInterval(-12.2)
        v.level = 0.7
        v.phase = 2.2
        set(v)
        let stage = GlassStage(frame: NSRect(x: 0, y: 0, width: 500, height: 290))
        stage.page = page
        let r = v.cardRect.offsetBy(dx: 20, dy: 20)
        stage.glass = [(r, v.text.isEmpty ? r.height / 2 : SpeechCardView.radius)]
        stage.addSubview(v)
        // The caret blinks on the wall clock — catch it lit.
        while Int(Date().timeIntervalSinceReferenceDate / 0.525) % 2 != 0 { usleep(20_000) }
        write(stage, "speechcard-\(name).png")
    }
    let said = "Here's what I'm seeing on the dashboard: the retry count doubled after the deploy, and the queue is"
    let unsettled = ("and the queue is" as NSString).length
    speechCard("compact") { _ in }
    speechCard("top") { v in
        v.text = said; v.soft = unsettled; v.chips = ["Pasting into Notes", "Casual tone"]
    }
    speechCard("top-photo", page: .photo) { v in
        v.text = said; v.soft = unsettled; v.chips = ["Pasting into Notes", "Casual tone"]
    }
    speechCard("bottom") { v in
        v.dock = .bottomCenter
        v.text = said; v.soft = unsettled; v.chips = ["Pasting into Notes", "Casual tone"]
    }
    speechCard("thinking") { v in
        v.text = said; v.soft = unsettled; v.chips = ["Pasting into Notes", "Casual tone"]
        v.mode = .thinking
    }
    speechCard("command") { v in
        v.command = true
        v.text = "make it shorter and friendlier"; v.soft = ("friendlier" as NSString).length
    }

    // The missed-paste card: waiting for a text box, then armed (the ember
    // ring, the hint naming the app), a one-line take just copied, and the
    // grow out of the pill as a strip of frames.
    func pasteCard(_ name: String, page: GlassStage.Page = .white,
                   words: String = "Send the revised deck to Priya before the Thursday review and flag the pricing slide",
                   extras: [PasteExtra] = [],
                   _ set: (PasteCardView) -> Void) {
        let v = PasteCardView(words: words, app: "Finder", extras: extras)
        v.life = 0.62
        set(v)
        v.entrance(at: .infinity)
        let stage = GlassStage(frame: NSRect(x: 0, y: 0, width: v.frame.width + 60, height: v.frame.height + 60))
        stage.page = page
        v.setFrameOrigin(NSPoint(x: 30, y: 30))
        stage.glass = [(v.frame, PasteCardView.radius)]
        stage.addSubview(v)
        write(stage, "pastecard-\(name).png")
    }
    pasteCard("waiting") { _ in }
    pasteCard("extras", page: .photo, words: "The padding on the pricing card looks off, match it to the header",
              extras: [.screenshots(1), .file("IMG_2588.HEIC")]) { v in v.target = "Notes"; v.armed = true }
    pasteCard("extras-only", page: .photo, words: "", extras: [.screenshots(2)]) { _ in }
    pasteCard("armed") { v in v.target = "Notes"; v.armed = true; v.life = 0.4 }
    pasteCard("armed-photo", page: .photo) { v in v.target = "Notes"; v.armed = true; v.life = 0.4 }
    pasteCard("armed-code", page: .code) { v in v.target = "Visual Studio Code"; v.armed = true; v.life = 0.4 }
    pasteCard("copied", words: "Call the dentist tomorrow") { v in v.copied = true; v.life = 0.85 }
    pasteCard("long-names") { v in
        v.missedApp = "System Information Utility Pro"; v.target = "Microsoft Outlook for Mac"; v.armed = true
    }
    do {
        // Frames of the opening: the glass springing from the thinking
        // capsule at a bottom seat, the rows following it in.
        let times: [Double] = [0, 0.05, 0.1, 0.16, 0.22, 0.3, 0.42, 0.7]
        let cellW: CGFloat = 300, cellH: CGFloat = 170
        let strip = NSView(frame: NSRect(x: 0, y: 0, width: cellW * CGFloat(times.count), height: cellH))
        for (i, t) in times.enumerated() {
            let v = PasteCardView(words: "Send the revised deck to Priya before the Thursday review", app: "Finder")
            let stage = GlassStage(frame: NSRect(x: CGFloat(i) * cellW, y: 0, width: cellW, height: cellH))
            let card = NSRect(x: (cellW - v.frame.width) / 2, y: 26, width: v.frame.width, height: v.frame.height)
            let pill = NSRect(x: (cellW - 124) / 2, y: 26, width: 124, height: 32)
            let p = PasteCard.spring(t, stiffness: 230, damping: 21)
            let g = PasteCard.lerp(pill, card, p)
            stage.glass = [(g, min(PasteCard.lerp(16, PasteCardView.radius, min(p, 1)), min(g.width, g.height) / 2))]
            v.setFrameOrigin(card.origin)
            v.entrance(at: t)
            // The capture ignores a view's alpha, so a row not in yet is left out.
            for row in v.subviews where row.alphaValue < 0.5 { row.isHidden = true }
            stage.addSubview(v)
            strip.addSubview(stage)
        }
        write(strip, "pastecard-grow.png")
    }

    // The agent card mid-episode: the voice's line in the sans, your reply in
    // the serif, and the foot while the voice speaks (white bars), while the
    // mic listens (ember) and while the reply goes out (flat). The panel is
    // a real window, kept transparent on screen: only the capture sees it.
    let agent = AgentPanel.shared
    agent.concealed(true)
    func agentShot(_ name: String) {
        guard let content = agent.snapshotView else { return }
        let frost = content.subviews.first { $0 is NSVisualEffectView }
        frost?.isHidden = true
        content.layoutSubtreeIfNeeded()
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        frost?.isHidden = false
        let image = NSImage(size: content.bounds.size)
        image.addRepresentation(rep)
        let stage = GlassStage(frame: NSRect(x: 0, y: 0, width: content.bounds.width + 60,
                                             height: content.bounds.height + 60))
        let at = NSRect(x: 30, y: 30, width: content.bounds.width, height: content.bounds.height)
        stage.glass = [(at, 16)]
        let shot = NSImageView(frame: at)
        shot.image = image
        shot.imageScaling = .scaleNone
        stage.addSubview(shot)
        write(stage, "agentcard-\(name).png")
    }
    agent.begin(folder: "SayControl", title: "Pill restyle", agent: .claude,
                saying: "The pill restyle is done. Want me to open the diff?")
    agent.revealAll()
    agent.heard("Yes, open it and tell me what changed")
    agent.say("Opening it now.")
    agent.revealAll()
    agent.tickFoot(level: 0.7, phase: 2.2)
    agentShot("speaking")
    agent.listening(true)
    agent.forming("and after that run the")
    agent.tickFoot(level: 0.7, phase: 2.2)
    agentShot("listening")
    agent.footStatus("Sending…")
    agentShot("sending")
    agent.hideNow()
    agent.concealed(false)

    // The sun menu, fanned as it would be from each kind of seat; the
    // bottom variant hovers a button so the label capsule shows. Once over
    // a grey desktop, once over a white page.
    for (angle, spread, name) in [(CGFloat(90), CGFloat(140), "bottom"),
                                  (CGFloat(55), CGFloat(120), "corner"),
                                  (CGFloat(0), CGFloat(140), "side")] {
        for white in [false, true] {
            let menu = SunMenuView(frame: NSRect(origin: .zero, size: SunMenu.panelSize))
            menu.wantsLayer = true
            menu.layer?.backgroundColor = white ? NSColor.white.cgColor
                : NSColor(srgbRed: 0.35, green: 0.38, blue: 0.42, alpha: 1).cgColor
            let center = NSPoint(x: SunMenu.panelSize.width / 2, y: SunMenu.panelSize.height / 2)
            let capsule = name == "side" ? NSSize(width: Pill.idleSize.height, height: Pill.idleSize.width) : Pill.idleSize
            menu.layout(sun: center, capsule: capsule, angleDegrees: angle, spreadDegrees: spread)
            if name == "bottom" {
                menu.updateHover(at: NSPoint(x: center.x, y: center.y + SunMenu.radius))
            }
            write(menu, white ? "sunmenu-\(name)-onwhite.png" : "sunmenu-\(name).png")
        }
    }

    // The dock picker's six ghost slots on a mini stand-in screen.
    let screen = NSRect(x: 0, y: 0, width: 720, height: 440)
    let picker = DockPickerView(frame: screen)
    picker.wantsLayer = true
    picker.layer?.backgroundColor = NSColor(srgbRed: 0.35, green: 0.38, blue: 0.42, alpha: 1).cgColor
    picker.slots = PillDock.allCases.map { ($0, $0.aligned(size: DockPicker.slotBox(for: $0), in: screen.insetBy(dx: 4, dy: 4))) }
    picker.current = .bottomCenter
    picker.highlighted = .bottomRight
    picker.showHint = true
    write(picker, "dockpicker.png")
    return true
}

private var shotLogURL: URL?

/// Dev tool: `SayCtrl --windowshot <dir>` photographs the real window — sidebar,
/// traffic lights, shadow and all — one PNG per pane, then exits. Goes through
/// /usr/sbin/screencapture, so it borrows SayCtrl's own Screen Recording grant
/// instead of asking for the terminal's.
func runWindowShotsIfRequested() -> Bool {
    guard let i = CommandLine.arguments.firstIndex(of: "--windowshot"),
          CommandLine.arguments.count > i + 1 else { return false }
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    // AppKit swallows an exception thrown out of applicationDidFinishLaunching,
    // which would leave this tool sitting there half-done with no clue why.
    shotLogURL = dir.appendingPathComponent("frames.txt")
    NSSetUncaughtExceptionHandler { e in
        let line = "‼️ \(e.name.rawValue): \(e.reason ?? "")\n"
            + e.callStackSymbols.prefix(12).joined(separator: "\n") + "\n"
        if let url = shotLogURL, let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        }
    }

    SettingsUI.shared.present(selecting: "overview")
    guard let window = NSApp.windows.first(where: { $0.title == "SayControl" }) else { return true }
    let id = window.windowNumber

    func note(_ line: String) {
        let log = dir.appendingPathComponent("frames.txt")
        let data = (line + "\n").data(using: .utf8)!
        if let h = try? FileHandle(forWritingTo: log) { h.seekToEndOfFile(); h.write(data); try? h.close() }
        else { try? (line + "\n").write(to: log, atomically: true, encoding: .utf8) }
    }
    func settle(_ seconds: TimeInterval = 0.35) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        window.layoutIfNeeded()
        window.displayIfNeeded()
    }
    func shoot(_ name: String) {
        settle()
        let note = "\(name): \(Int(window.frame.width))x\(Int(window.frame.height))\n"
        let log = dir.appendingPathComponent("frames.txt")
        if let h = try? FileHandle(forWritingTo: log) { h.seekToEndOfFile(); h.write(note.data(using: .utf8)!); try? h.close() }
        else { try? note.write(to: log, atomically: true, encoding: .utf8) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l\(id)", dir.appendingPathComponent(name + ".png").path]
        try? p.run()
        p.waitUntilExit()
    }

    for mode in ["light", "dark"] {
        NSApp.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
        for pane in ["overview", "dictionary", "insights", "phrases", "tones",
                     "agents", "agent-claude", "agent-codex", "agent-cursor", "agent-opencode", "help"] {
            SettingsUI.shared.select(pane)
            shoot("win-\(pane)-\(mode)")
        }
        SettingsUI.shared.select("overview")
        SettingsUI.shared.showCommands()
        shoot("win-howto-\(mode)")
        SettingsUI.shared.dismissOverlay()
        // Every Settings section, in the sheet, over the Overview. A real
        // screen capture, so this is also the only place the dimmed app
        // behind the sheet shows up properly.
        SettingsUI.shared.select("overview")
        for tab in SettingsSheet.visibleTabKeys {
            SettingsUI.shared.showSettings(tab: tab)
            shoot("set-\(tab)-\(mode)")
        }
        SettingsUI.shared.dismissOverlay()

        SettingsUI.shared.select("overview")
        SettingsUI.shared.showAbout()
        shoot("win-about-\(mode)")
        SettingsUI.shared.dismissOverlay()
        SettingsUI.shared.toggleAccountPopover()
        shoot("win-account-\(mode)")
        SettingsUI.shared.dismissOverlay()
    }
    return true
}

/// Dev tool: `SayCtrl --onboardingshot <dir>` draws the first-run window in
/// each of its states, light and dark, then exits: the welcome signed out,
/// the welcome signed in, and the switches as this Mac has them.
func runOnboardingShotsIfRequested() -> Bool {
    guard let i = CommandLine.arguments.firstIndex(of: "--onboardingshot"),
          CommandLine.arguments.count > i + 1 else { return false }
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    OnboardingWindow.shared.present(at: 0)
    guard let window = NSApp.windows.first(where: { $0.title == "Welcome to SayControl" }),
          let content = window.contentView else { return true }

    // Drawn off-screen, like --snapshot: no Screen Recording grant needed, so
    // it runs from any shell. No traffic lights or window shadow, then.
    func shoot(_ name: String, settle: TimeInterval = 0.8) {
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        window.layoutIfNeeded()
        window.displayIfNeeded()
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: dir.appendingPathComponent(name + ".png"))
    }

    let wasStep = Onboarding.savedStep
    defer { Onboarding.savedStep = wasStep }   // the tool must not move a real run along
    // Both account states, drawn without touching the real account.
    defer { Account.preview = nil }
    for mode in ["light", "dark"] {
        NSApp.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
        Account.preview = false
        OnboardingWindow.shared.present(at: 0)
        shoot("onboard-1-welcome-\(mode)")
        for (step, name) in [(EmailSignInForm.ShotStep.signUp, "1b-sign-up"), (.logIn, "1c-password"),
                             (.code, "1d-reset-code"), (.newPassword, "1e-new-password")] {
            OnboardingWindow.shared.showFormForShot(step)
            shoot("onboard-\(name)-\(mode)")
        }
        OnboardingWindow.shared.showFormForShot(nil)
        Account.preview = true
        OnboardingWindow.shared.present(at: 0)
        shoot("onboard-2-signed-in-\(mode)")
        OnboardingWindow.shared.showSwitchesForShot()
        shoot("onboard-3-switches-\(mode)", settle: 1.5)
    }
    return true
}

/// Dev tool: `SayCtrl --modelsshot <dir>` draws Settings › Models in each of
/// its states, light and dark: the window as it composites (models-<state>-
/// <mode>.png) and the whole page, top to bottom (page-<state>-<mode>.png).
/// The states are set in .env, which is put back as it was before exiting.
func runModelsShotsIfRequested() -> Bool {
    guard let i = CommandLine.arguments.firstIndex(of: "--modelsshot"),
          CommandLine.arguments.count > i + 1 else { return false }
    let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let envURL = Config.shared.dir.appendingPathComponent(".env")
    let saved = try? Data(contentsOf: envURL)
    defer { if let saved = saved { try? saved.write(to: envURL) } }
    Motion.still = true

    SettingsUI.shared.present(selecting: "overview")
    guard let window = NSApp.windows.first(where: { $0.title == "SayControl" }) else { return true }
    func settle(_ seconds: TimeInterval = 0.4) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        window.layoutIfNeeded()
        window.displayIfNeeded()
    }
    func page(in view: NSView) -> ModelsPage? {
        if let p = view as? ModelsPage { return p }
        for sub in view.subviews { if let p = page(in: sub) { return p } }
        return nil
    }
    let states: [(String, () -> Void)] = [
        ("mac", { Config.shared.setTranscriptionSource(.mac) }),
        ("mac-live-off", { Config.shared.setTranscriptionSource(.mac); Config.shared.setFlag("LOCAL_LIVE", false) }),
        ("key", { Config.shared.setTranscriptionSource(.key) }),
        ("cloud", { Config.shared.setTranscriptionSource(.cloud); Config.shared.setFlag("POLISH_CLOUD", true) }),
        ("cloud-polish-key", { Config.shared.setTranscriptionSource(.cloud); Config.shared.setFlag("POLISH_CLOUD", false) }),
        ("polish-claude", { Config.shared.setFlag("POLISH_CLOUD", false); Config.shared.set("POLISH_PROVIDER", "anthropic") }),
        ("polish-off", { Config.shared.setFlag("REFINE", false) }),
    ]
    for mode in ["light", "dark"] {
        NSApp.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
        for (name, setUp) in states where mode == "light" || name == "mac" || name == "key" {
            if let saved = saved { try? saved.write(to: envURL) }
            setUp()
            SettingsUI.shared.dismissOverlay()
            settle(0.2)
            SettingsUI.shared.showSettings(tab: "model")
            settle(1.2)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l\(window.windowNumber)", dir.appendingPathComponent("models-\(name)-\(mode).png").path]
            try? p.run()
            p.waitUntilExit()
            guard let content = window.contentView, let models = page(in: content) else { continue }
            models.layoutSubtreeIfNeeded()
            let bounds = models.bounds
            guard bounds.width > 1, bounds.height > 1,
                  let rep = models.bitmapImageRepForCachingDisplay(in: bounds) else { continue }
            models.effectiveAppearance.performAsCurrentDrawingAppearance {
                models.cacheDisplay(in: bounds, to: rep)
            }
            // The page has no fill of its own; the sheet's paper goes behind.
            let image = NSImage(size: bounds.size)
            image.lockFocus()
            models.effectiveAppearance.performAsCurrentDrawingAppearance {
                Theme.paper.setFill()
                bounds.fill()
            }
            rep.draw(in: bounds)
            image.unlockFocus()
            if let tiff = image.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff) {
                try? bmp.representation(using: .png, properties: [:])?
                    .write(to: dir.appendingPathComponent("page-\(name)-\(mode).png"))
            }
        }
    }
    SettingsUI.shared.dismissOverlay()
    return true
}

/// Dev tool: `SayCtrl --localbench <a.wav>…` runs each installed model that
/// streams natively the way a live take does — opened, fed 0.2 s at a time
/// as fast as it will go, finished — and prints the text, the pace and the
/// key-up time; then times every installed model that can run live the way
/// LocalSpeed does, and records it. LOCAL_MODEL is put back afterwards.
func runLocalBenchIfRequested() -> Bool {
    guard let i = CommandLine.arguments.firstIndex(of: "--localbench") else { return false }
    let files = CommandLine.arguments[(i + 1)...].filter { $0.hasSuffix(".wav") }
    let envURL = Config.shared.dir.appendingPathComponent(".env")
    let saved = try? Data(contentsOf: envURL)
    defer { if let saved = saved { try? saved.write(to: envURL) } }
    func say(_ line: String) { print(line); fflush(stdout) }

    var done = false
    Task {
        let engine = LocalEngine.shared
        for entry in LocalEngine.catalog where engine.isInstalled(entry) && entry.family.streams {
            Config.shared.set(Provider.local.modelVar, entry.id)
            // Loads it (and primes a streamed one), so there is something to time.
            _ = try? await engine.transcribe(samples: [Float](repeating: 0, count: 8000))
            if entry.family.streamsNatively {
                for path in files {
                    guard let samples = try? LocalEngine.samples(from: URL(fileURLWithPath: path)) else { continue }
                    do {
                        try await engine.streamStart()
                        var spent: TimeInterval = 0
                        var start = 0
                        while start < samples.count {
                            let piece = Array(samples[start..<min(start + 3200, samples.count)])
                            let t0 = Date()
                            _ = try await engine.streamFeed(piece)
                            spent += Date().timeIntervalSince(t0)
                            start += 3200
                        }
                        let t0 = Date()
                        let text = try await engine.streamFinish([], all: samples)
                        let keyUp = Date().timeIntervalSince(t0)
                        let seconds = Double(samples.count) / 16000
                        say(String(format: "%@ %@ %.1fs: %.2f× real time, key-up %.0f ms\n  %@", entry.id,
                                   (path as NSString).lastPathComponent, seconds, spent / seconds, keyUp * 1000, text))
                    } catch {
                        say("\(entry.id) \((path as NSString).lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }
            if let seconds = await engine.timeLoaded() {
                let native = entry.family.streamsNatively
                let live = seconds <= (native ? LocalSpeed.nativeBudget : LocalSpeed.replayBudget)
                say(String(format: "%@ timed: %.2f%@ → %@", entry.id, seconds, native ? "× real time" : " s for 10 s",
                           live ? "live" : "writes when you let go"))
            }
        }
        done = true
    }
    while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    return true
}

/// Dev tool: `SayCtrl --polishcheck` reads the model list of every polish
/// provider with a key saved, then sends Try it's sentence through each one
/// on its own route, the way Settings › Models would: one short request per
/// provider. Prints what came back and how long it took; .env is put back.
func runPolishCheckIfRequested() -> Bool {
    guard CommandLine.arguments.contains("--polishcheck") else { return false }
    let envURL = Config.shared.dir.appendingPathComponent(".env")
    let saved = try? Data(contentsOf: envURL)
    defer { if let saved = saved { try? saved.write(to: envURL) } }
    func say(_ line: String) { print(line); fflush(stdout) }
    func wait(_ done: () -> Bool) { while !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }

    Config.shared.setFlag("POLISH_CLOUD", false)
    Config.shared.setFlag("REFINE", true)
    for p in PolishProvider.allCases {
        guard let key = Config.shared.polishKey(p) else { say("\(p.title): no key"); continue }
        var models: [String]?
        var finished = false
        PolishModels.fetch(p, key: key) { result in
            switch result {
            case .success(let ids): models = ids
            case .failure(let e): say("\(p.title): models refused — \(e.localizedDescription)")
            }
            finished = true
        }
        wait { finished }
        guard let ids = models else { continue }
        let model = ids.contains(p.defaultModel) ? p.defaultModel : ids.first ?? p.defaultModel
        say("\(p.title): \(ids.count) chat models, fast first: \(ids.prefix(5).joined(separator: ", "))")
        Config.shared.set("POLISH_PROVIDER", p.rawValue)
        Config.shared.set(p.modelVar, model)
        finished = false
        Refiner.shared.tryPolish(Refiner.testSample) { result, ms in
            switch result {
            case .success(let text): say("  \(model), \(ms) ms: \(text)")
            case .failure(let e): say("  \(model), \(ms) ms: ✕ \(e.localizedDescription)")
            }
            finished = true
        }
        wait { finished }
    }
    return true
}
