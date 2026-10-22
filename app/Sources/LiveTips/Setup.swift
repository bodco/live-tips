import AppKit
import LiveTipsCore
import SwiftUI

/// First-run setup: installs what Live Tips needs next to the app (Python modules, the recorder
/// core, local models) and shows each step with a tick. Steps already in place are only checked.
@MainActor
final class SetupModel: ObservableObject {
    struct Step: Identifiable {
        let id: String
        let title: String
        let why: String
        let optional: Bool
        var state: State = .unknown
        var detail = ""
        enum State { case unknown, checking, ok, missing, installing, failed }
    }

    @Published var steps: [Step] = [
        Step(id: "python", title: "Python 3.10 or newer", why: "Runs the speech recognition and the tips engine on this Mac.", optional: false),
        Step(id: "core", title: "Recorder core", why: "Records your mic and the call audio, writes the transcript, runs the local fact cards.", optional: false),
        Step(id: "venv", title: "Private Python environment", why: "Keeps Live Tips' modules apart from anything else on this Mac.", optional: false),
        Step(id: "recorder", title: "Speech recognition (MLX Whisper)", why: "Turns speech into text on the Mac's GPU; audio never leaves the Mac.", optional: false),
        Step(id: "tips", title: "Tips engine modules", why: "Claude API client, rules reader, and ONNX Runtime for the local AI model.", optional: false),
        Step(id: "whisper", title: "Whisper model (about 1.6 GB)", why: "The speech model itself, downloaded once from Hugging Face.", optional: false),
        Step(id: "localai", title: "Local AI model bge-m3 (about 590 MB)", why: "Finds facts and project files by meaning, for HELP NOW and the fact cards.", optional: false),
        Step(id: "voices", title: "Speaker identification (optional)", why: "Tells the other side's voices apart (S1, S2…). Voice prints stay on this Mac.", optional: true),
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
                log.append(rc == 0 ? "Not finished: see the step above." : "Stopped: fix this step, then press Install again.")
                return
            }
        }
        if allRequiredOK {
            applyEngineSettings()
            LocalAIService.shared.apply()
            log.append("All set. Start a call from the menu bar icon.")
        }
    }

    /// Points the app at what setup installed, unless the PM set other engines on purpose.
    func applyEngineSettings() {
        var c = config
        let py = (appRoot as NSString).appendingPathComponent(".venv/bin/python")
        let engineDir = ((Bundle.main.resourcePath ?? "") as NSString).appendingPathComponent("engine/spikes/m0")
        var changed = false
        if c.engine.python.isEmpty || !FileManager.default.isExecutableFile(atPath: c.engine.python) { c.engine.python = py; changed = true }
        if c.engine.sidecarPython.isEmpty || !FileManager.default.isExecutableFile(atPath: c.engine.sidecarPython) { c.engine.sidecarPython = py; changed = true }
        if c.engine.sidecarDir.isEmpty || !FileManager.default.fileExists(atPath: c.engine.sidecarDir) { c.engine.sidecarDir = engineDir; changed = true }
        if changed { try? c.save(to: AppPaths.config) }
    }
}

struct SetupView: View {
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set up Live Tips").font(.title2.bold())
            Text("Live Tips runs speech recognition and a small AI model on this Mac. This installs what is missing into the app folder; nothing needs an administrator password. Steps with a green tick are already in place.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(model.steps) { s in
                    HStack(alignment: .top, spacing: 10) {
                        icon(s.state).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(s.title).font(.body.weight(.medium))
                                if !s.detail.isEmpty { Text(s.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                            }
                            Text(s.why).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    Divider()
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(model.log.enumerated()), id: \.offset) { i, l in
                            Text(l).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).id(i)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
                .frame(height: 110)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: model.log.count) { proxy.scrollTo(model.log.count - 1) }
            }
            HStack {
                Button("Check again") { Task { await model.checkAll() } }.disabled(model.busy)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button(model.allRequiredOK ? "Install speaker identification" : "Install missing") {
                    Task { await model.installMissing(includeOptional: model.allRequiredOK) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.busy || (model.allRequiredOK && model.steps.last?.state == .ok))
            }
        }
        .padding(20)
        .frame(width: 620)
        .task { await model.checkAll() }
    }

    @ViewBuilder func icon(_ s: SetupModel.Step.State) -> some View {
        switch s {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .missing: Image(systemName: "circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .checking, .installing: ProgressView().controlSize(.small)
        case .unknown: Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        }
    }
}

@MainActor
final class SetupWindow {
    static var window: NSWindow?
    static let model = SetupModel()

    static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SetupView(model: model)))
            w.title = "Live Tips Setup"
            w.isReleasedWhenClosed = false
            window = w
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
