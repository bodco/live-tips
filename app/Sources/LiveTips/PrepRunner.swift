import Foundation
import LiveTipsCore

/// "Prepare now" in Start call (2026-10-26): runs Claude Code headless (`claude -p`, the newest Opus)
/// in the project folder with the live-tips skill's prep instructions, on local files only (the
/// project folder, the local Notion mirror, earlier calls). No Notion, Jira or web: the mirror is
/// already local and the PM names the folders and documents that matter in the call context.
/// Writes <project>/live/prep-<YYYY-MM-DD-HHMM>-<title>.brief.md, .cards.json, .facts.json
/// (.outline.json for a presentation) and checks them with `lt prep-check`.
@MainActor
final class PrepRunner: ObservableObject {
    static let shared = PrepRunner()

    @Published var running = false
    @Published var startedAt: Date?
    @Published var result = ""            // last outcome, one line
    @Published var target = ""            // the prep base name being written
    /// 2026-10-26: objective progress from Claude Code's own event stream (stream-json): which files it
    /// reads and writes. Stages: instructions, sources, brief, cards, facts, check, done.
    @Published var progress: Double = 0
    @Published var stage = ""
    @Published var detail = ""
    private var filesRead = 0
    @Published var costUSD: Double?          // from the stream's final "result" event (API key; the plan shows the equivalent)
    private var lineBuf = Data()
    private var process: Process?

    /// How Claude Code is paid for: the PM's Claude account (Claude Code sign-in) or the app's API key.
    @Published var useAPI = UserDefaults.standard.bool(forKey: "prepUseAPI") {
        didSet { UserDefaults.standard.set(useAPI, forKey: "prepUseAPI") }
    }
    /// Claude Code model alias (always the newest of the family). Sonnet by default: it reads and
    /// extracts well, is quicker, and uses the account's limits several times slower than Opus.
    @Published var model = UserDefaults.standard.string(forKey: "prepModel") ?? "sonnet" {
        didSet { UserDefaults.standard.set(model, forKey: "prepModel") }
    }
    static let models: [(id: String, label: String)] = [("sonnet", "Sonnet, newest (recommended)"),
                                                         ("opus", "Opus, newest (best, slower)"),
                                                         ("haiku", "Haiku, newest (fastest)")]
    /// Claude Code sign-in (`claude auth status --json`): nil = not checked yet.
    @Published var loggedIn: Bool?
    @Published var authInfo = ""
    private var checking = false

    var hasAPIKey: Bool {
        let store = SecretStore(service: Bundle.main.bundleIdentifier ?? "io.github.example.livetips")
        return !(store.get(.claudeAPIKey) ?? "").isEmpty
    }

