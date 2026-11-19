import AppKit
import SwiftUI
import LiveTipsCore

/// 0.17.0 (spec 5.2, D39): "New project", one window, up to five steps; every step after the first can be skipped.
/// 1 name and where (personal space or a team organization: a new organization project or one I am on),
/// 2 the folder (new in a workspace, or one that exists), 3 the card, 4 sources, 5 people (new organization project,
/// only for those who make them, D38). Nothing goes to the server but the organization project and the link.
@MainActor
final class ProjectWizardModel: ObservableObject {
    enum OrgMode: String { case none, join, create }
    enum FolderMode: String { case new, existing }

    let settings: SettingsModel
    @Published var step: ProjectWizardCore.Step = .name
    @Published var name = ""
    @Published var orgID = ""                 // "" = where new calls go now
    @Published var orgMode: OrgMode = .none
    @Published var orgProjectID = ""
    @Published var folderMode: FolderMode = .new
    @Published var parent = ""                // workspace for a new folder
    @Published var existing = ""              // an existing folder
    @Published var about = ""
    @Published var client = ""
    @Published var goal = ""
    @Published var language = ""
    @Published var clientLanguage = ""
    @Published var glossary = ""
    @Published var linksText = ""
    @Published var members: [ProjectWizardCore.Member] = []
    @Published var picked = Set<String>()
    @Published var membersNote = ""
    @Published var busy = false
    @Published var error = ""

    init(settings: SettingsModel, orgID: String = "") {
        self.settings = settings
        self.orgID = orgID                    // 0.17.0 (5.3): from the organization setup, already there
        parent = ProjectWizardCore.parent(workRoot: settings.config.workRoot, workspaces: settings.registry.workspaces.map(\.root))
        language = settings.config.uiLanguage.isEmpty ? "en" : settings.config.uiLanguage
    }

    var acct: PacenoteAccount { PacenoteAccount.shared }
    var teamOrgs: [PacenoteServer.Org] { acct.me?.orgs.filter { !$0.isPersonal } ?? [] }
    var org: PacenoteServer.Org? { acct.me?.org(orgID) }
    var isTeam: Bool { org.map { !$0.isPersonal } ?? false }
    var canCreate: Bool { (org?.orgProjects ?? false) && (org?.canManage ?? false) }
    var steps: [ProjectWizardCore.Step] { ProjectWizardCore.steps(newOrgProject: isTeam && orgMode == .create, canManage: canCreate) }
    var isLast: Bool { steps.last == step }
    var stepNumber: Int { (steps.firstIndex(of: step) ?? 0) + 1 }

    var nameOK: Bool {
        if isTeam && orgMode == .join { return !orgProjectID.isEmpty }
        return !ProjectWizardCore.folderName(name).isEmpty
    }
    var folderPath: String {
        folderMode == .existing ? existing
            : ProjectWizardCore.newFolder(parent: parent, name: name, exists: { FileManager.default.fileExists(atPath: $0) })
    }

    func next() {
        error = ""
        if step == .name, isTeam, orgMode == .join, let op = acct.orgProjects[orgID]?.first(where: { $0.id == orgProjectID }), name.isEmpty {
            name = op.name
        }
        if let i = steps.firstIndex(of: step), i + 1 < steps.count { step = steps[i + 1] }
        if step == .people { Task { await loadMembers() } }
    }
    func back() { if let i = steps.firstIndex(of: step), i > 0 { step = steps[i - 1] } }

    func chooseExisting() {
        if let d = settings.chooseFolder(L("set.chooseProject")) { existing = d; folderMode = .existing }
    }

