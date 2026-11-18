import AppKit
import SwiftUI
import LiveTipsCore

// 0.22.0 (B13, D48; D50 Bohdan 18.11): the sign-in screen. Pacenote needs an account, so this window comes before
// onboarding and Home and stays until the person is signed in. Google or email: one form with Sign in / Create account
// (the address stays when switching), the 8-digit code from the email, a password reset, and joining Google to a
// password account after `link_required`. Texts: research/pacenote-b13-copy-and-signin-critique-2026-11-17.md.
// The password lives only in the field and the request; every field is cleared once signed in.

@MainActor
final class SignInModel: ObservableObject {
    enum Step: String { case choose, email, code, resetAsk = "reset", resetCode = "reset_code", link }
    enum Field: Hashable { case email, password, name, code, newPassword, linkPassword }

    @Published var step: Step = .choose { didSet { if step != oldValue { stepChanged() } } }
    @Published var creating = false
    @Published var email = ""
    @Published var password = ""
    @Published var name = ""
    @Published var code = ""
    @Published var newPassword = ""
    @Published var linkPassword = ""
    @Published var showPassword = false
    @Published var busy = false
    @Published var error: String?
    @Published var errorField: Field?
    @Published var info: String?
    @Published var codeEmail = ""
    @Published var resendAt: Date?
    @Published var lockedUntil: Date?
    private var signupID = "", resetID = ""
    let acct = PacenoteAccount.shared

    /// Set while the window resets after signing in: the reset is not a screen the person saw.
    var quiet = false

    private func stepChanged() {
        error = nil; errorField = nil; info = nil
        if quiet { return }
        let sub = step == .resetCode ? "reset" : step.rawValue
        AnalyticsTracker.shared.screen("sign_in", sub: sub)
    }

    /// Back to the start; the address stays, every secret goes.
    func restart() {
        password = ""; newPassword = ""; linkPassword = ""; code = ""; signupID = ""; resetID = ""
        lockedUntil = nil; resendAt = nil; step = .choose
    }
    func clearSecrets() { password = ""; newPassword = ""; linkPassword = ""; code = "" }

    private func run(_ field: Field? = nil, _ f: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil; errorField = nil; info = nil
        Task {
            defer { busy = false }
            do { try await f() }
            catch let e as PacenoteAccount.AuthFailure { handle(e, field) }
            catch { self.error = error.localizedDescription; errorField = nil }
        }
    }

    private func handle(_ e: PacenoteAccount.AuthFailure, _ fallback: Field?) {
        guard let p = e.problem else { error = e.text; errorField = nil; return }
        if p.type == "resend_wait", let w = p.retryAfter { resendAt = Date().addingTimeInterval(Double(w)); return }
        if p.status == 429, p.type != "code_limit", let w = p.retryAfter {
            lockedUntil = Date().addingTimeInterval(Double(w)); error = nil; errorField = nil; return
        }
        error = e.text
        switch p.type {
        case "invalid_email", "undeliverable": errorField = .email
        case "weak_password": errorField = step == .resetCode ? .newPassword : .password
        case "invalid_credentials": errorField = step == .link ? .linkPassword : .password
        case "invalid_code", "code_expired": errorField = .code
        default: errorField = fallback
        }
    }

    private func local(_ key: String, _ f: Field, _ args: [String: String] = [:]) { error = L(key, args); errorField = f }
    private func weak(_ reason: String, _ f: Field) {
        let m = PacenoteServer.authMessage(PacenoteServer.AuthProblem(status: 422, type: "weak_password", reason: reason), context: .signUp)
        local(m?.key ?? "auth.err.weak.short", f)
    }
    var locked: Bool { PacenoteServer.secondsLeft(until: lockedUntil) > 0 }

    // MARK: actions

    func google() {
        AnalyticsTracker.shared.track("auth_method_chosen", ["method": "google"])
        acct.startSignIn()
    }
    func chooseEmail() {
        AnalyticsTracker.shared.track("auth_method_chosen", ["method": "password"])
        step = .email
    }

    func submitEmail() {
        guard PacenoteServer.emailLooksValid(email) else { return local("auth.err.emailFormat", .email) }
        if creating {
            if let r = PacenoteServer.passwordProblem(password) { return weak(r, .password) }
            run(.email) { [self] in
                let c = try await acct.register(email: email, password: password, name: name)
                signupID = c.id; codeEmail = PacenoteServer.cleanEmail(email); code = ""
                resendAt = Date().addingTimeInterval(Double(c.resendIn)); password = ""
                step = .code
            }
        } else {
            guard !password.isEmpty else { return local("auth.err.credentials", .password) }
            run(.password) { [self] in try await acct.signInEmail(email: email, password: password) }
        }
    }

