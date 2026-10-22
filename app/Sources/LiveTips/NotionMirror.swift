import Foundation
import LiveTipsCore

/// Runs tools/notion-mirror for the user (M1): "Set up sync" in Settings > General copies the script
/// from the app to <work>/Tools/notion-mirror, writes its config, finds the Control Tower databases
/// with the Notion token from the Keychain (--discover) and starts the first full run. After that the
/// app runs it every 2 hours, never during a call. A mirror the user already runs with their own
/// launchd job (a config without "managed_by") is left alone: the app only reads its status.
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
    private var token: String? { SecretStore(service: Bundle.main.bundleIdentifier ?? "io.github.example.livetips").get(.notionToken) }

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
        guard !c.workRoot.isEmpty else { done(false, "Set the work folder first."); return }
        guard token != nil else { done(false, "Add the Notion token in Settings > Keys first."); return }
        if Self.mode(workRoot: c.workRoot) == "external" {
            done(false, "A mirror is already set up in \(Self.dir(workRoot: c.workRoot)) with its own schedule. Live Tips reads it and leaves it alone.")
            return
        }
        let fm = FileManager.default
        let dst = Self.dir(workRoot: c.workRoot)
        guard let src = Bundle.main.resourceURL?.appendingPathComponent("notion-mirror").path, fm.fileExists(atPath: src) else {
            done(false, "This build has no notion-mirror inside."); return
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
        if let out = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: URL(fileURLWithPath: Self.configPath(workRoot: c.workRoot)), options: .atomic)
        }
        run(["--discover"]) { [weak self] ok, out in
            guard ok else { done(false, "Could not find the Control Tower databases: \(out)"); return }
            self?.run(["--full"], done: nil)
            done(true, out + "\nThe first full run is going in the background; it can take a few minutes.")
        }
    }

    func syncNow() { run([], done: nil) }

    private func run(_ args: [String], done: (@Sendable (Bool, String) -> Void)?) {
        let c = config
        guard let tok = token else { done?(false, "No Notion token"); return }
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
