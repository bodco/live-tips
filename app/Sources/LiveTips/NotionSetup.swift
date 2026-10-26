import AppKit
import LiveTipsCore
import SwiftUI

/// Where meeting pages go in Notion (2026-10-26, owner: "people do not know where the key comes from and
/// what happens next"). Works without Control Tower: the PM shares a page with the integration, then picks
/// a database (missing properties are added) or lets Live Tips create a "Meetings" database on a page.
/// A project with a Control Tower config keeps writing to the config's meetings_db.
enum NotionAPI {
    static let version = "2025-09-03"

    struct Item: Identifiable, Hashable {
        let id: String
        let kind: String          // "data_source" | "page"
        let title: String
    }

    static func call(_ token: String, _ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://api.notion.com/v1" + path)!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(version, forHTTPHeaderField: "Notion-Version")
        req.timeoutInterval = 30
        if let body = body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code >= 300 {
            throw NSError(domain: "Notion", code: code, userInfo: [NSLocalizedDescriptionKey: (obj["message"] as? String) ?? "HTTP \(code)"])
        }
        return obj
    }

    static func plain(_ rich: Any?) -> String {
        ((rich as? [[String: Any]]) ?? []).compactMap { $0["plain_text"] as? String }.joined()
    }

    /// Databases and pages the integration can see (shared with it through ••• > Connections).
    static func search(_ token: String) async throws -> [Item] {
        var out: [Item] = []
        var cursor: String?
        repeat {
            var body: [String: Any] = ["page_size": 100]
            if let c = cursor { body["start_cursor"] = c }
            let r = try await call(token, "POST", "/search", body)
            for o in (r["results"] as? [[String: Any]]) ?? [] {
                guard let id = o["id"] as? String, let kind = o["object"] as? String else { continue }
                if kind == "data_source" || kind == "database" {
                    let t = plain(o["title"])
                    out.append(Item(id: id, kind: "data_source", title: t.isEmpty ? "Untitled database" : t))
                } else if kind == "page" {
                    // only pages at the top of what was shared, not every row of every database
                    let parent = (o["parent"] as? [String: Any])?["type"] as? String ?? ""
                    if parent == "data_source_id" || parent == "database_id" { continue }
                    let props = (o["properties"] as? [String: [String: Any]]) ?? [:]
                    let t = props.values.first { ($0["type"] as? String) == "title" }.map { plain($0["title"]) } ?? ""
                    out.append(Item(id: id, kind: "page", title: t.isEmpty ? "Untitled page" : t))
                }
            }
            cursor = (r["has_more"] as? Bool) == true ? r["next_cursor"] as? String : nil
        } while cursor != nil && out.count < 300
        return out.sorted { ($0.kind, $0.title.lowercased()) < ($1.kind, $1.title.lowercased()) }
    }

    /// What a database lacks for meeting pages: a date and a text property for the summary.
    static func missing(_ token: String, _ ds: String) async throws -> [String] {
        let r = try await call(token, "GET", "/data_sources/\(ds)")
        let props = (r["properties"] as? [String: [String: Any]]) ?? [:]
        var m: [String] = []
        if !props.values.contains(where: { ($0["type"] as? String) == "date" }) { m.append("Date") }
        if (props["Summary"]?["type"] as? String) != "rich_text" { m.append("Summary") }
        if props["Project"] == nil { m.append("Project") }
        return m
    }

    static func addProperties(_ token: String, _ ds: String, _ names: [String]) async throws {
        var p: [String: Any] = [:]
        for n in names {
            switch n {
            case "Date": p["Date"] = ["date": [String: Any]()]
            case "Summary": p["Summary"] = ["rich_text": [String: Any]()]
            case "Project": p["Project"] = ["select": [String: Any]()]
            default: break
            }
        }
        if !p.isEmpty { _ = try await call(token, "PATCH", "/data_sources/\(ds)", ["properties": p]) }
    }

    /// Creates a "Meetings" database on a page; returns its data source id.
    static func createMeetings(_ token: String, page: String) async throws -> String {
        let props: [String: Any] = ["Meeting Name": ["title": [String: Any]()], "Date": ["date": [String: Any]()],
                                    "Summary": ["rich_text": [String: Any]()], "Project": ["select": [String: Any]()]]
        let r = try await call(token, "POST", "/databases", [
            "parent": ["type": "page_id", "page_id": page],
            "title": [["type": "text", "text": ["content": "Meetings"]]],
            "initial_data_source": ["properties": props]])
        if let ds = ((r["data_sources"] as? [[String: Any]])?.first?["id"] as? String) { return ds }
        throw NSError(domain: "Notion", code: 0, userInfo: [NSLocalizedDescriptionKey: "the database was created, but Notion did not return its id"])
    }
}

@MainActor
final class NotionDestinationModel: ObservableObject {
    static let shared = NotionDestinationModel()
    @Published var items: [NotionAPI.Item] = []
    @Published var busy = false
    @Published var note = ""
    @Published var searched = false
    let settings = SettingsWindow.model

    var token: String? {
        SecretStore(service: Bundle.main.bundleIdentifier ?? "io.github.example.livetips").get(.notionToken)
    }

