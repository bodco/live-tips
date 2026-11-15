import Foundation

/// 0.14.0 (D1, Get Ready): the two sides of a call in the Meeting Sheet prep. Pure helpers, so CoreChecks can test
/// what the drag and drop and the arrow on a chip do.
public enum PeopleSides {
    /// Moves the first element that matches `match` from `from` to the end of `to`. A locked element (you) stays.
    /// Returns true when something moved.
    @discardableResult
    public static func move<T>(_ match: (T) -> Bool, from: inout [T], to: inout [T], locked: (T) -> Bool = { _ in false }) -> Bool {
        guard let i = from.firstIndex(where: match), !locked(from[i]) else { return false }
        to.append(from.remove(at: i))
        return true
    }

    /// "Emily Carter, David Brooks +2": the first names in full, the rest as a count.
    public static func summary(_ names: [String], first: Int = 2) -> String {
        let n = names.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !n.isEmpty else { return "" }
        let shown = n.prefix(max(1, first)).joined(separator: ", ")
        return n.count > first ? shown + " +\(n.count - first)" : shown
    }

    /// Two letters for the avatar: first and last word ("Christopher Montgomery-Wells" -> "CW"), one for one word.
    public static func initials(_ name: String) -> String {
        let w = name.split(whereSeparator: { $0 == " " || $0 == "-" }).filter { !$0.isEmpty }
        guard let a = w.first?.first else { return "?" }
        if w.count > 1, let b = w.last?.first { return String(a).uppercased() + String(b).uppercased() }
        return String(a).uppercased()
    }
    // MARK: 0.14.0 (D1 smoke): one person under several spellings

    /// "Inna B. Anton S." (two short names that lost their comma) -> ["Inna B.", "Anton S."]. Anything else stays whole.
    public static func splitGlued(_ name: String) -> [String] {
        let t = name.trimmingCharacters(in: .whitespaces)
        let pat = "^(\\p{Lu}[\\p{L}'’-]+ \\p{Lu}\\.)\\s+(\\p{Lu}[\\p{L}'’-]+ \\p{Lu}\\.)$"
        guard let re = try? NSRegularExpression(pattern: pat),
              let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), m.numberOfRanges == 3,
              let a = Range(m.range(at: 1), in: t), let b = Range(m.range(at: 2), in: t) else { return t.isEmpty ? [] : [t] }
        return [String(t[a]), String(t[b])]
    }

    /// First and last name; either may be only an initial. "Olena S.", "O. Starodubtseva", "o.starodubtseva",
    /// "Olena Starodubtseva". One word: first only. Diacritics and case are ignored.
    struct Parts { var first: String; var last: String; var firstFull: Bool; var lastFull: Bool }
    static func parts(_ name: String) -> Parts? {
        var t = name.trimmingCharacters(in: .whitespaces)
        if let at = t.firstIndex(of: "@") { t = String(t[..<at]) }
        if let p = t.firstIndex(of: "(") { t = String(t[..<p]) }
        t = t.replacingOccurrences(of: ".", with: ". ").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let w = t.split(whereSeparator: { $0 == " " || $0 == "_" }).map(String.init).filter { !$0.isEmpty }
        guard let f = w.first else { return nil }
        let clean: (String) -> String = { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,")) }
        let first = clean(f), last = w.count > 1 ? clean(w[w.count - 1]) : ""
        guard !first.isEmpty else { return nil }
        return Parts(first: first, last: last, firstFull: first.count > 1, lastFull: last.count > 1)
    }

    static func compatible(_ a: String, _ af: Bool, _ b: String, _ bf: Bool) -> Bool {
        if af && bf { return a == b }
        return a.first == b.first
    }

    /// The same person written two ways. Both need a last name or initial, unless both are the same single word.
    public static func samePerson(_ a: String, _ b: String) -> Bool {
        guard let x = parts(a), let y = parts(b) else { return false }
        if x.last.isEmpty || y.last.isEmpty { return x.last.isEmpty && y.last.isEmpty && x.first == y.first && x.firstFull }
        // at least one full part has to agree, two bare initials ("A. S." and "A. S.") say too little
        guard (x.firstFull && y.firstFull) || (x.lastFull && y.lastFull) || (x.firstFull != y.firstFull && x.lastFull != y.lastFull) else { return false }
        return compatible(x.first, x.firstFull, y.first, y.firstFull) && compatible(x.last, x.lastFull, y.last, y.lastFull)
    }

    /// A team member from the project config ("Alexey Gnidash (Льоша; Alex, Oleksii Hnidash)"): the name before the
    /// brackets when the person is that name or one of the names in the brackets.
    public static func teamName(for name: String, team: [String]) -> String? {
        for t in team {
            let base = (t.components(separatedBy: "(").first ?? t).trimmingCharacters(in: .whitespaces)
            var alts = [base]
            if let o = t.firstIndex(of: "("), let c = t.lastIndex(of: ")"), o < c {
                alts += t[t.index(after: o)..<c].split(whereSeparator: { ";,".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
            }
            if alts.contains(where: { !$0.isEmpty && ($0.caseInsensitiveCompare(name) == .orderedSame || samePerson($0, name)) }) { return base }
        }
        return nil
    }

    /// The participants of a call as people: glued names split, one person written several ways kept once
    /// ("Anton S." and "A. Sorokin" -> "Anton Sorokin"), in the order first seen.
    public static func merge(_ names: [String]) -> [String] {
        var out: [String] = []
        for n in names.flatMap(splitGlued) {
            if let i = out.firstIndex(where: { samePerson($0, n) }) { out[i] = fuller(out[i], n) } else { out.append(n) }
        }
        return out
    }

    /// "Anton S." + "A. Sorokin" -> "Anton Sorokin"; with nothing to add the first spelling stays.
    static func fuller(_ a: String, _ b: String) -> String {
        guard let x = parts(a), let y = parts(b) else { return a }
        if x.firstFull && x.lastFull { return a }
        if y.firstFull && y.lastFull { return b }
        let words: (String) -> [String] = { $0.replacingOccurrences(of: ".", with: ". ").split(separator: " ").map(String.init) }
        let wa = words(a), wb = words(b)
        guard let fa = wa.first, let la = wa.last, let fb = wb.first, let lb = wb.last, wa.count > 1, wb.count > 1 else { return a }
        let first = x.firstFull ? fa : (y.firstFull ? fb : fa), last = x.lastFull ? la : (y.lastFull ? lb : la)
        let cap: (String) -> String = { $0.contains("@") || $0 == $0.lowercased() ? $0.prefix(1).uppercased() + $0.dropFirst() : $0 }
        return cap(first) + " " + cap(last)
    }
}

