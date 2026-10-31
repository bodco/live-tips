import AppKit
import SwiftUI
import LiveTipsCore

// 0.8.7 (H, rules/sales.yaml): the sales methods for the pickers, the answer cards file and its editor.
// The rules file is the single source: the app asks the engine for the methods in the interface language.

@MainActor
final class SalesMethods: ObservableObject {
    static let shared = SalesMethods()
    struct Criterion: Identifiable, Hashable { let key: String; let name: String; let explain: String; var id: String { key } }
    struct Method: Identifiable, Hashable { let key: String; let name: String; let desc: String; let chip: Bool; let criteria: [Criterion]; var id: String { key } }
    @Published var methods: [Method] = [
        Method(key: "general", name: "General sales", desc: "", chip: false, criteria: []),
        Method(key: "bant", name: "BANT", desc: "", chip: true, criteria: []),
        Method(key: "spiced", name: "SPICED", desc: "", chip: true, criteria: []),
        Method(key: "meddic", name: "MEDDIC", desc: "", chip: true, criteria: []),
    ]
    @Published var defaultKey = "general"
    private var loadedLang = ""

    func load() {
        let lang = SettingsWindow.model.config.uiLanguage
        guard lang != loadedLang else { return }
        loadedLang = lang
        PyTool.run("sales", ["--methods", "--lang", lang], needsAI: false) { [weak self] r in
            guard let self, let ms = r["methods"] as? [[String: Any]], !ms.isEmpty else { return }
            self.defaultKey = r["default"] as? String ?? "general"
            self.methods = ms.map { m in
                Method(key: m["key"] as? String ?? "", name: m["name"] as? String ?? "", desc: m["desc"] as? String ?? "",
                       chip: m["chip"] as? Bool ?? false,
                       criteria: ((m["criteria"] as? [[String: Any]]) ?? []).map {
                           Criterion(key: $0["key"] as? String ?? "", name: $0["name"] as? String ?? "", explain: $0["explain"] as? String ?? "") })
            }
        }
    }

    func name(_ key: String) -> String { methods.first { $0.key == key }?.name ?? methods.first { $0.key == defaultKey }?.name ?? key }
}

/// The method picker with a short description of each (Start call popover and Settings > Projects).
struct SalesMethodPicker: View {
    @Binding var selection: String
    @ObservedObject var sm = SalesMethods.shared
    var body: some View {
        Picker(L("sales.method"), selection: $selection) {
            ForEach(sm.methods) { m in Text(m.name).tag(m.key) }
        }
        .help(sm.methods.first { $0.key == selection }?.desc ?? "")
        .onAppear { sm.load(); if selection.isEmpty { selection = sm.defaultKey } }
    }
}

/// Answer cards: short ready answers to the questions clients ask (rules/sales.yaml > answer_cards). One file per
/// project, `<project>/pacenote/answer-cards.md`: "## question" then the answer. Pacenote shows the closest card
/// when a client asks something like it.
@MainActor
enum AnswerCards {
    static func url(root: String) -> URL { URL(fileURLWithPath: root).appendingPathComponent("pacenote/answer-cards.md") }

    static let template = """
    # Answer cards

    One card per question: a heading with the question (or several ways to ask it, separated by " | "), then the short answer.

    ## How much does it cost? | What is the price?
    Pricing depends on the scope. A pilot for one team is the usual start; we send the numbers after this call.

    ## How long does it take to start?
    About two weeks from the signed order to the first working version.
    """

    static func count(root: String) -> Int {
        guard let t = try? String(contentsOf: url(root: root), encoding: .utf8) else { return 0 }
        return t.components(separatedBy: "\n").filter { $0.hasPrefix("## ") }.count
    }

    static func show(project: Project) {
        guard !project.root.isEmpty else { return }
        let w = NSWindow(contentViewController: NSHostingController(rootView: Localized { AnswerCardsEditor(root: project.root, name: project.name) }))
        w.tabbingMode = .disallowed
        w.title = L("cards.title", ["project": project.name])
        w.setContentSize(NSSize(width: 620, height: 520))
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct AnswerCardsEditor: View {
    let root: String, name: String
    @State private var text = ""
    @State private var saved = true
    @State private var note = ""
    @State private var tab = "list"        // 0.8.7 (H5): the cards as a list, or the file by hand
    @State private var listID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $tab) {
                Text(L("cards.tab.list")).tag("list")
                Text(L("cards.tab.file")).tag("file")
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .onChange(of: tab) {
                if tab == "file" { text = (try? String(contentsOf: AnswerCards.url(root: root), encoding: .utf8)) ?? AnswerCards.template; saved = FileManager.default.fileExists(atPath: AnswerCards.url(root: root).path) }
                else { listID = UUID() }
            }
            if tab == "list" { AnswerCardsList(root: root).id(listID) } else { fileEditor }
        }
        .padding(16)
    }

