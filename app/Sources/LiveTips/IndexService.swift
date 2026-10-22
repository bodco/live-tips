import CoreServices
import Foundation
import LiveTipsCore

/// Keeps each project's search index (<project>/.livetips-index) fresh (M1 step 6).
/// - FSEvents watch the project folders (and their extra folders); a changed project is reindexed
///   after 60 s of quiet with `lt index <root>` (incremental: only new or changed files).
/// - Never during a call: the indexer is paused (SIGSTOP) while the recorder runs, so Whisper and the
///   tips engine keep the CPU, and continues (SIGCONT) after the call.
/// - One writer at a time per project: `lt index` and the recorder take the flock on
///   <root>/.livetips-index/lock (semantic.IndexLock), so the app, the recorder and the Cowork skill
///   never write the same index at once (the second one waits up to 2 min, then reports busy).
final class IndexService: @unchecked Sendable {
    nonisolated(unsafe) static let shared = IndexService()

    private var stream: FSEventStreamRef?
    private var roots: [String: [String]] = [:]          // project root -> watched folders (root + extras)
    private var changedAt: [String: Date] = [:]          // project root -> last change seen
    private var forced = Set<String>()
    private var running: Process?
    private var runningRoot: String?
    private var paused = false
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
        if r != roots { roots = r; restartStream() }
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

    private func changed(_ paths: [String]) {
        for path in paths where !Self.ignored(path) {
            for (root, watched) in roots where watched.contains(where: { path.hasPrefix($0 + "/") || path == $0 }) {
                changedAt[root] = Date()
            }
        }
    }

    private func tick() {
        guard enabled, !paused, !(running?.isRunning ?? false), !python.isEmpty else { return }
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
                self.results[root] = proc.terminationStatus == 0 ? "Updated \(f.string(from: Date()))" : "Failed, see logs/index.log"
                self.running = nil
                self.runningRoot = nil
            }
        }
        do { try p.run(); running = p; runningRoot = root } catch { results[root] = "Could not start: \(error.localizedDescription)" }
    }
}
