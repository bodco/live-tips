import AppKit
import SwiftUI
import LiveTipsCore

// Pacenote 0.8 (F3): what Home knows about calls already held, from their own files. The tips engine writes the
// call picture ("situation": decisions, what the PM took on, open questions to the PM) into the call's tips file;
// its last line is the outcome of the call (Recent's "2 decisions · 1 on you · 1 open question").

struct CallOutcome: Equatable {
    var decisions: [String] = []
    var decisionBy: [String] = []       // theme pass stage 2: who made each decision, same order ("" when nobody is named)
    var onMe: [String] = []             // what the PM took on
    var openQuestions: [String] = []    // questions to the PM still open at the end
    var theirs: [(who: String, what: String)] = []   // 0.8: promises made to the PM's side
    var risks: [String] = []            // 0.8: risks heard on the call (rules/risks.yaml)
    var tasks: [CallLists.Task] = []    // 0.12.2 (L4): the one-rule tasks, for a call whose register has none

    static func == (a: CallOutcome, b: CallOutcome) -> Bool {
        a.decisions == b.decisions && a.decisionBy == b.decisionBy && a.onMe == b.onMe && a.openQuestions == b.openQuestions && a.risks == b.risks
            && a.theirs.map { $0.who + "|" + $0.what } == b.theirs.map { $0.who + "|" + $0.what } && a.tasks == b.tasks
    }

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
    /// 0.12.2 (L2): decisions follow the one rule (CallLists: the PM's edit, Meeting notes, live picture, older notes),
    /// so Home, Export, follow-up, CRM, Memory and the call page agree; a call with decisions only in its notes has an
    /// outcome too.
    static func read(transcript file: String) -> CallOutcome? {
        let lists = CallLists.read(transcript: file)
        var c = readSituation(transcript: file)
        let folder = (file as NSString).deletingLastPathComponent
        let reg = CommitmentRegister.load(folder: folder)
            .filter { CommitmentRegister.callKey($0.call) == CommitmentRegister.callKey(file) && $0.status != "dropped" }
        if c == nil, !(lists.isEmpty && reg.isEmpty) { c = CallOutcome() }
        c?.decisions = lists.decisions
        c?.decisionBy = lists.decisionItems.map(\.by)
        c?.risks = lists.risks          // 0.12.2 (L3): risks by the same rule
        c?.tasks = lists.tasks
        // 0.12.2 (L4): on you and on them from the register (the store), else by the one rule
        if !reg.isEmpty {
            c?.onMe = reg.filter(\.mine).map(\.text)
            c?.theirs = reg.filter { !$0.mine }.map { (who: $0.owner, what: $0.text) }
        } else if !lists.tasks.isEmpty {
            c?.onMe = lists.tasks.filter { $0.mine ?? $0.owner.isEmpty }.map(\.text)
            c?.theirs = lists.tasks.filter { !($0.mine ?? $0.owner.isEmpty) }.map { (who: $0.owner, what: $0.text) }
        }
        return c
    }

    private static func readSituation(transcript file: String) -> CallOutcome? {
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
                c.theirs = ((o["theirs"] as? [[String: Any]]) ?? []).compactMap { d in
                    guard let w = d["what"] as? String, !w.isEmpty else { return nil }
                    return (who: (d["who"] as? String) ?? "", what: w)
                }
                c.risks = ((o["risks"] as? [[String: Any]]) ?? []).compactMap { $0["what"] as? String }.filter { !$0.isEmpty }
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
        let m = [file + ".tips.jsonl", stem + ".tips.jsonl", CallLists.notesPath(transcript: file),   // 0.12.2: notes bring decisions
                 CommitmentRegister.path(folder: (file as NSString).deletingLastPathComponent)]           // and the register tasks
            .compactMap { (try? fm.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }.max() ?? .distantPast
        if let c = cache[file], c.0 == m { return c.1 }
        let o = CallOutcome.read(transcript: file)
        cache[file] = (m, o)
        return o
    }
}

// "On you" on Home reads the commitments register since Pacenote 0.8 (Register.swift, rules/commitments.yaml).
