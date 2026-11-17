import Foundation

// 0.22.0 (B13, D48, server 0.13.0): sign-in with email and password next to Google, and D50 (Bohdan 18.11): an account
// is required, the sign-in screen comes before onboarding. Pure helpers (CoreChecks): request bodies, the server's
// answers, the code field, the local password rule, the countdowns and which screen the app shows. The network is in
// the app (PacenoteAccount.swift). The password only lives in the text field and in the request body.

extension PacenoteServer {

    // MARK: what the server offers, and how this person signs in

    /// GET /v1/auth/methods. `email` is false while the server has no mail (no Postmark token): Google only then.
    public struct AuthMethods: Equatable {
        public var google: Bool
        public var email: Bool
        public init(google: Bool = true, email: Bool = false) { self.google = google; self.email = email }
    }
    /// A server before 0.13.0 has no such route (404): Google only, like an unreachable server.
    public static func authMethods(_ o: [String: Any]?) -> AuthMethods {
        guard let o else { return AuthMethods() }
        return AuthMethods(google: (o["google"] as? Bool) ?? true, email: (o["email"] as? Bool) == true)
    }

    /// `auth` in /v1/me (server 0.13.0): the ways this person signs in.
    public struct AuthInfo: Equatable {
        public var google: Bool
        public var password: Bool
        public var passwordChangedAt: Date?
        public init(google: Bool, password: Bool, passwordChangedAt: Date? = nil) {
            self.google = google; self.password = password; self.passwordChangedAt = passwordChangedAt
        }
        /// Removing one way needs the other one (the server answers `last_method` otherwise).
        public var canRemovePassword: Bool { password && google }
        public var canDisconnectGoogle: Bool { google && password }
    }
    public static func authInfo(_ o: Any?) -> AuthInfo? {
        guard let a = o as? [String: Any] else { return nil }
        return AuthInfo(google: (a["google"] as? Bool) == true, password: (a["password"] as? Bool) == true,
                        passwordChangedAt: isoDate(a["password_changed_at"]))
    }

    // MARK: request bodies (the server rejects unknown fields)

