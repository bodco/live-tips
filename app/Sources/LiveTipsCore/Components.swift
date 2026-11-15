import Foundation

/// 0.16.0 (D3, rules/components.yaml): what Pacenote installs on this Mac, which parts can be removed and what a
/// removal changes. Pure, so CoreChecks can test it; the app measures and removes (OptionalComponents, setup.sh).
public enum ComponentCatalog {
    /// The parts every call needs (setup.sh steps). They are never removed from Settings > Components.
    public static let required = ["python", "core", "venv", "recorder", "tips", "whisper", "localai", "voices"]
    /// The optional parts, in the order Settings > Components and the onboarding show them (v2: Ollama is not a row
    /// of its own; "Local AI model" is the model in Ollama).
    public static let optional = ["local_model", "agent", "link_downloader"]
    /// The optional part the local model needs, which Pacenote opens but never installs or removes itself.
    public static let modelNeeds = "ollama"

    /// Only optional parts can be removed; a required one or an unknown id never.
    public static func canRemove(_ id: String) -> Bool { optional.contains(id) }

    /// The setup.sh step that installs, measures and removes a part ("linkdl", "agent"); nil for the model in Ollama
    /// (LocalLLM removes it through Ollama) and for an unknown id.
    public static func setupStep(_ id: String) -> String? {
        switch id {
        case "link_downloader": return "linkdl"
        case "agent": return "agent"
        case "local_model": return nil
        default: return required.contains(id) ? id : nil
        }
    }

    /// What a part needs before it installs: the model needs Ollama on this Mac.
    public static func needs(_ id: String) -> String? { id == "local_model" ? modelNeeds : nil }

    /// The call agent is offered only with Claude (it runs on the Claude Agent SDK with the API key).
    public static func offered(_ id: String, provider: String) -> Bool { id == "agent" ? provider == "claude" : optional.contains(id) }

    /// The size shown before anything is measured (rules/components.yaml > sizes), in bytes.
    public static func estimate(_ id: String) -> Int64 {
        switch id {
        case "local_model": return 16_000_000_000
        case "agent": return 320_000_000
        case "link_downloader": return 10_000_000
        case "whisper": return 1_600_000_000
        case "localai": return 590_000_000
        case "voices": return 30_000_000
        case "venv": return 300_000_000
        default: return 0
        }
    }

    /// The line setup.sh prints for `size <step>`: "SIZE <bytes>". nil for anything else.
    public static func parseSize(_ line: String) -> Int64? {
        let p = line.split(separator: " ")
        guard p.count == 2, p[0] == "SIZE", let v = Int64(p[1]), v >= 0 else { return nil }
        return v
    }

    /// What a removal freed: measured before minus after, never below zero (never written from the table).
    public static func freed(before: Int64?, after: Int64?) -> Int64 {
        guard let b = before else { return 0 }
        return max(0, b - (after ?? 0))
    }

    /// "16 GB", "320 MB", "10 MB", "0 MB" (decimal units, like Finder).
    public static func format(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1e9
        if gb >= 10 { return String(format: "%.0f GB", gb) }
        if gb >= 1 { return String(format: "%.1f GB", gb).replacingOccurrences(of: ".0 GB", with: " GB") }
        return String(format: "%.0f MB", max(0, Double(bytes) / 1e6))
    }

    /// The onboarding's step 5 summary: how many picked and how much more they take.
    public static func summary(picked: [String], sizes: [String: Int64] = [:]) -> (count: Int, bytes: Int64) {
        let ids = picked.filter { optional.contains($0) }
        return (ids.count, ids.reduce(0) { $0 + (sizes[$1] ?? estimate($1)) })
    }

    /// The AI settings after the model on this Mac is removed: every job set to it moves to the next AI in the
    /// chain (on, connected, not the model, allowed for the job), else to the default route; the chain's local
    /// step is switched off. `connected` is AIRoute.connected() without the model.
    public static func afterRemovingLocal(prep: String, tips: String, after: String, chain: [AIChain.Entry],
                                          connected: Set<String>) -> (prep: String, tips: String, after: String, chain: [AIChain.Entry]) {
        let c = AIChain.normalized(chain)
        func next(_ job: String, _ route: String, _ fallback: String) -> String {
            guard route == "local" else { return route }
            return c.first { $0.on && $0.route != "local" && connected.contains($0.route) && AIChain.allowed($0.route, job: job) }?.route ?? fallback
        }
        return (next("prep", prep, "code"), next("tips", tips, "api"), next("after", after, "code"),
                AIChain.setOn(c, route: "local", on: false))
    }
}
