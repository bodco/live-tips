import AppKit
import LiveTipsCore

/// 2026-10-27 (owner): "Up next", upcoming calls. Any number of calls can be set up and prepared ahead,
/// also while a call is live; only one call records at a time. Switching ends the live call properly
/// (transcript saved, Notion summary in the background) and starts the chosen one.
/// Preparations run one after another (Claude Code, one at a time); each is tied to its call by id, so
/// a preparation for an upcoming call never joins the live one. The list is kept in upnext.json and
/// survives a restart of the app.
@MainActor
final class UpNext: ObservableObject {
    static let shared = UpNext()

    @Published private(set) var items: [StartCallModel] = []
    /// Calls waiting for their preparation (the runner is busy with another one).
    @Published private(set) var queue: [StartCallModel] = []
    /// The call to start once the live one has stopped (End current call and start this).
    var switchingTo: StartCallModel?

    private var path: URL { AppPaths.support.appendingPathComponent("upnext.json") }

    private init() { load(); pruneHeld() }

    // MARK: list

    func contains(_ m: StartCallModel) -> Bool { items.contains { $0 === m } }
    func item(_ id: String) -> StartCallModel? { items.first { $0.id.uuidString == id } }
    /// 2026-10-28 (owner): "no duplicate meetings". The call being recorded is not shown as the next one.
    var first: StartCallModel? { visible.first }
    var visible: [StartCallModel] { items.filter { !isLive($0) } }

    /// The same call as the live one: its own setup, the same calendar event, or the same title within 2 hours.
    func isLive(_ m: StartCallModel) -> Bool {
        let ce = CallEngine.shared
        guard (NSApp.delegate as? AppDelegate)?.callIsLive ?? ce.isRunning else { return false }
        if ce.currentCallID == m.id { return true }
        if let a = m.calEventID, let b = ce.liveEventID { return a == b }      // both from the calendar: exact
        let t = EditLog.seriesKey(ce.renamed ?? (ce.callRequest["title"] as? String) ?? "")
        return !t.isEmpty && t == EditLog.seriesKey(m.effectiveTitle) && abs(m.callDate.timeIntervalSinceNow) < 2 * 3600
    }

    /// A call has started: every Up next entry for it goes (set up twice, from the calendar and from Up next).
    func removeMatching(_ s: StartCallModel) {
        let key = EditLog.seriesKey(s.effectiveTitle)
        let before = items.count
        items.removeAll { m in
            m === s || m.id == s.id
                || (m.calEventID != nil && m.calEventID == s.calEventID)
                || (!key.isEmpty && EditLog.seriesKey(m.effectiveTitle) == key && abs(m.callDate.timeIntervalSince(Date())) < 2 * 3600)
        }
        if items.count != before { persist() }
    }

    /// Calendar calls of the next 36 hours with a preparation not used yet join Up next as prepared.
    func adoptPreparedEvents() {
        var changed = false
        // 0.7.4 gave a regular meeting's preparation to every occurrence; it belongs to one (prepFits).
        let wrong = items.filter { m in m.calEventID != nil && m.prepBase.map { !m.prepFits($0) } == true }
        if !wrong.isEmpty { items.removeAll { m in wrong.contains { $0 === m } }; changed = true }
        for e in CalendarService.shared.upcoming() where !items.contains(where: { $0.calEventID == e.id }) {
            let m = StartCallModel()
            m.applyEvent(e)
            guard !m.target.isEmpty, m.prepBase != nil, !isLive(m) else { continue }
            items.append(m); changed = true
        }
        for m in items where m.prepBase == nil { if m.adoptExistingPrep() { changed = true } }
        if changed { items.sort { $0.callDate < $1.callDate }; persist() }
    }

    /// Calls already held (a transcript of the same meeting that day) are not "up next" any more.
    func pruneHeld() {
        let held = CallHistory.shared.records
        let before = items.count
        items.removeAll { m in
            guard m.callDate < Date().addingTimeInterval(-30 * 60) else { return false }
            let key = EditLog.seriesKey(m.effectiveTitle)
            return held.contains { EditLog.seriesKey($0.title) == key && abs($0.start.timeIntervalSince(m.callDate)) < 3 * 3600 }
        }
        if items.count != before { persist() }
    }

    /// Adds or updates a call; the list is ordered by the call time.
    func save(_ m: StartCallModel) {
        if !contains(m) { items.append(m) }
        items.sort { $0.callDate < $1.callDate }
        persist()
    }

    /// Takes a call off the list. `keepPrep`: the call is being started, so its preparation goes on
    /// (and joins the call when done); otherwise a running or queued preparation for it is dropped.
    func remove(_ m: StartCallModel, keepPrep: Bool = false) {
        items.removeAll { $0 === m }
        if !keepPrep {
            queue.removeAll { $0 === m }
            if PrepRunner.shared.running && PrepRunner.shared.callID == m.id { PrepRunner.shared.cancel() }
        }
        persist()
    }

