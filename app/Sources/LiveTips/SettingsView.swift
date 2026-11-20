import AppKit
import AVFoundation
import LiveTipsCore
import SwiftUI

enum AppPaths {
    static var support: URL {
        // Screenshot mode (--shots) runs on demo data in its own folder, never on the PM's projects.
        if let d = ProcessInfo.processInfo.environment["LT_SUPPORT_DIR"], !d.isEmpty { return URL(fileURLWithPath: d) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LiveTips")
    }
    static var config: URL { support.appendingPathComponent("config.json") }
    static var projects: URL { support.appendingPathComponent("projects.json") }
}

enum KeyState: Equatable {
    case notSet, untested, ok(String), failed(String), testing
}

/// Checks a key with one cheap read-only request. Never logs the key.
enum KeyTester {
    static func claude(key: String, workspace: String?) async -> (Bool, String, [String]) {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=100")!)
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if let w = workspace, !w.isEmpty { req.setValue(w, forHTTPHeaderField: "anthropic-workspace-id") }
        req.timeoutInterval = 15
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if code == 200 {
                let ids = ((obj?["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
                return (true, "Works, \(ids.count) models available", ids)
            }
            let msg = ((obj?["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(code)"
            return (false, msg, [])
        } catch {
            return (false, error.localizedDescription, [])
        }
    }

    static func openai(key: String) async -> (Bool, String) {
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/models/gpt-6-luna")!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return (code == 200, code == 200 ? "GPT-6 Luna" : "HTTP \(code)")
        } catch { return (false, error.localizedDescription) }
    }

    /// 0.9.3: a free metadata read of one model with the key (no tokens billed). A key of a free-tier project answers
    /// too: the PM is told in the hint to use a key of a project with billing on.
    static func gemini(key: String) async -> (Bool, String) {
        var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-flash-lite")!)
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.timeoutInterval = 15
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return (code == 200, code == 200 ? "Gemini 3.5 Flash-Lite" : "HTTP \(code)")
        } catch { return (false, error.localizedDescription) }
    }

    static func notion(token: String) async -> (Bool, String) {
        var req = URLRequest(url: URL(string: "https://api.notion.com/v1/users/me")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        req.timeoutInterval = 15
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if code == 200 { return (true, "Works, integration: \(obj?["name"] as? String ?? "ok")") }
            return (false, (obj?["message"] as? String) ?? "HTTP \(code)")
        } catch {
            return (false, error.localizedDescription)
        }
    }
}

@MainActor
final class SettingsModel: ObservableObject {
    /// 0.24.1 (F3): the model Settings and the onboarding show, so AIRoute.autoAssign changes it instead of a file
    /// the model would write over.
    static weak var live: SettingsModel?
    @Published var config = AppConfig.load(from: AppPaths.config) {
        didSet {
            guard config != oldValue else { return }
            saveConfig()
            let support = AppPaths.support.path
            let was = oldValue.effectiveAppRoot(appSupport: support), now = config.effectiveAppRoot(appSupport: support)
            if was != now { scheduleFolderMove(from: was) }
        }
    }
    /// The app folder follows the work folder (or the override). Its files move once the path has
    /// stayed the same for 1.5 s and its parent folder exists, so typing a path does not move anything.
    private var moveFrom: String?
    private var moveWork: DispatchWorkItem?
    func scheduleFolderMove(from old: String) {
        if moveFrom == nil { moveFrom = old }
        moveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let from = self.moveFrom else { return }
                let to = self.config.effectiveAppRoot(appSupport: AppPaths.support.path)
                guard FileManager.default.fileExists(atPath: (to as NSString).deletingLastPathComponent) else { return }
                self.moveFrom = nil
                AppFolderMover.relocate(from: from, to: to)
            }
        }
        moveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }
    @Published var registry = ProjectRegistry.load(from: AppPaths.projects) {
        didSet {
            // 0.17.0 (5.1): a renamed or edited sample project becomes the PM's own (and may sync)
            if registry.projects.contains(where: { $0.sample && !SampleProject.pristine($0) }) { registry.projects = registry.projects.map(SampleProject.settle) }
            if registry != oldValue { saveRegistry() }
        }
    }
    @Published var keyState: [SecretStore.Key: KeyState] = [:]
    @Published var masks: [SecretStore.Key: String] = [:]
    @Published var mirror = MirrorStatus(result: "", lastRunUTC: nil, pages: nil, mode: "")
    @Published var note = ""
    // 0.8.7 (F1): Notion, Calendars and the keys live under Integrations; old names open the matching page there
    @Published var tab = "general" {
        didSet {
            if ["notion", "keys", "calendars", "hubspot", "google"].contains(tab) { integration = tab == "keys" ? "notion" : tab; tab = "integrations" }
        }
    }
    @Published var integration: String? = nil
    /// 0.19.0 (S4): the pane as `settings` screen_view names it (an Integrations page with its own name where the
    /// catalog has one).
    static func trackedPane(_ tab: String, _ integration: String?) -> String {
        if tab == "integrations", let i = integration, ["calendars", "notion", "keys"].contains(i) { return i }
        return tab
    }
    /// 0.15.0 (D2): the project whose own page is open under Settings > Projects.
    @Published var projectDetail: String? = nil
    /// 0.15.0 (D2): the search query in the sidebar and the row a result marks for a moment.
    @Published var search = ""
    @Published var highlight: String? = nil
    @Published var aliasesText = ""
    @Published var mirrorNote = ""

    // Voice library (<app folder>/voices/voices.json): team voices for every project, clients per project (D3).
    /// 2026-10-27 (owner): side (our team or the client's) and where (all projects, workspaces, projects) are separate.
    struct Voice: Identifiable { let name: String; let side: String; let wherer: [String]; let calls: Int; var id: String { name } }
    static func side(of p: [String: Any]) -> String {
        if let s = p["side"] as? String, s == "team" || s == "client" { return s }
        let sc = (p["scope"] as? String) ?? ""
        return sc == "team" ? "team" : (sc.isEmpty ? "" : "client")
    }
    static func whereOf(_ p: [String: Any]) -> [String] {
        if let w = p["where"] as? [String], !w.isEmpty { return w }
        let sc = (p["scope"] as? String) ?? ""
        return (sc.isEmpty || sc == "team") ? ["all"] : [sc]
    }
    @Published var voices: [Voice] = []
    var voicesPath: String { (CallEngine.shared.appRoot as NSString).appendingPathComponent("voices/voices.json") }
    func loadVoices() {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: voicesPath)),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let people = o["people"] as? [String: Any] else { voices = []; return }
        voices = people.compactMap { k, v in
            guard let p = v as? [String: Any] else { return nil }
            return Voice(name: k, side: Self.side(of: p), wherer: Self.whereOf(p), calls: (p["calls"] as? Int) ?? 0)
        }.sorted { ($0.side == "team" ? 0 : 1, $0.name) < ($1.side == "team" ? 0 : 1, $1.name) }
    }
    /// Removes one person's voice prints (not during a call: the recorder writes the file then).
    func forgetVoice(_ name: String) {
        guard !CallEngine.shared.isRunning, let d = try? Data(contentsOf: URL(fileURLWithPath: voicesPath)),
              var o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              var people = o["people"] as? [String: Any] else { return }
        people.removeValue(forKey: name)
        o["people"] = people
        if let out = try? JSONSerialization.data(withJSONObject: o) { try? out.write(to: URL(fileURLWithPath: voicesPath), options: .atomic) }
        loadVoices()
    }
    /// 0.8.5 (owner, rules/voices.yaml): two entries are one person ("Maria H." and "m.holosovska" are "Mariia H.").
    /// 0.9.4 (owner): the PM picks the name to keep (either one or a new full name, "M. T." + "Mike T." = "Mike
    /// Turner"); both old names and their aliases name that person from then on. Not during a call.
    func mergeVoice(_ src: String, into dst: String, keep: String? = nil) {
        editLibrary { VoiceBook.merge($0, src, dst, keep: keep ?? dst) }
        UsageLog.log("speakers_merged", ["aliases": VoiceBook.aliasesOf(readLibrary(), keep ?? dst).count])
        EditLog.add(kind: "speakers_merge", title: "", project: "", fields: ["before": [src, dst], "after": keep ?? dst])
    }
    func renameVoice(_ old: String, to new: String) { editLibrary { VoiceBook.rename($0, old, to: new) } }
    /// nil when added, otherwise why not (a person's own name, or another person's alias).
    func addVoiceAlias(_ alias: String, to name: String, force: Bool = false) -> VoiceBook.AddResult {
        var res = VoiceBook.AddResult.added
        editLibrary { let (o, r) = VoiceBook.addAlias($0, alias, to: name, force: force); res = r; return o }
        return res
    }
    func removeVoiceAlias(_ alias: String) { editLibrary { VoiceBook.removeAlias($0, alias) } }
    func voiceAliasesOf(_ name: String) -> [String] { VoiceBook.aliasesOf(readLibrary(), name) }
    func readLibrary() -> [String: Any] {
        FileManager.default.contents(atPath: voicesPath).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
    }
    private func editLibrary(_ change: ([String: Any]) -> [String: Any]) {
        guard !CallEngine.shared.isRunning else { return }
        var o = readLibrary()
        if o["people"] == nil { o["people"] = [String: Any]() }
        let out = change(o)
        try? FileManager.default.createDirectory(atPath: (voicesPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: out) { try? d.write(to: URL(fileURLWithPath: voicesPath), options: .atomic) }
        loadVoices()
    }
    @Published var personSheet: String? = nil          // 0.9.4: the person whose names are edited
    @Published var mergeAsk: MergeAsk? = nil           // 0.9.4: which name to keep
    struct MergeAsk: Identifiable { let a: String; let b: String; var id: String { a + "|" + b } }
    var voiceAliases: [String: String] {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: voicesPath)),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return (o["aliases"] as? [String: String]) ?? [:]
    }

    static func whereLabel(_ w: [String]) -> String {
        if w.contains("all") { return L("set.allProjects") }
        let parts = w.map { x -> String in
            if x.hasPrefix("project:") { return String(x.dropFirst(8)) }
            if x.hasPrefix("workspace:") { return L("set.whereWorkspace", ["name": String(x.dropFirst(10))]) }
            return x
        }
        return parts.isEmpty ? L("set.nowhere") : parts.joined(separator: ", ")
    }
    var voiceWheres: [(tag: String, label: String)] {
        var out: [(String, String)] = [("all", L("set.allProjects"))]
        for w in registry.workspaces { out.append(("workspace:" + w.name, L("set.workspaceAll", ["name": w.name]))) }
        for p in registry.projects where p.status != "archived" { out.append(("project:" + p.slug, L("set.projectNamed", ["name": p.name]))) }
        return out
    }
    private func editVoice(_ name: String, _ change: (inout [String: Any]) -> Void) {
        guard !CallEngine.shared.isRunning, let d = try? Data(contentsOf: URL(fileURLWithPath: voicesPath)),
              var o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              var people = o["people"] as? [String: Any], var p = people[name] as? [String: Any] else { return }
        change(&p)
        let side = Self.side(of: p), wh = Self.whereOf(p)
        p["scope"] = wh.contains("all") ? (side == "team" ? "team" : "") : (wh.first ?? "")     // older recorders
        people[name] = p
        o["people"] = people
        if let out = try? JSONSerialization.data(withJSONObject: o) { try? out.write(to: URL(fileURLWithPath: voicesPath), options: .atomic) }
        loadVoices()
    }
    func setVoiceSide(_ name: String, _ side: String) { editVoice(name) { $0["side"] = side } }
    func toggleVoiceWhere(_ name: String, _ tag: String) {
        editVoice(name) { p in
            var w = Self.whereOf(p)
            if tag == "all" { w = w.contains("all") ? [] : ["all"] }
            else {
                w.removeAll { $0 == "all" }
                if let i = w.firstIndex(of: tag) { w.remove(at: i) } else { w.append(tag) }
            }
            p["where"] = w.isEmpty ? ["all"] : w
            if p["side"] == nil { p["side"] = Self.side(of: p).isEmpty ? "client" : Self.side(of: p) }
        }
    }
    static func scopeLabel(_ s: String) -> String {
        if s == "team" { return L("set.teamAll") }
        if s.hasPrefix("project:") { return L("set.clientOf", ["name": String(s.dropFirst(8))]) }
        if s.hasPrefix("workspace:") { return L("set.workspaceAllShort", ["name": String(s.dropFirst(10))]) }
        return L("set.allBeforeScopes")
    }

    /// 2026-10-26 (owner): where a voice is suggested: the team (every project), one project, or a whole workspace.
    var voiceScopes: [(tag: String, label: String)] {
        var out: [(String, String)] = [("team", L("set.teamAll"))]
        for w in registry.workspaces { out.append(("workspace:" + w.name, L("set.workspaceAllShort", ["name": w.name]))) }
        for w in registry.workspaces { out.append(("project:" + w.name.lowercased(), L("set.wsCallsOnly", ["name": w.name]))) }
        for p in registry.projects where p.status != "archived" { out.append(("project:" + p.slug, L("set.projectNamed", ["name": p.name]))) }
        return out
    }

    func setVoiceScope(_ name: String, _ scope: String) {
        guard !CallEngine.shared.isRunning, let d = try? Data(contentsOf: URL(fileURLWithPath: voicesPath)),
              var o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              var people = o["people"] as? [String: Any], var p = people[name] as? [String: Any] else { return }
        p["scope"] = scope
        people[name] = p
        o["people"] = people
        if let out = try? JSONSerialization.data(withJSONObject: o) { try? out.write(to: URL(fileURLWithPath: voicesPath), options: .atomic) }
        loadVoices()
    }

    /// The folder with the imported project configs (projects/<slug>.md) feeds the mirror's layout.
    func setUpMirror() {
        let configsDir = registry.projects.first.map { ($0.config as NSString).deletingLastPathComponent } ?? ""
        mirrorNote = L("set.mirrorSettingUp")
        NotionMirrorService.shared.setUp(configsDir: configsDir) { ok, msg in
            DispatchQueue.main.async { [weak self] in
                self?.mirrorNote = msg
                self?.refreshMirror()
                if ok { DispatchQueue.main.asyncAfter(deadline: .now() + 60) { self?.refreshMirror() } }
            }
        }
    }
    let store = SecretStore(service: Bundle.main.bundleIdentifier ?? "io.github.example.livetips")

    init() {
        // 0.8.7.1: presence only at start; the masks are read when a key row is shown (KeyRow.onAppear). Reading every
        // secret here froze Home on the Keychain's "allow access" prompt for a key another tool had saved (HubSpot).
        for k in [SecretStore.Key.claudeAPIKey, .openaiAPIKey, .geminiAPIKey, .notionToken] {
            keyState[k] = store.has(k) ? .untested : .notSet
        }
        refreshMirror()
        aliasesText = config.nameAliases.joined(separator: ", ")
        for k in [SecretStore.Key.claudeAPIKey, .openaiAPIKey, .geminiAPIKey, .notionToken] where store.has(k) { test(k) }
        if Self.live == nil { Self.live = self }
    }

    func saveAliases() {
        config.nameAliases = aliasesText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func removeProject(_ slug: String) { registry.projects.removeAll { $0.slug == slug } }

    static func friendly(_ msg: String) -> String {
        let m = msg.lowercased()
        if m.contains("401") || m.contains("invalid x-api-key") || m.contains("authentication") || m.contains("unauthorized") {
            return L("keys.err.rejected")
        }
        if m.contains("403") || m.contains("permission") { return L("keys.err.noAccess") }
        if m.contains("429") || m.contains("rate") { return L("keys.err.rate") }
        if m.contains("offline") || m.contains("network") || m.contains("internet") || m.contains("timed out") {
            return L("keys.err.offline")
        }
        return msg
    }

    var mirrorHealth: String { mirror.health() }

    var mirrorLastRunText: String {
        guard let t = mirror.lastRunUTC else { return "" }
        let rel = RelativeDateTimeFormatter().localizedString(for: t, relativeTo: Date())
        var pagesText = ""
        if let n = mirror.pages { pagesText = ", \(n) pages" }
        return "updated " + rel + pagesText
    }

    func refreshMasks() { for k in SecretStore.Key.allCases { masks[k] = maskedSecret(store.get(k)) } }
    func refreshMask(_ k: SecretStore.Key) { if masks[k] == nil { masks[k] = maskedSecret(store.get(k)) } }     // 0.8.7.1
    func isSet(_ k: SecretStore.Key) -> Bool { store.has(k) }     // 0.8.7.1: presence only
    /// INT S2: Notion is connected, through OAuth (Connect with Notion) or a key pasted under Advanced.
    var notionConnected: Bool { store.has(.notionOAuth) || store.has(.notionToken) }

    func refreshMirror() {
        mirror = config.workRoot.isEmpty ? MirrorStatus(result: "", lastRunUTC: nil, pages: nil, mode: "") : MirrorStatus.load(workRoot: config.workRoot)
    }

    func save(_ key: SecretStore.Key, _ value: String) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        guard store.set(key, v) else { keyState[key] = .failed(L("keys.err.keychain")); return }
        refreshMasks()
        test(key)
        AIRoute.autoAssign()        // 0.24.1 (F3): a new AI key does the jobs whose AI is not there
    }

    func remove(_ key: SecretStore.Key) {
        store.remove(key)
        keyState[key] = .notSet
        refreshMasks()
        AIRoute.autoAssign()        // 0.24.1 (F3): the jobs move to an AI that is still connected
    }

    func test(_ key: SecretStore.Key) {
        keyState[key] = .testing
        let svc = store.service, raw = key.rawValue
        Task {
            // 0.8.7.1: the Keychain read runs off the main thread; on a new build macOS asks "allow access" and the
            // app froze on that prompt at start (Home never appeared until it was answered).
            let got = await Task.detached(priority: .userInitiated) { () -> String? in
                SecretStore.Key(rawValue: raw).flatMap { SecretStore(service: svc).get($0) }
            }.value
            guard let v = got else { keyState[key] = .notSet; return }
            if key == .hubspotKey {
                keyState[key] = .ok("")
                CRMService.shared.test()
            } else if key == .openaiAPIKey {
                let (ok, msg) = await KeyTester.openai(key: v)
                keyState[key] = ok ? .ok(msg) : .failed(msg)
                if ok { ModelCatalogStore.shared.refresh(.openai, force: true) }
            } else if key == .geminiAPIKey {
                let (ok, msg) = await KeyTester.gemini(key: v)
                keyState[key] = ok ? .ok(msg) : .failed(msg)
                if ok { ModelCatalogStore.shared.refresh(.gemini, force: true) }
            } else if key == .claudeAPIKey {
                let (ok, msg, ids) = await KeyTester.claude(key: v, workspace: nil)
                keyState[key] = ok ? .ok(msg) : .failed(SettingsModel.friendly(msg))
                if ok, !ids.isEmpty { config.knownModels = ids }
                if ok { ModelCatalogStore.shared.refresh(.claude, force: true) }
            } else {
                let (ok, msg) = await KeyTester.notion(token: v)
                keyState[key] = ok ? .ok(msg) : .failed(SettingsModel.friendly(msg))
            }
        }
    }

    var modelChoices: [String] {
        let base = config.knownModels.isEmpty ? AppConfig.fallbackModels : config.knownModels
        return base.filter { $0.contains("haiku") || $0.contains("sonnet") || $0.contains("opus") || $0.contains("fable") }
    }

    func chooseFolder(_ message: String) -> String? {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.message = message
        return p.runModal() == .OK ? p.url?.path : nil
    }

    func importProjects() {
        guard let dir = chooseFolder(L("set.chooseConfigs")) else { return }
        let found = ProjectConfigImporter.importFolder(dir)
        registry.merge(imported: found)
        rescanWorkspaces()
        note = L("set.imported", ["n": "\(found.count)"])
    }

    func rescanWorkspaces() {
        guard !config.workRoot.isEmpty else { return }
        registry.setWorkspaces(WorkspaceScanner.scan(workRoot: config.workRoot, projects: registry.projects,
                                                     extra: registry.extraWorkspaces, excluded: registry.excluded))   // 0.8.8: keeps In Notion
    }

    // ---- folder projects (2026-10-26: Notion and configs are optional)
    func scanFolders() {
        guard !config.workRoot.isEmpty else { note = L("set.setTheWorkFolder"); return }
        let before = registry.projects.count
        let r = WorkspaceScanner.scanFolders(workRoot: config.workRoot, extra: registry.extraWorkspaces, excluded: registry.excluded)
        registry.merge(folders: r.projects)
        rescanWorkspaces()
        note = L("set.scanNote", ["ws": "\(r.workspaces.count)", "new": "\(registry.projects.count - before)"])     // 0.8.7.1: translated
        IndexService.shared.configure(projects: registry.projects, appRoot: CallEngine.shared.appRoot,
                                      python: config.engine.python, enabled: config.localAI.enabled)
    }

    var folderCandidates: [(dir: String, projects: Int)] {
        guard !config.workRoot.isEmpty else { return [] }
        return WorkspaceScanner.candidates(workRoot: config.workRoot, known: registry.extraWorkspaces, excluded: registry.excluded)
    }

    func workspaceHasNotion(_ w: Workspace) -> Bool {
        var dir = w.root
        if (dir as NSString).lastPathComponent.lowercased().hasSuffix(" general") { dir = (dir as NSString).deletingLastPathComponent }
        return FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent("_notion/workspace.md"))
    }

    func addWorkspace(_ dir: String) {
        if !registry.extraWorkspaces.contains(dir) { registry.extraWorkspaces.append(dir) }
        registry.excluded.removeAll { $0 == dir }
        scanFolders()
    }

    func ignoreFolder(_ dir: String) {
        if !registry.excluded.contains(dir) { registry.excluded.append(dir) }
    }

    func addWorkspaceFolder() {
        guard let dir = chooseFolder(L("set.chooseWorkspace")) else { return }
        addWorkspace(dir)
    }

    func addProjectFolder() {
        guard let dir = chooseFolder(L("set.chooseProject")) else { return }
        registry.excluded.removeAll { $0 == dir }
        var p = Project(name: (dir as NSString).lastPathComponent, slug: WorkspaceScanner.slug((dir as NSString).lastPathComponent), root: dir)
        p.workspace = ((dir as NSString).deletingLastPathComponent as NSString).lastPathComponent
        registry.merge(folders: [p])
        rescanWorkspaces()
        note = L("set.added", ["name": p.name])
    }

    /// Takes a workspace out of Live Tips: its folder is ignored by scans and its projects leave the list.
    /// Nothing on disk changes; Add > Workspace folder brings it back.
    func removeWorkspace(_ w: Workspace) {
        var dir = w.root
        if (dir as NSString).lastPathComponent.lowercased().hasSuffix(" general") { dir = (dir as NSString).deletingLastPathComponent }
        registry.extraWorkspaces.removeAll { $0 == dir }
        if !registry.excluded.contains(dir) { registry.excluded.append(dir) }
        registry.projects.removeAll { !$0.root.isEmpty && ($0.root + "/").hasPrefix(dir + "/") }
        rescanWorkspaces()
        note = L("set.removedWs", ["name": w.name])
    }

    func excludeProject(_ slug: String) {
        if let p = registry.projects.first(where: { $0.slug == slug }), !p.root.isEmpty, !registry.excluded.contains(p.root) {
            registry.excluded.append(p.root)
        }
        removeProject(slug)
        rescanWorkspaces()
    }

    func saveConfig() { try? config.save(to: AppPaths.config); L10n.set(config.uiLanguage) }
    @Published var localAIStatus: (ok: Bool, text: String) = (false, "Checking…")
    func refreshLocalAI(after delay: Double = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.localAIStatus = LocalAIService.shared.statusLine() }
        }
    }
    func saveRegistry() { try? registry.save(to: AppPaths.projects) }
}

