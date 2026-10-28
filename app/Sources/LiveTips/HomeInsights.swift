import AppKit
import SwiftUI
import LiveTipsCore

// Pacenote 0.8 (F3): what Home knows about calls already held, from their own files. The tips engine writes the
// call picture ("situation": decisions, what the PM took on, open questions to the PM) into the call's tips file;
// its last line is the outcome of the call. Until the commitments register (F5, idea 01) these are read-only.

struct CallOutcome: Equatable {
    var decisions: [String] = []
    var onMe: [String] = []             // what the PM took on
    var openQuestions: [String] = []    // questions to the PM still open at the end

    var isEmpty: Bool { decisions.isEmpty && onMe.isEmpty && openQuestions.isEmpty }

    /// "2 decisions · 1 on you · 1 open question" in the interface language.
    var line: String {
        var parts: [String] = []
        if !decisions.isEmpty { parts.append(L(decisions.count == 1 ? "home.outcome.decision" : "home.outcome.decisions", ["n": "\(decisions.count)"])) }
        if !onMe.isEmpty { parts.append(L("home.outcome.onYou", ["n": "\(onMe.count)"])) }
        if !openQuestions.isEmpty { parts.append(L(openQuestions.count == 1 ? "home.outcome.question" : "home.outcome.questions", ["n": "\(openQuestions.count)"])) }
        return parts.joined(separator: " · ")
    }

    /// The last call picture in the call's tips file (the app's <stem>.md.tips.jsonl or the skill's <stem>.tips.jsonl).
    static func read(transcript file: String) -> CallOutcome? {
        let stem = file.hasSuffix(".md") ? String(file.dropLast(3)) : file
        for p in [file + ".tips.jsonl", stem + ".tips.jsonl"] {
            guard let s = try? String(contentsOfFile: p, encoding: .utf8) else { continue }
            for ln in s.split(separator: "\n").reversed() where ln.contains("situation") {
                guard let o = (try? JSONSerialization.jsonObject(with: Data(ln.utf8))) as? [String: Any],
                      (o["kind"] as? String) == "situation" else { continue }
                var c = CallOutcome()
                c.decisions = ((o["decisions"] as? [Any]) ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
                c.onMe = ((o["actions"] as? [[String: Any]]) ?? []).compactMap { $0["what"] as? String }.filter { !$0.isEmpty }
                c.openQuestions = ((o["asks"] as? [[String: Any]]) ?? []).filter { ($0["type"] as? String) != "update" }
                    .compactMap { $0["what"] as? String }.filter { !$0.isEmpty }
                return c
            }
        }
        return nil
    }
}

/// Outcomes read once per file version (Home redraws every 2 s).
@MainActor
final class OutcomeCache {
    static let shared = OutcomeCache()
    private var cache: [String: (Date, CallOutcome?)] = [:]

    func outcome(_ file: String) -> CallOutcome? {
        let stem = file.hasSuffix(".md") ? String(file.dropLast(3)) : file
        let fm = FileManager.default
        let m = [file + ".tips.jsonl", stem + ".tips.jsonl"]
            .compactMap { (try? fm.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }.max() ?? .distantPast
        if let c = cache[file], c.0 == m { return c.1 }
        let o = CallOutcome.read(transcript: file)
        cache[file] = (m, o)
        return o
    }
}

/// "On you" on Home: what the PM took on in recent calls, newest first. A tick hides an item here only; the
/// commitments register (F5) will keep them for real.
@MainActor
enum OnYou {
    struct Item: Identifiable, Hashable { var id: String; var text: String; var project: String; var when: Date; var file: String }

    static var done: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "homeOnYouDone") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).suffix(400), forKey: "homeOnYouDone") }
    }

    static func items(project: String? = nil, days: Double = 14) -> [Item] {
        let since = Date().addingTimeInterval(-days * 86400)
        var seen = Set<String>(), out: [Item] = []
        let closed = done
        for r in CallHistory.shared.visible where r.start > since && (project == nil || r.project == project) {
            for t in OutcomeCache.shared.outcome(r.file)?.onMe ?? [] {
                let key = t.lowercased().trimmingCharacters(in: .whitespaces)
                let id = r.file + "|" + key
                guard !seen.contains(key), !closed.contains(id) else { continue }
                seen.insert(key)
                out.append(Item(id: id, text: t, project: r.project, when: r.start, file: r.file))
            }
        }
        return out
    }
}
