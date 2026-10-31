// Core checks without a test framework: the Command Line Tools ship neither XCTest nor
// swift-testing, and the app must build without Xcode. Run: swift run -c release CoreChecks
import Foundation
import LiveTipsCore

var failures = 0
var passed = 0
func expect(_ ok: @autoclosure () -> Bool, _ what: String = "", line: Int = #line) {
    if ok() { passed += 1 } else { failures += 1; print("FAIL line \(line) \(what)") }
}

func frameRoundTripAcrossChunks() {
    let frames = [Frame(kind: .heartbeat, payload: Data("{\"t\":1}".utf8)),
                  Frame(kind: .micAudio, payload: Data(repeating: 7, count: 640))]
    var bytes = Data()
    frames.forEach { bytes.append($0.encoded()) }
    var dec = FrameDecoder()
    var got: [Frame] = []
    var i = 0
    while i < bytes.count {
        let end = min(i + 37, bytes.count)
        got += dec.feed(bytes.subdata(in: i..<end))
        i = end
    }
    expect(got == frames)
    expect(dec.malformed == 0)
}

func frameResyncAfterGarbage() {
    var dec = FrameDecoder()
    var bytes = Data([0xFF, 0x00])
    bytes.append(Frame(kind: .log, payload: Data("ok".utf8)).encoded())
    let got = dec.feed(bytes)
    expect(got.last?.payload == Data("ok".utf8))
    expect(dec.malformed > 0)
}

func watchdogStartGraceThenStallTerminateKillRestart() {
    var w = HelperWatchdog()
    expect(w.evaluate(now: 5, startedAt: 0, lastHeartbeat: nil, lastMicAudio: nil, micMuted: false, alive: true) == .none)
    expect(w.evaluate(now: 20, startedAt: 0, lastHeartbeat: 19, lastMicAudio: 5, micMuted: false, alive: true) == .terminate)
    expect(w.evaluate(now: 24, startedAt: 0, lastHeartbeat: 19, lastMicAudio: 5, micMuted: false, alive: true) == .kill)
    expect(w.evaluate(now: 25, startedAt: 0, lastHeartbeat: 19, lastMicAudio: 5, micMuted: false, alive: false) == .restart(afterSeconds: 2))
}

func watchdogMutedMicIsNotAStall() {
    var w = HelperWatchdog()
    expect(w.evaluate(now: 60, startedAt: 0, lastHeartbeat: 59.5, lastMicAudio: 1, micMuted: true, alive: true) == .none)
}

func watchdogTwoFailedRestartsSwitchToBuiltInMic() {
    var w = HelperWatchdog()
    _ = w.evaluate(now: 20, startedAt: 0, lastHeartbeat: nil, lastMicAudio: nil, micMuted: false, alive: true)
    expect(w.evaluate(now: 21, startedAt: 0, lastHeartbeat: nil, lastMicAudio: nil, micMuted: false, alive: false) == .restart(afterSeconds: 2))
    _ = w.evaluate(now: 40, startedAt: 30, lastHeartbeat: nil, lastMicAudio: nil, micMuted: false, alive: true)
    expect(w.evaluate(now: 41, startedAt: 30, lastHeartbeat: nil, lastMicAudio: nil, micMuted: false, alive: false) == .switchToBuiltInMic)
}

func projectConfigParse() {
    let md = """
    # Project: Demo Platform
    ## General
    - **project_name**: Demo Platform
    - **project_slug**: demo   (lowercase)
    - **status**: active
    - **default_language**: Ukrainian
    - **client_language**: English
    ## Local Paths
    - **project_root**: `~~home-folder/work/Demo`
    ## Team - Internal (as of 2026-01-01)
    | Name | Role | Jira Username | Report Title | Availability | Focus Areas |
    |------|------|---------------|--------------|--------------|-------------|
    | Alex Example | PM | alex | Project Manager | full-time | - |
    ### Transcript Alias Map
    | Transcript says | Actually is |
    |----------------|-------------|
    | Олекс | Alex Example |
    ## Team - Client (this is the Stakeholder Register)
    | Name | Role | Email | Influence | Interest | Channel | Cadence | Notes |
    |------|------|-------|-----------|----------|---------|---------|-------|
    | Jordan Client | CTO | j@example.com | H | H | Call | weekly | - |
    """
    let p = ProjectConfigImporter.parse(markdown: md, path: "/x/demo.md", home: "/home/test")
    expect(p?.slug == "demo", "slug")
    expect(p?.root == "/home/test/work/Demo", "root")
    expect(p?.people.count == 2, "people")
    expect(p?.people.last?.side == "client", "client side")
    expect(p?.aliases["Олекс"] == "Alex Example", "alias")
    expect(ProjectConfigImporter.parse(markdown: "- **project_slug**: {slug}") == nil, "template ignored")
}

func registryMergeKeepsUserFields() {
    var r = ProjectRegistry()
    var a = Project(name: "Demo", slug: "demo", root: "/r")
    a.apiAllowed = false
    a.index.extra = ["/w/_notion"]
    r.projects = [a]
    r.merge(imported: [Project(name: "Demo 2", slug: "demo", root: "/r2"), Project(name: "Beta", slug: "beta", root: "/b")])
    expect(r.projects.count == 2, "two projects")
    let d = r.projects.first { $0.slug == "demo" }
    expect(d?.name == "Demo 2" && d?.root == "/r2", "refreshed from config")
    expect(d?.apiAllowed == false && d?.index.extra == ["/w/_notion"], "user fields kept")
}

