import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import VideoToolbox
import LiveTipsCore

/// 0.9.5 (owner, 2026-11-05): Call recording. ScreenCaptureKit gives the screen (a display or one window) and the
/// call's sound; AVCaptureSession gives the PM's microphone; both sounds are mixed into one track by their timestamps,
/// so every player and Google Drive plays them together. The file is written as it goes (AVAssetWriter, H.264 or HEVC,
/// AAC mono): a crash loses only the last seconds. Pacenote's own windows are never in the picture and its own sounds
/// never in the track. Nothing is shown or played to the other participants: consent is Settings > General > Recording consent.
/// Pause keeps one file without the paused minutes; Stop and Start in the same call make a new part (<stem>.recording-2.mp4).

enum ScreenPermission {
    static func granted() -> Bool { CGPreflightScreenCaptureAccess() }
    /// Asks macOS once (it shows its own prompt the first time); false when it was refused before.
    @discardableResult static func request() -> Bool { CGRequestScreenCaptureAccess() }
    static func openSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(u) }
    }
}

/// What a part records from.
enum RecSource: Equatable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    case soundOnly
}

/// The screens and windows a recording can take (Settings > Call recording, the window picker).
enum RecTargets {
    struct Display: Identifiable, Hashable { var id: CGDirectDisplayID; var uuid: String; var name: String; var main: Bool }
    struct Window: Identifiable, Hashable {
        var id: CGWindowID; var app: String; var bundle: String; var title: String; var width: Double; var height: Double; var pid: pid_t
        var frame: CGRect = .zero      // 2026-11-05: screen points, top-left origin (for "Show on screen")
        var label: String { title.isEmpty ? app : app + " - " + title }
    }

    static func uuid(of id: CGDirectDisplayID) -> String {
        guard let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return "\(id)" }
        return (CFUUIDCreateString(nil, u) as String?) ?? "\(id)"
    }

    static func displays() -> [Display] {
        NSScreen.screens.compactMap { s in
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(n.uint32Value)
            return Display(id: id, uuid: uuid(of: id), name: s.localizedName, main: CGDisplayIsMain(id) != 0)
        }
    }

    /// The display a setting names ("" the main one; a display that is gone falls back to the main one).
    static func display(for setting: String) -> CGDirectDisplayID {
        let all = displays()
        if !setting.isEmpty, let d = all.first(where: { $0.uuid == setting }) { return d.id }
        return all.first { $0.main }?.id ?? CGMainDisplayID()
    }

    static func scale(of id: CGDirectDisplayID) -> Double {
        let s = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
        return Double(s?.backingScaleFactor ?? 2)
    }

    /// Normal on-screen windows of other apps, large enough to be a call.
    static func windows() async -> [Window] {
        guard let c = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return c.windows.compactMap { w in
            guard let a = w.owningApplication, a.processID != me, w.windowLayer == 0, w.frame.width >= 320, w.frame.height >= 200 else { return nil }
            return Window(id: w.windowID, app: a.applicationName, bundle: a.bundleIdentifier, title: w.title ?? "",
                          width: w.frame.width, height: w.frame.height, pid: a.processID, frame: w.frame)
        }
    }

    /// 2026-11-05 (owner): a small picture of what a source records, for the picker and the tips window. Works for
    /// a window that is covered by others; Pacenote's own windows are left out of a screen.
    static func thumbnail(_ s: RecSource, width: Int) async -> CGImage? {
        guard ScreenPermission.granted(),
              let c = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return nil }
        let filter: SCContentFilter
        var size = CGSize.zero
        switch s {
        case .window(let id):
            guard let w = c.windows.first(where: { $0.windowID == id }) else { return nil }
            filter = SCContentFilter(desktopIndependentWindow: w); size = w.frame.size
        case .display(let id):
            guard let d = c.displays.first(where: { $0.displayID == id }) else { return nil }
            let me = c.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: d, excludingApplications: me, exceptingWindows: []); size = CGSize(width: d.width, height: d.height)
        case .soundOnly: return nil
        }
        guard size.width > 0, size.height > 0 else { return nil }
        let cfg = SCStreamConfiguration()
        cfg.width = width; cfg.height = max(1, Int(Double(width) * size.height / size.width)); cfg.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }

    /// A JPEG data URL of a picture, for the tips window.
    static func dataURL(_ img: CGImage?) -> String {
        guard let img = img, let d = NSBitmapImageRep(cgImage: img).representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { return "" }
        return "data:image/jpeg;base64," + d.base64EncodedString()
    }

    static func meetingWindow(in list: [Window]) -> Window? {
        let c = list.map { MeetingWindow.Candidate(id: $0.id, bundle: $0.bundle, app: $0.app, title: $0.title, width: $0.width, height: $0.height) }
        guard let b = MeetingWindow.best(c) else { return nil }
        return list.first { $0.id == b.id }
    }
}