    @ViewBuilder private var fileEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("cards.hint")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $text).font(.body.monospaced()).onChange(of: text) { saved = false }
                .scrollContentBackground(.hidden).padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
            HStack {
                Text(note.isEmpty ? L("cards.count", ["n": "\(text.components(separatedBy: "\n").filter { $0.hasPrefix("## ") }.count)"]) : note)
                    .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                Spacer()
                Button(L("home.recent.finder")) { NSWorkspace.shared.activateFileViewerSelecting([AnswerCards.url(root: root)]) }.buttonStyle(.pnTertiary)
                Button(L("common.save")) { save() }.buttonStyle(.pnPrimary).disabled(saved).keyboardShortcut("s")
            }
        }
        .onAppear {
            text = (try? String(contentsOf: AnswerCards.url(root: root), encoding: .utf8)) ?? AnswerCards.template
            saved = FileManager.default.fileExists(atPath: AnswerCards.url(root: root).path)
        }
    }

    func save() {
        let u = AnswerCards.url(root: root)
        do {
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.replacingOccurrences(of: "\u{2014}", with: "-").write(to: u, atomically: true, encoding: .utf8)
            saved = true; note = L("cards.saved"); UsageLog.log("answer_card_saved")
        } catch { note = error.localizedDescription }
    }
}

/// The (i) popover next to the method: what the method is and its criteria (rules/sales.yaml).
struct SalesMethodInfo: View {
    let key: String
    @ObservedObject var sm = SalesMethods.shared
    var body: some View {
        let m = sm.methods.first { $0.key == key } ?? sm.methods.first { $0.key == sm.defaultKey }
        VStack(alignment: .leading, spacing: 8) {
            Text(m?.name ?? "").font(PN.Font.section)
            Text(m?.desc ?? "").font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
            ForEach(m?.criteria ?? []) { c in
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.name).font(PN.Font.body.weight(.semibold))
                    Text(c.explain).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14).frame(width: 320)
        .onAppear { sm.load() }
    }
}

// MARK: - 0.8.7 (H6.1): the Sales section of the call page, edited like the other sections

/// <stem>.sales.json, written by the engine after a sales call; the call page edits it in place.
enum SalesFile {
    static func url(_ file: String) -> URL {
        URL(fileURLWithPath: (file.hasSuffix(".md") ? String(file.dropLast(3)) : file) + ".sales.json")
    }
    static func load(_ file: String) -> [String: Any]? {
        (try? Data(contentsOf: url(file))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
    @discardableResult
    static func save(_ file: String, _ d: [String: Any]) -> Bool {
        var d = d
        // the scorecard follows the edits: known criteria and a next step with a date
        let crit = (d["criteria"] as? [[String: Any]]) ?? []
        var sc = (d["scorecard"] as? [String: Any]) ?? [:]
        sc["known"] = crit.filter { ($0["state"] as? String) == "known" }.count
        sc["total"] = crit.count
        sc["next_step_with_date"] = !(((d["next_step"] as? [String: Any])?["due"] as? String) ?? "").isEmpty
        d["scorecard"] = sc
        guard let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return false }
        return (try? s.replacingOccurrences(of: "\u{2014}", with: "-").write(to: url(file), atomically: true, encoding: .utf8)) != nil
    }
    /// unknown -> partial -> known -> unknown (a click on the state chip)
    static func nextState(_ s: String) -> String { s == "unknown" ? "partial" : s == "partial" ? "known" : "unknown" }
}

/// A criterion's state on the call page: known (green), partly (orange), unknown (grey). A click moves it on.
struct SalesStateChip: View {
    let state: String
    let next: () -> Void
    var body: some View {
        let c = state == "known" ? PN.C.turn : state == "partial" ? PN.C.onMe : PN.C.text3
        Button(action: next) {
            Text(L("sales.state." + (["known", "partial"].contains(state) ? state : "unknown")))
                .font(PN.Font.caption.weight(.semibold)).foregroundStyle(c)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Capsule().fill(c.opacity(0.14)))
                .fixedSize()
        }
        .buttonStyle(.plain)
        .help(L("sales.chip.help"))
        .accessibilityHint(L("sales.chip.help"))
    }
}

// MARK: - 0.8.7 (H5): Save as answer card, and the cards as a list in Settings > Projects

extension AnswerCards {
    /// Appends one card to <root>/pacenote/answer-cards.md (the file is created with a title when missing).
    static func add(_ card: AnswerCard, root: String) -> String? {
        guard !root.isEmpty else { return L("cards.noRoot") }
        let u = url(root: root)
        let old = (try? String(contentsOf: u, encoding: .utf8)) ?? ""
        do {
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try AnswerCardsDoc.append(card, to: old).write(to: u, atomically: true, encoding: .utf8)
            UsageLog.log("answer_card_saved")
            return nil
        } catch { return error.localizedDescription }
    }

    static func load(root: String) -> (preamble: String, cards: [AnswerCard]) {
        AnswerCardsDoc.parse((try? String(contentsOf: url(root: root), encoding: .utf8)) ?? "")
    }

