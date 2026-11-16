import Foundation

/// 0.17.0 (server 0.7.0, D40, B6b contract 9, block 2): a colleague's change comes back to the author's Mac. Someone on
/// the organization project changed a task's status, owner or due date (or a decision's or risk's status) in the
/// project registers; the server raised the call's `updated_at`, so the call shows up in the author's `GET /v1/sync`.
/// The Mac reads the call again (`GET /v1/calls/{id}`) and takes every item whose rev is newer than the one it last
/// saw: tasks into the commitments register (so the call page, Home and the next PUT agree with the server), decisions
/// and risks into the sync state (the Mac keeps no status for them; the next PUT sends the colleague's back).
/// Pure rules here (CoreChecks); the network is in CallSyncService.
public extension CallSync {
    /// One call in a `/v1/sync` answer.
    struct ChangedCall: Equatable {
        public var id: String
        public var ownerID: String
        public var version: String
        public init(id: String, ownerID: String, version: String = "") { self.id = id; self.ownerID = ownerID; self.version = version }
    }

    struct SyncPage: Equatable {
        public var changed: [ChangedCall]
        public var deleted: [String]
        public var cursor: String
        public var more: Bool
        public init(changed: [ChangedCall], deleted: [String], cursor: String, more: Bool) {
            self.changed = changed; self.deleted = deleted; self.cursor = cursor; self.more = more
        }
    }

    /// `{"changed": [CallListItem], "deleted": [uuid], "cursor", "more"}`; nil when it is not that.
    static func syncPage(_ d: Data) -> SyncPage? {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let cur = o["cursor"] as? String else { return nil }
        let ch = ((o["changed"] as? [[String: Any]]) ?? []).compactMap { c -> ChangedCall? in
            guard let id = c["id"] as? String else { return nil }
            return ChangedCall(id: id.lowercased(), ownerID: ((c["owner_id"] as? String) ?? "").lowercased(), version: (c["version"] as? String) ?? "")
        }
        let del = ((o["deleted"] as? [String]) ?? []).map { $0.lowercased() }
        return SyncPage(changed: ch, deleted: del, cursor: cur, more: (o["more"] as? Bool) == true)
    }

    /// GET /v1/sync in an organization ("" the personal one) from a cursor ("" from the start).
    static func syncPath(orgID: String, cursor: String) -> String {
        var q: [String] = []
        let o = orgQuery(orgID)
        if !o.isEmpty { q.append(String(o.dropFirst())) }
        if !cursor.isEmpty {
            var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-_.~")
            q.append("since=" + (cursor.addingPercentEncoding(withAllowedCharacters: allowed) ?? cursor))
        }
        return "/v1/sync" + (q.isEmpty ? "" : "?" + q.joined(separator: "&"))
    }

    /// The calls of a sync page worth reading again: mine (a colleague never syncs my call) and known on this Mac.
    static func toRead(_ page: SyncPage, me userID: String, known: Set<String>) -> [String] {
        var seen = Set<String>()
        return page.changed.filter { !userID.isEmpty && $0.ownerID == userID.lowercased() && known.contains($0.id) && seen.insert($0.id).inserted }
            .map(\.id)
    }

    /// An item as `GET /v1/calls/{id}` gives it (0.7.0).
    struct RemoteItem: Equatable {
        public var id: String
        public var rev: Int
        public var status: String
        public var assignee: String
        public var due: String              // "yyyy-MM-dd" or ""
        public var ownerUserID: String
        public var editedBy: String
        public init(id: String, rev: Int, status: String, assignee: String = "", due: String = "", ownerUserID: String = "", editedBy: String = "") {
            self.id = id; self.rev = rev; self.status = status; self.assignee = assignee; self.due = due
            self.ownerUserID = ownerUserID; self.editedBy = editedBy
        }
    }

    static func remoteItems(_ call: [String: Any], part: String) -> [RemoteItem] {
        ((call[part] as? [[String: Any]]) ?? []).compactMap { i in
            guard let id = i["id"] as? String, let rev = i["rev"] as? Int else { return nil }
            return RemoteItem(id: id.lowercased(), rev: rev, status: (i["status"] as? String) ?? "",
                              assignee: (i["assignee"] as? String) ?? "", due: String(((i["due_date"] as? String) ?? "").prefix(10)),
                              ownerUserID: ((i["owner_user_id"] as? String) ?? "").lowercased(), editedBy: ((i["edited_by"] as? String) ?? "").lowercased())
        }
    }

    /// A newer item: its local key, and what the server has now.
    struct ItemChange: Equatable {
        public var part: String
        public var key: String
        public var item: RemoteItem
        public init(part: String, key: String, item: RemoteItem) { self.part = part; self.key = key; self.item = item }
    }