    // MARK: preparation queue

    enum PrepState: String { case none, queued, running, ready, failed }

    func prepState(_ m: StartCallModel) -> PrepState {
        if PrepRunner.shared.running && PrepRunner.shared.callID == m.id { return .running }
        if queue.contains(where: { $0 === m }) { return .queued }
        if let b = m.prepBase, FileManager.default.fileExists(atPath: b + ".brief.md") { return .ready }
        return m.prepFailed ? .failed : .none
    }

    /// Prepare now: starts at once, or waits in line behind the preparation that is running.
    /// Returns an error line, or nil.
    func prepare(_ m: StartCallModel) -> String? {
        guard let r = m.prepRequest() else { return L("call.chooseProjectFirst") }
        m.prepFailed = false
        let runner = PrepRunner.shared
        if runner.running {
            if runner.callID == m.id || queue.contains(where: { $0 === m }) { return nil }
            queue.append(m)
            return nil
        }
        return runner.start(r)
    }

    func unqueue(_ m: StartCallModel) { queue.removeAll { $0 === m } }

    /// Called by PrepRunner when a preparation ends (done, failed or stopped): remember the result on its
    /// call and start the next one in line.
    func prepFinished(id: UUID?, base: String?, ok: Bool, stopped: Bool = false) {
        if let id = id {
            let owners = items.filter { $0.id == id } + queue.filter { $0.id == id }
            for m in owners {
                if ok, let b = base { m.prepBase = b; m.prepFailed = false } else if !stopped { m.prepFailed = true }
            }
            if !owners.isEmpty { persist() }
        }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.pump() } }
    }

    private func pump() {
        while !PrepRunner.shared.running, !queue.isEmpty {
            let m = queue.removeFirst()
            if let r = m.prepRequest(), PrepRunner.shared.start(r) == nil { break }
            m.prepFailed = true
        }
    }

    // MARK: what the tips window shows

    /// JSON for window.setUpNext in the tips window.
    func json() -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let d = DateFormatter(); d.dateFormat = "d MMM HH:mm"
        let runner = PrepRunner.shared
        let list: [[String: Any]] = visible.map { m in
            let st = prepState(m)
            let when = Calendar.current.isDateInToday(m.callDate) ? f.string(from: m.callDate) : d.string(from: m.callDate)
            return ["id": m.id.uuidString, "title": m.effectiveTitle, "project": m.targetName, "when": when,
                    "prep": st.rawValue, "progress": st == .running ? runner.progress : 0,
                    "stage": st == .running ? runner.stage : "",
                    "starts_in_min": m.callDate.timeIntervalSinceNow / 60]      // Pacenote 0.8: "Team retro in 8 min" 
        }
        let data = (try? JSONSerialization.data(withJSONObject: list)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    // MARK: storage

    struct Saved: Codable {
        var id: String; var target: String; var title: String; var audience: String; var callType: String
        var publicCall: Bool; var hiringRole: String; var tipModel: String; var language: String
        var context: String; var folders: [String]; var useProjectFolder: Bool; var callDate: Date
        var chosenPrep: String?; var prepBase: String?; var prepFailed: Bool
        var calEventID: String?; var seriesKey: String?
    }

    private func persist() {
        let list = items.map { m in
            Saved(id: m.id.uuidString, target: m.target, title: m.title, audience: m.audience, callType: m.callType,
                  publicCall: m.publicCall, hiringRole: m.hiringRole, tipModel: m.tipModel, language: m.language,
                  context: m.context, folders: m.folders, useProjectFolder: m.useProjectFolder, callDate: m.callDate,
                  chosenPrep: m.chosenPrep, prepBase: m.prepBase, prepFailed: m.prepFailed,
                  calEventID: m.calEventID, seriesKey: m.seriesKey)
        }
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted]
        if let d = try? enc.encode(list) {
            try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? d.write(to: path, options: .atomic)
        }
    }

    private func load() {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let d = try? Data(contentsOf: path), let list = try? dec.decode([Saved].self, from: d) else { return }
        items = list.map { s in
            let m = StartCallModel()
            if let u = UUID(uuidString: s.id) { m.id = u }
            m.target = s.target; m.title = s.title; m.audience = s.audience; m.callType = s.callType
            m.publicCall = s.publicCall; m.hiringRole = s.hiringRole; m.tipModel = s.tipModel
            m.language = s.language; m.languageTouched = true; m.context = s.context; m.folders = s.folders
            m.useProjectFolder = s.useProjectFolder; m.callDate = s.callDate; m.chosenPrep = s.chosenPrep
            m.prepBase = s.prepBase; m.prepFailed = s.prepFailed; m.calEventID = s.calEventID; m.seriesKey = s.seriesKey
            return m
        }
    }
}
