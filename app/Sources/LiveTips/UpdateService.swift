import AppKit
import LiveTipsCore
import Sparkle
import SwiftUI

/// 0.16.0 (D3, updates, Bohdan 15.11): updates from inside Pacenote with Sparkle 2.
/// Checks at launch and twice a day (Info.plist SUScheduledCheckInterval), downloads in the background when that
/// switch is on, and installs only when the person says so: "Install and restart" in About > Updates, the line on
/// Home or the dot on the menu bar icon. Never during a call: no checks while a call is live, and an install asked
/// for during a call waits for the call to end. The appcast is pacenote.bodco.pm/appcast.xml, every update is signed
/// with the EdDSA key whose public half is SUPublicEDKey in Info.plist. A build without that key (a developer build)
/// has updates off and keeps the manual "Check for updates" against GitHub in About.
///
/// Sparkle's own window shows only when the person asks to install an update that is not downloaded yet (it shows the
/// release notes and the download); scheduled finds never pop up Sparkle's window (gentle reminders).
/// 0.23.0 (Bohdan 18.11): a found version opens Pacenote's own update window (UpdatePromptWindow) on every launch,
/// once per launch, after the sign-in and the onboarding and never during a call, and a banner at the top of Home;
/// the dot and About say it too. A quiet check runs a little after every launch, so the window comes back.
final class UpdateService: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = UpdateService()

    enum Phase: Equatable {
        case off                     // no key or feed in this build
        case idle                    // nothing new (or not checked yet)
        case checking
        case available(String)       // found, not downloaded
        case ready(String)           // downloaded, verified, waits for "Install and restart"
        case failed(String)
    }

    @Published private(set) var phase: Phase = .off
    @Published private(set) var notes: [String] = []
    @Published private(set) var lastCheck: Date?
    /// "Install after the call" was pressed during a call: install as soon as it ends.
    @Published private(set) var installAfterCall = false
    /// "Later" hides the dot and the Home line for this version until the next launch.
    @Published var dismissedVersion: String?
    /// 0.23.0: versions whose update window was shown in this launch (it comes back at the next launch).
    private(set) var promptedThisLaunch: Set<String> = []
    func markPrompted(_ v: String) { promptedThisLaunch.insert(v) }

    private var controller: SPUStandardUpdaterController?
    private var installNow: (() -> Void)?
    private var postponedRelaunch: (() -> Void)?

    var updater: SPUUpdater? { controller?.updater }

    /// The info for a version that is new: shown on Home, in About and as the menu bar dot.
    var newVersion: String? {
        switch phase {
        case .available(let v), .ready(let v): return v == dismissedVersion ? nil : v
        default: return nil
        }
    }
    var isOn: Bool { phase != .off }

    static var configured: Bool {
        let i = Bundle.main.infoDictionary ?? [:]
        return !((i["SUPublicEDKey"] as? String) ?? "").isEmpty && !((i["SUFeedURL"] as? String) ?? "").isEmpty
    }

    static var callIsLive: Bool {
        let st = EngineStatus.load(path: CallEngine.shared.statusPath)
        return CallEngine.shared.isRunning || ["recording", "standby", "loading_model"].contains(st.state)
    }

    /// At launch (AppDelegate), never in the shot modes.
    func start() {
        guard Self.configured, controller == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        phase = .idle
        lastCheck = updater?.lastUpdateCheckDate
        NotificationCenter.default.addObserver(forName: CallEngine.callEnded, object: nil, queue: .main) { [weak self] _ in
            self?.callEnded()
        }
        // 0.23.0: a quiet check a little after every launch (when automatic checks are on), so a version found before
        // shows its window again; Sparkle's own schedule only checks every 12 hours.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let u = self?.updater, u.automaticallyChecksForUpdates, u.canCheckForUpdates, !Self.callIsLive else { return }
            u.checkForUpdatesInBackground()
        }
    }

    /// 0.23.0: open the update window if it is due (UpdatePromptWindow decides).
    func maybePrompt() {
        DispatchQueue.main.async { MainActor.assumeIsolated { UpdatePromptWindow.showIfNeeded() } }
    }

    // MARK: switches (About > Updates)

    var automaticChecks: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }
    var backgroundDownload: Bool {
        get { updater?.automaticallyDownloadsUpdates ?? false }
        set { updater?.automaticallyDownloadsUpdates = newValue; objectWillChange.send() }
    }

    // MARK: actions

    /// "Check now": a quiet check, the answer shows in About (no Sparkle window for "you're up to date").
    func checkNow() {
        guard let u = updater, u.canCheckForUpdates else { return }
        phase = .checking
        u.checkForUpdatesInBackground()
    }

    /// "Install and restart" (About, Home, the menu). Downloaded: installs now, or after the call. Not downloaded yet:
    /// Sparkle's window with the release notes takes it from there.
    func install() {
        if Self.callIsLive { installAfterCall = true; return }
        if let go = installNow { installNow = nil; go(); return }
        controller?.checkForUpdates(nil)
    }

    func later() { dismissedVersion = newVersion }

    private func callEnded() {
        if let go = postponedRelaunch { postponedRelaunch = nil; go(); return }
        if installAfterCall { installAfterCall = false; install(); return }
        maybePrompt()       // 0.23.0: a version found during the call opens its window now
    }

    // MARK: SPUUpdaterDelegate

    /// Developer test only: `defaults write <bundle id> updateFeedOverride <https URL or http://127.0.0.1:port/...>` points the app at a
    /// test appcast (an update test without publishing). Unset, the Info.plist feed is used.
    func feedURLString(for updater: SPUUpdater) -> String? {
        guard let s = UserDefaults.standard.string(forKey: "updateFeedOverride"),
              s.hasPrefix("https://") || s.hasPrefix("http://127.0.0.1:") else { return nil }      // Sparkle refuses file://
        return s
    }

    /// No checks while a call is live; the next scheduled one comes later.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if updateCheck == .updatesInBackground && Self.callIsLive {
            throw NSError(domain: "Pacenote", code: 1, userInfo: [NSLocalizedDescriptionKey: "A call is live"])
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        DispatchQueue.main.async {
            self.notes = Self.bullets(item.itemDescription)
            if case .ready = self.phase { return }
            self.phase = .available(item.displayVersionString)
            self.maybePrompt()
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        DispatchQueue.main.async { self.phase = .idle; self.lastCheck = Date() }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        DispatchQueue.main.async {
            self.lastCheck = updater.lastUpdateCheckDate ?? Date()
            if let e = error as NSError?, e.domain != SUSparkleErrorDomain || e.code != Int(SUError.noUpdateError.rawValue) {
                if case .checking = self.phase { self.phase = .failed(e.localizedDescription) }
                // S5: error update; "A call is live" (our own refusal) and a check the PM cancelled are not errors
                if !(e.domain == "Pacenote" && e.code == 1) {
                    let code = e.domain == NSURLErrorDomain ? Analytics.errorCode(URLError(URLError.Code(rawValue: e.code)))
                        : e.code == Int(SUError.installationCanceledError.rawValue) ? "cancelled" : Analytics.errorCode(message: e.localizedDescription)
                    AnalyticsTracker.onMain { AnalyticsTracker.shared.error("update", code) }
                }
            } else if case .checking = self.phase { self.phase = .idle }
        }
    }

    /// Downloaded in the background: Pacenote shows it and installs on "Install and restart" (or when it quits).
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock: @escaping () -> Void) -> Bool {
        DispatchQueue.main.async {
            self.installNow = immediateInstallationBlock
            self.notes = Self.bullets(item.itemDescription)
            self.phase = .ready(item.displayVersionString)
            if self.installAfterCall && !Self.callIsLive { self.installAfterCall = false; self.install(); return }
            self.maybePrompt()
        }
        return true
    }

    /// Never restart into the new version during a call: it waits for the call to end.
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard Self.callIsLive else { return false }
        DispatchQueue.main.async { self.postponedRelaunch = installHandler; self.installAfterCall = true }
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let e = error as NSError
        guard e.domain != SUSparkleErrorDomain || e.code != Int(SUError.noUpdateError.rawValue) else { return }
        DispatchQueue.main.async { if case .checking = self.phase { self.phase = .failed(e.localizedDescription) } }
    }

    // MARK: SPUStandardUserDriverDelegate

    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// A scheduled find never opens Sparkle's window: the dot, Home and About show it.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool { false }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        DispatchQueue.main.async {
            self.notes = Self.bullets(update.itemDescription)
            if case .ready = self.phase { return }
            self.phase = .available(update.displayVersionString)
            self.maybePrompt()
        }
    }

    // MARK: helpers

    /// The appcast item's description (HTML) as plain lines (LiveTipsCore/AppcastNotes, checked in CoreChecks).
    static func bullets(_ html: String?) -> [String] { AppcastNotes.bullets(html) }
}

