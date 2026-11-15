import Foundation

/// Pacenote 0.13.0 (B8 part 2, step 1): the consent record of a call. The app writes it to the call's tips file as
/// {"kind": "consent", "mode": ..., "at": ...} lines; nothing goes to the server in this step.
///
/// Modes of a line:
/// - said: macOS spoke the consent message (Settings > General > Recording consent > Say).
/// - posted: the message was copied for the meeting chat (owner 15.11: whoever copies it also pastes it; whoever does
///   not want to tell the others does not copy it).
/// - none: consent was off when the call started (or the message was empty).
/// A call with no consent line (made before 0.13.0) is unknown.
public enum CallConsent {
    public enum Mode: String, CaseIterable { case said, posted, none, unknown }

    public struct Event: Equatable {
        public let mode: Mode
        public let at: Date
        public let recorded: Bool
        public let source: String
        public init(mode: Mode, at: Date, recorded: Bool = false, source: String = "app") {
            self.mode = mode; self.at = at; self.recorded = recorded; self.source = source
        }
    }

    public struct State: Equatable {
        public var mode: Mode = .unknown
        /// When the resolved mode happened (nil for unknown).
        public var at: Date? = nil
        public var said: Date? = nil
        public var posted: Date? = nil
        public init() {}
    }

    // MARK: lines

    static func iso(_ d: Date) -> String { ISO8601DateFormatter().string(from: d) }

    static func date(_ s: String) -> Date? {
        if let d = ISO8601DateFormatter().date(from: s) { return d }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    /// One consent line. Only the mode, the time, whether the call was recorded and where it came from: never the
    /// message text and never a name.
    public static func line(mode: Mode, at: Date = Date(), recorded: Bool = false, source: String = "app") -> [String: Any] {
        ["kind": "consent", "mode": mode.rawValue, "at": iso(at), "recorded": recorded, "source": source]
    }

    /// The consent events in a tips file's text, in file order. Unknown modes and broken lines are skipped.
    public static func events(in text: String) -> [Event] {
        text.split(separator: "\n").compactMap { ln in
            guard ln.contains("consent"),
                  let o = (try? JSONSerialization.jsonObject(with: Data(ln.utf8))) as? [String: Any],
                  (o["kind"] as? String) == "consent",
                  let m = Mode(rawValue: (o["mode"] as? String) ?? ""), m != .unknown,
                  let at = date((o["at"] as? String) ?? "") else { return nil }
            return Event(mode: m, at: at, recorded: (o["recorded"] as? Bool) ?? false, source: (o["source"] as? String) ?? "app")
        }
    }

    /// One state from the events: the earliest said or posted wins; then none; unknown when there are no events.
    public static func resolve(_ events: [Event]) -> State {
        var s = State()
        func first(_ m: Mode) -> Date? { events.filter { $0.mode == m }.map(\.at).min() }
        s.said = first(.said); s.posted = first(.posted)
        let given = [(Mode.said, s.said), (Mode.posted, s.posted)].compactMap { m, d in d.map { (m, $0) } }.min { $0.1 < $1.1 }
        if let g = given { s.mode = g.0; s.at = g.1 }
        else if let n = first(.none) { s.mode = .none; s.at = n }
        return s
    }

    /// The consent state of a call from both of its tips files (the app's <file>.tips.jsonl and the skill's
    /// <stem>.tips.jsonl).
    public static func read(transcript file: String) -> State {
        resolve(CallLists.tipsPaths(transcript: file).flatMap { p in
            (try? String(contentsOfFile: p, encoding: .utf8)).map { events(in: $0) } ?? []
        })
    }

    // MARK: writing

    /// Appends one JSON line with O_APPEND in a single write, so a line from the tips engine (which appends to the
    /// same file during the call) is never overwritten.
    @discardableResult
    public static func append(path: String, _ o: [String: Any]) -> Bool {
        guard JSONSerialization.isValidJSONObject(o),
              var d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return false }
        d.append(0x0A)
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let n = d.withUnsafeBytes { write(fd, $0.baseAddress, d.count) }
        return n == d.count
    }

    @discardableResult
    public static func record(path: String, mode: Mode, at: Date = Date(), recorded: Bool = false, source: String = "app") -> Bool {
        guard mode != .unknown else { return false }
        return append(path: path, line(mode: mode, at: at, recorded: recorded, source: source))
    }
}
