import AppKit
import LiveTipsCore
import SwiftUI

// 0.10.0 (Meeting Sheet, smoke): `LiveTips --render-sheet-shots <outdir>` (hidden developer flag) draws the new
// Meeting Sheet screens offscreen into PNG files (2x, light and dark, plus a Ukrainian pass), so the screens can be
// looked at without driving the real GUI. Demo data only (Emily Parker, Mike Carter, Lumenfield, Northwind Studio,
// Orbit): the support folder, the projects and the app root live in <outdir>/work, LT_SUPPORT_DIR points there
// before anything reads it, and the sheet sidecar is never started (SheetCLI.run returns at once). The PM's own
// projects, app folder and state are never read or written. Prints the written files and exits.
@MainActor
final class SheetShots: NSObject, NSApplicationDelegate {
    /// True while rendering: SheetCLI.run starts no sidecar.
    nonisolated(unsafe) static var active = false

    struct Scene {
        var name: String
        var size: NSSize
        var make: () -> AnyView
        var tweak: (() -> Void)? = nil
    }

    let out: URL
    let work: String
    var queue: [() -> Void] = []
    var files: [String] = []
    var theme = "light"
    var keep: [AnyObject] = []

    init(out: URL) {
        self.out = out
        self.work = out.appendingPathComponent("work").path
    }

    nonisolated static var repo: String {
        // <repo>/app/Sources/LiveTips/SheetShots.swift -> <repo>
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().path
    }

