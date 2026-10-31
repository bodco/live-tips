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
        w.tabbingMode = .disallowed      // 0.8.7 (A1): never tabs
        w.title = L("prep.windowTitle", ["title": title])
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

/// Pacenote 0.8 (F4, REDESIGN-SPEC 6): the brief reads like a document. A click on a line edits it in place (Enter
/// saves, Esc cancels); checkboxes are real and write [x] into the file, the same checklist the tips window shows as the
/// agenda. "Prepared 09:40 · for 12:18" under the call's name; Show in Finder and the whole text are in the menu.
struct PrepDocView: View {
    let path: String
    let title: String
    @State private var text = ""
    @State private var editingAll = false
    @State private var editLine: Int?
    @State private var lineText = ""
    @State private var saved = ""
    @FocusState private var lineFocus: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(PN.C.text).lineLimit(2)
                    Text(times).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                }
                Spacer()
                if !saved.isEmpty { Text(saved).font(PN.Font.caption).foregroundStyle(PN.C.turn) }
                if editingAll {
                    Button(L("common.cancel")) { load(); editingAll = false }.buttonStyle(.pnSecondary)
                    Button(L("common.save")) { save(); editingAll = false }.buttonStyle(.pnPrimary).keyboardShortcut("s", modifiers: .command)
                } else {
                    Menu {
                        Button(L("prep.editAll")) { editingAll = true }
                        Button(L("home.recent.finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel(L("home.more"))
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            Divider()
            if editingAll {
                TextEditor(text: $text).font(.system(size: 13, design: .monospaced)).padding(8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { i, raw in
                            if editLine == i {
                                TextField("", text: $lineText)
                                    .textFieldStyle(.roundedBorder)
                                    .focused($lineFocus)
                                    .onSubmit { commitLine(i) }
                                    .onExitCommand { editLine = nil }
                            } else if let done = Self.checkbox(raw) {
                                Toggle(isOn: Binding(get: { done }, set: { toggle(i, $0) })) {
                                    MarkdownBlocks(text: Self.checkboxText(raw))
                                }
                                .toggleStyle(.checkbox)
                            } else {
                                MarkdownBlocks(text: raw)
                                    .contentShape(Rectangle())
                                    .onTapGesture { if !raw.trimmingCharacters(in: .whitespaces).isEmpty { lineText = raw; editLine = i; lineFocus = true } }
                                    .help(L("prep.clickToEdit"))
                            }
                        }
                    }
                    .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(PN.C.bg)
        .frame(minWidth: 480, minHeight: 400)
        .onAppear { load() }
    }

    /// "Prepared 09:40 · for 12:18": the file's time and the call's time from its name (prep-<date>-<HHMM>-...).
    private var times: String {
        let fm = DateFormatter(); fm.dateFormat = "HH:mm"
        var parts: [String] = []
        if let m = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date {
            let f = DateFormatter(); f.dateFormat = Calendar.current.isDateInToday(m) ? "HH:mm" : "d MMM HH:mm"
            parts.append(L("prep.prepared", ["at": f.string(from: m)]))
        }
        let n = (path as NSString).lastPathComponent
        if let r = n.range(of: "\\d{4}-\\d\\d-\\d\\d-(\\d\\d)(\\d\\d)", options: .regularExpression) {
            let hhmm = String(n[r].suffix(4))
            parts.append(L("prep.for", ["at": String(hhmm.prefix(2)) + ":" + String(hhmm.suffix(2))]))
        }
        return parts.joined(separator: " · ")
    }

    static func checkbox(_ raw: String) -> Bool? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("- [ ] ") || t.hasPrefix("* [ ] ") { return false }
        if t.lowercased().hasPrefix("- [x] ") || t.lowercased().hasPrefix("* [x] ") { return true }
        return nil
    }
    static func checkboxText(_ raw: String) -> String {
        String(raw.trimmingCharacters(in: .whitespaces).dropFirst(6))
    }

    private func toggle(_ i: Int, _ on: Bool) {
        var lines = text.components(separatedBy: "\n")
        guard i < lines.count else { return }
        let lead = String(lines[i].prefix { $0 == " " })
        lines[i] = lead + "- [" + (on ? "x" : " ") + "] " + Self.checkboxText(lines[i])
        text = lines.joined(separator: "\n")
        write(log: false)
    }

    private func commitLine(_ i: Int) {
        var lines = text.components(separatedBy: "\n")
        if i < lines.count, lines[i] != lineText { lines[i] = lineText; text = lines.joined(separator: "\n"); save() }
        editLine = nil
    }

    private func load() { text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

    private func save() { write(log: true) }

    private func write(log: Bool) {
        let orig = path.replacingOccurrences(of: ".brief.md", with: ".brief.orig.md")
        if orig != path, !FileManager.default.fileExists(atPath: orig) { try? FileManager.default.copyItem(atPath: path, toPath: orig) }
        let old = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        if log {
            // 2026-10-28 (owner): every correction is logged to learn from (EditLog).
            var t = String(text.split(separator: "\n").first ?? "")
            if let r = t.range(of: "Live Brief:") { t = String(t[r.upperBound...]) }
            if let r = t.range(of: " (prep") { t = String(t[..<r.lowerBound]) }
            t = t.trimmingCharacters(in: .whitespaces)
            let project = (((path as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent as NSString).lastPathComponent
            EditLog.addBriefEdit(title: t.isEmpty ? "Call" : t, project: project, file: path, before: old, after: text, when: "before the call")
        }
        saved = L("prep.saved", ["at": Date().formatted(date: .omitted, time: .shortened)])
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
                Text("•").foregroundStyle(PN.C.text3)
                inline(t.replacingOccurrences(of: "^[-*•]\\s+", with: "", options: .regularExpression))
            }
            .padding(.leading, CGFloat(min(lead, 8)) * 6)
        } else if let r = t.range(of: "^\\d+[.)]\\s+", options: .regularExpression) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(t[r].trimmingCharacters(in: .whitespaces)).foregroundStyle(PN.C.text3).monospacedDigit()
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
