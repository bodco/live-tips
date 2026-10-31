import AppKit
import LiveTipsCore
import SwiftUI

/// Pacenote 0.8.6 (D, rules/notion-tasks.yaml): the PM's Notion tasks in On you and the call window's On me, and the
/// link between the commitments register and Notion (Add to Notion tasks, ticks and closes both ways, Remove, the
/// automatic add after a call). Nothing is written to Notion without the PM's action or the switch he turned on.
@MainActor
final class NotionTasks: ObservableObject {
    static let shared = NotionTasks()

    struct Toast: Identifiable {
        let id = UUID()
        let text: String
        var undo: (() -> Void)? = nil
        var openURL = ""
        var isError = false
    }

    @Published private(set) var tasks: [NotionTask] = []
    @Published private(set) var syncedAt: Date?
    @Published var error = ""
    @Published var toast: Toast?
    @Published var mapNotice = ""            // a project without a Notion value ("Map <project> to send its tasks")
    @Published private(set) var busy = false
    @Published private(set) var version = 0
    private var timer: Timer?
    private var schema: [String: [String: Any]] = [:]
    private var schemaFor = ""
    private var pending: [[String: Any]] = []   // offline ticks: {"page": id, "properties": {...}}

    var settings: NotionTasksSettings { SettingsWindow.model.config.notionTasks }
    var token: String? { SecretStore(service: Bundle.main.bundleIdentifier ?? "io.github.example.livetips").get(.notionToken) }
    private var cachePath: String { (CallEngine.shared.appRoot as NSString).appendingPathComponent("state/notion-tasks.json") }

    private init() { loadCache() }

    // MARK: sync

