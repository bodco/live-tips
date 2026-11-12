import Foundation

// 0.10.0 (Meeting Sheet, phase 4): pure logic behind the Meeting Sheet screens, kept here so CoreChecks can test it
// without the UI: the Quick / Expert default (settings.default_mode of rules/meeting-sheet.yaml plus the user's own
// rules from Settings > Meeting Sheet), the counts of the Refresh banner, the edits a person makes on the sheet
// (an edited fact, a block moved or hidden, a conflict settled, a gap closed) and the export rendering (Markdown and
// HTML with the sources as footnotes or links next to each fact). Nothing here reads the disk or the network.

// MARK: - Quick or Expert

/// One rule of settings.default_mode: the first rule that matches wins; no match = the preset's own mode.
public struct SheetModeRule: Codable, Equatable, Identifiable {
    public var when: String               // preset_in | earlier_sheet | new_external_domain | internal
    public var presets: [String]?
    public var mode: String               // quick | expert
    public var off: Bool?                 // turned off in Settings > Meeting Sheet
    public var id: String { when + ":" + (presets ?? []).joined(separator: ",") }
    public init(when: String, presets: [String]? = nil, mode: String, off: Bool? = nil) {
        self.when = when; self.presets = presets; self.mode = mode; self.off = off
    }

    /// The rules of rules/meeting-sheet.yaml (settings.default_mode), the same order.
    public static let defaults: [SheetModeRule] = [
        SheetModeRule(when: "preset_in", presets: ["standup", "client_sync"], mode: "quick"),
        SheetModeRule(when: "earlier_sheet", mode: "quick"),
        SheetModeRule(when: "preset_in", presets: ["sales_intro", "internal_presentation", "interview"], mode: "expert"),
        SheetModeRule(when: "new_external_domain", mode: "expert"),
        SheetModeRule(when: "internal", mode: "quick"),
    ]
}

public enum SheetModeDecider {
    /// The mode a new sheet opens in, the same as livetips_m0.sheet.presets.default_mode.
    /// presetBase: the shared preset a user preset was made from (its rules apply to the copy).
    public static func decide(rules: [SheetModeRule], preset: String, presetBase: String? = nil, presetMode: String,
                              earlierSheet: Bool, theirDomains: [String], knownDomains: [String], theirCount: Int) -> SheetMode {
        let known = Set(knownDomains.map { $0.lowercased() })
        let domains = Set(theirDomains.map { $0.lowercased() }.filter { !$0.isEmpty })
        for r in rules where r.off != true {
            let hit: Bool
            switch r.when {
            case "preset_in": hit = (r.presets ?? []).contains(preset) || (presetBase.map { (r.presets ?? []).contains($0) } ?? false)
            case "earlier_sheet": hit = earlierSheet
            case "new_external_domain": hit = !domains.subtracting(known).isEmpty
            case "internal": hit = theirCount == 0
            default: hit = false
            }
            if hit { return SheetMode(rawValue: r.mode) }
        }
        return SheetMode(rawValue: presetMode.isEmpty ? "quick" : presetMode)
    }
}

// MARK: - Refresh banner

public struct SheetDiffCounts: Equatable {
    public var new: Int, changed: Int, gone: Int, keptEdits: Int
    public var isEmpty: Bool { new + changed + gone == 0 }
    public init(new: Int, changed: Int, gone: Int, keptEdits: Int) { self.new = new; self.changed = changed; self.gone = gone; self.keptEdits = keptEdits }

    /// From sheet.diff when the sidecar wrote it, else from the diff marks on the facts. keptEdits: protected facts
    /// (edited by the person) that Refresh left as they were.
    public static func of(_ s: MeetingSheet) -> SheetDiffCounts {
        let facts = s.blocks.flatMap(\.facts)
        let kept = s.diff == nil && facts.allSatisfy({ $0.diff == nil }) ? 0 : keptEdits(s)
        if let d = s.diff {
            return SheetDiffCounts(new: d.new?.count ?? 0, changed: d.changed?.count ?? 0, gone: d.gone?.count ?? 0, keptEdits: kept)
        }
        return SheetDiffCounts(new: facts.filter { $0.diff == .new }.count, changed: facts.filter { $0.diff == .changed }.count,
                               gone: facts.filter { $0.diff == .gone }.count, keptEdits: kept)
    }

