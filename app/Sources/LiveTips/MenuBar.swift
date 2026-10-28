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
    var demoItem = NSMenuItem()
    var demoPresItem = NSMenuItem()
    var notionItem = NSMenuItem()
    var upNextItem = NSMenuItem()
    var homeItem = NSMenuItem(), settingsItem = NSMenuItem(), setupItem = NSMenuItem(), tourItem = NSMenuItem()
    var aboutItem = NSMenuItem(), quitItem = NSMenuItem()
    var menuLang = L10n.lang
    var clock: Timer?               // the elapsed time next to the menu bar icon while recording
    var lastStatus = EngineStatus()

    var config: AppConfig { AppConfig.load(from: AppPaths.config) }
    var appRoot: String { config.effectiveAppRoot(appSupport: AppPaths.support.path) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        NSApp.setActivationPolicy(config.showInDock ? .regular : .accessory)
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        it.button?.image = Brand.menuBarImage(recording: false)     // Pacenote 0.8: the brand template
        it.button?.imagePosition = .imageLeft
        it.button?.toolTip = L("menubar.tooltip")
        let menu = NSMenu()
        menu.delegate = self
        // The main action first; the status lines below it (review P2).
        homeItem = add(menu, L("menubar.home"), #selector(openHome), "0")
        startItem = add(menu, L("menubar.startCall"), #selector(startCall), "n")
        upNextItem = NSMenuItem(title: "Up next", action: nil, keyEquivalent: "")
        upNextItem.isHidden = true
        menu.addItem(upNextItem)
        tipsItem = add(menu, L("menubar.showTips"), #selector(showTips), "")
        pauseItem = add(menu, L("menubar.pause"), #selector(togglePause), "p")
        pauseItem.keyEquivalentModifierMask = [.control, .option]      // shown in the menu: the global shortcut
        helpItem = add(menu, L("menubar.helpNow"), #selector(helpNow), "h")
        helpItem.keyEquivalentModifierMask = [.control, .option]
        endItem = add(menu, L("menubar.endCall"), #selector(endCall), "")
        menu.addItem(.separator())
        for l in statusLines { l.isEnabled = false; menu.addItem(l) }
        menu.addItem(.separator())
        notionItem = add(menu, L("menubar.sendNotion"), #selector(sendToNotion), "")
        micItem = add(menu, L("menubar.allowMic"), #selector(requestMic), "")
        menu.addItem(.separator())
        settingsItem = add(menu, L("menubar.settings"), #selector(openSettings), ",")
        setupItem = add(menu, L("menubar.setup"), #selector(openSetup), "")
        tourItem = add(menu, L("menubar.welcomeTour"), #selector(openOnboarding), "")
        aboutItem = add(menu, L("menubar.about"), #selector(openAbout), "")
        // For checking the window without a call: shown only with Option held while the menu opens.
        demoItem = add(menu, L("menubar.demo"), #selector(showDemo), "")
        demoPresItem = add(menu, L("menubar.demoPresentation"), #selector(showDemoPresentation), "")
        menu.addItem(.separator())
        quitItem = NSMenuItem(title: L("menubar.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
        it.menu = menu
        item = it
        refresh()
        MainActor.assumeIsolated { LocalAIService.shared.apply() }
        NotionMirrorService.shared.startSchedule()
        updateCoreIfNeeded()
        // Up next (2026-10-27): the switch goes on when the old call's recorder has stopped.
        NotificationCenter.default.addObserver(forName: CallEngine.callEnded, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                // Home's Recent calls (2026-10-27): recorded before a switch starts the next call.
                let ce = CallEngine.shared
                let file = n.userInfo?["file"] as? String ?? ""
                let root = ce.callRequest["project_dir"] as? String ?? ""
                CallHistory.shared.recordEnd(file: file, title: ce.renamed ?? (ce.callRequest["title"] as? String) ?? "Call",
                                             project: self?.lastStatus.project ?? (root as NSString).lastPathComponent,
                                             lines: n.userInfo?["lines"] as? Int ?? 0, cost: ce.lastCall["tips_usd"] as? Double)
                SpendDays.add(ce.lastCall["tips_usd"] as? Double ?? 0)
                self?.finishSwitch()
            }
        }
        HotKeys.shared.install(help: { [weak self] in self?.helpNow() }, pause: { [weak self] in self?.togglePause() })
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        // 2026-10-26: new users get the onboarding (permissions, folders, Claude, install, Notion optional).
        if !UserDefaults.standard.bool(forKey: "onboardingDone") && !UserDefaults.standard.bool(forKey: "onboarded") {
            UserDefaults.standard.set(true, forKey: "onboarded")
            MainActor.assumeIsolated { OnboardingWindow.show() }
        } else if !CallEngine.shared.problems().isEmpty { MainActor.assumeIsolated { SetupWindow.show() } }
        else if !callIsLive { openHome() }       // 2026-10-27 (owner): Home is the app's main window
        MainActor.assumeIsolated { _ = CalendarService.shared }
    }

    /// After an app update the recorder core in the app folder is refreshed from the app by itself
    /// (setup.sh install core keeps config.json, voices and models), so a new dmg needs no Setup run.
    func updateCoreIfNeeded() {
        guard let res = Bundle.main.resourcePath else { return }
        let root = appRoot
        let bundled = (try? String(contentsOfFile: (res as NSString).appendingPathComponent("core/VERSION"), encoding: .utf8)) ?? ""
        let installed = (try? String(contentsOfFile: (root as NSString).appendingPathComponent("core.version"), encoding: .utf8)) ?? ""
        guard !bundled.isEmpty, bundled != installed,
              FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent("src/transcriber.py")),
              !CallEngine.shared.isRunning else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [(res as NSString).appendingPathComponent("setup.sh"), "install", "core"]
        var env = ProcessInfo.processInfo.environment
        env["APPROOT"] = root
        env["BUNDLE"] = res
        p.environment = env
        try? p.run()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Dock icon: a call in progress (also while waiting for the other side) opens its tips window.
        if !flag { if CallEngine.shared.isRunning || ["recording", "standby", "loading_model"].contains(lastStatus.state) { showTips() } else { openHome() } }
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
        appMenu.addItem(withTitle: L("menubar.about"), action: #selector(openAbout), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: L("menubar.settings"), action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("menubar.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: L("menu.edit"))
        edit.addItem(withTitle: L("menu.undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: L("menu.redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: L("menu.cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("menu.copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("menu.paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("menu.selectAll"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        let winItem = NSMenuItem()
        main.addItem(winItem)
        let win = NSMenu(title: L("menu.window"))
        win.addItem(withTitle: L("menu.minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: L("menu.close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = win
        NSApp.mainMenu = main
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
        let dev = NSEvent.modifierFlags.contains(.option)
        demoItem.isHidden = !dev
        demoPresItem.isHidden = !dev
    }

    func refresh() {
        // Custom shortcuts (Settings > General > Shortcuts) shown in the menu.
        for (item, act) in [(helpItem, HotKeys.Action.help), (pauseItem, HotKeys.Action.pause)] {
            let c = HotKeys.shared.combo(act)
            item.keyEquivalent = c.char.lowercased(); item.keyEquivalentModifierMask = c.menuMask
        }
        let cfg = config
        IndexService.shared.configure(projects: ProjectRegistry.load(from: AppPaths.projects).projects, appRoot: appRoot,
                                      python: cfg.engine.python, enabled: cfg.localAI.enabled)
        let st = EngineStatus.load(path: (appRoot as NSString).appendingPathComponent("state/status.json"))
        let month = SpendLedger.monthSpent()
        let recording = ["recording", "loading_model", "standby"].contains(st.state)
        lastStatus = st
        warnIfNoAudio(st)
        // 2026-10-27 (Up next): during a call the same item plans an upcoming call.
        relabelMenu()
        startItem.title = recording ? L("menubar.planCall") : L("menubar.startCall")
        MainActor.assumeIsolated { rebuildUpNextMenu() }
        endItem.isHidden = !recording
        pauseItem.isHidden = st.state != "recording"
        helpItem.isHidden = st.state != "recording"
        tipsItem.isHidden = !recording
        notionItem.isHidden = recording || CallEngine.shared.lastFile == nil
        notionItem.toolTip = CallEngine.shared.notionResult
        let elapsed = Self.elapsed(st)
        statusLines[0].title = st.state == "standby" ? L("menubar.status.waiting") + (st.project.map { ": \($0)" } ?? "")
            : recording ? L("menubar.status.recording", ["elapsed": elapsed]) + (st.project.map { " · \($0)" } ?? "")
            : (CallEngine.shared.lastCallSummary.isEmpty ? L("menubar.status.notRecording") : CallEngine.shared.lastCallSummary)
        if noAudioWarned != nil, noAudioWarned == st.file, st.lines == 0, ["recording", "standby"].contains(st.state) {
            statusLines[0].title = L("menubar.status.audioFailing")
        }
        statusLines[1].title = L("menubar.status.callLine", ["lines": "\(st.lines)", "tips": "\(st.tips)",
                                                              "cost": String(format: "%.2f", st.callSpentUSD), "cap": String(format: "%.0f", cfg.budget.callHardUSD)])
        statusLines[1].isHidden = !recording
        // 2026-10-26 (owner): the last call's cost; the tip rating only when that developer check is on.
        let judge = cfg.judgeAfterCall ? CallEngine.shared.judgeResult : ""
        let cost = CallEngine.shared.lastCallLine
        statusLines[2].title = [cost, CallEngine.shared.judgeRunning != nil && cfg.judgeAfterCall ? "rating the tips…" : judge]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        statusLines[2].isHidden = recording || statusLines[2].title.isEmpty
        statusLines[2].toolTip = CallEngine.shared.lastCallDetail
        statusLines[3].title = L("menubar.thisMonth", ["spent": String(format: "%.2f", month), "cap": String(format: "%.0f", cfg.budget.monthlyHardUSD)])
        micItem.isHidden = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        item?.button?.image = Brand.menuBarImage(recording: st.state == "recording")
        setClock(st.state == "recording")
        if st.callSpentUSD >= cfg.budget.callSoftUSD || month >= cfg.budget.monthlyHardUSD * 0.9 {
            item?.button?.contentTintColor = .systemOrange
        } else {
            item?.button?.contentTintColor = recording ? .systemRed : nil
        }
    }

    @objc func startCall() { MainActor.assumeIsolated { StartCallWindow.show(delegate: self) } }
    @objc func openHome() { MainActor.assumeIsolated { HomeWindow.show(delegate: self) } }
    @objc func sendToNotion() {
        guard let f = CallEngine.shared.lastFile, !CallEngine.shared.isRunning else { return }
        CallEngine.shared.writeToNotion(file: f)
    }
    @objc func openSetup() { MainActor.assumeIsolated { SetupWindow.show() } }
    @objc func openOnboarding() { MainActor.assumeIsolated { OnboardingWindow.show() } }
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

    /// 2026-10-23: the audio helper failed for a whole call and nothing said so. A red card in the window
    /// (once per call) and a menu line when the helper keeps exiting and no line has been written.
    var noAudioWarned: String?
    var noAudioSince: Date?
    func warnIfNoAudio(_ st: EngineStatus) {
        let failing = ["recording", "standby"].contains(st.state) && st.lines == 0 && st.errors.contains { $0.contains("audiocap") && $0.contains("exited") }
        if !failing { noAudioSince = nil; return }
        if noAudioSince == nil { noAudioSince = Date() }
        guard Date().timeIntervalSince(noAudioSince!) > 30, noAudioWarned != st.file else { return }
        noAudioWarned = st.file
        let uk = config.uiLanguage == "uk"
        _ = uk
        let item: [String: Any] = ["kind": "tip", "level": "red", "gist": L("tips.noAudio.title"),
                                   "items": [L("tips.noAudio.body")],
                                   "t": DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)]
        if let d = try? JSONSerialization.data(withJSONObject: [item]), let js = String(data: d, encoding: .utf8) {
            if tips == nil { showTips() }
            MainActor.assumeIsolated { tips?.push("window.addItems && window.addItems(\(js))") }
        }
    }

    @objc func endCall() {
        if let t = tips { MainActor.assumeIsolated { t.window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); t.endCallClicked() }; return }
        let a = NSAlert()
        a.messageText = L("alert.endCall.title")
        a.informativeText = L("alert.endCall.body")
        a.addButton(withTitle: L("menubar.endCall"))
        a.addButton(withTitle: L("common.cancel"))
        if a.runModal() == .alertFirstButtonReturn { CallEngine.shared.stop() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { LocalAIService.shared.stop() }
        tips?.setSplit(false, animate: false)          // keep the saved tips window at its normal width
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard CallEngine.shared.isRunning else { return .terminateNow }
        let a = NSAlert()
        a.messageText = L("alert.quit.title")
        a.informativeText = L("alert.quit.body")
        a.addButton(withTitle: L("alert.quit.confirm"))
        a.addButton(withTitle: L("common.cancel"))
        if a.runModal() == .alertFirstButtonReturn { CallEngine.shared.stop(); return .terminateNow }
        return .terminateCancel
    }
    @objc func requestMic() { AVCaptureDevice.requestAccess(for: .audio) { _ in } }

    @objc func showTips() {
        // 2026-10-27 (owner): reopens a closed tips window for the call in progress, also in standby.
        let st = EngineStatus.load(path: CallEngine.shared.statusPath)
        lastStatus = st
        if ["recording", "standby", "loading_model"].contains(st.state) || CallEngine.shared.isRunning,
           let t = CallEngine.shared.appTipsFile ?? st.tipsFile {
            openTips(for: CallFiles(tips: t, inbox: st.inboxFile ?? "", status: CallEngine.shared.statusPath,
                                    control: (CallEngine.shared.appRoot as NSString).appendingPathComponent("control")))
            return
        }
    }

    @objc func showDemo() { openDemo("--prompter-demo") }
    @objc func showDemoPresentation() { openDemo("--prompter-demo-presentation") }
    func openDemo(_ flag: String) {
        MainActor.assumeIsolated {
            tips?.window?.close()
            let c = PrompterController(args: prompterArgs(["LiveTips", flag]))
            c.show()
            tips = c
        }
    }

    func openTips(for call: CallFiles) {
        MainActor.assumeIsolated {
            // QA 26.10: one tips window per call; a second click brings the open one forward.
            if let t = tips, t.args.tips == call.tips, let w = t.window, w.isVisible {
                w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
            }
            tips?.window?.close()
            var a = PrompterArgs()
            a.tips = call.tips
            a.inbox = call.inbox
            a.status = call.status
            a.control = call.control
            a.html = Bundle.main.resourceURL?.appendingPathComponent("prompter.html").path ?? ""
            // Pacenote 0.8: the window is titled with the call, the brand sits in the title bar.
            let ce = CallEngine.shared
            a.title = ce.renamed ?? (ce.callRequest["title"] as? String) ?? lastStatus.project ?? L("app.name")
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
    /// 2026-10-27 (owner, Up next): every call set up here has an id; its preparation is tied to it.
    var id = UUID()
    /// The base path of this call's finished preparation (<root>/live/prep-...), set when it is ready.
    @Published var prepBase: String?
    @Published var prepFailed = false
    /// 2026-10-27 (owner, calendars): the calendar event this call is, its series, and where the settings came from.
    @Published var calEventID: String?
    var seriesKey: String?
    var calendarKey: String?          // "<account>|<calendar>": the project last used for this calendar is suggested
    @Published var appliedFrom: String?
    @Published var target = ""          // "project:<slug>" | "workspace:<name>"
    @Published var title = ""
    @Published var audience = "auto"
    @Published var callType = "auto"
    @Published var publicCall = false            // D3: a webinar or an event with strangers: new voices are not saved
    @Published var hiringRole = "observer"      // interview: observer | interviewer | coach (as in the skill)
    @Published var tipModel = ""                // "" = the model from Settings > AI
    @Published var language = "uk"
    @Published var note = ""
    /// 2026-10-26 (owner): a template instead of an empty field; empty lines of it are not sent.
    /// 2026-10-27 (owner): the template follows the interface language; no Ukrainian words in an English UI.
    static let templates = ["en": "Goal: \nParticipants: \nOpen questions: \nWhere to look (document names, links): ",
                            "uk": "Мета: \nУчасники: \nВідкриті питання: \nДе дивитись (назви документів, посилання): "]
    static var uiLang: String { AppConfig.load(from: AppPaths.config).uiLanguage == "uk" ? "uk" : "en" }
    static var contextTemplate: String { templates[uiLang]! }
    static let allTemplates = templates.values.joined(separator: "\n") + "\nДе дивитись (документи, посилання): \nДе дивитись (папки, документи, посилання): "
    @Published var context = StartCallModel.contextTemplate
    /// An untouched template in the other language (or an older one) is replaced by this language's.
    func refreshTemplate() {
        let t = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || StartCallModel.allTemplates.contains(t) { context = StartCallModel.contextTemplate }
    }
    /// 2026-10-27 (owner): "Add folder" like in Cowork; the context then names only files or links.
    @Published var folders: [String] = []
    @Published var useProjectFolder = true     // 2026-10-27 (owner): the project folder can be left out of the preparation
    nonisolated static func isDir(_ path: String) -> Bool { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: path, isDirectory: &d) && d.boolValue }

    /// 2026-10-28 (owner): folders or single files (one document from Downloads, not the whole folder).
    func addFolders() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = true; p.allowsMultipleSelection = true
        p.message = "Folders or files to read for this call"
        p.prompt = "Add"
        if let r = root { p.directoryURL = URL(fileURLWithPath: r) }
        guard p.runModal() == .OK else { return }
        for u in p.urls where !folders.contains(u.path) { folders.append(u.path) }
    }
    /// When the call is: today, the next full hour (17:00). Goes into the Cowork request and the call request.
    @Published var callDate = StartCallModel.nextFullHour()

    static func nextFullHour(from now: Date = Date()) -> Date {
        let cal = Calendar.current
        let start = cal.dateInterval(of: .hour, for: now)?.start ?? now
        return cal.date(byAdding: .hour, value: 1, to: start) ?? now
    }

    /// The call context without the template lines left empty ("Мета: " with nothing after it).
    var cleanContext: String {
        let lines = context.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        func isHeader(_ t: String) -> Bool { t.hasSuffix(":") && !t.dropLast().contains(":") }
        var out: [String] = []
        for (i, t) in lines.enumerated() where !t.isEmpty {
            if isHeader(t) {
                // An empty template line goes; a header with its list on the next lines stays (QA 26.10).
                let next = lines[(i + 1)...].first { !$0.isEmpty }
                if next == nil || isHeader(next!) || StartCallModel.allTemplates.contains(next!) { continue }
            }
            out.append(t)
        }
        let fl = folders.filter { Self.isDir($0) }, fi = folders.filter { !Self.isDir($0) }
        if !fl.isEmpty { out.append((StartCallModel.uiLang == "uk" ? "Папки: " : "Folders: ") + fl.joined(separator: "; ")) }
        if !fi.isEmpty { out.append((StartCallModel.uiLang == "uk" ? "Файли: " : "Files: ") + fi.joined(separator: "; ")) }
        return out.joined(separator: "\n")
    }

    /// The PM's own projects on this call: the project, or every project of the workspace that has a config here.
    var pmProjects: [String] {
        if let p = project { return [p.name] }
        if let w = workspace { return registry.projects.filter { w.projects.contains($0.slug) && $0.status != "archived" }.map(\.name) }
        return []
    }

    /// Names from the "Учасники:" / "Participants:" line: the only names the speaker cards offer.
    /// The PM's own names (Settings > General) are left out: the PM's voice is the microphone.
    var participants: [String] {
        let me = Set(AppConfig.load(from: AppPaths.config).nameAliases.map { $0.lowercased() })
        let lines = context.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let i = lines.firstIndex(where: { $0.range(of: "^(учасники|participants|attendees)\\s*:", options: [.regularExpression, .caseInsensitive]) != nil }) else { return [] }
        var text = String(lines[i].drop(while: { $0 != ":" }).dropFirst())
        for l in lines[(i + 1)...] {                // names may go on the next lines, until the next "Header:"
            if l.range(of: "^[^,;]{1,40}:", options: .regularExpression) != nil { break }
            text += "," + l
        }
        // QA 26.10: only the PM's own full name or a single-word alias is left out, not every namesake.
        return text.replacingOccurrences(of: " and ", with: ",").replacingOccurrences(of: " і ", with: ",")
            .split(whereSeparator: { ",;".contains($0) })
            .map { $0.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-•*"))) }
            .filter { n in !n.isEmpty && !me.contains(n.lowercased()) }
    }
    @Published var prep: PrepInfo?
    /// All preparations in the project's live folder (last 14 days), newest first, and the one chosen by hand.
    @Published var prepList: [PrepInfo] = []
    @Published var chosenPrep: String?           // file name in <root>/live; nil = automatic
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
        var all: [PrepInfo] = []
        for n in names where n.hasPrefix("prep-") && n.hasSuffix(".brief.md") {
            let path = (live as NSString).appendingPathComponent(n)
            guard let m0 = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  Date().timeIntervalSince(m0) < 14 * 86400 else { continue }
            // QA 26.10: a prep made in the morning for an evening call is still fresh: its age counts from
            // the call time in its name (prep-YYYY-MM-DD-HHMM-...) when that time is ahead.
            var m = m0
            if let r = n.range(of: "^prep-\\d{4}-\\d\\d-\\d\\d-\\d{4}", options: .regularExpression) {
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"
                if let when = f.date(from: String(n[r].dropFirst(5))), when > m0, when.timeIntervalSinceNow < 12 * 3600 {
                    m = min(Date(), max(m0, when.addingTimeInterval(-2 * 3600)))
                }
            }
            let core = String(n.dropFirst("prep-".count).dropLast(".brief.md".count))
                .replacingOccurrences(of: "^(\\d{4}-\\d\\d-\\d\\d(-\\d{4})?-)+", with: "", options: .regularExpression)
            let first = (try? String(contentsOfFile: path, encoding: .utf8))?.split(separator: "\n").first.map(String.init) ?? n
            let heading = first.replacingOccurrences(of: "# Live Brief (prep):", with: "").replacingOccurrences(of: "# Live Brief:", with: "")
                .replacingOccurrences(of: "#", with: "").trimmingCharacters(in: .whitespaces)
            // The call title is also in the heading: "Live Brief: <title> (prep, <date> ...)". Cowork may name the file differently.
            let headTitle = heading.replacingOccurrences(of: "\\s*\\((prep|[^)]*\\d{4}-\\d\\d-\\d\\d)[^)]*\\)\\s*$", with: "", options: .regularExpression)
            let matches = Self.titleMatch(core, callTitle) || (!headTitle.isEmpty && Self.titleMatch(headTitle, callTitle))
            all.append(PrepInfo(heading: heading.isEmpty ? n : heading, made: m, file: n, matches: matches))
            if Date().timeIntervalSince(m) >= 3 * 3600 { continue }
            if let b = best, b.matches && !matches || (b.matches == matches && b.made > m) { continue }
            best = PrepInfo(heading: heading.isEmpty ? n : heading, made: m, file: n, matches: matches)
        }
        prepList = all.sorted { $0.made > $1.made }
        if let c = chosenPrep, let p = all.first(where: { $0.file == c }) {
            prep = PrepInfo(heading: p.heading, made: p.made, file: p.file, matches: true)
        } else {
            if chosenPrep != nil { chosenPrep = nil }
            prep = best
        }
    }

    /// Full path of the chosen prep brief (nil = automatic).
    var chosenPrepPath: String? {
        guard let c = chosenPrep, let root = root else { return nil }
        return ((root as NSString).appendingPathComponent("live") as NSString).appendingPathComponent(c)
    }

    var targetName: String { project?.name ?? workspace?.name ?? "the project" }

    /// "Prepare now": the request for Claude Code (PrepRunner).
    func prepRequest() -> PrepRunner.Request? {
        guard let root = root, !root.isEmpty else { return nil }
        let ws = workspace ?? registry.workspaces.first { w in w.projects.contains(project?.slug ?? "\u{0}") }
        return PrepRunner.Request(title: effectiveTitle, date: callDate, projectName: targetName,
                                  slug: project?.slug ?? workspace?.name.lowercased() ?? "", root: root,
                                  config: project?.config ?? "", audience: audience, callType: callType, hiringRole: hiringRole,
                                  languages: language.split(separator: "+").map(String.init), context: cleanContext,
                                  workspaceRoot: (ws?.root == root) ? "" : (ws?.root ?? ""), folders: folders,
                                  useProjectFolder: useProjectFolder, callID: id)
    }

    /// Phrase to paste into Cowork to make a prep for this call.
    var prepPhrase: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        let t = title.isEmpty ? "the call" : "\"\(title)\""
        let ctx = cleanContext
        return "Prepare live tips for \(t) on \(f.string(from: callDate)), project \(targetName). Use this title exactly for the prep files" +
            (ctx.isEmpty ? "" : ". Context:\n\(ctx)")
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

    var languageTouched = false               // the PM chose a language by hand: project changes keep it
    func applyProjectDefaults() {
        // QA 26.10: the language follows the project (English client -> English) until the PM picks one.
        guard !languageTouched else { return }
        language = (project?.clientLanguage.lowercased().hasPrefix("english") ?? false) ? "en" : "uk"
    }

    func requestJSON() -> [String: Any]? {
        guard let root = root, !root.isEmpty else { note = "This project has no folder in its config."; return nil }
        let langs: (String, [String]) = language == "en" ? ("en", ["en"]) : language == "en+es" ? ("en", ["en", "es"])
            : language == "uk" ? ("uk", ["uk"]) : ("uk", ["uk", "en"])
        var reg = registry
        reg.lastUsed = target
        reg.lastUsedAt[target] = ISO8601DateFormatter().string(from: Date())
        try? reg.save(to: AppPaths.projects)
        return ["project_dir": root, "title": title.isEmpty ? (project?.name ?? workspace?.name ?? "Meeting") : title,
                "slug": project?.slug ?? workspace?.name.lowercased() ?? "", "call_type": callType, "audience": audience,
                "hiring_role": callType == "interview" ? hiringRole : "", "tip_model": tipModel,
                "me_lang": langs.0, "langs": langs.1, "me_langs": language == "uk+en" ? ["uk", "en"] : [langs.0],
                "context": cleanContext, "participants": participantsWithPrevious, "pm_projects": pmProjects,
                "workspace": workspace?.name ?? registry.workspaces.first { w in w.projects.contains(project?.slug ?? "\u{0}") }?.name ?? "",
                "scheduled_at": ISO8601DateFormatter().string(from: callDate), "mic_device": micDevice, "standby": standby,
                "project_config": project?.config ?? "", "people": people, "people_team": peopleTeam,
                "voices_remember": !publicCall, "prep_file": chosenPrepPath ?? "",
                "folders": folders,
                "workspace_root": { let ws = workspace ?? registry.workspaces.first { w in w.projects.contains(project?.slug ?? "\u{0}") }; return (ws?.root == root) ? "" : (ws?.root ?? "") }()]
    }

    var tipModelChoices: [String] {
        let c = AppConfig.load(from: AppPaths.config)
        let base = c.knownModels.isEmpty ? AppConfig.fallbackModels : c.knownModels
        return base.filter { ($0.contains("haiku") || $0.contains("sonnet") || $0.contains("opus") || $0.contains("fable")) && $0 != c.models.tip }
    }

    /// Full names of the team and the client from the project config (all projects of a workspace):
    /// the "Who is speaking?" card offers them, as in the skill. Names are never set by themselves.
    var peopleTeam: [String] {
        let ps = project.map { [$0] } ?? registry.projects.filter { workspace?.projects.contains($0.slug) ?? false }
        var seen = Set<String>()
        return ps.flatMap { $0.people.filter { $0.side == "team" }.map(\.name) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    var people: [String] {
        let ps = project.map { [$0] } ?? registry.projects.filter { workspace?.projects.contains($0.slug) ?? false }
        var seen = Set<String>()
        return ps.flatMap { $0.people.map(\.name) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}

struct StartCallView: View {
    @ObservedObject var model: StartCallModel
    @ObservedObject var runner = PrepRunner.shared
    @ObservedObject var upnext = UpNext.shared
    /// 2026-10-27 (owner, Up next): a call is being recorded; this window sets up an upcoming one.
    var live = false
    var planOnly = false            // Plan a call from Home: plan mode without a live call
    var liveTitle = ""
    var liveSince: Date?
    var onStart: () -> Void
    var onCancel: () -> Void
    var onSave: () -> Void = {}
    var onSwitch: () -> Void = {}
    var onRemove: () -> Void = {}
    @State private var copied = false

    @AppStorage("startCallAdvanced") private var advanced = false
    @State private var picking = false
    @FocusState private var titleFocus: Bool
    @State private var search = ""

    // 2026-10-26 (owner): the main window before a call, not a settings form: one hero card with the
    // project, the title and the time, the context, the preparation, then one big Start button.
    // 2026-10-27 (owner): what the call is stays in place (header, project, title, time, who, type,
    // language); the context, the preparation and more options scroll under it.
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    IconTile(symbol: live || planOnly ? "calendar.badge.plus" : "text.bubble", size: 40)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(live || planOnly ? "Plan an upcoming call" : saved ? "Upcoming call" : "Start a call").font(.title2.weight(.semibold))
                        if live || saved || planOnly {
                            Text("Set it up and prepare it now; it starts only when you switch to it.")
                                .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                        }
                    }
                    Spacer()
                }
                if live { liveBanner }
                calendarStrip
                hero
                HStack(spacing: 10) {
                    ChoicePill(symbol: "person.2", label: ["auto": "Auto", "team": "Team", "client": "Client"][model.audience] ?? "Auto",
                               help: "Who is on the other side of the call") { close in
                        OptionList(options: [("auto", "Auto", "Detected from who speaks."),
                                             ("team", "Team", "An internal call: no corrections of your facts."),
                                             ("client", "Client", "Stricter: internal numbers are never shown, the client's culture profile is used.")],
                                   selection: $model.audience, close: close)
                    }
                    ChoicePill(symbol: "rectangle.3.group", label: ["auto": "Regular", "presentation": "Presentation", "interview": "Interview"][model.callType] ?? "Regular",
                               help: "Meeting type") { close in
                        OptionList(options: [("auto", "Regular", "A usual meeting; talk and discussion are told apart by themselves."),
                                             ("presentation", "Presentation", "Your talk with an outline; best with a preparation."),
                                             ("interview", "Interview", "A hiring interview; choose your role in More options.")],
                                   selection: $model.callType, close: close)
                    }
                    ChoicePill(symbol: "globe", label: Languages.label(model.language.split(separator: "+").map(String.init)),
                               help: "Languages spoken on the call") { _ in
                        LanguagePicker(codes: Binding(get: { model.language.split(separator: "+").map(String.init) },
                                                      set: { model.language = $0.joined(separator: "+"); model.languageTouched = true }))
                    }
                }
            }
            .padding(.horizontal, 28).padding(.top, 16).padding(.bottom, 14)
            .background(Color.secondary.opacity(0.04))
            .overlay(alignment: .bottom) { Divider() }
            ScrollView {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("What matters on this call", systemImage: "text.alignleft").font(.callout.weight(.medium))
                        TextEditor(text: $model.context)
                            .font(.callout)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
                            .frame(height: 96)
                        folderChips
                        Text(model.useProjectFolder ? "The project folder is included; add folders or single files with this call's documents." : "The project folder is left out; only the added folders and files are read.")
                            .font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(1)
                        Text("Names after \u{201C}\(StartCallModel.uiLang == "uk" ? "Учасники:" : "Participants:")\u{201D} are the speakers offered on the call. Empty lines are not sent.")
                            .font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                    }
                    .ltCard(padding: 14)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Preparation", systemImage: "doc.badge.clock").font(.callout.weight(.medium))
                            Spacer()
                            Text(runner.useAPI ? "\(runner.model.capitalized) · API key" : "\(runner.model.capitalized) · Claude account")
                                .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                        }
                        prepStatus
                        if !model.prepList.isEmpty {
                            HStack(spacing: 8) {
                                Text("Use").foregroundStyle(PN.C.text3)
                                Picker("", selection: Binding(get: { model.chosenPrep ?? "" },
                                                              set: { model.chosenPrep = $0.isEmpty ? nil : $0; model.scanPrep() })) {
                                    Text("Automatic (match by call title)").tag("")
                                    ForEach(model.prepList, id: \.file) { p in
                                        Text("\(p.heading) · \(p.made.formatted(date: .abbreviated, time: .shortened))").tag(p.file)
                                    }
                                }
                                .labelsHidden().frame(maxWidth: .infinity)
                            }
                        }
                        prepActions
                    }
                    .ltCard(padding: 14)
                    DisclosureGroup(isExpanded: $advanced) {
                        Form {
                            if model.callType == "interview" {
                                Picker("Your role", selection: $model.hiringRole) {
                                    Text("Observer").tag("observer"); Text("Interviewer").tag("interviewer"); Text("Coach (I am interviewed)").tag("coach")
                                }
                                .help("Observer: you watch someone interview a candidate; tips show each question and what a strong answer has. Interviewer: you ask; tips give the next question and follow-ups. Coach: you are the one being interviewed; tips give a structure and an opening sentence for your answer.")
                            }
                            Picker("Tip model", selection: $model.tipModel) {
                                Text("Default (\(prettyModel(AppConfig.load(from: AppPaths.config).models.tip)))").tag("")
                                ForEach(model.tipModelChoices, id: \.self) { id in Text(prettyModel(id) + "  " + id).tag(id) }
                            }
                            .help("For this call only. Settings > AI sets the default.")
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
                            .help("Your voice. System default follows macOS (AirPods, a headset or the Mac). Can be changed during the call in the tips window.")
                            Picker("Start recording", selection: $model.standby) {
                                Text("When the other side speaks").tag(true)
                                Text("Right away").tag(false)
                            }
                            .help("When the other side speaks: the window opens now and waits; recording starts when the other side speaks for a few seconds, or when you press the green Start.")
                            Toggle("Don't save new voices (webinar, strangers)", isOn: $model.publicCall)
                                .help("Speakers can still be named during the call, but no voice prints are saved. On other calls your team's voices are remembered for every project and the client's for this project only.")
                        }
                        .formStyle(.columns)
                        .padding(.top, 8)
                    } label: {
                        Label("More options", systemImage: "slider.horizontal.3").font(.callout.weight(.medium))
                    }
                    .ltCard(padding: 14)
                }
            }
            // 2026-10-27 (owner): mid-scroll the cut edge is rounded like a card, with the same gap above the button.
            .clipShape(RoundedRectangle(cornerRadius: LT.radius))
            .padding(.horizontal, 28).padding(.top, 16)
            VStack(spacing: 8) {
                if !model.note.isEmpty { Text(model.note).font(PN.Font.caption).foregroundStyle(PN.C.onMe).lineLimit(2) }
                if live || planOnly {
                    // 2026-10-27 (owner, Up next): during a call the main action keeps this call for later;
                    // switching is a separate, confirmed step.
                    LTPrimaryButton(title: saved ? "Save" : "Add to Up next", symbol: "calendar.badge.plus") { if !needProject() { onSave() } }
                        .keyboardShortcut(.defaultAction)
                    HStack(spacing: 18) {
                        Button(live ? "End current call and start this…" : "Start now", action: live ? onSwitch : onStart).buttonStyle(.pnTertiary)
                            .foregroundStyle(Color.accentColor).disabled(model.target.isEmpty)
                        if saved { Button("Remove", action: onRemove).buttonStyle(.pnTertiary).foregroundStyle(PN.C.text3) }
                        Button("Close", action: onCancel).buttonStyle(.pnTertiary).foregroundStyle(PN.C.text3)
                            .keyboardShortcut(.cancelAction)
                    }
                } else {
                    // 2026-10-28 (owner): never a dead button: without a project it opens the project list and says why.
                    LTPrimaryButton(title: "Start call", symbol: "phone.arrow.up.right") {
                        if needProject() { return }
                        onStart()
                    }
                        .keyboardShortcut(.defaultAction)
                    HStack(spacing: 18) {
                        Button(saved ? "Save" : "Save for later", action: onSave).buttonStyle(.pnTertiary)
                            .foregroundStyle(Color.accentColor).disabled(model.target.isEmpty)
                            .help("Keep this call in Up next: set it up and prepare it now, start it later.")
                        if saved { Button("Remove", action: onRemove).buttonStyle(.pnTertiary).foregroundStyle(PN.C.text3) }
                        Button("Cancel", action: onCancel).buttonStyle(.pnTertiary).foregroundStyle(PN.C.text3)
                            .keyboardShortcut(.cancelAction)
                    }
                }
            }
            .padding(.top, 16).padding(.bottom, 16)
        }
        .frame(width: 580, height: 800)
        .onAppear { model.refreshTemplate() }
        .onChange(of: model.target) { model.applyProjectDefaults(); model.scanPrep(); copied = false; if !model.target.isEmpty { model.note = "" } }
        .onAppear { model.scanPrep(); model.loadMicInputs(); PrepRunner.shared.refreshAuth() }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in model.scanPrep() }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in if !PrepRunner.shared.useAPI { PrepRunner.shared.refreshAuth() } }
    }

    var saved: Bool { upnext.contains(model) }

    /// No project or workspace yet (a new calendar meeting has none by default): open the list and say so.
    private func needProject() -> Bool {
        guard model.target.isEmpty else { return false }
        model.note = "Choose the project or workspace of this call first: its folder gets the transcript and the notes."
        search = ""; picking = true
        return true
    }

    /// 2026-10-27 (owner, calendars): the calls around now, from every calendar on this Mac. Two or three at the
    /// same time are normal (one in the calendar he skips, another he joins): the PM picks the one he goes to.
    @ObservedObject private var cal = CalendarService.shared
    static func eventHelp(_ e: CalendarService.CalEvent) -> String {
        var t: String = e.title + "\n" + e.account + " · " + e.calendar
        if !e.attendees.isEmpty { t += "\n" + e.attendees.joined(separator: ", ") }
        t += "\nClick to set up this call from the event"
        if e.recurring { t += " (and like its last call)" }
        return t
    }
    @ViewBuilder private var calendarStrip: some View {
        let evs = cal.aroundNow()
        if cal.access == .granted, !evs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Image(systemName: "calendar").foregroundStyle(PN.C.text3)
                        ForEach(evs) { e in
                            let on = model.calEventID == e.id
                            Button { model.applyEvent(e); copied = false } label: {
                                HStack(spacing: 5) {
                                    Circle().fill(Color(nsColor: e.color)).frame(width: 7, height: 7)
                                    Text(e.timeRange).monospacedDigit().foregroundStyle(PN.C.text3)
                                    Text(e.title).lineLimit(1)
                                    let rel: String = e.relative()
                                    if !rel.isEmpty && !rel.hasPrefix("ended") { Text(rel).foregroundStyle(rel == "in progress" ? PN.C.rec : PN.C.text3) }
                                    if e.recurring { Image(systemName: "repeat").foregroundStyle(PN.C.text3) }
                                }
                                .font(PN.Font.caption)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Capsule().fill(on ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.10)))
                                .overlay(Capsule().stroke(on ? Color.accentColor : .clear))
                            }
                            .buttonStyle(.plain)
                            .help(Self.eventHelp(e))
                        }
                    }
                }
                if let a = model.appliedFrom {
                    Label(a, systemImage: "arrow.uturn.backward.circle").font(PN.Font.caption).foregroundStyle(PN.C.text3)
                }
            }
        } else if cal.access == .unknown {
            HStack(spacing: 6) {
                Image(systemName: "calendar").foregroundStyle(PN.C.text3)
                Text("Pick the call from your calendars").font(PN.Font.caption).foregroundStyle(PN.C.text3)
                Button("Connect calendars") { cal.connect() }.buttonStyle(.pnTertiary).font(PN.Font.caption)
                Spacer()
            }
        } else if let a = model.appliedFrom {
            Label(a, systemImage: "arrow.uturn.backward.circle").font(PN.Font.caption).foregroundStyle(PN.C.text3)
        }
    }

    /// The call being recorded, so it is clear this window does not start a call by itself.
    private var liveBanner: some View {
        HStack(spacing: 8) {
            Circle().fill(PN.C.rec).frame(width: 8, height: 8)
            Text("Recording: \(liveTitle)").font(.callout.weight(.medium)).lineLimit(1)
            if let d = liveSince { Text(d, style: .timer).font(.callout.monospacedDigit()).foregroundStyle(PN.C.text3) }
            Spacer()
            Button("Show tips") { (NSApp.delegate as? AppDelegate)?.showTips() }.buttonStyle(.pnTertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: LT.radius).fill(PN.C.rec.opacity(0.10)))
    }

    /// The project, the call's title and its time: what the call is.
    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { search = ""; picking = true } label: {
                HStack(spacing: 12) {
                    IconTile(symbol: model.workspace != nil ? "square.stack.3d.up" : "folder", size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.project?.name ?? model.workspace?.name ?? "Choose a project")
                            .font(.headline).foregroundStyle(model.target.isEmpty ? PN.C.onMe : Color.primary)
                        Text(model.workspace != nil ? "Workspace: a general call about several projects"
                             : (model.project.map { $0.workspace.isEmpty ? "Project" : "Project in " + $0.workspace } ?? "Recordings and notes go to its folder"))
                            .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").foregroundStyle(Color.accentColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $picking, arrowEdge: .bottom) { projectPicker }
            // 2026-10-27 (owner): optional, but clearly the place to type the call's name.
            HStack(spacing: 8) {
                Image(systemName: "pencil").foregroundStyle(Color.accentColor)
                TextField("", text: $model.title, prompt: Text("Call title, e.g. Weekly sync"))
                    .textFieldStyle(.plain).font(.title3)
                    .focused($titleFocus)
                    .onChange(of: model.title) { model.scanPrep(); copied = false }
            }
            .padding(.vertical, 8).padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(titleFocus ? Color.accentColor : Color.secondary.opacity(0.25),
                                                                lineWidth: titleFocus ? 2 : 1))
            .onTapGesture { titleFocus = true }
            if let e = model.rememberedForTitle {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.backward.circle").foregroundStyle(Color.accentColor)
                    Text("A call named \u{201C}\(e.title)\u{201D} was set up before.").font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    Button("Use its settings") { model.apply(e); model.scanPrep() }.buttonStyle(.pnTertiary).font(PN.Font.caption)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "calendar").foregroundStyle(PN.C.text3)
                DatePicker("", selection: $model.callDate, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden().fixedSize()
                    .onChange(of: model.callDate) { copied = false }
                Spacer()
            }
            .help("When the call is: goes into the preparation and the Notion page title.")
            if let r = model.root {
                Text(model.details).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(1).truncationMode(.tail)
                    .help(r + "\n" + model.details)
            }
        }
        .ltCard(padding: 16)
    }

    /// Folders and files added for this call, as removable chips, and the Add folder or file button.
    private var folderChips: some View {
        VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .center, spacing: 6) {
            Button { model.addFolders() } label: { Label("Add folder or file", systemImage: "folder.badge.plus") }
                .buttonStyle(.pnTertiary).disabled(model.target.isEmpty)
            ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if let r = model.root {
                            HStack(spacing: 4) {
                                Image(systemName: "folder").font(PN.Font.caption)
                                Text((r as NSString).lastPathComponent).font(PN.Font.caption).lineLimit(1)
                                    .strikethrough(!model.useProjectFolder)
                                Button { model.useProjectFolder.toggle() } label: {
                                    Image(systemName: model.useProjectFolder ? "xmark" : "plus").font(PN.Font.caption)
                                }
                                .buttonStyle(.plain)
                            }
                            .foregroundStyle(model.useProjectFolder ? Color.accentColor : .secondary)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(model.useProjectFolder ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12)))
                            .help(model.useProjectFolder ? "The project folder: " + r + "\nIts files and earlier calls are read for the preparation. × leaves it out for this call."
                                                          : "Left out: the preparation will not read this folder (only the new files are written into its live folder). + brings it back.")
                        }
                        ForEach(model.folders, id: \.self) { f in
                            HStack(spacing: 4) {
                                Image(systemName: StartCallModel.isDir(f) ? "folder" : "doc").font(PN.Font.caption)
                                Text((f as NSString).lastPathComponent).font(PN.Font.caption).lineLimit(1)
                                Button { model.folders.removeAll { $0 == f } } label: { Image(systemName: "xmark").font(PN.Font.caption) }
                                    .buttonStyle(.plain).foregroundStyle(PN.C.text3)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                            .help(f)
                        }
                    }
            }
        }
        }
    }

    private var projectPicker: some View {
        let q = search.lowercased()
        let ws = model.registry.workspaces.filter { q.isEmpty || $0.name.lowercased().contains(q) }
        let ps = model.registry.projects.filter { $0.status != "archived" && (q.isEmpty || $0.name.lowercased().contains(q)) }
        return VStack(alignment: .leading, spacing: 6) {
            TextField("", text: $search, prompt: Text("Find a project")).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !ps.isEmpty { Text("Projects").font(PN.Font.caption).foregroundStyle(PN.C.text3).padding(.top, 4) }
                    ForEach(ps, id: \.slug) { p in pickRow("folder", p.name, p.workspace, "project:" + p.slug) }
                    if !ws.isEmpty { Text("Workspaces").font(PN.Font.caption).foregroundStyle(PN.C.text3).padding(.top, 6) }
                    ForEach(ws, id: \.name) { w in pickRow("square.stack.3d.up", w.name, "general calls", "workspace:" + w.name) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(width: 340, height: 360)
    }

    private func pickRow(_ symbol: String, _ name: String, _ sub: String, _ tag: String) -> some View {
        Button { model.target = tag; picking = false } label: {
            HStack(spacing: 10) {
                IconTile(symbol: symbol, size: 26)
                Text(name)
                if !sub.isEmpty { Text(sub).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
                Spacer()
                if model.target == tag { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(model.target == tag ? Color.accentColor.opacity(0.15) : .clear))
        }
        .buttonStyle(.plain)
    }

    // 2026-10-27 (owner): three equal controls, tinted because they are clickable.
    private func pill<C: View>(_ symbol: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(Color.accentColor).frame(width: 18)
            content().frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: LT.radius).fill(Color.accentColor.opacity(0.10)))
    }

    /// One line: found, being written, for another call, or none.
    @ViewBuilder private var prepStatus: some View {
        if runner.running, runner.callID == model.id {
            Label("Being written: \(runner.stage.lowercased())…", systemImage: "hourglass").foregroundStyle(PN.C.text3)
        } else if upnext.prepState(model) == .queued {
            Label("Waiting in line: starts when the preparation in progress is done.", systemImage: "clock").foregroundStyle(PN.C.text3)
        } else if let p = model.prep, p.matches {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.heading).lineLimit(2)
                    HStack(spacing: 8) {
                        Text(model.chosenPrep != nil ? "Chosen by you, made \(p.made.formatted(date: .abbreviated, time: .shortened))"
                                                     : "Made \(p.made.formatted(date: .omitted, time: .shortened)); used for this call")
                            .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                        if let path = PrepDocWindow.path(for: model) {
                            Button("Read") { PrepDocWindow.show(path: path, title: model.effectiveTitle) }.buttonStyle(.pnTertiary).font(PN.Font.caption)
                                .help("Read or correct the whole preparation")
                        }
                    }
                }
            } icon: { Image(systemName: "checkmark.seal.fill").foregroundStyle(PN.C.turn) }
        } else if let p = model.prep {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No preparation for \u{201C}\(model.effectiveTitle)\u{201D} yet")
                    Text("The one made \(p.made.formatted(date: .omitted, time: .shortened)) is for another call (\(p.heading)); pick it below to use it anyway.")
                        .font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                }
            } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(PN.C.onMe) }
        } else {
            Label(model.target.isEmpty ? "Choose a project first" : "No preparation yet. Prepare now takes a few minutes. Not ready in time? Start anyway: questions to you, your turn, HELP NOW and answers from the call work without it, and a late preparation joins the call.",
                  systemImage: "doc.badge.clock").foregroundStyle(PN.C.text3).font(.callout)
        }
    }

    /// Prepare now (Claude Code) with its progress; how it runs is set in Settings > AI > Preparation.
    @ViewBuilder private var prepActions: some View {
        if runner.running && runner.callID == model.id {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("\(runner.model.capitalized): \(runner.stage)").font(.callout)
                        Text(runner.startedAt ?? Date(), style: .timer).font(.callout.monospacedDigit()).foregroundStyle(PN.C.text3)
                    }
                    ProgressView(value: runner.progress)
                    if !runner.detail.isEmpty {
                        Text(runner.detail).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(1).truncationMode(.middle)
                    }
                }
                Button("Stop") { runner.cancel() }.controlSize(.small)
            }
        } else {
            HStack(spacing: 10) {
                Button {
                    // 2026-10-27 (Up next): one preparation runs at a time; the others wait in line.
                    model.note = upnext.prepare(model) ?? ""
                    if !saved && model.note.isEmpty { upnext.save(model) }   // kept in Up next (tracked as prepared until the call); the window stays
                } label: { Label(runner.running ? "Prepare (after the current one)" : "Prepare now", systemImage: "sparkles") }
                .buttonStyle(.pnSecondary)
                .disabled(model.target.isEmpty || PrepRunner.claudePath == nil || (!runner.useAPI && runner.loggedIn == false)
                          || upnext.prepState(model) == .queued)
                .help("Claude Code builds the preparation here from local files: the documents named in the context, the folders above, the local Notion mirror, earlier calls and public web links in the context. A few minutes; you can close this window.")
                Menu {
                    Button(copied ? "Copied" : "Copy request for Cowork") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.prepPhrase, forType: .string)
                        copied = true
                    }
                    Button("Preparation settings…") { SettingsWindow.show(tab: "ai") }
                } label: { Text("More") }
                .menuStyle(.borderlessButton).tint(.accentColor).fixedSize().disabled(model.target.isEmpty)
                Spacer()
            }
            if upnext.prepState(model) == .queued {
                HStack {
                    Text("In line after: \(runner.target)").font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(1).truncationMode(.middle)
                    Button("Take out of line") { upnext.unqueue(model) }.controlSize(.small)
                }
            } else if runner.running {
                Text("Another call is being prepared (\(runner.stage.lowercased())); this one starts after it.")
                    .font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            }
            if PrepRunner.claudePath == nil {
                Text("Claude Code is not installed: use More > Copy request for Cowork.").font(PN.Font.caption).foregroundStyle(PN.C.text3)
            } else if !runner.useAPI && runner.loggedIn == false {
                HStack(spacing: 8) {
                    Label("Claude Code is not signed in", systemImage: "exclamationmark.triangle.fill").font(PN.Font.caption).foregroundStyle(PN.C.onMe)
                    Spacer()
                    Button("Log in…") { runner.openLogin() }.controlSize(.small)
                    Button("Use API key") { runner.useAPI = true }.controlSize(.small).disabled(!runner.hasAPIKey)
                    Button("Check") { runner.refreshAuth() }.controlSize(.small)
                }
            } else if runner.useAPI && !runner.hasAPIKey {
                Text("No Claude API key: add it in Settings > Keys.").font(PN.Font.caption).foregroundStyle(PN.C.onMe)
            }
            if !runner.result.isEmpty { Text(runner.result).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
        }
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
    static var model: StartCallModel?

    /// 2026-10-27 (owner, Up next): while a call is live this window plans an upcoming call: Add to Up next,
    /// Prepare, or End current call and start this (confirmed). Without a live call it starts a call as before,
    /// and Save for later keeps the call in Up next.
    static func show(delegate: AppDelegate, prepared: StartCallModel? = nil, planOnly: Bool = false) {
        let model = prepared ?? StartCallModel()
        Self.model = model
        let live = delegate.callIsLive
        let liveTitle = CallEngine.shared.renamed ?? (CallEngine.shared.callRequest["title"] as? String) ?? "the current call"
        let since = EngineStatus.load(path: CallEngine.shared.statusPath).startedAt.flatMap { ISO8601DateFormatter().date(from: $0) }
        let view = StartCallView(model: model, live: live, planOnly: planOnly && !live, liveTitle: liveTitle, liveSince: since, onStart: {
            if let err = delegate.launch(model) { model.note = err } else { window?.close() }
        }, onCancel: {
            // A call with a preparation running or waiting is kept, so the preparation is not lost.
            if live, !UpNext.shared.contains(model), [.running, .queued].contains(UpNext.shared.prepState(model)) { UpNext.shared.save(model) }
            window?.close()
        }, onSave: {
            guard !model.target.isEmpty else { return }
            UpNext.shared.save(model)
            model.note = ""
            window?.close()
        }, onSwitch: {
            UpNext.shared.save(model)
            delegate.confirmSwitch(to: model, on: window)
        }, onRemove: {
            UpNext.shared.remove(model)
            window?.close()
        })
        let host = NSHostingController(rootView: view)
        let w = window ?? NSWindow(contentViewController: host)
        w.contentViewController = host
        w.styleMask.insert(.resizable)
        w.setContentSize(NSSize(width: 580, height: 800))
        w.title = live || planOnly ? "Plan an upcoming call" : "Start call"
        w.isReleasedWhenClosed = false
        window = w
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Up next: start, switch (2026-10-27, owner)

extension AppDelegate {
    /// A call is being recorded or waits for the other side (also a call the app lost track of).
    var callIsLive: Bool {
        CallEngine.shared.isRunning || ["recording", "standby", "loading_model"].contains(EngineStatus.load(path: CallEngine.shared.statusPath).state)
    }

    /// Starts a call set up in Start call or kept in Up next. Its finished preparation is used by name; one still
    /// being written joins the call when done. Returns an error line, or nil.
    @MainActor
    func launch(_ model: StartCallModel) -> String? {
        if model.chosenPrep == nil { model.adoptExistingPrep() }
        if model.chosenPrep == nil, let b = model.prepBase, let root = model.root {
            let name = (b as NSString).lastPathComponent + ".brief.md"
            if FileManager.default.fileExists(atPath: ((root as NSString).appendingPathComponent("live") as NSString).appendingPathComponent(name)) {
                model.chosenPrep = name
            }
        }
        guard let req = model.requestJSON() else { return model.note.isEmpty ? "This call cannot start yet." : model.note }
        let before = CallEngine.shared.currentCallID
        CallEngine.shared.currentCallID = model.id
        let err = CallEngine.shared.start(request: req, apiAllowed: model.project?.apiAllowed ?? true) { [weak self] st in
            self?.openTips(for: CallFiles(tips: st.tipsFile ?? "", inbox: st.inboxFile ?? "",
                                          status: CallEngine.shared.statusPath,
                                          control: (CallEngine.shared.appRoot as NSString).appendingPathComponent("control")))
        }
        if err != nil { CallEngine.shared.currentCallID = before; return err }
        UpNext.shared.remove(model, keepPrep: true)
        UpNext.shared.removeMatching(model)          // 2026-10-28: no second entry of the call just started
        CallEngine.shared.liveEventID = model.calEventID
        SeriesMemory.shared.remember(model)          // the next call of this series starts from these settings
        return nil
    }

    /// "End current call and start this…": one question, then the switch.
    @MainActor
    func confirmSwitch(to model: StartCallModel, on window: NSWindow?) {
        guard callIsLive else {
            if let e = launch(model) { model.note = e } else { StartCallWindow.window?.close() }
            return
        }
        let cur = CallEngine.shared.renamed ?? (CallEngine.shared.callRequest["title"] as? String) ?? "the current call"
        let next = model.effectiveTitle
        let a = NSAlert()
        a.messageText = "End \u{201C}\(cur)\u{201D} and start \u{201C}\(next)\u{201D}?"
        var info = "Recording stops now. The transcript is saved and the Notion summary is written in the background. "
        info += model.standby ? "\(next) opens right away and records when the other side speaks or you press Start." : "\(next) starts recording right away."
        switch UpNext.shared.prepState(model) {
        case .running: info += "\n\nIts preparation is \(Int(PrepRunner.shared.progress * 100))% done; it goes on and joins the call when ready."
        case .queued: info += "\n\nIts preparation is waiting in line; it joins the call when ready."
        case .failed: info += "\n\nIts preparation failed; the call starts without it."
        case .none: info += "\n\nNo preparation: questions to you, HELP NOW and answers from the call still work."
        case .ready: break
        }
        a.informativeText = info
        a.addButton(withTitle: "End and start")
        a.addButton(withTitle: "Cancel")
        let go: () -> Void = { [weak self] in self?.performSwitch(to: model) }
        if let w = window, w.isVisible {
            a.beginSheetModal(for: w) { r in if r == .alertFirstButtonReturn { MainActor.assumeIsolated { go() } } }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertFirstButtonReturn { go() }
        }
    }

    /// Ends the live call properly and starts `model` as soon as the recorder has stopped.
    @MainActor
    func performSwitch(to model: StartCallModel) {
        StartCallWindow.window?.close()
        guard callIsLive else { if let e = launch(model) { notifySwitchFailed(e, model) }; return }
        UpNext.shared.switchingTo = model
        let owned = CallEngine.shared.isRunning
        CallEngine.shared.stop()
        tips?.markEnding()
        if !owned {
            CallEngine.shared.finishOrphan { [weak self] _, _ in MainActor.assumeIsolated { self?.finishSwitch() } }
        }
        // The recorder normally stops in a few seconds; if it does not, say so instead of waiting forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
            MainActor.assumeIsolated {
                guard let m = UpNext.shared.switchingTo, m === model else { return }
                UpNext.shared.switchingTo = nil
                self?.notifySwitchFailed("The current call did not stop in 45 s. End it in the tips window, then start \u{201C}\(model.effectiveTitle)\u{201D} from Up next.", model)
            }
        }
    }

    /// Called when the recorder of the old call has stopped (CallEngine.callEnded or the orphan finish).
    @MainActor
    func finishSwitch() {
        guard let m = UpNext.shared.switchingTo else { return }
        UpNext.shared.switchingTo = nil
        // A moment for the old call's wrap-up (Notion summary, rating) to read that call's settings first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                if let e = self.launch(m) { self.notifySwitchFailed(e, m) }
            }
        }
    }

    @MainActor
    func notifySwitchFailed(_ text: String, _ model: StartCallModel) {
        UpNext.shared.save(model)
        let a = NSAlert()
        a.messageText = "\u{201C}\(model.effectiveTitle)\u{201D} did not start"
        a.informativeText = text + "\n\nIt stays in Up next."
        a.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    /// The menu's Up next submenu: each call opens for editing, switching or starting.
    @MainActor
    func rebuildUpNextMenu() {
        let items = UpNext.shared.visible
        upNextItem.isHidden = items.isEmpty
        upNextItem.title = L("menubar.upNextCount", ["n": "\(items.count)"])
        let m = NSMenu()
        let f = DateFormatter(); f.dateFormat = "d MMM HH:mm"
        for c in items {
            let st = UpNext.shared.prepState(c)
            let mark = ["ready", "running", "queued", "failed"].contains(st.rawValue) ? " · " + L("menubar.upNext." + st.rawValue) : ""
            let it = NSMenuItem(title: "\(c.effectiveTitle) · \(f.string(from: c.callDate))\(mark)", action: #selector(openUpNext(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = c.id.uuidString
            m.addItem(it)
        }
        upNextItem.submenu = m
    }

    @objc func openUpNext(_ sender: NSMenuItem) {
        MainActor.assumeIsolated {
            if let id = sender.representedObject as? String, let c = UpNext.shared.item(id) { StartCallWindow.show(delegate: self, prepared: c) }
        }
    }
}

// MARK: - Pacenote 0.8 (F0): menu language and the recording clock

extension AppDelegate {
    /// The menu follows the interface language (Settings > General) without a restart.
    func relabelMenu() {
        guard menuLang != L10n.lang else { return }
        menuLang = L10n.lang
        homeItem.title = L("menubar.home"); tipsItem.title = L("menubar.showTips"); pauseItem.title = L("menubar.pause")
        helpItem.title = L("menubar.helpNow"); endItem.title = L("menubar.endCall"); notionItem.title = L("menubar.sendNotion")
        micItem.title = L("menubar.allowMic"); settingsItem.title = L("menubar.settings"); setupItem.title = L("menubar.setup")
        tourItem.title = L("menubar.welcomeTour"); aboutItem.title = L("menubar.about"); quitItem.title = L("menubar.quit")
        demoItem.title = L("menubar.demo"); demoPresItem.title = L("menubar.demoPresentation")
        item?.button?.toolTip = L("menubar.tooltip")
        installMainMenu()
    }

    /// Time since the recording started, "32:14" or "1:02:05".
    static func elapsed(_ st: EngineStatus) -> String {
        guard let s = st.startedAt, let d = ISO8601DateFormatter().date(from: s) else { return "00:00" }
        let t = max(0, Int(Date().timeIntervalSince(d)))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t % 3600 / 60, t % 60)
                         : String(format: "%02d:%02d", t / 60, t % 60)
    }

    /// While recording, the elapsed time sits next to the menu bar icon and ticks every second.
    func setClock(_ on: Bool) {
        if on {
            if clock == nil {
                clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tickClock() }
            }
            tickClock()
        } else if clock != nil {
            clock?.invalidate()
            clock = nil
            item?.button?.title = ""
        }
    }

    func tickClock() {
        guard let b = item?.button else { return }
        b.attributedTitle = NSAttributedString(string: " " + Self.elapsed(lastStatus),
                                               attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)])
    }
}
