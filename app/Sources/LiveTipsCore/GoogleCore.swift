import CryptoKit
import Foundation

// 0.9.1 (owner, 2026-11-04): Google accounts in Pacenote. Several accounts like Notion workspaces; each one gives its
// calendars, the Google Docs, Sheets and Slides links of the call context, the export of notes to Google Docs and the
// Google Meet participants and transcript after the call. Pure helpers here (CoreChecks); the network is in the app.
// rules/google.yaml is the rule; nothing is written to Google without a click (the export only).

public enum GoogleScopes {
    public static let identity = ["openid", "https://www.googleapis.com/auth/userinfo.email"]
    public static let calendar = ["https://www.googleapis.com/auth/calendar.calendarlist.readonly",
                                  "https://www.googleapis.com/auth/calendar.events.readonly"]
    public static let files = ["https://www.googleapis.com/auth/documents.readonly",
                               "https://www.googleapis.com/auth/spreadsheets.readonly",
                               "https://www.googleapis.com/auth/presentations.readonly"]
    public static let export = ["https://www.googleapis.com/auth/drive.file"]
    public static let meet = ["https://www.googleapis.com/auth/meetings.space.readonly"]
    /// Everything at once: one consent screen per account. The PM can untick a scope there; the app then says
    /// what does not work for that account instead of failing.
    public static var all: [String] { identity + calendar + files + export + meet }
}

/// The OAuth client of the app (a Desktop client: Google does not treat its secret as confidential).
public struct GoogleClient: Codable, Equatable {
    public var clientID: String
    public var clientSecret: String
    public init(clientID: String, clientSecret: String) { self.clientID = clientID; self.clientSecret = clientSecret }

    /// Reads {"client_id","client_secret"} or Google's own download ({"installed": {...}}).
    public static func parse(_ data: Data) -> GoogleClient? {
        guard var o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let i = o["installed"] as? [String: Any] { o = i }
        guard let id = o["client_id"] as? String, !id.isEmpty, let s = o["client_secret"] as? String else { return nil }
        return GoogleClient(clientID: id, clientSecret: s)
    }
}

/// One connected account. The refresh token lives in the Keychain (SecretStore.Key.googleAccounts), never in a file.
public struct GoogleAccount: Codable, Equatable, Identifiable {
    public var id: String { email }
    public var email: String
    public var refreshToken: String
    public var scopes: [String]
    public var added: Date
    public init(email: String, refreshToken: String, scopes: [String], added: Date = Date()) {
        self.email = email; self.refreshToken = refreshToken; self.scopes = scopes; self.added = added
    }
    public func has(_ s: [String]) -> Bool { s.allSatisfy { scopes.contains($0) } }

    public static func encode(_ a: [GoogleAccount]) -> String {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]
        return (try? e.encode(a)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
    public static func decode(_ s: String?) -> [GoogleAccount] {
        guard let d = s?.data(using: .utf8) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([GoogleAccount].self, from: d)) ?? []
    }
    /// Adds or replaces by email (signing in again with the same account updates its token and scopes).
    public static func upsert(_ list: [GoogleAccount], _ a: GoogleAccount) -> [GoogleAccount] {
        var out = list.filter { $0.email.lowercased() != a.email.lowercased() }
        if let i = list.firstIndex(where: { $0.email.lowercased() == a.email.lowercased() }) { out.insert(a, at: min(i, out.count)) } else { out.append(a) }
        return out
    }
}

public enum GoogleOAuth {
    public static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    public static let tokenEndpoint = "https://oauth2.googleapis.com/token"