    /// Checks the Claude Code sign-in in the background (it can expire: the window shows it and offers Log in).
    func refreshAuth() {
        guard !checking, let claude = Self.claudePath else { return }
        checking = true
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: claude)
            p.arguments = ["auth", "status", "--json"]
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "ANTHROPIC_API_KEY")
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            var ok: Bool? = nil, info = ""
            if (try? p.run()) != nil {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if let s = String(data: data, encoding: .utf8), let i = s.firstIndex(of: "{"),
                   let o = try? JSONSerialization.jsonObject(with: Data(s[i...].utf8)) as? [String: Any] {
                    ok = (o["loggedIn"] as? Bool) ?? false
                    let who = (o["email"] as? String) ?? (o["account"] as? String) ?? ""
                    let plan = (o["subscriptionType"] as? String) ?? (o["authMethod"] as? String) ?? ""
                    info = [who, plan].filter { !$0.isEmpty && $0 != "none" }.joined(separator: ", ")
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.loggedIn = ok
                    self.authInfo = info
                    self.checking = false
                }
            }
        }
    }

    /// Opens Terminal with `claude auth login` (the sign-in needs a browser and sometimes a pasted code).
    func openLogin() {
        guard let claude = Self.claudePath else { return }
        let cmd = "'" + claude + "' auth login"
        let script = "tell application \"Terminal\"\n activate\n do script \"" + cmd.replacingOccurrences(of: "\"", with: "\\\"") + "\"\nend tell"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }

    /// The `claude` command line tool (Claude Code).
    static var claudePath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [home + "/.local/bin/claude", home + "/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The live-tips skill folder with SKILL.md and references/ (the prep instructions).
    static func skillDir(workRoot: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let w = (workRoot as NSString).expandingTildeInPath
        var c: [String] = []
        if let d = UserDefaults.standard.string(forKey: "prepSkillDir"), !d.isEmpty { c.append((d as NSString).expandingTildeInPath) }
        c += [home + "/.claude/skills/live-tips", w + "/Skills/src/live-tips", w + "/Control Tower/plugin/skills/live-tips"]
        return c.first { FileManager.default.fileExists(atPath: ($0 as NSString).appendingPathComponent("SKILL.md")) }
    }

    struct Request {
        var title: String
        var date: Date
        var projectName: String
        var slug: String
        var root: String
        var config: String
        var audience: String
        var callType: String
        var hiringRole: String
        var languages: [String]
        var context: String
        var workspaceRoot: String
        var folders: [String] = []          // "Add folder" in Start call: read these first, they may be outside the project
    }

    func cancel() {
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil   // QA: no stage updates after Stop
        process?.terminate()
        process = nil
        lineBuf = Data()
        running = false
        result = "Stopped"
    }

    /// Starts the prep. Returns an error line, or nil when it started.
    func start(_ r: Request) -> String? {
        if running { return "A preparation is already running" }
        guard let claude = Self.claudePath else { return "Claude Code (the claude command) is not installed" }
        let c = AppConfig.load(from: AppPaths.config)
        guard let skill = Self.skillDir(workRoot: c.workRoot) else { return "The live-tips skill folder was not found" }
        let appRoot = c.effectiveAppRoot(appSupport: AppPaths.support.path)
        let lt = (appRoot as NSString).appendingPathComponent("bin/lt")
        let live = (r.root as NSString).appendingPathComponent("live")
        try? FileManager.default.createDirectory(atPath: live, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"
        let h = DateFormatter(); h.dateFormat = "yyyy-MM-dd HH:mm"
        let base = (live as NSString).appendingPathComponent("prep-\(f.string(from: r.date))-\(StartCallModel.slugify(r.title))")
        let refs = ["sweep.md", "speech.md"] + (r.callType == "presentation" ? ["presentation.md"] : [])
            + (r.callType == "interview" ? ["hiring.md"] : []) + (r.audience == "client" ? ["culture.md"] : [])
        var notion = [(r.root as NSString).appendingPathComponent("_notion")]
        if !r.workspaceRoot.isEmpty { notion.append((r.workspaceRoot as NSString).appendingPathComponent("_notion")) }
        let prompt = """
        Prepare Live Tips for a call ahead of time (a "prep ahead" of the live-tips skill). Work with local files: \
        no Notion or Jira APIs, no MCP tools, no recording, no subagents (the Notion data is already mirrored locally). \
        The only web access: links written in the call context below (public pages: a client's site, a shared Google \
        Doc, a public Notion page). Read them with WebFetch; for a Google Doc use \
        https://docs.google.com/document/d/<id>/export?format=txt, for a Google Sheet .../export?format=csv. A page \
        that needs a sign-in or shows nothing useful: say so in the brief's sources line and go on. No other web search.

        Call: "\(r.title)", \(h.string(from: r.date)). Project: \(r.projectName) (slug \(r.slug)). Project folder: \(r.root). \
        Project config: \(r.config.isEmpty ? "none" : r.config). Audience: \(r.audience). Meeting type: \(r.callType)\
        \(r.callType == "interview" ? ", role " + r.hiringRole : ""). Call languages: \(r.languages.joined(separator: "+")).

        The PM's call context (what matters, the folders and documents to read first):
        \(r.context.isEmpty ? "(none)" : r.context)
        \(r.folders.isEmpty ? "" : "Folders the PM added (look through them first; read fully the files the context names): " + r.folders.joined(separator: "; "))

        Read first: \(skill)/SKILL.md (the Start checklist, steps 5-6, and "prep ahead"), then \
        \(refs.map { skill + "/references/" + $0 }.joined(separator: ", ")). Follow their content rules and file formats \
        exactly; skip every part that needs Notion, Jira, the Agent tool, device_bash, polling or a recording \
        (all paths here are local Mac paths).

        Sources, in this order: the folders and documents named in the call context (read them fully; .docx with \
        `textutil -convert txt -stdout <file>`), the project config, the Current State and other rows of the local \
        Notion mirror (\(notion.joined(separator: ", "))), the recent calls in \(live) (transcripts *.md and their \
        *.tips.jsonl, newest first; `"\(c.engine.python)" "\(lt)" digest "\(r.root)" --days 14` gives a digest), then other \
        project files found with Grep and Glob. Newer facts win; say in the brief which sources were used and what is old.

        Write exactly these files and nothing else:
        - \(base).brief.md, first line: "# Live Brief: \(r.title) (prep, \(h.string(from: r.date)))"
        - \(base).cards.json
        - \(base).facts.json\(r.callType == "presentation" ? "\n- \(base).outline.json" : "")
        Then run `"\(c.engine.python)" "\(lt)" prep-check "\(base).md"` and fix the files until it prints verdict: OK.
        End with one line: the sources used.
        """
        if useAPI && !hasAPIKey { return "No Claude API key in Settings > Keys" }
        if !useAPI && loggedIn == false { return "Claude Code is not signed in: Log in, or switch to API key" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        let py = c.engine.python
        let allowed = ["Read", "Grep", "Glob", "Write", "Edit", "WebFetch", "Bash(\(py):*)", "Bash(\"\(py)\":*)", "Bash(python3:*)", "Bash(textutil:*)",
                       "Bash(ls:*)", "Bash(find:*)", "Bash(head:*)", "Bash(wc:*)"]
        p.arguments = ["-p", prompt, "--model", model, "--output-format", "stream-json", "--verbose", "--permission-mode", "acceptEdits",
                       "--allowedTools", allowed.joined(separator: ","),
                       "--add-dir", skill, "--add-dir", live] + (r.workspaceRoot.isEmpty ? [] : ["--add-dir", r.workspaceRoot])
                       + r.folders.flatMap { ["--add-dir", $0] }
        p.currentDirectoryURL = URL(fileURLWithPath: r.root)
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""].joined(separator: ":")
        // The app's Claude API key (Settings > Keys), so it works without a Claude Code sign-in; billed like the tips.
        // Passed to the child only, never written or logged.
        env.removeValue(forKey: "ANTHROPIC_API_KEY")      // account mode: Claude Code's own sign-in
        env.removeValue(forKey: "ANTHROPIC_CUSTOM_HEADERS")
        let store = SecretStore(service: Bundle.main.bundleIdentifier ?? "io.github.example.livetips")
        if useAPI, let key = store.get(.claudeAPIKey), !key.isEmpty {
            env["ANTHROPIC_API_KEY"] = key
            if let ws = store.get(.claudeWorkspaceID), !ws.isEmpty { env["ANTHROPIC_CUSTOM_HEADERS"] = "anthropic-workspace-id: " + ws }
        }
        p.environment = env
        let logs = (appRoot as NSString).appendingPathComponent("logs")
        try? FileManager.default.createDirectory(atPath: logs, withIntermediateDirectories: true)
        let log = FileHandle.forAppending(path: (logs as NSString).appendingPathComponent("prep-claude.log"))
        log?.write(("\n==== \(Date()) \(r.title) -> \(base)\n").data(using: .utf8)!)
        let out = Pipe()
        p.standardOutput = out
        p.standardError = log
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { return }
            log?.write(d)
            Task { @MainActor in self?.consume(d, skill: skill, base: base) }
        }
        p.terminationHandler = { [weak self] proc in
            let ok = proc.terminationStatus == 0 && FileManager.default.fileExists(atPath: base + ".brief.md")
                && FileManager.default.fileExists(atPath: base + ".facts.json")
            Task { @MainActor in
                guard let self = self, self.process === proc else { return }
                (proc.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
                if ok {
                    self.progress = 1; self.stage = "Done"
                    // QA 26.10: the call may have started while the prep was written: pick up the rest now.
                    if CallEngine.shared.isRunning, let f = CallEngine.shared.lastFile { CallEngine.shared.adoptPrep(file: f) }
                }
                self.running = false
                self.process = nil
                let mins = Int((Date().timeIntervalSince(self.startedAt ?? Date())) / 60)
                let tail = (try? String(contentsOfFile: (logs as NSString).appendingPathComponent("prep-claude.log"), encoding: .utf8))
                    .map { String($0.suffix(600)) } ?? ""
                if !ok && (tail.contains("authenticate") || tail.contains("OAuth") || tail.contains("log in") || tail.contains("/login")) {
                    self.result = "Claude Code is not signed in: Log in, or switch to API key"
                    self.refreshAuth()
                } else if !ok && (tail.lowercased().contains("usage limit") || tail.lowercased().contains("rate limit")) {
                    self.result = "The Claude account hit its limit: switch to API key and try again"
                } else {
                    let cost = self.costUSD.map { String(format: " · $%.2f%@", $0, self.useAPI ? "" : " (plan)") } ?? ""
                    self.result = ok ? "✓ Preparation ready in \(max(1, mins)) min" + cost : "Preparation failed (exit \(proc.terminationStatus)); see logs/prep-claude.log"
                }
            }
        }
        do { try p.run() } catch { return "Could not start Claude Code: \(error.localizedDescription)" }
        process = p
        running = true
        startedAt = Date()
        target = (base as NSString).lastPathComponent
        result = ""
        progress = 0.02; stage = "Starting Claude Code"; detail = ""; filesRead = 0; lineBuf = Data(); costUSD = nil
        return nil
    }

    /// Reads Claude Code's stream-json events and turns tool calls into stages (no guessing from time).
    private func consume(_ data: Data, skill: String, base: String) {
        lineBuf.append(data)
        while let r = lineBuf.range(of: Data([0x0A])) {
            let ln = lineBuf.subdata(in: lineBuf.startIndex..<r.lowerBound)
            lineBuf.removeSubrange(lineBuf.startIndex..<r.upperBound)
            guard let o = try? JSONSerialization.jsonObject(with: ln) as? [String: Any] else { continue }
            if (o["type"] as? String) == "system", progress < 0.05 { set(0.05, "Reading the instructions", "") }
            if (o["type"] as? String) == "result" { costUSD = (o["total_cost_usd"] as? Double) ?? (o["total_cost_usd"] as? NSNumber)?.doubleValue }
            guard (o["type"] as? String) == "assistant", let msg = o["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]] else { continue }
            for c in content where (c["type"] as? String) == "tool_use" {
                let name = c["name"] as? String ?? ""
                let input = c["input"] as? [String: Any] ?? [:]
                let path = (input["file_path"] as? String) ?? (input["path"] as? String) ?? ""
                let file = (path as NSString).lastPathComponent
                switch name {
                case "Write", "Edit":
                    if path.hasSuffix(".brief.md") { set(0.70, "Writing the brief", file) }
                    else if path.hasSuffix(".cards.json") { set(0.80, "Writing the cards", file) }
                    else if path.hasSuffix(".facts.json") { set(0.87, "Writing the fact book", file) }
                    else if path.hasSuffix(".outline.json") { set(0.90, "Writing the outline", file) }
                    else { set(max(progress, 0.65), "Writing", file) }
                case "Bash":
                    let cmd = input["command"] as? String ?? ""
                    if cmd.contains("prep-check") { set(max(progress, 0.93), "Checking the preparation", "lt prep-check") }
                    else if cmd.contains("digest") { set(max(progress, 0.2), "Reading the recent calls", "lt digest") }
                    else if cmd.contains("textutil") { filesRead += 1; sources(file.isEmpty ? "a document" : file) }
                    else { sources("") }
                case "Read":
                    if path.hasPrefix(skill) { set(max(progress, 0.08), "Reading the instructions", file) }
                    else { filesRead += 1; sources(file) }
                case "WebFetch":
                    filesRead += 1; sources("web: " + String(((input["url"] as? String) ?? "").prefix(60)))
                case "Grep", "Glob":
                    sources("search: " + String(((input["pattern"] as? String) ?? "").prefix(40)))
                default:
                    break
                }
            }
        }
    }

    /// Sources: 15% to 65%, a step per file read (most preps read 10-30 files).
    private func sources(_ what: String) {
        guard progress < 0.65 else { return }
        let p = min(0.64, 0.15 + Double(filesRead) * 0.02)
        set(max(progress, p), "Reading the sources (\(filesRead) file\(filesRead == 1 ? "" : "s"))", what)
    }

    private func set(_ p: Double, _ s: String, _ d: String) { progress = p; stage = s; detail = d }
}
