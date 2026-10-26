import AppKit
import AVFoundation
import LiveTipsCore
import SwiftUI

enum AppPaths {
    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LiveTips")
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
    struct Voice: Identifiable { let name: String; let scope: String; let calls: Int; var id: String { name } }
    @Published var voices: [Voice] = []
    var voicesPath: String { (CallEngine.shared.appRoot as NSString).appendingPathComponent("voices/voices.json") }
    func loadVoices() {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: voicesPath)),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let people = o["people"] as? [String: Any] else { voices = []; return }
        voices = people.compactMap { k, v in
            guard let p = v as? [String: Any] else { return nil }
            return Voice(name: k, scope: (p["scope"] as? String) ?? "", calls: (p["calls"] as? Int) ?? 0)
        }.sorted { ($0.scope, $0.name) < ($1.scope, $1.name) }
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
    static func scopeLabel(_ s: String) -> String {
        if s == "team" { return "Team, all projects" }
        if s.hasPrefix("project:") { return "Client of " + String(s.dropFirst(8)) }
        if s.hasPrefix("workspace:") { return "Workspace " + String(s.dropFirst(10)) + ", all its projects" }
        return "All projects (saved before scopes)"
    }

    /// 2026-10-26 (owner): where a voice is suggested: the team (every project), one project, or a whole workspace.
    var voiceScopes: [(tag: String, label: String)] {
        var out: [(String, String)] = [("team", "Team, all projects")]
        for w in registry.workspaces { out.append(("workspace:" + w.name, "Workspace " + w.name + ", all its projects")) }
        for w in registry.workspaces { out.append(("project:" + w.name.lowercased(), "Calls of workspace " + w.name + " only")) }
        for p in registry.projects where p.status != "archived" { out.append(("project:" + p.slug, "Project " + p.name)) }
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
        mirrorNote = "Setting up: finding your Control Tower databases…"
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
            return "Key rejected. Copy the whole key and paste it again."
        }
        if m.contains("403") || m.contains("permission") { return "The key works but has no access. Check its workspace or integration access." }
        if m.contains("429") || m.contains("rate") { return "Rate limited. Try again in a minute." }
        if m.contains("offline") || m.contains("network") || m.contains("internet") || m.contains("timed out") {
            return "No connection. Check the internet and press Test."
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
        guard store.set(key, v) else { keyState[key] = .failed("Keychain write failed"); return }
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
        guard let dir = chooseFolder("Choose the folder with Control Tower project configs (projects/*.md)") else { return }
        let found = ProjectConfigImporter.importFolder(dir)
        registry.merge(imported: found)
        rescanWorkspaces()
        note = "Imported \(found.count) project(s)"
    }

    func rescanWorkspaces() {
        guard !config.workRoot.isEmpty else { return }
        registry.workspaces = WorkspaceScanner.scan(workRoot: config.workRoot, projects: registry.projects,
                                                    extra: registry.extraWorkspaces, excluded: registry.excluded)
    }

    // ---- folder projects (2026-10-26: Notion and configs are optional)
    func scanFolders() {
        guard !config.workRoot.isEmpty else { note = "Set the work folder in General first."; return }
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
        guard let dir = chooseFolder("Choose a workspace folder: its subfolders become projects") else { return }
        addWorkspace(dir)
    }

    func addProjectFolder() {
        guard let dir = chooseFolder("Choose a project folder") else { return }
        registry.excluded.removeAll { $0 == dir }
        var p = Project(name: (dir as NSString).lastPathComponent, slug: WorkspaceScanner.slug((dir as NSString).lastPathComponent), root: dir)
        p.workspace = ((dir as NSString).deletingLastPathComponent as NSString).lastPathComponent
        registry.merge(folders: [p])
        rescanWorkspaces()
        note = "Added \(p.name)"
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
        note = "Removed \(w.name) from Live Tips (the folder is untouched)"
    }

    func excludeProject(_ slug: String) {
        if let p = registry.projects.first(where: { $0.slug == slug }), !p.root.isEmpty, !registry.excluded.contains(p.root) {
            registry.excluded.append(p.root)
        }
        removeProject(slug)
        rescanWorkspaces()
    }

    struct ReadyItem { let title: String; let ok: Bool; let action: String; let tab: String? }
    var readyItems: [ReadyItem] {
        var keyOK = false
        if case .ok = keyState[.claudeAPIKey] ?? .notSet { keyOK = true }
        return [
            ReadyItem(title: "Claude API key works", ok: keyOK, action: "Open Keys", tab: "keys"),
            ReadyItem(title: "Work folder set", ok: !config.workRoot.isEmpty, action: "Set below", tab: nil),
            ReadyItem(title: "Projects imported", ok: !registry.projects.isEmpty, action: "Import…", tab: nil),
            ReadyItem(title: "Your name on calls", ok: !config.nameAliases.isEmpty, action: "Set below", tab: nil),
            ReadyItem(title: "Microphone allowed", ok: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, action: "Asked on the first call", tab: nil),
        ]
    }

    func saveConfig() { try? config.save(to: AppPaths.config) }
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
                (Text(prettyModel(id)) + Text("  " + id).font(.caption).foregroundColor(.secondary)).tag(id)
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
            case .notSet: Image(systemName: "circle.dashed").foregroundStyle(.secondary).help("Not set")
            case .untested: Image(systemName: "circle.fill").foregroundStyle(.yellow).help("Saved, checking…")
            case .testing: ProgressView().controlSize(.small)
            case .ok(let m): Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help(m)
            case .failed(let m): Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).help(m)
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

