import CryptoKit
import Foundation

/// 0.19.0 (S4, D43, spec research/pacenote-analytics-spec-2026-11-17.md 3, 4, 9, 11.3): product analytics v2 in the
/// app. Events are checked against the catalog (rules/analytics.yaml, embedded as AnalyticsCatalogData) exactly as the
/// server checks them: an unknown event is dropped, a parameter of the wrong type loses only itself, and there is no
/// free string type. Each event gets a time to the second, a session (new at launch and after 30 minutes without an
/// event) and its number in the session. Events wait in a queue on disk and go every hour and at quit: signed in to
/// POST /v1/telemetry/events (Bearer), else to the anonymous POST /v1/telemetry/batch. A batch leaves the queue only
/// after 200 or 202 (never re-packed: the server is idempotent per batch, not per event). D45: an organization whose
/// signed policy is `on` gets its events even when the personal switch is off. The local UsageLog (schema 1) stays.
public enum Analytics {
    // MARK: the catalog

    public struct Catalog {
        public let types: [String: [String: Any]]
        public let enums: [String: [String]]
        public let screens: [String: [String]]
        public let actions: Set<String>
        public let events: [String: [String: String]]
        public let values: [String: [String]]
    }

    public static let catalog: Catalog = parse(AnalyticsCatalogData.json)
    public static var catalogSHA256: String { AnalyticsCatalogData.sourceSHA256 }

    static func parse(_ json: String) -> Catalog {
        let o = ((try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]) ?? [:]
        return Catalog(types: (o["types"] as? [String: [String: Any]]) ?? [:], enums: (o["enums"] as? [String: [String]]) ?? [:],
                       screens: (o["screens"] as? [String: [String]]) ?? [:], actions: Set((o["actions"] as? [String]) ?? []),
                       events: (o["events"] as? [String: [String: String]]) ?? [:], values: (o["values"] as? [String: [String]]) ?? [:])
    }

    static func isBool(_ v: Any) -> Bool { (v as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false }
    static func int(_ v: Any) -> Int? {
        guard let n = v as? NSNumber, !isBool(v), CFNumberIsFloatType(n) == false else { return nil }
        return n.intValue
    }

    /// The server's check_value, the same rules: true when `v` is a value of the parameter's type.
    public static func valid(_ event: String, _ param: String, _ type: String, _ v: Any, scr: String?) -> Bool {
        let cat = catalog
        guard let t = cat.types[type] else { return (v as? String).map { (cat.enums[type] ?? []).contains($0) } ?? false }
        switch t["kind"] as? String {
        case "bool": return isBool(v)
        case "int":
            guard let i = int(v), let lo = t["min"] as? Int, let hi = t["max"] as? Int else { return false }
            return lo <= i && i <= hi
        case "enum": return (v as? String).map { ((t["values"] as? [String]) ?? []).contains($0) } ?? false
        case "pattern", "code":
            guard let s = v as? String, let re = t["re"] as? String,
                  s.range(of: re, options: .regularExpression) == s.startIndex..<s.endIndex else { return false }
            if let closed = cat.values["\(event).\(param)"] { return closed.contains(s) }
            return true
        case "list":
            guard let s = v as? String else { return false }
            switch t["of"] as? String {
            case "screens": return cat.screens[s] != nil
            case "screens.sub": return scr.map { (cat.screens[$0] ?? []).contains(s) } ?? false
            case "actions": return cat.actions.contains(s)
            default: return false
            }
        default: return false
        }
    }

    /// The parameters that pass, and how many were dropped. nil: the event itself is not sent (unknown, or a screen
    /// event without a known screen).
    public static func clean(_ e: String, _ p: [String: Any], scr: String?) -> (p: [String: Any], dropped: Int)? {
        guard let spec = catalog.events[e] else { return nil }
        if let s = scr, catalog.screens[s] == nil { return nil }
        if ["screen_view", "action"].contains(e) && scr == nil { return nil }
        var out: [String: Any] = [:], dropped = 0
        for (k, v) in p {
            guard let type = spec[k], valid(e, k, type, v, scr: scr) else { dropped += 1; continue }
            out[k] = v
        }
        return (out, dropped)
    }

    // MARK: events and sessions

    public struct Event: Equatable {
        public var e: String
        public var t: Date
        public var s: String
        public var seq: Int
        public var scr: String?
        public var p: [String: Any]
        public var ms: Int?
        public var o: String?
        public init(e: String, t: Date, s: String, seq: Int, scr: String?, p: [String: Any], ms: Int?, o: String?) {
            self.e = e; self.t = t; self.s = s; self.seq = seq; self.scr = scr; self.p = p; self.ms = ms; self.o = o
        }
        public static func == (a: Event, b: Event) -> Bool {
            a.e == b.e && a.t == b.t && a.s == b.s && a.seq == b.seq && a.scr == b.scr && a.ms == b.ms && a.o == b.o
                && NSDictionary(dictionary: a.p).isEqual(to: b.p)
        }
        public var json: [String: Any] {
            var o: [String: Any] = ["e": e, "t": Analytics.time(t), "s": s, "seq": seq]
            if let scr { o["scr"] = scr }
            if !p.isEmpty { o["p"] = p }
            if let ms { o["ms"] = ms }
            if let org = self.o { o["o"] = org }
            return o
        }
    }

    public static func time(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d)
    }