/// "claude-sonnet-4-5-20250929" -> "Sonnet 4.5"; unknown ids stay as they are.
func prettyModel(_ id: String) -> String {
    let parts = id.split(separator: "-").map(String.init)
    guard let i = parts.firstIndex(where: { ["haiku", "sonnet", "opus", "fable"].contains($0) }) else { return id }
    let nums = parts[(i + 1)...].prefix { $0.count <= 2 && Int($0) != nil }
    return parts[i].capitalized + (nums.isEmpty ? "" : " " + nums.joined(separator: "."))
}

struct ModelPicker: View {
    let title: String
    @Binding var selection: String
    let choices: [String]
    /// 0.26.2: the provider's own model list (ModelCatalogStore) instead of `choices`, once it has been read.
    var provider: ModelCatalog.Provider? = nil
    @ObservedObject var catalog = ModelCatalogStore.shared

    private var rows: [(id: String, name: String)] {
        guard let p = provider, !catalog.entries(p).isEmpty else { return choices.map { (id: $0, name: prettyModel($0)) } }
        return ModelCatalog.choices(p, live: catalog.entries(p), selected: selection).map { (id: $0.id, name: Self.name($0)) }
    }

    static func name(_ e: ModelCatalog.Entry) -> String {
        let pretty = prettyModel(e.id)
        return (pretty == e.id ? e.label : pretty) + (e.known ? "" : L("ai.model.priceUnknown"))
    }

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(rows, id: \.id) { m in
                Text(m.name).tag(m.id)          // 0.8.7 (F6): the model id only in the tooltip
            }
        }
        .help(selection)
        .onAppear { if let p = provider { catalog.refresh(p) } }
    }
}

