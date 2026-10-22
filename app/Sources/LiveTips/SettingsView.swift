import AppKit
import LiveTipsCore
import SwiftUI

enum AppPaths {
    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LiveTips")
    }
    static var config: URL { support.appendingPathComponent("config.json") }
    static var projects: URL { support.appendingPathComponent("projects.json") }
}

@MainActor
final class SettingsModel: ObservableObject {
    @Published var config = AppConfig.load(from: AppPaths.config)
    @Published var registry = ProjectRegistry.load(from: AppPaths.projects)
    @Published var masks: [SecretStore.Key: String] = [:]
    @Published var message = ""
    @Published var secretsFile = ""
    let store = SecretStore(service: Bundle.main.bundleIdentifier ?? "io.github.example.livetips")

    init() { refreshMasks() }

    func refreshMasks() {
        for k in SecretStore.Key.allCases { masks[k] = maskedSecret(store.get(k)) }
    }

    func setSecret(_ key: SecretStore.Key, _ value: String) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        message = store.set(key, v) ? "Saved to Keychain" : "Keychain write failed"
        refreshMasks()
    }

    func removeSecret(_ key: SecretStore.Key) {
        store.remove(key)
        refreshMasks()
    }

    /// Imports values from a dotenv secrets file into the Keychain; the file is not changed.
    func importSecrets(_ mapping: [(String, SecretStore.Key)]) {
        var n = 0
        for (name, key) in mapping {
            if let v = readSecretsFileValue(name, path: secretsFile), store.set(key, v) { n += 1 }
        }
        message = n > 0 ? "Imported \(n) value(s) into Keychain" : "Nothing imported (check the path and variable names)"
        refreshMasks()
    }

    func importProjects() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the folder with Control Tower project configs (projects/*.md)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let found = ProjectConfigImporter.importFolder(url.path)
        registry.merge(imported: found)
        save()
        message = "Imported \(found.count) project(s)"
    }

    func save() {
        do {
            try config.save(to: AppPaths.config)
            try registry.save(to: AppPaths.projects)
        } catch {
            message = "Save failed: \(error.localizedDescription)"
        }
    }
}

struct SecretRow: View {
    let title: String
    let key: SecretStore.Key
    @ObservedObject var model: SettingsModel
    @State private var value = ""

    var body: some View {
        HStack {
            Text(title).frame(width: 150, alignment: .leading)
            SecureField("paste here", text: $value).frame(minWidth: 220)
            Button("Save") { model.setSecret(key, value); value = "" }
            Text(model.masks[key] ?? "not set").foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            Button("Remove") { model.removeSecret(key) }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView {
            Form {
                SecretRow(title: "Claude API key", key: .claudeAPIKey, model: model)
                SecretRow(title: "Workspace ID (optional)", key: .claudeWorkspaceID, model: model)
                SecretRow(title: "Notion token", key: .notionToken, model: model)
                HStack {
                    TextField("secrets.env path (optional import)", text: $model.secretsFile)
                    Button("Import CLAUDE_API / NOTION token") {
                        model.importSecrets([("CLAUDE_API", .claudeAPIKey), ("CLAUDE_WORKSPACE_ID", .claudeWorkspaceID),
                                             ("NOTION_TOKEN", .notionToken)])
                    }
                }
                Text("Keys are stored only in the macOS Keychain and never written to files or logs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding().tabItem { Text("Keys") }

            Form {
                TextField("classify", text: $model.config.models.classify)
                TextField("tip", text: $model.config.models.tip)
                TextField("analysis (after the call)", text: $model.config.models.analysis)
                TextField("Soft limit per call, USD", value: $model.config.budget.callSoftUSD, format: .number)
                TextField("Hard limit per call, USD", value: $model.config.budget.callHardUSD, format: .number)
                TextField("Hard limit per month, USD", value: $model.config.budget.monthlyHardUSD, format: .number)
            }
            .padding().tabItem { Text("Models and limits") }

            Form {
                Toggle("Local AI (local models: embeddings, project index)", isOn: $model.config.localAI.enabled)
                Picker("Engine", selection: $model.config.localAI.engine) {
                    Text("Built-in (bge-m3 int8)").tag("embedded")
                    Text("Ollama").tag("ollama")
                }
                .disabled(!model.config.localAI.enabled)
                TextField("Ollama URL", text: $model.config.localAI.ollamaURL)
                    .disabled(!model.config.localAI.enabled || model.config.localAI.engine != "ollama")
                Text("Off: no local model calls and no indexing; matching falls back to keywords.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding().tabItem { Text("Local AI") }

            VStack(alignment: .leading) {
                HStack {
                    Button("Import from Control Tower…") { model.importProjects() }
                    Text("\(model.registry.projects.count) project(s)").foregroundStyle(.secondary)
                }
                List {
                    ForEach($model.registry.projects, id: \.slug) { $p in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(p.name)  (\(p.slug))").bold()
                            Text(p.root.isEmpty ? "root: not set" : p.root).font(.caption).foregroundStyle(.secondary)
                            Toggle("Allowed to send call text to the model API", isOn: $p.apiAllowed)
                            Toggle("Project index", isOn: $p.index.enabled)
                        }
                    }
                }
            }
            .padding().tabItem { Text("Projects") }

            Form {
                Picker("Interface language", selection: $model.config.uiLanguage) {
                    Text("English").tag("en")
                    Text("Українська").tag("uk")
                }
                Toggle("Hide the tips window from screen sharing and screenshots", isOn: $model.config.stealthDefault)
                Toggle("Write the call summary to Notion", isOn: $model.config.notionWriteSummary)
                TextField("Local Notion mirror folder", text: $model.config.notionMirrorPath)
                TextField("App folder (control and state, visible to the skill)", text: $model.config.appRoot)
            }
            .padding().tabItem { Text("General") }
        }
        .frame(minWidth: 720, minHeight: 420)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(model.message).foregroundStyle(.secondary)
                Spacer()
                Button("Save") { model.save(); model.message = "Saved" }.keyboardShortcut("s")
            }
            .padding(10)
        }
    }
}

@MainActor
final class SettingsWindow {
    static var window: NSWindow?
    static let model = SettingsModel()

    static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            w.title = "LiveTips Settings"
            w.setContentSize(NSSize(width: 760, height: 480))
            w.isReleasedWhenClosed = false
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
