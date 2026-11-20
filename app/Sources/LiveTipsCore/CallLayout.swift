import Foundation

/// Call folders (rules/call_layout.yaml, Bohdan 19.11.2026). A call used to leave ~30 loose files in <project>/live;
/// now every call lives in live/<YYYY-MM-DD>-<slug>/: the transcript, notes, brief and Meeting Sheet on top, every
/// service file in its .work/ subfolder. File names do not change. A file still directly in live/ keeps the old flat
/// rule, so a legacy path resolves as before. `migrate(live:)` moves old flat calls into folders (move only).
public enum CallLayout {
    public static let workDir = ".work"
    public static let visibleCall: Set<String> = [".md", ".app.md", ".notes.md", ".app.notes.md", ".brief.md", ".app.brief.md"]
    public static let visiblePrep: Set<String> = [".sheet.md"]
    public static let quietSeconds: TimeInterval = 600

    /// A call's file name split: "prep-2026-11-18-1515-pacenote-sync.sheet.json" ->
    /// (prep: true, date: "2026-11-18", key: "2026-11-18-1515-pacenote-sync", slug: "pacenote-sync", rest: ".sheet.json").
    public struct Name: Equatable {
        public var prep: Bool
        public var date: String
        public var key: String
        public var slug: String
        public var rest: String
        public var folder: String { CallLayout.folderName(date: date, slug: slug) }
        public var visible: Bool { prep ? CallLayout.visiblePrep.contains(rest) : CallLayout.visibleCall.contains(rest) }
    }

