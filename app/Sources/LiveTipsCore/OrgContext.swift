import Foundation

/// 0.17.0 (server 0.7.0, D40, B6b contract 9 blocks 5-6, spec 3-4): the rest of an organization project's shared
/// context, beside the card (OrgProjectCard.swift) and the registers (OrgRegisters.swift):
/// - current state: markdown up to 8 KB with a version (`GET/PUT {base}/state`, If-Match from the second write on);
///   after a call with decisions or risks the app offers "Update the project state?" and shows the diff before it goes;
/// - the map of sources (`GET/POST/DELETE {base}/sources`): Drive folders and files, Notion pages and databases, URLs;
/// - the file index (`PUT/GET/DELETE {base}/index/{ref}`, `POST .../index/search`): name, type, time, a description up
///   to 600 characters and a bge-m3 embedding (1024), built on the Mac of someone with access;
/// - history with Restore (`GET {base}/history`, `POST .../history/{id}/restore`): card, state and sources.
/// Pure rules here (CoreChecks); the network and the views are in the app (OrgContextViews.swift).
public enum OrgContext {
    public static let stateLimit = 8192
    public static let descriptionLimit = 600
    public static let dimensions = 1024

    static func str(_ o: Any?) -> String { (o as? String) ?? "" }
    static func person(_ o: Any?) -> (id: String, name: String) {
        if let d = o as? [String: Any] { return (str(d["id"]).lowercased(), str(d["name"])) }
        return (str(o).lowercased(), "")
    }

    // MARK: current state

    public struct State: Equatable {
        public var body = ""
        public var version = "0"
        public var updatedByID = "", updatedByName = ""
        public var updatedAt: Date?
        public var changed = false
        public init(body: String = "", version: String = "0") { self.body = body; self.version = version }
        /// The first write needs no If-Match; every later one does (the server answers 428 without it).
        public var isNew: Bool { version == "0" }
    }

