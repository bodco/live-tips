import Foundation

// B7 (server ADR 5.1, 2026-11-15): the Pacenote account. Optional: without it the app works as before. Sign-in is a
// separate Google request with `openid email profile` only, so the Pacenote account and the Google accounts that give
// calendars and Drive stay independent. The app sends Google's ID token to the server once and gets the server's own
// tokens: access for 15 minutes (memory only), refresh for 60 days with rotation (Keychain only). Pure helpers here
// (CoreChecks); the network is in the app (PacenoteAccount.swift).

public enum PacenoteServer {
    public static let defaultURL = "https://pacenote-api.bodco.pm"

    /// The server address: an override for a development server (UserDefaults "pacenoteServerURL"), else the default.
    /// Only https, or http to this Mac, is accepted; anything else falls back to the default.
    public static func baseURL(override: String?) -> URL {
        let o = (override ?? "").trimmingCharacters(in: .whitespaces)
        if let u = URL(string: o), let s = u.scheme, let h = u.host, !h.isEmpty,
           s == "https" || (s == "http" && (h == "127.0.0.1" || h == "localhost")) {
            return URL(string: o.hasSuffix("/") ? String(o.dropLast()) : o)!
        }
        return URL(string: defaultURL)!
    }

    /// What the app keeps in the Keychain (SecretStore.Key.pacenoteSession): the refresh token and who signed in.
    public struct Session: Codable, Equatable {
        public var refreshToken: String
        public var refreshExpires: Date
        public var email: String
        public var name: String
        public var signedIn: Date
        public init(refreshToken: String, refreshExpires: Date, email: String, name: String, signedIn: Date = Date()) {
            self.refreshToken = refreshToken; self.refreshExpires = refreshExpires; self.email = email; self.name = name
            self.signedIn = signedIn
        }
        public func encoded() -> String {
            let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]
            return (try? e.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        public static func decode(_ s: String?) -> Session? {
            guard let d = s?.data(using: .utf8) else { return nil }
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            return try? dec.decode(Session.self, from: d)
        }
    }

    public struct Tokens: Equatable {
        public var access: String
        public var accessExpires: Date
        public var refresh: String
        public var refreshExpires: Date
    }

    /// A TokenPair from /v1/auth/google or /v1/auth/refresh. The access token is treated as expired a minute early.
    public static func tokens(_ o: [String: Any], now: Date = Date()) -> Tokens? {
        guard let a = o["access_token"] as? String, !a.isEmpty, let r = o["refresh_token"] as? String, !r.isEmpty else { return nil }
        let ae = (o["access_expires_in"] as? Int) ?? 900, re = (o["refresh_expires_in"] as? Int) ?? 60 * 24 * 3600
        return Tokens(access: a, accessExpires: now.addingTimeInterval(Double(max(ae - 60, 30))), refresh: r,
                      refreshExpires: now.addingTimeInterval(Double(re)))
    }

    public struct Org: Equatable, Identifiable {
        public var id: String
        public var name: String
        public var kind: String      // personal / team
        public var role: String      // owner / admin / member
        public var plan: String
        /// 0.11.0 (B7b): the organization's policy `require_transcript_in_drive` (server ADR 3.4).
        public var requireTranscriptInDrive = false
        /// 0.17.0 (B6b, server 0.6.0): the policy and what the person is here. Defaults are what a server before 0.6.0
        /// means: private calls allowed, nobody sees my calls, no organization projects.
        public var allowPrivateCalls = true
        public var shareMeetingSheets = true
        public var orgProjects = false          // flags.org_projects (Enterprise, D38)
        public var teams = false                // flags.teams
        public var cLevel = false               // I am C-level here (D37)
        public var leadsTeams: [String] = []    // teams I lead here
        public var visibleTo: [String] = []     // who sees my calls here: team_lead and/or c_level
        public init(id: String, name: String, kind: String, role: String, plan: String, requireTranscriptInDrive: Bool = false) {
            self.id = id; self.name = name; self.kind = kind; self.role = role; self.plan = plan
            self.requireTranscriptInDrive = requireTranscriptInDrive
        }
        public var isPersonal: Bool { kind == "personal" }
        /// B6b contract 6: "Manage organization" for a team organization the person runs something in.
        public var canManage: Bool { kind == "team" && (["owner", "admin"].contains(role) || cLevel || !leadsTeams.isEmpty) }
    }

