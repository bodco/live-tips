import AppKit
import SwiftUI
import WebKit
import LiveTipsCore

/// `LiveTips --shots <folder>`: renders the app's windows on demo data into PNG files for the website
/// (2026-10-27, owner: the site shows the real app, and the pictures are refreshed as the app changes).
/// Demo projects, people and voices only (Orbit SaaS Launch, Northwind Studio, Mike, Emily, ...): the
/// PM's own projects are never loaded, because the support folder is replaced before anything reads it.
/// Each window is drawn into a bitmap by AppKit itself (no screen recording permission is needed);
/// the tips window's web content comes from WKWebView.takeSnapshot and is laid over the frame.
@MainActor
final class ShotMode: NSObject, NSApplicationDelegate {
    let out: URL
    var steps: [() -> Void] = []
    var keep: [AnyObject] = []
    init(out: URL) { self.out = out }

    nonisolated static let demoRoot = "/Users/Shared/LiveTipsDemo"

    /// Writes the demo support folder and points the app at it. Called before the app starts.
    nonisolated static func prepareDemo() {
        let fm = FileManager.default
        let sup = demoRoot + "/support", work = demoRoot + "/work", app = demoRoot + "/app"
        let orbit = work + "/Northwind Studio/Orbit SaaS Launch", play = work + "/Northwind Studio/Internal Delivery Playbook"
        for d in [sup, orbit + "/live", play + "/live", app + "/voices", work + "/Northwind Studio"] {
            try? fm.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
        setenv("LT_SUPPORT_DIR", sup, 1)
        try? fm.removeItem(atPath: sup + "/upnext.json")          // Up next starts empty on every run
        try? fm.removeItem(atPath: app + "/state/status.json")
        try? fm.removeItem(atPath: sup + "/history.json")
        // Recent calls for Home: demo transcripts of the last days.
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        for (days, hm, slug, title, dir, len) in [(0, "1000", "orbit-weekly-with-the-client", "Orbit weekly with the client", orbit, 42),
                                                  (1, "1530", "release-checklist-review", "Release checklist review", play, 25),
                                                  (2, "1100", "orbit-pilot-planning", "Orbit pilot planning", orbit, 55),
                                                  (2, "1600", "team-sync", "Team sync", play, 18),
                                                  (3, "0930", "orbit-kickoff", "Orbit kickoff", orbit, 64)] {
            let d = df.string(from: Date().addingTimeInterval(-Double(days) * 86400 - 3600))
            let f = "\(dir)/live/\(d)-\(hm)-\(slug).app.md"
            let h = Int(hm.prefix(2)) ?? 10, m = Int(hm.suffix(2)) ?? 0
            let endM = h * 60 + m + len
            let body = "# Live Transcript: \(title)\n\n- Project: demo\n\n" + String(format: "[%02d:%02d:05] Me (en): Hello.\n[%02d:%02d:10] Other (en): Thanks, bye.\n", h, m, endM / 60, endM % 60)
            try? body.write(toFile: f, atomically: true, encoding: .utf8)
            if days != 2 { try? "# Live Brief: demo\n".write(toFile: String(f.dropLast(3)) + ".brief.md", atomically: true, encoding: .utf8) }
            // Pacenote 0.8 (F3): the call picture at the end of the call, for Home's Recent and On you.
            let sit: [String: Any] = ["kind": "situation", "t": "10:40:00",
                                      "decisions": days == 0 ? ["Export goes to production on Tuesday", "Pilot starts Monday with 5 users"] : ["Release checklist approved"],
                                      "actions": days == 0 ? [["what": "Send the test account list", "due": "today", "from": "Emily"]] : days == 1 ? [["what": "Share the release notes draft", "due": "Friday", "from": "PM"]] : [],
                                      "asks": days == 0 ? [["who": "David", "what": "Who tests the pilot after week one?", "type": "question"]] : []]
            // Pacenote 0.8.5: the last agenda strip of the call (one item not raised: carried into the next call of the series).
            let agenda: [String: Any] = ["kind": "agenda", "final": true, "items": [["text": "Export release date", "done": true, "state": "done"],
                                                                                 ["text": "Who tests the pilot", "done": true, "state": "done"],
                                                                                 ["text": "Test accounts", "done": false, "state": "todo"]]]
            if let d = try? JSONSerialization.data(withJSONObject: sit), let s = String(data: d, encoding: .utf8),
               let d2 = try? JSONSerialization.data(withJSONObject: agenda), let s2 = String(data: d2, encoding: .utf8) {
                try? (s + "\n" + (days == 0 ? s2 + "\n" : "")).write(toFile: f + ".tips.jsonl", atomically: true, encoding: .utf8)
            }
        }
        // Pacenote 0.8.5 (F5): the commitments register for Home's On you and the readiness checks (demo items only).
        let iso = ISO8601DateFormatter()
        let yesterday = df.string(from: Date().addingTimeInterval(-86400)), today = df.string(from: Date().addingTimeInterval(-3600))
        let regItems: [(String, String, String, String, String, Double)] = [
            ("Send the test account list", "me", yesterday, "orbit-saas-launch", "Orbit weekly with the client", 2),
            ("Share the release notes draft", "me", "Friday", "internal-delivery-playbook", "Release checklist review", 1),
            ("Book the pilot kick-off room", "me", "", "orbit-saas-launch", "Orbit pilot planning", 3),
            ("Names of the 5 pilot users", "Emily Clark", "Friday", "orbit-saas-launch", "Orbit weekly with the client", 2)]
        try? fm.removeItem(atPath: orbit + "/live/commitments.jsonl")
        try? fm.removeItem(atPath: play + "/live/commitments.jsonl")
        for (text, owner, due, proj, title, days) in regItems {
            let folder = (proj == "orbit-saas-launch" ? orbit : play) + "/live"
            let call = "\(today)-1000-" + title.lowercased().replacingOccurrences(of: " ", with: "-") + ".app.md"
            CommitmentRegister.append(folder: folder, [["op": "add", "id": CommitmentRegister.makeID(call: call, owner: owner, text: text),
                "text": text, "owner": owner, "project": proj, "series": CommitmentRegister.seriesKey(project: proj, title: title),
                "call": call, "t": "10:20:00", "created": iso.string(from: Date().addingTimeInterval(-days * 86400)), "due": due, "by": "app"]])
        }
        let k = DateFormatter(); k.dateFormat = "yyyy-MM-dd"
        write([k.string(from: Date()): 0.62, k.string(from: Date().addingTimeInterval(-86400)): 0.41, k.string(from: Date().addingTimeInterval(-2 * 86400)): 0.95], sup + "/spend-days.json")
        let cfg: [String: Any] = ["workRoot": work, "appRoot": app, "uiLanguage": "en", "speakersEnabled": true]
        write(cfg, sup + "/config.json")
        var reg = ProjectRegistry()
        var o = Project(name: "Orbit SaaS Launch", slug: "orbit-saas-launch", root: orbit)
        o.workspace = "Northwind Studio"
        o.people = [.init(name: "Mike Johnson", role: "PM", side: "team"), .init(name: "Sarah Lee", role: "Tech lead", side: "team"),
                    .init(name: "Emily Clark", role: "Product owner", side: "client"), .init(name: "David Kim", role: "CTO", side: "client")]
        var pb = Project(name: "Internal Delivery Playbook", slug: "internal-delivery-playbook", root: play)
        pb.workspace = "Northwind Studio"
        pb.people = [.init(name: "Mike Johnson", role: "PM", side: "team")]
        reg.projects = [o, pb]
        reg.workspaces = [Workspace(name: "Northwind Studio", root: work + "/Northwind Studio", projects: [o.slug, pb.slug])]
        reg.lastUsed = "project:orbit-saas-launch"
        if let d = try? JSONEncoder().encode(reg) { try? d.write(to: URL(fileURLWithPath: sup + "/projects.json")) }
        let emb = Array(repeating: 0.1, count: 16)
        func voice(_ side: String, _ wh: [String], _ calls: Int) -> [String: Any] {
            ["embeddings": [emb], "calls": calls, "side": side, "where": wh, "updated": "2026-10-27T10:00:00+02:00"]
        }
        write(["people": ["Mike J.": voice("team", ["all"], 12), "Sarah L.": voice("team", ["all"], 9),
                          "Emily C.": voice("client", ["project:orbit-saas-launch"], 6),
                          "David K.": voice("client", ["project:orbit-saas-launch", "project:internal-delivery-playbook"], 3)]],
              app + "/voices/voices.json")
    }

    nonisolated static func write(_ o: Any, _ path: String) {
        if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted]) { try? d.write(to: URL(fileURLWithPath: path)) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        log("launched")
        // Pacenote 0.8: every screen in English and Ukrainian (files of the Ukrainian pass end in -uk).
        for lang in ["en", "uk"] {
        steps.append { [unowned self] in SettingsWindow.model.config.uiLanguage = lang; self.next(after: 0.3) }
        for theme in ["dark", "light"] {
            steps.append { [unowned self] in NSApp.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua); self.next(after: 0.5) }
            steps.append { [unowned self] in self.splash(theme) }
            steps.append { [unowned self] in self.startCall(theme) }
            steps.append { [unowned self] in self.planCall(theme) }
            steps.append { [unowned self] in self.home(theme) }
            steps.append { [unowned self] in self.menuPanel(theme, live: false) }
            steps.append { [unowned self] in self.menuPanel(theme, live: true) }
            for tab in ["general", "calendars", "keys", "notion", "ai", "about", "projects"] { steps.append { [unowned self] in self.settings(tab, theme) } }
            steps.append { [unowned self] in self.howItWorks(theme) }     // F4: its own window from the Help menu
            steps.append { [unowned self] in self.tips(theme, presentation: false) }
            steps.append { [unowned self] in self.tips(theme, presentation: true) }
            steps.append { [unowned self] in self.tipsExtra(theme, js: "", name: "tips-380", size: NSSize(width: 380, height: 620)) }
            steps.append { [unowned self] in self.tipsExtra(theme, js: "", name: "tips-560", size: NSSize(width: 560, height: 620)) }
            steps.append { [unowned self] in self.tipsExtra(theme, js: "window.setStatus({state:'standby',title:'Orbit weekly with the client'});", name: "tips-ready", size: NSSize(width: 560, height: 620)) }
            if ProcessInfo.processInfo.environment["LT_SHOTS_ALL"] == "1" {
                steps.append { [unowned self] in self.tipsExtra(theme, js: "LiveTips.openTab('brief');", name: "tips-brief") }
                steps.append { [unowned self] in self.tipsExtra(theme, js: "document.getElementById('moreBtn').click();", name: "tips-menu", size: NSSize(width: 560, height: 620)) }
                steps.append { [unowned self] in self.tipsExtra(theme, js: "LiveTips.setMode('compact');", name: "tips-compact", size: NSSize(width: 560, height: 150)) }
                steps.append { [unowned self] in self.tipsExtra(theme, js: "window.setStatus({state:'recording',title:'Orbit weekly with the client',started_at:new Date(Date.now()-55*60000).toISOString(),minutes_left:4});", name: "tips-finish", size: NSSize(width: 560, height: 620)) }
                steps.append { [unowned self] in self.prepDoc(theme) }
                for st in OnboardingModel.Step.allCases where st != .splash { steps.append { [unowned self] in self.onboarding(st, theme) } }
            }
        }
        }
        steps.append { exit(0) }
        next()
    }

    func log(_ m: String) {
        let f = out.appendingPathComponent("shots.log")
        let line = "\(Date()) \(m)\n"
        if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        else { try? line.write(to: f, atomically: true, encoding: .utf8) }
    }

    func next(after: Double = 0.3) {
        DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
            guard let self = self, !self.steps.isEmpty else { return }
            self.log("step, \(self.steps.count) left")
            self.steps.removeFirst()()
        }
    }

    func startCall(_ theme: String) {
        let m = StartCallModel()
        m.target = "project:orbit-saas-launch"
        m.language = "en"
        m.title = "Orbit weekly with the client"
        m.context = "Goal: agree the pilot plan and the export release date.\nParticipants: Emily Clark, David Kim.\nOpen questions: who tests the pilot, the test accounts.\nWhere to look: kickoff notes, export spec."
        StartCallWindow.show(delegate: AppDelegate(), prepared: m)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [self] in
            if let w = StartCallWindow.window { capture(w, "start-call-\(theme)"); w.close() }
            next()
        }
    }

    /// Up next (2026-10-27): Start call during a live call plans an upcoming call. The live call is faked by a
    /// status file in the demo folder; the planned call then stays in Up next, so the tips window shows it.
    lazy var planned: StartCallModel = {
        let m = StartCallModel()
        m.target = "project:internal-delivery-playbook"
        m.language = "en"
        m.title = "Team retro"
        m.callDate = StartCallModel.nextFullHour()
        m.context = "Goal: agree two process changes for the next sprint.\nParticipants: Mike Johnson, Sarah Lee.\nOpen questions: release checklist owner."
        return m
    }()

    func planCall(_ theme: String) {
        let st = (CallEngine.shared.statusPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: st, withIntermediateDirectories: true)
        let started = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-14 * 60))
        Self.write(["state": "recording", "title": "Orbit weekly with the client", "started_at": started, "pid": Int(getpid())], CallEngine.shared.statusPath)
        CallEngine.shared.callRequest["title"] = "Orbit weekly with the client"
        StartCallWindow.show(delegate: AppDelegate(), prepared: planned)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [self] in
            if let w = StartCallWindow.window { capture(w, "plan-call-\(theme)"); w.close() }
            UpNext.shared.save(planned)
            try? FileManager.default.removeItem(atPath: CallEngine.shared.statusPath)
            next()
        }
    }

    /// Home on demo calendars: two calls at the same time (one skipped, one joined), Up next, recent calls.
    func home(_ theme: String) {
        let now = Date()
        let hour = StartCallModel.nextFullHour()
        func ev(_ id: String, _ t: String, _ s: Date, _ mins: Double, _ acc: String, _ cal: String, _ c: NSColor, _ rec: Bool, _ who: [String]) -> CalendarService.CalEvent {
            .init(id: id, seriesKey: rec ? "cal:" + id : "title:" + StartCallModel.slugify(t), title: t, start: s, end: s.addingTimeInterval(mins * 60),
                  calendar: cal, account: acc, color: c, attendees: who, link: nil, recurring: rec)
        }
        let evs = [ev("e1", "Northwind all-hands", now.addingTimeInterval(-10 * 60), 40, "mike@northwind.example", "Northwind", .systemPurple, true, []),
                   ev("e2", "Orbit weekly with the client", now.addingTimeInterval(5 * 60), 30, "mike.johnson@gmail.example", "Work", .systemBlue, true, ["Emily Clark", "David Kim"]),
                   ev("e3", "Team retro", hour, 45, "mike@northwind.example", "Northwind", .systemPurple, false, ["Sarah Lee"]),
                   ev("e4", "Orbit pilot review", Calendar.current.date(byAdding: .day, value: 1, to: hour) ?? hour, 30, "mike.johnson@gmail.example", "Work", .systemBlue, true, ["Emily Clark"])]
        CalendarService.shared.useDemo(evs)
        planned.calEventID = "e3"
        UpNext.shared.save(planned)
        CallHistory.shared.scan()
        if let r = CallHistory.shared.visible.first { CallHistory.shared.setNotion(file: r.file, url: "https://www.notion.so/demo") }
        HomeWindow.show(delegate: AppDelegate())
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [self] in
            if let w = HomeWindow.window { w.setContentSize(NSSize(width: 820, height: 1080)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in
                if let w = HomeWindow.window { capture(w, "home-\(theme)"); w.setContentSize(NSSize(width: 1200, height: 800)) }
                // The wide Home (the week next to the calls): the first picture on the site.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
                    if let w = HomeWindow.window { capture(w, "home-wide-\(theme)"); w.close(); HomeWindow.window = nil }
                    prepare(theme, evs[1])
                }
            }
        }
    }

    /// Prepare from Home: the form that asks for the project and what matters on the call.
    func prepare(_ theme: String, _ e: CalendarService.CalEvent) {
        let m = StartCallModel()
        m.applyEvent(e)
        m.target = "project:orbit-saas-launch"
        let f = DateFormatter(); f.dateFormat = "d MMM"
        m.appliedFrom = "Set up like the last \u{201C}\(e.title)\u{201D} call (\(f.string(from: Date().addingTimeInterval(-7 * 86400)))): correct what changed."
        m.context = "Goal: agree the pilot plan and the export release date.\nParticipants: Emily Clark, David Kim\nOpen questions: who tests the pilot, the test accounts.\nWhere to look: kickoff notes, export spec."
        StartCallWindow.show(delegate: AppDelegate(), prepared: m, mode: .prepare)     // Pacenote 0.8: the same form
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [self] in
            if let w = StartCallWindow.window { capture(w, "prepare-\(theme)"); w.close() }
            next()
        }
    }

    func howItWorks(_ theme: String) {
        HowItWorksWindow.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [self] in
            if let w = HowItWorksWindow.window { capture(w, "how-it-works-\(theme)"); w.close() }
            next()
        }
    }

    func settings(_ tab: String, _ theme: String) {
        SettingsWindow.show(tab: tab)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [self] in
            if let w = SettingsWindow.window { capture(w, "settings-\(tab)-\(theme)") }
            if tab == "projects" { SettingsWindow.window?.close() }
            next()
        }
    }

    /// The tips window in a given state and size (Pacenote 0.8: 380, 560, 1000 px, ready, compact, menu, brief).
    func tipsExtra(_ theme: String, js: String, name: String, size: NSSize = NSSize(width: 1040, height: 680)) {
        var pa = prompterArgs(["LiveTips", "--prompter-demo"])
        pa.title = "Orbit weekly with the client"
        let c = PrompterController(args: pa)
        c.show()
        keep.append(c)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [self] in
            c.web.evaluateJavaScript("""
              try { window.setPrepDoc && window.setPrepDoc({text: \(Self.demoBriefJS), at: '09:40'}); \(js) } catch (e) {}
            """, completionHandler: nil)
            c.window.setContentSize(size)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [self] in
                capture(c.window, "\(name)-\(theme)", web: c.web) { [self] in c.window.close(); next() }
            }
        }
    }

    static let demoBrief = """
    # Live Brief: Orbit weekly with the client (prep, today 11:00)

    **Goal:** agree the pilot plan and the export release date.

    ## Previous meetings
    - **Last week:** export scope agreed; Emily asked for test accounts (open). David asked who tests the pilot (partly answered).
    - **Action items:** Mike - send the test account list (not done); Sarah - export on dev (done).

    ## Checklist
    - [ ] Confirm the export release date (Tuesday after the review)
    - [ ] Who tests the pilot: our QA the first week, then their team
    - [ ] Send the test account list today

    ## Risks
    - Pilot slips if the test accounts are late.

    Sources: kickoff notes, export spec, 2 previous calls, 4 corrections.
    """
    static var demoBriefJS: String {
        let d = (try? JSONSerialization.data(withJSONObject: [demoBrief])) ?? Data("[\"\"]".utf8)
        let s = String(data: d, encoding: .utf8) ?? "[\"\"]"
        return String(s.dropFirst().dropLast())
    }

    /// Read prep: the preparation document window before the call.
    func prepDoc(_ theme: String) {
        let path = out.appendingPathComponent("demo-prep.brief.md").path
        try? Self.demoBrief.write(toFile: path, atomically: true, encoding: .utf8)
        PrepDocWindow.show(path: path, title: "Orbit weekly with the client")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [self] in
            if let w = PrepDocWindow.windows[path] { capture(w, "prep-doc-\(theme)"); w.close(); PrepDocWindow.windows[path] = nil }
            try? FileManager.default.removeItem(atPath: path)
            next()
        }
    }

    /// The menu bar panel (Pacenote 0.8, F1) on demo data: between calls and during one.
    func menuPanel(_ theme: String, live: Bool) {
        let app = AppDelegate()
        let c = MenuBarPanelController(app: app, button: nil)
        let m = c.model
        func call(_ title: String, _ inMin: Double, _ st: UpNext.PrepState) -> MenuBarModel.Call {
            let d = Date().addingTimeInterval(inMin * 60)
            return MenuBarModel.Call(id: title, title: title, startsAt: d, state: st, note: "Orbit SaaS Launch",
                                     ahead: AheadCall(id: title, event: nil, model: nil, start: d))
        }
        m.isLive = live
        m.isRecording = live
        m.elapsed = "32:14"
        m.liveTitle = "Orbit weekly with the client"
        m.liveLine = "Orbit SaaS Launch · " + L("menubar.status.callLine", ["lines": "42", "tips": "3", "cost": "0.21", "cap": "2"])
        m.next = call("Orbit weekly with the client", 8, .none)
        m.later = [call("Team retro", 125, .ready), call("Release checklist review", 245, .running)]
        m.monthSpend = 12.40
        m.monthCap = 100
        m.lastCallLine = L("menubar.lastCall", ["cost": "0.47", "n": "6"])
        m.thisCallSpend = 0.21
        keep.append(c); keep.append(app)
        guard let w = c.windowForShots() else { next(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            c.place()
            capture(w, live ? "menubar-panel-live-\(theme)" : "menubar-panel-\(theme)")
            w.orderOut(nil)
            next()
        }
    }

    /// First launch: the splash with the brand (Pacenote 0.8).
    func splash(_ theme: String) {
        OnboardingWindow.show()
        OnboardingWindow.model.step = .splash
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [self] in
            if let w = OnboardingWindow.window { capture(w, "onboarding-0-splash-\(theme)"); w.close() }
            next()
        }
    }

    /// First run: every onboarding step.
    func onboarding(_ st: OnboardingModel.Step, _ theme: String) {
        OnboardingWindow.show()
        OnboardingWindow.model.step = st
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [self] in
            if let w = OnboardingWindow.window { capture(w, "onboarding-\(st.rawValue)-\(st)-\(theme)") }
            if st == OnboardingModel.Step.allCases.last { OnboardingWindow.window?.close() }
            next()
        }
    }

    func tips(_ theme: String, presentation: Bool) {
        var pa = prompterArgs(["LiveTips", presentation ? "--prompter-demo-presentation" : "--prompter-demo"])
        pa.title = "Orbit weekly with the client"
        let c = PrompterController(args: pa)
        c.show()
        keep.append(c)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [self] in
            if !presentation {   // the transcript pane with named speakers, as during a call
                c.web.evaluateJavaScript("""
                  try { LiveTips.openTab('transcript');
                  window.setSpeakers({clusters:{S1:{name:'Emily C.',seconds:40,side:'client'},S2:{name:'David K.',seconds:22,side:'client'}},
                    roster:[{name:'Emily C.',side:'client'},{name:'David K.',side:'client'},{name:'Sarah L.',side:'team'}]});
                  window.addTranscript(['- Channels: Me = microphone, Other = system audio',
                    '[10:31:02] Emily C. [S1] (en): When is the export live for our users?',
                    '[10:31:09] Me (en): It is on dev now, production on Tuesday after the review.',
                    '[10:31:20] David K. [S2] (en): And who tests the pilot?',
                    '[10:31:26] Me (en): Our QA covers the first week, then your team.']); } catch (e) {}
                """, completionHandler: nil)
            }
            // The same size in both themes, so the dark and light pictures match on the site.
            c.window.setContentSize(presentation ? NSSize(width: 1040, height: 560) : NSSize(width: 1040, height: 640))
            if !presentation { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { c.window.setContentSize(NSSize(width: 1040, height: 640)) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [self] in
                capture(c.window, presentation ? "tips-presentation-\(theme)" : "tips-\(theme)", web: c.web) { [self] in
                    c.window.close()
                    next()
                }
            }
        }
    }

    func capture(_ w: NSWindow, _ name: String, web: WKWebView? = nil, done: (() -> Void)? = nil) {
        guard let frame = w.contentView?.superview, let base = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { done?(); return }
        // Always 2x (sharp on retina screens), whatever the scale of the screen the window is on.
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(frame.bounds.width * 2), pixelsHigh: Int(frame.bounds.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) ?? base
        rep.size = frame.bounds.size
        frame.cacheDisplay(in: frame.bounds, to: rep)
        func save() {
            let file = L10n.lang == "uk" ? name + "-uk" : name
            if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: out.appendingPathComponent(file + ".png")) }
            log("saved " + file)
            done?()
        }
        guard let web = web else { save(); return }
        web.takeSnapshot(with: nil) { img, _ in
            MainActor.assumeIsolated {
                if let img = img, let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                    var r = web.convert(web.bounds, to: frame)
                    if frame.isFlipped { r.origin.y = frame.bounds.height - r.maxY }
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = ctx
                    img.draw(in: r)
                    NSGraphicsContext.restoreGraphicsState()
                }
                save()
            }
        }
    }
}
