import AppKit
import LiveTipsCore
import SwiftUI

// INT S2 (D52): "Connect with Notion" through the Pacenote server. The server holds the client secret and the callback
// (server INT S1, integrations.py); the token pair lives only in the Keychain (SecretStore.Key.notionOAuth). Flow: a
// one-shot LoopbackReceiver on 127.0.0.1 -> POST /v1/integrations/notion/start {port} -> the browser opens Notion's
// consent -> the server's callback exchanges the code and sends the browser to 127.0.0.1:<port>/notion?handoff= ->
// POST /claim {handoff} -> the pair. A token never travels in a URL. Refresh only after a 401 from Notion.
// After the consent Pacenote makes its own "Pacenote" page at the top of the workspace and the databases it needs
// (NotionWorkspaceSetup), unless the person picks databases they already have (Settings > Integrations > Notion).

@MainActor
final class NotionAuth: ObservableObject {
    static let shared = NotionAuth()

    enum State: Equatable { case idle, waiting, claiming, settingUp, failed(String) }
    @Published private(set) var state: State = .idle
    /// The connected workspace (nil: not connected through OAuth). Read off the main thread at start.
    @Published private(set) var record: NotionOAuthRecord?
    /// Notion refused the refresh token: the person connects again (Reconnect).
    @Published private(set) var needsReconnect = false
    /// One line under the connection after the setup ("Pacenote made Meetings, Tasks ... in <workspace>").
    @Published var note = ""
    /// Notion showed Pacenote databases the person already has (Control Tower): they choose between those and
    /// Pacenote's own ones instead of Pacenote making copies by itself (Bohdan 19.11).
    @Published var offerChoice = false

    private var receiver: LoopbackReceiver?
    private var refreshing: Task<String?, Never>?

    nonisolated static var store: SecretStore { SecretStore(service: Bundle.main.bundleIdentifier ?? "io.github.example.livetips") }

    private init() {
        if SheetShots.active { return }
        let st = Self.store
        DispatchQueue.global(qos: .userInitiated).async {
            let r = st.has(.notionOAuth) ? NotionOAuthRecord.decode(st.get(.notionOAuth)) : nil
            DispatchQueue.main.async { MainActor.assumeIsolated { NotionAuth.shared.record = r } }
        }
    }

    // MARK: the one token

    /// The token for every Notion call and for the Python tools (env NOTION_TOKEN): OAuth when connected, else the key
    /// pasted under Advanced. Never logged.
    nonisolated static func token() -> String? {
        let s = store
        let o = s.has(.notionOAuth) ? NotionOAuthRecord.decode(s.get(.notionOAuth)) : nil
        return NotionOAuthCore.pick(oauth: o, manual: s.has(.notionToken) ? s.get(.notionToken) : nil).token
    }

    /// Presence only (no Keychain prompt): Notion is connected one way or the other.
    nonisolated static var connected: Bool { store.has(.notionOAuth) || store.has(.notionToken) }
    nonisolated static var viaOAuth: Bool { store.has(.notionOAuth) }

    var busy: Bool { [.waiting, .claiming, .settingUp].contains(state) }

    // MARK: before a Python tool (INT S3)

    private static let checkLock = NSLock()
    nonisolated(unsafe) private static var lastCheckOK: Date?

    /// Before a child process gets NOTION_TOKEN: with the OAuth token, one GET /users/me through NotionAPI (a 401
    /// refreshes the pair through the server) at most every NotionTokenCheck.window, then `then` on the main queue with
    /// the token as it is now. A pasted key, or a check inside the window, runs `then` at once. Offline or a failed
    /// check still runs `then`: the tool reports its own Notion error. The token is never logged.
    nonisolated static func ensureFresh(_ then: @escaping @Sendable (String?) -> Void) {
        checkLock.lock(); let last = lastCheckOK; checkLock.unlock()
        guard NotionTokenCheck.needed(viaOAuth: viaOAuth, lastOK: last), let tok = token() else { then(token()); return }
        Task.detached(priority: .userInitiated) {
            let ok = (try? await NotionAPI.call(tok, "GET", "/users/me")) != nil
            if ok { checkLock.lock(); lastCheckOK = Date(); checkLock.unlock() }
            AppLog.app("notion: token check before a tool \(ok ? "ok" : "failed")")
            DispatchQueue.main.async { then(token()) }
        }
    }

    // MARK: connect

