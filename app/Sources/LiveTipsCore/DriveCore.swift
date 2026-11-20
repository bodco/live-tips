import Foundation

/// 0.11.0 (B7b, server ADR 3.3, 3.4, 3.7): the Drive side of call recordings, without network: where the folder ids
/// live, what a Drive answer means for a saved folder, the transcript file Pacenote puts next to the video.

/// The Drive folders Pacenote made, per Google account: My Drive > Pacenote (the root) and one folder per project
/// in it. Kept in a file (Application Support/LiveTips/drive-folders.json), not as a cache: the PM may move the
/// folder in Drive (to a shared drive, into a shared folder); a search by name would not find it there, and a new
/// "Pacenote" would split the calls. The id survives a move, so Pacenote writes by the id while Drive gives it.
public struct DriveFolderStore: Codable, Equatable {
    public struct Folder: Codable, Equatable {
        public var id: String
        public var name: String
        /// The shared drive's id when the folder is on one ("" for My Drive). Read from Drive, not chosen.
        public var driveId: String = ""
        public init(id: String, name: String, driveId: String = "") { self.id = id; self.name = name; self.driveId = driveId }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil ?? ""
            driveId = (try? c.decodeIfPresent(String.self, forKey: .driveId)) ?? nil ?? ""
        }
    }
    public struct Account: Codable, Equatable {
        public var root: Folder?
        /// project name -> its folder inside the root
        public var projects: [String: Folder] = [:]
        public init(root: Folder? = nil, projects: [String: Folder] = [:]) { self.root = root; self.projects = projects }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            root = (try? c.decodeIfPresent(Folder.self, forKey: .root)) ?? nil
            projects = (try? c.decodeIfPresent([String: Folder].self, forKey: .projects)) ?? nil ?? [:]
        }
    }
    public var schema = 1
    /// lowercased email -> the account's folders
    public var accounts: [String: Account] = [:]
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = (try? c.decodeIfPresent(Int.self, forKey: .schema)) ?? nil ?? 1
        accounts = (try? c.decodeIfPresent([String: Account].self, forKey: .accounts)) ?? nil ?? [:]
    }

    public static let rootName = "Pacenote"

    public func account(_ email: String) -> Account { accounts[email.lowercased()] ?? Account() }
    public mutating func setRoot(_ email: String, _ f: Folder?) {
        var a = account(email); a.root = f; accounts[email.lowercased()] = a
    }
    public mutating func setProject(_ email: String, _ project: String, _ f: Folder?) {
        var a = account(email); a.projects[project] = f; accounts[email.lowercased()] = a
    }
    /// Use default: forget this account's folders (the next upload finds or makes My Drive > Pacenote again).
    public mutating func reset(_ email: String) { accounts[email.lowercased()] = nil }

    public static func load(_ path: String) -> DriveFolderStore? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(DriveFolderStore.self, from: d)
    }
    public func save(_ path: String) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let d = try? enc.encode(self) { try? d.write(to: URL(fileURLWithPath: path), options: .atomic) }
    }

    /// 0.9.5-0.10.2 kept the ids in UserDefaults: "driveFolder|<account>|<parent id or root>|<name>" -> id.
    /// The root is the "Pacenote" under "root"; a project is a folder whose parent is that root's id. Other keys
    /// (the spike's folders, a stale root) are left alone. Existing entries in the store win.
    public static func migrated(_ s: DriveFolderStore, defaults: [String: String]) -> DriveFolderStore {
        var out = s
        var roots: [String: String] = [:]       // account -> root id
        for (k, v) in defaults {
            let p = k.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard p.count == 4, p[0] == "driveFolder", p[2] == "root", p[3] == rootName, !v.isEmpty else { continue }
            roots[p[1].lowercased()] = v
        }
        for (acct, rid) in roots where out.account(acct).root == nil { out.setRoot(acct, Folder(id: rid, name: rootName)) }
        for (k, v) in defaults {
            let p = k.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard p.count == 4, p[0] == "driveFolder", !v.isEmpty else { continue }
            let acct = p[1].lowercased()
            guard let root = out.account(acct).root, p[2] == root.id, out.account(acct).projects[p[3]] == nil else { continue }
            out.setProject(acct, p[3], Folder(id: v, name: p[3], driveId: root.driveId))
        }
        return out
    }
}

/// What a Drive answer about a saved folder means. Only a clear "not there" (404, in the trash, access taken away)
/// makes it unavailable; no network, a server error or an expired token is "try later" and keeps the id.
public enum DriveFolderState: Equatable {
    case ok
    case unavailable
    case retry

    public static func of(status: Int, body: [String: Any]) -> DriveFolderState {
        if status == 200 {
            if (body["trashed"] as? Bool) == true { return .unavailable }
            if let caps = body["capabilities"] as? [String: Any], (caps["canAddChildren"] as? Bool) == false { return .unavailable }
            return .ok
        }
        if status == 404 { return .unavailable }
        if status == 403 {
            let reasons = (((body["error"] as? [String: Any])?["errors"] as? [[String: Any]]) ?? []).compactMap { $0["reason"] as? String }
            if reasons.contains(where: { $0 == "rateLimitExceeded" || $0 == "userRateLimitExceeded" || $0 == "dailyLimitExceeded" }) { return .retry }
            return .unavailable
        }
        return .retry              // 0 (no network), 401, 429, 5xx
    }

