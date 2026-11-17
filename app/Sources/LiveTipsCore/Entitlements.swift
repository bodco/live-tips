import CryptoKit
import Foundation

/// 0.18.0 (B3, D41; contract claude/b6-entitlements-contract.md, spec research/pacenote-b2-entitlements-spec-2026-11-17.md):
/// what the person's plan opens, per organization. The server (0.9.0) signs each organization's record with Ed25519
/// (JWS compact, `alg: EdDSA`, `kid`); the app trusts only that signature, checked with the public keys built in here,
/// and checks it again every time the cache is read. Offline never takes anything away (spec 6.3).
public enum Entitlements {
    /// Public keys (kid -> raw 32 bytes, base64url). Rotation: a new key ships in an app release first, the server
    /// switches to it later, the old one goes a release after that. `GET /v1/entitlements/keys` is never trusted instead.
    public static let builtInKeys: [String: String] = ["pn-ent-1": "1VxOKsFcBMYehhiPLSEPQLCUbBqO83CNDaCaBTO8LoA"]
    /// Sent with every request to the Pacenote server: plan answers come as 403 `type: plan`, quotas as 402 `type: quota`.
    public static let problemsHeader = (name: "Pacenote-Problems", value: "2")
    public static let refreshEvery: TimeInterval = 6 * 3600
    public static let entitlementsPath = "/v1/entitlements"
    public static let catalogPath = "/v1/catalog"

    // MARK: JWS

