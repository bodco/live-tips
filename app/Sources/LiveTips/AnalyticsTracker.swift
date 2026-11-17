import AppKit
import Foundation
import IOKit
import LiveTipsCore
import SwiftUI

/// 0.19.0 (S4, D43, D45; spec research/pacenote-analytics-spec-2026-11-17.md 9, 11.3): product analytics v2 on this Mac.
/// Every UsageLog event whose name is in the v2 catalog (rules/analytics.yaml) is tracked too, plus app_launch,
/// app_quit, sign_in, sign_out and the events the app tracks directly. What may go: Help improve Pacenote on, or the
/// event belongs to an organization whose signed policy `usage_analytics` is `on` (D45; the switch then covers the rest).
/// The queue lives in <app root>/usage/queue and goes every hour, after sign-in and at quit (the server is idempotent
/// per batch). Settings > General > Privacy > Show what is sent shows the next batches as they will go.
@MainActor
final class AnalyticsTracker {
    static let shared = AnalyticsTracker()

    private var sessions = Analytics.Sessions()
    private var timer: Timer?
    private var failures = 0
    private var nextTry = Date.distantPast
    private var sending = false
    private(set) var lastScreen = "launch"

    static var queueDir: URL { FeatureRegistry.usageDir.appendingPathComponent("queue", isDirectory: true) }
    var queue: Analytics.Queue { Analytics.Queue(dir: Self.queueDir) }

    /// The Mac's hashed hardware id (IOPlatformUUID with Pacenote's salt), for the header and for sign-in.
    static let machineID: String? = {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(svc) }
        guard svc != 0, let u = IORegistryEntryCreateCFProperty(svc, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String else { return nil }
        return Analytics.machine(platformUUID: u)
    }()

    /// The personal switch, read from the config at most every 10 seconds (events can come many a minute in a call).
    private var personalCache: (on: Bool, at: Date) = (false, .distantPast)
    private var personalOn: Bool {
        if Date().timeIntervalSince(personalCache.at) > 10 {
            let c = AppConfig.load(from: AppPaths.config); personalCache = (c.shareUsage && c.usageLog, Date())
        }
        return personalCache.on
    }
    private var policy: [String: String] { EntitlementsStore.shared.rights.analyticsPolicy }