// MARK: - Small views

struct StateIcon: View {
    let state: KeyState
    var body: some View {
        Group {
            switch state {
            case .notSet: Image(systemName: "circle.dashed").foregroundStyle(PN.C.text3).help(L("callSettings.role.none"))
            case .untested: Image(systemName: "circle.fill").foregroundStyle(.yellow).help(L("set.savedChecking"))
            case .testing: PNSpinner(size: 16)
            case .ok(let m): Image(systemName: "checkmark.circle.fill").foregroundStyle(PN.C.turn).help(m)
            case .failed(let m): Image(systemName: "xmark.octagon.fill").foregroundStyle(PN.C.danger).help(m)
            }
        }
        .frame(width: 16, height: 16)
    }
}

struct IconButton: View {
    let symbol: String
    let label: String
    var role: ButtonRole? = nil
    let action: () -> Void
    var body: some View {
        Button(role: role, action: action) {
            Label(label, systemImage: symbol).labelStyle(.iconOnly).frame(width: 18, height: 18)
        }
        .help(label)
    }
}

/// Pacenote 0.8 (F4, spec 8): a key is a status line (Connected, Not set, the error) and one menu (Replace, Test, Remove);
/// the field shows only when there is no key yet or while replacing it.
/// 0.8.2: the way one job reaches Claude: the PM's Claude account (Claude Code) or the API key.
/// 0.8.5 (owner): the model on this Mac for a job: the models Ollama has, or Install Gemma when it has none.
struct LocalModelRow: View {
    @ObservedObject var local = LocalLLM.shared
    @State private var pick = LocalLLM.model
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if local.running && !local.models.isEmpty {
                Picker(L("set.model"), selection: $pick) {
                    ForEach(local.models, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: pick) { LocalLLM.model = pick }
            }
            LocalStatus(local: local)
        }
        .onAppear { local.refresh(); if !local.models.contains(pick), let f = local.models.first { pick = f } }
    }
}

/// Ollama's state and the one action that moves it on: Get Ollama, Start Ollama, Install Gemma, or the progress.
struct LocalStatus: View {
    @ObservedObject var local: LocalLLM
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if !local.installed {
                    EmptyView()                              // 0.8.6 (E): the Ollama component row offers Install
                } else if !local.running {
                    Text(L("local.notRunning")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    Spacer()
                    Button(L("local.start")) { local.start() }.buttonStyle(.pnTertiary)
                } else if let p = local.pulling {
                    ProgressView(value: local.progress).frame(maxWidth: 160)
                    Text(p + " · " + local.note).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                } else if !local.hasSuggested {
                    Text(local.models.isEmpty ? L("local.noModels") : L("local.ready")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                } else {
                    Text(local.note.isEmpty ? L("local.ready") : local.note).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                }
            }
            // 0.8.5 (owner: "which of my Ollama models is used?"): every model Ollama has, and what it is for
            if local.running && !(local.models.isEmpty && local.searchModels.isEmpty) {
                ForEach(local.models, id: \.self) { m in
                    Text(L("local.model.text", ["name": m]) + (m == LocalLLM.model ? L("local.model.chosen") : ""))
                        .font(PN.Font.caption).foregroundStyle(PN.C.text2)
                }
                ForEach(local.searchModels, id: \.self) { m in
                    Text(L("local.model.search", ["name": m])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                }
            }
        }
    }
}

