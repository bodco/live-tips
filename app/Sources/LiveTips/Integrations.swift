import AppKit
import SwiftUI
import LiveTipsCore

// 0.8.7 (F1-F2, rules/crm.yaml): Settings > Integrations. A card per connection (Notion, Calendars, HubSpot) with its
// status; a click opens the connection's page. Without a key everything on the page but the key itself is disabled.

/// The list of connections. A new one (another CRM) is one entry here and one page.
@MainActor
enum IntegrationRegistry {
    struct Item: Identifiable { let id: String; let title: String; let symbol: String; let subtitle: String }
    static var items: [Item] { [
        Item(id: "notion", title: "Notion", symbol: "doc.text", subtitle: L("int.notion.sub")),
        Item(id: "calendars", title: L("settings.tab.calendars"), symbol: "calendar", subtitle: L("int.calendars.sub")),
        Item(id: "google", title: "Google", symbol: "globe", subtitle: L("int.google.sub")),
        Item(id: "hubspot", title: "HubSpot", symbol: "briefcase", subtitle: L("int.hubspot.sub")),
    ] }

    /// One line under the card's title and whether it is connected (nil = not set up).
    /// `short`: the list row shows "Connected" without the account name, so the row's description keeps its room.
    static func status(_ id: String, _ m: SettingsModel, short: Bool = false) -> (String, Bool?) {
        switch id {
        case "notion":
            guard m.isSet(.notionToken) else { return (L("int.notConnected"), nil) }
            if case .failed(let e) = m.keyState[.notionToken] ?? .untested { return (e, false) }
            let dbs = [m.config.notionMeetingsDB, m.config.notionTasks.database, m.config.notionRisksDB].filter { !$0.isEmpty }.count
            return (L("int.notion.status", ["n": "\(dbs)"]), true)
        case "calendars":
            let n = CalendarService.shared.calendars.count
            return n == 0 ? (L("int.notConnected"), nil) : (L("int.calendars.status", ["n": "\(n)"]), true)
        case "google":
            let g = GoogleService.shared
            guard g.connected else { return (L("int.notConnected"), nil) }
            if !g.lastError.isEmpty { return (L("google.err.signInAgain"), false) }
            return (L("int.google.status", ["n": "\(g.accounts.count)"]), true)
        case "hubspot":
            guard m.isSet(.hubspotKey) else { return (L("int.notConnected"), nil) }
            if !m.config.crm.missingScopes.isEmpty { return (L("int.hubspot.scopes", ["n": "\(m.config.crm.missingScopes.count)"]), false) }
            if case .failed(let e) = CRMService.shared.state { return (e, false) }
            if short { return (L("keys.connected"), true) }
            return (m.config.crm.account.isEmpty ? L("keys.saved") : L("int.connectedTo", ["name": m.config.crm.account]), true)
        default: return ("", nil)
        }
    }
}

