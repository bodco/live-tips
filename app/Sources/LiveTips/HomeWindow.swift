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

struct HomeView: View {
    let app: AppDelegate
    @ObservedObject var cal = CalendarService.shared
    @ObservedObject var upnext = UpNext.shared
    @ObservedObject var history = CallHistory.shared
    @ObservedObject var runner = PrepRunner.shared
    @State private var featuresCard = FeaturesWindow.showOnHome
    @ObservedObject var register = Register.shared        // Pacenote 0.8: the commitments register
    @ObservedObject var ntasks = NotionTasks.shared       // 0.8.6 (D): the PM's Notion tasks in On you
    @AppStorage("onYouFilter") private var onYouFilter = ""         // "" = All projects, else "<slug>" or "workspace:<name>"
    @AppStorage("onYouHidden") private var onYouHidden = ""         // Hide here (local only), ids joined by ","
    @State private var onYouAll = false                              // 0.8.6 (owner): Show all instead of the first 8
    @ObservedObject var auto = AutoStart.shared            // Pacenote 0.8: "Start tips for ...?" when a call begins
    @State private var now = Date()
    @State private var status = EngineStatus()
    @State private var note = ""
    @State private var pickCalendars = false
    /// 2026-10-27 (owner): Settings > General can hide the week's numbers (a demo to colleagues).
    @AppStorage("homeShowStats") private var showStats = true

    private var live: Bool { CallEngine.shared.isRunning || ["recording", "standby", "loading_model"].contains(status.state) }

    @ObservedObject var nav = HomeNav.shared               // 0.8.7 (A2): call page, series, Statistics push here

    var body: some View {
        NavigationStack(path: $nav.path) {
            homeBody.navigationDestination(for: HomeNav.Route.self) { r in HomeRouteView(route: r) }
        }
    }

