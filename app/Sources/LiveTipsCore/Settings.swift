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
        /// Embedding model name in Ollama (bge-m3 by default; other models need a reindex and new thresholds).
        public var ollamaModel = "bge-m3"
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = LocalAI()
            enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
            engine = (try? c.decodeIfPresent(String.self, forKey: .engine)) ?? d.engine
            ollamaURL = (try? c.decodeIfPresent(String.self, forKey: .ollamaURL)) ?? d.ollamaURL
            ollamaModel = (try? c.decodeIfPresent(String.self, forKey: .ollamaModel)) ?? d.ollamaModel
        }
    }
    /// 0.8.2 (owner): which way each job reaches Claude. "code": the PM's Claude account through Claude Code
    /// (the plan's limits, no key); "api": the Claude API key (billed per token, the fastest). Auto-switch: when the
    /// chosen way is out (no credit, the plan limit, signed out), the job uses the other one and goes back once the
    /// chosen one answers again (state/ai-routes.json, shared with the engine).
    public struct AIRoutes: Codable, Equatable {
        public var prep = "code"
        public var tips = "api"
        public var after = "code"
        public var autoSwitch = true
        /// 0.8.5 (owner): when neither Claude way answers, the preparation and the after-the-call jobs use the model
        /// on this Mac (rules/ai.yaml > fallback); never the tips during a call.
        public var localFallback = true
        public init() {}
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = AIRoutes()
            prep = (try? c.decodeIfPresent(String.self, forKey: .prep)) ?? d.prep
            tips = (try? c.decodeIfPresent(String.self, forKey: .tips)) ?? d.tips
            after = (try? c.decodeIfPresent(String.self, forKey: .after)) ?? d.after
            autoSwitch = (try? c.decodeIfPresent(Bool.self, forKey: .autoSwitch)) ?? d.autoSwitch
            localFallback = (try? c.decodeIfPresent(Bool.self, forKey: .localFallback)) ?? d.localFallback
        }
        public func route(_ job: String) -> String { job == "prep" ? prep : job == "tips" ? tips : after }
    }
    /// Engine processes (M1-M2: Python core). Not shown in the UI; set by the installer.
    public struct Engine: Codable, Equatable {
        public var python = ""            // python that runs <appRoot>/src/transcriber.py (MLX Whisper)
        public var sidecarPython = ""     // python with the model-tips engine (livetips_m0)
        public var sidecarDir = ""        // folder that contains livetips_m0/
        public init() {}

        /// 0.8.3: the engine follows the app. An empty or vanished path (the app was renamed or moved) points at what
        /// setup installed (`defaultPython`) and at the app's own engine (`bundleEngine`); a working path, the PM's own
        /// choice included, stays. nil when nothing changes.
        public func resolved(defaultPython: String, bundleEngine: String, exists: (String) -> Bool) -> Engine? {
            var e = self
            if e.python.isEmpty || !exists(e.python) { e.python = defaultPython }
            if e.sidecarPython.isEmpty || !exists(e.sidecarPython) { e.sidecarPython = defaultPython }
            if e.sidecarDir.isEmpty || !exists(e.sidecarDir) { e.sidecarDir = bundleEngine }
            return e == self ? nil : e
        }
    }
    public var engine = Engine()
    /// How people address the PM on calls (any form); the "your turn" trigger.
    public var nameAliases: [String] = []
    public var models = Models()
    public var ai = AIRoutes()
    public var budget = Budget()
    public var localAI = LocalAI()
    public var uiLanguage = "en"           // en | uk
    public var stealthDefault = true
    public var showInDock = true
    public var notionWriteSummary = false
    /// 2026-10-26: where meeting pages go when the project has no Control Tower config (a data source id
    /// chosen or created in Settings or the welcome tour) and its name for the UI.
    public var notionMeetingsDB = ""
    public var notionMeetingsName = ""
    /// 0.8.6 (C): a project without a Control Tower config may write its meeting pages to another database
    /// (project slug -> data source id); empty = the default above.
    public var notionMeetingsDBByProject: [String: String] = [:]
    /// 0.8.6 (D, rules/notion-tasks.yaml): the PM's Notion tasks in On you.
    public var notionTasks = NotionTasksSettings()
    /// Speaker identification on the other side's audio (local voice prints, as in the skill).
    public var speakersEnabled = true
    /// M2: a second request when Claude is slow to start answering (the first good answer wins).
    public var hedgeEnabled = true
    /// After each call: the blind judge rates the tips in the background (Sonnet, at most 25 tips, about $0.10).
    public var judgeAfterCall = false     // 2026-10-26: off for new installs (a developer check, about $0.10 a call)
    /// 2026-10-23: tips for a question to anyone on the call (not only to you) when the brief or the
    /// project state holds an answer you could give or add.
    public var answerAny = true
    /// 2026-10-26 (owner): consent when a recording starts, both off by default. Say: macOS speaks the
    /// message through the speakers so the others hear it via the microphone. Chat: the message is copied
    /// for the meeting chat (paste it with Command-V).
    public var consentSay = false
    public var consentChat = false
    public var consentTextEN = "Hi all, a note-taking assistant on my computer transcribes this call for my notes. Tell me if you would rather I turn it off."
    public var consentTextUK = "Привіт усім, помічник на моєму комп'ютері транскрибує цей дзвінок для моїх нотаток. Скажіть, якщо краще його вимкнути."
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
        if let a = try? c.decode(AIRoutes.self, forKey: .ai) { ai = a } else {
            // Before 0.8.2 the preparation's way was a separate switch; keep what the PM chose there.
            ai = d.ai
            if UserDefaults.standard.object(forKey: "prepUseAPI") != nil { ai.prep = UserDefaults.standard.bool(forKey: "prepUseAPI") ? "api" : "code" }
        }
        budget = (try? c.decode(Budget.self, forKey: .budget)) ?? d.budget
        localAI = (try? c.decode(LocalAI.self, forKey: .localAI)) ?? d.localAI
        uiLanguage = (try? c.decode(String.self, forKey: .uiLanguage)) ?? d.uiLanguage
        stealthDefault = (try? c.decode(Bool.self, forKey: .stealthDefault)) ?? d.stealthDefault
        showInDock = (try? c.decode(Bool.self, forKey: .showInDock)) ?? d.showInDock
        notionWriteSummary = (try? c.decode(Bool.self, forKey: .notionWriteSummary)) ?? d.notionWriteSummary
        notionMeetingsDB = (try? c.decode(String.self, forKey: .notionMeetingsDB)) ?? d.notionMeetingsDB
        notionMeetingsName = (try? c.decode(String.self, forKey: .notionMeetingsName)) ?? d.notionMeetingsName
        notionMeetingsDBByProject = (try? c.decode([String: String].self, forKey: .notionMeetingsDBByProject)) ?? d.notionMeetingsDBByProject
        notionTasks = (try? c.decode(NotionTasksSettings.self, forKey: .notionTasks)) ?? d.notionTasks
        speakersEnabled = (try? c.decode(Bool.self, forKey: .speakersEnabled)) ?? d.speakersEnabled
        hedgeEnabled = (try? c.decode(Bool.self, forKey: .hedgeEnabled)) ?? d.hedgeEnabled
        judgeAfterCall = (try? c.decode(Bool.self, forKey: .judgeAfterCall)) ?? d.judgeAfterCall
        answerAny = (try? c.decode(Bool.self, forKey: .answerAny)) ?? d.answerAny
        consentSay = (try? c.decode(Bool.self, forKey: .consentSay)) ?? d.consentSay
        consentChat = (try? c.decode(Bool.self, forKey: .consentChat)) ?? d.consentChat
        consentTextEN = (try? c.decode(String.self, forKey: .consentTextEN)) ?? d.consentTextEN
        consentTextUK = (try? c.decode(String.self, forKey: .consentTextUK)) ?? d.consentTextUK
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

