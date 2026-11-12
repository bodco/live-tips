import AppKit
import LiveTipsCore
import SwiftUI

// 0.10.0 (Meeting Sheet, phase 4): the state of one preparation before the run, shared by Quick (S1a) and Expert
// (S1-S5): the meeting, the blocks, the sources with their access, the size and the route. It turns into the request
// of `python -m livetips_m0.sheet sources|candidates|size|build`. Nothing is taken without a tick, nothing is cut
// silently, the route is shown before the run and never switched without asking.

struct DraftBlock: Identifiable, Equatable {
    var type: String
    var title: String
    var visible = true
    var onlyIfData = false
    var method: String?
    var id: String { type }
}

struct DraftPerson: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var role = ""
    var company = ""
    var domain = ""
}

struct DraftSource: Identifiable, Equatable {
    var id: String = "u" + String(UUID().uuidString.prefix(8)).lowercased()
    var type: String
    var path: String?
    var uri: String?
    var title: String
    var text: String?
    var auto = false
    var why: [String] = []
    var checked = true
    var access = "pending"
    var reason: String?
    var fix: String?
    var tokens: Int?
    var deck = false
    var deckMinutes: Double?
    var deckQA: Double?
}

@MainActor
final class SheetDraft: ObservableObject {
    let model: StartCallModel
    @Published var mode: SheetMode = .quick
    @Published var step = 1
    @Published var presetID = "blank"
    @Published var presetSuggested = true
    @Published var blocks: [DraftBlock] = []
    @Published var sources: [DraftSource] = []
    @Published var candidates: [DraftSource] = []
    @Published var candidateNote = ""
    @Published var goal = ""
    @Published var special = ""
    @Published var language = "en"
    @Published var route = SheetRoutes.preferred
    @Published var remind = SheetPrefs.shared.remindMinutes
    @Published var withEvent = true
    @Published var ours: [DraftPerson] = []
    @Published var theirs: [DraftPerson] = []
    @Published var size: SizeReport?
    @Published var plan = "one"
    @Published var checking = false
    @Published var note = ""
    @Published var keptLink: Set<String> = []
    @Published var job: SheetJob?
    /// The series had a Quick setup before (Quick says "Same as last time"); false = first time in the series.
    @Published var remembered = false

    init(model: StartCallModel) {
        self.model = model
        let mem = SheetSeriesMemory.shared.lookup(model)
        let lib = SheetLibrary.shared
        presetID = mem?.preset ?? Self.suggestedPreset(model)
        presetSuggested = mem == nil
        remembered = mem != nil
        let preset = lib.preset(presetID)
        mode = mem.map { SheetMode(rawValue: $0.mode) } ?? SheetPrefs.shared.mode(for: model, preset: preset)
        if let r = mem?.route, !r.isEmpty { route = r }
        language = mem?.language ?? (model.language.hasPrefix("uk") && model.audience != "client" ? "uk" : "en")
        applyPreset(presetID)
        goal = Self.goalLine(model.cleanContext)
        ours = [DraftPerson(name: L("sheet.ui.you"))] + model.peopleTeam.filter { n in model.participants.contains { $0.caseInsensitiveCompare(n) == .orderedSame } }.map { DraftPerson(name: $0) }
        theirs = Self.theirPeople(model).map { DraftPerson(name: $0.name, company: $0.company ?? "", domain: $0.domain ?? "") }
        withEvent = model.calEventID != nil
        // The files and folders already added in Start call, and the call's text, are sources from the start.
        for f in model.folders {
            sources.append(DraftSource(type: StartCallModel.isDir(f) ? "folder_file" : "file", path: f, title: (f as NSString).lastPathComponent))
        }
        if let m = mem {
            for s in m.sources where !sources.contains(where: { $0.path == s["path"] && $0.uri == s["uri"] }) {
                sources.append(DraftSource(type: s["type"] ?? "file", path: s["path"], uri: s["uri"], title: s["title"] ?? (s["path"] ?? s["uri"] ?? ""), auto: true, why: [L("sheet.ui.why.lastTime")]))
            }
        }
        if model.callType == "presentation", let p = model.deck.path, !sources.contains(where: { $0.path == p }) {
            sources.append(DraftSource(type: "file", path: p, title: (p as NSString).lastPathComponent, deck: true,
                                       deckMinutes: Double(model.deck.talkMin), deckQA: model.deck.qaOn ? Double(model.deck.qaMin) : 0))
        }
    }

    // MARK: presets and blocks

