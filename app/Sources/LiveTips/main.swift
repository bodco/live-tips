import AppKit
import AVFoundation
import LiveTipsCore

// M0 skeleton. `LiveTips --probe` prints permission state as JSON and exits (used by the TCC
// persistence test across two signed builds). Without arguments it runs as a menu bar app.

func micStatus() -> String {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return "authorized"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "not_determined"
    @unknown default: return "unknown"
    }
}

func probe(request: Bool) {
    let info = Bundle.main.infoDictionary ?? [:]
    var out: [String: Any] = [
        "bundle_id": Bundle.main.bundleIdentifier ?? "none",
        "version": info["CFBundleShortVersionString"] ?? "dev",
        "build": info["CFBundleVersion"] ?? "dev",
        "mic": micStatus(),
    ]
    if request && micStatus() == "not_determined" {
        let sem = DispatchSemaphore(value: 0)
        AVCaptureDevice.requestAccess(for: .audio) { _ in sem.signal() }
        _ = sem.wait(timeout: .now() + 60)
        out["mic_after_request"] = micStatus()
    }
    if let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]),
       let s = String(data: data, encoding: .utf8) {
        print(s)
    }
}


/// Runs the bundled audiocap helper for each source and reports bytes captured and its log tail.
/// Launch through LaunchServices (`open -W LiveTips.app --args --capture-test 5`) so that macOS
/// attributes the permission prompts to LiveTips and not to Terminal.
func captureTest(seconds: Int) {
    let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/audiocap").path
    var out: [String: Any] = ["mic_permission": micStatus(), "seconds": seconds]
    for source in ["mic", "system"] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: helper)
        p.arguments = ["--source", source, "--seconds", String(seconds)]
        let so = Pipe(), se = Pipe()
        p.standardOutput = so
        p.standardError = se
        var bytes = 0
        var peak: Float = 0
        do {
            try p.run()
            let data = so.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            bytes = data.count
            data.withUnsafeBytes { raw in
                for v in raw.bindMemory(to: Float.self) where abs(v) > peak { peak = abs(v) }
            }
            let err = String(data: se.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            out[source] = ["bytes": bytes, "peak": Double(peak), "exit": Int(p.terminationStatus),
                           "log_tail": Array(err.split(separator: "\n").suffix(4)).map(String.init)]
        } catch {
            out[source] = ["error": "\(error)"]
        }
    }
    out["mic_permission_after"] = micStatus()
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/LiveTips")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .prettyPrinted]) {
        try? data.write(to: dir.appendingPathComponent("capture-test.json"))
        print(String(data: data, encoding: .utf8) ?? "")
    }
}

/// Stealth test: a floating window like the prompter, excluded from screen sharing and screenshots
/// (`sharingType = .none`, best effort). `--stealth-window off` shows the same window shareable.
final class StealthDelegate: NSObject, NSApplicationDelegate {
    let hidden: Bool
    var window: NSWindow?
    init(hidden: Bool) { self.hidden = hidden }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let w = NSPanel(contentRect: NSRect(x: 200, y: 600, width: 420, height: 160),
                        styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        w.title = "LiveTips stealth test"
        w.level = .floating
        w.sharingType = hidden ? .none : .readOnly
        let label = NSTextField(labelWithString: hidden
            ? "STEALTH ON: this window should NOT appear\nin screen sharing or screenshots."
            : "STEALTH OFF: this window SHOULD appear\nin screen sharing and screenshots.")
        label.font = .systemFont(ofSize: 18, weight: .semibold)
        label.frame = NSRect(x: 20, y: 50, width: 380, height: 60)
        w.contentView?.addSubview(label)
        w.makeKeyAndOrderFront(nil)
        window = w
    }
}

/// `--prompter` hosts the tips window for given files; `--prompter-demo` shows sample tips.
final class PrompterAppDelegate: NSObject, NSApplicationDelegate {
    let pargs: PrompterArgs
    var controller: PrompterController?
    init(pargs: PrompterArgs) { self.pargs = pargs }
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let c = PrompterController(args: pargs)
            c.show()
            controller = c
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

func prompterArgs(_ args: [String]) -> PrompterArgs {
    var a = PrompterArgs()
    var it = args.dropFirst().makeIterator()
    while let k = it.next() {
        switch k {
        case "--tips": a.tips = it.next() ?? ""
        case "--inbox": a.inbox = it.next() ?? ""
        case "--status": a.status = it.next() ?? ""
        case "--html": a.html = it.next() ?? ""
        case "--control": a.control = it.next() ?? ""
        case "--title": a.title = it.next() ?? a.title
        case "--prompter-demo": a.demo = true
        default: break
        }
    }
    if a.html.isEmpty, let res = Bundle.main.resourceURL?.appendingPathComponent("prompter.html").path {
        a.html = res
    }
    if a.demo {
        let tmp = NSTemporaryDirectory()
        a.tips = tmp + "livetips-app-demo.tips.jsonl"
        a.inbox = tmp + "livetips-app-demo.inbox.jsonl"
        a.title = "Live Tips (app, demo)"
        let demo = [
            #"{"t":"10:30:05","kind":"checklist","level":"info","gist":"Meeting checklist","items":["Release status","New client request","Decision on the date"]}"#,
            #"{"t":"10:31:40","src":"10:31:36","kind":"tip","level":"red","gist":"🔴 New requirement. Do not agree now.","phrase":"Good idea. I will write it down. We will check it and come back to you.","engine":"app"}"#,
            #"{"t":"10:33:12","src":"10:33:08","kind":"tip","level":"orange","gist":"🟠 Fix the owner and the date","phrase":"So, Alex checks the export by Friday. Is that right?","engine":"app"}"#,
        ]
        try? (demo.joined(separator: "\n") + "\n").write(toFile: a.tips, atomically: true, encoding: .utf8)
        try? "".write(toFile: a.inbox, atomically: true, encoding: .utf8)
    }
    return a
}

let args = CommandLine.arguments
if args.contains("--prompter") || args.contains("--prompter-demo") {
    let app = NSApplication.shared
    let d = PrompterAppDelegate(pargs: prompterArgs(args))
    app.delegate = d
    app.setActivationPolicy(.regular)
    app.run()
}
if let i = args.firstIndex(of: "--stealth-window") {
    let hidden = !(i + 1 < args.count && args[i + 1] == "off")
    let app = NSApplication.shared
    let d = StealthDelegate(hidden: hidden)
    app.delegate = d
    app.setActivationPolicy(.regular)
    app.run()
}
if let i = args.firstIndex(of: "--capture-test") {
    let n = i + 1 < args.count ? Int(args[i + 1]) ?? 5 : 5
    captureTest(seconds: n)
    exit(0)
}
if args.contains("--probe") {
    probe(request: args.contains("--request"))
    exit(0)
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
