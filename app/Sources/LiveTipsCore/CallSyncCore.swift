import CryptoKit
import Foundation

/// 0.12.0 (B8b, server ADR 8 and 9): what a call sends to the Pacenote server and how the Mac remembers it.
/// Only what D27 allows: metadata, the call notes as the summary, decisions, tasks, the Meeting Sheet and Drive links;
/// since 0.13.0 the consent record and the call's numbers. Never audio, video, the transcript, speaker names from the
/// transcript, participants' emails or tip texts. The Mac stays the source of
/// truth: every request replaces the server's copy, and a part is sent again only when its body changed.
/// Off by default: a project sends nothing until its "Sync to Pacenote server" is on (owner, 2026-11-15).
public enum CallSync {
    /// <stem>.sync.json next to the transcript.
    public struct State: Codable, Equatable {
        public var schema = 1
        public var callID = ""              // the server's id of the call
        public var clientCallID = ""
        public var version = ""             // the call row's version (ETag)
        public var hashes: [String: String] = [:]   // part ("call", "summary", ...) -> hash of the body last accepted
        public var meta: [String: String] = [:]     // call_type, audience, language: kept when the call ends
        public var skip = false             // Don't sync this call
        public var deletedElsewhere = false // the server answered 410: deleted on another device, never re-sent by itself
        public var removed = false          // 0.12.1: "Delete from server" on this Mac; never re-sent (the server keeps a tombstone)
        public var error = ""
        public var syncedAt: Date?
        /// 0.17.0 (B6b, D36): the organization the call belongs to on the server ("" before 0.17.0: the personal one).
        public var orgID = ""
        /// 0.17.0 (D36): the PM marked the call private (a manager sees only that it happened and how long); and
        /// whether the server has it private (a private call stays private when the organization turns them off).
        public var isPrivate = false
        public var serverPrivate = false
        /// 0.17.0 (server 0.7.0, D40): decisions, tasks, risks -> item key (CallSync.itemKey) -> the item's stable id and
        /// the rev the server last answered. Sent with every PUT so a colleague's change in the project registers survives.
        public var items: [String: [String: ItemRef]] = [:]
        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func s(_ k: CodingKeys) -> String { (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil ?? "" }
            schema = (try? c.decodeIfPresent(Int.self, forKey: .schema)) ?? nil ?? 1
            callID = s(.callID); clientCallID = s(.clientCallID); version = s(.version); error = s(.error)
            hashes = (try? c.decodeIfPresent([String: String].self, forKey: .hashes)) ?? nil ?? [:]
            meta = (try? c.decodeIfPresent([String: String].self, forKey: .meta)) ?? nil ?? [:]
            skip = (try? c.decodeIfPresent(Bool.self, forKey: .skip)) ?? nil ?? false
            deletedElsewhere = (try? c.decodeIfPresent(Bool.self, forKey: .deletedElsewhere)) ?? nil ?? false
            removed = (try? c.decodeIfPresent(Bool.self, forKey: .removed)) ?? nil ?? false
            syncedAt = (try? c.decodeIfPresent(Date.self, forKey: .syncedAt)) ?? nil
            orgID = s(.orgID)
            isPrivate = (try? c.decodeIfPresent(Bool.self, forKey: .isPrivate)) ?? nil ?? false
            serverPrivate = (try? c.decodeIfPresent(Bool.self, forKey: .serverPrivate)) ?? nil ?? false
            items = (try? c.decodeIfPresent([String: [String: ItemRef]].self, forKey: .items)) ?? nil ?? [:]
        }

        public static func load(_ path: String) -> State? {
            guard let d = FileManager.default.contents(atPath: path) else { return nil }
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            return try? dec.decode(State.self, from: d)
        }

        public func save(_ path: String) {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
            if let d = try? enc.encode(self) { try? d.write(to: URL(fileURLWithPath: path), options: .atomic) }
        }
    }

