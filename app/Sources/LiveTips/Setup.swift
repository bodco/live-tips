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

    /// 0.24.1 (F1, decisions 10 and 11): the base set, all of it installed by one Install (bge-m3 and voices too).
    @Published var steps: [Step] = SetupPlan.base.map { Step(id: $0, optional: false) }
    /// The command line tools of the accounts (Claude Code, Codex): not components, installed when an account is connected.
    @Published var tools: [Step] = SetupPlan.accountTools.map { Step(id: $0, optional: true) }
    @Published var log: [String] = []
    /// 0.26.3: a move of the app folder waits for the install and runs when it ends.
    @Published var busy = false { didSet { if oldValue && !busy && pinDepth == 0 { AppFolderMover.runPending() } } }
    /// 0.26.3: the app folder of the running installs and checks: every step goes to the same folder even when the
    /// work folder changes meanwhile (an install split between two folders left a Python without its packages). A
    /// check can overlap an install, so the pin counts its runs and the last one to end releases it.
    private var pinnedRoot: String?
    private var pinDepth = 0
    /// A move of the app folder waits while this is true.
    var holdsAppFolder: Bool { busy || pinDepth > 0 }
    private func pinRoot() {
        if pinDepth == 0 { pinnedRoot = config.effectiveAppRoot(appSupport: AppPaths.support.path) }
        pinDepth += 1
    }
    private func unpinRoot() {
        pinDepth = max(0, pinDepth - 1)
        guard pinDepth == 0 else { return }
        pinnedRoot = nil
        if !busy { AppFolderMover.runPending() }
    }
    // The one loader (0.24.1, F1): what runs, its fraction and bytes, the whole run's progress and time left.
    @Published var running: String?
    @Published var stepFraction = 0.0
    @Published var stepBytes: (done: Int64, total: Int64)?
    @Published var runSteps: [String] = []
    @Published var runDone: Set<String> = []
    @Published var runStarted: Date?

    var config: AppConfig { AppConfig.load(from: AppPaths.config) }
    var appRoot: String { pinnedRoot ?? config.effectiveAppRoot(appSupport: AppPaths.support.path) }
    var script: String { Bundle.main.path(forResource: "setup", ofType: "sh") ?? "" }
    var allRequiredOK: Bool { steps.allSatisfy { $0.optional || $0.state == .ok } }
    /// What a call cannot start without (decision 9).
    var callBlockingMissing: [String] { steps.filter { SetupPlan.callBlocking.contains($0.id) && $0.state != .ok }.map(\.id) }
    var checked: Bool { !steps.contains { $0.state == .unknown || $0.state == .checking } }

    var overall: Double {
        SetupPlan.overall(steps: runSteps, done: runDone, running: running, fraction: stepFraction)
    }
    var etaSeconds: TimeInterval? { runStarted.flatMap { SetupPlan.eta(fraction: overall, elapsed: Date().timeIntervalSince($0)) } }

    func step(_ id: String) -> Step? { steps.first { $0.id == id } ?? tools.first { $0.id == id } }
    func update(_ id: String, _ f: (inout Step) -> Void) {
        if let i = steps.firstIndex(where: { $0.id == id }) { f(&steps[i]) }
        else if let i = tools.firstIndex(where: { $0.id == id }) { f(&tools[i]) }
    }

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

    private func setState(_ id: String, from out: String) {
        update(id) {
            $0.state = out.hasPrefix("OK") ? .ok : .missing
            $0.detail = String(out.split(separator: " ", maxSplits: 1).dropFirst().first ?? "")
        }
    }

    func checkAll() async {
        pinRoot()
        defer { unpinRoot() }
        for id in steps.map(\.id) + tools.map(\.id) {
            update(id) { $0.state = .checking }
            var out = ""
            _ = await run("check", id) { out = $0 }
            setState(id, from: out)
        }
        if allRequiredOK { applyEngineSettings() }
        AppLog.app("components checked: " + steps.map { "\($0.id)=\($0.state == .ok ? "ok" : "missing")" }.joined(separator: " "))
    }

    /// One install step with its output in the window, in logs/setup.log, and the loader's numbers. Returns ok.
    @discardableResult
    private func install(_ id: String) async -> Bool {
        guard let title = step(id)?.title else { return false }
        update(id) { $0.state = .installing }
        running = id; stepFraction = 0; stepBytes = nil
        log.append("> " + title)
        AppLog.setup("> install \(id)")
        let t0 = Date()
        var lines: [String] = []
        let rc = await run("install", id) { [weak self] l in
            guard let self else { return }
            if let p = SetupPlan.parse(l) {
                self.stepFraction = p.fraction
                if let b = p.bytes, let t = p.total { self.stepBytes = (b, t) }
                return                                  // progress lines stay out of the log
            }
            self.log.append(l); lines.append(l)
            if self.log.count > 400 { self.log.removeFirst(100) }
            AppLog.setup("  " + l)
        }
        var out = ""
        _ = await run("check", id) { out = $0 }
        setState(id, from: out)
        let ok = out.hasPrefix("OK")
        if !ok { update(id) { $0.state = .failed } }
        let secs = Int(Date().timeIntervalSince(t0).rounded())
        let code = ok ? "" : SetupPlan.errorCode(step: id, log: lines)
        AppLog.setup("< \(id) rc=\(rc) \(ok ? "ok" : "failed " + code) \(secs)s check: \(out)")
        AppLog.app("install \(id): \(ok ? "ok" : "failed (\(code))") in \(secs) s")
        var props: [String: Any] = ["step": id, "ok": ok, "seconds": secs]
        if !ok { props["code"] = code }
        AnalyticsTracker.shared.track("install_component", props)
        runDone.insert(id); running = nil; stepFraction = 0; stepBytes = nil
        return ok
    }

    /// One component or account tool on request (the CLI of an account when it is connected).
    func installOne(_ id: String) async {
        guard step(id) != nil, !busy else { return }
        busy = true
        pinRoot()
        defer { unpinRoot(); busy = false; running = nil }
        runSteps = [id]; runDone = []; runStarted = Date()
        AppLog.header("setup.log", "install \(id)", extra: AppLog.runtimeExtra)
        await install(id)
        if allRequiredOK { applyEngineSettings() }
        AnalyticsTracker.shared.snapshotIfDue(force: true)
    }

    /// 0.24.1 (F1): installs every missing part of the base set. A failure no longer stops the run: the steps that need
    /// the failed one are marked with why, the others still install (the first outside user's install stopped at the
    /// tips engine and never reached Whisper).
    func installMissing(includeOptional: Bool = true) async {
        guard !busy else { return }
        busy = true
        pinRoot()
        defer { unpinRoot(); busy = false; running = nil }
        let todo = steps.filter { $0.state != .ok }.map(\.id)
        runSteps = todo; runDone = []; runStarted = Date()
        AppLog.header("setup.log", "install \(todo.joined(separator: ","))", extra: AppLog.runtimeExtra)
        var failed = Set<String>()
        for id in todo {
            if let b = SetupPlan.blockedBy(id, failed: failed) {
                let need = step(b)?.title ?? b
                update(id) { $0.state = .failed; $0.detail = L("setup.blocked", ["step": need]) }
                failed.insert(id); runDone.insert(id)
                log.append(L("setup.blocked", ["step": need]) + ": " + (step(id)?.title ?? id))
                AnalyticsTracker.shared.track("install_component", ["step": id, "ok": false, "seconds": 0, "code": "blocked"])
                continue
            }
            if !(await install(id)) { failed.insert(id) }
        }
        if allRequiredOK {
            applyEngineSettings()
            Self.healEnginePython()
            LocalAIService.shared.apply()
            log.append(L("setup.log.allSet"))
        } else if !failed.isEmpty {
            log.append(L("setup.log.someFailed", ["n": "\(failed.count)"]))
        }
        AnalyticsTracker.shared.snapshotIfDue(force: true)
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

    /// 0.26.3: the engine Python must import what the engine needs. A config left pointing at another Python (it
    /// exists, so `repairEnginePaths` keeps it) made the Meeting Sheet and the meeting notes fail with "No module named
    /// 'anthropic'" while Settings > Components said Installed. The interpreters run off the main thread; the config is
    /// read and saved on the main thread. `done(true)` when the engine was switched to setup's own Python.
    static func healEnginePython(done: (@MainActor (Bool) -> Void)? = nil) {
        let c0 = AppConfig.load(from: AppPaths.config)
        let venv = (c0.effectiveAppRoot(appSupport: AppPaths.support.path) as NSString).appendingPathComponent(".venv/bin/python")
        let engine = c0.engine
        DispatchQueue.global(qos: .utility).async {
            let healed = engine.healed(defaultPython: venv, works: Self.pythonWorks)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let h = healed, AppConfig.load(from: AppPaths.config).engine == engine else { done?(false); return }
                    Self.editConfig { $0.engine.python = h.python; $0.engine.sidecarPython = h.sidecarPython }
                    AppLog.app("engine python healed: the engine now runs setup's own Python")
                    done?(true)
                }
            }
        }
    }

    /// 0.26.3: one change of the config: through Settings when it is open (it saves the file and would otherwise
    /// write its older copy over this change), else in the file.
    static func editConfig(_ f: (inout AppConfig) -> Void) {
        if let m = SettingsModel.live { var c = m.config; f(&c); if c != m.config { m.config = c }; return }
        var c = AppConfig.load(from: AppPaths.config)
        f(&c)
        try? c.save(to: AppPaths.config)
    }

    /// True when `py` runs and finds the engine's modules (10 s at most).
    nonisolated static func pythonWorks(_ py: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: py) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: py)
        p.arguments = AppConfig.Engine.probeArgs
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        let deadline = Date().addingTimeInterval(10)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate(); return false }
        return p.terminationStatus == 0
    }

    /// 0.26.3: an engine error that means the Python cannot find a module.
    static func isModuleError(_ s: String) -> Bool {
        let l = s.lowercased()
        return l.contains("no module named") || l.contains("modulenotfounderror")
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
                        }
                        Spacer()
                        Text(s.detail).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(1)
                    }
                    .padding(.vertical, 6)
                }
            }
            .ltCard()
            SetupLoader(model: model, showButton: false)
            DisclosureGroup(L("home.week.details"), isExpanded: $showLog) {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(model.log.enumerated()), id: \.offset) { i, l in
                                Text(l).font(PN.sys(12, mono: true)).textSelection(.enabled).id(i)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                    .frame(height: 110)
                    .background(RoundedRectangle(cornerRadius: LT.radius).fill(LT.cardFill))
                    .onChange(of: model.log.count) { proxy.scrollTo(model.log.count - 1) }
                }
            }
            .font(PN.sys(.callout, 12)).foregroundStyle(PN.C.text3)
            if !showLog, let last = model.log.last {
                Text(last).font(PN.Font.caption.monospaced()).foregroundStyle(PN.C.text3).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            VStack(spacing: 8) {
                LTPrimaryButton(title: model.allRequiredOK ? L("setup.allInstalled") : (model.busy ? L("setup.installing") : L("setup.installAll")),
                                symbol: model.allRequiredOK ? "checkmark" : (model.busy ? nil : "arrow.down")) {
                    Task { await model.installMissing() }
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
        case .checking, .installing: PNSpinner(size: 16)
        case .unknown: Image(systemName: "circle.dotted").foregroundStyle(PN.C.text3)
        }
    }
}

