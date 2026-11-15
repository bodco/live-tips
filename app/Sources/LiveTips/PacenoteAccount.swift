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
        // presence first, the value off the main thread (0.8.7.1: a Keychain read can wait on macOS's prompt)
        if store.has(.pacenoteSession) {
            let st = store
            DispatchQueue.global(qos: .userInitiated).async {
                let s = PacenoteServer.Session.decode(st.get(.pacenoteSession))
                DispatchQueue.main.async { MainActor.assumeIsolated { PacenoteAccount.shared.loaded(s) } }
            }
        }
    }

    private func loaded(_ s: PacenoteServer.Session?) {
        guard session == nil, let s else { return }
        session = s
        Task { await refreshInfo() }
    }

    /// 0.11.0 (smoke shots, `--render-sheet-shots`): the demo account state for the offscreen screens.
    func shotState(session: PacenoteServer.Session?, me: PacenoteServer.Me?, devices: [PacenoteServer.Device] = []) {
        guard SheetShots.active else { return }
        self.session = session; self.me = me; self.devices = devices
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

    private func finishSignIn(code: String, verifier: String, client: GoogleClient) async {
        do {
            let o = try await GoogleService.shared.tokenCall(["grant_type": "authorization_code", "code": code, "code_verifier": verifier,
                                                              "redirect_uri": pendingRedirect, "client_id": client.clientID,
                                                              "client_secret": client.clientSecret])
            guard let idToken = o["id_token"] as? String else { throw PacenoteAccountError.server(0, "no ID token from Google") }
            // the Google access token of this exchange is not kept: Pacenote needs nothing from Google here
            let body = PacenoteServer.signInBody(idToken: idToken, deviceName: Self.deviceName, appVersion: Self.appVersion)
            let (d, code) = try await raw("POST", "/v1/auth/google", body: body, token: nil)
            guard code == 200, let t = PacenoteServer.tokens(json(d)) else { throw PacenoteAccountError.server(code, PacenoteServer.problem(d, status: code)) }
            let email = GoogleOAuth.email(idToken: idToken) ?? ""
            let s = PacenoteServer.Session(refreshToken: t.refresh, refreshExpires: t.refreshExpires, email: email, name: "")
            guard store.set(.pacenoteSession, s.encoded()) else { throw PacenoteAccountError.server(0, L("account.err.keychain")) }
            session = s
            access = (t.access, t.accessExpires)
            signIn = .idle; problem = nil
            await refreshInfo()
        } catch {
            signIn = .failed(error.localizedDescription)
        }
    }

    // MARK: account, devices

    func refreshInfo() async {
        if SheetShots.active { return }      // 0.11.0 (smoke shots): no network with the demo session
        guard signedIn else { return }
        busy = true; defer { busy = false }
        do {
            let (md, mc) = try await call("GET", "/v1/me")
            guard mc == 200, let m = PacenoteServer.me(json(md)) else { throw PacenoteAccountError.server(mc, PacenoteServer.problem(md, status: mc)) }
            me = m
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

    /// QA (`--account-test`): drops the access token so the next request refreshes.
    func expireAccessForTest() { access = nil }

    private func forget() {
        refreshing?.cancel(); refreshing = nil
        access = nil; session = nil; me = nil; devices = []; problem = nil
        _ = store.remove(.pacenoteSession)
    }

    // MARK: tokens and requests

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

    /// An authorized request; a 401 on a fresh-looking access token gets one refresh and one retry.
    private func call(_ method: String, _ path: String, body: Data? = nil, headers: [String: String] = [:]) async throws -> (Data, Int) {
        let r = try await raw(method, path, body: body, token: try await accessToken(), headers: headers)
        guard r.1 == 401 else { return r }
        access = nil
        return try await raw(method, path, body: body, token: try await accessToken(), headers: headers)
    }

    private func raw(_ method: String, _ path: String, body: Data?, token: String?, headers: [String: String] = [:]) async throws -> (Data, Int) {
        var r = URLRequest(url: base.appendingPathComponent(String(path.dropFirst())))
        r.httpMethod = method
        r.timeoutInterval = 30
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("Pacenote/\(Self.appVersion) (macOS)", forHTTPHeaderField: "User-Agent")
        if let token { r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        if let body { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        do {
            let (d, resp) = try await URLSession.shared.data(for: r)
            return (d, (resp as? HTTPURLResponse)?.statusCode ?? 0)
        } catch { throw PacenoteAccountError.network(error.localizedDescription) }
    }
}

private func json(_ d: Data) -> [String: Any] { ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any]) ?? [:] }
