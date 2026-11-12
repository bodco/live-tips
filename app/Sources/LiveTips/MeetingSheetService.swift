import AppKit
import Combine
import LiveTipsCore
import SwiftUI
import UserNotifications

// 0.10.0 (Meeting Sheet, phase 4): the UI side of the sidecar `python -m livetips_m0.sheet <cmd> --request <json>`
// (contract: research/pacenote-meeting-sheet-build-plan-2026-11-12.md). Where the sheet of a call lives, a small
// cache of loaded sheets, the CLI runner (one-shot and streaming for build / refresh), the route check used by
// Quick, Expert and Start call (every AI route counts, not Claude Code only), the settings of Settings > Meeting
// Sheet, the series memory of Quick prep and the reminder before a call. SheetRunner (pipeline) may take over the
// build queue later; this adapter only needs the CLI.

// MARK: - Files of a call

@MainActor
enum SheetFiles {
    static let dayFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()
    static let baseFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"; return f }()

    static func liveFolder(_ m: StartCallModel) -> String? {
        guard let r = m.root, !r.isEmpty else { return nil }
        return (r as NSString).appendingPathComponent("live")
    }

    /// <root>/live/prep-<yyyy-MM-dd-HHmm>-<slug>: the base a new sheet is written to (the same name the recorder adopts).
    static func newBase(for m: StartCallModel) -> String? {
        guard let live = liveFolder(m) else { return nil }
        return (live as NSString).appendingPathComponent("prep-\(baseFormat.string(from: m.callDate))-\(StartCallModel.slugify(m.effectiveTitle))")
    }

    /// All sheets of this call's series in its project, newest name first: (path, day in the name).
    static func seriesSheets(_ m: StartCallModel) -> [(path: String, day: String)] {
        guard let live = liveFolder(m), let names = try? FileManager.default.contentsOfDirectory(atPath: live) else { return [] }
        let slug = StartCallModel.slugify(m.effectiveTitle)
        return names.filter { $0.hasPrefix("prep-") && $0.hasSuffix(".sheet.json") }
            .compactMap { n -> (String, String)? in
                let core = String(n.dropFirst(5).dropLast(".sheet.json".count))      // yyyy-MM-dd-HHmm-<slug>
                guard core.count > 16 else { return nil }
                let rest = String(core.dropFirst(16))
                guard rest == slug || StartCallModel.titleMatch(rest, m.effectiveTitle) else { return nil }
                return ((live as NSString).appendingPathComponent(n), String(core.prefix(10)))
            }
            .sorted { $0.0 > $1.0 }
    }

    /// Home and the pages ask many times a second: the answer is kept for 3 seconds per call.
    private static var recent: [UUID: (at: Date, path: String?)] = [:]

    /// The sheet of this call: its prep base, else a sheet of the same series named for the call's day.
    static func path(for m: StartCallModel) -> String? {
        if let r = recent[m.id], Date().timeIntervalSince(r.at) < 3 { return r.path }
        let p = findPath(for: m)
        recent[m.id] = (Date(), p)
        return p
    }

    static func findPath(for m: StartCallModel) -> String? {
        let fm = FileManager.default
        if let b = m.prepBase, fm.fileExists(atPath: b + ".sheet.json") { return b + ".sheet.json" }
        let day = dayFormat.string(from: m.callDate)
        return seriesSheets(m).first { $0.day == day }?.path
    }

    /// The newest sheet of the series before this call's day (Quick prep repeats its setup).
    static func earlier(for m: StartCallModel) -> String? {
        let day = dayFormat.string(from: m.callDate)
        return seriesSheets(m).first { $0.day < day }?.path
    }

    /// <base>.sheet.v<N>.json, newest first.
    static func versions(of sheetPath: String) -> [(n: Int, path: String)] {
        let base = String(sheetPath.dropLast(".sheet.json".count))
        let dir = (base as NSString).deletingLastPathComponent, name = (base as NSString).lastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names.compactMap { n -> (Int, String)? in
            guard n.hasPrefix(name + ".sheet.v"), n.hasSuffix(".json"),
                  let v = Int(n.dropFirst(name.count + 8).dropLast(5)) else { return nil }
            return (v, (dir as NSString).appendingPathComponent(n))
        }.sorted { $0.0 > $1.0 }
    }

    static func base(of sheetPath: String) -> String { String(sheetPath.dropLast(".sheet.json".count)) }
}

/// Loaded sheets by path and modification time: the views read a sheet many times per second.
@MainActor
final class SheetCache {
    static let shared = SheetCache()
    private var map: [String: (Date, MeetingSheet)] = [:]

