import AppKit
import SwiftUI
import LiveTipsCore

// 0.17.0 (server 0.7.0, D40, B6b contract 9 block 3): the shared card of an organization project, on the project page
// in Settings > Projects, and the line on the Meeting Sheet when someone else changed it after my last prep. The prep
// does not read the shared card yet (SEC-01 first, spec 5.5); the Mac's own card stays what the prep reads.

/// The shared cards I have read, by organization project; and when I last prepared each project.
@MainActor
final class OrgCardStore: ObservableObject {
    static let shared = OrgCardStore()
    @Published private(set) var cards: [String: OrgCard.Shared] = [:]
    @Published private(set) var problems: [String: String] = [:]

    private static func prepKey(_ orgProjectID: String) -> String { "pn.orgCardPrep." + orgProjectID }

    /// SheetRunner: a prep of this project finished (the time "since your last prep" counts from).
    static func notePrep(root: String) {
        let reg = ProjectRegistry.load(from: AppPaths.projects)
        guard let p = reg.projects.first(where: { !$0.root.isEmpty && ProjectRegistry.norm($0.root) == ProjectRegistry.norm(root) }),
              p.linkedToOrgProject else { return }
        UserDefaults.standard.set(Date(), forKey: prepKey(p.orgProjectID))
    }

    static func lastPrep(_ orgProjectID: String) -> Date? { UserDefaults.standard.object(forKey: prepKey(orgProjectID)) as? Date }

    func path(_ p: Project) -> String { "/v1/orgs/\(p.orgProjectOrg)/projects/\(p.orgProjectID)" }

    /// GET the card; nil with a problem in words.
    @discardableResult
    func load(_ p: Project) async -> OrgCard.Shared? {
        guard p.linkedToOrgProject, PacenoteAccount.shared.signedIn else { return nil }
        do {
            let (d, c) = try await PacenoteAccount.shared.api("GET", path(p))
            guard c == 200, let v = OrgCard.parse(d) else {
                problems[p.orgProjectID] = Self.problemText(c, d); return nil
            }
            cards[p.orgProjectID] = v; problems[p.orgProjectID] = nil
            return v
        } catch {
            problems[p.orgProjectID] = error.localizedDescription; return nil
        }
    }

    enum SaveResult { case saved(OrgCard.Shared), newer(OrgCard.Shared?), failed(String) }

    /// PATCH only the fields I changed, with If-Match on the version I started from.
    func save(_ p: Project, base: OrgCard.Shared, draft: OrgCard.Card) async -> SaveResult {
        let body = OrgCard.patch(base: base.card, draft: draft)
        guard !body.isEmpty else { return .saved(base) }
        do {
            let (d, c) = try await PacenoteAccount.shared.api("PATCH", path(p) + "/card", body: CallSync.json(body),
                                                              headers: ["If-Match": OrgCard.ifMatch(base.version)])
            switch OrgCard.outcome(status: c, problem: PacenoteServer.problem(d, status: c)) {
            case .saved:
                var v = OrgCard.parse(d) ?? base
                if v.id.isEmpty { v = base }
                cards[p.orgProjectID] = v
                UsageLog.log("org_card_saved", ["fields": v.changed.count])
                return .saved(v)
            case .newer: return .newer(await load(p))
            case .readOnly: return .failed(L("orgcard.err.readOnly"))
            case .gone: return .failed(L("orgcard.err.gone"))
            case .plan: return .failed(L("orgcard.err.plan"))
            case .invalid(let e), .failed(let e): return .failed(L("orgcard.err.other", ["e": e]))
            }
        } catch { return .failed(error.localizedDescription) }
    }

    static func problemText(_ c: Int, _ d: Data) -> String {
        switch c {
        case 403: return L("orgcard.err.noAccess")
        case 404: return L("orgcard.err.gone")
        case 402: return L("orgcard.err.plan")
        default: return L("orgcard.err.other", ["e": PacenoteServer.problem(d, status: c)])
        }
    }
}

