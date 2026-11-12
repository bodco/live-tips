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
    expect(c.new == 1 && c.gone == 1 && c.changed == 0 && c.keptEdits == d.blocks.flatMap(\.facts).filter(\.isProtected).count && c.keptEdits >= 1, "diff: counts from marks \(c)")
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

deckCapacity097()
meetingSheet0100()
meetingSheetUI0100()
browserCapture0100()
sheetPipeline0100()
sheetFixer0100()
sheetHardening0100()
print("core checks: \(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
