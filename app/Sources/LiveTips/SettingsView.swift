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
    @Published var registry = ProjectRegistry.load(from: AppPaths.projects) { didSet { if registry != oldValue { saveRegistry() } } }
    @Published var keyState: [SecretStore.Key: KeyState] = [:]
    @Published var masks: [SecretStore.Key: String] = [:]
    @Published var mirror = MirrorStatus(result: "", lastRunUTC: nil, pages: nil, mode: "")
    @Published var note = ""
    @Published var tab = "general"
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
    /// 0.8.5 (owner, rules/voices.yaml): two entries are one person ("Maria H." and "m.holosovska" are "Mariia H."):
    /// src's voice prints join dst and src becomes an alias, so typing or picking it names dst. Not during a call.
    func mergeVoice(_ src: String, into dst: String) {
        guard !CallEngine.shared.isRunning, src != dst, let d = try? Data(contentsOf: URL(fileURLWithPath: voicesPath)),
              var o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              var people = o["people"] as? [String: Any] else { return }
        var aliases = (o["aliases"] as? [String: String]) ?? [:]
        aliases[src.lowercased()] = dst
        for (k, v) in aliases where v.lowercased() == src.lowercased() { aliases[k] = dst }
        if let a = people.removeValue(forKey: src) as? [String: Any] {
            if var b = people[dst] as? [String: Any] {
                let ea = (a["embeddings"] as? [Any]) ?? [], eb = (b["embeddings"] as? [Any]) ?? []
                b["embeddings"] = Array((eb + ea).suffix(20))
                b["calls"] = ((b["calls"] as? Int) ?? 0) + ((a["calls"] as? Int) ?? 0)
                var wh = Self.whereOf(b)
                for x in Self.whereOf(a) where !wh.contains(x) { wh.append(x) }
                b["where"] = wh.contains("all") ? ["all"] : wh
                if Self.side(of: b).isEmpty, !Self.side(of: a).isEmpty { b["side"] = Self.side(of: a) }
                people[dst] = b
            } else { people[dst] = a }
        }
        o["people"] = people
        o["aliases"] = aliases
        if let out = try? JSONSerialization.data(withJSONObject: o) { try? out.write(to: URL(fileURLWithPath: voicesPath), options: .atomic) }
        loadVoices()
    }
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
        for k in [SecretStore.Key.claudeAPIKey, .notionToken] {
            keyState[k] = store.get(k) == nil ? .notSet : .untested
        }
        refreshMasks()
        refreshMirror()
        aliasesText = config.nameAliases.joined(separator: ", ")
        for k in [SecretStore.Key.claudeAPIKey, .notionToken] where store.get(k) != nil { test(k) }
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
    func isSet(_ k: SecretStore.Key) -> Bool { store.get(k) != nil }

    func refreshMirror() {
        mirror = config.workRoot.isEmpty ? MirrorStatus(result: "", lastRunUTC: nil, pages: nil, mode: "") : MirrorStatus.load(workRoot: config.workRoot)
    }

    func save(_ key: SecretStore.Key, _ value: String) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        guard store.set(key, v) else { keyState[key] = .failed(L("keys.err.keychain")); return }
        refreshMasks()
        test(key)
    }

    func remove(_ key: SecretStore.Key) {
        store.remove(key)
        keyState[key] = .notSet
        refreshMasks()
    }

    func test(_ key: SecretStore.Key) {
        guard let v = store.get(key) else { keyState[key] = .notSet; return }
        keyState[key] = .testing
        Task {
            if key == .claudeAPIKey {
                let (ok, msg, ids) = await KeyTester.claude(key: v, workspace: nil)
                keyState[key] = ok ? .ok(msg) : .failed(SettingsModel.friendly(msg))
                if ok, !ids.isEmpty { config.knownModels = ids }
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
        registry.workspaces = WorkspaceScanner.scan(workRoot: config.workRoot, projects: registry.projects,
                                                    extra: registry.extraWorkspaces, excluded: registry.excluded)
    }

    // ---- folder projects (2026-10-26: Notion and configs are optional)
    func scanFolders() {
        guard !config.workRoot.isEmpty else { note = L("set.setTheWorkFolder"); return }
        let before = registry.projects.count
        let r = WorkspaceScanner.scanFolders(workRoot: config.workRoot, extra: registry.extraWorkspaces, excluded: registry.excluded)
        registry.merge(folders: r.projects)
        rescanWorkspaces()
        note = "\(r.workspaces.count) workspace(s), \(registry.projects.count - before) new project(s)"
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
    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(choices, id: \.self) { id in
                (Text(prettyModel(id)) + Text("  " + id).font(PN.Font.caption).foregroundColor(.secondary)).tag(id)
            }
        }
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
            case .testing: ProgressView().controlSize(.small)
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
struct RoutePicker: View {
    @Binding var selection: String
    var recommended: String
    var discouraged: String? = nil
    var body: some View {
        Picker(L("ai.route"), selection: $selection) {
            ForEach([AIRoute.code, AIRoute.api], id: \.self) { r in
                Text(AIRoute.name(r) + (r == recommended ? L("ai.route.recommended") : r == discouraged ? L("ai.route.notRecommended") : "")).tag(r)
            }
        }
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
    @State private var showProjectsInfo = false
    @State private var aiChecking = false     // 0.8.2: Check now on the ways that are out
    @State private var aiTick = 0
    @AppStorage("homeShowStats") private var showStats = true      // Home: this week's numbers (2026-10-27)

    struct Pane: Identifiable { let id: String; let title: String; let symbol: String; let subtitle: String }
    static var panes: [Pane] { [   // titles follow the interface language
        Pane(id: "general", title: "General", symbol: "gearshape", subtitle: "Your name on calls, folders, Notion and how the app behaves."),
        Pane(id: "keys", title: "Keys", symbol: "key", subtitle: "The Claude API key and the Notion token, kept in the macOS Keychain."),
        Pane(id: "projects", title: "Projects", symbol: "folder", subtitle: "Your workspaces and projects. Ticked ones show up in Start call."),
        Pane(id: "calendars", title: "Calendars", symbol: "calendar", subtitle: "Your Google, Microsoft and iCloud calendars: pick the calls to prepare and start."),
        Pane(id: "notion", title: "Notion", symbol: "doc.text", subtitle: "Meeting pages after each call and the optional local copy of Notion."),
        Pane(id: "ai", title: "AI", symbol: "cpu", subtitle: "Models, spending limits, the local AI layer and the preparation."),
        Pane(id: "about", title: "About", symbol: "info.circle", subtitle: "Version, updates and where your data lives."),
    ].map { Pane(id: $0.id, title: L("settings.tab." + $0.id), symbol: $0.symbol, subtitle: L("settings.pane." + $0.id)) } }

    // 2026-10-26 (owner): the welcome tour's look: a sidebar of icon tiles, a header per pane, soft cards.
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Self.panes) { p in
                    Button { model.tab = p.id } label: {
                        HStack(spacing: 10) {
                            IconTile(symbol: p.symbol, size: 26)
                            Text(p.title)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .background(RoundedRectangle(cornerRadius: 8).fill(model.tab == p.id ? Color.accentColor.opacity(0.2) : .clear))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(10)
            .frame(width: 200)
            .background(Color.secondary.opacity(0.05))
            Divider()
            VStack(spacing: 0) {
                let p = Self.panes.first { $0.id == model.tab } ?? Self.panes[0]
                WindowHeader(symbol: p.symbol, title: p.title, subtitle: p.subtitle)
                    .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 2)
                pane.scrollContentBackground(.hidden)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onChange(of: model.tab) { SettingsWindow.window?.title = SettingsWindow.title(for: model.tab) }
    }

    @ViewBuilder var pane: some View {
        switch model.tab {
        case "keys": keys
        case "projects": projects
        case "ai": ai
        case "notion": notion
        case "calendars": CalendarsPane()
        case "how": HowItWorksView()
        case "about": AboutView(model: model)
        default: general
        }
    }

    var keys: some View {
        Form {
            Section {
                KeyRow(title: L("keys.notion.title"), hint: L("keys.notion.hintShort"), key: .notionToken, model: model)
            } footer: {
                Text(L("set.pasteWithVAnd"))
                    .font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
        }
        .formStyle(.grouped)
    }

    var ai: some View {
        Form {
            // 0.8.2 (owner): everything about Claude in one tab. Access once for the whole app, then the way and the
            // models for each job, then the automatic switch between the two ways.
            Section {
                LabeledContent(L("ai.access.account")) {
                    HStack(spacing: 8) {
                        if PrepRunner.claudePath == nil {
                            Text(L("set.cc.notInstalled")).foregroundStyle(PN.C.text3)
                        } else {
                            Image(systemName: runner.loggedIn == true ? "checkmark.circle.fill" : (runner.loggedIn == false ? "exclamationmark.triangle.fill" : "circle.dotted"))
                                .foregroundStyle(runner.loggedIn == true ? PN.C.turn : (runner.loggedIn == false ? PN.C.onMe : PN.C.text3))
                            Text(runner.loggedIn == true ? L("set.cc.signedIn") + (runner.authInfo.isEmpty ? "" : " (\(runner.authInfo))")
                                 : runner.loggedIn == false ? L("set.cc.notSignedIn") : L("set.cc.checking"))
                                .foregroundStyle(PN.C.text3)
                            if runner.loggedIn == false { Button(L("set.logIn")) { runner.openLogin() } }
                            Button(L("set.check")) { runner.refreshAuth() }
                        }
                    }
                }
                .help(L("ai.access.accountHelp"))
                KeyRow(title: L("keys.claude.title"), hint: L("keys.claude.hint"), key: .claudeAPIKey, model: model)
            } header: { Text(L("ai.access")) } footer: {
                Text(L("ai.access.footer")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            .onAppear { runner.refreshAuth() }
            Section {
                RoutePicker(selection: $model.config.ai.prep, recommended: AIRoute.code)
                Picker(L("set.model"), selection: $runner.model) {
                    ForEach(PrepRunner.models, id: \.id) { m in Text(m.label).tag(m.id) }
                }
                .help(L("set.sonnetReadsTheFiles"))
            } header: { Text(L("ai.job.prep")) } footer: {
                Text(L("set.cc.builds")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            Section {
                RoutePicker(selection: $model.config.ai.tips, recommended: AIRoute.api, discouraged: AIRoute.code)
                    .help(L("ai.tips.codeWhy"))
                if model.config.ai.tips == AIRoute.code {
                    Text(L("ai.tips.codeWhy")).font(PN.Font.caption).foregroundStyle(PN.C.onMe)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ModelPicker(title: L("set.classify"), selection: $model.config.models.classify, choices: model.modelChoices).help(L("set.decidesIfATip"))
                ModelPicker(title: L("set.tip"), selection: $model.config.models.tip, choices: model.modelChoices).help(L("set.writesTheTipYou"))
                Toggle(L("set.answerQuestionsToAnyone"), isOn: $model.config.answerAny)
                    .help(L("set.aQuestionAskedTo"))
                Toggle(L("set.secondRequestWhenClaude"), isOn: $model.config.hedgeEnabled)
                    .help(L("set.ifClaudeShowsNo"))
            } header: { Text(L("ai.job.tips")) } footer: {
                Text(model.config.knownModels.isEmpty ? L("set.modelsTest") : L("set.modelsKnown"))
                    .font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            Section {
                RoutePicker(selection: $model.config.ai.after, recommended: AIRoute.code)
                ModelPicker(title: L("set.model"), selection: $model.config.models.analysis, choices: model.modelChoices).help(L("set.summaryAndAnalysisNot"))
                Toggle(L("set.rateTipsAfterEach"), isOn: $model.config.judgeAfterCall)
                    .help(L("set.afterTheCallClaude"))
                if !CallEngine.shared.judgeResult.isEmpty {
                    Text(CallEngine.shared.judgeResult).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                }
            } header: { Text(L("ai.job.after")) } footer: {
                Text(L("ai.after.footer")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            Section {
                Toggle(L("ai.auto"), isOn: $model.config.ai.autoSwitch)
                    .help(L("ai.auto.help"))
                let lines = AIRoute.statusLines()
                if lines.isEmpty {
                    Text(L("ai.status.ok")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                } else {
                    ForEach(lines, id: \.self) { Text($0).font(PN.Font.caption).foregroundStyle(PN.C.onMe) }
                    Button(L("ai.status.checkNow")) { aiChecking = true; AIRoute.checkNow { aiChecking = false; aiTick += 1 } }
                        .disabled(aiChecking)
                }
            } header: { Text(L("ai.auto.header")) } footer: {
                Text(L("ai.auto.help")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .id(aiTick)
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
            } header: { Text(L("set.spendingLimits")) } footer: {
                Text(L("set.monthSpend", ["spent": String(format: "%.2f", SpendLedger.monthSpent()), "cap": String(format: "%.0f", model.config.budget.monthlyHardUSD)]))
                    .font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            Section {
                Toggle(L("set.localAiDefaultFor"), isOn: $model.config.localAI.enabled)
                    .help(L("set.theTipsWindowMenu"))
                Picker(L("set.engine"), selection: $model.config.localAI.engine) {
                    Text(L("set.builtInRecommended")).tag("embedded")
                    Text("Ollama").tag("ollama")
                }
                .disabled(!model.config.localAI.enabled)
                .help(L("set.builtInNothingElse"))
                if model.config.localAI.engine == "ollama" {
                    TextField(L("set.ollamaUrl"), text: $model.config.localAI.ollamaURL).disabled(!model.config.localAI.enabled)
                    TextField(L("set.model"), text: $model.config.localAI.ollamaModel, prompt: Text("bge-m3"))
                        .disabled(!model.config.localAI.enabled)
                        .help(L("set.anEmbeddingModelPulled"))
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
            } header: { Text(L("set.localAi")) } footer: {
                Text(L("set.audioAndVoicePrints")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            .onChange(of: model.config.localAI) { LocalAIService.shared.apply(); model.refreshLocalAI(after: 2) }
            .onAppear { model.refreshLocalAI() }
            Section {
                Toggle(L("set.identifySpeakers"), isOn: $model.config.speakersEnabled)
                    .help(L("set.tellsTheVoicesOn"))
                    .onChange(of: model.config.speakersEnabled) { LocalAIService.shared.apply() }
                LabeledContent(L("set.status")) {
                    let st = LocalAIService.shared.speakersLine()
                    HStack(spacing: 6) {
                        Image(systemName: st.ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(st.ok ? .green : (model.config.speakersEnabled ? .orange : .secondary))
                        Text(st.text).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                        Spacer()
                        Button(L("set.voiceLibrary")) {
                            NSWorkspace.shared.open(URL(fileURLWithPath: (CallEngine.shared.appRoot as NSString).appendingPathComponent("voices")))
                        }.controlSize(.small)
                    }
                }
                DisclosureGroup(L("set.voiceLibraryN", ["n": "\(model.voices.count)"])) {
                    if model.voices.isEmpty { Text(L("set.nobodyYetNamesYou")).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
                    ForEach(model.voices) { v in
                        HStack {
                            Text(v.name)
                            Spacer()
                            Menu(v.side == "team" ? L("set.sideTeam") : (v.side == "client" ? L("set.sideClient") : L("set.sideUnknown"))) {
                                Button { model.setVoiceSide(v.name, "team") } label: { v.side == "team" ? Label(L("set.teamOurs"), systemImage: "checkmark") : Label(L("set.teamOurs"), systemImage: "person.2") }
                                Button { model.setVoiceSide(v.name, "client") } label: { v.side == "client" ? Label(L("set.clientSide"), systemImage: "checkmark") : Label(L("set.clientSide"), systemImage: "building.2") }
                            }
                            .menuStyle(.borderlessButton).fixedSize().font(PN.Font.caption)
                            .foregroundStyle(v.side == "team" ? Color.accentColor : .primary)
                            .disabled(CallEngine.shared.isRunning)
                            .help(L("set.whichSideThisPerson"))
                            Menu(SettingsModel.whereLabel(v.wherer)) {
                                ForEach(model.voiceWheres, id: \.tag) { sc in
                                    Button { model.toggleVoiceWhere(v.name, sc.tag) } label: {
                                        if v.wherer.contains(sc.tag) { Label(sc.label, systemImage: "checkmark") } else { Text(sc.label) }
                                    }
                                }
                            }
                            .menuStyle(.borderlessButton).fixedSize().font(PN.Font.caption)
                            .disabled(CallEngine.shared.isRunning)
                            .help(L("set.theCallsThisVoice"))
                            Text("\(v.calls) call\(v.calls == 1 ? "" : "s")").font(PN.Font.caption).foregroundStyle(PN.C.text3)
                            Menu(L("set.mergeInto")) {
                                ForEach(model.voices.filter { $0.name != v.name }) { o in
                                    Button(o.name) { model.mergeVoice(v.name, into: o.name) }
                                }
                            }
                            .menuStyle(.borderlessButton).fixedSize().font(PN.Font.caption)
                            .disabled(CallEngine.shared.isRunning || model.voices.count < 2)
                            .help(L("set.mergeHelp", ["name": v.name]))
                            Button(L("set.forget")) { model.forgetVoice(v.name) }.controlSize(.small).disabled(CallEngine.shared.isRunning)
                                .help(L("set.removesThisPersonS"))
                        }
                    }
                let al = model.voiceAliases
                if !al.isEmpty {
                    Text(L("set.aliases", ["list": al.sorted { $0.key < $1.key }.map { "\($0.key) → \($0.value)" }.joined(separator: ", ")]))
                        .font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                }
                }
                .onAppear { model.loadVoices() }
            } header: { Text(L("set.speakers")) } footer: {
                Text(L("set.inTheTipsWindow"))
                    .font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
        }
        .formStyle(.grouped)
    }

    var projects: some View {
        Form {
            Section {
                HStack {
                    Button(L("set.scanWorkFolder")) { model.scanFolders() }
                        .disabled(model.config.workRoot.isEmpty)
                        .help(L("set.addsTheProjectFolders"))
                    Menu(L("home.finish.add")) {
                        Button(L("set.projectFolder")) { model.addProjectFolder() }
                        Button(L("set.workspaceFolder")) { model.addWorkspaceFolder() }
                        Divider()
                        Button(L("set.importControlTowerConfigs")) { model.importProjects() }
                    }
                    .fixedSize()
                    Button { showProjectsInfo.toggle() } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.borderless).accessibilityLabel(L("set.aboutProjects"))
                        .popover(isPresented: $showProjectsInfo, arrowEdge: .bottom) { projectsInfo }
                    Spacer()
                    Button(L("set.reindexAll")) { IndexService.shared.reindexAll() }
                        .help(L("set.rebuildTheSearchIndex"))
                }
                if model.config.workRoot.isEmpty {
                    Text(L("set.setTheWorkFolder")).font(PN.Font.caption).foregroundStyle(PN.C.onMe)
                }
                if !model.note.isEmpty { Text(model.note).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
            }
            let cands = model.folderCandidates
            if !cands.isEmpty {
                Section {
                    ForEach(cands, id: \.dir) { c in
                        HStack {
                            Image(systemName: "folder.badge.questionmark").foregroundStyle(PN.C.text3)
                            VStack(alignment: .leading, spacing: 1) {
                                Text((c.dir as NSString).lastPathComponent)
                                Text("\(c.projects) folder\(c.projects == 1 ? "" : "s") inside").font(PN.Font.caption).foregroundStyle(PN.C.text3)
                            }
                            Spacer()
                            Button(L("set.addAsWorkspace")) { model.addWorkspace(c.dir) }
                            Button(L("set.ignore")) { model.ignoreFolder(c.dir) }
                        }
                    }
                } header: { Text(L("set.foundInYourWork")) } footer: {
                    Text(L("set.aWorkspaceSSubfolders")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                }
            }
            ForEach(model.registry.workspaces, id: \.name) { w in
                Section {
                    let members = model.registry.projects.filter { w.projects.contains($0.slug) }
                    if members.isEmpty { Text(L("set.noProjectsYetScan")).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
                    ForEach(members, id: \.slug) { p in projectRow(p.slug) }
                } header: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.stack.3d.up")
                        Text(w.name)
                        if model.workspaceHasNotion(w) { Text("Notion").font(PN.Font.caption).padding(.horizontal, 5).background(Capsule().fill(Color.secondary.opacity(0.15))) }
                        Spacer()
                        Text(L("set.calls") + (w.root as NSString).lastPathComponent).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                        Menu {
                            Button(L("home.recent.finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: w.root)]) }
                            Button(L("set.removeWorkspaceFromPacenote"), role: .destructive) { model.removeWorkspace(w) }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    }
                }
            }
            let inWs = Set(model.registry.workspaces.flatMap(\.projects))
            let others = model.registry.projects.filter { !inWs.contains($0.slug) }
            if !others.isEmpty {
                Section {
                    ForEach(others, id: \.slug) { p in projectRow(p.slug) }
                } header: { Text(model.registry.workspaces.isEmpty ? L("settings.tab.projects") : L("set.otherProjects")) }
            }
            if model.registry.projects.isEmpty && model.registry.workspaces.isEmpty && cands.isEmpty {
                Section {
                    Text(L("set.noProjectsYetScan2"))
                        .font(.callout).foregroundStyle(PN.C.text3)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// 2026-10-27 (owner): plain words instead of the long text on top of the tab.
    var projectsInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("set.howProjectsWork")).font(.headline)
            Text(L("set.eachProjectIsA"))
            Text(L("set.tickAProjectTo"))
            Text(L("set.removesAProjectOr"))
            Text(L("set.optionalExtrasComeFrom"))
        }
        .font(.callout).fixedSize(horizontal: false, vertical: true)
        .padding(16).frame(width: 380)
    }

    func projectMenu(_ i: Int) -> some View {
        let p = model.registry.projects[i]
        return Menu {
            Button(L("home.recent.finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p.root)]) }.disabled(p.root.isEmpty)
            Divider()
            // Both on by default; kept here for a project whose call text must not leave the Mac.
            Toggle(L("set.useClaudeForTips"), isOn: $model.registry.projects[i].apiAllowed)
            Toggle(L("set.searchThisFolder"), isOn: $model.registry.projects[i].index.enabled)
            Button(L("set.reindexNow")) { IndexService.shared.reindex(p.root) }.disabled(!p.index.enabled)
            Divider()
            Button(L("set.removeProjectFromPacenote"), role: .destructive) { model.excludeProject(p.slug) }
        } label: { Image(systemName: "ellipsis.circle") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(L("set.showInFinderRemove"))
    }

    @ViewBuilder func projectRow(_ slug: String) -> some View {
        if let i = model.registry.projects.firstIndex(where: { $0.slug == slug }) {
            let p = model.registry.projects[i]
            HStack(alignment: .center) {
                Toggle("", isOn: Binding(get: { model.registry.projects[i].status != "archived" },
                                         set: { model.registry.projects[i].status = $0 ? "active" : "archived" }))
                    .toggleStyle(.checkbox).labelsHidden()
                    .help(L("set.activeOfferedInStart"))
                Image(systemName: "folder").foregroundStyle(PN.C.text3)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(p.name).foregroundStyle(p.status == "archived" ? .secondary : .primary)
                        if !p.config.isEmpty {
                            Text(L("set.config")).font(PN.Font.caption).padding(.horizontal, 5).background(Capsule().fill(Color.secondary.opacity(0.15)))
                                .help(L("set.peopleNotionPagesAnd") + p.config)
                        }
                    }
                    Text(p.root.isEmpty ? L("set.noFolder") : p.root).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                projectMenu(i)
            }
            .contextMenu {
                Button(L("home.recent.finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p.root)]) }.disabled(p.root.isEmpty)
                Button(L("set.reindexNow")) { IndexService.shared.reindex(p.root) }.disabled(!p.index.enabled)
                Button(L("set.removeFromPacenote"), role: .destructive) { model.excludeProject(p.slug) }
            }
        }
    }

    // 2026-10-27 (owner): everything about Notion in one place (it was hidden under General > Behaviour).
    var notion: some View {
        Form {
            Section {
                Toggle(L("set.writeAMeetingPage"), isOn: $model.config.notionWriteSummary)
                KeyRow(title: L("keys.notion.title"), hint: L("keys.notion.hint"), key: .notionToken, model: model)
                NotionDestinationView()
            } header: { Text(L("set.meetingPages")) } footer: {
                Text(L("set.afterTheCallA"))
                    .font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            let withConfig = model.registry.projects.filter { !$0.config.isEmpty }
            if !withConfig.isEmpty {
                Section {
                    ForEach(withConfig, id: \.slug) { p in
                        LabeledContent(p.name) { Text(L("set.itsOwnMeetingsDatabase")).foregroundStyle(PN.C.text3) }
                    }
                } header: { Text(L("set.projectsSetUpWith")) } footer: {
                    Text(L("set.theseProjectsHaveA"))
                        .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                }
            }
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
                    }
                } label: {
                    Text(L("set.notionMirror")).help(L("set.aReadOnlyCopy"))
                }
            } header: { Text(L("set.localCopyOfNotion")) } footer: {
                Text(L("set.aReadOnlyCopy2"))
                    .font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
        }
        .formStyle(.grouped)
    }

    var general: some View {
        Form {
            Section {
                FolderRow(title: L("set.workFolder"),
                          hint: L("set.workFolderHint"),
                          path: $model.config.workRoot, placeholder: "~/work", choose: { model.chooseFolder(L("set.chooseWork")) })
                    .onChange(of: model.config.workRoot) { model.refreshMirror(); model.rescanWorkspaces() }
                LabeledContent(L("set.yourNameOnCalls")) {
                    TextField("", text: $model.aliasesText, prompt: Text(L("onboarding.name.placeholder")))
                        .onSubmit { model.saveAliases() }
                        .onChange(of: model.aliasesText) { model.saveAliases() }
                }
                .help(L("set.everyFormPeopleUse"))
            } header: { Text(L("set.setup")) }
            Section {
                Picker(L("callSettings.uiLang"), selection: $model.config.uiLanguage) {
                    Text("English").tag("en")
                    Text("Українська").tag("uk")
                }
                Toggle(L("set.hideTheTipsWindow"), isOn: $model.config.stealthDefault)
                    .help(L("set.defaultForNewCalls"))
                Toggle(isOn: $showStats) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("set.showThisWeekS"))
                        Text(L("set.callsTimeOnCalls"))
                            .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    }
                }
                Toggle(L("settings.general.dock"), isOn: $model.config.showInDock)
                    .onChange(of: model.config.showInDock) { NSApp.setActivationPolicy(model.config.showInDock ? .regular : .accessory) }
            } header: { Text(L("set.behaviour")) } footer: {
                HStack {
                    Text(L("set.settingsSaveAutomaticallyAnd"))
                    Button(L("home.recent.finder")) { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.config]) }.buttonStyle(.pnTertiary)
                }
                HStack {
                    Text(L("set.yourCorrectionsCardsOn"))
                    Button(L("set.showLog")) {
                        if !FileManager.default.fileExists(atPath: EditLog.url.path) { FileManager.default.createFile(atPath: EditLog.url.path, contents: nil) }
                        NSWorkspace.shared.activateFileViewerSelecting([EditLog.url])
                    }.buttonStyle(.pnTertiary)
                }
                .font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            Section {
                Toggle(isOn: $model.config.consentSay) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("set.playAnAudioConsent"))
                        Text(L("set.whenARecordingStarts"))
                            .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    }
                }
                Toggle(isOn: $model.config.consentChat) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("set.copyAConsentMessage"))
                        Text(L("set.whenARecordingStarts2"))
                            .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    }
                }
                if model.config.consentSay || model.config.consentChat {
                    TextField("English", text: $model.config.consentTextEN, axis: .vertical).lineLimit(2...4)
                    TextField("Українська", text: $model.config.consentTextUK, axis: .vertical).lineLimit(2...4)
                }
            } header: { Text(L("set.recordingConsent")) } footer: {
                Text(L("set.offByDefaultThe"))
                    .font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            Section {
                ShortcutRow(action: .help)
                ShortcutRow(action: .pause)
                ShortcutRow(action: .mute)
                ShortcutRow(action: .compact)
                ShortcutRow(action: .proactive)
                ShortcutRow(action: .presentation)
                ShortcutRow(action: .prevSlide)
                ShortcutRow(action: .nextSlide)
                ShortcutRow(action: .add30)
            } header: { Text(L("set.shortcuts")) } footer: {
                Text(L("set.theyWorkFromAny"))
                    .font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            Section {
                LabeledContent {
                    HStack {
                        Text(model.config.effectiveAppRoot(appSupport: AppPaths.support.path))
                            .font(.callout).foregroundStyle(PN.C.text3).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(L("onboarding.folder.choose")) { if let p = model.chooseFolder(L("set.chooseApp")) { model.config.appRoot = p } }
                        if !model.config.appRoot.isEmpty { Button(L("set.default")) { model.config.appRoot = "" } }
                    }
                } label: {
                    Text(L("set.appFolder")).help(L("set.whereTheAppKeeps"))
                }
            } header: { Text(L("set.advanced")) }
        }
        .formStyle(.grouped)
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
        .formStyle(.grouped)
    }

    var arrow: some View { Image(systemName: "arrow.right").foregroundStyle(PN.C.text3) }

    func box(_ title: String, _ sub: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.callout).bold()
            Text(sub).font(PN.Font.caption).foregroundStyle(PN.C.text3).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.4)))
    }

    func row(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).frame(width: 20).foregroundStyle(PN.C.text3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(text).font(.callout).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
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
                        Text(L("settings.about.byline")).font(.system(size: 15)).foregroundStyle(PN.C.text2)
                        Text(versionLine).font(PN.Font.caption).foregroundStyle(PN.C.text3).textSelection(.enabled)
                    }
                    Spacer()
                    // Asks GitHub for the latest release only when pressed; nothing is checked in the background.
                    Button(L("settings.about.checkUpdates")) { Task { await checkUpdates() } }
                        .buttonStyle(.pnSecondary).disabled(checking)
                }
                if !updateNote.isEmpty {
                    HStack {
                        Text(updateNote).font(.callout).foregroundStyle(updateURL != nil ? PN.C.accent : PN.C.text3)
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
            // 2026-10-27 (owner): privacy policy and terms of use, published on the website.
            Section {
                Text(L("settings.about.dataBody"))
                    .font(.callout).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    Link(L("settings.about.privacy"), destination: URL(string: "https://tower.bodco.pm/pacenote/privacy/")!)
                    Link(L("settings.about.terms"), destination: URL(string: "https://tower.bodco.pm/pacenote/terms/")!)
                    Link(L("settings.about.license"), destination: URL(string: "https://github.com/bodco/live-tips/blob/main/LICENSE")!)
                }
            } header: { Text(L("settings.about.yourData")) }
            // Pacenote 0.8 (F4, spec 7-8): the technical install status lives here (onboarding shows one progress line).
            Section {
                ForEach(setup.steps) { st in
                    HStack(spacing: 8) {
                        Image(systemName: st.state == .ok ? "checkmark.circle.fill" : st.state == .failed ? "xmark.circle.fill" : "circle")
                            .foregroundStyle(st.state == .ok ? PN.C.turn : st.state == .failed ? PN.C.danger : PN.C.text3)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(st.title)
                            if !st.detail.isEmpty { Text(st.detail).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(1) }
                        }
                    }
                }
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
                if let cc = setup.steps.first(where: { $0.id == "claude" }), cc.state != .ok, cc.state != .unknown {
                    Button(L("onboarding.claude.install")) { Task { await setup.installOne("claude") } }.buttonStyle(.pnSecondary).disabled(setup.busy)
                }
                HStack {
                    Button(L("about.components.check")) { Task { await setup.checkAll() } }.buttonStyle(.pnTertiary).disabled(setup.busy)
                    Button(L("about.components.open")) { SetupWindow.show() }.buttonStyle(.pnTertiary)
                }
            } header: { Text(L("about.components")) } footer: {
                Text(L("settings.about.readyFooter", ["help": HotKeys.shared.combo(.help).display, "pause": HotKeys.shared.combo(.pause).display]))
                    .font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
        }
        .formStyle(.grouped)
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
        case "general", "calendars", "keys", "projects", "ai", "notion": return L("settings.tab." + tab)
        default: return L("settings.windowTitle")
        }
    }

    static func show(tab: String = "general") {
        model.tab = tab
        window?.title = title(for: tab)
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: Localized { SettingsView(model: model) }))
            w.title = title(for: tab)
            w.setContentSize(NSSize(width: 960, height: 660))
            w.isReleasedWhenClosed = false
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
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
            w.isReleasedWhenClosed = false
            window = w
        }
        window?.title = L("settings.how.title")
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
