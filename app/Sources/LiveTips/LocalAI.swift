import Foundation
import LiveTipsCore

/// Local AI for the recorder core: the built-in embedding engine (bge-m3 int8 on ONNX Runtime,
/// served on 127.0.0.1 with the small Ollama-compatible API the core already speaks) or the
/// user's Ollama. Writes the choice into the core config before every call.
final class LocalAIService: @unchecked Sendable {
    nonisolated(unsafe) static let shared = LocalAIService()
    static let builtinPort = 11435
    static let defaultThreads = 2
    /// 0.26.3 (owner, 20.11): the server quits after this many seconds without use (embed_server --idle-exit) and is
    /// started again when a call, the index or a brief needs it. Defaults key `embedIdleExit` overrides, 0 = never.
    static let defaultIdleExit = 600
    var idleExit: Int { (UserDefaults.standard.object(forKey: "embedIdleExit") as? Int) ?? Self.defaultIdleExit }
    private var keepAlive: Timer?
    static var builtinURL: String { "http://127.0.0.1:\(builtinPort)" }
    private(set) var process: Process?

    var config: AppConfig { AppConfig.load(from: AppPaths.config) }
    var appRoot: String { config.effectiveAppRoot(appSupport: AppPaths.support.path) }
    var modelDir: String { (appRoot as NSString).appendingPathComponent("models/bge-m3-int8") }
    var modelInstalled: Bool {
        FileManager.default.fileExists(atPath: (modelDir as NSString).appendingPathComponent("model_quantized.onnx"))
            && FileManager.default.fileExists(atPath: (modelDir as NSString).appendingPathComponent("tokenizer.json"))
    }

    var embedded: Bool { let c = config; return c.localAI.enabled && c.localAI.engine == "embedded" }
    var launcherPath: String { (appRoot as NSString).appendingPathComponent("state/embed-server.json") }
    var logPath: String { (appRoot as NSString).appendingPathComponent("logs/local-ai.log") }

    /// Matches the settings. Safe to call often. 0.26.3: the built-in engine is no longer started here unless `start`
    /// is set; it starts when something needs it (a call, the index, a brief through the core's launcher file).
    func apply(start now: Bool = false) {
        if embedded {
            writeLauncher()
            retireOldServer()
            if now { start() }
        } else {
            stop()
            try? FileManager.default.removeItem(atPath: launcherPath)   // the core must not wake an engine that is off
        }
        writeCoreConfig()
    }

    /// Starts the built-in engine when Local AI uses it (index, prep). No-op otherwise.
    func ensure() { if embedded { start() } }

    var arguments: [String] {
        // 0.16.2: 2 threads (was 4) and utility QoS, so background indexing no longer takes four cores for hours;
        // a live line is short and the indexer is paused during a call. Defaults key `embedThreads` overrides.
        let threads = UserDefaults.standard.integer(forKey: "embedThreads")
        return ["-m", "livetips_m0.embed_server", "--model-dir", modelDir, "--port", String(Self.builtinPort),
                "--threads", String(threads > 0 ? threads : Self.defaultThreads), "--idle-exit", String(max(0, idleExit))]
    }

