import AppKit
import LiveTipsCore
import SwiftUI

// 0.10.0 (Meeting Sheet, phase 5): the Meeting Sheet tab of an upcoming call (S6), its Readiness (S7), Sources
// (the per-source report) and Versions tabs. Facts carry the number of their source: hover shows the quote, where
// it is and when it was checked, a click opens the source. Status chips are an icon and a word, never colour alone.
// An inline edit marks the fact Edited and Refresh never overwrites it. Mockups: ms/mockups/S6Sheet, S7Ready.

/// The open sheet of a page: loads, saves (edits), recomputes readiness through the sidecar.
@MainActor
final class SheetDoc: ObservableObject {
    @Published var path: String
    @Published var sheet: MeetingSheet?
    @Published var note = ""
    @Published var checking = false

    init(path: String) { self.path = path; reload() }

    func reload() { sheet = SheetCache.shared.load(path) }

    /// Apply a change, save it, then let the sidecar compute readiness again (auto questions, old facts).
    func change(_ f: (inout MeetingSheet) -> Bool) {
        guard var s = sheet, f(&s) else { return }
        sheet = s
        guard SheetCache.shared.save(s, to: path) else { note = L("sheet.ui.err.save"); return }
        recheck()
    }

    func recheck() {
        checking = true
        SheetCLI.run("readiness", args: ["--sheet", path, "--app-root", SheetCLI.appRoot]) { r in
            self.checking = false
            if let e = SheetCLI.error(r), r.json?["state"] == nil { self.note = L("sheet.ui.err.readiness", ["e": e]) }
            self.reload()
        }
    }

    var base: String { SheetFiles.base(of: path) }
}

/// The Meeting Sheet tab (S6).
struct MeetingSheetTab: View {
    @ObservedObject var doc: SheetDoc
    @ObservedObject var prefs = SheetPrefs.shared
    var onRefresh: () -> Void
    var onEditBlocks: () -> Void
    var onCompare: (Int) -> Void = { _ in }
    @State private var width: CGFloat = 0        // 0.10.0 (Meeting Sheet, polish): the right column only on a wide page

