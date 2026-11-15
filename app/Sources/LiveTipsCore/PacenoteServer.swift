import Foundation

// B7 (server ADR 5.1, 2026-11-15): the Pacenote account. Optional: without it the app works as before. Sign-in is a
// separate Google request with `openid email profile` only, so the Pacenote account and the Google accounts that give
// calendars and Drive stay independent. The app sends Google's ID token to the server once and gets the server's own
// tokens: access for 15 minutes (memory only), refresh for 60 days with rotation (Keychain only). Pure helpers here
// (CoreChecks); the network is in the app (PacenoteAccount.swift).

public enum PacenoteServer {
    public static let defaultURL = "https://pacenote-api.bodco.pm"

    /// The server address: an override for a development server (UserDefaults "pacenoteServerURL"), else the default.
    /// Only https, or http to this Mac, is accepted; anything else falls back to the default.
    public static func baseURL(override: String?) -> URL {
        let o = (override ?? "").trimmingCharacters(in: .whitespaces)
        if let u = URL(string: o), let s = u.scheme, let h = u.host, !h.isEmpty,
           s == "https" || (s == "http" && (h == "127.0.0.1" || h == "localhost")) {
            return URL(string: o.hasSuffix("/") ? String(o.dropLast()) : o)!
        }
        return URL(string: defaultURL)!
    }

    /// What the app keeps in the Keychain (SecretStore.Key.pacenoteSession): the refresh token and who signed in.
    public struct Session: Codable, Equatable {
        public var refreshToken: String
        public var refreshExpires: Date
        public var email: String
        public var name: String
        public var signedIn: Date
        public init(refreshToken: String, refreshExpires: Date, email: String, name: String, signedIn: Date = Date()) {
            self.refreshToken = refreshToken; self.refreshExpires = refreshExpires; self.email = email; self.name = name
            self.signedIn = signedIn
        }
        public func encoded() -> String {
            let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]
            return (try? e.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        public static func decode(_ s: String?) -> Session? {
            guard let d = s?.data(using: .utf8) else { return nil }
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            return try? dec.decode(Session.self, from: d)
        }
    }

    public struct Tokens: Equatable {
        public var access: String
        public var accessExpires: Date
        public var refresh: String
        public var refreshExpires: Date
    }

    /// A TokenPair from /v1/auth/google or /v1/auth/refresh. The access token is treated as expired a minute early.
    public static func tokens(_ o: [String: Any], now: Date = Date()) -> Tokens? {
        guard let a = o["access_token"] as? String, !a.isEmpty, let r = o["refresh_token"] as? String, !r.isEmpty else { return nil }
        let ae = (o["access_expires_in"] as? Int) ?? 900, re = (o["refresh_expires_in"] as? Int) ?? 60 * 24 * 3600
        return Tokens(access: a, accessExpires: now.addingTimeInterval(Double(max(ae - 60, 30))), refresh: r,
                      refreshExpires: now.addingTimeInterval(Double(re)))
    }

    public struct Org: Equatable, Identifiable {
        public var id: String
        public var name: String
        public var kind: String      // personal / team
        public var role: String      // owner / admin / member
        public var plan: String
        /// 0.11.0 (B7b): the organization's policy `require_transcript_in_drive` (server ADR 3.4).
        public var requireTranscriptInDrive = false
        public init(id: String, name: String, kind: String, role: String, plan: String, requireTranscriptInDrive: Bool = false) {
            self.id = id; self.name = name; self.kind = kind; self.role = role; self.plan = plan
            self.requireTranscriptInDrive = requireTranscriptInDrive
        }
    }

    public struct Me: Equatable {
        public var email: String
        public var name: String
        public var orgs: [Org]
        /// The first organization that requires the transcript in Drive (its name is shown on the locked switch).
        public var transcriptRequiredBy: String? { orgs.first { $0.requireTranscriptInDrive }?.name }
    }

    public static func me(_ o: [String: Any]) -> Me? {
        guard let u = o["user"] as? [String: Any], let email = u["email"] as? String else { return nil }
        let orgs = ((o["organizations"] as? [[String: Any]]) ?? []).compactMap { g -> Org? in
            guard let id = g["id"] as? String else { return nil }
            return Org(id: id, name: (g["name"] as? String) ?? "", kind: (g["kind"] as? String) ?? "",
                       role: (g["org_role"] as? String) ?? "", plan: (g["plan"] as? String) ?? "",
                       requireTranscriptInDrive: ((g["policy"] as? [String: Any])?["require_transcript_in_drive"] as? Bool) ?? false)
        }
        return Me(email: email, name: (u["name"] as? String) ?? "", orgs: orgs)
    }

    public struct Device: Equatable, Identifiable {
        public var id: String
        public var name: String
        public var appVersion: String
        public var lastSeen: Date?
        public var current: Bool
    }

    public static func devices(_ a: [[String: Any]]) -> [Device] {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let g = ISO8601DateFormatter()
        return a.compactMap { d in
            guard let id = d["id"] as? String else { return nil }
            let seen = (d["last_seen_at"] as? String).flatMap { f.date(from: $0) ?? g.date(from: $0) }
            return Device(id: id, name: (d["name"] as? String) ?? "", appVersion: (d["app_version"] as? String) ?? "",
                          lastSeen: seen, current: (d["current"] as? Bool) == true)
        }
        .sorted { ($0.current ? 0 : 1, -($0.lastSeen?.timeIntervalSince1970 ?? 0)) < ($1.current ? 0 : 1, -($1.lastSeen?.timeIntervalSince1970 ?? 0)) }
    }

    /// The body of POST /v1/auth/google. The server rejects unknown fields and names over 100 characters.
    public static func signInBody(idToken: String, deviceName: String, appVersion: String) -> Data {
        let name = String(deviceName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        let o: [String: Any] = ["id_token": idToken,
                                "device": ["name": name.isEmpty ? "Mac" : name, "platform": "macos",
                                           "app_version": appVersion.isEmpty ? "dev" : String(appVersion.prefix(40))]]
        return (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
    }

    /// A short reason from an RFC 9457 problem body (detail, else title), never the raw body.
    public static func problem(_ data: Data, status: Int) -> String {
        let o = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        let s = (o["detail"] as? String) ?? (o["title"] as? String) ?? ""
        return s.isEmpty ? "HTTP \(status)" : String(s.prefix(160))
    }

    /// 0.12.1 (B8): a 402 names the plan quota it hit ("storage_mb") and its limit; nil for any other answer.
    public struct Quota: Equatable {
        public let name: String; public let limit: Int
        public init(name: String, limit: Int) { self.name = name; self.limit = limit }
    }
    public static func quota(_ data: Data, status: Int) -> Quota? {
        guard status == 402, let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let n = o["quota"] as? String, !n.isEmpty else { return nil }
        return Quota(name: n, limit: (o["limit"] as? Int) ?? 0)
    }

    /// What the app does after a failed refresh: 401 means the session ended on the server (signed out elsewhere,
    /// revoked, deleted): forget it here. Anything else (no network, 5xx, 429) keeps it and tries again later.
    public static func refreshEndsSession(status: Int) -> Bool { status == 401 }
}
