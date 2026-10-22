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
    @Published var config = AppConfig.load(from: AppPaths.config) { didSet { if config != oldValue { saveConfig() } } }
    @Published var registry = ProjectRegistry.load(from: AppPaths.projects) { didSet { if registry != oldValue { saveRegistry() } } }
    @Published var keyState: [SecretStore.Key: KeyState] = [:]
    @Published var masks: [SecretStore.Key: String] = [:]
    @Published var mirror = MirrorStatus(result: "", lastRunUTC: nil, pages: nil, mode: "")
    @Published var note = ""
    let store = SecretStore(service: Bundle.main.bundleIdentifier ?? "io.github.example.livetips")

    init() {
        for k in [SecretStore.Key.claudeAPIKey, .notionToken] {
            keyState[k] = store.get(k) == nil ? .notSet : .untested
        }
        refreshMasks()
        refreshMirror()
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
                let (ok, msg, ids) = await KeyTester.claude(key: v, workspace: store.get(.claudeWorkspaceID))
                keyState[key] = ok ? .ok(msg) : .failed(msg)
                if ok, !ids.isEmpty { config.knownModels = ids }
            } else {
                let (ok, msg) = await KeyTester.notion(token: v)
                keyState[key] = ok ? .ok(msg) : .failed(msg)
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

    func saveConfig() { try? config.save(to: AppPaths.config) }
    func saveRegistry() { try? registry.save(to: AppPaths.projects) }
}

// MARK: - Small views

struct Hint: View {
    let text: String
    var body: some View {
        Image(systemName: "questionmark.circle").foregroundStyle(.secondary).help(text)
    }
}

struct StateIcon: View {
    let state: KeyState
    var body: some View {
        switch state {
        case .notSet: Image(systemName: "circle.dashed").foregroundStyle(.secondary).help("Not set")
        case .untested: Image(systemName: "circle.fill").foregroundStyle(.yellow).help("Saved, not tested yet")
        case .testing: ProgressView().controlSize(.small)
        case .ok(let m): Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help(m)
        case .failed(let m): Image(systemName: "xmark.octagon.fill").foregroundStyle(.red).help(m)
        }
    }
}

struct KeyRow: View {
    let title: String
    let hint: String
    let key: SecretStore.Key
    @ObservedObject var model: SettingsModel
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(title).frame(width: 130, alignment: .leading)
                Hint(text: hint)
                SecureField("", text: $value).frame(minWidth: 240).onSubmit { model.save(key, value); value = "" }
                Button { model.save(key, value); value = "" } label: { Image(systemName: "square.and.arrow.down") }
                    .help("Save to Keychain").disabled(value.isEmpty)
                Button { model.test(key) } label: { Image(systemName: "bolt.horizontal") }
                    .help("Test with one request").disabled(!model.isSet(key))
                Button(role: .destructive) { model.remove(key) } label: { Image(systemName: "trash") }
                    .help("Remove from Keychain").disabled(!model.isSet(key))
                StateIcon(state: model.keyState[key] ?? .notSet)
                Text(model.masks[key] ?? "").font(.caption).foregroundStyle(.secondary)
            }
            if case .failed(let m) = model.keyState[key] ?? .notSet {
                Text(m).font(.caption).foregroundStyle(.red).padding(.leading, 140)
            } else if case .ok(let m) = model.keyState[key] ?? .notSet {
                Text(m).font(.caption).foregroundStyle(.green).padding(.leading, 140)
            }
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
        HStack {
            Text(title).frame(width: 130, alignment: .leading)
            Hint(text: hint)
            TextField(placeholder, text: $path)
            Button("Browse…") { if let p = choose() { path = p } }
        }
    }
}

