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
    @ObservedObject private var links = NotionLinksVersion.shared   // 0.8.8: "In register" after an automatic add
    @State private var supersede: [String: [String: String]] = [:]  // 0.8.8: decision -> the active one it may replace
    @State private var adding = Set<String>()
    @State private var tab = "summary"          // 0.9.0: Summary, Decisions, Tasks, Risks, Transcript (+ Sales)
    @State private var meetNote = ""          // 0.9.1: the Google Meet record, one line
    @State private var exportOpen = false
    @State private var transcriptAt: String? = nil     // 0.9.5.2: a time in the Meeting notes opens the transcript there
    @State private var making = false
    @State private var makeNote = ""
    @State private var copied = false
    @State private var reassigning = false       // 0.10.1 (A3): the project picker in the header
    @State private var confirmServerDelete = false  // 0.12.1 (B8): "Delete from server"
    @State private var serverDeleteError = ""
    @ObservedObject private var nav = HomeNav.shared       // 0.25 (R2): Follow-up is a tab of the page
    @State private var riskAsk: RiskAsk?                    // 0.25 (R2 tail): the risk waiting for "Add to Tracker"
    @Environment(\.pnTheme) private var t

    /// Shot mode only: the tab the page opens on.
    static var shotTab: String? = nil
    static var shotExport = false        // shot mode only: the export panel open, in Preview

    init(file: String) {
        self.file = file
        _sync = ObservedObject(wrappedValue: CallPageSync.of(file))
        _tab = State(initialValue: Self.shotTab ?? "summary")
        _exportOpen = State(initialValue: Self.shotExport)
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
    private var folderRoot: String { (folder as NSString).deletingLastPathComponent }      // <root>/live -> <root>
    /// This call's register items in every status (dropped too: a deleted task must not come back from the notes).
    private var callItems: [Commitment] {
        register.items(in: folder).filter { CommitmentRegister.callKey($0.call) == CommitmentRegister.callKey(file) }
    }
    private var items: [Commitment] { callItems.filter { $0.status != "dropped" } }
    /// 0.13.3 (L5): the picture tasks still shown as they are (none once the call has its own register items).
    private func legacyTasks(_ o: CallOutcome) -> [CallLists.Task] {
        CommitmentRegister.legacy(o.tasks, items: callItems, call: file, them: L("callEdit.them"))
    }

    /// Earlier and later calls of the same meeting (same project, same title key).
    static func series(of r: CallHistory.Record) -> [CallHistory.Record] {
        let key = EditLog.seriesKey(r.title)
        return CallHistory.shared.visible.filter { EditLog.seriesKey($0.title) == key && $0.project == r.project }
    }

    @State private var width: CGFloat = 1000      // 2026-11-05 (redesign): two columns on a wide window
    @State private var allQuotes = false
    @State private var openQuotes = Set<Int>()

    private var wide: Bool { width >= 860 }

    var body: some View {
        Group {
        let o = CallOutcome.read(transcript: file) ?? CallOutcome()
        let agenda = StartCallModel.agenda(transcript: file)
        let pw = PyTool.project(of: file)
        let proj = pw.project, ws = pw.workspace
        // 0.25 (R2, boards CP, CT, SL): the bar stays, the page scrolls under it; everything is flat sections
        VStack(spacing: 0) {
            PageBackBar(crumb: crumb) { barActions(proj, o) }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    titleBlock(proj, ws, o)
                    statusLines(o)
                    if exportOpen {
                        ExportPanel(file: file, title: Self.title(file), outcome: o, commitments: items) { exportOpen = false }
                            .padding(.horizontal, PageMetrics.side).padding(.bottom, 16)
                    }
                    PageTabBar(tabs: pageTabs(o), selection: $tab, counts: tabCounts(o), badges: hasSales ? ["sales": salesBadge] : [:],
                               note: ["decisions", "tasks", "risks"].contains(tab) ? L("page.trackerNote") : "")
                    Group {
                        switch tab {
                        case "decisions":
                            decisionsSection(o, proj, ws)      // 0.8.8 (rules/decisions.yaml > after_call)
                        case "tasks":
                            tasksTab(o, proj, ws)
                        case "risks":
                            risks(o, proj)
                        case "followup":
                            followUpTab(o)
                        case "transcript":
                            VStack(alignment: .leading, spacing: 0) {
                                TranscriptView(file: file, at: transcriptAt)
                                    .frame(minHeight: 560)
                                Text(L("page.transcript.local")).font(t.homeText(13)).foregroundStyle(PN.C.text3)
                                    .padding(.horizontal, PageMetrics.side).pageRow(12)
                            }
                        case "sales":
                            salesSection(cardRoot(proj, ws))
                        case "discussed":
                            summaryTab(o, agenda)        // 0.9.5.2: the former Summary, as it was
                        default:
                            meetingTab(o)
                        }
                    }
                    .padding(.horizontal, tab == "transcript" ? 0 : PageMetrics.side)
                    .padding(.top, tab == "transcript" ? 0 : 24).padding(.bottom, 32)
                    .onChange(of: tab) { _, t in if t != "transcript" { transcriptAt = nil } }
                }
                .id(tick)
                .environment(\.pageFlat, true)
                .environment(\.pageWide, width >= 900)
                .background(GeometryReader { g in
                    Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w }
                })
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: CallReassignService.changed)) { _ in tick += 1 }   // 0.10.1 (A3)
        .onAppear {
            DriveRecordings.shared.syncTranscript(file, create: false)   // 0.11.0 (B7b): a changed transcript in Drive
            CallSyncService.shared.sync(file)                            // 0.12.0 (B8b): changed notes to the server
            takeFollowUp()
        }
        .onChange(of: nav.followUp) { _, _ in takeFollowUp() }
        .onReceive(NotificationCenter.default.publisher(for: .pnShotTab)) { n in if let s = n.object as? String { tab = s } }
        .textSelection(.enabled)      // 2026-11-10 (owner): the call's title and every text on the page can be selected and copied
        .background(PN.C.bg)
        .alert(L("sync.call.delete.q"), isPresented: $confirmServerDelete) {
            Button(L("sync.call.delete.ok"), role: .destructive) {
                Task { serverDeleteError = await CallSyncService.shared.deleteFromServer(file) ?? "" }
            }
            Button(L("common.cancel"), role: .cancel) {}
        } message: { Text(L("sync.call.delete.m")) }
        .alert(L("sync.call.delete.failed"), isPresented: Binding(get: { !serverDeleteError.isEmpty }, set: { if !$0 { serverDeleteError = "" } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(serverDeleteError) }
        .sheet(item: $cardDraft) { c in
            AnswerCardForm(card: c, title: L("cards.saveAs"), onSave: { saveCard($0, proj, ws) }, onCancel: { cardDraft = nil })
        }
        .sheet(item: $riskAsk) { r in
            PageConfirmSheet(title: L("risk.confirm.title"), text: L("risk.confirm.body", ["risk": r.text, "project": proj?.name ?? ""]),
                             go: L("risk.add"), onCancel: { riskAsk = nil }, onGo: { riskAsk = nil; addRiskNow(r.text, proj) })
        }
    }
        .trackScreen("call_page", sub: tab, o: CallSyncService.shared.callOrg(of: file))
    }

    /// 0.25 (R2, board CT row 5): the follow-up email as a tab: the draft on the left, who it goes to and what it is
    /// written from on the right.
    @ViewBuilder private func followUpTab(_ o: CallOutcome) -> some View {
        let people: [String] = {
            guard let r = record else { return [] }
            let key = EditLog.seriesKey(r.title)
            return CalendarService.shared.events.first { abs($0.start.timeIntervalSince(r.start)) < 1800 && EditLog.seriesKey($0.title) == key }?.attendees ?? []
        }()
        let lang = FollowUpWindow.language(of: file)
        let langName = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US").localizedString(forLanguageCode: lang)?.capitalized ?? lang
        PageColumns(side: 320) {
            FollowUpView(file: file, page: true)
        } right: {
            VStack(alignment: .leading, spacing: 20) {
                if let first = people.first {
                    VStack(alignment: .leading, spacing: 0) {
                        PageSectionHead(title: L("followup.to"))
                        Text(first).font(t.homeText(15, .semibold)).foregroundStyle(PN.C.text).pageRow(8)
                        if people.count > 1 {
                            Text(L("followup.copyTo", ["people": people.dropFirst().joined(separator: ", ")])).font(t.homeText(15)).foregroundStyle(PN.C.text2).pageRow(8)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    PageSectionHead(title: L("followup.from"))
                    fromRow(L("followup.from.notes"), "")
                    fromRow(L("page.tab.decisions"), "\(decisions(o).count)")
                    fromRow(L("followup.from.onYou"), "\(items.filter { $0.mine && $0.status != "done" }.count)")
                    fromRow(L("followup.from.lang"), L("followup.from.langValue", ["lang": langName]))
                }
                Text(L("followup.shortcut")).font(t.homeText(13)).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func fromRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(t.homeText(15)).foregroundStyle(PN.C.text)
            Spacer(minLength: 8)
            Text(v).font(v.allSatisfy(\.isNumber) ? t.homeMono(12) : t.homeText(14)).foregroundStyle(v.allSatisfy(\.isNumber) ? PN.C.text3 : PN.C.text2)
        }
        .pageRow(8)
    }

    /// 0.25 (R2): "Draft follow-up email" anywhere (Home's menu, Option-Command-I) opens the Follow-up tab of this page.
    private func takeFollowUp() {
        guard nav.followUp == file else { return }
        nav.followUp = nil
        tab = "followup"
    }

    // MARK: header (0.25 R2: the bar, the title block and the status lines of the boards CP and SL)

    /// "Mon, Nov 2 · 14:55-15:11"
    private var whenText: String {
        guard let r = record else { return "" }
        let d = Self.fmt("EEEMMMd"), t = Self.fmt("HHmm")
        let end = r.end ?? r.minutes.map { r.start.addingTimeInterval($0 * 60) }
        return d.string(from: r.start) + " · " + t.string(from: r.start) + (end.map { "-" + t.string(from: $0) } ?? "")
    }

    /// The bar's mono text: "Past call · 3rd in this series".
    private var crumb: String {
        guard let r = record else { return L("page.crumb.past") }
        let s = Self.series(of: r).sorted { $0.start < $1.start }
        guard s.count > 1, let i = s.firstIndex(where: { $0.file == r.file }) else { return L("page.crumb.past") }
        let f = NumberFormatter(); f.numberStyle = .ordinal; f.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US")
        return L("page.crumb.pastNth", ["nth": f.string(from: NSNumber(value: i + 1)) ?? "\(i + 1)"])
    }

    /// The people of the call from its calendar event: "Emily Carter, Mike Reed and you".
    private var peopleText: String {
        guard let r = record else { return "" }
        let key = EditLog.seriesKey(r.title)
        guard let e = CalendarService.shared.events.first(where: { abs($0.start.timeIntervalSince(r.start)) < 1800 && EditLog.seriesKey($0.title) == key }),
              !e.attendees.isEmpty else { return "" }
        return L("page.people.andYou", ["people": e.attendees.prefix(5).joined(separator: ", ")])
    }

    /// The state of the call after the title (board TAG): ended and how it was recorded, transcript only, or not synced.
    private func callTag(_ o: CallOutcome) -> (HomeTag, String) {
        let notes = CallNotes.meeting(file).map { !$0.isEmpty } ?? false
        if !notes && o.isEmpty { return (.notReady, L("page.tag.transcriptOnly")) }
        if case .failed = sync.state { return (.notReady, L("page.tag.notSynced")) }
        if let m = RecordingMeta.load(RecordingFiles.metaPath(transcript: file)), !m.parts.isEmpty {
            return (.ready, L(m.parts.contains { $0.kind == "video" } ? "page.tag.screen" : "page.tag.sound"))
        }
        return (.ready, L("page.tag.ended"))
    }

    @ViewBuilder private func titleBlock(_ proj: Project?, _ ws: Workspace?, _ o: CallOutcome) -> some View {
        let projName = CallReassignService.shared.pendingName(for: file) ?? proj?.name ?? ws?.name ?? record?.project ?? ""
        let series = record.map { Self.series(of: $0).count } ?? 0
        let mins = record?.minutes.map { L("call.page.minutes", ["n": "\(max(1, Int($0.rounded())))"]) } ?? ""
        let (kind, tag) = callTag(o)
        PageTitleBlock(meta: [whenText, mins].filter { !$0.isEmpty }.joined(separator: " · "), title: Self.title(file)) {
            HStack(spacing: 16) {
                // 0.10.1 (A3): the project is a picker: the call, its tasks, series and Notion pages move to another one
                Button { reassigning = true } label: { HomeField(text: projName.isEmpty ? L("reassign.noProject") : projName, height: 28) }
                    .buttonStyle(.plain).help(L("reassign.help")).accessibilityLabel(L("reassign.help"))
                    .popover(isPresented: $reassigning, arrowEdge: .bottom) { ReassignPickerView(file: file, done: { reassigning = false }) }
                HomeTagView(kind: kind, text: tag)
                if !peopleText.isEmpty { Text(peopleText).font(t.homeText(14)).foregroundStyle(PN.C.text2).lineLimit(1) }
                if series > 1, let r = record { HomeLink(L("page.seriesLink", ["n": "\(series)"])) { SeriesWindow.show(record: r) } }
            }
            if !meetNote.isEmpty { Text(meetNote).font(t.homeText(13)).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true) }
            if !note.isEmpty { Text(note).font(t.homeText(13)).foregroundStyle(PN.C.notreadyText).fixedSize(horizontal: false, vertical: true) }
        }
    }

    /// The status lines under the title (board SL): Notion, consent, recording, server, organization; then the offer
    /// to update the organization's shared state.
    @ViewBuilder private func statusLines(_ o: CallOutcome) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CallPageSyncLine(sync: sync)       // 0.8.7 (E5)
            CallConsentLine(file: file)        // 0.13.0 (B8 part 2): the consent record of the call
            RecordingRow(file: file)           // 0.9.5: the call recording, if there is one
            ServerSyncRow(file: file)          // 0.12.1 (B8): the call's copy on the Pacenote server
            CallOrgRow(file: file)             // 0.17.0 (B6b): its organization, who sees it, Private
            OrgStateUpdateLine(file: file, decisions: decisions(o), risks: o.risks).padding(.top, 10)   // 0.17.0 (contract 9 block 5)
        }
        .overlay(alignment: .top) { Rectangle().fill(PN.C.rule).frame(height: 1) }
        .padding(.horizontal, PageMetrics.side).padding(.bottom, 16)
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
            // 0.25 (R2, board SL): Qualification on the left, Next step and Objections on the right
            let known = crit.filter { ($0["state"] as? String) == "known" }.count
            PageColumns(side: 380) {
                VStack(alignment: .leading, spacing: 2) {
                    PageSectionHead(title: L("sales.qualification")) {
                        if let m = method { HomeField(text: m.name, height: 26) }
                        Spacer()
                        PageCount(text: L("sales.knownOf", ["known": "\(known)", "total": "\(crit.count)"]))
                    }
                ForEach(Array(crit.enumerated()), id: \.offset) { i, c in
                    let key = (c["criterion"] as? String) ?? (c["key"] as? String) ?? ""
                    let name = method?.criteria.first { $0.key == key }?.name ?? (c["name"] as? String) ?? (key.prefix(1).uppercased() + key.dropFirst())
                    let what = (c["what"] as? String) ?? ""
                    let quote = (c["quote"] as? String) ?? ""
                    EditableRow(text: what.isEmpty ? L("sales.criterionPh") : what, sub: quote.isEmpty ? "" : "\u{201C}" + quote + "\u{201D}",
                                copy: name + ": " + what,
                                onSave: { v in var nd = d; var l = crit; if i < l.count { l[i]["what"] = v; if (l[i]["state"] as? String ?? "unknown") == "unknown" { l[i]["state"] = "partial" } }; nd["criteria"] = l; save(nd) },
                                leading: { Text(name).font(t.homeDisplay(20, t.titleWeight)).tracking(t.dTrack * 20).foregroundStyle(PN.C.text).frame(width: 110, alignment: .leading) },
                                trailing: {
                                    SalesStateChip(state: (c["state"] as? String) ?? "unknown") {
                                        var nd = d; var l = crit; if i < l.count { l[i]["state"] = SalesFile.nextState((l[i]["state"] as? String) ?? "unknown") }; nd["criteria"] = l; save(nd)
                                    }
                                })
                }
                Text(L("sales.scorecard", ["known": "\(crit.filter { ($0["state"] as? String) == "known" }.count)", "total": "\(crit.count)",
                                           "open": "\((sc["open_questions"] as? Int) ?? 0)",
                                           "share": (sc["pm_talk_share"] as? Double).map { "\(Int(($0 * 100).rounded()))%" } ?? "-"]))
                    .font(t.homeMono(12)).foregroundStyle(PN.C.text2).pageRow(12)
                    salesBlocks(d, root: root, save: save)
                }
            } right: {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 6) {
                        PageSectionHead(title: L("sales.next"))
                let nw = (next["what"] as? String) ?? "", due = (next["due"] as? String) ?? ""
                EditableRow(text: nw.isEmpty ? L("sales.nextPh") : nw, sub: due.isEmpty ? L("sales.noNext") : L("sales.due", ["due": due]),
                            subColor: due.isEmpty ? PN.C.onMe : PN.C.text3, copy: nw,
                            menu: [PageRowAction(title: L("callEdit.setDue"), prompt: .date(value: due), run: { v in
                                var nd = d; var n = next; n["due"] = v; nd["next_step"] = n; save(nd) })],
                            onSave: { v in var nd = d; var n = next; n["what"] = v; nd["next_step"] = n; save(nd) },
                            leading: { EmptyView() })
                    }
                    .pageTint()
                    VStack(alignment: .leading, spacing: 2) {
                        PageSectionHead(title: L("sales.objections"), count: objections.isEmpty ? "" : "\(objections.count)")
                ForEach(Array(objections.enumerated()), id: \.offset) { i, ob in
                    let what = (ob["what"] as? String) ?? ""
                    let ans = (ob["answer"] as? String) ?? ""
                    EditableRow(text: what, sub: ans.isEmpty ? "" : L("sales.answered", ["answer": ans]), copy: what + (ans.isEmpty ? "" : " -> " + ans),
                                menu: [saveCardAction(what, ans, root: root), .separator,
                                       PageRowAction(title: L("callEdit.delete"), destructive: true, run: { _ in
                                           var nd = d; var l = objections; if i < l.count { l.remove(at: i) }; nd["objections"] = l; save(nd) })],
                                onSave: { v in var nd = d; var l = objections; if i < l.count { l[i]["what"] = v }; nd["objections"] = l; save(nd) },
                                leading: { EmptyView() })
                }
                AddRowField(placeholder: L("sales.objection")) { v in
                    var nd = d; nd["objections"] = objections + [["what": v, "answer": "", "t": ""]]; save(nd)
                }
                        Text(L("sales.objection.cardNote")).font(t.homeText(13)).foregroundStyle(PN.C.text3).padding(.top, 8)
                    }
                }
            }
            .onAppear { sm.load() }
        }
    }

    /// S1 (rules/sales.yaml > after_call > blocks): stakeholders, the mutual action plan, competitors, prices and the
    /// CRM stage of <stem>.sales.json. Edited in place like the rows above; empty blocks are not shown, except the plan,
    /// which can be started here (it goes into the follow-up email).
    @ViewBuilder private func salesBlocks(_ d: [String: Any], root: String, save: @escaping ([String: Any]) -> Void) -> some View {
        let rows = { (k: String) -> [[String: Any]] in (d[k] as? [[String: Any]]) ?? [] }
        let people = rows("stakeholders"), plan = rows("mutual_plan"), comps = rows("competitors")
        let prices = rows("price_talk"), breaches = rows("limit_breach")
        let edit = { (k: String, i: Int, f: String, v: String) in var nd = d; var l = rows(k); if i < l.count { l[i][f] = v }; nd[k] = l; save(nd) }
        let drop = { (k: String, i: Int) in var nd = d; var l = rows(k); if i < l.count { l.remove(at: i) }; nd[k] = l; save(nd) }
        let del = { (k: String, i: Int) in PageRowAction(title: L("callEdit.delete"), destructive: true, run: { _ in drop(k, i) }) }
        if let st = d["stage_crm"] as? String, !st.isEmpty {
            Text(L("sales.stage", ["stage": st])).font(PN.Font.caption).foregroundStyle(PN.C.text3).padding(.top, 4)
        }
        if !people.isEmpty { subheading(L("sales.stakeholders")) }
        ForEach(Array(people.enumerated()), id: \.offset) { i, p in
            let role = (p["role"] as? String) ?? "unknown", stance = (p["stance"] as? String) ?? "unknown"
            let quote = (p["quote"] as? String) ?? ""
            EditableRow(text: (p["name"] as? String) ?? "",
                        sub: L("sales.role." + role) + (stance == "unknown" ? "" : " · " + L("sales.stance." + stance)) + (quote.isEmpty ? "" : " · \u{201C}" + quote + "\u{201D}"),
                        subColor: stance == "against" ? PN.C.onMe : PN.C.text3, copy: (p["name"] as? String) ?? "",
                        menu: ["decider", "champion", "blocker", "influencer", "user", "unknown"].map { r in
                                   PageRowAction(title: L("sales.setRole", ["role": L("sales.role." + r)]), run: { _ in edit("stakeholders", i, "role", r) }) }
                              + [.separator, del("stakeholders", i)],
                        onSave: { v in edit("stakeholders", i, "name", v) })
        }
        subheading(L("sales.plan"))
        ForEach(Array(plan.enumerated()), id: \.offset) { i, m in
            let owner = (m["owner"] as? String) ?? "", due = (m["due"] as? String) ?? ""
            EditableRow(text: (m["step"] as? String) ?? "",
                        sub: [owner == "us" ? L("sales.owner.us") : owner == "them" ? L("sales.owner.them") : owner, due.isEmpty ? "" : L("sales.due", ["due": due])].filter { !$0.isEmpty }.joined(separator: " · "),
                        copy: (m["step"] as? String) ?? "",
                        menu: [PageRowAction(title: L("callEdit.setDue"), prompt: .date(value: due), run: { v in edit("mutual_plan", i, "due", v) }),
                               PageRowAction(title: L("sales.owner.setUs"), run: { _ in edit("mutual_plan", i, "owner", "us") }),
                               PageRowAction(title: L("sales.owner.setThem"), run: { _ in edit("mutual_plan", i, "owner", "them") }),
                               .separator, del("mutual_plan", i)],
                        onSave: { v in edit("mutual_plan", i, "step", v) })
        }
        AddRowField(placeholder: L("sales.planPh")) { v in var nd = d; nd["mutual_plan"] = plan + [["step": v, "owner": "", "due": ""]]; save(nd) }
        if !comps.isEmpty { subheading(L("sales.competitors")) }
        ForEach(Array(comps.enumerated()), id: \.offset) { i, c in
            let name = (c["name"] as? String) ?? "", what = (c["what"] as? String) ?? ""
            EditableRow(text: name, sub: what, copy: name + (what.isEmpty ? "" : ": " + what),
                        menu: [PageRowAction(title: L("cards.saveAs"), enabled: !root.isEmpty, note: L("cards.noRoot"),
                                             run: { _ in cardDraft = AnswerCard(title: name, answer: what, type: "competitor") }),
                               .separator, del("competitors", i)],
                        onSave: { v in edit("competitors", i, "name", v) })
        }
        if !(prices.isEmpty && breaches.isEmpty) { subheading(L("sales.prices")) }
        ForEach(Array(breaches.enumerated()), id: \.offset) { i, b in
            EditableRow(text: (b["what"] as? String) ?? "", sub: L("sales.overLimit", ["limit": (b["limit"] as? String) ?? ""]),
                        subColor: PN.C.danger, copy: (b["what"] as? String) ?? "", menu: [del("limit_breach", i)],
                        onSave: { v in edit("limit_breach", i, "what", v) })
        }
        ForEach(Array(prices.enumerated()), id: \.offset) { i, p in
            EditableRow(text: (p["what"] as? String) ?? "", sub: (p["who"] as? String) == "us" ? L("sales.owner.us") : L("sales.owner.them"),
                        copy: (p["what"] as? String) ?? "", menu: [del("price_talk", i)],
                        onSave: { v in edit("price_talk", i, "what", v) })
        }
    }

    private func subheading(_ s: String) -> some View {
        PageSectionHead(title: s).padding(.top, 18)
    }

    // MARK: 0.9.0 tabs

    private var hasSales: Bool { FileManager.default.fileExists(atPath: (file.hasSuffix(".md") ? String(file.dropLast(3)) : file) + ".sales.json") }

    /// Decisions of the call: the call picture's, else the "## Decisions" of the notes (the follow-up email reads those too).
    /// 0.12.1: a line that only says there are none ("Жодних рішень не приймалося.") is not a decision, so the tab no
    /// longer counts it as 1 (the server sync already sent 0).
    private func decisions(_ o: CallOutcome) -> [String] {
        o.decisions   // 0.12.2 (L2): CallOutcome.read already applies the one rule (CallLists)
    }

    private func pageTabs(_ o: CallOutcome) -> [(String, String)] {
        [("summary", L("page.tab.summary")), ("discussed", L("page.sum.discussed")), ("decisions", L("page.tab.decisions")), ("tasks", L("page.tab.tasks")),
         ("risks", L("page.tab.risks")), ("followup", L("page.tab.followup")), ("transcript", L("call.page.transcript"))]
            + (hasSales ? [("sales", L("sales.section"))] : [])
    }

    /// "2/4": the criteria of the sales method known so far (board SL).
    private var salesBadge: String {
        guard let d = SalesFile.load(file) else { return "" }
        let crit = (d["criteria"] as? [[String: Any]]) ?? []
        guard !crit.isEmpty else { return "" }
        let known = crit.filter { ($0["state"] as? String) == "known" }.count
        return "\(known)/\(crit.count)"
    }

    /// 2026-11-05 (redesign): the counts are badges on the tabs, not part of the name.
    private func tabCounts(_ o: CallOutcome) -> [String: Int] {
        ["decisions": decisions(o).count, "tasks": items.count + legacyTasks(o).count, "risks": o.risks.count]
    }

    private var trackerNote: some View {
        Text(L("page.trackerNote")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
    }

    // MARK: Summary = Meeting notes (0.9.5.2, owner: readable notes people will read, with Copy and Export)

    /// 0.25 (R2, board CP): In short and Topics on the left; Decisions, On you, On them, Risks on the right, as
    /// equal columns; every time is a link to the transcript. Without notes: the "No notes yet" state of board CT row 7.
    @ViewBuilder private func meetingTab(_ o: CallOutcome) -> some View {
        if let m = CallNotes.meeting(file), !m.isEmpty {
            PageColumns {
                VStack(alignment: .leading, spacing: 26) { summaryLeft(m) }
            } right: {
                VStack(alignment: .leading, spacing: 26) { summaryRight(m, o) }
            }
        } else {
            noNotes(o)
        }
    }

    @ViewBuilder private func summaryLeft(_ m: MeetingNotes.Notes) -> some View {
        if !m.tldr.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                PageSectionHead(title: L("page.sum.inShort")) {
                    HomeLink(copied ? L("page.mn.copied") : L("page.mn.copyNotes")) { copyMeeting() }.help(L("page.mn.copyHelp"))
                }
                .padding(.bottom, 2)
                Text(CallNotes.md(m.tldr)).font(t.homeText(17)).lineSpacing(3).foregroundStyle(PN.C.text)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        if !m.topics.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                PageSectionHead(title: L("page.mn.topics")) { HomeLink(L("page.mn.seeDiscussed")) { tab = "discussed" } }
                ForEach(Array(m.topics.enumerated()), id: \.offset) { _, tp in
                    let text = tp.outcome.isEmpty ? tp.points.map { CallNotes.plain($0.text) }.joined(separator: " ") : tp.outcome.prefix(1).uppercased() + tp.outcome.dropFirst()
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(CallNotes.md(tp.title)).font(t.homeDisplay(20, t.titleWeight)).tracking(t.dTrack * 20)
                                .foregroundStyle(PN.C.text).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if !tp.t.isEmpty { PageTimeLink(time: tp.t) { transcriptAt = tp.t; tab = "transcript" } }
                        }
                        if !text.isEmpty {
                            Text(CallNotes.md(text)).font(t.homeText(15)).lineSpacing(2).foregroundStyle(PN.C.text2)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .pageRow(12)
                }
            }
        }
        if !m.unclear.isEmpty {
            Text(L("page.mn.unclear") + ": " + m.unclear.map { CallNotes.plain($0.text) }.joined(separator: "; "))
                .font(t.homeText(13)).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One line of the right column: the text and its time as a link to the transcript.
    @ViewBuilder private func timedRow(_ it: MeetingNotes.Item, bold: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(CallNotes.md(it.text)).font(t.homeText(16, bold ? .semibold : .regular)).foregroundStyle(PN.C.text)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !it.t.isEmpty { PageTimeLink(time: it.t) { transcriptAt = it.t; tab = "transcript" } }
        }
        .pageRow()
    }

    @ViewBuilder private func summaryRight(_ m: MeetingNotes.Notes, _ o: CallOutcome) -> some View {
        let mine = items.filter { $0.mine }, theirs = items.filter { !$0.mine }
        if !m.decisions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                PageSectionHead(title: L("page.tab.decisions"), count: "\(m.decisions.count)")
                ForEach(Array(m.decisions.enumerated()), id: \.offset) { _, it in timedRow(it, bold: true) }
            }
        }
        if !items.isEmpty {
            let open = mine.filter { $0.status != "done" }.count
            VStack(alignment: .leading, spacing: 0) {
                PageSectionHead(title: L("call.page.onYou"), count: open > 0 ? L("page.tasks.open", ["n": "\(open)"]) : "", warn: open > 0)
                if mine.isEmpty { Text(L("page.tasks.noneOnYou")).font(t.homeText(15)).foregroundStyle(PN.C.text3).pageRow() }
                ForEach(mine) { c in summaryTask(c) }
            }
            VStack(alignment: .leading, spacing: 0) {
                let n = theirs.filter { $0.status != "done" }.count
                PageSectionHead(title: L("call.page.onThem"), count: n > 0 ? L("page.tasks.open", ["n": "\(n)"]) : "")
                if theirs.isEmpty { Text(L("page.tasks.noneOnThem")).font(t.homeText(15)).foregroundStyle(PN.C.text3).pageRow() }
                ForEach(theirs) { c in summaryTask(c) }
            }
        } else if !m.actions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                PageSectionHead(title: L("page.mn.actions"), count: "\(m.actions.count)")
                ForEach(Array(m.actions.enumerated()), id: \.offset) { _, it in timedRow(it) }
            }
        }
        if !m.risks.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                PageSectionHead(title: L("page.tab.risks"), count: "\(m.risks.count)")
                ForEach(Array(m.risks.enumerated()), id: \.offset) { _, it in timedRow(it) }
            }
        }
        if !m.open.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                PageSectionHead(title: L("page.mn.open"), count: "\(m.open.count)")
                ForEach(Array(m.open.enumerated()), id: \.offset) { _, it in timedRow(it) }
            }
        }
    }

    /// A task of the Summary (board CP): a check box, the text (the owner first when it is on someone else), the due date.
    @ViewBuilder private func summaryTask(_ c: Commitment) -> some View {
        let done = c.status == "done"
        let late = !done && CommitmentRegister.isOverdue(c)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if c.mine {
                Toggle("", isOn: Binding(get: { done }, set: { register.mark(c, $0 ? "done" : "reopen") }))
                    .toggleStyle(.pnCheckbox).labelsHidden().accessibilityLabel(L("reg.markDoneA11y", ["text": c.text]))
            }
            (c.mine ? Text(c.text) : Text(c.owner + ": ").fontWeight(.semibold) + Text(c.text))
                .font(t.homeText(16)).foregroundStyle(done ? PN.C.text3 : PN.C.text).strikethrough(done)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(done ? L("page.tasks.doneWord") : c.due.isEmpty ? L("page.tasks.noDate") : Register.dueText(c.due))
                .font(t.homeMono(12)).foregroundStyle(late ? PN.C.recText : PN.C.text3).lineLimit(1).fixedSize()
        }
        .pageRow()
    }

    /// No notes yet (board CT row 7): what this call has, and one button that writes the notes from the transcript.
    @ViewBuilder private func noNotes(_ o: CallOutcome) -> some View {
        let hasNotes = FileManager.default.fileExists(atPath: CallNotes.path(file))
        let rec = RecordingMeta.load(RecordingFiles.metaPath(transcript: file))
        let mins = record?.minutes.map { L("call.page.minutes", ["n": "\(max(1, Int($0.rounded())))"]) } ?? ""
        PageColumns(side: 360) {
            VStack(alignment: .leading, spacing: 12) {
                PageSectionHead(title: L("page.mn.label"))
                Text(t.cased(L("page.mn.noneTitle"))).font(t.homeDisplay(34, t.heroWeight)).tracking(t.dTrack * 34).foregroundStyle(PN.C.text)
                Text(L(hasNotes ? "page.mn.none" : "page.mn.noneNoNotes")).font(t.homeText(17)).foregroundStyle(PN.C.text2)
                    .frame(maxWidth: 560, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    Button(making ? L("page.mn.making") : L("page.mn.make")) { makeMeeting() }
                        .buttonStyle(PNHeroButtonStyle()).disabled(making)
                    if making { PNSpinner(size: 18) }
                    Text(L(hasNotes ? "page.mn.cost" : "page.mn.costFull")).font(t.homeText(13)).foregroundStyle(PN.C.text3)
                        .frame(maxWidth: 300, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 6)
                if !makeNote.isEmpty {
                    Text(makeNote).font(t.homeText(13)).foregroundStyle(PN.C.notreadyText).fixedSize(horizontal: false, vertical: true)
                }
                HomeLink(L("page.mn.openTranscript")) { tab = "transcript" }.padding(.top, 4)
            }
        } right: {
            VStack(alignment: .leading, spacing: 0) {
                PageSectionHead(title: L("page.has.title"))
                hasRow(L("call.page.transcript"), .ready, mins.isEmpty ? L("page.has.yes") : mins)
                if let rec, !rec.parts.isEmpty {
                    hasRow(L(rec.parts.contains { $0.kind == "video" } ? "page.has.screen" : "page.has.sound"), .ready,
                           L(rec.notUploaded.isEmpty ? "page.has.inDrive" : "page.has.onMac"))
                }
                hasRow(L("page.has.notes"), o.isEmpty ? .notReady : .ready, L(o.isEmpty ? "page.has.notWritten" : "page.has.partly"))
                Text(L("page.has.note")).font(t.homeText(13)).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true).pageRow(10)
            }
        }
    }

    private func hasRow(_ k: String, _ kind: HomeTag, _ v: String) -> some View {
        HStack {
            Text(k).font(t.homeText(15)).foregroundStyle(PN.C.text)
            Spacer(minLength: 8)
            HomeTagView(kind: kind, text: v)
        }
        .pageRow()
    }

    /// A time of the notes: a click opens the transcript at that line.
    @ViewBuilder private func timeLink(_ t: String, width w: CGFloat? = nil) -> some View {
        if t.isEmpty {
            if let w { Color.clear.frame(width: w, height: 1) }
        } else {
            Button { transcriptAt = t; tab = "transcript" } label: {
                Text(String(t.prefix(5))).font(PN.Font.caption.monospacedDigit()).foregroundStyle(PN.C.accent)
            }
            .buttonStyle(.plain).help(L("page.mn.jump")).accessibilityLabel(L("page.mn.jumpTo", ["time": String(t.prefix(5))]))
            .frame(width: w, alignment: .leading)
        }
    }

    @ViewBuilder private func itemRow(_ it: MeetingNotes.Item) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            timeLink(it.t, width: 38)
            Text(CallNotes.md(it.text)).font(PN.Font.body).lineSpacing(2).foregroundStyle(PN.C.text)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func makeMeeting() {
        making = true; makeNote = ""
        CallEngine.shared.makeMeetingNotes(file: file) { err in
            making = false
            if let err { makeNote = err } else { tick += 1 }
        }
    }

    /// Copy: Markdown as text and the same as rich text (HTML), so a paste into Notion, Google Docs, Word, Mail or
    /// Slack keeps the headings, lists and bold.
    private func copyMeeting() {
        guard let md = CallNotes.meetingMarkdown(file, title: Self.title(file)) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.html, .string], owner: nil)
        pb.setString(DocMD.html(DocMD.parse(md)), forType: .html)
        pb.setString(md, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
    }

    // MARK: What was discussed (the Summary before 0.9.5.2; 2026-11-05 redesign: the story on the left, what is next on the right)

    @ViewBuilder private func summaryTab(_ o: CallOutcome, _ agenda: [(text: String, state: String)]) -> some View {
        // 0.25 (R2, board CT row 1): the story on the left, a 360 pt column of what is next on the right
        PageColumns(side: 360) { summaryMain(o, agenda) } right: { summarySide(o, agenda) }
    }

    @ViewBuilder private func summaryMain(_ o: CallOutcome, _ agenda: [(text: String, state: String)]) -> some View {
        let short = CallNotes.inShort(file), topics = CallNotes.topics(file)
        PageCard(spacing: 0) {
            if short.isEmpty && topics.isEmpty {
                Text(o.line.isEmpty ? L("home.noNotes") : o.line).font(PN.Font.body).foregroundStyle(PN.C.text2)
                    .fixedSize(horizontal: false, vertical: true)
                if o.isEmpty && items.isEmpty && agenda.isEmpty {
                    Text(L("call.page.empty")).font(PN.Font.body).foregroundStyle(PN.C.text3).padding(.top, 8)
                }
            }
            if !short.isEmpty {
                PageLabel(text: L("page.sum.inShort")).padding(.bottom, 2)
                Text(CallNotes.md(short.joined(separator: " "))).font(t.homeText(17)).lineSpacing(3).foregroundStyle(PN.C.text)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if !short.isEmpty && !topics.isEmpty { Color.clear.frame(height: 24) }
            if !topics.isEmpty {
                let hasQuotes = topics.contains { !$0.quotes.isEmpty }
                PageLabel(text: L("page.sum.discussed")) {
                    if hasQuotes {
                        Button(allQuotes ? L("page.quotes.hideAll") : L("page.quotes.showAll")) { allQuotes.toggle(); openQuotes = [] }
                            .buttonStyle(.plain).font(t.homeText(14, .semibold)).foregroundStyle(PN.C.accent)
                    }
                }
                ForEach(Array(topics.enumerated()), id: \.offset) { i, tp in
                    topicRow(i, tp)
                }
            }
        }
    }

    /// 0.25 (R2, board CT row 1): the time as a link in its own 52 pt column, the title in the display face, the points
    /// as "·" lines, the quotes behind a thin line.
    @ViewBuilder private func topicRow(_ i: Int, _ tp: CallNotes.Topic) -> some View {
        let showQuotes = allQuotes || openQuotes.contains(i)
        HStack(alignment: .top, spacing: 12) {
            Group {
                if tp.time.isEmpty { Text("\(i + 1)").font(t.homeMono(12)).foregroundStyle(PN.C.text3) }
                else { PageTimeLink(time: tp.time) { transcriptAt = tp.time; tab = "transcript" } }
            }
            .frame(width: 52, alignment: .leading).padding(.top, 3)
            VStack(alignment: .leading, spacing: 4) {
                if !tp.title.isEmpty {
                    Text(CallNotes.md(tp.title)).font(t.homeDisplay(20, t.titleWeight)).tracking(t.dTrack * 20).foregroundStyle(PN.C.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(tp.body.enumerated()), id: \.offset) { _, b in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("·").font(t.homeText(15)).foregroundStyle(PN.C.text3).accessibilityHidden(true)
                        Text(CallNotes.md(b)).font(t.homeText(15)).lineSpacing(2).foregroundStyle(PN.C.text2)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !tp.quotes.isEmpty {
                    if showQuotes {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(tp.quotes.enumerated()), id: \.offset) { _, q in
                                Text(CallNotes.md(q)).font(t.homeText(14)).lineSpacing(2).foregroundStyle(PN.C.text3)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) { Rectangle().fill(PN.C.rule).frame(width: 2) }
                        .padding(.top, 4)
                    }
                    if !allQuotes {
                        HomeLink(showQuotes ? L("page.quotes.hide") : L("page.quotes.n", ["n": "\(tp.quotes.count)"]), size: 13) {
                            if showQuotes { openQuotes.remove(i) } else { openQuotes.insert(i) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .pageRow(12)
    }

    @ViewBuilder private func summarySide(_ o: CallOutcome, _ agenda: [(text: String, state: String)]) -> some View {
        let next = CallNotes.nextCall(file)
        VStack(alignment: .leading, spacing: 24) {
            if !next.isEmpty {
                PageCard(tint: PN.C.accent) {
                    PageLabel(text: nextCallLabel, color: PN.C.answer)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(next, id: \.self) { d in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Circle().fill(PN.C.accent).frame(width: 6, height: 6).offset(y: -2)
                                Text(CallNotes.md(d)).font(PN.Font.body).foregroundStyle(PN.C.text).lineSpacing(2)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            if !agenda.isEmpty {
                PageCard { agendaSection(agenda) }
            }
            PageCard {
                lines("open", L("call.page.open"), o.openQuestions) { saveLists(o, open: $0, section: "open") }
            }
        }
    }

    /// "FOR THE NEXT CALL · WED 15:00" when the calendar has the next call of this series.
    private var nextCallLabel: String {
        let key = EditLog.seriesKey(Self.title(file))
        let base = L("page.sum.next")
        guard let e = CalendarService.shared.events.first(where: { $0.start > Date() && EditLog.seriesKey($0.title) == key }) else { return base }
        let f = DateFormatter(); f.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US"); f.setLocalizedDateFormatFromTemplate("EEEHHmm")
        return base + " · " + f.string(from: e.start)
    }

    // MARK: Tasks (2026-11-05 redesign: On you and On them side by side, theirs grouped by person)

    @ViewBuilder private func tasksTab(_ o: CallOutcome, _ proj: Project?, _ ws: Workspace?) -> some View {
        // 0.12.2 (L4): a call without register items shows its one-rule tasks (notes, live picture, older notes)
        // 0.13.3 (L5): a picture task the PM touches is adopted into the register (by page), so a delete sticks
        let old = legacyTasks(o)
        let isMine: (CallLists.Task) -> Bool = { CommitmentRegister.legacyOwner($0, them: "").lowercased() == "me" }
        let mine = PageCard { commitments(items.filter { $0.mine }, mine: true, legacy: old.filter(isMine), proj, ws) }
        let theirs = PageCard { commitments(items.filter { !$0.mine }, mine: false, legacy: old.filter { !isMine($0) }, proj, ws) }
        PageColumns { mine } right: { theirs }      // 0.25 (R2, board CT row 3)
    }

    /// The actions of the bar (board CP): Ask about this call, Export, the rest in "...". 0.25 (R2): the follow-up
    /// email is a tab; Option-Command-I still opens it.
    @ViewBuilder private func barActions(_ proj: Project?, _ o: CallOutcome) -> some View {
        HStack(spacing: 10) {
            Button("") { tab = "followup" }.keyboardShortcut("i", modifiers: [.command, .option])
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            Button(L("page.ask")) { MemoryWindow.show(project: proj?.root ?? folderRoot) }
                .buttonStyle(.pnBar)
            Button(L("page.export")) { exportOpen.toggle() }.buttonStyle(.pnPrimary)
            Menu {
                // 0.9.1 (rules/google.yaml > meet): participants and, when Meet transcribed it, the Meet transcript
                if GoogleService.shared.accounts.contains(where: { $0.has(GoogleScopes.meet) }), let r = record {
                    Button(L("meet.get")) { getMeet(r) }
                    Divider()
                }
                if let u = record?.notionURL.flatMap({ URL(string: $0) }) { Button(L("home.recent.notion")) { NSWorkspace.shared.open(u) } }
                Button(L("home.recent.finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)]) }
                Button(L("reassign.menu")) { reassigning = true }       // 0.10.1 (A3)
                // 0.12.0 (B8b): one call kept off the server in a project that syncs
                if CallSyncService.shared.project(for: file) != nil {
                    let skipped = CallSync.State.load(CallSync.statePath(transcript: file))?.skip ?? false
                    Button(L(skipped ? "sync.call.allow" : "sync.call.skip")) { CallSyncService.shared.setSkip(!skipped, transcript: file) }
                }
                // 0.12.1 (B8): remove the server's copy of this call; the files on this Mac stay
                if CallSyncService.shared.canDelete(file) {
                    Button(L("sync.call.delete")) { confirmServerDelete = true }
                }
                Button(L("call.page.transcript")) { TranscriptWindow.show(file: file) }
                if let r = record, Self.series(of: r).count > 1 { Button(L("call.page.series", ["n": "\(Self.series(of: r).count)"])) { SeriesWindow.show(record: r) } }
                Divider()
                // 0.8.7 (I5, L2): Update <CRM> is always listed; without a connection it leads to Settings
                if CRMService.shared.connected {
                    Button(L("crm.update.title", ["crm": "HubSpot"])) { CRMUpdateWindow.show(file: file) }
                } else {
                    Button(L("crm.update.connect")) { SettingsWindow.show(tab: "hubspot") }
                }
            } label: { Image(systemName: "ellipsis").foregroundStyle(PN.C.text2) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 32, height: 32).accessibilityLabel(L("home.more"))
        }
    }

    /// <stem>.meet.md next to the transcript; the call's own transcript is not changed, its unnamed voices get Meet names (0.9.4).
    private func getMeet(_ r: CallHistory.Record) {
        meetNote = L("meet.looking")
        let end = r.end ?? r.start.addingTimeInterval((r.minutes ?? 60) * 60)
        let code = CalendarService.shared.events.first { abs($0.start.timeIntervalSince(r.start)) < 1800 && $0.meetCode != nil }?.meetCode
        let out = (file.hasSuffix(".md") ? String(file.dropLast(3)) : file) + ".meet.md"
        Task {
            do {
                guard let m = try await GoogleService.shared.meet(code: code, start: r.start, end: end) else { meetNote = L("meet.none"); return }
                // 0.9.4: the same as after End call: <stem>.meet.md and the voices named from Meet
                MeetAfterCall.apply(stem: String(out.dropLast(8)), meet: m, title: r.title)
                UsageLog.log("google_meet", ["transcript": !m.transcript.isEmpty])
                meetNote = m.transcript.isEmpty ? L("meet.savedNoTranscript", ["n": "\(m.participants.count)"]) : L("meet.saved")
                NSWorkspace.shared.open(URL(fileURLWithPath: out))
            } catch { meetNote = error.localizedDescription }
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
        CallPageEdit.save(file: file, decisions: decisions ?? o.decisions, open: open ?? o.openQuestions, risks: risks ?? o.risks, lists: [section])
        changed(section)
        if section == "decisions" || section == "risks" {   // 0.12.2 (L2, L3): the PM's edits go to the server too (only the changed part)
            let f = file
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { MainActor.assumeIsolated { CallSyncService.shared.sync(f) } }
        }
    }

    private var bullet: some View { Text("•").font(PN.Font.body).foregroundStyle(PN.C.text3) }

    /// 2026-11-05 (redesign): every block opens with the same small uppercase label as "In short".
    private func heading(_ t: String, _ tail: String = "") -> some View {
        PageLabel(text: t) { if !tail.isEmpty { PageCount(text: tail) } }      // 0.25 (R2): a flat section head
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
    /// 2026-11-05 (redesign): On them is grouped by person, the name once with its initials.
    @ViewBuilder private func commitments(_ list: [Commitment], mine: Bool, legacy: [CallLists.Task], _ proj: Project?, _ ws: Workspace?) -> some View {
        let section = mine ? "onYou" : "onThem"
        let open = list.filter { $0.status == "open" }.count + legacy.count
        let owners: [String] = mine ? [""] : list.reduce(into: [String]()) { if !$0.contains($1.owner) { $0.append($1.owner) } }
        VStack(alignment: .leading, spacing: 2) {
            PageSectionHead(title: mine ? L("call.page.onYou") : L("call.page.onThem"),
                            count: list.isEmpty && legacy.isEmpty ? "" : L("page.tasks.open", ["n": "\(open)"]), warn: mine && open > 0)
            if list.isEmpty && legacy.isEmpty {
                Text(L(mine ? "page.tasks.noneOnYou" : "page.tasks.noneOnThem")).font(t.homeText(15)).foregroundStyle(PN.C.text3).pageRow()
            }
            ForEach(owners, id: \.self) { who in
                if !mine {
                    // 0.25 (R2, board CT row 3): the person's tile and name over their tasks
                    HStack(spacing: 8) {
                        PageAvatar(name: who)
                        Text(t.cased(who)).font(t.homeDisplay(16, .heavy)).tracking(t.style == .classic ? 0 : t.bTrack * 16).foregroundStyle(PN.C.text2)
                    }
                    .padding(.top, 10).padding(.bottom, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { Rectangle().fill(PN.C.rule).frame(height: 1) }
                }
                ForEach(list.filter { mine || $0.owner == who }) { c in commitmentRow(c, section: section) }
            }
            ForEach(Array(legacy.enumerated()), id: \.offset) { _, t in
                let shown = mine ? t.text : t.line
                EditableRow(text: shown, copy: shown, menu: legacyMenu(t, mine: mine, section, proj, ws), onSave: { v in
                    var v = v.trimmingCharacters(in: .whitespaces)
                    if !t.due.isEmpty, v.hasSuffix(" (due: " + t.due + ")") { v = String(v.dropLast(t.due.count + 8)) }
                    let parts = v.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if !mine, parts.count == 2, !parts[0].isEmpty, parts[0].count <= 40 {
                        adoptLegacy(t, section, proj, ws) { CommitmentRegister.edit(folder: folder, id: $0, text: parts[1], owner: parts[0]) }
                    } else {
                        adoptLegacy(t, section, proj, ws) { CommitmentRegister.edit(folder: folder, id: $0, text: v) }
                    }
                }) {
                    Toggle("", isOn: Binding(get: { false }, set: { on in
                        if on { adoptLegacy(t, section, proj, ws) { CommitmentRegister.mark(folder: folder, id: $0, op: "done") } }
                    }))
                    .toggleStyle(.pnCheckbox).labelsHidden().accessibilityLabel(L("reg.markDoneA11y", ["text": t.text]))
                }
                .padding(.vertical, 3)
            }
            AddRowField(placeholder: mine ? L("callEdit.addPh") : L("callEdit.addTheirsPh")) { v in
                if mine { addItem(v, owner: "me", proj, ws) } else {
                    let parts = v.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if parts.count == 2, !parts[0].isEmpty, parts[0].count <= 40, !parts[1].isEmpty { addItem(parts[1], owner: parts[0], proj, ws) }
                    else { addItem(v, owner: L("callEdit.them"), proj, ws) }
                }
                changed(section)
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder private func commitmentRow(_ c: Commitment, section: String) -> some View {
        let overdue = c.status == "open" && CommitmentRegister.isOverdue(c)
        // 0.8.7 (J4): only the due date is red when overdue, never the owner
        // 0.8.8: an item sent to the Notion tasks (by a click or the automatic add) says so
        // 0.25 (R2 tail, board CT row 3): the due date in its own column on the right, red only when late
        EditableRow(text: c.text, sub: c.mine && !c.notionPage.isEmpty ? L("call.page.inNotionTasks") : "", subColor: PN.C.text3,
                    subTail: "", done: c.status == "done",
                    copy: (c.mine ? "" : c.owner + ": ") + c.text + (c.due.isEmpty ? "" : " (" + Register.dueText(c.due) + ")"),
                    menu: commitmentMenu(c, section),
                    onSave: { v in register.edit(c, text: v); changed(section) },
                    leading: {
                        Toggle("", isOn: Binding(get: { c.status == "done" }, set: { register.mark(c, $0 ? "done" : "reopen") }))
                            .toggleStyle(.pnCheckbox).labelsHidden().accessibilityLabel(L("reg.markDoneA11y", ["text": c.text]))
                    },
                    trailing: {
                        Text(c.status == "done" ? L("page.tasks.doneWord") : c.due.isEmpty ? L("page.tasks.noDate") : Register.dueText(c.due))
                            .font(t.homeMono(12, .semibold)).foregroundStyle(overdue ? PN.C.recText : PN.C.text3).lineLimit(1).fixedSize()
                    })
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
        // 0.13.3 (L5): by page, so an old call's untouched picture tasks keep showing next to it
        register.add(folder: folder, text: text, owner: owner, project: slug, title: Self.title(file), call: file, by: CommitmentRegister.pageBy)
    }

    /// 0.13.3 (L5): the PM touched a picture task of an old call: it goes into the register (op add, by page), then
    /// the PM's op is applied to it. From then on it shows from the register; dropped, it never comes back.
    private func adoptLegacy(_ t: CallLists.Task, _ section: String, _ proj: Project?, _ ws: Workspace?, _ op: (String) -> Void) {
        let slug = proj?.slug ?? ws?.name ?? record?.project ?? ""
        guard let id = CommitmentRegister.adopt(t, folder: folder, project: slug, title: Self.title(file), call: file, them: L("callEdit.them")) else { return }
        op(id)
        register.touch(folder)
        changed(section)
    }

    /// 0.13.3 (L5): the same menu as a register item's (commitmentMenu), for a picture task of an old call.
    private func legacyMenu(_ t: CallLists.Task, mine: Bool, _ section: String, _ proj: Project?, _ ws: Workspace?) -> [PageRowAction] {
        let edit: (String?, String?) -> Void = { owner, due in
            adoptLegacy(t, section, proj, ws) { CommitmentRegister.edit(folder: folder, id: $0, owner: owner, due: due) }
        }
        var m: [PageRowAction] = [PageRowAction(title: L("reg.markDone"), run: { _ in
            adoptLegacy(t, section, proj, ws) { CommitmentRegister.mark(folder: folder, id: $0, op: "done") } })]
        if mine {
            m.append(PageRowAction(title: L("callEdit.moveOnThem"), prompt: .text(title: L("callEdit.moveOnThem"), value: "", placeholder: L("callEdit.ownerPh")),
                                   run: { v in guard !v.isEmpty else { return }; edit(v, nil) }))
        } else {
            m.append(PageRowAction(title: L("callEdit.moveOnYou"), run: { _ in edit("me", nil) }))
        }
        m.append(PageRowAction(title: L("callEdit.changeOwner"), prompt: .text(title: L("callEdit.changeOwner"), value: mine ? "" : t.owner, placeholder: L("callEdit.ownerPh")),
                               run: { v in edit(v.isEmpty ? "me" : v, nil) }))
        m.append(PageRowAction(title: L("callEdit.setDue"), prompt: .date(value: t.due), run: { v in edit(nil, v) }))
        m.append(.separator)
        m.append(PageRowAction(title: L("callEdit.delete"), destructive: true, run: { _ in
            adoptLegacy(t, section, proj, ws) { CommitmentRegister.mark(folder: folder, id: $0, op: "drop") } }))
        return m
    }

    /// 0.8.7 (E3): the agenda; the state is a chip on the right, a click moves it on and saves a new agenda line.
    @ViewBuilder private func agendaSection(_ agenda: [(text: String, state: String)]) -> some View {
        let save: ([(text: String, state: String)]) -> Void = { CallPageEdit.saveAgenda(file: file, items: $0); changed("agenda") }
        VStack(alignment: .leading, spacing: 2) {
            let done = agenda.filter { $0.state == "done" }.count
            heading(L("call.page.agenda"), L("page.agenda.progress", ["done": "\(done)", "n": "\(agenda.count)"]))
            PageProgress(value: agenda.isEmpty ? 0 : Double(done) / Double(agenda.count)).padding(.bottom, 6)
            ForEach(Array(agenda.enumerated()), id: \.offset) { i, a in
                EditableRow(text: a.text, copy: a.text,
                            menu: [.separator, PageRowAction(title: L("callEdit.delete"), destructive: true, run: { _ in
                                var l = agenda; if i < l.count { l.remove(at: i) }; save(l) })],
                            onSave: { v in var l = agenda; if i < l.count { l[i].text = v }; save(l) },
                            leading: { EmptyView() },       // 0.25 (R2, board CT): no bullet, the tag on the right
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
                Text(title).pnSection().foregroundStyle(PN.C.text)
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
        PageCard(spacing: 2) {
            PageSectionHead(title: L("call.page.risks"), count: o.risks.isEmpty ? "" : "\(o.risks.count)")
            let _ = links.n
            if o.risks.isEmpty { PageEmpty(icon: "exclamationmark.triangle", title: L("page.empty.risks"), text: L("page.empty.risks.body")) }
            ForEach(Array(o.risks.enumerated()), id: \.offset) { i, r in
                let known = added[r] ?? NotionCallLinks.url(file, "risks", r)     // 0.8.8: kept next to the call
                let inRegister = known != nil
                let addAction = PageRowAction(title: L("risk.add"), icon: "exclamationmark.shield", enabled: hasDB, note: L("risk.noDB"),
                                              run: { _ in addRisk(r, proj) })
                EditableRow(text: r, copy: r,
                            menu: (inRegister ? [] : [addAction]) + [.separator, PageRowAction(title: L("callEdit.delete"), destructive: true, run: { _ in
                                var l = o.risks; if i < l.count { l.remove(at: i) }; saveLists(o, risks: l, section: "risks") })],
                            hoverButton: inRegister ? nil : addAction,
                            onSave: { v in var l = o.risks; if i < l.count { l[i] = v }; saveLists(o, risks: l, section: "risks") },
                            leading: { PageIconTile(icon: "exclamationmark.triangle", color: PN.C.onMe) },
                            trailing: {
                                if inRegister {
                                    if let u = known.flatMap({ URL(string: $0) }), !(known ?? "").isEmpty {
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
        // 2026-11-05 (owner): every block is as wide as the header card
    }

    /// 0.8.8 (rules/decisions.yaml > after_call): "Add to decision register" on a row and "Add all N" above the section.
    /// Greyed out with the reason (and Settings) without Notion, a project or a Decisions database.
    @ViewBuilder private func decisionsSection(_ o: CallOutcome, _ proj: Project?, _ ws: Workspace?) -> some View {
        let c = SettingsWindow.model.config
        let token = SettingsWindow.model.isSet(.notionToken)
        let hasDB = token && proj != nil && !NotionTargets.decisionsDB(c, proj).isEmpty
        let reason = !token ? L("dec.noNotion") : proj == nil ? L("dec.noProject") : L("dec.noDB")
        let _ = links.n
        let decs = decisions(o)
        let pending = decs.filter { NotionCallLinks.url(file, "decisions", $0) == nil }
        let set: ([String]) -> Void = { saveLists(o, decisions: $0, section: "decisions") }
        let root = cardRoot(proj, ws)
        PageCard(spacing: 2) {
            PageSectionHead(title: L("call.page.decisions"), count: decs.isEmpty ? "" : "\(decs.count)") {
                if hasDB && pending.count > 1 {
                    Button(L("dec.addAll", ["n": "\(pending.count)"])) { addDecisions(pending, proj) }
                        .buttonStyle(.pnBar).disabled(!adding.isEmpty)
                }
            }
            if decs.isEmpty { PageEmpty(icon: "checkmark.seal", title: L("page.empty.decisions"), text: L("page.empty.decisions.body")) }
            if !hasDB && !decs.isEmpty {
                HStack(spacing: 6) {
                    Text(reason).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    Button(L("common.openSettings")) { SettingsWindow.show(tab: "notion") }.buttonStyle(.link).font(PN.Font.caption)
                }
            }
            ForEach(Array(decs.enumerated()), id: \.offset) { i, d in
                let url = NotionCallLinks.url(file, "decisions", d)
                let add = PageRowAction(title: L("dec.add"), icon: "checkmark.seal", enabled: hasDB && !adding.contains(d), note: reason,
                                        run: { _ in addDecisions([d], proj) })
                EditableRow(text: d, copy: d,
                            menu: (url == nil ? [add] : []) + [saveCardAction("", d, root: root), .separator,
                                  PageRowAction(title: L("callEdit.delete"), destructive: true, run: { _ in
                                      var l = decs; if i < l.count { l.remove(at: i) }; set(l) })],
                            hoverButton: url == nil ? add : nil,
                            onSave: { v in var l = decs; if i < l.count { l[i] = v }; set(l) },
                            leading: { PageIconTile(icon: "checkmark", color: PN.C.turn) },
                            trailing: {
                                if let url {
                                    if let u = URL(string: url), !url.isEmpty {
                                        Button(L("dec.inRegister")) { NSWorkspace.shared.open(u) }.buttonStyle(.link)
                                            .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                                    } else {
                                        Text(L("dec.inRegister")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                                    }
                                } else if adding.contains(d) {
                                    PNSpinner(size: 16)
                                }
                            })
                if let s = supersede[d] { supersedeRow(d, s) }
            }
            AddRowField(placeholder: L("callEdit.addPh")) { set(decs + [$0]) }
            Text(L("dec.footnote")).font(t.homeText(13)).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true).padding(.top, 12)
        }
        // 2026-11-05 (owner): every block is as wide as the header card
    }

    /// "Replaces <old, date>?": only this click marks the old decision Superseded and links the two.
    @ViewBuilder private func supersedeRow(_ d: String, _ s: [String: String]) -> some View {
        HStack(spacing: 8) {
            Text("⇄").foregroundStyle(PN.C.text3).accessibilityHidden(true)
            Text(L("dec.replaces", ["title": s["title"] ?? "", "date": s["date"] ?? ""])).font(t.homeText(14)).foregroundStyle(PN.C.text2)
                .fixedSize(horizontal: false, vertical: true)
            Button(L("dec.replaceYes")) { replace(d, s) }.buttonStyle(.pnRow).padding(.leading, 8)
            HomeLink(L("dec.replaceNo")) { supersede[d] = nil }
            Spacer()
        }
        .padding(.leading, 38).padding(.bottom, 12)
    }

    private func replace(_ d: String, _ s: [String: String]) {
        let c = SettingsWindow.model.config
        let p = PyTool.project(of: file).project
        guard let old = s["id"], let new = NotionCallLinks.pageId(file, "decisions", d), !new.isEmpty else { return }
        PyTool.run("decision_notion", ["--db", NotionTargets.decisionsDB(c, p), "--supersede", old, "--new", new], notion: true, needsAI: false) { r in
            if (r["ok"] as? Bool) == true {
                supersede[d] = nil; note = L("dec.superseded", ["title": s["title"] ?? ""]); UsageLog.log("decision_superseded")
            } else { note = L("dec.failed", ["err": r["error"] as? String ?? ""]) }
        }
    }

    /// One at a time, so <stem>.notion.json is written by one process; "Add all" skips the supersede check.
    private func addDecisions(_ list: [String], _ proj: Project?, all: Bool? = nil) {
        let all = all ?? (list.count > 1)     // 0.8.8.1: the last item of "Add all" ran the supersede check too
        guard let p = proj, let d = list.first else { return }
        adding.insert(d)
        note = L("dec.adding")
        let c = SettingsWindow.model.config
        let when = record.map { DateFormatter.localizedString(from: $0.start, dateStyle: .medium, timeStyle: .short) } ?? ""
        var args = ["--db", NotionTargets.decisionsDB(c, p), "--title", d, "--call-file", file, "--call", Self.title(file) + ", " + when]
        if let u = record?.notionURL, !u.isEmpty { args += ["--source", u] }
        if all { args.append("--no-supersede-check") }
        PyTool.run("decision_notion", args + NotionTargets.projectArgs(c, p, kind: "decisions"), notion: true) { r in
            adding.remove(d)
            if (r["ok"] as? Bool) == true {
                note = ""
                if (r["existing"] as? Bool) != true { UsageLog.log("decision_added") }
                if let s = r["supersede"] as? [String: Any], let id = s["id"] as? String {
                    supersede[d] = ["id": id, "title": (s["title"] as? String) ?? "", "date": (s["date"] as? String) ?? ""]
                }
                links.bump()
            } else {
                note = L("dec.failed", ["err": r["error"] as? String ?? ""])
            }
            if list.count > 1 { addDecisions(Array(list.dropFirst()), proj, all: all) }
        }
    }

    /// 0.25 (R2 tail, board CT row 4): asks in a sheet in the style first; addRiskNow writes it.
    private func addRisk(_ text: String, _ proj: Project?) {
        guard proj != nil else { return }
        riskAsk = RiskAsk(text: text)
    }

    private func addRiskNow(_ text: String, _ proj: Project?) {
        guard let p = proj else { return }
        let when = record.map { DateFormatter.localizedString(from: $0.start, dateStyle: .medium, timeStyle: .short) } ?? ""
        note = L("risk.adding")
        let c = SettingsWindow.model.config
        PyTool.run("risk_notion", ["--db", NotionTargets.risksDB(c, p), "--title", text, "--call", Self.title(file) + ", " + when, "--call-file", file]
                   + NotionTargets.projectArgs(c, p, risks: true), notion: true) { r in
            if (r["ok"] as? Bool) == true { added[text] = (r["url"] as? String) ?? ""; note = ""; UsageLog.log("risk_added") } else { note = L("risk.failed", ["err": r["error"] as? String ?? ""]) }
        }
    }
}

/// 0.8.7 (E3): an agenda item's state on the call page: discussed (green), raised (orange), not raised (grey).
/// 0.13.0 (B8 part 2, step 1): one line under the title with the call's consent record (CallConsent, from the tips
/// files). Local only.
struct CallConsentLine: View {
    let file: String
    @State private var state = CallConsent.State()

    private func time(_ d: Date?) -> String { d.map { CallPageView.fmt("jmm").string(from: $0) } ?? "" }

    private var text: String {
        switch state.mode {
        case .said where state.posted != nil, .posted where state.said != nil:
            return L("consent.page.saidPosted", ["said": time(state.said), "posted": time(state.posted)])
        case .said: return L("consent.page.said", ["time": time(state.at)])
        case .posted: return L("consent.page.posted", ["time": time(state.at)])
        case .none: return L("consent.page.none")
        case .unknown: return L("consent.page.unknown")
        }
    }

    /// 0.25 (R2, board SL): the value of the Consent line, without the "Consent:" of the older caption.
    private var value: String {
        switch state.mode {
        case .said where state.posted != nil, .posted where state.said != nil:
            return L("consent.line.saidPosted", ["said": time(state.said), "posted": time(state.posted)])
        case .said: return L("consent.line.said", ["time": time(state.at)])
        case .posted: return L("consent.line.posted", ["time": time(state.at)])
        case .none: return L("consent.line.none")
        case .unknown: return L("consent.line.unknown")
        }
    }

    var body: some View {
        let ok = state.mode == .said || state.mode == .posted
        PageStatusLine(key: L("consent.line.key"), kind: ok ? .ready : .neutral, value: value)
            .onAppear { state = CallConsent.read(transcript: file) }
    }
}

struct AgendaChip: View {
    let state: String
    let next: () -> Void
    // 0.25 (R2, board CT row 1): the state as the boards' tag: Discussed (ready), Raised (not ready), Not raised (grey)
    var body: some View {
        let kind: HomeTag = state == "done" ? .ready : (state == "now" || state == "raised") ? .notReady : .neutral
        Button(action: next) {
            HomeTagView(kind: kind, text: L(state == "done" ? "call.page.discussed" : (state == "now" || state == "raised") ? "call.page.raised" : state == "skip" ? "call.page.skipped" : "call.page.notRaised"))
                .contentShape(Rectangle())
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
    @State private var who: String? = nil       // 2026-11-05 (redesign): one speaker only
    @State private var lines: [TranscriptLine] = []
    @Environment(\.pnTheme) private var t

    private var target: Int? {
        guard let at = at else { return nil }
        return lines.first { $0.t >= at }?.id ?? lines.last?.id
    }

    /// The speakers with the most lines first (at most 6 chips).
    private var speakers: [String] {
        var n: [String: Int] = [:]
        for l in lines { n[l.who, default: 0] += 1 }
        return n.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(6).map(\.key)
    }

    /// Lines in a row from the same speaker are one turn: the name and the time once.
    private var turns: [[TranscriptLine]] {
        let shown = lines.filter { l in
            (who == nil || l.who == who) && (q.isEmpty || l.text.localizedCaseInsensitiveContains(q) || l.who.localizedCaseInsensitiveContains(q))
        }
        var out: [[TranscriptLine]] = []
        for l in shown {
            if let last = out.last?.last, last.who == l.who, last.id + 1 == l.id { out[out.count - 1].append(l) } else { out.append([l]) }
        }
        return out
    }

    var body: some View {
        Group {
        VStack(spacing: 0) {
            // 0.25 (R2, board CT row 6): find, the speaker chips in the field look, Show in Finder; a rule under it
            HStack(spacing: 10) {
                TextField("", text: $q, prompt: Text(L("transcript.find"))).labelsHidden().pageField(32)
                    .frame(maxWidth: 300)
                if speakers.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            chip(L("transcript.everyone"), on: who == nil) { who = nil }
                            ForEach(speakers, id: \.self) { s in chip(s, on: who == s) { who = who == s ? nil : s } }
                        }
                    }
                    .padding(.leading, 6)
                }
                Spacer(minLength: 0)
                Button(L("home.recent.finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)]) }.buttonStyle(.pnBar)
            }
            .padding(.horizontal, PageMetrics.side).padding(.vertical, 16)
            .overlay(alignment: .bottom) { Rectangle().fill(PN.C.rule).frame(height: 1) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(turns, id: \.first!.id) { turn in
                            let first = turn[0]
                            HStack(alignment: .top, spacing: 14) {
                                Text(first.t).font(t.homeMono(12)).monospacedDigit().foregroundStyle(PN.C.text3)
                                    .frame(width: 62, alignment: .leading).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(t.caps ? first.who.uppercased() : first.who).font(t.homeMono(12, .semibold)).foregroundStyle(first.me ? PN.C.text : PN.C.text2)
                                    ForEach(turn) { l in
                                        let hit = l.id == target
                                        Text(l.text).font(t.homeText(16)).lineSpacing(2).foregroundStyle(PN.C.text).textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .padding(.horizontal, hit ? 8 : 0).padding(.vertical, hit ? 2 : 0)
                                            .background(hit ? PN.C.surface2 : .clear)
                                            .overlay(alignment: .leading) { if hit { Rectangle().fill(PN.C.accent).frame(width: 3) } }
                                            .id(l.id)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, PageMetrics.side).padding(.vertical, 10)
                            .background(first.me ? PN.C.surface2 : Color.clear)
                        }
                        if lines.isEmpty {
                            Text(L("transcript.empty")).font(t.homeText(15)).foregroundStyle(PN.C.text3).padding(PageMetrics.side)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .onAppear {
                    lines = TranscriptLine.read(file, me: PyTool.meLabel)
                    if let t = target { DispatchQueue.main.async { proxy.scrollTo(t, anchor: .center) } }
                }
            }
        }
        .background(PN.C.bg)
    }
        .trackScreen("call_page", sub: "transcript", o: CallSyncService.shared.callOrg(of: file))
    }

    private func chip(_ label: String, on: Bool, _ tap: @escaping () -> Void) -> some View {
        let fill: Color = on ? (t.hlBg.map { Color(pnHex: $0) } ?? PN.C.text) : .clear
        let ink: Color = on ? (t.hlBg != nil ? Color(pnHex: t.hlFg) : PN.C.bg) : PN.C.text2
        let shape = RoundedRectangle(cornerRadius: t.style == .classic ? 6 : 0)
        return Button(action: tap) {
            Text(t.caps ? label.uppercased() : label).font(t.homeMono(12, .semibold)).lineLimit(1)
                .foregroundStyle(ink)
                .padding(.horizontal, 10).frame(height: 28)
                .background(fill, in: shape)
                .overlay(shape.strokeBorder(on ? fill : PN.C.field, lineWidth: 1.5))
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Follow-up email

/// Idea 04 (rules/followup.yaml): a draft in the client's language to edit, Copy or Open in Mail. Nothing is sent.
/// 0.8.7 (A3): the follow-up email is the call page's right panel, not a window.
@MainActor
enum FollowUpWindow {
    static func show(file: String) {
        guard ModuleGate.allow("followup") else { return }          // 0.18.0 (B3)
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
    /// 0.25 (R2, board CT row 5): the Follow-up tab of the call page, in the boards' look.
    var page = false
    @ObservedObject var model: FollowUpModel
    @State private var instruction = ""
    @Environment(\.pnTheme) private var t

    init(file: String, page: Bool = false) { self.file = file; self.page = page; self.model = FollowUpModel.of(file) }

    var body: some View {
        if page { pageBody } else { panelBody }
    }

    private var lessons: Int { Learning.standing(EditLog.all(), kinds: ["followup_instruction", "followup_edit"]).count }

    private var pageBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            PageSectionHead(title: L("followup.tabTitle")) {
                if lessons > 0 { Text(L("followup.uses", ["n": "\(lessons)"])).font(t.homeText(13)).foregroundStyle(PN.C.text3) }
            }
            Text(L("followup.note")).font(t.homeText(14)).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            if model.busy {
                HStack(spacing: 8) { PNSpinner(size: 16); Text(L("followup.writing")).font(t.homeText(14)).foregroundStyle(PN.C.text2) }
            }
            if !model.error.isEmpty { Text(model.error).font(t.homeText(13)).foregroundStyle(PN.C.recText) }
            if !model.body.isEmpty || !model.subject.isEmpty {
                Text(t.caps ? L("followup.subject").uppercased() : L("followup.subject"))
                    .font(t.homeMono(11, t.labelWeight)).tracking(t.style == .classic ? 0 : t.lblTrack * 11).foregroundStyle(PN.C.text3)
                    .padding(.top, 4)
                TextField("", text: $model.subject).labelsHidden().pageField(36)
                TextEditor(text: $model.body).font(t.homeText(15)).lineSpacing(3)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(minHeight: 280)
                    .background(PN.C.surface)
                    .overlay(RoundedRectangle(cornerRadius: t.style == .classic ? 6 : 0).strokeBorder(PN.C.field, lineWidth: 1.5))
                HStack(spacing: 8) {
                    TextField("", text: $instruction, prompt: Text(L("after.instruct"))).pageField(32)
                        .onSubmit { model.revise(instruction); instruction = "" }
                    Button(L("after.rewrite")) { model.revise(instruction); instruction = "" }.buttonStyle(.pnBar)
                        .disabled(instruction.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
                }
                HStack(spacing: 10) {
                    Button(L("after.copy")) { model.copy() }.buttonStyle(.pnPrimary).disabled(model.body.isEmpty).fixedSize()
                    Button(L("after.openMail")) { model.openMail() }.buttonStyle(.pnBar).disabled(model.body.isEmpty).fixedSize()
                    Text(L("after.neverSends")).font(t.homeText(13)).foregroundStyle(PN.C.text3).padding(.leading, 6)
                    Spacer()
                    HomeLink(L("followup.again")) { model.write() }.disabled(model.busy).fixedSize()
                }
                .padding(.top, 4)
            }
        }
        .onAppear { if model.body.isEmpty && !model.busy && model.error.isEmpty { model.write() } }
        .onDisappear { model.logHandEdits() }
    }

    private var panelBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("followup.note")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            if model.busy {
                HStack(spacing: 8) { PNSpinner(size: 16); Text(L("followup.writing")).foregroundStyle(PN.C.text2) }
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
                // 0.8.7.1: in the 380 pt panel the caption squeezed the buttons ("Write ag...", "Open in Mail" on two lines)
                HStack(spacing: 8) {
                    Button(L("after.copy")) { model.copy() }.buttonStyle(.pnPrimary).disabled(model.body.isEmpty).fixedSize()
                    Button(L("after.openMail")) { model.openMail() }.buttonStyle(.pnSecondary).disabled(model.body.isEmpty).fixedSize()
                    Spacer()
                    Button(L("followup.again")) { model.write() }.buttonStyle(.pnTertiary).disabled(model.busy).fixedSize()
                }
                Text(L("after.neverSends")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
        }
        .padding(20)
        .background(PN.C.bg)
        .onAppear { if model.body.isEmpty && !model.busy && model.error.isEmpty { model.write() } }
        .onDisappear { model.logHandEdits() }
    }
}

// MARK: - Call page building blocks (2026-11-05 redesign, in the style of Home)
// 0.25 (R2): on the call pages (environment pageFlat) a block is a flat section by the boards CP, CT, UT, SL: no card,
// a heavy rule over its name, rows split by thin rules. Elsewhere (Meeting Sheet, prep windows) the cards stay as they were.

enum PageStyle { static let radius: CGFloat = 16 }

private struct PageFlatKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// 0.25 (R2): the call pages draw their blocks flat (boards CP, CT, UP, UT, SL).
    var pageFlat: Bool { get { self[PageFlatKey.self] } set { self[PageFlatKey.self] = newValue } }
}

/// A white block on the grey page, like Home's cards. `tint`: a soft accent wash and border (For the next call).
/// 0.25 (R2): flat on the call pages; a tinted one is the surface2 block with a 3 pt line on top.
struct PageCard<Content: View>: View {
    var spacing: CGFloat = 10
    var tint: Color? = nil
    @ViewBuilder var content: () -> Content
    @Environment(\.pageFlat) private var flat
    var body: some View {
        if flat {
            if tint != nil {
                VStack(alignment: .leading, spacing: spacing) { content() }.pageTint()
            } else {
                VStack(alignment: .leading, spacing: spacing) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: spacing) { content() }
                .padding(.horizontal, 24).padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: PageStyle.radius).fill(PN.C.surface)
                        if let tint { RoundedRectangle(cornerRadius: PageStyle.radius).fill(tint.opacity(0.06)) }
                    }
                }
                .overlay { if let tint { RoundedRectangle(cornerRadius: PageStyle.radius).stroke(tint.opacity(0.22)) } }
        }
    }
}

/// The small uppercase label of a block, with an optional note or action on the right.
/// 0.25 (R2): on the call pages the head of a section (heavy rule, the style's section face).
struct PageLabel<Trailing: View>: View {
    let text: String
    var color: Color = PN.C.text3
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.pageFlat) private var flat
    var body: some View {
        if flat {
            PageSectionHead(title: text, trailing: trailing)
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text(text.uppercased()).pnLabel().kerning(0.4).foregroundStyle(color)
                Spacer(minLength: 8)
                trailing()
            }
        }
    }
}

extension PageLabel where Trailing == EmptyView {
    init(text: String, color: Color = PN.C.text3) { self.init(text: text, color: color, trailing: { EmptyView() }) }
}

struct PagePill: View {
    let text: String
    let color: Color
    @Environment(\.pageFlat) private var flat
    var body: some View {
        if flat {
            HomeField(text: text, height: 28)
        } else {
            Text(text).font(PN.sys(12, .semibold)).foregroundStyle(color).lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: PN.r(6)))
        }
    }
}

/// Initials in a circle, for the person a task is on. 0.25 (R2): on the call pages a 24 pt tile (square in Roadbook).
struct PageAvatar: View {
    let name: String
    @Environment(\.pageFlat) private var flat
    @Environment(\.pnTheme) private var t
    var body: some View {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "." }).prefix(2)
        let ini = parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
        if flat {
            Text(ini.isEmpty ? "?" : ini).font(t.homeMono(10, .semibold)).foregroundStyle(PN.C.text)
                .frame(width: 24, height: 24)
                .background(PN.C.surface2, in: RoundedRectangle(cornerRadius: t.statusSquare ? 0 : 12))
                .overlay(RoundedRectangle(cornerRadius: t.statusSquare ? 0 : 12).strokeBorder(PN.C.rule, lineWidth: 1))
                .accessibilityHidden(true)
        } else {
            Text(ini.isEmpty ? "?" : ini).font(PN.sys(10, .bold)).foregroundStyle(PN.C.answer)
                .frame(width: 22, height: 22).background(Circle().fill(PN.C.accent.opacity(0.13)))
                .accessibilityHidden(true)
        }
    }
}

/// A row's kind as a small tinted square (a decision, a risk).
/// 0.25 (R2): on the call pages an outlined 22 pt square: ✓ in the ready colour, ! on the not-ready plate (board CT).
struct PageIconTile: View {
    let icon: String
    let color: Color
    @Environment(\.pageFlat) private var flat
    @Environment(\.pnTheme) private var t
    var body: some View {
        if flat {
            let risk = icon.contains("exclamation")
            let shape = RoundedRectangle(cornerRadius: t.statusSquare ? 0 : 11)
            Text(risk ? "!" : "✓").font(t.homeText(13, .heavy))
                .foregroundStyle(risk ? PN.C.notreadyText : PN.C.readyText)
                .frame(width: 22, height: 22)
                .background(risk ? (t.nrBg.map { Color(pnHex: $0) } ?? .clear) : .clear, in: shape)
                .overlay(shape.strokeBorder(risk ? PN.C.notready : PN.C.ready, lineWidth: 1.5))
                .accessibilityHidden(true)
        } else {
            Image(systemName: icon).font(PN.sys(11, .semibold)).foregroundStyle(color)
                .frame(width: 22, height: 22).background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: PN.r(6)))
                .accessibilityHidden(true)
        }
    }
}

/// An empty block: what would be here and how it gets here.
struct PageEmpty: View {
    let icon: String
    let title: String
    let text: String
    @Environment(\.pageFlat) private var flat
    @Environment(\.pnTheme) private var t
    var body: some View {
        if flat {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(t.homeText(16, .semibold)).foregroundStyle(PN.C.text)
                Text(text).font(t.homeText(14)).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            }
            .pageRow(10)
        } else {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon).font(PN.sys(14, .medium)).foregroundStyle(PN.C.text3)
                    .frame(width: 34, height: 34).background(Circle().fill(PN.C.surface2)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(PN.Font.body.weight(.semibold)).foregroundStyle(PN.C.text)
                    Text(text).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
        }
    }
}

struct PageProgress: View {
    let value: Double
    @Environment(\.pageFlat) private var flat
    var body: some View {
        if flat {
            Rectangle().fill(PN.C.rule).frame(height: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { g in Rectangle().fill(PN.C.ready).frame(width: max(0, min(1, value)) * g.size.width) }
                }
                .accessibilityElement().accessibilityLabel(L("page.agenda.a11y")).accessibilityValue("\(Int(value * 100))%")
        } else {
            Capsule().fill(PN.C.surface2).frame(height: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { g in Capsule().fill(PN.C.turn).frame(width: max(0, min(1, value)) * g.size.width) }
                }
                .accessibilityHidden(true)
        }
    }
}

/// 0.25 (R2): the tabs of the call pages (boards CP, CT, UT, SL): the name in the display face, a count or a word next
/// to it (on the not-ready plate when it asks for work), a 3 pt line under the chosen one, a note on the right.
struct PageTabBar: View {
    let tabs: [(String, String)]
    @Binding var selection: String
    var counts: [String: Int] = [:]
    var badges: [String: String] = [:]
    var warn: Set<String> = []
    var note = ""
    @Environment(\.pnTheme) private var t

    var body: some View {
        let row = HStack(alignment: .bottom, spacing: tabs.count > 7 ? 26 : 28) {
            ForEach(tabs, id: \.0) { tab in item(tab.0, tab.1) }
        }
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                row
                Spacer(minLength: 8)
                if !note.isEmpty { Text(note).font(t.homeText(13)).foregroundStyle(PN.C.text3).lineLimit(1).fixedSize() }
            }
            ScrollView(.horizontal, showsIndicators: false) { row }
        }
        .padding(.horizontal, PageMetrics.side)
        .overlay(alignment: .bottom) { Rectangle().fill(PN.C.rule).frame(height: 1) }
    }

    private func item(_ id: String, _ label: String) -> some View {
        let on = selection == id
        let badge = badges[id] ?? counts[id].flatMap { $0 > 0 ? "\($0)" : nil } ?? ""
        let classic = t.style == .classic
        return Button { selection = id } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(t.cased(label))
                    .font(t.homeDisplay(t.tabSize, on ? (classic ? .semibold : .heavy) : (classic ? .regular : .semibold)))
                    .tracking(classic ? 0 : t.bTrack * t.tabSize)
                    .foregroundStyle(on ? PN.C.text : PN.C.text2)
                    .lineLimit(1).fixedSize()
                if !badge.isEmpty { PageCount(text: badge, warn: warn.contains(id)) }
            }
            .padding(.top, 10).padding(.bottom, 9)
            .overlay(alignment: .bottom) { Rectangle().fill(on ? PN.C.accent : Color.clear).frame(height: 3) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
