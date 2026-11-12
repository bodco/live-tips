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

    private var wide: Bool { width >= 860 }

    private var app: AppDelegate? { NSApp.delegate as? AppDelegate }
    private var dirty: Bool { snap.map { $0 != SetupSnap(model) } ?? false }
    private var briefPath: String? { PrepDocWindow.path(for: model) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                head
                PageTabs(tabs: tabs, selection: $tab, counts: ["tasks": series.count, "earlier": earlier.count,
                    "readiness": doc?.sheet?.readinessBadge.gaps ?? 0, "sources": doc?.sheet?.sources.count ?? 0,
                    "versions": doc.map { SheetFiles.versions(of: $0.path).count + 1 } ?? 0]).padding(.top, 4)
                switch tab {
                case "sheet", "brief": sheetTab
                case "readiness": sheetOr { SheetReadinessTab(doc: $0, onAddSource: { getReady(.expert, step: 3) }, onStart: { start() }) }
                case "sources": sheetOr { SheetSourcesTab(doc: $0, onAddSource: { getReady(.expert, step: 3) }) }
                case "versions": sheetOr { SheetVersionsTab(doc: $0, initialOpen: compareN) }
                case "tasks": tasksTab
                case "earlier": card { earlierTab }
                default: card { setupTab }
                }
            }
            .padding(24).frame(maxWidth: 1100, alignment: .leading)
            .background(GeometryReader { g in
                Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w }
            })
            .frame(maxWidth: .infinity)      // centred
        }
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

    // MARK: head: meta, name, project and people, the actions

    private var tabs: [(String, String)] {
        // 2026-11-05 (redesign): the counts are badges, as on the past call page
        // 0.10.0 (Meeting Sheet, phase 5): Setup / Meeting Sheet / Readiness / Sources / Versions / Tasks / Earlier
        [("setup", L("page.tab.setup")), ("sheet", L("sheet.ui.tab.sheet")), ("readiness", L("sheet.ui.tab.readiness")),
         ("sources", L("sheet.ui.tab.sources")), ("versions", L("sheet.ui.tab.versions")),
         ("tasks", L("page.tab.tasks")), ("earlier", L("page.tab.earlier"))]
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

    /// 2026-11-05 (redesign): a header card like Home's next call and the past call page.
    private var head: some View {
        let d = DateFormatter(); d.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US"); d.setLocalizedDateFormatFromTemplate("EEEMMMd")
        let t = DateFormatter(); t.locale = d.locale; t.setLocalizedDateFormatFromTemplate("HHmm")
        let people = HomeView.peopleLine(model.participants)
        let info = VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(d.string(from: model.callDate) + " · " + t.string(from: model.callDate)).font(.system(size: 13, weight: .semibold)).foregroundStyle(PN.C.accent)
                if let b = doc?.sheet?.readinessBadge, state != .preparing { SheetReadinessPill(badge: b) } else { StatePill(state: state) }
                if !model.target.isEmpty { PagePill(text: model.targetName, color: PN.C.answer) }
            }
            Text(model.effectiveTitle).font(.system(size: 28, weight: .bold)).foregroundStyle(PN.C.text).lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if !people.isEmpty { Text(L("home.card.with", ["people": people])).font(PN.Font.body).foregroundStyle(PN.C.text2).lineLimit(2) }
            if !note.isEmpty { Text(note).font(PN.Font.caption).foregroundStyle(PN.C.pending).fixedSize(horizontal: false, vertical: true) }
        }
        return VStack(alignment: .leading, spacing: 0) {
            if wide {
                HStack(alignment: .top, spacing: 20) {
                    info.frame(maxWidth: .infinity, alignment: .leading)
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .trailing, spacing: 8) { primary }
                        more
                    }
                    .padding(.top, 2)
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    info
                    HStack(spacing: 12) { primary; more }
                }
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: PageStyle.radius).fill(PN.C.surface))
    }

    /// 0.10.0 (Meeting Sheet, phase 4): Get ready opens Quick or Expert by the default rules; Start without prep;
    /// once the sheet is built: Start call, Refresh, Export.
    @ViewBuilder private var primary: some View {
        let live = app?.callIsLive ?? false
        if let j = jobs.job(for: model.id) {
            Button { start() } label: { Label(L("home.startCall"), systemImage: "play.fill") }.buttonStyle(.pnPrimary)
            Text(L("sheet.ui.building", ["p": "\(Int(j.progress * 100))"])).font(PN.Font.caption).foregroundStyle(PN.C.text2)
            link(L("call.stop")) { j.stop() }
            SheetSwitchPrompt(callID: model.id)      // 0.10.0 (Meeting Sheet, hardening): the route question inline
        } else if doc != nil {
            Button { start() } label: { Label(live ? L("home.switch") : L("home.startCall"), systemImage: "play.fill") }.buttonStyle(.pnPrimary)
            HStack(spacing: 14) {
                link(L("sheet.ui.refresh")) { confirmAgain = true }
                link(L("sheet.ui.export")) { exporting = true }
            }
        } else if state == .preparing || state == .queued {
            Button { start() } label: { Label(L("home.startCall"), systemImage: "play.fill") }.buttonStyle(.pnPrimary)
            link(L("common.cancel")) { if state == .preparing { runner.cancel() } else { upnext.unqueue(model) } }
        } else if state == .ready {
            // 0.10.0 (Meeting Sheet, hardening): a call prepared in 0.9.7 (a brief, no sheet) starts with that brief:
            // Start call stays the main button, Get ready (build a sheet) is the second choice.
            Button { start() } label: { Label(live ? L("home.switch") : L("home.startCall"), systemImage: "play.fill") }.buttonStyle(.pnPrimary)
            link(L("home.getReady")) { getReady(nil) }
        } else {
            Button(L("home.getReady")) { getReady(nil) }.buttonStyle(.pnPrimary)
            link(L("sheet.ui.startWithout")) { start() }
            if !SheetRoutes.ready(SheetRoutes.preferred) && SheetRoutes.firstReady() == nil { link(L("home.connectClaude")) { SettingsWindow.show(tab: "ai") } }
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
        } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(height: 32).accessibilityLabel(L("home.more"))
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
        if let d = doc { c(d) } else { card { noSheet } }
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
        } else if briefPath != nil {
            VStack(alignment: .leading, spacing: 8) {
                Label(L("sheet.ui.legacy"), systemImage: "doc.text").font(PN.Font.caption).foregroundStyle(PN.C.text3)
                card { briefTab }
            }
        } else {
            card { noSheet }
        }
    }

    private var noSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            PageEmpty(icon: "doc.text.magnifyingglass", title: L("sheet.ui.none"), text: L("sheet.ui.none.body"))
            if let j = jobs.job(for: model.id) {
                Text(L("sheet.ui.building", ["p": "\(Int(j.progress * 100))"])).font(PN.Font.body).foregroundStyle(PN.C.text2)
                SheetSwitchPrompt(callID: model.id)
            } else {
                HStack(spacing: 10) {
                    Button(L("home.getReady")) { getReady(nil) }.buttonStyle(.pnPrimary)
                    Button(L("sheet.ui.quickPrep")) { getReady(.quick) }.buttonStyle(.pnSecondary)
                    Button(L("sheet.ui.expertPrep")) { getReady(.expert) }.buttonStyle(.pnSecondary)
                }
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 22)
    }

    private func save() {
        model.useDefaultTargetIfEmpty()
        upnext.save(model)
        snap = SetupSnap(model)
    }

    /// Leaving with unsaved Setup changes: ask, never drop them silently.
    private func askToSave() {
        guard dirty, let s = snap else { return }
        let a = NSAlert()
        a.messageText = L("page.unsaved.title", ["title": model.effectiveTitle])
        a.informativeText = L("page.unsaved.body")
        a.addButton(withTitle: L("common.save")); a.addButton(withTitle: L("page.unsaved.discard"))
        if a.runModal() == .alertFirstButtonReturn { save() } else { s.restore(model) }
    }

    // MARK: tabs

    private var setupTab: some View {
        CallSetupView(model: model, mode: .page, onStart: { start() }, onCancel: { snap?.restore(model) }, onSave: { save() })
            .frame(minHeight: 560)
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
                PrepDocView(path: p, title: model.effectiveTitle).frame(minHeight: 520)
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

    /// 2026-11-05 (redesign): On you and Waiting on others side by side (others grouped by person), what was decided
    /// last time below; the same cards as the past call page.
    @ViewBuilder private var tasksTab: some View {
        let mine = series.filter { $0.mine }, theirs = series.filter { !$0.mine }
        let decided = earlier.first.flatMap { OutcomeCache.shared.outcome($0.file)?.decisions } ?? []
        let onYou = PageCard(spacing: 2) {
            label(L("page.tasks.onYou"), mine.count)
            if mine.isEmpty { none }
            ForEach(mine) { c in taskRow(c, action: L("page.tasks.done")) { register.mark(c) } }
            HStack(spacing: 8) {
                TextField(L("page.tasks.addPh"), text: $newTask).textFieldStyle(.roundedBorder).onSubmit(addTask)
                Button(L("page.tasks.add"), action: addTask).buttonStyle(.pnSecondary).disabled(newTask.trimmingCharacters(in: .whitespaces).isEmpty || model.root == nil)
            }
            .padding(.top, 10)
        }
        let owners = theirs.reduce(into: [String]()) { if !$0.contains($1.owner) { $0.append($1.owner) } }
        let waiting = PageCard(spacing: 2) {
            label(L("page.tasks.waiting"), theirs.count)
            if theirs.isEmpty { none }
            ForEach(owners, id: \.self) { who in
                HStack(spacing: 8) { PageAvatar(name: who); Text(who).font(PN.Font.section).foregroundStyle(PN.C.text2) }
                    .padding(.top, who == owners.first ? 2 : 12).padding(.bottom, 2)
                ForEach(theirs.filter { $0.owner == who }) { c in taskRow(c, action: L("page.tasks.gotIt")) { register.mark(c) } }
            }
        }
        VStack(alignment: .leading, spacing: 16) {
            if wide { HStack(alignment: .top, spacing: 16) { onYou; waiting } } else { onYou; waiting }
            PageCard(spacing: 2) {
                label(L("page.tasks.decided"), decided.count)
                if decided.isEmpty { none }
                ForEach(Array(decided.enumerated()), id: \.offset) { _, d in
                    HStack(alignment: .top, spacing: 10) {
                        PageIconTile(icon: "checkmark", color: PN.C.turn)
                        Text(d).font(PN.Font.body).foregroundStyle(PN.C.text).fixedSize(horizontal: false, vertical: true).padding(.top, 2)
                    }
                    .padding(.vertical, 5)
                }
            }
            if trackerOn {
                HStack { Spacer(); link(L("page.tasks.openTracker")) { HomeNav.shared.open(.tracker) } }
            }
        }
    }

    private func label(_ t: String, _ n: Int) -> some View {
        PageLabel(text: t) { if n > 0 { Text(L("page.tasks.open", ["n": "\(n)"])).font(PN.Font.caption).foregroundStyle(PN.C.text3) } }.padding(.bottom, 6)
    }

    private var none: some View {
        Text(L("page.tasks.none")).font(PN.Font.body).foregroundStyle(PN.C.text3).padding(.vertical, 4)
    }

    private func taskRow(_ c: Commitment, action: String, run: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(c.text).font(PN.Font.body).foregroundStyle(PN.C.text).fixedSize(horizontal: false, vertical: true)
                if !c.due.isEmpty {
                    Text(L("reg.due", ["due": Register.dueText(c.due)])).font(PN.Font.caption)
                        .foregroundStyle(CommitmentRegister.isOverdue(c) ? PN.C.danger : PN.C.text3)
                }
            }
            Spacer(minLength: 8)
            Button(action, action: run).buttonStyle(.pnTertiary)
        }
        .padding(.vertical, 5)
    }

    private func addTask() {
        let t = newTask.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let root = model.root else { return }
        let slug = model.project?.slug ?? model.workspace?.name.lowercased() ?? ""
        register.add(folder: (root as NSString).appendingPathComponent("live"), text: t, owner: "me", project: slug,
                     title: model.effectiveTitle, call: "")
        newTask = ""
    }

    private var earlierTab: some View {
        let f = DateFormatter(); f.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US"); f.setLocalizedDateFormatFromTemplate("EEEdMMMyyyy")
        return VStack(alignment: .leading, spacing: 0) {
            if earlier.isEmpty {
                PageEmpty(icon: "clock.arrow.circlepath", title: L("page.earlier.none"), text: L("series.after2"))
                    .padding(.horizontal, 18).padding(.vertical, 16)
            }
            ForEach(Array(earlier.enumerated()), id: \.element.id) { i, r in
                if i > 0 { Divider() }
                Button { CallPageWindow.show(file: r.file) } label: {
                    // 2026-11-05 (redesign): the date in its own column, the gist, a chevron to the call page
                    HStack(alignment: .top, spacing: 14) {
                        Text(f.string(from: r.start)).font(PN.Font.caption.weight(.medium)).foregroundStyle(PN.C.accent)
                            .frame(width: 110, alignment: .leading).padding(.top, 1)
                        Text(RecentCard.summary(r.file) ?? (OutcomeCache.shared.outcome(r.file)?.line ?? r.title))
                            .font(PN.Font.body).foregroundStyle(PN.C.text).lineLimit(2).multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(PN.C.text3).padding(.top, 3)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.horizontal, 24).padding(.vertical, 14)
            }
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
                            Text("\(n)").font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(on ? PN.C.answer : PN.C.text2)
                                .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                                .background(Capsule().fill(on ? PN.C.accent.opacity(0.14) : Color.primary.opacity(0.07)))
                        }
                    }
                    .foregroundStyle(on ? PN.C.text : PN.C.text2)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(on ? PN.C.surface : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    .shadow(color: .black.opacity(on ? 0.06 : 0), radius: 1, y: 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(PN.C.surface2, in: RoundedRectangle(cornerRadius: 10))
    }
}
