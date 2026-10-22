// The tips window of LiveTips.app: the same prompter.html as the skill's live-transcriber
// (shared UI, parity), hosted in a WKWebView. Ported from live-transcriber src/prompter.swift;
// the message bridge (ask, pin, opacity, ready, mute, setting, stealth) is unchanged.

import AppKit
import WebKit

struct PrompterArgs {
    var tips = ""
    var inbox = ""
    var status = ""
    var html = ""
    var control = ""
    var title = "Live Tips (app)"
    var demo = false
}

/// Reads only the lines appended to a file since the previous call.
final class TailReader {
    let path: String
    private var offset: UInt64 = 0
    private var buffer = Data()

    init(path: String) { self.path = path }

    func newLines() -> [String] {
        guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        if size < offset { offset = 0; buffer = Data() }   // file was replaced
        if size == offset { return [] }
        try? fh.seek(toOffset: offset)
        let data = fh.readDataToEndOfFile()
        offset += UInt64(data.count)
        buffer.append(data)
        var lines: [String] = []
        while let r = buffer.range(of: Data([0x0A])) {
            let lineData = buffer.subdata(in: buffer.startIndex..<r.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<r.upperBound)
            if let s = String(data: lineData, encoding: .utf8),
               !s.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append(s)
            }
        }
        return lines
    }
}

func isJSONObject(_ s: String) -> Bool {
    guard let d = s.data(using: .utf8),
          let o = try? JSONSerialization.jsonObject(with: d) else { return false }
    return o is [String: Any]
}

func nowHMS() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: Date())
}

func appendLine(_ line: String, to path: String) {
    let data = (line + "\n").data(using: .utf8)!
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
    }
    guard let fh = FileHandle(forWritingAtPath: path) else { return }
    defer { try? fh.close() }
    _ = try? fh.seekToEnd()
    fh.write(data)
}

func jsonLine(_ obj: [String: Any]) -> String {
    guard let d = try? JSONSerialization.data(withJSONObject: obj),
          let s = String(data: d, encoding: .utf8) else { return "{}" }
    return s
}

