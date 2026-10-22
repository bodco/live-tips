import Foundation

/// One project the app records calls for. No secrets. Matches the Control Tower project config.
public struct Project: Codable, Equatable {
    public struct Person: Codable, Equatable {
        public var name: String
        public var role: String
        public var side: String            // "team" | "client"
        public init(name: String, role: String, side: String) { self.name = name; self.role = role; self.side = side }
    }
    public struct IndexSettings: Codable, Equatable {
        public var enabled = true
        public var extra: [String] = []    // e.g. the workspace's Notion mirror (same workspace only)
        public init() {}
    }
    public var name: String
    public var slug: String
    public var root: String
    public var config: String = ""
    public var status: String = "active"
    public var workspace: String = ""
    public var defaultLanguage: String = ""
    public var clientLanguage: String = ""
    public var audienceDefault: String = "auto"
    public var people: [Person] = []
    public var aliases: [String: String] = [:]   // transcript alias -> real name
    /// D5b: may this project's call text go to the model API? Off = local layer only.
    public var apiAllowed: Bool = true
    public var index = IndexSettings()

    public init(name: String, slug: String, root: String) { self.name = name; self.slug = slug; self.root = root }
}

public struct ProjectRegistry: Codable, Equatable {
    public var projects: [Project] = []
    /// Workspaces for general calls about several projects (recordings go to the workspace folder).
    public var workspaces: [Workspace] = []
    public var lastUsed: String = ""        // "project:<slug>" or "workspace:<name>"
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        projects = (try? c.decode([Project].self, forKey: .projects)) ?? []
        workspaces = (try? c.decode([Workspace].self, forKey: .workspaces)) ?? []
        lastUsed = (try? c.decode(String.self, forKey: .lastUsed)) ?? ""
    }

    public static func load(from url: URL) -> ProjectRegistry {
        guard let d = try? Data(contentsOf: url), let r = try? JSONDecoder().decode(ProjectRegistry.self, from: d) else {
            return ProjectRegistry()
        }
        return r
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }

    /// Adds or refreshes projects from imported configs. Fields the user sets in the app
    /// (apiAllowed, index, audienceDefault, workspace) survive a re-import.
    public mutating func merge(imported: [Project]) {
        for var p in imported {
            if let i = projects.firstIndex(where: { $0.slug == p.slug }) {
                let old = projects[i]
                p.apiAllowed = old.apiAllowed
                p.index = old.index
                p.audienceDefault = old.audienceDefault
                if !old.workspace.isEmpty { p.workspace = old.workspace }
                if p.root.isEmpty { p.root = old.root }
                projects[i] = p
            } else {
                projects.append(p)
            }
        }
        projects.sort { $0.name.lowercased() < $1.name.lowercased() }
    }
}

/// Reads a Control Tower project config (projects/<slug>.md): "- **key**: value" lines,
/// "## Local Paths", the team tables and the transcript alias map.
public enum ProjectConfigImporter {
    public static func parse(markdown: String, path: String = "", home: String = NSHomeDirectory()) -> Project? {
        var kv: [String: String] = [:]
        var section = ""
        var people: [Project.Person] = []
        var aliases: [String: String] = [:]
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") || line.hasPrefix("### ") {
                section = line.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
                continue
            }
            if line.hasPrefix("- **"), let end = line.range(of: "**:") {
                let key = String(line[line.index(line.startIndex, offsetBy: 4)..<end.lowerBound])
                var value = String(line[end.upperBound...]).trimmingCharacters(in: .whitespaces)
                if let r = value.range(of: "  (") { value = String(value[..<r.lowerBound]) }   // drop trailing notes
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: " `"))
                kv[key] = value
                continue
            }
            if line.hasPrefix("|") {
                let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                guard cells.count >= 2, !cells[0].hasPrefix("---"), !cells[0].hasPrefix("{"),
                      cells[0] != "Name", cells[0] != "Transcript says", cells[0] != "...", !cells[0].contains("---") else { continue }
                if section.hasPrefix("team - internal") {
                    people.append(.init(name: cells[0], role: cells[1], side: "team"))
                } else if section.hasPrefix("team - client") {
                    people.append(.init(name: cells[0], role: cells[1], side: "client"))
                } else if section.hasPrefix("transcript alias map") {
                    aliases[cells[0]] = cells[1]
                }
            }
        }
        guard let slug = kv["project_slug"], !slug.isEmpty, !slug.hasPrefix("{") else { return nil }
        var root = kv["project_root"] ?? ""
        if root.hasPrefix("{") || root == "none" { root = "" }
        root = root.replacingOccurrences(of: "~~home-folder", with: home)
        if root.hasPrefix("~") { root = home + root.dropFirst() }
        var p = Project(name: kv["project_name"] ?? slug, slug: slug, root: root)
        p.config = path
        p.status = kv["status"] ?? "active"
        p.defaultLanguage = kv["default_language"] ?? ""
        p.clientLanguage = kv["client_language"] ?? ""
        p.people = people
        p.aliases = aliases
        return p
    }

    /// Every active project config in a folder (files starting with "_" and *.instructions.md skipped).
    public static func importFolder(_ dir: String) -> [Project] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        return names.sorted().compactMap { n -> Project? in
            guard n.hasSuffix(".md"), !n.hasPrefix("_"), !n.hasSuffix(".instructions.md"), n != "SKILL.md" else { return nil }
            let path = (dir as NSString).appendingPathComponent(n)
            guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                  let p = parse(markdown: text, path: path), p.status != "archived" else { return nil }
            return p
        }
    }
}