    func codeTyped(_ v: String) {
        let f = PacenoteServer.formatCode(v)
        // only the keystroke that completes the code sends it: a 9th digit or the field's end-of-editing set with the
        // same 8 digits must not send a wrong code again and spend an attempt
        let wasComplete = PacenoteServer.codeComplete(code)
        if f != code { code = f }
        if step == .code, !wasComplete, PacenoteServer.codeComplete(f), !busy { verify() }
    }
    func verify() {
        guard PacenoteServer.codeComplete(code) else { return local("auth.code.field", .code) }
        run(.code) { [self] in try await acct.verify(signupID: signupID, code: code, email: codeEmail) }
    }
    func resend() {
        run(.code) { [self] in
            try await acct.resend(signupID: step == .code ? signupID : nil, resetID: step == .resetCode ? resetID : nil)
            resendAt = Date().addingTimeInterval(60); code = ""; info = L("auth.code.resent")
        }
    }
    func otherEmail() { code = ""; signupID = ""; resendAt = nil; step = .email }

    func forgot() { password = ""; step = .resetAsk }
    func sendReset() {
        guard PacenoteServer.emailLooksValid(email) else { return local("auth.err.emailFormat", .email) }
        run(.email) { [self] in
            let c = try await acct.forgot(email: email)
            resetID = c.id; codeEmail = PacenoteServer.cleanEmail(email); code = ""; newPassword = ""
            resendAt = Date().addingTimeInterval(Double(c.resendIn))
            step = .resetCode
        }
    }
    func submitReset() {
        guard PacenoteServer.codeComplete(code) else { return local("auth.code.field", .code) }
        if let r = PacenoteServer.passwordProblem(newPassword) { return weak(r, .newPassword) }
        run(.code) { [self] in try await acct.reset(resetID: resetID, code: code, newPassword: newPassword, email: codeEmail) }
    }

    func linkShown() { linkPassword = ""; step = .link }
    func submitLink() {
        guard !linkPassword.isEmpty else { return local("account.methods.wrongPassword", .linkPassword) }
        run(.linkPassword) { [self] in try await acct.linkGoogle(password: linkPassword) }
    }
    func cancelLink() { acct.cancelLink(); restart() }
    func linkForgot() { email = acct.pendingLink?.email ?? email; acct.cancelLink(); forgot() }
}