@MainActor
final class PrompterController: NSObject, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    let args: PrompterArgs
    var window: NSWindow!
    var web: WKWebView!
    var tips: TailReader?
    var pageReady = false
    var pending: [String] = []
    var lastStatus = ""
    var ticks = 0
    var isSplit = false              // presentation split view: slide cards on one side, tips on the other
    var baseWidth: CGFloat = 0       // window width before the split, restored when it ends
    var grewRight = false            // the side the window grew to (the slides side)

    init(args: PrompterArgs) { self.args = args }

    func show() {

        let uc = WKUserContentController()
        for name in ["ask", "pin", "opacity", "ready", "mute", "setting", "stealth", "split"] { uc.add(self, name: name) }
        let cfg = WKWebViewConfiguration()
        cfg.userContentController = uc

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w: CGFloat = 520, h: CGFloat = 420     // v36: taller default, the redesign has a dock and an action row
        let rect = NSRect(x: screen.midX - w / 2, y: screen.maxY - h - 6, width: w, height: h)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = args.title
        window.titlebarAppearsTransparent = true   // the title bar blends with the page background
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.sharingType = .none          // ask macOS to keep the window out of screen capture
        window.isMovableByWindowBackground = true
        window.alphaValue = 0.94
        window.minSize = NSSize(width: 300, height: 140)
        window.delegate = self
        window.isReleasedWhenClosed = false
        _ = window.setFrameAutosaveName("LiveTipsAppPrompter")   // remembers position and size
        addEndCallButton()

        web = WKWebView(frame: NSRect(origin: .zero, size: rect.size), configuration: cfg)
        web.navigationDelegate = self
        web.autoresizingMask = [.width, .height]
        window.contentView = web
        let url = URL(fileURLWithPath: args.html)
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if !args.tips.isEmpty { tips = TailReader(path: args.tips) }
        Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(tick),
                             userInfo: nil, repeats: true)
    }

    @objc func tick() {
        if let t = tips {
            let lines = t.newLines().filter(isJSONObject)
            if !lines.isEmpty { push("window.addItems([" + lines.joined(separator: ",") + "])") }
        }
        ticks += 1
        if ticks % 4 == 0, !args.status.isEmpty,
           let s = try? String(contentsOfFile: args.status, encoding: .utf8),
           s != lastStatus, isJSONObject(s) {
            lastStatus = s
            push("window.setStatus(" + s + ")")
        }
    }

    func push(_ js: String) {
        if pageReady {
            web.evaluateJavaScript(js, completionHandler: nil)
        } else {
            pending.append(js)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        let queued = pending
        pending.removeAll()
        for js in queued { web.evaluateJavaScript(js, completionHandler: nil) }
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        switch message.name {
        case "ask":
            guard let text = message.body as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !args.inbox.isEmpty else { return }
            appendLine(jsonLine(["t": nowHMS(), "text": text]), to: args.inbox)
            if args.demo, !args.tips.isEmpty {
                appendLine(jsonLine(["t": nowHMS(), "kind": "answer", "level": "info", "q": text,
                                     "gist": "Demo: question received",
                                     "phrase": "On a real call the answer appears here."]),
                           to: args.tips)
            }
        case "pin":
            let on = (message.body as? Bool) ?? true
            window.level = on ? .floating : .normal
        case "stealth":
            // v37: the PM can switch stealth off to share or screenshot the window (default on).
            let on = (message.body as? Bool) ?? true
            window.sharingType = on ? .none : .readOnly
        case "opacity":
            if let v = message.body as? Double { window.alphaValue = CGFloat(max(0.35, min(1.0, v))) }
        case "mute":
            // The recorder checks this file twice a second and stops transcribing the mic.
            let on = (message.body as? Bool) ?? false
            guard !args.control.isEmpty else { return }
            let path = (args.control as NSString).appendingPathComponent("mic_muted")
            if on {
                FileManager.default.createFile(atPath: path, contents: Data())
            } else {
                try? FileManager.default.removeItem(atPath: path)
            }
        case "split":
            // Presentation mode with slide cards: the page asks for a window twice as wide. It grows
            // towards the cards, so the tips stream stays where the PM put it.
            // Body: Bool (grow left), or {"on": Bool, "grow": "left" | "right"} after the PM swapped the sides.
            if let d = message.body as? [String: Any] {
                setSplit((d["on"] as? Bool) ?? false, growRight: (d["grow"] as? String) == "right", animate: true)
            } else {
                setSplit((message.body as? Bool) ?? false, growRight: false, animate: true)
            }
        case "setting":
            // {"key": ..., "value": ...} -> the skill reads it from the inbox as @@SET key=value
            guard let d = message.body as? [String: Any], let key = d["key"] as? String,
                  !args.inbox.isEmpty else { return }
            appendLine(jsonLine(["t": nowHMS(), "kind": "setting", "key": key, "value": d["value"] ?? NSNull()]),
                       to: args.inbox)
        default:
            break
        }
    }

    func setSplit(_ on: Bool, growRight: Bool = false, animate: Bool) {
        guard on != isSplit, let window = window else { return }
        isSplit = on
        let vis = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        var f = window.frame
        if on {
            baseWidth = f.width
            grewRight = growRight
            let w = min(f.width * 2, vis.width)
            if !growRight { f.origin.x -= (w - f.width) }
            f.size.width = w
        } else {
            let w = baseWidth > 0 ? baseWidth : f.width / 2
            if !grewRight { f.origin.x += (f.width - w) }
            f.size.width = w
        }
        if f.minX < vis.minX { f.origin.x = vis.minX }
        if f.maxX > vis.maxX { f.origin.x = max(vis.minX, vis.maxX - f.width) }
        window.setFrame(f, display: true, animate: animate)
    }

    /// Back to the normal width before the frame is saved, so the next call does not open twice as wide.
    func windowWillClose(_ notification: Notification) { setSplit(false, animate: false) }

    /// "End call" in the window's title bar: stops the recording; the transcript and tips stay in the project folder.
    var endButton: NSButton?
    func addEndCallButton() {
        let b = NSButton(title: "End call", target: self, action: #selector(endCallClicked))
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        b.contentTintColor = .systemRed
        b.toolTip = "Stop recording this call"
        b.sizeToFit()
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: b.frame.width + 12, height: 28))
        b.frame.origin = NSPoint(x: 4, y: (28 - b.frame.height) / 2)
        holder.addSubview(b)
        let acc = NSTitlebarAccessoryViewController()
        acc.view = holder
        acc.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(acc)
        endButton = b
    }

    @objc func endCallClicked() {
        guard CallEngine.shared.isRunning else { window.close(); return }
        let a = NSAlert()
        a.messageText = "End the call?"
        a.informativeText = "Recording stops; the transcript and tips stay in the project folder."
        a.addButton(withTitle: "End call")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn { CallEngine.shared.stop() }
    }
}