    // 0.10.0 (Meeting Sheet, polish): only the person's own edits count: a block marked edited_by_user counts once,
    // and in other blocks a fact with status edited or origin user that Refresh kept (merge.py drops its diff mark).
    // A protected-looking fact that arrived with a diff mark (new, changed, gone) is not a kept edit.
    public static func keptEdits(_ s: MeetingSheet) -> Int {
        s.blocks.reduce(0) { n, b in
            b.editedByUser ? n + 1 : n + b.facts.filter { $0.isProtected && $0.diff == nil }.count
        }
    }
}

// MARK: - Edits on the sheet

public enum SheetEdit {
    /// An inline edit: the text changes, the fact becomes `edited` (Refresh never overwrites it) and its block is
    /// marked edited_by_user. An empty text is not saved.
    @discardableResult
    public static func editFact(_ s: inout MeetingSheet, factID: String, text: String, now: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        for bi in s.blocks.indices {
            if let fi = s.blocks[bi].facts.firstIndex(where: { $0.id == factID }) {
                guard s.blocks[bi].facts[fi].text != t || s.blocks[bi].facts[fi].status != .edited else { return false }
                s.blocks[bi].facts[fi].text = t
                s.blocks[bi].facts[fi].status = .edited
                s.blocks[bi].facts[fi].checkedAt = now
                s.blocks[bi].facts[fi].conflictWith = nil
                s.blocks[bi].editedByUser = true
                return true
            }
        }
        return false
    }

    /// A fact typed by the person into a block (origin user, status edited).
    @discardableResult
    public static func addFact(_ s: inout MeetingSheet, blockType: BlockType, text: String, label: String? = nil, now: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if s.blocks.firstIndex(where: { $0.type == blockType }) == nil {
            let order = (s.blocks.map(\.order).max() ?? 0) + 1
            s.blocks.append(SheetBlock(id: "b-" + blockType.rawValue, type: blockType, title: blockTitle(blockType), visible: true,
                                       onlyIfData: false, order: order, method: nil, facts: [], editedByUser: true))
        }
        let bi = s.blocks.firstIndex(where: { $0.type == blockType })!
        var n = s.blocks[bi].facts.count + 1
        let taken = Set(s.blocks.flatMap(\.facts).map(\.id))
        while taken.contains("u-\(blockType.rawValue)-\(n)") { n += 1 }
        let id = "u-\(blockType.rawValue)-\(n)"
        s.blocks[bi].facts.append(SheetFact(id: id, label: label, text: t, sourceIds: [], locator: nil, checkedAt: now, status: .edited,
                                            conflictWith: nil, origin: .user, value: nil, diff: nil))
        s.blocks[bi].editedByUser = true
        return id
    }

    public enum BlockAction: String { case hide, show, moveUp, moveDown, delete }

    /// Block menu: hide or show for this meeting, move up or down among the shown order, delete.
    @discardableResult
    public static func block(_ s: inout MeetingSheet, id: String, _ a: BlockAction) -> Bool {
        guard let i = s.blocks.firstIndex(where: { $0.id == id }) else { return false }
        switch a {
        case .hide: s.blocks[i].visible = false
        case .show: s.blocks[i].visible = true
        case .delete: s.blocks.remove(at: i); return true
        case .moveUp, .moveDown:
            let sorted = s.blocks.indices.sorted { s.blocks[$0].order < s.blocks[$1].order }
            guard let pos = sorted.firstIndex(of: i) else { return false }
            let other = a == .moveUp ? pos - 1 : pos + 1
            guard other >= 0 && other < sorted.count else { return false }
            // Renumber in order first so equal orders never block a move.
            for (k, bi) in sorted.enumerated() { s.blocks[bi].order = k }
            let j = sorted[other]
            let o = s.blocks[i].order; s.blocks[i].order = s.blocks[j].order; s.blocks[j].order = o
        }
        s.blocks[i].editedByUser = true
        return true
    }

    public enum ConflictChoice: Equatable { case use(String), keepBoth }

