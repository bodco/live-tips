import AppKit
import Foundation
import SwiftUI
import LiveTipsCore

/// Pacenote 0.8.7 (E): the call page is edited row by row. A saved edit appends a new call picture ("situation") or
/// agenda line to the call's tips file, so the file keeps its history and every reader takes the last line; register
/// items change through the ops edit, drop and add. When the call has a Notion page, the changed sections are
/// rewritten on it 2 s after the last change (CallPageSync, notion_sections).
enum CallPageEdit {
    /// The tips file that holds the call picture: the app's <file>.tips.jsonl or the skill's <stem>.tips.jsonl.
    static func tipsFile(_ file: String) -> String {
        let stem = file.hasSuffix(".md") ? String(file.dropLast(3)) : file
        return [file + ".tips.jsonl", stem + ".tips.jsonl"].first { FileManager.default.fileExists(atPath: $0) } ?? file + ".tips.jsonl"
    }

    static func lastSituation(_ path: String) -> [String: Any] {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        for ln in s.split(separator: "\n").reversed() where ln.contains("situation") {
            if let o = (try? JSONSerialization.jsonObject(with: Data(ln.utf8))) as? [String: Any], (o["kind"] as? String) == "situation" { return o }
        }
        return [:]
    }

    /// Writes the edited lists as a new call picture line. Lines are trimmed, empty ones dropped, long dashes replaced.
    @discardableResult
    static func save(file: String, decisions: [String], open: [String], risks: [String]) -> Bool {
        let clean: ([String]) -> [String] = { $0.map { $0.replacingOccurrences(of: "\u{2014}", with: "-").trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
        let path = tipsFile(file)
        var o = lastSituation(path)
        o["kind"] = "situation"
        o["decisions"] = clean(decisions)
        let updates = ((o["asks"] as? [[String: Any]]) ?? []).filter { ($0["type"] as? String) == "update" }
        o["asks"] = updates + clean(open).map { ["what": $0, "type": "question"] }
        o["risks"] = clean(risks).map { ["what": $0] }
        o["edited"] = ISO8601DateFormatter().string(from: Date())
        o["source"] = "call_page"
        return appendLine(path, o)
    }

    /// 0.8.7 (E3): the PM changed the agenda on the call page: a new agenda line (the same shape as the call window's),
    /// so StartCallModel.agenda and the wrap-up read the last one. States: done (discussed), now (raised), todo.
    @discardableResult
    static func saveAgenda(file: String, items: [(text: String, state: String)]) -> Bool {
        let rows: [[String: Any]] = items.compactMap { it in
            let t = it.text.replacingOccurrences(of: "\u{2014}", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }
            return ["text": t, "state": it.state, "done": it.state == "done", "cur": it.state == "now"]
        }
        return appendLine(tipsFile(file), ["kind": "agenda", "final": true, "items": rows, "source": "call_page",
                                           "edited": ISO8601DateFormatter().string(from: Date())])
    }

    /// The next agenda state on a click: not raised, raised, discussed, then not raised again.
    static func nextAgendaState(_ s: String) -> String { s == "todo" ? "now" : s == "now" ? "done" : "todo" }

    static func appendLine(_ path: String, _ o: [String: Any]) -> Bool {
        guard JSONSerialization.isValidJSONObject(o), let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return false }
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil) }
        guard let h = FileHandle(forWritingAtPath: path) else { return false }
        h.seekToEndOfFile(); h.write(d); h.write(Data([0x0A])); try? h.close()
        return true
    }

    /// The sections JSON for notion_sections (ids, the script finds the page's own headings).
    static func sectionsJSON(_ obj: [String: [String]]) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(data: d, encoding: .utf8) ?? "{}"
    }

    /// 0.8.7 (E5): the current lines of the edited sections, as the wrap-up wrote them (agenda "Item: discussed",
    /// action items "Who: what (due)"). Section ids: decisions, open, risks, actions, agenda.
    @MainActor
    static func sections(file: String, ids: Set<String>) -> [String: [String]] {
        let o = CallOutcome.read(transcript: file) ?? CallOutcome()
        var out: [String: [String]] = [:]
        for id in ids {
            switch id {
            case "decisions": out[id] = o.decisions
            case "sales": out[id] = []          // 0.8.7 (H6.1): notion_sections reads <stem>.sales.json (--call-md)
            case "open": out[id] = o.openQuestions
            case "risks": out[id] = o.risks
            case "agenda":
                out[id] = StartCallModel.agenda(transcript: file).map { a in
                    a.text + ": " + (a.state == "done" ? L("call.page.discussed") : a.state == "now" ? L("call.page.raised") : L("call.page.notRaised"))
                }
            case "onYou", "onThem", "actions":
                let folder = (file as NSString).deletingLastPathComponent
                let me = PyTool.meLabel
                out["actions"] = Register.shared.items(in: folder)
                    .filter { CommitmentRegister.callKey($0.call) == CommitmentRegister.callKey(file) && $0.status != "dropped" }
                    .map { ($0.mine ? me : $0.owner) + ": " + $0.text + ($0.due.isEmpty ? "" : " (" + Register.dueText($0.due) + ")") }
            default: break
            }
        }
        return out
    }
}