    var body: some View {
        if let s = doc.sheet {
            // 0.10.0 (Meeting Sheet, polish): the right column "On this sheet" (mockup S6) when the page is wide enough
            ScrollViewReader { proxy in
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 16) {
                        headerLine(s)
                        let d = SheetDiffCounts.of(s)
                        if !d.isEmpty { diffBanner(s, d) }
                        if !doc.note.isEmpty { Text(doc.note).font(PN.Font.caption).foregroundStyle(PN.C.pending) }
                        myFocus(s).id("sheet-block-" + (s.block(.myFocus)?.id ?? "my_focus"))
                        ForEach(s.shownBlocks.filter { $0.type != .myFocus }) { b in
                            SheetBlockCard(doc: doc, block: b, onRefresh: onRefresh).id("sheet-block-" + b.id)
                        }
                        hiddenLine(s)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if width >= 900 { SheetOnThisSheet(sheet: s, myFocusShown: myFocusShown(s)) { id in
                        withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo("sheet-block-" + id, anchor: .top) }
                    }.frame(width: 232) }
                }
                .background(GeometryReader { g in
                    Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w }
                })
            }
        } else {
            PageCard { PageEmpty(icon: "doc.text", title: L("sheet.ui.err.read"), text: doc.path) }
        }
    }

    private func headerLine(_ s: MeetingSheet) -> some View {
        let read = s.sources.filter { [.full, .summarized, .truncated].contains($0.used) }.count
        let skipped = s.sources.filter { $0.used == .skipped }.count
        var parts: [String] = []
        if let b = s.builtAt { parts.append(L("sheet.ui.head.built", ["at": SheetLabels.date(b), "route": s.route.map { AIRoute.name($0) } ?? "-"])) }
        else { parts.append(L("sheet.ui.head.notBuilt")) }
        parts.append(skipped > 0 ? L("sheet.ui.head.readSkipped", ["n": "\(read)", "k": "\(skipped)"]) : L("sheet.ui.head.read", ["n": "\(read)"]))
        if let v = s.versions?.map(\.n).max() { parts.append(L("sheet.ui.head.version", ["n": "\(v)"])) }
        return HStack(spacing: 10) {
            Text(parts.joined(separator: " · ")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            SheetReadinessPill(badge: s.readinessBadge)
            if doc.checking { ProgressView().controlSize(.small) }
            Spacer()
            Button(L("sheet.ui.blocks.edit"), action: onEditBlocks).buttonStyle(.pnTertiary)
        }
    }

    private func diffBanner(_ s: MeetingSheet, _ d: SheetDiffCounts) -> some View {
        PageCard(spacing: 8, tint: PN.C.accent) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(PN.C.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("sheet.ui.diff.title", ["at": SheetLabels.date(s.refreshedAt ?? s.builtAt)])).font(PN.Font.body.weight(.semibold))
                    Text(L("sheet.ui.diff.counts", ["new": "\(d.new)", "changed": "\(d.changed)", "gone": "\(d.gone)"])
                         + (d.keptEdits > 0 ? " " + L("sheet.ui.diff.kept", ["n": "\(d.keptEdits)"]) : ""))
                        .font(PN.Font.body).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if let prev = (s.versions?.map(\.n).max()).map({ $0 - 1 }), prev > 0 {
                    Button(L("sheet.ui.diff.compare", ["n": "\(prev)"])) { onCompare(prev) }.buttonStyle(.pnTertiary)
                }
                Button(L("sheet.ui.diff.accept")) { doc.change { SheetEdit.acceptDiff(&$0); return true } }.buttonStyle(.pnSecondary)
            }
        }
    }

    private func myFocusShown(_ s: MeetingSheet) -> Bool {
        guard let b = s.block(.myFocus) else { return false }
        return b.visible || !prefs.focus.isEmpty
    }

    /// My focus on top: the fields from Settings > Meeting Sheet, each with its fact or "Not found".
    @ViewBuilder private func myFocus(_ s: MeetingSheet) -> some View {
        if let b = s.block(.myFocus), b.visible || !prefs.focus.isEmpty {
            PageCard(spacing: 6, tint: PN.C.accent) {
                PageLabel(text: L("sheet.ui.myFocus")) { Text(L("sheet.ui.myFocus.yours")).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
                let facts = b.facts
                let extra = facts.filter { f in !prefs.focus.contains { $0.caseInsensitiveCompare(f.label ?? "") == .orderedSame } }
                ForEach(prefs.focus, id: \.self) { field in
                    if let f = facts.first(where: { ($0.label ?? "").caseInsensitiveCompare(field) == .orderedSame }) {
                        SheetFactRow(doc: doc, fact: f)
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(field + ":").font(PN.Font.body.weight(.semibold)).foregroundStyle(PN.C.text)
                            Label(L("sheet.ui.status.notFound"), systemImage: "questionmark.circle").font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.pending)
                        }
                        .padding(.vertical, 3)
                    }
                }
                ForEach(extra) { f in SheetFactRow(doc: doc, fact: f) }
            }
        }
    }

    @ViewBuilder private func hiddenLine(_ s: MeetingSheet) -> some View {
        let hidden = s.blocks.filter { !$0.visible }
        let empty = s.blocks.filter { $0.visible && $0.onlyIfData && $0.facts.isEmpty }
        if !hidden.isEmpty || !empty.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if !hidden.isEmpty {
                    HStack(spacing: 6) {
                        Text(L("sheet.ui.blocks.hidden", ["list": hidden.map(\.title).joined(separator: ", ")])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                        ForEach(hidden) { b in
                            Button(L("sheet.ui.block.showNamed", ["title": b.title])) { doc.change { SheetEdit.block(&$0, id: b.id, .show) } }.buttonStyle(.pnTertiary)
                        }
                    }
                }
                if !empty.isEmpty {
                    Text(L("sheet.ui.blocks.onlyIfData", ["list": empty.map(\.title).joined(separator: ", ")])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                }
            }
            .padding(.horizontal, 6)
        }
    }
}

