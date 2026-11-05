import Foundation

/// 0.9.5 (owner, 2026-11-05): Call recording. The sound of the call, or the sound and the screen, saved on this Mac in
/// <project>/video/ next to nothing else, and on request copied to the PM's own Google Drive (drive.file) for sharing.
/// Off by default; a choice per call, an automatic default in Settings > Call recording. Nothing here is ever sent to an AI.
public struct RecordingSettings: Codable, Equatable {
    /// true: every call starts recording by itself (the kind below). false: only when chosen in Start call or in the call.
    public var auto = false
    /// "audio" (the call's sound: the other side and your microphone) or "video" (the sound and the screen).
    public var kind = "video"
    /// A quality preset id (RecordingPreset.all).
    public var quality = "light"          // 0.9.5 (owner): Light by default, faces and a call window stay clear
    /// "hevc" (smaller; Mac, iPhone and Google Drive play it, checked 2026-11-05) or "h264" (also older Windows players).
    public var codec = "hevc"
    /// "display" (a whole screen) or "window" (one window, the call app's).
    public var source = "display"
    /// The screen to record: "" the main screen, otherwise the display's UUID (stays the same across restarts).
    public var display = ""
    /// For source "window": "ask" (choose the window when the recording starts) or "auto" (the call app's window;
    /// the whole screen when no call window is found).
    public var windowPick = "ask"
    /// Your microphone in the recording (the other side always is).
    public var mic = true
    /// Google Drive: "manual" (Upload to Drive on the call page after the call) or "auto" (every recording, after the call).
    public var drive = "manual"
    /// The Google account whose Drive gets the recordings ("" the first account that allows the export).
    public var driveAccount = ""
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RecordingSettings()
        auto = (try? c.decodeIfPresent(Bool.self, forKey: .auto)) ?? d.auto
        kind = Self.pick((try? c.decodeIfPresent(String.self, forKey: .kind)) ?? nil, ["audio", "video"], d.kind)
        quality = Self.pick((try? c.decodeIfPresent(String.self, forKey: .quality)) ?? nil, RecordingPreset.all.map(\.id), d.quality)
        codec = Self.pick((try? c.decodeIfPresent(String.self, forKey: .codec)) ?? nil, ["h264", "hevc"], d.codec)
        source = Self.pick((try? c.decodeIfPresent(String.self, forKey: .source)) ?? nil, ["display", "window"], d.source)
        display = (try? c.decodeIfPresent(String.self, forKey: .display)) ?? nil ?? d.display
        windowPick = Self.pick((try? c.decodeIfPresent(String.self, forKey: .windowPick)) ?? nil, ["ask", "auto"], d.windowPick)
        mic = (try? c.decodeIfPresent(Bool.self, forKey: .mic)) ?? nil ?? d.mic
        drive = Self.pick((try? c.decodeIfPresent(String.self, forKey: .drive)) ?? nil, ["manual", "auto"], d.drive)
        driveAccount = (try? c.decodeIfPresent(String.self, forKey: .driveAccount)) ?? nil ?? d.driveAccount
    }

    static func pick(_ v: String?, _ allowed: [String], _ def: String) -> String { v.flatMap { allowed.contains($0) ? $0 : nil } ?? def }

    /// What a new call records: "off", "audio" or "video".
    public var defaultForCall: String { auto ? kind : "off" }
    public var preset: RecordingPreset { RecordingPreset.find(quality) }
}

/// A video quality. Meetings are mostly still (faces, a shared screen), so the frame rate is low and the picture is
/// scaled to a width that keeps shared text readable. Bitrates are averages: a still screen takes much less.
public struct RecordingPreset: Equatable {
    public let id: String
    public let maxWidth: Int
    public let fps: Int
    public let h264Kbps: Int
    public let hevcKbps: Int
    /// The sound: AAC mono, 48 kHz.
    public static let audioKbps = 64

    public static let all: [RecordingPreset] = [
        RecordingPreset(id: "light", maxWidth: 1280, fps: 10, h264Kbps: 600, hevcKbps: 380),
        RecordingPreset(id: "standard", maxWidth: 1920, fps: 12, h264Kbps: 1200, hevcKbps: 750),
        RecordingPreset(id: "sharp", maxWidth: 2560, fps: 15, h264Kbps: 2400, hevcKbps: 1500),
    ]
    public static func find(_ id: String) -> RecordingPreset { all.first { $0.id == id } ?? all[1] }

    public func videoKbps(_ codec: String) -> Int { codec == "hevc" ? hevcKbps : h264Kbps }

    /// The most an hour takes, in MB (video at its average bitrate plus the sound).
    public func mbPerHour(_ codec: String) -> Int { Self.mb(kbps: videoKbps(codec) + Self.audioKbps) }
    public static var audioMBPerHour: Int { mb(kbps: audioKbps) }
    static func mb(kbps: Int) -> Int { Int((Double(kbps) * 1000 / 8 * 3600 / 1_000_000).rounded()) }

    /// The output size for a source of w x h points at `scale`: the source's pixels, no wider than maxWidth, even numbers.
    public func outputSize(width w: Double, height h: Double, scale: Double) -> (Int, Int) {
        var pw = max(2, w * scale), ph = max(2, h * scale)
        if pw > Double(maxWidth) { ph = ph * Double(maxWidth) / pw; pw = Double(maxWidth) }
        let even: (Double) -> Int = { max(2, Int($0.rounded()) & ~1) }
        return (even(pw), even(ph))
    }
}

