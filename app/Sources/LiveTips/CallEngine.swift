import AppKit
import LiveTipsCore

/// Runs a call: the recorder core (transcriber, MLX Whisper, local layer) and the model-tips
/// engine, both as child processes of Live Tips so macOS permissions belong to the app.
/// M1-M2 core is Python (see SPEC 2.0); the protocol is the call files and app_root/control|state.
final class CallEngine {
    static let shared = CallEngine()
    var recorder: Process?
    var sidecar: Process?
    var poll: Timer?
    var onReady: ((EngineStatus) -> Void)?

    var config: AppConfig { AppConfig.load(from: AppPaths.config) }
    var appRoot: String { config.effectiveAppRoot(appSupport: AppPaths.support.path) }
    var statusPath: String { (appRoot as NSString).appendingPathComponent("state/status.json") }
    var isRunning: Bool { recorder?.isRunning ?? false }
    var callContext = ""
    var projectConfig = ""          // projects/<slug>.md of this call (Meetings DB and page IDs for Notion)
    var lastFile: String?
    var notionResult = ""      // last post-call Notion write: link or error
    var sidecarRestarts = 0
    var projectRoot = ""

    func problems() -> [String] {
        let c = config
        var p: [String] = []
        let fm = FileManager.default
        if !fm.fileExists(atPath: (appRoot as NSString).appendingPathComponent("src/transcriber.py")) {
            p.append("Recorder core not installed in \(appRoot)")
        }
        if c.engine.python.isEmpty || !fm.isExecutableFile(atPath: c.engine.python) { p.append("Recorder Python not set") }
        return p
    }