/// 0.10.0 (Meeting Sheet, polish): the right column of S6. "On this sheet": the facts by status, then each block with
/// its facts, not found and conflicts (a click scrolls to the block), then a short sources report.
struct SheetOnThisSheet: View {
    let sheet: MeetingSheet
    var myFocusShown: Bool
    var go: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageCard(spacing: 6) {
                PageLabel(text: L("sheet.ui.nav.title")) { EmptyView() }
                ForEach(SheetBlockCount.statuses(sheet).filter { $0.1 > 0 }, id: \.0.rawValue) { st, n in
                    HStack(spacing: 6) {
                        let l = legend(st)
                        Label(l.text, systemImage: l.icon).font(PN.Font.caption.weight(.semibold)).foregroundStyle(l.color)
                        Spacer()
                        Text("\(n)").font(PN.Font.caption.monospacedDigit()).foregroundStyle(PN.C.text2)
                    }
                }
                Divider().padding(.vertical, 4)
                PageLabel(text: L("sheet.ui.nav.blocks")) { EmptyView() }
                ForEach(blocks) { b in
                    let c = SheetBlockCount.of(b)
                    Button { go(b.id) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(b.type == .myFocus ? L("sheet.ui.myFocus") : b.title).font(PN.Font.body.weight(.medium)).foregroundStyle(PN.C.text).lineLimit(1)
                            HStack(spacing: 6) {
                                Text(L("sheet.ui.nav.facts", ["n": "\(c.facts)"])).foregroundStyle(PN.C.text3)
                                if c.notFound > 0 { Text(L("sheet.ui.nav.notFound", ["n": "\(c.notFound)"])).foregroundStyle(PN.C.pending) }
                                if c.conflicts > 0 { Text(L("sheet.ui.nav.conflicts", ["n": "\(c.conflicts)"])).foregroundStyle(PN.C.pending) }
                            }
                            .font(PN.Font.caption).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).padding(.vertical, 2)
                }
                Text(L("sheet.ui.nav.hint")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
            if !sheet.sources.isEmpty {
                PageCard(spacing: 6) {
                    PageLabel(text: L("sheet.ui.sources.report")) { EmptyView() }
                    ForEach(sheet.sources.sorted { $0.n < $1.n }.prefix(8)) { src in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(src.n)").font(.system(size: 10, weight: .bold).monospacedDigit()).foregroundStyle(PN.C.answer).frame(width: 14, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(src.title).font(PN.Font.caption.weight(.medium)).foregroundStyle(PN.C.text).lineLimit(1).truncationMode(.tail)
                                let a = SheetLabels.access(src)
                                Text(src.access == .ok ? SheetLabels.used(src.used) : a.text).font(PN.Font.caption).lineLimit(1)
                                    .foregroundStyle(src.access == .ok ? (src.used == .skipped || src.used == .truncated ? PN.C.pending : PN.C.text3) : a.color)
                            }
                        }
                    }
                }
            }
        }
    }

    private var blocks: [SheetBlock] {
        sheet.shownBlocks.filter { $0.type != .myFocus || myFocusShown }
    }

    private func legend(_ st: FactStatus) -> (text: String, icon: String, color: Color) {
        switch st {      // the same words and icons as the fact chips (SheetLabels.status)
        case .notFound: return (L("sheet.ui.status.notFound"), "questionmark.circle", PN.C.pending)
        case .needsCheck: return (L("sheet.ui.status.check"), "exclamationmark.circle", PN.C.pending)
        case .conflict: return (L("sheet.ui.status.conflict"), "arrow.left.arrow.right.circle", PN.C.pending)
        case .stale: return (L("sheet.ui.status.old"), "clock.arrow.circlepath", PN.C.onMe)
        case .edited: return (L("sheet.ui.status.edited"), "pencil.circle", PN.C.docs)
        default: return (L("sheet.ui.status.found"), "checkmark.circle", PN.C.turn)
        }
    }
}

/// One block: title, the method in the qualification header, the block menu, its facts.
struct SheetBlockCard: View {
    @ObservedObject var doc: SheetDoc
    let block: SheetBlock
    var onRefresh: () -> Void
    @ObservedObject var lib = SheetLibrary.shared
    @State private var confirmDelete = false
    @State private var adding = false
    @State private var newText = ""

    var body: some View {
        PageCard(spacing: 4) {
            PageLabel(text: block.title) {
                HStack(spacing: 8) {
                    if block.type == .qualification {
                        Menu(L("sheet.ui.method", ["m": (block.method ?? "bant").uppercased()])) {
                            ForEach(lib.methods, id: \.self) { m in
                                Button(m.uppercased()) { doc.change { SheetEdit.setMethod(&$0, blockID: block.id, method: m) } }
                            }
                        }
                        .menuStyle(.borderlessButton).fixedSize().font(PN.Font.caption)
                    }
                    if block.editedByUser { Label(L("sheet.ui.status.edited"), systemImage: "pencil").font(PN.Font.caption).foregroundStyle(PN.C.docs) }
                    menu
                }
            }
            .padding(.bottom, 4)
            if block.facts.isEmpty {
                Label(L("sheet.ui.block.empty"), systemImage: "questionmark.circle").font(PN.Font.caption).foregroundStyle(PN.C.pending)
            }
            // 0.10.0 (Meeting Sheet, round 2): a value replaced by a newer one shows as "was X" under the newer fact
            ForEach(shownFacts) { f in SheetFactRow(doc: doc, fact: f) }
            if adding {
                HStack(spacing: 8) {
                    TextField(L("sheet.ui.fact.addPh"), text: $newText).textFieldStyle(.roundedBorder).onSubmit(add)
                    Button(L("common.save"), action: add).buttonStyle(.pnSecondary)
                    Button(L("common.cancel")) { adding = false; newText = "" }.buttonStyle(.pnTertiary)
                }
                .padding(.top, 6)
            }
        }
        .confirmationDialog(L("sheet.ui.block.deleteQ", ["title": block.title]), isPresented: $confirmDelete) {
            Button(L("sheet.ui.block.delete"), role: .destructive) { doc.change { SheetEdit.block(&$0, id: block.id, .delete) } }
            Button(L("common.cancel"), role: .cancel) {}
        }
    }

    /// 0.10.0 (Meeting Sheet, smoke): one row per conflict (the mockup S6: both values and Use A / Use B in one box);
    /// the other side of the pair is not shown a second time with the same box. Replaced facts show as "was X".
    private var shownFacts: [SheetFact] {
        var partners = Set<String>()
        return block.facts.filter { f in
            guard f.supersededBy == nil else { return false }
            if f.status == .conflict {
                if partners.contains(f.id) { return false }
                partners.formUnion(f.conflictWith ?? [])
            }
            return true
        }
    }

