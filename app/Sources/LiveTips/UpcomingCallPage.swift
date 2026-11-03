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
    @State private var tab = "setup"
    @State private var snap: SetupSnap?
    @State private var note = ""
    @State private var confirmAgain = false
    @State private var newTask = ""

    private var app: AppDelegate? { NSApp.delegate as? AppDelegate }
    private var dirty: Bool { snap.map { $0 != SetupSnap(model) } ?? false }
    private var briefPath: String? { PrepDocWindow.path(for: model) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                head
                if !note.isEmpty { Text(note).font(PN.Font.body).foregroundStyle(PN.C.pending) }
                PageTabs(tabs: tabs, selection: $tab)
                VStack(alignment: .leading, spacing: 0) {
                    switch tab {
                    case "brief": briefTab
                    case "tasks": tasksTab
                    case "earlier": earlierTab
                    default: setupTab
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.l))
            }
            .padding(24).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)      // centred
        }
        .onAppear { if snap == nil { snap = SetupSnap(model) }; model.scanPrep() }
        .onDisappear { askToSave() }
        .confirmationDialog(L("again.title"), isPresented: $confirmAgain) {
            Button(L("talk.prepareAgain")) { prepare() }
            Button(L("common.cancel"), role: .cancel) {}
        } message: { Text(L("again.keepBrief")) }
    }

    // MARK: head: meta, name, project and people, the actions

    private var tabs: [(String, String)] {
        [("setup", L("page.tab.setup")), ("brief", L("page.tab.brief")),
         ("tasks", L("page.tab.tasks") + (series.isEmpty ? "" : " \(series.count)")),
         ("earlier", L("page.tab.earlier") + (earlier.isEmpty ? "" : " \(earlier.count)"))]
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

    private var head: some View {
        let df = DateFormatter(); df.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US"); df.setLocalizedDateFormatFromTemplate("EEEEdMMMMHHmm")
        let people = HomeView.peopleLine(model.participants)
        let sub = [model.target.isEmpty ? "" : model.targetName, people.isEmpty ? "" : L("home.card.with", ["people": people])].filter { !$0.isEmpty }.joined(separator: " · ")
        return HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(df.string(from: model.callDate)).font(PN.Font.caption.weight(.medium)).foregroundStyle(PN.C.text3)
                    StatePill(state: state)
                }
                Text(model.effectiveTitle).font(.system(size: 24, weight: .bold)).foregroundStyle(PN.C.text).lineLimit(2)
                if !sub.isEmpty { Text(sub).font(PN.Font.body).foregroundStyle(PN.C.text2).lineLimit(2) }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) { actions }
        }
    }

    @ViewBuilder private var actions: some View {
        let live = app?.callIsLive ?? false
        switch state {
        case .noBrief:
            Button { start() } label: { Label(live ? L("home.switch") : L("home.startCall"), systemImage: "play.fill") }.buttonStyle(.pnPrimary)
            link(L("home.connectClaude")) { SettingsWindow.show(tab: "ai") }
        case .ready:
            Button { start() } label: { Label(live ? L("home.switch") : L("home.startCall"), systemImage: "play.fill") }.buttonStyle(.pnPrimary)
            link(L("talk.prepareAgain")) { confirmAgain = true }
        case .preparing, .queued:
            Button { start() } label: { Label(L("home.startCall"), systemImage: "play.fill") }.buttonStyle(.pnPrimary)
            link(L("common.cancel")) { if state == .preparing { runner.cancel() } else { upnext.unqueue(model) } }
        default:
            Button(L("home.getReady")) { prepare() }.buttonStyle(.pnPrimary)
            link(L("home.startWithout")) { start() }
        }
        Menu {
            if upnext.contains(model) { Button(L("home.removeUpNext")) { upnext.remove(model); HomeNav.shared.back() } }
            if model.calEventID != nil { Button(L("home.showInCalendar")) { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app")) } }
            Button(L("call.copyCowork")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.prepPhrase, forType: .string) }
        } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel(L("home.more"))
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

    private func prepare() {
        guard !model.target.isEmpty else { note = L("call.needProject"); tab = "setup"; return }
        if dirty { save() }
        upnext.save(model)
        if let e = upnext.prepare(model) { note = e } else { note = ""; tab = "brief" }
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
            VStack(alignment: .leading, spacing: 10) {
                Text(L("page.brief.none")).font(.system(size: 17, weight: .semibold)).foregroundStyle(PN.C.text)
                if state == .preparing || state == .queued {
                    Text(state == .preparing ? L("home.check.preparing", ["p": "\(Int(runner.progress * 100))"]) : L("badge.queued"))
                        .font(PN.Font.body).foregroundStyle(PN.C.text2)
                } else if HomeView.aiReadyNow() {
                    Button(L("page.brief.getReady")) { prepare() }.buttonStyle(.pnPrimary)
                } else {
                    link(L("home.connectClaude")) { SettingsWindow.show(tab: "ai") }
                }
            }
            .padding(20)
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

    private var tasksTab: some View {
        let mine = series.filter { $0.mine }, theirs = series.filter { !$0.mine }
        let decided = earlier.first.flatMap { OutcomeCache.shared.outcome($0.file)?.decisions } ?? []
        return VStack(alignment: .leading, spacing: 18) {
            group(L("page.tasks.onYou"), mine.isEmpty ? [] : mine.map { c in AnyView(taskRow(c, action: L("page.tasks.done")) { register.mark(c) }) })
            group(L("page.tasks.waiting"), theirs.isEmpty ? [] : theirs.map { c in AnyView(taskRow(c, action: L("page.tasks.gotIt")) { register.mark(c) }) })
            group(L("page.tasks.decided"), decided.map { d in AnyView(Text("• " + d).font(PN.Font.body).foregroundStyle(PN.C.text).fixedSize(horizontal: false, vertical: true)) })
            HStack(spacing: 8) {
                TextField(L("page.tasks.addPh"), text: $newTask).textFieldStyle(.roundedBorder).onSubmit(addTask)
                Button(L("page.tasks.add"), action: addTask).buttonStyle(.pnSecondary).disabled(newTask.trimmingCharacters(in: .whitespaces).isEmpty || model.root == nil)
                Spacer()
                if trackerOn { link(L("page.tasks.openTracker")) { HomeNav.shared.open(.tracker) } }
            }
        }
        .padding(20)
    }

    private func group(_ title: String, _ rows: [AnyView]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(PN.Font.label).foregroundStyle(PN.C.text3)
            if rows.isEmpty { Text(L("page.tasks.none")).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in r }
        }
    }

    private func taskRow(_ c: Commitment, action: String, run: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(c.text).font(PN.Font.body).foregroundStyle(PN.C.text).fixedSize(horizontal: false, vertical: true)
                let meta = [c.mine ? "" : c.owner, c.due.isEmpty ? "" : L("reg.due", ["due": Register.dueText(c.due)])].filter { !$0.isEmpty }.joined(separator: " · ")
                if !meta.isEmpty { Text(meta).font(PN.Font.caption).foregroundStyle(CommitmentRegister.isOverdue(c) ? PN.C.danger : PN.C.text3) }
            }
            Spacer(minLength: 8)
            Button(action, action: run).buttonStyle(.pnTertiary)
        }
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
            if earlier.isEmpty { Text(L("series.after2")).font(PN.Font.body).foregroundStyle(PN.C.text3).padding(20) }
            ForEach(Array(earlier.enumerated()), id: \.element.id) { i, r in
                if i > 0 { Divider() }
                Button { CallPageWindow.show(file: r.file) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(f.string(from: r.start)).font(PN.Font.caption.weight(.medium)).foregroundStyle(PN.C.text3)
                        Text(RecentCard.summary(r.file) ?? (OutcomeCache.shared.outcome(r.file)?.line ?? r.title))
                            .font(PN.Font.body).foregroundStyle(PN.C.text).lineLimit(2).multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.horizontal, 20).padding(.vertical, 12)
            }
        }
    }
}

/// 0.9.0: the row of tabs shared by both call pages.
struct PageTabs: View {
    let tabs: [(String, String)]
    @Binding var selection: String
    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.0) { t in
                Button { selection = t.0 } label: {
                    Text(t.1).font(PN.Font.body.weight(selection == t.0 ? .semibold : .regular))
                        .foregroundStyle(selection == t.0 ? PN.C.text : PN.C.text2)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(selection == t.0 ? PN.C.surface : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(PN.C.surface2, in: RoundedRectangle(cornerRadius: 10))
    }
}