struct IntegrationsPane<NotionPage: View>: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var crm = CRMService.shared
    @ObservedObject var cal = CalendarService.shared
    let notion: () -> NotionPage

    // 0.8.7 (A4): push navigation inside the pane. The path is model.integration, so SettingsWindow.show(tab:) and the
    // old tab names ("notion", "keys", "calendars", "hubspot") still open the right page. Back and Command-[ pop it.
    var body: some View {
        NavigationStack(path: Binding(get: { model.integration.map { [$0] } ?? [] }, set: { model.integration = $0.last })) {
            list
                .navigationDestination(for: String.self) { id in
                    VStack(alignment: .leading, spacing: 0) {
                        Button { model.integration = nil } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                Text(L("int.all")).lineLimit(1)
                            }
                        }
                        .buttonStyle(.pnTertiary).keyboardShortcut("[", modifiers: .command)
                        .help(L("nav.back.help"))
                        .padding(.horizontal, 20).padding(.top, 8)
                        // 0.15.0 (D2): the pane header is hidden on this page, so the page names itself and its state
                        if let it = IntegrationRegistry.items.first(where: { $0.id == id }) {
                            let st = IntegrationRegistry.status(id, model)
                            HStack(spacing: 10) {
                                Text(it.title).font(.system(size: 20, weight: .semibold))
                                IntegrationStatus(text: st.0, ok: st.1)
                            }
                            .padding(.horizontal, 28).padding(.top, 4)
                        }
                        switch id {
                        case "notion": notion()
                        case "calendars": CalendarsPane()
                        case "google": GooglePage()
                        default: HubSpotPage(model: model)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .navigationBarBackButtonHidden(true)
                }
        }
    }

    // 0.15.0 (D2): one card of rows, small symbols; a connection that is not set up has a Connect button
    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                VStack(spacing: 0) {
                    ForEach(Array(IntegrationRegistry.items.enumerated()), id: \.element.id) { n, it in
                        let st = IntegrationRegistry.status(it.id, model, short: true)
                        if n > 0 { Divider().padding(.leading, 40) }
                        Button { model.integration = it.id } label: {
                            HStack(spacing: 12) {
                                Image(systemName: it.symbol).font(.system(size: 15)).frame(width: 20).foregroundStyle(PN.C.text2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(it.title).fontWeight(.semibold)
                                    Text(it.subtitle).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 8)
                                IntegrationStatus(text: st.0, ok: st.1).fixedSize()
                                if st.1 == nil {
                                    Text(L("int.connect")).font(PN.Font.caption.weight(.semibold)).foregroundStyle(.white)
                                        .padding(.horizontal, 9).padding(.vertical, 3)
                                        .background(RoundedRectangle(cornerRadius: 6).fill(PN.C.accent))
                                }
                                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(PN.C.text3)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(it.title + ", " + st.0)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
                Text(L("int.keysNote")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            .padding(20)
        }
        .scrollContentBackground(.hidden)
    }
}

/// A dot and a word: green connected, orange needs you, grey not set up.
struct IntegrationStatus: View {
    let text: String
    let ok: Bool?
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(ok == true ? PN.C.turn : (ok == false ? PN.C.onMe : PN.C.text3.opacity(0.5))).frame(width: 8, height: 8)
            Text(text).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(1)
        }
    }
}

// MARK: - CRM

/// The CRM connection for the app. The key is read from the Keychain for each request and never kept in a field,
/// printed or written to a file (rules/crm.yaml > auth).
@MainActor
final class CRMService: ObservableObject {
    static let shared = CRMService()
    enum State: Equatable { case idle, testing, ok(String), failed(String) }
    @Published var state: State = .idle
    var store: SecretStore { SecretStore(service: Bundle.main.bundleIdentifier ?? "io.github.example.livetips") }

    var connected: Bool { store.has(.hubspotKey) }     // 0.8.7.1: presence only, no Keychain prompt

    /// A connector built for one job; nil without a key.
    func connector() -> CRMConnector? {
        guard let k = store.get(.hubspotKey) else { return nil }
        return HubSpotConnector(transport: URLSessionTransport(key: k), ownerId: SettingsWindow.model.config.crm.ownerId)
    }

    func test() {
        guard let c = connector() else { state = .idle; return }
        state = .testing
        Task {
            do {
                let a = try await c.testConnection()
                var cfg = SettingsWindow.model.config
                cfg.crm.account = a.portal
                cfg.crm.lastTest = ISO8601DateFormatter().string(from: Date())
                cfg.crm.missingScopes = []
                // the scopes the key lacks show up as 403 on a read of each object
                for (scope, path) in [("crm.objects.deals.read", "/crm/v3/objects/deals?limit=1"),
                                      ("crm.objects.contacts.read", "/crm/v3/objects/contacts?limit=1"),
                                      ("crm.objects.companies.read", "/crm/v3/objects/companies?limit=1")] {
                    if let hs = c as? HubSpotConnector, (try? await hs.call("GET", path)) == nil { cfg.crm.missingScopes.append(scope) }
                }
                // 0.8.7 (I6.2): the owner is picked by the user's email until the PM chooses one
                if cfg.crm.ownerAuto, let os = try? await c.owners(), let o = CRMOwner.pick(os, emails: Self.ownEmails) {
                    cfg.crm.ownerId = o.id; cfg.crm.ownerName = o.name
                }
                SettingsWindow.model.config = cfg
                state = .ok(a.user.isEmpty ? a.portal : a.portal + ", " + a.user)
            } catch {
                state = .failed((error as? CRMError)?.message ?? error.localizedDescription)
            }
        }
    }
}

