import AppKit
import LiveTipsCore

/// 0.9.5 (owner): a call recording copied to the PM's own Google Drive, for sharing. The original stays on this Mac.
/// drive.file only: Pacenote sees nothing in Drive but the files and folders it made (My Drive > Pacenote > <project>).
/// Resumable upload in 8 MB pieces: a dropped connection goes on from the last piece Google confirmed. The queue
/// survives a restart (UserDefaults "recUploadQueue", transcript paths) and starts again at launch.
///
/// 0.11.0 (B7b, server ADR 3.3, 3.4, 3.7): the folder ids are kept per Google account (DriveFolderStore,
/// drive-folders.json), so the PM can move the Pacenote folder in Drive (to a shared drive, or share it with a lead)
/// and Pacenote goes on writing by the id. A new "Pacenote" is made only when no id is saved; a saved folder that is
/// gone (404, trash, no access) stops the upload with "Folder not available" and Create a new folder; no network keeps
/// the id and the queue. Every Drive request passes supportsAllDrives=true. Optionally the call's transcript goes to
/// the same folder as "<date> <title>.md" and is updated in place (the same file id) when it changes.
@MainActor
final class DriveRecordings: ObservableObject {
    static let shared = DriveRecordings()
    /// transcript path -> "12 of 340 MB" while it uploads
    @Published private(set) var progress: [String: String] = [:]
    @Published private(set) var errors: [String: String] = [:]
    /// For Settings: the root folder of each account as Drive last answered ("" not checked yet).
    @Published private(set) var rootState: [String: DriveFolderState] = [:]
    @Published private(set) var store: DriveFolderStore
    private var running = Set<String>()
    private var transcriptRunning = Set<String>()
    private let chunk = 8 * 1024 * 1024
    private let queueKey = "recUploadQueue"
    private var started = false

    private static var storePath: String { AppPaths.support.appendingPathComponent("drive-folders.json").path }

    private init() {
        var s = DriveFolderStore.load(Self.storePath) ?? DriveFolderStore()
        if !SheetShots.active && !UserDefaults.standard.bool(forKey: "driveFoldersMigrated") {
            let all = UserDefaults.standard.dictionaryRepresentation()
            var old: [String: String] = [:]
            for (k, v) in all where k.hasPrefix("driveFolder|") { if let id = v as? String { old[k] = id } }
            s = DriveFolderStore.migrated(s, defaults: old)
            s.save(Self.storePath)
            UserDefaults.standard.set(true, forKey: "driveFoldersMigrated")   // the old keys stay, for a downgrade
        }
        store = s
    }

    var accounts: [GoogleAccount] {
        if let a = RecordingSettingsPane.shotAccounts { return a }
        return GoogleService.shared.accounts.filter { $0.has(GoogleScopes.export) }
    }

    /// The account Settings name, else the first one that allows the export.
    var account: String? {
        let want = AppConfig.load(from: AppPaths.config).recording.driveAccount
        return accounts.first { $0.email == want }?.email ?? accounts.first?.email
    }

    /// Transcript in Drive as it applies now: an organization that requires it turns it on for every call.
    var transcriptMode: TranscriptInDrive {
        if PacenoteAccount.shared.me?.transcriptRequiredBy != nil { return .everyCall }
        return TranscriptInDrive(rawValue: AppConfig.load(from: AppPaths.config).recording.transcriptDrive) ?? .off
    }

    func isUploading(_ transcript: String) -> Bool { running.contains(transcript) }

    /// At launch (MenuBar, 20 s after start): the waiting uploads, the call-ended hook, transcripts that changed.
    func resumeQueue() {
        if !started {
            started = true
            NotificationCenter.default.addObserver(forName: CallEngine.callEnded, object: nil, queue: .main) { n in
                let file = n.userInfo?["file"] as? String ?? ""
                guard !file.isEmpty else { return }
                // The recorder writes <stem>.named.md (speaker names) a few seconds after the call ends.
                DispatchQueue.main.asyncAfter(deadline: .now() + 40) {
                    MainActor.assumeIsolated { DriveRecordings.shared.callEnded(file) }
                }
            }
        }
        for t in UserDefaults.standard.stringArray(forKey: queueKey) ?? [] { upload(transcript: t, auto: true) }
        let since = Date().addingTimeInterval(-30 * 86400)
        for r in CallHistory.shared.records where r.start > since && FileManager.default.fileExists(atPath: DriveTranscript.metaPath(transcript: r.file)) {
            syncTranscript(r.file, create: false)
        }
    }

