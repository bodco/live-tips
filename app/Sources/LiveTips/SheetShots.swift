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
        return s
    }

    // MARK: run

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        log("launched, work " + work)
        writeSheet()
        let only = ProcessInfo.processInfo.environment["LT_SHEETSHOTS_ONLY"] ?? ""
        for (lang, themes) in [("en", ["light", "dark"]), ("uk", ["light"])] {
            queue.append { [unowned self] in L10n.set(lang); next(0.3) }
            for t in themes {
                queue.append { [unowned self] in theme = t; NSApp.appearance = NSAppearance(named: t == "dark" ? .darkAqua : .aqua); next(0.3) }
                for sc in scenes() where only.isEmpty || sc.name.hasPrefix(only) {
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