    public static func randomString(_ bytes: Int = 32) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        for i in b.indices { b[i] = UInt8.random(in: 0...255) }
        return base64url(Data(b))
    }
    public static func base64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    /// RFC 7636, S256.
    public static func challenge(_ verifier: String) -> String { base64url(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    public static func authURL(client: String, redirect: String, scopes: [String], state: String, challenge: String, hint: String? = nil) -> URL {
        var c = URLComponents(string: authEndpoint)!
        var q: [URLQueryItem] = [
            .init(name: "client_id", value: client), .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "state", value: state), .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"), .init(name: "access_type", value: "offline"),
            // consent: Google gives a refresh token again when the same account is added a second time;
            // select_account: the chooser shows every signed-in account, so another one is one click away
            .init(name: "prompt", value: "consent select_account"), .init(name: "include_granted_scopes", value: "true"),
        ]
        if let h = hint, !h.isEmpty { q.append(.init(name: "login_hint", value: h)) }
        c.queryItems = q
        return c.url!
    }

    public enum Callback: Equatable { case code(String), denied(String), bad }
    /// The query of the loopback request ("/?state=..&code=.."); the state must match.
    public static func callback(_ target: String, state: String) -> Callback {
        guard let c = URLComponents(string: "http://127.0.0.1" + (target.hasPrefix("/") ? target : "/" + target)) else { return .bad }
        let items = Dictionary((c.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard items["state"] == state else { return .bad }
        if let e = items["error"] { return .denied(e) }
        if let code = items["code"], !code.isEmpty { return .code(code) }
        return .bad
    }

    public static func form(_ f: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        return Data(f.sorted { $0.key < $1.key }.map { $0.key + "=" + ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }.joined(separator: "&").utf8)
    }

    /// The email from an id_token (its payload only; Google already checked it over TLS).
    public static func email(idToken: String) -> String? {
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var s = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let d = Data(base64Encoded: s), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        return o["email"] as? String
    }
}

// MARK: - Links in the call context

public struct GoogleLink: Equatable, Hashable {
    public enum Kind: String { case doc, sheet, slides, file }
    public var kind: Kind
    public var id: String
    public var url: String
    public init(kind: Kind, id: String, url: String) { self.kind = kind; self.id = id; self.url = url }

    /// docs.google.com/document|spreadsheets|presentation/d/<id>, drive.google.com/file/d/<id> and open?id=<id>.
    public static func find(in text: String) -> [GoogleLink] {
        let pat = "https://(docs|drive)\\.google\\.com/[^\\s<>\"')\\]]+"
        guard let re = try? NSRegularExpression(pattern: pat) else { return [] }
        var out: [GoogleLink] = []
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range, in: text) else { continue }
            let u = String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
            if let l = parse(u), !out.contains(where: { $0.id == l.id }) { out.append(l) }
        }
        return out
    }

    public static func parse(_ u: String) -> GoogleLink? {
        func id(after marker: String) -> String? {
            guard let r = u.range(of: marker) else { return nil }
            let rest = u[r.upperBound...]
            let v = rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            return v.count >= 10 ? String(v) : nil
        }
        if let i = id(after: "/document/d/") { return GoogleLink(kind: .doc, id: i, url: u) }
        if let i = id(after: "/spreadsheets/d/") { return GoogleLink(kind: .sheet, id: i, url: u) }
        if let i = id(after: "/presentation/d/") { return GoogleLink(kind: .slides, id: i, url: u) }
        if let i = id(after: "/file/d/") ?? id(after: "open?id=") { return GoogleLink(kind: .file, id: i, url: u) }
        return nil
    }
}

/// Google's JSON into plain text for the preparation. The text stays on this Mac (the project's live/google folder).
public enum GoogleText {
    /// documents.get (with includeTabsContent): headings as "#", list items as "- ", tables as "a | b" rows.
    public static func doc(_ o: [String: Any]) -> String {
        var out = "# " + ((o["title"] as? String) ?? "Google Doc") + "\n"
        var bodies: [(String?, [String: Any])] = []
        func tabs(_ t: [[String: Any]]) {
            for tab in t {
                let title = (tab["tabProperties"] as? [String: Any])?["title"] as? String
                if let b = (tab["documentTab"] as? [String: Any])?["body"] as? [String: Any] { bodies.append((title, b)) }
                if let kids = tab["childTabs"] as? [[String: Any]] { tabs(kids) }
            }
        }
        if let t = o["tabs"] as? [[String: Any]], !t.isEmpty { tabs(t) } else if let b = o["body"] as? [String: Any] { bodies.append((nil, b)) }
        for (title, b) in bodies {
            if bodies.count > 1, let t = title { out += "\n# " + t + "\n" }
            out += content((b["content"] as? [[String: Any]]) ?? [])
        }
        return out
    }

