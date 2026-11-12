import Foundation

/// 0.10.0 (AI chain, owner 12.11): one fallback chain for every job. The AI chosen for the job goes first, then the
/// other connected AIs in the order the PM sets in Settings > AI (a reorderable list with on/off checkboxes). Live
/// tips never go to the model on this Mac (19-59 s) or to the Gemini account (agy, 20-30 s a request); for the
/// preparation, after-call jobs and typed questions the model on this Mac is always the last step. Shared with
/// livetips_m0.routing (LT_AI_CHAIN, sidecar-config ai.chain). Pure, for CoreChecks.
public enum AIChain {
    public struct Entry: Codable, Equatable, Hashable, Sendable {
        public var route: String
        public var on: Bool
        public init(_ route: String, on: Bool = true) { self.route = route; self.on = on }
    }

    /// Claude account, ChatGPT account, Claude API, OpenAI API, Gemini API, Gemini account (agy), model on this Mac.
    public static let defaultOrder = ["code", "codex", "api", "openai", "gemini", "agy", "local"]
    public static let jobs = ["tips", "prep", "after"]

    public static func defaults(localOn: Bool = true) -> [Entry] {
        defaultOrder.map { Entry($0, on: $0 == "local" ? localOn : true) }
    }

    /// Unknown routes dropped, the first of a duplicate kept, a missing route added (on) in the default order.
    public static func normalized(_ chain: [Entry]) -> [Entry] {
        var seen = Set<String>(), out: [Entry] = []
        for e in chain where defaultOrder.contains(e.route) && !seen.contains(e.route) { seen.insert(e.route); out.append(e) }
        for r in defaultOrder where !seen.contains(r) { out.append(Entry(r)) }
        return out
    }

    /// Live tips never run on the model on this Mac or on the Gemini account: too slow for a call.
    public static func allowed(_ route: String, job: String) -> Bool {
        job == "tips" ? !["local", "agy"].contains(route) : true
    }

    /// The order a job tries its AIs: the chosen one first (even when it is not connected: the caller says why it
    /// cannot run), then the connected AIs that are on, in the PM's order; the model on this Mac always last.
    /// `auto` off (Settings > AI > switch automatically): the chosen AI only.
    public static func order(job: String, chosen: String, chain: [Entry], connected: Set<String>, auto: Bool = true) -> [String] {
        var out = [chosen]
        guard auto else { return out }
        var local = false
        for e in normalized(chain) where e.on && e.route != chosen && connected.contains(e.route) && allowed(e.route, job: job) {
            if e.route == "local" { local = true } else { out.append(e.route) }
        }
        if local { out.append("local") }
        return out
    }

    /// The enabled routes in the PM's order, for the engine (it applies the same job rules).
    public static func enabled(_ chain: [Entry]) -> [String] { normalized(chain).filter { $0.on }.map { $0.route } }

    /// The next AI to try: the first of `order` not yet tried that can run now.
    public static func next(_ order: [String], tried: Set<String>, usable: (String) -> Bool) -> String? {
        order.first { !tried.contains($0) && usable($0) }
    }

    /// Moves one entry up (-1) or down (+1); the list stays as it is at the ends.
    public static func move(_ chain: [Entry], route: String, by step: Int) -> [Entry] {
        var c = normalized(chain)
        guard let i = c.firstIndex(where: { $0.route == route }) else { return c }
        let j = i + step
        guard j >= 0, j < c.count else { return c }
        c.swapAt(i, j)
        return c
    }

    public static func setOn(_ chain: [Entry], route: String, on: Bool) -> [Entry] {
        normalized(chain).map { $0.route == route ? Entry($0.route, on: on) : $0 }
    }
}

/// 0.10.0 (AI chain): the shared out-state of every AI (state/ai-routes.json, written by the app and the engine):
/// {"codex": {"down": true, "reason": "limit", "since": t, "checked": t, "until": t}}. An AI out with a known reset
/// time (`until`) is tried again at that time; without one every 15 minutes. It goes back to work once it answers.
public enum AIOut {
    public static let recheckS: Double = 900

    public struct State: Equatable, Sendable {
        public var down = false
        public var reason = ""
        public var since: Double?
        public var checked: Double?
        public var until: Double?
        public init(down: Bool = false, reason: String = "", since: Double? = nil, checked: Double? = nil, until: Double? = nil) {
            self.down = down; self.reason = reason; self.since = since; self.checked = checked; self.until = until
        }
    }