    func load(_ path: String) -> MeetingSheet? {
        guard let m = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { map[path] = nil; return nil }
        if let c = map[path], c.0 == m { return c.1 }
        guard let s = try? MeetingSheetIO.load(path) else { return nil }
        map[path] = (m, s)
        return s
    }

    func save(_ s: MeetingSheet, to path: String) -> Bool {
        do { try MeetingSheetIO.save(s, to: path) } catch { return false }
        map[path] = nil
        return true
    }

    /// 0.10.0 (Meeting Sheet, hardening): the file changed outside the cache (a version swapped in).
    func forget(_ path: String) { map[path] = nil }

    /// The readiness of a call's sheet, nil when it has none.
    func badge(for m: StartCallModel) -> ReadinessBadge? {
        guard let p = SheetFiles.path(for: m), let s = load(p) else { return nil }
        return s.readinessBadge
    }
}

// MARK: - The sidecar CLI

enum SheetCLI {
    struct Result { var code: Int32; var json: [String: Any]?; var lines: [[String: Any]]; var text: String }

    static func now() -> String { ISO8601DateFormatter().string(from: Date()) }

    /// The request file: <app root>/state/sheet/<id>.request.json (or <base>.sheet.request.json for a build).
    static func writeRequest(_ req: [String: Any], to path: String) -> Bool {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard let d = try? JSONSerialization.data(withJSONObject: req, options: [.prettyPrinted, .sortedKeys]) else { return false }
        return (try? d.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }

    static var stateDir: String {
        let c = AppConfig.load(from: AppPaths.config)
        return ((c.effectiveAppRoot(appSupport: AppPaths.support.path) as NSString).appendingPathComponent("state") as NSString).appendingPathComponent("sheet")
    }

    static var appRoot: String { AppConfig.load(from: AppPaths.config).effectiveAppRoot(appSupport: AppPaths.support.path) }

    static func process(_ cmd: String, _ args: [String]) -> Process? {
        let c = AppConfig.load(from: AppPaths.config)
        guard !c.engine.sidecarPython.isEmpty, !c.engine.sidecarDir.isEmpty else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: c.engine.sidecarPython)
        p.arguments = ["-m", "livetips_m0.sheet", cmd] + args
        p.currentDirectoryURL = URL(fileURLWithPath: c.engine.sidecarDir)
        var env = AIRoute.env(job: "prep", config: c)
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        p.environment = env
        return p
    }

    /// One-shot command on a background thread; done on the main thread. The last JSON object of stdout is `json`.
    static func run(_ cmd: String, request: [String: Any]? = nil, args: [String] = [], done: @escaping (Result) -> Void) {
        if SheetShots.active { return }      // 0.10.0 (Meeting Sheet, smoke): offscreen pictures never start the sidecar
        var a = args
        if let r = request {
            let path = (stateDir as NSString).appendingPathComponent("\(cmd)-\(UUID().uuidString.prefix(8)).request.json")
            guard writeRequest(r, to: path) else { done(Result(code: 3, json: nil, lines: [], text: "request")); return }
            a = ["--request", path] + a
        }
        guard let p = process(cmd, a) else { done(Result(code: 127, json: nil, lines: [], text: L("sheet.ui.err.noEngine"))); return }
        DispatchQueue.global().async {
            let o = Pipe(), e = Pipe()
            p.standardOutput = o; p.standardError = e
            var r = Result(code: 127, json: nil, lines: [], text: "")
            if (try? p.run()) != nil {
                let out = o.fileHandleForReading.readDataToEndOfFile()
                let err = e.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                r = parse(out, code: p.terminationStatus)
                if r.json == nil { r.text = String(decoding: err.suffix(600), as: UTF8.self) }
            }
            DispatchQueue.main.async { done(r) }
        }
    }

    static func parse(_ data: Data, code: Int32) -> Result {
        let text = String(decoding: data, as: UTF8.self)
        // One pretty-printed object (most commands) or JSON lines (progress, then the result).
        if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return Result(code: code, json: o, lines: [o], text: text) }
        var lines: [[String: Any]] = []
        for l in text.split(separator: "\n") where l.hasPrefix("{") && l.hasSuffix("}") {
            if let o = try? JSONSerialization.jsonObject(with: Data(l.utf8)) as? [String: Any] { lines.append(o) }
        }
        return Result(code: code, json: lines.last, lines: lines, text: text)
    }

    /// The error a result carries, for a status line ("... not implemented yet" while the pipeline is being built).
    static func error(_ r: Result) -> String? {
        if let e = r.json?["error"] as? String { return e }
        if r.code != 0 { return r.text.isEmpty ? L("sheet.ui.err.engine", ["code": "\(r.code)"]) : String(r.text.suffix(300)) }
        return nil
    }
}