    func connect() {
        let account = PacenoteAccount.shared
        guard account.signedIn else { state = .failed(L("ntauth.err.signIn")); return }
        receiver?.cancel()
        let r = LoopbackReceiver(); receiver = r
        r.okTitle = "Pacenote is connected to Notion"
        r.okMarker = "handoff="
        r.failTitle = "Notion did not connect"
        state = .waiting; note = ""
        r.start({ [weak self] port in
            guard let self else { return }
            guard let port else { self.state = .failed(L("google.err.loopback")); return }
            Task { @MainActor in
                do {
                    let (d, c) = try await account.api("POST", NotionOAuthCore.startPath, body: NotionOAuthCore.startBody(port: port))
                    guard c == 200, let url = NotionOAuthCore.authorizeURL(d) else {
                        self.receiver?.cancel()
                        self.state = .failed(c == 503 ? L("ntauth.err.server") : PacenoteServer.problem(d, status: c))
                        return
                    }
                    NSWorkspace.shared.open(url)
                } catch {
                    self.receiver?.cancel()
                    self.state = .failed(error.localizedDescription)
                }
            }
        }, received: { [weak self] target in
            guard let self else { return }
            NSApp?.activate(ignoringOtherApps: true)
            guard let target else { if self.state == .waiting { self.state = .idle }; return }
            switch NotionOAuthCore.loopback(target) {
            case .handoff(let h): Task { await self.claim(h) }
            case .denied: self.state = .failed(L("ntauth.err.denied"))
            case .failed: self.state = .failed(L("ntauth.err.exchange"))
            case .bad: self.state = .failed(L("ntauth.err.exchange"))
            }
        })
    }

    func cancel() { receiver?.cancel(); receiver = nil; if state == .waiting { state = .idle } }

    private func claim(_ handoff: String) async {
        state = .claiming
        do {
            let (d, c) = try await PacenoteAccount.shared.api("POST", NotionOAuthCore.claimPath, body: NotionOAuthCore.claimBody(handoff: handoff))
            let o = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any]) ?? [:]
            guard c == 200, let r = NotionOAuthRecord.from(pair: o, keeping: record) else {
                state = .failed(c == 200 ? L("ntauth.err.exchange") : PacenoteServer.problem(d, status: c)); return
            }
            guard keep(r) else { state = .failed(L("keys.err.keychain")); return }
            needsReconnect = false
            let m = SettingsWindow.model
            let missing = !NotionBlueprint.toCreate(chosen: ["meetings": m.config.notionMeetingsDB, "tasks": m.config.notionTasks.database,
                                                             "decisions": m.config.notionDecisionsDB, "risks": m.config.notionRisksDB],
                                                    tracker: NotionWorkspaceSetup.trackerOn).isEmpty
            let shared = ((try? await NotionAPI.search(r.accessToken)) ?? []).filter { $0.kind == "data_source" }
            if missing && !shared.isEmpty {
                offerChoice = true; state = .idle
                note = L("ntauth.choice.note", ["n": "\(shared.count)", "ws": r.workspaceName])
                NotionDestinationModel.shared.find()
            } else {
                await setUp()
            }
        } catch { state = .failed(error.localizedDescription) }
    }

    @discardableResult
    private func keep(_ r: NotionOAuthRecord) -> Bool {
        guard Self.store.set(.notionOAuth, r.encoded()) else { return false }
        record = r
        let m = SettingsWindow.model
        m.keyState[.notionOAuth] = .ok(r.workspaceName)
        m.objectWillChange.send()
        return true
    }

    /// Makes (or finds) the "Pacenote" page and the databases still missing. Also from Settings ("Create them for me").
    func setUp() async {
        guard let r = record else { return }
        offerChoice = false
        state = .settingUp
        let m = SettingsWindow.model
        let out = await NotionWorkspaceSetup.run(record: r, model: m)
        if let root = out.root, root != r.rootPageID { var n = r; n.rootPageID = root; keep(n) }
        if let e = out.error { state = .failed(e) } else { state = .idle }
        note = out.note
        NotionDestinationModel.shared.find()
    }

    // MARK: disconnect

    /// Forgets the pair on this Mac. Pacenote's access in Notion itself is removed by the person (manageURL).
    func disconnect() {
        cancel()
        _ = Self.store.remove(.notionOAuth)
        record = nil; needsReconnect = false; offerChoice = false; state = .idle; note = ""
        let m = SettingsWindow.model
        m.keyState[.notionOAuth] = .notSet
        m.objectWillChange.send()
    }

    // MARK: refresh

    /// After a 401 from Notion on the OAuth token: one refresh at a time (Notion rotates the refresh token, so a
    /// second request with the old one would fail). The new access token, or nil (not OAuth, offline, or Reconnect).
    nonisolated func refreshAfter401(_ failed: String) async -> String? {
        let t = await MainActor.run { self.startRefresh(failed) }
        return await t?.value
    }

    private func startRefresh(_ failed: String) -> Task<String?, Never>? {
        if let t = refreshing { return t }
        guard let r = record, r.accessToken == failed, !needsReconnect else {
            // another call refreshed already: hand back the current token
            if let r = record, r.accessToken != failed { return Task<String?, Never> { r.accessToken } }
            return nil
        }
        let t = Task<String?, Never> { @MainActor in
            defer { self.refreshing = nil }
            do {
                let (d, c) = try await PacenoteAccount.shared.api("POST", NotionOAuthCore.refreshPath,
                                                                  body: NotionOAuthCore.refreshBody(refreshToken: r.refreshToken))
                if c == 200, let n = NotionOAuthRecord.from(pair: ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any]) ?? [:], keeping: r) {
                    self.keep(n)
                    return n.accessToken
                }
                if NotionOAuthCore.reconnectNeeded(d, status: c) {
                    self.needsReconnect = true
                    self.state = .failed(L("ntauth.reconnect"))
                    SettingsWindow.model.keyState[.notionOAuth] = .failed(L("ntauth.reconnect"))
                }
                return nil
            } catch { return nil }
        }
        refreshing = t
        return t
    }
}

