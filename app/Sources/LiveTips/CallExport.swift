import AppKit
import LiveTipsCore
import SwiftUI
import UniformTypeIdentifiers

/// 0.9.0: the call notes (<stem>.notes.md, rules/notes.yaml) read by section, for the Summary tab and the export.
enum CallNotes {
    static func path(_ transcript: String) -> String { (transcript.hasSuffix(".md") ? String(transcript.dropLast(3)) : transcript) + ".notes.md" }

    /// Lines of each "## " section, keyed by the heading in lower case.
    static func sections(_ transcript: String) -> [(String, [String])] {
        guard let text = try? String(contentsOfFile: path(transcript), encoding: .utf8) else { return [] }
        var out: [(String, [String])] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("## ") { out.append((l.dropFirst(3).lowercased(), [])); continue }
            if l.hasPrefix("#") || l.isEmpty || out.isEmpty { continue }
            // 2026-11-05: only a list marker followed by a space, so "**Topic**" keeps both of its stars (was "*Topic**")
            out[out.count - 1].1.append(l.replacingOccurrences(of: "^[-*•]\\s+", with: "", options: .regularExpression))
        }
        return out
    }

    static func lines(_ transcript: String, _ names: [String]) -> [String] {
        sections(transcript).first { s in names.contains { s.0.contains($0) } }?.1 ?? []
    }

    static func inShort(_ t: String) -> [String] { Array(lines(t, ["summary", "підсумок", "коротко"]).prefix(3)) }
    static func discussed(_ t: String) -> [String] { Array(lines(t, ["topics", "теми", "discussed"]).prefix(10)) }
    static func nextCall(_ t: String) -> [String] { Array(lines(t, ["open after", "відкрите після", "next call"]).prefix(6)) }
    static func decisions(_ t: String) -> [String] { lines(t, ["decisions", "рішення"]).map(plain).filter { !$0.isEmpty } }

    /// 0.9.5.2 (rules/notes.yaml, schema 2): the readable ## Meeting notes of the call, nil for older notes.
    static func meeting(_ transcript: String) -> MeetingNotes.Notes? {
        guard let text = try? String(contentsOfFile: path(transcript), encoding: .utf8) else { return nil }
        return MeetingNotes.parse(text)
    }

    static var meetingLabels: MeetingNotes.Labels {
        MeetingNotes.Labels(title: "", tldr: L("page.mn.tldr"), decisions: L("page.tab.decisions"), actions: L("page.mn.actions"),
                            open: L("page.mn.open"), topics: L("page.mn.topics"), unclear: L("page.mn.unclear"))
    }

    /// The Meeting notes as Markdown for Copy: the call's name, when and project, then the sections.
    @MainActor static func meetingMarkdown(_ transcript: String, title: String) -> String? {
        guard let m = meeting(transcript), !m.isEmpty else { return nil }
        var lab = meetingLabels; lab.title = title
        return MeetingNotes.markdown(m, lab, when: whenLine(transcript))
    }

    @MainActor static func whenLine(_ transcript: String) -> String {
        guard let r = CallHistory.shared.records.first(where: { $0.file == transcript }) else { return "" }
        return RecentCard.when(r) + (r.project.isEmpty ? "" : " · " + r.project)
    }

    /// Inline Markdown of a notes line (**bold**, *italic*, `code`) as styled text; plain text when it does not parse.
    static func md(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    /// A line without Markdown stars, for places that take plain text (lists that are edited and saved back).
    static func plain(_ s: String) -> String { s.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces) }

    /// 2026-11-05 (call page redesign): "## Topics" as topics. "- **Title**: text" starts a topic, a time at the end
    /// of the title ("(15:01-15:04)") goes to the time column, indented quotes are its quotes, other lines its text.
    struct Topic { var title = ""; var time = ""; var body: [String] = []; var quotes: [String] = [] }

    static func topics(_ transcript: String) -> [Topic] {
        guard let text = try? String(contentsOfFile: path(transcript), encoding: .utf8) else { return [] }
        var inside = false
        var out: [Topic] = []
        let names = ["topics", "теми", "discussed"]
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let s = String(raw)
            let l = s.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("## ") { let h = l.dropFirst(3).lowercased(); inside = names.contains { h.contains($0) }; continue }
            guard inside, !l.isEmpty, !l.hasPrefix("#") else { continue }
            let indent = s.prefix { $0 == " " || $0 == "\t" }.count
            let c = l.replacingOccurrences(of: "^[-*•]\\s+", with: "", options: .regularExpression)
            if c.hasPrefix("**"), let close = c.dropFirst(2).range(of: "**") {
                var title = String(c[c.index(c.startIndex, offsetBy: 2)..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
                var rest = String(c[close.upperBound...]).trimmingCharacters(in: .whitespaces)
                if rest.hasPrefix(":") { rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces) }
                if title.hasSuffix(":") { title = String(title.dropLast()) }
                var time = ""
                if let r = title.range(of: "\\s*\\(([0-9]{1,2}:[0-9]{2})[^)]*\\)\\s*$", options: .regularExpression) {
                    time = String(title[r]).components(separatedBy: CharacterSet(charactersIn: "(-,) ")).first { $0.contains(":") } ?? ""
                    title = String(title[..<r.lowerBound])
                }
                out.append(Topic(title: title, time: time, body: rest.isEmpty ? [] : [rest]))
                continue
            }
            if out.isEmpty { out.append(Topic()) }
            let quote = c.hasPrefix("\"") || c.hasPrefix("\u{201C}") || c.hasPrefix("\u{00AB}")
            if indent >= 2 && quote { out[out.count - 1].quotes.append(c) } else { out[out.count - 1].body.append(c) }
        }
        return out
    }
}