/// A build or a refresh that streams progress: {"progress":0.4,"stage":"...","source_id":...}, then {"done":true,"sheet":path}.
@MainActor
final class SheetJob: ObservableObject, Identifiable {
    let id = UUID()
    let callID: UUID?
    let kind: String                      // build | refresh
    @Published var progress: Double = 0
    @Published var stage = ""
    @Published var sourceState: [String: String] = [:]     // source id -> reading | read | failed | skipped
    @Published var sourceNote: [String: String] = [:]
    @Published var pass: Int?
    @Published var passes: Int?
    @Published var done = false
    @Published var failed: String?
    @Published var sheetPath: String?
    @Published var notifyWhenDone = false
    let started = Date()
    private var process: Process?
    var title = ""

    init(callID: UUID?, kind: String) { self.callID = callID; self.kind = kind }

    func start(_ req: [String: Any], requestPath: String) {
        // 0.10.0 (Meeting Sheet, round 2): the sidecar reads Retry / Skip from this job's control file
        var req = req
        _ = SheetCLI.writeRequest(["actions": [Any]()], to: ownControlPath)
        req["control"] = ownControlPath
        req["control_wait_s"] = 30
        guard SheetCLI.writeRequest(req, to: requestPath) else { failed = "request"; return }
        guard let p = SheetCLI.process(kind, ["--request", requestPath]) else { failed = L("sheet.ui.err.noEngine"); return }
        let o = Pipe(), e = Pipe()
        p.standardOutput = o; p.standardError = e
        process = p
        o.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            let text = String(decoding: d, as: UTF8.self)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(text) } }
        }
        p.terminationHandler = { [weak self] pr in
            let err = String(decoding: e.fileHandleForReading.readDataToEndOfFile().suffix(400), as: UTF8.self)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finish(code: pr.terminationStatus, err: err) } }
        }
        do { try p.run() } catch { failed = error.localizedDescription }
    }

    private var buffer = ""
    private func consume(_ text: String) {
        buffer += text
        while let r = buffer.range(of: "\n") {
            let line = String(buffer[..<r.lowerBound]); buffer.removeSubrange(..<r.upperBound)
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let p = o["progress"] as? Double { progress = p }
            if let s = o["stage"] as? String { stage = s }
            if let n = o["pass"] as? Int { pass = n }
            if let n = o["passes"] as? Int { passes = n }
            if let sid = o["source_id"] as? String {
                // 0.10.0 (round 2): a denied / unsupported source is failed (Retry / Skip), a skipped one skipped
                let acc = o["access"] as? String ?? ""
                let bad = acc == "denied" || acc == "unsupported"
                sourceState[sid] = (o["state"] as? String) ?? (o["skipped"] as? Bool == true ? "skipped" : (o["error"] != nil || bad) ? "failed" : "read")
                if let note = (o["error"] as? String) ?? (o["note"] as? String) { sourceNote[sid] = note }
                else if bad { sourceNote[sid] = L("sheet.ui.access." + acc) }
            }
            if let e = o["error"] as? String, o["source_id"] == nil { failed = e }
            if o["done"] as? Bool == true { done = true; sheetPath = o["sheet"] as? String; progress = 1 }
        }
    }

    private func finish(code: Int32, err: String) {
        if !buffer.isEmpty { consume("\n") }
        process = nil
        if !done && failed == nil { failed = code == 0 ? L("sheet.ui.err.noResult") : (err.isEmpty ? L("sheet.ui.err.engine", ["code": "\(code)"]) : err) }
        SheetJobs.shared.finished(self)
    }

    func stop() {
        if following { PrepRunner.shared.cancel(); sink = nil } else { process?.terminate() }
        failed = L("sheet.ui.build.stopped")
    }

    // MARK: following SheetRunner (pipeline): Prepare and Refresh of a call go through it

    private var sink: AnyCancellable?
    private var sawRunning = false
    private var sawPending = false            // 0.10.0 (Meeting Sheet, hardening)
    private(set) var following = false

    /// Mirror SheetRunner's state while it builds this call's sheet (queued in Up next until it starts).
    func follow(_ r: SheetRunner) {
        following = true
        sink = r.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.sync(r) } }
        }
        sync(r)
    }

    private func sync(_ r: SheetRunner) {
        guard let id = callID, !done, failed == nil else { return }
        if r.running && r.callID == id {
            sawRunning = true
            progress = r.progress
            stage = r.detail.isEmpty ? r.stage : r.stage + " · " + (r.detail as NSString).lastPathComponent
            pass = r.pass > 0 ? r.pass : nil
            passes = r.passes > 0 ? r.passes : nil
            for (k, v) in r.sources {
                sourceState[k] = v.status == "ok" ? "reading" : v.status.isEmpty ? "reading" : v.status
                if v.access == "denied" || v.access == "unsupported" { sourceState[k] = "failed"; sourceNote[k] = L("sheet.ui.access." + v.access) }
            }
        } else if let p = r.pendingSwitch, p.callID == id || r.callID == id {
            sawPending = true
            stage = r.result                       // the route question is open (inline in the UI); still waiting
        } else if sawPending && !sawRunning {
            // 0.10.0 (Meeting Sheet, hardening): Not now (or Stop) on the route question: no build comes, the job ends
            // (it used to stay "Building 0%" and block Prepare)
            sink = nil
            failed = r.result.isEmpty ? L("sheet.switch.declined") : r.result
            SheetJobs.shared.finished(self)
        } else if sawRunning {
            sink = nil
            if let p = r.sheetPath, FileManager.default.fileExists(atPath: p) {
                for (k, v) in sourceState where v == "reading" { sourceState[k] = "read" }
                sheetPath = p; progress = 1; done = true
            } else {
                failed = r.result.isEmpty ? L("sheet.ui.err.noResult") : r.result
            }
            SheetJobs.shared.finished(self)
        } else if let m = UpNext.shared.items.first(where: { $0.id == id }), UpNext.shared.prepState(m) == .queued {
            stage = L("badge.queued")
        }
    }

    /// Retry or skip one source that failed: the sidecar takes a small control file next to the request.
    private var ownControlPath: String { (SheetCLI.stateDir as NSString).appendingPathComponent("control-\(id.uuidString.prefix(8)).json") }

    func control(_ action: String, source: String) {
        sourceState[source] = action == "skip" ? "skipped" : "reading"
        // a build SheetRunner runs reads the runner's control file; a CLI job its own (both: sheet/build.py Control)
        let path = following ? (SheetRunner.controlPath ?? ownControlPath) : ownControlPath
        // 0.10.0 (round 2): the file is {"actions": [...]} (sheet/build.py Control); read it in that shape
        let o = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))) as? [String: Any]
        let list = SheetPipeline.controlActions(o?["actions"] as? [[String: String]] ?? [], add: action, source: source)
        _ = SheetCLI.writeRequest(["actions": list], to: path)
    }
}

