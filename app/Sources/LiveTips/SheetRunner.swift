import AppKit
import Foundation
import LiveTipsCore

/// 0.10.0 (Meeting Sheet, phase 3): Prepare builds a Meeting Sheet for every call type except Transcript.
/// Runs the Python sidecar (`python -m livetips_m0.sheet build|refresh --request <json>`, the same python and engine
/// folder as the packed preparation), reads its progress lines and publishes the state the Meeting Sheet screens bind
/// to (progress, stage, per-source status, passes). One build at a time: the Up next queue waits on
/// `PrepRunner.shared.running`, which this runner mirrors, so the existing UI (Up next, the tips window, Brief tab)
/// keeps working before the new screens land. The sidecar also writes the files the live call reads today
/// (<base>.brief.md as a generated copy of the sheet, cards, facts, slides, agenda), see sheet/derive.py.
///
/// Route rule (PM, 12.11): the route is Settings > AI > Preparation and is never switched silently. When it cannot
/// run, an interactive Prepare asks (`pendingSwitch`, shown by the UI; an alert until the UI takes it over), a
/// queued one without a person switches and the sheet's report says so.
@MainActor
final class SheetRunner: ObservableObject {
    static let shared = SheetRunner()

    struct SourceState: Equatable {
        var id: String
        var access: String = ""
        var status: String = ""          // checking | ok | reading | read | failed | skipped
    }

    struct PendingSwitch: Identifiable {
        let id = UUID()
        let from: String
        let to: String
        let reason: String
        fileprivate let job: Job
    }

    fileprivate struct Job {
        var prep: PrepRunner.Request
        var base: String
        var refresh: Bool
        var interactive: Bool
        var route: String
        var switchedFrom: String?
        var switchReason: String?
        var live = false                 // 0.10.0 (round 2): Prepare again during this very call
    }

    @Published var running = false
    @Published var progress: Double = 0
    @Published var stage = ""
    @Published var detail = ""
    @Published var sources: [String: SourceState] = [:]
    @Published var pass = 0
    @Published var passes = 0
    @Published var sheetPath: String?
    @Published var base: String?
    @Published var result = ""
    @Published var lastOutcome: [String: Any] = [:]
    @Published var pendingSwitch: PendingSwitch?
    @Published var callID: UUID?
    /// The Meeting Sheet UI sets this when it shows `pendingSwitch` itself; until then an alert asks.
    static var uiHandlesSwitch = false
    /// 0.10.0 (Meeting Sheet, phase 4, ui agent): what Quick / Expert chose for a call (preset, blocks, sources, goal,
    /// participants, language, route, plan, method, focus), by call id; laid over the request built here.
    static var overrides: [UUID: [String: Any]] = [:]
    /// 0.10.0 (Meeting Sheet, round 2): Retry / Skip of the build screen (S5) for the running build. The sidecar reads
    /// {"actions": [{"action": "retry" | "skip", "source_id": "s3"}]} between sources and before every pass.
    static var controlPath: String?

    private var process: Process?
    private var buffer = Data()
    private var startedAt = Date()
    private var job: Job?

    // MARK: who goes through the sheet

    /// Every call type except Transcript (no preparation at all). The rule lives in LiveTipsCore (SheetPipeline).
    nonisolated static func handles(callType: String) -> Bool { SheetPipeline.builds(callType: callType) }
    static func handles(_ r: PrepRunner.Request) -> Bool { handles(callType: r.callType) }

    /// A preparation for the call being recorded right now (LivePrep: Prepare again / a correction during the call).
    /// 0.10.0 (round 2): it goes through the sheet too, as a refresh of the call's sheet (SheetPipeline.isRefresh).
    static func isLivePrep(_ r: PrepRunner.Request) -> Bool {
        guard r.callID != nil, CallEngine.shared.isRunning else { return false }
        return PrepRunner.joinsLiveCall(prepFor: r.callID, liveCall: CallEngine.shared.currentCallID)
    }

