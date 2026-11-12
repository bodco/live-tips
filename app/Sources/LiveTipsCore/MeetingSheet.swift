import Foundation

// 0.10.0 (Meeting Sheet, phase 1): the models of <project>/live/<base>.sheet.json (schema pacenote.sheet/1), the same
// fields as the Python sidecar (spikes/m0/livetips_m0/sheet/schema.py) and rules/meeting-sheet.yaml. Keys are snake_case
// in the file. Enum values are tolerant: an unknown value from a newer sidecar decodes, keeps its text and encodes back
// as it was (isKnown == false), so an older app never drops a sheet over one new word.

public protocol SheetValue: RawRepresentable, Codable, Hashable, CustomStringConvertible where RawValue == String {
    static var known: [Self] { get }
}

public extension SheetValue {
    var isKnown: Bool { Self.known.contains(self) }
    var description: String { rawValue }
}

public struct SheetMode: SheetValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let quick = Self(rawValue: "quick"), expert = Self(rawValue: "expert")
    public static let known: [Self] = [quick, expert]
}

public struct BlockType: SheetValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let header = Self(rawValue: "header"), myFocus = Self(rawValue: "my_focus"), company = Self(rawValue: "company"),
        signals = Self(rawValue: "signals"), techStack = Self(rawValue: "tech_stack"), fit = Self(rawValue: "fit"),
        contact = Self(rawValue: "contact"), qualification = Self(rawValue: "qualification"), history = Self(rawValue: "history"),
        projectContext = Self(rawValue: "project_context"), agenda = Self(rawValue: "agenda"), actionItems = Self(rawValue: "action_items"),
        questions = Self(rawValue: "questions"), bestOutcome = Self(rawValue: "best_outcome"), redLines = Self(rawValue: "red_lines"),
        structureRoles = Self(rawValue: "structure_roles"), overview = Self(rawValue: "overview"), gaps = Self(rawValue: "gaps"),
        standupSince = Self(rawValue: "standup_since"), standupToday = Self(rawValue: "standup_today"),
        standupBlockers = Self(rawValue: "standup_blockers"), standupWaiting = Self(rawValue: "standup_waiting"),
        interviewCandidate = Self(rawValue: "interview_candidate"), interviewRole = Self(rawValue: "interview_role")
    public static let known: [Self] = [header, myFocus, company, signals, techStack, fit, contact, qualification, history,
        projectContext, agenda, actionItems, questions, bestOutcome, redLines, structureRoles, overview, gaps, standupSince,
        standupToday, standupBlockers, standupWaiting, interviewCandidate, interviewRole]
}

public struct FactStatus: SheetValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let found = Self(rawValue: "found"), notFound = Self(rawValue: "not_found"), needsCheck = Self(rawValue: "needs_check"),
        conflict = Self(rawValue: "conflict"), stale = Self(rawValue: "stale"), edited = Self(rawValue: "edited")
    public static let known: [Self] = [found, notFound, needsCheck, conflict, stale, edited]
}

public struct FactOrigin: SheetValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let model = Self(rawValue: "model"), user = Self(rawValue: "user"), readiness = Self(rawValue: "readiness")
    public static let known: [Self] = [model, user, readiness]
}

public struct FactLevel: SheetValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let green = Self(rawValue: "green"), yellow = Self(rawValue: "yellow"), red = Self(rawValue: "red"),
        unknown = Self(rawValue: "unknown")
    public static let known: [Self] = [green, yellow, red, unknown]
}

public struct DiffMark: SheetValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let new = Self(rawValue: "new"), changed = Self(rawValue: "changed"), gone = Self(rawValue: "gone")
    public static let known: [Self] = [new, changed, gone]
}

