import AppKit
import LiveTipsCore

/// Moves the app folder's contents (recorder core, its config, local model, state, logs, voices)
/// when the effective app folder changes in Settings. Nothing is overwritten: an item that already
/// exists at the new place stays where it was and is reported.
enum AppFolderMover {
    struct Result { var moved: [String] = []; var skipped: [String] = []; var error: String? }

    static func move(from old: String, to new: String) -> Result {
        var r = Result()
        let fm = FileManager.default
        let o = (old as NSString).standardizingPath, n = (new as NSString).standardizingPath
        guard o != n, fm.fileExists(atPath: o) else { return r }
        if n.hasPrefix(o + "/") || o.hasPrefix(n + "/") {
            r.error = L("af.inside")
            return r
        }
        do { try fm.createDirectory(atPath: n, withIntermediateDirectories: true) } catch {
            r.error = L("af.cantCreate", ["path": n, "err": error.localizedDescription])
            return r
        }
        let items = (try? fm.contentsOfDirectory(atPath: o)) ?? []
        for item in items where item != ".DS_Store" {
            let src = (o as NSString).appendingPathComponent(item), dst = (n as NSString).appendingPathComponent(item)
            if fm.fileExists(atPath: dst) { r.skipped.append(item); continue }
            do { try fm.moveItem(atPath: src, toPath: dst); r.moved.append(item) } catch {
                r.skipped.append(item + " (" + error.localizedDescription + ")")
            }
        }
        // Remove the old folder only when it is empty now (leftovers stay for the PM to check).
        if let left = try? fm.contentsOfDirectory(atPath: o), left.filter({ $0 != ".DS_Store" }).isEmpty {
            try? fm.removeItem(atPath: o)
        }
        return r
    }

    /// Runs the move with the local engine stopped, then tells the PM what happened.
    static func relocate(from old: String, to new: String) {
        if CallEngine.shared.isRunning {
            say(L("af.notMoved"), L("af.callRunning"), level: .error)
            return
        }
        LocalAIService.shared.stop()
        let r = move(from: old, to: new)
        LocalAIService.shared.apply()
        if let e = r.error { say(L("af.notMoved"), e, level: .error); return }
        if r.moved.isEmpty && r.skipped.isEmpty { return }
        var text = L("af.movedTo", ["path": new]) + (r.moved.isEmpty ? L("af.nothing") : r.moved.joined(separator: ", ")) + "."
        if !r.skipped.isEmpty {
            text += "\n\n" + L("af.leftIn", ["path": old]) + r.skipped.joined(separator: ", ") + "."
        }
        say(L("af.moved"), text, level: r.skipped.isEmpty ? .info : .warning, folder: new)
    }

    /// 0.26.0 (block 3): a notice in the app (Settings is open), not an alert; Show in Finder for the new folder.
    static func say(_ title: String, _ text: String, level: NoticeLevel, folder: String? = nil) {
        NoticeCenter.post(title + ". " + text, level: level, action: folder.map { .finder($0) })
    }
}
