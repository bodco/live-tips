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
        updateCoreIfNeeded()
        HotKeys.shared.install(help: { [weak self] in self?.helpNow() }, pause: { [weak self] in self?.togglePause() })
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        if !CallEngine.shared.problems().isEmpty { MainActor.assumeIsolated { SetupWindow.show() } }
        if !UserDefaults.standard.bool(forKey: "onboarded") {
            UserDefaults.standard.set(true, forKey: "onboarded")
            openSettings()
        }
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
        warnIfNoAudio(st)
        startItem.isHidden = recording
        endItem.isHidden = !recording
        pauseItem.isHidden = st.state != "recording"
        helpItem.isHidden = st.state != "recording"
        tipsItem.title = recording ? "Open tips window" : "Preview tips window"
        notionItem.isHidden = recording || CallEngine.shared.lastFile == nil
        notionItem.toolTip = CallEngine.shared.notionResult
        statusLines[0].title = st.state == "standby" ? "○ Waiting for the call" + (st.project.map { ": \($0)" } ?? "")
            : recording ? "● Recording" + (st.project.map { ": \($0)" } ?? "")
            : (CallEngine.shared.lastCallSummary.isEmpty ? "Not recording" : CallEngine.shared.lastCallSummary)
        if noAudioWarned != nil, noAudioWarned == st.file, st.lines == 0, ["recording", "standby"].contains(st.state) {
            statusLines[0].title = "⚠ Not recording: the audio helper keeps failing. End the call and start again"
        }
        statusLines[1].title = String(format: "Lines %d · tips %d · this call $%.2f of $%.0f", st.lines, st.tips, st.callSpentUSD, cfg.budget.callHardUSD)
        statusLines[1].isHidden = !recording
        let judge = cfg.judgeAfterCall ? CallEngine.shared.judgeResult : ""
        statusLines[2].title = CallEngine.shared.judgeRunning != nil ? "Rating the last call's tips..." : judge
        statusLines[2].isHidden = recording || (judge.isEmpty && CallEngine.shared.judgeRunning == nil)
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
        let item: [String: Any] = ["kind": "tip", "level": "red", "gist": "⚠ Запис не йде: аудіо не захоплюється",
                                   "items": ["Заверши дзвінок і почни знову: Live Tips перевірить аудіо-помічник перед стартом."],
                                   "t": DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)]
        if let d = try? JSONSerialization.data(withJSONObject: [item]), let js = String(data: d, encoding: .utf8) {
            if tips == nil { showTips() }
            MainActor.assumeIsolated { tips?.push("window.addItems && window.addItems(\(js))") }
        }
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
    @Published var publicCall = false            // D3: a webinar or an event with strangers: new voices are not saved
    @Published var hiringRole = "observer"      // interview: observer | interviewer | coach (as in the skill)
    @Published var tipModel = ""                // "" = the model from Settings > AI
    @Published var language = "uk"
    @Published var note = ""
    /// 2026-10-26 (owner): a template instead of an empty field; empty lines of it are not sent.
    static let contextTemplate = "Мета: \nУчасники: \nВідкриті питання: \nДе дивитись (документи, тікети): "
    @Published var context = StartCallModel.contextTemplate
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
                if next == nil || isHeader(next!) || StartCallModel.contextTemplate.contains(next!) { continue }
            }
            out.append(t)
        }
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
                                  workspaceRoot: (ws?.root == root) ? "" : (ws?.root ?? ""))
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
                "context": cleanContext, "participants": participants, "pm_projects": pmProjects,
                "workspace": workspace?.name ?? registry.workspaces.first { w in w.projects.contains(project?.slug ?? "\u{0}") }?.name ?? "",
                "scheduled_at": ISO8601DateFormatter().string(from: callDate), "mic_device": micDevice, "standby": standby,
                "project_config": project?.config ?? "", "people": people, "people_team": peopleTeam,
                "voices_remember": !publicCall, "prep_file": chosenPrepPath ?? ""]
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
    var onStart: () -> Void
    var onCancel: () -> Void
    @State private var copied = false

    @AppStorage("startCallAdvanced") private var advanced = false

    var body: some View {
        VStack(spacing: 0) {
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
                    TextField("Title", text: $model.title, prompt: Text("e.g. Weekly sync with the client"))
                        .onChange(of: model.title) { model.scanPrep(); copied = false }
                    DatePicker("Date and time", selection: $model.callDate, displayedComponents: [.date, .hourAndMinute])
                        .help("When the call is. Goes into the preparation request.")
                        .onChange(of: model.callDate) { copied = false }
                    if let r = model.root {
                        Text(model.details).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                            .help(r + "\n" + model.details)
                    }
                }
                Section {
                    TextEditor(text: $model.context)
                        .font(.callout)
                        .scrollContentBackground(.hidden)
                        .frame(height: 84)
                } header: {
                    Text("Call context")
                } footer: {
                    Text("Empty lines are not sent. Names after \u{201C}Учасники:\u{201D} or \u{201C}Participants:\u{201D} are the speakers offered on the call.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    prepStatus
                    if !model.prepList.isEmpty {
                        Picker("Use preparation", selection: Binding(get: { model.chosenPrep ?? "" },
                                                                      set: { model.chosenPrep = $0.isEmpty ? nil : $0; model.scanPrep() })) {
                            Text("Automatic (match by call title)").tag("")
                            ForEach(model.prepList, id: \.file) { p in
                                Text("\(p.heading) · \(p.made.formatted(date: .abbreviated, time: .shortened))").tag(p.file)
                            }
                        }
                    }
                    prepActions
                } header: { Text("Preparation") }
                Section {
                    Picker("Audience", selection: $model.audience) {
                        Text("Auto").tag("auto"); Text("Team").tag("team"); Text("Client").tag("client")
                    }
                    .pickerStyle(.segmented)
                    .help("Who is on the other side. Auto: detected from who speaks. Team: internal call, no corrections of your facts. Client: stricter, internal numbers are never shown, the client's culture profile is used.")
                    Picker("Languages", selection: Binding(get: { model.language }, set: { model.language = $0; model.languageTouched = true })) {
                        Text("Ukrainian").tag("uk"); Text("Ukrainian + English").tag("uk+en"); Text("English").tag("en"); Text("English + Spanish").tag("en+es")
                    }
                    .help("What may be spoken on the call; transcription is restricted to these.")
                    DisclosureGroup("Advanced", isExpanded: $advanced) {
                        Picker("Meeting type", selection: $model.callType) {
                            Text("Regular").tag("auto"); Text("Presentation").tag("presentation"); Text("Interview").tag("interview")
                        }
                        .help("Regular: a usual meeting; talk vs discussion is detected by itself. Presentation (your talk with an outline) and Interview work best with a preparation.")
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
                }
            }
            .formStyle(.grouped)
            Divider()
            // UI review 26.10: the main action never scrolls out of sight.
            HStack {
                Text(model.note).font(.caption).foregroundStyle(.orange).lineLimit(2)
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Start") { onStart() }.keyboardShortcut(.defaultAction).disabled(model.target.isEmpty)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 540, height: 720)
        .onAppear { model.scanPrep(); model.loadMicInputs(); PrepRunner.shared.refreshAuth() }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in model.scanPrep() }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in if !PrepRunner.shared.useAPI { PrepRunner.shared.refreshAuth() } }
    }

    /// One line: found, being written, for another call, or none.
    @ViewBuilder private var prepStatus: some View {
        if runner.running, let p = model.prep, p.file.hasPrefix(runner.target) {
            Label("Being written: \(runner.stage.lowercased())…", systemImage: "hourglass").foregroundStyle(.secondary)
        } else if let p = model.prep, p.matches {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.heading).lineLimit(2)
                    Text(model.chosenPrep != nil ? "Chosen by you, made \(p.made.formatted(date: .abbreviated, time: .shortened))"
                                                 : "Made \(p.made.formatted(date: .omitted, time: .shortened)); used for this call")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: "checkmark.seal.fill").foregroundStyle(.green) }
        } else if let p = model.prep {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("No preparation for \u{201C}\(model.effectiveTitle)\u{201D} yet")
                    Text("The one made \(p.made.formatted(date: .omitted, time: .shortened)) is for another call (\(p.heading)); pick it below to use it anyway.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
        } else {
            Label(model.target.isEmpty ? "Choose a project first" : "No preparation yet. Prepare now takes a few minutes, or the call starts without one.",
                  systemImage: "doc.badge.clock").foregroundStyle(.secondary).font(.callout)
        }
    }

    /// Prepare now (Claude Code) with its progress; how it runs is set in Settings > AI > Preparation.
    @ViewBuilder private var prepActions: some View {
        if runner.running {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("\(runner.model.capitalized): \(runner.stage)").font(.callout)
                        Text(runner.startedAt ?? Date(), style: .timer).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    ProgressView(value: runner.progress)
                    if !runner.detail.isEmpty {
                        Text(runner.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                Button("Stop") { runner.cancel() }.controlSize(.small)
            }
        } else {
            HStack(spacing: 8) {
                Button("Prepare now") {
                    guard let r = model.prepRequest() else { model.note = "Choose a project first."; return }
                    model.note = runner.start(r) ?? ""
                }
                .disabled(model.target.isEmpty || PrepRunner.claudePath == nil || (!runner.useAPI && runner.loggedIn == false))
                .help("Claude Code builds the preparation here from local files: the documents named in Call context, the project folder, the local Notion mirror and earlier calls. No Notion, Jira or web. A few minutes; you can close this window.")
                Menu("More") {
                    Button(copied ? "Copied" : "Copy request for Cowork (with Notion and Jira)") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.prepPhrase, forType: .string)
                        copied = true
                    }
                    Button("Preparation settings…") { SettingsWindow.show(tab: "ai") }
                }
                .menuStyle(.borderlessButton).fixedSize().disabled(model.target.isEmpty)
                Spacer()
                Text(runner.useAPI ? "\(runner.model.capitalized) · API key" : "\(runner.model.capitalized) · Claude account")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if PrepRunner.claudePath == nil {
                Text("Claude Code is not installed: use More > Copy request for Cowork.").font(.caption).foregroundStyle(.secondary)
            } else if !runner.useAPI && runner.loggedIn == false {
                HStack(spacing: 8) {
                    Label("Claude Code is not signed in", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("Log in…") { runner.openLogin() }.controlSize(.small)
                    Button("Use API key") { runner.useAPI = true }.controlSize(.small).disabled(!runner.hasAPIKey)
                    Button("Check") { runner.refreshAuth() }.controlSize(.small)
                }
            } else if runner.useAPI && !runner.hasAPIKey {
                Text("No Claude API key: add it in Settings > Keys.").font(.caption).foregroundStyle(.orange)
            }
            if !runner.result.isEmpty { Text(runner.result).font(.caption).foregroundStyle(.secondary) }
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
