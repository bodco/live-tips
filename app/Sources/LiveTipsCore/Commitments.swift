import CryptoKit
import Foundation

/// Pacenote 0.8 (F5, idea 01): the commitments register, rules/commitments.yaml. One append-only JSON-lines file
/// per project, next to the transcripts (<project>/live/commitments.jsonl), written by the app's engine, the app and
/// the skill. The register is the events folded by id; the same fold as livetips_m0/commitments.py.
public struct Commitment: Equatable, Identifiable {
    public var id: String
    public var text: String
    public var owner: String            // "me" or a name ("on them")
    public var project: String
    public var series: String
    public var call: String             // transcript file name
    public var t: String
    public var created: String          // ISO time
    public var due: String
    public var by: String
    public var status: String = "open"  // open | done | dropped
    public var doneAt = ""
    public var doneSource = ""
    public var folder = ""              // the live folder of the register (set by the reader)
    public var from = ""                // 0.8.6: the id this item replaces ("Mine" on an "on them" item)
    public var notionPage = ""          // 0.8.6 (op link): the Notion task this item is
    public var notionNote = ""          // "removed" when the linked page was removed in Notion

    public var mine: Bool { owner.isEmpty || owner.lowercased() == "me" }
    public var createdDate: Date? { CommitmentRegister.iso(created) }
}

public enum CommitmentRegister {
    public static let fileName = "commitments.jsonl"

    public static func path(folder: String) -> String {
        (folder as NSString).lastPathComponent == fileName ? folder : (folder as NSString).appendingPathComponent(fileName)
    }

    /// The transcript name without folders, ".md" and the app's ".app" part (the app's and the skill's files match).
    public static func callKey(_ call: String) -> String {
        var n = (call as NSString).lastPathComponent
        if n.hasSuffix(".md") { n = String(n.dropLast(3)) }
        return n.replacingOccurrences(of: ".app", with: "")
    }

    /// "<project slug>|<title in lower case, letters and digits only>" (rules/commitments.yaml > series_key).
    public static func seriesKey(project: String, title: String) -> String {
        project + "|" + title.lowercased().replacingOccurrences(of: "[^\\p{L}\\p{N}]", with: "", options: .regularExpression)
    }

    public static func makeID(call: String, owner: String, text: String) -> String {
        let raw = callKey(call) + "|" + owner.trimmingCharacters(in: .whitespaces).lowercased() + "|" + text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hex = Insecure.SHA1.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
        return "c-" + hex.prefix(10)
    }