    /// 0.17.0 (server 0.7.0, D40): an item's id on the server (a UUID made on this Mac) and the last rev it answered.
    public struct ItemRef: Codable, Equatable {
        public var id: String
        public var rev: Int?
        /// 0.17.0 (contract 9, block 2): what a colleague set in the project registers, kept so the next PUT sends it
        /// back instead of the app's default: a decision's or risk's status (the Mac keeps none), and the server's name
        /// for me on a task given to me (so `owner_user_id` survives). nil when nobody changed them.
        public var status: String?
        public var assignee: String?
        public init(id: String, rev: Int? = nil, status: String? = nil, assignee: String? = nil) {
            self.id = id; self.rev = rev; self.status = status; self.assignee = assignee
        }
    }

    /// The parts whose items carry a stable id and rev (B6b contract 9).
    public static let itemParts: Set<String> = ["decisions", "tasks", "risks"]

    /// The key that finds an item's id again: its text, case and spacing ignored. An edited text is a new item.
    public static func itemKey(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// The rows with their stable `id` (known ones kept, new ones get a fresh UUID); the same text twice gets "#2".
    /// The body without revs decides whether the part changed, so a new rev alone never sends it again.
    public static func withIDs(_ rows: [[String: Any]], part: String, state: State,
                               newID: () -> String = { UUID().uuidString.lowercased() }) -> [[String: Any]] {
        let known = state.items[part] ?? [:]
        var seen: [String: Int] = [:]
        return rows.map { r in
            var o = r
            let base = itemKey(r["text"] as? String ?? "")
            seen[base, default: 0] += 1
            let key = seen[base]! > 1 ? base + "#\(seen[base]!)" : base
            o["id"] = known[key]?.id ?? newID()
            o["_key"] = key
            return o
        }
    }

    /// What goes to the server: the rows with ids and the rev last seen (B6b contract 9), without the local key.
    public static func withRevs(_ rows: [[String: Any]], part: String, state: State) -> [[String: Any]] {
        let known = state.items[part] ?? [:]
        return rows.map { r in
            let key = r["_key"] as? String ?? ""
            let mine = (r["_mine"] as? Bool) == true
            var o = stripKeys([r])[0]
            if let rev = known[key]?.rev, rev >= 1 { o["rev"] = rev }
            // 0.17.0 (block 2): a colleague's status of a decision or risk goes back as it is (the Mac keeps none), and
            // a task given to me keeps the server's name for me
            if part != "tasks", let st = known[key]?.status, !st.isEmpty { o["status"] = st }
            if part == "tasks", mine, let a = known[key]?.assignee, !a.isEmpty { o["assignee"] = a }
            return o
        }
    }

    /// The rows without the local keys ("_key", "_cid", "_mine"), for the change hash.
    public static func stripKeys(_ rows: [[String: Any]]) -> [[String: Any]] {
        rows.map { $0.filter { !$0.key.hasPrefix("_") } }
    }

    /// After a 200: remember each sent item's id and the rev in the answer `{"count", "items": [{"id", "rev"}]}`.
    /// An item missing from the answer (a lead deleted it in the registers) keeps its id, so the server keeps skipping
    /// it; a server before 0.7.0 answers without items and the ids stay without a rev. Items no longer sent are dropped.
    public static func rememberItems(_ rows: [[String: Any]], part: String, response: Data, state: inout State) {
        let o = (try? JSONSerialization.jsonObject(with: response)) as? [String: Any] ?? [:]
        var revs: [String: Int] = [:]
        for i in (o["items"] as? [[String: Any]]) ?? [] {
            if let id = (i["id"] as? String)?.lowercased(), let r = i["rev"] as? Int { revs[id] = r }
        }
        let old = state.items[part] ?? [:]
        var next: [String: ItemRef] = [:]
        for r in rows {
            guard let key = r["_key"] as? String, let id = r["id"] as? String else { continue }
            let same = old[key]?.id == id
            next[key] = ItemRef(id: id, rev: revs[id.lowercased()] ?? (same ? old[key]?.rev : nil),
                                status: same ? old[key]?.status : nil, assignee: same ? old[key]?.assignee : nil)
        }
        state.items[part] = next.isEmpty ? nil : next
    }

    public static func stem(_ transcript: String) -> String { transcript.hasSuffix(".md") ? String(transcript.dropLast(3)) : transcript }
    public static func statePath(transcript t: String) -> String { stem(t) + ".sync.json" }
    public static func sheetPath(transcript t: String) -> String { stem(t) + ".sheet.json" }

    /// "<device>-<file stem>": the same call from two Macs stays two calls, a repeat from one Mac stays one.
    public static func clientCallID(device: String, transcript: String) -> String {
        let base = ((stem(transcript) as NSString).lastPathComponent)
        let raw = device.prefix(36) + "-" + base
        let clean = raw.unicodeScalars.map { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "._-".unicodeScalars.contains($0) ? Character($0) : "_" }
        return String(String(clean).prefix(200))
    }

    /// A project's local slug as the server takes it (letters, digits, dot, dash, underscore).
    public static func localSlug(_ slug: String) -> String {
        let s = String(slug.unicodeScalars.map { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) ? Character($0) : "-" })
        return String((s.isEmpty ? "project" : s).prefix(100))
    }

