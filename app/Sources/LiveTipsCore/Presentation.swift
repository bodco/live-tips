import Foundation

/// Pacenote 0.8.5 (rules/presentation.yaml): the deck owners, the talk time and Prepare again.
/// Pure functions, checked by CoreChecks; the windows only call them.
public enum DeckOwners {
    /// Owner values: "me", "all" (a shared slide, who = shared) or a colleague's name (who = other).
    public static let me = "me", all = "all"

    /// "slides 5-9 Ann", "1, 14 all", "10-13 me", "5-9 Ганна", "1, 14 усі", "10-13 я".
    /// Returns the slides and the owner, or nil when the line is not understood (nothing is changed then).
    public static func parse(_ line: String, speakers: [String], count: Int) -> (slides: [Int], owner: String)? {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        for w in ["slides", "slide", "слайди", "слайд"] where text.lowercased().hasPrefix(w) {
            text = String(text.dropFirst(w.count)).trimmingCharacters(in: .whitespaces)
        }
        // The owner is the text after the last number or range.
        guard let m = text.range(of: "^[0-9][0-9 ,\u{2013}-]*", options: .regularExpression) else { return nil }
        let nums = String(text[m]), who = text[m.upperBound...].trimmingCharacters(in: .whitespaces)
        guard !who.isEmpty else { return nil }
        var slides: [Int] = []
        for part in nums.split(whereSeparator: { $0 == "," || $0 == " " }) where !part.isEmpty {
            let ends = part.split(whereSeparator: { $0 == "-" || $0 == "\u{2013}" }).compactMap { Int($0) }
            if ends.count == 1 { slides.append(ends[0]) }
            else if ends.count == 2, ends[0] <= ends[1] { slides += Array(ends[0]...ends[1]) }
            else { return nil }
        }
        slides = slides.filter { $0 >= 1 && $0 <= count }
        guard !slides.isEmpty else { return nil }
        let l = who.lowercased()
        if ["me", "я", "мене", "мої"].contains(l) { return (Array(Set(slides)).sorted(), me) }
        if ["all", "everyone", "shared", "усі", "всі", "спільний", "спільні"].contains(l) { return (Array(Set(slides)).sorted(), all) }
        guard let name = speakers.first(where: { $0.lowercased() == l || $0.lowercased().hasPrefix(l + " ") }) ?? (who.count <= 40 ? who : nil)
        else { return nil }
        return (Array(Set(slides)).sorted(), name)
    }

    /// slides.json "who" and "speaker" for an owner.
    public static func who(_ owner: String) -> (who: String, speaker: String) {
        owner == me ? ("me", "") : owner == all ? ("shared", "") : ("other", owner)
    }

    /// Runs of the same owner, for the strip and the meta line: [(owner, first, last)].
    public static func runs(_ owners: [Int: String], count: Int) -> [(owner: String, from: Int, to: Int)] {
        var out: [(String, Int, Int)] = []
        for n in stride(from: 1, through: count, by: 1) {
            let o = owners[n] ?? me
            if let last = out.last, last.0 == o, last.2 == n - 1 { out[out.count - 1].2 = n } else { out.append((o, n, n)) }
        }
        return out.map { (owner: $0.0, from: $0.1, to: $0.2) }
    }
}

public enum TalkTime {
    /// Talk time = call duration minus Q&A (P2), never below 1 minute.
    public static func talkMinutes(duration: Int, qa: Int, qaOn: Bool) -> Int { max(1, duration - (qaOn ? qa : 0)) }

    /// "24:30", "1:05:00".
    public static func clock(_ seconds: Int) -> String {
        let s = abs(seconds), h = s / 3600, m = (s % 3600) / 60, r = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%d:%02d", m, r)
    }

    static func sec(_ s: [String: Any]) -> Int { s["sec"] as? Int ?? Int((s["sec"] as? Double) ?? 60) }
    /// The PM's own planned seconds: slides with who = me or shared.
    public static func mine(_ slides: [[String: Any]]) -> Int {
        slides.reduce(0) { $0 + (($1["who"] as? String ?? "me") == "other" ? 0 : sec($1)) }
    }
    public static func total(_ slides: [[String: Any]]) -> Int { slides.reduce(0) { $0 + sec($1) } }
}

/// Prepare again (rules/presentation.yaml > prepare_again).
public enum TalkMerge {
    /// The fields the PM edits in "Your talk"; the rest (n, who, speaker) come from the deck owners.
    public static let editable = ["title", "sec", "body", "numbers", "qa", "skip", "short"]

    /// Keep my edits: slides with edited = true keep the PM's text, unless the deck text of that slide changed
    /// (then the new text wins and the old edit stays in the previous version). Rewrite everything: the new slides.
    /// Returns the merged slides and the numbers of the slides kept.
    public static func merge(old: [[String: Any]], new: [[String: Any]], keepEdits: Bool,
                             deckChanged: Set<Int> = []) -> (slides: [[String: Any]], kept: [Int]) {
        guard keepEdits else { return (new, []) }
        var byN: [Int: [String: Any]] = [:]
        for s in old { if let n = num(s) { byN[n] = s } }
        var kept: [Int] = []
        let out: [[String: Any]] = new.map { s in
            guard let n = num(s), let o = byN[n], o["edited"] as? Bool == true, !deckChanged.contains(n) else { return s }
            var m = s
            for k in editable { if let v = o[k] { m[k] = v } }
            m["edited"] = true
            kept.append(n)
            return m
        }
        return (out, kept)
    }

    /// The slides the PM edited, for "Slides you edited ({list})".
    public static func edited(_ slides: [[String: Any]]) -> [Int] {
        slides.compactMap { $0["edited"] as? Bool == true ? num($0) : nil }
    }

    /// "3, 6-8": a short list of slide numbers.
    public static func list(_ ns: [Int]) -> String {
        let s = Array(Set(ns)).sorted()
        var parts: [String] = [], i = 0
        while i < s.count {
            var j = i
            while j + 1 < s.count && s[j + 1] == s[j] + 1 { j += 1 }
            parts.append(j - i >= 2 ? "\(s[i])-\(s[j])" : (i...j).map { String(s[$0]) }.joined(separator: ", "))
            i = j + 1
        }
        return parts.joined(separator: ", ")
    }

    /// Slides whose deck text differs between two deck reads ([n: text]).
    public static func deckChanges(old: [Int: String], new: [Int: String]) -> Set<Int> {
        func norm(_ t: String) -> String { t.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
        return Set(new.keys.filter { norm(new[$0] ?? "") != norm(old[$0] ?? "") })
    }

    public static func num(_ s: [String: Any]) -> Int? { s["n"] as? Int ?? (s["n"] as? Double).map(Int.init) ?? (s["n"] as? String).flatMap(Int.init) }
}

/// 2026-10-29 (owner): which call a preparation belongs to.
public enum PrepOwnership {
    /// A preparation is a held call's (not the next one's of the series) when that call started within 3 hours of the
    /// preparation's own time (its file name), or the preparation was finished before that call ended (and not more
    /// than 12 hours before it started): the PM started the call early and the preparation joined it late.
    public static func belongsToHeld(prepDate: Date, made: Date?, held: [(start: Date, end: Date)], before callDate: Date) -> Bool {
        held.contains { h in
            guard h.start < callDate.addingTimeInterval(-3600) else { return false }
            if abs(h.start.timeIntervalSince(prepDate)) < 3 * 3600 { return true }
            if let m = made, m <= h.end, m >= h.start.addingTimeInterval(-12 * 3600) { return true }
            return false
        }
    }
}