/// 0.24.1 (F1, decision 3): one loader for the whole base set, wherever it is installed from (onboarding, the
/// Setup window, a call that cannot start yet): the part that is installing, MB of MB for downloads, percent of the
/// whole run and time left; what failed with its reason and one Retry. Never a browser or Terminal.
struct SetupLoader: View {
    @ObservedObject var model: SetupModel
    var showButton = true
    var compact = false

    var failed: [SetupModel.Step] { model.steps.filter { $0.state == .failed } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.busy {
                ProgressView(value: model.overall).tint(PN.C.brand)
                    .accessibilityLabel(L("setup.loader.a11y", ["pct": "\(Int(model.overall * 100))"]))
                HStack(spacing: 6) {
                    Text(nowLine).font(PN.Font.caption).foregroundStyle(PN.C.text2).lineLimit(1)
                    Spacer()
                    Text(rightLine).font(PN.Font.caption.monospacedDigit()).foregroundStyle(PN.C.text3).lineLimit(1)
                }
            } else if !failed.isEmpty {
                ForEach(failed) { s in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(PN.C.danger).accessibilityHidden(true)
                        Text(s.title + (s.detail.isEmpty ? "" : ": " + s.detail)).font(PN.Font.caption).foregroundStyle(PN.C.text2)
                            .lineLimit(compact ? 1 : 3).fixedSize(horizontal: false, vertical: !compact)
                    }
                }
                Button(L("setup.retry")) { Task { await model.installMissing() } }.buttonStyle(.pnSecondary)
            } else if showButton && model.checked && !model.allRequiredOK {
                Button(L("setup.installAll")) { Task { await model.installMissing() } }.buttonStyle(.pnPrimary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in if model.busy { model.objectWillChange.send() } }
    }