struct SignInView: View {
    @ObservedObject var m: SignInModel
    @ObservedObject private var acct = PacenoteAccount.shared
    @FocusState private var focus: SignInModel.Field?
    let quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PN.Space.x4) {
            switch m.step {
            case .choose: choose
            case .email: emailForm
            case .code: codeStep
            case .resetAsk: resetAsk
            case .resetCode: resetCode
            case .link: linkStep
            }
        }
        .padding(28)
        .frame(width: 420, alignment: .leading)
        .disabled(m.busy)
        .onChange(of: acct.pendingLink) { _, l in if l != nil { m.linkShown() } }
        .onChange(of: m.errorField) { _, f in if let f { focus = f } }
        .onChange(of: m.error) { _, e in
            guard let e else { return }
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: e, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        .onAppear {
            AnalyticsTracker.shared.screen("sign_in", sub: m.step == .resetCode ? "reset" : m.step.rawValue)
            Task { await acct.loadMethods() }
        }
    }

    // MARK: steps

    @ViewBuilder private var choose: some View {
        Text(L("gate.title")).pnTitle()
        Text(L("gate.intro")).font(PN.Font.body).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: PN.Space.x2) {
            Button(action: m.google) { Text(L("account.signIn")).frame(maxWidth: .infinity) }
                .buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
                .disabled(!GoogleService.shared.configured || acct.signIn == .waiting)
            Text(L("auth.google.sub")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            switch acct.signIn {
            case .waiting:
                HStack(spacing: 8) {
                    PNSpinner(size: 16)
                    Text(L("google.waiting")).font(PN.Font.caption).foregroundStyle(PN.C.text2)
                    Spacer()
                    Button(L("auth.cancel")) { acct.cancelSignIn() }.buttonStyle(.pnTertiary)
                }
            case .failed(let e): errorLine(e)
            case .idle: EmptyView()
            }
            if !GoogleService.shared.configured { errorLine(L("google.err.noClient")) }
        }
        if acct.methods.email {
            Button(action: m.chooseEmail) { Text(L("account.signIn.email")).frame(maxWidth: .infinity) }.buttonStyle(.pnSecondary)
        }
        if !acct.serverReachable {
            HStack(alignment: .top, spacing: 8) {
                errorLine(L("gate.offline"))
                Spacer()
                Button(L("gate.retry")) { Task { await acct.loadMethods() } }.buttonStyle(.pnTertiary)
            }
        }
        if let n = acct.notice { Text(n).font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true) }
        HStack {
            Link(L("account.privacy"), destination: URL(string: "https://pacenote.bodco.pm/privacy/")!)
            Link(L("account.terms"), destination: URL(string: "https://pacenote.bodco.pm/terms/")!)
            Spacer()
            Button(L("gate.quit"), action: quit).buttonStyle(.pnTertiary)
        }
        .font(PN.Font.caption)
    }

    @ViewBuilder private var emailForm: some View {
        PNSegmented(selection: $m.creating, options: [
            (false, L("auth.tab.signIn")),
            (true, L("auth.tab.create"))
        ]).labelsHidden()
        .onChange(of: m.creating) { _, _ in m.error = nil; m.errorField = nil }
        field(L("auth.email"), .email) {
            TextField("name@example.com", text: $m.email).textContentType(.username).focused($focus, equals: .email)
        }
        passwordField(L("auth.password"), $m.password, .password)
        if m.creating {
            rule(m.password)
            field(L("auth.name"), .name) {
                TextField("Mike", text: $m.name).focused($focus, equals: .name)
            }
            Text(L("auth.name.hint")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
        }
        lockedLine
        if m.error != nil, m.errorField == nil { errorLine(m.error!) }
        if m.creating {
            Text(L("auth.create.legal")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Button(L("auth.code.back")) { m.restart() }.buttonStyle(.pnTertiary)
            if !m.creating { Button(L("auth.forgot"), action: m.forgot).buttonStyle(.pnTertiary) }
            Spacer()
            if m.busy { PNSpinner(size: 16) }
            Button(L(m.creating ? "auth.submit.create" : "auth.submit.signIn"), action: m.submitEmail)
                .buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction).disabled(m.locked)
        }
        .onAppear { focus = m.email.isEmpty ? .email : .password }
    }

    @ViewBuilder private var codeStep: some View {
        Text(L("auth.code.title")).pnTitle()
        Text(L("auth.code.sent", ["email": m.codeEmail])).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
        codeField
        lockedLine
        if let i = m.info { Text(i).font(PN.Font.caption).foregroundStyle(PN.C.text2) }
        Text(L("auth.code.exists")).font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
        resendRow
        HStack {
            Button(L("auth.code.other"), action: m.otherEmail).buttonStyle(.pnTertiary)
            Button(L("auth.code.back")) { m.restart() }.buttonStyle(.pnTertiary)
            Spacer()
            if m.busy { PNSpinner(size: 16) }
        }
        .onAppear { focus = .code }
    }

    @ViewBuilder private var resetAsk: some View {
        Text(L("auth.reset.title")).pnTitle()
        Text(L("auth.reset.intro")).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
        field(L("auth.email"), .email) {
            TextField("name@example.com", text: $m.email).textContentType(.username).focused($focus, equals: .email)
        }
        lockedLine
        if m.error != nil, m.errorField == nil { errorLine(m.error!) }
        HStack {
            Button(L("auth.code.back")) { m.step = .email }.buttonStyle(.pnTertiary)
            Spacer()
            if m.busy { PNSpinner(size: 16) }
            Button(L("auth.reset.send"), action: m.sendReset).buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction).disabled(m.locked)
        }
        .onAppear { focus = .email }
    }

    @ViewBuilder private var resetCode: some View {
        Text(L("auth.reset.title")).pnTitle()
        Text(L("auth.code.sent", ["email": m.codeEmail])).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
        codeField
        passwordField(L("auth.reset.new"), $m.newPassword, .newPassword)
        rule(m.newPassword)
        lockedLine
        if let i = m.info { Text(i).font(PN.Font.caption).foregroundStyle(PN.C.text2) }
        if m.error != nil, m.errorField == nil { errorLine(m.error!) }
        resendRow
        HStack {
            Button(L("auth.code.back")) { m.restart() }.buttonStyle(.pnTertiary)
            Spacer()
            if m.busy { PNSpinner(size: 16) }
            Button(L("auth.reset.submit"), action: m.submitReset).buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction).disabled(m.locked)
        }
        .onAppear { focus = .code }
    }

    @ViewBuilder private var linkStep: some View {
        Text(L("auth.link.title")).pnTitle().fixedSize(horizontal: false, vertical: true)
        Text(L("auth.link.body", ["email": acct.pendingLink?.email ?? ""])).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
        passwordField(L("auth.password"), $m.linkPassword, .linkPassword)
        lockedLine
        if m.error != nil, m.errorField == nil { errorLine(m.error!) }
        HStack {
            Button(L("auth.cancel"), action: m.cancelLink).buttonStyle(.pnTertiary)
            Button(L("auth.forgot"), action: m.linkForgot).buttonStyle(.pnTertiary)
            Spacer()
            if m.busy { PNSpinner(size: 16) }
            Button(L("auth.link.submit"), action: m.submitLink).buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction).disabled(m.locked)
        }
        .onAppear { focus = .linkPassword }
    }

    // MARK: parts

    /// A label above the field and the error under it, with an icon (never colour alone).
    @ViewBuilder private func field<F: View>(_ label: String, _ f: SignInModel.Field, @ViewBuilder _ content: () -> F) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).pnSection()
            content().textFieldStyle(.roundedBorder).accessibilityLabel(label)
            if m.errorField == f, let e = m.error { errorLine(e) }
        }
    }

    @ViewBuilder private func passwordField(_ label: String, _ text: Binding<String>, _ f: SignInModel.Field) -> some View {
        field(label, f) {
            HStack(spacing: 6) {
                Group {
                    if m.showPassword { TextField("", text: text) } else { SecureField("", text: text) }
                }
                .textContentType(.password).focused($focus, equals: f)
                Button { m.showPassword.toggle() } label: { Image(systemName: m.showPassword ? "eye.slash" : "eye") }
                    .buttonStyle(.borderless)
                    .help(L(m.showPassword ? "auth.password.hide" : "auth.password.show"))
                    .accessibilityLabel(L(m.showPassword ? "auth.password.hide" : "auth.password.show"))
            }
        }
    }

    /// The one rule shown while typing, with a tick (not a colour).
    private func rule(_ p: String) -> some View {
        let ok = PacenoteServer.passwordProblem(p) == nil
        return Label(L("auth.password.rule"), systemImage: ok ? "checkmark.circle.fill" : "circle")
            .font(PN.Font.caption).foregroundStyle(ok ? PN.C.turn : PN.C.text3)
    }

    private var codeField: some View {
        field(L("auth.code.field"), .code) {
            TextField("1234 5678", text: Binding(get: { m.code }, set: { m.codeTyped($0) }))
                .font(PN.sys(22, .semibold, mono: true))
                .textContentType(.oneTimeCode).focused($focus, equals: .code)
                .onSubmit { if m.step == .code { m.verify() } }
        }
    }

    /// "Send again in 0:42" until the server allows a new code, then the button.
    private var resendRow: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = PacenoteServer.secondsLeft(until: m.resendAt, now: ctx.date)
            if left > 0 {
                Text(L("auth.code.resendIn", ["time": PacenoteServer.countdown(left)])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    .accessibilityHidden(true)
            } else {
                Button(L("auth.code.resend"), action: m.resend).buttonStyle(.pnTertiary)
            }
        }
    }

    /// "Too many attempts. Try again in 0:27." while the address waits; the buttons stay off till then.
    private var lockedLine: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = PacenoteServer.secondsLeft(until: m.lockedUntil, now: ctx.date)
            if left > 0 { errorLine(L("auth.err.locked", ["time": PacenoteServer.countdown(left)])) }
        }
    }

    private func errorLine(_ e: String) -> some View {
        Label { Text(e).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "exclamationmark.circle.fill") }
            .font(PN.Font.caption).foregroundStyle(PN.C.danger)
    }
}

/// The window that holds SignInView. Shown by AppDelegate.routeSignIn while there is no session.
@MainActor
final class SignInWindow {
    static var window: NSWindow?
    static let model = SignInModel()

    static var isVisible: Bool { window?.isVisible == true }

    static func show() {
        if window == nil {
            let host = NSHostingController(rootView: Localized { SignInView(m: model, quit: { NSApp.terminate(nil) }) })
            let w = NSWindow(contentViewController: host)
            w.tabbingMode = .disallowed
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            // the close button too: no password or code stays in memory behind a closed window
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { model.clearSecrets() }
            }
            window = w
        }
        window?.title = L("app.name")
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Signed in: the window goes and every field with it.
    static func close() {
        model.quiet = true
        model.restart()
        model.quiet = false
        window?.close()
    }
}