public struct SourceType: SheetValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let file = Self(rawValue: "file"), folderFile = Self(rawValue: "folder_file"), gdoc = Self(rawValue: "gdoc"),
        gsheet = Self(rawValue: "gsheet"), gslides = Self(rawValue: "gslides"), driveFile = Self(rawValue: "drive_file"),
        notion = Self(rawValue: "notion"), web = Self(rawValue: "web"), webPage = Self(rawValue: "web_page"),
        linkedin = Self(rawValue: "linkedin"), linkedinManual = Self(rawValue: "linkedin_manual"), text = Self(rawValue: "text"),
        prevCall = Self(rawValue: "prev_call"), tracker = Self(rawValue: "tracker"), webSearch = Self(rawValue: "web_search"),
        crm = Self(rawValue: "crm"), projectState = Self(rawValue: "project_state"), digest = Self(rawValue: "digest"),
        transcript = Self(rawValue: "transcript")
    // 0.10.0 (Meeting Sheet, folders): a folder is a source of its own (its recent files are folder_file with parent)
    public static let folder = Self(rawValue: "folder")
    public static let known: [Self] = [file, folderFile, gdoc, gsheet, gslides, driveFile, notion, web, webPage, linkedin,
        linkedinManual, text, prevCall, tracker, webSearch, crm, projectState, digest, transcript, folder]
}

public struct SourceAccess: SheetValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let ok = Self(rawValue: "ok"), denied = Self(rawValue: "denied"), unsupported = Self(rawValue: "unsupported"),
        pending = Self(rawValue: "pending")
    public static let known: [Self] = [ok, denied, unsupported, pending]
}

public struct FixAction: SheetValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let confirmGoogle = Self(rawValue: "confirm_google"), connectNotion = Self(rawValue: "connect_notion"),
        connectGoogle = Self(rawValue: "connect_google"), openInBrowser = Self(rawValue: "open_in_browser"),
        saveAsPDF = Self(rawValue: "save_as_pdf"), pasteText = Self(rawValue: "paste_text"),
        fillByHand = Self(rawValue: "fill_by_hand"), retry = Self(rawValue: "retry")
    public static let known: [Self] = [confirmGoogle, connectNotion, connectGoogle, openInBrowser, saveAsPDF, pasteText, fillByHand, retry]
}

public struct SourceUse: SheetValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let full = Self(rawValue: "full"), summarized = Self(rawValue: "summarized"), truncated = Self(rawValue: "truncated"),
        skipped = Self(rawValue: "skipped"), notUsed = Self(rawValue: "not_used")
    public static let known: [Self] = [full, summarized, truncated, skipped, notUsed]
}

public struct SizeState: SheetValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let fits = Self(rawValue: "fits"), near = Self(rawValue: "near"), tooMuch = Self(rawValue: "too_much")
    public static let known: [Self] = [fits, near, tooMuch]
}

public struct PlanMode: SheetValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let one = Self(rawValue: "one"), passes = Self(rawValue: "passes"), compress = Self(rawValue: "compress")
    public static let known: [Self] = [one, passes, compress]
}

public struct ReadinessState: SheetValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let ready = Self(rawValue: "ready"), almost = Self(rawValue: "almost"), notReady = Self(rawValue: "not_ready")
    public static let known: [Self] = [ready, almost, notReady]
}

public struct GapAction: SheetValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let addQuestion = Self(rawValue: "add_question"), findAgain = Self(rawValue: "find_again"),
        markChecked = Self(rawValue: "mark_checked"), dropCheck = Self(rawValue: "drop_check"),
        assignOwner = Self(rawValue: "assign_owner"), addSource = Self(rawValue: "add_source")
    public static let known: [Self] = [addQuestion, findAgain, markChecked, dropCheck, assignOwner, addSource]
}

public struct GapSeverity: SheetValue {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let blocker = Self(rawValue: "blocker"), warning = Self(rawValue: "warning")
    public static let known: [Self] = [blocker, warning]
}

// MARK: - The sheet