    func start() {
        if process?.isRunning == true { return }
        let c = config
        guard modelInstalled, !c.engine.sidecarPython.isEmpty, !c.engine.sidecarDir.isEmpty else { return }
        if Self.ping(Self.builtinURL) { return }          // already running (started by the core or a previous app run)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: c.engine.sidecarPython)
        p.arguments = arguments
        p.qualityOfService = .utility
        p.currentDirectoryURL = URL(fileURLWithPath: c.engine.sidecarDir)
        var env = ProcessInfo.processInfo.environment
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        p.environment = env
        try? FileManager.default.createDirectory(atPath: (logPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let log = FileHandle.forAppending(path: logPath)
        p.standardOutput = log
        p.standardError = log
        try? p.run()
        process = p
    }

    func stop() {
        holdForCall(false)
        process?.terminate()
        process = nil
    }

    /// 0.26.3: how the core (recorder, `lt`, the Cowork skill) starts the engine when the port refuses
    /// (recorder/src/semantic.py wake_builtin). Written on every apply, so a moved app folder or Python is picked up.
    func writeLauncher() {
        let c = config
        guard modelInstalled, !c.engine.sidecarPython.isEmpty, !c.engine.sidecarDir.isEmpty else { return }
        let d: [String: Any] = ["python": c.engine.sidecarPython, "cwd": c.engine.sidecarDir, "args": arguments, "log": logPath]
        try? FileManager.default.createDirectory(atPath: (launcherPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]),
           (try? Data(contentsOf: URL(fileURLWithPath: launcherPath))) != data {
            try? data.write(to: URL(fileURLWithPath: launcherPath), options: .atomic)
        }
    }

    /// 0.26.3: a server from before 0.26.3 never quits, and one left by an earlier app run is not ours to stop: it held
    /// two cores and 1.3 GB for days. Such a server (no idle exit) is stopped; the next need starts one that sleeps.
    func retireOldServer() {
        guard process == nil, let v = Self.versionInfo(Self.builtinURL) else { return }
        if (v["idle_exit_s"] as? Double ?? 0) > 0 || (v["idle_exit_s"] as? Int ?? 0) > 0 { return }
        guard let pid = Self.listenerPID(port: Self.builtinPort), Self.command(pid).contains("livetips_m0.embed_server") else { return }
        AppLog.app("local AI: stopping the old embedding server (pid \(pid), no idle exit)")
        kill(pid, SIGTERM)
        for _ in 0..<20 where Self.ping(Self.builtinURL) { Thread.sleep(forTimeInterval: 0.1) }
    }

    /// 0.26.3: during a call the engine must not fall asleep in a quiet stretch; a keepalive a minute keeps it up,
    /// and starts it again if it is gone.
    func holdForCall(_ on: Bool) {
        keepAlive?.invalidate(); keepAlive = nil
        guard on, embedded else { return }
        keepAlive = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.global(qos: .utility).async {
                if !Self.get(Self.builtinURL + "/api/keepalive") { DispatchQueue.main.async { self.ensure() } }
            }
        }
    }

    /// Waits until the chosen engine answers (built-in loads in about a second).
    func waitReady(timeout: TimeInterval = 8) -> Bool {
        let c = config
        guard c.localAI.enabled else { return false }
        let url = c.localAI.engine == "embedded" ? Self.builtinURL : c.localAI.ollamaURL
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if Self.ping(url) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return false
    }

    /// The core (recorder and `lt`) reads these keys from <appRoot>/config.json.
    func writeCoreConfig() {
        let c = config
        let path = (appRoot as NSString).appendingPathComponent("config.json")
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)),
              var core = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
        core["semantic_enabled"] = c.localAI.enabled
        core["speakers_enabled"] = c.speakersEnabled
        if !c.nameAliases.isEmpty { core["name_aliases"] = c.nameAliases }   // "❓" cards for lines that name the PM
        // 0.10.0 (owner 12.11): Settings > Transcription > Dictionary, for the live recorder and recordings after the call
        let dict = DictionaryEntry.core(c.dictionary)
        if dict.isEmpty { core.removeValue(forKey: "dictionary") } else { core["dictionary"] = dict }
        core["ollama_url"] = c.localAI.engine == "embedded" ? Self.builtinURL : c.localAI.ollamaURL
        core["semantic_model"] = c.localAI.engine == "embedded" ? "bge-m3" : (c.localAI.ollamaModel.isEmpty ? "bge-m3" : c.localAI.ollamaModel)
        if let out = try? JSONSerialization.data(withJSONObject: core, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    /// Speakers: the voice model in <app folder>/models and the people in the voice library.
    func speakersLine() -> (ok: Bool, text: String) {
        let c = config
        if !c.speakersEnabled { return (false, L("lai.voicesOff")) }
        let models = (appRoot as NSString).appendingPathComponent("models")
        let hasModel = ((try? FileManager.default.contentsOfDirectory(atPath: models)) ?? []).contains { $0.hasPrefix("wespeaker") && $0.hasSuffix(".onnx") }
        if !hasModel { return (false, L("lai.noVoiceModel")) }
        let lib = (appRoot as NSString).appendingPathComponent("voices/voices.json")
        var n = 0
        if let d = try? Data(contentsOf: URL(fileURLWithPath: lib)), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            n = ((o["people"] as? [String: Any])?.count) ?? ((o["people"] as? [Any])?.count) ?? 0
        }
        return (true, L("lai.voicesOn", ["n": "\(n)"]))
    }

    /// One short status line for Settings and the menu.
    func statusLine() -> (ok: Bool, text: String) {
        let c = config
        if !c.localAI.enabled { return (false, L("lai.off")) }
        if c.localAI.engine == "embedded" {
            if !modelInstalled { return (false, L("lai.noModel", ["path": modelDir])) }
            // 0.26.3: not running is the normal state between uses (it starts when needed), so it is not a problem
            return Self.ping(Self.builtinURL) ? (true, L("lai.running"))
                                              : (true, L("lai.sleeping"))
        }
        return Self.ping(c.localAI.ollamaURL) ? (true, L("lai.ollamaOK", ["url": c.localAI.ollamaURL]))
                                              : (false, L("lai.ollamaNo", ["url": c.localAI.ollamaURL]))
    }

    static func get(_ url: String) -> Bool { fetch(url).ok }

    /// GET /api/version as JSON (version, pid, idle_exit_s from 0.26.3 on), nil when nothing answers.
    static func versionInfo(_ base: String) -> [String: Any]? {
        let r = fetch(base + "/api/version")
        guard r.ok, let d = r.data else { return nil }
        return ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any]) ?? [:]
    }

    static func fetch(_ s: String) -> (ok: Bool, data: Data?) {
        guard let url = URL(string: s) else { return (false, nil) }
        var req = URLRequest(url: url, timeoutInterval: 0.8)
        req.httpMethod = "GET"
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        var body: Data?
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        URLSession(configuration: cfg).dataTask(with: req) { d, r, _ in
            ok = (r as? HTTPURLResponse)?.statusCode == 200
            body = d
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 1.0)
        return (ok, body)
    }

    /// The process listening on a local TCP port (lsof), nil when none or lsof fails.
    static func listenerPID(port: Int) -> Int32? {
        let out = run("/usr/sbin/lsof", ["-nP", "-t", "-iTCP:\(port)", "-sTCP:LISTEN"])
        return out.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }.first
    }

    static func command(_ pid: Int32) -> String { run("/bin/ps", ["-p", String(pid), "-o", "command="]) }

    static func run(_ exe: String, _ args: [String]) -> String {
        let p = Process(); let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: d, encoding: .utf8) ?? ""
    }

    static func ping(_ base: String) -> Bool {
        guard let url = URL(string: base + "/api/version") else { return false }
        var req = URLRequest(url: url, timeoutInterval: 0.8)
        req.httpMethod = "GET"
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]               // local only, never through a proxy
        URLSession(configuration: cfg).dataTask(with: req) { _, r, _ in
            ok = (r as? HTTPURLResponse)?.statusCode == 200
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 1.0)
        return ok
    }
}
