import AppKit
import SwiftUI
import LiveTipsCore

/// 0.9.0 (redesign): the PM's open items (commitments from calls and Notion tasks), moved off Home. Shown on the
/// Tracker screen until the Tracker module replaces it (phase 3); the logic is the old Home "On you" unchanged.
struct OnYouView: View {
    @ObservedObject var register = Register.shared
    @ObservedObject var ntasks = NotionTasks.shared
    @AppStorage("onYouFilter") private var onYouFilter = ""
    @AppStorage("onYouHidden") private var onYouHidden = ""
    @State private var onYouAll = false

    var body: some View { onYouSection.onAppear { register.importOnce(); ntasks.keepFresh() } }

    /// REDESIGN-SPEC 4.4 + idea 01: the PM's open commitments from every call, overdue first. The tick closes the item
    /// in the register; the context menu copies it, opens the call or drops what is not a commitment.
    /// 0.8.6 (D3, rules/notion-tasks.yaml > on_you): one list with the PM's Notion tasks, a source badge, a project filter.
    private enum OnYouRow: Identifiable {
        case commit(Commitment), task(NotionTask, Commitment?)
        var id: String { switch self { case .commit(let c): return c.id; case .task(let t, _): return t.id } }
        var due: String { switch self { case .commit(let c): return c.due; case .task(let t, let c): return t.due.isEmpty ? (c?.due ?? "") : t.due } }
        var created: Date? { switch self { case .commit(let c): return c.createdDate; case .task(let t, let c): return c?.createdDate ?? CommitmentRegister.iso(t.created) } }
    }

    private func onYouRows() -> [OnYouRow] {
        let hidden = Set(onYouHidden.split(separator: ",").map(String.init))
        let target: String? = onYouFilter.isEmpty ? nil : onYouFilter
        let tasks = ntasks.tasks(for: target)
        let taskIds = Set(tasks.map { $0.id })
        let reg = ProjectRegistry.load(from: AppPaths.projects)
        let inScope: (Commitment) -> Bool = { c in
            guard let t = target else { return true }
            if t.hasPrefix("workspace:") {
                let w = String(t.dropFirst(10))
                return c.project == w || reg.projects.first { $0.slug == c.project }?.workspace == w
            }
            return c.project == t
        }
        var rows: [OnYouRow] = register.open(mine: true).filter { inScope($0) && !($0.notionPage.isEmpty == false && taskIds.contains($0.notionPage)) }.map { .commit($0) }
        rows += tasks.map { t in .task(t, ntasks.linkedCommitment(t)) }
        rows = rows.filter { !hidden.contains($0.id) }
        let now = Date()
        func due(_ r: OnYouRow) -> Date? { CommitmentRegister.dueDate(r.due, from: r.created ?? now) }
        return rows.sorted { a, b in
            let da = due(a), db = due(b)
            let oa = (da.map { $0 < Calendar.current.startOfDay(for: now) } ?? false), ob = (db.map { $0 < Calendar.current.startOfDay(for: now) } ?? false)
            if oa != ob { return oa }
            if (da != nil) != (db != nil) { return da != nil }
            if let x = da, let y = db, x != y { return x < y }
            return (a.created ?? .distantPast) > (b.created ?? .distantPast)
        }
    }

    private func hideHere(_ id: String) { onYouHidden = (onYouHidden.isEmpty ? "" : onYouHidden + ",") + id }

