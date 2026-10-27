// The tips window of LiveTips.app: the same prompter.html as the skill's live-transcriber
// (shared UI, parity), hosted in a WKWebView. Ported from live-transcriber src/prompter.swift;
// the message bridge (ask, pin, opacity, ready, mute, setting, stealth) is unchanged.

import AppKit
import WebKit
import LiveTipsCore

struct PrompterArgs {
    var tips = ""
    var inbox = ""
    var status = ""
    var html = ""
    var control = ""
    var title = "Live Tips (app)"
    var demo = false
    var demoPresentation = false
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
    var deckWide = false             // the page wants the slide cards next to the tips
    var trWide = false               // 2026-10-26: the transcript pane is open next to the tips
    var deckGrowRight = false
    var transcript: TailReader?      // the call's transcript (.md), pushed to the transcript pane
    var transcriptPath = ""
    var speakersMtime: Date?
    var lastPrep = ""
    var ticker: Timer?               // stopped when the window closes (QA: closed windows kept reading files)

    init(args: PrompterArgs) { self.args = args }

    func show() {

        let uc = WKUserContentController()
        for name in ["ask", "pin", "opacity", "ready", "mute", "setting", "stealth", "split", "transcript", "pref", "rename", "upnext"] { uc.add(self, name: name) }
        // The remembered window settings, before the page's own script runs.
        var prefs = UserDefaults.standard.dictionary(forKey: "prompterPrefs") ?? [:]
        // 2026-10-27 (owner): one interface language for the whole app: the window follows Settings > General.
        prefs["ui_lang"] = MainActor.assumeIsolated { AppConfig.load(from: AppPaths.config).uiLanguage == "uk" ? "uk" : "en" }
        if let d = try? JSONSerialization.data(withJSONObject: prefs), let js = String(data: d, encoding: .utf8) {
            uc.addUserScript(WKUserScript(source: "window.LT_PREFS = " + js + ";", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
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
        _ = window.setFrameAutosaveName("LiveTipsAppPrompter")   // remembers position and size
        addEndCallButton()

        // 2026-10-23: the title bar (close, minimise, End call) stays solid at any opacity setting.
        if let tb = window.standardWindowButton(.closeButton)?.superview {
            tb.wantsLayer = true
            window.effectiveAppearance.performAsCurrentDrawingAppearance {
                tb.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
        }
        NotificationCenter.default.addObserver(forName: CallEngine.callEnded, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { self?.showCallEnded(n.userInfo ?? [:]) }
        }

        web = WKWebView(frame: NSRect(origin: .zero, size: rect.size), configuration: cfg)
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")   // the page's own background can be see-through
        web.autoresizingMask = [.width, .height]
        window.contentView = web
        let url = URL(fileURLWithPath: args.html)
        pageURL = url
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if !args.tips.isEmpty { tips = TailReader(path: args.tips) }
        ticker = Timer.scheduledTimer(timeInterval: 0.5, target: self, selector: #selector(tick),
                             userInfo: nil, repeats: true)
    }

    @objc func tick() {
        if let t = tips {
            let lines = t.newLines().filter(isJSONObject)
            if !lines.isEmpty { push("window.addItems([" + lines.joined(separator: ",") + "])") }
        }
        ticks += 1
        // 2026-10-27 (owner): the status every 0.5 s (was 2 s), so the dot turns red as soon as the recording runs.
        if !args.status.isEmpty,
           let s = try? String(contentsOfFile: args.status, encoding: .utf8),
           s != lastStatus, isJSONObject(s) {
            lastStatus = s
            push("window.setStatus(" + s + ")")
            if let d = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] {
                if !callEnded { startButton?.isHidden = (d["state"] as? String) != "standby" }
                if let f = d["file"] as? String, !f.isEmpty, f != transcriptPath {
                    transcriptPath = f
                    transcript = TailReader(path: f)
                    speakersMtime = nil
                }
            }
        }
        // 2026-10-27 (owner): the preparation's progress in the ⚙ panel's Context block.
        if ticks % 4 == 2 {
            let js: String = MainActor.assumeIsolated {
                let r = PrepRunner.shared
                var d: [String: Any] = ["state": "none"]
                // Up next (2026-10-27): only the preparation of this call; an upcoming call's shows in Up next.
                let mine = PrepRunner.joinsLiveCall(prepFor: r.callID, liveCall: CallEngine.shared.currentCallID)
                if r.running && mine {
                    d = ["state": "running", "stage": r.stage, "detail": r.detail, "progress": r.progress]
                } else if !transcriptPath.isEmpty, FileManager.default.fileExists(atPath: String(transcriptPath.dropLast(3)) + ".brief.md") {
                    d = ["state": "ready"]
                } else if mine, r.result.lowercased().contains("fail") {
                    d = ["state": "failed", "stage": r.result]
                }
                let data = (try? JSONSerialization.data(withJSONObject: d)) ?? Data("{}".utf8)
                return String(data: data, encoding: .utf8) ?? "{}"
            }
            if js != lastPrep { lastPrep = js; push("window.setPrep && window.setPrep(" + js + ")") }
            let un: String = MainActor.assumeIsolated { UpNext.shared.json() }
            if un != lastUpNext { lastUpNext = un; push("window.setUpNext && window.setUpNext(" + un + ")") }
        }
        // The live transcript and the speaker names (speakers.json) for the transcript pane.
        if let tr = transcript {
            let lines = tr.newLines()
            if !lines.isEmpty, let d = try? JSONSerialization.data(withJSONObject: lines), let js = String(data: d, encoding: .utf8) {
                push("window.addTranscript && window.addTranscript(" + js + ")")
            }
        }
        if ticks % 4 == 2, !transcriptPath.isEmpty {
            let sp = (transcriptPath.hasSuffix(".md") ? String(transcriptPath.dropLast(3)) : transcriptPath) + ".speakers.json"
            if let m = (try? FileManager.default.attributesOfItem(atPath: sp))?[.modificationDate] as? Date, m != speakersMtime,
               let s = try? String(contentsOfFile: sp, encoding: .utf8), isJSONObject(s) {
                speakersMtime = m
                push("window.setSpeakers && window.setSpeakers(" + s + ")")
            }
        }
    }

    func push(_ js: String) {
        if pageReady {
            web.evaluateJavaScript(js, completionHandler: nil)
        } else {
            pending.append(js)
        }
    }

    /// Security (audit 2026-10-27): the window shows only its own page. https links open in the browser,
    /// everything else (other files, javascript:, data:, custom schemes) is refused.
    var pageURL: URL?
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let u = action.request.url else { decisionHandler(.cancel); return }
        if u.isFileURL, let page = pageURL, u.standardizedFileURL.path == page.standardizedFileURL.path { decisionHandler(.allow); return }
        if u.absoluteString == "about:blank" { decisionHandler(.allow); return }
        if u.scheme?.lowercased() == "https", action.navigationType == .linkActivated { NSWorkspace.shared.open(u) }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        web.evaluateJavaScript("window.enableGlass && window.enableGlass()", completionHandler: nil)
        if args.demoPresentation {   // the demo of the presentation mode: type Presentation opens the slide cards
            web.evaluateJavaScript("(function(){var s=document.getElementById('s_type'); if(s){s.value='presentation'; s.dispatchEvent(new Event('change'));}})()", completionHandler: nil)
        }
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
                deckWide = (d["on"] as? Bool) ?? false
                deckGrowRight = (d["grow"] as? String) == "right"
            } else {
                deckWide = (message.body as? Bool) ?? false
                deckGrowRight = false
            }
            setSplit(deckWide || trWide, growRight: deckGrowRight, animate: true)
        case "transcript":
            // The transcript pane opens next to the tips: the window grows the same way as for slide cards.
            trWide = (message.body as? Bool) ?? false
            setSplit(deckWide || trWide, growRight: deckGrowRight, animate: true)
        case "upnext":
            // 2026-10-27 (owner, Up next): {"a": "plan" | "edit" | "switch" | "remove" | "prep", "id": ...}
            guard let d = message.body as? [String: Any], let act = d["a"] as? String else { return }
            MainActor.assumeIsolated {
                guard let app = NSApp.delegate as? AppDelegate else { return }
                let m = (d["id"] as? String).flatMap { UpNext.shared.item($0) }
                switch act {
                case "plan": StartCallWindow.show(delegate: app)
                case "edit": if let m = m { StartCallWindow.show(delegate: app, prepared: m) }
                case "switch": if let m = m { app.confirmSwitch(to: m, on: window) }
                case "prep": if let m = m, let e = UpNext.shared.prepare(m) { push("window.toastMsg && window.toastMsg(" + jsString(e) + ")") }
                case "remove":
                    guard let m = m else { return }
                    let a = NSAlert()
                    a.messageText = "Remove \u{201C}\(m.effectiveTitle)\u{201D} from Up next?"
                    a.informativeText = "Its preparation files stay in the project's live folder."
                    a.addButton(withTitle: "Remove"); a.addButton(withTitle: "Cancel")
                    a.beginSheetModal(for: window) { r in if r == .alertFirstButtonReturn { MainActor.assumeIsolated { UpNext.shared.remove(m) } } }
                default: break
                }
            }
        case "rename":
            // 2026-10-27 (owner): rename the call while it runs (a title typed in a hurry).
            guard let v = (message.body as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return }
            MainActor.assumeIsolated { CallEngine.shared.callRequest["title"] = v; CallEngine.shared.renamed = v }
            window.title = "Live Tips: " + v
            if !args.inbox.isEmpty { appendLine(jsonLine(["t": nowHMS(), "kind": "setting", "key": "title", "value": v]), to: args.inbox) }
        case "pref":
            // Window settings remembered across calls (opacity, text size, proactive, language...).
            guard let d = message.body as? [String: Any], let k = d["k"] as? String else { return }
            var prefs = UserDefaults.standard.dictionary(forKey: "prompterPrefs") ?? [:]
            prefs[k] = d["v"] as? String ?? ""
            UserDefaults.standard.set(prefs, forKey: "prompterPrefs")
            if k == "ui_lang", let v = d["v"] as? String, ["en", "uk"].contains(v) {
                // The window's Interface switch is the app's interface language too (Settings > General).
                MainActor.assumeIsolated {
                    SettingsWindow.model.config.uiLanguage = v
                    SettingsWindow.model.saveConfig()
                }
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
    func windowWillClose(_ notification: Notification) {
        deckWide = false; trWide = false; setSplit(false, animate: false)
        ticker?.invalidate(); ticker = nil
    }

    /// "End call" in the window's title bar: stops the recording; the transcript and tips stay in the project folder.
    var endButton: NSButton?
    var callEnded = false
    var startButton: NSButton?
    var lastUpNext = ""

    @objc func startClicked() {
        guard !args.control.isEmpty else { return }
        FileManager.default.createFile(atPath: (args.control as NSString).appendingPathComponent("go"), contents: Data())
        startButton?.isHidden = true
        push("window.setStarting && window.setStarting()")     // blue dot until the recorder says it records
    }
    /// 2026-10-27 (owner): the call buttons in the same style as the rest of the app: a soft pill,
    /// blue to start, red to end, both say "call".
    func pillButton(_ title: String, color: NSColor, filled: Bool, action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 9
        b.layer?.backgroundColor = (filled ? color : color.withAlphaComponent(0.18)).cgColor
        b.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: filled ? NSColor.white : color, .font: NSFont.systemFont(ofSize: 12, weight: .semibold)])
        let size = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)])
        b.frame = NSRect(x: 0, y: 0, width: ceil(size.width) + 24, height: 22)
        return b
    }

    func restylePill(_ b: NSButton, _ title: String, color: NSColor) {
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        b.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: color, .font: font])
        b.layer?.backgroundColor = color.withAlphaComponent(0.18).cgColor
        let w = ceil((title as NSString).size(withAttributes: [.font: font]).width) + 24
        let right = b.frame.maxX
        b.frame = NSRect(x: max(0, right - w), y: b.frame.origin.y, width: w, height: 22)
    }

    func addEndCallButton() {
        let b = pillButton("End call", color: .systemRed, filled: false, action: #selector(endCallClicked))
        b.toolTip = "Stop recording this call"
        // Start call while the window waits for the call (standby); it also starts by itself when the other side speaks.
        let g = pillButton("Start call", color: .controlAccentColor, filled: true, action: #selector(startClicked))
        g.toolTip = "Start recording now (otherwise it starts when the other side speaks)"
        g.isHidden = true
        let w = g.frame.width + b.frame.width + 18
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: w, height: 28))
        g.frame.origin = NSPoint(x: 4, y: (28 - g.frame.height) / 2)
        b.frame.origin = NSPoint(x: g.frame.maxX + 6, y: (28 - b.frame.height) / 2)
        holder.addSubview(g)
        holder.addSubview(b)
        startButton = g
        let acc = NSTitlebarAccessoryViewController()
        acc.view = holder
        acc.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(acc)
        endButton = b
    }

    @objc func newCallClicked() {
        MainActor.assumeIsolated {
            guard let app = NSApp.delegate as? AppDelegate else { return }
            if CallEngine.shared.isRunning { window.close(); return }    // the next call is already starting (Up next switch)
            if let n = UpNext.shared.first {
                if let e = app.launch(n) { app.notifySwitchFailed(e, n) }
            } else {
                window.close()
                app.startCall()
            }
        }
    }

    /// Up next switch: the call is being ended by the app, not by this window's button.
    func markEnding() {
        if let b = endButton { restylePill(b, "Ending...", color: .systemRed); b.isEnabled = false }
        push("window.setEnding && window.setEnding()")
    }

    func jsString(_ s: String) -> String {
        let d = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        let a = String(data: d, encoding: .utf8) ?? "[\"\"]"
        return String(a.dropFirst().dropLast())
    }

    @objc func endCallClicked() {
        // 2026-10-26: End call did nothing on a live call. The app had lost track of the recorder
        // process, and a modal alert can open behind this floating window. Now: the recorder's own
        // status decides, and the question is a sheet on this window.
        let st = EngineStatus.load(path: CallEngine.shared.statusPath)
        let live = CallEngine.shared.isRunning || ["recording", "standby", "loading_model"].contains(st.state)
        guard live else { window.close(); return }
        let a = NSAlert()
        a.messageText = "End the call?"
        a.informativeText = "Recording stops; the transcript and tips stay in the project folder, and the summary goes to Notion."
        a.addButton(withTitle: "End call")
        // 2026-10-27 (Up next): the next planned call can start right after this one.
        let next: StartCallModel? = MainActor.assumeIsolated { UpNext.shared.first }
        if let n = next { a.addButton(withTitle: "End and start \u{201C}\(MainActor.assumeIsolated { n.effectiveTitle })\u{201D}") }
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { [weak self] resp in
            if let n = next, resp == .alertSecondButtonReturn {
                MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.performSwitch(to: n) }
                return
            }
            guard resp == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated {
                let owned = CallEngine.shared.isRunning
                CallEngine.shared.stop()
                if let b = self?.endButton { self?.restylePill(b, "Ending...", color: .systemRed) }
                self?.endButton?.isEnabled = false
                if !owned {
                    CallEngine.shared.finishOrphan { file, saved in
                        self?.showCallEnded(["saved": saved, "file": file, "lines": EngineStatus.load(path: CallEngine.shared.statusPath).lines])
                    }
                }
            }
        }
    }

    /// The recorder has stopped: the button says so and the window gets a closing card with the file
    /// (2026-10-23: "I was afraid to close the app before it finished the call").
    func showCallEnded(_ info: [AnyHashable: Any]) {
        let saved = info["saved"] as? Bool ?? false
        if let b = endButton {                  // 2026-10-27: same pill style, green when saved (sizeToFit broke the shape)
            restylePill(b, saved ? "Ended ✓" : "Ended", color: saved ? .systemGreen : .systemOrange)
            b.isEnabled = true                  // a click now closes the window
            b.toolTip = "Close this window"
        }
        // 2026-10-27 (owner): start the next call from here: closes this window and opens Start call.
        // With a call in Up next the pill starts it at once ("Start next"; the old call has ended already).
        if let g = startButton {
            callEnded = true
            let next: StartCallModel? = MainActor.assumeIsolated { UpNext.shared.first }
            let label = next == nil ? "New call" : "Start next"
            restylePill(g, label, color: .controlAccentColor)
            let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            g.attributedTitle = NSAttributedString(string: label, attributes: [.foregroundColor: NSColor.white, .font: font])
            g.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            if let b = endButton { g.frame.origin.x = max(0, b.frame.minX - 6 - g.frame.width) }
            g.action = #selector(newCallClicked)
            g.target = self
            g.toolTip = next.map { n in "Start \u{201C}" + MainActor.assumeIsolated { n.effectiveTitle } + "\u{201D} now (Up next)" } ?? "Close this window and open Start call"
            g.isHidden = false
        }
        let file = ((info["file"] as? String ?? "") as NSString).lastPathComponent
        let lines = info["lines"] as? Int ?? 0
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        let item: [String: Any] = ["kind": "wrapup", "level": "info", "t": f.string(from: Date()), "at": f.string(from: Date()),
                                   "gist": saved ? "✅ Call ended, transcript saved" : "⚠ Call ended, transcript file not found",
                                   "items": saved ? ["\(lines) lines: \(file)", "You can close this window."] : ["Check the project's live folder."]]
        if let d = try? JSONSerialization.data(withJSONObject: [item]), let js = String(data: d, encoding: .utf8) {
            push("window.addItems && window.addItems(\(js))")
        }
    }
}