// MARK: - About > Updates

/// About > Updates (mockup "Update" and "UpdateLive"): the new version with its notes, Install and restart (Install
/// after the call during a call), Later, and the two switches. A build without updates shows the manual check.
struct UpdatesSection: View {
    @ObservedObject var up = UpdateService.shared
    @State private var live = UpdateService.callIsLive

    var mine: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    var body: some View {
        Section {
            if let v = up.newVersion {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Circle().fill(PN.C.brand).frame(width: 8, height: 8).accessibilityHidden(true)
                        Text(L(isReady ? "upd.ready" : "upd.available", ["v": v])).pnSection()
                        Spacer()
                        Text(L("upd.youHave", ["v": mine])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    }
                    if !up.notes.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(up.notes, id: \.self) { n in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text("•").foregroundStyle(PN.C.text3).accessibilityHidden(true)
                                    Text(n).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    if live || up.installAfterCall {
                        Text(L("upd.afterCall.note")).font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.onMe)
                            .padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                            .background(PN.C.onMe.opacity(0.13), in: RoundedRectangle(cornerRadius: PN.Radius.m))
                    }
                    HStack(spacing: 8) {
                        Button(live ? L("upd.installAfter") : L("upd.install")) { up.install() }
                            .buttonStyle(.pnPrimary).disabled(up.installAfterCall)
                        Button(L("upd.later")) { up.later() }.buttonStyle(.pnSecondary)
                    }
                }
                .padding(.vertical, 4)
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusLine)
                        if let d = up.lastCheck {
                            Text(L("upd.lastCheck", ["when": d.formatted(date: .abbreviated, time: .shortened)]))
                                .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                        }
                    }
                    Spacer()
                    Button(L("upd.checkNow")) { up.checkNow() }.buttonStyle(.pnSecondary).disabled(up.phase == .checking)
                }
            }
            Toggle(isOn: Binding(get: { up.automaticChecks }, set: { up.automaticChecks = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("upd.auto"))
                    Text(L("upd.auto.sub")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle(isOn: Binding(get: { up.backgroundDownload }, set: { up.backgroundDownload = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("upd.bg"))
                    Text(L("upd.bg.sub")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: { Text(L("upd.title")) }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in live = UpdateService.callIsLive }
    }

    var isReady: Bool { if case .ready = up.phase { return true }; return false }

    var statusLine: String {
        switch up.phase {
        case .checking: return L("common.checking")
        case .failed(let m): return L("upd.failed", ["error": m])
        default: return L("upd.upToDate", ["v": mine])
        }
    }
}

/// Home: a banner at the top when a new version is there (0.23.0, Bohdan 18.11; was one line since 0.16.0):
/// "Pacenote 0.23.1 is ready", You have 0.23.0, What's new (the update window), Later (until the next launch), Install
/// (Install after the call during a call).
struct UpdateHomeLine: View {
    @ObservedObject var up = UpdateService.shared
    @State private var live = UpdateService.callIsLive
    var mine: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    var body: some View {
        if let v = up.newVersion {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill").font(PN.sys(22)).foregroundStyle(PN.C.accent).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L(isReady ? "upd.home.ready" : "upd.home.available", ["v": v])).pnSection().foregroundStyle(PN.C.text)
                    Text(L("upd.youHave", ["v": mine])).font(PN.Font.caption).foregroundStyle(PN.C.text2)
                }
                Spacer(minLength: 8)
                if !up.notes.isEmpty { Button(L("upd.home.details")) { UpdatePromptWindow.show(version: v) }.buttonStyle(.pnTertiary) }
                Button(L("upd.later")) { up.later() }.buttonStyle(.pnTertiary)
                Button(live ? L("upd.installAfter") : L("upd.home.install")) { up.install() }
                    .buttonStyle(.pnPrimary).disabled(up.installAfterCall)
            }
            .padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
            .background(PN.C.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: PN.Radius.m))
            .overlay(RoundedRectangle(cornerRadius: PN.Radius.m).stroke(PN.C.accent.opacity(0.35), lineWidth: 1))
            .accessibilityElement(children: .contain)
            .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in live = UpdateService.callIsLive }
        }
    }
    var isReady: Bool { if case .ready = up.phase { return true }; return false }
}