// MARK: - Notion sync of the call page (E5)

/// 0.8.7 (E5): edits on the call page go to the call's existing Notion page 2 s after the last change. Only the
/// sections changed since the last good sync are rewritten; a failed sync keeps them for Retry. One per call file, so
/// leaving the page does not drop a pending sync.
@MainActor
final class CallPageSync: ObservableObject {
    private static var all: [String: CallPageSync] = [:]
    static func of(_ file: String) -> CallPageSync {
        if let s = all[file] { return s }
        let s = CallPageSync(file: file); all[file] = s; return s
    }

    let file: String
    enum State: Equatable { case idle, pending, syncing, ok, failed(String) }
    @Published var state: State = .idle
    @Published var at: Date?
    @Published var appended: [String] = []
    private var dirty = Set<String>()
    private var work: DispatchWorkItem?

    init(file: String) { self.file = file }

    var notionURL: String? {
        guard SettingsWindow.model.isSet(.notionToken),
              let u = CallHistory.shared.records.first(where: { $0.file == file })?.notionURL, !u.isEmpty else { return nil }
        return u
    }

    /// A section changed: (re)start the 2 s timer.
    func changed(_ section: String) {
        guard notionURL != nil else { return }
        dirty.insert(section)
        state = .pending
        work?.cancel()
        let w = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.run() } }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
    }

    func run() {
        work?.cancel(); work = nil
        guard let url = notionURL else { state = .idle; return }
        guard !dirty.isEmpty else { return }
        let ids = dirty
        dirty = []
        state = .syncing
        PyTool.run("notion_sections", ["--page", url, "--sections", CallPageEdit.sectionsJSON(CallPageEdit.sections(file: file, ids: ids)),
                                       "--todo", "actions", "--lang", L10n.lang, "--call-md", file], notion: true) { [weak self] r in
            guard let self else { return }
            if (r["ok"] as? Bool) == true {
                self.at = Date()
                let added = (r["appended"] as? [String]) ?? []
                if !added.isEmpty { self.appended = added }
                self.state = self.dirty.isEmpty ? .ok : .pending
            } else {
                self.dirty.formUnion(ids)
                self.state = .failed((r["error"] as? String) ?? L("py.failed"))
            }
        }
    }
}

/// The status line under the call title: "Synced to Notion · 5 s ago" or "Not synced: <reason> · Retry". No line
/// when the call has no Notion page or Notion is not connected.
struct CallPageSyncLine: View {
    @ObservedObject var sync: CallPageSync