@MainActor
final class SheetJobs: ObservableObject {
    static let shared = SheetJobs()
    @Published var jobs: [SheetJob] = []

    func job(for callID: UUID) -> SheetJob? { jobs.last { $0.callID == callID && !$0.done && $0.failed == nil } }
    func last(for callID: UUID) -> SheetJob? { jobs.last { $0.callID == callID } }

    /// A build or refresh that SheetRunner runs (Prepare in Quick / Expert, Refresh on the page).
    @discardableResult
    func follow(kind: String, call: StartCallModel) -> SheetJob {
        let j = SheetJob(callID: call.id, kind: kind)
        j.title = call.effectiveTitle
        jobs.append(j)
        j.follow(SheetRunner.shared)
        return j
    }

    /// A one-off job run here through the CLI (a refresh of a sheet with no call in Up next).
    @discardableResult
    func start(kind: String, request: [String: Any], call: StartCallModel?, title: String) -> SheetJob {
        let j = SheetJob(callID: call?.id, kind: kind)
        j.title = title
        jobs.append(j)
        let base = (request["out"] as? String) ?? ((SheetCLI.stateDir as NSString).appendingPathComponent(j.id.uuidString))
        j.start(request, requestPath: base + ".sheet.request.json")
        return j
    }

    func finished(_ j: SheetJob) {
        objectWillChange.send()
        if let p = j.sheetPath, let id = j.callID, let m = UpNext.shared.items.first(where: { $0.id == id }) {
            m.prepBase = SheetFiles.base(of: p); m.prepFailed = false
        }
        if j.notifyWhenDone {
            let c = UNMutableNotificationContent()
            c.title = j.done ? L("sheet.ui.notif.built", ["title": j.title]) : L("sheet.ui.notif.failed", ["title": j.title])
            c.body = j.failed ?? L("sheet.ui.notif.builtBody")
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: SheetReminder.idPrefix + "built-" + (j.callID?.uuidString ?? ""), content: c, trigger: nil))
        }
    }
}

// MARK: - Routes: every AI route counts (fixes Start call's Claude-Code-only check)

@MainActor
enum SheetRoutes {
    static let all = [AIRoute.code, AIRoute.codex, AIRoute.agy, AIRoute.api, AIRoute.openai, AIRoute.gemini, AIRoute.local]

    /// Settings > AI > Preparation.
    static var preferred: String { SettingsWindow.model.config.ai.prep }

