import AppKit
import LiveTipsCore
import SwiftUI

// 0.25 (R3a): `LT_SHEETSHOTS_ONLY=r3 LiveTips --render-sheet-shots <outdir>` draws the preparation screens of the boards
// SU (Start a call, Plan a call, no project), QP (Quick: ok, attention, building, done, failed, live), EA (Expert steps 1-3),
// EB (Expert steps 4-5: too much, build, error, done) and RS (Readiness, Sources, Versions) in every style and mode,
// English only, so they can be laid next to the boards. Demo data of the boards: Orbit and Northwind in Acme Studio,
// Emily Carter, Sarah Lopez, Ryan Cole, Mike Reed, Jessica Moore. Shot code only: no screen changes here.
extension SheetShots {
    nonisolated static var r3: Bool { ProcessInfo.processInfo.environment["LT_SHEETSHOTS_ONLY"] == "r3" }

    /// Before the app starts: the two board projects next to the smoke ones, and a few files in their folders.
    nonisolated static func prepareR3(work: String) {
        let sup = work + "/support", fm = FileManager.default
        let root = work + "/projects/Acme Studio", orbit = root + "/Orbit", nw = root + "/Northwind"
        for d in [orbit + "/live", orbit + "/docs", nw + "/live", nw + "/docs"] { try? fm.createDirectory(atPath: d, withIntermediateDirectories: true) }
        for f in ["Status report Nov 14.docx", "Old kickoff notes.md", "Orbit roadmap.md"] { try? "# \(f)\n".write(toFile: orbit + "/docs/" + f, atomically: true, encoding: .utf8) }
        for f in ["Pilot scope draft v2.docx", "Security questionnaire.xlsx", "Case study: Fleetwise.pdf", "Old proposal 2025.pptx"] {
            try? "# \(f)\n".write(toFile: nw + "/docs/" + f, atomically: true, encoding: .utf8)
        }
        var reg = (try? JSONDecoder().decode(ProjectRegistry.self, from: Data(contentsOf: URL(fileURLWithPath: sup + "/projects.json")))) ?? ProjectRegistry()
        var o = Project(name: "Orbit", slug: "orbit", root: orbit)
        o.workspace = "Acme Studio"
        o.people = [.init(name: "Mike Reed", role: "PM", side: "team"), .init(name: "Emily Carter", role: "Product lead", side: "client"),
                    .init(name: "Sarah Lopez", role: "Security", side: "client")]
        var n = Project(name: "Northwind", slug: "northwind", root: nw)
        n.workspace = "Acme Studio"
        n.people = [.init(name: "Mike Reed", role: "Account executive", side: "team"), .init(name: "Jessica Moore", role: "Head of Operations", side: "client")]
        reg.projects += [o, n]
        reg.workspaces.append(Workspace(name: "Acme Studio", root: root, projects: [o.slug, n.slug]))
        reg.lastUsed = "project:orbit"
        if let d = try? JSONEncoder().encode(reg) { try? d.write(to: URL(fileURLWithPath: sup + "/projects.json")) }
    }

    // MARK: models and drafts

    func r3Call(_ project: String, _ title: String, minutes: Double, sales: Bool = false) -> StartCallModel {
        let m = StartCallModel()
        m.target = project.isEmpty ? "" : "project:" + project
        m.title = title
        m.language = "en"
        m.audience = "client"
        m.salesEnabled = sales
        m.callDate = Date().addingTimeInterval(minutes * 60)
        return m
    }

    var r3Orbit: String { work + "/projects/Acme Studio/Orbit" }
    var r3North: String { work + "/projects/Acme Studio/Northwind" }

