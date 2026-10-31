import AppKit
import SwiftUI
import LiveTipsCore

// Pacenote 0.8.5 (PRESENTATION-SPEC P7; rules/followup.yaml, rules/learning.yaml): right after End call the tips window
// shows the call's outcome, the series and the follow-up. "Write draft" makes the draft; the PM changes it in his own
// words ("drop the pricing line", "shorter") or by hand. Every instruction and hand edit is logged (EditLog) and the
// instructions given on two or more different calls are applied to every next draft. Nothing is sent: Copy and Open in
// Mail only.

@MainActor
final class FollowUpModel: ObservableObject {
    static var byFile: [String: FollowUpModel] = [:]
    static func of(_ file: String) -> FollowUpModel {
        if let m = byFile[file] { return m }
        let m = FollowUpModel(file: file); byFile[file] = m; return m
    }

    let file: String
    @Published var subject = ""
    @Published var body = ""
    @Published var busy = false
    @Published var error = ""
    @Published var instructions: [String] = []
    private var lastWritten = ""                     // the text as Pacenote wrote it, to log the PM's hand edits
    var onChange: (() -> Void)?

    init(file: String) { self.file = file }

    var title: String { CallPageView.title(file) }
    var project: String { CallHistory.shared.records.first { $0.file == file }?.project ?? "" }
    var lang: String { FollowUpWindow.language(of: file) }

    /// The PM's recurring follow-up corrections (rules/learning.yaml > standing).
    static func lessons() -> String {
        Learning.prompt(Learning.standing(EditLog.all(), kinds: ["followup_instruction", "followup_edit"]))
    }

    func write() {
        UsageLog.log("followup_written")
        busy = true; error = ""; onChange?()
        let c = AppConfig.load(from: AppPaths.config)
        var args = ["--md", file, "--lang", lang, "--model", c.models.tip]
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("pacenote-lessons-\(UUID().uuidString).txt")
        let l = Self.lessons()
        if !l.isEmpty, (try? l.write(toFile: tmp, atomically: true, encoding: .utf8)) != nil { args += ["--lessons", tmp] }
        PyTool.run("followup", args) { [weak self] r in
            try? FileManager.default.removeItem(atPath: tmp)
            guard let self = self else { return }
            self.busy = false
            if (r["ok"] as? Bool) == true {
                self.subject = r["subject"] as? String ?? ""; self.body = r["body"] as? String ?? ""; self.lastWritten = self.body
            } else { self.error = L("followup.failed", ["err": r["error"] as? String ?? ""]) }
            self.onChange?()
        }
    }

    /// "Drop the pricing line": the instruction is applied to the current text and logged.
    func revise(_ instruction: String) {
        let i = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !i.isEmpty, !body.isEmpty else { return }
        logHandEdits()
        EditLog.add(kind: "followup_instruction", title: title, project: project, file: file, fields: ["text": i])
        instructions.append(i)
        busy = true; error = ""; onChange?()
        let c = AppConfig.load(from: AppPaths.config)
        let tmp = (NSTemporaryDirectory() as NSString).appendingPathComponent("pacenote-draft-\(UUID().uuidString).json")
        if let d = try? JSONSerialization.data(withJSONObject: ["subject": subject, "body": body]) { try? d.write(to: URL(fileURLWithPath: tmp)) }
        PyTool.run("followup", ["--md", file, "--lang", lang, "--model", c.models.tip, "--draft", tmp, "--instruction", i]) { [weak self] r in
            try? FileManager.default.removeItem(atPath: tmp)
            guard let self = self else { return }
            self.busy = false
            if (r["ok"] as? Bool) == true {
                self.subject = r["subject"] as? String ?? self.subject; self.body = r["body"] as? String ?? self.body; self.lastWritten = self.body
            } else { self.error = L("followup.failed", ["err": r["error"] as? String ?? ""]) }
            self.onChange?()
        }
    }

    /// The PM changed the text by hand: only the lines removed and added go to the log (as for the brief).
    func logHandEdits() {
        guard !lastWritten.isEmpty, body != lastWritten else { return }
        let a = lastWritten.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let b = body.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let removed = a.filter { !Set(b).contains($0) }.prefix(20).map { String($0.prefix(300)) }
        let added = b.filter { !Set(a).contains($0) }.prefix(20).map { String($0.prefix(300)) }
        if !removed.isEmpty || !added.isEmpty {
            EditLog.add(kind: "followup_edit", title: title, project: project, file: file, fields: ["removed": Array(removed), "added": Array(added)])
        }
        lastWritten = body
    }

