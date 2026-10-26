import AppKit
import AVFoundation
import LiveTipsCore
import SwiftUI

/// First-run onboarding (2026-10-26, owner: "like Fireflies"): one window, one question per screen,
/// a progress line on top, Back and Continue. Everything here can be changed later in Settings.
/// Notion is an optional step: Live Tips works with plain folders.
@MainActor
final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable { case welcome, permissions, folder, projects, name, claude, notion, install, done }
    @Published var step: Step = .welcome
    @Published var micState = AVCaptureDevice.authorizationStatus(for: .audio)
    /// true granted, false denied, nil not asked yet (or macOS does not say).
    @Published var sysAudio: Bool? = SystemAudioPermission.granted()
    @Published var apiKey = ""
    @Published var notionToken = ""
    @Published var keyNote = ""
    @Published var notionNote = ""
    @Published var picked: Set<String> = []
    let settings = SettingsWindow.model
    let setup = SetupWindow.model

    var progress: Double { Double(step.rawValue) / Double(Step.allCases.count - 1) }

    func next() { if let s = Step(rawValue: step.rawValue + 1) { step = s } }
    func back() { if let s = Step(rawValue: step.rawValue - 1) { step = s } }

    func askMic() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async { self.micState = AVCaptureDevice.authorizationStatus(for: .audio) }
        }
    }

    func refreshPermissions() {
        micState = AVCaptureDevice.authorizationStatus(for: .audio)
        sysAudio = SystemAudioPermission.granted()
    }

    /// Asks macOS now (the same prompt as on the first call); when it was refused, opens System Settings.
    func askSystemAudio() {
        if sysAudio == false || !SystemAudioPermission.request({ _ in self.refreshPermissions() }) { openSystemAudioSettings() }
    }

    func openSystemAudioSettings() {
        for s in ["x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
                  "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"] {
            if let u = URL(string: s), NSWorkspace.shared.open(u) { break }
        }
    }

    func defaultWorkFolder() {
        guard settings.config.workRoot.isEmpty else { return }
        let w = (NSHomeDirectory() as NSString).appendingPathComponent("work")
        if FileManager.default.fileExists(atPath: w) { settings.config.workRoot = "~/work" }
    }

    func chooseWorkFolder() {
        if let d = settings.chooseFolder("Choose your work folder: one folder per workspace inside, one per project inside those") {
            settings.config.workRoot = d.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            picked = []
        }
    }

    /// Adds the picked candidate workspaces, then scans: projects become every subfolder of a workspace.
    func applyFolders() {
        for d in picked { settings.addWorkspace(d) }
        settings.scanFolders()
    }

    func saveKey() {
        let v = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        settings.save(.claudeAPIKey, v)
        apiKey = ""
        keyNote = "Saved in the Keychain, checking…"
    }

    func saveNotion() {
        let v = notionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        settings.save(.notionToken, v)
        notionToken = ""
        notionNote = "Saved in the Keychain, checking…"
    }
}

struct OnboardingView: View {
    @ObservedObject var m: OnboardingModel
    @ObservedObject var settings: SettingsModel
    @ObservedObject var setup: SetupModel
    var close: () -> Void

