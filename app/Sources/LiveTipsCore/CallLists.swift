import Foundation

/// Pacenote 0.12.2 (L1, research/pacenote-call-lists-audit-2026-11-15.md): one rule for the Decisions, Tasks and Risks
/// of a call. Every place that shows or sends these lists (call page tabs and counts, Summary, Home, Export, follow-up,
/// CRM, server sync) reads them here, so one call never has two different lists. Each list comes from the first of:
///  1. the PM's edit on the call page: the last call picture ("situation") with `source: call_page` that edited this
///     list (`lists: ["decisions"]`; a line without `lists` edited them all). An edit counts even when it left the
///     list empty: the PM removed everything on purpose. Tasks have no such level here: the PM edits tasks in the
///     commitments register, which stays their store (L4);
///  2. the Meeting notes of <stem>.notes.md: `### Decisions`, `### Action items`, `### Risks` (schema 3, L3);
///  3. the live call picture: the last situation written during the call (not by the call page);
///  4. the older notes sections: `## Decisions`, `## Action items`.
/// Levels 2-4 count only when they have a real item: "nothing" lines (MeetingNotes.isNothing) are dropped everywhere,
/// so a notes heading that only says "None" falls through to the next level.
public enum CallLists {
    public enum Source: String, Equatable { case pm, notes, live, legacy, none }

    public struct Task: Equatable {
        public var owner: String       // "" when the line names nobody
        public var text: String        // what, without the owner and the due date
        public var due: String         // "Friday", "" when none
        public var mine: Bool?         // true / false from the live picture (actions / theirs), nil when unknown (notes)
        public var t: String           // "10:06:29" from the notes, "" when none
        public init(owner: String = "", text: String, due: String = "", mine: Bool? = nil, t: String = "") {
            self.owner = owner; self.text = text; self.due = due; self.mine = mine; self.t = t
        }
        /// One line for copy, export and the follow-up: "Mike: send the deck (due: Friday)".
        public var line: String {
            (owner.isEmpty ? "" : owner + ": ") + text + (due.isEmpty ? "" : " (due: " + due + ")")
        }
    }

    public struct Lists: Equatable {
        public var decisions: [String] = []
        /// 0.12.2 (L2): the decisions with their notes time ("10:06:29", "" outside the notes), for the Summary panel.
        public var decisionItems: [MeetingNotes.Item] = []
        public var tasks: [Task] = []
        public var risks: [String] = []
        /// 0.12.2 (L3): the risks with their notes time, for the Summary panel.
        public var riskItems: [MeetingNotes.Item] = []
        public var decisionsFrom: Source = .none
        public var tasksFrom: Source = .none
        public var risksFrom: Source = .none
        public init() {}
        public var isEmpty: Bool { decisions.isEmpty && tasks.isEmpty && risks.isEmpty }
    }

    // MARK: the rule

