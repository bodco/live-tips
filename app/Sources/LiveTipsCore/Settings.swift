import Foundation

/// Non-secret settings (JSON in ~/Library/Application Support/LiveTips/config.json).
/// Secrets (API keys, tokens) never live here: see SecretStore (Keychain).
public struct AppConfig: Codable, Equatable {
    public struct Models: Codable, Equatable {
        public var classify = "claude-haiku-5-5"
        public var tip = "claude-sonnet-5-5"
        public var analysis = "claude-opus-5-5"
        public init() {}
    }
    public struct Budget: Codable, Equatable {
        public var callSoftUSD = 2.0
        public var callHardUSD = 5.0
        public var monthlyHardUSD = 100.0
        public init() {}
    }
    public struct LocalAI: Codable, Equatable {
        /// Master switch for every local model (embeddings now, a local generative model later).
        public var enabled = true
        /// "embedded" (bge-m3 int8 via ONNX Runtime, default) or "ollama".
        public var engine = "embedded"
        public var ollamaURL = "http://127.0.0.1:11434"
        public init() {}
    }
    /// Engine processes (M1-M2: Python core). Not shown in the UI; set by the installer.
    public struct Engine: Codable, Equatable {
        public var python = ""            // python that runs <appRoot>/src/transcriber.py (MLX Whisper)
        public var sidecarPython = ""     // python with the model-tips engine (livetips_m0)
        public var sidecarDir = ""        // folder that contains livetips_m0/
        public init() {}
    }
    public var engine = Engine()
    /// How people address the PM on calls (any form); the "your turn" trigger.
    public var nameAliases: [String] = []
    public var models = Models()
    public var budget = Budget()
    public var localAI = LocalAI()
    public var uiLanguage = "en"           // en | uk
    public var stealthDefault = true
    public var showInDock = true
    public var notionWriteSummary = false
    /// The work folder connected to Cowork: project folders and the Notion mirror (_notion/) live here.
    public var workRoot = ""
    /// Advanced override; empty = <workRoot>/Tools/LiveTips (or Application Support without a work folder).
    public var appRoot = ""
    /// Model ids the API returned on the last successful key test (for the model pickers).
    public var knownModels: [String] = []
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        engine = (try? c.decode(Engine.self, forKey: .engine)) ?? d.engine
        nameAliases = (try? c.decode([String].self, forKey: .nameAliases)) ?? d.nameAliases
        models = (try? c.decode(Models.self, forKey: .models)) ?? d.models
        budget = (try? c.decode(Budget.self, forKey: .budget)) ?? d.budget
        localAI = (try? c.decode(LocalAI.self, forKey: .localAI)) ?? d.localAI
        uiLanguage = (try? c.decode(String.self, forKey: .uiLanguage)) ?? d.uiLanguage
        stealthDefault = (try? c.decode(Bool.self, forKey: .stealthDefault)) ?? d.stealthDefault
        showInDock = (try? c.decode(Bool.self, forKey: .showInDock)) ?? d.showInDock
        notionWriteSummary = (try? c.decode(Bool.self, forKey: .notionWriteSummary)) ?? d.notionWriteSummary
        workRoot = (try? c.decode(String.self, forKey: .workRoot)) ?? d.workRoot
        appRoot = (try? c.decode(String.self, forKey: .appRoot)) ?? d.appRoot
        knownModels = (try? c.decode([String].self, forKey: .knownModels)) ?? d.knownModels
    }

    /// Where control/ and state/ live. Inside the work folder by default, so the Cowork skill sees the status.
    public func effectiveAppRoot(appSupport: String) -> String {
        if !appRoot.isEmpty { return (appRoot as NSString).expandingTildeInPath }
        if !workRoot.isEmpty { return ((workRoot as NSString).expandingTildeInPath as NSString).appendingPathComponent("Tools/LiveTips") }
        return appSupport
    }

    /// Default model choices when the API was not asked yet.
    public static let fallbackModels = ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5", "claude-sonnet-5", "claude-opus-5"]

    public static func load(from url: URL) -> AppConfig {
        guard let d = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(AppConfig.self, from: d) else {
            return AppConfig()
        }
        return c
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }
}

/// Shows only the last 4 characters of a secret.
public func maskedSecret(_ s: String?) -> String {
    guard let s = s, !s.isEmpty else { return "not set" }
    return s.count > 8 ? "..." + s.suffix(4) : "(set)"
}

/// Reads one variable from a dotenv-style secrets file (import into the Keychain); never logs it.
public func readSecretsFileValue(_ name: String, path: String) -> String? {
    guard let text = try? String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8) else { return nil }
    for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
        var line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
        guard let eq = line.firstIndex(of: "="), line[..<eq].trimmingCharacters(in: .whitespaces) == name else { continue }
        var v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if v.count >= 2, let f = v.first, let l = v.last, (f == "\"" && l == "\"") || (f == "'" && l == "'") {
            v = String(v.dropFirst().dropLast())
        }
        return v.isEmpty ? nil : v
    }
    return nil
}