    static func words(_ s: String) -> Set<String> {
        let rx = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}_']+")
        let low = s.lowercased()
        let r = rx.matches(in: low, range: NSRange(low.startIndex..., in: low)).compactMap { Range($0.range, in: low).map { String(low[$0]) } }
        return Set(r.filter { $0.count > 2 })
    }

    /// At least 60% of the shorter text's words are shared (rules/commitments.yaml > duplicates).
    public static func similar(_ a: String, _ b: String, share: Double = 0.6) -> Bool {
        let x = words(a), y = words(b)
        if x.isEmpty || y.isEmpty { return a.trimmingCharacters(in: .whitespaces).lowercased() == b.trimmingCharacters(in: .whitespaces).lowercased() }
        return Double(x.intersection(y).count) / Double(min(x.count, y.count)) >= share
    }

    public static func fold(_ events: [[String: Any]]) -> [Commitment] {
        var items: [String: Commitment] = [:], order: [String] = [], alias: [String: String] = [:]
        func s(_ e: [String: Any], _ k: String) -> String { (e[k] as? String) ?? "" }
        for e in events {
            let op = s(e, "op"), cid = s(e, "id")
            guard !op.isEmpty, !cid.isEmpty else { continue }
            if op == "add" {
                if items[cid] != nil || alias[cid] != nil { continue }
                let owner = s(e, "owner").isEmpty ? "me" : s(e, "owner")
                if let twin = order.compactMap({ items[$0] }).first(where: { $0.status == "open" && callKey($0.call) == callKey(s(e, "call"))
                        && $0.owner.lowercased() == owner.lowercased() && similar($0.text, s(e, "text")) }) {
                    alias[cid] = twin.id
                    continue
                }
                items[cid] = Commitment(id: cid, text: s(e, "text"), owner: owner, project: s(e, "project"), series: s(e, "series"),
                                        call: s(e, "call"), t: s(e, "t"), created: s(e, "created"), due: s(e, "due"), by: s(e, "by"))
                items[cid]?.from = s(e, "from")
                order.append(cid)
                continue
            }
            guard var it = items[alias[cid] ?? cid] else { continue }
            switch op {
            case "done": it.status = "done"; it.doneAt = s(e, "at"); it.doneSource = s(e, "source").isEmpty ? "manual" : s(e, "source")
            case "reopen": it.status = "open"; it.doneAt = ""; it.doneSource = ""
            case "drop": it.status = "dropped"
            case "link": it.notionPage = s(e, "notion_page"); it.notionNote = ""
            case "unlink": it.notionPage = ""; it.notionNote = (s(e, "reason").isEmpty || s(e, "reason") == "removed") ? "removed" : ""
            default: break
            }
            items[it.id] = it
        }
        return order.compactMap { items[$0] }
    }

    public static func readEvents(folder: String) -> [[String: Any]] {
        guard let text = try? String(contentsOfFile: path(folder: folder), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }

    public static func load(folder: String) -> [Commitment] {
        fold(readEvents(folder: folder)).map { var c = $0; c.folder = folder; return c }
    }

    /// Appends events; never rewrites the file.
    public static func append(folder: String, _ events: [[String: Any]]) {
        guard !events.isEmpty else { return }
        let p = path(folder: folder)
        try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var out = Data()
        for var e in events {
            e["v"] = 1
            if let d = try? JSONSerialization.data(withJSONObject: e, options: [.sortedKeys]) { out.append(d); out.append(0x0A) }
        }
        if let h = FileHandle(forWritingAtPath: p) {
            h.seekToEndOfFile(); h.write(out); try? h.close()
        } else {
            try? out.write(to: URL(fileURLWithPath: p))
        }
    }

    public static func nowISO() -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; f.timeZone = .current
        return f.string(from: Date())
    }

    public static func iso(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    public static func mark(folder: String, id: String, op: String = "done", source: String = "manual", call: String = "",
                            notionPage: String = "") {
        var e: [String: Any] = ["op": op, "id": id, "at": nowISO()]
        if op == "done" { e["source"] = source; if !call.isEmpty { e["call"] = (call as NSString).lastPathComponent } }
        if op == "link" { e["notion_page"] = notionPage }
        if op == "unlink" { e["reason"] = ["removed", "undo"].contains(source) ? source : "removed" }
        append(folder: folder, [e])
    }

    /// A due date from free text: an ISO date, "31.10", "31.10.2026", "10/31", a weekday (English or Ukrainian,
    /// the next one after `from`), "today", "tomorrow". Nil when the text names no date.
    public static func dueDate(_ text: String, from: Date, calendar cal: Calendar = .current) -> Date? {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let start = cal.startOfDay(for: from)
        if let r = t.range(of: "\\d{4}-\\d{2}-\\d{2}", options: .regularExpression) {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
            return f.date(from: String(t[r]))
        }
        if let r = t.range(of: "\\b\\d{1,2}[./]\\d{1,2}([./]\\d{2,4})?\\b", options: .regularExpression) {
            let parts = t[r].split(whereSeparator: { $0 == "." || $0 == "/" }).compactMap { Int($0) }
            let slash = t[r].contains("/")
            var c = cal.dateComponents([.year], from: from)
            c.day = slash ? parts[1] : parts[0]; c.month = slash ? parts[0] : parts[1]
            if parts.count > 2 { c.year = parts[2] < 100 ? 2000 + parts[2] : parts[2] }
            if let d = cal.date(from: c) { return (parts.count < 3 && d < cal.date(byAdding: .month, value: -6, to: start)!) ? cal.date(byAdding: .year, value: 1, to: d) : d }
        }
        if t.contains("today") || t.contains("сьогодні") { return start }
        if t.contains("tomorrow") || t.contains("завтра") { return cal.date(byAdding: .day, value: 1, to: start) }
        let days: [(Int, [String])] = [(2, ["monday", "понеділ"]), (3, ["tuesday", "вівтор"]), (4, ["wednesday", "серед"]),
                                       (5, ["thursday", "четвер"]), (6, ["friday", "п'ятниц", "пʼятниц", "пятниц"]),
                                       (7, ["saturday", "субот"]), (1, ["sunday", "неділ"])]
        for (wd, names) in days where names.contains(where: { t.contains($0) }) {
            var c = DateComponents(); c.weekday = wd
            return cal.nextDate(after: start.addingTimeInterval(-1), matching: c, matchingPolicy: .nextTime)
        }
        return nil
    }

    /// rules/commitments.yaml > order: overdue first, then with a due date (soonest first), then the rest (newest first).
    public static func sorted(_ items: [Commitment], now: Date = Date()) -> [Commitment] {
        let today = Calendar.current.startOfDay(for: now)
        func key(_ c: Commitment) -> (Int, Double) {
            let base = c.createdDate ?? now
            if let d = dueDate(c.due, from: base) { return (d < today ? 0 : 1, d.timeIntervalSince1970) }
            return (2, -(c.createdDate?.timeIntervalSince1970 ?? 0))
        }
        return items.sorted { let a = key($0), b = key($1); return a.0 != b.0 ? a.0 < b.0 : a.1 < b.1 }
    }

    public static func isOverdue(_ c: Commitment, now: Date = Date()) -> Bool {
        guard let d = dueDate(c.due, from: c.createdDate ?? now) else { return false }
        return d < Calendar.current.startOfDay(for: now)
    }
}