    public struct Me: Equatable {
        public var email: String
        public var name: String
        public var orgs: [Org]
        public var userID = ""
        /// 0.17.0 (B6b): where new calls go (always filled by a 0.6.0 server; else the personal organization).
        public var defaultOrgID = ""
        public var pendingInvites = 0
        /// 0.17.0 (server 0.8.0): Pacenote staff. The Console tab shows for them too (the Platform zone asks for Google).
        public var staff = false
        public init(email: String, name: String, orgs: [Org], userID: String = "", defaultOrgID: String = "", pendingInvites: Int = 0) {
            self.email = email; self.name = name; self.orgs = orgs; self.userID = userID
            self.defaultOrgID = defaultOrgID; self.pendingInvites = pendingInvites
        }
        /// The first organization that requires the transcript in Drive (its name is shown on the locked switch).
        public var transcriptRequiredBy: String? { orgs.first { $0.requireTranscriptInDrive }?.name }
        public var personal: Org? { orgs.first { $0.isPersonal } }
        public func org(_ id: String) -> Org? { id.isEmpty ? nil : orgs.first { $0.id == id } }
        /// Where new calls go: the default when the person is still there, else the personal organization.
        public var defaultOrg: Org? { org(defaultOrgID) ?? personal }
        /// The organization filter on Home is shown only with more than one organization.
        public var showsOrgFilter: Bool { orgs.count > 1 }
        /// 0.17.0: the Console tab in the header, only for someone who runs something (contract 6) or for staff.
        public var showsConsole: Bool { staff || orgs.contains { $0.canManage } }
        /// Where the Console tab opens: the default organization when the person runs it, else the first one they run.
        public var consolePath: String {
            if let d = defaultOrg, d.canManage { return "/org/" + d.id }
            if let o = orgs.first(where: { $0.canManage }) { return "/org/" + o.id }
            return "/"
        }
    }

    // MARK: 0.17.0 (server 0.8.0): the Console tab

    /// The console's host. The tab's web view stays on it; any other link opens in the browser.
    public static let consoleHost = "pacenote-admin.bodco.pm"

    public static func isConsoleURL(_ u: URL?) -> Bool {
        guard let u, u.scheme == "https" else { return false }
        return u.host?.lowercased() == consoleHost
    }

