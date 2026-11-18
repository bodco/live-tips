import AppKit
import LiveTipsCore
import SwiftUI

/// Pacenote 0.8.6 (E, rules/components.yaml): one pattern for optional components. They never count against
/// readiness, "Install or repair" never installs them, and nothing installs or is removed during a live call.
/// 0.16.0 (D3): three rows (the local AI model in Ollama, the call agent, the link downloader), each measured on
/// disk and removable from Settings > Components (ComponentCatalog in LiveTipsCore says what can go and what follows).
@MainActor
final class OptionalComponents: ObservableObject {
    static let shared = OptionalComponents()
    enum State: Equatable { case unknown, installed(String), missing, installing(Double?), removing, failed(String) }
    // 0.8.7 (L3.4): `title` is the human name; `tech` small and grey; `purpose` what it is for
    struct Comp: Identifiable { let id: String; let title: String; let tech: String; let purpose: String }

    @Published var states: [String: State] = [:]
    /// Measured sizes on disk in bytes (setup.sh size, the Ollama manifest); missing = not measured yet.
    @Published var sizes: [String: Int64] = [:]
    /// After a removal: what went and how much it freed (Settings > Components shows it with Install again).
    @Published var removed: (id: String, bytes: Int64)?
    private var linkTask: Task<Void, Never>?

    var all: [Comp] {
        [Comp(id: "local_model", title: L("comp.name.model"), tech: L("comp.tech.model", ["model": LocalLLM.suggestedLabel]), purpose: L("comp.for.model2")),
         // 0.9.6 (owner): the call agent (Claude Agent SDK with its own Claude Code, ~320 MB, Python 3.10+)
         Comp(id: "agent", title: L("comp.name.agent"), tech: "claude-agent-sdk", purpose: L("comp.for.agent2")),
         Comp(id: "link_downloader", title: L("comp.name.link"), tech: "yt-dlp", purpose: L("comp.for.link"))]
    }

    func title(_ id: String) -> String { id == "ollama" ? L("comp.human.ollama") : all.first { $0.id == id }?.title ?? id }

    var duringCall: Bool {
        let st = EngineStatus.load(path: CallEngine.shared.statusPath)
        return CallEngine.shared.isRunning || ["recording", "standby", "loading_model"].contains(st.state)
    }

    func state(_ id: String) -> State {
        let llm = LocalLLM.shared
        if let s = states[id], s == .removing { return s }
        switch id {
        case "ollama": return llm.installed ? .installed(llm.running ? L("comp.running") : "") : .missing
        case "local_model":
            if llm.pulling != nil { return .installing(llm.progress) }
            if llm.models.contains(LocalLLM.model) { return .installed(LocalLLM.model) }
            return LocalLLM.onDisk(LocalLLM.model) ? .installed(llm.running ? LocalLLM.model : L("comp.startToUse")) : .missing
        default: return states[id] ?? .unknown
        }
    }

    func isInstalled(_ id: String) -> Bool { if case .installed = state(id) { return true }; return false }

    func refresh() {
        LocalLLM.shared.refresh()
        Task {
            var out = ""
            let rc = await SetupWindow.model.run("check", "linkdl") { out += $0 }
            states["link_downloader"] = rc == 0 && out.hasPrefix("OK") ? .installed(String(out.dropFirst(3)).trimmingCharacters(in: .whitespaces)) : .missing
            var ag = ""
            let rc2 = await SetupWindow.model.run("check", "agent") { ag += $0 }
            states["agent"] = rc2 == 0 && ag.hasPrefix("OK") ? .installed(String(ag.dropFirst(3)).trimmingCharacters(in: .whitespaces)) : .missing
        }
    }

    func install(_ id: String) {
        guard !duringCall else { return }
        if removed?.id == id { removed = nil }
        switch id {
        case "ollama": LocalLLM.shared.start()                         // opens ollama.com/download when it is not on this Mac
        case "local_model":
            // v2 (D3): one row. Without Ollama on this Mac Install opens its download page first; then the model downloads.
            if LocalLLM.shared.installed { LocalLLM.shared.install(LocalLLM.model) } else { LocalLLM.shared.start() }
        default:
            states[id] = .installing(nil)
            linkTask = Task {
                var last = ""
                let rc = await SetupWindow.model.run("install", id == "agent" ? "agent" : "linkdl") { last = $0 }
                states[id] = rc == 0 ? .installed("") : .failed(last.isEmpty ? L("comp.failed") : last)
                if rc == 0 { refresh(); await measure(id) }
            }
        }
    }

    func cancel(_ id: String) {
        linkTask?.cancel(); linkTask = nil
        states[id] = .missing
    }

    // MARK: 0.16.0 (D3): sizes and removal

    /// The size of one part on disk: setup.sh `size <step>` for required parts and the Python add-ons, the Ollama
    /// manifest for the model. nil when it could not be measured.
    func size(_ id: String) async -> Int64? {
        if id == "local_model" { return LocalLLM.sizeOnDisk(LocalLLM.model) }
        guard let step = ComponentCatalog.setupStep(id) else { return nil }
        var out: Int64?
        _ = await SetupWindow.model.run("size", step) { if let v = ComponentCatalog.parseSize($0) { out = v } }
        return out
    }

    /// A size of 0 (the folder is not there) counts as not measured, so the estimate shows instead of "0 MB".
    func measure(_ id: String) async { if let v = await size(id), v > 0 { sizes[id] = v } else { sizes[id] = nil } }