    /// Home or the call window is open: refresh now and every 5 minutes while one of them is.
    func keepFresh() {
        refresh()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            MainActor.assumeIsolated {
                let homeOpen = HomeWindow.window?.isVisible == true
                if homeOpen || CallEngine.shared.isRunning { NotionTasks.shared.refresh() }
            }
        }
    }

    func refresh() {
        let s = settings
        guard s.ready, let t = token, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                await flushPending(t)
                var out: [NotionTask] = []
                var cursor: String?
                repeat {
                    var body: [String: Any] = ["page_size": 100]
                    let f = NotionTasksCore.filter(s)
                    if !f.isEmpty { body["filter"] = f }
                    if let c = cursor { body["start_cursor"] = c }
                    let r = try await NotionAPI.call(t, "POST", "/data_sources/\(s.database)/query", body)
                    out += ((r["results"] as? [[String: Any]]) ?? []).compactMap { NotionTasksCore.task($0, s) }
                    cursor = (r["has_more"] as? Bool) == true ? r["next_cursor"] as? String : nil
                } while cursor != nil && out.count < 1000
                tasks = out.filter { $0.open }
                syncedAt = Date()
                error = ""
                saveCache()
                await syncLinks(t, s)
                version += 1
            } catch {
                self.error = "Notion: " + error.localizedDescription
            }
        }
    }

    /// rules/notion-tasks.yaml > both_ways: a linked item closed or reopened in Notion follows in the register; a page
    /// removed in Notion unlinks the item, which stays open.
    private func syncLinks(_ t: String, _ s: NotionTasksSettings) async {
        let reg = Register.shared
        let openIds = Set(tasks.map { $0.id })
        let linked = reg.folders.flatMap { reg.items(in: $0) }.filter { !$0.notionPage.isEmpty && $0.status != "dropped" }
        for c in linked.prefix(80) {
            let inOpen = openIds.contains(c.notionPage)
            if c.status == "open" && inOpen { continue }
            if c.status == "done" && !inOpen && c.doneSource != "notion" { continue }   // closed here; Notion was told
            do {
                let p = try await NotionAPI.call(t, "GET", "/pages/\(c.notionPage)")
                if (p["in_trash"] as? Bool) == true || (p["archived"] as? Bool) == true {
                    if c.status == "open" { reg.mark(c, "unlink", source: "removed") }
                    continue
                }
                guard let task = NotionTasksCore.task(p, s) else { continue }
                if c.status == "open" && !task.open { reg.mark(c, "done", source: "notion") }
                if c.status == "done" && task.open { reg.mark(c, "reopen") }
            } catch let e as NSError where e.code == 404 {
                if c.status == "open" { reg.mark(c, "unlink", source: "removed") }
            } catch { continue }
        }
    }

    private func flushPending(_ t: String) async {
        var left: [[String: Any]] = []
        for p in pending {
            guard let id = p["page"] as? String else { continue }
            do { _ = try await NotionAPI.call(t, "PATCH", "/pages/\(id)", p["body"] as? [String: Any] ?? [:]) } catch { left.append(p) }
        }
        pending = left
    }

    private func loadCache() {
        guard let d = FileManager.default.contents(atPath: cachePath),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
        if let a = o["tasks"], let data = try? JSONSerialization.data(withJSONObject: a),
           let list = try? JSONDecoder().decode([NotionTask].self, from: data) { tasks = list }
        if let ts = o["synced"] as? Double { syncedAt = Date(timeIntervalSince1970: ts) }
        pending = (o["pending"] as? [[String: Any]]) ?? []
    }

    private func saveCache() {
        let list = (try? JSONSerialization.jsonObject(with: (try? JSONEncoder().encode(tasks)) ?? Data("[]".utf8))) ?? []
        let o: [String: Any] = ["tasks": list, "synced": (syncedAt ?? Date()).timeIntervalSince1970, "pending": pending]
        if let d = try? JSONSerialization.data(withJSONObject: o) {
            try? FileManager.default.createDirectory(atPath: (cachePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? d.write(to: URL(fileURLWithPath: cachePath))
        }
    }

    // MARK: what a list shows

    /// Tasks of a target ("<slug>" or "workspace:<name>"), or every task for nil (Home's "All projects").
    func tasks(for target: String?) -> [NotionTask] {
        let s = settings
        guard s.ready else { return [] }
        guard let target = target else { return tasks }
        let reg = ProjectRegistry.load(from: AppPaths.projects)
        if target.hasPrefix("workspace:") {
            let w = String(target.dropFirst(10))
            let slugs = reg.projects.filter { $0.workspace == w }.map { $0.slug }
            return NotionTasksCore.forCall(tasks, s, project: nil, workspaceProjects: slugs, workspace: w)
        }
        return NotionTasksCore.forCall(tasks, s, project: target)
    }

    func projectName(_ t: NotionTask) -> String {
        let reg = ProjectRegistry.load(from: AppPaths.projects)
        let names = NotionTasksCore.targets(t, settings).map { k -> String in
            k.hasPrefix("workspace:") ? String(k.dropFirst(10)) : (reg.projects.first { $0.slug == k }?.name ?? k)
        }
        return names.first ?? ""
    }

    func linkedCommitment(_ t: NotionTask) -> Commitment? {
        let reg = Register.shared
        return reg.folders.lazy.flatMap { reg.items(in: $0) }.first { $0.notionPage == t.id }
    }

    // MARK: actions

    /// A tick on a Notion task (or on a linked commitment): the tick value at once, Undo for 8 s.
    func tick(_ t: NotionTask, done: Bool = true) {
        UsageLog.log("notion_task_ticked")
        let s = settings
        guard let tok = token else { return }
        let before = t.tickBefore
        let value = done ? s.tickValue : (before.isEmpty || before == s.tickValue ? (s.conditions.first?.values.first ?? "") : before)
        let body: [String: Any] = ["properties": NotionTasksCore.tickPatch(s, value: value)]
        if done { tasks.removeAll { $0.id == t.id } }
        if let c = linkedCommitment(t) { Register.shared.mark(c, done ? "done" : "reopen") }
        Task {
            do {
                _ = try await NotionAPI.call(tok, "PATCH", "/pages/\(t.id)", body)
                if done {
                    toast = Toast(text: L("ntask.setTo", ["title": t.title, "value": s.tickValue]), undo: { [weak self] in
                        self?.untick(t, to: before)
                    })
                }
            } catch let e as NSError where e.code == 0 || e.domain == NSURLErrorDomain {
                pending.append(["page": t.id, "body": body]); saveCache()        // offline: sent when Notion answers
            } catch {
                if done { tasks.append(t) }
                if let c = linkedCommitment(t) { Register.shared.mark(c, done ? "reopen" : "done") }
                toast = Toast(text: L("ntask.refused", ["reason": error.localizedDescription]), isError: true)
            }
            version += 1
        }
    }

    private func untick(_ t: NotionTask, to value: String) {
        let s = settings
        guard let tok = token else { return }
        if !tasks.contains(where: { $0.id == t.id }) { tasks.append(t) }
        if let c = linkedCommitment(t) { Register.shared.mark(c, "reopen") }
        Task {
            _ = try? await NotionAPI.call(tok, "PATCH", "/pages/\(t.id)", ["properties": NotionTasksCore.tickPatch(s, value: value)])
            version += 1
        }
    }

    /// rules/notion-tasks.yaml > remove: out of On you, the page to the Notion trash (30 days), Undo for 8 s.
    func remove(pageId: String, title: String, commitment: Commitment?) {
        guard let tok = token else { return }
        let task = tasks.first { $0.id == pageId }
        tasks.removeAll { $0.id == pageId }
        if let c = commitment { Register.shared.mark(c, "drop") }
        Task {
            do {
                _ = try await NotionAPI.call(tok, "PATCH", "/pages/\(pageId)", ["in_trash": true])
                toast = Toast(text: L("ntask.removed"), undo: { [weak self] in
                    guard let self = self else { return }
                    if let t = task { self.tasks.append(t) }
                    if let c = commitment { Register.shared.mark(c, "reopen") }
                    Task { _ = try? await NotionAPI.call(tok, "PATCH", "/pages/\(pageId)", ["in_trash": false]); self.version += 1 }
                })
            } catch {
                toast = Toast(text: L("ntask.removeRefused"), openURL: task?.url ?? "", isError: true)
            }
            version += 1
        }
    }

    /// The data source's properties (cached per database) for the title property and the settings pickers.
    func properties(_ tok: String, _ ds: String) async throws -> [String: [String: Any]] {
        if schemaFor == ds, !schema.isEmpty { return schema }
        let r = try await NotionAPI.call(tok, "GET", "/data_sources/\(ds)")
        schema = (r["properties"] as? [String: [String: Any]]) ?? [:]
        schemaFor = ds
        return schema
    }

    /// The Notion values of a register item's project (rules/notion-tasks.yaml > project_by); nil when not mapped.
    func projectValues(slug: String) -> [String]? {
        let s = settings
        if s.projectProperty.isEmpty { return [] }
        if let v = s.projectMap[slug], !v.isEmpty { return v }
        let reg = ProjectRegistry.load(from: AppPaths.projects)
        if let w = reg.workspaces.first(where: { $0.name == slug || slug == "workspace:" + $0.name }), let v = s.projectMap["workspace:" + w.name], !v.isEmpty { return v }
        return nil
    }

    /// "Add to Notion tasks" on a commitment (owner me): a page, then op link. Returns the page id.
    @discardableResult
    func add(_ c: Commitment, quote: String = "", silent: Bool = false) async -> String? {
        let s = settings
        guard s.ready, c.mine, c.notionPage.isEmpty, let tok = token else { return nil }
        guard let pv = projectValues(slug: c.project) else {
            mapNotice = Register.shared.projectName(c)
            return nil
        }
        // rules/notion-tasks.yaml > after_call: the same project and 60% of the words is the same task: link it
        if let twin = tasks.first(where: { CommitmentRegister.similar($0.title, c.text) && (pv.isEmpty || !Set(pv).isDisjoint(with: $0.projectValues)) }) {
            CommitmentRegister.mark(folder: c.folder, id: c.id, op: "link", notionPage: twin.id)
            Register.shared.touch(c.folder)
            return twin.id
        }
        do {
            let props = try await properties(tok, s.database)
            let titleProp = props.first { ($0.value["type"] as? String) == "title" }?.key ?? "Name"
            let call = (c.call as NSString).lastPathComponent
            let when = c.createdDate.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .none) } ?? ""
            let title = Register.shared.callTitle(c) ?? call
            let source = L("ntask.fromCall", ["title": title, "date": when])
            let body = NotionTasksCore.newPage(s, title: c.text, projectValues: pv, due: CommitmentRegister.dueDate(c.due, from: c.createdDate ?? Date()).map { Self.day($0) } ?? "",
                                               source: source, quote: quote, titleProperty: titleProp)
            let r = try await NotionAPI.call(tok, "POST", "/pages", body)
            guard let id = r["id"] as? String else { return nil }
            CommitmentRegister.mark(folder: c.folder, id: c.id, op: "link", notionPage: id)
            Register.shared.touch(c.folder)
            if let t = NotionTasksCore.task(r, s) { tasks.append(t) }
            if !silent { toast = Toast(text: L("ntask.added", ["n": "1"])) }
            version += 1
            return id
        } catch {
            if !silent { toast = Toast(text: L("ntask.refused", ["reason": error.localizedDescription]), isError: true) }
            return nil
        }
    }

    static func day(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d) }

    /// rules/notion-tasks.yaml > after_call: every open item owned by me of this call goes to Notion, once.
    func afterCall(file: String) {
        let s = settings
        guard s.ready, s.autoAdd, token != nil else { return }
        let folder = (file as NSString).deletingLastPathComponent
        let key = CommitmentRegister.callKey(file)
        let items = CommitmentRegister.load(folder: folder).filter { $0.mine && $0.status == "open" && $0.notionPage.isEmpty && CommitmentRegister.callKey($0.call) == key }
        guard !items.isEmpty else { return }
        Task {
            var added: [String] = []
            for c in items { if let id = await add(c, silent: true) { added.append(id) } }
            guard !added.isEmpty, let tok = token else { return }
            toast = Toast(text: L("ntask.added", ["n": "\(added.count)"]), undo: { [weak self] in
                guard let self = self else { return }
                for c in CommitmentRegister.load(folder: folder) where added.contains(c.notionPage) {
                    CommitmentRegister.mark(folder: folder, id: c.id, op: "unlink", source: "undo")
                }
                Register.shared.touch(folder)
                self.tasks.removeAll { added.contains($0.id) }
                Task { for id in added { _ = try? await NotionAPI.call(tok, "PATCH", "/pages/\(id)", ["in_trash": true]) }; self.version += 1 }
            })
        }
    }

    // MARK: the call window

    /// The On me tab's two outside groups: open register items of this call's project (earlier calls) and its Notion
    /// tasks, as the page's setOnYou payload.
    func callPayload(folder: String, target: String?, callFile: String) -> [String: Any] {
        let key = CommitmentRegister.callKey(callFile)
        let reg = Register.shared
        let items = reg.items(in: folder).filter { $0.status == "open" && CommitmentRegister.callKey($0.call) != key }
        let notionIds = Set(tasks.map { $0.id })
        let open: [[String: Any]] = CommitmentRegister.sorted(items).prefix(20).compactMap { c in
            if !c.notionPage.isEmpty && notionIds.contains(c.notionPage) { return nil }    // shown once, as the Notion task
            return ["id": c.id, "text": c.text, "due": Register.dueText(c.due), "done": false, "mine": c.mine, "owner": c.owner,
                    "badge": "CALL", "note": c.notionNote]
        }
        let ts = tasks(for: target).prefix(30).map { t -> [String: Any] in
            ["id": t.id, "text": t.title, "due": t.due.isEmpty ? "" : Register.dueText(t.due), "done": false, "mine": true,
             "badge": "N", "status": t.status, "fromCall": linkedCommitment(t) != nil]
        }
        let reg2 = ProjectRegistry.load(from: AppPaths.projects)
        let pname = target.map { k in k.hasPrefix("workspace:") ? String(k.dropFirst(10)) : (reg2.projects.first { $0.slug == k }?.name ?? k) } ?? ""
        return ["open": open, "notion": Array(ts), "project": pname]
    }

    /// A tick or Remove from the call window, by id (a register id "c-..." or a Notion page id).
    func callAction(id: String, folder: String, op: String, done: Bool = true) {
        if id.hasPrefix("c-") {
            guard let c = Register.shared.items(in: folder).first(where: { $0.id == id }) else { return }
            if op == "remove" {
                if !c.notionPage.isEmpty { remove(pageId: c.notionPage, title: c.text, commitment: c) } else { Register.shared.mark(c, "drop") }
            } else if let t = tasks.first(where: { $0.id == c.notionPage }) { tick(t, done: done) }
            else { Register.shared.mark(c, done ? "done" : "reopen") }
            return
        }
        guard let t = tasks.first(where: { $0.id == id }) else { return }
        if op == "remove" { remove(pageId: t.id, title: t.title, commitment: linkedCommitment(t)) } else { tick(t, done: done) }
    }
}
