import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LiveTipsCore

/// B7 (server ADR 5.1, 12.2): Settings > Account. Signing in to the Pacenote server is optional; the page says what
/// goes there and what never does, lists the signed-in devices, signs out here or everywhere and deletes the server
/// data. The Mac and Google Drive are never touched from here.
struct AccountSettingsPane: View {
    @ObservedObject private var acct = PacenoteAccount.shared
    @State private var confirmDelete = false
    @State private var confirmDeleteAgain = false
    @State private var confirmEverywhere = false
    @State private var exporting = false          // 0.12.1 (B8): Export server data
    @State private var exportNote = ""

    var body: some View {
        Form {
            if let s = acct.session { signedIn(s) } else { signedOut }

            Section {
                Text(L("account.what.goes")).fixedSize(horizontal: false, vertical: true)
                Text(L("account.what.never")).fixedSize(horizontal: false, vertical: true)
                Text(L("account.what.where")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    Link(L("account.privacy"), destination: URL(string: "https://pacenote.bodco.pm/privacy/")!)
                    Link(L("account.terms"), destination: URL(string: "https://pacenote.bodco.pm/terms/")!)
                }
                .font(PN.Font.caption)
            } header: { Text(L("account.what.head")) }
        }
        .formStyle(.grouped)
        .onAppear { if acct.signedIn { Task { await acct.refreshInfo() } } }
        .alert(L("account.delete.q1"), isPresented: $confirmDelete) {
            Button(L("account.delete.continue"), role: .destructive) { confirmDeleteAgain = true }
            Button(L("common.cancel"), role: .cancel) {}
        } message: { Text(L("account.delete.m1")) }
        .alert(L("account.delete.q2"), isPresented: $confirmDeleteAgain) {
            Button(L("account.delete.final"), role: .destructive) { Task { await acct.deleteServerData() } }
            Button(L("common.cancel"), role: .cancel) {}
        } message: { Text(L("account.delete.m2")) }
        .alert(L("account.everywhere.q"), isPresented: $confirmEverywhere) {
            Button(L("account.signOutEverywhere"), role: .destructive) { Task { await acct.signOut(everywhere: true) } }
            Button(L("common.cancel"), role: .cancel) {}
        } message: { Text(L("account.everywhere.m")) }
    }

