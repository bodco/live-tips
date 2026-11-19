import AppKit
import LiveTipsCore
import SwiftUI

/// 0.9.0 (redesign phase 3): the Tracker module. Tasks, decisions and risks of every project in one place.
/// Owner, 2026-11-03: no new register and no rules change. What is in Notion comes from the local Notion mirror
/// (`<project>/_notion/{tasks,decisions,risks}/`, refreshed by notion-mirror); what is not in Notion yet are the
/// call commitments kept on this Mac (`<project>/live/commitments.jsonl`). "Add to Tracker" on a call page writes
/// to Notion as before, and the mirror brings it back here.
struct TrackerItem: Identifiable, Hashable {
    enum Kind: String { case task, decision, risk }
    var id: String
    var kind: Kind
    var title: String
    var project: String
    var workspace: String
    var owner: String = ""
    var due: String = ""
    var date: String = ""
    var status: String = ""
    var impact: String = ""
    var url: String = ""
    var callFile: String = ""          // a local commitment: the transcript of its call
    var callTitle: String = ""
    var local = false                  // kept on this Mac (not in Notion yet)
    var commitment: Commitment? = nil
    var orgItem: OrgRegister.Item? = nil  // 0.17.0 (block 4): a colleague's item from an organization project's registers
    var orgProject = ""                   // its organization project

    static func == (a: TrackerItem, b: TrackerItem) -> Bool { a.id == b.id && a.status == b.status && a.orgItem == b.orgItem }
    func hash(into h: inout Hasher) { h.combine(id) }

    var done: Bool {
        let s = status.lowercased()
        return ["done", "closed", "resolved", "superseded", "cancelled", "canceled", "mitigated", "dropped", "reverted", "готово", "закрито"].contains(s)
    }
    var dueDate: Date? { CommitmentRegister.dueDate(due, from: Date()) }
}

@MainActor
final class TrackerModel: ObservableObject {
    static let shared = TrackerModel()
    @Published var items: [TrackerItem] = []
    @Published var loading = false
    @Published var mirrorAt: Date?

    /// 0.25 (R4 shots): the Tracker as with Notion connected, on the demo mirror (ShotMode only).
    static var shotNotion = false

    /// The call a local commitment came from, by its title: the transcript's record, else a call of the same series,
    /// else the call file's name as words ("2026-11-18-1000-release-checklist-review.app.md" -> "Release checklist review").
    /// The series key ("project|releasechecklistreview") is never shown: it has no spaces.
    static func callTitle(_ c: Commitment) -> String {
        if let f = Register.shared.transcript(c), let t = CallHistory.shared.records.first(where: { $0.file == f })?.title { return t }
        let key = c.series.split(separator: "|").last.map(String.init) ?? ""
        if !key.isEmpty, let r = CallHistory.shared.records.first(where: { EditLog.seriesKey($0.title) == key }) { return r.title }
        return titleFromCallFile(c.call)
    }