    /// DeviceInfo, the same in every sign-in body: name up to 100 characters, `macos`, the version, the Mac hash.
    public static func deviceInfo(deviceName: String, appVersion: String, machine: String? = nil) -> [String: Any] {
        let name = String(deviceName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        var d: [String: Any] = ["name": name.isEmpty ? "Mac" : name, "platform": "macos",
                                "app_version": appVersion.isEmpty ? "dev" : String(appVersion.prefix(40))]
        if let m = machine, m.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil { d["machine"] = m }
        return d
    }

    static func body(_ o: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
    }

    /// The mail's language: Ukrainian for a Ukrainian interface, else English.
    public static func mailLocale(_ uiLang: String) -> String { uiLang.lowercased().hasPrefix("uk") ? "uk" : "en" }

    /// POST /v1/auth/email/register. An empty name is left out (the server then uses the part before the @).
    public static func registerBody(email: String, password: String, name: String, locale: String) -> Data {
        var o: [String: Any] = ["email": cleanEmail(email), "password": password, "locale": mailLocale(locale)]
        let n = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        if !n.isEmpty { o["name"] = n }
        return body(o)
    }
    /// POST /v1/auth/email/login.
    public static func loginBody(email: String, password: String, device: [String: Any]) -> Data {
        body(["email": cleanEmail(email), "password": password, "device": device])
    }
    /// POST /v1/auth/email/verify.
    public static func verifyBody(signupID: String, code: String, device: [String: Any]) -> Data {
        body(["signup_id": signupID, "code": codeDigits(code), "device": device])
    }
    /// POST /v1/auth/email/resend: exactly one of the two ids.
    public static func resendBody(signupID: String? = nil, resetID: String? = nil) -> Data {
        if let s = signupID, !s.isEmpty { return body(["signup_id": s]) }
        return body(["reset_id": resetID ?? ""])
    }
    /// POST /v1/auth/password/forgot.
    public static func forgotBody(email: String, locale: String) -> Data {
        body(["email": cleanEmail(email), "locale": mailLocale(locale)])
    }
    /// POST /v1/auth/password/reset.
    public static func resetBody(resetID: String, code: String, newPassword: String, device: [String: Any]) -> Data {
        body(["reset_id": resetID, "code": codeDigits(code), "new_password": newPassword, "device": device])
    }
    /// POST /v1/auth/google/link, after `link_required`.
    public static func linkBody(linkID: String, password: String, device: [String: Any]) -> Data {
        body(["link_id": linkID, "password": password, "device": device])
    }
    /// PUT /v1/me/password: `current_password` to change it; without it the server wants Google confirmed on this Mac
    /// within 10 minutes (adding a password to a Google account, or a change after Google).
    public static func setPasswordBody(current: String?, new: String) -> Data {
        var o: [String: Any] = ["new_password": new]
        if let c = current, !c.isEmpty { o["current_password"] = c }
        return body(o)
    }
    /// PUT /v1/me/google.
    public static func connectGoogleBody(idToken: String, currentPassword: String) -> Data {
        body(["id_token": idToken, "current_password": currentPassword])
    }
    /// DELETE /v1/me/google.
    public static func currentPasswordBody(_ current: String) -> Data { body(["current_password": current]) }

    // MARK: answers

    /// 202 from register or forgot: the id to send back with the code, how long the code lives, when a resend is allowed.
    public struct CodeStarted: Equatable {
        public var id: String
        public var expiresIn: Int
        public var resendIn: Int
        public init(id: String, expiresIn: Int = 900, resendIn: Int = 60) { self.id = id; self.expiresIn = expiresIn; self.resendIn = resendIn }
    }
    public static func codeStarted(_ o: [String: Any]) -> CodeStarted? {
        guard let id = (o["signup_id"] as? String) ?? (o["reset_id"] as? String), !id.isEmpty else { return nil }
        return CodeStarted(id: id, expiresIn: max(60, (o["expires_in"] as? Int) ?? 900), resendIn: max(0, (o["resend_in"] as? Int) ?? 60))
    }

    /// An error answer of the sign-in routes (RFC 9457 with a short `type`).
    public struct AuthProblem: Equatable {
        public var status: Int
        public var type: String
        public var attemptsLeft: Int?
        /// Seconds; from `Retry-After`, else `retry_after` in the body.
        public var retryAfter: Int?
        public var reason = ""
        public var linkID = ""
        public var expiresIn: Int?
        public var detail = ""
        public init(status: Int, type: String, attemptsLeft: Int? = nil, retryAfter: Int? = nil, reason: String = "",
                    linkID: String = "", expiresIn: Int? = nil, detail: String = "") {
            self.status = status; self.type = type; self.attemptsLeft = attemptsLeft; self.retryAfter = retryAfter
            self.reason = reason; self.linkID = linkID; self.expiresIn = expiresIn; self.detail = detail
        }
    }
    public static func authProblem(_ data: Data, status: Int, retryAfter header: String? = nil) -> AuthProblem {
        let o = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        var t = (o["type"] as? String) ?? ""
        if t.contains("/") { t = String(t.split(separator: "/").last ?? "") }      // a URI type keeps its last part
        let wait = header.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? (o["retry_after"] as? Int)
        return AuthProblem(status: status, type: t, attemptsLeft: o["attempts_left"] as? Int, retryAfter: wait.map { max(1, $0) },
                           reason: (o["reason"] as? String) ?? "", linkID: (o["link_id"] as? String) ?? "",
                           expiresIn: o["expires_in"] as? Int, detail: String(((o["detail"] as? String) ?? "").prefix(160)))
    }

    /// Where the error came from: the same `invalid_credentials` reads differently on the sign-in form (could be no
    /// account at all) and when the app asks for the password of the account already signed in.
    public enum AuthContext: Equatable { case signIn, signUp, code, reset, link, methods, google }

    /// The interface string for an answer: key and its values (`{email}` the caller adds). nil: no special text,
    /// show the generic server error.
    public struct AuthMessage: Equatable {
        public var key: String
        public var args: [String: String]
        public init(_ key: String, _ args: [String: String] = [:]) { self.key = key; self.args = args }
    }
    public static func authMessage(_ p: AuthProblem, context: AuthContext) -> AuthMessage? {
        let time = countdown(p.retryAfter ?? 0)
        switch p.type {
        case "invalid_credentials":
            return AuthMessage(context == .signIn ? "auth.err.credentials" : "account.methods.wrongPassword")
        case "locked": return AuthMessage("auth.err.locked", ["time": time])
        case "code_limit": return AuthMessage("auth.err.codeLimit")
        case "resend_wait": return AuthMessage("auth.code.resendIn", ["time": time])
        case "invalid_code":
            if let n = p.attemptsLeft, n <= 0 { return AuthMessage("auth.err.codeSpent") }
            return AuthMessage("auth.err.code", ["n": String(p.attemptsLeft ?? 0)])
        case "code_expired": return AuthMessage("auth.err.codeExpired")
        case "weak_password": return AuthMessage(weakKey(p.reason))
        case "invalid_email": return AuthMessage("auth.err.emailFormat")
        case "undeliverable": return AuthMessage("auth.err.undeliverable")
        case "email_signin_off": return AuthMessage("auth.err.off")
        case "link_expired": return AuthMessage("auth.err.linkExpired")
        case "email_taken": return AuthMessage("auth.err.emailTaken")
        case "google_reauth": return AuthMessage("account.methods.confirmGoogle")
        case "last_method": return AuthMessage("account.methods.last")
        case "email_mismatch": return AuthMessage("account.methods.mismatch")
        case "google_taken": return AuthMessage("account.methods.taken")
        default:
            if p.status == 429 { return AuthMessage("auth.err.locked", ["time": time]) }
            if p.status == 503 { return AuthMessage("auth.err.off") }
            return nil
        }
    }
    static func weakKey(_ reason: String) -> String {
        switch reason {
        case "too_long": return "auth.err.weak.long"
        case "common": return "auth.err.weak.common"
        case "contains_email": return "auth.err.weak.email"
        default: return "auth.err.weak.short"
        }
    }
    /// The code for analytics (`signin_failed`): the type when it is one we know, else the status class.
    public static func failureCode(_ p: AuthProblem) -> String {
        let known = ["invalid_credentials", "locked", "code_limit", "resend_wait", "invalid_code", "code_expired",
                     "weak_password", "invalid_email", "undeliverable", "email_signin_off", "link_expired", "email_taken",
                     "google_reauth", "last_method", "email_mismatch", "google_taken", "link_required"]
        if known.contains(p.type) { return p.type }
        return p.status >= 500 ? "server_5xx" : "server_4xx"
    }

    // MARK: fields

    /// The address as sent: trimmed, nothing else (the server lowercases it for the comparison).
    public static func cleanEmail(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A first check before asking the server: one @, a dot in the domain, no spaces, at most 254 characters.
    public static func emailLooksValid(_ s: String) -> Bool {
        let e = cleanEmail(s)
        guard e.count <= 254 else { return false }
        return e.range(of: #"^[^@\s]+@[^@\s.]+(\.[^@\s.]+)+$"#, options: .regularExpression) != nil
    }

    /// The local part of the password rule (the server also checks common passwords, the email and "pacenote"):
    /// 10 to 128 characters after NFKC. nil when fine, else the server's reason name.
    public static func passwordProblem(_ s: String) -> String? {
        // code points, like the server's len() in Python, not Swift's grapheme count (an emoji or an accent would differ)
        let n = s.precomposedStringWithCompatibilityMapping.unicodeScalars.count
        if n < 10 { return "too_short" }
        if n > 128 { return "too_long" }
        return nil
    }

    /// The digits of a code as typed or pasted ("1234 5678", "1234-5678", "Your code: 12345678"), at most 8.
    public static func codeDigits(_ s: String) -> String {
        String(s.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) && $0.isASCII }.map(Character.init).prefix(8))
    }
    /// The code field shows "1234 5678".
    public static func formatCode(_ s: String) -> String {
        let d = codeDigits(s)
        return d.count > 4 ? String(d.prefix(4)) + " " + String(d.dropFirst(4)) : d
    }
    /// Eight digits: the field sends it by itself.
    public static func codeComplete(_ s: String) -> Bool { codeDigits(s).count == 8 }

    /// A countdown as "0:27" or "15:00".
    public static func countdown(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return "\(s / 60):" + String(format: "%02d", s % 60)
    }
    /// Seconds left until `until`, rounded up, never below zero.
    public static func secondsLeft(until: Date?, now: Date = Date()) -> Int {
        guard let u = until else { return 0 }
        return max(0, Int(ceil(u.timeIntervalSince(now))))
    }

    // MARK: D50: the sign-in screen comes first

    public enum Gate: Equatable {
        /// The session is still being read from the Keychain: show nothing yet.
        case loading
        /// No session: the sign-in screen, before onboarding and Home.
        case signIn
        /// The session ended during a call: the call goes on, the sign-in screen comes after it.
        case afterCall
        case onboarding
        case home
    }
    public static func gate(sessionKnown: Bool, signedIn: Bool, onboarded: Bool, callLive: Bool) -> Gate {
        guard sessionKnown else { return .loading }
        guard signedIn else { return callLive ? .afterCall : .signIn }
        return onboarded ? .home : .onboarding
    }
}
