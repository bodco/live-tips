import AppKit
import SwiftUI
import LiveTipsCore

// 0.17.0 (server 0.7.0, D40, B6b contract 9 blocks 5-6): the shared context of an organization project beside its card
// on the project page in Settings > Projects: current state, the map of sources, the file index and the history with
// Restore. After a call with decisions or risks the call page offers "Update the project state?" with the diff before
// anything goes. Rules: LiveTipsCore/OrgContext.swift. The prep does not read any of this yet (SEC-01 first, spec 5.5).

@MainActor
final class OrgContextStore: ObservableObject {
    static let shared = OrgContextStore()
    @Published private(set) var states: [String: OrgContext.State] = [:]
    @Published private(set) var sources: [String: [OrgContext.Source]] = [:]
    @Published private(set) var files: [String: [OrgContext.File]] = [:]
    @Published private(set) var history: [String: [OrgContext.Change]] = [:]
    @Published private(set) var problems: [String: String] = [:]      // "<orgProjectID>|<part>" -> words
    @Published private(set) var indexing: [String: String] = [:]      // orgProjectID -> progress line

    func base(_ p: Project) -> String { OrgCardStore.shared.path(p) }
    private func key(_ p: Project, _ part: String) -> String { p.orgProjectID + "|" + part }
    func problem(_ p: Project, _ part: String) -> String? { problems[key(p, part)] }

    private func get(_ p: Project, _ part: String, _ path: String) async -> Data? {
        guard p.linkedToOrgProject, PacenoteAccount.shared.signedIn else { return nil }
        do {
            let (d, c) = try await PacenoteAccount.shared.api("GET", path)
            guard c == 200 else { problems[key(p, part)] = OrgCardStore.problemText(c, d); return nil }
            problems[key(p, part)] = nil
            return d
        } catch { problems[key(p, part)] = error.localizedDescription; return nil }
    }

    // MARK: state

    @discardableResult
    func loadState(_ p: Project) async -> OrgContext.State? {
        guard let d = await get(p, "state", base(p) + "/state"), let s = OrgContext.state(d) else { return nil }
        states[p.orgProjectID] = s
        return s
    }

    enum StateResult { case saved(OrgContext.State), newer(OrgContext.State?), failed(String) }

    func putState(_ p: Project, from: OrgContext.State, body: String) async -> StateResult {
        guard OrgContext.fits(body) else { return .failed(L("orgctx.state.tooLong")) }
        do {
            let (d, c) = try await PacenoteAccount.shared.api("PUT", base(p) + "/state", body: OrgContext.stateBody(body),
                                                              headers: OrgContext.stateHeaders(from))
            switch OrgContext.outcome(status: c, problem: PacenoteServer.problem(d, status: c)) {
            case .saved:
                let s = OrgContext.state(d) ?? OrgContext.State(body: body, version: from.version)
                states[p.orgProjectID] = s
                UsageLog.log("org_state_saved", ["bytes": body.utf8.count])
                await loadHistory(p)      // 0.17.1: the history under it shows the change at once
                return .saved(s)
            case .newer: return .newer(await loadState(p))
            case .tooLong: return .failed(L("orgctx.state.tooLong"))
            case .readOnly: return .failed(L("orgcard.err.readOnly"))
            case .gone: return .failed(L("orgcard.err.gone"))
            case .plan: return .failed(L("orgcard.err.plan"))
            case .failed(let e): return .failed(L("orgcard.err.other", ["e": e]))
            }
        } catch { return .failed(error.localizedDescription) }
    }

    // MARK: sources

    func loadSources(_ p: Project) async {
        if let d = await get(p, "sources", base(p) + "/sources"), let s = OrgContext.sources(d) { sources[p.orgProjectID] = s }
    }

