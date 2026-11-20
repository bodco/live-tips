import Foundation

/// 0.26.2 (owner, 2026-11-20): the model lists of the API pickers (Claude, OpenAI, Gemini) come from the provider's own
/// list with the key, so a new model shows up in Settings without an app update. Pure: parsing, the text-model filter,
/// the order (newest first), the on-disk cache and the built-in fallback. The requests live in the app
/// (ModelCatalogStore). A model the app has no price for is marked `known == false`: it is listed and works, but the
/// spending counts nothing for it (cost.py has no price) until the price table gets it.
public enum ModelCatalog {
    public enum Provider: String, CaseIterable, Codable, Sendable { case claude, openai, gemini }

    public struct Entry: Equatable, Codable, Sendable {
        public var id: String
        public var label: String       // what the picker shows (the hand-written label with the price, else the provider's name)
        public var known: Bool         // the app has a price for it (cost.py PRICES)
        public var created: Double     // epoch seconds; 0 when the provider does not say (Gemini)
        public init(id: String, label: String, known: Bool = false, created: Double = 0) {
            self.id = id; self.label = label; self.known = known; self.created = created
        }
    }

    public typealias Page = (entries: [Entry], next: String?)

    /// The families cost.py has a price for (livetips_m0/cost.py PRICES, same substring match). Kept in step by
    /// spikes/m0/tests/test_model_prices_sync.py: add a family in both places.
    public static let pricedFamilies: [String] = [
        "gpt-6-astra", "gpt-6.1-sol", "gpt-6.1-terra", "gpt-6-luna", "gpt-5.4-mini",
        "gemini-4-argon", "gemini-3.8-flash", "gemini-3.6-flash", "gemini-3.5-flash-lite", "gemini-3.1-flash-lite",
        "haiku-5-5", "sonnet-5-5", "opus-5-5", "sonnet-5", "opus-5", "haiku-4-5", "sonnet-4",
    ]

    public static func isKnown(_ id: String) -> Bool {
        let m = id.lowercased()
        return pricedFamilies.contains { m.contains($0) }
    }

    /// Hand-written labels (with the price per 1M input / output tokens, checked 2026-11-04 for Gemini and OpenAI).
    public static let labels: [String: String] = [
        "gemini-3.5-flash-lite": "Gemini 3.5 Flash-Lite \u{00B7} fastest \u{00B7} $0.30 / $2.50",
        "gemini-3.8-flash": "Gemini 3.8 Flash \u{00B7} balanced \u{00B7} $0.75 / $3.75",
        "gemini-4-argon": "Gemini 4 Argon \u{00B7} most capable \u{00B7} $2 / $10",
        "gpt-6-luna": "GPT-6 Luna \u{00B7} fastest, like Haiku \u{00B7} $0.10 / $0.50",
        "gpt-6.1-terra": "GPT-6.1 Terra \u{00B7} fast, between Haiku and Sonnet \u{00B7} $1 / $5",
        "gpt-6.1-sol": "GPT-6.1 Sol \u{00B7} balanced, like Sonnet \u{00B7} $2 / $10",
        "gpt-6-astra": "GPT-6 Astra \u{00B7} most capable, above Opus in price \u{00B7} $10 / $50",
        "gpt-5.4-mini": "GPT-5.4 mini \u{00B7} older \u{00B7} $0.75 / $4.50",
    ]

    /// The lists known at build time: shown when the provider has never been reached (no key, offline).
    public static var builtin: [Provider: [Entry]] {
        let ids: [Provider: [String]] = [
            .gemini: ["gemini-3.5-flash-lite", "gemini-3.8-flash", "gemini-4-argon"],
            .openai: ["gpt-6-luna", "gpt-6.1-terra", "gpt-6.1-sol", "gpt-6-astra", "gpt-5.4-mini"],
            .claude: ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5", "claude-sonnet-5", "claude-opus-5"],
        ]
        var out: [Provider: [Entry]] = [:]
        for (p, list) in ids { out[p] = sorted(list.map { entry(id: $0, name: nil, created: 0) }) }
        return out
    }

