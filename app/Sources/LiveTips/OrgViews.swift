import AppKit
import SwiftUI
import LiveTipsCore

// 0.17.0 (B6b, server 0.6.0, contract claude/b6b-app-contract.md): organizations in the app. Invites (Home and
// Settings > Account), the organization filter, where new calls go (default_org_id), who sees a call (the badge next to
// a call and its Sheet), private calls by the organization's policy and "Manage organization" (the console in the
// browser). People, teams, organization projects and invites are managed in the console, not here.

/// The invites line on Home: "Mike invited you to Acme · Decline · Join…". One invite at a time.
struct InvitesHomeLine: View {
    @ObservedObject private var acct = PacenoteAccount.shared
    @State private var joining: PacenoteServer.Invite?

    var body: some View {
        if acct.signedIn, let i = acct.invites.first {
            // 0.24 (R1, board HB): one of the Home banners
            HomeBanner(icon: "+", title: InviteText.line(i),
                       sub: acct.invites.count > 1 ? L("org.invite.more", ["n": "\(acct.invites.count - 1)"]) : "",
                       edge: PN.C.answer, iconFill: PN.C.answer, iconInk: PN.C.bg, problem: acct.inviteProblem,
                       later: (L("org.invite.decline"), { Task { await acct.decline(i) } }),
                       go: L("org.invite.join"), goDisabled: acct.busy) { joining = i }
                .sheet(item: $joining) { inv in InviteJoinSheet(invite: inv) { joining = nil } }
        }
    }
}

enum InviteText {
    static func line(_ i: PacenoteServer.Invite) -> String {
        let who = i.invitedBy.isEmpty ? "" : i.invitedBy
        let base = who.isEmpty ? L("org.invite.lineNoWho", ["org": i.orgName]) : L("org.invite.line", ["who": who, "org": i.orgName])
        return i.teamName.isEmpty ? base : base + " " + L("org.invite.team", ["team": i.teamName])
    }
}

/// "Join Acme?": what changes, the "Use Acme for new calls" switch (on, B6b contract 2).
struct InviteJoinSheet: View {
    let invite: PacenoteServer.Invite
    var done: () -> Void
    @ObservedObject private var acct = PacenoteAccount.shared
    @State private var makeDefault = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("org.join.title", ["org": invite.orgName])).font(PN.sys(.headline, 13, .semibold))
            Text(InviteText.line(invite)).font(PN.Font.body).foregroundStyle(PN.C.text2)
            Text(L("org.join.what")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            // 0.19.0 (D45 5): one line among what the organization sees, no separate confirmation
            Text(L("org.join.usage", ["org": invite.orgName])).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            Toggle(L("org.join.default", ["org": invite.orgName]), isOn: $makeDefault)
            Text(L("org.join.defaultSub")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            if let e = error { Text(e).font(PN.Font.caption).foregroundStyle(PN.C.danger).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button(L("common.cancel"), action: done).buttonStyle(.pnTertiary).keyboardShortcut(.cancelAction)
                Button(L("org.join.ok")) {        // smoke 16.11: the sheet's own button has no "..."
                    Task {
                        if let e = await acct.accept(invite, makeDefault: makeDefault) { error = e } else { done() }
                    }
                }
                .buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction).disabled(acct.busy)
            }
        }
        .padding(20).frame(width: 440)
    }
}

/// Settings > Account: the organizations, where new calls go, Manage organization, the invites.
struct AccountOrgsSection: View {
    @ObservedObject private var acct = PacenoteAccount.shared
    @State private var joining: PacenoteServer.Invite?

