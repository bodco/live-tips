// prompter - the live-tips teleprompter window.
//
// A small always-on-top window that shows the tips the live-tips skill writes into
// <transcript>.tips.jsonl and sends the PM's typed questions to <transcript>.inbox.jsonl.
// It can be moved, resized, minimised and closed like any window. It asks macOS to keep
// it out of screen sharing (NSWindow.sharingType = .none); whether a given app honours
// that depends on how it captures the screen, so check it once with your meeting app.
//
//   prompter --tips FILE --inbox FILE --status FILE --html FILE [--control DIR] [--title T]
//   prompter --demo        sample tips, typed questions get a demo answer
//
// Launched by transcriber.py when a recording starts. Closing the window does not stop
// the recording.

import AppKit
import WebKit

struct Args {
    var tips = ""
    var inbox = ""
    var status = ""
    var html = ""
    var control = ""      // live-transcriber control dir: the mute button writes mic_muted here
    var title = "Суфлер"
    var demo = false
}

func parseArgs() -> Args {
    var a = Args()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let k = it.next() {
        switch k {
        case "--tips": a.tips = it.next() ?? ""
        case "--inbox": a.inbox = it.next() ?? ""
        case "--status": a.status = it.next() ?? ""
        case "--html": a.html = it.next() ?? ""
        case "--control": a.control = it.next() ?? ""
        case "--title": a.title = it.next() ?? a.title
        case "--demo": a.demo = true
        default: break
        }
    }
    let root = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent()
    if a.html.isEmpty { a.html = root.appendingPathComponent("src/prompter.html").path }
    if a.demo {
        let tmp = NSTemporaryDirectory()
        a.tips = tmp + "live-tips-demo.tips.jsonl"
        a.inbox = tmp + "live-tips-demo.inbox.jsonl"
        a.title = "Суфлер (демо)"
        let demo = [
            #"{"t":"10:30:05","kind":"checklist","level":"info","gist":"Чекліст мітингу","items":["Статус релізу","Нова вимога від клієнта","Рішення по даті"]}"#,
            #"{"t":"10:31:40","kind":"tip","level":"red","gist":"🔴 Нова вимога. Не погоджуй зараз.","phrase":"Good idea. I will write it down. We will check it and come back to you."}"#,
            #"{"t":"10:33:12","kind":"tip","level":"red","gist":"🔴 Твоя черга: апдейт","phrase":"Short update from my side. We are on track.","items":["Transaction report is in testing","Payments: waiting for the client","We need a decision on the release date"]}"#,
            #"{"kind":"slides","title":"Демо","total_min":3,"slides":[{"n":1,"title":"Титул","who":"shared","sec":30,"body":[{"k":"p","t":"Добрий день. Сьогодні покажемо результати ресерчу."}]},{"n":2,"title":"Ринок","who":"other","speaker":"Sarah","sec":60,"body":[{"k":"h","t":"Sarah: обсяг ринку і болі."},{"k":"c","t":"Її репліка перед твоїм виходом: «Богдане, тобі слово.»"}]},{"n":3,"title":"Що ми пропонуємо","who":"me","sec":90,"body":[{"k":"p","t":"Три шляхи, і чому ми пропонуємо третій."},{"k":"s","t":"Абзац, який можна пропустити, якщо відстаєш."},{"k":"h","t":"Підказка, яку не читаєш уголос."}]}]}"#,
        ]
        try? (demo.joined(separator: "\n") + "\n").write(toFile: a.tips, atomically: true, encoding: .utf8)
        try? "".write(toFile: a.inbox, atomically: true, encoding: .utf8)
    }
    return a
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
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    let args: Args
    var window: NSWindow!
    var web: WKWebView!
    var tips: TailReader?
    var pageReady = false
    var pending: [String] = []
    var lastStatus = ""
    var ticks = 0
    var isSplit = false              // presentation split view: slide cards left, tips right
    var baseWidth: CGFloat = 0       // window width before the split, restored when it ends
    var grewRight = false            // the side the window grew to (the slides side)

    init(args: Args) { self.args = args }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

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
        window.alphaValue = 1.0                 // opacity fades the page backgrounds only (text stays readable)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 300, height: 140)
        window.delegate = self
        window.isReleasedWhenClosed = false
        _ = window.setFrameAutosaveName("LiveTipsPrompter")   // remembers position and size

        web = WKWebView(frame: NSRect(origin: .zero, size: rect.size), configuration: cfg)
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")   // the page's own background can be see-through
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

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Закрити суфлер", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let winItem = NSMenuItem()
        main.addItem(winItem)
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = win
        NSApp.mainMenu = main
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
        web.evaluateJavaScript("window.enableGlass && window.enableGlass()", completionHandler: nil)
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
                                     "gist": "Демо: питання отримано",
                                     "phrase": "У справжньому дзвінку тут буде відповідь скіла."]),
                           to: args.tips)
            }
        case "pin":
            let on = (message.body as? Bool) ?? true
            window.level = on ? .floating : .normal
        case "stealth":
            // v37: the PM can switch stealth off to share or screenshot the window (default on).
            let on = (message.body as? Bool) ?? true
            window.sharingType = on ? .none : .readOnly
        case "split":
            // Presentation mode with slide cards: the page asks for a window twice as wide. It grows
            // to the left, so the tips stream stays where the PM put it (under the camera).
            // Body: Bool (grow left), or {"on": Bool, "grow": "left" | "right"} when the PM swapped the sides.
            if let d = message.body as? [String: Any] {
                setSplit((d["on"] as? Bool) ?? false, growRight: (d["grow"] as? String) == "right", animate: true)
            } else {
                setSplit((message.body as? Bool) ?? false, growRight: false, animate: true)
            }
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

    // Save the normal (single) width, so the next call does not open twice as wide.
    func windowWillClose(_ notification: Notification) { setSplit(false, animate: false) }
    func applicationWillTerminate(_ notification: Notification) { setSplit(false, animate: false) }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let parsed = parseArgs()
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = AppDelegate(args: parsed)
    app.delegate = delegate
    app.run()
    _ = delegate   // keep the delegate alive for the whole run
}