    static func content(_ items: [[String: Any]]) -> String {
        var out = ""
        for el in items {
            if let p = el["paragraph"] as? [String: Any] {
                let text = ((p["elements"] as? [[String: Any]]) ?? []).compactMap { ($0["textRun"] as? [String: Any])?["content"] as? String
                    ?? (($0["person"] as? [String: Any])?["personProperties"] as? [String: Any])?["name"] as? String
                    ?? (($0["richLink"] as? [String: Any])?["richLinkProperties"] as? [String: Any])?["title"] as? String }.joined()
                let line = text.trimmingCharacters(in: .newlines)
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                let style = (p["paragraphStyle"] as? [String: Any])?["namedStyleType"] as? String ?? ""
                if style == "TITLE" { out += "\n# " + line + "\n" }
                else if style.hasPrefix("HEADING_"), let n = Int(style.dropFirst(8)) { out += "\n" + String(repeating: "#", count: min(6, n + 1)) + " " + line + "\n" }
                else if p["bullet"] != nil {
                    let level = ((p["bullet"] as? [String: Any])?["nestingLevel"] as? Int) ?? 0
                    out += String(repeating: "  ", count: level) + "- " + line + "\n"
                } else { out += line + "\n" }
            } else if let t = el["table"] as? [String: Any] {
                out += "\n"
                for row in (t["tableRows"] as? [[String: Any]]) ?? [] {
                    let cells = ((row["tableCells"] as? [[String: Any]]) ?? []).map {
                        content(($0["content"] as? [[String: Any]]) ?? []).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                    }
                    out += "| " + cells.joined(separator: " | ") + " |\n"
                }
                out += "\n"
            } else if let toc = el["tableOfContents"] as? [String: Any] {
                _ = toc     // the headings follow anyway
            }
        }
        return out
    }

    /// presentations.get: the text of each slide and its speaker notes.
    public static func slides(_ o: [String: Any]) -> String {
        var out = "# " + ((o["title"] as? String) ?? "Google Slides") + "\n"
        func texts(_ els: [[String: Any]]) -> [String] {
            var t: [String] = []
            for e in els {
                if let te = (e["shape"] as? [String: Any])?["text"] as? [String: Any] {
                    let s = ((te["textElements"] as? [[String: Any]]) ?? []).compactMap { ($0["textRun"] as? [String: Any])?["content"] as? String }.joined()
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !s.isEmpty { t.append(s) }
                }
                if let g = (e["elementGroup"] as? [String: Any])?["children"] as? [[String: Any]] { t += texts(g) }
                if let rows = (e["table"] as? [String: Any])?["tableRows"] as? [[String: Any]] {
                    for r in rows {
                        let cells = ((r["tableCells"] as? [[String: Any]]) ?? []).map { c -> String in
                            ((((c["text"] as? [String: Any])?["textElements"] as? [[String: Any]]) ?? []).compactMap { ($0["textRun"] as? [String: Any])?["content"] as? String }.joined())
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                        t.append("| " + cells.joined(separator: " | ") + " |")
                    }
                }
            }
            return t
        }
        for (i, s) in ((o["slides"] as? [[String: Any]]) ?? []).enumerated() {
            out += "\n## Slide \(i + 1)\n"
            out += texts((s["pageElements"] as? [[String: Any]]) ?? []).joined(separator: "\n") + "\n"
            let notes = (((s["slideProperties"] as? [String: Any])?["notesPage"] as? [String: Any])?["pageElements"] as? [[String: Any]]) ?? []
            let n = texts(notes).joined(separator: " ")
            if !n.isEmpty { out += "Speaker notes: " + n + "\n" }
        }
        return out
    }

    /// spreadsheets.values.batchGet: each sheet as rows "a | b | c", at most `maxRows` rows per sheet.
    public static func sheet(title: String, ranges: [[String: Any]], maxRows: Int = 400) -> String {
        var out = "# " + title + "\n"
        for r in ranges {
            let name = ((r["range"] as? String) ?? "").components(separatedBy: "!").first?.trimmingCharacters(in: CharacterSet(charactersIn: "'")) ?? ""
            let rows = (r["values"] as? [[Any]]) ?? []
            out += "\n## " + name + "\n"
            for row in rows.prefix(maxRows) { out += "| " + row.map { "\($0)".replacingOccurrences(of: "\n", with: " ") }.joined(separator: " | ") + " |\n" }
            if rows.count > maxRows { out += "(\(rows.count - maxRows) more rows not included)\n" }
        }
        return out
    }
}

// MARK: - Calendar

public struct GoogleEvent: Equatable {
    public var id: String
    public var uid: String
    public var title: String
    public var start: Date
    public var end: Date
    public var allDay: Bool
    public var cancelled: Bool
    public var declined: Bool
    public var recurring: Bool
    public var attendees: [(name: String, email: String)]
    public var link: String?
    public var meetCode: String?
    public var attachments: [(title: String, url: String)]
    public var description: String
    public var location: String

