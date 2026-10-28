import AppKit
import SwiftUI

/// 2026-10-28 (owner): read (and correct) a call's preparation before the call starts: the full
/// prep-....brief.md in a window, rendered; Edit shows the text, Save writes it back (the first version is kept as
/// .orig.md). During the call the tips window has the same thing as its Preparation pane.
@MainActor
final class PrepDocWindow {
    static var windows: [String: NSWindow] = [:]

    static func show(path: String, title: String) {
        if let w = windows[path] { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentViewController: NSHostingController(rootView: PrepDocView(path: path, title: title)))
        w.title = "Preparation: " + title
        w.styleMask.insert(.resizable)
        w.setContentSize(NSSize(width: 640, height: 760))
        w.isReleasedWhenClosed = false
        windows[path] = w
        w.center(); w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The brief of a planned or chosen call, if it has been written.
    static func path(for m: StartCallModel) -> String? {
        let fm = FileManager.default
        if let b = m.prepBase, fm.fileExists(atPath: b + ".brief.md") { return b + ".brief.md" }
        if let c = m.chosenPrepPath, fm.fileExists(atPath: c) { return c }
        if let p = m.prep, p.matches, let root = m.root {
            let f = ((root as NSString).appendingPathComponent("live") as NSString).appendingPathComponent(p.file)
            if fm.fileExists(atPath: f) { return f }
        }
        return nil
    }
}

struct PrepDocView: View {
    let path: String
    let title: String
    @State private var text = ""
    @State private var editing = false
    @State private var saved = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text").foregroundStyle(Color.accentColor)
                Text((path as NSString).lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                if !saved.isEmpty { Text(saved).font(.caption).foregroundStyle(.green) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }.buttonStyle(.link)
                if editing {
                    Button("Cancel") { load(); editing = false }
                    Button("Save") { save() }.buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command)
                } else {
                    Button("Edit") { editing = true }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            if editing {
                TextEditor(text: $text).font(.system(.callout, design: .monospaced)).padding(8)
            } else {
                ScrollView { MarkdownBlocks(text: text).padding(18).frame(maxWidth: .infinity, alignment: .leading) }
            }
        }
        .frame(minWidth: 480, minHeight: 400)
        .onAppear { load() }
    }

    private func load() { text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

    private func save() {
        let orig = path.replacingOccurrences(of: ".brief.md", with: ".brief.orig.md")
        if orig != path, !FileManager.default.fileExists(atPath: orig) { try? FileManager.default.copyItem(atPath: path, toPath: orig) }
        let old = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        // 2026-10-28 (owner): every correction is logged to learn from (EditLog).
        var t = String(text.split(separator: "\n").first ?? "")
        if let r = t.range(of: "Live Brief:") { t = String(t[r.upperBound...]) }
        if let r = t.range(of: " (prep") { t = String(t[..<r.lowerBound]) }
        t = t.trimmingCharacters(in: .whitespaces)
        let project = (((path as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent as NSString).lastPathComponent
        EditLog.addBriefEdit(title: t.isEmpty ? "Call" : t, project: project, file: path, before: old, after: text, when: "before the call")
        editing = false
        saved = "Saved " + Date().formatted(date: .omitted, time: .shortened)
    }
}

/// A light Markdown view for the briefs: headings, bullets, numbered points, tables (as aligned text), paragraphs.
struct MarkdownBlocks: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                line(raw)
            }
        }
        .textSelection(.enabled)
    }

    private func inline(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) { return Text(a) }
        return Text(s)
    }

    @ViewBuilder private func line(_ raw: String) -> some View {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.isEmpty {
            Spacer().frame(height: 4)
        } else if t.hasPrefix("### ") {
            inline(String(t.dropFirst(4))).font(.callout.weight(.semibold)).padding(.top, 4)
        } else if t.hasPrefix("## ") {
            inline(String(t.dropFirst(3))).font(.headline).padding(.top, 8)
        } else if t.hasPrefix("# ") {
            inline(String(t.dropFirst(2))).font(.title3.weight(.semibold))
        } else if t.range(of: "^[-*•]\\s+", options: .regularExpression) != nil {
            let lead = raw.prefix { $0 == " " }.count
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                inline(t.replacingOccurrences(of: "^[-*•]\\s+", with: "", options: .regularExpression))
            }
            .padding(.leading, CGFloat(min(lead, 8)) * 6)
        } else if let r = t.range(of: "^\\d+[.)]\\s+", options: .regularExpression) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(t[r].trimmingCharacters(in: .whitespaces)).foregroundStyle(.secondary).monospacedDigit()
                inline(String(t[r.upperBound...]))
            }
        } else if t.hasPrefix("|") {
            if t.range(of: "^\\|?\\s*:?-{2,}", options: .regularExpression) == nil {
                Text(t.trimmingCharacters(in: CharacterSet(charactersIn: "|")).replacingOccurrences(of: "|", with: "  ·  "))
                    .font(.callout)
            }
        } else {
            inline(t)
        }
    }
}
