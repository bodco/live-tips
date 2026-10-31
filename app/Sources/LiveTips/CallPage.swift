import AppKit
import SwiftUI
import LiveTipsCore

/// Pacenote 0.8 (F6): the page of a held call (REDESIGN-SPEC 4.4 "Recent: a click opens the call page"): what was
/// decided, what is on you and on them (the register), open questions, the agenda, the risks; then the follow-up
/// email, the transcript, Notion and the series. Everything is read from the call's own files.
/// 0.8.7 (A2): the call page is pushed into Home (HomeNav), not a window of its own.
@MainActor
enum CallPageWindow {
    static func show(file: String) { HomeNav.shared.open(.call(file)) }
}

struct CallPageView: View {
    let file: String
    @ObservedObject var register = Register.shared
    @ObservedObject var history = CallHistory.shared
    @ObservedObject var sync: CallPageSync
    @State private var note = ""
    @State private var added: [String: String] = [:]     // risk text -> its Notion page URL ("" when none came back)
    @State private var tick = 0
    @State private var cardDraft: AnswerCard? = nil     // 0.8.7 (H5): Save as answer card
    @ObservedObject private var sm = SalesMethods.shared

    init(file: String) {
        self.file = file
        _sync = ObservedObject(wrappedValue: CallPageSync.of(file))
    }

