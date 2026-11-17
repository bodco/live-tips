import Foundation

/// 0.17.0 (server 0.7.0, D40, B6b contract 9 block 3, spec 3): the shared card of an organization project. Everyone on
/// the project edits it (`PATCH .../card` with `If-Match`, 428 without it, 409 when someone saved a newer version);
/// owner and admin only read. The Mac keeps its own card (Project.about, client, goal, glossary) for the prep: until
/// SEC-01 is checked live the prep never reads the shared card. The Meeting Sheet says when someone else changed the
/// card after my last prep ("Project card changed by Emily since your last prep"), so a swapped instruction shows.
/// Pure rules here (CoreChecks); the network and the views are in the app (OrgCardViews.swift).
public enum OrgCard {
    public struct Person: Equatable {
        public var name: String, role: String, side: String, note: String
        public init(name: String, role: String = "", side: String = "client", note: String = "") {
            self.name = name; self.role = role; self.side = side; self.note = note
        }
    }

    public struct Term: Equatable {
        public var term: String, note: String
        public init(term: String, note: String = "") { self.term = term; self.note = note }
    }

    public struct Card: Equatable {
        public var description = "", goal = "", clientName = "", clientSite = ""
        public var people: [Person] = []
        public var glossary: [Term] = []
        public var rules: [String] = []
        public var languages: [String] = []
        public var audience = ""
        public init() {}
        public var isEmpty: Bool { self == Card() }
    }

    public struct Member: Equatable, Identifiable {
        public var id: String, name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }

    /// `GET /v1/orgs/{org}/projects/{id}` (and the PATCH answer).
    public struct Shared: Equatable {
        public var id = "", orgID = "", name = ""
        public var archived = false
        public var card = Card()
        public var version = "0"
        public var updatedByID = "", updatedByName = ""
        public var updatedAt: Date?
        public var members: [Member] = []
        public var changed: [String] = []
        public init() {}
    }

    /// The server's limits (openapi 0.7.0, ProjectCard).
    public static let limits = (description: 2000, goal: 1000, people: 50, glossary: 300, rules: 50, rule: 500, languages: 10)
    public static let fields = ["description", "goal", "client", "people", "glossary", "rules", "languages", "audience"]

    static func date(_ s: Any?) -> Date? {
        guard let s = s as? String else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    public static func parse(_ d: Data) -> Shared? {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let id = o["id"] as? String else { return nil }
        var v = Shared()
        v.id = id; v.orgID = (o["org_id"] as? String) ?? ""; v.name = (o["name"] as? String) ?? ""
        v.archived = (o["archived"] as? Bool) == true
        let k = (o["card"] as? [String: Any]) ?? [:]
        func s(_ x: Any?) -> String { (x as? String) ?? "" }
        v.card.description = s(k["description"]); v.card.goal = s(k["goal"]); v.card.audience = s(k["audience"])
        let cl = (k["client"] as? [String: Any]) ?? [:]
        v.card.clientName = s(cl["name"]); v.card.clientSite = s(cl["site"])
        v.card.people = ((k["people"] as? [[String: Any]]) ?? []).compactMap { p in
            let n = s(p["name"]); return n.isEmpty ? nil : Person(name: n, role: s(p["role"]), side: s(p["side"]).isEmpty ? "client" : s(p["side"]), note: s(p["note"]))
        }
        v.card.glossary = ((k["glossary"] as? [[String: Any]]) ?? []).compactMap { g in
            let t = s(g["term"]); return t.isEmpty ? nil : Term(term: t, note: s(g["note"]))
        }
        v.card.rules = ((k["rules"] as? [Any]) ?? []).compactMap { $0 as? String }
        v.card.languages = ((k["languages"] as? [Any]) ?? []).compactMap { $0 as? String }
        v.version = (k["version"] as? String) ?? ((k["version"] as? Int).map(String.init) ?? "0")
        let by = (k["updated_by"] as? [String: Any]) ?? [:]
        v.updatedByID = s(by["id"]).lowercased(); v.updatedByName = s(by["name"])
        v.updatedAt = date(k["updated_at"])
        v.members = ((o["people"] as? [[String: Any]]) ?? []).compactMap { p in
            guard let u = p["user_id"] as? String else { return nil }
            return Member(id: u.lowercased(), name: s(p["name"]))
        }
        v.changed = ((o["changed"] as? [Any]) ?? []).compactMap { $0 as? String }
        return v
    }

    static func value(_ c: Card, _ field: String) -> Any {
        switch field {
        case "description": return String(c.description.prefix(limits.description))
        case "goal": return String(c.goal.prefix(limits.goal))
        case "client": return ["name": String(c.clientName.prefix(200)), "site": String(c.clientSite.prefix(300))]
        case "people": return c.people.prefix(limits.people).map {
            ["name": String($0.name.prefix(200)), "role": String($0.role.prefix(200)),
             "side": ["client", "team", "other"].contains($0.side) ? $0.side : "client", "note": String($0.note.prefix(300))] }
        case "glossary": return c.glossary.prefix(limits.glossary).map { ["term": String($0.term.prefix(100)), "note": String($0.note.prefix(300))] }
        case "rules": return c.rules.prefix(limits.rules).map { String($0.prefix(limits.rule)) }
        case "languages": return Array(c.languages.prefix(limits.languages))
        default: return String(c.audience.prefix(50))
        }
    }

    static func same(_ a: Card, _ b: Card, _ field: String) -> Bool {
        (try? JSONSerialization.data(withJSONObject: ["v": value(a, field)], options: .sortedKeys)) ==
            (try? JSONSerialization.data(withJSONObject: ["v": value(b, field)], options: .sortedKeys))
    }

    /// The fields I changed against the card I started from.
    public static func edited(base: Card, draft: Card) -> [String] { fields.filter { !same(base, draft, $0) } }

    /// The PATCH body: only the fields I changed (the server writes one history row per field).
    public static func patch(base: Card, draft: Card) -> [String: Any] {
        var o: [String: Any] = [:]
        for f in edited(base: base, draft: draft) { o[f] = value(draft, f) }
        return o
    }

    /// After a 409: my edits on top of the newer card, field by field (the last writer wins per field, nothing is lost
    /// silently). `conflicts`: the fields both of us changed to different values; mine are kept, the view says so.
    public static func rebase(base: Card, draft: Card, server: Card) -> (card: Card, conflicts: [String]) {
        var out = server, conflicts: [String] = []
        for f in edited(base: base, draft: draft) {
            if !same(base, server, f) && !same(server, draft, f) { conflicts.append(f) }
            switch f {
            case "description": out.description = draft.description
            case "goal": out.goal = draft.goal
            case "client": out.clientName = draft.clientName; out.clientSite = draft.clientSite
            case "people": out.people = draft.people
            case "glossary": out.glossary = draft.glossary
            case "rules": out.rules = draft.rules
            case "languages": out.languages = draft.languages
            default: out.audience = draft.audience
            }
        }
        return (out, conflicts)
    }

    /// What a PATCH answer means.
    public enum Outcome: Equatable { case saved, newer, readOnly, gone, plan, invalid(String), failed(String) }
    public static func outcome(status: Int, problem: String = "") -> Outcome {
        switch status {
        case 200: return .saved
        case 409, 428: return .newer             // 428 only when the version was not known: read it again
        case 403: return problem == "plan" ? .plan : .readOnly      // 0.18.0: 403 `type: plan` (server 0.9.0)
        case 404: return .gone
        case 402: return .plan
        case 422: return .invalid(problem)
        default: return .failed(problem.isEmpty ? "HTTP \(status)" : problem)
        }
    }

    /// The If-Match header: the card version from the ETag (quoted).
    public static func ifMatch(_ version: String) -> String { "\"" + version.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) + "\"" }

