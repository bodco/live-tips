import AppKit
import SwiftUI
import LiveTipsCore

/// Pacenote 0.8.6 (F6): the page of a held call (REDESIGN-SPEC 4.4 "Recent: a click opens the call page"): what was
/// decided, what is on you and on them (the register), open questions, the agenda, the risks; then the follow-up
/// email, the transcript, Notion and the series. Everything is read from the call's own files.
@MainActor
enum CallPageWindow {
    static var windows: [String: NSWindow] = [:]
    static func show(file: String) {
        let w = windows[file] ?? {
            let w = NSWindow(contentViewController: NSHostingController(rootView: Localized { CallPageView(file: file).frame(minWidth: 560, minHeight: 560) }))
            w.styleMask.insert(.resizable)
            w.isReleasedWhenClosed = false
            windows[file] = w
            return w
        }()
        w.title = CallPageView.title(file)
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct CallPageView: View {
    let file: String
    @ObservedObject var register = Register.shared
    @ObservedObject var history = CallHistory.shared
    @State private var note = ""
    @State private var added: Set<String> = []

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
        let f = DateFormatter(); f.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US"); f.setLocalizedDateFormatFromTemplate("EEEEdMMMMHHmm")
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
                }
                actions(proj)
                if !note.isEmpty { Text(note).font(PN.Font.caption).foregroundStyle(PN.C.onMe) }
                section(L("call.page.decisions"), o.decisions.map { Text($0) })
                commitments(items.filter { $0.mine }, L("call.page.onYou"))
                commitments(items.filter { !$0.mine }, L("call.page.onThem"))
                if items.isEmpty && !o.onMe.isEmpty { section(L("call.page.onYou"), o.onMe.map { Text($0) }) }
                section(L("call.page.open"), o.openQuestions.map { Text($0) })
                section(L("call.page.agenda"), agenda.map { a in
                    Text(a.text) + Text("  " + L(a.state == "done" ? "call.page.discussed" : a.state == "now" ? "call.page.raised" : "call.page.notRaised")).foregroundStyle(PN.C.text3)
                })
                risks(o.risks, proj)
                if o.isEmpty && items.isEmpty && agenda.isEmpty {
                    Text(L("call.page.empty")).font(PN.Font.body).foregroundStyle(PN.C.text3)
                }
            }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(PN.C.bg)
    }

    @ViewBuilder private func actions(_ proj: Project?) -> some View {
        HStack(spacing: 8) {
            Button(L("call.page.followup")) { FollowUpWindow.show(file: file) }.buttonStyle(.pnPrimary)
            Button(L("call.page.transcript")) { TranscriptWindow.show(file: file) }.buttonStyle(.pnSecondary)
            if let r = record, Self.series(of: r).count > 1 {
                Button(L("call.page.series", ["n": "\(Self.series(of: r).count)"])) { SeriesWindow.show(record: r) }.buttonStyle(.pnSecondary)
            }
            Menu {
                if let u = record?.notionURL.flatMap({ URL(string: $0) }) { Button(L("home.recent.notion")) { NSWorkspace.shared.open(u) } }
                Button(L("home.recent.finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)]) }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel(L("home.more"))
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

    @ViewBuilder private func commitments(_ list: [Commitment], _ title: String) -> some View {
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(PN.Font.section).foregroundStyle(PN.C.text)
                ForEach(list) { c in
                    HStack(alignment: .top, spacing: 8) {
                        Toggle("", isOn: Binding(get: { c.status == "done" }, set: { register.mark(c, $0 ? "done" : "reopen") }))
                            .toggleStyle(.checkbox).labelsHidden().accessibilityLabel(L("reg.markDoneA11y", ["text": c.text]))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.mine ? c.text : c.owner + ": " + c.text).font(PN.Font.body).foregroundStyle(c.status == "done" ? PN.C.text3 : PN.C.text)
                                .strikethrough(c.status == "done").fixedSize(horizontal: false, vertical: true)
                            if !c.due.isEmpty { Text(L("reg.due", ["due": c.due])).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
                        }
                        Spacer()
                        Button(L("reg.copy")) { register.copyText(c) }.buttonStyle(.pnTertiary)
                    }
                }
            }
        }
    }

    /// Risks (rules/risks.yaml > after_call): "Add to risk register" writes one Notion page after the PM confirms.
    @ViewBuilder private func risks(_ list: [String], _ proj: Project?) -> some View {
        if !list.isEmpty {
            let cfg = proj?.config ?? ""
            let hasDB = !cfg.isEmpty && ((try? String(contentsOfFile: cfg, encoding: .utf8))?.contains("risks_db") ?? false)
            VStack(alignment: .leading, spacing: 6) {
                Text(L("call.page.risks")).font(PN.Font.section).foregroundStyle(PN.C.text)
                ForEach(list, id: \.self) { r in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(PN.C.onMe).accessibilityHidden(true)
                        Text(r).font(PN.Font.body).foregroundStyle(PN.C.text).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if added.contains(r) {
                            Text(L("risk.added")).font(PN.Font.caption).foregroundStyle(PN.C.turn)
                        } else {
                            Button(L("risk.add")) { addRisk(r, proj) }.buttonStyle(.pnTertiary).disabled(!hasDB)
                                .help(hasDB ? L("risk.add.help") : L("risk.noDB"))
                        }
                    }
                }
            }
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
        PyTool.run("risk_notion", ["--project-config", p.config, "--title", text, "--call", Self.title(file) + ", " + when,
                                   "--project-name", p.name], notion: true) { r in
            if (r["ok"] as? Bool) == true { added.insert(text); note = "" } else { note = L("risk.failed", ["err": r["error"] as? String ?? ""]) }
        }
    }
}

// MARK: - Transcript

/// The transcript of a call, opened at a moment ("Jump to 12:34" from the call memory). Read only.
@MainActor
enum TranscriptWindow {
    static func show(file: String, at: String? = nil) {
        let w = NSWindow(contentViewController: NSHostingController(rootView: Localized { TranscriptView(file: file, at: at).frame(minWidth: 560, minHeight: 520) }))
        w.styleMask.insert(.resizable)
        w.isReleasedWhenClosed = false
        w.title = L("transcript.title", ["title": CallPageView.title(file)])
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
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
@MainActor
enum FollowUpWindow {
    static func show(file: String) {
        let w = NSWindow(contentViewController: NSHostingController(rootView: Localized { FollowUpView(file: file).frame(minWidth: 560, minHeight: 520) }))
        w.styleMask.insert(.resizable)
        w.isReleasedWhenClosed = false
        w.title = L("followup.title", ["title": CallPageView.title(file)])
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
    @State private var subject = ""
    @State private var bodyText = ""
    @State private var busy = false
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("followup.note")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            if busy {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L("followup.writing")).foregroundStyle(PN.C.text2) }
            }
            if !error.isEmpty { Text(error).font(PN.Font.caption).foregroundStyle(PN.C.danger) }
            TextField(L("followup.subject"), text: $subject).textFieldStyle(.roundedBorder)
            TextEditor(text: $bodyText).font(PN.Font.body).frame(minHeight: 280)
                .overlay(RoundedRectangle(cornerRadius: PN.Radius.s).stroke(PN.C.text3.opacity(0.3)))
            HStack(spacing: 8) {
                Button(L("followup.copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString((subject.isEmpty ? "" : subject + "\n\n") + bodyText, forType: .string)
                }.buttonStyle(.pnPrimary).disabled(bodyText.isEmpty)
                Button(L("followup.mail")) { openMail() }.buttonStyle(.pnSecondary).disabled(bodyText.isEmpty)
                Spacer()
                Button(L("followup.again")) { generate() }.buttonStyle(.pnTertiary).disabled(busy)
            }
        }
        .padding(20)
        .background(PN.C.bg)
        .onAppear { if bodyText.isEmpty { generate() } }
    }

    private func generate() {
        busy = true; error = ""
        let c = AppConfig.load(from: AppPaths.config)
        PyTool.run("followup", ["--md", file, "--lang", FollowUpWindow.language(of: file), "--model", c.models.tip]) { r in
            busy = false
            if (r["ok"] as? Bool) == true {
                subject = r["subject"] as? String ?? ""; bodyText = r["body"] as? String ?? ""
            } else { error = L("followup.failed", ["err": r["error"] as? String ?? ""]) }
        }
    }

    /// A mailto link: Mail opens a new message with the text; the PM adds the people and sends it.
    private func openMail() {
        var u = URLComponents(); u.scheme = "mailto"; u.path = ""
        u.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: bodyText)]
        if let url = u.url { NSWorkspace.shared.open(url) }
    }
}