public struct MeetingSheet: Codable, Equatable {
    public var schema: String
    public var id: String
    public var title: String
    public var meetingRef: MeetingRef
    public var mode: SheetMode
    public var preset: String
    public var language: String
    public var route: String?
    public var project: SheetProject?
    public var callType: String?
    public var audience: String?
    public var participants: SheetParticipants?
    public var goal: String?
    public var blocks: [SheetBlock]
    public var sources: [SheetSource]
    public var sizeReport: SizeReport?
    public var readiness: SheetReadiness?
    public var versions: [SheetVersion]?
    public var builtAt: String?
    public var refreshedAt: String?
    public var diff: SheetDiff?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schema, id, title, mode, preset, language, route, project, audience, participants, goal, blocks, sources,
             readiness, versions, diff
        case meetingRef = "meeting_ref", callType = "call_type", sizeReport = "size_report", builtAt = "built_at",
             refreshedAt = "refreshed_at"
    }
}

public struct MeetingRef: Codable, Equatable {
    public var eventId: String?
    public var start: String
    public var end: String?
    public var tz: String?
    public var place: String?             // "where" in the file (a Swift keyword)
    enum CodingKeys: String, CodingKey { case start, end, tz, eventId = "event_id", place = "where" }
}

public struct SheetProject: Codable, Equatable {
    public var slug: String?
    public var root: String?
}

public struct SheetParticipants: Codable, Equatable {
    public var ours: [SheetPerson]?
    public var theirs: [SheetPerson]?
}

public struct SheetPerson: Codable, Equatable {
    public var name: String
    public var role: String?
    public var company: String?
    public var domain: String?
}

public struct SheetBlock: Codable, Equatable, Identifiable {
    public var id: String
    public var type: BlockType
    public var title: String
    public var visible: Bool
    public var onlyIfData: Bool
    public var order: Int
    public var method: String?            // the qualification method (rules/sales.yaml key), qualification blocks only
    public var facts: [SheetFact]
    public var editedByUser: Bool
    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, type, title, visible, order, method, facts
        case onlyIfData = "only_if_data", editedByUser = "edited_by_user"
    }
}

public struct SheetFact: Codable, Equatable, Identifiable {
    public var id: String
    public var label: String?
    public var text: String
    public var sourceIds: [String]
    public var locator: FactLocator?
    public var checkedAt: String?
    public var status: FactStatus
    public var conflictWith: [String]?
    public var origin: FactOrigin
    public var value: FactValue?
    public var diff: DiffMark?
    /// 0.10.0 (Meeting Sheet, round 2): an older value replaced by a newer fact (newer wins); the UI shows "was X".
    public var supersededBy: String? = nil
    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, label, text, locator, status, origin, value, diff
        case sourceIds = "source_ids", checkedAt = "checked_at", conflictWith = "conflict_with"
        case supersededBy = "superseded_by"
    }
    /// A fact Refresh never overwrites (livetips_m0/sheet/merge.py).
    public var isProtected: Bool { status == .edited || origin == .user }
}

public struct FactLocator: Codable, Equatable {
    public var quote: String?
    public var line: Int?
    public var page: Int?
    public var url: String?
    public var slide: Int?
    public var cell: String?
}

/// level: qualification and other rated facts; key: the criterion (qualification) or the question's criterion;
/// owner and due: agenda and action items.
public struct FactValue: Codable, Equatable {
    public var level: FactLevel?
    public var key: String?
    public var owner: String?
    public var due: String?
}

public struct SheetSource: Codable, Equatable, Identifiable {
    public var id: String
    public var n: Int
    public var type: SourceType
    public var uri: String?
    public var path: String?
    public var title: String
    public var sizeTokens: Int?
    public var chars: Int?
    public var access: SourceAccess
    public var accessReason: String?
    public var fixAction: FixAction?
    public var used: SourceUse
    public var reason: String?
    public var pass: Int?
    public var auto: Bool?
    public var why: [String]?
    public var deck: DeckInfo?
    public var modifiedAt: String?
    // 0.10.0 (Meeting Sheet, folders): a folder file names its folder; a folder has its own days and its counts
    public var parent: String?
    public var days: Int?
    public var folder: SheetFolderInfo?
    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, n, type, uri, path, title, chars, access, used, reason, pass, auto, why, deck, parent, days, folder
        case sizeTokens = "size_tokens", accessReason = "access_reason", fixAction = "fix_action", modifiedAt = "modified_at"
    }
}