    var body: some View {
        if sync.notionURL != nil && sync.state != .idle {
            TimelineView(.periodic(from: .now, by: 5)) { ctx in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        switch sync.state {
                        case .pending, .syncing:
                            ProgressView().controlSize(.small); Text(L("callEdit.syncing"))
                        case .ok:
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(PN.C.turn).accessibilityHidden(true)
                            Text(L("callEdit.syncedAgo", ["ago": Self.ago(sync.at, ctx.date)]))
                        case .failed(let e):
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(PN.C.onMe).accessibilityHidden(true)
                            Text(L("callEdit.notSynced", ["err": e])).lineLimit(2)
                            Button(L("callEdit.retry")) { sync.run() }.buttonStyle(.pnTertiary)
                        case .idle: EmptyView()
                        }
                    }
                    if !sync.appended.isEmpty {
                        Text(L("callEdit.appended", ["list": sync.appended.joined(separator: ", ")]))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
        }
    }

    static func ago(_ d: Date?, _ now: Date) -> String {
        guard let d else { return "" }
        let s = max(0, Int(now.timeIntervalSince(d)))
        if s < 60 { return L("callEdit.agoS", ["n": "\(max(1, s / 5 * 5))"]) }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US"); f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: now)
    }
}

// MARK: - Rows (E1, E2)

/// One action of a row's menu or of its hover icons. `prompt` opens a small field (owner, due date) instead of running.
struct PageRowAction: Identifiable {
    enum Prompt { case text(title: String, value: String, placeholder: String), date(value: String) }
    let id = UUID()
    var title: String
    var icon = ""
    var enabled = true
    var note = ""              // shown greyed under a disabled item (why it is off)
    var destructive = false
    var divider = false
    var prompt: Prompt? = nil
    var run: (String) -> Void = { _ in }