    /// "my_drive" | "shared_drive", from the file's driveId (files on a shared drive have no owner person).
    public static func kind(driveId: String?) -> String { (driveId ?? "").isEmpty ? "my_drive" : "shared_drive" }
}

/// Settings > Call recording > Google Drive > Transcript in Drive.
public enum TranscriptInDrive: String, CaseIterable {
    case off
    case withRecording = "with_recording"
    case everyCall = "every_call"
}

/// The transcript Pacenote puts in Drive: the same folder and name base as the video, ".md", one file per call.
/// The header (title, date, duration, project, participants) and the lines with the speaker and the time. No tips,
/// no private notes, no Meeting Sheet. Built from <stem>.named.md (speaker names applied) or else <stem>.md.
public enum DriveTranscript {
    public static let mime = "text/markdown"

    /// "2026-11-05 14.30 Weekly sync.md" (the time the call started).
    public static func fileName(title: String, start: Date, ext: String = "md") -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH.mm"
        let clean = title.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return f.string(from: start) + " " + (clean.isEmpty ? "Call" : clean) + "." + ext
    }

    /// The source file for a call's transcript: the named copy when there is one.
    public static func source(transcript: String) -> String {
        let stem = transcript.hasSuffix(".md") ? String(transcript.dropLast(3)) : transcript
        let named = CallLayout.sidecar(stem, ".named.md")
        return FileManager.default.fileExists(atPath: named) ? named : transcript
    }

    /// <stem>.drive.json next to the transcript: the transcript's own Drive copy (also for calls without a recording).
    public static func metaPath(transcript: String) -> String {
        let stem = transcript.hasSuffix(".md") ? String(transcript.dropLast(3)) : transcript
        return CallLayout.sidecar(stem, ".drive.json")
    }

    public struct Line: Equatable {
        public var time: String
        public var who: String
        public var text: String
        public init(time: String, who: String, text: String) { self.time = time; self.who = who; self.text = text }
    }

    private static let line = try! NSRegularExpression(pattern: "^\\[(\\d\\d:\\d\\d:\\d\\d)\\] (.+?)(?: \\[(S\\d+)\\])? \\((\\w+)\\): (.*)$")
    private static let timing = try! NSRegularExpression(pattern: " \\(\\d+(?:\\.\\d+)?s\\)$")

    /// The spoken lines of a transcript: "[14:30:05] Mike (en): Hi (2.1s)" -> 14:30:05, Mike, Hi. A speaker the PM did
    /// not name keeps the label and its number ("Them [S2]" -> "Them 2"). Headers and end marks are dropped.
    public static func lines(_ text: String) -> [Line] {
        var out: [Line] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let s = String(raw)
            guard let m = line.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { continue }
            func g(_ k: Int) -> String { Range(m.range(at: k), in: s).map { String(s[$0]) } ?? "" }
            var who = g(2)
            let sid = g(3)
            if !sid.isEmpty { who += " " + String(sid.dropFirst()) }
            var t = g(5)
            if let tm = timing.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), let r = Range(tm.range, in: t) { t.removeSubrange(r) }
            t = t.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { continue }
            out.append(Line(time: g(1), who: who, text: t))
        }
        return out
    }

    public struct Header: Equatable {
        public var title: String
        public var start: Date
        public var minutes: Int?
        public var project: String
        public var participants: [String]
        public init(title: String, start: Date, minutes: Int?, project: String, participants: [String]) {
            self.title = title; self.start = start; self.minutes = minutes; self.project = project; self.participants = participants
        }
    }

    /// The file's text, in English (it is read by others in Drive, like the file name).
    public static func render(_ h: Header, transcript text: String) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm"
        var s = "# " + (h.title.isEmpty ? "Call" : h.title) + "\n\n"
        s += "- Date: " + f.string(from: h.start) + "\n"
        if let m = h.minutes, m > 0 { s += "- Duration: \(m) min\n" }
        if !h.project.isEmpty { s += "- Project: " + h.project + "\n" }
        if !h.participants.isEmpty { s += "- Participants: " + h.participants.joined(separator: ", ") + "\n" }
        s += "\n## Transcript\n\n"
        let ls = lines(text)
        if ls.isEmpty { s += "_No speech was transcribed._\n" }
        for l in ls { s += "**\(l.time) \(l.who):** \(l.text)\n\n" }
        s += "---\nMade by Pacenote. The audio stayed on the Mac.\n"
        return s
    }

    /// A short, stable fingerprint of the text (FNV-1a 64): the file is sent again only when it changed.
    public static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}

/// <stem>.drive.json: the call's transcript in Drive.
public struct DriveTranscriptMeta: Codable, Equatable {
    public var schema = 1
    public var fileID = ""
    public var link = ""
    public var name = ""
    public var folderID = ""
    public var kind = ""          // my_drive | shared_drive
    public var account = ""
    public var hash = ""          // of the text last sent
    public var error = ""
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func s(_ k: CodingKeys) -> String { (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil ?? "" }
        schema = (try? c.decodeIfPresent(Int.self, forKey: .schema)) ?? nil ?? 1
        fileID = s(.fileID); link = s(.link); name = s(.name); folderID = s(.folderID); kind = s(.kind)
        account = s(.account); hash = s(.hash); error = s(.error)
    }
    public static func load(_ path: String) -> DriveTranscriptMeta? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(DriveTranscriptMeta.self, from: d)
    }
    public func save(_ path: String) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(self) { try? d.write(to: URL(fileURLWithPath: path), options: .atomic) }
    }
}
