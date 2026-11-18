import AppKit
import LiveTipsCore
import SwiftUI

/// 0.20.0 (B9, server 0.12.0, D47): the Team tab for a team lead or C-level. The calls of the people they see, an
/// overview by person and week, search, and a colleague's call page (read only). The team's calls stay in memory for
/// this session and are never written to this Mac (D47.9). Built in the current style of the app, with no new
/// components, so the redesign can move it as it is.
@MainActor
final class TeamStore: ObservableObject {
    static let shared = TeamStore()

    enum Mode: String, CaseIterable, Identifiable { case calls, overview; var id: String { rawValue } }

    @Published var orgID = ""
    @Published var mode: Mode = .calls
    @Published var period: TeamCalls.Period = .days30
    @Published var customFrom = Date().addingTimeInterval(-30 * 86400)
    @Published var customTo = Date()
    @Published var person = ""
    @Published var team = ""
    @Published var project = ""
    @Published var type = ""
    @Published var recordedOnly = false
    @Published var series = ""
    @Published var query = ""

    @Published private(set) var people: TeamCalls.People?
    @Published private(set) var items: [TeamCalls.Item] = []
    @Published private(set) var next: String?
    @Published private(set) var overview: TeamCalls.Overview?
    @Published private(set) var hits: [TeamCalls.Hit]?
    @Published private(set) var truncated = false
    @Published private(set) var loading = false
    @Published private(set) var problem: String?
    /// Projects and call types seen in the loaded calls, for their filters (the server has no list of the team's projects).
    @Published private(set) var projects: [ProjectRef] = []
    struct ProjectRef: Identifiable, Hashable { let id: String; let name: String }
    @Published private(set) var types: [String] = []

    private init() {
        NotificationCenter.default.addObserver(forName: PacenoteAccount.orgsChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { TeamStore.shared.clear() }
        }
    }

    /// The organizations whose Team tab the person gets (lead or C-level, the plan opens manager_view).
    static var orgs: [PacenoteServer.Org] {
        TeamCalls.orgs(PacenoteAccount.shared.me) { EntitlementsStore.shared.rights.can("manager_view", org: $0) }
    }
    static var visible: Bool { !orgs.isEmpty }

    var filter: TeamCalls.Filter {
        let (f, t) = TeamCalls.range(period, now: Date(), custom: (customFrom, customTo))
        var x = TeamCalls.Filter(from: f, to: t)
        x.person = person; x.team = team; x.project = project; x.type = type; x.recordedOnly = recordedOnly; x.series = series
        return x
    }

    /// Signed out or the organizations changed: nothing of the team's stays in memory.
    func clear() {
        people = nil; items = []; next = nil; overview = nil; hits = nil; problem = nil; projects = []; types = []
        if !Self.orgs.contains(where: { $0.id == orgID }) { orgID = Self.orgs.first?.id ?? "" }
    }

    func start() async {
        if orgID.isEmpty || !Self.orgs.contains(where: { $0.id == orgID }) { orgID = Self.orgs.first?.id ?? "" }
        guard !orgID.isEmpty else { return }
        if people == nil { await loadPeople() }
        await reload()
    }

    func switchOrg(_ id: String) async {
        orgID = id; person = ""; team = ""; project = ""; type = ""; series = ""; query = ""
        people = nil; hits = nil
        await start()
    }

    private func get(_ path: String) async -> (Data, Int)? {
        do { return try await PacenoteAccount.shared.api("GET", path) } catch {
            problem = L("team.err.network"); return nil
        }
    }

    private func failed(_ d: Data, _ c: Int) {
        let p = PacenoteServer.problem(d, status: c)
        problem = c == 403 ? L("team.err.plan") : (c == 429 ? L("team.err.slow") : L("team.err.server", ["text": p]))
    }

    func loadPeople() async {
        guard let r = await get(TeamCalls.peoplePath(org: orgID)) else { return }
        if r.1 == 200, let p = TeamCalls.people(r.0) { people = p } else { failed(r.0, r.1) }
    }

    /// The list or the overview, whichever is in front; a search in the box runs instead of the list.
    func reload() async {
        problem = nil
        if mode == .overview { await loadOverview(); return }
        if TeamCalls.searchable(query) { await runSearch(); return }
        hits = nil
        await loadCalls(more: false)
    }

