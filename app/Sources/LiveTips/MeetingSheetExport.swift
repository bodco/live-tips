import AppKit
import LiveTipsCore
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// 0.10.0 (Meeting Sheet, phase 5): Export (S8). Markdown, PDF (new: the HTML rendered by WebKit), Word, Google Doc and
// Notion (the same paths as the call notes, CallExport.swift), Copy as rich text. Sources as footnotes or a link next
// to each fact; all blocks, a choice, or "For a colleague" without the internal blocks (My focus, Red lines).
// Nothing is sent to anyone: a Google Doc or a Notion page is made in the PM's own account and opened for them.

struct SheetExportView: View {
    @ObservedObject var doc: SheetDoc
    var done: () -> Void
    @ObservedObject var google = GoogleService.shared
    @State private var format = "pdf"
    @State private var sources = SheetExportOptions.SourcesStyle.footnotes
    @State private var template = "all"           // all | colleague | pick
    @State private var picked: Set<String> = []
    @State private var note = ""
    @State private var busy = false

    private var options: SheetExportOptions {
        SheetExportOptions(sources: sources, blocks: template == "pick" ? picked : nil, colleague: template == "colleague")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("sheet.ui.export.title", ["title": doc.sheet?.title ?? ""])).font(PN.Font.section)
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    PageLabel(text: L("sheet.ui.export.format"))
                    Picker("", selection: $format) {
                        Text("PDF").tag("pdf")
                        Text(L("sheet.ui.export.gdoc")).tag("gdoc")
                        Text(L("sheet.ui.export.notion")).tag("notion")
                        Text(L("sheet.ui.export.docx")).tag("docx")
                        Text("Markdown").tag("md")
                        Text(L("sheet.ui.export.copy")).tag("copy")
                    }
                    .labelsHidden().pickerStyle(.radioGroup)
                    PageLabel(text: L("sheet.ui.export.sources")).padding(.top, 6)
                    Picker("", selection: $sources) {
                        Text(L("sheet.ui.export.footnotes")).tag(SheetExportOptions.SourcesStyle.footnotes)
                        Text(L("sheet.ui.export.inline")).tag(SheetExportOptions.SourcesStyle.inline)
                    }
                    .labelsHidden().pickerStyle(.radioGroup)
                }
                VStack(alignment: .leading, spacing: 8) {
                    PageLabel(text: L("sheet.ui.export.blocks"))
                    Picker("", selection: $template) {
                        Text(L("sheet.ui.export.all")).tag("all")
                        Text(L("sheet.ui.export.colleague")).tag("colleague")
                        Text(L("sheet.ui.export.pick")).tag("pick")
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                    if template == "colleague" { Text(L("sheet.ui.export.colleagueNote")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true) }
                    if template == "pick", let s = doc.sheet {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(s.shownBlocks) { b in
                                    Toggle(b.title + (SheetExportOptions.internalBlocks.contains(b.type) ? " · " + L("sheet.ui.export.internal") : ""),
                                           isOn: Binding(get: { picked.contains(b.id) }, set: { if $0 { picked.insert(b.id) } else { picked.remove(b.id) } }))
                                        .toggleStyle(.checkbox)
                                }
                            }
                        }
                        .frame(height: 200)
                    }
                }
            }
            Text(L("sheet.ui.export.nothingSent")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            if !note.isEmpty { Text(note).font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button(L("common.cancel"), action: done).buttonStyle(.pnTertiary).keyboardShortcut(.cancelAction)
                Button(L("sheet.ui.export.go")) { run() }.buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction).disabled(busy || doc.sheet == nil)
            }
        }
        .padding(22).frame(width: 600)
        .onAppear { if let s = doc.sheet { picked = Set(s.shownBlocks.map(\.id)) } }
    }

    private var baseName: String { (doc.sheet?.title ?? "Meeting Sheet").replacingOccurrences(of: "/", with: "-") }

    /// DocMD (Word, Google Docs, Notion) has no footnotes: [^n] becomes [n] and the notes a numbered list.
    static func plainNotes(_ md: String) -> String {
        var out: [String] = []
        var notes: [String] = []
        for l in md.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let r = l.range(of: "^\\[\\^(\\d+)\\]: ", options: .regularExpression) {
                let num = String(l[r].dropFirst(2).prefix { $0 != "]" })
                notes.append(num + ". " + String(l[r.upperBound...]))
            } else {
                out.append(l.replacingOccurrences(of: "\\[\\^(\\d+)\\]", with: " [$1]", options: .regularExpression))
            }
        }
        if !notes.isEmpty { out.append("## " + L("sheet.ui.export.sourcesTitle")); out.append(""); out += notes }
        return out.joined(separator: "\n")
    }

    private func run() {
        guard let s = doc.sheet else { return }
        let md = SheetExport.markdown(s, options)
        switch format {
        case "md":
            save("md", UTType(filenameExtension: "md") ?? .plainText) { try md.write(to: $0, atomically: true, encoding: .utf8) }
        case "docx":
            save("docx", UTType(filenameExtension: "docx") ?? .data) { try DocMD.docx(DocMD.parse(Self.plainNotes(md))).write(to: $0) }
        case "pdf":
            let p = NSSavePanel(); p.allowedContentTypes = [.pdf]; p.nameFieldStringValue = baseName + ".pdf"
            guard p.runModal() == .OK, let u = p.url else { return }
            busy = true
            SheetPDF.render(html: SheetExport.html(s, options), to: u) { err in
                busy = false
                if let err { note = err } else { note = L("export.saved", ["name": u.lastPathComponent]); NSWorkspace.shared.activateFileViewerSelecting([u]) }
            }
        case "copy":
            let html = SheetExport.html(s, options)
            let pb = NSPasteboard.general
            pb.clearContents()
            if let d = html.data(using: .utf8), let a = NSAttributedString(html: d, documentAttributes: nil),
               let rtf = a.rtf(from: NSRange(location: 0, length: a.length), documentAttributes: [:]) {
                pb.setData(rtf, forType: .rtf)
            }
            pb.setString(html, forType: .html)
            pb.setString(md, forType: .string)
            note = L("sheet.ui.export.copied")
        case "gdoc":
            let accts = google.accounts.filter { $0.has(GoogleScopes.export) }
            guard let acct = accts.first?.email else { note = L("export.googleConnect"); return }
            let d = DocMD.docx(DocMD.parse(Self.plainNotes(md)))
            busy = true; note = L("nset.checking", ["name": "Google"])
            Task {
                do {
                    let link = try await GoogleService.shared.exportDoc(d, title: s.title, account: acct)
                    note = L("export.gdocDone", ["email": acct])
                    if let u = URL(string: link) { NSWorkspace.shared.open(u) }
                } catch { note = error.localizedDescription }
                busy = false
            }
        default:
            busy = true; note = L("nset.checking", ["name": "Notion"])
            Task { let r = await ExportPanel.toNotion(Self.plainNotes(md), title: s.title, file: ""); busy = false; note = r }
        }
    }

    private func save(_ ext: String, _ type: UTType, _ write: (URL) throws -> Void) {
        let p = NSSavePanel(); p.allowedContentTypes = [type]; p.nameFieldStringValue = baseName + "." + ext
        guard p.runModal() == .OK, let u = p.url else { return }
        do { try write(u); note = L("export.saved", ["name": u.lastPathComponent]) } catch { note = error.localizedDescription }
    }
}

/// HTML to PDF with WebKit (no print dialog): load, wait for the page, createPDF, write.
@MainActor
final class SheetPDF: NSObject, WKNavigationDelegate {
    private static var live: [SheetPDF] = []
    private let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 794, height: 1123))
    private let out: URL
    private let done: (String?) -> Void

    private init(out: URL, done: @escaping (String?) -> Void) { self.out = out; self.done = done }

    static func render(html: String, to url: URL, done: @escaping (String?) -> Void) {
        let r = SheetPDF(out: url, done: done)
        live.append(r)
        r.web.navigationDelegate = r
        r.web.loadHTMLString(html, baseURL: nil)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            web.createPDF { result in
                MainActor.assumeIsolated {
                    switch result {
                    case .success(let data):
                        do { try data.write(to: self.out); self.done(nil) } catch { self.done(error.localizedDescription) }
                    case .failure(let e): self.done(e.localizedDescription)
                    }
                    Self.live.removeAll { $0 === self }
                }
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { done(error.localizedDescription); Self.live.removeAll { $0 === self } }
    }
}
