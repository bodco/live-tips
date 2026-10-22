import Foundation
import LiveTipsCore

/// Local AI for the recorder core: the built-in embedding engine (bge-m3 int8 on ONNX Runtime,
/// served on 127.0.0.1 with the small Ollama-compatible API the core already speaks) or the
/// user's Ollama. Writes the choice into the core config before every call.
final class LocalAIService: @unchecked Sendable {
    nonisolated(unsafe) static let shared = LocalAIService()
    static let builtinPort = 11435
    static var builtinURL: String { "http://127.0.0.1:\(builtinPort)" }
    private(set) var process: Process?

    var config: AppConfig { AppConfig.load(from: AppPaths.config) }
    var appRoot: String { config.effectiveAppRoot(appSupport: AppPaths.support.path) }
    var modelDir: String { (appRoot as NSString).appendingPathComponent("models/bge-m3-int8") }
    var modelInstalled: Bool {
        FileManager.default.fileExists(atPath: (modelDir as NSString).appendingPathComponent("model_quantized.onnx"))
            && FileManager.default.fileExists(atPath: (modelDir as NSString).appendingPathComponent("tokenizer.json"))
    }

    /// Starts or stops the built-in engine to match the settings. Safe to call often.
    func apply() {
        let c = config
        if c.localAI.enabled && c.localAI.engine == "embedded" { start() } else { stop() }
        writeCoreConfig()
    }

    func start() {
        if process?.isRunning == true { return }
        let c = config
        guard modelInstalled, !c.engine.sidecarPython.isEmpty, !c.engine.sidecarDir.isEmpty else { return }
        if Self.ping(Self.builtinURL) { return }          // already running (e.g. started by a previous app run)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: c.engine.sidecarPython)
        p.arguments = ["-m", "livetips_m0.embed_server", "--model-dir", modelDir, "--port", String(Self.builtinPort)]
        p.currentDirectoryURL = URL(fileURLWithPath: c.engine.sidecarDir)
        var env = ProcessInfo.processInfo.environment
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        p.environment = env
        let logs = (appRoot as NSString).appendingPathComponent("logs")
        try? FileManager.default.createDirectory(atPath: logs, withIntermediateDirectories: true)
        let log = FileHandle.forAppending(path: (logs as NSString).appendingPathComponent("local-ai.log"))
        p.standardOutput = log
        p.standardError = log
        try? p.run()
        process = p
    }

    func stop() {
        process?.terminate()
        process = nil
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
        core["ollama_url"] = c.localAI.engine == "embedded" ? Self.builtinURL : c.localAI.ollamaURL
        core["semantic_model"] = c.localAI.engine == "embedded" ? "bge-m3" : (c.localAI.ollamaModel.isEmpty ? "bge-m3" : c.localAI.ollamaModel)
        if let out = try? JSONSerialization.data(withJSONObject: core, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    /// Speakers: the voice model in <app folder>/models and the people in the voice library.
    func speakersLine() -> (ok: Bool, text: String) {
        let c = config
        if !c.speakersEnabled { return (false, "Off: the other side is one speaker (\"Them\")") }
        let models = (appRoot as NSString).appendingPathComponent("models")
        let hasModel = ((try? FileManager.default.contentsOfDirectory(atPath: models)) ?? []).contains { $0.hasPrefix("wespeaker") && $0.hasSuffix(".onnx") }
        if !hasModel { return (false, "Voice model not installed: open Setup and install Voices") }
        let lib = (appRoot as NSString).appendingPathComponent("voices/voices.json")
        var n = 0
        if let d = try? Data(contentsOf: URL(fileURLWithPath: lib)), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            n = ((o["people"] as? [String: Any])?.count) ?? ((o["people"] as? [Any])?.count) ?? 0
        }
        return (true, "On. Voice library: \(n) \(n == 1 ? "person" : "people") (stays on this Mac)")
    }

    /// One short status line for Settings and the menu.
    func statusLine() -> (ok: Bool, text: String) {
        let c = config
        if !c.localAI.enabled { return (false, "Off: facts and cards match by keywords only") }
        if c.localAI.engine == "embedded" {
            if !modelInstalled { return (false, "Built-in model is not installed in \(modelDir)") }
            return Self.ping(Self.builtinURL) ? (true, "Built-in engine is running (bge-m3, on this Mac)")
                                              : (false, "Built-in engine is not running yet")
        }
        return Self.ping(c.localAI.ollamaURL) ? (true, "Ollama answers at \(c.localAI.ollamaURL)")
                                              : (false, "Ollama does not answer at \(c.localAI.ollamaURL)")
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
