import AppKit
import LiveTipsCore

/// 0.9.5 (owner): a call recording copied to the PM's own Google Drive, for sharing. The original stays on this Mac.
/// drive.file only: Pacenote sees nothing in Drive but the files and folders it made (My Drive > Pacenote > <project>).
/// Resumable upload in 8 MB pieces: a dropped connection goes on from the last piece Google confirmed. The queue
/// survives a restart (UserDefaults "recUploadQueue", transcript paths) and starts again at launch.
@MainActor
final class DriveRecordings: ObservableObject {
    static let shared = DriveRecordings()
    /// transcript path -> "12 of 340 MB" while it uploads
    @Published private(set) var progress: [String: String] = [:]
    @Published private(set) var errors: [String: String] = [:]
    private var running = Set<String>()
    private let chunk = 8 * 1024 * 1024
    private let queueKey = "recUploadQueue"

    var accounts: [GoogleAccount] { GoogleService.shared.accounts.filter { $0.has(GoogleScopes.export) } }

    /// The account Settings name, else the first one that allows the export.
    var account: String? {
        let want = AppConfig.load(from: AppPaths.config).recording.driveAccount
        return accounts.first { $0.email == want }?.email ?? accounts.first?.email
    }

    func isUploading(_ transcript: String) -> Bool { running.contains(transcript) }

    /// Resumes what was waiting when the app quit.
    func resumeQueue() {
        for t in UserDefaults.standard.stringArray(forKey: queueKey) ?? [] { upload(transcript: t, auto: true) }
    }

    /// Uploads every part of this call's recording that has no Drive copy yet.
    func upload(transcript t: String, auto: Bool = false) {
        guard !running.contains(t) else { return }
        guard let acct = account else { errors[t] = L("rec.drive.noAccount"); return }
        let mp = RecordingFiles.metaPath(transcript: t)
        guard let meta = RecordingMeta.load(mp), !meta.notUploaded.isEmpty else { dequeue(t); return }
        running.insert(t); errors[t] = nil
        enqueue(t)
        Task {
            var failed: String?
            for part in meta.notUploaded {
                let path = (RecordingFiles.folder(transcript: t) as NSString).appendingPathComponent(part.file)
                guard FileManager.default.fileExists(atPath: path) else { continue }
                do {
                    let folder = try await folderID(project: meta.project.isEmpty ? "Calls" : meta.project, account: acct)
                    let name = (meta.title.isEmpty ? part.file : Self.fileName(meta.title, part)) 
                    let (id, link) = try await send(path: path, name: name, mime: part.kind == "audio" ? "audio/mp4" : "video/mp4",
                                                    parent: folder, account: acct, key: t)
                    var m = RecordingMeta.load(mp) ?? meta
                    if let i = m.parts.firstIndex(where: { $0.file == part.file }) {
                        m.parts[i].driveID = id; m.parts[i].driveLink = link; m.parts[i].driveAccount = acct; m.parts[i].driveError = ""
                    }
                    m.save(mp)
                    UsageLog.log("rec_uploaded", ["minutes": Int(part.seconds / 60), "auto": auto])
                } catch {
                    failed = error.localizedDescription
                    var m = RecordingMeta.load(mp) ?? meta
                    if let i = m.parts.firstIndex(where: { $0.file == part.file }) { m.parts[i].driveError = failed ?? "" }
                    m.save(mp)
                    break
                }
            }
            running.remove(t); progress[t] = nil
            if let f = failed {
                errors[t] = f
                CallEngine.shared.notify(L("rec.drive.failed", ["err": f]))
            } else {
                dequeue(t)
                let link = RecordingMeta.load(mp)?.parts.last?.driveLink ?? ""
                CallEngine.shared.notify(L("rec.drive.done"), url: link.isEmpty ? nil : link)
            }
            objectWillChange.send()
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

    // MARK: Drive

    private func request(_ url: String, method: String, token: String) -> URLRequest {
        var r = URLRequest(url: URL(string: url)!)
        r.httpMethod = method
        r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 120
        return r
    }

    private func json(_ d: Data) -> [String: Any] { ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any]) ?? [:] }
    private func message(_ o: [String: Any]) -> String { ((o["error"] as? [String: Any])?["message"] as? String) ?? "" }

    /// My Drive > Pacenote > <project>, made once (only folders Pacenote made are visible to it).
    private func folderID(project: String, account: String) async throws -> String {
        let root = try await folder(named: "Pacenote", parent: nil, account: account)
        return try await folder(named: project, parent: root, account: account)
    }