    var body: some View {
        if let me = acct.me {
            Section {
                ForEach(me.orgs) { o in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: o.isPersonal ? "person" : "building.2").foregroundStyle(PN.C.text2).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(o.name)
                                if o.id == me.defaultOrg?.id { Text(L("org.newCallsHere")).font(PN.Font.caption).foregroundStyle(PN.C.turn) }
                            }
                            Text(L("account.org", ["name": o.isPersonal ? L("org.personal") : L("org.team"),
                                                   "role": L("account.role." + (o.role.isEmpty ? "member" : o.role)),
                                                   "plan": EntitlementsStore.shared.rights.record(o.id)?.plan.label ?? o.plan.capitalized]))
                                .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                            if let k = PacenoteServer.visibilityKey(o, isPrivate: false) {
                                Label(L(k), systemImage: "eye").font(PN.Font.caption).foregroundStyle(PN.C.text2)
                            }
                            if !o.isPersonal && !o.allowPrivateCalls {
                                Text(L("org.privateOff", ["org": o.name])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                            }
                        }
                        Spacer()
                        OrgSetupButton(org: o)                 // 0.17.0 (5.3): name, projects, people, policy
                        if o.canManage {
                            Button(L("org.manage")) { ConsoleLink.openOrg(o.id) }       // 0.17.2: the Console tab
                                .buttonStyle(.pnTertiary).help(L("org.manage.help"))
                        }
                    }
                }
                if me.orgs.count > 1 {
                    Picker(L("org.default"), selection: Binding(get: { me.defaultOrg?.id ?? "" },
                                                                set: { v in Task { await acct.setDefaultOrg(v) } })) {
                        ForEach(me.orgs) { o in Text(o.name).tag(o.id) }
                    }
                    .disabled(acct.busy)
                    Text(L("org.default.sub")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(acct.invites) { i in
                    HStack(spacing: 10) {
                        Image(systemName: "envelope.badge").foregroundStyle(PN.C.brand).frame(width: 18)
                        Text(InviteText.line(i)).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button(L("org.invite.decline")) { Task { await acct.decline(i) } }.buttonStyle(.pnTertiary).disabled(acct.busy)
                        Button(L("org.invite.join")) { joining = i }.buttonStyle(.pnSecondary).disabled(acct.busy)
                    }
                }
                if let p = acct.inviteProblem { Text(p).font(PN.Font.caption).foregroundStyle(PN.C.pending) }
            } header: { Text(L("org.head")).settingsAnchor("acc.orgs") } footer: {
                Text(L("org.foot")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            .sheet(item: $joining) { inv in InviteJoinSheet(invite: inv) { joining = nil } }
        }
    }
}

/// The organization and project filters of Recent calls and All past calls (B6b contract 3, D39). The organization
/// filter shows only with more than one organization; the project filter only with more than one project among the calls.
struct CallFilters: View {
    @Binding var org: String          // "" all
    @Binding var project: String      // "" all, else a project root
    let records: [CallHistory.Record]
    @ObservedObject private var acct = PacenoteAccount.shared

    var body: some View {
        let projects = CallFilter.projects(in: records)
        HStack(spacing: 8) {
            if let me = acct.me, me.showsOrgFilter {
                Menu {
                    Button(L("org.filter.all")) { org = "" }
                    Divider()
                    ForEach(me.orgs) { o in Button(o.name) { org = o.id } }
                } label: {
                    Text(org.isEmpty ? L("org.filter.all") : (me.org(org)?.name ?? L("org.filter.all"))).lineLimit(1)
                }
                .menuStyle(.borderlessButton).fixedSize().help(L("org.filter.help"))
            }
            if projects.count > 1 {
                Menu {
                    Button(L("proj.filter.all")) { project = "" }
                    Divider()
                    ForEach(projects, id: \.root) { p in Button(CallFilter.label(p)) { project = p.root } }
                } label: {
                    Text(project.isEmpty ? L("proj.filter.all") : (projects.first { $0.root == project }.map(CallFilter.label) ?? L("proj.filter.all")))
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton).fixedSize().help(L("proj.filter.help"))
            }
        }
    }
}

@MainActor
enum CallFilter {
    /// The calls of one organization (a call that never went to the server is in the personal space) and one project.
    static func apply(_ rs: [CallHistory.Record], org: String, project: String) -> [CallHistory.Record] {
        guard !org.isEmpty || !project.isEmpty else { return rs }
        let me = PacenoteAccount.shared.me
        let personal = me?.personal?.id ?? ""
        let orgKnown = !org.isEmpty && me?.org(org) != nil
        return rs.filter { r in
            if !project.isEmpty && root(of: r.file) != project { return false }
            if orgKnown {
                let o = CallSyncService.shared.orgID(of: r.file)
                return (o.isEmpty ? personal : o) == org
            }
            return true
        }
    }

    static func root(of file: String) -> String {
        (CallLayout.liveFolder(of: file) as NSString).deletingLastPathComponent
    }