    /// Items this Mac knows (by id) whose server rev is newer than the rev it last saw. An item the Mac never sent (a
    /// second Mac's) and an item a lead deleted (missing from the answer) change nothing here.
    static func newer(_ remote: [RemoteItem], part: String, state: State) -> [ItemChange] {
        let byID = Dictionary((state.items[part] ?? [:]).map { ($0.value.id.lowercased(), $0.key) }, uniquingKeysWith: { a, _ in a })
        return remote.compactMap { r in
            guard let key = byID[r.id], let ref = state.items[part]?[key], r.rev > (ref.rev ?? 0) else { return nil }
            return ItemChange(part: part, key: key, item: r)
        }
    }

    /// A task the server gives to me: my user id as its owner, or one of my names as its assignee.
    static func givenToMe(_ r: RemoteItem, me: String, myNames: [String]) -> Bool {
        let names = Set(myNames.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
        return (!me.isEmpty && r.ownerUserID == me.lowercased()) || names.contains(r.assignee.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Takes the newer revs into the state. A decision's or risk's status is kept (sent back by the next PUT); a task
    /// given to me keeps the server's name for me. `me`: my user id; `myNames`: the names the server may use for me.
    static func adopt(_ changes: [ItemChange], me: String, myNames: [String] = [], state: inout State) {
        for c in changes {
            guard var ref = state.items[c.part]?[c.key] else { continue }
            ref.rev = c.item.rev
            if c.part != "tasks" { ref.status = c.item.status.isEmpty ? nil : c.item.status }
            if c.part == "tasks" {
                let a = c.item.assignee.trimmingCharacters(in: .whitespaces)
                ref.assignee = givenToMe(c.item, me: me, myNames: myNames) && !a.isEmpty ? a : nil
            }
            state.items[c.part]?[c.key] = ref
        }
    }

    /// The task rows' keys and their register items, the way `withIDs` keys them ("#2" for the same text twice).
    static func taskKeys(_ rows: [[String: Any]]) -> [String: String] {
        var seen: [String: Int] = [:], out: [String: String] = [:]
        for r in rows {
            let base = itemKey(r["text"] as? String ?? "")
            seen[base, default: 0] += 1
            let key = seen[base]! > 1 ? base + "#\(seen[base]!)" : base
            if let cid = r["_cid"] as? String, !cid.isEmpty { out[key] = cid }
        }
        return out
    }

    /// The register events that bring one item to the server's status, owner and due date; none when they already
    /// agree. `me`: my user id; `myNames`: the names the server may use for me (the account name, my aliases).
    static func taskEvents(_ c: Commitment, server r: RemoteItem, me: String, myNames: [String], at: String) -> [[String: Any]] {
        var ev: [[String: Any]] = []
        switch r.status {
        case "done" where c.status != "done": ev.append(["op": "done", "id": c.id, "at": at, "source": "server"])
        case "dropped" where c.status != "dropped": ev.append(["op": "drop", "id": c.id, "at": at])
        case "open" where c.status != "open": ev.append(["op": "reopen", "id": c.id, "at": at])
        default: break
        }
        var edit: [String: Any] = [:]
        if givenToMe(r, me: me, myNames: myNames) {
            if !c.mine { edit["owner"] = "me" }
        } else if !r.assignee.trimmingCharacters(in: .whitespaces).isEmpty,
                  c.mine || c.owner.lowercased() != r.assignee.trimmingCharacters(in: .whitespaces).lowercased() {
            edit["owner"] = r.assignee.trimmingCharacters(in: .whitespaces)
        }
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let local = CommitmentRegister.dueDate(c.due, from: c.createdDate ?? Date()).map { f.string(from: $0) } ?? ""
        if !r.due.isEmpty, r.due != local { edit["due"] = r.due }
        if r.due.isEmpty, !local.isEmpty { edit["due"] = "" }       // a text that reads as no day ("next sprint") stays
        if !edit.isEmpty { ev.append(["op": "edit", "id": c.id, "at": at].merging(edit) { a, _ in a }) }
        return ev
    }
}

public extension CommitmentRegister {
    /// 0.17.0 (block 2): a call whose tasks still come from its notes takes them into the register first (all at once,
    /// full text, `by: sync`), so a colleague's change has an item to land on and the call page shows it.
    static func adoptAllEvents(_ tasks: [CallLists.Task], project: String, title: String, call: String, them: String, at: String) -> [[String: Any]] {
        var seen = Set<String>()
        return tasks.compactMap { t in
            let text = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !MeetingNotes.isNothing(text) else { return nil }
            let owner = legacyOwner(t, them: them)
            let id = makeID(call: call, owner: owner, text: text)
            guard seen.insert(id).inserted else { return nil }
            return ["op": "add", "id": id, "text": String(text.prefix(2000)), "owner": owner, "project": project,
                    "series": seriesKey(project: project, title: title), "call": (call as NSString).lastPathComponent,
                    "t": t.t, "created": at, "due": t.due, "by": "sync"]
        }
    }
}
