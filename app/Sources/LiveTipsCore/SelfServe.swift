import Foundation

/// 0.19.0 (server 0.11.0, migration 0014, Bohdan 17.11): plans for everyone in the beta. The plans people can choose
/// (GET /v1/plans) with their planned price, trial and what they include; moving an organization to another plan
/// (POST /v1/orgs/{id}/plan, owner or admin; a downgrade only when the organization fits); starting a team organization
/// from Solo (POST /v1/orgs); and the person's own usage (GET /v1/me/usage). The server decides; the app shows.
public enum SelfServe {
    public struct Item: Equatable { public var id: String; public var label: String; public var level: String }
    public struct Quota: Equatable { public var id: String; public var label: String; public var limit: Double?; public var period: String }
    public struct Plan: Equatable, Identifiable {
        public var id: String
        public var name: String
        public var description: String
        public var price: Entitlements.Price?
        public var trialDays: Int
        public var teams: Bool
        public var included: [Item]
        public var missing: [Item]
        public var quotas: [Quota]
    }

    static func items(_ v: Any?) -> [Item] {
        ((v as? [[String: Any]]) ?? []).compactMap { m in
            guard let id = m["id"] as? String else { return nil }
            return Item(id: id, label: (m["label"] as? String) ?? id, level: (m["level"] as? String) ?? "")
        }
    }

    /// GET /v1/plans: (beta, plans in the server's order). A plan without an id is dropped.
    public static func plans(_ d: Data) -> (beta: Bool, plans: [Plan]) {
        let o = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any]) ?? [:]
        let list = ((o["plans"] as? [[String: Any]]) ?? []).compactMap { p -> Plan? in
            guard let id = p["id"] as? String, !id.isEmpty else { return nil }
            var price: Entitlements.Price?
            if let pr = p["price"] as? [String: Any], let c = pr["amount_cents"] as? Int {
                price = Entitlements.Price(amountCents: c, currency: (pr["currency"] as? String) ?? "USD",
                                           per: (pr["per"] as? String) ?? "seat_month", minSeats: (pr["min_seats"] as? Int) ?? 1)
            }
            let qs = ((p["quotas"] as? [[String: Any]]) ?? []).compactMap { q -> Quota? in
                guard let id = q["id"] as? String else { return nil }
                return Quota(id: id, label: (q["label"] as? String) ?? id, limit: Entitlements.num(q["limit"]),
                             period: (q["period"] as? String) ?? "")
            }
            return Plan(id: id, name: (p["name"] as? String) ?? id, description: (p["description"] as? String) ?? "",
                        price: price, trialDays: (p["trial_days"] as? Int) ?? 0, teams: (p["teams"] as? Bool) == true,
                        included: items(p["included"]), missing: items(p["missing"]), quotas: qs)
        }
        return ((o["beta"] as? Bool) ?? true, list)
    }

    /// What a move from one plan to another adds and turns off, by module label (the confirm step). A module whose
    /// level changes counts as added when it moves up the target's order, else as turned off; with the current plan
    /// unknown (custom), everything the target has is listed as included, nothing as turned off.
    public static func changes(from: Plan?, to: Plan) -> (gained: [String], lost: [String]) {
        guard let from else { return (to.included.map(\.label), []) }
        let a = Dictionary(from.included.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
        let b = Dictionary(to.included.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
        var gained: [String] = [], lost: [String] = []
        for m in to.included where a[m.id] == nil || (a[m.id]!.level != m.level && rank(m.level) > rank(a[m.id]!.level)) {
            gained.append(m.label)
        }
        for m in from.included where b[m.id] == nil || (b[m.id]!.level != m.level && rank(b[m.id]!.level) < rank(m.level)) {
            lost.append(m.label)
        }
        return (gained, lost)
    }

    /// Levels the server catalog uses beside on/off, low to high (org_policy basic < full, project_context shared <
    /// index; "" is a plain on). An unknown level ranks as the lowest named one.
    static func rank(_ level: String) -> Int {
        ["", "basic", "shared", "full", "index"].firstIndex(of: level) ?? 1
    }

    /// Who may do what with an organization's plan in the app.
    public enum Action: Equatable {
        case current                 // this is the plan
        case choose                  // Switch to (owner or admin; personal space: plans without teams)
        case startTeam               // Solo: start a team organization on a plan with teams
        case askOwner                // a member: the owner decides
        case custom                  // a custom plan: changes go through Pacenote
    }

    /// The action on one plan card for an organization (or the personal space). Mirrors the server: a personal space
    /// takes only plans without teams; a plan with teams from there starts a new team organization.
    public static func action(org: PacenoteServer.Org, currentPlan: String?, customPlan: Bool, plan: Plan) -> Action {
        if !customPlan, currentPlan == plan.id { return .current }
        if org.isPersonal { return plan.teams ? .startTeam : (customPlan ? .custom : .choose) }
        guard ["owner", "admin"].contains(org.role) else { return .askOwner }
        return customPlan ? .custom : .choose
    }

    public static func chooseBody(_ plan: String) -> Data { (try? JSONSerialization.data(withJSONObject: ["plan": plan])) ?? Data() }

    /// POST /v1/orgs: nil when the name is empty after trimming (the server's limit is 100 characters).
    public static func teamBody(name: String, plan: String) -> Data? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n.count <= 100 else { return nil }
        return try? JSONSerialization.data(withJSONObject: ["name": n, "plan": plan])
    }

    /// What does not fit a downgrade (409 with `misfit`): "Seats: 3 of 1". Empty for any other answer.
    public static func misfit(_ d: Data, status: Int) -> [String] {
        guard status == 409, let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let a = o["misfit"] as? [[String: Any]] else { return [] }
        return a.compactMap { m in
            guard let label = m["label"] as? String else { return nil }
            let used = Entitlements.num(m["used"]) ?? 0, limit = Entitlements.num(m["limit"]) ?? 0
            let f: (Double) -> String = { $0 == $0.rounded() ? "\(Int($0))" : String(format: "%.1f", $0) }
            return "\(label): \(f(used)) / \(f(limit))"
        }
    }

    /// The new organization's id from POST /v1/orgs (201).
    public static func createdOrg(_ d: Data, status: Int) -> String? {
        guard status == 201, let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        return o["id"] as? String
    }

    /// GET /v1/me/usage: the personal overview.
    public struct Usage: Equatable {
        public var days: Int
        public var activeDays: Int
        public var calls: Int
        public var callMinutes: Int
        public var sessions: Int
        public var features: [String]
        public var callsByDay: [Int]
        public var hoursText: String {
            let h = Double(callMinutes) / 60
            return h == h.rounded() ? "\(Int(h))" : String(format: "%.1f", h)
        }
    }

    public static func usage(_ d: Data) -> Usage? {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let days = o["days"] as? Int else { return nil }
        let by = ((o["by_day"] as? [[String: Any]]) ?? []).map { ($0["calls"] as? Int) ?? 0 }
        return Usage(days: days, activeDays: (o["active_days"] as? Int) ?? 0, calls: (o["calls"] as? Int) ?? 0,
                     callMinutes: (o["call_minutes"] as? Int) ?? 0, sessions: (o["sessions"] as? Int) ?? 0,
                     features: (o["features"] as? [String]) ?? [], callsByDay: by)
    }
}
