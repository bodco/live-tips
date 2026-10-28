import AppKit
import SwiftUI
import LiveTipsCore

/// Pacenote 0.8.6 (F6, idea 05): "what did we agree about the export?" over the transcripts of ONE project. The
/// project is always chosen by the PM (never guessed); the answer is 1-2 sentences, a quote and the moment.
@MainActor
enum MemoryWindow {
    static var window: NSWindow?
    static func show(project: String? = nil) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: Localized { MemoryView(initial: project).frame(minWidth: 560, minHeight: 420) }))
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
            Text(L("memory.note")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            if busy { HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L("memory.searching")).foregroundStyle(PN.C.text2) } }
            if !error.isEmpty { Text(error).font(PN.Font.caption).foregroundStyle(PN.C.danger) }
            if !answer.isEmpty { result }
            Spacer()
        }
        .padding(20)
        .background(PN.C.bg)
        .onAppear { if let i = initial { target = i } }
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

/// Pacenote 0.8.6 (F6, idea 06): a regular meeting (same project, same title) as one page: what changed since last
/// time, the decisions of every call, the series' commitments and the questions that stay open call after call.
@MainActor
enum SeriesWindow {
    static func show(record: CallHistory.Record) {
        let w = NSWindow(contentViewController: NSHostingController(rootView: Localized { SeriesView(record: record).frame(minWidth: 600, minHeight: 560) }))
        w.styleMask.insert(.resizable)
        w.isReleasedWhenClosed = false
        w.title = L("series.title", ["title": record.title])
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

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
        let df = DateFormatter(); df.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US"); df.setLocalizedDateFormatFromTemplate("EEEdMMM")
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
            out += items.filter { CommitmentRegister.callKey($0.call) == CommitmentRegister.callKey(l.file) && $0.status == "open" }
                .map { L("series.new", ["text": $0.mine ? $0.text : $0.owner + ": " + $0.text]) }
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
                block(L("series.commitments"), items.filter { $0.status == "open" }.map { ($0.mine ? "" : $0.owner + ": ") + $0.text + ($0.due.isEmpty ? "" : " (" + $0.due + ")") })
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
