import AppKit
import LiveTipsCore

/// 0.10.1 (A2, roadmap п.9): "this call belongs to another project". A finished call moves at once (files, history,
/// register items, series, index); the live call changes its target at once (the Notion page and Home use the new
/// project) and its files move after the call, once nothing writes next to the transcript any more.
/// Core and tests: LiveTipsCore/CallReassign.swift. Spec: research/pacenote-reassign-spec-2026-11-14.md.
@MainActor
final class CallReassignService {
    static let shared = CallReassignService()
    static let changed = Notification.Name("PacenoteCallReassigned")

    struct Target { var target: String; var root: String; var name: String; var slug: String; var config: String; var workspace: String }

    private(set) var pending: [CallReassign.Pending] = []
    private var path: URL { AppPaths.support.appendingPathComponent("reassign-pending.json") }

    private init() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: path), let p = try? dec.decode([CallReassign.Pending].self, from: d) { pending = p }
    }

    /// "project:<slug>" or "workspace:<name>" -> the folder and the names the app writes.
    static func resolve(_ target: String, registry reg: ProjectRegistry = ProjectRegistry.load(from: AppPaths.projects)) -> Target? {
        if target.hasPrefix("project:"), let p = reg.projects.first(where: { "project:" + $0.slug == target }), !p.root.isEmpty {
            let ws = reg.workspaces.first { $0.projects.contains(p.slug) }?.name ?? ""
            return Target(target: target, root: p.root, name: p.name, slug: p.slug, config: p.config, workspace: ws)
        }
        if target.hasPrefix("workspace:"), let w = reg.workspaces.first(where: { "workspace:" + $0.name == target }), !w.root.isEmpty {
            return Target(target: target, root: w.root, name: w.name, slug: w.name.lowercased(), config: "", workspace: w.name)
        }
        return nil
    }

    /// The target ("project:<slug>" / "workspace:<name>") a call's folder belongs to now.
    static func currentTarget(of file: String) -> String? {
        let pw = PyTool.project(of: file)
        if let p = pw.project { return "project:" + p.slug }
        if let w = pw.workspace { return "workspace:" + w.name }
        return nil
    }

    func isLive(_ file: String) -> Bool {
        let ce = CallEngine.shared
        return ce.isRunning && (ce.lastFile == file || CallReassign.key(ce.lastFile ?? "") == CallReassign.key(file))
    }

    /// The project shown for a call whose move is still waiting (the live call).
    func pendingName(for file: String) -> String? { pending.first { $0.key == CallReassign.key(file) && $0.moved == nil }?.toName }

    /// Changes the call's project. Returns nil on success, else the reason for the PM.
    @discardableResult
    func change(file: String, to target: String) -> String? {
        guard let t = Self.resolve(target) else { return L("reassign.err.noFolder") }
        if isLive(file) {
            CallEngine.shared.retarget(root: t.root, slug: t.slug, workspace: t.workspace, config: t.config)
            pending.removeAll { $0.key == CallReassign.key(file) }
            if CallReassign.root(of: file) != t.root {
                pending.append(CallReassign.Pending(file: file, toRoot: t.root, toTarget: t.target, toName: t.name))
            }
            persist()
            UsageLog.log("call_reassign", ["when": "live"])
            NotificationCenter.default.post(name: Self.changed, object: nil, userInfo: ["file": file])
            return nil
        }
        let plan = CallReassign.plan(file: file, toRoot: t.root)
        if plan.sameProject { return nil }
        do {
            try CallReassign.apply(plan)
        } catch let f as CallReassign.Failure {
            return L("reassign.err.move", ["why": f.description])
        } catch { return error.localizedDescription }
        afterMove(old: file, new: plan.newFile, fromRoot: plan.fromRoot, to: t, live: false)
        UsageLog.log("call_reassign", ["when": "after", "files": plan.moves.count])
        return nil
    }

    /// Every 2 s from the menu bar: moves a waiting call once it is over and quiet; sweeps late files for 30 min.
    func tick() {
        guard !pending.isEmpty else { return }
        var changedAny = false
        for i in pending.indices.reversed() {
            var p = pending[i]
            guard let t = Self.resolve(p.toTarget) else { pending.remove(at: i); changedAny = true; continue }
            if p.moved == nil {
                let live = isLive(p.file)
                guard CallReassign.readyToMove(callLive: live, lastWrite: CallReassign.lastWrite(file: p.file)) else { continue }
                let plan = CallReassign.plan(file: p.file, toRoot: t.root)
                if plan.sameProject || plan.moves.isEmpty { pending.remove(at: i); changedAny = true; continue }
                do { try CallReassign.apply(plan) } catch {
                    CallEngine.shared.notify(L("reassign.err.move", ["why": "\(error)"]), level: .error)
                    pending.remove(at: i); changedAny = true; continue
                }
                afterMove(old: p.file, new: plan.newFile, fromRoot: plan.fromRoot, to: t, live: true)
                p.moved = Date()
                pending[i] = p
                changedAny = true
            } else if CallReassign.sweepDone(p) {
                pending.remove(at: i); changedAny = true
            } else {
                let moved = CallReassign.sweep(key: p.key, fromRoot: p.fromRoot, toRoot: t.root)
                if moved.contains(where: { $0.from.hasSuffix(".notes.md") || $0.from.hasSuffix(".notion.json") }) {
                    NotificationCenter.default.post(name: Self.changed, object: nil, userInfo: ["file": p.file])
                }
            }
        }
        if changedAny { persist() }
    }

    private func afterMove(old: String, new: String, fromRoot: String, to t: Target, live: Bool) {
        let title = CallHistory.shared.records.first { $0.file == old }?.title ?? CallHistory.renamedTitle(old) ?? ""
        CallHistory.shared.move(file: old, to: new, project: t.name)
        // the skill's transcript of the same call moved too: its record follows
        let twin = (old.hasSuffix(".app.md") ? String(old.dropLast(7)) + ".md" : nil)
        if let tw = twin { CallHistory.shared.move(file: tw, to: (new as NSString).deletingLastPathComponent + "/" + (tw as NSString).lastPathComponent, project: t.name) }
        CommitmentRegister.moveCall(old, from: (fromRoot as NSString).appendingPathComponent("live"),
                                    to: (t.root as NSString).appendingPathComponent("live"), project: t.slug, title: title)
        if !title.isEmpty { SeriesMemory.shared.retarget(title: title, to: t.target) }
        CallEngine.shared.callMoved(from: old, to: new, root: t.root, config: t.config)
        let meta = RecordingFiles.metaPath(transcript: new)
        if var m = RecordingMeta.load(meta) { m.project = t.name; m.save(meta) }
        IndexService.shared.reindex(fromRoot)
        IndexService.shared.reindex(t.root)
        NotionCallMove.after(file: new, oldRoot: fromRoot, to: t, live: live)
        NotificationCenter.default.post(name: Self.changed, object: nil, userInfo: ["file": new, "old": old])
    }

    private func persist() {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted]
        if pending.isEmpty { try? FileManager.default.removeItem(at: path); return }
        if let d = try? enc.encode(pending) { try? d.write(to: path, options: .atomic) }
    }
}

extension CallHistory {
    /// 0.10.1 (A2): the call's transcript moved to another project.
    func move(file: String, to new: String, project: String) {
        guard let i = records.firstIndex(where: { $0.file == file }) else { return }
        var r = records[i]
        r.file = new; r.project = project
        replace(at: i, with: r)
    }
}

extension SeriesMemory {
    /// 0.10.1 (A2): the next call of this series starts in the new project.
    func retarget(title: String, to target: String) { setTarget(forTitleKey: Self.titleKey(title), target) }
}
