import AppKit
import LiveTipsCore
import SwiftUI

/// 0.24.1 (F1, decision 10): connecting a Claude, ChatGPT or Gemini account. The account's command line tool is
/// installed at that moment (Claude Code, Codex; never from the components list), then its sign-in runs as a child
/// process of the app: no Terminal. The browser opens for the sign-in (OAuth cannot do without it); if the tool asks
/// for a code, a field in the app writes it to the tool's input. After the tool exits the account is checked again
/// and, through F3 (AIDefaults), a connected account becomes the default AI.
@MainActor
final class AccountLogin: ObservableObject {
    static let shared = AccountLogin()

    enum Phase: Equatable { case idle, installing, waiting, needsCode, done, failed(String) }
    @Published var phase: [String: Phase] = [:]
    @Published var url: [String: String] = [:]
    private var input: [String: FileHandle] = [:]
    private var procs: [String: Process] = [:]

    func state(_ kind: String) -> Phase { phase[kind] ?? .idle }

    static func cli(_ kind: String) -> String? {
        switch kind {
        case "claude": return PrepRunner.claudePath
        case "codex": return CodexAccount.cliPath
        case "agy": return AgyAccount.cliPath
        default: return nil
        }
    }

    /// The setup.sh step that installs the tool; agy has none yet (no pinned official binary): "not installable".
    static func installStep(_ kind: String) -> String? { ["claude", "codex"].contains(kind) ? kind : nil }

    func connect(_ kind: String) {
        guard ![.installing, .waiting, .needsCode].contains(state(kind)) else { return }
        AppLog.app("account connect \(kind): start")
        Task {
            if Self.cli(kind) == nil, let step = Self.installStep(kind) {
                phase[kind] = .installing
                await SetupWindow.model.installOne(step)
            }
            guard let cli = Self.cli(kind) else {
                phase[kind] = .failed(L("acct.notInstalled"))
                AppLog.app("account connect \(kind): the tool is not installed")
                return
            }
            start(kind, cli: cli)
        }
    }

    private func start(_ kind: String, cli: String) {
        let p = Process(), out = Pipe(), inp = Pipe()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = CLILogin.arguments(kind)
        let base = ProcessInfo.processInfo.environment
        var env: [String: String]
        switch kind {
        case "codex": env = CodexCLI.environment(base)
        case "agy": env = AgyCLI.environment(base)
        default: env = base; env.removeValue(forKey: "ANTHROPIC_API_KEY"); env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
        }
        env["BROWSER"] = "open"          // the tools that read BROWSER open the default browser
        p.environment = env
        if kind == "agy" {               // agy asks to trust the folder it starts in: an empty temporary one
            let d = (NSTemporaryDirectory() as NSString).appendingPathComponent("pacenote-agy-\(UUID().uuidString.prefix(8))")
            try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
            p.currentDirectoryURL = URL(fileURLWithPath: d)
        }
        p.standardOutput = out; p.standardError = out; p.standardInput = inp
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            let lines = s.split(whereSeparator: \.isNewline).map(String.init)
            DispatchQueue.main.async { MainActor.assumeIsolated { lines.forEach { self?.handle(kind, $0) } } }
        }
        p.terminationHandler = { [weak self] proc in
            let rc = proc.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finished(kind, rc: rc) } }
        }
        do { try p.run() } catch {
            phase[kind] = .failed(L("acct.failed")); AppLog.app("account connect \(kind): did not start"); return
        }
        procs[kind] = p; input[kind] = inp.fileHandleForWriting
        phase[kind] = .waiting
    }

    private func handle(_ kind: String, _ line: String) {
        switch CLILogin.event(line) {
        case .url(let u):
            if url[kind] == nil, let link = URL(string: u) { NSWorkspace.shared.open(link) }   // most tools open it themselves; twice is harmless
            url[kind] = u
        case .askCode: phase[kind] = .needsCode
        case .failed(let m): AppLog.app("account connect \(kind): \(m)")
        default: break
        }
    }

    func submit(_ kind: String, code: String) {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty, let h = input[kind] else { return }
        h.write(Data((c + "\n").utf8))
        phase[kind] = .waiting
    }

    func cancel(_ kind: String) {
        procs[kind]?.terminate()
        phase[kind] = .idle
    }

    private func finished(_ kind: String, rc: Int32) {
        procs[kind] = nil; input[kind] = nil; url[kind] = nil
        AppLog.app("account connect \(kind): the tool exited rc=\(rc)")
        switch kind {
        case "codex": CodexAccount.shared.refresh()
        case "agy": AgyAccount.shared.refresh()
        default: PrepRunner.shared.refreshAuth()
        }
        phase[kind] = rc == 0 ? .done : .failed(L("acct.failed"))
        // F3: the account just connected becomes the default AI once its check says so
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated {
                AIRoute.autoAssign()
                AnalyticsTracker.shared.snapshotIfDue(force: true)
            }
        }
    }
}

