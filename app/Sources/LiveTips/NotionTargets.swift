import Foundation
import LiveTipsCore

/// 0.8.7 (F3): where a call's pages go in Notion. One Meetings and one Risks database for all projects (Settings >
/// Integrations > Notion > Databases); the project is a property of the page, its value set in Settings > Projects.
/// A project's Control Tower config still names its own databases and page ids; the database chosen in Settings wins.
enum NotionTargets {
    static func configText(_ p: Project?) -> String {
        guard let p, !p.config.isEmpty else { return "" }
        return (try? String(contentsOfFile: p.config, encoding: .utf8)) ?? ""
    }

    /// The id after `key` in a project config ("- **risks_db**: `collection://...`"), or "".
    static func configId(_ key: String, _ p: Project?) -> String {
        let t = configText(p)
        guard let r = t.range(of: key + "[^:\\n]*:\\s*[`\"]?(collection://)?([0-9a-fA-F-]{32,36})", options: .regularExpression),
              let id = t[r].range(of: "[0-9a-fA-F-]{32,36}", options: .regularExpression) else { return "" }
        return String(t[r][id])
    }

    static func meetingsDB(_ c: AppConfig, _ p: Project?) -> String { c.notionMeetingsDB.isEmpty ? configId("meetings_db", p) : c.notionMeetingsDB }
    static func risksDB(_ c: AppConfig, _ p: Project?) -> String { c.notionRisksDB.isEmpty ? configId("risks_db", p) : c.notionRisksDB }

    /// A page id (32 hex digits, dashes allowed) means a relation; anything else is a select option or text.
    static func isPageId(_ v: String) -> Bool { v.range(of: "^[0-9a-fA-F-]{32,36}$", options: .regularExpression) != nil }

    /// Arguments for wrapup_notion and risk_notion: the project property and its value.
    static func projectArgs(_ c: AppConfig, _ p: Project?, risks: Bool = false) -> [String] {
        let prop = risks ? c.notionRisksProp : c.notionMeetingsProp
        let value = p.map { $0.notionValue.isEmpty ? $0.name : $0.notionValue } ?? ""
        var a: [String] = []
        if !prop.isEmpty { a += ["--project-prop", prop] }
        if let p, !p.config.isEmpty, FileManager.default.fileExists(atPath: p.config) { a += ["--project-config", p.config] }
        // 0.8.7: several page ids ("id1, id2") go together when every part is a page id
        let parts = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !parts.isEmpty, parts.allSatisfy(isPageId) { a += ["--project-page", parts.joined(separator: ",")] }
        else if !value.isEmpty { a += ["--project-name", value] }
        return a
    }
}

import AppKit
import SwiftUI

/// 0.8.7 (F3, F7): what Settings needs to know about the chosen Notion databases: the name, the properties that can
/// carry the project (relation, select, multi-select) with their options, a page count, and the titles of the pages a
/// relation points to. Read with the PM's token on demand; ids are never shown in the interface.
@MainActor
final class NotionSchema: ObservableObject {
    static let shared = NotionSchema()
    struct Prop: Hashable {
        let name: String
        let type: String           // relation | select | multi_select
        let relationDS: String     // the data source a relation points to
        let options: [String]      // select and multi-select option names
    }
    struct Page: Hashable { let id: String; let title: String }
    struct Choice: Hashable { let id: String; let projects: [String] }

    @Published var props: [String: [Prop]] = [:]
    @Published var titles: [String: String] = [:]        // data source id -> its name
    @Published var counts: [String: String] = [:]        // data source id -> "12 pages" / "100+ pages"
    @Published var pages: [String: [Page]] = [:]         // relation data source id -> its pages
    @Published var pageTitles: [String: String] = [:]    // page id -> title ("" when it could not be read)
    @Published var fillChoices: [String: [Choice]] = [:] // kind -> databases the project configs name, when they differ
    private var loading = Set<String>()

    private var token: String? { NotionDestinationModel.shared.token }

    static func norm(_ id: String) -> String { id.replacingOccurrences(of: "-", with: "").lowercased() }

    /// The property named Project (any case), else the first one with "project" in its name.
    static func autoProject(_ ps: [Prop]) -> String {
        ps.first { $0.name.lowercased() == "project" }?.name ?? ps.first { $0.name.lowercased().contains("project") }?.name ?? ""
    }