    static func entry(id: String, name: String?, created: Double) -> Entry {
        let n = name ?? ""
        let shown = labels[id] ?? (n.isEmpty ? id : n)
        return Entry(id: id, label: shown, known: isKnown(id), created: created)
    }

    // MARK: - Which models are listed (text models only)

    static let geminiSkip = ["embedding", "image", "tts", "audio", "live", "native", "robotics", "computer-use", "imagen",
                             "veo", "aqa", "learnlm", "latest", "customtools", "deep-research"]
    static let openaiSkip = ["embedding", "whisper", "tts", "audio", "realtime", "image", "transcribe", "moderation",
                             "search", "instruct", "chat-latest", "dall", "sora", "davinci", "babbage"]
    static let claudeFamilies = ["haiku", "sonnet", "opus", "fable", "mythos"]

    public static func isGeminiText(_ id: String, methods: [String]) -> Bool {
        guard id.hasPrefix("gemini-"), methods.contains("generateContent") else { return false }
        return !geminiSkip.contains { id.contains($0) }
    }

    public static func isOpenAIText(_ id: String) -> Bool {
        guard id.hasPrefix("gpt-") else { return false }
        if openaiSkip.contains(where: { id.contains($0) }) { return false }
        return !hasDateSuffix(id)       // "gpt-6-luna-2026-11-04" is a snapshot of "gpt-6-luna"
    }

    public static func isClaudeText(_ id: String) -> Bool {
        id.hasPrefix("claude-") && claudeFamilies.contains { id.contains($0) }
    }

    static func hasDateSuffix(_ id: String) -> Bool {
        let p = id.split(separator: "-").map(String.init)
        guard p.count >= 4 else { return false }
        let y = p[p.count - 3], m = p[p.count - 2], d = p[p.count - 1]
        return y.count == 4 && m.count == 2 && d.count == 2 && Int(y) != nil && Int(m) != nil && Int(d) != nil
    }

    // MARK: - Parsing the provider answers

