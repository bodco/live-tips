import AppKit
import LiveTipsCore

/// 2026-10-28 (owner): every correction the PM makes, in one log for all calls, to learn from it: find
/// patterns and make the next preparations better. Cards and On me lines corrected, added or hidden in the
/// tips window, the preparation edited (before the call or during it), the call renamed.
/// Application Support/LiveTips/edits.jsonl, one JSON object per line. Nothing leaves the Mac; each new
/// preparation reads the corrections of the same meeting and project (PrepRunner) and the skill does too.
enum EditLog {
    static var url: URL { AppPaths.support.appendingPathComponent("edits.jsonl") }

    /// "PM Stand-Up" -> "pmstandup": the same meeting whatever the punctuation.
    static func seriesKey(_ title: String) -> String {
        title.lowercased().replacingOccurrences(of: "[^\\p{L}\\p{N}]", with: "", options: .regularExpression)
    }

    static func add(kind: String, title: String, project: String, file: String = "", fields: [String: Any] = [:]) {
        var r = fields
        r["at"] = ISO8601DateFormatter().string(from: Date())
        r["kind"] = kind
        r["title"] = title
        r["series"] = seriesKey(title)
        r["project"] = project
        if !file.isEmpty { r["file"] = (file as NSString).lastPathComponent }
        guard JSONSerialization.isValidJSONObject(r), let d = try? JSONSerialization.data(withJSONObject: r, options: [.sortedKeys]) else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        h.seekToEndOfFile(); h.write(d); h.write(Data([0x0A])); try? h.close()
    }

    /// A preparation edited: only what changed (lines removed and added), not the whole document.
    static func addBriefEdit(title: String, project: String, file: String, before: String, after: String, when: String) {
        let a = before.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let b = after.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let sa = Set(a), sb = Set(b)
        let removed = a.filter { !sb.contains($0) }.prefix(40).map { String($0.prefix(300)) }
        let added = b.filter { !sa.contains($0) }.prefix(40).map { String($0.prefix(300)) }
        guard !removed.isEmpty || !added.isEmpty else { return }
        add(kind: "brief_edit", title: title, project: project, file: file,
            fields: ["when": when, "removed": Array(removed), "added": Array(added)])
    }

    /// The newest records, same meeting first, then the same project.
    static func recent(title: String, project: String, limit: Int = 30) -> [[String: Any]] {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let key = seriesKey(title)
        var same: [[String: Any]] = [], proj: [[String: Any]] = []
        for ln in s.split(separator: "\n").reversed() {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(ln.utf8))) as? [String: Any] else { continue }
            if !key.isEmpty, (o["series"] as? String) == key { same.append(o) }
            else if !project.isEmpty, (o["project"] as? String) == project { proj.append(o) }
            if same.count >= limit { break }
        }
        return Array((same + proj).prefix(limit))
    }

    /// For the preparation prompt: what the PM corrected before, to learn from.
    static func promptBlock(title: String, project: String) -> String {
        // 0.8.5 (rules/learning.yaml): the corrections made on two or more different calls first, for every call.
        let standing = Learning.prompt(Learning.standing(all(), kinds: ["brief_edit", "talk_edit", "card_onme_remove", "card_onme_edit"]))
        let list = recent(title: title, project: project)
        guard !list.isEmpty else { return standing }
        var lines: [String] = []
        for o in list {
            var r = o; r.removeValue(forKey: "series")
            if let d = try? JSONSerialization.data(withJSONObject: r, options: [.sortedKeys]), let t = String(data: d, encoding: .utf8) {
                lines.append("  " + String(t.prefix(1500)))
            }
        }
        return """
        The PM's corrections to earlier preparations and tips (\(url.path), newest first; same meeting first, then \
        the same project). Learn from them before writing: what he removes (do not write that kind of content again), \
        what he rewrites (use his wording and level of detail), what he adds (cover it this time without being asked), \
        names and facts he fixes (use the fixed ones). Say in the brief's sources line how many corrections were used. \
        A correction that contradicts a newer source loses.
        \(lines.joined(separator: "\n"))
        \(standing)
        """
    }

    static func count() -> Int {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return s.split(separator: "\n").count
    }
}