/// The recording of the live call: state for the tips window, the menu and the call page.
final class CallRecorder: NSObject, ObservableObject {
    static let shared = CallRecorder()
    static let changed = Notification.Name("PacenoteRecordingChanged")

    /// "off", "choosing" (the window picker is open), "starting", "recording", "paused"
    @Published private(set) var state = "off"
    @Published private(set) var kind = "video"
    @Published private(set) var sourceLabel = ""
    @Published private(set) var lastNote = ""
    private(set) var transcript = ""
    private var session: RecSession?
    private var ticker: Timer?
    private var title = "", project = ""
    /// The PM turned the microphone off in the tips window: the recording takes the other side only until it is on.
    var micMuted = false { didSet { session?.setMicMuted(micMuted) } }

    var isActive: Bool { state == "recording" || state == "paused" || state == "starting" }
    /// Seconds recorded (without paused time), updated every second while a part runs.
    @Published private(set) var elapsedSec = 0
    var elapsed: Double { Double(elapsedSec) }
    private var nextPart: [String: Int] = [:]      // transcript -> the next part number (meta is written only after a part is saved)

    /// 0:42, 12:05, 1:02:09: one format for the tips window, the floating panel and the menu.
    static func clock(_ sec: Int) -> String {
        let s = max(0, sec), h = s / 3600, m = (s % 3600) / 60, x = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, x) : String(format: "%d:%02d", m, x)
    }
    var settings: RecordingSettings { AppConfig.load(from: AppPaths.config).recording }

    /// The tips window's view of the recording.
    var windowState: [String: Any] {
        ["state": state, "kind": kind, "elapsed": elapsedSec, "source": sourceLabel, "note": lastNote,
         "arm": ["kind": armKind, "app": armApp, "title": armTitle, "size": armSize, "thumb": armThumb, "ready": armSource != nil]]
    }

    // MARK: prepared before listening (2026-11-05, owner: "not at the last second")

    /// The tips window's ready state: what the recording of this call will be ("off", "audio", "video") and, for video,
    /// the window or screen. Starts from Start call / Settings; used once when listening starts (startCallRecording).
    private var armTouched = false
    private var armChosen = "off"
    private(set) var armSource: RecSource?
    private var armApp = "", armTitle = "", armSize = "", armThumb = ""
    private var armLoading = false

    var armKind: String {
        armTouched ? armChosen : ((CallEngine.shared.callRequest["recording"] as? String) ?? settings.defaultForCall)
    }

    /// Off / Sound / Sound and screen in the ready card. Video finds its source now (the call window or the screen).
    func arm(_ k: String) {
        armTouched = true
        armChosen = ["audio", "video"].contains(k) ? k : "off"
        if armChosen == "video" && armSource == nil { findArmSource() }
        publish()
    }

    /// Change in the ready card: the picker now, so nothing is asked when the call starts.
    func pickArmSource() {
        guard ScreenPermission.granted() else { ScreenPermission.request(); note(L("rec.err.permission")); return }
        Task { @MainActor in
            let list = await RecTargets.windows()
            let pre: CGWindowID? = { if case .window(let id) = self.armSource { return id }; return RecTargets.meetingWindow(in: list)?.id }()
            RecordingPicker.show(windows: list, preselect: pre) { choice in
                guard let c = choice else { return }
                self.armTouched = true; self.armChosen = "video"
                self.setArm(c.0, windows: list)
            }
        }
    }

    /// Video without a chosen source yet: the screen from Settings, else the call's window (or nothing to show).
    func findArmSource() {
        guard !armLoading, armKind == "video", armSource == nil, ScreenPermission.granted() else { return }
        armLoading = true
        Task { @MainActor in
            defer { self.armLoading = false }
            if self.settings.source == "display" {
                self.setArm(.display(RecTargets.display(for: self.settings.display)), windows: []); return
            }
            let list = await RecTargets.windows()
            if let w = RecTargets.meetingWindow(in: list) { self.setArm(.window(w.id), windows: list); return }
            // 2026-11-05: no call window open yet: the screen from Settings, so the card always shows what is recorded
            self.setArm(.display(RecTargets.display(for: self.settings.display)), windows: [])
        }
    }

    private func setArm(_ src: RecSource, windows: [RecTargets.Window]) {
        armSource = src
        switch src {
        case .window(let id):
            let w = windows.first { $0.id == id }
            armApp = w?.app ?? ""; armTitle = w?.title ?? ""; armSize = w.map { "\(Int($0.width)) × \(Int($0.height))" } ?? ""
        case .display(let id):
            let d = RecTargets.displays().first { $0.id == id }
            armApp = d?.name ?? ""; armTitle = d?.main == true ? L("rec.display.main") : ""
            armSize = Int(CGDisplayPixelsWide(id)) > 0 ? "\(CGDisplayPixelsWide(id)) × \(CGDisplayPixelsHigh(id))" : ""
        case .soundOnly: armApp = ""; armTitle = ""; armSize = ""
        }
        armThumb = ""
        publish()
        Task { @MainActor in
            let img = await RecTargets.thumbnail(src, width: 240)
            if self.armSource == src { self.armThumb = RecTargets.dataURL(img); self.publish() }
        }
    }

    /// The prepared choice, once, when listening starts (then the next call starts from Settings again).
    func takeArm() -> (kind: String, source: (RecSource, String)?) {
        let k = armKind
        let label = armTitle.isEmpty ? armApp : armApp + " - " + armTitle
        let src = armSource.map { ($0, label) }
        resetArm()
        return (k, k == "video" ? src : nil)
    }

    func resetArm() {
        armTouched = false; armChosen = "off"; armSource = nil
        armApp = ""; armTitle = ""; armSize = ""; armThumb = ""
    }

    /// Start a recording of the live call from the floating panel or the menu bar panel (the tips window has its own).
    func beginLive(kind k: String) {
        let ce = CallEngine.shared
        guard let f = ce.lastFile, !f.isEmpty, ce.isRunning else { publish(); return }
        begin(transcript: f, kind: k, title: (ce.callRequest["title"] as? String) ?? "", project: ce.projectName)
    }

    // MARK: control

    /// Starts recording the live call (kind "audio" or "video"); for video the source follows Settings (and the picker).
    func begin(transcript t: String, kind k: String, title: String, project: String, source chosen: (RecSource, String)? = nil) {
        guard !isActive, state != "choosing", !t.isEmpty else { publish(); return }
        transcript = t; kind = k == "audio" ? "audio" : "video"; self.title = title; self.project = project
        lastNote = ""
        guard ScreenPermission.granted() else {
            ScreenPermission.request()
            note(L("rec.err.permission")); return
        }
        if kind == "audio" { open(.soundOnly, label: ""); return }
        if let c = chosen { open(c.0, label: c.1); return }      // 2026-11-05: prepared in the ready state
        let s = settings
        if s.source == "display" {
            let id = RecTargets.display(for: s.display)
            open(.display(id), label: RecTargets.displays().first { $0.id == id }?.name ?? "")
            return
        }
        setState("choosing")
        Task { @MainActor in
            let list = await RecTargets.windows()
            guard self.state == "choosing" else { return }          // stopped or the call ended while the list loaded
            if s.windowPick == "auto", let w = RecTargets.meetingWindow(in: list) {
                self.setState("off"); self.open(.window(w.id), label: w.label); return
            }
            if s.windowPick == "auto" { self.note(L("rec.noCallWindow")) }
            RecordingPicker.show(windows: list, preselect: RecTargets.meetingWindow(in: list)?.id) { choice in
                guard self.state == "choosing" else { return }
                self.setState("off")
                // never start after the call is over (the picker can stay open past End call)
                guard let choice = choice, CallEngine.shared.isRunning else {
                    self.note(L("rec.cancelled")); CallEngine.shared.recordingNotStarted(); return
                }
                self.open(choice.0, label: choice.1)
            }
        }
    }

    /// Picks another window or screen for the running recording (video only); the file goes on.
    func changeSource() {
        guard isActive, kind == "video", let ses = session else { return }
        Task { @MainActor in
            let list = await RecTargets.windows()
            RecordingPicker.show(windows: list, preselect: nil) { choice in
                guard let choice = choice else { return }
                ses.switchSource(choice.0) { ok in
                    DispatchQueue.main.async {
                        if ok { self.sourceLabel = choice.1 } else { self.note(L("rec.err.source")) }
                        self.publish()
                    }
                }
            }
        }
    }

    func pause() { guard state == "recording" else { return }; session?.pause(); setState("paused"); UsageLog.log("rec_paused") }
    func resume() { guard state == "paused" else { return }; session?.resume(); setState("recording") }

    /// Stops and saves the current part. `callEnded`: the call is over (the Drive copy follows Settings).
    func stop(callEnded: Bool = false) {
        if state == "choosing" {               // the picker is open: close it, nothing was recorded
            setState("off")
            MainActor.assumeIsolated { RecordingPicker.close(nil) }
        }
        guard let ses = session else {
            if callEnded { afterCall() }
            publish()
            return
        }
        session = nil
        setState("off")
        ticker?.invalidate(); ticker = nil
        let t = transcript, label = sourceLabel
        ses.finish { part in
            DispatchQueue.main.async {
                if let p = part { self.record(p, transcript: t, label: label) }
                UsageLog.log("rec_saved", ["kind": part?.kind ?? self.kind, "minutes": Int((part?.seconds ?? 0) / 60)])
                if callEnded { self.afterCall() }
                self.publish()
            }
        }
    }

    /// Pacenote quits during a recording: the part is finished and saved before the app goes (at most `timeout` s).
    func stopAndWait(timeout: Double = 4) {
        guard session != nil else { return }
        var done = false
        let t = transcript, label = sourceLabel
        let ses = session!
        session = nil; ticker?.invalidate(); ticker = nil; state = "off"
        ses.finish { part in DispatchQueue.main.async { if let p = part { self.record(p, transcript: t, label: label) }; done = true } }
        let end = Date().addingTimeInterval(timeout)
        while !done && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
    }

    /// The call is over: stop, then copy to Drive when Settings say every recording goes there.
    func callEnded() { resetArm(); stop(callEnded: true) }

    private func afterCall() {
        let t = transcript
        guard !t.isEmpty, let meta = RecordingMeta.load(RecordingFiles.metaPath(transcript: t)), !meta.parts.isEmpty else { return }
        if settings.drive == "auto" {
            Task { @MainActor in DriveRecordings.shared.upload(transcript: t) }
        } else {
            CallEngine.shared.notify(L("rec.saved.notify", ["min": "\(Int((meta.totalSeconds / 60).rounded()))"]))
        }
    }

    // MARK: inside

    private func open(_ src: RecSource, label: String) {
        // the first free part: a part still being saved is not in the meta yet, so the number is kept here too
        var n = max(nextPart[transcript] ?? 1, (RecordingMeta.load(RecordingFiles.metaPath(transcript: transcript))?.parts.count ?? 0) + 1)
        var path = RecordingFiles.partPath(transcript: transcript, part: n, audioOnly: src == .soundOnly)
        while FileManager.default.fileExists(atPath: path) || FileManager.default.fileExists(atPath: RecordingFiles.partPath(transcript: transcript, part: n, audioOnly: src != .soundOnly)) {
            n += 1; path = RecordingFiles.partPath(transcript: transcript, part: n, audioOnly: src == .soundOnly)
        }
        nextPart[transcript] = n + 1
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let s = settings
        let req = CallEngine.shared.callRequest
        let ses = RecSession(url: URL(fileURLWithPath: path), source: src, preset: s.preset, codec: s.codec,
                             mic: s.mic ? RecSession.micDevice(req["mic_device"] as? String ?? "default") : nil)
        ses.setMicMuted(micMuted)
        session = ses
        sourceLabel = label
        setState("starting")
        ses.start { err in
            DispatchQueue.main.async {
                guard self.session === ses else { return }
                if let err = err {
                    self.session = nil; self.setState("off")
                    self.note(L("rec.err.start", ["err": err]))
                    CallEngine.shared.recordingNotStarted()
                    return
                }
                self.elapsedSec = 0
                self.setState("recording")
                UsageLog.log("rec_started", ["kind": self.kind, "source": src == .soundOnly ? "sound" : (label.isEmpty ? "display" : "chosen")])
                self.ticker?.invalidate()
                self.ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                    self.elapsedSec = Int(ses.mediaNow()); self.publish()
                }
                CallEngine.shared.recordingConsent()
            }
        }
        ses.onFailure = { msg in
            DispatchQueue.main.async { if self.session === ses { self.note(msg); self.stop() } }
        }
    }

    private func record(_ p: RecSession.Result, transcript t: String, label: String) {
        let mp = RecordingFiles.metaPath(transcript: t)
        var meta = RecordingMeta.load(mp) ?? RecordingMeta()
        if meta.title.isEmpty { meta.title = title }
        if meta.project.isEmpty { meta.project = project }
        var part = RecordingMeta.Part(file: (p.path as NSString).lastPathComponent, kind: p.kind, source: label, started: p.started)
        part.seconds = p.seconds
        part.bytes = ((try? FileManager.default.attributesOfItem(atPath: p.path))?[.size] as? NSNumber)?.int64Value ?? 0
        meta.parts.removeAll { $0.file == part.file }
        meta.parts.append(part)
        meta.save(mp)
    }

    private func setState(_ s: String) { state = s; publish() }
    private func note(_ s: String) { lastNote = s; CallEngine.shared.notify(s); publish() }
    func publish() { NotificationCenter.default.post(name: Self.changed, object: nil) }
}