    nonisolated static func titleFromCallFile(_ call: String) -> String {
        var n = (call as NSString).lastPathComponent
        for suf in [".app.md", ".md"] where n.hasSuffix(suf) { n = String(n.dropLast(suf.count)); break }
        n = n.replacingOccurrences(of: "^\\d{4}-\\d{2}-\\d{2}-\\d{4}-", with: "", options: .regularExpression)
        let words = n.replacingOccurrences(of: "-", with: " ").trimmingCharacters(in: .whitespaces)
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    /// Reads the mirror off the main thread; the commitments come from the register.
    func reload() {
        let cfg = AppConfig.load(from: AppPaths.config)
        let reg = ProjectRegistry.load(from: AppPaths.projects)
        var roots = Set(reg.projects.filter { $0.status != "archived" }.map(\.root) + reg.workspaces.map(\.root))
        if !cfg.workRoot.isEmpty { roots.insert(cfg.workRoot) }
        let rootsList = Array(roots).filter { !$0.isEmpty }
        let local = Register.shared.open(mine: nil).map { c -> TrackerItem in
            let pn = reg.projects.first { $0.slug == c.project }?.name ?? c.project
            let ws = reg.projects.first { $0.slug == c.project }?.workspace ?? ""
            return TrackerItem(id: "c:" + c.id, kind: .task, title: c.text, project: pn, workspace: ws, owner: c.mine ? "me" : c.owner,
                               due: c.due, status: c.status == "open" ? "Open" : c.status, callFile: Register.shared.transcript(c) ?? "",
                               callTitle: Self.callTitle(c),
                               local: c.notionPage.isEmpty, commitment: c)
        }.filter { $0.local }
        mirrorAt = cfg.workRoot.isEmpty ? nil : MirrorStatus.load(workRoot: cfg.workRoot).lastRunUTC
        loading = true
        Task.detached(priority: .utility) {
            let found = Self.scan(rootsList)
            await MainActor.run {
                self.items = local + found
                self.loading = false
            }
        }
    }

    nonisolated static func scan(_ roots: [String]) -> [TrackerItem] {
        var out: [String: TrackerItem] = [:]
        let fm = FileManager.default
        for root in roots {
            guard let en = fm.enumerator(atPath: root) else { continue }
            var depth = 0
            while let rel = en.nextObject() as? String {
                depth = rel.split(separator: "/").count
                if depth > 6 { en.skipDescendants(); continue }
                let name = (rel as NSString).lastPathComponent
                if name.hasPrefix(".") || name == "node_modules" || name == "_archived" || name == "_to_delete" || name == "live" { en.skipDescendants(); continue }
                guard name.hasSuffix(".md"), rel.contains("_notion/") else { continue }
                let dir = ((rel as NSString).deletingLastPathComponent as NSString).lastPathComponent
                guard let kind = TrackerItem.Kind(rawValue: String(dir.dropLast())) else { continue }   // tasks -> task
                if let it = parse((root as NSString).appendingPathComponent(rel), kind), out[it.id] == nil { out[it.id] = it }
            }
        }
        return Array(out.values)
    }

    /// The YAML header the mirror writes (notion-mirror/README.md > Layout).
    nonisolated static func parse(_ path: String, _ kind: TrackerItem.Kind) -> TrackerItem? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        let data = h.readData(ofLength: 16_000); try? h.close()
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix("---") else { return nil }
        var top: [String: String] = [:], props: [String: String] = [:]
        var inProps = false
        for raw in text.split(separator: "\n").dropFirst() {
            let line = String(raw)
            if line.hasPrefix("---") { break }
            if line.hasPrefix("properties:") { inProps = true; continue }
            let isProp = line.hasPrefix("  ")
            let l = line.trimmingCharacters(in: .whitespaces)
            guard let colon = l.range(of: "\": ") ?? l.range(of: ": ") else { continue }
            var k = String(l[..<colon.lowerBound]); var v = String(l[colon.upperBound...])
            k = k.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            v = v.trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("[") { v = v.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }.joined(separator: ", ") }
            v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if inProps && isProp { props[k] = v } else { top[k] = v; inProps = false }
        }
        guard let id = top["notion_id"], let title = top["title"], !title.isEmpty else { return nil }
        func p(_ names: [String]) -> String { for n in names { if let v = props[n], !v.isEmpty, v != "null" { return v } }; return "" }
        let project = p(["Project"]).split(separator: ",").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        return TrackerItem(id: id, kind: kind, title: title,
                           project: project.replacingOccurrences(of: "^[^\\p{L}\\p{N}]+\\s*", with: "", options: .regularExpression),
                           workspace: p(["Workspace"]), owner: p(["Owner", "Assignee", "Stated by", "Assigned to"]),
                           due: p(["Due date", "Due", "Deadline"]), date: p(["Date", "First Seen", "Created"]),
                           status: p(["Status"]), impact: p(["Severity", "Impact", "Likelihood"]), url: top["url"] ?? "",
                           callTitle: p(["Meeting", "Meetings", "Source call"]))
    }
}

