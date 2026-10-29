import Foundation

/// Pacenote 0.8.5 (rules/learning.yaml): learning from the PM's corrections is a search for patterns. The same
/// correction on two or more different calls is a standing preference; a single one stays with its meeting.
/// Same rule and fixture as the skill's livetips_m0/learning.py (rules/fixtures/learning-patterns.json).
public enum Learning {
    public static let head = "Recurring corrections (the PM made each of them on two or more different calls; apply them always, without being asked):"

    public struct Pattern: Equatable { public var kind: String; public var text: String; public var calls: Int }

    static func words(_ t: String) -> Set<String> {
        Set(t.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init).filter { $0.count >= 3 })
    }

    static func signals(_ records: [[String: Any]]) -> [(kind: String, text: String, file: String)] {
        var out: [(String, String, String)] = []
        for r in records {
            let k = r["kind"] as? String ?? "", f = r["file"] as? String ?? ""
            if k == "followup_instruction", let t = r["text"] as? String, !t.isEmpty { out.append((k, t, f)) }
            else if k == "brief_edit" || k == "followup_edit" {
                for x in (r["removed"] as? [Any]) ?? [] { let t = "\(x)"; if !t.trimmingCharacters(in: .whitespaces).isEmpty { out.append((k, t, f)) } }
            } else if k == "talk_edit", let t = r["say_after"] as? String, !t.isEmpty { out.append((k, t, f))
            } else if k == "card_onme_remove" || k == "card_onme_edit", let t = (r["before"] as? [String: Any])?["text"] as? String, !t.isEmpty {
                out.append((k, t, f))
            }
        }
        return out.map { (kind: $0.0, text: $0.1, file: $0.2) }
    }

    public static func standing(_ records: [[String: Any]], kinds: Set<String>? = nil) -> [Pattern] {
        struct G { var kind: String; var words: Set<String>; var last: (Int, String); var files: Set<String> }
        var groups: [G] = []
        for (i, s) in signals(records).enumerated() {
            if let k = kinds, !k.contains(s.kind) { continue }
            let w = words(s.text)
            guard !w.isEmpty else { continue }
            if let j = groups.firstIndex(where: { $0.kind == s.kind && Double(w.intersection($0.words).count) / Double(w.union($0.words).count) >= 0.5 }) {
                groups[j].last = (i, s.text); groups[j].files.insert(s.file)
            } else {
                groups.append(G(kind: s.kind, words: w, last: (i, s.text), files: [s.file]))
            }
        }
        return groups.filter { $0.files.count >= 2 }
            .sorted { ($0.files.count, $0.last.0) > ($1.files.count, $1.last.0) }
            .map { Pattern(kind: $0.kind, text: $0.last.1, calls: $0.files.count) }
    }

    public static func prompt(_ items: [Pattern]) -> String {
        guard !items.isEmpty else { return "" }
        return head + "\n" + items.prefix(20).map { "- [\($0.kind)] \($0.text)" }.joined(separator: "\n")
    }
}
