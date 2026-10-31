import AppKit
import AVFoundation
import LiveTipsCore
import SwiftUI

/// First-run onboarding (2026-10-26, owner: "like Fireflies"): one window, one question per screen,
/// a progress line on top, Back and Continue. Everything here can be changed later in Settings.
/// Notion is an optional step: Live Tips works with plain folders.
@MainActor
final class OnboardingModel: ObservableObject {
    // Pacenote 0.8 (F4, REDESIGN-SPEC 7): the splash, then four steps. Speech recognition installs in the background
    // from the first step; your name, Notion and calendars (if skipped) become Finish setup cards on Home.
    enum Step: Int, CaseIterable { case splash, permissions, folder, claude, addons, done }   // 0.8.6 (E): optional add-ons
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

    func next() { UsageLog.log("onboarding_step", ["step": "\(step)", "skipped": false]); if let s = Step(rawValue: step.rawValue + 1) { step = s } }
    func skip() { UsageLog.log("onboarding_step", ["step": "\(step)", "skipped": true]); if let s = Step(rawValue: step.rawValue + 1) { step = s } }
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
        if let d = settings.chooseFolder(L("onboarding.folder.chooseMessage")) {
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
        keyNote = L("onboarding.keySaved")
    }

    func saveNotion() {
        let v = notionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        settings.save(.notionToken, v)
        notionToken = ""
        notionNote = L("onboarding.keySaved")
    }
}