    func start() {
        if SheetShots.active { return }
        sessions.launch(now: Date())
        UsageLog.onLog = { e, p in
            // UsageLog is called from any thread; analytics keeps to the main one
            if Thread.isMainThread { MainActor.assumeIsolated { AnalyticsTracker.shared.fromUsageLog(e, p) } }
            else { DispatchQueue.main.async { MainActor.assumeIsolated { AnalyticsTracker.shared.fromUsageLog(e, p) } } }
        }
        launchFacts()
        settleWhenAccountKnown()
        NotificationCenter.default.addObserver(forName: PacenoteAccount.orgsChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in await AnalyticsTracker.shared.flush(why: "orgs") }
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Analytics.sendEvery, repeats: true) { _ in
            Task { @MainActor in await AnalyticsTracker.shared.flush(why: "hour") }
        }
        // what waited from the last run goes a minute after launch (sign-in and plan info are loaded by then)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { Task { @MainActor in await AnalyticsTracker.shared.flush(why: "launch") } }
    }

    /// Schema 1 names that became one v2 event with a parameter.
    private func fromUsageLog(_ e: String, _ p: [String: Any]) {
        if e.hasPrefix("provider_limit_") {
            var q = p; q["level"] = String(e.dropFirst("provider_limit_".count)); track("provider_limit", q); return
        }
        guard let spec = Analytics.catalog.events[e], !Self.direct.contains(e) else { return }
        track(e, Self.v2(e, p, spec: spec), o: orgFor(e))
    }

    /// Events of a running call carry its organization; edits on a call page that of the page (spec 3.2, D36).
    static let liveEvents: Set<String> = ["tip_action", "tip_rated", "rec_started", "rec_paused", "rec_saved", "hotkey",
                                          "presentation_mode_on", "slide_sync", "meeting_end", "speakers_merged", "update_crm"]
    /// Events done on a call page or an upcoming call page (they carry that page's organization).
    static let pageEvents: Set<String> = ["call_page_edited", "followup_written", "followup_copied", "followup_open_mail",
                                          "decision_added", "decision_superseded", "risk_added", "google_meet", "call_reassign",
                                          "call_reassign_notion", "meet_participants", "answer_card_saved"]
    private func orgFor(_ e: String) -> String? {
        // review 17.11: the call's organization stays a while after it ends (rec_saved and ratings come later), and only
        // for events of the call; page events only while that page is the screen in front
        if let c = callOrg, Self.liveEvents.contains(e), CallEngine.shared.isRunning || Date().timeIntervalSince(callEndedAt) < 600 { return c }
        if Self.pageEvents.contains(e), ["call_page", "upcoming_page"].contains(lastScreen) { return lastScreenOrg }
        return nil
    }
    private var lastScreenOrg: String?

    /// Events whose v2 parameters differ from schema 1: the code tracks them itself (CallEngine, PrepRunner,
    /// SheetRunner); the local log keeps its schema 1 line.
    static let direct: Set<String> = ["call_started", "call_ended", "prepare_run"]

    /// A schema 1 line as v2 takes it: `code` values as the catalog lists them (snake_case), an empty plan reads
    /// `none`, a spending limit's provider as the provider list names it.
    static func v2(_ e: String, _ p: [String: Any], spec: [String: String]) -> [String: Any] {
        var q = p
        for (k, v) in p {
            guard spec[k] == "code", let str = v as? String else { continue }
            if str.isEmpty { q[k] = e == "plan_chosen" && k == "from" ? "none" : nil; continue }
            q[k] = Analytics.snake(str)
        }
        if e == "provider_limit", let pv = q["provider"] as? String, Analytics.provider(route: pv) != "none" { q["provider"] = Analytics.provider(route: pv) }
        return q
    }

    /// One event. `o` is the organization the work belongs to (a call's, a screen's), when known.
    func track(_ e: String, _ p: [String: Any] = [:], scr: String? = nil, ms: Int? = nil, o: String? = nil) {
        if SheetShots.active { return }
        let o = (o?.isEmpty ?? true) ? nil : o
        // review 17.11: until the account is known (the session is read off the main thread at launch), events wait in
        // memory, so the launch events go signed in and the D45 rule sees the right organizations
        if settling { pending.append((e, p, scr, ms, o, Date())); return }
        record(e, p, scr: scr, ms: ms, o: o, at: Date())
        // the button behind a feature event, on the screen it was pressed on ("seen but not pressed", spec 5)
        if let a = Self.actionFor[e], !(e == "rec_uploaded" && (p["auto"] as? Bool) == true) {
            track("action", ["name": a], scr: lastScreen, o: o)
        }
    }

    private func record(_ e: String, _ p: [String: Any], scr: String?, ms: Int?, o: String?, at: Date) {
        let me = PacenoteAccount.shared.me
        guard Analytics.mayGo(o: o, defaultOrg: me?.defaultOrg?.isPersonal == false ? me?.defaultOrg?.id : nil,
                              personalOn: personalOn, orgPolicy: policy),
              let c = Analytics.clean(e, p, scr: scr) else { return }
        let (s, seq) = sessions.next(now: at)
        let ev = Analytics.Event(e: e, t: at, s: s, seq: seq, scr: scr, p: c.p, ms: ms.map { min(max($0, 0), 3_600_000) },
                                 o: o?.lowercased())
        queue.append(ev, signedIn: PacenoteAccount.shared.signedIn)
    }

    private var settling = true
    private var pending: [(e: String, p: [String: Any], scr: String?, ms: Int?, o: String?, at: Date)] = []

    /// The account is known when /v1/me answered, or 15 seconds after launch (no session, or the server is away).
    private func settleWhenAccountKnown(waited: Double = 0) {
        if PacenoteAccount.shared.me != nil || waited >= 15 { settle(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            MainActor.assumeIsolated { AnalyticsTracker.shared.settleWhenAccountKnown(waited: waited + 0.5) }
        }
    }
    private func settle() {
        guard settling else { return }
        settling = false
        let waiting = pending; pending = []
        for x in waiting { record(x.e, x.p, scr: x.scr, ms: x.ms, o: x.o, at: x.at) }
    }

    /// Feature events whose button is in the `actions` list (review 17.11: not the ones that end later or by themselves,
    /// such as a preparation's result or a call the meeting's end stopped; those buttons track their action directly).
    static let actionFor: [String: String] = [
        "call_started": "start_call",
        "followup_written": "followup_write", "followup_copied": "followup_copy", "followup_open_mail": "followup_mail",
        "search_calls": "search", "rehearsal_started": "rehearsal_start", "presentation_mode_on": "presentation_on",
        "feature_try_it": "feature_try_it", "google_connect": "connect_google", "plan_request_opened": "request_plan",
        "plan_chosen": "change_plan", "org_team_started": "start_team", "console_platform": "open_platform",
        "calendar_refresh": "refresh_calendars", "speakers_merged": "merge_speakers", "risk_added": "add_risk",
        "decision_added": "add_decision", "rec_started": "record_start", "rec_paused": "record_pause",
        "rec_uploaded": "upload_drive", "project_wizard": "add_project", "project_removed": "remove_project",
        "component_removed": "remove_component", "call_reassign": "change_project", "google_export": "export",
        "sign_in": "sign_in", "sign_out": "sign_out", "org_setup_invites": "invite"]

    /// A screen opened: `screen_view {scr, sub, from}`.
    func screen(_ scr: String, sub: String? = nil, o: String? = nil) {
        guard !scr.isEmpty else { return }          // a view shown inside another screen (the Setup tab of a call page)
        let sub = sub.map(Analytics.snake)
        // SwiftUI can call onAppear twice for one view; the same screen and part within 2 seconds is one view
        if let l = lastView, l.scr == scr, l.sub == sub, Date().timeIntervalSince(l.at) < 2 { return }
        lastView = (scr, sub, Date())
        var p: [String: Any] = ["from": lastScreen]
        if let sub { p["sub"] = sub }
        // review 17.11: the screen in front changes whether or not its event may go (D45), so a page's organization never
        // sticks to events done elsewhere
        lastScreen = scr; lastScreenOrg = (o?.isEmpty ?? true) ? nil : o
        track("screen_view", p, scr: scr, o: o)
    }
    private var lastView: (scr: String, sub: String?, at: Date)?

    /// A button or menu item from the fixed list: `action {scr, name}`.
    func action(_ name: String, scr: String, o: String? = nil) { track("action", ["name": name], scr: scr, o: o) }

    var header: Analytics.Header {
        var s = TelemetrySender.load()
        if s.install.isEmpty { s = Telemetry.ensured(s, now: Date()); TelemetrySender.save(s) }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let ctx = EditLog.context()
        return Analytics.Header(install: s.install, machine: Self.machineID, appVersion: PacenoteAccount.appVersion,
                                build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
                                osVersion: "\(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : ""),
                                arch: arch, uiLang: L10n.lang, rulesVersion: ctx["rules_version"] as? String)
    }

    /// Seals the open events and sends the batches, oldest first. Stops at the first failure and waits (1, 2, 4 ...
    /// minutes up to an hour) unless `force`.
    func flush(why: String, force: Bool = false) async {
        guard !sending, force || Date() >= nextTry else { return }
        sending = true; defer { sending = false }
        _ = queue.seal(header, now: Date())
        if !personalOn && policy.values.allSatisfy({ $0 != "on" }) {
            // nothing may go and nothing is kept for later (the switch is off, no organization asks for it)
            queue.clear(); return
        }
        if !personalOn { keepOnlyOrgShared() }
        for u in queue.batches {
            guard let b = queue.read(u), let body = try? JSONSerialization.data(withJSONObject: b.body) else { queue.remove(u); continue }
            let status: Int
            if b.route == "events" {
                guard PacenoteAccount.shared.signedIn else { continue }      // waits for sign-in (spec 8.1)
                status = (try? await PacenoteAccount.shared.api("POST", "/v1/telemetry/events", body: body))?.1 ?? 0
            } else {
                status = await post(Telemetry.serverURL(base: PacenoteAccount.shared.base), body)
            }
            switch Analytics.outcome(status: status) {
            case .done, .drop: queue.remove(u); failures = 0
            case .retry:
                failures += 1; nextTry = Date().addingTimeInterval(Analytics.backoff(failures: failures)); return
            }
        }
    }

    private func post(_ url: URL, _ body: Data) async -> Int {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"; req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Pacenote", forHTTPHeaderField: "User-Agent")
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return 0 }
        return (resp as? HTTPURLResponse)?.statusCode ?? 0
    }

    // MARK: S4 part 2: launch, update, crash, settings snapshot

    private static let kVersion = "analytics.lastVersion", kClean = "analytics.cleanQuit", kSnapshot = "analytics.snapshotAt"

    /// app_launch {cold, ms_to_ready, after_update}, perf app_ready, app_update and crash_prev_session from what the
    /// last run stored; then the day's settings_snapshot. The run is marked as not quit cleanly until quit().
    private func launchFacts() {
        let d = UserDefaults.standard, cur = PacenoteAccount.appVersion
        let facts = Analytics.launchFacts(lastVersion: d.string(forKey: Self.kVersion),
                                          cleanQuit: d.object(forKey: Self.kClean) as? Bool, current: cur)
        let ready = Self.msSinceProcessStart()
        var p: [String: Any] = ["cold": true, "after_update": facts.updatedFrom != nil]
        if let ready { p["ms_to_ready"] = ready }
        track("app_launch", p)
        if let ready { track("perf", ["what": "app_ready", "ok": true], ms: ready) }
        if let from = facts.updatedFrom { track("app_update", ["from": from, "to": cur]) }
        if facts.crashed { track("crash_prev_session") }
        d.set(cur, forKey: Self.kVersion); d.set(false, forKey: Self.kClean)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { MainActor.assumeIsolated { AnalyticsTracker.shared.snapshotIfDue() } }
    }

    /// Milliseconds from the process start to now (kinfo_proc), nil when macOS does not say.
    static func msSinceProcessStart() -> Int? {
        var kp = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0 else { return nil }
        let tv = kp.kp_proc.p_un.__p_starttime
        let start = Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
        let ms = Int((Date().timeIntervalSince1970 - start) * 1000)
        return (0...3_600_000).contains(ms) ? ms : nil
    }

    /// Once a day, at the first launch of the day: how the app is set up, as types and buckets (spec 6.2).
    func snapshotIfDue(now: Date = Date()) {
        let d = UserDefaults.standard
        guard Analytics.snapshotDue(last: d.object(forKey: Self.kSnapshot) as? Date, now: now) else { return }
        let c = AppConfig.load(from: AppPaths.config)
        let reg = ProjectRegistry.load(from: AppPaths.projects)
        let secrets = SecretStore(service: Bundle.main.bundleIdentifier ?? "io.github.example.livetips")   // presence only, no Keychain prompt
        let orgs = PacenoteAccount.shared.me?.orgs.count ?? 0
        let p: [String: Any] = [
            "route_prep": Analytics.provider(route: c.ai.prep), "route_live": Analytics.provider(route: c.ai.tips),
            "route_notes": Analytics.provider(route: c.ai.after), "route_sheet": Analytics.provider(route: c.ai.prep),
            "fallback_chain": c.ai.autoSwitch ? min(c.ai.chain.filter(\.on).count, 100) : 0,
            "tracker_on": UserDefaults.standard.object(forKey: "moduleTracker") as? Bool ?? true,
            "recording_auto": c.recording.auto,
            "server_sync": reg.projects.contains { $0.serverSync },
            "local_llm": c.ai.localFallback,
            "theme": ["system", "light", "dark"].contains(c.appearance) ? c.appearance : "system",
            "ui_lang": L10n.lang == "uk" ? "uk" : "en",
            "projects": Analytics.bucket(reg.projects.filter { !$0.sample }.count),
            "orgs": Analytics.bucket(orgs),
            "google": GoogleService.shared.connected,
            "notion": secrets.has(.notionToken),
            "hubspot": secrets.has(.hubspotKey),
            "calendars": Analytics.bucket(CalendarService.shared.calendars.count)]
        track("settings_snapshot", p)
        d.set(now, forKey: Self.kSnapshot)
    }

    /// For code that is not on the main actor (CallEngine): runs `f` on the main thread, now when already there.
    nonisolated static func onMain(_ f: @escaping @MainActor () -> Void) {
        if Thread.isMainThread { MainActor.assumeIsolated { f() } } else { DispatchQueue.main.async { MainActor.assumeIsolated { f() } } }
    }

    // MARK: S4 part 2: the call

    /// The organization of the running call (D36: where its project's calls go, else the default organization).
    private(set) var callOrg: String?
    private var callEndedAt = Date.distantPast
    private var callCounts = (tips: 0, rated: 0, asks: 0)
    private var seenTips = Set<String>()      // review 17.11: a reopened tips window reads the file from the start again

    func callStarted(request: [String: Any], tipsRoute: String) {
        let me = PacenoteAccount.shared.me
        let dir = (request["project_dir"] as? String) ?? ""
        let proj = dir.isEmpty ? nil : ProjectRegistry.load(from: AppPaths.projects).projects.first { $0.root == dir }
        let o = me.map { PacenoteServer.orgForCall(stored: "", onServer: false, linkedOrg: proj?.homeOrg ?? "", me: $0) }
        callOrg = (o?.isEmpty ?? true) ? nil : o
        callCounts = (0, 0, 0); seenTips = []
        let rec = AppConfig.load(from: AppPaths.config).recording.auto
        var p: [String: Any] = ["type": Analytics.callType(request["call_type"] as? String),
                                "sales": ((request["sales"] as? [String: Any])?["enabled"] as? Bool) ?? false,
                                "has_brief": !((request["brief"] as? String) ?? "").isEmpty,
                                "provider": Analytics.provider(route: tipsRoute), "recording": rec]
        if let o = callOrg, let org = me?.org(o) { p["org"] = org.isPersonal ? "personal" : "team" }
        track("call_started", p, o: callOrg)
        begin("first_tip")
    }

    func callEnded(minutes: Int, recorded: Bool) {
        track("call_ended", ["minutes": min(max(minutes, 0), 1440), "tips": callCounts.tips, "rated": callCounts.rated,
                             "asks": callCounts.asks, "recorded": recorded], o: callOrg)
        timers["first_tip|"] = nil
        callEndedAt = Date()          // the organization stays for the call's late events (orgFor), until the next call
    }

    /// A line of the tips file reached the window: tip_shown for a finished card (never its text), first_tip once.
    /// Only cards count (review 17.11: the file also carries acks, the deal panel, notices, retractions and context
    /// resets); each card once, by its uid.
    static let notCards: Set<String> = ["retract", "context_reset", "notice"]
    func tipLine(_ d: [String: Any]) {
        guard d["partial"] as? Bool != true, let raw = d["kind"] as? String, let uid = d["uid"] as? String, !uid.isEmpty else { return }
        let kind = Analytics.snake(raw)
        guard (Analytics.catalog.values["tip_shown.kind"] ?? []).contains(kind), !Self.notCards.contains(kind),
              seenTips.insert(uid).inserted else { return }
        callCounts.tips += 1
        track("tip_shown", ["kind": kind], o: callOrg)
        end("first_tip", o: callOrg)
    }

    /// From the tips window: a question typed, HELP NOW, a rating (the engine logs the first two locally).
    func tipsWindow(_ what: String) {
        switch what {
        case "ask": callCounts.asks += 1; track("ask_typed", o: callOrg)
        case "help": track("help_now", o: callOrg); action("help_now", scr: "tips_window", o: callOrg)
        case "rated": callCounts.rated += 1
        default: break
        }
    }

    // MARK: S4 part 2: timers and errors

    private var timers: [String: Date] = [:]

    /// A timer for `perf {what}`; `key` tells apart two of the same kind running at once (two preparations).
    func begin(_ what: String, key: String = "") { timers[what + "|" + key] = Date() }

    /// Ends the timer and tracks `perf {what, ms, provider, ok}`. A timer that never began is ignored.
    func end(_ what: String, key: String = "", provider: String? = nil, ok: Bool = true, o: String? = nil) {
        guard let t0 = timers.removeValue(forKey: what + "|" + key) else { return }
        perf(what, ms: Int(Date().timeIntervalSince(t0) * 1000), provider: provider, ok: ok, o: o)
    }

    func perf(_ what: String, ms: Int, provider: String? = nil, ok: Bool = true, o: String? = nil) {
        var p: [String: Any] = ["what": what, "ok": ok]
        if let provider { p["provider"] = provider }
        track("perf", p, ms: ms, o: o)
    }

    /// `error {area, code, provider, retry, fallback_to, fatal}`: the area and code from the fixed lists, never the text.
    func error(_ area: String, _ code: String, provider: String? = nil, retry: Int? = nil, fallbackTo: String? = nil,
               fatal: Bool = false, o: String? = nil) {
        var p: [String: Any] = ["area": area, "code": code, "fatal": fatal]
        if let provider { p["provider"] = provider }
        if let retry { p["retry"] = min(max(retry, 0), 100) }
        if let fallbackTo { p["fallback_to"] = fallbackTo }
        track("error", p, o: o)
    }

    /// At quit: app_quit, then everything is sealed for the next launch (a send at quit is not waited for).
    func quit() {
        UserDefaults.standard.set(true, forKey: Self.kClean)
        if SheetShots.active { return }
        settle()
        let mins = sessions.started.map { Int(Date().timeIntervalSince($0) / 60) } ?? 0
        track("app_quit", ["session_min": min(mins, 1440)])
        _ = queue.seal(header, now: Date())
    }

    /// Show what is sent: the batches waiting and the open events as they will go.
    func preview() -> [String: Any] {
        _ = queue.seal(header, now: Date())
        let waiting = queue.batches.compactMap { queue.read($0).map { ["route": $0.route == "events" ? "/v1/telemetry/events (signed in)" : "/v1/telemetry/batch (anonymous)", "body": $0.body] } }
        return ["note": "Pacenote analytics v2: the batches waiting to go, as they will go. Never the words of a call, names, titles or files.",
                "batches": waiting]
    }

    /// The switch turned on: read it again now.
    func switchedOn() { personalCache.at = .distantPast }

    /// The switch turned off: what waits goes away unless an organization's policy keeps it on (D45).
    func switchedOff() {
        personalCache.at = .distantPast
        if policy.values.allSatisfy({ $0 != "on" }) { queue.clear() } else { keepOnlyOrgShared() }
    }

    /// The personal switch is off but an organization keeps analytics on (D45): only that organization's events stay
    /// (review 17.11: what was collected while the switch was on must not go after it is turned off).
    private func keepOnlyOrgShared() {
        _ = queue.seal(header, now: Date())
        let on = Set(policy.filter { $0.value == "on" }.keys.map { $0.lowercased() })
        let me = PacenoteAccount.shared.me
        let def = me?.defaultOrg?.isPersonal == false ? me?.defaultOrg?.id.lowercased() : nil
        queue.filter { route, ev in
            guard route == "events" else { return false }
            let o = (ev["o"] as? String)?.lowercased() ?? def
            return o.map { on.contains($0) } ?? false
        }
    }

    /// Sign-out (review 17.11): what waits for this account goes now with its token; what could not go is dropped, so
    /// nothing of it goes later with another account's token.
    func signingOut() async {
        settle()
        await flush(why: "sign_out", force: true)
        _ = queue.seal(header, now: Date())
        queue.filter { route, _ in route != "events" }
    }
}

