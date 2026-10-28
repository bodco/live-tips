import AppKit
import SwiftUI
import LiveTipsCore

/// 2026-10-27 (owner): Home, the app's main window. What is live now, the calls ahead (calendar and Up next,
/// with their preparation, overlaps shown so the PM picks the one he goes to), the calls already held (Notion,
/// transcript, folder) and the state of everything a call needs (Claude, spend, Notion mirror, local AI, calendars).
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
        w.title = L("home.window.title")
        w.styleMask.insert(.resizable)
        w.setContentSize(NSSize(width: 780, height: 760))
        w.isReleasedWhenClosed = false
        _ = w.setFrameAutosaveName("LiveTipsHome")
        window = w
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct HomeView: View {
    let app: AppDelegate
    @ObservedObject var cal = CalendarService.shared
    @ObservedObject var upnext = UpNext.shared
    @ObservedObject var history = CallHistory.shared
    @ObservedObject var runner = PrepRunner.shared
    @State private var now = Date()
    @State private var status = EngineStatus()
    @State private var note = ""
    @State private var pickCalendars = false
    @State private var prepSheet: StartCallModel?
    /// 2026-10-27 (owner): Settings > General: the week's numbers, the chart and the spend can be hidden (a demo to colleagues).
    @AppStorage("homeShowStats") private var showStats = true
    @State private var showAllRecent = false

    private var live: Bool { CallEngine.shared.isRunning || ["recording", "standby", "loading_model"].contains(status.state) }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 28).padding(.top, 18).padding(.bottom, 14)
            Divider()
            // 2026-10-27 (owner): a wide window puts the week next to the calls; a narrow one stacks them.
            GeometryReader { geo in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if live { liveCard }
                        if !note.isEmpty { Text(note).font(.callout).foregroundStyle(PN.C.onMe) }
                        if geo.size.width >= 1060 {
                            HStack(alignment: .top, spacing: 18) {
                                VStack(alignment: .leading, spacing: 18) { aheadSection; recentSection }
                                    .frame(maxWidth: .infinity)
                                if showStats { WeekStats().frame(width: 400) }
                            }
                        } else {
                            // 2026-10-28 (owner): narrow: the insights on top, lower than in a wide window, then the calls.
                            if showStats { WeekStats(compact: true) }
                            aheadSection
                            recentSection
                        }
                    }
                    .padding(.horizontal, 28).padding(.vertical, 18)
                }
            }
            Divider()
            footer.padding(.horizontal, 28).padding(.vertical, 10)
        }
        .frame(minWidth: 640, minHeight: 560)
        .onAppear { tick(); cal.refresh(); history.scan(); upnext.pruneHeld(); upnext.adoptPreparedEvents() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in upnext.adoptPreparedEvents() }
        .sheet(item: $prepSheet) { m in
            PrepareSheet(model: m, onPrepare: {
                upnext.save(m)
                note = upnext.prepare(m) ?? ""
                prepSheet = nil
            }, onCancel: { prepSheet = nil }, onMore: {
                prepSheet = nil
                StartCallWindow.show(delegate: app, prepared: m)
            })
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in tick() }
    }

    private func tick() {
        now = Date()
        status = EngineStatus.load(path: CallEngine.shared.statusPath)
    }

    // MARK: header and status

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            PacenoteSymbol(height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("app.name")).font(.title2.weight(.semibold))
                Text(now.formatted(date: .complete, time: .omitted)).font(.callout).foregroundStyle(PN.C.text3)
            }
            Spacer()
            if !live {
                Button { StartCallWindow.show(delegate: app, planOnly: true) } label: { Label("Plan a call", systemImage: "calendar.badge.plus") }
                    .buttonStyle(.pnSecondary)
                    .help("Set up and prepare a call for later (Up next).")
            }
            LTPrimaryButton(title: live ? "Plan an upcoming call" : "Start call", symbol: live ? "calendar.badge.plus" : "phone.arrow.up.right", minWidth: 150) {
                StartCallWindow.show(delegate: app)
            }
            .keyboardShortcut("n", modifiers: .command)
        }
    }

    private var liveCard: some View {
        let title = CallEngine.shared.renamed ?? (CallEngine.shared.callRequest["title"] as? String) ?? status.project ?? "Call"
        let since = status.startedAt.flatMap { ISO8601DateFormatter().date(from: $0) }
        return HStack(spacing: 12) {
            Circle().fill(status.state == "recording" ? PN.C.rec : PN.C.text3).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text((status.state == "standby" ? "Waiting for the call: " : "Recording: ") + title).font(.headline).lineLimit(1)
                HStack(spacing: 8) {
                    if let s = since { Text(s, style: .timer).monospacedDigit() }
                    Text("\(status.lines) lines · \(status.tips) tips · $" + String(format: "%.2f", status.callSpentUSD))
                }
                .font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            Spacer()
            Button("Show tips") { app.showTips() }.buttonStyle(.pnTertiary)
            Button("End call") { app.endCall() }.buttonStyle(.pnTertiary)
        }
        .ltCard(padding: 14)
        .background(RoundedRectangle(cornerRadius: LT.radius).fill(PN.C.rec.opacity(0.06)))
    }

    // MARK: ahead: calendar and Up next

    /// One row per call ahead: a calendar event (with its Up next setup, if any) or an Up next call without an event.
    private struct Ahead: Identifiable {
        var id: String
        var event: CalendarService.CalEvent?
        var model: StartCallModel?
        var start: Date
    }

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

    private var aheadSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Ahead").font(.headline)
                Text("calendar and Up next").font(PN.Font.caption).foregroundStyle(PN.C.text3)
                Spacer()
                if cal.access == .granted {
                    Button("Calendars…") { pickCalendars = true }.buttonStyle(.pnTertiary)
                        .popover(isPresented: $pickCalendars, arrowEdge: .bottom) { CalendarPicker() }
                }
                if cal.access != .granted {
                    Button(cal.access == .denied ? "Allow calendars…" : "Connect calendars") { cal.connect() }.buttonStyle(.pnTertiary)
                }
            }
            let rows = ahead
            if rows.isEmpty {
                Text(cal.access == .granted ? "Nothing in the calendars for the next 36 hours, and Up next is empty." : "Connect your calendars to see the calls ahead, or plan a call with Plan a call.")
                    .font(.callout).foregroundStyle(PN.C.text3).ltCard(padding: 14)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                        if i > 0 { Divider() }
                        aheadRow(r, overlaps: r.event.map { e in rows.compactMap(\.event).filter { e.overlaps($0) } } ?? [])
                    }
                }
                .ltCard(padding: 6)
            }
        }
    }

    private func aheadRow(_ r: Ahead, overlaps: [CalendarService.CalEvent]) -> some View {
        let m = r.model
        let st = m.map { upnext.prepState($0) } ?? .none
        let f = DateFormatter(); f.dateFormat = Calendar.current.isDateInToday(r.start) ? "HH:mm" : "EEE HH:mm"
        let rel = r.event?.relative(now) ?? ""
        return HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(r.event.map { Color(nsColor: $0.color) } ?? Color.accentColor).frame(width: 4, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(r.event.map { (Calendar.current.isDateInToday($0.start) ? "" : dayName($0.start) + " ") + $0.timeRange } ?? f.string(from: r.start))
                        .font(.callout.monospacedDigit()).foregroundStyle(PN.C.text3)
                    if !rel.isEmpty {
                        Text(rel).font(PN.Font.caption.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill((rel == "in progress" ? PN.C.rec : Color.accentColor).opacity(0.15)))
                    }
                    if r.event?.recurring == true { Image(systemName: "repeat").font(PN.Font.caption).foregroundStyle(PN.C.text3).help("A regular meeting: set up like the last one") }
                }
                Text(m?.effectiveTitle ?? r.event?.title ?? "").font(.body.weight(.medium)).lineLimit(1)
                HStack(spacing: 6) {
                    if let m = m, !m.target.isEmpty { Text(m.targetName) }
                    if let e = r.event { Text(e.account + " · " + e.calendar).foregroundStyle(PN.C.text3) } else { Text("Up next").foregroundStyle(PN.C.text3) }
                    prepBadge(st)
                }
                .font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(1)
                if !overlaps.isEmpty {
                    Label(overlaps.count == 1 ? "Same time as \u{201C}\(overlaps[0].title)\u{201D}" : "Same time as \(overlaps.count) other calls", systemImage: "rectangle.on.rectangle")
                        .font(PN.Font.caption).foregroundStyle(PN.C.onMe).lineLimit(1)
                        .help("At the same time: " + overlaps.map(\.title).joined(separator: ", ") + ". Prepare and start the one you actually go to; hide the others with ×.")
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                if st == .none || st == .failed {
                    Button("Prepare") { prepare(r) }.buttonStyle(.pnTertiary)
                        .help("Set up this call like the last one of its series and write its preparation now. It does not start the call.")
                }
                if st == .ready, let m = m, let p = PrepDocWindow.path(for: m) {
                    Button("Read prep") { PrepDocWindow.show(path: p, title: m.effectiveTitle) }.buttonStyle(.pnTertiary)
                        .help("Read or correct the preparation before the call")
                }
                Button("Set up…") { StartCallWindow.show(delegate: app, prepared: model(for: r)) }.buttonStyle(.pnTertiary)
                Button(live ? "Switch…" : "Start") { start(r) }.buttonStyle(.pnTertiary)
                    .help(live ? "End the current call and start this one (asks first)." : "Start this call now.")
                Button { dismiss(r) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("Hide").foregroundStyle(PN.C.text3)
                    .help(r.event != nil ? "Hide this event here (the calendar is not changed)." : "Remove from Up next")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
    }

    private func dayName(_ d: Date) -> String {
        if Calendar.current.isDateInTomorrow(d) { return "Tomorrow" }
        let f = DateFormatter(); f.dateFormat = "EEE"; return f.string(from: d)
    }

    @ViewBuilder private func prepBadge(_ st: UpNext.PrepState) -> some View {
        switch st {
        case .ready: Label("prepared", systemImage: "checkmark.seal.fill").foregroundStyle(PN.C.turn)
        case .running: Label("preparing \(Int(runner.progress * 100))%", systemImage: "hourglass").foregroundStyle(Color.accentColor)
        case .queued: Label("in line", systemImage: "clock")
        case .failed: Label("preparation failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(PN.C.onMe)
        case .none: EmptyView()
        }
    }

    /// The Up next call behind a row; for a calendar event one is made (set up like the last call of its series).
    private func model(for r: Ahead) -> StartCallModel {
        if let m = r.model { return m }
        let m = StartCallModel()
        if let e = r.event { m.applyEvent(e) }       // also adopts a preparation not used yet
        return m
    }

    /// Asks first: the project or workspace and what matters on this call (PrepareSheet).
    private func prepare(_ r: Ahead) {
        prepSheet = model(for: r)
    }

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

    // MARK: recent calls

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            let all = history.visible
            HStack {
                Text("Recent calls").font(.headline)
                Spacer()
                if all.count > 8 { Button(showAllRecent ? "Show fewer" : "Show all \(all.count)") { showAllRecent.toggle() }.buttonStyle(.pnTertiary) }
            }
            let rs = showAllRecent ? all : Array(all.prefix(8))
            if rs.isEmpty {
                Text("Calls you record appear here with their transcript and Notion page.").font(.callout).foregroundStyle(PN.C.text3).ltCard(padding: 14)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rs.enumerated()), id: \.element.id) { i, r in
                        if i > 0 { Divider() }
                        recentRow(r)
                    }
                }
                .ltCard(padding: 6)
            }
        }
    }

    private func recentRow(_ r: CallHistory.Record) -> some View {
        let f = DateFormatter(); f.dateFormat = Calendar.current.isDateInToday(r.start) ? "'Today' HH:mm" : "d MMM HH:mm"
        var meta = [r.project]
        if let l = r.lines, l > 0 { meta.append("\(l) lines") }
        if let c = r.costUSD, c > 0 { meta.append(String(format: "$%.2f", c)) }
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(f.string(from: r.start)).font(.callout.monospacedDigit()).foregroundStyle(PN.C.text3)
                    Text(r.title).font(.body.weight(.medium)).lineLimit(1)
                }
                Text(meta.filter { !$0.isEmpty }.joined(separator: " · ")).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let u = r.notionURL, let url = URL(string: u) {
                Button("Notion") { NSWorkspace.shared.open(url) }.buttonStyle(.pnTertiary)
            }
            Button("Transcript") { NSWorkspace.shared.open(URL(fileURLWithPath: r.file)) }.buttonStyle(.pnTertiary)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.file)]) }.buttonStyle(.pnTertiary)
            Button { history.hide(r) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("Hide").foregroundStyle(PN.C.text3)
                .help("Remove from this list. The files stay in the project folder.")
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
    }

    // MARK: footer: what a call needs

    private var footer: some View {
        let cfg = AppConfig.load(from: AppPaths.config)
        // Screenshot mode (demo data): no real spend, key or mirror state in the pictures.
        let demo = ProcessInfo.processInfo.environment["LT_SUPPORT_DIR"] != nil
        let month = demo ? 4.20 : SpendLedger.monthSpent()
        let store = SecretStore(service: Bundle.main.bundleIdentifier ?? "io.github.example.livetips")
        let hasKey = demo || !(store.get(.claudeAPIKey) ?? "").isEmpty
        let mirror = demo ? "ok" : (cfg.workRoot.isEmpty ? "" : MirrorStatus.load(workRoot: cfg.workRoot).health())
        let calCount = demo ? 3 : cal.calendars.filter { !cal.excluded.contains($0.calendarIdentifier) }.count
        return HStack(spacing: 14) {
            chip(hasKey ? "key.fill" : "key", hasKey ? "Claude API key set" : "No Claude API key", hasKey ? PN.C.text3 : PN.C.onMe) { SettingsWindow.show(tab: "keys") }
            if showStats { chip("dollarsign.circle", String(format: "Month $%.2f / $%.0f", month, cfg.budget.monthlyHardUSD), month >= cfg.budget.monthlyHardUSD * 0.9 ? .orange : .secondary) { SettingsWindow.show(tab: "ai") }
            Link("Balance in Anthropic Console", destination: URL(string: "https://console.anthropic.com/settings/billing")!).font(PN.Font.caption)
                .help("Anthropic does not let an API key read the balance; it is shown in the Console.") }
            if !mirror.isEmpty { chip("doc.text", mirror == "ok" ? "Notion mirror fresh" : "Notion mirror \(mirror)", mirror == "ok" ? PN.C.text3 : PN.C.onMe) { SettingsWindow.show(tab: "notion") } }
            chip("cpu", cfg.localAI.enabled ? "Local AI on" : "Local AI off", .secondary) { SettingsWindow.show(tab: "ai") }
            chip("calendar", cal.access == .granted ? "\(calCount) calendars" : "Calendars off", cal.access == .granted ? PN.C.text3 : PN.C.onMe) { SettingsWindow.show(tab: "calendars") }
            Spacer()
        }
        .font(PN.Font.caption)
    }

    private func chip(_ symbol: String, _ text: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(text, systemImage: symbol).foregroundStyle(color) }.buttonStyle(.borderless)
    }
}