/// The inline part of a Connect button: installing, waiting for the browser, the code field, a failure line.
struct AccountLoginStatus: View {
    let kind: String
    @ObservedObject var login = AccountLogin.shared
    @ObservedObject var setup = SetupWindow.model
    @State private var code = ""

    var body: some View {
        switch login.state(kind) {
        case .installing:
            VStack(alignment: .leading, spacing: 4) {
                Text(L("acct.installing", ["tool": L("setup.step.\(kind).title")])).font(PN.Font.caption).foregroundStyle(PN.C.text2)
                SetupLoader(model: setup, showButton: false, compact: true)
            }
        case .waiting:
            HStack(spacing: 8) {
                PNSpinner(size: 14)
                Text(L("acct.waiting")).font(PN.Font.caption).foregroundStyle(PN.C.text2)
                if let u = login.url[kind], let link = URL(string: u) { Link(L("acct.openAgain"), destination: link).font(PN.Font.caption) }
                Button(L("common.cancel")) { login.cancel(kind) }.buttonStyle(.pnTertiary)
            }
        case .needsCode:
            HStack(spacing: 8) {
                TextField(L("acct.code"), text: $code).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Button(L("common.continue")) { login.submit(kind, code: code); code = "" }.buttonStyle(.pnSecondary).disabled(code.isEmpty)
            }
        case .failed(let m):
            Text(m).font(PN.Font.caption).foregroundStyle(PN.C.danger)
        case .done, .idle:
            EmptyView()
        }
    }
}

/// One row per account: its state, one Connect button that installs the tool if needed and signs in from the app.
struct AccountConnectRow: View {
    let kind: String           // claude, codex, agy
    @ObservedObject var login = AccountLogin.shared
    @ObservedObject var prep = PrepRunner.shared
    @ObservedObject var codex = CodexAccount.shared
    @ObservedObject var agy = AgyAccount.shared

    var signedIn: Bool? {
        switch kind {
        case "codex": return CodexAccount.cliPath == nil ? false : codex.signedIn
        case "agy": return AgyAccount.cliPath == nil ? false : agy.signedIn
        default: return PrepRunner.claudePath == nil ? false : prep.loggedIn
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: signedIn == true ? "checkmark.circle.fill" : "person.crop.circle").foregroundStyle(signedIn == true ? PN.C.turn : PN.C.text3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("acct.\(kind).title")).font(PN.Font.body)
                    Text(signedIn == true ? L("acct.connected") : L("acct.\(kind).why")).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(2)
                }
                Spacer()
                if signedIn != true && [.idle, .done].contains(login.state(kind)) || isFailed {
                    Button(L("acct.connect")) { login.connect(kind) }.buttonStyle(.pnSecondary)
                        .disabled(kind == "agy" && AgyAccount.cliPath == nil)
                }
            }
            AccountLoginStatus(kind: kind)
            if kind == "agy" && AgyAccount.cliPath == nil {
                Text(L("acct.agy.notInstallable")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
        }
        .padding(10).background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.m))
        .onAppear {
            switch kind {
            case "codex": codex.refresh()
            case "agy": agy.refresh()
            default: prep.refreshAuth()
            }
        }
    }

    var isFailed: Bool { if case .failed = login.state(kind) { return true }; return false }
}
