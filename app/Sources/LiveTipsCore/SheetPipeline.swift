import Foundation

/// 0.10.0 (Meeting Sheet, phase 3): the pure part of SheetRunner, checked by CoreChecks.
/// - which call types build a sheet (all but Transcript),
/// - the preset a Prepare without the wizard starts from (the series' own choice wins),
/// - the progress lines of the sidecar (`python -m livetips_m0.sheet build`): {"progress", "stage", "source_id"?,
///   "access"?, "pass"?, "passes"?, "file"?} and the last line {"done": true, ...} or {"error": ...}.
public enum SheetPipeline {
    public static func builds(callType: String) -> Bool { callType != "transcript" }

    public static func preset(callType: String, sales: Bool, title: String, earlier: Bool, seriesChoice: String? = nil) -> String {
        if let p = seriesChoice, !p.isEmpty { return p }
        let t = title.lowercased()
        if callType == "interview" { return "interview" }
        if callType == "presentation" { return "internal_presentation" }
        if t.contains("standup") || t.contains("stand-up") || t.contains("daily") || t.contains("стендап") { return "standup" }
        if sales { return earlier ? "repeat_call" : "sales_intro" }
        return "client_sync"
    }

    public struct Line: Equatable {
        public var progress: Double?
        public var stage: String = ""
        public var sourceID: String?
        public var access: String?
        public var pass: Int?
        public var passes: Int?
        public var file: String?
        public var done = false
        public var error: String?
        public var sheet: String?
        public var readiness: String?
    }

    /// One stdout line of the sidecar; nil for anything that is not a JSON object.
    public static func parse(_ line: String) -> Line? {
        guard let d = line.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        var l = Line()
        l.progress = (o["progress"] as? NSNumber)?.doubleValue
        l.stage = o["stage"] as? String ?? ""
        l.sourceID = o["source_id"] as? String
        l.access = o["access"] as? String
        l.pass = (o["pass"] as? NSNumber)?.intValue
        l.passes = (o["passes"] as? NSNumber)?.intValue
        l.file = o["file"] as? String
        l.done = (o["done"] as? Bool) == true
        l.error = o["error"] as? String
        l.sheet = o["sheet"] as? String
        l.readiness = o["readiness"] as? String
        return l
    }
}
