import Foundation

/// 0.24.1 (F7, Bohdan 18.11): local logs that a support look can read. Every line has the date and time zone, files
/// are appended (never rewritten per run) and rotated by size, a run starts with a header (versions, macOS, call id).
/// Never call text, keys or file contents; home folders are written as "~".
public enum LogFile {
    public static let maxBytes: Int64 = 2_000_000
    public static let keep = 5

    /// "2026-11-18 19:42:07 +0200 message"
    public static func stamp(_ d: Date = Date(), zone: TimeZone = .current) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = zone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f.string(from: d)
    }

    public static func line(_ message: String, at d: Date = Date(), zone: TimeZone = .current, home: String = NSHomeDirectory()) -> String {
        stamp(d, zone: zone) + " " + redact(message, home: home)
    }

    /// The home folder as "~" and anything that looks like a key or token cut out.
    public static func redact(_ s: String, home: String = NSHomeDirectory()) -> String {
        var t = home.count > 1 ? s.replacingOccurrences(of: home, with: "~") : s
        t = t.replacingOccurrences(of: #"(sk-ant-[A-Za-z0-9_-]{8})[A-Za-z0-9_-]+|(sk-[A-Za-z0-9_-]{6})[A-Za-z0-9_-]{14,}|(ntn_[A-Za-z0-9]{4})[A-Za-z0-9]{16,}|(secret_[A-Za-z0-9]{4})[A-Za-z0-9]{16,}|(AIza[0-9A-Za-z_-]{4})[0-9A-Za-z_-]{26,}"#,
                                  with: "$1$2$3$4$5…", options: .regularExpression)
        return t
    }

    /// The header of one run: "=== <what> | 2026-11-18 19:42:07 +0200 | Pacenote 0.24.1 (241) | macOS 15.4 | k=v ...".
    public static func header(_ what: String, app: String, build: String, os: String, extra: [(String, String)] = [], at d: Date = Date(), zone: TimeZone = .current) -> String {
        (["=== " + what, stamp(d, zone: zone), "Pacenote \(app) (\(build))", "macOS \(os)"] + extra.filter { !$0.1.isEmpty }.map { "\($0.0)=\($0.1)" })
            .joined(separator: " | ")
    }

    /// The rotation names: log, log.1 ... log.<keep>.
    public static func rotated(_ path: String, _ i: Int) -> String { i == 0 ? path : path + ".\(i)" }

    /// Appends one line (adds the newline) and rotates first when the file is over `maxBytes`.
    public static func append(_ text: String, to path: String, maxBytes: Int64 = maxBytes, keep: Int = keep) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int64, size > maxBytes { rotate(path, keep: keep) }
        if !fm.fileExists(atPath: path) { fm.createFile(atPath: path, contents: nil) }
        guard let h = FileHandle(forWritingAtPath: path) else { return }
        _ = try? h.seekToEnd()
        h.write(Data((text.hasSuffix("\n") ? text : text + "\n").utf8))
        try? h.close()
    }

    /// log.<keep> goes, every other moves one up, the live file becomes log.1.
    public static func rotate(_ path: String, keep: Int = keep) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: rotated(path, keep))
        for i in stride(from: keep - 1, through: 0, by: -1) where fm.fileExists(atPath: rotated(path, i)) {
            try? fm.moveItem(atPath: rotated(path, i), toPath: rotated(path, i + 1))
        }
    }
}