/// 0.19.0 (D45): the names of the organizations whose signed policy shares usage (`usage_analytics = on`), for the line
/// under Help improve Pacenote in Settings > General > Privacy.
@MainActor
enum AnalyticsOrgLine {
    static var orgs: [String] {
        let pol = EntitlementsStore.shared.rights.analyticsPolicy
        return (PacenoteAccount.shared.me?.orgs ?? []).filter { !$0.isPersonal && pol[$0.id.lowercased()] == "on" }.map(\.name)
    }
}

/// 0.19.0 (S4): `screen_view` when a view appears and when its part (tab, step, mode) changes.
struct ScreenTrack: ViewModifier {
    let scr: String
    let sub: String?
    let o: String?
    var on = true
    func body(content: Content) -> some View {
        content
            .onAppear { if on { AnalyticsTracker.shared.screen(scr, sub: sub, o: o) } }
            .onChange(of: sub) { _, new in if on { AnalyticsTracker.shared.screen(scr, sub: new, o: o) } }
    }
}

extension View {
    /// `scr` is a key of `screens` in rules/analytics.yaml and `sub` one of its parts (CoreChecks scans these calls).
    /// `on: false` for a view shown inside another screen (the Setup tab of a call page).
    func trackScreen(_ scr: String, sub: String? = nil, o: String? = nil, on: Bool = true) -> some View {
        modifier(ScreenTrack(scr: scr, sub: sub, o: o, on: on))
    }
}
