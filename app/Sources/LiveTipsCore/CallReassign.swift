import Foundation

/// 0.10.1 (A2, roadmap п.9): moving a call to another project. A call's files live next to its transcript in
/// <project>/live (<stem>.md, .app.md, .brief.md, .tips.jsonl, .notes.md, .notion.json, <stem>.judge/ ...) and its
/// recording in <project>/video (<stem>.recording*.mp4|m4a|json). Changing the project moves all of them, the call's
/// items in the commitments register and the app's records; nothing is copied and nothing is deleted.
/// Spec: research/pacenote-reassign-spec-2026-11-14.md.
public enum CallReassign {
    public struct Move: Equatable, Codable {
        public var from: String
        public var to: String
        public init(from: String, to: String) { self.from = from; self.to = to }
    }

    public struct Plan: Equatable {
        public var file: String                 // the transcript as the app knows it
        public var newFile: String              // the same transcript in the new project
        public var key: String                  // the call's name without ".md" and ".app" (the skill's and the app's files)
        public var fromRoot: String
        public var toRoot: String
        public var moves: [Move] = []
        public var collisions: [String] = []    // files that already exist in the new project: nothing is moved then
        public var sameProject: Bool { fromRoot == toRoot }
        public var canApply: Bool { !sameProject && collisions.isEmpty && !moves.isEmpty }
        public init(file: String, newFile: String, key: String, fromRoot: String, toRoot: String) {
            self.file = file; self.newFile = newFile; self.key = key; self.fromRoot = fromRoot; self.toRoot = toRoot
        }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case sameProject, collision([String]), nothing, moveFailed(String, String)
        public var description: String {
            switch self {
            case .sameProject: return "the call is already in this project"
            case .collision(let c): return "already in the new project: " + c.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            case .nothing: return "no files of this call were found"
            case .moveFailed(let f, let e): return "could not move " + (f as NSString).lastPathComponent + ": " + e
            }
        }
    }

    /// "<root>/live/2026-11-14-1000-weekly-sync.app.md" -> "2026-11-14-1000-weekly-sync".
    public static func key(_ file: String) -> String {
        var n = (file as NSString).lastPathComponent
        if n.hasSuffix(".md") { n = String(n.dropLast(3)) }
        if n.hasSuffix(".app") { n = String(n.dropLast(4)) }
        return n
    }