/// After the consent: the "Pacenote" page at the top of the workspace and its databases (NotionBlueprint). A database
/// already chosen in Settings (for example one from Control Tower) is never replaced.
@MainActor
enum NotionWorkspaceSetup {
    struct Outcome { var root: String?; var made: [String] = []; var note = ""; var error: String? }

    static var trackerOn: Bool { UserDefaults.standard.object(forKey: "moduleTracker") as? Bool ?? true }

    static func run(record r: NotionOAuthRecord, model m: SettingsModel) async -> Outcome {
        let tok = r.accessToken
        var out = Outcome()
        let chosen = ["meetings": m.config.notionMeetingsDB, "tasks": m.config.notionTasks.database,
                      "decisions": m.config.notionDecisionsDB, "risks": m.config.notionRisksDB]
        let todo = NotionBlueprint.toCreate(chosen: chosen, tracker: trackerOn)
        do {
            let root = try await findOrMakeRoot(tok, known: r.rootPageID)
            out.root = root
            guard !todo.isEmpty else { out.note = L("ntauth.setup.kept", ["ws": r.workspaceName]); return out }
            let under = NotionBlueprint.childDatabases(try await NotionAPI.call(tok, "GET", "/blocks/\(root)/children?page_size=100"))
            for db in todo {
                let ds: String
                if let existing = under[db.title], let d = NotionBlueprint.dataSourceID(try await NotionAPI.call(tok, "GET", "/databases/\(existing)")) {
                    ds = d
                } else {
                    let made = try await NotionAPI.call(tok, "POST", "/databases", NotionBlueprint.databaseBody(db, parentPage: root))
                    guard let d = NotionBlueprint.dataSourceID(made) else { throw NSError(domain: "Notion", code: 0, userInfo: [NSLocalizedDescriptionKey: L("nset.noId")]) }
                    ds = d
                }
                apply(db.kind, ds, name: db.title, m)
                out.made.append(db.title)
            }
            out.note = L("ntauth.setup.made", ["dbs": out.made.joined(separator: ", "), "ws": r.workspaceName])
        } catch {
            out.error = "Notion: " + error.localizedDescription
            if !out.made.isEmpty { out.note = L("ntauth.setup.made", ["dbs": out.made.joined(separator: ", "), "ws": r.workspaceName]) }
        }
        return out
    }

    private static func findOrMakeRoot(_ tok: String, known: String?) async throws -> String {
        if let id = known, !id.isEmpty,
           let p = try? await NotionAPI.call(tok, "GET", "/pages/\(id)"),
           (p["in_trash"] as? Bool) != true, (p["archived"] as? Bool) != true { return id }
        let found = try await NotionAPI.call(tok, "POST", "/search", ["query": NotionBlueprint.rootTitle, "page_size": 20,
                                                                      "filter": ["property": "object", "value": "page"]])
        if let id = NotionBlueprint.rootInSearch(found) { return id }
        let made = try await NotionAPI.call(tok, "POST", "/pages", NotionBlueprint.rootPageBody())
        guard let id = made["id"] as? String else { throw NSError(domain: "Notion", code: 0, userInfo: [NSLocalizedDescriptionKey: L("nset.noId")]) }
        return id
    }

