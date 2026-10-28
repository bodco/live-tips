import AppKit
import LiveTipsCore

/// 2026-10-27 (owner): a regular meeting remembers how it was set up last time (project, audience, type,
/// languages, the "What matters on this call" text that drives the preparation, folders, role, model), so the
/// PM only corrects it. Keyed by the calendar series (recurring events) and by the call title.
@MainActor
final class SeriesMemory {
    static let shared = SeriesMemory()

    struct Entry: Codable {
        var title: String; var target: String; var audience: String; var callType: String; var language: String
        var context: String; var folders: [String]; var useProjectFolder: Bool; var hiringRole: String
        var tipModel: String; var publicCall: Bool; var savedAt: Date
    }

    private var map: [String: Entry] = [:]
    private var path: URL { AppPaths.support.appendingPathComponent("series.json") }

    private init() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: path), let m = try? dec.decode([String: Entry].self, from: d) { map = m }
    }

    static func titleKey(_ title: String) -> String { "title:" + StartCallModel.slugify(title) }

    func keys(for m: StartCallModel) -> [String] {
        var k: [String] = []
        if let s = m.seriesKey, !s.isEmpty { k.append(s) }
        let t = Self.titleKey(m.effectiveTitle)
        if !k.contains(t) { k.append(t) }
        return k
    }

    /// Called when a call starts: these are the settings that were actually used.
    func remember(_ m: StartCallModel) {
        let e = Entry(title: m.effectiveTitle, target: m.target, audience: m.audience, callType: m.callType, language: m.language,
                      context: m.context, folders: m.folders, useProjectFolder: m.useProjectFolder, hiringRole: m.hiringRole,
                      tipModel: m.tipModel, publicCall: m.publicCall, savedAt: Date())
        for k in keys(for: m) { map[k] = e }
        // The calendar remembers its project too: a new meeting in the same calendar starts with it (2026-10-28).
        if let ck = m.calendarKey, !m.target.isEmpty { map["calendar:" + ck] = e }
        if map.count > 400 {       // keep the newest
            map = Dictionary(uniqueKeysWithValues: map.sorted { $0.value.savedAt > $1.value.savedAt }.prefix(400).map { ($0.key, $0.value) })
        }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(map) { try? d.write(to: path, options: .atomic) }
    }

    var count: Int { Set(map.values.map { $0.title.lowercased() }).count }

    func forgetAll() {
        map = [:]
        try? FileManager.default.removeItem(at: path)
    }

    /// The project of the last call that came from this calendar.
    func projectFor(calendarKey: String) -> String? { map["calendar:" + calendarKey]?.target }

    func lookup(seriesKey: String?, title: String) -> Entry? {
        if let s = seriesKey, let e = map[s] { return e }
        return map[Self.titleKey(title)]
    }
}

extension StartCallModel {
    /// The settings of the last call of this series, applied over the current ones.
    func apply(_ e: SeriesMemory.Entry) {
        if !e.target.isEmpty, registry.projects.contains(where: { "project:" + $0.slug == e.target }) || registry.workspaces.contains(where: { "workspace:" + $0.name == e.target }) {
            target = e.target
        }
        audience = e.audience; callType = e.callType; language = e.language; languageTouched = true
        context = e.context; folders = e.folders.filter { FileManager.default.fileExists(atPath: $0) }
        useProjectFolder = e.useProjectFolder; hiringRole = e.hiringRole; tipModel = e.tipModel; publicCall = e.publicCall
        let f = DateFormatter(); f.dateFormat = "d MMM"
        appliedFrom = L("call.appliedLast", ["title": e.title, "date": f.string(from: e.savedAt)])
        carryNotRaised(title: e.title)
    }

