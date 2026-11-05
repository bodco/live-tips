import Foundation

/// Pacenote 0.9.5.2 (rules/notes.yaml, schema 2): the readable "## Meeting notes" section at the top of
/// <stem>.notes.md. The model writes fixed English headings (### TL;DR, ### Decisions, ### Action items,
/// ### Open questions, ### Topics with "#### Title [HH:MM:SS]", ### Unclear); the text under them is in the call's
/// language. The same reading as livetips_m0.callnotes.parse_meeting.
public enum MeetingNotes {
    public struct Item: Equatable { public var t: String; public var text: String
        public init(t: String = "", text: String) { self.t = t; self.text = text }
        /// "10:06" of "10:06:29".
        public var hhmm: String { String(t.prefix(5)) }
    }
    public struct Topic: Equatable { public var title: String; public var t: String; public var outcome = ""; public var points: [Item] = [] }
    public struct Notes: Equatable {
        public var tldr = ""
        public var decisions: [Item] = []
        public var actions: [Item] = []
        public var open: [Item] = []
        public var topics: [Topic] = []
        public var unclear: [Item] = []
        public init() {}
        public var isEmpty: Bool { tldr.isEmpty && decisions.isEmpty && actions.isEmpty && open.isEmpty && topics.isEmpty }
    }

    public static let heading = "## Meeting notes"

    /// The section's lines (without its heading), nil when the notes have none.
    public static func section(_ notes: String) -> [String]? {
        let lines = notes.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == heading }) else { return nil }
        var out: [String] = []
        for l in lines[(start + 1)...] {
            if l.hasPrefix("## ") || l.hasPrefix("Coverage: ") { break }
            out.append(l)
        }
        return out
    }

    static func item(_ s: String) -> Item {
        guard let r = s.range(of: "^\\[([0-9]{1,2}:[0-9]{2}(:[0-9]{2})?)\\]\\s*", options: .regularExpression) else {
            return Item(text: s.trimmingCharacters(in: .whitespaces))
        }
        let t = s[r].trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        return Item(t: t, text: String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces))
    }

    public static func parse(_ notes: String) -> Notes? {
        guard let lines = section(notes) else { return nil }
        var n = Notes()
        var cur = ""
        let keys = ["tl;dr": "tldr", "decisions": "decisions", "action items": "actions", "open questions": "open",
                    "topics": "topics", "unclear": "unclear"]
        for raw in lines {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.isEmpty { continue }
            if l.hasPrefix("### ") {
                var k = l.dropFirst(4).trimmingCharacters(in: .whitespaces).lowercased()
                if k.hasSuffix(":") { k = String(k.dropLast()) }
                cur = keys[k] ?? ""
                continue
            }
            if l.hasPrefix("#### "), cur == "topics" {
                var title = String(l.dropFirst(5)).trimmingCharacters(in: .whitespaces), t = ""
                if let r = title.range(of: "\\s*\\[([0-9]{1,2}:[0-9]{2}(:[0-9]{2})?)\\]\\s*$", options: .regularExpression) {
                    t = title[r].trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                    title = String(title[..<r.lowerBound])
                }
                n.topics.append(Topic(title: title, t: t))
                continue
            }
            let body = l.replacingOccurrences(of: "^[-*\u{2022}]\\s+", with: "", options: .regularExpression)
            let bullet = body != l
            switch cur {
            case "tldr": n.tldr = (n.tldr + " " + body).trimmingCharacters(in: .whitespaces)
            case "topics":
                guard !n.topics.isEmpty else { continue }
                if !bullet, let r = body.range(of: "^(\\*\\*)?(Outcome|Підсумок|Результат)(\\*\\*)?:\\s*(\\*\\*)?\\s*", options: [.regularExpression, .caseInsensitive]) {
                    n.topics[n.topics.count - 1].outcome = String(body[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                } else {
                    n.topics[n.topics.count - 1].points.append(item(body))
                }
            case "decisions": n.decisions.append(item(body))
            case "actions": n.actions.append(item(body))
            case "open": n.open.append(item(body))
            case "unclear": n.unclear.append(item(body))
            default: continue
            }
        }
        return n
    }

    /// The headings of the copied and exported text, in the interface language.
    public struct Labels {
        public var title, tldr, decisions, actions, open, topics, unclear: String
        public init(title: String, tldr: String, decisions: String, actions: String, open: String, topics: String, unclear: String) {
            self.title = title; self.tldr = tldr; self.decisions = decisions; self.actions = actions; self.open = open
            self.topics = topics; self.unclear = unclear
        }
    }

    /// Markdown for Copy and Export: "#" title (when given), "##" sections, "###" topics, "- " items with their time.
    public static func markdown(_ n: Notes, _ L: Labels, when: String = "", level: Int = 2) -> String {
        let h = String(repeating: "#", count: level) + " ", h3 = String(repeating: "#", count: level + 1) + " "
        func line(_ i: Item) -> String { "- " + (i.t.isEmpty ? "" : "[" + i.hhmm + "] ") + i.text }
        var md = L.title.isEmpty ? "" : String(repeating: "#", count: level - 1) + " " + L.title + "\n"
        if !when.isEmpty { md += "\n" + when + "\n" }
        if !n.tldr.isEmpty { md += "\n" + h + L.tldr + "\n\n" + n.tldr + "\n" }
        for (title, items) in [(L.decisions, n.decisions), (L.actions, n.actions), (L.open, n.open)] where !items.isEmpty {
            md += "\n" + h + title + "\n\n" + items.map(line).joined(separator: "\n") + "\n"
        }
        if !n.topics.isEmpty {
            md += "\n" + h + L.topics + "\n"
            for tp in n.topics {
                md += "\n" + h3 + tp.title + (tp.t.isEmpty ? "" : " [" + String(tp.t.prefix(5)) + "]") + "\n\n"
                if !tp.outcome.isEmpty { md += "*" + tp.outcome.replacingOccurrences(of: "*", with: "") + "*\n\n" }
                md += tp.points.map(line).joined(separator: "\n") + (tp.points.isEmpty ? "" : "\n")
            }
        }
        if !n.unclear.isEmpty { md += "\n" + h + L.unclear + "\n\n" + n.unclear.map { "- " + $0.text }.joined(separator: "\n") + "\n" }
        return md
    }
}
