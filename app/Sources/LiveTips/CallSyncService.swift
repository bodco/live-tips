import Foundation
import LiveTipsCore

/// 0.12.0 (B8b, server ADR 9): sends a call's notes, decisions, tasks, Meeting Sheet and Drive links to the Pacenote
/// server, for projects with "Sync to Pacenote server" on (off by default) and only while signed in. A call goes
/// after it ends (once the notes are likely written), when its page opens, and at launch for the last 30 days; each
/// time only the parts that changed. No network or a server error just waits for the next time. A call deleted on
/// another device (410) is marked and never sent again by itself. Rules and payloads: LiveTipsCore/CallSyncCore.swift.
@MainActor
final class CallSyncService {
    static let shared = CallSyncService()

    private var running: Set<String> = []
    private var started = false
    private var projectIDs: [String: String] = [:]          // "<account email>|<local slug>" -> server project id
    private var projectsPath: URL { AppPaths.support.appendingPathComponent("server-projects.json") }

    private init() {
        if let d = try? Data(contentsOf: projectsPath), let m = try? JSONDecoder().decode([String: String].self, from: d) { projectIDs = m }
    }

    /// This Mac's part of every client call id (stable, not the hardware id).
    static var deviceKey: String {
        let k = "pacenoteSyncDevice"
        if let v = UserDefaults.standard.string(forKey: k), !v.isEmpty { return v }
        let v = String(UUID().uuidString.lowercased().prefix(8))
        UserDefaults.standard.set(v, forKey: k)
        return v
    }

    func start() {
        guard !started, !SheetShots.active else { return }
        started = true
        NotificationCenter.default.addObserver(forName: CallEngine.callEnded, object: nil, queue: .main) { n in
            let file = n.userInfo?["file"] as? String ?? ""
            guard !file.isEmpty else { return }
            var meta: [String: String] = [:]
            for k in ["call_type", "audience", "language"] { if let v = n.userInfo?[k] as? String, !v.isEmpty { meta[k] = v } }
            MainActor.assumeIsolated { CallSyncService.shared.remember(meta: meta, transcript: file) }
            // the notes are written in the background after the call; the call page and the next launch send later changes
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { MainActor.assumeIsolated { CallSyncService.shared.sync(file) } }
        }
        let since = Date().addingTimeInterval(-30 * 86400)
        for r in CallHistory.shared.records where r.start > since && !r.hidden { sync(r.file) }
    }

    private func remember(meta: [String: String], transcript t: String) {
        guard !meta.isEmpty else { return }
        let p = CallSync.statePath(transcript: t)
        var st = CallSync.State.load(p) ?? CallSync.State()
        st.meta.merge(meta) { _, new in new }
        st.save(p)
    }

    /// The project of a call when it may go to the server now.
    func project(for t: String) -> Project? {
        guard PacenoteAccount.shared.signedIn, let p = PyTool.project(of: t).project, p.serverSync else { return nil }
        return p
    }

    /// Don't sync this call (or allow it again).
    func setSkip(_ skip: Bool, transcript t: String) {
        let p = CallSync.statePath(transcript: t)
        var st = CallSync.State.load(p) ?? CallSync.State()
        st.skip = skip
        st.save(p)
        if !skip { sync(t) }
    }

    func sync(_ t: String) {
        guard !running.contains(t), FileManager.default.fileExists(atPath: t), let p = project(for: t) else { return }
        running.insert(t)
        Task { await run(t, project: p); running.remove(t) }
    }

