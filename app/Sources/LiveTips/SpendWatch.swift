import Foundation
import LiveTipsCore
import UserNotifications

/// 0.9.6 (owner, 2026-11-06): monthly limits and alerts per AI provider (Settings > AI > Spending limits) and economy
/// mode. Only the providers with a key are watched and shown. An alert fires once a month per level: at the share the
/// PM set ("80% of the Claude limit used") and at the limit, where the engine stops using that key
/// (livetips_m0.cost.ProviderCaps). Economy mode is switched by hand; the alert says where.
@MainActor
enum SpendWatch {
    static let shownKey = "providerAlertsShown"
    private static var cache: (at: Date, spend: [String: Double])?

    static var stateDir: String { (AIRoute.statePath as NSString).deletingLastPathComponent }
    static var economyOn: Bool { Economy.isOn(stateDir: stateDir) }
    static func setEconomy(_ on: Bool) {
        Economy.set(on, stateDir: stateDir)
        UsageLog.log(on ? "economy_on" : "economy_off")
    }

    /// Claude, OpenAI, Gemini: the ones with a key in the Keychain (presence only).
    static var shotConnected: [String]?          // shot mode only: the demo has no keys
    static var connected: [String] {
        if let c = shotConnected { return c }
        let s = SecretStore(service: Bundle.main.bundleIdentifier ?? "io.github.example.livetips")
        return AIUsage.providers.filter { s.has($0 == "claude" ? .claudeAPIKey : $0 == "openai" ? .openaiAPIKey : .geminiAPIKey) }
    }

    /// This month's API spend per provider, read at most every 30 s.
    static func monthSpend(fresh: Bool = false) -> [String: Double] {
        if !fresh, let c = cache, Date().timeIntervalSince(c.at) < 30 { return c.spend }
        let s = ProviderLimits.monthSpend(AIUsage.load(path: AIUsageView.ledgerPath), month: ProviderLimits.month())
        cache = (Date(), s)
        return s
    }

    static func level(_ p: String, config c: AppConfig) -> ProviderLimits.Level {
        ProviderLimits.level(spent: monthSpend()[p] ?? 0, budget: c.providerBudgets[p])
    }

    /// The API way of a provider is at its monthly limit (the preparation then switches or stops, like the engine).
    static func capped(route: String, config c: AppConfig) -> Bool {
        guard let p = AIUsage.provider(route: route) else { return false }
        return level(p, config: c) == .capped
    }

    /// Any connected provider at its alert share or limit (the menu bar icon turns orange).
    static func anyAlert(config c: AppConfig) -> Bool {
        connected.contains { level($0, config: c) != .ok }
    }

    /// Posts the alerts that are due; called with the menu bar refresh.
    static func check(config c: AppConfig) {
        let month = ProviderLimits.month()
        var shown = Set(UserDefaults.standard.stringArray(forKey: shownKey) ?? [])
        var changed = false
        for p in connected {
            let b = c.providerBudgets[p]
            let spent = monthSpend()[p] ?? 0
            guard let lv = ProviderLimits.due(level: ProviderLimits.level(spent: spent, budget: b), shown: shown, provider: p, month: month) else { continue }
            shown.insert(ProviderLimits.alertKey(provider: p, month: month, level: lv))
            if lv == .capped { shown.insert(ProviderLimits.alertKey(provider: p, month: month, level: .alert)) }
            changed = true
            notify(provider: p, level: lv, spent: spent, budget: b)
        }
        if changed {
            UserDefaults.standard.set(Array(shown.filter { $0.contains("." + month + ".") }), forKey: shownKey)
        }
    }

    private static func notify(provider p: String, level: ProviderLimits.Level, spent: Double, budget b: AppConfig.ProviderBudget) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let name = AIUsageView.name(p)
        let n = UNMutableNotificationContent()
        let vars = ["provider": name, "spent": String(format: "%.2f", spent), "cap": String(format: "%.0f", b.monthlyUSD),
                    "pct": String(format: "%.0f", b.alertPercent)]
        n.title = L(level == .capped ? "limit.capped.title" : "limit.alert.title", vars)
        n.body = L(level == .capped ? "limit.capped.body" : "limit.alert.body", vars)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "pn-limit-" + p + "-" + level.rawValue, content: n, trigger: nil))
        UsageLog.log("provider_limit_" + level.rawValue, ["provider": p])
    }
}
