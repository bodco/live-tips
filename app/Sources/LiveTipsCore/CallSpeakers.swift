import Foundation

/// 0.26.2 (speakers on the call page): the transcript of a call with its speakers as the PM left them.
/// The raw transcript (<stem>.md) keeps the recorder's tags ("[10:00:24] Other [S2] (en): ..."); the names, merges
/// and line fixes live in .work/<stem>.speakers.json, the same data src/fromfile.py edit writes and named.md is made
/// from, so the page shows exactly what named.md says. Edits go through fromfile.py edit (args built here).
/// .work/<stem>.voices.json (written at the end of the call) holds the voice prints: without it the names change,
/// the voices library does not ("voices": false).
public struct CallSpeakers: Equatable {
    public struct Line: Identifiable, Equatable, Hashable {
        public var id: Int
        public var t: String
        public var label: String       // the label in the raw file ("Other", "Me")
        public var tag: String?        // the recorder's speaker id ("S2"), nil on untagged lines
        public var lang: String
        public var text: String
        public var me: Bool
        public init(id: Int, t: String, label: String, tag: String?, lang: String, text: String, me: Bool) {
            self.id = id; self.t = t; self.label = label; self.tag = tag; self.lang = lang; self.text = text; self.me = me
        }
    }

    public struct Speaker: Identifiable, Equatable {
        public var id: String
        public var name: String?
        public var seconds: Double
        public var side: String?
        public var suggestions: [String]
        public var namedBy: String?     // "meet": named from the Google Meet record (not learned without the PM)
        public var remember: Bool
        public init(id: String, name: String?, seconds: Double, side: String?, suggestions: [String], namedBy: String?, remember: Bool) {
            self.id = id; self.name = name; self.seconds = seconds; self.side = side; self.suggestions = suggestions
            self.namedBy = namedBy; self.remember = remember
        }
        /// "Mike" or "Speaker 2" (the same fallback as named.md).
        public var display: String { name ?? "Speaker " + String(id.dropFirst()) }
    }

    public var lines: [Line] = []
    public var speakers: [Speaker] = []         // not merged away, in id order
    public var overrides: [String: String] = [:]
    public var merged: [String: String] = [:]
    /// The speakers file exists: the page can edit.
    public var editable = false
    /// Voice prints exist (a live call with voices.json, or a recording with prints in speakers.json).
    public var voices = false
    /// When the PM last changed the speakers (edited_at, epoch seconds), for "notes are out of date".
    public var editedAt: Double?

    public init() {}

    static let rx = try! NSRegularExpression(pattern: "^\\[(\\d\\d:\\d\\d:\\d\\d)\\]\\s+(.+?)(?:\\s+\\[(S\\d+)\\])?\\s+\\((\\w{2,})\\):\\s?(.*)$")