    private func add() {
        let t = newText
        doc.change { SheetEdit.addFact(&$0, blockType: block.type, text: t, now: SheetCLI.now()) != nil }
        newText = ""; adding = false
    }

    private var menu: some View {
        Menu {
            Button(L("sheet.ui.fact.add")) { adding = true }
            Button(L("sheet.ui.block.regenerate")) { SheetActions.refresh(doc: doc, blocks: [block.id]); onRefresh() }
            Button(L("sheet.ui.block.hide")) { doc.change { SheetEdit.block(&$0, id: block.id, .hide) } }
            Button(L("sheet.ui.block.up")) { doc.change { SheetEdit.block(&$0, id: block.id, .moveUp) } }
            Button(L("sheet.ui.block.down")) { doc.change { SheetEdit.block(&$0, id: block.id, .moveDown) } }
            Divider()
            Button(L("sheet.ui.block.delete"), role: .destructive) { confirmDelete = true }
        } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel(L("sheet.ui.block.menu"))
    }
}

/// One fact: label, text, source numbers, status chip, diff mark, inline edit, the conflict choice.
struct SheetFactRow: View {
    @ObservedObject var doc: SheetDoc
    let fact: SheetFact
    @State private var editing = false
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if editing { editor } else { line }
            if fact.status == .conflict, !(fact.conflictWith ?? []).isEmpty { conflict }
            if let old = doc.sheet?.replaced(by: fact.id).first {
                Text(L("sheet.ui.fact.was", ["v": old.text]) + (old.sourceIds.first.flatMap { doc.sheet?.source(id: $0)?.title }.map { " · " + $0 } ?? ""))
                    .font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, fact.diff == nil ? 0 : 6)
        .background(diffColor.map { RoundedRectangle(cornerRadius: 6).fill($0.opacity(0.08)) })
    }

    private var diffColor: Color? {
        switch fact.diff {
        case .some(.new): return PN.C.turn
        case .some(.changed): return PN.C.accent
        case .some(.gone): return PN.C.text3
        default: return nil
        }
    }

    private var line: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let d = fact.diff {
                Text(L("sheet.ui.diff." + d.rawValue)).font(.system(size: 10, weight: .bold)).foregroundStyle(diffColor ?? PN.C.text3)
                    .padding(.horizontal, 4).background(Capsule().stroke(diffColor ?? PN.C.text3))
            }
            // 0.10.0 (Meeting Sheet, polish): "Budget:" + the Not found chip, without the "Not found" text repeated.
            (Text(fact.label.map { fact.shownText.isEmpty ? $0 + ":" : $0 + ": " } ?? "").fontWeight(.semibold) + Text(fact.shownText))
                .font(PN.Font.body).foregroundStyle(fact.diff == .gone ? PN.C.text3 : PN.C.text)
                .strikethrough(fact.diff == .gone)
                .fixedSize(horizontal: false, vertical: true)
                .onTapGesture(count: 2) { start() }
            ForEach(fact.sourceIds, id: \.self) { sid in
                if let src = doc.sheet?.source(id: sid) { SheetSourceNumber(source: src, fact: fact) }
            }
            if let st = SheetLabels.status(fact) {
                Label(st.text, systemImage: st.icon).font(PN.Font.caption.weight(.semibold)).foregroundStyle(st.color).fixedSize()
            }
            Spacer(minLength: 4)
            Button { start() } label: { Image(systemName: "pencil").foregroundStyle(PN.C.text3) }
                .buttonStyle(.plain).help(L("sheet.ui.fact.edit")).accessibilityLabel(L("sheet.ui.fact.edit"))
        }
    }

    private func start() { text = fact.text; editing = true }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("", text: $text, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...6).onSubmit(save)
            HStack(spacing: 8) {
                Button(L("common.save"), action: save).buttonStyle(.pnSecondary).keyboardShortcut(.defaultAction)
                Button(L("common.cancel")) { editing = false }.buttonStyle(.pnTertiary).keyboardShortcut(.cancelAction)
                Text(L("sheet.ui.fact.editNote")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
        }
    }

    private func save() {
        let t = text, id = fact.id
        doc.change { SheetEdit.editFact(&$0, factID: id, text: t, now: SheetCLI.now()) }
        editing = false
    }

    /// Both values side by side with the source of each: Use A / Use B / Keep both, ask on the call.
    @ViewBuilder private var conflict: some View {
        if let s = doc.sheet {
            let others = (fact.conflictWith ?? []).compactMap { s.fact(id: $0) }
            VStack(alignment: .leading, spacing: 6) {
                ForEach([fact] + others) { f in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(f.text).font(PN.Font.body.weight(.semibold))
                        Text(f.sourceIds.compactMap { s.source(id: $0)?.title }.joined(separator: ", ") + (f.checkedAt.map { " · " + SheetLabels.date($0) } ?? ""))
                            .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    }
                }
                HStack(spacing: 8) {
                    ForEach([fact] + others) { f in
                        Button(L("sheet.ui.conflict.use", ["v": String(f.text.prefix(24))])) {
                            doc.change { SheetEdit.settle(&$0, factID: fact.id, .use(f.id), now: SheetCLI.now()) }
                        }.buttonStyle(.pnSecondary)
                    }
                    Button(L("sheet.ui.conflict.keepBoth")) {
                        let q = L("sheet.ui.conflict.question", ["a": fact.text, "b": others.map(\.text).joined(separator: " / ")])
                        doc.change { SheetEdit.settle(&$0, factID: fact.id, .keepBoth, now: SheetCLI.now(), question: q) }
                    }.buttonStyle(.pnTertiary)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(PN.C.pendingFill.opacity(0.08)))
        }
    }
}

