import Foundation
import LiveTipsCore

/// 0.10.0 (owner 12.11): the light usage probe of the PM's Claude and ChatGPT accounts, so the status popover shows
/// numbers ("usage not reported" otherwise until the next real job). One tiny run per account (livetips_m0.usage_probe:
/// `claude -p` on the smallest model, "Reply with OK", one turn, no tools; `codex exec --json` without --ephemeral,
/// whose own session log is read for rate_limits and then removed by its thread id). At launch after 60 s, then every
/// 30 minutes while no call is recording and no preparation runs, and when the popover opens with numbers older than
/// 10 minutes; at most one probe per account per 10 minutes, never for a signed-out account or one at its limit
/// (AIUsageProbePlan). No key goes to the probe: the accounts sign in on their own. Tokens go to the usage ledger as
/// account usage, without a price.
@MainActor
final class AIUsageProbe {
    static let shared = AIUsageProbe()

    private var timer: Timer?
    private var lastProbe: [String: Double] = [:]
    private var running = Set<String>()

    func start() {
        guard timer == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + AIUsageProbePlan.firstDelay) {
            MainActor.assumeIsolated { AIUsageProbe.shared.tick() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: AIUsageProbePlan.every, repeats: true) { _ in
            MainActor.assumeIsolated { AIUsageProbe.shared.tick() }
        }
    }

    func popoverOpened() { tick() }

    /// A call is recording (or waits for the other side) or a preparation or a Meeting Sheet build runs.
    private var busy: Bool {
        if CallEngine.shared.isRunning { return true }
        if ["recording", "standby", "loading_model"].contains(EngineStatus.load(path: CallEngine.shared.statusPath).state) { return true }
        return PrepRunner.shared.running || SheetRunner.shared.running
    }

    private func signedIn(_ r: String) -> Bool {
        switch r {
        case "code": return PrepRunner.claudePath != nil && PrepRunner.shared.loggedIn != false
        case "codex": return CodexAccount.cliPath != nil && CodexAccount.shared.signedIn != false
        default: return false
        }
    }

    func tick() {
        if AIStatusModel.shot != nil { return }            // offscreen pictures
        let now = Date().timeIntervalSince1970
        var accounts: [String: AIAccountUsage.Usage] = [:]
        if let d = FileManager.default.contents(atPath: AIRoute.accountsPath),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { accounts = AIAccountUsage.parseFile(o) }
        let out = AIRoute.outStates()
        let isBusy = busy
        for r in AIUsageProbePlan.routes where !running.contains(r) {
            let blocked = AIUsageProbePlan.blockedUntil(usage: accounts[r], out: out[r], now: now)
            guard AIUsageProbePlan.due(signedIn: signedIn(r), busy: isBusy, reportedAt: accounts[r]?.at, blockedUntil: blocked,
                                       lastProbe: lastProbe[r], now: now) else { continue }
            run(r)
        }
    }

    private func run(_ route: String) {
        let c = AppConfig.load(from: AppPaths.config)
        guard !c.engine.sidecarPython.isEmpty, !c.engine.sidecarDir.isEmpty else { return }
        lastProbe[route] = Date().timeIntervalSince1970
        running.insert(route)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: c.engine.sidecarPython)
        p.arguments = ["-m", "livetips_m0.usage_probe", "--account", route, "--state", AIRoute.statePath]
        p.currentDirectoryURL = URL(fileURLWithPath: c.engine.sidecarDir)
        // no API key: the probe is about the accounts, which sign in on their own
        var env = ProcessInfo.processInfo.environment
        for k in ["CLAUDE_API", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY", "CODEX_API_KEY", "GEMINI_API_KEY"] { env.removeValue(forKey: k) }
        env["LT_AI_STATE"] = AIRoute.statePath
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        if let cl = PrepRunner.claudePath { env["LT_CLAUDE_CLI"] = cl }
        if let cli = CodexAccount.cliPath { env["LT_CODEX_CLI"] = cli }
        p.environment = env
        p.standardOutput = FileHandle.nullDevice
        let appRoot = c.effectiveAppRoot(appSupport: AppPaths.support.path)
        p.standardError = FileHandle.forAppending(path: (appRoot as NSString).appendingPathComponent("logs/usage-probe.log"))
        p.terminationHandler = { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    AIUsageProbe.shared.running.remove(route)
                    AIStatusModel.shared.refresh(force: true)
                }
            }
        }
        do { try p.run() } catch { running.remove(route) }
    }
}