    public static func json(_ o: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    public static func hash(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()

    /// PUT /v1/calls/{client_call_id}. 0.13.0: with the consent record and the call's numbers. No participants: their
    /// names wait for the lawyer (owner 15.11) and their emails are never sent.
    public static func callBody(projectID: String, title: String, start: Date, durationS: Int, meta: [String: String],
                                appVersion: String, consent: [String: Any]? = nil, analysis: [String: Any]? = nil,
                                orgID: String = "", isPrivate: Bool = false) -> [String: Any] {
        func m(_ k: String, _ max: Int) -> String { String((meta[k] ?? "").prefix(max)) }
        var o: [String: Any] = ["project_id": projectID, "title": String(title.prefix(300)), "started_at": iso.string(from: start),
                                "duration_s": max(0, durationS), "call_type": m("call_type", 50), "audience": m("audience", 50),
                                "language": m("language", 10), "app_version": String(appVersion.prefix(40))]
        if let c = consent { o["consent"] = c }
        if let a = analysis { o["analysis"] = a }
        // 0.17.0 (B6b): the call's organization (a server before 0.6.0 never sees the new fields from a personal call)
        if !orgID.isEmpty { o["org_id"] = orgID }
        if isPrivate { o["is_private"] = true }
        return o
    }

    /// 0.17.0 (B6b): the query for a call's parts and its delete, so they run in the call's organization; "" keeps
    /// the server's default (the personal organization), as before 0.17.0.
    public static func orgQuery(_ orgID: String) -> String {
        orgID.range(of: "^[0-9A-Fa-f-]{36}$", options: .regularExpression) != nil ? "?org_id=" + orgID : ""
    }

    /// 0.17.0 (B6b): the body of POST /v1/projects in an organization. `orgProjectID`: nil leaves the link as it is (a
    /// personal organization has no organization projects), "" unlinks, an id links (D38).
    public static func projectBody(name: String, slug: String, orgID: String, orgProjectID: String?) -> [String: Any] {
        var o: [String: Any] = ["name": String(name.prefix(200)), "local_slug": localSlug(slug)]
        if !orgID.isEmpty { o["org_id"] = orgID }
        if let l = orgProjectID { o["org_project_id"] = l.isEmpty ? NSNull() : l }
        return o
    }

    /// 0.17.0: the key of a registered project: one server project per account, organization and local slug (the same
    /// slug may live in two organizations, B6b contract 3). The personal organization keeps the old key.
    public static func projectKey(email: String, orgID: String, personal: Bool, slug: String, link: String) -> String {
        (personal || orgID.isEmpty ? email : email + "|" + orgID) + "|" + localSlug(slug) + (link.isEmpty ? "" : "|" + link)
    }

    /// 0.17.0 (D36): a 422 that names the private-calls policy.
    public static func privateRefused(status: Int, problem: String) -> Bool { status == 422 && problem.lowercased().contains("private calls are off") }

    /// 0.13.0 (B8 part 2): the consent record as the server takes it (said, posted, none, unknown; the time when known).
    public static func consent(_ s: CallConsent.State) -> [String: Any] {
        var o: [String: Any] = ["mode": s.mode.rawValue]
        if let at = s.at { o["at"] = iso.string(from: at) }
        return o
    }

    public static func inboxPath(transcript t: String) -> String { stem(t) + ".inbox.jsonl" }
    public static func sheetCheckPath(transcript t: String) -> String { stem(t) + ".sheet-check.json" }

    /// 0.13.0 (B8 part 2): the call's numbers, never a text. `tips`: the call's tips files; `inbox`: the window's inbox
    /// (ratings as tip_feedback settings, HELP NOW as the ask "sos"); `talkShare`: the PM's share of the words
    /// (CallMetrics); `sheetCheck`: <stem>.sheet-check.json. Tips shown: tip, fact, answer and card lines, not partial,
    /// not retracted, one per uid. Ratings: the last one per tip; useful = used (a check or Said), not useful = a cross,
    /// partly counts as neither. Sheet topics: the checked questions, hit = answered or partly. nil when there is nothing.
    public static func analysis(tips: String, inbox: String, talkShare: Double?, sheetCheck: Data?) -> [String: Any]? {
        func objects(_ text: String) -> [[String: Any]] {
            text.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        }
        let t = objects(tips)
        let retracted = Set(t.filter { ($0["kind"] as? String) == "retract" }.compactMap { $0["uid"] as? String })
        var seen = Set<String>(), shown = 0
        for (i, o) in t.enumerated() {
            guard ["tip", "fact", "answer", "card"].contains((o["kind"] as? String) ?? ""), (o["partial"] as? Bool) != true else { continue }
            let uid = (o["uid"] as? String) ?? ""
            if !uid.isEmpty && retracted.contains(uid) { continue }
            let key = uid.isEmpty ? "#\(i)" : uid
            if seen.insert(key).inserted { shown += 1 }
        }
        var verdicts: [String: String] = [:], helpNow = 0
        for o in objects(inbox) {
            if (o["kind"] as? String) == "setting" {
                guard (o["key"] as? String) == "tip_feedback", let v = o["value"] as? String else { continue }
                let parts = v.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, ["used", "partly", "not_useful"].contains(String(parts[0])) else { continue }
                var rest = String(parts[1])
                if let r = rest.range(of: "|c=", options: .backwards) { rest = String(rest[..<r.lowerBound]) }
                if let r = rest.range(of: "|r=", options: .backwards) { rest = String(rest[..<r.lowerBound]) }
                verdicts[rest] = String(parts[0])
            } else if o["kind"] == nil, ((o["text"] as? String) ?? "").trimmingCharacters(in: .whitespaces).lowercased() == "sos" {
                helpNow += 1
            }
        }
        var hit = 0, total = 0
        if let d = sheetCheck, let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            let qs = (o["questions"] as? [[String: Any]]) ?? []
            total = qs.count
            hit = qs.filter { ["answered", "partly"].contains(($0["status"] as? String) ?? "") }.count
        }
        if shown == 0, verdicts.isEmpty, helpNow == 0, talkShare == nil, total == 0 { return nil }
        var a: [String: Any] = ["tips_shown": shown, "tips_rated_useful": verdicts.values.filter { $0 == "used" }.count,
                                "tips_not_useful": verdicts.values.filter { $0 == "not_useful" }.count,
                                "ask_now_count": helpNow, "sheet_topics_hit": hit, "sheet_topics_total": total]
        if let r = talkShare { a["talk_ratio_me"] = (min(1, max(0, r)) * 100).rounded() / 100 }
        return a
    }

    /// The call notes (<stem>.notes.md) are the summary; nil without notes.
    public static func summaryBody(notes: String?) -> [String: Any]? {
        guard let n = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty else { return nil }
        return ["body_md": String(n.prefix(200_000)), "model": "claude-sonnet"]
    }

    public static func decisions(_ n: MeetingNotes.Notes?) -> [[String: Any]] {
        (n?.decisions ?? []).prefix(200).compactMap { i in
            let t = i.text.trimmingCharacters(in: .whitespaces)
            return MeetingNotes.isNothing(t) ? nil : ["text": String(t.prefix(2000))]
        }
    }

    /// 0.12.2 (L2): the call's decisions by the one rule (CallLists), so the server shows what the call page shows.
    public static func decisions(_ l: CallLists.Lists) -> [[String: Any]] {
        l.decisions.prefix(200).map { ["text": String($0.prefix(2000))] }
    }

    /// 0.12.2 (L3): the call's risks by the one rule (CallLists), for PUT /v1/calls/{id}/risks (server 0.4.0).
    public static func risks(_ l: CallLists.Lists) -> [[String: Any]] {
        l.risks.prefix(200).map { ["text": String($0.prefix(2000))] }
    }

    /// 0.12.2 (L3): a server older than 0.4.0 has no risks part (404 or 405): skip it quietly, never treat it as
    /// "the call is gone".
    public static func partMissing(_ name: String, status: Int) -> Bool { name == "risks" && (status == 404 || status == 405) }

    /// 0.12.2 (L4): the call's tasks from the commitments register (the store: text, owner, status, due), else by the
    /// one rule (CallLists: notes, live picture, older notes). `me`: the PM's name for "me" items ("" leaves it out).
    /// A due date goes only when it reads as a day (CommitmentRegister.dueDate); a Notion link only when it is one.
    public static func tasks(register: [Commitment], lists: CallLists.Lists, me: String) -> [[String: Any]] {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        func row(_ text: String, owner: String, mine: Bool, due: String, from: Date, status: String, notion: String,
                 cid: String = "") -> [String: Any]? {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !MeetingNotes.isNothing(t) else { return nil }
            var o: [String: Any] = ["text": String(t.prefix(2000)), "status": status, "_mine": mine]
            if !cid.isEmpty { o["_cid"] = cid }        // 0.17.0 (block 2): the register item, for a colleague's change
            let who = mine ? me : owner
            if !who.isEmpty { o["assignee"] = String(who.prefix(200)) }
            if !due.isEmpty, let d = CommitmentRegister.dueDate(due, from: from) { o["due_date"] = f.string(from: d) }
            if notion.hasPrefix("https://www.notion.so/") || notion.hasPrefix("https://notion.so/") { o["notion_url"] = notion }
            return o
        }
        if !register.isEmpty {
            return register.prefix(200).compactMap { c in
                row(c.text, owner: c.owner, mine: c.mine, due: c.due, from: c.createdDate ?? Date(),
                    status: ["open", "done", "dropped"].contains(c.status) ? c.status : "open", notion: c.notionPage, cid: c.id)
            }
        }
        return lists.tasks.prefix(200).compactMap { k in
            row(k.text, owner: k.owner, mine: k.mine ?? k.owner.isEmpty, due: "", from: Date(), status: "open", notion: "")
        }
    }

    public static func tasks(_ n: MeetingNotes.Notes?) -> [[String: Any]] {
        (n?.actions ?? []).prefix(200).compactMap { i in
            let t = i.text.trimmingCharacters(in: .whitespaces)
            return MeetingNotes.isNothing(t) ? nil : ["text": String(t.prefix(2000))]
        }
    }

    /// The Meeting Sheet as built for the call, if it is a JSON object under 1 MB.
    public static func sheetBody(_ data: Data?) -> [String: Any]? {
        guard let d = data, d.count < 1_000_000, let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        return ["sheet": o]
    }

    static func driveID(_ s: String) -> Bool { s.range(of: "^[A-Za-z0-9_-]{10,200}$", options: .regularExpression) != nil }
    static func driveLink(_ s: String) -> Bool {
        s.range(of: "^https://(drive|docs)\\.google\\.com/[^\\s]*$", options: .regularExpression) != nil && s.count <= 500
    }

    /// Links to the recording parts and the transcript copy in Google Drive (links only, never files).
    public static func assets(recording: RecordingMeta?, transcript: DriveTranscriptMeta?) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for p in recording?.parts ?? [] where driveID(p.driveID) && driveLink(p.driveLink) {
            var a: [String: Any] = ["kind": p.kind == "audio" ? "audio" : "video", "drive_file_id": p.driveID,
                                    "web_view_link": p.driveLink, "drive_kind": p.driveKind == "shared_drive" ? "shared_drive" : "my_drive"]
            if driveID(p.driveFolderID) { a["drive_folder_id"] = p.driveFolderID }
            if p.bytes > 0 { a["bytes"] = p.bytes }
            out.append(a)
        }
        if let t = transcript, driveID(t.fileID), driveLink(t.link) {
            var a: [String: Any] = ["kind": "transcript_md", "drive_file_id": t.fileID, "web_view_link": t.link,
                                    "drive_kind": t.kind == "shared_drive" ? "shared_drive" : "my_drive"]
            if driveID(t.folderID) { a["drive_folder_id"] = t.folderID }
            out.append(a)
        }
        return Array(out.prefix(20))
    }

