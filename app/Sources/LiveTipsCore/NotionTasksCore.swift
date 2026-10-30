import Foundation

/// Pacenote 0.8.6 (D, rules/notion-tasks.yaml): the pure part of the PM's Notion tasks: the query filter, a task read
/// from a page, which Pacenote project a task belongs to, and whether Notion closed it. No network here.
public struct NotionTask: Equatable, Identifiable, Codable {
    public var id: String
    public var title: String
    public var url: String
    public var status: String          // the value of the first condition's property, for the second line
    public var due: String             // YYYY-MM-DD or empty
    public var projectValues: [String] // relation page ids or option names
    public var workspaceValues: [String]
    public var open: Bool              // still inside "Show only when" and not the tick value
    public var tickBefore: String      // the tick property's value before a tick (for Undo)
    public var created: String
    public init(id: String, title: String, url: String = "", status: String = "", due: String = "", projectValues: [String] = [],
                workspaceValues: [String] = [], open: Bool = true, tickBefore: String = "", created: String = "") {
        self.id = id; self.title = title; self.url = url; self.status = status; self.due = due; self.projectValues = projectValues
        self.workspaceValues = workspaceValues; self.open = open; self.tickBefore = tickBefore; self.created = created
    }
}

public enum NotionTasksCore {
    /// One condition as a Notion filter (several values of one property are joined with OR).
    static func condition(_ c: NotionTasksSettings.Condition) -> [String: Any]? {
        guard !c.property.isEmpty, !c.values.isEmpty else { return nil }
        let parts: [[String: Any]] = c.values.map { v in
            switch c.type {
            case "status": return ["property": c.property, "status": ["equals": v]]
            case "multi_select": return ["property": c.property, "multi_select": ["contains": v]]
            case "checkbox": return ["property": c.property, "checkbox": ["equals": v == "true"]]
            default: return ["property": c.property, "select": ["equals": v]]
            }
        }
        return parts.count == 1 ? parts[0] : ["or": parts]
    }

    /// The query filter: the person, every condition (AND), and when `scope` is given the projects' values (OR, plus
    /// the workspace relation when the scope is a workspace with a mapped page).
    public static func filter(_ s: NotionTasksSettings, scope: [String]? = nil, workspace: String? = nil) -> [String: Any] {
        var and: [[String: Any]] = [["property": s.personProperty, "people": ["contains": s.personId]]]
        for c in s.conditions { if let f = condition(c) { and.append(f) } }
        if let scope = scope {
            var any: [[String: Any]] = scope.map { v in
                switch s.projectType {
                case "relation": return ["property": s.projectProperty, "relation": ["contains": v]]
                case "multi_select": return ["property": s.projectProperty, "multi_select": ["contains": v]]
                default: return ["property": s.projectProperty, "select": ["equals": v]]
                }
            }
            if let w = workspace, !s.workspaceProperty.isEmpty, let page = s.workspaceMap[w], !page.isEmpty {
                any.append(["property": s.workspaceProperty, "relation": ["contains": page]])
            }
            if !any.isEmpty { and.append(any.count == 1 ? any[0] : ["or": any]) }
        }
        return and.count == 1 ? and[0] : ["and": and]
    }

    static func plain(_ rich: Any?) -> String {
        ((rich as? [[String: Any]]) ?? []).compactMap { $0["plain_text"] as? String }.joined()
    }

