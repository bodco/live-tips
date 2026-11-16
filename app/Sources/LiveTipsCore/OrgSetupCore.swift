import Foundation

/// 0.17.0 (spec 5.3, D39, Bohdan 16.11): setting up an organization after the upgrade, for its owner. The organization
/// already exists (the upgrade happens in the console; the server has no `POST /v1/orgs`), so the steps start from it:
/// 1 its name, 2 projects (move mine in, or a new one with the 5.2 wizard), 3 invites, 4 teams and leads, 5 policy.
/// Steps 3-5 can wait: the console (pacenote-admin.bodco.pm/org/{id}) does the same. Pure rules here (CoreChecks);
/// the window is in the app (OrgSetupView.swift).
public enum OrgSetup {
    public enum Step: String, CaseIterable { case name, projects, invite, teams, policy }

    /// The steps for this organization: teams only where the plan has them.
    public static func steps(_ org: PacenoteServer.Org) -> [Step] {
        org.teams ? Step.allCases : Step.allCases.filter { $0 != .teams }
    }

    /// Offered (a line on Home) to the owner of a team organization not set up or dismissed yet on this Mac.
    public static func offered(_ org: PacenoteServer.Org, done: Set<String>) -> Bool {
        org.kind == "team" && org.role == "owner" && !done.contains(org.id)
    }

    /// May run at all (Settings > Account "Set up…"): owner or admin of a team organization.
    public static func canRun(_ org: PacenoteServer.Org) -> Bool { org.kind == "team" && ["owner", "admin"].contains(org.role) }

    public static func nameBody(_ name: String) -> [String: Any]? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? nil : ["name": String(n.prefix(200))]
    }

    /// The projects that could move into the organization: active, with a folder, not there already, and not the
    /// untouched sample (it never leaves the Mac, spec 5.1).
    public static func movable(_ projects: [Project], into orgID: String) -> [Project] {
        projects.filter { $0.status != "archived" && !$0.root.isEmpty && $0.homeOrg != orgID && !SampleProject.blocksSync($0) }
    }

    public struct InviteLine: Equatable {
        public var email: String
        public var role: String
        public init(email: String, role: String) { self.email = email; self.role = role }
    }

    /// One email a line (or separated by commas); "admin" on the line makes that person an admin. `bad`: what is not
    /// an email. Each email once, at most 50.
    public static func invites(_ text: String, defaultRole: String = "member") -> (ok: [InviteLine], bad: [String]) {
        var ok: [InviteLine] = [], bad: [String] = [], seen = Set<String>()
        for raw in text.split(whereSeparator: { $0.isNewline || $0 == "," || $0 == ";" }) {
            let words = raw.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !words.isEmpty else { continue }
            let admin = words.contains { $0.lowercased() == "admin" }
            let mails = words.filter { $0.lowercased() != "admin" && $0.lowercased() != "member" }
            for m in mails {
                let e = m.trimmingCharacters(in: CharacterSet(charactersIn: "<>()\"'")).lowercased()
                guard e.count <= 254, e.range(of: "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", options: .regularExpression) != nil else { bad.append(m); continue }
                if seen.insert(e).inserted && ok.count < 50 { ok.append(InviteLine(email: e, role: admin ? "admin" : defaultRole)) }
            }
        }
        return (ok, bad)
    }

    public static func inviteBody(_ i: InviteLine, teamID: String) -> [String: Any] {
        var o: [String: Any] = ["email": i.email, "org_role": i.role == "admin" ? "admin" : "member"]
        if !teamID.isEmpty { o["team_id"] = teamID }
        return o
    }

    /// The L10n key of an invite answer.
    public static func inviteResult(status: Int) -> String {
        switch status {
        case 200: return "orgsetup.invite.refreshed"
        case 201: return "orgsetup.invite.sent"
        case 402: return "orgsetup.invite.seats"
        case 403: return "orgsetup.invite.forbidden"
        case 409: return "orgsetup.invite.member"
        case 422: return "orgsetup.invite.invalid"
        default: return "orgsetup.invite.failed"
        }
    }

    public struct Team: Equatable, Identifiable {
        public var id: String, name: String, leadID: String
        public var memberIDs: [String]
        public init(id: String, name: String, leadID: String = "", memberIDs: [String] = []) {
            self.id = id; self.name = name; self.leadID = leadID; self.memberIDs = memberIDs
        }
    }

    public static func teams(_ a: [[String: Any]]) -> [Team] {
        a.compactMap { t in
            guard let id = t["id"] as? String else { return nil }
            return Team(id: id, name: (t["name"] as? String) ?? "", leadID: (t["lead_user_id"] as? String) ?? "",
                        memberIDs: (t["member_ids"] as? [String]) ?? [])
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func teamBody(name: String, leadID: String) -> [String: Any]? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return nil }
        var o: [String: Any] = ["name": String(n.prefix(200))]
        if !leadID.isEmpty { o["lead_user_id"] = leadID }
        return o
    }

    public struct Policy: Equatable {
        public var allowPrivateCalls = true
        public var shareMeetingSheets = true
        public init(allowPrivateCalls: Bool = true, shareMeetingSheets: Bool = true) {
            self.allowPrivateCalls = allowPrivateCalls; self.shareMeetingSheets = shareMeetingSheets
        }
    }

    public static func policy(_ o: [String: Any]) -> Policy {
        Policy(allowPrivateCalls: (o["allow_private_calls"] as? Bool) ?? true, shareMeetingSheets: (o["share_meeting_sheets"] as? Bool) ?? true)
    }

    /// PATCH /v1/orgs/{id}/policy: only what changed (the server takes only sent fields).
    public static func policyBody(from a: Policy, to b: Policy) -> [String: Any] {
        var o: [String: Any] = [:]
        if a.allowPrivateCalls != b.allowPrivateCalls { o["allow_private_calls"] = b.allowPrivateCalls }
        if a.shareMeetingSheets != b.shareMeetingSheets { o["share_meeting_sheets"] = b.shareMeetingSheets }
        return o
    }
}
