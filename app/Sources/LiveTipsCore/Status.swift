import Foundation

/// State of the local Notion mirror (<workRoot>/_notion/MIRROR_STATUS.md written by the mirror tool).
public struct MirrorStatus: Equatable {
    public var result: String
    public var lastRunUTC: Date?
    public var pages: Int?
    public var mode: String

    public init(result: String = "", lastRunUTC: Date? = nil, pages: Int? = nil, mode: String = "") {
        self.result = result
        self.lastRunUTC = lastRunUTC
        self.pages = pages
        self.mode = mode
    }

    /// "ok", "stale" (older than 24 h), "failed", "missing".
    public func health(now: Date = Date()) -> String {
        if result.uppercased() != "OK" { return result.isEmpty ? "missing" : "failed" }
        guard let t = lastRunUTC else { return "failed" }
        return now.timeIntervalSince(t) > 24 * 3600 ? "stale" : "ok"
    }

    public static func parse(_ text: String) -> MirrorStatus {
        var kv: [String: String] = [:]
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- "), let c = line.firstIndex(of: ":") else { continue }
            let k = line[line.index(line.startIndex, offsetBy: 2)..<c].trimmingCharacters(in: .whitespaces)
            kv[k] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso2 = ISO8601DateFormatter()
        let t = kv["last_run_utc"].flatMap { iso.date(from: $0) ?? iso2.date(from: $0) }
        return MirrorStatus(result: kv["result"] ?? "", lastRunUTC: t, pages: kv["pages_in_mirror"].flatMap { Int($0) },
                            mode: kv["mode"] ?? "")
    }

    public static func load(workRoot: String) -> MirrorStatus {
        let p = ((workRoot as NSString).expandingTildeInPath as NSString).appendingPathComponent("_notion/MIRROR_STATUS.md")
        guard let t = try? String(contentsOfFile: p, encoding: .utf8) else { return MirrorStatus(result: "", lastRunUTC: nil, pages: nil, mode: "") }
        return parse(t)
    }
}

/// Spending ledger shared by the app and the spike: {"YYYY-MM": usd}.
public enum SpendLedger {
    public static var defaultPath: String { (NSHomeDirectory() as NSString).appendingPathComponent(".livetips/spend.json") }

    public static func monthSpent(path: String = defaultPath, now: Date = Date()) -> Double {
        guard let d = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return 0 }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        return (obj[f.string(from: now)] as? Double) ?? (obj[f.string(from: now)] as? NSNumber)?.doubleValue ?? 0
    }
}

/// The recorder status the menu shows (app_root/state/status.json; the same fields as live-transcriber).
public struct EngineStatus {
    public init() {}
    public var state = "idle"
    public var startedAt: String?
    public var lines = 0
    public var tips = 0
    public var callSpentUSD = 0.0
    public var project: String?

    public static func load(path: String) -> EngineStatus {
        var s = EngineStatus()
        guard let d = FileManager.default.contents(atPath: path),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return s }
        s.state = o["state"] as? String ?? "idle"
        s.startedAt = o["started_at"] as? String
        s.lines = (o["lines"] as? Int) ?? 0
        s.tips = (o["tips"] as? Int) ?? 0
        s.callSpentUSD = (o["spent_usd"] as? Double) ?? 0
        s.project = o["project"] as? String
        return s
    }
}

/// Workspaces found in the work folder: <workRoot>/<Name>/_notion/workspace.md (written by the mirror).
public struct Workspace: Codable, Equatable {
    public var name: String
    public var root: String
    public var projects: [String]       // project slugs whose root is inside this folder
    public init(name: String, root: String, projects: [String]) { self.name = name; self.root = root; self.projects = projects }
}

public enum WorkspaceScanner {
    public static func scan(workRoot: String, projects: [Project]) -> [Workspace] {
        let root = (workRoot as NSString).expandingTildeInPath
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        var out: [Workspace] = []
        for n in names.sorted() where !n.hasPrefix(".") && !n.hasPrefix("_") {
            let dir = (root as NSString).appendingPathComponent(n)
            guard FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent("_notion/workspace.md")) else { continue }
            let members = projects.filter { !$0.root.isEmpty && ($0.root + "/").hasPrefix(dir + "/") }.map { $0.slug }
            out.append(Workspace(name: n, root: dir, projects: members))
        }
        return out
    }
}