    /// The Lumenfield fixture with the board's names, as the sheet of this call (for Done and the page tabs).
    func r3Sheet(_ m: StartCallModel) -> String? {
        guard let live = SheetFiles.liveFolder(m), let base = SheetFiles.newBase(for: m) else { return nil }
        try? FileManager.default.createDirectory(atPath: live, withIntermediateDirectories: true)
        let fx = Self.repo + "/spikes/m0/tests/fixtures/sheet/sales-intro-lumenfield.sheet.json"
        guard var s = try? String(contentsOfFile: fx, encoding: .utf8) else { log("r3: no fixture"); return nil }
        for (a, b) in [("lumenfield.example", "northwindlabs.com"), ("Lumenfield", "Northwind Labs"), ("Emily Parker", "Jessica Moore"),
                       ("Emily", "Jessica"), ("Mike Carter", "Mike Reed"), ("Northwind Studio", "Acme Studio")] { s = s.replacingOccurrences(of: a, with: b) }
        try? s.write(toFile: base + ".sheet.v1.json", atomically: true, encoding: .utf8)
        try? s.write(toFile: base + ".sheet.v2.json", atomically: true, encoding: .utf8)
        try? s.write(toFile: CallLayout.sidecar(base, ".sheet.json"), atomically: true, encoding: .utf8)
        m.prepBase = base
        return CallLayout.sidecar(base, ".sheet.json")
    }

    /// The two board calls, made once (a static store: an extension keeps no stored properties).
    static var r3Models: [String: StartCallModel] = [:]
    var r3Weekly: StartCallModel {
        if let m = Self.r3Models["weekly"] { return m }
        let m = r3Call("orbit", "Weekly sync with Emily Carter", minutes: 37)
        Self.r3Models["weekly"] = m
        return m
    }
    var r3Pilot: StartCallModel {
        if let m = Self.r3Models["pilot"] { return m }
        let m = r3Call("northwind", "Pilot scoping with Northwind Labs", minutes: 26 * 60, sales: true)
        m.salesMethod = "bant"
        Self.r3Models["pilot"] = m
        _ = r3Sheet(m)
        return m
    }

    func r3Quick(_ kind: String) -> SheetDraft {
        let d = SheetDraft(model: r3Weekly)
        d.mode = .quick
        d.applyPreset("client_sync")
        d.presetSuggested = false
        d.remembered = kind != "attn"
        d.live = kind == "live"
        d.goal = "Agree the March release scope and the SSO plan"
        d.ours = [DraftPerson(name: L("sheet.ui.you"), you: true), DraftPerson(name: "Mike Reed", company: "Acme Studio")]
        d.theirs = [DraftPerson(name: "Emily Carter", company: "Orbit"), DraftPerson(name: "Sarah Lopez", company: "Orbit")]
        if kind == "attn" { d.theirs.append(DraftPerson(name: "Ryan Cole", company: "Acme Studio")) }
        d.sources = [src("folder", "Orbit project folder", path: r3Orbit + "/docs", tokens: 9_000, auto: true, why: ["project folder"]),
                     src("file", "Status report Nov 14.docx", path: r3Orbit + "/docs/Status report Nov 14.docx", tokens: 2_000),
                     src("file", "Orbit roadmap.md", path: r3Orbit + "/docs/Orbit roadmap.md", tokens: 3_000),
                     src("prev_call", "Weekly sync, Tue 10 Nov", tokens: 4_000, auto: true, why: ["same series"])]
        if kind == "attn" {
            d.sources.insert(src("gdoc", "SSO plan", uri: "https://docs.google.com/document/d/sso-plan", access: "denied",
                                 reason: "No access with you@acme.studio", fix: "connect_google"), at: 1)
            d.special = "SSO plan is here: https://docs.google.com/document/d/sso-plan"
        } else {
            d.special = kind == "live" ? "Emily brought Sarah in; she runs security now" : "Emily may push SSO back into March"
        }
        switch kind {
        case "building": d.job = r3Job(d, done: false)
        case "done": d.job = r3Job(d, done: true)
        case "failed": d.job = r3Job(d, done: false, failed: "Claude account: the weekly limit is used up until 07:10")
        default: break
        }
        return d
    }

