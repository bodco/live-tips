import Foundation

/// 0.24.1 (F3, owner 18.11): the AI of each job follows what is connected. Whatever AI is connected does the
/// preparation and the summary; when an account (Claude or ChatGPT) gets connected it becomes the default for both;
/// until then the job runs on what there is. A choice the PM made stays while its AI is connected. Pure, for CoreChecks.
public enum AIDefaults {
    /// The accounts, in the order a newly connected one is adopted (Claude first when both arrive at once).
    public static let accounts = ["code", "codex"]

    /// The order a job looks for a connected AI when its own is not connected. Tips: the fast API keys first;
    /// preparation and after the call: the accounts first (no per-token bill), then the keys, then the slow ones.
    public static func preference(job: String) -> [String] {
        job == "tips" ? ["api", "openai", "gemini", "code", "codex"]
                      : ["code", "codex", "api", "openai", "gemini", "agy", "local"]
    }

    /// The AI the job uses: the chosen one while it is connected (and allowed for the job), else the first connected
    /// one by `preference`; with nothing connected the choice stays as it is.
    public static func pick(job: String, chosen: String, connected: Set<String>) -> String {
        if connected.contains(chosen) && AIChain.allowed(chosen, job: job) { return chosen }
        return preference(job: job).first { connected.contains($0) && AIChain.allowed($0, job: job) } ?? chosen
    }

    /// The routes after a change of what is connected. `seen` is what was connected the last time (nil: never looked,
    /// e.g. the first launch after the update: nothing is adopted then, only routes whose AI is not connected move).
    /// An account connected since the last look becomes the preparation and after-the-call AI.
    public static func apply(_ r: AppConfig.AIRoutes, connected: Set<String>) -> AppConfig.AIRoutes {
        var out = r
        if let seen = r.seen.map(Set.init) {
            if let acc = accounts.first(where: { connected.contains($0) && !seen.contains($0) }) {
                out.prep = acc
                out.after = acc
            }
        }
        out.prep = pick(job: "prep", chosen: out.prep, connected: connected)
        out.after = pick(job: "after", chosen: out.after, connected: connected)
        out.tips = pick(job: "tips", chosen: out.tips, connected: connected)
        out.seen = AIChain.defaultOrder.filter { connected.contains($0) }
        return out
    }
}