/// 0.10.0 (Meeting Sheet, folders): what a folder source gave: files taken for the preparation (changed in the last
/// `days` days, or the newest few when none is that fresh), files searchable during the call, files over the budget.
public struct SheetFolderInfo: Codable, Equatable {
    public var days: Int?
    public var recent: Int?
    public var inWindow: Int?
    public var searchable: Int?
    public var fallback: Bool?
    public var overBudget: Int?
    public var tokens: Int?
    public init(days: Int? = nil, recent: Int? = nil, inWindow: Int? = nil, searchable: Int? = nil, fallback: Bool? = nil,
                overBudget: Int? = nil, tokens: Int? = nil) {
        self.days = days; self.recent = recent; self.inWindow = inWindow; self.searchable = searchable
        self.fallback = fallback; self.overBudget = overBudget; self.tokens = tokens
    }
    enum CodingKeys: String, CodingKey {
        case days, recent, searchable, fallback, tokens, inWindow = "in_window", overBudget = "over_budget"
    }
    public init(json o: [String: Any]) {
        self.init(days: o["days"] as? Int, recent: o["recent"] as? Int, inWindow: o["in_window"] as? Int,
                  searchable: o["searchable"] as? Int, fallback: o["fallback"] as? Bool, overBudget: o["over_budget"] as? Int,
                  tokens: o["tokens"] as? Int)
    }
}

/// 0.10.0 (Meeting Sheet, folders): the pure rules of folder sources, shared by Quick, Expert, Start call and the
/// series memory (CoreChecks).
public enum SheetFolders {
    public static let defaultDays = 7

    /// A path added as a source: a folder is "folder", never a file that fails with "a folder, not a file".
    public static func sourceType(isDir: Bool) -> String { isDir ? SourceType.folder.rawValue : SourceType.file.rawValue }

    /// A source saved by an older setup (series memory): "file" or "folder_file" that is a folder now reads as "folder".
    public static func migrate(type: String, isDir: Bool) -> String {
        isDir && (type == SourceType.file.rawValue || type == SourceType.folderFile.rawValue || type.isEmpty) ? SourceType.folder.rawValue : type
    }

    /// The folder row as an i18n key and its arguments:
    /// "12 recent files for the preparation (last 7 days) · 340 searchable during the call".
    public static func line(_ i: SheetFolderInfo, days fallbackDays: Int = defaultDays) -> (key: String, args: [String: String]) {
        let days = i.days ?? fallbackDays, n = i.recent ?? 0, total = i.searchable ?? 0
        let key: String
        if total == 0 { key = "sheet.ui.folder.empty" }
        else if i.fallback == true { key = n > 0 ? "sheet.ui.folder.fallback" : "sheet.ui.folder.none" }
        else { key = "sheet.ui.folder.line" }
        return (key, ["n": "\(n)", "days": "\(days)", "m": "\(total)", "over": "\(i.overBudget ?? 0)"])
    }

    /// The tokens a folder adds to the size: only the files taken.
    public static func tokens(_ i: SheetFolderInfo?) -> Int { i?.tokens ?? 0 }

    /// A per-folder days value as typed in Expert Sources: 1...365, empty or 0 = the default of Settings.
    public static func days(_ typed: String) -> Int? {
        guard let v = Int(typed.trimmingCharacters(in: .whitespaces)), v > 0 else { return nil }
        return min(365, v)
    }
}