    func loadMembers() async {
        guard members.isEmpty, isTeam else { return }
        do {
            let (d, c) = try await acct.api("GET", "/v1/orgs/\(orgID)/members")
            guard c == 200 else { membersNote = L("wiz.people.cant", ["code": "\(c)"]); return }
            members = ProjectWizardCore.members(((try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]]) ?? [],
                                                me: acct.me?.userID ?? "")
            if members.isEmpty { membersNote = L("wiz.people.none") }
        } catch { membersNote = error.localizedDescription }
    }

    /// Makes the folder and the project; for a team organization links it (and makes the organization project first).
    /// Returns the new project's slug, or nil with `error` set.
    func finish() async -> String? {
        error = ""
        let dir = folderPath
        guard !dir.isEmpty else { error = L(settings.config.workRoot.isEmpty ? "set.setTheWorkFolder" : "wiz.err.folder"); return nil }
        if let r = settings.registry.projects.first(where: { ProjectRegistry.norm($0.root) == ProjectRegistry.norm(dir) }) {
            error = L("wiz.err.known", ["name": r.name]); return nil
        }
        busy = true; defer { busy = false }
        // 1. the organization project, before anything is written on the Mac
        var link: PacenoteServer.OrgProject?
        if isTeam && orgMode == .create {
            do {
                let body = try JSONSerialization.data(withJSONObject: ProjectWizardCore.orgProjectBody(name: name, memberIDs: Array(picked)))
                let (d, c) = try await acct.api("POST", "/v1/orgs/\(orgID)/projects", body: body)
                guard c == 201 || c == 200, let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                      let id = o["id"] as? String else { error = L("wiz.err.orgProject", ["code": "\(c)"]); return nil }
                link = PacenoteServer.OrgProject(id: id, name: (o["name"] as? String) ?? name)
                await acct.loadOrgProjects(orgID)
            } catch { self.error = error.localizedDescription; return nil }
        } else if isTeam && orgMode == .join {
            link = acct.orgProjects[orgID]?.first { $0.id == orgProjectID }
        }
        // 2. the folder and the project
        let fm = FileManager.default
        if folderMode == .new {
            do { try fm.createDirectory(atPath: dir, withIntermediateDirectories: true) } catch { self.error = error.localizedDescription; return nil }
        }
        let ws = (dir as NSString).deletingLastPathComponent
        let knownWS = settings.registry.workspaces.contains { ProjectRegistry.norm($0.root) == ProjectRegistry.norm(ws) }
        let display = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (dir as NSString).lastPathComponent : name.trimmingCharacters(in: .whitespacesAndNewlines)
        if folderMode == .new && !knownWS && ProjectRegistry.norm(ws).hasPrefix(ProjectRegistry.norm(settings.config.workRoot) + "/") {
            settings.addWorkspace(ws)                  // a new "My workspace": a workspace, not a candidate in the list
        }
        if !settings.registry.projects.contains(where: { ProjectRegistry.norm($0.root) == ProjectRegistry.norm(dir) }) {
            var p = Project(name: display, slug: WorkspaceScanner.slug((dir as NSString).lastPathComponent), root: dir)
            p.workspace = (ws as NSString).lastPathComponent
            settings.registry.excluded.removeAll { $0 == dir }
            settings.registry.merge(folders: [p])
            settings.rescanWorkspaces()
        }
        guard let i = settings.registry.projects.firstIndex(where: { ProjectRegistry.norm($0.root) == ProjectRegistry.norm(dir) }) else {
            error = L("wiz.err.folder"); return nil
        }
        var p = settings.registry.projects[i]
        p.name = display; p.status = "active"
        p.about = String(about.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
        p.client = client.trimmingCharacters(in: .whitespacesAndNewlines)
        p.goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        p.defaultLanguage = language; p.clientLanguage = clientLanguage
        p.glossary = ProjectWizardCore.glossary(glossary)
        p.links = ProjectWizardCore.links(linksText)
        if let l = link {
            p.orgProjectID = l.id; p.orgProjectOrg = orgID; p.orgProjectName = l.name
            p.serverSync = true                                     // D40.6: linking turns the sync on
        } else if !orgID.isEmpty && orgID != acct.me?.defaultOrgID {
            p.orgID = orgID                                         // new calls of this project go there
        }
        settings.registry.projects[i] = p
        settings.note = L("set.added", ["name": p.name])
        IndexService.shared.configure(projects: settings.registry.projects, appRoot: CallEngine.shared.appRoot,
                                      python: settings.config.engine.python, enabled: settings.config.localAI.enabled)
        UsageLog.log("project_wizard", ["org": isTeam ? orgMode.rawValue : "personal", "folder": folderMode.rawValue,
                                        "card": !p.about.isEmpty || !p.client.isEmpty, "links": p.links.count])
        return p.slug
    }
}