    private static func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

    public static func parse(_ o: [String: Any]) -> [String: State] {
        var out: [String: State] = [:]
        for (k, v) in o {
            guard let d = v as? [String: Any] else { continue }
            out[k] = State(down: (d["down"] as? Bool) ?? false, reason: (d["reason"] as? String) ?? "",
                           since: num(d["since"]), checked: num(d["checked"]), until: num(d["until"]))
        }
        return out
    }

    /// When the AI is tried again: its reset time when known, else 15 minutes after the last check.
    public static func nextCheck(_ s: State) -> Double? {
        guard s.down else { return nil }
        if let u = s.until { return u }
        return (s.checked ?? s.since).map { $0 + recheckS }
    }

    /// The AI may be tried now: it is not out, or its next check is due.
    public static func due(_ s: State?, now: Double) -> Bool {
        guard let s = s, s.down else { return true }
        guard let n = nextCheck(s) else { return true }
        return now >= n
    }

    /// The reset time in an error text: "try again at 12:48 PM", "resets 3pm", "resets at 15:30", "reset at 3:05 pm
    /// (Europe/Kyiv)", "try again in 2 hours 5 minutes", "in 37 minutes", "resets_at": 1793731185. The next such clock
    /// time after `now` in `calendar`'s time zone; nil when the text names none.
    public static func resetTime(_ text: String, now: Date, calendar: Calendar = .current) -> Date? {
        let t = text.lowercased()
        func groups(_ pattern: String) -> [String]? {
            guard let rx = try? NSRegularExpression(pattern: pattern),
                  let m = rx.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) else { return nil }
            return (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : String(t[Range(r, in: t)!])
            }
        }
        if let g = groups(#"resets?_?at"?\s*[:=]\s*(\d{9,11})"#) ?? groups(#"limit reached\|(\d{9,11})"#), let v = Double(g[1]) {
            return Date(timeIntervalSince1970: v)          // also Claude Code's "usage limit reached|<unix time>"
        }
        if let g = groups(#"(?:try again|reset[s]?|available again)\s+in\s+((?:\d+\s*(?:days?|d|hours?|hrs?|h|minutes?|mins?|m)\b[\s,]*(?:and\s+)?)+)"#) {
            var secs = 0.0
            if let rx = try? NSRegularExpression(pattern: #"(\d+)\s*(days?|d|hours?|hrs?|h|minutes?|mins?|m)\b"#) {
                let s = g[1]
                for m in rx.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                    let n = Double(String(s[Range(m.range(at: 1), in: s)!])) ?? 0
                    let u = String(s[Range(m.range(at: 2), in: s)!])
                    secs += n * (u.hasPrefix("d") ? 86400 : u.hasPrefix("h") ? 3600 : 60)
                }
            }
            if secs > 0 { return now.addingTimeInterval(secs) }
        }
        guard let g = groups(#"(?:try again at|resets? at|resets|reset|available again at)\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?"#) else { return nil }
        var h = Int(g[1]) ?? 0
        let m = Int(g[2]) ?? 0
        let ap = g[3]
        if ap.hasPrefix("p"), h < 12 { h += 12 }
        if ap.hasPrefix("a"), h == 12 { h = 0 }
        if g[2].isEmpty && ap.isEmpty { return nil }          // "resets 5" is not a time
        guard h < 24, m < 60 else { return nil }
        var c = calendar.dateComponents([.year, .month, .day], from: now)
        c.hour = h; c.minute = m; c.second = 0
        guard var d = calendar.date(from: c) else { return nil }
        if d <= now { d = calendar.date(byAdding: .day, value: 1, to: d) ?? d }
        return d
    }
}

