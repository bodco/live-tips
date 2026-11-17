import AppKit
import SwiftUI
import LiveTipsCore

// 0.19.0 (server 0.11.0, migration 0014, Bohdan 17.11): Compare plans, in the app. Every plan people can choose with
// its planned price (beta: struck through, $0 now), trial, what it includes and its limits. An owner or admin switches
// an organization to another plan here (a downgrade only when the organization fits; what does not fit is named); on
// Solo, a plan with teams starts a team organization and the organization setup opens right after. Opened from
// Settings > Account > Plan, from a closed feature and from the Console tab's plan pages in the browser. The server
// decides everything (SelfServe); the confirm step says what is added and what turns off.

/// A label from the app's own strings when it has one, else the server's English label.
func Lor(_ key: String, _ fallback: String) -> String { let s = L(key); return s == key ? fallback : s }

@MainActor
final class PlansModel: ObservableObject {
    @Published var plans: [SelfServe.Plan] = []
    @Published var beta = true
    @Published var loading = false
    @Published var error = ""
    @Published var note = ""
    @Published var misfit: [String] = []
    @Published var orgID: String
    @Published var confirm: SelfServe.Plan?
    @Published var teamPlan: SelfServe.Plan?
    @Published var teamName = ""
    @Published var busy = false
    @Published var setupOrg: PacenoteServer.Org?

    init(orgID: String?) {
        let me = PacenoteAccount.shared.me
        self.orgID = orgID ?? me?.defaultOrg?.id ?? me?.personal?.id ?? ""
    }

    var acct: PacenoteAccount { PacenoteAccount.shared }
    var org: PacenoteServer.Org? { acct.me?.org(orgID) }
    var record: Entitlements.Record? { EntitlementsStore.shared.rights.record(orgID) }
    /// The plan the organization is on now: the signed record first, then /v1/me.
    var currentPlanID: String? { record.map { $0.plan.id } ?? org?.plan }
    /// A hidden (custom) plan, or one that is not in the list people choose from.
    var customPlan: Bool {
        if let r = record, r.plan.id == nil { return true }
        guard let id = currentPlanID, !plans.isEmpty else { return false }
        return !plans.contains { $0.id == id }
    }
    var current: SelfServe.Plan? { plans.first { $0.id == currentPlanID } }
    var orgName: String { org.map { $0.isPersonal ? L("plans.personal") : $0.name } ?? "" }

    func load() async {
        loading = true; error = ""; defer { loading = false }
        do {
            let (d, c) = try await acct.api("GET", "/v1/plans")
            guard c == 200 else { error = L("plans.err", ["e": c == 404 ? L("console.err.old") : PacenoteServer.problem(d, status: c)]); return }
            let r = SelfServe.plans(d)
            beta = r.beta; plans = r.plans
        } catch { self.error = L("plans.err", ["e": error.localizedDescription]) }
    }

    func action(_ p: SelfServe.Plan) -> SelfServe.Action {
        guard let o = org else { return .askOwner }
        return SelfServe.action(org: o, currentPlan: currentPlanID, customPlan: customPlan, plan: p)
    }

    func choose(_ p: SelfServe.Plan) async {
        guard let o = org else { return }
        busy = true; error = ""; note = ""; misfit = []; defer { busy = false }
        do {
            let (d, c) = try await acct.api("POST", "/v1/orgs/\(o.id)/plan", body: SelfServe.chooseBody(p.id))
            switch c {
            case 200:
                UsageLog.log("plan_chosen", ["plan": p.id, "from": currentPlanID ?? ""])
                await acct.refreshInfo()
                await EntitlementsStore.shared.refresh(force: true)
                note = L("plans.done", ["org": orgName, "plan": p.name])
            case 409:
                misfit = SelfServe.misfit(d, status: c)
                error = misfit.isEmpty ? PacenoteServer.problem(d, status: c) : L("plans.misfit", ["plan": p.name])
            case 403: error = L("plans.askOwner")
            default: error = PacenoteServer.problem(d, status: c)
            }
        } catch { self.error = error.localizedDescription }
    }

    func startTeam(_ p: SelfServe.Plan) async {
        guard let b = SelfServe.teamBody(name: teamName, plan: p.id) else { error = L("orgsetup.name.empty"); return }
        busy = true; error = ""; note = ""; defer { busy = false }
        do {
            let (d, c) = try await acct.api("POST", "/v1/orgs", body: b)
            guard let id = SelfServe.createdOrg(d, status: c) else {
                error = L("plans.team.err", ["e": PacenoteServer.problem(d, status: c)]); return
            }
            UsageLog.log("org_team_started", ["plan": p.id])
            await acct.refreshInfo()
            await EntitlementsStore.shared.refresh(force: true)
            teamPlan = nil; teamName = ""
            if let o = acct.me?.org(id) { setupOrg = o } else { note = L("plans.team.done") }
        } catch { self.error = L("plans.team.err", ["e": error.localizedDescription]) }
    }
}

