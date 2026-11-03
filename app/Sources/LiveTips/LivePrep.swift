import AppKit
import LiveTipsCore

/// 0.9.0 (redesign phase 4, rules/live_prep.yaml): Prepare now / Prepare again during a call. The preparation runs
/// in the background like any other (PrepRunner, its own process, the way set for the Preparation job) with the
/// transcript up to this minute added to its sources. Recording, ASR and the tips loop never wait for it. When it is
/// ready, CallEngine.adoptLatePrep swaps the call's brief, cards and facts in one rename each (the brief before it
/// is kept as <stem>.brief.prev.md, one previous version), and the engine reloads them; a tip already being
/// written finishes on the old brief.
@MainActor
enum LivePrep {
    /// The Up next call being recorded, or one built from the running call's request.
    static func liveModel() -> StartCallModel? {
        let ce = CallEngine.shared
        guard ce.isRunning else { return nil }
        if let id = ce.currentCallID {
            if let m = UpNext.shared.items.first(where: { $0.id == id }) { return m }
            if let m = StartCallWindow.model, m.id == id { return m }
        }
        let st = EngineStatus.load(path: ce.statusPath)
        let m = StartCallModel()
        m.title = ce.renamed ?? (ce.callRequest["title"] as? String) ?? ""
        if let slug = st.slug, m.registry.projects.contains(where: { $0.slug == slug }) { m.target = "project:" + slug }
        else if let p = st.project, let w = m.registry.workspaces.first(where: { $0.name == p }) { m.target = "workspace:" + w.name }
        m.useDefaultTargetIfEmpty()
        if let id = ce.currentCallID { m.id = id } else { ce.currentCallID = m.id }
        return m
    }

    /// Starts the preparation; nil or the reason it cannot start.
    static func start() -> String? {
        guard let m = liveModel(), var r = m.prepRequest() else { return L("call.chooseProjectFirst") }
        let st = EngineStatus.load(path: CallEngine.shared.statusPath)
        if let f = st.file, FileManager.default.fileExists(atPath: f) {
            r.folders.append(f)
            r.context += (r.context.isEmpty ? "" : "\n\n") + L("liveprep.context", ["file": (f as NSString).lastPathComponent])
        }
        r.callID = m.id
        if PrepRunner.shared.running { return L("liveprep.busy") }
        return PrepRunner.shared.start(r)
    }

    static func cancel() { if PrepRunner.shared.running && PrepRunner.shared.joinsCurrentCall { PrepRunner.shared.cancel() } }
}