    var nowLine: String {
        guard let id = model.running, let s = model.step(id) else { return L("setup.installing") }
        let n = model.runSteps.firstIndex(of: id).map { $0 + 1 } ?? 1
        return L("setup.loader.now", ["step": s.title, "n": "\(n)", "total": "\(model.runSteps.count)"])
    }

    var rightLine: String {
        var parts: [String] = []
        if let b = model.stepBytes, b.total > 0 {
            parts.append(L("setup.loader.mb", ["done": "\(b.done / 1_000_000)", "total": "\(b.total / 1_000_000)"]))
        }
        parts.append("\(Int(model.overall * 100)) %")
        if let e = model.etaSeconds { parts.append(L("setup.loader.eta", ["t": SetupPlan.etaText(e)])) }
        return parts.joined(separator: " · ")
    }
}

/// 0.24.1 (F1): no Python on this Mac is no longer the PM's problem: Pacenote downloads its own (about 25 MB). The
/// python.org page and its steps are gone (decision 2: the PM never leaves the onboarding).
struct PythonInstallHint: View {
    @ObservedObject var setup = SetupWindow.model
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("setup.python.own")).font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
            Button(L("setup.installAll")) { Task { await setup.installMissing() } }.buttonStyle(.pnSecondary).disabled(setup.busy)
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