    /// The registered projects that have calls in the list, by name.
    static func projects(in rs: [CallHistory.Record]) -> [Project] {
        let roots = Set(rs.map { root(of: $0.file) })
        return ProjectRegistry.load(from: AppPaths.projects).projects
            .filter { !$0.root.isEmpty && roots.contains($0.root) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// A project's name, with the organization project it is linked to (D38).
    static func label(_ p: Project) -> String {
        p.linkedToOrgProject && !p.orgProjectName.isEmpty ? p.name + " · " + p.orgProjectName : p.name
    }
}

/// "Visible to your team lead": next to a call and its Meeting Sheet when someone else sees it (B6b contract 1). Only
/// for a call that goes to the server (its project syncs, signed in) and is not private.
struct VisibilityBadge: View {
    let transcript: String
    @ObservedObject private var acct = PacenoteAccount.shared
    @ObservedObject private var sync = CallSyncService.shared

    var body: some View {
        if sync.project(for: transcript) != nil {
            let pv = sync.privacy(transcript)
            if let k = PacenoteServer.visibilityKey(pv.org, isPrivate: pv.isPrivate) {
                Label(L(k), systemImage: "eye").font(PN.Font.caption).foregroundStyle(PN.C.text2)
                    .help(L("org.visible.help", ["org": pv.org?.name ?? ""]))
            } else if pv.isPrivate, pv.org?.isPersonal == false {
                Label(L("org.private.badge"), systemImage: "lock").font(PN.Font.caption).foregroundStyle(PN.C.text2)
                    .help(L("org.private.help"))
            }
        }
    }
}

/// The call page's line about the call's organization: where it is, who sees it, and the Private switch (D36). Only
/// for a call of a team organization that goes to the server.
struct CallOrgRow: View {
    let file: String
    @ObservedObject private var acct = PacenoteAccount.shared
    @ObservedObject private var sync = CallSyncService.shared
    @State private var tick = 0

    var body: some View {
        let pv = sync.privacy(file)
        if sync.project(for: file) != nil, let org = pv.org, !org.isPersonal {
            // 0.25 (R2, board SL): a status line: the organization, who sees the call, and the Private switch
            let vk = PacenoteServer.visibilityKey(org, isPrivate: pv.isPrivate)
            let who = pv.isPrivate ? L("org.private.badge") : vk.map { L($0) } ?? ""
            PageStatusLine(key: L("org.line.key"), kind: .neutral, value: who.isEmpty ? org.name : org.name + " · " + who,
                           sub: pv.isPrivate ? L("org.private.help") : L("org.line.visibleSub")) {
                Toggle(L("org.private.toggle"), isOn: Binding(get: { pv.isPrivate },
                                                              set: { sync.setPrivate($0, transcript: file); tick += 1 }))
                    .toggleStyle(.pnSwitch).controlSize(.small)
                    .disabled(!pv.isPrivate && !pv.allowed)
                    .help(pv.allowed ? L("org.private.help") : L("org.privateOff", ["org": org.name]))
            }
            .id(tick)
        }
    }
}

/// Settings > Projects > a project: the organization part. Where new calls of the project go, the organization
/// project it is linked to (D38; linking turns the sync on, D40.6) and "private by default" (D36).
struct ProjectOrgSection: View {
    @ObservedObject var model: SettingsModel
    let index: Int
    @ObservedObject private var acct = PacenoteAccount.shared
    @State private var moveTo: PacenoteServer.Org?        // 0.17.0 (Bohdan 16.11): Move project, after the warning
    @State private var moving = false
    @State private var moveNote = ""

    var body: some View {
        if acct.signedIn, let me = acct.me, me.orgs.contains(where: { !$0.isPersonal }) {
            let p = model.registry.projects[index]
            let target = me.org(p.homeOrg) ?? me.defaultOrg
            let linkable = me.orgs.filter { $0.orgProjects }
            Section {
                LabeledContent(L("proj.org.newCalls")) {
                    HStack(spacing: 8) {
                        Text(target?.name ?? "-").foregroundStyle(PN.C.text2)
                        if moving { PNSpinner(size: 16) }
                        Menu(L("proj.org.move")) {
                            ForEach(me.orgs.filter { $0.id != target?.id }) { o in Button(o.name) { moveTo = o } }
                        }
                        .menuStyle(.borderlessButton).fixedSize().disabled(moving || acct.busy)
                        .help(L("proj.org.move.help"))
                    }
                }
                .help(L("proj.org.newCalls.help"))
                .settingsAnchor("pr.orgMove")
                if !moveNote.isEmpty { Text(moveNote).font(PN.Font.caption).foregroundStyle(PN.C.pending).fixedSize(horizontal: false, vertical: true) }
                if !linkable.isEmpty {
                    Picker(L("proj.org.project"), selection: Binding(get: { p.orgProjectID }, set: { link($0, in: linkable) })) {
                        Text(L("proj.org.none")).tag("")
                        ForEach(linkable) { o in
                            ForEach(acct.orgProjects[o.id] ?? []) { op in
                                Text(linkable.count > 1 ? op.name + " · " + o.name : op.name).tag(op.id)
                            }
                        }
                        if !p.orgProjectID.isEmpty && !known(p.orgProjectID) {
                            Text(p.orgProjectName.isEmpty ? L("proj.org.gone") : p.orgProjectName + " (" + L("proj.org.gone") + ")").tag(p.orgProjectID)
                        }
                    }
                    .settingsAnchor("pr.orgProject")
                    Text(L(p.linkedToOrgProject ? "proj.org.linkedSub" : "proj.org.sub")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                        .fixedSize(horizontal: false, vertical: true)
                    if !p.orgProjectID.isEmpty && loaded(p.orgProjectOrg) && !known(p.orgProjectID) {
                        HStack {
                            Text(L("proj.org.goneSub")).font(PN.Font.caption).foregroundStyle(PN.C.pending)
                            Spacer()
                            Button(L("proj.org.unlink")) { link("", in: linkable) }.buttonStyle(.pnTertiary)
                        }
                    }
                }
                let allowed = target.map { $0.isPersonal || $0.allowPrivateCalls } ?? true
                Toggle(isOn: $model.registry.projects[index].privateByDefault) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("proj.org.private"))
                        Text(allowed ? L("proj.org.privateSub") : L("org.privateOff", ["org": target?.name ?? ""]))
                            .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    }
                }
                .disabled(!allowed && !p.privateByDefault)
            } header: { Text(L("proj.org.head")) }
            .task { for o in linkable { await acct.loadOrgProjects(o.id) } }
            .alert(L("proj.org.move.q", ["project": p.name, "org": moveTo?.name ?? ""]),
                   isPresented: Binding(get: { moveTo != nil }, set: { if !$0 { moveTo = nil } })) {
                Button(L("proj.org.move.ok", ["org": moveTo?.name ?? ""])) { if let o = moveTo { move(o) } }
                Button(L("common.cancel"), role: .cancel) { moveTo = nil }
            } message: { Text(L("proj.org.move.m", ["org": moveTo?.name ?? ""])) }
        }
    }

