import Foundation

// INT S2 (D52, server INT S1): Notion through OAuth. The Pacenote server holds the client secret and the callback;
// the token pair lives only in this Mac's Keychain (SecretStore.Key.notionOAuth). Pure helpers here (CoreChecks);
// the network is in the app (NotionAuth.swift).

/// What the Keychain keeps after "Connect with Notion": the pair from POST /v1/integrations/notion/claim (or /refresh)
/// and the root page Pacenote made at the top of the workspace.
public struct NotionOAuthRecord: Codable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var workspaceID: String
    public var workspaceName: String
    public var botID: String
    public var ownerUserID: String?
    /// The "Pacenote" page at the top of the workspace (made by the app after the consent), nil until then.
    public var rootPageID: String?
    public var connected: Date

    public init(accessToken: String, refreshToken: String, workspaceID: String, workspaceName: String, botID: String,
                ownerUserID: String? = nil, rootPageID: String? = nil, connected: Date = Date()) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.workspaceID = workspaceID
        self.workspaceName = workspaceName; self.botID = botID; self.ownerUserID = ownerUserID
        self.rootPageID = rootPageID; self.connected = connected
    }

    /// The server's pair (`access_token`, `refresh_token`, `workspace_id`, ...). nil without both tokens.
    public static func from(pair o: [String: Any], keeping old: NotionOAuthRecord? = nil, now: Date = Date()) -> NotionOAuthRecord? {
        func s(_ k: String) -> String { (o[k] as? String) ?? "" }
        guard !s("access_token").isEmpty, !s("refresh_token").isEmpty else { return nil }
        var r = NotionOAuthRecord(accessToken: s("access_token"), refreshToken: s("refresh_token"),
                                  workspaceID: s("workspace_id").isEmpty ? (old?.workspaceID ?? "") : s("workspace_id"),
                                  workspaceName: s("workspace_name").isEmpty ? (old?.workspaceName ?? "") : s("workspace_name"),
                                  botID: s("bot_id").isEmpty ? (old?.botID ?? "") : s("bot_id"),
                                  ownerUserID: (o["owner_user_id"] as? String) ?? old?.ownerUserID, connected: old?.connected ?? now)
        // a refresh of the same workspace keeps the root page; another workspace starts over
        if let old, old.workspaceID == r.workspaceID { r.rootPageID = old.rootPageID }
        return r
    }

    public func encoded() -> String {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]
        return (try? e.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    public static func decode(_ s: String?) -> NotionOAuthRecord? {
        guard let d = s?.data(using: .utf8), !d.isEmpty else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let r = try? dec.decode(NotionOAuthRecord.self, from: d), !r.accessToken.isEmpty else { return nil }
        return r
    }
}

public enum NotionOAuthCore {
    public static let startPath = "/v1/integrations/notion/start"
    public static let claimPath = "/v1/integrations/notion/claim"
    public static let refreshPath = "/v1/integrations/notion/refresh"
    /// The path the server sends the browser back to on 127.0.0.1 (integrations.py `_loopback`).
    public static let loopbackPath = "/notion"
    /// Where a person removes Pacenote's access in Notion (Settings > Connections).
    public static let manageURL = "https://www.notion.so/profile/integrations"

    public enum Source: String, Equatable { case oauth, manual, none }

    /// The token every Notion call uses: the OAuth one when Notion was connected, else the key pasted under Advanced.
    public static func pick(oauth: NotionOAuthRecord?, manual: String?) -> (token: String?, source: Source) {
        if let o = oauth, !o.accessToken.isEmpty { return (o.accessToken, .oauth) }
        if let m = manual?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty { return (m, .manual) }
        return (nil, .none)
    }

    public enum Loopback: Equatable { case handoff(String), denied, failed(String), bad }

    /// The request target the browser brought to the loopback receiver: `/notion?handoff=...` or `/notion?error=...`.
    public static func loopback(_ target: String) -> Loopback {
        guard let c = URLComponents(string: "http://127.0.0.1" + (target.hasPrefix("/") ? target : "/" + target)),
              c.path == loopbackPath else { return .bad }
        let q = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        if let h = q["handoff"], h.count >= 20 { return .handoff(h) }
        switch q["error"] {
        case "access_denied": return .denied
        case .some(let e) where !e.isEmpty: return .failed(e)
        default: return .bad
        }
    }

