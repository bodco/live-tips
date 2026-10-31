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
    /// 2026-10-27 (owner, Up next): the call this preparation is for (StartCallModel.id). It joins a live call
    /// only when that call has the same id, so a preparation for an upcoming call never lands in the live one.
    @Published var callID: UUID?
    /// 2026-10-26: objective progress from Claude Code's own event stream (stream-json): which files it
    /// reads and writes. Stages: instructions, sources, brief, cards, facts, check, done.
    @Published var progress: Double = 0
    @Published var stage = ""
    @Published var detail = ""
    private var filesRead = 0
    /// 0.8.5: the last Prepare of a talk: slides rewritten and the ones kept with the PM's edits (P4 done).
    @Published var lastTalk: (rewritten: Int, kept: [Int])?
    var resultMeta: [String: Any] = [:]       // 0.8.5: duration, turns and tokens of the last preparation
    @Published var costUSD: Double?          // from the stream's final "result" event (API key; the plan shows the equivalent)
    private var lineBuf = Data()
    private var process: Process?

    /// How Claude Code is paid for: the PM's Claude account (Claude Code sign-in) or the app's API key.
    /// 0.8.2: chosen in Settings > AI (AppConfig.ai.prep); `runRoute` is the way this run took (auto-switch).
    var useAPI: Bool { AppConfig.load(from: AppPaths.config).ai.prep == AIRoute.api }
    @Published var runRoute = AIRoute.code
    var switchedOnce = false
    var localTried = false          // 0.8.5: the fallback to the model on this Mac ran for this preparation
    /// Claude Code model alias (always the newest of the family). Sonnet by default: it reads and
    /// extracts well, is quicker, and uses the account's limits several times slower than Opus.
    @Published var model = UserDefaults.standard.string(forKey: "prepModel") ?? "sonnet" {
        didSet { UserDefaults.standard.set(model, forKey: "prepModel") }
    }
    /// 0.8.5 (owner): the Ollama model of a preparation on this Mac (Settings > AI, route "local").
    var localModel: String { get { LocalLLM.model } set { LocalLLM.model = newValue } }
    static let ollamaURL = "http://127.0.0.1:11434"

    /// The models Ollama has, or nil when it does not answer.
    static func ollamaModels(_ done: @escaping ([String]?) -> Void) {
        var req = URLRequest(url: URL(string: ollamaURL + "/api/tags")!); req.timeoutInterval = 3
        URLSession.shared.dataTask(with: req) { d, _, e in
            let names = (d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["models"] as? [[String: Any]])?
                .compactMap { $0["name"] as? String }
            DispatchQueue.main.async { done(e == nil ? (names ?? []) : nil) }
        }.resume()
    }

    // MARK: 0.8.5 (owner): every preparation kept for comparison, each one made from a clean start

    /// <appRoot>/prep-runs/<base name>/: outside the project, so no preparation reads another one.
    static func runsDir(_ base: String) -> String {
        let c = AppConfig.load(from: AppPaths.config)
        return (((c.effectiveAppRoot(appSupport: AppPaths.support.path) as NSString).appendingPathComponent("prep-runs") as NSString)
            .appendingPathComponent((base as NSString).lastPathComponent))
    }
    static let runFiles = ["brief.md", "cards.json", "facts.json", "prep.json", "brief.orig.md", "brief.prev.md", "digest.md"]
    static func stamp() -> String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"; return f.string(from: Date()) }

    /// Before a full preparation: the previous one's files leave the live folder (kept in prep-runs), so the new one
    /// cannot read or continue it. Returns that folder, or nil when there was nothing.
    static func moveAside(base: String) -> String? {
        let fm = FileManager.default
        let have = runFiles.filter { fm.fileExists(atPath: base + "." + $0) }
        guard !have.isEmpty else { return nil }
        let dir = (runsDir(base) as NSString).appendingPathComponent(stamp() + "-before")
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for f in have { try? fm.moveItem(atPath: base + "." + f, toPath: (dir as NSString).appendingPathComponent(f)) }
        return dir
    }

    /// After it: a copy of what it wrote and run.json (route, model, time, price, tokens, turns, sources); the
    /// previous brief is back as <base>.brief.prev.md (Restore previous version); a failed run puts the old files back.
    static func keepRun(base: String, aside: String?, ok: Bool, meta: [String: Any]) {
        let fm = FileManager.default
        let route = meta["route"] as? String ?? "", model = meta["model"] as? String ?? ""
        let dir = (runsDir(base) as NSString).appendingPathComponent(stamp() + "-" + route + "-" + model.replacingOccurrences(of: ":", with: "_") + (ok ? "" : "-failed"))
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for f in runFiles where fm.fileExists(atPath: base + "." + f) { try? fm.copyItem(atPath: base + "." + f, toPath: (dir as NSString).appendingPathComponent(f)) }
        if let d = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent("run.json")))
        }
        guard let aside else { return }
        if ok {
            let old = (aside as NSString).appendingPathComponent("brief.md")
            if fm.fileExists(atPath: old) { try? fm.removeItem(atPath: base + ".brief.prev.md"); try? fm.copyItem(atPath: old, toPath: base + ".brief.prev.md") }
        } else {
            for f in runFiles where !fm.fileExists(atPath: base + "." + f) {
                let src = (aside as NSString).appendingPathComponent(f)
                if fm.fileExists(atPath: src) { try? fm.copyItem(atPath: src, toPath: base + "." + f) }
            }
        }
    }

    static var models: [(id: String, label: String)] { [("sonnet", L("prep.model.sonnet")), ("opus", L("prep.model.opus")),
                                                         ("haiku", L("prep.model.haiku"))] }
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
    nonisolated static var claudePath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [home + "/.local/bin/claude", home + "/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The live-tips skill folder with SKILL.md and references/ (the prep instructions).
    /// 0.8.5 (owner): one line per preparation in state/spend-ledger.jsonl, next to the Python stages.
    static func ledger(job: String, route: String, usd: Double?, meta: [String: Any], ok: Bool) {
        let f = ISO8601DateFormatter(); f.timeZone = .current
        var row: [String: Any] = ["at": f.string(from: Date()), "job": job, "route": route, "error": !ok]
        if let u = usd { row["usd"] = (u * 1_000_000).rounded() / 1_000_000 }
        if let t = meta["tokens"] as? [String: Any] { for (k, v) in t { row[k] = v } }
        if let d = meta["duration_s"] { row["duration_s"] = d }
        if let n = meta["turns"] { row["turns"] = n }
        let path = ((AIRoute.statePath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("spend-ledger.jsonl")
        guard let d = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(d + Data([0x0A])); try? h.close() }
        else { try? (d + Data([0x0A])).write(to: URL(fileURLWithPath: path)) }
    }

    static func skillDir(workRoot: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let w = (workRoot as NSString).expandingTildeInPath
        var c: [String] = []
        let fm = FileManager.default
        let has = { (d: String) in fm.fileExists(atPath: (d as NSString).appendingPathComponent("SKILL.md")) }
        if let d = UserDefaults.standard.string(forKey: "prepSkillDir"), !d.isEmpty, has((d as NSString).expandingTildeInPath) {
            return (d as NSString).expandingTildeInPath           // chosen by hand: always wins
        }
        c += [home + "/.claude/skills/live-tips", w + "/Skills/src/live-tips", w + "/live-tips/skill", w + "/Control Tower/plugin/skills/live-tips"]
        if let r = Bundle.main.resourcePath { c.append((r as NSString).appendingPathComponent("skill")) }   // 2026-10-29: the copy inside the app
        // 0.8.5 (owner: the speech points had no full text): an older copy of the skill was found first and the
        // preparation followed its old rules. The newest copy wins (by its newest file among SKILL.md and references).
        func newest(_ d: String) -> Date {
            var files = [(d as NSString).appendingPathComponent("SKILL.md")]
            let refs = (d as NSString).appendingPathComponent("references")
            files += ((try? fm.contentsOfDirectory(atPath: refs)) ?? []).map { (refs as NSString).appendingPathComponent($0) }
            return files.compactMap { (try? fm.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }.max() ?? .distantPast
        }
        return c.filter(has).max { newest($0) < newest($1) }
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
        var useProjectFolder = true         // 2026-10-27 (owner): off = never read the project folder, only write the prep into live/
        var callID: UUID? = nil             // 2026-10-27 (owner, Up next): which call it is for
        // Pacenote 0.8 (rules/freshness.json > refresh): update an existing brief from the files changed since.
        var refreshBase: String? = nil
        var refreshOf: Date? = nil
        var changed: [String] = []
        var deck: DeckSetup? = nil          // 0.8.5: a Presentation call with a deck (P2)
        var salesMethod: String? = nil      // 0.8.7 (H3): Sales mode on: the method key (rules/sales.yaml)
        var company = ""                    // 0.8.7 (H3): the only thing that may go into a web search
    }

    /// 0.8.7 (H3, rules/sales.yaml > prep.sections): the sales part of the brief. The web search is the company's
    /// name or domain only; nothing from the project files goes into a search.
    static func salesPrompt(_ r: Request, base: String, web: Bool) -> String {
        guard let m = r.salesMethod else { return "" }
        // 0.8.7 (F4): without a CRM key there is no From CRM section, even when an old snapshot is still on disk
        let crmLine = !CRMService.shared.connected ? "" : "## From CRM: " + (FileManager.default.fileExists(atPath: base + ".crm.md") ? "Read \(base).crm.md (a CRM snapshot; say how old it is from its Taken line)." : "There is no CRM snapshot.") + "\n"
        return """

        SALES CALL (method: \(m), see rules/sales.yaml in the skill for its criteria). Add these sections to the brief, in this order:
        ## Company: \(web ? "what they do, size, news of the last 90 days, with links. Use WebSearch and WebFetch ONLY with the company's name or domain (\(r.company.isEmpty ? r.projectName : r.company)); never put anything from the project files, the context or people's names into a search. End the section with the line: \"Searched the web for: \(r.company.isEmpty ? r.projectName : r.company). Nothing from your files was sent.\"" : "from the project files only (web search is off in Settings > AI).")
        \(crmLine)## Where we are: what is known and unknown for each criterion of the method, from earlier calls of this series\(crmLine.isEmpty ? "" : " and the CRM"), who said what.
        ## Likely objections: 3 to 5, each with a short answer; use <project>/pacenote/answer-cards.md when it has a match.
        ## Questions to ask: the questions that close the gaps.
        ## Goal of this call: one wanted next step.
        """
    }

    /// A preparation joins the live call only when it was made for that very call (Up next, 2026-10-27).
    nonisolated static func joinsLiveCall(prepFor: UUID?, liveCall: UUID?) -> Bool {
        guard let a = prepFor, let b = liveCall else { return prepFor == nil && liveCall == nil }
        return a == b
    }

    /// 0.8.5 fix (owner, 29.10): a call started from the calendar or Home is a new form, so its id differs from the
    /// Up next item the preparation was made for. The same call is also recognised by its title and day, so the
    /// preparation's progress shows in the tips window and its files join the call when they are ready.
    @Published var forTitle = ""
    @Published var forDate: Date?
    static func sameCall(prepTitle: String, prepDate: Date?, liveTitle: String, liveDate: Date?) -> Bool {
        let a = StartCallModel.slugify(prepTitle), b = StartCallModel.slugify(liveTitle)
        guard !a.isEmpty, a == b, let d1 = prepDate else { return false }
        return Calendar.current.isDate(d1, inSameDayAs: liveDate ?? Date())
    }
    /// The running (or last) preparation belongs to the live call: by id, else by title and day.
    var joinsCurrentCall: Bool {
        if Self.joinsLiveCall(prepFor: callID, liveCall: CallEngine.shared.currentCallID) { return true }
        let r = CallEngine.shared.callRequest
        let when = (r["scheduled_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return Self.sameCall(prepTitle: forTitle, prepDate: forDate, liveTitle: r["title"] as? String ?? "", liveDate: when)
    }

    func cancel() {
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil   // QA: no stage updates after Stop
        process?.terminate()
        process = nil
        lineBuf = Data()
        running = false
        result = L("prep.stopped")
        UpNext.shared.prepFinished(id: callID, base: nil, ok: false, stopped: true)
    }

    /// Starts the prep. Returns an error line, or nil when it started.
    func start(_ r: Request, route forced: String? = nil) -> String? {
        if running { return L("prep.err.running") }
        if forced == nil { switchedOnce = false; localTried = false }
        let wantsLocal = (forced ?? AppConfig.load(from: AppPaths.config).ai.prep) == AIRoute.local
        guard let claude = Self.claudePath ?? (wantsLocal ? "/usr/bin/true" : nil) else { return L("prep.err.noClaude") }
        let c = AppConfig.load(from: AppPaths.config)
        guard let skill = Self.skillDir(workRoot: c.workRoot) else { return L("prep.err.noSkill") }
        let appRoot = c.effectiveAppRoot(appSupport: AppPaths.support.path)
        let lt = (appRoot as NSString).appendingPathComponent("bin/lt")
        let live = (r.root as NSString).appendingPathComponent("live")
        try? FileManager.default.createDirectory(atPath: live, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"
        let h = DateFormatter(); h.dateFormat = "yyyy-MM-dd HH:mm"
        let base = r.refreshBase ?? (live as NSString).appendingPathComponent("prep-\(f.string(from: r.date))-\(StartCallModel.slugify(r.title))")
        let refs = ["sweep.md", "speech.md"] + (r.callType == "presentation" ? ["presentation.md"] : [])
            + (r.callType == "interview" ? ["hiring.md"] : []) + (r.audience == "client" ? ["culture.md"] : [])
        var notion = [(r.root as NSString).appendingPathComponent("_notion")]
        if !r.workspaceRoot.isEmpty { notion.append((r.workspaceRoot as NSString).appendingPathComponent("_notion")) }
        let fullPrompt = """
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
        \(r.folders.filter { StartCallModel.isDir($0) }.isEmpty ? "" : "Folders the PM added (look through them first; read fully the files the context names): " + r.folders.filter { StartCallModel.isDir($0) }.joined(separator: "; "))
        \(r.folders.filter { !StartCallModel.isDir($0) }.isEmpty ? "" : "Files the PM added (read each fully; read nothing else in their folders): " + r.folders.filter { !StartCallModel.isDir($0) }.joined(separator: "; "))

        Read first: \(skill)/SKILL.md (the Start checklist, steps 5-6, and "prep ahead"), then \
        \(refs.map { skill + "/references/" + $0 }.joined(separator: ", ")). Follow their content rules and file formats \
        exactly; skip every part that needs Notion, Jira, the Agent tool, device_bash, polling or a recording \
        (all paths here are local Mac paths).

        \(r.useProjectFolder ? """
        Sources, in this order: the folders and documents named in the call context (read them fully; .docx with \
        `textutil -convert txt -stdout <file>`), the project config, the Current State and other rows of the local \
        Notion mirror (\(notion.joined(separator: ", "))), the recent calls in \(live) (transcripts *.md and their \
        *.tips.jsonl, newest first; the digest of the last 14 days is in \(base).digest.md, made by the app), then other \
        project files found with Grep and Glob. Newer facts win; say in the brief which sources were used and what is old.
        """ : """
        The PM EXCLUDED the project folder for this call: do not read, list or search anything in \(r.root) or the \
        Notion mirror, and not the earlier calls in \(live); only write the files below into \(live). Sources: only \
        the folders the PM added, the documents and links named in the call context and the project config. Say in the \
        brief that the project folder was excluded on purpose.
        """)

        \(Self.previousCallsBlock(live: live, title: r.title))
        \(EditLog.promptBlock(title: r.title, project: (r.root as NSString).lastPathComponent))
        Previous meetings (2026-10-28, owner): read the previous calls of this meeting in depth, as the skill's sweep.md \
        step 3b says: what was discussed, every question and whether it was answered fully, partly or not, open items, \
        action items (owner, due, status checked against newer sources), promises, the other side's concerns. The brief \
        is detailed (up to ~2500 words) and has the "Previous meetings" section (sweep.md, item 1a); open items go into \
        that section; only those likely to come up on this call become checklist lines and cards (fewer, surer cards).

        Write exactly these files and nothing else:
        - \(base).brief.md, first line: "# Live Brief: \(r.title) (prep, \(h.string(from: r.date)))"
        - \(base).cards.json
        - \(base).facts.json\(r.callType == "presentation" ? "\n- \(base).outline.json" : "")
        The app checks the files with `lt prep-check` when you finish (cards and facts must be valid JSON lists with the \
        fields of the formats). Participants: compare the invitation with the project config and the recent notes; a \
        person in the invitation who has left the project is named as not expected (sweep.md, Names).
        End with one line: the sources used.
        """
        let refreshPrompt = """
        Refresh an existing Live Tips preparation (the live-tips skill's sweep.md, section "Refresh"). Work with local \
        files only: no Notion or Jira APIs, no MCP tools, no web, no subagents.

        Call: "\(r.title)", \(h.string(from: r.date)). Project: \(r.projectName) (slug \(r.slug)). Project folder: \(r.root).
        The brief: \(base).brief.md (the PM's original is \(base).brief.orig.md when it exists: lines that differ are the \
        PM's edits and stay). Facts: \(base).facts.json, cards: \(base).cards.json.
        Files changed since the brief was made (newest first; read only these, fully):
        \(r.changed.isEmpty ? "(none: the brief is only old; check the project's Current State in the local Notion mirror \(notion.joined(separator: ", ")) and the newest call in \(live))" : r.changed.map { "- " + $0 }.joined(separator: "\n"))

        Read first: \(skill)/SKILL.md (section "Agenda, commitments, brief freshness") and \(skill)/references/sweep.md \
        (section "Refresh"). Rewrite only the sections of the brief these files change; keep the checklist order, every \
        ticked item and the PM's lines. Update the facts and cards only for the same topics. Put one line at the top of the \
        brief: "Updated <time>: <N> files, sections: ...". The app checks the files with `lt prep-check` when you finish. \
        End with one line: what changed.
        """
        // 0.8.5 (rules/presentation.yaml > prepare_again): one previous version is kept; the deck goes to <base>.deck.json.
        let deckTexts = TalkFiles.before(base: base, deck: r.deck)
        let deckLines = r.deck.map { TalkFiles.prompt(base: base, deck: $0) } ?? ""
        let prompt = (r.refreshBase == nil ? fullPrompt : refreshPrompt) + (deckLines.isEmpty ? "" : "\n\n" + deckLines)
            + Self.salesPrompt(r, base: base, web: AppConfig.load(from: AppPaths.config).salesWebSearch)
        if r.refreshBase != nil { UsageLog.log("prepare_again") }
        // 0.8.2: the way from Settings > AI; with auto-switch the other one when this one cannot run at all.
        let routes = c.ai
        var route = forced ?? routes.prep
        let usable: (String) -> Bool = { $0 == AIRoute.api ? self.hasAPIKey : self.loggedIn != false }
        if forced == nil && routes.autoSwitch && !usable(route) && usable(AIRoute.other(route)) { route = AIRoute.other(route) }
        // rules/ai.yaml > fallback: no Claude way can run at all -> the model on this Mac
        if forced == nil && routes.localFallback && route != AIRoute.local && !usable(route) && !usable(AIRoute.other(route)) { route = AIRoute.local }
        if route == AIRoute.api && !hasAPIKey { return L("prep.err.noKey") }
        if route == AIRoute.code && loggedIn == false { return L("prep.err.notSigned") }
        let useAPI = route == AIRoute.api
        let isLocal = route == AIRoute.local
        let runModel = isLocal ? localModel : model
        let aside = r.refreshBase == nil ? Self.moveAside(base: base) : nil      // a clean start, the old one kept
        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        let py = c.engine.python
        // Security (audit 2026-10-27): least privilege. Only the two lt commands, read-only shell helpers, the
        // textutil conversion, WebFetch only to the hosts named in the PM's context, and writes only to this
        // prep's own files. "default" permission mode: anything else is denied in -p mode (no prompt to accept).
        let ltq = "\"\(py)\" \"\(lt)\""
        var allowed = ["Read", "Grep", "Glob",
                       "Write(/\(base).*)", "Edit(/\(base).*)",
                       "Bash(\(ltq) prep-check:*)", "Bash(\(ltq) digest:*)",
                       "Bash(\(py) \(lt) prep-check:*)", "Bash(\(py) \(lt) digest:*)",
                       "Bash(textutil -convert txt -stdout:*)", "Bash(ls:*)", "Bash(head:*)", "Bash(wc:*)"]
        allowed += Self.webHosts(in: r.context).map { "WebFetch(domain:\($0))" }
        let salesWeb = r.salesMethod != nil && c.salesWebSearch      // 0.8.7 (H3): only for a sales preparation
        if salesWeb { allowed += ["WebSearch", "WebFetch"] }
        let denied = (py.hasPrefix("/") ? ["Bash(python3:*)", "Bash(python:*)"] : []) + ["Bash(curl:*)", "Bash(wget:*)", "Bash(sh:*)", "Bash(bash:*)", "Bash(zsh:*)", "Bash(osascript:*)",
                      "Bash(find:*)", "Bash(rm:*)", "Bash(open:*)"] + (salesWeb ? [] : ["WebSearch"]) + ["Task", "NotebookEdit",
                      "Edit(/\(skill)/**)", "Write(/\(skill)/**)"]
        p.arguments = ["-p", prompt, "--model", model, "--output-format", "stream-json", "--verbose", "--permission-mode", "default",
                       "--allowedTools", allowed.joined(separator: ","),
                       "--disallowedTools", denied.joined(separator: ","),
                       "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
                       "--add-dir", skill, "--add-dir", live] + (r.workspaceRoot.isEmpty ? [] : ["--add-dir", r.workspaceRoot])
                       + Array(Set(r.folders.map { StartCallModel.isDir($0) ? $0 : ($0 as NSString).deletingLastPathComponent })).flatMap { ["--add-dir", $0] }
        if let dir = r.deck?.info?.dir { p.arguments! += ["--add-dir", dir] }
        if isLocal {
            // rules/ai.yaml > local: the engine builds the context pack and asks Ollama once (livetips_m0.localprep)
            let req: [String: Any] = ["title": r.title, "when": h.string(from: r.date), "project_name": r.projectName, "root": r.root,
                "config": r.config, "audience": r.audience, "call_type": r.callType, "languages": r.languages, "context": r.context,
                "files": r.folders.filter { !StartCallModel.isDir($0) }, "folders": r.folders.filter { StartCallModel.isDir($0) },
                "live": live, "notion": notion, "skill": skill, "base": base, "lt": [c.engine.python, lt], "model": localModel,
                "url": Self.ollamaURL, "use_project_folder": r.useProjectFolder, "brief_lang": L10n.lang]
            let reqPath = ((appRoot as NSString).appendingPathComponent("state") as NSString).appendingPathComponent("localprep-request.json")
            if let d = try? JSONSerialization.data(withJSONObject: req) { try? d.write(to: URL(fileURLWithPath: reqPath)) }
            p.executableURL = URL(fileURLWithPath: c.engine.sidecarPython)
            p.arguments = ["-m", "livetips_m0.localprep", "--request", reqPath]
        }
        p.currentDirectoryURL = URL(fileURLWithPath: isLocal ? c.engine.sidecarDir : (r.useProjectFolder ? r.root : live))
        // 0.8.5 (owner: "lt digest" and "lt prep-check" were refused to Claude in every run): the app makes the digest
        // right before Claude starts (a one-line shell that then becomes Claude) and checks the files after it.
        var digestEnv: [String: String] = [:]
        if !isLocal, r.useProjectFolder, let exe = p.executableURL?.path {
            p.arguments = ["-c", "\"$LT_PY\" \"$LT_BIN\" digest \"$LT_ROOT\" --days 14 > \"$LT_DIGEST\" 2>/dev/null; exec \"$LT_EXE\" \"$@\"", "sh"] + (p.arguments ?? [])
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            digestEnv = ["LT_PY": c.engine.python, "LT_BIN": lt, "LT_ROOT": r.root, "LT_DIGEST": base + ".digest.md", "LT_EXE": exe]
        }
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
        for (k, v) in digestEnv { env[k] = v }
        p.environment = env
        let logs = (appRoot as NSString).appendingPathComponent("logs")
        try? FileManager.default.createDirectory(atPath: logs, withIntermediateDirectories: true)
        let logPath = (logs as NSString).appendingPathComponent("prep-claude.log")
        let log = FileHandle.forAppending(path: logPath)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logPath)
        log?.write(("\n==== \(Date()) \(r.title) -> \(base)\n").data(using: .utf8)!)
        let out = Pipe()
        p.standardOutput = out
        p.standardError = log
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { return }
            Self.logSafe(d, to: log)
            Task { @MainActor in self?.consume(d, skill: skill, base: base) }
        }
        let checkPy = c.engine.python
        p.terminationHandler = { [weak self] proc in
            // the app's own check (the skill's prep-check); --fix derives the cards from the facts when they are missing
            var checkLine = ""
            if !isLocal, FileManager.default.fileExists(atPath: base + ".brief.md") {
                let chk = Process(); let o = Pipe()
                chk.executableURL = URL(fileURLWithPath: checkPy); chk.arguments = [lt, "prep-check", base + ".md", "--fix"]
                chk.standardOutput = o; chk.standardError = FileHandle.nullDevice
                if (try? chk.run()) != nil {
                    chk.waitUntilExit()
                    let text = String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    checkLine = text.range(of: "\"verdict\"[^,}]*", options: .regularExpression).map { String(text[$0]) } ?? ""
                }
            }
            let ok = proc.terminationStatus == 0 && FileManager.default.fileExists(atPath: base + ".brief.md")
                && FileManager.default.fileExists(atPath: base + ".facts.json")
            Task { @MainActor in
                guard let self = self, self.process === proc else { return }
                (proc.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
                let forID = self.callID
                // 0.8.2: the way that is out is marked for everyone; with auto-switch the same preparation runs once
                // more on the other way (the next preparation tries the chosen way first again).
                let logText = (try? String(contentsOfFile: (logs as NSString).appendingPathComponent("prep-claude.log"), encoding: .utf8))
                    .map { String(($0.components(separatedBy: "\n==== ").last ?? "").suffix(1500)) } ?? ""   // this run only
                // rules/ai.yaml > fallback: both Claude ways are out (or the other one cannot run) -> the model on this Mac
                let claudeOut = !ok && !isLocal && AIRoute.outReason(route, logText) != nil
                if claudeOut, routes.localFallback, (self.switchedOnce || !usable(AIRoute.other(route)) || !routes.autoSwitch), !self.localTried {
                    AIRoute.markDown(route, AIRoute.outReason(route, logText) ?? "out")
                    self.localTried = true
                    self.running = false
                    self.process = nil
                    if self.start(r, route: AIRoute.local) == nil {
                        self.detail = L("prep.switched", ["route": AIRoute.name(AIRoute.local)])
                        return
                    }
                }
                if ok { AIRoute.markUp(route) } else if let why = AIRoute.outReason(route, logText) {
                    AIRoute.markDown(route, why)
                    let alt = AIRoute.other(route)
                    if routes.autoSwitch && !self.switchedOnce && usable(alt) {
                        self.switchedOnce = true
                        self.running = false
                        self.process = nil
                        if self.start(r, route: alt) == nil {
                            self.detail = L("prep.switched", ["route": AIRoute.name(alt)])
                            return
                        }
                    }
                }
                if useAPI, let c = self.costUSD { SpendDays.add(c) }     // Home's week (2026-10-27)
                let routeName = useAPI ? "api" : isLocal ? "local" : "plan"
                var meta = self.resultMeta
                meta["model"] = runModel
                if !checkLine.isEmpty { meta["check"] = checkLine }
                Self.ledger(job: r.refreshOf == nil ? "prep" : "prep_refresh", route: routeName, usd: self.costUSD, meta: meta, ok: ok)
                if r.refreshBase == nil {
                    var run = meta
                    run["route"] = routeName; run["ok"] = ok; run["title"] = r.title
                    run["started"] = ISO8601DateFormatter().string(from: self.startedAt ?? Date())
                    run["duration_s"] = run["duration_s"] ?? Int(Date().timeIntervalSince(self.startedAt ?? Date()))
                    if let c = self.costUSD { run["cost_usd"] = (c * 10000).rounded() / 10000 }
                    Self.keepRun(base: base, aside: aside, ok: ok, meta: run)
                }
                if ok {
                    var extra = self.resultMeta
                    extra["route"] = routeName
                    extra["model"] = runModel
                    if let c = self.costUSD { extra["cost_usd"] = (c * 10000).rounded() / 10000 }
                    Freshness.writeSnapshot(base: base, refreshOf: r.refreshOf, extra: extra)      // rules/freshness.json > snapshot
                    if let res = TalkFiles.after(base: base, deck: r.deck, oldTexts: deckTexts) { self.lastTalk = res }
                    self.progress = 1; self.stage = L("prep.st.done")
                    // QA 26.10: the call may have started while the prep was written: pick up the rest now.
                    // 2026-10-27 (Up next): only into the call it was made for.
                    if Self.joinsLiveCall(prepFor: forID, liveCall: CallEngine.shared.currentCallID) || self.joinsCurrentCall,
                       CallEngine.shared.isRunning, let f = CallEngine.shared.lastFile { CallEngine.shared.adoptLatePrep(base: base, file: f) }
                }
                self.running = false
                self.process = nil
                UpNext.shared.prepFinished(id: forID, base: base, ok: ok)
                let mins = Int((Date().timeIntervalSince(self.startedAt ?? Date())) / 60)
                let tail = (try? String(contentsOfFile: (logs as NSString).appendingPathComponent("prep-claude.log"), encoding: .utf8))
                    .map { String($0.suffix(600)) } ?? ""
                if !ok && (tail.contains("authenticate") || tail.contains("OAuth") || tail.contains("log in") || tail.contains("/login")) {
                    self.result = L("prep.err.notSigned")
                    self.refreshAuth()
                } else if !ok && (tail.lowercased().contains("usage limit") || tail.lowercased().contains("rate limit")) {
                    self.result = L("prep.err.limit")
                } else {
                    let cost = isLocal ? L("prep.local") : self.costUSD.map { String(format: " · $%.2f", $0) + (useAPI ? "" : L("prep.plan")) } ?? ""
                    self.result = ok ? L("prep.readyIn", ["min": "\(max(1, mins))"]) + cost : L("prep.failedExit", ["code": "\(proc.terminationStatus)"])
                    if ok { UsageLog.log("prepare_run", ["type": isLocal ? "local" : (useAPI ? "api" : "code"), "source": "app", "seconds": mins * 60]) }
                }
            }
        }
        do { try p.run() } catch { return L("prep.err.cantStart", ["err": error.localizedDescription]) }
        process = p
        running = true
        runRoute = route
        startedAt = Date()
        target = (base as NSString).lastPathComponent
        callID = r.callID
        forTitle = r.title; forDate = r.date
        result = ""
        progress = 0.02; stage = L("prep.st.starting"); detail = ""; filesRead = 0; lineBuf = Data(); costUSD = nil; resultMeta = [:]
        return nil
    }

    /// The transcripts of the last 3 calls of the same meeting (same title) in the project's live folder, newest first.
    static func previousCallsBlock(live: String, title: String) -> String {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: live) else { return "" }
        let want = StartCallModel.slugify(title).replacingOccurrences(of: "-", with: "")
        var picked: [String] = []
        for n in names.sorted(by: >) where n.range(of: "^\\d{4}-\\d\\d-\\d\\d-\\d{4}-[^.]+(\\.app)?\\.md$", options: .regularExpression) != nil {
            let core = String(n.dropFirst(16)).replacingOccurrences(of: ".app.md", with: "").replacingOccurrences(of: ".md", with: "").replacingOccurrences(of: "-", with: "")
            guard !want.isEmpty, core == want || (min(core.count, want.count) >= 4 && (core.contains(want) || want.contains(core))) else { continue }
            let stem = String(n.prefix(16 + max(0, n.count - 16 - (n.hasSuffix(".app.md") ? 7 : 3))))
            if picked.contains(where: { ($0 as NSString).lastPathComponent.hasPrefix(stem) }) { continue }   // app and skill copies of one call
            let named = (live as NSString).appendingPathComponent(String(n.dropLast(3)) + ".named.md")
            picked.append(fm.fileExists(atPath: named) ? named : (live as NSString).appendingPathComponent(n))
            if picked.count == 3 { break }
        }
        guard !picked.isEmpty else { return "Previous calls of this meeting: none found by title in \(live); use the Meetings rows of the Notion copy and the digest." }
        // rules/notes.yaml > preparation: the newest call in full, the older ones from their full notes when they exist
        let list = picked.enumerated().map { (i, path) -> String in
            guard i > 0 else { return path }
            var stem = path.hasSuffix(".named.md") ? String(path.dropLast(9)) : String(path.dropLast(3))
            if stem.hasSuffix(".named") { stem = String(stem.dropLast(6)) }
            let notes = stem + ".notes.md"
            return fm.fileExists(atPath: notes) ? notes + " (its full notes, they keep every detail)" : path
        }
        return "Previous calls of this meeting (read each fully, newest first; the newest is its transcript): " + list.joined(separator: "; ")
    }

    /// Hosts of the http(s) links the PM wrote in the call context, plus docs.google.com for Google Docs exports.
    nonisolated static func webHosts(in text: String) -> [String] {
        var hosts: Set<String> = []
        let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        det?.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { m, _, _ in
            if let u = m?.url, let sc = u.scheme?.lowercased(), sc == "https" || sc == "http", let h = u.host?.lowercased(),
               h.range(of: "^[a-z0-9.-]+$", options: .regularExpression) != nil { hosts.insert(h) }
        }
        if hosts.contains(where: { $0.hasSuffix("google.com") }) { hosts.insert("docs.google.com") }
        return hosts.sorted()
    }

    /// The log keeps what explains a failure (system, result and error lines), never tool results with file contents.
    nonisolated static func logSafe(_ d: Data, to log: FileHandle?) {
        guard let log = log, let s = String(data: d, encoding: .utf8) else { return }
        for ln in s.split(separator: "\n") where ln.contains("\"type\":\"result\"") || ln.contains("\"type\":\"system\"") || ln.contains("\"error\"") {
            log.write((String(ln.prefix(4000)) + "\n").data(using: .utf8)!)
        }
    }

    /// Reads Claude Code's stream-json events and turns tool calls into stages (no guessing from time).
    private func consume(_ data: Data, skill: String, base: String) {
        lineBuf.append(data)
        while let r = lineBuf.range(of: Data([0x0A])) {
            let ln = lineBuf.subdata(in: lineBuf.startIndex..<r.lowerBound)
            lineBuf.removeSubrange(lineBuf.startIndex..<r.upperBound)
            guard let o = try? JSONSerialization.jsonObject(with: ln) as? [String: Any] else { continue }
            if (o["type"] as? String) == "system", progress < 0.05 { set(0.05, L("prep.st.instructions"), "") }
            if let st = o["stage"] as? String {      // livetips_m0.localprep
                switch st {
                case "pack": set(0.1, L("prep.st.local.pack"), "")
                case "model": set(0.25, L("prep.st.local.model"), "")
                case "writing": set(min(0.9, 0.3 + Double((o["pieces"] as? Int) ?? 0) / 6000), L("prep.st.local.writing"), "")
                default: set(0.92, L("prep.st.local.check"), "")
                }
            }
            if o["ok"] != nil, o["tokens"] != nil {
                costUSD = 0
                var m: [String: Any] = ["tokens": o["tokens"] ?? [:]]
                if let d = o["duration_s"] { m["duration_s"] = d }
                if let s = o["sources"] { m["sources"] = s }
                if let e = o["error"] as? String { m["error"] = e }
                resultMeta = m
            }
            if (o["type"] as? String) == "result" {
                costUSD = (o["total_cost_usd"] as? Double) ?? (o["total_cost_usd"] as? NSNumber)?.doubleValue
                // 0.8.5 (owner): what a preparation costs, kept in <base>.prep.json (rules/freshness.json > snapshot)
                var m: [String: Any] = [:]
                if let d = (o["duration_ms"] as? NSNumber)?.doubleValue { m["duration_s"] = Int(d / 1000) }
                if let t = o["num_turns"] as? Int { m["turns"] = t }
                if let u = o["usage"] as? [String: Any] {
                    let n = { (k: String) in (u[k] as? NSNumber)?.intValue ?? 0 }
                    m["tokens"] = ["input": n("input_tokens"), "output": n("output_tokens"), "cache_read": n("cache_read_input_tokens"),
                                   "cache_write": n("cache_creation_input_tokens")]
                }
                resultMeta = m
            }
            guard (o["type"] as? String) == "assistant", let msg = o["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]] else { continue }
            for c in content where (c["type"] as? String) == "tool_use" {
                let name = c["name"] as? String ?? ""
                let input = c["input"] as? [String: Any] ?? [:]
                let path = (input["file_path"] as? String) ?? (input["path"] as? String) ?? ""
                let file = (path as NSString).lastPathComponent
                switch name {
                case "Write", "Edit":
                    if path.hasSuffix(".brief.md") { set(0.70, L("prep.st.brief"), file) }
                    else if path.hasSuffix(".cards.json") { set(0.80, L("prep.st.cards"), file) }
                    else if path.hasSuffix(".facts.json") { set(0.87, L("prep.st.facts"), file) }
                    else if path.hasSuffix(".outline.json") { set(0.90, L("prep.st.outline"), file) }
                    else { set(max(progress, 0.65), L("prep.st.writing"), file) }
                case "Bash":
                    let cmd = input["command"] as? String ?? ""
                    if cmd.contains("prep-check") { set(max(progress, 0.93), L("prep.st.check"), "lt prep-check") }
                    else if cmd.contains("digest") { set(max(progress, 0.2), L("prep.st.recent"), "lt digest") }
                    else if cmd.contains("textutil") { filesRead += 1; sources(file.isEmpty ? "a document" : file) }
                    else { sources("") }
                case "Read":
                    if path.hasPrefix(skill) { set(max(progress, 0.08), L("prep.st.instructions"), file) }
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
        set(max(progress, p), L("prep.st.sources", ["n": "\(filesRead)"]), what)
    }

    private func set(_ p: Double, _ s: String, _ d: String) { progress = p; stage = s; detail = d }
}

/// 0.8.5 (owner: compare the preparations of one call by time, price and quality): control/prep-bench.json
/// {"title": "<part of the event title>", "runs": [{"route": "api|code|local", "model": "sonnet|opus|gemma4:26b"}],
///  "next": 0} runs every listed preparation for the next calendar event with that title, one after another, never
/// during a recorded call and with no automatic switch. Each run is kept in prep-runs (rules/ai.yaml > prep_runs);
/// the file gets each result line and "done". The PM's model choice comes back at the end.
@MainActor
enum PrepBench {
    static var localReady = false
    static var path: String {
        let c = AppConfig.load(from: AppPaths.config)
        return ((c.effectiveAppRoot(appSupport: AppPaths.support.path) as NSString).appendingPathComponent("control") as NSString)
            .appendingPathComponent("prep-bench.json")
    }

    static func tick() {
        guard let data = FileManager.default.contents(atPath: path),
              var d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              d["done"] as? Bool != true, let runs = d["runs"] as? [[String: String]] else { return }
        let runner = PrepRunner.shared
        if runner.running || CallEngine.shared.isRunning { return }
        var next = d["next"] as? Int ?? 0
        var results = d["results"] as? [String] ?? []
        if d["active"] as? Bool == true {
            results.append("\(runs[min(next, runs.count - 1)]["route"] ?? "") \(runs[min(next, runs.count - 1)]["model"] ?? ""): \(runner.result)")
            next += 1
            d["active"] = false
        }
        if d["saved_model"] == nil { d["saved_model"] = runner.model; d["saved_local"] = runner.localModel }
        func finish() {
            runner.model = d["saved_model"] as? String ?? runner.model
            runner.localModel = d["saved_local"] as? String ?? runner.localModel
            d["done"] = true
        }
        defer {
            d["next"] = next; d["results"] = results
            if let out = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted, .sortedKeys]) {
                try? out.write(to: URL(fileURLWithPath: path))
            }
        }
        guard next < runs.count else { finish(); return }
        let want = (d["title"] as? String ?? "").lowercased()
        guard !want.isEmpty, let ev = CalendarService.shared.upcoming().filter({ $0.title.lowercased().contains(want) && $0.start > Date() })
                .min(by: { $0.start < $1.start }) ?? CalendarService.shared.next(titleContains: want) else { results.append("no upcoming event with \"\(want)\""); finish(); return }
        let m = StartCallModel()
        m.applyEvent(ev)
        guard let r = m.prepRequest() else { results.append("no project for \(ev.title)"); finish(); return }
        let run = runs[next]
        if run["route"] == AIRoute.local {
            // the local model may still be downloading: wait for Ollama to have it
            let want = run["model"] ?? ""
            PrepRunner.ollamaModels { names in localReady = names?.contains { $0 == want || $0 == want + ":latest" } ?? false }
            guard localReady else { d["waiting"] = "ollama: " + want; return }
        }
        if run["route"] == AIRoute.local { runner.localModel = run["model"] ?? runner.localModel } else { runner.model = run["model"] ?? runner.model }
        runner.switchedOnce = true
        d["event"] = ev.title + " " + ISO8601DateFormatter().string(from: ev.start)
        if let err = runner.start(r, route: run["route"]) {
            results.append("\(run["route"] ?? "") \(run["model"] ?? ""): not started: \(err)")
            next += 1
        } else {
            runner.switchedOnce = true          // start() reset it for a forced route: no automatic switch in a comparison
            d["active"] = true
        }
    }
}