/// 0.23.0 (Bohdan 18.11): the update window. Opens on every launch while a new version is there (UpdatePrompt), and
/// from What's new on Home's banner. The version, what is new (the appcast notes), Later and Install and restart.
struct UpdatePromptView: View {
    @ObservedObject var up = UpdateService.shared
    let version: String
    var close: () -> Void
    @State private var live = UpdateService.callIsLive
    var mine: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    var isReady: Bool { if case .ready = up.phase { return true }; return false }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                PacenoteSymbol(height: 32).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L(isReady ? "upd.ready" : "upd.available", ["v": version])).pnTitle().foregroundStyle(PN.C.text)
                    Text(L("upd.youHave", ["v": mine])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                }
            }
            if !up.notes.isEmpty {
                Text(L("upd.prompt.notes")).pnLabel().foregroundStyle(PN.C.text3)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(up.notes, id: \.self) { n in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("•").foregroundStyle(PN.C.text3).accessibilityHidden(true)
                                Text(n).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
            }
            if live || up.installAfterCall {
                Text(L("upd.afterCall.note")).font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.onMe)
                    .padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(PN.C.onMe.opacity(0.13), in: RoundedRectangle(cornerRadius: PN.Radius.m))
            } else {
                Text(L("upd.prompt.sub")).font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer()
                Button(L("upd.later")) { close() }.buttonStyle(.pnSecondary).keyboardShortcut(.cancelAction)
                Button(live ? L("upd.installAfter") : L("upd.install")) { up.install(); close() }
                    .buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction).disabled(up.installAfterCall)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(PN.C.bg)
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in live = UpdateService.callIsLive }
    }
}