    func loadCalls(more: Bool) async {
        guard !loading, !orgID.isEmpty else { return }
        loading = true; defer { loading = false }
        let t0 = Date()
        guard let r = await get(TeamCalls.listPath(org: orgID, filter: filter, cursor: more ? next : nil)) else { return }
        AnalyticsTracker.shared.perf("team_list", ms: Int(Date().timeIntervalSince(t0) * 1000), ok: r.1 == 200, o: orgID)
        guard r.1 == 200, let page = TeamCalls.page(r.0) else { failed(r.0, r.1); return }
        items = more ? items + page.items : page.items
        next = page.next
        var seen: [String: String] = [:]
        for i in items where !i.projectID.isEmpty && !i.projectName.isEmpty { seen[i.projectID] = i.projectName }
        for p in projects { seen[p.id] = seen[p.id] ?? p.name }
        projects = seen.map { ProjectRef(id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        types = Array(Set(types + items.map(\.callType).filter { !$0.isEmpty })).sorted()
    }

    func loadOverview() async {
        guard !loading, !orgID.isEmpty else { return }
        loading = true; defer { loading = false }
        guard let r = await get(TeamCalls.overviewPath(org: orgID, filter: filter)) else { return }
        if r.1 == 200, let o = TeamCalls.overview(r.0) { overview = o } else { failed(r.0, r.1) }
    }

    func runSearch() async {
        guard !loading, !orgID.isEmpty, TeamCalls.searchable(query) else { return }
        loading = true; defer { loading = false }
        AnalyticsTracker.shared.action("team_search", scr: "team_search", o: orgID)
        let t0 = Date()
        guard let r = await get(TeamCalls.searchPath(org: orgID, q: query, filter: filter)) else { return }
        AnalyticsTracker.shared.perf("team_search", ms: Int(Date().timeIntervalSince(t0) * 1000), ok: r.1 == 200, o: orgID)
        guard r.1 == 200, let s = TeamCalls.search(r.0) else { failed(r.0, r.1); return }
        hits = s.hits; truncated = s.truncated
    }

    func person(_ id: String) -> String {
        people?.people.first { $0.id == id }?.label ?? items.first { $0.ownerID == id }?.ownerName ?? ""
    }
}

// MARK: the tab

struct TeamView: View {
    @ObservedObject var store = TeamStore.shared
    @ObservedObject var acct = PacenoteAccount.shared
    @ObservedObject var nav = HomeNav.shared

    private var scr: String {
        store.mode == .overview ? "team_overview" : (store.hits != nil ? "team_search" : "team_calls")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)
            filters.padding(.horizontal, 20).padding(.bottom, 10)
            Divider()
            if let p = store.problem {
                Text(p).font(PN.Font.caption).foregroundStyle(PN.C.danger).padding(.horizontal, 20).padding(.vertical, 8)
            }
            if store.people?.people.isEmpty == true {
                empty(L("team.nobody"))
            } else if store.mode == .overview {
                TeamOverviewView()
            } else if let hits = store.hits {
                searchResults(hits)
            } else {
                callList
            }
        }
        .background(PN.C.bg)
        .task { await store.start() }
        .trackScreen(scr, o: store.orgID)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(L("team.tab")).font(.system(size: 15, weight: .semibold)).foregroundStyle(PN.C.text)
            if TeamStore.orgs.count > 1 {
                Picker("", selection: Binding(get: { store.orgID }, set: { id in Task { await store.switchOrg(id) } })) {
                    ForEach(TeamStore.orgs, id: \.id) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().fixedSize().accessibilityLabel(L("team.org"))
            }
            Text(L(store.people?.wholeOrg == true ? "team.note.org" : "team.note.lead")).font(PN.Font.caption)
                .foregroundStyle(PN.C.text2).lineLimit(1)
            Spacer()
            Picker("", selection: Binding(get: { store.mode }, set: { m in store.mode = m; Task { await store.reload() } })) {
                Text(L("team.mode.calls")).tag(TeamStore.Mode.calls)
                Text(L("team.mode.overview")).tag(TeamStore.Mode.overview)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize().accessibilityLabel(L("team.mode"))
            if store.loading { PNSpinner(size: 16) }
        }
    }

    private func reload() { Task { await store.reload() } }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker(L("team.f.period"), selection: $store.period) {
                    Text(L("team.p.7")).tag(TeamCalls.Period.days7)
                    Text(L("team.p.30")).tag(TeamCalls.Period.days30)
                    Text(L("team.p.90")).tag(TeamCalls.Period.days90)
                    Text(L("team.p.quarter")).tag(TeamCalls.Period.quarter)
                    Text(L("team.p.custom")).tag(TeamCalls.Period.custom)
                }
                .fixedSize()
                if store.period == .custom {
                    DatePicker("", selection: $store.customFrom, displayedComponents: .date).labelsHidden().fixedSize()
                        .accessibilityLabel(L("team.f.from"))
                    DatePicker("", selection: $store.customTo, displayedComponents: .date).labelsHidden().fixedSize()
                        .accessibilityLabel(L("team.f.to"))
                }
                Picker(L("team.f.person"), selection: $store.person) {
                    Text(L("team.f.everyone")).tag("")
                    ForEach(store.people?.people ?? []) { Text($0.label).tag($0.id) }
                }
                .fixedSize()
                if (store.people?.teams.count ?? 0) > 1 {
                    Picker(L("team.f.team"), selection: $store.team) {
                        Text(L("team.f.allTeams")).tag("")
                        ForEach(store.people?.teams ?? []) { Text($0.name).tag($0.id) }
                    }
                    .fixedSize()
                }
                Spacer()
            }
            HStack(spacing: 10) {
                if store.mode == .calls {
                    Picker(L("team.f.project"), selection: $store.project) {
                        Text(L("team.f.allProjects")).tag("")
                        ForEach(store.projects) { Text($0.name).tag($0.id) }
                    }
                    .fixedSize()
                    Picker(L("team.f.type"), selection: $store.type) {
                        Text(L("team.f.allTypes")).tag("")
                        ForEach(store.types, id: \.self) { Text($0).tag($0) }
                    }
                    .fixedSize()
                    Toggle(L("team.f.recorded"), isOn: $store.recordedOnly).toggleStyle(.checkbox)
                    if !store.series.isEmpty {
                        Button { store.series = "" } label: { Label(L("team.f.seriesOff"), systemImage: "xmark.circle") }
                            .buttonStyle(.pnTertiary)
                    }
                    Spacer()
                    TextField(L("team.search.prompt"), text: $store.query)
                        .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                        .onSubmit(reload)
                        .accessibilityLabel(L("team.search"))
                } else {
                    Spacer()
                }
            }
        }
        .font(PN.Font.body)
        .onChange(of: store.period) { _, _ in reload() }
        .onChange(of: store.customFrom) { _, _ in reload() }
        .onChange(of: store.customTo) { _, _ in reload() }
        .onChange(of: store.person) { _, _ in reload() }
        .onChange(of: store.team) { _, _ in reload() }
        .onChange(of: store.project) { _, _ in reload() }
        .onChange(of: store.type) { _, _ in reload() }
        .onChange(of: store.recordedOnly) { _, _ in reload() }
        .onChange(of: store.series) { _, _ in reload() }
        .onChange(of: store.query) { _, q in if q.isEmpty && store.hits != nil { reload() } }
    }

    private func empty(_ text: String) -> some View {
        VStack { Spacer(); Text(text).font(PN.Font.body).foregroundStyle(PN.C.text2).multilineTextAlignment(.center); Spacer() }
            .frame(maxWidth: .infinity).padding(20)
    }

    private var callList: some View {
        Group {
            if store.items.isEmpty && !store.loading {
                empty(L("team.empty"))
            } else {
                List {
                    ForEach(store.items) { i in
                        TeamCallRow(item: i).contentShape(Rectangle())
                            .onTapGesture { open(i, section: "summary", from: "team_calls") }
                            .contextMenu {
                                if !i.seriesKey.isEmpty {
                                    Button(L("team.series.all")) { store.series = i.seriesKey; store.person = i.ownerID }
                                }
                            }
                    }
                    if store.next != nil {
                        Button(L("team.more")) { Task { await store.loadCalls(more: true) } }.buttonStyle(.pnTertiary)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func searchResults(_ hits: [TeamCalls.Hit]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.truncated {
                Text(L("team.search.truncated")).font(PN.Font.caption).foregroundStyle(PN.C.pending)
                    .padding(.horizontal, 20).padding(.vertical, 6)
            }
            if hits.isEmpty {
                empty(L("team.search.none"))
            } else {
                List(hits) { h in
                    VStack(alignment: .leading, spacing: 4) {
                        TeamCallRow(item: h.call)
                        HStack(alignment: .top, spacing: 6) {
                            Text(L("team.field." + h.field)).pnLabel().foregroundStyle(PN.C.text3)
                            Text(h.snippet).font(PN.Font.caption).foregroundStyle(PN.C.text2).lineLimit(2)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { open(h.call, section: TeamCalls.section(forField: h.field), from: "team_search") }
                }
                .listStyle(.inset)
            }
        }
    }

    private func open(_ i: TeamCalls.Item, section: String, from: String) {
        AnalyticsTracker.shared.action("open_team_call", scr: from, o: store.orgID)
        nav.open(.teamCall(store.orgID, i.id, section))
    }
}

struct TeamCallRow: View {
    let item: TeamCalls.Item

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.ownerName.isEmpty ? L("team.someone") : item.ownerName).pnSection().foregroundStyle(PN.C.text)
                    Text(TeamCalls.title(item, privateLabel: L("team.private"), untitled: L("team.untitled")))
                        .font(PN.Font.body).foregroundStyle(item.isPrivate && item.title == nil ? PN.C.text3 : PN.C.text)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    if let s = item.start { Text(s.formatted(date: .abbreviated, time: .shortened)) }
                    Text(TeamCalls.length(item.durationS))
                    if !item.projectName.isEmpty { Text(item.projectName).lineLimit(1) }
                    if !item.callType.isEmpty { Text(item.callType) }
                }
                .font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            Spacer()
            HStack(spacing: 6) {
                if item.hasSheet { Image(systemName: "doc.text").help(L("team.mark.sheet")).accessibilityLabel(L("team.mark.sheet")) }
                if item.hasRecording { Image(systemName: "video").help(L("team.mark.rec")).accessibilityLabel(L("team.mark.rec")) }
                if item.hasSummary { Image(systemName: "text.alignleft").help(L("team.mark.summary")).accessibilityLabel(L("team.mark.summary")) }
                if item.isPrivate { Image(systemName: "lock").help(L("team.private.help")).accessibilityLabel(L("team.private")) }
            }
            .font(PN.Font.caption).foregroundStyle(PN.C.text3)
        }
        .padding(.vertical, 3)
    }
}

// MARK: overview

/// One row of the overview table; nil shares sort as -1 so they go last in a descending sort.
struct TeamOverviewRow: Identifiable {
    let id: String
    let name: String
    let n: TeamCalls.Numbers
    var calls: Int { n.calls }
    var hours: Double { n.hours }
    var sheet: Double { n.sheetShare ?? -1 }
    var tips: Int { n.tipsShown }
    var useful: Double { n.usefulShare ?? -1 }
    var asks: Int { n.askNow }
    var talk: Double { n.talkMedian ?? -1 }
    var topics: Double { n.topicsShare ?? -1 }
    var decisions: Int { n.decisions }
    var tasks: Int { n.tasksOpen }
    var risks: Int { n.risks }
    var recorded: Int { n.recorded }
}

struct TeamOverviewView: View {
    @ObservedObject var store = TeamStore.shared
    @State private var order = [KeyPathComparator(\TeamOverviewRow.calls, order: .reverse)]

    private var rows: [TeamOverviewRow] {
        (store.overview?.people ?? []).map { TeamOverviewRow(id: $0.id, name: $0.name.isEmpty ? store.person($0.id) : $0.name, n: $0.n) }
            .sorted(using: order)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let o = store.overview {
                summary(o.team).padding(.horizontal, 20).padding(.top, 12)
                weeks(o.weeks).padding(.horizontal, 20)
                Table(rows, sortOrder: $order) {
                    TableColumn(L("team.col.person"), value: \TeamOverviewRow.name)
                    TableColumn(L("team.col.calls"), value: \TeamOverviewRow.calls) { Text("\($0.calls)") + Text($0.n.privateCalls > 0 ? " (\($0.n.privateCalls))" : "").foregroundColor(PN.C.text3) }
                    TableColumn(L("team.col.hours"), value: \TeamOverviewRow.hours) { Text(TeamCalls.hours($0.hours)) }
                    TableColumn(L("team.col.rec"), value: \TeamOverviewRow.recorded) { Text("\($0.recorded)") }
                    TableColumn(L("team.col.sheet"), value: \TeamOverviewRow.sheet) { Text(TeamCalls.percent($0.n.sheetShare)) }
                    TableColumn(L("team.col.tips"), value: \TeamOverviewRow.useful) { Text("\($0.tips) / \(TeamCalls.percent($0.n.usefulShare)) / \($0.asks)") }
                    TableColumn(L("team.col.talk"), value: \TeamOverviewRow.talk) { Text(TeamCalls.percent($0.n.talkMedian)) }
                    TableColumn(L("team.col.topics"), value: \TeamOverviewRow.topics) { Text(TeamCalls.percent($0.n.topicsShare)) }
                    TableColumn(L("team.col.decisions"), value: \TeamOverviewRow.decisions) { Text("\($0.decisions) / \($0.risks)") }
                    TableColumn(L("team.col.tasks"), value: \TeamOverviewRow.tasks) { Text("\($0.n.tasksOpen) / \($0.n.tasksClosed)") }
                }
                .font(PN.Font.caption)
                Text(L("team.overview.note")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 20).padding(.bottom, 10)
            } else if !store.loading {
                Text(L("team.empty")).font(PN.Font.body).foregroundStyle(PN.C.text2).padding(20)
            }
        }
    }

    private func summary(_ n: TeamCalls.Numbers) -> some View {
        Text(L("team.overview.line", ["calls": "\(n.calls)", "private": "\(n.privateCalls)", "hours": TeamCalls.hours(n.hours),
                                      "sheet": TeamCalls.percent(n.sheetShare), "useful": TeamCalls.percent(n.usefulShare),
                                      "decisions": "\(n.decisions)", "open": "\(n.tasksOpen)", "risks": "\(n.risks)"]))
            .font(PN.Font.body).foregroundStyle(PN.C.text).fixedSize(horizontal: false, vertical: true)
    }

    /// Calls by week as small bars (the shape only; the numbers are in the table and on hover).
    private func weeks(_ w: [TeamCalls.Week]) -> some View {
        let top = max(w.map(\.n.calls).max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 4) {
            ForEach(w) { x in
                RoundedRectangle(cornerRadius: PN.r(2)).fill(PN.C.brand)
                    .frame(width: 14, height: max(2, 40 * CGFloat(x.n.calls) / CGFloat(top)))
                    .help(L("team.week.help", ["week": x.week, "calls": "\(x.n.calls)", "hours": TeamCalls.hours(x.n.hours)]))
            }
        }
        .frame(height: 42, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("team.weeks.a11y", ["n": "\(w.count)"]))
    }
}

