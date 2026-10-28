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
    static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: Localized { ScrollView { WeekStats().padding(20) }.frame(minWidth: 620, minHeight: 520) }))
            w.styleMask.insert(.resizable)
            w.isReleasedWhenClosed = false
            window = w
        }
        window?.title = L("home.week.detailsTitle")
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// One call ahead: a calendar event (with its Up next setup, if any) or an Up next call without an event.
private struct Ahead: Identifiable {
    var id: String
    var event: CalendarService.CalEvent?
    var model: StartCallModel?
    var start: Date
    var end: Date? { event?.end }
    var title: String { model?.effectiveTitle ?? event?.title ?? "" }
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
    @State private var doneTick = 0               // redraw On you after a tick
    /// 2026-10-27 (owner): Settings > General can hide the week's numbers (a demo to colleagues).
    @AppStorage("homeShowStats") private var showStats = true

    private var live: Bool { CallEngine.shared.isRunning || ["recording", "standby", "loading_model"].contains(status.state) }

    var body: some View {
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
        .onAppear { tick(); cal.refresh(); history.scan(); upnext.pruneHeld(); upnext.adoptPreparedEvents() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in upnext.adoptPreparedEvents() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in tick() }
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
            Button(L("home.planCall")) { StartCallWindow.show(delegate: app, planOnly: true) }
                .buttonStyle(.pnSecondary)
                .help(L("home.planCall.help"))
            if !live {
                Button(L("home.startCall")) { StartCallWindow.show(delegate: app) }
                    .buttonStyle(.pnPrimary).keyboardShortcut("n", modifiers: .command)
            }
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
            if !note.isEmpty { Text(note).font(PN.Font.body).foregroundStyle(PN.C.onMe) }
            // Up next: the call being recorded, or the nearest one; an event that began more than 5 minutes ago without
            // being recorded stays in Later (with its Live badge).
            let first = live ? nil : rows.first { $0.event == nil || $0.start > now.addingTimeInterval(-5 * 60) }
            if live { liveCard } else if let first = first { upNextCard(first, overlaps: overlaps(first, rows)) } else { emptyCard }
            laterSection(rows.filter { $0.id != first?.id })
        }
    }

    private func overlaps(_ r: Ahead, _ rows: [Ahead]) -> [CalendarService.CalEvent] {
        guard let e = r.event else { return [] }
        return rows.compactMap(\.event).filter { e.overlaps($0) }
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
            }
            HStack(spacing: 8) {
                Button(L("home.startTips")) { start(r) }.buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
                Button(L("home.editSetup")) { StartCallWindow.show(delegate: app, prepared: model(for: r)) }.buttonStyle(.pnSecondary)
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
        if let m = m, let p = PrepDocWindow.path(for: m) {
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
        if let last = lastOfSeries(r), let o = OutcomeCache.shared.outcome(last.file) {
            let closed = OnYou.done
            let open = o.onMe.filter { !closed.contains(last.file + "|" + $0.lowercased().trimmingCharacters(in: .whitespaces)) }
            if let first = open.first {
                out.append(Check(id: "onyou", ok: false, text: L("home.check.onYou", ["text": first]),
                                 sub: open.count > 1 ? L("home.check.more", ["n": "\(open.count - 1)"]) : ""))
            }
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
            if inProgress {
                PNBadge(text: L("home.live"), kind: .live)
                Button(live ? L("home.switch") : L("home.startTips.short")) { start(r) }.buttonStyle(.pnTertiary)
            } else {
                switch st {
                case .ready:
                    PNBadge(text: L("badge.ready"), kind: .ready)
                    if let m = m, let p = PrepDocWindow.path(for: m) { Button(L("common.open")) { PrepDocWindow.show(path: p, title: m.effectiveTitle) }.buttonStyle(.pnTertiary) }
                case .running: PNBadge(text: L("badge.preparing"), kind: .stale)
                case .queued: PNBadge(text: L("badge.queued"), kind: .stale)
                case .failed:
                    PNBadge(text: L("badge.failed"), kind: .live)
                    Button(L("menubar.prepare")) { prepare(r) }.buttonStyle(.pnTertiary)
                case .none:
                    PNBadge(text: L("badge.notPrepared"), kind: .notPrepared)
                    Button(L("menubar.prepare")) { prepare(r) }.buttonStyle(.pnTertiary)
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

    /// The Up next call behind a row; for a calendar event one is made (set up like the last call of its series).
    private func model(for r: Ahead) -> StartCallModel {
        if let m = r.model { return m }
        let m = StartCallModel()
        if let e = r.event { m.applyEvent(e) }       // also adopts a preparation not used yet
        return m
    }

    /// Asks first: the project or workspace and what matters on this call (PrepareSheet).
    private func prepare(_ r: Ahead) { prepSheet = model(for: r) }

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

    private var onYouSection: some View {
        let items = OnYou.items()
        let df = DateFormatter(); df.dateFormat = "d MMM"
        df.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US")
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("home.onYou")).font(PN.Font.section).foregroundStyle(PN.C.text)
                if !items.isEmpty { Text("\(items.count)").font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.onMe) }
                Spacer()
            }
            if items.isEmpty {
                Text(L("home.onYou.empty")).font(PN.Font.body).foregroundStyle(PN.C.text3)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(items.prefix(6)) { it in
                        HStack(alignment: .top, spacing: 8) {
                            Toggle("", isOn: Binding(get: { false }, set: { _ in var d = OnYou.done; d.insert(it.id); OnYou.done = d; doneTick += 1 }))
                                .toggleStyle(.checkbox).labelsHidden()
                                .accessibilityLabel(it.text)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(it.text).font(PN.Font.body).foregroundStyle(PN.C.text).fixedSize(horizontal: false, vertical: true)
                                Text(it.project + " · " + df.string(from: it.when)).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                            }
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { NSWorkspace.shared.open(URL(fileURLWithPath: it.file)) }
                        .help(L("home.onYou.help"))
                    }
                    if items.count > 6 { Text(L("home.check.more", ["n": "\(items.count - 6)"])).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
                }
                .id(doneTick)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.m))
    }

    private var weekSection: some View {
        let cal0 = Calendar.current
        let ws = cal0.dateInterval(of: .weekOfYear, for: now)?.start ?? cal0.startOfDay(for: now)
        let recs = history.records.filter { !$0.hidden && $0.start >= ws && $0.start <= now }
        let mins = recs.reduce(0) { $0 + ($1.minutes ?? 0) }
        let prepared = recs.filter { $0.prepared == true }.count
        let days: [(String, Double)] = (0..<5).map { i in
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
                        let outcome = OutcomeCache.shared.outcome(r.file)?.line ?? ""
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.title).font(PN.Font.body.weight(.medium)).foregroundStyle(PN.C.text).lineLimit(1)
                            Text([f.string(from: r.start), r.project].filter { !$0.isEmpty }.joined(separator: " · ")).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(1)
                            if !outcome.isEmpty { Text(outcome).font(PN.Font.caption).foregroundStyle(PN.C.text2).lineLimit(1) }
                        }
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { if let u = r.notionURL.flatMap({ URL(string: $0) }) { NSWorkspace.shared.open(u) } else { NSWorkspace.shared.open(URL(fileURLWithPath: r.file)) } }
                        .contextMenu {
                            if let u = r.notionURL.flatMap({ URL(string: $0) }) { Button(L("home.recent.notion")) { NSWorkspace.shared.open(u) } }
                            Button(L("home.recent.transcript")) { NSWorkspace.shared.open(URL(fileURLWithPath: r.file)) }
                            Button(L("home.recent.finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.file)]) }
                            Divider()
                            Button(L("home.recent.hide")) { history.hide(r) }
                        }
                        .help(r.notionURL != nil ? L("home.recent.help.notion") : L("home.recent.help.transcript"))
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
        let hasKey = demo || !(store.get(.claudeAPIKey) ?? "").isEmpty
        let mirror = demo ? "ok" : (cfg.workRoot.isEmpty ? "" : MirrorStatus.load(workRoot: cfg.workRoot).health())
        let calCount = demo ? 3 : cal.calendars.filter { !cal.excluded.contains($0.calendarIdentifier) }.count
        let month = demo ? 4.20 : SpendLedger.monthSpent()
        let nearLimit = month >= cfg.budget.monthlyHardUSD * 0.9
        return HStack(spacing: 18) {
            dot(hasKey, hasKey ? L("home.status.claude") : L("home.status.noClaude")) { SettingsWindow.show(tab: "keys") }
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