    private static let nameRE = try! NSRegularExpression(pattern: #"^(prep-)?(\d{4}-\d{2}-\d{2})-(\d{4})-([^.]+)(\..+)$"#)

    public static func parse(_ name: String) -> Name? {
        let ns = name as NSString
        guard let m = nameRE.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func g(_ i: Int) -> String { m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i)) }
        let date = g(2), slug = g(4)
        return Name(prep: !g(1).isEmpty, date: date, key: date + "-" + g(3) + "-" + slug, slug: slug, rest: g(5))
    }

    public static func folderName(date: String, slug: String) -> String { date + "-" + slug }

    /// A call folder is a direct subfolder of a "live" folder (live/<date>-<slug>), or its .work/.
    public static func isCallFolder(_ dir: String) -> Bool {
        let d = dir.hasSuffix("/") ? String(dir.dropLast()) : dir
        let name = (d as NSString).lastPathComponent
        if name == workDir { return isCallFolder((d as NSString).deletingLastPathComponent) }
        return name != "live" && ((d as NSString).deletingLastPathComponent as NSString).lastPathComponent == "live"
    }

    /// The folder a call or a prep with this title and date goes to; created with its .work/ when `create`.
    public static func folder(live: String, date: String, slug: String, create: Bool = false, fm: FileManager = .default) -> String {
        let f = (live as NSString).appendingPathComponent(folderName(date: date, slug: slug))
        if create { try? fm.createDirectory(atPath: (f as NSString).appendingPathComponent(workDir), withIntermediateDirectories: true) }
        return f
    }

    /// Where a file of the call called `name` lives, given the folder its transcript is in. In a call folder a service
    /// file goes to .work/; in live/ itself (a legacy flat call) everything stays next to the transcript.
    public static func place(_ name: String, in dir: String) -> String {
        var base = dir.hasSuffix("/") ? String(dir.dropLast()) : dir
        if (base as NSString).lastPathComponent == workDir { base = (base as NSString).deletingLastPathComponent }
        guard isCallFolder(base) else { return (base as NSString).appendingPathComponent(name) }
        let visible = parse(name)?.visible ?? false
        return visible ? (base as NSString).appendingPathComponent(name)
                       : ((base as NSString).appendingPathComponent(workDir) as NSString).appendingPathComponent(name)
    }

    /// The path of a sidecar: `stem` is the transcript without ".md" (".../X.app"), `suffix` what the code used to
    /// append (".tips.jsonl"). Replaces `stem + suffix` everywhere.
    public static func sidecar(_ stem: String, _ suffix: String) -> String {
        place((stem as NSString).lastPathComponent + suffix, in: (stem as NSString).deletingLastPathComponent)
    }

    /// The same for a full transcript path: sidecar(of: ".../X.app.md", ".tips.jsonl").
    public static func sidecar(of transcript: String, _ suffix: String) -> String {
        sidecar(transcript.hasSuffix(".md") ? String(transcript.dropLast(3)) : transcript, suffix)
    }

    /// The project's live folder for a transcript in either layout.
    public static func liveFolder(of file: String) -> String {
        let dir = (file as NSString).deletingLastPathComponent
        if (dir as NSString).lastPathComponent == workDir { return (((dir as NSString).deletingLastPathComponent) as NSString).deletingLastPathComponent }
        return isCallFolder(dir) ? (dir as NSString).deletingLastPathComponent : dir
    }

    /// Every visible call file of a live folder in both layouts (flat files in live/, then the files on top of each
    /// call folder), as full paths. What used to be contentsOfDirectory(live) for transcripts, notes and briefs.
    /// `includeWork`: also the service files in each call folder's .work/ (a scan for speakers, preps, tips).
    public static func files(live: String, includeWork: Bool = false, fm: FileManager = .default) -> [String] {
        var out: [String] = []
        for n in ((try? fm.contentsOfDirectory(atPath: live)) ?? []).sorted() where !n.hasPrefix(".") {
            let p = (live as NSString).appendingPathComponent(n)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir) else { continue }
            if !isDir.boolValue { out.append(p); continue }
            guard !n.contains("."), n.range(of: #"^\d{4}-\d{2}-\d{2}-"#, options: .regularExpression) != nil else { continue }   // a call folder (no dot), not a legacy .judge/
            for c in ((try? fm.contentsOfDirectory(atPath: p)) ?? []).sorted() where !c.hasPrefix(".") {
                let cp = (p as NSString).appendingPathComponent(c)
                out.append(cp)
            }
            if includeWork {
                let w = (p as NSString).appendingPathComponent(workDir)
                for c in ((try? fm.contentsOfDirectory(atPath: w)) ?? []).sorted() where !c.hasPrefix(".") { out.append((w as NSString).appendingPathComponent(c)) }
            }
        }
        return out
    }

    /// The preps in a live folder, `prep-*<suffix>`, in both layouts (flat in live/, and in a call folder or its .work/).
    public static func prepFiles(live: String, suffix: String, fm: FileManager = .default) -> [String] {
        files(live: live, includeWork: true, fm: fm).filter {
            let n = ($0 as NSString).lastPathComponent
            return n.hasPrefix("prep-") && n.hasSuffix(suffix)
        }
    }

    /// The full path of the prep file called `name` (prep-<date-time>-<slug>.brief.md), wherever it lives; nil when it is gone.
    public static func prepPath(live: String, name: String, fm: FileManager = .default) -> String? {
        prepFiles(live: live, suffix: name, fm: fm).first { ($0 as NSString).lastPathComponent == name }
    }

    // MARK: migration

    public struct Move: Equatable { public var from: String; public var to: String }
    public struct Report: Equatable {
        public var moved: [Move] = []
        public var conflicts: [String] = []     // a file with that name is already in the folder: left in live/
        public var skippedBusy: [String] = []   // keys written within `quietSeconds`: left for the next launch
        public var failed: [String] = []
        public var isEmpty: Bool { moved.isEmpty && conflicts.isEmpty && skippedBusy.isEmpty && failed.isEmpty }
    }

    /// Moves every flat call file of `live` into its call folder. Move only, nothing deleted or overwritten; running it
    /// again does nothing. A call any of whose flat files changed within `quiet` seconds is left for later.
    /// `dryRun`: touches nothing (no folder made, no file moved) and reports in `moved` what would move.
    @discardableResult
    public static func migrate(live: String, now: Date = Date(), quiet: TimeInterval = quietSeconds, dryRun: Bool = false, fm: FileManager = .default) -> Report {
        var r = Report()
        let names = ((try? fm.contentsOfDirectory(atPath: live)) ?? []).sorted()
        var byKey: [String: [(String, Name)]] = [:]
        for n in names { if let p = parse(n) { byKey[p.key, default: []].append((n, p)) } }
        for key in byKey.keys.sorted() {
            let items = byKey[key]!
            let busy = items.contains { n, _ in
                guard let d = (try? fm.attributesOfItem(atPath: (live as NSString).appendingPathComponent(n)))?[.modificationDate] as? Date else { return false }
                return now.timeIntervalSince(d) < quiet
            }
            if busy { r.skippedBusy.append(key); continue }
            for (n, p) in items {
                let dir = folder(live: live, date: p.date, slug: p.slug, create: !dryRun, fm: fm)
                let from = (live as NSString).appendingPathComponent(n), to = place(n, in: dir)
                if fm.fileExists(atPath: to) { r.conflicts.append(from); continue }
                if dryRun { r.moved.append(Move(from: from, to: to)); continue }
                do { try fm.moveItem(atPath: from, toPath: to); r.moved.append(Move(from: from, to: to)) }
                catch { r.failed.append(from + ": " + error.localizedDescription) }
            }
        }
        return r
    }
}