    public static func == (a: GoogleEvent, b: GoogleEvent) -> Bool { a.id == b.id && a.start == b.start }

    static func date(_ o: Any?) -> (Date, Bool)? {
        guard let d = o as? [String: Any] else { return nil }
        if let s = d["dateTime"] as? String {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
            let g = ISO8601DateFormatter(); g.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let t = f.date(from: s) ?? g.date(from: s) { return (t, false) }
        }
        if let s = d["date"] as? String {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
            if let t = f.date(from: s) { return (t, true) }
        }
        return nil
    }

    /// One item of events.list (singleEvents=true).
    public static func parse(_ o: [String: Any]) -> GoogleEvent? {
        guard let id = o["id"] as? String, let (s, allDay) = date(o["start"]), let (e, _) = date(o["end"]) else { return nil }
        let people = (o["attendees"] as? [[String: Any]]) ?? []
        let me = people.first { ($0["self"] as? Bool) == true }
        let others = people.filter { ($0["self"] as? Bool) != true && ($0["resource"] as? Bool) != true }
        let conf = o["conferenceData"] as? [String: Any]
        let video = ((conf?["entryPoints"] as? [[String: Any]]) ?? []).first { ($0["entryPointType"] as? String) == "video" }?["uri"] as? String
        let link = (o["hangoutLink"] as? String) ?? video
        let code = (conf?["conferenceSolution"] as? [String: Any]).flatMap { (($0["key"] as? [String: Any])?["type"] as? String) == "hangoutsMeet" ? conf?["conferenceId"] as? String : nil }
            ?? link.flatMap(meetCode)
        return GoogleEvent(
            id: id, uid: (o["iCalUID"] as? String) ?? id, title: (o["summary"] as? String) ?? "",
            start: s, end: e, allDay: allDay, cancelled: (o["status"] as? String) == "cancelled",
            declined: (me?["responseStatus"] as? String) == "declined", recurring: o["recurringEventId"] != nil,
            attendees: others.map { (($0["displayName"] as? String) ?? "", (($0["email"] as? String) ?? "").lowercased()) },
            link: link, meetCode: code,
            attachments: ((o["attachments"] as? [[String: Any]]) ?? []).compactMap { a in (a["fileUrl"] as? String).map { ((a["title"] as? String) ?? "", $0) } },
            description: (o["description"] as? String) ?? "", location: (o["location"] as? String) ?? "")
    }

    /// "abc-defg-hij" from a meet.google.com link.
    public static func meetCode(_ link: String) -> String? {
        guard let r = link.range(of: "meet\\.google\\.com/([a-z]{3}-[a-z]{4}-[a-z]{3})", options: .regularExpression) else { return nil }
        return String(link[r].split(separator: "/").last ?? "")
    }
}

public enum CalendarMerge {
    /// The same occurrence in two places (an EventKit copy of a Google calendar, or the same invite in two connected
    /// accounts) has the same iCalendar UID and start. The EventKit row stays (its id keeps the brief, the hidden state
    /// and the series the PM already has) and takes the Google details; the first account wins over the next.
    public static func key(uid: String, start: Date) -> String { uid.lowercased() + "@" + String(Int(start.timeIntervalSince1970)) }

