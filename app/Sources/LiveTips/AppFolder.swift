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

    /// 0.26.3: a move asked while Pacenote installs its parts; it runs when the install ends (the first move's source,
    /// the last target).
    @MainActor private static var pending: (from: String, to: String)?

    /// Runs the move with the local engine stopped, then tells the PM what happened.
    @MainActor
    static func relocate(from old: String, to new: String) {
        if CallEngine.shared.isRunning {
            say(L("af.notMoved"), L("af.callRunning"), level: .error)
            return
        }
        // 0.26.3 (beta report 20.11): a move during the install split the parts between two folders
        if SetupWindow.model.holdsAppFolder {     // an install or a check of the parts is running
            pending = (pending?.from ?? old, new)
            AppLog.app("app folder: the move waits for the install to end")
            return
        }
        LocalAIService.shared.stop()
        let r = move(from: old, to: new)
        if !r.moved.isEmpty { afterMove(from: old, to: new, moved: r.moved) }
        LocalAIService.shared.apply()
        AppLog.app("app folder: moved \(r.moved.count), left \(r.skipped.count)" + (r.error.map { ", error " + $0 } ?? ""))
        if let e = r.error { say(L("af.notMoved"), e, level: .error); return }
        if r.moved.isEmpty && r.skipped.isEmpty { return }
        var text = L("af.movedTo", ["path": new]) + (r.moved.isEmpty ? L("af.nothing") : r.moved.joined(separator: ", ")) + "."
        if !r.skipped.isEmpty {
            text += "\n\n" + L("af.leftIn", ["path": old]) + r.skipped.joined(separator: ", ") + "."
        }
        say(L("af.moved"), text, level: r.skipped.isEmpty ? .info : .warning, folder: new)
    }

    /// 0.26.3: the move that waited for the install.
    @MainActor
    static func runPending() {
        guard let p = pending else { return }
        pending = nil
        relocate(from: p.from, to: p.to)
    }

    /// 0.26.3: after a move the engine paths point at the new folder at once (not at the next launch), the Python
    /// environment is relinked (it keeps absolute paths to the old folder), then the engine Python is checked and the
    /// parts are checked again; what is missing is installed (the same as Repair).
    @MainActor
    static func afterMove(from old: String, to new: String, moved: [String]) {
        SetupModel.editConfig { c in if let e = c.engine.rebased(from: old, to: new) { c.engine = e } }
        let setup = SetupWindow.model
        Task { @MainActor in
            if moved.contains(".venv") {
                var out = ""
                _ = await setup.run("relink", "venv") { out = $0 }
                AppLog.app("app folder: venv " + (out.hasPrefix("OK") ? "relinked" : "not relinked (\(out))"))
            }
            SetupModel.repairEnginePaths()
            await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in SetupModel.healEnginePython { _ in k.resume() } }
            await setup.checkAll()
            if !setup.allRequiredOK {
                AppLog.app("app folder: parts missing after the move, installing them")
                await setup.installMissing(includeOptional: false)
            }
        }
    }

    /// 0.26.0 (block 3): a notice in the app (Settings is open), not an alert; Show in Finder for the new folder.
    static func say(_ title: String, _ text: String, level: NoticeLevel, folder: String? = nil) {
        NoticeCenter.post(title + ". " + text, level: level, action: folder.map { .finder($0) })
    }
}