    /// "Project card changed by Emily since your last prep": the name when someone else changed the card after my
    /// last prep of this project; nil when I changed it, nobody did, or I never prepared it.
    public static func changedSincePrep(_ v: Shared, lastPrep: Date?, me: String) -> String? {
        guard let p = lastPrep, let at = v.updatedAt, at > p, !v.updatedByID.isEmpty, v.updatedByID != me.lowercased() else { return nil }
        return v.updatedByName.isEmpty ? "?" : v.updatedByName
    }

    // MARK: text forms for the editor

    /// "Mike | CTO | client | decides", one person a line.
    public static func peopleText(_ p: [Person]) -> String {
        p.map { [$0.name, $0.role, $0.side, $0.note].joined(separator: " | ").replacingOccurrences(of: "( \\| )+$", with: "", options: .regularExpression) }
            .joined(separator: "\n")
    }
    public static func people(_ text: String) -> [Person] {
        lines(text).compactMap { l in
            let c = l.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let n = c.first, !n.isEmpty else { return nil }
            let side = c.count > 2 && ["client", "team", "other"].contains(c[2].lowercased()) ? c[2].lowercased() : "client"
            let note = c.count > 3 ? c[3...].joined(separator: " | ") : (c.count > 2 && side != c[2].lowercased() ? c[2] : "")
            return Person(name: n, role: c.count > 1 ? c[1] : "", side: side, note: note)
        }
    }

    /// "Term: note", one a line.
    public static func glossaryText(_ g: [Term]) -> String { g.map { $0.note.isEmpty ? $0.term : $0.term + ": " + $0.note }.joined(separator: "\n") }
    public static func glossary(_ text: String) -> [Term] {
        lines(text).map { l in
            guard let r = l.range(of: ":") else { return Term(term: l) }
            return Term(term: l[..<r.lowerBound].trimmingCharacters(in: .whitespaces), note: l[r.upperBound...].trimmingCharacters(in: .whitespaces))
        }
        .filter { !$0.term.isEmpty }
    }

    public static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// "en, uk" -> ["en", "uk"]: short codes only, each once.
    public static func languages(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map { $0.lowercased() }
            .filter { $0.range(of: "^[a-z]{2,3}(-[a-z0-9]{2,8})?$", options: .regularExpression) != nil && seen.insert($0).inserted }
    }

    /// The Mac's card as a start for an empty shared one ("Copy from this Mac"): only what the shared card has room for.
    public static func fromLocal(about: String, client: String, goal: String, glossary: [String], languages: [String]) -> Card {
        var c = Card()
        c.description = about; c.goal = goal; c.clientName = client
        c.glossary = glossary.map { Term(term: $0) }
        c.languages = languages.filter { !$0.isEmpty }
        return c
    }
}