    /// Can this route build a sheet now? nil = yes, else the reason in one line.
    static func problem(_ r: String) -> String? {
        if ProcessInfo.processInfo.environment["LT_SUPPORT_DIR"] != nil { return ["noai", "first"].contains(HomeView.shotState) ? L("sheet.ui.route.noAI") : nil }
        let runner = PrepRunner.shared
        switch r {
        case AIRoute.code:
            if PrepRunner.claudePath == nil { return L("call.hint.noClaudeCode") }
            if runner.loggedIn == false { return L("call.hint.notSignedIn") }
        case AIRoute.api: if !runner.hasAPIKey { return L("call.hint.noKey") }
        case AIRoute.openai: if !runner.hasOpenAIKey { return L("sheet.ui.route.noKey", ["route": AIRoute.name(r)]) }
        case AIRoute.gemini: if !runner.hasGeminiKey { return L("sheet.ui.route.noKey", ["route": AIRoute.name(r)]) }
        case AIRoute.codex: if CodexAccount.cliPath == nil { return L("sheet.ui.route.notSet", ["route": AIRoute.name(r)]) }
        case AIRoute.agy: if AgyAccount.cliPath == nil { return L("sheet.ui.route.notSet", ["route": AIRoute.name(r)]) }
        default: break
        }
        if AIRoute.isDown(r) { return L("sheet.ui.route.down", ["route": AIRoute.name(r)]) }
        return nil
    }

    static func ready(_ r: String) -> Bool { problem(r) == nil }

    /// The route a call prepares on: the preferred one. Never switched silently: when it is out, the UI asks.
    static func firstReady() -> String? { ([preferred] + all).first { ready($0) } }

    /// One pass of the model in tokens, for the Size step when the sidecar does not say (rules/ai.yaml has the truth).
    static func window(_ r: String) -> Int {
        switch r {
        case AIRoute.codex, AIRoute.openai: return 272_000
        case AIRoute.gemini, AIRoute.agy: return 1_000_000
        case AIRoute.local: return 64_000
        default: return 200_000
        }
    }
}

// MARK: - Settings > Meeting Sheet

@MainActor
final class SheetPrefs: ObservableObject {
    static let shared = SheetPrefs()
    private let d = UserDefaults.standard

    @Published var rules: [SheetModeRule] { didSet { save("sheetModeRules", rules) } }
    @Published var focus: [String] { didSet { d.set(focus, forKey: "sheetFocusFields") } }
    @Published var staleMonths: Int { didSet { d.set(staleMonths, forKey: "sheetStaleMonths") } }
    @Published var remindMinutes: Int { didSet { d.set(remindMinutes, forKey: "sheetRemindMinutes") } }
    /// Always Quick or always Expert for every call ("" = by the rules).
    @Published var forced: String { didSet { d.set(forced, forKey: "sheetModeForced") } }

    static let defaultFocus = ["Budget", "Decision maker", "Next step", "Red flags"]

    private init() {
        rules = (d.data(forKey: "sheetModeRules").flatMap { try? JSONDecoder().decode([SheetModeRule].self, from: $0) }) ?? SheetModeRule.defaults
        focus = d.stringArray(forKey: "sheetFocusFields") ?? Self.defaultFocus
        staleMonths = d.object(forKey: "sheetStaleMonths") as? Int ?? 6
        remindMinutes = d.object(forKey: "sheetRemindMinutes") as? Int ?? 30
        forced = d.string(forKey: "sheetModeForced") ?? ""
    }

    private func save<T: Encodable>(_ key: String, _ v: T) { if let data = try? JSONEncoder().encode(v) { d.set(data, forKey: key) } }

    /// The mode a call opens in (S1a note: Quick for a series with an earlier sheet, internal calls, stand-ups and
    /// client syncs; Expert for a new external domain, a sales intro and presentations).
    func mode(for m: StartCallModel, preset: SheetPresetInfo?) -> SheetMode {
        if forced == "quick" { return .quick }
        if forced == "expert" { return .expert }
        let theirs = m.audience == "team" ? [] : SheetDraft.theirPeople(m)
        let known: [String] = SheetFiles.earlier(for: m).flatMap { SheetCache.shared.load($0) }?.participants?.theirs?.compactMap(\.domain) ?? []
        return SheetModeDecider.decide(rules: rules, preset: preset?.id ?? SheetDraft.suggestedPreset(m), presetBase: preset?.base,
                                       presetMode: preset?.mode ?? "quick", earlierSheet: SheetFiles.earlier(for: m) != nil,
                                       theirDomains: theirs.compactMap(\.domain), knownDomains: known, theirCount: theirs.count)
    }
}

