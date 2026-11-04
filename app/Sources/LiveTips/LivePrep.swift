import AppKit
import LiveTipsCore

/// 0.9.0 (redesign phase 4, rules/live_prep.yaml): Prepare now / Prepare again during a call. The preparation runs
/// in the background like any other (PrepRunner, its own process, the way set for the Preparation job) with the
/// transcript up to this minute added to its sources. Recording, ASR and the tips loop never wait for it. When it is
/// ready, CallEngine.adoptLatePrep swaps the call's brief, cards and facts in one rename each (the brief before it
/// is kept as <stem>.brief.prev.md, one previous version), and the engine reloads them; responses still being generated from the old context are discarded.
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
        m.context = ce.callContext
        m.callType = (ce.callRequest["call_type"] as? String) ?? m.callType
        m.audience = (ce.callRequest["audience"] as? String) ?? m.audience
        m.hiringRole = (ce.callRequest["hiring_role"] as? String) ?? m.hiringRole
        m.language = (ce.callRequest["langs"] as? [String])?.first ?? m.language
        m.useDefaultTargetIfEmpty()
        if let id = ce.currentCallID { m.id = id } else { ce.currentCallID = m.id }
        return m
    }

    /// Starts the preparation; nil or the reason it cannot start.
    static func start(correction: String = "") -> String? {
        guard let m = liveModel(), var r = m.prepRequest() else { return L("call.chooseProjectFirst") }
        let st = EngineStatus.load(path: CallEngine.shared.statusPath)
        if let f = st.file, FileManager.default.fileExists(atPath: f) {
            r.folders.append(f)
            r.context += (r.context.isEmpty ? "" : "\n\n") + L("liveprep.context", ["file": (f as NSString).lastPathComponent])
        }
        let correction = correction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !correction.isEmpty {
            r.context = "Latest explicit correction from the PM for THIS call (overrides conflicting earlier prep):\n" + correction + "\n\nEarlier context:\n" + r.context
        }
        r.callID = m.id
        if !correction.isEmpty {
            // the newest correction replaces an older one in the call context (no pile of contradicting lines)
            let marker = "Latest correction for this call: "
            let rest = m.context.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix(marker) }.joined(separator: "\n")
            m.context = marker + correction + (rest.isEmpty ? "" : "\n" + rest)
            CallEngine.shared.callContext = m.context
            CallEngine.shared.callRequest["context"] = m.context
        }
        if PrepRunner.shared.running { return L("liveprep.busy") }
        let error = PrepRunner.shared.start(r)
        pendingCorrection = error == nil && !correction.isEmpty ? m.id : nil
        return error
    }

    /// The call whose correction is waiting for its new prep (restore the agenda if that prep does not land).
    static var pendingCorrection: UUID?

    /// PrepRunner finished a preparation: after a correction, a failed or cancelled one brings the old agenda back.
    static func prepFinished(id: UUID?, ok: Bool) {
        guard let p = pendingCorrection, p == id else { return }
        pendingCorrection = nil
        if !ok, let inbox = EngineStatus.load(path: CallEngine.shared.statusPath).inboxFile, let h = FileHandle(forWritingAtPath: inbox) {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            h.seekToEndOfFile(); h.write(Data(("{\"t\": \"" + f.string(from: Date()) + "\", \"kind\": \"context_restore_agenda\"}\n").utf8)); try? h.close()
        }
    }

    static func cancel() { if PrepRunner.shared.running && PrepRunner.shared.joinsCurrentCall { PrepRunner.shared.cancel() } }
}
