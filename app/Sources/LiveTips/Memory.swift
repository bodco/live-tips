import AppKit
import SwiftUI
import LiveTipsCore

/// Pacenote 0.8 (F6, idea 05): "what did we agree about the export?" over the transcripts of ONE project. The
/// project is always chosen by the PM (never guessed); the answer is 1-2 sentences, a quote and the moment.
@MainActor
enum MemoryWindow {
    static var window: NSWindow?
    static func show(project: String? = nil) {
        guard ModuleGate.allow("search") else { return }            // 0.18.0 (B3)
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: Localized { MemoryView(initial: project).frame(minWidth: 560, minHeight: 420) }))
            w.setContentSize(NSSize(width: 640, height: 520))      // 0.8.7 (A6)
            w.tabbingMode = .disallowed      // 0.8.7 (A1): never tabs
            w.styleMask.insert(.resizable)
            w.isReleasedWhenClosed = false
            window = w
        }
        window?.title = L("memory.title")
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MemoryView: View {
    var initial: String?
    @State private var target = ""           // the folder of the project or workspace
    @State private var q = ""
    @State private var busy = false
    @State private var answer: [String: Any] = [:]
    @State private var error = ""
    @AppStorage("memoryRecent") private var recent = ""     // 0.8.7 (A6): the last 3 questions, joined by "\n"

    private var targets: [(String, String)] {
        let reg = ProjectRegistry.load(from: AppPaths.projects)
        return reg.projects.filter { $0.status != "archived" && !$0.root.isEmpty }.map { ($0.root, $0.name) } + reg.workspaces.map { ($0.root, $0.name) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(L("memory.project"), selection: $target) {
                Text(L("memory.chooseProject")).tag("")
                ForEach(targets, id: \.0) { t in Text(t.1).tag(t.0) }
            }
            HStack {
                TextField("", text: $q, prompt: Text(L("memory.prompt"))).textFieldStyle(.roundedBorder).onSubmit { ask() }
                Button(L("memory.ask")) { ask() }.buttonStyle(.pnPrimary).disabled(target.isEmpty || q.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
            let rq = recent.split(separator: "\n").map(String.init).prefix(3)
            if !rq.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(rq), id: \.self) { x in Button(x) { q = x; ask() }.buttonStyle(.pnTertiary).lineLimit(1) }
                }
            }
            Text(L("memory.note")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            if busy { HStack(spacing: 8) { PNSpinner(size: 16); Text(L("memory.searching")).foregroundStyle(PN.C.text2) } }
            if !error.isEmpty { Text(error).font(PN.Font.caption).foregroundStyle(PN.C.danger) }
            if !answer.isEmpty { result }
            Spacer()
        }
        .padding(20)
        .background(PN.C.bg)
        .onAppear {
            if let i = initial { target = i } else if target.isEmpty {
                // 0.8.7 (A6): the project of the last call is chosen in advance
                let reg = ProjectRegistry.load(from: AppPaths.projects)
                if let last = CallStats.calls().max(by: { $0.start < $1.start }) {
                    let k = CallStats.key(last)
                    target = reg.projects.first { $0.slug == k }?.root ?? reg.workspaces.first { "workspace:" + $0.name == k }?.root ?? ""
                }
            }
        }
    }

    @ViewBuilder private var result: some View {
        let found = (answer["found"] as? Bool) ?? false
        let file = answer["file"] as? String ?? "", t = answer["t"] as? String ?? ""
        VStack(alignment: .leading, spacing: 8) {
            Text(found ? (answer["answer"] as? String ?? "") : L("memory.notFound")).font(PN.Font.body).foregroundStyle(PN.C.text)
                .fixedSize(horizontal: false, vertical: true)
            if found, let quote = answer["quote"] as? String, !quote.isEmpty {
                Text("“" + quote + "”").font(PN.Font.body.italic()).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
            }
            if found && !file.isEmpty {
                HStack(spacing: 8) {
                    Text([answer["title"] as? String ?? "", answer["date"] as? String ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    Spacer()
                    if !t.isEmpty { Button(L("memory.jump", ["t": String(t.prefix(5))])) { TranscriptWindow.show(file: file, at: t) }.buttonStyle(.pnSecondary) }
                    Button(L("call.page.open")) { CallPageWindow.show(file: file) }.buttonStyle(.pnTertiary)
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.m))
    }

    private func ask() {
        guard !target.isEmpty, !q.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        busy = true; error = ""; answer = [:]
        UsageLog.log("search_calls")
        let qq = q.trimmingCharacters(in: .whitespaces)
        recent = ([qq] + recent.split(separator: "\n").map(String.init).filter { $0 != qq }).prefix(3).joined(separator: "\n")
        let c = AppConfig.load(from: AppPaths.config)
        let appRoot = c.effectiveAppRoot(appSupport: AppPaths.support.path)
        let lt = (appRoot as NSString).appendingPathComponent("bin/lt")
        let t0 = Date()      // S5: perf search, the question to its answer
        PyTool.run("memory", ["--root", target, "--q", q, "--lt", c.engine.python, lt, "--model", c.models.classify, "--lang", L10n.lang]) { r in
            busy = false
            let ok = (r["ok"] as? Bool) == true
            let ms = Int(Date().timeIntervalSince(t0) * 1000), code = Analytics.errorCode(message: r["error"] as? String ?? "")
            AnalyticsTracker.onMain {
                AnalyticsTracker.shared.perf("search", ms: ms, ok: ok)
                if !ok { AnalyticsTracker.shared.error("ai", code) }
            }
            if ok { answer = r } else { error = L("memory.failed", ["err": r["error"] as? String ?? ""]) }
        }
    }
}

// MARK: - Series

/// Pacenote 0.8 (F6, idea 06): a regular meeting (same project, same title) as one page: what changed since last
/// time, the decisions of every call, the series' commitments and the questions that stay open call after call.
@MainActor
enum SeriesWindow {
    static func show(record: CallHistory.Record) {
        guard ModuleGate.allow("series") else { return }            // 0.18.0 (B3)
        UsageLog.log("series_opened"); HomeNav.shared.open(.series(record.file))
    }   // 0.8.7 (A2)

    /// Questions open at the end of the latest calls, how many calls in a row and since when (newest call first).
    static func lingering(_ calls: [CallHistory.Record]) -> [(text: String, calls: Int, since: Date)] {
        guard let latest = calls.first, let o = CallOutcome.read(transcript: latest.file) else { return [] }
        return o.openQuestions.map { q in
            var n = 1, since = latest.start
            for c in calls.dropFirst() {
                guard let oo = CallOutcome.read(transcript: c.file), oo.openQuestions.contains(where: { CommitmentRegister.similar($0, q, share: 0.5) }) else { break }
                n += 1; since = c.start
            }
            return (text: q, calls: n, since: since)
        }
    }
}

/// 0.25 (R4, board SR-Series): the bar with the next call, the title block, then two columns: what changed since last
/// time, the open commitments and the questions that stay open; the decisions call by call and the decision register.
struct SeriesView: View {
    let record: CallHistory.Record
    @ObservedObject var register = Register.shared
    @Environment(\.pnTheme) private var t
    @State private var allCalls = false

    private struct SinceRow: Identifiable { let id = UUID(); let kind: String; let text: String }

    var body: some View {
        Group {
        let calls = CallPageView.series(of: record)          // newest first
        let df = CallPageView.fmt("EEEdMMM")
        let folder = (record.file as NSString).deletingLastPathComponent
        let key = EditLog.seriesKey(record.title)
        let items = register.items(in: folder).filter { $0.series.split(separator: "|", maxSplits: 1).last.map(String.init) == key && $0.status != "dropped" }
        let latest = calls.first, prev = calls.dropFirst().first
        let newKey = latest.map { CommitmentRegister.callKey($0.file) } ?? ""
        let open = items.filter { $0.status == "open" }
        let since: [SinceRow] = {
            guard let l = latest else { return [] }
            var out = (CallOutcome.read(transcript: l.file)?.decisions ?? []).map { SinceRow(kind: "decided", text: $0) }
            if let p = prev {
                out += items.filter { $0.status == "done" && ($0.doneAt.isEmpty ? false : (CommitmentRegister.iso($0.doneAt) ?? .distantPast) > p.start) }
                    .map { SinceRow(kind: "closed", text: $0.text + ($0.mine ? "" : " (" + $0.owner + ")")) }
            }
            out += open.filter { CommitmentRegister.callKey($0.call) == newKey }.map { SinceRow(kind: "new", text: ($0.mine ? "" : $0.owner + ": ") + $0.text) }
            out += open.filter { CommitmentRegister.callKey($0.call) != newKey }.map { SinceRow(kind: "still", text: $0.text + ($0.mine ? " (" + L("series.you") + ")" : " (" + $0.owner + ")")) }
            return out
        }()
        let lingering = SeriesWindow.lingering(calls)
        let reg = NotionAutoAdd.active(PyTool.project(of: record.file).project)
        let next = CalendarService.shared.events.first { $0.start > Date() && EditLog.seriesKey($0.title) == key }
        VStack(spacing: 0) {
            PageBackBar(crumb: L("series.crumb", ["project": record.project])) {
                if let n = next { Text(t.caps ? L("series.next", ["date": df.string(from: n.start)]).uppercased() : L("series.next", ["date": df.string(from: n.start)]))
                    .font(t.homeMono(12, .semibold)).foregroundStyle(PN.C.text2) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    PageTitleBlock(meta: L("series.meta", ["n": "\(calls.count)", "project": record.project, "date": calls.last.map { df.string(from: $0.start) } ?? ""]),
                                   title: record.title) {
                        Text(L("series.explain")).font(t.homeText(14)).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
                    }
                    PageColumns {
                        VStack(alignment: .leading, spacing: 26) {
                            VStack(alignment: .leading, spacing: 0) {
                                PageSectionHead(title: L("series.sinceLast"),
                                                count: (prev.map { df.string(from: $0.start) + " → " } ?? "") + (latest.map { df.string(from: $0.start) } ?? ""))
                                if since.isEmpty { none }
                                ForEach(since) { r in sinceRow(r) }
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                PageSectionHead(title: L("series.commitments"), count: open.isEmpty ? "" : L("page.tasks.open", ["n": "\(open.count)"]), warn: !open.isEmpty)
                                if open.isEmpty { none }
                                ForEach(open.sorted { ($0.mine ? 0 : 1, $0.created) < ($1.mine ? 0 : 1, $1.created) }) { c in commitRow(c, calls: calls, newKey: newKey, df: df) }
                            }
                            if !lingering.isEmpty {
                                VStack(alignment: .leading, spacing: 0) {
                                    PageSectionHead(title: L("series.lingering"), count: "\(lingering.count)")
                                    ForEach(Array(lingering.enumerated()), id: \.offset) { _, q in
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(q.text).font(t.homeText(16)).foregroundStyle(PN.C.text).fixedSize(horizontal: false, vertical: true)
                                            Text(q.calls > 1 ? L("series.age.openFor", ["n": "\(q.calls)", "date": df.string(from: q.since)]) : L("series.age.new", ["date": df.string(from: q.since)]))
                                                .font(t.homeMono(12)).foregroundStyle(PN.C.text3)
                                        }
                                        .pageRow()
                                    }
                                }
                            }
                        }
                    } right: {
                        VStack(alignment: .leading, spacing: 26) {
                            VStack(alignment: .leading, spacing: 0) {
                                PageSectionHead(title: L("series.timeline"))
                                ForEach(Array(calls.prefix(allCalls ? calls.count : 5).enumerated()), id: \.element.id) { i, c in timelineRow(c, first: i == 0, df: df) }
                                if calls.count > 5 && !allCalls {
                                    HomeLink(L("ntask.showAll", ["n": "\(calls.count)"])) { allCalls = true }.padding(.top, 10)
                                }
                            }
                            if !reg.isEmpty {
                                VStack(alignment: .leading, spacing: 0) {
                                    PageSectionHead(title: L("series.register"), count: L("series.regActive", ["n": "\(reg.count)"])) {
                                        HomeLink(L("page.tasks.openTracker")) { HomeNav.shared.open(.tracker) }
                                    }
                                    ForEach(Array(reg.prefix(10).enumerated()), id: \.offset) { _, d in
                                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                                            Text(d.title).font(t.homeText(16, .semibold)).foregroundStyle(PN.C.text).fixedSize(horizontal: false, vertical: true)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            Text(d.date.isEmpty ? "" : L("series.sinceDate", ["date": d.date])).font(t.homeMono(12)).foregroundStyle(PN.C.text3).fixedSize()
                                        }
                                        .pageRow()
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, PageMetrics.side).padding(.top, 20).padding(.bottom, 36)
                    .overlay(alignment: .top) { Rectangle().fill(PN.C.rule).frame(height: 1) }
                }
                .environment(\.pageFlat, true)
                .environment(\.pageWide, true)
            }
        }
        .background(PN.C.bg)
    }
        .trackScreen("series")
    }

    private var none: some View { Text(L("page.tasks.none")).font(t.homeText(15)).foregroundStyle(PN.C.text3).pageRow() }

    /// "Decided", "Closed" (struck), "New", "Still open" (on the not-ready plate) in a 78 pt column, then the text.
    private func sinceRow(_ r: SinceRow) -> some View {
        let kind: HomeTag = r.kind == "closed" ? .ready : r.kind == "new" ? .answer : r.kind == "still" ? .notReady : .neutral
        let plate = kind.plate(t)
        let tag = L("series.tag." + r.kind)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(t.caps ? tag.uppercased() : tag).font(t.homeMono(11, .semibold))
                .foregroundStyle(r.kind == "decided" ? PN.C.text : kind.text(t))
                .padding(.horizontal, plate == nil ? 0 : 5).background(plate ?? .clear)
                .frame(width: 78, alignment: .leading)
            Text(r.text).font(t.homeText(16)).foregroundStyle(r.kind == "closed" ? PN.C.text3 : PN.C.text).strikethrough(r.kind == "closed")
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .pageRow()
    }

    /// Who, what with how long it is open, and the date of the call where it was promised (a link to it).
    private func commitRow(_ c: Commitment, calls: [CallHistory.Record], newKey: String, df: DateFormatter) -> some View {
        let made = c.createdDate ?? Date()
        let n = calls.filter { $0.start >= made.addingTimeInterval(-3600) }.count
        let fresh = CommitmentRegister.callKey(c.call) == newKey
        let callRec = calls.first { CommitmentRegister.callKey($0.file) == CommitmentRegister.callKey(c.call) }
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(c.mine ? L("series.you") : c.owner).font(t.homeText(15, .semibold)).foregroundStyle(PN.C.text).lineLimit(1).frame(width: 96, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.text).font(t.homeText(16)).foregroundStyle(PN.C.text).fixedSize(horizontal: false, vertical: true)
                Text(fresh || n <= 1 ? L("series.age.new", ["date": df.string(from: made)]) : L("series.age.openFor", ["n": "\(n)", "date": df.string(from: made)]))
                    .font(t.homeMono(12)).foregroundStyle(fresh || n <= 1 ? PN.C.text3 : PN.C.notreadyText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let r = callRec {
                let day = CallPageView.fmt("dMMM").string(from: r.start)
                Button { CallPageWindow.show(file: r.file) } label: {
                    Text(day).font(t.homeMono(12, .semibold)).foregroundStyle(PN.C.accent).fixedSize().contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(L("page.mn.jump"))
            }
        }
        .pageRow()
    }

    /// One call of the series on the line: a square on the line (filled for the latest), the date, length and count,
    /// the decisions.
    private func timelineRow(_ c: CallHistory.Record, first: Bool, df: DateFormatter) -> some View {
        let d = CallOutcome.read(transcript: c.file)?.decisions ?? []
        let mins = c.minutes.map { L("call.page.minutes", ["n": "\(max(1, Int($0.rounded())))"]) } ?? ""
        let meta = [mins, d.isEmpty ? "" : L("series.nDecisions", ["n": "\(d.count)"])].filter { !$0.isEmpty }.joined(separator: " · ")
        return HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: t.statusSquare ? 0 : 6).fill(first ? PN.C.accent : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: t.statusSquare ? 0 : 6).strokeBorder(PN.C.ruleStrong, lineWidth: 1.5))
                    .frame(width: 12, height: 12)
                Rectangle().fill(PN.C.rule).frame(width: 2).frame(maxHeight: .infinity)
            }
            .frame(width: 24).padding(.top, 4).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Button { CallPageWindow.show(file: c.file) } label: {
                        Text(t.cased(df.string(from: c.start))).font(t.homeDisplay(20, t.titleWeight)).foregroundStyle(PN.C.text)
                    }
                    .buttonStyle(.plain)
                    Text(meta).font(t.homeMono(12)).foregroundStyle(PN.C.text3)
                }
                if d.isEmpty { Text(L("series.noDecisions")).font(t.homeText(15)).foregroundStyle(PN.C.text3) }
                ForEach(d, id: \.self) { x in Text(x).font(t.homeText(15)).foregroundStyle(PN.C.text).fixedSize(horizontal: false, vertical: true) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 12).padding(.bottom, 10)
        .overlay(alignment: .top) { Rectangle().fill(PN.C.rule).frame(height: 1) }
    }
}