    static func baseName(live: String, date: Date, title: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"
        return (live as NSString).appendingPathComponent("prep-\(f.string(from: date))-\(StartCallModel.slugify(title))")
    }

    /// The preset for a call: the PM's choice for the series (sheet.preset.<series>), else from the call settings.
    static func preset(callType: String, audience: String, sales: Bool, title: String, earlier: Bool) -> String {
        SheetPipeline.preset(callType: callType, sales: sales, title: title, earlier: earlier,
                             seriesChoice: UserDefaults.standard.string(forKey: "sheet.preset." + EditLog.seriesKey(title)))
    }

    // MARK: routes

    static func usable(_ r: String, config c: AppConfig) -> Bool {
        let p = PrepRunner.shared
        let ok: Bool
        switch r {
        case AIRoute.codex: ok = CodexAccount.cliPath != nil
        case AIRoute.openai: ok = p.hasOpenAIKey
        case AIRoute.gemini: ok = p.hasGeminiKey
        case AIRoute.agy: ok = AgyAccount.cliPath != nil && AgyAccount.shared.signedIn != false
        case AIRoute.api: ok = p.hasAPIKey
        case AIRoute.local: ok = true
        default: ok = PrepRunner.claudePath != nil && p.loggedIn != false
        }
        return ok && !SpendWatch.capped(route: r, config: c)
    }

    /// The first other route that can run, in the order the app already falls back (the other Claude way, the
    /// ChatGPT account, Gemini, the model on this Mac).
    static func alternative(to r: String, config c: AppConfig) -> String? {
        let order = [AIRoute.other(r), AIRoute.code, AIRoute.codex, AIRoute.gemini, AIRoute.agy, AIRoute.local]
        return order.first { $0 != r && usable($0, config: c) }
    }

    static func whyNot(_ r: String) -> String {
        switch r {
        case AIRoute.codex: return L("ai.codex.missing")
        case AIRoute.openai: return L("prep.err.noOpenAIKey")
        case AIRoute.gemini: return L("prep.err.noGeminiKey")
        case AIRoute.agy: return L("ai.agy.missing")
        case AIRoute.api: return L("prep.err.noKey")
        default: return L("prep.err.notSigned")
        }
    }

    // MARK: start

    /// Starts a build (or a refresh when the call already has a sheet). Returns an error line, or nil.
    func start(_ r: PrepRunner.Request, interactive: Bool) -> String? {
        if running || PrepRunner.shared.running { return L("prep.err.running") }
        let live = (r.root as NSString).appendingPathComponent("live")
        try? FileManager.default.createDirectory(atPath: live, withIntermediateDirectories: true)
        let b = r.refreshBase ?? Self.baseName(live: live, date: r.date, title: r.title)
        let duringCall = Self.isLivePrep(r)
        let refresh = SheetPipeline.isRefresh(sheetExists: FileManager.default.fileExists(atPath: b + ".sheet.json"),
                                              refreshAsked: r.refreshBase != nil, duringCall: duringCall)
        // An old brief of this call (made before 0.10.0) is kept as the previous version (Restore previous version):
        // the sheet writes <base>.brief.md again as its own copy.
        let fm = FileManager.default
        if !fm.fileExists(atPath: b + ".sheet.json"), fm.fileExists(atPath: b + ".brief.md") {
            try? fm.removeItem(atPath: b + ".brief.prev.md")
            try? fm.copyItem(atPath: b + ".brief.md", toPath: b + ".brief.prev.md")
        }
        let c = AIRoute.effective(AppConfig.load(from: AppPaths.config))
        let chosen = r.callID.flatMap { Self.overrides[$0]?["route"] as? String } ?? c.ai.prep   // 0.10.0 (ui): the route shown in Quick / Expert
        var j = Job(prep: r, base: b, refresh: refresh, interactive: interactive, route: chosen)
        j.live = duringCall
        if !Self.usable(chosen, config: c) {
            guard let alt = Self.alternative(to: chosen, config: c) else { return Self.whyNot(chosen) }
            let why = Self.whyNot(chosen)
            if interactive {
                j.route = alt
                ask(PendingSwitch(from: chosen, to: alt, reason: why, job: j))
                return nil
            }
            j.route = alt; j.switchedFrom = chosen; j.switchReason = why        // queued, nobody to ask: switch, report it
        }
        return launch(j)
    }