func secretsAndConfig() {
    expect(maskedSecret("sk-abcdefghijkl1234") == "...1234", "mask")
    expect(maskedSecret(nil) == "not set", "mask nil")
    let tmp = NSTemporaryDirectory() + "livetips-check-secrets.env"
    try? "FOO=1\nexport CLAUDE_API=\"sk-test-9999\"\n".write(toFile: tmp, atomically: true, encoding: .utf8)
    expect(readSecretsFileValue("CLAUDE_API", path: tmp) == "sk-test-9999", "secrets file")
    expect(readSecretsFileValue("MISSING", path: tmp) == nil, "missing var")
    try? FileManager.default.removeItem(atPath: tmp)
    var c = AppConfig()
    c.localAI.enabled = false
    c.budget.monthlyHardUSD = 50
    let url = URL(fileURLWithPath: NSTemporaryDirectory() + "livetips-check-config.json")
    try? c.save(to: url)
    expect(AppConfig.load(from: url) == c, "config round trip")
    try? FileManager.default.removeItem(at: url)
}

func mirrorAndWorkspaces() {
    let st = MirrorStatus.parse("# Notion mirror status\n\n- result: OK\n- last_run_utc: 2026-10-22T05:07:05.000Z\n- pages_in_mirror: 3586\n- mode: incremental\n")
    expect(st.result == "OK" && st.pages == 3586, "mirror parse")
    let iso = ISO8601DateFormatter()
    expect(st.health(now: iso.date(from: "2026-10-22T10:00:00Z")!) == "ok", "fresh mirror")
    expect(st.health(now: iso.date(from: "2026-10-24T10:00:00Z")!) == "stale", "stale mirror")
    expect(MirrorStatus.parse("").health() == "missing", "missing mirror")
    let tmp = NSTemporaryDirectory() + "lt-ws-check-\(getpid())"
    let fm = FileManager.default
    try? fm.createDirectory(atPath: tmp + "/Acme/_notion", withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: tmp + "/Acme/Alpha", withIntermediateDirectories: true)
    fm.createFile(atPath: tmp + "/Acme/_notion/workspace.md", contents: Data("x".utf8))
    try? fm.createDirectory(atPath: tmp + "/Notes", withIntermediateDirectories: true)
    let ws = WorkspaceScanner.scan(workRoot: tmp, projects: [Project(name: "Alpha", slug: "alpha", root: tmp + "/Acme/Alpha"),
                                                             Project(name: "Beta", slug: "beta", root: tmp + "/Other/Beta")])
    expect(ws.count == 1 && ws[0].name == "Acme" && ws[0].projects == ["alpha"], "workspace scan")
    // 0.8.7 (F7): "Found in your work folder" skips git repositories and ignored folders
    try? fm.createDirectory(atPath: tmp + "/Code/app", withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: tmp + "/Code/.git", withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: tmp + "/Clients/Orbit", withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: tmp + "/Old/Orbit", withIntermediateDirectories: true)
    let cands = WorkspaceScanner.candidates(workRoot: tmp, known: [], excluded: [tmp + "/Old"]).map { ($0.dir as NSString).lastPathComponent }
    expect(cands.contains("Clients") && !cands.contains("Code") && !cands.contains("Old"), "found folders skip git and ignored")
    try? fm.removeItem(atPath: tmp)
    var c = AppConfig()
    expect(c.effectiveAppRoot(appSupport: "/AS") == "/AS", "app root default")
    c.workRoot = "/w"
    expect(c.effectiveAppRoot(appSupport: "/AS") == "/w/Tools/LiveTips", "app root in work folder")
    let old = try? JSONDecoder().decode(AppConfig.self, from: Data("{\"uiLanguage\":\"uk\"}".utf8))
    expect(old?.uiLanguage == "uk" && old?.showInDock == true, "config decodes older files")
}

/// Pacenote 0.8: the interface catalog (Resources/i18n) has the same keys in en and uk, no empty values,
/// no long dash and no emoji, and the same {placeholders} in both languages.
func interfaceStrings() {
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/i18n")
    func load(_ l: String) -> [String: String] {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("\(l).json")),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return [:] }
        return o.compactMapValues { $0 as? String }
    }
    let en = load("en"), uk = load("uk")
    expect(!en.isEmpty && !uk.isEmpty, "i18n catalogs load")
    expect(Set(en.keys) == Set(uk.keys), "i18n keys match: \(Set(en.keys).symmetricDifference(Set(uk.keys)).sorted())")
    func holes(_ s: String) -> Set<String> {
        var out = Set<String>(), cur: String?
        for ch in s { if ch == "{" { cur = "" } else if ch == "}" { if let c = cur { out.insert(c) }; cur = nil } else if cur != nil { cur!.append(ch) } }
        return out
    }
    for (k, v) in en {
        let u = uk[k] ?? ""
        expect(!v.isEmpty && !u.isEmpty, "i18n empty: \(k)")
        expect(!v.contains("\u{2014}") && !u.contains("\u{2014}"), "i18n long dash: \(k)")
        expect(!(v + u).unicodeScalars.contains { $0.properties.isEmojiPresentation }, "i18n emoji: \(k)")
        expect(holes(v) == holes(u), "i18n placeholders differ: \(k)")
    }
}

