import AppKit
import Foundation
import Network
import LiveTipsCore

// 0.9.1 (owner, 2026-11-04): Google in Pacenote (rules/google.yaml). Several Google accounts, like Notion workspaces.
// Sign-in: the system browser and a one-shot server on 127.0.0.1 (OAuth for installed apps, PKCE). The refresh tokens
// are in the Keychain; access tokens only in memory. Read only, except the export of notes to Google Docs.

/// The app's OAuth client: Resources/google_oauth.json in the bundle (bundle.sh writes it from the build machine's
/// environment), or the same file in the app's support folder for a development build.
enum GoogleClientConfig {
    static func load() -> GoogleClient? {
        let candidates = [Bundle.main.url(forResource: "google_oauth", withExtension: "json"),
                          AppPaths.support.appendingPathComponent("google_oauth.json")]
        for u in candidates.compactMap({ $0 }) { if let d = try? Data(contentsOf: u), let c = GoogleClient.parse(d) { return c } }
        return nil
    }
}

/// One request on 127.0.0.1: the browser comes back with ?code=..&state=..; the page says to close the tab.
final class LoopbackReceiver {
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private var done: ((String?) -> Void)?

    func start(_ ready: @escaping (UInt16?) -> Void, received: @escaping (String?) -> Void) {
        done = received
        let p = NWParameters.tcp
        p.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        guard let l = try? NWListener(using: p) else { ready(nil); return }
        listener = l
        l.stateUpdateHandler = { [weak self] st in
            switch st {
            case .ready: self?.port = l.port?.rawValue ?? 0; ready(l.port?.rawValue)
            case .failed: ready(nil)
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.handle(c) }
        l.start(queue: .main)
    }

    private func handle(_ c: NWConnection) {
        c.start(queue: .main)
        c.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            let req = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let first = req.split(separator: "\r\n").first ?? ""
            let target = first.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            if target.hasPrefix("/favicon") { c.cancel(); return }
            let ok = target.contains("code=")
            let html = """
            <!doctype html><meta charset="utf-8"><title>Pacenote</title>
            <body style="font:16px -apple-system,sans-serif;margin:15vh auto;max-width:460px;text-align:center;color:#1d1d1f">
            <h2>\(ok ? "Pacenote is connected to Google" : "Google did not connect")</h2>
            <p>\(ok ? "You can close this tab and go back to Pacenote." : "Go back to Pacenote and try again.")</p></body>
            """
            let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n" + html
            c.send(content: Data(resp.utf8), completion: .contentProcessed { _ in c.cancel() })
            self?.finish(target)
        }
    }

    private func finish(_ target: String?) {
        let d = done; done = nil
        listener?.cancel(); listener = nil
        d?(target)
    }

    func cancel() { finish(nil) }
}

struct GoogleCalendarInfo: Identifiable, Hashable {
    var id: String { account + "|" + calendarID }
    var account: String
    var calendarID: String
    var title: String
    var color: String
    var primary: Bool
}

enum GoogleError: LocalizedError {
    case noClient, noAccount, http(Int, String), noAccess(String)
    var errorDescription: String? {
        switch self {
        case .noClient: return L("google.err.noClient")
        case .noAccount: return L("google.err.noAccount")
        case .http(let c, let m): return "Google \(c): \(m)"
        case .noAccess(let what): return L("google.err.noAccess", ["what": what])
        }
    }
}

@MainActor
final class GoogleService: ObservableObject {
    static let shared = GoogleService()

