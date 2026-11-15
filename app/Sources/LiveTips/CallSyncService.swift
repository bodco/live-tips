import Combine
import Foundation
import LiveTipsCore

/// 0.12.0 (B8b, server ADR 9): sends a call's notes, decisions, tasks, Meeting Sheet and Drive links to the Pacenote
/// server, for projects with "Sync to Pacenote server" on (off by default) and only while signed in. A call goes
/// after it ends (once the notes are likely written), when its page opens, and at launch for the last 30 days; each
/// time only the parts that changed. No network or a server error just waits for the next time. A call deleted on
/// another device (410) is marked and never sent again by itself. Rules and payloads: LiveTipsCore/CallSyncCore.swift.
@MainActor
final class CallSyncService: ObservableObject {
    static let shared = CallSyncService()

    @Published private(set) var running: Set<String> = []      // 0.12.1: the call page shows "Syncing"
    private var started = false
    private var sessionWait: AnyCancellable?             // 0.13.1: the launch sweep waits for the saved session
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
        // 0.13.1: the account reads its saved session from the Keychain in the background, so right after launch it is
        // not signed in yet and the sweep skipped every call. Sweep once the session is there (now or when it loads).
        sessionWait = PacenoteAccount.shared.$session.compactMap { $0 }.first().receive(on: DispatchQueue.main).sink { _ in
            MainActor.assumeIsolated { CallSyncService.shared.sweep() }
        }
    }

    /// The calls of the last 30 days, once the account is signed in.
    private func sweep() {
        sessionWait = nil
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

    /// 0.12.1 (B8): the call page's sync line; nil when the call's project does not sync (or signed out). A call
    /// deleted from the server keeps its line while signed in, even after its project stops syncing.
    func status(_ t: String) -> CallSync.Status? {
        let st = CallSync.State.load(CallSync.statePath(transcript: t))
        guard project(for: t) != nil || (PacenoteAccount.shared.signedIn && st?.removed == true) else { return nil }
        return CallSync.status(st, syncing: running.contains(t))
    }

    /// 0.12.1 (B8): "Delete from server" is offered while signed in and the server has a copy (also when the project
    /// stopped syncing since).
    func canDelete(_ t: String) -> Bool {
        PacenoteAccount.shared.signedIn && CallSync.canDelete(CallSync.State.load(CallSync.statePath(transcript: t)))
    }

    /// 0.12.1 (B8): removes the server's copy of one call (DELETE /v1/calls/{id}); the files on this Mac stay. The call
    /// is never sent again by itself. Returns the error to show, nil when done.
    func deleteFromServer(_ t: String) async -> String? {
        let path = CallSync.statePath(transcript: t)
        guard let st = CallSync.State.load(path), CallSync.canDelete(st), !running.contains(t) else { return nil }
        running.insert(t)
        defer { running.remove(t) }
        do {
            let (d, c) = try await PacenoteAccount.shared.api("DELETE", "/v1/calls/" + st.callID)
            let (next, err) = CallSync.afterDelete(st, status: c, problem: Self.problemText(d, c))
            next.save(path)
            return err
        } catch {
            return error.localizedDescription
        }
    }

    private func run(_ t: String, project p: Project) async {
        let path = CallSync.statePath(transcript: t)
        var st = CallSync.State.load(path) ?? CallSync.State()
        guard !st.skip, !st.deletedElsewhere, !st.removed else { return }
        if st.clientCallID.isEmpty { st.clientCallID = CallSync.clientCallID(device: Self.deviceKey, transcript: t) }
        defer { st.save(path) }
        do {
            let pid = try await projectID(p)
            let rec = CallHistory.shared.records.first { $0.file == t }
            let start = rec?.start ?? CallHistory.startFromName(t) ?? Date()
            let dur = rec?.minutes.map { Int($0 * 60) } ?? rec?.end.map { Int($0.timeIntervalSince(start)) } ?? 0
            let title = (rec?.title).flatMap { $0.isEmpty ? nil : $0 } ?? ((CallSync.stem(t) as NSString).lastPathComponent)
            // 0.13.0 (B8 part 2): the consent record and the call's numbers (never a text)
            let tipsText = CallLists.tipsPaths(transcript: t).compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }.joined(separator: "\n")
            let analysis = CallSync.analysis(tips: tipsText,
                                             inbox: (try? String(contentsOfFile: CallSync.inboxPath(transcript: t), encoding: .utf8)) ?? "",
                                             talkShare: CallMetrics.shared.of(t).talkShare,
                                             sheetCheck: FileManager.default.contents(atPath: CallSync.sheetCheckPath(transcript: t)))
            let call = CallSync.json(CallSync.callBody(projectID: pid, title: title, start: start, durationS: dur, meta: st.meta,
                                                       appVersion: PacenoteAccount.appVersion,
                                                       consent: CallSync.consent(CallConsent.read(transcript: t)), analysis: analysis))
            if st.callID.isEmpty || st.hashes["call"] != CallSync.hash(call) {
                let (d, c) = try await PacenoteAccount.shared.api("PUT", "/v1/calls/" + st.clientCallID, body: call)
                switch CallSync.outcome(status: c, problem: Self.problemText(d, c)) {
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
            var parts: [(String, Data)] = []
            if let s = CallSync.summaryBody(notes: notes) { parts.append(("summary", CallSync.json(s))) }
            // 0.12.2 (L2): decisions by the one rule (the PM's edit, notes, live picture, older notes); sent also when the
            // PM removed them all, so the server copy follows. Tasks still from the notes until L4.
            let lists = CallLists.read(transcript: t)
            if lists.decisionsFrom != .none || st.hashes["decisions"] != nil {
                parts.append(("decisions", CallSync.json(CallSync.decisions(lists))))
            }
            // 0.12.2 (L4): tasks from the commitments register (status, owner, due), else by the one rule
            let reg = CommitmentRegister.load(folder: (t as NSString).deletingLastPathComponent)
                .filter { CommitmentRegister.callKey($0.call) == CommitmentRegister.callKey(t) }
            let tasks = CallSync.tasks(register: reg, lists: lists, me: AppConfig.load(from: AppPaths.config).nameAliases.first ?? "")
            if !tasks.isEmpty || st.hashes["tasks"] != nil { parts.append(("tasks", CallSync.json(tasks))) }
            // 0.12.2 (L3): risks by the same rule, also when the PM removed them all
            if lists.risksFrom != .none || st.hashes["risks"] != nil {
                parts.append(("risks", CallSync.json(CallSync.risks(lists))))
            }
            if let s = CallSync.sheetBody(FileManager.default.contents(atPath: CallSync.sheetPath(transcript: t))) {
                parts.append(("sheet", CallSync.json(s)))
            }
            let assets = CallSync.assets(recording: RecordingMeta.load(RecordingFiles.metaPath(transcript: t)),
                                         transcript: DriveTranscriptMeta.load(DriveTranscript.metaPath(transcript: t)))
            if !assets.isEmpty || st.hashes["assets"] != nil { parts.append(("assets", CallSync.json(assets))) }
            for (name, body) in CallSync.changed(parts, state: st) {
                let (d, c) = try await PacenoteAccount.shared.api("PUT", "/v1/calls/\(st.callID)/\(name)", body: body)
                if CallSync.partMissing(name, status: c) { continue }   // server before 0.4.0
                switch CallSync.outcome(status: c, problem: Self.problemText(d, c)) {
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

    /// The server's reason in words; a full storage quota (402) says so with the plan's limit.
    private static func problemText(_ d: Data, _ c: Int) -> String {
        if let q = PacenoteServer.quota(d, status: c), q.name == "storage_mb" { return L("sync.quota.storage", ["limit": "\(q.limit)"]) }
        return PacenoteServer.problem(d, status: c)
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
            throw PacenoteAccountError.server(c, Self.problemText(d, c))
        }
        projectIDs[key] = id
        if let data = try? JSONEncoder().encode(projectIDs) { try? data.write(to: projectsPath, options: .atomic) }
        return id
    }
}