/// 0.10.0 (AI chain): what the accounts report about their own limits. Claude Code prints a `rate_limit_event` in
/// stream-json (rate_limit_info.unifiedWindows.five_hour / seven_day: utilization 0-1, resetsAt); Codex logs
/// `rate_limits` (primary / secondary: used_percent, window_minutes, resets_at). The latest per account lives in
/// state/ai-accounts.json, written by the engine and the app; never a key or a token.
public enum AIAccountUsage {
    public struct Window: Equatable, Sendable {
        public var name: String           // five_hour | seven_day | <minutes>m
        public var usedPercent: Double
        public var resetsAt: Double?
        public init(name: String, usedPercent: Double, resetsAt: Double?) { self.name = name; self.usedPercent = usedPercent; self.resetsAt = resetsAt }
    }
    public struct Usage: Equatable, Sendable {
        public var at: Double
        public var windows: [Window]
        public var limited: Bool          // the account says the limit is reached now
        /// 0.10.0 (status fix): when a reached limit resets (the account's own reset time, or the "try again at 12:48
        /// PM" of a limit error). Persisted, so the state is known at launch and clears itself at that time.
        public var until: Double?
        public init(at: Double, windows: [Window], limited: Bool = false, until: Double? = nil) {
            self.at = at; self.windows = windows; self.limited = limited; self.until = until
        }
        public var maxUsed: Double { windows.map { $0.usedPercent }.max() ?? 0 }
        /// The reset of the fullest window (the one that matters).
        public var resetOfMax: Double? { windows.max { $0.usedPercent < $1.usedPercent }?.resetsAt }
    }

    private static func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init) }

    public static func windowName(minutes: Double) -> String {
        minutes == 300 ? "five_hour" : minutes == 10080 ? "seven_day" : "\(Int(minutes))m"
    }

    /// A Claude Code stream-json line of type rate_limit_event.
    public static func fromClaude(_ ev: [String: Any], now: Double) -> Usage? {
        guard (ev["type"] as? String) == "rate_limit_event", let info = ev["rate_limit_info"] as? [String: Any] else { return nil }
        var ws: [Window] = []
        if let u = info["unifiedWindows"] as? [String: Any] {
            for k in ["five_hour", "seven_day"] {
                if let w = u[k] as? [String: Any], let used = num(w["utilization"]) {
                    ws.append(Window(name: k, usedPercent: (used * 1000).rounded() / 10, resetsAt: num(w["resetsAt"])))
                }
            }
        } else if let used = num(info["utilization"]) {
            ws.append(Window(name: (info["rateLimitType"] as? String) ?? "five_hour", usedPercent: (used * 1000).rounded() / 10, resetsAt: num(info["resetsAt"])))
        }
        guard !ws.isEmpty else { return nil }
        let rejected = (info["status"] as? String) == "rejected"
        return Usage(at: now, windows: ws, limited: rejected,
                     until: rejected ? (num(info["resetsAt"]) ?? ws.compactMap { $0.resetsAt }.max()) : nil)
    }

    /// A Codex `rate_limits` object.
    public static func fromCodex(_ rl: [String: Any], now: Double) -> Usage? {
        var ws: [Window] = []
        for k in ["primary", "secondary"] {
            if let w = rl[k] as? [String: Any], let used = num(w["used_percent"]) {
                ws.append(Window(name: windowName(minutes: num(w["window_minutes"]) ?? 0), usedPercent: used, resetsAt: num(w["resets_at"])))
            }
        }
        guard !ws.isEmpty else { return nil }
        let reached = rl["rate_limit_reached_type"].flatMap { $0 is NSNull ? nil : "\($0)".lowercased() }
        let full = ws.filter { $0.usedPercent >= 100 }
        guard reached != nil || !full.isEmpty else { return Usage(at: now, windows: ws) }
        // the window at 100%, else the one the account names (primary = 5 hours, secondary = the week), else the later
        let named = reached.flatMap { r -> Window? in
            r.contains("primary") ? ws.first(where: { $0.name == "five_hour" }) : r.contains("secondary") ? ws.first(where: { $0.name == "seven_day" }) : nil
        }
        let until = full.compactMap { $0.resetsAt }.max() ?? named?.resetsAt ?? ws.compactMap { $0.resetsAt }.max()
        return Usage(at: now, windows: ws, limited: true, until: until)
    }

    /// 0.10.0 (status fix): a limit error with no numbers ("You've hit your usage limit ... try again at 12:48 PM").
    public static func limitError(until: Double?, now: Double) -> Usage { Usage(at: now, windows: [], limited: true, until: until) }

    /// state/ai-accounts.json: {"code": {"at": t, "limited": false, "windows": [{"name", "used_percent", "resets_at"}]}}
    public static func parseFile(_ o: [String: Any]) -> [String: Usage] {
        var out: [String: Usage] = [:]
        for (k, v) in o {
            guard let d = v as? [String: Any], let at = num(d["at"]) else { continue }
            let ws = ((d["windows"] as? [[String: Any]]) ?? []).compactMap { w -> Window? in
                guard let n = w["name"] as? String, let u = num(w["used_percent"]) else { return nil }
                return Window(name: n, usedPercent: u, resetsAt: num(w["resets_at"]))
            }
            out[k] = Usage(at: at, windows: ws, limited: (d["limited"] as? Bool) ?? false, until: num(d["until"]))
        }
        return out
    }

    public static func encode(_ u: Usage) -> [String: Any] {
        var o: [String: Any] = ["at": u.at, "limited": u.limited, "windows": u.windows.map { w -> [String: Any] in
            var d: [String: Any] = ["name": w.name, "used_percent": w.usedPercent]
            if let r = w.resetsAt { d["resets_at"] = r }
            return d
        }]
        if let t = u.until { o["until"] = t }
        return o
    }

    /// A window whose reset time has passed says nothing about now: it is dropped. A reached limit holds until its
    /// reset time (`until`); without one, while a window it was reported with is still current.
    public static func current(_ u: Usage, now: Double) -> Usage {
        var c = u
        c.windows = u.windows.filter { ($0.resetsAt ?? .infinity) > now }
        if let t = u.until {
            c.limited = u.limited && t > now
            if t <= now { c.until = nil }
        } else if c.windows.isEmpty {
            c.limited = false
        }
        return c
    }

    /// 0.10.0 (status fix): the usage lines of an account: "{pct}% used, resets at {time}" for the 5-hour window,
    /// "{pct}% of the week" for the weekly one; any other window as the 5-hour line.
    public static func lines(_ u: Usage, now: Double, tz: TimeZone = .current) -> [AIStatus.Line] {
        let rank: (Window) -> Int = { $0.name == "five_hour" ? 0 : $0.name == "seven_day" ? 2 : 1 }
        return u.windows.sorted { rank($0) < rank($1) }.map { w in
            let pct = String(format: "%.0f", w.usedPercent)
            if w.name == "seven_day" { return AIStatus.Line("ai.status.usage.week", ["pct": pct]) }
            return w.resetsAt.map { AIStatus.Line("ai.status.usage.account", ["pct": pct, "time": AIStatus.when($0, now: now, tz: tz)]) }
                ?? AIStatus.Line("ai.status.usage.accountNoReset", ["pct": pct])
        }
    }
}