// MARK: a colleague's call (read only)

struct TeamCallPage: View {
    let orgID: String
    let callID: String
    @State var section: String
    @State private var detail: TeamCalls.Detail?
    @State private var problem: String?

    private let sections = ["summary", "decisions", "tasks", "risks", "sheet", "people"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let d = detail {
                head(d).padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 8)
                if d.isPrivate && d.title == nil {
                    Text(L("team.private.page")).font(PN.Font.body).foregroundStyle(PN.C.text2).padding(20)
                    Spacer()
                } else {
                    Picker("", selection: $section) {
                        ForEach(sections, id: \.self) { Text(L("team.sec." + $0)).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20).padding(.bottom, 8)
                    Divider()
                    ScrollView { content(d).frame(maxWidth: .infinity, alignment: .leading).padding(20) }
                }
            } else if let p = problem {
                Text(p).font(PN.Font.body).foregroundStyle(PN.C.danger).padding(20)
                Spacer()
            } else {
                PNSpinner(size: 24).padding(20)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PN.C.bg)
        .task { await load() }
        .trackScreen("team_call_page", sub: section, o: orgID)
    }

    private func load() async {
        do {
            let (d, c) = try await PacenoteAccount.shared.api("GET", "/v1/calls/" + callID + "?" + TeamCalls.query([("org_id", orgID)]))
            if c == 200, let x = TeamCalls.detail(d) { detail = x } else { problem = L("team.err.server", ["text": PacenoteServer.problem(d, status: c)]) }
        } catch { problem = L("team.err.network") }
    }

