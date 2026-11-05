import Foundation

/// Pacenote 0.9.4 (owner, rules/voices.yaml > meet): after the call the Google Meet record names the speakers.
/// With Meet's own transcript (Workspace, someone turned it on) every unnamed voice of this Mac's transcript is
/// matched by time: the Meet participant who spoke when the voice spoke. Without it, the participants are only
/// suggestions, except the plain case of one unnamed voice and one participant nobody else is named after.
/// A name given this way is marked "meet"; the voice library does not learn from it.
public enum MeetSpeakers {
    public struct Spoken: Equatable {
        public var name: String; public var start: Date; public var end: Date
        public init(name: String, start: Date, end: Date) { self.name = name; self.start = start; self.end = end }
    }

    /// Meet transcript entries (participant resource name, startTime, endTime) as who spoke when.
    public static func spoken(entries: [[String: Any]], names: [String: String]) -> [Spoken] {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let g = ISO8601DateFormatter(); g.formatOptions = [.withInternetDateTime]
        func d(_ s: Any?) -> Date? { (s as? String).flatMap { f.date(from: $0) ?? g.date(from: $0) } }
        return entries.compactMap { e in
            guard let who = names[(e["participant"] as? String) ?? ""], who != "?", let a = d(e["startTime"]) else { return nil }
            return Spoken(name: who, start: a, end: d(e["endTime"]) ?? a.addingTimeInterval(3))
        }
    }

    /// The other side's tagged lines "[HH:MM:SS] Them [S2] (en): ..." as (seconds of the day, speaker id).
    public static func lines(_ md: String) -> [(t: Int, sid: String)] {
        let rx = try! NSRegularExpression(pattern: "^\\[(\\d\\d):(\\d\\d):(\\d\\d)\\] .+? \\[(S\\d+)\\] \\(\\w+\\): ", options: [.anchorsMatchLines])
        let ns = md as NSString
        return rx.matches(in: md, range: NSRange(location: 0, length: ns.length)).map { m in
            let n = (1...3).map { Int(ns.substring(with: m.range(at: $0))) ?? 0 }
            return (n[0] * 3600 + n[1] * 60 + n[2], ns.substring(with: m.range(at: 4)))
        }
    }

    public static func normal(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// Names for unnamed speaker ids. `named`: sid -> name already given; `merged`: sid -> sid it joined;
    /// `me`: the PM's names (never given to the other side); `resolve`: an alias -> the name kept (the library).
    public static func match(lines: [(t: Int, sid: String)], spoken: [Spoken], participants: [String],
                             named: [String: String], merged: [String: String] = [:], me: [String],
                             resolve: (String) -> String = { $0 }, calendar: Calendar = .current,
                             minVotes: Int = 3, minShare: Double = 0.7) -> [String: String] {
        func root(_ s: String) -> String { var s = s, seen = Set<String>(); while let n = merged[s], !seen.contains(s) { seen.insert(s); s = n }; return s }
        let mine = Set(me.map(normal).filter { !$0.isEmpty })
        func isMe(_ n: String) -> Bool { mine.contains(normal(n)) || mine.contains(normal(resolve(n))) }
        var taken = Set(named.values.map { normal(resolve($0)) })
        let unnamed = Set(lines.map { root($0.sid) }).filter { (named[$0] ?? "").isEmpty }
        var out: [String: String] = [:]
        if !spoken.isEmpty {
            func sec(_ d: Date) -> Int { let c = calendar.dateComponents([.hour, .minute, .second], from: d); return (c.hour ?? 0) * 3600 + (c.minute ?? 0) * 60 + (c.second ?? 0) }
            let iv = spoken.filter { !isMe($0.name) }.map { (a: sec($0.start) - 2, b: sec($0.end) + 2, n: resolve($0.name)) }
            var votes: [String: [String: Int]] = [:]
            for l in lines { let s = root(l.sid); guard unnamed.contains(s) else { continue }
                for n in Set(iv.filter { $0.a <= l.t && l.t <= $0.b }.map { $0.n }) { votes[s, default: [:]][n, default: 0] += 1 } }
            // the clearest voice first, so two voices never take one name
            let ranked = votes.compactMap { s, v -> (String, String, Int, Double)? in
                guard let best = v.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) else { return nil }
                return (s, best.key, best.value, Double(best.value) / Double(v.values.reduce(0, +)))
            }.sorted { ($0.2, $0.0) > ($1.2, $1.0) }
            for (s, n, c, share) in ranked where c >= minVotes && share >= minShare && !taken.contains(normal(n)) {
                out[s] = n; taken.insert(normal(n))
            }
            return out
        }
        let free = participants.map(resolve).filter { !isMe($0) && !taken.contains(normal($0)) }
        if unnamed.count == 1, Set(free.map(normal)).count == 1, let s = unnamed.first, let n = free.first { out[s] = n }
        return out
    }
}
