import Foundation
import LiveTipsCore

/// 0.26.2 (call folders, B6): at launch every flat call of every active project, workspace and the app's own live/ moves
/// into its call folder (`CallLayout.migrate`: move only, nothing deleted or overwritten, a call written in the last
/// minutes is left for the next launch). The result goes to logs/app.log, counts and folder names only, never titles.
enum CallMigration {
    /// The live folders to migrate, each once: active projects, workspaces, and the app's own live/ when it has one.
    static func liveFolders(registry reg: ProjectRegistry, appRoot: String) -> [String] {
        var roots = reg.projects.filter { $0.status != "archived" && !$0.root.isEmpty }.map { $0.root }
        roots += reg.workspaces.filter { !$0.root.isEmpty }.map { $0.root }
        var seen = Set<String>(), out: [String] = []
        for r in roots {
            let f = (r as NSString).appendingPathComponent("live")
            if seen.insert(f).inserted { out.append(f) }
        }
        let own = (appRoot as NSString).appendingPathComponent("live")
        if seen.insert(own).inserted { out.append(own) }
        return out.filter { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: $0, isDirectory: &d) && d.boolValue }
    }

    /// One line per live folder with something to report (nothing when everything is already in folders).
    static func summary(_ r: CallLayout.Report, live: String, dryRun: Bool) -> String? {
        if r.isEmpty { return nil }
        let name = ((live as NSString).deletingLastPathComponent as NSString).lastPathComponent
        let calls = Set(r.moved.map { ($0.to as NSString).deletingLastPathComponent.replacingOccurrences(of: "/.work", with: "") }).count
        var s = "call folders\(dryRun ? " (dry run)" : ""): \(name): \(dryRun ? "would move" : "moved") \(r.moved.count) files of \(calls) calls"
        if !r.skippedBusy.isEmpty { s += ", \(r.skippedBusy.count) busy (next launch)" }
        if !r.conflicts.isEmpty { s += ", \(r.conflicts.count) conflicts left in live/" }
        if !r.failed.isEmpty { s += ", \(r.failed.count) failed" }
        return s
    }

    /// Runs off the main thread, a few seconds after launch (after the first scan). Safe to call twice.
    static func runAtLaunch(dryRun: Bool = false) {
        let reg = ProjectRegistry.load(from: AppPaths.projects)
        let folders = liveFolders(registry: reg, appRoot: AppLog.root)
        DispatchQueue.global(qos: .utility).async {
            var total = 0, moves: [CallLayout.Move] = []
            for live in folders {
                let r = CallLayout.migrate(live: live, dryRun: dryRun)
                total += r.moved.count; moves += r.moved
                if let line = summary(r, live: live, dryRun: dryRun) { AppLog.app(line) }
                for f in r.failed { AppLog.app("call folders: failed " + (f as NSString).lastPathComponent) }
            }
            if total > 0 && !dryRun {
                DispatchQueue.main.async { MainActor.assumeIsolated { CallHistory.shared.relocate(moves) } }
            }
        }
    }

    /// `--call-folders-dry-run <out.txt>`: what would move, per live folder and call, nothing touched. For the PM's eyes
    /// (call slugs are in it), so it goes to a file he names, not to the logs.
    static func preview(registry reg: ProjectRegistry, appRoot: String) -> String {
        var out = "Call folders: dry run, nothing moved (\(Date()))\n"
        for live in liveFolders(registry: reg, appRoot: appRoot) {
            let r = CallLayout.migrate(live: live, dryRun: true)
            out += "\n== \((live as NSString).deletingLastPathComponent)\n"
            if r.isEmpty { out += "  already in folders\n"; continue }
            var byDir: [String: Int] = [:]
            for m in r.moved { byDir[((m.to as NSString).deletingLastPathComponent).replacingOccurrences(of: "/.work", with: ""), default: 0] += 1 }
            for d in byDir.keys.sorted() { out += "  \((d as NSString).lastPathComponent)/  <- \(byDir[d]!) files\n" }
            out += "  total: \(r.moved.count) files, \(byDir.count) calls\n"
            if !r.skippedBusy.isEmpty { out += "  busy (written in the last minutes, next launch): \(r.skippedBusy.sorted().joined(separator: ", "))\n" }
            for c in r.conflicts { out += "  conflict, stays in live/: \((c as NSString).lastPathComponent)\n" }
        }
        return out
    }
}