    private var onYouFilterMenu: some View {
        let reg = ProjectRegistry.load(from: AppPaths.projects)
        let label = onYouFilter.isEmpty ? L("ntask.allProjects")
            : onYouFilter.hasPrefix("workspace:") ? String(onYouFilter.dropFirst(10)) : (reg.projects.first { $0.slug == onYouFilter }?.name ?? onYouFilter)
        return Picker(L("home.filter.project"), selection: Binding(get: { onYouFilter }, set: { onYouFilter = $0 })) {   // 0.8.7 (J4)
            Text(L("ntask.allProjects")).tag("")
            ForEach(reg.projects.filter { $0.status != "archived" }, id: \.slug) { p in Text(p.name).tag(p.slug) }
            ForEach(reg.workspaces, id: \.name) { w in Text(w.name).tag("workspace:" + w.name) }
        }
        .pickerStyle(.menu).fixedSize().font(PN.Font.caption).help(label)
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .bold)).foregroundStyle(PN.C.text2)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(PN.C.surface2, in: RoundedRectangle(cornerRadius: 4))
    }

    private var onYouSection: some View {
        let items = onYouRows()
        let df = DateFormatter(); df.dateFormat = "d MMM"
        df.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US")
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("home.onYou")).font(PN.Font.section).foregroundStyle(PN.C.text)
                if !items.isEmpty { Text("\(items.count)").font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.onMe) }
                Spacer()
                onYouFilterMenu
            }
            if !ntasks.mapNotice.isEmpty {
                HStack {
                    Text(L("ntask.mapNotice", ["project": ntasks.mapNotice])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    Spacer()
                    Button(L("ntask.mapSet")) { ntasks.mapNotice = ""; SettingsWindow.show(tab: "notion") }.buttonStyle(.pnTertiary)
                    Button { ntasks.mapNotice = "" } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(PN.C.text3)
                }
            }
            if let t = ntasks.toast {
                HStack(spacing: 8) {
                    Text(t.text).font(PN.Font.caption).foregroundStyle(t.isError ? PN.C.danger : PN.C.text2)
                    Spacer()
                    if let u = t.undo { Button(L("ntask.undo")) { u(); ntasks.toast = nil }.buttonStyle(.pnTertiary) }
                    if !t.openURL.isEmpty, let url = URL(string: t.openURL) { Button(L("ntask.open")) { NSWorkspace.shared.open(url) }.buttonStyle(.pnTertiary) }
                }
                .task(id: t.id) { try? await Task.sleep(nanoseconds: 8_000_000_000); if ntasks.toast?.id == t.id { ntasks.toast = nil } }
            }
            if items.isEmpty {
                Text(L("home.onYou.empty")).font(PN.Font.body).foregroundStyle(PN.C.text3)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(onYouAll ? items : Array(items.prefix(8))) { r in onYouRow(r, df) }
                    // 0.8.6 (owner): the whole list opens in place (the column scrolls), never a scroll inside the card
                    if items.count > 8 {
                        Button(onYouAll ? L("ntask.showLess") : L("ntask.showAll", ["n": "\(items.count)"])) { onYouAll.toggle() }
                            .buttonStyle(.pnTertiary).padding(.top, 4)
                    }
                }
                .id("\(register.version)-\(ntasks.version)")
            }
            if !ntasks.error.isEmpty { Text(ntasks.error).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(1) }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.m))
    }

    @ViewBuilder private func onYouRow(_ r: OnYouRow, _ df: DateFormatter) -> some View {
        switch r {
        case .commit(let c):
            let overdue = CommitmentRegister.isOverdue(c)
            let when = c.createdDate.map { df.string(from: $0) } ?? ""
            // 0.8.7 (J4): the project once (not when the text names it), only the due date red
            let pn = register.projectName(c)
            let sub = [c.text.lowercased().contains(pn.lowercased()) ? "" : pn, when.isEmpty ? "" : L("reg.promised", ["date": when]),
                       c.notionNote == "removed" ? L("ntask.pageRemoved") : ""]
                .filter { !$0.isEmpty }.joined(separator: " · ")
            let dueS = c.due.isEmpty ? "" : (overdue ? L("reg.overdue", ["due": Register.dueText(c.due)]) : L("reg.due", ["due": Register.dueText(c.due)]))
            HStack(alignment: .top, spacing: 8) {
                Toggle("", isOn: Binding(get: { false }, set: { _ in register.mark(c) }))
                    .toggleStyle(.checkbox).labelsHidden()
                    .accessibilityLabel(L("reg.markDoneA11y", ["text": c.text]))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        badge(L("ntask.badgeCall"))
                        Text(c.text).font(PN.Font.body).foregroundStyle(PN.C.text).fixedSize(horizontal: false, vertical: true)
                    }
                    (Text(sub).foregroundColor(PN.C.text3) + Text((sub.isEmpty || dueS.isEmpty ? "" : " · ") + dueS).foregroundColor(overdue ? PN.C.danger : PN.C.text3))
                        .font(PN.Font.caption)
                }
                Spacer(minLength: 0)
                RemoveButton { register.mark(c, "drop") }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if let f = register.transcript(c) { NSWorkspace.shared.open(URL(fileURLWithPath: f)) } }
            .help(L("home.onYou.help"))
            .contextMenu {
                Button(L("reg.copy")) { register.copyText(c) }
                if let f = register.transcript(c) { Button(L("reg.openCall")) { NSWorkspace.shared.open(URL(fileURLWithPath: f)) } }
                if ntasks.settings.ready && c.notionPage.isEmpty { Button(L("ntask.addToNotion")) { Task { await ntasks.add(c) } } }
                Divider()
                Button(L("ntask.hideHere")) { hideHere(c.id) }
                Button(L("ntask.remove")) { register.mark(c, "drop") }
            }
        case .task(let t, let c):
            let dueD = CommitmentRegister.dueDate(t.due, from: Date())
            let overdue = dueD.map { $0 < Calendar.current.startOfDay(for: Date()) } ?? false
            let tpn = ntasks.projectName(t)
            let sub = [t.title.lowercased().contains(tpn.lowercased()) ? "" : tpn, t.status,
                       c != nil ? L("ntask.fromACall") : ""].filter { !$0.isEmpty }.joined(separator: " · ")
            let dueS = t.due.isEmpty ? "" : (overdue ? L("reg.overdue", ["due": Register.dueText(t.due)]) : L("reg.due", ["due": Register.dueText(t.due)]))
            HStack(alignment: .top, spacing: 8) {
                Toggle("", isOn: Binding(get: { false }, set: { _ in ntasks.tick(t) }))
                    .toggleStyle(.checkbox).labelsHidden()
                    .accessibilityLabel(L("reg.markDoneA11y", ["text": t.title]))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        badge(L("ntask.badgeNotion"))
                        Text(t.title).font(PN.Font.body).foregroundStyle(PN.C.text).fixedSize(horizontal: false, vertical: true)
                    }
                    (Text(sub).foregroundColor(PN.C.text3) + Text((sub.isEmpty || dueS.isEmpty ? "" : " · ") + dueS).foregroundColor(overdue ? PN.C.danger : PN.C.text3))
                        .font(PN.Font.caption)
                }
                Spacer(minLength: 0)
                RemoveButton { confirmRemove(t, c) }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if let u = URL(string: t.url) { NSWorkspace.shared.open(u) } }
            .contextMenu {
                Button(L("reg.copy")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t.title, forType: .string) }
                if let u = URL(string: t.url) { Button(L("ntask.openNotion")) { NSWorkspace.shared.open(u) } }
                if let c = c, let f = register.transcript(c) { Button(L("reg.openCall")) { NSWorkspace.shared.open(URL(fileURLWithPath: f)) } }
                Divider()
                Button(L("ntask.hideHere")) { hideHere(t.id) }
                Button(L("ntask.remove")) { confirmRemove(t, c) }
            }
        }
    }

    /// rules/notion-tasks.yaml > remove: a task made by hand in Notion asks once; one from a call does not.
    private func confirmRemove(_ t: NotionTask, _ c: Commitment?) {
        if c == nil {
            let a = NSAlert()
            a.messageText = L("ntask.trashQ", ["title": t.title])
            a.informativeText = L("ntask.trashInfo")
            a.addButton(withTitle: L("ntask.moveToTrash"))
            a.addButton(withTitle: L("hk.cancel"))
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        ntasks.remove(pageId: t.id, title: t.title, commitment: c)
    }

}