    /// enrich: EventKit index -> the Google index whose details it takes; keepGoogle: Google rows shown on their own.
    public static func plan(eventKit: [(uid: String?, start: Date)], google: [(uid: String, start: Date)]) -> (enrich: [Int: Int], keepGoogle: [Int]) {
        var first: [String: Int] = [:]; var order: [String] = []
        for (i, g) in google.enumerated() {
            let k = key(uid: g.uid, start: g.start)
            if first[k] == nil { first[k] = i; order.append(k) }
        }
        var enrich: [Int: Int] = [:], used = Set<String>()
        for (i, e) in eventKit.enumerated() {
            guard let u = e.uid else { continue }
            let k = key(uid: u, start: e.start)
            if let g = first[k] { enrich[i] = g; used.insert(k) }
        }
        return (enrich, order.filter { !used.contains($0) }.compactMap { first[$0] })
    }
}

// MARK: - Meet

public enum GoogleMeetText {
    /// Transcript entries (participant resource names) into "[HH:MM:SS] Name: text" lines from the call start.
    public static func transcript(entries: [[String: Any]], names: [String: String], start: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let g = ISO8601DateFormatter(); g.formatOptions = [.withInternetDateTime]
        return entries.compactMap { e -> String? in
            guard let text = e["text"] as? String, !text.isEmpty else { return nil }
            let who = names[(e["participant"] as? String) ?? ""] ?? "?"
            let t = (e["startTime"] as? String).flatMap { f.date(from: $0) ?? g.date(from: $0) }
            let s = max(0, Int((t ?? start).timeIntervalSince(start)))
            return String(format: "[%02d:%02d:%02d] ", s / 3600, (s / 60) % 60, s % 60) + who + ": " + text
        }.joined(separator: "\n")
    }

    /// participants.list item: the display name of a signed-in, anonymous or phone participant.
    public static func name(_ p: [String: Any]) -> String {
        for k in ["signedinUser", "anonymousUser", "phoneUser"] { if let n = (p[k] as? [String: Any])?["displayName"] as? String, !n.isEmpty { return n } }
        return "?"
    }
}

/// multipart/related for a Drive upload with conversion (a .docx becomes a Google Doc).
public enum DriveUpload {
    public static func body(name: String, convertTo: String, media: Data, mediaType: String, boundary: String) -> Data {
        let meta = (try? JSONSerialization.data(withJSONObject: ["name": name, "mimeType": convertTo])) ?? Data("{}".utf8)
        var d = Data()
        d.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8)); d.append(meta)
        d.append(Data("\r\n--\(boundary)\r\nContent-Type: \(mediaType)\r\n\r\n".utf8)); d.append(media)
        d.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return d
    }
}

// MARK: - Google Picker (0.10.0, Meeting Sheet)

// 0.10.0 (Meeting Sheet, Google Picker): a Drive file link (PDF, Word, any non Docs/Sheets/Slides file) is not read
// with the read-only Docs, Sheets and Slides scopes, and drive.readonly is restricted (CASA). "Confirm in Google"
// opens Google Picker on that one file with the drive.file token; after the PM confirms it the app may read that file
// only. rules/google.yaml > picker. Pure helpers here (CoreChecks); the window and the network are in the app.

/// The Picker's two build-time values: the API key (Google Picker API only) and the App ID (the Cloud project number).
/// bundle.sh writes them next to the OAuth client in Resources/google_oauth.json from PACENOTE_GOOGLE_PICKER_API_KEY
/// and PACENOTE_GOOGLE_APP_ID; never in git.
public struct GooglePickerKeys: Equatable {
    public var apiKey: String
    public var appID: String
    public init(apiKey: String, appID: String) { self.apiKey = apiKey; self.appID = appID }