    /// A date format in the interface language.
    static func fmt(_ template: String) -> DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US"); f.setLocalizedDateFormatFromTemplate(template)
        return f
    }

    static func title(_ file: String) -> String {
        CallHistory.shared.records.first { $0.file == file }?.title
            ?? ((file as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    private var record: CallHistory.Record? { history.records.first { $0.file == file } }
    private var folder: String { (file as NSString).deletingLastPathComponent }
    private var items: [Commitment] {
        register.items(in: folder).filter { CommitmentRegister.callKey($0.call) == CommitmentRegister.callKey(file) && $0.status != "dropped" }
    }

    /// Earlier and later calls of the same meeting (same project, same title key).
    static func series(of r: CallHistory.Record) -> [CallHistory.Record] {
        let key = EditLog.seriesKey(r.title)
        return CallHistory.shared.visible.filter { EditLog.seriesKey($0.title) == key && $0.project == r.project }
    }

    var body: some View {
        let o = CallOutcome.read(transcript: file) ?? CallOutcome()
        let agenda = StartCallModel.agenda(transcript: file)
        let f = Self.fmt("EEEEdMMMMHHmm")
        let pw = PyTool.project(of: file)
        let proj = pw.project, ws = pw.workspace
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.title(file)).font(PN.Font.title).foregroundStyle(PN.C.text)
                    Text([record.map { f.string(from: $0.start) } ?? "", proj?.name ?? ws?.name ?? record?.project ?? "",
                          record?.minutes.map { L("call.page.minutes", ["n": "\(Int($0.rounded()))"]) } ?? ""]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    CallPageSyncLine(sync: sync)       // 0.8.7 (E5)
                }
                actions(proj, o)
                if !note.isEmpty { Text(note).font(PN.Font.caption).foregroundStyle(PN.C.onMe) }
                if o.isEmpty && items.isEmpty && agenda.isEmpty {
                    Text(L("call.page.empty")).font(PN.Font.body).foregroundStyle(PN.C.text3)
                }
                // 0.8.7 (E1, E2): every row is edited in place; "+ Add" under each section
                lines("decisions", L("call.page.decisions"), o.decisions, cardRoot: cardRoot(proj, ws)) { saveLists(o, decisions: $0, section: "decisions") }
                commitments(items.filter { $0.mine }, mine: true, legacy: items.isEmpty ? o.onMe : [], proj, ws)
                commitments(items.filter { !$0.mine }, mine: false, legacy: [], proj, ws)
                lines("open", L("call.page.open"), o.openQuestions) { saveLists(o, open: $0, section: "open") }
                agendaSection(agenda)
                risks(o, proj)
                salesSection(cardRoot(proj, ws))
            }
            .id(tick)
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(PN.C.bg)
        .sheet(item: $cardDraft) { c in
            AnswerCardForm(card: c, title: L("cards.saveAs"), onSave: { saveCard($0, proj, ws) }, onCancel: { cardDraft = nil })
        }
    }

    /// 0.8.7 (H5): where a card from this call goes: the project's folder, else the workspace's.
    private func cardRoot(_ proj: Project?, _ ws: Workspace?) -> String { proj?.root.isEmpty == false ? proj!.root : (ws?.root ?? "") }

    private func saveCard(_ c: AnswerCard, _ proj: Project?, _ ws: Workspace?) -> String? {
        if let e = AnswerCards.add(c, root: cardRoot(proj, ws)) { return e }
        cardDraft = nil
        note = L("cards.savedFrom", ["project": proj?.name ?? ws?.name ?? ""])
        return nil
    }

    private func saveCardAction(_ title: String, _ answer: String, root: String) -> PageRowAction {
        PageRowAction(title: L("cards.saveAs"), enabled: !root.isEmpty, note: L("cards.noRoot"),
                      run: { _ in cardDraft = AnswerCard(title: title, answer: answer) })
    }

    /// 0.8.7 (H6, H6.1): the Sales section and the scorecard (<stem>.sales.json), facts of the call only. Edited like
    /// the other sections: the criterion's state is a chip (a click moves it on), what is known and the next step are
    /// edited in place; an objection's menu has Save as answer card. Changes go to the Notion page's Sales heading.
    @ViewBuilder private func salesSection(_ root: String) -> some View {
        if let d = SalesFile.load(file) {
            let crit = (d["criteria"] as? [[String: Any]]) ?? []
            let objections = ((d["objections"] as? [Any]) ?? []).map { o -> [String: Any] in (o as? [String: Any]) ?? ["what": (o as? String) ?? ""] }
            let next = (d["next_step"] as? [String: Any]) ?? ["what": (d["next_step"] as? String) ?? ""]
            let sc = (d["scorecard"] as? [String: Any]) ?? [:]
            let method = sm.methods.first { $0.key == (d["method"] as? String) }
            let save: ([String: Any]) -> Void = { nd in SalesFile.save(file, nd); changed("sales") }
            VStack(alignment: .leading, spacing: 2) {
                heading(L("sales.section"))
                ForEach(Array(crit.enumerated()), id: \.offset) { i, c in
                    let key = (c["criterion"] as? String) ?? (c["key"] as? String) ?? ""
                    let name = method?.criteria.first { $0.key == key }?.name ?? (c["name"] as? String) ?? key
                    let what = (c["what"] as? String) ?? ""
                    let quote = (c["quote"] as? String) ?? ""
                    EditableRow(text: what.isEmpty ? L("sales.criterionPh") : what, sub: quote.isEmpty ? "" : "\u{201C}" + quote + "\u{201D}",
                                copy: name + ": " + what,
                                onSave: { v in var nd = d; var l = crit; if i < l.count { l[i]["what"] = v; if (l[i]["state"] as? String ?? "unknown") == "unknown" { l[i]["state"] = "partial" } }; nd["criteria"] = l; save(nd) },
                                leading: { Text(name).font(PN.Font.body.weight(.semibold)).foregroundStyle(PN.C.text).frame(minWidth: 90, alignment: .leading) },
                                trailing: {
                                    SalesStateChip(state: (c["state"] as? String) ?? "unknown") {
                                        var nd = d; var l = crit; if i < l.count { l[i]["state"] = SalesFile.nextState((l[i]["state"] as? String) ?? "unknown") }; nd["criteria"] = l; save(nd)
                                    }
                                })
                }
                ForEach(Array(objections.enumerated()), id: \.offset) { i, ob in
                    let what = (ob["what"] as? String) ?? ""
                    let ans = (ob["answer"] as? String) ?? ""
                    EditableRow(text: what, sub: ans.isEmpty ? "" : L("sales.answered", ["answer": ans]), copy: what + (ans.isEmpty ? "" : " -> " + ans),
                                menu: [saveCardAction(what, ans, root: root), .separator,
                                       PageRowAction(title: L("callEdit.delete"), destructive: true, run: { _ in
                                           var nd = d; var l = objections; if i < l.count { l.remove(at: i) }; nd["objections"] = l; save(nd) })],
                                onSave: { v in var nd = d; var l = objections; if i < l.count { l[i]["what"] = v }; nd["objections"] = l; save(nd) },
                                leading: { Text(L("sales.objection")).font(PN.Font.body.weight(.semibold)).foregroundStyle(PN.C.onMe) })
                }
                let nw = (next["what"] as? String) ?? "", due = (next["due"] as? String) ?? ""
                EditableRow(text: nw.isEmpty ? L("sales.nextPh") : nw, sub: due.isEmpty ? L("sales.noNext") : L("sales.due", ["due": due]),
                            subColor: due.isEmpty ? PN.C.onMe : PN.C.text3, copy: nw,
                            menu: [PageRowAction(title: L("callEdit.setDue"), prompt: .date(value: due), run: { v in
                                var nd = d; var n = next; n["due"] = v; nd["next_step"] = n; save(nd) })],
                            onSave: { v in var nd = d; var n = next; n["what"] = v; nd["next_step"] = n; save(nd) },
                            leading: { Text(L("sales.next")).font(PN.Font.body.weight(.semibold)).foregroundStyle(PN.C.text) })
                AddRowField(placeholder: L("sales.objection")) { v in
                    var nd = d; nd["objections"] = objections + [["what": v, "answer": "", "t": ""]]; save(nd)
                }
                Text(L("sales.scorecard", ["known": "\(crit.filter { ($0["state"] as? String) == "known" }.count)", "total": "\(crit.count)",
                                           "open": "\((sc["open_questions"] as? Int) ?? 0)",
                                           "share": (sc["pm_talk_share"] as? Double).map { "\(Int(($0 * 100).rounded()))%" } ?? "-"]))
                    .font(PN.Font.caption).foregroundStyle(PN.C.text3).padding(.top, 4)
            }
            .onAppear { sm.load() }
        }
    }

    @ViewBuilder private func actions(_ proj: Project?, _ o: CallOutcome) -> some View {
        HStack(spacing: 8) {
            // 0.8.7 (E1): no Edit mode; rows are edited in place
            // 0.8.7 (A3): Option-Command-I opens and closes the follow-up panel
            Button(L("call.page.followup")) {
                if HomeNav.shared.followUp == file { HomeNav.shared.followUp = nil } else { FollowUpWindow.show(file: file) }
            }
            .buttonStyle(.pnPrimary).keyboardShortcut("i", modifiers: [.command, .option]).help(L("call.page.followup.help"))
            Button(L("call.page.transcript")) { TranscriptWindow.show(file: file) }.buttonStyle(.pnSecondary)
            if let r = record, Self.series(of: r).count > 1 {
                Button(L("call.page.series", ["n": "\(Self.series(of: r).count)"])) { SeriesWindow.show(record: r) }.buttonStyle(.pnSecondary)
            } else {
                // 0.8.7 (L2): visible, greyed out, with the condition
                VStack(spacing: 1) {
                    Button(L("recent.series")) {}.buttonStyle(.pnSecondary).disabled(true)
                    Text(L("series.after2")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                }.help(L("series.after2"))
            }
            Menu {
                if let u = record?.notionURL.flatMap({ URL(string: $0) }) { Button(L("home.recent.notion")) { NSWorkspace.shared.open(u) } }
                Button(L("home.recent.finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)]) }
                Divider()
                // 0.8.7 (I5, L2): Update <CRM> is always listed; without a connection it leads to Settings
                if CRMService.shared.connected {
                    Button(L("crm.update.title", ["crm": "HubSpot"])) { CRMUpdateWindow.show(file: file) }
                } else {
                    Button(L("crm.update.connect")) { SettingsWindow.show(tab: "hubspot") }
                }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel(L("home.more"))
        }
    }

    // MARK: edits (E1-E5)

    /// Every change: EditLog and the usage log as other PM edits, a redraw, and the Notion sync 2 s later.
    private func changed(_ section: String) {
        EditLog.add(kind: "call_page_edit", title: Self.title(file), project: record?.project ?? "", file: file)
        UsageLog.log("call_page_edited", ["section": section])
        tick += 1
        sync.changed(section)
    }

    private func saveLists(_ o: CallOutcome, decisions: [String]? = nil, open: [String]? = nil, risks: [String]? = nil, section: String) {
        CallPageEdit.save(file: file, decisions: decisions ?? o.decisions, open: open ?? o.openQuestions, risks: risks ?? o.risks)
        changed(section)
    }

    private var bullet: some View { Text("•").font(PN.Font.body).foregroundStyle(PN.C.text3) }

    private func heading(_ t: String) -> some View {
        Text(t).font(PN.Font.section).foregroundStyle(PN.C.text).padding(.bottom, 2)
    }

    /// Decisions and open questions: a list of lines in the call picture.
    @ViewBuilder private func lines(_ id: String, _ title: String, _ list: [String], cardRoot: String? = nil, set: @escaping ([String]) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            heading(title)
            ForEach(Array(list.enumerated()), id: \.offset) { i, t in
                // 0.8.7 (E2, H5): decisions can become an answer card (the PM writes the question and edits the answer)
                EditableRow(text: t, copy: t,
                            menu: (cardRoot.map { [saveCardAction("", t, root: $0)] } ?? []) + [.separator, PageRowAction(title: L("callEdit.delete"), destructive: true, run: { _ in
                                var l = list; if i < l.count { l.remove(at: i) }; set(l) })],
                            onSave: { v in var l = list; if i < l.count { l[i] = v }; set(l) }) { bullet }
            }
            AddRowField(placeholder: L("callEdit.addPh")) { set(list + [$0]) }
        }
    }

    /// On you and On them: register items (ops edit, drop, add). `legacy`: an old call's picture without register items.
    @ViewBuilder private func commitments(_ list: [Commitment], mine: Bool, legacy: [String], _ proj: Project?, _ ws: Workspace?) -> some View {
        let section = mine ? "onYou" : "onThem"
        VStack(alignment: .leading, spacing: 2) {
            heading(mine ? L("call.page.onYou") : L("call.page.onThem"))
            ForEach(list) { c in
                let overdue = c.status == "open" && CommitmentRegister.isOverdue(c)
                // 0.8.7 (J4): only the due date is red when overdue, never the owner
                EditableRow(text: c.text, sub: mine ? "" : c.owner, subColor: overdue ? PN.C.danger : PN.C.text3,
                            subTail: c.due.isEmpty ? "" : L("reg.due", ["due": Register.dueText(c.due)]), done: c.status == "done",
                            copy: (c.mine ? "" : c.owner + ": ") + c.text + (c.due.isEmpty ? "" : " (" + Register.dueText(c.due) + ")"),
                            menu: commitmentMenu(c, section),
                            onSave: { v in register.edit(c, text: v); changed(section) }) {
                    Toggle("", isOn: Binding(get: { c.status == "done" }, set: { register.mark(c, $0 ? "done" : "reopen") }))
                        .toggleStyle(.checkbox).labelsHidden().accessibilityLabel(L("reg.markDoneA11y", ["text": c.text]))
                }
            }
            ForEach(legacy, id: \.self) { t in
                EditableRow(text: t, copy: t, onSave: { v in addItem(v, owner: "me", proj, ws); changed(section) }) { bullet }
            }
            AddRowField(placeholder: mine ? L("callEdit.addPh") : L("callEdit.addTheirsPh")) { v in
                if mine { addItem(v, owner: "me", proj, ws) } else {
                    let parts = v.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if parts.count == 2, !parts[0].isEmpty, parts[0].count <= 40, !parts[1].isEmpty { addItem(parts[1], owner: parts[0], proj, ws) }
                    else { addItem(v, owner: L("callEdit.them"), proj, ws) }
                }
                changed(section)
            }
        }
    }

    private func commitmentMenu(_ c: Commitment, _ section: String) -> [PageRowAction] {
        var m: [PageRowAction] = []
        if c.mine {
            m.append(PageRowAction(title: L("callEdit.moveOnThem"), prompt: .text(title: L("callEdit.moveOnThem"), value: "", placeholder: L("callEdit.ownerPh")),
                                   run: { v in guard !v.isEmpty else { return }; register.edit(c, owner: v); changed(section) }))
        } else {
            m.append(PageRowAction(title: L("callEdit.moveOnYou"), run: { _ in register.edit(c, owner: "me"); changed(section) }))
        }
        m.append(PageRowAction(title: L("callEdit.changeOwner"), prompt: .text(title: L("callEdit.changeOwner"), value: c.mine ? "" : c.owner, placeholder: L("callEdit.ownerPh")),
                               run: { v in register.edit(c, owner: v.isEmpty ? "me" : v); changed(section) }))
        m.append(PageRowAction(title: L("callEdit.setDue"), prompt: .date(value: c.due), run: { v in register.edit(c, due: v); changed(section) }))
        if c.mine && c.notionPage.isEmpty && NotionTasks.shared.settings.ready {     // 0.8.6 (D5)
            m.append(PageRowAction(title: L("ntask.addToNotion"), run: { _ in Task { await NotionTasks.shared.add(c) } }))
        }
        m.append(.separator)
        m.append(PageRowAction(title: L("callEdit.delete"), destructive: true, run: { _ in register.mark(c, "drop"); changed(section) }))
        return m
    }

    private func addItem(_ text: String, owner: String, _ proj: Project?, _ ws: Workspace?) {
        let slug = proj?.slug ?? ws?.name ?? record?.project ?? ""
        register.add(folder: folder, text: text, owner: owner, project: slug, title: Self.title(file), call: file)
    }

    /// 0.8.7 (E3): the agenda; the state is a chip on the right, a click moves it on and saves a new agenda line.
    @ViewBuilder private func agendaSection(_ agenda: [(text: String, state: String)]) -> some View {
        let save: ([(text: String, state: String)]) -> Void = { CallPageEdit.saveAgenda(file: file, items: $0); changed("agenda") }
        VStack(alignment: .leading, spacing: 2) {
            heading(L("call.page.agenda"))
            ForEach(Array(agenda.enumerated()), id: \.offset) { i, a in
                EditableRow(text: a.text, copy: a.text,
                            menu: [.separator, PageRowAction(title: L("callEdit.delete"), destructive: true, run: { _ in
                                var l = agenda; if i < l.count { l.remove(at: i) }; save(l) })],
                            onSave: { v in var l = agenda; if i < l.count { l[i].text = v }; save(l) },
                            leading: { bullet },
                            trailing: {
                                AgendaChip(state: a.state) { var l = agenda; if i < l.count { l[i].state = CallPageEdit.nextAgendaState(a.state) }; save(l) }
                            })
            }
            AddRowField(placeholder: L("callEdit.addPh")) { save(agenda + [(text: $0, state: "todo")]) }
        }
    }

    @ViewBuilder private func section(_ title: String, _ rows: [Text]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(PN.Font.section).foregroundStyle(PN.C.text)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, t in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").foregroundStyle(PN.C.text3)
                        t.font(PN.Font.body).foregroundStyle(PN.C.text).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// Risks (rules/risks.yaml > after_call): "Add to risk register" is a hover action and a menu item; it writes one
    /// Notion page after the PM confirms. Without a Risks database or Notion it is greyed out with the reason.
    @ViewBuilder private func risks(_ o: CallOutcome, _ proj: Project?) -> some View {
        let hasDB = SettingsWindow.model.isSet(.notionToken) && !NotionTargets.risksDB(SettingsWindow.model.config, proj).isEmpty && proj != nil
        VStack(alignment: .leading, spacing: 2) {
            heading(L("call.page.risks"))
            ForEach(Array(o.risks.enumerated()), id: \.offset) { i, r in
                let inRegister = added[r] != nil
                let addAction = PageRowAction(title: L("risk.add"), icon: "exclamationmark.shield", enabled: hasDB, note: L("risk.noDB"),
                                              run: { _ in addRisk(r, proj) })
                EditableRow(text: r, copy: r,
                            hoverActions: inRegister ? [] : [addAction],
                            menu: (inRegister ? [] : [addAction]) + [.separator, PageRowAction(title: L("callEdit.delete"), destructive: true, run: { _ in
                                var l = o.risks; if i < l.count { l.remove(at: i) }; saveLists(o, risks: l, section: "risks") })],
                            onSave: { v in var l = o.risks; if i < l.count { l[i] = v }; saveLists(o, risks: l, section: "risks") },
                            leading: { Image(systemName: "exclamationmark.triangle").foregroundStyle(PN.C.onMe).accessibilityHidden(true) },
                            trailing: {
                                if inRegister {
                                    if let u = added[r].flatMap({ URL(string: $0) }), !(added[r] ?? "").isEmpty {
                                        Button(L("risk.inRegister")) { NSWorkspace.shared.open(u) }.buttonStyle(.link)
                                            .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                                    } else {
                                        Text(L("risk.inRegister")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                                    }
                                }
                            })
            }
            AddRowField(placeholder: L("callEdit.addPh")) { saveLists(o, risks: o.risks + [$0], section: "risks") }
        }
    }

    private func addRisk(_ text: String, _ proj: Project?) {
        guard let p = proj else { return }
        let a = NSAlert()
        a.messageText = L("risk.confirm.title")
        a.informativeText = L("risk.confirm.body", ["risk": text, "project": p.name])
        a.addButton(withTitle: L("risk.add"))
        a.addButton(withTitle: L("hk.cancel"))
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let when = record.map { DateFormatter.localizedString(from: $0.start, dateStyle: .medium, timeStyle: .short) } ?? ""
        note = L("risk.adding")
        let c = SettingsWindow.model.config
        PyTool.run("risk_notion", ["--db", NotionTargets.risksDB(c, p), "--title", text, "--call", Self.title(file) + ", " + when]
                   + NotionTargets.projectArgs(c, p, risks: true), notion: true) { r in
            if (r["ok"] as? Bool) == true { added[text] = (r["url"] as? String) ?? ""; note = ""; UsageLog.log("risk_added") } else { note = L("risk.failed", ["err": r["error"] as? String ?? ""]) }
        }
    }
}

/// 0.8.7 (E3): an agenda item's state on the call page: discussed (green), raised (orange), not raised (grey).
struct AgendaChip: View {
    let state: String
    let next: () -> Void
    var body: some View {
        let c = state == "done" ? PN.C.turn : state == "now" ? PN.C.onMe : PN.C.text3
        Button(action: next) {
            Text(L(state == "done" ? "call.page.discussed" : state == "now" ? "call.page.raised" : "call.page.notRaised"))
                .font(PN.Font.caption.weight(.semibold)).foregroundStyle(c)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Capsule().fill(c.opacity(0.14)))
                .fixedSize()
        }
        .buttonStyle(.plain)
        .help(L("callEdit.agendaChip.help"))
        .accessibilityHint(L("callEdit.agendaChip.help"))
    }
}

// MARK: - Transcript

/// The transcript of a call, opened at a moment ("Jump to 12:34" from the call memory). Read only.
@MainActor
enum TranscriptWindow {
    static func show(file: String, at: String? = nil) { HomeNav.shared.open(.transcript(file, at)) }
}

struct TranscriptView: View {
    let file: String
    let at: String?
    @State private var q = ""
    @State private var lines: [TranscriptLine] = []

    private var target: Int? {
        guard let at = at else { return nil }
        return lines.first { $0.t >= at }?.id ?? lines.last?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("", text: $q, prompt: Text(L("transcript.find"))).textFieldStyle(.roundedBorder)
                Button(L("home.recent.finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)]) }.buttonStyle(.pnTertiary)
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(lines.filter { q.isEmpty || $0.text.localizedCaseInsensitiveContains(q) || $0.who.localizedCaseInsensitiveContains(q) }) { l in
                            HStack(alignment: .top, spacing: 8) {
                                Text(l.t).font(PN.Font.caption.monospacedDigit()).foregroundStyle(PN.C.text3).frame(width: 64, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(l.who).font(PN.Font.caption.weight(.semibold)).foregroundStyle(l.me ? PN.C.accent : PN.C.text2)
                                    Text(l.text).font(PN.Font.body).foregroundStyle(PN.C.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: PN.Radius.s).fill(l.id == target ? PN.C.accent.opacity(0.12) : .clear))
                            .id(l.id)
                        }
                    }
                    .padding(12)
                }
                .onAppear {
                    lines = TranscriptLine.read(file, me: PyTool.meLabel)
                    if let t = target { DispatchQueue.main.async { proxy.scrollTo(t, anchor: .center) } }
                }
            }
        }
        .background(PN.C.bg)
    }
}

// MARK: - Follow-up email

/// Idea 04 (rules/followup.yaml): a draft in the client's language to edit, Copy or Open in Mail. Nothing is sent.
/// 0.8.7 (A3): the follow-up email is the call page's right panel, not a window.
@MainActor
enum FollowUpWindow {
    static func show(file: String) {
        HomeNav.shared.open(.call(file))
        HomeNav.shared.followUp = file
    }

    /// The client's language from the project config ("English", "Spanish", ...), English when it is not set.
    static func language(of file: String) -> String {
        let l = (PyTool.project(of: file).project?.clientLanguage ?? "").lowercased()
        for (k, v) in [("ukrain", "uk"), ("україн", "uk"), ("spanish", "es"), ("español", "es"), ("german", "de"), ("deutsch", "de"),
                       ("french", "fr"), ("polish", "pl")] where l.hasPrefix(k) { return v }
        return "en"
    }
}

struct FollowUpView: View {
    let file: String
    @ObservedObject var model: FollowUpModel
    @State private var instruction = ""

    init(file: String) { self.file = file; self.model = FollowUpModel.of(file) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("followup.note")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            if model.busy {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L("followup.writing")).foregroundStyle(PN.C.text2) }
            }
            if !model.error.isEmpty { Text(model.error).font(PN.Font.caption).foregroundStyle(PN.C.danger) }
            // 0.8.7 (J1): the draft is written as soon as the panel opens; no Write draft button
            let n = Learning.standing(EditLog.all(), kinds: ["followup_instruction", "followup_edit"]).count
            if n > 0 && model.body.isEmpty { Text(L("after.lessons", ["n": "\(n)"])).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
            if !model.body.isEmpty || !model.subject.isEmpty {
                Text(L("followup.subject")).font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.text3)
                TextField("", text: $model.subject).textFieldStyle(.roundedBorder).labelsHidden()
                TextEditor(text: $model.body).font(PN.Font.body).frame(minHeight: 260)
                    .overlay(RoundedRectangle(cornerRadius: PN.Radius.s).stroke(PN.C.text3.opacity(0.3)))
                HStack(spacing: 8) {
                    TextField("", text: $instruction, prompt: Text(L("after.instruct"))).textFieldStyle(.roundedBorder)
                        .onSubmit { model.revise(instruction); instruction = "" }
                    Button(L("after.rewrite")) { model.revise(instruction); instruction = "" }.buttonStyle(.pnSecondary)
                        .disabled(instruction.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
                }
                HStack(spacing: 8) {
                    Button(L("after.copy")) { model.copy() }.buttonStyle(.pnPrimary).disabled(model.body.isEmpty)
                    Button(L("after.openMail")) { model.openMail() }.buttonStyle(.pnSecondary).disabled(model.body.isEmpty)
                    Text(L("after.neverSends")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    Spacer()
                    Button(L("followup.again")) { model.write() }.buttonStyle(.pnTertiary).disabled(model.busy)
                }
            }
        }
        .padding(20)
        .background(PN.C.bg)
        .onAppear { if model.body.isEmpty && !model.busy && model.error.isEmpty { model.write() } }
        .onDisappear { model.logHandEdits() }
    }
}
