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

struct NotionTasksSection: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var m = NotionTasksSettingsModel.shared
    @ObservedObject var tasks = NotionTasks.shared
    @ObservedObject var dest = NotionDestinationModel.shared

    var s: Binding<NotionTasksSettings> { $model.config.notionTasks }

    private func picker(_ title: String, _ sel: Binding<String>, types: [String]) -> some View {
        Picker(title, selection: sel) {
            Text(L("ntset.none")).tag("")
            ForEach(m.props.filter { types.contains($0.type) }, id: \.name) { p in Text(p.name).tag(p.name) }
        }
    }

    var body: some View {
        Section {
            Toggle(L("ntset.enable"), isOn: s.enabled)
            if model.config.notionTasks.enabled {
                if !model.isSet(.notionToken) {
                    Text(L("ntset.connectFirst")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                } else {
                    Picker(L("ntset.database"), selection: Binding(get: { model.config.notionTasks.database }, set: { id in
                        model.config.notionTasks.database = id
                        model.config.notionTasks.databaseName = dest.items.first { $0.id == id }?.title ?? ""
                        m.loadedFor = ""; m.load()
                    })) {
                        Text(L("ntset.choose")).tag("")
                        if !model.config.notionTasks.database.isEmpty && !dest.items.contains(where: { $0.id == model.config.notionTasks.database }) {
                            Text(model.config.notionTasks.databaseName.isEmpty ? model.config.notionTasks.database : model.config.notionTasks.databaseName).tag(model.config.notionTasks.database)
                        }
                        ForEach(dest.items.filter { $0.kind == "data_source" }) { it in Text(it.title).tag(it.id) }
                    }
                    if !model.config.notionTasks.database.isEmpty { details }
                }
            }
        } header: { Text(L("ntset.header")) } footer: {
            Text(L("ntset.footer")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
        }
        .onAppear { if dest.items.isEmpty && model.isSet(.notionToken) { dest.find() }; m.load() }
    }

    @ViewBuilder private var details: some View {
        // On me means
        HStack {
            picker(L("ntset.onMeMeans"), s.personProperty, types: ["people"])
            Picker("", selection: s.personId) {
                Text(L("ntset.choosePerson")).tag("")
                ForEach(m.users, id: \.id) { u in Text(u.name).tag(u.id) }
            }
            .labelsHidden()
            .onChange(of: model.config.notionTasks.personId) { model.config.notionTasks.personName = m.users.first { $0.id == model.config.notionTasks.personId }?.name ?? "" }
        }
        // Show only when
        ForEach(Array(model.config.notionTasks.conditions.enumerated()), id: \.element.id) { i, c in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Picker(i == 0 ? L("ntset.showOnlyWhen") : L("ntset.and"), selection: Binding(get: { c.property }, set: { v in
                        model.config.notionTasks.conditions[i].property = v
                        model.config.notionTasks.conditions[i].type = m.type(v)
                        let vals = m.options[v] ?? []
                        model.config.notionTasks.conditions[i].values = m.type(v) == "checkbox" ? ["false"] : vals.filter { !(m.statusComplete[v] ?? []).contains($0) }
                    })) {
                        Text(L("ntset.none")).tag("")
                        ForEach(m.props.filter { ["status", "select", "multi_select", "checkbox"].contains($0.type) }, id: \.name) { p in Text(p.name).tag(p.name) }
                    }
                    if i > 0 { Button { model.config.notionTasks.conditions.remove(at: i) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain) }
                }
                let vals = c.type == "checkbox" ? ["true", "false"] : (m.options[c.property] ?? [])
                ChipFlow(values: vals, selected: c.values) { v in
                    var sel = model.config.notionTasks.conditions[i].values
                    if let k = sel.firstIndex(of: v) { sel.remove(at: k) } else { sel.append(v) }
                    model.config.notionTasks.conditions[i].values = sel
                }
            }
        }
        Button(L("ntset.addCondition")) { model.config.notionTasks.conditions.append(NotionTasksSettings.Condition()) }.buttonStyle(.pnTertiary)
        // Ticking a task sets
        HStack {
            Picker(L("ntset.tickSets"), selection: Binding(get: { model.config.notionTasks.tickProperty }, set: { v in
                model.config.notionTasks.tickProperty = v; model.config.notionTasks.tickType = m.type(v)
                model.config.notionTasks.tickValue = m.type(v) == "checkbox" ? "true" : (m.statusComplete[v]?.first ?? m.options[v]?.last ?? "")
            })) {
                Text(L("ntset.none")).tag("")
                ForEach(m.props.filter { ["status", "select", "checkbox"].contains($0.type) }, id: \.name) { p in Text(p.name).tag(p.name) }
            }
            Picker("", selection: s.tickValue) {
                ForEach(model.config.notionTasks.tickType == "checkbox" ? ["true"] : (m.options[model.config.notionTasks.tickProperty] ?? []), id: \.self) { v in Text(v).tag(v) }
            }
            .labelsHidden()
        }
        picker(L("ntset.due"), s.dueProperty, types: ["date"])
        // Project is told by
        Picker(L("ntset.projectBy"), selection: Binding(get: { model.config.notionTasks.projectProperty }, set: { v in
            model.config.notionTasks.projectProperty = v; model.config.notionTasks.projectType = m.type(v)
            model.config.notionTasks.projectMap = [:]; m.applyDefaults()
        })) {
            Text(L("ntset.none")).tag("")
            ForEach(m.props.filter { ["relation", "select", "multi_select"].contains($0.type) }, id: \.name) { p in Text(p.name).tag(p.name) }
        }
        if !model.config.notionTasks.projectProperty.isEmpty { mapping }
        Toggle(L("ntset.autoAdd"), isOn: s.autoAdd)
        HStack {
            Text(L("ntset.status", ["n": "\(tasks.tasks.count)", "ago": tasks.syncedAt.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date()) } ?? "-"]))
                .font(PN.Font.caption).foregroundStyle(PN.C.text3)
            Spacer()
            if tasks.busy || m.busy { ProgressView().controlSize(.small) }
            Button(L("ntset.refresh")) { m.load(force: true); tasks.refresh() }.disabled(!model.config.notionTasks.ready)
        }
        if !tasks.error.isEmpty { Text(tasks.error).font(PN.Font.caption).foregroundStyle(PN.C.danger) }
        if !m.note.isEmpty { Text(m.note).font(PN.Font.caption).foregroundStyle(PN.C.danger) }
    }

    /// "Pacenote project -> Notion value"; a workspace means all its projects, plus its Workspace relation value.
    @ViewBuilder private var mapping: some View {
        let choices = m.valueChoices(model.config.notionTasks.projectProperty)
        let rows: [(key: String, name: String)] = model.registry.projects.filter { $0.status != "archived" }.map { ($0.slug, $0.name) }
            + model.registry.workspaces.map { ("workspace:" + $0.name, $0.name + " " + L("ntset.workspaceMark")) }
        ForEach(rows, id: \.key) { r in
            Picker(r.name, selection: Binding(get: { model.config.notionTasks.projectMap[r.key]?.first ?? "" }, set: { v in
                model.config.notionTasks.projectMap[r.key] = v.isEmpty ? nil : [v]
            })) {
                Text(L("ntset.notMapped")).tag("")
                ForEach(choices, id: \.value) { c in Text(c.name).tag(c.value) }
            }
        }
        if !model.config.notionTasks.workspaceProperty.isEmpty {
            let wch = m.valueChoices(model.config.notionTasks.workspaceProperty)
            ForEach(model.registry.workspaces, id: \.name) { w in
                Picker(L("ntset.workspaceValue", ["name": w.name, "prop": model.config.notionTasks.workspaceProperty]), selection: Binding(
                    get: { model.config.notionTasks.workspaceMap[w.name] ?? "" },
                    set: { model.config.notionTasks.workspaceMap[w.name] = $0.isEmpty ? nil : $0 })) {
                    Text(L("ntset.notMapped")).tag("")
                    ForEach(wch, id: \.value) { c in Text(c.name).tag(c.value) }
                }
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
