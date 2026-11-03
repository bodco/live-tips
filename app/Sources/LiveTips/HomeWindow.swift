import AppKit
import SwiftUI
import LiveTipsCore

/// Home, the app's main window (Pacenote 0.8, F3, REDESIGN-SPEC 4): one question, "what is next and am I ready".
/// Left: the next call (or the live one) with its readiness checks and one main action, then Later. Right: On you,
/// This week (no dollars) and Recent. A status line at the bottom says what is connected, in red only when not.
@MainActor
final class HomeWindow {
    static var window: NSWindow?

    static func show(delegate: AppDelegate) {
        if let w = window {
            w.title = L("home.window.title")
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(contentViewController: NSHostingController(rootView: Localized { HomeView(app: delegate) }))
        w.tabbingMode = .disallowed      // 0.8.7 (A1): never tabs
        w.title = L("home.window.title")
        w.styleMask.insert(.resizable)
        w.setContentSize(NSSize(width: 1120, height: 760))
        w.contentMinSize = NSSize(width: 640, height: 480)     // 0.8.7.1: narrower, the call page was cut on the right
        w.isReleasedWhenClosed = false
        _ = w.setFrameAutosaveName("LiveTipsHome")
        window = w
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// The full statistics (Home > This week > Details): the insights dashboard with its period and project filters.
@MainActor
enum InsightsWindow {
    static var window: NSWindow?
    static func show() { HomeNav.shared.open(.stats) }     // 0.8.7 (A2): pushed into Home
}

/// One call ahead: a calendar event (with its Up next setup, if any) or an Up next call without an event.
private struct Ahead: Identifiable {
    var id: String
    var event: CalendarService.CalEvent?
    var model: StartCallModel?
    var start: Date
    var end: Date? { event?.end }
    @MainActor var title: String { model?.effectiveTitle ?? event?.title ?? "" }
}

/// 0.9.0 (redesign, owner 2026-11-03): the state of one call, shown as a soft pill and the colour of its dot on the
/// Coming up line and on Recent calls. Colours are by status, never by project.
enum CallState {
    case notReady, ready, preparing, queued, failed, live, recorded, notTranscribed, noBrief

    var color: Color {
        switch self {
        case .notReady, .failed, .noBrief: return PN.C.pending
        case .ready: return PN.C.turn
        case .preparing, .queued: return PN.C.accent
        case .live: return PN.C.danger
        case .recorded: return PN.C.answer
        case .notTranscribed: return PN.C.text3
        }
    }

    var text: String {
        switch self {
        case .notReady: return L("home.state.notReady")
        case .ready: return L("home.state.ready")
        case .preparing: return L("badge.preparing")
        case .queued: return L("badge.queued")
        case .failed: return L("badge.failed")
        case .live: return L("home.live")
        case .recorded: return L("home.state.recorded")
        case .notTranscribed: return L("home.state.notTranscribed")
        case .noBrief: return L("home.state.noBrief")
        }
    }
}

extension CallState {
    static func of(_ s: UpNext.PrepState, ai: Bool) -> CallState {
        switch s {
        case .ready: return .ready
        case .running: return .preparing
        case .queued: return .queued
        case .failed: return .failed
        case .none: return ai ? .notReady : .noBrief
        }
    }
}

/// A small soft pill: tinted text on a light fill of the same colour (no loud fills on Home).
struct StatePill: View {
    let state: CallState
    var text: String? = nil
    var body: some View {
        Text(text ?? state.text).font(.system(size: 11, weight: .semibold)).foregroundStyle(state.color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(state.color.opacity(0.13), in: Capsule())
            .lineLimit(1).fixedSize()
    }
}

struct HomeView: View {
    let app: AppDelegate
    @ObservedObject var cal = CalendarService.shared
    @ObservedObject var upnext = UpNext.shared
    @ObservedObject var history = CallHistory.shared
    @ObservedObject var runner = PrepRunner.shared
    @ObservedObject var register = Register.shared
    @ObservedObject var ntasks = NotionTasks.shared
    @ObservedObject var auto = AutoStart.shared            // Pacenote 0.8: "Start tips for ...?" when a call begins
    @State private var now = Date()
    @State private var status = EngineStatus()
    @State private var note = ""
    @State private var pickCalendars = false
    @State private var showAllCalls = false
    @State private var hiddenNow: [String] = []           // 0.9.0: hidden in this session, for Undo
    /// 0.9.0 (phase 3 adds Settings > Modules): the Tracker screen in the navigation; on until the module switch exists.
    @AppStorage("moduleTracker") private var trackerOn = true

    private var live: Bool { CallEngine.shared.isRunning || ["recording", "standby", "loading_model"].contains(status.state) }
    private var demo: Bool { ProcessInfo.processInfo.environment["LT_SUPPORT_DIR"] != nil }
    /// Shot mode (p090): "", "nocal", "noai" or "first", to picture the integration states on demo data.
    nonisolated(unsafe) static var shotState = ""

    @ObservedObject var nav = HomeNav.shared

    var body: some View {
        NavigationStack(path: $nav.path) {
            homeBody.navigationDestination(for: HomeNav.Route.self) { r in HomeRouteView(route: r) }
        }
    }

    // MARK: states (rules: what the PM has connected)

    /// Something can write a brief and tips: Claude Code signed in, a Claude API key, or the ChatGPT account route.
    private var aiReady: Bool { Self.aiReadyNow() }

    /// Something can write a brief and tips (shared with the call pages).
    @MainActor static func aiReadyNow() -> Bool {
        let demo = ProcessInfo.processInfo.environment["LT_SUPPORT_DIR"] != nil
        let runner = PrepRunner.shared
        if demo { return !["noai", "first"].contains(Self.shotState) }
        let s = SettingsWindow.model
        if [s.config.ai.prep, s.config.ai.tips, s.config.ai.after].contains(AIRoute.codex) && CodexAccount.cliPath != nil { return true }
        if runner.hasAPIKey { return true }
        if [s.config.ai.prep, s.config.ai.tips, s.config.ai.after].contains(AIRoute.openai) && runner.hasOpenAIKey { return true }
        return runner.loggedIn == true || (runner.loggedIn == nil && PrepRunner.claudePath != nil)
    }
    private var calendarOn: Bool { demo ? !["nocal", "first"].contains(Self.shotState) : cal.access == .granted }
    private var firstLaunch: Bool { demo ? Self.shotState == "first" : (!aiReady && !calendarOn && history.records.isEmpty) }

    private var homeBody: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 24).padding(.vertical, 12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    titleBlock
                    if let e = auto.suggestion, !live { autoBanner(e) }
                    if !note.isEmpty { Text(note).font(PN.Font.body).foregroundStyle(PN.C.onMe) }
                    mainBlock
                    if !firstLaunch && calendarOn { comingUp }
                    if !firstLaunch { recentCalls }
                }
                .padding(24)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)      // 0.9.0 (owner): centred on a wide window
            }
        }
        .background(PN.C.bg)
        .frame(minWidth: 680, minHeight: 560)
        .onAppear { tick(); cal.refresh(); history.scan(); upnext.pruneHeld(); upnext.adoptPreparedEvents(); register.importOnce(); ntasks.keepFresh()
                    runner.refreshAuth() }
        .onDrop(of: [.fileURL], isTargeted: nil) { items in          // 0.8.6 (B): drop a recording on Home
            _ = items.first?.loadObject(ofClass: URL.self) { u, _ in
                if let u = u, TranscribeWindow.accepts(u) { DispatchQueue.main.async { MainActor.assumeIsolated { TranscribeWindow.show(file: u) } } }
            }
            return true
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in upnext.adoptPreparedEvents() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in tick() }
    }

    private func tick() {
        now = Date()
        status = EngineStatus.load(path: CallEngine.shared.statusPath)
    }

    // MARK: header: logo, Home / Tracker, the integrations pill, search, transcribe, Start a call now, Settings

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            PacenoteSymbol(height: 20).accessibilityLabel(L("app.name"))
            HStack(spacing: 2) {
                navTab(L("home.nav.home"), selected: true) { nav.path = [] }
                if trackerOn { navTab(L("home.nav.tracker"), selected: false) { nav.open(.tracker) } }
            }
            integrationsPill
            Spacer(minLength: 8)
            ViewThatFits(in: .horizontal) { headerButtons(icons: false); headerButtons(icons: true) }
        }
    }

    private func navTab(_ title: String, selected: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(title).font(PN.Font.body.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? PN.C.text : PN.C.text2)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(selected ? PN.C.surface2 : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func headerButtons(icons: Bool) -> some View {
        HStack(spacing: 10) {
            if history.records.isEmpty {
                Button { StartCallWindow.show(delegate: app) } label: { headerLabel(L("memory.button"), "magnifyingglass", icons) }
                    .buttonStyle(.pnTertiary).opacity(0.5).help(L("memory.afterFirst"))
            } else {
                Button { MemoryWindow.show() } label: { headerLabel(L("memory.button"), "magnifyingglass", icons) }
                    .buttonStyle(.pnTertiary).keyboardShortcut("f", modifiers: .command).help(L("memory.help")).fixedSize()
            }
            // 0.8.6 (B), owner 2026-11-03: Transcribe stays in the header, next to search
            Button { TranscribeWindow.show() } label: { headerLabel(L("tr.window"), "waveform", icons) }
                .buttonStyle(.pnTertiary).help(L("tr.subtitle")).fixedSize()
            if !live {
                HStack(spacing: 2) {
                    Button(L("home.startCallNow")) { StartCallWindow.show(delegate: app) }
                        .buttonStyle(.pnPrimary).keyboardShortcut("n", modifiers: .command).fixedSize()
                    Menu {
                        Button(L("home.planCall")) { StartCallWindow.show(delegate: app, planOnly: true) }
                    } label: { Image(systemName: "chevron.down") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help(L("home.planCall.help")).accessibilityLabel(L("home.planCall"))
                }
            }
            Button { SettingsWindow.show() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.pnTertiary).help(L("home.settings")).accessibilityLabel(L("home.settings"))
        }
    }

    @ViewBuilder private func headerLabel(_ title: String, _ symbol: String, _ icons: Bool) -> some View {
        if icons { Image(systemName: symbol).accessibilityLabel(title) } else { Label(title, systemImage: symbol) }
    }

    /// 0.9.0: what the old status line and Finish setup said, as one pill shown only when something needs the PM.
    private struct Problem: Identifiable { var id: String; var text: String; var run: () -> Void }

    private var problems: [Problem] {
        if demo && !Self.shotState.isEmpty && !firstLaunch {
            return (aiReady ? [] : [Problem(id: "ai", text: L("home.pill.claude"), run: {})]) + (calendarOn ? [] : [Problem(id: "cal", text: L("home.status.noCalendars"), run: {})])
        }
        guard !demo, !firstLaunch else { return [] }
        let cfg = AppConfig.load(from: AppPaths.config)
        var out: [Problem] = []
        if !CallEngine.shared.problems().isEmpty { out.append(Problem(id: "install", text: L("home.finish.install"), run: { SetupWindow.show() })) }
        if !aiReady { out.append(Problem(id: "ai", text: L("home.pill.claude"), run: { SettingsWindow.show(tab: "ai") })) }
        if !calendarOn { out.append(Problem(id: "cal", text: L("home.status.noCalendars"), run: { SettingsWindow.show(tab: "calendars") })) }
        if !cfg.workRoot.isEmpty, SettingsWindow.model.isSet(.notionToken), MirrorStatus.load(workRoot: cfg.workRoot).health() != "ok" {
            out.append(Problem(id: "notion", text: L("home.status.notionStale"), run: { SettingsWindow.show(tab: "notion") }))
        }
        if SpendLedger.monthSpent() >= cfg.budget.monthlyHardUSD * 0.9 {
            out.append(Problem(id: "limit", text: L("home.status.limit"), run: { SettingsWindow.show(tab: "ai") }))
        }
        if SettingsWindow.model.config.nameAliases.isEmpty {
            out.append(Problem(id: "name", text: L("home.finish.name"), run: { SettingsWindow.show(tab: "general") }))
        }
        return out
    }

    @ViewBuilder private var integrationsPill: some View {
        let ps = problems
        if ps.count == 1, let p = ps.first {
            Button(action: p.run) { pillLabel(p.text) }.buttonStyle(.plain)
        } else if ps.count > 1 {
            Menu { ForEach(ps) { p in Button(p.text, action: p.run) } } label: { pillLabel(L("home.pill.n", ["n": "\(ps.count)"])) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }

    private func pillLabel(_ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(PN.C.pending).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(text).lineLimit(1)
        }
        .font(PN.Font.caption.weight(.medium)).foregroundStyle(PN.C.pending)
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(PN.C.pending.opacity(0.12), in: Capsule())
    }

    // MARK: the sentence on top

    private var titleBlock: some View {
        let df = DateFormatter()
        df.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US")
        df.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return VStack(alignment: .leading, spacing: 4) {
            Text(df.string(from: now)).font(PN.Font.body).foregroundStyle(PN.C.text3)
            Text(titleText).font(.system(size: 26, weight: .bold)).foregroundStyle(PN.C.text)
        }
    }

    private var titleText: String {
        if firstLaunch { return L("home.title.welcome") }
        if live { return L("home.title.live") }
        guard calendarOn || !upnext.visible.isEmpty, let n = nextCall else { return L("home.title.whenReady") }
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        let m = Int((n.start.timeIntervalSince(now) / 60).rounded())
        if m <= 0 { return n.title }
        if m < 90 { return L("home.title.nextIn", ["n": "\(m)"]) }
        if Calendar.current.isDateInTomorrow(n.start) { return L("home.title.nextTomorrow", ["t": tf.string(from: n.start)]) }
        return L("home.title.nextAt", ["t": tf.string(from: n.start)])
    }

    // MARK: calls ahead

    private var ahead: [Ahead] {
        var rows: [Ahead] = []
        var used = Set<ObjectIdentifier>()
        let ce = CallEngine.shared
        let liveKey = ce.isRunning ? EditLog.seriesKey(ce.renamed ?? (ce.callRequest["title"] as? String) ?? "") : ""
        for e in (calendarOn ? cal.upcoming(now) : []) {
            // 2026-10-28 (owner): the call being recorded is shown once, as live, not again as ahead.
            if ce.isRunning, e.id == ce.liveEventID || (!liveKey.isEmpty && EditLog.seriesKey(e.title) == liveKey && e.start <= now.addingTimeInterval(15 * 60)) { continue }
            let m = upnext.visible.first { $0.calEventID == e.id }
            if let m = m { used.insert(ObjectIdentifier(m)) }
            rows.append(Ahead(id: e.id, event: e, model: m, start: e.start))
        }
        for m in upnext.visible where !used.contains(ObjectIdentifier(m)) {
            rows.append(Ahead(id: m.id.uuidString, event: nil, model: m, start: m.callDate))
        }
        return rows.sorted { $0.start < $1.start }
    }

    /// The next call: an Up next call, or an event that began less than 5 minutes ago.
    private var nextCall: Ahead? { live ? nil : ahead.first { $0.event == nil || $0.start > now.addingTimeInterval(-5 * 60) } }

    @ViewBuilder private var mainBlock: some View {
        if live { liveCard }
        else if firstLaunch { stepsCard }
        else if !calendarOn {
            seeYourDay
            if let n = nextCall { upNextCard(n, overlaps: []) }      // a call planned by hand still shows
        }
        else if let n = nextCall { upNextCard(n, overlaps: overlaps(n, ahead)) }
        else { nothingAhead }
    }

    private func overlaps(_ r: Ahead, _ rows: [Ahead]) -> [CalendarService.CalEvent] {
        guard let e = r.event else { return [] }
        return rows.compactMap(\.event).filter { $0.id != e.id && e.overlaps($0) }
    }

    private func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c().padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.l))
    }

    /// No calendar: the day cannot be shown; a call can still be started or planned by hand.
    private var seeYourDay: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("home.seeDay.title")).font(.system(size: 17, weight: .semibold)).foregroundStyle(PN.C.text)
                Text(L("home.seeDay.body")).font(PN.Font.body).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(L("home.connectCalendar")) { cal.connect() }.buttonStyle(.pnPrimary)
                    Button(L("home.planByHand")) { StartCallWindow.show(delegate: app, planOnly: true) }.buttonStyle(.pnSecondary)
                }
                .padding(.top, 4)
            }
        }
    }

    private var nothingAhead: some View {
        card {
            HStack(spacing: 10) {
                Text(L("home.nothingAhead")).font(PN.Font.body).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(L("home.planCall")) { StartCallWindow.show(delegate: app, planOnly: true) }.buttonStyle(.pnTertiary)
            }
        }
    }

    /// First launch: three steps instead of a call card; Coming up and Recent calls stay hidden.
    private var stepsCard: some View {
        let notion = SettingsWindow.model.isSet(.notionToken)
        return card {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("home.steps.title")).font(.system(size: 17, weight: .semibold)).foregroundStyle(PN.C.text)
                step(1, L("home.steps.claude"), L("home.steps.claude.sub"), done: aiReady) { SettingsWindow.show(tab: "ai") }
                step(2, L("home.steps.calendar"), L("home.steps.calendar.sub"), done: calendarOn) { cal.connect() }
                step(3, L("home.steps.notion"), L("home.steps.notion.sub"), done: notion) { SettingsWindow.show(tab: "notion") }
            }
        }
        .frame(maxWidth: 680)      // 0.9.0 (owner): a compact card, not the full width of a wide window
    }

    private func step(_ n: Int, _ title: String, _ sub: String, done: Bool, run: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(done ? PN.C.turn.opacity(0.15) : PN.C.surface2).frame(width: 26, height: 26)
                if done { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(PN.C.turn) }
                else { Text("\(n)").font(PN.Font.section).foregroundStyle(PN.C.text2) }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(PN.Font.body.weight(.semibold)).foregroundStyle(PN.C.text)
                Text(sub).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            Spacer(minLength: 8)
            if done { Text(L("home.steps.done")).font(PN.Font.caption).foregroundStyle(PN.C.turn) }
            else { Button(L("home.finish.connect"), action: run).buttonStyle(.pnSecondary) }
        }
    }

    private var liveCard: some View {
        let ce = CallEngine.shared
        let title = ce.renamed ?? (ce.callRequest["title"] as? String) ?? status.project ?? L("app.name")
        let since = status.startedAt.flatMap { ISO8601DateFormatter().date(from: $0) }
        return card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    StatePill(state: .live, text: status.state == "standby" ? L("menubar.status.waiting") : L("home.live"))
                    if let s = since, status.state == "recording" {
                        Text(s, style: .timer).monospacedDigit().font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    }
                }
                Text(title).font(.system(size: 20, weight: .semibold)).foregroundStyle(PN.C.text).lineLimit(2)
                if let p = status.project { Text(p).font(PN.Font.body).foregroundStyle(PN.C.text2) }
                HStack(spacing: 8) {
                    Button(L("menubar.showTips")) { app.showTips() }.buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
                    Button(L("menubar.endCall")) { app.endCall() }.buttonStyle(.pnSecondary)
                }
                .padding(.top, 4)
            }
        }
    }

    private func platform(_ e: CalendarService.CalEvent?) -> String {
        guard let l = e?.link?.lowercased() else { return "" }
        if l.contains("zoom") { return "Zoom" }
        if l.contains("meet.google") { return "Google Meet" }
        if l.contains("teams") { return "Microsoft Teams" }
        return ""
    }

    /// "Emily R., Jake T. and Sarah M."
    static func peopleLine(_ names: [String]) -> String {
        let n = names.prefix(4).map { $0 }
        guard n.count > 1 else { return n.first ?? "" }
        return n.dropLast().joined(separator: ", ") + L("home.card.and") + (n.last ?? "")
    }

    private func state(of r: Ahead) -> CallState {
        if r.event?.relative(now) == "in progress" { return .live }
        guard let m = r.model else { return aiReady ? .notReady : .noBrief }
        switch upnext.prepState(m) {
        case .ready: return .ready
        case .running: return .preparing
        case .queued: return .queued
        case .failed: return .failed
        case .none: return aiReady ? .notReady : .noBrief
        }
    }

    /// One main button and one text link under it (rules of the mockup, 1.2).
    private func upNextCard(_ r: Ahead, overlaps: [CalendarService.CalEvent]) -> some View {
        let m = r.model
        let st = state(of: r)
        let fresh = m.flatMap { Freshness.check($0) }
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        let people = Self.peopleLine(r.event?.attendees ?? m?.participants ?? [])
        let meta1 = [tf.string(from: r.start) + (r.end.map { "-" + tf.string(from: $0) } ?? ""), platform(r.event), m.map { $0.target.isEmpty ? "" : $0.targetName } ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        let briefText: String = {
            switch st {
            case .ready: return fresh?.stale == true ? fresh!.line : L("home.brief.ready")
            case .preparing: return L("home.check.preparing", ["p": "\(Int(runner.progress * 100))"])
            case .queued: return L("badge.queued")
            case .failed: return L("badge.failed")
            case .noBrief: return L("home.recordsOnly")
            default: return L("home.brief.notReady")
            }
        }()
        let meta2 = [people.isEmpty ? "" : L("home.card.with", ["people": people]), briefText].filter { !$0.isEmpty }.joined(separator: " · ")
        return card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(meta1).font(PN.Font.caption.weight(.medium)).foregroundStyle(PN.C.text3)
                    Spacer()
                    StatePill(state: st)
                }
                Button { openCall(r) } label: {
                    Text(r.title).font(.system(size: 22, weight: .bold)).foregroundStyle(PN.C.text).lineLimit(2).multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain).help(L("home.openCall.help"))
                Text(meta2).font(PN.Font.body).foregroundStyle(PN.C.text2).lineLimit(2)
                ForEach(overlaps, id: \.id) { e in
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(PN.C.pending).accessibilityHidden(true)
                        Text(L("home.check.overlaps", ["title": e.title])).font(PN.Font.caption).foregroundStyle(PN.C.text2)
                        link(L("home.overlap.hide")) { hide(e.id) }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    mainAction(r, st)
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder private func mainAction(_ r: Ahead, _ st: CallState) -> some View {
        switch st {
        case .noBrief:
            Button { start(r) } label: { Label(L("home.startCall"), systemImage: "play.fill") }.buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
            link(L("home.connectClaude")) { SettingsWindow.show(tab: "ai") }
        case .ready, .live:
            Button { start(r) } label: { Label(live ? L("home.switch") : L("home.startCall"), systemImage: "play.fill") }.buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
            if st == .ready { link(L("talk.prepareAgain")) { StartCallWindow.show(delegate: app, prepared: model(for: r)) } }
            else { link(L("home.getReady")) { prepare(r) } }
        case .preparing, .queued:
            Button { start(r) } label: { Label(L("home.startCall"), systemImage: "play.fill") }.buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
            link(L("common.cancel")) { if st == .preparing { runner.cancel() } else if let m = r.model { upnext.unqueue(m) } }
        default:
            Button(L("home.getReady")) { prepare(r) }.buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
            link(L("home.startWithout")) { start(r) }
        }
    }

    private func link(_ t: String, run: @escaping () -> Void) -> some View {
        Button(action: run) { Text(t).font(PN.Font.body).foregroundStyle(PN.C.accent) }.buttonStyle(.plain)
    }

    /// Pacenote 0.8 (idea 08): "Start tips for Orbit weekly?" when a meeting app is on at a calendar call.
    private func autoBanner(_ e: CalendarService.CalEvent) -> some View {
        let m = auto.model(for: e)
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: "waveform").foregroundStyle(PN.C.accent).frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("auto.title", ["title": e.title])).font(PN.Font.body.weight(.semibold)).foregroundStyle(PN.C.text)
                Text(m.target.isEmpty ? L("auto.chooseProject") : L("auto.body", ["project": m.targetName]))
                    .font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            Spacer(minLength: 8)
            Button(L("auto.notNow")) { auto.dismiss() }.buttonStyle(.pnTertiary)
            Button(L("home.startTips")) { auto.accept() }.buttonStyle(.pnPrimary)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.m))
    }

    // MARK: Coming up: the rest of today and tomorrow on one line

    private var comingUp: some View {
        let first = nextCall?.id
        let rest = ahead.filter { $0.id != first }
        let near = rest.filter { Calendar.current.isDateInToday($0.start) || Calendar.current.isDateInTomorrow($0.start) || $0.start < now }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(L("home.comingUp")).font(.system(size: 15, weight: .semibold)).foregroundStyle(PN.C.text)
                if !hiddenNow.isEmpty {
                    Text(L("home.hiddenUndo", ["n": "\(hiddenNow.count)"])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    Button(L("ntask.undo")) { undoHide() }.buttonStyle(.pnTertiary)
                }
                Spacer()
                if cal.access == .granted {
                    Button(L("home.calendars")) { pickCalendars = true }.buttonStyle(.pnTertiary)
                        .popover(isPresented: $pickCalendars, arrowEdge: .bottom) { CalendarPicker() }
                }
                if !rest.isEmpty {
                    Button(showAllCalls ? L("ntask.showLess") : L("home.allCalls", ["n": "\(ahead.count)"])) { showAllCalls.toggle() }.buttonStyle(.pnTertiary)
                }
            }
            if near.isEmpty && !showAllCalls {
                Text(L("home.later.empty")).font(PN.Font.body).foregroundStyle(PN.C.text3)
            } else if !near.isEmpty {
                timeline(near)
            }
            if showAllCalls && !rest.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(rest.enumerated()), id: \.element.id) { i, r in
                        if i > 0 { Divider() }
                        listRow(r)
                    }
                }
                .padding(.horizontal, 6)
                .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.m))
            }
        }
    }

    private func timeline(_ rows: [Ahead]) -> some View {
        let firstTomorrow = rows.firstIndex { Calendar.current.isDateInTomorrow($0.start) }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                    if i == firstTomorrow {
                        VStack(alignment: .leading, spacing: 8) {
                            ZStack(alignment: .leading) {
                                Rectangle().fill(PN.C.accent.opacity(0.25)).frame(height: 2)
                                Rectangle().fill(PN.C.accent).frame(width: 2, height: 14)
                            }
                            .frame(height: 14)
                            Text(L("home.tomorrowCaps")).font(PN.Font.label).foregroundStyle(PN.C.accent)
                        }
                        .frame(width: 92, alignment: .leading)
                    }
                    node(r)
                }
            }
            .padding(.bottom, 4)
        }
    }

    private func node(_ r: Ahead) -> some View {
        let st = state(of: r)
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        let proj = r.model.map { $0.target.isEmpty ? "" : $0.targetName } ?? ""
        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .leading) {
                Rectangle().fill(PN.C.accent.opacity(0.25)).frame(height: 2)
                Circle().fill(st.color).frame(width: 12, height: 12)
                    .overlay(Circle().stroke(PN.C.bg, lineWidth: 2))
            }
            .frame(height: 14)
            Text([tf.string(from: r.start), proj].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(PN.Font.caption.weight(.semibold)).foregroundStyle(st.color).lineLimit(1)
            Button { openCall(r) } label: {
                Text(r.title).font(PN.Font.body.weight(.medium)).foregroundStyle(PN.C.text).lineLimit(2).multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain).help(L("home.openCall.help"))
            HStack(spacing: 6) {
                StatePill(state: st)
                callMenu(r, st)
            }
        }
        .frame(width: 200, alignment: .leading)
        .padding(.trailing, 12)
        .contextMenu { callMenuItems(r, st) }
    }

    private func callMenu(_ r: Ahead, _ st: CallState) -> some View {
        Menu { callMenuItems(r, st) } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(L("home.more"))
    }

    /// "…": Get ready or Prepare again, Not my call (no Start here: a call starts from its card or its page).
    @ViewBuilder private func callMenuItems(_ r: Ahead, _ st: CallState) -> some View {
        if st == .ready { Button(L("talk.prepareAgain")) { StartCallWindow.show(delegate: app, prepared: model(for: r)) } }
        else if st == .notReady || st == .failed { Button(L("home.getReady")) { prepare(r) } }
        if st == .queued, let m = r.model { Button(L("common.cancel")) { upnext.unqueue(m) } }
        if st == .preparing { Button(L("common.cancel")) { runner.cancel() } }
        Divider()
        if let e = r.event { Button(L("home.notMine")) { hide(e.id) } }
        else { Button(L("home.removeUpNext")) { if let m = r.model { upnext.remove(m) } } }
    }

    /// The full list behind "All N calls": the same row as the timeline node, in a list.
    private func listRow(_ r: Ahead) -> some View {
        let st = state(of: r)
        let f = DateFormatter(); f.dateFormat = Calendar.current.isDateInToday(r.start) ? "HH:mm" : "EEE d MMM HH:mm"
        f.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US")
        let m = r.model
        let people = (r.event?.attendees ?? m?.participants ?? []).prefix(3).joined(separator: ", ")
        let sub = [m.map { $0.target.isEmpty ? "" : $0.targetName } ?? "", people].filter { !$0.isEmpty }.joined(separator: " · ")
        return HStack(alignment: .center, spacing: 12) {
            Circle().fill(st.color).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(f.string(from: r.start)).font(PN.Font.body.monospacedDigit()).foregroundStyle(PN.C.text3).frame(width: 120, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Button { openCall(r) } label: { Text(r.title).font(PN.Font.body.weight(.medium)).foregroundStyle(PN.C.text).lineLimit(1) }.buttonStyle(.plain)
                if !sub.isEmpty { Text(sub).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(1) }
            }
            Spacer(minLength: 8)
            StatePill(state: st)
            callMenu(r, st)
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu { callMenuItems(r, st) }
    }

    private func hide(_ id: String) {
        cal.hidden.insert(id)
        hiddenNow.append(id)
    }

    private func undoHide() {
        guard let id = hiddenNow.popLast() else { return }
        _ = cal.hidden.remove(id)
    }

    // MARK: Recent calls: three cards

    private var recentCalls: some View {
        let rs = Array(history.visible.prefix(3))
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("home.recentCalls")).font(.system(size: 15, weight: .semibold)).foregroundStyle(PN.C.text)
                Spacer()
                if !history.visible.isEmpty { Button(L("home.allPast")) { nav.open(.pastCalls) }.buttonStyle(.pnTertiary) }
            }
            if rs.isEmpty {
                Text(L("home.recent.empty")).font(PN.Font.body).foregroundStyle(PN.C.text3)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], alignment: .leading, spacing: 14) {
                    ForEach(rs) { r in RecentCard(r: r, aiReady: aiReady) { history.hide(r) } }
                }
            }
        }
    }

    // MARK: actions

    /// The call's page (0.9.0 phase 2): Setup, Brief, Tasks, Earlier calls; any upcoming call starts from there.
    private func openCall(_ r: Ahead) { UpcomingPages.open(model(for: r)) }

    /// The Up next call behind a row; for a calendar event one is made (set up like the last call of its series).
    private func model(for r: Ahead) -> StartCallModel {
        if let m = r.model { return m }
        let m = StartCallModel()
        if let e = r.event { m.applyEvent(e) }       // also adopts a preparation not used yet
        return m
    }

    /// Asks first: the project or workspace and what matters on this call (the call form in Prepare mode).
    private func prepare(_ r: Ahead) { StartCallWindow.show(delegate: app, prepared: model(for: r), mode: .prepare) }

    private func start(_ r: Ahead) {
        let m = model(for: r)
        m.useDefaultTargetIfEmpty()     // 0.9.0 (owner): no project chosen: the app's own live folder
        if live {
            upnext.save(m)
            app.confirmSwitch(to: m, on: HomeWindow.window)
        } else if let e = app.launch(m) {
            note = e
        }
    }

    static func hm(_ m: Double) -> String {
        let t = Int(m.rounded())
        return t >= 60 ? L("home.hm", ["h": "\(t / 60)", "m": "\(t % 60)"]) : L("home.m", ["m": "\(t)"])
    }

    static func relativeText(_ d: Date, now: Date) -> String {
        let m = Int((d.timeIntervalSince(now) / 60).rounded())
        if m <= 0 { return "" }
        if m < 90 { return L("home.inMin", ["n": "\(m)"]) }
        if Calendar.current.isDateInTomorrow(d) { return L("home.tomorrow") }
        return ""
    }
}