struct KeyRow: View {
    let title: String
    let hint: String
    let key: SecretStore.Key
    @ObservedObject var model: SettingsModel
    @State private var value = ""

    var body: some View {
        LabeledContent {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    SecureField("", text: $value)
                        .onSubmit { model.save(key, value); value = "" }
                    IconButton(symbol: "square.and.arrow.down", label: "Save to Keychain") { model.save(key, value); value = "" }
                        .disabled(value.isEmpty)
                    IconButton(symbol: "checkmark.seal", label: "Test with one request") { model.test(key) }
                        .disabled(!model.isSet(key))
                    IconButton(symbol: "trash", label: "Remove from Keychain", role: .destructive) { model.remove(key) }
                        .disabled(!model.isSet(key))
                    StateIcon(state: model.keyState[key] ?? .notSet)
                    Text(model.masks[key] ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .leading)
                }
                statusText
            }
        } label: {
            Text(title).help(hint)
        }
    }

    @ViewBuilder var statusText: some View {
        switch model.keyState[key] ?? .notSet {
        case .ok(let m): Label(m, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary)
        case .failed(let m): Label(m, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
        case .notSet: Text(hint).font(.caption).foregroundStyle(.secondary)
        default: EmptyView()
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
                Button("Browse…") { if let p = choose() { path = p } }
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

    struct Pane: Identifiable { let id: String; let title: String; let symbol: String; let subtitle: String }
    static let panes: [Pane] = [
        Pane(id: "general", title: "General", symbol: "gearshape", subtitle: "Your name on calls, folders, Notion and how the app behaves."),
        Pane(id: "keys", title: "Keys", symbol: "key", subtitle: "The Claude API key and the Notion token, kept in the macOS Keychain."),
        Pane(id: "projects", title: "Projects", symbol: "folder", subtitle: "Your workspaces and projects. Ticked ones show up in Start call."),
        Pane(id: "ai", title: "AI", symbol: "cpu", subtitle: "Models, spending limits, the local AI layer and the preparation."),
        Pane(id: "how", title: "How it works", symbol: "point.3.connected.trianglepath.dotted", subtitle: "What happens before, during and after a call."),
        Pane(id: "about", title: "About", symbol: "info.circle", subtitle: "Version, updates and where your data lives."),
    ]

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
        case "how": HowItWorksView()
        case "about": AboutView(model: model)
        default: general
        }
    }

    var keys: some View {
        Form {
            Section {
                KeyRow(title: "Claude API key", hint: "From console.anthropic.com > API keys. Used for tips during the call and the summary after it.", key: .claudeAPIKey, model: model)
                KeyRow(title: "Notion token", hint: "Internal integration token (notion.so/my-integrations). Optional: fresh changes and the call summary in Notion.", key: .notionToken, model: model)
            } footer: {
                Text("Paste with ⌘V and press Return. Each key is checked with one request. Keys live only in the macOS Keychain and survive app updates.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    var ai: some View {
        Form {
            // UI review 26.10: how "Prepare now" runs lives here, Start call keeps one button.
            Section {
                Picker("Run with", selection: $runner.useAPI) {
                    Text("Claude account").tag(false); Text("API key").tag(true)
                }
                .pickerStyle(.segmented)
                .help("Claude account: Claude Code's own sign-in, uses your Claude plan. API key: the key in Keys, billed like the tips; use it when the plan's limit is reached.")
                if !runner.useAPI {
                    HStack(spacing: 8) {
                        Image(systemName: runner.loggedIn == true ? "checkmark.circle.fill" : (runner.loggedIn == false ? "exclamationmark.triangle.fill" : "circle.dotted"))
                            .foregroundStyle(runner.loggedIn == true ? Color.green : (runner.loggedIn == false ? Color.orange : Color.secondary))
                        Text(runner.loggedIn == true ? "Claude Code signed in" + (runner.authInfo.isEmpty ? "" : " (\(runner.authInfo))")
                             : runner.loggedIn == false ? "Claude Code is not signed in" : "Checking the Claude Code sign-in…")
                            .foregroundStyle(.secondary)
                        Spacer()
                        if runner.loggedIn == false { Button("Log in…") { runner.openLogin() } }
                        Button("Check") { runner.refreshAuth() }
                    }
                }
                Picker("Model", selection: $runner.model) {
                    ForEach(PrepRunner.models, id: \.id) { m in Text(m.label).tag(m.id) }
                }
                .help("Sonnet reads the files and pulls out the facts well and fast; Opus is a little better on a hard call but slower and uses the plan's limit several times faster.")
            } header: { Text("Preparation (Prepare now in Start call)") } footer: {
                Text(PrepRunner.claudePath == nil ? "Claude Code is not installed on this Mac: Start call offers the Cowork request instead."
                     : "Claude Code builds the brief, facts and cards from local files (the project folder, the local Notion mirror, earlier calls) and the public web links in Call context.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onAppear { runner.refreshAuth() }
            Section {
                ModelPicker(title: "Classify", selection: $model.config.models.classify, choices: model.modelChoices).help("Decides if a tip is needed. Runs often: fast and cheap. Recommended: Haiku.")
                ModelPicker(title: "Tip", selection: $model.config.models.tip, choices: model.modelChoices).help("Writes the tip you see. Recommended: Sonnet. Opus is too slow for live tips.")
                ModelPicker(title: "After the call", selection: $model.config.models.analysis, choices: model.modelChoices).help("Summary and analysis. Not time-critical. Recommended: Opus.")
                Toggle("Answer questions to anyone, not only to me", isOn: $model.config.answerAny)
                    .help("A question asked to anyone on the call gets a tip when your brief, facts or the project's Current State hold an answer you could give or add. Off: only questions to you by name.")
                Toggle("Second request when Claude is slow", isOn: $model.config.hedgeEnabled)
                    .help("If Claude shows no answer after 2 s (classify) or 3 s (tip), or fails at once, the same request is sent again and the first good answer wins. Faster tips on busy hours; costs a little more (both requests are billed and counted in the limits).")
                Toggle("Rate tips after each call (blind judge, about $0.10)", isOn: $model.config.judgeAfterCall)
                    .help("After the call Claude Sonnet scores up to 25 tips of the app and of the skill from the transcript, in the background. Results: <call>.judge/judge.summary.json next to the transcript.")
                if !CallEngine.shared.judgeResult.isEmpty {
                    Text(CallEngine.shared.judgeResult).font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Models") } footer: {
                Text(model.config.knownModels.isEmpty ? "Test the Claude key to load the models your key can use." : "Models your key can use.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                TextField("Warning per call", value: $model.config.budget.callSoftUSD, format: .currency(code: "USD"))
                    .help("At this amount in one call the tips window shows a warning. Nothing stops.")
                TextField("Stop per call", value: $model.config.budget.callHardUSD, format: .currency(code: "USD"))
                    .help("At this amount Claude tips stop for the rest of the call. Local facts, cards and HELP NOW keep working.")
                TextField("Stop per month", value: $model.config.budget.monthlyHardUSD, format: .currency(code: "USD"))
                    .help("At this amount Claude tips stay off until the next month. The local layer keeps working.")
            } header: { Text("Spending limits") } footer: {
                Text(String(format: "This month: $%.2f of $%.0f. A typical hour of a call costs $0.10 to $1.20.", SpendLedger.monthSpent(), model.config.budget.monthlyHardUSD))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Local AI (default for new calls)", isOn: $model.config.localAI.enabled)
                    .help("The tips window menu can switch it for one call only. Local models on this Mac: facts and cards by meaning, material for HELP NOW, project search. Off: keywords only.")
                Picker("Engine", selection: $model.config.localAI.engine) {
                    Text("Built-in (recommended)").tag("embedded")
                    Text("Ollama").tag("ollama")
                }
                .disabled(!model.config.localAI.enabled)
                .help("Built-in: nothing else to install. Ollama: your local Ollama server, shared with the Cowork skill.")
                if model.config.localAI.engine == "ollama" {
                    TextField("Ollama URL", text: $model.config.localAI.ollamaURL).disabled(!model.config.localAI.enabled)
                    TextField("Model", text: $model.config.localAI.ollamaModel, prompt: Text("bge-m3"))
                        .disabled(!model.config.localAI.enabled)
                        .help("An embedding model pulled in Ollama. Another model needs a project reindex (lt index --rebuild) and its own thresholds.")
                }
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Image(systemName: model.localAIStatus.ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(model.localAIStatus.ok ? .green : .orange)
                        Text(model.localAIStatus.text).font(.caption).foregroundStyle(.secondary)
                        Button("Check") { model.refreshLocalAI() }.controlSize(.small)
                    }
                }
                DisclosureGroup("About the engines") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("**Built-in.** bge-m3 by BAAI (open model, MIT license), a multilingual text embedding model: it turns a line of the call or a piece of a project file into numbers so that texts with the same meaning sit close, in Ukrainian, English and Spanish alike. Live Tips runs the int8 ONNX build (Xenova/bge-m3 on Hugging Face, about 570 MB) with ONNX Runtime on the CPU of this Mac: about 25 ms per line, about 1 s to start. The model lives in <app folder>/models/bge-m3-int8. Text never leaves the Mac.")
                        Text("**Ollama.** If you already run Ollama (ollama.com) for the Cowork skill, Live Tips can use the same server: `ollama pull bge-m3`, then choose Ollama here. Both engines give the same search results on the existing project index (checked: the same top result on 8 of 8 test queries), so switching needs no reindex.")
                        Text("**Another model.** Any embedding model from the Ollama library (for example multilingual-e5 or nomic-embed-text): `ollama pull <name>`, put the name into Model, then rebuild each project index with `lt index <project folder> --rebuild`. Thresholds in rules/semantic.yaml are tuned for bge-m3, so check them on a recorded call before trusting a new model. Other built-in models (any ONNX export with tokenizer.json) are planned; for now the built-in engine is bge-m3 only.")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } header: { Text("Local AI") } footer: {
                Text("Audio and voice prints never leave the Mac; only text goes to the Claude API.").font(.caption).foregroundStyle(.secondary)
            }
            .onChange(of: model.config.localAI) { LocalAIService.shared.apply(); model.refreshLocalAI(after: 2) }
            .onAppear { model.refreshLocalAI() }
            Section {
                Toggle("Identify speakers", isOn: $model.config.speakersEnabled)
                    .help("Tells the voices on the other side apart (Speaker 2, Speaker 3) and asks \"Who is speaking?\" once a new voice talked for a few seconds. Names you give are used in tips and in the summary, and are remembered for the next calls.")
                    .onChange(of: model.config.speakersEnabled) { LocalAIService.shared.apply() }
                LabeledContent("Status") {
                    let st = LocalAIService.shared.speakersLine()
                    HStack(spacing: 6) {
                        Image(systemName: st.ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(st.ok ? .green : (model.config.speakersEnabled ? .orange : .secondary))
                        Text(st.text).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Voice library") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: (CallEngine.shared.appRoot as NSString).appendingPathComponent("voices")))
                        }.controlSize(.small)
                    }
                }
                DisclosureGroup("Voice library (\(model.voices.count))") {
                    if model.voices.isEmpty { Text("Nobody yet. Names you give on calls appear here.").font(.caption).foregroundStyle(.secondary) }
                    ForEach(model.voices) { v in
                        HStack {
                            Text(v.name)
                            Spacer()
                            Menu(SettingsModel.scopeLabel(v.scope)) {
                                ForEach(model.voiceScopes, id: \.tag) { sc in
                                    Button { model.setVoiceScope(v.name, sc.tag) } label: {
                                        if sc.tag == v.scope { Label(sc.label, systemImage: "checkmark") } else { Text(sc.label) }
                                    }
                                }
                            }
                            .menuStyle(.borderlessButton).fixedSize().font(.caption)
                            .disabled(CallEngine.shared.isRunning)
                            .help("Where this voice is suggested and recognised: the team (every project), a whole workspace, or one project. Not during a call.")
                            Text("\(v.calls) call\(v.calls == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                            Button("Forget") { model.forgetVoice(v.name) }.controlSize(.small).disabled(CallEngine.shared.isRunning)
                                .help("Removes this person's voice prints from the Mac. Not during a call.")
                        }
                    }
                }
                .onAppear { model.loadVoices() }
            } header: { Text("Speakers") } footer: {
                Text("In the tips window: the \"Who is speaking?\" card (pick a name from the project's people, type one, or Skip) and the 🗣 chip under the top bar to rename, fix one line or merge two voices. A voice named on a meeting series is named by itself on the next call of that series when it matches well (Clear speakers in the window forgets it). Your team (the team table of a project config) is remembered for every project, a client for that project only; the menu next to each person moves them to the team, a whole workspace or another project. Nothing is saved on a call marked Public in Start call. Voice prints stay in <app folder>/voices on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    var projects: some View {
        Form {
            Section {
                HStack {
                    Button("Scan work folder") { model.scanFolders() }
                        .disabled(model.config.workRoot.isEmpty)
                        .help("Adds the project folders of your workspaces. Folders that only look like workspaces are listed below to add or ignore; nothing else is added by itself.")
                    Menu("Add") {
                        Button("Project folder…") { model.addProjectFolder() }
                        Button("Workspace folder…") { model.addWorkspaceFolder() }
                        Divider()
                        Button("Import Control Tower configs…") { model.importProjects() }
                    }
                    .fixedSize()
                    Button { showProjectsInfo.toggle() } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.borderless)
                        .popover(isPresented: $showProjectsInfo, arrowEdge: .bottom) { projectsInfo }
                    Spacer()
                    Button("Reindex all") { IndexService.shared.reindexAll() }
                        .help("Rebuild the search index of every project with Index on (in the background, paused during calls).")
                }
                if model.config.workRoot.isEmpty {
                    Text("Set the work folder in General first.").font(.caption).foregroundStyle(.orange)
                }
                if !model.note.isEmpty { Text(model.note).font(.caption).foregroundStyle(.secondary) }
            }
            let cands = model.folderCandidates
            if !cands.isEmpty {
                Section {
                    ForEach(cands, id: \.dir) { c in
                        HStack {
                            Image(systemName: "folder.badge.questionmark").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text((c.dir as NSString).lastPathComponent)
                                Text("\(c.projects) folder\(c.projects == 1 ? "" : "s") inside").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Add as workspace") { model.addWorkspace(c.dir) }
                            Button("Ignore") { model.ignoreFolder(c.dir) }
                        }
                    }
                } header: { Text("Found in your work folder") } footer: {
                    Text("A workspace's subfolders become its projects. Ignore keeps a folder out of every scan.").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(model.registry.workspaces, id: \.name) { w in
                Section {
                    let members = model.registry.projects.filter { w.projects.contains($0.slug) }
                    if members.isEmpty { Text("No projects yet: Scan work folder.").font(.caption).foregroundStyle(.secondary) }
                    ForEach(members, id: \.slug) { p in projectRow(p.slug) }
                } header: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.stack.3d.up")
                        Text(w.name)
                        if model.workspaceHasNotion(w) { Text("Notion").font(.caption2).padding(.horizontal, 5).background(Capsule().fill(Color.secondary.opacity(0.15))) }
                        Spacer()
                        Text("calls: " + (w.root as NSString).lastPathComponent).font(.caption).foregroundStyle(.secondary)
                        Menu {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: w.root)]) }
                            Button("Remove workspace from Live Tips", role: .destructive) { model.removeWorkspace(w) }
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
                } header: { Text(model.registry.workspaces.isEmpty ? "Projects" : "Other projects") }
            }
            if model.registry.projects.isEmpty && model.registry.workspaces.isEmpty && cands.isEmpty {
                Section {
                    Text("No projects yet. Scan the work folder, or add a project folder. Any folder works; Notion is not needed.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// 2026-10-27 (owner): plain words instead of the long text on top of the tab.
    var projectsInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How projects work").font(.headline)
            Text("Each project is a folder on your Mac: work folder > workspace > project. Calls, preparations and notes are saved in the project folder.")
            Text("Tick a project to see it in Start call. Untick a project that is over; nothing is deleted.")
            Text("⋯ removes a project or a whole workspace from Live Tips. The folders stay on your Mac; Scan work folder or Add brings them back.")
            Text("A Control Tower config or a Notion copy are optional: they add the team, Notion pages and the project's current state.")
        }
        .font(.callout).fixedSize(horizontal: false, vertical: true)
        .padding(16).frame(width: 380)
    }

    func projectMenu(_ i: Int) -> some View {
        let p = model.registry.projects[i]
        return Menu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p.root)]) }.disabled(p.root.isEmpty)
            Divider()
            // Both on by default; kept here for a project whose call text must not leave the Mac.
            Toggle("Use Claude for tips", isOn: $model.registry.projects[i].apiAllowed)
            Toggle("Search this folder", isOn: $model.registry.projects[i].index.enabled)
            Button("Reindex now") { IndexService.shared.reindex(p.root) }.disabled(!p.index.enabled)
            Divider()
            Button("Remove project from Live Tips", role: .destructive) { model.excludeProject(p.slug) }
        } label: { Image(systemName: "ellipsis.circle") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Show in Finder, remove from Live Tips")
    }

    @ViewBuilder func projectRow(_ slug: String) -> some View {
        if let i = model.registry.projects.firstIndex(where: { $0.slug == slug }) {
            let p = model.registry.projects[i]
            HStack(alignment: .center) {
                Toggle("", isOn: Binding(get: { model.registry.projects[i].status != "archived" },
                                         set: { model.registry.projects[i].status = $0 ? "active" : "archived" }))
                    .toggleStyle(.checkbox).labelsHidden()
                    .help("Active: offered in Start call. Untick a project that is over; its folder and calls stay.")
                Image(systemName: "folder").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(p.name).foregroundStyle(p.status == "archived" ? .secondary : .primary)
                        if !p.config.isEmpty {
                            Text("config").font(.caption2).padding(.horizontal, 5).background(Capsule().fill(Color.secondary.opacity(0.15)))
                                .help("People, Notion pages and settings come from " + p.config)
                        }
                    }
                    Text(p.root.isEmpty ? "No folder" : p.root).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                projectMenu(i)
            }
            .contextMenu {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p.root)]) }.disabled(p.root.isEmpty)
                Button("Reindex now") { IndexService.shared.reindex(p.root) }.disabled(!p.index.enabled)
                Button("Remove from Live Tips", role: .destructive) { model.excludeProject(p.slug) }
            }
        }
    }

    var general: some View {
        Form {
            if !model.readyItems.allSatisfy(\.ok) {
                Section {
                    ForEach(model.readyItems, id: \.title) { it in
                        HStack {
                            Image(systemName: it.ok ? "checkmark.circle.fill" : "circle").foregroundStyle(it.ok ? Color.green : Color.secondary)
                            Text(it.title)
                            Spacer()
                            if !it.ok, let tab = it.tab { Button(it.action) { model.tab = tab } }
                            else if !it.ok, it.action == "Import…" { Button(it.action) { model.importProjects() } }
                            else if !it.ok { Text(it.action).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                } header: { Text("Get ready for the first call") } footer: {
                    Text("This list disappears when everything is set. The same list is in About.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                FolderRow(title: "Work folder",
                          hint: "The folder you connected to Cowork, where your project folders live. Live Tips keeps its files in <work folder>/Tools/LiveTips (the skill sees them) and reads the Notion mirror from <work folder>/_notion.",
                          path: $model.config.workRoot, placeholder: "~/work", choose: { model.chooseFolder("Choose your work folder") })
                    .onChange(of: model.config.workRoot) { model.refreshMirror(); model.rescanWorkspaces() }
                LabeledContent {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            mirrorLine
                            Spacer()
                            switch NotionMirrorService.mode(workRoot: model.config.workRoot) {
                            case "managed": Button("Sync now") { NotionMirrorService.shared.syncNow(); model.mirrorNote = "Syncing in the background…" }
                            case "none": Button("Set up sync…") { model.setUpMirror() }.disabled(model.config.workRoot.isEmpty)
                            default: EmptyView()
                            }
                            Button("Check") { model.refreshMirror() }
                        }
                        if !model.mirrorNote.isEmpty {
                            Text(model.mirrorNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        } else if NotionMirrorService.mode(workRoot: model.config.workRoot) == "external" {
                            Text("Run by your own schedule (notion-mirror in Tools). Live Tips only reads it.").font(.caption).foregroundStyle(.secondary)
                        } else if NotionMirrorService.mode(workRoot: model.config.workRoot) == "managed" {
                            Text("Live Tips runs it every 2 hours (7:00-22:00), never during a call.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } label: {
                    Text("Notion mirror").help("A read-only copy of your Notion as .md files, refreshed by a background job every 2 hours. Live Tips reads it for facts and search; anything newer comes from the Notion API.")
                }
                LabeledContent("Your name on calls") {
                    TextField("", text: $model.aliasesText, prompt: Text("e.g. Alex, Alexander, Sasha"))
                        .onSubmit { model.saveAliases() }
                        .onChange(of: model.aliasesText) { model.saveAliases() }
                }
                .help("Every form people use when they address you. When the other side says it with a question, you get a red \"your turn\" tip.")
            } header: { Text("Setup") }
            Section {
                Picker("Interface language", selection: $model.config.uiLanguage) {
                    Text("English").tag("en")
                    Text("Українська").tag("uk")
                }
                Toggle("Hide the tips window from screen sharing and screenshots", isOn: $model.config.stealthDefault)
                    .help("Default for new calls. The tips window menu changes it for one call only.")
                Toggle("Show Live Tips in the Dock", isOn: $model.config.showInDock)
                    .onChange(of: model.config.showInDock) { NSApp.setActivationPolicy(model.config.showInDock ? .regular : .accessory) }
                Toggle("Write the call summary to Notion", isOn: $model.config.notionWriteSummary)
                    .help("After the call: updates the meeting's Notion page (or creates one) in your Meetings database. The Cowork skill can do it instead.")
                if model.config.notionWriteSummary {
                    NotionDestinationView()
                    Text("Projects with a Control Tower config write to their own Meetings database; the one chosen here is for every other project.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: { Text("Behaviour") } footer: {
                HStack {
                    Text("Settings save automatically and survive updates: options in Application Support/LiveTips, keys in the Keychain.")
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.config]) }.buttonStyle(.link)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: $model.config.consentSay) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Play an audio consent message")
                        Text("When a recording starts, macOS speaks the message through your speakers, so the others hear it through your microphone.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $model.config.consentChat) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Copy a consent message for the meeting chat")
                        Text("When a recording starts, the message is copied and a notification reminds you to paste it into the chat (Command-V).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.config.consentSay || model.config.consentChat {
                    TextField("English", text: $model.config.consentTextEN, axis: .vertical).lineLimit(2...4)
                    TextField("Українська", text: $model.config.consentTextUK, axis: .vertical).lineLimit(2...4)
                }
            } header: { Text("Recording consent") } footer: {
                Text("Off by default. The message follows the call's language. Check the rules of your company and your clients' countries: in some places everyone must agree to a recording.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("HELP NOW") { Text("⌃⌥H  Control-Option-H").font(.callout.monospaced()) }
                LabeledContent("Pause or resume tips") { Text("⌃⌥P  Control-Option-P").font(.callout.monospaced()) }
            } header: { Text("Shortcuts") } footer: {
                Text("They work from any app during a call, also while the meeting app has the focus. Also in the menu bar menu and on the tips window buttons.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent {
                    HStack {
                        Text(model.config.effectiveAppRoot(appSupport: AppPaths.support.path))
                            .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose…") { if let p = model.chooseFolder("Choose the app folder") { model.config.appRoot = p } }
                        if !model.config.appRoot.isEmpty { Button("Default") { model.config.appRoot = "" } }
                    }
                } label: {
                    Text("App folder").help("Where the app keeps its recorder core, local AI model, state and logs. Default: <work folder>/Tools/LiveTips. When it changes, the files move there by themselves (not during a call).")
                }
            } header: { Text("Advanced") }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder var mirrorLine: some View {
        switch model.mirrorHealth {
        case "ok": Label(model.mirrorLastRunText, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case "stale": Label("Stale: " + model.mirrorLastRunText, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case "failed": Label("Last run failed", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        default: Label(model.config.workRoot.isEmpty ? "Set the work folder first" : "No mirror found (sync not set up)", systemImage: "circle.dashed").foregroundStyle(.secondary)
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
                        box("Your mic + call audio", "captured on the Mac", .gray)
                        arrow
                        box("Whisper", "speech to text on the Mac", .gray)
                        arrow
                        box("Transcript", "with speaker names", .gray)
                    }
                    Image(systemName: "arrow.down").foregroundStyle(.secondary)
                    HStack(alignment: .top, spacing: 10) {
                        box("On the Mac, 1-2 s", "keyword rules, prepared facts and cards; Local AI matches them by meaning", .green)
                        box("Claude, about 5 s", "classifies new lines, writes tips, answers asks and HELP NOW, searches the project folder", .blue)
                    }
                    Image(systemName: "arrow.down").foregroundStyle(.secondary)
                    box("Tips window", "facts, tips, answers, transcript; nothing is sent to anyone", .orange)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            } header: { Text("The flow") }

            Section {
                row("waveform", "Recording", "Your microphone and the call's system audio. Audio never leaves the Mac; the text transcript is written to the project's live folder.")
                row("text.bubble", "Transcription", "Whisper (large-v3-turbo) runs on the Mac in the languages chosen in Start call. Ukrainian only is the default; add English when the call mixes languages.")
                row("person.2.wave.2", "Speakers", "A small voice model on the Mac tells voices apart. You name a voice once in the window; the name is remembered for the next calls of the same meeting series (project + title) and filled in by itself when the voice matches well. \"Clear speakers\" in the window forgets them.")
                row("cpu", "Local AI (optional)", "bge-m3, an embedding model on the Mac, not a chat model. It finds prepared facts and cards by meaning, builds the search index of each project folder (updated after files change, paused during calls) and helps HELP NOW. It never writes tips by itself.")
            } header: { Text("On your Mac") }

            Section {
                row("doc.text.magnifyingglass", "What Claude gets", "Only for projects with Claude tips on: the Cowork preparation (brief, facts, cards, outline), the call context you typed, the project's Current State from the Notion mirror, passages from the project folder found for that context, a digest of recent calls, and the last minutes of the transcript with speaker names. This context is cached for an hour, so each tip costs little.")
                row("bolt", "When Claude is called", "A direct question or request to you, a date, an owner or a number goes straight to a tip; other new lines are checked by a fast model (Haiku) and turned into a tip only when they need one. Your asks in the window, HELP NOW and the folder search always go to Claude.")
                row("list.bullet.rectangle", "Call picture", "Every ~10 s a fast model (Haiku) updates the picture of the call: the topic and whose it is, open questions and requests to you, what you took on, decisions, and which speech points you said. The window shows it as the status line, the On me panel and the speech card; an open question to you that no tip covered gets one red tip.")
                row("folder", "Folder search", "The folder button: Claude turns your question into a few searches, reads the best passages from the project's files (by meaning with Local AI on, by words otherwise) and answers with the file names, in 10-30 s.")
                row("checkmark.seal", "After the call", "A wrap-up goes to the meeting's page in Notion (when the Notion token is set) and a quality check of the tips runs in the background.")
                row("dollarsign.circle", "Limits", "The call and monthly budgets in Settings > AI stop Claude when reached; the Mac part keeps working.")
            } header: { Text("Claude (cloud)") }

            Section {
                row("checkmark.circle", "Count on", "Instant prepared facts; a tip within seconds after a direct question; answers to what you type; the transcript and speaker names saved in the project folder; nothing sent to the client or posted anywhere by itself.")
                row("exclamationmark.triangle", "Do not count on", "Names, numbers and terms heard right every time (check them); similar voices always told apart; short replies tagged; Claude seeing your screen, chats or files outside the project folder; information newer than the last Notion mirror or index update; numbers Claude was not given. A project with Claude off gets only the Mac part.")
            } header: { Text("What to expect") }
        }
        .formStyle(.grouped)
    }

    var arrow: some View { Image(systemName: "arrow.right").foregroundStyle(.secondary) }

    func box(_ title: String, _ sub: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.callout).bold()
            Text(sub).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.4)))
    }

    func row(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).frame(width: 20).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct AboutView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    Text("Live Tips").font(.largeTitle).bold()
                    Text("by PM Control Tower").foregroundStyle(.secondary)
                    Spacer()
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")").foregroundStyle(.secondary)
                }
                Text("A quiet co-pilot for video calls. Live Tips transcribes the call on your Mac and shows a small window with the right fact or a ready phrase when you need it: a direct question to you, a new request, a date or an owner to fix. Prepared facts and cards appear instantly; Claude tips arrive in about 5 seconds. Audio never leaves your Mac.")
                HStack(spacing: 16) {
                    Link("Website", destination: URL(string: "https://tower.bodco.pm")!)
                    Link("GitHub", destination: URL(string: "https://github.com/bodco/pm-control-tower")!)
                    Link("Notion template", destination: URL(string: "https://bodco.notion.site/pm-control-tower")!)
                }
            }
            Section {
                check(isOK(.claudeAPIKey), "Claude API key works", "Keys")
                check(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, "Microphone allowed", "asked on the first call")
                check(!model.registry.projects.isEmpty, "Projects imported", "Projects")
                check(!model.config.workRoot.isEmpty, "Work folder set", "General")
                check(!model.config.nameAliases.isEmpty, "Your name on calls", "General")
                check(model.mirrorHealth == "ok", "Notion mirror is fresh", "General")
                check(model.config.localAI.enabled, "Local AI on", "AI")
            } header: { Text("Ready for a call") } footer: {
                Text("Before a call: click Live Tips in the Dock or the menu bar > Start call, choose the project or workspace, Start. The tips window opens under your camera. During the call: Control-Option-H is HELP NOW, Control-Option-P pauses tips.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    func isOK(_ k: SecretStore.Key) -> Bool {
        if case .ok = model.keyState[k] ?? .notSet { return true }
        return false
    }

    func check(_ ok: Bool, _ title: String, _ whereTo: String) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle").foregroundStyle(ok ? Color.green : Color.secondary)
            Text(title)
            Spacer()
            if !ok { Text(whereTo).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

@MainActor
final class SettingsWindow {
    static var window: NSWindow?
    static let model = SettingsModel()

    static func title(for tab: String) -> String {
        ["general": "General", "keys": "Keys", "projects": "Projects", "ai": "AI", "how": "How Live Tips works", "about": "About Live Tips"][tab] ?? "Settings"
    }

    static func show(tab: String = "general") {
        model.tab = tab
        window?.title = title(for: tab)
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            w.title = title(for: tab)
            w.setContentSize(NSSize(width: 960, height: 660))
            w.isReleasedWhenClosed = false
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