/// A preset from `python -m livetips_m0.sheet presets` (shared and the user's own).
struct SheetPresetInfo: Identifiable, Equatable {
    var id: String; var name: String; var mode: String; var blocks: [String]; var readiness: [String]
    var source: String; var base: String?; var method: String?
    var mine: Bool { source != "shared" }
}

@MainActor
final class SheetLibrary: ObservableObject {
    static let shared = SheetLibrary()
    @Published var presets: [SheetPresetInfo] = SheetLibrary.fallback
    @Published var blockTitles: [String: String] = [:]
    @Published var blockFields: [String: String] = [:]
    @Published var methods: [String] = ["bant", "spiced", "meddic", "general"]
    @Published var ruleGaps: [String: String] = [:]
    @Published var loaded = false
    @Published var note = ""

    static let fallback: [SheetPresetInfo] = [
        .init(id: "sales_intro", name: "Sales intro", mode: "expert", blocks: ["header", "my_focus", "overview", "company", "signals", "tech_stack", "contact", "qualification", "fit", "history", "questions", "best_outcome", "red_lines", "gaps"], readiness: [], source: "shared"),
        .init(id: "upsell", name: "Upsell", mode: "quick", blocks: ["header", "my_focus", "overview", "company", "fit", "history", "project_context", "action_items", "questions", "best_outcome", "red_lines", "gaps"], readiness: [], source: "shared"),
        .init(id: "repeat_call", name: "Repeat call", mode: "quick", blocks: ["header", "my_focus", "overview", "company", "signals", "contact", "qualification", "history", "questions", "best_outcome", "gaps"], readiness: [], source: "shared"),
        .init(id: "client_sync", name: "Client sync", mode: "quick", blocks: ["header", "my_focus", "overview", "history", "project_context", "agenda", "action_items", "questions", "best_outcome", "red_lines", "gaps"], readiness: [], source: "shared"),
        .init(id: "internal_presentation", name: "Internal or presentation", mode: "expert", blocks: ["header", "my_focus", "overview", "agenda", "structure_roles", "red_lines", "gaps"], readiness: [], source: "shared"),
        .init(id: "standup", name: "Stand-up", mode: "quick", blocks: ["header", "standup_since", "standup_today", "standup_blockers", "standup_waiting"], readiness: [], source: "shared"),
        .init(id: "interview", name: "Interview", mode: "expert", blocks: ["header", "my_focus", "overview", "interview_candidate", "interview_role", "questions", "red_lines", "structure_roles", "gaps"], readiness: [], source: "shared"),
        .init(id: "blank", name: "Blank", mode: "quick", blocks: ["header", "my_focus"], readiness: [], source: "shared"),
    ]

    func preset(_ id: String) -> SheetPresetInfo? { presets.first { $0.id == id } }
    func title(_ type: String) -> String { blockTitles[type] ?? SheetEdit.blockTitle(BlockType(rawValue: type)) }

    func reload() {
        SheetCLI.run("presets", args: ["--app-root", SheetCLI.appRoot]) { r in
            guard let j = r.json, let ps = j["presets"] as? [[String: Any]] else { self.note = SheetCLI.error(r) ?? ""; return }
            self.presets = ps.compactMap { p in
                guard let id = p["id"] as? String else { return nil }
                return SheetPresetInfo(id: id, name: p["name"] as? String ?? id, mode: p["mode"] as? String ?? "quick",
                                       blocks: p["blocks"] as? [String] ?? [], readiness: p["readiness"] as? [String] ?? [],
                                       source: p["source"] as? String ?? "shared", base: p["base"] as? String, method: p["method"] as? String)
            }
            if let b = j["blocks"] as? [String: [String: Any]] {
                self.blockTitles = b.compactMapValues { $0["title"] as? String }
                self.blockFields = b.compactMapValues { $0["fields"] as? String }
            }
            if let m = j["methods"] as? [String], !m.isEmpty { self.methods = m }
            if let rr = j["readiness_rules"] as? [String: [String: Any]] { self.ruleGaps = rr.compactMapValues { $0["gap"] as? String } }
            self.loaded = true
        }
    }

    /// save | rename | duplicate | delete of a user preset (delete moves the file aside, never rm).
    func change(_ req: [String: Any], done: @escaping (String?) -> Void = { _ in }) {
        var r = req; r["app_root"] = SheetCLI.appRoot
        SheetCLI.run("presets", request: r) { res in
            let e = SheetCLI.error(res)
            if e == nil { self.reload() }
            done(e)
        }
    }
}

// MARK: - Quick prep remembers the series (the S1a "Next time Pacenote remembers this setup")

