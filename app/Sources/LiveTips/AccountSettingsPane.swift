import AppKit
import SwiftUI
import LiveTipsCore

/// B7 (server ADR 5.1, 12.2): Settings > Account. Signing in to the Pacenote server is optional; the page says what
/// goes there and what never does, lists the signed-in devices, signs out here or everywhere and deletes the server
/// data. The Mac and Google Drive are never touched from here.
struct AccountSettingsPane: View {
    @ObservedObject private var acct = PacenoteAccount.shared
    @State private var confirmDelete = false
    @State private var confirmDeleteAgain = false
    @State private var confirmEverywhere = false

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
        } header: { Text(L("account.head")) }
    }

    @ViewBuilder private func signedIn(_ s: PacenoteServer.Session) -> some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(PN.C.text2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(acct.me?.name.isEmpty == false ? acct.me!.name : (s.name.isEmpty ? s.email : s.name)).font(.headline)
                    if !s.email.isEmpty { Text(s.email).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
                    ForEach(acct.me?.orgs ?? []) { o in
                        Text(L("account.org", ["name": o.name, "role": L("account.role." + (o.role.isEmpty ? "member" : o.role)), "plan": o.plan.capitalized]))
                            .font(PN.Font.caption).foregroundStyle(PN.C.text2)
                    }
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
        } header: { Text(L("account.head")) }

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
                Text(L("account.delete.sub")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(L("account.delete")) { confirmDelete = true }.buttonStyle(.pnSecondary).disabled(acct.busy)
            }
        } header: { Text(L("account.delete.head")) }
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
