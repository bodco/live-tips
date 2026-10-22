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
    try? fm.removeItem(atPath: tmp)
    var c = AppConfig()
    expect(c.effectiveAppRoot(appSupport: "/AS") == "/AS", "app root default")
    c.workRoot = "/w"
    expect(c.effectiveAppRoot(appSupport: "/AS") == "/w/Tools/LiveTips", "app root in work folder")
    let old = try? JSONDecoder().decode(AppConfig.self, from: Data("{\"uiLanguage\":\"uk\"}".utf8))
    expect(old?.uiLanguage == "uk" && old?.showInDock == true, "config decodes older files")
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
print("core checks: \(passed) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