    private func run(_ t: String, project p: Project) async {
        let path = CallSync.statePath(transcript: t)
        var st = CallSync.State.load(path) ?? CallSync.State()
        guard !st.skip, !st.deletedElsewhere else { return }
        if st.clientCallID.isEmpty { st.clientCallID = CallSync.clientCallID(device: Self.deviceKey, transcript: t) }
        defer { st.save(path) }
        do {
            let pid = try await projectID(p)
            let rec = CallHistory.shared.records.first { $0.file == t }
            let start = rec?.start ?? CallHistory.startFromName(t) ?? Date()
            let dur = rec?.minutes.map { Int($0 * 60) } ?? rec?.end.map { Int($0.timeIntervalSince(start)) } ?? 0
            let title = (rec?.title).flatMap { $0.isEmpty ? nil : $0 } ?? ((CallSync.stem(t) as NSString).lastPathComponent)
            let call = CallSync.json(CallSync.callBody(projectID: pid, title: title, start: start, durationS: dur, meta: st.meta,
                                                       appVersion: PacenoteAccount.appVersion))
            if st.callID.isEmpty || st.hashes["call"] != CallSync.hash(call) {
                let (d, c) = try await PacenoteAccount.shared.api("PUT", "/v1/calls/" + st.clientCallID, body: call)
                switch CallSync.outcome(status: c, problem: PacenoteServer.problem(d, status: c)) {
                case .ok:
                    let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
                    st.callID = o["id"] as? String ?? st.callID
                    st.version = o["version"] as? String ?? st.version
                    st.hashes["call"] = CallSync.hash(call)
                case .deletedElsewhere:
                    st.deletedElsewhere = true; st.error = ""; return
                case .stop(let e), .retryLater(let e):
                    // the server no longer knows the project (server data deleted, another account): register again
                    if c == 422 { forgetProject(p) }
                    st.error = e; return
                }
            }
            guard !st.callID.isEmpty else { return }
            let notes = try? String(contentsOfFile: CallNotes.path(t), encoding: .utf8)
            let parsed = notes.flatMap { MeetingNotes.parse($0) }
            var parts: [(String, Data)] = []
            if let s = CallSync.summaryBody(notes: notes) { parts.append(("summary", CallSync.json(s))) }
            if parsed != nil {
                parts.append(("decisions", CallSync.json(CallSync.decisions(parsed))))
                parts.append(("tasks", CallSync.json(CallSync.tasks(parsed))))
            }
            if let s = CallSync.sheetBody(FileManager.default.contents(atPath: CallSync.sheetPath(transcript: t))) {
                parts.append(("sheet", CallSync.json(s)))
            }
            let assets = CallSync.assets(recording: RecordingMeta.load(RecordingFiles.metaPath(transcript: t)),
                                         transcript: DriveTranscriptMeta.load(DriveTranscript.metaPath(transcript: t)))
            if !assets.isEmpty || st.hashes["assets"] != nil { parts.append(("assets", CallSync.json(assets))) }
            for (name, body) in CallSync.changed(parts, state: st) {
                let (d, c) = try await PacenoteAccount.shared.api("PUT", "/v1/calls/\(st.callID)/\(name)", body: body)
                switch CallSync.outcome(status: c, problem: PacenoteServer.problem(d, status: c)) {
                case .ok: st.hashes[name] = CallSync.hash(body)
                case .deletedElsewhere: st.deletedElsewhere = true; return
                case .stop(let e), .retryLater(let e):
                    // 404: the server copy is gone (server data deleted, signed in with another account): send it anew
                    if c == 404 { st.callID = ""; st.version = ""; st.hashes = [:] }
                    st.error = e; return
                }
            }
            st.error = ""
            st.syncedAt = Date()
        } catch PacenoteAccountError.notSignedIn {
            st.error = ""
        } catch {
            st.error = error.localizedDescription
        }
    }

    private func forgetProject(_ p: Project) {
        projectIDs[(PacenoteAccount.shared.session?.email ?? "") + "|" + CallSync.localSlug(p.slug)] = nil
        if let data = try? JSONEncoder().encode(projectIDs) { try? data.write(to: projectsPath, options: .atomic) }
    }

    /// The server id of a project: registered once per account (POST /v1/projects is keyed by the local slug).
    private func projectID(_ p: Project) async throws -> String {
        let slug = CallSync.localSlug(p.slug)
        let key = (PacenoteAccount.shared.session?.email ?? "") + "|" + slug
        if let id = projectIDs[key] { return id }
        let body = CallSync.json(["name": String(p.name.prefix(200)), "local_slug": slug])
        let (d, c) = try await PacenoteAccount.shared.api("POST", "/v1/projects", body: body)
        guard c == 200 || c == 201, let id = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["id"] as? String else {
            throw PacenoteAccountError.server(c, PacenoteServer.problem(d, status: c))
        }
        projectIDs[key] = id
        if let data = try? JSONEncoder().encode(projectIDs) { try? data.write(to: projectsPath, options: .atomic) }
        return id
    }
}