    /// nil when added (or it was there already), else the problem in words.
    func addSource(_ p: Project, input: String, title: String, note: String) async -> String? {
        guard let r = OrgContext.recognize(input) else { return L("orgctx.src.bad") }
        do {
            let (d, c) = try await PacenoteAccount.shared.api("POST", base(p) + "/sources",
                                                              body: OrgContext.sourceBody(kind: r.kind, ref: r.ref, title: title, note: note))
            guard c == 200 || c == 201 else { return c == 409 ? L("orgctx.src.full") : OrgCardStore.problemText(c, d) }
            await loadSources(p); await loadHistory(p)
            return nil
        } catch { return error.localizedDescription }
    }

    func removeSource(_ p: Project, _ s: OrgContext.Source) async -> String? {
        do {
            let (d, c) = try await PacenoteAccount.shared.api("DELETE", base(p) + "/sources/" + s.id)
            guard c == 204 || c == 404 else { return c == 403 ? L("orgctx.src.notYours") : OrgCardStore.problemText(c, d) }
            await loadSources(p); await loadHistory(p)
            return nil
        } catch { return error.localizedDescription }
    }

    // MARK: file index

    func loadFiles(_ p: Project) async {
        if let d = await get(p, "index", base(p) + "/index"), let f = OrgContext.files(d) { files[p.orgProjectID] = f }
    }

    /// Words, or meaning when the built-in embedding engine runs on this Mac (the query never leaves it as text then).
    func search(_ p: Project, _ text: String) async -> (results: [OrgContext.File], problem: String?) {
        let vector = await Self.embed(text)
        do {
            let (d, c) = try await PacenoteAccount.shared.api("POST", base(p) + "/index/search", body: OrgContext.searchBody(text: text, vector: vector))
            guard c == 200, let f = OrgContext.files(d) else { return ([], OrgCardStore.problemText(c, d)) }
            return (f, nil)
        } catch { return ([], error.localizedDescription) }
    }

    func removeFile(_ p: Project, _ f: OrgContext.File) async -> String? {
        do {
            let (d, c) = try await PacenoteAccount.shared.api("DELETE", OrgContext.indexPath(base(p), ref: f.ref))
            guard c == 204 || c == 404 else { return OrgCardStore.problemText(c, d) }
            await loadFiles(p)
            return nil
        } catch { return error.localizedDescription }
    }

    /// A bge-m3 vector from the built-in engine (127.0.0.1:11435), or nil when it is not running.
    nonisolated static func embed(_ text: String) async -> [Double]? {
        guard let url = URL(string: LocalAIService.builtinURL + "/api/embed") else { return nil }
        var r = URLRequest(url: url); r.httpMethod = "POST"; r.timeoutInterval = 20
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["model": "bge-m3", "input": String(text.prefix(4000))])
        guard let (d, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let v = (o["embeddings"] as? [[Double]])?.first, v.count == OrgContext.dimensions else { return nil }
        return v
    }

