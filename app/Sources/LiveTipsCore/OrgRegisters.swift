import Foundation

/// 0.17.0 (server 0.7.0, D40, B6b contract 9 block 4, spec 4.1): the registers of an organization project. Everyone
/// on the project reads the decisions, tasks and risks of the not private calls linked to it; the call itself stays
/// with its author (D37): `call_id` comes only to those who see the call. Who changes what (D40.5): a task's status,
/// owner and due date its owner, the call's author and the author's team lead; a decision's or risk's status the author
/// and the lead; deleting the author and the lead. The server says it per item (`can_edit`, `can_delete`), the app
/// does not guess. My own items stay where they were (this Mac's register, the Notion mirror): the Tracker adds only
/// my colleagues' items. Pure rules here (CoreChecks); the network and the rows are in the app (OrgRegisterViews.swift).
public enum OrgRegister {
    public enum Kind: String, CaseIterable { case decision, task, risk }

    public struct Item: Equatable, Identifiable {
        public var kind: Kind
        public var id: String
        public var text: String
        public var who: String               // made_by, said_by or assignee
        public var status: String
        public var rev: Int
        public var editedBy: String = ""
        public var editedAt: Date?
        public var callID: String?           // nil when the call is not mine to see
        public var callDate: Date?
        public var authorID: String = ""
        public var authorName: String = ""
        public var mine = false              // from my own call
        public var canEdit = false
        public var canDelete = false
        public var due: String = ""          // "yyyy-MM-dd" or ""
        public var ownerUserID: String = ""
        public init(kind: Kind, id: String, text: String, who: String = "", status: String, rev: Int = 1) {
            self.kind = kind; self.id = id; self.text = text; self.who = who; self.status = status; self.rev = rev
        }
    }

    /// The statuses the server takes (context.STATUSES), in menu order.
    public static func statuses(_ k: Kind) -> [String] {
        switch k {
        case .decision: return ["made", "proposed", "reverted"]
        case .task: return ["open", "done", "dropped"]
        case .risk: return ["open", "closed"]
        }
    }

    /// Not active any more: hidden under the Tracker's Open filter.
    public static func closed(_ i: Item) -> Bool { ["done", "dropped", "reverted", "closed"].contains(i.status) }

    public static func base(org: String, project: String) -> String { "/v1/orgs/\(org)/projects/\(project)" }

    /// GET .../registers, all kinds unless one is asked.
    public static func listPath(org: String, project: String, kind: Kind? = nil, status: String = "", since: Date? = nil) -> String {
        var q: [String] = []
        if let k = kind { q.append("kind=" + k.rawValue) }
        if !status.isEmpty { q.append("status=" + status) }
        if let s = since {
            var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-_.~")
            q.append("since=" + (ISO8601DateFormatter().string(from: s).addingPercentEncoding(withAllowedCharacters: allowed) ?? ""))
        }
        return base(org: org, project: project) + "/registers" + (q.isEmpty ? "" : "?" + q.joined(separator: "&"))
    }

    public static func itemPath(org: String, project: String, _ i: Item) -> String {
        base(org: org, project: project) + "/registers/\(i.kind.rawValue)/\(i.id)"
    }

    static func date(_ s: Any?) -> Date? {
        guard let s = s as? String else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    /// The GET answer; nil when it is not a list. Items without a kind, id or text are dropped.
    public static func parse(_ d: Data) -> [Item]? {
        guard let a = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return nil }
        func s(_ x: Any?) -> String { (x as? String) ?? "" }
        return a.compactMap { o in
            guard let k = Kind(rawValue: s(o["kind"])), let id = o["id"] as? String, let text = o["text"] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let who = k == .decision ? s(o["made_by"]) : k == .risk ? s(o["said_by"]) : s(o["assignee"])
            var i = Item(kind: k, id: id.lowercased(), text: text, who: who, status: s(o["status"]), rev: (o["rev"] as? Int) ?? 0)
            i.editedBy = s(o["edited_by"]).lowercased(); i.editedAt = date(o["edited_at"])
            i.callID = (o["call_id"] as? String).map { $0.lowercased() }
            i.callDate = date(o["call_date"])
            let a = (o["call_author"] as? [String: Any]) ?? [:]
            i.authorID = s(a["id"]).lowercased(); i.authorName = s(a["name"])
            i.mine = (o["mine"] as? Bool) == true
            i.canEdit = (o["can_edit"] as? Bool) == true
            i.canDelete = (o["can_delete"] as? Bool) == true
            i.due = String(s(o["due_date"]).prefix(10))
            i.ownerUserID = s(o["owner_user_id"]).lowercased()
            return i
        }
    }

