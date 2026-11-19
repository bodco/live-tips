import AppKit
import LiveTipsCore
import SwiftUI

/// 0.9.0 (redesign phase 2): the page of an upcoming call, pushed into Home. The same frame as the past call page:
/// meta line, name, "Project · with ...", tabs (Setup, Brief, Tasks, Earlier calls) and the actions on the right.
/// Opened from the call name on Home and on Coming up; any upcoming call can be started from here.
@MainActor
enum UpcomingPages {
    static var models: [String: StartCallModel] = [:]

    static func open(_ m: StartCallModel) {
        models[m.id.uuidString] = m
        HomeNav.shared.open(.upcoming(m.id.uuidString))
    }
}

/// What the Setup tab can change, to tell saved from unsaved and to undo Cancel.
private struct SetupSnap: Equatable {
    var target, title, audience, callType, language, context, hiringRole, tipModel, salesMethod: String
    var folders: [String]
    var useProjectFolder, publicCall, salesEnabled: Bool
    var callDate: Date

    @MainActor init(_ m: StartCallModel) {
        target = m.target; title = m.title; audience = m.audience; callType = m.callType; language = m.language
        context = m.context; hiringRole = m.hiringRole; tipModel = m.tipModel; salesMethod = m.salesMethod
        folders = m.folders; useProjectFolder = m.useProjectFolder; publicCall = m.publicCall
        salesEnabled = m.salesEnabled; callDate = m.callDate
    }

    @MainActor func restore(_ m: StartCallModel) {
        m.target = target; m.title = title; m.audience = audience; m.callType = callType; m.language = language
        m.context = context; m.hiringRole = hiringRole; m.tipModel = tipModel; m.salesMethod = salesMethod
        m.folders = folders; m.useProjectFolder = useProjectFolder; m.publicCall = publicCall
        m.salesEnabled = salesEnabled; m.callDate = callDate
    }
}

struct UpcomingCallPage: View {
    @ObservedObject var model: StartCallModel
    @ObservedObject var upnext = UpNext.shared
    @ObservedObject var runner = PrepRunner.shared
    @ObservedObject var register = Register.shared
    @ObservedObject var history = CallHistory.shared
    @AppStorage("moduleTracker") private var trackerOn = true
    @ObservedObject var jobs = SheetJobs.shared
    @State private var tab = UpcomingCallPage.shotTab ?? "setup"
    /// Shot mode only: the tab the page opens on.
    static var shotTab: String? = nil
    /// 0.10.0 (Meeting Sheet, phase 5): the tab a page opens on once (the reminder opens Readiness, a build the sheet).
    static var openTab: [String: String] = [:]
    @State private var doc: SheetDoc?
    @State private var exporting = false
    @State private var compareN: Int?
    @State private var snap: SetupSnap?
    @State private var note = ""
    @State private var confirmAgain = false
    @State private var newTask = ""
    @State private var width: CGFloat = 1000      // 2026-11-05 (redesign): side by side on a wide window
    @Environment(\.pnTheme) private var t

    private var wide: Bool { width >= 860 }

    private var app: AppDelegate? { NSApp.delegate as? AppDelegate }
    private var dirty: Bool { snap.map { $0 != SetupSnap(model) } ?? false }
    private var briefPath: String? { PrepDocWindow.path(for: model) }