/// Settings > Projects > a linked project: the organization project's card, the same for everyone on it.
struct OrgCardSection: View {
    @ObservedObject var model: SettingsModel
    let index: Int
    @ObservedObject private var store = OrgCardStore.shared
    @ObservedObject private var acct = PacenoteAccount.shared
    @State private var base: OrgCard.Shared?
    @State private var description = ""
    @State private var goal = ""
    @State private var clientName = ""
    @State private var clientSite = ""
    @State private var people = ""
    @State private var glossary = ""
    @State private var rules = ""
    @State private var languages = ""
    @State private var audience = ""
    @State private var busy = false
    @State private var note = ""
    @State private var noteIsError = false

    private var p: Project { model.registry.projects[index] }

    private var draft: OrgCard.Card {
        var c = OrgCard.Card()
        c.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        c.goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        c.clientName = clientName.trimmingCharacters(in: .whitespaces); c.clientSite = clientSite.trimmingCharacters(in: .whitespaces)
        c.people = OrgCard.people(people); c.glossary = OrgCard.glossary(glossary); c.rules = OrgCard.lines(rules)
        c.languages = OrgCard.languages(languages); c.audience = audience.trimmingCharacters(in: .whitespaces)
        return c
    }

    private var dirty: Bool { base.map { !OrgCard.edited(base: $0.card, draft: draft).isEmpty } ?? false }

    var body: some View {
        Section {
            if let b = base {
                Text(L("orgcard.sub", ["project": b.name.isEmpty ? p.orgProjectName : b.name]))
                    .font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                TextField(L("wiz.card.about"), text: $description, axis: .vertical).lineLimit(2...6)
                TextField(L("wiz.card.goal"), text: $goal, axis: .vertical).lineLimit(1...3)
                TextField(L("orgcard.client"), text: $clientName)
                TextField(L("orgcard.site"), text: $clientSite, prompt: Text("https://"))
                TextField(L("orgcard.people"), text: $people, prompt: Text(L("orgcard.peoplePrompt")), axis: .vertical).lineLimit(1...6)
                TextField(L("wiz.card.glossary"), text: $glossary, prompt: Text(L("orgcard.glossaryPrompt")), axis: .vertical).lineLimit(1...6)
                TextField(L("orgcard.rules"), text: $rules, prompt: Text(L("orgcard.rulesPrompt")), axis: .vertical).lineLimit(1...6)
                TextField(L("orgcard.languages"), text: $languages, prompt: Text("en, uk"))
                TextField(L("orgcard.audience"), text: $audience, prompt: Text(L("orgcard.audiencePrompt")))
                if !b.members.isEmpty {
                    LabeledContent(L("orgcard.members")) {
                        Text(b.members.map { $0.name.isEmpty ? "?" : $0.name }.joined(separator: ", "))
                            .foregroundStyle(PN.C.text2).multilineTextAlignment(.trailing)
                    }
                }
                HStack(spacing: 8) {
                    if let at = b.updatedAt, !b.updatedByName.isEmpty {
                        Text(L("orgcard.changedBy", ["who": b.updatedByID == acct.me?.userID.lowercased() ? L("orgcard.you") : b.updatedByName,
                                                     "when": at.formatted(date: .abbreviated, time: .shortened)]))
                            .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    }
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    if b.card.isEmpty && !dirty && hasLocal {
                        Button(L("orgcard.copyLocal")) { copyLocal() }.buttonStyle(.pnTertiary).help(L("orgcard.copyLocal.help"))
                    }
                    Button(L("orgcard.reload")) { Task { await reload(keepDraft: false) } }.buttonStyle(.pnTertiary).disabled(busy)
                    Button(L("common.save")) { Task { await save() } }.buttonStyle(.pnSecondary).disabled(busy || !dirty)
                }
            } else if let e = store.problems[p.orgProjectID] {
                HStack {
                    Text(e).font(PN.Font.caption).foregroundStyle(PN.C.pending).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(L("orgcard.reload")) { Task { await reload(keepDraft: false) } }.buttonStyle(.pnTertiary)
                }
            } else {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L("orgcard.loading")).foregroundStyle(PN.C.text3) }
            }
            if !note.isEmpty {
                Text(note).font(PN.Font.caption).foregroundStyle(noteIsError ? PN.C.danger : PN.C.text2).fixedSize(horizontal: false, vertical: true)
            }
            Text(L("orgcard.prepNote")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
        } header: { Text(L("orgcard.head")).settingsAnchor("pr.orgCard") }
        .task(id: p.orgProjectID) { await reload(keepDraft: false) }
    }

    private var hasLocal: Bool { !p.about.isEmpty || !p.client.isEmpty || !p.goal.isEmpty || !p.glossary.isEmpty }

    private func fill(_ c: OrgCard.Card) {
        description = c.description; goal = c.goal; clientName = c.clientName; clientSite = c.clientSite
        people = OrgCard.peopleText(c.people); glossary = OrgCard.glossaryText(c.glossary); rules = c.rules.joined(separator: "\n")
        languages = c.languages.joined(separator: ", "); audience = c.audience
    }

    private func copyLocal() {
        fill(OrgCard.fromLocal(about: p.about, client: p.client, goal: p.goal, glossary: p.glossary,
                               languages: [p.defaultLanguage, p.clientLanguage]))
        note = L("orgcard.copied"); noteIsError = false
    }

    private func reload(keepDraft: Bool) async {
        busy = true; defer { busy = false }
        if let v = await OrgCardStore.shared.load(p) {
            base = v
            if !keepDraft { fill(v.card); note = "" }
        }
    }

    private func save() async {
        guard let b = base else { return }
        busy = true; defer { busy = false }
        let mine = draft
        switch await OrgCardStore.shared.save(p, base: b, draft: mine) {
        case .saved(let v):
            base = v; fill(v.card); note = L("orgcard.saved"); noteIsError = false
        case .newer(let v):
            // someone saved meanwhile: my edits on top of theirs, field by field; nothing goes until I save again
            guard let v else { note = L("orgcard.err.newerNoRead"); noteIsError = true; return }
            let (merged, conflicts) = OrgCard.rebase(base: b.card, draft: mine, server: v.card)
            base = v; fill(merged)
            note = L(conflicts.isEmpty ? "orgcard.newer" : "orgcard.newerBoth",
                     ["who": v.updatedByName.isEmpty ? "?" : v.updatedByName,
                      "fields": conflicts.map { L("orgcard.field." + $0) }.joined(separator: ", ")])
            noteIsError = !conflicts.isEmpty
        case .failed(let e):
            note = e; noteIsError = true
        }
    }
}

