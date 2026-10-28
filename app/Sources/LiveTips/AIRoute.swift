import Foundation
import LiveTipsCore

/// 0.8.2 (owner): the ways to Claude per job (Settings > AI) and the shared state of the automatic switch.
/// The tips engine and the one-off jobs (livetips_m0.routing) read and write the same file, state/ai-routes.json:
/// {"api": {"down": true, "reason": "credit", "since": <unix time>, "checked": <unix time>}, "code": {...}}.
enum AIRoute {
    static let api = "api", code = "code"

    static func other(_ r: String) -> String { r == api ? code : api }

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

    static func markDown(_ r: String, _ reason: String) {
        var o = read()
        let cur = o[r] as? [String: Any] ?? [:]
        let now = Date().timeIntervalSince1970
        o[r] = ["down": true, "reason": reason, "since": (cur["down"] as? Bool) == true ? (cur["since"] ?? now) : now, "checked": now]
        write(o)
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
        if r == api { return e.contains("invalid api key") || e.contains("x-api-key") || e.contains("authentication_error") ? "auth" : nil }
        if e.contains("usage limit") || e.contains("limit reached") || e.contains("hit your limit") || e.contains("limit will reset") { return "limit" }
        if e.contains("/login") || e.contains("not logged in") || e.contains("oauth") || e.contains("authenticate") { return "auth" }
        return nil
    }

    static var hasKey: Bool {
        !(SecretStore(service: Bundle.main.bundleIdentifier ?? "io.github.example.livetips").get(.claudeAPIKey) ?? "").isEmpty
    }

    /// The way can be tried at all: a key for the API, the Claude Code tool for the account.
    static func available(_ r: String) -> Bool { r == api ? hasKey : PrepRunner.claudePath != nil }

    /// A job on this way can run: the way itself, or with auto-switch the other one.
    static func canRun(job: String, config c: AppConfig) -> Bool {
        let r = c.ai.route(job)
        return available(r) || (c.ai.autoSwitch && available(other(r)))
    }

    /// The environment of an engine child process for one job: the way, the switch, the shared state, the key
    /// (to the child only, never written or logged) and the Claude Code tool.
    static func env(job: String, config c: AppConfig, base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        let store = SecretStore(service: Bundle.main.bundleIdentifier ?? "io.github.example.livetips")
        if let k = store.get(.claudeAPIKey), !k.isEmpty { env["CLAUDE_API"] = k } else { env.removeValue(forKey: "CLAUDE_API") }
        if let ws = store.get(.claudeWorkspaceID), !ws.isEmpty { env["CLAUDE_WORKSPACE"] = ws }
        env["LT_AI_JOB"] = job
        env["LT_AI_ROUTE"] = c.ai.route(job)
        env["LT_AI_AUTO"] = c.ai.autoSwitch ? "1" : "0"
        env["LT_AI_STATE"] = statePath
        if let cl = PrepRunner.claudePath { env["LT_CLAUDE_CLI"] = cl }
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        return env
    }

    /// For sidecar-config.json (the tips engine and the judge).
    static func sidecarBlock(config c: AppConfig) -> [String: Any] {
        ["routes": ["tips": c.ai.tips, "after": c.ai.after], "auto": c.ai.autoSwitch, "state": statePath,
         "claude_cli": PrepRunner.claudePath ?? ""]
    }

    static func name(_ r: String) -> String { L(r == api ? "ai.route.api" : "ai.route.code") }

    /// One line per way that is out, for Settings > AI; empty when both answer.
    static func statusLines() -> [String] {
        let o = read()
        let t = DateFormatter(); t.dateFormat = "HH:mm"
        return [code, api].compactMap { r in
            guard let s = o[r] as? [String: Any], (s["down"] as? Bool) == true else { return nil }
            let since = (s["since"] as? Double).map { t.string(from: Date(timeIntervalSince1970: $0)) } ?? ""
            return L("ai.status.out", ["route": name(r), "reason": L("ai.reason." + ((s["reason"] as? String) ?? "error")), "time": since])
        }
    }

    /// Checks the ways that are out now (a one-word request each, through the engine) and calls back.
    @MainActor static func checkNow(done: @escaping () -> Void) {
        let c = AppConfig.load(from: AppPaths.config)
        let down = [code, api].filter { isDown($0) }
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
