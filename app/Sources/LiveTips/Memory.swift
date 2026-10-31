import AppKit
import SwiftUI
import LiveTipsCore

/// Pacenote 0.8 (F6, idea 05): "what did we agree about the export?" over the transcripts of ONE project. The
/// project is always chosen by the PM (never guessed); the answer is 1-2 sentences, a quote and the moment.
@MainActor
enum MemoryWindow {
    static var window: NSWindow?
    static func show(project: String? = nil) {
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
            if busy { HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L("memory.searching")).foregroundStyle(PN.C.text2) } }
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
        PyTool.run("memory", ["--root", target, "--q", q, "--lt", c.engine.python, lt, "--model", c.models.classify, "--lang", L10n.lang]) { r in
            busy = false
            if (r["ok"] as? Bool) == true { answer = r } else { error = L("memory.failed", ["err": r["error"] as? String ?? ""]) }
        }
    }
}

// MARK: - Series

/// Pacenote 0.8 (F6, idea 06): a regular meeting (same project, same title) as one page: what changed since last
/// time, the decisions of every call, the series' commitments and the questions that stay open call after call.
@MainActor
enum SeriesWindow {
    static func show(record: CallHistory.Record) { UsageLog.log("series_opened"); HomeNav.shared.open(.series(record.file)) }   // 0.8.7 (A2)

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

struct SeriesView: View {
    let record: CallHistory.Record
    @ObservedObject var register = Register.shared

    var body: some View {
        let calls = CallPageView.series(of: record)
        let df = CallPageView.fmt("EEEdMMM")
        let folder = (record.file as NSString).deletingLastPathComponent
        let key = EditLog.seriesKey(record.title)
        let items = register.items(in: folder).filter { $0.series.split(separator: "|", maxSplits: 1).last.map(String.init) == key && $0.status != "dropped" }
        let latest = calls.first, prev = calls.dropFirst().first
        let sinceLast: [String] = {
            guard let l = latest else { return [] }
            var out = (CallOutcome.read(transcript: l.file)?.decisions ?? []).map { L("series.decided", ["text": $0]) }
            if let p = prev {
                out += items.filter { $0.status == "done" && ($0.doneAt.isEmpty ? false : (CommitmentRegister.iso($0.doneAt) ?? .distantPast) > p.start) }
                    .map { L("series.closed", ["text": $0.text]) }
            }
            // 0.8.7 (D1): new open items are marked "new" in Open commitments, not repeated here
            return out
        }()
        let lingering = SeriesWindow.lingering(calls)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.title).font(PN.Font.title).foregroundStyle(PN.C.text)
                    Text(L("series.sub", ["n": "\(calls.count)", "project": record.project])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                }
                block(L("series.sinceLast"), sinceLast)
                if !lingering.isEmpty {
                    block(L("series.lingering"), lingering.filter { $0.calls > 1 }.map { L("series.openFor", ["text": $0.text, "n": "\($0.calls)", "since": df.string(from: $0.since)]) }
                          + lingering.filter { $0.calls == 1 }.map { $0.text })
                }
                commitmentsByOwner(items.filter { $0.status == "open" }, newKey: latest.map { CommitmentRegister.callKey($0.file) } ?? "")
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("series.timeline")).font(PN.Font.section).foregroundStyle(PN.C.text)
                    ForEach(calls) { c in
                        let d = CallOutcome.read(transcript: c.file)?.decisions ?? []
                        VStack(alignment: .leading, spacing: 3) {
                            Button { CallPageWindow.show(file: c.file) } label: {
                                Text(df.string(from: c.start)).font(PN.Font.body.weight(.semibold)).foregroundStyle(PN.C.accent)
                            }.buttonStyle(.plain)
                            if d.isEmpty { Text(L("series.noDecisions")).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
                            ForEach(d, id: \.self) { x in Text("• " + x).font(PN.Font.body).foregroundStyle(PN.C.text).fixedSize(horizontal: false, vertical: true) }
                        }
                    }
                }
            }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(PN.C.bg)
    }

    /// 0.8.7 (D2): open commitments grouped by owner (Me first, then people A-Z), the name once per group;
    /// items from the latest call carry a "new" tag.
    @ViewBuilder private func commitmentsByOwner(_ list: [Commitment], newKey: String) -> some View {
        if !list.isEmpty {
            let owners = Array(Set(list.filter { !$0.mine }.map { $0.owner.isEmpty ? "?" : $0.owner })).sorted { $0.lowercased() < $1.lowercased() }
            let groups: [(String, [Commitment])] = (list.contains { $0.mine } ? [(L("series.me"), list.filter { $0.mine })] : [])
                + owners.map { o in (o, list.filter { !$0.mine && ($0.owner.isEmpty ? "?" : $0.owner) == o }) }
            VStack(alignment: .leading, spacing: 8) {
                Text(L("series.commitments")).font(PN.Font.section).foregroundStyle(PN.C.text)
                ForEach(groups, id: \.0) { g in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(g.0).font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.text3)
                        ForEach(g.1) { c in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("• " + c.text + (c.due.isEmpty ? "" : " (" + Register.dueText(c.due) + ")"))
                                    .font(PN.Font.body).foregroundStyle(PN.C.text).fixedSize(horizontal: false, vertical: true)
                                if CommitmentRegister.callKey(c.call) == newKey {
                                    Text(L("series.newTag")).font(PN.Font.caption).padding(.horizontal, 5)
                                        .background(Capsule().fill(PN.C.accent.opacity(0.15))).foregroundStyle(PN.C.accent)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func block(_ title: String, _ rows: [String]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(PN.Font.section).foregroundStyle(PN.C.text)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    Text("• " + r).font(PN.Font.body).foregroundStyle(PN.C.text).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
