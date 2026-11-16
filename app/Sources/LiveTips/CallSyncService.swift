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
        // 0.17.0 (B6b): joined or left an organization: a call of an organization left goes home (the server moved it)
        NotificationCenter.default.addObserver(forName: PacenoteAccount.orgsChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { CallSyncService.shared.sweep() }
        }
        // 0.17.0 (contract 9, block 2): colleagues' changes in the project registers come back every 10 minutes
        pullTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            MainActor.assumeIsolated { CallSyncService.shared.pull() }
        }
    }

    /// The calls of the last 30 days, once the account is signed in; then what colleagues changed.
    private func sweep() {
        sessionWait = nil
        let since = Date().addingTimeInterval(-30 * 86400)
        for r in CallHistory.shared.records where r.start > since && !r.hidden { sync(r.file) }
        pull()
    }

    // MARK: 0.17.0 (server 0.7.0, D40, contract 9 block 2): a colleague's change comes back

    private var pulling = false
    private var pullTimer: Timer?
    private var cursorsPath: URL { AppPaths.support.appendingPathComponent("server-sync-cursors.json") }

    /// Reads `/v1/sync` of every organization with organization projects, from where it stopped last time. My calls in
    /// it are read again and a colleague's newer status, owner or due date is taken (CallPullCore). The cursor moves on
    /// only when every call of the page was read, so a call missed for no network comes again next time.
    func pull() {
        guard !pulling, PacenoteAccount.shared.signedIn, !SheetShots.active else { return }
        pulling = true
        Task { await runPull(); pulling = false }
    }

    private func runPull() async {
        guard PacenoteAccount.shared.signedIn, let me = await PacenoteAccount.shared.meNow(), !me.userID.isEmpty else { return }
        let orgs = me.orgs.filter { $0.orgProjects }
        guard !orgs.isEmpty else { return }
        let email = PacenoteAccount.shared.session?.email ?? ""
        var cursors = ((try? Data(contentsOf: cursorsPath)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }) ?? [:]
        var byID: [String: String] = [:]            // the server's call id -> the transcript on this Mac
        for r in CallHistory.shared.records {
            guard let st = CallSync.State.load(CallSync.statePath(transcript: r.file)), !st.callID.isEmpty, !st.removed,
                  !st.deletedElsewhere else { continue }
            byID[st.callID.lowercased()] = r.file
        }
        var merged = 0
        for o in orgs {
            let key = email + "|" + o.id
            var cursor = cursors[key] ?? "", ok = true, ids: [String] = []
            for _ in 0..<20 {
                guard let r = try? await PacenoteAccount.shared.api("GET", CallSync.syncPath(orgID: o.id, cursor: cursor)),
                      r.1 == 200, let page = CallSync.syncPage(r.0) else { ok = false; break }
                ids += CallSync.toRead(page, me: me.userID, known: Set(byID.keys))
                cursor = page.cursor
                if !page.more { break }
            }
            guard ok else { continue }
            for id in Set(ids) {
                guard let t = byID[id] else { continue }
                switch await merge(t, orgID: o.id, me: me) {
                case .some(let n): merged += n
                case .none: ok = false
                }
            }
            if ok { cursors[key] = cursor }
        }
        if let d = try? JSONEncoder().encode(cursors) { try? d.write(to: cursorsPath, options: .atomic) }
        if merged > 0 { UsageLog.log("sync_pull", ["items": merged]) }
    }

    /// Reads one of my calls again and takes the newer items. Returns how many changed, nil to try again later.
    private func merge(_ t: String, orgID: String, me: PacenoteServer.Me) async -> Int? {
        guard !running.contains(t) else { return nil }
        let path = CallSync.statePath(transcript: t)
        guard CallSync.State.load(path)?.callID.isEmpty == false else { return 0 }
        running.insert(t)
        defer { running.remove(t) }
        do {
            guard var st = CallSync.State.load(path) else { return 0 }
            let (d, c) = try await PacenoteAccount.shared.api("GET", "/v1/calls/" + st.callID + CallSync.orgQuery(orgID))
            if c == 404 || c == 410 { return 0 }          // gone: the next PUT says so
            guard c == 200, let call = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
            var changes: [CallSync.ItemChange] = []
            for part in ["decisions", "tasks", "risks"] {
                changes += CallSync.newer(CallSync.remoteItems(call, part: part), part: part, state: st)
            }
            guard !changes.isEmpty else { return 0 }
            let cfg = AppConfig.load(from: AppPaths.config)
            let names = [me.name] + cfg.nameAliases
            let tasks = changes.filter { $0.part == "tasks" }
            if !tasks.isEmpty { applyTasks(tasks, transcript: t, me: me.userID, myNames: names, alias: cfg.nameAliases.first ?? "") }
            CallSync.adopt(changes, me: me.userID, myNames: names, state: &st)
            st.save(path)
            return changes.count
        } catch {
            return nil
        }
    }

    /// A colleague's task change lands in the commitments register (op done, drop, reopen, edit; source "server").
    /// A call whose tasks still come from its notes takes them into the register first.
    private func applyTasks(_ changes: [CallSync.ItemChange], transcript t: String, me: String, myNames: [String], alias: String) {
        let folder = (t as NSString).deletingLastPathComponent
        let at = CommitmentRegister.nowISO()
        func items() -> [Commitment] {
            CommitmentRegister.load(folder: folder).filter { CommitmentRegister.callKey($0.call) == CommitmentRegister.callKey(t) }
        }
        let lists = CallLists.read(transcript: t)
        var reg = items()
        if reg.isEmpty {
            let title = CallHistory.shared.records.first { $0.file == t }?.title ?? ((CallSync.stem(t) as NSString).lastPathComponent)
            CommitmentRegister.append(folder: folder, CommitmentRegister.adoptAllEvents(
                lists.tasks, project: PyTool.project(of: t).project?.slug ?? "", title: title, call: t, them: L("callEdit.them"), at: at))
            reg = items()
        }
        let keys = CallSync.taskKeys(CallSync.tasks(register: reg, lists: lists, me: alias))
        let byID = Dictionary(reg.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var events: [[String: Any]] = []
        for ch in changes {
            guard let cid = keys[ch.key], let c = byID[cid] else { continue }
            events += CallSync.taskEvents(c, server: ch.item, me: me, myNames: myNames, at: at)
        }
        CommitmentRegister.append(folder: folder, events)
        Register.shared.touch(folder)
    }

    private func remember(meta: [String: String], transcript t: String) {
        let p = CallSync.statePath(transcript: t)
        var st = CallSync.State.load(p) ?? CallSync.State()
        st.meta.merge(meta) { _, new in new }
        // 0.17.0 (B6b, D36): the call's organization is where new calls go when it ends (or where its project is
        // linked), and stays so; a project's "private by default" marks it private when the organization allows that
        if let me = PacenoteAccount.shared.me, st.orgID.isEmpty, st.callID.isEmpty {
            let proj = PyTool.project(of: t).project
            st.orgID = PacenoteServer.orgForCall(stored: "", onServer: false, linkedOrg: proj?.homeOrg ?? "", me: me)
            if proj?.privateByDefault == true, PacenoteServer.privateAllowed(me.org(st.orgID), alreadyPrivate: false) { st.isPrivate = true }
        }
        guard !meta.isEmpty || !st.orgID.isEmpty else { return }
        st.save(p)
    }

    /// 0.17.0 (B6b): the organization of a call as the Mac knows it ("" for a call that never went to the server:
    /// it is in the personal space).
    func orgID(of t: String) -> String { CallSync.State.load(CallSync.statePath(transcript: t))?.orgID ?? "" }

    /// 0.17.0 (D36): the call's private mark and what the organization allows (the call page's switch).
    func privacy(_ t: String) -> (isPrivate: Bool, allowed: Bool, org: PacenoteServer.Org?) {
        let st = CallSync.State.load(CallSync.statePath(transcript: t)) ?? CallSync.State()
        let me = PacenoteAccount.shared.me
        let proj = PyTool.project(of: t).project
        let oid = PacenoteServer.orgForCall(stored: st.orgID, onServer: !st.callID.isEmpty, linkedOrg: proj?.homeOrg ?? "", me: me)
        let org = me?.org(oid)
        return (st.isPrivate, PacenoteServer.privateAllowed(org, alreadyPrivate: st.serverPrivate), org)
    }

    func setPrivate(_ on: Bool, transcript t: String) {
        let p = CallSync.statePath(transcript: t)
        var st = CallSync.State.load(p) ?? CallSync.State()
        st.isPrivate = on
        if !on, st.error.lowercased().contains("private") { st.error = "" }
        st.save(p)
        sync(t)
    }

    /// The project of a call when it may go to the server now.
    func project(for t: String) -> Project? {
        guard PacenoteAccount.shared.signedIn, let p = PyTool.project(of: t).project, p.serverSync,
              !SampleProject.blocksSync(p) else { return nil }          // 0.17.0 (5.1): an untouched sample stays local
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
            let me = await PacenoteAccount.shared.meNow()
            let home = me?.org(st.orgID)?.isPersonal ?? true
            let (d, c) = try await PacenoteAccount.shared.api("DELETE", "/v1/calls/" + st.callID + CallSync.orgQuery(home ? "" : st.orgID))
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
            // 0.17.0 (B6b, D36): the call's organization and privacy
            let me = await PacenoteAccount.shared.meNow()
            st.orgID = PacenoteServer.orgForCall(stored: st.orgID, onServer: !st.callID.isEmpty, linkedOrg: p.homeOrg, me: me)
            let org = me?.org(st.orgID)
            let bodyOrg = (org?.isPersonal ?? true) ? "" : st.orgID       // the personal one: the server's default, as before
            if st.isPrivate && !PacenoteServer.privateAllowed(org, alreadyPrivate: st.serverPrivate) {
                st.error = L("sync.private.off", ["org": org?.name ?? ""]); return      // never sent visible by itself
            }
            let pid = try await projectID(p, orgID: bodyOrg, personal: bodyOrg.isEmpty)
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
                                                       consent: CallSync.consent(CallConsent.read(transcript: t)), analysis: analysis,
                                                       orgID: bodyOrg, isPrivate: st.isPrivate))
            if st.callID.isEmpty || st.hashes["call"] != CallSync.hash(call) {
                let (d, c) = try await PacenoteAccount.shared.api("PUT", "/v1/calls/" + st.clientCallID, body: call)
                switch CallSync.outcome(status: c, problem: Self.problemText(d, c)) {
                case .ok:
                    let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
                    st.callID = o["id"] as? String ?? st.callID
                    st.version = o["version"] as? String ?? st.version
                    st.hashes["call"] = CallSync.hash(call)
                    st.serverPrivate = st.isPrivate
                case .deletedElsewhere:
                    st.deletedElsewhere = true; st.error = ""; return
                case .stop(let e), .retryLater(let e):
                    if CallSync.privateRefused(status: c, problem: e) {
                        st.error = L("sync.private.off", ["org": org?.name ?? ""]); return
                    }
                    // 0.17.0: the call is in another organization on the server (left one, it went home): try home
                    if c == 409, e.contains("another organization"), let home = me?.personal?.id, st.orgID != home {
                        st.orgID = home; st.hashes = [:]; st.items = [:]; st.error = ""; return
                    }
                    // the server no longer knows the project (server data deleted, another account): register again
                    if c == 422 { forgetProject(p, orgID: bodyOrg) }
                    st.error = e; return
                }
            }
            guard !st.callID.isEmpty else { return }
            let notes = try? String(contentsOfFile: CallNotes.path(t), encoding: .utf8)
            var parts: [(String, Data)] = []
            // 0.17.0 (server 0.7.0, D40): decisions, tasks and risks go with stable ids and the last rev
            var itemRows: [String: [[String: Any]]] = [:]
            func items(_ name: String, _ rows: [[String: Any]]) {
                let r = CallSync.withIDs(rows, part: name, state: st)
                itemRows[name] = r
                parts.append((name, CallSync.json(CallSync.stripKeys(r))))
            }
            if let s = CallSync.summaryBody(notes: notes) { parts.append(("summary", CallSync.json(s))) }
            // 0.12.2 (L2): decisions by the one rule (the PM's edit, notes, live picture, older notes); sent also when the
            // PM removed them all, so the server copy follows. Tasks still from the notes until L4.
            let lists = CallLists.read(transcript: t)
            if lists.decisionsFrom != .none || st.hashes["decisions"] != nil {
                items("decisions", CallSync.decisions(lists))
            }
            // 0.12.2 (L4): tasks from the commitments register (status, owner, due), else by the one rule
            let reg = CommitmentRegister.load(folder: (t as NSString).deletingLastPathComponent)
                .filter { CommitmentRegister.callKey($0.call) == CommitmentRegister.callKey(t) }
            let tasks = CallSync.tasks(register: reg, lists: lists, me: AppConfig.load(from: AppPaths.config).nameAliases.first ?? "")
            if !tasks.isEmpty || st.hashes["tasks"] != nil { items("tasks", tasks) }
            // 0.12.2 (L3): risks by the same rule, also when the PM removed them all
            if lists.risksFrom != .none || st.hashes["risks"] != nil {
                items("risks", CallSync.risks(lists))
            }
            if let s = CallSync.sheetBody(FileManager.default.contents(atPath: CallSync.sheetPath(transcript: t))) {
                parts.append(("sheet", CallSync.json(s)))
            }
            let assets = CallSync.assets(recording: RecordingMeta.load(RecordingFiles.metaPath(transcript: t)),
                                         transcript: DriveTranscriptMeta.load(DriveTranscript.metaPath(transcript: t)))
            if !assets.isEmpty || st.hashes["assets"] != nil { parts.append(("assets", CallSync.json(assets))) }
            for (name, body) in CallSync.changed(parts, state: st) {
                let rows = itemRows[name]
                let send = rows.map { CallSync.json(CallSync.withRevs($0, part: name, state: st)) } ?? body
                let (d, c) = try await PacenoteAccount.shared.api("PUT", "/v1/calls/\(st.callID)/\(name)" + CallSync.orgQuery(bodyOrg), body: send)
                if CallSync.partMissing(name, status: c) { continue }   // server before 0.4.0
                switch CallSync.outcome(status: c, problem: Self.problemText(d, c)) {
                case .ok:
                    st.hashes[name] = CallSync.hash(body)
                    if let rows { CallSync.rememberItems(rows, part: name, response: d, state: &st) }
                case .deletedElsewhere: st.deletedElsewhere = true; return
                case .stop(let e), .retryLater(let e):
                    // 404: the server copy is gone (server data deleted, signed in with another account): send it anew
                    if c == 404 { st.callID = ""; st.version = ""; st.hashes = [:]; st.items = [:] }
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

    /// 0.17.0 (B6b contract 3, Bohdan 16.11): moves a project with its calls on the server to another organization
    /// (POST /v1/projects/{id}/move for its copy in every other organization; the target merges a project with the same
    /// local slug). The calls on this Mac follow, so their next sync goes there; private calls stay private on the
    /// server. Returns the error to show, nil when done. The project's new calls go there too (Project.orgID; a link to
    /// an organization project of another organization is dropped).
    func move(_ p: Project, to target: String) async -> (Project, String?) {
        var q = p
        guard let me = await PacenoteAccount.shared.meNow(), me.org(target) != nil else { return (q, L("proj.org.move.err", ["code": "404"])) }
        let slug = CallSync.localSlug(p.slug)
        do {
            for o in me.orgs where o.id != target {
                let (d, c) = try await PacenoteAccount.shared.api("GET", "/v1/projects" + CallSync.orgQuery(o.id))
                guard c == 200 else { continue }
                let rows = ((try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]]) ?? []
                for r in rows where (r["local_slug"] as? String) == slug {
                    guard let id = r["id"] as? String else { continue }
                    let (md, mc) = try await PacenoteAccount.shared.api("POST", "/v1/projects/\(id)/move", body: CallSync.json(["org_id": target]))
                    guard mc == 200 else { return (q, L("proj.org.move.err", ["code": "\(mc)"]) + " " + Self.problemText(md, mc)) }
                }
                forgetProject(p, orgID: o.isPersonal ? "" : o.id)
            }
        } catch { return (q, error.localizedDescription) }
        // the Mac follows: the project's calls on the server now belong to the target
        for r in CallHistory.shared.records where ((r.file as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent == p.root {
            let path = CallSync.statePath(transcript: r.file)
            guard var st = CallSync.State.load(path), !st.callID.isEmpty || !st.orgID.isEmpty else { continue }
            st.orgID = target; st.error = ""
            st.save(path)
        }
        q.orgID = target
        if q.linkedToOrgProject && q.orgProjectOrg != target { q.orgProjectID = ""; q.orgProjectOrg = ""; q.orgProjectName = "" }
        return (q, nil)
    }

    /// After a move: send the project's calls again (each only when its body changed, as always).
    func resync(root: String) {
        for r in CallHistory.shared.records where ((r.file as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent == root && !r.hidden {
            sync(r.file)
        }
    }

    /// The server's reason in words; a full storage quota (402) says so with the plan's limit.
    private static func problemText(_ d: Data, _ c: Int) -> String {
        if let q = PacenoteServer.quota(d, status: c), q.name == "storage_mb" { return L("sync.quota.storage", ["limit": "\(q.limit)"]) }
        return PacenoteServer.problem(d, status: c)
    }

    private func forgetProject(_ p: Project, orgID: String) {
        let email = PacenoteAccount.shared.session?.email ?? "", slug = CallSync.localSlug(p.slug)
        let prefix = CallSync.projectKey(email: email, orgID: orgID, personal: orgID.isEmpty, slug: slug, link: "")
        for k in projectIDs.keys where k == prefix || k.hasPrefix(prefix + "|") { projectIDs[k] = nil }
        if let data = try? JSONEncoder().encode(projectIDs) { try? data.write(to: projectsPath, options: .atomic) }
    }

    /// The server id of a project: registered once per account, organization and link (POST /v1/projects is keyed by
    /// the organization and the local slug, a repeat changes nothing). 0.17.0 (D38): in a team organization the link
    /// to an organization project is always sent (the Mac is the source of truth); in the personal one never.
    private func projectID(_ p: Project, orgID: String, personal: Bool) async throws -> String {
        let slug = CallSync.localSlug(p.slug)
        let link: String? = personal ? nil : (p.linkedToOrgProject && p.orgProjectOrg == orgID ? p.orgProjectID : "")
        let key = CallSync.projectKey(email: PacenoteAccount.shared.session?.email ?? "", orgID: orgID, personal: personal, slug: slug,
                                      link: link ?? "")
        if let id = projectIDs[key] { return id }
        let body = CallSync.json(CallSync.projectBody(name: p.name, slug: slug, orgID: orgID, orgProjectID: link))
        let (d, c) = try await PacenoteAccount.shared.api("POST", "/v1/projects", body: body)
        guard c == 200 || c == 201, let id = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])?["id"] as? String else {
            throw PacenoteAccountError.server(c, Self.problemText(d, c))
        }
        projectIDs[key] = id
        if let data = try? JSONEncoder().encode(projectIDs) { try? data.write(to: projectsPath, options: .atomic) }
        return id
    }
}