    /// Indexes the Drive files in the map of sources that this Mac's Google account can read: name, type, time, the
    /// first 600 characters of the text and a bge-m3 vector when the built-in engine runs. Returns a summary line.
    func indexDriveFiles(_ p: Project) async -> String {
        await loadSources(p)
        let wanted = (sources[p.orgProjectID] ?? []).filter { $0.kind == .driveFile }
        guard !wanted.isEmpty else { return L("orgctx.idx.noDrive") }
        guard let email = GoogleService.shared.accounts.first?.email else { return L("orgctx.idx.noGoogle") }
        var done = 0, skipped = 0, vectors = 0, lastCode = ""
        let t0 = Date()
        defer { indexing[p.orgProjectID] = nil }
        for (n, s) in wanted.enumerated() {
            indexing[p.orgProjectID] = L("orgctx.idx.progress", ["n": "\(n + 1)", "of": "\(wanted.count)"])
            do {
                let token = try await GoogleService.shared.accessToken(email)
                func req(_ u: String) -> URLRequest { var r = URLRequest(url: URL(string: u)!); r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization"); return r }
                let meta = "https://www.googleapis.com/drive/v3/files/\(s.ref)?fields=name,mimeType,modifiedTime&supportsAllDrives=true"
                let (md, mr) = try await URLSession.shared.data(for: req(meta))
                guard (mr as? HTTPURLResponse)?.statusCode == 200, let m = (try? JSONSerialization.jsonObject(with: md)) as? [String: Any] else { skipped += 1; continue }
                let name = (m["name"] as? String) ?? s.title, mime = (m["mimeType"] as? String) ?? ""
                var text = ""
                if GoogleDriveCopy.export(for: mime) != nil || mime.hasPrefix("text/") {
                    let (td, tr) = try await URLSession.shared.data(for: req(GoogleDriveCopy.downloadURL(id: s.ref, mimeType: mime)))
                    if (tr as? HTTPURLResponse)?.statusCode == 200 { text = String(decoding: td.prefix(200_000), as: UTF8.self) }
                }
                let desc = OrgContext.describe(text.isEmpty ? (s.note.isEmpty ? name : s.note) : text)
                let vec = await Self.embed(name + "\n" + desc)
                if vec != nil { vectors += 1 }
                let (d, c) = try await PacenoteAccount.shared.api("PUT", OrgContext.indexPath(base(p), ref: s.ref),
                                                                  body: OrgContext.fileBody(name: name, mime: mime, modified: OrgCard.parseDate(m["modifiedTime"]),
                                                                                            description: desc, embedding: vec))
                if c == 200 || c == 201 { done += 1 } else {
                    skipped += 1; problems[key(p, "index")] = OrgCardStore.problemText(c, d); lastCode = Analytics.errorCode(status: c)
                }
            } catch { skipped += 1; lastCode = Analytics.errorCode(error) }
        }
        await loadFiles(p)
        UsageLog.log("org_index_built", ["files": done, "skipped": skipped, "vectors": vectors])
        // S5: perf index_build for the whole run, error index with the last failure's code (never a file's name)
        AnalyticsTracker.shared.perf("index_build", ms: Int(Date().timeIntervalSince(t0) * 1000), provider: "drive", ok: done > 0 || skipped == 0, o: p.orgProjectOrg)
        if !lastCode.isEmpty { AnalyticsTracker.shared.error("index", lastCode, provider: "drive", o: p.orgProjectOrg) }
        return L("orgctx.idx.done", ["n": "\(done)", "skipped": "\(skipped)", "vectors": "\(vectors)"])
    }

    // MARK: history

    func loadHistory(_ p: Project) async {
        if let d = await get(p, "history", base(p) + "/history?limit=60"), let h = OrgContext.history(d) { history[p.orgProjectID] = h }
    }

    func restore(_ p: Project, _ ch: OrgContext.Change, old: Bool) async -> String? {
        do {
            let (d, c) = try await PacenoteAccount.shared.api("POST", base(p) + "/history/\(ch.id)/restore", body: OrgContext.restoreBody(old: old))
            guard c == 200 else { return OrgCardStore.problemText(c, d) }
            await loadHistory(p)
            switch ch.entity {
            case "state": await loadState(p)
            case "source": await loadSources(p)
            case "card": await OrgCardStore.shared.load(p)
            default: break
            }
            UsageLog.log("org_change_restored", ["entity": ch.entity])
            return nil
        } catch { return error.localizedDescription }
    }
}

extension OrgCard {
    static func parseDate(_ s: Any?) -> Date? {
        guard let s = s as? String else { return nil }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}

private func whenText(_ d: Date?) -> String { d?.formatted(date: .abbreviated, time: .shortened) ?? "" }

// MARK: the diff before sending

struct StateDiffView: View {
    let old: String, new: String
    var body: some View {
        let lines = OrgContext.compact(OrgContext.diff(old, new))
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                if lines.isEmpty { Text(L("orgctx.state.noChange")).foregroundStyle(PN.C.text3) }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    switch l {
                    case nil: Text("…").foregroundStyle(PN.C.text3)
                    case .same(let t)?: Text("  " + t).foregroundStyle(PN.C.text2)
                    case .added(let t)?: Text("+ " + t).foregroundStyle(PN.C.turn).frame(maxWidth: .infinity, alignment: .leading).background(PN.C.turn.opacity(0.08))
                    case .removed(let t)?: Text("- " + t).foregroundStyle(PN.C.danger).strikethrough().frame(maxWidth: .infinity, alignment: .leading).background(PN.C.danger.opacity(0.06))
                    }
                }
            }
            .font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The editor and the diff, then Send. Used from Settings and after a call.
struct StateEditSheet: View {
    let project: Project
    let start: OrgContext.State
    @State var draft: String
    let onDone: (Bool) -> Void
    @State private var reviewing = false
    @State private var busy = false
    @State private var note = ""
    @State private var from: OrgContext.State?