/// 0.8.6 (D, rules/notion-tasks.yaml > settings). Off by default; ids are Notion ids, never written to git.
public struct NotionTasksSettings: Codable, Equatable {
    public struct Condition: Codable, Equatable, Identifiable {
        public var id = UUID().uuidString
        public var property = ""
        public var type = ""                // status | select | multi_select | checkbox
        public var values: [String] = []    // option names (checkbox: "true" or "false")
        public init() {}
    }
    public var enabled = false
    public var database = ""                // data source id
    public var databaseName = ""
    public var personProperty = ""
    public var personId = ""
    public var personName = ""
    public var conditions: [Condition] = []
    public var tickProperty = ""
    public var tickType = ""                // status | select | checkbox
    public var tickValue = ""
    public var dueProperty = ""
    public var projectProperty = ""
    public var projectType = ""             // relation | select | multi_select
    /// Pacenote project slug or "workspace:<name>" -> the Notion values (option names or page ids)
    public var projectMap: [String: [String]] = [:]
    public var workspaceProperty = ""       // a Workspace relation, when the database has one
    public var workspaceMap: [String: String] = [:]   // workspace name -> page id
    public var sourceProperty = ""          // rich text or url for "From the call ..."
    public var autoAdd = true               // after each call (rules/notion-tasks.yaml > after_call)
    /// 0.8.6 (owner, 30.10): only tasks edited in the last N days ("all", "1", "7", "14", "30")
    public var periodDays = "all"
    public init() {}