    /// Starts recording. `request` goes to control/start.json (project_dir, title, slug, langs, call_type, audience).
    func start(request: [String: Any], apiAllowed: Bool, onReady: @escaping (EngineStatus) -> Void) -> String? {
        if isRunning { return "A call is already running" }
        if let first = problems().first { return first }
        LocalAIService.shared.apply()                       // core config: semantic on/off, engine URL
        if config.localAI.enabled { _ = LocalAIService.shared.waitReady(timeout: 6) }
        callContext = (request["context"] as? String) ?? ""
        sidecarRestarts = 0
        projectRoot = (request["project_dir"] as? String) ?? ""
        projectConfig = (request["project_config"] as? String) ?? ""
        let c = config
        let control = (appRoot as NSString).appendingPathComponent("control")
        let logs = (appRoot as NSString).appendingPathComponent("logs")
        try? FileManager.default.createDirectory(atPath: control, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: logs, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: statusPath)
        var req = request
        req["prompter"] = false            // Live Tips shows its own window
        guard let d = try? JSONSerialization.data(withJSONObject: req, options: [.prettyPrinted, .sortedKeys]) else { return "Bad request" }
        try? d.write(to: URL(fileURLWithPath: (control as NSString).appendingPathComponent("start.json")), options: .atomic)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: c.engine.python)
        p.arguments = [(appRoot as NSString).appendingPathComponent("src/transcriber.py"), "--from-control"]
        p.currentDirectoryURL = URL(fileURLWithPath: appRoot)
        let log = FileHandle.forAppending(path: (logs as NSString).appendingPathComponent("recorder.log"))
        p.standardOutput = log
        p.standardError = log
        do { try p.run() } catch { return "Could not start the recorder: \(error.localizedDescription)" }
        recorder = p
        self.onReady = onReady
        poll?.invalidate()
        var sidecarStarted = false
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            let st = EngineStatus.load(path: self.statusPath)
            if let f = st.file { self.lastFile = f }
            if !sidecarStarted, let file = st.file, ["recording", "loading_model", "standby"].contains(st.state) {
                sidecarStarted = true
                self.adoptPrep(file: file)
                self.onReady?(st)
                if apiAllowed { self.startSidecar(file: file, status: st) }
            }
            // The tips engine must live as long as the recording: restart it if it ended (it reads on from now).
            if sidecarStarted, apiAllowed, st.state == "recording", let file = st.file,
               let sc = self.sidecar, !sc.isRunning, self.sidecarRestarts < 5 {
                self.sidecarRestarts += 1
                self.startSidecar(file: file, status: st, fromStart: false)
            }
            if !(self.recorder?.isRunning ?? false) {
                t.invalidate()
                self.sidecar?.terminate()
                if let file = st.file ?? self.lastFile, apiAllowed { self.writeToNotion(file: file) }
            }
        }
        return nil
    }

    /// Picks up a prep made ahead in Cowork (prep-<time>-<title>.brief.md, cards.json, facts.json).
    func adoptPrep(file: String) {
        let c = config
        let lt = (appRoot as NSString).appendingPathComponent("bin/lt")
        guard FileManager.default.fileExists(atPath: lt) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: c.engine.python)
        p.arguments = [lt, "prep-check", file, "--adopt-prep"]
        let log = FileHandle.forAppending(path: (appRoot as NSString).appendingPathComponent("logs/prep.log"))
        p.standardOutput = log
        p.standardError = log
        try? p.run()
        p.waitUntilExit()
    }

    func startSidecar(file: String, status: EngineStatus, fromStart: Bool = true) {
        let c = config
        guard !c.engine.sidecarPython.isEmpty, !c.engine.sidecarDir.isEmpty else { return }
        let store = SecretStore(service: Bundle.main.bundleIdentifier ?? "io.github.example.livetips")
        guard let key = store.get(.claudeAPIKey) else { return }
        let state = (appRoot as NSString).appendingPathComponent("state")
        let cfgPath = (state as NSString).appendingPathComponent("sidecar-config.json")
        let core = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: (appRoot as NSString).appendingPathComponent("config.json"))))) as? [String: Any] ?? [:]
        var sc: [String: Any] = [
            "variant": "app", "provider": "anthropic", "api_key_env": "CLAUDE_API",
            "models": ["classify": c.models.classify, "tip": c.models.tip], "cache_ttl": "1h", "direct_route": true,
            "periodic_classify_s": 20, "max_parallel_calls": 4, "max_tokens": ["classify": 120, "tip": 300],
            "request_extra": ["classify": ["thinking": ["type": "disabled"]], "tip": ["thinking": ["type": "between_tools"]]],
            "me_label": core["me_label"] ?? "Me", "them_label": core["them_label"] ?? "Other",
            "name_aliases": c.nameAliases, "langs": core["langs"] ?? ["en"], "tips_lang": (c.uiLanguage == "uk" || (core["me_lang"] as? String) == "uk") ? "uk" : "en",
            "budget": ["ledger": SpendLedger.defaultPath, "call_soft_usd": c.budget.callSoftUSD,
                       "call_hard_usd": c.budget.callHardUSD, "monthly_hard_usd": c.budget.monthlyHardUSD]]
        // Call context: the PM's note, the project's current state and local files found for it (lt search).
        sc["call_context"] = callContext
        sc["project_root"] = projectRoot
        if c.localAI.enabled { sc["lt_cmd"] = [c.engine.python, (appRoot as NSString).appendingPathComponent("bin/lt")] }
        if let d = try? JSONSerialization.data(withJSONObject: sc, options: [.prettyPrinted]) {
            try? d.write(to: URL(fileURLWithPath: cfgPath), options: .atomic)
        }
        let stem = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
        let p = Process()
        p.executableURL = URL(fileURLWithPath: c.engine.sidecarPython)
        p.arguments = ["-m", "livetips_m0.live", "--config", cfgPath, "--md", file] + (fromStart ? ["--from-start"] : []) + [
                       "--out", (appRoot as NSString).appendingPathComponent("runs/" + stem),
                       "--status", statusPath, "--idle-min", "0", "--state-dir", state,
                       "--tips-out", status.tipsFile ?? (file + ".tips.jsonl"),
                       "--inbox", status.inboxFile ?? ""]
        p.currentDirectoryURL = URL(fileURLWithPath: c.engine.sidecarDir)
        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_API"] = key
        env["PYTHONDONTWRITEBYTECODE"] = "1"     // the engine may live inside the signed app bundle                 // passed to the child only, never written or logged
        p.environment = env
        let log = FileHandle.forAppending(path: (appRoot as NSString).appendingPathComponent("logs/tips-engine.log"))
        p.standardOutput = log
        p.standardError = log
        try? p.run()
        sidecar = p
    }

    /// After the call: wrap-up by Claude and the Meetings DB page in Notion (existing page of this meeting
    /// first, a new one otherwise), with the transcript attached as a .md file. Same result as the skill's
    /// wrap-up Step 5. Needs the Notion token (Settings > Keys) and a project with a config.
    func writeToNotion(file: String) {
        let c = config
        guard c.notionWriteSummary else { return }
        let store = SecretStore(service: Bundle.main.bundleIdentifier ?? "io.github.example.livetips")
        guard let key = store.get(.claudeAPIKey), let notionToken = store.get(.notionToken) else {
            notionResult = "Notion: add the Notion token in Settings > Keys"; notify(notionResult); return
        }
        guard !projectConfig.isEmpty, FileManager.default.fileExists(atPath: projectConfig) else {
            notionResult = "Notion: this call has no project config, nothing written"; return
        }
        guard !c.engine.sidecarPython.isEmpty, !c.engine.sidecarDir.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: c.engine.sidecarPython)
        p.arguments = ["-m", "livetips_m0.wrapup_notion", "--md", file, "--project-config", projectConfig,
                       "--lt", c.engine.python, (appRoot as NSString).appendingPathComponent("bin/lt"),
                       "--model", c.models.tip]
        p.currentDirectoryURL = URL(fileURLWithPath: c.engine.sidecarDir)
        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_API"] = key
        env["NOTION_TOKEN"] = notionToken          // passed to the child only, never written or logged
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        let log = FileHandle.forAppending(path: (appRoot as NSString).appendingPathComponent("logs/notion.log"))
        p.standardError = log
        notionResult = "Notion: writing the meeting page…"
        p.terminationHandler = { [weak self] proc in
            let data = out.fileHandleForReading.readDataToEndOfFile()
            log?.write(data)
            let line = String(data: data, encoding: .utf8)?.split(separator: "\n").last.map(String.init) ?? ""
            let d = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
            DispatchQueue.main.async {
                guard let self = self else { return }
                if (d["ok"] as? Bool) == true, let url = d["url"] as? String {
                    self.notionResult = url
                    self.notify(((d["created"] as? Bool) == true ? "Meeting page created in Notion" : "Wrap-up added to the meeting page in Notion"), url: url)
                } else {
                    self.notionResult = "Notion: " + ((d["error"] as? String) ?? "failed, see logs/notion.log")
                    self.notify(self.notionResult)
                }
            }
        }
        do { try p.run() } catch { notionResult = "Notion: could not start (\(error.localizedDescription))" }
    }

    func notify(_ text: String, url: String? = nil) {
        let a = NSAlert()
        a.messageText = "Live Tips"
        a.informativeText = text
        a.addButton(withTitle: url == nil ? "OK" : "Open in Notion")
        if url != nil { a.addButton(withTitle: "Close") }
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn, let u = url, let link = URL(string: u) { NSWorkspace.shared.open(link) }
    }

    func stop() {
        let control = (appRoot as NSString).appendingPathComponent("control")
        FileManager.default.createFile(atPath: (control as NSString).appendingPathComponent("stop"), contents: Data())
    }
}

extension FileHandle {
    static func forAppending(path: String) -> FileHandle? {
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        let h = FileHandle(forWritingAtPath: path)
        _ = try? h?.seekToEnd()
        return h
    }
}
