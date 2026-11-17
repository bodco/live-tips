import Foundation

// 0.8.7 (H5, rules/sales.yaml > answer_cards): the answer cards file as a list for Settings > Projects and
// "Save as answer card". "## question or topic", the answer below, optional "Tags:" and "Use when:" lines.
// Text before the first card (a title, a hint) is kept as it is, so the file stays hand-editable.
public struct AnswerCard: Equatable, Identifiable {
    public var id = UUID()
    public var title: String
    public var answer: String
    public var tags: String
    public var useWhen: String
    /// S1 (rules/sales.yaml > answer_cards > fields): answer, competitor (a battlecard) or price (a price limit).
    /// "" keeps an older card as it was; a card with "Tags: competitor" reads as a competitor.
    public var type: String = ""
    public var theyWin: String = ""
    public var weWin: String = ""
    public var trap: String = ""
    public var limit: String = ""
    public static let types = ["answer", "competitor", "price"]
    public init(title: String, answer: String, tags: String = "", useWhen: String = "", type: String = "",
                theyWin: String = "", weWin: String = "", trap: String = "", limit: String = "") {
        self.title = title; self.answer = answer; self.tags = tags; self.useWhen = useWhen
        self.type = type; self.theyWin = theyWin; self.weWin = weWin; self.trap = trap; self.limit = limit
    }
    public static func == (a: AnswerCard, b: AnswerCard) -> Bool {
        a.title == b.title && a.answer == b.answer && a.tags == b.tags && a.useWhen == b.useWhen && a.type == b.type &&
            a.theyWin == b.theyWin && a.weWin == b.weWin && a.trap == b.trap && a.limit == b.limit
    }

    /// S1: the card's kind as the engine reads it (Type, else Tags: competitor, else a Limit line makes it a price card).
    public var kind: String {
        if Self.types.contains(type) { return type }
        if tags.lowercased().split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "competitor" }) { return "competitor" }
        return limit.trimmingCharacters(in: .whitespaces).isEmpty ? "answer" : "price"
    }

    /// The card as it is written to the file (no long dash, one line per field).
    public var markdown: String {
        func clean(_ s: String) -> String { s.replacingOccurrences(of: "\u{2014}", with: "-").trimmingCharacters(in: .whitespacesAndNewlines) }
        var out = "## " + clean(title).replacingOccurrences(of: "\n", with: " ") + "\n" + clean(answer) + "\n"
        if !clean(tags).isEmpty { out += "Tags: " + clean(tags).replacingOccurrences(of: "\n", with: " ") + "\n" }
        if !clean(useWhen).isEmpty { out += "Use when: " + clean(useWhen).replacingOccurrences(of: "\n", with: " ") + "\n" }
        // S1: Type only when set; the battlecard lines only on a competitor card, Limit only on a price card
        if Self.types.contains(type) { out += "Type: " + type + "\n" }
        let k = kind
        for (label, v, on) in [("They win", theyWin, "competitor"), ("We win", weWin, "competitor"), ("Trap", trap, "competitor"), ("Limit", limit, "price")]
            where k == on && !clean(v).isEmpty {
            out += label + ": " + clean(v).replacingOccurrences(of: "\n", with: " ") + "\n"
        }
        return out
    }
}

public enum AnswerCardsDoc {
    /// The text before the first card and the cards.
    public static func parse(_ text: String) -> (preamble: String, cards: [AnswerCard]) {
        var pre: [String] = [], cards: [AnswerCard] = []
        var cur: AnswerCard? = nil, body: [String] = []
        func close() {
            guard var c = cur else { return }
            c.answer = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            cards.append(c); cur = nil; body = []
        }
        for ln in text.components(separatedBy: "\n") {
            if ln.hasPrefix("## ") {
                close()
                cur = AnswerCard(title: String(ln.dropFirst(3)).trimmingCharacters(in: .whitespaces), answer: "")
            } else if cur != nil {
                let low = ln.trimmingCharacters(in: .whitespaces).lowercased()
                let val = ln.firstIndex(of: ":").map { String(ln[ln.index(after: $0)...]).trimmingCharacters(in: .whitespaces) } ?? ""
                if low.hasPrefix("tags:") { cur?.tags = val }
                else if low.hasPrefix("use when:") { cur?.useWhen = val }
                else if low.hasPrefix("type:") { cur?.type = AnswerCard.types.contains(val.lowercased()) ? val.lowercased() : "" }
                else if low.hasPrefix("they win:") { cur?.theyWin = val }
                else if low.hasPrefix("we win:") { cur?.weWin = val }
                else if low.hasPrefix("trap:") { cur?.trap = val }
                else if low.hasPrefix("limit:") { cur?.limit = val }
                else { body.append(ln) }
            } else {
                pre.append(ln)
            }
        }
        close()
        return (pre.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), cards)
    }

    public static func render(preamble: String, cards: [AnswerCard]) -> String {
        var parts: [String] = []
        if !preamble.isEmpty { parts.append(preamble + "\n") }
        parts += cards.map(\.markdown)
        return parts.joined(separator: "\n")
    }

    /// Appends one card to the file's text without touching what is above it.
    public static func append(_ card: AnswerCard, to text: String) -> String {
        let base = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (base.isEmpty ? "# Answer cards\n" : base + "\n") + "\n" + card.markdown
    }
}