    /// Before the app starts: the demo support folder with its config, LT_SUPPORT_DIR, the sidecar off.
    nonisolated static func prepare(out: String) {
        let work = (out as NSString).appendingPathComponent("work")
        let sup = work + "/support"
        let fm = FileManager.default
        for d in [sup, work + "/app/state", work + "/projects"] { try? fm.createDirectory(atPath: d, withIntermediateDirectories: true) }
        setenv("LT_SUPPORT_DIR", sup, 1)
        active = true
        let cfg: [String: Any] = ["workRoot": work + "/projects", "appRoot": work + "/app", "uiLanguage": "en", "speakersEnabled": true]
        if let d = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted]) { try? d.write(to: URL(fileURLWithPath: sup + "/config.json")) }
        // Projects: a sales project (the sheet) and Orbit (a call prepared in 0.9.7).
        let sales = work + "/projects/Northwind Studio/Northwind Sales", orbit = work + "/projects/Northwind Studio/Orbit SaaS Launch"
        for d in [sales + "/live", sales + "/cases", orbit + "/live"] { try? fm.createDirectory(atPath: d, withIntermediateDirectories: true) }
        var reg = ProjectRegistry()
        var s = Project(name: "Northwind Sales", slug: "northwind-sales", root: sales)
        s.workspace = "Northwind Studio"
        s.people = [.init(name: "Mike Carter", role: "Account executive", side: "team"), .init(name: "Emily Parker", role: "VP Operations", side: "client")]
        var o = Project(name: "Orbit SaaS Launch", slug: "orbit-saas-launch", root: orbit)
        o.workspace = "Northwind Studio"
        o.people = [.init(name: "Mike Carter", role: "PM", side: "team"), .init(name: "Sarah M.", role: "Product owner", side: "client")]
        reg.projects = [s, o]
        reg.workspaces = [Workspace(name: "Northwind Studio", root: work + "/projects/Northwind Studio", projects: [s.slug, o.slug])]
        reg.lastUsed = "project:northwind-sales"
        if let d = try? JSONEncoder().encode(reg) { try? d.write(to: URL(fileURLWithPath: sup + "/projects.json")) }
        try? "# Lumenfield-like case: Northwind Studio reporting automation\n\nMonthly reports went from three days to two hours.\n"
            .write(toFile: sales + "/cases/northwind-studio-reporting.md", atomically: true, encoding: .utf8)
        try? "# Pricing notes\n\nDiscovery workshop: fixed price.\n".write(toFile: sales + "/cases/pricing-notes.md", atomically: true, encoding: .utf8)
        prepareB7b(sales: sales)
    }

    // MARK: 0.11.0 (B7a, B7b smoke): Settings > Account, Settings > Call recording, the call page's recording line

    /// Three demo calls in Northwind Sales: a recording in Drive with its transcript, a recording whose Drive folder is
    /// gone, a call without a recording whose transcript is in Drive. Only meta files; no audio or video.
    nonisolated static func prepareB7b(sales: String) {
        try? FileManager.default.createDirectory(atPath: sales + "/video", withIntermediateDirectories: true)
        let start = Date().addingTimeInterval(-26 * 3600)
        for (stem, state) in [("2026-11-14-1030-weekly-sync", "uploaded"), ("2026-11-14-1500-pricing-review", "gone"), ("2026-11-14-1700-quick-check", "none")] {
            let t = sales + "/live/" + stem + ".app.md"
            try? "# Live transcript: x\n\n[10:30:05] Me (en): Hi Emily\n".write(toFile: t, atomically: true, encoding: .utf8)
            if state != "none" {
                var m = RecordingMeta(); m.title = "Weekly sync"; m.project = "Northwind Sales"
                var p = RecordingMeta.Part(file: stem + ".recording.mp4", kind: "video", started: start); p.seconds = 1860; p.bytes = 212_000_000
                if state == "uploaded" {
                    p.driveID = "demo-file"; p.driveLink = "https://drive.google.com/file/d/demo-file/view"; p.driveAccount = "mike@example.com"
                    p.driveFolderID = "demo-project"; p.driveKind = "shared_drive"
                } else { p.driveError = RecordingMeta.Part.folderUnavailable }
                m.parts = [p]
                m.save(RecordingFiles.metaPath(transcript: t))
            }
            if state != "gone" {
                var d = DriveTranscriptMeta(); d.fileID = "demo-md"; d.link = "https://drive.google.com/file/d/demo-md/view"; d.kind = "shared_drive"
                d.account = "mike@example.com"; d.hash = "x"
                d.save(DriveTranscript.metaPath(transcript: t))
            }
        }
    }

    var salesLive: String { work + "/projects/Northwind Studio/Northwind Sales/live/" }

    func b7bScenes() -> [Scene] {
        var s: [Scene] = []
        let mike = GoogleAccount(email: "mike@example.com", refreshToken: "demo", scopes: GoogleScopes.export)
        let emily = GoogleAccount(email: "emily@example.com", refreshToken: "demo", scopes: GoogleScopes.export)
        func store(root: DriveFolderStore.Folder?) -> DriveFolderStore {
            var st = DriveFolderStore()
            if let r = root { st.setRoot(mike.email, r); st.setProject(mike.email, "Northwind Sales", .init(id: "demo-project", name: "Northwind Sales", driveId: r.driveId)) }
            return st
        }
        let me: (Bool) -> PacenoteServer.Me? = { req in
            PacenoteServer.me(["user": ["email": "mike@example.com", "name": "Mike Carter"], "organizations": [
                ["id": "o1", "name": "Mike's workspace", "kind": "personal", "org_role": "owner", "plan": "beta"],
                ["id": "o2", "name": "Northwind Studio", "kind": "team", "org_role": "member", "plan": "team",
                 "policy": ["require_transcript_in_drive": req]]]])
        }
        func rec(_ name: String, accounts: [GoogleAccount], root: DriveFolderStore.Folder?, state: DriveFolderState? = nil,
                 transcript: String = "off", required: Bool = false, error: String? = nil) -> Scene {
            Scene(name: "settings-recording-" + name, size: NSSize(width: 720, height: 1500), make: { [unowned self] in
                RecordingSettingsPane.shotAccounts = accounts
                DriveRecordings.shared.shotState(store: store(root: root), rootState: state.map { [mike.email: $0] } ?? [:],
                                                 errors: error.map { ["settings": $0] } ?? [:])
                PacenoteAccount.shared.shotState(session: nil, me: required ? me(true) : nil)
                let lang = L10n.lang                 // saving the config sets the language from it: keep the pass's language
                let m = SettingsModel()
                var c = m.config
                c.uiLanguage = lang
                c.recording.kind = "audio"; c.recording.drive = "auto"; c.recording.transcriptDrive = transcript; c.recording.driveAccount = ""
                m.config = c
                L10n.set(lang)
                keep.append(m)
                return AnyView(RecordingSettingsPane(model: m))
            })
        }
        s.append(rec("no-account", accounts: [], root: nil))
        s.append(rec("first-upload", accounts: [mike, emily], root: nil))
        s.append(rec("my-drive", accounts: [mike], root: .init(id: "demo-root", name: "Pacenote"), state: .ok, transcript: "with_recording"))
        s.append(rec("shared-drive", accounts: [mike], root: .init(id: "demo-root", name: "Pacenote", driveId: "demo-shared"), state: .ok, transcript: "every_call"))
        s.append(rec("folder-gone", accounts: [mike], root: .init(id: "demo-root", name: "Pacenote"), state: .unavailable))
        s.append(rec("required", accounts: [mike], root: .init(id: "demo-root", name: "Pacenote", driveId: "demo-shared"), state: .ok, required: true))
        for (n, stem) in [("uploaded", "2026-11-14-1030-weekly-sync"), ("folder-gone", "2026-11-14-1500-pricing-review"), ("transcript-only", "2026-11-14-1700-quick-check")] {
            s.append(Scene(name: "row-recording-" + n, size: NSSize(width: 1000, height: 140), make: { [unowned self] in
                RecordingSettingsPane.shotAccounts = [mike]
                DriveRecordings.shared.shotState(store: store(root: .init(id: "demo-root", name: "Pacenote")))
                return AnyView(RecordingRow(file: salesLive + stem + ".app.md").padding(20))
            }))
        }
        s.append(Scene(name: "settings-account-signed-out", size: NSSize(width: 720, height: 900), make: {
            PacenoteAccount.shared.shotState(session: nil, me: nil)
            return AnyView(AccountSettingsPane())
        }))
        s.append(Scene(name: "settings-account-signed-in", size: NSSize(width: 720, height: 1300), make: {
            let ses = PacenoteServer.Session(refreshToken: "demo", refreshExpires: Date().addingTimeInterval(50 * 86400),
                                             email: "mike@example.com", name: "Mike Carter")
            let iso = ISO8601DateFormatter()
            let devs = PacenoteServer.devices([
                ["id": "d1", "name": "Mike's MacBook Pro", "app_version": "0.11.0", "last_seen_at": iso.string(from: Date()), "current": true],
                ["id": "d2", "name": "Mike's Mac mini", "app_version": "0.10.2", "last_seen_at": iso.string(from: Date().addingTimeInterval(-3 * 86400))]])
            PacenoteAccount.shared.shotState(session: ses, me: me(false), devices: devs)
            return AnyView(AccountSettingsPane())
        }))
        return s
    }

    // MARK: demo calls

    lazy var callDate: Date = {
        let cal = Calendar.current
        let d = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return cal.date(bySettingHour: 16, minute: 0, second: 0, of: d) ?? d
    }()

    lazy var sales: StartCallModel = {
        let m = StartCallModel()
        m.target = "project:northwind-sales"
        m.title = "Intro with Emily Parker"
        m.language = "en"
        m.audience = "client"
        m.salesEnabled = true
        m.salesMethod = "bant"
        m.callDate = callDate
        m.context = "Goal: understand Lumenfield's reporting pain and agree on a discovery workshop\nParticipants: Emily Parker"
        return m
    }()

    lazy var legacy: StartCallModel = {
        let m = StartCallModel()
        m.target = "project:orbit-saas-launch"
        m.title = "Orbit weekly sync"
        m.language = "en"
        m.audience = "client"
        m.callDate = callDate.addingTimeInterval(-5 * 3600)
        m.context = "Goal: agree the pilot plan\nParticipants: Sarah M., Jake T."
        return m
    }()

    var sheetPath = ""

    /// The sales intro fixture with a conflict, a "was X" fact (newer wins), an old fact, a skipped source and a
    /// Refresh diff; version 1 next to it for the Versions tab.
    func writeSheet() {
        guard let live = SheetFiles.liveFolder(sales), let base = SheetFiles.newBase(for: sales) else { log("no live folder"); return }
        try? FileManager.default.createDirectory(atPath: live, withIntermediateDirectories: true)
        let fx = Self.repo + "/spikes/m0/tests/fixtures/sheet/sales-intro-lumenfield.sheet.json"
        guard let data = FileManager.default.contents(atPath: fx),
              var o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { log("no fixture at " + fx); return }
        try? data.write(to: URL(fileURLWithPath: base + ".sheet.v1.json"))
        var blocks = o["blocks"] as? [[String: Any]] ?? []
        for i in blocks.indices {
            var facts = blocks[i]["facts"] as? [[String: Any]] ?? []
            switch blocks[i]["type"] as? String {
            case "my_focus":
                facts = [["id": "f-focus-dm", "label": "Decision maker", "text": "Emily decides together with the CEO", "source_ids": ["s2"],
                          "status": "found", "origin": "model", "checked_at": "2026-11-12T09:00:00+02:00"],
                         ["id": "f-focus-next", "label": "Next step", "text": "Book a discovery workshop for next week", "source_ids": ["s5"],
                          "status": "found", "origin": "model", "checked_at": "2026-11-12T09:00:00+02:00"]]
            case "contact":
                if !facts.isEmpty { facts[0]["diff"] = "changed" }
                facts.append(["id": "f-contact-old", "label": "Title", "text": "Director of Operations at Lumenfield", "source_ids": ["s3"],
                              "status": "stale", "origin": "model", "superseded_by": "f-contact-title", "conflict_with": ["f-contact-title"],
                              "checked_at": "2026-11-12T09:00:00+02:00"])
            case "signals":
                if !facts.isEmpty { facts[0]["status"] = "stale" }
            case "questions":
                if !facts.isEmpty { facts[0]["diff"] = "new" }
                facts.append(["id": "f-q-budget-ask", "text": "Is there a budget set aside for reporting this year?", "source_ids": [String](),
                              "status": "found", "origin": "auto", "diff": "new"])
            default: break
            }
            blocks[i]["facts"] = facts
        }
        o["blocks"] = blocks
        var src = o["sources"] as? [[String: Any]] ?? []
        src.append(["id": "s6", "n": 6, "type": "gdoc", "title": "Lumenfield discovery notes", "access": "denied", "used": "skipped",
                    "access_reason": "No access with the connected Google account", "fix_action": "connect_google",
                    "reason": "Skipped: no access", "uri": "https://docs.google.com/document/d/demo"])
        src.append(["id": "s7", "n": 7, "type": "web_page", "title": "Lumenfield - Blog", "size_tokens": 4000, "access": "ok", "used": "truncated",
                    "reason": "Cut at 256 KB of 410 KB", "uri": "https://lumenfield.example/blog"])
        o["sources"] = src
        var versions = o["versions"] as? [[String: Any]] ?? []
        versions.append(["n": 2, "built_at": "2026-11-12T18:00:00+02:00", "route": "claude_account", "note": "refresh"])
        o["versions"] = versions
        o["refreshed_at"] = "2026-11-12T18:00:00+02:00"
        if let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: URL(fileURLWithPath: base + ".sheet.json")) }
        sales.prepBase = base
        sheetPath = base + ".sheet.json"
        // A call prepared in 0.9.7: a brief, no sheet.
        if let lb = SheetFiles.newBase(for: legacy) {
            try? FileManager.default.createDirectory(atPath: (lb as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let brief = "# Live Brief: Orbit weekly sync\n\n**Goal:** agree the pilot plan.\n\n## Agenda\n- [ ] Pilot start date\n- [ ] Who tests week one\n- [ ] Test accounts from Sarah M.\n\n## Open questions\n- Does Jake T. join the pilot review?\n"
            try? brief.write(toFile: lb + ".brief.md", atomically: true, encoding: .utf8)
            legacy.prepBase = lb
        }
    }

    // MARK: drafts (Quick and Expert)

    func src(_ type: String, _ title: String, path: String? = nil, uri: String? = nil, access: String = "ok", reason: String? = nil,
             fix: String? = nil, tokens: Int? = nil, auto: Bool = false, why: [String] = []) -> DraftSource {
        DraftSource(type: type, path: path, uri: uri, title: title, auto: auto, why: why, access: access, reason: reason, fix: fix, tokens: tokens)
    }

    var casePath: String { (sales.root ?? "") + "/cases/northwind-studio-reporting.md" }

    func draft(_ mode: SheetMode, step: Int = 1, remembered: Bool = true, attention: Bool = false, linkedIn: String? = nil) -> SheetDraft {
        let d = SheetDraft(model: sales)
        d.mode = mode
        d.step = step
        d.remembered = remembered
        d.presetSuggested = !remembered
        d.applyPreset("sales_intro")
        d.goal = "Understand Lumenfield's reporting pain and agree on a discovery workshop"
        d.ours = [DraftPerson(name: "Mike Carter", role: "Account executive")]
        d.theirs = [DraftPerson(name: "Emily Parker", role: "VP Operations", company: "Lumenfield", domain: "lumenfield.example")]
        d.sources = [src("folder_file", "cases/northwind-studio-reporting.md", path: casePath, tokens: 900, auto: true, why: ["same industry"]),
                     src("web", "lumenfield.example/about", uri: "https://lumenfield.example/about", tokens: 900),
                     src("linkedin_manual", "Emily Parker (filled in by hand)", access: "ok", tokens: 120)]
        if attention {
            d.sources.append(src("gdoc", "Lumenfield discovery notes", uri: "https://docs.google.com/document/d/demo", access: "denied",
                                 reason: "No access with the connected Google account", fix: "connect_google"))
        }
        if let r = linkedIn {
            d.sources.removeAll { $0.type == "linkedin_manual" }
            d.sources.append(src("linkedin", "Emily Parker", uri: "https://www.linkedin.com/in/emily-parker-example", access: "denied", reason: r, fix: "save_as_pdf"))
        }
        d.candidates = [src("folder_file", "cases/pricing-notes.md", path: (sales.root ?? "") + "/cases/pricing-notes.md", tokens: 40, auto: true, why: ["mentions the workshop"]),
                        src("folder_file", "live/2026-10-30-1500-lumenfield-first-email.md", tokens: 300, auto: true, why: ["same company", "last 30 days"])]
        d.candidates[1].checked = true
        d.candidateNote = ""
        return d
    }

    func size(_ state: String, _ total: Int) -> SizeReport? {
        try? JSONDecoder().decode(SizeReport.self, from: JSONSerialization.data(withJSONObject: [
            "route": AIRoute.code, "window": 200_000, "reserve": 12_000, "total_tokens": total, "state": state]))
    }

    func job(done: Bool, d: SheetDraft) -> SheetJob {
        let j = SheetJob(callID: sales.id, kind: "build")
        if done {
            j.done = true; j.progress = 1; j.sheetPath = sheetPath
        } else {
            j.progress = 0.55; j.stage = "Reading sources: Lumenfield - About"; j.pass = 1; j.passes = 2
            let ids = d.sources.filter(\.checked).map(\.id)
            if ids.count > 0 { j.sourceState[ids[0]] = "read" }
            if ids.count > 1 { j.sourceState[ids[1]] = "reading" }
            if ids.count > 2 { j.sourceState[ids[2]] = "failed"; j.sourceNote[ids[2]] = "The page did not answer in 30 s" }
        }
        keep.append(j)
        return j
    }

    // MARK: scenes

    func page(_ m: StartCallModel, _ tab: String) -> AnyView {
        UpcomingCallPage.shotTab = tab
        let v = UpcomingCallPage(model: m)
        UpcomingCallPage.shotTab = nil
        return AnyView(v)
    }

    func scenes() -> [Scene] {
        var s: [Scene] = []
        let wide = NSSize(width: 1200, height: 2600)
        for tab in ["sheet", "readiness", "sources", "versions"] {
            s.append(Scene(name: "page-\(tab)", size: tab == "sheet" ? NSSize(width: 1200, height: 3400) : wide, make: { [unowned self] in page(sales, tab) }))
        }
        s.append(Scene(name: "page-legacy-097", size: NSSize(width: 1200, height: 1400), make: { [unowned self] in page(legacy, "sheet") }))
        let prep = NSSize(width: 860, height: 1300)
        func prepScene(_ name: String, _ d: @escaping () -> SheetDraft, tweak: ((SheetDraft) -> Void)? = nil, size: NSSize = prep) -> Scene {
            var made: SheetDraft?
            return Scene(name: name, size: size, make: { let x = d(); made = x; return AnyView(SheetPrepView(draft: x)) },
                         tweak: { if let x = made { x.checking = false; tweak?(x) } })
        }
        s.append(prepScene("quick-ready", { [unowned self] in draft(.quick) }))
        s.append(prepScene("quick-attention", { [unowned self] in draft(.quick, attention: true) }))
        s.append(prepScene("quick-first", { [unowned self] in draft(.quick, remembered: false) }))
        s.append(prepScene("quick-done", { [unowned self] in let d = draft(.quick); d.job = job(done: true, d: d); return d }))
        s.append(prepScene("expert-1-meeting", { [unowned self] in draft(.expert, step: 1) }))
        s.append(prepScene("expert-2-blocks", { [unowned self] in draft(.expert, step: 2) }, size: NSSize(width: 860, height: 1600)))
        s.append(prepScene("expert-3-sources", { [unowned self] in draft(.expert, step: 3, attention: true, linkedIn: "LinkedIn asks to sign in (authwall)") }, size: NSSize(width: 860, height: 1800)))
        for (st, total) in [("fits", 2_000), ("near", 168_000), ("too_much", 262_000)] {
            s.append(prepScene("expert-4-size-\(st)", { [unowned self] in
                let d = draft(.expert, step: 4)
                d.size = size(st, total)
                if st == "too_much" { d.plan = "passes" }       // no modal sheet on the offscreen window
                if st != "fits" { d.sources.append(src("file", "Lumenfield board deck 2026.pdf", path: casePath, tokens: total - 1_900)) }
                return d
            }, tweak: { d in if st == "too_much" { d.plan = "" } }))
        }
        s.append(Scene(name: "expert-4-too-much-modal", size: NSSize(width: 460, height: 700), make: { [unowned self] in
            let d = draft(.expert, step: 4); d.size = size("too_much", 262_000); d.plan = ""
            keep.append(d)
            return AnyView(SheetTooMuch(draft: d, done: {}).background(Color(nsColor: .windowBackgroundColor)))
        }))
        s.append(prepScene("expert-5-build", { [unowned self] in let d = draft(.expert, step: 5); d.job = job(done: false, d: d); return d }))
        s.append(prepScene("expert-5-done", { [unowned self] in let d = draft(.expert, step: 5); d.job = job(done: true, d: d); return d }))
        s.append(Scene(name: "switch-prompt-build", size: prep, make: { [unowned self] in
            let d = draft(.expert, step: 5); d.job = job(done: false, d: d)
            SheetRunner.shared.shotQuestion(from: AIRoute.code, to: AIRoute.codex, reason: "Claude Code: the weekly limit is used up until 07:10", call: sales)
            keep.append(d)
            return AnyView(SheetPrepView(draft: d))
        }, tweak: nil))
        s.append(Scene(name: "linkedin-states", size: NSSize(width: 720, height: 2000), make: { [unowned self] in
            let d = draft(.expert, step: 3)
            keep.append(d)
            let reasons = ["robots.txt does not allow reading this page", "LinkedIn asks to sign in (authwall)", "The owner hides this profile",
                           "The page came back empty", ""]
            let cards = reasons.map { r -> DraftSource in
                var x = src("linkedin", "Emily Parker", uri: "https://www.linkedin.com/in/emily-parker-example", access: r.isEmpty ? "ok" : "denied", reason: r.isEmpty ? nil : r)
                x.checked = true
                return x
            }
            return AnyView(VStack(alignment: .leading, spacing: 14) {
                ForEach(cards) { c in SheetLinkedInCard(draft: d, source: .constant(c)) }
            }.padding(24))
        }))
        s.append(Scene(name: "settings-meeting-sheet", size: NSSize(width: 720, height: 1100), make: {
            AnyView(MeetingSheetSettingsPane().formStyle(.grouped))
        }))
        s.append(Scene(name: "export-sheet", size: NSSize(width: 600, height: 700), make: { [unowned self] in
            let doc = SheetDoc(path: sheetPath)
            keep.append(doc)
            return AnyView(SheetExportView(doc: doc, done: {}).background(Color(nsColor: .windowBackgroundColor)))
        }))
        s += b7bScenes()
        s += d3Scenes()
        return s
    }

    /// 0.16.0 (D3 smoke): the seven onboarding steps at the window's own size, What's new (as after 0.15.0, every item),
    /// Settings > Components and Help > What's new. Read-only: the steps only check what is installed, nothing is set.
    func d3Scenes() -> [Scene] {
        var s: [Scene] = []
        for st in OnboardingModel.Step.allCases {
            s.append(Scene(name: "d3-onb-\(st.rawValue)-\(st)", size: NSSize(width: 760, height: 680), make: {
                let m = OnboardingModel()
                m.step = st
                return AnyView(OnboardingView(m: m, close: {}))
            }))
        }
        s.append(Scene(name: "d3-whatsnew", size: NSSize(width: 760, height: 680), make: {
            let all = WhatsNew.pending(WhatsNewStore.items, lastSeen: "0.14.0", current: "0.16.0", facts: ["provider:claude", "module:tracker", "os:15"])
            return AnyView(WhatsNewView(items: all, from: "0.14.0") { _ in })
        }))
        s.append(Scene(name: "d3-settings-components", size: NSSize(width: 720, height: 1000), make: {
            AnyView(SettingsComponentsPane())
        }, tweak: nil))
        s.append(Scene(name: "d3-help-whatsnew", size: NSSize(width: 720, height: 900), make: {
            AnyView(ScrollView { WhatsNewHistory().padding(24) })
        }))
        return s
    }

    // MARK: run

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        log("launched, work " + work)
        writeSheet()
        let only = ProcessInfo.processInfo.environment["LT_SHEETSHOTS_ONLY"] ?? ""   // a prefix, or several split by commas
        for (lang, themes) in [("en", ["light", "dark"]), ("uk", ["light"])] {
            queue.append { [unowned self] in L10n.set(lang); next(0.3) }
            for t in themes {
                queue.append { [unowned self] in theme = t; NSApp.appearance = NSAppearance(named: t == "dark" ? .darkAqua : .aqua); next(0.3) }
                for sc in scenes() where only.isEmpty || only.split(separator: ",").contains(where: { sc.name.hasPrefix(String($0)) }) {
                    queue.append { [unowned self] in shoot(sc, suffix: "-" + t + (lang == "uk" ? "-uk" : "")) }
                }
            }
        }
        queue.append { [unowned self] in
            log("done, \(files.count) files")
            for f in files { print(f) }
            fflush(stdout)
            exit(0)
        }
        next(0.5)
    }

    func next(_ after: Double = 0.1) {
        DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
            guard let self, !self.queue.isEmpty else { return }
            self.queue.removeFirst()()
        }
    }

    func shoot(_ sc: Scene, suffix: String) {
        let dark = theme == "dark"
        let content = sc.make()
        let root = AnyView(Localized { content }
            .frame(width: sc.size.width, height: sc.size.height, alignment: .top)
            .background(PN.C.bg))
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: sc.size)
        let w = NSWindow(contentRect: NSRect(x: -40000, y: -40000, width: sc.size.width, height: sc.size.height),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.isReleasedWhenClosed = false
        w.contentView = host
        w.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
            sc.tweak?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [self] in
                host.layoutSubtreeIfNeeded()
                save(host, sc.name + suffix, fallback: root, dark: dark)
                w.orderOut(nil)
                w.contentView = nil
                w.close()
                SheetRunner.shared.pendingSwitch = nil
                next(0.1)
            }
        }
    }

    func save(_ host: NSView, _ name: String, fallback: AnyView, dark: Bool) {
        let b = host.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width * 2), pixelsHigh: Int(b.height * 2), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { log("no bitmap for " + name); return }
        rep.size = b.size
        host.cacheDisplay(in: b, to: rep)
        var img = trim(rep)
        if img == nil {
            // Nothing was drawn (no window server drawing): SwiftUI's own renderer instead.
            log("blank cacheDisplay for " + name + ", ImageRenderer")
            let r = ImageRenderer(content: fallback.environment(\.colorScheme, dark ? .dark : .light))
            r.scale = 2
            var cg: CGImage?
            NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance { MainActor.assumeIsolated { cg = r.cgImage } }
            if let cg { img = trim(NSBitmapImageRep(cgImage: cg)) ?? NSBitmapImageRep(cgImage: cg) }
        }
        guard let final = img, let png = final.representation(using: .png, properties: [:]) else { log("not saved " + name); return }
        let url = out.appendingPathComponent(name + ".png")
        try? png.write(to: url)
        files.append(url.path)
        log("saved " + name)
    }

    /// Cuts the empty background below the content (the windows are tall so long pages fit). nil = nothing drawn.
    func trim(_ rep: NSBitmapImageRep) -> NSBitmapImageRep? {
        guard let data = rep.bitmapData, rep.samplesPerPixel >= 3 else { return rep }
        let w = rep.pixelsWide, h = rep.pixelsHigh, bpr = rep.bytesPerRow, spp = rep.samplesPerPixel
        func px(_ x: Int, _ y: Int) -> (Int, Int, Int, Int) {
            let o = y * bpr + x * spp
            return (Int(data[o]), Int(data[o + 1]), Int(data[o + 2]), spp > 3 ? Int(data[o + 3]) : 255)
        }
        let ref = px(min(4, w - 1), h - 4)
        var last = h - 1
        outer: while last > 0 {
            var x = 0
            while x < w {
                let p = px(x, last)
                if abs(p.0 - ref.0) > 8 || abs(p.1 - ref.1) > 8 || abs(p.2 - ref.2) > 8 || abs(p.3 - ref.3) > 8 { break outer }
                x += 2
            }
            last -= 1
        }
        if last <= 0 { return nil }
        let newH = min(h, last + 1 + 64)
        if newH >= h - 2 { return rep }
        guard let cg = rep.cgImage?.cropping(to: CGRect(x: 0, y: 0, width: w, height: newH)) else { return rep }
        let r = NSBitmapImageRep(cgImage: cg)
        r.size = NSSize(width: CGFloat(w) / 2, height: CGFloat(newH) / 2)
        return r
    }

    func log(_ m: String) {
        let f = out.appendingPathComponent("sheet-shots.log")
        let line = "\(Date()) \(m)\n"
        if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
        else { try? line.write(to: f, atomically: true, encoding: .utf8) }
    }
}
