import Foundation

/// 0.17.0 (spec 5.2, D39): the pure part of the "New project" wizard. The window is in the app (ProjectWizard.swift).
public enum ProjectWizardCore {
    public enum Step: Int, CaseIterable { case name, folder, card, sources, people }

    /// The steps the wizard shows. People only for a new organization project made by someone who may make one (D38).
    public static func steps(newOrgProject: Bool, canManage: Bool) -> [Step] {
        newOrgProject && canManage ? Step.allCases : [.name, .folder, .card, .sources]
    }

    /// A folder name from what the PM typed: no slashes or colons, no leading dot, at most 80 characters.
    public static func folderName(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "[/:\\\\]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        return String(s.prefix(80)).trimmingCharacters(in: .whitespaces)
    }

    /// Where a new project folder goes: the chosen workspace, else the first one, else "<work folder>/My workspace".
    /// A project right in the work folder would later show up as a workspace candidate, so it never goes there.
    public static func parent(workRoot: String, workspaces: [String], chosen: String = "") -> String {
        if !chosen.isEmpty { return chosen }
        if let w = workspaces.first(where: { !$0.isEmpty }) { return w }
        guard !workRoot.isEmpty else { return "" }
        return ((workRoot as NSString).expandingTildeInPath as NSString).appendingPathComponent("My workspace")
    }

    /// The new folder's path; a free name if the folder already exists ("Name 2", "Name 3").
    public static func newFolder(parent: String, name: String, exists: (String) -> Bool) -> String {
        let n = folderName(name)
        guard !parent.isEmpty, !n.isEmpty else { return "" }
        var p = (parent as NSString).appendingPathComponent(n), k = 2
        while exists(p) { p = (parent as NSString).appendingPathComponent(n + " \(k)"); k += 1 }
        return p
    }

    /// Links the PM pasted (one per line or separated by spaces): http(s) only, each once, at most 20.
    public static func links(_ text: String) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for w in text.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;"))) {
            let u = w.trimmingCharacters(in: CharacterSet(charactersIn: "<>()\"'"))
            guard let url = URL(string: u), let sch = url.scheme?.lowercased(), sch == "https" || sch == "http",
                  let h = url.host, h.contains(".") else { continue }
            if seen.insert(u).inserted { out.append(u) }
            if out.count == 20 { break }
        }
        return out
    }

    /// The kind of a source for the later source map (spec 4.3): drive_folder, drive_file, notion_page or url.
    public static func sourceKind(_ link: String) -> String {
        guard let u = URL(string: link), let h = u.host?.lowercased() else { return "url" }
        if h == "drive.google.com" && u.path.contains("/folders/") { return "drive_folder" }
        if h.hasSuffix("google.com") && (h.hasPrefix("docs.") || h == "drive.google.com") { return "drive_file" }
        if h == "notion.so" || h.hasSuffix(".notion.so") || h.hasSuffix(".notion.site") { return "notion_page" }
        return "url"
    }

    /// Glossary terms from a text field: one per line or comma separated, each once, at most 300 (spec 3).
    public static func glossary(_ text: String) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for t in text.components(separatedBy: CharacterSet(charactersIn: ",\n")) {
            let s = String(t.trimmingCharacters(in: .whitespaces).prefix(80))
            if !s.isEmpty, seen.insert(s.lowercased()).inserted { out.append(s) }
            if out.count == 300 { break }
        }
        return out
    }

    /// Body of POST /v1/orgs/{id}/projects (contract: name, member_ids).
    public static func orgProjectBody(name: String, memberIDs: [String]) -> [String: Any] {
        var b: [String: Any] = ["name": String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))]
        if !memberIDs.isEmpty { b["member_ids"] = Array(Set(memberIDs)).sorted() }
        return b
    }

    /// The people of GET /v1/orgs/{id}/members a project can take: active, with a name or an email; me excluded.
    public struct Member: Equatable, Identifiable {
        public var id: String
        public var name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }
    public static func members(_ a: [[String: Any]], me: String) -> [Member] {
        a.compactMap { m -> Member? in
            guard let id = m["user_id"] as? String, id != me, (m["status"] as? String ?? "active") == "active" else { return nil }
            let n = (m["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (m["email"] as? String) ?? ""
            return n.isEmpty ? nil : Member(id: id, name: n)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// 0.17.0 (spec 5.1, D39): the sample project a new person starts with. Invented company and people (Mike, Emily,
/// Sarah), one decision and one task from a short sample call. It stays off the server until the PM makes it theirs.
public enum SampleProject {
    public static let name = "Sample project"
    public static let callTitle = "Sample kickoff"

    public static func make(root: String, workspace: String) -> Project {
        var p = Project(name: name, slug: "sample-project", root: root)
        p.workspace = workspace
        p.sample = true
        p.about = "A made-up project to try Pacenote on: a new booking page for Brightline Bikes, a bike rental shop."
        p.client = "Brightline Bikes (brightline.example)"
        p.goal = "Launch the new booking page before the spring season."
        p.people = [Project.Person(name: "Mike", role: "Owner, decides", side: "client"),
                    Project.Person(name: "Emily", role: "Shop manager, champion", side: "client"),
                    Project.Person(name: "Sarah", role: "Designer", side: "team")]
        p.glossary = ["Brightline", "booking page", "e-bike", "deposit"]
        p.defaultLanguage = "en"
        p.clientLanguage = "en"
        return p
    }

    /// Still the sample as made: the name and the card untouched. Renaming or editing it makes it the PM's own.
    public static func pristine(_ p: Project) -> Bool {
        guard p.sample else { return false }
        let t = make(root: p.root, workspace: p.workspace)
        return p.name == t.name && p.about == t.about && p.client == t.client && p.goal == t.goal && p.people == t.people
            && p.glossary == t.glossary && p.links.isEmpty
    }

    /// The sample project never syncs while it is untouched (spec 5.1), even with the sync switched on.
    public static func blocksSync(_ p: Project) -> Bool { pristine(p) }

    /// After an edit: the sample mark goes once the PM renamed it or changed its card.
    public static func settle(_ p: Project) -> Project {
        var q = p
        if q.sample && !pristine(q) { q.sample = false }
        return q
    }

    /// The sample call's files in the project's live folder: transcript and notes (one decision, one task).
    public static func callStem(date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd-HHmm"
        return f.string(from: date) + "-sample-kickoff.app"
    }
    public static let transcript = """
    # Call: Sample kickoff
    - source: sample

    [00:00:05] Mike: Thanks for joining. We want the new booking page live before spring.
    [00:00:21] Emily: Most people ask for e-bikes, so they should be first on the page.
    [00:01:02] Sarah: I can share the first design next Tuesday.
    [00:01:40] Mike: Good. Let's keep the deposit at 20 euros for now.

    """
    public static let notes = """
    ## Meeting notes

    ### TL;DR
    A sample call: the booking page goes live before spring, e-bikes first, design next Tuesday.

    ### Decisions
    - [00:01:40] Keep the deposit at 20 euros for now.

    ### Action items
    - [00:01:02] Sarah shares the first design next Tuesday.

    """
    public static let task = "Send Mike the launch plan for the booking page"
}
