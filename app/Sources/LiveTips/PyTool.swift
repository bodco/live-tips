import AppKit
import LiveTipsCore

/// Pacenote 0.8.6 (F6): one run of a tips-engine module outside a call (follow-up email, call memory, rehearsal,
/// risk register). The Claude key and the Notion token go to the child process only, never written or logged; the
/// module prints one JSON object.
@MainActor
enum PyTool {
    static func run(_ module: String, _ args: [String], notion: Bool = false, done: @escaping ([String: Any]) -> Void) {
        let c = AppConfig.load(from: AppPaths.config)
        guard !c.engine.sidecarPython.isEmpty, !c.engine.sidecarDir.isEmpty else {
            done(["ok": false, "error": L("py.noEngine")]); return
        }
        let store = SecretStore(service: Bundle.main.bundleIdentifier ?? "io.github.example.livetips")
        let key = store.get(.claudeAPIKey) ?? ""
        if key.isEmpty && !notion { done(["ok": false, "error": L("prep.err.noKey")]); return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: c.engine.sidecarPython)
        p.arguments = ["-m", "livetips_m0." + module] + args
        p.currentDirectoryURL = URL(fileURLWithPath: c.engine.sidecarDir)
        var env = ProcessInfo.processInfo.environment
        env["CLAUDE_API"] = key
        if let ws = store.get(.claudeWorkspaceID), !ws.isEmpty { env["CLAUDE_WORKSPACE"] = ws }
        if notion { env["NOTION_TOKEN"] = store.get(.notionToken) ?? "" }
        env["LT_LEDGER"] = SpendLedger.defaultPath
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        let appRoot = c.effectiveAppRoot(appSupport: AppPaths.support.path)
        p.standardError = FileHandle.forAppending(path: (appRoot as NSString).appendingPathComponent("logs/after-call.log"))
        p.terminationHandler = { _ in
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            let line = text.split(separator: "\n").last(where: { $0.hasPrefix("{") }).map(String.init) ?? ""
            let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
                ?? ["ok": false, "error": L("py.failed")]
            DispatchQueue.main.async { MainActor.assumeIsolated { done(obj) } }
        }
        do { try p.run() } catch { done(["ok": false, "error": error.localizedDescription]) }
    }

    /// The core settings the recorder uses (me_label: how the PM's lines are labelled in the transcripts).
    static var meLabel: String {
        let c = AppConfig.load(from: AppPaths.config)
        let root = c.effectiveAppRoot(appSupport: AppPaths.support.path)
        let core = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: (root as NSString).appendingPathComponent("config.json"))))) as? [String: Any]
        return (core?["me_label"] as? String) ?? "Me"
    }

    /// The registered project or workspace whose folder holds this transcript.
    static func project(of file: String) -> (project: Project?, workspace: Workspace?) {
        let reg = ProjectRegistry.load(from: AppPaths.projects)
        let dir = ((file as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        return (reg.projects.first { !$0.root.isEmpty && $0.root == dir }, reg.workspaces.first { $0.root == dir })
    }
}

/// One transcript line: "[10:00:24] Other [S2] (en): text".
struct TranscriptLine: Identifiable, Hashable {
    var id: Int
    var t: String
    var who: String
    var text: String
    var me: Bool

    static func read(_ file: String, me: String) -> [TranscriptLine] {
        guard let s = try? String(contentsOfFile: file, encoding: .utf8) else { return [] }
        let rx = try! NSRegularExpression(pattern: "^\\[(\\d\\d:\\d\\d:\\d\\d)\\]\\s+(.+?)(?:\\s+\\[(S\\d+)\\])?\\s+\\((\\w{2})\\):\\s?(.*)$")
        var out: [TranscriptLine] = []
        for ln in s.split(separator: "\n", omittingEmptySubsequences: true) {
            let l = String(ln)
            guard let m = rx.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) else { continue }
            func g(_ i: Int) -> String { Range(m.range(at: i), in: l).map { String(l[$0]) } ?? "" }
            let label = g(2).trimmingCharacters(in: .whitespaces)
            out.append(TranscriptLine(id: out.count, t: g(1), who: label + (g(3).isEmpty ? "" : " " + g(3)), text: g(5), me: label == me))
        }
        return out
    }
}