func versions() {
    expect(AppVersion.number(in: "v0.8.1") == "0.8.1", "tag v0.8.1")
    expect(AppVersion.number(in: "pacenote-0.10.0-beta") == "0.10.0", "tag with a name")
    expect(AppVersion.isNewer("0.10.0", than: "0.9.9"), "0.10 > 0.9.9")
    expect(!AppVersion.isNewer("0.8", than: "0.8.0"), "0.8 == 0.8.0")
    expect(!AppVersion.isNewer("v0.8.0", than: "0.8.1"), "older tag")
}

/// Pacenote 0.8: the commitments register folds like livetips_m0/commitments.py (same ids, same duplicates).
func commitmentsRegister() {
    expect(CommitmentRegister.makeID(call: "/x/live/call-1.app.md", owner: "me", text: "Send the test account list") == "c-bb87a2a300", "id parity with Python")
    expect(CommitmentRegister.seriesKey(project: "orbit", title: "Weekly Sync #2") == "orbit|weeklysync2")
    let a = CommitmentRegister.makeID(call: "call-1.app.md", owner: "me", text: "Send the test account list")
    let ev: [[String: Any]] = [
        ["op": "add", "id": a, "text": "Send the test account list", "owner": "me", "call": "call-1.app.md", "created": "2026-10-20T10:00:00+03:00", "due": "Friday"],
        ["op": "add", "id": "c-skill", "text": "send test account list", "owner": "me", "call": "call-1.md"],          // the skill's twin
        ["op": "add", "id": "c-them", "text": "Share the export spec", "owner": "Dana", "call": "call-1.md", "created": "2026-10-20T10:00:00+03:00"],
        ["op": "done", "id": "c-skill", "at": "2026-10-21T09:00:00+03:00", "source": "detected"],
        ["op": "add", "id": "c-old", "text": "Book the room", "owner": "me", "call": "call-0.md", "created": "2026-10-01T10:00:00+03:00", "due": "3.10"],
    ]
    let items = CommitmentRegister.fold(ev)
    expect(items.count == 3, "a duplicate add is folded")
    expect(items.first { $0.id == a }?.status == "done" && items.first { $0.id == a }?.doneSource == "detected", "an event on the twin closes the first")
    expect(items.first { $0.id == "c-them" }?.mine == false)
    let now = ISO8601DateFormatter().date(from: "2026-10-22T12:00:00+03:00")!
    let open = CommitmentRegister.sorted(items.filter { $0.status == "open" }, now: now)
    expect(open.first?.id == "c-old" && CommitmentRegister.isOverdue(open[0], now: now), "overdue first")
    let from = ISO8601DateFormatter().date(from: "2026-10-20T10:00:00+03:00")!       // a Tuesday
    let fri = CommitmentRegister.dueDate("by Friday", from: from)!
    expect(Calendar.current.component(.weekday, from: fri) == 6 && fri > from, "a weekday is the next one")
    expect(CommitmentRegister.dueDate("до п'ятниці", from: from) == fri, "Ukrainian weekday")
    expect(CommitmentRegister.dueDate("2026-11-03", from: from) != nil && CommitmentRegister.dueDate("soon", from: from) == nil)
    let dir = NSTemporaryDirectory() + "pn-reg-\(getpid())"
    CommitmentRegister.append(folder: dir, [["op": "add", "id": "c-1", "text": "One", "owner": "me", "call": "x.md"]])
    CommitmentRegister.mark(folder: dir, id: "c-1", op: "done")
    expect(CommitmentRegister.load(folder: dir).first?.status == "done", "append and mark")
    // 0.8.6 (rules/commitments.yaml > link, unlink, from)
    CommitmentRegister.append(folder: dir, [["op": "add", "id": "c-2", "text": "Two", "owner": "me", "call": "x.md", "from": "c-them"]])
    CommitmentRegister.mark(folder: dir, id: "c-2", op: "link", notionPage: "page-1")
    expect(CommitmentRegister.load(folder: dir).first { $0.id == "c-2" }?.notionPage == "page-1", "link")
    expect(CommitmentRegister.load(folder: dir).first { $0.id == "c-2" }?.from == "c-them", "from")
    CommitmentRegister.mark(folder: dir, id: "c-2", op: "unlink", source: "removed")
    let c2 = CommitmentRegister.load(folder: dir).first { $0.id == "c-2" }
    expect(c2?.notionPage == "" && c2?.notionNote == "removed" && c2?.status == "open", "unlink keeps it open")
    CommitmentRegister.append(folder: dir, [["op": "edit", "id": "c-2", "text": "Two, edited", "owner": "Ann Lee", "due": "2026-11-03"]])
    let c2e = CommitmentRegister.load(folder: dir).first { $0.id == "c-2" }
    expect(c2e?.text == "Two, edited" && c2e?.owner == "Ann Lee" && c2e?.due == "2026-11-03", "op edit (0.8.7)")
    CommitmentRegister.mark(folder: dir, id: "c-2", op: "done", source: "notion")
    expect(CommitmentRegister.load(folder: dir).first { $0.id == "c-2" }?.doneSource == "notion", "done from Notion")
    // 0.8.7 (E2): "+ Add" on the call page, then a move to On you
    let nid = CommitmentRegister.add(folder: dir, text: "  Send the access list ", owner: "Ann Lee", project: "orbit", title: "Orbit sync", call: "/x/y.md")
    let na = CommitmentRegister.load(folder: dir).first { $0.id == nid }
    expect(na?.text == "Send the access list" && na?.owner == "Ann Lee" && na?.call == "y.md" && na?.series == "orbit|orbitsync", "op add from the call page")
    expect(CommitmentRegister.add(folder: dir, text: "  ", project: "orbit", title: "t", call: "y.md") == nil, "empty add is ignored")
    CommitmentRegister.edit(folder: dir, id: nid ?? "", owner: "me")
    expect(CommitmentRegister.load(folder: dir).first { $0.id == nid }?.mine == true, "move to On you")
    try? FileManager.default.removeItem(atPath: dir)
}