    /// Transcript in Drive "For every call": also a call without a recording (one with a recording that goes to Drive
    /// automatically gets it with the upload).
    private func callEnded(_ file: String) {
        guard transcriptMode == .everyCall, FileManager.default.fileExists(atPath: file) else { return }
        syncTranscript(file, create: true)
    }

    /// Uploads every part of this call's recording that has no Drive copy yet.
    func upload(transcript t: String, auto: Bool = false) {
        guard !running.contains(t) else { return }
        guard let acct = account else { errors[t] = L("rec.drive.noAccount"); return }
        let mp = RecordingFiles.metaPath(transcript: t)
        guard let meta = RecordingMeta.load(mp), !meta.notUploaded.isEmpty else {
            dequeue(t)
            if transcriptMode != .off { syncTranscript(t, create: true) }
            return
        }
        let wasGone = meta.parts.contains { $0.driveError == RecordingMeta.Part.folderUnavailable }
        running.insert(t); errors[t] = nil
        enqueue(t)
        Task {
            var failed: String?
            var gone = false
            for part in meta.notUploaded {
                let path = (RecordingFiles.folder(transcript: t) as NSString).appendingPathComponent(part.file)
                guard FileManager.default.fileExists(atPath: path) else { continue }
                do {
                    let folder = try await folderID(project: meta.project.isEmpty ? "Calls" : meta.project, account: acct)
                    let name = (meta.title.isEmpty ? part.file : Self.fileName(meta.title, part))
                    let f = try await send(path: path, name: name, mime: part.kind == "audio" ? "audio/mp4" : "video/mp4",
                                           parent: folder, account: acct, key: t)
                    var m = RecordingMeta.load(mp) ?? meta
                    if let i = m.parts.firstIndex(where: { $0.file == part.file }) {
                        m.parts[i].driveID = f.id; m.parts[i].driveLink = f.link; m.parts[i].driveAccount = acct; m.parts[i].driveError = ""
                        m.parts[i].driveFolderID = folder; m.parts[i].driveKind = DriveFolderState.kind(driveId: f.driveId)
                    }
                    m.save(mp)
                    UsageLog.log("rec_uploaded", ["minutes": Int(part.seconds / 60), "auto": auto, "shared_drive": !f.driveId.isEmpty])
                } catch {
                    gone = error is FolderUnavailable
                    failed = error.localizedDescription
                    var m = RecordingMeta.load(mp) ?? meta
                    if let i = m.parts.firstIndex(where: { $0.file == part.file }) { m.parts[i].driveError = gone ? RecordingMeta.Part.folderUnavailable : (failed ?? "") }
                    m.save(mp)
                    break
                }
            }
            running.remove(t); progress[t] = nil
            if let f = failed {
                errors[t] = f
                if !(gone && wasGone && auto) { CallEngine.shared.notify(L("rec.drive.failed", ["err": f])) }   // once, not at every launch
            } else {
                dequeue(t)
                let link = RecordingMeta.load(mp)?.parts.last?.driveLink ?? ""
                CallEngine.shared.notify(L("rec.drive.done"), url: link.isEmpty ? nil : link)
                if transcriptMode != .off { syncTranscript(t, create: true) }
            }
            objectWillChange.send()
        }
    }

    /// "Folder not available" on the call page: forget the saved folders Drive says are gone (only those), then upload
    /// again; the next upload finds or makes them anew. A folder that is only out of reach for now is kept.
    func recreateFolder(transcript t: String) {
        guard let acct = account, !running.contains(t) else { return }
        let project = RecordingMeta.load(RecordingFiles.metaPath(transcript: t)).map { $0.project.isEmpty ? "Calls" : $0.project } ?? "Calls"
        Task {
            await forgetGone(account: acct, project: project)
            var m = RecordingMeta.load(RecordingFiles.metaPath(transcript: t))
            if m != nil { for i in m!.parts.indices where m!.parts[i].driveError == RecordingMeta.Part.folderUnavailable { m!.parts[i].driveError = "" } }
            m?.save(RecordingFiles.metaPath(transcript: t))
            errors[t] = nil
            upload(transcript: t)
        }
    }

