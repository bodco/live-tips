import Foundation

/// 0.9.3 (owner, 2026-11-04): AI used through API keys (Claude, OpenAI, Gemini), from state/spend-ledger.jsonl: one
/// line per model request of the engine (livetips_m0.routing.spend_ledger) and one per preparation (PrepRunner.ledger).
/// Only the API ways count here; the Claude and ChatGPT accounts are paid by their plans. Pure, for CoreChecks.
public enum AIUsage {
    public static let providers = ["claude", "openai", "gemini"]
    public static let stages = ["prep", "live", "after"]

    public struct Row: Equatable, Sendable {
        public var day: String            // yyyy-MM-dd, the local day the line was written
        public var stage: String          // prep | live | after
        public var provider: String       // claude | openai | gemini
        public var model: String
        public var input = 0
        public var output = 0
        public var cacheRead = 0
        public var usd = 0.0
        public var error = false
        public init(day: String, stage: String, provider: String, model: String) {
            self.day = day; self.stage = stage; self.provider = provider; self.model = model
        }
    }

    public struct Total: Equatable, Sendable {
        public var requests = 0
        public var input = 0
        public var output = 0
        public var usd = 0.0
        public init() {}
        public mutating func add(_ r: Row) { requests += 1; input += r.input + r.cacheRead; output += r.output; usd += r.usd }
    }

    /// The provider of an API way; nil for the accounts (code, codex), the model on this Mac and the plan.
    public static func provider(route: String) -> String? {
        switch route { case "api": return "claude"; case "openai": return "openai"; case "gemini": return "gemini"; default: return nil }
    }

    /// The stage of a ledger job: "live" during the call, "prep*" before it, the rest after it; nil for a route check.
    public static func stage(job: String) -> String? {
        let j = job.lowercased()
        if j == "ping" || j.isEmpty { return nil }
        if j.hasPrefix("prep") { return "prep" }
        if j == "live" || j == "tips" { return "live" }
        return "after"
    }

    private static func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? Int((v as? String) ?? "") ?? 0 }

    /// One ledger line, or nil when it is not an API request (or not readable).
    public static func parse(_ line: String) -> Row? {
        guard let d = line.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let at = o["at"] as? String, at.count >= 10,
              let provider = provider(route: (o["route"] as? String) ?? ""), let stage = stage(job: (o["job"] as? String) ?? "")
        else { return nil }
        var r = Row(day: String(at.prefix(10)), stage: stage, provider: provider, model: (o["model"] as? String) ?? "")
        r.input = int(o["input"] ?? o["input_tokens"])
        r.output = int(o["output"] ?? o["output_tokens"])
        r.cacheRead = int(o["cache_read"])
        r.usd = (o["usd"] as? NSNumber)?.doubleValue ?? 0
        r.error = (o["error"] as? Bool) ?? false
        if r.model.isEmpty { r.model = "unknown" }
        return r
    }

    public static func parse(text: String) -> [Row] { text.split(separator: "\n").compactMap { parse(String($0)) } }

    public static func load(path: String) -> [Row] {
        guard let t = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return parse(text: t)
    }

    /// Rows of the days from `from` to `to`, both included (yyyy-MM-dd compares as text).
    public static func filter(_ rows: [Row], from: String, to: String) -> [Row] {
        rows.filter { $0.day >= from && $0.day <= to }
    }

    /// (provider, model, total), by provider order, then by spend.
    public static func byModel(_ rows: [Row]) -> [(provider: String, model: String, total: Total)] {
        var m: [String: Total] = [:]
        for r in rows { m[r.provider + "\u{1}" + r.model, default: Total()].add(r) }
        return m.map { kv -> (provider: String, model: String, total: Total) in
            let p = kv.key.split(separator: "\u{1}", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            return (provider: p[0], model: p.count > 1 ? p[1] : "", total: kv.value)
        }.sorted { a, b in
            let ia = providers.firstIndex(of: a.provider) ?? 9, ib = providers.firstIndex(of: b.provider) ?? 9
            return ia != ib ? ia < ib : (a.total.usd != b.total.usd ? a.total.usd > b.total.usd : a.model < b.model)
        }
    }

    /// stage -> provider -> total; every stage and provider present, zero when unused.
    public static func byStage(_ rows: [Row]) -> [String: [String: Total]] {
        var out: [String: [String: Total]] = [:]
        for s in stages { out[s] = Dictionary(uniqueKeysWithValues: providers.map { ($0, Total()) }) }
        for r in rows { out[r.stage, default: [:]][r.provider, default: Total()].add(r) }
        return out
    }

    public static func total(_ rows: [Row]) -> Total { rows.reduce(into: Total()) { $0.add($1) } }
}
