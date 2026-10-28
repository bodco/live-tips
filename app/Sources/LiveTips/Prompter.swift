// The tips window of Pacenote, hosted in a WKWebView. Pacenote 0.8 (F2): the page is Resources/tips/
// (Concept A "Focus"); the skill's live-transcriber keeps its own prompter.html. The item stream, the status,
// the transcript and the speakers go to the page as before (feed.js turns them into the window's state);
// the page answers on one handler, "liveTips", with {"action": ...} (handleAction below).

import AppKit
import SwiftUI
import WebKit
import LiveTipsCore

struct PrompterArgs {
    var tips = ""
    var inbox = ""
    var status = ""
    var html = ""
    var control = ""
    var title = "Pacenote"
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
    var briefMtime: Date?
    /// <transcript stem> (without .md): the call's files share it.
    var stem: String { transcriptPath.hasSuffix(".md") ? String(transcriptPath.dropLast(3)) : transcriptPath }
    var lastPrep = ""
    var ticker: Timer?               // stopped when the window closes (QA: closed windows kept reading files)
    var compactFrame: NSRect?        // the full window's frame while the compact strip is shown

    init(args: PrompterArgs) { self.args = args }

    func show() {

        let uc = WKUserContentController()
        uc.add(self, name: "liveTips")
        // The remembered window settings, before the page's own script runs.
        var prefs = UserDefaults.standard.dictionary(forKey: "prompterPrefs") ?? [:]
        // 2026-10-27 (owner): one interface language for the whole app: the window follows Settings > General.
        prefs["ui_lang"] = MainActor.assumeIsolated { AppConfig.load(from: AppPaths.config).uiLanguage == "uk" ? "uk" : "en" }
        prefs["keys"] = ["help": HotKeys.shared.combo(.help).display, "pause": HotKeys.shared.combo(.pause).display,
                         "mute": HotKeys.shared.combo(.mute).display, "compact": HotKeys.shared.combo(.compact).display]
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
        window.title = args.title                   // the call's name; the brand symbol sits next to it
        window.titlebarAppearsTransparent = true   // the title bar blends with the page background
        window.level = Self.onTop ? .floating : .normal      // 2026-10-28: "Always on top" is remembered
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
        if let z = prefs["zoom"] as? Double, z > 0 { web.pageZoom = CGFloat(z) }      // Cmd + and Cmd -, remembered
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
        // Pacenote 0.8: the minutes left (the calendar event's end) ride along for the "N min left" card.
        if !args.status.isEmpty,
           let raw = try? String(contentsOfFile: args.status, encoding: .utf8), isJSONObject(raw),
           var d = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] {
            if let left = Self.minutesLeft() { d["minutes_left"] = left }
            let s = (try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? raw
            if s != lastStatus {
                lastStatus = s
                push("window.setStatus(" + s + ")")
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
        // 2026-10-28 (owner): the full preparation for the Preparation pane, again when it changes.
        if ticks % 4 == 1, !transcriptPath.isEmpty {
            let bp = stem + ".brief.md"
            if let m = (try? FileManager.default.attributesOfItem(atPath: bp))?[.modificationDate] as? Date, m != briefMtime,
               let text = try? String(contentsOfFile: bp, encoding: .utf8) {
                briefMtime = m
                let f = DateFormatter(); f.dateFormat = "HH:mm"
                if let d = try? JSONSerialization.data(withJSONObject: ["text": text, "at": f.string(from: m)]), let js = String(data: d, encoding: .utf8) {
                    push("window.setPrepDoc && window.setPrepDoc(" + js + ")")
                }
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
        if let o = (UserDefaults.standard.dictionary(forKey: "prompterPrefs") ?? [:])["opacity"] as? Double {
            web.evaluateJavaScript("window.LiveTips && LiveTips.setOpacity(\(o))", completionHandler: nil)
        }
        if args.demo {   // the demo window: a call in progress (or a presentation) without a recorder
            let f = ISO8601DateFormatter()
            let st: [String: Any] = ["state": "recording", "title": args.title, "started_at": f.string(from: Date().addingTimeInterval(-32 * 60 - 14)),
                                     "call_type": args.demoPresentation ? "presentation" : "auto", "system_audio": "ok", "mic": "on", "minutes_left": 13]
            web.evaluateJavaScript("window.setStatus && window.setStatus(" + jsonLine(st) + ")", completionHandler: nil)
        }
        let queued = pending
        pending.removeAll()
        for js in queued { web.evaluateJavaScript(js, completionHandler: nil) }
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if message.name == "liveTips", let d = message.body as? [String: Any] { handleAction(d) }
    }

    /// The window's requests by their pre-0.8 names (the inbox, the corrections log, the files), shared by handleAction.
    func handle(_ name: String, _ body: Any) {
        let message = (name: name, body: body)
        switch message.name {
        case "ask":
            guard let text = message.body as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !args.inbox.isEmpty else { return }
            appendLine(jsonLine(["t": nowHMS(), "text": text]), to: args.inbox)
            if args.demo, !args.tips.isEmpty {
                appendLine(jsonLine(["t": nowHMS(), "kind": "answer", "level": "info", "q": text,
                                     "gist": L("tw.demoQ"),
                                     "phrase": L("tw.demoA")]),
                           to: args.tips)
            }
        case "pin":
            setOnTop((message.body as? Bool) ?? true)
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
                    a.messageText = L("tw.removeUpNext", ["title": m.effectiveTitle])
                    a.informativeText = L("tw.removeInfo")
                    a.addButton(withTitle: L("tw.remove")); a.addButton(withTitle: L("hk.cancel"))
                    a.beginSheetModal(for: window) { r in if r == .alertFirstButtonReturn { MainActor.assumeIsolated { UpNext.shared.remove(m) } } }
                default: break
                }
            }
        case "cardedit":
            // 2026-10-28 (owner): a card or an On me line corrected in the window. Kept next to the transcript
            // (<stem>.edits.jsonl, read by the Notion wrap-up as true), a prepared card is changed in <stem>.cards.json,
            // and the tips engine and the skill see it in the inbox.
            guard let d = message.body as? [String: Any], !transcriptPath.isEmpty else { return }
            var rec = d; rec["at"] = nowHMS()
            appendLine(jsonLine(rec), to: stem + ".edits.jsonl")
            let (ct, cp) = Self.callNames()
            EditLog.add(kind: "card_" + ((d["action"] as? String) ?? "edit"), title: ct, project: cp, file: stem, fields: d)
            if let card = d["card"] as? String, !card.isEmpty { updatePreparedCard(card, d) }
            if !args.inbox.isEmpty {
                let after = (d["after"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                appendLine(jsonLine(["t": nowHMS(), "kind": "setting", "key": "card_edit",
                                     "value": "\(d["action"] ?? "edit") \(d["kind"] ?? "") \(after)"]), to: args.inbox)
            }
        case "prepdoc":
            // The PM corrected the preparation in the Preparation pane: saved over <stem>.brief.md (the first version is kept).
            guard let text = message.body as? String, !transcriptPath.isEmpty else { return }
            let bp = stem + ".brief.md", orig = stem + ".brief.orig.md"
            if FileManager.default.fileExists(atPath: bp), !FileManager.default.fileExists(atPath: orig) { try? FileManager.default.copyItem(atPath: bp, toPath: orig) }
            let old = (try? String(contentsOfFile: bp, encoding: .utf8)) ?? ""
            try? text.write(toFile: bp, atomically: true, encoding: .utf8)
            let (ct, cp) = Self.callNames()
            EditLog.addBriefEdit(title: ct, project: cp, file: stem, before: old, after: text, when: "during the call")
            briefMtime = (try? FileManager.default.attributesOfItem(atPath: bp))?[.modificationDate] as? Date
            if !args.inbox.isEmpty {
                appendLine(jsonLine(["t": nowHMS(), "kind": "setting", "key": "brief_edited", "value": "on"]), to: args.inbox)
                appendLine(jsonLine(["t": nowHMS(), "text": "refresh context"]), to: args.inbox)   // the tips engine reloads it now
            }
        case "rename":
            // 2026-10-27 (owner): rename the call while it runs (a title typed in a hurry).
            guard let v = (message.body as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return }
            let (oldTitle, cp) = Self.callNames()
            if oldTitle != v { EditLog.add(kind: "rename", title: v, project: cp, file: stem, fields: ["before": oldTitle, "after": v]) }
            let tp = transcriptPath
            MainActor.assumeIsolated {
                CallEngine.shared.callRequest["title"] = v; CallEngine.shared.renamed = v
                if !tp.isEmpty { CallHistory.shared.rename(file: tp, title: v) }     // Home and insights at once
            }
            window.title = v                 // Pacenote 0.8: the call's name, no product prefix
            push("window.LiveTips && LiveTips.rename(" + jsString(v) + ")")
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
            if key.hasPrefix("speaker_"), let v = d["value"] as? String {   // who is who: corrections too (EditLog)
                let (ct, cp) = Self.callNames()
                EditLog.add(kind: key, title: ct, project: cp, file: stem, fields: ["value": v])
            }
        default:
            break
        }
    }

    /// A prepared card corrected or removed in the window: the same change in <stem>.cards.json, so it fires corrected
    /// (or not at all) for the rest of the call.
    func updatePreparedCard(_ id: String, _ d: [String: Any]) {
        let path = stem + ".cards.json"
        guard let data = FileManager.default.contents(atPath: path),
              var cards = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              let i = cards.firstIndex(where: { ($0["id"] as? String) == id }) else { return }
        if (d["action"] as? String) == "remove" {
            cards.remove(at: i)
        } else if let a = d["after"] as? [String: Any] {
            if let g = a["gist"] as? String, !g.isEmpty { cards[i]["gist"] = g }
            if let p = a["phrase"] as? String { cards[i]["phrase"] = p }
            if let items = a["items"] as? [String] { cards[i]["items"] = items }
        }
        if let out = try? JSONSerialization.data(withJSONObject: cards, options: [.prettyPrinted]) {
            try? out.write(to: URL(fileURLWithPath: path), options: .atomic)
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
        layoutTitleButtons()
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
        b.frame.size = NSSize(width: w, height: 22)
        layoutTitleButtons()
    }

    /// 2026-10-28 (owner): pin, Start and End always 8 pt apart, whatever their labels ("Start next", "Ended ✓").
    var titleHolder: NSView?
    func layoutTitleButtons() {
        guard let h = titleHolder else { return }
        let views: [NSView] = [pinButton, startButton, endButton].compactMap { $0 }.filter { !$0.isHidden }
        let gap: CGFloat = 8
        let need = views.reduce(CGFloat(0)) { $0 + $1.frame.width } + gap * CGFloat(max(0, views.count - 1)) + 10
        if abs(h.frame.width - need) > 0.5 { h.setFrameSize(NSSize(width: need, height: h.frame.height)) }
        var x = h.frame.width - 4
        for v in views.reversed() {
            x -= v.frame.width
            v.frame.origin = NSPoint(x: x, y: (h.frame.height - v.frame.height) / 2)
            x -= gap
        }
    }

    /// 2026-10-28 (owner): "Always on top" back in sight: a pin in the title bar, remembered across calls.
    static var onTop: Bool {
        get { UserDefaults.standard.object(forKey: "tipsOnTop") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "tipsOnTop") }
    }
    var pinButton: NSButton?

    func setOnTop(_ on: Bool) {
        Self.onTop = on
        window.level = on ? .floating : .normal
        styleOnTop()
        push("window.setPinned && window.setPinned(\(on))")
    }

    func styleOnTop() {
        guard let p = pinButton else { return }
        let on = Self.onTop
        p.image = NSImage(systemSymbolName: on ? "pin.fill" : "pin.slash", accessibilityDescription: L("tw.onTop"))
        p.contentTintColor = on ? .controlAccentColor : .secondaryLabelColor
        p.toolTip = on ? L("tw.onTopOn") : L("tw.onTopOff")
    }

    @objc func pinClicked() { setOnTop(!Self.onTop) }

    func addEndCallButton() {
        let b = pillButton(L("menubar.endCall"), color: .systemRed, filled: false, action: #selector(endCallClicked))
        b.toolTip = L("tips.endCall.tooltip")
        // Start call while the window waits for the call (standby); it also starts by itself when the other side speaks.
        let g = pillButton(L("home.startCall"), color: .controlAccentColor, filled: true, action: #selector(startClicked))
        g.toolTip = L("tw.startNowTip")
        g.isHidden = true
        // Pacenote 0.8 (F2): no pin in the title bar (Always on top is in Call settings); the brand symbol on the left.
        let w = g.frame.width + b.frame.width + 20
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
        titleHolder = holder
        layoutTitleButtons()
        let mark = NSHostingView(rootView: PacenoteSymbol(height: 14).padding(.horizontal, 6))
        mark.frame = NSRect(x: 0, y: 0, width: 26, height: 28)
        let lead = NSTitlebarAccessoryViewController()
        lead.view = mark
        lead.layoutAttribute = .leading
        window.addTitlebarAccessoryViewController(lead)
    }

    /// The live call's title and project folder name (the corrections log keys).
    static func callNames() -> (String, String) {
        MainActor.assumeIsolated {
            let ce = CallEngine.shared
            let t = ce.renamed ?? (ce.callRequest["title"] as? String) ?? "Call"
            let p = ((ce.callRequest["project_dir"] as? String) ?? ce.projectRoot) as NSString
            return (t, p.lastPathComponent)
        }
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
        a.messageText = L("tw.endQ")
        a.informativeText = L("tw.endInfo")
        a.addButton(withTitle: L("menubar.endCall"))
        // 2026-10-27 (Up next): the next planned call can start right after this one.
        let next: StartCallModel? = MainActor.assumeIsolated { UpNext.shared.first }
        if let n = next { a.addButton(withTitle: L("tw.endAndStart", ["title": MainActor.assumeIsolated { n.effectiveTitle }])) }
        a.addButton(withTitle: L("hk.cancel"))
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
            restylePill(b, saved ? L("tw.endedSaved") : L("tw.ended"), color: saved ? .systemGreen : .systemOrange)
            b.isEnabled = true                  // a click now closes the window
            b.toolTip = L("tw.close")
        }
        // 2026-10-27 (owner): start the next call from here: closes this window and opens Start call.
        // With a call in Up next the pill starts it at once ("Start next"; the old call has ended already).
        if let g = startButton {
            callEnded = true
            let next: StartCallModel? = MainActor.assumeIsolated { UpNext.shared.first }
            let label = next == nil ? L("tw.newCall") : L("tw.startNext")
            restylePill(g, label, color: .controlAccentColor)
            let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            g.attributedTitle = NSAttributedString(string: label, attributes: [.foregroundColor: NSColor.white, .font: font])
            g.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            if let b = endButton { g.frame.origin.x = max(0, b.frame.minX - 6 - g.frame.width) }
            g.action = #selector(newCallClicked)
            g.target = self
            g.toolTip = next.map { n in L("tw.startNextTip", ["title": MainActor.assumeIsolated { n.effectiveTitle }]) } ?? L("tw.closeOpen")
            g.isHidden = false
        }
        let file = ((info["file"] as? String ?? "") as NSString).lastPathComponent
        let lines = info["lines"] as? Int ?? 0
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        let item: [String: Any] = ["kind": "wrapup", "level": "info", "t": f.string(from: Date()), "at": f.string(from: Date()),
                                   "gist": saved ? L("tw.endedOK") : L("tw.endedNoFile"),
                                   "items": saved ? [L("tw.linesFile", ["n": "\(lines)", "file": file]), L("tw.canClose")] : [L("tw.checkLive")]]
        if let d = try? JSONSerialization.data(withJSONObject: [item]), let js = String(data: d, encoding: .utf8) {
            push("window.addItems && window.addItems(\(js))")
        }
    }
}

// MARK: - Pacenote 0.8 (F2): the new window's actions, compact mode, zoom, Call settings

extension PrompterController {
    /// One handler for the page: {"action": ..., ...} (REDESIGN-SPEC 3.10). Old behaviour is reused through handle(_:_:).
    func handleAction(_ d: [String: Any]) {
        let act = d["action"] as? String ?? ""
        switch act {
        case "ask":
            if let t = d["text"] as? String { handle("ask", t) }
        case "help":
            handle("ask", "sos")                                   // HELP NOW, as before
        case "shorter":
            // No engine change: a typed ask the tips engine answers as usual (the card says "Shorter").
            guard let say = d["say"] as? String, !say.isEmpty else { return }
            handle("ask", "shorter: one sentence I can say now, same facts: " + say)
        case "said":
            sendSetting("tip_feedback", "used|" + (d["key"] as? String ?? ""))
        case "edit":
            var c = d
            c["action"] = "edit"
            c["key"] = d["id"] ?? ""
            handle("cardedit", c)
        case "onme-toggle":
            let done = d["done"] as? Bool ?? false
            handle("cardedit", ["action": done ? "onme_done" : "onme_open", "kind": "onme", "key": d["id"] ?? "",
                                "after": ["text": d["text"] as? String ?? ""]] as [String: Any])
        case "agenda":
            handle("cardedit", ["action": "agenda", "kind": "agenda", "key": d["id"] ?? "",
                                "after": ["text": d["title"] as? String ?? "", "state": d["state"] as? String ?? ""]] as [String: Any])
        case "name-speaker":
            let sid = d["speakerId"] as? String ?? "", name = d["name"] as? String ?? "", side = d["side"] as? String ?? ""
            guard sid.range(of: "^S[0-9]+$", options: .regularExpression) != nil, !name.isEmpty else { return }
            sendSetting("speaker_name", sid + "|" + name)
            if !side.isEmpty { sendSetting("speaker_side", sid + "|" + side) }
        case "setting":
            if let k = d["key"] as? String { handle("setting", ["key": k, "value": d["value"] ?? NSNull()] as [String: Any]) }
        case "mute":
            handle("mute", d["on"] as? Bool ?? false)
        case "compact":
            setCompact(d["on"] as? Bool ?? false)
        case "zoom":
            zoom(d["step"] as? Int ?? 0)
        case "start":
            startClicked()
        case "prepdoc":
            if let t = d["text"] as? String { handle("prepdoc", t) }
        case "prepare-next":
            handle("upnext", ["a": "prep", "id": d["id"] as? String ?? ""])
        case "open-next":
            MainActor.assumeIsolated {
                if let id = d["id"] as? String, let m = UpNext.shared.item(id), let p = PrepDocWindow.path(for: m) {
                    PrepDocWindow.show(path: p, title: m.effectiveTitle)
                }
            }
        case "menu":
            switch d["item"] as? String ?? "" {
            case "clear-speakers": sendSetting("speakers_clear", true)
            case "settings": MainActor.assumeIsolated { CallSettingsWindow.show(for: self) }
            case "switch-call":
                MainActor.assumeIsolated {
                    guard let app = NSApp.delegate as? AppDelegate else { return }
                    if let n = UpNext.shared.first { app.confirmSwitch(to: n, on: window) } else { StartCallWindow.show(delegate: app, planOnly: true) }
                }
            default: break
            }
        default:
            break                                                  // pin, hide, present, ready: the window keeps them itself
        }
    }

    func sendSetting(_ key: String, _ value: Any) { handle("setting", ["key": key, "value": value] as [String: Any]) }

    /// Minutes until the end of the call's calendar event (nil without an event).
    static func minutesLeft() -> Int? {
        MainActor.assumeIsolated {
            guard let id = CallEngine.shared.liveEventID, let e = CalendarService.shared.event(id) else { return nil }
            return Int((e.end.timeIntervalSinceNow / 60).rounded(.up))
        }
    }

    // Compact mode (REDESIGN-SPEC 3.8): a strip about 560 x 150 at the top of the same place, always on top,
    // still hidden from screen sharing. Control-Option-T or the window menu; the same again goes back.
    var isCompact: Bool { compactFrame != nil }
    func setCompact(_ on: Bool) {
        guard let w = window else { return }
        if on, compactFrame == nil {
            compactFrame = w.frame
            var f = w.frame
            let size = NSSize(width: 560, height: 150)
            f.origin.y = f.maxY - size.height
            f.size = size
            w.minSize = NSSize(width: 360, height: 90)
            w.setFrame(f, display: true, animate: true)
            w.level = .floating
        } else if !on, let f = compactFrame {
            compactFrame = nil
            w.minSize = NSSize(width: 300, height: 140)
            w.setFrame(f, display: true, animate: true)
            w.level = Self.onTop ? .floating : .normal
        }
        push("window.LiveTips && LiveTips.setMode('" + (on ? "compact" : "normal") + "')")
    }
    func toggleCompact() { setCompact(!isCompact) }

    /// Cmd + / Cmd - / Cmd 0 in the window: the page zoom, remembered for the next calls.
    func zoom(_ step: Int) {
        let z = step == 0 ? 1.0 : min(1.6, max(0.8, Double(web.pageZoom) + Double(step) * 0.1))
        web.pageZoom = CGFloat(z)
        var prefs = UserDefaults.standard.dictionary(forKey: "prompterPrefs") ?? [:]
        prefs["zoom"] = z
        UserDefaults.standard.set(prefs, forKey: "prompterPrefs")
    }

    /// Display settings from Call settings: the background opacity (text stays solid) and screen-share hiding.
    func setOpacity(_ v: Double) {
        var prefs = UserDefaults.standard.dictionary(forKey: "prompterPrefs") ?? [:]
        prefs["opacity"] = v
        UserDefaults.standard.set(prefs, forKey: "prompterPrefs")
        push("window.LiveTips && LiveTips.setOpacity(\(v))")
    }
    var hiddenFromSharing: Bool {
        get { window.sharingType == NSWindow.SharingType.none }
        set { window.sharingType = newValue ? .none : .readOnly }
    }
    func setLanguage(_ l: String) {
        push("window.LiveTips && LiveTips.setLang('" + (l == "uk" ? "uk" : "en") + "')")
    }
}