/// 0.9.0 (redesign 2.2): Export of a past call: Word, Markdown or a Notion page; the sections to include; the full
/// text editable before it goes out. Edits change only the export, never the call notes.
struct ExportPanel: View {
    let file: String
    let title: String
    let outcome: CallOutcome
    let commitments: [Commitment]
    var onClose: () -> Void
    @State private var format = "docx"
    @State private var incSummary = true
    @State private var incDiscussed = false     // 0.9.5.2: the former Summary (In short, What was discussed, For the next call)
    @State private var incDecisions = true
    @State private var incTasks = true
    @State private var incRisks = true
    @State private var incTranscript = false
    @State private var preview = true            // 0.9.5.2 (owner): see the document as it will look, not only Markdown
    private var hasMeeting: Bool { CallNotes.meeting(file).map { !$0.isEmpty } ?? false }
    @State private var text = ""
    @State private var touched = false
    @State private var note = ""
    @State private var busy = false

    private var notionReady: Bool { SettingsWindow.model.isSet(.notionToken) }
    @ObservedObject private var google = GoogleService.shared
    @State private var googleAccount = ""
    private var googleAccounts: [GoogleAccount] { google.accounts.filter { $0.has(GoogleScopes.export) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("export.title")).font(PN.Font.section).foregroundStyle(PN.C.text)
                Spacer()
                Button { onClose() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel(L("common.close"))
            }
            Picker(L("export.format"), selection: $format) {
                Text("Word (.docx)").tag("docx")
                Text("Markdown (.md)").tag("md")
                Text("Notion page").tag("notion")
                Text("Google Docs").tag("gdoc")
            }
            .pickerStyle(.segmented).fixedSize()
            HStack(spacing: 14) {
                Text(L("export.include")).font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.text2)
                Toggle(hasMeeting ? L("page.mn.label") : L("export.summary"), isOn: $incSummary)
                if hasMeeting { Toggle(L("page.sum.discussed"), isOn: $incDiscussed) }
                Toggle(L("page.tab.decisions"), isOn: $incDecisions)
                Toggle(L("page.tab.tasks"), isOn: $incTasks)
                Toggle(L("page.tab.risks"), isOn: $incRisks)
                Toggle(L("call.page.transcript"), isOn: $incTranscript)
            }
            .toggleStyle(.checkbox).font(PN.Font.caption)
            if format == "notion" {
                Text(notionReady ? L("export.notionTo", ["db": L("export.meetings")]) : L("export.notionConnect"))
                    .font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            if format == "gdoc" {
                if googleAccounts.isEmpty { Text(L("export.googleConnect")).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
                else if googleAccounts.count > 1 {
                    Picker(L("export.googleAccount"), selection: $googleAccount) {
                        ForEach(googleAccounts) { Text($0.email).tag($0.email) }
                    }.fixedSize()
                } else { Text(L("export.googleTo", ["email": googleAccounts[0].email])).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
            }
            HStack(spacing: 12) {
                Text(L("export.edit")).font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.text2)
                if format != "md" {
                    Picker("", selection: $preview) {
                        Text(L("export.preview")).tag(true)
                        Text(L("export.editMd")).tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    if preview { Text(L("export.previewNote")).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
                }
            }
            if format != "md" && preview {
                ScrollView { DocPreview(blocks: DocMD.parse(text)).padding(.horizontal, 28).padding(.vertical, 20) }
                    .frame(height: 360)
                    .background(Color.white.opacity(0.98), in: RoundedRectangle(cornerRadius: PN.Radius.s))
                    .overlay(RoundedRectangle(cornerRadius: PN.Radius.s).stroke(Color.primary.opacity(0.12)))
                    .environment(\.colorScheme, .light)
            } else {
                TextEditor(text: Binding(get: { text }, set: { text = $0; touched = true }))
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden).padding(6).frame(height: 360)
                    .background(PN.C.bg, in: RoundedRectangle(cornerRadius: PN.Radius.s))
                    .overlay(RoundedRectangle(cornerRadius: PN.Radius.s).stroke(Color.primary.opacity(0.12)))
            }
            HStack {
                if !note.isEmpty { Text(note).font(PN.Font.caption).foregroundStyle(PN.C.text2).lineLimit(2) }
                Spacer()
                Button(L("common.cancel"), action: onClose).buttonStyle(.pnSecondary).keyboardShortcut(.cancelAction)
                if format == "notion" && !notionReady {
                    Button(L("export.connectNotion")) { SettingsWindow.show(tab: "notion") }.buttonStyle(.pnPrimary)
                } else if format == "gdoc" && googleAccounts.isEmpty {
                    Button(L("export.connectGoogle")) { SettingsWindow.show(tab: "google") }.buttonStyle(.pnPrimary)
                } else {
                    Button(format == "docx" ? L("export.docx") : format == "md" ? L("export.md") : format == "gdoc" ? L("export.gdoc") : L("export.notion")) { run() }
                        .buttonStyle(.pnPrimary).disabled(busy || text.isEmpty)
                }
            }
        }
        .padding(16)
        .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.l))
        .onAppear {
            // 0.9.5.2: the Meeting notes already carry the decisions, action items and open questions
            if hasMeeting { incDecisions = false; incTasks = false; incRisks = false }
            rebuild()
        }
        .onChange(of: [incSummary, incDiscussed, incDecisions, incTasks, incRisks, incTranscript]) { if !touched { rebuild() } else { rebuildAsk() } }
    }

    private func rebuildAsk() { rebuild(); touched = false }      // a change of sections rebuilds the text

    private func rebuild() {
        text = Self.markdown(file: file, title: title, outcome: outcome, commitments: commitments,
                             summary: incSummary, discussed: incDiscussed, decisions: incDecisions, tasks: incTasks, risks: incRisks,
                             transcript: incTranscript)
    }

    static func markdown(file: String, title: String, outcome o: CallOutcome, commitments: [Commitment],
                         summary: Bool, discussed: Bool = false, decisions: Bool, tasks: Bool, risks: Bool, transcript: Bool) -> String {
        var md = "# " + title + "\n"
        let when = CallNotes.whenLine(file)
        if !when.isEmpty { md += "\n" + when + "\n" }
        let meeting = CallNotes.meeting(file).flatMap { $0.isEmpty ? nil : $0 }
        if summary, let m = meeting { md += MeetingNotes.markdown(m, CallNotes.meetingLabels) }      // 0.9.5.2
        if (summary && meeting == nil) || (discussed && meeting != nil) {
            let s = CallNotes.inShort(file), d = CallNotes.discussed(file), n = CallNotes.nextCall(file)
            if !s.isEmpty { md += "\n## " + L("page.sum.inShort") + "\n\n" + s.joined(separator: " ") + "\n" }
            if !d.isEmpty { md += "\n## " + L("page.sum.discussed") + "\n\n" + d.map { "- " + $0 }.joined(separator: "\n") + "\n" }
            if !n.isEmpty { md += "\n## " + L("page.sum.next") + "\n\n" + n.map { "- " + $0 }.joined(separator: "\n") + "\n" }
        }
        if decisions && !o.decisions.isEmpty { md += "\n## " + L("page.tab.decisions") + "\n\n" + o.decisions.map { "- " + $0 }.joined(separator: "\n") + "\n" }
        if tasks {
            let t = commitments.map { "- " + $0.text + ($0.mine ? "" : " (" + $0.owner + ")") + ($0.due.isEmpty ? "" : ", " + L("reg.due", ["due": Register.dueText($0.due)])) }
            let list = t.isEmpty ? o.onMe.map { "- " + $0 } : t
            if !list.isEmpty { md += "\n## " + L("page.tab.tasks") + "\n\n" + list.joined(separator: "\n") + "\n" }
        }
        if risks && !o.risks.isEmpty { md += "\n## " + L("page.tab.risks") + "\n\n" + o.risks.map { "- " + $0 }.joined(separator: "\n") + "\n" }
        if transcript, let t = try? String(contentsOfFile: file, encoding: .utf8) { md += "\n## " + L("call.page.transcript") + "\n\n" + t + "\n" }
        return md
    }

    private var baseName: String { title.replacingOccurrences(of: "/", with: "-") }

    private func run() {
        switch format {
        case "md":
            let p = NSSavePanel(); p.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]; p.nameFieldStringValue = baseName + ".md"
            guard p.runModal() == .OK, let u = p.url else { return }
            do { try text.write(to: u, atomically: true, encoding: .utf8); note = L("export.saved", ["name": u.lastPathComponent]) } catch { note = error.localizedDescription }
        case "docx":
            let p = NSSavePanel(); p.allowedContentTypes = [UTType(filenameExtension: "docx") ?? .data]; p.nameFieldStringValue = baseName + ".docx"
            guard p.runModal() == .OK, let u = p.url else { return }
            do {
                try DocMD.docx(DocMD.parse(text)).write(to: u); note = L("export.saved", ["name": u.lastPathComponent])
            } catch { note = error.localizedDescription }
        case "gdoc":
            let acct = googleAccounts.first { $0.email == googleAccount }?.email ?? googleAccounts.first?.email ?? ""
            let d = DocMD.docx(DocMD.parse(text))      // 0.9.5.2: Word's heading styles become Google Docs headings
            busy = true; note = L("nset.checking", ["name": "Google"])
            Task {
                do {
                    let link = try await GoogleService.shared.exportDoc(d, title: title, account: acct)
                    note = L("export.gdocDone", ["email": acct])
                    if let u = URL(string: link) { NSWorkspace.shared.open(u) }
                } catch { note = error.localizedDescription }
                busy = false
            }
        default:
            busy = true; note = L("nset.checking", ["name": "Notion"])
            Task { let r = await Self.toNotion(text, title: title, file: file); busy = false; note = r }
        }
    }

    /// A page in the meetings database (Settings > Integrations > Notion), blocks of at most 2000 characters, 100
    /// per request. Only on the PM's click.
    static func toNotion(_ md: String, title: String, file: String) async -> String {
        guard let tok = SecretStore(service: Bundle.main.bundleIdentifier ?? "io.github.example.livetips").get(.notionToken) else { return L("nset.saveToken") }
        let db = AppConfig.load(from: AppPaths.config).notionMeetingsDB
        guard !db.isEmpty else { return L("tr.noMeetingsDb") }
        let blocks = DocMD.notion(DocMD.parse(md))   // 0.9.5.2: ### headings, bold, nested lists as Notion has them
        do {
            var dsId = db
            var props = (try? await NotionAPI.call(tok, "GET", "/data_sources/\(db)"))?["properties"] as? [String: [String: Any]] ?? [:]
            if props.isEmpty, let r = try? await NotionAPI.call(tok, "GET", "/databases/\(db)"), let ds = ((r["data_sources"] as? [[String: Any]])?.first?["id"] as? String) {
                dsId = ds; props = (try? await NotionAPI.call(tok, "GET", "/data_sources/\(ds)"))?["properties"] as? [String: [String: Any]] ?? [:]
            }
            let titleProp = props.first { ($0.value["type"] as? String) == "title" }?.key ?? "Name"
            var pp: [String: Any] = [titleProp: ["title": [["type": "text", "text": ["content": String(title.prefix(200))]]]]]
            if let r = CallHistory.shared.records.first(where: { $0.file == file }), let dp = props.first(where: { ($0.value["type"] as? String) == "date" })?.key {
                let f = ISO8601DateFormatter(); f.timeZone = .current; pp[dp] = ["date": ["start": f.string(from: r.start)]]
            }
            let page = try await NotionAPI.call(tok, "POST", "/pages", ["parent": ["type": "data_source_id", "data_source_id": dsId], "properties": pp, "children": Array(blocks.prefix(100))])
            guard let id = page["id"] as? String else { return L("export.failed") }
            var rest = Array(blocks.dropFirst(100))
            while !rest.isEmpty {
                _ = try await NotionAPI.call(tok, "PATCH", "/blocks/\(id)/children", ["children": Array(rest.prefix(100))])
                rest = Array(rest.dropFirst(100))
            }
            if let u = page["url"] as? String, let url = URL(string: u) { NSWorkspace.shared.open(url) }
            return L("export.sent")
        } catch { return L("export.failed") + ": " + error.localizedDescription }
    }
}