    var body: some View {
        Group {
        // 0.25 (R2, boards UP, UT): the bar with when it starts and the actions, the title with the big status, the tabs
        VStack(spacing: 0) {
            PageBackBar(crumb: crumb) { barRight }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    head
                    PageTabBar(tabs: tabs, selection: $tab, counts: ["tasks": series.count, "earlier": earlier.count,
                        "readiness": doc?.sheet?.readinessBadge.gaps ?? 0, "sources": doc?.sheet?.sources.count ?? 0,
                        "versions": doc.map { SheetFiles.versions(of: $0.path).count + 1 } ?? 0],
                               badges: doc == nil && jobs.job(for: model.id) == nil ? ["sheet": L("page.sheet.notBuilt")] : [:],
                               warn: doc == nil ? ["sheet"] : [])
                    Group {
                        switch tab {
                        case "sheet", "brief": sheetTab
                        case "readiness": sheetOr { SheetReadinessTab(doc: $0, onAddSource: { getReady(.expert, step: 3) }, onStart: { start() }) }
                        case "sources": sheetOr { SheetSourcesTab(doc: $0, onAddSource: { getReady(.expert, step: 3) }, root: model.root) }    // 0.10.0 (Meeting Sheet, polish): root for Confirm in Google
                        case "versions": sheetOr { SheetVersionsTab(doc: $0, initialOpen: compareN) }
                        case "tasks": tasksTab
                        case "earlier": earlierTab
                        default: setupTab
                        }
                    }
                    .padding(.horizontal, PageMetrics.side).padding(.top, 28).padding(.bottom, 36)
                }
                .environment(\.pageFlat, true)
                .environment(\.pageWide, width >= 900)
                .background(GeometryReader { g in
                    Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w }
                })
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pnShotTab)) { n in if let s = n.object as? String { tab = s } }
        .textSelection(.enabled)      // 2026-11-10 (owner): the call's title and every text on the page can be selected and copied
        .background(PN.C.bg)
        .onAppear {
            if snap == nil { snap = SetupSnap(model) }; model.scanPrep(); syncDoc()
            if let t = Self.openTab.removeValue(forKey: model.id.uuidString) { tab = t }
        }
        .onReceive(jobs.objectWillChange) { DispatchQueue.main.async { syncDoc() } }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in syncDoc() }
        .sheet(isPresented: $exporting) { if let d = doc { SheetExportView(doc: d, done: { exporting = false }) } }
        .onDisappear { askToSave() }
        .confirmationDialog(L("sheet.ui.refresh.title"), isPresented: $confirmAgain) {
            Button(L("sheet.ui.refresh")) { refresh() }
            Button(L("common.cancel"), role: .cancel) {}
        } message: { Text(L("sheet.ui.refresh.body")) }
    }
        .trackScreen("upcoming_page", sub: tab, o: AnalyticsTracker.orgFor(project: model.project))
    }

    /// "Upcoming call · weekly series" (board UP).
    private var crumb: String {
        guard let e = model.calEventID.flatMap({ CalendarService.shared.event($0) }), e.recurring else {
            return earlier.isEmpty ? L("page.crumb.upcoming") : L("page.crumb.upcomingSeries", ["cadence": L("page.cadence.repeating")])
        }
        return L("page.crumb.upcomingSeries", ["cadence": L("page.cadence.weekly")])
    }

    /// "Starts in 37 min" on the highlight plate, then the actions (board UP header).
    private var barRight: some View {
        HStack(spacing: 10) {
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                let m = Int((model.callDate.timeIntervalSince(ctx.date) / 60).rounded(.up))
                if m > 0 && m < 12 * 60 {
                    HomePlate(text: t.cased(m < 60 ? L("page.startsIn.min", ["n": "\(m)"]) : L("page.startsIn.hm", ["h": "\(m / 60)", "m": "\(m % 60)"])),
                              font: t.homeMono(12, .semibold))
                } else if m <= 0 && m > -120 {
                    HomePlate(text: t.cased(L("page.started", ["n": "\(-m)"])), font: t.homeMono(12, .semibold))
                }
            }
            primary
            more
        }
    }

    // MARK: head: meta, name, project and people, the actions

    private var tabs: [(String, String)] {
        // 2026-11-05 (redesign): the counts are badges, as on the past call page
        // 0.10.0 (Meeting Sheet, phase 5): Setup / Meeting Sheet / Readiness / Sources / Versions / Tasks / Earlier
        // 0.25 (R2, board UT): Readiness, Sources and Versions only once there is a sheet
        [("setup", L("page.tab.setup")), ("sheet", L("sheet.ui.tab.sheet"))]
            + (doc == nil ? [] : [("readiness", L("sheet.ui.tab.readiness")), ("sources", L("sheet.ui.tab.sources")), ("versions", L("sheet.ui.tab.versions"))])
            + [("tasks", L("page.tab.tasks")), ("earlier", L("page.tab.earlier"))]
    }

    private var state: CallState {
        switch upnext.prepState(model) {
        case .ready: return .ready
        case .running: return .preparing
        case .queued: return .queued
        case .failed: return .failed
        case .none: return HomeView.aiReadyNow() ? .notReady : .noBrief
        }
    }

    /// A white card the size of the header card (the setup form and the brief bring their own padding).
    private func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) { c() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: PageStyle.radius).fill(PN.C.surface))
            .clipShape(RoundedRectangle(cornerRadius: PageStyle.radius))
    }

    /// 0.25 (R2, board UP): the meta line (when, the project, the meeting app), the name, the big status.
    private var head: some View {
        let d = DateFormatter(); d.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US"); d.setLocalizedDateFormatFromTemplate("EEEdMMM")
        let tf = DateFormatter(); tf.locale = d.locale; tf.setLocalizedDateFormatFromTemplate("HHmm")
        let ev = model.calEventID.flatMap { CalendarService.shared.event($0) }
        let when = d.string(from: model.callDate) + " · " + tf.string(from: model.callDate) + (ev.map { "-" + tf.string(from: $0.end) } ?? "")
        let meta = [when, model.target.isEmpty ? "" : model.targetName].filter { !$0.isEmpty }.joined(separator: " · ")
        let people = HomeView.peopleLine(model.participants)
        let st = state
        let (kind, text, sub): (HomeTag, String, String) = {
            if doc != nil && st != .preparing {
                // 0.25 (QA): the tag follows the sheet's readiness (it said "Not ready" in the ready colour)
                guard let b = SheetCache.shared.badge(for: model) else { return (HomeTag.of(st), st.text, L("page.sub.sheetBuilt")) }
                let k: HomeTag = b.state == .almost ? .answer : b.state == .notReady ? .notReady : .ready
                return (k, SheetLabels.readiness(b).text, L("page.sub.sheetBuilt"))
            }
            switch st {
            case .preparing: return (.answer, st.text, L("home.check.preparing", ["p": "\(Int(runner.progress * 100))"]))
            case .queued: return (.answer, st.text, L("badge.queued"))
            case .noBrief: return (.notReady, st.text, L("home.recordsOnly"))
            case .ready: return (.ready, st.text, L("home.brief.ready"))
            default: return (HomeTag.of(st), st.text, L("page.sub.noSheet"))
            }
        }()
        return PageTitleBlock(meta: meta, title: model.effectiveTitle) {
            if !people.isEmpty { Text(L("home.card.with", ["people": people])).font(t.homeText(15)).foregroundStyle(PN.C.text2).lineLimit(2) }
            HomeTagView(kind: kind, text: text, big: true, sub: "· " + sub)
            if !note.isEmpty { Text(note).font(t.homeText(13)).foregroundStyle(PN.C.notreadyText).fixedSize(horizontal: false, vertical: true) }
        }
    }

    /// 0.10.0 (Meeting Sheet, phase 4): Get ready opens Quick or Expert by the default rules; Start without prep;
    /// once the sheet is built: Start call, Refresh, Export.
    /// 0.25 (R2, board UP): in the bar, the second choice bordered first, the main one filled after it.
    @ViewBuilder private var primary: some View {
        let live = app?.callIsLive ?? false
        if let j = jobs.job(for: model.id) {
            Text(L("sheet.ui.building", ["p": "\(Int(j.progress * 100))"])).font(t.homeMono(12, .semibold)).foregroundStyle(PN.C.text2)
            Button(L("call.stop")) { j.stop() }.buttonStyle(.pnBar)
            Button(L("home.startCall")) { start() }.buttonStyle(.pnPrimary)
        } else if doc != nil {
            Button(L("sheet.ui.refresh")) { confirmAgain = true }.buttonStyle(.pnBar)
            Button(live ? L("home.switch") : L("home.startCall")) { start() }.buttonStyle(.pnPrimary)
        } else if state == .preparing || state == .queued {
            Button(L("common.cancel")) { if state == .preparing { runner.cancel() } else { upnext.unqueue(model) } }.buttonStyle(.pnBar)
            Button(L("home.startCall")) { start() }.buttonStyle(.pnPrimary)
        } else if state == .ready {
            // 0.10.0 (Meeting Sheet, hardening): a call prepared in 0.9.7 (a brief, no sheet) starts with that brief:
            // Start call stays the main button, Get ready (build a sheet) is the second choice.
            Button(L("home.getReady")) { getReady(nil) }.buttonStyle(.pnBar)
            Button(live ? L("home.switch") : L("home.startCall")) { start() }.buttonStyle(.pnPrimary)
        } else {
            if !SheetRoutes.ready(SheetRoutes.preferred) && SheetRoutes.firstReady() == nil { HomeLink(L("home.connectClaude")) { SettingsWindow.show(tab: "ai") } }
            Button(L("sheet.ui.startWithout")) { start() }.buttonStyle(.pnBar)
            Button(L("home.getReady")) { getReady(nil) }.buttonStyle(.pnPrimary)
        }
    }

    private var more: some View {
        Menu {
            if upnext.contains(model) { Button(L("home.removeUpNext")) { upnext.remove(model); HomeNav.shared.back() } }
            if model.calEventID != nil { Button(L("home.showInCalendar")) { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app")) } }
            Button(L("sheet.ui.quickPrep")) { getReady(.quick) }
            Button(L("sheet.ui.expertPrep")) { getReady(.expert) }
            if doc != nil { Button(L("sheet.ui.export")) { exporting = true } }
            Button(L("call.copyCowork")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.prepPhrase, forType: .string) }
        } label: { Image(systemName: "ellipsis").foregroundStyle(PN.C.text2) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 32, height: 32).accessibilityLabel(L("home.more"))
    }

    private func link(_ t: String, run: @escaping () -> Void) -> some View {
        Button(action: run) { Text(t).font(PN.Font.body).foregroundStyle(PN.C.accent) }.buttonStyle(.plain)
    }

    private func start() {
        guard let app = app else { return }
        if dirty { save() }
        model.useDefaultTargetIfEmpty()
        if app.callIsLive { upnext.save(model); app.confirmSwitch(to: model, on: HomeWindow.window); return }
        if let e = app.launch(model) { note = e } else { HomeNav.shared.path = [] }
    }

    /// Get ready: the Quick or Expert window (by Settings > Meeting Sheet when mode is nil).
    private func getReady(_ mode: SheetMode?, step: Int = 1) {
        guard !model.target.isEmpty else { note = L("call.needProject"); tab = "setup"; return }
        if dirty { save() }
        upnext.save(model)
        note = ""
        SheetPrepWindow.show(model, mode: mode, step: step)
    }

    private func refresh() {
        guard let d = doc else { getReady(nil); return }
        SheetActions.refresh(doc: d, call: model)
    }

    /// The page follows the sheet file: built, refreshed, or another version chosen.
    private func syncDoc() {
        let p = SheetFiles.path(for: model)
        if p != doc?.path { doc = p.map { SheetDoc(path: $0) } } else { doc?.reload() }
    }

    @ViewBuilder private func sheetOr<C: View>(@ViewBuilder _ c: (SheetDoc) -> C) -> some View {
        if let d = doc { c(d).environment(\.pageFlat, false) } else { noSheet }
    }

    /// The Meeting Sheet tab: the sheet; for a call prepared before 0.10.0 its brief, read only; else Get ready.
    @ViewBuilder private var sheetTab: some View {
        if let d = doc {
            // Your talk and Rehearse stay with a presentation (the slides file is derived from the sheet)
            if model.callType == "presentation" {
                HStack(spacing: 8) {
                    if TalkWindow.available(base: d.base) {
                        Button(L("talk.open")) { TalkWindow.show(base: d.base, title: model.effectiveTitle, call: model) }.buttonStyle(.pnSecondary)
                        Button(L("rehearse.button")) { RehearsalWindow.show(base: d.base, title: model.effectiveTitle, call: model) }.buttonStyle(.pnSecondary)
                    } else {
                        Text(L("rehearse.needPrep")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    }
                }
            }
            MeetingSheetTab(doc: d, onRefresh: {}, onEditBlocks: { getReady(.expert, step: 2) }, onCompare: { compareN = $0; tab = "versions" })
                .environment(\.pageFlat, false)       // 0.25 (R2): the built sheet keeps its look (board MS, a later block)
        } else if briefPath != nil {
            VStack(alignment: .leading, spacing: 8) {
                Label(L("sheet.ui.legacy"), systemImage: "doc.text").font(PN.Font.caption).foregroundStyle(PN.C.text3)
                card { briefTab }
            }
        } else {
            noSheet
        }
    }

    /// 0.25 (R2, board UT row 1): no sheet yet: what Get ready builds, Quick prep and Expert prep side by side,
    /// and "No time? Start without prep".
    private var noSheet: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 10) {
                Text(t.cased(L("sheet.ui.none"))).font(t.homeDisplay(t.style == .classic ? 36 : 48, t.heroWeight)).tracking(t.dTrack * 48)
                    .foregroundStyle(PN.C.text).fixedSize(horizontal: false, vertical: true)
                Text(L("sheet.ui.none.body")).font(t.homeText(17)).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 760, alignment: .leading)
            if let j = jobs.job(for: model.id) {
                HStack(spacing: 10) {
                    PNSpinner(size: 18)
                    Text(L("sheet.ui.building", ["p": "\(Int(j.progress * 100))"])).font(t.homeText(16)).foregroundStyle(PN.C.text2)
                }
                SheetSwitchPrompt(callID: model.id)
            } else {
                PageColumns {
                    VStack(alignment: .leading, spacing: 0) {
                        PageSectionHead(title: L("sheet.ui.quickPrep")) { PageCount(text: L("page.quick.sub")) }
                        Text(L("page.quick.same")).font(t.homeText(16)).foregroundStyle(PN.C.text).fixedSize(horizontal: false, vertical: true).pageRow(10)
                        VStack(alignment: .leading, spacing: 6) {
                            (Text(L("page.q.special")) + Text("  " + L("page.q.specialSub")).foregroundColor(PN.C.text3)).font(t.homeText(15)).foregroundStyle(PN.C.text2)
                            TextField("", text: $model.context, prompt: Text(L("page.q.specialPh"))).labelsHidden().pageField(36)
                        }
                        .pageRow(12)
                        HStack(spacing: 14) {
                            Button(L("page.quick.build")) { getReady(.quick) }.buttonStyle(PNSolidButtonStyle(height: 40))
                            HomeLink(L("page.quick.sources")) { getReady(.expert, step: 3) }
                        }
                        .pageRow(14)
                    }
                } right: {
                    VStack(alignment: .leading, spacing: 0) {
                        PageSectionHead(title: L("page.expert.title")) { PageCount(text: L("page.expert.sub")) }
                        ForEach(Array(["page.expert.s1", "page.expert.s2", "page.expert.s3", "page.expert.s4", "page.expert.s5"].enumerated()), id: \.offset) { i, k in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(String(format: "%02d", i + 1)).font(t.homeMono(12, .semibold)).foregroundStyle(PN.C.text3).frame(width: 34, alignment: .leading)
                                (Text(L(k)).fontWeight(.semibold) + Text(" " + L(k + ".sub")).foregroundColor(PN.C.text3))
                                    .font(t.homeText(15)).foregroundStyle(PN.C.text).fixedSize(horizontal: false, vertical: true)
                            }
                            .pageRow(8)
                        }
                        Button(L("page.expert.open")) { getReady(.expert) }.buttonStyle(PNOutlineButtonStyle(height: 40)).pageRow(14)
                    }
                }
            }
            HStack(spacing: 0) {     // 0.25 (QA): no gap before the tail's colon
                Text(L("page.notime")).font(t.homeText(14)).foregroundStyle(PN.C.text3)
                HomeLink(L("sheet.ui.startWithout")) { start() }.padding(.leading, 4)
                Text(L("page.notime.tail")).font(t.homeText(14)).foregroundStyle(PN.C.text3)
            }
            .pageRow(14)
        }
    }

    private func save() {
        model.useDefaultTargetIfEmpty()
        upnext.save(model)
        snap = SetupSnap(model)
    }

    /// Leaving with unsaved Setup changes: ask, never drop them silently. 0.26.0 (block 3): a bar on top of the
    /// window instead of an alert. Save or Discard only; a question that goes away unanswered (replaced, its window
    /// closed) saves, so nothing the PM typed is lost.
    private func askToSave() {
        guard dirty, let s = snap else { return }
        let m = model, store = upnext
        let keep = { m.useDefaultTargetIfEmpty(); store.save(m) }
        // 0.26.0 (review 1): the window is closing (or gone): there is no place for the bar, just save.
        if AskCenter.windowClosing || HomeWindow.window?.isVisible != true { AppLog.app("ask: unsaved saved on close"); keep(); return }
        AskCenter.shared.ask(kind: "unsaved", origin: .window, title: L("page.unsaved.title", ["title": m.effectiveTitle]),
                             info: L("page.unsaved.body"),
                             choices: [Ask.Choice(id: "save", title: L("common.save"), role: .primary),
                                       Ask.Choice(id: "discard", title: L("page.unsaved.discard"), role: .danger)],
                             cancelled: keep) { id in
            if id == "save" { keep() } else { s.restore(m) }
        }
    }

    // MARK: tabs

    private var setupTab: some View {
        CallSetupView(model: model, mode: .page, onStart: { start() }, onCancel: { snap?.restore(model) }, onSave: { save() })
    }

    @ViewBuilder private var briefTab: some View {
        if let p = briefPath {
            VStack(alignment: .leading, spacing: 0) {
                if model.callType == "presentation" {
                    let base = String(p.dropLast(9))
                    HStack(spacing: 8) {
                        if TalkWindow.available(base: base) {
                            Button(L("talk.open")) { TalkWindow.show(base: base, title: model.effectiveTitle, call: model) }.buttonStyle(.pnSecondary)
                            Button(L("rehearse.button")) { RehearsalWindow.show(base: base, title: model.effectiveTitle, call: model) }.buttonStyle(.pnSecondary)
                        } else {
                            Text(L("rehearse.needPrep")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                        }
                    }
                    .padding(16)
                }
                PrepDocView(path: p, title: model.effectiveTitle, background: PN.C.surface).frame(minHeight: 520)   // 0.10.0 (Meeting Sheet, polish): white card like the other tabs
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                PageEmpty(icon: "doc.text", title: L("page.brief.none"), text: L("page.brief.none.body"))
                if state == .preparing || state == .queued {
                    Text(state == .preparing ? L("home.check.preparing", ["p": "\(Int(runner.progress * 100))"]) : L("badge.queued"))
                        .font(PN.Font.body).foregroundStyle(PN.C.text2)
                } else if HomeView.aiReadyNow() {
                    Button(L("page.brief.getReady")) { getReady(nil) }.buttonStyle(.pnPrimary)
                } else {
                    link(L("home.connectClaude")) { SettingsWindow.show(tab: "ai") }
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 22)
        }
    }

    /// Open items of this meeting series, only for its own project (never mixed across projects).
    private var series: [Commitment] {
        let key = EditLog.seriesKey(model.effectiveTitle)
        guard let slug = model.project?.slug ?? model.workspace?.name.lowercased(), !slug.isEmpty else { return [] }
        return register.open(mine: nil).filter { $0.project == slug && $0.series.split(separator: "|", maxSplits: 1).last.map(String.init) == key }
    }

    private var earlier: [CallHistory.Record] {
        let key = EditLog.seriesKey(model.effectiveTitle)
        return history.visible.filter { $0.start < model.callDate && EditLog.seriesKey($0.title) == key }
    }

    /// 0.25 (R2, board UT row 2): On you on the left (with Add); Waiting on others and Decided last time on the right.
    @ViewBuilder private var tasksTab: some View {
        let mine = series.filter { $0.mine }, theirs = series.filter { !$0.mine }
        let decided = earlier.first.flatMap { OutcomeCache.shared.outcome($0.file)?.decisions } ?? []
        PageColumns {
            VStack(alignment: .leading, spacing: 0) {
                PageSectionHead(title: L("call.page.onYou"), count: mine.isEmpty ? "" : L("page.tasks.open", ["n": "\(mine.count)"]), warn: !mine.isEmpty) {
                    if trackerOn { HomeLink(L("page.tasks.openTracker")) { HomeNav.shared.open(.tracker) } }
                }
                if mine.isEmpty { none }
                ForEach(mine) { c in taskRow(c) }
                HStack(spacing: 10) {
                    TextField("", text: $newTask, prompt: Text(L("page.tasks.addPh"))).labelsHidden().pageField(34).onSubmit(addTask)
                    Button(L("page.tasks.add"), action: addTask).buttonStyle(PNOutlineButtonStyle(height: 34))
                        .disabled(newTask.trimmingCharacters(in: .whitespaces).isEmpty || model.root == nil)
                }
                .pageRow(10)
            }
        } right: {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 0) {
                    PageSectionHead(title: L("page.tasks.waitingT"), count: theirs.isEmpty ? "" : L("page.tasks.open", ["n": "\(theirs.count)"]))
                    if theirs.isEmpty { none }
                    ForEach(theirs) { c in taskRow(c) }
                }
                VStack(alignment: .leading, spacing: 0) {
                    PageSectionHead(title: L("page.tasks.decidedT"), count: earlier.first.map { HomeRecentRow.day($0.start) } ?? "")
                    if decided.isEmpty { none }
                    ForEach(Array(decided.enumerated()), id: \.offset) { _, d in
                        Text(d).font(t.homeText(16, .semibold)).foregroundStyle(PN.C.text).fixedSize(horizontal: false, vertical: true).pageRow()
                    }
                }
                Text(L("page.tasks.seriesNote")).font(t.homeText(13)).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var none: some View {
        Text(L("page.tasks.none")).font(t.homeText(15)).foregroundStyle(PN.C.text3).pageRow()
    }

    /// A task of the series (board UT): on you a check box, the text, where it came from, the due date (red when late);
    /// on someone else "Name: text" and the due date.
    private func taskRow(_ c: Commitment) -> some View {
        let late = CommitmentRegister.isOverdue(c)
        let from: String = {
            if c.call.isEmpty { return L("page.tasks.byHand") }
            if let r = history.records.first(where: { CommitmentRegister.callKey($0.file) == CommitmentRegister.callKey(c.call) }) {
                return L("page.tasks.from", ["date": HomeRecentRow.day(r.start)])
            }
            return ""
        }()
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            if c.mine {
                Toggle("", isOn: Binding(get: { false }, set: { if $0 { register.mark(c) } }))
                    .toggleStyle(.pnCheckbox).labelsHidden().accessibilityLabel(L("reg.markDoneA11y", ["text": c.text]))
            }
            VStack(alignment: .leading, spacing: 1) {
                (c.mine ? Text(c.text) : Text(c.owner + ": ").fontWeight(.semibold) + Text(c.text))
                    .font(t.homeText(16)).foregroundStyle(PN.C.text).fixedSize(horizontal: false, vertical: true)
                if c.mine && !from.isEmpty { Text(from).font(t.homeText(13)).foregroundStyle(PN.C.text3) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(c.due.isEmpty ? L("page.tasks.noDate") : Register.dueText(c.due))
                .font(t.homeMono(12)).foregroundStyle(late ? PN.C.recText : PN.C.text3).lineLimit(1).fixedSize()
            if !c.mine { Button(L("page.tasks.gotIt")) { register.mark(c) }.buttonStyle(.pnTertiary) }
        }
        .pageRow()
    }

    private func addTask() {
        let t = newTask.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let root = model.root else { return }
        let slug = model.project?.slug ?? model.workspace?.name.lowercased() ?? ""
        register.add(folder: (root as NSString).appendingPathComponent("live"), text: t, owner: "me", project: slug,
                     title: model.effectiveTitle, call: "")
        newTask = ""
    }

    /// 0.25 (R2, board UT row 3): the earlier calls of this meeting: the date, the title, the gist, what came out, the state.
    private var earlierTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageSectionHead(title: L("page.earlier.title"), count: earlier.isEmpty ? "" : "\(earlier.count)") {
                if let r = earlier.first { HomeLink(L("page.earlier.series")) { SeriesWindow.show(record: r) } }
            }
            if earlier.isEmpty {
                PageEmpty(icon: "clock.arrow.circlepath", title: L("page.earlier.none"), text: L("series.after2"))
            }
            ForEach(earlier) { r in
                let o = OutcomeCache.shared.outcome(r.file)
                let notes = RecentCard.summary(r.file)
                Button { CallPageWindow.show(file: r.file) } label: {
                    HStack(alignment: .top, spacing: 14) {
                        Text(HomeRecentRow.day(r.start)).font(t.homeMono(12)).foregroundStyle(PN.C.text3)
                            .frame(width: 110, alignment: .leading).padding(.top, 3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(r.title).font(t.homeText(17, .semibold)).foregroundStyle(PN.C.text).lineLimit(1)
                            if let s = notes ?? o?.line, !s.isEmpty {
                                Text(s).font(t.homeText(15)).foregroundStyle(PN.C.text2).lineLimit(2).multilineTextAlignment(.leading)
                            }
                            let counts = RecentCard.counts(o)
                            if !counts.isEmpty { Text(counts).font(t.homeMono(12)).foregroundStyle(PN.C.text3) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        HomeTagView(kind: notes != nil ? .ready : .neutral, text: L(notes != nil ? "home.tag.notesReady" : "home.tag.transcriptOnly"))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pageRow(14)
            }
            Text(L("page.earlier.note")).font(t.homeText(13)).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true).pageRow(12)
        }
    }
}

/// 0.9.0: the row of tabs shared by both call pages.
struct PageTabs: View {
    let tabs: [(String, String)]
    @Binding var selection: String
    var counts: [String: Int] = [:]      // 2026-11-05 (call page redesign): a count badge next to the name
    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.0) { t in
                let on = selection == t.0
                Button { selection = t.0 } label: {
                    HStack(spacing: 6) {
                        Text(t.1).font(PN.Font.body.weight(on ? .semibold : .regular))
                        if let n = counts[t.0], n > 0 {
                            Text("\(n)").font(PN.sys(11, .semibold).monospacedDigit())
                                .foregroundStyle(on ? PN.C.answer : PN.C.text2)
                                .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                                .background(Capsule().fill(on ? PN.C.accent.opacity(0.14) : Color.primary.opacity(0.07)))
                        }
                    }
                    .foregroundStyle(on ? PN.C.text : PN.C.text2)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(on ? PN.C.surface : Color.clear, in: RoundedRectangle(cornerRadius: PN.r(8)))
                    .shadow(color: (Color.black.opacity(on ? 0.06 : 0)).opacity(PN.depth), radius: 1, y: 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(PN.C.surface2, in: RoundedRectangle(cornerRadius: PN.r(10)))
    }
}