    /// Measures every part, required and optional (Settings > Components, onboarding step 5).
    func measureAll() async {
        for id in ComponentCatalog.required + ComponentCatalog.optional { await measure(id) }
    }

    /// Removes an optional part and returns what it freed (measured before minus after). Never a required part,
    /// never during a call. After the model goes, every job set to "On this Mac" moves to the next AI in the chain
    /// and the chain's local step is switched off.
    @discardableResult
    func remove(_ id: String) async -> Int64? {
        guard ComponentCatalog.canRemove(id), !duringCall, isInstalled(id) else { return nil }
        let before = await size(id) ?? sizes[id]
        states[id] = .removing
        var ok = false
        if id == "local_model" {
            ok = await LocalLLM.shared.remove(LocalLLM.model)
        } else if let step = ComponentCatalog.setupStep(id) {
            let rc = await SetupWindow.model.run("remove", step) { _ in }
            ok = rc == 0
        }
        states[id] = nil
        if id == "local_model" {
            LocalLLM.shared.refresh()
            if ok { moveJobsOffLocal() }
        } else {
            refresh()
        }
        guard ok else { states[id] = .failed(L("comp.removeFailed")); return nil }
        let after = await size(id)
        let freed = ComponentCatalog.freed(before: before, after: after)
        sizes[id] = after
        removed = (id, freed)
        UsageLog.log("component_removed", ["id": id, "freed_mb": Int(freed / 1_000_000)])
        return freed
    }

    private func moveJobsOffLocal() {
        let s = SettingsWindow.model
        var connected = AIRoute.connected(); connected.remove(AIRoute.local)
        let r = ComponentCatalog.afterRemovingLocal(prep: s.config.ai.prep, tips: s.config.ai.tips, after: s.config.ai.after,
                                                    chain: s.config.ai.chain, connected: connected)
        s.config.ai.prep = r.prep; s.config.ai.tips = r.tips; s.config.ai.after = r.after
        s.config.ai.chain = r.chain; s.config.ai.localFallback = false
    }
}

/// One component row: name, what it is for and its state with one action (Settings > AI and General).
struct ComponentRow: View {
    let comp: OptionalComponents.Comp
    var markOptional = false
    @ObservedObject var oc = OptionalComponents.shared
    @ObservedObject var llm = LocalLLM.shared

    var body: some View {
        let st = oc.state(comp.id)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: { if case .installed = st { return "checkmark.circle.fill" }; return "circle.dashed" }())
                .foregroundStyle({ if case .installed = st { return PN.C.turn }; return PN.C.text3 }())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(comp.title + (markOptional ? " " + L("comp.optionalMark") : ""))
                if !comp.tech.isEmpty { Text(comp.tech).font(PN.Font.caption.monospaced()).foregroundStyle(PN.C.text3) }
                Text(comp.purpose).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                ComponentStateLine(id: comp.id)
            }
            Spacer()
            ComponentAction(id: comp.id)
        }
        .onAppear { if case .unknown = oc.state(comp.id) { oc.refresh() } }
    }
}

/// The state under a component's name.
struct ComponentStateLine: View {
    let id: String
    @ObservedObject var oc = OptionalComponents.shared
    @ObservedObject var llm = LocalLLM.shared
    var body: some View {
        switch oc.state(id) {
        case .installed(let v): Text(v.isEmpty ? L("comp.installed") : L("comp.installedV", ["v": v])).font(PN.Font.caption).foregroundStyle(PN.C.turn)
        case .missing, .unknown:
            Text(id == "local_model" && !llm.installed ? L("comp.needsOllama") : L("comp.notInstalled")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
        case .installing(let p):
            if let p = p { ProgressView(value: p).frame(maxWidth: 220) } else { PNSpinner(size: 16) }
        case .removing: Text(L("comp.removing")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
        case .failed(let e): Text(e).font(PN.Font.caption).foregroundStyle(PN.C.danger).lineLimit(1)
        }
    }
}

/// Install, Cancel or Retry for a component that is not installed (installed parts are removed in Settings > Components).
struct ComponentAction: View {
    let id: String
    @ObservedObject var oc = OptionalComponents.shared
    @ObservedObject var llm = LocalLLM.shared
    var body: some View {
        switch oc.state(id) {
        case .installed, .removing: EmptyView()
        case .installing: if ["link_downloader", "agent"].contains(id) { Button(L("common.cancel")) { oc.cancel(id) }.buttonStyle(.pnTertiary) }
        case .failed: Button(L("comp.retry")) { oc.install(id) }.buttonStyle(.pnSecondary).disabled(oc.duringCall)
        default:
            Button(oc.duringCall ? L("comp.afterCall") : (id == "local_model" && !llm.installed ? L("comp.getOllama") : L("comp.install"))) { oc.install(id) }
                .buttonStyle(.pnSecondary).disabled(oc.duringCall)
        }
    }
}

/// A small "Install" link next to a control that needs a missing component (rules/components.yaml > dependants).
struct NeedsComponent: View {
    let id: String
    @ObservedObject var oc = OptionalComponents.shared
    var body: some View {
        if !oc.isInstalled(id) {
            HStack(spacing: 4) {
                Text(L("comp.needs", ["name": oc.title(id)])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                Button(oc.duringCall ? L("comp.afterCall") : L("comp.install")) { oc.install(id) }.buttonStyle(.pnTertiary).disabled(oc.duringCall)
            }
        }
    }
}