    private func ask(_ p: PendingSwitch) {
        pendingSwitch = p
        result = L("sheet.switch.waiting")
        UpNext.shared.prepFinished(id: p.job.prep.callID, base: nil, ok: false, stopped: true)
        guard !Self.uiHandlesSwitch else { return }
        let a = NSAlert()
        a.messageText = L("sheet.switch.title")
        a.informativeText = L("sheet.switch.body", ["from": AIRoute.name(p.from), "to": AIRoute.name(p.to), "why": p.reason])
        a.addButton(withTitle: L("sheet.switch.ok", ["to": AIRoute.name(p.to)]))
        a.addButton(withTitle: L("sheet.switch.cancel"))
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { acceptSwitch() } else { declineSwitch() }
    }

    /// The person agreed to run this build on the other route (the UI's button, or the alert).
    func acceptSwitch() {
        guard var j = pendingSwitch?.job, let p = pendingSwitch else { return }
        pendingSwitch = nil
        j.switchedFrom = p.from; j.switchReason = p.reason + " (" + L("sheet.switch.accepted") + ")"
        if let err = launch(j) { result = err }
    }

    func declineSwitch() {
        pendingSwitch = nil
        result = L("sheet.switch.declined")
    }

    // MARK: the sidecar

    private func requestJSON(_ j: Job, config c: AppConfig, google: [String: Any]) -> [String: Any] {
        let r = j.prep
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime]; iso.timeZone = .current
        let ev = CalendarService.shared.events.first {
            abs($0.start.timeIntervalSince(r.date)) < 120 && StartCallModel.slugify($0.title) == StartCallModel.slugify(r.title)
        }
        var meeting: [String: Any] = ["title": r.title, "start": iso.string(from: r.date), "tz": TimeZone.current.identifier]
        if let e = ev {
            meeting["end"] = iso.string(from: e.end)
            meeting["event_id"] = e.id
            if let l = e.link { meeting["where"] = l }
        }
        let me = c.nameAliases.first ?? ""
        let theirs: [[String: Any]] = (ev?.attendees ?? []).filter { !$0.isEmpty && $0 != me }.map { ["name": $0] }
        let live = (r.root as NSString).appendingPathComponent("live")
        let earlier = (try? FileManager.default.contentsOfDirectory(atPath: live))?.contains {
            $0.hasSuffix(".sheet.json") && $0.contains("-" + StartCallModel.slugify(r.title) + ".sheet")
        } ?? false
        // 0.10.0 (Meeting Sheet, phase 7): the running call's transcript (Prepare again during a call) is a "transcript"
        // source of the sheet, not a plain file
        let liveFile = CallEngine.shared.isRunning ? EngineStatus.load(path: CallEngine.shared.statusPath).file : nil
        var sources: [[String: Any]] = r.folders.filter { !StartCallModel.isDir($0) }.map { p -> [String: Any] in
            p == liveFile ? ["path": p, "title": L("sheet.live.transcriptSource"), "type": "transcript"]
                          : ["path": p, "title": (p as NSString).lastPathComponent]
        }
        if let d = r.deck, let info = d.info {
            var owners: [String: String] = [:]
            for (k, v) in d.owners { owners[String(k)] = v }
            sources.append(["path": d.path ?? info.file, "title": (info.file as NSString).lastPathComponent, "deck_json": info.jsonPath,
                            "deck": ["owners": owners, "minutes": d.talkMin, "qa_minutes": d.qaOn ? d.qaMin : 0]])
        }
        let appRoot = c.effectiveAppRoot(appSupport: AppPaths.support.path)
        let lt = (appRoot as NSString).appendingPathComponent("bin/lt")
        let model: String
        switch j.route {
        case AIRoute.openai: model = c.ai.openaiPrep
        case AIRoute.gemini: model = c.ai.geminiPrep
        case AIRoute.agy: model = c.ai.agyPrep
        case AIRoute.local: model = LocalLLM.model
        case AIRoute.codex: model = ""
        default: model = PrepRunner.shared.model
        }
        var req: [String: Any] = [
            "meeting": meeting,
            "participants": ["ours": me.isEmpty ? [] : [["name": me]], "theirs": theirs],
            "preset": Self.preset(callType: r.callType, audience: r.audience, sales: r.salesMethod != nil, title: r.title, earlier: earlier),
            "language": L10n.lang, "languages": r.languages, "route": j.route, "model": model,
            "project": ["slug": r.slug, "root": r.root, "config": r.config],
            "call_type": r.callType, "audience": r.audience, "context": r.context,
            "sources": sources, "folders": r.folders.filter { StartCallModel.isDir($0) },
            "use_project_folder": r.useProjectFolder, "live": live, "base": j.base, "app_root": appRoot,
            "lt": [c.engine.python, lt], "google": google, "notion": ["connected": false],
            "auto_pick": 12, "on_too_much": "passes", "timeout": 1500
        ]
        if let m = r.salesMethod { req["method"] = m == "general" ? "bant" : m }
        if j.route == AIRoute.api, let pa = PrepAgent.plan(c.prepAgent, route: j.route, economy: SpendWatch.economyOn), let b = pa.budgetUSD {
            req["max_budget_usd"] = b
        }
        if let from = j.switchedFrom { req["route_switch"] = ["from": from, "to": j.route, "reason": j.switchReason ?? ""] }
        if let claude = PrepRunner.claudePath { req["claude"] = claude }
        // 0.10.0 (Meeting Sheet, phase 4, ui agent): the wizard's choices win; its sources come first, the deck and
        // the files found here stay unless the wizard has them; nothing is auto-picked once the person ticked.
        if let id = r.callID, let o = Self.overrides[id] {
            let mine = o["sources"] as? [[String: Any]] ?? []
            let paths = Set(mine.compactMap { $0["path"] as? String })
            for (k, v) in o where k != "sources" { req[k] = v }
            req["sources"] = mine + sources.filter { !paths.contains(($0["path"] as? String) ?? "\u{0}") }
            req["auto_pick"] = nil
        }
        return req
    }

    private func launch(_ j: Job) -> String? {
        let r = j.prep
        // Google links of the context, the sources and the invitation are read through the PM's accounts first
        // (rules/google.yaml > links); the sidecar gets local copies and, for a link no account opens, "denied".
        let ev = CalendarService.shared.events.first {
            abs($0.start.timeIntervalSince(r.date)) < 120 && StartCallModel.slugify($0.title) == StartCallModel.slugify(r.title)
        }
        let linkText = ([r.context] + (ev?.attachments ?? [])).joined(separator: "\n")
        begin(j)
        if GoogleService.shared.connected, !GoogleLink.find(in: linkText).isEmpty {
            set(0.01, L("prep.st.google"))
            let folder = ((r.root as NSString).appendingPathComponent("live") as NSString).appendingPathComponent("google")
            Task { @MainActor in
                let res = await GoogleService.shared.readLinks(in: r.context, extra: ev?.attachments ?? [], folder: folder)
                var copies: [String: String] = [:], status: [String: String] = [:]
                for (l, p) in res.files { copies[l.id] = p; status[l.id] = "ok" }
                for p in res.problems {
                    let u = String(p.split(separator: " ").first ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                    if let l = GoogleLink.parse(u) { status[l.id] = "denied" }
                }
                var j2 = j
                j2.prep.googleDone = true
                // the links found become sources, so their access shows in the report
                j2.prep.googleRead = res.files.map { $0.0.url }
                if let err = self.run(j2, google: ["connected": true, "copies": copies, "status": status],
                                      links: GoogleLink.find(in: linkText).map { $0.url }) { self.fail(j2, err) }
            }
            return nil
        }
        let links = GoogleLink.find(in: linkText).map { $0.url }
        if let err = run(j, google: ["connected": GoogleService.shared.connected], links: links) {
            end(j, ok: false)
            return err
        }
        return nil
    }

    private func begin(_ j: Job) {
        job = j
        running = true
        startedAt = Date()
        callID = j.prep.callID
        base = j.base
        sources = [:]; pass = 0; passes = 0; result = ""; lastOutcome = [:]; sheetPath = nil
        let pr = PrepRunner.shared
        pr.running = true
        pr.startedAt = startedAt
        pr.callID = j.prep.callID
        pr.forTitle = j.prep.title; pr.forDate = j.prep.date
        pr.target = (j.base as NSString).lastPathComponent
        pr.runRoute = j.route
        pr.result = ""
        pr.liveFailure = nil
        pr.costUSD = nil
        set(0.02, L("sheet.st.sources"))
    }

    private func set(_ p: Double, _ s: String, _ d: String = "") {
        progress = p; stage = s; detail = d
        let pr = PrepRunner.shared
        pr.progress = p; pr.stage = s; pr.detail = d
    }

    private func run(_ j: Job, google: [String: Any], links: [String]) -> String? {
        let c = AIRoute.effective(AppConfig.load(from: AppPaths.config))
        var req = requestJSON(j, config: c, google: google)
        if !links.isEmpty {         // a Google link of the context or the invitation is a source of its own
            var src = req["sources"] as? [[String: Any]] ?? []
            for u in links where !src.contains(where: { ($0["uri"] as? String) == u }) { src.append(["uri": u]) }
            req["sources"] = src
        }
        let appRoot = c.effectiveAppRoot(appSupport: AppPaths.support.path)
        let state = (appRoot as NSString).appendingPathComponent("state")
        try? FileManager.default.createDirectory(atPath: state, withIntermediateDirectories: true)
        let reqPath = (state as NSString).appendingPathComponent("sheet-request.json")
        // 0.10.0 (Meeting Sheet, round 2): a fresh control file per build; a person watching gets 30 s per failed source
        let ctl = (state as NSString).appendingPathComponent("sheet-control.json")
        if let cd = try? JSONSerialization.data(withJSONObject: ["actions": [Any]()]) { try? cd.write(to: URL(fileURLWithPath: ctl), options: .atomic) }
        Self.controlPath = ctl
        req["control"] = ctl
        req["control_wait_s"] = j.interactive ? 30 : 0
        guard let d = try? JSONSerialization.data(withJSONObject: req, options: [.prettyPrinted]) else { return L("sheet.err.request") }
        try? d.write(to: URL(fileURLWithPath: reqPath))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: c.engine.sidecarPython)
        p.arguments = ["-m", "livetips_m0.sheet", j.refresh ? "refresh" : "build", "--request", reqPath]
        p.currentDirectoryURL = URL(fileURLWithPath: c.engine.sidecarDir)
        // Keys go to the child only, and only the one of the route (as PrepRunner); never written or logged.
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""].joined(separator: ":")
        for k in ["ANTHROPIC_API_KEY", "ANTHROPIC_CUSTOM_HEADERS", "OPENAI_API_KEY", "GEMINI_API_KEY"] { env.removeValue(forKey: k) }
        let store = SecretStore(service: Bundle.main.bundleIdentifier ?? "io.github.example.livetips")
        switch j.route {
        case AIRoute.api:
            if let key = store.get(.claudeAPIKey), !key.isEmpty {
                env["ANTHROPIC_API_KEY"] = key
                if let ws = store.get(.claudeWorkspaceID), !ws.isEmpty { env["ANTHROPIC_CUSTOM_HEADERS"] = "anthropic-workspace-id: " + ws }
            }
        case AIRoute.openai: if let k = store.get(.openaiAPIKey), !k.isEmpty { env["OPENAI_API_KEY"] = k }
        case AIRoute.gemini: if let k = store.get(.geminiAPIKey), !k.isEmpty { env["GEMINI_API_KEY"] = k }
        case AIRoute.agy: env = AgyCLI.environment(env); env["LT_AGY_CLI"] = AgyAccount.cliPath
        case AIRoute.codex: env = CodexCLI.environment(env); env["LT_CODEX_CLI"] = CodexAccount.cliPath
        default: break
        }
        if let claude = PrepRunner.claudePath { env["LT_CLAUDE_CLI"] = claude }
        p.environment = env
        let logs = (appRoot as NSString).appendingPathComponent("logs")
        try? FileManager.default.createDirectory(atPath: logs, withIntermediateDirectories: true)
        let logPath = (logs as NSString).appendingPathComponent("sheet-build.log")
        let log = FileHandle.forAppending(path: logPath)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logPath)
        log?.write(("\n==== \(Date()) \(j.prep.title) -> \(j.base) (\(j.route))\n").data(using: .utf8)!)
        let out = Pipe()
        p.standardOutput = out
        p.standardError = log
        buffer = Data()
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { return }
            Task { @MainActor in self?.consume(data) }
        }
        p.terminationHandler = { [weak self] proc in
            let rest = out.fileHandleForReading.readDataToEndOfFile()
            Task { @MainActor in
                guard let self = self, self.process === proc else { return }
                out.fileHandleForReading.readabilityHandler = nil
                if !rest.isEmpty { self.consume(rest) }
                self.consume(Data("\n".utf8))
                self.finished(j, code: proc.terminationStatus)
            }
        }
        do { try p.run() } catch { return L("prep.err.cantStart", ["err": error.localizedDescription]) }
        process = p
        return nil
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            if o["done"] != nil || o["error"] != nil { lastOutcome = o; continue }
            let st = o["stage"] as? String ?? ""
            let sid = o["source_id"] as? String
            if let sid = sid {
                var s = sources[sid] ?? SourceState(id: sid)
                if o["skipped"] as? Bool == true { s.access = "skipped"; s.status = "skipped" }      // 0.10.0 (round 2)
                else if let a = o["access"] as? String { s.access = a; s.status = a == "ok" ? "ok" : "failed" }
                else if st == "reading" || st == "summarize" { s.status = "reading" }
                sources[sid] = s
            }
            if let n = o["pass"] as? Int { pass = n }
            if let n = o["passes"] as? Int { passes = n }
            let name: String
            switch st {
            case "sources": name = L("sheet.st.sources")
            case "size": name = L("sheet.st.size")
            case "reading": name = L("sheet.st.reading")
            case "summarize": name = L("sheet.st.summarize")
            case "model": name = passes > 1 ? L("sheet.st.pass", ["n": "\(pass)", "of": "\(passes)"]) : L("sheet.st.model")
            case "merge": name = L("sheet.st.merge")
            case "write": name = L("sheet.st.write")
            default: name = stage
            }
            let file = (o["file"] as? String) ?? ""
            set(max(progress, (o["progress"] as? Double) ?? progress), name, file)
        }
    }

    private func finished(_ j: Job, code: Int32) {
        process = nil
        let o = lastOutcome
        let ok = code == 0 && (o["done"] as? Bool) == true
        let routeName = j.route == AIRoute.code ? "plan" : j.route
        var meta: [String: Any] = ["sheet": true, "model": o["model"] ?? "", "duration_s": o["duration_s"] ?? Int(Date().timeIntervalSince(startedAt))]
        if let t = o["tokens"] { meta["tokens"] = t }
        if let f = j.switchedFrom { meta["switched_from"] = f }
        let usd = (o["cost_usd"] as? Double).flatMap { $0 > 0 ? $0 : nil }
        if ok {
            AIRoute.markUp(j.route)
            sheetPath = o["sheet"] as? String
            for (k, v) in sources where v.status == "reading" || v.status == "ok" { sources[k]?.status = "read" }
            var extra: [String: Any] = ["route": routeName, "model": o["model"] ?? "", "sheet": sheetPath ?? ""]
            if let u = usd { extra["cost_usd"] = (u * 10000).rounded() / 10000 }
            Freshness.writeSnapshot(base: j.base, refreshOf: j.refresh ? Date() : nil, extra: extra)
            if j.route == AIRoute.api, let u = usd { SpendDays.add(u) }
            let mins = max(1, Int(Date().timeIntervalSince(startedAt) / 60))
            result = L("sheet.ready", ["min": "\(mins)", "state": (o["readiness"] as? String) ?? ""])
            UsageLog.log("prepare_run", ["type": routeName, "source": "sheet", "seconds": mins * 60])
            set(1, L("prep.st.done"))
            let pr = PrepRunner.shared
            if pr.joinsCurrentCall, CallEngine.shared.isRunning, let f = CallEngine.shared.lastFile {
                CallEngine.shared.adoptLatePrep(base: j.base, file: f)
            }
        } else {
            let err = (o["error"] as? String) ?? L("prep.failedExit", ["code": "\(code)"])
            result = err
            if let why = AIRoute.outReason(j.route, err) {
                AIRoute.markDown(j.route, why)
                let c = AIRoute.effective(AppConfig.load(from: AppPaths.config))
                if j.switchedFrom == nil, let alt = Self.alternative(to: j.route, config: c) {
                    PrepRunner.ledger(job: "prep", route: routeName, usd: usd, meta: meta, ok: false)
                    var j2 = j
                    end(j, ok: false, notify: false)
                    if j.interactive {
                        j2.route = alt
                        ask(PendingSwitch(from: j.route, to: alt, reason: err, job: j2))
                    } else {
                        j2.route = alt; j2.switchedFrom = j.route; j2.switchReason = err
                        if let e = launch(j2) { fail(j2, e) }
                    }
                    return
                }
            }
        }
        PrepRunner.ledger(job: j.refresh ? "prep_refresh" : "prep", route: routeName, usd: usd, meta: meta, ok: ok)
        // 0.10.0 (round 2, L5): a failed refresh during the call leaves the call's sheet as it was (the sidecar writes
        // nothing on failure) and the tips window says so; never an old brief instead.
        if SheetPipeline.liveOutcome(ok: ok, duringCall: j.live && CallEngine.shared.isRunning) == .keepPrevious {
            PrepRunner.shared.liveFailure = L("sheet.live.refreshFailed", ["err": String(result.prefix(160))])
        }
        end(j, ok: ok)
    }

    private func fail(_ j: Job, _ err: String) {
        result = err
        if SheetPipeline.liveOutcome(ok: false, duringCall: j.live && CallEngine.shared.isRunning) == .keepPrevious {
            PrepRunner.shared.liveFailure = L("sheet.live.refreshFailed", ["err": String(err.prefix(160))])
        }
        end(j, ok: false)
    }

    private func end(_ j: Job, ok: Bool, notify: Bool = true) {
        running = false
        job = nil
        let pr = PrepRunner.shared
        pr.running = false
        pr.result = result
        if notify { UpNext.shared.prepFinished(id: j.prep.callID, base: ok ? j.base : nil, ok: ok) }
    }

    /// Stop (PrepRunner.cancel calls this first): the sidecar ends; PrepRunner reports the stop.
    func cancel() {
        guard let p = process else { return }
        (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process = nil
        p.terminate()
        running = false
        job = nil
        set(0, "")
    }
}