    private func head(_ d: TeamCalls.Detail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(d.title ?? L("team.private")).font(.system(size: 18, weight: .semibold)).foregroundStyle(PN.C.text)
            HStack(spacing: 8) {
                if let s = d.start { Text(s.formatted(date: .abbreviated, time: .shortened)) }
                Text(TeamCalls.length(d.durationS))
                if !d.callType.isEmpty { Text(d.callType) }
                Text(L("team.readonly"))
            }
            .font(PN.Font.caption).foregroundStyle(PN.C.text3)
            HStack(spacing: 8) {
                if let u = d.recording {
                    Button(L("team.drive.rec")) {
                        AnalyticsTracker.shared.action("open_drive_recording", scr: "team_call_page", o: orgID)
                        NSWorkspace.shared.open(u)
                    }
                    .buttonStyle(.pnSecondary)
                }
                if let u = d.transcript {
                    Button(L("team.drive.transcript")) {
                        AnalyticsTracker.shared.action("open_drive_transcript", scr: "team_call_page", o: orgID)
                        NSWorkspace.shared.open(u)
                    }
                    .buttonStyle(.pnSecondary)
                }
            }
            if d.recording != nil || d.transcript != nil {
                Text(L("team.drive.note")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
        }
    }

    @ViewBuilder private func content(_ d: TeamCalls.Detail) -> some View {
        switch section {
        case "decisions": lines(d.decisions)
        case "tasks": lines(d.tasks)
        case "risks": lines(d.risks)
        case "sheet": sheet(d.sheet)
        case "people": people(d)
        default:
            if d.summary.isEmpty { muted(L("team.none")) } else {
                Text((try? AttributedString(markdown: d.summary, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                     ?? AttributedString(d.summary))
                    .font(PN.Font.body).textSelection(.enabled)
            }
        }
    }

    private func muted(_ s: String) -> some View { Text(s).font(PN.Font.body).foregroundStyle(PN.C.text3) }

    @ViewBuilder private func lines(_ l: [TeamCalls.Line]) -> some View {
        if l.isEmpty { muted(L("team.none")) } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(l) { x in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(x.text).font(PN.Font.body).textSelection(.enabled)
                        Text([x.who, x.due, x.status].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    }
                }
            }
        }
    }

    @ViewBuilder private func sheet(_ data: Data?) -> some View {
        if let data, let s = try? MeetingSheetIO.decode(data) {
            VStack(alignment: .leading, spacing: 12) {
                if let g = s.goal, !g.isEmpty { Text(g).font(PN.Font.body) }
                ForEach(s.blocks.filter(\.visible).sorted { $0.order < $1.order }) { b in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(b.title).pnSection()
                        ForEach(b.facts) { f in
                            Text((f.label.map { $0 + ": " } ?? "") + f.text).font(PN.Font.body).textSelection(.enabled)
                        }
                    }
                }
            }
        } else if data != nil {
            muted(L("team.sheet.unknown"))
        } else {
            muted(L("team.none"))
        }
    }