    /// A conflict settled: "Use A" keeps A (found, protected as edited by the person) and removes the facts it
    /// disagreed with; "Keep both, ask" keeps both as needs_check and adds a question for the call.
    @discardableResult
    public static func settle(_ s: inout MeetingSheet, factID: String, _ c: ConflictChoice, now: String, question: String? = nil) -> Bool {
        guard let a = s.fact(id: factID) else { return false }
        let group = Set([factID] + (a.conflictWith ?? []))
        switch c {
        case .use(let keep):
            guard group.contains(keep) else { return false }
            for bi in s.blocks.indices {
                s.blocks[bi].facts.removeAll { group.contains($0.id) && $0.id != keep }
                if let fi = s.blocks[bi].facts.firstIndex(where: { $0.id == keep }) {
                    s.blocks[bi].facts[fi].status = .edited
                    s.blocks[bi].facts[fi].conflictWith = nil
                    s.blocks[bi].facts[fi].checkedAt = now
                    s.blocks[bi].editedByUser = true
                }
            }
        case .keepBoth:
            for bi in s.blocks.indices {
                for fi in s.blocks[bi].facts.indices where group.contains(s.blocks[bi].facts[fi].id) {
                    s.blocks[bi].facts[fi].status = .needsCheck
                    s.blocks[bi].facts[fi].conflictWith = nil
                }
            }
            if let q = question { addFact(&s, blockType: .questions, text: q, now: now) }
        }
        return true
    }

    /// A gap's quick action that changes the sheet itself; the readiness is computed again by the sidecar after.
    /// dropCheck: this check is off for this meeting. markChecked: the person says the fact is right.
    /// addQuestion: a question for the call from the gap text.
    @discardableResult
    public static func closeGap(_ s: inout MeetingSheet, gapID: String, action: GapAction, now: String, question: String? = nil) -> Bool {
        guard var r = s.readiness, let g = (r.gaps ?? []).first(where: { $0.id == gapID }) else { return false }
        switch action {
        case .dropCheck:
            var d = r.dropped ?? []
            if !d.contains(g.id) { d.append(g.id) }
            r.dropped = d
        case .markChecked:
            if let f = g.fact {
                for bi in s.blocks.indices {
                    if let fi = s.blocks[bi].facts.firstIndex(where: { $0.id == f }) {
                        s.blocks[bi].facts[fi].status = .edited
                        s.blocks[bi].facts[fi].checkedAt = now
                        s.blocks[bi].facts[fi].conflictWith = nil
                        s.blocks[bi].editedByUser = true
                    }
                }
            } else {
                var d = r.dropped ?? []
                if !d.contains(g.id) { d.append(g.id) }
                r.dropped = d
            }
        case .addQuestion:
            addFact(&s, blockType: .questions, text: question ?? g.text, now: now)
        default:
            return false
        }
        r.gaps = (r.gaps ?? []).filter { $0.id != gapID }
        if r.state != .ready {
            let left = r.gaps ?? []
            r.state = left.isEmpty ? .ready : (left.contains { $0.severity == .blocker } ? .notReady : .almost)
        }
        s.readiness = r
        return true
    }

    /// Accept all after Refresh: facts marked gone leave, the other marks clear, the banner goes away.
    public static func acceptDiff(_ s: inout MeetingSheet) {
        for bi in s.blocks.indices {
            s.blocks[bi].facts.removeAll { $0.diff == .gone }
            for fi in s.blocks[bi].facts.indices { s.blocks[bi].facts[fi].diff = nil }
        }
        s.diff = nil
    }