/// A source marked as the deck: slide owners ("<slide n>": name), talk minutes, Q&A minutes.
public struct DeckInfo: Codable, Equatable {
    public var owners: [String: String]?
    public var minutes: Double?
    public var qaMinutes: Double?
    enum CodingKeys: String, CodingKey { case owners, minutes, qaMinutes = "qa_minutes" }
}

public struct SizeReport: Codable, Equatable {
    public var route: String?
    public var model: String?
    public var window: Int?
    public var reserve: Int?
    public var totalTokens: Int?
    public var state: SizeState?
    public var plan: SizePlan?
    enum CodingKeys: String, CodingKey { case route, model, window, reserve, state, plan, totalTokens = "total_tokens" }
}

public struct SizePlan: Codable, Equatable {
    public var mode: PlanMode
    public var passes: [SizePass]?
}

public struct SizePass: Codable, Equatable {
    public var n: Int
    public var sourceIds: [String]
    enum CodingKeys: String, CodingKey { case n, sourceIds = "source_ids" }
}

public struct SheetReadiness: Codable, Equatable {
    public var state: ReadinessState
    public var gaps: [SheetGap]?
    public var checks: [ReadinessCheck]?
    public var dropped: [String]?         // rule ids or gap ids the user dropped for this meeting
}

public struct SheetGap: Codable, Equatable, Identifiable {
    public var id: String
    public var rule: String
    public var text: String
    public var block: String?
    public var fact: String?
    public var action: GapAction
    public var severity: GapSeverity
}

public struct ReadinessCheck: Codable, Equatable {
    public var rule: String
    public var ok: Bool
    public var dropped: Bool?
    public var skipped: Bool?
    /// 0.10.0 (Meeting Sheet, hardening): why a rule was skipped ("block_hidden": the block is hidden for this meeting).
    public var reason: String? = nil
}

public struct SheetVersion: Codable, Equatable {
    public var n: Int
    public var builtAt: String
    public var route: String?
    public var model: String?
    public var note: String?
    enum CodingKeys: String, CodingKey { case n, route, model, note, builtAt = "built_at" }
}

public struct SheetDiff: Codable, Equatable {
    public var new: [String]?
    public var changed: [String]?
    public var gone: [String]?
}

// MARK: - Files and helpers

public enum MeetingSheetIO {
    public static let schema = "pacenote.sheet/1"

    /// <live folder>/<base>.sheet.json, <base> = prep-<yyyy-MM-dd-HHmm>-<slug> as the call's other files.
    public static func path(liveFolder: String, base: String) -> String {
        (liveFolder as NSString).appendingPathComponent(base + ".sheet.json")
    }

    public static func decode(_ data: Data) throws -> MeetingSheet {
        try JSONDecoder().decode(MeetingSheet.self, from: data)
    }

