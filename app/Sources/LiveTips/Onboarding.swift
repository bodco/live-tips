import AppKit
import AVFoundation
import LiveTipsCore
import SwiftUI

/// First-run onboarding (2026-10-26, owner: "like Fireflies"): one window, one question per screen,
/// a progress line on top, Back and Continue. Everything here can be changed later in Settings.
/// 0.16.0 (D3): seven steps. Welcome (the three moments of a call), Permissions, Folder, AI with the fallback chain,
/// What to install (required parts locked, optional ones unticked), Your calls (new: Quick or Expert, tips, recording,
/// consent; it only sets what Settings already has), Ready with a practice call.
@MainActor
final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable { case welcome, permissions, folder, ai, install, calls, done }
    @Published var step: Step = .welcome
    @Published var micState = AVCaptureDevice.authorizationStatus(for: .audio)
    /// true granted, false denied, nil not asked yet (or macOS does not say).
    @Published var sysAudio: Bool? = SystemAudioPermission.granted()
    /// 0.9.5: Screen Recording, for call recordings with the screen (optional; asked here so a recording never asks mid-call)
    @Published var screen = ScreenPermission.granted()
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
        screen = ScreenPermission.granted()
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
    @State private var provider = "claude"       // 0.9.0 (owner): Claude or ChatGPT, as in Settings > AI
    @ObservedObject var settings: SettingsModel
    @ObservedObject var setup: SetupModel
    @ObservedObject var cal = CalendarService.shared
    @ObservedObject var sig = AppSignature.shared
    var close: () -> Void

    init(m: OnboardingModel, close: @escaping () -> Void) {
        self.m = m; self.settings = m.settings; self.setup = m.setup; self.close = close
    }

    var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.8" }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle().fill(PN.C.surface2)
                    Rectangle().fill(PN.C.accentFill).frame(width: g.size.width * m.progress)
                }
            }
            .frame(height: 3)
            .animation(.easeInOut(duration: 0.25), value: m.step)
            VStack(spacing: m.step == .install ? 8 : 14) {      // What to install: tighter, so it fits 680
                HStack {
                    if ![.welcome, .permissions, .done].contains(m.step) {
                        Button { m.back() } label: { Image(systemName: "arrow.left") }.buttonStyle(.borderless).accessibilityLabel(L("onboarding.back"))
                    } else { Color.clear.frame(width: 16, height: 16) }
                    Spacer()
                    if m.step != .welcome {
                        Text(L("onb.stepOf", ["n": "\(m.step.rawValue)", "total": "\(OnboardingModel.Step.allCases.count - 1)"]))
                            .font(PN.Font.label).foregroundStyle(PN.C.text3)
                    }
                    Spacer()
                    if m.step != .done { Button(L("onb.later")) { close() }.buttonStyle(.pnTertiary) } else { Color.clear.frame(width: 16, height: 16) }
                }
                if m.step == .done {
                    Image(nsImage: Brand.appIcon).resizable().interpolation(.high).frame(width: 96, height: 96).accessibilityHidden(true)
                } else if m.step == .install {
                    EmptyView()                     // What to install is the tallest step: no mark, so it fits 680
                } else if let logo = logo {
                    IconTile(symbol: "sparkles", image: logo)
                } else {
                    PacenoteSymbol(height: 44)      // the brand symbol above each step's title
                }
                Text(title).font(.title.weight(.semibold)).multilineTextAlignment(.center).foregroundStyle(PN.C.text)
                Text(subtitle).font(.body).foregroundStyle(PN.C.text2).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 560)
                if m.step == .folder {      // smoke 15.11: What to install scrolls too, so a long language never clips the header
                    content.frame(maxWidth: 620)
                } else {
                    ScrollView { content.frame(maxWidth: 620) }.scrollBounceBehavior(.basedOnSize)
                }
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    if m.step == .done {
                        Button(L("onb.done.home")) { finish(); (NSApp.delegate as? AppDelegate)?.openHome() }.buttonStyle(.pnSecondary)
                    }
                    if m.step != .install {          // What to install has its own "Install N and continue"
                        Button { primary() } label: { Text(primaryLabel).frame(minWidth: 200) }
                            .buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
                    }
                }
                installFooter
            }
            .padding(.horizontal, 32).padding(.vertical, 16)
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

    /// Speech recognition and the local search model install while the PM goes through the steps (spec 7).
    func installInBackground() {
        guard !setup.busy else { return }
        Task {
            await setup.checkAll()
            if !setup.allRequiredOK { await setup.installMissing(includeOptional: false) }   // Claude Code: only on Install
        }
    }

    /// One line of progress at the bottom; the parts themselves are on step 5 and in Settings > Components.
    @ViewBuilder var installFooter: some View {
        let total = setup.steps.filter { !$0.optional }.count
        let done = setup.steps.filter { !$0.optional && $0.state == .ok }.count
        let failed = setup.steps.contains { $0.state == .failed }
        if m.step == .welcome {
            Text(L("onb.changeLater")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
        } else if setup.pythonMissing && !setup.busy {
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
            HStack(spacing: 8) {
                ProgressView(value: Double(done), total: Double(max(total, 1))).frame(width: 160).tint(PN.C.brand)
                Text(L("onboarding.install.progress", ["done": "\(done)", "total": "\(total)"])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
        } else if total > 0 && done == total {
            Label(L("onboarding.install.ready"), systemImage: "checkmark.circle").font(PN.Font.caption).foregroundStyle(PN.C.text3)
        } else {
            Text(L("onboarding.changeLater")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
        }
    }

    /// The installed Claude app's own icon on the AI step (Claude chosen).
    var logo: NSImage? { m.step == .ai && provider == "claude" ? AppLogo.claude : nil }

    var title: String {
        switch m.step {
        case .welcome: return L("onb.welcome.title")
        case .permissions: return L("onboarding.permissions.title")
        case .folder: return L("onboarding.folder.title")
        case .ai: return L("onboarding.claude.title")
        case .install: return L("onb.install.title")
        case .calls: return L("onb.calls.title")
        case .done: return L("onboarding.done.title")
        }
    }

    var subtitle: String {
        switch m.step {
        case .welcome: return L("onb.welcome.body")
        case .permissions: return L("onboarding.permissions.body")
        case .folder: return L("onboarding.folder.body")
        case .ai: return L("onb.ai.body")
        case .install: return L("onb.install.body")
        case .calls: return L("onb.calls.body")
        case .done: return L("onb.done.body")
        }
    }

    @ViewBuilder var content: some View {
        switch m.step {
        case .welcome:
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    beat("doc.text", "before")
                    beat("waveform", "during")
                    beat("checklist", "after")
                }
                Text(L("onb.welcome.audio")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                // 2026-10-29 (owner): while the beta is not notarized, say why macOS asked for "Open Anyway" and that an
                // update may ask again. Shown only when this copy is not notarized.
                if sig.kind == .developer || sig.kind == .unsigned {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "checkmark.shield").foregroundStyle(PN.C.onMe)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("onboarding.unsigned.title")).font(PN.Font.body.weight(.semibold))
                            Text(L("onboarding.unsigned.body")).font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .background(PN.C.onMe.opacity(0.10), in: RoundedRectangle(cornerRadius: PN.Radius.m))
                }
            }
            .onAppear { sig.check() }
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
                // 0.9.5 (owner): in the same set, so a call recording never stops to ask
                permissionRow("record.circle", L("onboarding.permissions.screen"), ok: m.screen,
                              button: L("onboarding.permissions.screenButton"), note: L("onboarding.permissions.screenOptional")) {
                    if !ScreenPermission.request() { ScreenPermission.openSettings() }
                    m.refreshPermissions()
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
        case .ai:
            VStack(spacing: 10) {
                aiAccess
                OnboardingAIChain(provider: provider)
            }
        case .install:
            ComponentsChecklist(provider: provider) { m.next() }
        case .calls:
            OnboardingCallsStep(settings: settings)
        case .done:
            VStack(spacing: 10) {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Image(nsImage: Brand.menuBarImage(recording: false))
                            .padding(6).background(RoundedRectangle(cornerRadius: 6).fill(PN.C.surface2))
                        Text(L("onb.done.menubar")).font(PN.Font.body).foregroundStyle(PN.C.text)
                        Spacer()
                    }
                    .padding(.vertical, 10)
                    Divider()
                    keyRow(L("onb.done.keyHelp"), HotKeys.shared.combo(.help).display)
                    Divider()
                    keyRow(L("onb.done.keyTips"), HotKeys.shared.combo(.proactive).display)
                    Divider()
                    OnboardingTelemetryRow().padding(.vertical, 10)          // 0.10.1 (A6, D15): on by default, said here with the switch
                }
                .padding(.horizontal, 16)
                .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.m))
                Text(L("onb.done.practice")).font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Claude or ChatGPT, as before 0.16 (the provider row, the API key behind a disclosure, ChatGPT through Codex).
    @ViewBuilder var aiAccess: some View {
        VStack(spacing: 8) {
            Picker("", selection: $provider) {
                Text("Claude").tag("claude")
                Text("ChatGPT").tag("chatgpt")
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 280)
            if provider == "claude" {
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
            } else {
            // 0.9.0: ChatGPT: the account through Codex, or an OpenAI API key; one button sets every job to it
            CodexAccountRow()
            Button(L("ai.codex.use")) {
                settings.config.ai.prep = AIRoute.codex
                settings.config.ai.tips = AIRoute.codex
                settings.config.ai.after = AIRoute.codex
            }.buttonStyle(.pnSecondary).disabled(CodexAccount.cliPath == nil)
            KeyRow(title: L("keys.openai.title"), hint: L("keys.openai.hint"), key: .openaiAPIKey, model: settings)
            Button(L("ai.openai.use")) {
                settings.config.ai.prep = AIRoute.openai
                settings.config.ai.tips = AIRoute.openai
                settings.config.ai.after = AIRoute.openai
            }.buttonStyle(.pnSecondary).disabled(!settings.isSet(.openaiAPIKey))
            }
            if ![AIRoute.codex, AIRoute.openai].contains(settings.config.ai.prep) && !settings.isSet(.claudeAPIKey) && !settings.isSet(.openaiAPIKey) && setup.steps.first(where: { $0.id == "claude" })?.state != .ok {
                Text(L("onb.claude.without")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func beat(_ symbol: String, _ id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(PN.C.accent).accessibilityHidden(true)
            Text(L("onb.beat.\(id).when")).font(PN.Font.label).foregroundStyle(PN.C.text3).padding(.top, 4)
            Text(L("onb.beat.\(id).head")).font(PN.Font.section).foregroundStyle(PN.C.text)
            Text(L("onb.beat.\(id).body", ["help": HotKeys.shared.combo(.help).display])).font(PN.Font.caption).foregroundStyle(PN.C.text2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16).frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(PN.C.surface, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    func keyRow(_ action: String, _ keys: String) -> some View {
        HStack {
            Text(action).foregroundStyle(PN.C.text)
            Spacer()
            Text(keys).font(PN.Font.caption.monospaced()).foregroundStyle(PN.C.text2)
                .padding(.horizontal, 6).padding(.vertical, 2).background(PN.C.surface2, in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(.vertical, 10)
    }

    var primaryLabel: String {
        switch m.step {
        case .welcome: return L("onb.welcome.cta")
        case .ai: return (settings.isSet(.claudeAPIKey) || settings.isSet(.openaiAPIKey) || [AIRoute.codex, AIRoute.openai].contains(settings.config.ai.prep)) ? L("common.continue") : L("onboarding.claude.continueNoKey")
        case .done: return L("onb.done.practiceCta")
        default: return L("common.continue")
        }
    }

    func primary() {
        switch m.step {
        case .folder: m.applyFolders(); m.next()
        case .done:
            finish()
            UsageLog.log("practice_call", ["from": "onboarding"])
            (NSApp.delegate as? AppDelegate)?.showDemo()     // the tips window on a sample call, nothing recorded or saved
        default: m.next()
        }
    }

    /// Done: the onboarding never comes back by itself, and What's new for this version is not shown to a new person.
    func finish() {
        UserDefaults.standard.set(true, forKey: "onboardingDone")
        WhatsNewStore.markSeen()
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

/// 0.16.0 (D3, step 4): "If your AI is out". The order Pacenote tries when the chosen AI is out of limit, offline or
/// too slow: 1 the chosen provider, 2 the other one, 3 the model on this Mac, 4 the rules only. What is not
/// connected is grey with the reason. The real order and the AI per job: Settings > AI.
struct OnboardingAIChain: View {
    let provider: String
    @ObservedObject var oc = OptionalComponents.shared

    struct Link: Identifiable { let id: String; let label: String; let note: String; let on: Bool }

    var links: [Link] {
        let c = AIRoute.connected()
        let claude = c.contains(AIRoute.code) || c.contains(AIRoute.api)
        let gpt = c.contains(AIRoute.codex) || c.contains(AIRoute.openai)
        let first = provider == "claude" ? ("Claude", claude) : ("ChatGPT", gpt)
        let second = provider == "claude" ? ("ChatGPT", gpt) : ("Claude", claude)
        let local = c.contains(AIRoute.local)
        return [Link(id: "1", label: first.0, note: L(first.1 ? "ai.chain.connected" : "ai.chain.notConnected"), on: first.1),
                Link(id: "2", label: second.0, note: L(second.1 ? "ai.chain.connected" : "ai.chain.notConnected"), on: second.1),
                Link(id: "3", label: L("onb.chain.local"), note: L(local ? "ai.chain.connected" : "onb.chain.notInstalled"), on: local),
                Link(id: "4", label: L("onb.chain.rules"), note: L("onb.chain.always"), on: true)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("onb.chain.title")).font(PN.Font.section).foregroundStyle(PN.C.text)
            Text(L("onb.chain.sub")).font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ForEach(links) { l in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(l.id + "  " + l.label).font(PN.Font.caption.weight(.semibold)).lineLimit(1)
                        Text(l.note).font(PN.Font.caption).foregroundStyle(l.on && l.id != "4" ? PN.C.turn : PN.C.text3).lineLimit(1)
                    }
                    .fixedSize()
                    .foregroundStyle(l.on && l.id != "4" ? PN.C.turn : PN.C.text2)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background((l.on && l.id != "4" ? PN.C.turn.opacity(0.13) : PN.C.surface2), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityElement(children: .combine)
                    if l.id != "4" { Text("›").foregroundStyle(PN.C.text3).accessibilityHidden(true) }
                }
            }
            Text(L("onb.chain.foot")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.m))
    }
}

/// 0.16.0 (D3, step 6): Your calls. Sets what Settings already has, nothing new: Quick or Expert for every call
/// (Settings > Meeting Sheet), tips when useful or only when asked (the tips window's own switch), recording off,
/// sound or sound and screen (Settings > Call recording), and the consent line to paste in the chat.
struct OnboardingCallsStep: View {
    @ObservedObject var settings: SettingsModel
    @ObservedObject var prefs = SheetPrefs.shared
    @State private var proactive = ((UserDefaults.standard.dictionary(forKey: "prompterPrefs") ?? [:])["proactive"] as? String) == "1"
    @State private var screenOK = ScreenPermission.granted()

    var sheetMode: Binding<String> {
        Binding(get: { prefs.forced.isEmpty ? "quick" : prefs.forced }, set: { prefs.forced = $0 })
    }
    var tips: Binding<String> {
        Binding(get: { proactive ? "useful" : "ask" }, set: { v in
            proactive = v == "useful"
            var p = UserDefaults.standard.dictionary(forKey: "prompterPrefs") ?? [:]; p["proactive"] = proactive ? "1" : "0"
            UserDefaults.standard.set(p, forKey: "prompterPrefs")
        })
    }
    var record: Binding<String> {
        Binding(get: { !settings.config.recording.auto ? "off" : settings.config.recording.kind == "audio" ? "sound" : "screen" },
                set: { v in
                    settings.config.recording.auto = v != "off"
                    if v != "off" { settings.config.recording.kind = v == "sound" ? "audio" : "video" }
                })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(spacing: 0) {
                row(L("onb.calls.sheet"), sheetMode.wrappedValue == "quick" ? L("onb.calls.sheet.quick") : L("onb.calls.sheet.expert")) {
                    Picker("", selection: sheetMode) {
                        Text(L("sheet.ui.quick")).tag("quick")
                        Text(L("sheet.ui.expert")).tag("expert")
                    }
                }
                Divider()
                row(L("onb.calls.tips"), proactive ? L("onb.calls.tips.useful.sub") : L("onb.calls.tips.ask.sub", ["help": HotKeys.shared.combo(.help).display])) {
                    Picker("", selection: tips) {
                        Text(L("onb.calls.tips.useful")).tag("useful")
                        Text(L("onb.calls.tips.ask")).tag("ask")
                    }
                }
                Divider()
                row(L("onb.calls.rec"), recordSub) {
                    Picker("", selection: record) {
                        Text(L("onb.calls.rec.off")).tag("off")
                        Text(L("onb.calls.rec.sound")).tag("sound")
                        Text(L("onb.calls.rec.screen")).tag("screen")
                    }
                }
                if record.wrappedValue == "screen" && !screenOK {
                    HStack {
                        Text(L("onb.calls.rec.needsScreen")).font(PN.Font.caption).foregroundStyle(PN.C.onMe)
                        Spacer()
                        Button(L("onboarding.permissions.screenButton")) {
                            if !ScreenPermission.request() { ScreenPermission.openSettings() }
                            screenOK = ScreenPermission.granted()
                        }.buttonStyle(.pnTertiary)
                    }
                    .padding(.bottom, 8)
                }
                Divider()
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("onb.calls.consent"))
                        Text(settings.config.consentChat ? L("onb.calls.consent.on") : L("onb.calls.consent.off"))
                            .font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: $settings.config.consentChat).toggleStyle(.switch).labelsHidden()
                        .accessibilityLabel(L("onb.calls.consent"))
                }
                .padding(.vertical, 12)
            }
            .padding(.horizontal, 16)
            .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.m))
            Text(L("onb.calls.foot")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
        }
    }

    var recordSub: String {
        switch record.wrappedValue {
        case "off": return L("onb.calls.rec.off.sub")
        case "sound": return L("onb.calls.rec.sound.sub")
        default: return L("onb.calls.rec.screen.sub")
        }
    }

    func row<P: View>(_ label: String, _ sub: String, @ViewBuilder picker: () -> P) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).foregroundStyle(PN.C.text)
                Text(sub).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            picker().pickerStyle(.segmented).labelsHidden().fixedSize()
        }
        .padding(.vertical, 10)
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
        model.step = .welcome
        WhatsNewStore.markSeen()     // 0.16.0 (D3): the onboarding covers this version; What's new does not follow it
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

/// 0.10.1 (A6, owner decision D15): Help improve Pacenote is on from the first launch; onboarding says what goes and
/// lets the PM turn it off right there (the same switch as Settings > General > Privacy).
struct OnboardingTelemetryRow: View {
    @State private var on = AppConfig.load(from: AppPaths.config).shareUsage

    var body: some View {
        Toggle(isOn: $on) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("telemetry.toggle")).font(PN.Font.body.weight(.medium))
                Text(L("telemetry.onb.sub")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .onChange(of: on) {
            var c = AppConfig.load(from: AppPaths.config)
            c.shareUsage = on
            if on { c.usageLog = true }
            try? c.save(to: AppPaths.config)
            SettingsWindow.model.config.shareUsage = on
            if on { SettingsWindow.model.config.usageLog = true }
            TelemetrySender.setOn(on)
        }
    }
}