    public static func state(_ d: Data) -> State? {
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], o["body_md"] != nil || o["version"] != nil else { return nil }
        var s = State(body: str(o["body_md"]), version: (o["version"] as? String) ?? (o["version"] as? Int).map(String.init) ?? "0")
        let by = person(o["updated_by"])
        s.updatedByID = by.id; s.updatedByName = by.name
        s.updatedAt = OrgCard.date(o["updated_at"])
        s.changed = (o["changed"] as? Bool) == true
        return s
    }

    public static func fits(_ body: String) -> Bool { body.utf8.count <= stateLimit }

    public static func stateBody(_ body: String) -> Data { (try? JSONSerialization.data(withJSONObject: ["body_md": body])) ?? Data() }

    public static func stateHeaders(_ s: State) -> [String: String] { s.isNew ? [:] : ["If-Match": OrgCard.ifMatch(s.version)] }

    /// What a PUT answer means. 409: someone saved first; 428: the state exists already (read it again).
    public enum Outcome: Equatable { case saved, newer, tooLong, readOnly, gone, plan, failed(String) }
    public static func outcome(status: Int, problem: String = "") -> Outcome {
        switch status {
        case 200, 201: return .saved
        case 409, 412, 428: return .newer
        case 413: return .tooLong
        case 422: return problem.contains("8 KB") ? .tooLong : .failed(problem)
        case 403: return .readOnly
        case 404: return .gone
        case 402: return .plan
        default: return .failed(problem.isEmpty ? "HTTP \(status)" : problem)
        }
    }

    /// After a call: the state with this call's decisions and risks added under "## Recent" (newest first, no
    /// duplicates), cut to 8 KB by dropping the oldest lines of that part. The PM sees the diff and may edit.
    public static let recentHeading = "## Recent"
    public static func suggest(current: String, day: String, decisions: [String], risks: [String]) -> String {
        let clean = { (s: String) in s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }
        let new = decisions.map(clean).filter { !$0.isEmpty }.map { "- \(day): Decision: \($0)" }
            + risks.map(clean).filter { !$0.isEmpty }.map { "- \(day): Risk: \($0)" }
        var lines = current.components(separatedBy: "\n")
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        let at = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == recentHeading }
        var head: [String], recent: [String], tail: [String]
        if let at {
            head = Array(lines[..<at])
            let rest = Array(lines[(at + 1)...])
            let end = rest.firstIndex { $0.hasPrefix("## ") || $0.hasPrefix("# ") } ?? rest.count
            recent = rest[..<end].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            tail = Array(rest[end...])
        } else {
            head = lines; recent = []; tail = []
            if !head.isEmpty { head.append("") }
        }
        let have = Set(recent.map { $0.lowercased() })
        recent = new.filter { !have.contains($0.lowercased()) } + recent
        func build() -> String {
            var out = head + [recentHeading] + recent
            if !tail.isEmpty { out += [""] + tail }
            return out.joined(separator: "\n") + "\n"
        }
        var text = build()
        while !fits(text), !recent.isEmpty { recent.removeLast(); text = build() }
        return text
    }

    /// A line diff (longest common subsequence) for the preview before sending.
    public enum DiffLine: Equatable { case same(String), added(String), removed(String) }
    public static func diff(_ old: String, _ new: String) -> [DiffLine] {
        let a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
        let n = a.count, m = b.count
        guard n * m <= 400_000 else { return a.map { .removed($0) } + b.map { .added($0) } }
        var t = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                t[i][j] = a[i] == b[j] ? t[i + 1][j + 1] + 1 : max(t[i + 1][j], t[i][j + 1])
            }
        }
        var out: [DiffLine] = [], i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] { out.append(.same(a[i])); i += 1; j += 1 }
            else if t[i + 1][j] >= t[i][j + 1] { out.append(.removed(a[i])); i += 1 }
            else { out.append(.added(b[j])); j += 1 }
        }
        out += a[i...].map { .removed($0) } + b[j...].map { .added($0) }
        return out
    }

    /// Only the changed lines and up to `context` lines around them ("…" for what is skipped).
    public static func compact(_ d: [DiffLine], context: Int = 2) -> [DiffLine?] {
        let keep = Set(d.indices.filter { if case .same = d[$0] { return false }; return true }
            .flatMap { max(0, $0 - context)...min(d.count - 1, $0 + context) })
        var out: [DiffLine?] = []
        for i in d.indices {
            if keep.contains(i) { out.append(d[i]) } else if out.last != .some(nil) { out.append(nil) }
        }
        return out
    }

    // MARK: map of sources

    public enum SourceKind: String, CaseIterable { case driveFolder = "drive_folder", driveFile = "drive_file", notionPage = "notion_page", notionDB = "notion_db", url }

    public struct Source: Equatable, Identifiable {
        public var id = "", kind = SourceKind.url, ref = "", title = "", note = ""
        public var addedByID = "", addedByName = ""
        public var addedAt: Date?
        public init() {}
    }

    public static func sources(_ d: Data) -> [Source]? {
        guard let rows = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return nil }
        return rows.compactMap(source)
    }

    public static func source(_ o: [String: Any]) -> Source? {
        guard let id = o["id"] as? String, let k = SourceKind(rawValue: str(o["kind"])), !str(o["ref"]).isEmpty else { return nil }
        var s = Source()
        s.id = id.lowercased(); s.kind = k; s.ref = str(o["ref"]); s.title = str(o["title"]); s.note = str(o["note"])
        let by = person(o["added_by"]); s.addedByID = by.id; s.addedByName = by.name
        s.addedAt = OrgCard.date(o["added_at"])
        return s
    }

    /// What the PM pasted: a Drive folder or file, a Notion page or database, or another https link. Drive keeps only
    /// the id; Notion and links keep the URL.
    public static func recognize(_ input: String) -> (kind: SourceKind, ref: String)? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: s), u.scheme == "https", let host = u.host?.lowercased(), !host.isEmpty else { return nil }
        let parts = u.path.split(separator: "/").map(String.init)
        if host == "drive.google.com" {
            if let i = parts.firstIndex(of: "folders"), i + 1 < parts.count { return (.driveFolder, parts[i + 1]) }
            if let i = parts.firstIndex(of: "d"), i + 1 < parts.count { return (.driveFile, parts[i + 1]) }
            if let id = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value { return (.driveFile, id) }
        }
        if host == "docs.google.com", let i = parts.firstIndex(of: "d"), i + 1 < parts.count { return (.driveFile, parts[i + 1]) }
        if host == "notion.so" || host.hasSuffix(".notion.so") || host.hasSuffix(".notion.site") {
            let db = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "v" } == true
            return (db ? .notionDB : .notionPage, s)
        }
        return (.url, s)
    }

    public static func sourceBody(kind: SourceKind, ref: String, title: String, note: String) -> Data {
        CallSyncJSON.data(["kind": kind.rawValue, "ref": ref, "title": String(title.prefix(200)), "note": String(note.prefix(500))])
    }

    /// Where a source opens.
    public static func link(_ s: Source) -> URL? {
        switch s.kind {
        case .driveFolder: return URL(string: "https://drive.google.com/drive/folders/" + s.ref)
        case .driveFile: return URL(string: "https://drive.google.com/file/d/" + s.ref + "/view")
        default: return URL(string: s.ref).flatMap { $0.scheme == "https" ? $0 : nil }
        }
    }

    // MARK: file index

    public struct File: Equatable, Identifiable {
        public var ref = "", mime = ""
        public var name: String?, description: String?
        public var modified: Date?, indexedAt: Date?
        public var hasEmbedding = false
        public var indexedByID = "", indexedByName = ""
        public var score: Double?
        public var id: String { ref }
        public init() {}
        /// The one who indexed it left the organization: name and description cannot be opened; index it again.
        public var needsReindex: Bool { name == nil || description == nil }
    }

    public static func files(_ d: Data) -> [File]? {
        guard let rows = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return nil }
        return rows.compactMap(file)
    }

    public static func file(_ o: [String: Any]) -> File? {
        guard let ref = o["source_ref"] as? String, !ref.isEmpty else { return nil }
        var f = File()
        f.ref = ref; f.mime = str(o["mime"])
        f.name = o["name"] as? String; f.description = o["description"] as? String
        f.modified = OrgCard.date(o["modified_time"]); f.indexedAt = OrgCard.date(o["indexed_at"])
        f.hasEmbedding = (o["has_embedding"] as? Bool) == true
        let by = person(o["indexed_by"]); f.indexedByID = by.id; f.indexedByName = by.name
        f.score = (o["score"] as? Double) ?? (o["score"] as? Int).map(Double.init)
        return f
    }

    /// `{base}/index/{ref}`: the ref may hold "/", which stays a path separator; the rest is percent-encoded.
    public static func indexPath(_ base: String, ref: String) -> String {
        var allowed = CharacterSet.urlPathAllowed; allowed.remove(charactersIn: "?#%;")
        return base + "/index/" + (ref.addingPercentEncoding(withAllowedCharacters: allowed) ?? ref)
    }

    /// A description from the file's text: whitespace folded, at most 600 characters, cut at a word.
    public static func describe(_ text: String) -> String {
        let flat = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        guard flat.count > descriptionLimit else { return flat }
        let cut = String(flat.prefix(descriptionLimit - 1))
        if let sp = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: sp) > descriptionLimit / 2 { return String(cut[..<sp]) + "…" }
        return cut + "…"
    }

    public static func fileBody(name: String, mime: String, modified: Date?, description: String, embedding: [Double]?) -> Data {
        var o: [String: Any] = ["name": String(name.prefix(300)), "mime": String(mime.prefix(200)), "description": describe(description)]
        if let m = modified { o["modified_time"] = ISO8601DateFormatter().string(from: m) }
        if let e = embedding, e.count == dimensions { o["embedding"] = e }
        return CallSyncJSON.data(o)
    }

    /// `POST .../index/search`: words, or a vector when the local embedding engine made one.
    public static func searchBody(text: String, vector: [Double]? = nil, k: Int = 10) -> Data {
        var o: [String: Any] = ["k": min(50, max(1, k))]
        if let v = vector, v.count == dimensions { o["vector"] = v } else { o["text"] = String(text.prefix(200)) }
        return CallSyncJSON.data(o)
    }

    // MARK: history

    public struct Change: Equatable, Identifiable {
        public var id = "", entity = "", field = "", ref = ""
        public var at: Date?
        public var byID = "", byName = ""
        public var old: Any?, new: Any?
        public init() {}
        /// Card, state and sources come back; register items are changed in the registers (422).
        public var restorable: Bool { ["card", "state", "source"].contains(entity) }
        public static func == (a: Change, b: Change) -> Bool { a.id == b.id }
    }

    public static func history(_ d: Data) -> [Change]? {
        guard let rows = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return nil }
        return rows.compactMap { o in
            guard let id = (o["id"] as? String) ?? (o["id"] as? Int).map(String.init) else { return nil }
            var c = Change()
            c.id = id; c.entity = str(o["entity"]); c.field = str(o["field"]); c.ref = str(o["ref"])
            c.at = OrgCard.date(o["at"])
            let by = person(o["by"]); c.byID = by.id; c.byName = by.name
            c.old = o["old"].flatMap { $0 is NSNull ? nil : $0 }; c.new = o["new"].flatMap { $0 is NSNull ? nil : $0 }
            return c
        }
    }

    /// A short form of a value in a history row: text cut to `max`, a source by its title or ref, lists joined.
    public static func short(_ v: Any?, max: Int = 80) -> String {
        let s: String
        switch v {
        case nil: return ""
        case let t as String: s = t
        case let d as [String: Any]:
            if let t = d["title"] as? String, !t.isEmpty { s = t }
            else if let r = d["ref"] as? String { s = r }
            else if let t = d["text"] as? String { s = t }
            else { s = d.keys.sorted().map { "\($0): \(short(d[$0], max: 30))" }.joined(separator: ", ") }
        case let a as [Any]: s = a.map { short($0, max: 30) }.joined(separator: ", ")
        case let n as NSNumber: s = n.stringValue
        default: s = "\(v!)"
        }
        let flat = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
    }

    /// What the row says happened: "added", "removed" or "changed".
    public static func verb(_ c: Change) -> String {
        if c.entity == "source" { return c.old == nil ? "added" : (c.new == nil ? "removed" : "changed") }
        if c.entity == "item", c.field.hasSuffix(".deleted") { return "removed" }
        return "changed"
    }

    public static func restoreBody(old: Bool) -> Data { CallSyncJSON.data(["value": old ? "old" : "new"]) }
}

/// JSON bodies without depending on the call-sync helpers' order.
enum CallSyncJSON {
    static func data(_ o: [String: Any]) -> Data { (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data() }
}
