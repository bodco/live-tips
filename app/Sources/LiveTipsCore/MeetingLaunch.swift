import Foundation

// 0.9.6 (owner, 2026-11-09): one calendar row per meeting, and Start call opens the meeting in the right place.
// Pure logic only (CoreChecks covers it); the app side is LiveTips/MeetingLauncher.swift.

// MARK: - One row per meeting

public enum CalendarDedup {
    /// The meeting link without what differs between two invitations of the same meeting: scheme, "www.",
    /// a trailing slash, the query (authuser, pwd, hs) and the fragment. Lowercased.
    public static func normalizedLink(_ link: String?) -> String? {
        guard var s = link?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !s.isEmpty else { return nil }
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if s.hasPrefix("www.") { s = String(s.dropFirst(4)) }
        if let i = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = String(s[..<i]) }
        while s.hasSuffix("/") { s.removeLast() }
        return s.isEmpty ? nil : s
    }

    /// The same meeting invited to two connected accounts (owner: the same link and the same start are enough; the
    /// attendees are not compared). A row without a link falls back to its iCalendar UID and start.
    /// Returns, for each kept row, the indices of all its copies, the kept one first; the input order is kept.
    public static func groups(link: [String?], uid: [String?], start: [Date]) -> [[Int]] {
        var byKey: [String: Int] = [:]
        var out: [[Int]] = []
        for i in start.indices {
            let t = String(Int(start[i].timeIntervalSince1970))
            var keys: [String] = []
            if let l = normalizedLink(link[i]) { keys.append("l:" + l + "@" + t) }
            if let u = uid[i]?.lowercased(), !u.isEmpty { keys.append("u:" + u + "@" + t) }
            if let g = keys.compactMap({ byKey[$0] }).first {
                out[g].append(i)
                for k in keys where byKey[k] == nil { byKey[k] = g }
            } else {
                out.append([i])
                for k in keys { byKey[k] = out.count - 1 }
            }
        }
        return out
    }
}

// MARK: - Where a meeting opens

public enum MeetingPlatform: String, Codable, CaseIterable {
    case meet, teams, zoom, other

    public static func of(_ link: String?) -> MeetingPlatform {
        let l = (link ?? "").lowercased()
        if l.contains("meet.google.com") { return .meet }
        if l.contains("teams.microsoft.com") || l.contains("teams.live.com") { return .teams }
        if l.contains("zoom.us") || l.hasPrefix("zoommtg:") { return .zoom }
        return .other
    }
}

/// One way to open a meeting: where (a Chrome profile, the Google Meet app of a profile, a native app, the default
/// browser) and as whom (the Google account to join with). A profile is named by its signed-in email, or by its
/// display name when it has none, never by its folder: the same profile is "Profile 3" on one Mac and "Profile 1" on
/// another, and the folder is found on this Mac at launch.
public struct LaunchWay: Codable, Hashable, Identifiable {
    public enum Kind: String, Codable { case chrome, meetApp, teamsApp, zoomApp, browser }
    public var kind: Kind
    public var profile: String          // the profile's email or display name; "" for a native app or the default browser
    public var account: String          // the account to join as; "" = the profile's own
    public init(kind: Kind, profile: String = "", account: String = "") {
        self.kind = kind; self.profile = profile.lowercased()
        let a = account.lowercased()
        self.account = a == self.profile ? "" : a
    }

    /// The account the meeting is joined with: the chosen one, else the profile's own email.
    public var joinAs: String { account.isEmpty ? (profile.contains("@") ? profile : "") : account }

    /// "chrome:mike@orbit.com", "meetApp:mike@orbit.com|mike@acme.com", "teamsApp", "browser".
    public var id: String {
        guard !profile.isEmpty else { return kind.rawValue }
        return kind.rawValue + ":" + profile + (account.isEmpty ? "" : "|" + account)
    }
    public init?(id: String) {
        let p = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard let k = p.first.flatMap(Kind.init(rawValue:)) else { return nil }
        let rest = p.count > 1 ? p[1].split(separator: "|", maxSplits: 1).map(String.init) : []
        self.init(kind: k, profile: rest.first ?? "", account: rest.count > 1 ? rest[1] : "")
    }
}