    /// GET /v1beta/models: {"models": [{"name": "models/gemini-4-hydrogen", "displayName", "supportedGenerationMethods"}],
    /// "nextPageToken"}.
    public static func parseGemini(_ data: Data) -> Page {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return ([], nil) }
        var out: [Entry] = []
        for m in (o["models"] as? [[String: Any]]) ?? [] {
            guard let raw = m["name"] as? String else { continue }
            let id = raw.hasPrefix("models/") ? String(raw.dropFirst(7)) : raw
            let methods = (m["supportedGenerationMethods"] as? [String]) ?? []
            guard isGeminiText(id, methods: methods) else { continue }
            out.append(entry(id: id, name: m["displayName"] as? String, created: 0))
        }
        let next = (o["nextPageToken"] as? String) ?? ""
        return (out, next.isEmpty ? nil : next)
    }

    /// GET /v1/models: {"data": [{"id", "created"}]}. No paging.
    public static func parseOpenAI(_ data: Data) -> Page {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return ([], nil) }
        var out: [Entry] = []
        for m in (o["data"] as? [[String: Any]]) ?? [] {
            guard let id = m["id"] as? String, isOpenAIText(id) else { continue }
            out.append(entry(id: id, name: nil, created: (m["created"] as? NSNumber)?.doubleValue ?? 0))
        }
        return (out, nil)
    }

    /// GET /v1/models: {"data": [{"id", "display_name", "created_at"}], "has_more", "last_id"}.
    public static func parseClaude(_ data: Data) -> Page {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return ([], nil) }
        var out: [Entry] = []
        for m in (o["data"] as? [[String: Any]]) ?? [] {
            guard let id = m["id"] as? String, isClaudeText(id) else { continue }
            out.append(entry(id: id, name: m["display_name"] as? String, created: epoch(m["created_at"] as? String)))
        }
        let more = (o["has_more"] as? Bool) ?? false
        let last = (o["last_id"] as? String) ?? ""
        return (out, more && !last.isEmpty ? last : nil)
    }

    public static func parse(_ p: Provider, _ data: Data) -> Page {
        switch p {
        case .gemini: return parseGemini(data)
        case .openai: return parseOpenAI(data)
        case .claude: return parseClaude(data)
        }
    }

    static func epoch(_ s: String?) -> Double {
        guard let s = s, !s.isEmpty else { return 0 }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d.timeIntervalSince1970 }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)?.timeIntervalSince1970 ?? 0
    }

    // MARK: - Order and choices

    /// "gemini-3.5-flash-lite" -> 3.5, "gpt-6.1-sol" -> 6.1, "claude-opus-5-5" -> 5.5, "gemini-4-argon" -> 4.
    static func version(_ id: String) -> Double {
        var parts: [String] = []
        for c in id.split(separator: "-").map(String.init) {
            if Double(c) != nil && c.count <= 4 { parts.append(c) } else if !parts.isEmpty { break }
        }
        guard let first = parts.first else { return 0 }
        if parts.count >= 2, Int(first) != nil, Int(parts[1]) != nil, parts[1].count <= 2 { return Double(first + "." + parts[1]) ?? 0 }
        return Double(first) ?? 0
    }

    /// Newest first: by the provider's date when it gives one (Claude, OpenAI), else by the version in the name (Gemini).
    public static func sorted(_ list: [Entry]) -> [Entry] {
        list.sorted { a, b in
            if a.created != b.created { return a.created > b.created }
            let va = version(a.id), vb = version(b.id)
            if va != vb { return va > vb }
            return a.id < b.id
        }
    }

    /// A cached list read again: labels and prices follow the app's tables, which an update may have extended.
    public static func relabel(_ list: [Entry]) -> [Entry] {
        list.map { e in
            var n = e
            if let l = labels[e.id] { n.label = l }
            n.known = isKnown(e.id)
            return n
        }
    }

    /// The same model once, the first one wins.
    public static func unique(_ list: [Entry]) -> [Entry] {
        var seen = Set<String>()
        return list.filter { seen.insert($0.id).inserted }
    }

    /// What a picker lists: the provider's list (else the built-in one), and the model chosen now even when the
    /// provider no longer lists it, so an old choice never disappears from under the PM.
    public static func choices(_ p: Provider, live: [Entry], selected: String) -> [Entry] {
        var list = live.isEmpty ? (builtin[p] ?? []) : unique(sorted(live))
        if !selected.isEmpty, !list.contains(where: { $0.id == selected }) {
            list.append(entry(id: selected, name: nil, created: 0))
        }
        return list
    }

    // MARK: - Cache on disk (state/models-<provider>.json)

    struct Cached: Codable { var fetchedAt: Double; var entries: [Entry] }

    public static func cachePath(dir: String, provider: Provider) -> String {
        (dir as NSString).appendingPathComponent("models-\(provider.rawValue).json")
    }

    public static func saveCache(_ entries: [Entry], fetchedAt: Double, dir: String, provider: Provider) {
        guard let data = try? JSONEncoder().encode(Cached(fetchedAt: fetchedAt, entries: entries)) else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: cachePath(dir: dir, provider: provider)), options: .atomic)
    }

    public static func loadCache(dir: String, provider: Provider) -> (entries: [Entry], fetchedAt: Double)? {
        guard let data = FileManager.default.contents(atPath: cachePath(dir: dir, provider: provider)),
              let c = try? JSONDecoder().decode(Cached.self, from: data), !c.entries.isEmpty else { return nil }
        return (c.entries, c.fetchedAt)
    }

    /// The list is read again from the provider at most every 6 hours unless the PM asks (or a key was just tested).
    public static func isFresh(fetchedAt: Double, now: Double = Date().timeIntervalSince1970, maxAge: Double = 6 * 3600) -> Bool {
        now >= fetchedAt && now - fetchedAt < maxAge
    }
}