    /// The parts whose body changed since the last accepted send, in the order they go out (the call first).
    public static func changed(_ bodies: [(String, Data)], state: State) -> [(String, Data)] {
        bodies.filter { state.hashes[$0.0] != hash($0.1) }
    }

    /// 0.12.1 (B8): what the call page says about a call's copy on the server.
    public enum Status: Equatable { case syncing, synced(Date), waiting, failed(String), skipped, deletedElsewhere, removed }
    public static func status(_ st: State?, syncing: Bool) -> Status {
        guard let st else { return syncing ? .syncing : .waiting }
        if st.removed { return .removed }
        if st.deletedElsewhere { return .deletedElsewhere }
        if st.skip { return .skipped }
        if syncing { return .syncing }
        if !st.error.isEmpty { return .failed(st.error) }
        if let d = st.syncedAt, !st.callID.isEmpty { return .synced(d) }
        return .waiting
    }

    /// 0.12.1: "Delete from server" may be offered: the server has a copy of this call and it is not gone yet.
    public static func canDelete(_ st: State?) -> Bool {
        guard let st else { return false }
        return !st.callID.isEmpty && !st.removed && !st.deletedElsewhere
    }

    /// 0.12.1: the answer to DELETE /v1/calls/{id}: 204 deleted, 410 already deleted, 404 the server no longer has it.
    /// All three leave the call off the server for good; anything else keeps the state and says why.
    public static func afterDelete(_ st: State, status: Int, problem: String = "") -> (State, String?) {
        guard [200, 204, 404, 410].contains(status) else { return (st, problem.isEmpty ? "HTTP \(status)" : problem) }
        var s = st
        s.removed = true; s.callID = ""; s.version = ""; s.hashes = [:]; s.items = [:]; s.error = ""; s.syncedAt = nil
        return (s, nil)
    }

    /// What a server answer means for the queue.
    public enum Outcome: Equatable { case ok, deletedElsewhere, stop(String), retryLater(String) }
    public static func outcome(status: Int, problem: String = "") -> Outcome {
        switch status {
        case 200, 201: return .ok
        case 410: return .deletedElsewhere
        case 0, 408, 429, 500...599: return .retryLater(problem.isEmpty ? "HTTP \(status)" : problem)
        default: return .stop(problem.isEmpty ? "HTTP \(status)" : problem)
        }
    }
}