    static func write(root: String, preamble: String, cards: [AnswerCard]) -> String? {
        let u = url(root: root)
        do {
            try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try AnswerCardsDoc.render(preamble: preamble.isEmpty ? "# Answer cards" : preamble, cards: cards).write(to: u, atomically: true, encoding: .utf8)
            return nil
        } catch { return error.localizedDescription }
    }
}

/// The form for one card: question or topic, the answer, tags, use when. Used by Save as answer card and the list.
struct AnswerCardForm: View {
    @State var card: AnswerCard
    let title: String
    let onSave: (AnswerCard) -> String?        // an error line, or nil when saved
    let onCancel: () -> Void
    @State private var err = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(PN.Font.section)
            Text(L("cards.form.hint")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            field(L("cards.form.question")) { TextField("", text: $card.title, prompt: Text(L("cards.form.questionPh"))).textFieldStyle(.roundedBorder) }
            field(L("cards.form.answer")) {
                TextEditor(text: $card.answer).font(PN.Font.body).frame(minHeight: 90)
                    .scrollContentBackground(.hidden).padding(4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.06)))
            }
            field(L("cards.form.tags")) { TextField("", text: $card.tags, prompt: Text(L("cards.form.tagsPh"))).textFieldStyle(.roundedBorder) }
            field(L("cards.form.useWhen")) { TextField("", text: $card.useWhen, prompt: Text(L("cards.form.useWhenPh"))).textFieldStyle(.roundedBorder) }
            if !err.isEmpty { Text(err).font(PN.Font.caption).foregroundStyle(PN.C.danger) }
            HStack {
                Spacer()
                Button(L("common.cancel")) { onCancel() }.buttonStyle(.pnSecondary).keyboardShortcut(.cancelAction)
                Button(L("common.save")) { if let e = onSave(card) { err = e } }
                    .buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
                    .disabled(card.title.trimmingCharacters(in: .whitespaces).isEmpty || card.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18).frame(width: 460)
    }

    private func field<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.text2)
            c()
        }
    }
}

/// Settings > Projects > Answer cards: the cards as a list (add, edit, delete with a confirmation). The file stays
/// hand-editable in the File tab; the list rewrites it from the cards and keeps the text above the first card.
struct AnswerCardsList: View {
    let root: String
    @State private var preamble = ""
    @State private var cards: [AnswerCard] = []
    @State private var editing: AnswerCard? = nil
    @State private var isNew = false
    @State private var deleting: AnswerCard? = nil
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if cards.isEmpty {
                Text(L("cards.empty")).font(PN.Font.body).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(cards) { c in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.title).font(PN.Font.body.weight(.semibold)).foregroundStyle(PN.C.text)
                                Text(c.answer).font(PN.Font.caption).foregroundStyle(PN.C.text2).lineLimit(2)
                                if !c.tags.isEmpty { Text(L("cards.tags", ["tags": c.tags])).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
                            }
                            Spacer()
                            Button { isNew = false; editing = c } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless).help(L("callEdit.edit")).accessibilityLabel(L("callEdit.edit"))
                            Button { deleting = c } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).help(L("callEdit.delete")).accessibilityLabel(L("callEdit.delete"))
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
                    }
                }
            }
            HStack {
                Text(note.isEmpty ? L("cards.count", ["n": "\(cards.count)"]) : note).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                Spacer()
                Button { isNew = true; editing = AnswerCard(title: "", answer: "") } label: { Label(L("cards.add"), systemImage: "plus") }
                    .buttonStyle(.pnSecondary)
            }
        }
        .onAppear { reload() }
        .sheet(item: $editing) { c in
            AnswerCardForm(card: c, title: isNew ? L("cards.add") : L("cards.edit"), onSave: { save($0, new: isNew) }, onCancel: { editing = nil })
        }
        .confirmationDialog(L("cards.delete.title", ["title": deleting?.title ?? ""]), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L("callEdit.delete"), role: .destructive) {
                if let d = deleting { var l = cards; l.removeAll { $0.id == d.id }; if let e = AnswerCards.write(root: root, preamble: preamble, cards: l) { note = e } else { cards = l; note = L("cards.saved") } }
                deleting = nil
            }
            Button(L("common.cancel"), role: .cancel) { deleting = nil }
        } message: { Text(L("cards.delete.body")) }
    }

    func reload() { let d = AnswerCards.load(root: root); preamble = d.preamble; cards = d.cards }

    private func save(_ c: AnswerCard, new: Bool) -> String? {
        var l = cards
        if new { l.append(c) } else if let i = l.firstIndex(where: { $0.id == c.id }) { l[i] = c }
        if let e = AnswerCards.write(root: root, preamble: preamble, cards: l) { return e }
        cards = l; editing = nil; note = L("cards.saved")
        if new { UsageLog.log("answer_card_saved") }
        return nil
    }
}