    /// Complete enough to query and to add tasks.
    public var ready: Bool { enabled && !database.isEmpty && !personProperty.isEmpty && !personId.isEmpty }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = NotionTasksSettings()
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? d.enabled
        database = (try? c.decode(String.self, forKey: .database)) ?? d.database
        databaseName = (try? c.decode(String.self, forKey: .databaseName)) ?? d.databaseName
        personProperty = (try? c.decode(String.self, forKey: .personProperty)) ?? d.personProperty
        personId = (try? c.decode(String.self, forKey: .personId)) ?? d.personId
        personName = (try? c.decode(String.self, forKey: .personName)) ?? d.personName
        conditions = (try? c.decode([Condition].self, forKey: .conditions)) ?? d.conditions
        tickProperty = (try? c.decode(String.self, forKey: .tickProperty)) ?? d.tickProperty
        tickType = (try? c.decode(String.self, forKey: .tickType)) ?? d.tickType
        tickValue = (try? c.decode(String.self, forKey: .tickValue)) ?? d.tickValue
        dueProperty = (try? c.decode(String.self, forKey: .dueProperty)) ?? d.dueProperty
        projectProperty = (try? c.decode(String.self, forKey: .projectProperty)) ?? d.projectProperty
        projectType = (try? c.decode(String.self, forKey: .projectType)) ?? d.projectType
        projectMap = (try? c.decode([String: [String]].self, forKey: .projectMap)) ?? d.projectMap
        workspaceProperty = (try? c.decode(String.self, forKey: .workspaceProperty)) ?? d.workspaceProperty
        workspaceMap = (try? c.decode([String: String].self, forKey: .workspaceMap)) ?? d.workspaceMap
        sourceProperty = (try? c.decode(String.self, forKey: .sourceProperty)) ?? d.sourceProperty
        autoAdd = (try? c.decode(Bool.self, forKey: .autoAdd)) ?? d.autoAdd
        periodDays = (try? c.decode(String.self, forKey: .periodDays)) ?? d.periodDays
    }

    /// What is still missing before tasks can be read (for the settings' hint), empty when ready.
    public var missing: [String] {
        guard enabled else { return [] }
        var m: [String] = []
        if database.isEmpty { m.append("database") }
        if personProperty.isEmpty { m.append("personProperty") }
        if personId.isEmpty { m.append("person") }
        return m
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
