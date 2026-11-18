import AppKit
import SwiftUI
import LiveTipsCore

// 0.17.0 (spec 5.3, D39, Bohdan 16.11): setting up an organization after the upgrade, for its owner. Starts from the
// organization that already exists: its name, my projects (move them in, or a new one), invites, teams and leads, the
// policy. Steps 3-5 can wait for the console. Rules: LiveTipsCore/OrgSetupCore.swift.

@MainActor
enum OrgSetupMemory {
    static let key = "pn.orgSetupDone"
    static var done: Set<String> { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
    static func mark(_ orgID: String) {
        UserDefaults.standard.set(Array(done.union([orgID])).sorted(), forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }
    static let changed = Notification.Name("PacenoteOrgSetupChanged")
}

/// Home: "Acme is ready. Set it up: name, projects, people, policy · Not now · Set up…".
struct OrgSetupHomeLine: View {
    @ObservedObject private var acct = PacenoteAccount.shared
    @State private var done = OrgSetupMemory.done
    @State private var running: PacenoteServer.Org?

    var body: some View {
        if acct.signedIn, let o = acct.me?.orgs.first(where: { OrgSetup.offered($0, done: done) }) {
            // 0.24 (R1, board HB): one of the Home banners
            HomeBanner(icon: "◆", title: L("orgsetup.home", ["org": o.name]), sub: L("orgsetup.homeSub"),
                       edge: PN.C.text3, iconFill: PN.C.text, iconInk: PN.C.bg,
                       later: (L("orgsetup.notNow"), { OrgSetupMemory.mark(o.id) }), go: L("orgsetup.start")) { running = o }
                .help(L("orgsetup.notNow.help"))
                .sheet(item: $running) { org in OrgSetupView(org: org) { running = nil } }
                .onReceive(NotificationCenter.default.publisher(for: OrgSetupMemory.changed)) { _ in done = OrgSetupMemory.done }
        }
    }
}

@MainActor
final class OrgSetupModel: ObservableObject {
    let orgID: String
    @Published var step: OrgSetup.Step = .name
    @Published var name: String
    @Published var picked = Set<String>()          // project slugs to move in
    @Published var inviteText = ""
    @Published var inviteRole = "member"
    @Published var inviteTeam = ""
    @Published var inviteResults: [(String, String)] = []
    @Published var teams: [OrgSetup.Team] = []
    @Published var members: [ProjectWizardCore.Member] = []
    @Published var teamName = ""
    @Published var teamLead = ""
    @Published var policyLoaded: OrgSetup.Policy?
    @Published var policy = OrgSetup.Policy()
    @Published var busy = false
    @Published var note = ""
    @Published var error = ""

    init(org: PacenoteServer.Org) {
        orgID = org.id; name = org.name
        policy = OrgSetup.Policy(allowPrivateCalls: org.allowPrivateCalls, shareMeetingSheets: org.shareMeetingSheets)
    }

    var acct: PacenoteAccount { PacenoteAccount.shared }
    var org: PacenoteServer.Org? { acct.me?.org(orgID) }
    var steps: [OrgSetup.Step] { org.map(OrgSetup.steps) ?? [.name, .projects, .invite, .policy] }
    var isLast: Bool { steps.last == step }
    var later: Bool { [.invite, .teams, .policy].contains(step) }

    func go(_ delta: Int) {
        error = ""; note = ""
        if let i = steps.firstIndex(of: step), steps.indices.contains(i + delta) { step = steps[i + delta] }
        Task { await loadFor(step) }
    }

    private func body(_ o: [String: Any]) -> Data { CallSync.json(o) }

    func loadFor(_ s: OrgSetup.Step) async {
        switch s {
        case .invite, .teams:
            if let r = try? await acct.api("GET", "/v1/orgs/\(orgID)/teams"), r.1 == 200 {
                teams = OrgSetup.teams(((try? JSONSerialization.jsonObject(with: r.0)) as? [[String: Any]]) ?? [])
            }
            if s == .teams, let r = try? await acct.api("GET", "/v1/orgs/\(orgID)/members"), r.1 == 200 {
                members = ProjectWizardCore.members(((try? JSONSerialization.jsonObject(with: r.0)) as? [[String: Any]]) ?? [], me: acct.me?.userID ?? "")
            }
        case .policy:
            if policyLoaded == nil, let r = try? await acct.api("GET", "/v1/orgs/\(orgID)/policy"), r.1 == 200 {
                let p = OrgSetup.policy(((try? JSONSerialization.jsonObject(with: r.0)) as? [String: Any]) ?? [:])
                policyLoaded = p; policy = p
            }
        default: break
        }
    }

    /// The step's own action before going on. False keeps the step (the error says why).
    func commit(settings: SettingsModel) async -> Bool {
        error = ""
        busy = true; defer { busy = false }
        do {
            switch step {
            case .name:
                guard let b = OrgSetup.nameBody(name) else { error = L("orgsetup.name.empty"); return false }
                guard name.trimmingCharacters(in: .whitespacesAndNewlines) != org?.name else { return true }
                let (d, c) = try await acct.api("PATCH", "/v1/orgs/\(orgID)", body: body(b))
                guard c == 200 else { error = L("orgsetup.err", ["e": PacenoteServer.problem(d, status: c)]); return false }
                await acct.refreshInfo()
            case .projects:
                for slug in picked.sorted() {
                    guard let p = settings.registry.projects.first(where: { $0.slug == slug }) else { continue }
                    let (q, err) = await CallSyncService.shared.move(p, to: orgID)
                    if let e = err { error = L("orgsetup.move.err", ["project": p.name, "e": e]); return false }
                    if let i = settings.registry.projects.firstIndex(where: { $0.slug == slug }) { settings.registry.projects[i] = q }
                    CallSyncService.shared.resync(root: q.root)
                    picked.remove(slug)
                }
            case .policy:
                guard let from = policyLoaded else { return true }
                let b = OrgSetup.policyBody(from: from, to: policy)
                guard !b.isEmpty else { return true }
                let (d, c) = try await acct.api("PATCH", "/v1/orgs/\(orgID)/policy", body: body(b))
                guard c == 200 else {
                    error = PacenoteServer.isPlan(d, status: c) ? L("orgsetup.policy.plan") : L("orgsetup.err", ["e": PacenoteServer.problem(d, status: c)]); return false
                }
                policyLoaded = policy
                await acct.refreshInfo()
            case .invite, .teams:
                break                                   // their buttons act at once
            }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func sendInvites() async {
        let (ok, bad) = OrgSetup.invites(inviteText, defaultRole: inviteRole)
        error = bad.isEmpty ? "" : L("orgsetup.invite.bad", ["list": bad.joined(separator: ", ")])
        guard !ok.isEmpty else { return }
        busy = true; defer { busy = false }
        var results: [(String, String)] = []
        for i in ok {
            let c = (try? await acct.api("POST", "/v1/orgs/\(orgID)/invites", body: body(OrgSetup.inviteBody(i, teamID: inviteTeam))))?.1 ?? 0
            results.append((i.email, L(OrgSetup.inviteResult(status: c))))
        }
        inviteResults = results + inviteResults
        // live test 16.11: what did not go stays in the field (lines that are not an email, invites refused)
        let ok200 = [L("orgsetup.invite.sent"), L("orgsetup.invite.refreshed")]
        let left = results.filter { !ok200.contains($0.1) }.map(\.0) + bad
        inviteText = left.joined(separator: "\n")
        UsageLog.log("org_setup_invites", ["n": ok.count])
    }

    func addTeam() async {
        guard let b = OrgSetup.teamBody(name: teamName, leadID: teamLead) else { return }
        busy = true; defer { busy = false }
        do {
            let (d, c) = try await acct.api("POST", "/v1/orgs/\(orgID)/teams", body: body(b))
            guard c == 201 || c == 200 else {
                error = PacenoteServer.isPlan(d, status: c) ? L("orgsetup.teams.plan") : L("orgsetup.err", ["e": PacenoteServer.problem(d, status: c)]); return
            }
            teamName = ""; teamLead = ""
            await loadFor(.teams)
            await acct.refreshInfo()
        } catch { self.error = error.localizedDescription }
    }
}

struct OrgSetupView: View {
    @StateObject private var m: OrgSetupModel
    @ObservedObject private var settings = SettingsWindow.model
    @ObservedObject private var acct = PacenoteAccount.shared
    @State private var showWizard = false
    var done: () -> Void

    init(org: PacenoteServer.Org, done: @escaping () -> Void) {
        _m = StateObject(wrappedValue: OrgSetupModel(org: org)); self.done = done
    }

    var body: some View {
        Group {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("orgsetup.title", ["org": m.org?.name ?? m.name])).font(PN.sys(.headline, 13, .semibold))
                Spacer()
                Text(L("onb.stepOf", ["n": "\((m.steps.firstIndex(of: m.step) ?? 0) + 1)", "total": "\(m.steps.count)"]))
                    .font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            Text(L("orgsetup.\(m.step.rawValue).title")).font(PN.sys(15, .semibold))
            Group {
                switch m.step {
                case .name: nameStep
                case .projects: projectsStep
                case .invite: inviteStep
                case .teams: teamsStep
                case .policy: policyStep
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            if !m.error.isEmpty { Text(m.error).font(PN.Font.caption).foregroundStyle(PN.C.danger).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button(L("common.cancel")) { done() }.buttonStyle(.pnTertiary).keyboardShortcut(.cancelAction)
                if m.later {
                    Button(L("orgsetup.console")) { let id = m.orgID; done(); ConsoleLink.openOrg(id) }     // 0.17.2: the Console tab
                        .buttonStyle(.pnTertiary).help(L("orgsetup.console.help"))
                }
                Spacer()
                if m.busy { PNSpinner(size: 16) }
                if m.step != .name { Button(L("onboarding.back")) { m.go(-1) }.buttonStyle(.pnTertiary) }
                if m.later && !m.isLast { Button(L("orgsetup.later")) { m.go(1) }.buttonStyle(.pnTertiary) }
                Button(L(m.isLast ? "orgsetup.finish" : "common.continue")) {
                    Task {
                        guard await m.commit(settings: settings) else { return }
                        if m.isLast {
                            OrgSetupMemory.mark(m.orgID)
                            UsageLog.log("org_setup_done", ["org_teams": m.org?.teams ?? false])
                            done()
                        } else { m.go(1) }
                    }
                }
                .buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction).disabled(m.busy)
            }
        }
        .padding(20).frame(width: 540, height: 500)
        .sheet(isPresented: $showWizard) {
            ProjectWizardView(settings: settings, orgID: m.orgID) { _ in showWizard = false }
        }
    }
        .trackScreen("org_setup", sub: m.step.rawValue)
    }

    private func caption(_ s: String) -> some View {
        Text(s).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder var nameStep: some View {
        TextField(L("orgsetup.name"), text: $m.name).textFieldStyle(.roundedBorder)
        caption(L("orgsetup.name.sub"))
        if let o = m.org { caption(L("orgsetup.plan", ["plan": o.plan.capitalized])) }
    }

    @ViewBuilder var projectsStep: some View {
        let list = OrgSetup.movable(settings.registry.projects, into: m.orgID)
        if list.isEmpty {
            caption(L("orgsetup.projects.none"))
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(list, id: \.slug) { p in
                        Toggle(isOn: Binding(get: { m.picked.contains(p.slug) },
                                             set: { if $0 { m.picked.insert(p.slug) } else { m.picked.remove(p.slug) } })) {
                            HStack(spacing: 6) {
                                Text(p.name)
                                if let from = acct.me?.org(p.homeOrg)?.name ?? acct.me?.defaultOrg?.name {
                                    Text(from).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                                }
                            }
                        }
                        .toggleStyle(.pnCheckbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
        }
        HStack {
            Button(L("orgsetup.projects.new")) { showWizard = true }.buttonStyle(.pnSecondary)
            Spacer()
        }
        caption(L("orgsetup.projects.sub"))
    }

    @ViewBuilder var inviteStep: some View {
        TextField(L("orgsetup.invite.emails"), text: $m.inviteText, prompt: Text("mike@example.com\nemily@example.com admin"), axis: .vertical)
            .lineLimit(3...6).textFieldStyle(.roundedBorder)
        HStack {
            Picker(L("orgsetup.invite.role"), selection: $m.inviteRole) {
                Text(L("account.role.member")).tag("member"); Text(L("account.role.admin")).tag("admin")
            }
            .fixedSize()
            if !m.teams.isEmpty {
                Picker(L("orgsetup.invite.team"), selection: $m.inviteTeam) {
                    Text(L("orgsetup.invite.noTeam")).tag("")
                    ForEach(m.teams) { t in Text(t.name).tag(t.id) }
                }
                .fixedSize()
            }
            Spacer()
            Button(L("orgsetup.invite.send")) { Task { await m.sendInvites() } }
                .buttonStyle(.pnSecondary).disabled(m.busy || m.inviteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        if !m.inviteResults.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(m.inviteResults.enumerated()), id: \.offset) { _, r in
                        Text(r.0 + ": " + r.1).font(PN.Font.caption).foregroundStyle(PN.C.text2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 90)
        }
        caption(L("orgsetup.invite.sub"))
    }

    @ViewBuilder var teamsStep: some View {
        if !m.teams.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(m.teams) { t in
                    let lead = t.leadID == acct.me?.userID ? L("orgcard.you") : m.members.first { $0.id == t.leadID }?.name ?? "?"
                    Text(t.name + " · " + (t.leadID.isEmpty ? L("orgsetup.teams.noLeadLine") : L("orgsetup.teams.lead", ["who": lead])))
                        .font(PN.Font.body)
                }
            }
        }
        HStack {
            TextField(L("orgsetup.teams.name"), text: $m.teamName, prompt: Text("Sales")).textFieldStyle(.roundedBorder)
            Picker(L("orgsetup.teams.leadPick"), selection: $m.teamLead) {
                Text(L("orgsetup.teams.noLead")).tag("")
                if let me = acct.me?.userID, !me.isEmpty { Text(L("orgcard.you")).tag(me) }
                ForEach(m.members) { p in Text(p.name).tag(p.id) }
            }
            .fixedSize()
            Button(L("orgsetup.teams.add")) { Task { await m.addTeam() } }
                .buttonStyle(.pnSecondary).disabled(m.busy || m.teamName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        caption(L("orgsetup.teams.sub"))
    }

    @ViewBuilder var policyStep: some View {
        Toggle(isOn: $m.policy.allowPrivateCalls) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("orgsetup.policy.private"))
                Text(L("orgsetup.policy.privateSub")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
        }
        Toggle(isOn: $m.policy.shareMeetingSheets) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("orgsetup.policy.sheets"))
                Text(L("orgsetup.policy.sheetsSub")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
        }
        caption(L("orgsetup.policy.sub"))
    }
}

/// Settings > Account: "Set up…" next to Manage organization, for the owner or an admin of a team organization.
struct OrgSetupButton: View {
    let org: PacenoteServer.Org
    @State private var running: PacenoteServer.Org?
    var body: some View {
        if OrgSetup.canRun(org) {
            Button(L("orgsetup.button")) { running = org }.buttonStyle(.pnTertiary).help(L("orgsetup.button.help"))
                .sheet(item: $running) { o in OrgSetupView(org: o) { running = nil } }
        }
    }
}
