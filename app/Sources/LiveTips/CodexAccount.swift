import AppKit
import LiveTipsCore
import SwiftUI

@MainActor
final class CodexAccount: ObservableObject {
    static let shared = CodexAccount()
    @Published var signedIn: Bool?
    @Published var checking = false

    nonisolated static var cliPath: String? {
        CodexCLI.candidates(home: NSHomeDirectory(), path: ProcessInfo.processInfo.environment["PATH"] ?? "")
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func refresh() {
        guard !checking else { return }
        guard let cli = Self.cliPath else { signedIn = false; return }
        checking = true
        Task {
            let ok = await Task.detached(priority: .utility) {
                let process = Process(), out = Pipe()
                process.executableURL = URL(fileURLWithPath: cli)
                process.arguments = ["-c", "forced_login_method=\"chatgpt\"", "login", "status"]
                process.environment = CodexCLI.environment(ProcessInfo.processInfo.environment)
                process.standardOutput = out
                process.standardError = out
                let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
                do {
                    try process.run()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: timer)
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    timer.cancel()
                    return CodexCLI.isChatGPT(status: process.terminationStatus, output: String(data: data, encoding: .utf8) ?? "")
                } catch { timer.cancel(); return false }
            }.value
            signedIn = ok
            checking = false
        }
    }

    func login() {
        guard let cli = Self.cliPath else { return }
        let command = CodexCLI.loginCommand(cli: cli)
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "tell application \"Terminal\"\nactivate\ndo script \"" + escaped + "\"\nend tell"]
        try? process.run()
    }
}

struct CodexAccountRow: View {
    @ObservedObject private var account = CodexAccount.shared
    var body: some View {
        LabeledContent(L("ai.codex.account")) {
            HStack(spacing: 8) {
                if CodexAccount.cliPath == nil {
                    Text(L("ai.codex.missing")).foregroundStyle(PN.C.text3)
                    Link(L("ai.codex.install"), destination: URL(string: "https://learn.chatgpt.com/docs/cli")!)
                } else {
                    Text(account.checking ? L("set.cc.checking") : account.signedIn == true ? L("ai.codex.connected") : L("ai.codex.notSignedIn"))
                        .foregroundStyle(PN.C.text3)
                    if account.signedIn != true { Button(L("set.logIn")) { account.login() } }
                    Button(L("set.check")) { account.refresh() }.disabled(account.checking)
                }
            }
        }
        .onAppear { account.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in account.refresh() }
    }
}