    public static func encode(_ sheet: MeetingSheet) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(sheet)
    }

    public static func load(_ path: String) throws -> MeetingSheet {
        try decode(Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)))
    }

    /// 0.10.0 (Meeting Sheet, hardening): a save patches the file that is there: fields this model does not know
    /// (top-level gone_facts, fact.was, source.checked_at, value.minutes / backup, any later key) stay as Python wrote
    /// them; the fields the model knows are written from the model (so a value it cleared stays cleared).
    public static func save(_ sheet: MeetingSheet, to path: String) throws {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = try encode(sheet)
        if let old = try? Data(contentsOf: url), let merged = try? patched(original: old, new: data) { data = merged }
        try data.write(to: url, options: .atomic)
    }

    /// The keys each level of the sheet knows; anything else in the file is kept on save.
    struct KeyTree {
        let known: Set<String>
        let children: [String: KeyTree]
    }

    static let keyTree = KeyTree(known: Set(MeetingSheet.CodingKeys.allCases.map(\.rawValue)), children: [
        "blocks": KeyTree(known: Set(SheetBlock.CodingKeys.allCases.map(\.rawValue)), children: [
            "facts": KeyTree(known: Set(SheetFact.CodingKeys.allCases.map(\.rawValue)), children: [
                "value": KeyTree(known: ["level", "key", "owner", "due"], children: [:]),
                "locator": KeyTree(known: ["quote", "line", "page", "url", "slide", "cell"], children: [:]),
            ]),
        ]),
        "sources": KeyTree(known: Set(SheetSource.CodingKeys.allCases.map(\.rawValue)), children: [:]),
    ])

    /// The new JSON with the original's unknown keys laid back in (blocks, facts and sources matched by id).
    public static func patched(original: Data, new: Data) throws -> Data {
        guard let o = try JSONSerialization.jsonObject(with: original) as? [String: Any],
              let n = try JSONSerialization.jsonObject(with: new) as? [String: Any] else { return new }
        let m = merge(o, n, keyTree)
        return try JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    static func merge(_ orig: [String: Any], _ new: [String: Any], _ tree: KeyTree) -> [String: Any] {
        var out = new
        for (k, v) in orig where out[k] == nil && !tree.known.contains(k) { out[k] = v }
        for (k, sub) in tree.children {
            if let nd = out[k] as? [String: Any], let od = orig[k] as? [String: Any] {
                out[k] = merge(od, nd, sub)
            } else if let na = out[k] as? [[String: Any]], let oa = orig[k] as? [[String: Any]] {
                var byID: [String: [String: Any]] = [:]
                for x in oa { if let id = x["id"] as? String, byID[id] == nil { byID[id] = x } }
                out[k] = na.map { x -> [String: Any] in
                    guard let id = x["id"] as? String, let ox = byID[id] else { return x }
                    return merge(ox, x, sub)
                }
            }
        }
        return out
    }
}

/// The readiness chip of a call: icon and text, never colour alone. label is English; labelKey is the i18n key.
public struct ReadinessBadge: Equatable {
    public var state: ReadinessState?     // nil = not checked yet (or a state this app does not know)
    public var label: String
    public var labelKey: String
    public var symbol: String             // SF Symbol
    public var gaps: Int
    public var blockers: Int

    public static func of(_ r: SheetReadiness?) -> ReadinessBadge {
        let gaps = r?.gaps ?? []
        let blockers = gaps.filter { $0.severity == .blocker }.count
        switch r?.state {
        case .some(.ready): return ReadinessBadge(state: .ready, label: "Ready", labelKey: "sheet.readiness.ready", symbol: "checkmark.circle.fill", gaps: gaps.count, blockers: blockers)
        case .some(.almost): return ReadinessBadge(state: .almost, label: "Almost", labelKey: "sheet.readiness.almost", symbol: "exclamationmark.triangle.fill", gaps: gaps.count, blockers: blockers)
        case .some(.notReady): return ReadinessBadge(state: .notReady, label: "Not ready", labelKey: "sheet.readiness.not_ready", symbol: "xmark.octagon.fill", gaps: gaps.count, blockers: blockers)
        default: return ReadinessBadge(state: nil, label: "Not checked", labelKey: "sheet.readiness.unknown", symbol: "questionmark.circle", gaps: gaps.count, blockers: blockers)
        }
    }
}

public extension MeetingSheet {
    var readinessBadge: ReadinessBadge { ReadinessBadge.of(readiness) }
    func block(_ type: BlockType) -> SheetBlock? { blocks.first { $0.type == type } }
    /// Blocks in their order; a block marked only_if_data without facts is left out.
    var shownBlocks: [SheetBlock] {
        blocks.filter { $0.visible && !($0.onlyIfData && $0.facts.isEmpty) }.sorted { $0.order < $1.order }
    }
    func source(id: String) -> SheetSource? { sources.first { $0.id == id } }
    func fact(id: String) -> SheetFact? { blocks.lazy.flatMap(\.facts).first { $0.id == id } }
    /// 0.10.0 (Meeting Sheet, round 2): the older values a fact replaced (newer wins), newest first as built.
    func replaced(by id: String) -> [SheetFact] { blocks.flatMap(\.facts).filter { $0.supersededBy == id } }
}
