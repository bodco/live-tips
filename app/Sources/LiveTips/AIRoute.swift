import Foundation
import LiveTipsCore

/// 0.8.2 (owner): the ways to Claude per job (Settings > AI) and the shared state of the automatic switch.
/// The tips engine and the one-off jobs (livetips_m0.routing) read and write the same file, state/ai-routes.json:
/// {"api": {"down": true, "reason": "credit", "since": <unix time>, "checked": <unix time>}, "code": {...}}.
enum AIRoute {
    static let api = "api", code = "code", openai = "openai", codex = "codex", gemini = "gemini", agy = "agy"   // 0.9.3: gemini (API key), agy (account)
    /// 0.8.5 (owner): a preparation on this Mac (Ollama), chosen by hand; never an automatic switch target yet.
    static let local = "local"

    static func other(_ r: String) -> String { [openai, codex, gemini, agy].contains(r) ? r : r == api ? code : api }

    static var statePath: String {
        let c = AppConfig.load(from: AppPaths.config)
        return ((c.effectiveAppRoot(appSupport: AppPaths.support.path) as NSString).appendingPathComponent("state") as NSString)
            .appendingPathComponent("ai-routes.json")
    }

    static func read() -> [String: Any] {
        guard let d = FileManager.default.contents(atPath: statePath),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    private static func write(_ o: [String: Any]) {
        try? FileManager.default.createDirectory(atPath: (statePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted]) {
            try? d.write(to: URL(fileURLWithPath: statePath), options: .atomic)
        }
    }

    static func isDown(_ r: String) -> Bool { ((read()[r] as? [String: Any])?["down"] as? Bool) ?? false }

    /// 0.10.0 (AI chain): `text` is the error; when it names a reset time ("try again at 12:48 PM") the AI is out
    /// until then, otherwise it is checked again in 15 minutes (AIOut).
    static func markDown(_ r: String, _ reason: String, text: String = "") {
        var o = read()
        let cur = o[r] as? [String: Any] ?? [:]
        let now = Date().timeIntervalSince1970
        var d: [String: Any] = ["down": true, "reason": reason, "since": (cur["down"] as? Bool) == true ? (cur["since"] ?? now) : now, "checked": now]
        if let u = AIOut.resetTime(text, now: Date())?.timeIntervalSince1970, u > now { d["until"] = u }
        o[r] = d
        write(o)
    }

    // MARK: 0.10.0 (AI chain, owner 12.11)

    /// The AIs that can be tried at all now: installed and signed in (as far as the app knows), or a key is set.
    @MainActor static func connected() -> Set<String> {
        var out = Set<String>()
        let p = PrepRunner.shared
        if PrepRunner.claudePath != nil && p.loggedIn != false { out.insert(code) }
        if CodexAccount.cliPath != nil && CodexAccount.shared.signedIn != false { out.insert(codex) }
        if p.hasAPIKey { out.insert(api) }
        if p.hasOpenAIKey { out.insert(openai) }
        if p.hasGeminiKey { out.insert(gemini) }
        if AgyAccount.cliPath != nil && AgyAccount.shared.signedIn != false { out.insert(agy) }
        if !LocalLLM.downloaded().isEmpty { out.insert(local) }       // a model on this Mac is downloaded
        return out
    }

    /// The enabled AIs for the engine, the model on this Mac only when one is downloaded (the engine treats every AI
    /// it has a key or a tool for as connected).
    static func chainForEngine(_ c: AppConfig) -> [String] {
        AIChain.enabled(c.ai.chain).filter { $0 != local || !LocalLLM.downloaded().isEmpty }
    }

    /// The order a job tries its AIs (AIChain.order over the connected ones).
    @MainActor static func order(job: String, config c: AppConfig) -> [String] {
        c.ai.order(job, connected: connected())
    }

    /// The out state of every AI (AIOut).
    static func outStates() -> [String: AIOut.State] { AIOut.parse(read()) }

    /// An AI worth trying now: not out, or its next check is due (its reset time passed).
    static func due(_ r: String) -> Bool { AIOut.due(outStates()[r], now: Date().timeIntervalSince1970) }

    static var accountsPath: String { ((statePath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("ai-accounts.json") }
    static var switchesPath: String { ((statePath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("ai-switches.jsonl") }

    /// The latest limits an account reported (Claude Code's rate_limit_event, Codex's rate_limits), per account.
    static func noteAccountUsage(_ r: String, _ u: AIAccountUsage.Usage) {
        var o: [String: Any] = [:]
        if let d = FileManager.default.contents(atPath: accountsPath), let x = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { o = x }
        o[r] = AIAccountUsage.encode(u)
        if let d = try? JSONSerialization.data(withJSONObject: o) { try? d.write(to: URL(fileURLWithPath: accountsPath), options: .atomic) }
    }

    /// Never silent: one line per switch (the engine writes the same file, livetips_m0.routing.note_switch).
    static func noteSwitch(job: String, from: String, to: String, reason: String) {
        let row: [String: Any] = ["at": Date().timeIntervalSince1970, "job": job, "from": from, "to": to, "reason": reason]
        guard let d = try? JSONSerialization.data(withJSONObject: row), var line = String(data: d, encoding: .utf8) else { return }
        line += "\n"
        if let h = FileHandle(forWritingAtPath: switchesPath) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(toFile: switchesPath, atomically: true, encoding: .utf8)
        }
    }

    static func markUp(_ r: String) {
        var o = read()
        guard ((o[r] as? [String: Any])?["down"] as? Bool) == true else { return }
        o[r] = ["down": false, "back_at": Date().timeIntervalSince1970]
        write(o)
    }

    /// Why a way is out (worth switching), from an error text; nil for a passing error. Same rules as
    /// livetips_m0.routing.out_reason.
    static func outReason(_ r: String, _ text: String) -> String? {
        let e = text.lowercased()
        if e.contains("credit balance") || e.contains("billing") { return "credit" }
        // 0.9.3: Gemini: 401 and 403 a bad key or no permission, 402 the prepaid credit is gone, quota_exceeded the day's quota,
        // failed_precondition billing is off; a plain 429 (rate_limit_exceeded) passes. Same as livetips_m0.routing.
        if r == gemini {
            if e.contains("http 401") || e.contains("http 403") { return "auth" }
            return e.contains("http 402") || e.contains("quota_exceeded") || e.contains("failed_precondition") ? "credit" : nil
        }
        if r == agy {         // 0.9.3: livetips_m0.agy_provider names the kind only
            return e.contains("not signed in") ? "auth" : e.contains("usage limit") ? "limit" : e.contains("not installed") ? "missing" : nil
        }
        if r == openai {      // 0.9.3: same as livetips_m0.routing: 401 and 403 a bad key, insufficient_quota no credit
            if e.contains("http 401") || e.contains("http 403") { return "auth" }
            return e.contains("insufficient_quota") ? "credit" : nil
        }
        if r == api { return e.contains("invalid api key") || e.contains("x-api-key") || e.contains("authentication_error") ? "auth" : nil }
        if e.contains("usage limit") || e.contains("limit reached") || e.contains("hit your limit") || e.contains("limit will reset") { return "limit" }
        if e.contains("/login") || e.contains("not logged in") || e.contains("oauth") || e.contains("authenticate") { return "auth" }
        return nil
    }

    static var hasKey: Bool {
        SecretStore(service: Bundle.main.bundleIdentifier ?? "io.github.example.livetips").has(.claudeAPIKey)     // 0.8.7.1: presence only
    }

    /// The way can be tried at all: a key for the API, the Claude Code tool for the account.
    static func available(_ r: String) -> Bool {
        if r == codex { return CodexAccount.cliPath != nil }
        if r == openai { return SecretStore(service: Bundle.main.bundleIdentifier ?? "io.github.example.livetips").has(.openaiAPIKey) }
        if r == gemini { return SecretStore(service: Bundle.main.bundleIdentifier ?? "io.github.example.livetips").has(.geminiAPIKey) }
        if r == agy { return AgyAccount.cliPath != nil }
        return r == api ? hasKey : r == local ? true : PrepRunner.claudePath != nil
    }

    /// A job on this way can run: the way itself, or with auto-switch the other one.
    static func canRun(job: String, config c: AppConfig) -> Bool {
        let r = c.ai.route(job)
        if r == agy && job == "tips" { return false }      // 0.9.3: never during a call (20-30 s a request)
        // 0.10.0 (AI chain, owner 12.11): the chosen AI, or any AI of the chain this job may use
        let avail = Set(([api, code, codex, openai, gemini, agy] as [String]).filter { available($0) } + [local])
        return available(r) || AIChain.order(job: job, chosen: r, chain: c.ai.chain, connected: avail, auto: c.ai.autoSwitch).count > 1
    }

    /// The environment of an engine child process for one job: the way, the switch, the shared state, the key
    /// (to the child only, never written or logged) and the Claude Code tool.
    /// 0.9.6 Б1: the settings the jobs run with (economy mode on: EconomyPlan; an account counts when its tool is
    /// installed, a signed-out account falls to the other way through auto-switch as before).
    static func effective(_ c: AppConfig) -> AppConfig {
        EconomyPlan.apply(c, on: Economy.isOn(stateDir: (statePath as NSString).deletingLastPathComponent),
                          accounts: EconomyPlan.Accounts(claude: PrepRunner.claudePath != nil, chatgpt: CodexAccount.cliPath != nil))
    }

    static func env(job: String, config c0: AppConfig, base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        let c = effective(c0)
        var env = base
        let store = SecretStore(service: Bundle.main.bundleIdentifier ?? "io.github.example.livetips")
        if let k = store.get(.claudeAPIKey), !k.isEmpty { env["CLAUDE_API"] = k } else { env.removeValue(forKey: "CLAUDE_API") }
        if let k = store.get(.openaiAPIKey), !k.isEmpty { env["OPENAI_API_KEY"] = k } else { env.removeValue(forKey: "OPENAI_API_KEY") }
        if let k = store.get(.geminiAPIKey), !k.isEmpty { env["GEMINI_API_KEY"] = k } else { env.removeValue(forKey: "GEMINI_API_KEY") }
        if let ws = store.get(.claudeWorkspaceID), !ws.isEmpty { env["CLAUDE_WORKSPACE"] = ws }
        env["LT_AI_JOB"] = job
        env["LT_AI_ROUTE"] = c.ai.route(job)
        env["LT_OPENAI_MODEL"] = c.ai.openaiModel(job)       // 0.9.0: the job's OpenAI model (Settings > AI)
        env["LT_GEMINI_MODEL"] = c.ai.geminiModel(job)       // 0.9.3: the job's Gemini model (Settings > AI)
        env["LT_GEMINI_FALLBACK"] = c.ai.geminiFallback ? "1" : "0"   // 0.9.3: plan B, opt-in (rules/ai.yaml > gemini)
        env["LT_AGY_MODEL"] = c.ai.agyModel(job)              // 0.9.3: the Gemini account model (prep, after)
        if let cli = AgyAccount.cliPath { env["LT_AGY_CLI"] = cli }
        env["LT_LOCAL_MODEL"] = UserDefaults.standard.string(forKey: "prepLocalModel") ?? "gemma4:26b"   // rules/ai.yaml > local
        env["LT_LOCAL_FALLBACK"] = (job != "tips" && c.ai.localFallback) ? "1" : "0"                      // rules/ai.yaml > fallback
        env["LT_AI_AUTO"] = c.ai.autoSwitch ? "1" : "0"
        // 0.10.0 (AI chain): the enabled AIs in the PM's order; the engine applies the same job rules (AIChain)
        if let d = try? JSONSerialization.data(withJSONObject: chainForEngine(c)), let s = String(data: d, encoding: .utf8) {
            env["LT_AI_CHAIN"] = s
        }
        env["LT_AI_STATE"] = statePath
        // 0.9.6 (owner): the monthly limits per provider (livetips_m0.cost.ProviderCaps); none set, none sent
        let caps = ProviderLimits.caps(c.providerBudgets)
        if !caps.isEmpty, let d = try? JSONSerialization.data(withJSONObject: caps), let s = String(data: d, encoding: .utf8) {
            env["LT_PROVIDER_CAPS"] = s
        } else { env.removeValue(forKey: "LT_PROVIDER_CAPS") }
        if let cl = PrepRunner.claudePath { env["LT_CLAUDE_CLI"] = cl }
        if let cli = CodexAccount.cliPath { env["LT_CODEX_CLI"] = cli }
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        return env
    }

    /// For sidecar-config.json (the tips engine and the judge).
    static func sidecarBlock(config c0: AppConfig) -> [String: Any] {
        let c = effective(c0)
        // 2026-11-06: "prep" too: typed questions and the deep folder lookup use the preparation's way and model.
        return ["routes": ["prep": c.ai.prep, "tips": c.ai.tips, "after": c.ai.after], "auto": c.ai.autoSwitch, "state": statePath,
         "chain": chainForEngine(c),        // 0.10.0 (AI chain)
         "openai_models": ["prep": c.ai.openaiPrep, "tips": c.ai.openaiTips, "after": c.ai.openaiAfter],
         "gemini_models": ["prep": c.ai.geminiPrep, "tips": c.ai.geminiTips, "after": c.ai.geminiAfter], "gemini_fallback": c.ai.geminiFallback,
         "agy_models": ["prep": c.ai.agyPrep, "after": c.ai.agyAfter],
         "claude_cli": PrepRunner.claudePath ?? ""]
    }

    static func name(_ r: String) -> String {
        r == codex ? L("ai.codex.account") : r == openai ? L("ai.route.openai") : r == gemini ? L("ai.route.gemini") : r == agy ? L("ai.agy.account") : r == local ? L("ai.route.local.model", ["model": UserDefaults.standard.string(forKey: "prepLocalModel") ?? "gemma4:26b"])
            : L(r == api ? "ai.route.api" : "ai.route.code")
    }

    /// One line per way that is out, for Settings > AI; empty when both answer.
    static func statusLines() -> [String] {
        let o = read()
        let t = DateFormatter(); t.dateFormat = "HH:mm"
        return [code, api, openai, codex, gemini, agy, local].compactMap { r in
            guard let s = o[r] as? [String: Any], (s["down"] as? Bool) == true else { return nil }
            let since = (s["since"] as? Double).map { t.string(from: Date(timeIntervalSince1970: $0)) } ?? ""
            let reason = L("ai.reason." + ((s["reason"] as? String) ?? "error"))
            if let u = (s["until"] as? NSNumber)?.doubleValue, u > Date().timeIntervalSince1970 {     // 0.10.0 (AI chain)
                return L("ai.status.outUntilLine", ["route": name(r), "reason": reason, "time": since, "until": t.string(from: Date(timeIntervalSince1970: u))])
            }
            return L("ai.status.out", ["route": name(r), "reason": reason, "time": since])
        }
    }

    /// Checks the ways that are out now (a one-word request each, through the engine) and calls back.
    @MainActor static func checkNow(done: @escaping () -> Void) {
        let c = AppConfig.load(from: AppPaths.config)
        let down = [code, api, openai, codex, gemini, agy].filter { isDown($0) }
        guard !down.isEmpty, !c.engine.sidecarPython.isEmpty, !c.engine.sidecarDir.isEmpty else { done(); return }
        DispatchQueue.global().async {
            for r in down {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: c.engine.sidecarPython)
                p.arguments = ["-m", "livetips_m0.routing", "ping", "--route", r]
                p.currentDirectoryURL = URL(fileURLWithPath: c.engine.sidecarDir)
                var env = env(job: "after", config: c)
                env["PYTHONDONTWRITEBYTECODE"] = "1"
                p.environment = env
                p.standardOutput = Pipe(); p.standardError = Pipe()
                if (try? p.run()) != nil { p.waitUntilExit() }
            }
            DispatchQueue.main.async { done() }
        }
    }
}