    func copy() {
        UsageLog.log("followup_copied")
        logHandEdits()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString((subject.isEmpty ? "" : subject + "\n\n") + body, forType: .string)
    }

    /// A mailto link: Mail opens a new message with the text; the PM adds the people and sends it.
    func openMail() {
        UsageLog.log("followup_open_mail")
        logHandEdits()
        var u = URLComponents(); u.scheme = "mailto"; u.path = ""
        u.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        if let url = u.url { NSWorkspace.shared.open(url) }
    }
}

extension EditLog {
    /// Every record, oldest first (for the patterns of rules/learning.yaml).
    static func all() -> [[String: Any]] {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }
}

/// What the tips window shows right after End call (P7).
enum AfterCall {
    @MainActor static func state(file: String) -> [String: Any] {
        let rec = CallHistory.shared.records.first { $0.file == file }
        let o = CallOutcome.read(transcript: file) ?? CallOutcome()
        let fu = FollowUpModel.of(file)
        let f = CallPageView.fmt("EEEdMMMHHmm")
        var d: [String: Any] = [
            "title": rec?.title ?? CallPageView.title(file),
            "when": rec.map { f.string(from: $0.start) } ?? "",
            "dur": rec?.minutes.map { "\(Int($0.rounded())) " + L("deck.min") } ?? "",
            "people": people(file).joined(separator: ", "),
            "notion": rec?.notionURL ?? "",
            "decisions": o.decisions, "onMe": o.onMe, "open": o.openQuestions,
            "draft": ["subject": fu.subject, "body": fu.body, "busy": fu.busy, "error": fu.error, "instructions": fu.instructions],
            "lessons": Learning.standing(EditLog.all(), kinds: ["followup_instruction", "followup_edit"]).count
        ]
        if let r = rec {
            let s = CallPageView.series(of: r)
            if s.count > 1 {
                let key = CommitmentRegister.seriesKey(project: r.project, title: r.title)
                let next = UpNext.shared.items.first { m in
                    CommitmentRegister.seriesKey(project: m.project?.slug ?? "", title: m.effectiveTitle) == key || EditLog.seriesKey(m.effectiveTitle) == EditLog.seriesKey(r.title)
                }
                d["series"] = ["name": r.title, "n": s.count, "next": next.map { CallPageView.fmt("EEEHHmm").string(from: $0.callDate) } ?? ""]
            }
        }
        return d
    }

    /// The other people on the call (the speaker names), for "To ..." and the meta line.
    @MainActor static func people(_ file: String) -> [String] {
        let stem = file.hasSuffix(".md") ? String(file.dropLast(3)) : file
        guard let d = FileManager.default.contents(atPath: stem + ".speakers.json"),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return [] }
        var names: [String] = []
        for (_, v) in o { if let x = v as? [String: Any], let n = x["name"] as? String, !n.isEmpty, !names.contains(n) { names.append(n) } }
        return names.sorted()
    }
}

extension PrompterController {
    func pushAfter() {
        guard !transcriptPath.isEmpty else { return }
        let file = stem + ".md"
        let fu = FollowUpModel.of(file)
        fu.onChange = { [weak self] in self?.pushAfter() }
        let st = AfterCall.state(file: file)
        if let d = try? JSONSerialization.data(withJSONObject: st), let js = String(data: d, encoding: .utf8) {
            push("window.LiveTips && LiveTips.setAfter(" + js + ")")
        }
    }

    func handleAfter(_ d: [String: Any]) {
        let file = stem + ".md"
        let fu = FollowUpModel.of(file)
        fu.onChange = { [weak self] in self?.pushAfter() }
        if let b = d["body"] as? String { fu.body = b }
        if let s = d["subject"] as? String { fu.subject = s }
        switch d["item"] as? String ?? "" {
        case "write": fu.write()
        case "revise": fu.revise(d["instruction"] as? String ?? "")
        case "edited": fu.logHandEdits()
        case "copy": fu.copy()
        case "mail": fu.openMail()
        case "notion":
            if let u = CallHistory.shared.records.first(where: { $0.file == file })?.notionURL.flatMap({ URL(string: $0) }) { NSWorkspace.shared.open(u) }
        case "series":
            if let r = CallHistory.shared.records.first(where: { $0.file == file }) { SeriesWindow.show(record: r) }
        case "callpage": CallPageWindow.show(file: file)
        case "done": fu.logHandEdits(); window.close()
        default: break
        }
        pushAfter()
    }
}