    func r3Expert(_ step: Int) -> SheetDraft {
        let d = SheetDraft(model: r3Pilot)
        d.mode = .expert
        d.step = step
        d.applyPreset("sales_intro")
        d.presetSuggested = false
        d.remembered = false
        d.goal = "Agree the pilot scope and who signs off security"
        d.ours = [DraftPerson(name: L("sheet.ui.you"), you: true), DraftPerson(name: "Mike Reed", company: "Acme Studio")]
        d.theirs = [DraftPerson(name: "Jessica Moore", company: "Northwind Labs", domain: "northwindlabs.com"),
                    DraftPerson(name: "Daniel Kim", company: "Northwind Labs", domain: "northwindlabs.com"),
                    DraftPerson(name: "Priya Shah", company: "Northwind Labs", domain: "northwindlabs.com")]
        d.sources = [src("folder", "Northwind project folder", path: r3North + "/docs", tokens: 12_000, auto: true, why: ["project folder"]),
                     src("gdoc", "Northwind discovery notes", uri: "https://docs.google.com/document/d/nw-notes", tokens: 6_000, why: ["used last time"]),
                     src("web", "northwindlabs.com", uri: "https://northwindlabs.com", tokens: 9_000),
                     src("text", "Email thread with Jessica, Nov 12", tokens: 600),
                     src("gsheet", "Pilot pricing 2027", uri: "https://docs.google.com/spreadsheets/d/nw-pricing", access: "denied",
                         reason: "No access with you@acme.studio", fix: "paste_text"),
                     src("prev_call", "Discovery call, Mon 16 Nov", tokens: 4_000, auto: true, why: ["same company"])]
        if step == 3 {
            d.sources.append(src("linkedin", "Jessica Moore", uri: "https://www.linkedin.com/in/jessica-moore-example", access: "denied",
                                 reason: "LinkedIn asks to sign in (authwall)", fix: "save_as_pdf"))
        }
        d.candidates = [src("file", "Pilot scope draft v2.docx", path: r3North + "/docs/Pilot scope draft v2.docx", tokens: 3_000, auto: true, why: ["changed yesterday"]),
                        src("file", "Security questionnaire.xlsx", path: r3North + "/docs/Security questionnaire.xlsx", tokens: 7_000, auto: true, why: ["changed 3 days ago"]),
                        src("file", "Case study: Fleetwise.pdf", path: r3North + "/docs/Case study: Fleetwise.pdf", tokens: 5_000, auto: true, why: ["named in the notes"]),
                        src("file", "Old proposal 2025.pptx", path: r3North + "/docs/Old proposal 2025.pptx", tokens: 14_000, auto: true, why: ["11 months old"])]
        for i in d.candidates.indices { d.candidates[i].checked = i < 2 }
        d.candidateNote = ""
        return d
    }

    func r3Job(_ d: SheetDraft, done: Bool, failed: String? = nil, pass: Int = 1) -> SheetJob {
        let j = SheetJob(callID: d.model.id, kind: "build")
        if done {
            j.done = true; j.progress = 1; j.sheetPath = r3Sheet(d.model)
        } else {
            j.progress = pass == 2 ? 0.7 : 0.45
            j.stage = pass == 2 ? "Pass 2 of 2: Qualification, Questions" : "Reading sources: northwindlabs.com"
            j.pass = pass; j.passes = 2
            let ids = d.sources.filter(\.checked).map(\.id)
            for (i, id) in ids.enumerated() { j.sourceState[id] = i < 2 ? "read" : i == 2 ? "reading" : "waiting" }
            if ids.count > 3 { j.sourceState[ids[3]] = "failed"; j.sourceNote[ids[3]] = "The page did not answer in 30 s" }
            if let failed { j.failed = failed }
        }
        keep.append(j)
        return j
    }

    // MARK: scenes