    private func move(_ o: PacenoteServer.Org) {
        let p = model.registry.projects[index]
        moving = true; moveNote = ""; moveTo = nil
        Task {
            let (q, err) = await CallSyncService.shared.move(p, to: o.id)
            moving = false
            if let e = err { moveNote = e; return }
            if let i = model.registry.projects.firstIndex(where: { $0.slug == p.slug }) { model.registry.projects[i] = q }
            CallSyncService.shared.resync(root: q.root)
            moveNote = L("proj.org.move.done", ["org": o.name])
        }
    }

    private func known(_ id: String) -> Bool { acct.orgProjects.values.contains { $0.contains { $0.id == id } } }
    private func loaded(_ org: String) -> Bool { acct.orgProjects[org] != nil }

    private func link(_ id: String, in orgs: [PacenoteServer.Org]) {
        var p = model.registry.projects[index]
        if id.isEmpty {
            p.orgProjectID = ""; p.orgProjectOrg = ""; p.orgProjectName = ""      // the sync stays as it is (D40.6)
        } else if let o = orgs.first(where: { (acct.orgProjects[$0.id] ?? []).contains { $0.id == id } }),
                  let op = acct.orgProjects[o.id]?.first(where: { $0.id == id }) {
            p.orgProjectID = op.id; p.orgProjectOrg = o.id; p.orgProjectName = op.name
            p.serverSync = true                                                    // D40.6: linking turns the sync on
        }
        model.registry.projects[index] = p
    }
}