/// One part being written. Everything runs on one serial queue: the capture callbacks, the mixer and the writer.
final class RecSession: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    struct Result { var path: String; var kind: String; var started: Date; var seconds: Double }

    let url: URL
    let source: RecSource
    let preset: RecordingPreset
    let codec: String
    let micDevice: AVCaptureDevice?
    var onFailure: ((String) -> Void)?
    private let q = DispatchQueue(label: "pacenote.recording")
    private var stream: SCStream?
    private var micSession: AVCaptureSession?
    private var writer: AVAssetWriter?
    private var vIn: AVAssetWriterInput?
    private var aIn: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var size = (2, 2)
    private var started = Date()
    // the media clock: seconds of recording, without the paused time
    private var t0 = 0.0, pausedTotal = 0.0, pausedAt: Double?
    private var lastVideoT = -1.0
    private var lastPixels: CVPixelBuffer?
    private var finished = false
    // the mixer: one accumulator from `written` on, two sources placed by their timestamps
    private static let rate = 48000.0
    private var acc: [Float] = []
    private var written: Int64 = 0
    private var nextIdx: [Int: Int64] = [:]
    private var converters: [Int: (AVAudioConverter, AVAudioFormat)] = [:]
    private var mixTimer: DispatchSourceTimer?
    private var micMuted = false
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
    private var audioFormat: CMAudioFormatDescription?

    init(url: URL, source: RecSource, preset: RecordingPreset, codec: String, mic: AVCaptureDevice?) {
        self.url = url; self.source = source; self.preset = preset; self.codec = codec; self.micDevice = mic
    }

    var audioOnly: Bool { source == .soundOnly }
    static func hostNow() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    /// Seconds of recording now (the paused time not counted).
    func mediaNow() -> Double { q.sync { media(Self.hostNow()) } }
    private func media(_ host: Double) -> Double {
        guard t0 > 0 else { return 0 }
        return max(0, (pausedAt ?? host) - t0 - pausedTotal)
    }

    func setMicMuted(_ on: Bool) { q.async { self.micMuted = on } }

    /// The microphone the recorder uses: the one chosen for the call; with "default" a Bluetooth headset stays with the
    /// call app and the Mac's built-in microphone is used (rules/recording.yaml > microphone).
    static func micDevice(_ setting: String) -> AVCaptureDevice? {
        let all = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        let builtin = all.first { $0.transportType == Int32(bitPattern: kAudioDeviceTransportTypeBuiltIn) }
        if setting.hasPrefix("uid:"), let d = AVCaptureDevice(uniqueID: String(setting.dropFirst(4))) { return d }
        if setting == "builtin" { return builtin ?? AVCaptureDevice.default(for: .audio) }
        let d = AVCaptureDevice.default(for: .audio)
        let bt = [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE].map { Int32(bitPattern: $0) }
        if let d = d, bt.contains(d.transportType) { return builtin ?? d }
        return d
    }

    // MARK: start

    func start(_ done: @escaping (String?) -> Void) {
        Task {
            var madeFile = false
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                let (filter, w, h) = try self.filter(for: source, content: content)
                self.size = audioOnly ? (2, 2) : preset.outputSize(width: w, height: h, scale: scaleFor(source))
                try q.sync { try self.makeWriter() }
                madeFile = true
                let cfg = self.config()
                let s = SCStream(filter: filter, configuration: cfg, delegate: self)
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: q)
                try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: q)
                try await s.startCapture()
                // Stop may have come while macOS was starting the capture: then stop it again here, nothing keeps running
                let stopped: Bool = q.sync {
                    if self.finished { return true }
                    self.stream = s
                    self.t0 = Self.hostNow(); self.started = Date()
                    self.startMic()
                    self.startMixer()
                    return false
                }
                if stopped { try? await s.stopCapture(); done(L("rec.cancelled")); return }
                done(nil)
            } catch {
                q.sync { self.finished = true; self.writer?.cancelWriting() }
                if madeFile { try? FileManager.default.removeItem(at: url) }      // only the file this part made
                done(error.localizedDescription)
            }
        }
    }

    private func scaleFor(_ s: RecSource) -> Double {
        if case .display(let id) = s { return RecTargets.scale(of: id) }
        return RecTargets.scale(of: CGMainDisplayID())
    }

    enum RecError: LocalizedError {
        case gone(String)
        var errorDescription: String? { if case .gone(let s) = self { return s }; return nil }
    }

    /// The content filter: a display without Pacenote's windows, one window, or (sound only) the main display.
    private func filter(for s: RecSource, content: SCShareableContent) throws -> (SCContentFilter, Double, Double) {
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        switch s {
        case .window(let id):
            guard let w = content.windows.first(where: { $0.windowID == id }) else { throw RecError.gone(L("rec.err.windowGone")) }
            return (SCContentFilter(desktopIndependentWindow: w), w.frame.width, w.frame.height)
        case .display(let id):
            guard let d = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else { throw RecError.gone(L("rec.err.noDisplay")) }
            return (SCContentFilter(display: d, excludingApplications: me, exceptingWindows: []), Double(d.width), Double(d.height))
        case .soundOnly:
            guard let d = content.displays.first else { throw RecError.gone(L("rec.err.noDisplay")) }
            return (SCContentFilter(display: d, excludingApplications: me, exceptingWindows: []), Double(d.width), Double(d.height))
        }
    }

    private func config() -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = size.0; c.height = size.1
        c.minimumFrameInterval = audioOnly ? CMTime(value: 1, timescale: 1) : CMTime(value: 1, timescale: CMTimeScale(preset.fps))
        c.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        c.showsCursor = true
        c.queueDepth = 6
        c.scalesToFit = true
        c.preservesAspectRatio = true
        c.capturesAudio = true
        c.sampleRate = 48000
        c.channelCount = 2
        c.excludesCurrentProcessAudio = true
        return c
    }

    private func makeWriter() throws {
        let w = try AVAssetWriter(outputURL: url, fileType: audioOnly ? .m4a : .mp4)
        w.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)   // a crash or a power cut loses at most the last seconds
        if !audioOnly {
            let props: [String: Any] = [
                AVVideoAverageBitRateKey: preset.videoKbps(codec) * 1000,
                AVVideoExpectedSourceFrameRateKey: preset.fps,
                AVVideoMaxKeyFrameIntervalDurationKey: 4,
                AVVideoProfileLevelKey: codec == "hevc" ? (kVTProfileLevel_HEVC_Main_AutoLevel as String) : AVVideoProfileLevelH264HighAutoLevel,
            ]
            let vs: [String: Any] = [AVVideoCodecKey: codec == "hevc" ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
                                     AVVideoWidthKey: size.0, AVVideoHeightKey: size.1, AVVideoCompressionPropertiesKey: props]
            let v = AVAssetWriterInput(mediaType: .video, outputSettings: vs)
            v.expectsMediaDataInRealTime = true
            v.mediaTimeScale = 600
            guard w.canAdd(v) else { throw RecError.gone(L("rec.err.codec")) }
            w.add(v); vIn = v
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: v, sourcePixelBufferAttributes: nil)
        }
        let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000,
                                                                       AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: RecordingPreset.audioKbps * 1000])
        a.expectsMediaDataInRealTime = true
        guard w.canAdd(a) else { throw RecError.gone(L("rec.err.codec")) }
        w.add(a); aIn = a
        guard w.startWriting() else { throw w.error ?? (RecError.gone(L("rec.err.codec")) as Error) }
        w.startSession(atSourceTime: .zero)
        writer = w
        var asbd = AudioStreamBasicDescription(mSampleRate: Self.rate, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
                                               mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &audioFormat)
    }

    private func startMic() {
        guard let d = micDevice, let input = try? AVCaptureDeviceInput(device: d) else { return }
        let s = AVCaptureSession()
        let out = AVCaptureAudioDataOutput()
        out.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
                             AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: true]
        out.setSampleBufferDelegate(self, queue: q)
        guard s.canAddInput(input), s.canAddOutput(out) else { return }
        s.addInput(input); s.addOutput(out)
        micSession = s
        DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }
    }

    private func startMixer() {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 0.1, repeating: 0.1)
        t.setEventHandler { [weak self] in self?.flush(lag: 0.4) }
        t.resume()
        mixTimer = t
    }

    // MARK: capture callbacks (on q)

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !finished, sb.isValid else { return }
        switch type {
        case .screen: video(sb)
        case .audio: audio(sb, source: 0)
        default: break
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !finished, !micMuted else { return }
        audio(sb, source: 1)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // macOS stopped the capture (the recorded window was closed, the permission was taken back): what is written is kept
        q.async {
            guard !self.finished else { return }
            if case .window = self.source { self.onFailure?(L("rec.err.windowGone")) } else { self.onFailure?(L("rec.err.stopped")) }
        }
    }

    private func hostTime(_ sb: CMSampleBuffer) -> Double {
        let p = CMSampleBufferGetPresentationTimeStamp(sb).seconds, now = Self.hostNow()
        return p.isFinite && abs(p - now) < 3 ? p : now      // a timestamp on another clock: the time it came
    }

    private func video(_ sb: CMSampleBuffer) {
        guard !audioOnly, pausedAt == nil, t0 > 0,
              let att = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = att[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let px = CMSampleBufferGetImageBuffer(sb), let v = vIn, let ad = adaptor else { return }
        let t = media(hostTime(sb))
        guard t > lastVideoT + 0.01, v.isReadyForMoreMediaData else { return }
        if ad.append(px, withPresentationTime: CMTime(seconds: t, preferredTimescale: 600)) { lastVideoT = t; lastPixels = px }
    }

    private func audio(_ sb: CMSampleBuffer, source: Int) {
        guard pausedAt == nil, t0 > 0, let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return }
        let n = CMSampleBufferGetNumSamples(sb)
        guard n > 0 else { return }
        var desc = asbd.pointee
        guard let inFmt = AVAudioFormat(streamDescription: &desc), let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(n)) else { return }
        inBuf.frameLength = AVAudioFrameCount(n)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(n), into: inBuf.mutableAudioBufferList) == noErr else { return }
        if converters[source]?.1 != inFmt {
            guard let c = AVAudioConverter(from: inFmt, to: target) else { return }
            c.downmix = true
            converters[source] = (c, inFmt)
        }
        guard let conv = converters[source]?.0,
              let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(n) * Self.rate / inFmt.sampleRate + 64)) else { return }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return inBuf
        }
        guard err == nil, out.frameLength > 0, let ch = out.floatChannelData?[0] else { return }
        // where these samples go on the recording's timeline; a small jump keeps the source continuous (no clicks)
        var idx = Int64((media(hostTime(sb)) * Self.rate).rounded())
        if let nx = nextIdx[source], abs(idx - nx) < 2400 { idx = nx }
        let count = Int(out.frameLength)
        nextIdx[source] = idx + Int64(count)
        place(UnsafeBufferPointer(start: ch, count: count), at: idx)
    }

    private func place(_ s: UnsafeBufferPointer<Float>, at idx: Int64) {
        var from = 0, pos = idx - written
        if pos < 0 { from = Int(-pos); pos = 0 }       // too late for what was written already
        guard from < s.count else { return }
        let end = Int(pos) + (s.count - from)
        if end > acc.count { acc.append(contentsOf: repeatElement(0, count: end - acc.count)) }
        var j = Int(pos)
        for i in from..<s.count { acc[j] += s[i]; j += 1 }
    }

    /// Writes the mixed sound up to `lag` seconds before now (late buffers still find their place).
    private func flush(lag: Double) {
        guard !finished, pausedAt == nil, t0 > 0, let a = aIn, let fmt = audioFormat else { return }
        let upto = Int64(((media(Self.hostNow()) - lag) * Self.rate).rounded())
        let n = Int(upto - written)
        guard n > 0, a.isReadyForMoreMediaData else { return }
        if acc.count < n { acc.append(contentsOf: repeatElement(0, count: n - acc.count)) }
        var chunk = Array(acc[0..<n])
        acc.removeFirst(n)
        // a soft limit above 0.8: the call and the microphone together stay under full scale without a hard clip
        for i in 0..<chunk.count {
            let x = chunk[i], m = abs(x)
            if m > 0.8 { chunk[i] = (x < 0 ? -1 : 1) * (0.8 + 0.2 * tanhf((m - 0.8) / 0.2)) }
        }
        let bytes = n * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block) == noErr,
              let bb = block else { return }
        chunk.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: bytes) }
        var out: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: bb, formatDescription: fmt, sampleCount: n,
                                                                   presentationTimeStamp: CMTime(value: written, timescale: 48000),
                                                                   packetDescriptions: nil, sampleBufferOut: &out) == noErr, let o = out else { return }
        if a.append(o) { written += Int64(n) }
    }

    // MARK: pause, source, finish

    func pause() {
        q.async {
            guard self.pausedAt == nil else { return }
            self.flush(lag: 0)
            self.pausedAt = Self.hostNow()
        }
    }

    func resume() {
        q.async {
            guard let p = self.pausedAt else { return }
            self.pausedTotal += Self.hostNow() - p
            self.pausedAt = nil
            self.acc.removeAll(); self.nextIdx.removeAll()
        }
    }

    func switchSource(_ s: RecSource, _ done: @escaping (Bool) -> Void) {
        guard let st = q.sync(execute: { stream }) else { done(false); return }
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
                let (f, _, _) = try self.filter(for: s, content: content)
                try await st.updateContentFilter(f)
                done(true)
            } catch { done(false) }
        }
    }

    /// Ends the part: on the queue, so it never races `start`. The writer is closed at once (the callbacks stop
    /// counting when `finished` is set); the capture and the microphone are stopped in the background.
    func finish(_ done: @escaping (Result?) -> Void) {
        q.async {
            guard !self.finished else { done(nil); return }
            self.flush(lag: 0)
            let end = self.media(Self.hostNow())
            self.finished = true
            self.mixTimer?.cancel()
            let st = self.stream, mic = self.micSession
            self.stream = nil; self.micSession = nil
            if mic != nil || st != nil {
                Task.detached { mic?.stopRunning(); try? await st?.stopCapture() }
            }
            guard let w = self.writer, self.t0 > 0 else { self.writer?.cancelWriting(); done(nil); return }   // still starting: nothing recorded
            if let v = self.vIn, let ad = self.adaptor, let px = self.lastPixels, end > self.lastVideoT + 0.05, v.isReadyForMoreMediaData {
                _ = ad.append(px, withPresentationTime: CMTime(seconds: end, preferredTimescale: 600))   // the last picture lasts to the end
            }
            self.vIn?.markAsFinished(); self.aIn?.markAsFinished()
            w.endSession(atSourceTime: CMTime(seconds: end, preferredTimescale: 600))
            let r = Result(path: self.url.path, kind: self.audioOnly ? "audio" : "video", started: self.started, seconds: end)
            w.finishWriting {
                if w.status == .completed { done(r) } else { done(end > 1 ? r : nil) }
            }
        }
    }
}