/// 0.10.0 (AI chain): the limit status icon on Home and in the tips window, and its list of connected AIs.
public enum AIStatus {
    public enum Level: String, Equatable, Sendable { case ok, warn, out }

    /// SF Symbols that exist on macOS 14.4: red octagon at a limit, orange triangle close to one, a chip otherwise.
    public static func symbol(_ l: Level) -> String {
        switch l { case .out: return "exclamationmark.octagon.fill"; case .warn: return "exclamationmark.triangle.fill"; case .ok: return "cpu" }
    }

    public static let nearAccountPercent = 95.0
    public static let nearAPIDollars = 1.0

    /// One localized line: a key of en.json / uk.json and its variables.
    public struct Line: Equatable, Sendable {
        public var key: String
        public var vars: [String: String]
        public init(_ key: String, _ vars: [String: String] = [:]) { self.key = key; self.vars = vars }
    }

    public enum State: Equatable, Sendable { case ok, near, limit, out, capped }

    public struct Row: Equatable, Sendable {
        public var route: String
        public var serving: [String]      // jobs this AI does now (chosen and answering, or switched to)
        public var chosenFor: [String]    // jobs that chose it
        public var state: State
        public var status: Line
        public var usage: Line
        public var usageMore: [Line] = []  // 0.10.0 (status fix): the weekly window after the 5-hour one
        public var updatedAt: Double? = nil  // 0.10.0 (owner 12.11): when the account last reported its usage ("updated HH:MM")
    }

