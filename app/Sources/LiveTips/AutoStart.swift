import AppKit
import CoreAudio
import UserNotifications
import LiveTipsCore

/// Pacenote 0.8.5 (F5, idea 08): when a meeting app is on (Zoom, Microsoft Teams, or Google Meet in a browser, seen as
/// the microphone in use by another app) and the calendar has a call now (within 5 minutes of its start), Pacenote
/// offers to start tips once: a quiet notification and a banner on Home. It never records by itself: Start tips is
/// the PM's click. Settings > Calendars > "Suggest starting tips when a call begins" (on by default).
@MainActor
final class AutoStart: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = AutoStart()
    @Published private(set) var suggestion: CalendarService.CalEvent?
    private var asked: Set<String> = []
    private var timer: Timer?
    static let defaultsKey = "autostartSuggest"
    static let idPrefix = "pn-auto-"

    var enabled: Bool { UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? true }

    private var live: Bool {
        CallEngine.shared.isRunning || ["recording", "standby", "loading_model"].contains(EngineStatus.load(path: CallEngine.shared.statusPath).state)
    }

    func start() {
        UNUserNotificationCenter.current().delegate = self
        asked = Set(UserDefaults.standard.stringArray(forKey: "autostartAsked") ?? [])
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in MainActor.assumeIsolated { AutoStart.shared.check() } }
    }

    /// Calls that begin now: started up to 5 minutes ago or starting in the next 5 minutes.
    func candidates(_ now: Date = Date()) -> [CalendarService.CalEvent] {
        CalendarService.shared.upcoming(now).filter { abs($0.start.timeIntervalSince(now)) <= 300 }
    }

    func check() {
        guard enabled, CalendarService.shared.access == .granted, !live else {
            if suggestion != nil && (live || !enabled) { suggestion = nil }
            return
        }
        let now = Date()
        if let s = suggestion, s.end < now || now.timeIntervalSince(s.start) > 15 * 60 { suggestion = nil }
        guard let e = candidates(now).first(where: { !asked.contains($0.id) }), Self.meetingActive(for: e) else { return }
        asked.insert(e.id)
        UserDefaults.standard.set(Array(asked).suffix(200), forKey: "autostartAsked")
        suggestion = e
        post(e)
    }

    /// The meeting app of the event is running, or another app uses the microphone (a browser call: Google Meet).
    static func meetingActive(for e: CalendarService.CalEvent) -> Bool {
        let ids = NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
        let zoom = ids.contains("us.zoom.xos"), teams = ids.contains { $0.hasPrefix("com.microsoft.teams") }
        let link = (e.link ?? "").lowercased()
        if link.contains("zoom") { return zoom || micInUse() }
        if link.contains("teams") { return teams || micInUse() }
        if link.contains("meet.google") { return micInUse() }
        return zoom || teams || micInUse()
    }

    /// The default input device is running for some app (CoreAudio). The app's own recorder is not running here (no call).
    nonisolated static func micInUse() -> Bool {
        var dev = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr, dev != 0 else { return false }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        addr.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    /// The call set up like the last one of its series (project, audience, languages, what matters).
    func model(for e: CalendarService.CalEvent) -> StartCallModel {
        if let m = UpNext.shared.items.first(where: { $0.calEventID == e.id }) { return m }
        let m = StartCallModel()
        m.applyEvent(e)
        return m
    }

    private func post(_ e: CalendarService.CalEvent) {
        let m = model(for: e)
        let c = UNMutableNotificationContent()
        c.title = L("auto.title", ["title": e.title])
        c.body = m.target.isEmpty ? L("auto.chooseProject") : L("auto.body", ["project": m.targetName])
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.idPrefix + e.id, content: c, trigger: nil))
    }

    /// Start tips (the PM's click): straight away when the project is known, otherwise the call form asks for it.
    func accept() {
        guard let e = suggestion, let app = NSApp.delegate as? AppDelegate else { return }
        suggestion = nil
        let m = model(for: e)
        if m.target.isEmpty { StartCallWindow.show(delegate: app, prepared: m); return }
        if let err = app.launch(m) { StartCallWindow.show(delegate: app, prepared: m); m.note = err }
    }

    func dismiss() { suggestion = nil }

    // A click on the notification opens the call form with this call (one more click to start: never by itself).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void) {
        let id = response.notification.request.identifier
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                NSApp.activate(ignoringOtherApps: true)
                guard id.hasPrefix(AutoStart.idPrefix), let app = NSApp.delegate as? AppDelegate else { return }
                let eid = String(id.dropFirst(AutoStart.idPrefix.count))
                if let e = CalendarService.shared.upcoming().first(where: { $0.id == eid }) {
                    AutoStart.shared.suggestion = nil
                    StartCallWindow.show(delegate: app, prepared: AutoStart.shared.model(for: e))
                }
            }
        }
        done()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}