    var body: some View {
        let base = from ?? start
        VStack(alignment: .leading, spacing: 10) {
            Text(L("orgctx.state.head")).pnSection()
            Text(L("orgctx.state.sub", ["project": project.orgProjectName.isEmpty ? project.name : project.orgProjectName]))
                .font(PN.Font.caption).foregroundStyle(PN.C.text3)
            if reviewing {
                Text(L("orgctx.state.review")).font(PN.Font.caption).foregroundStyle(PN.C.text2)
                StateDiffView(old: base.body, new: draft).frame(minHeight: 260)
            } else {
                TextEditor(text: $draft).font(.system(size: 12, design: .monospaced)).frame(minHeight: 260)
                    .overlay(RoundedRectangle(cornerRadius: PN.Radius.s).stroke(PN.C.text3.opacity(0.3)))
            }
            HStack {
                let bytes = draft.utf8.count
                Text(L("orgctx.state.bytes", ["n": "\(bytes)", "max": "\(OrgContext.stateLimit)"]))
                    .font(PN.Font.caption).foregroundStyle(OrgContext.fits(draft) ? PN.C.text3 : PN.C.danger)
                if !note.isEmpty { Text(note).font(PN.Font.caption).foregroundStyle(PN.C.danger).lineLimit(2) }
                Spacer()
                if busy { PNSpinner(size: 16) }
                Button(L("common.cancel")) { onDone(false) }.buttonStyle(.pnTertiary).keyboardShortcut(.cancelAction)
                if reviewing {
                    Button(L("orgctx.state.edit")) { reviewing = false }.buttonStyle(.pnTertiary)
                    Button(L("orgctx.state.send")) { Task { await send(base) } }.buttonStyle(.pnSecondary)
                        .disabled(busy || draft == base.body || !OrgContext.fits(draft))
                } else {
                    Button(L("orgctx.state.reviewBtn")) { reviewing = true }.buttonStyle(.pnSecondary)
                        .disabled(draft == base.body || !OrgContext.fits(draft))
                }
            }
        }
        .padding(20).frame(width: 640, height: 520)
    }

    private func send(_ base: OrgContext.State) async {
        busy = true; defer { busy = false }
        switch await OrgContextStore.shared.putState(project, from: base, body: draft) {
        case .saved: onDone(true)
        case .newer(let s):
            // someone saved meanwhile: show their version under my text; nothing goes until I send again
            from = s; reviewing = true
            note = L("orgctx.state.newer", ["who": (s?.updatedByName).flatMap { $0.isEmpty ? nil : $0 } ?? "?"])
        case .failed(let e): note = e
        }
    }
}

// MARK: Settings > Projects > a linked project

struct OrgStateSection: View {
    let project: Project
    @ObservedObject private var store = OrgContextStore.shared
    @ObservedObject private var acct = PacenoteAccount.shared
    @State private var editing: OrgContext.State?
    @State private var saved = false

