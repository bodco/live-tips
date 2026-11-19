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
        w.setContentSize(NSSize(width: 1280, height: 860))      // 0.24 (R1): the width of the boards
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

    /// The dot and pill fill: the bright orange for "not ready" (2026-11-10, owner), the text colour otherwise.
    var dot: Color {
        switch self { case .notReady, .failed, .noBrief: return PN.C.pendingFill; default: return color }
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
    @Environment(\.pnTheme) private var t
    var body: some View {
        // Redesign review (18.11): "not ready" is the NotReadyLabel of the style (Light: ink on the orange plate,
        // Dark: orange text, no plate); Roadbook and Broadsheet set the pill square in the mono label face.
        let nr = state == .notReady || state == .noBrief || state == .failed
        let fg = nr ? Color(pnHex: t.notreadyText) : state.color
        let bg = nr ? (t.nrBg.map { Color(pnHex: $0) } ?? .clear) : state.dot.opacity(0.16)
        let classic = t.style == .classic
        Text(t.cased(text ?? state.text))
            .font(classic ? .system(size: 11, weight: .semibold) : t.font(.mono, 11, .semibold))
            .tracking(classic ? 0 : t.lblTrack * 11)
            .foregroundStyle(fg)
            .padding(.horizontal, nr && t.nrBg == nil && !classic ? 0 : 7).padding(.vertical, 2)
            .background(bg, in: RoundedRectangle(cornerRadius: classic ? 99 : 0))
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
    /// 0.17.0 (B6b, D39): the organization and project filters of Recent calls (shared with All past calls).
    @AppStorage("callFilterOrg") private var filterOrg = ""
    @AppStorage("callFilterProject") private var filterProject = ""
    @ObservedObject private var acct = PacenoteAccount.shared

    private var live: Bool { CallEngine.shared.isRunning || ["recording", "standby", "loading_model"].contains(status.state) }
    private var demo: Bool { ProcessInfo.processInfo.environment["LT_SUPPORT_DIR"] != nil }
    /// Shot mode (p090): "", "nocal", "noai" or "first", to picture the integration states on demo data.
    nonisolated(unsafe) static var shotState = ""

    @ObservedObject var nav = HomeNav.shared

    var body: some View {
        Group {
        NavigationStack(path: $nav.path) {
            homeBody.navigationDestination(for: HomeNav.Route.self) { r in HomeRouteView(route: r) }
        }
    }
        .trackScreen("home")
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
        if [s.config.ai.prep, s.config.ai.tips, s.config.ai.after].contains(AIRoute.gemini) && runner.hasGeminiKey { return true }
        if [s.config.ai.prep, s.config.ai.after].contains(AIRoute.agy) && AgyAccount.cliPath != nil { return true }
        return runner.loggedIn == true || (runner.loggedIn == nil && PrepRunner.claudePath != nil)
    }
    private var calendarOn: Bool { demo ? !["nocal", "first"].contains(Self.shotState) : cal.hasSource }
    private var firstLaunch: Bool { demo ? Self.shotState == "first" : (!aiReady && !calendarOn && history.records.isEmpty) }

    // MARK: layout (0.24, R1: boards HM-Home, HS-HomeStates, HB-HomeBanners)
    // The header, then the banners, then the hero over a heavy line (the next call with the rest of the day on the
    // right, or the state of the day), then Recent calls next to This week. The same layout in every style.

    @Environment(\.pnTheme) private var t
    @ObservedObject private var updates = UpdateService.shared

    /// Something shows in the banner band over the hero (the hero then takes its short form, board HB).
    private var bannersOn: Bool {
        if demo && Self.shotState == "banners" { return true }
        if !note.isEmpty || updates.newVersion != nil || (auto.suggestion != nil && !live) { return true }
        guard acct.signedIn else { return false }
        if !acct.invites.isEmpty { return true }
        let done = OrgSetupMemory.done
        return acct.me?.orgs.contains { OrgSetup.offered($0, done: done) } ?? false
    }

    private var homeBody: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(PN.C.rule).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if bannersOn { banners }
                    hero
                    if showAllCalls && calendarOn && !firstLaunch { comingUp }
                    if !firstLaunch { lower }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(PN.C.bg)
        .frame(minWidth: 680, minHeight: 560)
        .onAppear { tick(); cal.refresh(); history.scan(); upnext.pruneHeld(); upnext.adoptPreparedEvents(); register.importOnce(); ntasks.keepFresh()
                    runner.refreshAuth(); if acct.signedIn { Task { await acct.loadInvites() } }
                    if demo && Self.shotState == "coming" { showAllCalls = true }
                    UpdateService.shared.maybePrompt() }      // 0.23.0: the update window, once Home is up
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

    // MARK: header (HM): the mark, Home / Tracker / Team / Console, the organization filter, AI ok or the problems
    // pill, search, transcribe, refresh, Settings, Plan a call, Call now

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            PacenoteSymbol(height: 26).accessibilityLabel(L("app.name"))
            HStack(spacing: 22) {
                navTab(L("home.nav.home"), selected: true) { nav.path = [] }
                if trackerOn { navTab(L("home.nav.tracker"), selected: false) { nav.open(.tracker) } }
                // 0.17.0: the console, for someone who runs something in an organization, or for staff
                // 0.20.0 (B9, D47.2): the team's calls, for a team lead or C-level whose plan opens manager_view
                if TeamStore.visible { navTab(L("team.tab"), selected: false) { nav.open(.team) } }
                if acct.me?.showsConsole == true { navTab(L("console.tab"), selected: false) { nav.open(.console) } }
            }
            .padding(.leading, 10)
            .frame(maxHeight: .infinity)
            orgFilter.padding(.leading, 10)
            Spacer(minLength: 8)
            statusPill
            ViewThatFits(in: .horizontal) { headerButtons(icons: false); headerButtons(icons: true) }
        }
        .padding(.leading, 32).padding(.trailing, 20)
        .frame(height: 56)
    }

    /// A tab of the main navigation: the display face, a 3 pt line in the link colour under the open one.
    private func navTab(_ title: String, selected: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(t.cased(title))
                .font(t.style == .classic ? .system(size: 15, weight: selected ? .semibold : .regular) : t.font(.display, t.tabSize, selected ? .heavy : .semibold))
                .tracking(t.style == .classic ? 0 : t.bTrack * t.tabSize)
                .foregroundStyle(selected ? PN.C.text : PN.C.text2)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .bottom) { Rectangle().fill(selected ? PN.C.accent : Color.clear).frame(height: 3) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The organization filter of the boards sits in the header; it filters Recent calls (shared with All past calls).
    @ViewBuilder private var orgFilter: some View {
        if let me = acct.me, me.showsOrgFilter {
            Menu {
                Button(L("org.filter.all")) { filterOrg = "" }
                Divider()
                ForEach(me.orgs) { o in Button(o.name) { filterOrg = o.id } }
            } label: {
                HomeField(text: filterOrg.isEmpty ? L("org.filter.all") : (me.org(filterOrg)?.name ?? L("org.filter.all")))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help(L("org.filter.help"))
        }
    }

    private func headerButtons(icons: Bool) -> some View {
        HStack(spacing: 8) {
        HStack(spacing: 2) {
            if history.records.isEmpty {
                HomeIconButton(symbol: "magnifyingglass", label: L("memory.afterFirst")) { StartCallWindow.show(delegate: app) }.opacity(0.5)
            } else {
                HomeIconButton(symbol: "magnifyingglass", label: L("memory.help")) { MemoryWindow.show() }.keyboardShortcut("f", modifiers: .command)
            }
            // 0.8.6 (B), owner 2026-11-03: Transcribe stays in the header, next to search
            HomeIconButton(symbol: "waveform", label: L("tr.window")) { TranscribeWindow.show() }
            if calendarOn { CalendarRefreshButton(place: "home", shortcut: true).frame(width: 32, height: 32) }
            HomeIconButton(symbol: "slider.horizontal.3", label: L("home.settings")) { SettingsWindow.show() }
        }
        if !live {
            HStack(spacing: 8) {
                if icons {
                    HomeIconButton(symbol: "calendar.badge.plus", label: L("home.planCall")) { StartCallWindow.show(delegate: app, planOnly: true) }
                } else {
                    Button(L("home.planCall")) { StartCallWindow.show(delegate: app, planOnly: true) }
                        .buttonStyle(PNQuietButtonStyle()).help(L("home.planCall.help")).fixedSize()
                }
                // Theme pass (19.11): "New call ⌘N", quiet. It opens Get ready for an untitled call (StartCallWindow.startNow),
                // not the next meeting, so it must not read as a second way to start that meeting.
                Button { StartCallWindow.startNow(delegate: app) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                        Text(L("home.callNow"))
                        if !icons { Text("⌘N").font(t.homeMono(11)).foregroundStyle(PN.C.text3).textCase(nil) }
                    }
                }
                .buttonStyle(PNQuietButtonStyle()).keyboardShortcut("n", modifiers: .command).help(L("home.newCall.help")).fixedSize()
            }
            .padding(.leading, 6)
        }
        }
        .fixedSize()
    }

    /// 0.9.0: what the old status line and Finish setup said, as one pill shown only when something needs the PM.
    private struct Problem: Identifiable { var id: String; var text: String; var run: () -> Void }

    private var problems: [Problem] {
        if demo && Self.shotState == "pill" {
            return [Problem(id: "install", text: L("home.finish.install"), run: {}), Problem(id: "notion", text: L("home.status.notionStale"), run: {}),
                    Problem(id: "limit", text: L("home.status.limit"), run: {})]
        }
        if demo && !Self.shotState.isEmpty && !firstLaunch {
            return (aiReady ? [] : [Problem(id: "ai", text: L("home.pill.claude"), run: {})]) + (calendarOn ? [] : [Problem(id: "cal", text: L("home.status.noCalendars"), run: {})])
        }
        guard !demo, !firstLaunch else { return [] }
        let cfg = AppConfig.load(from: AppPaths.config)
        var out: [Problem] = []
        // 0.24.1 (F6): the same readiness answer as every start button
        if !CallEngine.shared.problems().isEmpty || CallReadyState.shared.blocked { out.append(Problem(id: "install", text: L("home.finish.install"), run: { SetupWindow.show() })) }
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

    /// "AI ok" (HM), or in its place the problems pill (HB row 2): one problem is a button, several open a menu.
    @ViewBuilder private var statusPill: some View {
        let ps = problems
        if ps.isEmpty {
            HomeAIStatus()
        } else if ps.count == 1, let p = ps.first {
            Button(action: p.run) { HomeProblemPill(text: p.text) }.buttonStyle(.plain).fixedSize()
        } else {
            Menu { ForEach(ps) { p in Button(p.text, action: p.run) } } label: { HomeProblemPill(text: L("home.pill.n", ["n": "\(ps.count)"]) + " ▾") }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(L("home.pill.n", ["n": "\(ps.count)"]))
        }
    }

    // MARK: banners (HB row 1): auto-start, the update, an invitation, an organization to set up

    private var banners: some View {
        VStack(alignment: .leading, spacing: 10) {
            if demo && Self.shotState == "banners" { demoBanners }
            if let e = auto.suggestion, !live { autoBanner(e) }
            UpdateHomeLine()      // 0.23.0 (Bohdan 18.11): the update banner at the top
            InvitesHomeLine()     // 0.17.0 (B6b): "Mike invited you to Acme · Join…"
            OrgSetupHomeLine()    // 0.17.0 (5.3): "Acme is ready. Set it up…" for its owner
            if !note.isEmpty { Text(note).font(t.homeText(14)).foregroundStyle(PN.C.notreadyText) }
        }
        .padding(.horizontal, 32).padding(.top, 20)
    }

    /// Pacenote 0.8 (idea 08): "Start tips for Orbit weekly?" when a meeting app is on at a calendar call.
    private func autoBanner(_ e: CalendarService.CalEvent) -> some View {
        let m = auto.model(for: e)
        return HomeBanner(icon: "◉", title: L("auto.title", ["title": e.title]),
                          sub: m.target.isEmpty ? L("auto.chooseProject") : L("auto.body", ["project": m.targetName]),
                          edge: PN.C.rec, iconFill: PN.C.rec, iconInk: .white,
                          later: (L("auto.notNow"), { auto.dismiss() }), go: L("home.startTips")) { auto.accept() }
    }

    /// Shot mode only: the four banners of the board, on demo data.
    @ViewBuilder private var demoBanners: some View {
        HomeBanner(icon: "◉", title: L("auto.title", ["title": "Northwind discovery call"]), sub: L("auto.body", ["project": "Northwind"]),
                   edge: PN.C.rec, iconFill: PN.C.rec, iconInk: .white, later: (L("auto.notNow"), {}), go: L("home.startTips")) {}
        HomeBanner(icon: "↑", title: L("upd.home.ready", ["v": "0.24.0"]), sub: L("upd.youHave", ["v": "0.23.0"]),
                   edge: PN.C.accent, iconFill: PN.C.accentFill, iconInk: PN.C.onAccent, later: (L("upd.later"), {}), go: L("upd.home.install")) {}
        HomeBanner(icon: "+", title: "Mike Reed invited you to Acme (team Delivery)", sub: L("org.invite.more", ["n": "1"]),
                   edge: PN.C.answer, iconFill: PN.C.answer, iconInk: PN.C.bg, later: (L("org.invite.decline"), {}), go: L("org.invite.join")) {}
        HomeBanner(icon: "◆", title: L("orgsetup.home", ["org": "Acme"]), sub: L("orgsetup.homeSub"),
                   edge: PN.C.text3, iconFill: PN.C.text, iconInk: PN.C.bg, later: (L("orgsetup.notNow"), {}), go: L("orgsetup.start")) {}
    }

    // MARK: calls ahead

    private var ahead: [Ahead] {
        if demo && Self.shotState == "empty" { return [] }
        var rows: [Ahead] = []
        var used = Set<ObjectIdentifier>()
        let ce = CallEngine.shared
        let liveKey = ce.isRunning ? EditLog.seriesKey(ce.renamed ?? (ce.callRequest["title"] as? String) ?? "") : ""
        for e in (calendarOn ? cal.upcoming(now) : []) {
            // 2026-10-28 (owner): the call being recorded is shown once, as live, not again as ahead.
            if ce.isRunning, e.has(ce.liveEventID) || (!liveKey.isEmpty && EditLog.seriesKey(e.title) == liveKey && e.start <= now.addingTimeInterval(15 * 60)) { continue }
            let m = upnext.visible.first { e.has($0.calEventID) }
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

    private func overlaps(_ r: Ahead, _ rows: [Ahead]) -> [CalendarService.CalEvent] {
        guard let e = r.event else { return [] }
        return rows.compactMap(\.event).filter { $0.id != e.id && e.overlaps($0) }
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
        // 2026-11-06 (owner: "Get ready > Prepare closes the window and nothing happens"): a preparation running or
        // waiting for a call whose calendar time has already begun showed the plain "in progress" card, so the prep
        // was invisible. A running or queued preparation now wins over "in progress".
        if let m = r.model, [.running, .queued].contains(upnext.prepState(m)) {
            return upnext.prepState(m) == .running ? .preparing : .queued
        }
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

    private func tag(_ r: Ahead, _ st: CallState) -> (HomeTag, String) {
        let s = SheetBadges.state(r.model, st)
        return (HomeTag.of(s), SheetBadges.text(r.model, st) ?? s.text)
    }

    private static func hhmm(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d) }

    /// "Tue 17 Nov, 10:23"
    private var todayLine: String {
        let df = DateFormatter()
        df.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US")
        df.setLocalizedDateFormatFromTemplate("EEEdMMM")
        return df.string(from: now) + ", " + Self.hhmm(now)
    }

    // MARK: hero (HM, HS): one state of the day over a heavy line

    @ViewBuilder private var hero: some View {
        if live { heroGrid { liveHero } aside: { laterAside } }
        else if firstLaunch { welcome }
        else if !calendarOn { noCalendar }
        else if let n = nextCall {
            if bannersOn || showAllCalls { shortHero(n) } else { heroGrid { callHero(n) } aside: { laterAside } }
        }
        else { emptyHero }
    }

    /// The hero on the left, the rest of the day on the right (430 pt); in a narrow window the day goes under it.
    private func heroGrid<A: View, B: View>(@ViewBuilder _ left: () -> A, @ViewBuilder aside: () -> B) -> some View {
        let l = left(), r = aside()
        return VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    l.padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 30)
                        .frame(minWidth: 500, maxWidth: .infinity, alignment: .topLeading)
                    r.padding(.leading, 28).padding(.trailing, 32).padding(.top, 28).padding(.bottom, 24)
                        .frame(width: 430, alignment: .topLeading).frame(maxHeight: .infinity, alignment: .top)
                        .background(PN.C.surface2)
                }
                .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 0) {
                    l.padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 30).frame(maxWidth: .infinity, alignment: .leading)
                    r.padding(.horizontal, 32).padding(.vertical, 22).frame(maxWidth: .infinity, alignment: .leading).background(PN.C.surface2)
                }
            }
            heavyRule
        }
    }

    private var heavyRule: some View { Rectangle().fill(PN.C.ruleStrong).frame(height: t.ruleHeavy) }

    /// "Next call in" + "37 min": in Roadbook one line as large as the number (theme pass, 19.11: scale, no yellow plate;
    /// the yellow belongs to the main button); in Classic a small line over a large number. A fill only for the live call.
    private func countdownView(pre: String, num: String, unit: String, fill: Color? = nil, ink: Color? = nil, timer: Date? = nil) -> some View {
        let c = t.countdown
        let w = t.heroWeight
        let numFont = t.homeDisplay(c.num, w), unitFont = t.homeDisplay(c.unit, w)
        let track = t.numTrack * c.num
        let plate = HStack(alignment: .firstTextBaseline, spacing: 0) {
            if let d = timer { Text(d, style: .timer).monospacedDigit().font(numFont).tracking(track) }
            else { Text(num).font(numFont).tracking(track) }
            if !unit.isEmpty { Text(" " + t.cased(unit)).font(unitFont) }
        }
        .foregroundStyle(ink ?? PN.C.text)
        .padding(.horizontal, fill == nil ? 0 : max(t.plateInset, 8))
        .background(fill ?? .clear)
        .lineLimit(1).minimumScaleFactor(0.4)
        let preText = Text(t.cased(pre)).font(t.homeDisplay(c.pre, w)).tracking(t.style == .broadsheet ? -0.02 * c.pre : 0).foregroundStyle(PN.C.text)
        return Group {
            if c.preOwnLine {
                VStack(alignment: .leading, spacing: 4) { preText; plate }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 18) { preText.fixedSize(); plate.fixedSize() }
                    VStack(alignment: .leading, spacing: 0) { preText.lineLimit(1).minimumScaleFactor(0.5); plate }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func heroTitle(_ text: String, help: String, size: CGFloat? = nil, run: @escaping () -> Void) -> some View {
        let z = size ?? t.titleSize
        return Button(action: run) {
            Text(text).font(t.homeDisplay(z, size == nil ? t.titleWeight : t.heroWeight)).tracking(t.dTrack * z)
                .foregroundStyle(PN.C.text).lineLimit(2).multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain).help(help)
        .accessibilityAddTraits(.isHeader)
    }

    private func heroPrimary(_ title: String, glyph: String = "↵", run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 10) { Text(title); Text(glyph).font(t.homeMono(11)).textCase(nil) }
        }
        .buttonStyle(PNHeroButtonStyle()).fixedSize()
    }

    private func countdown(_ r: Ahead) -> (pre: String, num: String, unit: String) {
        let m = Int((r.start.timeIntervalSince(now) / 60).rounded())
        let at = Self.hhmm(r.start)
        if m <= 0 { return (L("home.hero.now"), at, "") }
        if m <= 5 { return (L("home.hero.startsIn"), "\(m)", L("home.hero.min")) }
        if m < 90 { return (L("home.hero.nextIn"), "\(m)", L("home.hero.min")) }
        if Calendar.current.isDateInToday(r.start) { return (L("home.hero.nextAt"), at, "") }
        if Calendar.current.isDateInTomorrow(r.start) { return (L("home.hero.tomorrowAt"), at, "") }
        let df = DateFormatter(); df.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US"); df.setLocalizedDateFormatFromTemplate("EEEdMMM")
        return (L("home.hero.on", ["d": df.string(from: r.start)]), at, "")
    }

    /// "Tue 17 Nov, 10:23 · next: 11:00-11:30 · Orbit · Google Meet"
    private func metaLine(_ r: Ahead) -> String {
        let times = Self.hhmm(r.start) + (r.end.map { "-" + Self.hhmm($0) } ?? "")
        let proj = r.model.map { $0.target.isEmpty ? "" : $0.targetName } ?? ""
        return [todayLine, L("home.meta.next", ["t": times]), proj, platform(r.event)].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func briefLine(_ r: Ahead, _ st: CallState) -> String {
        let fresh = r.model.flatMap { Freshness.check($0) }
        switch st {
        case .ready: return fresh?.stale == true ? fresh!.line : L("home.brief.ready")
        case .preparing: return L("home.check.preparing", ["p": "\(Int(runner.progress * 100))"])
        case .queued: return L("badge.queued")
        case .failed: return L("badge.failed")
        case .noBrief: return L("home.recordsOnly")
        case .live: return L("home.hero.inProgress")
        default: return L("home.hero.takes")
        }
    }

    private func overlapLines(_ r: Ahead) -> some View {
        ForEach(overlaps(r, ahead), id: \.id) { e in
            HStack(spacing: 10) {
                HomeTagView(kind: .notReady, text: L("home.tag.overlap"))
                Text(L("home.check.overlaps", ["title": e.title]) + ", " + Self.hhmm(e.start) + "-" + Self.hhmm(e.end))
                    .font(t.homeText(14)).foregroundStyle(PN.C.text2).lineLimit(1)
                HomeLink(L("home.overlap.hide")) { hide(e.id) }
            }
        }
    }

    /// The next call (HM; HS row 1): when, how long until it, what it is, who is on it, whether it is ready,
    /// one big button, one bordered button and one link.
    private func callHero(_ r: Ahead) -> some View {
        let st = state(of: r)
        let (k, txt) = tag(r, st)
        let c = countdown(r)
        let people = Self.peopleLine(r.event?.attendees ?? r.model?.participants ?? [])
        return VStack(alignment: .leading, spacing: 14) {
            HomeMeta(text: metaLine(r))
            if t.style == .broadsheet {
                // Theme pass (19.11): Broadsheet's headline is the meeting; under it one line with the countdown and readiness
                heroTitle(r.title, help: L("home.openCall.help"), size: 60) { openCall(r) }
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text([c.pre, c.num, c.unit].filter { !$0.isEmpty }.joined(separator: " ")).font(t.homeText(17, .heavy)).foregroundStyle(PN.C.text)
                    if let e = r.event { Text(Self.hhmm(e.start) + "-" + Self.hhmm(e.end)).font(t.homeText(17)).foregroundStyle(PN.C.text3) }
                    HomeTagView(kind: k, text: txt)
                }
                .lineLimit(1).accessibilityElement(children: .combine)
                if !people.isEmpty { Text(L("home.hero.people", ["people": people])).font(t.homeText(15)).foregroundStyle(PN.C.text2) }
                Text(briefLine(r, st)).font(t.homeText(15)).foregroundStyle(PN.C.text2)
            } else {
                countdownView(pre: c.pre, num: c.num, unit: c.unit)
                heroTitle(r.title, help: L("home.openCall.help")) { openCall(r) }
                if !people.isEmpty { Text(L("home.hero.people", ["people": people])).font(t.homeText(15)).foregroundStyle(PN.C.text2) }
                HomeTagView(kind: k, text: txt, big: true, sub: "· " + briefLine(r, st))
            }
            overlapLines(r)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { heroButtons(r, st, link: true) }
                VStack(alignment: .leading, spacing: 10) { HStack(spacing: 12) { heroButtons(r, st, link: false) }; heroLink(r, st) }
            }
            .padding(.top, 4)
        }
    }

    /// Theme pass (19.11, owner): the main action follows what exists (a brief or not) and whether the meeting has
    /// begun, never the countdown. No brief: Prepare brief (opens Get ready, as before) + Start without prep. Preparing:
    /// the progress on the main button + Start call now (the brief joins the call when it is ready). Brief ready: View brief
    /// + Start call. The meeting has begun: Start call, labelled with what it opens. No AI: Start call + Connect AI.
    private struct HeroActions {
        var primary: String
        var busy: Double? = nil            // a running preparation: its progress, the button shows it and does nothing
        var run: () -> Void
        var second: String
        var secondPlay = false
        var secondRun: () -> Void
    }

    private func heroActions(_ r: Ahead, _ st: CallState) -> HeroActions {
        switch st {
        case .ready:
            return HeroActions(primary: L("home.viewBrief"), run: { openCall(r) }, second: L("home.startCall"), secondPlay: true, secondRun: { start(r) })
        case .live:
            if live { return HeroActions(primary: L("home.switch"), run: { start(r) }, second: HomePrepEstimate.label, secondRun: { prepare(r) }) }
            let app = platform(r.event)
            return HeroActions(primary: app.isEmpty ? L("home.startCall.tips") : L("home.startCall.app", ["app": app]), run: { start(r) },
                               second: HomePrepEstimate.label, secondRun: { prepare(r) })
        case .preparing:
            return HeroActions(primary: L("home.check.preparing", ["p": "\(Int(runner.progress * 100))"]), busy: runner.progress, run: {},
                               second: L("home.hero.startNow"), secondPlay: true, secondRun: { start(r) })
        case .queued:
            return HeroActions(primary: L("badge.queued"), busy: 0, run: {}, second: L("home.hero.startNow"), secondPlay: true, secondRun: { start(r) })
        case .noBrief:
            return HeroActions(primary: L("home.startCall"), run: { start(r) }, second: L("home.hero.connectAI"), secondRun: { SettingsWindow.show(tab: "ai") })
        default:
            return HeroActions(primary: HomePrepEstimate.label, run: { prepare(r) }, second: L("home.startWithoutPrep"), secondPlay: true, secondRun: { start(r) })
        }
    }

    /// The main button: the accent fill; while a preparation runs, its progress in it and no action.
    @ViewBuilder private func heroMain(_ a: HeroActions, height: CGFloat) -> some View {
        if let p = a.busy {
            Text(a.primary)
                .font(height >= 44 ? t.heroFont : t.buttonFont).tracking(t.style == .classic ? 0 : t.bTrack * (height >= 44 ? t.bigBtn : t.bSize))
                .textCase(t.caps ? .uppercase : nil).foregroundStyle(PN.C.onAccent)
                .padding(.horizontal, height >= 44 ? 26 : 20).frame(height: height)
                .background(alignment: .leading) {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            PN.C.accentFill
                            Color.black.opacity(0.12).frame(width: g.size.width * max(0, min(1, p)))
                        }
                    }
                }
                .overlay(Rectangle().strokeBorder(t.framedAccent ? PN.C.actEdge : Color.clear, lineWidth: 2))
                .clipShape(RoundedRectangle(cornerRadius: t.style == .classic ? (height >= 44 ? 12 : 9) : 0))
                .fixedSize()
                .accessibilityElement(children: .combine).accessibilityAddTraits(.updatesFrequently)
        } else if height >= 44 {
            heroPrimary(a.primary, glyph: "↵", run: a.run).keyboardShortcut(.defaultAction)
        } else {
            Button(a.primary, action: a.run).buttonStyle(PNSolidButtonStyle(height: height)).keyboardShortcut(.defaultAction).fixedSize()
        }
    }

    private func heroSecond(_ a: HeroActions, height: CGFloat) -> some View {
        Button(action: a.secondRun) {
            HStack(spacing: 8) {
                if a.secondPlay { Image(systemName: "play").font(.system(size: height >= 44 ? 12 : 10, weight: .bold)) }
                Text(a.second)
            }
        }
        .buttonStyle(PNOutlineButtonStyle(height: height)).fixedSize()
    }

    @ViewBuilder private func heroButtons(_ r: Ahead, _ st: CallState, link: Bool) -> some View {
        let a = heroActions(r, st)
        heroMain(a, height: 48)
        heroSecond(a, height: 48)
        if link { heroLink(r, st).padding(.leading, 8) }
    }

    @ViewBuilder private func heroLink(_ r: Ahead, _ st: CallState) -> some View {
        if st == .ready { HomeLink(L("talk.prepareAgain"), size: 15) { prepare(r) } }
        else if st == .preparing || st == .queued {
            HomeLink(L("common.cancel"), size: 15, color: PN.C.text2) { if st == .preparing { runner.cancel() } else if let m = r.model { upnext.unqueue(m) } }
        }
        else { HomeLink(L("home.hero.openPage"), size: 15) { openCall(r) } }
    }

    /// The short hero (HB): over banners or with Coming up open, the next call on one line.
    private func shortHero(_ r: Ahead) -> some View {
        let st = state(of: r)
        let (k, txt) = tag(r, st)
        let c = countdown(r)
        let w = t.heroWeight
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) { HomeMeta(text: metaLine(r)); HomeTagView(kind: k, text: txt) }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Text(t.cased(c.pre)).font(t.homeDisplay(44, w)).tracking(t.dTrack * 44).fixedSize()
                        HomePlate(text: t.cased(c.num + (c.unit.isEmpty ? "" : " " + c.unit)), font: t.homeDisplay(56, w), tracking: t.numTrack * 56).fixedSize()
                        heroTitleLine(r)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            Text(t.cased(c.pre)).font(t.homeDisplay(44, w)).fixedSize()
                            HomePlate(text: t.cased(c.num + (c.unit.isEmpty ? "" : " " + c.unit)), font: t.homeDisplay(56, w), tracking: t.numTrack * 56).fixedSize()
                        }
                        heroTitleLine(r)
                    }
                }
                .foregroundStyle(PN.C.text)
                .accessibilityElement(children: .combine)
                overlapLines(r)
                HStack(spacing: 12) {
                    let a = heroActions(r, st)
                    heroMain(a, height: 40)
                    heroSecond(a, height: 40)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 32).padding(.top, 22).padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            heavyRule
        }
    }

    private func heroTitleLine(_ r: Ahead) -> some View {
        Button { openCall(r) } label: {
            Text(r.title).font(t.homeText(24, .bold)).foregroundStyle(PN.C.text).lineLimit(1)
        }
        .buttonStyle(.plain).help(L("home.openCall.help"))
    }

    /// The live call (HS row 2): the time on the call on the red plate, Show tips, the Meeting Sheet, End the call.
    private var liveHero: some View {
        let ce = CallEngine.shared
        let req = ce.callRequest
        let title = ce.renamed ?? (req["title"] as? String) ?? status.project ?? L("app.name")
        let since = status.startedAt.flatMap { ISO8601DateFormatter().date(from: $0) }
        let reg = ProjectRegistry.load(from: AppPaths.projects)
        let slug = (req["slug"] as? String) ?? status.slug ?? ""
        let project = reg.projects.first { $0.slug == slug }?.name ?? reg.workspaces.first { $0.name.lowercased() == slug.lowercased() }?.name ?? status.project ?? ""
        let people = Self.peopleLine(((req["participants"] as? [String]) ?? []).filter { !$0.isEmpty })
        let stem = (status.file ?? "").hasSuffix(".md") ? String((status.file ?? "").dropLast(3)) : (status.file ?? "")
        let hasBrief = !stem.isEmpty && FileManager.default.fileExists(atPath: stem + ".brief.md")
        let preparing = runner.running && runner.joinsCurrentCall
        let failed = !preparing && !hasBrief && runner.joinsCurrentCall ? runner.failure : nil      // 2026-11-17 (owner)
        let briefText = preparing ? L("home.live.briefPreparing") : hasBrief ? L("home.brief.ready")
            : failed.map { L("home.live.prepFailed", ["why": $0]) } ?? L("home.live.noBrief")
        let waiting = status.state == "standby"
        let meta = [since.map { L("home.hero.started", ["t": Self.hhmm($0)]) } ?? "", project].filter { !$0.isEmpty }.joined(separator: " · ")
        let counts = status.lines > 0 ? " · " + L("home.live.counts", ["lines": "\(status.lines)", "tips": "\(status.tips)"]) : ""
        return VStack(alignment: .leading, spacing: 14) {
            if !meta.isEmpty { HomeMeta(text: meta) }
            if let s = since, status.state == "recording" {
                countdownView(pre: L("home.hero.onCallFor"), num: "", unit: "", fill: PN.C.rec, ink: .white, timer: s)
            } else {
                countdownView(pre: L("home.hero.onCall"), num: waiting ? L("menubar.status.waiting") : L("home.live"), unit: "", fill: PN.C.rec, ink: .white)
            }
            heroTitle(title, help: L("menubar.showTips")) { app.showTips() }
            if !people.isEmpty { Text(L("home.hero.people", ["people": people])).font(t.homeText(15)).foregroundStyle(PN.C.text2) }
            HomeTagView(kind: hasBrief || preparing ? .ready : .notReady, text: waiting ? L("menubar.status.waiting") : L("home.hero.listening"), big: true, sub: "· " + briefText + counts)
            HStack(spacing: 12) {
                heroPrimary(L("menubar.showTips")) { app.showTips() }.keyboardShortcut(.defaultAction)
                if !preparing {
                    Button(hasBrief ? L("home.hero.openSheet") : L("bb.prepareNow")) {
                        AnalyticsTracker.shared.action("prepare_again", scr: "home", o: AnalyticsTracker.shared.callOrg)   // 0.19.0 (S4)
                        if let e = LivePrep.openSheet() { note = e }      // 0.10.1 (A4): the Meeting Sheet in live mode
                    }
                    .buttonStyle(PNOutlineButtonStyle(height: 48)).fixedSize()
                }
                HomeLink(L("home.hero.endCall"), size: 15, color: PN.C.recText) {
                    AnalyticsTracker.shared.action("end_call", scr: "home", o: AnalyticsTracker.shared.callOrg); app.endCall()
                }
                .padding(.leading, 8)
            }
            .padding(.top, 4)
        }
    }

    /// The rest of today and tomorrow, next to the hero (HM aside): time, title, state; See the whole week opens Coming up.
    private var laterAside: some View {
        let first = nextCall?.id
        let rest = ahead.filter { $0.id != first }
        let today = rest.filter { Calendar.current.isDateInToday($0.start) }
        let tomorrow = rest.filter { Calendar.current.isDateInTomorrow($0.start) }
        return VStack(alignment: .leading, spacing: 0) {
            if today.isEmpty && tomorrow.isEmpty {
                asideHead(L("home.laterToday"), notReady: 0, top: 0)
                Text(L("home.later.empty")).font(t.homeText(14)).foregroundStyle(PN.C.text3).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { Rectangle().fill(PN.C.rule).frame(height: 1) }
            }
            if !today.isEmpty {
                asideHead(L("home.laterToday"), notReady: today.filter { [.notReady, .failed, .noBrief].contains(state(of: $0)) }.count, top: 0)
                ForEach(today.prefix(4)) { r in asideRow(r) }
            }
            if !tomorrow.isEmpty {
                asideHead(L("home.tomorrowHead"), notReady: 0, top: today.isEmpty ? 0 : 22)
                ForEach(tomorrow.prefix(3)) { r in asideRow(r) }
            }
            if !rest.isEmpty {
                HomeLink(L("home.seeWeek")) { showAllCalls = true }.padding(.top, 14)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("home.laterToday"))
    }

    private func asideHead(_ title: String, notReady: Int, top: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).pnSection().foregroundStyle(PN.C.text).accessibilityAddTraits(.isHeader)
            if notReady > 0 {
                Text(L("home.nNotReady", ["n": "\(notReady)"])).font(t.homeMono(11, .semibold)).foregroundStyle(PN.C.notreadyText)
                    .padding(.horizontal, t.nrBg == nil ? 0 : 5).background(PN.C.notreadyPlate)
            }
        }
        .padding(.top, top).padding(.bottom, 8)
    }

    private func asideRow(_ r: Ahead) -> some View {
        let st = state(of: r)
        let (k, txt) = tag(r, st)
        return Button { openCall(r) } label: {
            HStack(spacing: 10) {
                Text(Self.hhmm(r.start)).font(t.homeMono(13, .semibold)).foregroundStyle(PN.C.text).frame(width: 50, alignment: .leading)
                Text(r.title).font(t.homeText(15, .semibold)).foregroundStyle(PN.C.text).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                HomeQuietTag(kind: k, text: txt)      // theme pass (19.11): quiet marks with a sign, the hero keeps the loud one
            }
            .padding(.vertical, 10)
            .overlay(alignment: .top) { Rectangle().fill(PN.C.rule).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(L("home.openCall.help"))
        .contextMenu { callMenuItems(r, st) }
    }

    /// Nothing else today (HS row 3): a call can start without a calendar event.
    private var emptyHero: some View {
        let sync = cal.lastSync.map { L("home.empty.synced", ["t": Self.hhmm($0)]) } ?? ""
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HomeMeta(text: [todayLine, sync].filter { !$0.isEmpty }.joined(separator: " · "))
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    HomePlate(text: t.cased(L("home.empty.clear")), font: t.homeDisplay(t.bigNum, t.heroWeight), tracking: t.numTrack * t.bigNum)
                    Text(" " + t.cased(L("home.empty.until"))).font(t.homeDisplay(t.bigNum, t.heroWeight)).tracking(t.numTrack * t.bigNum)
                }
                .foregroundStyle(PN.C.text).lineLimit(1).minimumScaleFactor(0.4)
                Text(L("home.empty.body")).font(t.homeText(17)).foregroundStyle(PN.C.text2).frame(maxWidth: 720, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    heroPrimary(L("home.startCallNow"), glyph: "⌘N") { StartCallWindow.startNow(delegate: app) }
                    Button(L("home.planCall")) { StartCallWindow.show(delegate: app, planOnly: true) }.buttonStyle(PNOutlineButtonStyle(height: 48)).fixedSize()
                    HomeLink(L("home.empty.transcribe"), size: 15) { TranscribeWindow.show() }.padding(.leading, 8)
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 32).padding(.top, 32).padding(.bottom, 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            heavyRule
        }
    }

    /// No calendar (HS row 4): see your day here, connect a calendar or plan by hand; calls planned by hand on the right.
    private var noCalendar: some View {
        let planned = upnext.visible.sorted { $0.callDate < $1.callDate }
        let left = VStack(alignment: .leading, spacing: 14) {
            HomeMeta(text: todayLine + " · " + L("home.nocal.meta"))
            Text(t.cased(L("home.seeDay.title"))).font(t.homeDisplay(t.bigNum, t.heroWeight)).tracking(t.numTrack * t.bigNum)
                .foregroundStyle(PN.C.text).lineLimit(2).minimumScaleFactor(0.5)
            Text(L("home.seeDay.body")).font(t.homeText(17)).foregroundStyle(PN.C.text2).frame(maxWidth: 640, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                heroPrimary(L("home.connectCalendar"), glyph: "") { cal.connect() }
                Button(L("home.planByHand")) { StartCallWindow.show(delegate: app, planOnly: true) }.buttonStyle(PNOutlineButtonStyle(height: 48)).fixedSize()
            }
            .padding(.top, 4)
        }
        let right = VStack(alignment: .leading, spacing: 0) {
            Text(L("home.planned")).pnSection().foregroundStyle(PN.C.text).padding(.bottom, 8).accessibilityAddTraits(.isHeader)
            ForEach(planned, id: \.id) { m in
                let r = Ahead(id: m.id.uuidString, event: nil, model: m, start: m.callDate)
                plannedRow(r)
            }
            Text(L("home.planned.note")).font(t.homeText(13)).foregroundStyle(PN.C.text3).padding(.top, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(PN.C.rule).frame(height: 1) }
        }
        return VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 40) { left.frame(minWidth: 420, maxWidth: .infinity, alignment: .leading); right.frame(width: 430) }
                VStack(alignment: .leading, spacing: 28) { left; right }
            }
            .padding(.horizontal, 32).padding(.top, 32).padding(.bottom, 34)
            heavyRule
        }
    }

    private func plannedRow(_ r: Ahead) -> some View {
        let st = state(of: r)
        let (k, txt) = tag(r, st)
        let f = DateFormatter(); f.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US"); f.dateFormat = Calendar.current.isDateInToday(r.start) ? "HH:mm" : "EEE HH:mm"
        return Button { openCall(r) } label: {
            HStack(spacing: 10) {
                Text(f.string(from: r.start)).font(t.homeMono(13, .semibold)).foregroundStyle(PN.C.text).frame(width: 86, alignment: .leading)
                Text(r.title).font(t.homeText(15, .semibold)).foregroundStyle(PN.C.text).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                HomeTagView(kind: k, text: txt)
            }
            .padding(.vertical, 10)
            .overlay(alignment: .top) { Rectangle().fill(PN.C.rule).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).contextMenu { callMenuItems(r, st) }
    }

    /// First launch (HS row 5): welcome, what Pacenote does, three steps; Recent calls and This week stay hidden.
    private var welcome: some View {
        let notion = SettingsWindow.model.isSet(.notionToken)
        let done = [aiReady, calendarOn, notion]
        let firstOpen = done.firstIndex(of: false)
        let left = VStack(alignment: .leading, spacing: 14) {
            HomeMeta(text: L("home.first.meta"))
            // two lines, as on the board: the words, then the name on the plate
            VStack(alignment: .leading, spacing: 4) {
                Text(t.cased(L("home.welcome.pre"))).font(t.homeDisplay(t.bigNum, t.heroWeight)).tracking(t.numTrack * t.bigNum)
                HomePlate(text: t.cased(L("app.name")), font: t.homeDisplay(t.bigNum, t.heroWeight), tracking: t.numTrack * t.bigNum)
            }
            .foregroundStyle(PN.C.text).lineLimit(1).minimumScaleFactor(0.4)
            Text(L("home.welcome.body")).font(t.homeText(17)).foregroundStyle(PN.C.text2).frame(maxWidth: 560, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            // Theme pass (19.11): a call that starts right now gets a button, not a link
            VStack(alignment: .leading, spacing: 10) {
                Text(L("home.welcome.anyway")).font(t.homeText(17, .semibold)).foregroundStyle(PN.C.text)
                Button { StartCallWindow.startNow(delegate: app) } label: {
                    HStack(spacing: 8) { Image(systemName: "play").font(.system(size: 10, weight: .bold)); Text(L("home.startCallNow")) }
                }
                .buttonStyle(PNOutlineButtonStyle(height: 40)).fixedSize()
                Text(L("home.welcome.anywayHelp")).font(t.homeText(14)).foregroundStyle(PN.C.text3).frame(maxWidth: 520, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 16)
            .overlay(alignment: .top) { Rectangle().fill(PN.C.ruleStrong).frame(height: 2) }
            .padding(.top, 6)
        }
        let right = VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("home.steps.title")).pnSection().foregroundStyle(PN.C.text).accessibilityAddTraits(.isHeader)
                Spacer()
                Text(L("home.steps.nOf", ["n": "\(done.filter { $0 }.count)"])).font(t.homeMono(11)).foregroundStyle(PN.C.text3)
            }
            .padding(.top, 10).padding(.bottom, 8)
            .overlay(alignment: .top) { Rectangle().fill(PN.C.ruleStrong).frame(height: t.ruleHeavy) }
            step(1, L("home.steps.claude"), L("home.steps.claude.sub"), done: done[0], main: firstOpen == 0) { SettingsWindow.show(tab: "ai") }
            step(2, L("home.steps.calendar"), L("home.steps.calendar.sub"), done: done[1], main: firstOpen == 1) { cal.connect() }
            step(3, L("home.steps.notion"), L("home.steps.notion.sub"), done: done[2], main: firstOpen == 2) { SettingsWindow.show(tab: "notion") }
        }
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 48) { left.frame(minWidth: 380, maxWidth: .infinity, alignment: .leading); right.frame(width: 560) }
            VStack(alignment: .leading, spacing: 28) { left; right }
        }
        .padding(.horizontal, 32).padding(.top, 32).padding(.bottom, 34)
    }

    private func step(_ n: Int, _ title: String, _ sub: String, done: Bool, main: Bool, run: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Text(done ? "✓" : "\(n)").font(t.homeDisplay(17, .heavy))
                .foregroundStyle(done ? Color(pnHex: t.dark ? t.bg : t.ink) : (main ? PN.C.text : PN.C.text2))
                .frame(width: 32, height: 32)
                .background(done ? PN.C.ready : Color.clear, in: RoundedRectangle(cornerRadius: t.statusSquare ? 0 : 16))
                .overlay(RoundedRectangle(cornerRadius: t.statusSquare ? 0 : 16).strokeBorder(done ? PN.C.ready : (main ? PN.C.ruleStrong : PN.C.field), lineWidth: 1.5))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(t.homeText(17, .semibold)).foregroundStyle(PN.C.text)
                    if main && n == 1 {       // theme pass (19.11): the one step needed for briefs and tips
                        Text(t.caps ? L("home.steps.startHere").uppercased() : L("home.steps.startHere"))
                            .font(t.homeMono(11, .semibold)).tracking(t.style == .classic ? 0 : t.lblTrack * 11).foregroundStyle(PN.C.text)
                    }
                }
                Text(sub).font(t.homeText(14)).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if done { Text(t.caps ? L("home.steps.done").uppercased() : L("home.steps.done")).font(t.homeMono(12, .semibold)).foregroundStyle(PN.C.readyText) }
            else if main { Button(n == 1 ? L("home.hero.connectAI") : L("home.finish.connect"), action: run).buttonStyle(.pnPrimary).fixedSize() }
            else { Button(L("home.finish.connect"), action: run).buttonStyle(PNOutlineButtonStyle()).fixedSize() }
        }
        .padding(.vertical, 14).padding(.horizontal, main ? 14 : 0)
        .background(main ? PN.C.focus : Color.clear)
        .overlay { if main { Rectangle().strokeBorder(PN.C.ruleStrong, lineWidth: 2) } }
        .overlay(alignment: .top) { if !main { Rectangle().fill(PN.C.rule).frame(height: 1) } }
        .padding(.vertical, main ? 4 : 0)
        .accessibilityElement(children: .combine)
    }

    // MARK: Coming up (HB row 3): every call of today and tomorrow on a line, then the full list

    private var comingUp: some View {
        let first = nextCall?.id
        let rest = ahead.filter { $0.id != first }
        let near = rest.filter { Calendar.current.isDateInToday($0.start) || Calendar.current.isDateInTomorrow($0.start) || $0.start < now }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text(L("home.comingUp")).pnSection().foregroundStyle(PN.C.text).accessibilityAddTraits(.isHeader)
                if !hiddenNow.isEmpty {
                    Text(L("home.hiddenUndo", ["n": "\(hiddenNow.count)"])).font(t.homeText(13)).foregroundStyle(PN.C.text3)
                    HomeLink(L("ntask.undo"), size: 13) { undoHide() }
                }
                Spacer()
                if cal.access == .granted {
                    HomeLink(L("home.calendars")) { pickCalendars = true }
                        .popover(isPresented: $pickCalendars, arrowEdge: .bottom) { CalendarPicker() }
                }
                Button(L("ntask.showLess")) { showAllCalls = false }.buttonStyle(PNOutlineButtonStyle(height: 28)).fixedSize()
            }
            if near.isEmpty {
                Text(L("home.later.empty")).font(t.homeText(14)).foregroundStyle(PN.C.text3)
            } else {
                timeline(near)
            }
            if !rest.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(rest.enumerated()), id: \.element.id) { i, r in listRow(r, first: i == 0) }
                }
                .padding(.horizontal, 16).padding(.vertical, 4)
                .background(PN.C.surface2)
            }
        }
        .padding(.horizontal, 32).padding(.top, 18).padding(.bottom, 28)
        .overlay(alignment: .bottom) { Rectangle().fill(PN.C.rule).frame(height: 1) }
    }

    private func timeline(_ rows: [Ahead]) -> some View {
        let firstTomorrow = rows.firstIndex { Calendar.current.isDateInTomorrow($0.start) }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                    if i == firstTomorrow {
                        VStack(alignment: .leading, spacing: 6) {
                            ZStack(alignment: .leading) {
                                Rectangle().fill(PN.C.rule).frame(height: 2)
                                Rectangle().fill(PN.C.accent).frame(width: 2, height: 14)
                            }
                            .frame(height: 14)
                            Text(L("home.tomorrowCaps")).font(t.homeMono(11, .semibold)).foregroundStyle(PN.C.accent)
                        }
                        .frame(width: 110, alignment: .leading)
                    }
                    node(r)
                }
            }
            .padding(.bottom, 4)
        }
        .accessibilityLabel(L("home.comingUp"))
    }

    private func node(_ r: Ahead) -> some View {
        let st = state(of: r)
        let (k, _) = tag(r, st)
        let proj = r.model.map { $0.target.isEmpty ? "" : $0.targetName } ?? ""
        return VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .leading) {
                Rectangle().fill(PN.C.rule).frame(height: 2)
                HomeDot(color: k.dot(t), size: 12)
            }
            .frame(height: 14)
            Text([Self.hhmm(r.start), proj].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(t.homeMono(11, .semibold)).foregroundStyle(k.text(t))
                .padding(.horizontal, k.plate(t) == nil ? 0 : 5).background(k.plate(t) ?? .clear).lineLimit(1)
            Button { openCall(r) } label: {
                Text(r.title).font(t.homeText(15, .semibold)).foregroundStyle(PN.C.text).lineLimit(2).multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain).help(L("home.openCall.help"))
        }
        .frame(width: 210, alignment: .leading)
        .padding(.trailing, 16)
        .contextMenu { callMenuItems(r, st) }
    }

    private func callMenu(_ r: Ahead, _ st: CallState) -> some View {
        Menu { callMenuItems(r, st) } label: { Image(systemName: "ellipsis").foregroundStyle(PN.C.text2) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(L("home.more"))
    }

    /// "…": Get ready or Prepare again, Not my call (no Start here: a call starts from its card or its page).
    @ViewBuilder private func callMenuItems(_ r: Ahead, _ st: CallState) -> some View {
        if st == .ready { Button(L("talk.prepareAgain")) { prepare(r) } }
        else if st == .notReady || st == .failed { Button(L("home.getReady")) { prepare(r) } }
        if st == .queued, let m = r.model { Button(L("common.cancel")) { upnext.unqueue(m) } }
        if st == .preparing { Button(L("common.cancel")) { runner.cancel() } }
        Divider()
        if let e = r.event { Button(L("home.notMine")) { hide(e.id) } }
        else { Button(L("home.removeUpNext")) { if let m = r.model { upnext.remove(m) } } }
    }

    /// The full list of Coming up: when, the title with its project and people, the state, the "…" menu.
    private func listRow(_ r: Ahead, first: Bool) -> some View {
        let st = state(of: r)
        let (k, txt) = tag(r, st)
        let f = DateFormatter(); f.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US")
        f.dateFormat = "EEE HH:mm"
        let when = Calendar.current.isDateInToday(r.start) ? L("home.today") + " " + Self.hhmm(r.start) : f.string(from: r.start)
        let m = r.model
        let people = (r.event?.attendees ?? m?.participants ?? []).prefix(3).joined(separator: ", ")
        let over = overlaps(r, ahead).first.map { L("home.check.overlaps", ["title": $0.title]) } ?? ""
        let sub = [m.map { $0.target.isEmpty ? "" : $0.targetName } ?? "", people, over].filter { !$0.isEmpty }.joined(separator: " · ")
        return HStack(alignment: .center, spacing: 12) {
            Text(when).font(t.homeMono(12, .semibold)).foregroundStyle(PN.C.text3).frame(width: 130, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Button { openCall(r) } label: { Text(r.title).font(t.homeText(15, .semibold)).foregroundStyle(PN.C.text).lineLimit(1) }.buttonStyle(.plain)
                if !sub.isEmpty { Text(sub).font(t.homeText(12)).foregroundStyle(PN.C.text3).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HomeTagView(kind: k, text: txt)
            callMenu(r, st)
        }
        .padding(.vertical, 9)
        .overlay(alignment: .top) { Rectangle().fill(first ? Color.clear : PN.C.rule).frame(height: 1) }
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

    // MARK: Recent calls and This week (HM): two columns, one under the other in a narrow window

    private var lower: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 40) {
                recentCalls.frame(minWidth: 360, maxWidth: .infinity, alignment: .topLeading)
                thisWeek.frame(minWidth: 360, maxWidth: .infinity, alignment: .topLeading)
            }
            VStack(alignment: .leading, spacing: 30) { recentCalls; thisWeek }
        }
        .padding(.horizontal, 32).padding(.top, 26).padding(.bottom, 34)
    }

    private var recentCalls: some View {
        let projects = CallFilter.projects(in: history.visible)
        // A remembered project that is not among these calls (archived, another Mac) shows as All projects, so it
        // must not filter either: the list would be empty under "All projects".
        let project = projects.contains { $0.root == filterProject } ? filterProject : ""
        let org = acct.me?.org(filterOrg) != nil ? filterOrg : ""
        let rs = Array(CallFilter.apply(history.visible, org: org, project: project).prefix(5))
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Text(L("home.recentCalls")).pnSection().foregroundStyle(PN.C.text).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if projects.count > 1 {
                    Menu {
                        Button(L("proj.filter.all")) { filterProject = "" }
                        Divider()
                        ForEach(projects, id: \.root) { p in Button(CallFilter.label(p)) { filterProject = p.root } }
                    } label: {
                        HomeField(text: filterProject.isEmpty ? L("proj.filter.all") : (projects.first { $0.root == filterProject }.map(CallFilter.label) ?? L("proj.filter.all")), height: 28)
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help(L("proj.filter.help"))
                }
                if !history.visible.isEmpty { HomeLink(L("home.allPast")) { nav.open(.pastCalls) } }
            }
            .padding(.bottom, 8)
            if rs.isEmpty {
                Text(L("home.recent.empty")).font(t.homeText(14)).foregroundStyle(PN.C.text3).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { Rectangle().fill(PN.C.rule).frame(height: 1) }
            }
            ForEach(rs) { r in HomeRecentRow(r: r) { history.hide(r) } }
        }
    }

    /// This week (HM): calls, hours on calls and prepared calls as three numbers, then AI spend this month,
    /// the account limits and the calls not transcribed yet.
    private var thisWeek: some View {
        let recs = CallStats.calls(from: CallStats.weekStart(now), to: now.addingTimeInterval(1))
        let tot = CallStats.totals(recs)
        let mins = Int(tot.minutes.rounded())
        let cfg = AppConfig.load(from: AppPaths.config)
        let spent = SpendLedger.monthSpent()
        let limits = AIStatusModel.shared.rows.filter { $0.usage.contains("%") && $0.usage.count <= 24 }.map { $0.name + " " + $0.usage }.joined(separator: " · ")
        let notTr = history.visible.filter { ($0.lines ?? 1) == 0 }
        let stats: [(String, String)] = [("\(tot.calls)", L("home.week.calls")), (String(format: "%d:%02d", mins / 60, mins % 60), L("home.week.hoursOnCalls")),
                                         ("\(tot.prepared)/\(tot.calls)", L("home.week.prepared"))]
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Text(L("home.week")).pnSection().foregroundStyle(PN.C.text).accessibilityAddTraits(.isHeader)
                Spacer()
                HomeLink(L("home.week.detailsTitle")) { nav.open(.stats) }
            }
            .padding(.bottom, 8)
            HStack(alignment: .top, spacing: 0) {
                ForEach(stats, id: \.1) { s in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(s.0).font(t.homeDisplay(t.style == .classic ? 44 : 60, t.heroWeight)).tracking(t.numTrack * 60)
                            .foregroundStyle(PN.C.text).lineLimit(1).minimumScaleFactor(0.5)
                        Text(t.caps ? s.1.uppercased() : s.1).font(t.homeMono(12, t.labelWeight)).foregroundStyle(PN.C.text3)
                    }
                    .padding(.vertical, 14).padding(.trailing, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            .overlay(alignment: .top) { Rectangle().fill(PN.C.rule).frame(height: 1) }
            HomeFactRow(key: L("home.week.spend")) {
                Text(L("home.week.preparedOf", ["x": String(format: "$%.2f", spent), "y": String(format: "$%.0f", cfg.budget.monthlyHardUSD)]))
                    .font(t.homeMono(13, .semibold)).foregroundStyle(PN.C.text)
            }
            if !limits.isEmpty {
                HomeFactRow(key: L("home.week.limits")) { Text(limits).font(t.homeMono(13, .semibold)).foregroundStyle(PN.C.text).lineLimit(1) }
            }
            if let first = notTr.first {
                HomeFactRow(key: L("home.week.notTranscribed")) {
                    HomeLink(L(notTr.count == 1 ? "home.week.notTranscribed.one" : "home.week.notTranscribed.many", ["n": "\(notTr.count)"])) {
                        CallPageWindow.show(file: first.file)
                    }
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
    /// 0.10.0 (Meeting Sheet, phase 4): a call with its project known opens Quick or Expert at once.
    private func prepare(_ r: Ahead) {
        let m = model(for: r)
        StartCallWindow.getReady(m)      // A1: no old Prepare form, a call without a project opens Expert step 1
    }

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
                Circle().fill(st.dot).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(Self.when(r)).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(1)
                Spacer(minLength: 0)
                if let src = r.source {
                    Text(L(src == "link" ? "tr.mark.link" : "tr.mark.file")).font(PN.sys(10, .bold)).foregroundStyle(PN.C.text2)
                        .padding(.horizontal, 4).padding(.vertical, 1).background(PN.C.surface2, in: RoundedRectangle(cornerRadius: PN.r(4)))
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
            Button(L("reassign.menu")) { ReassignPanel.show(file: r.file) }      // 0.10.1 (A3)
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
        return MeetingNotes.homeLine(text)          // 0.17.0: also the TL;DR of the app's own notes
    }
}

/// 0.9.0: "All past calls": the old Recent list, all visible calls.
/// 0.25 (R4, board PC-PastCalls): the bar, how many calls since when, the title, the filters and Find on the right;
/// the calls grouped by week (This week, Last week) and then by month, each row with its date, what came out of it
/// and the state of its notes; on hover Summary, Follow-up and Series.
struct PastCallsView: View {
    @ObservedObject var history = CallHistory.shared
    @AppStorage("callFilterOrg") private var filterOrg = ""          // 0.17.0 (B6b, D39)
    @AppStorage("callFilterProject") private var filterProject = ""
    @ObservedObject private var acct = PacenoteAccount.shared
    @State private var find = ""
    @Environment(\.pnTheme) private var t

    private var shown: [CallHistory.Record] {
        let q = find.lowercased()
        return CallFilter.apply(history.visible, org: filterOrg, project: filterProject)
            .filter { q.isEmpty || $0.title.lowercased().contains(q) || $0.project.lowercased().contains(q) }
    }

    /// This week, Last week, then one group a month ("October 2026").
    private var groups: [(String, [CallHistory.Record])] {
        let cal = Calendar.current
        let now = Date()
        let weekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        let lastStart = cal.date(byAdding: .day, value: -7, to: weekStart) ?? weekStart
        let mf = DateFormatter(); mf.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US"); mf.setLocalizedDateFormatFromTemplate("LLLLyyyy")
        var out: [(String, [CallHistory.Record])] = []
        for r in shown.sorted(by: { $0.start > $1.start }) {
            let key = r.start >= weekStart ? L("past.g.thisWeek") : r.start >= lastStart ? L("past.g.lastWeek") : mf.string(from: r.start).capitalized
            if let i = out.firstIndex(where: { $0.0 == key }) { out[i].1.append(r) } else { out.append((key, [r])) }
        }
        return out
    }

    var body: some View {
        Group {
        VStack(spacing: 0) {
            PageBackBar(crumb: L("past.crumb"))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let all = history.visible
                    let since = all.map(\.start).min()
                    HStack(alignment: .bottom, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            HomeMeta(text: since.map { L("past.meta", ["n": "\(all.count)", "date": HomeRecentRow.day($0)]) } ?? L("past.metaNone"))
                            Text(t.cased(L("home.allPast"))).font(t.homeDisplay(t.style == .classic ? 32 : 40, t.titleWeight))
                                .tracking(t.dTrack * 40).foregroundStyle(PN.C.text)
                        }
                        Spacer(minLength: 8)
                        CallFilters(org: $filterOrg, project: $filterProject, records: all)
                        TextField("", text: $find, prompt: Text(L("past.find"))).labelsHidden().pageField(30).frame(width: 200)
                    }
                    .padding(.horizontal, PageMetrics.side).padding(.top, 24).padding(.bottom, 18)
                    if !filterOrg.isEmpty || !filterProject.isEmpty {
                        HStack(spacing: 10) {
                            Text(L("past.showing", ["n": "\(shown.count)"])).font(t.homeText(14)).foregroundStyle(PN.C.text2)
                            HomeLink(L("past.clear")) { filterOrg = ""; filterProject = "" }
                        }
                        .padding(.horizontal, PageMetrics.side).padding(.bottom, 10)
                    }
                    VStack(alignment: .leading, spacing: 22) {
                        if shown.isEmpty { Text(L("past.none")).font(t.homeText(15)).foregroundStyle(PN.C.text3).pageRow(10) }
                        ForEach(groups, id: \.0) { g in
                            VStack(alignment: .leading, spacing: 0) {
                                PageSectionHead(title: g.0, count: "\(g.1.count)")
                                ForEach(g.1) { r in PastCallRow(r: r) { history.hide(r) } }
                            }
                        }
                        Text(L("past.foot")).font(t.homeText(13)).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, PageMetrics.side).padding(.top, 8).padding(.bottom, 36)
                }
                .environment(\.pageFlat, true)
            }
        }
        .background(PN.C.bg)
    }
        .trackScreen("past_calls")
    }
}