    /// What the Tracker adds: my colleagues' items (mine are already there from this Mac), newest calls first.
    public static func fromColleagues(_ items: [Item]) -> [Item] { items.filter { !$0.mine } }

    /// A task given to me (by my user id); a decision or risk is never "mine" for the owner filter.
    public static func givenToMe(_ i: Item, me: String) -> Bool { i.kind == .task && !me.isEmpty && i.ownerUserID == me.lowercased() }

    /// "Nov 12" / "12 лист." for "from Mike's call, Nov 12".
    public static func callDay(_ i: Item, lang: String) -> String {
        guard let d = i.callDate else { return "" }
        let f = DateFormatter(); f.locale = Locale(identifier: lang == "uk" ? "uk_UA" : "en_US"); f.setLocalizedDateFormatFromTemplate("MMMd")
        return f.string(from: d)
    }

    /// One change from the register row. `due`: nil leaves it, "" clears it, "yyyy-MM-dd" sets it; `owner` the same with
    /// a user id. Decisions and risks take only the status (the server answers 422 otherwise).
    public struct Change: Equatable {
        public var status: String?
        public var due: String?
        public var owner: String?
        public init(status: String? = nil, due: String? = nil, owner: String? = nil) { self.status = status; self.due = due; self.owner = owner }
    }

    /// The PATCH body: only what changes against the item; empty when nothing does (no request then).
    public static func patch(_ i: Item, _ c: Change) -> [String: Any] {
        var o: [String: Any] = [:]
        if let s = c.status, s != i.status, statuses(i.kind).contains(s) { o["status"] = s }
        guard i.kind == .task else { return o }
        if let d = c.due, d != i.due {
            if d.isEmpty { o["due_date"] = NSNull() }
            else if d.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil { o["due_date"] = d }
        }
        if let u = c.owner?.lowercased(), u != i.ownerUserID { o["owner_user_id"] = u.isEmpty ? NSNull() : u }
        return o
    }

    /// The If-Match header: the item's rev (quoted).
    public static func ifMatch(_ i: Item) -> String { "\"\(i.rev)\"" }

    /// The item after a saved PATCH (`{"kind", "id", "rev", "changed"}`), so the row shows it before the list is read
    /// again. `ownerName`: the new owner's name on the project (the server writes it into `assignee`).
    public static func applied(_ i: Item, _ c: Change, answer: Data, me: String, ownerName: String = "") -> Item {
        var n = i
        let o = ((try? JSONSerialization.jsonObject(with: answer)) as? [String: Any]) ?? [:]
        if let r = o["rev"] as? Int { n.rev = r }
        let changed = Set(((o["changed"] as? [Any]) ?? []).compactMap { $0 as? String })
        if changed.contains("status"), let s = c.status { n.status = s }
        if changed.contains("due_date"), let d = c.due { n.due = d }
        if changed.contains("owner_user_id"), let u = c.owner { n.ownerUserID = u.lowercased(); n.who = u.isEmpty ? "" : ownerName }
        if !changed.isEmpty { n.editedBy = me.lowercased(); n.editedAt = Date() }
        return n
    }

    /// What a PATCH or DELETE answer means (the card's outcomes; 204 is a delete).
    public static func outcome(status: Int, problem: String = "") -> OrgCard.Outcome {
        status == 204 ? .saved : OrgCard.outcome(status: status, problem: problem)
    }

    /// The name for a user id among the project's people; "" when unknown.
    public static func name(_ userID: String, members: [OrgCard.Member]) -> String {
        members.first { $0.id == userID.lowercased() }?.name ?? ""
    }

    /// "changed by Emily" under the row: someone other than the author changed it (status, owner, due date).
    public static func editedByOther(_ i: Item, members: [OrgCard.Member]) -> String? {
        guard !i.editedBy.isEmpty, i.editedBy != i.authorID else { return nil }
        let n = name(i.editedBy, members: members)
        return n.isEmpty ? "?" : n
    }
}