struct HubSpotPage: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var crm = CRMService.shared
    @ObservedObject var sm = SalesMethods.shared
    @State private var copied = false
    @State private var owners: [CRMOwner] = []
    struct DealProp: Hashable { let name: String; let label: String }
    @State private var dealProps: [DealProp] = []
    @State private var loadErr = ""
    @AppStorage(SettingsSearch.hubspotGroupKey) private var group = "conn"

    var body: some View {
        // 0.15.0 (D2): four groups, one at a time; without a key only Connection
        let keyed = model.isSet(.hubspotKey)
        let g = keyed ? group : "conn"
        return VStack(spacing: 0) {
            if keyed {
                SettingsSegments(selection: $group, groups: SettingsSearch.hubspotGroups, prefix: "hs.group.")
                    .padding(.horizontal, 28).padding(.top, 10)
            }
        Form {
            if g == "conn" {
            Section {
                KeyRow(title: L("int.hubspot.key"), hint: L("int.hubspot.keyHint"), key: .hubspotKey, model: model)
                    .settingsAnchor("int.hubspot.key")
                if model.isSet(.hubspotKey) {
                    HStack {
                        switch crm.state {
                        case .ok(let s): Label(L("int.connectedTo", ["name": s]), systemImage: "checkmark.circle.fill").foregroundStyle(PN.C.turn)
                        case .failed(let e): Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(PN.C.danger)
                        case .testing: ProgressView().controlSize(.small); Text(L("common.checking")).foregroundStyle(PN.C.text3)
                        case .idle: Text(model.config.crm.account.isEmpty ? L("int.hubspot.untested") : L("int.connectedTo", ["name": model.config.crm.account])).foregroundStyle(PN.C.text3)
                        }
                        Spacer()
                        Button(L("keys.test")) { crm.test() }.buttonStyle(.pnSecondary).disabled(crm.state == .testing)
                    }
                    .font(PN.Font.caption)
                }
                // 0.8.7 (I2, I6): how to create the key, step by step, right next to the field
                DisclosureGroup(L("int.hubspot.how")) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(1...6, id: \.self) { i in
                            Text("\(i). " + L("int.hubspot.how\(i)")).font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 4)
                }
            } header: { Text(L("set.connection")) } footer: {
                Text(L("int.hubspot.keyFooter")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(HubSpotConnector.scopes, id: \.self) { s in
                        HStack(spacing: 6) {
                            // 0.8.7: after a good Test every scope on the key gets a green tick; a missing one a red cross;
                            // a grey circle only means "not tested yet" (an empty circle read as "not ticked")
                            let missing = model.config.crm.missingScopes.contains(s)
                            let tested = !model.config.crm.lastTest.isEmpty
                            Image(systemName: missing ? "xmark.circle.fill" : (tested ? "checkmark.circle.fill" : "circle"))
                                .foregroundStyle(missing ? PN.C.danger : (tested ? PN.C.turn : PN.C.text3)).font(.caption)
                            Text(s).font(PN.Font.caption.monospaced())
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button(copied ? L("int.copied") : L("int.copyList")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(HubSpotConnector.scopes.joined(separator: "\n"), forType: .string)
                        copied = true
                    }.buttonStyle(.pnTertiary)
                }
            } header: { Text(L("int.hubspot.scopesTitle")) } footer: {
                Text(L("int.hubspot.scopesFooter")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            }
            }
            // 0.8.7 (F4, I6): without a key the page shows only Connection
            if g == "match" { matching }
            if g == "data" {
                reads
                Section {
                    Toggle(L("int.hubspot.writeNote"), isOn: $model.config.crm.writeNote)
                    Toggle(L("int.hubspot.writeDeal"), isOn: $model.config.crm.writeDeal)
                    Toggle(L("int.hubspot.writeTask"), isOn: $model.config.crm.writeTask)
                    Toggle(L("int.hubspot.transcript"), isOn: $model.config.crm.transcriptInNote).help(L("int.hubspot.transcriptHelp"))
                } header: { Text(L("int.hubspot.canWrite")).settingsAnchor("int.hubspot.write") } footer: {
                    Text(L("int.hubspot.afterFooter")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
            if g == "qual" { qualification }
        }
        .formStyle(.grouped)
        }
        .onAppear { if model.isSet(.hubspotKey) { loadLists() } }
    }

    // I6.2: the company by the attendees' email domains; the owner of what Pacenote writes
    private var matching: some View {
        Section {
            Toggle(L("int.hubspot.matchDomains"), isOn: $model.config.crm.matchByDomain).help(L("int.hubspot.matchDomainsHelp"))
            Picker(L("int.hubspot.owner"), selection: Binding(get: { model.config.crm.ownerId }, set: { id in
                model.config.crm.ownerId = id
                model.config.crm.ownerName = owners.first { $0.id == id }?.name ?? ""
                model.config.crm.ownerAuto = false
            })) {
                Text(L("int.hubspot.ownerNone")).tag("")
                if !model.config.crm.ownerId.isEmpty, !owners.contains(where: { $0.id == model.config.crm.ownerId }) {
                    Text(model.config.crm.ownerName.isEmpty ? L("int.hubspot.ownerUnknown") : model.config.crm.ownerName).tag(model.config.crm.ownerId)
                }
                ForEach(owners) { o in Text(o.name).tag(o.id) }
            }
            .help(L("int.hubspot.ownerHelp"))
            if !loadErr.isEmpty { Text(loadErr).font(PN.Font.caption).foregroundStyle(PN.C.danger) }
        } header: { Text(L("int.hubspot.matching")).settingsAnchor("int.hubspot.match") } footer: {
            Text(model.config.crm.ownerAuto ? L("int.hubspot.ownerAuto") : L("int.hubspot.ownerChosen"))
                .font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
        }
    }

    // I6.3: read only
    private var reads: some View {
        Section {
            ForEach(["deals", "contacts", "activity", "tasks"], id: \.self) { k in
                HStack(spacing: 8) {
                    Image(systemName: "eye").foregroundStyle(PN.C.text3).font(.caption)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L("int.hubspot.read." + k))
                        Text(L("int.hubspot.read." + k + ".sub")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    }
                }
            }
        } header: { Text(L("int.hubspot.reads")) }
    }

    // I6.5: a deal property for each criterion of each method, or Don't write
    private var qualification: some View {
        Section {
            ForEach(sm.methods.filter { !$0.criteria.isEmpty }) { m in
                DisclosureGroup(m.name) {
                    ForEach(m.criteria) { c in
                        Picker(c.name, selection: Binding(get: { model.config.crm.qualification[m.key]?[c.key] ?? "" },
                                                          set: { v in var mm = model.config.crm.qualification[m.key] ?? [:]; mm[c.key] = v; model.config.crm.qualification[m.key] = mm })) {
                            Text(L("int.hubspot.dontWrite")).tag("")
                            let cur = model.config.crm.qualification[m.key]?[c.key] ?? ""
                            if !cur.isEmpty, !dealProps.contains(where: { $0.name == cur }) { Text(L("int.hubspot.propMissing")).tag(cur) }
                            ForEach(dealProps, id: \.self) { p in Text(p.label).tag(p.name) }
                        }
                        .help(c.explain)
                    }
                }
            }
        } header: { Text(L("int.hubspot.qualification")).settingsAnchor("int.hubspot.qual") } footer: {
            Text(L("int.hubspot.qualificationFooter")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { sm.load() }
    }

    private func loadLists() {
        guard let c = crm.connector() else { return }
        Task {
            do {
                let os = try await c.owners()
                owners = os
                if model.config.crm.ownerAuto, let o = CRMOwner.pick(os, emails: CRMService.ownEmails) {
                    model.config.crm.ownerId = o.id; model.config.crm.ownerName = o.name
                }
                dealProps = try await c.properties(objectType: "deals").map { DealProp(name: $0.name, label: $0.label) }
                loadErr = ""
            } catch { loadErr = (error as? CRMError)?.message ?? error.localizedDescription }
        }
    }
}
