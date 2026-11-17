import CryptoKit
import Foundation
import Security

/// 0.20.0 (B9, server 0.12.0, D47; spec research/pacenote-b9-team-calls-spec-2026-11-17.md): the team's calls for a
/// team lead or C-level. Pure parts here (CoreChecks `teamCallsB9`): the series key, who gets the Team tab, the periods,
/// the request paths and the answers. Nothing here is stored on the Mac: the team's calls live in memory only (D47.9).
public enum TeamCalls {

    // MARK: series (D47.5)

    /// The local series rule, the same one the series page uses: the project's slug and the title in lower case, letters
    /// and digits only, under the person's id. It never leaves the Mac; only its HMAC does.
    public static func seriesMessage(userID: String, project: String, title: String) -> String {
        userID.lowercased() + "|" + CommitmentRegister.seriesKey(project: project, title: title)
    }

    /// The `series_key` sent with a call: HMAC-SHA256 of the series message with the account's salt (from the Keychain),
    /// 64 hex. nil without a title or a usable salt, so a call without them is sent without a series.
    public static func seriesKey(salt: Data, userID: String, project: String, title: String) -> String? {
        let words = title.lowercased().replacingOccurrences(of: "[^\\p{L}\\p{N}]", with: "", options: .regularExpression)
        guard salt.count >= 16, !words.isEmpty, !userID.isEmpty else { return nil }
        let mac = HMAC<SHA256>.authenticationCode(for: Data(seriesMessage(userID: userID, project: project, title: title).utf8),
                                                  using: SymmetricKey(data: salt))
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// A new salt (32 random bytes, base64), made once and kept in the Keychain.
    public static func newSalt() -> String {
        var b = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
        return Data(b).base64EncodedString()
    }

    public static func salt(_ stored: String?) -> Data? {
        guard let s = stored, let d = Data(base64Encoded: s), d.count >= 16 else { return nil }
        return d
    }

    // MARK: who gets the tab (D47.1, D47.2)

    /// Someone who leads a team or is C-level in a team organization: they may see other people's calls there.
    public static func managesSomeone(_ o: PacenoteServer.Org) -> Bool { o.kind == "team" && (o.cLevel || !o.leadsTeams.isEmpty) }

    /// The organizations whose team the person sees, where the plan opens manager_view (`open` asks the entitlements).
    public static func orgs(_ me: PacenoteServer.Me?, open: (String) -> Bool) -> [PacenoteServer.Org] {
        (me?.orgs ?? []).filter { managesSomeone($0) && open($0.id) }
    }

    // MARK: periods

    public enum Period: String, CaseIterable, Identifiable {
        case days7, days30, days90, quarter, custom
        public var id: String { rawValue }
    }

    /// From and to of a period. Quarter: from the first day of this calendar quarter. Custom: the dates picked (whole
    /// days), at most 366 days back from `to` as the server allows.
    public static func range(_ p: Period, now: Date, custom: (Date, Date)? = nil, calendar: Calendar = .current) -> (Date, Date) {
        switch p {
        case .days7: return (now.addingTimeInterval(-7 * 86400), now)
        case .days30: return (now.addingTimeInterval(-30 * 86400), now)
        case .days90: return (now.addingTimeInterval(-90 * 86400), now)
        case .quarter:
            let c = calendar.dateComponents([.year, .month], from: now)
            let m = ((c.month ?? 1) - 1) / 3 * 3 + 1
            let start = calendar.date(from: DateComponents(year: c.year, month: m, day: 1)) ?? now.addingTimeInterval(-90 * 86400)
            return (start, now)
        case .custom:
            guard let c = custom else { return range(.days30, now: now) }
            let (a, b) = c
            let from = calendar.startOfDay(for: min(a, b))
            let to = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(a, b))) ?? max(a, b)
            return (max(from, to.addingTimeInterval(-366 * 86400)), to)
        }
    }

    // MARK: requests

    public struct Filter: Equatable {
        public var from: Date
        public var to: Date
        public var person = ""
        public var team = ""
        public var project = ""
        public var type = ""
        public var recordedOnly = false
        public var series = ""
        public init(from: Date, to: Date) { self.from = from; self.to = to }
    }

    static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    public static func date(_ s: Any?) -> Date? {
        guard let s = s as? String else { return nil }
        return iso.date(from: s) ?? isoFrac.date(from: s)
    }

    /// One query string, every value percent-encoded (a search may hold &, + or #).
    public static func query(_ items: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return items.filter { !$0.1.isEmpty }
            .map { $0.0 + "=" + ($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }
            .joined(separator: "&")
    }

    private static func base(_ org: String, _ f: Filter) -> [(String, String)] {
        [("org_id", org), ("from", iso.string(from: f.from)), ("to", iso.string(from: f.to))]
    }

    /// GET /v1/calls with scope=team: a page of the team's calls (newest first).
    public static func listPath(org: String, filter f: Filter, cursor: String? = nil, limit: Int = 100) -> String {
        var q = base(org, f) + [("scope", "team"), ("limit", "\(limit)")]
        if !f.team.isEmpty { q.append(("team", f.team)) }
        if !f.person.isEmpty { q.append(("owner", f.person)) }
        if !f.project.isEmpty { q.append(("project", f.project)) }
        if !f.type.isEmpty { q.append(("type", f.type)) }
        if f.recordedOnly { q.append(("has_recording", "true")) }
        if !f.series.isEmpty { q.append(("series", f.series)) }
        if let cursor { q.append(("cursor", cursor)) }
        return "/v1/calls?" + query(q)
    }

    public static func peoplePath(org: String) -> String { "/v1/team/people?" + query([("org_id", org)]) }

    public static func overviewPath(org: String, filter f: Filter) -> String {
        "/v1/team/overview?" + query(base(org, f) + [("team", f.team), ("person", f.person)])
    }

    public static func searchPath(org: String, q: String, filter f: Filter) -> String {
        "/v1/team/search?" + query(base(org, f) + [("q", q.trimmingCharacters(in: .whitespacesAndNewlines)),
                                                    ("team", f.team), ("person", f.person)])
    }

    /// The server's rule for a search: 2 to 200 characters, 1 to 8 words.
    public static func searchable(_ q: String) -> Bool {
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = t.split(whereSeparator: { $0.isWhitespace }).count
        return t.count >= 2 && t.count <= 200 && n >= 1 && n <= 8
    }

    // MARK: answers

    public struct Item: Identifiable, Equatable {
        public var id: String
        public var ownerID: String
        public var ownerName: String
        public var projectID: String
        public var projectName: String
        public var title: String?
        public var start: Date?
        public var durationS: Int
        public var callType: String
        public var isPrivate: Bool
        public var hasSummary: Bool
        public var hasSheet: Bool
        public var hasRecording: Bool
        public var hasTranscript: Bool
        public var seriesKey: String
    }

    static func item(_ o: [String: Any]) -> Item? {
        guard let id = o["id"] as? String else { return nil }
        return Item(id: id, ownerID: (o["owner_id"] as? String) ?? "", ownerName: (o["owner_name"] as? String) ?? "",
                    projectID: (o["project_id"] as? String) ?? "", projectName: (o["project_name"] as? String) ?? "",
                    title: o["title"] as? String, start: date(o["started_at"]), durationS: (o["duration_s"] as? Int) ?? 0,
                    callType: (o["call_type"] as? String) ?? "", isPrivate: (o["is_private"] as? Bool) == true,
                    hasSummary: (o["has_summary"] as? Bool) == true, hasSheet: (o["has_sheet"] as? Bool) == true,
                    hasRecording: (o["has_recording"] as? Bool) == true, hasTranscript: (o["has_transcript"] as? Bool) == true,
                    seriesKey: (o["series_key"] as? String) ?? "")
    }

    private static func obj(_ d: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] }

    public static func page(_ d: Data) -> (items: [Item], next: String?)? {
        guard let o = obj(d), let items = o["items"] as? [[String: Any]] else { return nil }
        return (items.compactMap(item), o["next_cursor"] as? String)
    }

    /// The title a row shows: someone else's private call has none (D47.3).
    public static func title(_ i: Item, privateLabel: String, untitled: String) -> String {
        if i.isPrivate && (i.title ?? "").isEmpty { return privateLabel }
        return (i.title ?? "").isEmpty ? untitled : i.title!
    }

    public struct Person: Identifiable, Equatable {
        public var id: String
        public var name: String
        public var email: String
        public var teamIDs: [String]
        public var label: String { name.isEmpty ? email : name }
    }

    public struct Team: Identifiable, Equatable {
        public var id: String
        public var name: String
        public var iLead: Bool
    }

    public struct People: Equatable {
        public var people: [Person]
        public var teams: [Team]
        public var wholeOrg: Bool
    }

    public static func people(_ d: Data) -> People? {
        guard let o = obj(d), let ps = o["people"] as? [[String: Any]] else { return nil }
        let people = ps.compactMap { p -> Person? in
            guard let id = p["user_id"] as? String else { return nil }
            return Person(id: id, name: (p["name"] as? String) ?? "", email: (p["email"] as? String) ?? "",
                          teamIDs: (p["team_ids"] as? [String]) ?? [])
        }
        let teams = ((o["teams"] as? [[String: Any]]) ?? []).compactMap { t -> Team? in
            guard let id = t["id"] as? String else { return nil }
            return Team(id: id, name: (t["name"] as? String) ?? "", iLead: (t["i_lead"] as? Bool) == true)
        }
        return People(people: people, teams: teams, wholeOrg: (o["whole_org"] as? Bool) == true)
    }

    /// Counts of one person, the team or one week (no content, D47.6).
    public struct Numbers: Equatable {
        public var calls = 0
        public var privateCalls = 0
        public var hours = 0.0
        public var contentCalls = 0
        public var sheetShare: Double?
        public var tipsShown = 0
        public var usefulShare: Double?
        public var askNow = 0
        public var talkMedian: Double?
        public var topicsHit = 0
        public var topicsTotal = 0
        public var decisions = 0
        public var tasksOpen = 0
        public var tasksClosed = 0
        public var risks = 0
        public var recorded = 0
        public init() {}
        public var topicsShare: Double? { topicsTotal > 0 ? Double(topicsHit) / Double(topicsTotal) : nil }
    }

    static func numbers(_ o: [String: Any]) -> Numbers {
        func i(_ k: String) -> Int { (o[k] as? Int) ?? Int((o[k] as? Double) ?? 0) }
        func d(_ k: String) -> Double? { (o[k] as? Double) ?? (o[k] as? Int).map(Double.init) }
        var n = Numbers()
        n.calls = i("calls"); n.privateCalls = i("private_calls"); n.hours = d("hours") ?? 0; n.contentCalls = i("content_calls")
        n.sheetShare = d("sheet_share"); n.tipsShown = i("tips_shown"); n.usefulShare = d("useful_share"); n.askNow = i("ask_now")
        n.talkMedian = d("talk_ratio_median"); n.topicsHit = i("sheet_topics_hit"); n.topicsTotal = i("sheet_topics_total")
        n.decisions = i("decisions"); n.tasksOpen = i("tasks_open"); n.tasksClosed = i("tasks_closed"); n.risks = i("risks")
        n.recorded = i("recorded_calls")
        return n
    }

    public struct PersonNumbers: Identifiable, Equatable {
        public var id: String
        public var name: String
        public var n: Numbers
    }

    public struct Week: Identifiable, Equatable {
        public var id: String { week }
        public var week: String
        public var n: Numbers
    }

    public struct Overview: Equatable {
        public var people: [PersonNumbers]
        public var team: Numbers
        public var weeks: [Week]
    }

    public static func overview(_ d: Data) -> Overview? {
        guard let o = obj(d), let ps = o["people"] as? [[String: Any]], let t = o["team"] as? [String: Any] else { return nil }
        return Overview(people: ps.compactMap { p in (p["user_id"] as? String).map { PersonNumbers(id: $0, name: (p["name"] as? String) ?? "", n: numbers(p)) } },
                        team: numbers(t),
                        weeks: ((o["weeks"] as? [[String: Any]]) ?? []).compactMap { w in (w["week"] as? String).map { Week(week: $0, n: numbers(w)) } })
    }

    public struct Hit: Identifiable, Equatable {
        public var id: String { call.id }
        public var call: Item
        public var field: String
        public var snippet: String
    }

    public static func search(_ d: Data) -> (hits: [Hit], truncated: Bool)? {
        guard let o = obj(d), let items = o["items"] as? [[String: Any]] else { return nil }
        let hits = items.compactMap { h -> Hit? in
            guard let c = h["call"] as? [String: Any], let i = item(c) else { return nil }
            return Hit(call: i, field: (h["field"] as? String) ?? "", snippet: (h["snippet"] as? String) ?? "")
        }
        return (hits, (o["truncated"] as? Bool) == true)
    }

    /// The tab of the colleague's call page a search hit opens.
    public static func section(forField f: String) -> String {
        switch f {
        case "decisions", "tasks", "risks": return f
        default: return "summary"
        }
    }

    public struct View: Identifiable, Equatable {
        public var id: String { callID + "|" + viewer + "|" + (at.map { iso.string(from: $0) } ?? "") }
        public var callID: String
        public var title: String
        public var viewer: String
        public var at: Date?
    }

    public static func views(_ d: Data) -> [View]? {
        guard let o = obj(d), let items = o["items"] as? [[String: Any]] else { return nil }
        return items.map { v in
            let name = (v["viewer_name"] as? String) ?? "", mail = (v["viewer_email"] as? String) ?? ""
            return View(callID: (v["call_id"] as? String) ?? "", title: (v["title"] as? String) ?? "",
                        viewer: name.isEmpty ? mail : name, at: date(v["at"]))
        }
    }

    // MARK: a colleague's call (read only, D47.8)

    public struct Line: Identifiable, Equatable {
        public var id: String
        public var text: String
        public var who: String
        public var status: String
        public var due: String
    }

    public struct Detail: Equatable {
        public var id: String
        public var title: String?
        public var isPrivate: Bool
        public var start: Date?
        public var durationS: Int
        public var callType: String
        public var summary: String
        public var decisions: [Line]
        public var tasks: [Line]
        public var risks: [Line]
        public var participants: [(name: String, seconds: Int, internalSide: Bool)]
        public var analysis: Numbers?
        public var sheet: Data?
        public var recording: URL?
        public var transcript: URL?

        public static func == (a: Detail, b: Detail) -> Bool {
            a.id == b.id && a.title == b.title && a.summary == b.summary && a.decisions == b.decisions && a.tasks == b.tasks
                && a.risks == b.risks && a.sheet == b.sheet && a.recording == b.recording && a.transcript == b.transcript
        }
    }

    /// Only Drive links open (the server takes no other host).
    public static func driveURL(_ s: Any?) -> URL? {
        guard let s = s as? String, let u = URL(string: s), u.scheme == "https",
              let h = u.host?.lowercased(), h == "drive.google.com" || h == "docs.google.com" else { return nil }
        return u
    }

    public static func detail(_ d: Data) -> Detail? {
        guard let o = obj(d), let id = o["id"] as? String else { return nil }
        func lines(_ k: String, who: String) -> [Line] {
            ((o[k] as? [[String: Any]]) ?? []).enumerated().map { i, x in
                Line(id: (x["id"] as? String) ?? "\(k)-\(i)", text: (x["text"] as? String) ?? "", who: (x[who] as? String) ?? "",
                     status: (x["status"] as? String) ?? "", due: (x["due_date"] as? String) ?? "")
            }
        }
        let assets = (o["assets"] as? [[String: Any]]) ?? []
        let rec = assets.first { ["video", "audio"].contains(($0["kind"] as? String) ?? "") }
        let tr = assets.first { ($0["kind"] as? String) == "transcript_md" }
        var an: Numbers?
        if let a = o["analysis"] as? [String: Any] {
            var n = Numbers()
            n.tipsShown = (a["tips_shown"] as? Int) ?? 0
            let useful = (a["tips_rated_useful"] as? Int) ?? 0, not = (a["tips_not_useful"] as? Int) ?? 0
            n.usefulShare = useful + not > 0 ? Double(useful) / Double(useful + not) : nil
            n.askNow = (a["ask_now_count"] as? Int) ?? 0
            n.talkMedian = (a["talk_ratio_me"] as? Double) ?? (a["talk_ratio_me"] as? Int).map(Double.init)
            n.topicsHit = (a["sheet_topics_hit"] as? Int) ?? 0; n.topicsTotal = (a["sheet_topics_total"] as? Int) ?? 0
            an = n
        }
        var sheet: Data?
        if let s = (o["sheet"] as? [String: Any])?["sheet"] { sheet = try? JSONSerialization.data(withJSONObject: s) }
        return Detail(id: id, title: o["title"] as? String, isPrivate: (o["is_private"] as? Bool) == true, start: date(o["started_at"]),
                      durationS: (o["duration_s"] as? Int) ?? 0, callType: (o["call_type"] as? String) ?? "",
                      summary: ((o["summary"] as? [String: Any])?["body_md"] as? String) ?? "",
                      decisions: lines("decisions", who: "made_by"), tasks: lines("tasks", who: "assignee"),
                      risks: lines("risks", who: "said_by"),
                      participants: ((o["participants"] as? [[String: Any]]) ?? []).map {
                          (($0["display_name"] as? String) ?? "", ($0["speaker_seconds"] as? Int) ?? 0, ($0["is_internal"] as? Bool) == true)
                      },
                      analysis: an, sheet: sheet, recording: driveURL(rec?["web_view_link"]), transcript: driveURL(tr?["web_view_link"]))
    }

    // MARK: words

    /// 0.42 -> "42%"; nil -> "-".
    public static func percent(_ v: Double?) -> String { v.map { "\(Int(($0 * 100).rounded()))%" } ?? "-" }

    /// 1.5 -> "1.5", 2.0 -> "2".
    public static func hours(_ v: Double) -> String { v == v.rounded() ? "\(Int(v))" : String(format: "%.1f", v) }

    /// 1800 -> "30 min", 5400 -> "1 h 30 min".
    public static func length(_ s: Int) -> String {
        let m = s / 60, h = m / 60, r = m % 60
        return h == 0 ? "\(r) min" : (r == 0 ? "\(h) h" : "\(h) h \(r) min")
    }
}