/// A Chrome profile: its folder, display name, signed-in email and the Google accounts Chrome knows in it.
public struct ChromeProfile: Hashable {
    public var dir: String, name: String, email: String
    public var accounts: [String]
    public init(dir: String, name: String, email: String, accounts: [String] = []) {
        self.dir = dir; self.name = name; self.email = email.lowercased(); self.accounts = accounts.map { $0.lowercased() }
    }
    /// How a LaunchWay names this profile.
    public var key: String { email.isEmpty ? name.lowercased() : email }

    /// Chrome's "Local State": profile.info_cache.
    public static func parse(localState: Data) -> [ChromeProfile] {
        guard let o = try? JSONSerialization.jsonObject(with: localState) as? [String: Any],
              let cache = (o["profile"] as? [String: Any])?["info_cache"] as? [String: Any] else { return [] }
        return cache.compactMap { dir, v -> ChromeProfile? in
            guard let d = v as? [String: Any] else { return nil }
            return ChromeProfile(dir: dir, name: d["name"] as? String ?? dir, email: d["user_name"] as? String ?? "")
        }.sorted { $0.dir.localizedStandardCompare($1.dir) == .orderedAscending }
    }

    /// A profile's "Preferences": account_info[].email.
    public static func accounts(preferences: Data) -> [String] {
        guard let o = try? JSONSerialization.jsonObject(with: preferences) as? [String: Any],
              let list = o["account_info"] as? [[String: Any]] else { return [] }
        return list.compactMap { ($0["email"] as? String)?.lowercased() }
    }

    /// The folder of a LaunchWay's profile on this Mac; nil when this Mac has no such profile.
    public static func dir(for key: String, in profiles: [ChromeProfile]) -> String? {
        let k = key.lowercased()
        return (profiles.first { !$0.email.isEmpty && $0.email == k } ?? profiles.first { $0.email.isEmpty && $0.name.lowercased() == k })?.dir
    }
}

/// What this Mac has: Chrome profiles, the profiles with the Google Meet app, native Teams and Zoom.
public struct LaunchEnvironment {
    public var profiles: [ChromeProfile]
    public var meetAppDirs: [String]     // folders of the profiles with the Google Meet app installed
    public var teamsApp: Bool, zoomApp: Bool
    public init(profiles: [ChromeProfile], meetAppDirs: [String] = [], teamsApp: Bool = false, zoomApp: Bool = false) {
        self.profiles = profiles; self.meetAppDirs = meetAppDirs; self.teamsApp = teamsApp; self.zoomApp = zoomApp
    }

    /// Every way this platform can open on this Mac, in a neutral order (native apps first, then Chrome profiles).
    /// `invited`: the connected accounts invited to the meeting. For Meet, each is offered in the Meet app of every
    /// profile that has it (a work account often lives inside one profile next to its own email), and in a Chrome
    /// profile that knows it; otherwise a profile joins as its own email.
    public func ways(for p: MeetingPlatform, invited: [String] = []) -> [LaunchWay] {
        let inv = invited.map { $0.lowercased() }.filter { $0.contains("@") }
        var w: [LaunchWay] = []
        func add(_ x: LaunchWay) { if !w.contains(x) { w.append(x) } }
        switch p {
        case .meet:
            let apps = profiles.filter { meetAppDirs.contains($0.dir) }
            if inv.isEmpty { for pr in apps { add(LaunchWay(kind: .meetApp, profile: pr.key)) } }
            for a in inv {      // the profile that knows the account first
                let knows = apps.filter { $0.email == a || $0.accounts.contains(a) }
                for pr in knows + apps.filter({ !knows.contains($0) }) { add(LaunchWay(kind: .meetApp, profile: pr.key, account: a)) }
            }
            for pr in profiles {
                let known = inv.filter { $0 == pr.email || pr.accounts.contains($0) }
                if known.isEmpty { add(LaunchWay(kind: .chrome, profile: pr.key)) }
                for a in known { add(LaunchWay(kind: .chrome, profile: pr.key, account: a)) }
            }
        case .teams, .zoom, .other:
            if p == .teams && teamsApp { add(LaunchWay(kind: .teamsApp)) }
            if p == .zoom && zoomApp { add(LaunchWay(kind: .zoomApp)) }
            for pr in profiles { add(LaunchWay(kind: .chrome, profile: pr.key)) }
        }
        add(LaunchWay(kind: .browser))
        return w
    }
}