struct TrackerScreen: View {
    @ObservedObject var model = TrackerModel.shared
    @ObservedObject var register = Register.shared
    @ObservedObject var org = OrgRegisterStore.shared      // 0.17.0 (block 4): my colleagues' items in organization projects
    @State private var orgSheet: OrgItemSheet.Mode?
    @AppStorage("trackerTab") private var tab = "tasks"
    @AppStorage("trackerWS") private var ws = ""
    @AppStorage("trackerProject") private var project = ""
    @AppStorage("trackerCall") private var call = ""
    @AppStorage("trackerOwner") private var owner = "me"
    @AppStorage("trackerStatus") private var status = "open"
    @State private var find = ""
    @State private var newOpen = false
    @State private var newText = ""
    @State private var newProject = ""

    private var notionOn: Bool { TrackerModel.shotNotion || SettingsWindow.model.notionConnected }
    private var me: [String] { ["me"] + SettingsWindow.model.config.nameAliases.map { $0.lowercased() } }

    private func isMine(_ i: TrackerItem) -> Bool {
        let o = i.owner.lowercased()
        return o == "me" || (!o.isEmpty && me.contains { !$0.isEmpty && o.contains($0) })
    }

    private func list(_ k: TrackerItem.Kind) -> [TrackerItem] {
        let q = find.lowercased()
        return allItems.filter { i in
            i.kind == k
                && (ws.isEmpty || i.workspace.contains(ws))
                && (project.isEmpty || i.project == project)
                && (call.isEmpty || i.callTitle == call)
                && (owner == "anyone" || k != .task || (owner == "me" ? isMine(i) : !isMine(i)))
                && (status == "all" || (status == "done" ? i.done : !i.done))
                && (q.isEmpty || i.title.lowercased().contains(q) || i.project.lowercased().contains(q))
        }
    }

    private var allItems: [TrackerItem] { model.items + org.trackerItems() }

    @Environment(\.pnTheme) private var t