    /// `situations`: every `kind: situation` line of the call's tips file, in file order. `notes`: the text of
    /// <stem>.notes.md, nil when there is none.
    public static func resolve(situations: [[String: Any]], notes: String?) -> Lists {
        var out = Lists()
        let edits = situations.filter { ($0["source"] as? String) == "call_page" }
        let live = situations.last { ($0["source"] as? String) != "call_page" }
        let mn = notes.flatMap { MeetingNotes.parse($0) }

        func pmEdit(_ list: String) -> [String: Any]? {
            edits.last { e in
                guard let l = e["lists"] as? [String] else { return true }
                return l.contains(list)
            }
        }

        // Decisions
        if let e = pmEdit("decisions") {
            out.decisionItems = clean(strings(e["decisions"])).map { MeetingNotes.Item(text: $0) }; out.decisionsFrom = .pm
        } else if let d = nonEmpty(cleanItems(mn?.decisions ?? [])) {
            out.decisionItems = d; out.decisionsFrom = .notes
        } else if let l = live, let d = nonEmpty(clean(strings(l["decisions"]))) {
            out.decisionItems = d.map { MeetingNotes.Item(text: $0) }; out.decisionsFrom = .live
        } else if let n = notes, let d = nonEmpty(clean(legacy(n, ["decisions", "рішення"]))) {
            out.decisionItems = d.map { MeetingNotes.Item(text: $0) }; out.decisionsFrom = .legacy
        }
        out.decisions = out.decisionItems.map(\.text)

        // Risks
        if let e = pmEdit("risks") {
            out.riskItems = clean(whats(e["risks"])).map { MeetingNotes.Item(text: $0) }; out.risksFrom = .pm
        } else if let r = nonEmpty(cleanItems(mn?.risks ?? [])) {
            out.riskItems = r; out.risksFrom = .notes
        } else if let l = live, let r = nonEmpty(clean(whats(l["risks"]))) {
            out.riskItems = r.map { MeetingNotes.Item(text: $0) }; out.risksFrom = .live
        }
        out.risks = out.riskItems.map(\.text)

        // Tasks
        if let t = nonEmpty(dedup((mn?.actions ?? []).compactMap { i in task(i.text, t: i.t) })) {
            out.tasks = t; out.tasksFrom = .notes
        } else if let l = live, let t = nonEmpty(liveTasks(l)) {
            out.tasks = t; out.tasksFrom = .live
        } else if let n = notes, let t = nonEmpty(dedup(legacy(n, ["action items", "задачі", "завдання"]).compactMap { task($0) })) {
            out.tasks = t; out.tasksFrom = .legacy
        }
        return out
    }

    // MARK: files

    /// The tips files of a call, the app's <file>.tips.jsonl first, then the skill's <stem>.tips.jsonl.
    public static func tipsPaths(transcript file: String) -> [String] {
        let stem = file.hasSuffix(".md") ? String(file.dropLast(3)) : file
        return [file + ".tips.jsonl", stem + ".tips.jsonl"]
    }

    public static func notesPath(transcript file: String) -> String {
        (file.hasSuffix(".md") ? String(file.dropLast(3)) : file) + ".notes.md"
    }

    /// Every situation line of the first tips file that has one, in file order.
    public static func situations(transcript file: String) -> [[String: Any]] {
        for p in tipsPaths(transcript: file) {
            guard let s = try? String(contentsOfFile: p, encoding: .utf8) else { continue }
            let found: [[String: Any]] = s.split(separator: "\n").compactMap { ln in
                guard ln.contains("situation"),
                      let o = (try? JSONSerialization.jsonObject(with: Data(ln.utf8))) as? [String: Any],
                      (o["kind"] as? String) == "situation" else { return nil }
                return o
            }
            if !found.isEmpty { return found }
        }
        return []
    }

    public static func read(transcript file: String) -> Lists {
        resolve(situations: situations(transcript: file),
                notes: try? String(contentsOfFile: notesPath(transcript: file), encoding: .utf8))
    }

    // MARK: helpers

    static func strings(_ v: Any?) -> [String] { ((v as? [Any]) ?? []).compactMap { $0 as? String } }
    static func whats(_ v: Any?) -> [String] {
        ((v as? [Any]) ?? []).compactMap { ($0 as? [String: Any])?["what"] as? String ?? $0 as? String }
    }
    static func nonEmpty<T>(_ a: [T]) -> [T]? { a.isEmpty ? nil : a }

    /// Plain text (no "**"), long dashes replaced, trimmed; empty and "nothing" lines dropped, repeats dropped.
    static func clean(_ a: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for s in a {
            let p = plain(s)
            guard !p.isEmpty, !MeetingNotes.isNothing(p), seen.insert(p.lowercased()).inserted else { continue }
            out.append(p)
        }
        return out
    }