/// The Meeting Sheet: "Project card changed by Emily since your last prep" (spec 3, safety: a changed instruction shows).
struct OrgCardChangedLine: View {
    let sheetPath: String
    @ObservedObject private var store = OrgCardStore.shared
    @ObservedObject private var acct = PacenoteAccount.shared

    private var project: Project? {
        let p = PyTool.project(of: sheetPath).project
        return (p?.linkedToOrgProject ?? false) ? p : nil
    }

    var body: some View {
        if let p = project {
            Group {
                if let v = store.cards[p.orgProjectID],
                   let who = OrgCard.changedSincePrep(v, lastPrep: OrgCardStore.lastPrep(p.orgProjectID), me: acct.me?.userID ?? "") {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.bubble").foregroundStyle(PN.C.pending)
                        Text(L("orgcard.changedSincePrep", ["who": who])).font(PN.Font.caption).foregroundStyle(PN.C.text2)
                        Spacer(minLength: 4)
                        Button(L("orgcard.open")) {
                            SettingsWindow.show(tab: "projects")
                            SettingsWindow.model.projectDetail = p.slug
                        }
                        .buttonStyle(.pnTertiary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(PN.C.pending.opacity(0.08), in: RoundedRectangle(cornerRadius: PN.Radius.m))
                } else {
                    EmptyView()
                }
            }
            .task(id: p.orgProjectID) { await store.load(p) }
        }
    }
}
