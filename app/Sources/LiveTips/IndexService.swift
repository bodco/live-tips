import CoreServices
import Foundation
import IOKit.ps
import LiveTipsCore

/// Keeps each project's search index (<project>/.livetips-index) fresh (M1 step 6).
/// - FSEvents watch the project folders (and their extra folders); a changed project is reindexed
///   after 60 s of quiet with `lt index <root>` (incremental: only new or changed files).
/// - Never during a call: the indexer is paused (SIGSTOP) while the recorder runs, so Whisper and the
///   tips engine keep the CPU, and continues (SIGCONT) after the call.
/// - One writer at a time per project: `lt index` and the recorder take the flock on
///   <root>/.livetips-index/lock (semantic.IndexLock), so the app, the recorder and the Cowork skill
///   never write the same index at once (the second one waits up to 2 min, then reports busy).
/// - 0.9.6: only on mains power. On battery nothing starts, and a running `lt index` gets SIGTERM: it
///   commits what it already embedded and the project runs again once the Mac is plugged in
///   (defaults key `indexOnBattery` = true turns this off). Changes in folders the index skips
///   (rules/index.yaml > skip_dirs, skip_dir_globs, hidden folders, each folder's .livetipsignore)
///   do not trigger a reindex.
final class IndexService: @unchecked Sendable {
    nonisolated(unsafe) static let shared = IndexService()

    private var stream: FSEventStreamRef?
    private var roots: [String: [String]] = [:]          // project root -> watched folders (root + extras)
    private var changedAt: [String: Date] = [:]          // project root -> last change seen
    private var forced = Set<String>()
    private var running: Process?
    private var runningRoot: String?
    private var paused = false
    private var stoppingForBattery = false
    private var ignores: [String: IgnoreList] = [:]      // watched folder -> its .livetipsignore
    private var timer: Timer?
    private(set) var results: [String: String] = [:]     // project root -> "Updated 14:05" / problem
    var appRoot = ""
    var python = ""
    var enabled = true                                   // Local AI on: the index needs the embedding engine