    private var homeBody: some View {
        VStack(spacing: 0) {
            toolbar.padding(.horizontal, 24).padding(.vertical, 14)
            Divider()
            GeometryReader { geo in
                ScrollView {
                    Group {
                        if geo.size.width >= 900 {
                            HStack(alignment: .top, spacing: 20) {
                                leftColumn.frame(maxWidth: .infinity, alignment: .topLeading)
                                rightColumn.frame(width: 360)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 20) { leftColumn; rightColumn }
                        }
                    }
                    .padding(24)
                }
            }
            Divider()
            statusBar.padding(.horizontal, 24).padding(.vertical, 9)
        }
        .background(PN.C.bg)
        .frame(minWidth: 680, minHeight: 560)
        .onAppear { tick(); cal.refresh(); history.scan(); upnext.pruneHeld(); upnext.adoptPreparedEvents(); register.importOnce(); ntasks.keepFresh()
                    runner.refreshAuth() }     // 0.8.7 (L3.3): the Connect Claude card needs the sign-in state
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

    // MARK: toolbar

    private var toolbar: some View {
        let today = cal.events.filter { Calendar.current.isDateInToday($0.start) && !cal.hidden.contains($0.id) }
        let mins = today.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) / 60 }
        let df = DateFormatter()
        df.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US")
        df.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        var sub = df.string(from: now)
        if !today.isEmpty { sub += " · " + L(today.count == 1 ? "home.calls.one" : "home.calls.many", ["n": "\(today.count)"]) + ", " + Self.hm(mins) }
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("home.today")).font(.system(size: 22, weight: .bold)).foregroundStyle(PN.C.text)
                Text(sub).font(PN.Font.body).foregroundStyle(PN.C.text3)
            }
            Spacer()
            // Pacenote 0.8 (idea 05): ask about past calls of a project (Command-F).
            if history.records.isEmpty {
                // 0.8.7 (L2): no transcripts in any project yet: greyed with the condition; a click opens Start call
                VStack(spacing: 1) {
                    Button { StartCallWindow.show(delegate: app) } label: { Label(L("memory.button"), systemImage: "magnifyingglass") }
                        .buttonStyle(.pnTertiary).opacity(0.5)
                    Text(L("memory.afterFirst")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                }
                .help(L("memory.afterFirst"))
            } else {
                Button { MemoryWindow.show() } label: { Label(L("memory.button"), systemImage: "magnifyingglass") }
                    .buttonStyle(.pnTertiary).keyboardShortcut("f", modifiers: .command).help(L("memory.help"))
            }
            // 0.8.6 (B): a recording or a link becomes a transcript like a call
            Button(L("tr.window")) { TranscribeWindow.show() }.buttonStyle(.pnTertiary).help(L("tr.subtitle"))
            Button(L("home.planCall")) { StartCallWindow.show(delegate: app, planOnly: true) }
                .buttonStyle(.pnSecondary)
                .help(L("home.planCall.help"))
            if !live {
                Button(L("home.startCall")) { StartCallWindow.show(delegate: app) }
                    .buttonStyle(.pnPrimary).keyboardShortcut("n", modifiers: .command)
            }
            // 0.8.5: Settings straight from Home (the gear at the right end of the toolbar).
            Button { SettingsWindow.show() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.pnTertiary).help(L("home.settings")).accessibilityLabel(L("home.settings"))
        }
    }

    static func hm(_ m: Double) -> String {
        let t = Int(m.rounded())
        return t >= 60 ? L("home.hm", ["h": "\(t / 60)", "m": "\(t % 60)"]) : L("home.m", ["m": "\(t)"])
    }

    // MARK: calls ahead

    private var ahead: [Ahead] {
        var rows: [Ahead] = []
        var used = Set<ObjectIdentifier>()
        let ce = CallEngine.shared
        let liveKey = ce.isRunning ? EditLog.seriesKey(ce.renamed ?? (ce.callRequest["title"] as? String) ?? "") : ""
        for e in cal.upcoming(now) {
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

    @ViewBuilder private var leftColumn: some View {
        let rows = ahead
        VStack(alignment: .leading, spacing: 20) {
            if let e = auto.suggestion, !live { autoBanner(e) }
            finishSetup
            if featuresCard {        // 0.8.7 (L1): the first 14 days, until closed
                FeaturesView(compact: true, onClose: { UserDefaults.standard.set(true, forKey: "featuresCardClosed"); featuresCard = false })
                    .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.l))
            }
            if !note.isEmpty { Text(note).font(PN.Font.body).foregroundStyle(PN.C.onMe) }
            // Up next: the call being recorded, or the nearest one; an event that began more than 5 minutes ago without
            // being recorded stays in Later (with its Live badge).
            let first = live ? nil : rows.first { $0.event == nil || $0.start > now.addingTimeInterval(-5 * 60) }
            if live { liveCard } else if let first = first { upNextCard(first, overlaps: overlaps(first, rows)) } else { adaptiveHero }
            // 0.8.7 (C): an empty Later is hidden
            if !rows.filter({ $0.id != first?.id }).isEmpty { laterSection(rows.filter { $0.id != first?.id }) }
        }
    }

    // MARK: Finish setup (REDESIGN-SPEC 7: what the onboarding left for later, until it is done)

    @AppStorage("finishSetupHidden") private var finishHidden = ""

    private struct Todo: Identifiable { var id: String; var text: String; var action: String; var run: () -> Void }

    private var todos: [Todo] {
        let demo = ProcessInfo.processInfo.environment["LT_SUPPORT_DIR"] != nil
        let settings = SettingsWindow.model
        var out: [Todo] = []
        if !demo && !CallEngine.shared.problems().isEmpty {
            out.append(Todo(id: "install", text: L("home.finish.install"), action: L("home.finish.open"), run: { SetupWindow.show() }))
        }
        if settings.config.nameAliases.isEmpty {
            out.append(Todo(id: "name", text: L("home.finish.name"), action: L("home.finish.add"), run: { SettingsWindow.show(tab: "general") }))
        }
        if cal.access != .granted {
            out.append(Todo(id: "calendars", text: L("home.finish.calendars"), action: L("onboarding.permissions.calendarsButton"), run: { cal.connect() }))
        }
        // 0.8.7 (L3.3): no API key and Claude Code not signed in: nothing can prepare a call or write the follow-up
        if !demo && !runner.hasAPIKey && (runner.loggedIn == false || (runner.loggedIn == nil && PrepRunner.claudePath == nil)) {
            out.append(Todo(id: "claude", text: L("home.finish.claude"), action: L("home.finish.connect"), run: { SettingsWindow.show(tab: "ai") }))
        }
        if !demo && !settings.isSet(.notionToken) {
            out.append(Todo(id: "notion", text: L("home.finish.notion"), action: L("home.finish.connect"), run: { SettingsWindow.show(tab: "notion") }))
        }
        let hidden = Set(finishHidden.split(separator: ",").map(String.init))
        return out.filter { !hidden.contains($0.id) }
    }

    @ViewBuilder private var finishSetup: some View {
        let list = todos
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("home.finish.title")).font(PN.Font.section).foregroundStyle(PN.C.text)
                ForEach(list) { t in
                    HStack(spacing: 10) {
                        Image(systemName: "circle.dashed").foregroundStyle(PN.C.accent).accessibilityHidden(true)
                        Text(t.text).font(PN.Font.body).foregroundStyle(PN.C.text)
                        Spacer()
                        Button(t.action, action: t.run).buttonStyle(.pnTertiary)
                        Button { finishHidden = (finishHidden.isEmpty ? "" : finishHidden + ",") + t.id } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).foregroundStyle(PN.C.text3).accessibilityLabel(L("home.finish.later"))
                            .help(L("home.finish.later"))
                    }
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(PN.C.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: PN.Radius.m))
        }
    }

    private func overlaps(_ r: Ahead, _ rows: [Ahead]) -> [CalendarService.CalEvent] {
        guard let e = r.event else { return [] }
        return rows.compactMap(\.event).filter { e.overlaps($0) }
    }

    /// 0.8.7 (C): with no call ahead the hero is what matters now: due or overdue items on you, else the last call of
    /// the past 3 days, else one small line.
    @ViewBuilder private var adaptiveHero: some View {
        let endOfToday = Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: now) ?? now
        let due = register.open(mine: true).filter { c in
            guard let d = CommitmentRegister.dueDate(c.due, from: now) else { return false }
            return d <= endOfToday
        }.sorted { (CommitmentRegister.dueDate($0.due, from: now) ?? now) < (CommitmentRegister.dueDate($1.due, from: now) ?? now) }
        let last = history.visible.filter { $0.start > now.addingTimeInterval(-3 * 86400) && $0.start < now }.max { $0.start < $1.start }
        if !due.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("home.hero.todayOnYou")).font(PN.Font.label).foregroundStyle(PN.C.text3)
                ForEach(due.prefix(3)) { c in
                    HStack(alignment: .top, spacing: 8) {
                        Toggle("", isOn: Binding(get: { c.status == "done" }, set: { register.mark(c, $0 ? "done" : "reopen") }))
                            .toggleStyle(.checkbox).labelsHidden()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.text).font(.system(size: 15, weight: .semibold)).foregroundStyle(PN.C.text).fixedSize(horizontal: false, vertical: true)
                            Text(L("reg.due", ["due": Register.dueText(c.due)])).font(PN.Font.caption)
                                .foregroundStyle((CommitmentRegister.dueDate(c.due, from: now) ?? now) < Calendar.current.startOfDay(for: now) ? PN.C.danger : PN.C.text3)
                        }
                    }
                }
                let n = register.open(mine: true).count
                if n > 3 { Text(L("home.hero.allOnYou", ["n": "\(n)"])).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.l))
        } else if let r = last {
            let o = CallOutcome.read(transcript: r.file) ?? CallOutcome()
            VStack(alignment: .leading, spacing: 8) {
                Text(L("home.hero.lastCall")).font(PN.Font.label).foregroundStyle(PN.C.text3)
                Text(r.title).font(.system(size: 17, weight: .semibold)).foregroundStyle(PN.C.text)
                Text(CallPageView.fmt("EEEEdMMMMHHmm").string(from: r.start)).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                ForEach(o.decisions.prefix(3), id: \.self) { d in Text("• " + d).font(PN.Font.body).foregroundStyle(PN.C.text).fixedSize(horizontal: false, vertical: true) }
                if !o.onMe.isEmpty { Text(L("home.outcome.onYou", ["n": "\(o.onMe.count)"])).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
                Button(L("home.hero.openCall")) { CallPageWindow.show(file: r.file) }.buttonStyle(.pnSecondary)
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.l))
        } else {
            HStack(spacing: 8) {
                Text(cal.access == .granted ? L("home.nothingAhead") : L("home.connectCalendars")).font(PN.Font.body).foregroundStyle(PN.C.text3)
                if cal.access != .granted { Button(L("onboarding.permissions.calendarsButton")) { cal.connect() }.buttonStyle(.pnTertiary) }
                Button(L("home.planCall")) { StartCallWindow.show(delegate: app, planOnly: true) }.buttonStyle(.pnTertiary)
            }
        }
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("home.upNext")).font(PN.Font.label).foregroundStyle(PN.C.text3)
            Text(cal.access == .granted ? L("home.nothingAhead") : L("home.connectCalendars"))
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(PN.C.text)
            HStack(spacing: 8) {
                if cal.access != .granted { Button(L("onboarding.permissions.calendarsButton")) { cal.connect() }.buttonStyle(.pnSecondary) }
                Button(L("home.planCall")) { StartCallWindow.show(delegate: app, planOnly: true) }.buttonStyle(.pnTertiary)
            }
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.l))
    }

    private var liveCard: some View {
        let ce = CallEngine.shared
        let title = ce.renamed ?? (ce.callRequest["title"] as? String) ?? status.project ?? L("app.name")
        let since = status.startedAt.flatMap { ISO8601DateFormatter().date(from: $0) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(L("home.upNext")).font(PN.Font.label).foregroundStyle(PN.C.text3)
                Spacer()
                HStack(spacing: 4) {
                    Text(status.state == "standby" ? L("menubar.status.waiting") : L("home.live"))
                    if let s = since, status.state == "recording" {
                        Text("·")
                        Text(s, style: .timer).monospacedDigit()
                    }
                }
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(PN.C.danger)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(PN.C.danger.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
            }
            Text(title).font(PN.Font.title).foregroundStyle(PN.C.text).lineLimit(2)
            if let p = status.project { Text(p).font(PN.Font.body).foregroundStyle(PN.C.text2) }
            HStack(spacing: 8) {
                Button(L("menubar.showTips")) { app.showTips() }.buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
                Button(L("menubar.endCall")) { app.endCall() }.buttonStyle(.pnSecondary)
            }
            .padding(.top, 6)
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.l))
    }

    private func platform(_ e: CalendarService.CalEvent?) -> String {
        guard let l = e?.link?.lowercased() else { return "" }
        if l.contains("zoom") { return "Zoom" }
        if l.contains("meet.google") { return "Google Meet" }
        if l.contains("teams") { return "Microsoft Teams" }
        return ""
    }

    private func upNextCard(_ r: Ahead, overlaps: [CalendarService.CalEvent]) -> some View {
        let m = r.model
        let checks = readiness(r, overlaps: overlaps)
        let hasBrief = m.flatMap { PrepDocWindow.path(for: $0) } != nil
        let todo = checks.filter { $0.ok == false }.count
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        let rel = r.event?.relative(now) ?? ""
        let people = (r.event?.attendees ?? m?.participants ?? []).prefix(4).joined(separator: ", ")
        let meta = [m.map { $0.target.isEmpty ? "" : $0.targetName } ?? "", people, platform(r.event)].filter { !$0.isEmpty }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(([L("home.upNext").uppercased(), Self.relativeText(r.start, now: now), tf.string(from: r.start) + (r.end.map { "-" + tf.string(from: $0) } ?? "")]
                          .filter { !$0.isEmpty }).joined(separator: " · "))
                        .font(PN.Font.label).foregroundStyle(PN.C.text3)
                    Spacer()
                    if rel == "in progress" { PNBadge(text: L("home.live"), kind: .live) }
                }
                Text(r.title).font(PN.Font.title).foregroundStyle(PN.C.text).lineLimit(2)
                if !meta.isEmpty { Text(meta).font(PN.Font.body).foregroundStyle(PN.C.text2).lineLimit(2) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L("home.ready.title")).font(PN.Font.section).foregroundStyle(PN.C.text)
                    Spacer()
                    if !hasBrief { PNBadge(text: L("badge.notPrepared"), kind: .notPrepared) }
                    else if todo == 0 { PNBadge(text: L("badge.ready"), kind: .ready) }
                    else { PNBadge(text: L("home.ready.mostly", ["n": "\(todo)"]), kind: .stale) }
                }
                ForEach(checks) { c in checkRow(c) }
                // 0.8.5 (P6, entry 2): a rehearsal row for presentation calls only.
                if let m = r.model, m.callType == "presentation", let p = PrepDocWindow.path(for: m), TalkWindow.available(base: String(p.dropLast(9))) {
                    let e = RehearsalWindow.entryLine(base: String(p.dropLast(9)))
                    HStack(spacing: 10) {
                        Image(systemName: "questionmark.circle").foregroundStyle(PN.C.text3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.title).font(PN.Font.body).foregroundStyle(PN.C.text)
                            if !e.sub.isEmpty { Text(e.sub).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
                        }
                        Spacer()
                        Button(L("rehearse.button")) { RehearsalWindow.show(base: String(p.dropLast(9)), title: m.effectiveTitle, call: m) }.buttonStyle(.pnTertiary)
                    }
                } else if let m = r.model, m.callType == "presentation" {
                    // 0.8.7 (L2): greyed with the condition; a click opens Start call, where Prepare makes the talk
                    HStack(spacing: 10) {
                        Image(systemName: "questionmark.circle").foregroundStyle(PN.C.text3)
                        Text(L("rehearse.needPrep")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                        Spacer()
                        Button(L("rehearse.button")) { StartCallWindow.show(delegate: app, prepared: model(for: r)) }
                            .buttonStyle(.pnTertiary).opacity(0.5).help(L("rehearse.needPrep"))
                    }
                }
            }
            HStack(spacing: 8) {
                Button(L("home.startTips")) { start(r) }.buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
                Button(L("home.editSetup")) { StartCallWindow.show(delegate: app, prepared: model(for: r)) }.buttonStyle(.pnSecondary)
                // 2026-10-29 (owner): a ready brief can be prepared again from here too (the form asks first).
                if hasBrief { Button(L("talk.prepareAgain")) { StartCallWindow.show(delegate: app, prepared: model(for: r)) }.buttonStyle(.pnTertiary) }
                // Pacenote 0.8: the series page (idea 06) and a rehearsal of a presentation (idea 10).
                if let m = r.model, m.callType == "presentation", let p = PrepDocWindow.path(for: m), TalkWindow.available(base: String(p.dropLast(9))) {
                    Button(L("talk.open")) { TalkWindow.show(base: String(p.dropLast(9)), title: m.effectiveTitle, call: m) }.buttonStyle(.pnTertiary)
                }
                if let last = lastOfSeries(r), CallPageView.series(of: last).count > 0 {
                    Button(L("call.page.series", ["n": "\(CallPageView.series(of: last).count)"])) { SeriesWindow.show(record: last) }.buttonStyle(.pnTertiary)
                }
            }
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.l))
    }

    static func relativeText(_ d: Date, now: Date) -> String {
        let m = Int((d.timeIntervalSince(now) / 60).rounded())
        if m <= 0 { return "" }
        if m < 90 { return L("home.inMin", ["n": "\(m)"]) }
        if Calendar.current.isDateInTomorrow(d) { return L("home.tomorrow") }
        return ""
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

    // MARK: readiness (REDESIGN-SPEC 4.2)

    private struct Check: Identifiable {
        var id: String
        var ok: Bool?                 // true done, false to do, nil information
        var text: String
        var sub: String = ""
        var action: String = ""
        var run: (() -> Void)?
    }

    /// The latest earlier call of the same series (project + title, as "Regular calls remembered").
    private func lastOfSeries(_ r: Ahead) -> CallHistory.Record? {
        let key = EditLog.seriesKey(r.title)
        return history.visible.first { $0.start < now && EditLog.seriesKey($0.title) == key }
    }

    private func readiness(_ r: Ahead, overlaps: [CalendarService.CalEvent]) -> [Check] {
        var out: [Check] = []
        let m = r.model
        let st = m.map { upnext.prepState($0) } ?? .none
        if let m = m, st != .running, let fr = Freshness.check(m), fr.stale {
            // Pacenote 0.8 (idea 03): "Brief is 2 days old · 3 changes since" with Refresh, never by itself.
            out.append(Check(id: "brief", ok: false, text: fr.line,
                             sub: fr.changes.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: ", "),
                             action: L("fresh.refresh"), run: { refresh(r) }))
        } else if let m = m, let p = PrepDocWindow.path(for: m) {
            let at = ((try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date).map {
                let f = DateFormatter(); f.dateFormat = Calendar.current.isDateInToday($0) ? "HH:mm" : "d MMM HH:mm"; return f.string(from: $0)
            } ?? ""
            out.append(Check(id: "brief", ok: true, text: L("home.check.briefReady", ["at": at]), action: L("menubar.openBrief"),
                             run: { PrepDocWindow.show(path: p, title: m.effectiveTitle) }))
        } else if st == .running || st == .queued {
            out.append(Check(id: "brief", ok: nil, text: st == .running ? L("home.check.preparing", ["p": "\(Int(runner.progress * 100))"]) : L("badge.queued")))
        } else {
            out.append(Check(id: "brief", ok: false, text: L("home.check.noBrief"), sub: st == .failed ? L("badge.failed") : "",
                             action: L("menubar.prepare"), run: { prepare(r) }))
        }
        // Pacenote 0.8 (idea 01): what is still open from this series, from the commitments register.
        let series = seriesCommitments(r)
        let mine = series.filter { $0.mine }, theirs = series.filter { !$0.mine }
        if let first = mine.first {
            out.append(Check(id: "onyou", ok: false, text: L("home.check.onYou", ["text": first.text]),
                             sub: mine.count > 1 ? L("home.check.more", ["n": "\(mine.count - 1)"]) : "",
                             action: L("reg.markDone"), run: { register.mark(first) }))
        }
        // 0.8.6 (D4): the PM's Notion tasks for this call's project join the onyou check
        if let t = r.model?.target, !t.isEmpty {
            let key = t.hasPrefix("project:") ? String(t.dropFirst(8)) : "workspace:" + String(t.dropFirst(10))
            let nt = ntasks.tasks(for: key)
            if !nt.isEmpty {
                let reg = ProjectRegistry.load(from: AppPaths.projects)
                let pname = key.hasPrefix("workspace:") ? String(key.dropFirst(10)) : (reg.projects.first { $0.slug == key }?.name ?? key)
                out.append(Check(id: "onyou-notion", ok: false, text: L("ntask.readiness", ["n": "\(nt.count)", "project": pname]),
                                 sub: nt.prefix(2).map { $0.title }.joined(separator: "; ")))
            }
        }
        if let t = theirs.first {
            out.append(Check(id: "onthem", ok: nil, text: L("home.check.onThem", ["who": t.owner, "text": t.text]),
                             sub: theirs.count > 1 ? L("home.check.more", ["n": "\(theirs.count - 1)"]) : ""))
        }
        if let last = lastOfSeries(r), let o = OutcomeCache.shared.outcome(last.file) {
            if !o.openQuestions.isEmpty {
                out.append(Check(id: "questions", ok: nil, text: L(o.openQuestions.count == 1 ? "home.check.question" : "home.check.questions", ["n": "\(o.openQuestions.count)"]),
                                 sub: o.openQuestions.prefix(2).joined(separator: "; ")))
            }
        }
        for e in overlaps {
            out.append(Check(id: "overlap-" + e.id, ok: false, text: L("home.check.overlaps", ["title": e.title]),
                             action: L("home.check.skip", ["title": e.title]), run: { cal.hidden.insert(e.id) }))
        }
        return out
    }

    /// Open items of this meeting series, only when its project is known (never mixed across projects).
    private func seriesCommitments(_ r: Ahead) -> [Commitment] {
        let key = EditLog.seriesKey(r.title)
        var slug: String?
        if let t = r.model?.target, !t.isEmpty {
            slug = t.hasPrefix("project:") ? String(t.dropFirst(8)) : String(t.dropFirst(10)).lowercased()
        } else if let last = lastOfSeries(r) {
            let reg = ProjectRegistry.load(from: AppPaths.projects)
            slug = reg.projects.first { $0.name == last.project || $0.slug == last.project || ($0.root as NSString).lastPathComponent == last.project }?.slug
                ?? reg.workspaces.first { $0.name == last.project }?.name.lowercased()
        }
        guard let s = slug, !s.isEmpty else { return [] }
        return register.open(mine: nil).filter { $0.project == s && $0.series.split(separator: "|", maxSplits: 1).last.map(String.init) == key }
    }

    private func refresh(_ r: Ahead) {
        let m = model(for: r)
        if r.model == nil { upnext.save(m) }
        if let e = upnext.refresh(m) { note = e }
    }

    private func checkRow(_ c: Check) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: c.ok == true ? "checkmark.circle.fill" : c.ok == false ? "exclamationmark.circle" : "info.circle")
                .foregroundStyle(c.ok == true ? PN.C.turn : c.ok == false ? PN.C.onMe : PN.C.text3)
                .frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.text).font(PN.Font.body).foregroundStyle(PN.C.text).fixedSize(horizontal: false, vertical: true)
                if !c.sub.isEmpty { Text(c.sub).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(2) }
            }
            Spacer(minLength: 8)
            if let run = c.run, !c.action.isEmpty { Button(c.action, action: run).buttonStyle(.pnTertiary) }
        }
    }

    // MARK: Later (REDESIGN-SPEC 4.3: state -> one action, the rest in the context menu)

    @ViewBuilder private func laterSection(_ rows: [Ahead]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("home.later")).font(PN.Font.section).foregroundStyle(PN.C.text)
                Spacer()
                if cal.access == .granted {
                    Button(L("home.calendars")) { pickCalendars = true }.buttonStyle(.pnTertiary)
                        .popover(isPresented: $pickCalendars, arrowEdge: .bottom) { CalendarPicker() }
                }
            }
            if rows.isEmpty {
                Text(L("home.later.empty")).font(PN.Font.body).foregroundStyle(PN.C.text3)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                        if i > 0 { Divider() }
                        laterRow(r)
                    }
                }
                .padding(.horizontal, 6)
                .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.m))
            }
        }
    }

    private func laterRow(_ r: Ahead) -> some View {
        let m = r.model
        let st = m.map { upnext.prepState($0) } ?? .none
        let f = DateFormatter(); f.dateFormat = Calendar.current.isDateInToday(r.start) ? "HH:mm" : "EEE HH:mm"
        f.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US")
        let inProgress = r.event?.relative(now) == "in progress"
        let people = (r.event?.attendees ?? m?.participants ?? []).prefix(3).joined(separator: ", ")
        let sub = [m.map { $0.target.isEmpty ? "" : $0.targetName } ?? "", people].filter { !$0.isEmpty }.joined(separator: " · ")
        return HStack(alignment: .center, spacing: 12) {
            Text(f.string(from: r.start)).font(PN.Font.body.monospacedDigit()).foregroundStyle(PN.C.text3).frame(width: 74, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title).font(PN.Font.body.weight(.medium)).foregroundStyle(PN.C.text).lineLimit(1)
                if !sub.isEmpty { Text(sub).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(1) }
            }
            Spacer(minLength: 8)
            // 2026-10-29 (owner): the badges and their actions in two fixed columns, so they line up row to row.
            Group {
                if inProgress {
                    statusCell(PNBadge(text: L("home.live"), kind: .live)) { Button(live ? L("home.switch") : L("home.startTips.short")) { start(r) }.buttonStyle(.pnTertiary) }
                } else {
                    switch st {
                    case .ready:
                        if let m = m, let fr = Freshness.check(m), fr.stale {
                            statusCell(PNBadge(text: fr.badge, kind: .stale).help(fr.line)) { Button(L("fresh.refresh")) { refresh(r) }.buttonStyle(.pnTertiary) }
                        } else {
                            statusCell(PNBadge(text: L("badge.ready"), kind: .ready)) {
                                if let m = m, let p = PrepDocWindow.path(for: m) { Button(L("common.open")) { PrepDocWindow.show(path: p, title: m.effectiveTitle) }.buttonStyle(.pnTertiary) }
                            }
                        }
                    case .running: statusCell(PNBadge(text: L("badge.preparing"), kind: .stale)) { EmptyView() }
                    case .queued: statusCell(PNBadge(text: L("badge.queued"), kind: .stale)) { EmptyView() }
                    case .failed: statusCell(PNBadge(text: L("badge.failed"), kind: .live)) { Button(L("menubar.prepare")) { prepare(r) }.buttonStyle(.pnTertiary) }
                    case .none: statusCell(PNBadge(text: L("badge.notPrepared"), kind: .notPrepared)) { Button(L("menubar.prepare")) { prepare(r) }.buttonStyle(.pnTertiary) }
                    }
                }
            }
            Menu {
                Button(L("home.setUp")) { StartCallWindow.show(delegate: app, prepared: model(for: r)) }
                Button(live ? L("home.switch") : L("home.startNow")) { start(r) }
                if st == .queued, let m = m { Button(L("common.cancel")) { upnext.unqueue(m) } }
                if st == .running { Button(L("common.cancel")) { runner.cancel() } }
                Divider()
                if r.event != nil { Button(L("home.showInCalendar")) { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app")) } }
                Button(r.event != nil ? L("home.hide") : L("home.removeUpNext")) { dismiss(r) }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(L("home.more"))
        }
        .padding(.horizontal, 8).padding(.vertical, 9)
        .contentShape(Rectangle())
        .contextMenu {
            Button(L("home.setUp")) { StartCallWindow.show(delegate: app, prepared: model(for: r)) }
            Button(r.event != nil ? L("home.hide") : L("home.removeUpNext")) { dismiss(r) }
        }
    }

    /// A badge right-aligned in its column and its action left-aligned in the next one (Later rows line up).
    private func statusCell<B: View, A: View>(_ badge: B, @ViewBuilder action: () -> A) -> some View {
        HStack(spacing: 8) {
            badge.frame(width: 120, alignment: .trailing)
            action().frame(width: 72, alignment: .leading)
        }
    }

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
        guard !m.target.isEmpty else { StartCallWindow.show(delegate: app, prepared: m); return }
        if live {
            upnext.save(m)
            app.confirmSwitch(to: m, on: HomeWindow.window)
        } else if let e = app.launch(m) {
            note = e
        }
    }

    private func dismiss(_ r: Ahead) {
        if let m = r.model { upnext.remove(m) }
        if let e = r.event { cal.hidden.insert(e.id) }
    }

    // MARK: right column: On you, This week, Recent (REDESIGN-SPEC 4.4)

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            onYouSection
            if showStats { weekSection }
            recentSection
        }
    }

    /// REDESIGN-SPEC 4.4 + idea 01: the PM's open commitments from every call, overdue first. The tick closes the item
    /// in the register; the context menu copies it, opens the call or drops what is not a commitment.
    /// 0.8.6 (D3, rules/notion-tasks.yaml > on_you): one list with the PM's Notion tasks, a source badge, a project filter.
    private enum OnYouRow: Identifiable {
        case commit(Commitment), task(NotionTask, Commitment?)
        var id: String { switch self { case .commit(let c): return c.id; case .task(let t, _): return t.id } }
        var due: String { switch self { case .commit(let c): return c.due; case .task(let t, let c): return t.due.isEmpty ? (c?.due ?? "") : t.due } }
        var created: Date? { switch self { case .commit(let c): return c.createdDate; case .task(let t, let c): return c?.createdDate ?? CommitmentRegister.iso(t.created) } }
    }

    private func onYouRows() -> [OnYouRow] {
        let hidden = Set(onYouHidden.split(separator: ",").map(String.init))
        let target: String? = onYouFilter.isEmpty ? nil : onYouFilter
        let tasks = ntasks.tasks(for: target)
        let taskIds = Set(tasks.map { $0.id })
        let reg = ProjectRegistry.load(from: AppPaths.projects)
        let inScope: (Commitment) -> Bool = { c in
            guard let t = target else { return true }
            if t.hasPrefix("workspace:") {
                let w = String(t.dropFirst(10))
                return c.project == w || reg.projects.first { $0.slug == c.project }?.workspace == w
            }
            return c.project == t
        }
        var rows: [OnYouRow] = register.open(mine: true).filter { inScope($0) && !($0.notionPage.isEmpty == false && taskIds.contains($0.notionPage)) }.map { .commit($0) }
        rows += tasks.map { t in .task(t, ntasks.linkedCommitment(t)) }
        rows = rows.filter { !hidden.contains($0.id) }
        let now = Date()
        func due(_ r: OnYouRow) -> Date? { CommitmentRegister.dueDate(r.due, from: r.created ?? now) }
        return rows.sorted { a, b in
            let da = due(a), db = due(b)
            let oa = (da.map { $0 < Calendar.current.startOfDay(for: now) } ?? false), ob = (db.map { $0 < Calendar.current.startOfDay(for: now) } ?? false)
            if oa != ob { return oa }
            if (da != nil) != (db != nil) { return da != nil }
            if let x = da, let y = db, x != y { return x < y }
            return (a.created ?? .distantPast) > (b.created ?? .distantPast)
        }
    }

    private func hideHere(_ id: String) { onYouHidden = (onYouHidden.isEmpty ? "" : onYouHidden + ",") + id }

    private var onYouFilterMenu: some View {
        let reg = ProjectRegistry.load(from: AppPaths.projects)
        let label = onYouFilter.isEmpty ? L("ntask.allProjects")
            : onYouFilter.hasPrefix("workspace:") ? String(onYouFilter.dropFirst(10)) : (reg.projects.first { $0.slug == onYouFilter }?.name ?? onYouFilter)
        return Picker(L("home.filter.project"), selection: Binding(get: { onYouFilter }, set: { onYouFilter = $0 })) {   // 0.8.7 (J4)
            Text(L("ntask.allProjects")).tag("")
            ForEach(reg.projects.filter { $0.status != "archived" }, id: \.slug) { p in Text(p.name).tag(p.slug) }
            ForEach(reg.workspaces, id: \.name) { w in Text(w.name).tag("workspace:" + w.name) }
        }
        .pickerStyle(.menu).fixedSize().font(PN.Font.caption).help(label)
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .bold)).foregroundStyle(PN.C.text2)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(PN.C.surface2, in: RoundedRectangle(cornerRadius: 4))
    }

    private var onYouSection: some View {
        let items = onYouRows()
        let df = DateFormatter(); df.dateFormat = "d MMM"
        df.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US")
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("home.onYou")).font(PN.Font.section).foregroundStyle(PN.C.text)
                if !items.isEmpty { Text("\(items.count)").font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.onMe) }
                Spacer()
                onYouFilterMenu
            }
            if !ntasks.mapNotice.isEmpty {
                HStack {
                    Text(L("ntask.mapNotice", ["project": ntasks.mapNotice])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    Spacer()
                    Button(L("ntask.mapSet")) { ntasks.mapNotice = ""; SettingsWindow.show(tab: "notion") }.buttonStyle(.pnTertiary)
                    Button { ntasks.mapNotice = "" } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(PN.C.text3)
                }
            }
            if let t = ntasks.toast {
                HStack(spacing: 8) {
                    Text(t.text).font(PN.Font.caption).foregroundStyle(t.isError ? PN.C.danger : PN.C.text2)
                    Spacer()
                    if let u = t.undo { Button(L("ntask.undo")) { u(); ntasks.toast = nil }.buttonStyle(.pnTertiary) }
                    if !t.openURL.isEmpty, let url = URL(string: t.openURL) { Button(L("ntask.open")) { NSWorkspace.shared.open(url) }.buttonStyle(.pnTertiary) }
                }
                .task(id: t.id) { try? await Task.sleep(nanoseconds: 8_000_000_000); if ntasks.toast?.id == t.id { ntasks.toast = nil } }
            }
            if items.isEmpty {
                Text(L("home.onYou.empty")).font(PN.Font.body).foregroundStyle(PN.C.text3)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(onYouAll ? items : Array(items.prefix(8))) { r in onYouRow(r, df) }
                    // 0.8.6 (owner): the whole list opens in place (the column scrolls), never a scroll inside the card
                    if items.count > 8 {
                        Button(onYouAll ? L("ntask.showLess") : L("ntask.showAll", ["n": "\(items.count)"])) { onYouAll.toggle() }
                            .buttonStyle(.pnTertiary).padding(.top, 4)
                    }
                }
                .id("\(register.version)-\(ntasks.version)")
            }
            if !ntasks.error.isEmpty { Text(ntasks.error).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(1) }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.m))
    }

    @ViewBuilder private func onYouRow(_ r: OnYouRow, _ df: DateFormatter) -> some View {
        switch r {
        case .commit(let c):
            let overdue = CommitmentRegister.isOverdue(c)
            let when = c.createdDate.map { df.string(from: $0) } ?? ""
            // 0.8.7 (J4): the project once (not when the text names it), only the due date red
            let pn = register.projectName(c)
            let sub = [c.text.lowercased().contains(pn.lowercased()) ? "" : pn, when.isEmpty ? "" : L("reg.promised", ["date": when]),
                       c.notionNote == "removed" ? L("ntask.pageRemoved") : ""]
                .filter { !$0.isEmpty }.joined(separator: " · ")
            let dueS = c.due.isEmpty ? "" : (overdue ? L("reg.overdue", ["due": Register.dueText(c.due)]) : L("reg.due", ["due": Register.dueText(c.due)]))
            HStack(alignment: .top, spacing: 8) {
                Toggle("", isOn: Binding(get: { false }, set: { _ in register.mark(c) }))
                    .toggleStyle(.checkbox).labelsHidden()
                    .accessibilityLabel(L("reg.markDoneA11y", ["text": c.text]))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        badge(L("ntask.badgeCall"))
                        Text(c.text).font(PN.Font.body).foregroundStyle(PN.C.text).fixedSize(horizontal: false, vertical: true)
                    }
                    (Text(sub).foregroundColor(PN.C.text3) + Text((sub.isEmpty || dueS.isEmpty ? "" : " · ") + dueS).foregroundColor(overdue ? PN.C.danger : PN.C.text3))
                        .font(PN.Font.caption)
                }
                Spacer(minLength: 0)
                RemoveButton { register.mark(c, "drop") }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if let f = register.transcript(c) { NSWorkspace.shared.open(URL(fileURLWithPath: f)) } }
            .help(L("home.onYou.help"))
            .contextMenu {
                Button(L("reg.copy")) { register.copyText(c) }
                if let f = register.transcript(c) { Button(L("reg.openCall")) { NSWorkspace.shared.open(URL(fileURLWithPath: f)) } }
                if ntasks.settings.ready && c.notionPage.isEmpty { Button(L("ntask.addToNotion")) { Task { await ntasks.add(c) } } }
                Divider()
                Button(L("ntask.hideHere")) { hideHere(c.id) }
                Button(L("ntask.remove")) { register.mark(c, "drop") }
            }
        case .task(let t, let c):
            let dueD = CommitmentRegister.dueDate(t.due, from: Date())
            let overdue = dueD.map { $0 < Calendar.current.startOfDay(for: Date()) } ?? false
            let tpn = ntasks.projectName(t)
            let sub = [t.title.lowercased().contains(tpn.lowercased()) ? "" : tpn, t.status,
                       c != nil ? L("ntask.fromACall") : ""].filter { !$0.isEmpty }.joined(separator: " · ")
            let dueS = t.due.isEmpty ? "" : (overdue ? L("reg.overdue", ["due": Register.dueText(t.due)]) : L("reg.due", ["due": Register.dueText(t.due)]))
            HStack(alignment: .top, spacing: 8) {
                Toggle("", isOn: Binding(get: { false }, set: { _ in ntasks.tick(t) }))
                    .toggleStyle(.checkbox).labelsHidden()
                    .accessibilityLabel(L("reg.markDoneA11y", ["text": t.title]))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        badge(L("ntask.badgeNotion"))
                        Text(t.title).font(PN.Font.body).foregroundStyle(PN.C.text).fixedSize(horizontal: false, vertical: true)
                    }
                    (Text(sub).foregroundColor(PN.C.text3) + Text((sub.isEmpty || dueS.isEmpty ? "" : " · ") + dueS).foregroundColor(overdue ? PN.C.danger : PN.C.text3))
                        .font(PN.Font.caption)
                }
                Spacer(minLength: 0)
                RemoveButton { confirmRemove(t, c) }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if let u = URL(string: t.url) { NSWorkspace.shared.open(u) } }
            .contextMenu {
                Button(L("reg.copy")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t.title, forType: .string) }
                if let u = URL(string: t.url) { Button(L("ntask.openNotion")) { NSWorkspace.shared.open(u) } }
                if let c = c, let f = register.transcript(c) { Button(L("reg.openCall")) { NSWorkspace.shared.open(URL(fileURLWithPath: f)) } }
                Divider()
                Button(L("ntask.hideHere")) { hideHere(t.id) }
                Button(L("ntask.remove")) { confirmRemove(t, c) }
            }
        }
    }

    /// rules/notion-tasks.yaml > remove: a task made by hand in Notion asks once; one from a call does not.
    private func confirmRemove(_ t: NotionTask, _ c: Commitment?) {
        if c == nil {
            let a = NSAlert()
            a.messageText = L("ntask.trashQ", ["title": t.title])
            a.informativeText = L("ntask.trashInfo")
            a.addButton(withTitle: L("ntask.moveToTrash"))
            a.addButton(withTitle: L("hk.cancel"))
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        ntasks.remove(pageId: t.id, title: t.title, commitment: c)
    }

    private var weekSection: some View {
        let cal0 = CallStats.calendar
        let ws = CallStats.weekStart(now)
        let recs = CallStats.calls(from: ws, to: now.addingTimeInterval(1))      // 0.8.7 (B1): the same numbers as Statistics
        let mins = recs.reduce(0) { $0 + ($1.minutes ?? 0) }
        let prepared = recs.filter { $0.prepared == true }.count
        // 0.8.7 (B3): Monday to Sunday; the weekend shows when it has calls or today is a weekend day
        let weekend = recs.contains { cal0.isDateInWeekend($0.start) } || cal0.isDateInWeekend(now)
        let days: [(String, Double)] = (0..<(weekend ? 7 : 5)).map { i in
            let d = cal0.date(byAdding: .day, value: i, to: ws) ?? ws
            let f = DateFormatter(); f.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US"); f.setLocalizedDateFormatFromTemplate("EEEEE")
            return (f.string(from: d), recs.filter { cal0.isDate($0.start, inSameDayAs: d) }.reduce(0) { $0 + ($1.minutes ?? 0) })
        }
        let top = max(30, days.map(\.1).max() ?? 0)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("home.week")).font(PN.Font.section).foregroundStyle(PN.C.text)
                Spacer()
                Button(L("home.week.details")) { InsightsWindow.show() }.buttonStyle(.pnTertiary)
            }
            HStack(alignment: .top, spacing: 12) {
                number("\(recs.count)", L("home.week.calls"))
                number(Self.hm(mins), L("home.week.onCalls"))
                number(L("home.week.preparedOf", ["x": "\(prepared)", "y": "\(recs.count)"]), L("home.week.prepared"))
            }
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, d in
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3).fill(d.1 > 0 ? PN.C.brand : PN.C.surface2)
                            .frame(height: max(4, CGFloat(d.1 / top) * 44))
                        Text(d.0).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement().accessibilityLabel(d.0 + " " + Self.hm(d.1))
                }
            }
            .frame(height: 64, alignment: .bottom)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.m))
        .onAppear { history.fillDetails() }
    }

    private func number(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 17, weight: .semibold)).monospacedDigit().foregroundStyle(PN.C.text).lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recentSection: some View {
        let rs = Array(history.visible.prefix(5))
        let f = DateFormatter(); f.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US"); f.setLocalizedDateFormatFromTemplate("dMMMHHmm")
        return VStack(alignment: .leading, spacing: 8) {
            Text(L("home.recent")).font(PN.Font.section).foregroundStyle(PN.C.text)
            if rs.isEmpty {
                Text(L("home.recent.empty")).font(PN.Font.body).foregroundStyle(PN.C.text3)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rs.enumerated()), id: \.element.id) { i, r in
                        if i > 0 { Divider() }
                        RecentRow(r: r, when: f.string(from: r.start), outcome: OutcomeCache.shared.outcome(r.file)?.line ?? "") { history.hide(r) }
                    }
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.m))
    }

    // MARK: status line (red only when something is wrong; spend only as a warning near the limit)

    private var statusBar: some View {
        let cfg = AppConfig.load(from: AppPaths.config)
        let demo = ProcessInfo.processInfo.environment["LT_SUPPORT_DIR"] != nil      // shot mode: no real key or mirror
        let store = SecretStore(service: Bundle.main.bundleIdentifier ?? "io.github.example.livetips")
        let hasKey = demo || !(store.get(.claudeAPIKey) ?? "").isEmpty || PrepRunner.claudePath != nil   // 0.8.2: either way to Claude
        let mirror = demo ? "ok" : (cfg.workRoot.isEmpty ? "" : MirrorStatus.load(workRoot: cfg.workRoot).health())
        let calCount = demo ? 3 : cal.calendars.filter { !cal.excluded.contains($0.calendarIdentifier) }.count
        let month = demo ? 4.20 : SpendLedger.monthSpent()
        let nearLimit = month >= cfg.budget.monthlyHardUSD * 0.9
        return HStack(spacing: 18) {
            dot(hasKey, hasKey ? L("home.status.claude") : L("home.status.noClaude")) { SettingsWindow.show(tab: "ai") }
            if !mirror.isEmpty { dot(mirror == "ok", mirror == "ok" ? L("home.status.notion") : L("home.status.notionStale")) { SettingsWindow.show(tab: "notion") } }
            dot(cal.access == .granted, cal.access == .granted ? L("home.status.calendars", ["n": "\(calCount)"]) : L("home.status.noCalendars")) { SettingsWindow.show(tab: "calendars") }
            if nearLimit {
                Button { SettingsWindow.show(tab: "ai") } label: { Label(L("home.status.limit"), systemImage: "exclamationmark.triangle").foregroundStyle(PN.C.onMe) }
                    .buttonStyle(.plain)
            }
            Spacer()
        }
        .font(PN.Font.caption)
    }

    private func dot(_ ok: Bool, _ text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(ok ? PN.C.turn : PN.C.danger).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(text).foregroundStyle(ok ? PN.C.text3 : PN.C.danger)
            }
        }
        .buttonStyle(.plain)
    }
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