/// 0.9.5.2 (owner): Edit before you export shows the document as Word, Google Docs and Notion will show it: headings,
/// lists with their indents, bold and italic, to-dos. The same reading (DocMD) as the files that go out.
struct DocPreview: View {
    let blocks: [DocMD.Block]

    static func text(_ runs: [DocMD.Run], size: CGFloat, weight: Font.Weight = .regular) -> AttributedString {
        var out = AttributedString()
        for r in runs {
            var a = AttributedString(r.text)
            var f = Font.system(size: size, weight: r.bold ? .bold : weight, design: r.code ? .monospaced : .default)
            if r.italic { f = f.italic() }
            a.font = f
            out += a
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, b in
                row(b, first: i == 0).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundStyle(Color(white: 0.12))
        .textSelection(.enabled)
    }

    @ViewBuilder private func row(_ b: DocMD.Block, first: Bool) -> some View {
        switch b.kind {
        case .h1: Text(Self.text(b.runs, size: 24, weight: .bold)).padding(.bottom, 8)
        case .h2: Text(Self.text(b.runs, size: 18, weight: .bold)).padding(.top, first ? 0 : 16).padding(.bottom, 6)
        case .h3: Text(Self.text(b.runs, size: 15, weight: .bold)).padding(.top, first ? 0 : 12).padding(.bottom, 4)
        case .h4: Text(Self.text(b.runs, size: 13.5, weight: .semibold)).padding(.top, first ? 0 : 10).padding(.bottom, 3)
        case .bullet(let lv):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(["\u{2022}", "\u{25E6}", "\u{25AA}"][min(lv, 2)]).font(.system(size: 13))
                Text(Self.text(b.runs, size: 13)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 18 + CGFloat(lv) * 20).padding(.vertical, 2)
        case .todo(let on):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: on ? "checkmark.square" : "square").font(.system(size: 12))
                Text(Self.text(b.runs, size: 13)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
        case .quote:
            Text(Self.text(b.runs, size: 13)).italic().foregroundStyle(Color(white: 0.35)).padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(Color(white: 0.8)).frame(width: 3) }.padding(.vertical, 4)
        case .rule: Divider().padding(.vertical, 8)
        case .para: Text(Self.text(b.runs, size: 13)).lineSpacing(2).fixedSize(horizontal: false, vertical: true).padding(.vertical, 3)
        }
    }
}
