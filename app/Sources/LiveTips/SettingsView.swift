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
        registry.workspaces = WorkspaceScanner.scan(workRoot: config.workRoot, projects: registry.projects)
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

    var body: some View {
        TabView(selection: $model.tab) {
            general.tag("general").tabItem { Label("General", systemImage: "gearshape") }
            keys.tag("keys").tabItem { Label("Keys", systemImage: "key") }
            projects.tag("projects").tabItem { Label("Projects", systemImage: "folder") }
            ai.tag("ai").tabItem { Label("AI", systemImage: "cpu") }
            AboutView(model: model).tag("about").tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(minWidth: 760, minHeight: 520)
        .onChange(of: model.tab) { SettingsWindow.window?.title = SettingsWindow.title(for: model.tab) }
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
            Section {
                ModelPicker(title: "Classify", selection: $model.config.models.classify, choices: model.modelChoices).help("Decides if a tip is needed. Runs often: fast and cheap. Recommended: Haiku.")
                ModelPicker(title: "Tip", selection: $model.config.models.tip, choices: model.modelChoices).help("Writes the tip you see. Recommended: Sonnet. Opus is too slow for live tips.")
                ModelPicker(title: "After the call", selection: $model.config.models.analysis, choices: model.modelChoices).help("Summary and analysis. Not time-critical. Recommended: Opus.")
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
            } header: { Text("Speakers") } footer: {
                Text("In the tips window: the \"Who is speaking?\" card (pick a name from the project's people, type one, or Skip) and the 🗣 chip under the top bar to rename, fix one line or merge two voices. Names are never set by themselves. Voice prints stay in <app folder>/voices on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    var projects: some View {
        Form {
            if model.registry.projects.isEmpty {
                ContentUnavailableView {
                    Label("No projects yet", systemImage: "folder.badge.plus")
                } description: {
                    Text("Live Tips reads projects from your Control Tower configs (projects/<slug>.md): name, folder, team and client people. Import the folder once; re-import any time to pick up changes.")
                } actions: {
                    Button("Import from Control Tower…") { model.importProjects() }
                }
            } else {
                Section {
                    ForEach($model.registry.projects, id: \.slug) { $p in
                        HStack(alignment: .center) {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name)
                                Text(p.root.isEmpty ? "No folder in the config" : p.root).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("Claude", isOn: $p.apiAllowed).toggleStyle(.checkbox)
                                .help("Send this project's call text to the Claude API. Off: local layer only.")
                            Toggle("Index", isOn: $p.index.enabled).toggleStyle(.checkbox)
                                .help("Search the project folder for HELP NOW and questions. The index updates by itself a minute after files change, never during a call. \(IndexService.shared.results[p.root] ?? "")")
                        }
                        .contextMenu {
                            Button("Reindex now") { IndexService.shared.reindex(p.root) }.disabled(!p.index.enabled)
                            Button("Remove from Live Tips", role: .destructive) { model.removeProject(p.slug) }
                        }
                    }
                } header: {
                    HStack {
                        Text("Projects")
                        Spacer()
                        Button("Reindex all") { IndexService.shared.reindexAll() }
                            .help("Rebuild the search index of every project with Index on (incremental, in the background, paused during calls). Log: <app folder>/logs/index.log")
                        Button("Re-import…") { model.importProjects() }
                    }
                } footer: {
                    Text("Projects come from your Control Tower configs. Re-import updates names, folders and people; your switches stay. To add a project, add its config and re-import. To remove one, right-click it (or archive it in its config). \(model.note)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    if model.registry.workspaces.isEmpty {
                        Text("No workspaces found. Set the work folder in General.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(model.registry.workspaces, id: \.name) { w in
                        HStack {
                            Image(systemName: "square.stack.3d.up").foregroundStyle(.secondary)
                            Text(w.name)
                            Spacer()
                            Text(w.projects.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    HStack {
                        Text("Workspaces")
                        Spacer()
                        Button("Rescan") { model.rescanWorkspaces() }
                    }
                } footer: {
                    Text("A workspace is a folder in your work folder with a Notion mirror (_notion/workspace.md), for general calls about several projects.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
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
            } header: { Text("Behaviour") } footer: {
                HStack {
                    Text("Settings save automatically and survive updates: options in Application Support/LiveTips, keys in the Keychain.")
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.config]) }.buttonStyle(.link)
                }
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
        ["general": "General", "keys": "Keys", "projects": "Projects", "ai": "AI", "about": "About Live Tips"][tab] ?? "Settings"
    }

    static func show(tab: String = "general") {
        model.tab = tab
        window?.title = title(for: tab)
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            w.title = title(for: tab)
            w.setContentSize(NSSize(width: 820, height: 560))
            w.isReleasedWhenClosed = false
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