func enginePathsFollowTheApp() {
    // 0.8.3: after the rename the config still pointed at the removed "Live Tips.app"; the engine must follow the app.
    var e = AppConfig.Engine()
    e.python = "/v/bin/python"; e.sidecarPython = "/v/bin/python"; e.sidecarDir = "/Old.app/Contents/Resources/engine/spikes/m0"
    let fixed = e.resolved(defaultPython: "/v/bin/python", bundleEngine: "/New.app/Contents/Resources/engine/spikes/m0",
                           exists: { $0 == "/v/bin/python" || $0.hasPrefix("/New.app") })
    expect(fixed?.sidecarDir == "/New.app/Contents/Resources/engine/spikes/m0", "a missing engine folder moves to the app's own")
    expect(fixed?.python == "/v/bin/python", "a working python stays")
    expect(e.resolved(defaultPython: "/v/bin/python", bundleEngine: "/Old.app/Contents/Resources/engine/spikes/m0",
                      exists: { _ in true }) == nil, "nothing to change: nil")
    var custom = AppConfig.Engine(); custom.python = "/mine/python"; custom.sidecarPython = "/mine/python"; custom.sidecarDir = "/mine/engine"
    expect(custom.resolved(defaultPython: "/v/bin/python", bundleEngine: "/New.app/e", exists: { _ in true }) == nil, "the PM's own engine is kept")
}

/// Pacenote 0.8.5: slide owners, talk time and Prepare again (rules/presentation.yaml).
func presentationCore() {
    let sp = ["Ann Lee", "Bob"]
    let a = DeckOwners.parse("slides 5-9 Ann", speakers: sp, count: 14)
    expect(a?.slides == [5, 6, 7, 8, 9] && a?.owner == "Ann Lee", "bulk assign by first name")
    expect(DeckOwners.parse("1, 14 all", speakers: sp, count: 14)?.owner == "all", "all")
    expect(DeckOwners.parse("10-13 me", speakers: sp, count: 14)?.slides == [10, 11, 12, 13], "range to me")
    expect(DeckOwners.parse("1, 14 усі", speakers: sp, count: 14)?.owner == "all", "uk all")
    expect(DeckOwners.parse("слайди 10-13 я", speakers: sp, count: 14)?.owner == "me", "uk me")
    expect(DeckOwners.parse("12-20 Bob", speakers: sp, count: 14)?.slides == [12, 13, 14], "clipped to the deck")
    expect(DeckOwners.parse("Ann", speakers: sp, count: 14) == nil && DeckOwners.parse("5-9", speakers: sp, count: 14) == nil, "not understood")
    expect(DeckOwners.who("Ann Lee") == ("other", "Ann Lee") && DeckOwners.who("all") == ("shared", ""), "who")
    let runs = DeckOwners.runs([5: "Ann", 6: "Ann", 1: "all"], count: 7)
    expect(runs.count == 4 && runs[2].from == 5 && runs[2].to == 6, "runs")
    expect(TalkTime.talkMinutes(duration: 30, qa: 5, qaOn: true) == 25 && TalkTime.talkMinutes(duration: 30, qa: 5, qaOn: false) == 30)
    expect(TalkTime.clock(1590) == "26:30" && TalkTime.clock(3900) == "1:05:00", "clock")
    let old: [[String: Any]] = [["n": 1, "title": "Old", "edited": true, "sec": 90], ["n": 2, "title": "Two"], ["n": 3, "title": "Mine", "edited": true]]
    let new: [[String: Any]] = [["n": 1, "title": "New", "sec": 60], ["n": 2, "title": "Two new"], ["n": 3, "title": "Deck changed"]]
    let m = TalkMerge.merge(old: old, new: new, keepEdits: true, deckChanged: [3])
    expect(m.kept == [1] && m.slides[0]["title"] as? String == "Old" && m.slides[0]["sec"] as? Int == 90, "keep my edits")
    expect(m.slides[2]["title"] as? String == "Deck changed", "a changed deck slide is rewritten")
    expect(TalkMerge.merge(old: old, new: new, keepEdits: false).kept.isEmpty, "rewrite everything")
    expect(TalkMerge.list([3, 6, 7, 8, 10]) == "3, 6-8, 10" && TalkMerge.list([4, 5]) == "4, 5", "list")
    expect(TalkMerge.deckChanges(old: [1: "A  b", 2: "c"], new: [1: "a b", 2: "d"]) == [2], "deck changes")
}