    enum SignIn: Equatable { case idle, waiting, failed(String) }
    @Published private(set) var accounts: [GoogleAccount] = []
    @Published private(set) var signIn: SignIn = .idle
    @Published private(set) var calendars: [GoogleCalendarInfo] = []
    @Published private(set) var events: [CalendarService.CalEvent] = []
    @Published private(set) var lastError: [String: String] = [:]      // email -> the last problem, shown on its row
    /// Calendars the PM switched off (account|calendarID). The primary calendar of each account is on by default.
    @Published var off: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "gcalOff") ?? []) {
        didSet { UserDefaults.standard.set(Array(off), forKey: "gcalOff"); Task { await refreshEvents() } }
    }
    /// Calendars switched on that are not primary (the rest of the list stays off until ticked).
    @Published var on: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "gcalOn") ?? []) {
        didSet { UserDefaults.standard.set(Array(on), forKey: "gcalOn"); Task { await refreshEvents() } }
    }

    private var tokens: [String: (String, Date)] = [:]      // email -> access token, expiry (memory only)
    private var receiver: LoopbackReceiver?
    private var timer: Timer?
    var store: SecretStore { SecretStore(service: Bundle.main.bundleIdentifier ?? "io.github.example.livetips") }
    var configured: Bool { GoogleClientConfig.load() != nil }
    var connected: Bool { !accounts.isEmpty }

    private init() {
        // presence first (no Keychain prompt on the main thread); the list is read once the cache is warm
        // 0.8.7.1 lesson: a Keychain read on the main thread can wait on macOS's "allow access" prompt and freeze Home
        if store.has(.googleAccounts) {
            let st = store
            DispatchQueue.global(qos: .userInitiated).async {
                let list = GoogleAccount.decode(st.get(.googleAccounts))
                DispatchQueue.main.async { MainActor.assumeIsolated { GoogleService.shared.loaded(list) } }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { guard let s = self else { return }; Task { await s.refreshEvents() } }
        }
    }

    private func loaded(_ list: [GoogleAccount]) { accounts = list; Task { await refreshAll() } }

    func reload() { accounts = GoogleAccount.decode(store.get(.googleAccounts)); Task { await refreshAll() } }

    private func save() { _ = store.set(.googleAccounts, GoogleAccount.encode(accounts)) }

    // MARK: sign-in

    func addAccount(hint: String? = nil) {
        guard let client = GoogleClientConfig.load() else { signIn = .failed(L("google.err.noClient")); return }
        receiver?.cancel()
        let r = LoopbackReceiver(); receiver = r
        let state = GoogleOAuth.randomString(16), verifier = GoogleOAuth.randomString(48)
        signIn = .waiting
        r.start({ [weak self] port in
            guard let self else { return }
            guard let port else { self.signIn = .failed(L("google.err.loopback")); return }
            let redirect = "http://127.0.0.1:\(port)"
            let url = GoogleOAuth.authURL(client: client.clientID, redirect: redirect, scopes: GoogleScopes.all, state: state,
                                          challenge: GoogleOAuth.challenge(verifier), hint: hint)
            NSWorkspace.shared.open(url)
            self.pendingRedirect = redirect
        }, received: { [weak self] target in
            guard let self else { return }
            guard let target else { if self.signIn == .waiting { self.signIn = .idle }; return }
            switch GoogleOAuth.callback(target, state: state) {
            case .code(let code):
                Task { await self.exchange(code: code, verifier: verifier, redirect: self.pendingRedirect, client: client) }
            case .denied(let e): self.signIn = .failed(e == "access_denied" ? L("google.err.denied") : e)
            case .bad: self.signIn = .failed(L("google.err.state"))
            }
            NSApp.activate(ignoringOtherApps: true)
        })
    }

    private var pendingRedirect = ""

    func cancelSignIn() { receiver?.cancel(); signIn = .idle }

    private func exchange(code: String, verifier: String, redirect: String, client: GoogleClient) async {
        do {
            let o = try await tokenCall(["grant_type": "authorization_code", "code": code, "code_verifier": verifier,
                                         "redirect_uri": redirect, "client_id": client.clientID, "client_secret": client.clientSecret])
            guard let refresh = o["refresh_token"] as? String, let access = o["access_token"] as? String else { throw GoogleError.http(0, "no refresh token") }
            var email = (o["id_token"] as? String).flatMap(GoogleOAuth.email(idToken:))
            if email == nil, let u = try? await get("https://openidconnect.googleapis.com/v1/userinfo", token: access) { email = u["email"] as? String }
            guard let mail = email else { throw GoogleError.http(0, "no email") }
            let scopes = ((o["scope"] as? String) ?? "").split(separator: " ").map(String.init)
            accounts = GoogleAccount.upsert(accounts, GoogleAccount(email: mail, refreshToken: refresh, scopes: scopes))
            tokens[mail] = (access, Date().addingTimeInterval(Double((o["expires_in"] as? Int) ?? 3600) - 60))
            lastError[mail] = nil
            save()
            signIn = .idle
            UsageLog.log("google_connect")
            await refreshAll()
        } catch {
            signIn = .failed(error.localizedDescription)
        }
    }

    /// Forgets the account here and revokes its token at Google (the PM can also do it in his Google account).
    func remove(_ email: String) {
        guard let a = accounts.first(where: { $0.email == email }) else { return }
        accounts.removeAll { $0.email == email }
        tokens[email] = nil
        calendars.removeAll { $0.account == email }
        events.removeAll { $0.account == email }
        save()
        var r = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
        r.httpMethod = "POST"; r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = GoogleOAuth.form(["token": a.refreshToken])
        URLSession.shared.dataTask(with: r).resume()
        CalendarService.shared.refresh()
    }

    // MARK: tokens and calls

    private func tokenCall(_ form: [String: String]) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: GoogleOAuth.tokenEndpoint)!)
        r.httpMethod = "POST"; r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = GoogleOAuth.form(form)
        let (d, resp) = try await URLSession.shared.data(for: r)
        let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw GoogleError.http(code, (o["error_description"] as? String) ?? (o["error"] as? String) ?? "") }
        return o
    }

    func accessToken(_ email: String) async throws -> String {
        if let (t, exp) = tokens[email], exp > Date() { return t }
        guard let a = accounts.first(where: { $0.email == email }) else { throw GoogleError.noAccount }
        guard let client = GoogleClientConfig.load() else { throw GoogleError.noClient }
        do {
            let o = try await tokenCall(["grant_type": "refresh_token", "refresh_token": a.refreshToken,
                                         "client_id": client.clientID, "client_secret": client.clientSecret])
            guard let t = o["access_token"] as? String else { throw GoogleError.http(0, "no token") }
            tokens[email] = (t, Date().addingTimeInterval(Double((o["expires_in"] as? Int) ?? 3600) - 60))
            lastError[email] = nil
            return t
        } catch GoogleError.http(400, let m) {
            lastError[email] = L("google.err.signInAgain")      // invalid_grant: revoked or expired
            throw GoogleError.http(400, m)
        }
    }

    nonisolated func get(_ url: String, token: String) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: url)!)
        r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 30
        let (d, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
        guard code == 200 else { throw GoogleError.http(code, ((o["error"] as? [String: Any])?["message"] as? String) ?? "") }
        return o
    }

    private func call(_ email: String, _ url: String) async throws -> [String: Any] {
        try await get(url, token: try await accessToken(email))
    }

    private static func q(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#@"))) ?? s }

    // MARK: calendars

    func isOn(_ c: GoogleCalendarInfo) -> Bool { c.primary ? !off.contains(c.id) : on.contains(c.id) }
    func setOn(_ c: GoogleCalendarInfo, _ v: Bool) {
        if c.primary { if v { off.remove(c.id) } else { off.insert(c.id) } } else { if v { on.insert(c.id) } else { on.remove(c.id) } }
    }

    func refreshAll() async {
        await refreshCalendars()
        await refreshEvents()
    }

    func refreshCalendars() async {
        var all: [GoogleCalendarInfo] = []
        for a in accounts where a.has(GoogleScopes.calendar) {
            do {
                let o = try await call(a.email, "https://www.googleapis.com/calendar/v3/users/me/calendarList?minAccessRole=reader&maxResults=250")
                for c in (o["items"] as? [[String: Any]]) ?? [] {
                    guard let id = c["id"] as? String else { continue }
                    all.append(GoogleCalendarInfo(account: a.email, calendarID: id, title: (c["summaryOverride"] as? String) ?? (c["summary"] as? String) ?? id,
                                                  color: (c["backgroundColor"] as? String) ?? "#4285F4", primary: (c["primary"] as? Bool) == true))
                }
            } catch { lastError[a.email] = error.localizedDescription }
        }
        calendars = all.sorted { ($0.account, $0.primary ? 0 : 1, $0.title) < ($1.account, $1.primary ? 0 : 1, $1.title) }
    }

    /// From 3 h ago to 36 h ahead, the same window as EventKit. CalendarService merges and drops the doubles.
    func refreshEvents() async {
        let now = Date()
        events = await fetch(from: now.addingTimeInterval(-3 * 3600), to: now.addingTimeInterval(36 * 3600))
        CalendarService.shared.refresh()
    }

    func fetch(from: Date, to: Date) async -> [CalendarService.CalEvent] {
        let f = ISO8601DateFormatter()
        var out: [CalendarService.CalEvent] = []
        for c in calendars where isOn(c) {
            let url = "https://www.googleapis.com/calendar/v3/calendars/\(Self.q(c.calendarID))/events?singleEvents=true&orderBy=startTime&maxResults=250"
                + "&timeMin=\(Self.q(f.string(from: from)))&timeMax=\(Self.q(f.string(from: to)))"
            guard let o = try? await call(c.account, url) else { continue }
            for item in (o["items"] as? [[String: Any]]) ?? [] {
                guard let e = GoogleEvent.parse(item), !e.allDay, !e.cancelled, !e.declined else { continue }
                out.append(Self.calEvent(e, calendar: c))
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    static func calEvent(_ e: GoogleEvent, calendar c: GoogleCalendarInfo) -> CalendarService.CalEvent {
        let names = e.attendees.compactMap { a -> String? in
            if !a.name.isEmpty { return a.name }
            let local = a.email.components(separatedBy: "@").first ?? ""
            let parts = local.split(whereSeparator: { ".-_".contains($0) }).map { $0.prefix(1).uppercased() + $0.dropFirst() }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
        var ev = CalendarService.CalEvent(
            id: "g:" + e.id + "@" + String(Int(e.start.timeIntervalSince1970)),
            seriesKey: e.recurring ? "cal:" + e.uid : "title:" + StartCallModel.slugify(e.title),
            title: e.title.isEmpty ? L("cal.untitled") : e.title, start: e.start, end: e.end,
            calendar: c.title, account: c.account, color: NSColor(hex: c.color) ?? .systemBlue, attendees: names,
            link: e.link ?? CalendarService.meetingLink(in: [e.location, e.description].joined(separator: " ")),
            recurring: e.recurring, emails: e.attendees.map { $0.email }.filter { $0.contains("@") })
        ev.uid = e.uid
        ev.attachments = e.attachments.map { $0.url }
        ev.meetCode = e.meetCode
        return ev
    }

    // MARK: links in the call context

    /// Reads the Google links of a text through the connected accounts (the first one that can open each) and writes
    /// each as Markdown into `folder`. Returns the files and a line per link that could not be read.
    func readLinks(in text: String, extra: [String] = [], folder: String) async -> (files: [(GoogleLink, String)], problems: [String]) {
        let links = GoogleLink.find(in: ([text] + extra).joined(separator: "\n"))
        guard !links.isEmpty, !accounts.isEmpty else { return ([], []) }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        var files: [(GoogleLink, String)] = [], problems: [String] = []
        for l in links {
            var got: String?, last = ""
            for a in accounts where a.has(GoogleScopes.files) {
                do { got = try await read(l, account: a.email); break } catch { last = error.localizedDescription }
            }
            guard let body = got else { problems.append(l.url + ": " + (last.isEmpty ? L("google.err.noAccount") : last)); continue }
            let path = (folder as NSString).appendingPathComponent("google-\(l.kind.rawValue)-\(l.id.prefix(16)).md")
            let head = "<!-- Read from Google (\(l.url)) at \(ISO8601DateFormatter().string(from: Date())). Pacenote keeps this copy on this Mac. -->\n"
            if (try? (head + body).write(toFile: path, atomically: true, encoding: .utf8)) != nil { files.append((l, path)) }
        }
        return (files, problems)
    }

    func read(_ l: GoogleLink, account: String) async throws -> String {
        switch l.kind {
        case .doc:
            return GoogleText.doc(try await call(account, "https://docs.googleapis.com/v1/documents/\(l.id)?includeTabsContent=true"))
        case .slides:
            return GoogleText.slides(try await call(account, "https://slides.googleapis.com/v1/presentations/\(l.id)"))
        case .sheet:
            let meta = try await call(account, "https://sheets.googleapis.com/v4/spreadsheets/\(l.id)?fields=properties.title,sheets.properties.title")
            let titles = ((meta["sheets"] as? [[String: Any]]) ?? []).compactMap { ($0["properties"] as? [String: Any])?["title"] as? String }
            let ranges = titles.prefix(20).map { "ranges=" + Self.q("'" + $0.replacingOccurrences(of: "'", with: "''") + "'") }.joined(separator: "&")
            let v = try await call(account, "https://sheets.googleapis.com/v4/spreadsheets/\(l.id)/values:batchGet?" + ranges)
            return GoogleText.sheet(title: ((meta["properties"] as? [String: Any])?["title"] as? String) ?? "Google Sheet",
                                    ranges: (v["valueRanges"] as? [[String: Any]]) ?? [])
        case .file:
            throw GoogleError.noAccess(L("google.err.fileKind"))
        }
    }

    // MARK: export

    /// Uploads Word data as a new Google Doc in the account's Drive (My Drive root). Returns the doc's link.
    func exportDoc(_ docx: Data, title: String, account: String) async throws -> String {
        let token = try await accessToken(account)
        let boundary = "pacenote-" + GoogleOAuth.randomString(8)
        var r = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id,webViewLink")!)
        r.httpMethod = "POST"
        r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        r.setValue("multipart/related; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
        r.httpBody = DriveUpload.body(name: title, convertTo: "application/vnd.google-apps.document", media: docx,
                                      mediaType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document", boundary: boundary)
        let (d, resp) = try await URLSession.shared.data(for: r)
        let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let link = o["webViewLink"] as? String else {
            throw GoogleError.http(code, ((o["error"] as? [String: Any])?["message"] as? String) ?? "")
        }
        UsageLog.log("google_export")
        return link
    }

    // MARK: Meet

    struct MeetResult { var participants: [String]; var transcript: String; var account: String; var started: Date
        var spoken: [MeetSpeakers.Spoken] = []   // 0.9.4: who spoke when (Meet transcript entries), to name the voices
    }

    /// The Google Meet record of a call: by its meeting code when the calendar gave one, otherwise the conference that
    /// started closest to `start`. Participants always; the transcript only when someone turned it on in Meet.
    func meet(code: String?, start: Date, end: Date) async throws -> MeetResult? {
        let f = ISO8601DateFormatter()
        var lastErr: Error?
        for a in accounts where a.has(GoogleScopes.meet) {
            do {
                var filter = "start_time>=\"\(f.string(from: start.addingTimeInterval(-3600)))\" AND start_time<=\"\(f.string(from: end))\""
                if let c = code, !c.isEmpty { filter = "space.meeting_code=\"\(c)\" AND " + filter }
                let o = try await call(a.email, "https://meet.googleapis.com/v2/conferenceRecords?filter=" + Self.q(filter))
                let recs = (o["conferenceRecords"] as? [[String: Any]]) ?? []
                let g = ISO8601DateFormatter(); g.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                func t(_ r: [String: Any]) -> Date? { (r["startTime"] as? String).flatMap { g.date(from: $0) ?? f.date(from: $0) } }
                guard let rec = recs.min(by: { abs((t($0) ?? .distantPast).timeIntervalSince(start)) < abs((t($1) ?? .distantPast).timeIntervalSince(start)) }),
                      let name = rec["name"] as? String else { continue }
                let began = t(rec) ?? start
                let ps = try await call(a.email, "https://meet.googleapis.com/v2/\(name)/participants?pageSize=100")
                var names: [String: String] = [:]
                for p in (ps["participants"] as? [[String: Any]]) ?? [] { if let n = p["name"] as? String { names[n] = GoogleMeetText.name(p) } }
                var text = "", spoken: [MeetSpeakers.Spoken] = []
                let ts = try await call(a.email, "https://meet.googleapis.com/v2/\(name)/transcripts")
                if let tr = ((ts["transcripts"] as? [[String: Any]]) ?? []).first?["name"] as? String {
                    var entries: [[String: Any]] = [], page = ""
                    for _ in 0..<40 {
                        let e = try await call(a.email, "https://meet.googleapis.com/v2/\(tr)/entries?pageSize=100" + (page.isEmpty ? "" : "&pageToken=" + Self.q(page)))
                        entries += (e["transcriptEntries"] as? [[String: Any]]) ?? []
                        page = (e["nextPageToken"] as? String) ?? ""
                        if page.isEmpty { break }
                    }
                    text = GoogleMeetText.transcript(entries: entries, names: names, start: began)
                    spoken = MeetSpeakers.spoken(entries: entries, names: names)
                }
                return MeetResult(participants: Array(Set(names.values)).filter { $0 != "?" }.sorted(), transcript: text, account: a.email,
                                  started: began, spoken: spoken)
            } catch { lastErr = error }
        }
        if let e = lastErr { throw e }
        return nil
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
}
