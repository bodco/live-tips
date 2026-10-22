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
        add(menu, "Start call…", #selector(startCall), "n")
        add(menu, "Show tips window", #selector(showTips), "t")
        micItem = add(menu, "Allow microphone…", #selector(requestMic), "")
        menu.addItem(.separator())
        add(menu, "Settings…", #selector(openSettings), ",")
        add(menu, "About Live Tips", #selector(openAbout), "")
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Live Tips", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        it.menu = menu
        item = it
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        if !UserDefaults.standard.bool(forKey: "onboarded") {
            UserDefaults.standard.set(true, forKey: "onboarded")
            openSettings()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { startCall() }        // clicking the Dock icon opens Start call
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
        let recording = st.state == "recording"
        statusLines[0].title = recording ? "● Recording" + (st.project.map { ": \($0)" } ?? "") : "Not recording"
        statusLines[1].title = recording ? "Lines \(st.lines) · tips \(st.tips)" : "Start a call to see live numbers"
        statusLines[2].title = String(format: "This call: $%.2f (warning $%.0f, stop $%.0f)", st.callSpentUSD, cfg.budget.callSoftUSD, cfg.budget.callHardUSD)
        statusLines[3].title = String(format: "This month: $%.2f of $%.0f", month, cfg.budget.monthlyHardUSD)
        micItem.isHidden = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        item?.button?.title = recording ? " REC" : ""
        if st.callSpentUSD >= cfg.budget.callSoftUSD || month >= cfg.budget.monthlyHardUSD * 0.9 {
            item?.button?.contentTintColor = .systemOrange
        } else {
            item?.button?.contentTintColor = recording ? .systemRed : nil
        }
    }

    @objc func startCall() { MainActor.assumeIsolated { StartCallWindow.show(delegate: self) } }
    @objc func openSettings() { MainActor.assumeIsolated { SettingsWindow.show() } }
    @objc func openAbout() { MainActor.assumeIsolated { SettingsWindow.show() } }
    @objc func requestMic() { AVCaptureDevice.requestAccess(for: .audio) { _ in } }

    @objc func showTips() {
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
    @Published var note = ""
    let registry = ProjectRegistry.load(from: AppPaths.projects)
    let config = AppConfig.load(from: AppPaths.config)

    init() { target = registry.lastUsed }

    var targets: [(String, String)] {
        registry.workspaces.map { ("workspace:" + $0.name, "◆ " + $0.name + " (workspace)") } +
        registry.projects.filter { $0.status != "archived" }.map { ("project:" + $0.slug, $0.name) }
    }

    var root: String? {
        if target.hasPrefix("project:") {
            return registry.projects.first { "project:" + $0.slug == target }?.root
        }
        return registry.workspaces.first { "workspace:" + $0.name == target }?.root
    }

    /// Writes control/start.json for the engine and returns the call file paths.
    func start() -> CallFiles? {
        guard !target.isEmpty, let root = root, !root.isEmpty else { note = "Choose a project or workspace with a folder."; return nil }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd-HHmm"
        let slugTitle = title.isEmpty ? "call" : title.lowercased().replacingOccurrences(of: " ", with: "-")
        let stem = df.string(from: Date()) + "-" + slugTitle
        let live = (root as NSString).appendingPathComponent("live")
        let appRoot = config.effectiveAppRoot(appSupport: AppPaths.support.path)
        let control = (appRoot as NSString).appendingPathComponent("control")
        try? FileManager.default.createDirectory(atPath: live, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: control, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: (appRoot as NSString).appendingPathComponent("state"), withIntermediateDirectories: true)
        let req: [String: Any] = ["schema_version": 1, "engine": "app", "target": target, "root": root, "title": title,
                                  "stem": stem, "audience": audience, "call_type": callType,
                                  "requested_at": ISO8601DateFormatter().string(from: Date())]
        if let d = try? JSONSerialization.data(withJSONObject: req, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: (control as NSString).appendingPathComponent("start.json")), options: .atomic)
        }
        var reg = registry
        reg.lastUsed = target
        try? reg.save(to: AppPaths.projects)
        let base = (live as NSString).appendingPathComponent(stem)
        return CallFiles(tips: base + ".app.tips.jsonl", inbox: base + ".app.inbox.jsonl",
                         status: (appRoot as NSString).appendingPathComponent("state/status.json"), control: control)
    }
}

struct StartCallView: View {
    @ObservedObject var model: StartCallModel
    var onStart: (CallFiles) -> Void

    var body: some View {
        Form {
            Picker("Project or workspace", selection: $model.target) {
                Text("Choose…").tag("")
                ForEach(model.targets, id: \.0) { Text($0.1).tag($0.0) }
            }
            .help("Recordings and notes go to this folder. A workspace is for general calls about several projects.")
            if let r = model.root { Text(r).font(.caption).foregroundStyle(.secondary) }
            TextField("Call title (optional)", text: $model.title)
            Picker("Who is on the other side", selection: $model.audience) {
                Text("Auto").tag("auto"); Text("Team").tag("team"); Text("Client").tag("client"); Text("Boss").tag("boss")
            }
            Picker("Meeting type", selection: $model.callType) {
                Text("Standard").tag("auto"); Text("Presentation (my talk)").tag("presentation"); Text("Interview").tag("interview")
            }
            .help("Standard: a usual meeting; Live Tips tells talk from discussion by itself. Presentation and Interview need a prep.")
            HStack {
                Text(model.note).font(.caption).foregroundStyle(.orange)
                Spacer()
                Button("Start") { if let f = model.start() { onStart(f) } }
                    .keyboardShortcut(.defaultAction).disabled(model.target.isEmpty)
            }
            Text("Recording starts when the engine is installed (next build). For now Start prepares the call and opens the tips window.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 460)
    }
}

@MainActor
final class StartCallWindow {
    static var window: NSWindow?

    static func show(delegate: AppDelegate) {
        let model = StartCallModel()
        let view = StartCallView(model: model) { files in
            window?.close()
            delegate.openTips(for: files)
        }
        let w = window ?? NSWindow(contentViewController: NSHostingController(rootView: view))
        w.contentViewController = NSHostingController(rootView: view)
        w.title = "Start call"
        w.isReleasedWhenClosed = false
        window = w
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