/// rules/learning.yaml: the shared fixture gives the same standing patterns as livetips_m0/learning.py.
func learningPatterns() {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("rules/fixtures/learning-patterns.json")
    guard let d = try? Data(contentsOf: url), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
          let rec = o["records"] as? [[String: Any]], let exp = o["expect"] as? [[String: Any]] else { expect(false, "learning fixture"); return }
    let got = Learning.standing(rec)
    expect(got.count == exp.count, "learning: \(got.count) patterns")
    for (g, e) in zip(got, exp) {
        expect(g.kind == e["kind"] as? String && g.text == e["text"] as? String && g.calls == e["calls"] as? Int, "learning: \(g.text)")
    }
    expect(Learning.standing([["kind": "followup_instruction", "file": "a", "text": "Drop pricing"], ["kind": "followup_instruction", "file": "a", "text": "drop the pricing"]]).isEmpty, "one call is not a pattern")
}

/// 2026-10-29 (owner): a preparation finished during a held call is that call's, not the next one's.
func prepOwnership() {
    let d = { (s: String) in ISO8601DateFormatter().date(from: s)! }
    let held = [(start: d("2026-10-29T08:58:00Z"), end: d("2026-10-29T09:50:00Z"))]
    let friday = d("2026-10-30T09:00:00Z")
    expect(PrepOwnership.belongsToHeld(prepDate: d("2026-10-29T09:00:00Z"), made: d("2026-10-29T09:25:00Z"), held: held, before: friday), "made during the held call")
    expect(PrepOwnership.belongsToHeld(prepDate: d("2026-10-29T15:00:00Z"), made: d("2026-10-29T09:40:00Z"), held: held, before: friday), "finished before the held call ended")
    expect(!PrepOwnership.belongsToHeld(prepDate: d("2026-10-30T09:00:00Z"), made: d("2026-10-29T16:00:00Z"), held: held, before: friday), "made after the call, for Friday")
    expect(!PrepOwnership.belongsToHeld(prepDate: d("2026-10-29T09:00:00Z"), made: nil, held: held, before: d("2026-10-29T09:30:00Z")), "the held call itself is not 'before'")
}