    private func folder(named name: String, parent: String?, account: String) async throws -> String {
        let key = "driveFolder|\(account)|\(parent ?? "root")|\(name)"
        let token = try await GoogleService.shared.accessToken(account)
        if let id = UserDefaults.standard.string(forKey: key) {
            let (d, resp) = try await URLSession.shared.data(for: request("https://www.googleapis.com/drive/v3/files/\(id)?fields=id,trashed", method: "GET", token: token))
            if (resp as? HTTPURLResponse)?.statusCode == 200, (json(d)["trashed"] as? Bool) != true { return id }
            UserDefaults.standard.removeObject(forKey: key)
        }
        let esc = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        var q = "name = '\(esc)' and mimeType = 'application/vnd.google-apps.folder' and trashed = false"
        q += parent.map { " and '\($0)' in parents" } ?? " and 'root' in parents"
        var c = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        c.queryItems = [.init(name: "q", value: q), .init(name: "fields", value: "files(id)"), .init(name: "spaces", value: "drive")]
        let (ld, lr) = try await URLSession.shared.data(for: request(c.url!.absoluteString, method: "GET", token: token))
        if (lr as? HTTPURLResponse)?.statusCode == 200, let id = ((json(ld)["files"] as? [[String: Any]])?.first?["id"]) as? String {
            UserDefaults.standard.set(id, forKey: key); return id
        }
        var r = request("https://www.googleapis.com/drive/v3/files?fields=id", method: "POST", token: token)
        r.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        var meta: [String: Any] = ["name": name, "mimeType": "application/vnd.google-apps.folder"]
        if let p = parent { meta["parents"] = [p] }
        r.httpBody = try JSONSerialization.data(withJSONObject: meta)
        let (d, resp) = try await URLSession.shared.data(for: r)
        let o = json(d)
        guard (resp as? HTTPURLResponse)?.statusCode == 200, let id = o["id"] as? String else {
            throw GoogleError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, message(o))
        }
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    /// Resumable upload; returns the file's id and its Drive link.
    private func send(path: String, name: String, mime: String, parent: String, account: String, key: String) async throws -> (String, String) {
        let total = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
        guard total > 0, let fh = FileHandle(forReadingAtPath: path) else { throw GoogleError.http(0, L("rec.drive.noFile")) }
        defer { try? fh.close() }
        var token = try await GoogleService.shared.accessToken(account)
        var r = request("https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id,webViewLink", method: "POST", token: token)
        r.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        r.setValue(mime, forHTTPHeaderField: "X-Upload-Content-Type")
        r.setValue("\(total)", forHTTPHeaderField: "X-Upload-Content-Length")
        r.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "parents": [parent], "mimeType": mime])
        let (sd, sr) = try await URLSession.shared.data(for: r)
        guard let http = sr as? HTTPURLResponse, http.statusCode == 200, let session = http.value(forHTTPHeaderField: "Location") else {
            throw GoogleError.http((sr as? HTTPURLResponse)?.statusCode ?? 0, message(json(sd)))
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
                    return (id, (o["webViewLink"] as? String) ?? "https://drive.google.com/file/d/\(id)/view")
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

    /// 0.9.5 QA (`--rec-drive-test <file>`): uploads one file to My Drive > Pacenote > Test and waits up to 3 minutes for
    /// Drive to process the video (videoMediaMetadata appears when Drive can play it). Returns a JSON line, no tokens.
    func testUpload(path: String) async -> [String: Any] {
        guard let acct = account else { return ["error": "no account with the export scope"] }
        do {
            let folder = try await folderID(project: "Test", account: acct)
            let (id, link) = try await send(path: path, name: "pacenote-test-" + (path as NSString).lastPathComponent, mime: "video/mp4",
                                            parent: folder, account: acct, key: path)
            var out: [String: Any] = ["uploaded": true, "link": link, "account_domain": String(acct.split(separator: "@").last ?? "")]
            for i in 0..<18 {
                let token = try await GoogleService.shared.accessToken(acct)
                let (d, _) = try await URLSession.shared.data(for: request("https://www.googleapis.com/drive/v3/files/\(id)?fields=mimeType,videoMediaMetadata,hasThumbnail", method: "GET", token: token))
                let o = json(d)
                out["mimeType"] = o["mimeType"]; out["hasThumbnail"] = o["hasThumbnail"]; out["waited_s"] = i * 10
                if let v = o["videoMediaMetadata"] { out["videoMediaMetadata"] = v; break }
                try await Task.sleep(nanoseconds: 10_000_000_000)
            }
            return out
        } catch { return ["error": error.localizedDescription] }
    }

    /// "bytes=0-8388607" -> 8388608
    nonisolated static func confirmed(_ range: String?) -> Int64? {
        guard let r = range, let last = r.split(separator: "-").last, let n = Int64(last) else { return nil }
        return n + 1
    }
}