    static func suggestedPreset(_ m: StartCallModel) -> String {
        let t = m.effectiveTitle.lowercased()
        if m.callType == "interview" { return "interview" }
        if m.callType == "presentation" { return "internal_presentation" }
        if t.contains("stand") || t.contains("daily") || t.contains("стендап") { return "standup" }
        if m.salesEnabled { return SheetFiles.earlier(for: m) == nil ? "sales_intro" : "repeat_call" }
        if m.audience == "client" { return "client_sync" }
        return "blank"
    }

    /// Their side: names from the call's participants that are not on the team, with the company of the project.
    struct TheirPerson { var name: String; var company: String?; var domain: String? }

    static func theirPeople(_ m: StartCallModel) -> [TheirPerson] {
        let team = Set(m.peopleTeam.map { $0.lowercased() })
        return m.participants.filter { !team.contains($0.lowercased()) }.map { n in
            let domain = n.contains("@") ? String(n.split(separator: "@").last ?? "") : nil
            return TheirPerson(name: n, company: m.project?.crmCompanyName.nilIfEmpty, domain: domain)
        }
    }

    static func goalLine(_ ctx: String) -> String {
        for l in ctx.split(separator: "\n") {
            let t = l.trimmingCharacters(in: .whitespaces)
            if let r = t.range(of: "^(goal|мета)\\s*:", options: [.regularExpression, .caseInsensitive]) { return String(t[r.upperBound...]).trimmingCharacters(in: .whitespaces) }
        }
        return ""
    }

    func applyPreset(_ id: String) {
        let lib = SheetLibrary.shared
        presetID = id
        let p = lib.preset(id) ?? SheetLibrary.fallback.last!
        blocks = p.blocks.map { t in
            DraftBlock(type: t, title: lib.title(t), visible: true, onlyIfData: ["signals", "tech_stack", "fit"].contains(t),
                       method: t == "qualification" ? (p.method ?? model.salesMethod.nilIfEmpty ?? "bant") : nil)
        }
    }

    var preset: SheetPresetInfo? { SheetLibrary.shared.preset(presetID) }

    // MARK: sources

