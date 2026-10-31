import AppKit
import Foundation
import LiveTipsCore

/// Pacenote 0.8.8 (rules/decisions.yaml): the pages one call made in Notion (<stem>.notion.json, written by
/// decision_notion and risk_notion), so the call page shows "In register" after a restart and nothing is written twice.
enum NotionCallLinks {
    static func path(_ file: String) -> String { (file.hasSuffix(".md") ? String(file.dropLast(3)) : file) + ".notion.json" }

    /// The same key as notion_links.norm in the engine: lower case, letters and digits, single spaces.
    static func norm(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
    }

    static func all(_ file: String) -> [String: [String: [String: String]]] {
        guard let d = FileManager.default.contents(atPath: path(file)),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: [String: [String: String]]] else { return [:] }
        return o
    }

    /// The page url of an item already written ("" when Notion gave none), nil when it is not in Notion yet.
    static func url(_ file: String, _ kind: String, _ text: String) -> String? {
        all(file)[kind]?[norm(text)].map { $0["url"] ?? "" }
    }
    static func pageId(_ file: String, _ kind: String, _ text: String) -> String? { all(file)[kind]?[norm(text)]?["id"] }
}

/// 0.8.8: the call page redraws its "In register" marks when an automatic add wrote pages.
@MainActor
final class NotionLinksVersion: ObservableObject {
    static let shared = NotionLinksVersion()
    @Published private(set) var n = 0
    func bump() { n += 1 }
}

/// 0.8.8 (rules/decisions.yaml > auto_add, snapshot): the automatic add after a call and the local snapshot of the
/// project's active decisions that the preparation and the live engine read.
@MainActor
enum NotionAutoAdd {
    static var hasToken: Bool { SecretStore(service: Bundle.main.bundleIdentifier ?? "io.github.example.livetips").get(.notionToken) != nil }

    /// 40 s after the call (after the register write), when the PM turned the switches on; never for a hidden call.
    static func afterCall(file: String) {
        if CallHistory.shared.records.first(where: { $0.file == file })?.hidden == true { return }
        NotionTasks.shared.afterCall(file: file)                // Tasks: the 0.8.6 switch, same value
        let c = AppConfig.load(from: AppPaths.config)
        guard hasToken, let p = PyTool.project(of: file).project else { return }
        let call = CallPageView.title(file)
        let source = CallHistory.shared.records.first { $0.file == file }?.notionURL ?? ""
        for (kind, on, db, module) in [("risks", c.notionRisksAutoAdd, NotionTargets.risksDB(c, p), "risk_notion"),
                                       ("decisions", c.notionDecisionsAutoAdd, NotionTargets.decisionsDB(c, p), "decision_notion")] where on && !db.isEmpty {
            let extra = kind == "decisions" && !source.isEmpty ? ["--source", source] : []
            PyTool.run(module, ["--db", db, "--call-file", file, "--from-call", "--call", call] + extra + NotionTargets.projectArgs(c, p, kind: kind),
                       notion: true) { r in
                let n = (r["added"] as? Int) ?? 0
                guard (r["ok"] as? Bool) == true, n > 0 else { return }
                UsageLog.log("auto_added", ["kind": kind, "n": n])
                NotionLinksVersion.shared.bump()
                NotionTasks.shared.toast = .init(text: L("auto.added." + kind, ["n": "\(n)", "title": call]))
            }
        }
    }

    /// The snapshot <project>/pacenote/decisions.md, before a preparation and before a call (offline: the old one stays).
    static func snapshot(_ p: Project?, done: (() -> Void)? = nil) {
        let c = AppConfig.load(from: AppPaths.config)
        guard let p, !p.root.isEmpty, hasToken else { done?(); return }
        let db = NotionTargets.decisionsDB(c, p)
        guard !db.isEmpty else { done?(); return }
        let file = ((p.root as NSString).appendingPathComponent("pacenote") as NSString).appendingPathComponent("decisions.md")
        PyTool.run("decision_notion", ["--db", db, "--snapshot", file] + NotionTargets.projectArgs(c, p, kind: "decisions"),
                   notion: true, needsAI: false) { _ in done?() }
    }

    /// The active decisions of a project from its snapshot (the series view and the brief), newest first.
    static func active(_ p: Project?) -> [(date: String, title: String, who: String)] {
        guard let p, !p.root.isEmpty else { return [] }
        let file = ((p.root as NSString).appendingPathComponent("pacenote") as NSString).appendingPathComponent("decisions.md")
        guard let t = try? String(contentsOfFile: file, encoding: .utf8) else { return [] }
        return t.split(separator: "\n").compactMap { ln in
            guard ln.hasPrefix("- ") else { return nil }
            let parts = ln.dropFirst(2).split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2, !parts[1].isEmpty else { return nil }
            return (parts[0], parts[1], parts.count > 2 ? parts[2] : "")
        }
    }
}