/// 0.8.6 (D, rules/notion-tasks.yaml): the filter, a task read from a page, project mapping, closing from Notion.
func notionTasksCore() {
    var st = NotionTasksSettings()
    st.enabled = true; st.database = "ds-1"; st.personProperty = "Assignee"; st.personId = "u-1"
    var c = NotionTasksSettings.Condition(); c.property = "Status"; c.type = "status"; c.values = ["To Do", "In progress"]
    st.conditions = [c]
    st.tickProperty = "Status"; st.tickType = "status"; st.tickValue = "Done"
    st.dueProperty = "Due"; st.projectProperty = "Project"; st.projectType = "relation"
    st.projectMap = ["orbit": ["p-orbit"], "playbook": ["p-play"]]
    st.workspaceProperty = "Workspace"; st.workspaceMap = ["Northwind": "w-nw"]
    expect(st.ready, "settings ready")
    let f = NotionTasksCore.filter(st)
    let and = f["and"] as? [[String: Any]] ?? []
    expect(and.count == 2 && ((and[1]["or"] as? [[String: Any]])?.count == 2), "person and the status values")
    let f2 = NotionTasksCore.filter(st, scope: ["p-orbit"], workspace: "Northwind")
    expect(((f2["and"] as? [[String: Any]])?.last?["or"] as? [[String: Any]])?.count == 2, "project or its workspace")
    func page(_ id: String, _ status: String, _ proj: String) -> [String: Any] {
        ["id": id, "url": "https://notion.so/" + id, "created_time": "2026-10-30T10:00:00.000Z", "properties": [
            "Name": ["type": "title", "title": [["plain_text": "Send the Orbit plan"]]],
            "Status": ["type": "status", "status": ["name": status]],
            "Due": ["type": "date", "date": ["start": "2026-11-03"]],
            "Project": ["type": "relation", "relation": [["id": proj]]],
            "Workspace": ["type": "relation", "relation": [[String: Any]]()]]]
    }
    let t = NotionTasksCore.task(page("t1", "To Do", "p-orbit"), st)!
    expect(t.title == "Send the Orbit plan" && t.due == "2026-11-03" && t.open && t.status == "To Do", "a task from a page")
    expect(!NotionTasksCore.task(page("t2", "Done", "p-orbit"), st)!.open, "closed in Notion: the tick value")
    expect(!NotionTasksCore.task(page("t3", "Archived", "p-orbit"), st)!.open, "closed in Notion: out of Show only when")
    expect(NotionTasksCore.targets(t, st) == ["orbit"], "mapped back to the project")
    let t4 = NotionTasksCore.task(page("t4", "To Do", "p-play"), st)!
    expect(NotionTasksCore.forCall([t, t4], st, project: "orbit").map { $0.id } == ["t1"], "a project's call shows its tasks")
    expect(NotionTasksCore.forCall([t, t4], st, project: nil, workspaceProjects: ["orbit", "playbook"], workspace: "Northwind").count == 2, "a workspace call: all its projects")
    expect(NotionTasksCore.forCall([t, t4], st, project: nil).isEmpty, "no project: none")
    expect(((NotionTasksCore.tickPatch(st, value: "Done")["Status"] as? [String: Any])?["status"] as? [String: Any])?["name"] as? String == "Done", "tick patch")
    let g = NotionTasksCore.statusGroups(["status": ["options": [["id": "a", "name": "To Do"], ["id": "b", "name": "Done"]],
                                                     "groups": [["name": "Complete", "option_ids": ["b"]]]]])
    expect(g.open == ["To Do"] && g.complete == ["Done"], "status groups")
    let np = NotionTasksCore.newPage(st, title: "Send the Orbit plan", projectValues: ["p-orbit"], due: "2026-11-03",
                                     source: "From the call Orbit sync, 2026-10-30", quote: "I will send it", titleProperty: "Name")
    let props = np["properties"] as? [String: Any] ?? [:]
    expect(props["Assignee"] != nil && props["Project"] != nil && props["Due"] != nil && props["Status"] != nil, "a new task page")
    expect(NotionTasksCore.autoMatch(projects: [("orbit", "Orbit SaaS Launch")], options: [("p-orbit", "Orbit SaaS Launch")]) == ["orbit": ["p-orbit"]], "match by name")
    var sp = st; sp.periodDays = "7"
    expect(((NotionTasksCore.filter(sp)["and"] as? [[String: Any]])?.last?["timestamp"] as? String) == "last_edited_time", "period filter")
    var miss = NotionTasksSettings(); miss.enabled = true
    expect(miss.missing == ["database"], "what is missing")
    var nobody = st; nobody.personId = ""
    expect(nobody.ready && !nobody.byPerson, "the person is optional")
    let fn = NotionTasksCore.filter(nobody)
    expect(fn["and"] == nil && fn["or"] != nil, "no person: only the conditions")
    var bare = nobody; bare.conditions = []
    expect(NotionTasksCore.filter(bare).isEmpty, "nothing set: every task")
    expect(((NotionTasksCore.newPage(nobody, title: "x", projectValues: [], due: "", source: "s", quote: "", titleProperty: "Name")["properties"] as? [String: Any])?["Assignee"]) == nil, "no person on a new page")
    let d = try? JSONEncoder().encode(st)
    let back = d.flatMap { try? JSONDecoder().decode(NotionTasksSettings.self, from: $0) }
    expect(back == st, "settings round trip")
}

/// 0.8.7 (B2): one key per project for the counts (Bink/bink, Volya/volya, Orbit-2/orbit 2).
func projectKeys() {
    let ps: [(slug: String, name: String)] = [("orbit", "Orbit SaaS Launch"), ("orbit-2", "Orbit-2"), ("playbook", "Internal Delivery Playbook")]
    let ws = ["Northwind Studio"]
    expect(ProjectKey.key("orbit", projects: ps, workspaces: ws) == "orbit", "exact slug")
    expect(ProjectKey.key("Orbit SaaS Launch", projects: ps, workspaces: ws) == "orbit", "name")
    expect(ProjectKey.key("ORBIT-2", projects: ps, workspaces: ws) == "orbit-2" && ProjectKey.key("orbit 2", projects: ps, workspaces: ws) == "orbit-2", "case and dashes")
    expect(ProjectKey.key("northwind-studio", projects: ps, workspaces: ws) == "workspace:Northwind Studio", "workspace")
    expect(ProjectKey.key("Gone Project", projects: ps, workspaces: ws) == ProjectKey.key("gone-project", projects: ps, workspaces: ws), "unknown names fold too")
    expect(ProjectKey.name("orbit", projects: ps, fallback: "x") == "Orbit SaaS Launch", "the registry name is shown")
}

projectKeys()
notionTasksCore()
interfaceStrings()
presentationCore()
prepOwnership()

// 0.8.7: migration, project decode, usage log, work tree, CRM on fixtures (no network, demo data only)
func settings087() {
    var c = AppConfig()
    c.notionMeetingsDB = "db-default"
    c.notionMeetingsDBByProject = ["orbit": "db-b", "northwind": "db-b", "beta": "db-b", "pilot": "db-default", "x": ""]
    let note = c.migrateMeetingsDBs()
    expect(c.notionMeetingsDB == "db-b", "the most used meetings database wins")
    expect(c.notionMeetingsDBByProject.isEmpty, "per-project overrides are gone")
    expect(note == "pilot", "the note names the project that wrote elsewhere: \(note)")
    var d = AppConfig(); d.notionMeetingsDB = "a"; d.notionMeetingsDBByProject = ["p": "b"]
    d.migrateMeetingsDBs()
    expect(d.notionMeetingsDB == "a", "a tie keeps the default")
    let old = #"{"notionMeetingsDB":"z","notionMeetingsDBByProject":{"orbit":"z"}}"#
    let e = try? JSONDecoder().decode(AppConfig.self, from: Data(old.utf8))
    expect(e?.notionMeetingsDB == "z" && e?.notionMigrationNote == "all", "an old config migrates silently on load")
    expect(AppConfig().models.tip.contains("haiku"), "Haiku is the default tip model")
    expect(AppConfig().salesWebSearch && AppConfig().usageLog && !AppConfig().crm.transcriptInNote, "0.8.7 defaults")
    // a project saved before 0.8.7 (no new keys) still decodes
    let pj = #"{"name":"Orbit","slug":"orbit","root":"/tmp/orbit"}"#
    let p = try? JSONDecoder().decode(Project.self, from: Data(pj.utf8))
    expect(p?.name == "Orbit" && p?.salesEnabled == false && p?.apiAllowed == true, "an old project decodes with defaults")
}

