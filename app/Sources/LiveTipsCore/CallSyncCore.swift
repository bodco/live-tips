import CryptoKit
import Foundation

/// 0.12.0 (B8b, server ADR 8 and 9): what a call sends to the Pacenote server and how the Mac remembers it.
/// Only what D27 allows: metadata, the call notes as the summary, decisions, tasks, the Meeting Sheet and Drive links.
/// Never audio, video, the transcript, speaker names from the transcript or tip texts. The Mac stays the source of
/// truth: every request replaces the server's copy, and a part is sent again only when its body changed.
/// Off by default: a project sends nothing until its "Sync to Pacenote server" is on (owner, 2026-11-15).
public enum CallSync {
    /// <stem>.sync.json next to the transcript.
    public struct State: Codable, Equatable {
        public var schema = 1
        public var callID = ""              // the server's id of the call
        public var clientCallID = ""
        public var version = ""             // the call row's version (ETag)
        public var hashes: [String: String] = [:]   // part ("call", "summary", ...) -> hash of the body last accepted
        public var meta: [String: String] = [:]     // call_type, audience, language: kept when the call ends
        public var skip = false             // Don't sync this call
        public var deletedElsewhere = false // the server answered 410: deleted on another device, never re-sent by itself
        public var error = ""
        public var syncedAt: Date?
        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func s(_ k: CodingKeys) -> String { (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil ?? "" }
            schema = (try? c.decodeIfPresent(Int.self, forKey: .schema)) ?? nil ?? 1
            callID = s(.callID); clientCallID = s(.clientCallID); version = s(.version); error = s(.error)
            hashes = (try? c.decodeIfPresent([String: String].self, forKey: .hashes)) ?? nil ?? [:]
            meta = (try? c.decodeIfPresent([String: String].self, forKey: .meta)) ?? nil ?? [:]
            skip = (try? c.decodeIfPresent(Bool.self, forKey: .skip)) ?? nil ?? false
            deletedElsewhere = (try? c.decodeIfPresent(Bool.self, forKey: .deletedElsewhere)) ?? nil ?? false
            syncedAt = (try? c.decodeIfPresent(Date.self, forKey: .syncedAt)) ?? nil
        }

        public static func load(_ path: String) -> State? {
            guard let d = FileManager.default.contents(atPath: path) else { return nil }
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            return try? dec.decode(State.self, from: d)
        }

        public func save(_ path: String) {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
            if let d = try? enc.encode(self) { try? d.write(to: URL(fileURLWithPath: path), options: .atomic) }
        }
    }

    public static func stem(_ transcript: String) -> String { transcript.hasSuffix(".md") ? String(transcript.dropLast(3)) : transcript }
    public static func statePath(transcript t: String) -> String { stem(t) + ".sync.json" }
    public static func sheetPath(transcript t: String) -> String { stem(t) + ".sheet.json" }

    /// "<device>-<file stem>": the same call from two Macs stays two calls, a repeat from one Mac stays one.
    public static func clientCallID(device: String, transcript: String) -> String {
        let base = ((stem(transcript) as NSString).lastPathComponent)
        let raw = device.prefix(36) + "-" + base
        let clean = raw.unicodeScalars.map { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || "._-".unicodeScalars.contains($0) ? Character($0) : "_" }
        return String(String(clean).prefix(200))
    }

    /// A project's local slug as the server takes it (letters, digits, dot, dash, underscore).
    public static func localSlug(_ slug: String) -> String {
        let s = String(slug.unicodeScalars.map { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)) ? Character($0) : "-" })
        return String((s.isEmpty ? "project" : s).prefix(100))
    }

    public static func json(_ o: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    public static func hash(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()

    /// PUT /v1/calls/{client_call_id}. No participants and no consent in this version: names stay on the Mac.
    public static func callBody(projectID: String, title: String, start: Date, durationS: Int, meta: [String: String],
                                appVersion: String) -> [String: Any] {
        func m(_ k: String, _ max: Int) -> String { String((meta[k] ?? "").prefix(max)) }
        return ["project_id": projectID, "title": String(title.prefix(300)), "started_at": iso.string(from: start),
                "duration_s": max(0, durationS), "call_type": m("call_type", 50), "audience": m("audience", 50),
                "language": m("language", 10), "app_version": String(appVersion.prefix(40))]
    }

    /// The call notes (<stem>.notes.md) are the summary; nil without notes.
    public static func summaryBody(notes: String?) -> [String: Any]? {
        guard let n = notes?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty else { return nil }
        return ["body_md": String(n.prefix(200_000)), "model": "claude-sonnet"]
    }

    public static func decisions(_ n: MeetingNotes.Notes?) -> [[String: Any]] {
        (n?.decisions ?? []).prefix(200).compactMap { i in
            let t = i.text.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : ["text": String(t.prefix(2000))]
        }
    }

    public static func tasks(_ n: MeetingNotes.Notes?) -> [[String: Any]] {
        (n?.actions ?? []).prefix(200).compactMap { i in
            let t = i.text.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : ["text": String(t.prefix(2000))]
        }
    }

    /// The Meeting Sheet as built for the call, if it is a JSON object under 1 MB.
    public static func sheetBody(_ data: Data?) -> [String: Any]? {
        guard let d = data, d.count < 1_000_000, let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        return ["sheet": o]
    }

    static func driveID(_ s: String) -> Bool { s.range(of: "^[A-Za-z0-9_-]{10,200}$", options: .regularExpression) != nil }
    static func driveLink(_ s: String) -> Bool {
        s.range(of: "^https://(drive|docs)\\.google\\.com/[^\\s]*$", options: .regularExpression) != nil && s.count <= 500
    }

    /// Links to the recording parts and the transcript copy in Google Drive (links only, never files).
    public static func assets(recording: RecordingMeta?, transcript: DriveTranscriptMeta?) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for p in recording?.parts ?? [] where driveID(p.driveID) && driveLink(p.driveLink) {
            var a: [String: Any] = ["kind": p.kind == "audio" ? "audio" : "video", "drive_file_id": p.driveID,
                                    "web_view_link": p.driveLink, "drive_kind": p.driveKind == "shared_drive" ? "shared_drive" : "my_drive"]
            if driveID(p.driveFolderID) { a["drive_folder_id"] = p.driveFolderID }
            if p.bytes > 0 { a["bytes"] = p.bytes }
            out.append(a)
        }
        if let t = transcript, driveID(t.fileID), driveLink(t.link) {
            var a: [String: Any] = ["kind": "transcript_md", "drive_file_id": t.fileID, "web_view_link": t.link,
                                    "drive_kind": t.kind == "shared_drive" ? "shared_drive" : "my_drive"]
            if driveID(t.folderID) { a["drive_folder_id"] = t.folderID }
            out.append(a)
        }
        return Array(out.prefix(20))
    }

    /// The parts whose body changed since the last accepted send, in the order they go out (the call first).
    public static func changed(_ bodies: [(String, Data)], state: State) -> [(String, Data)] {
        bodies.filter { state.hashes[$0.0] != hash($0.1) }
    }

    /// What a server answer means for the queue.
    public enum Outcome: Equatable { case ok, deletedElsewhere, stop(String), retryLater(String) }
    public static func outcome(status: Int, problem: String = "") -> Outcome {
        switch status {
        case 200, 201: return .ok
        case 410: return .deletedElsewhere
        case 0, 408, 429, 500...599: return .retryLater(problem.isEmpty ? "HTTP \(status)" : problem)
        default: return .stop(problem.isEmpty ? "HTTP \(status)" : problem)
        }
    }
}
