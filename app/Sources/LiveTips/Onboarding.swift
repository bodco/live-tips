import AppKit
import AVFoundation
import LiveTipsCore
import SwiftUI

/// First-run onboarding (2026-10-26, owner: "like Fireflies"): one window, one question per screen,
/// a progress line on top, Back and Continue. Everything here can be changed later in Settings.
/// Notion is an optional step: Live Tips works with plain folders.
@MainActor
final class OnboardingModel: ObservableObject {
    // Pacenote 0.8 (F0): a splash with the brand comes first. F4 folds the steps after it into four.
    enum Step: Int, CaseIterable { case splash, welcome, permissions, folder, projects, name, claude, notion, install, done }
    @Published var step: Step = .splash
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
    @ObservedObject var cal = CalendarService.shared
    var close: () -> Void

    init(m: OnboardingModel, close: @escaping () -> Void) {
        self.m = m; self.settings = m.settings; self.setup = m.setup; self.close = close
    }

    var body: some View {
        if m.step == .splash { splash } else { steps }
    }

    var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.8" }

    /// First launch: the icon, the wordmark, the tagline and one button (no Skip).
    var splash: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(nsImage: Brand.appIcon).resizable().interpolation(.high).frame(width: 144, height: 144)
                .accessibilityHidden(true)
            PacenoteWordmark(height: 40).padding(.top, 22)
            Text(L("app.tagline")).font(.system(size: 20)).foregroundStyle(PN.C.text2).padding(.top, 14)
            Spacer()
            Button { m.next() } label: { Text(L("onboarding.splash.cta")).frame(minWidth: 180) }
                .buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
            Text(L("onboarding.splash.hint")).font(PN.Font.caption).foregroundStyle(PN.C.text3).padding(.top, 10)
            Spacer().frame(height: 56)
            Text(L("onboarding.splash.footer", ["version": appVersion])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
        }
        .padding(32)
        .frame(width: 760, height: 680)
        .background(PN.C.bg)
    }

    var steps: some View {
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
                        Button { m.back() } label: { Image(systemName: "arrow.left") }.buttonStyle(.borderless).accessibilityLabel("Back")
                    }
                    Spacer()
                    if m.step != .done { Button(L("onboarding.skip")) { close() }.buttonStyle(.pnTertiary).foregroundStyle(PN.C.text3) }
                }
                if m.step == .done {
                    Image(nsImage: Brand.appIcon).resizable().interpolation(.high).frame(width: 112, height: 112).accessibilityHidden(true)
                } else if let logo = logo {
                    IconTile(symbol: icon, image: logo)
                } else {
                    PacenoteSymbol(height: 44)      // the brand symbol above each step's title
                }
                Text(title).font(.title.weight(.semibold)).multilineTextAlignment(.center)
                Text(subtitle).font(.body).foregroundStyle(PN.C.text3).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 520)
                content.frame(maxWidth: 560)
                Spacer(minLength: 0)
                Button { primary() } label: {
                    HStack { Text(primaryLabel); Image(systemName: "arrow.right") }.frame(minWidth: 220)
                }
                .buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
                Text(L("onboarding.changeLater")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
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
        case .splash, .welcome: return "sparkles"
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
        case .splash: return L("app.name")
        case .welcome: return L("onboarding.welcome.title")
        case .permissions: return L("onboarding.permissions.title")
        case .folder: return L("onboarding.folder.title")
        case .projects: return L("onboarding.projects.title")
        case .name: return L("onboarding.name.title")
        case .claude: return L("onboarding.claude.title")
        case .install: return L("onboarding.install.title")
        case .notion: return L("onboarding.notion.title")
        case .done: return L("onboarding.done.title")
        }
    }

    var subtitle: String {
        switch m.step {
        case .splash: return L("app.tagline")
        case .welcome: return L("onboarding.welcome.body")
        case .permissions: return L("onboarding.permissions.body")
        case .projects: return L("onboarding.projects.body")
        case .folder: return L("onboarding.folder.body")
        case .name: return L("onboarding.name.body")
        case .claude: return L("onboarding.claude.body")
        case .install: return L("onboarding.install.body")
        case .notion: return L("onboarding.notion.body")
        case .done: return L("onboarding.done.body", ["help": HotKeys.shared.combo(.help).display])
        }
    }

    @ViewBuilder var content: some View {
        switch m.step {
        case .splash:
            EmptyView()
        case .welcome:
            VStack(spacing: 10) {
                row("waveform", L("onboarding.welcome.row1.title"), L("onboarding.welcome.row1.body"))
                row("rectangle.on.rectangle", L("onboarding.welcome.row2.title"), L("onboarding.welcome.row2.body"))
                row("doc.badge.clock", L("onboarding.welcome.row3.title"), L("onboarding.welcome.row3.body"))
            }
        case .permissions:
            VStack(spacing: 10) {
                permissionRow("mic", L("onboarding.permissions.mic"), ok: m.micState == .authorized,
                              button: m.micState == .denied ? L("common.openSettings") : L("onboarding.permissions.micButton")) {
                    if m.micState == .denied {
                        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(u) }
                    } else { m.askMic() }
                }
                permissionRow("speaker.wave.2", L("onboarding.permissions.system"), ok: m.sysAudio == true,
                              button: m.sysAudio == false ? L("common.openSettings") : L("onboarding.permissions.systemButton"),
                              note: m.sysAudio == false ? L("onboarding.permissions.systemNote") : "") {
                    m.askSystemAudio()
                }
                // 2026-10-27 (owner): optional; the calls from the calendars appear in Home and Start call.
                permissionRow("calendar", L("onboarding.permissions.calendars"), ok: cal.access == .granted,
                              button: cal.access == .denied ? L("common.openSettings") : L("onboarding.permissions.calendarsButton"),
                              note: L("onboarding.permissions.calendarsNote")) {
                    cal.connect()
                }
            }
        case .folder:
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "folder").foregroundStyle(PN.C.text3)
                    Text(settings.config.workRoot.isEmpty ? L("onboarding.folder.none") : settings.config.workRoot).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button(settings.config.workRoot.isEmpty ? L("onboarding.folder.choose") : L("onboarding.folder.change")) { m.chooseWorkFolder() }
                }
                .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
                let marked = settings.config.workRoot.isEmpty ? [] : WorkspaceScanner.scanFolders(workRoot: settings.config.workRoot,
                                                                                                    extra: settings.registry.extraWorkspaces,
                                                                                                    excluded: settings.registry.excluded).workspaces
                let cands = settings.folderCandidates
                if !marked.isEmpty || !cands.isEmpty {
                    Text(L("onboarding.folder.workspaces")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(marked, id: \.self) { d in
                                Label((d as NSString).lastPathComponent + "  ·  Notion", systemImage: "checkmark.square.fill")
                            }
                            ForEach(cands, id: \.dir) { c in
                                Toggle(isOn: Binding(get: { m.picked.contains(c.dir) },
                                                     set: { if $0 { m.picked.insert(c.dir) } else { m.picked.remove(c.dir) } })) {
                                    Text((c.dir as NSString).lastPathComponent + "  ·  " + L("onboarding.folder.projectFolders", ["n": "\(c.projects)"]))
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                } else if !settings.config.workRoot.isEmpty {
                    Text(L("onboarding.folder.empty"))
                        .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                }
            }
        case .projects:
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(settings.registry.workspaces, id: \.name) { w in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(w.name).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                            ForEach(settings.registry.projects.filter { w.projects.contains($0.slug) }, id: \.slug) { p in projectToggle(p.slug) }
                        }
                    }
                    let inWs = Set(settings.registry.workspaces.flatMap(\.projects))
                    let others = settings.registry.projects.filter { !inWs.contains($0.slug) }
                    if !others.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("onboarding.projects.other")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                            ForEach(others, id: \.slug) { p in projectToggle(p.slug) }
                        }
                    }
                    if settings.registry.projects.isEmpty {
                        Text(L("onboarding.projects.empty")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
        case .name:
            TextField("", text: $settings.aliasesText, prompt: Text(L("onboarding.name.placeholder")))
                .textFieldStyle(.roundedBorder).controlSize(.large)
                .onChange(of: settings.aliasesText) { settings.saveAliases() }
        case .claude:
            VStack(spacing: 8) {
                HStack {
                    SecureField("", text: $m.apiKey, prompt: Text(settings.isSet(.claudeAPIKey) ? L("onboarding.claude.saved") : "sk-ant-…"))
                        .textFieldStyle(.roundedBorder)
                    Button(L("common.save")) { m.saveKey() }.disabled(m.apiKey.isEmpty)
                }
                keyState(settings.keyState[.claudeAPIKey], fallback: m.keyNote)
                Link(L("onboarding.claude.getKey"), destination: URL(string: "https://console.anthropic.com/settings/keys")!).font(PN.Font.caption)
            }
        case .install:
            VStack(spacing: 6) {
                ForEach(setup.steps) { s in
                    HStack {
                        stateIcon(s.state).frame(width: 18)
                        Text(s.title)
                            Spacer()
                        Text(s.detail).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(1)
                    }
                }
                if setup.busy { ProgressView().controlSize(.small) }
                Text(setup.log.last ?? "").font(PN.Font.caption.monospaced()).foregroundStyle(PN.C.text3).lineLimit(1)
            }
            .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
        case .notion:
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("1.").foregroundStyle(PN.C.text3)
                    Text(L("onboarding.notion.step1a")) + Text(L("onboarding.notion.step1b")).bold() + Text(L("onboarding.notion.step1c"))
                    Spacer()
                    Link(L("common.open"), destination: URL(string: "https://www.notion.so/profile/integrations")!)
                }
                .font(.callout)
                HStack(alignment: .firstTextBaseline) {
                    Text("2.").foregroundStyle(PN.C.text3).font(.callout)
                    Text(L("onboarding.notion.step2")).font(.callout)
                }
                HStack {
                    SecureField("", text: $m.notionToken, prompt: Text(settings.isSet(.notionToken) ? L("onboarding.notion.saved") : L("onboarding.notion.placeholder")))
                        .textFieldStyle(.roundedBorder)
                    Button(L("common.save")) { m.saveNotion() }.disabled(m.notionToken.isEmpty)
                }
                keyState(settings.keyState[.notionToken], fallback: m.notionNote)
                HStack(alignment: .firstTextBaseline) {
                    Text("3.").foregroundStyle(PN.C.text3)
                    Text(L("onboarding.notion.step3a")) + Text(L("onboarding.notion.step3b")).bold() + Text(L("onboarding.notion.step3c"))
                }
                .font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top) {
                    Text("4.").foregroundStyle(PN.C.text3).font(.callout)
                    NotionDestinationView(compact: true)
                }
                if settings.isSet(.notionToken) && NotionMirrorService.mode(workRoot: settings.config.workRoot) == "none" && settings.registry.projects.contains(where: { !$0.config.isEmpty }) {
                    HStack {
                        Text(settings.mirrorNote.isEmpty ? L("onboarding.notion.mirror") : settings.mirrorNote)
                            .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                        Spacer()
                        Button(L("onboarding.notion.mirrorButton")) { settings.setUpMirror() }
                            .disabled(settings.config.workRoot.isEmpty || NotionMirrorService.mode(workRoot: settings.config.workRoot) != "none")
                    }
                }
            }
        case .done:
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    Image(nsImage: Brand.menuBarImage(recording: false))
                        .padding(6).background(RoundedRectangle(cornerRadius: 6).fill(PN.C.surface2))
                    Text(L("onboarding.done.menubarHint")).font(PN.Font.body).foregroundStyle(PN.C.text2)
                }
                Button(L("onboarding.done.secondary")) { finish(); (NSApp.delegate as? AppDelegate)?.openHome() }
                    .buttonStyle(.pnSecondary)
            }
        }
    }

    var primaryLabel: String {
        switch m.step {
        case .install: return setup.allRequiredOK ? L("common.continue") : (setup.busy ? L("onboarding.install.running") : L("onboarding.install.all"))
        case .claude: return settings.isSet(.claudeAPIKey) ? L("common.continue") : L("onboarding.claude.continueNoKey")
        case .notion: return settings.config.notionMeetingsDB.isEmpty ? L("onboarding.notion.skip") : L("common.continue")
        case .done: return L("onboarding.done.primary")
        case .splash: return L("onboarding.splash.cta")
        default: return L("common.continue")
        }
    }

    func primary() {
        switch m.step {
        case .folder: m.applyFolders(); m.next()
        case .install:
            if setup.allRequiredOK { m.next() }
            else if !setup.busy { Task { await setup.installMissing(includeOptional: true); if setup.allRequiredOK { m.next() } } }
        case .done:
            finish()
            (NSApp.delegate as? AppDelegate)?.showDemo()     // the tips window on demo data
        default: m.next()
        }
    }

    func finish() {
        UserDefaults.standard.set(true, forKey: "onboardingDone")
        close()
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
            VStack(alignment: .leading, spacing: 2) { Text(t).font(.body.weight(.medium)); Text(d).font(.callout).foregroundStyle(PN.C.text3) }
            Spacer()
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    func permissionRow(_ icon: String, _ t: String, ok: Bool, button: String, note: String = "", action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(t)
                if !note.isEmpty { Text(note).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
            }
            Spacer()
            if ok { Image(systemName: "checkmark").foregroundStyle(PN.C.turn) } else { Button(button, action: action).buttonStyle(.pnSecondary) }
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    @ViewBuilder func keyState(_ s: KeyState?, fallback: String) -> some View {
        switch s ?? .notSet {
        case .ok(let msg): Label(msg.isEmpty ? L("common.works") : msg, systemImage: "checkmark.circle.fill").foregroundStyle(PN.C.turn).font(PN.Font.caption)
        case .failed(let msg): Label(msg, systemImage: "xmark.circle.fill").foregroundStyle(PN.C.danger).font(PN.Font.caption)
        case .testing: Label(L("common.checking"), systemImage: "hourglass").foregroundStyle(PN.C.text3).font(PN.Font.caption)
        default: Text(fallback).font(PN.Font.caption).foregroundStyle(PN.C.text3)
        }
    }

    @ViewBuilder func stateIcon(_ s: SetupModel.Step.State) -> some View {
        switch s {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(PN.C.turn)
        case .missing: Image(systemName: "circle").foregroundStyle(PN.C.text3)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(PN.C.danger)
        case .checking, .installing: ProgressView().controlSize(.small)
        case .unknown: Image(systemName: "circle.dotted").foregroundStyle(PN.C.text3)
        }
    }
}

@MainActor
final class OnboardingWindow {
    static var window: NSWindow?
    static let model = OnboardingModel()

    static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: Localized { OnboardingView(m: model, close: { window?.close() }) }))
            w.title = L("onboarding.window.title")
            w.styleMask.remove(.resizable)
            w.isReleasedWhenClosed = false
            window = w
        }
        model.step = .splash
        window?.title = L("onboarding.window.title")
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