/// One row of All past calls (board PC): the date and time, the title (a mark when it came from a file), the project,
/// the length and the series, what came out of it; the state of the notes, or on hover Summary, Follow-up, Series.
struct PastCallRow: View {
    let r: CallHistory.Record
    var onHide: () -> Void
    @State private var hover = false
    @Environment(\.pnTheme) private var t

    var body: some View {
        let transcribed = (r.lines ?? 1) > 0
        let o = OutcomeCache.shared.outcome(r.file)
        let notes = transcribed && RecentCard.summary(r.file) != nil
        let kind: HomeTag = !transcribed ? .notReady : notes ? .ready : .neutral
        let tag = L(!transcribed ? "home.tag.notTranscribed" : notes ? "home.tag.notesReady" : "home.tag.transcriptOnly")
        let series = CallPageView.series(of: r).count
        let mins = r.minutes.map { L("call.page.minutes", ["n": "\(max(1, Int($0.rounded())))"]) } ?? ""
        let sub = [r.project, mins].filter { !$0.isEmpty }.joined(separator: " · ")
        let counts = RecentCard.counts(o)
        let outcome = !transcribed ? L("past.notTranscribed") : notes ? (counts.isEmpty ? L("past.noDecisions") : counts) : L("past.transcriptOnly")
        let df = CallPageView.fmt("EEEdMMMHHmm")
        HStack(alignment: .top, spacing: 14) {
            Text(df.string(from: r.start)).font(t.homeMono(12)).foregroundStyle(PN.C.text3).frame(width: 150, alignment: .leading).padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(r.title).font(t.homeText(17, .semibold)).foregroundStyle(PN.C.text).lineLimit(1)
                    if r.source != nil {
                        Text(t.caps ? L("past.fromFile").uppercased() : L("past.fromFile")).font(t.homeMono(10, .semibold)).foregroundStyle(PN.C.text2)
                            .padding(.horizontal, 4).overlay(Rectangle().strokeBorder(PN.C.field, lineWidth: 1)).fixedSize()
                    }
                }
                HStack(spacing: 4) {
                    Text(sub).font(t.homeText(13)).foregroundStyle(PN.C.text2)
                    if series > 1 { HomeLink("· " + L("past.seriesN", ["n": "\(series)"]), size: 13) { SeriesWindow.show(record: r) } }
                }
                Text(outcome).font(t.homeMono(12)).foregroundStyle(PN.C.text3).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if hover {
                HStack(spacing: 8) {
                    Button(L("past.btn.summary")) { CallPageWindow.show(file: r.file) }.buttonStyle(.pnRow)
                    if transcribed { Button(L("past.btn.followup")) { FollowUpWindow.show(file: r.file) }.buttonStyle(.pnRow) }
                    if series > 1 { Button(L("past.btn.series")) { SeriesWindow.show(record: r) }.buttonStyle(.pnRow) }
                }
                .fixedSize()
            } else {
                HomeTagView(kind: kind, text: tag)
            }
        }
        .pageRow(11)
        .background(hover ? PN.C.surface2 : Color.clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { CallPageWindow.show(file: r.file) }
        .contextMenu {
            if let u = r.notionURL.flatMap({ URL(string: $0) }) { Button(L("home.recent.notion")) { NSWorkspace.shared.open(u) } }
            Button(L("home.recent.transcript")) { TranscriptWindow.show(file: r.file) }
            Button(L("call.page.followup")) { FollowUpWindow.show(file: r.file) }
            if series > 1 { Button(L("call.page.series", ["n": "\(series)"])) { SeriesWindow.show(record: r) } }
            Button(L("home.recent.finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.file)]) }
            Button(L("reassign.menu")) { ReassignPanel.show(file: r.file) }
            Divider()
            Button(L("home.recent.hide"), action: onHide)
        }
        .accessibilityElement(children: .contain)
    }
}

/// 0.9.0: the Tracker screen (Tracker.swift). The old On you list stays reachable from its Tasks tab data.
struct TrackerView: View {
    var body: some View { TrackerScreen().trackScreen("tracker") }
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
                    Text(L(src == "link" ? "tr.mark.link" : "tr.mark.file")).font(PN.sys(10, .bold)).foregroundStyle(PN.C.text2)
                        .padding(.horizontal, 4).padding(.vertical, 1).background(PN.C.surface2, in: RoundedRectangle(cornerRadius: PN.r(4)))
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
                            Text(L("series.why")).pnSection()
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
            Button(L("reassign.menu")) { ReassignPanel.show(file: r.file) }      // 0.10.1 (A3)
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
        Button(action: run) { Image(systemName: "trash").font(PN.sys(11)) }
            .buttonStyle(.plain).foregroundStyle(PN.C.text3)
            .opacity(hover ? 1 : 0.0001)
            .onHover { hover = $0 }
            .help(L("ntask.removeHelp")).accessibilityLabel(L("ntask.removeHelp"))
    }
}