@MainActor
enum UpdatePromptWindow {
    static var window: NSWindow?

    /// Every launch while a new version is there, once per launch and version (LiveTipsCore/UpdatePrompt).
    static func showIfNeeded() {
        guard ProcessInfo.processInfo.environment["LT_SUPPORT_DIR"] == nil, window?.isVisible != true else { return }
        let up = UpdateService.shared, d = UserDefaults.standard
        let other = SignInWindow.isVisible || OnboardingWindow.window?.isVisible == true || WhatsNewWindow.window?.isVisible == true
        guard UpdatePrompt.shouldShow(newVersion: up.newVersion, shownThisLaunch: up.promptedThisLaunch,
                                      signedIn: PacenoteAccount.shared.signedIn,
                                      onboarded: d.bool(forKey: "onboardingDone") || d.bool(forKey: "onboarded"),
                                      callLive: UpdateService.callIsLive, otherWindowUp: other),
              let v = up.newVersion else { return }
        up.markPrompted(v)
        show(version: v)
    }

    static func show(version: String) {
        if let w = window, w.isVisible { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentViewController: NSHostingController(rootView: Localized { UpdatePromptView(version: version) { window?.close() } }))
        w.tabbingMode = .disallowed
        w.title = L("upd.prompt.window")
        w.styleMask.remove(.resizable)
        w.isReleasedWhenClosed = false
        window = w
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