    func find() {
        guard let t = token else { note = "Save the Notion token first."; return }
        busy = true; note = "Looking for what the integration can see…"
        Task {
            do {
                items = try await NotionAPI.search(t)
                note = items.isEmpty ? "The integration sees nothing yet: share a page with it (step 3), then Find again." : ""
            } catch { note = "Notion: " + error.localizedDescription }
            searched = true; busy = false
        }
    }

    func use(_ it: NotionAPI.Item) {
        guard let t = token else { return }
        busy = true; note = "Checking \(it.title)…"
        Task {
            do {
                let miss = try await NotionAPI.missing(t, it.id)
                if !miss.isEmpty { try await NotionAPI.addProperties(t, it.id, miss) }
                choose(id: it.id, name: it.title)
                note = miss.isEmpty ? "Meeting pages go to \(it.title)." : "Meeting pages go to \(it.title); added the properties " + miss.joined(separator: ", ") + "."
            } catch { note = "Notion: " + error.localizedDescription }
            busy = false
        }
    }

    func create(on page: NotionAPI.Item) {
        guard let t = token else { return }
        busy = true; note = "Creating a Meetings database on \(page.title)…"
        Task {
            do {
                let ds = try await NotionAPI.createMeetings(t, page: page.id)
                choose(id: ds, name: "Meetings (\(page.title))")
                note = "Created Meetings on \(page.title). Meeting pages go there."
                items = (try? await NotionAPI.search(t)) ?? items
            } catch { note = "Notion: " + error.localizedDescription }
            busy = false
        }
    }

    private func choose(id: String, name: String) {
        settings.config.notionMeetingsDB = id
        settings.config.notionMeetingsName = name
        settings.config.notionWriteSummary = true
    }

    func clear() {
        settings.config.notionMeetingsDB = ""
        settings.config.notionMeetingsName = ""
        note = ""
    }
}

/// The steps and the picker, shared by the welcome tour and Settings > General.
struct NotionDestinationView: View {
    @ObservedObject var m = NotionDestinationModel.shared
    @ObservedObject var settings = SettingsWindow.model
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !settings.config.notionMeetingsDB.isEmpty {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Meeting pages go to ") + Text(settings.config.notionMeetingsName.isEmpty ? "the chosen database" : settings.config.notionMeetingsName).bold()
                    Spacer()
                    Button("Change") { m.clear(); m.find() }.controlSize(.small)
                }
            } else {
                HStack {
                    Text("Where meeting pages go").font(.callout.weight(.medium))
                    Spacer()
                    if m.busy { ProgressView().controlSize(.small) }
                    Button(m.searched ? "Find again" : "Find") { m.find() }.controlSize(.small)
                        .disabled(m.busy || !settings.isSet(.notionToken))
                }
                let dbs = m.items.filter { $0.kind == "data_source" }
                let pages = m.items.filter { $0.kind == "page" }
                if !m.items.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(dbs) { it in
                                HStack {
                                    Image(systemName: "tablecells").foregroundStyle(.secondary)
                                    Text(it.title).lineLimit(1)
                                    Spacer()
                                    Button("Use") { m.use(it) }.controlSize(.small).disabled(m.busy)
                                }
                            }
                            ForEach(pages) { it in
                                HStack {
                                    Image(systemName: "doc").foregroundStyle(.secondary)
                                    Text(it.title).lineLimit(1)
                                    Spacer()
                                    Button("Create Meetings here") { m.create(on: it) }.controlSize(.small).disabled(m.busy)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: compact ? 110 : 140)
                }
            }
            if !m.note.isEmpty { Text(m.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// Real app icons for the welcome tour (the installed Claude or Notion app), else a plain symbol.
enum AppLogo {
    static func image(bundleIDs: [String], appNames: [String]) -> NSImage? {
        for id in bundleIDs {
            if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return NSWorkspace.shared.icon(forFile: u.path) }
        }
        for n in appNames {
            for dir in ["/Applications", NSHomeDirectory() + "/Applications"] {
                let p = dir + "/" + n + ".app"
                if FileManager.default.fileExists(atPath: p) { return NSWorkspace.shared.icon(forFile: p) }
            }
        }
        return nil
    }
    static var claude: NSImage? { image(bundleIDs: ["com.anthropic.claudefordesktop"], appNames: ["Claude"]) }
    static var notion: NSImage? { image(bundleIDs: ["notion.id"], appNames: ["Notion"]) }
}

/// System audio recording permission (macOS 14.4+ audio taps). There is no public API to read it, so
/// this asks TCC the way Apple's own sample apps do; nil when that is not available.
enum SystemAudioPermission {
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)

    /// true granted, false denied, nil not decided yet or unknown.
    static func granted() -> Bool? {
        guard let h = tcc, let sym = dlsym(h, "TCCAccessPreflight") else { return nil }
        let r = unsafeBitCast(sym, to: Preflight.self)("kTCCServiceAudioCapture" as CFString, nil)
        return r == 0 ? true : (r == 1 ? false : nil)
    }

    static func request(_ done: @escaping (Bool) -> Void) -> Bool {
        guard let h = tcc, let sym = dlsym(h, "TCCAccessRequest") else { return false }
        unsafeBitCast(sym, to: Request.self)("kTCCServiceAudioCapture" as CFString, nil) { ok in
            DispatchQueue.main.async { done(ok) }
        }
        return true
    }
}