    /// The value of a property as text values: a status or select name, multi-select names, relation ids, a checkbox.
    public static func values(_ prop: [String: Any]?) -> [String] {
        guard let p = prop, let type = p["type"] as? String else { return [] }
        switch type {
        case "status", "select": return ((p[type] as? [String: Any])?["name"] as? String).map { [$0] } ?? []
        case "multi_select": return ((p[type] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
        case "relation": return ((p[type] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
        case "checkbox": return [(p[type] as? Bool) == true ? "true" : "false"]
        case "date": return ((p[type] as? [String: Any])?["start"] as? String).map { [String($0.prefix(10))] } ?? []
        case "title", "rich_text": return [plain(p[type])]
        default: return []
        }
    }

    /// Is the page still open for "Show only when"? Closed = a condition no longer holds or the tick value is set.
    public static func isOpen(_ props: [String: [String: Any]], _ s: NotionTasksSettings) -> Bool {
        if !s.tickProperty.isEmpty, !s.tickValue.isEmpty, values(props[s.tickProperty]).contains(s.tickValue) { return false }
        for c in s.conditions where !c.property.isEmpty && !c.values.isEmpty {
            if Set(values(props[c.property])).isDisjoint(with: c.values) { return false }
        }
        return true
    }

    public static func task(_ page: [String: Any], _ s: NotionTasksSettings) -> NotionTask? {
        guard let id = page["id"] as? String else { return nil }
        let props = (page["properties"] as? [String: [String: Any]]) ?? [:]
        let title = props.values.first { ($0["type"] as? String) == "title" }.map { plain($0["title"]) } ?? ""
        let statusProp = s.conditions.first { $0.type == "status" || $0.type == "select" }?.property ?? s.tickProperty
        return NotionTask(id: id, title: title.isEmpty ? "Untitled" : title, url: page["url"] as? String ?? "",
                          status: values(props[statusProp]).first ?? "", due: values(props[s.dueProperty]).first ?? "",
                          projectValues: values(props[s.projectProperty]), workspaceValues: values(props[s.workspaceProperty]),
                          open: isOpen(props, s) && (page["in_trash"] as? Bool) != true && (page["archived"] as? Bool) != true,
                          tickBefore: values(props[s.tickProperty]).first ?? "", created: page["created_time"] as? String ?? "")
    }

    /// The Pacenote targets a task belongs to ("<slug>" or "workspace:<name>"), from the mapping table.
    public static func targets(_ t: NotionTask, _ s: NotionTasksSettings) -> [String] {
        var out: [String] = []
        for (k, vals) in s.projectMap where !Set(vals).isDisjoint(with: t.projectValues) { out.append(k) }
        for (w, page) in s.workspaceMap where t.workspaceValues.contains(page) { out.append("workspace:" + w) }
        return out.sorted()
    }

    /// Which tasks a call shows: a project's own; a workspace's: every project of it; no project: none.
    public static func forCall(_ tasks: [NotionTask], _ s: NotionTasksSettings, project: String?, workspaceProjects: [String] = [],
                               workspace: String? = nil) -> [NotionTask] {
        guard project != nil || workspace != nil else { return [] }
        let want = Set((project.map { [$0] } ?? []) + workspaceProjects + (workspace.map { ["workspace:" + $0] } ?? []))
        return tasks.filter { $0.open && !Set(targets($0, s)).isDisjoint(with: want) }
    }

    /// The property value a tick (or Undo) writes.
    public static func tickPatch(_ s: NotionTasksSettings, value: String) -> [String: Any] {
        switch s.tickType {
        case "checkbox": return [s.tickProperty: ["checkbox": value == "true"]]
        case "status": return [s.tickProperty: ["status": ["name": value]]]
        default: return [s.tickProperty: ["select": ["name": value]]]
        }
    }

    /// The default of "Ticking a task sets" and of "Show only when" for a status property: Notion's groups.
    public static func statusGroups(_ prop: [String: Any]) -> (open: [String], complete: [String]) {
        let st = (prop["status"] as? [String: Any]) ?? [:]
        let options = (st["options"] as? [[String: Any]]) ?? []
        let byId = Dictionary(uniqueKeysWithValues: options.compactMap { o -> (String, String)? in
            guard let id = o["id"] as? String, let n = o["name"] as? String else { return nil }; return (id, n) })
        var complete: [String] = []
        for g in (st["groups"] as? [[String: Any]]) ?? [] where (g["name"] as? String)?.lowercased() == "complete" {
            complete = ((g["option_ids"] as? [String]) ?? []).compactMap { byId[$0] }
        }
        let all = options.compactMap { $0["name"] as? String }
        return (all.filter { !complete.contains($0) }, complete)
    }

    /// A new task page (rules/notion-tasks.yaml > link) for a commitment.
    public static func newPage(_ s: NotionTasksSettings, title: String, projectValues: [String], due: String, source: String,
                               quote: String, titleProperty: String) -> [String: Any] {
        var props: [String: Any] = [titleProperty: ["title": [["type": "text", "text": ["content": String(title.prefix(200))]]]],
                                    s.personProperty: ["people": [["id": s.personId]]]]
        if !s.projectProperty.isEmpty, !projectValues.isEmpty {
            switch s.projectType {
            case "relation": props[s.projectProperty] = ["relation": projectValues.map { ["id": $0] }]
            case "multi_select": props[s.projectProperty] = ["multi_select": projectValues.map { ["name": $0] }]
            default: props[s.projectProperty] = ["select": ["name": projectValues[0]]]
            }
        }
        if !s.dueProperty.isEmpty, due.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil {
            props[s.dueProperty] = ["date": ["start": due]]
        }
        if let c = s.conditions.first(where: { ($0.type == "status" || $0.type == "select") && !$0.values.isEmpty }) {
            props[c.property] = c.type == "status" ? ["status": ["name": c.values[0]]] : ["select": ["name": c.values[0]]]
        }
        if !s.sourceProperty.isEmpty {
            props[s.sourceProperty] = ["rich_text": [["type": "text", "text": ["content": String(source.prefix(300))]]]]
        }
        var children: [[String: Any]] = [["object": "block", "type": "paragraph",
                                          "paragraph": ["rich_text": [["type": "text", "text": ["content": String(source.prefix(1900))]]]]]]
        if !quote.isEmpty {
            children.append(["object": "block", "type": "quote", "quote": ["rich_text": [["type": "text", "text": ["content": String(quote.prefix(1900))]]]]])
        }
        return ["parent": ["type": "data_source_id", "data_source_id": s.database], "properties": props, "children": children]
    }

    /// Automatic match of Pacenote project names to Notion values by name (rules/notion-tasks.yaml > project_by).
    public static func autoMatch(projects: [(slug: String, name: String)], options: [(value: String, name: String)]) -> [String: [String]] {
        func k(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "[^\\p{L}\\p{N}]", with: "", options: .regularExpression) }
        var out: [String: [String]] = [:]
        for p in projects {
            if let o = options.first(where: { k($0.name) == k(p.name) || k($0.name) == k(p.slug) }) { out[p.slug] = [o.value] }
        }
        return out
    }
}
