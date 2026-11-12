import Foundation

/// 0.10.0 (Meeting Sheet, phase 3): the pure part of SheetRunner, checked by CoreChecks.
/// - which call types build a sheet (all but Transcript),
/// - the preset a Prepare without the wizard starts from (the series' own choice wins),
/// - the progress lines of the sidecar (`python -m livetips_m0.sheet build`): {"progress", "stage", "source_id"?,
///   "access"?, "pass"?, "passes"?, "file"?} and the last line {"done": true, ...} or {"error": ...}.
public enum SheetPipeline {
    public static func builds(callType: String) -> Bool { callType != "transcript" }

    public static func preset(callType: String, sales: Bool, title: String, earlier: Bool, seriesChoice: String? = nil) -> String {
        if let p = seriesChoice, !p.isEmpty { return p }
        let t = title.lowercased()
        if callType == "interview" { return "interview" }
        if callType == "presentation" { return "internal_presentation" }
        if t.contains("standup") || t.contains("stand-up") || t.contains("daily") || t.contains("стендап") { return "standup" }
        if sales { return earlier ? "repeat_call" : "sales_intro" }
        return "client_sync"
    }

    public struct Line: Equatable {
        public var progress: Double?
        public var stage: String = ""
        public var sourceID: String?
        public var access: String?
        public var pass: Int?
        public var passes: Int?
        public var file: String?
        public var done = false
        public var error: String?
        public var sheet: String?
        public var readiness: String?
        /// 0.10.0 (round 2): Skip from the build screen took this source out; a failed source waits for Retry / Skip.
        public var skipped = false
        public var waiting: [String] = []
    }

    /// 0.10.0 (Meeting Sheet, round 2): a build refreshes the call's sheet when it exists and either Refresh was asked
    /// or it runs during that very call (Prepare again: the transcript so far is one more source, edits stay).
    public static func isRefresh(sheetExists: Bool, refreshAsked: Bool, duringCall: Bool) -> Bool {
        sheetExists && (refreshAsked || duringCall)
    }

    /// What a finished build during the call means for the call: adopt the new sheet, or keep the previous one and say
    /// so in the tips window (never fall back to an old brief), or nothing (not during a call).
    public enum LiveOutcome: Equatable { case adopt, keepPrevious, none }
    public static func liveOutcome(ok: Bool, duringCall: Bool) -> LiveOutcome {
        guard duringCall else { return .none }
        return ok ? .adopt : .keepPrevious
    }

    /// The Retry / Skip control file the sidecar reads (sheet/build.py Control): the actions so far plus one.
    public static func controlActions(_ existing: [[String: String]], add action: String, source: String) -> [[String: String]] {
        guard action == "retry" || action == "skip", !source.isEmpty else { return existing }
        return existing + [["action": action, "source_id": source]]
    }

    /// One stdout line of the sidecar; nil for anything that is not a JSON object.
    public static func parse(_ line: String) -> Line? {
        guard let d = line.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        var l = Line()
        l.progress = (o["progress"] as? NSNumber)?.doubleValue
        l.stage = o["stage"] as? String ?? ""
        l.sourceID = o["source_id"] as? String
        l.access = o["access"] as? String
        l.pass = (o["pass"] as? NSNumber)?.intValue
        l.passes = (o["passes"] as? NSNumber)?.intValue
        l.file = o["file"] as? String
        l.done = (o["done"] as? Bool) == true
        l.error = o["error"] as? String
        l.sheet = o["sheet"] as? String
        l.readiness = o["readiness"] as? String
        l.skipped = (o["skipped"] as? Bool) == true
        l.waiting = o["waiting"] as? [String] ?? []
        return l
    }
}

// 0.10.0 (Meeting Sheet, hardening): the rules behind what could hurt a real call, kept here so CoreChecks test them.
extension SheetPipeline {
    /// The route question is asked only when a person started the build and no call is live; otherwise the build
    /// switches, the report says so and a notice (never a modal) tells the PM.
    public static func asksRouteSwitch(interactive: Bool, callLive: Bool) -> Bool { interactive && !callLive }

    /// What a job that follows SheetRunner shows for its call.
    public enum FollowState: Equatable { case running, waitingForChoice, finished, gaveUp, queued }
    public static func followState(runningThis: Bool, pendingThis: Bool, sawRunning: Bool, sawPending: Bool) -> FollowState {
        if runningThis { return .running }
        if pendingThis { return .waitingForChoice }
        if sawRunning { return .finished }
        if sawPending { return .gaveUp }          // the route question was answered Not now, or Stop: no build comes
        return .queued
    }

    /// A notification of the sheet (pn-sheet-<call id> reminder, pn-sheet-built-<call id> ready): the call and the tab
    /// of its page to open; nil for anything else (a route notice).
    public static func notificationTarget(_ id: String, prefix: String) -> (call: String, tab: String)? {
        guard id.hasPrefix(prefix) else { return nil }
        let rest = String(id.dropFirst(prefix.count))
        if rest.hasPrefix("built-") {
            let u = String(rest.dropFirst("built-".count))
            return UUID(uuidString: u) == nil ? nil : (u, "sheet")
        }
        return UUID(uuidString: rest) == nil ? nil : (rest, "readiness")
    }

    /// A person typed in the wizard ("Emily Parker · Lumenfield"): name and company; nil when there is no name
    /// (an empty line, or only "·").
    public static func person(_ typed: String) -> (name: String, company: String)? {
        let t = typed.trimmingCharacters(in: .whitespaces)
        let parts = t.split(separator: "·", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = parts.first, !first.isEmpty else { return nil }
        return (first, parts.count > 1 ? parts[1] : "")
    }

    /// Reminder keys already sent (kept between app starts), the old ones dropped: at most `keep`, newest last.
    public static func rememberSent(_ sent: [String], add key: String, keep: Int = 200) -> [String] {
        Array((sent.filter { $0 != key } + [key]).suffix(keep))
    }
}