struct OnboardingView: View {
    @ObservedObject var m: OnboardingModel
    @State private var tree: [String] = []      // 0.8.7 (L3): the tree made by "Create the structure for me"
    @State private var keyOpen = false
    @ObservedObject var settings: SettingsModel
    @ObservedObject var setup: SetupModel
    @ObservedObject var cal = CalendarService.shared
    @ObservedObject var sig = AppSignature.shared
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
                    Rectangle().fill(PN.C.surface2)
                    Rectangle().fill(PN.C.accentFill).frame(width: g.size.width * m.progress)
                }
            }
            .frame(height: 3)
            .animation(.easeInOut(duration: 0.25), value: m.step)
            VStack(spacing: 18) {
                HStack {
                    if m.step != .permissions && m.step != .done {
                        Button { m.back() } label: { Image(systemName: "arrow.left") }.buttonStyle(.borderless).accessibilityLabel(L("onboarding.back"))
                    }
                    Spacer()
                    if m.step != .done { Button(L("onboarding.skip")) { close() }.buttonStyle(.pnTertiary) }
                }
                if m.step == .done {
                    Image(nsImage: Brand.appIcon).resizable().interpolation(.high).frame(width: 112, height: 112).accessibilityHidden(true)
                } else if let logo = logo {
                    IconTile(symbol: "sparkles", image: logo)
                } else {
                    PacenoteSymbol(height: 44)      // the brand symbol above each step's title
                }
                Text(title).font(.title.weight(.semibold)).multilineTextAlignment(.center).foregroundStyle(PN.C.text)
                Text(subtitle).font(.body).foregroundStyle(PN.C.text2).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 520)
                content.frame(maxWidth: 560)
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    if m.step == .done {
                        Button(L("onboarding.done.secondary")) { finish(); (NSApp.delegate as? AppDelegate)?.openHome() }.buttonStyle(.pnSecondary)
                    }
                    if m.step != .addons {          // the add-ons step has its own Install selected and Skip
                        Button { primary() } label: { Text(primaryLabel).frame(minWidth: 180) }
                            .buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
                    }
                }
                installFooter
            }
            .padding(.horizontal, 40).padding(.vertical, 24)
        }
        .frame(width: 760, height: 680)
        .background(PN.C.bg)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            if m.step == .permissions { m.refreshPermissions() }
        }
        .onChange(of: m.step) {
            if m.step == .permissions { m.refreshPermissions(); installInBackground() }
            if m.step == .folder { m.defaultWorkFolder() }
        }
    }

    /// Speech recognition and the local AI model install while the PM goes through the steps (spec 7).
    func installInBackground() {
        guard !setup.busy else { return }
        Task {
            await setup.checkAll()
            if !setup.allRequiredOK { await setup.installMissing(includeOptional: false) }   // Claude Code: only on Install
        }
    }

    /// One line of progress at the bottom; the list of components lives in Settings > About > Components.
    @ViewBuilder var installFooter: some View {
        let total = setup.steps.filter { !$0.optional }.count
        let done = setup.steps.filter { !$0.optional && $0.state == .ok }.count
        let failed = setup.steps.contains { $0.state == .failed }
        if setup.pythonMissing && !setup.busy {
            // 0.8.7 (L3.5): without Python nothing else installs; say how to get it
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(PN.C.onMe)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("setup.python.missing")).font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.text)
                    PythonInstallHint()
                    Button(L("about.components.check")) { installInBackground() }.buttonStyle(.pnTertiary)
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
        } else if failed {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(PN.C.onMe)
                Text(L("onboarding.install.failed")).font(PN.Font.caption).foregroundStyle(PN.C.onMe)
                Button(L("onboarding.install.details")) { SetupWindow.show() }.buttonStyle(.pnTertiary)
            }
        } else if setup.busy || (done < total && done > 0) {
            VStack(spacing: 4) {
                ProgressView(value: Double(done), total: Double(max(total, 1))).frame(width: 260).tint(PN.C.brand)
                Text(L("onboarding.install.progress", ["done": "\(done)", "total": "\(total)"])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
        } else if total > 0 && done == total {
            Label(L("onboarding.install.ready"), systemImage: "checkmark.circle").font(PN.Font.caption).foregroundStyle(PN.C.text3)
        } else {
            Text(L("onboarding.changeLater")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
        }
    }

    /// The installed Claude app's own icon on its step.
    var logo: NSImage? { m.step == .claude ? AppLogo.claude : nil }

    var title: String {
        switch m.step {
        case .splash: return L("app.name")
        case .permissions: return L("onboarding.permissions.title")
        case .folder: return L("onboarding.folder.title")
        case .claude: return L("onboarding.claude.title")
        case .addons: return L("comp.onb.title")
        case .done: return L("onboarding.done.title")
        }
    }

    var subtitle: String {
        switch m.step {
        case .splash: return L("app.tagline")
        case .permissions: return L("onboarding.permissions.body")
        case .folder: return L("onboarding.folder.body")
        case .claude: return L("onboarding.claude.body")
        case .addons: return L("comp.onb.body")
        case .done: return L("onboarding.done.body", ["help": HotKeys.shared.combo(.help).display])
        }
    }

    @ViewBuilder var content: some View {
        switch m.step {
        case .splash:
            // 2026-10-29 (owner): while the beta is not notarized, say why macOS asked for "Open Anyway" and that an
            // update may ask again. Shown only when this copy is not notarized.
            if sig.kind == .developer || sig.kind == .unsigned {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.shield").foregroundStyle(PN.C.onMe)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("onboarding.unsigned.title")).font(PN.Font.body.weight(.semibold))
                        Text(L("onboarding.unsigned.body")).font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(12).frame(maxWidth: 440, alignment: .leading)
                .background(PN.C.onMe.opacity(0.10), in: RoundedRectangle(cornerRadius: PN.Radius.m))
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
                // 0.8.7 (L3.1): where macOS keeps the switch, and why it says "screen" when Pacenote takes only sound
                if m.sysAudio != true {
                    VStack(alignment: .leading, spacing: 6) {
                        SystemAudioSettingsPicture()
                        Text(L("onboarding.permissions.screenNote")).font(PN.Font.caption).foregroundStyle(PN.C.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 12)
                }
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
                        .buttonStyle(.pnSecondary)
                }
                .padding(12).background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.m))
                let cands = settings.folderCandidates
                if !cands.isEmpty {
                    Text(L("onboarding.folder.workspaces")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    ForEach(cands, id: \.dir) { c in
                        Toggle(isOn: Binding(get: { m.picked.contains(c.dir) },
                                             set: { if $0 { m.picked.insert(c.dir) } else { m.picked.remove(c.dir) }; m.applyFolders() })) {
                            Text((c.dir as NSString).lastPathComponent + "  ·  " + L("onboarding.folder.projectFolders", ["n": "\(c.projects)"]))
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                // Merged with the projects step (spec 7): the projects found, ticked = active.
                if !settings.registry.projects.isEmpty {
                    Text(L("onboarding.projects.title")).font(PN.Font.caption).foregroundStyle(PN.C.text3).padding(.top, 4)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(settings.registry.projects, id: \.slug) { p in projectToggle(p.slug) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 170)
                } else if !settings.config.workRoot.isEmpty {
                    Text(L("onboarding.folder.empty")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    // 0.8.7 (L3): one click makes work / workspace / project
                    HStack(alignment: .top, spacing: 14) {
                        Button(L("onb.tree.create")) {
                            if let t = try? WorkTree.create(root: settings.config.workRoot) { tree = t; settings.rescanWorkspaces(); m.applyFolders() }
                        }.buttonStyle(.pnSecondary)
                        Text((tree.isEmpty ? ["work/", "  My workspace/", "    First project/"] : tree).joined(separator: "\n"))
                            .font(PN.Font.caption.monospaced()).foregroundStyle(PN.C.text3)
                    }
                    Text(L("onb.tree.hint")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                }
            }
            .onAppear { if !settings.config.workRoot.isEmpty { m.applyFolders() } }
            .onChange(of: settings.config.workRoot) { m.applyFolders() }
        case .claude:
            VStack(spacing: 8) {
                // 2026-10-29 (owner): preparing calls always needs Claude Code, whichever way pays (plan or API key).
                if let cc = setup.steps.first(where: { $0.id == "claude" }) {
                    HStack(spacing: 10) {
                        Image(systemName: cc.state == .ok ? "checkmark.circle.fill" : "terminal").foregroundStyle(cc.state == .ok ? PN.C.turn : PN.C.text3)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L("setup.step.claude.title")).font(PN.Font.body)
                            Text(cc.state == .ok ? cc.detail : L("setup.step.claude.why")).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(2)
                        }
                        Spacer()
                        if cc.state == .installing { ProgressView().controlSize(.small) }
                        else if cc.state != .ok { Button(L("onboarding.claude.install")) { Task { await setup.installOne("claude") } }.buttonStyle(.pnSecondary).disabled(setup.busy) }
                    }
                    .padding(10).background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.m))
                }
                // 0.8.7 (L3): 1) sign in (above), 2) an API key behind a disclosure, 3) continue without Claude, said honestly
                DisclosureGroup(L("onb.claude.haveKey"), isExpanded: $keyOpen) {
                HStack {
                    SecureField("", text: $m.apiKey, prompt: Text(settings.isSet(.claudeAPIKey) ? L("onboarding.claude.saved") : "sk-ant-…"))
                        .textFieldStyle(.roundedBorder)
                    Button(L("common.save")) { m.saveKey() }.buttonStyle(.pnSecondary).disabled(m.apiKey.isEmpty)
                }
                keyState(settings.keyState[.claudeAPIKey], fallback: m.keyNote)
                Link(L("onboarding.claude.getKey"), destination: URL(string: "https://console.anthropic.com/settings/keys")!).font(PN.Font.caption)
                }
                if !settings.isSet(.claudeAPIKey) && setup.steps.first(where: { $0.id == "claude" })?.state != .ok {
                    Text(L("onb.claude.without")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
        case .addons:
            OptionalAddonsStep(showHeader: false) { m.next() }
        case .done:
            HStack(spacing: 10) {
                Image(nsImage: Brand.menuBarImage(recording: false))
                    .padding(6).background(RoundedRectangle(cornerRadius: 6).fill(PN.C.surface2))
                Text(L("onboarding.done.menubarHint")).font(PN.Font.body).foregroundStyle(PN.C.text2)
            }
            // 0.8.7 (L3): the three shortcuts, shown again on the first call
            VStack(alignment: .leading, spacing: 4) {
                Text(L("onb.done.keys", ["h": HotKeys.shared.combo(.help).display, "t": HotKeys.shared.combo(.compact).display, "l": HotKeys.shared.combo(.proactive).display]))
                    .font(PN.Font.body.monospacedDigit()).foregroundStyle(PN.C.text)
                Text(L("onb.done.keysAgain")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            .padding(.top, 8)
        }
    }

    var primaryLabel: String {
        switch m.step {
        case .splash: return L("onboarding.splash.cta")
        case .claude: return settings.isSet(.claudeAPIKey) ? L("common.continue") : L("onboarding.claude.continueNoKey")
        case .done: return L("onboarding.done.primary")
        default: return L("common.continue")
        }
    }

    func primary() {
        switch m.step {
        case .folder: m.applyFolders(); m.next()
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

    func permissionRow(_ icon: String, _ t: String, ok: Bool, button: String, note: String = "", action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(PN.C.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(t).foregroundStyle(PN.C.text)
                if !note.isEmpty { Text(note).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
            }
            Spacer()
            if ok { Image(systemName: "checkmark").foregroundStyle(PN.C.turn).accessibilityLabel(L("common.works")) }
            else { Button(button, action: action).buttonStyle(.pnSecondary) }
        }
        .padding(12).background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.m))
    }

    @ViewBuilder func keyState(_ s: KeyState?, fallback: String) -> some View {
        switch s ?? .notSet {
        case .ok(let msg): Label(msg.isEmpty ? L("common.works") : msg, systemImage: "checkmark.circle.fill").foregroundStyle(PN.C.turn).font(PN.Font.caption)
        case .failed(let msg): Label(msg, systemImage: "xmark.circle.fill").foregroundStyle(PN.C.danger).font(PN.Font.caption)
        case .testing: Label(L("common.checking"), systemImage: "hourglass").foregroundStyle(PN.C.text3).font(PN.Font.caption)
        default: Text(fallback).font(PN.Font.caption).foregroundStyle(PN.C.text3)
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
            w.tabbingMode = .disallowed      // 0.8.7 (A1): never tabs
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

/// 0.8.7 (L3.1): a small static drawing of System Settings > Privacy & Security > Screen & System Audio Recording with
/// Pacenote's switch highlighted. Drawn in SwiftUI with the app's colours, so it follows light and dark by itself.
struct SystemAudioSettingsPicture: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(PN.C.text3.opacity(0.45)).frame(width: 7, height: 7) }
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    sidebarRow("gearshape", L("onboarding.pic.general"), selected: false)
                    sidebarRow("hand.raised.fill", L("onboarding.pic.privacy"), selected: true)
                    sidebarRow("speaker.wave.2", L("onboarding.pic.sound"), selected: false)
                }
                .padding(6).frame(width: 150, alignment: .leading)
                .background(PN.C.surface2.opacity(0.6))
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("onboarding.pic.pane")).font(.system(size: 11, weight: .semibold)).foregroundStyle(PN.C.text)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 4).fill(PN.C.accent).frame(width: 16, height: 16)
                            .overlay(Image(systemName: "waveform").font(.system(size: 9, weight: .bold)).foregroundStyle(.white))
                        Text("Pacenote").font(.system(size: 11)).foregroundStyle(PN.C.text)
                        Spacer()
                        // the switch, on, with a highlight ring
                        Capsule().fill(PN.C.accent).frame(width: 26, height: 15)
                            .overlay(Circle().fill(.white).frame(width: 12, height: 12).offset(x: 5.5))
                            .padding(3)
                            .overlay(Capsule().stroke(PN.C.onMe, lineWidth: 2))
                    }
                    .padding(6).background(PN.C.surface, in: RoundedRectangle(cornerRadius: 6))
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 4).fill(PN.C.text3.opacity(0.35)).frame(width: 16, height: 16)
                        RoundedRectangle(cornerRadius: 2).fill(PN.C.text3.opacity(0.25)).frame(width: 60, height: 6)
                        Spacer()
                        Capsule().fill(PN.C.text3.opacity(0.3)).frame(width: 26, height: 15)
                            .overlay(Circle().fill(.white).frame(width: 12, height: 12).offset(x: -5.5)).padding(3)
                    }
                    .padding(6).background(PN.C.surface, in: RoundedRectangle(cornerRadius: 6))
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 400)
        .background(PN.C.bg, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(PN.C.text3.opacity(0.25), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("onboarding.pic.a11y"))
    }

    private func sidebarRow(_ icon: String, _ t: String, selected: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 9)).frame(width: 12)
            Text(t).font(.system(size: 10)).lineLimit(1)
        }
        .foregroundStyle(selected ? Color.white : PN.C.text2)
        .padding(.horizontal, 5).padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? PN.C.accent : Color.clear, in: RoundedRectangle(cornerRadius: 4))
    }
}
