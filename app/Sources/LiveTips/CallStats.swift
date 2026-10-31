import Foundation
import LiveTipsCore

/// Pacenote 0.8.7 (B1): the one source of call numbers for Home > This week and Statistics. A hidden call never
/// counts anywhere; projects are counted by their registry key (ProjectKey), so "Bink" and "bink" are one project.
@MainActor
enum CallStats {
    private static var registry: (projects: [(slug: String, name: String)], workspaces: [String], ws: [Workspace]) {
        let reg = ProjectRegistry.load(from: AppPaths.projects)
        return (reg.projects.map { ($0.slug, $0.name) }, reg.workspaces.map(\.name), reg.workspaces)
    }

    static func key(_ r: CallHistory.Record) -> String {
        let reg = registry
        return ProjectKey.key(r.project, projects: reg.projects, workspaces: reg.workspaces)
    }

    static func name(ofKey k: String, fallback: String = "") -> String {
        ProjectKey.name(k, projects: registry.projects, fallback: fallback.isEmpty ? k.replacingOccurrences(of: "other:", with: "") : fallback)
    }

    /// A sales call: the engine wrote <stem>.sales.json (rules/sales.yaml > after_call).
    static func isSales(_ r: CallHistory.Record) -> Bool {
        let stem = r.file.hasSuffix(".md") ? String(r.file.dropLast(3)) : r.file
        return FileManager.default.fileExists(atPath: stem + ".sales.json")
    }

    /// The visible calls in [from, to), within a scope ("" all, "p:<key>", "w:<workspace name>"), optionally sales only.
    static func calls(from: Date = .distantPast, to: Date = .distantFuture, scope: String = "", salesOnly: Bool = false) -> [CallHistory.Record] {
        let reg = registry
        return CallHistory.shared.records.filter { r in
            guard !r.hidden, r.start >= from, r.start < to else { return false }
            if salesOnly && !isSales(r) { return false }
            if scope.isEmpty { return true }
            let k = ProjectKey.key(r.project, projects: reg.projects, workspaces: reg.workspaces)
            if scope.hasPrefix("p:") { return k == String(scope.dropFirst(2)) }
            let w = String(scope.dropFirst(2))
            guard let ws = reg.ws.first(where: { $0.name == w }) else { return k == "workspace:" + w }
            return k == "workspace:" + w || ws.projects.contains(k)
        }
    }

    /// 0.8.7 (B3): the week starts on Monday everywhere (Home and Statistics).
    static var calendar: Calendar { var c = Calendar.current; c.firstWeekday = 2; return c }
    static func weekStart(_ now: Date = Date()) -> Date {
        let c = calendar
        return c.dateInterval(of: .weekOfYear, for: now)?.start ?? c.startOfDay(for: now)
    }

    struct Totals: Equatable { var calls = 0; var minutes = 0.0; var prepared = 0 }
    static func totals(_ recs: [CallHistory.Record]) -> Totals {
        Totals(calls: recs.count, minutes: recs.reduce(0) { $0 + ($1.minutes ?? 0) }, prepared: recs.filter { $0.prepared == true }.count)
    }
}