    @ViewBuilder private var signedOut: some View {
        Section {
            Text(L("account.intro")).fixedSize(horizontal: false, vertical: true)
            Text(L("account.optional")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(L("account.signIn")) { acct.startSignIn() }
                    .buttonStyle(.pnPrimary).disabled(!GoogleService.shared.configured || acct.signIn == .waiting)
                switch acct.signIn {
                case .waiting:
                    ProgressView().controlSize(.small)
                    Text(L("google.waiting")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    Button(L("common.cancel")) { acct.cancelSignIn() }.buttonStyle(.pnTertiary)
                case .failed(let e):
                    Text(e).font(PN.Font.caption).foregroundStyle(PN.C.danger).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                case .idle: EmptyView()
                }
            }
            if !GoogleService.shared.configured {
                Label(L("google.err.noClient"), systemImage: "exclamationmark.triangle.fill").foregroundStyle(PN.C.pending)
            }
            Text(L("account.signIn.sub")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            if let n = acct.notice { Text(n).font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true) }
        } header: { Text(L("account.head")).settingsAnchor("acc.head") }
    }

    @ViewBuilder private func signedIn(_ s: PacenoteServer.Session) -> some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(PN.C.text2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(acct.me?.name.isEmpty == false ? acct.me!.name : (s.name.isEmpty ? s.email : s.name)).font(.headline)
                    if !s.email.isEmpty { Text(s.email).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
                }
                Spacer()
                if acct.busy { ProgressView().controlSize(.small) }
                Button(L("account.signOut")) { Task { await acct.signOut(everywhere: false) } }.buttonStyle(.pnSecondary).disabled(acct.busy)
            }
            Text(L("account.syncLater")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            if let p = acct.problem {
                Label(p, systemImage: "exclamationmark.triangle.fill").font(PN.Font.caption).foregroundStyle(PN.C.pending)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: { Text(L("account.head")).settingsAnchor("acc.head") }

        AccountOrgsSection()       // 0.17.0 (B6b): organizations, where new calls go, invites, Manage organization
        AccountPlanSection()       // 0.18.0 (B3): the plan of each organization, the beta mark, trial, limits
        AccountUsageSection()      // 0.19.0: my own use (GET /v1/me/usage), also on Solo
        AccountCallViewsSection()  // 0.20.0 (B9, D47.7): who opened my calls, when a lead or C-level sees them

        Section {
            if acct.devices.isEmpty {
                Text(L(acct.busy ? "common.checking" : "account.devices.none")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            ForEach(acct.devices) { d in
                HStack {
                    Image(systemName: "laptopcomputer").foregroundStyle(PN.C.text2)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(d.name.isEmpty ? "Mac" : d.name)
                            if d.current { Text(L("account.devices.this")).font(PN.Font.caption).foregroundStyle(PN.C.turn) }
                        }
                        Text(Self.deviceLine(d)).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    }
                    Spacer()
                    if !d.current {
                        Button(L("account.signOut")) { Task { await acct.revoke(d) } }.buttonStyle(.pnTertiary).disabled(acct.busy)
                    }
                }
            }
            HStack {
                Button(L("account.signOutEverywhere")) { confirmEverywhere = true }.buttonStyle(.pnTertiary).disabled(acct.busy)
                Spacer()
                Button(L("account.refresh")) { Task { await acct.refreshInfo() } }.buttonStyle(.pnTertiary).disabled(acct.busy)
            }
        } header: { Text(L("account.devices.head")) }

        Section {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("account.export.sub")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                    if !exportNote.isEmpty { Text(exportNote).font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer()
                Button(L(exporting ? "account.export.busy" : "account.export")) { exportServerData() }
                    .buttonStyle(.pnSecondary).disabled(acct.busy || exporting)
            }
            HStack(alignment: .top) {
                Text(L("account.delete.sub")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(L("account.delete")) { confirmDelete = true }.buttonStyle(.pnSecondary).disabled(acct.busy)
            }
        } header: { Text(L("account.delete.head")) }
    }

    /// 0.12.1 (B8): downloads the export zip and asks where to keep it.
    private func exportServerData() {
        exporting = true; exportNote = ""
        Task {
            defer { exporting = false }
            do {
                let data = try await acct.exportData()
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
                let p = NSSavePanel()
                p.allowedContentTypes = [UTType(filenameExtension: "zip") ?? .data]
                p.nameFieldStringValue = "pacenote-export-" + f.string(from: Date()) + ".zip"
                guard p.runModal() == .OK, let url = p.url else { return }
                try data.write(to: url, options: .atomic)
                exportNote = L("account.export.saved", ["file": url.lastPathComponent])
            } catch { exportNote = error.localizedDescription }
        }
    }

    static func deviceLine(_ d: PacenoteServer.Device) -> String {
        let v = d.appVersion.isEmpty ? "" : "Pacenote " + d.appVersion
        guard let seen = d.lastSeen else { return v }
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .full
        f.locale = Locale(identifier: L10n.lang)
        let now = Date()
        // "in 0 seconds" for this Mac (seen just now, or a server clock a little ahead): say "active now" instead
        let when = now.timeIntervalSince(seen) < 60 ? L("account.devices.now")
            : L("account.devices.seen", ["when": f.localizedString(for: min(seen, now), relativeTo: now)])
        return v.isEmpty ? when : v + " · " + when
    }
}

/// 0.18.0 (B3, spec 6.3, 7, 11; D32, D42): Settings > Account > Plan. The plan of each organization from the signed
/// entitlements (a hidden plan reads "Custom"), the beta mark (planned price struck through, 0, until further
/// notice, 30 days' notice), a trial, the limits, Request plan for owner and admin, and a quiet line when the plan
/// info is old. Nothing here is decided by the app: it shows what the server signed.
struct AccountPlanSection: View {
    @ObservedObject private var acct = PacenoteAccount.shared
    @ObservedObject private var store = EntitlementsStore.shared
    static let shownQuotas = ["seats", "storage_mb", "tip_minutes", "org_projects_max"]

    var body: some View {
        let r = store.rights
        if let me = acct.me {
            Section {
                if case .stale(let days) = r.basis {
                    Label(L("plan.stale", ["n": "\(days)"]), systemImage: "clock.arrow.circlepath")
                        .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                }
                if r.basis == .soloFallback {
                    Label(L("plan.fallback"), systemImage: "exclamationmark.triangle").font(PN.Font.caption).foregroundStyle(PN.C.pending)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if r.allPlansFree {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(L("plan.beta"), systemImage: "sparkles").font(PN.Font.body.weight(.semibold)).foregroundStyle(PN.C.turn)
                        Text(L("plan.beta.note", ["days": "\(r.billingNoticeDays)"])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(me.orgs) { o in orgRow(o, r.record(o.id), free: r.allPlansFree) }
                HStack {
                    Button(L("plans.compare")) { PlansWindow.show(org: me.defaultOrg?.id, from: "account") }
                        .buttonStyle(.pnSecondary).help(L("plans.compare.help"))
                    Spacer()
                }
            } header: { Text(L("plan.head")).settingsAnchor("acc.plan") }
        }
    }

    @ViewBuilder private func orgRow(_ o: PacenoteServer.Org, _ rec: Entitlements.Record?, free: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(o.isPersonal ? L("org.personal") : o.name).foregroundStyle(PN.C.text2)
                Text(rec?.plan.label ?? (o.plan.isEmpty ? L("plan.unknown") : o.plan.capitalized)).font(PN.Font.body.weight(.semibold))
                if let p = rec?.plan.plannedPrice { price(p, free: free) }
                Spacer()
                if rec?.canRequestPlan == true || o.isPersonal {
                    // 0.19.0: the plans in the app (switch, or start a team from the personal space); a custom plan still
                    // goes to the console, where Pacenote changes it
                    if rec?.plan.id == nil && rec != nil {
                        Button(L("plan.request")) { UsageLog.log("plan_request_opened", ["from": "account"]); ConsoleLink.openPlan(o.id) }
                            .buttonStyle(.pnTertiary).help(L("plan.request.help"))
                    } else {
                        Button(L("plans.change")) { PlansWindow.show(org: o.id, from: "account") }
                            .buttonStyle(.pnTertiary).help(L("plans.compare.help"))
                    }
                }
            }
            if let t = rec?.plan.trial { Text(trialLine(t, free: free)).font(PN.Font.caption).foregroundStyle(t.ended ? PN.C.text3 : PN.C.turn) }
            if let rec {
                ForEach(Self.shownQuotas.filter { rec.quotas[$0]?.limit != nil }, id: \.self) { id in
                    let q = rec.quotas[id]!
                    Text(QuotaText.line(id, q)).font(PN.Font.caption)
                        .foregroundStyle(q.state == "exhausted" ? PN.C.danger : q.state == "warn" ? PN.C.pending : PN.C.text3)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// "$12" struck through, then "$0 until further notice" (beta), or the price as it is.
    @ViewBuilder private func price(_ p: Entitlements.Price, free: Bool) -> some View {
        let per = p.per == "seat_month" ? " " + L("plan.perSeat") : ""
        if free {
            Text(Entitlements.priceText(p) + per).strikethrough().font(PN.Font.caption).foregroundStyle(PN.C.text3)
            Text(L("plan.free", ["zero": Entitlements.zeroText(p.currency)])).font(PN.Font.caption).foregroundStyle(PN.C.text2)
        } else {
            Text(Entitlements.priceText(p) + per).font(PN.Font.caption).foregroundStyle(PN.C.text2)
        }
    }

    private func trialLine(_ t: Entitlements.Trial, free: Bool) -> String {
        if !t.ended && t.endsAt > Date() { return L("plan.trial.left", ["n": "\(t.daysLeft(now: Date()))"]) }
        return L(free ? "plan.trial.endedBeta" : "plan.trial.ended")
    }
}

/// 0.19.0 (server 0.11.0): Settings > Account > Your use. The person's own numbers for the last 30 days from the
/// server (what Help improve Pacenote sent), with Open my overview (the console's /me). Nothing about anyone else.
struct AccountUsageSection: View {
    @ObservedObject private var acct = PacenoteAccount.shared
    @State private var usage: SelfServe.Usage?
    @State private var failed = false

    var body: some View {
        if acct.me != nil {
            Section {
                if let u = usage {
                    if u.calls == 0 && u.activeDays == 0 {
                        Text(L("usage.none", ["days": "\(u.days)"])).foregroundStyle(PN.C.text2)
                    } else {
                        Text(L("usage.line", ["days": "\(u.days)", "active": "\(u.activeDays)", "calls": "\(u.calls)", "hours": u.hoursText]))
                            .fixedSize(horizontal: false, vertical: true)
                        bars(u.callsByDay)
                    }
                } else if failed {
                    Text(L("usage.failed")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(L("usage.note")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(L("usage.open")) { ConsoleLink.open(path: "/me") }.buttonStyle(.pnTertiary).help(L("usage.open.help"))
                    Spacer()
                }
            } header: { Text(L("usage.head")).settingsAnchor("acc.usage") }
            .task { await load() }
        }
    }

    /// Calls by day as small bars, for the shape only (the numbers are above and in the console).
    private func bars(_ v: [Int]) -> some View {
        let top = max(v.max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(v.enumerated()), id: \.offset) { _, n in
                RoundedRectangle(cornerRadius: 1).fill(n > 0 ? PN.C.brand : PN.C.surface2)
                    .frame(width: 6, height: max(2, 28 * CGFloat(n) / CGFloat(top)))
            }
        }
        .frame(height: 30, alignment: .bottom)
        .accessibilityHidden(true)
    }

    private func load() async {
        guard let r = try? await acct.api("GET", "/v1/me/usage?days=30"), r.1 == 200, let u = SelfServe.usage(r.0) else { failed = true; return }
        usage = u; failed = false
    }
}