    // 0.25 (R4, boards TR, TX): the bar, the sync line and the title with New on the right, the local banner, the tabs
    // with counts, a row of filter fields, then the table: a head row, groups under a heavy rule, a footnote.
    var body: some View {
        VStack(spacing: 0) {
            PageBackBar(crumb: L("home.nav.tracker"))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .bottom, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                HomeDot(color: notionOn && model.mirrorAt != nil ? PN.C.ready : PN.C.text3, size: 8)
                                Text(t.caps ? subline.uppercased() : subline).font(t.homeMono(11, t.labelWeight))
                                    .tracking(t.style == .classic ? 0 : t.lblTrack * 11).foregroundStyle(PN.C.text3)
                            }
                            Text(t.cased(L("home.nav.tracker"))).font(t.homeDisplay(t.style == .classic ? 32 : 40, t.titleWeight))
                                .tracking(t.dTrack * 40).foregroundStyle(PN.C.text)
                        }
                        Spacer(minLength: 8)
                        if model.loading { PNSpinner(size: 16) }
                        if tab == "tasks" || notionOn {      // 0.25: decisions and risks are made in Notion; without it the banner connects it
                            Button(L(tab == "tasks" ? "tracker.newTask" : tab == "decisions" ? "tracker.newDecision" : "tracker.newRisk")) { newItem() }
                                .buttonStyle(.pnPrimary)
                        }
                    }
                    .padding(.horizontal, PageMetrics.side).padding(.top, 24).padding(.bottom, 16)
                    if !notionOn {
                        HStack(spacing: 16) {
                            Text(L("tracker.localBanner")).font(t.homeText(15)).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button(L("export.connectNotion")) { SettingsWindow.show(tab: "notion") }.buttonStyle(.pnBar)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 14)
                        .background(PN.C.surface2)
                        .overlay(alignment: .leading) { Rectangle().fill(PN.C.notready).frame(width: 4) }
                        .padding(.horizontal, PageMetrics.side).padding(.bottom, 16)
                    }
                    PageTabBar(tabs: [("tasks", L("page.tab.tasks")), ("decisions", L("page.tab.decisions")), ("risks", L("page.tab.risks"))],
                               selection: $tab, badges: ["tasks": "\(list(.task).count)", "decisions": "\(list(.decision).count)", "risks": "\(list(.risk).count)"])
                    filters
                    if newOpen && tab == "tasks" { newTaskRow }
                    if !org.note.isEmpty {
                        Text(org.note).font(t.homeText(13)).foregroundStyle(org.noteIsError ? PN.C.recText : PN.C.text2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, PageMetrics.side).padding(.top, 12)
                    }
                    VStack(alignment: .leading, spacing: 22) {
                        headRow
                        table
                        Text(L(footKey)).font(t.homeText(13)).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, PageMetrics.side).padding(.top, 18).padding(.bottom, 36)
                }
                .environment(\.pageFlat, true)
            }
        }
        .background(PN.C.bg)
        .onAppear { model.reload(); Task { await org.reload() } }
        .onChange(of: register.version) { model.reload() }
        .sheet(item: $orgSheet) { m in OrgItemSheet(mode: m) { orgSheet = nil } }
    }

    private var footKey: String {
        if !notionOn && tab != "tasks" { return "tracker.foot.local" }   // 0.25: no Notion words about rows that cannot be here
        switch tab {
        case "decisions": return "tracker.foot.dec"
        case "risks": return "tracker.foot.risk"
        default: return notionOn ? "tracker.foot.tasks" : "tracker.foot.local"
        }
    }

    private var subline: String {
        guard notionOn else { return L("tracker.kept") }
        guard let d = model.mirrorAt else { return L("tracker.synced", ["ago": "-"]) }
        let f = RelativeDateTimeFormatter(); f.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US"); f.unitsStyle = .short
        return L("tracker.synced", ["ago": f.localizedString(for: d, relativeTo: Date())])
    }

    /// A filter as the boards' field: the name in grey, the value, ▾; set (not "All") on the highlight fill.
    private func filterField<C: View>(_ label: String, _ value: String, set: Bool, @ViewBuilder _ items: () -> C) -> some View {
        let fill: Color = set ? (t.hlBg.map { Color(pnHex: $0) } ?? PN.C.surface2) : .clear
        let ink: Color = set && t.hlBg != nil ? Color(pnHex: t.hlFg) : PN.C.text
        return Menu { items() } label: {
            HStack(spacing: 6) {
                Text(t.caps ? label.uppercased() : label).font(t.homeMono(12)).foregroundStyle(set && t.hlBg != nil ? ink : PN.C.text3)
                Text((t.caps ? value.uppercased() : value) + " ▾").font(t.homeMono(12, .semibold)).foregroundStyle(ink)
            }
            .lineLimit(1)
            .padding(.horizontal, 10).frame(height: 30)
            .background(fill)
            .overlay(RoundedRectangle(cornerRadius: t.style == .classic ? 6 : 0).strokeBorder(PN.C.field, lineWidth: 1.5))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(label + ": " + value)
    }

    private var filters: some View {
        let projects = Array(Set(allItems.map(\.project).filter { !$0.isEmpty })).sorted()
        let wss = Array(Set(allItems.flatMap { $0.workspace.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }.filter { !$0.isEmpty })).sorted()
        let calls = Array(Set(allItems.map(\.callTitle).filter { !$0.isEmpty })).sorted()
        let all = L("tracker.all")
        return HStack(spacing: 8) {
            if !wss.isEmpty {
                filterField(L("tracker.f.workspace"), ws.isEmpty ? all : ws, set: !ws.isEmpty) {
                    Button(all) { ws = "" }; ForEach(wss, id: \.self) { w in Button(w) { ws = w } }
                }
            }
            filterField(L("call.project"), project.isEmpty ? all : project, set: !project.isEmpty) {
                Button(all) { project = "" }; ForEach(projects, id: \.self) { p in Button(p) { project = p } }
            }
            filterField(L("tracker.f.call"), call.isEmpty ? all : String(call.prefix(28)), set: !call.isEmpty) {
                Button(all) { call = "" }; ForEach(calls, id: \.self) { c in Button(c) { call = c } }
            }
            if tab == "tasks" {
                filterField(L("tracker.f.owner"), L(owner == "me" ? "series.me" : owner == "others" ? "tracker.others" : "tracker.anyone"), set: owner != "anyone") {
                    Button(L("series.me")) { owner = "me" }; Button(L("tracker.anyone")) { owner = "anyone" }; Button(L("tracker.others")) { owner = "others" }
                }
            }
            filterField(L("tracker.f.status"), L(status == "open" ? "tracker.open" : status == "done" ? "page.tasks.done" : "tracker.all"), set: status != "all") {
                Button(L("tracker.open")) { status = "open" }; Button(L("page.tasks.done")) { status = "done" }; Button(all) { status = "all" }
            }
            Spacer(minLength: 8)
            TextField("", text: $find, prompt: Text(L("tracker.find"))).labelsHidden().pageField(30).frame(width: 220)
        }
        .padding(.horizontal, PageMetrics.side).padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(PN.C.rule).frame(height: 1) }
    }

    // MARK: table, grouped

    private struct Cols { static let lead: CGFloat = 28, project: CGFloat = 140, call: CGFloat = 210, third: CGFloat = 110, fourth: CGFloat = 104 }

    /// The head of the table in the mono label face (board: Task, Project, Call, Owner, Due).
    private var headRow: some View {
        let h: [String] = tab == "decisions" ? ["tracker.h.decision", "tracker.h.date", "tracker.h.status"]
            : tab == "risks" ? ["tracker.h.risk", "tracker.h.impact", "tracker.h.status"] : ["tracker.h.task", "tracker.h.owner", "tracker.h.due"]
        func lbl(_ s: String) -> some View {
            Text(t.caps ? s.uppercased() : s).font(t.homeMono(11, t.labelWeight)).tracking(t.style == .classic ? 0 : t.lblTrack * 11).foregroundStyle(PN.C.text3)
        }
        return HStack(spacing: 12) {
            Color.clear.frame(width: Cols.lead, height: 1)
            lbl(L(h[0])).frame(maxWidth: .infinity, alignment: .leading)
            lbl(L("call.project")).frame(width: Cols.project, alignment: .leading)
            lbl(L("tracker.f.call")).frame(width: Cols.call, alignment: .leading)
            lbl(L(h[1])).frame(width: Cols.third, alignment: .leading)
            lbl(L(h[2])).frame(width: Cols.fourth, alignment: .leading)
        }
    }

    @ViewBuilder private var table: some View {
        switch tab {
        case "decisions":
            let all = list(.decision)
            let waiting = all.filter { ["proposed", "draft", "pending", "waiting"].contains($0.status.lowercased()) }
            groupView(L("tracker.g.waiting"), waiting, kind: .waiting)
            groupView(L("tracker.g.confirmed"), all.filter { !waiting.contains($0) }, kind: .plain)
        case "risks":
            let all = list(.risk)
            groupView(L("tracker.g.open"), all.filter { !$0.done }, kind: .plain)
            groupView(L("tracker.g.closed"), all.filter { $0.done }, kind: .quiet)
        default:
            let all = list(.task)
            let today = Calendar.current.startOfDay(for: Date())
            let week = Calendar.current.date(byAdding: .day, value: 7, to: today) ?? today
            let overdue = all.filter { ($0.dueDate.map { $0 < today } ?? false) && !$0.done }
            let thisWeek = all.filter { d in !overdue.contains(d) && (d.dueDate.map { $0 < week } ?? false) }
            groupView(L("tracker.g.overdue"), overdue, kind: .danger)
            groupView(L("tracker.g.week"), thisWeek, kind: .plain)
            groupView(L("tracker.g.later"), all.filter { !overdue.contains($0) && !thisWeek.contains($0) }, kind: .plain)
        }
        if list(tab == "decisions" ? .decision : tab == "risks" ? .risk : .task).isEmpty {
            Text(L("page.tasks.none")).font(t.homeText(15)).foregroundStyle(PN.C.text3).pageRow(10)
        }
    }

    private enum GroupKind { case plain, danger, waiting, quiet }

    @ViewBuilder private func groupView(_ title: String, _ rows: [TrackerItem], kind: GroupKind) -> some View {
        if !rows.isEmpty {
            let plate = kind == .waiting ? t.nrBg.map { Color(pnHex: $0) } : nil
            let color: Color = kind == .danger ? PN.C.recText : kind == .waiting ? PN.C.notreadyText : kind == .quiet ? PN.C.text3 : PN.C.text
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(title).pnSection().foregroundStyle(color)
                        .padding(.horizontal, plate == nil ? 0 : 5).background(plate ?? .clear)
                        .accessibilityAddTraits(.isHeader)
                    PageCount(text: "\(rows.count)")
                    Spacer()
                }
                .padding(.top, 10).padding(.bottom, 8)
                .overlay(alignment: .top) { Rectangle().fill(PN.C.ruleStrong).frame(height: t.ruleHeavy) }
                ForEach(rows.sorted { ($0.dueDate ?? .distantFuture, $0.title) < ($1.dueDate ?? .distantFuture, $1.title) }) { r in
                    row(r, danger: kind == .danger)
                }
            }
        }
    }

    /// A small outlined tile in front of a decision or a risk (board TX): ✓ made, ? proposed, × reverted, ! a risk.
    private func tile(_ r: TrackerItem) -> some View {
        let s = r.status.lowercased()
        let proposed = ["proposed", "draft", "pending", "waiting"].contains(s), reverted = ["reverted", "superseded", "cancelled", "canceled"].contains(s)
        let risk = r.kind == .risk && !r.done       // a closed risk is quiet (grey), like a reverted decision
        let sym = r.kind == .risk ? "!" : proposed ? "?" : reverted ? "×" : "✓"
        let quiet = reverted || (r.kind == .risk && r.done)
        let border: Color = risk || proposed ? PN.C.notready : quiet ? PN.C.text3 : PN.C.ready
        let ink: Color = risk || proposed ? PN.C.notreadyText : quiet ? PN.C.text2 : PN.C.readyText
        let fill: Color = risk || proposed ? (t.nrBg.map { Color(pnHex: $0) } ?? .clear) : .clear
        let shape = RoundedRectangle(cornerRadius: t.statusSquare ? 0 : 10)
        return Text(sym).font(t.homeText(12, .heavy)).foregroundStyle(ink)
            .frame(width: 20, height: 20).background(fill, in: shape).overlay(shape.strokeBorder(border, lineWidth: 1.5))
            .accessibilityHidden(true)
    }

    private func row(_ r: TrackerItem, danger: Bool) -> some View {
        let third = r.kind == .task ? (isMine(r) ? L("series.me") : r.owner) : r.kind == .decision ? Register.dueText(String(r.date.prefix(10))) : r.impact
        let fourth = r.kind == .task ? (r.due.isEmpty ? L("page.tasks.noDate") : Register.dueText(r.due))
            : r.orgItem.map { L("orgreg.st." + $0.kind.rawValue + "." + $0.status) } ?? r.status
        let imp = r.impact.lowercased()
        let thirdColor: Color = r.kind == .risk ? (imp.hasPrefix("high") || imp.hasPrefix("висок") ? PN.C.recText : imp.hasPrefix("med") || imp.hasPrefix("серед") ? PN.C.notreadyText : PN.C.text2) : PN.C.text2
        let proposed = r.kind == .decision && ["proposed", "draft", "pending", "waiting"].contains(r.status.lowercased())
        let fourthColor: Color = (danger && r.kind == .task) ? PN.C.recText : proposed ? PN.C.notreadyText : r.done ? PN.C.text3 : PN.C.text2
        let note: String = {
            if let i = r.orgItem { return r.callTitle + (org.editedBy(i, r.orgProject).map { " · " + L("orgreg.changedBy", ["who": $0]) } ?? "") }
            return r.local ? L("tracker.kept") : ""
        }()
        return HStack(alignment: .center, spacing: 12) {
            Group {
                if r.kind == .task {
                    Toggle("", isOn: Binding(get: { r.done }, set: { on in
                        if let i = r.orgItem { Task { await org.change(i, orgProject: r.orgProject, .init(status: on ? "done" : "open")) } }
                        else if let c = r.commitment { register.mark(c) } else if let u = URL(string: r.url) { NSWorkspace.shared.open(u) } }))
                        .toggleStyle(.pnCheckbox).labelsHidden().accessibilityLabel(L("reg.markDoneA11y", ["text": r.title]))
                        .disabled(r.orgItem.map { !$0.canEdit } ?? false)
                } else { tile(r) }
            }
            .frame(width: Cols.lead, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(r.title).font(t.homeText(16)).foregroundStyle(r.done ? PN.C.text3 : PN.C.text).lineLimit(2)
                if !note.isEmpty { Text(note).font(t.homeText(12)).foregroundStyle(PN.C.text3).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(r.project).font(t.homeText(14)).foregroundStyle(PN.C.text2).frame(width: Cols.project, alignment: .leading).lineLimit(1)
            Group {
                if !r.callFile.isEmpty {
                    HomeLink(r.callTitle.isEmpty ? L("tracker.call") : r.callTitle) { CallPageWindow.show(file: r.callFile) }
                } else { Text(r.orgItem == nil ? r.callTitle : "").font(t.homeText(14)).foregroundStyle(PN.C.text3) }
            }
            .frame(width: Cols.call, alignment: .leading).lineLimit(1)
            Text(third).font(t.homeText(14, r.kind == .risk ? .semibold : .regular)).foregroundStyle(thirdColor).frame(width: Cols.third, alignment: .leading).lineLimit(1)
            Text(fourth).font(t.homeMono(12, .semibold)).foregroundStyle(fourthColor).frame(width: Cols.fourth, alignment: .leading).lineLimit(1)
        }
        .pageRow(9)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if let u = URL(string: r.url), !r.url.isEmpty { NSWorkspace.shared.open(u) } }
        .contextMenu {
            OrgItemMenu(row: r, sheet: $orgSheet)
            if let u = URL(string: r.url), !r.url.isEmpty { Button(L("ntask.openNotion")) { NSWorkspace.shared.open(u) } }
            if !r.callFile.isEmpty { Button(L("reg.openCall")) { CallPageWindow.show(file: r.callFile) } }
            Button(L("reg.copy")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(r.title, forType: .string) }
        }
    }

    // MARK: new

    private func newItem() {
        if tab == "tasks" { newOpen.toggle(); return }
        let cfg = AppConfig.load(from: AppPaths.config)
        let db = tab == "decisions" ? cfg.notionDecisionsDB : cfg.notionRisksDB
        if !notionOn || db.isEmpty { SettingsWindow.show(tab: "notion"); return }
        if let u = URL(string: "https://www.notion.so/" + db.replacingOccurrences(of: "-", with: "")) { NSWorkspace.shared.open(u) }
    }

    private var newTaskRow: some View {
        let reg = ProjectRegistry.load(from: AppPaths.projects)
        let name = reg.projects.first { $0.slug == newProject }?.name ?? L("call.chooseProject")
        return HStack(spacing: 8) {
            TextField("", text: $newText, prompt: Text(L("page.tasks.addPh"))).labelsHidden().pageField(32).onSubmit(addTask)
            Menu {
                ForEach(reg.projects.filter { $0.status != "archived" }, id: \.slug) { p in Button(p.name) { newProject = p.slug } }
            } label: { HomeField(text: name, height: 32) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            Button(L("page.tasks.add"), action: addTask).buttonStyle(.pnPrimary)
                .disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty || newProject.isEmpty)
        }
        .padding(.horizontal, PageMetrics.side).padding(.vertical, 14)
        .background(PN.C.surface2)
        .overlay(alignment: .bottom) { Rectangle().fill(PN.C.rule).frame(height: 1) }
    }

    private func addTask() {
        let reg = ProjectRegistry.load(from: AppPaths.projects)
        guard let p = reg.projects.first(where: { $0.slug == newProject }), !p.root.isEmpty else { return }
        let t = newText.trimmingCharacters(in: .whitespaces); guard !t.isEmpty else { return }
        register.add(folder: (p.root as NSString).appendingPathComponent("live"), text: t, owner: "me", project: p.slug, title: "", call: "")
        newText = ""; newOpen = false
    }
}