    public static func startBody(port: UInt16) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["port": Int(port)], options: [.sortedKeys])) ?? Data()
    }
    public static func claimBody(handoff: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["handoff": handoff], options: [.sortedKeys])) ?? Data()
    }
    public static func refreshBody(refreshToken: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken], options: [.sortedKeys])) ?? Data()
    }

    /// The authorize URL from /start, only when it goes to Notion over https (nothing else is opened in the browser).
    public static func authorizeURL(_ data: Data) -> URL? {
        let o = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        guard let s = o["authorize_url"] as? String, let u = URL(string: s), u.scheme == "https",
              let h = u.host, h == "api.notion.com" || h.hasSuffix(".notion.com") else { return nil }
        return u
    }

    /// 409 `type: notion_reconnect` from /refresh: Notion refused the refresh token, the person connects again.
    public static func reconnectNeeded(_ data: Data, status: Int) -> Bool {
        guard status == 409 else { return false }
        let o = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        return (o["type"] as? String)?.hasSuffix("notion_reconnect") == true
    }
}

/// What Pacenote makes in a workspace connected through OAuth: a "Pacenote" page at the top and its databases under it
/// (Meetings always; Tasks, Decisions and Risks with the Tracker module). Property names follow what the writers look
/// for (CallExport, NotionTasks, NotionDecisions, rules/decisions.yaml, rules/risks.yaml).
public enum NotionBlueprint {
    public static let rootTitle = "Pacenote"

    public struct Database: Equatable {
        public let kind: String          // meetings | tasks | decisions | risks
        public let title: String
        public let properties: [String: String]    // name -> Notion type
        public let options: [String: [String]]      // select name -> option names
    }

    public static let meetings = Database(kind: "meetings", title: "Meetings",
        properties: ["Meeting Name": "title", "Date": "date", "Summary": "rich_text", "Project": "select"], options: [:])
    public static let tasks = Database(kind: "tasks", title: "Tasks",
        properties: ["Name": "title", "Status": "select", "Assignee": "people", "Due": "date", "Project": "select", "Source": "rich_text"],
        options: ["Status": ["To do", "In progress", "Done"]])
    public static let decisions = Database(kind: "decisions", title: "Decisions",
        properties: ["Decision": "title", "Date": "date", "Area": "select", "Context": "rich_text", "Source": "url",
                     "Status": "select", "Stated by": "rich_text", "Project": "select"],
        options: ["Status": ["Active", "Superseded"]])
    public static let risks = Database(kind: "risks", title: "Risks",
        properties: ["Risk": "title", "Date": "date", "Severity": "select", "Likelihood": "select", "Status": "select",
                     "Owner": "rich_text", "Mitigation": "rich_text", "Project": "select"],
        options: ["Severity": ["High", "Medium", "Low"], "Likelihood": ["High", "Medium", "Low"], "Status": ["Open", "Mitigated", "Closed"]])

    public static func databases(tracker: Bool) -> [Database] { tracker ? [meetings, tasks, decisions, risks] : [meetings] }

    /// The kinds still to make: the ones the module needs whose database is not chosen yet (a chosen database, such as
    /// one from Control Tower, is never replaced).
    public static func toCreate(chosen: [String: String], tracker: Bool) -> [Database] {
        databases(tracker: tracker).filter { (chosen[$0.kind] ?? "").isEmpty }
    }

    static func text(_ s: String) -> [[String: Any]] { [["type": "text", "text": ["content": s]]] }

    public static func rootPageBody() -> [String: Any] {
        ["parent": ["type": "workspace", "workspace": true],
         "icon": ["type": "emoji", "emoji": "🧭"],
         "properties": ["title": ["title": text(rootTitle)]],
         "children": [["object": "block", "type": "paragraph",
                       "paragraph": ["rich_text": text("Pacenote keeps its meeting pages and registers here. Rename or move the databases if you like; Pacenote finds them by id.")]]]]
    }

    public static func propertySchema(_ db: Database) -> [String: Any] {
        var out: [String: Any] = [:]
        for (name, type) in db.properties {
            if type == "select", let opts = db.options[name] {
                out[name] = ["select": ["options": opts.map { ["name": $0] }]]
            } else {
                out[name] = [type: [String: Any]()]
            }
        }
        return out
    }