    /// Session rule (spec 3.4): a new session at launch and after 30 minutes without an event; `seq` from 1.
    public struct Sessions {
        public private(set) var id = ""
        public private(set) var seq = 0
        public private(set) var last: Date?
        public private(set) var started: Date?
        public static let idle: TimeInterval = 30 * 60
        public init() {}
        public mutating func launch(now: Date) { id = UUID().uuidString.lowercased(); seq = 0; last = now; started = now }
        public mutating func next(now: Date) -> (s: String, seq: Int) {
            if id.isEmpty || last.map({ now.timeIntervalSince($0) > Self.idle }) ?? true || seq >= 1_000_000 {
                id = UUID().uuidString.lowercased(); seq = 0; started = now
            }
            seq += 1; last = now
            return (id, seq)
        }
    }

    // MARK: D45: which events may go

    /// The personal switch covers everything except work in an organization whose signed policy is `on`
    /// (`usage_analytics`): those events go even with the switch off. Events without an organization belong to the
    /// person's default organization (D36), as the server reads them.
    public static func mayGo(o: String?, defaultOrg: String?, personalOn: Bool, orgPolicy: [String: String]) -> Bool {
        if personalOn { return true }
        guard let org = (o ?? defaultOrg)?.lowercased() else { return false }
        return orgPolicy[org] == "on"
    }

    // MARK: the batch

    public struct Header: Equatable {
        public var install: String
        public var machine: String?
        public var appVersion: String
        public var build: String?
        public var osVersion: String
        public var arch: String
        public var uiLang: String
        public var rulesVersion: String?
        public init(install: String, machine: String?, appVersion: String, build: String?, osVersion: String, arch: String,
                    uiLang: String, rulesVersion: String?) {
            self.install = install; self.machine = machine; self.appVersion = appVersion; self.build = build
            self.osVersion = osVersion; self.arch = arch; self.uiLang = uiLang; self.rulesVersion = rulesVersion
        }
    }

    static let versionRE = #"^\d{1,3}(\.\d{1,3}){0,3}$"#
    static func versionOr(_ s: String?, _ fallback: String?) -> String? {
        guard let s, s.range(of: versionRE, options: .regularExpression) != nil else { return fallback }
        return s
    }

