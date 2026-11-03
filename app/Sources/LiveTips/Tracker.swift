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

    static func == (a: TrackerItem, b: TrackerItem) -> Bool { a.id == b.id && a.status == b.status }
    func hash(into h: inout Hasher) { h.combine(id) }

    var done: Bool {
        let s = status.lowercased()
        return ["done", "closed", "resolved", "superseded", "cancelled", "canceled", "mitigated", "готово", "закрито"].contains(s)
    }
    var dueDate: Date? { CommitmentRegister.dueDate(due, from: Date()) }
}

@MainActor
final class TrackerModel: ObservableObject {
    static let shared = TrackerModel()
    @Published var items: [TrackerItem] = []
    @Published var loading = false
    @Published var mirrorAt: Date?

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
                               callTitle: Register.shared.transcript(c).flatMap { f in CallHistory.shared.records.first { $0.file == f }?.title } ?? (c.series.split(separator: "|").last.map(String.init) ?? ""),
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

    private var notionOn: Bool { SettingsWindow.model.isSet(.notionToken) }
    private var me: [String] { ["me"] + SettingsWindow.model.config.nameAliases.map { $0.lowercased() } }

    private func isMine(_ i: TrackerItem) -> Bool {
        let o = i.owner.lowercased()
        return o == "me" || (!o.isEmpty && me.contains { !$0.isEmpty && o.contains($0) })
    }