    public static func databaseBody(_ db: Database, parentPage: String) -> [String: Any] {
        ["parent": ["type": "page_id", "page_id": parentPage],
         "title": text(db.title),
         "initial_data_source": ["properties": propertySchema(db)]]
    }

    /// The data source id of a database from POST /databases or GET /databases/{id} (Notion 2025-09-03).
    public static func dataSourceID(_ o: [String: Any]) -> String? {
        ((o["data_sources"] as? [[String: Any]])?.first?["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Databases already under the root (GET /blocks/{root}/children): title -> database id, so a second Connect or a
    /// Reconnect reuses them instead of making copies.
    public static func childDatabases(_ o: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for b in (o["results"] as? [[String: Any]]) ?? [] where (b["type"] as? String) == "child_database" {
            guard let id = b["id"] as? String, let t = (b["child_database"] as? [String: Any])?["title"] as? String else { continue }
            if out[t] == nil { out[t] = id }
        }
        return out
    }

    /// The "Pacenote" page at the top of the workspace among search results (a second Mac, or a lost Keychain).
    public static func rootInSearch(_ o: [String: Any]) -> String? {
        for r in (o["results"] as? [[String: Any]]) ?? [] where (r["object"] as? String) == "page" {
            guard (r["in_trash"] as? Bool) != true, (r["archived"] as? Bool) != true,
                  ((r["parent"] as? [String: Any])?["type"] as? String) == "workspace" else { continue }
            let props = (r["properties"] as? [String: [String: Any]]) ?? [:]
            let t = props.values.first { ($0["type"] as? String) == "title" }
                .map { (($0["title"] as? [[String: Any]]) ?? []).compactMap { $0["plain_text"] as? String }.joined() } ?? ""
            if t == rootTitle, let id = r["id"] as? String { return id }
        }
        return nil
    }
}

// MARK: - INT S3

/// Before a Python tool gets NOTION_TOKEN (after-call pages, the mirror, the risk register): one cheap Notion call through
/// NotionAPI (it refreshes on a 401), at most once per window, only for the OAuth token. A pasted key never refreshes.
public enum NotionTokenCheck {
    public static let window: TimeInterval = 10 * 60
    public static func needed(viaOAuth: Bool, lastOK: Date?, now: Date = Date()) -> Bool {
        guard viaOAuth else { return false }
        guard let t = lastOK else { return true }
        return now.timeIntervalSince(t) >= window || now < t
    }
}

/// INT5: after "Connect with Notion" Pacenote offers a local copy of Notion once (Turn on / Later / Not now).
/// Later comes back after three days; Not now never comes back by itself (Settings > Local copy still has it).
public enum NotionLocalCopyOffer {
    public static let choiceKey = "notionLocalCopyChoice"     // "", "later", "no", "on"
    public static let laterKey = "notionLocalCopyLaterAt"
    public static let laterDays: Double = 3

    public static func shouldShow(connected: Bool, mirrorMode: String, choice: String, laterAt: Date?, now: Date = Date()) -> Bool {
        guard connected, mirrorMode == "none" else { return false }
        switch choice {
        case "no", "on": return false
        case "later":
            guard let t = laterAt else { return true }
            return now.timeIntervalSince(t) >= laterDays * 86_400
        default: return true
        }
    }
}

/// The "pacenote" section of notion-mirror's config (Pacenote mode, no Control Tower): Pacenote's root page and the
/// databases chosen in Settings. Rewritten before every run, so a database chosen later is mirrored without a new setup.
public enum NotionMirrorPacenote {
    public static func section(root: String?, meetings: String, tasks: String, decisions: String, risks: String) -> [String: Any] {
        var dbs: [String: String] = [:]
        for (k, v) in [("meetings", meetings), ("tasks", tasks), ("decisions", decisions), ("risks", risks)] {
            let t = v.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { dbs[k] = t }
        }
        var o: [String: Any] = ["databases": dbs]
        if let r = root, !r.isEmpty { o["root_page_id"] = r }
        return o
    }

    /// The config with the section set; everything else (Control Tower ids, mode, the user's own keys) kept.
    public static func merged(_ cfg: [String: Any], section: [String: Any]) -> [String: Any] {
        var c = cfg
        c["pacenote"] = section
        return c
    }

    /// "pacenote" when discover chose Pacenote mode, else "control_tower".
    public static func mode(_ cfg: [String: Any]) -> String { (cfg["mode"] as? String) == "pacenote" ? "pacenote" : "control_tower" }
}