    /// Pacenote 0.8.5 (rules/agenda.yaml > wrapup): agenda items not raised on the last call of this series go into
    /// "What matters" as one line, so the next preparation and the tips pick them up. Same project only.
    func carryNotRaised(title: String) {
        let key = EditLog.seriesKey(title)
        let names = Set([project?.name, project?.slug, workspace?.name, root.map { ($0 as NSString).lastPathComponent }].compactMap { $0 })
        guard !names.isEmpty, let last = CallHistory.shared.visible.first(where: { $0.start < Date() && EditLog.seriesKey($0.title) == key && names.contains($0.project) }) else { return }
        let left = Self.notRaised(transcript: last.file)
        guard !left.isEmpty else { return }
        let line = L("call.notRaisedLast", ["items": left.joined(separator: "; ")])
        if context.contains(line) { return }
        let prefix = L("call.notRaisedLast", ["items": ""])
        let kept = context.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix(prefix) }.joined(separator: "\n")
        context = (kept.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : kept.trimmingCharacters(in: .newlines) + "\n") + line
    }

    /// The items of the last agenda strip of a call that were never raised (state todo).
    static func notRaised(transcript file: String) -> [String] {
        let stem = file.hasSuffix(".md") ? String(file.dropLast(3)) : file
        for p in [file + ".tips.jsonl", stem + ".tips.jsonl"] {
            guard let s = try? String(contentsOfFile: p, encoding: .utf8) else { continue }
            for ln in s.split(separator: "\n").reversed() where ln.contains("\"agenda\"") {
                guard let o = (try? JSONSerialization.jsonObject(with: Data(ln.utf8))) as? [String: Any], (o["kind"] as? String) == "agenda",
                      let items = o["items"] as? [Any] else { continue }
                return items.compactMap { x -> String? in
                    guard let d = x as? [String: Any], let t = d["text"] as? String, !t.isEmpty else { return nil }
                    let st = (d["state"] as? String) ?? ((d["done"] as? Bool) == true ? "done" : (d["cur"] as? Bool) == true ? "now" : "todo")
                    return st == "todo" ? t : nil
                }
            }
        }
        return []
    }

    /// A calendar event: its title, time and people; the project and the rest from the last call of the series
    /// or, the first time, a project whose name is in the title.
    func applyEvent(_ ev: CalendarService.CalEvent) {
        calEventID = ev.id
        seriesKey = ev.seriesKey
        calendarKey = ev.account + "|" + ev.calendar
        title = ev.title
        callDate = ev.start
        if let e = SeriesMemory.shared.lookup(seriesKey: ev.seriesKey, title: ev.title) {
            apply(e)
        } else {
            appliedFrom = nil
            let t = (ev.title + " " + ev.calendar).lowercased()
            if let p = registry.projects.filter({ $0.status != "archived" }).first(where: { t.contains($0.name.lowercased()) || t.contains($0.slug.lowercased()) }) {
                target = "project:" + p.slug
            } else if let t = SeriesMemory.shared.projectFor(calendarKey: ev.account + "|" + ev.calendar),
                      registry.projects.contains(where: { "project:" + $0.slug == t }) || registry.workspaces.contains(where: { "workspace:" + $0.name == t }) {
                target = t           // the project last used with this calendar
                appliedFrom = L("call.appliedCal", ["cal": ev.calendar])
            } else {
                target = ""          // owner: never the last used project by default; Start and Prepare ask
            }
            applyProjectDefaults()
        }
        setParticipants(ev.attendees)
        scanPrep()
        adoptExistingPrep()
    }

    /// 2026-10-28 (owner): "track whether the call happened after the preparation". A preparation of this meeting
    /// (prep-<date>-<title>.brief.md in the project's live folder) made after its last held call is the coming call's
    /// preparation: Home shows it as prepared and Start uses it. One made before the last call is old.
    /// 2026-10-28 (owner): a preparation belongs to ONE occurrence of a regular meeting: the one it was made for
    /// (the date in its name, within 3 hours), or else the next occurrence only. Tomorrow's call of the same
    /// series is not "prepared" by today's preparation.
    func prepFits(_ base: String) -> Bool {
        let n = (base as NSString).lastPathComponent
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"; f.locale = Locale(identifier: "en_US_POSIX")
        guard n.hasPrefix("prep-"), n.count > 20, let pd = f.date(from: String(n.dropFirst(5).prefix(15))) else { return true }
        if abs(pd.timeIntervalSince(callDate)) < 3 * 3600 { return true }
        if pd > callDate { return false }
        let key = EditLog.seriesKey(effectiveTitle)
        let earlier = CalendarService.shared.upcoming().contains { e in
            e.id != calEventID && e.start < callDate.addingTimeInterval(-3600)
                && ((seriesKey != nil && e.seriesKey == seriesKey) || EditLog.seriesKey(e.title) == key)
        }
        return !earlier
    }

    @discardableResult
    func adoptExistingPrep() -> Bool {
        if let b = prepBase, FileManager.default.fileExists(atPath: b + ".brief.md") { return true }
        guard let root = root else { return false }
        let live = (root as NSString).appendingPathComponent("live")
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: live) else { return false }
        let slug = Self.slugify(effectiveTitle)
        let key = EditLog.seriesKey(effectiveTitle)
        let lastHeld = CallHistory.shared.records.filter { EditLog.seriesKey($0.title) == key && $0.start < Date() }.map(\.start).max()
        var best: (String, Date)?
        for n in names where n.hasPrefix("prep-") && n.hasSuffix("-" + slug + ".brief.md") {
            let p = (live as NSString).appendingPathComponent(n)
            let attrs = try? fm.attributesOfItem(atPath: p)
            guard let made = (attrs?[.creationDate] as? Date) ?? (attrs?[.modificationDate] as? Date) else { continue }
            if let h = lastHeld, made <= h { continue }                     // written before the last call: old
            guard prepFits(String(p.dropLast(".brief.md".count))) else { continue }   // made for another occurrence
            if lastHeld == nil, Date().timeIntervalSince(made) > 3 * 86400 { continue }
            if best == nil || made > best!.1 { best = (p, made) }
        }
        guard let b = best else { return false }
        prepBase = String(b.0.dropLast(".brief.md".count))
        prepFailed = false
        return true
    }

    /// Writes the calendar's people into the "Participants:" line (the speakers offered on the call).
    func setParticipants(_ names: [String]) {
        guard !names.isEmpty else { return }
        let header = StartCallModel.uiLang == "uk" ? "Учасники:" : "Participants:"
        var lines = context.components(separatedBy: "\n")
        // Merge (2026-10-28): the names already there (a regular meeting's last setup) stay; the calendar adds the rest.
        var all = participants
        for n in names where !all.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) { all.append(n) }
        let line = header + " " + all.joined(separator: ", ")
        if let i = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).range(of: "^(учасники|participants|attendees)\\s*:", options: [.regularExpression, .caseInsensitive]) != nil }) {
            lines[i] = line
        } else {
            lines.insert(line, at: min(1, lines.count))
        }
        context = lines.joined(separator: "\n")
    }

    /// 2026-10-28 (owner): a regular meeting offers the speakers named on its last 3 calls (their speakers.json),
    /// next to the participants typed or taken from the calendar, so the voice library's names are offered again.
    var participantsWithPrevious: [String] {
        var out = participants
        guard let root = root else { return out }
        let live = (root as NSString).appendingPathComponent("live")
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: live) else { return out }
        let want = Self.slugify(effectiveTitle).replacingOccurrences(of: "-", with: "")
        var seen = 0
        for n in names.sorted(by: >) where n.hasSuffix(".speakers.json") && n.range(of: "^\\d{4}-\\d\\d-\\d\\d-\\d{4}-", options: .regularExpression) != nil {
            let core = String(n.dropFirst(16)).replacingOccurrences(of: ".app.speakers.json", with: "").replacingOccurrences(of: ".speakers.json", with: "").replacingOccurrences(of: "-", with: "")
            guard !want.isEmpty, core == want else { continue }
            guard let d = fm.contents(atPath: (live as NSString).appendingPathComponent(n)),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
            var found: [String] = ((o["roster"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
            found += ((o["clusters"] as? [String: [String: Any]]) ?? [:]).values.compactMap { $0["name"] as? String }
            for f in found where !f.isEmpty && !out.contains(where: { $0.caseInsensitiveCompare(f) == .orderedSame }) { out.append(f) }
            seen += 1
            if seen == 3 { break }
        }
        let me = Set(AppConfig.load(from: AppPaths.config).nameAliases.map { $0.lowercased() })
        return out.filter { !me.contains($0.lowercased()) }
    }

    /// Before typing everything again: a remembered call with the same title (no calendar needed).
    var rememberedForTitle: SeriesMemory.Entry? {
        guard appliedFrom == nil, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return SeriesMemory.shared.lookup(seriesKey: seriesKey, title: title)
    }
}

/// 2026-10-27 (owner): the calls already held, for Home: transcript, Notion page, folder. Built from the
/// app's own records and from the transcripts found in the projects' live folders (the skill's too).
/// Removing a call from the list only hides it; no file is deleted.
@MainActor
final class CallHistory: ObservableObject {
    static let shared = CallHistory()

    struct Record: Codable, Identifiable {
        var id: String { file }
        var file: String
        var title: String
        var project: String
        var start: Date
        var end: Date?
        var lines: Int?
        var notionURL: String?
        var costUSD: Double?
        var hidden = false
        var minutes: Double?       // from the first to the last line of the transcript
        var prepared: Bool?        // a preparation (<stem>.brief.md) was there
    }

    @Published private(set) var records: [Record] = []
    private var path: URL { AppPaths.support.appendingPathComponent("history.json") }

    private init() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: path), let r = try? dec.decode([Record].self, from: d) { records = r }
        scan()
    }

    var visible: [Record] {
        Array(records.filter { !$0.hidden && FileManager.default.fileExists(atPath: $0.file) }.sorted { $0.start > $1.start }.prefix(40))
    }

    func hide(_ r: Record) { update(r.file) { $0.hidden = true } }

    /// A call that has just ended.
    func recordEnd(file: String, title: String, project: String, lines: Int, cost: Double?) {
        guard !file.isEmpty else { return }
        let start = Self.startFromName(file) ?? Date()
        if records.contains(where: { $0.file == file }) {
            update(file) { $0.title = title; $0.project = project; $0.lines = lines; $0.end = Date(); $0.costUSD = cost }
        } else {
            records.append(Record(file: file, title: title, project: project, start: start, end: Date(), lines: lines, costUSD: cost))
            persist()
        }
        fillDetails()            // QA: Home's numbers count the call just ended
    }

    /// 2026-10-28 (owner): a call renamed during the call keeps the new name everywhere (Home, insights, history).
    /// The tips window writes the rename to <stem>.inbox.jsonl, so it survives a restart or an app update mid-call.
    nonisolated static func renamedTitle(_ file: String) -> String? {
        let stem = file.hasSuffix(".md") ? String(file.dropLast(3)) : file
        guard let s = try? String(contentsOfFile: stem + ".inbox.jsonl", encoding: .utf8) else { return nil }
        var t: String?
        for ln in s.split(separator: "\n") where ln.contains("\"title\"") {
            if let o = (try? JSONSerialization.jsonObject(with: Data(ln.utf8))) as? [String: Any],
               (o["key"] as? String) == "title", let v = (o["value"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { t = v }
        }
        return t
    }

    func rename(file: String, title: String) {
        if records.contains(where: { $0.file == file }) { update(file) { $0.title = title } }
    }

    /// Renames found in the calls' inbox files (calls of the last 60 days).
    func applyRenames() {
        var changed = false
        let since = Date().addingTimeInterval(-60 * 86400)
        for i in records.indices where records[i].start > since {
            if let t = Self.renamedTitle(records[i].file), t != records[i].title { records[i].title = t; changed = true }
        }
        if changed { persist() }
    }

    func setNotion(file: String, url: String) {
        if records.contains(where: { $0.file == file }) { update(file) { $0.notionURL = url } }
    }

    func addCost(file: String, _ usd: Double) {
        guard usd > 0, records.contains(where: { $0.file == file }) else { return }
        update(file) { $0.costUSD = ($0.costUSD ?? 0) + usd }
    }

    /// Length and preparation of each call, read once from its files (in the background).
    func fillDetails() {
        let todo = records.filter { $0.minutes == nil || $0.prepared == nil }.map(\.file)
        guard !todo.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            var found: [String: (Double, Bool)] = [:]
            for f in todo { found[f] = (Self.duration(of: f), Self.wasPrepared(f)) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for (f, v) in found { if let i = self.records.firstIndex(where: { $0.file == f }) { self.records[i].minutes = v.0; self.records[i].prepared = v.1 } }
                    self.persist()
                }
            }
        }
    }

    nonisolated static func duration(of file: String) -> Double {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return 0 }
        let re = try? NSRegularExpression(pattern: "^\\[(\\d\\d):(\\d\\d):(\\d\\d)\\]", options: .anchorsMatchLines)
        let ns = text as NSString
        let ms = re?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? []
        func secs(_ m: NSTextCheckingResult) -> Int {
            (1...3).map { Int(ns.substring(with: m.range(at: $0))) ?? 0 }.enumerated().reduce(0) { $0 + $1.element * [3600, 60, 1][$1.offset] }
        }
        guard let a = ms.first, let b = ms.last else { return 0 }
        var d = secs(b) - secs(a)
        if d < 0 { d += 86400 }
        return Double(d) / 60
    }

    nonisolated static func wasPrepared(_ file: String) -> Bool {
        let stem = file.hasSuffix(".md") ? String(file.dropLast(3)) : file
        return FileManager.default.fileExists(atPath: stem + ".brief.md")
    }

    private func update(_ file: String, _ change: (inout Record) -> Void) {
        guard let i = records.firstIndex(where: { $0.file == file }) else { return }
        change(&records[i])
        persist()
    }

    private func persist() {
        if records.count > 600 { records = Array(records.sorted { $0.start > $1.start }.prefix(600)) }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted]
        if let d = try? enc.encode(records) { try? d.write(to: path, options: .atomic) }
    }

    /// "2026-10-27-1657-weekly-sync.app.md" -> 27 Oct 2026 16:57.
    static func startFromName(_ file: String) -> Date? {
        let n = (file as NSString).lastPathComponent
        guard let r = n.range(of: "^\\d{4}-\\d\\d-\\d\\d-\\d{4}", options: .regularExpression) else { return nil }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"
        return f.date(from: String(n[r]))
    }

    /// Transcripts of the last 45 days in every project's live folder (calls made before Home existed, or by the skill).
    func scan() {
        let reg = ProjectRegistry.load(from: AppPaths.projects)
        var roots: [(String, String)] = reg.projects.filter { $0.status != "archived" }.map { ($0.root, $0.name) }
        roots += reg.workspaces.map { ($0.root, $0.name) }
        let fm = FileManager.default
        var known = Set(records.map(\.file))
        var added = false
        for (root, name) in roots {
            let live = (root as NSString).appendingPathComponent("live")
            guard let names = try? fm.contentsOfDirectory(atPath: live) else { continue }
            for n in names where n.range(of: "^\\d{4}-\\d\\d-\\d\\d-\\d{4}-[^.]+(\\.app)?\\.md$", options: .regularExpression) != nil {
                let file = (live as NSString).appendingPathComponent(n)
                guard !known.contains(file), let start = Self.startFromName(file), Date().timeIntervalSince(start) < 45 * 86400 else { continue }
                // The skill and the app can record the same call: keep one (the app's).
                if !n.hasSuffix(".app.md"), names.contains(String(n.dropLast(3)) + ".app.md") { continue }
                var title = String(n.dropFirst(16).dropLast(n.hasSuffix(".app.md") ? 7 : 3)).replacingOccurrences(of: "-", with: " ")
                if let h = try? FileHandle(forReadingFrom: URL(fileURLWithPath: file)) {
                    let head = String(data: h.readData(ofLength: 400), encoding: .utf8) ?? ""
                    try? h.close()
                    if let first = head.split(separator: "\n").first, first.hasPrefix("#"), let c = first.firstIndex(of: ":") {
                        let t = first[first.index(after: c)...].trimmingCharacters(in: .whitespaces)
                        if !t.isEmpty { title = t }
                    }
                }
                records.append(Record(file: file, title: title, project: name, start: start))
                known.insert(file)
                added = true
            }
        }
        if added { persist() }
        applyRenames()
    }
}

/// 2026-10-27 (owner): Claude spend by day for Home's week (the shared ledger keeps months only). Counted from
/// 0.6.8 on: the tips of each call, the Notion summary and preparations paid with the API key.
enum SpendDays {
    static var path: URL { AppPaths.support.appendingPathComponent("spend-days.json") }
    static func load() -> [String: Double] {
        guard let d = try? Data(contentsOf: path), let m = try? JSONDecoder().decode([String: Double].self, from: d) else { return [:] }
        return m
    }
    static func key(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d) }
    static func add(_ usd: Double, on day: Date = Date()) {
        guard usd > 0 else { return }
        var m = load()
        m[key(day), default: 0] += usd
        if let d = try? JSONEncoder().encode(m) { try? d.write(to: path, options: .atomic) }
    }
    static func total(from: Date, to: Date) -> Double {
        let m = load()
        var sum = 0.0, d = Calendar.current.startOfDay(for: from)
        while d < to { sum += m[key(d)] ?? 0; d = Calendar.current.date(byAdding: .day, value: 1, to: d) ?? to }
        return sum
    }
}

extension StartCallModel: Identifiable {}