    /// {"picker_api_key","app_id"} of google_oauth.json; nil when either is missing or empty (the Picker is off).
    public static func parse(_ data: Data) -> GooglePickerKeys? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let key = ((o["picker_api_key"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let app: String
        if let n = o["app_id"] as? NSNumber { app = n.stringValue } else { app = ((o["app_id"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !key.isEmpty, !app.isEmpty, app.allSatisfy(\.isNumber) else { return nil }
        return GooglePickerKeys(apiKey: key, appID: app)
    }
}

public enum GooglePickerPlan {
    /// What "Confirm in Google" does for one source.
    public enum Step: Equatable {
        case picker(account: String)      // open the Picker with this account's token
        case consent(account: String)     // the account lacks drive.file: sign in again for it, then the Picker
        case connect                      // no Google account at all
        case browser(reason: String)      // the honest fallback: open the file in the browser, the source stays "No access"
        case notDrive                     // not a Drive file link: nothing to confirm here
    }

    /// The Drive file id of a link that the Picker can confirm (drive.google.com/file/d/<id> or open?id=<id>).
    public static func fileID(_ url: String) -> String? {
        guard let l = GoogleLink.parse(url), l.kind == .file else { return nil }
        return l.id
    }

    /// keys nil = the build has no Picker values -> the browser. Accounts: the first one with drive.file wins
    /// (`preferred` first when it is one of them); none with it -> consent for the first account.
    public static func decide(url: String, keys: GooglePickerKeys?, accounts: [GoogleAccount], preferred: String? = nil) -> Step {
        guard fileID(url) != nil else { return .notDrive }
        guard keys != nil else { return .browser(reason: "picker_not_set_up") }
        guard let first = accounts.first else { return .connect }
        let withFile = accounts.filter { $0.has(GoogleScopes.export) }
        if let p = preferred, withFile.contains(where: { $0.email == p }) { return .picker(account: p) }
        if let a = withFile.first { return .picker(account: a.email) }
        return .consent(account: first.email)
    }

    /// The JSON the bundled picker page reads (window.PN_PICKER). The token is in memory only; it never reaches a file.
    public static func config(fileID: String, token: String, keys: GooglePickerKeys, origin: String, locale: String) -> [String: String] {
        ["fileId": fileID, "token": token, "apiKey": keys.apiKey, "appId": keys.appID, "origin": origin,
         "locale": locale == "uk" ? "uk" : "en"]
    }

    /// The picker page's message to the app (WKScriptMessageHandler "pacenotePicker").
    public enum Message: Equatable { case picked(id: String, name: String, mimeType: String), cancelled, loaded, failed(String) }

    public static func message(_ body: Any) -> Message? {
        guard let o = body as? [String: Any], let k = o["event"] as? String else { return nil }
        switch k {
        case "picked":
            guard let id = o["id"] as? String, !id.isEmpty else { return .failed("no file id") }
            return .picked(id: id, name: (o["name"] as? String) ?? "", mimeType: (o["mimeType"] as? String) ?? "")
        case "cancel": return .cancelled
        case "loaded": return .loaded
        case "error": return .failed((o["error"] as? String) ?? "unknown")
        default: return nil
        }
    }
}

/// The local copy of a confirmed Drive file: <project>/live/google/google-file-<id16>.<ext>, like the other Google copies.
public enum GoogleDriveCopy {
    /// Google-native files are exported (Docs and Slides as text, Sheets as CSV); others are downloaded as they are.
    public static func export(for mimeType: String) -> (mime: String, ext: String)? {
        switch mimeType {
        case "application/vnd.google-apps.document": return ("text/plain", "txt")
        case "application/vnd.google-apps.presentation": return ("text/plain", "txt")
        case "application/vnd.google-apps.spreadsheet": return ("text/csv", "csv")
        default: return nil
        }
    }

    static let extByMime: [String: String] = [
        "application/pdf": "pdf", "text/plain": "txt", "text/markdown": "md", "text/csv": "csv", "text/html": "html",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation": "pptx",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
        "application/rtf": "rtf", "application/msword": "doc", "application/json": "json",
    ]

    /// The extension of the copy: the export's, else the file name's, else the MIME type's, else "bin".
    public static func ext(mimeType: String, name: String) -> String {
        if let e = export(for: mimeType) { return e.ext }
        let n = (name as NSString).pathExtension.lowercased()
        if !n.isEmpty, n.count <= 5, n.allSatisfy({ $0.isLetter || $0.isNumber }) { return n }
        return extByMime[mimeType] ?? "bin"
    }

    public static func fileName(id: String, mimeType: String, name: String) -> String {
        "google-file-\(id.prefix(16)).\(ext(mimeType: mimeType, name: name))"
    }

    /// An existing confirmed copy of this file id in `folder` (any extension), the newest first; nil when none.
    public static func existing(in folder: String, id: String) -> String? {
        let prefix = "google-file-\(id.prefix(16))."
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        let hits = names.filter { $0.hasPrefix(prefix) && !$0.hasSuffix(".part") }.map { (folder as NSString).appendingPathComponent($0) }
        func m(_ p: String) -> Date { ((try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date) ?? .distantPast }
        return hits.max { m($0) < m($1) }
    }

    /// The Drive API URL that gives the file's bytes (alt=media) or its export (Google-native types).
    public static func downloadURL(id: String, mimeType: String) -> String {
        let base = "https://www.googleapis.com/drive/v3/files/\(id)"
        if let e = export(for: mimeType) {
            return base + "/export?mimeType=" + (e.mime.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? e.mime)
        }
        return base + "?alt=media&supportsAllDrives=true"
    }
}