    private func people(_ d: TeamCalls.Detail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if d.participants.isEmpty { muted(L("team.none")) }
            ForEach(Array(d.participants.enumerated()), id: \.offset) { _, p in
                Text(p.name + (p.seconds > 0 ? " · " + TeamCalls.length(p.seconds) : "")).font(PN.Font.body)
            }
            if let a = d.analysis {
                Divider()
                Text(L("team.analysis", ["tips": "\(a.tipsShown)", "useful": TeamCalls.percent(a.usefulShare), "asks": "\(a.askNow)",
                                         "talk": TeamCalls.percent(a.talkMedian), "hit": "\(a.topicsHit)", "total": "\(a.topicsTotal)"]))
                    .font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: Settings > Account > Who viewed my calls (D47.7)

struct AccountCallViewsSection: View {
    @ObservedObject private var acct = PacenoteAccount.shared
    @State private var views: [TeamCalls.View]?
    @State private var failed = false
    @State private var open = false

    var body: some View {
        if acct.me?.orgs.contains(where: { !$0.visibleTo.isEmpty }) == true {
            Section {
                Text(L("views.note")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                if open {
                    if let v = views {
                        if v.isEmpty { Text(L("views.none")).foregroundStyle(PN.C.text2) }
                        ForEach(v) { x in
                            HStack {
                                Text(x.viewer).lineLimit(1)
                                Text(x.title.isEmpty ? L("team.untitled") : x.title).foregroundStyle(PN.C.text2).lineLimit(1)
                                Spacer()
                                if let at = x.at { Text(at.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(PN.C.text3) }
                            }
                            .font(PN.Font.caption)
                        }
                    } else if failed {
                        Text(L("usage.failed")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    } else {
                        PNSpinner(size: 16)
                    }
                } else {
                    HStack {
                        Button(L("views.show")) { open = true; Task { await load() } }.buttonStyle(.pnTertiary)
                        Spacer()
                    }
                }
            } header: { Text(L("views.head")).settingsAnchor("acc.views") }
        }
    }

    private func load() async {
        AnalyticsTracker.shared.screen("call_views")
        guard let r = try? await acct.api("GET", "/v1/me/call-views?days=90"), r.1 == 200, let v = TeamCalls.views(r.0) else { failed = true; return }
        views = v; failed = false
    }
}