func usage087() {
    expect(UsageLog.line("tip_shown", ["kind": "risk"]) != nil, "a known event")
    expect(UsageLog.line("tip_shown", ["kind": String(repeating: "x", count: 81)]) == nil, "no text over 80 characters")
    expect(UsageLog.line("tip_shown", ["text": "Emily said"]) == nil, "no parameter outside the list")
    expect(UsageLog.line("nope") == nil, "no unknown event")
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pn-usage-\(UUID().uuidString)")
    let sink = LocalFileSink(dir: dir)
    sink.write(UsageLog.line("help_now")!)
    expect(UsageLog.counts(dir: dir)["help_now"] == 1, "counted")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: dir.appendingPathComponent("2020-01.jsonl").path, contents: Data())
    sink.prune(now: Date())
    expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("2020-01.jsonl").path), "older than 12 months is deleted")
    let rootT = NSTemporaryDirectory() + "pn-tree-\(UUID().uuidString)"
    let t = try? WorkTree.create(root: rootT)
    var isDir: ObjCBool = false
    expect(t?.count == 3 && FileManager.default.fileExists(atPath: rootT + "/My workspace/First project", isDirectory: &isDir) && isDir.boolValue, "the tree is made")
}

final class FakeHubSpot: CRMTransport {
    var calls: [String] = []
    var replies: [(Int, [String: Any], [String: String])]
    init(_ r: [(Int, [String: Any], [String: String])]) { replies = r }
    func send(_ method: String, _ path: String, _ body: [String: Any]?) async throws -> (Int, [String: Any], [String: String]) {
        calls.append(method + " " + path)
        return replies.isEmpty ? (200, [:], [:]) : replies.removeFirst()
    }
}

func crm087() async {
    // 429 then success: retried after the Retry-After wait
    var waited: [Double] = []
    let t1 = FakeHubSpot([(429, [:], ["retry-after": "2"]), (200, ["results": [["id": "11", "properties": ["name": "Northwind", "domain": "northwind.example"]]]], [:])])
    let c1 = HubSpotConnector(transport: t1, sleep: { waited.append($0) })
    let co = try? await c1.findCompany(domain: "northwind.example", name: "")
    expect(co?.name == "Northwind" && waited == [2] && t1.calls.count == 2, "429 is retried after Retry-After")
    // 401: one plain line, no retry
    let t2 = FakeHubSpot([(401, ["message": "bad"], [:])])
    do { _ = try await HubSpotConnector(transport: t2, sleep: { _ in }).testConnection(); expect(false, "401 throws") }
    catch { expect((error as? CRMError)?.code == 401 && t2.calls.count == 1, "401 is one error, no retry") }
    // 403 names the missing scope
    let t3 = FakeHubSpot([(403, ["message": "This app hasn't been granted all required scopes: crm.objects.deals.read"], [:])])
    do { _ = try await HubSpotConnector(transport: t3, sleep: { _ in }).deal(id: "1"); expect(false, "403 throws") }
    catch { expect((error as? CRMError)?.scope == "crm.objects.deals.read", "403 names the scope") }
    // snapshot and the update plan
    let md = CRMSnapshot.render(provider: "HubSpot", company: CRMCompany(id: "1", name: "Northwind", domain: "northwind.example"),
                                deal: nil, contacts: [CRMContact(id: "2", name: "Emily Clark", email: "emily@northwind.example", role: "CTO")],
                                activity: [CRMActivity(kind: "note", when: "2026-10-01", text: "Intro call")], taken: Date())
    expect(md.contains("Company: Northwind") && md.contains("Emily Clark, CTO") && md.contains("Deal: none linked") && CRMSnapshot.taken(md) != nil, "snapshot")
    expect(!md.contains("\u{2014}"), "no long dash in the snapshot")
    expect(CRMSnapshot.clientDomains(emails: ["ann@orbit.example", "me@volya.example", "x@gmail.com"], ownDomains: ["volya.example"]) == ["orbit.example"], "client domains")
    let plan = CRMUpdatePlan.build(title: "Orbit renewal", date: "31 Oct", summary: ["a"], decisions: ["b"], nextSteps: ["c"], notionURL: "",
                                   transcript: nil, nextStep: "Demo on Friday", closeDate: "", stage: nil,
                                   qualification: ["budget": "Set aside"], mapping: ["budget": "budget_note", "authority": ""], followUp: ("Send the demo link", nil))
    expect(plan.dealFields["hs_next_step"] == "Demo on Friday" && plan.dealFields["budget_note"] == "Set aside" && plan.dealFields["dealstage"] == nil, "deal fields; the stage only when chosen")
    expect(plan.rows.first { $0.id == "transcript" }?.on == false, "the transcript is off by default")
}