    /// The project folder of a transcript (<root>/live/<file>).
    public static func root(of file: String) -> String {
        ((file as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
    }

    /// A file of the call: the transcript itself or a name that starts with the call's name and a dot
    /// ("weekly.md" and "weekly.app.tips.jsonl" yes, "weekly-sync.md" no).
    public static func belongs(_ name: String, key: String, video: Bool = false) -> Bool {
        guard !key.isEmpty else { return false }
        if video { return name.hasPrefix(key + ".recording") }
        return name.hasPrefix(key + ".")
    }

    /// What would move, without touching anything. `toRoot` is the new project's folder.
    public static func plan(file: String, toRoot: String, fm: FileManager = .default) -> Plan {
        let from = root(of: file)
        let k = key(file)
        var p = Plan(file: file, newFile: ((toRoot as NSString).appendingPathComponent("live") as NSString)
                        .appendingPathComponent((file as NSString).lastPathComponent),
                     key: k, fromRoot: from, toRoot: toRoot)
        guard !p.sameProject else { return p }
        for (sub, video) in [("live", false), ("video", true)] {
            let src = (from as NSString).appendingPathComponent(sub), dst = (toRoot as NSString).appendingPathComponent(sub)
            guard let names = try? fm.contentsOfDirectory(atPath: src) else { continue }
            for n in names.sorted() where belongs(n, key: k, video: video) {
                let m = Move(from: (src as NSString).appendingPathComponent(n), to: (dst as NSString).appendingPathComponent(n))
                if fm.fileExists(atPath: m.to) { p.collisions.append(m.to) }
                p.moves.append(m)
            }
        }
        return p
    }

    /// Moves every file of the plan. If one move fails, the ones already done go back and the error is thrown.
    @discardableResult
    public static func apply(_ p: Plan, fm: FileManager = .default) throws -> [Move] {
        if p.sameProject { throw Failure.sameProject }
        if !p.collisions.isEmpty { throw Failure.collision(p.collisions) }
        if p.moves.isEmpty { throw Failure.nothing }
        var done: [Move] = []
        for m in p.moves {
            do {
                try fm.createDirectory(atPath: (m.to as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try fm.moveItem(atPath: m.from, toPath: m.to)
                done.append(m)
            } catch {
                for d in done.reversed() { try? fm.moveItem(atPath: d.to, toPath: d.from) }
                throw Failure.moveFailed(m.from, error.localizedDescription)
            }
        }
        return done
    }

    /// After the move: files of the call that appeared in the old project later (a job that was still writing
    /// next to the old transcript, the notes or the judge). Moved too; a name that exists in the new project stays.
    @discardableResult
    public static func sweep(key k: String, fromRoot: String, toRoot: String, fm: FileManager = .default) -> [Move] {
        guard fromRoot != toRoot, !k.isEmpty else { return [] }
        var done: [Move] = []
        for (sub, video) in [("live", false), ("video", true)] {
            let src = (fromRoot as NSString).appendingPathComponent(sub), dst = (toRoot as NSString).appendingPathComponent(sub)
            guard let names = try? fm.contentsOfDirectory(atPath: src) else { continue }
            for n in names where belongs(n, key: k, video: video) {
                let m = Move(from: (src as NSString).appendingPathComponent(n), to: (dst as NSString).appendingPathComponent(n))
                guard !fm.fileExists(atPath: m.to) else { continue }
                try? fm.createDirectory(atPath: dst, withIntermediateDirectories: true)
                if (try? fm.moveItem(atPath: m.from, toPath: m.to)) != nil { done.append(m) }
            }
        }
        return done
    }

    /// A change made during the call: the target changes at once, the files move after the call, once nothing has
    /// written next to the transcript for `quiet` seconds; later sweeps catch files written after that.
    public struct Pending: Codable, Equatable {
        public var file: String
        public var toRoot: String
        public var toTarget: String             // "project:<slug>" or "workspace:<name>"
        public var toName: String
        public var requested: Date
        public var moved: Date?
        public init(file: String, toRoot: String, toTarget: String, toName: String, requested: Date = Date()) {
            self.file = file; self.toRoot = toRoot; self.toTarget = toTarget; self.toName = toName; self.requested = requested
        }
        public var key: String { CallReassign.key(file) }
        public var fromRoot: String { CallReassign.root(of: file) }
    }

    /// The newest change time among the call's files in its current project (nil: none found).
    public static func lastWrite(file: String, fm: FileManager = .default) -> Date? {
        let r = root(of: file), k = key(file)
        var newest: Date?
        for (sub, video) in [("live", false), ("video", true)] {
            let dir = (r as NSString).appendingPathComponent(sub)
            for n in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where belongs(n, key: k, video: video) {
                if let d = (try? fm.attributesOfItem(atPath: (dir as NSString).appendingPathComponent(n)))?[.modificationDate] as? Date,
                   newest == nil || d > newest! { newest = d }
            }
        }
        return newest
    }

    /// The call is over and its files have been quiet long enough to move.
    public static func readyToMove(callLive: Bool, lastWrite: Date?, now: Date = Date(), quiet: TimeInterval = 60) -> Bool {
        guard !callLive else { return false }
        guard let w = lastWrite else { return true }
        return now.timeIntervalSince(w) >= quiet
    }

    /// Sweeps go on for this long after the move (the notes and the Notion page can take a few minutes).
    public static func sweepDone(_ p: Pending, now: Date = Date(), window: TimeInterval = 30 * 60) -> Bool {
        guard let m = p.moved else { return false }
        return now.timeIntervalSince(m) > window
    }
}

extension CommitmentRegister {
    /// 0.10.1 (A2): the items of one call go with the call to another project. Their events (the add and every later
    /// op) are appended to the new register with the new project; the old register gets an op "move" per item, which
    /// the fold reads as "no longer here". Append-only on both sides. Returns the number of items moved.
    @discardableResult
    public static func moveCall(_ call: String, from: String, to: String, project: String, title: String = "") -> Int {
        guard path(folder: from) != path(folder: to) else { return 0 }
        let key = callKey(call)
        let events = readEvents(folder: from)
        func op(_ e: [String: Any]) -> String { (e["op"] as? String) ?? "" }
        var lastAdd: [String: Int] = [:], lastMove: [String: Int] = [:]
        for (i, e) in events.enumerated() {
            guard let id = e["id"] as? String else { continue }
            if op(e) == "add", callKey((e["call"] as? String) ?? "") == key { lastAdd[id] = i }
            if op(e) == "move" { lastMove[id] = i }
        }
        // the items of this call that are here now (an item moved out earlier and not back is skipped)
        let ids = Set(lastAdd.keys.filter { (lastMove[$0] ?? -1) < lastAdd[$0]! })
        guard !ids.isEmpty else { return 0 }
        let live = (to as NSString).lastPathComponent == fileName ? (to as NSString).deletingLastPathComponent : to
        var out: [[String: Any]] = []
        for (i, var e) in events.enumerated() {
            guard let id = e["id"] as? String, ids.contains(id), op(e) != "move", i > (lastMove[id] ?? -1) else { continue }
            e.removeValue(forKey: "v")
            if op(e) == "add" {
                e["project"] = project
                if !title.isEmpty { e["series"] = seriesKey(project: project, title: title) }
                if let c = e["call"] as? String, c.contains("/") { e["call"] = (live as NSString).appendingPathComponent((c as NSString).lastPathComponent) }
            }
            out.append(e)
        }
        append(folder: to, out)
        append(folder: from, ids.sorted().map { ["op": "move", "id": $0, "to": project, "at": nowISO()] })
        return ids.count
    }
}