struct ProjectWizardView: View {
    @StateObject var m: ProjectWizardModel
    @ObservedObject private var acct = PacenoteAccount.shared
    var done: (String?) -> Void

    init(settings: SettingsModel, orgID: String = "", done: @escaping (String?) -> Void) {
        _m = StateObject(wrappedValue: ProjectWizardModel(settings: settings, orgID: orgID)); self.done = done
    }

    var body: some View {
        Group {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L("wiz.title")).font(PN.sys(.headline, 13, .semibold))
                Spacer()
                Text(L("onb.stepOf", ["n": "\(m.stepNumber)", "total": "\(m.steps.count)"])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            Text(L("wiz.\(m.step).title")).font(PN.sys(15, .semibold))
            Group {
                switch m.step {
                case .name: nameStep
                case .folder: folderStep
                case .card: cardStep
                case .sources: sourcesStep
                case .people: peopleStep
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            if !m.error.isEmpty { Text(m.error).font(PN.Font.caption).foregroundStyle(PN.C.danger).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button(L("common.cancel")) { done(nil) }.buttonStyle(.pnTertiary).keyboardShortcut(.cancelAction)
                Spacer()
                if m.busy { PNSpinner(size: 16) }
                if m.step != .name { Button(L("onboarding.back")) { m.back() }.buttonStyle(.pnTertiary) }
                if m.step != .name && !m.isLast { Button(L("wiz.skip")) { m.next() }.buttonStyle(.pnTertiary) }
                if m.isLast {
                    Button(L("wiz.create")) { Task { if let s = await m.finish() { done(s) } } }
                        .buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction).disabled(m.busy || !m.nameOK)
                } else {
                    Button(L("common.continue")) { m.next() }
                        .buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction).disabled(!m.nameOK || (m.step == .folder && m.folderPath.isEmpty))
                }
            }
        }
        .padding(20).frame(width: 520, height: 470)
        .task { for o in m.teamOrgs where o.orgProjects { await acct.loadOrgProjects(o.id) } }
    }
        .trackScreen("project_wizard", sub: "\(m.step)")
    }

    private func caption(_ s: String) -> some View {
        Text(s).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder var nameStep: some View {
        if !(m.isTeam && m.orgMode == .join) {
            TextField(L("wiz.name"), text: $m.name, prompt: Text(L("wiz.name.prompt"))).textFieldStyle(.roundedBorder)
        }
        if !m.teamOrgs.isEmpty, let me = acct.me {
            Picker(L("wiz.where"), selection: $m.orgID) {
                Text(L("wiz.where.default", ["org": me.defaultOrg?.name ?? ""])).tag("")
                ForEach(me.orgs.filter { $0.id != me.defaultOrgID }) { o in Text(o.name).tag(o.id) }   // smoke 16.11: not twice
            }
            .pickerStyle(.radioGroup)          // a few organizations: all visible at once, no menu to open
            if m.isTeam, let o = m.org {
                if o.orgProjects {
                    Picker(L("wiz.orgProject"), selection: $m.orgMode) {
                        Text(L("wiz.orgProject.none")).tag(ProjectWizardModel.OrgMode.none)
                        if !(acct.orgProjects[o.id] ?? []).isEmpty { Text(L("wiz.orgProject.join")).tag(ProjectWizardModel.OrgMode.join) }
                        if m.canCreate { Text(L("wiz.orgProject.create")).tag(ProjectWizardModel.OrgMode.create) }
                    }
                    .pickerStyle(.radioGroup)
                    if m.orgMode == .join {
                        Picker(L("proj.org.project"), selection: $m.orgProjectID) {      // smoke 16.11: no "Choose..." row
                            ForEach(acct.orgProjects[o.id] ?? []) { op in Text(op.name).tag(op.id) }
                        }
                        .pickerStyle(.radioGroup).labelsHidden().padding(.leading, 120)
                        TextField(L("wiz.name"), text: $m.name, prompt: Text(L("wiz.name.same"))).textFieldStyle(.roundedBorder)
                    }
                    caption(L(m.orgMode == .none ? "wiz.orgProject.noneSub" : "proj.org.linkedSub"))
                } else {
                    caption(L("wiz.orgProject.planSub", ["org": o.name]))
                }
            } else {
                caption(L("wiz.where.sub"))
            }
        }
    }

    @ViewBuilder var folderStep: some View {
        Picker("", selection: $m.folderMode) {
            Text(L("wiz.folder.new")).tag(ProjectWizardModel.FolderMode.new)
            Text(L("wiz.folder.existing")).tag(ProjectWizardModel.FolderMode.existing)
        }
        .pickerStyle(.radioGroup).labelsHidden()
        if m.folderMode == .new {
            if m.settings.registry.workspaces.count > 1 {
                Picker(L("wiz.folder.in"), selection: $m.parent) {
                    ForEach(m.settings.registry.workspaces, id: \.root) { w in Text(w.name).tag(w.root) }
                }
                .pickerStyle(.menu)
            }
            caption(m.folderPath.isEmpty ? L("set.setTheWorkFolder") : m.folderPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        } else {
            HStack {
                Text(m.existing.isEmpty ? L("onboarding.folder.none") : m.existing.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .lineLimit(1).truncationMode(.middle).foregroundStyle(PN.C.text2)
                Spacer()
                Button(L("onboarding.folder.choose")) { m.chooseExisting() }.buttonStyle(.pnSecondary)
            }
        }
        caption(L("wiz.folder.sub"))
    }

    @ViewBuilder var cardStep: some View {
        if m.isTeam && m.orgMode == .join { caption(L("wiz.card.shared")) }
        TextField(L("wiz.card.about"), text: $m.about, prompt: Text(L("wiz.card.aboutPrompt")), axis: .vertical)
            .lineLimit(3...5).textFieldStyle(.roundedBorder)
        TextField(L("wiz.card.client"), text: $m.client, prompt: Text(L("wiz.card.clientPrompt"))).textFieldStyle(.roundedBorder)
        TextField(L("wiz.card.goal"), text: $m.goal, prompt: Text(L("wiz.card.goalPrompt"))).textFieldStyle(.roundedBorder)
        HStack {
            Picker(L("wiz.card.lang"), selection: $m.language) { langs }
            Picker(L("wiz.card.clientLang"), selection: $m.clientLanguage) { Text(L("wiz.card.same")).tag(""); langs }
        }
        TextField(L("wiz.card.glossary"), text: $m.glossary, prompt: Text(L("wiz.card.glossaryPrompt"))).textFieldStyle(.roundedBorder)
        caption(L("wiz.card.sub"))
    }

    @ViewBuilder var langs: some View {
        Text("English").tag("en"); Text("Українська").tag("uk")
    }

    @ViewBuilder var sourcesStep: some View {
        TextField(L("wiz.sources.links"), text: $m.linksText, prompt: Text("https://drive.google.com/drive/folders/...\nhttps://www.notion.so/..."), axis: .vertical)
            .lineLimit(4...7).textFieldStyle(.roundedBorder)
        let ls = ProjectWizardCore.links(m.linksText)
        if !ls.isEmpty { caption(L("wiz.sources.found", ["n": "\(ls.count)"])) }
        caption(L("wiz.sources.sub"))
    }

    @ViewBuilder var peopleStep: some View {
        if m.members.isEmpty {
            caption(m.membersNote.isEmpty ? L("wiz.people.loading") : m.membersNote)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(m.members) { p in
                        Toggle(p.name, isOn: Binding(get: { m.picked.contains(p.id) },
                                                     set: { if $0 { m.picked.insert(p.id) } else { m.picked.remove(p.id) } }))
                            .toggleStyle(.pnCheckbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
        }
        caption(L("wiz.people.sub"))
    }
}

/// 0.17.0 (spec 5.1): the sample project. Made once at the end of the first-start steps; Settings > Projects > Add >
/// Sample project makes it again after it was removed. Files: a folder, a short sample call with notes, one task.
@MainActor
enum SampleProjectMaker {
    static let madeKey = "pn.sampleProjectMade"

    static func makeOnce(_ settings: SettingsModel) {
        guard !UserDefaults.standard.bool(forKey: madeKey) else { return }
        if make(settings) != nil { UserDefaults.standard.set(true, forKey: madeKey) }
    }

    @discardableResult
    static func make(_ settings: SettingsModel) -> String? {
        if let p = settings.registry.projects.first(where: { $0.sample }) { return p.slug }
        let parent = ProjectWizardCore.parent(workRoot: settings.config.workRoot, workspaces: settings.registry.workspaces.map(\.root))
        let dir = ProjectWizardCore.newFolder(parent: parent, name: SampleProject.name, exists: { FileManager.default.fileExists(atPath: $0) })
        guard !dir.isEmpty else { return nil }
        let fm = FileManager.default
        let live = (dir as NSString).appendingPathComponent("live")
        do { try fm.createDirectory(atPath: live, withIntermediateDirectories: true) } catch { return nil }
        let stem = (live as NSString).appendingPathComponent(SampleProject.callStem(date: Date().addingTimeInterval(-3600)))
        try? SampleProject.transcript.write(toFile: stem + ".md", atomically: true, encoding: .utf8)
        try? SampleProject.notes.write(toFile: CallLayout.sidecar(stem, ".notes.md"), atomically: true, encoding: .utf8)
        let ws = (dir as NSString).deletingLastPathComponent
        if !settings.registry.workspaces.contains(where: { ProjectRegistry.norm($0.root) == ProjectRegistry.norm(ws) }),
           ProjectRegistry.norm(ws).hasPrefix(ProjectRegistry.norm(settings.config.workRoot) + "/") {
            settings.addWorkspace(ws)
        }
        var p = SampleProject.make(root: dir, workspace: (ws as NSString).lastPathComponent)
        if let i = settings.registry.projects.firstIndex(where: { ProjectRegistry.norm($0.root) == ProjectRegistry.norm(dir) }) {
            p.slug = settings.registry.projects[i].slug
            settings.registry.projects[i] = p
        } else {
            settings.registry.merge(folders: [p])
            settings.rescanWorkspaces()
        }
        let slug = settings.registry.projects.first { ProjectRegistry.norm($0.root) == ProjectRegistry.norm(dir) }?.slug ?? p.slug
        Register.shared.add(folder: live, text: SampleProject.task, owner: "me", project: slug, title: SampleProject.callTitle,
                            call: (stem as NSString).lastPathComponent + ".md", by: "sample")
        CallHistory.shared.scan()
        return slug
    }
}

/// 0.17.0 (5.2, 5.1): a project's card on its page in Settings > Projects. The sample project says what it is here.
struct ProjectCardSection: View {
    @ObservedObject var model: SettingsModel
    let index: Int
    @State private var glossary = ""
    @State private var links = ""

    var body: some View {
        let p = model.registry.projects[index]
        Section {
            if p.sample {
                HStack(alignment: .top, spacing: 8) {
                    Text(L("proj.sample.badge")).font(PN.Font.caption.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(PN.C.accent.opacity(0.2)))
                    Text(L("proj.sample.sub")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
            TextField(L("proj.card.name"), text: $model.registry.projects[index].name)
            TextField(L("wiz.card.about"), text: $model.registry.projects[index].about, axis: .vertical).lineLimit(1...5)
            TextField(L("wiz.card.client"), text: $model.registry.projects[index].client)
            TextField(L("wiz.card.goal"), text: $model.registry.projects[index].goal)
            TextField(L("wiz.card.glossary"), text: $glossary, prompt: Text(L("wiz.card.glossaryPrompt")))
            TextField(L("proj.card.links"), text: $links, prompt: Text(L("proj.card.linksPrompt")), axis: .vertical).lineLimit(1...5)
            if !p.people.isEmpty {
                LabeledContent(L("proj.card.people")) {
                    Text(p.people.map { $0.name + ($0.role.isEmpty ? "" : " (" + $0.role + ")") }.joined(separator: ", "))
                        .foregroundStyle(PN.C.text2).multilineTextAlignment(.trailing)
                }
            }
        } header: { Text(L("proj.card.head")).settingsAnchor("pr.card") }
        .onAppear { glossary = p.glossary.joined(separator: ", "); links = p.links.joined(separator: "\n") }
        .onChange(of: glossary) { model.registry.projects[index].glossary = ProjectWizardCore.glossary(glossary) }
        .onChange(of: links) { model.registry.projects[index].links = ProjectWizardCore.links(links) }
    }
}