/// Where the recordings of a call live: <project>/video/<stem>.recording[-N].mp4 (or .m4a for sound only) and one
/// <stem>.recording.json with the parts and their Google Drive copies. <stem> is the transcript's name without
/// ".app" and ".md", so the call page finds the files by itself.
public enum RecordingFiles {
    public static func stem(transcript: String) -> String {
        var s = (transcript as NSString).lastPathComponent
        if s.hasSuffix(".md") { s = String(s.dropLast(3)) }
        if s.hasSuffix(".app") { s = String(s.dropLast(4)) }
        return s
    }
    /// <root>/live/x.md -> <root>/video
    public static func folder(transcript: String) -> String {
        let live = (transcript as NSString).deletingLastPathComponent
        return ((live as NSString).deletingLastPathComponent as NSString).appendingPathComponent("video")
    }
    public static func metaPath(transcript: String) -> String {
        (folder(transcript: transcript) as NSString).appendingPathComponent(stem(transcript: transcript) + ".recording.json")
    }
    /// The file of part `n` (1 is the first; parts start when the recording is stopped and started again in one call).
    public static func partPath(transcript: String, part n: Int, audioOnly: Bool) -> String {
        let name = stem(transcript: transcript) + ".recording" + (n > 1 ? "-\(n)" : "") + (audioOnly ? ".m4a" : ".mp4")
        return (folder(transcript: transcript) as NSString).appendingPathComponent(name)
    }
}

/// <stem>.recording.json
public struct RecordingMeta: Codable, Equatable {
    public struct Part: Codable, Equatable {
        public var file: String            // the file name inside video/
        public var kind: String            // "audio" | "video"
        public var source: String = ""     // "display:<name>" | "window:<app> - <title>" | "" for sound only
        public var started: Date
        public var seconds: Double = 0
        public var bytes: Int64 = 0
        public var driveID: String = ""
        public var driveLink: String = ""
        public var driveAccount: String = ""
        public var driveError: String = ""
        public init(file: String, kind: String, source: String = "", started: Date) {
            self.file = file; self.kind = kind; self.source = source; self.started = started
        }
    }
    public var schema = 1
    public var title = ""
    public var project = ""
    public var parts: [Part] = []
    public init() {}

    public static func load(_ path: String) -> RecordingMeta? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(RecordingMeta.self, from: d)
    }
    public func save(_ path: String) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let d = try? enc.encode(self) { try? d.write(to: URL(fileURLWithPath: path), options: .atomic) }
    }
    /// Parts that are finished and have no Drive copy yet.
    public var notUploaded: [Part] { parts.filter { $0.driveID.isEmpty && $0.seconds > 0 } }
    public var totalSeconds: Double { parts.reduce(0) { $0 + $1.seconds } }
    public var totalBytes: Int64 { parts.reduce(0) { $0 + $1.bytes } }
}

/// Which window is the call. Ranks the on-screen windows of meeting apps and of browsers with a meeting tab.
public enum MeetingWindow {
    public struct Candidate: Equatable {
        public var id: UInt32; public var bundle: String; public var app: String; public var title: String
        public var width: Double; public var height: Double
        public init(id: UInt32, bundle: String, app: String, title: String, width: Double, height: Double) {
            self.id = id; self.bundle = bundle; self.app = app; self.title = title; self.width = width; self.height = height
        }
    }
    static let apps: [String: Int] = ["us.zoom.xos": 3, "com.microsoft.teams2": 3, "com.microsoft.teams": 3,
                                      "com.cisco.webexmeetingsapp": 3, "Cisco-Systems.Spark": 3, "com.apple.FaceTime": 2,
                                      "com.hnc.Discord": 1, "com.tinyspeck.slackmacgap": 1]
    static let browsers: Set<String> = ["com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "com.microsoft.edgemac",
                                        "org.mozilla.firefox", "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
                                        "com.google.Chrome.beta", "company.thebrowser.dia"]
    static let tabWords = ["meet", "zoom", "teams", "webex", "whereby", "jitsi", "huddle", "around"]

    /// 0 when the window is not a call; higher is more likely the call.
    public static func score(_ c: Candidate) -> Int {
        guard c.width >= 320, c.height >= 200 else { return 0 }
        let t = c.title.lowercased()
        if let s = apps[c.bundle] {
            if c.bundle == "com.tinyspeck.slackmacgap" { return t.contains("huddle") ? 2 : 0 }
            if c.bundle == "us.zoom.xos" { return t.contains("meeting") || t.contains("zoom") ? 4 : 1 }   // the meeting, not the home window
            return s
        }
        if browsers.contains(c.bundle), tabWords.contains(where: { w in t.range(of: "\\b" + w + "\\b", options: .regularExpression) != nil }) { return 3 }
        return 0
    }

    /// The best call window: the highest score, then the largest.
    public static func best(_ list: [Candidate]) -> Candidate? {
        list.filter { score($0) > 0 }.max { a, b in
            let sa = score(a), sb = score(b)
            return sa != sb ? sa < sb : a.width * a.height < b.width * b.height
        }
    }
}