    public struct Input {
        public var connected: [String]                    // in the chain's order
        public var chosen: [String: String]               // job -> route (Settings > AI)
        public var chain: [AIChain.Entry]
        public var auto: Bool
        public var out: [String: AIOut.State]
        public var accounts: [String: AIAccountUsage.Usage]
        public var spend: [String: Double]                // provider -> this month's USD
        public var limits: [String: Double]               // provider -> monthly limit USD (0 = none)
        public var now: Double
        public init(connected: [String], chosen: [String: String], chain: [AIChain.Entry], auto: Bool = true,
                    out: [String: AIOut.State] = [:], accounts: [String: AIAccountUsage.Usage] = [:],
                    spend: [String: Double] = [:], limits: [String: Double] = [:], now: Double) {
            self.connected = connected; self.chosen = chosen; self.chain = chain; self.auto = auto; self.out = out
            self.accounts = accounts; self.spend = spend; self.limits = limits; self.now = now
        }
    }

    public static func provider(_ route: String) -> String? {
        switch route { case "api": return "claude"; case "openai": return "openai"; case "gemini": return "gemini"; default: return nil }
    }

    static func money(_ v: Double) -> String { String(format: v >= 100 ? "%.0f" : "%.2f", max(0, v)) }

    public static func hhmm(_ t: Double, tz: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz; f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    /// "HH:mm" today, "EEE HH:mm" on another day (English day names; the app may localize).
    public static func when(_ t: Double, now: Double, tz: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        if cal.isDate(Date(timeIntervalSince1970: t), inSameDayAs: Date(timeIntervalSince1970: now)) { return hhmm(t, tz: tz) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = tz; f.dateFormat = "d MMM HH:mm"
        return f.string(from: Date(timeIntervalSince1970: t))
    }

    /// The AI a job is on now: the first of its chain order that is connected and not out (or due for a check).
    public static func current(job: String, _ i: Input) -> String? {
        guard let chosen = i.chosen[job] else { return nil }
        let order = AIChain.order(job: job, chosen: chosen, chain: i.chain, connected: Set(i.connected), auto: i.auto)
        let capped: (String) -> Bool = { r in
            guard let p = provider(r), let l = i.limits[p], l > 0 else { return false }
            return (i.spend[p] ?? 0) >= l
        }
        return order.first { Set(i.connected).contains($0) && AIOut.due(i.out[$0], now: i.now) && !capped($0) } ?? chosen
    }

    public static func rows(_ i: Input, tz: TimeZone = .current) -> [Row] {
        var serving: [String: [String]] = [:], chosenFor: [String: [String]] = [:]
        for j in AIChain.jobs {
            if let c = i.chosen[j] { chosenFor[c, default: []].append(j) }
            if let r = current(job: j, i) { serving[r, default: []].append(j) }
        }
        var routes = i.connected
        for j in AIChain.jobs { if let c = i.chosen[j], !routes.contains(c) { routes.append(c) } }
        return routes.map { r in
            var st = State.ok
            var status = Line("ai.status.state.ok")
            var usage = Line("ai.status.usage.none")
            var more: [Line] = []
            // 0.10.0 (status fix): an account that has not reported yet says when it will
            let pending = r == "code" ? Line("ai.status.usage.afterClaude") : r == "codex" ? Line("ai.status.usage.afterCodex") : nil
            if let p = provider(r) {
                let spent = i.spend[p] ?? 0, lim = i.limits[p] ?? 0
                if lim > 0 {
                    usage = Line("ai.status.usage.api", ["left": money(lim - spent), "limit": money(lim)])
                    if spent >= lim { st = .capped; status = Line("ai.status.state.capped") }
                    else if lim - spent <= nearAPIDollars { st = .near; status = Line("ai.status.state.near") }
                } else {
                    usage = Line("ai.status.usage.apiNoLimit", ["spent": money(spent)])
                }
            } else if r == "local" {
                usage = Line("ai.status.usage.local")
            } else if let u0 = i.accounts[r] {
                let u = AIAccountUsage.current(u0, now: i.now)
                let ls = AIAccountUsage.lines(u, now: i.now, tz: tz)
                if let f = ls.first { usage = f; more = Array(ls.dropFirst()) } else if let p = pending { usage = p }
                if u.limited || u.maxUsed >= 100 {
                    st = .limit
                    let t = u.until ?? (u.maxUsed >= 100 ? u.resetOfMax : nil)
                    status = t.map { Line("ai.status.state.limitUntil", ["time": when($0, now: i.now, tz: tz)]) } ?? Line("ai.status.state.limit")
                } else if u.maxUsed >= nearAccountPercent {
                    st = .near; status = Line("ai.status.state.near")
                }
            } else if let p = pending {
                usage = p
            }
            if let o = i.out[r], o.down, !(AIOut.due(o, now: i.now) && o.until != nil) {
                // an AI out with a reset time that has passed shows as OK until it fails again
                let isLimit = ["limit", "credit"].contains(o.reason)
                if AIOut.due(o, now: i.now) {
                    st = isLimit ? .limit : .out; status = Line("ai.status.state.checking")
                } else if isLimit, let u = o.until {
                    st = .limit; status = Line("ai.status.state.limitUntil", ["time": when(u, now: i.now, tz: tz)])
                } else if let n = AIOut.nextCheck(o) {
                    st = isLimit ? .limit : .out
                    status = Line("ai.status.state.outUntil", ["reason": "ai.reason." + (o.reason.isEmpty ? "error" : o.reason), "time": when(n, now: i.now, tz: tz)])
                } else {
                    st = isLimit ? .limit : .out; status = Line("ai.status.state.out")
                }
            }
            return Row(route: r, serving: serving[r] ?? [], chosenFor: chosenFor[r] ?? [], state: st, status: status, usage: usage, usageMore: more,
                       updatedAt: provider(r) == nil && r != "local" ? i.accounts[r]?.at : nil)
        }
    }

    /// Red: an AI the current jobs chose or use is at a limit or out. Orange: one of them is close to a limit
    /// (>= 95% of an account, <= $1 left of an API's monthly limit). Neutral otherwise.
    public static func level(_ rows: [Row]) -> Level {
        let used = rows.filter { !$0.serving.isEmpty || !$0.chosenFor.isEmpty }
        if used.contains(where: { [.limit, .out, .capped].contains($0.state) }) { return .out }
        if used.contains(where: { $0.state == .near }) { return .warn }
        return .ok
    }

    /// The jobs line of a row: what it does now, and a chosen job that went elsewhere.
    public static func jobsLines(_ r: Row) -> [Line] {
        var out: [Line] = []
        if !r.serving.isEmpty { out.append(Line("ai.status.jobs.now", ["jobs": r.serving.map { "ai.status.job." + $0 }.joined(separator: ",")])) }
        let moved = r.chosenFor.filter { !r.serving.contains($0) }
        if !moved.isEmpty { out.append(Line("ai.status.jobs.moved", ["jobs": moved.map { "ai.status.job." + $0 }.joined(separator: ",")])) }
        if out.isEmpty { out.append(Line("ai.status.jobs.none")) }
        return out
    }
}

/// 0.10.0 (owner 12.11): when the app runs the light usage probe of an account (livetips_m0.usage_probe): at launch
/// after 60 s, then every 30 minutes while no call is recording and no preparation runs, and when the status popover
/// opens with numbers older than 10 minutes. At most one probe per account per 10 minutes; never for an account that is
/// signed out or at its limit (until its reset time). Pure, for CoreChecks.
public enum AIUsageProbePlan {
    public static let routes = ["code", "codex"]
    public static let firstDelay: Double = 60
    public static let every: Double = 1800
    public static let minGap: Double = 600
    public static let staleAfter: Double = 600

    /// Until when an account is not probed: a reported limit (until its reset), or an out state not yet due.
    public static func blockedUntil(usage: AIAccountUsage.Usage?, out: AIOut.State?, now: Double) -> Double? {
        var until: Double?
        if let u0 = usage {
            let u = AIAccountUsage.current(u0, now: now)
            if u.limited || u.maxUsed >= 100 { until = u.until ?? u.resetOfMax ?? (now + AIOut.recheckS) }
        }
        if let o = out, o.down, !AIOut.due(o, now: now) {
            let t = o.until ?? AIOut.nextCheck(o) ?? (now + AIOut.recheckS)
            until = max(until ?? t, t)
        }
        return until
    }

    /// Whether to probe this account now. `reportedAt`: when the account last reported its usage (any run).
    public static func due(signedIn: Bool, busy: Bool, reportedAt: Double?, blockedUntil: Double?, lastProbe: Double?, now: Double) -> Bool {
        guard signedIn, !busy else { return false }
        if let b = blockedUntil, b > now { return false }
        if let l = lastProbe, now - l < minGap { return false }
        if let r = reportedAt, now - r < staleAfter { return false }
        return true
    }
}
