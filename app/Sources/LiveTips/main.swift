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

final class AppDelegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        it.button?.title = "LT"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "LiveTips M0 (mic: \(micStatus()))", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Request microphone access", action: #selector(requestMic), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for m in menu.items where m.action == #selector(requestMic) { m.target = self }
        it.menu = menu
        item = it
    }

    @objc func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }
}

let args = CommandLine.arguments
if args.contains("--probe") {
    probe(request: args.contains("--request"))
    exit(0)
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
