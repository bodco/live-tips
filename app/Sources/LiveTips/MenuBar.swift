import AppKit
import AVFoundation
import LiveTipsCore
import SwiftUI
import Combine

/// Menu bar item and the main app delegate: live status, spending against limits, Start call,
/// tips window, settings. The Dock icon is on by default so the app is visible even when the
/// menu bar is full.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem?
    var tips: PrompterController?
    var timer: Timer?
    let statusLines = [NSMenuItem(), NSMenuItem(), NSMenuItem(), NSMenuItem()]
    var micItem = NSMenuItem()
    var startItem = NSMenuItem()
    var endItem = NSMenuItem()
    var pauseItem = NSMenuItem()
    var helpItem = NSMenuItem()
    var tipsItem = NSMenuItem()
    var notionItem = NSMenuItem()
    var lastStatus = EngineStatus()

    var config: AppConfig { AppConfig.load(from: AppPaths.config) }
    var appRoot: String { config.effectiveAppRoot(appSupport: AppPaths.support.path) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        NSApp.setActivationPolicy(config.showInDock ? .regular : .accessory)
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        it.button?.image = NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Live Tips")
        it.button?.toolTip = "Live Tips"
        let menu = NSMenu()
        menu.delegate = self
        // The main action first; the status lines below it (review P2).
        startItem = add(menu, "Start call…", #selector(startCall), "n")
        tipsItem = add(menu, "Open tips window", #selector(showTips), "t")
        pauseItem = add(menu, "Pause or resume tips", #selector(togglePause), "p")
        pauseItem.keyEquivalentModifierMask = [.control, .option]      // shown in the menu: the global shortcut
        helpItem = add(menu, "HELP NOW", #selector(helpNow), "h")
        helpItem.keyEquivalentModifierMask = [.control, .option]
        endItem = add(menu, "End call", #selector(endCall), "")
        menu.addItem(.separator())
        for l in statusLines { l.isEnabled = false; menu.addItem(l) }
        menu.addItem(.separator())
        notionItem = add(menu, "Send last call to Notion", #selector(sendToNotion), "")
        micItem = add(menu, "Allow microphone…", #selector(requestMic), "")
        menu.addItem(.separator())
        add(menu, "Settings…", #selector(openSettings), ",")
        add(menu, "Setup…", #selector(openSetup), "")
        add(menu, "About Live Tips", #selector(openAbout), "")
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Live Tips", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        it.menu = menu
        item = it
        refresh()
        MainActor.assumeIsolated { LocalAIService.shared.apply() }
        NotionMirrorService.shared.startSchedule()
        HotKeys.shared.install(help: { [weak self] in self?.helpNow() }, pause: { [weak self] in self?.togglePause() })
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        if !CallEngine.shared.problems().isEmpty { MainActor.assumeIsolated { SetupWindow.show() } }
        if !UserDefaults.standard.bool(forKey: "onboarded") {
            UserDefaults.standard.set(true, forKey: "onboarded")
            openSettings()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { if lastStatus.state == "recording" { showTips() } else { startCall() } }   // Dock icon
        return true
    }

    @discardableResult
    func add(_ menu: NSMenu, _ title: String, _ sel: Selector, _ key: String) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        m.target = self
        menu.addItem(m)
        return m
    }

    /// Edit menu so ⌘C / ⌘V / ⌘A work in text fields (accessory apps have no menu by default).
    func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Live Tips", action: #selector(openAbout), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Live Tips", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        let winItem = NSMenuItem()
        main.addItem(winItem)
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = win
        NSApp.mainMenu = main
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    func refresh() {
        let cfg = config
        IndexService.shared.configure(projects: ProjectRegistry.load(from: AppPaths.projects).projects, appRoot: appRoot,
                                      python: cfg.engine.python, enabled: cfg.localAI.enabled)
        let st = EngineStatus.load(path: (appRoot as NSString).appendingPathComponent("state/status.json"))
        let month = SpendLedger.monthSpent()
        let recording = ["recording", "loading_model", "standby"].contains(st.state)
        lastStatus = st
        startItem.isHidden = recording
        endItem.isHidden = !recording
        pauseItem.isHidden = st.state != "recording"
        helpItem.isHidden = st.state != "recording"
        tipsItem.title = recording ? "Open tips window" : "Preview tips window"
        notionItem.isHidden = recording || CallEngine.shared.lastFile == nil
        notionItem.toolTip = CallEngine.shared.notionResult
        statusLines[0].title = st.state == "standby" ? "○ Waiting for the call" + (st.project.map { ": \($0)" } ?? "")
            : recording ? "● Recording" + (st.project.map { ": \($0)" } ?? "") : "Not recording"
        statusLines[1].title = String(format: "Lines %d · tips %d · this call $%.2f of $%.0f", st.lines, st.tips, st.callSpentUSD, cfg.budget.callHardUSD)
        statusLines[1].isHidden = !recording
        statusLines[2].isHidden = true
        statusLines[3].title = String(format: "This month: $%.2f of $%.0f", month, cfg.budget.monthlyHardUSD)
        micItem.isHidden = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        item?.button?.image = NSImage(systemSymbolName: recording ? "record.circle.fill" : "text.bubble", accessibilityDescription: "Live Tips")
        if st.callSpentUSD >= cfg.budget.callSoftUSD || month >= cfg.budget.monthlyHardUSD * 0.9 {
            item?.button?.contentTintColor = .systemOrange
        } else {
            item?.button?.contentTintColor = recording ? .systemRed : nil
        }
    }

    @objc func startCall() { MainActor.assumeIsolated { StartCallWindow.show(delegate: self) } }
    @objc func sendToNotion() {
        guard let f = CallEngine.shared.lastFile, !CallEngine.shared.isRunning else { return }
        CallEngine.shared.writeToNotion(file: f)
    }
    @objc func openSetup() { MainActor.assumeIsolated { SetupWindow.show() } }
    @objc func openSettings() { MainActor.assumeIsolated { SettingsWindow.show() } }
    @objc func openAbout() { MainActor.assumeIsolated { SettingsWindow.show(tab: "about") } }
    @objc func openSettingsTab() { MainActor.assumeIsolated { SettingsWindow.show() } }

    /// Same as the buttons in the tips window (the window owns the pause state and HELP NOW).
    @objc func togglePause() { pushTips("document.getElementById('pause').click()") }
    @objc func helpNow() { pushTips("document.getElementById('sos').click()") }
    func pushTips(_ js: String) {
        guard lastStatus.state == "recording" else { return }
        if tips == nil { showTips() }
        MainActor.assumeIsolated { tips?.push(js) }
    }

    @objc func endCall() {
        let a = NSAlert()
        a.messageText = "End the call?"
        a.informativeText = "Recording stops; the transcript and tips stay in the project folder."
        a.addButton(withTitle: "End call")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { CallEngine.shared.stop() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { LocalAIService.shared.stop() }
        tips?.setSplit(false, animate: false)          // keep the saved tips window at its normal width
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard CallEngine.shared.isRunning else { return .terminateNow }
        let a = NSAlert()
        a.messageText = "A call is being recorded"
        a.informativeText = "Quitting stops the recording."
        a.addButton(withTitle: "Stop and quit")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { CallEngine.shared.stop(); return .terminateNow }
        return .terminateCancel
    }
    @objc func requestMic() { AVCaptureDevice.requestAccess(for: .audio) { _ in } }

    @objc func showTips() {
        if lastStatus.state == "recording", let t = lastStatus.tipsFile {
            openTips(for: CallFiles(tips: t, inbox: lastStatus.inboxFile ?? "", status: CallEngine.shared.statusPath,
                                    control: (CallEngine.shared.appRoot as NSString).appendingPathComponent("control")))
            return
        }
        if tips == nil {
            MainActor.assumeIsolated {
                let c = PrompterController(args: prompterArgs(["LiveTips", "--prompter-demo"]))
                c.show()
                tips = c
            }
        }
    }

    func openTips(for call: CallFiles) {
        MainActor.assumeIsolated {
            var a = PrompterArgs()
            a.tips = call.tips
            a.inbox = call.inbox
            a.status = call.status
            a.control = call.control
            a.html = Bundle.main.resourceURL?.appendingPathComponent("prompter.html").path ?? ""
            a.title = lastStatus.project.map { "Live Tips: \($0)" } ?? "Live Tips"
            let c = PrompterController(args: a)
            c.show()
            tips = c
        }
    }
}

struct CallFiles {
    var tips: String
    var inbox: String
    var status: String
    var control: String
}

// MARK: - Start call

@MainActor
final class StartCallModel: ObservableObject {
    @Published var target = ""          // "project:<slug>" | "workspace:<name>"
    @Published var title = ""
    @Published var audience = "auto"
    @Published var callType = "auto"
    @Published var language = "uk+en"
    @Published var note = ""
    @Published var context = ""
    @Published var prep: PrepInfo?
    /// "default" | "builtin" | "uid:<UID>" (same values as the recorder's mic_device and the window's Mic menu).
    @Published var micDevice = UserDefaults.standard.string(forKey: "micDevice") ?? "default" {
        didSet { UserDefaults.standard.set(micDevice, forKey: "micDevice") }
    }
    @Published var micInputs: [MicInput] = []
    /// Open the window now and start recording when the call begins (the other side speaks, or Start).
    @Published var standby = UserDefaults.standard.object(forKey: "standby") as? Bool ?? true {
        didSet { UserDefaults.standard.set(standby, forKey: "standby") }
    }
    struct MicInput: Decodable, Hashable { var uid: String; var name: String; var builtin: Bool; var `default`: Bool }

    /// Inputs the Mac sees now, from the recorder's audiocap (--list-inputs). Empty with an older audiocap.
    func loadMicInputs() {
        let appRoot = config.effectiveAppRoot(appSupport: AppPaths.support.path)
        let bin = (appRoot as NSString).appendingPathComponent("bin/audiocap")
        guard FileManager.default.isExecutableFile(atPath: bin) else { return }
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["--list-inputs"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let list = (try? JSONDecoder().decode([MicInput].self, from: data)) ?? []
            DispatchQueue.main.async { self.micInputs = list }
        }
    }
    var defaultInputName: String? { micInputs.first { $0.default }?.name }
    let registry = ProjectRegistry.load(from: AppPaths.projects)
    let config = AppConfig.load(from: AppPaths.config)

    init() {
        target = registry.lastUsed
        applyProjectDefaults()
    }

    /// `matches` = the prep was made for this call's title; only such a prep is adopted on start.
    struct PrepInfo { var heading: String; var made: Date; var file: String; var matches: Bool }

    /// Same as `slugify` in live-transcriber `lt` and transcriber.py.
    static func slugify(_ s: String) -> String {
        let cleaned = s.replacingOccurrences(of: "[^\\p{L}\\p{M}\\p{N}_\\s-]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let slug = cleaned.replacingOccurrences(of: "[\\s_]+", with: "-", options: .regularExpression)
        return slug.isEmpty ? "meeting" : String(slug.prefix(60))
    }

    /// Same as `title_match` in `lt`: equal, or one contains the other (4+ characters), hyphens ignored.
    static func titleMatch(_ a: String, _ b: String) -> Bool {
        // Spaces and hyphens do not count: "Standup" = "stand-up", and a project prefix still matches.
        let a = slugify(a).replacingOccurrences(of: "-", with: ""), b = slugify(b).replacingOccurrences(of: "-", with: "")
        return a == b || (min(a.count, b.count) >= 4 && (a.contains(b) || b.contains(a)))
    }

    /// The title the call will get (the same fallback as `requestJSON`).
    var effectiveTitle: String { title.isEmpty ? (project?.name ?? workspace?.name ?? "Meeting") : title }

    /// A prep made in Cowork (prep-*.brief.md in <project folder>/live, younger than 3 h). The recorder
    /// adopts only a prep whose name matches the call title (`lt prep-check --adopt-prep`). The newest
    /// matching prep is shown; when none matches, the newest prep of another call is shown as not used.
    func scanPrep() {
        guard let root = root else { prep = nil; return }
        let live = (root as NSString).appendingPathComponent("live")
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: live) else { prep = nil; return }
        let callTitle = effectiveTitle
        var best: PrepInfo?
        for n in names where n.hasPrefix("prep-") && n.hasSuffix(".brief.md") {
            let path = (live as NSString).appendingPathComponent(n)
            guard let m = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  Date().timeIntervalSince(m) < 3 * 3600 else { continue }
            let core = String(n.dropFirst("prep-".count).dropLast(".brief.md".count))
                .replacingOccurrences(of: "^(\\d{4}-\\d\\d-\\d\\d(-\\d{4})?-)+", with: "", options: .regularExpression)
            let matches = Self.titleMatch(core, callTitle)
            if let b = best, b.matches && !matches || (b.matches == matches && b.made > m) { continue }
            let first = (try? String(contentsOfFile: path, encoding: .utf8))?.split(separator: "\n").first.map(String.init) ?? n
            let heading = first.replacingOccurrences(of: "# Live Brief (prep):", with: "").replacingOccurrences(of: "#", with: "")
                .trimmingCharacters(in: .whitespaces)
            best = PrepInfo(heading: heading.isEmpty ? n : heading, made: m, file: n, matches: matches)
        }
        prep = best
    }

    var targetName: String { project?.name ?? workspace?.name ?? "the project" }

    /// Phrase to paste into Cowork to make a prep for this call.
    var prepPhrase: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let t = title.isEmpty ? "the call" : "\"\(title)\""
        return "Prepare live tips for \(t) at \(f.string(from: Date().addingTimeInterval(15 * 60))), project \(targetName). Use this title exactly for the prep files" +
            (context.isEmpty ? "" : ". Context: \(context)")
    }

    var project: Project? { registry.projects.first { "project:" + $0.slug == target } }
    var workspace: Workspace? { registry.workspaces.first { "workspace:" + $0.name == target } }
    var root: String? { project?.root ?? workspace?.root }

    /// Two seconds to see the right project is chosen: people from its config, Claude on or off,
    /// the last call with it and how fresh the Notion mirror is.
    var details: String {
        var parts: [String] = []
        if let p = project {
            let team = p.people.filter { $0.side == "team" }.count, client = p.people.filter { $0.side == "client" }.count
            parts.append("Team \(team) · client \(client)")
            parts.append(p.apiAllowed ? "Claude tips on" : "local only (Claude off for this project)")
        } else if let w = workspace {
            parts.append("Projects: " + w.projects.joined(separator: ", "))
        } else { return "" }
        let rel = RelativeDateTimeFormatter()
        if let s = registry.lastUsedAt[target], let d = ISO8601DateFormatter().date(from: s) {
            parts.append("last call " + rel.localizedString(for: d, relativeTo: Date()))
        } else {
            parts.append("first call here")
        }
        let cfg = AppConfig.load(from: AppPaths.config)
        if !cfg.workRoot.isEmpty {
            let st = MirrorStatus.load(workRoot: cfg.workRoot)
            switch st.health() {
            case "ok", "stale": parts.append("Notion mirror " + rel.localizedString(for: st.lastRunUTC ?? Date(), relativeTo: Date()) + (st.health() == "stale" ? " (stale)" : ""))
            case "failed": parts.append("Notion mirror: last run failed")
            default: parts.append("no Notion mirror")
            }
        }
        return parts.joined(separator: " · ")
    }

    func applyProjectDefaults() {
        if let p = project, p.clientLanguage.lowercased().hasPrefix("english"), language == "uk+en" { language = "en" }
    }

    func requestJSON() -> [String: Any]? {
        guard let root = root, !root.isEmpty else { note = "This project has no folder in its config."; return nil }
        let langs: (String, [String]) = language == "en" ? ("en", ["en"]) : language == "en+es" ? ("en", ["en", "es"]) : ("uk", ["uk", "en"])
        var reg = registry
        reg.lastUsed = target
        reg.lastUsedAt[target] = ISO8601DateFormatter().string(from: Date())
        try? reg.save(to: AppPaths.projects)
        return ["project_dir": root, "title": title.isEmpty ? (project?.name ?? workspace?.name ?? "Meeting") : title,
                "slug": project?.slug ?? workspace?.name.lowercased() ?? "", "call_type": callType, "audience": audience,
                "me_lang": langs.0, "langs": langs.1, "me_langs": langs.0 == "uk" ? ["uk", "en"] : [langs.0],
                "context": context.trimmingCharacters(in: .whitespacesAndNewlines), "mic_device": micDevice, "standby": standby,
                "project_config": project?.config ?? "", "people": people]
    }

    /// Full names of the team and the client from the project config (all projects of a workspace):
    /// the "Who is speaking?" card offers them, as in the skill. Names are never set by themselves.
    var people: [String] {
        let ps = project.map { [$0] } ?? registry.projects.filter { workspace?.projects.contains($0.slug) ?? false }
        var seen = Set<String>()
        return ps.flatMap { $0.people.map(\.name) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}

struct StartCallView: View {
    @ObservedObject var model: StartCallModel
    var onStart: () -> Void
    var onCancel: () -> Void
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                Picker("Project", selection: $model.target) {
                    Text("Choose…").tag("")
                    if !model.registry.workspaces.isEmpty {
                        Section("Workspaces") {
                            ForEach(model.registry.workspaces, id: \.name) { w in
                                Label(w.name, systemImage: "square.stack.3d.up").tag("workspace:" + w.name)
                            }
                        }
                    }
                    Section("Projects") {
                        ForEach(model.registry.projects.filter { $0.status != "archived" }, id: \.slug) { p in
                            Label(p.name, systemImage: "folder").tag("project:" + p.slug)
                        }
                    }
                }
                .help("Recordings and notes go to this folder. A workspace is for general calls about several projects.")
                .onChange(of: model.target) { model.applyProjectDefaults(); model.scanPrep(); copied = false }
                if let r = model.root {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Text(model.details).font(.caption).foregroundStyle(.secondary)
                    }
                }
                TextField("Title", text: $model.title, prompt: Text("e.g. Weekly sync with the client"))
                    .onChange(of: model.title) { model.scanPrep(); copied = false }
            }
            Section {
                ZStack(alignment: .topLeading) {
                    if model.context.isEmpty {
                        Text("What the call is about and where to look: goal, open questions, people, the docs or tickets that matter (for example \"pricing for phase 2, see the estimate and last week's notes\"). Claude reads it with the project's current state and searches the project files for it before the call starts.")
                            .font(.callout).foregroundStyle(.tertiary)
                            .padding(.top, 1).padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $model.context)
                        .font(.callout)
                        .scrollContentBackground(.hidden)
                        .frame(height: 84)
                }
            } header: {
                Text("Call context")
            } footer: {
                Text("Optional, but tips get much better with it. Works with or without a Cowork prep.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if let p = model.prep, p.matches {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Prep found: \(p.heading)").lineLimit(2)
                            Text("Made \(p.made.formatted(date: .omitted, time: .shortened)) in Cowork; it will be used for this call.")
                                .font(.caption).foregroundStyle(.secondary)
                            copyButton("Copy request for a new prep")
                        }
                    } icon: { Image(systemName: "checkmark.seal.fill").foregroundStyle(.green) }
                } else if let p = model.prep {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("No prep for \u{201C}\(model.effectiveTitle)\u{201D} yet.")
                            Text("The prep made \(p.made.formatted(date: .omitted, time: .shortened)) is for another call (\(p.heading)) and will not be used. Copy the request, paste it into Cowork, then start the call here when the new prep shows up.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            copyButton("Copy request for Cowork")
                        }
                    } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                } else {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.target.isEmpty ? "Choose a project to check for a Cowork prep." : "No Cowork prep for this project in the last 3 hours.")
                            Text("A prep is a brief, fact cards and an outline that Claude builds in Cowork from your project files, Notion and Jira 10-30 minutes before the call. Copy the request, paste it into Cowork, then start the call here: the prep is picked up from the project's live folder automatically.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            copyButton("Copy request for Cowork")
                        }
                    } icon: { Image(systemName: "doc.badge.clock").foregroundStyle(.secondary) }
                }
            } header: { Text("Prep") }
            Section {
                Picker("Audience", selection: $model.audience) {
                    Text("Auto").tag("auto"); Text("Team").tag("team"); Text("Client").tag("client")
                }
                .pickerStyle(.segmented)
                .help("Who is on the other side. Auto: detected from who speaks. Team: internal call, no corrections of your facts. Client: stricter, internal numbers are never shown, the client's culture profile is used. The language is chosen separately.")
                Picker("Meeting type", selection: $model.callType) {
                    Text("Standard").tag("auto"); Text("Presentation").tag("presentation"); Text("Interview").tag("interview")
                }
                .help("Standard: a usual meeting; talk vs discussion is detected by itself. Presentation (your talk with an outline) and Interview work best with a Cowork prep.")
                Picker("Microphone", selection: $model.micDevice) {
                    Text("System default" + (model.defaultInputName.map { " (\($0))" } ?? "")).tag("default")
                    Text("Mac built-in microphone").tag("builtin")
                    ForEach(model.micInputs.filter { !$0.builtin }, id: \.uid) { d in
                        Text(d.name).tag("uid:" + d.uid)
                    }
                    if model.micDevice.hasPrefix("uid:") && !model.micInputs.contains(where: { "uid:" + $0.uid == model.micDevice }) {
                        Text("Not connected: " + String(model.micDevice.dropFirst(4))).tag(model.micDevice)
                    }
                }
                .help("Your voice. System default follows macOS (AirPods, a headset or the Mac). Pick a device to keep it even if macOS switches. Can be changed during the call in the tips window.")
                Picker("Recording starts", selection: $model.standby) {
                    Text("When the call begins").tag(true)
                    Text("Now").tag(false)
                }
                .help("When the call begins: the window opens now and waits; recording starts when the other side speaks for a few seconds, or when you press the green Start. Nothing is written and no mic warnings are shown while it waits.")
                Picker("Languages", selection: $model.language) {
                    Text("Ukrainian + English").tag("uk+en"); Text("English").tag("en"); Text("English + Spanish").tag("en+es")
                }
                .help("What may be spoken on the call; transcription is restricted to these.")
            }
            HStack {
                Text(model.note).font(.caption).foregroundStyle(.orange)
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Start") { onStart() }.keyboardShortcut(.defaultAction).disabled(model.target.isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 720)
        .onAppear { model.scanPrep(); model.loadMicInputs() }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in model.scanPrep() }
    }

    /// Copies the Cowork request for this call (title, time, project, call context).
    private func copyButton(_ label: String) -> some View {
        Button(copied ? "Copied" : label) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(model.prepPhrase, forType: .string)
            copied = true
        }
        .controlSize(.small)
        .disabled(model.target.isEmpty)
    }
}

@MainActor
final class StartCallWindow {
    static var window: NSWindow?

    static func show(delegate: AppDelegate) {
        let model = StartCallModel()
        let view = StartCallView(model: model, onStart: {
            guard let req = model.requestJSON() else { return }
            let err = CallEngine.shared.start(request: req, apiAllowed: model.project?.apiAllowed ?? true) { st in
                delegate.openTips(for: CallFiles(tips: st.tipsFile ?? "", inbox: st.inboxFile ?? "",
                                                 status: CallEngine.shared.statusPath,
                                                 control: (CallEngine.shared.appRoot as NSString).appendingPathComponent("control")))
            }
            if let err = err { model.note = err } else { window?.close() }
        }, onCancel: { window?.close() })
        let host = NSHostingController(rootView: view)
        let w = window ?? NSWindow(contentViewController: host)
        w.contentViewController = host
        w.styleMask.insert(.resizable)
        w.setContentSize(NSSize(width: 540, height: 720))
        w.title = "Start call"
        w.isReleasedWhenClosed = false
        window = w
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