    /// Watches the projects whose index switch is on. Projects without an index yet are built once.
    func configure(projects: [Project], appRoot: String, python: String, enabled: Bool) {
        self.appRoot = appRoot
        self.python = python
        self.enabled = enabled
        var r: [String: [String]] = [:]
        for p in projects where p.index.enabled && !p.root.isEmpty && FileManager.default.fileExists(atPath: p.root) {
            r[p.root] = [p.root] + p.index.extra.filter { FileManager.default.fileExists(atPath: $0) }
            let idx = (p.root as NSString).appendingPathComponent(".livetips-index")
            if !FileManager.default.fileExists(atPath: idx) { forced.insert(p.root) }
        }
        if r != roots {
            roots = r
            ignores = [:]
            for w in r.values.flatMap({ $0 }) { ignores[w] = IgnoreList(folder: w) }
            restartStream()
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.tick() }
        }
    }

    func reindex(_ root: String) { forced.insert(root); tick() }
    func reindexAll() { roots.keys.forEach { forced.insert($0) }; tick() }
    var isIndexing: Bool { running?.isRunning ?? false }
    var indexingRoot: String? { isIndexing ? runningRoot : nil }

    /// Called by CallEngine when a call starts and ends.
    func pause() {
        paused = true
        if let p = running, p.isRunning { kill(p.processIdentifier, SIGSTOP) }
    }

    func resume() {
        paused = false
        if let p = running, p.isRunning { kill(p.processIdentifier, SIGCONT) }
        tick()
    }

    // MARK: - internals

    private func restartStream() {
        if let s = stream { FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s); stream = nil }
        let paths = roots.values.flatMap { $0 }
        guard !paths.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, n, pathsPtr, _, _ in
            guard let info else { return }
            let me = Unmanaged<IndexService>.fromOpaque(info).takeUnretainedValue()
            let arr = unsafeBitCast(pathsPtr, to: NSArray.self) as? [String] ?? []
            me.changed(Array(arr.prefix(n)))
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, cb, &ctx, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 5, flags) else { return }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
        stream = s
    }

    /// Changes inside the index itself, git internals and live transcripts do not count.
    static func ignored(_ path: String) -> Bool {
        ["/.livetips-index", "/.git/", "/node_modules/", "/live/", "/.DS_Store"].contains { path.contains($0) }
    }

    /// Same folder rules as recorder/src/semantic.py (rules/index.yaml > skip_dirs, skip_dir_globs, skip_hidden).
    static let skipDirs: Set<String> = [".git", "node_modules", "repos", "_archived", ".livetips-index", "__pycache__",
                                        ".venv", "venv", ".idea", ".vscode", ".Trash", ".cache", "Secrets", "secrets",
                                        "_to_delete", "_archive", "_Archive", "runs", "_judge", "worktrees"]
    static let skipDirGlobs = ["wt-*"]

    /// True when the change is under a folder the index never enters (checked on the folders of the path,
    /// relative to the watched folder; the file name itself is left to the indexer).
    static func skippedFolder(_ rel: [String]) -> Bool {
        rel.dropLast().contains { d in
            d.hasPrefix(".") || skipDirs.contains(d) || skipDirGlobs.contains { fnmatch($0, d, 0) == 0 }
        }
    }

    /// A small subset of .gitignore, same as semantic.load_ignore: `name` or `name/` at any depth,
    /// a slash inside or in front anchors the pattern to the folder, globs, # comments, no negation.
    struct IgnoreList {
        var names: [(String, Bool)] = []                 // (pattern, folders only)
        var anchored: [(String, Bool)] = []
        init(folder: String) {
            let f = (folder as NSString).appendingPathComponent(".livetipsignore")
            guard let text = try? String(contentsOfFile: f, encoding: .utf8) else { return }
            for line in text.components(separatedBy: .newlines) {
                var pat = line.trimmingCharacters(in: .whitespaces)
                if pat.isEmpty || pat.hasPrefix("#") || pat.hasPrefix("!") { continue }
                let dirOnly = pat.hasSuffix("/")
                while pat.hasSuffix("/") { pat.removeLast() }
                let lead = pat.hasPrefix("/")
                while pat.hasPrefix("/") { pat.removeFirst() }
                if pat.isEmpty { continue }
                if lead || pat.contains("/") { anchored.append((pat, dirOnly)) } else { names.append((pat, dirOnly)) }
            }
        }
        /// rel: path components relative to the folder; the last one may be a file or a folder.
        func matches(_ rel: [String]) -> Bool {
            guard !rel.isEmpty, !(names.isEmpty && anchored.isEmpty) else { return false }
            for i in 0..<rel.count {
                let isLast = i == rel.count - 1          // unknown kind: folder-only patterns still apply to parents
                for (pat, dirOnly) in names where (!dirOnly || !isLast) && fnmatch(pat, rel[i], 0) == 0 { return true }
                let prefix = rel[0...i].joined(separator: "/")
                for (pat, dirOnly) in anchored where (!dirOnly || !isLast) && fnmatch(pat, prefix, 0) == 0 { return true }
            }
            return false
        }
    }

    private func changed(_ paths: [String]) {
        for path in paths where !Self.ignored(path) {
            for (root, watched) in roots {
                guard let w = watched.first(where: { path.hasPrefix($0 + "/") || path == $0 }) else { continue }
                let rel = path == w ? [] : String(path.dropFirst(w.count + 1)).split(separator: "/").map(String.init)
                if rel.last == ".livetipsignore" {
                    ignores[w] = IgnoreList(folder: w)   // the list changed: reload it and reindex (files may drop out)
                    changedAt[root] = Date()
                    continue
                }
                if Self.skippedFolder(rel) || (ignores[w]?.matches(rel) ?? false) { continue }
                changedAt[root] = Date()
            }
        }
    }

    /// Mains power (desktops without a battery report AC too). Unknown counts as AC.
    static func onACPower() -> Bool {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(snap)?.takeUnretainedValue() else { return true }
        return (type as String) == kIOPMACPowerKey
    }

    private var powerOK: Bool { UserDefaults.standard.bool(forKey: "indexOnBattery") || Self.onACPower() }

    private func tick() {
        let power = powerOK
        if !power, !stoppingForBattery, let p = running, p.isRunning, let r = runningRoot {
            stoppingForBattery = true
            forced.insert(r)                             // runs again (incremental) once plugged in
            kill(p.processIdentifier, SIGTERM)           // lt index commits what it embedded, then exits
            // during a call the indexer is SIGSTOPped: it acts on SIGTERM when resume() continues it after the call
        }
        guard enabled, !paused, power, !(running?.isRunning ?? false), !python.isEmpty else { return }
        let lt = (appRoot as NSString).appendingPathComponent("bin/lt")
        guard FileManager.default.fileExists(atPath: lt) else { return }
        let quiet = changedAt.filter { Date().timeIntervalSince($0.value) > 60 }.map(\.key)
        guard let root = forced.first ?? quiet.first, let watched = roots[root] else {
            forced = forced.filter { roots[$0] != nil }
            return
        }
        forced.remove(root)
        changedAt[root] = nil
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = [lt, "index", root] + watched.dropFirst().flatMap { ["--extra", $0] }
        p.currentDirectoryURL = URL(fileURLWithPath: appRoot)
        let logPath = (appRoot as NSString).appendingPathComponent("logs/index.log")
        let log = FileHandle.forAppending(path: logPath)
        log?.write("== \(Date()) lt index \(root)\n".data(using: .utf8)!)
        p.standardOutput = log
        p.standardError = log
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                let f = DateFormatter(); f.dateFormat = "HH:mm"
                if self.stoppingForBattery {
                    self.stoppingForBattery = false      // keep the previous result; the root is queued again
                } else {
                    self.results[root] = proc.terminationStatus == 0 ? L("idx.updated", ["time": f.string(from: Date())]) : L("idx.failed")
                }
                self.running = nil
                self.runningRoot = nil
            }
        }
        do { try p.run(); running = p; runningRoot = root } catch { results[root] = L("idx.cantStart", ["err": error.localizedDescription]) }
    }
}