/// One start of a meeting: what was opened and whether the PM said it was right.
public struct LaunchRecord: Codable, Equatable {
    public var at: Date
    public var platform: MeetingPlatform
    public var series: String           // CalEvent.seriesKey ("" for a call without an event)
    public var organizer: String        // the domain of the invitation, for a series not seen yet
    public var way: String              // LaunchWay.id
    public var ok: Bool                 // false: "Wrong place" was pressed
    public init(at: Date, platform: MeetingPlatform, series: String, organizer: String, way: String, ok: Bool) {
        self.at = at; self.platform = platform; self.series = series; self.organizer = organizer; self.way = way; self.ok = ok
    }
}

public enum LaunchRanking {
    /// The ways in the order to offer them. A pinned way (Settings) is first; then what worked for this series,
    /// then for this invitation's domain, then for the platform (more starts first, the latest breaks a tie); a way
    /// marked wrong for the series goes to the end. A way invited through one of the event's accounts comes before
    /// the rest at the same score. `auto` is true when the first way may open without asking: it has worked for
    /// this series or domain and nothing was marked wrong since.
    public static func rank(_ ways: [LaunchWay], history: [LaunchRecord], platform: MeetingPlatform, series: String,
                            organizer: String, invited: [String] = [], pinned: String? = nil) -> (ways: [LaunchWay], auto: Bool) {
        let inv = Set(invited.map { $0.lowercased() })
        let mine = history.filter { $0.platform == platform }
        func score(_ w: LaunchWay) -> (Int, Int, Int, Int, Double) {
            let s = mine.filter { $0.way == w.id && !series.isEmpty && $0.series == series }
            let o = mine.filter { $0.way == w.id && !organizer.isEmpty && $0.organizer == organizer && $0.ok }
            let a = mine.filter { $0.way == w.id && $0.ok }
            let sOK = s.filter(\.ok).count
            let lastBad = s.last.map { !$0.ok } ?? false
            let latest = (s + o + a).map { $0.at.timeIntervalSince1970 }.max() ?? 0
            return (lastBad ? -1 : sOK, o.count, a.count, inv.contains(w.joinAs) ? 1 : 0, latest)
        }
        let order = ways.enumerated().sorted { x, y in
            if pinned == x.element.id { return true }
            if pinned == y.element.id { return false }
            let a = score(x.element), b = score(y.element)
            if a != b { return a > b }
            return x.offset < y.offset
        }.map(\.element)
        guard let first = order.first else { return ([], false) }
        if pinned == first.id { return (order, true) }
        let sc = score(first)
        return (order, sc.0 > 0 || (sc.0 == 0 && sc.1 > 0))
    }
}

public enum MeetingURL {
    /// The URL a way opens. Meet in a Chrome profile or the Meet app gets authuser=<email>, so a profile with
    /// several Google accounts joins with the chosen one. Teams in a browser asks to stay on the web.
    public static func forWay(_ link: String, _ w: LaunchWay) -> String {
        switch (MeetingPlatform.of(link), w.kind) {
        case (.meet, .chrome), (.meet, .meetApp):
            guard !w.joinAs.isEmpty else { return link }
            return setQuery(link, "authuser", w.joinAs)
        case (.teams, .chrome), (.teams, .browser):
            return setQuery(setQuery(link, "msLaunch", "false"), "suppressPrompt", "true")
        case (.zoom, .zoomApp):
            return zoomApp(link) ?? link
        default: return link
        }
    }

    /// https://orbit.zoom.us/j/123456789?pwd=abc -> zoommtg://zoom.us/join?confno=123456789&pwd=abc
    public static func zoomApp(_ link: String) -> String? {
        guard let u = URLComponents(string: link), let host = u.host, host.hasSuffix("zoom.us") else { return nil }
        let parts = u.path.split(separator: "/")
        guard let i = parts.firstIndex(where: { $0 == "j" || $0 == "w" || $0 == "s" }), i + 1 < parts.count else { return nil }
        var z = URLComponents(); z.scheme = "zoommtg"; z.host = "zoom.us"; z.path = "/join"
        var q = [URLQueryItem(name: "action", value: "join"), URLQueryItem(name: "confno", value: String(parts[i + 1]))]
        if let pwd = u.queryItems?.first(where: { $0.name == "pwd" })?.value { q.append(URLQueryItem(name: "pwd", value: pwd)) }
        z.queryItems = q
        return z.string
    }

    static func setQuery(_ link: String, _ name: String, _ value: String) -> String {
        guard var u = URLComponents(string: link) else { return link }
        var q = (u.queryItems ?? []).filter { $0.name != name }
        q.append(URLQueryItem(name: name, value: value))
        u.queryItems = q
        return u.string ?? link
    }
}
