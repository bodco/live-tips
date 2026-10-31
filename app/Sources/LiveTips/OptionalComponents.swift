import AppKit
import LiveTipsCore
import SwiftUI

/// Pacenote 0.8.6 (E, rules/components.yaml): one pattern for optional components (Ollama, the local model, the Link
/// downloader). They never count against readiness, "Install or repair" never installs them, and nothing installs
/// during a live call.
@MainActor
final class OptionalComponents: ObservableObject {
    static let shared = OptionalComponents()
    enum State: Equatable { case unknown, installed(String), missing, installing(Double?), failed(String) }
    // 0.8.7 (L3.4, rules/components.yaml > names): `title` is the human name with the size; `tech` small and grey
    struct Comp: Identifiable { let id: String; let title: String; let tech: String; let purpose: String }

    @Published var states: [String: State] = [:]
    @Published var linkLog = ""
    private var linkTask: Task<Void, Never>?

    var all: [Comp] {
        [Comp(id: "ollama", title: L("comp.human.ollama"), tech: "", purpose: L("comp.for.ollama")),
         Comp(id: "local_model", title: L("comp.human.model"), tech: LocalLLM.model, purpose: L("comp.for.model")),
         Comp(id: "link_downloader", title: L("comp.human.link"), tech: "yt-dlp", purpose: L("comp.for.link"))]
    }

    var duringCall: Bool {
        let st = EngineStatus.load(path: CallEngine.shared.statusPath)
        return CallEngine.shared.isRunning || ["recording", "standby", "loading_model"].contains(st.state)
    }

    func state(_ id: String) -> State {
        let llm = LocalLLM.shared
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
        }
    }

    func install(_ id: String) {
        guard !duringCall else { return }
        switch id {
        case "ollama": LocalLLM.shared.start()                         // opens ollama.com/download when it is not on this Mac
        case "local_model": LocalLLM.shared.install(LocalLLM.model)
        default:
            states[id] = .installing(nil)
            linkTask = Task {
                var last = ""
                let rc = await SetupWindow.model.run("install", "linkdl") { last = $0 }
                states[id] = rc == 0 ? .installed("") : .failed(last.isEmpty ? L("comp.failed") : last)
                if rc == 0 { refresh() }
            }
        }
    }

    func cancel(_ id: String) {
        linkTask?.cancel(); linkTask = nil
        states[id] = .missing
    }
}

/// One component row: name, size, what it is for and its state with one action.
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
                switch st {
                case .installed(let v): Text(v.isEmpty ? L("comp.installed") : L("comp.installedV", ["v": v])).font(PN.Font.caption).foregroundStyle(PN.C.turn)
                case .missing, .unknown: Text(L("comp.notInstalled")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                case .installing(let p):
                    if let p = p { ProgressView(value: p).frame(maxWidth: 220) } else { ProgressView().controlSize(.small) }
                case .failed(let e): Text(e).font(PN.Font.caption).foregroundStyle(PN.C.danger).lineLimit(1)
                }
            }
            Spacer()
            switch st {
            case .installed: EmptyView()
            case .installing: if comp.id == "link_downloader" { Button(L("common.cancel")) { oc.cancel(comp.id) }.buttonStyle(.pnTertiary) }
            case .failed: Button(L("comp.retry")) { oc.install(comp.id) }.buttonStyle(.pnSecondary).disabled(oc.duringCall)
            default:
                Button(oc.duringCall ? L("comp.afterCall") : L("comp.install")) { oc.install(comp.id) }
                    .buttonStyle(.pnSecondary).disabled(oc.duringCall || (comp.id == "local_model" && !llm.installed))
            }
        }
        .onAppear { if case .unknown = oc.state(comp.id) { oc.refresh() } }
    }
}

/// A small "Install" link next to a control that needs a missing component (rules/components.yaml > dependants).
struct NeedsComponent: View {
    let id: String
    @ObservedObject var oc = OptionalComponents.shared
    var body: some View {
        if !oc.isInstalled(id) {
            HStack(spacing: 4) {
                Text(L("comp.needs", ["name": oc.all.first { $0.id == id }?.title ?? id])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                Button(oc.duringCall ? L("comp.afterCall") : L("comp.install")) { oc.install(id) }.buttonStyle(.pnTertiary).disabled(oc.duringCall)
            }
        }
    }
}

/// Onboarding (rules/components.yaml > onboarding): an optional step, nothing ticked, Install selected or Skip.
struct OptionalAddonsStep: View {
    @ObservedObject var oc = OptionalComponents.shared
    @State private var picked: Set<String> = []
    var showHeader = true
    var done: () -> Void
    var freeGB: Double {
        let v = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0
        return Double(v) / 1e9
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showHeader {
                Text(L("comp.onb.title")).font(.title3.weight(.semibold))
                Text(L("comp.onb.body")).foregroundStyle(PN.C.text3)
            }
            ForEach(oc.all) { c in
                Toggle(isOn: Binding(get: { picked.contains(c.id) }, set: { if $0 { picked.insert(c.id) } else { picked.remove(c.id) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.title)
                        if !c.tech.isEmpty { Text(c.tech).font(PN.Font.caption.monospaced()).foregroundStyle(PN.C.text3) }
                        Text(c.purpose).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                        if c.id == "local_model" && picked.contains(c.id) {
                            Text(L("comp.onb.space", ["free": String(format: "%.0f", freeGB)])).font(PN.Font.caption).foregroundStyle(freeGB < 25 ? PN.C.danger : PN.C.onMe)
                        }
                    }
                }
                .toggleStyle(.checkbox).disabled(oc.isInstalled(c.id))
            }
            HStack {
                Spacer()
                Button(L("comp.onb.skip")) { done() }.buttonStyle(.pnSecondary)
                Button(L("comp.onb.install")) {
                    for id in ["ollama", "link_downloader", "local_model"] where picked.contains(id) { oc.install(id) }
                    done()
                }
                .buttonStyle(.pnPrimary).disabled(picked.isEmpty || oc.duringCall)
            }
        }
        .onAppear { oc.refresh() }
    }
}
