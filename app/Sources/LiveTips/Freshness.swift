import AppKit
import LiveTipsCore

/// Pacenote 0.8 (F5, idea 03, instead of overnight preparation): is the brief still fresh? rules/freshness.json:
/// the files of the project folder (and the folders added in the call form) changed after the preparation was made.
/// Nothing runs by itself: the PM presses Refresh, which updates only what changed.
struct BriefFreshness {
    var preparedAt: Date
    var changes: [String]            // changed files, newest first
    var stale: Bool

    /// "2 days" / "5 h" / "40 min".
    var age: String {
        let s = Date().timeIntervalSince(preparedAt)
        if s >= 2 * 86400 { return L("fresh.days", ["n": "\(Int(s / 86400))"]) }
        if s >= 3600 { return L("fresh.hours", ["n": "\(Int(s / 3600))"]) }
        return L("fresh.minutes", ["n": "\(max(1, Int(s / 60)))"])
    }
    /// "Brief is 2 days old · 3 changes since" (REDESIGN-SPEC 4.2).
    var line: String { L(changes.isEmpty ? "fresh.lineOld" : "fresh.line", ["age": age, "n": "\(changes.count)"]) }
    var badge: String { L("fresh.badge", ["age": age]) }
}

@MainActor
enum Freshness {
    struct Rules { var ignore: [String]; var hidden: Bool; var maxFiles: Int; var staleHours: Double }
    private static var cache: [String: (Date, BriefFreshness?)] = [:]

    static let rules: Rules = {
        let p = Bundle.main.resourceURL?.appendingPathComponent("engine/rules/freshness.json")
        let o = p.flatMap { try? Data(contentsOf: $0) }.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        return Rules(ignore: (o["ignore"] as? [String]) ?? ["live/", ".livetips-index/", ".git/", "node_modules/", ".DS_Store", "Tools/"],
                     hidden: (o["ignore_hidden"] as? Bool) ?? true, maxFiles: (o["max_files_scanned"] as? Int) ?? 4000,
                     staleHours: (o["stale_after_hours"] as? Double) ?? 24)
    }()

    /// prepared_at from <base>.prep.json, else the brief file's creation time (an edit does not make it fresh).
    static func preparedAt(brief: String) -> Date? {
        let base = brief.hasSuffix(".brief.md") ? String(brief.dropLast(9)) : brief
        if let d = try? Data(contentsOf: URL(fileURLWithPath: base + ".prep.json")),
           let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let s = o["prepared_at"] as? String,
           let t = CommitmentRegister.iso(s) { return t }
        let a = try? FileManager.default.attributesOfItem(atPath: brief)
        return (a?[.creationDate] as? Date) ?? (a?[.modificationDate] as? Date)
    }

    /// Checked at most once a minute per brief (Home redraws every 2 s).
    static func check(brief: String, roots: [String], callDate: Date) -> BriefFreshness? {
        if let c = cache[brief], Date().timeIntervalSince(c.0) < 60 { return c.1 }
        let r = compute(brief: brief, roots: roots, callDate: callDate)
        cache[brief] = (Date(), r)
        return r
    }

    static func forget(_ brief: String) { cache[brief] = nil }

    static func compute(brief: String, roots: [String], callDate: Date) -> BriefFreshness? {
        guard let at = preparedAt(brief: brief) else { return nil }
        let fm = FileManager.default
        let skipDirs = Set(rules.ignore.filter { $0.hasSuffix("/") }.map { String($0.dropLast()) })
        let skipFiles = Set(rules.ignore.filter { !$0.hasSuffix("/") })
        var changed: [(String, Date)] = [], scanned = 0, seen = Set<String>()
        for root in roots where !root.isEmpty && seen.insert(root).inserted {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {                               // a single file added in the call form
                if let m = (try? fm.attributesOfItem(atPath: root))?[.modificationDate] as? Date, m > at { changed.append((root, m)) }
                continue
            }
            let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
            guard let en = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys,
                                         options: rules.hidden ? [.skipsHiddenFiles, .skipsPackageDescendants] : [.skipsPackageDescendants]) else { continue }
            for case let u as URL in en {
                let v = try? u.resourceValues(forKeys: Set(keys))
                if v?.isDirectory == true {
                    if skipDirs.contains(u.lastPathComponent) { en.skipDescendants() }
                    continue
                }
                if skipFiles.contains(u.lastPathComponent) { continue }
                scanned += 1
                if scanned > rules.maxFiles { break }
                if let m = v?.contentModificationDate, m > at { changed.append((u.path, m)) }
            }
        }
        changed.sort { $0.1 > $1.1 }
        let old = Date().timeIntervalSince(at) > rules.staleHours * 3600 && !Calendar.current.isDate(at, inSameDayAs: callDate)
        return BriefFreshness(preparedAt: at, changes: changed.map { $0.0 }, stale: !changed.isEmpty || old)
    }

    /// For a planned call: its brief and the folders it reads.
    static func check(_ m: StartCallModel) -> BriefFreshness? {
        guard let p = PrepDocWindow.path(for: m) else { return nil }
        let roots = (m.useProjectFolder ? [m.root ?? ""] : []) + m.folders
        return check(brief: p, roots: roots, callDate: m.callDate)
    }

    /// <base>.prep.json after a preparation or a refresh (rules/freshness.json > snapshot).
    nonisolated static func writeSnapshot(base: String, refreshOf: Date?) {
        let f = ISO8601DateFormatter(); f.timeZone = .current
        let o: [String: Any] = ["prepared_at": f.string(from: Date()), "by": "app", "refresh_of": refreshOf.map { f.string(from: $0) } ?? ""]
        if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: base + ".prep.json"), options: .atomic)
        }
    }
}

extension UpNext {
    /// Refresh: an incremental update of the brief from the files changed since it was made (never by itself).
    func refresh(_ m: StartCallModel) -> String? {
        guard let p = PrepDocWindow.path(for: m), var r = m.prepRequest() else { return L("call.chooseProjectFirst") }
        if PrepRunner.shared.running { return L("prep.err.running") }
        r.refreshBase = String(p.dropLast(9))
        r.refreshOf = Freshness.preparedAt(brief: p)
        r.changed = Array((Freshness.compute(brief: p, roots: (m.useProjectFolder ? [m.root ?? ""] : []) + m.folders, callDate: m.callDate)?.changes ?? []).prefix(30))
        Freshness.forget(p)
        m.prepFailed = false
        return PrepRunner.shared.start(r)
    }
}
