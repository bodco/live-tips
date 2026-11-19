import Foundation
import LiveTipsCore

/// Runs notion-mirror/ for the user (M1): "Set up sync" in Settings > General copies the script
/// from the app to <work>/Tools/notion-mirror, writes its config, finds the Control Tower databases
/// with the Notion token from the Keychain (--discover) and starts the first full run. After that the
/// app runs it every 2 hours, never during a call. A mirror the user already runs with their own
/// launchd job (a config without "managed_by") is left alone: the app only reads its status.
/// INT5 (S3): without Control Tower the mirror runs in Pacenote mode: the config's "pacenote" section (Pacenote's root
/// page and the databases chosen in Settings, rewritten before every run) and the plain pages shared with Pacenote,
/// all under <work>/_notion/. The token is checked (and refreshed on a 401) before every run.
final class NotionMirrorService: @unchecked Sendable {
    nonisolated(unsafe) static let shared = NotionMirrorService()
    private var running: Process?
    private var timer: Timer?
    private(set) var lastMessage = ""
    var isRunning: Bool { running?.isRunning ?? false }

    static func dir(workRoot: String) -> String {
        ((workRoot as NSString).expandingTildeInPath as NSString).appendingPathComponent("Tools/notion-mirror")
    }
    static func configPath(workRoot: String) -> String { (dir(workRoot: workRoot) as NSString).appendingPathComponent("mirror.config.json") }