/// The source number next to a fact: hover shows the quote, where and when; a click opens the source.
struct SheetSourceNumber: View {
    let source: SheetSource
    let fact: SheetFact
    var body: some View {
        Button { SheetOpen.source(source, locator: fact.locator) } label: {
            Text("\(source.n)").font(.system(size: 10, weight: .bold).monospacedDigit()).foregroundStyle(PN.C.answer)
                .frame(minWidth: 16, minHeight: 16).background(Circle().fill(PN.C.accent.opacity(0.13)))
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .accessibilityLabel(L("sheet.ui.source.n", ["n": "\(source.n)", "title": source.title]))
    }

    private var tooltip: String {
        var t = "\(source.n) · " + (fact.locator?.url ?? source.uri ?? source.title)
        if let q = fact.locator?.quote, !q.isEmpty { t += "\n\"" + q + "\"" }
        var whereParts: [String] = []
        if let p = fact.locator?.page { whereParts.append(L("sheet.ui.loc.page", ["n": "\(p)"])) }
        if let l = fact.locator?.line { whereParts.append(L("sheet.ui.loc.line", ["n": "\(l)"])) }
        if let sl = fact.locator?.slide { whereParts.append(L("sheet.ui.loc.slide", ["n": "\(sl)"])) }
        if let c = fact.locator?.cell { whereParts.append(L("sheet.ui.loc.cell", ["c": c])) }
        let checked = fact.checkedAt.map { L("sheet.ui.loc.checked", ["at": SheetLabels.date($0)]) }
        t += "\n" + ([checked].compactMap { $0 } + whereParts).joined(separator: " · ")
        return t + "\n" + L("sheet.ui.loc.click")
    }
}

// MARK: - Readiness (S7)

struct SheetReadinessTab: View {
    @ObservedObject var doc: SheetDoc
    var onAddSource: () -> Void
    var onStart: () -> Void
    @ObservedObject var lib = SheetLibrary.shared
    @State private var ownerFor: String?
    @State private var owner = ""

