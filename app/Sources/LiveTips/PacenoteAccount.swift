import AppKit
import Foundation
import LiveTipsCore

// B7 (server ADR 5.1, 2026-11-15): Settings > Account. Signing in to Pacenote with Google: the system browser, a
// one-shot server on 127.0.0.1 and PKCE, like the Google accounts, but with `openid email profile` only and no Google
// refresh token. Google's ID token goes to the Pacenote server once (POST /v1/auth/google); from then on the app uses
// the server's tokens. The refresh token (60 days, rotated on every use) is in the Keychain, the access token
// (15 minutes) only in memory. Optional: without signing in nothing changes. Calls go only for projects with
// "Sync to Pacenote server" on (0.12.0, B8b: CallSyncService).

enum PacenoteAccountError: LocalizedError {
    case noClient, notSignedIn, server(Int, String), network(String)
    var errorDescription: String? {
        switch self {
        case .noClient: return L("google.err.noClient")
        case .notSignedIn: return L("account.err.notSignedIn")
        case .server(let c, let m): return L("account.err.server", ["code": String(c), "msg": m])
        case .network(let m): return L("account.err.network", ["msg": m])
        }
    }
}

@MainActor
final class PacenoteAccount: ObservableObject {
    static let shared = PacenoteAccount()

    enum SignIn: Equatable { case idle, waiting, failed(String) }
    @Published private(set) var session: PacenoteServer.Session?
    @Published private(set) var signIn: SignIn = .idle
    @Published private(set) var me: PacenoteServer.Me?
    @Published private(set) var devices: [PacenoteServer.Device] = []
    @Published private(set) var busy = false
    /// The last problem with the server, shown under the account (cleared by the next good answer).
    @Published private(set) var problem: String?
    /// A one-line notice after signing out or deleting ("Signed out on the server too").
    @Published var notice: String?
    /// 0.17.0 (B6b): open invites to my email (Home and Settings > Account), and the organization projects I am on
    /// per organization (Settings > Projects > a project). Posted when the organizations change (joined, left).
    @Published private(set) var invites: [PacenoteServer.Invite] = []
    @Published private(set) var orgProjects: [String: [PacenoteServer.OrgProject]] = [:]
    @Published var inviteProblem: String?
    static let orgsChanged = Notification.Name("PacenoteOrgsChanged")

    var signedIn: Bool { session != nil }
    var base: URL { PacenoteServer.baseURL(override: UserDefaults.standard.string(forKey: "pacenoteServerURL")) }
    var store: SecretStore { SecretStore(service: Bundle.main.bundleIdentifier ?? "io.github.example.livetips") }

    private var access: (token: String, expires: Date)?
    /// One refresh at a time: the server rotates the refresh token, and a second request with the old one would make
    /// it revoke this Mac's session (reuse detection, ADR 21.2). Everyone waiting gets the same result.
    private var refreshing: Task<String, Error>?
    private var receiver: LoopbackReceiver?
    private var pendingRedirect = ""

    private init() {
        if SheetShots.active { return }     // 0.11.0 (smoke shots): demo state only, no Keychain, no network
        // presence and value off the main thread (0.8.7.1: a Keychain read can wait on macOS's prompt). Smoke
        // 16.11 (0.16.0): even the presence check waited there after a reinstall, while the "allow access" prompt
        // was open, and froze the whole app (no Home, no Quit); now nothing here touches the Keychain on main.
        let st = store
        DispatchQueue.global(qos: .userInitiated).async {
            guard st.has(.pacenoteSession) else { return }
            let s = PacenoteServer.Session.decode(st.get(.pacenoteSession))
            DispatchQueue.main.async { MainActor.assumeIsolated { PacenoteAccount.shared.loaded(s) } }
        }
    }