// MARK: - 0.9.5 QA: `Pacenote.app --args --rec-bench <dir> [seconds]` records the main screen for `seconds` (15) with
// every quality and format, and sound only, and writes <dir>/bench.json (bytes, MB an hour). The files stay for a look.
enum RecBench {
    static func run(out: String, seconds: Double) {
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        var cases: [(String, RecSource, RecordingPreset, String)] = []
        for p in RecordingPreset.all { for c in ["h264", "hevc"] { cases.append((p.id + "-" + c, .display(CGMainDisplayID()), p, c)) } }
        cases.append(("sound", .soundOnly, RecordingPreset.find("standard"), "h264"))
        var rows: [[String: Any]] = []
        func next(_ i: Int) {
            guard i < cases.count else {
                let d = (try? JSONSerialization.data(withJSONObject: ["permission": ScreenPermission.granted(), "seconds": seconds, "runs": rows],
                                                     options: [.prettyPrinted, .sortedKeys])) ?? Data()
                try? d.write(to: URL(fileURLWithPath: out + "/bench.json"))
                exit(0)
            }
            let c = cases[i]
            let url = URL(fileURLWithPath: out + "/" + c.0 + (c.1 == .soundOnly ? ".m4a" : ".mp4"))
            try? FileManager.default.removeItem(at: url)
            let s = RecSession(url: url, source: c.1, preset: c.2, codec: c.3, mic: nil)
            s.start { err in
                if let e = err { rows.append(["case": c.0, "error": e]); DispatchQueue.main.async { next(i + 1) }; return }
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    s.finish { r in
                        let b = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.doubleValue ?? 0
                        let sec = r?.seconds ?? seconds
                        rows.append(["case": c.0, "bytes": Int(b), "seconds": sec, "mbPerHour": Int((b / max(sec, 1) * 3600 / 1_000_000).rounded()),
                                     "presetMaxMBPerHour": c.1 == .soundOnly ? RecordingPreset.audioMBPerHour : c.2.mbPerHour(c.3)])
                        DispatchQueue.main.async { next(i + 1) }
                    }
                }
            }
        }
        if !ScreenPermission.granted() { ScreenPermission.request() }
        next(0)
        RunLoop.main.run()
    }
}