    var body: some View {
        if let s = doc.sheet {
            let b = s.readinessBadge
            let gaps = s.readiness?.gaps ?? []
            VStack(alignment: .leading, spacing: 16) {
                PageCard(spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: b.symbol).font(.system(size: 22)).foregroundStyle(SheetLabels.readiness(b).color)
                        Text(SheetLabels.readiness(b).text).font(.system(size: 22, weight: .bold)).foregroundStyle(SheetLabels.readiness(b).color)
                        if doc.checking { ProgressView().controlSize(.small) }
                        Spacer()
                        Button(L("home.startCall"), action: onStart).buttonStyle(.pnPrimary)
                    }
                    Text(summary(b)).font(PN.Font.body).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
                    Text(L("sheet.ui.ready.rules", ["preset": lib.preset(s.preset)?.name ?? s.preset])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                }
                if !gaps.isEmpty {
                    PageCard(spacing: 4) {
                        PageLabel(text: L("sheet.ui.ready.gaps"))
                        ForEach(gaps) { g in gapRow(s, g) }
                    }
                }
                PageCard(spacing: 2) {
                    PageLabel(text: L("sheet.ui.ready.checks")).padding(.bottom, 4)
                    ForEach(Array((s.readiness?.checks ?? []).enumerated()), id: \.offset) { _, c in
                        HStack(spacing: 8) {
                            Image(systemName: c.dropped == true ? "minus.circle" : c.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(c.dropped == true ? PN.C.text3 : c.ok ? PN.C.turn : PN.C.pending)
                            Text(ruleText(c.rule)).font(PN.Font.body).foregroundStyle(c.dropped == true ? PN.C.text3 : PN.C.text)
                            Spacer()
                            Text(c.dropped == true ? L("sheet.ui.check.dropped") : c.skipped == true ? (c.reason == "block_hidden" ? L("sheet.ui.check.skippedHidden") : L("sheet.ui.check.skipped")) : c.ok ? L("sheet.ui.check.ok") : L("sheet.ui.check.gap"))
                                .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                        }
                        .padding(.vertical, 3)
                    }
                    if (s.readiness?.checks ?? []).isEmpty { Text(L("sheet.ui.ready.noChecks")).font(PN.Font.body).foregroundStyle(PN.C.text3) }
                }
                PageCard(spacing: 4) {
                    PageLabel(text: L("sheet.ui.ready.team"))
                    Text(L("sheet.ui.ready.teamLater")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                }
            }
        }
    }

    private func summary(_ b: ReadinessBadge) -> String {
        switch b.state {
        case .some(.ready): return L("sheet.ui.ready.readyBody")
        case .some(.almost): return L("sheet.ui.ready.almostBody", ["n": "\(b.gaps)"])
        case .some(.notReady): return L("sheet.ui.ready.notReadyBody", ["n": "\(b.gaps)", "k": "\(b.blockers)"])
        default: return L("sheet.ui.ready.unknownBody")
        }
    }

    private func ruleText(_ rule: String) -> String {
        let k = "sheet.ui.rule." + rule
        let t = L(k)
        return t == k ? (lib.ruleGaps[rule] ?? rule.replacingOccurrences(of: "_", with: " ")) : t
    }

    private func gapRow(_ s: MeetingSheet, _ g: SheetGap) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: g.severity == .blocker ? "xmark.octagon.fill" : "exclamationmark.triangle.fill").foregroundStyle(PN.C.pending)
                Text(g.text).font(PN.Font.body.weight(.semibold)).foregroundStyle(PN.C.text).fixedSize(horizontal: false, vertical: true)
                if g.severity == .blocker { Text(L("sheet.ui.gap.blocker")).font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.pending) }
            }
            if g.rule == "no_open_conflicts", let fid = g.fact, let f = s.fact(id: fid) {
                SheetFactRow(doc: doc, fact: f).padding(.leading, 24)
            }
            HStack(spacing: 8) {
                actionButton(g, g.action, primary: true)
                ForEach(extraActions(g), id: \.rawValue) { a in actionButton(g, a, primary: false) }
                if g.action != .dropCheck { actionButton(g, .dropCheck, primary: false) }
            }
            .padding(.leading, 24)
            if ownerFor == g.id {
                HStack(spacing: 8) {
                    TextField(L("sheet.ui.gap.ownerPh"), text: $owner).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                    Button(L("common.save")) {
                        let o = owner, fid = g.fact ?? ""
                        doc.change { SheetEdit.setOwner(&$0, factID: fid, owner: o) }
                        ownerFor = nil; owner = ""
                    }.buttonStyle(.pnSecondary)
                }
                .padding(.leading, 24)
            }
        }
        .padding(.vertical, 6)
    }

    private func extraActions(_ g: SheetGap) -> [GapAction] {
        var a: [GapAction] = []
        if g.action != .addQuestion { a.append(.addQuestion) }
        if g.action != .findAgain { a.append(.findAgain) }
        if g.action != .markChecked && g.fact != nil { a.append(.markChecked) }
        if g.action != .addSource { a.append(.addSource) }
        return Array(a.prefix(2))
    }

    @ViewBuilder private func actionButton(_ g: SheetGap, _ a: GapAction, primary: Bool) -> some View {
        let title = L("sheet.ui.gap." + a.rawValue)
        let run: () -> Void = {
            switch a {
            case .addQuestion, .markChecked, .dropCheck:
                doc.change { SheetEdit.closeGap(&$0, gapID: g.id, action: a, now: SheetCLI.now(), question: a == .addQuestion ? L("sheet.ui.gap.question", ["gap": g.text]) : nil) }
            case .findAgain: SheetActions.refresh(doc: doc, blocks: g.block.map { [$0] } ?? [], findAgain: g.id)
            case .assignOwner: ownerFor = g.id
            case .addSource: onAddSource()
            default: break
            }
        }
        if primary { Button(title, action: run).buttonStyle(.pnSecondary) } else { Button(title, action: run).buttonStyle(.pnTertiary) }
    }
}

// MARK: - Sources report and versions

struct SheetSourcesTab: View {
    @ObservedObject var doc: SheetDoc
    var onAddSource: () -> Void
    var root: String? = nil               // 0.10.0 (Meeting Sheet, polish): the project folder, for the Confirm in Google copy

    var body: some View {
        if let s = doc.sheet {
            PageCard(spacing: 0) {
                PageLabel(text: L("sheet.ui.sources.report")) {
                    Button(L("sheet.ui.sources.add"), action: onAddSource).buttonStyle(.pnTertiary)
                }
                .padding(.bottom, 8)
                if let r = s.sizeReport, let t = r.totalTokens {
                    Text(L("sheet.ui.sources.total", ["t": SheetLabels.tokens(t), "w": SheetLabels.tokens(r.window), "route": r.route.map { AIRoute.name($0) } ?? "-"]))
                        .font(PN.Font.caption).foregroundStyle(PN.C.text3).padding(.bottom, 8)
                }
                ForEach(Array(s.sources.sorted { $0.n < $1.n }.enumerated()), id: \.element.id) { i, src in
                    if i > 0 { Divider() }
                    SheetSourceReportRow(source: src, onFix: { fix(src, $0) }).padding(.vertical, 8)
                }
                if !doc.note.isEmpty { Text(doc.note).font(PN.Font.caption).foregroundStyle(PN.C.pending).padding(.top, 6) }
                if s.sources.isEmpty { Text(L("sheet.ui.sources.none")).font(PN.Font.body).foregroundStyle(PN.C.text3) }
            }
        }
    }