    private func loaded(_ s: PacenoteServer.Session?) {
        guard session == nil, let s else { return }
        session = s
        Task { await refreshInfo() }
        // smoke 16.11 (0.17.0): an invite made while the app runs showed only after a restart or a visit to Settings >
        // Account. Coming back to the app reads /v1/me again, at most every 10 minutes.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let a = PacenoteAccount.shared
                guard a.signedIn, !a.busy, Date().timeIntervalSince(a.lastInfo) > 600 else { return }
                Task { await a.refreshInfo() }
            }
        }
    }
    private var lastInfo = Date.distantPast

    /// 0.11.0 (smoke shots, `--render-sheet-shots`): the demo account state for the offscreen screens.
    func shotState(session: PacenoteServer.Session?, me: PacenoteServer.Me?, devices: [PacenoteServer.Device] = [],
                   invites: [PacenoteServer.Invite] = [], orgProjects: [String: [PacenoteServer.OrgProject]] = [:]) {
        guard SheetShots.active else { return }
        self.session = session; self.me = me; self.devices = devices; self.invites = invites; self.orgProjects = orgProjects
    }

    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }
    static var deviceName: String { Host.current().localizedName ?? "Mac" }

    // MARK: sign-in

    func startSignIn() {
        guard let client = GoogleClientConfig.load() else { signIn = .failed(L("google.err.noClient")); return }
        receiver?.cancel()
        let r = LoopbackReceiver(); receiver = r
        r.okTitle = "You are signed in to Pacenote"
        let state = GoogleOAuth.randomString(16), verifier = GoogleOAuth.randomString(48)
        signIn = .waiting; notice = nil
        r.start({ [weak self] port in
            guard let self else { return }
            guard let port else { self.signIn = .failed(L("google.err.loopback")); return }
            let redirect = "http://127.0.0.1:\(port)"
            self.pendingRedirect = redirect
            NSWorkspace.shared.open(GoogleOAuth.authURL(client: client.clientID, redirect: redirect, scopes: GoogleScopes.signIn,
                                                        state: state, challenge: GoogleOAuth.challenge(verifier), offline: false))
        }, received: { [weak self] target in
            guard let self else { return }
            guard let target else { if self.signIn == .waiting { self.signIn = .idle }; return }
            switch GoogleOAuth.callback(target, state: state) {
            case .code(let code):
                Task { await self.finishSignIn(code: code, verifier: verifier, client: client) }
            case .denied(let e): self.signIn = .failed(e == "access_denied" ? L("google.err.denied") : e)
            case .bad: self.signIn = .failed(L("google.err.state"))
            }
            NSApp?.activate(ignoringOtherApps: true)      // no NSApp in a command-line QA run (--account-test)
        })
    }

    func cancelSignIn() { receiver?.cancel(); signIn = .idle }

    // MARK: 0.19.0 (server 0.11.0, Bohdan 17.11): Google again for this Mac, for the Platform zone in the Console tab

    /// True while the Google confirm runs (the Console tab shows it over the page).
    @Published private(set) var confirmingGoogle = false
    private var confirmReceiver: LoopbackReceiver?

    /// The same Google sign-in as the first one (the system browser, a one-shot server on 127.0.0.1, PKCE, the
    /// signed-in account preselected), but the ID token goes to POST /v1/auth/google/confirm: the server stamps this Mac
    /// as having proved Google now; the session, its tokens and everything else stay. nil when done, else the reason.
    func confirmGoogle() async -> String? {
        guard signedIn else { return L("account.err.notSignedIn") }
        guard let client = GoogleClientConfig.load() else { return L("google.err.noClient") }
        confirmReceiver?.cancel()
        confirmingGoogle = true; defer { confirmingGoogle = false; confirmReceiver = nil }
        let state = GoogleOAuth.randomString(16), verifier = GoogleOAuth.randomString(48)
        let hint = session?.email.isEmpty == false ? session?.email : nil
        let got: (code: String, redirect: String)? = await withCheckedContinuation { (k: CheckedContinuation<(code: String, redirect: String)?, Never>) in
            let r = LoopbackReceiver(); confirmReceiver = r
            r.okTitle = "Pacenote: Google confirmed, back to the app"
            var redirect = "", resumed = false
            let finish: ((code: String, redirect: String)?) -> Void = { v in if !resumed { resumed = true; k.resume(returning: v) } }
            r.start({ port in
                guard let port else { finish(nil); return }
                redirect = "http://127.0.0.1:\(port)"
                NSWorkspace.shared.open(GoogleOAuth.authURL(client: client.clientID, redirect: redirect, scopes: GoogleScopes.signIn,
                                                            state: state, challenge: GoogleOAuth.challenge(verifier), hint: hint, offline: false))
            }, received: { target in
                NSApp?.activate(ignoringOtherApps: true)
                guard let target, case .code(let code) = GoogleOAuth.callback(target, state: state) else { finish(nil); return }
                finish((code, redirect))
            })
        }
        guard let got else { return L("console.platform.cancelled") }
        do {
            let o = try await GoogleService.shared.tokenCall(["grant_type": "authorization_code", "code": got.code, "code_verifier": verifier,
                                                              "redirect_uri": got.redirect, "client_id": client.clientID,
                                                              "client_secret": client.clientSecret])
            guard let idToken = o["id_token"] as? String else { return L("console.platform.noToken") }
            let (d, c) = try await call("POST", "/v1/auth/google/confirm", body: PacenoteServer.googleConfirmBody(idToken: idToken))
            switch c {
            case 204, 200: return nil
            case 403: return L("console.platform.otherAccount")
            default: return PacenoteServer.problem(d, status: c)
            }
        } catch { return error.localizedDescription }
    }

    func cancelConfirmGoogle() { confirmReceiver?.cancel() }

    private func finishSignIn(code: String, verifier: String, client: GoogleClient) async {
        do {
            let o = try await GoogleService.shared.tokenCall(["grant_type": "authorization_code", "code": code, "code_verifier": verifier,
                                                              "redirect_uri": pendingRedirect, "client_id": client.clientID,
                                                              "client_secret": client.clientSecret])
            guard let idToken = o["id_token"] as? String else { throw PacenoteAccountError.server(0, "no ID token from Google") }
            // the Google access token of this exchange is not kept: Pacenote needs nothing from Google here
            let body = PacenoteServer.signInBody(idToken: idToken, deviceName: Self.deviceName, appVersion: Self.appVersion,
                                                 machine: AnalyticsTracker.machineID)
            let (d, code) = try await raw("POST", "/v1/auth/google", body: body, token: nil)
            guard code == 200, let t = PacenoteServer.tokens(json(d)) else { throw PacenoteAccountError.server(code, PacenoteServer.problem(d, status: code)) }
            let email = GoogleOAuth.email(idToken: idToken) ?? ""
            let s = PacenoteServer.Session(refreshToken: t.refresh, refreshExpires: t.refreshExpires, email: email, name: "")
            guard store.set(.pacenoteSession, s.encoded()) else { throw PacenoteAccountError.server(0, L("account.err.keychain")) }
            session = s
            access = (t.access, t.accessExpires)
            noteIdentity(t.access)
            signIn = .idle; problem = nil
            await refreshInfo()
            AnalyticsTracker.shared.track("sign_in", ["method": "google"])      // 0.19.0 (S4)
            Task { await AnalyticsTracker.shared.flush(why: "sign_in", force: true) }
        } catch {
            signIn = .failed(error.localizedDescription)
        }
    }

    // MARK: account, devices

    func refreshInfo() async {
        if SheetShots.active { return }      // 0.11.0 (smoke shots): no network with the demo session
        guard signedIn else { return }
        busy = true; defer { busy = false }
        lastInfo = Date()
        do {
            let (md, mc) = try await call("GET", "/v1/me")
            guard mc == 200, let m = PacenoteServer.me(json(md)) else { throw PacenoteAccountError.server(mc, PacenoteServer.problem(md, status: mc)) }
            let before = me.map { Set($0.orgs.map(\.id)) }
            me = m
            EntitlementsStore.shared.meLoaded(m)        // 0.18.0 (B3): a changed entitlements_etag asks again
            if let b = before, b != Set(m.orgs.map(\.id)) { NotificationCenter.default.post(name: Self.orgsChanged, object: nil) }
            if m.pendingInvites > 0 { await loadInvites() } else { invites = [] }
            if var s = session, s.name != m.name || (s.email != m.email && !m.email.isEmpty) {
                s.name = m.name; s.email = m.email; session = s; _ = store.set(.pacenoteSession, s.encoded())
            }
            let (dd, dc) = try await call("GET", "/v1/devices")
            guard dc == 200 else { throw PacenoteAccountError.server(dc, PacenoteServer.problem(dd, status: dc)) }
            devices = PacenoteServer.devices(((try? JSONSerialization.jsonObject(with: dd)) as? [[String: Any]]) ?? [])
            problem = nil
        } catch PacenoteAccountError.notSignedIn {
            // the session ended on the server (forgotten in accessToken)
        } catch { problem = error.localizedDescription }
    }

    /// Signs this Mac out (or every device). Forgets the session here even if the server cannot be reached.
    func signOut(everywhere: Bool) async {
        busy = true; defer { busy = false }
        AnalyticsTracker.shared.track("sign_out")      // 0.19.0 (S4)
        await AnalyticsTracker.shared.signingOut()       // review 17.11: this account's events go now or never
        var reached = false
        if signedIn {
            let body = try? JSONSerialization.data(withJSONObject: ["everywhere": everywhere])
            if let r = try? await call("POST", "/v1/auth/logout", body: body) { reached = r.1 == 204 }
        }
        forget()
        notice = L(reached ? (everywhere ? "account.notice.outEverywhere" : "account.notice.out") : "account.notice.outLocal")
    }

    /// Signs one device out; this Mac too, then the session here ends.
    func revoke(_ d: PacenoteServer.Device) async {
        busy = true; defer { busy = false }
        do {
            let (b, c) = try await call("DELETE", "/v1/devices/\(d.id)")
            guard c == 204 || c == 404 else { throw PacenoteAccountError.server(c, PacenoteServer.problem(b, status: c)) }
            if d.current { forget(); notice = L("account.notice.out"); return }
            devices.removeAll { $0.id == d.id }
            problem = nil
        } catch { problem = error.localizedDescription }
    }

    /// DELETE /v1/me: the server destroys this person's content key at once and purges the rows within 30 days.
    /// The Mac and Google Drive are not touched. Returns whether the server accepted it.
    @discardableResult
    func deleteServerData() async -> Bool {
        busy = true; defer { busy = false }
        do {
            let (b, c) = try await call("DELETE", "/v1/me", headers: ["Idempotency-Key": UUID().uuidString])
            guard c == 202 else { throw PacenoteAccountError.server(c, PacenoteServer.problem(b, status: c)) }
            forget()
            notice = L("account.notice.deleted")
            return true
        } catch { problem = error.localizedDescription; return false }
    }

    /// 0.12.1 (B8): GET /v1/export, the zip of everything of mine on the server (export.json and one .md per call).
    func exportData() async throws -> Data {
        let (b, c) = try await call("GET", "/v1/export")
        guard c == 200 else { throw PacenoteAccountError.server(c, PacenoteServer.problem(b, status: c)) }
        return b
    }

    // MARK: 0.17.0 (B6b): organizations

    private var meLoad: Task<Void, Never>?
    /// The account's organizations, loaded once when not known yet (the call sync needs them to pick a call's
    /// organization right after launch).
    func meNow() async -> PacenoteServer.Me? {
        if let m = me { return m }
        guard signedIn else { return nil }
        if let t = meLoad { await t.value; return me }
        let t = Task { @MainActor in await self.refreshInfo() }
        meLoad = t
        await t.value
        meLoad = nil
        return me
    }

    /// GET /v1/invites: the open invites to my confirmed email.
    func loadInvites() async {
        guard signedIn else { return }
        do {
            let (d, c) = try await call("GET", "/v1/invites")
            guard c == 200 else { return }
            invites = PacenoteServer.invites(((try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]]) ?? [])
        } catch {}
    }

    /// Accepts an invite; by default the organization also becomes where new calls go. Returns the message to show,
    /// nil when joined.
    @discardableResult
    func accept(_ i: PacenoteServer.Invite, makeDefault: Bool) async -> String? {
        busy = true; defer { busy = false }
        do {
            let (_, c) = try await call("POST", "/v1/invites/\(i.id)/accept", body: PacenoteServer.acceptBody(makeDefault: makeDefault))
            if let key = PacenoteServer.acceptProblem(status: c) {
                if c == 404 || c == 410 { invites.removeAll { $0.id == i.id } }
                inviteProblem = L(key, ["org": i.orgName, "code": String(c)])
                return inviteProblem
            }
            invites.removeAll { $0.id == i.id }
            inviteProblem = nil
            notice = L("org.invite.joined", ["org": i.orgName])
            await refreshInfo()
            NotificationCenter.default.post(name: Self.orgsChanged, object: nil)
            return nil
        } catch { inviteProblem = error.localizedDescription; return inviteProblem }
    }

    func decline(_ i: PacenoteServer.Invite) async {
        busy = true; defer { busy = false }
        do {
            let (_, c) = try await call("POST", "/v1/invites/\(i.id)/decline")
            if [204, 200, 404, 410].contains(c) { invites.removeAll { $0.id == i.id }; inviteProblem = nil }
            else { inviteProblem = L("org.invite.err.other", ["code": String(c)]) }
        } catch { inviteProblem = error.localizedDescription }
    }

    /// PATCH /v1/me: where new calls go from now on (calls already made stay where they are).
    func setDefaultOrg(_ orgID: String) async {
        guard let m = me, m.org(orgID) != nil else { return }
        busy = true; defer { busy = false }
        do {
            let (d, c) = try await call("PATCH", "/v1/me", body: PacenoteServer.defaultOrgBody(orgID, me: m))
            guard c == 200 || c == 204 else { throw PacenoteAccountError.server(c, PacenoteServer.problem(d, status: c)) }
            me?.defaultOrgID = orgID
            problem = nil
        } catch { problem = error.localizedDescription }
    }

    /// GET /v1/orgs/{id}/projects: the organization projects I am on (only where flags.org_projects).
    func loadOrgProjects(_ orgID: String) async {
        guard signedIn, me?.org(orgID)?.orgProjects == true else { return }
        do {
            let (d, c) = try await call("GET", "/v1/orgs/\(orgID)/projects")
            guard c == 200 else { return }
            orgProjects[orgID] = PacenoteServer.orgProjects(((try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]]) ?? [],
                                                            me: me?.userID ?? "")
        } catch {}
    }

    /// QA (`--account-test`): drops the access token so the next request refreshes.
    func expireAccessForTest() { access = nil }

    private func forget() {
        refreshing?.cancel(); refreshing = nil
        access = nil; session = nil; me = nil; devices = []; problem = nil; invites = []; orgProjects = [:]
        _ = store.remove(.pacenoteSession)
        EntitlementsStore.shared.signedOut()
    }

    // MARK: tokens and requests

    /// 0.18.0 (B3): who and which Mac this session is (from the access token), kept with the session so a cached
    /// entitlements record can be checked offline. Written only when it changes.
    private func noteIdentity(_ token: String) {
        guard var s = session, let id = PacenoteServer.accessIdentity(token), s.userID != id.user || s.deviceID != id.device else { return }
        s.userID = id.user; s.deviceID = id.device
        _ = store.set(.pacenoteSession, s.encoded())
        session = s
        EntitlementsStore.shared.reload()
    }

    func accessToken() async throws -> String {
        if let a = access, a.expires > Date() { return a.token }
        if let r = refreshing { return try await r.value }
        guard let s = session else { throw PacenoteAccountError.notSignedIn }
        let task = Task<String, Error> { @MainActor in
            defer { self.refreshing = nil }
            let body = try JSONSerialization.data(withJSONObject: ["refresh_token": s.refreshToken])
            let (d, c) = try await self.raw("POST", "/v1/auth/refresh", body: body, token: nil)
            if c == 200, let t = PacenoteServer.tokens(json(d)) {
                // the old refresh token is dead from now on: keep the new one before anything else
                var n = s; n.refreshToken = t.refresh; n.refreshExpires = t.refreshExpires
                _ = self.store.set(.pacenoteSession, n.encoded())
                if self.session != nil { self.session = n }
                self.access = (t.access, t.accessExpires)
                self.noteIdentity(t.access)
                return t.access
            }
            if PacenoteServer.refreshEndsSession(status: c) {
                self.forget()
                self.notice = L("account.notice.ended")
                throw PacenoteAccountError.notSignedIn
            }
            throw PacenoteAccountError.server(c, PacenoteServer.problem(d, status: c))
        }
        refreshing = task
        return try await task.value
    }

    /// 0.12.0 (B8b): an authorized JSON request for the call sync (CallSyncService).
    func api(_ method: String, _ path: String, body: Data? = nil) async throws -> (Data, Int) {
        try await call(method, path, body: body)
    }

    /// 0.17.0 (contract 9): with headers (`If-Match` on the organization project card).
    func api(_ method: String, _ path: String, body: Data? = nil, headers: [String: String]) async throws -> (Data, Int) {
        try await call(method, path, body: body, headers: headers)
    }

    /// 0.18.0 (B3): with the answer's headers (`ETag` of /v1/entitlements and /v1/catalog).
    func apiWithHeaders(_ method: String, _ path: String, headers: [String: String] = [:]) async throws -> (Data, Int, [String: String]) {
        var r = try await rawFull(method, path, body: nil, token: try await accessToken(), headers: headers)
        if r.1 == 401 { access = nil; r = try await rawFull(method, path, body: nil, token: try await accessToken(), headers: headers) }
        return r
    }

    /// An authorized request; a 401 on a fresh-looking access token gets one refresh and one retry.
    private func call(_ method: String, _ path: String, body: Data? = nil, headers: [String: String] = [:]) async throws -> (Data, Int) {
        let r = try await raw(method, path, body: body, token: try await accessToken(), headers: headers)
        guard r.1 == 401 else { return r }
        access = nil
        return try await raw(method, path, body: body, token: try await accessToken(), headers: headers)
    }

    private func raw(_ method: String, _ path: String, body: Data?, token: String?, headers: [String: String] = [:]) async throws -> (Data, Int) {
        let r = try await rawFull(method, path, body: body, token: token, headers: headers)
        return (r.0, r.1)
    }

    private func rawFull(_ method: String, _ path: String, body: Data?, token: String?, headers: [String: String] = [:]) async throws -> (Data, Int, [String: String]) {
        // 0.17.0: a query ("?org_id=") stays a query, not a part of the path
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        var url = base.appendingPathComponent(String(parts[0].dropFirst()))
        if parts.count == 2, var comp = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comp.percentEncodedQuery = parts[1]; url = comp.url ?? url
        }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = 30
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("Pacenote/\(Self.appVersion) (macOS)", forHTTPHeaderField: "User-Agent")
        if let token { r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        // 0.18.0 (B3, contract 4): plan answers as 403 `type: plan`, quotas as 402 `type: quota`
        r.setValue(Entitlements.problemsHeader.value, forHTTPHeaderField: Entitlements.problemsHeader.name)
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        if let body { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        do {
            let (d, resp) = try await URLSession.shared.data(for: r)
            let h = resp as? HTTPURLResponse, code = h?.statusCode ?? 0
            // contract 2: any plan or quota answer means the rights changed; ask for them again
            if PacenoteServer.refreshesEntitlements(d, status: code), !path.hasPrefix(Entitlements.entitlementsPath) {
                EntitlementsStore.shared.planAnswer()
            }
            var hs: [String: String] = [:]
            for (k, v) in h?.allHeaderFields ?? [:] { if let k = k as? String, let v = v as? String { hs[k.lowercased()] = v } }
            return (d, code, hs)
        } catch { throw PacenoteAccountError.network(error.localizedDescription) }
    }
}

private func json(_ d: Data) -> [String: Any] { ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any]) ?? [:] }
