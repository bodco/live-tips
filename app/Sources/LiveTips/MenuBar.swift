import AppKit
import AVFoundation
import LiveTipsCore
import SwiftUI
import Combine

/// Menu bar item and the main app delegate: live status, spending against limits, Start call,
/// tips window, settings. The Dock icon is on by default so the app is visible even when the
/// menu bar is full.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem?
    var tips: PrompterController?
    var timer: Timer?
    var panel: MenuBarPanelController?      // Pacenote 0.8 (F1): the menu bar panel instead of an NSMenu
    var menuLang = L10n.lang
    var clock: Timer?               // the elapsed time next to the menu bar icon while recording
    var lastStatus = EngineStatus()

    var config: AppConfig { AppConfig.load(from: AppPaths.config) }
    var appRoot: String { config.effectiveAppRoot(appSupport: AppPaths.support.path) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppSignature.shared.check() }     // 2026-10-29: onboarding and About show it
        SetupModel.repairEnginePaths()      // 0.8.3: the engine follows the app after a rename or a move
        installMainMenu()
        NSApp.setActivationPolicy(config.showInDock ? .regular : .accessory)
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        it.button?.image = Brand.menuBarImage(recording: false)     // Pacenote 0.8: the brand template
        it.button?.imagePosition = .imageLeft
        it.button?.toolTip = L("menubar.tooltip")
        it.button?.target = self
        it.button?.action = #selector(statusItemClicked(_:))
        it.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        it.button?.setAccessibilityLabel(L("app.name"))
        item = it
        MainActor.assumeIsolated { panel = MenuBarPanelController(app: self, button: it.button) }
        refresh()
        MainActor.assumeIsolated { LocalAIService.shared.apply() }
        NotionMirrorService.shared.startSchedule()
        MainActor.assumeIsolated { AutoStart.shared.start() }      // Pacenote 0.8: offer to start tips when a call begins
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
        HotKeys.shared.install(help: { [weak self] in self?.helpNow() }, pause: { [weak self] in self?.togglePause() },
                               mute: { [weak self] in self?.toggleMute() }, compact: { [weak self] in self?.toggleCompact() },
                               proactive: { [weak self] in self?.pushTips("window.LiveTips && LiveTips.toggleProactive()") },
                               present: { [weak self] k in self?.pushTips("window.LiveTips && LiveTips.presentKey('\(k)')") })
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
        // Pacenote 0.8 (F1): Home and Start a call are app commands too, not only rows of the menu bar panel.
        appMenu.addItem(withTitle: L("menubar.home"), action: #selector(openHome), keyEquivalent: "0").target = self
        appMenu.addItem(withTitle: L("menubar.startCall"), action: #selector(startCall), keyEquivalent: "n").target = self
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
        // Pacenote 0.8 (F4): Help > How Pacenote works (it left Settings).
        let helpItem = NSMenuItem()
        main.addItem(helpItem)
        let help = NSMenu(title: L("menu.help"))
        help.addItem(withTitle: L("settings.how.title"), action: #selector(openHowItWorks), keyEquivalent: "").target = self
        helpItem.submenu = help
        NSApp.helpMenu = help
        NSApp.mainMenu = main
    }

    @objc func statusItemClicked(_ sender: Any?) {
        refresh()
        MainActor.assumeIsolated { panel?.toggle() }
    }

    func refresh() {
        let cfg = config
        IndexService.shared.configure(projects: ProjectRegistry.load(from: AppPaths.projects).projects, appRoot: appRoot,
                                      python: cfg.engine.python, enabled: cfg.localAI.enabled)
        let st = EngineStatus.load(path: (appRoot as NSString).appendingPathComponent("state/status.json"))
        let month = SpendLedger.monthSpent()
        lastStatus = st
        warnIfNoAudio(st)
        if menuLang != L10n.lang { menuLang = L10n.lang; installMainMenu() }     // the app menu follows the language
        MainActor.assumeIsolated { fillPanel(st, month: month, cfg: cfg) }
        item?.button?.image = Brand.menuBarImage(recording: st.state == "recording")
        setClock(st.state == "recording")
        // Orange near a spending limit; no red tint while recording: the filled dot and the clock say it.
        item?.button?.contentTintColor = (st.callSpentUSD >= cfg.budget.callSoftUSD || month >= cfg.budget.monthlyHardUSD * 0.9) ? .systemOrange : nil
    }

    /// The menu bar panel's data (Pacenote 0.8, F1).
    @MainActor func fillPanel(_ st: EngineStatus, month: Double, cfg: AppConfig) {
        guard let m = panel?.model else { return }
        let ce = CallEngine.shared
        m.isRecording = st.state == "recording"
        m.isLive = ce.isRunning || ["recording", "standby", "loading_model"].contains(st.state)
        m.elapsed = Self.elapsed(st)
        let failing = noAudioWarned != nil && noAudioWarned == st.file && st.lines == 0 && ["recording", "standby"].contains(st.state)
        m.warning = failing
        m.statusLine = st.state == "standby" ? L("menubar.status.waiting") : ""
        m.liveTitle = ce.renamed ?? (ce.callRequest["title"] as? String) ?? st.project ?? L("app.name")
        let callLine = st.state == "recording"
            ? L("menubar.status.callLine", ["lines": "\(st.lines)", "tips": "\(st.tips)",
                                            "cost": String(format: "%.2f", st.callSpentUSD), "cap": String(format: "%.0f", cfg.budget.callHardUSD)])
            : ""
        m.liveLine = failing ? L("menubar.status.audioFailing") : [st.project ?? "", callLine].filter { !$0.isEmpty }.joined(separator: " · ")
        let calls = AheadCall.list().map { a -> MenuBarModel.Call in
            let target = a.model.map { $0.target.isEmpty ? "" : $0.targetName } ?? ""
            let note = [target, a.event?.timeRange ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
            return MenuBarModel.Call(id: a.id, title: a.title, startsAt: a.start,
                                     state: a.model.map { UpNext.shared.prepState($0) } ?? .none, note: note, ahead: a)
        }
        m.next = calls.first
        m.later = Array(calls.dropFirst().prefix(2))
        m.monthSpend = month
        m.monthCap = cfg.budget.monthlyHardUSD
        // 2026-10-26 (owner): the last call's cost; the tip rating only when that developer check is on.
        let judge = cfg.judgeAfterCall ? (ce.judgeRunning != nil ? "rating the tips…" : ce.judgeResult) : ""
        m.lastCallLine = [ce.lastCallLine, judge].filter { !$0.isEmpty }.joined(separator: " · ")
        m.lastCallDetail = ce.lastCallDetail
        m.thisCallSpend = st.callSpentUSD
        m.canSendNotion = !m.isLive && (ce.lastFile != nil || (!ce.isRunning && ce.restoreLastCall()))
        m.notionResult = ce.notionResult
        m.micMissing = AVCaptureDevice.authorizationStatus(for: .audio) != .authorized
        m.helpKey = HotKeys.shared.combo(.help).display
        m.pauseKey = HotKeys.shared.combo(.pause).display
        m.compactKey = HotKeys.shared.combo(.compact).display
        panel?.place()
    }

    @objc func startCall() { MainActor.assumeIsolated { StartCallWindow.show(delegate: self) } }
    @objc func openHome() { MainActor.assumeIsolated { HomeWindow.show(delegate: self) } }
    @objc func sendToNotion() {
        guard !CallEngine.shared.isRunning, CallEngine.shared.restoreLastCall(), let f = CallEngine.shared.lastFile else { return }
        CallEngine.shared.writeToNotion(file: f)
    }
    @objc func openSetup() { MainActor.assumeIsolated { SetupWindow.show() } }
    @objc func openOnboarding() { MainActor.assumeIsolated { OnboardingWindow.show() } }
    @objc func openSettings() { MainActor.assumeIsolated { SettingsWindow.show() } }
    @objc func openHowItWorks() { MainActor.assumeIsolated { HowItWorksWindow.show() } }
    @objc func openAbout() { MainActor.assumeIsolated { SettingsWindow.show(tab: "about") } }
    @objc func openSettingsTab() { MainActor.assumeIsolated { SettingsWindow.show() } }

    /// Same as the tips window's own controls (the window owns the pause and mic state). Pacenote 0.8 (F2).
    @objc func togglePause() { pushTips("window.LiveTips && LiveTips.togglePause()") }
    @objc func helpNow() { pushTips("window.LiveTips && LiveTips.help()") }
    @objc func toggleMute() { pushTips("window.LiveTips && LiveTips.toggleMute()") }
    @objc func toggleCompact() {
        guard lastStatus.state == "recording" || lastStatus.state == "standby" else { return }
        if tips == nil { showTips() }
        MainActor.assumeIsolated { tips?.toggleCompact() }
    }
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
            a.html = Bundle.main.resourceURL?.appendingPathComponent("tips/index.html").path ?? ""
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
    /// 0.8.5 (P2): the deck of a Presentation call, its speakers, slide owners and timing.
    @Published var deck = DeckSetup()
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
        p.message = L("call.pickMessage")
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

    var targetName: String { project?.name ?? workspace?.name ?? L("call.theProject") }

    /// "Prepare now": the request for Claude Code (PrepRunner).
    func prepRequest() -> PrepRunner.Request? {
        guard let root = root, !root.isEmpty else { return nil }
        let ws = workspace ?? registry.workspaces.first { w in w.projects.contains(project?.slug ?? "\u{0}") }
        return PrepRunner.Request(title: effectiveTitle, date: callDate, projectName: targetName,
                                  slug: project?.slug ?? workspace?.name.lowercased() ?? "", root: root,
                                  config: project?.config ?? "", audience: audience, callType: callType, hiringRole: hiringRole,
                                  languages: language.split(separator: "+").map(String.init), context: cleanContext,
                                  workspaceRoot: (ws?.root == root) ? "" : (ws?.root ?? ""), folders: folders,
                                  useProjectFolder: useProjectFolder, callID: id,
                                  deck: callType == "presentation" && deck.info != nil ? deck : nil)
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
            parts.append(L("call.det.people", ["team": "\(team)", "client": "\(client)"]))
            parts.append(p.apiAllowed ? L("call.det.claudeOn") : L("call.det.localOnly"))
        } else if let w = workspace {
            parts.append(L("call.det.projects") + w.projects.joined(separator: ", "))
        } else { return "" }
        let rel = RelativeDateTimeFormatter()
        if let s = registry.lastUsedAt[target], let d = ISO8601DateFormatter().date(from: s) {
            parts.append(L("call.det.lastCall") + rel.localizedString(for: d, relativeTo: Date()))
        } else {
            parts.append(L("call.det.first"))
        }
        let cfg = AppConfig.load(from: AppPaths.config)
        if !cfg.workRoot.isEmpty {
            let st = MirrorStatus.load(workRoot: cfg.workRoot)
            switch st.health() {
            case "ok", "stale": parts.append(L("call.det.mirror") + rel.localizedString(for: st.lastRunUTC ?? Date(), relativeTo: Date()) + (st.health() == "stale" ? L("call.det.stale") : ""))
            case "failed": parts.append(L("call.det.mirrorFailed"))
            default: parts.append(L("call.det.noMirror"))
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
        guard let root = root, !root.isEmpty else { note = L("call.noFolder"); return nil }
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

// StartCallView moved to CallSetup.swift as CallSetupView (Pacenote 0.8, F4).


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
        guard let req = model.requestJSON() else { return model.note.isEmpty ? L("call.cannotStart") : model.note }
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
        let cur = CallEngine.shared.renamed ?? (CallEngine.shared.callRequest["title"] as? String) ?? L("sw.current")
        let next = model.effectiveTitle
        let a = NSAlert()
        a.messageText = L("sw.title", ["cur": cur, "next": next])
        var info = L("sw.stops")
        info += model.standby ? L("sw.standby", ["next": next]) : L("sw.now", ["next": next])
        switch UpNext.shared.prepState(model) {
        case .running: info += "\n\n" + L("sw.prepRunning", ["pct": "\(Int(PrepRunner.shared.progress * 100))"])
        case .queued: info += "\n\n" + L("sw.prepQueued")
        case .failed: info += "\n\n" + L("sw.prepFailed")
        case .none: info += "\n\n" + L("sw.prepNone")
        case .ready: break
        }
        a.informativeText = info
        a.addButton(withTitle: L("sw.endStart"))
        a.addButton(withTitle: L("hk.cancel"))
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
                self?.notifySwitchFailed(L("sw.stuck", ["next": model.effectiveTitle]), model)
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
}

// MARK: - Pacenote 0.8: the recording clock

extension AppDelegate {
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
        MainActor.assumeIsolated { panel?.model.elapsed = Self.elapsed(lastStatus) }
        guard let b = item?.button else { return }
        b.attributedTitle = NSAttributedString(string: " " + Self.elapsed(lastStatus),
                                               attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)])
    }
}
