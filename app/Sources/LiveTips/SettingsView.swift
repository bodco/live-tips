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
    @Published var tab = "general"
    @Published var aliasesText = ""
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
                let (ok, msg, ids) = await KeyTester.claude(key: v, workspace: store.get(.claudeWorkspaceID))
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

    func saveConfig() { try? config.save(to: AppPaths.config) }
    func saveRegistry() { try? registry.save(to: AppPaths.projects) }
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
                Picker("Classify", selection: $model.config.models.classify) {
                    ForEach(model.modelChoices, id: \.self) { Text($0).tag($0) }
                }.help("Decides if a tip is needed. Runs often: fast and cheap. Recommended: Haiku.")
                Picker("Tip", selection: $model.config.models.tip) {
                    ForEach(model.modelChoices, id: \.self) { Text($0).tag($0) }
                }.help("Writes the tip you see. Recommended: Sonnet. Opus is too slow for live tips.")
                Picker("After the call", selection: $model.config.models.analysis) {
                    ForEach(model.modelChoices, id: \.self) { Text($0).tag($0) }
                }.help("Summary and analysis. Not time-critical. Recommended: Opus.")
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
                Toggle("Local AI", isOn: $model.config.localAI.enabled)
                    .help("Local models on this Mac: facts and cards by meaning, material for HELP NOW, project search. Off: keywords only.")
                Picker("Engine", selection: $model.config.localAI.engine) {
                    Text("Built-in (recommended)").tag("embedded")
                    Text("Ollama").tag("ollama")
                }
                .disabled(!model.config.localAI.enabled)
                .help("Built-in: nothing else to install. Ollama: your local Ollama server with bge-m3, shared with the Cowork skill.")
                if model.config.localAI.engine == "ollama" {
                    TextField("Ollama URL", text: $model.config.localAI.ollamaURL).disabled(!model.config.localAI.enabled)
                }
            } header: { Text("Local AI") } footer: {
                Text("Audio and voice prints never leave the Mac; only text goes to the Claude API.").font(.caption).foregroundStyle(.secondary)
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
                                .help("Search the project folder for HELP NOW and questions.")
                        }
                        .contextMenu { Button("Remove from Live Tips", role: .destructive) { model.removeProject(p.slug) } }
                    }
                } header: {
                    HStack {
                        Text("Projects")
                        Spacer()
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
            Section {
                FolderRow(title: "Work folder",
                          hint: "The folder you connected to Cowork, where your project folders live. Live Tips keeps its files in <work folder>/Tools/LiveTips (the skill sees them) and reads the Notion mirror from <work folder>/_notion.",
                          path: $model.config.workRoot, placeholder: "~/work", choose: { model.chooseFolder("Choose your work folder") })
                    .onChange(of: model.config.workRoot) { model.refreshMirror(); model.rescanWorkspaces() }
                LabeledContent {
                    HStack {
                        mirrorLine
                        Spacer()
                        Button("Check") { model.refreshMirror() }
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
                FolderRow(title: "App folder",
                          hint: "Leave empty. Default: <work folder>/Tools/LiveTips. Change only if the skill should look for the app's status elsewhere.",
                          path: $model.config.appRoot, placeholder: "default", choose: { model.chooseFolder("Choose the app folder") })
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
                Text("Before a call: click Live Tips in the Dock or the menu bar > Start call, choose the project or workspace, Start. The tips window opens under your camera.")
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

    static func show(tab: String = "general") {
        model.tab = tab
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            w.title = "Live Tips Settings"
            w.setContentSize(NSSize(width: 820, height: 560))
            w.isReleasedWhenClosed = false
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