    /// 0.17.1: the console sent the tab to /login because a page needs Google (the Platform zone), not because the
    /// session ended: `next` points into /platform.
    public static func consoleLoginWantsPlatform(_ u: URL) -> Bool {
        guard isConsoleURL(u), u.path == "/login",
              let next = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "next" })?.value
        else { return false }
        return next == "/platform" || next.hasPrefix("/platform/")
    }

    /// The body of POST /v1/console/handoff.
    public static func consoleHandoffBody(next: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["next": next])) ?? Data()
    }

    /// The one-time link from POST /v1/console/handoff: only an https link to the console's /auth/app with a code.
    public static func consoleHandoffURL(_ d: Data) -> URL? {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let s = o["url"] as? String,
              let u = URL(string: s), isConsoleURL(u), u.path == "/auth/app",
              let q = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems,
              q.contains(where: { $0.name == "code" && ($0.value ?? "").hasPrefix("pnh_") }) else { return nil }
        return u
    }

    public static func me(_ o: [String: Any]) -> Me? {
        guard let u = o["user"] as? [String: Any], let email = u["email"] as? String else { return nil }
        let orgs = ((o["organizations"] as? [[String: Any]]) ?? []).compactMap { g -> Org? in
            guard let id = g["id"] as? String else { return nil }
            let policy = (g["policy"] as? [String: Any]) ?? [:], flags = (g["flags"] as? [String: Any]) ?? [:]
            var org = Org(id: id, name: (g["name"] as? String) ?? "", kind: (g["kind"] as? String) ?? "",
                          role: (g["org_role"] as? String) ?? "", plan: (g["plan"] as? String) ?? "",
                          requireTranscriptInDrive: (policy["require_transcript_in_drive"] as? Bool) ?? false)
            org.allowPrivateCalls = (policy["allow_private_calls"] as? Bool) ?? true
            org.shareMeetingSheets = (policy["share_meeting_sheets"] as? Bool) ?? true
            org.orgProjects = (flags["org_projects"] as? Bool) == true && org.kind == "team"   // never in the personal one (0.6.0)
            org.teams = (flags["teams"] as? Bool) == true
            org.cLevel = (g["c_level"] as? Bool) == true
            org.leadsTeams = ((g["leads_teams"] as? [Any]) ?? []).compactMap { ($0 as? String) ?? (($0 as? [String: Any])?["id"] as? String) }
            // heads_departments is deprecated (always []) and not read (D37)
            let vis = ((g["visible_to"] as? [String]) ?? []).filter { ["team_lead", "c_level"].contains($0) }
            org.visibleTo = vis.isEmpty && (g["visible_to_manager"] as? Bool) == true ? ["team_lead"] : vis
            return org
        }
        var me = Me(email: email, name: (u["name"] as? String) ?? "", orgs: orgs, userID: (u["id"] as? String) ?? "",
                    defaultOrgID: (o["default_org_id"] as? String) ?? "", pendingInvites: (o["pending_invites"] as? Int) ?? 0)
        me.staff = (o["staff"] as? Bool) == true      // a server before 0.8.0 does not say: not staff
        return me
    }

    // MARK: 0.17.0 (B6b): invites, visibility, private calls, organization projects

    /// An open invite to my email (GET /v1/invites).
    public struct Invite: Equatable, Identifiable {
        public var id: String
        public var orgID: String
        public var orgName: String
        public var role: String
        public var teamName: String
        public var invitedBy: String
        public var expires: Date?
        public init(id: String, orgID: String, orgName: String, role: String, teamName: String = "", invitedBy: String = "", expires: Date? = nil) {
            self.id = id; self.orgID = orgID; self.orgName = orgName; self.role = role; self.teamName = teamName
            self.invitedBy = invitedBy; self.expires = expires
        }
    }

    static func isoDate(_ s: Any?) -> Date? {
        guard let s = s as? String else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    /// Expired invites are dropped here too (the server already leaves them out).
    public static func invites(_ a: [[String: Any]], now: Date = Date()) -> [Invite] {
        a.compactMap { i in
            guard let id = i["id"] as? String, let org = i["org_id"] as? String else { return nil }
            let exp = isoDate(i["expires_at"])
            if let e = exp, e <= now { return nil }
            return Invite(id: id, orgID: org, orgName: (i["org_name"] as? String) ?? "", role: (i["org_role"] as? String) ?? "member",
                          teamName: (i["team_name"] as? String) ?? "", invitedBy: (i["invited_by_name"] as? String) ?? "", expires: exp)
        }
    }

    public static func acceptBody(makeDefault: Bool) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["make_default": makeDefault])) ?? Data()
    }

    /// PATCH /v1/me: null means the personal organization.
    public static func defaultOrgBody(_ orgID: String?, me: Me) -> Data {
        let v: Any = (orgID.flatMap { me.org($0) }.map { $0.isPersonal ? NSNull() : $0.id as Any }) ?? NSNull()
        return (try? JSONSerialization.data(withJSONObject: ["default_org_id": v])) ?? Data()
    }

    /// What an answer to accept means: the L10n key of the message, nil when joined.
    public static func acceptProblem(status: Int) -> String? {
        switch status {
        case 200, 201, 204: return nil
        case 404: return "org.invite.err.gone"
        case 410: return "org.invite.err.expired"
        case 402: return "org.invite.err.seats"
        default: return "org.invite.err.other"
        }
    }

    /// The badge next to a call and its Sheet (B6b contract 1): the L10n key, nil when nobody else sees it or the call
    /// is private. Not tied to share_meeting_sheets (D36: the switch acts on past calls too).
    public static func visibilityKey(_ org: Org?, isPrivate: Bool) -> String? {
        guard let o = org, !isPrivate else { return nil }
        let lead = o.visibleTo.contains("team_lead"), top = o.visibleTo.contains("c_level")
        return lead && top ? "org.visible.both" : lead ? "org.visible.lead" : top ? "org.visible.leadership" : nil
    }

    /// May this call be (made) private here? A call already private on the server stays private (D36).
    public static func privateAllowed(_ org: Org?, alreadyPrivate: Bool) -> Bool { alreadyPrivate || (org?.allowPrivateCalls ?? true) }

    /// The console page of an organization ("Manage organization").
    public static func adminURL(orgID: String) -> URL { URL(string: "https://pacenote-admin.bodco.pm/org/" + orgID)! }

    /// An organization project I can link my project to (GET /v1/orgs/{id}/projects, D38).
    public struct OrgProject: Equatable, Identifiable {
        public var id: String
        public var name: String
        public var archived: Bool
        public var memberIDs: [String]
        public init(id: String, name: String, archived: Bool = false, memberIDs: [String] = []) {
            self.id = id; self.name = name; self.archived = archived; self.memberIDs = memberIDs
        }
    }

    /// Only the projects I am on, not archived (a lead or an owner gets them all, but links only where they are).
    public static func orgProjects(_ a: [[String: Any]], me userID: String) -> [OrgProject] {
        a.compactMap { p -> OrgProject? in
            guard let id = p["id"] as? String else { return nil }
            let m = (p["member_ids"] as? [String]) ?? []
            let op = OrgProject(id: id, name: (p["name"] as? String) ?? "", archived: (p["archived"] as? Bool) == true, memberIDs: m)
            guard !op.archived, userID.isEmpty || m.contains(userID) else { return nil }
            return op
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The organization a call goes to (D36): a call already on the server stays in its organization while the person
    /// is still there; a person who left takes it home (the server moved it). A new call goes where its project is linked
    /// (an organization project), else where new calls go now. "" when the account is not known yet.
    public static func orgForCall(stored: String, onServer: Bool, linkedOrg: String, me: Me?) -> String {
        guard let me else { return stored }
        if !stored.isEmpty { return me.org(stored) != nil ? stored : (me.personal?.id ?? "") }
        if onServer { return me.personal?.id ?? "" }        // synced before 0.17.0: always the personal organization
        if let l = me.org(linkedOrg) { return l.id }
        return me.defaultOrg?.id ?? ""
    }

    public struct Device: Equatable, Identifiable {
        public var id: String
        public var name: String
        public var appVersion: String
        public var lastSeen: Date?
        public var current: Bool
    }

    public static func devices(_ a: [[String: Any]]) -> [Device] {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let g = ISO8601DateFormatter()
        return a.compactMap { d in
            guard let id = d["id"] as? String else { return nil }
            let seen = (d["last_seen_at"] as? String).flatMap { f.date(from: $0) ?? g.date(from: $0) }
            return Device(id: id, name: (d["name"] as? String) ?? "", appVersion: (d["app_version"] as? String) ?? "",
                          lastSeen: seen, current: (d["current"] as? Bool) == true)
        }
        .sorted { ($0.current ? 0 : 1, -($0.lastSeen?.timeIntervalSince1970 ?? 0)) < ($1.current ? 0 : 1, -($1.lastSeen?.timeIntervalSince1970 ?? 0)) }
    }

    /// The body of POST /v1/auth/google. The server rejects unknown fields and names over 100 characters.
    public static func signInBody(idToken: String, deviceName: String, appVersion: String) -> Data {
        let name = String(deviceName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        let o: [String: Any] = ["id_token": idToken,
                                "device": ["name": name.isEmpty ? "Mac" : name, "platform": "macos",
                                           "app_version": appVersion.isEmpty ? "dev" : String(appVersion.prefix(40))]]
        return (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
    }

    /// A short reason from an RFC 9457 problem body (detail, else title), never the raw body.
    public static func problem(_ data: Data, status: Int) -> String {
        let o = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        let s = (o["detail"] as? String) ?? (o["title"] as? String) ?? ""
        return s.isEmpty ? "HTTP \(status)" : String(s.prefix(160))
    }

    /// 0.12.1 (B8): a 402 names the plan quota it hit ("storage_mb") and its limit; nil for any other answer.
    public struct Quota: Equatable {
        public let name: String; public let limit: Int
        public init(name: String, limit: Int) { self.name = name; self.limit = limit }
    }
    public static func quota(_ data: Data, status: Int) -> Quota? {
        guard status == 402, let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let n = o["quota"] as? String, !n.isEmpty else { return nil }
        return Quota(name: n, limit: (o["limit"] as? Int) ?? 0)
    }

    /// What the app does after a failed refresh: 401 means the session ended on the server (signed out elsewhere,
    /// revoked, deleted): forget it here. Anything else (no network, 5xx, 429) keeps it and tries again later.
    public static func refreshEndsSession(status: Int) -> Bool { status == 401 }
}