@MainActor
final class SheetSeriesMemory {
    static let shared = SheetSeriesMemory()
    struct Entry: Codable { var preset: String; var mode: String; var route: String; var sources: [[String: String]]; var language: String; var savedAt: Date }
    private var map: [String: Entry] = [:]
    private var path: URL { AppPaths.support.appendingPathComponent("sheet-series.json") }

    private init() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: path), let m = try? dec.decode([String: Entry].self, from: d) { map = m }
    }

    func lookup(_ m: StartCallModel) -> Entry? { SeriesMemory.shared.keys(for: m).lazy.compactMap { self.map[$0] }.first }

    func remember(_ m: StartCallModel, _ e: Entry) {
        for k in SeriesMemory.shared.keys(for: m) { map[k] = e }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(map) { try? d.write(to: path, options: .atomic) }
    }
}

// MARK: - Opening a source

@MainActor
enum SheetOpen {
    /// A click on a source number: a link opens in the browser, a file in its default app (Finder when it is a folder).
    static func source(_ s: SheetSource, locator: FactLocator? = nil) {
        if let u = locator?.url ?? s.uri, let url = URL(string: u), url.scheme != nil { NSWorkspace.shared.open(url); return }
        if let p = s.path {
            let full = (p as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: full) {
                if StartCallModel.isDir(full) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: full)]) }
                else { NSWorkspace.shared.open(URL(fileURLWithPath: full)) }
            }
        }
    }

    static func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
}

// MARK: - Labels: icon and text, never colour alone

enum SheetLabels {
    static func status(_ f: SheetFact) -> (text: String, icon: String, color: Color)? {
        switch f.status {
        case .notFound: return (L("sheet.ui.status.notFound"), "questionmark.circle", PN.C.pending)
        case .needsCheck: return (L("sheet.ui.status.check"), "exclamationmark.circle", PN.C.pending)
        case .conflict: return (L("sheet.ui.status.conflict"), "arrow.left.arrow.right.circle", PN.C.pending)
        case .stale: return (L("sheet.ui.status.old"), "clock.arrow.circlepath", PN.C.onMe)
        case .edited: return (L("sheet.ui.status.edited"), "pencil.circle", PN.C.docs)
        default: return nil
        }
    }

    static func readiness(_ b: ReadinessBadge) -> (text: String, color: Color, fill: Color) {
        switch b.state {
        case .some(.ready): return (L("sheet.ui.ready.ready"), PN.C.turn, PN.C.turn)
        case .some(.almost): return (L("sheet.ui.ready.almost"), PN.C.pending, PN.C.pendingFill)
        case .some(.notReady): return (L("sheet.ui.ready.notReady"), PN.C.pending, PN.C.pendingFill)
        default: return (L("sheet.ui.ready.unknown"), PN.C.text3, PN.C.text3)
        }
    }

    static func readinessLine(_ b: ReadinessBadge) -> String {
        let t = readiness(b).text
        return b.gaps > 0 ? t + " · " + L("sheet.ui.gaps", ["n": "\(b.gaps)"]) : t
    }

    static func access(_ s: SheetSource) -> (text: String, icon: String, color: Color) {
        switch s.access {
        case .ok: return (L("sheet.ui.access.ok"), "checkmark.circle.fill", PN.C.turn)
        case .denied: return (L("sheet.ui.access.denied"), "lock.circle", PN.C.pending)
        case .unsupported: return (L("sheet.ui.access.unsupported"), "nosign", PN.C.pending)
        default: return (L("sheet.ui.access.pending"), "hourglass", PN.C.text3)
        }
    }

    static func used(_ u: SourceUse) -> String { L("sheet.ui.used." + u.rawValue) }

    static func fix(_ a: FixAction) -> String { L("sheet.ui.fix." + a.rawValue) }

    static func icon(_ t: SourceType) -> String {
        switch t {
        case .file, .folderFile: return "doc"
        case .gdoc, .gsheet, .gslides, .driveFile: return "doc.richtext"
        case .notion: return "n.square"
        case .web, .webPage, .webSearch: return "globe"
        case .linkedin, .linkedinManual: return "person.crop.square"
        case .text, .transcript: return "text.alignleft"
        case .prevCall: return "clock.arrow.circlepath"
        case .tracker: return "checklist"
        case .crm: return "person.2"
        case .projectState, .digest: return "folder"
        default: return "doc"
        }
    }

    static func kind(_ t: SourceType) -> String { L("sheet.ui.src." + t.rawValue) }

    static func tokens(_ n: Int?) -> String {
        guard let n = n else { return "" }
        return n >= 1000 ? L("sheet.ui.tokensK", ["n": String(format: n >= 10000 ? "%.0f" : "%.1f", Double(n) / 1000)]) : L("sheet.ui.tokens", ["n": "\(n)"])
    }

