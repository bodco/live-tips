import AppKit
import LiveTipsCore

/// 0.24.1 (F7): the app's own journal, logs/app.log (Start and End call and from where, the readiness answer with its
/// reason, onboarding steps, AI switches, install results, permissions), and logs/setup.log (the full output of every
/// install step; before 0.24.1 it lived only in the Setup window's Details). Lines carry date and time zone; files
/// rotate by size (LiveTipsCore LogFile). Never call text, keys or file contents.
enum AppLog {
    static let queue = DispatchQueue(label: "pacenote.applog")
    static var root: String { AppConfig.load(from: AppPaths.config).effectiveAppRoot(appSupport: AppPaths.support.path) }
    static var logs: String { (root as NSString).appendingPathComponent("logs") }

    static var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
    static var build: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?" }
    static var macOS: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static func write(_ file: String, _ message: String) {
        let path = (logs as NSString).appendingPathComponent(file), line = LogFile.line(message)
        queue.async { LogFile.append(line, to: path) }
    }

    static func app(_ message: String) { write("app.log", message) }
    /// The call's id in the logs: the transcript's file name without the folder (never the folder: it names the project).
    static func stem(_ file: String?) -> String { file.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? "" }
    static func setup(_ message: String) { write("setup.log", message) }

    /// The header of one run in a log ("launch", "install", "call <stem>").
    static func header(_ file: String, _ what: String, extra: [(String, String)] = []) {
        let path = (logs as NSString).appendingPathComponent(file)
        let h = LogFile.header(what, app: appVersion, build: build, os: macOS, extra: extra)
        queue.sync { LogFile.append(h, to: path) }        // before the child process writes to the same file
    }

    /// Python and its key packages, Whisper model: for headers. Read from the files setup.sh leaves, never by running Python.
    static var runtimeExtra: [(String, String)] {
        let r = root, fm = FileManager.default
        let own = (r as NSString).appendingPathComponent("python/bin/python3")
        let cfg = ((r as NSString).appendingPathComponent(".venv/pyvenv.cfg"))
        let pyv = (try? String(contentsOfFile: cfg, encoding: .utf8))?.split(separator: "\n")
            .first { $0.hasPrefix("version") }.map { String($0.split(separator: "=").last ?? "").trimmingCharacters(in: .whitespaces) } ?? ""
        var pk: [String] = []
        let site = ((try? fm.contentsOfDirectory(atPath: (r as NSString).appendingPathComponent(".venv/lib"))) ?? []).first.map { (r as NSString).appendingPathComponent(".venv/lib/\($0)/site-packages") }
        if let s = site, let names = try? fm.contentsOfDirectory(atPath: s) {
            for p in ["mlx_whisper", "anthropic", "onnxruntime", "sherpa_onnx", "jsonschema"] {
                if let d = names.first(where: { $0.hasPrefix(p + "-") && $0.hasSuffix(".dist-info") }) {
                    pk.append(String(d.dropLast(".dist-info".count)))
                }
            }
        }
        return [("python", pyv + (fm.fileExists(atPath: own) ? " own" : "")), ("packages", pk.joined(separator: ",")),
                ("whisper", "large-v3-turbo"), ("tz", TimeZone.current.identifier)]
    }
}