    /// A batch body the server's validate_header takes: a dev build ("dev") reads 0.0.0, a language other than en/uk
    /// reads en, an unknown arch arm64.
    public static func body(_ h: Header, batch: String, events: [[String: Any]], sentAt: Date) -> [String: Any] {
        var o: [String: Any] = ["schema": 2, "batch": batch, "install": h.install, "app_version": versionOr(h.appVersion, "0.0.0")!,
                                "os_version": versionOr(h.osVersion, "14.0")!, "arch": ["arm64", "x86_64"].contains(h.arch) ? h.arch : "arm64",
                                "ui_lang": ["en", "uk"].contains(h.uiLang) ? h.uiLang : "en", "sent_at": time(sentAt), "events": events]
        if let m = h.machine, m.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil { o["machine"] = m }
        if let b = h.build, b.range(of: "^[0-9A-Za-z.]{1,20}$", options: .regularExpression) != nil { o["build"] = b }
        if let r = versionOr(h.rulesVersion, nil) { o["rules_version"] = r }
        return o
    }

    /// The Mac's id for the header and for sign-in (`device.machine`, spec 3.1): SHA-256 of the hardware UUID with
    /// Pacenote's salt, lower-case hex. The server hashes it once more before keeping it.
    public static func machine(platformUUID: String) -> String? {
        let u = platformUUID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !u.isEmpty else { return nil }
        return SHA256.hash(data: Data(("pacenote-mac:v1:" + u).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// What an answer means for a batch in the queue.
    public enum Outcome: Equatable { case done, retry, drop }
    public static func outcome(status: Int) -> Outcome {
        switch status {
        case 200, 202: return .done           // taken, or a duplicate of one taken
        case 400, 413: return .drop           // the server will never take it: do not loop on it
        default: return .retry                // 0 (offline), 401 (signed out: goes again after sign-in), 429, 5xx
        }
    }

    /// The wait before the next try after `failures` failed sends in a row: 1, 2, 4 ... minutes, at most 1 hour.
    public static func backoff(failures: Int) -> TimeInterval { min(3600, 60 * pow(2, Double(max(0, failures - 1)))) }

    public static let maxEvents = 5000
    public static let maxBytes = 480 * 1024        // under the server's 512 KiB with room for the header
    public static let maxQueueBytes = 30 * 1024 * 1024
    public static let sendEvery: TimeInterval = 3600

    /// Cuts events into batches the server takes (count and size).
    public static func chunks(_ events: [[String: Any]]) -> [[[String: Any]]] {
        var out: [[[String: Any]]] = [], cur: [[String: Any]] = [], size = 0
        for e in events {
            let n = ((try? JSONSerialization.data(withJSONObject: e)) ?? Data()).count + 1
            if !cur.isEmpty && (cur.count >= maxEvents || size + n > maxBytes) { out.append(cur); cur = []; size = 0 }
            cur.append(e); size += n
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    // MARK: the queue on disk

    /// <app root>/usage/queue: `open.jsonl` collects events as they happen; sealing turns it into batch files
    /// (`<time>-<batch>.json`, the body as it will go, with its route) that stay until the server took them. Over 30 MB
    /// the oldest batches go first.
    public struct Queue {
        public let dir: URL
        public init(dir: URL) { self.dir = dir }
        var openFile: URL { dir.appendingPathComponent("open.jsonl") }

        public func append(_ e: Event, signedIn: Bool) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var line = e.json; line["_auth"] = signedIn
            guard let d = try? JSONSerialization.data(withJSONObject: line) else { return }
            if let h = try? FileHandle(forWritingTo: openFile) {
                h.seekToEndOfFile(); h.write(d); h.write(Data("\n".utf8)); try? h.close()
            } else {
                try? (d + Data("\n".utf8)).write(to: openFile, options: .atomic)
            }
        }

        /// The open events become batch files, split by route (signed in or anonymous), then the open file goes.
        public func seal(_ h: Header, now: Date) -> Int {
            guard let t = try? String(contentsOf: openFile, encoding: .utf8), !t.isEmpty else { return 0 }
            var signed: [[String: Any]] = [], anon: [[String: Any]] = []
            for ln in t.split(separator: "\n") {
                guard var o = (try? JSONSerialization.jsonObject(with: Data(ln.utf8))) as? [String: Any] else { continue }
                let auth = (o.removeValue(forKey: "_auth") as? Bool) == true
                if auth { signed.append(o) } else { o.removeValue(forKey: "o"); anon.append(o) }
            }
            var n = 0
            let stamp = String(format: "%013.0f", now.timeIntervalSince1970 * 1000)
            for (route, evs) in [("events", signed), ("batch", anon)] {
                for c in chunks(evs) {
                    let id = UUID().uuidString.lowercased()
                    let file: [String: Any] = ["route": route, "body": body(h, batch: id, events: c, sentAt: now)]
                    if let d = try? JSONSerialization.data(withJSONObject: file) {
                        try? d.write(to: dir.appendingPathComponent("\(stamp)-\(id).json"), options: .atomic); n += 1
                    }
                }
            }
            try? FileManager.default.removeItem(at: openFile)
            trim()
            return n
        }

        /// Batch files, oldest first.
        public var batches: [URL] {
            ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
                .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }

        public func read(_ u: URL) -> (route: String, body: [String: Any])? {
            guard let d = try? Data(contentsOf: u), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let r = o["route"] as? String, let b = o["body"] as? [String: Any] else { return nil }
            return (r, b)
        }

        public func remove(_ u: URL) { try? FileManager.default.removeItem(at: u) }

        /// Everything goes (the switch off with no organization asking for it).
        public func clear() { try? FileManager.default.removeItem(at: dir) }

        /// Keeps only the sealed events `keep` says yes to (route "events" or "batch", the event); a batch left empty
        /// goes. Used after sign-out (nothing of the old account goes with the next one's token) and when the switch
        /// goes off while an organization keeps analytics on (only that organization's events stay). Seal first.
        @discardableResult
        public func filter(_ keep: (_ route: String, _ event: [String: Any]) -> Bool) -> Int {
            var dropped = 0
            for u in batches {
                guard let d = try? Data(contentsOf: u), var f = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                      let r = f["route"] as? String, var b = f["body"] as? [String: Any] else { remove(u); continue }
                let evs = (b["events"] as? [[String: Any]]) ?? []
                let kept = evs.filter { keep(r, $0) }
                dropped += evs.count - kept.count
                if kept.isEmpty { remove(u); continue }
                if kept.count == evs.count { continue }
                b["events"] = kept; f["body"] = b
                if let out = try? JSONSerialization.data(withJSONObject: f) { try? out.write(to: u, options: .atomic) }
            }
            return dropped
        }

        func trim() {
            var all = batches.map { ($0, (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            var total = all.reduce(0) { $0 + $1.1 }
            while total > maxQueueBytes, !all.isEmpty { let (u, s) = all.removeFirst(); remove(u); total -= s }
        }
    }

    // MARK: buckets (counts that could tell a person apart go as ranges, spec 4)

    public static func bucket(_ n: Int) -> String {
        switch n { case ..<1: return "0"; case 1: return "1"; case 2...5: return "2-5"; case 6...20: return "6-20"; case 21...100: return "21-100"; default: return "100+" }
    }
    public static func bucketPct(_ p: Double) -> String { p < 25 ? "0-25" : p < 50 ? "25-50" : p < 75 ? "50-75" : "75-100" }

    // MARK: S4 part 2: values as the catalog has them

    /// A code value as the catalog lists it: camelCase to snake_case, anything outside [a-z0-9_] to "_", at most 40
    /// ("onYou" -> "on_you", "prevSlide" -> "prev_slide"). Only for fixed values from the code, never for text.
    public static func snake(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ch.isUppercase, !out.isEmpty, out.last != "_" { out.append("_") }
            let c = Character(ch.lowercased())
            out.append(c.isASCII && (c.isLetter || c.isNumber) ? c : "_")
        }
        return String(out.prefix(40))
    }

    /// The call type of rules/meeting.yaml (auto, presentation, interview, coach, transcript) as v2 names it.
    public static func callType(_ raw: String?) -> String {
        let v = (raw ?? "auto").lowercased()
        switch v {
        case "auto", "", "general": return "general"
        case "presentation", "interview", "transcript", "sales", "standup", "rehearsal": return v
        default: return "other"
        }
    }

    /// An AI way of Settings > AI (prep, tips, after, sheet routes and the names PrepRunner logs) as a `provider`.
    public static func provider(route: String?) -> String {
        switch (route ?? "").lowercased() {
        case "code", "plan", "claude": return "claude"
        case "api", "claude_api": return "claude_api"
        case "codex", "chatgpt": return "codex"
        case "openai", "openai_api": return "openai_api"
        case "gemini", "agy", "antigravity": return "gemini"
        case "local", "ollama": return "local"
        default: return "none"
        }
    }

    /// settings_snapshot goes once a day, at the first launch of the local day.
    public static func snapshotDue(last: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        guard let last else { return true }
        return !calendar.isDate(last, inSameDayAs: now) && now > last
    }

    /// What the last run left behind, read at launch: an update (`app_update {from, to}`) and whether it ended without
    /// a quit (`crash_prev_session`). `lastVersion` and `cleanQuit` are what the previous run stored.
    public struct LaunchFacts: Equatable {
        public var updatedFrom: String?
        public var crashed: Bool
        public init(updatedFrom: String?, crashed: Bool) { self.updatedFrom = updatedFrom; self.crashed = crashed }
    }
    public static func launchFacts(lastVersion: String?, cleanQuit: Bool?, current: String) -> LaunchFacts {
        let from = lastVersion.flatMap { $0 != current && versionOr($0, nil) != nil && versionOr(current, nil) != nil ? $0 : nil }
        return LaunchFacts(updatedFrom: from, crashed: cleanQuit == false)
    }

    /// One error, its area and code from the fixed lists (spec 6.6); the message itself never goes.
    public static func errorCode(status: Int? = nil, _ e: Error? = nil) -> String {
        if let s = status {
            switch s {
            case 401, 403: return "auth_expired"
            case 404: return "not_found"
            case 409: return "conflict"
            case 413: return "too_large"
            case 429: return "rate_limit"
            case 400..<500: return "server_4xx"
            case 500..<600: return "server_5xx"
            case 0: return "network"
            default: break
            }
        }
        if let u = e as? URLError {
            switch u.code {
            case .timedOut: return "timeout"
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return "offline"
            case .cancelled: return "cancelled"
            default: return "network"
            }
        }
        if e is CancellationError { return "cancelled" }
        if let n = e as NSError?, n.domain == NSCocoaErrorDomain {
            if [NSFileWriteOutOfSpaceError].contains(n.code) { return "disk_full" }
            if [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(n.code) { return "permission" }
            if [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(n.code) { return "not_found" }
            if n.code >= 3840 && n.code <= 3851 { return "parse" }
        }
        return "other"
    }

    /// S5 (17.11): a code from the fixed list for an error that only comes as a message (a recorder, a sidecar, a CLI).
    /// The message is read here and never sent.
    public static func errorCode(message: String) -> String {
        let m = message.lowercased()
        func has(_ w: String...) -> Bool { w.contains { m.contains($0) } }
        if has("timed out", "timeout") { return "timeout" }
        if has("rate limit", "rate_limit", "429", "too many requests") { return "rate_limit" }
        if has("quota", "usage limit", "credit") { return "quota" }
        if has("api key", "invalid key", "invalid_api_key", "invalid x-api-key") { return "key_invalid" }
        if has("401", "unauthorized", "unauthenticated", "token expired", "expired token", "sign in again") { return "auth_expired" }
        if has("permission", "not permitted", "not authorized", "denied", "tcc") { return "permission" }
        if has("no space", "disk full", "out of space") { return "disk_full" }
        if has("offline", "not connected to the internet", "network connection was lost") { return "offline" }
        if has("could not connect", "connection refused", "network") { return "network" }
        if has("not found", "no such file", "404") { return "not_found" }
        if has("cancelled", "canceled") { return "cancelled" }
        if has("unsupported", "not supported") { return "unsupported" }
        if has("too large", "too long", "413") { return "too_large" }
        if has("crash", "exited with", "signal") { return "crashed" }
        if has("500", "502", "503", "504", "overloaded", "internal server error") { return "server_5xx" }
        return "other"
    }
}
