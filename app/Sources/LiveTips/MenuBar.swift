import AppKit
import AVFoundation
import LiveTipsCore
import SwiftUI

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
    var tipsItem = NSMenuItem()
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
        for l in statusLines { l.isEnabled = false; menu.addItem(l) }
        menu.addItem(.separator())
        startItem = add(menu, "Start call…", #selector(startCall), "n")
        endItem = add(menu, "End call", #selector(endCall), "")
        tipsItem = add(menu, "Open tips window", #selector(showTips), "t")
        micItem = add(menu, "Allow microphone…", #selector(requestMic), "")
        menu.addItem(.separator())
        add(menu, "Settings…", #selector(openSettings), ",")
        add(menu, "About Live Tips", #selector(openAbout), "")
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Live Tips", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        it.menu = menu
        item = it
        refresh()
        MainActor.assumeIsolated { LocalAIService.shared.apply() }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
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
        let st = EngineStatus.load(path: (appRoot as NSString).appendingPathComponent("state/status.json"))
        let month = SpendLedger.monthSpent()
        let recording = st.state == "recording" || st.state == "loading_model"
        lastStatus = st
        startItem.isHidden = recording
        endItem.isHidden = !recording
        tipsItem.title = recording ? "Open tips window" : "Preview tips window"
        statusLines[0].title = recording ? "● Recording" + (st.project.map { ": \($0)" } ?? "") : "Not recording"
        statusLines[1].title = recording ? "Lines \(st.lines) · tips \(st.tips)" : "Start a call to see live numbers"
        statusLines[2].title = String(format: "This call: $%.2f (warning $%.0f, stop $%.0f)", st.callSpentUSD, cfg.budget.callSoftUSD, cfg.budget.callHardUSD)
        statusLines[2].isHidden = !recording
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
    @objc func openSettings() { MainActor.assumeIsolated { SettingsWindow.show() } }
    @objc func openAbout() { MainActor.assumeIsolated { SettingsWindow.show(tab: "about") } }
    @objc func openSettingsTab() { MainActor.assumeIsolated { SettingsWindow.show() } }

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
            a.title = "Live Tips (app)"
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
    let registry = ProjectRegistry.load(from: AppPaths.projects)
    let config = AppConfig.load(from: AppPaths.config)

    init() {
        target = registry.lastUsed
        applyProjectDefaults()
    }

    struct PrepInfo { var heading: String; var made: Date; var file: String }

    /// A prep made in Cowork (prep-*.brief.md in <project folder>/live, younger than 3 h). The recorder
    /// adopts it on start: the one whose name matches the title, else the newest.
    func scanPrep() {
        prep = nil
        guard let root = root else { return }
        let live = (root as NSString).appendingPathComponent("live")
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: live) else { return }
        var best: PrepInfo?
        for n in names where n.hasPrefix("prep-") && n.hasSuffix(".brief.md") {
            let path = (live as NSString).appendingPathComponent(n)
            guard let m = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  Date().timeIntervalSince(m) < 3 * 3600 else { continue }
            if let b = best, b.made > m { continue }
            let first = (try? String(contentsOfFile: path, encoding: .utf8))?.split(separator: "\n").first.map(String.init) ?? n
            let heading = first.replacingOccurrences(of: "# Live Brief (prep):", with: "").replacingOccurrences(of: "#", with: "")
                .trimmingCharacters(in: .whitespaces)
            best = PrepInfo(heading: heading.isEmpty ? n : heading, made: m, file: n)
        }
        prep = best
    }

    var targetName: String { project?.name ?? workspace?.name ?? "the project" }

    /// Phrase to paste into Cowork to make a prep for this call.
    var prepPhrase: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let t = title.isEmpty ? "the call" : "\"\(title)\""
        return "Prepare live tips for \(t) at \(f.string(from: Date().addingTimeInterval(15 * 60))), project \(targetName)" +
            (context.isEmpty ? "" : ". Context: \(context)")
    }

    var project: Project? { registry.projects.first { "project:" + $0.slug == target } }
    var workspace: Workspace? { registry.workspaces.first { "workspace:" + $0.name == target } }
    var root: String? { project?.root ?? workspace?.root }

    var details: String {
        if let p = project {
            let team = p.people.filter { $0.side == "team" }.count, client = p.people.filter { $0.side == "client" }.count
            return "Team \(team) · client \(client) · " + (p.apiAllowed ? "Claude tips on" : "local only (Claude off for this project)")
        }
        if let w = workspace { return "Projects: " + w.projects.joined(separator: ", ") }
        return ""
    }

    func applyProjectDefaults() {
        if let p = project, p.clientLanguage.lowercased().hasPrefix("english"), language == "uk+en" { language = "en" }
    }

    func requestJSON() -> [String: Any]? {
        guard let root = root, !root.isEmpty else { note = "This project has no folder in its config."; return nil }
        let langs: (String, [String]) = language == "en" ? ("en", ["en"]) : language == "en+es" ? ("en", ["en", "es"]) : ("uk", ["uk", "en"])
        var reg = registry
        reg.lastUsed = target
        try? reg.save(to: AppPaths.projects)
        return ["project_dir": root, "title": title.isEmpty ? (project?.name ?? workspace?.name ?? "Meeting") : title,
                "slug": project?.slug ?? workspace?.name.lowercased() ?? "", "call_type": callType, "audience": audience,
                "me_lang": langs.0, "langs": langs.1, "me_langs": langs.0 == "uk" ? ["uk", "en"] : [langs.0],
                "context": context.trimmingCharacters(in: .whitespacesAndNewlines)]
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
                .onChange(of: model.target) { model.applyProjectDefaults(); model.scanPrep() }
                if let r = model.root {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Text(model.details).font(.caption).foregroundStyle(.secondary)
                    }
                }
                TextField("Title", text: $model.title, prompt: Text("e.g. Weekly sync with the client"))
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
                if let p = model.prep {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Prep found: \(p.heading)").lineLimit(2)
                            Text("Made \(p.made.formatted(date: .omitted, time: .shortened)) in Cowork; it will be used for this call.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "checkmark.seal.fill").foregroundStyle(.green) }
                } else {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.target.isEmpty ? "Choose a project to check for a Cowork prep." : "No Cowork prep for this project in the last 3 hours.")
                            Text("A prep is a brief, fact cards and an outline that Claude builds in Cowork from your project files, Notion and Jira 10-30 minutes before the call. Copy the request, paste it into Cowork, then start the call here: the prep is picked up from the project's live folder automatically.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button(copied ? "Copied" : "Copy request for Cowork") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(model.prepPhrase, forType: .string)
                                copied = true
                            }
                            .controlSize(.small)
                            .disabled(model.target.isEmpty)
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
        .frame(width: 540, height: 640)
        .onAppear { model.scanPrep() }
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
        w.setContentSize(NSSize(width: 540, height: 640))
        w.title = "Start call"
        w.isReleasedWhenClosed = false
        window = w
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