    static func unb64url(_ s: Substring) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    /// The payload of a token signed by one of `keys`; nil when malformed, by an unknown key or not matching.
    public static func verify(_ token: String, keys: [String: String] = builtInKeys) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let hd = unb64url(parts[0]), let bd = unb64url(parts[1]), let sig = unb64url(parts[2]),
              let head = (try? JSONSerialization.jsonObject(with: hd)) as? [String: Any],
              head["alg"] as? String == "EdDSA", let kid = head["kid"] as? String,
              let x = keys[kid], let raw = unb64url(Substring(x)),
              let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return nil }
        guard pub.isValidSignature(sig, for: Data((parts[0] + "." + parts[1]).utf8)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: bd)) as? [String: Any]
    }

    // MARK: the record of one organization

    public struct Module: Equatable {
        public var level: String
        public var source: String          // catalog / plan / override
        public var requiredPlan: String?   // the cheapest visible plan with a higher level
        public init(level: String, source: String = "catalog", requiredPlan: String? = nil) {
            self.level = level; self.source = source; self.requiredPlan = requiredPlan
        }
    }
    public struct Quota: Equatable {
        public var limit: Double?          // nil: no limit of the plan
        public var used: Double
        public var state: String           // ok / warn / exhausted
        public var perSeat: Double?
        public var period: String?
        public var resetsAt: Date?
        public var balance: Double
        public init(limit: Double?, used: Double = 0, state: String = "ok", perSeat: Double? = nil, period: String? = nil,
                    resetsAt: Date? = nil, balance: Double = 0) {
            self.limit = limit; self.used = used; self.state = state; self.perSeat = perSeat; self.period = period
            self.resetsAt = resetsAt; self.balance = balance
        }
    }
    public struct Price: Equatable {
        public var amountCents: Int; public var currency: String; public var per: String; public var minSeats: Int
        public init(amountCents: Int, currency: String, per: String, minSeats: Int) {
            self.amountCents = amountCents; self.currency = currency; self.per = per; self.minSeats = minSeats
        }
    }
    /// D42 (spec 11): a trial of the plan, inside the signed record. Before billing (B10) the plan simply continues
    /// after `endsAt`; with billing the server moves the organization to the default plan. The app never lowers
    /// anything by the date itself.
    public struct Trial: Equatable {
        public var days: Int
        public var startedAt: Date?
        public var endsAt: Date
        public var state: String           // active / ended
        public init(days: Int, startedAt: Date? = nil, endsAt: Date, state: String) {
            self.days = days; self.startedAt = startedAt; self.endsAt = endsAt; self.state = state
        }
        public var ended: Bool { state == "ended" }
        /// Whole days left, rounded up (0 when over).
        public func daysLeft(now: Date) -> Int { max(0, Int((endsAt.timeIntervalSince(now) / 86400).rounded(.up))) }
    }
    public struct Plan: Equatable {
        public var id: String?             // nil for a hidden plan (Internal): never shown
        public var name: String?
        public var version: Int
        public var latestVersion: Int
        public var displayAs: String       // "Custom" for a hidden plan
        public var plannedPrice: Price?
        public var trial: Trial? = nil
        /// What to call the plan: `display_as`, "Custom" for a hidden one.
        public var label: String { displayAs.isEmpty ? (name ?? "Custom") : displayAs }
    }
    public struct Record: Equatable {
        public var orgID: String
        public var sub: String
        public var deviceID: String
        public var issued: Date
        public var expires: Date
        public var plan: Plan
        public var canRequestPlan: Bool
        public var modules: [String: Module]
        public var quotas: [String: Quota]
        /// 0.19.0 (D45, server 0.11.0): the organization's analytics policy, `on` or `member_choice`; nil for the
        /// personal space and from a server before 0.11.0.
        public var usageAnalytics: String? = nil
    }

    static func num(_ v: Any?) -> Double? { (v as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.doubleValue } }
    static func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        let f = ISO8601DateFormatter(); if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.date(from: s)
    }

    /// A verified payload as a record; nil when a required field is missing.
    public static func record(_ p: [String: Any]) -> Record? {
        guard let org = p["org_id"] as? String, let sub = p["sub"] as? String, let dev = p["device_id"] as? String,
              let iat = num(p["iat"]), let exp = num(p["exp"]), let pl = p["plan"] as? [String: Any] else { return nil }
        let price = (pl["planned_price"] as? [String: Any]).flatMap { d -> Price? in
            guard let a = num(d["amount_cents"]) else { return nil }
            return Price(amountCents: Int(a), currency: (d["currency"] as? String) ?? "USD", per: (d["per"] as? String) ?? "",
                         minSeats: Int(num(d["min_seats"]) ?? 1))
        }
        let plan = Plan(id: pl["id"] as? String, name: pl["name"] as? String, version: Int(num(pl["version"]) ?? 1),
                        latestVersion: Int(num(pl["latest_version"]) ?? num(pl["version"]) ?? 1),
                        displayAs: (pl["display_as"] as? String) ?? (pl["name"] as? String) ?? "", plannedPrice: price,
                        trial: (pl["trial"] as? [String: Any]).flatMap { t -> Trial? in
                            guard let e = date(t["ends_at"]) else { return nil }
                            let st = (t["state"] as? String) ?? "active"
                            return Trial(days: Int(num(t["days"]) ?? 0), startedAt: date(t["started_at"]), endsAt: e,
                                         state: st == "ended" ? "ended" : "active")
                        })
        var mods: [String: Module] = [:]
        for (k, v) in (p["modules"] as? [String: Any]) ?? [:] {
            guard let m = v as? [String: Any], let l = m["level"] as? String else { continue }
            mods[k] = Module(level: l, source: (m["source"] as? String) ?? "plan", requiredPlan: m["required_plan"] as? String)
        }
        var qs: [String: Quota] = [:]
        for (k, v) in (p["quotas"] as? [String: Any]) ?? [:] {
            guard let q = v as? [String: Any] else { continue }
            qs[k] = Quota(limit: num(q["limit"]), used: num(q["used"]) ?? 0, state: (q["state"] as? String) ?? "ok",
                          perSeat: num(q["per_seat"]), period: q["period"] as? String, resetsAt: date(q["resets_at"]),
                          balance: num(q["balance"]) ?? 0)
        }
        return Record(orgID: org.lowercased(), sub: sub.lowercased(), deviceID: dev.lowercased(),
                      issued: Date(timeIntervalSince1970: iat), expires: Date(timeIntervalSince1970: exp), plan: plan,
                      canRequestPlan: (p["can_request_plan"] as? Bool) == true, modules: mods, quotas: qs,
                      usageAnalytics: (p["usage_analytics"] as? String).flatMap { ["on", "member_choice"].contains($0) ? $0 : nil })
    }

    // MARK: the catalog

    public struct CatalogModule: Equatable {
        public var id: String; public var kind: String; public var levels: [String]; public var defaultLevel: String
        public var available: Bool; public var gateable: Bool
        public init(_ id: String, _ kind: String, _ levels: [String], _ def: String, available: Bool = true, gateable: Bool = true) {
            self.id = id; self.kind = kind; self.levels = levels; self.defaultLevel = def; self.available = available; self.gateable = gateable
        }
        public func rank(_ level: String) -> Int { levels.firstIndex(of: level) ?? 0 }
    }
    public struct Catalog: Equatable {
        public var version: Int
        public var modules: [String: CatalogModule]
        public var quotaModule: [String: String]          // quota id -> module id
        /// The levels and limits of the default plan (Solo, latest version): offline for a signed-in app without a valid cache.
        public var fallbackModules: [String: String]
        public var fallbackQuotas: [String: Double?]
    }

    /// Catalog version 1 (server `catalog.yaml`, 0.9.0), for an app that has never fetched one. Local modules open
    /// at their default (D41.1), server and metered closed.
    public static let builtInCatalog: Catalog = {
        let on = ["off", "on"]
        let ms: [CatalogModule] = [
            .init("live_tips", "local", on, "on"), .init("meeting_sheet", "local", ["off", "quick", "expert"], "expert"),
            .init("presentation", "local", on, "on"), .init("recording", "local", ["off", "audio", "video"], "video"),
            .init("drive", "local", on, "on"), .init("transcribe", "local", on, "on"), .init("search", "local", on, "on"),
            .init("series", "local", on, "on"), .init("followup", "local", on, "on"), .init("registers", "local", on, "on"),
            .init("notion", "local", ["off", "read", "write"], "write"), .init("sales", "local", ["off", "bant", "full"], "full"),
            .init("learning", "local", on, "on"), .init("call_agent", "local", on, "on"),
            .init("server_sync", "server", on, "off"), .init("teams", "server", on, "off"), .init("manager_view", "server", on, "off"),
            .init("c_level", "server", on, "off"), .init("org_projects", "server", on, "off"),
            .init("project_context", "server", ["off", "shared", "index"], "off"), .init("org_policy", "server", ["off", "basic", "full"], "off"),
            .init("pacenote_ai_tips", "metered", on, "off", available: false), .init("server_prep", "metered", on, "off", available: false),
        ]
        return Catalog(version: 1, modules: Dictionary(uniqueKeysWithValues: ms.map { ($0.id, $0) }),
                       quotaModule: ["seats": "teams", "storage_mb": "server_sync", "history_months": "server_sync",
                                     "tip_minutes": "pacenote_ai_tips", "server_prep": "server_prep",
                                     "index_sources": "project_context", "org_projects_max": "org_projects"],
                       fallbackModules: [:], fallbackQuotas: [:])
    }()

    /// A verified `GET /v1/catalog` payload (the `signed` field) as a catalog.
    public static func catalog(_ p: [String: Any]) -> Catalog? {
        guard let v = num(p["catalog_version"]), let ms = p["modules"] as? [[String: Any]] else { return nil }
        var mods: [String: CatalogModule] = [:]
        for m in ms {
            guard let id = m["id"] as? String, let levels = m["levels"] as? [String], !levels.isEmpty else { continue }
            mods[id] = CatalogModule(id, (m["kind"] as? String) ?? "local", levels, (m["default"] as? String) ?? levels[0],
                                     available: (m["available"] as? Bool) ?? true, gateable: (m["gateable"] as? Bool) ?? true)
        }
        var qm: [String: String] = [:]
        for q in (p["quotas"] as? [[String: Any]]) ?? [] { if let id = q["id"] as? String { qm[id] = (q["module"] as? String) ?? "" } }
        let fb = (p["fallback"] as? [String: Any]) ?? [:]
        var fq: [String: Double?] = [:]
        for (k, v) in (fb["quotas"] as? [String: Any]) ?? [:] { fq[k] = num((v as? [String: Any])?["limit"]) }
        return Catalog(version: Int(v), modules: mods, quotaModule: qm,
                       fallbackModules: (fb["modules"] as? [String: String]) ?? [:], fallbackQuotas: fq)
    }

    // MARK: the app's entries (spec 2.1, A1)

    /// Each "What Pacenote can do" entry and the module (and level) it needs; entries not here are not modules
    /// (demo, Components, settings search) and never close. CoreChecks: every module named here is in the catalog.
    public static let featureModules: [String: (module: String, level: String?)] = [
        "start": ("live_tips", nil), "prepare": ("meeting_sheet", "expert"), "upnext": ("meeting_sheet", nil),
        "presentation": ("presentation", nil), "rehearse": ("presentation", nil), "transcribe": ("transcribe", nil),
        "search": ("search", nil), "followup": ("followup", nil), "series": ("series", nil),
        "notionTasks": ("notion", "write"), "sales": ("sales", nil),
    ]

    /// A planned price for the beta mark (D32): "$12", per seat a month is said by the caller.
    public static func priceText(_ p: Price, locale: Locale = Locale(identifier: "en_US")) -> String {
        let f = NumberFormatter(); f.numberStyle = .currency; f.currencyCode = p.currency; f.locale = locale
        f.maximumFractionDigits = p.amountCents % 100 == 0 ? 0 : 2; f.minimumFractionDigits = f.maximumFractionDigits
        return f.string(from: NSNumber(value: Double(p.amountCents) / 100)) ?? "\(p.currency) \(Double(p.amountCents) / 100)"
    }
    /// The same currency at zero: "$0".
    public static func zeroText(_ currency: String, locale: Locale = Locale(identifier: "en_US")) -> String {
        priceText(Price(amountCents: 0, currency: currency, per: "", minSeats: 1), locale: locale)
    }

    // MARK: the cache: <app root>/state/entitlements.json, the signed strings as they came

    public struct Cache: Codable, Equatable {
        public var schema = 1
        public var fetchedAt: Date?
        public var etag = ""
        public var orgs: [String] = []          // `signed` of each organization
        public var orgETags: [String: String] = [:]   // org id -> the server's etag beside `signed` (compared with /v1/me)
        public var catalog = ""                 // `signed` of /v1/catalog
        public var catalogETag = ""
        public var offlineGraceDays = 14
        public var allPlansFree = true
        public var billingNoticeDays = 30
        public init() {}
        enum CodingKeys: String, CodingKey {
            case schema, etag, orgs, catalog
            case orgETags = "org_etags"
            case fetchedAt = "fetched_at", catalogETag = "catalog_etag", offlineGraceDays = "offline_grace_days"
            case allPlansFree = "all_plans_free", billingNoticeDays = "billing_notice_days"
        }
        public func encoded() -> Data? {
            let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys, .prettyPrinted]
            return try? e.encode(self)
        }
        public static func decode(_ d: Data?) -> Cache? {
            guard let d else { return nil }
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            return try? dec.decode(Cache.self, from: d)
        }
    }

    /// Cache from a `GET /v1/entitlements` answer (200). The records are not trusted here; `resolve` checks them.
    public static func cache(from o: [String: Any], etag: String, now: Date, keeping old: Cache?) -> Cache {
        var c = old ?? Cache()
        c.fetchedAt = now; c.etag = etag
        c.orgs = ((o["orgs"] as? [[String: Any]]) ?? []).compactMap { $0["signed"] as? String }
        c.orgETags = orgETags(o)
        c.offlineGraceDays = Int(num(o["offline_grace_days"]) ?? 14)
        let b = (o["beta"] as? [String: Any]) ?? [:]
        c.allPlansFree = (b["all_plans_free"] as? Bool) ?? true
        c.billingNoticeDays = Int(num(b["billing_notice_days"]) ?? 30)
        return c
    }

    // MARK: what applies now (spec 6.3)

    public enum Basis: Equatable {
        case signedOut                          // catalog defaults; server functions need sign-in
        case live                               // fetched and verified, not expired
        case stale(days: Int)                   // verified but past `exp`: kept, a quiet "Plan info last updated N days ago"
        case soloFallback                       // signed in, no valid cache: Solo levels of the last catalog; fetch now
    }

    public enum State: Equatable {
        case open
        case lockedPlan(requiredPlan: String?, canRequest: Bool)
        case quotaWarn(id: String, Quota)
        case quotaExhausted(id: String, Quota)
        case policyOff
    }

    public struct Rights: Equatable {
        public var basis: Basis
        public var catalog: Catalog
        public var records: [String: Record]    // by organization id (lowercased)
        public var allPlansFree = true
        public var billingNoticeDays = 30
        /// True when the app should ask the server now (no valid cache while signed in).
        public var needsRefresh: Bool { basis == .soloFallback }

        func catalogLevel(_ m: String) -> String {
            guard let c = catalog.modules[m] ?? Entitlements.builtInCatalog.modules[m], c.available else { return "off" }
            if basis == .soloFallback, let f = catalog.fallbackModules[m] { return f }
            return c.defaultLevel
        }

        /// The level of a module in an organization (nil: the record of any one organization, the first by id;
        /// local modules take the default organization from the caller). Unknown modules are off.
        public func level(_ m: String, org: String? = nil) -> String {
            guard let c = catalog.modules[m] ?? Entitlements.builtInCatalog.modules[m] else { return "off" }
            if !c.gateable { return c.levels.last ?? "on" }
            guard basis == .live || isStale, let r = record(org) else { return catalogLevel(m) }
            if let x = r.modules[m] { return c.levels.contains(x.level) ? x.level : "off" }
            return c.available ? c.defaultLevel : "off"
        }
        var isStale: Bool { if case .stale = basis { return true }; return false }
        /// 0.19.0 (D45): organization id -> `on` / `member_choice`, from the signed records only.
        public var analyticsPolicy: [String: String] { records.compactMapValues { $0.usageAnalytics } }

        public func record(_ org: String?) -> Record? {
            if let o = org?.lowercased(), !o.isEmpty { return records[o] }
            return records.keys.sorted().first.flatMap { records[$0] }
        }

        /// The module is at least at `level` (default: its first level above off).
        public func can(_ m: String, _ level: String? = nil, org: String? = nil) -> Bool {
            guard let c = catalog.modules[m] ?? Entitlements.builtInCatalog.modules[m] else { return false }
            let need = level ?? (c.levels.count > 1 ? c.levels[1] : "on")
            return c.rank(self.level(m, org: org)) >= c.rank(need) && self.level(m, org: org) != "off"
        }

        public func quota(_ id: String, org: String? = nil) -> Quota? {
            if basis == .live || isStale { return record(org)?.quotas[id] }
            if basis == .soloFallback, let f = catalog.fallbackQuotas[id] { return Quota(limit: f) }
            return nil
        }

        /// What a closed or limited module shows (spec 7). A policy of the organization wins over the plan; a module
        /// the plan opens can still be limited by its quota.
        public func state(_ m: String, _ level: String? = nil, org: String? = nil, policyOff: Bool = false) -> State {
            if policyOff { return .policyOff }
            if !can(m, level, org: org) {
                let r = (basis == .live || isStale) ? record(org) : nil
                return .lockedPlan(requiredPlan: r?.modules[m]?.requiredPlan, canRequest: r?.canRequestPlan ?? false)
            }
            let ids = catalog.quotaModule.filter { $0.value == m }.keys.sorted()
            for id in ids { if let q = quota(id, org: org), q.state == "exhausted" { return .quotaExhausted(id: id, q) } }
            for id in ids { if let q = quota(id, org: org), q.state == "warn" { return .quotaWarn(id: id, q) } }
            return .open
        }
    }

    /// What applies: the cache is checked on every read (signature, this person, this Mac). `userID` nil = signed out.
    public static func resolve(_ cache: Cache?, userID: String?, deviceID: String?, now: Date = Date(),
                               keys: [String: String] = builtInKeys) -> Rights {
        let cat = cache.flatMap { c in c.catalog.isEmpty ? nil : verify(c.catalog, keys: keys).flatMap(catalog) } ?? builtInCatalog
        var r = Rights(basis: .signedOut, catalog: cat, records: [:])
        if let c = cache { r.allPlansFree = c.allPlansFree; r.billingNoticeDays = c.billingNoticeDays }
        guard let user = userID?.lowercased(), !user.isEmpty else { return r }
        let dev = (deviceID ?? "").lowercased()
        var recs: [String: Record] = [:]
        for s in cache?.orgs ?? [] {
            guard let p = verify(s, keys: keys), let rec = record(p), rec.sub == user, !dev.isEmpty, rec.deviceID == dev else { continue }
            recs[rec.orgID] = rec
        }
        guard !recs.isEmpty, recs.count == cache?.orgs.count else { r.basis = .soloFallback; return r }
        r.records = recs
        let exp = recs.values.map(\.expires).min() ?? now
        if now <= exp { r.basis = .live } else {
            let since = cache?.fetchedAt ?? recs.values.map(\.issued).min() ?? now
            r.basis = .stale(days: max(1, Int(now.timeIntervalSince(since) / 86400)))
        }
        return r
    }

    /// When to ask the server again: never fetched, 6 hours, or an `entitlements_etag` in /v1/me differs from the
    /// cache (it changes when staff change the plan in the console, and daily). After 402/403 the caller forces it.
    public static func due(_ cache: Cache?, now: Date, meETags: [String: String] = [:]) -> Bool {
        guard let c = cache, let at = c.fetchedAt, !c.orgs.isEmpty else { return true }
        return now.timeIntervalSince(at) >= refreshEvery || meChanged(cached: c.orgETags, me: meETags)
    }

    /// The server's etag of each organization, beside `signed` in a 200 answer.
    public static func orgETags(_ o: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for g in (o["orgs"] as? [[String: Any]]) ?? [] {
            if let id = g["org_id"] as? String, let e = g["etag"] as? String { out[id.lowercased()] = e }
        }
        return out
    }
    /// True when /v1/me names an organization etag the cache does not have (a change on the server, a new organization).
    public static func meChanged(cached: [String: String], me: [String: String]) -> Bool {
        me.contains { k, v in !v.isEmpty && cached[k.lowercased()] != v }
    }
}