/// 0.9.0: a Recent calls card. Click: the call page. Right-click: what the old Recent row menu had.
struct RecentCard: View {
    let r: CallHistory.Record
    let aiReady: Bool
    var onHide: () -> Void
    @State private var hover = false

    var body: some View {
        let o = OutcomeCache.shared.outcome(r.file)
        let sentence = Self.summary(r.file)
        let transcribed = (r.lines ?? 1) > 0
        let st: CallState = transcribed ? .recorded : .notTranscribed
        let counts = Self.counts(o)
        let series = CallPageView.series(of: r).count
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(st.color).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(Self.when(r)).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(1)
                Spacer(minLength: 0)
                if let src = r.source {
                    Text(L(src == "link" ? "tr.mark.link" : "tr.mark.file")).font(.system(size: 10, weight: .bold)).foregroundStyle(PN.C.text2)
                        .padding(.horizontal, 4).padding(.vertical, 1).background(PN.C.surface2, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            Text(r.title).font(PN.Font.body.weight(.semibold)).foregroundStyle(PN.C.text).lineLimit(2)
            if !transcribed {
                Text(L("home.state.notTranscribed")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            } else if let s = sentence {
                Text(s).font(PN.Font.caption).foregroundStyle(PN.C.text2).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            } else if aiReady {
                Text(L("home.noNotes")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            } else {
                Text(L("home.transcriptSaved")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                Button(L("home.noNotes.connect")) { SettingsWindow.show(tab: "ai") }.buttonStyle(.plain).font(PN.Font.caption).foregroundStyle(PN.C.accent)
            }
            Spacer(minLength: 0)
            if !counts.isEmpty { Text(counts).font(PN.Font.caption.weight(.medium)).foregroundStyle(PN.C.text3) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.m))
        .overlay(RoundedRectangle(cornerRadius: PN.Radius.m).stroke(PN.C.accent.opacity(hover ? 0.35 : 0), lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { CallPageWindow.show(file: r.file) }
        .contextMenu {
            if let u = r.notionURL.flatMap({ URL(string: $0) }) { Button(L("home.recent.notion")) { NSWorkspace.shared.open(u) } }
            Button(L("home.recent.transcript")) { TranscriptWindow.show(file: r.file) }
            Button(L("call.page.followup")) { FollowUpWindow.show(file: r.file) }
            if series > 1 { Button(L("call.page.series", ["n": "\(series)"])) { SeriesWindow.show(record: r) } }
            Button(L("home.recent.finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.file)]) }
            Divider()
            Button(L("home.recent.hide"), action: onHide)
        }
        .help(L("home.recent.help.page"))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// "3 decisions · 1 task"
    static func counts(_ o: CallOutcome?) -> String {
        guard let o = o else { return "" }
        var parts: [String] = []
        let d = o.decisions.count, t = o.onMe.count
        if d > 0 { parts.append(L(d == 1 ? "home.count.decision" : "home.count.decisions", ["n": "\(d)"])) }
        if t > 0 { parts.append(L(t == 1 ? "home.count.task" : "home.count.tasks", ["n": "\(t)"])) }
        return parts.joined(separator: " · ")
    }

    /// "Today · 14:30 · 25 min"
    static func when(_ r: CallHistory.Record) -> String {
        let c = Calendar.current
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        let df = DateFormatter(); df.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US"); df.setLocalizedDateFormatFromTemplate("EEEdMMM")
        let day = c.isDateInToday(r.start) ? L("home.today") : c.isDateInYesterday(r.start) ? L("home.yesterday") : df.string(from: r.start)
        let mins = r.minutes.map { L("call.page.minutes", ["n": "\(max(1, Int($0.rounded())))"]) } ?? ""
        return [day, tf.string(from: r.start), mins].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// One sentence from the call notes (<stem>.notes.md, rules/notes.yaml): the first line of the Summary section.
    static func summary(_ file: String) -> String? {
        let notes = (file.hasSuffix(".md") ? String(file.dropLast(3)) : file) + ".notes.md"
        guard let text = try? String(contentsOfFile: notes, encoding: .utf8) else { return nil }
        var inSummary = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("#") { inSummary = l.lowercased().contains("summary") || l.lowercased().contains("підсумок") || l.lowercased().contains("коротко"); continue }
            guard inSummary, !l.isEmpty else { continue }
            var s = l.replacingOccurrences(of: "^[-*•]\\s*", with: "", options: .regularExpression)
            if let r = s.range(of: "(?<=[.!?])\\s", options: .regularExpression) { s = String(s[..<r.lowerBound]) }
            return s.isEmpty ? nil : s
        }
        return nil
    }
}

/// 0.9.0: "All past calls": the old Recent list, all visible calls.
struct PastCallsView: View {
    @ObservedObject var history = CallHistory.shared
    private var f: DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US"); f.setLocalizedDateFormatFromTemplate("EEEdMMMHHmm"); return f
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(L("home.allPast")).font(.system(size: 20, weight: .bold)).foregroundStyle(PN.C.text).padding(.bottom, 12)
                ForEach(Array(history.visible.enumerated()), id: \.element.id) { i, r in
                    if i > 0 { Divider() }
                    RecentRow(r: r, when: f.string(from: r.start), outcome: OutcomeCache.shared.outcome(r.file)?.line ?? "") { history.hide(r) }
                }
            }
            .padding(24).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
}

/// 0.9.0: the Tracker screen (Tracker.swift). The old On you list stays reachable from its Tasks tab data.
struct TrackerView: View {
    var body: some View { TrackerScreen() }
}


/// 0.8.5 (P7, Home): a Recent row. Summary, Follow-up and Series show on hover and when the row's buttons get the
/// keyboard focus (Tab); without them the row stays quiet. The Series pill explains the series rule.
struct RecentRow: View {
    let r: CallHistory.Record
    let when: String
    let outcome: String
    var onHide: () -> Void
    @State private var hover = false
    @State private var why = false
    @FocusState private var focus: Int?

    var body: some View {
        let series = CallPageView.series(of: r).count
        // 0.8.7 (J3): the title takes the full width; "Series · N" is a pill in the subline; the actions float on hover
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(r.title).font(PN.Font.body.weight(.medium)).foregroundStyle(PN.C.text).lineLimit(1)
                if let src = r.source {          // 0.8.6 (B): a transcribed recording, not a call
                    Text(L(src == "link" ? "tr.mark.link" : "tr.mark.file")).font(.system(size: 10, weight: .bold)).foregroundStyle(PN.C.text2)
                        .padding(.horizontal, 4).padding(.vertical, 1).background(PN.C.surface2, in: RoundedRectangle(cornerRadius: 4))
                }
            }
            HStack(spacing: 6) {
                Text([when, r.project].filter { !$0.isEmpty }.joined(separator: " · ")).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(1)
                if series > 1 {
                    Text("·").font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    Button { why = true } label: {
                        Text(L("recent.seriesPill", ["n": "\(series)"])).font(PN.Font.caption).foregroundStyle(PN.C.accent)
                            .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(PN.C.accent.opacity(0.12)))
                    }
                    .buttonStyle(.plain).focused($focus, equals: 9)
                    .popover(isPresented: $why, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L("series.why")).font(PN.Font.section)
                            Text(L("series.whyText")).font(PN.Font.body).fixedSize(horizontal: false, vertical: true)
                            Button(L("series.open")) { why = false; SeriesWindow.show(record: r) }.buttonStyle(.pnSecondary)
                        }
                        .padding(14).frame(width: 320)
                    }
                }
            }
            if !outcome.isEmpty { Text(outcome).font(PN.Font.caption).foregroundStyle(PN.C.text2).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .trailing) {
            let shown = hover || (focus != nil && focus != 9)
            HStack(spacing: 4) {
                Button(L("recent.summary")) {
                    if let u = r.notionURL.flatMap({ URL(string: $0) }) { NSWorkspace.shared.open(u) } else { CallPageWindow.show(file: r.file) }
                }.focused($focus, equals: 1)
                Button(L("recent.followup")) { FollowUpWindow.show(file: r.file) }.focused($focus, equals: 2)
                if series > 1 { Button(L("recent.series")) { SeriesWindow.show(record: r) }.focused($focus, equals: 3) }
            }
            .buttonStyle(.pnTertiary)
            .padding(.leading, 8)
            .background(PN.C.bg.opacity(shown ? 0.95 : 0))
            .opacity(shown ? 1 : 0)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { CallPageWindow.show(file: r.file) }       // 0.8: the call page (spec 4.4)
        .contextMenu {
            if let u = r.notionURL.flatMap({ URL(string: $0) }) { Button(L("home.recent.notion")) { NSWorkspace.shared.open(u) } }
            Button(L("home.recent.transcript")) { TranscriptWindow.show(file: r.file) }
            Button(L("call.page.followup")) { FollowUpWindow.show(file: r.file) }
            if series > 1 { Button(L("call.page.series", ["n": "\(series)"])) { SeriesWindow.show(record: r) } }
            Button(L("home.recent.finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.file)]) }
            Divider()
            Button(L("home.recent.hide"), action: onHide)
        }
        .help(L("home.recent.help.page"))
    }
}


/// 0.8.6 (D3): the trash icon on the hover of an On you row.
struct RemoveButton: View {
    let run: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: run) { Image(systemName: "trash").font(.system(size: 11)) }
            .buttonStyle(.plain).foregroundStyle(PN.C.text3)
            .opacity(hover ? 1 : 0.0001)
            .onHover { hover = $0 }
            .help(L("ntask.removeHelp")).accessibilityLabel(L("ntask.removeHelp"))
    }
}
