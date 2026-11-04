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
            out[out.count - 1].1.append(l.replacingOccurrences(of: "^[-*•]\\s*", with: "", options: .regularExpression))
        }
        return out
    }

    static func lines(_ transcript: String, _ names: [String]) -> [String] {
        sections(transcript).first { s in names.contains { s.0.contains($0) } }?.1 ?? []
    }

    static func inShort(_ t: String) -> [String] { Array(lines(t, ["summary", "підсумок", "коротко"]).prefix(3)) }
    static func discussed(_ t: String) -> [String] { Array(lines(t, ["topics", "теми", "discussed"]).prefix(10)) }
    static func nextCall(_ t: String) -> [String] { Array(lines(t, ["open after", "відкрите після", "next call"]).prefix(6)) }
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
    @State private var incDecisions = true
    @State private var incTasks = true
    @State private var incRisks = true
    @State private var incTranscript = false
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
                Toggle(L("export.summary"), isOn: $incSummary)
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
            Text(L("export.edit")).font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.text2)
            TextEditor(text: Binding(get: { text }, set: { text = $0; touched = true }))
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden).padding(6).frame(height: 220)
                .background(PN.C.bg, in: RoundedRectangle(cornerRadius: PN.Radius.s))
                .overlay(RoundedRectangle(cornerRadius: PN.Radius.s).stroke(Color.primary.opacity(0.12)))
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
        .onAppear { rebuild() }
        .onChange(of: [incSummary, incDecisions, incTasks, incRisks, incTranscript]) { if !touched { rebuild() } else { rebuildAsk() } }
    }

    private func rebuildAsk() { rebuild(); touched = false }      // a change of sections rebuilds the text

    private func rebuild() {
        text = Self.markdown(file: file, title: title, outcome: outcome, commitments: commitments,
                             summary: incSummary, decisions: incDecisions, tasks: incTasks, risks: incRisks, transcript: incTranscript)
    }

    static func markdown(file: String, title: String, outcome o: CallOutcome, commitments: [Commitment],
                         summary: Bool, decisions: Bool, tasks: Bool, risks: Bool, transcript: Bool) -> String {
        var md = "# " + title + "\n"
        if let r = CallHistory.shared.records.first(where: { $0.file == file }) { md += "\n" + RecentCard.when(r) + (r.project.isEmpty ? "" : " · " + r.project) + "\n" }
        if summary {
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
                let doc = Self.attributed(text)
                let d = try doc.data(from: NSRange(location: 0, length: doc.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
                try d.write(to: u); note = L("export.saved", ["name": u.lastPathComponent])
            } catch { note = error.localizedDescription }
        case "gdoc":
            let acct = googleAccounts.first { $0.email == googleAccount }?.email ?? googleAccounts.first?.email ?? ""
            let doc = Self.attributed(text)
            guard let d = try? doc.data(from: NSRange(location: 0, length: doc.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]) else { return }
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

    /// Headings, bullets and paragraphs into rich text for Word (AppKit's own writer, no extra dependency).
    static func attributed(_ md: String) -> NSAttributedString {
        let doc = NSMutableAttributedString()
        for raw in md.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = String(raw)
            if l.hasPrefix("# ") { doc.append(NSAttributedString(string: String(l.dropFirst(2)) + "\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 20)])) }
            else if l.hasPrefix("## ") { doc.append(NSAttributedString(string: "\n" + String(l.dropFirst(3)) + "\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])) }
            else if l.hasPrefix("- ") { doc.append(NSAttributedString(string: "• " + String(l.dropFirst(2)) + "\n", attributes: [.font: NSFont.systemFont(ofSize: 11)])) }
            else { doc.append(NSAttributedString(string: l + "\n", attributes: [.font: NSFont.systemFont(ofSize: 11)])) }
        }
        return doc
    }

    /// A page in the meetings database (Settings > Integrations > Notion), blocks of at most 2000 characters, 100
    /// per request. Only on the PM's click.
    static func toNotion(_ md: String, title: String, file: String) async -> String {
        guard let tok = SecretStore(service: Bundle.main.bundleIdentifier ?? "io.github.example.livetips").get(.notionToken) else { return L("nset.saveToken") }
        let db = AppConfig.load(from: AppPaths.config).notionMeetingsDB
        guard !db.isEmpty else { return L("tr.noMeetingsDb") }
        func block(_ type: String, _ s: String) -> [String: Any] { ["object": "block", "type": type, type: ["rich_text": [["type": "text", "text": ["content": String(s.prefix(2000))]]]]] }
        var blocks: [[String: Any]] = []
        for raw in md.split(separator: "\n") {
            let l = String(raw)
            if l.hasPrefix("# ") { continue }
            if l.hasPrefix("## ") { blocks.append(block("heading_2", String(l.dropFirst(3)))) }
            else if l.hasPrefix("- ") { blocks.append(block("bulleted_list_item", String(l.dropFirst(2)))) }
            else { var s = Substring(l); while !s.isEmpty { blocks.append(block("paragraph", String(s.prefix(2000)))); s = s.dropFirst(2000) } }
        }
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
