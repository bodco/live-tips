import AppKit
import LiveTipsCore
import SwiftUI

/// First-run setup: installs what Live Tips needs next to the app (Python modules, the recorder
/// core, local models) and shows each step with a tick. Steps already in place are only checked.
@MainActor
final class SetupModel: ObservableObject {
    struct Step: Identifiable {
        let id: String
        var title: String { L("setup.step.\(id).title") }
        var why: String { L("setup.step.\(id).why") }
        let optional: Bool
        var state: State = .unknown
        var detail = ""
        enum State { case unknown, checking, ok, missing, installing, failed }
    }

    @Published var steps: [Step] = [
        Step(id: "python", optional: false),
        Step(id: "core", optional: false),
        Step(id: "venv", optional: false),
        Step(id: "recorder", optional: false),
        Step(id: "tips", optional: false),
        Step(id: "whisper", optional: false),
        Step(id: "localai", optional: false),
        Step(id: "voices", optional: false),
        // 2026-10-29 (owner): installed like the rest, but optional: recording works without it, preparing does not.
        Step(id: "claude", optional: true),
    ]
    @Published var log: [String] = []
    @Published var busy = false

    var config: AppConfig { AppConfig.load(from: AppPaths.config) }
    var appRoot: String { config.effectiveAppRoot(appSupport: AppPaths.support.path) }
    var script: String { Bundle.main.path(forResource: "setup", ofType: "sh") ?? "" }
    var allRequiredOK: Bool { steps.allSatisfy { $0.optional || $0.state == .ok } }

    func run(_ mode: String, _ step: String, onLine: @escaping (String) -> Void) async -> Int32 {
        let script = self.script, root = appRoot, res = Bundle.main.resourcePath ?? ""
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                p.arguments = [script, mode, step]
                var env = ProcessInfo.processInfo.environment
                env["APPROOT"] = root
                env["BUNDLE"] = res
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                p.environment = env
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                pipe.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData
                    guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
                    for line in s.split(whereSeparator: \.isNewline) where !line.isEmpty {
                        let l = String(line)
                        DispatchQueue.main.async { onLine(l) }
                    }
                }
                do { try p.run() } catch { cont.resume(returning: -1); return }
                p.waitUntilExit()
                pipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: p.terminationStatus)
            }
        }
    }

    func checkAll() async {
        for i in steps.indices {
            steps[i].state = .checking
            var out = ""
            _ = await run("check", steps[i].id) { out = $0 }
            steps[i].state = out.hasPrefix("OK") ? .ok : .missing
            steps[i].detail = String(out.split(separator: " ", maxSplits: 1).dropFirst().first ?? "")
        }
        if allRequiredOK { applyEngineSettings() }
    }

    /// One component on request (Claude Code is installed only when the PM presses Install).
    func installOne(_ id: String) async {
        guard let i = steps.firstIndex(where: { $0.id == id }), !busy else { return }
        busy = true
        defer { busy = false }
        steps[i].state = .installing
        log.append("> " + steps[i].title)
        _ = await run("install", id) { [weak self] l in self?.log.append(l) }
        var out = ""
        _ = await run("check", id) { out = $0 }
        steps[i].state = out.hasPrefix("OK") ? .ok : .failed
        steps[i].detail = String(out.split(separator: " ", maxSplits: 1).dropFirst().first ?? "")
    }

    func installMissing(includeOptional: Bool) async {
        busy = true
        defer { busy = false }
        for i in steps.indices where steps[i].state != .ok && (includeOptional || !steps[i].optional) {
            steps[i].state = .installing
            log.append("> " + steps[i].title)
            let rc = await run("install", steps[i].id) { [weak self] l in
                self?.log.append(l)
                if (self?.log.count ?? 0) > 400 { self?.log.removeFirst(100) }
            }
            var out = ""
            _ = await run("check", steps[i].id) { out = $0 }
            steps[i].state = out.hasPrefix("OK") ? .ok : .failed
            steps[i].detail = String(out.split(separator: " ", maxSplits: 1).dropFirst().first ?? "")
            if steps[i].state != .ok && !steps[i].optional {
                log.append(rc == 0 ? L("setup.log.notFinished") : L("setup.log.stopped"))
                return
            }
        }
        if allRequiredOK {
            applyEngineSettings()
            LocalAIService.shared.apply()
            log.append(L("setup.log.allSet"))
        }
    }

    /// Points the app at what setup installed, unless the PM set other engines on purpose.
    func applyEngineSettings() { Self.repairEnginePaths() }

    /// The engine paths follow the app (also at every launch: a renamed or moved app must not leave the tips engine
    /// pointing at a folder that is gone).
    static func repairEnginePaths() {
        var c = AppConfig.load(from: AppPaths.config)
        let root = c.effectiveAppRoot(appSupport: AppPaths.support.path)
        let fm = FileManager.default
        guard let e = c.engine.resolved(defaultPython: (root as NSString).appendingPathComponent(".venv/bin/python"),
                                        bundleEngine: ((Bundle.main.resourcePath ?? "") as NSString).appendingPathComponent("engine/spikes/m0"),
                                        exists: { fm.fileExists(atPath: $0) }) else { return }
        c.engine = e
        try? c.save(to: AppPaths.config)
    }
}