    func load(_ ds: String) {
        guard !ds.isEmpty, let t = token, !loading.contains("ds:" + ds), props[ds] == nil else { return }
        loading.insert("ds:" + ds)
        Task {
            defer { loading.remove("ds:" + ds) }
            guard let r = try? await NotionAPI.call(t, "GET", "/data_sources/\(ds)") else { counts[ds] = ""; return }
            let title = NotionAPI.plain(r["title"])
            titles[ds] = title
            var out: [Prop] = []
            for (name, v) in (r["properties"] as? [String: [String: Any]]) ?? [:] {
                let type = (v["type"] as? String) ?? ""
                guard ["relation", "select", "multi_select"].contains(type) else { continue }
                let inner = (v[type] as? [String: Any]) ?? [:]
                let opts = ((inner["options"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
                out.append(Prop(name: name, type: type, relationDS: (inner["data_source_id"] as? String) ?? "", options: opts))
            }
            props[ds] = out.sorted { $0.name.lowercased() < $1.name.lowercased() }
            if let q = try? await NotionAPI.call(t, "POST", "/data_sources/\(ds)/query", ["page_size": 100]) {
                let n = ((q["results"] as? [Any]) ?? []).count
                counts[ds] = (q["has_more"] as? Bool) == true ? L("ntset.pagesMore", ["n": "\(n)"]) : L("ntset.pages", ["n": "\(n)"])
            }
        }
    }

    /// The pages of a relation's database, for the In Notion pop-up (up to 200, by title).
    func loadPages(_ ds: String) {
        guard !ds.isEmpty, let t = token, !loading.contains("pg:" + ds), pages[ds] == nil else { return }
        loading.insert("pg:" + ds)
        Task {
            defer { loading.remove("pg:" + ds) }
            var out: [Page] = [], cursor: String?
            repeat {
                var body: [String: Any] = ["page_size": 100]
                if let c = cursor { body["start_cursor"] = c }
                guard let r = try? await NotionAPI.call(t, "POST", "/data_sources/\(ds)/query", body) else { break }
                for o in (r["results"] as? [[String: Any]]) ?? [] {
                    guard let id = o["id"] as? String else { continue }
                    out.append(Page(id: id, title: Self.title(of: o)))
                    pageTitles[Self.norm(id)] = Self.title(of: o)
                }
                cursor = (r["has_more"] as? Bool) == true ? r["next_cursor"] as? String : nil
            } while cursor != nil && out.count < 200
            pages[ds] = out.sorted { $0.title.lowercased() < $1.title.lowercased() }
        }
    }

    /// One page's title (a stored relation value that is not in the list).
    func loadPage(_ id: String) {
        let k = Self.norm(id)
        guard let t = token, pageTitles[k] == nil, !loading.contains("p:" + k) else { return }
        loading.insert("p:" + k)
        Task {
            defer { loading.remove("p:" + k) }
            let r = try? await NotionAPI.call(t, "GET", "/pages/\(id)")
            pageTitles[k] = r.map { Self.title(of: $0) } ?? ""
        }
    }

    static func title(of page: [String: Any]) -> String {
        let props = (page["properties"] as? [String: [String: Any]]) ?? [:]
        return props.values.first { ($0["type"] as? String) == "title" }.map { NotionAPI.plain($0["title"]) } ?? ""
    }
}

/// A database pop-up with a search field over the databases the integration sees.
struct NotionDBSearchPopover: View {
    let items: [NotionAPI.Item]
    let pick: (NotionAPI.Item?) -> Void
    @State private var q = ""
    @FocusState private var focus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("", text: $q, prompt: Text(L("ntset.searchDb"))).textFieldStyle(.roundedBorder).focused($focus)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Button { pick(nil) } label: { Text(L("ntset.none")).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4) }
                        .buttonStyle(.plain).foregroundStyle(PN.C.text3)
                    let list = items.filter { q.isEmpty || $0.title.localizedCaseInsensitiveContains(q) }
                    ForEach(list) { it in
                        Button { pick(it) } label: {
                            Text(it.title).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if list.isEmpty { Text(L("ntset.noDbMatch")).font(PN.Font.caption).foregroundStyle(PN.C.text3).padding(.vertical, 4) }
                }
            }
            .frame(height: 220)
        }
        .padding(12).frame(width: 300)
        .onAppear { focus = true }
    }
}

/// 0.8.7 (F3): one row of Settings > Integrations > Notion > Databases: the database (a pop-up with search), its
/// project property and how many pages it has.
struct NotionDBRow: View {
    let kind: String          // meetings | tasks | risks
    @ObservedObject var model: SettingsModel
    @ObservedObject var dest = NotionDestinationModel.shared
    @ObservedObject var schema = NotionSchema.shared
    @State private var pop = false

