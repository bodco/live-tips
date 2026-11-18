import AppKit
import SwiftUI
import LiveTipsCore

// 0.17.0 (server 0.7.0, D40, B6b contract 9 block 4, spec 4.1): my colleagues' decisions, tasks and risks in the
// Tracker, from the registers of the organization projects my projects are linked to. A row says whose call it came
// from ("from Mike's call, Nov 12") and never links to a colleague's call. Status, owner and due date change by the
// server's `can_edit`, deleting by `can_delete`; everyone else reads.

@MainActor
final class OrgRegisterStore: ObservableObject {
    static let shared = OrgRegisterStore()

    /// One linked organization project: the Mac project it shows under, and its items.
    struct Linked: Equatable {
        var org: String, orgProject: String, projectName: String, workspace: String
    }

    @Published private(set) var items: [String: [OrgRegister.Item]] = [:]       // by organization project
    @Published private(set) var linked: [Linked] = []
    @Published private(set) var problems: [String: String] = [:]
    @Published private(set) var loading = false
    @Published var note = ""
    @Published var noteIsError = false

    var me: String { PacenoteAccount.shared.me?.userID.lowercased() ?? "" }

    /// The organization projects my Mac projects are linked to (each once; the first Mac project names it).
    static func linkedProjects() -> [Linked] {
        let reg = ProjectRegistry.load(from: AppPaths.projects)
        var seen = Set<String>(), out: [Linked] = []
        for p in reg.projects where p.status != "archived" && p.linkedToOrgProject && seen.insert(p.orgProjectID).inserted {
            out.append(Linked(org: p.orgProjectOrg, orgProject: p.orgProjectID, projectName: p.name, workspace: p.workspace))
        }
        return out
    }

    /// GET the registers of every linked organization project (and the people on each, for owner names).
    func reload() async {
        guard PacenoteAccount.shared.signedIn else { items = [:]; linked = []; return }
        let ls = Self.linkedProjects()
        linked = ls
        guard !ls.isEmpty else { items = [:]; return }
        loading = true; defer { loading = false }
        for l in ls {
            do {
                let (d, c) = try await PacenoteAccount.shared.api("GET", OrgRegister.listPath(org: l.org, project: l.orgProject))
                if c == 200, let v = OrgRegister.parse(d) {
                    items[l.orgProject] = OrgRegister.fromColleagues(v); problems[l.orgProject] = nil
                } else {
                    items[l.orgProject] = nil; problems[l.orgProject] = OrgCardStore.problemText(c, d)
                }
            } catch {
                problems[l.orgProject] = error.localizedDescription
            }
            if OrgCardStore.shared.cards[l.orgProject] == nil, let p = project(l.orgProject) { await OrgCardStore.shared.load(p) }
        }
        for k in items.keys where !ls.contains(where: { $0.orgProject == k }) { items[k] = nil }
    }

    func project(_ orgProject: String) -> Project? {
        ProjectRegistry.load(from: AppPaths.projects).projects.first { $0.orgProjectID == orgProject && $0.linkedToOrgProject }
    }

    func members(_ orgProject: String) -> [OrgCard.Member] { OrgCardStore.shared.cards[orgProject]?.members ?? [] }

    /// "changed by Emily" under a row; "you" when it was me.
    func editedBy(_ i: OrgRegister.Item, _ orgProject: String) -> String? {
        guard let n = OrgRegister.editedByOther(i, members: members(orgProject)) else { return nil }
        return !me.isEmpty && i.editedBy == me ? L("orgcard.you") : n
    }

    /// The Tracker rows: one per colleague item.
    func trackerItems() -> [TrackerItem] {
        let lang = L10n.lang
        return linked.flatMap { l -> [TrackerItem] in
            (items[l.orgProject] ?? []).map { i in
                let kind: TrackerItem.Kind = i.kind == .task ? .task : i.kind == .decision ? .decision : .risk
                let owner = OrgRegister.givenToMe(i, me: me) ? "me" : i.who
                return TrackerItem(id: "o:" + i.id, kind: kind, title: i.text, project: l.projectName, workspace: l.workspace,
                                   owner: owner, due: i.due, date: OrgRegister.callDay(i, lang: lang), status: i.status,
                                   callTitle: L("orgreg.from", ["who": i.authorName.isEmpty ? "?" : i.authorName, "day": OrgRegister.callDay(i, lang: lang)]),
                                   orgItem: i, orgProject: l.orgProject)
            }
        }
    }

    /// PATCH one item; the row shows the change at once, the list is read again after.
    func change(_ i: OrgRegister.Item, orgProject: String, _ c: OrgRegister.Change) async {
        guard let l = linked.first(where: { $0.orgProject == orgProject }) else { return }
        let body = OrgRegister.patch(i, c)
        guard !body.isEmpty else { return }
        do {
            let (d, code) = try await PacenoteAccount.shared.api("PATCH", OrgRegister.itemPath(org: l.org, project: orgProject, i),
                                                                 body: CallSync.json(body), headers: ["If-Match": OrgRegister.ifMatch(i)])
            switch OrgRegister.outcome(status: code, problem: PacenoteServer.problem(d, status: code)) {
            case .saved:
                let name = c.owner.map { OrgRegister.name($0, members: members(orgProject)) } ?? ""
                let n = OrgRegister.applied(i, c, answer: d, me: me, ownerName: name)
                if var list = items[orgProject], let k = list.firstIndex(where: { $0.id == i.id }) { list[k] = n; items[orgProject] = list }
                say("")
                UsageLog.log("org_register_changed", ["kind": i.kind.rawValue])
            case .newer: say(L("orgreg.err.newer"), error: true)
            case .readOnly: say(L("orgreg.err.readOnly"), error: true)
            case .gone: say(L("orgreg.err.gone"), error: true)
            case .plan: say(L("orgcard.err.plan"), error: true)
            case .invalid(let e), .failed(let e): say(L("orgcard.err.other", ["e": e]), error: true)
            }
        } catch { say(error.localizedDescription, error: true) }
        await reload()
    }