    /// "2026-11-05 14:30 Weekly sync.mp4", "... (part 2).mp4"
    static func fileName(_ title: String, _ p: RecordingMeta.Part) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm"
        let n = p.file.range(of: "\\.recording-[0-9]+\\.", options: .regularExpression).map { String(p.file[$0].dropFirst(11).dropLast()) }
        let clean = title.replacingOccurrences(of: "/", with: "-")
        return f.string(from: p.started) + " " + clean + (n.map { " (part \($0))" } ?? "") + (p.kind == "audio" ? ".m4a" : ".mp4")
    }

    private func enqueue(_ t: String) {
        var q = UserDefaults.standard.stringArray(forKey: queueKey) ?? []
        if !q.contains(t) { q.append(t); UserDefaults.standard.set(q, forKey: queueKey) }
    }
    private func dequeue(_ t: String) {
        let q = (UserDefaults.standard.stringArray(forKey: queueKey) ?? []).filter { $0 != t }
        UserDefaults.standard.set(q, forKey: queueKey)
    }

    // MARK: Settings

    /// The root folder of an account for Settings: its name, whether it is on a shared drive, whether Drive still gives it.
    func refreshRoot(account acct: String) {
        if SheetShots.active { return }
        guard let root = store.account(acct).root else { rootState[acct.lowercased()] = nil; return }
        Task {
            let (st, info) = await check(root.id, account: acct)
            rootState[acct.lowercased()] = st
            if st == .ok, let info, info.name != root.name || info.driveId != root.driveId {
                store.setRoot(acct, DriveFolderStore.Folder(id: root.id, name: info.name, driveId: info.driveId)); store.save(Self.storePath)
            }
        }
    }

    /// Open folder in Drive: the root folder (made now if there is none yet). Errors go to `errors["settings"]`.
    func openRoot(account acct: String) {
        errors["settings"] = nil
        Task {
            do {
                let id = try await rootID(account: acct)
                rootState[acct.lowercased()] = .ok
                NSWorkspace.shared.open(URL(string: "https://drive.google.com/drive/folders/\(id)")!)
            } catch {
                if error is FolderUnavailable { rootState[acct.lowercased()] = .unavailable }
                errors["settings"] = error.localizedDescription
            }
        }
    }

    /// Use default: forget this account's folders; the next upload goes to My Drive > Pacenote (found or made).
    func useDefault(account acct: String) {
        store.reset(acct); store.save(Self.storePath)
        rootState[acct.lowercased()] = nil
        errors["settings"] = nil
    }

    /// Create a new folder from Settings when the saved one is gone.
    func recreateRoot(account acct: String) {
        Task {
            await forgetGone(account: acct, project: nil)
            refreshRoot(account: acct)
            objectWillChange.send()
        }
    }

    /// 0.11.0 (smoke shots): the demo folders and states for the offscreen screens.
    func shotState(store s: DriveFolderStore, rootState r: [String: DriveFolderState] = [:], errors e: [String: String] = [:]) {
        guard SheetShots.active else { return }
        store = s; rootState = r; errors = e
    }

    // MARK: Transcript (ADR 3.4)

    /// Puts the call's transcript into Drive, or updates the copy in place (same id) when the text or the title changed.
    /// `create`: a call without a copy gets one (the setting allows it); otherwise only an existing copy is updated.
    func syncTranscript(_ t: String, create: Bool) {
        guard !SheetShots.active, !transcriptRunning.contains(t), let acct = account else { return }
        let mp = DriveTranscript.metaPath(transcript: t)
        let dm = DriveTranscriptMeta.load(mp) ?? DriveTranscriptMeta()
        guard !dm.fileID.isEmpty || create else { return }
        let src = DriveTranscript.source(transcript: t)
        guard let text = try? String(contentsOfFile: src, encoding: .utf8) else { return }
        let h = header(t)
        let body = DriveTranscript.render(h, transcript: text)
        let name = DriveTranscript.fileName(title: h.title, start: h.start)
        let hash = DriveTranscript.hash(name + "\n" + body)
        guard hash != dm.hash || !dm.error.isEmpty else { return }
        let account = dm.account.isEmpty ? acct : dm.account
        guard accounts.contains(where: { $0.email == account }) else { return }
        transcriptRunning.insert(t)
        Task {
            var dm = dm
            defer { transcriptRunning.remove(t) }
            do {
                if !dm.fileID.isEmpty {
                    do {
                        let f = try await sendSmall(body, name: name, fileID: dm.fileID, parent: nil, account: account)
                        dm.link = f.link.isEmpty ? dm.link : f.link
                    } catch GoogleError.http(let code, _) where code == 404 {
                        dm.fileID = ""          // removed in Drive: made again only when the setting asks for it
                        guard create else { dm.error = ""; dm.hash = ""; dm.save(mp); return }
                    }
                }
                if dm.fileID.isEmpty {
                    let folder: String
                    if let v = RecordingMeta.load(RecordingFiles.metaPath(transcript: t))?.parts.first(where: { !$0.driveFolderID.isEmpty && $0.driveAccount == account }) {
                        folder = v.driveFolderID       // the video's own folder
                    } else {
                        folder = try await folderID(project: h.project.isEmpty ? "Calls" : h.project, account: account)
                    }
                    let f = try await sendSmall(body, name: name, fileID: nil, parent: folder, account: account)
                    dm.fileID = f.id; dm.link = f.link; dm.folderID = folder; dm.kind = DriveFolderState.kind(driveId: f.driveId)
                    dm.account = account
                    UsageLog.log("transcript_drive", ["shared_drive": !f.driveId.isEmpty])
                }
                dm.name = name; dm.hash = hash; dm.error = ""
                dm.save(mp)
            } catch {
                dm.error = error is FolderUnavailable ? RecordingMeta.Part.folderUnavailable : error.localizedDescription
                dm.save(mp)
                errors["transcript|" + t] = error.localizedDescription
            }
            objectWillChange.send()
        }
    }

    /// The call was renamed: the Drive copies (video parts and the transcript) take the new name; ids stay.
    func renamed(file t: String, title: String) {
        let mp = RecordingFiles.metaPath(transcript: t)
        if var m = RecordingMeta.load(mp), !title.isEmpty, m.title != title {
            m.title = title; m.save(mp)
            for p in m.parts where !p.driveID.isEmpty {
                let acct = p.driveAccount
                let name = Self.fileName(title, p)
                Task {
                    guard let token = try? await GoogleService.shared.accessToken(acct) else { return }
                    var r = request("https://www.googleapis.com/drive/v3/files/\(p.driveID)?supportsAllDrives=true&fields=id", method: "PATCH", token: token)
                    r.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
                    r.httpBody = try? JSONSerialization.data(withJSONObject: ["name": name])
                    _ = try? await URLSession.shared.data(for: r)        // best effort: a failed rename leaves the old name
                }
            }
        }
        if DriveTranscriptMeta.load(DriveTranscript.metaPath(transcript: t))?.fileID.isEmpty == false { syncTranscript(t, create: false) }
    }

    func transcriptLink(_ t: String) -> String? {
        guard let m = DriveTranscriptMeta.load(DriveTranscript.metaPath(transcript: t)), !m.fileID.isEmpty, !m.link.isEmpty else { return nil }
        return m.link
    }

    /// Title, start, duration, project and participants: the renamed title and the project from the call history.
    private func header(_ t: String) -> DriveTranscript.Header {
        let r = CallHistory.shared.records.first { $0.file == t }
        let meta = RecordingMeta.load(RecordingFiles.metaPath(transcript: t))
        let title = CallHistory.renamedTitle(t) ?? r?.title ?? meta?.title ?? ""
        let start = r?.start ?? CallHistory.startFromName(t) ?? meta?.parts.first?.started ?? Date()
        var minutes = r?.minutes.map { Int($0.rounded()) }
        if minutes == nil, let e = r?.end { minutes = Int((e.timeIntervalSince(start) / 60).rounded()) }
        if minutes == nil, let m = meta, m.totalSeconds > 0 { minutes = Int((m.totalSeconds / 60).rounded()) }
        let project = (meta?.project).flatMap { $0.isEmpty ? nil : $0 } ?? r?.project ?? ""
        return DriveTranscript.Header(title: title, start: start, minutes: minutes, project: project, participants: AfterCall.people(t))
    }

    // MARK: Drive

    /// The saved folder is gone: deleted, in the trash, or the access was taken away.
    struct FolderUnavailable: LocalizedError {
        var errorDescription: String? { L("rec.drive.folderGone") }
    }

    private func request(_ url: String, method: String, token: String) -> URLRequest {
        var r = URLRequest(url: URL(string: url)!)
        r.httpMethod = method
        r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 120
        return r
    }

    private func json(_ d: Data) -> [String: Any] { ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any]) ?? [:] }
    private func message(_ o: [String: Any]) -> String { ((o["error"] as? [String: Any])?["message"] as? String) ?? "" }

    /// What Drive says about a saved folder now. No network or a token problem is `.retry`.
    private func check(_ id: String, account: String) async -> (DriveFolderState, (name: String, driveId: String)?) {
        guard let token = try? await GoogleService.shared.accessToken(account) else { return (.retry, nil) }
        let url = "https://www.googleapis.com/drive/v3/files/\(id)?supportsAllDrives=true&fields=id,name,trashed,driveId,capabilities(canAddChildren)"
        guard let (d, resp) = try? await URLSession.shared.data(for: request(url, method: "GET", token: token)) else { return (.retry, nil) }
        let o = json(d)
        let st = DriveFolderState.of(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, body: o)
        return (st, st == .ok ? ((o["name"] as? String) ?? "", (o["driveId"] as? String) ?? "") : nil)
    }

    /// No answer from Drive (no network, a server error, the token): the id is kept, the upload waits in the queue.
    struct DriveOffline: LocalizedError {
        var errorDescription: String? { L("rec.drive.offline") }
    }
    private func notReachable() -> Error { DriveOffline() }

    /// <root>/<project>: the saved project folder if Drive gives it, else found or made inside the root.
    private func folderID(project: String, account: String) async throws -> String {
        if let p = store.account(account).projects[project] {
            switch await check(p.id, account: account).0 {
            case .ok: return p.id
            case .retry: throw notReachable()
            case .unavailable: throw FolderUnavailable()
            }
        }
        let root = try await rootID(account: account)
        let id = try await findOrMake(project, parent: root, account: account)
        store.setProject(account, project, DriveFolderStore.Folder(id: id, name: project, driveId: store.account(account).root?.driveId ?? ""))
        store.save(Self.storePath)
        return id
    }

    /// My Drive > Pacenote, or wherever the PM moved it: the saved id while Drive gives it; a new one only with no id.
    private func rootID(account: String) async throws -> String {
        if let r = store.account(account).root {
            let (st, info) = await check(r.id, account: account)
            switch st {
            case .ok:
                if let info, info.driveId != r.driveId || info.name != r.name {
                    store.setRoot(account, DriveFolderStore.Folder(id: r.id, name: info.name, driveId: info.driveId)); store.save(Self.storePath)
                }
                return r.id
            case .retry: throw notReachable()
            case .unavailable: rootState[account.lowercased()] = .unavailable; throw FolderUnavailable()
            }
        }
        let id = try await findOrMake(DriveFolderStore.rootName, parent: nil, account: account)
        store.setRoot(account, DriveFolderStore.Folder(id: id, name: DriveFolderStore.rootName)); store.save(Self.storePath)
        rootState[account.lowercased()] = .ok
        return id
    }

    /// Forgets the saved folders that Drive says are gone (the project's, or all of the account's when nil).
    private func forgetGone(account acct: String, project: String?) async {
        let a = store.account(acct)
        for (name, f) in a.projects where project == nil || name == project {
            if await check(f.id, account: acct).0 == .unavailable { store.setProject(acct, name, nil) }
        }
        if let r = a.root, await check(r.id, account: acct).0 == .unavailable {
            store.setRoot(acct, nil); rootState[acct.lowercased()] = nil
        }
        store.save(Self.storePath)
    }

    /// A folder by name under `parent` (My Drive's root when nil) that Pacenote made, else a new one.
    private func findOrMake(_ name: String, parent: String?, account: String) async throws -> String {
        let token = try await GoogleService.shared.accessToken(account)
        let esc = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        var q = "name = '\(esc)' and mimeType = 'application/vnd.google-apps.folder' and trashed = false"
        q += parent.map { " and '\($0)' in parents" } ?? " and 'root' in parents"
        var c = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        c.queryItems = [.init(name: "q", value: q), .init(name: "fields", value: "files(id)"),
                        .init(name: "supportsAllDrives", value: "true"), .init(name: "includeItemsFromAllDrives", value: "true"),
                        .init(name: "corpora", value: "allDrives")]
        let (ld, lr) = try await URLSession.shared.data(for: request(c.url!.absoluteString, method: "GET", token: token))
        let lcode = (lr as? HTTPURLResponse)?.statusCode ?? 0
        if lcode == 200, let id = ((json(ld)["files"] as? [[String: Any]])?.first?["id"]) as? String { return id }
        guard lcode == 200 else { throw GoogleError.http(lcode, message(json(ld))) }        // no list, no new folder
        var r = request("https://www.googleapis.com/drive/v3/files?fields=id&supportsAllDrives=true", method: "POST", token: token)
        r.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        var meta: [String: Any] = ["name": name, "mimeType": "application/vnd.google-apps.folder"]
        if let p = parent { meta["parents"] = [p] }
        r.httpBody = try JSONSerialization.data(withJSONObject: meta)
        let (d, resp) = try await URLSession.shared.data(for: r)
        let o = json(d)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let id = o["id"] as? String else {
            throw GoogleError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, message(o))
        }
        return id
    }

    struct Sent { var id: String; var link: String; var driveId: String }

    /// A small text file in one request (multipart): a new file in `parent`, or new content and name for `fileID`.
    private func sendSmall(_ text: String, name: String, fileID: String?, parent: String?, account: String) async throws -> Sent {
        let token = try await GoogleService.shared.accessToken(account)
        let boundary = "pacenote-" + UUID().uuidString
        var meta: [String: Any] = ["name": name]
        if fileID == nil { meta["mimeType"] = DriveTranscript.mime; if let p = parent { meta["parents"] = [p] } }
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(try JSONSerialization.data(withJSONObject: meta))
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: \(DriveTranscript.mime); charset=UTF-8\r\n\r\n".utf8))
        body.append(Data(text.utf8))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let base = "https://www.googleapis.com/upload/drive/v3/files"
        let q = "uploadType=multipart&supportsAllDrives=true&fields=id,webViewLink,driveId"
        var r = request(fileID.map { base + "/\($0)?" + q } ?? base + "?" + q, method: fileID == nil ? "POST" : "PATCH", token: token)
        r.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        let (d, resp) = try await URLSession.shared.data(for: r)
        let o = json(d)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let id = o["id"] as? String else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if fileID == nil, code == 404 || code == 403 { throw FolderUnavailable() }
            throw GoogleError.http(code, message(o))
        }
        return Sent(id: id, link: (o["webViewLink"] as? String) ?? "https://drive.google.com/file/d/\(id)/view", driveId: (o["driveId"] as? String) ?? "")
    }

    /// Resumable upload; returns the file's id, its Drive link and the shared drive's id ("" in My Drive).
    private func send(path: String, name: String, mime: String, parent: String, account: String, key: String) async throws -> Sent {
        let total = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
        guard total > 0, let fh = FileHandle(forReadingAtPath: path) else { throw GoogleError.http(0, L("rec.drive.noFile")) }
        defer { try? fh.close() }
        var token = try await GoogleService.shared.accessToken(account)
        var r = request("https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&supportsAllDrives=true&fields=id,webViewLink,driveId",
                        method: "POST", token: token)
        r.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        r.setValue(mime, forHTTPHeaderField: "X-Upload-Content-Type")
        r.setValue("\(total)", forHTTPHeaderField: "X-Upload-Content-Length")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "parents": [parent], "mimeType": mime])
        let (sd, sr) = try await URLSession.shared.data(for: r)
        guard let http = sr as? HTTPURLResponse, http.statusCode == 200, let session = http.value(forHTTPHeaderField: "Location") else {
            let code = (sr as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { throw FolderUnavailable() }       // the parent went away between the check and the upload
            throw GoogleError.http(code, message(json(sd)))
        }
        var offset: Int64 = 0
        var retries = 0
        let mb: (Int64) -> String = { "\(Int(Double($0) / 1_000_000))" }
        while true {
            progress[key] = L("rec.drive.progress", ["done": mb(offset), "total": mb(total)])
            try fh.seek(toOffset: UInt64(offset))
            let piece = try fh.read(upToCount: chunk) ?? Data()
            var put = request(session, method: "PUT", token: token)
            put.setValue("bytes \(offset)-\(offset + Int64(piece.count) - 1)/\(total)", forHTTPHeaderField: "Content-Range")
            do {
                let (d, resp) = try await URLSession.shared.upload(for: put, from: piece)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200 || code == 201 {
                    let o = json(d)
                    guard let id = o["id"] as? String else { throw GoogleError.http(code, "no id") }
                    return Sent(id: id, link: (o["webViewLink"] as? String) ?? "https://drive.google.com/file/d/\(id)/view",
                                driveId: (o["driveId"] as? String) ?? "")
                }
                if code == 308 {
                    offset = Self.confirmed((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Range")) ?? 0   // no Range: Google kept nothing yet
                    retries = 0
                    continue
                }
                if code == 401 { token = try await GoogleService.shared.accessToken(account) }
                guard code >= 500 || code == 401 || code == 429, retries < 5 else { throw GoogleError.http(code, message(json(d))) }
            } catch let e as GoogleError { throw e } catch {
                guard retries < 5 else { throw error }
            }
            retries += 1
            try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(retries))) * 1_000_000_000)
            offset = ((try? await status(session, total: total, token: token)) ?? nil) ?? offset   // no network yet: try again
        }
    }

    /// Asks Google how much of the file it has (after a dropped piece).
    private func status(_ session: String, total: Int64, token: String) async throws -> Int64? {
        var r = request(session, method: "PUT", token: token)
        r.setValue("bytes */\(total)", forHTTPHeaderField: "Content-Range")
        let (_, resp) = try await URLSession.shared.upload(for: r, from: Data())
        guard let h = resp as? HTTPURLResponse, h.statusCode == 308 else { return nil }
        return Self.confirmed(h.value(forHTTPHeaderField: "Range")) ?? 0
    }

    /// 0.9.5 QA (`--rec-drive-test <file>`): uploads one file to <Pacenote folder> > Test and waits up to 3 minutes for
    /// Drive to process the video (videoMediaMetadata appears when Drive can play it). Returns a JSON line, no tokens.
    /// 0.11.0: also says whether the folder is on a shared drive (the root as saved, possibly moved by the PM).
    func testUpload(path: String) async -> [String: Any] {
        guard let acct = account else { return ["error": "no account with the export scope"] }
        do {
            let folder = try await folderID(project: "Test", account: acct)
            let f = try await send(path: path, name: "pacenote-test-" + (path as NSString).lastPathComponent, mime: "video/mp4",
                                   parent: folder, account: acct, key: path)
            var out: [String: Any] = ["uploaded": true, "link": f.link, "drive_kind": DriveFolderState.kind(driveId: f.driveId),
                                      "account_domain": String(acct.split(separator: "@").last ?? "")]
            for i in 0..<18 {
                let token = try await GoogleService.shared.accessToken(acct)
                let (d, _) = try await URLSession.shared.data(for: request("https://www.googleapis.com/drive/v3/files/\(f.id)?supportsAllDrives=true&fields=mimeType,videoMediaMetadata,hasThumbnail", method: "GET", token: token))
                let o = json(d)
                out["mimeType"] = o["mimeType"]; out["hasThumbnail"] = o["hasThumbnail"]; out["waited_s"] = i * 10
                if let v = o["videoMediaMetadata"] { out["videoMediaMetadata"] = v; break }
                try await Task.sleep(nanoseconds: 10_000_000_000)
            }
            return out
        } catch { return ["error": error.localizedDescription, "folder_unavailable": error is FolderUnavailable] }
    }

    /// 0.11.0 QA (`--drive-b7b-test <file> <out.json>`): the B7b paths against the live Drive, in <Pacenote folder> > Test:
    /// the saved folders (migrated or new), a video upload with its kind, a transcript .md made and then updated in place
    /// (same id, new name and text), a rename of the video by PATCH, and a project folder with an id Drive does not know,
    /// which must stop with FolderUnavailable and make nothing. Returns ids, kinds and HTTP results; no tokens, no emails.
    func testB7b(path: String) async -> [String: Any] {
        guard let acct = account else { return ["error": "no account with the export scope"] }
        var out: [String: Any] = ["account_domain": String(acct.split(separator: "@").last ?? "")]
        let before = store.account(acct)
        out["store_before"] = ["root": before.root?.id ?? "", "root_kind": DriveFolderState.kind(driveId: before.root?.driveId), "projects": before.projects.keys.sorted()]
        do {
            let folder = try await folderID(project: "Test", account: acct)
            let root = store.account(acct).root
            out["root_id"] = root?.id ?? ""; out["root_name"] = root?.name ?? ""; out["root_kind"] = DriveFolderState.kind(driveId: root?.driveId)
            out["root_same_as_before"] = before.root == nil ? NSNull() : (before.root?.id == root?.id) as Any
            out["test_folder"] = folder
            // 1. the video
            var part = RecordingMeta.Part(file: "b7b.recording.mp4", kind: "video", started: Date())
            let v = try await send(path: path, name: Self.fileName("B7b live test", part), mime: "video/mp4", parent: folder, account: acct, key: path)
            progress[path] = nil
            part.driveID = v.id
            out["video"] = ["id": v.id, "kind": DriveFolderState.kind(driveId: v.driveId), "link_ok": v.link.hasPrefix("https://")]
            // 2. rename the video in place
            let newName = Self.fileName("B7b live test renamed", part)
            let token = try await GoogleService.shared.accessToken(acct)
            var r = request("https://www.googleapis.com/drive/v3/files/\(v.id)?supportsAllDrives=true&fields=id,name", method: "PATCH", token: token)
            r.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: ["name": newName])
            let (rd, rr) = try await URLSession.shared.data(for: r)
            out["video_rename"] = ["http": (rr as? HTTPURLResponse)?.statusCode ?? 0, "name_ok": (json(rd)["name"] as? String) == newName]
            // 3. the transcript: made, then updated in place
            let start = Date()
            let tr = "# Live transcript: x\n\n[10:00:01] Me (en): Hello Emily (1.2s)\n[10:00:04] Them [S2] (en): Hi Mike\n"
            let h1 = DriveTranscript.Header(title: "B7b live test", start: start, minutes: 1, project: "Test", participants: ["Emily", "Mike"])
            let t1 = try await sendSmall(DriveTranscript.render(h1, transcript: tr), name: DriveTranscript.fileName(title: h1.title, start: start),
                                         fileID: nil, parent: folder, account: acct)
            var h2 = h1; h2.title = "B7b live test renamed"
            let name2 = DriveTranscript.fileName(title: h2.title, start: start)
            let t2 = try await sendSmall(DriveTranscript.render(h2, transcript: tr + "[10:00:09] Emily (en): One more line\n"), name: name2,
                                         fileID: t1.id, parent: nil, account: acct)
            let (gd, _) = try await URLSession.shared.data(for: request("https://www.googleapis.com/drive/v3/files/\(t1.id)?supportsAllDrives=true&fields=id,name,mimeType,parents,driveId,version", method: "GET", token: token))
            let g = json(gd)
            let (cd, _) = try await URLSession.shared.data(for: request("https://www.googleapis.com/drive/v3/files/\(t1.id)?supportsAllDrives=true&alt=media", method: "GET", token: token))
            let content = String(data: cd, encoding: .utf8) ?? ""
            out["transcript"] = ["id": t1.id, "same_id_after_update": t2.id == t1.id, "name_ok": (g["name"] as? String) == name2,
                                 "mime": g["mimeType"] ?? "", "in_test_folder": ((g["parents"] as? [String]) ?? []).contains(folder),
                                 "kind": DriveFolderState.kind(driveId: g["driveId"] as? String),
                                 "content_updated": content.contains("One more line") && content.hasPrefix("# B7b live test renamed"),
                                 "no_internal_lines": !content.contains("Live transcript") && !content.contains("(1.2s)"),
                                 "speaker_number": content.contains("Them 2:")]
            // 4. a saved project folder Drive does not know: must stop, and make nothing
            let fake = "pacenote-b7b-missing-folder-id"
            store.setProject(acct, "B7b gone", DriveFolderStore.Folder(id: fake, name: "B7b gone")); store.save(Self.storePath)
            do {
                _ = try await folderID(project: "B7b gone", account: acct)
                out["gone"] = ["stopped": false]
            } catch {
                out["gone"] = ["stopped": error is FolderUnavailable, "kept_id": store.account(acct).projects["B7b gone"]?.id == fake]
            }
            await forgetGone(account: acct, project: "B7b gone")
            out["gone_forgotten"] = store.account(acct).projects["B7b gone"] == nil
            out["root_after_forget"] = store.account(acct).root?.id == root?.id
        } catch {
            out["error"] = error.localizedDescription
            out["folder_unavailable"] = error is FolderUnavailable
        }
        return out
    }

    /// QA clean-up (`--drive-b7b-cleanup <out.json> <id...>`): moves files this app made to the Drive trash (not a
    /// permanent delete). drive.file reaches only what Pacenote created, so any other id fails with 404.
    func testTrash(_ ids: [String]) async -> [String: Any] {
        guard let acct = account, let token = try? await GoogleService.shared.accessToken(acct) else { return ["error": "no account or token"] }
        var out: [String: Any] = [:]
        for id in ids {
            var r = request("https://www.googleapis.com/drive/v3/files/\(id)?supportsAllDrives=true&fields=id,trashed", method: "PATCH", token: token)
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = Data("{\"trashed\":true}".utf8)
            if let (d, resp) = try? await URLSession.shared.data(for: r) {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                out[id] = code == 200 && (json(d)["trashed"] as? Bool) == true ? "trashed" : "http \(code): \(message(json(d)))"
            } else { out[id] = "network error" }
        }
        return out
    }

    /// "bytes=0-8388607" -> 8388608
    nonisolated static func confirmed(_ range: String?) -> Int64? {
        guard let r = range, let last = r.split(separator: "-").last, let n = Int64(last) else { return nil }
        return n + 1
    }
}