    func r3Scenes(_ style: PNStyle) -> [Scene] {
        let sx = "-" + style.rawValue
        var s: [Scene] = []
        let form = NSSize(width: 640, height: 1700), prep = NSSize(width: 860, height: 1700)
        for (name, mode, project) in [("start", CallSetupMode.start, "orbit"), ("plan", CallSetupMode.plan, "orbit"), ("none", CallSetupMode.start, "")] {
            s.append(Scene(name: "r3-su-\(name)\(sx)", size: form, make: { [unowned self] in
                let m = r3Call(project, project.isEmpty ? "" : name == "plan" ? "Q1 roadmap review with Orbit" : "Weekly sync with Emily Carter", minutes: name == "plan" ? 3 * 24 * 60 : 37)
                if name == "plan" { m.callType = "presentation" }
                if project.isEmpty { UserDefaults.standard.set(true, forKey: "callSetupOptions") } else { UserDefaults.standard.set(false, forKey: "callSetupOptions") }
                m.folders = project.isEmpty ? [] : [r3Orbit + "/docs", r3Orbit + "/docs/Status report Nov 14.docx"] + (name == "plan" ? [] : [r3Orbit + "/docs/Old kickoff notes.md"])
                keep.append(m)
                return AnyView(CallSetupView(model: m, mode: mode, onStart: {}, onCancel: {}))
            }))
        }
        func prepScene(_ name: String, _ d: @escaping () -> SheetDraft, tweak: ((SheetDraft) -> Void)? = nil, switchTo: Bool = false) -> Scene {
            var made: SheetDraft?
            return Scene(name: name + sx, size: prep, make: { [unowned self] in
                let x = d(); made = x; keep.append(x)
                if switchTo {
                    SheetRunner.shared.shotQuestion(from: AIRoute.code, to: AIRoute.codex, reason: "Claude account: the weekly limit is used up until 07:10", call: x.model)
                }
                return AnyView(SheetPrepView(draft: x))
            }, tweak: { if let x = made { x.checking = false; tweak?(x) } })
        }
        for k in ["ok", "attn", "building", "done", "failed", "live"] {
            s.append(prepScene("r3-qp-\(k)", { [unowned self] in r3Quick(k) }, switchTo: k == "failed"))
        }
        for n in 1...3 { s.append(prepScene("r3-ea-s\(n)", { [unowned self] in r3Expert(n) })) }
        s.append(prepScene("r3-eb-s4", { [unowned self] in
            let d = r3Expert(4)
            d.size = size("too_much", 262_000)
            d.plan = "passes"           // 0.25 (R3c): picked on the page, as on the board
            return d
        }))
        s.append(prepScene("r3-eb-run", { [unowned self] in let d = r3Expert(5); d.job = r3Job(d, done: false); return d }))
        s.append(prepScene("r3-eb-err", { [unowned self] in
            let d = r3Expert(5); d.job = r3Job(d, done: false, failed: "Pass 2 stopped: Claude account limit. Pass 1 is saved.", pass: 2); return d
        }, switchTo: true))
        s.append(prepScene("r3-eb-done", { [unowned self] in let d = r3Expert(5); d.job = r3Job(d, done: true); return d }))
        for tab in ["readiness", "sources", "versions", "sheet"] {
            s.append(Scene(name: "r3-rs-\(tab)\(sx)", size: NSSize(width: 1160, height: 2400), make: { [unowned self] in page(r3Pilot, tab) }))
        }
        return s
    }

    /// The r3 queue: every style, dark then light, English.
    func r3Queue() {
        _ = PNFonts.once
        queue.append { [unowned self] in L10n.set("en"); next(0.3) }
        for style in PNStyle.allCases {
            for t in ["dark", "light"] {
                queue.append { [unowned self] in
                    theme = t; PNThemeModel.shared.style = style
                    NSApp.appearance = NSAppearance(named: t == "dark" ? .darkAqua : .aqua); next(0.5)
                }
                for sc in r3Scenes(style) { queue.append { [unowned self] in shoot(sc, suffix: "-" + t) } }
            }
        }
        queue.append { [unowned self] in PNThemeModel.shared.style = PNStyle.buildDefault; next(0.1) }
    }
}