    /// `clean` for notes items: the same text rule, the first time of a repeated line kept.
    static func cleanItems(_ a: [MeetingNotes.Item]) -> [MeetingNotes.Item] {
        var seen = Set<String>(), out: [MeetingNotes.Item] = []
        for i in a {
            let p = plain(i.text)
            guard !p.isEmpty, !MeetingNotes.isNothing(p), seen.insert(p.lowercased()).inserted else { continue }
            out.append(MeetingNotes.Item(t: i.t, text: p))
        }
        return out
    }

    static func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "\u{2014}", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func dedup(_ a: [Task]) -> [Task] {
        var seen = Set<String>()
        return a.filter { seen.insert(($0.owner + "|" + $0.text).lowercased()).inserted }
    }

    /// A notes task line, "**Owner**: what (due: when)" (rules/notes.yaml), "Owner: what" or just "what".
    static func task(_ raw: String, t: String = "") -> Task? {
        var s = raw.replacingOccurrences(of: "\u{2014}", with: "-").trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, !MeetingNotes.isNothing(s) else { return nil }
        var owner = ""
        if let r = s.range(of: "^\\*\\*([^*]{1,60})\\*\\*\\s*:\\s*", options: .regularExpression) {
            owner = s[r].replacingOccurrences(of: "**", with: "").replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespaces)
            s = String(s[r.upperBound...])
        } else if let r = s.range(of: "^\\*\\*([^*]{1,60}):\\*\\*\\s*", options: .regularExpression) {
            owner = s[r].replacingOccurrences(of: "**", with: "").replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespaces)
            s = String(s[r.upperBound...])
        }
        var due = ""
        if let r = s.range(of: "\\s*\\((due|до|термін|deadline)\\s*:?\\s*([^)]*)\\)\\s*\\.?$", options: [.regularExpression, .caseInsensitive]) {
            let inner = s[r].trimmingCharacters(in: CharacterSet(charactersIn: " .()"))
            due = inner.replacingOccurrences(of: "^(due|до|термін|deadline)\\s*:?\\s*", with: "", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespaces)
            s = String(s[..<r.lowerBound])
        }
        let text = plain(s)
        guard !text.isEmpty, !MeetingNotes.isNothing(text) else { return nil }
        return Task(owner: owner, text: text, due: due, t: t)
    }

    /// The live picture's tasks: what the PM took on (actions) and what the other side promised (theirs).
    static func liveTasks(_ o: [String: Any]) -> [Task] {
        var out: [Task] = []
        for d in (o["actions"] as? [[String: Any]]) ?? [] {
            guard let w = d["what"] as? String else { continue }
            let p = plain(w); guard !p.isEmpty, !MeetingNotes.isNothing(p) else { continue }
            out.append(Task(text: p, due: (d["due"] as? String) ?? "", mine: true, t: (d["t"] as? String) ?? ""))
        }
        for d in (o["theirs"] as? [[String: Any]]) ?? [] {
            guard let w = d["what"] as? String else { continue }
            let p = plain(w); guard !p.isEmpty, !MeetingNotes.isNothing(p) else { continue }
            out.append(Task(owner: (d["who"] as? String) ?? "", text: p, due: (d["due"] as? String) ?? "", mine: false, t: (d["t"] as? String) ?? ""))
        }
        return dedup(out)
    }

    /// Lines of the older "## " notes section whose heading contains one of `names` (the same reading as the app's
    /// CallNotes.lines): list markers removed, "#" lines skipped. "## Meeting notes" never matches these names.
    static func legacy(_ notes: String, _ names: [String]) -> [String] {
        var cur: String? = nil, out: [String] = [], found = false
        for raw in notes.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("## ") {
                if found { break }
                let h = l.dropFirst(3).lowercased()
                cur = names.contains { h.contains($0) } ? h : nil
                found = cur != nil
                continue
            }
            guard cur != nil, !l.isEmpty, !l.hasPrefix("#") else { continue }
            out.append(l.replacingOccurrences(of: "^[-*\u{2022}]\\s+", with: "", options: .regularExpression))
        }
        return out
    }
}