    /// The new database becomes the choice in Settings, with the property names the blueprint gave it.
    private static func apply(_ kind: String, _ ds: String, name: String, _ m: SettingsModel) {
        switch kind {
        case "meetings":
            m.config.notionMeetingsDB = ds; m.config.notionMeetingsName = name; m.config.notionMeetingsProp = "Project"
            m.config.notionWriteSummary = true
        case "tasks":
            m.config.notionTasks.database = ds; m.config.notionTasks.databaseName = name
            m.config.notionTasks.projectProperty = "Project"; m.config.notionTasks.projectType = "select"
            m.config.notionTasks.dueProperty = "Due"; m.config.notionTasks.sourceProperty = "Source"
            m.config.notionTasks.tickProperty = "Status"; m.config.notionTasks.tickType = "select"; m.config.notionTasks.tickValue = "Done"
        case "decisions":
            m.config.notionDecisionsDB = ds; m.config.notionDecisionsName = name; m.config.notionDecisionsProp = "Project"
        case "risks":
            m.config.notionRisksDB = ds; m.config.notionRisksName = name; m.config.notionRisksProp = "Project"
        default: break
        }
    }
}

// MARK: - Settings > Integrations > Notion > Connection

/// Connect with Notion (the main way), the connected workspace with Reconnect and Disconnect, the choice between
/// Pacenote's own databases and shared ones, and the pasted key as the advanced way.
struct NotionConnectSection: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var auth = NotionAuth.shared
    @ObservedObject var account = PacenoteAccount.shared
    @State private var manual = false

    var body: some View {
        if let r = auth.record {
            LabeledContent {
                HStack(spacing: 8) {
                    if auth.busy { PNSpinner(size: 16) }
                    status
                    Menu {
                        Button(L("ntauth.reconnect.button")) { auth.connect() }
                        Button(L("ntauth.createDbs")) { Task { await auth.setUp() } }
                        Button(L("ntauth.manage")) { if let u = URL(string: NotionOAuthCore.manageURL) { NSWorkspace.shared.open(u) } }
                        Divider()
                        Button(L("ntauth.disconnect"), role: .destructive) { auth.disconnect() }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel(L("home.more"))
                        .disabled(auth.busy)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("ntauth.workspace", ["ws": r.workspaceName.isEmpty ? "Notion" : r.workspaceName]))
                    Text(L("ntauth.connected.hint")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
            .settingsAnchor("int.notion.token")
            if auth.needsReconnect {
                HStack {
                    Text(L("ntauth.reconnect")).font(PN.Font.caption).foregroundStyle(PN.C.onMe).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(L("ntauth.reconnect.button")) { auth.connect() }.buttonStyle(.pnPrimary).disabled(auth.busy)
                }
            }
            if auth.offerChoice { choice }
            line
            NotionLocalCopyOfferCard(model: model)          // INT5: Turn on / Later / Not now
        } else {
            LabeledContent {
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 8) {
                        if auth.busy { PNSpinner(size: 16) }
                        if auth.state == .waiting { Button(L("common.cancel")) { auth.cancel() }.buttonStyle(.pnTertiary) }
                        Button(L("ntauth.connect")) { auth.connect() }.buttonStyle(.pnPrimary)
                            .disabled(auth.busy || !account.signedIn)
                    }
                    if auth.state == .waiting { Text(L("ntauth.waiting")).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("ntauth.title"))
                    Text(L(account.signedIn ? "ntauth.hint" : "ntauth.err.signIn")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .settingsAnchor("int.notion.token")
            line
            if model.isSet(.notionToken) || manual {
                KeyRow(title: L("keys.notion.title"), hint: L("keys.notion.hint"), key: .notionToken, model: model)
            } else {
                HStack {
                    Spacer()
                    Button(L("ntauth.manual")) { manual = true }.buttonStyle(.pnTertiary)
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        if auth.needsReconnect {
            Label(L("ntauth.reconnect.short"), systemImage: "exclamationmark.triangle.fill").font(PN.Font.caption).foregroundStyle(PN.C.danger)
        } else if auth.state == .settingUp {
            Text(L("ntauth.settingUp")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
        } else {
            Label(L("keys.connected"), systemImage: "checkmark.circle.fill").font(PN.Font.caption).foregroundStyle(PN.C.turn)
        }
    }

    @ViewBuilder private var line: some View {
        if case .failed(let e) = auth.state {
            Text(e).font(PN.Font.caption).foregroundStyle(PN.C.danger).fixedSize(horizontal: false, vertical: true)
        } else if !auth.note.isEmpty {
            Text(auth.note).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var choice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("ntauth.choice.title")).font(.callout.weight(.medium))
            Text(L("ntauth.choice.body")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L("ntauth.choice.create")) { Task { await auth.setUp() } }.buttonStyle(.pnPrimary).disabled(auth.busy)
                Button(L("ntauth.choice.pick")) {
                    auth.offerChoice = false
                    UserDefaults.standard.set("1", forKey: SettingsSearch.advancedKey("notion"))
                }.buttonStyle(.pnSecondary)
            }
        }
        .padding(.vertical, 4)
    }
}