    func delete(_ i: OrgRegister.Item, orgProject: String) async {
        guard let l = linked.first(where: { $0.orgProject == orgProject }) else { return }
        do {
            let (d, code) = try await PacenoteAccount.shared.api("DELETE", OrgRegister.itemPath(org: l.org, project: orgProject, i))
            switch OrgRegister.outcome(status: code, problem: PacenoteServer.problem(d, status: code)) {
            case .saved, .gone:
                items[orgProject]?.removeAll { $0.id == i.id }
                say(L("orgreg.deleted"))
                UsageLog.log("org_register_deleted", ["kind": i.kind.rawValue])
            case .readOnly: say(L("orgreg.err.readOnly"), error: true)
            case .plan: say(L("orgcard.err.plan"), error: true)
            case .newer, .invalid, .failed: say(L("orgcard.err.other", ["e": PacenoteServer.problem(d, status: code)]), error: true)
            }
        } catch { say(error.localizedDescription, error: true) }
        await reload()
    }

    private func say(_ s: String, error: Bool = false) { note = s; noteIsError = error }
}

/// The due date of a colleague's task, or deleting an item: a small sheet (never an NSAlert).
struct OrgItemSheet: View {
    enum Mode: Identifiable {
        case due(TrackerItem), delete(TrackerItem)
        var id: String { switch self { case .due(let r): return "due" + r.id; case .delete(let r): return "del" + r.id } }
    }
    let mode: Mode
    var close: () -> Void
    @State private var day = Date()
    @State private var busy = false

    private static let iso: DateFormatter = {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch mode {
            case .due(let r):
                Text(L("orgreg.due.title")).font(.headline)
                Text(r.title).font(PN.Font.body).foregroundStyle(PN.C.text2).lineLimit(3)
                DatePicker(L("orgreg.due.label"), selection: $day, displayedComponents: .date).datePickerStyle(.field)
                HStack {
                    if !(r.orgItem?.due.isEmpty ?? true) {
                        Button(L("orgreg.due.clear")) { run { await save(r, "") } }.buttonStyle(.pnTertiary)
                    }
                    Spacer()
                    if busy { PNSpinner(size: 16) }
                    Button(L("common.cancel")) { close() }.buttonStyle(.pnTertiary).keyboardShortcut(.cancelAction)
                    Button(L("common.save")) { run { await save(r, Self.iso.string(from: day)) } }.buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
                }
            case .delete(let r):
                Text(L("orgreg.delete.title")).font(.headline)
                Text(r.title).font(PN.Font.body).foregroundStyle(PN.C.text2).lineLimit(3)
                Text(L("orgreg.delete.sub", ["who": r.orgItem?.authorName ?? "?"])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    if busy { PNSpinner(size: 16) }
                    Button(L("common.cancel")) { close() }.buttonStyle(.pnTertiary).keyboardShortcut(.cancelAction)
                    Button(L("orgreg.delete.ok"), role: .destructive) {        // deleting is never the Return key
                        run { if let i = r.orgItem { await OrgRegisterStore.shared.delete(i, orgProject: r.orgProject) } }
                    }.buttonStyle(.pnPrimary)
                }
            }
        }
        .padding(20).frame(width: 420)
        .disabled(busy)
        .onAppear {
            if case .due(let r) = mode, let d = r.orgItem?.due, let x = Self.iso.date(from: d) { day = x }
        }
    }

    private func save(_ r: TrackerItem, _ due: String) async {
        guard let i = r.orgItem else { return }
        await OrgRegisterStore.shared.change(i, orgProject: r.orgProject, .init(due: due))
    }

    private func run(_ f: @escaping () async -> Void) {
        busy = true
        Task { await f(); busy = false; close() }
    }
}

/// The context menu of a colleague's row: status, owner and due date when the server lets me, delete when it lets me.
struct OrgItemMenu: View {
    let row: TrackerItem
    @Binding var sheet: OrgItemSheet.Mode?
    @ObservedObject private var store = OrgRegisterStore.shared

    var body: some View {
        if let i = row.orgItem {
            if i.canEdit {
                Menu(L("orgreg.status")) {
                    ForEach(OrgRegister.statuses(i.kind), id: \.self) { s in
                        Button((s == i.status ? "✓ " : "") + L("orgreg.st." + i.kind.rawValue + "." + s)) {
                            Task { await store.change(i, orgProject: row.orgProject, .init(status: s)) }
                        }
                    }
                }
                if i.kind == .task {
                    Menu(L("orgreg.owner")) {
                        ForEach(store.members(row.orgProject)) { m in
                            Button((m.id == i.ownerUserID ? "✓ " : "") + (m.id == store.me ? L("series.me") : (m.name.isEmpty ? "?" : m.name))) {
                                Task { await store.change(i, orgProject: row.orgProject, .init(owner: m.id)) }
                            }
                        }
                        Divider()
                        Button(L("orgreg.owner.none")) { Task { await store.change(i, orgProject: row.orgProject, .init(owner: "")) } }
                            .disabled(i.ownerUserID.isEmpty)
                    }
                    Button(L("orgreg.due") + "…") { sheet = .due(row) }
                }
            } else {
                Text(L(i.kind == .task ? "orgreg.readOnly.task" : "orgreg.readOnly"))
            }
            if i.canDelete {
                Divider()
                Button(L("orgreg.delete") + "…") { sheet = .delete(row) }
            }
            Divider()
        }
    }
}