    /// "managed" (the app runs it), "external" (the user's own job), "none".
    static func mode(workRoot: String) -> String {
        guard !workRoot.isEmpty, let d = try? Data(contentsOf: URL(fileURLWithPath: configPath(workRoot: workRoot))),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return "none" }
        return (o["managed_by"] as? String) == "live-tips" ? "managed" : "external"
    }

    private var config: AppConfig { AppConfig.load(from: AppPaths.config) }
    private var token: String? { NotionAuth.token() }

    func startSchedule() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        let c = config
        guard Self.mode(workRoot: c.workRoot) == "managed", !CallEngine.shared.isRunning, !isRunning else { return }
        let st = MirrorStatus.load(workRoot: c.workRoot)
        if let t = st.lastRunUTC, Date().timeIntervalSince(t) < 2 * 3600 { return }
        let h = Calendar.current.component(.hour, from: Date())
        guard (7...21).contains(h) else { return }
        run([], done: nil)
    }

    /// Copies the script, writes the config, discovers the databases, then starts a full run.
    func setUp(configsDir: String, done: @escaping @Sendable (Bool, String) -> Void) {
        let c = config
        guard !c.workRoot.isEmpty else { done(false, L("set.workFirst") + "."); return }
        guard token != nil else { done(false, L("nm.tokenFirst")); return }
        if Self.mode(workRoot: c.workRoot) == "external" {
            done(false, L("nm.external", ["path": Self.dir(workRoot: c.workRoot)]))
            return
        }
        let fm = FileManager.default
        let dst = Self.dir(workRoot: c.workRoot)
        guard let src = Bundle.main.resourceURL?.appendingPathComponent("notion-mirror").path, fm.fileExists(atPath: src) else {
            done(false, L("nm.noMirror")); return
        }
        try? fm.createDirectory(atPath: dst, withIntermediateDirectories: true)
        for f in ["mirror.py", "run.sh", "install.sh", "README.md", "README.uk.md", "mirror.config.example.json"] {
            let to = (dst as NSString).appendingPathComponent(f)
            try? fm.removeItem(atPath: to)
            try? fm.copyItem(atPath: (src as NSString).appendingPathComponent(f), toPath: to)
        }
        var cfg: [String: Any] = [:]
        if let d = try? Data(contentsOf: URL(fileURLWithPath: (src as NSString).appendingPathComponent("mirror.config.example.json"))),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { cfg = o }
        if let d = try? Data(contentsOf: URL(fileURLWithPath: Self.configPath(workRoot: c.workRoot))),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { cfg.merge(o) { _, new in new } }
        cfg["work_root"] = (c.workRoot as NSString).expandingTildeInPath
        cfg["configs_dir"] = configsDir
        cfg["secrets_file"] = ""
        cfg["token_env"] = ""
        cfg["managed_by"] = "live-tips"
        cfg = NotionMirrorPacenote.merged(cfg, section: Self.pacenoteSection(c))
        if let out = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: URL(fileURLWithPath: Self.configPath(workRoot: c.workRoot)), options: .atomic)
        }
        run(["--discover"]) { [weak self] ok, out in
            guard ok else { done(false, L("nm.noDbs", ["out": out])); return }
            self?.run(["--full"], done: nil)
            done(true, out + "\n" + L("nm.firstRun"))
        }
    }

    func syncNow() { run([], done: nil) }

    /// Pacenote's root page (from the OAuth connection) and the databases chosen in Settings.
    static func pacenoteSection(_ c: AppConfig) -> [String: Any] {
        let st = NotionAuth.store
        let root = st.has(.notionOAuth) ? NotionOAuthRecord.decode(st.get(.notionOAuth))?.rootPageID : nil
        return NotionMirrorPacenote.section(root: root, meetings: c.notionMeetingsDB, tasks: c.notionTasks.database,
                                            decisions: c.notionDecisionsDB, risks: c.notionRisksDB)
    }

    /// A managed config gets the current "pacenote" section before each run; the person's own mirror is never touched.
    private static func refreshSection(_ c: AppConfig) {
        let path = configPath(workRoot: c.workRoot)
        guard mode(workRoot: c.workRoot) == "managed", let d = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        let n = NotionMirrorPacenote.merged(o, section: pacenoteSection(c))
        if let out = try? JSONSerialization.data(withJSONObject: n, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    /// "pacenote" (no Control Tower) or "control_tower", from the managed config; "" when there is none.
    static func layout(workRoot: String) -> String {
        guard !workRoot.isEmpty, let d = try? Data(contentsOf: URL(fileURLWithPath: configPath(workRoot: workRoot))),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], o["projects_ds"] != nil || o["mode"] != nil else { return "" }
        return NotionMirrorPacenote.mode(o)
    }

    private func run(_ args: [String], done: (@Sendable (Bool, String) -> Void)?) {
        guard token != nil else { done?(false, L("nm.tokenFirst")); return }
        NotionAuth.ensureFresh { [weak self] tok in
            guard let tok, !tok.isEmpty else { done?(false, L("nm.tokenFirst")); return }
            self?.launch(args, token: tok, done: done)
        }
    }

    private func launch(_ args: [String], token tok: String, done: (@Sendable (Bool, String) -> Void)?) {
        let c = config
        Self.refreshSection(c)
        let dir = Self.dir(workRoot: c.workRoot)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: c.engine.python.isEmpty ? "/usr/bin/python3" : c.engine.python)
        p.arguments = [(dir as NSString).appendingPathComponent("mirror.py")] + args
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        var env = ProcessInfo.processInfo.environment
        env["NOTION_TOKEN"] = tok
        env["NOTION_MIRROR_CONFIG"] = Self.configPath(workRoot: c.workRoot)
        p.environment = env
        // Output goes to a file, not a pipe: a full run prints a lot and a full pipe would block it.
        let outPath = (dir as NSString).appendingPathComponent(args.first == "--discover" ? "discover.out" : "run.out")
        FileManager.default.createFile(atPath: outPath, contents: nil)
        let fh = FileHandle(forWritingAtPath: outPath)
        p.standardOutput = fh
        p.standardError = fh
        p.terminationHandler = { [weak self] proc in
            try? fh?.close()
            let out = (try? String(contentsOfFile: outPath, encoding: .utf8)) ?? ""
            let tail = out.split(separator: "\n").suffix(4).joined(separator: "\n")
            DispatchQueue.main.async {
                self?.lastMessage = tail
                if self?.running === proc { self?.running = nil }
                done?(proc.terminationStatus == 0, tail)
            }
        }
        do { try p.run(); if args.first != "--discover" { running = p } } catch { done?(false, error.localizedDescription) }
    }
}
