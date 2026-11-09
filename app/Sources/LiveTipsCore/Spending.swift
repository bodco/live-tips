import Foundation

/// 0.9.6 (owner, 2026-11-06): monthly limits and alerts per AI provider, and economy mode. Pure, for CoreChecks.
/// The spend is Settings > Usage's ledger (state/spend-ledger.jsonl); only the providers with a key are shown.
public enum ProviderLimits {
    public enum Level: String, Equatable { case ok, alert, capped }

    /// ok below the alert share of the limit, alert from it, capped at the limit; ok when there is no limit.
    public static func level(spent: Double, budget b: AppConfig.ProviderBudget) -> Level {
        guard b.monthlyUSD > 0 else { return .ok }
        if spent >= b.monthlyUSD { return .capped }
        return spent >= b.monthlyUSD * b.alertPercent / 100 ? .alert : .ok
    }

    /// This month's spend per provider ("yyyy-MM").
    public static func monthSpend(_ rows: [AIUsage.Row], month: String) -> [String: Double] {
        var out: [String: Double] = [:]
        for r in rows where r.day.hasPrefix(month) { out[r.provider, default: 0] += r.usd }
        return out
    }

    /// The limits the engine enforces (sidecar-config "provider_caps", LT_PROVIDER_CAPS): set ones only.
    public static func caps(_ b: AppConfig.ProviderBudgets) -> [String: Double] {
        var out: [String: Double] = [:]
        for p in AIUsage.providers where b[p].monthlyUSD > 0 { out[p] = b[p].monthlyUSD }
        return out
    }

    /// The alert to show now: the highest level not yet shown this month for this provider, or nil.
    public static func due(level: Level, shown: Set<String>, provider: String, month: String) -> Level? {
        guard level != .ok else { return nil }
        let key = alertKey(provider: provider, month: month, level: level)
        return shown.contains(key) ? nil : level
    }

    public static func alertKey(provider: String, month: String, level: Level) -> String {
        provider + "." + month + "." + level.rawValue
    }

    public static func month(_ d: Date = Date()) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM"
        return f.string(from: d)
    }
}

/// Economy mode: a flag file next to the AI routes' state, switched by hand (menu bar, Settings). The engine checks
/// it before every agent request, lookup and background search, so it works during a call too (0.9.6 Б1: the agent
/// on Haiku, no background searches, lookups on the Claude account); EconomyPlan is what changes from the next job.
public enum Economy {
    public static func path(stateDir: String) -> String { (stateDir as NSString).appendingPathComponent("economy") }
    public static func isOn(stateDir: String) -> Bool { FileManager.default.fileExists(atPath: path(stateDir: stateDir)) }
    public static func set(_ on: Bool, stateDir: String) {
        let p = path(stateDir: stateDir)
        if on {
            try? FileManager.default.createDirectory(atPath: stateDir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: p, contents: Data("on\n".utf8))
        } else {
            try? FileManager.default.removeItem(atPath: p)
        }
    }
}

/// 0.9.6 Б1 (owner, 2026-11-06): economy mode v1 = the least API money, the plans of the accounts pay where they can.
/// From the next call or job: live tips on the cheapest model of their way, the preparation and the after-the-call
/// jobs on the Claude account instead of the Claude key and on the ChatGPT account instead of the OpenAI key when that
/// account can run; Gemini never moves to the Gemini account (Antigravity's terms). Without an account the
/// after-the-call jobs take the cheaper model of their way; the preparation is not made cheaper. The monthly limits
/// per provider apply on top (they are checked after this plan). Pure: the app passes which accounts can run.
public enum EconomyPlan {
    public struct Accounts: Equatable {
        public var claude: Bool
        public var chatgpt: Bool
        public init(claude: Bool, chatgpt: Bool) { self.claude = claude; self.chatgpt = chatgpt }
    }
    public static let claudeTips = "claude-haiku-5-5", openaiCheap = "gpt-6-luna", geminiCheap = "gemini-3.5-flash-lite"

    /// The way of a job ("prep", "after") in economy mode.
    public static func jobRoute(_ route: String, accounts a: Accounts) -> String {
        if route == "api" && a.claude { return "code" }
        if route == "openai" && a.chatgpt { return "codex" }
        return route
    }

    /// The live tips' model on their way (nil: the way keeps its model, e.g. the local one).
    public static func tipsModel(route: String) -> String? {
        switch route {
        case "api", "code": return claudeTips
        case "openai", "codex": return openaiCheap
        case "gemini": return geminiCheap
        default: return nil
        }
    }

    /// The research preparation's features in economy mode (point 4, Б3): tools yes, the checker on Haiku only, no
    /// parallel subagents. Off features stay off.
    public struct PrepFeatures: Equatable {
        public var tools: Bool, verify: Bool, verifyModel: String, parallel: Bool
        public init(tools: Bool, verify: Bool, verifyModel: String, parallel: Bool) {
            self.tools = tools; self.verify = verify; self.verifyModel = verifyModel; self.parallel = parallel
        }
    }
    public static func prepFeatures(tools: Bool, verify: Bool, parallel: Bool, verifyModel: String, economy: Bool) -> PrepFeatures {
        economy ? PrepFeatures(tools: tools, verify: verify, verifyModel: claudeTips, parallel: false)
                : PrepFeatures(tools: tools, verify: verify, verifyModel: verifyModel, parallel: parallel)
    }

    /// The settings the jobs run with. Off: the config itself. Applying it twice changes nothing.
    public static func apply(_ c: AppConfig, on: Bool, accounts: Accounts) -> AppConfig {
        guard on else { return c }
        var e = c
        if let m = tipsModel(route: c.ai.tips), c.ai.tips == "api" || c.ai.tips == "code" { e.models.tip = m }
        e.ai.openaiTips = openaiCheap
        e.ai.geminiTips = geminiCheap
        e.ai.prep = jobRoute(c.ai.prep, accounts: accounts)
        e.ai.after = jobRoute(c.ai.after, accounts: accounts)
        if e.ai.after == "openai" { e.ai.openaiAfter = openaiCheap }
        if e.ai.after == "gemini" { e.ai.geminiAfter = geminiCheap }
        return e
    }

    /// What economy mode changes, for Settings (keys of the i18n strings economy.what.*).
    public static let changes = ["economy.what.agent", "economy.what.lookup", "economy.what.tips", "economy.what.jobs"]
}
