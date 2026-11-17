import AppKit
import SwiftUI
import LiveTipsCore

/// 0.10.1 (A3, roadmap п.9): where the PM changes a call's project. The same list as the project picker of Quick and
/// Expert (projects, then workspaces, with search). Opened from the call page header (a popover), the menu bar during a
/// call, Home > Recent calls ("Change project...") and the tips window ("Project: My calls · Change").
/// Spec: research/pacenote-reassign-spec-2026-11-14.md, section 4.
struct ProjectTargetList: View {
    let current: String
    let onPick: (String) -> Void
    @State private var search = ""
    private let registry = ProjectRegistry.load(from: AppPaths.projects)

    var body: some View {
        let q = search.lowercased()
        let ws = registry.workspaces.filter { q.isEmpty || $0.name.lowercased().contains(q) }
        let ps = registry.projects.filter { $0.status != "archived" && (q.isEmpty || $0.name.lowercased().contains(q)) }
        VStack(alignment: .leading, spacing: 6) {
            TextField("", text: $search, prompt: Text(L("call.findProject"))).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !ps.isEmpty { Text(L("stats.projects")).font(PN.Font.caption).foregroundStyle(PN.C.text3).padding(.top, 4) }
                    ForEach(ps, id: \.slug) { p in row("folder", p.name, p.workspace, "project:" + p.slug) }
                    if !ws.isEmpty { Text(L("stats.workspaces")).font(PN.Font.caption).foregroundStyle(PN.C.text3).padding(.top, 6) }
                    ForEach(ws, id: \.name) { w in row("square.stack.3d.up", w.name, L("call.generalCalls"), "workspace:" + w.name) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func row(_ symbol: String, _ name: String, _ sub: String, _ tag: String) -> some View {
        Button { onPick(tag) } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(PN.C.accent).frame(width: 18)
                Text(name).foregroundStyle(PN.C.text)
                if !sub.isEmpty { Text(sub).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
                Spacer()
                if current == tag { Image(systemName: "checkmark").foregroundStyle(PN.C.accent) }
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(current == tag ? PN.C.accent.opacity(0.12) : .clear))
        }
        .buttonStyle(.plain)
    }
}

/// The picker with its one-line explanation, for a popover or the small window.
struct ReassignPickerView: View {
    let file: String
    var done: () -> Void = {}

    var body: some View {
        Group {
        let live = CallReassignService.shared.isLive(file)
        VStack(alignment: .leading, spacing: 8) {
            Text(L("reassign.title")).font(PN.Font.body.weight(.semibold)).foregroundStyle(PN.C.text)
            Text(L(live ? "reassign.hint.live" : "reassign.hint")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                .fixedSize(horizontal: false, vertical: true)
            ProjectTargetList(current: CallReassignService.shared.target(for: file) ?? "") { tag in
                done()
                CallReassignUI.change(file: file, to: tag)
            }
        }
        .padding(12)
        .frame(width: 340, height: 380)
    }
        .trackScreen("reassign_panel")
    }
}

@MainActor
enum CallReassignUI {
    /// Changes the project and says why when it could not.
    static func change(file: String, to target: String) {
        guard CallReassignService.shared.target(for: file) != target else { return }
        if let err = CallReassignService.shared.change(file: file, to: target) {
            let a = NSAlert()
            a.messageText = L("reassign.failed")
            a.informativeText = err
            a.runModal()
        }
    }
}

/// The small floating window with the picker, for places without room for a popover (menu bar, Recent calls, tips).
@MainActor
enum ReassignPanel {
    static var window: NSWindow?

    static func show(file: String) {
        window?.close()
        let w = NSWindow(contentViewController: NSHostingController(rootView: Localized {
            ReassignPickerView(file: file, done: { window?.close() })
        }))
        w.styleMask = [.titled, .closable]
        w.title = CallPageView.title(file)
        w.isReleasedWhenClosed = false
        w.level = .floating          // above the tips window, which floats too
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension CallReassignService {
    /// The project a call is in for the PM: the waiting move's target (the live call), else its folder's.
    func target(for file: String) -> String? {
        pending.first { $0.key == CallReassign.key(file) && $0.moved == nil }?.toTarget ?? Self.currentTarget(of: file)
    }
}

/// 0.10.1 (A3): the call's Notion pages follow the new project (spec section 4.5).
/// One Meetings database (the F3 setting, or both configs name the same one): Project and Workspace rewritten on the same
/// page. Another database: the PM is asked first (a new page means a new summary, a model call), then a new page there
/// and "Moved to <url>" in the old one. Decisions and risks of this call: Project and Workspace on the same pages.
@MainActor
enum NotionCallMove {
    static func after(file: String, oldRoot: String, to t: CallReassignService.Target, live: Bool) {
        guard NotionAutoAdd.hasToken else { return }
        let c = AppConfig.load(from: AppPaths.config)
        let reg = ProjectRegistry.load(from: AppPaths.projects)
        let p = reg.projects.first { "project:" + $0.slug == t.target }
        let ws = reg.workspaces.first { "workspace:" + $0.name == t.target }
        func link(_ kind: String) -> [String] {
            p != nil ? NotionTargets.projectArgs(c, p, kind: kind) : NotionTargets.workspaceArgs(c, ws, kind: kind)
        }
        // A live call's meeting page is written after the call with the new project already (CallEngine.retarget).
        if !live {
            var a = ["--kind", "meetings", "--md", file] + link("meetings")
            if let u = CallHistory.shared.records.first(where: { $0.file == file })?.notionURL, !u.isEmpty { a += ["--page", u] }
            if !c.notionMeetingsDB.isEmpty { a += ["--meetings-db", c.notionMeetingsDB] }
            if let op = reg.projects.first(where: { $0.root == oldRoot }), !op.config.isEmpty { a += ["--from-config", op.config] }
            PyTool.run("notion_move", a, notion: true, needsAI: false) { r in
                if (r["other_db"] as? Bool) == true {
                    askNewPage(file: file, oldURL: (r["url"] as? String) ?? "", link: link("meetings"), c: c)
                } else if (r["ok"] as? Bool) != true {
                    CallEngine.shared.notify(failure(r))
                } else if (r["updated"] as? Int ?? 0) > 0 {
                    UsageLog.log("call_reassign_notion", ["kind": "meetings"])
                }
            }
        }
        for kind in ["decisions", "risks"] {
            PyTool.run("notion_move", ["--kind", kind, "--md", file] + link(kind), notion: true, needsAI: false) { r in
                if (r["ok"] as? Bool) != true {
                    CallEngine.shared.notify(failure(r))
                }
            }
        }
    }

    /// 0.13.2: a page the Notion integration cannot see (404) gets a fix the PM can do, not the raw error.
    private static func failure(_ r: [String: Any]) -> String {
        let why = (r["error"] as? String) ?? ""
        return why == "not_shared" ? L("reassign.notion.notShared") : L("reassign.notion.failed", ["why": why])
    }

    /// The new project keeps its meetings in another database: a new page there only when the PM says so.
    private static func askNewPage(file: String, oldURL: String, link: [String], c: AppConfig) {
        let a = NSAlert()
        a.messageText = L("reassign.notion.otherDB.title")
        a.informativeText = L("reassign.notion.otherDB.body")
        a.addButton(withTitle: L("reassign.notion.otherDB.yes"))
        a.addButton(withTitle: L("reassign.notion.otherDB.no"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        guard !c.engine.python.isEmpty else { return }
        let appRoot = c.effectiveAppRoot(appSupport: AppPaths.support.path)
        var args = ["--md", file, "--lt", c.engine.python, (appRoot as NSString).appendingPathComponent("bin/lt"),
                    "--model", c.models.analysis] + link
        if !c.notionMeetingsDB.isEmpty { args += ["--meetings-db", c.notionMeetingsDB] }
        let title = CallPageView.title(file)
        if !title.isEmpty { args += ["--title", title] }
        PyTool.run("wrapup_notion", args, notion: true) { r in
            if let usd = r["cost_usd"] as? Double, usd > 0 { SpendDays.add(usd); CallHistory.shared.addCost(file: file, usd) }
            guard (r["ok"] as? Bool) == true, let url = r["url"] as? String else {
                CallEngine.shared.notify(failure(r)); return
            }
            CallHistory.shared.setNotion(file: file, url: url)
            UsageLog.log("call_reassign_notion", ["kind": "new_page"])
            guard !oldURL.isEmpty else { return }
            PyTool.run("notion_move", ["--moved-to", url, "--page", oldURL, "--lang", L10n.lang == "uk" ? "uk" : "en"],
                       notion: true, needsAI: false) { _ in }
        }
    }
}