    var id: Binding<String> {
        switch kind {
        case "meetings": return Binding(get: { model.config.notionMeetingsDB }, set: { v in
            model.config.notionMeetingsDB = v; model.config.notionMeetingsName = dest.items.first { $0.id == v }?.title ?? NotionSchema.shared.titles[v] ?? "" })
        case "risks": return Binding(get: { model.config.notionRisksDB }, set: { v in
            model.config.notionRisksDB = v; model.config.notionRisksName = dest.items.first { $0.id == v }?.title ?? NotionSchema.shared.titles[v] ?? "" })
        default: return Binding(get: { model.config.notionTasks.database }, set: { v in
            model.config.notionTasks.database = v; model.config.notionTasks.databaseName = dest.items.first { $0.id == v }?.title ?? NotionSchema.shared.titles[v] ?? "" })
        }
    }
    var name: String {
        let stored: String
        switch kind {
        case "meetings": stored = model.config.notionMeetingsName
        case "risks": stored = model.config.notionRisksName
        default: stored = model.config.notionTasks.databaseName
        }
        let v = id.wrappedValue
        if v.isEmpty { return L("ntset.notSet") }
        return [dest.items.first { $0.id == v }?.title, schema.titles[v], stored].compactMap { $0 }.first { !$0.isEmpty } ?? L("ntset.unnamedDb")
    }
    var prop: Binding<String>? {
        switch kind {
        case "meetings": return $model.config.notionMeetingsProp
        case "risks": return $model.config.notionRisksProp
        default: return nil          // tasks: the person and conditions under My tasks
        }
    }

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 8) {
                    if !id.wrappedValue.isEmpty {
                        Text(schema.counts[id.wrappedValue] ?? "").font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    }
                    Button { if dest.items.isEmpty && !dest.busy { dest.find() }; pop = true } label: {
                        HStack(spacing: 4) {
                            Text(name).lineLimit(1).foregroundStyle(id.wrappedValue.isEmpty ? PN.C.text3 : PN.C.text)
                            Image(systemName: "chevron.up.chevron.down").font(.caption2)
                        }
                        .frame(maxWidth: 220, alignment: .leading)
                    }
                    .buttonStyle(.pnSecondary)
                    .popover(isPresented: $pop, arrowEdge: .bottom) {
                        NotionDBSearchPopover(items: dest.items.filter { $0.kind == "data_source" }) { it in
                            if let it { id.wrappedValue = it.id } else { id.wrappedValue = "" }
                            pop = false
                        }
                    }
                }
                if let prop, !id.wrappedValue.isEmpty {
                    let ps = schema.props[id.wrappedValue] ?? []
                    HStack(spacing: 6) {
                        Text(L("ntset.projectProp")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                        Picker("", selection: prop) {
                            Text(L("ntset.propNone")).tag("")
                            if !prop.wrappedValue.isEmpty && !ps.contains(where: { $0.name == prop.wrappedValue }) {
                                Text(prop.wrappedValue).tag(prop.wrappedValue)
                            }
                            ForEach(ps, id: \.self) { p in Text(p.name + " (" + L("ntset.propType." + p.type) + ")").tag(p.name) }
                        }
                        .labelsHidden().controlSize(.small).fixedSize()
                        .help(L("ntset.projectProp.help"))
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("ntset.db." + kind))
                Text(L("ntset.db." + kind + ".sub")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
        }
        .onAppear { schema.load(id.wrappedValue) }
        .onChange(of: id.wrappedValue) { schema.load(id.wrappedValue) }
        .onChange(of: schema.props[id.wrappedValue]) {
            if let prop, prop.wrappedValue.isEmpty, let ps = schema.props[id.wrappedValue] { prop.wrappedValue = NotionSchema.autoProject(ps) }
        }
    }
}

