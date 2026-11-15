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
}