    /// 0.10.0 (Meeting Sheet, polish): the fix actions are real buttons, wired to the same actions as Expert step 3.
    private func fix(_ src: SheetSource, _ f: FixAction) {
        switch f {
        case .connectGoogle: SettingsWindow.show(tab: "google")          // Settings > Integrations > Google
        case .connectNotion: SettingsWindow.show(tab: "notion")          // Settings > Integrations > Notion
        case .confirmGoogle:
            GooglePicker.confirm(url: src.uri ?? "", root: root) { o in
                switch o {
                case .copied: doc.note = L("sheet.ui.sources.confirmed")
                case .note(let m): doc.note = m
                case .cancelled: break
                }
            }
        case .openInBrowser:
            if let u = src.uri, let url = URL(string: u), url.scheme != nil { NSWorkspace.shared.open(url) } else { SheetOpen.source(src) }
        default: onAddSource()                                           // paste the text, save as PDF, fill in, retry: Expert step 3
        }
    }
}

struct SheetSourceReportRow: View {
    let source: SheetSource
    var onFix: (FixAction) -> Void = { _ in }
    var body: some View {
        let a = SheetLabels.access(source)
        HStack(alignment: .top, spacing: 10) {
            Text("\(source.n)").font(.system(size: 11, weight: .bold).monospacedDigit()).foregroundStyle(PN.C.answer)
                .frame(width: 20, height: 20).background(Circle().fill(PN.C.accent.opacity(0.13)))
            Image(systemName: SheetLabels.icon(source.type)).foregroundStyle(PN.C.text3).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Button { SheetOpen.source(source) } label: { Text(source.title).font(PN.Font.body.weight(.medium)).foregroundStyle(PN.C.text) }.buttonStyle(.plain)
                    if source.deck != nil { PagePill(text: L("sheet.ui.deck"), color: PN.C.docs) }
                    if source.auto == true { PagePill(text: L("sheet.ui.src.auto"), color: PN.C.text3) }
                }
                Text([SheetLabels.kind(source.type), SheetLabels.tokens(source.sizeTokens), source.pass.map { L("sheet.ui.pass", ["n": "\($0)"]) }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                if let r = source.reason ?? source.accessReason { Text(r).font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true) }
                // 0.10.0 (Meeting Sheet, fix 2026-11-12): a source Pacenote added says why (Tracker, earlier calls, digest)
                else if let w = source.why, !w.isEmpty { Text(w.joined(separator: " · ")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                // 0.10.0 (Meeting Sheet, smoke): a cut source is a warning (orange, scissors), not a green "read"
                Label(source.access == .ok ? SheetLabels.used(source.used) : a.text, systemImage: source.access == .ok ? (source.used == .skipped || source.used == .notUsed ? "minus.circle" : source.used == .truncated ? "scissors" : "checkmark.circle.fill") : a.icon)
                    .font(PN.Font.caption.weight(.semibold)).foregroundStyle(source.access == .ok ? (source.used == .skipped || source.used == .truncated ? PN.C.pending : PN.C.turn) : a.color)
                // 0.10.0 (Meeting Sheet, polish): a button, not text
                if let f = source.fixAction { Button(SheetLabels.fix(f)) { onFix(f) }.buttonStyle(.pnSecondary).controlSize(.small).fixedSize().padding(.top, 4) }
            }
        }
    }
}

struct SheetVersionsTab: View {
    @ObservedObject var doc: SheetDoc
    var initialOpen: Int? = nil           // "Compare with version N" from the Refresh banner
    @State private var open: Int?
    @State private var note = ""