    static func date(_ iso: String?) -> String {
        guard let s = iso else { return "" }
        let f = ISO8601DateFormatter()
        let d = f.date(from: s) ?? { let g = DateFormatter(); g.dateFormat = "yyyy-MM-dd"; return g.date(from: String(s.prefix(10))) }()
        guard let d else { return s }
        let o = DateFormatter(); o.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US")
        o.setLocalizedDateFormatFromTemplate(s.count > 10 ? "MMMdHHmm" : "MMMd")
        return o.string(from: d)
    }
}

/// The readiness pill (Ready / Almost · 2 gaps / Not ready): bright orange in both themes when not ready.
struct SheetReadinessPill: View {
    let badge: ReadinessBadge
    var body: some View {
        let l = SheetLabels.readiness(badge)
        Label(SheetLabels.readinessLine(badge), systemImage: badge.symbol)
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(l.color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(l.fill.opacity(0.16), in: Capsule())
            .lineLimit(1).fixedSize()
    }
}

/// Home and the call pages: a call whose sheet is built shows its readiness instead of "Brief ready".
@MainActor
enum SheetBadges {
    static func state(_ m: StartCallModel?, _ st: CallState) -> CallState {
        guard st == .ready, let m, let b = SheetCache.shared.badge(for: m) else { return st }
        return b.state == .ready || b.state == nil ? .ready : .notReady
    }

    static func text(_ m: StartCallModel?, _ st: CallState) -> String? {
        guard st == .ready, let m, let b = SheetCache.shared.badge(for: m) else { return nil }
        return SheetLabels.readinessLine(b)
    }
}

// MARK: - The reminder before a call (S7)

@MainActor
final class SheetReminder {
    static let shared = SheetReminder()
    static let idPrefix = "pn-sheet-"
    static let category = "pn-sheet-cat"
    static let openGaps = "pn-sheet-open-gaps"
    private var timer: Timer?
    /// 0.10.0 (Meeting Sheet, hardening): kept between app starts, so a restart does not send a reminder again.
    private static let sentKey = "sheet.remind.sent"
    private var sent: [String] = UserDefaults.standard.stringArray(forKey: SheetReminder.sentKey) ?? []

    func start() {
        let open = UNNotificationAction(identifier: Self.openGaps, title: L("sheet.ui.remind.openGaps"), options: [.foreground])
        let cat = UNNotificationCategory(identifier: Self.category, actions: [open], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().getNotificationCategories { have in
            UNUserNotificationCenter.current().setNotificationCategories(have.filter { $0.identifier != SheetReminder.category }.union([cat]))
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in MainActor.assumeIsolated { SheetReminder.shared.tick() } }
    }

    func tick() {
        let minutes = SheetPrefs.shared.remindMinutes
        guard minutes > 0 else { return }
        for m in UpNext.shared.visible {
            let left = m.callDate.timeIntervalSinceNow / 60
            let key = m.id.uuidString + "@" + SheetFiles.baseFormat.string(from: m.callDate)
            guard left > 0, left <= Double(minutes), !sent.contains(key) else { continue }
            guard let p = SheetFiles.path(for: m), let s = SheetCache.shared.load(p) else { continue }
            sent = SheetPipeline.rememberSent(sent, add: key)
            UserDefaults.standard.set(sent, forKey: Self.sentKey)
            let b = s.readinessBadge
            let c = UNMutableNotificationContent()
            c.title = L("sheet.ui.remind.title", ["n": "\(Int(left.rounded()))", "title": m.effectiveTitle])
            if b.gaps == 0 { c.body = L("sheet.ui.remind.ready") } else {
                let gaps = (s.readiness?.gaps ?? []).prefix(2).map(\.text).joined(separator: ", ")
                c.body = L("sheet.ui.remind.gaps", ["state": SheetLabels.readiness(b).text, "n": "\(b.gaps)", "gaps": gaps])
                c.categoryIdentifier = Self.category
            }
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.idPrefix + m.id.uuidString, content: c, trigger: nil))
        }
    }

    /// A click on the reminder (or on Open the gaps): the call's page on the Readiness tab.
    /// 0.10.0 (Meeting Sheet, hardening): the "ready" notification (pn-sheet-built-<id>) opens the call's sheet tab.
    static func open(_ id: String) {
        guard let t = SheetPipeline.notificationTarget(id, prefix: idPrefix),
              let m = UpNext.shared.items.first(where: { $0.id.uuidString == t.call }) else { return }
        if let app = NSApp.delegate as? AppDelegate { HomeWindow.show(delegate: app) }
        UpcomingCallPage.openTab[m.id.uuidString] = t.tab
        UpcomingPages.open(m)
    }
}
