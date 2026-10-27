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
        appliedFrom = "Set up like the last \u{201C}\(e.title)\u{201D} call (\(f.string(from: e.savedAt))): correct what changed."
    }

    /// A calendar event: its title, time and people; the project and the rest from the last call of the series
    /// or, the first time, a project whose name is in the title.
    func applyEvent(_ ev: CalendarService.CalEvent) {
        calEventID = ev.id
        seriesKey = ev.seriesKey
        title = ev.title
        callDate = ev.start
        if let e = SeriesMemory.shared.lookup(seriesKey: ev.seriesKey, title: ev.title) {
            apply(e)
        } else {
            appliedFrom = nil
            let t = (ev.title + " " + ev.calendar).lowercased()
            if let p = registry.projects.filter({ $0.status != "archived" }).first(where: { t.contains($0.name.lowercased()) || t.contains($0.slug.lowercased()) }) {
                target = "project:" + p.slug
            }
            applyProjectDefaults()
        }
        setParticipants(ev.attendees)
        scanPrep()
    }

    /// Writes the calendar's people into the "Participants:" line (the speakers offered on the call).
    func setParticipants(_ names: [String]) {
        guard !names.isEmpty else { return }
        let header = StartCallModel.uiLang == "uk" ? "Учасники:" : "Participants:"
        var lines = context.components(separatedBy: "\n")
        let line = header + " " + names.joined(separator: ", ")
        if let i = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).range(of: "^(учасники|participants|attendees)\\s*:", options: [.regularExpression, .caseInsensitive]) != nil }) {
            lines[i] = line
        } else {
            lines.insert(line, at: min(1, lines.count))
        }
        context = lines.joined(separator: "\n")
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
    }

    func setNotion(file: String, url: String) {
        if records.contains(where: { $0.file == file }) { update(file) { $0.notionURL = url } }
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
    }
}