    var body: some View {
        if let s = doc.sheet {
            let files = SheetFiles.versions(of: doc.path)
            VStack(alignment: .leading, spacing: 16) {
                PageCard(spacing: 0) {
                    PageLabel(text: L("sheet.ui.versions")).padding(.bottom, 8)
                    // 0.10.0 (Meeting Sheet, smoke): the current version shows when it was refreshed, not the first build
                    row(n: (s.versions?.map(\.n).max() ?? 1), at: s.refreshedAt ?? s.builtAt, route: s.route, note: L("sheet.ui.versions.current"), current: true)
                    ForEach(files, id: \.n) { v in
                        Divider()
                        let meta = s.versions?.first { $0.n == v.n }
                        row(n: v.n, at: meta?.builtAt, route: meta?.route, note: meta?.note, current: false)
                    }
                    if files.isEmpty { Text(L("sheet.ui.versions.one")).font(PN.Font.caption).foregroundStyle(PN.C.text3).padding(.top, 6) }
                    if !note.isEmpty { Text(note).font(PN.Font.caption).foregroundStyle(PN.C.pending).padding(.top, 6) }
                }
                if let n = open, let f = files.first(where: { $0.n == n }) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L("sheet.ui.versions.viewing", ["n": "\(n)"])).font(PN.Font.section)
                            Spacer()
                            Button(L("common.close")) { open = nil }.buttonStyle(.pnTertiary)
                        }
                        MeetingSheetTab(doc: SheetDoc(path: f.path), onRefresh: {}, onEditBlocks: {}).disabled(true)
                    }
                }
            }
            .onAppear { if open == nil { open = initialOpen } }
        }
    }

    func show(_ n: Int) { open = n }

    private func row(n: Int, at: String?, route: String?, note: String?, current: Bool) -> some View {
        HStack(spacing: 10) {
            Text(L("sheet.ui.head.version", ["n": "\(n)"])).font(PN.Font.body.weight(.semibold))
            Text([at.map { SheetLabels.date($0) }, route.map { AIRoute.name($0) }, note].compactMap { $0 }.joined(separator: " · "))
                .font(PN.Font.caption).foregroundStyle(PN.C.text3)
            Spacer()
            if current { PagePill(text: L("sheet.ui.versions.live"), color: PN.C.turn) } else {
                Button(L("common.open")) { open = n }.buttonStyle(.pnTertiary)
                Button(L("sheet.ui.versions.use")) { use(n) }.buttonStyle(.pnSecondary)
            }
        }
        .padding(.vertical, 6)
    }

    /// Use this version for live: the current sheet is kept as the next version file, the chosen one becomes the
    /// sheet, the live files are derived from it again. Nothing is deleted.
    private func use(_ n: Int) {
        guard let f = SheetFiles.versions(of: doc.path).first(where: { $0.n == n }), let chosen = try? MeetingSheetIO.load(f.path),
              let cur = doc.sheet else { return }
        let next = (SheetFiles.versions(of: doc.path).map(\.n).max() ?? 0) + 1
        let keep = doc.base + ".sheet.v\(max(next, (cur.versions?.map(\.n).max() ?? 0) + 1)).json"
        // 0.10.0 (Meeting Sheet, hardening): byte copies, so the fields this app does not know stay in both files
        _ = cur; _ = chosen
        guard let curData = try? Data(contentsOf: URL(fileURLWithPath: doc.path)), let chosenData = try? Data(contentsOf: URL(fileURLWithPath: f.path)),
              (try? curData.write(to: URL(fileURLWithPath: keep), options: .atomic)) != nil,
              (try? chosenData.write(to: URL(fileURLWithPath: doc.path), options: .atomic)) != nil else { note = L("sheet.ui.err.save"); return }
        SheetCache.shared.forget(doc.path)
        doc.reload()
        SheetCLI.run("derive", args: ["--sheet", doc.path]) { r in
            self.note = SheetCLI.error(r).map { L("sheet.ui.versions.deriveFailed", ["e": $0]) } ?? L("sheet.ui.versions.used", ["n": "\(n)"])
        }
    }
}

// MARK: - Actions that start the sidecar

@MainActor
enum SheetActions {
    /// The request the sheet was built with (<base>.sheet.request.json), or a minimal one from the sheet.
    static func request(for doc: SheetDoc) -> [String: Any] {
        let p = doc.base + ".sheet.request.json"
        var r = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: p)))) as? [String: Any]) ?? [:]
        r["sheet"] = doc.path
        r["out"] = doc.base
        r["app_root"] = SheetCLI.appRoot
        if r["route"] == nil { r["route"] = doc.sheet?.route ?? SheetRoutes.preferred }
        return r
    }

    /// Refresh (all, or some blocks): a new version with the diff; edited facts stay. A call in Up next refreshes
    /// through SheetRunner (the same request, Google links, route rule as Prepare); anything else through the CLI.
    static func refresh(doc: SheetDoc, blocks: [String] = [], findAgain: String? = nil, call: StartCallModel? = nil) {
        let m = call ?? UpNext.shared.items.first { SheetFiles.path(for: $0) == doc.path }
        if let m, var pr = m.prepRequest() {
            pr.refreshBase = doc.base
            var o = SheetRunner.overrides[m.id] ?? [:]
            var opt = (o["options"] as? [String: Any]) ?? [:]
            opt["blocks"] = blocks.isEmpty ? nil : blocks
            opt["find_again"] = findAgain.map { [$0] }
            o["options"] = opt
            if o["route"] == nil, let r = doc.sheet?.route, SheetRoutes.ready(r) { o["route"] = r }
            SheetRunner.overrides[m.id] = o
            if let e = PrepRunner.shared.start(pr) { doc.note = e; return }
            SheetJobs.shared.follow(kind: "refresh", call: m)
            return
        }
        var r = request(for: doc)
        var o = (r["options"] as? [String: Any]) ?? [:]
        if !blocks.isEmpty { o["blocks"] = blocks }
        if let g = findAgain { o["find_again"] = [g] }
        r["options"] = o
        SheetJobs.shared.start(kind: "refresh", request: r, call: call, title: doc.sheet?.title ?? "")
    }
}