struct SetupView: View {
    @ObservedObject var model: SetupModel

    @State private var showLog = false

    // 2026-10-26 (owner): the welcome tour's look: header, one soft card, one big button.
    var body: some View {
        VStack(spacing: 14) {
            WindowHeader(symbol: "arrow.down.circle", title: L("setup.title"),
                         subtitle: L("setup.subtitle"))
            VStack(spacing: 0) {
                ForEach(model.steps) { s in
                    HStack(alignment: .top, spacing: 10) {
                        icon(s.state).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.title)
                            Text(s.why).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                            if s.id == "python" && (s.state == .missing || s.state == .failed) { PythonInstallHint() }   // 0.8.7 (L3.5)
                        }
                        Spacer()
                        Text(s.detail).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(1)
                    }
                    .padding(.vertical, 6)
                }
            }
            .ltCard()
            DisclosureGroup(L("home.week.details"), isExpanded: $showLog) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(model.log.enumerated()), id: \.offset) { i, l in
                                Text(l).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).id(i)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                    .frame(height: 110)
                    .background(RoundedRectangle(cornerRadius: LT.radius).fill(LT.cardFill))
                    .onChange(of: model.log.count) { proxy.scrollTo(model.log.count - 1) }
                }
            }
            .font(.callout).foregroundStyle(PN.C.text3)
            if !showLog, let last = model.log.last {
                Text(last).font(PN.Font.caption.monospaced()).foregroundStyle(PN.C.text3).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                LTPrimaryButton(title: model.allRequiredOK ? L("setup.allInstalled") : (model.busy ? L("setup.installing") : L("setup.installAll")),
                                symbol: model.allRequiredOK ? "checkmark" : (model.busy ? nil : "arrow.down")) {
                    Task { await model.installMissing(includeOptional: true) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.busy || model.allRequiredOK)
                Button(L("about.components.check")) { Task { await model.checkAll() } }.buttonStyle(.pnTertiary).foregroundStyle(PN.C.text3)
                    .disabled(model.busy)
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 22)
        .frame(width: 640, height: 640)
        .task { await model.checkAll() }
    }

    @ViewBuilder func icon(_ s: SetupModel.Step.State) -> some View {
        switch s {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(PN.C.turn)
        case .missing: Image(systemName: "circle").foregroundStyle(PN.C.text3)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(PN.C.danger)
        case .checking, .installing: ProgressView().controlSize(.small)
        case .unknown: Image(systemName: "circle.dotted").foregroundStyle(PN.C.text3)
        }
    }
}

/// 0.8.7 (L3.5): no Python on this Mac. One way out instead of a red line: the official python.org installer page and
/// what to click there; Check again after it is installed.
struct PythonInstallHint: View {
    static let url = URL(string: "https://www.python.org/downloads/macos/")!
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(L("setup.python.install")) { NSWorkspace.shared.open(Self.url) }
                .buttonStyle(.pnSecondary)
            Text(L("setup.python.how")).font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }
}

extension SetupModel {
    var pythonMissing: Bool { steps.first { $0.id == "python" }.map { $0.state == .missing || $0.state == .failed } ?? false }
}

@MainActor
final class SetupWindow {
    static var window: NSWindow?
    static let model = SetupModel()

    static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: Localized { SetupView(model: model) }))
            w.tabbingMode = .disallowed      // 0.8.7 (A1): never tabs
            w.title = L("setup.window.title")
            w.isReleasedWhenClosed = false
            window = w
        }
        window?.title = L("setup.window.title")
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}


/// 2026-10-29 (owner): how this copy of the app is signed. A beta signed by its developer but not notarized by Apple
/// opens only after "Open Anyway" (System Settings > Privacy & Security); onboarding and About say so.
@MainActor
final class AppSignature: ObservableObject {
    static let shared = AppSignature()
    enum Kind { case unknown, notarized, developer, unsigned }
    @Published var kind: Kind = .unknown

    func check() {
        let path = Bundle.main.bundlePath
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/spctl")
            p.arguments = ["--assess", "--type", "execute", "-vv", path]
            let o = Pipe(); p.standardOutput = o; p.standardError = o
            var text = ""
            if (try? p.run()) != nil { p.waitUntilExit(); text = String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "" }
            let k: Kind = text.contains("Notarized") ? .notarized : text.contains("no usable signature") || text.contains("not signed") ? .unsigned : .developer
            DispatchQueue.main.async { self.kind = k }
        }
    }
    var line: String {
        switch kind {
        case .notarized: return L("sign.notarized")
        case .developer: return L("sign.developer")
        case .unsigned: return L("sign.unsigned")
        case .unknown: return ""
        }
    }
}