func part2_087() async {
    // H5: the answer cards file as a list; the text above the first card and hand edits stay
    let txt = "# Answer cards\nOne card per question.\n\n## Price is too high\nOrbit pays back in 4 months.\nTags: price, objection\nUse when: budget comes up\n\n## Security\nSOC 2 on request.\n"
    let doc = AnswerCardsDoc.parse(txt)
    expect(doc.preamble == "# Answer cards\nOne card per question." && doc.cards.count == 2, "cards parse")
    expect(doc.cards[0].tags == "price, objection" && doc.cards[0].useWhen == "budget comes up" && doc.cards[1].answer == "SOC 2 on request.", "card fields")
    expect(AnswerCardsDoc.parse(AnswerCardsDoc.render(preamble: doc.preamble, cards: doc.cards)).cards == doc.cards, "render round trip")
    let added = AnswerCardsDoc.append(AnswerCard(title: "Timeline", answer: "Two weeks \u{2014} to start"), to: txt)
    expect(added.hasPrefix(txt.trimmingCharacters(in: .whitespacesAndNewlines)) && AnswerCardsDoc.parse(added).cards.count == 3, "append keeps the file")
    expect(!added.contains("\u{2014}"), "no long dash in a saved card")
    expect(AnswerCardsDoc.append(AnswerCard(title: "A", answer: "B"), to: "").hasPrefix("# Answer cards"), "a new file gets a title")
    // I6.2: owners with paging, the owner by the user's email, notes and tasks carry the owner
    let t = FakeHubSpot([(200, ["results": [["id": "7", "firstName": "Ann", "lastName": "Lee", "email": "ann@orbit.example"]],
                                "paging": ["next": ["after": "7"]]], [:]),
                         (200, ["results": [["id": 9, "firstName": "Emily", "lastName": "Clark", "email": "Emily@Northwind.example"]]], [:])])
    let hs = HubSpotConnector(transport: t, sleep: { _ in })
    let owners = (try? await hs.owners()) ?? []
    expect(owners.map(\.name) == ["Ann Lee", "Emily Clark"] && owners[1].id == "9" && t.calls.count == 2 && t.calls[1].contains("after=7"), "owners with paging")
    expect(CRMOwner.pick(owners, emails: ["emily@northwind.example"])?.id == "9" && CRMOwner.pick(owners, emails: ["x@y.example"]) == nil, "owner by email")
    let tb = BodyFake()
    let hs2 = HubSpotConnector(transport: tb, ownerId: "9", sleep: { _ in })
    _ = try? await hs2.createTask(subject: "Send the demo link", due: nil, associations: [])
    expect(((tb.bodies.last?["properties"] as? [String: Any])?["hubspot_owner_id"] as? String) == "9", "the task has the owner")
    // I6.4, I6.5: the write defaults set the ticks; qualification goes through the mapping
    let plan = CRMUpdatePlan.build(title: "Orbit renewal", date: "31 Oct", summary: [], decisions: [], nextSteps: [], notionURL: "",
                                   transcript: nil, nextStep: "Demo", closeDate: "", stage: nil,
                                   qualification: ["budget": "40k approved", "need": "Manual reports"], mapping: ["budget": "budget_note", "need": ""],
                                   followUp: ("Demo", nil), writeNote: false, writeDeal: true, writeTask: false)
    expect(plan.rows.first { $0.id == "note" }?.on == false && plan.rows.first { $0.id == "task" }?.on == false && plan.rows.first { $0.id == "deal" }?.on == true, "write defaults")
    expect(plan.dealFields["budget_note"] == "40k approved" && plan.dealFields.count == 2, "Don't write skips the criterion")
    // CRMSettings: old files get the new keys with defaults
    let old = try? JSONDecoder().decode(CRMSettings.self, from: Data("{\"provider\":\"hubspot\",\"account\":\"Northwind\"}".utf8))
    expect(old?.matchByDomain == true && old?.ownerAuto == true && old?.writeNote == true && old?.qualification.isEmpty == true, "CRM settings defaults")
}

final class BodyFake: CRMTransport {
    var bodies: [[String: Any]] = []
    func send(_ method: String, _ path: String, _ body: [String: Any]?) async throws -> (Int, [String: Any], [String: String]) {
        bodies.append(body ?? [:]); return (200, ["id": "1"], [:])
    }
}

settings087()
await part2_087()
usage087()
await crm087()
learningPatterns()
enginePathsFollowTheApp()
versions()
commitmentsRegister()
frameRoundTripAcrossChunks()
frameResyncAfterGarbage()
watchdogStartGraceThenStallTerminateKillRestart()
watchdogMutedMicIsNotAStall()
watchdogTwoFailedRestartsSwitchToBuiltInMic()
projectConfigParse()
registryMergeKeepsUserFields()
secretsAndConfig()
mirrorAndWorkspaces()
print("core checks: \(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
