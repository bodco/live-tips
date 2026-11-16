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
    c.floatingCallControls = false
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
    expect(old?.floatingCallControls == true, "older config enables floating controls")
    let statusPath = NSTemporaryDirectory() + "pacenote-floating-status.json"
    for value in ["on", "off"] {
        try? ("{\"state\":\"recording\",\"tips_paused\":\"" + value + "\"}").write(toFile: statusPath, atomically: true, encoding: .utf8)
        expect(EngineStatus.load(path: statusPath).transcriptPaused == (value == "on"), "transcript pause follows recorder acknowledgement")
    }
    try? "{\"state\":\"recording\"}".write(toFile: statusPath, atomically: true, encoding: .utf8)
    expect(!EngineStatus.load(path: statusPath).transcriptPaused, "older recorder status defaults to listening")
    try? FileManager.default.removeItem(atPath: statusPath)
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
    legacyTasksOnTheCallPage()
}

/// 0.13.3 (L5): an old call's picture tasks get Delete, Done, owner and due; a deleted one never comes back.
func legacyTasksOnTheCallPage() {
    let dir = NSTemporaryDirectory() + "pn-legacy-\(getpid())"
    let call = dir + "/2026-10-01-sync.app.md"
    let tasks = [CallLists.Task(text: "Send the deck", mine: true),
                 CallLists.Task(owner: "Mike", text: "Share the export spec", due: "Friday", mine: false),
                 CallLists.Task(text: "Book the room")]
    func shown() -> [CallLists.Task] { CommitmentRegister.legacy(tasks, items: CommitmentRegister.load(folder: dir), call: call, them: "Them") }
    expect(shown().count == 3, "legacy: all picture tasks show while the register has none")
    expect(CommitmentRegister.legacyOwner(tasks[1], them: "Them") == "Mike" && CommitmentRegister.legacyOwner(tasks[2], them: "Them") == "me", "legacy owner")
    // Delete: the row is adopted and dropped; it does not come back, the others stay
    let d = CommitmentRegister.adopt(tasks[0], folder: dir, project: "orbit", title: "Sync", call: call, them: "Them")
    expect(d == CommitmentRegister.legacyID(tasks[0], call: call, them: "Them"), "legacy: adopt writes the expected id")
    CommitmentRegister.mark(folder: dir, id: d ?? "", op: "drop")
    let after = shown()
    expect(after.count == 2 && !after.contains(tasks[0]), "legacy: a deleted task does not come back from the notes")
    expect(CommitmentRegister.load(folder: dir).first { $0.id == d }?.status == "dropped", "legacy: the delete is a drop")
    // Done and a due date on theirs: adopted with its owner and due, shown from the register
    let m = CommitmentRegister.adopt(tasks[1], folder: dir, project: "orbit", title: "Sync", call: call, them: "Them")
    CommitmentRegister.mark(folder: dir, id: m ?? "", op: "done")
    let mc = CommitmentRegister.load(folder: dir).first { $0.id == m }
    expect(mc?.owner == "Mike" && mc?.due == "Friday" && mc?.status == "done" && mc?.by == CommitmentRegister.pageBy, "legacy: done keeps owner and due")
    expect(shown() == [tasks[2]], "legacy: only the untouched task stays a picture row")
    // An edited text still counts as the adopted task (same id)
    CommitmentRegister.edit(folder: dir, id: m ?? "", text: "Share the new export spec")
    expect(shown() == [tasks[2]], "legacy: an edited task does not come back")
    // Every task deleted: the call shows no task at all (the register has only dropped ones)
    let r = CommitmentRegister.adopt(tasks[2], folder: dir, project: "orbit", title: "Sync", call: call, them: "Them")
    CommitmentRegister.mark(folder: dir, id: r ?? "", op: "drop")
    CommitmentRegister.mark(folder: dir, id: m ?? "", op: "drop")
    expect(shown().isEmpty && CommitmentRegister.load(folder: dir).allSatisfy { $0.status == "dropped" }, "legacy: all deleted, none come back")
    // A call with its own register items (the engine's) shows no picture rows
    let dir2 = dir + "-2"
    CommitmentRegister.append(folder: dir2, [["op": "add", "id": "c-e", "text": "Send the deck", "owner": "me", "call": "2026-10-01-sync.md", "by": "app"]])
    expect(CommitmentRegister.legacy(tasks, items: CommitmentRegister.load(folder: dir2), call: call, them: "Them").isEmpty, "legacy: none when the register covers the call")
    // "+ Add" on the page (by page) does not hide the other picture rows
    let dir3 = dir + "-3"
    CommitmentRegister.add(folder: dir3, text: "Write the recap", project: "orbit", title: "Sync", call: call, by: CommitmentRegister.pageBy)
    expect(CommitmentRegister.legacy(tasks, items: CommitmentRegister.load(folder: dir3), call: call, them: "Them").count == 3, "legacy: a page add keeps the picture rows")
    for x in [dir, dir2, dir3] { try? FileManager.default.removeItem(atPath: x) }
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

/// 0.8.8: all secrets in one Keychain item (one prompt after an update at most): pack, unpack, names, migration plan.
func keychain088() {
    let v = ["notion_token": "secret-n", "claude_api_key": "secret-c", "hubspot_service_key": ""]
    let d = SecretStore.pack(v)
    expect(SecretStore.unpack(d) == ["notion_token": "secret-n", "claude_api_key": "secret-c"], "round trip, empty left out")
    expect(String(data: d, encoding: .utf8) == #"{"claude_api_key":"secret-c","notion_token":"secret-n"}"#, "sorted JSON object")
    expect(SecretStore.unpack(Data("not json".utf8)) == nil && SecretStore.unpack(Data("[1]".utf8)) == nil, "garbage is nil")
    expect(SecretStore.unpack(Data(#"{"a": 1, "b": "x"}"#.utf8)) == ["b": "x"], "only string values")
    let names = SecretStore.namesAttribute(v)
    expect(String(data: names, encoding: .utf8) == "claude_api_key,hubspot_service_key,notion_token", "names only")
    expect(!(String(data: names, encoding: .utf8) ?? "").contains("secret"), "no value in the attribute")
    expect(SecretStore.names(from: names).contains("notion_token") && SecretStore.names(from: nil).isEmpty, "names back")
    expect(SecretStore.plan(combinedExists: true, oldPresent: ["notion_token"]) == .useCombined, "combined wins")
    expect(SecretStore.plan(combinedExists: false, oldPresent: ["notion_token", "claude_api_key"]) == .migrate(["claude_api_key", "notion_token"]), "migrate the old items")
    expect(SecretStore.plan(combinedExists: false, oldPresent: []) == .nothing, "nothing saved")
    expect(SecretStore.combinedAccount == "pacenote_secrets", "account name")
}

/// 0.8.8 (rules/decisions.yaml): the 0.8.6 tasks switch keeps its value, new switches are off, the workspace value.
func decisions088() {
    func cfg(_ json: String) -> AppConfig? { try? JSONDecoder().decode(AppConfig.self, from: Data(json.utf8)) }
    let fresh = AppConfig()
    expect(!fresh.notionTasks.autoAdd && !fresh.notionRisksAutoAdd && !fresh.notionDecisionsAutoAdd, "all three off on a new install")
    let on = cfg(#"{"notionTasks": {"enabled": true, "database": "ds-1", "autoAdd": true}}"#)
    expect(on?.notionTasks.autoAdd == true && on?.notionTasks.database == "ds-1", "0.8.6 switch on stays on")
    expect(on?.notionRisksAutoAdd == false && on?.notionDecisionsAutoAdd == false && on?.notionDecisionsDB == "", "new fields default")
    let off = cfg(#"{"notionTasks": {"enabled": true, "autoAdd": false}}"#)
    expect(off?.notionTasks.autoAdd == false, "0.8.6 switch off stays off")
    let back = on.flatMap { try? JSONEncoder().encode($0) }.flatMap { try? JSONDecoder().decode(AppConfig.self, from: $0) }
    expect(back?.notionTasks.autoAdd == true, "survives a save")
    // the registry: workspaces saved by 0.8.7 load; a project's workspace value is its workspace's, else the name
    let reg = try? JSONDecoder().decode(ProjectRegistry.self, from: Data(#"""
    {"projects": [{"name": "Orbit", "slug": "orbit", "workspace": "Northwind Studio"}, {"name": "Solo", "slug": "solo"}],
     "workspaces": [{"name": "Northwind Studio", "root": "/w/nw", "projects": ["orbit"]}]}
    """#.utf8))
    expect(reg?.workspaces.first?.notionValue == "", "0.8.7 workspace loads without a value")
    if var r = reg {
        expect(r.notionWorkspaceValue(for: r.projects[0]) == "Northwind Studio", "default: the workspace's name")
        expect(r.notionWorkspaceValue(for: r.projects[1]) == "", "no workspace, no value")
        r.workspaces[0].notionValue = "0123456789abcdef0123456789abcdef"
        expect(r.notionWorkspaceValue(for: r.projects[0]) == "0123456789abcdef0123456789abcdef", "the card's value")
        r.setWorkspaces([Workspace(name: "Northwind Studio", root: "/w/nw", projects: ["orbit"]), Workspace(name: "Acme", root: "/w/a", projects: [])])
        expect(r.workspaces[0].notionValue == "0123456789abcdef0123456789abcdef" && r.workspaces[1].notionValue == "", "a rescan keeps it")
    } else { expect(false, "registry decodes") }
    // a new task gets the Workspace value its property can take
    var st = NotionTasksSettings(); st.workspaceProperty = "Workspace"
    expect((NotionTasksCore.workspaceProp(st, ["0123456789abcdef0123456789abcdef"])?["relation"] as? [[String: String]])?.first?["id"] == "0123456789abcdef0123456789abcdef", "relation by page id")
    expect(NotionTasksCore.workspaceProp(st, ["Northwind Studio"]) == nil, "a name never goes into a relation")
    st.workspaceType = "select"
    expect((NotionTasksCore.workspaceProp(st, ["Northwind Studio"])?["select"] as? [String: String])?["name"] == "Northwind Studio", "select by name")
    expect(UsageLog.events["auto_added"] == ["kind", "n"] && UsageLog.events["decision_added"] == [], "usage events")
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

decisions088()

/// 0.9.1 (rules/google.yaml): accounts, OAuth, links, Docs/Slides/Sheets text, calendar events, the merge, Meet.
func google091() {
    // client file: ours and Google's own download
    expect(GoogleClient.parse(Data(#"{"client_id":"a","client_secret":"b"}"#.utf8)) == GoogleClient(clientID: "a", clientSecret: "b"), "client file")
    expect(GoogleClient.parse(Data(#"{"installed":{"client_id":"x","client_secret":"y","redirect_uris":["http://localhost"]}}"#.utf8))?.clientID == "x", "Google download")
    expect(GoogleClient.parse(Data("{}".utf8)) == nil, "no client")
    // accounts: round trip, upsert keeps order and replaces by email
    let a1 = GoogleAccount(email: "mike@example.com", refreshToken: "r1", scopes: GoogleScopes.all, added: Date(timeIntervalSince1970: 0))
    let a2 = GoogleAccount(email: "emily@example.com", refreshToken: "r2", scopes: GoogleScopes.identity, added: Date(timeIntervalSince1970: 0))
    let list = GoogleAccount.upsert(GoogleAccount.upsert([], a1), a2)
    expect(GoogleAccount.decode(GoogleAccount.encode(list)) == list, "accounts round trip")
    let again = GoogleAccount.upsert(list, GoogleAccount(email: "Mike@example.com", refreshToken: "r3", scopes: GoogleScopes.all, added: Date(timeIntervalSince1970: 0)))
    expect(again.count == 2 && again[0].refreshToken == "r3", "same account again replaces in place")
    expect(GoogleAccount.decode(nil).isEmpty && GoogleAccount.decode("garbage").isEmpty, "bad list is empty")
    expect(a1.has(GoogleScopes.meet) && !a2.has(GoogleScopes.calendar), "scopes per account")
    expect(!GoogleScopes.all.contains { $0.hasSuffix("/drive") || $0.hasSuffix("drive.readonly") || $0.contains("gmail") }, "no restricted scopes")
    // PKCE (RFC 7636 appendix B) and the auth URL
    expect(GoogleOAuth.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "S256 challenge")
    let u = GoogleOAuth.authURL(client: "cid", redirect: "http://127.0.0.1:5000", scopes: ["openid", "email"], state: "st", challenge: "ch", hint: "mike@example.com").absoluteString
    expect(u.contains("access_type=offline") && u.contains("code_challenge_method=S256") && u.contains("login_hint=mike@example.com") && u.contains("scope=openid%20email"), "auth URL")
    expect(GoogleOAuth.callback("/?state=st&code=4/abc&scope=x", state: "st") == .code("4/abc"), "callback code")
    expect(GoogleOAuth.callback("/?state=other&code=4/abc", state: "st") == .bad, "callback state mismatch")
    expect(GoogleOAuth.callback("/?state=st&error=access_denied", state: "st") == .denied("access_denied"), "callback denied")
    expect(String(data: GoogleOAuth.form(["b": "a b", "a": "x/y"]), encoding: .utf8) == "a=x%2Fy&b=a%20b", "form encoding")
    let payload = GoogleOAuth.base64url(Data(#"{"email":"mike@example.com"}"#.utf8))
    expect(GoogleOAuth.email(idToken: "h." + payload + ".s") == "mike@example.com", "email from id_token")
    // links
    let txt = "See https://docs.google.com/document/d/1AbcDEFghijkLMNOP_qrs/edit?tab=t.0 and https://docs.google.com/spreadsheets/d/1SheetIdABCDEFGHIJK/edit#gid=0, https://docs.google.com/presentation/d/1SlidesIdABCDEFGHIJ/edit. Also https://drive.google.com/file/d/1FileIdABCDEFGHIJKL/view and again https://docs.google.com/document/d/1AbcDEFghijkLMNOP_qrs/edit"
    let ls = GoogleLink.find(in: txt)
    expect(ls.map { $0.kind } == [.doc, .sheet, .slides, .file], "link kinds, no duplicates")
    expect(ls.first?.id == "1AbcDEFghijkLMNOP_qrs" && ls[1].url.hasSuffix("gid=0"), "ids and trimmed urls")
    expect(GoogleLink.find(in: "https://docs.google.com/forms/d/e/x/viewform").isEmpty, "a form is not a link we read")
    // Docs text: title, heading, bullets, table, tabs
    let para: (String, String, Bool) -> [String: Any] = { t, style, bullet in
        var p: [String: Any] = ["elements": [["textRun": ["content": t + "\n"]]], "paragraphStyle": ["namedStyleType": style]]
        if bullet { p["bullet"] = ["listId": "l"] }
        return ["paragraph": p]
    }
    let table: [String: Any] = ["table": ["tableRows": [["tableCells": [["content": [para("Phase", "NORMAL_TEXT", false)]], ["content": [para("Cost", "NORMAL_TEXT", false)]]]]]]]
    let doc: [String: Any] = ["title": "Pilot plan", "body": ["content": [para("Scope", "HEADING_1", false), para("Five users", "NORMAL_TEXT", true), table, para("  ", "NORMAL_TEXT", false)]]]
    let dt = GoogleText.doc(doc)
    expect(dt.hasPrefix("# Pilot plan\n") && dt.contains("## Scope") && dt.contains("- Five users") && dt.contains("| Phase | Cost |"), "doc text")
    let tabbed: [String: Any] = ["title": "T", "tabs": [["tabProperties": ["title": "One"], "documentTab": ["body": ["content": [para("A", "NORMAL_TEXT", false)]]]],
                                                       ["tabProperties": ["title": "Two"], "documentTab": ["body": ["content": [para("B", "NORMAL_TEXT", false)]]]]]]
    let tt = GoogleText.doc(tabbed)
    expect(tt.contains("# One") && tt.contains("# Two") && tt.contains("A\n") && tt.contains("B\n"), "doc tabs")
    let shape: (String) -> [String: Any] = { ["shape": ["text": ["textElements": [["textRun": ["content": $0 + "\n"]]]]]] }
    let deck: [String: Any] = ["title": "Deck", "slides": [["pageElements": [shape("Why a pilot")], "slideProperties": ["notesPage": ["pageElements": [shape("Say the hour a day")]]]]]]
    let st = GoogleText.slides(deck)
    expect(st.contains("## Slide 1") && st.contains("Why a pilot") && st.contains("Speaker notes: Say the hour a day"), "slides text")
    let sh = GoogleText.sheet(title: "Budget", ranges: [["range": "'Plan A'!A1:Z1000", "values": [["Item", "Cost"], ["QA", 100]]]], maxRows: 1)
    expect(sh.contains("## Plan A") && sh.contains("| Item | Cost |") && sh.contains("1 more rows"), "sheet text")
    // calendar event
    let item: [String: Any] = ["id": "e1", "iCalUID": "UID1@google.com", "summary": "Weekly sync", "status": "confirmed",
        "start": ["dateTime": "2026-11-05T10:00:00+02:00"], "end": ["dateTime": "2026-11-05T10:30:00+02:00"],
        "attendees": [["email": "me@example.com", "self": true, "responseStatus": "accepted"], ["email": "emily.clark@example.com", "displayName": "Emily Clark"], ["email": "room@resource.calendar.google.com", "resource": true]],
        "hangoutLink": "https://meet.google.com/abc-defg-hij",
        "conferenceData": ["conferenceId": "abc-defg-hij", "conferenceSolution": ["key": ["type": "hangoutsMeet"]]],
        "attachments": [["fileUrl": "https://docs.google.com/document/d/1AttachedDocIdABCDEF/edit", "title": "Agenda"]]]
    let ge = GoogleEvent.parse(item)
    expect(ge?.uid == "UID1@google.com" && ge?.attendees.count == 1 && ge?.attendees.first?.name == "Emily Clark", "event people, no self, no room")
    expect(ge?.meetCode == "abc-defg-hij" && ge?.attachments.first?.title == "Agenda" && ge?.allDay == false && ge?.declined == false, "event meet code and attachment")
    var declined = item; declined["attendees"] = [["email": "me@example.com", "self": true, "responseStatus": "declined"]]
    expect(GoogleEvent.parse(declined)?.declined == true, "declined by me")
    var allDay = item; allDay["start"] = ["date": "2026-11-05"]; allDay["end"] = ["date": "2026-11-06"]
    expect(GoogleEvent.parse(allDay)?.allDay == true, "all-day")
    expect(GoogleEvent.meetCode("https://meet.google.com/xyz-abcd-efg?authuser=1") == "xyz-abcd-efg" && GoogleEvent.meetCode("https://zoom.us/j/1") == nil, "meet code")
    // merge: EventKit row kept and enriched, the first account over the next
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let plan = CalendarMerge.plan(eventKit: [("UID1@google.com", t0), ("other", t0), (nil, t0)],
                                  google: [("uid1@google.com", t0), ("UID1@google.com", t0), ("UID1@google.com", t0.addingTimeInterval(604800))])
    expect(plan.enrich == [0: 0] && plan.keepGoogle == [2], "merge plan: the EventKit row stays and takes the Google details")
    // Meet
    let names = ["conferenceRecords/c/participants/p1": "Mike", "conferenceRecords/c/participants/p2": "Emily"]
    let start = ISO8601DateFormatter().date(from: "2026-11-05T08:00:00Z")!
    let tr = GoogleMeetText.transcript(entries: [["participant": "conferenceRecords/c/participants/p2", "text": "Hi", "startTime": "2026-11-05T08:01:05.120Z"],
                                                 ["participant": "x", "text": "Who?", "startTime": "2026-11-05T09:00:00Z"], ["text": ""]], names: names, start: start)
    expect(tr == "[00:01:05] Emily: Hi\n[01:00:00] ?: Who?", "meet transcript lines")
    expect(GoogleMeetText.name(["signedinUser": ["displayName": "Mike"]]) == "Mike" && GoogleMeetText.name(["phoneUser": ["displayName": "+1 555"]]) == "+1 555", "meet names")
    // Drive upload body
    let body = String(data: DriveUpload.body(name: "Notes", convertTo: "application/vnd.google-apps.document", media: Data("DOCX".utf8), mediaType: "application/x", boundary: "b1"), encoding: .utf8) ?? ""
    expect(body.hasPrefix("--b1\r\n") && body.contains("google-apps.document") && body.contains("\"name\":\"Notes\""), "upload metadata")
    expect(body.contains("\r\n\r\nDOCX\r\n--b1--"), "upload media")
}

keychain088()
google091()
settings087()
await part2_087()
usage087()
await crm087()
learningPatterns()
enginePathsFollowTheApp()
versions()
commitmentsRegister()
/// 0.9.5: call recording: settings decode with defaults, presets and sizes, file names, the call window.
func meetingNotes0952() {
    // 0.9.5.2 (rules/notes.yaml, schema 2): the ## Meeting notes section of the call notes, and the export's Markdown
    let notes = """
    # Call notes: Orbit weekly
    Date 2026-11-05 10:00, Mike Johnson (team), David Kim (client).
    ## Meeting notes
    ### TL;DR
    The export is merged;
    the pilot starts November 10.
    ### Decisions
    - [10:04:10] Export goes to production on Tuesday.
    ### Action items
    - [10:06:29] **David Kim**: send the test accounts (due: Friday)
    ### Open questions
    - Data retention statement needs legal approval.
    ### Topics
    #### Export screen [10:00:21]
    Outcome: merged to main, ships Tuesday.
    - [10:00:30] Mike: failed payments retry after 1, 6 and 24 hours.
    #### Pilot readiness [10:06]
    **Outcome:** starts November 10 if the accounts come by Friday.
    - [10:06:18] David's manager wants one more approval.
    ### Unclear
    - The name of the security vendor.

    ## Summary
    Export and pilot.
    ## Decisions
    - Export goes to production on Tuesday

    Coverage: numbers 4/4.
    """
    guard let m = MeetingNotes.parse(notes) else { expect(false, "meeting notes: the section is read"); return }
    expect(m.tldr == "The export is merged; the pilot starts November 10.", "meeting notes: TL;DR lines joined")
    expect(m.decisions == [MeetingNotes.Item(t: "10:04:10", text: "Export goes to production on Tuesday.")], "meeting notes: a decision with its time")
    expect(m.actions.first?.hhmm == "10:06" && m.actions.first?.text.hasPrefix("**David Kim**") == true, "meeting notes: an action item")
    expect(m.open.first?.t == "" && m.open.count == 1, "meeting notes: an item without a time")
    expect(m.topics.map(\.title) == ["Export screen", "Pilot readiness"] && m.topics[1].t == "10:06", "meeting notes: topics and times")
    expect(m.topics[0].outcome == "merged to main, ships Tuesday." && m.topics[1].outcome.hasPrefix("starts November 10"), "meeting notes: outcome lines")
    expect(m.topics[0].points.count == 1 && m.topics[0].points[0].t == "10:00:30", "meeting notes: points with times")
    expect(m.unclear.count == 1 && m.decisions.count == 1, "meeting notes: the full notes' sections are not read in")
    expect(MeetingNotes.parse("# Call notes\n## Summary\nx\n") == nil, "meeting notes: none in older notes")
    let lab = MeetingNotes.Labels(title: "Orbit weekly", tldr: "Summary", decisions: "Decisions", actions: "Action items",
                                  open: "Open questions", topics: "Topics", unclear: "Unclear")
    let md = MeetingNotes.markdown(m, lab, when: "Thu, Nov 5 · 10:00")
    expect(md.hasPrefix("# Orbit weekly\n\nThu, Nov 5 · 10:00\n\n## Summary\n\nThe export"), "meeting notes: Markdown head")
    expect(md.contains("\n### Export screen [10:00]\n\n*merged to main, ships Tuesday.*\n\n- [10:00] Mike"), "meeting notes: Markdown topic")

    // the export: Markdown into blocks, Word, Notion, HTML
    let b = DocMD.parse(md + "\n  - nested point\n- [ ] check the CSV\n")
    expect(b.first == DocMD.Block(.h1, [DocMD.Run("Orbit weekly")]), "docmd: # is the title")
    expect(b.contains { $0.kind == .h3 && $0.plain == "Export screen [10:00]" }, "docmd: ### is a heading, without the marks")
    expect(DocMD.inline("**David Kim**: send *now* `X-1`") == [DocMD.Run("David Kim", bold: true), DocMD.Run(": send "),
                                                              DocMD.Run("now", italic: true), DocMD.Run(" "), DocMD.Run("X-1", code: true)], "docmd: bold, italic, code")
    expect(DocMD.inline("2 * 3 and a**b") == [DocMD.Run("2 * 3 and a**b")], "docmd: lone stars stay as typed")
    expect(DocMD.inline("snake_case_name") == [DocMD.Run("snake_case_name")], "docmd: underscores inside a word stay")
    expect(b.contains { $0.kind == .bullet(1) } && b.last?.kind == .todo(false), "docmd: a nested bullet and a to-do")
    let doc = DocMD.documentXML(b)
    expect(doc.contains("<w:pStyle w:val=\"Heading1\"/></w:pPr><w:r><w:t xml:space=\"preserve\">Summary</w:t>"), "docx: ## is Word's Heading 1")
    expect(doc.contains("<w:pStyle w:val=\"Heading2\"/>") && doc.contains("<w:numId w:val=\"1\"/>") && doc.contains("<w:ilvl w:val=\"1\"/>"), "docx: Heading 2 and real lists")
    expect(doc.contains("<w:rPr><w:b/></w:rPr><w:t xml:space=\"preserve\">David Kim</w:t>") && !doc.contains("**") && !doc.contains("###"), "docx: bold runs, no marks left")
    let z = DocMD.docx(b)
    if let out = ProcessInfo.processInfo.environment["LT_DOCX_OUT"] { try? z.write(to: URL(fileURLWithPath: out)) }   // a manual look in Word
    expect(z.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]) && z.suffix(22).prefix(4) == Data([0x50, 0x4B, 0x05, 0x06]), "docx: a zip")
    expect(Zip.crc32(Data("123456789".utf8)) == 0xCBF43926, "zip: crc32")
    let nb = DocMD.notion(b)
    expect(nb.first?["type"] as? String == "paragraph" && nb.contains { $0["type"] as? String == "heading_2" } && nb.contains { $0["type"] as? String == "to_do" }, "notion: no title block, headings, to-do")
    let bold = nb.compactMap { ($0["bulleted_list_item"] as? [String: Any])?["rich_text"] as? [[String: Any]] }.flatMap { $0 }
        .first { (($0["annotations"] as? [String: Bool])?["bold"]) == true }
    expect(((bold?["text"] as? [String: Any])?["content"] as? String) == "David Kim", "notion: bold as an annotation")
    expect(nb.contains { (($0["bulleted_list_item"] as? [String: Any])?["children"] as? [[String: Any]])?.count == 1 }, "notion: a nested bullet is a child")
    let h = DocMD.html(b)
    expect(h.contains("<h2>Summary</h2>") && h.contains("<ul><li>") && h.contains("<ul><li>nested point</li></ul>") && h.contains("<strong>David Kim</strong>"), "html: headings and nested lists")
}

func callRecording() {
    let d = try? JSONDecoder().decode(RecordingSettings.self, from: Data("{\"kind\":\"bogus\",\"auto\":true,\"quality\":\"sharp\"}".utf8))
    expect(d?.kind == "video" && d?.auto == true && d?.quality == "sharp" && d?.drive == "manual", "recording: unknown values fall back, known ones kept")
    expect(d?.defaultForCall == "video" && RecordingSettings().defaultForCall == "off", "recording: off by default, auto records the kind")
    let old = try? JSONDecoder().decode(AppConfig.self, from: Data("{\"usageLog\":true}".utf8))
    expect(old?.recording == RecordingSettings(), "recording: a config without it gets the defaults")
    let std = RecordingPreset.find("standard")
    expect(RecordingPreset.find("nope") == std, "recording: an unknown preset is Standard")
    expect(std.mbPerHour("h264") == 569 && std.mbPerHour("hevc") == 366 && RecordingPreset.audioMBPerHour == 29, "recording: MB an hour \(std.mbPerHour("h264")) \(std.mbPerHour("hevc"))")
    let (w, h) = std.outputSize(width: 1728, height: 1117, scale: 2)
    expect(w == 1920 && h == 1240 && w % 2 == 0 && h % 2 == 0, "recording: scaled to the width, even \(w)x\(h)")
    let (w2, h2) = std.outputSize(width: 801, height: 601, scale: 1)
    expect(w2 == 800 && h2 == 600, "recording: small windows keep their size, even numbers")
    let t = "/p/Orbit/live/2026-11-05-1430-weekly-sync.app.md"
    expect(RecordingFiles.stem(transcript: t) == "2026-11-05-1430-weekly-sync", "recording: stem without .app and .md")
    expect(RecordingFiles.folder(transcript: t) == "/p/Orbit/video", "recording: <project>/video")
    expect(RecordingFiles.partPath(transcript: t, part: 1, audioOnly: false) == "/p/Orbit/video/2026-11-05-1430-weekly-sync.recording.mp4", "recording: first part")
    expect(RecordingFiles.partPath(transcript: t, part: 2, audioOnly: true) == "/p/Orbit/video/2026-11-05-1430-weekly-sync.recording-2.m4a", "recording: second part, sound only")
    expect(RecordingFiles.metaPath(transcript: t) == "/p/Orbit/video/2026-11-05-1430-weekly-sync.recording.json", "recording: meta")
    var m = RecordingMeta(); m.title = "Weekly sync"
    var p1 = RecordingMeta.Part(file: "a.recording.mp4", kind: "video", started: Date(timeIntervalSince1970: 1_800_000_000)); p1.seconds = 60; p1.bytes = 10
    var p2 = p1; p2.file = "a.recording-2.mp4"; p2.driveID = "x"
    m.parts = [p1, p2]
    let mp = NSTemporaryDirectory() + "pn-rec-\(UUID().uuidString)/x.recording.json"
    m.save(mp)
    let back = RecordingMeta.load(mp)
    expect(back == m && back?.notUploaded.map(\.file) == ["a.recording.mp4"] && back?.totalSeconds == 120, "recording: meta round trip, what is not uploaded")
    try? FileManager.default.removeItem(atPath: (mp as NSString).deletingLastPathComponent)
    typealias C = MeetingWindow.Candidate
    let chrome = C(id: 1, bundle: "com.google.Chrome", app: "Chrome", title: "Meet - abc-defg-hij", width: 1400, height: 900)
    let docs = C(id: 2, bundle: "com.google.Chrome", app: "Chrome", title: "Meeting notes - Google Docs", width: 1600, height: 1000)
    let zoomHome = C(id: 3, bundle: "us.zoom.xos", app: "zoom.us", title: "Home", width: 900, height: 600)
    let zoomMeet = C(id: 4, bundle: "us.zoom.xos", app: "zoom.us", title: "Zoom Meeting", width: 1200, height: 800)
    let slack = C(id: 5, bundle: "com.tinyspeck.slackmacgap", app: "Slack", title: "general", width: 1200, height: 800)
    let tiny = C(id: 6, bundle: "com.microsoft.teams2", app: "Teams", title: "", width: 300, height: 100)
    expect(MeetingWindow.score(docs) == 0 && MeetingWindow.score(slack) == 0 && MeetingWindow.score(tiny) == 0, "recording: not calls")
    expect(MeetingWindow.best([docs, chrome, zoomHome]) == chrome, "recording: the Meet tab, not the Docs tab or Zoom's home")
    expect(MeetingWindow.best([chrome, zoomMeet, docs]) == zoomMeet, "recording: a Zoom meeting first")
    expect(MeetingWindow.best([docs, slack]) == nil, "recording: no call window")
}

frameRoundTripAcrossChunks()
frameResyncAfterGarbage()
watchdogStartGraceThenStallTerminateKillRestart()
watchdogMutedMicIsNotAStall()
watchdogTwoFailedRestartsSwitchToBuiltInMic()
projectConfigParse()
registryMergeKeepsUserFields()
secretsAndConfig()
mirrorAndWorkspaces()
let codexCandidates = CodexCLI.candidates(home: "/tmp/demo", path: "/custom/bin:/usr/bin")
expect(codexCandidates.contains("/custom/bin/codex"), "Codex CLI follows PATH")
expect(codexCandidates.contains("/tmp/demo/.local/bin/codex"), "Codex CLI supports local install")
expect(CodexCLI.isChatGPT(status: 0, output: "Logged in using ChatGPT"), "Codex ChatGPT auth")
expect(!CodexCLI.isChatGPT(status: 0, output: "Logged in using an API key"), "Codex API key is not account auth")
expect(!CodexCLI.isChatGPT(status: 1, output: "Logged in using ChatGPT"), "Codex failed status is not signed in")
let codexEnv = CodexCLI.environment(["OPENAI_API_KEY": "dummy", "CODEX_ACCESS_TOKEN": "dummy", "PATH": "/bin", "CODEX_HOME": "/tmp/auth"])
expect(codexEnv == ["PATH": "/bin", "CODEX_HOME": "/tmp/auth"], "Codex reuses login without API credentials")
expect(CodexCLI.loginCommand(cli: "/tmp/O'Reilly/codex").contains("O'\\''Reilly"), "Codex login quotes executable path")
// 0.9.3: Settings > Usage, AI through API keys (AIUsage, from state/spend-ledger.jsonl)
let usageLedger = """
{"at": "2026-11-03T10:00:00+0200", "job": "live", "route": "gemini", "model": "gemini-3.5-flash-lite", "input": 100, "output": 20, "cache_read": 40, "usd": 0.001, "error": false}
{"at": "2026-11-04T09:00:00+02:00", "job": "prep", "route": "openai", "model": "gpt-6.1-sol", "input": 1000, "output": 300, "usd": 0.05, "error": false}
{"at": "2026-11-04T11:00:00+0200", "job": "after_notes", "route": "api", "model": "claude-sonnet-5-5", "input": 500, "output": 100, "usd": 0.02}
{"at": "2026-11-04T11:05:00+0200", "job": "after", "route": "code", "model": "claude-code/sonnet", "usd": 0.3}
{"at": "2026-11-04T11:06:00+0200", "job": "ping", "route": "api", "model": "claude-haiku-5-5", "usd": 0.0001}
not json
"""
let usageRows = AIUsage.parse(text: usageLedger)
expect(usageRows.count == 3, "usage: only API routes, no route checks, bad lines skipped")
expect(usageRows.map(\.provider) == ["gemini", "openai", "claude"], "usage: providers by route")
expect(usageRows.map(\.stage) == ["live", "prep", "after"], "usage: stages by job")
expect(usageRows[0].day == "2026-11-03" && usageRows[0].input == 100 && usageRows[0].cacheRead == 40, "usage: day and tokens")
let usageDay = AIUsage.filter(usageRows, from: "2026-11-04", to: "2026-11-04")
expect(usageDay.count == 2 && abs(AIUsage.total(usageDay).usd - 0.07) < 1e-9, "usage: a day and its total")
let usageStage = AIUsage.byStage(usageRows)
expect(usageStage["prep"]?["openai"]?.requests == 1 && usageStage["live"]?["claude"]?.requests == 0, "usage: every stage and provider present")
expect(AIUsage.byModel(usageRows).map(\.provider) == ["claude", "openai", "gemini"], "usage: models in provider order")
expect(AIUsage.stage(job: "prep_refresh") == "prep" && AIUsage.stage(job: "judge") == "after" && AIUsage.stage(job: "tips") == "live", "usage: job names")
// 0.9.6: monthly limits and alerts per provider, economy mode, the call agent's settings
expect(AIUsage.stage(job: "agent") == "live", "usage: the call agent counts as live")
let plMonth = ProviderLimits.monthSpend(usageRows, month: "2026-11")
expect(abs((plMonth["openai"] ?? 0) - 0.05) < 1e-9 && abs((plMonth["claude"] ?? 0) - 0.02) < 1e-9 && plMonth["gemini"] != nil, "limits: month spend by provider")
expect(ProviderLimits.monthSpend(usageRows, month: "2026-10").isEmpty, "limits: another month is empty")
var plb = AppConfig.ProviderBudget()
expect(ProviderLimits.level(spent: 99, budget: plb) == .ok, "limits: no limit, no alert")
plb.monthlyUSD = 10; plb.alertPercent = 70
expect(ProviderLimits.level(spent: 6.9, budget: plb) == .ok && ProviderLimits.level(spent: 7, budget: plb) == .alert
       && ProviderLimits.level(spent: 10, budget: plb) == .capped, "limits: ok, alert at the share, capped at the limit")
var plbs = AppConfig.ProviderBudgets(); plbs["gemini"] = plb
expect(ProviderLimits.caps(plbs) == ["gemini": 10] && plbs.gemini.monthlyUSD == 10 && plbs.claude.monthlyUSD == 0, "limits: only set limits go to the engine")
let plKey = ProviderLimits.alertKey(provider: "claude", month: "2026-11", level: .alert)
expect(ProviderLimits.due(level: .alert, shown: [], provider: "claude", month: "2026-11") == .alert
       && ProviderLimits.due(level: .alert, shown: [plKey], provider: "claude", month: "2026-11") == nil
       && ProviderLimits.due(level: .capped, shown: [plKey], provider: "claude", month: "2026-11") == .capped
       && ProviderLimits.due(level: .ok, shown: [], provider: "claude", month: "2026-11") == nil, "limits: each alert once a month")
let plBad = try? JSONDecoder().decode(AppConfig.ProviderBudget.self, from: Data(#"{"monthlyUSD": -5, "alertPercent": 300}"#.utf8))
expect(plBad?.monthlyUSD == 0 && plBad?.alertPercent == 100, "limits: bad values are clamped")
let ecoDir = NSTemporaryDirectory() + "pn-economy-\(getpid())"
Economy.set(true, stateDir: ecoDir)
expect(Economy.isOn(stateDir: ecoDir), "economy: on")
Economy.set(false, stateDir: ecoDir)
expect(!Economy.isOn(stateDir: ecoDir), "economy: off")
// 0.9.6 Б1: economy mode v1, the plan from the next job
let both = EconomyPlan.Accounts(claude: true, chatgpt: true), none = EconomyPlan.Accounts(claude: false, chatgpt: false)
expect(EconomyPlan.jobRoute("api", accounts: both) == "code" && EconomyPlan.jobRoute("openai", accounts: both) == "codex", "economy: key ways move to the accounts")
expect(EconomyPlan.jobRoute("gemini", accounts: both) == "gemini" && EconomyPlan.jobRoute("api", accounts: none) == "api", "economy: Gemini never to agy; no account, no move")
expect(EconomyPlan.tipsModel(route: "openai") == "gpt-6-luna" && EconomyPlan.tipsModel(route: "gemini") == "gemini-3.5-flash-lite" && EconomyPlan.tipsModel(route: "local") == nil, "economy: cheapest tips model per way")
var ecoCfg = AppConfig(); ecoCfg.ai.prep = "api"; ecoCfg.ai.after = "openai"; ecoCfg.ai.tips = "api"; ecoCfg.models.tip = "claude-sonnet-5-5"; ecoCfg.ai.openaiTips = "gpt-6.1-sol"
expect(EconomyPlan.apply(ecoCfg, on: false, accounts: both) == ecoCfg, "economy: off changes nothing")
let ecoOn = EconomyPlan.apply(ecoCfg, on: true, accounts: EconomyPlan.Accounts(claude: true, chatgpt: false))
expect(ecoOn.ai.prep == "code" && ecoOn.ai.after == "openai" && ecoOn.ai.openaiAfter == "gpt-6-luna", "economy: prep to the account, after on the cheaper model without an account")
expect(ecoOn.models.tip == "claude-haiku-5-5" && ecoOn.ai.openaiTips == "gpt-6-luna" && ecoOn.models.classify == ecoCfg.models.classify, "economy: tips cheapest, classify untouched")
expect(EconomyPlan.apply(ecoOn, on: true, accounts: EconomyPlan.Accounts(claude: true, chatgpt: false)) == ecoOn, "economy: applying twice changes nothing")
var gemCfg = AppConfig(); gemCfg.ai.prep = "gemini"; gemCfg.ai.after = "gemini"
let gemOn = EconomyPlan.apply(gemCfg, on: true, accounts: both)
expect(gemOn.ai.prep == "gemini" && gemOn.ai.geminiPrep == gemCfg.ai.geminiPrep && gemOn.ai.geminiAfter == "gemini-3.5-flash-lite", "economy: the preparation is not made cheaper")
let pf = EconomyPlan.prepFeatures(tools: true, verify: true, parallel: true, verifyModel: "claude-sonnet-5-5", economy: true)
expect(pf.tools && pf.verify && pf.verifyModel == "claude-haiku-5-5" && !pf.parallel, "economy: prep tools yes, checker on Haiku, no parallel")
let caOld = try? JSONDecoder().decode(AppConfig.self, from: Data(#"{"uiLanguage": "en"}"#.utf8))
expect(caOld?.callAgent.enabled == false && caOld?.callAgent.tools == true && caOld?.providerBudgets.claude.alertPercent == 80, "agent: off by default in an older config")
expect(caOld?.callAgent.proactive == false && caOld?.callAgent.proactiveUSDPerCall == 0.25, "agent: background searches off by default")
var caCfg = AppConfig(); caCfg.callAgent.enabled = true; caCfg.callAgent.model = "claude-haiku-5-5"; caCfg.providerBudgets.openai.monthlyUSD = 20
caCfg.callAgent.proactive = true; caCfg.callAgent.proactiveUSDPerCall = 0.4
let caURL = URL(fileURLWithPath: NSTemporaryDirectory() + "pn-agent-config.json")
try? caCfg.save(to: caURL)
expect(AppConfig.load(from: caURL) == caCfg, "agent and limits: config round trip")
try? FileManager.default.removeItem(at: caURL)
// 0.9.3: the Gemini account through Antigravity CLI
let agyList = AgyCLI.models(output: "gemini-4-argon-medium\tGemini 4 Argon (Medium)\nclaude-opus-5-5-low\tClaude Opus 5.5 (Low)\ngemini-3.8-flash-medium\tGemini 3.8 Flash (Medium)\nFetching available models...\n")
expect(agyList.map(\.id) == ["gemini-4-argon-medium", "gemini-3.8-flash-medium"], "agy: only the Gemini models of the list")
expect(AgyCLI.environment(["GEMINI_API_KEY": "k", "GOOGLE_API_KEY": "k", "CLAUDE_API": "k", "PATH": "/bin"]) == ["PATH": "/bin"], "agy: no API key reaches the account")
expect(AgyCLI.candidates(home: "/tmp/h", path: "/x/bin").contains("/tmp/h/.local/bin/agy"), "agy: the installer's place")
expect(AgyCLI.loginCommand(cli: "/tmp/O'R/agy").contains("O'\\''R") && AgyCLI.loginCommand(cli: "/a/agy").contains("mktemp -d"), "agy: login quoted, in an empty folder")
// 0.9.4: one person, many spellings (VoiceBook) and speakers named from Google Meet (MeetSpeakers)
var vb: [String: Any] = ["people": ["M. T.": ["calls": 2, "embeddings": [[0.1]], "side": "team"], "Mike T.": ["calls": 3, "embeddings": [[0.2]]],
                                    "Emily Clark": ["calls": 1]], "aliases": ["mt": "M. T."]]
vb = VoiceBook.merge(vb, "M. T.", "Mike T.", keep: "Mike Turner")
let vbp = vb["people"] as? [String: Any] ?? [:]
expect(vbp["M. T."] == nil && vbp["Mike T."] == nil && ((vbp["Mike Turner"] as? [String: Any])?["calls"] as? Int) == 5, "voicebook: merged under a new primary")
expect(((vbp["Mike Turner"] as? [String: Any])?["side"] as? String) == "team", "voicebook: the side is kept")
expect(VoiceBook.resolve(vb, "m. t.") == "Mike Turner" && VoiceBook.resolve(vb, "MT") == "Mike Turner" && VoiceBook.resolve(vb, "Mike T.") == "Mike Turner", "voicebook: every spelling resolves")
expect(VoiceBook.aliasesOf(vb, "Mike Turner") == ["m. t.", "mike t.", "mt"], "voicebook: aliases listed")
let (vb2, r1) = VoiceBook.addAlias(vb, "Emily Clark", to: "Mike Turner")
expect(r1 == .isPerson && VoiceBook.aliasesOf(vb2, "Mike Turner").count == 3, "voicebook: a person is not an alias")
let (vb3, r2) = VoiceBook.addAlias(vb, "Mikey", to: "Mike Turner")
expect(r2 == .added && VoiceBook.resolve(vb3, "mikey") == "Mike Turner", "voicebook: alias added")
expect(VoiceBook.addAlias(vb3, "Mikey", to: "Emily Clark").1 == .otherPerson("Mike Turner"), "voicebook: an alias of someone else is asked first")
let vb4 = VoiceBook.rename(vb3, "Mike Turner", to: "Mike Turner-K")
expect(VoiceBook.resolve(vb4, "mt") == "Mike Turner-K" && VoiceBook.resolve(vb4, "Mike Turner") == "Mike Turner-K", "voicebook: rename keeps old names")
let msMd = "[10:00:01] Them [S2] (en): hi\n[10:00:05] Me (en): hello\n[10:00:09] Them [S2] (en): so\n[10:00:20] Them [S3] (en): yes\n[10:00:30] Them [S2] (en): ok\n[10:00:40] Them [S3] (en): sure\n[10:00:50] Them [S3] (en): right\n"
let msLines = MeetSpeakers.lines(msMd)
expect(msLines.count == 6 && msLines[0].t == 36001 && msLines[0].sid == "S2", "meet: tagged lines only")
var msCal = Calendar(identifier: .gregorian); msCal.timeZone = TimeZone(identifier: "UTC")!
func msAt(_ s: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(1_800_000_000 / 86400 * 86400 + s)) }
let msSpoken = [MeetSpeakers.Spoken(name: "Mike Brown", start: msAt(36000), end: msAt(36012)), MeetSpeakers.Spoken(name: "Mike Brown", start: msAt(36028), end: msAt(36032)),
                MeetSpeakers.Spoken(name: "Emily Clark", start: msAt(36018), end: msAt(36022)), MeetSpeakers.Spoken(name: "Emily Clark", start: msAt(36038), end: msAt(36055)),
                MeetSpeakers.Spoken(name: "Mike Turner", start: msAt(36004), end: msAt(36006))]
let msGot = MeetSpeakers.match(lines: msLines, spoken: msSpoken, participants: [], named: [:], me: ["Mike Turner"], calendar: msCal)
expect(msGot == ["S2": "Mike Brown", "S3": "Emily Clark"], "meet: voices named by time \(msGot)")
expect(MeetSpeakers.match(lines: msLines, spoken: msSpoken, participants: [], named: ["S2": "Mike Brown"], me: [], calendar: msCal) == ["S3": "Emily Clark"], "meet: a taken name is not given twice")
expect(MeetSpeakers.match(lines: msLines, spoken: [], participants: ["Mike Turner", "Mike Brown"], named: ["S3": "Emily Clark"], me: ["mike turner"]) == ["S2": "Mike Brown"], "meet: one voice, one free participant")
expect(MeetSpeakers.match(lines: msLines, spoken: [], participants: ["Mike Brown", "Emily Clark"], named: [:], me: []).isEmpty, "meet: no guess with two voices")
expect(MeetSpeakers.match(lines: msLines, spoken: [], participants: ["Mike B."], named: ["S3": "Emily Clark"], me: [], resolve: { $0 == "Mike B." ? "Mike Brown" : $0 }) == ["S2": "Mike Brown"], "meet: the library's name kept")
// 0.9.4: Help improve Pacenote (Telemetry): complete days since it was turned on, once a week, only allowed events
let tmNow = ISO8601DateFormatter().date(from: "2026-11-20T12:00:00Z")!
var tmS = Telemetry.State()
expect(Telemetry.due(tmS, now: tmNow) == nil, "telemetry: nothing before it is turned on")
tmS.since = "2026-11-10"
expect(Telemetry.due(tmS, now: tmNow).map { $0.from + ".." + $0.to } == "2026-11-10..2026-11-19", "telemetry: from the day it was turned on to yesterday")
tmS.sentUntil = "2026-11-17"; tmS.sentAt = "2026-11-18T09:00:00Z"
expect(Telemetry.due(tmS, now: tmNow) == nil, "telemetry: once a week")
tmS.sentAt = "2026-11-12T09:00:00Z"
expect(Telemetry.due(tmS, now: tmNow).map { $0.from + ".." + $0.to } == "2026-11-18..2026-11-19", "telemetry: the days after the last batch")
let tmR = Telemetry.ensured(Telemetry.State(), now: tmNow)
expect(tmR.install.count == 36 && Telemetry.ensured(tmR, now: tmNow.addingTimeInterval(40 * 86400)).install == tmR.install, "telemetry: one id per install, kept")
// 0.10.1 (A6, D15): on by default; an older config is switched on once and told, unless its usage log is off
func telemetryDefault0101() {
    let dec = { (j: String) in try? JSONDecoder().decode(AppConfig.self, from: Data(j.utf8)) }
    expect(AppConfig().shareUsage && AppConfig().shareUsageDefaulted && !AppConfig().shareUsageNote, "telemetry 0.10.1: on for a new install, nothing to tell")
    let upd = dec("{\"usageLog\":true,\"shareUsage\":false}")
    expect(upd?.shareUsage == true && upd?.shareUsageNote == true && upd?.shareUsageDefaulted == true, "telemetry 0.10.1: an update turns it on once and says so")
    let noLog = dec("{\"usageLog\":false,\"shareUsage\":false}")
    expect(noLog?.shareUsage == false && noLog?.shareUsageNote == false, "telemetry 0.10.1: the usage log off keeps sharing off")
    let was = dec("{\"usageLog\":true,\"shareUsage\":true}")
    expect(was?.shareUsage == true && was?.shareUsageNote == false, "telemetry 0.10.1: already on, nothing to tell")
    let off = dec("{\"usageLog\":true,\"shareUsage\":false,\"shareUsageDefaulted\":true}")
    expect(off?.shareUsage == false && off?.shareUsageNote == false, "telemetry 0.10.1: turned off after the default stays off")
    if let u = upd, let d = try? JSONEncoder().encode(u), let again = try? JSONDecoder().decode(AppConfig.self, from: d) {
        var a2 = again; a2.shareUsage = false; a2.shareUsageNote = false
        let back = (try? JSONEncoder().encode(a2)).flatMap { try? JSONDecoder().decode(AppConfig.self, from: $0) }
        expect(back?.shareUsage == false, "telemetry 0.10.1: the default is applied once, a later off survives a reload")
    }
    expect(UsageLog.line("call_reassign", ["when": "after", "files": 7]) != nil && UsageLog.line("rec_saved", ["kind": "audio", "minutes": 30]) != nil,
           "usage 0.10.1: events the app logs are allowed")
}
telemetryDefault0101()
let tmDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pn-tm-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmDir, withIntermediateDirectories: true)
try? """
{"t":"2026-11-09T10:00:00Z","e":"tip_rated","p":{"kind":"tip","verdict":"partly","reason":"off_topic"}}
{"t":"2026-11-18T10:00:00Z","e":"tip_rated","p":{"kind":"tip","verdict":"partly","reason":"off_topic"}}
{"t":"2026-11-18T10:01:00Z","e":"call_ended","p":{"minutes":1}}
{"t":"2026-11-18T10:02:00Z","e":"made_up","p":{}}
{"t":"2026-11-18T10:03:00Z","e":"tip_rated","p":{"text":"the words of the call"}}
{"t":"2026-11-20T10:00:00Z","e":"help_now","p":{}}
""".write(to: tmDir.appendingPathComponent("2026-11.jsonl"), atomically: true, encoding: .utf8)
let tmB = Telemetry.batch(usageDir: tmDir, from: "2026-11-10", to: "2026-11-19", install: "x", appVersion: "0.9.4", rulesVersion: "0.3.0", uiLang: "uk", routes: ["tips": "api"])
let tmE = tmB["events"] as? [[String: Any]] ?? []
expect(tmE.count == 2 && tmE[0]["d"] as? String == "2026-11-18" && tmE[0]["t"] == nil, "telemetry: only allowed events of those days, days not times")
expect(((tmE[1]["p"] as? [String: Any])?["minutes"] as? NSNumber)?.intValue == 1, "telemetry: numbers as written")
try? FileManager.default.removeItem(at: tmDir)
/// 0.9.6 Б3 (rules/prep.yaml): the research preparation's plan, flags and process chain.
func prepAgent096() {
    let old = try? JSONDecoder().decode(AppConfig.self, from: Data(#"{"uiLanguage": "en"}"#.utf8))
    expect(old?.prepAgent == AppConfig.PrepAgentSettings() && old?.prepAgent.tools == true && old?.prepAgent.verify == false
           && old?.prepAgent.parallel == false && old?.prepAgent.budgetUSD == 1.5, "prep agent: tools on, the check and parallel off in an older config (owner, Б4)")
    let kept = try? JSONDecoder().decode(AppConfig.self, from: Data(#"{"uiLanguage": "en", "prepAgent": {"tools": false}}"#.utf8))
    expect(kept?.prepAgent.tools == false, "prep agent: a saved tools switch stays as saved")
    let dflt = PrepAgent.plan(AppConfig.PrepAgentSettings(), route: "api", economy: false)
    expect(dflt?.features.tools == true && dflt?.features.verify == false && dflt?.features.parallel == false && dflt?.budgetUSD == 1.5,
           "prep agent: the default plan is the tools only, capped on the API way")
    var s = AppConfig.PrepAgentSettings(); s.tools = false
    expect(PrepAgent.plan(s, route: "api", economy: false) == nil, "prep agent: all off, no plan")
    s.tools = true; s.verify = true; s.parallel = true
    expect(PrepAgent.plan(s, route: "openai", economy: false) == nil && PrepAgent.plan(s, route: "local", economy: false) == nil
           && PrepAgent.plan(s, route: "codex", economy: false) == nil, "prep agent: only the Claude ways")
    let api = PrepAgent.plan(s, route: "api", economy: false), code = PrepAgent.plan(s, route: "code", economy: false)
    expect(api?.budgetUSD == 1.5 && code?.budgetUSD == nil && api?.features.verifyModel == "claude-haiku-5-5", "prep agent: the budget only on the API way, the checker on Haiku")
    let eco = PrepAgent.plan(s, route: "code", economy: true)
    expect(eco?.features.tools == true && eco?.features.verify == true && eco?.features.parallel == false && eco?.record["economy"] == "true",
           "prep agent: economy keeps tools and the checker, no parallel")
    expect(api?.record == ["tools": "true", "verify": "true", "parallel": "true", "economy": "false", "verify_model": "claude-haiku-5-5", "budget_usd": "1.50"],
           "prep agent: run.json record")
    var onlyVerify = AppConfig.PrepAgentSettings(); onlyVerify.tools = false; onlyVerify.verify = true
    expect(PrepAgent.plan(onlyVerify, route: "api", economy: false)?.budgetUSD == nil, "prep agent: the checker alone leaves the preparation uncapped")
    if let p = api {
        expect(PrepAgent.allowed(p).contains("mcp__pacenote__decisions") && PrepAgent.allowed(p).contains("Agent") && PrepAgent.undeny(p) == ["Task", "Agent"],
               "prep agent: tools and the subagent tool allowed")
        expect(PrepAgent.prompt(p).contains("PACENOTE TOOLS") && PrepAgent.prompt(p).contains("never more than 5 subagents") && !PrepAgent.prompt(p).contains("\u{2014}"),
               "prep agent: prompt lines")
        let basePrompt = "Work with local files: no Notion or Jira APIs, no MCP tools, no recording, no subagents (x). Skip every part that needs Notion, Jira, the Agent tool, device_bash, polling."
        let adj = PrepAgent.adjust(basePrompt, p)
        expect(!adj.contains("no subagents") && !adj.contains("the Agent tool") && adj.contains("except Pacenote's tools") && adj.contains("subagents only as"),
               "prep agent: the base prompt names the switched-on features (Б4 smoke)")
        var onlyTools = AppConfig.PrepAgentSettings(); onlyTools.tools = true
        if let t = PrepAgent.plan(onlyTools, route: "code", economy: false) {
            let a2 = PrepAgent.adjust(basePrompt, t)
            expect(a2.contains("no subagents") && a2.contains("the Agent tool") && a2.contains("except Pacenote's tools"), "prep agent: tools only keep the no-subagents line")
        }
        expect(PrepAgent.adjust(basePrompt, PrepAgent.plan(onlyVerify, route: "code", economy: false)!) == basePrompt, "prep agent: the checker alone leaves the prompt as it was")
        let vr = PrepAgent.verifyRequest(p, base: "/p/live/prep-x", root: "/p", extra: ["/d"], lt: ["/py", "/lt"], claude: "/c", route: "api",
                                         stateDir: "/s", python: "/vpy", engineDir: "/eng", lang: "uk")
        expect(vr["route"] as? String == "api" && vr["model"] as? String == "claude-haiku-5-5" && (vr["budget_usd"] as? Double ?? 0) > 0, "prep agent: checker request on the API way")
        expect(PrepAgent.verifyRequest(p, base: "b", root: "r", extra: [], lt: [], claude: "c", route: "code", stateDir: "s", python: "p", engineDir: "e", lang: "en")["route"] as? String == "plan",
               "prep agent: checker request on the account way")
    }
    let mcp = (try? JSONSerialization.jsonObject(with: Data(PrepAgent.mcpConfig(python: "/vpy", engineDir: "/eng", root: "/p", extra: ["/d"], lt: ["/py", "/lt"]).utf8))) as? [String: Any]
    let srv = (mcp?["mcpServers"] as? [String: Any])?["pacenote"] as? [String: Any]
    expect(srv?["command"] as? String == "/vpy" && srv?["args"] as? [String] == ["-m", "livetips_m0.pn_mcp", "--root", "/p", "--extra", "/d", "--lt", "/py", "/lt"]
           && (srv?["env"] as? [String: String]) == ["PYTHONPATH": "/eng"], "prep agent: the pn_mcp config matches pn_mcp.mcp_config")
    let ag = (try? JSONSerialization.jsonObject(with: Data(PrepAgent.agentsJSON(withTools: false).utf8))) as? [String: Any]
    let tl = (ag?["researcher"] as? [String: Any])?["tools"] as? [String]
    expect(tl == ["Read", "Grep", "Glob"], "prep agent: researcher read-only, no Pacenote tools when they are off")
    // the chain with stand-ins: the checker runs only after a good preparation that wrote the brief
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pn-chain-\(getpid())")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let spy = tmp.appendingPathComponent("spy.sh").path, mark = tmp.appendingPathComponent("mark").path, brief = tmp.appendingPathComponent("b.brief.md").path
    try? "#!/bin/sh\necho \"$PYTHONPATH $*\" > \"\(mark)\"\n".write(toFile: spy, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: spy)
    try? "brief".write(toFile: brief, atomically: true, encoding: .utf8)
    func chain(_ exe: String, verify: Bool) -> (Int32, String?) {
        try? FileManager.default.removeItem(atPath: mark)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", PrepAgent.chain, "sh", "-p", "x"]
        var env = ["LT_EXE": exe, "LT_BRIEF": brief, "LT_SPY": spy, "LT_ENGINE": "/eng", "PATH": "/usr/bin:/bin"]
        if verify { env["LT_VERIFY"] = "/s/req.json" }
        p.environment = env
        guard (try? p.run()) != nil else { return (-1, nil) }
        p.waitUntilExit()
        return (p.terminationStatus, try? String(contentsOfFile: mark, encoding: .utf8))
    }
    let good = chain("/usr/bin/true", verify: true)
    expect(good.0 == 0 && good.1 == "/eng -m livetips_m0.prepverify --request /s/req.json\n", "prep agent: chain runs the checker after a good preparation")
    let bad = chain("/usr/bin/false", verify: true)
    expect(bad.0 == 1 && bad.1 == nil, "prep agent: chain keeps the failure and skips the checker")
    expect(chain("/usr/bin/true", verify: false).1 == nil, "prep agent: chain without the checker")
    try? FileManager.default.removeItem(at: tmp)
}

// 0.9.6 (owner, 2026-11-09): one calendar row per meeting; where Start call opens the meeting.
func meetingLaunch096() {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000), t1 = t0.addingTimeInterval(1800)
    expect(CalendarDedup.normalizedLink("https://meet.google.com/abc-defg-hij?authuser=1") == "meet.google.com/abc-defg-hij", "dedup: query dropped")
    expect(CalendarDedup.normalizedLink(" HTTPS://www.Zoom.us/j/123/ ") == "zoom.us/j/123", "dedup: case, www, slash")
    expect(CalendarDedup.normalizedLink("") == nil && CalendarDedup.normalizedLink(nil) == nil, "dedup: no link")
    // two accounts invited to the same meeting (attendees not compared), another meeting at the same time, the same link later
    let g = CalendarDedup.groups(link: ["https://meet.google.com/abc-defg-hij", "https://meet.google.com/abc-defg-hij?authuser=2",
                                        "https://meet.google.com/xyz-xxxx-xyz", "https://meet.google.com/abc-defg-hij", nil, nil, nil],
                                 uid: [nil, "U1", nil, nil, "U2", "u2", "U3"], start: [t0, t0, t0, t1, t0, t0, t0])
    expect(g == [[0, 1], [2], [3], [4, 5], [6]], "dedup: link + start, uid + start without a link: \(g)")
    // a row with a link and a UID joins a row with only the same UID
    expect(CalendarDedup.groups(link: [nil, "https://zoom.us/j/1"], uid: ["U9", "U9"], start: [t0, t0]) == [[0, 1]], "dedup: uid bridges")

    expect(MeetingPlatform.of("https://teams.microsoft.com/l/meetup-join/x") == .teams && MeetingPlatform.of("https://orbit.zoom.us/j/1") == .zoom
           && MeetingPlatform.of("https://meet.google.com/a") == .meet && MeetingPlatform.of(nil) == .other, "launch: platform from the link")
    expect(LaunchWay(id: "chrome:Mike@Orbit.com") == LaunchWay(kind: .chrome, profile: "mike@orbit.com") && LaunchWay(id: "teamsApp")?.kind == .teamsApp
           && LaunchWay(id: "nope") == nil, "launch: way ids round-trip")
    let wa = LaunchWay(kind: .meetApp, profile: "mike@orbit.com", account: "Mike@Acme.com")
    expect(wa.id == "meetApp:mike@orbit.com|mike@acme.com" && LaunchWay(id: wa.id) == wa && wa.joinAs == "mike@acme.com", "launch: join as another account")
    expect(LaunchWay(kind: .chrome, profile: "a@b.c", account: "A@b.c").account == "" && LaunchWay(kind: .chrome, profile: "work").joinAs == "", "launch: own account")

    let state = #"{"profile":{"info_cache":{"Profile 3":{"name":"Work","user_name":"Mike@Orbit.com"},"Default":{"name":"Me","user_name":""}}}}"#
    let pr = ChromeProfile.parse(localState: Data(state.utf8))
    expect(pr.count == 2 && ChromeProfile.dir(for: "mike@orbit.com", in: pr) == "Profile 3" && ChromeProfile.dir(for: "emily@orbit.com", in: pr) == nil
           && ChromeProfile.dir(for: "me", in: pr) == "Default", "launch: Chrome profile folder found by email or name")
    expect(ChromeProfile.accounts(preferences: Data(#"{"account_info":[{"email":"Mike@Orbit.com"},{"email":"mike@acme.com"}]}"#.utf8)) == ["mike@orbit.com", "mike@acme.com"],
           "launch: accounts of a profile")
    let env = LaunchEnvironment(profiles: [ChromeProfile(dir: "Default", name: "Home", email: "mike@gmail.com"),
                                           ChromeProfile(dir: "Profile 1", name: "A", email: "mike@orbit.com", accounts: ["mike@orbit.com", "mike@acme.com"]),
                                           ChromeProfile(dir: "Profile 2", name: "Side", email: "")],
                                meetAppDirs: ["Default", "Profile 1"], teamsApp: true, zoomApp: false)
    expect(env.ways(for: .meet).map(\.id) == ["meetApp:mike@gmail.com", "meetApp:mike@orbit.com", "chrome:mike@gmail.com", "chrome:mike@orbit.com", "chrome:side", "browser"],
           "launch: Meet ways, nobody invited: \(env.ways(for: .meet).map(\.id))")
    let inv = env.ways(for: .meet, invited: ["mike@orbit.com", "mike@beta.com", "Calendar"]).map(\.id)
    expect(inv == ["meetApp:mike@orbit.com", "meetApp:mike@gmail.com|mike@orbit.com", "meetApp:mike@gmail.com|mike@beta.com", "meetApp:mike@orbit.com|mike@beta.com",
                   "chrome:mike@gmail.com", "chrome:mike@orbit.com", "chrome:side", "browser"], "launch: Meet ways for the invited accounts: \(inv)")
    expect(env.ways(for: .teams).map(\.id) == ["teamsApp", "chrome:mike@gmail.com", "chrome:mike@orbit.com", "chrome:side", "browser"], "launch: Teams ways")
    expect(env.ways(for: .zoom).first?.id == "chrome:mike@gmail.com", "launch: no Zoom app, no Zoom way")

    let meet = env.ways(for: .meet)
    var h: [LaunchRecord] = []
    var r = LaunchRanking.rank(meet, history: h, platform: .meet, series: "cal:daily", organizer: "orbit.com")
    expect(!r.auto && r.ways.first?.id == "meetApp:mike@gmail.com", "launch: nothing known asks")
    r = LaunchRanking.rank(meet, history: h, platform: .meet, series: "cal:daily", organizer: "orbit.com", invited: ["mike@orbit.com"])
    expect(!r.auto && r.ways.first?.id == "meetApp:mike@orbit.com", "launch: an invited account first when nothing is known")
    h.append(LaunchRecord(at: t0, platform: .meet, series: "cal:daily", organizer: "orbit.com", way: "chrome:mike@orbit.com", ok: true))
    r = LaunchRanking.rank(meet, history: h, platform: .meet, series: "cal:daily", organizer: "orbit.com")
    expect(r.auto && r.ways.first?.id == "chrome:mike@orbit.com", "launch: what worked for the series opens at once")
    h[0].ok = false
    h.append(LaunchRecord(at: t1, platform: .meet, series: "cal:daily", organizer: "orbit.com", way: "meetApp:mike@gmail.com", ok: true))
    r = LaunchRanking.rank(meet, history: h, platform: .meet, series: "cal:daily", organizer: "orbit.com")
    expect(r.auto && r.ways.first?.id == "meetApp:mike@gmail.com" && r.ways.last?.id == "chrome:mike@orbit.com", "launch: wrong place goes last")
    r = LaunchRanking.rank(meet, history: h, platform: .meet, series: "cal:weekly", organizer: "orbit.com")
    expect(r.auto && r.ways.first?.id == "meetApp:mike@gmail.com", "launch: a new series of the same domain follows it")
    r = LaunchRanking.rank(meet, history: h, platform: .meet, series: "cal:other", organizer: "acme.com")
    expect(!r.auto && r.ways.first?.id == "meetApp:mike@gmail.com", "launch: another domain is offered, not opened")
    r = LaunchRanking.rank(env.ways(for: .teams), history: h, platform: .teams, series: "cal:daily", organizer: "orbit.com")
    expect(!r.auto, "launch: Meet history does not open Teams")
    r = LaunchRanking.rank(meet, history: h, platform: .meet, series: "cal:x", organizer: "", pinned: "browser")
    expect(r.auto && r.ways.first?.id == "browser", "launch: a pinned way wins")

    let ml = "https://meet.google.com/abc-defg-hij"
    expect(MeetingURL.forWay(ml, LaunchWay(kind: .chrome, profile: "mike@orbit.com")) == ml + "?authuser=mike@orbit.com", "launch: Meet authuser")
    expect(MeetingURL.forWay(ml + "?authuser=0", LaunchWay(kind: .meetApp, profile: "x@y.z", account: "a@b.c")) == ml + "?authuser=a@b.c", "launch: authuser replaced")
    expect(MeetingURL.forWay(ml, LaunchWay(kind: .chrome, profile: "side")) == ml, "launch: a profile without an email keeps the link")
    expect(MeetingURL.forWay(ml, LaunchWay(kind: .browser)) == ml, "launch: browser keeps the link")
    // 0.12.0: Drive links open as their account.
    let dl = "https://drive.google.com/drive/folders/1AbcFolderIdXYZ"
    expect(GoogleAccountLink.url(dl, account: "Mike@Orbit.com") == dl + "?authuser=mike@orbit.com", "drive link: authuser")
    expect(GoogleAccountLink.url(dl + "?usp=sharing&authuser=0", account: "mike@orbit.com") == dl + "?usp=sharing&authuser=mike@orbit.com", "drive link: authuser replaced, query kept")
    expect(GoogleAccountLink.url(dl, account: "") == dl, "drive link: no account keeps the link")
    let gp = [ChromeProfile(dir: "Default", name: "Work", email: "emily@example.com", accounts: ["emily@example.com", "mike@orbit.com"]),
              ChromeProfile(dir: "Profile 2", name: "Orbit", email: "mike@orbit.com")]
    expect(GoogleAccountLink.profileDir(account: "MIKE@orbit.com", in: gp) == "Profile 2", "drive link: profile signed in as the account wins")
    expect(GoogleAccountLink.profileDir(account: "emily@example.com", in: gp) == "Default", "drive link: own profile")
    expect(GoogleAccountLink.profileDir(account: "mike@orbit.com", in: [gp[0]]) == "Default", "drive link: a profile that knows the account")
    expect(GoogleAccountLink.profileDir(account: "nobody@example.com", in: gp) == nil, "drive link: no profile -> default browser")
    // 0.12.0 (B8b): what a call sends to the server.
    let cc = CallSync.clientCallID(device: "a1b2c3d4", transcript: "/x/Orbit/calls/2026-11-14 10-00 Weekly sync.md")
    expect(cc == "a1b2c3d4-2026-11-14_10-00_Weekly_sync", "sync: client call id \(cc)")
    expect(CallSync.clientCallID(device: "d", transcript: "/x/Зустріч з Emily.md").allSatisfy { $0.isASCII && !$0.isWhitespace }, "sync: client id ascii")
    expect(CallSync.localSlug("Orbit sales/EU") == "Orbit-sales-EU" && CallSync.localSlug("") == "project", "sync: local slug")
    expect(CallSync.statePath(transcript: "/a/b.md") == "/a/b.sync.json" && CallSync.sheetPath(transcript: "/a/b.md") == "/a/b.sheet.json", "sync: paths")
    let cb = CallSync.callBody(projectID: "p1", title: String(repeating: "t", count: 400), start: Date(timeIntervalSince1970: 1_794_650_400),
                               durationS: -5, meta: ["call_type": "client", "language": "english-long"], appVersion: "0.12.0")
    expect((cb["title"] as? String)?.count == 300 && cb["duration_s"] as? Int == 0 && cb["started_at"] as? String == "2026-11-14T10:00:00Z", "sync: call body limits")
    expect(cb["call_type"] as? String == "client" && cb["language"] as? String == "english-lo" && cb["participants"] == nil, "sync: call body meta, no names")
    expect(CallSync.summaryBody(notes: "  \n ") == nil && (CallSync.summaryBody(notes: "## Summary\nok")?["body_md"] as? String) == "## Summary\nok", "sync: summary")
    var mn = MeetingNotes.Notes(); mn.decisions = [MeetingNotes.Item(t: "00:10", text: "Pilot in December"), MeetingNotes.Item(t: "", text: " ")]
    mn.actions = [MeetingNotes.Item(t: "00:20", text: "Mike sends the proposal")]
    expect(CallSync.decisions(mn).count == 1 && CallSync.tasks(mn).first?["text"] as? String == "Mike sends the proposal", "sync: decisions and tasks")
    expect(CallSync.sheetBody(Data("[1]".utf8)) == nil && CallSync.sheetBody(Data("{\"a\":1}".utf8)) != nil, "sync: sheet is an object")
    var rm = RecordingMeta(); var rp = RecordingMeta.Part(file: "v.mp4", kind: "video", started: Date())
    rp.driveID = "1AbcDEFghijkLMNOPqrs"; rp.driveLink = "https://drive.google.com/file/d/1AbcDEFghijkLMNOPqrs/view"; rp.driveKind = "shared_drive"; rp.bytes = 10
    var bad = rp; bad.driveLink = "https://evil.example/x"
    rm.parts = [rp, bad]
    var tm = DriveTranscriptMeta(); tm.fileID = "1TranscriptIdABCDEFG"; tm.link = "https://drive.google.com/file/d/1TranscriptIdABCDEFG/view"
    let am = CallSync.assets(recording: rm, transcript: tm)
    expect(am.count == 2 && am[0]["drive_kind"] as? String == "shared_drive" && am[1]["kind"] as? String == "transcript_md", "sync: assets, Drive links only")
    var sst = CallSync.State(); let b1 = CallSync.json(["a": 1]), b2 = CallSync.json(["b": 2])
    sst.hashes["summary"] = CallSync.hash(b1)
    expect(CallSync.changed([("summary", b1), ("tasks", b2)], state: sst).map(\.0) == ["tasks"], "sync: only changed parts")
    expect(CallSync.json(["b": 1, "a": 2]) == Data("{\"a\":2,\"b\":1}".utf8), "sync: stable json")
    expect(CallSync.outcome(status: 201) == .ok && CallSync.outcome(status: 410) == .deletedElsewhere, "sync: outcome ok/gone")
    expect(CallSync.outcome(status: 503) == .retryLater("HTTP 503") && CallSync.outcome(status: 403, problem: "plan") == .stop("plan"), "sync: outcome retry/stop")
    let sd = try! JSONDecoder().decode(CallSync.State.self, from: Data("{\"callID\":\"x\"}".utf8))
    expect(sd.callID == "x" && !sd.skip && sd.hashes.isEmpty, "sync: old state decodes")
    let pj = try! JSONDecoder().decode(Project.self, from: Data("{\"name\":\"Orbit\"}".utf8))
    expect(pj.serverSync == false, "sync: projects are off by default")
    // 0.12.1: "nothing" lines are neither decisions nor tasks, on the call page or on the server
    for l in ["Жодних рішень не приймалося.", "Немає.", "None", "**No decisions were made.**", "n/a", "Рішень не ухвалено", ""] {
        expect(MeetingNotes.isNothing(l), "notes: nothing line \(l)")
    }
    for l in ["Mike sends the proposal", "Немає блокерів, реліз у п'ятницю", "No-code tool stays", "None of the old flags stay, we drop them"] {
        expect(!MeetingNotes.isNothing(l), "notes: real line \(l)")
    }
    var none = MeetingNotes.Notes(); none.decisions = [MeetingNotes.Item(text: "Немає.")]; none.actions = [MeetingNotes.Item(text: "None")]
    expect(CallSync.decisions(none).isEmpty && CallSync.tasks(none).isEmpty, "sync: nothing lines are not sent")
    // 0.12.1 (B8): the call page's sync line
    var cs = CallSync.State()
    expect(CallSync.status(nil, syncing: false) == .waiting && CallSync.status(cs, syncing: true) == .syncing, "sync status: waiting, syncing")
    cs.callID = "c1"; cs.syncedAt = Date(timeIntervalSince1970: 100)
    expect(CallSync.status(cs, syncing: false) == .synced(Date(timeIntervalSince1970: 100)), "sync status: synced")
    cs.error = "HTTP 503"
    expect(CallSync.status(cs, syncing: false) == .failed("HTTP 503"), "sync status: failed")
    cs.skip = true
    expect(CallSync.status(cs, syncing: true) == .skipped, "sync status: skipped wins over syncing")
    cs.deletedElsewhere = true
    expect(CallSync.status(cs, syncing: false) == .deletedElsewhere, "sync status: deleted elsewhere first")
    // 0.12.1 (B8): Delete from server
    var ds = CallSync.State(); ds.callID = "c1"; ds.version = "3"; ds.hashes = ["call": "h"]; ds.syncedAt = Date()
    expect(CallSync.canDelete(ds) && !CallSync.canDelete(nil) && !CallSync.canDelete(CallSync.State()), "delete: offered only with a server copy")
    for code in [204, 404, 410] {
        let (after, err) = CallSync.afterDelete(ds, status: code)
        expect(err == nil && after.removed && after.callID.isEmpty && after.hashes.isEmpty && !CallSync.canDelete(after), "delete: \(code) removes")
        expect(CallSync.status(after, syncing: false) == .removed, "delete: status removed")
    }
    let (kept, why) = CallSync.afterDelete(ds, status: 503)
    expect(kept == ds && why == "HTTP 503", "delete: a server error keeps the copy")
    let rd = try! JSONDecoder().decode(CallSync.State.self, from: Data("{\"callID\":\"x\"}".utf8))
    expect(!rd.removed, "delete: old state is not removed")
    let q = Data("{\"status\":402,\"detail\":\"storage\",\"quota\":\"storage_mb\",\"limit\":500,\"used_mb\":499.9}".utf8)
    expect(PacenoteServer.quota(q, status: 402) == PacenoteServer.Quota(name: "storage_mb", limit: 500), "quota: 402 names storage_mb")
    expect(PacenoteServer.quota(q, status: 403) == nil && PacenoteServer.quota(Data("{}".utf8), status: 402) == nil, "quota: only a named 402")
    expect(MeetingURL.forWay("https://teams.microsoft.com/l/meetup-join/x", LaunchWay(kind: .chrome, profile: "a@b.c"))
           == "https://teams.microsoft.com/l/meetup-join/x?msLaunch=false&suppressPrompt=true", "launch: Teams stays on the web")
    expect(MeetingURL.zoomApp("https://orbit.zoom.us/j/123456789?pwd=abc") == "zoommtg://zoom.us/join?action=join&confno=123456789&pwd=abc", "launch: Zoom app link")
    expect(MeetingURL.zoomApp("https://meet.google.com/x") == nil, "launch: not Zoom")
}

// 0.9.7 (capacity check, 11.11): the deck is cut into slides in the show order, hidden slides out, notes read,
// a text plan cut on one heading level only.
func deckCapacity097() {
    let files = ["ppt/slides/slide1.xml", "ppt/slides/slide2.xml", "ppt/slides/slide3.xml", "ppt/slides/slide10.xml"]
    let pres = "<p:presentation><p:sldIdLst><p:sldId id=\"256\" r:id=\"rId4\"/><p:sldId id=\"257\" r:id=\"rId2\"/><p:sldId id=\"258\" r:id=\"rId3\"/><p:sldId id=\"259\" r:id=\"rId5\"/></p:sldIdLst></p:presentation>"
    let rels = "<Relationships><Relationship Id=\"rId2\" Type=\"x/slide\" Target=\"slides/slide1.xml\"/><Relationship Id=\"rId3\" Type=\"x/slide\" Target=\"slides/slide2.xml\"/><Relationship Id=\"rId4\" Type=\"x/slide\" Target=\"slides/slide10.xml\"/><Relationship Id=\"rId5\" Type=\"x/slide\" Target=\"/ppt/slides/slide3.xml\"/></Relationships>"
    expect(PptxOrder.slideFiles(files: files, presentation: pres, rels: rels) == ["ppt/slides/slide10.xml", "ppt/slides/slide1.xml", "ppt/slides/slide2.xml", "ppt/slides/slide3.xml"], "deck: show order from presentation.xml")
    expect(PptxOrder.slideFiles(files: files, presentation: "", rels: "") == ["ppt/slides/slide1.xml", "ppt/slides/slide2.xml", "ppt/slides/slide3.xml", "ppt/slides/slide10.xml"], "deck: file numbers when presentation.xml is missing")
    expect(PptxOrder.hidden("<p:sld xmlns:p=\"x\" show=\"0\"><p:cSld/>"), "deck: hidden slide")
    expect(!PptxOrder.hidden("<p:sld xmlns:p=\"x\"><p:cSld/>"), "deck: shown slide")
    let nrels = "<Relationships><Relationship Id=\"rId1\" Type=\"http://x/slideLayout\" Target=\"../slideLayouts/slideLayout2.xml\"/><Relationship Id=\"rId2\" Type=\"http://x/notesSlide\" Target=\"../notesSlides/notesSlide7.xml\"/></Relationships>"
    expect(PptxOrder.notesTarget(nrels) == "../notesSlides/notesSlide7.xml", "deck: notes page of a slide")
    let notes = "<p:notes><p:sp><p:nvSpPr><p:nvPr><p:ph type=\"sldImg\"/></p:nvPr></p:nvSpPr></p:sp><p:sp><p:nvSpPr><p:nvPr><p:ph type=\"body\" idx=\"1\"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>Say the 216 calls</a:t></a:r></a:p><a:p><a:r><a:t>Mike &amp; Emily&#39;s team</a:t></a:r></a:p></p:txBody></p:sp><p:sp><p:nvSpPr><p:nvPr><p:ph type=\"sldNum\"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>21</a:t></a:r></a:p></p:txBody></p:sp></p:notes>"
    expect(PptxOrder.notesText(notes) == "Say the 216 calls\nMike & Emily's team", "deck: notes text without the slide number")
    // A text plan: "# Talk" title, "## Slide" headings, "### subheadings" inside a slide stay text.
    let plan = "# Our talk\n\n## Why\nFive users.\n### Detail\nTwo weeks.\n\n## Plan\nMonday.\n### Risks\nNone."
    let b = PptxOrder.outlineBlocks(plan)
    expect(b.count == 2 && b[0].title == "Why" && b[0].text == "Five users.\nDetail\nTwo weeks." && b[1].title == "Plan", "deck: one heading level starts a slide")
    let words = PptxOrder.outlineBlocks("## Intro\nSlide 1: Hello\nHi all.\n### Note\nSlide 2: Numbers\n216 calls.")
    expect(words.count == 2 && words[0].title == "Hello" && words[1].title == "Numbers", "deck: Slide N lines win over headings")
    let flat = PptxOrder.outlineBlocks("# A\none\n# B\ntwo\n# C\nthree")
    expect(flat.count == 3, "deck: a single level of headings")
    let blank = PptxOrder.outlineBlocks("First slide\nline\n\nSecond slide\nline")
    expect(blank.count == 2, "deck: blank lines without markers")
    let dashes = PptxOrder.outlineBlocks("One\ntext\n---\nTwo\ntext")
    expect(dashes.count == 2 && dashes[1].title == "Two", "deck: --- starts a slide")
}

// 0.10.0 (Meeting Sheet, phase 1): the shared fixtures of the sidecar (spikes/m0/tests/fixtures/sheet) decode into the
// models, survive a round trip, keep unknown enum values, and give the readiness badge the Python engine stored.
func meetingSheet0100() {
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("spikes/m0/tests/fixtures/sheet")
    let expected: [(String, ReadinessState, Int)] = [("sales-intro-lumenfield", .almost, 3), ("client-sync-orbit", .ready, 0), ("standup-orbit", .ready, 0)]
    for (name, state, gaps) in expected {
        let path = dir.appendingPathComponent(name + ".sheet.json").path
        guard let s = try? MeetingSheetIO.load(path) else { expect(false, "sheet fixture \(name)"); continue }
        expect(s.schema == MeetingSheetIO.schema, "sheet \(name): schema")
        expect(s.readiness?.state == state && s.readinessBadge.gaps == gaps, "sheet \(name): readiness \(s.readiness?.state.rawValue ?? "-")")
        expect(s.blocks.allSatisfy { $0.type.isKnown } && s.sources.allSatisfy { $0.type.isKnown && $0.access.isKnown }, "sheet \(name): known values")
        guard let data = try? MeetingSheetIO.encode(s), let back = try? MeetingSheetIO.decode(data) else { expect(false, "sheet \(name): encode"); continue }
        expect(back == s, "sheet \(name): round trip")
        // The file's keys are snake_case and every key of the fixture survives the round trip.
        if let a = try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? NSDictionary,
           let b = try? JSONSerialization.jsonObject(with: data) as? NSDictionary {
            expect(a == b, "sheet \(name): same JSON after a round trip")
        } else { expect(false, "sheet \(name): JSON") }
    }
    if let s = try? MeetingSheetIO.load(dir.appendingPathComponent("sales-intro-lumenfield.sheet.json").path) {
        expect(s.title == "Meeting Sheet: Emily Parker" && s.mode == .expert && s.meetingRef.place == "https://meet.example.com/lumenfield-intro", "sheet: header fields")
        expect(s.block(.qualification)?.method == "bant", "sheet: qualification method")
        let budget = s.fact(id: "f-q-budget")
        expect(budget?.status == .notFound && budget?.value?.level == .unknown && budget?.value?.key == "budget", "sheet: budget unknown")
        expect(s.fact(id: "f-size-site")?.conflictWith == ["f-size-li"] && s.fact(id: "f-size-site")?.status == .conflict, "sheet: team size conflict")
        expect(s.fact(id: "q-reports")?.isProtected == true && s.fact(id: "f-industry")?.isProtected == false, "sheet: protected facts")
        expect(s.source(id: "s4")?.why == ["same industry", "matches the call context"] && s.source(id: "s4")?.auto == true, "sheet: source why")
        expect(s.readinessBadge.label == "Almost" && s.readinessBadge.blockers == 0 && s.readiness?.gaps?.first?.action == .addQuestion, "sheet: badge and first gap")
        expect(!s.shownBlocks.contains { $0.type == .techStack } && s.shownBlocks.contains { $0.type == .contact }, "sheet: only if data")
        // 0.10.2 (Q, v4): a block with only "not found" placeholders is not shown; an edited one and qualification are
        var t = s
        if let i = t.blocks.firstIndex(where: { $0.type == .contact }), !t.blocks[i].facts.isEmpty {
            for j in t.blocks[i].facts.indices { t.blocks[i].facts[j].status = .notFound }
            t.blocks[i].editedByUser = false
            expect(t.blocks[i].nothingFound && !t.shownBlocks.contains { $0.type == .contact }, "sheet: nothing found is not shown")
            t.blocks[i].editedByUser = true
            expect(!t.blocks[i].nothingFound && t.shownBlocks.contains { $0.type == .contact }, "sheet: an edited block stays")
        } else { expect(false, "sheet: contact facts in the fixture") }
        if let i = t.blocks.firstIndex(where: { $0.type == .qualification }) {
            for j in t.blocks[i].facts.indices { t.blocks[i].facts[j].status = .notFound }
            expect(!t.blocks[i].nothingFound, "sheet: qualification unknowns stay shown")
        }
    } else { expect(false, "sales fixture") }
    // Unknown enum values decode, keep their text and encode back unchanged.
    let future = """
    {"schema":"pacenote.sheet/1","id":"x","title":"Meeting Sheet: Orbit","meeting_ref":{"start":"2026-11-13T10:00:00Z"},
     "mode":"turbo","preset":"blank","language":"en","sources":[{"id":"s1","n":1,"type":"hologram","title":"t","access":"maybe","used":"full"}],
     "blocks":[{"id":"b1","type":"weather","title":"W","visible":true,"only_if_data":false,"order":0,"edited_by_user":false,
       "facts":[{"id":"f1","text":"t","source_ids":["s1"],"status":"rumour","origin":"model","value":{"level":"purple"}}]}],
     "readiness":{"state":"perfect","gaps":[{"id":"g","rule":"r","text":"t","action":"call_mom","severity":"info"}]}}
    """
    if let s = try? MeetingSheetIO.decode(Data(future.utf8)) {
        expect(!s.mode.isKnown && s.mode.rawValue == "turbo" && !s.blocks[0].type.isKnown && !s.sources[0].type.isKnown, "sheet: unknown values decode")
        expect(s.blocks[0].facts[0].status.rawValue == "rumour" && s.blocks[0].facts[0].value?.level?.isKnown == false, "sheet: unknown fact values")
        expect(s.readinessBadge.state == nil && s.readinessBadge.label == "Not checked" && s.readiness?.gaps?[0].action.rawValue == "call_mom", "sheet: unknown readiness")
        let text = (try? MeetingSheetIO.encode(s)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        expect(text.contains("\"status\" : \"rumour\"") && text.contains("\"mode\" : \"turbo\"") && !text.contains("rawValue"), "sheet: unknown values encode back")
    } else { expect(false, "sheet: tolerant decoding") }
    expect(MeetingSheetIO.path(liveFolder: "/p/live", base: "prep-2026-11-13-1600-lumenfield") == "/p/live/prep-2026-11-13-1600-lumenfield.sheet.json", "sheet: file name")
    expect((try? MeetingSheetIO.decode(Data("{\"schema\":\"pacenote.sheet/1\"}".utf8))) == nil, "sheet: required fields")
}

// 0.10.0 (Meeting Sheet, phase 6): the Pacenote browser's pure logic: page kinds, the capture plan, the pause, the
// file names under <project>/live/sources, and the contact scrubber (emails and phones are never collected).
func browserCapture0100() {
    let prof = URL(string: "https://www.linkedin.com/in/emily-parker-lf/?trk=x")!
    expect(BrowserURL.kind(prof) == .linkedinProfile, "browser: profile kind")
    expect(BrowserURL.kind(URL(string: "https://www.linkedin.com/in/emily-parker-lf/details/skills/")!) == .linkedinDetail, "browser: detail kind")
    expect(BrowserURL.kind(URL(string: "https://www.linkedin.com/company/lumenfield/")!) == .linkedinCompany, "browser: company kind")
    expect(BrowserURL.kind(URL(string: "https://lumenfield.example/about")!) == .web, "browser: web kind")
    expect(!BrowserURL.isLinkedIn(URL(string: "https://linkedin.com.example/in/x")!), "browser: look-alike host")
    expect(BrowserURL.fromInput("lumenfield.example/about")?.absoluteString == "https://lumenfield.example/about", "browser: address without scheme")
    expect(BrowserURL.fromInput("javascript:alert(1)") == nil && BrowserURL.fromInput("file:///etc/hosts") == nil && BrowserURL.fromInput("two words") == nil, "browser: refused addresses")
    let plan = CapturePlan.make(for: prof, sections: ["skills", "experience", "unknown"])
    expect(plan.steps.map(\.url.absoluteString) == ["https://www.linkedin.com/in/emily-parker-lf/",
        "https://www.linkedin.com/in/emily-parker-lf/details/experience/", "https://www.linkedin.com/in/emily-parker-lf/details/skills/"], "browser: linkedin plan order")
    expect(plan.offersSections && plan.detailSections == ["experience", "skills"], "browser: plan sections")
    expect(plan.summary.contains("2 detail pages (Experience, Skills)"), "browser: plan summary")
    let full = CapturePlan.make(for: prof)
    expect(full.steps.count == 6, "browser: profile + 5 detail pages")
    let site = CapturePlan.make(for: URL(string: "https://lumenfield.example/team")!)
    expect(site.steps.count == 1 && !site.offersSections && site.steps[0].section == nil, "browser: one page for a site")
    let detail = CapturePlan.make(for: URL(string: "https://www.linkedin.com/in/emily-parker-lf/details/skills/")!)
    expect(detail.steps.count == 1, "browser: a detail page alone")
    expect(CapturePlan.pause(0) == 3 && CapturePlan.pause(1) == 6 && CapturePlan.pause(7) == 6 && CapturePlan.pause(0.5) == 4.5, "browser: pause 3-6 s")
    let d = Date(timeIntervalSince1970: 1_794_445_323)       // 2026-11-12 01:02:03 UTC
    expect(CaptureFiles.base(for: prof, at: d) == "emily-parker-lf-20261112-010203", "browser: profile file name \(CaptureFiles.base(for: prof, at: d))")
    expect(BrowserURL.slug(URL(string: "https://www.lumenfield.example/about/team")!) == "lumenfield-example-about-team", "browser: site slug")
    let s = ContactScrubber.scrub("Mail emily.parker@lumenfield.example, call +1 512 555 0142 or (512) 555-0199. 2018 - 2023 · 5 yrs. 50,000+ users.")
    expect(s.removed == 3 && !s.text.contains("@") && !s.text.contains("555"), "browser: contacts removed")
    expect(s.text.contains("2018 - 2023") && s.text.contains("50,000+ users"), "browser: dates and numbers kept")
    let h = ContactScrubber.scrubHTML("<a href=\"https://x.example/u/123456789012\">Call 512 555 0142</a>")
    expect(h.removed == 1 && h.html.contains("123456789012") && h.html.contains("[phone removed]"), "browser: html attributes untouched")
    let parts = [CapturedPart(url: "https://www.linkedin.com/in/emily-parker-lf/", title: "Emily Parker | LinkedIn",
                              html: "<main><h1>Emily Parker</h1><p>emily@lumenfield.example</p></main>", text: "Emily Parker\nemily@lumenfield.example", section: nil),
                 CapturedPart(url: "https://www.linkedin.com/in/emily-parker-lf/details/skills/", title: "Skills | Emily Parker | LinkedIn",
                              html: "<main><ul><li>Python</li></ul></main>", text: "Python", section: "skills")]
    let r = CaptureFiles.assemble(start: prof, kind: .linkedinProfile, parts: parts, signedIn: true, at: d,
                                  folder: CaptureFiles.folder(live: URL(fileURLWithPath: "/p/live")))
    expect(r.page.htmlPath == "/p/live/sources/emily-parker-lf-20261112-010203.html" && r.page.textPath.hasSuffix(".txt"), "browser: saved under live/sources")
    expect(r.page.pages.count == 2 && r.page.pages[1].section == "skills" && r.page.contactsRemoved == 1, "browser: parts")
    expect(!r.htmlDoc.contains("@lumenfield") && !r.textDoc.contains("@lumenfield"), "browser: no email in files")
    expect(r.htmlDoc.contains("data-pacenote-page=\"https://www.linkedin.com/in/emily-parker-lf/details/skills/\"")
           && r.htmlDoc.contains("name=\"pacenote:session\" content=\"signed_in\"") && r.page.capturedAt == "2026-11-12T01:02:03Z", "browser: document")
    if let data = try? JSONEncoder().encode(r.page), let back = try? JSONDecoder().decode(CapturedPage.self, from: data),
       let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        expect(back == r.page && o["captured_at"] != nil && o["html_path"] != nil, "browser: captured page JSON")
    } else { expect(false, "browser: captured page JSON") }
    expect(r.page.sidecarItem["html"] == r.page.htmlPath && r.page.sidecarItem["url"] == r.page.url, "browser: sidecar item")
}

callRecording()
meetingNotes0952()
prepAgent096()
meetingLaunch096()
/// 0.10.0 (Meeting Sheet, phases 4-5, ui): Quick / Expert default, the Refresh banner counts, edits on the sheet
/// (inline edit, block menu, conflict, gap quick actions) and the export rendering (footnotes, links, colleague).
func meetingSheetUI0100() {
    let rules = SheetModeRule.defaults
    func mode(_ p: String, _ pm: String = "quick", earlier: Bool = false, domains: [String] = [], known: [String] = [], theirs: Int = 1) -> String {
        SheetModeDecider.decide(rules: rules, preset: p, presetMode: pm, earlierSheet: earlier, theirDomains: domains, knownDomains: known, theirCount: theirs).rawValue
    }
    expect(mode("standup", "quick", domains: ["new.example"]) == "quick", "mode: stand-up is quick first")
    expect(mode("sales_intro", "expert", earlier: true) == "quick", "mode: a series with an earlier sheet is quick")
    expect(mode("sales_intro", "expert") == "expert", "mode: sales intro expert")
    expect(mode("upsell", "quick", domains: ["lumenfield.example"]) == "expert", "mode: new external domain expert")
    expect(mode("upsell", "quick", domains: ["lumenfield.example"], known: ["Lumenfield.example"]) == "quick", "mode: known domain falls to preset")
    expect(mode("blank", "expert", theirs: 0) == "quick", "mode: internal quick")
    expect(mode("blank", "expert") == "expert", "mode: no rule, the preset's mode")
    var off = rules; off[0].off = true
    expect(SheetModeDecider.decide(rules: off, preset: "standup", presetMode: "expert", earlierSheet: false, theirDomains: [], knownDomains: [], theirCount: 1) == .expert, "mode: a rule turned off")
    expect(SheetModeDecider.decide(rules: rules, preset: "my-orbit", presetBase: "client_sync", presetMode: "expert", earlierSheet: false, theirDomains: [], knownDomains: [], theirCount: 1) == .quick, "mode: user preset follows its base")

    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("spikes/m0/tests/fixtures/sheet")
    guard let base = try? MeetingSheetIO.load(dir.appendingPathComponent("sales-intro-lumenfield.sheet.json").path) else { expect(false, "ui: fixture"); return }
    expect(SheetDiffCounts.of(base).isEmpty, "diff: none on a fresh sheet")
    var s = base
    // inline edit
    expect(SheetEdit.editFact(&s, factID: "f-overview", text: "  Lumenfield wants reporting automation.  ", now: "2026-11-12T10:00:00+02:00"), "edit: applied")
    expect(s.fact(id: "f-overview")?.status == .edited && s.fact(id: "f-overview")?.text == "Lumenfield wants reporting automation." && s.fact(id: "f-overview")?.isProtected == true, "edit: fact edited and protected")
    expect(s.blocks.first { $0.type == .overview }?.editedByUser == true, "edit: block marked edited_by_user")
    expect(!SheetEdit.editFact(&s, factID: "f-overview", text: "   ", now: "x"), "edit: empty text is not saved")
    expect(!SheetEdit.editFact(&s, factID: "nope", text: "x", now: "x"), "edit: unknown fact")
    // diff banner
    var d = s
    if let bi = d.blocks.firstIndex(where: { $0.type == .company }) {
        d.blocks[bi].facts[0].diff = .new
        if d.blocks[bi].facts.count > 1 { d.blocks[bi].facts[1].diff = .gone }
    }
    let c = SheetDiffCounts.of(d)
    expect(c.new == 1 && c.gone == 1 && c.changed == 0 && c.keptEdits == 2, "diff: counts from marks \(c)")
    // 0.10.0 (Meeting Sheet, polish): no edits by the person -> no "Your edits (N) are kept", even with origin user facts that came new.
    do {
        var z = base
        for bi in z.blocks.indices { for fi in z.blocks[bi].facts.indices where z.blocks[bi].facts[fi].origin == .user { z.blocks[bi].facts[fi].origin = .model } }
        if let bi = z.blocks.firstIndex(where: { !$0.facts.isEmpty }) {
            z.blocks[bi].facts[0].origin = .user
            z.blocks[bi].facts[0].diff = .new
            z.blocks[bi].editedByUser = false
        }
        for i in z.blocks.indices { z.blocks[i].editedByUser = false }
        let zc = SheetDiffCounts.of(z)
        expect(zc.keptEdits == 0 && zc.new >= 1, "diff: a new user-origin fact is not a kept edit \(zc)")
        if let bi = z.blocks.firstIndex(where: { $0.facts.count > 1 }) { z.blocks[bi].facts[1].status = .edited }
        expect(SheetDiffCounts.of(z).keptEdits == 1, "diff: an edited fact without a diff mark is a kept edit")
        if let bi = z.blocks.firstIndex(where: { $0.facts.count > 1 }) { z.blocks[bi].editedByUser = true }
        expect(SheetDiffCounts.keptEdits(z) >= 1, "diff: an edited block counts")
    }
    // 0.10.0 (Meeting Sheet, polish): "Budget: Not found" + the chip, the text is not repeated.
    if let nf = base.blocks.flatMap(\.facts).first(where: { $0.status == .notFound }) {
        expect(nf.shownText.isEmpty, "not found: placeholder text hidden")
        var real = nf; real.text = "No budget in the notes"
        expect(real.shownText == "No budget in the notes", "not found: a real explanation stays")
        var found = nf; found.status = .found
        expect(found.shownText == nf.text, "not found: other statuses keep their text")
    } else { expect(false, "not found: fixture has a not_found fact") }
    // 0.10.0 (Meeting Sheet, polish): "On this sheet" counts per block (a conflict pair is one)
    if let co = base.block(.company), let q = base.block(.qualification) {
        expect(SheetBlockCount.of(co) == SheetBlockCount(facts: 2, notFound: 0, conflicts: 1), "nav: company 2 facts, 1 conflict \(SheetBlockCount.of(co))")
        expect(SheetBlockCount.of(q).notFound == 1 && SheetBlockCount.of(q).facts == 4, "nav: qualification 1 not found of 4")
        let st = Dictionary(uniqueKeysWithValues: SheetBlockCount.statuses(base).map { ($0.0.rawValue, $0.1) })
        expect(st["conflict"] == 1 && st["not_found"] == 1, "nav: legend counts \(st)")
    } else { expect(false, "nav: fixture blocks") }
    expect(SheetFact.isPlaceholder(" not found. ") && SheetFact.isPlaceholder("Не знайдено") && !SheetFact.isPlaceholder("20K"), "not found: placeholder list")
    d.diff = try? JSONDecoder().decode(SheetDiff.self, from: Data(#"{"new":["a","b"],"changed":["c"],"gone":[]}"#.utf8))
    expect(SheetDiffCounts.of(d) == SheetDiffCounts(new: 2, changed: 1, gone: 0, keptEdits: c.keptEdits), "diff: counts from sheet.diff")
    let before = d.blocks.flatMap(\.facts).count
    SheetEdit.acceptDiff(&d)
    expect(d.diff == nil && d.blocks.flatMap(\.facts).allSatisfy { $0.diff == nil } && d.blocks.flatMap(\.facts).count == before - 1, "diff: accept all clears and drops gone")
    // block menu
    var b = base
    let shown = b.shownBlocks.map(\.id)
    let second = shown[1]
    expect(SheetEdit.block(&b, id: second, .moveUp) && b.shownBlocks.first?.id == second, "block: move up")
    expect(SheetEdit.block(&b, id: second, .moveDown) && b.shownBlocks.map(\.id) == shown, "block: move down back")
    expect(!SheetEdit.block(&b, id: shown[0], .moveUp), "block: first cannot go up")
    expect(SheetEdit.block(&b, id: second, .hide) && !b.shownBlocks.contains { $0.id == second }, "block: hide")
    expect(SheetEdit.block(&b, id: second, .show) && b.shownBlocks.contains { $0.id == second }, "block: show")
    expect(SheetEdit.block(&b, id: second, .delete) && !b.blocks.contains { $0.id == second }, "block: delete")
    // conflict
    var k = base
    expect(SheetEdit.settle(&k, factID: "f-size-site", .use("f-size-li"), now: "n") && k.fact(id: "f-size-site") == nil && k.fact(id: "f-size-li")?.status == .edited, "conflict: use B")
    var k2 = base
    let qBefore = k2.block(.questions)?.facts.count ?? 0
    expect(SheetEdit.settle(&k2, factID: "f-size-site", .keepBoth, now: "n", question: "120 or 80?") && k2.fact(id: "f-size-site")?.status == .needsCheck
           && k2.fact(id: "f-size-li")?.conflictWith == nil && (k2.block(.questions)?.facts.count ?? 0) == qBefore + 1, "conflict: keep both adds a question")
    expect(!SheetEdit.settle(&k2, factID: "f-size-site", .use("f-industry"), now: "n"), "conflict: only a value of the group")
    // gaps
    var g = base
    expect(SheetEdit.closeGap(&g, gapID: "gap-no_stale-f-funding", action: .dropCheck, now: "n") && g.readiness?.dropped == ["gap-no_stale-f-funding"] && g.readiness?.gaps?.count == 2, "gap: drop check")
    expect(SheetEdit.closeGap(&g, gapID: "gap-no_open_conflicts-f-size-site", action: .markChecked, now: "n") && g.fact(id: "f-size-site")?.status == .edited, "gap: mark checked")
    expect(SheetEdit.closeGap(&g, gapID: "gap-qualification_complete-budget", action: .addQuestion, now: "n", question: "Budget?") && g.readiness?.state == .ready
           && g.block(.questions)?.facts.contains { $0.text == "Budget?" && $0.origin == .user } == true, "gap: add question, then ready")
    expect(SheetEdit.setOwner(&g, factID: "f-overview", owner: "Mike Carter") && g.fact(id: "f-overview")?.value?.owner == "Mike Carter", "gap: owner")
    expect(SheetEdit.addFact(&g, blockType: .agenda, text: "Kick-off", now: "n") != nil && g.block(.agenda)?.facts.first?.status == .edited, "fact: added into a new block")
    // export
    let md = SheetExport.markdown(base)
    expect(md.hasPrefix("# Meeting Sheet: Emily Parker") && md.contains("## About the company") && md.contains("[^1]") && md.contains("[^1]: Lumenfield - About https://lumenfield.example/about"), "export: markdown footnotes")
    expect(md.contains("(sources disagree)") && md.contains("(not found)"), "export: statuses in words")
    let inline = SheetExport.markdown(base, SheetExportOptions(sources: .inline))
    expect(inline.contains("([1](https://lumenfield.example/about))") && !inline.contains("[^"), "export: inline links")
    let col = SheetExport.markdown(base, SheetExportOptions(colleague: true))
    expect(!col.contains("## My focus") && !col.contains("## Red lines") && col.contains("## Overview"), "export: colleague leaves internal blocks out")
    let pick = SheetExport.blocks(base, SheetExportOptions(blocks: ["b-overview"]))
    expect(pick.map(\.id) == ["b-overview"], "export: chosen blocks")
    let html = SheetExport.html(base)
    expect(html.contains("<sup>1</sup>") && html.contains("<h2>Sources</h2>") && !html.contains("\u{2014}") && !md.contains("\u{2014}"), "export: html, no long dash")
    expect(SheetExport.esc("<a & \"b\">") == "&lt;a &amp; &quot;b&quot;&gt;", "export: escaping")
}

// 0.10.0 (Meeting Sheet, phase 3, pipeline): which calls build a sheet, the preset without the wizard, progress lines
func sheetPipeline0100() {
    expect(SheetPipeline.builds(callType: "auto") && SheetPipeline.builds(callType: "presentation") && !SheetPipeline.builds(callType: "transcript"), "sheet: every type but Transcript")
    expect(SheetPipeline.preset(callType: "interview", sales: false, title: "x", earlier: false) == "interview", "sheet preset: interview")
    expect(SheetPipeline.preset(callType: "presentation", sales: true, title: "x", earlier: false) == "internal_presentation", "sheet preset: presentation")
    expect(SheetPipeline.preset(callType: "auto", sales: false, title: "Orbit daily stand-up", earlier: true) == "standup", "sheet preset: stand-up by title")
    expect(SheetPipeline.preset(callType: "auto", sales: true, title: "Lumenfield intro", earlier: false) == "sales_intro", "sheet preset: sales intro")
    expect(SheetPipeline.preset(callType: "auto", sales: true, title: "Lumenfield intro", earlier: true) == "repeat_call", "sheet preset: sales, a series")
    expect(SheetPipeline.preset(callType: "auto", sales: false, title: "Orbit weekly sync", earlier: false) == "client_sync", "sheet preset: default")
    expect(SheetPipeline.preset(callType: "auto", sales: false, title: "x", earlier: false, seriesChoice: "upsell") == "upsell", "sheet preset: the series' choice wins")
    let p = SheetPipeline.parse("{\"progress\": 0.4, \"stage\": \"model\", \"pass\": 2, \"passes\": 3}")
    expect(p?.progress == 0.4 && p?.stage == "model" && p?.pass == 2 && p?.passes == 3 && p?.done == false, "sheet line: progress")
    let s = SheetPipeline.parse("{\"progress\": 0.05, \"stage\": \"sources\", \"source_id\": \"s2\", \"access\": \"denied\"}")
    expect(s?.sourceID == "s2" && s?.access == "denied", "sheet line: a source")
    let d = SheetPipeline.parse("{\"done\": true, \"sheet\": \"/x/prep-a.sheet.json\", \"readiness\": \"almost\"}")
    expect(d?.done == true && d?.sheet == "/x/prep-a.sheet.json" && d?.readiness == "almost", "sheet line: done")
    expect(SheetPipeline.parse("{\"error\": \"too_much\"}")?.error == "too_much" && SheetPipeline.parse("not json") == nil, "sheet line: error, garbage")
}

/// 0.10.0 (Meeting Sheet, round 2, fixer): Prepare again during a call refreshes the sheet, a failed refresh keeps
/// the previous sheet, Retry / Skip lines and the control file.
func sheetFixer0100() {
    expect(SheetPipeline.isRefresh(sheetExists: true, refreshAsked: false, duringCall: true), "sheet r2: during the call a sheet is refreshed, not rebuilt")
    expect(SheetPipeline.isRefresh(sheetExists: true, refreshAsked: true, duringCall: false), "sheet r2: Refresh refreshes")
    expect(!SheetPipeline.isRefresh(sheetExists: false, refreshAsked: true, duringCall: true), "sheet r2: no sheet yet = a build")
    expect(!SheetPipeline.isRefresh(sheetExists: true, refreshAsked: false, duringCall: false), "sheet r2: Prepare before the call builds again")
    expect(SheetPipeline.liveOutcome(ok: false, duringCall: true) == .keepPrevious, "sheet r2: a failed refresh during the call keeps the previous sheet")
    expect(SheetPipeline.liveOutcome(ok: true, duringCall: true) == .adopt && SheetPipeline.liveOutcome(ok: false, duringCall: false) == .none, "sheet r2: adopt / none")
    let sk = SheetPipeline.parse("{\"stage\": \"sources\", \"source_id\": \"s2\", \"skipped\": true}")
    expect(sk?.skipped == true && sk?.sourceID == "s2" && sk?.progress == nil, "sheet r2: a skipped source line")
    expect(SheetPipeline.parse("{\"progress\": 0.1, \"stage\": \"sources\", \"waiting\": [\"s3\"], \"wait_s\": 30}")?.waiting == ["s3"], "sheet r2: waiting for Retry / Skip")
    let a = SheetPipeline.controlActions([], add: "skip", source: "s2")
    expect(SheetPipeline.controlActions(a, add: "retry", source: "s3") == [["action": "skip", "source_id": "s2"], ["action": "retry", "source_id": "s3"]], "sheet r2: control actions append")
    expect(SheetPipeline.controlActions(a, add: "delete", source: "s3") == a && SheetPipeline.controlActions(a, add: "skip", source: "") == a, "sheet r2: control ignores the unknown")
    // newer wins: the older value is linked to the newer one ("was X") and never exported
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("spikes/m0/tests/fixtures/sheet")
    guard var s = try? MeetingSheetIO.load(dir.appendingPathComponent("sales-intro-lumenfield.sheet.json").path) else { expect(false, "sheet r2: fixture"); return }
    for bi in s.blocks.indices {
        for fi in s.blocks[bi].facts.indices where s.blocks[bi].facts[fi].id == "f-size-site" {
            s.blocks[bi].facts[fi].status = .stale
            s.blocks[bi].facts[fi].conflictWith = ["f-size-li"]
            s.blocks[bi].facts[fi].supersededBy = "f-size-li"
        }
        for fi in s.blocks[bi].facts.indices where s.blocks[bi].facts[fi].id == "f-size-li" {
            s.blocks[bi].facts[fi].status = .found
            s.blocks[bi].facts[fi].conflictWith = nil
        }
    }
    expect(s.replaced(by: "f-size-li").map(\.id) == ["f-size-site"] && s.replaced(by: "f-size-site").isEmpty, "sheet r2: replaced(by:) finds the older value")
    let oldText = s.fact(id: "f-size-site")?.text ?? "\u{0}"
    expect(!SheetExport.markdown(s).contains(oldText), "sheet r2: the replaced value is not exported")
    if let d = try? JSONEncoder().encode(s), let back = try? JSONDecoder().decode(MeetingSheet.self, from: d) {
        expect(back.fact(id: "f-size-site")?.supersededBy == "f-size-li", "sheet r2: superseded_by survives a save")
    } else { expect(false, "sheet r2: encode") }
}

// 0.10.0 (Meeting Sheet, hardening): route question rules, the job after Not now, notifications, the wizard's person
// line, reminders kept between starts, and a save that keeps the fields this app does not know.
func sheetHardening0100() {
    expect(SheetPipeline.asksRouteSwitch(interactive: true, callLive: false), "hardening: a person at Prepare is asked (inline)")
    expect(!SheetPipeline.asksRouteSwitch(interactive: true, callLive: true), "hardening: never asked during a live call")
    expect(!SheetPipeline.asksRouteSwitch(interactive: false, callLive: false), "hardening: queued without a person: switch and report")
    expect(SheetPipeline.followState(runningThis: false, pendingThis: false, sawRunning: false, sawPending: true) == .gaveUp, "hardening: Not now ends the job (no stuck 0%)")
    expect(SheetPipeline.followState(runningThis: false, pendingThis: true, sawRunning: false, sawPending: true) == .waitingForChoice, "hardening: question open = waiting")
    expect(SheetPipeline.followState(runningThis: false, pendingThis: false, sawRunning: true, sawPending: true) == .finished, "hardening: a build that ran finishes")
    expect(SheetPipeline.followState(runningThis: false, pendingThis: false, sawRunning: false, sawPending: false) == .queued, "hardening: not started yet = queued")
    let u = "6F9619FF-8B86-D011-B42D-00C04FC964FF"
    expect(SheetPipeline.notificationTarget("pn-sheet-built-" + u, prefix: "pn-sheet-").map { $0.call + "|" + $0.tab } == u + "|sheet", "hardening: the ready notification opens the sheet")
    expect(SheetPipeline.notificationTarget("pn-sheet-" + u, prefix: "pn-sheet-").map { $0.tab } == "readiness", "hardening: the reminder opens readiness")
    expect(SheetPipeline.notificationTarget("pn-sheet-switch-x", prefix: "pn-sheet-") == nil && SheetPipeline.notificationTarget("other", prefix: "pn-sheet-") == nil, "hardening: other ids open nothing")
    expect(SheetPipeline.person("·") == nil && SheetPipeline.person("  ") == nil && SheetPipeline.person("· Lumenfield") == nil, "hardening: '·' alone is no person (no crash)")
    expect(SheetPipeline.person("Emily Parker · Lumenfield").map { $0.name + "|" + $0.company } == "Emily Parker|Lumenfield", "hardening: name · company")
    expect(SheetPipeline.person("Mike Carter").map { $0.name + "|" + $0.company } == "Mike Carter|", "hardening: name only")
    var sent = SheetPipeline.rememberSent([], add: "a")
    sent = SheetPipeline.rememberSent(sent, add: "a")
    expect(sent == ["a"], "hardening: a sent reminder is kept once")
    expect(SheetPipeline.rememberSent((0..<300).map(String.init), add: "x", keep: 200).count == 200, "hardening: sent reminders capped")
    // H4: a save keeps unknown keys (gone_facts, was, checked_at of a source, value extras, a future key)
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("spikes/m0/tests/fixtures/sheet")
    guard let raw = try? Data(contentsOf: dir.appendingPathComponent("sales-intro-lumenfield.sheet.json")),
          var o = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
          var blocks = o["blocks"] as? [[String: Any]], var srcs = o["sources"] as? [[String: Any]], !srcs.isEmpty else { expect(false, "hardening: fixture"); return }
    o["gone_facts"] = [["id": "f-gone", "text": "Lumenfield had 40 people"]]
    o["future_top"] = ["x": 1]
    var factID = ""
    for bi in blocks.indices {
        guard var facts = blocks[bi]["facts"] as? [[String: Any]], !facts.isEmpty, factID.isEmpty else { continue }
        factID = facts[0]["id"] as? String ?? ""
        facts[0]["was"] = "Mike Carter leads sales"
        facts[0]["future_fact"] = "keep me"
        facts[0]["value"] = ["level": "high", "minutes": 3, "backup": "Northwind: 3 days to 2 hours."]
        blocks[bi]["facts"] = facts
        blocks[bi]["future_block"] = true
    }
    srcs[0]["checked_at"] = "2026-11-12T09:00:00+02:00"
    o["blocks"] = blocks; o["sources"] = srcs
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pn-hardening-\(UUID().uuidString).sheet.json")
    guard let d0 = try? JSONSerialization.data(withJSONObject: o), (try? d0.write(to: tmp)) != nil,
          var sheet = try? MeetingSheetIO.load(tmp.path) else { expect(false, "hardening: write fixture"); return }
    for bi in sheet.blocks.indices { for fi in sheet.blocks[bi].facts.indices where sheet.blocks[bi].facts[fi].id == factID {
        sheet.blocks[bi].facts[fi].text = "Edited by the PM"; sheet.blocks[bi].facts[fi].status = .edited } }
    guard (try? MeetingSheetIO.save(sheet, to: tmp.path)) != nil, let back = try? Data(contentsOf: tmp),
          let b = (try? JSONSerialization.jsonObject(with: back)) as? [String: Any] else { expect(false, "hardening: save"); return }
    expect((b["gone_facts"] as? [[String: Any]])?.first?["id"] as? String == "f-gone", "hardening: gone_facts survive a save")
    expect((b["future_top"] as? [String: Any]) != nil, "hardening: an unknown top-level key survives")
    let bf = (b["blocks"] as? [[String: Any]] ?? []).flatMap { ($0["facts"] as? [[String: Any]]) ?? [] }.first { $0["id"] as? String == factID }
    expect(bf?["text"] as? String == "Edited by the PM" && bf?["status"] as? String == "edited", "hardening: the edit is saved")
    expect(bf?["was"] as? String == "Mike Carter leads sales" && bf?["future_fact"] as? String == "keep me", "hardening: fact.was and unknown fact keys survive")
    let v = bf?["value"] as? [String: Any]
    expect(v?["level"] as? String == "high" && (v?["minutes"] as? Int) == 3 && v?["backup"] as? String != nil, "hardening: value extras survive")
    expect((b["blocks"] as? [[String: Any]] ?? []).contains { $0["future_block"] as? Bool == true }, "hardening: unknown block keys survive")
    expect((b["sources"] as? [[String: Any]])?.first?["checked_at"] as? String == "2026-11-12T09:00:00+02:00", "hardening: source.checked_at survives")
    // a key the model knows and cleared stays cleared
    for bi in sheet.blocks.indices { for fi in sheet.blocks[bi].facts.indices where sheet.blocks[bi].facts[fi].id == factID { sheet.blocks[bi].facts[fi].label = nil } }
    _ = try? MeetingSheetIO.save(sheet, to: tmp.path)
    let b2 = (try? JSONSerialization.jsonObject(with: Data(contentsOf: tmp))) as? [String: Any] ?? [:]
    let bf2 = (b2["blocks"] as? [[String: Any]] ?? []).flatMap { ($0["facts"] as? [[String: Any]]) ?? [] }.first { $0["id"] as? String == factID }
    expect(bf2?["label"] == nil && bf2?["was"] != nil, "hardening: a cleared known field is not brought back")
    try? FileManager.default.removeItem(at: tmp)
}

// 0.10.0 (Meeting Sheet, Google Picker): the Drive file id, the Picker values of the build, the fallback decision,
// the page config, the page's messages and the local copy's name. Invented accounts only.
func googlePicker0100() {
    let url = "https://drive.google.com/file/d/1FileIdABCDEFGHIJKL/view?usp=sharing"
    expect(GooglePickerPlan.fileID(url) == "1FileIdABCDEFGHIJKL", "picker: file id from /file/d/")
    expect(GooglePickerPlan.fileID("https://drive.google.com/open?id=1OpenIdABCDEFGHIJ") == "1OpenIdABCDEFGHIJ", "picker: file id from open?id=")
    expect(GooglePickerPlan.fileID("https://docs.google.com/document/d/1AbcDEFghijkLMNOP_qrs/edit") == nil, "picker: a Doc is not a Picker file")
    expect(GooglePickerPlan.fileID("https://drive.google.com/file/d/short/view") == nil, "picker: short ids are not ids")
    // the build's values: both or nothing; the App ID is the project number
    let keys = GooglePickerKeys.parse(Data(#"{"client_id":"c","client_secret":"s","picker_api_key":"k-test","app_id":"123456789012"}"#.utf8))
    expect(keys == GooglePickerKeys(apiKey: "k-test", appID: "123456789012"), "picker: keys from google_oauth.json")
    expect(GooglePickerKeys.parse(Data(#"{"picker_api_key":"k","app_id":123456789012}"#.utf8))?.appID == "123456789012", "picker: numeric app id")
    expect(GooglePickerKeys.parse(Data(#"{"client_id":"c","client_secret":"s"}"#.utf8)) == nil, "picker: no keys = off")
    expect(GooglePickerKeys.parse(Data(#"{"picker_api_key":"k","app_id":""}"#.utf8)) == nil, "picker: empty app id = off")
    expect(GooglePickerKeys.parse(Data(#"{"picker_api_key":"k","app_id":"pacenote-project"}"#.utf8)) == nil, "picker: a project id is not the project number")
    // the decision
    let k = GooglePickerKeys(apiKey: "k", appID: "1")
    let full = GoogleAccount(email: "emily@example.com", refreshToken: "r", scopes: GoogleScopes.all)
    let noFile = GoogleAccount(email: "mike@example.com", refreshToken: "r", scopes: GoogleScopes.identity + GoogleScopes.files)
    expect(GooglePickerPlan.decide(url: url, keys: nil, accounts: [full]) == .browser(reason: "picker_not_set_up"), "picker: no keys = browser fallback")
    expect(GooglePickerPlan.decide(url: url, keys: k, accounts: []) == .connect, "picker: no account = connect")
    expect(GooglePickerPlan.decide(url: url, keys: k, accounts: [noFile, full]) == .picker(account: "emily@example.com"), "picker: the account with drive.file")
    expect(GooglePickerPlan.decide(url: url, keys: k, accounts: [noFile]) == .consent(account: "mike@example.com"), "picker: drive.file missing = consent")
    expect(GooglePickerPlan.decide(url: "https://docs.google.com/document/d/1AbcDEFghijkLMNOP_qrs/edit", keys: k, accounts: [full]) == .notDrive, "picker: a Doc link")
    let second = GoogleAccount(email: "jake@example.com", refreshToken: "r", scopes: GoogleScopes.all)
    expect(GooglePickerPlan.decide(url: url, keys: k, accounts: [full, second], preferred: "jake@example.com") == .picker(account: "jake@example.com"), "picker: preferred account")
    expect(!GoogleScopes.all.contains { $0.hasSuffix("/drive") || $0.hasSuffix("drive.readonly") }, "picker: still no restricted scope")
    // the page config and messages
    let cfg = GooglePickerPlan.config(fileID: "1FileIdABCDEFGHIJKL", token: "t", keys: k, origin: "https://pacenote.bodco.pm", locale: "uk")
    expect(cfg["fileId"] == "1FileIdABCDEFGHIJKL" && cfg["appId"] == "1" && cfg["apiKey"] == "k" && cfg["locale"] == "uk" && cfg["origin"] == "https://pacenote.bodco.pm", "picker: page config")
    expect(GooglePickerPlan.config(fileID: "x", token: "t", keys: k, origin: "o", locale: "de")["locale"] == "en", "picker: locale falls back to en")
    expect(GooglePickerPlan.message(["event": "picked", "id": "1FileIdABCDEFGHIJKL", "name": "Plan.pdf", "mimeType": "application/pdf"])
           == .picked(id: "1FileIdABCDEFGHIJKL", name: "Plan.pdf", mimeType: "application/pdf"), "picker: picked message")
    expect(GooglePickerPlan.message(["event": "cancel"]) == .cancelled && GooglePickerPlan.message(["event": "loaded"]) == .loaded, "picker: cancel and loaded")
    expect(GooglePickerPlan.message(["event": "picked"]) == .failed("no file id") && GooglePickerPlan.message("junk") == nil, "picker: bad messages")
    // the local copy
    expect(GoogleDriveCopy.fileName(id: "1FileIdABCDEFGHIJKL", mimeType: "application/pdf", name: "Plan.pdf") == "google-file-1FileIdABCDEFGHI.pdf", "picker: copy name")
    expect(GoogleDriveCopy.ext(mimeType: "application/vnd.google-apps.spreadsheet", name: "Budget") == "csv", "picker: Sheets export as CSV")
    expect(GoogleDriveCopy.ext(mimeType: "application/octet-stream", name: "notes") == "bin" && GoogleDriveCopy.ext(mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document", name: "Brief") == "docx", "picker: ext from MIME")
    expect(GoogleDriveCopy.downloadURL(id: "abc", mimeType: "application/pdf").hasSuffix("/files/abc?alt=media&supportsAllDrives=true"), "picker: download URL")
    expect(GoogleDriveCopy.downloadURL(id: "abc", mimeType: "application/vnd.google-apps.document").hasSuffix("/files/abc/export?mimeType=text%2Fplain"), "picker: export URL")
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pn-picker-\(UUID().uuidString)").path
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    expect(GoogleDriveCopy.existing(in: dir, id: "1FileIdABCDEFGHIJKL") == nil, "picker: no copy yet")
    let copy = (dir as NSString).appendingPathComponent("google-file-1FileIdABCDEFGHI.pdf")
    FileManager.default.createFile(atPath: copy, contents: Data("x".utf8))
    FileManager.default.createFile(atPath: (dir as NSString).appendingPathComponent("google-file-1FileIdABCDEFGHI.txt.part"), contents: Data())
    expect(GoogleDriveCopy.existing(in: dir, id: "1FileIdABCDEFGHIJKL") == copy, "picker: the confirmed copy is found")
    try? FileManager.default.removeItem(atPath: dir)
}

// 0.10.0 (AI chain, owner 12.11): one fallback chain, out-state with reset times, account usage, the status icon
func aiChain0100() {
    let all: Set<String> = ["code", "codex", "api", "openai", "gemini", "agy", "local"]
    let d = AIChain.defaults()
    expect(d.map { $0.route } == ["code", "codex", "api", "openai", "gemini", "agy", "local"] && d.allSatisfy { $0.on }, "chain: default order, all on")
    expect(AIChain.defaults(localOn: false).last == AIChain.Entry("local", on: false), "chain: an old localFallback off keeps local off")
    expect(AIChain.order(job: "prep", chosen: "api", chain: d, connected: all) == ["api", "code", "codex", "openai", "gemini", "agy", "local"], "chain: prep, chosen first")
    expect(AIChain.order(job: "tips", chosen: "api", chain: d, connected: all) == ["api", "code", "codex", "openai", "gemini"], "chain: tips never local or agy")
    expect(AIChain.order(job: "tips", chosen: "openai", chain: d, connected: ["openai", "api"]) == ["openai", "api"], "chain: only connected")
    expect(AIChain.order(job: "after", chosen: "code", chain: d, connected: all, auto: false) == ["code"], "chain: switching off = the chosen AI only")
    let moved = AIChain.move(d, route: "local", by: 1)
    expect(moved == d, "chain: a move past the end changes nothing")
    var c = AIChain.move(d, route: "local", by: -1)
    expect(c.map { $0.route }.suffix(2) == ["local", "agy"], "chain: local moved up")
    expect(AIChain.order(job: "after", chosen: "code", chain: c, connected: all).last == "local", "chain: local is always the last step")
    c = AIChain.setOn(d, route: "gemini", on: false)
    expect(!AIChain.order(job: "after", chosen: "code", chain: c, connected: all).contains("gemini"), "chain: an AI switched off is skipped")
    expect(AIChain.order(job: "after", chosen: "gemini", chain: c, connected: all).first == "gemini", "chain: a chosen AI goes first even when off in the list")
    expect(AIChain.enabled(c) == ["code", "codex", "api", "openai", "agy", "local"], "chain: enabled order for the engine")
    expect(AIChain.normalized([AIChain.Entry("x"), AIChain.Entry("api", on: false), AIChain.Entry("api")]).first == AIChain.Entry("api", on: false)
           && AIChain.normalized([]).count == 7, "chain: normalized")
    expect(AIChain.next(["api", "code", "codex"], tried: ["api"], usable: { $0 != "code" }) == "codex", "chain: next untried usable")
    // Settings: an old config without a chain
    let old = #"{"prep":"code","tips":"api","after":"code","autoSwitch":true,"localFallback":false}"#
    let r = try? JSONDecoder().decode(AppConfig.AIRoutes.self, from: Data(old.utf8))
    expect(r?.chain.last == AIChain.Entry("local", on: false) && r?.chain.count == 7, "chain: decoded from an old config")
    expect(r?.order("tips", connected: all) == ["api", "code", "codex", "openai", "gemini"], "chain: AIRoutes.order")
    if let r = r, let data = try? JSONEncoder().encode(r), let back = try? JSONDecoder().decode(AppConfig.AIRoutes.self, from: data) {
        expect(back.chain == r.chain, "chain: round trip")
    } else { expect(false, "chain: encode") }

    // out-state and reset times
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Europe/Kyiv")!
    let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 10, minute: 15))!
    let codexMsg = "You\u{2019}ve hit your usage limit. Upgrade to Pro (https://chatgpt.com/explore/pro), visit https://chatgpt.com/settings/usage to purchase more credits or try again at 12:48 PM."
    let r1 = AIOut.resetTime(codexMsg, now: now, calendar: cal)
    expect(r1.map { cal.component(.hour, from: $0) == 12 && cal.component(.minute, from: $0) == 48 && cal.isDate($0, inSameDayAs: now) } == true, "reset: Codex 12:48 PM")
    let r2 = AIOut.resetTime("5-hour limit reached \u{2219} resets 9am", now: now, calendar: cal)
    expect(r2.map { cal.component(.hour, from: $0) == 9 && !cal.isDate($0, inSameDayAs: now) } == true, "reset: Claude 9am is tomorrow")
    let r3 = AIOut.resetTime("Your limit will reset at 3:05 pm (Europe/Kyiv)", now: now, calendar: cal)
    expect(r3.map { cal.component(.hour, from: $0) == 15 && cal.component(.minute, from: $0) == 5 } == true, "reset: will reset at 3:05 pm")
    expect(AIOut.resetTime("resets at 18:30", now: now, calendar: cal).map { cal.component(.hour, from: $0) == 18 } == true, "reset: 24-hour")
    expect(AIOut.resetTime("try again in 2 hours 5 minutes", now: now, calendar: cal) == now.addingTimeInterval(7500), "reset: in 2 hours 5 minutes")
    expect(AIOut.resetTime("try again in 1 day 3h", now: now, calendar: cal) == now.addingTimeInterval(97200), "reset: in 1 day 3h")
    expect(AIOut.resetTime(#"{"resets_at": 1793731185}"#, now: now)?.timeIntervalSince1970 == 1793731185, "reset: epoch")
    expect(AIOut.resetTime("rate limit exceeded, retry later", now: now) == nil && AIOut.resetTime("resets 5 things", now: now) == nil, "reset: no time")
    let st = AIOut.parse(["codex": ["down": true, "reason": "limit", "since": 100.0, "checked": 100.0, "until": 5000.0],
                          "api": ["down": true, "reason": "auth", "since": 100.0, "checked": 200.0], "code": ["down": false]])
    expect(st["codex"]?.until == 5000 && AIOut.nextCheck(st["codex"]!) == 5000, "out: until is the next check")
    expect(AIOut.nextCheck(st["api"]!) == 1100 && !AIOut.due(st["api"], now: 1000) && AIOut.due(st["api"], now: 1100), "out: 15 minutes without a reset time")
    expect(AIOut.due(st["code"], now: 0) && AIOut.due(nil, now: 0), "out: not down is due")

    // account usage
    let claudeEv: [String: Any] = ["type": "rate_limit_event", "rate_limit_info": ["status": "allowed_warning", "resetsAt": 1794063600, "utilization": 0.81,
        "unifiedWindows": ["five_hour": ["utilization": 0.1, "resetsAt": 1793977200, "status": "allowed"],
                           "seven_day": ["utilization": 0.81, "resetsAt": 1794063600, "status": "allowed_warning"]]]]
    let cu = AIAccountUsage.fromClaude(claudeEv, now: 1793970000)
    expect(cu?.windows.count == 2 && cu?.maxUsed == 81 && cu?.resetOfMax == 1794063600 && cu?.limited == false, "usage: Claude rate_limit_event")
    expect(AIAccountUsage.fromClaude(["type": "result"], now: 0) == nil, "usage: other events ignored")
    let codexRL: [String: Any] = ["limit_id": "codex", "primary": ["used_percent": 12.0, "window_minutes": 300, "resets_at": 1793968790],
        "secondary": ["used_percent": 54.0, "window_minutes": 10080, "resets_at": 1794317985], "rate_limit_reached_type": NSNull()]
    let xu = AIAccountUsage.fromCodex(codexRL, now: 1793960000)
    expect(xu?.windows.map { $0.name } == ["five_hour", "seven_day"] && xu?.maxUsed == 54 && xu?.limited == false, "usage: Codex rate_limits")
    if let u = cu {
        let back = AIAccountUsage.parseFile(["code": AIAccountUsage.encode(u)])["code"]
        expect(back == u, "usage: file round trip")
        expect(AIAccountUsage.current(u, now: 1793980000).windows.map { $0.name } == ["seven_day"], "usage: a passed window is dropped")
    }

    // the status icon and its rows
    let tz = TimeZone(identifier: "Europe/Kyiv")!
    let chosen = ["tips": "api", "prep": "code", "after": "code"]
    var inp = AIStatus.Input(connected: ["code", "codex", "api", "local"], chosen: chosen, chain: d,
                             accounts: ["code": cu!], spend: ["claude": 3.5], limits: ["claude": 10], now: 1793970000)
    var rows = AIStatus.rows(inp, tz: tz)
    expect(AIStatus.level(rows) == .ok && AIStatus.symbol(.ok) == "cpu", "status: neutral")
    expect(rows.first { $0.route == "api" }?.usage == AIStatus.Line("ai.status.usage.api", ["left": "6.50", "limit": "10.00"]), "status: API left of the limit")
    expect(rows.first { $0.route == "local" }?.usage.key == "ai.status.usage.local", "status: local no limit")
    expect(rows.first { $0.route == "code" }?.usage == AIStatus.Line("ai.status.usage.account", ["pct": "10", "time": "17:00"])
           && rows.first { $0.route == "code" }?.usageMore == [AIStatus.Line("ai.status.usage.week", ["pct": "81"])]
           && rows.first { $0.route == "code" }?.serving == ["prep", "after"], "status: 5-hour % with reset, weekly %, and jobs")
    expect(rows.first { $0.route == "codex" }?.usage.key == "ai.status.usage.afterCodex", "status: ChatGPT usage appears after its next run")
    expect(rows.first { $0.route == "code" }?.status.key == "ai.status.state.ok", "status: a healthy AI is OK")
    inp.spend = ["claude": 9.2]
    rows = AIStatus.rows(inp, tz: tz)
    expect(AIStatus.level(rows) == .warn && AIStatus.symbol(.warn) == "exclamationmark.triangle.fill", "status: <= $1 left is orange")
    inp.spend = ["claude": 1]
    var near = cu!; near.windows[1].usedPercent = 96
    inp.accounts = ["code": near]
    expect(AIStatus.level(AIStatus.rows(inp, tz: tz)) == .warn, "status: >= 95% of an account is orange")
    inp.accounts = ["codex": near]
    expect(AIStatus.level(AIStatus.rows(inp, tz: tz)) == .ok, "status: an AI no job uses does not color the icon")
    // the Claude account out with a reset time: red, tips stay on the API, prep and after move to the ChatGPT account
    inp.accounts = [:]
    inp.out = ["code": AIOut.State(down: true, reason: "limit", since: 1793969000, checked: 1793969000, until: 1793977200)]
    rows = AIStatus.rows(inp, tz: tz)
    let code = rows.first { $0.route == "code" }!
    expect(AIStatus.level(rows) == .out && AIStatus.symbol(.out) == "exclamationmark.octagon.fill", "status: chosen AI out is red")
    expect(code.status == AIStatus.Line("ai.status.state.limitUntil", ["time": "17:00"]), "status: limit reached, resets at")
    expect(code.serving.isEmpty && code.chosenFor == ["prep", "after"] && rows.first { $0.route == "codex" }?.serving == ["prep", "after"], "status: jobs moved to the next AI")
    expect(AIStatus.jobsLines(code) == [AIStatus.Line("ai.status.jobs.moved", ["jobs": "ai.status.job.prep,ai.status.job.after"])], "status: jobs line of a moved AI")
    inp.out = ["code": AIOut.State(down: true, reason: "auth", since: 1793969000, checked: 1793969500)]
    rows = AIStatus.rows(inp, tz: tz)
    expect(rows.first { $0.route == "code" }?.status == AIStatus.Line("ai.status.state.outUntil", ["reason": "ai.reason.auth", "time": "15:06"]), "status: out, checking again at")
    inp.out = ["code": AIOut.State(down: true, reason: "auth", since: 1793969000, checked: 1793969000)]
    expect(AIStatus.rows(inp, tz: tz).first { $0.route == "code" }?.status.key == "ai.status.state.checking", "status: out and due: being checked")
    inp.now = 1793977300
    inp.out = ["code": AIOut.State(down: true, reason: "limit", since: 1793969000, checked: 1793969000, until: 1793977200)]
    expect(AIStatus.rows(inp, tz: tz).first { $0.route == "code" }?.state == .ok, "status: after the reset time it is tried again")
    inp.spend = ["claude": 10]
    rows = AIStatus.rows(inp, tz: tz)
    expect(rows.first { $0.route == "api" }?.state == .capped && AIStatus.level(rows) == .out, "status: monthly limit reached is red")
    expect(AIStatus.current(job: "tips", inp) == "code", "status: tips leave a capped API")
    statusFix0100()
}

// 0.10.0 (status fix, 12.11): "OK" not "working", the ChatGPT account's limits and a reached limit known at launch
func statusFix0100() {
    let tz = TimeZone(identifier: "Europe/Kyiv")!
    let d = AIChain.defaults()
    let t0 = 1793970000.0, reset = 1793977200.0                // 17:00 Kyiv
    // Codex rate_limits: 100% of the 5 hours, the reached type named, or neither
    let full: [String: Any] = ["primary": ["used_percent": 100.0, "window_minutes": 300, "resets_at": reset],
                               "secondary": ["used_percent": 40.0, "window_minutes": 10080, "resets_at": 1794317985], "rate_limit_reached_type": NSNull()]
    let fu = AIAccountUsage.fromCodex(full, now: t0)
    expect(fu?.limited == true && fu?.until == reset, "statusfix: 100% of a window is a reached limit until its reset")
    let named: [String: Any] = ["primary": ["used_percent": 80.0, "window_minutes": 300, "resets_at": reset],
                                "secondary": ["used_percent": 99.0, "window_minutes": 10080, "resets_at": 1794317985], "rate_limit_reached_type": "primary"]
    expect(AIAccountUsage.fromCodex(named, now: t0)?.until == reset, "statusfix: the reached type names the window")
    let plain: [String: Any] = ["primary": ["used_percent": 20.0, "window_minutes": 300, "resets_at": reset], "secondary": NSNull(), "rate_limit_reached_type": NSNull()]
    let pu = AIAccountUsage.fromCodex(plain, now: t0)
    expect(pu?.limited == false && pu?.until == nil && pu?.windows.count == 1, "statusfix: no limit, a missing window is skipped")
    let claudeRejected: [String: Any] = ["type": "rate_limit_event", "rate_limit_info": ["status": "rejected", "resetsAt": reset,
        "unifiedWindows": ["five_hour": ["utilization": 1.0, "resetsAt": reset, "status": "rejected"]]]]
    expect(AIAccountUsage.fromClaude(claudeRejected, now: t0)?.until == reset, "statusfix: Claude rejected holds until its reset")
    // a limit error with no numbers: persisted, red until the reset time, then OK again
    let le = AIAccountUsage.limitError(until: reset, now: t0)
    let back = AIAccountUsage.parseFile(["codex": AIAccountUsage.encode(le)])["codex"]
    expect(back == le && back?.until == reset, "statusfix: a limit error round-trips with its reset time")
    expect(AIAccountUsage.current(le, now: reset - 60).limited && !AIAccountUsage.current(le, now: reset + 60).limited,
           "statusfix: the limit holds until the reset time only")
    var inp = AIStatus.Input(connected: ["code", "codex"], chosen: ["tips": "code", "prep": "codex", "after": "code"], chain: d,
                             accounts: ["codex": le], now: t0)
    var rows = AIStatus.rows(inp, tz: tz)
    var cx = rows.first { $0.route == "codex" }!
    expect(cx.state == .limit && cx.status == AIStatus.Line("ai.status.state.limitUntil", ["time": "17:00"]) && AIStatus.level(rows) == .out,
           "statusfix: ChatGPT at its limit is red at launch, resets at 17:00")
    expect(rows.first { $0.route == "code" }?.usage.key == "ai.status.usage.afterClaude", "statusfix: Claude usage appears after its next run")
    inp.now = reset + 60
    rows = AIStatus.rows(inp, tz: tz)
    cx = rows.first { $0.route == "codex" }!
    expect(cx.state == .ok && cx.status.key == "ai.status.state.ok" && cx.usage.key == "ai.status.usage.afterCodex" && AIStatus.level(rows) == .ok,
           "statusfix: after the reset time it is OK again")
    // numbers: 100% of the 5 hours -> limit until its reset; 96% of the week -> close
    inp.now = t0
    inp.accounts = ["codex": fu!]
    cx = AIStatus.rows(inp, tz: tz).first { $0.route == "codex" }!
    expect(cx.state == .limit && cx.status.vars["time"] == "17:00" && cx.usage == AIStatus.Line("ai.status.usage.account", ["pct": "100", "time": "17:00"])
           && cx.usageMore == [AIStatus.Line("ai.status.usage.week", ["pct": "40"])], "statusfix: 5-hour line, weekly line, limit until reset")
    var near = AIAccountUsage.fromCodex(plain, now: t0)!
    near.windows.append(AIAccountUsage.Window(name: "seven_day", usedPercent: 96, resetsAt: 1794317985))
    inp.accounts = ["codex": near]
    rows = AIStatus.rows(inp, tz: tz)
    expect(rows.first { $0.route == "codex" }?.state == .near && AIStatus.level(rows) == .warn, "statusfix: 95% of the week is a warning")
    // the wording: a state, never an activity
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/i18n")
    func table(_ l: String) -> [String: String] {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("\(l).json")),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return [:] }
        return o.compactMapValues { $0 as? String }
    }
    let tables = ["en": table("en"), "uk": table("uk")]
    for k in ["ai.status.state.ok", "ai.status.title.ok", "ai.status.state.checking", "ai.status.state.outUntil", "ai.status.jobs.now"] {
        for lang in ["en", "uk"] {
            let v = tables[lang]?[k] ?? ""
            expect(!v.isEmpty && !v.lowercased().contains("working") && !v.contains("працює") && !v.contains("перевіряємо"), "statusfix: \(lang) \(k) reads as a state")
        }
    }
    expect(tables["en"]?["ai.status.state.ok"] == "OK" && tables["en"]?["ai.status.title.ok"] == "AI: OK", "statusfix: OK wording")
    for (k, v) in (tables["en"] ?? [:]) where k.hasPrefix("ai.status.state.") || k.hasPrefix("ai.status.title.") {
        expect(!v.lowercased().contains("working") && !v.lowercased().contains("checking"), "statusfix: en \(k) is not an activity")
    }
}

// 0.10.0 (Meeting Sheet, folders): a folder is a source of its own, never "a folder, not a file"
func sheetFolders0100() {
    expect(SourceType.known.contains(.folder) && SourceType(rawValue: "folder") == .folder, "folders: folder is a known source type")
    expect(SheetFolders.sourceType(isDir: true) == "folder" && SheetFolders.sourceType(isDir: false) == "file", "folders: a folder path is a folder source")
    expect(SheetFolders.migrate(type: "folder_file", isDir: true) == "folder" && SheetFolders.migrate(type: "file", isDir: true) == "folder",
           "folders: an older setup's folder becomes a folder source")
    expect(SheetFolders.migrate(type: "folder_file", isDir: false) == "folder_file" && SheetFolders.migrate(type: "gdoc", isDir: true) == "gdoc",
           "folders: files and links keep their type")
    let i = SheetFolderInfo(days: 7, recent: 12, inWindow: 12, searchable: 340, fallback: false, overBudget: 0, tokens: 9000)
    let l = SheetFolders.line(i)
    expect(l.key == "sheet.ui.folder.line" && l.args["n"] == "12" && l.args["days"] == "7" && l.args["m"] == "340", "folders: the row line")
    let fb = SheetFolders.line(SheetFolderInfo(recent: 5, searchable: 8, fallback: true), days: 10)
    expect(fb.key == "sheet.ui.folder.fallback" && fb.args == ["n": "5", "days": "10", "m": "8", "over": "0"],
           "folders: fallback line with the default days")
    expect(SheetFolders.line(SheetFolderInfo(days: 7, recent: 0, searchable: 0)).key == "sheet.ui.folder.empty", "folders: an empty folder")
    expect(SheetFolders.tokens(i) == 9000 && SheetFolders.tokens(nil) == 0, "folders: the size counts only the files taken")
    expect(SheetFolders.days("14") == 14 && SheetFolders.days("") == nil && SheetFolders.days("0") == nil && SheetFolders.days("999") == 365,
           "folders: a folder's own days")
    let json = """
    {"id": "s3", "n": 3, "type": "folder", "title": "Orbit", "path": "/p/Orbit", "access": "ok", "used": "full", "days": 14,
     "folder": {"days": 14, "recent": 4, "in_window": 4, "searchable": 6, "fallback": false, "over_budget": 0, "tokens": 820}}
    """
    let kid = """
    {"id": "s3-fa1b2c3d4", "n": 4, "type": "folder_file", "title": "status.md", "path": "/p/Orbit/status.md", "access": "ok", "used": "full", "parent": "s3"}
    """
    let s = try? JSONDecoder().decode(SheetSource.self, from: Data(json.utf8))
    let k = try? JSONDecoder().decode(SheetSource.self, from: Data(kid.utf8))
    expect(s?.type == .folder && s?.days == 14 && s?.folder?.searchable == 6 && s?.folder?.inWindow == 4 && s?.folder?.tokens == 820,
           "folders: a folder source decodes with its counts")
    expect(k?.parent == "s3" && k?.type == .folderFile, "folders: a folder file names its folder")
    if let s, let d = try? JSONEncoder().encode(s), let back = try? JSONDecoder().decode(SheetSource.self, from: d) {
        expect(back == s, "folders: round trip")
    } else { expect(false, "folders: encode") }
    expect(SheetFolderInfo(json: ["recent": 2, "searchable": 9, "in_window": 3, "over_budget": 1]) == SheetFolderInfo(recent: 2, inWindow: 3, searchable: 9, overBudget: 1),
           "folders: the counts from the sidecar")
}

/// 2026-11-12 (owner, fix77): compact mode is gone (menu item, Control-Option-T, the small window, its strings), and a
/// stand-up sheet keeps the Tracker the build put in it (live fallback) and shows why Pacenote added a source.
func fix77() {
    let res = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources")
    func text(_ p: String) -> String { (try? String(contentsOf: res.appendingPathComponent(p), encoding: .utf8)) ?? "" }
    let js = text("tips/tips.js"), css = text("tips/tips.css"), html = text("tips/index.html")
    expect(!js.isEmpty && !css.isEmpty, "fix77: the tips window files load")
    expect(!js.contains("['compact'") && !js.contains("post('compact'") && !js.contains("k.compact") && !js.contains("compact: '"),
           "fix77: no compact item, key or string in the tips window")
    expect(!css.contains(".compact") && !html.contains("compact"), "fix77: no compact styles")
    expect(js.contains("function setMode() { S.call.mode = 'normal'; render(); }"), "fix77: an old setMode('compact') opens the full window")
    for l in ["en", "uk"] {
        guard let d = try? Data(contentsOf: res.appendingPathComponent("i18n/\(l).json")),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { expect(false, "fix77: i18n \(l)"); continue }
        expect(o["menubar.compact"] == nil && o["pm.menu.compact"] == nil, "fix77: \(l) has no compact strings")
        expect(!((o["onb.done.keys"] as? String) ?? "{t}").contains("{t}"), "fix77: \(l) onboarding keys without compact")
    }
    let orig = #"{"schema": "pacenote.sheet/1", "id": "x", "tracker": {"on_me": [{"text": "Send Mike Carter the test accounts"}]}}"#
    let new = #"{"schema": "pacenote.sheet/1", "id": "x"}"#
    if let m = try? MeetingSheetIO.patched(original: Data(orig.utf8), new: Data(new.utf8)),
       let o = (try? JSONSerialization.jsonObject(with: m)) as? [String: Any] {
        expect((o["tracker"] as? [String: Any])?["on_me"] != nil, "fix77: a save keeps the sheet's Tracker")
    } else { expect(false, "fix77: patch") }
    let src = #"{"id": "s-tracker", "n": 2, "type": "tracker", "title": "Tracker: 3 on me, 1 waiting on others", "access": "ok", "used": "full", "auto": true, "why": ["open items on you and waiting on others", "from 2 project registers"]}"#
    let s = try? JSONDecoder().decode(SheetSource.self, from: Data(src.utf8))
    expect(s?.type == .tracker && s?.auto == true && s?.why?.count == 2, "fix77: an auto source decodes with its why")
}

// f78 (owner 12.11): the dictionary in the config, the usage probe's schedule, the "updated" time and the wording
func f78() {
    var c = AppConfig()
    c.dictionary = [DictionaryEntry(word: "Lumenfield", heard: ["Lumen field", "Lumin field"]), DictionaryEntry(word: "Kestrel")]
    let url = URL(fileURLWithPath: NSTemporaryDirectory() + "f78-dict-\(getpid()).json")
    try? c.save(to: url)
    let back = AppConfig.load(from: url)
    expect(back == c && back.dictionary.count == 2 && back.dictionary[0].heard == ["Lumen field", "Lumin field"], "f78: the dictionary round-trips")
    try? FileManager.default.removeItem(at: url)
    let old = try? JSONDecoder().decode(AppConfig.self, from: Data(#"{"nameAliases": ["Mike"]}"#.utf8))
    expect(old?.dictionary == [] && old?.nameAliases == ["Mike"], "f78: an older config has an empty dictionary")
    let noId = try? JSONDecoder().decode(AppConfig.self, from: Data(#"{"dictionary": [{"word": "Orbitex", "heard": ["Orbit ex"]}]}"#.utf8))
    expect(noId?.dictionary.first?.word == "Orbitex" && noId?.dictionary.first?.id.isEmpty == false, "f78: a hand-written row gets an id")
    expect(DictionaryEntry.split(" Lumen field, ,Lumin field ,") == ["Lumen field", "Lumin field"], "f78: heard-as splits on commas")
    let core = DictionaryEntry.core([DictionaryEntry(word: " Lumenfield ", heard: ["Lumen  field", "lumenfield", "Lumen field"]),
                                     DictionaryEntry(word: "lumenfield", heard: ["x"]), DictionaryEntry(word: "  ")])
    expect(core.count == 1 && (core[0]["word"] as? String) == "Lumenfield" && (core[0]["heard"] as? [String]) == ["Lumen field"],
           "f78: the recorder gets clean rows, the word once")
    // the probe's schedule
    let t = 1_794_000_000.0
    typealias P = AIUsageProbePlan
    expect(P.due(signedIn: true, busy: false, reportedAt: nil, blockedUntil: nil, lastProbe: nil, now: t), "f78: probe a quiet account")
    expect(!P.due(signedIn: false, busy: false, reportedAt: nil, blockedUntil: nil, lastProbe: nil, now: t), "f78: never a signed-out account")
    expect(!P.due(signedIn: true, busy: true, reportedAt: nil, blockedUntil: nil, lastProbe: nil, now: t), "f78: never during a call or a preparation")
    expect(!P.due(signedIn: true, busy: false, reportedAt: nil, blockedUntil: nil, lastProbe: t - 300, now: t), "f78: one probe per 10 minutes")
    expect(!P.due(signedIn: true, busy: false, reportedAt: t - 300, blockedUntil: nil, lastProbe: nil, now: t), "f78: fresh numbers need no probe")
    expect(P.due(signedIn: true, busy: false, reportedAt: t - 700, blockedUntil: nil, lastProbe: t - 700, now: t), "f78: older than 10 minutes: probe")
    expect(!P.due(signedIn: true, busy: false, reportedAt: nil, blockedUntil: t + 60, lastProbe: nil, now: t), "f78: never while at the limit")
    let lim = AIAccountUsage.limitError(until: t + 3600, now: t - 60)
    expect(P.blockedUntil(usage: lim, out: nil, now: t) == t + 3600 && P.blockedUntil(usage: lim, out: nil, now: t + 3601) == nil,
           "f78: a limit blocks the probe until its reset")
    let ok = AIAccountUsage.Usage(at: t, windows: [AIAccountUsage.Window(name: "five_hour", usedPercent: 30, resetsAt: t + 900)])
    expect(P.blockedUntil(usage: ok, out: nil, now: t) == nil, "f78: an account in its limits is not blocked")
    let out = AIOut.State(down: true, reason: "limit", since: t - 60, checked: t - 60, until: t + 1200)
    expect(P.blockedUntil(usage: nil, out: out, now: t) == t + 1200, "f78: an out account waits for its reset")
    expect(P.firstDelay == 60 && P.every == 1800 && P.minGap == 600 && P.staleAfter == 600, "f78: launch +60 s, every 30 min, 10 min gap")
    // i18n: both languages
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/i18n")
    for l in ["en", "uk"] {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("\(l).json")),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { expect(false, "f78: i18n \(l)"); continue }
        for k in ["settings.tab.transcription", "settings.pane.transcription", "dict.head", "dict.col.word", "dict.col.heard", "dict.add",
                  "dict.remove", "dict.empty", "dict.footer", "dict.word.placeholder", "dict.heard.placeholder", "ai.status.updated"] {
            let v = (o[k] as? String) ?? ""
            expect(!v.isEmpty && !v.contains("\u{2014}"), "f78: \(l) \(k)")
        }
        expect(((o["ai.status.updated"] as? String) ?? "").contains("{time}"), "f78: \(l) updated has the time")
        expect(((o["ai.status.state.ok"] as? String) ?? "") == "OK", "f78: \(l) the healthy state reads OK")
    }
}

/// 0.10.1 (A2): moving a call to another project (CallReassign) and its register items (op move).
func callReassign0101() {
    let fm = FileManager.default
    let base = NSTemporaryDirectory() + "pn-reassign-" + UUID().uuidString
    let a = base + "/orbit", b = base + "/my-calls"
    for d in [a + "/live", a + "/video", b + "/live", a + "/live/2026-11-14-1000-weekly.app.judge"] { try? fm.createDirectory(atPath: d, withIntermediateDirectories: true) }
    let key = "2026-11-14-1000-weekly"
    let mine = [key + ".app.md", key + ".app.brief.md", key + ".app.tips.jsonl", key + ".md", key + ".notes.md", key + ".app.notion.json"]
    let other = [key + "-sync.app.md", "2026-11-14-1000-weekly2.md", "commitments.jsonl", "prep-2026-11-14-1000-weekly.brief.md"]
    for n in mine + other { fm.createFile(atPath: a + "/live/" + n, contents: Data("x".utf8)) }
    fm.createFile(atPath: a + "/live/" + key + ".app.judge/judge.summary.json", contents: Data("{}".utf8))
    for n in [key + ".recording.json", key + ".recording.mp4", key + ".recording-2.m4a", key + "-sync.recording.mp4"] {
        fm.createFile(atPath: a + "/video/" + n, contents: Data("v".utf8))
    }
    let file = a + "/live/" + key + ".app.md"
    expect(CallReassign.key(file) == key, "A2: key drops .app and .md")
    expect(CallReassign.root(of: file) == a, "A2: root of a transcript")
    expect(CallReassign.belongs(key + ".app.tips.jsonl", key: key) && !CallReassign.belongs(key + "-sync.app.md", key: key), "A2: belongs by name and dot")
    expect(CallReassign.plan(file: file, toRoot: a).sameProject && !CallReassign.plan(file: file, toRoot: a).canApply, "A2: same project is not a move")
    var p = CallReassign.plan(file: file, toRoot: b)
    expect(p.moves.count == mine.count + 1 + 3, "A2: plan moves the call's live files, the judge folder and 3 recording files (\(p.moves.count))")
    expect(p.collisions.isEmpty && p.canApply, "A2: no collisions")
    expect(p.newFile == b + "/live/" + key + ".app.md", "A2: new transcript path")
    // collision: nothing moves
    fm.createFile(atPath: b + "/live/" + key + ".notes.md", contents: Data("y".utf8))
    p = CallReassign.plan(file: file, toRoot: b)
    expect(p.collisions == [b + "/live/" + key + ".notes.md"] && !p.canApply, "A2: collision found")
    var threw = false
    do { try CallReassign.apply(p) } catch CallReassign.Failure.collision(let c) { threw = c.count == 1 } catch {}
    expect(threw && fm.fileExists(atPath: file), "A2: a collision moves nothing")
    try? fm.moveItem(atPath: b + "/live/" + key + ".notes.md", toPath: base + "/aside.md")
    p = CallReassign.plan(file: file, toRoot: b)
    let done = (try? CallReassign.apply(p)) ?? []
    expect(done.count == p.moves.count, "A2: all moved")
    expect(!fm.fileExists(atPath: file) && fm.fileExists(atPath: p.newFile), "A2: transcript in the new project")
    expect(fm.fileExists(atPath: b + "/live/" + key + ".app.judge/judge.summary.json"), "A2: judge folder moved whole")
    expect(fm.fileExists(atPath: b + "/video/" + key + ".recording-2.m4a"), "A2: recording moved to the new video folder")
    expect(other.allSatisfy { fm.fileExists(atPath: a + "/live/" + $0) } && fm.fileExists(atPath: a + "/video/" + key + "-sync.recording.mp4"), "A2: other calls and the prep original stay")
    // rollback: the second move fails (its source is gone), the first goes back
    let r1 = base + "/r1.txt", r2 = base + "/r2-missing.txt"
    fm.createFile(atPath: r1, contents: Data("1".utf8))
    var rp = CallReassign.Plan(file: r1, newFile: base + "/x/r1.txt", key: "r", fromRoot: base, toRoot: base + "/x")
    rp.moves = [CallReassign.Move(from: r1, to: base + "/x/r1.txt"), CallReassign.Move(from: r2, to: base + "/x/r2.txt")]
    var failed = false
    do { try CallReassign.apply(rp) } catch CallReassign.Failure.moveFailed { failed = true } catch {}
    expect(failed && fm.fileExists(atPath: r1) && !fm.fileExists(atPath: base + "/x/r1.txt"), "A2: rollback on failure")
    // sweep: a late file in the old project follows; an existing name stays
    fm.createFile(atPath: a + "/live/" + key + ".app.speakers.json", contents: Data("s".utf8))
    fm.createFile(atPath: a + "/live/" + key + ".app.brief.md", contents: Data("late twin".utf8))
    let sw = CallReassign.sweep(key: key, fromRoot: a, toRoot: b)
    expect(sw.count == 1 && fm.fileExists(atPath: b + "/live/" + key + ".app.speakers.json"), "A2: sweep moves late files")
    expect(fm.fileExists(atPath: a + "/live/" + key + ".app.brief.md"), "A2: sweep never overwrites")
    // waiting for quiet
    let now = Date()
    expect(!CallReassign.readyToMove(callLive: true, lastWrite: nil, now: now), "A2: not during the call")
    expect(!CallReassign.readyToMove(callLive: false, lastWrite: now.addingTimeInterval(-10), now: now), "A2: files still written")
    expect(CallReassign.readyToMove(callLive: false, lastWrite: now.addingTimeInterval(-61), now: now), "A2: quiet after 60 s")
    var pend = CallReassign.Pending(file: file, toRoot: b, toTarget: "project:x", toName: "X", requested: now)
    expect(!CallReassign.sweepDone(pend, now: now), "A2: not moved yet")
    pend.moved = now.addingTimeInterval(-31 * 60)
    expect(CallReassign.sweepDone(pend, now: now) && pend.key == key && pend.fromRoot == a, "A2: sweeps end after 30 min")
    // the register: the call's items go along, others stay; both registers stay append-only
    let la = a + "/live", lb = b + "/live"
    try? fm.removeItem(atPath: la + "/commitments.jsonl")
    let c1 = CommitmentRegister.makeID(call: file, owner: "me", text: "Send the deck to Mike")
    let c2 = CommitmentRegister.makeID(call: file, owner: "Emily", text: "Check the budget")
    let c3 = CommitmentRegister.makeID(call: la + "/2026-11-13-0900-other.app.md", owner: "me", text: "Other call item")
    CommitmentRegister.append(folder: la, [
        ["op": "add", "id": c1, "text": "Send the deck to Mike", "owner": "me", "project": "orbit", "series": "orbit|weekly", "call": file, "created": "2026-11-14T10:05:00+02:00"],
        ["op": "add", "id": c2, "text": "Check the budget", "owner": "Emily", "project": "orbit", "series": "orbit|weekly", "call": key + ".md", "created": "2026-11-14T10:06:00+02:00"],
        ["op": "add", "id": c3, "text": "Other call item", "owner": "me", "project": "orbit", "call": "2026-11-13-0900-other.app.md", "created": "2026-11-13T09:05:00+02:00"],
        ["op": "done", "id": c1, "at": "2026-11-14T11:00:00+02:00", "source": "manual"]])
    let before = (try? String(contentsOfFile: la + "/commitments.jsonl", encoding: .utf8)) ?? ""
    let n = CommitmentRegister.moveCall(file, from: la, to: lb, project: "my-calls", title: "Weekly")
    expect(n == 2, "A2: two items of the call moved (\(n))")
    let after = (try? String(contentsOfFile: la + "/commitments.jsonl", encoding: .utf8)) ?? ""
    expect(after.hasPrefix(before), "A2: the old register only grew")
    expect(CommitmentRegister.load(folder: la).map(\.id) == [c3], "A2: only the other call's item stays")
    let nb = CommitmentRegister.load(folder: lb)
    expect(Set(nb.map(\.id)) == [c1, c2], "A2: both items in the new register")
    expect(nb.first { $0.id == c1 }?.status == "done", "A2: later ops go along (done)")
    expect(nb.allSatisfy { $0.project == "my-calls" && $0.series == "my-calls|weekly" }, "A2: new project and series")
    expect(nb.first { $0.id == c1 }?.call == lb + "/" + key + ".app.md", "A2: a full call path points to the new folder")
    expect(nb.first { $0.id == c2 }?.call == key + ".md", "A2: a bare call name stays")
    expect(CommitmentRegister.moveCall(file, from: la, to: lb, project: "my-calls") == 0, "A2: moving again moves nothing")
    // and back: the old register holds them again, once
    let back = CommitmentRegister.moveCall(lb + "/" + key + ".app.md", from: lb, to: la, project: "orbit", title: "Weekly")
    let na = CommitmentRegister.load(folder: la)
    expect(back == 2 && Set(na.map(\.id)) == [c1, c2, c3] && na.count == 3, "A2: moved back once")
    expect(na.first { $0.id == c1 }?.status == "done" && CommitmentRegister.load(folder: lb).isEmpty, "A2: state kept, new register empty")
    try? fm.removeItem(atPath: base)
}

/// B7 (server ADR 5.1): the Pacenote account. Sign-in scopes, the auth URL without offline access, the server's
/// replies (TokenPair, /v1/me, /v1/devices, problems), the request body and the Keychain session.
func pacenoteAccountB7() {
    expect(GoogleScopes.signIn == ["openid", "email", "profile"], "B7: sign-in scopes only")
    expect(!GoogleScopes.signIn.contains { $0.contains("drive") || $0.contains("calendar") }, "B7: no data scopes")
    let u = GoogleOAuth.authURL(client: "cid", redirect: "http://127.0.0.1:5000", scopes: GoogleScopes.signIn, state: "st",
                                challenge: "ch", offline: false).absoluteString
    expect(!u.contains("access_type") && !u.contains("include_granted_scopes") && !u.contains("consent"), "B7: no offline access, no forced consent")
    expect(u.contains("prompt=select_account") && u.contains("scope=openid%20email%20profile") && u.contains("code_challenge_method=S256"), "B7: auth URL")
    let old = GoogleOAuth.authURL(client: "cid", redirect: "http://127.0.0.1:5000", scopes: ["openid"], state: "st", challenge: "ch").absoluteString
    expect(old.contains("access_type=offline") && old.contains("prompt=consent%20select_account"), "B7: the Google accounts flow unchanged")
    // server address
    expect(PacenoteServer.baseURL(override: nil).absoluteString == "https://pacenote-api.bodco.pm", "B7: default server")
    expect(PacenoteServer.baseURL(override: "https://dev.example.com/").absoluteString == "https://dev.example.com", "B7: https override, slash dropped")
    expect(PacenoteServer.baseURL(override: "http://127.0.0.1:8000").absoluteString == "http://127.0.0.1:8000", "B7: local http")
    expect(PacenoteServer.baseURL(override: "http://example.com").absoluteString == PacenoteServer.defaultURL, "B7: plain http elsewhere refused")
    expect(PacenoteServer.baseURL(override: "nonsense").absoluteString == PacenoteServer.defaultURL, "B7: garbage refused")
    // tokens
    let now = Date(timeIntervalSince1970: 1_000_000)
    let t = PacenoteServer.tokens(["access_token": "pna_x", "access_expires_in": 900, "refresh_token": "pnr_y", "refresh_expires_in": 5_184_000], now: now)
    expect(t?.access == "pna_x" && t?.refresh == "pnr_y", "B7: token pair")
    expect(t?.accessExpires == now.addingTimeInterval(840) && t?.refreshExpires == now.addingTimeInterval(5_184_000), "B7: expiry a minute early")
    expect(PacenoteServer.tokens(["access_token": "a"], now: now) == nil && PacenoteServer.tokens([:]) == nil, "B7: incomplete pair")
    // me and devices
    let me = PacenoteServer.me(["user": ["id": "u1", "email": "mike@example.com", "name": "Mike"],
                                "organizations": [["id": "o1", "name": "Mike's workspace", "kind": "personal", "org_role": "owner", "plan": "beta"], ["name": "no id"]]])
    expect(me?.email == "mike@example.com" && me?.name == "Mike" && me?.orgs.count == 1, "B7: me")
    expect(me?.orgs.first == PacenoteServer.Org(id: "o1", name: "Mike's workspace", kind: "personal", role: "owner", plan: "beta"), "B7: personal organization")
    expect(PacenoteServer.me(["organizations": []]) == nil, "B7: me without a user")
    let ds = PacenoteServer.devices([
        ["id": "d1", "name": "Emily's Mac", "platform": "macos", "app_version": "0.11.0", "last_seen_at": "2026-11-15T09:00:00.123456+00:00", "current": false],
        ["id": "d2", "name": "Mike's MacBook Pro", "platform": "macos", "app_version": "0.11.0", "last_seen_at": "2026-11-14T09:00:00+00:00", "current": true],
        ["id": "d3", "name": "Old", "platform": "macos", "app_version": "0.10.2", "last_seen_at": NSNull(), "current": false],
        ["name": "no id"]])
    expect(ds.map(\.id) == ["d2", "d1", "d3"], "B7: this Mac first, then the latest")
    expect(ds[1].lastSeen != nil && ds[0].lastSeen != nil && ds[2].lastSeen == nil, "B7: dates with and without fractions")
    // the sign-in body: exactly the fields the server allows
    let body = PacenoteServer.signInBody(idToken: "h.p.s", deviceName: "  " + String(repeating: "M", count: 120), appVersion: "0.11.0")
    let bo = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    let dev = bo["device"] as? [String: Any] ?? [:]
    expect(Set(bo.keys) == ["id_token", "device"] && Set(dev.keys) == ["name", "platform", "app_version"], "B7: body fields")
    expect((dev["name"] as? String)?.count == 100 && dev["platform"] as? String == "macos" && bo["id_token"] as? String == "h.p.s", "B7: device name capped")
    let empty = (try? JSONSerialization.jsonObject(with: PacenoteServer.signInBody(idToken: "x", deviceName: " ", appVersion: ""))) as? [String: Any]
    expect((empty?["device"] as? [String: Any])?["name"] as? String == "Mac" && (empty?["device"] as? [String: Any])?["app_version"] as? String == "dev", "B7: defaults")
    // problems and the refresh rule
    expect(PacenoteServer.problem(Data(#"{"type":"about:blank","title":"Unauthorized","status":401,"detail":"invalid Google token"}"#.utf8), status: 401) == "invalid Google token", "B7: problem detail")
    expect(PacenoteServer.problem(Data(#"{"title":"Too Many Requests","status":429}"#.utf8), status: 429) == "Too Many Requests", "B7: problem title")
    expect(PacenoteServer.problem(Data("<html>".utf8), status: 502) == "HTTP 502", "B7: no raw body")
    expect(PacenoteServer.refreshEndsSession(status: 401) && !PacenoteServer.refreshEndsSession(status: 0)
           && !PacenoteServer.refreshEndsSession(status: 503) && !PacenoteServer.refreshEndsSession(status: 429), "B7: only 401 ends the session")
    // the Keychain session
    let ses = PacenoteServer.Session(refreshToken: "pnr_y", refreshExpires: now, email: "mike@example.com", name: "Mike", signedIn: now)
    expect(PacenoteServer.Session.decode(ses.encoded()) == ses && PacenoteServer.Session.decode("junk") == nil && PacenoteServer.Session.decode(nil) == nil, "B7: session round trip")
    expect(SecretStore.Key.pacenoteSession.rawValue == "pacenote_session", "B7: Keychain key")
}

// 0.11.0 (B7b, server ADR 3.3, 3.4, 3.7): Drive folder ids kept per account, what a Drive answer means for a saved
// folder, the transcript .md, the new meta fields read from older files.
func pacenoteDriveB7b() {
    // migration from UserDefaults (0.9.5-0.10.2)
    let old = ["driveFolder|Mike@Example.com|root|Pacenote": "R1", "driveFolder|Mike@Example.com|R1|Orbit": "P1",
               "driveFolder|Mike@Example.com|R1|Calls": "P2", "driveFolder|Mike@Example.com|X9|Pacenote spike A": "S1",
               "driveFolder|emily@example.com|root|Other": "O1", "driveFolder|bad": "Z"]
    let m = DriveFolderStore.migrated(DriveFolderStore(), defaults: old)
    let a = m.account("mike@example.com")
    expect(a.root == DriveFolderStore.Folder(id: "R1", name: "Pacenote"), "B7b: the root migrates, email in any case")
    expect(a.projects.count == 2 && a.projects["Orbit"]?.id == "P1" && a.projects["Calls"]?.id == "P2", "B7b: project folders under the root migrate")
    expect(a.projects["Pacenote spike A"] == nil && m.account("emily@example.com").root == nil, "B7b: spike folders and other names stay out")
    var kept = DriveFolderStore(); kept.setRoot("mike@example.com", .init(id: "NEW", name: "Calls archive", driveId: "D1"))
    let m2 = DriveFolderStore.migrated(kept, defaults: old)
    expect(m2.account("mike@example.com").root?.id == "NEW" && m2.account("mike@example.com").projects.isEmpty, "B7b: the store wins over old keys")
    var st = m; st.setRoot("emily@example.com", .init(id: "E1", name: "Pacenote")); st.reset("MIKE@example.com")
    expect(st.account("mike@example.com").root == nil && st.account("emily@example.com").root?.id == "E1", "B7b: Use default forgets one account")
    let sp = NSTemporaryDirectory() + "pn-b7b-\(UUID().uuidString)/drive-folders.json"
    m.save(sp)
    expect(DriveFolderStore.load(sp) == m, "B7b: store round trip")
    try? Data(#"{"accounts":{"x@y.z":{"root":{"id":"R"}}}}"#.utf8).write(to: URL(fileURLWithPath: sp))
    expect(DriveFolderStore.load(sp)?.account("x@y.z").root?.id == "R" && DriveFolderStore.load(sp)?.account("x@y.z").projects.isEmpty == true, "B7b: missing fields default")
    try? FileManager.default.removeItem(atPath: (sp as NSString).deletingLastPathComponent)

    // a Drive answer about a saved folder
    typealias S = DriveFolderState
    expect(S.of(status: 200, body: ["id": "x"]) == .ok, "B7b: 200 is there")
    expect(S.of(status: 200, body: ["trashed": true]) == .unavailable, "B7b: in the trash is gone")
    expect(S.of(status: 200, body: ["capabilities": ["canAddChildren": false]]) == .unavailable, "B7b: no write access is gone")
    expect(S.of(status: 404, body: [:]) == .unavailable, "B7b: 404 is gone")
    expect(S.of(status: 403, body: ["error": ["errors": [["reason": "insufficientFilePermissions"]]]]) == .unavailable, "B7b: 403 permissions is gone")
    expect(S.of(status: 403, body: ["error": ["errors": [["reason": "userRateLimitExceeded"]]]]) == .retry, "B7b: 403 rate limit is later")
    expect(S.of(status: 0, body: [:]) == .retry && S.of(status: 401, body: [:]) == .retry && S.of(status: 429, body: [:]) == .retry
           && S.of(status: 503, body: [:]) == .retry, "B7b: network, token, limits and server errors keep the id")
    expect(S.kind(driveId: "0AB") == "shared_drive" && S.kind(driveId: "") == "my_drive" && S.kind(driveId: nil) == "my_drive", "B7b: drive kind")

    // settings
    let rs = try? JSONDecoder().decode(RecordingSettings.self, from: Data(#"{"drive":"auto"}"#.utf8))
    expect(rs?.transcriptDrive == "off" && rs?.drive == "auto", "B7b: transcript in Drive is off by default")
    let rs2 = try? JSONDecoder().decode(RecordingSettings.self, from: Data(#"{"transcriptDrive":"every_call"}"#.utf8))
    let rs3 = try? JSONDecoder().decode(RecordingSettings.self, from: Data(#"{"transcriptDrive":"always"}"#.utf8))
    expect(rs2?.transcriptDrive == "every_call" && rs3?.transcriptDrive == "off", "B7b: transcript setting values")
    expect(TranscriptInDrive.allCases.map(\.rawValue) == ["off", "with_recording", "every_call"], "B7b: three choices")

    // meta: older files without the new fields
    let oldPart = #"{"schema":1,"title":"Weekly","project":"Orbit","parts":[{"file":"a.recording.mp4","kind":"video","started":"2026-11-05T14:30:00Z","seconds":60,"bytes":10,"driveID":"F1","driveLink":"L","driveAccount":"mike@example.com","driveError":""}]}"#
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    let om = try? dec.decode(RecordingMeta.self, from: Data(oldPart.utf8))
    expect(om?.parts.first?.driveID == "F1" && om?.parts.first?.driveFolderID == "" && om?.parts.first?.driveKind == "", "B7b: old meta reads, new fields empty")
    let bare = #"{"schema":1,"title":"","project":"","parts":[{"file":"b.recording.m4a","kind":"audio","started":"2026-11-05T14:30:00Z"}]}"#
    let bm = try? dec.decode(RecordingMeta.self, from: Data(bare.utf8))
    expect(bm?.parts.first?.seconds == 0 && bm?.parts.first?.source == "" && bm?.notUploaded.isEmpty == true, "B7b: a part with only the first fields")
    var nm = om!; nm.parts[0].driveFolderID = "P1"; nm.parts[0].driveKind = "shared_drive"
    let mp = NSTemporaryDirectory() + "pn-b7b-\(UUID().uuidString)/x.recording.json"
    nm.save(mp)
    expect(RecordingMeta.load(mp) == nm, "B7b: new fields round trip")
    try? FileManager.default.removeItem(atPath: (mp as NSString).deletingLastPathComponent)

    // the transcript file
    var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
    let start = cal.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 14, minute: 30))!
    expect(DriveTranscript.fileName(title: "Weekly sync", start: start) == "2026-11-05 14.30 Weekly sync.md", "B7b: transcript name like the video's")
    expect(DriveTranscript.fileName(title: "A/B review ", start: start) == "2026-11-05 14.30 A-B review.md"
           && DriveTranscript.fileName(title: "", start: start) == "2026-11-05 14.30 Call.md", "B7b: name cleaned")
    let tr = """
    # Live transcript: Weekly sync

    - Project: orbit
    - Model: mlx-community/whisper-large-v3-turbo

    [14:30:05] Me (en): Hi everyone (2.1s)
    [14:30:09] Them [S2] (en): Hi Mike
    [14:30:12] Emily (en): Morning
    [14:30:15] Them (en):  (0.4s)

    --- end of recording 14:31:00 ---
    """
    let ls = DriveTranscript.lines(tr)
    expect(ls.count == 3, "B7b: spoken lines only (\(ls.count))")
    expect(ls.first == DriveTranscript.Line(time: "14:30:05", who: "Me", text: "Hi everyone"), "B7b: the timing is dropped")
    expect(ls.count > 2 && ls[1].who == "Them 2" && ls[2].who == "Emily", "B7b: an unnamed speaker keeps its number, a named one its name")
    let h = DriveTranscript.Header(title: "Weekly sync", start: start, minutes: 31, project: "Orbit", participants: ["Emily", "Mike"])
    let md = DriveTranscript.render(h, transcript: tr)
    expect(md.hasPrefix("# Weekly sync\n") && md.contains("- Duration: 31 min") && md.contains("- Project: Orbit")
           && md.contains("- Participants: Emily, Mike") && md.contains("**14:30:09 Them 2:** Hi Mike"), "B7b: header and lines")
    expect(!md.contains("Model:") && !md.contains("end of recording") && !md.contains("whisper"), "B7b: no internal header lines")
    let empty = DriveTranscript.render(.init(title: "", start: start, minutes: nil, project: "", participants: []), transcript: "# x\n")
    expect(empty.hasPrefix("# Call\n") && !empty.contains("Duration") && !empty.contains("Project") && empty.contains("No speech"), "B7b: an empty call")
    expect(DriveTranscript.hash(md) == DriveTranscript.hash(md) && DriveTranscript.hash(md) != DriveTranscript.hash(md + " "), "B7b: hash")
    expect(DriveTranscript.metaPath(transcript: "/p/live/x.app.md") == "/p/live/x.app.drive.json", "B7b: drive meta next to the transcript")
    let dir = NSTemporaryDirectory() + "pn-b7b-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let t = dir + "/2026-11-05-1430-weekly.app.md"
    try? "x".write(toFile: t, atomically: true, encoding: .utf8)
    expect(DriveTranscript.source(transcript: t) == t, "B7b: the transcript when there is no named copy")
    try? "y".write(toFile: dir + "/2026-11-05-1430-weekly.app.named.md", atomically: true, encoding: .utf8)
    expect(DriveTranscript.source(transcript: t) == dir + "/2026-11-05-1430-weekly.app.named.md", "B7b: the named copy first")
    var dm = DriveTranscriptMeta(); dm.fileID = "T1"; dm.kind = "my_drive"; dm.hash = "abc"
    dm.save(DriveTranscript.metaPath(transcript: t))
    expect(DriveTranscriptMeta.load(DriveTranscript.metaPath(transcript: t)) == dm, "B7b: transcript meta round trip")
    try? FileManager.default.removeItem(atPath: dir)

    // the organization's policy
    let me = PacenoteServer.me(["user": ["email": "mike@example.com"], "organizations": [
        ["id": "o1", "name": "Mike's workspace", "kind": "personal", "policy": ["require_transcript_in_drive": false]],
        ["id": "o2", "name": "Acme", "kind": "team", "policy": ["require_transcript_in_drive": true]]]])
    expect(me?.transcriptRequiredBy == "Acme" && me?.orgs.first?.requireTranscriptInDrive == false, "B7b: the policy names the organization")
    expect(PacenoteServer.me(["user": ["email": "a@b.c"], "organizations": [["id": "o1"]]])?.transcriptRequiredBy == nil, "B7b: no policy, not required")
}

// 0.12.2 (L1): one rule for Decisions, Tasks and Risks (CallLists)
func callLists0122() {
    let live: [String: Any] = ["kind": "situation", "decisions": ["Ship on Friday", "Немає."],
        "actions": [["what": "Send the deck", "due": "Monday", "t": "10:05:00"]],
        "theirs": [["who": "Mike", "what": "Share the budget"]], "risks": [["what": "Budget not approved"]]]
    var r = CallLists.resolve(situations: [live], notes: nil)
    expect(r.decisions == ["Ship on Friday"] && r.decisionsFrom == .live, "L1: live decisions, nothing line dropped")
    expect(r.risks == ["Budget not approved"] && r.risksFrom == .live, "L1: live risks")
    expect(r.tasks.count == 2 && r.tasks[0].mine == true && r.tasks[0].due == "Monday" && r.tasks[1].owner == "Mike" && r.tasks[1].mine == false, "L1: live tasks, mine and theirs")
    expect(r.tasks[1].line == "Mike: Share the budget", "L1: task line")

    let mn = "# Call notes\n\n## Meeting notes\n\n### TL;DR\nShort.\n\n### Decisions\n- [10:01:00] **Go with plan B**\n- Go with plan B\n\n### Action items\n- **Emily**: draft the contract (due: Friday)\n- **Mike:** review the draft\n- Book the room\n\n### Risks\n- Vendor may slip\n\n## Decisions\n- Old decision\n"
    r = CallLists.resolve(situations: [live], notes: mn)
    expect(r.decisions == ["Go with plan B"] && r.decisionsFrom == .notes, "L1: notes beat the live picture, repeats dropped")
    expect(r.decisionItems.map(\.t) == ["10:01:00"], "L2: notes decisions keep their time")
    expect(CallSync.decisions(r).map { $0["text"] as? String } == ["Go with plan B"], "L2: sync sends the one-rule decisions")
    expect(r.risks == ["Vendor may slip"] && r.risksFrom == .notes, "L1: notes risks (schema 3)")
    expect(r.riskItems.first?.t == "", "L3: a risk without a time")
    if var mm = MeetingNotes.parse(mn) {
        mm.risks = [MeetingNotes.Item(t: "10:09:00", text: "Vendor may slip")]
        let lab = MeetingNotes.Labels(title: "", tldr: "TL;DR", decisions: "Decisions", actions: "Action items", open: "Open", topics: "Topics", unclear: "Unclear")
        expect(!MeetingNotes.markdown(mm, lab).contains("Vendor"), "L3: no Risks without its label")
        expect(MeetingNotes.markdown(mm, lab.withRisks("Risks")).contains("## Risks\n\n- [10:09] Vendor may slip"), "L3: Risks in Copy and Export")
    } else { expect(false, "L3: notes parse") }
    expect(r.tasksFrom == .notes && r.tasks.count == 3, "L1: notes tasks beat live actions")
    expect(r.tasks[0].owner == "Emily" && r.tasks[0].text == "draft the contract" && r.tasks[0].due == "Friday" && r.tasks[0].mine == nil, "L1: owner and due parsed")
    expect(r.tasks[1].owner == "Mike" && r.tasks[1].text == "review the draft", "L1: bold owner with the colon inside")
    expect(r.tasks[2].owner.isEmpty && r.tasks[2].text == "Book the room", "L1: task without owner")

    let empty = "## Meeting notes\n\n### Decisions\n- Жодних рішень не приймалося.\n\n### Action items\n- None\n"
    r = CallLists.resolve(situations: [live], notes: empty)
    expect(r.decisionsFrom == .live && r.tasksFrom == .live && r.risksFrom == .live, "L1: nothing-only notes fall through")

    var editRisks = live; editRisks["source"] = "call_page"; editRisks["lists"] = ["risks"]; editRisks["risks"] = [["what": "Legal review"]]
    r = CallLists.resolve(situations: [live, editRisks], notes: mn)
    expect(r.risks == ["Legal review"] && r.risksFrom == .pm, "L1: the PM's risks edit wins")
    expect(r.decisions == ["Go with plan B"] && r.decisionsFrom == .notes, "L1: a risks edit does not freeze decisions")

    var editAll = live; editAll["source"] = "call_page"; editAll["decisions"] = [String](); editAll["risks"] = [[String: Any]]()
    r = CallLists.resolve(situations: [live, editAll], notes: mn)
    expect(r.decisions.isEmpty && r.decisionsFrom == .pm && r.risks.isEmpty && r.risksFrom == .pm, "L1: an old edit line covers all, an empty edit counts")
    expect(CallSync.decisions(r).isEmpty, "L2: the PM removed all decisions, the server gets none")
    let later: [String: Any] = ["kind": "situation", "decisions": ["Later live"]]
    r = CallLists.resolve(situations: [live, editAll, later], notes: nil)
    expect(r.decisionsFrom == .pm, "L1: a live line after the edit does not undo it")

    let old = "# Call notes\n## Summary\nx\n## Decisions\n- **Keep the old API**\n- None\n## Action items\n- **Mike**: send notes\n## Concerns and mood\n- calm\n"
    r = CallLists.resolve(situations: [], notes: old)
    expect(r.decisions == ["Keep the old API"] && r.decisionsFrom == .legacy, "L1: older notes sections last")
    expect(r.tasks.first?.owner == "Mike" && r.tasksFrom == .legacy && r.risks.isEmpty && r.risksFrom == .none, "L1: older tasks, no older risks")
    expect(CallLists.resolve(situations: [], notes: nil) == CallLists.Lists(), "L1: nothing at all")
    expect(MeetingNotes.parse(mn)?.risks.map(\.text) == ["Vendor may slip"], "L1: meeting notes read ### Risks")

    // 0.12.2 (L4): server tasks from the register, else the one-rule tasks
    let regEv: [[String: Any]] = [
        ["op": "add", "id": "c-1", "text": "Send the deck", "owner": "me", "call": "x.app.md", "created": "2026-11-13T10:00:00+02:00", "due": "2026-11-20"],
        ["op": "link", "id": "c-1", "notion_page": "abc123"],
        ["op": "add", "id": "c-2", "text": "Share the budget", "owner": "Mike", "call": "x.app.md", "created": "2026-11-13T10:00:00+02:00"],
        ["op": "drop", "id": "c-2"]]
    let regItems = CommitmentRegister.fold(regEv)
    let lst = CallLists.resolve(situations: [live], notes: mn)
    let st = CallSync.tasks(register: regItems, lists: lst, me: "Emily")
    expect(st.count == 2 && st[0]["assignee"] as? String == "Emily" && st[0]["due_date"] as? String == "2026-11-20" && st[0]["notion_url"] == nil,
           "L4: a register item with the PM's name, its day and no fake Notion link")
    expect(st[1]["assignee"] as? String == "Mike" && st[1]["status"] as? String == "dropped" && st[1]["due_date"] == nil, "L4: their item, dropped")
    let fb = CallSync.tasks(register: [], lists: lst, me: "")
    expect(fb.count == 3 && fb[0]["assignee"] as? String == "Emily" && fb.allSatisfy { ($0["status"] as? String) == "open" }, "L4: no register, the notes tasks")
    expect(CallSync.tasks(register: [], lists: CallLists.Lists(), me: "Emily").isEmpty, "L4: nothing to send")
    expect(CallSync.risks(lst).map { $0["text"] as? String } == ["Vendor may slip"], "L3: server risks by the one rule")
    expect(CallSync.partMissing("risks", status: 404) && CallSync.partMissing("risks", status: 405), "L3: an old server without risks")
    expect(!CallSync.partMissing("tasks", status: 404) && !CallSync.partMissing("risks", status: 410), "L3: other parts and 410 as before")
    let dir = NSTemporaryDirectory() + "pn-l1-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let t = dir + "/2026-11-15-1000-sync.app.md"
    let lines = [live, editRisks].map { String(data: try! JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), encoding: .utf8)! }
    try? (["{\"kind\":\"tip\",\"text\":\"x\"}"] + lines).joined(separator: "\n").write(toFile: t + ".tips.jsonl", atomically: true, encoding: .utf8)
    try? mn.write(toFile: dir + "/2026-11-15-1000-sync.app.notes.md", atomically: true, encoding: .utf8)
    r = CallLists.read(transcript: t)
    expect(r.decisionsFrom == .notes && r.risksFrom == .pm && r.tasksFrom == .notes, "L1: read from the call's files")
    try? FileManager.default.removeItem(atPath: dir)
}

/// 0.13.0 (B8 part 2, step 1): the consent record of a call in its tips files.
func callConsent0130() {
    let t0 = Date(timeIntervalSince1970: 1_763_200_000)
    let l = CallConsent.line(mode: .said, at: t0, recorded: true)
    expect((l["kind"] as? String) == "consent" && (l["mode"] as? String) == "said" && (l["recorded"] as? Bool) == true, "consent: line shape")
    expect(Set(l.keys) == ["kind", "mode", "at", "recorded", "source"], "consent: no text, no names in the line")
    expect(CallConsent.resolve([]).mode == .unknown && CallConsent.resolve([]).at == nil, "consent: no lines = unknown")
    let e = { (m: CallConsent.Mode, s: Double) in CallConsent.Event(mode: m, at: t0.addingTimeInterval(s)) }
    expect(CallConsent.resolve([e(.none, 0)]).mode == .none, "consent: off = none")
    var r = CallConsent.resolve([e(.posted, 5)])
    expect(r.mode == .posted && r.at == t0.addingTimeInterval(5), "consent: copied for the chat = posted")
    r = CallConsent.resolve([e(.posted, 60), e(.said, 9), e(.none, 1)])
    expect(r.mode == .said && r.at == t0.addingTimeInterval(9) && r.posted == t0.addingTimeInterval(60), "consent: the earliest given wins over none")
    expect(CallConsent.resolve([CallConsent.Event(mode: .unknown, at: t0)]).mode == .unknown, "consent: an unknown event changes nothing")
    r = CallConsent.resolve([e(.said, 30), e(.said, 10)])
    expect(r.said == t0.addingTimeInterval(10), "consent: the first said time")
    let text = ["{\"kind\":\"tip\",\"text\":\"consent is a word\"}", "not json consent",
                "{\"kind\":\"consent\",\"mode\":\"weird\",\"at\":\"2026-11-15T10:00:00Z\"}",
                "{\"kind\":\"consent\",\"mode\":\"said\",\"at\":\"bad\"}",
                "{\"kind\":\"consent\",\"mode\":\"said\",\"at\":\"2026-11-15T10:02:00.250Z\"}",
                "{\"kind\":\"consent\",\"mode\":\"copied\",\"at\":\"2026-11-15T10:03:00Z\"}",
                "{\"kind\":\"consent\",\"mode\":\"unknown\",\"at\":\"2026-11-15T10:03:00Z\"}"].joined(separator: "\n")
    let ev = CallConsent.events(in: text)
    expect(ev.count == 1 && ev[0].mode == .said && ev[0].source == "app", "consent: only valid consent lines, fractional seconds read")
    let dir = NSTemporaryDirectory() + "pn-consent-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let tr = dir + "/2026-11-15-1000-sync.app.md"
    expect(CallConsent.read(transcript: tr).mode == .unknown, "consent: a call without tips files = unknown")
    try? "{\"kind\":\"situation\",\"decisions\":[\"x\"]}\n".write(toFile: tr + ".tips.jsonl", atomically: true, encoding: .utf8)
    expect(CallConsent.record(path: tr + ".tips.jsonl", mode: .none, at: t0), "consent: append none")
    expect(!CallConsent.record(path: tr + ".tips.jsonl", mode: .unknown), "consent: unknown is never written")
    expect(CallConsent.read(transcript: tr).mode == .none, "consent: read none from the app's tips file")
    expect(CallConsent.record(path: dir + "/2026-11-15-1000-sync.app.tips.jsonl", mode: .posted, at: t0.addingTimeInterval(40), source: "skill"),
           "consent: append to the skill's tips file (created)")
    r = CallConsent.read(transcript: tr)
    expect(r.mode == .posted && r.at == t0.addingTimeInterval(40), "consent: both tips files are read")
    let raw = (try? String(contentsOfFile: tr + ".tips.jsonl", encoding: .utf8)) ?? ""
    expect(raw.hasPrefix("{\"kind\":\"situation\"") && raw.hasSuffix("\n") && raw.split(separator: "\n").count == 2, "consent: appended, the old line kept")
    expect(CallLists.read(transcript: tr).decisions == ["x"], "consent: call lists still read the call picture")
    try? FileManager.default.removeItem(atPath: dir)
}

/// 0.13.0 (B8 part 2, step 3): the consent record and the call's numbers in the call body; never names or texts.
func callSyncAnalysis0130() {
    let t0 = Date(timeIntervalSince1970: 1_763_200_000)
    var s = CallConsent.State(); s.mode = .said; s.at = t0
    let c = CallSync.consent(s)
    expect(c["mode"] as? String == "said" && (c["at"] as? String)?.hasSuffix("Z") == true && c.count == 2, "sync0130: consent said with its time")
    let u = CallSync.consent(CallConsent.State())
    expect(u["mode"] as? String == "unknown" && u["at"] == nil, "sync0130: an older call = unknown, no time")
    expect(CallSync.analysis(tips: "", inbox: "", talkShare: nil, sheetCheck: nil) == nil, "sync0130: nothing = no analysis")
    func line(_ o: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]), encoding: .utf8)! }
    let tips = [line(["kind": "tip", "uid": "a", "gist": "secret tip text", "partial": true]),
                line(["kind": "tip", "uid": "a", "gist": "secret tip text"]),
                line(["kind": "fact", "uid": "b", "gist": "f"]),
                line(["kind": "answer", "q": "what", "gist": "x"]),
                line(["kind": "card", "uid": "c", "gist": "gone"]), line(["kind": "retract", "uid": "c"]),
                line(["kind": "situation", "decisions": ["d"]]), line(["kind": "consent", "mode": "said", "at": "2026-11-15T10:00:00Z"]),
                "broken {"].joined(separator: "\n")
    let inbox = [line(["t": "10:00:01", "text": "sos"]), line(["t": "10:00:05", "text": "SOS "]),
                 line(["t": "10:00:06", "text": "what is the budget"]),
                 line(["t": "10:01:00", "kind": "setting", "key": "tip_feedback", "value": "not_useful|tip|10:00:02|g|r=late"]),
                 line(["t": "10:01:30", "kind": "setting", "key": "tip_feedback", "value": "used|tip|10:00:02|g"]),
                 line(["t": "10:02:00", "kind": "setting", "key": "tip_feedback", "value": "not_useful|fact|10:00:09|f|c=wrong|x"]),
                 line(["t": "10:02:10", "kind": "setting", "key": "tip_feedback", "value": "partly|card|10:00:11|z"]),
                 line(["t": "10:02:20", "kind": "setting", "key": "tip_feedback", "value": "maybe|card|10:00:12|z"]),
                 line(["t": "10:02:30", "kind": "setting", "key": "proactive", "value": "on"])].joined(separator: "\n")
    let check = try! JSONSerialization.data(withJSONObject: ["questions": [["id": "1", "status": "answered"], ["id": "2", "status": "partly"],
                                                                          ["id": "3", "status": "not"]], "outcome": [["id": "o", "status": "answered"]]])
    let a = CallSync.analysis(tips: tips, inbox: inbox, talkShare: 0.4567, sheetCheck: check) ?? [:]
    expect(a["tips_shown"] as? Int == 3, "sync0130: tips shown once per uid, partial and retracted out (got \(a["tips_shown"] ?? "nil"))")
    expect(a["tips_rated_useful"] as? Int == 1 && a["tips_not_useful"] as? Int == 1, "sync0130: the last rating per tip, partly in neither")
    expect(a["ask_now_count"] as? Int == 2, "sync0130: HELP NOW counted, typed asks not")
    expect(a["talk_ratio_me"] as? Double == 0.46, "sync0130: talk share rounded")
    expect(a["sheet_topics_hit"] as? Int == 2 && a["sheet_topics_total"] as? Int == 3, "sync0130: sheet questions answered or partly")
    expect(Set(a.keys) == ["tips_shown", "tips_rated_useful", "tips_not_useful", "ask_now_count", "talk_ratio_me", "sheet_topics_hit", "sheet_topics_total"],
           "sync0130: only the server's numeric fields")
    let b = CallSync.analysis(tips: "", inbox: "", talkShare: 1.7, sheetCheck: nil) ?? [:]
    expect(b["talk_ratio_me"] as? Double == 1 && b["tips_shown"] as? Int == 0, "sync0130: talk share capped at 1")
    let cb = CallSync.callBody(projectID: "p1", title: "t", start: t0, durationS: 60, meta: [:], appVersion: "0.13.0", consent: c, analysis: a)
    let body = String(data: CallSync.json(cb), encoding: .utf8) ?? ""
    expect(cb["participants"] == nil && !body.contains("secret") && !body.contains("budget") && !body.contains("@"), "sync0130: no names, no texts, no emails")
    expect((cb["consent"] as? [String: Any])?["mode"] as? String == "said" && cb["analysis"] != nil, "sync0130: consent and analysis in the body")
    let old = CallSync.callBody(projectID: "p1", title: "t", start: t0, durationS: 60, meta: [:], appVersion: "0.13.0")
    expect(old["consent"] == nil && old["analysis"] == nil, "sync0130: without them the body is as before")
    expect(CallSync.inboxPath(transcript: "/x/2026-11-15-1000-sync.app.md") == "/x/2026-11-15-1000-sync.app.inbox.jsonl"
           && CallSync.sheetCheckPath(transcript: "/x/a.md") == "/x/a.sheet-check.json", "sync0130: file names next to the transcript")
}

func sheetPeopleD1() {
    struct P { var id: String; var you = false }
    var theirs = [P(id: "emily"), P(id: "jake")], ours = [P(id: "you", you: true), P(id: "mike")]
    expect(PeopleSides.move({ $0.id == "jake" }, from: &theirs, to: &ours, locked: { $0.you }), "d1: moved to our side")
    expect(theirs.map(\.id) == ["emily"] && ours.map(\.id) == ["you", "mike", "jake"], "d1: lists after the move")
    expect(PeopleSides.move({ $0.id == "jake" }, from: &ours, to: &theirs, locked: { $0.you }) && theirs.map(\.id) == ["emily", "jake"], "d1: and back")
    expect(!PeopleSides.move({ $0.id == "you" }, from: &ours, to: &theirs, locked: { $0.you }) && ours.first?.id == "you", "d1: you never moves")
    expect(!PeopleSides.move({ $0.id == "nobody" }, from: &ours, to: &theirs) && ours.count == 2 && theirs.count == 2, "d1: no match, no change")
    expect(PeopleSides.summary(["Emily Carter", "David Brooks", "Chris", "Jake"]) == "Emily Carter, David Brooks +2", "d1: summary with a count")
    expect(PeopleSides.summary(["Emily Carter"]) == "Emily Carter" && PeopleSides.summary([" "]) == "", "d1: summary short and empty")
    expect(PeopleSides.initials("Christopher Montgomery-Wells") == "CW" && PeopleSides.initials("mike") == "M" && PeopleSides.initials("") == "?", "d1: initials")
}

func sheetPeopleD1b() {
    expect(PeopleSides.splitGlued("Jake T. Mike J.") == ["Jake T.", "Mike J."], "d1b: glued short names split")
    expect(PeopleSides.splitGlued("Emily Carter") == ["Emily Carter"] && PeopleSides.splitGlued("John F. Kennedy") == ["John F. Kennedy"], "d1b: real names stay whole")
    expect(PeopleSides.samePerson("Emily C.", "E. Carter") && PeopleSides.samePerson("Emily C.", "Emily Carter") && PeopleSides.samePerson("e.carter", "Emily Carter"), "d1b: one person, several spellings")
    expect(!PeopleSides.samePerson("Emily C.", "Emma C.") && !PeopleSides.samePerson("E. Carter", "E. Cooper") && !PeopleSides.samePerson("Mike J.", "Mike"), "d1b: different people stay apart")
    expect(PeopleSides.samePerson("Mike", "mike") && !PeopleSides.samePerson("A. S.", "A. S."), "d1b: one word and bare initials")
    expect(PeopleSides.merge(["Jake T. Mike J.", "Emily C.", "E. Carter", "mike", "Mike Johnson"]) == ["Jake T.", "Mike Johnson", "Emily Carter", "mike"], "d1b: merge splits, joins and keeps order")
    expect(PeopleSides.merge(["Emily C.", "e.carter"]) == ["Emily Carter"], "d1b: first and last from two spellings")
    let team = ["Emily Carter", "David Brooks (Dave; D. Brooks)"]
    expect(PeopleSides.teamName(for: "Emily C.", team: team) == "Emily Carter" && PeopleSides.teamName(for: "Dave", team: team) == "David Brooks", "d1b: team member under a short name or an alias")
    expect(PeopleSides.teamName(for: "Jake T.", team: team) == nil, "d1b: not on the team")
}

// 0.15.0 (D2): search in Settings
/// 0.16.0 (D3): Settings > Components. Required parts never removed, the model needs Ollama, the agent only with
/// Claude, sizes parsed and freed space measured, jobs on the model move to the next AI when it goes, search leads
/// to the Components pane.
func componentsD3() {
    for id in ComponentCatalog.required { expect(!ComponentCatalog.canRemove(id), "d3: required \(id) is never removable") }
    for id in ComponentCatalog.optional { expect(ComponentCatalog.canRemove(id), "d3: optional \(id) is removable") }
    expect(!ComponentCatalog.canRemove("ollama") && !ComponentCatalog.canRemove("claude") && !ComponentCatalog.canRemove("x"), "d3: Ollama, Claude Code, unknown: not removable")
    expect(ComponentCatalog.needs("local_model") == "ollama" && ComponentCatalog.needs("agent") == nil, "d3: the model needs Ollama")
    expect(ComponentCatalog.setupStep("link_downloader") == "linkdl" && ComponentCatalog.setupStep("agent") == "agent"
           && ComponentCatalog.setupStep("local_model") == nil && ComponentCatalog.setupStep("whisper") == "whisper", "d3: setup.sh steps")
    expect(ComponentCatalog.offered("agent", provider: "claude") && !ComponentCatalog.offered("agent", provider: "chatgpt")
           && ComponentCatalog.offered("local_model", provider: "chatgpt"), "d3: the agent only with Claude")
    expect(ComponentCatalog.parseSize("SIZE 1048576") == 1_048_576 && ComponentCatalog.parseSize("OK 12") == nil
           && ComponentCatalog.parseSize("SIZE -1") == nil && ComponentCatalog.parseSize("SIZE") == nil, "d3: parse SIZE")
    expect(ComponentCatalog.freed(before: 16_000_000_000, after: nil) == 16_000_000_000, "d3: freed, gone entirely")
    expect(ComponentCatalog.freed(before: 100, after: 140) == 0 && ComponentCatalog.freed(before: nil, after: 5) == 0, "d3: freed never negative or guessed")
    expect(ComponentCatalog.format(16_000_000_000) == "16 GB" && ComponentCatalog.format(2_500_000_000) == "2.5 GB"
           && ComponentCatalog.format(1_000_000_000) == "1 GB" && ComponentCatalog.format(320_000_000) == "320 MB", "d3: format sizes")
    let s = ComponentCatalog.summary(picked: ["agent", "link_downloader", "whisper"], sizes: ["agent": 300_000_000])
    expect(s.count == 2 && s.bytes == 310_000_000, "d3: summary counts optional parts only, measured first: \(s)")
    // the model goes: jobs on it move to the next connected AI allowed for the job, local switched off
    let chain = AIChain.defaults()
    let r = ComponentCatalog.afterRemovingLocal(prep: "local", tips: "api", after: "local", chain: chain, connected: ["codex", "api"])
    expect(r.prep == "codex" && r.after == "codex" && r.tips == "api", "d3: jobs move to the next AI: \(r.prep) \(r.after) \(r.tips)")
    expect(r.chain.first { $0.route == "local" }?.on == false, "d3: the local step is off after removal")
    let none = ComponentCatalog.afterRemovingLocal(prep: "local", tips: "api", after: "code", chain: chain, connected: [])
    expect(none.prep == "code" && none.after == "code", "d3: nothing connected: the default route")
    let agyOnly = ComponentCatalog.afterRemovingLocal(prep: "local", tips: "local", after: "local", chain: chain, connected: ["agy"])
    expect(agyOnly.prep == "agy" && agyOnly.tips == "api", "d3: tips never move to the Gemini account")
    // search leads to Components
    let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    func load(_ l: String) -> [String: String] {
        guard let d = try? Data(contentsOf: base.appendingPathComponent("Resources/i18n/\(l).json")),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return [:] }
        return o.compactMapValues { $0 as? String }
    }
    let en = load("en"), uk = load("uk")
    let titles: (SettingsSearchEntry) -> [String] = { [en[$0.titleKey] ?? "", uk[$0.titleKey] ?? ""] }
    expect(SettingsSearch.find("remove", titles: titles).first?.pane == "components", "d3: \"remove\" opens Components")
    expect(SettingsSearch.find("видалити", titles: titles).first?.pane == "components", "d3: \"видалити\" opens Components")
    expect(SettingsSearch.find("disk space", titles: titles).first?.id == "comp.disk", "d3: \"disk space\" finds the disk line")
    for k in ["cmp.impact.local_model", "cmp.impact.agent", "cmp.impact.link_downloader"] { expect(en[k] != nil && uk[k] != nil, "d3: impact \(k)") }
    // setup.sh: size for every required step and the add-ons, remove only for the add-ons, required refused
    let sh = (try? String(contentsOf: base.appendingPathComponent("Resources/setup.sh"), encoding: .utf8)) ?? ""
    for st in ["core", "venv", "whisper", "localai", "voices", "linkdl", "agent"] { expect(sh.contains("  size:\(st)"), "d3: setup.sh size:\(st)") }
    expect(sh.contains("  remove:linkdl)") && sh.contains("  remove:agent)") && sh.contains("  remove:*) echo"), "d3: setup.sh remove only add-ons")
    expect(!sh.contains("remove:whisper") && !sh.contains("remove:localai") && !sh.contains("remove:core"), "d3: no remove for required steps")
}

/// 0.16.0 (D3, rules/whatsnew.yaml): every item in both languages, Try it exists in FeatureRegistry, versions never
/// go down; the personal filter (versions, conditions, setup done) and a new person sees nothing.
func whatsNewD3() {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    let text = (try? String(contentsOf: repo.appendingPathComponent("rules/whatsnew.yaml"), encoding: .utf8)) ?? ""
    let items = WhatsNew.parse(text)
    expect(items.count >= 3, "d3: whatsnew.yaml parsed: \(items.count)")
    let features = (try? String(contentsOf: repo.appendingPathComponent("app/Sources/LiveTips/Features.swift"), encoding: .utf8)) ?? ""
    var prev = "0"
    for i in items {
        expect(!i.id.isEmpty && !i.version.isEmpty, "d3: \(i.id) has id and version")
        expect(!i.titleEN.isEmpty && !i.titleUK.isEmpty && !i.bodyEN.isEmpty && !i.bodyUK.isEmpty, "d3: \(i.id) EN and UK")
        expect(!(i.titleEN + i.titleUK + i.bodyEN + i.bodyUK).contains("\u{2014}"), "d3: \(i.id) no long dash")
        if let t = i.tryIt { expect(features.contains("Feature(id: \"\(t)\""), "d3: \(i.id) try \(t) is in FeatureRegistry") }
        expect(!AppVersion.isNewer(prev, than: i.version), "d3: versions do not go down at \(i.id)")
        prev = i.version
    }
    expect(Set(items.map(\.id)).count == items.count, "d3: whatsnew ids unique")
    expect(items.first { $0.id == "addons" }?.setupStep == "addons", "d3: the add-ons item is a setup step")
    let q = WhatsNew.parse("items:\n  - id: a\n    version: 0.16.0\n    title_en: \"Say \\\"hi\\\" # not a comment\"\n    when: provider:claude, module:tracker # c\n  - id: b\n    version: 0.17.0\n")
    expect(q.count == 2 && q[0].titleEN == "Say \"hi\" # not a comment" && q[0].when == ["provider:claude", "module:tracker"], "d3: parse quotes and comments: \(q)")
    // the filter
    var a = WhatsNew.Item(); a.id = "a"; a.version = "0.16.0"
    var b = WhatsNew.Item(); b.id = "b"; b.version = "0.16.0"; b.when = ["provider:claude"]
    var c = WhatsNew.Item(); c.id = "c"; c.version = "0.16.0"; c.setupStep = "addons"
    var d = WhatsNew.Item(); d.id = "d"; d.version = "0.17.0"
    var e = WhatsNew.Item(); e.id = "e"; e.version = "0.15.0"
    let all = [e, a, b, c, d]
    expect(WhatsNew.pending(all, lastSeen: nil, current: "0.16.0", facts: []).map(\.id) == ["a", "c"], "d3: no saved version: since the baseline, conditions and the release")
    expect(WhatsNew.pending(all, lastSeen: "0.14.0", current: "0.16.0", facts: ["provider:claude", "done:addons"]).map(\.id) == ["a", "b", "e"], "d3: skipped versions merge, done steps hidden")
    expect(WhatsNew.pending(all, lastSeen: "0.16.0", current: "0.16.0", facts: []).isEmpty, "d3: nothing after seen")
    expect(WhatsNew.pending(all, lastSeen: "0.16.0", current: "0.17.0", facts: []).map(\.id) == ["d"], "d3: the next version only")
    expect(!WhatsNew.shouldShow(onboardingDone: false, pending: [a]) && WhatsNew.shouldShow(onboardingDone: true, pending: [a])
           && !WhatsNew.shouldShow(onboardingDone: true, pending: []), "d3: shown only after onboarding and with something new")
    let h = WhatsNew.history(all)
    expect(h.map(\.version) == ["0.17.0", "0.16.0", "0.15.0"] && h[1].items.map(\.id) == ["a", "b", "c"], "d3: history newest first, file order inside")
    expect(WhatsNew.short("0.16.0") == "0.16" && WhatsNew.short("0.16.1") == "0.16.1", "d3: short version")
}

/// 0.16.0 (D3, updates): appcast release notes to lines; whatsnew.yaml has the updates item.
func updatesD3() {
    expect(AppcastNotes.bullets(nil).isEmpty && AppcastNotes.bullets("").isEmpty, "d3u: empty notes")
    let li = "<h2>Pacenote 0.16.1</h2><ul><li>Fixes <b>Install</b> &amp; restart</li><li> Faster </li><li></li></ul>"
    expect(AppcastNotes.bullets(li) == ["Fixes Install & restart", "Faster"], "d3u: li items: \(AppcastNotes.bullets(li))")
    expect(AppcastNotes.bullets("<p>One</p><p>Two &lt;3</p>") == ["One", "Two <3"], "d3u: paragraphs")
    let many = "<ul>" + (1...9).map { "<li>\($0)</li>" }.joined() + "</ul>"
    expect(AppcastNotes.bullets(many).count == 6, "d3u: at most six lines")
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("rules/whatsnew.yaml")
    let items = WhatsNew.parse((try? String(contentsOf: url, encoding: .utf8)) ?? "")
    let u = items.first { $0.id == "updates" }
    expect(u?.version == "0.16.0" && u?.tryIt == nil, "d3u: whatsnew has updates 0.16.0 with no try")
}

func settingsSearchD2() {
    let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    func load(_ l: String) -> [String: String] {
        guard let d = try? Data(contentsOf: base.appendingPathComponent("Resources/i18n/\(l).json")),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return [:] }
        return o.compactMapValues { $0 as? String }
    }
    let en = load("en"), uk = load("uk")
    let es = SettingsSearch.entries
    let panes: Set<String> = ["account", "general", "projects", "sheet", "recording", "transcription", "integrations", "ai", "modules", "components", "usage", "help", "about"]
    expect(Set(es.map(\.id)).count == es.count, "d2: search ids are unique")
    for e in es {
        expect(panes.contains(e.pane), "d2: \(e.id) pane \(e.pane) exists")
        expect(en[e.titleKey] != nil && uk[e.titleKey] != nil, "d2: \(e.id) title \(e.titleKey) in en and uk")
        if let g = e.defaults[SettingsSearch.generalGroupKey] { expect(SettingsSearch.generalGroups.contains(g) && e.pane == "general", "d2: \(e.id) general group") }
        if let g = e.defaults[SettingsSearch.aiGroupKey] { expect(SettingsSearch.aiGroups.contains(g) && e.pane == "ai", "d2: \(e.id) ai group") }
        if let g = e.defaults[SettingsSearch.notionGroupKey] { expect(SettingsSearch.notionGroups.contains(g) && e.integration == "notion", "d2: \(e.id) notion group") }
        if let g = e.defaults[SettingsSearch.hubspotGroupKey] { expect(SettingsSearch.hubspotGroups.contains(g) && e.integration == "hubspot", "d2: \(e.id) hubspot group") }
        if e.integration != nil { expect(e.pane == "integrations", "d2: \(e.id) integration lives under Integrations") }
        if e.projectPage { expect(e.pane == "projects", "d2: \(e.id) project page lives under Projects") }
        for k in ["gen.group.", "ai.group.", "ntn.group.", "hs.group."] { _ = k }
    }
    for (p, gs) in [("gen.group.", SettingsSearch.generalGroups), ("ai.group.", SettingsSearch.aiGroups),
                    ("ntn.group.", SettingsSearch.notionGroups), ("hs.group.", SettingsSearch.hubspotGroups)] {
        for g in gs { expect(en[p + g] != nil && uk[p + g] != nil && en[p + "sub." + g] != nil && uk[p + "sub." + g] != nil, "d2: group strings \(p)\(g)") }
    }
    // every target the search jumps to carries its anchor in the app (pages that are a target as a whole need none)
    let src = (try? FileManager.default.contentsOfDirectory(at: base.appendingPathComponent("Sources/LiveTips"), includingPropertiesForKeys: nil)) ?? []
    let code = src.filter { $0.pathExtension == "swift" }.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
    for e in es where !["int.calendars", "int.google"].contains(e.id) {
        expect(code.contains("settingsAnchor(\"\(e.id)\")"), "d2: anchor for \(e.id) in the app")
    }
    let titles: (SettingsSearchEntry) -> [String] = { [en[$0.titleKey] ?? "", uk[$0.titleKey] ?? ""] }
    let key = Set(SettingsSearch.find("key", titles: titles).map(\.id))
    expect(["ai.claude", "ai.openai", "ai.gemini", "int.notion.token", "int.hubspot.key"].allSatisfy(key.contains), "d2: \"key\" finds the keys: \(key.sorted())")
    expect(Set(SettingsSearch.find("ключ", titles: titles).map(\.id)).isSuperset(of: ["ai.claude", "int.hubspot.key"]), "d2: \"ключ\" finds the keys")
    expect(SettingsSearch.find("мова", titles: titles).first?.id == "gen.lang", "d2: \"мова\" opens Language first")
    expect(SettingsSearch.find("Theme", titles: titles).first?.id == "gen.theme", "d2: a title prefix ranks first")
    expect(SettingsSearch.find("notion key", titles: titles).first?.id == "int.notion.token", "d2: two words narrow it down")
    expect(SettingsSearch.find("bant", titles: titles).map(\.id).contains("pr.sales"), "d2: synonyms find the setting")
    expect(SettingsSearch.find("zzqx", titles: titles).isEmpty, "d2: nothing for nonsense")
    expect(SettingsSearch.find("   ", titles: titles).isEmpty, "d2: nothing for an empty query")
    expect(SettingsSearch.normalize("  Ключ   API ") == "ключ api", "d2: normalize spaces and case")
    expect(SettingsSearch.normalize("Café імʼя") == "cafe ім'я", "d2: normalize accents and apostrophes")
    expect(SettingsSearch.score("ab", titles: ["Abc"], extra: "") > SettingsSearch.score("ab", titles: ["x ab"], extra: ""), "d2: prefix beats inside")
    expect(SettingsSearch.score("q", titles: ["x"], extra: "q") == 1, "d2: extra words still match")
    let gen = SettingsSearch.entries.first { $0.id == "gen.lang" }
    expect(gen?.group == "basics", "d2: the group of an entry")
}

func orgsB6b() {
    // /v1/me of server 0.6.0 (B6b contract 1)
    let id: (String) -> String = { ["0000000" + $0, "0000", "0000", "0000", "00000000000" + $0].joined(separator: "-") }   // UUID-shaped
    let u1 = id("1"), o1 = id("a"), o2 = id("b")
    let mo: [String: Any] = [
        "user": ["id": u1, "email": "mike@example.com", "name": "Mike"], "default_org_id": o2, "pending_invites": 1,
        "organizations": [
            ["id": o1, "name": "Mike's workspace", "kind": "personal", "org_role": "owner", "plan": "solo",
             "flags": ["teams": false, "c_level": false, "org_projects": false], "quotas": ["seats_max": ["used": 0, "limit": 1]],
             "policy": ["share_meeting_sheets": true, "allow_private_calls": true],
             "leads_teams": [], "c_level": false, "heads_departments": [], "visible_to_manager": false, "visible_to": []],
            ["id": o2, "name": "Acme", "kind": "team", "org_role": "member", "plan": "enterprise", "flags": ["org_projects": true],
             "policy": ["allow_private_calls": false], "leads_teams": [], "c_level": false, "visible_to_manager": true,
             "visible_to": ["c_level", "team_lead", "boss"]]]]
    guard let me = PacenoteServer.me(mo) else { expect(false, "b6b: me parses"); return }
    expect(me.userID == u1 && me.defaultOrgID == o2 && me.pendingInvites == 1 && me.orgs.count == 2, "b6b: me fields")
    expect(me.personal?.id == o1 && me.defaultOrg?.id == o2 && me.showsOrgFilter, "b6b: personal, default, filter shown")
    let acme = me.org(o2)!
    expect(acme.orgProjects && !acme.allowPrivateCalls && acme.visibleTo == ["c_level", "team_lead"], "b6b: Acme flags, policy, visible_to (unknown dropped)")
    expect(me.personal!.allowPrivateCalls && !me.personal!.orgProjects && me.personal!.visibleTo.isEmpty, "b6b: personal defaults")
    expect(PacenoteServer.me(["user": ["email": "a@b.c"], "organizations": [["id": o1, "kind": "personal"]]])?.defaultOrg?.id == o1,
           "b6b: no default_org_id (old server): the personal one")
    var gone = me; gone.defaultOrgID = id("d")
    expect(gone.defaultOrg?.id == o1, "b6b: a default the person left falls back to personal")
    var one = me; one.orgs = [me.personal!]
    expect(!one.showsOrgFilter, "b6b: one organization, no filter")
    // the old field visible_to_manager alone still shows a badge
    let old = PacenoteServer.me(["user": ["email": "a@b.c"], "organizations": [["id": o2, "kind": "team", "visible_to_manager": true]]])
    expect(old?.orgs.first?.visibleTo == ["team_lead"], "b6b: visible_to_manager without visible_to")
    // the badge (contract 1)
    var o = acme
    expect(PacenoteServer.visibilityKey(o, isPrivate: false) == "org.visible.both", "b6b: both")
    o.visibleTo = ["team_lead"]; expect(PacenoteServer.visibilityKey(o, isPrivate: false) == "org.visible.lead", "b6b: lead")
    o.visibleTo = ["c_level"]; expect(PacenoteServer.visibilityKey(o, isPrivate: false) == "org.visible.leadership", "b6b: leadership")
    o.visibleTo = []; expect(PacenoteServer.visibilityKey(o, isPrivate: false) == nil, "b6b: nobody")
    expect(PacenoteServer.visibilityKey(acme, isPrivate: true) == nil && PacenoteServer.visibilityKey(nil, isPrivate: false) == nil, "b6b: private or unknown: no badge")
    o.shareMeetingSheets = false; o.visibleTo = ["team_lead"]
    expect(PacenoteServer.visibilityKey(o, isPrivate: false) == "org.visible.lead", "b6b: the badge does not depend on share_meeting_sheets")
    // Manage organization (contract 6)
    var m = acme
    expect(!m.canManage, "b6b: a member does not manage")
    m.leadsTeams = ["t1"]; expect(m.canManage, "b6b: a lead manages")
    m.leadsTeams = []; m.cLevel = true; expect(m.canManage, "b6b: C-level manages")
    m.cLevel = false; m.role = "admin"; expect(m.canManage, "b6b: admin manages")
    expect(!me.personal!.canManage, "b6b: never the personal space")
    expect(PacenoteServer.adminURL(orgID: o2).absoluteString == "https://pacenote-admin.bodco.pm/org/" + o2, "b6b: console URL")
    let lead = PacenoteServer.me(["user": ["email": "a@b.c"], "organizations": [["id": o2, "kind": "team", "leads_teams": [["id": "t9", "name": "Sales"]]]]])
    expect(lead?.orgs.first?.leadsTeams == ["t9"], "b6b: leads_teams as objects too")
    // private calls (contract 5)
    expect(!PacenoteServer.privateAllowed(acme, alreadyPrivate: false) && PacenoteServer.privateAllowed(acme, alreadyPrivate: true), "b6b: policy off, a private call stays private")
    expect(PacenoteServer.privateAllowed(me.personal, alreadyPrivate: false) && PacenoteServer.privateAllowed(nil, alreadyPrivate: false), "b6b: allowed by default")
    expect(CallSync.privateRefused(status: 422, problem: "private calls are off in this organization") && !CallSync.privateRefused(status: 422, problem: "invalid fields: project_id"), "b6b: 422 private")
    // invites (contract 2)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let inv = PacenoteServer.invites([
        ["id": "i1", "org_id": o2, "org_name": "Acme", "org_role": "member", "team_name": "Sales", "invited_by_name": "Emily",
         "created_at": "2027-01-01T00:00:00Z", "expires_at": "2027-02-01T00:00:00.123+00:00"],
        ["id": "i2", "org_id": o2, "org_name": "Old", "org_role": "member", "team_name": NSNull(), "expires_at": "2020-01-01T00:00:00Z"],
        ["id": "i3", "org_name": "no org"]], now: now)
    expect(inv.map(\.id) == ["i1"] && inv[0].teamName == "Sales" && inv[0].invitedBy == "Emily" && inv[0].expires != nil, "b6b: invites, expired and broken dropped")
    let ab = (try? JSONSerialization.jsonObject(with: PacenoteServer.acceptBody(makeDefault: false))) as? [String: Any]
    expect(ab?["make_default"] as? Bool == false && ab?.count == 1, "b6b: accept body")
    expect(PacenoteServer.acceptProblem(status: 200) == nil && PacenoteServer.acceptProblem(status: 404) == "org.invite.err.gone"
           && PacenoteServer.acceptProblem(status: 410) == "org.invite.err.expired" && PacenoteServer.acceptProblem(status: 402) == "org.invite.err.seats"
           && PacenoteServer.acceptProblem(status: 500) == "org.invite.err.other", "b6b: accept answers")
    let dp = (try? JSONSerialization.jsonObject(with: PacenoteServer.defaultOrgBody(o1, me: me))) as? [String: Any]
    let dt = (try? JSONSerialization.jsonObject(with: PacenoteServer.defaultOrgBody(o2, me: me))) as? [String: Any]
    expect(dp?["default_org_id"] is NSNull && dt?["default_org_id"] as? String == o2, "b6b: PATCH /v1/me body (personal = null)")
    // organization projects (contract 4)
    let ops = PacenoteServer.orgProjects([
        ["id": "p2", "name": "Zeta", "archived": false, "member_ids": [u1]], ["id": "p1", "name": "Alpha", "member_ids": [u1, "x"]],
        ["id": "p3", "name": "Not mine", "member_ids": ["x"]], ["id": "p4", "name": "Old", "archived": true, "member_ids": [u1]], ["name": "no id"]], me: u1)
    expect(ops.map(\.id) == ["p1", "p2"], "b6b: only my projects, not archived, by name")
    // the organization of a call (D36)
    expect(PacenoteServer.orgForCall(stored: "", onServer: false, linkedOrg: "", me: me) == o2, "b6b: a new call goes to the default")
    expect(PacenoteServer.orgForCall(stored: "", onServer: true, linkedOrg: "", me: me) == o1, "b6b: a call synced before 0.17 is personal")
    expect(PacenoteServer.orgForCall(stored: o1, onServer: true, linkedOrg: o2, me: me) == o1, "b6b: a call keeps its organization")
    expect(PacenoteServer.orgForCall(stored: "", onServer: false, linkedOrg: o2, me: one) == o1, "b6b: a link to an organization left is ignored")
    expect(PacenoteServer.orgForCall(stored: o2, onServer: true, linkedOrg: "", me: one) == o1, "b6b: left the organization: the call goes home")
    expect(PacenoteServer.orgForCall(stored: "", onServer: false, linkedOrg: o2, me: me) == o2, "b6b: a linked project's call goes to its organization")
    expect(PacenoteServer.orgForCall(stored: "x", onServer: false, linkedOrg: "", me: nil) == "x", "b6b: account not known yet")
    // what a call sends
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let pb = CallSync.callBody(projectID: "p", title: "t", start: start, durationS: 1, meta: [:], appVersion: "0.17.0")
    expect(pb["org_id"] == nil && pb["is_private"] == nil, "b6b: a personal, not private call sends what 0.16 sent")
    let tb = CallSync.callBody(projectID: "p", title: "t", start: start, durationS: 1, meta: [:], appVersion: "0.17.0", orgID: o2, isPrivate: true)
    expect(tb["org_id"] as? String == o2 && tb["is_private"] as? Bool == true, "b6b: org_id and is_private")
    expect(CallSync.orgQuery(o2) == "?org_id=" + o2 && CallSync.orgQuery("") == "" && CallSync.orgQuery("x&y=1") == "", "b6b: org query only for an id")
    let p0 = CallSync.projectBody(name: "N", slug: "n s", orgID: "", orgProjectID: nil)
    let pl = CallSync.projectBody(name: "N", slug: "n", orgID: o2, orgProjectID: "op1")
    let pu = CallSync.projectBody(name: "N", slug: "n", orgID: o2, orgProjectID: "")
    expect(Set(p0.keys) == ["name", "local_slug"] && p0["local_slug"] as? String == "n-s", "b6b: personal project body as before")
    expect(pl["org_id"] as? String == o2 && pl["org_project_id"] as? String == "op1" && pu["org_project_id"] is NSNull, "b6b: link and unlink")
    expect(CallSync.projectKey(email: "m@x", orgID: o1, personal: true, slug: "a b", link: "") == "m@x|a-b", "b6b: personal key unchanged since 0.12")
    expect(CallSync.projectKey(email: "m@x", orgID: o2, personal: false, slug: "a", link: "op1") == "m@x|" + o2 + "|a|op1", "b6b: organization key")
    // the sync state: old files load, the new fields round-trip
    let tmp = NSTemporaryDirectory() + "b6b-\(UUID().uuidString).sync.json"
    try? Data(#"{"schema":1,"callID":"c1","hashes":{"call":"h"}}"#.utf8).write(to: URL(fileURLWithPath: tmp))
    var st = CallSync.State.load(tmp)
    expect(st?.callID == "c1" && st?.orgID == "" && st?.isPrivate == false && st?.serverPrivate == false, "b6b: a 0.16 state loads")
    st?.orgID = o2; st?.isPrivate = true; st?.serverPrivate = true; st?.save(tmp)
    let back = CallSync.State.load(tmp)
    expect(back?.orgID == o2 && back?.isPrivate == true && back?.serverPrivate == true && back?.hashes["call"] == "h", "b6b: state round-trip")
    try? FileManager.default.removeItem(atPath: tmp)
    // a project: old files load, the link round-trips
    let pj = try? JSONDecoder().decode(Project.self, from: Data(#"{"name":"A","slug":"a","root":"/x"}"#.utf8))
    expect(pj?.orgProjectID == "" && pj?.privateByDefault == false && pj?.linkedToOrgProject == false, "b6b: a 0.16 project loads")
    var lp = pj!; lp.orgProjectID = "op1"; lp.orgProjectOrg = o2; lp.orgProjectName = "Project 1"; lp.privateByDefault = true
    let rt = (try? JSONEncoder().encode(lp)).flatMap { try? JSONDecoder().decode(Project.self, from: $0) }
    expect(rt == lp && rt?.linkedToOrgProject == true, "b6b: project link round-trip")
    // a moved project (Bohdan 16.11): its new calls go to the organization it was moved to; a link wins
    var mv = pj!; mv.orgID = o1
    expect(mv.homeOrg == o1 && PacenoteServer.orgForCall(stored: "", onServer: false, linkedOrg: mv.homeOrg, me: me) == o1, "b6b: moved project's new calls")
    mv.orgProjectID = "op1"; mv.orgProjectOrg = o2
    expect(mv.homeOrg == o2, "b6b: the organization project's organization first")
    let mrt = (try? JSONEncoder().encode(mv)).flatMap { try? JSONDecoder().decode(Project.self, from: $0) }
    expect(mrt?.orgID == o1 && pj?.homeOrg == "", "b6b: orgID round-trip, empty by default")
}

func prepSecuritySEC01() {
    // hosts: only links the PM typed with a scheme, never Google, never a bare domain
    let ctx = "Read https://northwind.example/pricing and https://docs.google.com/document/d/abc/edit, see x.example.io, " +
              "https://forms.gle/zz https://sub.drive.google.com/a http://Acme.example/a"
    expect(PrepSecurity.webHosts(in: ctx) == ["acme.example", "northwind.example"], "sec01: PM hosts only, no Google: \(PrepSecurity.webHosts(in: ctx))")
    expect(PrepSecurity.webHosts(in: "https://docs.google.com/document/d/x").isEmpty, "sec01: docs.google.com never added")
    expect(PrepSecurity.webHosts(in: "") == [] && PrepSecurity.webHosts(in: "https://localhost:8000/x").isEmpty, "sec01: nothing, no localhost")
    expect(PrepSecurity.blocked("webhook.site") && PrepSecurity.blocked("a.ngrok-free.app") && !PrepSecurity.blocked("example.com"), "sec01: blocked hosts")
    // the sales fetch: the company's own domain only
    expect(PrepSecurity.salesFetchHosts(company: "https://www.Northwind.example/about") == ["northwind.example", "www.northwind.example"], "sec01: sales domain")
    expect(PrepSecurity.salesFetchHosts(company: "Northwind Studio").isEmpty && PrepSecurity.salesFetchHosts(company: "").isEmpty, "sec01: a name is no domain")
    expect(PrepSecurity.salesFetchHosts(company: "google.com").isEmpty, "sec01: never Google")
    // read denies
    let d = PrepSecurity.readDenies(home: "/Users/example", workRoot: "/Users/example/work", allowed: ["/Users/example/work/Acme", "/Users/example/.claude/skills/live-tips"],
                                    otherRoots: ["/Users/example/work/Globex", "/Users/example/work/Acme", "/Users/example/work"])
    expect(d.contains("Read(//Users/example/.ssh/**)") && d.contains("Grep(//Users/example/.aws/**)") && d.contains("Glob(//Users/example/Library/**)"), "sec01: secret folders denied")
    expect(d.contains("Read(//Users/example/work/Secrets/**)") && d.contains("Read(//Users/example/work/Globex/**)"), "sec01: Secrets and another project denied")
    expect(!d.contains("Read(//Users/example/work/Acme/**)") && !d.contains("Read(//Users/example/work/**)"), "sec01: never this project or a folder that holds it")
    expect(!d.contains("Read(//Users/example/.claude/**)") && d.contains("Read(//Users/example/.claude/.credentials.json)"), "sec01: the skill's parent stays, its credentials not")
    expect(d.contains("Read(//Users/example/.netrc)") && d.filter { $0 == "Read(//Users/example/.ssh/**)" }.count == 1, "sec01: files, no duplicates")
    let w = PrepSecurity.readDenies(home: "/Users/example/", workRoot: "", allowed: [], otherRoots: [""])
    expect(w.contains("Read(//Users/example/.ssh/**)") && !w.contains { $0.contains("(///") || $0.contains("//**") }, "sec01: clean paths")
    // Claude Code's version
    expect(PrepSecurity.claudeOK("2.1.170 (Claude Code)") == true && PrepSecurity.claudeOK("2.1.163") == true, "sec01: new enough")
    expect(PrepSecurity.claudeOK("2.1.162 (Claude Code)") == false && PrepSecurity.claudeOK("1.9.999") == false, "sec01: too old")
    expect(PrepSecurity.claudeOK("3.0.0") == true && PrepSecurity.claudeOK("unknown") == nil, "sec01: major, unreadable")
}

deckCapacity097()
meetingSheet0100()
meetingSheetUI0100()
browserCapture0100()
sheetPipeline0100()
sheetFixer0100()
sheetHardening0100()
googlePicker0100()
aiChain0100()
sheetFolders0100()
fix77()
f78()
callReassign0101()
pacenoteAccountB7()
pacenoteDriveB7b()
callLists0122()
callConsent0130()
callSyncAnalysis0130()
sheetPeopleD1()
sheetPeopleD1b()
settingsSearchD2()
func projectsWizard0170() {
    // steps: people only for a new organization project made by someone who may make one
    expect(ProjectWizardCore.steps(newOrgProject: true, canManage: true) == ProjectWizardCore.Step.allCases, "wiz: 5 steps")
    expect(ProjectWizardCore.steps(newOrgProject: true, canManage: false).count == 4 && ProjectWizardCore.steps(newOrgProject: false, canManage: true).count == 4, "wiz: 4 steps")
    expect(ProjectWizardCore.folderName("  ../Acme: site/plan  ") == "Acme site plan", "wiz: folder name \(ProjectWizardCore.folderName("  ../Acme: site/plan  "))")
    expect(ProjectWizardCore.folderName("...") == "" && ProjectWizardCore.folderName(String(repeating: "a", count: 99)).count == 80, "wiz: empty, 80")
    expect(ProjectWizardCore.parent(workRoot: "/w", workspaces: []) == "/w/My workspace", "wiz: My workspace")
    expect(ProjectWizardCore.parent(workRoot: "/w", workspaces: ["/w/Acme", "/w/B"]) == "/w/Acme", "wiz: first workspace")
    expect(ProjectWizardCore.parent(workRoot: "/w", workspaces: ["/w/Acme"], chosen: "/w/B") == "/w/B", "wiz: chosen")
    expect(ProjectWizardCore.parent(workRoot: "", workspaces: []) == "", "wiz: no work folder")
    let taken: Set<String> = ["/w/A/Site", "/w/A/Site 2"]
    expect(ProjectWizardCore.newFolder(parent: "/w/A", name: "Site", exists: { taken.contains($0) }) == "/w/A/Site 3", "wiz: free name")
    expect(ProjectWizardCore.newFolder(parent: "", name: "Site", exists: { _ in false }) == "", "wiz: no parent")
    let ls = ProjectWizardCore.links("https://drive.google.com/drive/folders/abc, https://www.notion.so/x\nftp://x.example/a notalink https://www.notion.so/x <https://brightline.example/a>")
    expect(ls == ["https://drive.google.com/drive/folders/abc", "https://www.notion.so/x", "https://brightline.example/a"], "wiz: links \(ls)")
    expect(ProjectWizardCore.links(String(repeating: "https://a.example/x ", count: 1)).count == 1, "wiz: dedupe")
    expect(ProjectWizardCore.sourceKind(ls[0]) == "drive_folder" && ProjectWizardCore.sourceKind("https://docs.google.com/document/d/1") == "drive_file"
           && ProjectWizardCore.sourceKind(ls[1]) == "notion_page" && ProjectWizardCore.sourceKind(ls[2]) == "url", "wiz: kinds")
    expect(ProjectWizardCore.glossary("Brightline, e-bike\nbrightline, ,deposit") == ["Brightline", "e-bike", "deposit"], "wiz: glossary")
    let b = ProjectWizardCore.orgProjectBody(name: "  Site  ", memberIDs: ["b", "a", "b"])
    expect(b["name"] as? String == "Site" && b["member_ids"] as? [String] == ["a", "b"], "wiz: org project body")
    expect(ProjectWizardCore.orgProjectBody(name: "S", memberIDs: [])["member_ids"] == nil, "wiz: no members key")
    let ms = ProjectWizardCore.members([["user_id": "u1", "name": "Mike", "status": "active"], ["user_id": "me", "name": "Me"],
                                        ["user_id": "u2", "name": NSNull(), "email": "emily@example.com"],
                                        ["user_id": "u3", "name": "Gone", "status": "left"]], me: "me")
    expect(ms.map(\.name) == ["emily@example.com", "Mike"], "wiz: members \(ms.map(\.name))")
    // the sample project: untouched never syncs; a rename or a card edit makes it the PM's own
    var sp = SampleProject.make(root: "/w/My workspace/Sample project", workspace: "My workspace")
    expect(sp.sample && SampleProject.pristine(sp) && SampleProject.blocksSync(sp), "sample: pristine")
    expect(sp.people.map(\.name) == ["Mike", "Emily", "Sarah"], "sample: American names")
    sp.serverSync = true
    expect(SampleProject.blocksSync(sp) && SampleProject.settle(sp).sample, "sample: sync switch alone does not unblock")
    var renamed = sp; renamed.name = "Brightline"
    expect(!SampleProject.pristine(renamed) && !SampleProject.settle(renamed).sample && !SampleProject.blocksSync(SampleProject.settle(renamed)), "sample: rename")
    var edited = sp; edited.goal = "Ship it"
    expect(!SampleProject.settle(edited).sample, "sample: card edit")
    var plain = Project(name: "Site", slug: "site", root: "/w/Site"); plain.serverSync = true
    expect(!SampleProject.blocksSync(plain), "sample: other projects sync as before")
    let n = MeetingNotes.parse(SampleProject.notes)
    expect(n?.decisions.count == 1 && n?.actions.count == 1 && n?.decisions.first?.t == "00:01:40", "sample: one decision, one task")
    expect(SampleProject.callStem(date: Date(timeIntervalSince1970: 0)).hasSuffix("-sample-kickoff.app"), "sample: stem")
    // the card round-trips through projects.json, old files keep loading
    var c = Project(name: "Site", slug: "site", root: "/w/Site")
    c.about = "A"; c.client = "B"; c.goal = "C"; c.glossary = ["x"]; c.links = ["https://a.example"]; c.sample = true
    let d = (try? JSONEncoder().encode(c)) ?? Data()
    expect((try? JSONDecoder().decode(Project.self, from: d)) == c, "card: round trip")
    let old = try? JSONDecoder().decode(Project.self, from: Data(#"{"name":"Old","slug":"old","root":"/o"}"#.utf8))
    expect(old?.about == "" && old?.links == [] && old?.sample == false, "card: old file")
    for s in [SampleProject.transcript, SampleProject.notes, SampleProject.task, sp.about, sp.client, sp.goal] {
        expect(!s.contains("\u{2014}"), "sample: no long dash")
    }
}

func itemIDs0170() {
    // server 0.7.0 (D40, B6b contract 9): stable item ids and revs in PUT /v1/calls/{id}/decisions|tasks|risks
    var n = 0
    let mk: () -> String = { n += 1; return "00000000-0000-0000-0000-00000000000\(n)" }
    var st = CallSync.State()
    let rows: [[String: Any]] = [["text": "Ship  the beta"], ["text": "Hire Emily"], ["text": "ship the beta"]]
    let a = CallSync.withIDs(rows, part: "decisions", state: st, newID: mk)
    expect(a.map { $0["_key"] as? String } == ["ship the beta", "hire emily", "ship the beta#2"], "items: keys (case, spaces, repeats)")
    expect(Set(a.compactMap { $0["id"] as? String }).count == 3, "items: fresh ids")
    expect(CallSync.stripKeys(a).allSatisfy { $0["_key"] == nil }, "items: hash body without the local key")
    let first = CallSync.withRevs(a, part: "decisions", state: st)
    expect(first.allSatisfy { $0["rev"] == nil && $0["_key"] == nil && $0["id"] != nil }, "items: first PUT, ids without rev")
    let id0 = a[0]["id"] as! String, id1 = a[1]["id"] as! String, id2 = a[2]["id"] as! String
    let resp = CallSync.json(["count": 3, "items": [["id": id0, "rev": 1], ["id": id2, "rev": 4]]])   // id1 deleted by a lead
    CallSync.rememberItems(a, part: "decisions", response: resp, state: &st)
    expect(st.items["decisions"]?["ship the beta"] == CallSync.ItemRef(id: id0, rev: 1), "items: rev remembered")
    expect(st.items["decisions"]?["hire emily"] == CallSync.ItemRef(id: id1, rev: nil), "items: skipped by the server keeps its id")
    // the next sync: same ids, same hash body, revs only in what is sent
    let b = CallSync.withIDs([["text": "ship the BETA"], ["text": "Hire Emily"], ["text": "Ship the beta"], ["text": "New risk"]],
                             part: "decisions", state: st, newID: mk)
    expect(b.prefix(3).map { $0["id"] as? String } == [id0, id1, id2], "items: ids found again")
    expect(CallSync.hash(CallSync.json(CallSync.stripKeys(Array(a.prefix(2))))) ==
           CallSync.hash(CallSync.json(CallSync.stripKeys([a[0], b[1]]))), "items: a new rev alone does not change the hash")
    let sent = CallSync.withRevs(b, part: "decisions", state: st)
    expect(sent[0]["rev"] as? Int == 1 && sent[1]["rev"] == nil && sent[2]["rev"] as? Int == 4 && sent[3]["rev"] == nil, "items: last rev sent")
    // an item no longer sent is forgotten; an old server answers without items
    CallSync.rememberItems([b[0]], part: "decisions", response: CallSync.json(["count": 1]), state: &st)
    expect(st.items["decisions"]?.count == 1 && st.items["decisions"]?["ship the beta"]?.rev == 1, "items: old server keeps rev, dropped forgotten")
    CallSync.rememberItems([], part: "decisions", response: CallSync.json(["count": 0]), state: &st)
    expect(st.items["decisions"] == nil, "items: empty part")
    // the state file keeps them; an old file reads without them
    st.items["tasks"] = ["call mike": CallSync.ItemRef(id: id1, rev: 2)]
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    let back = try? dec.decode(CallSync.State.self, from: enc.encode(st))
    expect(back?.items == st.items, "items: state round trip")
    let old = try? dec.decode(CallSync.State.self, from: Data(#"{"callID":"x","hashes":{}}"#.utf8))
    expect(old?.items == [:] && old?.callID == "x", "items: old state file")
    expect(CallSync.itemParts == ["decisions", "tasks", "risks"], "items: parts")
}

// 0.17.0 (server 0.7.0, D40, contract 9 block 2): a colleague's change comes back through /v1/sync
func pull0170() {
    let me = "11111111-1111-1111-1111-111111111111", emily = "22222222-2222-2222-2222-222222222222"
    let page = CallSync.syncPage(CallSync.json(["changed": [["id": "AAA", "owner_id": me.uppercased(), "version": "3"], ["id": "bbb", "owner_id": emily],
                                                            ["id": "ccc", "owner_id": me], ["id": "aaa", "owner_id": me]],
                                                "deleted": ["DDD"], "cursor": "MjAyNi0xMS0xNlQxMDowMDowMCswMDowMA==", "more": true]))
    expect(page?.changed.count == 4 && page?.changed[0].id == "aaa" && page?.deleted == ["ddd"] && page?.more == true, "pull: sync page")
    expect(CallSync.syncPage(Data("[]".utf8)) == nil, "pull: not a page")
    expect(CallSync.toRead(page!, me: me, known: ["aaa", "bbb"]) == ["aaa"], "pull: my known calls, once")
    expect(CallSync.toRead(page!, me: "", known: ["aaa"]).isEmpty, "pull: no user id, nothing")
    let org = "33333333-3333-3333-3333-333333333333"
    expect(CallSync.syncPath(orgID: org, cursor: "") == "/v1/sync?org_id=" + org, "pull: first page")
    expect(CallSync.syncPath(orgID: org, cursor: "ab=") == "/v1/sync?org_id=" + org + "&since=ab%3D", "pull: cursor encoded")
    expect(CallSync.syncPath(orgID: "", cursor: "x") == "/v1/sync?since=x", "pull: personal")

    let call: [String: Any] = [
        "decisions": [["id": "D1", "rev": 3, "status": "reverted", "edited_by": emily], ["id": "d9", "rev": 1, "status": "made"]],
        "tasks": [["id": "t1", "rev": 2, "status": "done", "assignee": "Mike", "due_date": "2026-11-20", "owner_user_id": emily],
                  ["id": "t2", "rev": 4, "status": "open", "assignee": "Bohdan N.", "due_date": nil, "owner_user_id": me],
                  ["id": "t3", "rev": 1, "status": "open"]],
        "risks": [["id": "r1"]]]
    let rd = CallSync.remoteItems(call, part: "decisions"), rt = CallSync.remoteItems(call, part: "tasks")
    expect(rd.first == CallSync.RemoteItem(id: "d1", rev: 3, status: "reverted", editedBy: emily), "pull: remote decision")
    expect(rt[0].due == "2026-11-20" && rt[0].ownerUserID == emily && rt[1].due == "" && CallSync.remoteItems(call, part: "risks").isEmpty, "pull: remote tasks")

    var st = CallSync.State()
    st.items["decisions"] = ["ship the beta": .init(id: "d1", rev: 1)]
    st.items["tasks"] = ["send the deck": .init(id: "t1", rev: 1), "call the vendor": .init(id: "t2", rev: 4), "book a room": .init(id: "t3")]
    let nd = CallSync.newer(rd, part: "decisions", state: st), nt = CallSync.newer(rt, part: "tasks", state: st)
    expect(nd.map(\.key) == ["ship the beta"], "pull: a newer decision, an unknown one ignored")
    expect(Set(nt.map(\.key)) == ["send the deck", "book a room"], "pull: newer tasks (same rev skipped, no rev counts as 0)")
    var st2 = st
    CallSync.adopt(nd + CallSync.newer([CallSync.RemoteItem(id: "t2", rev: 5, status: "open", assignee: "Bohdan N.", ownerUserID: me)], part: "tasks", state: st),
                   me: me, myNames: ["Bohdan"], state: &st2)
    expect(st2.items["decisions"]?["ship the beta"] == .init(id: "d1", rev: 3, status: "reverted"), "pull: decision rev and status kept")
    expect(st2.items["tasks"]?["call the vendor"]?.assignee == "Bohdan N." && st2.items["tasks"]?["call the vendor"]?.rev == 5, "pull: a task given to me keeps the server name")
    // the next PUT sends them back
    let drows = CallSync.withIDs([["text": "Ship the beta"]], part: "decisions", state: st2)
    let dsent = CallSync.withRevs(drows, part: "decisions", state: st2)
    expect(dsent[0]["status"] as? String == "reverted" && dsent[0]["rev"] as? Int == 3 && dsent[0]["_key"] == nil, "pull: decision status goes back")
    let trows = CallSync.withIDs([["text": "Call the vendor", "assignee": "Bohdan", "status": "open", "_mine": true, "_cid": "c-1"],
                                  ["text": "Send the deck", "assignee": "Mike", "status": "done", "_mine": false]], part: "tasks", state: st2)
    let tsent = CallSync.withRevs(trows, part: "tasks", state: st2)
    expect(tsent[0]["assignee"] as? String == "Bohdan N." && tsent[0]["status"] as? String == "open" && tsent[0]["_mine"] == nil && tsent[0]["_cid"] == nil,
           "pull: my task keeps the server name, no local keys")
    expect(tsent[1]["assignee"] as? String == "Mike", "pull: their task as it is")
    expect(CallSync.stripKeys(trows).allSatisfy { $0.keys.allSatisfy { !$0.hasPrefix("_") } }, "pull: hash body without local keys")
    // rememberItems keeps what a colleague set when the id stays
    var st3 = st2
    CallSync.rememberItems(drows, part: "decisions", response: CallSync.json(["count": 1, "items": [["id": "d1", "rev": 3]]]), state: &st3)
    expect(st3.items["decisions"]?["ship the beta"]?.status == "reverted", "pull: status survives the next PUT")

    // task rows carry their register item; keys like withIDs
    let ev: [[String: Any]] = [
        ["op": "add", "id": "c-1", "text": "Send the deck", "owner": "me", "call": "x.app.md", "created": "2026-11-13T10:00:00+02:00", "due": "Friday"],
        ["op": "add", "id": "c-2", "text": "Book a room", "owner": "Mike", "call": "x.app.md", "created": "2026-11-13T10:00:00+02:00", "due": "2026-11-18"],
        ["op": "add", "id": "c-3", "text": "Draft the plan", "owner": "me", "call": "x.app.md", "created": "2026-11-13T10:00:00+02:00", "due": "next sprint"]]
    let reg = CommitmentRegister.fold(ev)
    let rows = CallSync.tasks(register: reg, lists: CallLists.Lists(), me: "Bohdan")
    expect(rows[0]["_cid"] as? String == "c-1" && rows[0]["_mine"] as? Bool == true && rows[1]["_mine"] as? Bool == false, "pull: rows know their item")
    expect(CallSync.taskKeys(rows) == ["send the deck": "c-1", "book a room": "c-2", "draft the plan": "c-3"], "pull: task keys")
    expect(CallSync.taskKeys([["text": "A", "_cid": "x"], ["text": "a", "_cid": "y"]]) == ["a": "x", "a#2": "y"], "pull: same text twice")

    let at = "2026-11-16T12:00:00+02:00"
    let done = CallSync.taskEvents(reg[0], server: .init(id: "t1", rev: 2, status: "done", assignee: "Mike", due: "2026-11-20", ownerUserID: emily),
                                   me: me, myNames: ["Bohdan"], at: at)
    expect(done.count == 2 && done[0]["op"] as? String == "done" && done[0]["source"] as? String == "server", "pull: done from the server")
    expect(done[1]["op"] as? String == "edit" && done[1]["owner"] as? String == "Mike" && done[1]["due"] as? String == "2026-11-20", "pull: owner and due")
    let folded = CommitmentRegister.fold(ev + done)
    expect(folded[0].status == "done" && folded[0].owner == "Mike" && folded[0].due == "2026-11-20", "pull: the register agrees")
    expect(CallSync.taskEvents(folded[0], server: .init(id: "t1", rev: 2, status: "done", assignee: "Mike", due: "2026-11-20"), me: me, myNames: [], at: at).isEmpty,
           "pull: nothing when they agree")
    let toMe = CallSync.taskEvents(reg[1], server: .init(id: "t3", rev: 2, status: "dropped", assignee: "Bohdan N.", due: "", ownerUserID: me),
                                   me: me, myNames: [], at: at)
    expect(toMe[0]["op"] as? String == "drop" && toMe[1]["owner"] as? String == "me" && toMe[1]["due"] as? String == "", "pull: given to me, dropped, no due")
    let reopen = CallSync.taskEvents(CommitmentRegister.fold(ev + [["op": "done", "id": "c-3"]])[2],
                                     server: .init(id: "t4", rev: 3, status: "open", assignee: "bohdan", due: ""), me: me, myNames: ["Bohdan"], at: at)
    expect(reopen.count == 1 && reopen[0]["op"] as? String == "reopen", "pull: reopened; my name; a due text with no day stays")

    // tasks from the notes go into the register first, full text, once each
    let long = String(repeating: "word ", count: 40) + "end"
    let lt = [CallLists.Task(owner: "Mike", text: "Send the deck", due: "Friday"), CallLists.Task(text: long, mine: true),
              CallLists.Task(owner: "Mike", text: "Send the deck"), CallLists.Task(text: "None")]
    let ad = CommitmentRegister.adoptAllEvents(lt, project: "acme", title: "Weekly", call: "/x/live/2026-11-13 Weekly.app.md", them: "them", at: at)
    expect(ad.count == 2 && ad.allSatisfy { ($0["by"] as? String) == "sync" && ($0["op"] as? String) == "add" }, "pull: adopt all, once each, nothing lines out")
    expect((ad[1]["text"] as? String)?.hasSuffix("end") == true && ad[1]["owner"] as? String == "me" && ad[0]["due"] as? String == "Friday",
           "pull: full text, owner, due")
    let after = CommitmentRegister.fold(ad)
    expect(CallSync.taskKeys(CallSync.tasks(register: after, lists: CallLists.Lists(), me: "")).keys.contains(CallSync.itemKey(long)), "pull: the same key after adopting")

    // the state file keeps status and assignee; an older ItemRef reads without them
    let enc = JSONEncoder(), dec = JSONDecoder()
    expect((try? dec.decode(CallSync.State.self, from: enc.encode(st2)))?.items == st2.items, "pull: state round trip")
    let oldRef = try? dec.decode(CallSync.ItemRef.self, from: Data(#"{"id":"x","rev":2}"#.utf8))
    expect(oldRef == .init(id: "x", rev: 2) && oldRef?.status == nil, "pull: old item ref")
}

// 0.17.0 (contract 9 block 3): the organization project card
func orgCard0170() {
    let emily = "22222222-2222-2222-2222-222222222222", me = "11111111-1111-1111-1111-111111111111"
    let body: [String: Any] = ["id": "p1", "org_id": "o1", "name": "Project 1", "archived": false,
        "card": ["description": "Bike rental app", "goal": "Beta in March", "client": ["name": "Brightline Bikes", "site": "https://brightline.example"],
                 "people": [["name": "Mike", "role": "CTO", "side": "client", "note": "decides"], ["name": ""]],
                 "glossary": [["term": "BLB", "note": "Brightline Bikes"]], "rules": ["No dates before the estimate"], "languages": ["en"],
                 "audience": "client", "version": "4", "updated_by": ["id": emily.uppercased(), "name": "Emily"], "updated_at": "2026-11-16T10:00:00Z"],
        "people": [["user_id": me, "name": "Bohdan"], ["user_id": emily, "name": "Emily"]]]
    guard let v = OrgCard.parse(CallSync.json(body)) else { expect(false, "card: parse"); return }
    expect(v.name == "Project 1" && v.version == "4" && v.updatedByID == emily && v.updatedByName == "Emily" && v.members.count == 2, "card: header")
    expect(v.card.clientName == "Brightline Bikes" && v.card.people == [OrgCard.Person(name: "Mike", role: "CTO", side: "client", note: "decides")]
           && v.card.glossary == [OrgCard.Term(term: "BLB", note: "Brightline Bikes")] && v.card.rules.count == 1, "card: fields, empty names out")
    var empty = OrgCard.parse(CallSync.json(["id": "p2", "card": ["description": NSNull(), "client": [:], "version": "1", "updated_by": ["id": NSNull(), "name": ""]]]))
    expect(empty?.card.isEmpty == true && empty?.updatedByID == "" && empty?.updatedAt == nil, "card: a new empty card")
    empty?.card.goal = "x"
    expect(OrgCard.parse(Data("{}".utf8)) == nil, "card: not a card")

    // only what I changed goes
    var d = v.card
    d.goal = "Beta in April"; d.rules.append("Never share the price list")
    let patch = OrgCard.patch(base: v.card, draft: d)
    expect(Set(patch.keys) == ["goal", "rules"] && (patch["rules"] as? [String])?.count == 2, "card: patch only changed fields")
    expect(OrgCard.patch(base: v.card, draft: v.card).isEmpty, "card: nothing changed")
    var long = v.card; long.description = String(repeating: "a", count: 2500)
    expect((OrgCard.patch(base: v.card, draft: long)["description"] as? String)?.count == 2000, "card: limits")
    expect(OrgCard.ifMatch("4") == "\"4\"" && OrgCard.ifMatch("\"4\"") == "\"4\"", "card: If-Match")

    // 409: mine on top of theirs, field by field
    var theirs = v.card; theirs.description = "Bike sharing app"; theirs.goal = "Beta in May"
    let (merged, conflicts) = OrgCard.rebase(base: v.card, draft: d, server: theirs)
    expect(merged.description == "Bike sharing app" && merged.goal == "Beta in April" && merged.rules.count == 2, "card: rebase keeps theirs and mine")
    expect(conflicts == ["goal"], "card: both changed the goal")
    var same = v.card; same.goal = "Beta in April"
    expect(OrgCard.rebase(base: v.card, draft: d, server: same).conflicts.isEmpty, "card: the same change is no conflict")
    expect(OrgCard.outcome(status: 200) == .saved && OrgCard.outcome(status: 409) == .newer && OrgCard.outcome(status: 428) == .newer
           && OrgCard.outcome(status: 403) == .readOnly && OrgCard.outcome(status: 422, problem: "x") == .invalid("x"), "card: outcomes")

    // the Meeting Sheet line
    let before = ISO8601DateFormatter().date(from: "2026-11-15T10:00:00Z")!, after = ISO8601DateFormatter().date(from: "2026-11-17T10:00:00Z")!
    expect(OrgCard.changedSincePrep(v, lastPrep: before, me: me) == "Emily", "card: changed by Emily since my prep")
    expect(OrgCard.changedSincePrep(v, lastPrep: after, me: me) == nil, "card: not since")
    expect(OrgCard.changedSincePrep(v, lastPrep: before, me: emily.uppercased()) == nil, "card: my own change")
    expect(OrgCard.changedSincePrep(v, lastPrep: nil, me: me) == nil, "card: never prepared")

    // editor text forms
    let ppl = OrgCard.people("Mike | CTO | client | decides\nEmily | PM | team\nSarah | Designer | likes demos\n | nobody")
    expect(ppl.count == 3 && ppl[1].side == "team" && ppl[2].side == "client" && ppl[2].note == "likes demos", "card: people lines")
    expect(OrgCard.peopleText([OrgCard.Person(name: "Mike", role: "CTO", side: "client", note: "")]) == "Mike | CTO | client", "card: people text")
    expect(OrgCard.people(OrgCard.peopleText(v.card.people)) == v.card.people, "card: people round trip")
    expect(OrgCard.glossary("BLB: Brightline Bikes\nPacenote\n: none") == [OrgCard.Term(term: "BLB", note: "Brightline Bikes"), OrgCard.Term(term: "Pacenote")], "card: glossary lines")
    expect(OrgCard.languages("en, UK, en, english, pt-br") == ["en", "uk", "pt-br"], "card: languages")
    let local = OrgCard.fromLocal(about: "a", client: "Acme", goal: "g", glossary: ["BLB"], languages: ["en", ""])
    expect(local.clientName == "Acme" && local.glossary == [OrgCard.Term(term: "BLB")] && local.languages == ["en"], "card: from this Mac")
}

// 0.17.0 (spec 5.3): setting up an organization
func orgSetup0170() {
    var acme = PacenoteServer.Org(id: "o1", name: "Acme", kind: "team", role: "owner", plan: "team")
    expect(OrgSetup.steps(acme) == [.name, .projects, .invite, .policy], "orgsetup: no teams without the flag")
    acme.teams = true
    expect(OrgSetup.steps(acme) == OrgSetup.Step.allCases, "orgsetup: all steps")
    expect(OrgSetup.offered(acme, done: []) && !OrgSetup.offered(acme, done: ["o1"]), "orgsetup: offered once")
    var admin = acme; admin.role = "admin"
    expect(!OrgSetup.offered(admin, done: []) && OrgSetup.canRun(admin), "orgsetup: admin runs it from Settings")
    let home = PacenoteServer.Org(id: "o0", name: "Mike's workspace", kind: "personal", role: "owner", plan: "solo")
    expect(!OrgSetup.offered(home, done: []) && !OrgSetup.canRun(home), "orgsetup: never the personal one")
    expect(OrgSetup.nameBody("  Acme Inc ")?["name"] as? String == "Acme Inc" && OrgSetup.nameBody(" ") == nil, "orgsetup: name")

    var a = Project(name: "A", slug: "a", root: "/w/A"), b = Project(name: "B", slug: "b", root: "/w/B")
    var c = Project(name: "C", slug: "c", root: "/w/C"); c.status = "archived"
    var d = Project(name: "D", slug: "d", root: "/w/D"); d.orgID = "o1"
    let s = SampleProject.make(root: "/w/S", workspace: "w")
    b.orgProjectID = "p1"; b.orgProjectOrg = "o2"
    a.orgID = ""
    expect(OrgSetup.movable([a, b, c, d, s], into: "o1").map(\.slug) == ["a", "b"], "orgsetup: movable projects")

    let (ok, bad) = OrgSetup.invites("mike@example.com\nEmily@Example.com admin, sarah@example\n<mike@example.com>; joe@example.org member")
    expect(ok == [.init(email: "mike@example.com", role: "member"), .init(email: "emily@example.com", role: "admin"),
                  .init(email: "joe@example.org", role: "member")], "orgsetup: invite lines")
    expect(bad == ["sarah@example"], "orgsetup: not an email")
    expect(OrgSetup.invites("emily@example.com", defaultRole: "admin").ok.first?.role == "admin", "orgsetup: default role")
    let ib = OrgSetup.inviteBody(.init(email: "e@x.io", role: "owner"), teamID: "t1")
    expect(ib["org_role"] as? String == "member" && ib["team_id"] as? String == "t1", "orgsetup: invite body")
    expect(OrgSetup.inviteBody(.init(email: "e@x.io", role: "admin"), teamID: "")["team_id"] == nil, "orgsetup: no team")
    expect(OrgSetup.inviteResult(status: 201) == "orgsetup.invite.sent" && OrgSetup.inviteResult(status: 402) == "orgsetup.invite.seats"
           && OrgSetup.inviteResult(status: 500) == "orgsetup.invite.failed", "orgsetup: invite answers")

    let t = OrgSetup.teams([["id": "t2", "name": "Sales", "lead_user_id": "u1", "member_ids": ["u2"]], ["id": "t1", "name": "Delivery", "lead_user_id": NSNull()], ["name": "x"]])
    expect(t.map(\.name) == ["Delivery", "Sales"] && t[0].leadID == "" && t[1].memberIDs == ["u2"], "orgsetup: teams")
    expect(OrgSetup.teamBody(name: " Sales ", leadID: "u1")?["lead_user_id"] as? String == "u1" && OrgSetup.teamBody(name: "", leadID: "") == nil
           && OrgSetup.teamBody(name: "Ops", leadID: "")?["lead_user_id"] == nil, "orgsetup: team body")

    let p0 = OrgSetup.policy(["allow_private_calls": false, "share_meeting_sheets": true, "require_transcript_in_drive": false])
    expect(p0 == .init(allowPrivateCalls: false, shareMeetingSheets: true) && OrgSetup.policy([:]) == .init(), "orgsetup: policy")
    var p1 = p0; p1.allowPrivateCalls = true
    expect(OrgSetup.policyBody(from: p0, to: p1).keys.sorted() == ["allow_private_calls"] && OrgSetup.policyBody(from: p0, to: p0).isEmpty, "orgsetup: policy body")
    expect(SettingsSearch.entries.contains { $0.id == "pr.orgCard" }, "orgsetup: the card is in the settings search")
}

// 0.17.0 (smoke 16.11): the Home card line also from the TL;DR of the app's own notes
func homeLine0170() {
    expect(MeetingNotes.homeLine(SampleProject.notes) == "A sample call: the booking page goes live before spring, e-bikes first, design next Tuesday.",
           "home line: TL;DR of the sample notes")
    expect(MeetingNotes.homeLine("## Summary\n\n- Mike agreed. Then more.\n\n## Meeting notes\n\n### TL;DR\nOther.") == "Mike agreed.", "home line: a summary section first")
    expect(MeetingNotes.homeLine("## Summary\n\nNone.\n\n## Meeting notes\n\n### TL;DR\nThe plan is set. More.") == "The plan is set.", "home line: an empty summary falls back")
    expect(MeetingNotes.homeLine("## Meeting notes\n\n### TL;DR\nНемає.\n") == nil && MeetingNotes.homeLine("") == nil, "home line: nothing")
    expect(MeetingNotes.homeLine("## Коротко\nДомовились про бюджет. Далі.") == "Домовились про бюджет.", "home line: Ukrainian summary")
}

// 0.17.0 (contract 9 block 4, spec 4.1): the registers of an organization project
func orgRegisters0170() {
    let me = "11111111-1111-1111-1111-111111111111", emily = "22222222-2222-2222-2222-222222222222", lead = "33333333-3333-3333-3333-333333333333"
    let rows: [[String: Any]] = [
        ["kind": "task", "id": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", "text": "Send the estimate", "assignee": "Bohdan", "status": "open", "rev": 3,
         "edited_by": lead.uppercased(), "edited_at": "2026-11-16T09:00:00Z", "call_id": NSNull(), "call_date": "2026-11-12T14:00:00Z",
         "call_author": ["id": emily, "name": "Emily"], "mine": false, "can_edit": true, "can_delete": false,
         "due_date": "2026-11-20", "owner_user_id": me.uppercased()],
        ["kind": "decision", "id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", "text": "Beta in March", "made_by": "Mike", "status": "made", "rev": 1,
         "edited_by": NSNull(), "edited_at": NSNull(), "call_id": "cccccccc-cccc-cccc-cccc-cccccccccccc", "call_date": "2026-11-12T14:00:00.000Z",
         "call_author": ["id": emily, "name": "Emily"], "mine": false, "can_edit": false, "can_delete": false],
        ["kind": "risk", "id": "dddddddd-dddd-dddd-dddd-dddddddddddd", "text": "The client may slip", "said_by": "Mike", "status": "open", "rev": 2,
         "call_id": "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee", "call_date": "2026-11-10T10:00:00Z",
         "call_author": ["id": me, "name": "Bohdan"], "mine": true, "can_edit": true, "can_delete": true],
        ["kind": "note", "id": "x", "text": "not a register kind"], ["kind": "task", "id": "y", "text": "  "]]
    guard let items = OrgRegister.parse(CallSync.json(rows)) else { expect(false, "registers: parse"); return }
    expect(items.count == 3, "registers: unknown kinds and empty texts dropped")
    let t = items[0], d = items[1], r = items[2]
    expect(t.kind == .task && t.id == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" && t.who == "Bohdan" && t.rev == 3 && t.due == "2026-11-20"
           && t.ownerUserID == me && t.callID == nil && t.authorName == "Emily" && t.canEdit && !t.canDelete && !t.mine, "registers: a colleague's task given to me")
    expect(d.who == "Mike" && d.callID == "cccccccc-cccc-cccc-cccc-cccccccccccc" && d.callDate != nil && d.editedBy == "" && !d.canEdit, "registers: a read-only decision")
    expect(r.who == "Mike" && r.mine && r.canDelete, "registers: my own risk")
    expect(OrgRegister.parse(Data("{}".utf8)) == nil && OrgRegister.parse(Data("[]".utf8)) == [], "registers: not a list, an empty list")
    expect(OrgRegister.fromColleagues(items).map(\.id) == [t.id, d.id], "registers: the Tracker adds my colleagues' items only")
    expect(OrgRegister.givenToMe(t, me: me.uppercased()) && !OrgRegister.givenToMe(d, me: me) && !OrgRegister.givenToMe(t, me: ""), "registers: given to me")
    expect(OrgRegister.callDay(t, lang: "en") == "Nov 12", "registers: from Emily's call, Nov 12")
    expect(OrgRegister.closed(OrgRegister.Item(kind: .decision, id: "1", text: "x", status: "reverted")) && !OrgRegister.closed(t), "registers: closed")

    // paths
    expect(OrgRegister.listPath(org: "o1", project: "p1") == "/v1/orgs/o1/projects/p1/registers", "registers: list path")
    expect(OrgRegister.listPath(org: "o1", project: "p1", kind: .task, status: "open") == "/v1/orgs/o1/projects/p1/registers?kind=task&status=open", "registers: filters")
    let since = ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z")!
    expect(OrgRegister.listPath(org: "o", project: "p", since: since).hasSuffix("?since=2026-11-01T00%3A00%3A00Z"), "registers: since escaped")
    expect(OrgRegister.itemPath(org: "o", project: "p", t) == "/v1/orgs/o/projects/p/registers/task/" + t.id && OrgRegister.ifMatch(t) == "\"3\"", "registers: item path, If-Match")

    // the PATCH body: only what changes
    expect(OrgRegister.patch(t, .init(status: "done")) as NSDictionary == ["status": "done"] as NSDictionary, "registers: status")
    expect(OrgRegister.patch(t, .init(status: "open")).isEmpty && OrgRegister.patch(t, .init(status: "closed")).isEmpty, "registers: same or a wrong status")
    let clear = OrgRegister.patch(t, .init(due: "", owner: ""))
    expect(clear["due_date"] is NSNull && clear["owner_user_id"] is NSNull, "registers: clear due date and owner")
    expect(OrgRegister.patch(t, .init(due: "2026-11-20", owner: me)).isEmpty, "registers: the same due date and owner")
    expect(OrgRegister.patch(t, .init(due: "next week")).isEmpty, "registers: not a date")
    expect(OrgRegister.patch(t, .init(due: "2026-11-25", owner: emily.uppercased())) as NSDictionary == ["due_date": "2026-11-25", "owner_user_id": emily] as NSDictionary, "registers: due date and owner")
    expect(OrgRegister.patch(d, .init(status: "reverted", due: "2026-11-25", owner: emily)) as NSDictionary == ["status": "reverted"] as NSDictionary, "registers: a decision takes only the status")
    expect(OrgRegister.patch(r, .init(status: "made")).isEmpty && OrgRegister.statuses(.risk) == ["open", "closed"], "registers: risk statuses")

    // after a saved PATCH
    let ans = CallSync.json(["kind": "task", "id": t.id, "rev": 4, "changed": ["status", "owner_user_id"]])
    let n = OrgRegister.applied(t, .init(status: "done", due: "2026-12-01", owner: emily), answer: ans, me: me, ownerName: "Emily")
    expect(n.rev == 4 && n.status == "done" && n.due == "2026-11-20" && n.ownerUserID == emily && n.who == "Emily" && n.editedBy == me, "registers: applied only what changed")
    let none = OrgRegister.applied(t, .init(status: "done"), answer: CallSync.json(["rev": 3, "changed": []]), me: me)
    expect(none == t, "registers: nothing changed")
    expect(OrgRegister.outcome(status: 204) == .saved && OrgRegister.outcome(status: 409) == .newer && OrgRegister.outcome(status: 403) == .readOnly
           && OrgRegister.outcome(status: 404) == .gone && OrgRegister.outcome(status: 422, problem: "invalid fields: owner_user_id") == .invalid("invalid fields: owner_user_id"), "registers: outcomes")

    // "changed by" under the row
    let ppl = [OrgCard.Member(id: emily, name: "Emily"), OrgCard.Member(id: lead, name: "Sarah")]
    expect(OrgRegister.editedByOther(t, members: ppl) == "Sarah" && OrgRegister.editedByOther(d, members: ppl) == nil, "registers: changed by the lead")
    var byAuthor = t; byAuthor.editedBy = emily
    expect(OrgRegister.editedByOther(byAuthor, members: ppl) == nil, "registers: the author's own change says nothing")
    var byGone = t; byGone.editedBy = "44444444-4444-4444-4444-444444444444"
    expect(OrgRegister.editedByOther(byGone, members: ppl) == "?" && OrgRegister.name(emily.uppercased(), members: ppl) == "Emily", "registers: names")
}

func console0170() {
    func meWith(_ orgs: [[String: Any]], staff: Any? = nil, def: String = "") -> PacenoteServer.Me? {
        var o: [String: Any] = ["user": ["id": "u1", "email": "mike@example.com", "name": "Mike"], "organizations": orgs, "default_org_id": def]
        if let staff { o["staff"] = staff }
        return PacenoteServer.me(o)
    }
    let personal: [String: Any] = ["id": "p1", "name": "Mike", "kind": "personal", "org_role": "owner", "plan": "solo"]
    let member: [String: Any] = ["id": "t1", "name": "Acme", "kind": "team", "org_role": "member", "plan": "enterprise"]
    let lead: [String: Any] = ["id": "t2", "name": "Beta", "kind": "team", "org_role": "member", "plan": "enterprise", "leads_teams": ["x"]]
    let admin: [String: Any] = ["id": "t3", "name": "Gamma", "kind": "team", "org_role": "admin", "plan": "team"]
    let cl: [String: Any] = ["id": "t4", "name": "Delta", "kind": "team", "org_role": "member", "plan": "enterprise", "c_level": true]
    expect(meWith([personal])?.showsConsole == false && meWith([personal])?.staff == false, "console: personal only, no tab (and no staff field means not staff)")
    expect(meWith([personal, member])?.showsConsole == false, "console: a plain member sees no tab")
    expect(meWith([personal, member, lead])?.showsConsole == true && meWith([personal, member, lead])?.consolePath == "/org/t2", "console: a lead, opens their org")
    expect(meWith([personal, admin])?.consolePath == "/org/t3" && meWith([personal, cl])?.showsConsole == true, "console: admin and C-level")
    expect(meWith([personal, admin, lead], def: "t2")?.consolePath == "/org/t2", "console: the default org first when the person runs it")
    expect(meWith([personal, member, admin], def: "t1")?.consolePath == "/org/t3", "console: the default org skipped when the person only belongs")
    expect(meWith([personal], staff: true)?.showsConsole == true && meWith([personal], staff: true)?.consolePath == "/", "console: staff")
    expect(meWith([personal], staff: "yes")?.staff == false, "console: staff must be a bool")

    func url(_ s: String) -> Data { CallSync.json(["url": s, "expires_in": 60]) }
    let good = "https://pacenote-admin.bodco.pm/auth/app?code=pnh_abcDEF123_-x&next=%2Forg%2Ft2"
    expect(PacenoteServer.consoleHandoffURL(url(good))?.absoluteString == good, "console: handoff link")
    for bad in ["http://pacenote-admin.bodco.pm/auth/app?code=pnh_a", "https://evil.example/auth/app?code=pnh_a",
                "https://pacenote-admin.bodco.pm.evil.example/auth/app?code=pnh_a", "https://pacenote-admin.bodco.pm/login?code=pnh_a",
                "https://pacenote-admin.bodco.pm/auth/app?code=abc", "https://pacenote-admin.bodco.pm/auth/app"] {
        expect(PacenoteServer.consoleHandoffURL(url(bad)) == nil, "console: rejects \(bad)")
    }
    expect(PacenoteServer.consoleHandoffURL(Data("{}".utf8)) == nil && PacenoteServer.consoleHandoffURL(Data()) == nil, "console: empty answers")
    expect(PacenoteServer.isConsoleURL(URL(string: "https://PACENOTE-ADMIN.bodco.pm/org/x")) && !PacenoteServer.isConsoleURL(URL(string: "https://accounts.google.com/o")),
           "console: which links stay in the tab")
    let body = (try? JSONSerialization.jsonObject(with: PacenoteServer.consoleHandoffBody(next: "/org/t2"))) as? [String: String]
    expect(body == ["next": "/org/t2"], "console: handoff body")
}

func orgContext0170() {
    // current state
    let st = OrgContext.state(CallSync.json(["body_md": "# Acme\nBeta in March", "version": "3", "updated_by": ["id": "AB-1", "name": "Emily"],
                                             "updated_at": "2026-11-16T09:00:00Z", "changed": true]))
    expect(st?.body == "# Acme\nBeta in March" && st?.version == "3" && st?.updatedByID == "ab-1" && st?.updatedByName == "Emily"
           && st?.updatedAt != nil && st?.changed == true && st?.isNew == false, "state: parse")
    let empty = OrgContext.state(CallSync.json(["body_md": "", "version": "0", "updated_by": NSNull(), "updated_at": NSNull()]))
    expect(empty?.isNew == true && empty.map(OrgContext.stateHeaders) == [:], "state: the first write has no If-Match")
    expect(st.map(OrgContext.stateHeaders) == ["If-Match": "\"3\""], "state: later writes carry If-Match")
    expect(OrgContext.state(Data("[]".utf8)) == nil && OrgContext.state(Data()) == nil, "state: not a state")
    expect(OrgContext.fits(String(repeating: "a", count: 8192)) && !OrgContext.fits(String(repeating: "a", count: 8193))
           && !OrgContext.fits(String(repeating: "ї", count: 4097)), "state: 8 KB in UTF-8 bytes")
    expect(OrgContext.outcome(status: 200) == .saved && OrgContext.outcome(status: 409) == .newer && OrgContext.outcome(status: 428) == .newer
           && OrgContext.outcome(status: 422, problem: "body_md: 8 KB at most") == .tooLong && OrgContext.outcome(status: 403) == .readOnly,
           "state: outcomes")
    let body = (try? JSONSerialization.jsonObject(with: OrgContext.stateBody("x"))) as? [String: String]
    expect(body == ["body_md": "x"], "state: PUT body")

    // the post-call suggestion
    let s1 = OrgContext.suggest(current: "# Acme\nGoal: beta", day: "Nov 16", decisions: ["Ship on Friday"], risks: ["The client may slip", " "])
    expect(s1 == "# Acme\nGoal: beta\n\n## Recent\n- Nov 16: Decision: Ship on Friday\n- Nov 16: Risk: The client may slip\n", "state: suggest adds a Recent part")
    let s2 = OrgContext.suggest(current: s1, day: "Nov 17", decisions: ["Ship on Friday", "Hire Mike"], risks: [])
    expect(s2.hasPrefix("# Acme\nGoal: beta\n\n## Recent\n- Nov 17: Decision: Ship on Friday\n- Nov 17: Decision: Hire Mike\n- Nov 16: Decision"),
           "state: newest first under Recent")
    let s3 = OrgContext.suggest(current: s1, day: "Nov 16", decisions: ["ship on friday"], risks: [])
    expect(s3 == s1, "state: the same line twice is kept once")
    let withTail = OrgContext.suggest(current: "# A\n## Recent\n- old\n## People\nMike", day: "D", decisions: ["x"], risks: [])
    expect(withTail == "# A\n## Recent\n- D: Decision: x\n- old\n\n## People\nMike\n", "state: parts after Recent stay")
    let big = OrgContext.suggest(current: "# A\n## Recent\n" + (0..<400).map { "- old line number \($0) with some words" }.joined(separator: "\n"),
                                 day: "D", decisions: ["new"], risks: [])
    expect(OrgContext.fits(big) && big.contains("- D: Decision: new") && !big.contains("number 399"), "state: oldest Recent lines go to fit 8 KB")
    expect(OrgContext.suggest(current: "", day: "D", decisions: ["x"], risks: []) == "## Recent\n- D: Decision: x\n", "state: from empty")

    // diff
    let d = OrgContext.diff("a\nb\nc", "a\nc\nd")
    expect(d == [.same("a"), .removed("b"), .same("c"), .added("d")], "state: line diff")
    expect(OrgContext.diff("", "x") == [.removed(""), .added("x")] || OrgContext.diff("", "x") == [.added("x"), .removed("")], "state: diff from empty")
    let long = OrgContext.diff((0..<20).map(String.init).joined(separator: "\n"), (0..<20).map { $0 == 10 ? "ten" : String($0) }.joined(separator: "\n"))
    let c = OrgContext.compact(long, context: 1)
    expect(c.count == 6 && c.first! == nil && c.last! == nil && c.contains(.some(.removed("10"))) && c.contains(.some(.added("ten"))), "state: compact diff")

    // sources
    let srcs = OrgContext.sources(CallSync.json([
        ["id": "S1", "kind": "drive_folder", "ref": "1AbC", "title": "Specs", "note": "", "added_by": ["id": "U1", "name": "Mike"], "added_at": "2026-11-16T09:00:00Z"],
        ["id": "s2", "kind": "telegram", "ref": "x"], ["id": "s3", "kind": "url", "ref": ""]]))
    expect(srcs?.count == 1 && srcs?[0].id == "s1" && srcs?[0].kind == .driveFolder && srcs?[0].addedByName == "Mike" && srcs?[0].addedByID == "u1",
           "sources: parse, unknown kinds and empty refs dropped")
    let rec: [(String, OrgContext.SourceKind?, String)] = [
        ("https://drive.google.com/drive/folders/1AbC_d-9?usp=sharing", .driveFolder, "1AbC_d-9"),
        ("https://drive.google.com/drive/u/1/folders/XyZ", .driveFolder, "XyZ"),
        ("https://drive.google.com/file/d/F1le/view", .driveFile, "F1le"),
        ("https://drive.google.com/open?id=Q9", .driveFile, "Q9"),
        ("https://docs.google.com/document/d/D0c/edit", .driveFile, "D0c"),
        ("https://www.notion.so/acme/Plan-0123", .notionPage, "https://www.notion.so/acme/Plan-0123"),
        ("https://www.notion.so/acme/0123?v=456", .notionDB, "https://www.notion.so/acme/0123?v=456"),
        (" https://example.com/spec ", .url, "https://example.com/spec"),
        ("http://example.com", nil, ""), ("not a link", nil, ""), ("javascript:alert(1)", nil, "")]
    for (input, kind, ref) in rec {
        let r = OrgContext.recognize(input)
        expect(r?.kind == kind && (kind == nil || r?.ref == ref), "sources: recognize \(input)")
    }
    let sb = (try? JSONSerialization.jsonObject(with: OrgContext.sourceBody(kind: .driveFile, ref: "F", title: String(repeating: "t", count: 300), note: "n"))) as? [String: String]
    expect(sb?["kind"] == "drive_file" && sb?["title"]?.count == 200 && sb?["note"] == "n", "sources: POST body")
    var fs = OrgContext.Source(); fs.kind = .driveFolder; fs.ref = "1AbC"
    var us = OrgContext.Source(); us.kind = .url; us.ref = "javascript:x"
    expect(OrgContext.link(fs)?.absoluteString == "https://drive.google.com/drive/folders/1AbC" && OrgContext.link(us) == nil, "sources: links")

    // file index
    let files = OrgContext.files(CallSync.json([
        ["source_ref": "drive/F1", "name": "Spec.pdf", "description": "The spec", "mime": "application/pdf", "modified_time": "2026-11-10T08:00:00Z",
         "has_embedding": true, "indexed_by": ["id": "U2", "name": "Emily"], "indexed_at": "2026-11-16T09:00:00Z", "score": 0.83],
        ["source_ref": "F2", "name": NSNull(), "description": NSNull(), "mime": "", "has_embedding": false, "indexed_by": ["id": "u3", "name": ""]],
        ["name": "no ref"]]))
    expect(files?.count == 2 && files?[0].name == "Spec.pdf" && files?[0].score == 0.83 && files?[0].hasEmbedding == true
           && files?[0].indexedByName == "Emily" && files?[0].needsReindex == false && files?[1].needsReindex == true, "index: parse, gone indexer")
    expect(OrgContext.indexPath("/v1/orgs/o/projects/p", ref: "drive/F 1?x#y") == "/v1/orgs/o/projects/p/index/drive/F%201%3Fx%23y", "index: ref path")
    let longText = String(repeating: "word ", count: 300)
    let desc = OrgContext.describe(longText)
    expect(desc.count <= 600 && desc.hasSuffix("…") && OrgContext.describe("  a\n\n b ") == "a b", "index: description")
    let vec = Array(repeating: 0.5, count: 1024)
    let fb = (try? JSONSerialization.jsonObject(with: OrgContext.fileBody(name: "Spec", mime: "text/plain", modified: Date(timeIntervalSince1970: 0), description: "d", embedding: vec))) as? [String: Any]
    expect((fb?["embedding"] as? [Double])?.count == 1024 && fb?["modified_time"] as? String == "1970-01-01T00:00:00Z" && fb?["name"] as? String == "Spec", "index: PUT body")
    let fb2 = (try? JSONSerialization.jsonObject(with: OrgContext.fileBody(name: "S", mime: "", modified: nil, description: "", embedding: [1, 2]))) as? [String: Any]
    expect(fb2?["embedding"] == nil && fb2?["modified_time"] == nil, "index: a wrong-sized embedding is not sent")
    let q1 = (try? JSONSerialization.jsonObject(with: OrgContext.searchBody(text: "pricing", k: 80))) as? [String: Any]
    let q2 = (try? JSONSerialization.jsonObject(with: OrgContext.searchBody(text: "pricing", vector: vec))) as? [String: Any]
    expect(q1?["text"] as? String == "pricing" && q1?["k"] as? Int == 50 && q1?["vector"] == nil && (q2?["vector"] as? [Double])?.count == 1024 && q2?["text"] == nil,
           "index: search body")

    // history
    let h = OrgContext.history(CallSync.json([
        ["id": "12", "at": "2026-11-16T09:00:00Z", "by": ["id": "U1", "name": "Mike"], "entity": "state", "field": "body_md", "ref": "", "old": "# Old", "new": "# New"],
        ["id": 11, "entity": "source", "field": "", "ref": "s1", "old": NSNull(), "new": ["kind": "url", "ref": "https://x", "title": "Spec"], "by": ["id": NSNull(), "name": ""]],
        ["id": "10", "entity": "item", "field": "task.deleted", "ref": "t1", "old": ["deleted": false], "new": ["deleted": true]],
        ["entity": "card"]]))
    expect(h?.count == 3 && h?[0].byName == "Mike" && h?[0].restorable == true && h?[1].id == "11" && h?[1].old == nil && h?[2].restorable == false, "history: parse")
    expect(OrgContext.verb(h![1]) == "added" && OrgContext.verb(h![0]) == "changed" && OrgContext.verb(h![2]) == "removed", "history: verbs")
    expect(OrgContext.short(h![1].new) == "Spec" && OrgContext.short(String(repeating: "x", count: 100), max: 10).count == 10
           && OrgContext.short(["a", "b"]) == "a, b" && OrgContext.short(nil).isEmpty, "history: short values")
    let rb = (try? JSONSerialization.jsonObject(with: OrgContext.restoreBody(old: false))) as? [String: String]
    expect(rb == ["value": "new"], "history: restore body")
}

componentsD3()
whatsNewD3()
updatesD3()
orgsB6b()
prepSecuritySEC01()
projectsWizard0170()
itemIDs0170()
pull0170()
orgCard0170()
orgSetup0170()
homeLine0170()
orgRegisters0170()
console0170()
orgContext0170()
print("core checks: \(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