    /// A pasted line: a link becomes a typed source (its access is checked at once), anything else a text source.
    func add(pasted raw: String) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if let u = URL(string: t), let host = u.host, u.scheme?.hasPrefix("http") == true {
            let type = Self.linkType(t)
            if !sources.contains(where: { $0.uri == t }) { sources.append(DraftSource(type: type, uri: t, title: host + u.path.prefix(40))) }
        } else {
            sources.append(DraftSource(type: "text", title: L("sheet.ui.src.pasted", ["n": "\(t.count)"]), text: t, access: "ok", tokens: max(1, t.count / 4)))
        }
        checkSources()
    }

    static func linkType(_ s: String) -> String {
        let l = s.lowercased()
        if l.contains("docs.google.com/document") { return "gdoc" }
        if l.contains("docs.google.com/spreadsheets") { return "gsheet" }
        if l.contains("docs.google.com/presentation") { return "gslides" }
        if l.contains("drive.google.com/file") || l.contains("drive.google.com/open") { return "drive_file" }
        if l.contains("notion.so") || l.contains("notion.site") { return "notion" }
        if l.contains("linkedin.com/") { return "linkedin" }
        return "web"
    }

    /// Files become sources; a folder lists its files as candidates (nothing is taken without a tick).
    func add(paths: [String]) {
        let dirs = paths.filter { StartCallModel.isDir($0) }
        if !dirs.isEmpty { loadCandidates(folders: dirs) }
        for p in paths where !StartCallModel.isDir(p) && !sources.contains(where: { $0.path == p }) {
            let isDeck = model.callType == "presentation" && ["pptx", "pdf", "key"].contains((p as NSString).pathExtension.lowercased()) && !sources.contains { $0.deck }
            sources.append(DraftSource(type: StartCallModel.isDir(p) ? "folder_file" : "file", path: p, title: (p as NSString).lastPathComponent, deck: isDeck))
        }
        checkSources()
    }

    func chooseFiles() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = true; p.allowsMultipleSelection = true
        p.message = L("call.pickMessage")
        if let r = model.root { p.directoryURL = URL(fileURLWithPath: r) }
        guard p.runModal() == .OK else { return }
        add(paths: p.urls.map(\.path))
    }

    /// Links typed into the goal or "Anything special today?" that are not sources yet: offered, never moved silently.
    var linksInText: [String] {
        let text = goal + "\n" + special + "\n" + model.cleanContext
        let found = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".,;()<>\"'")) }
            .filter { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
        var seen = Set<String>()
        return found.filter { l in seen.insert(l).inserted && !keptLink.contains(l) && !sources.contains { $0.uri == l } }
    }

    var hasLinkedIn: Bool { sources.contains { $0.type == "linkedin" || $0.type == "linkedin_manual" } }

    // MARK: the request

    func request(out: String?) -> [String: Any] {
        let f = ISO8601DateFormatter()
        var meeting: [String: Any] = ["start": f.string(from: model.callDate), "title": model.effectiveTitle, "tz": TimeZone.current.identifier]
        if withEvent, let e = model.calEventID { meeting["event_id"] = e }
        let person: (DraftPerson) -> [String: Any] = { p -> [String: Any] in
            var d: [String: Any] = ["name": p.name]
            if !p.role.isEmpty { d["role"] = p.role }
            if !p.company.isEmpty { d["company"] = p.company }
            if !p.domain.isEmpty { d["domain"] = p.domain }
            return d
        }
        let src: [[String: Any]] = sources.filter(\.checked).map { s -> [String: Any] in
            var d: [String: Any] = ["id": s.id, "type": s.type, "title": s.title, "auto": s.auto]
            if let p = s.path { d["path"] = p }
            if let u = s.uri { d["uri"] = u }
            if let t = s.text { d["text"] = t }
            if !s.why.isEmpty { d["why"] = s.why }
            if s.deck {
                var dk: [String: Any] = [:]
                if s.deckMinutes != nil || model.callType == "presentation" {
                    dk["minutes"] = s.deckMinutes ?? Double(model.deck.talkMin)
                    dk["qa_minutes"] = s.deckQA ?? (model.deck.qaOn ? Double(model.deck.qaMin) : 0)
                    dk["owners"] = Dictionary(uniqueKeysWithValues: model.deck.owners.map { (String($0.key), $0.value) })
                }
                d["deck"] = dk
            }
            return d
        }
        let blockList: [[String: Any]] = blocks.enumerated().map { i, b -> [String: Any] in
            var d: [String: Any] = ["type": b.type, "title": b.title, "visible": b.visible, "only_if_data": b.onlyIfData, "order": i]
            if let m = b.method { d["method"] = m }
            return d
        }
        let people: [String: Any] = ["ours": ours.filter { !$0.name.isEmpty }.map(person), "theirs": theirs.filter { !$0.name.isEmpty }.map(person)]
        let options: [String: Any] = ["plan": plan, "special": special, "remind_minutes": remind, "stale_months": SheetPrefs.shared.staleMonths,
                                      "use_project_folder": false, "sales": model.salesEnabled, "hiring_role": model.hiringRole]
        var r: [String: Any] = [
            "project": ["slug": model.project?.slug ?? model.workspace?.name.lowercased() ?? "", "root": model.root ?? ""],
            "meeting": meeting, "preset": presetID, "mode": mode.rawValue, "language": language, "route": route,
            "blocks": blockList,
            "sources": src, "focus": SheetPrefs.shared.focus, "goal": goal,
            "participants": people,
            "call_type": model.callType, "audience": model.audience, "app_root": SheetCLI.appRoot,
            "options": options, "plan": plan.isEmpty ? "one" : plan,
            "context": [model.cleanContext, special].filter { !$0.isEmpty }.joined(separator: "\n"),
            "use_project_folder": false, "folders": [String](),
        ]
        if let m = blocks.first(where: { $0.type == "qualification" })?.method { r["method"] = m }
        if let o = out { r["out"] = o }
        if let e = SheetFiles.earlier(for: model) { r["earlier_sheet"] = e }
        return r
    }

    // MARK: sidecar calls

    /// Access and size of every source, before any model (the same on every route).
    func checkSources() {
        checking = true
        SheetCLI.run("sources", request: request(out: nil)) { r in
            self.checking = false
            guard let list = r.json?["sources"] as? [[String: Any]] else {
                self.note = SheetCLI.error(r).map { L("sheet.ui.err.sources", ["e": $0]) } ?? ""
                self.localCheck()
                return
            }
            for o in list {
                guard let id = o["id"] as? String, let i = self.sources.firstIndex(where: { $0.id == id }) else { continue }
                self.sources[i].access = o["access"] as? String ?? self.sources[i].access
                self.sources[i].reason = o["access_reason"] as? String ?? o["reason"] as? String
                self.sources[i].fix = o["fix_action"] as? String
                self.sources[i].tokens = o["size_tokens"] as? Int ?? self.sources[i].tokens
                if let t = o["title"] as? String, !t.isEmpty { self.sources[i].title = t }
            }
            self.note = ""
        }
    }

    /// Without the sidecar: files on this Mac are readable, links wait for the check.
    private func localCheck() {
        for i in sources.indices where sources[i].access == "pending" {
            if let p = sources[i].path {
                let full = (p as NSString).expandingTildeInPath
                if FileManager.default.isReadableFile(atPath: full) {
                    sources[i].access = "ok"
                    let sz = (try? FileManager.default.attributesOfItem(atPath: full))?[.size] as? Int ?? 0
                    if !StartCallModel.isDir(full) { sources[i].tokens = max(1, sz / 4) }
                } else { sources[i].access = "denied"; sources[i].reason = L("sheet.ui.access.noFile") }
            }
        }
    }

    /// From the project folder: the candidates with why; nothing is taken without a tick.
    func loadCandidates(folders: [String] = []) {
        guard model.root != nil || !folders.isEmpty else { return }
        var req = request(out: nil)
        req["use_project_folder"] = folders.isEmpty
        req["folders"] = folders
        req["live"] = SheetFiles.liveFolder(model) ?? ""
        SheetCLI.run("candidates", request: req) { r in
            guard let list = r.json?["candidates"] as? [[String: Any]] else {
                self.candidateNote = SheetCLI.error(r).map { L("sheet.ui.err.candidates", ["e": $0]) } ?? ""
                return
            }
            self.candidates = list.map { o in
                DraftSource(id: o["id"] as? String ?? UUID().uuidString, type: o["type"] as? String ?? "folder_file", path: o["path"] as? String,
                            uri: o["uri"] as? String, title: o["title"] as? String ?? (o["path"] as? String ?? ""), auto: true,
                            why: o["why"] as? [String] ?? [], checked: o["suggested"] as? Bool ?? false, access: o["access"] as? String ?? "ok",
                            tokens: o["size_tokens"] as? Int)
            } + (folders.isEmpty ? [] : self.candidates)
            if let n = r.json?["total_files"] as? Int {
                self.candidateNote = L("sheet.ui.s3.folderCount", ["n": "\(n)", "k": "\(self.candidates.filter(\.checked).count)"])
            }
        }
    }

    func addTickedCandidates() {
        for c in candidates where c.checked && !sources.contains(where: { $0.id == c.id || ($0.path != nil && $0.path == c.path) }) { sources.append(c) }
        candidates.removeAll { $0.checked }
        checkSources()
    }

    /// The size against one pass of the chosen route; the sidecar counts tokens per file, the local sum is a fallback.
    func checkSize() {
        checking = true
        SheetCLI.run("size", request: request(out: nil)) { r in
            self.checking = false
            if let j = r.json, j["error"] == nil, let d = try? JSONSerialization.data(withJSONObject: (j["size_report"] as? [String: Any]) ?? j),
               let s = try? JSONDecoder().decode(SizeReport.self, from: d) {
                self.size = s
            } else {
                let total = self.sources.filter(\.checked).compactMap(\.tokens).reduce(0, +)
                let w = SheetRoutes.window(self.route), reserve = 12_000
                let st: SizeState = total > w - reserve ? .tooMuch : total > Int(Double(w - reserve) * 0.85) ? .near : .fits
                self.size = try? JSONDecoder().decode(SizeReport.self, from: JSONSerialization.data(withJSONObject: [
                    "route": self.route, "window": w, "reserve": reserve, "total_tokens": total, "state": st.rawValue]))
                self.note = SheetCLI.error(r).map { L("sheet.ui.size.local", ["e": $0]) } ?? ""
            }
            if self.size?.state == .tooMuch && self.plan == "one" { self.plan = "" }
        }
    }

    /// Prepare / Build: through Up next and SheetRunner (pipeline) like every preparation, with the wizard's choices
    /// laid over its request; the job mirrors the runner's progress. The series remembers the setup.
    @discardableResult
    func build() -> String? {
        if let p = SheetRoutes.problem(route) { return p }
        guard model.root != nil else { return L("call.chooseProjectFirst") }
        var o = request(out: nil)
        for k in ["project", "meeting", "app_root", "call_type", "audience", "earlier_sheet"] { o.removeValue(forKey: k) }
        SheetRunner.overrides[model.id] = o
        if !UpNext.shared.contains(model) { UpNext.shared.save(model) }
        if let e = UpNext.shared.prepare(model) { return e }
        job = SheetJobs.shared.follow(kind: SheetFiles.path(for: model) == nil ? "build" : "refresh", call: model)
        let keep = sources.filter { $0.checked && $0.type != "text" }.map { s -> [String: String] in
            var d = ["type": s.type, "title": s.title]
            if let p = s.path { d["path"] = p }
            if let u = s.uri { d["uri"] = u }
            return d
        }
        SheetSeriesMemory.shared.remember(model, .init(preset: presetID, mode: mode.rawValue, route: route, sources: keep, language: language, savedAt: Date()))
        return nil
    }

    /// About how long a build takes, for "Prepare · ~40 s".
    var estimateSeconds: Int {
        let t = sources.filter(\.checked).compactMap(\.tokens).reduce(0, +)
        return max(20, min(900, 20 + t / 600))
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