    var body: some View {
        Section {
            if let s = store.states[project.orgProjectID] {
                if s.body.isEmpty {
                    Text(L("orgctx.state.empty")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                } else {
                    Text(s.body).font(.system(size: 12, design: .monospaced)).foregroundStyle(PN.C.text2).lineLimit(12)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 8) {
                    if let at = s.updatedAt {
                        Text(L("orgcard.changedBy", ["who": s.updatedByID == acct.me?.userID.lowercased() ? L("orgcard.you") : (s.updatedByName.isEmpty ? "?" : s.updatedByName),
                                                     "when": whenText(at)])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    }
                    if saved { Text(L("orgcard.saved")).font(PN.Font.caption).foregroundStyle(PN.C.text2) }
                    Spacer()
                    Button(L("orgcard.reload")) { Task { await store.loadState(project) } }.buttonStyle(.pnTertiary)
                    Button(L("orgctx.state.editBtn")) { editing = s }.buttonStyle(.pnSecondary)
                }
            } else if let e = store.problem(project, "state") {
                Text(e).font(PN.Font.caption).foregroundStyle(PN.C.pending)
            } else {
                HStack(spacing: 8) { PNSpinner(size: 16); Text(L("orgcard.loading")).foregroundStyle(PN.C.text3) }
            }
        } header: { Text(L("orgctx.state.head")).settingsAnchor("pr.orgState") }
        .task(id: project.orgProjectID) { await store.loadState(project) }
        .sheet(item: Binding(get: { editing.map { IdentifiedState(s: $0) } }, set: { if $0 == nil { editing = nil } })) { e in
            StateEditSheet(project: project, start: e.s, draft: e.s.body) { ok in editing = nil; saved = ok }
        }
    }
}

struct IdentifiedState: Identifiable { let s: OrgContext.State; var id: String { s.version } }

struct OrgSourcesSection: View {
    let project: Project
    @ObservedObject private var store = OrgContextStore.shared
    @ObservedObject private var acct = PacenoteAccount.shared
    @State private var link = ""
    @State private var title = ""
    @State private var note = ""
    @State private var busy = false

    var body: some View {
        Section {
            let list = store.sources[project.orgProjectID] ?? []
            if list.isEmpty, store.problem(project, "sources") == nil {
                Text(L("orgctx.src.empty")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            ForEach(list) { s in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: icon(s.kind)).foregroundStyle(PN.C.text3)
                    VStack(alignment: .leading, spacing: 1) {
                        if let u = OrgContext.link(s) { Link(s.title.isEmpty ? s.ref : s.title, destination: u).lineLimit(1) }
                        else { Text(s.title.isEmpty ? s.ref : s.title).lineLimit(1) }
                        Text(L("orgctx.src.by", ["who": s.addedByID == acct.me?.userID.lowercased() ? L("orgcard.you") : (s.addedByName.isEmpty ? "?" : s.addedByName),
                                                 "when": s.addedAt?.formatted(date: .abbreviated, time: .omitted) ?? ""])
                             + (s.note.isEmpty ? "" : " · " + s.note))
                            .font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(1)
                    }
                    Spacer()
                    Button { Task { busy = true; note = await store.removeSource(project, s) ?? ""; busy = false } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.pnTertiary).help(L("orgctx.src.remove")).accessibilityLabel(L("orgctx.src.remove")).disabled(busy)
                }
            }
            HStack(spacing: 8) {
                TextField(L("orgctx.src.link"), text: $link, prompt: Text("https://drive.google.com/…"))
                TextField(L("orgctx.src.title"), text: $title).frame(maxWidth: 160)
                Button(L("orgctx.src.add")) {
                    Task {
                        busy = true; defer { busy = false }
                        if let e = await store.addSource(project, input: link, title: title, note: "") { note = e } else { link = ""; title = ""; note = "" }
                    }
                }
                .buttonStyle(.pnSecondary).disabled(busy || link.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !note.isEmpty || store.problem(project, "sources") != nil {
                Text(note.isEmpty ? store.problem(project, "sources") ?? "" : note).font(PN.Font.caption).foregroundStyle(PN.C.pending)
            }
            Text(L("orgctx.src.help")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
        } header: { Text(L("orgctx.src.head")).settingsAnchor("pr.orgSources") }
        .task(id: project.orgProjectID) { await store.loadSources(project) }
    }

    private func icon(_ k: OrgContext.SourceKind) -> String {
        switch k {
        case .driveFolder: return "folder"
        case .driveFile: return "doc"
        case .notionPage, .notionDB: return "n.square"
        case .url: return "globe"
        }
    }
}

struct OrgIndexSection: View {
    let project: Project
    @ObservedObject private var store = OrgContextStore.shared
    @State private var query = ""
    @State private var results: [OrgContext.File]?
    @State private var note = ""
    @State private var busy = false

    var body: some View {
        Section {
            let all = store.files[project.orgProjectID] ?? []
            HStack(spacing: 8) {
                TextField(L("orgctx.idx.search"), text: $query).onSubmit { find() }
                Button(L("orgctx.idx.find")) { find() }.buttonStyle(.pnTertiary).disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                if results != nil { Button(L("orgctx.idx.clear")) { results = nil; query = "" }.buttonStyle(.pnTertiary) }
            }
            let shown = results ?? all
            if shown.isEmpty {
                Text(results == nil ? L("orgctx.idx.empty") : L("orgctx.idx.none")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            ForEach(shown.prefix(40)) { f in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(f.name ?? f.ref).lineLimit(1)
                            if let sc = f.score { Text(String(format: "%.2f", sc)).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
                            if f.needsReindex { Text(L("orgctx.idx.again")).font(PN.Font.caption).foregroundStyle(PN.C.pending) }
                        }
                        if let d = f.description, !d.isEmpty { Text(d).font(PN.Font.caption).foregroundStyle(PN.C.text2).lineLimit(2) }
                        Text(L("orgctx.idx.by", ["who": f.indexedByName.isEmpty ? "?" : f.indexedByName, "when": whenText(f.indexedAt)]))
                            .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    }
                    Spacer()
                    Button { Task { busy = true; note = await store.removeFile(project, f) ?? ""; busy = false } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.pnTertiary).help(L("orgctx.idx.remove")).accessibilityLabel(L("orgctx.idx.remove")).disabled(busy)
                }
            }
            HStack(spacing: 8) {
                if let line = store.indexing[project.orgProjectID] { PNSpinner(size: 16); Text(line).font(PN.Font.caption).foregroundStyle(PN.C.text2) }
                else if !note.isEmpty { Text(note).font(PN.Font.caption).foregroundStyle(PN.C.text2).lineLimit(2) }
                Spacer()
                Button(L("orgctx.idx.build")) { Task { note = await store.indexDriveFiles(project) } }
                    .buttonStyle(.pnSecondary).help(L("orgctx.idx.build.help")).disabled(store.indexing[project.orgProjectID] != nil)
            }
            if let e = store.problem(project, "index") { Text(e).font(PN.Font.caption).foregroundStyle(PN.C.pending) }
        } header: { Text(L("orgctx.idx.head")).settingsAnchor("pr.orgIndex") }
        .task(id: project.orgProjectID) { await store.loadFiles(project) }
    }

    private func find() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        Task { let r = await store.search(project, q); results = r.results; note = r.problem ?? "" }
    }
}

struct OrgHistorySection: View {
    let project: Project
    @ObservedObject private var store = OrgContextStore.shared
    @State private var confirm: OrgContext.Change?
    @State private var note = ""

    var body: some View {
        Section {
            let list = store.history[project.orgProjectID] ?? []
            if list.isEmpty { Text(store.problem(project, "history") ?? L("orgctx.hist.empty")).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
            ForEach(list.prefix(30)) { c in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(line(c)).lineLimit(1)
                        let people = OrgCardStore.shared.cards[project.orgProjectID]?.members ?? []
                        let o = OrgContext.short(OrgContext.named(c.old, field: c.field, members: people)),
                            n = OrgContext.short(OrgContext.named(c.new, field: c.field, members: people))
                        if c.entity != "source", !(o.isEmpty && n.isEmpty) {
                            Text((o.isEmpty ? "∅" : o) + "  →  " + (n.isEmpty ? "∅" : n)).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(1)
                        }
                    }
                    Spacer()
                    if c.restorable { Button(L("orgctx.hist.restore")) { confirm = c }.buttonStyle(.pnTertiary).help(L("orgctx.hist.restore.help")) }
                }
            }
            if !note.isEmpty { Text(note).font(PN.Font.caption).foregroundStyle(PN.C.pending) }
            HStack { Spacer(); Button(L("orgcard.reload")) { Task { await store.loadHistory(project) } }.buttonStyle(.pnTertiary) }
        } header: { Text(L("orgctx.hist.head")).settingsAnchor("pr.orgHistory") }
        .task(id: project.orgProjectID) { await store.loadHistory(project) }
        .confirmationDialog(L("orgctx.hist.confirm"), isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button(L("orgctx.hist.restore")) { if let c = confirm { Task { note = await store.restore(project, c, old: true) ?? "" } } }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(confirm.map { L("orgctx.hist.confirmBody", ["what": line($0)]) } ?? "")
        }
    }

    private func line(_ c: OrgContext.Change) -> String {
        let what: String
        switch c.entity {
        case "card": what = L("orgctx.hist.card", ["field": L("orgcard.field." + c.field)])
        case "state": what = L("orgctx.hist.state")
        case "source": what = L("orgctx.hist.source", ["title": OrgContext.short(c.new ?? c.old, max: 50)])
        default: what = L("orgctx.hist.item")
        }
        return L("orgctx.hist.line", ["who": c.byName.isEmpty ? "?" : c.byName, "verb": L("orgctx.hist.verb." + OrgContext.verb(c)),
                                      "what": what, "when": whenText(c.at)])
    }
}

// MARK: after a call

/// The call page: "Update the project state?" after a call with decisions or risks in a project linked to an
/// organization project. Review opens the editor with this call's lines added and the diff before anything goes.
struct OrgStateUpdateLine: View {
    let file: String
    let decisions: [String]
    let risks: [String]
    @ObservedObject private var store = OrgContextStore.shared
    @AppStorage private var done: Bool
    @State private var sheet: IdentifiedState?
    @State private var suggestion = ""
    @State private var problem = ""

    init(file: String, decisions: [String], risks: [String]) {
        self.file = file; self.decisions = decisions; self.risks = risks
        _done = AppStorage(wrappedValue: false, "pn.orgStateOffer." + CommitmentRegister.callKey(file))
    }

    private var project: Project? {
        let p = PyTool.project(of: file).project
        return (p?.linkedToOrgProject ?? false) ? p : nil
    }

    var body: some View {
        if let p = project, !done, PacenoteAccount.shared.signedIn, !(decisions.isEmpty && risks.isEmpty) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil").foregroundStyle(PN.C.accent)
                Text(problem.isEmpty ? L("orgctx.offer", ["project": p.orgProjectName.isEmpty ? p.name : p.orgProjectName]) : problem)
                    .font(PN.Font.caption).foregroundStyle(problem.isEmpty ? PN.C.text2 : PN.C.pending)
                Spacer(minLength: 4)
                Button(L("orgctx.offer.review")) { Task { await review(p) } }.buttonStyle(.pnSecondary)
                Button(L("orgctx.offer.notNow")) { done = true }.buttonStyle(.pnTertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(PN.C.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: PN.Radius.m))
            .sheet(item: $sheet) { s in
                StateEditSheet(project: p, start: s.s, draft: suggestion) { ok in sheet = nil; if ok { done = true } }
            }
        }
    }

    private func review(_ p: Project) async {
        guard let s = await store.loadState(p) else { problem = store.problem(p, "state") ?? L("orgcard.err.gone"); return }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "MMM d"
        let day = CallHistory.shared.records.first { $0.file == file }?.start ?? Date()
        suggestion = OrgContext.suggest(current: s.body, day: f.string(from: day), decisions: decisions, risks: risks)
        problem = ""
        sheet = IdentifiedState(s: s)
    }
}