// MARK: - Tabs

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView {
            keys.tabItem { Text("Keys") }
            models.tabItem { Text("Models and limits") }
            localAI.tabItem { Text("Local AI") }
            projects.tabItem { Text("Projects") }
            general.tabItem { Text("General") }
            AboutView(model: model).tabItem { Text("About") }
        }
        .padding()
        .frame(minWidth: 760, minHeight: 460)
    }

    var keys: some View {
        VStack(alignment: .leading, spacing: 14) {
            KeyRow(title: "Claude API key", hint: "From console.anthropic.com > API keys. Used for model tips during the call and the summary after it. Stored only in the macOS Keychain.", key: .claudeAPIKey, model: model)
            KeyRow(title: "Notion token", hint: "Internal integration token (notion.so/my-integrations). Used to read changes newer than your local mirror and, if enabled, to write the call summary. Stored only in the macOS Keychain.", key: .notionToken, model: model)
            Text("Paste with ⌘V and press Return or the save icon. Each key is checked with one request; a green check means it works.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }

    var models: some View {
        Form {
            Section("Models") {
                Picker("Classify (is a tip needed?)", selection: $model.config.models.classify) {
                    ForEach(model.modelChoices, id: \.self) { Text($0).tag($0) }
                }.help("Fast and cheap; runs often. Recommended: Haiku class.")
                Picker("Tip (the text you see)", selection: $model.config.models.tip) {
                    ForEach(model.modelChoices, id: \.self) { Text($0).tag($0) }
                }.help("Quality matters most here. Recommended: Sonnet class. Opus is too slow for live tips.")
                Picker("After the call (summary, analysis)", selection: $model.config.models.analysis) {
                    ForEach(model.modelChoices, id: \.self) { Text($0).tag($0) }
                }.help("Not time-critical. Recommended: Opus class.")
                Text(model.config.knownModels.isEmpty ? "Test the Claude key to load the models available to it." : "Models available to your key.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Spending limits (USD)") {
                HStack {
                    TextField("Warning per call", value: $model.config.budget.callSoftUSD, format: .number)
                    Hint(text: "When one call reaches this, the tips window shows a warning. Nothing stops.")
                }
                HStack {
                    TextField("Stop per call", value: $model.config.budget.callHardUSD, format: .number)
                    Hint(text: "When one call reaches this, model tips stop for the rest of the call. Local facts, cards and HELP NOW keep working.")
                }
                HStack {
                    TextField("Stop per month", value: $model.config.budget.monthlyHardUSD, format: .number)
                    Hint(text: "When the month reaches this, model tips stay off until the next month. Local layer keeps working.")
                }
                Text(String(format: "This month: $%.2f of $%.0f. A typical hour costs about $0.10 to $1.20.", SpendLedger.monthSpent(), model.config.budget.monthlyHardUSD))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    var localAI: some View {
        Form {
            Toggle("Local AI", isOn: $model.config.localAI.enabled)
                .help("Local models on this Mac: finds facts and cards by meaning, picks material for HELP NOW, searches the project index. Off: keywords only, no local model and no indexing.")
            Picker("Engine", selection: $model.config.localAI.engine) {
                Text("Built-in (recommended)").tag("embedded")
                Text("Ollama").tag("ollama")
            }
            .disabled(!model.config.localAI.enabled)
            .help("Built-in: bge-m3 runs inside Live Tips, nothing else to install. Ollama: uses your local Ollama server with bge-m3, shared with the skill.")
            if model.config.localAI.engine == "ollama" {
                TextField("Ollama URL", text: $model.config.localAI.ollamaURL).disabled(!model.config.localAI.enabled)
            }
            Text("Audio and voice prints never leave the Mac; only text goes to the Claude API.").font(.caption).foregroundStyle(.secondary)
        }
    }

    var projects: some View {
        VStack(alignment: .leading) {
            HStack {
                Button { model.importProjects() } label: { Label("Import from Control Tower…", systemImage: "square.and.arrow.down.on.square") }
                Hint(text: "Pick the folder with your project configs (projects/<slug>.md). Name, folder, team and client people are read from there; switches below are kept on re-import.")
                Button { model.rescanWorkspaces() } label: { Image(systemName: "arrow.clockwise") }.help("Find workspaces in the work folder again")
                Spacer()
                Text(model.note).font(.caption).foregroundStyle(.secondary)
            }
            List {
                if !model.registry.workspaces.isEmpty {
                    Section("Workspaces (general calls about several projects)") {
                        ForEach(model.registry.workspaces, id: \.name) { w in
                            HStack {
                                Image(systemName: "square.stack.3d.up")
                                Text(w.name).bold()
                                Text(w.projects.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Projects") {
                    ForEach($model.registry.projects, id: \.slug) { $p in
                        HStack(alignment: .top) {
                            Image(systemName: "folder")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(p.name)  ·  \(p.slug)").bold()
                                Text(p.root.isEmpty ? "folder not set in the config" : p.root).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle(isOn: $p.apiAllowed) { Image(systemName: "network") }
                                .help("Allowed to send this project's call text to the Claude API. Off: local layer only.")
                            Toggle(isOn: $p.index.enabled) { Image(systemName: "magnifyingglass") }
                                .help("Project index for search and HELP NOW")
                        }
                    }
                }
            }
        }
    }

    var general: some View {
        Form {
            FolderRow(title: "Work folder",
                      hint: "The folder you connected to Cowork (where your project folders live). Live Tips keeps its control files in <work folder>/Tools/LiveTips so the skill can see the app's status, and finds the Notion mirror in <work folder>/_notion.",
                      path: $model.config.workRoot, placeholder: "~/work", choose: { model.chooseFolder("Choose your work folder") })
                .onChange(of: model.config.workRoot) { model.refreshMirror(); model.rescanWorkspaces() }
            HStack {
                Text("Notion mirror").frame(width: 130, alignment: .leading)
                Hint(text: "A read-only copy of your Notion in .md files, refreshed by a background job (every 2 hours). Live Tips reads it for facts and search; changes newer than the last run come from the Notion API.")
                mirrorLine
                Spacer()
                Button { model.refreshMirror() } label: { Image(systemName: "arrow.clockwise") }.help("Check again")
            }
            DisclosureGroup("Advanced") {
                FolderRow(title: "App folder",
                          hint: "Leave empty. Default: <work folder>/Tools/LiveTips. Set only if the skill should look for the app's status somewhere else.",
                          path: $model.config.appRoot, placeholder: "default", choose: { model.chooseFolder("Choose the app folder") })
            }
            Picker("Interface language", selection: $model.config.uiLanguage) {
                Text("English").tag("en")
                Text("Українська").tag("uk")
            }
            Toggle("Hide the tips window from screen sharing and screenshots", isOn: $model.config.stealthDefault)
            Toggle("Show Live Tips in the Dock", isOn: $model.config.showInDock)
                .onChange(of: model.config.showInDock) { NSApp.setActivationPolicy(model.config.showInDock ? .regular : .accessory) }
            Toggle("Write the call summary to Notion", isOn: $model.config.notionWriteSummary)
                .help("After the call: updates the meeting's existing Notion page (or creates one) in your Meetings database. Off by default; the Cowork skill can do it instead.")
            HStack {
                Image(systemName: "externaldrive.badge.checkmark").foregroundStyle(.green)
                Text("Settings are saved automatically and kept across updates: options and projects in Application Support/LiveTips, keys in the macOS Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.config]) }
            }
        }
    }

    @ViewBuilder var mirrorLine: some View {
        let h = model.mirrorHealth
        switch h {
        case "ok":
            Label(lastRunText, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case "stale":
            Label("Stale: " + lastRunText, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case "failed":
            Label("Last run failed", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        default:
            Label(model.config.workRoot.isEmpty ? "Set the work folder first" : "No mirror found (sync not set up)", systemImage: "circle.dashed").foregroundStyle(.secondary)
        }
    }

    var lastRunText: String { model.mirrorLastRunText }
}

struct AboutView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Live Tips").font(.largeTitle).bold()
                    Text("by PM Control Tower").foregroundStyle(.secondary)
                    Spacer()
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")").foregroundStyle(.secondary)
                }
                Text("A quiet co-pilot for video calls. Live Tips transcribes the call on your Mac and shows a small window with the right fact or a ready phrase when you need it: a direct question to you, a new request, a date or an owner to fix. Prepared facts and cards appear instantly; model tips arrive in about 5 seconds. Audio never leaves your Mac.")
                HStack(spacing: 16) {
                    Link("Website", destination: URL(string: "https://tower.bodco.pm")!)
                    Link("GitHub", destination: URL(string: "https://github.com/bodco/pm-control-tower")!)
                    Link("Notion template", destination: URL(string: "https://bodco.notion.site/pm-control-tower")!)
                }
                Divider()
                Text("For the full experience").font(.headline)
                check(model.keyState[.claudeAPIKey].map { if case .ok = $0 { return true } else { return false } } ?? false,
                      "Claude API key works", "Keys tab: paste the key; the check turns green after a test request.")
                check(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                      "Microphone allowed", "macOS asks on the first recording.")
                check(true, "System audio recording", "macOS asks on the first recording (System Audio Recording Only).", unknown: true)
                check(!model.registry.projects.isEmpty, "Projects imported", "Projects tab: Import from Control Tower.")
                check(!model.config.workRoot.isEmpty, "Work folder set", "General tab.")
                check(model.mirrorHealth == "ok", "Notion mirror is fresh", "General tab shows when it last ran.")
                check(model.config.localAI.enabled, "Local AI on", "Local AI tab.")
                check(model.isSet(.notionToken), "Notion token (optional)", "Needed only for the summary in Notion and fresh changes.")
                Text("Before a call: click Live Tips in the menu bar (or the Dock icon) > Start call, pick the project or workspace, and Start. The tips window opens under your camera.")
                    .font(.callout).padding(.top, 6)
            }
            .padding(4)
        }
    }

    func check(_ ok: Bool, _ title: String, _ how: String, unknown: Bool = false) -> some View {
        HStack {
            Image(systemName: unknown ? "questionmark.circle" : (ok ? "checkmark.circle.fill" : "circle"))
                .foregroundStyle(unknown ? Color.secondary : (ok ? Color.green : Color.secondary))
            Text(title)
            if !ok || unknown { Text(how).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

@MainActor
final class SettingsWindow {
    static var window: NSWindow?
    static let model = SettingsModel()

    static func show(tab: Int = 0) {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            w.title = "Live Tips Settings"
            w.setContentSize(NSSize(width: 820, height: 520))
            w.isReleasedWhenClosed = false
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
