import AppKit
import CoreAudio
import Darwin
import UserNotifications
import LiveTipsCore

/// 2026-11-10 (owner): hanging up in the meeting ends the call in Pacenote, the way Notion stops its notes, with a
/// short grace in case the guess is wrong. The signal is not silence: while you are in a meeting, Zoom, Teams, Meet in
/// the browser or the Meet app keeps the microphone open, also when you are muted, quiet or away from the Mac. Hanging
/// up closes it. Every 2 s the app asks CoreAudio which processes capture from a microphone (macOS 14.4+: the process
/// objects). Once another app has held it for 10 s during the call, 4 s without it (a device switch takes about 1 s)
/// show "The meeting has ended? Stopping in 5 s" (2026-11-11, owner: was 10 s) in the tips window and as a notification, both with Keep recording.
/// The microphone coming back hides it; otherwise the call stops as End call does. Pacenote's own recorder and screen
/// recording never count; a call with no meeting app (in person) is never stopped. Settings > Integrations >
/// Calendars > "Stop the call when the meeting ends" (on by default).
@MainActor
final class MeetingEndWatch {
    static let shared = MeetingEndWatch()
    static let defaultsKey = "meetingEndStop"
    static let notificationId = "pn-meetend"
    static let category = "pn-meetend-cat"
    static let keepAction = "pn-meetend-keep"
    static let step: TimeInterval = 2
    static let meetingSeen: TimeInterval = 10   // another app held the microphone this long: there is a meeting
    static let releasedFor: TimeInterval = 4    // it let go for this long: ask
    static let grace: TimeInterval = 5          // then stop, unless the microphone comes back or the PM keeps recording

    var enabled: Bool { UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? true }
    private var timer: Timer?
    private var callKey = ""
    private var seen: TimeInterval = 0
    private var releasedSince: Date?
    private var asking = false
    private var done = false

    func start() {
        let keep = UNNotificationAction(identifier: Self.keepAction, title: L("meetend.keep"), options: [])
        let cat = UNNotificationCategory(identifier: Self.category, actions: [keep], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().getNotificationCategories { have in
            UNUserNotificationCenter.current().setNotificationCategories(have.filter { $0.identifier != MeetingEndWatch.category }.union([cat]))
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.step, repeats: true) { _ in MainActor.assumeIsolated { MeetingEndWatch.shared.tick() } }
    }

    func tick() {
        let st = EngineStatus.load(path: CallEngine.shared.statusPath)
        let live = CallEngine.shared.isRunning || ["recording", "standby"].contains(st.state)
        guard enabled, live else { if asking { hideAsk() }; callKey = ""; return }
        let key = CallEngine.shared.appTipsFile ?? st.tipsFile ?? ""
        if key != callKey { if asking { hideAsk() }; callKey = key; seen = 0; releasedSince = nil; done = false }
        if done { return }
        if Self.otherAppsUseMicrophone() {
            seen += Self.step; releasedSince = nil
            if asking { hideAsk() }
            return
        }
        guard seen >= Self.meetingSeen else { return }
        let now = Date()
        guard let r = releasedSince else { releasedSince = now; return }
        let quiet = now.timeIntervalSince(r)
        if quiet >= Self.releasedFor + Self.grace { stop(); return }
        if quiet >= Self.releasedFor { showAsk(left: Int((Self.releasedFor + Self.grace - quiet).rounded(.up))) }
    }

    /// Keep recording (the tips window or the notification): no more questions on this call.
    func keepRecording() {
        guard asking else { return }
        done = true; hideAsk()
        UsageLog.log("meeting_end", ["action": "keep"])
    }

    func stopNow() { guard asking else { return }; stop() }

    private func stop() {
        hideAsk()
        done = true
        UsageLog.log("meeting_end", ["action": "stop"])
        CallEngine.shared.stop()
    }

    private func showAsk(left: Int) {
        (NSApp.delegate as? AppDelegate)?.tips?.push("window.LiveTips && LiveTips.setMeetEnd({left: \(max(0, left))})")
        guard !asking else { return }
        asking = true
        UsageLog.log("meeting_end", ["action": "ask"])
        let c = UNMutableNotificationContent()
        c.title = L("meetend.notif.title")
        c.body = L("meetend.notif.body", ["n": "\(Int(Self.grace))"])
        c.categoryIdentifier = Self.category
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.notificationId, content: c, trigger: nil))
    }

    private func hideAsk() {
        asking = false
        (NSApp.delegate as? AppDelegate)?.tips?.push("window.LiveTips && LiveTips.setMeetEnd(null)")
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationId])
    }

    /// Some process other than Pacenote and its recorder is capturing from an input device. When CoreAudio cannot
    /// say, the answer is yes: a call is never stopped on a guess.
    nonisolated static func otherAppsUseMicrophone() -> Bool {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return true }
        var objs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &objs) == noErr else { return true }
        let me = getpid()
        for o in objs {
            var running: UInt32 = 0
            var s = UInt32(MemoryLayout<UInt32>.size)
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                               mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(o, &a, 0, nil, &s, &running) == noErr else { return true }
            if running == 0 { continue }
            var pid: pid_t = 0
            s = UInt32(MemoryLayout<pid_t>.size)
            a.mSelector = kAudioProcessPropertyPID
            guard AudioObjectGetPropertyData(o, &a, 0, nil, &s, &pid) == noErr else { return true }
            if pid == me || isOurs(pid, me: me) { continue }
            return true
        }
        return false
    }

    /// Pacenote's own processes: a child of the app (the recorder, audiocap) or a binary from its folders.
    nonisolated static func isOurs(_ pid: pid_t, me: pid_t) -> Bool {
        var p = pid
        for _ in 0..<6 {
            var info = proc_bsdinfo()
            let n = proc_pidinfo(p, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
            guard n == Int32(MemoryLayout<proc_bsdinfo>.size) else { break }
            let parent = pid_t(info.pbi_ppid)
            if parent == me { return true }
            if parent <= 1 { break }
            p = parent
        }
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return false }
        let path = String(cString: buf)
        return path.contains("/Pacenote.app/") || path.contains("/LiveTips.app/") || path.contains("/Tools/LiveTips/")
            || path.contains("/live-transcriber/")
    }
}