/// 0.8.7 (F3): "Fill from project configs" found different databases in the configs: the PM picks one.
struct NotionFillChoices: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var schema = NotionSchema.shared
    @ObservedObject var dest = NotionDestinationModel.shared

    var body: some View {
        ForEach(["meetings", "tasks", "risks"], id: \.self) { kind in
            if let cs = schema.fillChoices[kind], cs.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("ntset.fill.differ", ["kind": L("ntset.db." + kind)])).font(PN.Font.caption).foregroundStyle(PN.C.text2)
                    ForEach(cs, id: \.self) { c in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(dest.items.first { NotionSchema.norm($0.id) == NotionSchema.norm(c.id) }?.title
                                     ?? schema.titles[c.id].flatMap { $0.isEmpty ? nil : $0 } ?? L("ntset.unnamedDb"))
                                Text(c.projects.joined(separator: ", ")).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(2)
                            }
                            Spacer()
                            Button(L("ntset.fill.use")) { use(kind, c.id) }.buttonStyle(.pnTertiary)
                        }
                        .onAppear { schema.load(c.id) }
                    }
                }
            }
        }
    }

    private func use(_ kind: String, _ id: String) {
        let n = schema.titles[id] ?? ""
        switch kind {
        case "meetings": model.config.notionMeetingsDB = id; model.config.notionMeetingsName = n
        case "risks": model.config.notionRisksDB = id; model.config.notionRisksName = n
        default: model.config.notionTasks.database = id; model.config.notionTasks.databaseName = n
        }
        schema.fillChoices[kind] = nil
    }
}

/// 0.8.7 (F7): a project's value in the meetings database's project property: the select or multi-select option names
/// or the titles of the relation's pages; several values as chips. Stored as Project.notionValue (comma-separated).
struct NotionValuePicker: View {
    @Binding var value: String
    let fallback: String               // the project name, used when nothing is chosen
    @ObservedObject var model: SettingsModel
    @ObservedObject var schema = NotionSchema.shared

    private var ds: String { model.config.notionMeetingsDB }
    private var prop: NotionSchema.Prop? {
        let ps = schema.props[ds] ?? []
        let name = model.config.notionMeetingsProp.isEmpty ? NotionSchema.autoProject(ps) : model.config.notionMeetingsProp
        return ps.first { $0.name == name }
    }
    private var values: [String] { value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }

    private func label(_ v: String) -> String {
        guard NotionTargets.isPageId(v) else { return v }
        if let t = schema.pageTitles[NotionSchema.norm(v)], !t.isEmpty { return t }
        return L("proj.unnamedPage")
    }

    private func toggle(_ v: String, multi: Bool) {
        var vs = values
        if let i = vs.firstIndex(of: v) { vs.remove(at: i) } else { vs = multi ? vs + [v] : [v] }
        value = vs.joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 4) {
            if let p = prop {
                let multi = p.type != "select"
                ForEach(values, id: \.self) { v in
                    HStack(spacing: 3) {
                        Text(label(v)).lineLimit(1)
                        if NotionTargets.isPageId(v) && (schema.pageTitles[NotionSchema.norm(v)] ?? "").isEmpty {
                            Button(L("common.open")) {
                                if let u = URL(string: "https://www.notion.so/" + NotionSchema.norm(v)) { NSWorkspace.shared.open(u) }
                            }.buttonStyle(.link)
                        }
                        Button { toggle(v, multi: true) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                            .accessibilityLabel(L("callEdit.remove"))
                    }
                    .font(PN.Font.caption).padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    .onAppear { if NotionTargets.isPageId(v) { schema.loadPage(v) } }
                }
                Menu {
                    if p.type == "relation" {
                        ForEach(schema.pages[p.relationDS] ?? [], id: \.self) { pg in
                            Toggle(pg.title.isEmpty ? L("proj.unnamedPage") : pg.title,
                                   isOn: Binding(get: { values.contains { NotionSchema.norm($0) == NotionSchema.norm(pg.id) } }, set: { _ in
                                       if let have = values.first(where: { NotionSchema.norm($0) == NotionSchema.norm(pg.id) }) { toggle(have, multi: true) } else { toggle(pg.id, multi: true) }
                                   }))
                        }
                        if (schema.pages[p.relationDS] ?? []).isEmpty { Text(L("common.checking")) }
                    } else {
                        ForEach(p.options, id: \.self) { o in
                            Toggle(o, isOn: Binding(get: { values.contains(o) }, set: { _ in toggle(o, multi: multi) }))
                        }
                        if p.options.isEmpty { Text(L("proj.noOptions")) }
                    }
                } label: {
                    Text(values.isEmpty ? fallback : (multi ? L("proj.addValue") : label(values[0]))).lineLimit(1)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .onAppear { if p.type == "relation" { schema.loadPages(p.relationDS) } }
            } else {
                // no project property known yet: the value as text, never an id
                TextField("", text: Binding(get: { values.map(label).joined(separator: ", ") }, set: { value = $0 }), prompt: Text(fallback))
                    .textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 140)
                    .disabled(values.contains { NotionTargets.isPageId($0) })
            }
        }
        .onAppear { schema.load(ds) }
    }
}