    init(m: OnboardingModel, close: @escaping () -> Void) {
        self.m = m; self.settings = m.settings; self.setup = m.setup; self.close = close
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.secondary.opacity(0.15))
                    Rectangle().fill(Color.accentColor).frame(width: g.size.width * m.progress)
                }
            }
            .frame(height: 3)
            .animation(.easeInOut(duration: 0.25), value: m.step)
            VStack(spacing: 18) {
                HStack {
                    if m.step != .welcome && m.step != .done {
                        Button { m.back() } label: { Image(systemName: "arrow.left") }.buttonStyle(.borderless)
                    }
                    Spacer()
                    if m.step != .done { Button("Skip setup") { close() }.buttonStyle(.borderless).foregroundStyle(.secondary) }
                }
                IconTile(symbol: icon, image: logo)
                Text(title).font(.title.weight(.semibold)).multilineTextAlignment(.center)
                Text(subtitle).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 520)
                content.frame(maxWidth: 560)
                Spacer(minLength: 0)
                Button { primary() } label: {
                    HStack { Text(primaryLabel); Image(systemName: "arrow.right") }.frame(minWidth: 220)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large).keyboardShortcut(.defaultAction)
                Text("You can change this any time in Settings").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 40).padding(.vertical, 24)
        }
        .frame(width: 760, height: 680)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            if m.step == .permissions { m.refreshPermissions() }
        }
        .onChange(of: m.step) {
            if m.step == .permissions { m.refreshPermissions() }
            if m.step == .notion && settings.isSet(.notionToken) && settings.config.notionMeetingsDB.isEmpty && !NotionDestinationModel.shared.searched { NotionDestinationModel.shared.find() }
            if m.step == .folder { m.defaultWorkFolder() }
            if m.step == .install { Task { await setup.checkAll() } }
        }
    }

    /// The installed Claude or Notion app's own icon on their screens.
    var logo: NSImage? {
        switch m.step {
        case .claude: return AppLogo.claude
        case .notion: return AppLogo.notion
        default: return nil
        }
    }

    var icon: String {
        switch m.step {
        case .welcome: return "text.bubble"
        case .permissions: return "mic"
        case .folder: return "folder"
        case .name: return "person.wave.2"
        case .claude: return "sparkles"
        case .install: return "arrow.down.circle"
        case .notion: return "doc.text"
        case .projects: return "checklist"
        case .done: return "checkmark.circle"
        }
    }

    var title: String {
        switch m.step {
        case .welcome: return "A quiet co-pilot for your calls"
        case .permissions: return "Allow access to capture your calls"
        case .folder: return "Where your projects live"
        case .projects: return "Which projects are active"
        case .name: return "How people call you"
        case .claude: return "Connect Claude"
        case .install: return "Install speech recognition"
        case .notion: return "Connect Notion (optional)"
        case .done: return "You are ready"
        }
    }

    var subtitle: String {
        switch m.step {
        case .welcome: return "Live Tips listens to your call on this Mac and shows the right fact or a ready sentence when you need it: a question to you, your turn, a new request. Audio never leaves your Mac."
        case .permissions: return "Your voice comes from the microphone, the other side from the call's system audio. Both are transcribed on this Mac."
        case .projects: return "Calls can be started only for active projects. Untick the folders that are done or not projects; you can turn them back on in Settings > Projects."
        case .folder: return "Live Tips works with plain folders: a work folder, a folder per workspace inside it, a folder per project inside those. Calls, preparations and notes are saved in each project's folder."
        case .name: return "So Live Tips knows when a question is for you. Add the names and short forms people use on calls."
        case .claude: return "Tips, answers and the call picture come from Claude with your own API key, about $0.3-0.8 per call. Without a key Live Tips still records, transcribes and shows prepared facts."
        case .install: return "Speech recognition and a small local AI model run on this Mac (about 2.5 GB, no administrator password)."
        case .notion: return "After each call Live Tips adds a page to a Notion database: a short summary, decisions, action items, open questions and the transcript. Without Notion the same notes stay in the project folder."
        case .done: return "Before a call: Live Tips in the menu bar > Start call, pick the project, Start. During the call: Control-Option-H is HELP NOW, Control-Option-P pauses tips."
        }
    }

    @ViewBuilder var content: some View {
        switch m.step {
        case .welcome:
            VStack(spacing: 10) {
                row("waveform", "Records and transcribes on your Mac", "Whisper runs locally; only text goes to Claude.")
                row("rectangle.on.rectangle", "A small window next to your call", "Facts, a ready phrase, what is on you, your speech.")
                row("doc.badge.clock", "Prepared before the call", "A brief from your project folder in a few minutes.")
            }
        case .permissions:
            VStack(spacing: 10) {
                permissionRow("mic", "Transcribe your voice", ok: m.micState == .authorized,
                              button: m.micState == .denied ? "Open Settings" : "Allow microphone") {
                    if m.micState == .denied {
                        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(u) }
                    } else { m.askMic() }
                }
                permissionRow("speaker.wave.2", "Capture the other side of the call", ok: m.sysAudio == true,
                              button: m.sysAudio == false ? "Open Settings" : "Allow audio access",
                              note: m.sysAudio == false ? "Turn on Live Tips under Privacy & Security > Screen & System Audio Recording." : "") {
                    m.askSystemAudio()
                }
            }
        case .folder:
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(settings.config.workRoot.isEmpty ? "No work folder yet" : settings.config.workRoot).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(settings.config.workRoot.isEmpty ? "Choose…" : "Change…") { m.chooseWorkFolder() }
                }
                .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
                let marked = settings.config.workRoot.isEmpty ? [] : WorkspaceScanner.scanFolders(workRoot: settings.config.workRoot,
                                                                                                    extra: settings.registry.extraWorkspaces,
                                                                                                    excluded: settings.registry.excluded).workspaces
                let cands = settings.folderCandidates
                if !marked.isEmpty || !cands.isEmpty {
                    Text("Workspaces").font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(marked, id: \.self) { d in
                                Label((d as NSString).lastPathComponent + "  ·  Notion", systemImage: "checkmark.square.fill")
                            }
                            ForEach(cands, id: \.dir) { c in
                                Toggle(isOn: Binding(get: { m.picked.contains(c.dir) },
                                                     set: { if $0 { m.picked.insert(c.dir) } else { m.picked.remove(c.dir) } })) {
                                    Text((c.dir as NSString).lastPathComponent + "  ·  \(c.projects) project folder\(c.projects == 1 ? "" : "s")")
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                } else if !settings.config.workRoot.isEmpty {
                    Text("No workspace folders found here yet. You can add project folders later in Settings > Projects.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case .projects:
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(settings.registry.workspaces, id: \.name) { w in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(w.name).font(.caption).foregroundStyle(.secondary)
                            ForEach(settings.registry.projects.filter { w.projects.contains($0.slug) }, id: \.slug) { p in projectToggle(p.slug) }
                        }
                    }
                    let inWs = Set(settings.registry.workspaces.flatMap(\.projects))
                    let others = settings.registry.projects.filter { !inWs.contains($0.slug) }
                    if !others.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Other").font(.caption).foregroundStyle(.secondary)
                            ForEach(others, id: \.slug) { p in projectToggle(p.slug) }
                        }
                    }
                    if settings.registry.projects.isEmpty {
                        Text("No project folders found. Add them later in Settings > Projects.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
        case .name:
            TextField("", text: $settings.aliasesText, prompt: Text("e.g. Alex, Alexander, Sasha"))
                .textFieldStyle(.roundedBorder).controlSize(.large)
                .onChange(of: settings.aliasesText) { settings.saveAliases() }
        case .claude:
            VStack(spacing: 8) {
                HStack {
                    SecureField("", text: $m.apiKey, prompt: Text(settings.isSet(.claudeAPIKey) ? "A key is saved; paste a new one to replace it" : "sk-ant-…"))
                        .textFieldStyle(.roundedBorder)
                    Button("Save") { m.saveKey() }.disabled(m.apiKey.isEmpty)
                }
                keyState(settings.keyState[.claudeAPIKey], fallback: m.keyNote)
                Link("Get a key at console.anthropic.com", destination: URL(string: "https://console.anthropic.com/settings/keys")!).font(.caption)
            }
        case .install:
            VStack(spacing: 6) {
                ForEach(setup.steps) { s in
                    HStack {
                        stateIcon(s.state).frame(width: 18)
                        Text(s.title)
                            Spacer()
                        Text(s.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if setup.busy { ProgressView().controlSize(.small) }
                Text(setup.log.last ?? "").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
        case .notion:
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("1.").foregroundStyle(.secondary)
                    Text("Create an integration: ") + Text("New integration").bold() + Text(", type Internal, then copy its Internal Integration Secret (ntn_…).")
                    Spacer()
                    Link("Open", destination: URL(string: "https://www.notion.so/profile/integrations")!)
                }
                .font(.callout)
                HStack(alignment: .firstTextBaseline) {
                    Text("2.").foregroundStyle(.secondary).font(.callout)
                    Text("Paste it here:").font(.callout)
                }
                HStack {
                    SecureField("", text: $m.notionToken, prompt: Text(settings.isSet(.notionToken) ? "A token is saved" : "ntn_… (an internal integration token)"))
                        .textFieldStyle(.roundedBorder)
                    Button("Save") { m.saveNotion() }.disabled(m.notionToken.isEmpty)
                }
                keyState(settings.keyState[.notionToken], fallback: m.notionNote)
                HStack(alignment: .firstTextBaseline) {
                    Text("3.").foregroundStyle(.secondary)
                    Text("In Notion open the page where meeting notes should live, ") + Text("••• > Connections").bold() + Text(", add your integration. Pages inside it are shared too.")
                }
                .font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top) {
                    Text("4.").foregroundStyle(.secondary).font(.callout)
                    NotionDestinationView(compact: true)
                }
                if settings.isSet(.notionToken) && NotionMirrorService.mode(workRoot: settings.config.workRoot) == "none" && settings.registry.projects.contains(where: { !$0.config.isEmpty }) {
                    HStack {
                        Text(settings.mirrorNote.isEmpty ? "Control Tower user: keep a local copy of your Notion for facts and search" : settings.mirrorNote)
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Set up sync") { settings.setUpMirror() }
                            .disabled(settings.config.workRoot.isEmpty || NotionMirrorService.mode(workRoot: settings.config.workRoot) != "none")
                    }
                }
            }
        case .done:
            HStack(spacing: 12) {
                Button("Open the demo window") { (NSApp.delegate as? AppDelegate)?.showDemo() }
                Button("Settings…") { SettingsWindow.show() }
            }
        }
    }

    var primaryLabel: String {
        switch m.step {
        case .install: return setup.allRequiredOK ? "Continue" : (setup.busy ? "Installing…" : "Install all and continue")
        case .claude: return settings.isSet(.claudeAPIKey) ? "Continue" : "Continue without a key"
        case .notion: return settings.config.notionMeetingsDB.isEmpty ? "Skip Notion" : "Continue"
        case .done: return "Start a call"
        default: return "Continue"
        }
    }

    func primary() {
        switch m.step {
        case .folder: m.applyFolders(); m.next()
        case .install:
            if setup.allRequiredOK { m.next() }
            else if !setup.busy { Task { await setup.installMissing(includeOptional: true); if setup.allRequiredOK { m.next() } } }
        case .done:
            UserDefaults.standard.set(true, forKey: "onboardingDone")
            close()
            (NSApp.delegate as? AppDelegate)?.startCall()
        default: m.next()
        }
    }

    func projectToggle(_ slug: String) -> some View {
        Group {
            if let i = settings.registry.projects.firstIndex(where: { $0.slug == slug }) {
                Toggle(isOn: Binding(get: { settings.registry.projects[i].status != "archived" },
                                     set: { settings.registry.projects[i].status = $0 ? "active" : "archived" })) {
                    Text(settings.registry.projects[i].name)
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    func row(_ icon: String, _ t: String, _ d: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) { Text(t).font(.body.weight(.medium)); Text(d).font(.callout).foregroundStyle(.secondary) }
            Spacer()
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    func permissionRow(_ icon: String, _ t: String, ok: Bool, button: String, note: String = "", action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(t)
                if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if ok { Image(systemName: "checkmark").foregroundStyle(.green) } else { Button(button, action: action).buttonStyle(.borderedProminent) }
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    @ViewBuilder func keyState(_ s: KeyState?, fallback: String) -> some View {
        switch s ?? .notSet {
        case .ok(let msg): Label(msg.isEmpty ? "Works" : msg, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        case .failed(let msg): Label(msg, systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.caption)
        case .testing: Label("Checking…", systemImage: "hourglass").foregroundStyle(.secondary).font(.caption)
        default: Text(fallback).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder func stateIcon(_ s: SetupModel.Step.State) -> some View {
        switch s {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .missing: Image(systemName: "circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .checking, .installing: ProgressView().controlSize(.small)
        case .unknown: Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        }
    }
}

@MainActor
final class OnboardingWindow {
    static var window: NSWindow?
    static let model = OnboardingModel()

    static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: OnboardingView(m: model, close: { window?.close() })))
            w.title = "Welcome to Live Tips"
            w.styleMask.remove(.resizable)
            w.isReleasedWhenClosed = false
            window = w
        }
        model.step = .welcome
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
