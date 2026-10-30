import AppKit
import LiveTipsCore
import SwiftUI

/// Pacenote 0.8.6 (D1, rules/notion-tasks.yaml > settings): Settings > Notion > My tasks in On you. Every value comes
/// from the PM's database (a live read), and the status line is a live query: it tests the settings.
@MainActor
final class NotionTasksSettingsModel: ObservableObject {
    static let shared = NotionTasksSettingsModel()
    struct Prop: Hashable { let name: String; let type: String }
    @Published var props: [Prop] = []
    @Published var options: [String: [String]] = [:]          // property -> option names (status, select, multi_select)
    @Published var statusComplete: [String: [String]] = [:]   // status property -> its Complete group
    @Published var relationTargets: [String: [(id: String, title: String)]] = [:]   // relation property -> pages
    @Published var users: [(id: String, name: String)] = []
    @Published var note = ""
    @Published var busy = false
    var loadedFor = ""
    let settings = SettingsWindow.model

    var token: String? { SecretStore(service: Bundle.main.bundleIdentifier ?? "io.github.example.livetips").get(.notionToken) }

    func load(force: Bool = false) {
        let ds = settings.config.notionTasks.database
        guard let t = token, !ds.isEmpty, force || loadedFor != ds else { return }
        busy = true; note = ""
        Task {
            defer { busy = false }
            do {
                let r = try await NotionAPI.call(t, "GET", "/data_sources/\(ds)")
                let raw = (r["properties"] as? [String: [String: Any]]) ?? [:]
                props = raw.map { Prop(name: $0.key, type: ($0.value["type"] as? String) ?? "") }.sorted { $0.name < $1.name }
                var opts: [String: [String]] = [:], comp: [String: [String]] = [:]
                var rels: [String: [(id: String, title: String)]] = [:]
                for (name, p) in raw {
                    let type = (p["type"] as? String) ?? ""
                    if type == "status" {
                        let g = NotionTasksCore.statusGroups(p)
                        opts[name] = g.open + g.complete; comp[name] = g.complete
                    } else if type == "select" || type == "multi_select" {
                        opts[name] = (((p[type] as? [String: Any])?["options"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
                    } else if type == "relation", let rel = p["relation"] as? [String: Any],
                              let target = (rel["data_source_id"] as? String) ?? (rel["database_id"] as? String) {
                        rels[name] = (try? await pages(t, target)) ?? []
                    }
                }
                options = opts; statusComplete = comp; relationTargets = rels
                if users.isEmpty { users = (try? await allUsers(t)) ?? [] }
                // 0.8.6: an integration without "Read user information" sees no users: offer the people of the database
                if users.isEmpty { users = (try? await peopleIn(t, ds)) ?? [] }
                loadedFor = ds
                applyDefaults()
            } catch { note = "Notion: " + error.localizedDescription }
        }
    }

    private func pages(_ t: String, _ ds: String) async throws -> [(id: String, title: String)] {
        var out: [(id: String, title: String)] = []
        var cursor: String?
        repeat {
            var body: [String: Any] = ["page_size": 100]
            if let c = cursor { body["start_cursor"] = c }
            let r = try await NotionAPI.call(t, "POST", "/data_sources/\(ds)/query", body)
            for p in (r["results"] as? [[String: Any]]) ?? [] {
                guard let id = p["id"] as? String else { continue }
                let props = (p["properties"] as? [String: [String: Any]]) ?? [:]
                let title = props.values.first { ($0["type"] as? String) == "title" }.map { NotionAPI.plain($0["title"]) } ?? ""
                out.append((id, title.isEmpty ? L("nset.untitledPage") : title))
            }
            cursor = (r["has_more"] as? Bool) == true ? r["next_cursor"] as? String : nil
        } while cursor != nil && out.count < 500
        return out.sorted { $0.title.lowercased() < $1.title.lowercased() }
    }

    private func peopleIn(_ t: String, _ ds: String) async throws -> [(id: String, name: String)] {
        let r = try await NotionAPI.call(t, "POST", "/data_sources/\(ds)/query", ["page_size": 100])
        var seen: [String: String] = [:]
        for p in (r["results"] as? [[String: Any]]) ?? [] {
            for (_, v) in (p["properties"] as? [String: [String: Any]]) ?? [:] where (v["type"] as? String) == "people" {
                for u in (v["people"] as? [[String: Any]]) ?? [] { if let id = u["id"] as? String { seen[id] = (u["name"] as? String) ?? seen[id] ?? id } }
            }
        }
        return seen.map { ($0.key, $0.value) }.sorted { $0.1.lowercased() < $1.1.lowercased() }
    }

    private func allUsers(_ t: String) async throws -> [(id: String, name: String)] {
        var out: [(id: String, name: String)] = []
        var cursor: String?
        repeat {
            let r = try await NotionAPI.call(t, "GET", "/users?page_size=100" + (cursor.map { "&start_cursor=" + $0 } ?? ""))
            for u in (r["results"] as? [[String: Any]]) ?? [] where (u["type"] as? String) == "person" {
                if let id = u["id"] as? String { out.append((id, (u["name"] as? String) ?? id)) }
            }
            cursor = (r["has_more"] as? Bool) == true ? r["next_cursor"] as? String : nil
        } while cursor != nil
        return out.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// The first person, date, status property and the project relation are chosen by themselves; names match projects.
    func applyDefaults() {
        var s = settings.config.notionTasks
        if s.personProperty.isEmpty { s.personProperty = props.first { $0.type == "people" }?.name ?? "" }
        if s.dueProperty.isEmpty { s.dueProperty = props.first { $0.type == "date" }?.name ?? "" }
        if s.conditions.isEmpty, let st = props.first(where: { $0.type == "status" }) {
            var c = NotionTasksSettings.Condition(); c.property = st.name; c.type = "status"
            c.values = (options[st.name] ?? []).filter { !(statusComplete[st.name] ?? []).contains($0) }
            s.conditions = [c]
        }
        if s.tickProperty.isEmpty, let st = props.first(where: { $0.type == "status" }) {
            s.tickProperty = st.name; s.tickType = "status"; s.tickValue = statusComplete[st.name]?.first ?? ""
        }
        if s.projectProperty.isEmpty {
            let cand = props.first { ["relation", "select", "multi_select"].contains($0.type) && $0.name.lowercased().contains("project") }
            s.projectProperty = cand?.name ?? ""; s.projectType = cand?.type ?? ""
        }
        if s.workspaceProperty.isEmpty {
            s.workspaceProperty = props.first { $0.type == "relation" && $0.name.lowercased().contains("workspace") }?.name ?? ""
        }
        if s.sourceProperty.isEmpty {
            s.sourceProperty = props.first { ($0.type == "rich_text" || $0.type == "url") && ["source", "from", "call"].contains(where: $0.name.lowercased().contains) }?.name ?? ""
        }
        let reg = settings.registry
        let opts = valueChoices(s.projectProperty).map { (value: $0.value, name: $0.name) }
        let matched = NotionTasksCore.autoMatch(projects: reg.projects.map { ($0.slug, $0.name) } + reg.workspaces.map { ("workspace:" + $0.name, $0.name) }, options: opts)
        for (k, v) in matched where (s.projectMap[k] ?? []).isEmpty { s.projectMap[k] = v }
        if !s.workspaceProperty.isEmpty {
            let wopts = valueChoices(s.workspaceProperty)
            for w in reg.workspaces where (s.workspaceMap[w.name] ?? "").isEmpty {
                if let m = wopts.first(where: { $0.name.lowercased() == w.name.lowercased() }) { s.workspaceMap[w.name] = m.value }
            }
        }
        if s != settings.config.notionTasks { settings.config.notionTasks = s }
    }

    /// The values a property offers: option names, or the related pages (id and title).
    func valueChoices(_ prop: String) -> [(value: String, name: String)] {
        if let r = relationTargets[prop] { return r.map { ($0.id, $0.title) } }
        return (options[prop] ?? []).map { ($0, $0) }
    }

    func type(_ prop: String) -> String { props.first { $0.name == prop }?.type ?? "" }
}

/// A setting's name with an (i) that explains it (0.8.6, owner: "what does each item mean").
struct InfoLabel: View {
    let title: String
    let info: String
    @State private var show = false
    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            Button { show.toggle() } label: { Image(systemName: "info.circle").foregroundStyle(PN.C.text3) }
                .buttonStyle(.plain).help(info).accessibilityLabel(info)
                .popover(isPresented: $show, arrowEdge: .bottom) {
                    Text(info).font(PN.Font.body).fixedSize(horizontal: false, vertical: true).padding(12).frame(width: 300)
                }
        }
    }
}

/// Settings > Notion: "My tasks in On you" (global) and "Projects in Notion" (which task belongs to which project).
struct NotionTasksSection: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var m = NotionTasksSettingsModel.shared
    @ObservedObject var tasks = NotionTasks.shared
    @ObservedObject var dest = NotionDestinationModel.shared

    var s: Binding<NotionTasksSettings> { $model.config.notionTasks }
    var nt: NotionTasksSettings { model.config.notionTasks }

    private func propPicker(_ sel: Binding<String>, types: [String]) -> some View {
        Picker("", selection: sel) {
            Text(L("ntset.none")).tag("")
            ForEach(m.props.filter { types.contains($0.type) }, id: \.name) { p in Text(p.name).tag(p.name) }
        }
        .labelsHidden().fixedSize()
    }

    var body: some View {
        Section {
            Toggle(isOn: s.enabled) { InfoLabel(title: L("ntset.enable"), info: L("ntset.enable.i")) }
            if nt.enabled {
                if !model.isSet(.notionToken) {
                    Text(L("ntset.connectFirst")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                } else {
                    LabeledContent { databasePicker } label: { InfoLabel(title: L("ntset.database"), info: L("ntset.database.i")) }
                    if !nt.database.isEmpty { globalRows }
                }
            }
        } header: { Text(L("ntset.header")) } footer: {
            Text(L("ntset.footer")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
        }
        .onAppear { if dest.items.isEmpty && model.isSet(.notionToken) { dest.find() }; m.load() }
        if nt.enabled && !nt.database.isEmpty && model.isSet(.notionToken) {
            Section {
                LabeledContent { propPicker(Binding(get: { nt.projectProperty }, set: { v in
                    model.config.notionTasks.projectProperty = v; model.config.notionTasks.projectType = m.type(v)
                    model.config.notionTasks.projectMap = [:]; m.applyDefaults()
                }), types: ["relation", "select", "multi_select"]) } label: { InfoLabel(title: L("ntset.projectBy"), info: L("ntset.projectBy.i")) }
                if !nt.projectProperty.isEmpty { mapping }
            } header: { Text(L("ntset.projectsHeader")) } footer: {
                Text(L("ntset.projectsFooter")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
        }
    }

    private var databasePicker: some View {
        Picker("", selection: Binding(get: { nt.database }, set: { id in
            model.config.notionTasks.database = id
            model.config.notionTasks.databaseName = dest.items.first { $0.id == id }?.title ?? ""
            m.loadedFor = ""; m.load()
        })) {
            Text(L("ntset.choose")).tag("")
            if !nt.database.isEmpty && !dest.items.contains(where: { $0.id == nt.database }) {
                Text(nt.databaseName.isEmpty ? nt.database : nt.databaseName).tag(nt.database)
            }
            ForEach(dest.items.filter { $0.kind == "data_source" }) { it in Text(it.title).tag(it.id) }
        }
        .labelsHidden().fixedSize()
    }

    @ViewBuilder private var globalRows: some View {
        LabeledContent {
            HStack {
                propPicker(s.personProperty, types: ["people"])
                Picker("", selection: s.personId) {
                    Text(L("ntset.choosePerson")).tag("")
                    ForEach(m.users, id: \.id) { u in Text(u.name).tag(u.id) }
                }
                .labelsHidden().fixedSize()
                .onChange(of: nt.personId) { model.config.notionTasks.personName = m.users.first { $0.id == nt.personId }?.name ?? "" }
            }
        } label: { InfoLabel(title: L("ntset.onMeMeans"), info: L("ntset.onMeMeans.i")) }
        ForEach(Array(nt.conditions.enumerated()), id: \.element.id) { i, c in conditionRow(i, c) }
        Button(L("ntset.addCondition")) {
            // 0.8.6 (owner): a new condition starts on a property not used yet, with its open values ticked
            var c = NotionTasksSettings.Condition()
            let used = Set(nt.conditions.map(\.property))
            if let p = m.props.first(where: { ["status", "select", "multi_select", "checkbox"].contains($0.type) && !used.contains($0.name) }) {
                c.property = p.name; c.type = p.type
                c.values = p.type == "checkbox" ? ["false"] : (m.options[p.name] ?? []).filter { !(m.statusComplete[p.name] ?? []).contains($0) }
            }
            model.config.notionTasks.conditions.append(c)
        }
        .buttonStyle(.pnTertiary)
        LabeledContent {
            HStack {
                propPicker(Binding(get: { nt.tickProperty }, set: { v in
                    model.config.notionTasks.tickProperty = v; model.config.notionTasks.tickType = m.type(v)
                    model.config.notionTasks.tickValue = m.type(v) == "checkbox" ? "true" : (m.statusComplete[v]?.first ?? m.options[v]?.last ?? "")
                }), types: ["status", "select", "checkbox"])
                Picker("", selection: s.tickValue) {
                    ForEach(nt.tickType == "checkbox" ? ["true"] : (m.options[nt.tickProperty] ?? []), id: \.self) { v in Text(v).tag(v) }
                }
                .labelsHidden().fixedSize()
            }
        } label: { InfoLabel(title: L("ntset.tickSets"), info: L("ntset.tickSets.i")) }
        LabeledContent { propPicker(s.dueProperty, types: ["date"]) } label: { InfoLabel(title: L("ntset.due"), info: L("ntset.due.i")) }
        LabeledContent {
            Picker("", selection: s.periodDays) {
                Text(L("ntset.period.all")).tag("all")
                Text(L("ntset.period.1")).tag("1")
                Text(L("ntset.period.7")).tag("7")
                Text(L("ntset.period.14")).tag("14")
                Text(L("ntset.period.30")).tag("30")
            }
            .labelsHidden().fixedSize()
            .onChange(of: nt.periodDays) { tasks.refresh() }
        } label: { InfoLabel(title: L("ntset.period"), info: L("ntset.period.i")) }
        Toggle(isOn: s.autoAdd) { InfoLabel(title: L("ntset.autoAdd"), info: L("ntset.autoAdd.i")) }
        HStack {
            if nt.ready {
                Text(L("ntset.status", ["n": "\(tasks.tasks.count)", "ago": tasks.syncedAt.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) } ?? "-"]))
                    .font(PN.Font.caption).foregroundStyle(PN.C.text3)
            } else {
                // 0.8.6 (owner: Refresh was grey with no reason): say what is missing
                Text(L("ntset.missing", ["what": nt.missing.map { L("ntset.missing." + $0) }.joined(separator: ", ")]))
                    .font(PN.Font.caption).foregroundStyle(PN.C.onMe)
            }
            Spacer()
            if tasks.busy || m.busy { ProgressView().controlSize(.small) }
            Button(L("ntset.refresh")) { m.load(force: true); tasks.refresh() }.disabled(!nt.ready)
        }
        if !tasks.error.isEmpty { Text(tasks.error).font(PN.Font.caption).foregroundStyle(PN.C.danger) }
        if !m.note.isEmpty { Text(m.note).font(PN.Font.caption).foregroundStyle(PN.C.danger) }
    }

    @ViewBuilder private func conditionRow(_ i: Int, _ c: NotionTasksSettings.Condition) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent {
                HStack {
                    propPicker(Binding(get: { c.property }, set: { v in
                        model.config.notionTasks.conditions[i].property = v
                        model.config.notionTasks.conditions[i].type = m.type(v)
                        let vals = m.options[v] ?? []
                        model.config.notionTasks.conditions[i].values = m.type(v) == "checkbox" ? ["false"] : vals.filter { !(m.statusComplete[v] ?? []).contains($0) }
                    }), types: ["status", "select", "multi_select", "checkbox"])
                    if i > 0 {
                        Button { model.config.notionTasks.conditions.remove(at: i) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).help(L("ntset.removeCondition")).accessibilityLabel(L("ntset.removeCondition"))
                    }
                }
            } label: {
                InfoLabel(title: i == 0 ? L("ntset.showOnlyWhen") : L("ntset.and"), info: L("ntset.showOnlyWhen.i"))
            }
            if c.property.isEmpty {
                Text(L("ntset.pickProperty")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            } else {
                ChipFlow(values: c.type == "checkbox" ? ["true", "false"] : (m.options[c.property] ?? []), selected: c.values) { v in
                    var sel = model.config.notionTasks.conditions[i].values
                    if let k = sel.firstIndex(of: v) { sel.remove(at: k) } else { sel.append(v) }
                    model.config.notionTasks.conditions[i].values = sel
                }
            }
        }
    }

    /// "Pacenote project -> Notion values" (several values per project are fine). A workspace shows once: by its
    /// Workspace relation when the database has one, else in this table.
    @ViewBuilder private var mapping: some View {
        let choices = m.valueChoices(nt.projectProperty)
        let wsByRelation = !nt.workspaceProperty.isEmpty
        let rows: [(key: String, name: String)] = model.registry.projects.filter { $0.status != "archived" }.map { ($0.slug, $0.name) }
            + (wsByRelation ? [] : model.registry.workspaces.map { ("workspace:" + $0.name, $0.name + " " + L("ntset.workspaceMark")) })
        ForEach(rows, id: \.key) { r in
            let sel = nt.projectMap[r.key] ?? []
            LabeledContent(r.name) {
                Menu {
                    ForEach(choices, id: \.value) { c in
                        Toggle(c.name, isOn: Binding(get: { sel.contains(c.value) }, set: { on in
                            var v = model.config.notionTasks.projectMap[r.key] ?? []
                            if on { if !v.contains(c.value) { v.append(c.value) } } else { v.removeAll { $0 == c.value } }
                            model.config.notionTasks.projectMap[r.key] = v.isEmpty ? nil : v
                        }))
                    }
                } label: {
                    Text(sel.isEmpty ? L("ntset.notMapped") : sel.map { v in choices.first { $0.value == v }?.name ?? v }.joined(separator: ", "))
                        .foregroundStyle(sel.isEmpty ? PN.C.text3 : PN.C.text)
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
        }
        if wsByRelation {
            let wch = m.valueChoices(nt.workspaceProperty)
            ForEach(model.registry.workspaces, id: \.name) { w in
                Picker(w.name + " " + L("ntset.workspaceMark"), selection: Binding(
                    get: { nt.workspaceMap[w.name] ?? "" },
                    set: { model.config.notionTasks.workspaceMap[w.name] = $0.isEmpty ? nil : $0 })) {
                    Text(L("ntset.notMapped")).tag("")
                    ForEach(wch, id: \.value) { c in Text(c.name).tag(c.value) }
                }
                .help(L("ntset.workspaceRel.i", ["prop": nt.workspaceProperty]))
            }
        }
    }
}

/// Option chips: a click selects or clears one value (multi-select).
struct ChipFlow: View {
    let values: [String]
    let selected: [String]
    let toggle: (String) -> Void
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(values, id: \.self) { v in
                    let on = selected.contains(v)
                    Button { toggle(v) } label: {
                        Text(v).font(PN.Font.caption)
                            .padding(.horizontal, 10).padding(.vertical, 3)
                            .background(Capsule().fill(on ? PN.C.accentFill.opacity(0.18) : PN.C.surface2))
                            .foregroundStyle(on ? PN.C.accent : PN.C.text2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }
}
