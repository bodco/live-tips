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
    private var items: [Commitment] {
        register.items(in: folder).filter { CommitmentRegister.callKey($0.call) == CommitmentRegister.callKey(file) && $0.status != "dropped" }
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
        let o = CallOutcome.read(transcript: file) ?? CallOutcome()
        let agenda = StartCallModel.agenda(transcript: file)
        let pw = PyTool.project(of: file)
        let proj = pw.project, ws = pw.workspace
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(proj, ws, o)
                RecordingRow(file: file)       // 0.9.5: the call recording, if there is one
                if exportOpen {
                    ExportPanel(file: file, title: Self.title(file), outcome: o, commitments: items) { exportOpen = false }
                }
                HStack(alignment: .center, spacing: 12) {
                    PageTabs(tabs: pageTabs(o), selection: $tab, counts: tabCounts(o))
                    Spacer(minLength: 0)
                    if ["decisions", "tasks", "risks"].contains(tab) { trackerNote }
                }
                .padding(.top, 4)
                Group {
                    switch tab {
                    case "decisions":
                        decisionsSection(o, proj, ws)      // 0.8.8 (rules/decisions.yaml > after_call)
                    case "tasks":
                        tasksTab(o, proj, ws)
                    case "risks":
                        risks(o, proj)
                    case "transcript":
                        VStack(alignment: .leading, spacing: 8) {
                            TranscriptView(file: file, at: transcriptAt)
                                .frame(minHeight: 560)
                                .clipShape(RoundedRectangle(cornerRadius: PageStyle.radius))
                            Text(L("page.transcript.local")).font(PN.Font.caption).foregroundStyle(PN.C.text3).padding(.leading, 4)
                        }
                    case "sales":
                        PageCard { salesSection(cardRoot(proj, ws)) }
                    case "discussed":
                        summaryTab(o, agenda)        // 0.9.5.2: the former Summary, as it was
                    default:
                        meetingTab(o)
                    }
                }
                .onChange(of: tab) { _, t in if t != "transcript" { transcriptAt = nil } }
            }
            .id(tick)
            .padding(24).frame(maxWidth: 1100, alignment: .leading)
            .background(GeometryReader { g in
                Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w }
            })
            .frame(maxWidth: .infinity)      // 0.9.0: centred
        }
        .background(PN.C.bg)
        .sheet(item: $cardDraft) { c in
            AnswerCardForm(card: c, title: L("cards.saveAs"), onSave: { saveCard($0, proj, ws) }, onCancel: { cardDraft = nil })
        }
    }

    // MARK: header (2026-11-05 redesign: a card like Home's next call)

    /// "Mon, Nov 2 · 14:55-15:11"
    private var whenText: String {
        guard let r = record else { return "" }
        let d = Self.fmt("EEEMMMd"), t = Self.fmt("HHmm")
        let end = r.end ?? r.minutes.map { r.start.addingTimeInterval($0 * 60) }
        return d.string(from: r.start) + " · " + t.string(from: r.start) + (end.map { "-" + t.string(from: $0) } ?? "")
    }

    @ViewBuilder private func header(_ proj: Project?, _ ws: Workspace?, _ o: CallOutcome) -> some View {
        let projName = proj?.name ?? ws?.name ?? record?.project ?? ""
        let series = record.map { Self.series(of: $0).count } ?? 0
        let info = VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if !whenText.isEmpty { Text(whenText).font(.system(size: 13, weight: .semibold)).foregroundStyle(PN.C.accent) }
                if !projName.isEmpty { PagePill(text: projName, color: PN.C.answer) }
                if let m = record?.minutes {
                    Text(L("call.page.minutes", ["n": "\(Int(m.rounded()))"])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                }
            }
            Text(Self.title(file)).font(.system(size: 28, weight: .bold)).foregroundStyle(PN.C.text)
                .fixedSize(horizontal: false, vertical: true)
            if series > 1, let r = record {
                Button { SeriesWindow.show(record: r) } label: {
                    Text(L("page.seriesLink", ["n": "\(series)"])).font(PN.Font.body)
                }
                .buttonStyle(.plain).foregroundStyle(PN.C.accent)
            }
            CallPageSyncLine(sync: sync)       // 0.8.7 (E5)
            if !meetNote.isEmpty { Text(meetNote).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true) }
            if !note.isEmpty { Text(note).font(PN.Font.caption).foregroundStyle(PN.C.onMe).fixedSize(horizontal: false, vertical: true) }
        }
        VStack(alignment: .leading, spacing: 0) {
            if wide {
                HStack(alignment: .top, spacing: 20) {
                    info.frame(maxWidth: .infinity, alignment: .leading)
                    actions(proj, o).padding(.top, 2)
                }
            } else {
                VStack(alignment: .leading, spacing: 16) { info; actions(proj, o) }
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: PageStyle.radius).fill(PN.C.surface))
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

    // MARK: 0.9.0 tabs

    private var hasSales: Bool { FileManager.default.fileExists(atPath: (file.hasSuffix(".md") ? String(file.dropLast(3)) : file) + ".sales.json") }

    /// Decisions of the call: the call picture's, else the "## Decisions" of the notes (the follow-up email reads those too).
    private func decisions(_ o: CallOutcome) -> [String] { o.decisions.isEmpty ? CallNotes.decisions(file) : o.decisions }

    private func pageTabs(_ o: CallOutcome) -> [(String, String)] {
        [("summary", L("page.tab.summary")), ("discussed", L("page.sum.discussed")), ("decisions", L("page.tab.decisions")), ("tasks", L("page.tab.tasks")),
         ("risks", L("page.tab.risks")), ("transcript", L("call.page.transcript"))] + (hasSales ? [("sales", L("sales.section"))] : [])
    }

    /// 2026-11-05 (redesign): the counts are badges on the tabs, not part of the name.
    private func tabCounts(_ o: CallOutcome) -> [String: Int] {
        ["decisions": decisions(o).count, "tasks": max(items.count, items.isEmpty ? o.onMe.count : 0), "risks": o.risks.count]
    }

    private var trackerNote: some View {
        Text(L("page.trackerNote")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
    }

    // MARK: Summary = Meeting notes (0.9.5.2, owner: readable notes people will read, with Copy and Export)

    @ViewBuilder private func meetingTab(_ o: CallOutcome) -> some View {
        if let m = CallNotes.meeting(file), !m.isEmpty {
            let side = !(m.decisions.isEmpty && m.actions.isEmpty && m.open.isEmpty)
            if wide && side {
                HStack(alignment: .top, spacing: 16) {
                    meetingMain(m)
                    meetingSide(m).frame(width: width >= 1000 ? 350 : 310)
                }
            } else {
                VStack(alignment: .leading, spacing: 16) { meetingMain(m); if side { meetingSide(m) } }
            }
        } else {
            makeMeetingCard(o)
        }
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

    @ViewBuilder private func meetingMain(_ m: MeetingNotes.Notes) -> some View {
        PageCard(spacing: 0) {
            PageLabel(text: L("page.mn.label")) {
                HStack(spacing: 14) {
                    Button { copyMeeting() } label: {
                        Label(copied ? L("page.mn.copied") : L("page.mn.copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.plain).font(PN.Font.caption.weight(.medium)).foregroundStyle(PN.C.accent).help(L("page.mn.copyHelp"))
                    Button { exportOpen = true } label: { Label(L("page.export"), systemImage: "square.and.arrow.up") }
                        .buttonStyle(.plain).font(PN.Font.caption.weight(.medium)).foregroundStyle(PN.C.accent)
                }
            }
            .padding(.bottom, 10)
            if !m.tldr.isEmpty {
                Text(CallNotes.md(m.tldr)).font(.system(size: 15)).lineSpacing(3).foregroundStyle(PN.C.text)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if !m.topics.isEmpty {
                if !m.tldr.isEmpty { Divider().padding(.vertical, 20) }
                PageLabel(text: L("page.mn.topics")).padding(.bottom, 4)
                ForEach(Array(m.topics.enumerated()), id: \.offset) { i, tp in
                    if i > 0 { Divider() }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        timeLink(tp.t, width: 40)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(CallNotes.md(tp.title)).font(PN.Font.body.weight(.semibold)).foregroundStyle(PN.C.text)
                                .fixedSize(horizontal: false, vertical: true)
                            if !tp.outcome.isEmpty {
                                Text(CallNotes.md(tp.outcome.prefix(1).uppercased() + tp.outcome.dropFirst())).font(PN.Font.body).lineSpacing(2).foregroundStyle(PN.C.text2)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(Array(tp.points.enumerated()), id: \.offset) { _, pt in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Circle().fill(PN.C.text3).frame(width: 4, height: 4).offset(y: -3)
                                        Text(CallNotes.md(pt.text)).font(PN.Font.body).lineSpacing(2).foregroundStyle(PN.C.text)
                                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                        timeLink(pt.t)
                                        Spacer(minLength: 0)
                                    }
                                }
                            }
                            .padding(.top, 2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 12)
                }
            }
            if !m.unclear.isEmpty {
                Text(L("page.mn.unclear") + ": " + m.unclear.map { CallNotes.plain($0.text) }.joined(separator: "; "))
                    .font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true).padding(.top, 14)
            }
        }
    }

    @ViewBuilder private func meetingSide(_ m: MeetingNotes.Notes) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach([(L("page.tab.decisions"), m.decisions, PN.C.accent as Color?), (L("page.mn.actions"), m.actions, nil),
                     (L("page.mn.open"), m.open, nil)].filter { !$0.1.isEmpty }, id: \.0) { title, items, tint in
                PageCard(tint: tint) {
                    PageLabel(text: title, color: tint == nil ? PN.C.text3 : PN.C.answer)
                    VStack(alignment: .leading, spacing: 9) { ForEach(Array(items.enumerated()), id: \.offset) { _, it in itemRow(it) } }
                }
            }
        }
    }

    @ViewBuilder private func makeMeetingCard(_ o: CallOutcome) -> some View {
        let hasNotes = FileManager.default.fileExists(atPath: CallNotes.path(file))
        PageCard {
            PageLabel(text: L("page.mn.label"))
            Text(L(hasNotes ? "page.mn.none" : "page.mn.noneNoNotes")).font(PN.Font.body).foregroundStyle(PN.C.text2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button(making ? L("page.mn.making") : L("page.mn.make")) { makeMeeting() }
                    .buttonStyle(.pnPrimary).disabled(making)
                if making { ProgressView().controlSize(.small) }
                Text(L(hasNotes ? "page.mn.cost" : "page.mn.costFull")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            .padding(.top, 4)
            if !makeNote.isEmpty {
                Text(makeNote).font(PN.Font.caption).foregroundStyle(PN.C.onMe).fixedSize(horizontal: false, vertical: true)
            }
            Button(L("page.mn.seeDiscussed")) { tab = "discussed" }.buttonStyle(.plain)
                .font(PN.Font.caption.weight(.medium)).foregroundStyle(PN.C.accent).padding(.top, 2)
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
        if wide {
            HStack(alignment: .top, spacing: 16) {
                summaryMain(o, agenda)
                summarySide(o, agenda).frame(width: width >= 1000 ? 350 : 310)
            }
        } else {
            VStack(alignment: .leading, spacing: 16) { summaryMain(o, agenda); summarySide(o, agenda) }
        }
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
                PageLabel(text: L("page.sum.inShort")).padding(.bottom, 10)
                Text(CallNotes.md(short.joined(separator: " "))).font(.system(size: 15)).lineSpacing(3).foregroundStyle(PN.C.text)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if !short.isEmpty && !topics.isEmpty { Divider().padding(.vertical, 20) }
            if !topics.isEmpty {
                let hasQuotes = topics.contains { !$0.quotes.isEmpty }
                PageLabel(text: L("page.sum.discussed")) {
                    if hasQuotes {
                        Button(allQuotes ? L("page.quotes.hideAll") : L("page.quotes.showAll")) { allQuotes.toggle(); openQuotes = [] }
                            .buttonStyle(.plain).font(PN.Font.caption.weight(.medium)).foregroundStyle(PN.C.accent)
                    }
                }
                .padding(.bottom, 4)
                ForEach(Array(topics.enumerated()), id: \.offset) { i, tp in
                    if i > 0 { Divider() }
                    topicRow(i, tp)
                }
            }
        }
    }

    @ViewBuilder private func topicRow(_ i: Int, _ tp: CallNotes.Topic) -> some View {
        let showQuotes = allQuotes || openQuotes.contains(i)
        HStack(alignment: .top, spacing: 12) {
            Text(tp.time.isEmpty ? "\(i + 1)" : tp.time).font(PN.Font.caption.monospacedDigit()).foregroundStyle(PN.C.text3)
                .frame(width: 40, alignment: .leading).padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                if !tp.title.isEmpty {
                    Text(CallNotes.md(tp.title)).font(PN.Font.body.weight(.semibold)).foregroundStyle(PN.C.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(tp.body.enumerated()), id: \.offset) { _, b in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if tp.body.count > 1 { Circle().fill(PN.C.text3).frame(width: 4, height: 4).offset(y: -3) }
                        Text(CallNotes.md(b)).font(PN.Font.body).lineSpacing(2).foregroundStyle(PN.C.text2)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !tp.quotes.isEmpty {
                    if showQuotes {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(tp.quotes.enumerated()), id: \.offset) { _, q in
                                Text(CallNotes.md(q)).font(PN.Font.caption).lineSpacing(2).foregroundStyle(PN.C.text3)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) { Rectangle().fill(PN.C.surface2).frame(width: 2) }
                        .padding(.top, 4)
                    }
                    if !allQuotes {
                        Button(showQuotes ? L("page.quotes.hide") : L("page.quotes.n", ["n": "\(tp.quotes.count)"])) {
                            if showQuotes { openQuotes.remove(i) } else { openQuotes.insert(i) }
                        }
                        .buttonStyle(.plain).font(PN.Font.caption.weight(.medium)).foregroundStyle(PN.C.accent).padding(.top, 2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder private func summarySide(_ o: CallOutcome, _ agenda: [(text: String, state: String)]) -> some View {
        let next = CallNotes.nextCall(file)
        VStack(alignment: .leading, spacing: 16) {
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
        let mine = PageCard { commitments(items.filter { $0.mine }, mine: true, legacy: items.isEmpty ? o.onMe : [], proj, ws) }
        let theirs = PageCard { commitments(items.filter { !$0.mine }, mine: false, legacy: [], proj, ws) }
        if wide {
            HStack(alignment: .top, spacing: 16) { mine; theirs }
        } else {
            VStack(alignment: .leading, spacing: 16) { mine; theirs }
        }
    }

    @ViewBuilder private func actions(_ proj: Project?, _ o: CallOutcome) -> some View {
        HStack(spacing: 8) {
            // 0.9.0: Ask about this call, the follow-up email, Export; the rest in "..."
            Button { MemoryWindow.show(project: proj?.root ?? folderRoot) } label: { Label(L("page.ask"), systemImage: "magnifyingglass") }
                .buttonStyle(.pnSecondary)
            Button(L("call.page.followup")) {
                if HomeNav.shared.followUp == file { HomeNav.shared.followUp = nil } else { FollowUpWindow.show(file: file) }
            }
            .buttonStyle(.pnSecondary).keyboardShortcut("i", modifiers: [.command, .option]).help(L("call.page.followup.help"))
            Button(L("page.export")) { exportOpen.toggle() }.buttonStyle(.pnPrimary)
            Menu {
                // 0.9.1 (rules/google.yaml > meet): participants and, when Meet transcribed it, the Meet transcript
                if GoogleService.shared.accounts.contains(where: { $0.has(GoogleScopes.meet) }), let r = record {
                    Button(L("meet.get")) { getMeet(r) }
                    Divider()
                }
                if let u = record?.notionURL.flatMap({ URL(string: $0) }) { Button(L("home.recent.notion")) { NSWorkspace.shared.open(u) } }
                Button(L("home.recent.finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)]) }
                Button(L("call.page.transcript")) { TranscriptWindow.show(file: file) }
                if let r = record, Self.series(of: r).count > 1 { Button(L("call.page.series", ["n": "\(Self.series(of: r).count)"])) { SeriesWindow.show(record: r) } }
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
        CallPageEdit.save(file: file, decisions: decisions ?? o.decisions, open: open ?? o.openQuestions, risks: risks ?? o.risks)
        changed(section)
    }

    private var bullet: some View { Text("•").font(PN.Font.body).foregroundStyle(PN.C.text3) }

    /// 2026-11-05 (redesign): every block opens with the same small uppercase label as "In short".
    private func heading(_ t: String, _ tail: String = "") -> some View {
        PageLabel(text: t) { if !tail.isEmpty { Text(tail).font(PN.Font.caption).foregroundStyle(PN.C.text3) } }
            .padding(.horizontal, 6).padding(.bottom, 6)
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
    @ViewBuilder private func commitments(_ list: [Commitment], mine: Bool, legacy: [String], _ proj: Project?, _ ws: Workspace?) -> some View {
        let section = mine ? "onYou" : "onThem"
        let open = list.filter { $0.status == "open" }.count + legacy.count
        let owners: [String] = mine ? [""] : list.reduce(into: [String]()) { if !$0.contains($1.owner) { $0.append($1.owner) } }
        VStack(alignment: .leading, spacing: 2) {
            heading(mine ? L("call.page.onYou") : L("call.page.onThem"), list.isEmpty && legacy.isEmpty ? "" : L("page.tasks.open", ["n": "\(open)"]))
            if list.isEmpty && legacy.isEmpty {
                Text(L(mine ? "page.tasks.noneOnYou" : "page.tasks.noneOnThem")).font(PN.Font.body).foregroundStyle(PN.C.text3).padding(.horizontal, 6).padding(.vertical, 4)
            }
            ForEach(owners, id: \.self) { who in
                if !mine {
                    HStack(spacing: 8) {
                        PageAvatar(name: who)
                        Text(who).font(PN.Font.section).foregroundStyle(PN.C.text2)
                    }
                    .padding(.horizontal, 6).padding(.top, who == owners.first ? 2 : 12).padding(.bottom, 2)
                }
                ForEach(list.filter { mine || $0.owner == who }) { c in commitmentRow(c, section: section) }
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
            .padding(.top, 4)
        }
    }

    @ViewBuilder private func commitmentRow(_ c: Commitment, section: String) -> some View {
        let overdue = c.status == "open" && CommitmentRegister.isOverdue(c)
        // 0.8.7 (J4): only the due date is red when overdue, never the owner
        // 0.8.8: an item sent to the Notion tasks (by a click or the automatic add) says so
        EditableRow(text: c.text, sub: c.mine && !c.notionPage.isEmpty ? L("call.page.inNotionTasks") : "", subColor: overdue ? PN.C.danger : PN.C.text3,
                    subTail: c.due.isEmpty ? "" : L("reg.due", ["due": Register.dueText(c.due)]), done: c.status == "done",
                    copy: (c.mine ? "" : c.owner + ": ") + c.text + (c.due.isEmpty ? "" : " (" + Register.dueText(c.due) + ")"),
                    menu: commitmentMenu(c, section),
                    onSave: { v in register.edit(c, text: v); changed(section) }) {
            Toggle("", isOn: Binding(get: { c.status == "done" }, set: { register.mark(c, $0 ? "done" : "reopen") }))
                .toggleStyle(.checkbox).labelsHidden().accessibilityLabel(L("reg.markDoneA11y", ["text": c.text]))
        }
        .padding(.vertical, 3)
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
            let done = agenda.filter { $0.state == "done" }.count
            heading(L("call.page.agenda"), L("page.agenda.progress", ["done": "\(done)", "n": "\(agenda.count)"]))
            PageProgress(value: agenda.isEmpty ? 0 : Double(done) / Double(agenda.count)).padding(.horizontal, 6).padding(.bottom, 8)
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
        PageCard(spacing: 2) {
            heading(L("call.page.risks"))
            let _ = links.n
            if o.risks.isEmpty { PageEmpty(icon: "exclamationmark.triangle", title: L("page.empty.risks"), text: L("page.empty.risks.body")) }
            ForEach(Array(o.risks.enumerated()), id: \.offset) { i, r in
                let known = added[r] ?? NotionCallLinks.url(file, "risks", r)     // 0.8.8: kept next to the call
                let inRegister = known != nil
                let addAction = PageRowAction(title: L("risk.add"), icon: "exclamationmark.shield", enabled: hasDB, note: L("risk.noDB"),
                                              run: { _ in addRisk(r, proj) })
                EditableRow(text: r, copy: r,
                            hoverActions: inRegister ? [] : [addAction],
                            menu: (inRegister ? [] : [addAction]) + [.separator, PageRowAction(title: L("callEdit.delete"), destructive: true, run: { _ in
                                var l = o.risks; if i < l.count { l.remove(at: i) }; saveLists(o, risks: l, section: "risks") })],
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
            AddRowField(placeholder: L("callEdit.addPh")) { saveLists(o, risks: o.risks + [$0], section: "risks") }.padding(.top, 4)
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
            HStack(alignment: .firstTextBaseline) {
                heading(L("call.page.decisions"))
                Spacer()
                if hasDB && pending.count > 1 {
                    Button(L("dec.addAll", ["n": "\(pending.count)"])) { addDecisions(pending, proj) }
                        .buttonStyle(.pnTertiary).disabled(!adding.isEmpty)
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
                            hoverActions: url == nil ? [add] : [],
                            menu: (url == nil ? [add] : []) + [saveCardAction("", d, root: root), .separator,
                                  PageRowAction(title: L("callEdit.delete"), destructive: true, run: { _ in
                                      var l = decs; if i < l.count { l.remove(at: i) }; set(l) })],
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
                                    ProgressView().controlSize(.small)
                                }
                            })
                if let s = supersede[d] { supersedeRow(d, s) }
            }
            AddRowField(placeholder: L("callEdit.addPh")) { set(decs + [$0]) }.padding(.top, 4)
        }
        // 2026-11-05 (owner): every block is as wide as the header card
    }

    /// "Replaces <old, date>?": only this click marks the old decision Superseded and links the two.
    @ViewBuilder private func supersedeRow(_ d: String, _ s: [String: String]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.swap").foregroundStyle(PN.C.text3).accessibilityHidden(true)
            Text(L("dec.replaces", ["title": s["title"] ?? "", "date": s["date"] ?? ""])).font(PN.Font.caption).foregroundStyle(PN.C.text2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(L("dec.replaceYes")) { replace(d, s) }.buttonStyle(.pnSecondary).controlSize(.small)
            Button(L("dec.replaceNo")) { supersede[d] = nil }.buttonStyle(.pnTertiary).controlSize(.small)
        }
        .padding(.leading, 20)
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
        PyTool.run("risk_notion", ["--db", NotionTargets.risksDB(c, p), "--title", text, "--call", Self.title(file) + ", " + when, "--call-file", file]
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
        let c = state == "done" ? PN.C.turn : state == "now" ? PN.C.onMe : PN.C.text3   // skip (2026-11-03): grey, like not raised
        Button(action: next) {
            Text(L(state == "done" ? "call.page.discussed" : state == "now" ? "call.page.raised" : state == "skip" ? "call.page.skipped" : "call.page.notRaised"))
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
    @State private var who: String? = nil       // 2026-11-05 (redesign): one speaker only
    @State private var lines: [TranscriptLine] = []

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
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(PN.C.text3).accessibilityHidden(true)
                    TextField("", text: $q, prompt: Text(L("transcript.find"))).textFieldStyle(.plain).font(PN.Font.body)
                    if !q.isEmpty {
                        Button { q = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(PN.C.text3) }
                            .buttonStyle(.plain).accessibilityLabel(L("common.close"))
                    }
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(PN.C.surface2, in: RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: 360)
                if speakers.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            chip(L("transcript.everyone"), on: who == nil) { who = nil }
                            ForEach(speakers, id: \.self) { s in chip(s, on: who == s) { who = who == s ? nil : s } }
                        }
                    }
                }
                Spacer(minLength: 0)
                Button(L("home.recent.finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)]) }.buttonStyle(.pnTertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(turns, id: \.first!.id) { turn in
                            let first = turn[0]
                            HStack(alignment: .top, spacing: 14) {
                                Text(first.t).font(PN.Font.caption.monospacedDigit()).foregroundStyle(PN.C.text3)
                                    .frame(width: 62, alignment: .leading).padding(.top, 1)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(first.who).font(PN.Font.caption.weight(.semibold)).foregroundStyle(first.me ? PN.C.accent : PN.C.text2)
                                    ForEach(turn) { l in
                                        Text(l.text).font(PN.Font.body).lineSpacing(2).foregroundStyle(PN.C.text).textSelection(.enabled)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .padding(.horizontal, l.id == target ? 4 : 0)
                                            .background(RoundedRectangle(cornerRadius: PN.Radius.s).fill(l.id == target ? PN.C.accent.opacity(0.14) : .clear))
                                            .id(l.id)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(first.me ? PN.C.accent.opacity(0.05) : Color.clear)
                        }
                        if lines.isEmpty {
                            Text(L("transcript.empty")).font(PN.Font.body).foregroundStyle(PN.C.text3).padding(18)
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
        .background(PN.C.surface)
    }

    private func chip(_ t: String, on: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(t).font(PN.Font.caption.weight(on ? .semibold : .regular)).lineLimit(1)
                .foregroundStyle(on ? PN.C.answer : PN.C.text2)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(on ? PN.C.accent.opacity(0.14) : PN.C.surface2))
        }
        .buttonStyle(.plain)
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

enum PageStyle { static let radius: CGFloat = 16 }

/// A white block on the grey page, like Home's cards. `tint`: a soft accent wash and border (For the next call).
struct PageCard<Content: View>: View {
    var spacing: CGFloat = 10
    var tint: Color? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
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

/// The small uppercase label of a block, with an optional note or action on the right.
struct PageLabel<Trailing: View>: View {
    let text: String
    var color: Color = PN.C.text3
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text.uppercased()).font(PN.Font.label).kerning(0.4).foregroundStyle(color)
            Spacer(minLength: 8)
            trailing()
        }
    }
}

extension PageLabel where Trailing == EmptyView {
    init(text: String, color: Color = PN.C.text3) { self.init(text: text, color: color, trailing: { EmptyView() }) }
}

struct PagePill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(color).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Initials in a circle, for the person a task is on.
struct PageAvatar: View {
    let name: String
    var body: some View {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "." }).prefix(2)
        let ini = parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
        Text(ini.isEmpty ? "?" : ini).font(.system(size: 10, weight: .bold)).foregroundStyle(PN.C.answer)
            .frame(width: 22, height: 22).background(Circle().fill(PN.C.accent.opacity(0.13)))
            .accessibilityHidden(true)
    }
}

/// A row's kind as a small tinted square (a decision, a risk).
struct PageIconTile: View {
    let icon: String
    let color: Color
    var body: some View {
        Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            .frame(width: 22, height: 22).background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityHidden(true)
    }
}

/// An empty block: what would be here and how it gets here.
struct PageEmpty: View {
    let icon: String
    let title: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 14, weight: .medium)).foregroundStyle(PN.C.text3)
                .frame(width: 34, height: 34).background(Circle().fill(PN.C.surface2)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(PN.Font.body.weight(.semibold)).foregroundStyle(PN.C.text)
                Text(text).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 6)
    }
}

struct PageProgress: View {
    let value: Double
    var body: some View {
        Capsule().fill(PN.C.surface2).frame(height: 6)
            .overlay(alignment: .leading) {
                GeometryReader { g in Capsule().fill(PN.C.turn).frame(width: max(0, min(1, value)) * g.size.width) }
            }
            .accessibilityHidden(true)
    }
}