/// 0.8.5 (owner): the search model is picked from what Ollama has; a model that writes text is listed with why it
/// cannot search (Ollama gives no search vectors for it), so both installed models are visible here.
struct SearchModelRow: View {
    @Binding var selection: String
    @ObservedObject var local = LocalLLM.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if local.searchModels.isEmpty {
                TextField(L("set.model"), text: $selection, prompt: Text("bge-m3")).help(L("set.anEmbeddingModelPulled"))
            } else {
                Picker(L("set.model"), selection: $selection) {
                    ForEach(local.searchModels + (local.searchModels.contains(selection) || selection.isEmpty ? [] : [selection]), id: \.self) {
                        Text($0).tag($0)
                    }
                }
            }
            ForEach(local.models, id: \.self) { m in
                Text(L("search.textModel", ["name": m])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { local.refresh() }
    }
}

/// 0.9.0 (owner, 2026-11-04): the OpenAI model of a job, with its Claude counterpart and price. 0.26.2: the list is
/// the provider's own (ModelCatalogStore); the hand-written labels with prices live in ModelCatalog.labels.
/// (developers.openai.com/api/docs/pricing and platform.claude.com/docs/en/about-claude/pricing, checked 2026-11-04).
struct OpenAIModelPicker: View {
    @Binding var selection: String
    let job: String
    @ObservedObject var catalog = ModelCatalogStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(L("set.model"), selection: $selection) {
                ForEach(ModelCatalog.choices(.openai, live: catalog.entries(.openai), selected: selection), id: \.id) { m in
                    Text(ModelLabel.text(m, recommended: m.id == Self.recommended(job))).tag(m.id)
                }
            }
            ModelListNote(provider: .openai)
            Text(L("ai.openai.model2")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { catalog.refresh(.openai) }
    }
    static func recommended(_ job: String) -> String { job == "tips" ? "gpt-6-luna" : "gpt-6.1-sol" }
}

/// 0.9.3 (owner, 2026-11-04): the Gemini model of a job and its price per 1M input / output tokens (no Claude comparison)
/// (ai.google.dev/gemini-api/docs/pricing, paid tier, checked 2026-11-04). Google announced rises: Gemini 4 Argon to
/// $4 / $20 from 2026-12-01, Gemini 3.8 Flash to $1.50 / $7.50 from 2027-01-01 (livetips_m0.cost.PRICE_CHANGES).
/// 0.26.2: the list is the provider's own (ModelCatalogStore), so Gemini 4 Hydrogen and later models appear by themselves.
struct GeminiModelPicker: View {
    @Binding var selection: String
    let job: String
    @ObservedObject var catalog = ModelCatalogStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(L("set.model"), selection: $selection) {
                ForEach(ModelCatalog.choices(.gemini, live: catalog.entries(.gemini), selected: selection), id: \.id) { m in
                    Text(ModelLabel.text(m, recommended: m.id == Self.recommended(job))).tag(m.id)
                }
            }
            ModelListNote(provider: .gemini)
            Text(L("ai.gemini.model2")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { catalog.refresh(.gemini) }
    }
    static func recommended(_ job: String) -> String { job == "tips" ? "gemini-3.5-flash-lite" : "gemini-3.8-flash" }
}

struct RoutePicker: View {
    @Binding var selection: String
    /// 0.25 (R5, owner 18.11): the job decides what the picker shows: the AI that really runs it (AIDefaults.pick over
    /// what is connected), "(recommended)" on the best connected one, the AIs that are not connected greyed out.
    var job: String
    var recommended: String
    var discouraged: String? = nil
    var withOpenAI = false
    var withGemini = true          // 0.9.3
    var withAgy = false            // 0.9.3: the Gemini account, for the preparation and after the call only
    /// 0.9.3: built step by step (one long expression was too much for the type checker)
    private var routes: [String] {
        var r: [String] = [AIRoute.code, AIRoute.api, AIRoute.codex]
        if withOpenAI { r.append(AIRoute.openai) }
        if withGemini { r.append(AIRoute.gemini) }
        if withAgy { r.append(AIRoute.agy) }
        if withLocal { r.append(AIRoute.local) }
        return r
    }
    private func label(_ r: String, best: String?, on: Bool) -> String {
        guard on else { return AIRoute.name(r) + L("ai.route.notConnected") }
        let mark: String = r == (best ?? recommended) ? L("ai.route.recommended") : (r == discouraged ? L("ai.route.notRecommended") : "")
        return AIRoute.name(r) + mark
    }
    var withLocal = false          // 0.8.5: the preparation can also run on this Mac (Ollama)
    @ObservedObject var oc = OptionalComponents.shared
    @ObservedObject var llm = LocalLLM.shared
    var body: some View {
        // 0.8.6 (E > dependants): "On this Mac" needs Ollama and the model; without them it is disabled, with Install next to it
        let localOK = oc.isInstalled("ollama") && oc.isInstalled("local_model")
        let conn = AIRoute.confirmed()
        let ok: (String) -> Bool = { conn.contains($0) && AIChain.allowed($0, job: job) && ($0 != AIRoute.local || localOK) }
        let best = AIDefaults.preference(job: job).first { routes.contains($0) && ok($0) }
        let runs = RoutePicker.runs(job: job, chosen: selection, connected: conn)
        let shown = Binding<String>(get: { runs.flatMap { ok($0) ? $0 : nil } ?? "" }, set: { if !$0.isEmpty { selection = $0 } })
        VStack(alignment: .trailing, spacing: 2) {
            Picker(L("ai.route"), selection: shown) {
                if shown.wrappedValue.isEmpty { Text(L("ai.route.none")).tag("") }
                ForEach(routes, id: \.self) { r in
                    Text(label(r, best: best, on: ok(r))).tag(r)
                        .selectionDisabled(!ok(r))
                }
            }
            if withLocal && !localOK { NeedsComponent(id: oc.isInstalled("ollama") ? "local_model" : "ollama") }
        }
    }
}

extension RoutePicker {
    /// The AI that really runs the job: the chosen one while it is connected, else the best connected one; nil when
    /// no connected AI may do the job. The sections under the picker (models, warnings) follow this, not the choice.
    @MainActor static func runs(job: String, chosen: String, connected: Set<String>? = nil) -> String? {
        let conn = connected ?? AIRoute.confirmed()
        let r = AIDefaults.pick(job: job, chosen: chosen, connected: conn)
        return conn.contains(r) && AIChain.allowed(r, job: job) ? r : nil
    }
}

struct KeyRow: View {
    let title: String
    let hint: String
    let key: SecretStore.Key
    @ObservedObject var model: SettingsModel
    @State private var value = ""
    @State private var replacing = false

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 4) {
                if model.isSet(key) && !replacing {
                    HStack(spacing: 8) {
                        status
                        Text(model.masks[key] ?? "").font(PN.Font.caption.monospaced()).foregroundStyle(PN.C.text3)
                            .onAppear { model.refreshMask(key) }      // 0.8.7.1: read when shown, not at app start
                        Menu {
                            Button(L("keys.replace")) { replacing = true }
                            Button(L("keys.test")) { model.test(key) }
                            Divider()
                            Button(L("keys.remove"), role: .destructive) { model.remove(key) }
                        } label: { Image(systemName: "ellipsis.circle") }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .accessibilityLabel(L("home.more"))
                    }
                } else {
                    HStack(spacing: 6) {
                        SecureField("", text: $value, prompt: Text(L("keys.paste")))
                            .onSubmit { save() }
                        Button(L("common.save")) { save() }.buttonStyle(.pnSecondary).disabled(value.isEmpty)
                        if replacing { Button(L("common.cancel")) { replacing = false; value = "" }.buttonStyle(.pnTertiary) }
                    }
                    Text(model.isSet(key) ? "" : L("keys.notSet")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(hint).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func save() {
        guard !value.isEmpty else { return }
        model.save(key, value); value = ""; replacing = false
    }

    @ViewBuilder var status: some View {
        switch model.keyState[key] ?? .notSet {
        case .ok: Label(L("keys.connected"), systemImage: "checkmark.circle.fill").font(PN.Font.caption).foregroundStyle(PN.C.turn)
        case .failed(let m): Label(m, systemImage: "exclamationmark.triangle.fill").font(PN.Font.caption).foregroundStyle(PN.C.danger).lineLimit(2)
        case .testing: Label(L("common.checking"), systemImage: "hourglass").font(PN.Font.caption).foregroundStyle(PN.C.text3)
        default: Text(L("keys.saved")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
        }
    }
}

struct FolderRow: View {
    let title: String
    let hint: String
    @Binding var path: String
    let placeholder: String
    let choose: () -> String?
    var body: some View {
        LabeledContent {
            HStack {
                TextField("", text: $path, prompt: Text(placeholder))
                Button(L("set.browse")) { if let p = choose() { path = p } }
            }
        } label: {
            Text(title).help(hint)
        }
    }
}

// MARK: - Tabs

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var runner = PrepRunner.shared
    @AppStorage("moduleTracker") private var trackerModule = true      // 0.9.0: Settings > Modules > Tracker     // 0.9.0: the Claude / ChatGPT tab
    @State private var showProjectsInfo = false
    @State private var showWizard = false          // 0.17.0 (5.2)
    @State private var projectFilter = ""          // 0.15.0 (D2)
    @State private var showCandidates = false
    @AppStorage(SettingsSearch.advancedKey("general")) private var genAdv = "0"      // 0.25 (R5)
    @AppStorage(SettingsSearch.advancedKey("notion")) private var notionAdv = "0"
    @AppStorage(SettingsSearch.advancedKey("projects")) private var projectsAdv = "0"
    @State private var aiChecking = false     // 0.8.2: Check now on the ways that are out
    @State private var aiTick = 0
    @ObservedObject var dest = NotionDestinationModel.shared

    struct Pane: Identifiable { let id: String; let title: String; let symbol: String; let subtitle: String }
    static var panes: [Pane] { [   // titles follow the interface language
        Pane(id: "account", title: "Account", symbol: "person.crop.circle", subtitle: "Sign in to Pacenote: optional, your devices."),   // B7
        Pane(id: "general", title: "General", symbol: "gearshape", subtitle: "Your name on calls, folders, Notion and how the app behaves."),
        Pane(id: "projects", title: "Projects", symbol: "folder", subtitle: "Your workspaces and projects. Ticked ones show up in Start call."),
        Pane(id: "integrations", title: "Integrations", symbol: "point.3.connected.trianglepath.dotted", subtitle: "Notion, calendars and your CRM."),
        Pane(id: "ai", title: "AI", symbol: "cpu", subtitle: "Models, spending limits, the local AI layer and the preparation."),
        Pane(id: "recording", title: "Call recording", symbol: "record.circle", subtitle: "Record the sound or the screen of your calls."),   // 0.9.5
        Pane(id: "transcription", title: "Transcription", symbol: "character.book.closed", subtitle: "Your own words, so the transcript spells them right."),   // 0.10.0 (owner 12.11): the dictionary
        Pane(id: "sheet", title: "Meeting Sheet", symbol: "doc.text.magnifyingglass", subtitle: "Quick or Expert, My focus, reminders, your presets."),   // 0.10.0 (Meeting Sheet, phase 4)
        Pane(id: "modules", title: "Modules", symbol: "square.grid.2x2", subtitle: "Turn parts of Pacenote on or off."),       // 0.9.0
        Pane(id: "components", title: "Components", symbol: "shippingbox", subtitle: "What is installed and what you can remove."),   // 0.16.0 (D3)
        Pane(id: "usage", title: "Usage", symbol: "chart.bar", subtitle: "Calls this week and the full statistics."),       // 0.9.0: from Home
        Pane(id: "help", title: "Help", symbol: "questionmark.circle", subtitle: "What Pacenote can do and what is new."),  // 0.9.0: from Home
        Pane(id: "about", title: "About", symbol: "info.circle", subtitle: "Version, updates and where your data lives."),
    ].map { Pane(id: $0.id, title: L("settings.tab." + $0.id), symbol: $0.symbol, subtitle: L("settings.pane." + $0.id)) } }

    /// 0.14.0 (D2): the sidebar groups. A pane missing here would not show, so CoreChecks-free: keep every pane id listed.
    static let groups: [(key: String, ids: [String])] = [
        ("settings.group.you", ["account", "general"]),
        ("settings.group.calls", ["projects", "sheet", "recording", "transcription"]),
        ("settings.group.connect", ["integrations", "ai"]),
        ("settings.group.more", ["modules", "components", "usage", "help", "about"]),
    ]

    // 2026-10-26 (owner): the welcome tour's look: a sidebar of icon tiles, a header per pane, soft cards.
    var body: some View {
        Group {
        HStack(spacing: 0) {
            // 0.14.0 (D2, minimal Settings): twelve panes in four short groups instead of one long list
            VStack(alignment: .leading, spacing: 2) {
                // 0.15.0 (D2): search in Settings
                SettingsSearchField(model: model)
                if !model.search.trimmingCharacters(in: .whitespaces).isEmpty {
                    SettingsSearchResults(model: model)
                } else {
                ForEach(Self.groups, id: \.key) { g in
                    Text(L(g.key)).pnLabel().foregroundStyle(PN.C.text3)
                        .padding(.horizontal, 8).padding(.top, g.key == Self.groups[0].key ? 2 : 12).padding(.bottom, 2)
                    ForEach(Self.panes.filter { g.ids.contains($0.id) }) { p in
                        Button { model.tab = p.id; model.integration = nil; model.projectDetail = nil } label: {
                            HStack(spacing: 8) {
                                Image(systemName: p.symbol).font(PN.sys(13)).frame(width: 18)
                                    .foregroundStyle(model.tab == p.id ? PNSelect.icon : PN.C.text2)
                                // 0.23.0: the selected row on the style's selection plate (Roadbook highlight, Broadsheet ink)
                                Text(p.title)
                                    .fontWeight(model.tab == p.id && PNThemeModel.shared.style != .classic ? .bold : nil)
                                    .foregroundStyle(model.tab == p.id ? PNSelect.ink : PN.C.text)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .contentShape(Rectangle())
                            .background(RoundedRectangle(cornerRadius: PN.r(6)).fill(model.tab == p.id ? PNSelect.fill : .clear))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer()
                }
            }
            .padding(10)
            .frame(width: 200)
            .background(Color.secondary.opacity(0.05))
            Divider()
            VStack(spacing: 0) {
                let p = Self.panes.first { $0.id == model.tab } ?? Self.panes[0]
                // 0.8.6 (owner, 30.10): a clear gap and a line between the header and what scrolls under it
                // 0.14.0 (D2): a plain title and one caption line (was a 44 pt icon tile and a callout)
                if !innerPage {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.title).font(PN.sys(20, .semibold))
                    Text(p.subtitle).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28).padding(.top, 16).padding(.bottom, 10)
                Divider().padding(.horizontal, 20)
                }
                // 0.15.0 (D2): a search result scrolls its row into view; the mark fades after a moment
                ScrollViewReader { proxy in
                    pane.scrollContentBackground(.hidden).clipped().padding(.top, 4)
                        .onChange(of: model.highlight) { _, id in
                            guard let id else { return }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { if model.highlight == id { model.highlight = nil } }
                        }
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onChange(of: model.tab) { SettingsWindow.window?.title = SettingsWindow.title(for: model.tab) }
    }
        .trackScreen("settings", sub: SettingsModel.trackedPane(model.tab, model.integration))
    }

    /// A project's page or an integration's page: they carry a back link and their own title.
    var innerPage: Bool { (model.tab == "projects" && model.projectDetail != nil) || (model.tab == "integrations" && model.integration != nil) }

    @ViewBuilder var pane: some View {
        switch model.tab {
        case "projects":
            if let slug = model.projectDetail { ProjectSettingsPage(model: model, slug: slug) } else { projects }
        case "ai": ai
        case "account": AccountSettingsPane()      // B7 (server ADR 5.1)
        case "recording": RecordingSettingsPane(model: model)
        case "transcription": TranscriptionSettingsPane(model: model)      // 0.10.0 (owner 12.11): the dictionary
        case "integrations": IntegrationsPane(model: model) { notion }
        case "how": HowItWorksView()
        case "sheet": MeetingSheetSettingsPane()      // 0.10.0 (Meeting Sheet, phase 4)
        case "modules": Form {
            Section {
                Toggle(isOn: $trackerModule) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("modules.tracker"))
                        Text(L("modules.tracker.sub")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .settingsAnchor("mod.tracker")
            }
        }.formStyle(.grouped).toggleStyle(.pnSwitch)
        case "usage": ScrollView { VStack(alignment: .leading, spacing: 16) { WeekSummaryView(); WeekStats(); AIUsageView() }.padding(20) }   // 0.9.3: AI through API keys
        case "help": ScrollView { VStack(alignment: .leading, spacing: 12) {
            Button(L("settings.how.title")) { model.tab = "how" }.buttonStyle(.pnSecondary)
            FeaturesView()
            WhatsNewHistory()      // 0.16.0 (D3): every change, newest first
        }.padding(20) }
        case "components": SettingsComponentsPane()      // 0.16.0 (D3)
        case "about": AboutView(model: model)
        default: general
        }
    }


    // 0.25 (R5, owner 18.11): the three providers on top with one "Pacenote uses" line (F3); the AI of each job, the
    // fallback chain, the models, the limits, the AI on this Mac and the agents under Advanced. Who is speaking moved
    // to Transcription.
    @AppStorage(SettingsSearch.advancedKey("ai")) private var aiAdv = "0"

    var ai: some View { aiForm }

    /// 0.25 (R5): the AI that really runs a job ("" when none may), for the rows under the Runs on pickers.
    private func run(_ job: String) -> String {
        let chosen = job == "prep" ? model.config.ai.prep : job == "tips" ? model.config.ai.tips : model.config.ai.after
        return RoutePicker.runs(job: job, chosen: chosen) ?? ""
    }

    var aiForm: some View {
        Form {
            AIUsesSection(model: model)
            AIProviderCard(provider: "claude", model: model)
            AIProviderCard(provider: "chatgpt", model: model)
            AIProviderCard(provider: "gemini", model: model)
            SettingsAdvancedHeader("ai", summary: L("adv.sum.ai"))
            if aiAdv == "1" {
            Group {
            Section {
                RoutePicker(selection: $model.config.ai.prep, job: "prep", recommended: AIRoute.code, withOpenAI: true, withAgy: true, withLocal: true)
                if run("prep") == AIRoute.codex {
                    Text(L("ai.codex.model")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                } else if run("prep") == AIRoute.local {
                    LocalModelRow()
                } else if run("prep") == AIRoute.openai {
                    OpenAIModelPicker(selection: $model.config.ai.openaiPrep, job: "prep")
                } else if run("prep") == AIRoute.gemini {
                    GeminiModelPicker(selection: $model.config.ai.geminiPrep, job: "prep")
                } else if run("prep") == AIRoute.agy {
                    AgyTermsWarning()
                    AgyModelPicker(selection: $model.config.ai.agyPrep)
                } else if !run("prep").isEmpty {      // nothing connected for the job: no models to pick
                    Picker(L("set.model"), selection: $runner.model) {
                        ForEach(PrepRunner.models, id: \.id) { m in Text(m.label).tag(m.id) }
                    }
                    .help(L("set.sonnetReadsTheFiles"))
                }
            } header: { Text(L("ai.job.prep")).settingsAnchor("ai.prep") } footer: {
                if run("prep") == AIRoute.code { Text(L("set.cc.builds")).font(PN.Font.caption).foregroundStyle(PN.C.text3) }   // about Claude Code only
            }
            Section {
                RoutePicker(selection: $model.config.ai.tips, job: "tips", recommended: AIRoute.api, discouraged: AIRoute.code, withOpenAI: true)
                    .help(L("ai.tips.codeWhy"))
                if run("tips") == AIRoute.code {
                    Text(L("ai.tips.codeWhy")).font(PN.Font.caption).foregroundStyle(PN.C.onMe)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if run("tips") == AIRoute.codex {
                    Text(L("ai.codex.model")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                } else if run("tips") == AIRoute.openai {
                    OpenAIModelPicker(selection: $model.config.ai.openaiTips, job: "tips")
                } else if run("tips") == AIRoute.gemini {
                    GeminiModelPicker(selection: $model.config.ai.geminiTips, job: "tips")
                } else if !run("tips").isEmpty {      // nothing connected for the job: no models to pick
                    ModelPicker(title: L("set.classify"), selection: $model.config.models.classify, choices: model.modelChoices, provider: .claude).help(L("set.decidesIfATip"))
                    ModelPicker(title: L("set.tip"), selection: $model.config.models.tip, choices: model.modelChoices, provider: .claude).help(L("set.writesTheTipYou"))
                }
                Toggle(L("set.answerQuestionsToAnyone"), isOn: $model.config.answerAny)
                    .help(L("set.aQuestionAskedTo"))
                if [AIRoute.api, AIRoute.code].contains(run("tips")) {      // Claude runs the tips
                    Toggle(L("set.secondRequestWhenClaude"), isOn: $model.config.hedgeEnabled)
                        .help(L("set.ifClaudeShowsNo"))
                }
            } header: { Text(L("ai.job.tips")).settingsAnchor("ai.tips") } footer: {
                if run("tips") == AIRoute.api {      // the Claude key's models only
                    Text(model.config.knownModels.isEmpty ? L("set.modelsTest") : L("set.modelsKnown"))
                        .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                }
            }
            Section {
                RoutePicker(selection: $model.config.ai.after, job: "after", recommended: AIRoute.code, withOpenAI: true, withAgy: true, withLocal: true)
                if run("after") == AIRoute.codex {
                    Text(L("ai.codex.model")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                } else if run("after") == AIRoute.openai {
                    OpenAIModelPicker(selection: $model.config.ai.openaiAfter, job: "after")
                } else if run("after") == AIRoute.gemini {
                    GeminiModelPicker(selection: $model.config.ai.geminiAfter, job: "after")
                } else if run("after") == AIRoute.agy {
                    AgyTermsWarning()
                    AgyModelPicker(selection: $model.config.ai.agyAfter)
                } else if run("after") == AIRoute.local {
                    LocalModelRow()
                } else if !run("after").isEmpty {      // nothing connected for the job: no models to pick
                    ModelPicker(title: L("set.model"), selection: $model.config.models.analysis, choices: model.modelChoices, provider: .claude).help(L("set.summaryAndAnalysisNot"))
                }
                Toggle(L("set.rateTipsAfterEach"), isOn: $model.config.judgeAfterCall)
                    .help(L("set.afterTheCallClaude"))
                if !CallEngine.shared.judgeResult.isEmpty {
                    Text(CallEngine.shared.judgeResult).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                }
            } header: { Text(L("ai.job.after")).settingsAnchor("ai.after") } footer: {
                Text(L("ai.after.footer")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            // 0.10.0 (AI chain, owner 12.11): one fallback chain for every job, reorderable, each AI with its checkbox
            AIChainSection(model: model, checking: $aiChecking, tick: $aiTick)
            .id(aiTick)
            }
            Group {
            Section {
                // Pacenote 0.8 (F4, spec 8): the month's spend and the balance live here, not on Home.
                LabeledContent(L("ai.thisMonth")) {
                    let month = SpendLedger.monthSpent()
                    HStack(spacing: 10) {
                        Text(String(format: "$%.2f / $%.0f", month, model.config.budget.monthlyHardUSD)).monospacedDigit()
                        Link(L("ai.balance"), destination: URL(string: "https://console.anthropic.com/settings/billing")!).font(PN.Font.caption)
                    }
                }
                TextField(L("set.warningPerCall"), value: $model.config.budget.callSoftUSD, format: .currency(code: "USD"))
                    .help(L("set.atThisAmountIn"))
                TextField(L("set.stopPerCall"), value: $model.config.budget.callHardUSD, format: .currency(code: "USD"))
                    .help(L("set.atThisAmountClaude"))
                TextField(L("set.stopPerMonth"), value: $model.config.budget.monthlyHardUSD, format: .currency(code: "USD"))
                    .help(L("set.atThisAmountClaude2"))
            } header: { Text(L("set.spendingLimits")).settingsAnchor("ai.spend") } footer: {
                Text(L("set.monthSpend", ["spent": String(format: "%.2f", SpendLedger.monthSpent()), "cap": String(format: "%.0f", model.config.budget.monthlyHardUSD)]))
                    .font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            ProviderLimitsSection(model: model)
            EconomySection()                 // 0.9.6 Б1: between the limits and the agent
            }
            Group {
            Section {
                // 0.8.6 (E, rules/components.yaml): Ollama and the model as optional components
                ForEach(OptionalComponents.shared.all.filter { $0.id != "link_downloader" }) { c in ComponentRow(comp: c) }
                LocalStatus(local: LocalLLM.shared)
                // 0.10.0 (AI chain): the same switch as the model on this Mac's checkbox in the AI chain
                Toggle(L("local.fallback"), isOn: Binding(
                    get: { model.config.ai.chain.first { $0.route == AIRoute.local }?.on ?? true },
                    set: { on in model.config.ai.chain = AIChain.setOn(model.config.ai.chain, route: AIRoute.local, on: on); model.config.ai.localFallback = on }))
                    .help(L("local.fallback.help"))
            } header: { Text(L("local.section")).settingsAnchor("ai.local") } footer: {
                Text(L("local.footer")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Text(L("search.what")).font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
                Toggle(L("set.localAiDefaultFor"), isOn: $model.config.localAI.enabled)
                    .help(L("set.theTipsWindowMenu"))
                Picker(L("set.engine"), selection: $model.config.localAI.engine) {
                    Text(L("set.builtInRecommended")).tag("embedded")
                    Text(L("search.inOllama", ["model": model.config.localAI.ollamaModel.isEmpty ? "bge-m3" : model.config.localAI.ollamaModel])).tag("ollama")
                }
                .disabled(!model.config.localAI.enabled)
                .help(L("set.builtInNothingElse"))
                if model.config.localAI.engine == "ollama" {
                    TextField(L("set.ollamaUrl"), text: $model.config.localAI.ollamaURL).disabled(!model.config.localAI.enabled)
                    SearchModelRow(selection: $model.config.localAI.ollamaModel).disabled(!model.config.localAI.enabled)
                }
                LabeledContent(L("set.status")) {
                    HStack(spacing: 6) {
                        Image(systemName: model.localAIStatus.ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(model.localAIStatus.ok ? PN.C.turn : PN.C.onMe)
                        Text(model.localAIStatus.text).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                        Button(L("set.check")) { model.refreshLocalAI() }.controlSize(.small)
                    }
                }
                DisclosureGroup(L("set.aboutTheEngines")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(LocalizedStringKey(L("set.builtInBgeM3")))
                        Text(LocalizedStringKey(L("set.ollamaIfYouAlready")))
                        Text(LocalizedStringKey(L("set.anotherModelAnyEmbedding")))
                    }
                    .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } header: { Text(L("set.localAi")).settingsAnchor("ai.localLayer") } footer: {
                Text(L("set.audioAndVoicePrints")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            .onChange(of: model.config.localAI) { LocalAIService.shared.apply(); model.refreshLocalAI(after: 2) }
            .onAppear { model.refreshLocalAI() }
            }
            Group {
            // 0.8.7 (H3): company research for sales preparations, on by default, with what goes out
            Section {
                Toggle(isOn: $model.config.salesWebSearch) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("ai.salesWeb"))
                        Text(L("ai.salesWeb.sub")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: { Text(L("ai.salesWeb.header")).settingsAnchor("ai.salesWeb") }
            CallAgentSection(model: model)
            PrepAgentSection(model: model)   // 0.9.6 Б3: the research preparation (beta)
            }
            }
        }
        .formStyle(.grouped).toggleStyle(.pnSwitch)
    }

    // 0.15.0 (D2): a short list. A row is the tick, the name and one line; a click opens the project's own page
    // (ProjectSettingsPage). The actions that were five buttons in a row are a filter, Add and a "…" menu.
    func projectMatches(_ slug: String) -> Bool {
        let q = projectFilter.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        guard let p = model.registry.projects.first(where: { $0.slug == slug }) else { return false }
        return SettingsSearch.normalize(p.name + " " + p.slug).contains(SettingsSearch.normalize(q))
    }

    var projects: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    // 0.15.0 (D2 smoke): labelsHidden, or the grouped Form puts the field in the value column
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass").font(PN.sys(12)).foregroundStyle(PN.C.text3)
                        TextField("", text: $projectFilter, prompt: Text(L("proj.filter")))
                            .textFieldStyle(.plain).labelsHidden()
                    }
                    .padding(.horizontal, 7).frame(maxWidth: 220, minHeight: 24)
                    .background(RoundedRectangle(cornerRadius: PN.r(7)).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: PN.r(7)).stroke(Color.secondary.opacity(0.2)))
                    Spacer()
                    Menu(L("home.finish.add")) {
                        Button(L("proj.add.new")) { showWizard = true }          // 0.17.0 (5.2): the wizard
                        if !model.registry.projects.contains(where: { $0.sample }) {
                            Button(L("proj.add.sample")) { if let s = SampleProjectMaker.make(model) { model.projectDetail = s } }
                        }
                        Divider()
                        Button(L("set.projectFolder")) { model.addProjectFolder() }
                        Button(L("set.workspaceFolder")) { model.addWorkspaceFolder() }
                        Divider()
                        Button(L("set.importControlTowerConfigs")) { model.importProjects() }
                    }
                    .fixedSize().settingsAnchor("pr.import")
                    .sheet(isPresented: $showWizard) {
                        ProjectWizardView(settings: model) { slug in showWizard = false; if let s = slug { model.projectDetail = s } }
                    }
                    Button { showProjectsInfo.toggle() } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.borderless).accessibilityLabel(L("set.aboutProjects"))
                        .popover(isPresented: $showProjectsInfo, arrowEdge: .bottom) { projectsInfo }
                }
                if model.config.workRoot.isEmpty {
                    Text(L("set.setTheWorkFolder")).font(PN.Font.caption).foregroundStyle(PN.C.onMe)
                }
                if !model.note.isEmpty { Text(model.note).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
            }
            // 0.25 (R5): one list of every project on top; the workspaces they come from are under Advanced
            let all = model.registry.projects.filter { projectMatches($0.slug) }
            if !all.isEmpty {
                Section {
                    ForEach(all, id: \.slug) { p in projectRow(p.slug) }
                } header: { Text(L("settings.tab.projects")) }
            }
            if !projectFilter.isEmpty && !model.registry.projects.contains(where: { projectMatches($0.slug) }) {
                Section { Text(L("proj.noMatch")).font(PN.sys(.callout, 12)).foregroundStyle(PN.C.text3) }
            }
            if model.registry.projects.isEmpty && model.registry.workspaces.isEmpty && model.folderCandidates.isEmpty {
                Section {
                    Text(L("set.noProjectsYetScan2"))
                        .font(PN.sys(.callout, 12)).foregroundStyle(PN.C.text3)
                }
            }
            SettingsAdvancedHeader("projects", summary: L("adv.sum.projects"))
            if projectsAdv == "1" {
            Section {
                let cands = model.folderCandidates
                if !cands.isEmpty {
                    HStack(spacing: 8) {
                        Circle().fill(PN.C.accent).frame(width: 7, height: 7)
                        Text(L("proj.found", ["n": "\(cands.count)", "names": cands.map { ($0.dir as NSString).lastPathComponent }.joined(separator: ", ")]))
                            .lineLimit(1).truncationMode(.tail)
                        Spacer()
                        Button(showCandidates ? L("proj.hide") : L("proj.review")) { showCandidates.toggle() }.buttonStyle(.pnTertiary)
                    }
                    if showCandidates {
                        ForEach(cands, id: \.dir) { c in
                            HStack {
                                Image(systemName: "folder.badge.questionmark").foregroundStyle(PN.C.text3)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text((c.dir as NSString).lastPathComponent)
                                    Text(L("set.foldersInside", ["n": "\(c.projects)"])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                                }
                                Spacer()
                                Button(L("set.addAsWorkspace")) { model.addWorkspace(c.dir) }
                                Button(L("set.ignore")) { model.ignoreFolder(c.dir) }
                            }
                        }
                    }
                }
                HStack {
                    Button(L("set.scanWorkFolder")) { model.scanFolders() }
                        .disabled(model.config.workRoot.isEmpty)
                        .help(L("set.addsTheProjectFolders"))
                    Button(L("set.reindexAll")) { IndexService.shared.reindexAll() }
                        .help(L("set.rebuildTheSearchIndex"))
                    Spacer()
                }
                .settingsAnchor("pr.scan")
            } header: { Text(L("proj.adv.folders")) } footer: {
                Text(L("set.aWorkspaceSSubfolders")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.registry.workspaces, id: \.name) { w in
                let members = model.registry.projects.filter { w.projects.contains($0.slug) && projectMatches($0.slug) }
                if projectFilter.isEmpty || !members.isEmpty {
                Section {
                    // 0.8.8: the workspace's value in the Notion Workspace properties (as for a project, never an id)
                    if model.notionConnected, let wi = model.registry.workspaces.firstIndex(where: { $0.name == w.name }) {
                        LabeledContent(L("proj.inNotion")) {
                            NotionValuePicker(value: $model.registry.workspaces[wi].notionValue, fallback: w.name, model: model, workspace: true)
                        }
                        .help(L("ws.inNotion.help"))
                    }
                    Text(members.isEmpty ? L("set.noProjectsYetScan") : L("proj.ws.members", ["n": "\(members.count)", "names": members.prefix(4).map(\.name).joined(separator: ", ")]))
                        .font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(2)
                } header: {
                    HStack(spacing: 6) {
                        Text(w.name)
                        if model.workspaceHasNotion(w) { Text("Notion").font(PN.Font.caption).padding(.horizontal, 5).background(Capsule().fill(Color.secondary.opacity(0.15))) }
                        Spacer()
                        Menu {
                            // 0.8.7 (F7): where this workspace's calls go
                            Text(L("set.calls") + (w.root as NSString).lastPathComponent)
                            Divider()
                            Button(L("home.recent.finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: w.root)]) }
                            Button(L("set.removeWorkspaceFromPacenote"), role: .destructive) { model.removeWorkspace(w) }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help(L("set.calls.help", ["name": (w.root as NSString).lastPathComponent]))
                    }
                }
                }
            }
            }
        }
        .formStyle(.grouped).toggleStyle(.pnSwitch)
    }

    /// 2026-10-27 (owner): plain words instead of the long text on top of the tab.
    var projectsInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("set.howProjectsWork")).font(PN.sys(.headline, 13, .semibold))
            Text(L("set.eachProjectIsA"))
            Text(L("set.tickAProjectTo"))
            Text(L("set.removesAProjectOr"))
            Text(L("set.optionalExtrasComeFrom"))
        }
        .font(PN.sys(.callout, 12)).fixedSize(horizontal: false, vertical: true)
        .padding(16).frame(width: 380)
    }

    @ViewBuilder func projectRow(_ slug: String) -> some View {
        if let i = model.registry.projects.firstIndex(where: { $0.slug == slug }) {
            let p = model.registry.projects[i]
            HStack(alignment: .center, spacing: 10) {
                Toggle("", isOn: Binding(get: { model.registry.projects[i].status != "archived" },
                                         set: { model.registry.projects[i].status = $0 ? "active" : "archived" }))
                    .toggleStyle(.pnCheckbox).labelsHidden()
                    .help(L("set.activeOfferedInStart"))
                Button { model.projectDetail = p.slug } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(p.name).foregroundStyle(p.status == "archived" ? .secondary : .primary)
                                if !p.config.isEmpty {
                                    Text(L("set.config")).font(PN.Font.caption).padding(.horizontal, 5).background(Capsule().fill(Color.secondary.opacity(0.15)))
                                        .help(L("set.peopleNotionPagesAnd") + p.config)
                                }
                            }
                            let meta = ProjectMeta.line(p, model: model)
                            if !meta.isEmpty {
                                Text(meta).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(1).truncationMode(.tail)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(PN.sys(11, .semibold)).foregroundStyle(PN.C.text3)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(p.root.isEmpty ? L("set.noFolder") : p.root)
            }
            .contextMenu {
                Button(L("home.recent.finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p.root)]) }.disabled(p.root.isEmpty)
                Button(L("set.reindexNow")) { IndexService.shared.reindex(p.root) }.disabled(!p.index.enabled)
                Button(L("set.removeFromPacenote"), role: .destructive) { model.excludeProject(p.slug) }
            }
        }
    }

    // 2026-10-27 (owner): everything about Notion in one place (it was hidden under General > Behaviour).
    /// 0.8.6 (C): everything about Notion on one tab: Connection, Meeting pages, My tasks in On you, Local copy.
    // 0.25 (R5, owner 18.11): Notion shows the token and, as soon as it is connected, where meeting notes go (the
    // first user's bug: Notion connected without a database, so a call could not finish its page); the other
    // databases, My tasks and the local copy are under Advanced. (0.15.0 had four groups, one at a time.)
    var notion: some View {
        let connected = model.notionConnected
        return Form {
            if !model.config.notionMigrationNote.isEmpty {
                Section {
                    HStack(alignment: .top) {
                        Image(systemName: "info.circle").foregroundStyle(Color.accentColor)
                        Text(model.config.notionMigrationNote == "all" ? L("ntset.migrated.all", ["name": model.config.notionMeetingsName.isEmpty ? "-" : model.config.notionMeetingsName])
                             : L("ntset.migrated", ["name": model.config.notionMeetingsName.isEmpty ? "-" : model.config.notionMeetingsName, "projects": model.config.notionMigrationNote]))
                            .font(PN.Font.caption).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button(L("common.ok")) { model.config.notionMigrationNote = "" }.buttonStyle(.pnTertiary)
                    }
                }
            }
            Section {
                // INT S2: Connect with Notion through the Pacenote server; the pasted key stays as the advanced way
                NotionConnectSection(model: model)
                if model.notionConnected { NotionSeesLine() }
            } header: { Text(L("set.connection")) }
            if connected {
            Section {
                NotionDestinationView(compact: true)
                Toggle(L("set.writeAMeetingPage"), isOn: $model.config.notionWriteSummary)
                    .settingsAnchor("int.notion.pages")
            } header: { Text(L("nset.whereMeetingPagesGo")).settingsAnchor("int.notion.meetDB") } footer: {
                Text(L(model.config.notionMeetingsDB.isEmpty ? "ntn.meet.need" : "set.afterTheCallA"))
                    .font(PN.Font.caption).foregroundStyle(model.config.notionMeetingsDB.isEmpty ? PN.C.onMe : PN.C.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsAdvancedHeader("notion", summary: L("adv.sum.notion"))
            if notionAdv == "1" {
            if NotionAuth.viaOAuth && model.isSet(.notionToken) {
                Section {
                    KeyRow(title: L("keys.notion.title"), hint: L("ntauth.manual.unused"), key: .notionToken, model: model)
                }
            }
            Section {
                NotionDBRow(kind: "meetings", model: model)
                NotionDBRow(kind: "tasks", model: model)
                NotionDBRow(kind: "risks", model: model)
                NotionDBRow(kind: "decisions", model: model)      // 0.8.8 (rules/decisions.yaml)
                NotionFillChoices(model: model)
                HStack {
                    if dest.busy { PNSpinner(size: 16) }
                    Text(dest.note).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(2)
                    Spacer()
                    Button(L("ntset.fillFromConfigs")) { fillFromConfigs() }.buttonStyle(.pnTertiary)
                        .help(L("ntset.fillFromConfigs.help"))
                    Button(dest.searched ? L("nset.findAgain") : L("nset.find")) { dest.find() }.buttonStyle(.pnSecondary).disabled(dest.busy)
                }
            } header: { Text(L("ntset.databases")).settingsAnchor("int.notion.dbs") } footer: {
                Text(L("ntset.databases.footer")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            }
            NotionTasksSection(model: model)
            Section {
                LabeledContent {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            mirrorLine
                            Spacer()
                            switch NotionMirrorService.mode(workRoot: model.config.workRoot) {
                            case "managed": Button(L("set.syncNow")) { NotionMirrorService.shared.syncNow(); model.mirrorNote = "Syncing in the background…" }
                            case "none": Button(L("set.setUpSync")) { model.setUpMirror() }.disabled(model.config.workRoot.isEmpty)
                            default: EmptyView()
                            }
                            Button(L("set.check")) { model.refreshMirror() }
                        }
                        if !model.mirrorNote.isEmpty {
                            Text(model.mirrorNote).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                        } else if NotionMirrorService.mode(workRoot: model.config.workRoot) == "external" {
                            Text(L("set.runByYourOwn")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                        } else if NotionMirrorService.mode(workRoot: model.config.workRoot) == "managed" {
                            Text(L("set.pacenoteRunsItEvery")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                        }
                        // INT5: without Control Tower the copy holds Pacenote's databases and the shared pages
                        if NotionMirrorService.layout(workRoot: model.config.workRoot) == "pacenote" {
                            Text(L("nlc.mode.pacenote")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } label: {
                    Text(L("set.notionMirror")).help(L("set.aReadOnlyCopy"))
                }
            } header: { Text(L("set.localCopyOfNotion")).settingsAnchor("int.notion.local") } footer: {
                Text(L("set.aReadOnlyCopy2"))
                    .font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            }
            }
        }
        .formStyle(.grouped).toggleStyle(.pnSwitch)
        .onAppear { if connected && model.config.notionMeetingsDB.isEmpty && !dest.searched && !dest.busy { dest.find() } }
        .onChange(of: model.notionConnected) { _, on in
            // the database is picked right when Notion gets connected
            // (R5, item 3) "Write a meeting page" turns on when the database is picked (NotionDestination.choose), not on the token
            if on && model.config.notionMeetingsDB.isEmpty && !dest.busy { dest.find() }
        }
    }

    /// 0.8.7 (F3): fills empty database choices from the project configs (meetings_db, tasks_db, risks_db). One
    /// database named by all configs is set at once; different ones are listed for the PM to pick (NotionFillChoices).
    func fillFromConfigs() {
        let ps = model.registry.projects.filter { $0.status != "archived" && !$0.config.isEmpty }
        func named(_ key: String) -> [NotionSchema.Choice] {
            var by: [String: [String]] = [:], order: [String] = []
            for p in ps {
                let id = NotionTargets.configId(key, p)
                guard !id.isEmpty else { continue }
                let k = NotionSchema.norm(id)
                if by[k] == nil { order.append(k) }
                by[k, default: []].append(p.name)
            }
            return order.map { NotionSchema.Choice(id: $0, projects: by[$0] ?? []) }.sorted { $0.projects.count > $1.projects.count }
        }
        var filled = 0, differ = 0
        let schema = NotionSchema.shared
        for (kind, key) in [("meetings", "meetings_db"), ("tasks", "tasks_db"), ("risks", "risks_db")] {
            let current = kind == "meetings" ? model.config.notionMeetingsDB : kind == "risks" ? model.config.notionRisksDB : model.config.notionTasks.database
            guard current.isEmpty else { continue }
            let cs = named(key)
            if cs.count == 1 {
                switch kind {
                case "meetings": model.config.notionMeetingsDB = cs[0].id
                case "risks": model.config.notionRisksDB = cs[0].id
                default: model.config.notionTasks.database = cs[0].id
                }
                schema.load(cs[0].id)
                filled += 1
            } else if cs.count > 1 {
                schema.fillChoices[kind] = cs
                differ += 1
            }
        }
        dest.note = differ > 0 ? L("ntset.fill.choose") : (filled == 0 ? L("ntset.fill.none") : L("ntset.fill.done", ["n": "\(filled)"]))
        if (filled > 0 || differ > 0) && dest.items.isEmpty { dest.find() }
    }

    // 0.25 (R5, owner 18.11): General shows the "Pacenote is ready" card, the name on calls, the language and the
    // look on top; the Dock, the tips window during screen sharing, the call controls, the shortcuts, the folders and
    // the data under Advanced. (0.15.0 had three groups, one at a time.)
    var general: some View { generalForm }

    var generalForm: some View {
        Form {
            PacenoteReadyCard(model: model)
            Section {
                LabeledContent(L("set.yourNameOnCalls")) {
                    TextField("", text: $model.aliasesText, prompt: Text(L("onboarding.name.placeholder")))
                        .onSubmit { model.saveAliases() }
                        .onChange(of: model.aliasesText) { model.saveAliases() }
                }
                .help(L("set.everyFormPeopleUse"))
                .settingsAnchor("gen.name")
                Picker(L("callSettings.uiLang"), selection: $model.config.uiLanguage) {
                    Text("English").tag("en")
                    Text("Українська").tag("uk")
                }
                .settingsAnchor("gen.lang")
                // Redesign block 1: the style (Classic, Roadbook, Broadsheet) and the mode, both applied at once
                AppearanceBlock(style: $model.config.appearanceStyle, mode: $model.config.appearance)
                    .onChange(of: model.config.appearance) { AppDelegate.applyAppearance(model.config.appearance) }
                    .onChange(of: model.config.appearanceStyle) { AppDelegate.applyStyle(model.config.appearanceStyle) }
                    .settingsAnchor("gen.theme")
            } footer: {
                HStack {
                    Text(L("set.settingsSaveAutomaticallyAnd"))
                    Button(L("home.recent.finder")) { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.config]) }.buttonStyle(.pnTertiary)
                }
                .font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            SettingsAdvancedHeader("general", summary: L("adv.sum.general"))
            if genAdv == "1" {
            Group {
            Section {
                Toggle(L("settings.general.dock"), isOn: $model.config.showInDock)
                    .onChange(of: model.config.showInDock) { NSApp.setActivationPolicy(model.config.showInDock ? .regular : .accessory) }
                    .settingsAnchor("gen.dock")
                Toggle(L("set.hideTheTipsWindow"), isOn: $model.config.stealthDefault)
                    .help(L("set.defaultForNewCalls"))
                    .settingsAnchor("gen.stealth")
                Picker(selection: $model.config.tipsWindowMode) {
                    Text(L("set.tipsMode.window")).tag("window")
                    Text(L("set.tipsMode.card")).tag("card")
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("set.tipsMode"))
                        Text(L("set.tipsMode.help")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .settingsAnchor("gen.tipsMode")
                Toggle(isOn: $model.config.floatingCallControls) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("floating.setting"))
                        Text(L("floating.menuHelp")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .help(L("floating.settingHelp"))
                .onChange(of: model.config.floatingCallControls) { (NSApp.delegate as? AppDelegate)?.refresh() }
                .settingsAnchor("gen.floating")
            } header: { Text(L("gen.group.calls")) }
            Section {
                ShortcutRow(action: .help)
                ShortcutRow(action: .pause)
                ShortcutRow(action: .mute)
                ShortcutRow(action: .proactive)
                ShortcutRow(action: .presentation)
                ShortcutRow(action: .prevSlide)
                ShortcutRow(action: .nextSlide)
                ShortcutRow(action: .add30)
                // 0.8.6 (A3): a key of the call window itself (works while that window is in front), so it is not editable.
                LabeledContent(L("set.onTopShortcut")) { Text("⌥⌘T").font(.callout.monospaced()).foregroundStyle(PN.C.text3) }
            } header: { Text(L("set.shortcuts")).settingsAnchor("gen.shortcuts") } footer: {
                Text(L("set.theyWorkFromAny"))
                    .font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            Section {
                FolderRow(title: L("set.workFolder"),
                          hint: L("set.workFolderHint"),
                          path: $model.config.workRoot, placeholder: "~/work", choose: { model.chooseFolder(L("set.chooseWork")) })
                    .onChange(of: model.config.workRoot) { model.refreshMirror(); model.rescanWorkspaces() }
                    .settingsAnchor("gen.folder")
                LabeledContent {
                    HStack {
                        Text(model.config.effectiveAppRoot(appSupport: AppPaths.support.path))
                            .font(PN.sys(.callout, 12)).foregroundStyle(PN.C.text3).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(L("onboarding.folder.choose")) { if let p = model.chooseFolder(L("set.chooseApp")) { model.config.appRoot = p } }
                        if !model.config.appRoot.isEmpty { Button(L("set.default")) { model.config.appRoot = "" } }
                    }
                } label: {
                    Text(L("set.appFolder")).help(L("set.whereTheAppKeeps"))
                }
                .settingsAnchor("gen.appfolder")
            } header: { Text(L("gen.folders")) } footer: {
                HStack {
                    Text(L("set.yourCorrectionsCardsOn"))
                    Button(L("set.showLog")) {
                        if !FileManager.default.fileExists(atPath: EditLog.url.path) { FileManager.default.createFile(atPath: EditLog.url.path, contents: nil) }
                        NSWorkspace.shared.activateFileViewerSelecting([EditLog.url])
                    }.buttonStyle(.pnTertiary)
                }
                .font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            }
            Group {
            // 0.8.7 (M, rules/usage.yaml): the local usage log
            Section {
                Toggle(isOn: $model.config.usageLog) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("usage.toggle"))
                        Text(L("usage.toggle.sub")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .onChange(of: model.config.usageLog) {
                    UsageLog.enabled = model.config.usageLog
                    if !model.config.usageLog { model.config.shareUsage = false }
                }
                .settingsAnchor("gen.usage")
                // 0.9.4 (owner, rules/usage.yaml > telemetry): the same log, sent to the author once a week
                Toggle(isOn: $model.config.shareUsage) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("telemetry.toggle"))
                        Text(L("telemetry.toggle.sub")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(!model.config.usageLog)
                .onChange(of: model.config.shareUsage) {
                    if model.config.shareUsage { model.config.usageLog = true }
                    TelemetrySender.setOn(model.config.shareUsage)
                    if model.config.shareUsage { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { TelemetrySender.tick() } }
                }
                .settingsAnchor("gen.telemetry")
                // 0.19.0 (D45): organizations that share usage for work there whatever this switch says, always named
                ForEach(AnalyticsOrgLine.orgs, id: \.self) { name in
                    Label(L("telemetry.orgOn", ["org": name]), systemImage: "building.2")
                        .font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button(L("telemetry.preview")) { TelemetrySender.preview() }.buttonStyle(.pnTertiary)
                        .help(L("telemetry.previewHelp"))
                    Button(L("set.showLog")) {
                        let d = FeatureRegistry.usageDir
                        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([d])
                    }.buttonStyle(.pnTertiary)
                }
            } header: { Text(L("usage.privacy")) }
            Section {
                ForEach(OptionalComponents.shared.all.filter { $0.id == "link_downloader" }) { c in ComponentRow(comp: c) }
            } header: { Text(L("comp.addons")).settingsAnchor("gen.addons") } footer: {
                Text(L("comp.addonsFoot")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            }
            }
        }
        .formStyle(.grouped).toggleStyle(.pnSwitch)
    }

    @ViewBuilder var mirrorLine: some View {
        switch model.mirrorHealth {
        case "ok": Label(model.mirrorLastRunText, systemImage: "checkmark.circle.fill").foregroundStyle(PN.C.turn)
        case "stale": Label(L("set.stale") + model.mirrorLastRunText, systemImage: "exclamationmark.triangle.fill").foregroundStyle(PN.C.onMe)
        case "failed": Label(L("set.lastRunFailed"), systemImage: "xmark.octagon.fill").foregroundStyle(PN.C.danger)
        default: Label(model.config.workRoot.isEmpty ? L("set.workFirst") : L("set.noMirror"), systemImage: "circle.dashed").foregroundStyle(PN.C.text3)
        }
    }
}

/// 2026-10-26 (owner): what runs on the Mac, what goes to Claude and when, and what to expect.
struct HowItWorksView: View {
    var body: some View {
        Form {
            // 0.8.7 (L4): this page is the architecture; what the app can do has its own page
            Section {
                HStack(spacing: 4) {
                    Text(L("how.lookingFor"))
                    Button(L("feat.title")) { FeaturesWindow.show() }.buttonStyle(.link)
                }
                .font(PN.Font.body)
            }
            Section {
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        box(L("how.0"), L("how.1"), .gray)
                        arrow
                        box("Whisper", L("how.2"), .gray)
                        arrow
                        box(L("how.3"), L("how.4"), .gray)
                    }
                    Image(systemName: "arrow.down").foregroundStyle(PN.C.text3)
                    HStack(alignment: .top, spacing: 10) {
                        box(L("how.5"), L("how.6"), PN.C.turn)
                        box(L("how.7"), L("how.8"), .blue)
                    }
                    Image(systemName: "arrow.down").foregroundStyle(PN.C.text3)
                    box(L("how.9"), L("how.10"), PN.C.onMe)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            } header: { Text(L("set.theFlow")) }

            Section {
                row("waveform", L("how.11"), L("how.12"))
                row("text.bubble", L("how.13"), L("how.14"))
                row("person.2.wave.2", L("how.15"), L("how.16"))
                row("cpu", L("how.17"), L("how.18"))
            } header: { Text(L("set.onYourMac")) }

            Section {
                row("doc.text.magnifyingglass", L("how.19"), L("how.20"))
                row("bolt", L("how.21"), L("how.22"))
                row("list.bullet.rectangle", L("how.23"), L("how.24"))
                row("folder", L("how.25"), L("how.26"))
                row("checkmark.seal", L("how.27"), L("how.28"))
                row("dollarsign.circle", L("how.29"), L("how.30"))
            } header: { Text(L("set.claudeCloud")) }

            Section {
                row("checkmark.circle", L("how.31"), L("how.32"))
                row("exclamationmark.triangle", L("how.33"), L("how.34"))
            } header: { Text(L("set.whatToExpect")) }
        }
        .formStyle(.grouped).toggleStyle(.pnSwitch)
    }

    var arrow: some View { Image(systemName: "arrow.right").foregroundStyle(PN.C.text3) }

    func box(_ title: String, _ sub: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(title).font(PN.sys(.callout, 12)).bold()
            Text(sub).font(PN.Font.caption).foregroundStyle(PN.C.text3).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: PN.r(8)).fill(color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: PN.r(8)).stroke(color.opacity(0.4)))
    }

    func row(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).frame(width: 20).foregroundStyle(PN.C.text3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(text).font(PN.sys(.callout, 12)).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct AboutView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var setup = SetupWindow.model
    @State private var checking = false
    @State private var updateNote = ""
    @State private var updateURL: URL?

    /// Pacenote 0.8 (owner, Q6): the latest release from the GitHub API, compared with this build.
    func checkUpdates() async {
        checking = true; updateURL = nil; updateNote = L("common.checking")
        defer { checking = false }
        var r = URLRequest(url: URL(string: "https://api.github.com/repos/bodco/live-tips/releases/latest")!)
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.timeoutInterval = 10
        guard let res = try? await URLSession.shared.data(for: r), (res.1 as? HTTPURLResponse)?.statusCode == 200,
              let o = (try? JSONSerialization.jsonObject(with: res.0)) as? [String: Any],
              let tag = o["tag_name"] as? String, let latest = AppVersion.number(in: tag) else {
            updateNote = L("settings.about.checkFailed"); return
        }
        let mine = info["CFBundleShortVersionString"] as? String ?? "0"
        if AppVersion.isNewer(latest, than: mine) {
            updateNote = L("settings.about.newVersion", ["version": latest])
            updateURL = URL(string: o["html_url"] as? String ?? "") ?? URL(string: "https://github.com/bodco/live-tips/releases/latest")
        } else {
            updateNote = L("settings.about.upToDate", ["version": mine])
        }
    }

    var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }
    var versionLine: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return L("settings.about.version", ["version": info["CFBundleShortVersionString"] as? String ?? "dev",
                                            "build": info["CFBundleVersion"] as? String ?? "dev",
                                            "os": "\(os.majorVersion).\(os.minorVersion)" + (os.patchVersion > 0 ? ".\(os.patchVersion)" : "")])
    }

    // Pacenote 0.8 (F0): the brand block, the version with build and macOS, updates, the former name.
    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 18) {
                    Image(nsImage: Brand.appIcon).resizable().interpolation(.high).frame(width: 88, height: 88).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 8) {
                        PacenoteWordmark(height: 26)
                        Text(L("settings.about.byline")).font(PN.sys(15)).foregroundStyle(PN.C.text2)
                        Text(versionLine).font(PN.Font.caption).foregroundStyle(PN.C.text3).textSelection(.enabled)
                    }
                    Spacer()
                    // Asks GitHub for the latest release only when pressed; nothing is checked in the background.
                    // 0.16.0 (D3): only in builds without Sparkle (no key); otherwise About > Updates below.
                    if !UpdateService.shared.isOn {
                        Button(L("settings.about.checkUpdates")) { Task { await checkUpdates() } }
                            .buttonStyle(.pnSecondary).disabled(checking)
                    }
                }
                if !updateNote.isEmpty {
                    HStack {
                        Text(updateNote).font(PN.sys(.callout, 12)).foregroundStyle(updateURL != nil ? PN.C.accent : PN.C.text3)
                        if let u = updateURL { Button(L("settings.about.download")) { NSWorkspace.shared.open(u) }.buttonStyle(.pnTertiary) }
                    }
                }
                Text(L("app.description")).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    Link(L("settings.about.website"), destination: URL(string: "https://tower.bodco.pm/pacenote/")!)
                    Link("GitHub", destination: URL(string: "https://github.com/bodco/live-tips")!)
                    Link("PM Control Tower", destination: URL(string: "https://tower.bodco.pm")!)
                }
            }
            if UpdateService.shared.isOn { UpdatesSection() }     // 0.16.0 (D3): Sparkle 2
            // 2026-10-27 (owner): privacy policy and terms of use, published on the website.
            Section {
                Text(L("settings.about.dataBody"))
                    .font(PN.sys(.callout, 12)).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    Link(L("settings.about.privacy"), destination: URL(string: "https://tower.bodco.pm/pacenote/privacy/")!)
                    Link(L("settings.about.terms"), destination: URL(string: "https://tower.bodco.pm/pacenote/terms/")!)
                    Link(L("settings.about.license"), destination: URL(string: "https://github.com/bodco/live-tips/blob/main/LICENSE")!)
                }
            } header: { Text(L("settings.about.yourData")) }
            // 0.16.0 (D3): the parts, their sizes and Remove moved to Settings > Components; here the signature and a link
            Section {
                // 2026-10-29 (owner): the app's own signature, so "Open Anyway" reads as expected, not as a fault.
                if !AppSignature.shared.line.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: AppSignature.shared.kind == .notarized ? "checkmark.seal.fill" : "checkmark.shield")
                            .foregroundStyle(AppSignature.shared.kind == .notarized ? PN.C.turn : PN.C.onMe).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L("sign.title"))
                            Text(AppSignature.shared.line).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                HStack {
                    Text(L("cmp.aboutNote")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(L("cmp.manage")) { model.tab = "components" }.buttonStyle(.pnSecondary)
                }
            } header: { Text(L("about.components")) } footer: {
                Text(L("settings.about.readyFooter", ["help": HotKeys.shared.combo(.help).display, "pause": HotKeys.shared.combo(.pause).display]))
                    .font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
        }
        .formStyle(.grouped).toggleStyle(.pnSwitch)
        .onAppear { AppSignature.shared.check(); if setup.steps.allSatisfy({ $0.state == .unknown }) { Task { await setup.checkAll() } } }
    }

    func isOK(_ k: SecretStore.Key) -> Bool {
        if case .ok = model.keyState[k] ?? .notSet { return true }
        return false
    }

    func check(_ ok: Bool, _ title: String, _ whereTo: String) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle").foregroundStyle(ok ? PN.C.turn : PN.C.text3)
            Text(title)
            Spacer()
            if !ok { Text(whereTo).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
        }
    }
}

@MainActor
final class SettingsWindow {
    static var window: NSWindow?
    static let model = SettingsModel()

    static func title(for tab: String) -> String {
        switch tab {
        case "how": return L("settings.how.title")
        case "about": return L("settings.about.windowTitle")
        case "account", "general", "projects", "ai", "recording", "transcription", "integrations", "usage", "help", "modules", "sheet", "components": return L("settings.tab." + tab)
        default: return L("settings.windowTitle")
        }
    }

    static func show(tab: String = "general") {
        model.integration = nil
        model.projectDetail = nil
        model.tab = tab                                   // 0.8.7 (F1): notion, keys, calendars open under Integrations
        window?.title = title(for: model.tab)
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: Localized { SettingsView(model: model).noticeBanner() }))
            w.tabbingMode = .disallowed      // 0.8.7 (A1): never tabs
            w.title = title(for: model.tab)
            w.setContentSize(NSSize(width: 960, height: 660))
            w.isReleasedWhenClosed = false
            window = w
            AskCenter.watch(w)
        }
        window?.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { window?.makeFirstResponder(nil) }   // 0.8.7 (F6): no field is focused on open
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// "How Pacenote works" moved from Settings to the Help menu (Pacenote 0.8, F4, spec 8).
@MainActor
enum HowItWorksWindow {
    static var window: NSWindow?
    static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: Localized { HowItWorksView().frame(width: 680, height: 620) }))
            w.tabbingMode = .disallowed      // 0.8.7 (A1): never tabs
            w.isReleasedWhenClosed = false
            window = w
        }
        window?.title = L("settings.how.title")
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}


/// 0.8.6 (C): "sees N databases and M pages": what the token can reach, as a test of the connection.
struct NotionSeesLine: View {
    @ObservedObject var m = NotionDestinationModel.shared
    var body: some View {
        HStack {
            if m.searched {
                Text(L("set.notionSees", ["db": "\(m.items.filter { $0.kind == "data_source" }.count)", "pages": "\(m.items.filter { $0.kind == "page" }.count)"]))
                    .font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            Spacer()
            if m.busy { PNSpinner(size: 16) }
            Button(L("set.check")) { m.find() }.disabled(m.busy)
        }
        .onAppear { if !m.searched && !m.busy { m.find() } }
    }
}


// MARK: - 0.9.4 (owner, rules/voices.yaml > people): one person, many spellings

struct PersonName: Identifiable { let name: String; var id: String { name } }

/// Merge: which name stays. Either of the two, or a fuller one typed here; the others become its aliases.
struct MergeNameSheet: View {
    @ObservedObject var model: SettingsModel
    let ask: SettingsModel.MergeAsk
    @State private var keep = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("people.mergeTitle", ["a": ask.a, "b": ask.b])).font(SwiftUI.Font.system(size: 15, weight: .semibold))
            Text(L("people.mergeSub")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            HStack {
                ForEach([ask.a, ask.b], id: \.self) { n in
                    Button(n) { keep = n }.buttonStyle(.pnTertiary)
                }
            }
            TextField(L("people.primary"), text: $keep).textFieldStyle(.roundedBorder)
            let others = Set([ask.a, ask.b, keep]).subtracting([keep]).sorted()
            if !keep.isEmpty, !others.isEmpty {
                Text(L("people.willMean", ["list": others.joined(separator: ", "), "name": keep])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            HStack {
                Spacer()
                Button(L("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("people.merge")) { model.mergeVoice(ask.a, into: ask.b, keep: keep.trimmingCharacters(in: .whitespaces)); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(keep.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 420)
        .onAppear { keep = ask.a.count >= ask.b.count ? ask.a : ask.b }      // the fuller spelling first
    }
}

/// A person's primary name and the other spellings that mean them (typed on a call, in the calendar, in Meet).
struct PersonNamesSheet: View {
    @ObservedObject var model: SettingsModel
    let name: String
    @State private var primary = ""
    @State private var newAlias = ""
    @State private var note = ""
    @State private var aliases: [String] = []
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("people.title")).font(SwiftUI.Font.system(size: 15, weight: .semibold))
            TextField(L("people.primary"), text: $primary).textFieldStyle(.roundedBorder)
            Text(L("people.primarySub")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            Text(L("people.aliases")).font(PN.Font.caption.weight(.semibold))
            if aliases.isEmpty { Text(L("people.noAliases")).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
            ForEach(aliases, id: \.self) { a in
                HStack {
                    Text(a)
                    Spacer()
                    Button(L("people.remove")) { model.removeVoiceAlias(a); reload() }.controlSize(.small)
                }
            }
            HStack {
                TextField(L("people.addPlaceholder"), text: $newAlias).textFieldStyle(.roundedBorder).onSubmit(add)
                Button(L("people.add"), action: add).disabled(newAlias.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !note.isEmpty { Text(note).font(PN.Font.caption).foregroundStyle(PN.C.onMe).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button(L("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("common.save")) {
                    let p = primary.trimmingCharacters(in: .whitespaces)
                    if !p.isEmpty, p != name { model.renameVoice(name, to: p) }
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 420)
        .onAppear { primary = name; reload() }
    }
    private func reload() { aliases = model.voiceAliasesOf(name) }
    private func add() {
        let a = newAlias.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty else { return }
        switch model.addVoiceAlias(a, to: name) {
        case .added: newAlias = ""; note = ""
        case .isPerson: note = L("people.isPerson", ["name": a])
        case .otherPerson(let o): note = L("people.otherPerson", ["alias": a, "name": o])
        }
        reload()
    }
}

/// 0.10.0 (AI chain, owner 12.11): Settings > AI > If an AI is out. One fallback chain for every job: the AI chosen for
/// the job first, then the connected AIs in this order (arrows to reorder, a checkbox each). Tips never use the model
/// on this Mac or the Gemini account; the model on this Mac is always the last step. The status of every AI below.
struct AIChainSection: View {
    @ObservedObject var model: SettingsModel
    @Binding var checking: Bool
    @Binding var tick: Int

    var body: some View {
        let chain = AIChain.normalized(model.config.ai.chain)
        let connected = MainActor.assumeIsolated { AIRoute.connected() }
        Section {
            Toggle(L("ai.auto"), isOn: $model.config.ai.autoSwitch).help(L("ai.auto.help"))
            ForEach(Array(chain.enumerated()), id: \.element.route) { i, e in
                HStack(spacing: 8) {
                    Text("\(i + 1).").font(PN.Font.caption.monospacedDigit()).foregroundStyle(PN.C.text3).frame(width: 18, alignment: .trailing)
                    Toggle(isOn: Binding(get: { e.on }, set: { on in
                        model.config.ai.chain = AIChain.setOn(model.config.ai.chain, route: e.route, on: on)
                        if e.route == AIRoute.local { model.config.ai.localFallback = on }
                    })) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(AIRoute.name(e.route))
                            Text(note(e.route, connected: connected.contains(e.route))).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                        }
                    }
                    .toggleStyle(.pnCheckbox)
                    Spacer()
                    Button { model.config.ai.chain = AIChain.move(model.config.ai.chain, route: e.route, by: -1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless).disabled(i == 0).help(L("ai.chain.up")).accessibilityLabel(L("ai.chain.up"))
                    Button { model.config.ai.chain = AIChain.move(model.config.ai.chain, route: e.route, by: 1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless).disabled(i == chain.count - 1).help(L("ai.chain.down")).accessibilityLabel(L("ai.chain.down"))
                }
                .disabled(!model.config.ai.autoSwitch)
            }
            Button(L("ai.chain.reset")) { model.config.ai.chain = AIChain.defaults(localOn: model.config.ai.localFallback) }
                .buttonStyle(.link).font(PN.Font.caption).disabled(!model.config.ai.autoSwitch)
            let lines = AIRoute.statusLines()
            if lines.isEmpty {
                Text(L("ai.status.ok")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            } else {
                ForEach(lines, id: \.self) { Text($0).font(PN.Font.caption).foregroundStyle(PN.C.onMe) }
                Button(L("ai.status.checkNow")) { checking = true; AIRoute.checkNow { checking = false; tick += 1 } }
                    .disabled(checking)
            }
        } header: { Text(L("ai.chain.header")).settingsAnchor("ai.chain") } footer: {
            Text(L("ai.chain.footer")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func note(_ r: String, connected: Bool) -> String {
        var parts: [String] = [L(connected ? "ai.chain.connected" : "ai.chain.notConnected")]
        if r == AIRoute.local { parts.append(L("ai.chain.localNote")) }
        if r == AIRoute.agy { parts.append(L("ai.chain.agyNote")) }
        return parts.joined(separator: " · ")
    }
}