struct PlansView: View {
    @StateObject private var m: PlansModel
    @ObservedObject private var acct = PacenoteAccount.shared
    @ObservedObject private var store = EntitlementsStore.shared
    var close: () -> Void

    init(orgID: String?, close: @escaping () -> Void) {
        _m = StateObject(wrappedValue: PlansModel(orgID: orgID)); self.close = close
    }

    var body: some View {
        Group {
        if let o = m.setupOrg {
            OrgSetupView(org: o) { close() }
        } else {
            content
        }
    }
        .trackScreen("plans")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("plans.window")).font(.system(size: 20, weight: .bold)).foregroundStyle(PN.C.text)
                Spacer()
                if let me = acct.me, me.orgs.count > 1 {
                    Picker(L("plans.for"), selection: $m.orgID) {
                        ForEach(me.orgs) { o in Text(o.isPersonal ? L("plans.personal") : o.name).tag(o.id) }
                    }
                    .frame(maxWidth: 280)
                    .onChange(of: m.orgID) { _, _ in m.error = ""; m.note = ""; m.misfit = []; m.teamPlan = nil }
                }
            }
            if m.beta {
                VStack(alignment: .leading, spacing: 2) {
                    Label(L("plan.beta"), systemImage: "sparkles").font(PN.Font.body.weight(.semibold)).foregroundStyle(PN.C.turn)
                    Text(L("plan.beta.note", ["days": "\(store.rights.billingNoticeDays)"])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if m.customPlan {
                Label(L("plans.custom"), systemImage: "building.columns").font(PN.Font.caption).foregroundStyle(PN.C.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if m.loading && m.plans.isEmpty {
                ProgressView(L("plans.loading")).frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) { ForEach(m.plans) { card($0) } }.padding(.bottom, 4)
                }
            }
            if let p = m.teamPlan { teamForm(p) }
            messages
            HStack {
                Button(L("plans.console")) {
                    let path = "/plans?org=" + m.orgID
                    close()
                    ConsoleLink.open(path: path)
                }.buttonStyle(.pnTertiary).help(L("plans.console.help"))
                Spacer()
                Button(L("common.close")) { close() }.buttonStyle(.pnSecondary).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 520)
        .task { if m.plans.isEmpty { await m.load() } }
        .alert(m.confirm.map { L("plans.confirm.q", ["org": m.orgName, "plan": $0.name]) } ?? "",
               isPresented: Binding(get: { m.confirm != nil }, set: { if !$0 { m.confirm = nil } }), presenting: m.confirm) { p in
            Button(L("plans.confirm.go")) { Task { await m.choose(p) } }
            Button(L("common.cancel"), role: .cancel) {}
        } message: { p in Text(confirmText(p)) }
    }

    private func confirmText(_ p: SelfServe.Plan) -> String {
        let ch = SelfServe.changes(from: m.current, to: p)
        var parts: [String] = []
        if !ch.gained.isEmpty { parts.append(L("plans.confirm.gained", ["list": ch.gained.map(moduleLabel).joined(separator: ", ")])) }
        if !ch.lost.isEmpty { parts.append(L("plans.confirm.lost", ["list": ch.lost.map(moduleLabel).joined(separator: ", ")])) }
        parts.append(L(m.beta ? "plans.confirm.now" : "plans.confirm.nowPaid"))
        return parts.joined(separator: "\n\n")
    }

    /// Server labels come in English; the app's own module names win when it has them.
    private func moduleLabel(_ label: String) -> String {
        let id = m.plans.flatMap { $0.included + $0.missing }.first { $0.label == label }?.id ?? ""
        return id.isEmpty ? label : Lor("module." + id, label)
    }

    @ViewBuilder private func card(_ p: SelfServe.Plan) -> some View {
        let a = m.action(p)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(p.name).font(.system(size: 17, weight: .bold)).foregroundStyle(PN.C.text)
                Spacer()
                if a == .current { Text(L("plans.current")).font(PN.Font.label).foregroundStyle(PN.C.turn) }
            }
            priceLine(p)
            if p.trialDays > 0 { Text(L("plans.trial", ["n": "\(p.trialDays)"])).font(PN.Font.caption).foregroundStyle(PN.C.turn) }
            if !p.description.isEmpty {
                Text(p.description).font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Text(L("plans.local")).font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
            ForEach(p.included, id: \.id) { i in
                Label(Lor("module." + i.id, i.label) + (i.level.isEmpty ? "" : " (" + Lor("plans.level." + i.level, i.level) + ")"),
                      systemImage: "checkmark").font(PN.Font.caption).foregroundStyle(PN.C.text)
            }
            ForEach(p.missing, id: \.id) { i in
                Label(Lor("module." + i.id, i.label), systemImage: "minus").font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    .accessibilityLabel(L("plans.notIncluded") + ": " + Lor("module." + i.id, i.label))
            }
            if !p.quotas.isEmpty {
                Divider()
                ForEach(p.quotas, id: \.id) { q in
                    Text(quotaLine(q)).font(PN.Font.caption).foregroundStyle(PN.C.text2)
                }
            }
            Spacer(minLength: 4)
            button(p, a)
        }
        .padding(14)
        .frame(width: 230, alignment: .topLeading)
        .frame(minHeight: 360, alignment: .top)
        .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.m))
        .overlay(RoundedRectangle(cornerRadius: PN.Radius.m).stroke(a == .current ? PN.C.turn : PN.C.surface2, lineWidth: a == .current ? 2 : 1))
    }

    @ViewBuilder private func priceLine(_ p: SelfServe.Plan) -> some View {
        if let pr = p.price {
            let per = pr.per == "seat_month" ? " " + L("plan.perSeat") : ""
            if m.beta {
                HStack(spacing: 6) {
                    Text(Entitlements.priceText(pr) + per).strikethrough().font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    Text(L("plan.free", ["zero": Entitlements.zeroText(pr.currency)])).font(PN.Font.caption).foregroundStyle(PN.C.text2)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(L("plans.priceBeta", ["price": Entitlements.priceText(pr) + per]))
            } else {
                Text(Entitlements.priceText(pr) + per).font(PN.Font.body).foregroundStyle(PN.C.text)
            }
        } else {
            Text(L("plans.free")).font(PN.Font.body.weight(.semibold)).foregroundStyle(PN.C.text)
        }
    }

    private func quotaLine(_ q: SelfServe.Quota) -> String {
        let name = Lor("quota." + q.id, q.label)
        guard let l = q.limit, l >= 0 else { return L("plans.unlimited", ["name": name]) }
        return L("plans.limit", ["name": name, "limit": QuotaText.amount(q.id, l)])
    }

    @ViewBuilder private func button(_ p: SelfServe.Plan, _ a: SelfServe.Action) -> some View {
        switch a {
        case .current:
            Text(L("plans.youAreHere")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
        case .choose:
            Button(L("plans.switch", ["plan": p.name])) { m.confirm = p }
                .buttonStyle(.pnPrimary).disabled(m.busy || !acct.signedIn)
        case .startTeam:
            Button(L("plans.startTeam", ["plan": p.name])) { m.teamPlan = p; m.error = ""; m.note = "" }
                .buttonStyle(.pnSecondary).disabled(m.busy || !acct.signedIn)
        case .askOwner:
            Text(L("plans.askOwner")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
        case .custom:
            Button(L("plans.customRequest")) { close(); ConsoleLink.openPlan(m.orgID) }.buttonStyle(.pnTertiary)
        }
    }

    @ViewBuilder private func teamForm(_ p: SelfServe.Plan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("plans.startTeam", ["plan": p.name])).font(PN.Font.section)
            Text(L("plans.team.sub")).font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField(L("plans.team.name"), text: $m.teamName).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                    .onSubmit { Task { await m.startTeam(p) } }
                Button(L("plans.team.create")) { Task { await m.startTeam(p) } }
                    .buttonStyle(.pnPrimary).disabled(m.busy || m.teamName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(L("common.cancel")) { m.teamPlan = nil }.buttonStyle(.pnTertiary)
                if m.busy { ProgressView().controlSize(.small) }
            }
        }
        .padding(12).background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.m))
    }

    @ViewBuilder private var messages: some View {
        if !m.note.isEmpty {
            Label(m.note, systemImage: "checkmark.circle.fill").font(PN.Font.caption).foregroundStyle(PN.C.turn)
        }
        if !m.error.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Label(m.error, systemImage: "exclamationmark.triangle.fill").font(PN.Font.caption).foregroundStyle(PN.C.pending)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(m.misfit, id: \.self) { Text("• " + $0).font(PN.Font.caption).foregroundStyle(PN.C.text2) }
            }
        }
    }
}

/// One plans window at a time, over whatever is open (Settings, a closed feature, Home).
@MainActor
enum PlansWindow {
    static var window: NSWindow?
    static func show(org: String? = nil, from: String) {
        UsageLog.log("plans_opened", ["from": from])
        window?.close()
        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.contentViewController = NSHostingController(rootView: Localized {
            PlansView(orgID: org) { PlansWindow.window?.close() }
        })
        w.title = L("plans.window")
        w.tabbingMode = .disallowed
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
