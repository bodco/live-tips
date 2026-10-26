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
    var callRequest: [String: Any] = [:]
    var projectConfig = ""          // projects/<slug>.md of this call (Meetings DB and page IDs for Notion)
    var lastFile: String?
    var notionResult = ""      // last post-call Notion write: link or error
    var appTipsFile: String?   // the tips file the tips engine writes (--tips-out), for the post-call judge
    var judgeRunning: Process?
    /// Last post-call judge result, one line ("Last call: app 3.4/5 (12 tips), skill 2.9/5 (20 tips)").
    var judgeResult: String {
        get { (try? String(contentsOfFile: judgeResultPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        set { try? newValue.write(toFile: judgeResultPath, atomically: true, encoding: .utf8) }
    }
    var judgeResultPath: String { (appRoot as NSString).appendingPathComponent("state/last-judge.txt") }
    var sidecarRestarts = 0
    var projectRoot = ""
    /// 2026-10-23: a visible confirmation that the call ended and the transcript is saved (menu, tips window).
    var lastCallSummary = ""
    var lastLines = 0
    var liveSpent = 0.0, liveTips = 0
    /// 2026-10-26 (owner): what the last call cost, for the menu: the tips engine during the call plus the
    /// Notion wrap-up after it (state/last-call.json, survives a restart).
    var lastCallPath: String { (appRoot as NSString).appendingPathComponent("state/last-call.json") }
    var lastCall: [String: Any] {
        get { ((try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: lastCallPath)))) as? [String: Any]) ?? [:] }
        set { if let d = try? JSONSerialization.data(withJSONObject: newValue) { try? d.write(to: URL(fileURLWithPath: lastCallPath)) } }
    }
    var lastCallLine: String {
        let d = lastCall
        guard let tips = d["tips_usd"] as? Double else { return "" }
        let notes = d["notes_usd"] as? Double ?? 0
        var line = String(format: "Last call: $%.2f", tips + notes)
        if notes > 0 { line += String(format: " (tips $%.2f, Notion notes $%.2f)", tips, notes) }
        if let n = d["tips"] as? Int { line += " · \(n) tip\(n == 1 ? "" : "s")" }
        return line
    }
    static let callEnded = Notification.Name("LiveTipsCallEnded")

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

    /// The recorder's audio helper (bin/audiocap) must start. 2026-10-23: after an update the helper was
    /// killed by macOS at every launch (signature cached for the old file) and a call recorded nothing.
    /// A quick probe; on a kill the core is copied again (as a new file) and probed once more.
    func ensureAudioHelper() -> String? {
        let bin = (appRoot as NSString).appendingPathComponent("bin/audiocap")
        guard FileManager.default.isExecutableFile(atPath: bin) else { return nil }
        func probe() -> Bool {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["--help"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return false }
            let deadline = Date().addingTimeInterval(4)
            while p.isRunning && Date() < deadline { usleep(50_000) }
            if p.isRunning { p.terminate(); return true }
            return !(p.terminationReason == .uncaughtSignal)
        }
        if probe() { return nil }
        if let res = Bundle.main.resourcePath {
            let s = Process()
            s.executableURL = URL(fileURLWithPath: "/bin/bash")
            s.arguments = [(res as NSString).appendingPathComponent("setup.sh"), "install", "core"]
            var env = ProcessInfo.processInfo.environment
            env["APPROOT"] = appRoot
            env["BUNDLE"] = res
            s.environment = env
            try? s.run()
            s.waitUntilExit()
        }
        return probe() ? nil : "The audio helper is blocked by macOS (killed at launch). Open Settings > About and run Setup again, or reinstall Live Tips."
    }

    /// Starts recording. `request` goes to control/start.json (project_dir, title, slug, langs, call_type, audience).
    func start(request: [String: Any], apiAllowed: Bool, onReady: @escaping (EngineStatus) -> Void) -> String? {
        if isRunning { return "A call is already running" }
        if let first = problems().first { return first }
        if let err = ensureAudioHelper() { return err }
        LocalAIService.shared.apply()                       // core config: semantic on/off, engine URL
        if config.localAI.enabled { _ = LocalAIService.shared.waitReady(timeout: 6) }
        callContext = (request["context"] as? String) ?? ""
        callRequest = request
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
        req["stem_suffix"] = ".app"        // own files (<stem>.app.*): the skill can record the same call
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
        IndexService.shared.pause()        // the indexer waits while Whisper and the tips engine run
        self.onReady = onReady
        liveSpent = 0; liveTips = 0
        poll?.invalidate()
        var sidecarStarted = false
        var consentDone = false
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            let st = EngineStatus.load(path: self.statusPath)
            if let f = st.file { self.lastFile = f }
            if st.lines > 0 { self.lastLines = st.lines }
            if st.callSpentUSD > self.liveSpent { self.liveSpent = st.callSpentUSD }
            if st.tips > self.liveTips { self.liveTips = st.tips }
            if !sidecarStarted, let file = st.file, ["recording", "loading_model", "standby"].contains(st.state) {
                sidecarStarted = true
                self.adoptPrep(file: file)
                self.onReady?(st)
                if apiAllowed { self.startSidecar(file: file, status: st) }
            }
            if !consentDone, st.state == "recording" {
                consentDone = true
                self.consent()
            }
            // The tips engine must live as long as the recording: restart it if it ended (it reads on from now).
            if sidecarStarted, apiAllowed, st.state == "recording", let file = st.file,
               let sc = self.sidecar, !sc.isRunning, self.sidecarRestarts < 5 {
                self.sidecarRestarts += 1
                self.startSidecar(file: file, status: st, fromStart: false)
            }
            if !(self.recorder?.isRunning ?? false) {
                t.invalidate()
                // The tips engine ends by itself a few seconds after the recorder and writes the call summary
                // card; it is stopped only if it hangs (P2 26.10).
                let sc = self.sidecar
                DispatchQueue.main.asyncAfter(deadline: .now() + 25) { if sc?.isRunning == true { sc?.terminate() } }
                IndexService.shared.resume()
                let f = DateFormatter(); f.dateFormat = "HH:mm"
                let saved = (st.file ?? self.lastFile).map { FileManager.default.fileExists(atPath: $0) } ?? false
                self.lastCall = ["tips_usd": self.liveSpent, "tips": self.liveTips, "lines": self.lastLines,
                                 "at": ISO8601DateFormatter().string(from: Date())]
                self.lastCallSummary = saved
                    ? "✓ Call ended \(f.string(from: Date())) · transcript saved (\(self.lastLines) lines)"
                    : "⚠ Call ended \(f.string(from: Date())) · no transcript file found"
                NotificationCenter.default.post(name: CallEngine.callEnded, object: nil,
                                                userInfo: ["summary": self.lastCallSummary, "saved": saved,
                                                           "file": (st.file ?? self.lastFile) ?? "", "lines": self.lastLines])
                if let file = st.file ?? self.lastFile, apiAllowed {
                    self.writeToNotion(file: file)
                    self.runJudge(file: file)          // background, optional: never blocks the UI or the call
                }
            }
        }
        return nil
    }

    /// Picks up a prep made ahead in Cowork (prep-<time>-<title>.brief.md, cards.json, facts.json).
    func adoptPrep(file: String) {
        let c = config
        let lt = (appRoot as NSString).appendingPathComponent("bin/lt")
        guard FileManager.default.fileExists(atPath: lt) else { return }
        // A prep chosen by hand in the Start call window: copy its files next to this call's transcript,
        // and do not let the automatic pick add files of another prep (QA 26.10).
        var auto = true
        if let chosen = callRequest["prep_file"] as? String, !chosen.isEmpty, chosen.hasSuffix(".brief.md") {
            auto = false
            let base = String(chosen.dropLast(".brief.md".count))
            let stem = file.hasSuffix(".md") ? String(file.dropLast(3)) : file
            for ext in [".brief.md", ".cards.json", ".facts.json", ".outline.json", ".slides.json"] {
                let dst = stem + ext
                if FileManager.default.fileExists(atPath: base + ext), !FileManager.default.fileExists(atPath: dst) {
                    try? FileManager.default.copyItem(atPath: base + ext, toPath: dst)
                }
            }
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: c.engine.python)
        p.arguments = [lt, "prep-check", file] + (auto ? ["--adopt-prep"] : [])
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
            "periodic_classify_s": 20, "max_parallel_calls": 4, "max_tokens": ["classify": 60, "tip": 700],
            "request_extra": ["classify": ["thinking": ["type": "disabled"]], "tip": ["thinking": ["type": "between_tools"]]],
            "me_label": core["me_label"] ?? "Me", "them_label": core["them_label"] ?? "Other",
            "name_aliases": c.nameAliases, "langs": core["langs"] ?? ["en"], "tips_lang": (c.uiLanguage == "uk" || (core["me_lang"] as? String) == "uk") ? "uk" : "en",
            "budget": ["ledger": SpendLedger.defaultPath, "call_soft_usd": c.budget.callSoftUSD,
                       "call_hard_usd": c.budget.callHardUSD, "monthly_hard_usd": c.budget.monthlyHardUSD]]
        // Call context: the PM's note, the project's current state and local files found for it (lt search).
        sc["call_context"] = callContext
        // The meeting concept of this call (Start call): type, audience, interview role, tip model.
        for k in ["call_type", "audience", "hiring_role"] { if let v = callRequest[k] as? String, !v.isEmpty { sc[k] = v } }
        if let m = callRequest["tip_model"] as? String, !m.isEmpty { sc["models"] = ["classify": c.models.classify, "tip": m] }
        sc["hedge"] = ["enabled": c.hedgeEnabled]
        sc["answer_any"] = c.answerAny
        // 2026-10-26: the running call picture needs who the PM is on this call.
        for k in ["participants", "pm_projects"] { if let v = callRequest[k] as? [String], !v.isEmpty { sc[k] = v } }
        sc["situation"] = true
        sc["proactive"] = false
        sc["project_root"] = projectRoot
        // lt search: by meaning with Local AI on, plain text search otherwise (2026-10-26: "Search the project" works either way).
        sc["lt_cmd"] = [c.engine.python, (appRoot as NSString).appendingPathComponent("bin/lt")]
        sc["local_ai"] = c.localAI.enabled
        if let d = try? JSONSerialization.data(withJSONObject: sc, options: [.prettyPrinted]) {
            try? d.write(to: URL(fileURLWithPath: cfgPath), options: .atomic)
        }
        let stem = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
        let tipsOut = status.tipsFile ?? (file + ".tips.jsonl")
        appTipsFile = tipsOut
        let p = Process()
        p.executableURL = URL(fileURLWithPath: c.engine.sidecarPython)
        p.arguments = ["-m", "livetips_m0.live", "--config", cfgPath, "--md", file] + (fromStart ? ["--from-start"] : []) + [
                       "--out", (appRoot as NSString).appendingPathComponent("runs/" + stem),
                       "--status", statusPath, "--idle-min", "0", "--state-dir", state,
                       "--tips-out", tipsOut,
                       "--inbox", status.inboxFile ?? ""]
        p.currentDirectoryURL = URL(fileURLWithPath: c.engine.sidecarDir)
        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_API"] = key
        env["LT_PM_NAMES"] = c.nameAliases.joined(separator: ",")   // lt digest: questions addressed to the PM
        env["PYTHONDONTWRITEBYTECODE"] = "1"     // the engine may live inside the signed app bundle; the key goes to the child only, never written or logged
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
        let hasConfig = !projectConfig.isEmpty && FileManager.default.fileExists(atPath: projectConfig)
        guard hasConfig || !c.notionMeetingsDB.isEmpty else {
            notionResult = "Notion: choose where meeting pages go in Settings > General > Notion"; notify(notionResult); return
        }
        guard !c.engine.sidecarPython.isEmpty, !c.engine.sidecarDir.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: c.engine.sidecarPython)
        let projectName = ((callRequest["project_dir"] as? String).map { ($0 as NSString).lastPathComponent }) ?? ""
        p.arguments = ["-m", "livetips_m0.wrapup_notion", "--md", file,
                       "--lt", c.engine.python, (appRoot as NSString).appendingPathComponent("bin/lt"),
                       "--model", c.models.tip, "--project-name", projectName]
            + (hasConfig ? ["--project-config", projectConfig] : [])
            + (c.notionMeetingsDB.isEmpty ? [] : ["--meetings-db", c.notionMeetingsDB])
            + ((callRequest["scheduled_at"] as? String).map { ["--when", $0] } ?? [])   // the date and time set in Start call
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
                if let c = d["cost_usd"] as? Double, c > 0 { var lc = self.lastCall; lc["notes_usd"] = c; self.lastCall = lc }
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

    /// After the call: the blind judge (Sonnet, at most 25 tips) rates the app's and the skill's tips in the
    /// background and writes <transcript dir>/<stem>.judge/judge.summary.json. Optional (Settings > AI);
    /// any failure only leaves a line in logs/judge.log.
    func runJudge(file: String) {
        let c = config
        guard c.judgeAfterCall, judgeRunning?.isRunning != true else { return }
        guard !c.engine.sidecarPython.isEmpty, !c.engine.sidecarDir.isEmpty else { return }
        let cfgPath = (appRoot as NSString).appendingPathComponent("state/sidecar-config.json")
        guard FileManager.default.fileExists(atPath: cfgPath) else { return }
        let store = SecretStore(service: Bundle.main.bundleIdentifier ?? "io.github.example.livetips")
        guard let key = store.get(.claudeAPIKey) else { return }
        let dir = (file as NSString).deletingLastPathComponent
        var stem = (file as NSString).lastPathComponent
        if stem.hasSuffix(".md") { stem = String(stem.dropLast(3)) }
        let out = (dir as NSString).appendingPathComponent(stem + ".judge")
        let ct = ((callRequest["call_type"] as? String) ?? "").lowercased()
        let callType = ct.contains("present") ? "presentation" : (ct.contains("interview") || ct.contains("hiring")) ? "interview" : "auto"
        var args = ["-m", "livetips_m0.judge", "--config", cfgPath, "--md", file, "--call-type", callType, "--quick", "--out", out]
        if let t = appTipsFile { args += ["--app-tips", t] }
        if let r = callRequest["hiring_role"] as? String, !r.isEmpty { args += ["--role", r] }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: c.engine.sidecarPython)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: c.engine.sidecarDir)
        p.qualityOfService = .background
        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_API"] = key                    // passed to the child only, never written or logged
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        p.environment = env
        let log = FileHandle.forAppending(path: (appRoot as NSString).appendingPathComponent("logs/judge.log"))
        p.standardOutput = log
        p.standardError = log
        p.terminationHandler = { [weak self] _ in
            let summary = (out as NSString).appendingPathComponent("judge.summary.json")
            let d = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: summary)))) as? [String: Any] ?? [:]
            var parts: [String] = []
            for eng in ["app", "skill"] {
                if let e = d[eng] as? [String: Any], let n = e["n"] as? Int, n > 0, let m = e["mean"] as? Double {
                    parts.append(String(format: "%@ %.1f/5 (%d tips)", eng, m, n))
                }
            }
            let line = parts.isEmpty ? "Tips rated: none" : "Tips rated: " + parts.joined(separator: ", ")
            DispatchQueue.main.async { self?.judgeResult = line; self?.judgeRunning = nil }
        }
        do { try p.run(); judgeRunning = p } catch { judgeResult = "Tips rated: the check could not start" }
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

    /// 2026-10-26: the app was restarted during a call (an update), so it no longer owns the recorder.
    /// After End call, wait for the recorder to stop, then do what a normal end does: the Notion page
    /// (project config looked up by the call's slug) and the tips rating.
    func finishOrphan(onDone: @escaping (String, Bool) -> Void) {
        var waited = 0
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            waited += 1
            let st = EngineStatus.load(path: self.statusPath)
            guard st.state == "stopped" || waited > 60 else { return }
            t.invalidate()
            if st.state != "stopped" {
                // QA 26.10: the recorder died without writing "stopped": mark it, or the menu shows a call forever.
                if let d = FileManager.default.contents(atPath: self.statusPath),
                   var o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    let pid = (o["pid"] as? Int) ?? 0
                    if pid <= 0 || kill(pid_t(pid), 0) != 0 {
                        o["state"] = "stopped"
                        if let out = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted]) {
                            try? out.write(to: URL(fileURLWithPath: self.statusPath), options: .atomic)
                        }
                    }
                }
            }
            let file = st.file ?? self.lastFile ?? ""
            let saved = !file.isEmpty && FileManager.default.fileExists(atPath: file)
            if self.projectConfig.isEmpty, let slug = st.slug {
                let reg = ProjectRegistry.load(from: AppPaths.projects)
                self.projectConfig = reg.projects.first { $0.slug == slug }?.config ?? ""
            }
            let api = ProjectRegistry.load(from: AppPaths.projects).projects.first { $0.slug == st.slug }?.apiAllowed ?? true
            if saved && api {
                self.writeToNotion(file: file)
                self.runJudge(file: file)
            }
            onDone(file, saved)
        }
    }

    /// Consent when the recording starts (Settings > General > Recording consent; both off by default).
    func consent() {
        let c = config
        guard c.consentSay || c.consentChat else { return }
        let uk = ((callRequest["me_lang"] as? String) ?? "uk") == "uk"
        let text = uk ? c.consentTextUK : c.consentTextEN
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if c.consentChat {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            notify("Consent message copied: paste it into the meeting chat (Command-V)")
        }
        if c.consentSay {
            DispatchQueue.global().async {
                func say(_ args: [String]) -> Int32 {
                    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/say"); p.arguments = args
                    p.standardError = FileHandle.nullDevice
                    do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
                }
                if !(uk && say(["-v", "Lesya", text]) == 0) { _ = say([text]) }
            }
        }
    }

    func stop() {
        lastCallSummary = ""
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
