import Foundation

/// Pacenote 0.9.4 (owner, rules/usage.yaml > telemetry): "Help improve Pacenote". When the PM turns it on, the local
/// usage log (UsageLog: event names and small parameters, never words, names or ids) of complete days is sent to the
/// author once a week. Times become days; one random install id tells the users apart (it goes when sharing is off); the server checks the same rules
/// again (telemetry/worker.js). The batch can be seen before it goes (Settings > General > Privacy > Show what is sent).
public enum Telemetry {
    public static let endpoint = "https://pacenote-telemetry.neymet-bogdan.workers.dev/v1/batch"
    public static let everyDays = 7

    /// <app root>/state/telemetry.json: {"install", "month", "since", "sent_until", "sent_at"}.
    public struct State: Codable, Equatable {
        public var install = ""; public var month = ""; public var since = ""; public var sentUntil = ""; public var sentAt = ""
        public init() {}
        enum CodingKeys: String, CodingKey { case install, month, since, sentUntil = "sent_until", sentAt = "sent_at" }
    }

    public static func day(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }
    static func month(_ d: Date) -> String { String(day(d).prefix(7)) }
    static func next(_ day: String) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: day) else { return day }
        return f.string(from: d.addingTimeInterval(86400 + 3600))
    }

    /// 0.9.4 (owner): one random id per install, kept while sharing is on, so batches of one user can be told apart
    /// (there are no accounts yet). It is made on this Mac, says nothing about the person and goes when sharing is off.
    public static func ensured(_ s: State, now: Date) -> State {
        var s = s
        if s.install.isEmpty { s.install = UUID().uuidString.lowercased(); s.month = month(now) }
        return s
    }

    /// The days to send now: from the day after the last batch (never before it was turned on) to yesterday, once a week.
    public static func due(_ s: State, now: Date) -> (from: String, to: String)? {
        guard !s.since.isEmpty else { return nil }
        let to = day(now.addingTimeInterval(-86400))
        let from = s.sentUntil.isEmpty ? s.since : max(s.since, next(s.sentUntil))
        guard from <= to else { return nil }
        if !s.sentAt.isEmpty, let last = ISO8601DateFormatter().date(from: s.sentAt), now.timeIntervalSince(last) < Double(everyDays) * 86400 { return nil }
        return (from, to)
    }

    /// Only the parameters UsageLog allows for the event; strings up to 80 characters, numbers and booleans as written.
    static func clean(_ e: String, _ p: Any?) -> [String: Any]? {
        guard let allowed = UsageLog.events[e] else { return nil }
        var out: [String: Any] = [:]
        for (k, v) in (p as? [String: Any]) ?? [:] {
            guard allowed.contains(k) else { return nil }
            if let s = v as? String { guard s.count <= 80 else { return nil }; out[k] = s }
            else if let n = v as? NSNumber { out[k] = n }
            else { return nil }
        }
        return out
    }

    /// The batch: the usage log lines of those days, re-checked against UsageLog.events, with days instead of times.
    public static func batch(usageDir: URL, from: String, to: String, install: String, appVersion: String, rulesVersion: String,
                             uiLang: String, routes: [String: String]) -> [String: Any] {
        var events: [[String: Any]] = []
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: usageDir.path)) ?? []).filter { $0.hasSuffix(".jsonl") && $0.count == 13 }.sorted()
        for n in names where String(n.prefix(7)) >= String(from.prefix(7)) && String(n.prefix(7)) <= String(to.prefix(7)) {
            guard let t = try? String(contentsOf: usageDir.appendingPathComponent(n), encoding: .utf8) else { continue }
            for ln in t.split(separator: "\n") {
                guard let o = (try? JSONSerialization.jsonObject(with: Data(ln.utf8))) as? [String: Any],
                      let ts = o["t"] as? String, let e = o["e"] as? String else { continue }
                let d = String(ts.prefix(10))
                guard d >= from, d <= to, let p = clean(e, o["p"]) else { continue }
                events.append(["d": d, "e": e, "p": p])
            }
        }
        return ["schema": 1, "install": install, "app_version": appVersion, "rules_version": rulesVersion, "ui_lang": uiLang,
                "routes": routes, "from": from, "to": to, "events": events]
    }
}