    /// md: the raw transcript; snapshot: speakers.json; voicesFile: voices.json (only remember/auto are read).
    public static func parse(md: String, snapshot: [String: Any]?, voicesFile: [String: Any]?, me: String) -> CallSpeakers {
        var s = CallSpeakers()
        for raw in md.split(separator: "\n", omittingEmptySubsequences: true) {
            let l = String(raw)
            guard let m = rx.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) else { continue }
            func g(_ i: Int) -> String { Range(m.range(at: i), in: l).map { String(l[$0]) } ?? "" }
            let label = g(2).trimmingCharacters(in: .whitespaces)
            s.lines.append(Line(id: s.lines.count, t: g(1), label: label, tag: g(3).isEmpty ? nil : g(3), lang: g(4), text: g(5), me: label == me))
        }
        guard let o = snapshot else { return s }
        s.editable = true
        s.overrides = (o["overrides"] as? [String: String]) ?? [:]
        s.merged = (o["merged"] as? [String: String]) ?? [:]
        s.editedAt = (o["edited_at"] as? NSNumber)?.doubleValue
        let cl = (o["clusters"] as? [String: [String: Any]]) ?? [:]
        let rem = (o["remember"] as? [String: Bool]) ?? [:]
        let auto = Set((voicesFile?["auto"] as? [String]) ?? [])
        let callRemember = (voicesFile?["remember"] as? Bool) ?? true
        s.voices = voicesFile != nil || cl.values.contains { !(($0["embs"] as? [Any]) ?? []).isEmpty }
        s.speakers = cl.keys.sorted { (Int($0.dropFirst()) ?? 0) < (Int($1.dropFirst()) ?? 0) }.filter { s.merged[$0] == nil }.map { sid in
            let c = cl[sid] ?? [:]
            let namedBy = c["named_by"] as? String
            // the default as fromfile.py edit learns it: a roster or Meet name, or a public call, waits for the PM
            let def = voicesFile == nil ? true : (callRemember && !auto.contains(sid) && namedBy != "meet")
            let name = (c["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Speaker(id: sid, name: name, seconds: (c["seconds"] as? NSNumber)?.doubleValue ?? 0, side: c["side"] as? String,
                           suggestions: ((c["suggestions"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String },
                           namedBy: namedBy, remember: rem[sid] ?? def)
        }
        return s
    }

    public func resolve(_ sid: String) -> String {
        var s = sid; var seen = Set<String>()
        while let n = merged[s], !seen.contains(s) { seen.insert(s); s = n }
        return s
    }

    /// The speaker a line belongs to now (its fix or its tag), nil for an untagged line nobody moved.
    public func owner(_ l: Line) -> String? {
        guard let s = overrides[l.t] ?? l.tag else { return nil }
        return resolve(s)
    }

    public func speaker(_ sid: String) -> Speaker? { speakers.first { $0.id == sid } }

    /// What the page shows as the line's speaker: the same label named.md has.
    public func display(_ l: Line) -> String {
        guard let s = owner(l) else { return l.label }
        return speaker(s)?.display ?? "Speaker " + String(s.dropFirst())
    }

    /// The line's speaker is the PM (the microphone, nobody moved it).
    public func isMe(_ l: Line) -> Bool { l.me && overrides[l.t] == nil }

    /// Speakers with at least one line, most lines first.
    public func ranked() -> [(sid: String, lines: Int)] {
        var n: [String: Int] = [:]
        for l in lines { if let s = owner(l) { n[s, default: 0] += 1 } }
        return n.sorted { $0.value != $1.value ? $0.value > $1.value : (Int($0.key.dropFirst()) ?? 0) < (Int($1.key.dropFirst()) ?? 0) }
            .map { ($0.key, $0.value) }
    }

    /// The speaker to whom a typed name belongs, if one of this call already has it (case-insensitive).
    public func sid(named name: String) -> String? {
        let k = name.trimmingCharacters(in: .whitespaces).lowercased()
        return speakers.first { ($0.name ?? "").lowercased() == k }?.id
    }

    /// The notes were written before the last speakers edit (B3: "Rewrite notes").
    /// 0.26.2 (B3): when the PM last changed the speakers (speakers.json edited_at), nil before any change.
    public static func editedAt(snapshot: [String: Any]?) -> Double? { (snapshot?["edited_at"] as? NSNumber)?.doubleValue }

    /// 0.26.2 (B3): callnotes arguments for Rewrite notes: the full notes again over the old ones, owners migrated.
    public static func rewriteArgs(md: String, model: String, aliases: [String], config: String?) -> [String] {
        ["-m", "livetips_m0.callnotes", "--md", md, "--model", model, "--lang", "auto", "--rewrite",
         "--aliases", aliases.joined(separator: ",")] + ((config?.isEmpty ?? true) ? [] : ["--project-config", config!])
    }

    public static func notesStale(editedAt: Double?, notesWritten: Date?) -> Bool {
        guard let e = editedAt, let n = notesWritten else { return false }
        return e > n.timeIntervalSince1970 + 1
    }

    // MARK: fromfile.py edit arguments

    public enum Edit: Equatable {
        case rename(String, String)          // S2 -> "Mike"
        case merge(String, into: String)
        case lineTo(String, sid: String)     // the line at hh:mm:ss belongs to S3
        case lineToName(String, String)      // ... to a person: a speaker with that name, or a new one
        case remember(String, Bool)
        case side(String, String)            // "team" / "client"

        public var args: [String] {
            switch self {
            case let .rename(sid, name): return ["--name", sid + "=" + name.trimmingCharacters(in: .whitespacesAndNewlines)]
            case let .merge(src, dst): return ["--merge", src + "=" + dst]
            case let .lineTo(t, sid): return ["--fix", t + "=" + sid]
            case let .lineToName(t, name): return ["--fix", t + "=@" + name.trimmingCharacters(in: .whitespacesAndNewlines)]
            case let .remember(sid, on): return ["--remember", sid + "=" + (on ? "on" : "off")]
            case let .side(sid, side): return ["--side", sid + "=" + side]
            }
        }
    }

    /// Renaming to a name another speaker of this call already has is the same person: a merge, not two Mikes.
    public func plan(rename sid: String, to name: String) -> Edit? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return nil }
        if let other = self.sid(named: n), other != sid { return .merge(sid, into: other) }
        return .rename(sid, n)
    }

    /// "Said by ..." with a typed name: an existing speaker of this call, otherwise a new one.
    public func plan(line t: String, to name: String) -> Edit? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return nil }
        if let s = sid(named: n) { return .lineTo(t, sid: s) }
        return .lineToName(t, n)
    }
}