    static var separator: PageRowAction { PageRowAction(title: "", divider: true) }
}

/// 0.8.7 (E1): a row of the call page. Double-click, or Return on the selected row, opens a field; Return saves, Esc
/// cancels. On hover: pencil (Edit), doc.on.doc (Copy text), ellipsis (the row's menu, also on right-click).
struct EditableRow<Leading: View, Trailing: View>: View {
    let text: String
    var sub: String = ""
    var subColor: Color = PN.C.text3
    var done = false
    var copy: String? = nil
    var hoverActions: [PageRowAction] = []
    var menu: [PageRowAction] = []
    let onSave: (String) -> Void
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    @State private var editing = false
    @State private var draft = ""
    @State private var hover = false
    @State private var prompt: PageRowAction?
    @State private var promptValue = ""
    @State private var promptDate = Date()
    @FocusState private var rowFocus: Bool
    @FocusState private var fieldFocus: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            leading()
            if editing {
                TextField("", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...6).font(PN.Font.body)
                    .focused($fieldFocus)
                    .onSubmit { commit() }
                    .onExitCommand { cancel() }
                    .accessibilityLabel(L("callEdit.edit"))
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(text).font(PN.Font.body).foregroundStyle(done ? PN.C.text3 : PN.C.text).strikethrough(done)
                        .fixedSize(horizontal: false, vertical: true)
                    if !sub.isEmpty { Text(sub).font(PN.Font.caption).foregroundStyle(subColor) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { begin() }
                .simultaneousGesture(TapGesture().onEnded { rowFocus = true })
                HStack(spacing: 2) {
                    ForEach(hoverActions) { a in icon(a) }
                    icon(PageRowAction(title: L("callEdit.edit"), icon: "pencil", run: { _ in begin() }))
                    if let c = copy { icon(PageRowAction(title: L("callEdit.copyText"), icon: "doc.on.doc", run: { _ in Self.copyText(c) })) }
                    Menu { menuContent } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help(L("callEdit.more")).accessibilityLabel(L("callEdit.more"))
                }
                .foregroundStyle(PN.C.text3)
                .opacity(hover || rowFocus ? 1 : 0)
                trailing()
            }
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: PN.Radius.s)
            .fill(rowFocus && !editing ? PN.C.accent.opacity(0.10) : (hover ? PN.C.surface2.opacity(0.6) : Color.clear)))
        .focusable(!editing)
        .focused($rowFocus)
        .focusEffectDisabled()
        .onKeyPress(.return) { guard !editing else { return .ignored }; begin(); return .handled }
        .onHover { hover = $0 }
        .contextMenu { menuContent }
        .popover(isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }), arrowEdge: .bottom) { promptView }
    }

    @ViewBuilder private func icon(_ a: PageRowAction) -> some View {
        Button { trigger(a) } label: { Image(systemName: a.icon).frame(width: 20, height: 18) }
            .buttonStyle(.borderless).disabled(!a.enabled)
            .help(a.enabled ? a.title : (a.note.isEmpty ? a.title : a.note)).accessibilityLabel(a.title)
    }

    @ViewBuilder private var menuContent: some View {
        Button(L("callEdit.edit")) { begin() }
        if let c = copy { Button(L("callEdit.copyText")) { Self.copyText(c) } }
        ForEach(menu) { a in
            if a.divider { Divider() } else {
                Button(role: a.destructive ? .destructive : nil) { trigger(a) } label: { Text(a.title) }.disabled(!a.enabled)
                if !a.enabled && !a.note.isEmpty { Text(a.note) }
            }
        }
    }

    @ViewBuilder private var promptView: some View {
        if let a = prompt {
            VStack(alignment: .leading, spacing: 10) {
                Text(a.title).font(PN.Font.section)
                switch a.prompt {
                case .date?:
                    DatePicker("", selection: $promptDate, displayedComponents: .date).datePickerStyle(.graphical).labelsHidden()
                case .text(_, _, let ph)?:
                    TextField("", text: $promptValue, prompt: Text(ph)).textFieldStyle(.roundedBorder).frame(width: 240)
                        .onSubmit { finishPrompt(a) }
                case nil: EmptyView()
                }
                HStack {
                    if case .date(let v)? = a.prompt, !v.isEmpty {
                        Button(L("callEdit.clearDue")) { a.run(""); prompt = nil }.buttonStyle(.pnTertiary)
                    }
                    Spacer()
                    Button(L("common.cancel")) { prompt = nil }.buttonStyle(.pnSecondary).keyboardShortcut(.cancelAction)
                    Button(L("common.save")) { finishPrompt(a) }.buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
        }
    }

    private func trigger(_ a: PageRowAction) {
        guard a.enabled else { return }
        switch a.prompt {
        case .text(_, let v, _)?: promptValue = v; prompt = a
        case .date(let v)?: promptDate = Self.isoDay.date(from: v) ?? Date(); prompt = a
        case nil: a.run("")
        }
    }

    private func finishPrompt(_ a: PageRowAction) {
        if case .date? = a.prompt { a.run(Self.isoDay.string(from: promptDate)) } else { a.run(promptValue.trimmingCharacters(in: .whitespaces)) }
        prompt = nil
    }

    private func begin() { draft = text; editing = true; DispatchQueue.main.async { fieldFocus = true } }
    private func cancel() { editing = false; rowFocus = true }
    private func commit() {
        let t = draft.replacingOccurrences(of: "\u{2014}", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        editing = false
        rowFocus = true
        if !t.isEmpty && t != text { onSave(t) }
    }

    static var isoDay: DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
    }

    static func copyText(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

extension EditableRow where Trailing == EmptyView {
    init(text: String, sub: String = "", subColor: Color = PN.C.text3, done: Bool = false, copy: String? = nil,
         hoverActions: [PageRowAction] = [], menu: [PageRowAction] = [], onSave: @escaping (String) -> Void,
         @ViewBuilder leading: @escaping () -> Leading) {
        self.init(text: text, sub: sub, subColor: subColor, done: done, copy: copy, hoverActions: hoverActions, menu: menu,
                  onSave: onSave, leading: leading, trailing: { EmptyView() })
    }
}

/// "+ Add" at the bottom of a section: a field opens; Return adds, Esc closes.
struct AddRowField: View {
    var placeholder = ""
    let onAdd: (String) -> Void
    @State private var open = false
    @State private var text = ""
    @FocusState private var focus: Bool

    var body: some View {
        if open {
            TextField("", text: $text, prompt: Text(placeholder), axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(1...4).font(PN.Font.body)
                .focused($focus)
                .onSubmit {
                    let t = text.replacingOccurrences(of: "\u{2014}", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { onAdd(t) }
                    text = ""; open = false
                }
                .onExitCommand { text = ""; open = false }
                .padding(.horizontal, 6)
        } else {
            Button { open = true; DispatchQueue.main.async { focus = true } } label: { Label(L("callEdit.add"), systemImage: "plus") }
                .buttonStyle(.pnTertiary)
        }
    }
}