    public static func blockTitle(_ t: BlockType) -> String {
        switch t {
        case .header: return "Header"
        case .myFocus: return "My focus"
        case .overview: return "Overview"
        case .company: return "About the company"
        case .signals: return "Signals"
        case .techStack: return "Tech stack"
        case .fit: return "Fit for us"
        case .contact: return "About the contact"
        case .qualification: return "Qualification"
        case .history: return "Conversation history"
        case .projectContext: return "Project context"
        case .agenda: return "Agenda"
        case .actionItems: return "Open action items"
        case .questions: return "Questions for the call"
        case .bestOutcome: return "Best outcome"
        case .redLines: return "Red lines and risks"
        case .structureRoles: return "Structure and roles"
        case .gaps: return "Conflicts and gaps"
        case .standupSince: return "Since last time"
        case .standupToday: return "On you today"
        case .standupBlockers: return "Blockers"
        case .standupWaiting: return "Waiting on others"
        case .interviewCandidate: return "The candidate"
        case .interviewRole: return "The role"
        default: return t.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

// MARK: - Export rendering

public struct SheetExportOptions: Equatable {
    public enum SourcesStyle: String { case footnotes, inline }
    public var sources: SourcesStyle = .footnotes
    public var blocks: Set<String>? = nil          // block ids; nil = every shown block
    public var colleague = false                   // "For a colleague": no internal blocks
    public init(sources: SourcesStyle = .footnotes, blocks: Set<String>? = nil, colleague: Bool = false) {
        self.sources = sources; self.blocks = blocks; self.colleague = colleague
    }
    /// Blocks that stay with the PM: never in the colleague template.
    public static let internalBlocks: Set<BlockType> = [.myFocus, .redLines]
}

public enum SheetExport {
    /// The blocks an export takes, in order.
    public static func blocks(_ s: MeetingSheet, _ o: SheetExportOptions) -> [SheetBlock] {
        s.shownBlocks.filter { b in
            (o.blocks == nil || o.blocks!.contains(b.id)) && !(o.colleague && SheetExportOptions.internalBlocks.contains(b.type))
        }.map { b in
            // 0.10.0 (Meeting Sheet, round 2): a value replaced by a newer one (superseded_by) is not exported
            var c = b
            c.facts = b.facts.filter { $0.supersededBy == nil }
            return c
        }
    }

    /// The sources cited by the exported facts, numbered as in the sheet.
    public static func cited(_ s: MeetingSheet, _ bl: [SheetBlock]) -> [SheetSource] {
        let ids = Set(bl.flatMap(\.facts).flatMap(\.sourceIds))
        return s.sources.filter { ids.contains($0.id) }.sorted { $0.n < $1.n }
    }

    static func statusNote(_ f: SheetFact) -> String {
        switch f.status {
        case .notFound: return " (not found)"
        case .needsCheck: return " (check)"
        case .conflict: return " (sources disagree)"
        case .stale: return " (old)"
        default: return ""
        }
    }

    static func link(_ src: SheetSource) -> String? { src.uri ?? src.path.map { "file://" + $0 } }

    public static func markdown(_ s: MeetingSheet, _ o: SheetExportOptions = SheetExportOptions()) -> String {
        let bl = blocks(s, o)
        var out = "# " + s.title + "\n\n"
        if let g = s.goal, !g.isEmpty { out += "**Goal:** " + g + "\n\n" }
        for b in bl {
            out += "## " + b.title + "\n\n"
            if b.facts.isEmpty { out += "- Not found\n\n"; continue }
            for f in b.facts where f.diff != .gone {
                var line = "- " + (f.label.map { "**\($0):** " } ?? "") + f.text + statusNote(f)
                for id in f.sourceIds {
                    guard let src = s.source(id: id) else { continue }
                    if o.sources == .footnotes { line += "[^\(src.n)]" }
                    else if let l = link(src) { line += " ([\(src.n)](\(l)))" } else { line += " (\(src.n))" }
                }
                out += line + "\n"
            }
            out += "\n"
        }
        let cs = cited(s, bl)
        if !cs.isEmpty {
            if o.sources == .footnotes {
                for src in cs { out += "[^\(src.n)]: " + src.title + (link(src).map { " " + $0 } ?? "") + "\n" }
            } else {
                out += "## Sources\n\n"
                for src in cs { out += "\(src.n). " + src.title + (link(src).map { " " + $0 } ?? "") + "\n" }
            }
        }
        return out
    }

    public static func esc(_ t: String) -> String {
        t.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// HTML for PDF and rich text: the same content as the Markdown, footnotes as numbered superscripts.
    public static func html(_ s: MeetingSheet, _ o: SheetExportOptions = SheetExportOptions()) -> String {
        let bl = blocks(s, o)
        var out = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>\(esc(s.title))</title><style>"
            + "body{font:13px -apple-system,Helvetica,sans-serif;color:#1d1d1f;margin:32px;max-width:720px}"
            + "h1{font-size:22px}h2{font-size:15px;margin-top:20px;border-bottom:1px solid #ddd;padding-bottom:3px}"
            + "li{margin:3px 0}sup{color:#0058b0}.st{color:#e8590c}.src{font-size:11px;color:#555}</style></head><body>"
        out += "<h1>\(esc(s.title))</h1>"
        if let g = s.goal, !g.isEmpty { out += "<p><b>Goal:</b> \(esc(g))</p>" }
        for b in bl {
            out += "<h2>\(esc(b.title))</h2><ul>"
            if b.facts.isEmpty { out += "<li class=\"st\">Not found</li>" }
            for f in b.facts where f.diff != .gone {
                var li = "<li>" + (f.label.map { "<b>\(esc($0)):</b> " } ?? "") + esc(f.text)
                let note = statusNote(f)
                if !note.isEmpty { li += "<span class=\"st\">\(esc(note))</span>" }
                for id in f.sourceIds {
                    guard let src = s.source(id: id) else { continue }
                    if o.sources == .footnotes { li += "<sup>\(src.n)</sup>" }
                    else if let l = link(src) { li += " <a href=\"\(esc(l))\">[\(src.n)]</a>" } else { li += " [\(src.n)]" }
                }
                out += li + "</li>"
            }
            out += "</ul>"
        }
        let cs = cited(s, bl)
        if !cs.isEmpty {
            out += "<h2>Sources</h2><ol class=\"src\">"
            for src in cs {
                out += "<li value=\"\(src.n)\">\(esc(src.title))" + (link(src).map { " <a href=\"\(esc($0))\">\(esc($0))</a>" } ?? "") + "</li>"
            }
            out += "</ol>"
        }
        return out + "</body></html>"
    }
}

// MARK: - Small edits used by the Readiness quick actions

public extension SheetEdit {
    /// assign_owner: the person who leads an agenda point or an action item.
    @discardableResult
    static func setOwner(_ s: inout MeetingSheet, factID: String, owner: String) -> Bool {
        let o = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !o.isEmpty else { return false }
        for bi in s.blocks.indices {
            if let fi = s.blocks[bi].facts.firstIndex(where: { $0.id == factID }) {
                var v = s.blocks[bi].facts[fi].value ?? FactValue(level: nil, key: nil, owner: nil, due: nil)
                v.owner = o
                s.blocks[bi].facts[fi].value = v
                s.blocks[bi].editedByUser = true
                return true
            }
        }
        return false
    }

    /// The qualification method chosen in the block header (rules/sales.yaml key).
    @discardableResult
    static func setMethod(_ s: inout MeetingSheet, blockID: String, method: String) -> Bool {
        guard let i = s.blocks.firstIndex(where: { $0.id == blockID }) else { return false }
        s.blocks[i].method = method
        s.blocks[i].editedByUser = true
        return true
    }

    /// The blocks of a preset as a sheet would get them (for the Blocks step before the first build).
    static func emptyBlocks(_ types: [String], titles: [String: String] = [:], onlyIfData: Set<String> = []) -> [SheetBlock] {
        types.enumerated().map { i, t in
            let bt = BlockType(rawValue: t)
            return SheetBlock(id: "b-" + t, type: bt, title: titles[t] ?? blockTitle(bt), visible: true, onlyIfData: onlyIfData.contains(t),
                              order: i, method: bt == .qualification ? "bant" : nil, facts: [], editedByUser: false)
        }
    }
}

// 0.10.0 (Meeting Sheet, polish): a not_found fact whose text only repeats the status ("Not found", empty) shows the
// label and the chip, not "Budget: Not found" next to a "Not found" chip. Same list as derive.is_placeholder.
public extension SheetFact {
    static func isPlaceholder(_ text: String) -> Bool {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix(".") { t.removeLast() }
        return ["", "not found", "не знайдено", "n/a", "unknown"].contains(t.trimmingCharacters(in: .whitespaces).lowercased())
    }
    /// The text the sheet shows next to the label.
    var shownText: String { status == .notFound && Self.isPlaceholder(text) ? "" : text }
}

// 0.10.0 (Meeting Sheet, polish): the right column "On this sheet" (mockup S6): per block the facts shown, not found and
// conflicts (one per pair, as the sheet shows them); replaced facts ("was X") do not count.
public struct SheetBlockCount: Equatable {
    public var facts: Int, notFound: Int, conflicts: Int
    public init(facts: Int, notFound: Int, conflicts: Int) { self.facts = facts; self.notFound = notFound; self.conflicts = conflicts }

    public static func of(_ b: SheetBlock) -> SheetBlockCount {
        var partners = Set<String>()
        let shown = b.facts.filter { f in
            guard f.supersededBy == nil else { return false }
            if f.status == .conflict {
                if partners.contains(f.id) { return false }
                partners.formUnion(f.conflictWith ?? [])
            }
            return true
        }
        return SheetBlockCount(facts: shown.count, notFound: shown.filter { $0.status == .notFound }.count,
                               conflicts: shown.filter { $0.status == .conflict }.count)
    }

    /// The whole sheet by status, for the legend: found, not found, check, conflict, old, edited.
    public static func statuses(_ s: MeetingSheet) -> [(FactStatus, Int)] {
        let all = s.shownBlocks.flatMap { b in b.facts.filter { $0.supersededBy == nil } }
        let pairs = s.shownBlocks.reduce(0) { $0 + of($1).conflicts }
        return [FactStatus.found, .notFound, .needsCheck, .conflict, .stale, .edited].map { st in
            (st, st == .conflict ? pairs : all.filter { $0.status == st }.count)
        }
    }
}