    private func list(_ k: TrackerItem.Kind) -> [TrackerItem] {
        let q = find.lowercased()
        return model.items.filter { i in
            i.kind == k
                && (ws.isEmpty || i.workspace.contains(ws))
                && (project.isEmpty || i.project == project)
                && (call.isEmpty || i.callTitle == call)
                && (owner == "anyone" || k != .task || (owner == "me" ? isMine(i) : !isMine(i)))
                && (status == "all" || (status == "done" ? i.done : !i.done))
                && (q.isEmpty || i.title.lowercased().contains(q) || i.project.lowercased().contains(q))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("home.nav.tracker")).font(.system(size: 24, weight: .bold)).foregroundStyle(PN.C.text)
                        Text(subline).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    }
                    Spacer()
                    if model.loading { ProgressView().controlSize(.small) }
                    Button(L(tab == "tasks" ? "tracker.newTask" : tab == "decisions" ? "tracker.newDecision" : "tracker.newRisk")) { newItem() }
                        .buttonStyle(.pnPrimary)
                }
                if !notionOn {
                    HStack(spacing: 10) {
                        Text(L("tracker.localBanner")).font(PN.Font.body).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button(L("export.connectNotion")) { SettingsWindow.show(tab: "notion") }.buttonStyle(.pnSecondary)
                    }
                    .padding(14).background(PN.C.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: PN.Radius.m))
                }
                PageTabs(tabs: [("tasks", L("page.tab.tasks") + " \(list(.task).count)"), ("decisions", L("page.tab.decisions") + " \(list(.decision).count)"),
                                ("risks", L("page.tab.risks") + " \(list(.risk).count)")], selection: $tab)
                filters
                if newOpen { newTaskRow }
                table
            }
            .padding(24).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)      // centred
        }
        .onAppear { model.reload() }
        .onChange(of: register.version) { model.reload() }
    }

    private var subline: String {
        guard notionOn else { return L("tracker.kept") }
        guard let d = model.mirrorAt else { return L("tracker.synced", ["ago": "-"]) }
        let f = RelativeDateTimeFormatter(); f.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US"); f.unitsStyle = .short
        return L("tracker.synced", ["ago": f.localizedString(for: d, relativeTo: Date())])
    }

    private var filters: some View {
        let projects = Array(Set(model.items.map(\.project).filter { !$0.isEmpty })).sorted()
        let wss = Array(Set(model.items.flatMap { $0.workspace.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }.filter { !$0.isEmpty })).sorted()
        let calls = Array(Set(model.items.map(\.callTitle).filter { !$0.isEmpty })).sorted()
        return HStack(spacing: 10) {
            Picker(L("tracker.f.workspace"), selection: $ws) { Text(L("tracker.all")).tag(""); ForEach(wss, id: \.self) { Text($0).tag($0) } }.fixedSize()
            Picker(L("call.project"), selection: $project) { Text(L("tracker.all")).tag(""); ForEach(projects, id: \.self) { Text($0).tag($0) } }.fixedSize()
            Picker(L("tracker.f.call"), selection: $call) { Text(L("tracker.all")).tag(""); ForEach(calls, id: \.self) { Text($0).tag($0) } }.fixedSize()
            if tab == "tasks" {
                Picker(L("tracker.f.owner"), selection: $owner) {
                    Text(L("series.me")).tag("me"); Text(L("tracker.anyone")).tag("anyone"); Text(L("tracker.others")).tag("others")
                }.fixedSize()
            }
            Picker(L("tracker.f.status"), selection: $status) {
                Text(L("tracker.open")).tag("open"); Text(L("page.tasks.done")).tag("done"); Text(L("tracker.all")).tag("all")
            }.fixedSize()
            TextField(L("tracker.find"), text: $find).textFieldStyle(.roundedBorder).frame(minWidth: 140)
        }
        .font(PN.Font.caption)
    }

    // MARK: table, grouped

    @ViewBuilder private var table: some View {
        switch tab {
        case "decisions":
            let all = list(.decision)
            let waiting = all.filter { ["proposed", "draft", "pending", "waiting"].contains($0.status.lowercased()) }
            groupView(L("tracker.g.waiting"), waiting, danger: false)
            groupView(L("tracker.g.confirmed"), all.filter { !waiting.contains($0) }, danger: false)
        case "risks":
            groupView(L("tracker.g.open"), list(.risk), danger: false)
        default:
            let all = list(.task)
            let today = Calendar.current.startOfDay(for: Date())
            let week = Calendar.current.date(byAdding: .day, value: 7, to: today) ?? today
            let overdue = all.filter { ($0.dueDate.map { $0 < today } ?? false) && !$0.done }
            let thisWeek = all.filter { d in !overdue.contains(d) && (d.dueDate.map { $0 < week } ?? false) }
            groupView(L("tracker.g.overdue"), overdue, danger: true)
            groupView(L("tracker.g.week"), thisWeek, danger: false)
            groupView(L("tracker.g.later"), all.filter { !overdue.contains($0) && !thisWeek.contains($0) }, danger: false)
        }
    }

    @ViewBuilder private func groupView(_ title: String, _ rows: [TrackerItem], danger: Bool) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(title.uppercased() + " · \(rows.count)").font(PN.Font.label).foregroundStyle(danger ? PN.C.danger : PN.C.text3)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                ForEach(rows.sorted { ($0.dueDate ?? .distantFuture, $0.title) < ($1.dueDate ?? .distantFuture, $1.title) }) { r in
                    Divider()
                    row(r, danger: danger)
                }
            }
            .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.m))
        }
    }

    private func row(_ r: TrackerItem, danger: Bool) -> some View {
        let third = r.kind == .task ? (isMine(r) ? L("series.me") : r.owner) : r.kind == .decision ? r.date : r.impact
        let fourth = r.kind == .task ? (r.due.isEmpty ? "" : Register.dueText(r.due)) : r.status
        return HStack(spacing: 12) {
            if r.kind == .task {
                Toggle("", isOn: Binding(get: { r.done }, set: { _ in if let c = r.commitment { register.mark(c) } else if let u = URL(string: r.url) { NSWorkspace.shared.open(u) } }))
                    .toggleStyle(.checkbox).labelsHidden().accessibilityLabel(L("reg.markDoneA11y", ["text": r.title]))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(r.title).font(PN.Font.body).foregroundStyle(PN.C.text).lineLimit(2)
                if r.local { Text(L("tracker.kept")).font(.system(size: 10)).foregroundStyle(PN.C.text3) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(r.project).font(PN.Font.caption).foregroundStyle(PN.C.text2).frame(width: 140, alignment: .leading).lineLimit(1)
            Group {
                if !r.callFile.isEmpty {
                    Button(r.callTitle.isEmpty ? L("tracker.call") : r.callTitle) { CallPageWindow.show(file: r.callFile) }
                        .buttonStyle(.plain).foregroundStyle(PN.C.accent)
                } else { Text(r.callTitle).foregroundStyle(PN.C.text3) }
            }
            .font(PN.Font.caption).frame(width: 140, alignment: .leading).lineLimit(1)
            Text(third).font(PN.Font.caption).foregroundStyle(PN.C.text2).frame(width: 110, alignment: .leading).lineLimit(1)
            Text(fourth).font(PN.Font.caption).foregroundStyle(danger && r.kind == .task ? PN.C.danger : PN.C.text2).frame(width: 90, alignment: .leading).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if let u = URL(string: r.url), !r.url.isEmpty { NSWorkspace.shared.open(u) } }
        .contextMenu {
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
        return HStack(spacing: 8) {
            TextField(L("page.tasks.addPh"), text: $newText).textFieldStyle(.roundedBorder).onSubmit(addTask)
            Picker("", selection: $newProject) {
                Text(L("call.chooseProject")).tag("")
                ForEach(reg.projects.filter { $0.status != "archived" }, id: \.slug) { p in Text(p.name).tag(p.slug) }
            }.labelsHidden().fixedSize()
            Button(L("page.tasks.add"), action: addTask).buttonStyle(.pnSecondary).disabled(newText.trimmingCharacters(in: .whitespaces).isEmpty || newProject.isEmpty)
        }
    }

    private func addTask() {
        let reg = ProjectRegistry.load(from: AppPaths.projects)
        guard let p = reg.projects.first(where: { $0.slug == newProject }), !p.root.isEmpty else { return }
        let t = newText.trimmingCharacters(in: .whitespaces); guard !t.isEmpty else { return }
        register.add(folder: (p.root as NSString).appendingPathComponent("live"), text: t, owner: "me", project: p.slug, title: "", call: "")
        newText = ""; newOpen = false
    }
}
