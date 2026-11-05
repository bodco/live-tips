import AppKit
import LiveTipsCore
import SwiftUI

/// 0.9.3 (owner): the Gemini account through Antigravity CLI, for the preparation and after the call (rules/ai.yaml >
/// agy). Signed in when `agy models` answers with a model list; the list feeds the model pickers.
@MainActor
final class AgyAccount: ObservableObject {
    static let shared = AgyAccount()
    @Published var signedIn: Bool?
    @Published var checking = false
    @Published var models: [(id: String, name: String)] = []

    nonisolated static var cliPath: String? {
        AgyCLI.candidates(home: NSHomeDirectory(), path: ProcessInfo.processInfo.environment["PATH"] ?? "")
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func refresh() {
        guard !checking else { return }
        guard let cli = Self.cliPath else { signedIn = false; return }
        checking = true
        Task {
            let (status, text) = await Task.detached(priority: .utility) { () -> (Int32, String) in
                let process = Process(), out = Pipe()
                process.executableURL = URL(fileURLWithPath: cli)
                process.arguments = ["models"]
                process.currentDirectoryURL = FileManager.default.temporaryDirectory
                process.environment = AgyCLI.environment(ProcessInfo.processInfo.environment)
                process.standardOutput = out
                process.standardError = Pipe()
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                do {
                    try process.run()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timer)
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    timer.cancel()
                    return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
                } catch { timer.cancel(); return (-1, "") }
            }.value
            let list = AgyCLI.models(output: text)
            signedIn = status == 0 && !list.isEmpty
            if !list.isEmpty { models = list }
            checking = false
        }
    }

    func login() {
        guard let cli = Self.cliPath else { return }
        let command = AgyCLI.loginCommand(cli: cli)
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"Terminal\"\nactivate\ndo script \"" + escaped + "\"\nend tell"]
        try? process.run()
    }
}

struct AgyAccountRow: View {
    @ObservedObject private var account = AgyAccount.shared
    var body: some View {
        LabeledContent(L("ai.agy.account")) {
            HStack(spacing: 8) {
                if AgyAccount.cliPath == nil {
                    Text(L("ai.agy.missing")).foregroundStyle(PN.C.text3)
                    Link(L("ai.agy.install"), destination: URL(string: "https://antigravity.google/docs/cli/")!)
                } else {
                    Text(account.checking ? L("set.cc.checking") : account.signedIn == true ? L("ai.agy.connected") : L("ai.agy.notSignedIn"))
                        .foregroundStyle(PN.C.text3)
                    if account.signedIn != true { Button(L("set.logIn")) { account.login() } }
                    Button(L("set.check")) { account.refresh() }.disabled(account.checking)
                }
            }
        }
        .help(L("ai.agy.help"))
        .onAppear { account.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in account.refresh() }
    }
}

/// 0.9.3 (owner): shown in red under a job whose way is the Gemini account: Google's Antigravity terms forbid using the
/// service through third-party software (a breach may suspend the account) and allow Google to use and review the
/// conversations. The route stays available like the others; the PM decides with this in front of them.
struct AgyTermsWarning: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("ai.agy.warning")).font(PN.Font.caption).foregroundStyle(PN.C.danger)
                .fixedSize(horizontal: false, vertical: true)
            Link(L("ai.agy.terms"), destination: URL(string: "https://antigravity.google/terms")!)
                .font(PN.Font.caption).foregroundStyle(PN.C.danger)
        }
    }
}

/// 0.9.3: the account model of a job (prep or after), from `agy models` once signed in.
struct AgyModelPicker: View {
    @Binding var selection: String
    @ObservedObject private var account = AgyAccount.shared
    static let fallback: [(id: String, name: String)] = [
        ("gemini-3.8-flash-medium", "Gemini 3.8 Flash (Medium)"), ("gemini-3.8-flash-high", "Gemini 3.8 Flash (High)"),
        ("gemini-4-argon-medium", "Gemini 4 Argon (Medium)"), ("gemini-4-argon-high", "Gemini 4 Argon (High)"),
    ]
    var body: some View {
        let list = account.models.isEmpty ? Self.fallback : account.models
        VStack(alignment: .leading, spacing: 4) {
            Picker(L("set.model"), selection: $selection) {
                ForEach(list.indices, id: \.self) { i in
                    Text(list[i].name + (list[i].id == AgyCLI.defaultModel ? L("ai.route.recommended") : "")).tag(list[i].id)
                }
            }
            Text(L("ai.agy.model")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
        }
    }
}
