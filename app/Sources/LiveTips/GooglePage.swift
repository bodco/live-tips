import AppKit
import SwiftUI
import LiveTipsCore

/// 0.9.1 (rules/google.yaml): Settings > Integrations > Google. Several accounts, like Notion workspaces: each one
/// with its calendars to show, what it can do (calendars, links, export, Meet) and Remove.
struct GooglePage: View {
    @ObservedObject var g = GoogleService.shared
    /// 0.9.2 (owner): the calendar list of an account is folded; once the calendars are picked it is rarely needed.
    @State private var openCalendars: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Google").font(PN.Font.section).foregroundStyle(PN.C.text)
                Text(L("google.intro")).font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
                if !g.configured {
                    Label(L("google.err.noClient"), systemImage: "exclamationmark.triangle.fill").foregroundStyle(PN.C.pending)
                }
                ForEach(g.accounts) { a in account(a) }
                HStack(spacing: 10) {
                    Button(g.accounts.isEmpty ? L("google.connect") : L("google.addAnother")) { g.addAccount() }
                        .buttonStyle(.pnPrimary).disabled(!g.configured || g.signIn == .waiting)
                    switch g.signIn {
                    case .waiting:
                        ProgressView().controlSize(.small)
                        Text(L("google.waiting")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                        Button(L("common.cancel")) { g.cancelSignIn() }.buttonStyle(.pnTertiary)
                    case .failed(let e):
                        Text(e).font(PN.Font.caption).foregroundStyle(PN.C.danger).lineLimit(2)
                    case .idle: EmptyView()
                    }
                }
                Text(L("google.unverified")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                Text(L("google.what")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                // 0.10.0 (Meeting Sheet, Google Picker): whether "Confirm in Google" can open Google Picker in this build
                Text(L(GooglePickerConfig.load() == nil ? "sheet.google.page.off" : "sheet.google.page.on")).font(PN.Font.caption)
                    .foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
    }

    private func can(_ a: GoogleAccount, _ s: [String], _ key: String) -> some View {
        let ok = a.has(s)
        return Label(L(key), systemImage: ok ? "checkmark.circle.fill" : "minus.circle")
            .foregroundStyle(ok ? PN.C.turn : PN.C.text3).font(PN.Font.caption)
            .help(ok ? "" : L("google.scopeOff"))
    }

    @ViewBuilder private func account(_ a: GoogleAccount) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "person.crop.circle").foregroundStyle(PN.C.text2)
                Text(a.email).font(.headline)
                Spacer()
                if let e = g.lastError[a.email] {
                    Text(e).font(PN.Font.caption).foregroundStyle(PN.C.pending).lineLimit(1)
                    Button(L("google.signInAgain")) { g.addAccount(hint: a.email) }.buttonStyle(.pnTertiary)
                }
                Button(L("google.remove")) { g.remove(a.email) }.buttonStyle(.pnTertiary)
                    .help(L("google.removeHelp"))
            }
            HStack(spacing: 14) {
                can(a, GoogleScopes.calendar, "google.can.calendar")
                can(a, GoogleScopes.files, "google.can.links")
                can(a, GoogleScopes.export, "google.can.export")
                can(a, GoogleScopes.meet, "google.can.meet")
            }
            let cals = g.calendars.filter { $0.account == a.email }
            if !cals.isEmpty {
                let open = openCalendars.contains(a.email)
                Button {
                    if open { openCalendars.remove(a.email) } else { openCalendars.insert(a.email) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2.weight(.semibold))
                        Text(L("google.calendars")).font(PN.Font.caption.weight(.semibold))
                        Text(L("google.calendarsOn", ["n": String(cals.filter { g.isOn($0) }.count), "total": String(cals.count)]))
                            .font(PN.Font.caption)
                            .foregroundStyle(PN.C.text3)
                    }
                    .foregroundStyle(PN.C.text2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("google.calendars"))
                if open { ForEach(cals) { c in
                    Toggle(isOn: Binding(get: { g.isOn(c) }, set: { g.setOn(c, $0) })) {
                        HStack(spacing: 6) {
                            Circle().fill(Color(nsColor: NSColor(hex: c.color) ?? .systemBlue)).frame(width: 8, height: 8)
                            Text(c.title).lineLimit(1)
                            if c.primary { Text(L("google.primary")).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
                        }
                    }
                    .toggleStyle(.checkbox)
                } }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
    }
}
