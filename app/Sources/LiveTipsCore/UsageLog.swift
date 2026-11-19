import Foundation

/// Pacenote 0.8.7 (M, rules/usage.yaml): a local log of which features are used. Only event names, time and small
/// parameters; never call text, names or ids. One JSONL file per month in <app root>/usage/, 12 months kept.
public protocol UsageSink {
    func write(_ line: [String: Any])
}

/// The only sink today. A server sink is a second implementation later; call sites do not change.
public struct LocalFileSink: UsageSink {
    public let dir: URL
    public init(dir: URL) { self.dir = dir }

    public func file(for date: Date) -> URL {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM"
        return dir.appendingPathComponent(f.string(from: date) + ".jsonl")
    }

    public func write(_ line: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(line), let d = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let u = file(for: Date())
        if !fm.fileExists(atPath: u.path) { fm.createFile(atPath: u.path, contents: nil); prune(now: Date()) }
        guard let h = try? FileHandle(forWritingTo: u) else { return }
        h.seekToEndOfFile(); h.write(d); h.write(Data([0x0A])); try? h.close()
    }

    /// Deletes monthly files older than `keep` months.
    public func prune(now: Date, keep: Int = 12) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path),
              let limit = Calendar(identifier: .gregorian).date(byAdding: .month, value: -keep, to: now) else { return }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM"
        let cut = f.string(from: limit)
        for n in names where n.hasSuffix(".jsonl") && n.count == 13 && String(n.prefix(7)) < cut {
            try? fm.removeItem(at: dir.appendingPathComponent(n))
        }
    }
}

public enum UsageLog {
    /// Events and their parameters (rules/usage.yaml > events). An unknown event or parameter is not written.
    public static let events: [String: [String]] = [
        "call_started": ["type", "sales", "has_brief"], "call_ended": ["minutes"], "prepare_run": ["type", "source", "seconds"],
        "prepare_again": [], "presentation_mode_on": [], "slide_sync": ["variant"], "rehearsal_started": [],
        "rehearsal_finished": ["score"], "transcribe_run": ["source", "minutes"], "search_calls": [], "followup_written": [],
        "followup_copied": [], "followup_open_mail": [], "notion_page_written": [], "notion_task_ticked": [], "risk_added": [],
        "decision_added": [], "decision_superseded": [], "auto_added": ["kind", "n"],
        "series_opened": [], "call_page_edited": ["section"], "tip_shown": ["kind"], "tip_action": ["kind", "action"],
        "help_now": [], "ask_typed": [], "hotkey": ["name"], "update_crm": ["fields"], "answer_card_saved": [],
        "feature_try_it": ["feature"], "demo_opened": ["kind"], "onboarding_step": ["step", "skipped"], "notion_local_copy": ["choice"],
        "google_connect": [], "google_links_read": ["n"], "google_export": [], "google_meet": ["transcript"],
        "tip_rated": ["kind", "verdict", "reason"], "speakers_merged": ["aliases"], "meet_participants": ["n", "named"],
        "telemetry_sent": ["lines", "to"],
        "entitlements_refresh": ["ok", "why"],
        "module_locked": ["module", "state"], "plan_request_opened": ["from"],
        "plans_opened": ["from"], "console_platform": ["google"], "plan_chosen": ["plan", "from"], "org_team_started": ["plan"],
        // 0.10.1 (A6 audit): events the app already logged but this list did not have, so they were never written
        "rec_started": ["kind", "source"], "rec_paused": [], "rec_saved": ["kind", "minutes"], "rec_uploaded": ["minutes", "auto"],
        "call_reassign": ["when", "files"], "call_reassign_notion": ["kind"], "meeting_end": ["action"], "google_picker_copy": [],
        "calendar_refresh": ["from", "new"],   // 2026-11-17 (owner): Refresh calendars by hand
        // 2026-11-17 (S1 finding, spec 13): logged by the app since 0.15-0.18 but missing here, so they were never written
        "addons_chosen": ["n", "where"], "component_removed": ["id", "freed_mb"], "provider_limit_alert": ["provider"],
        "provider_limit_capped": ["provider"], "project_wizard": ["org", "folder", "card", "links"],
        "project_removed": ["sample", "trash"], "transcript_drive": ["shared_drive"], "whatsnew_shown": ["from", "to"],
        "whatsnew_closed": ["seen"], "practice_call": ["from"], "sync_pull": ["items"], "org_card_saved": ["fields"],
        "org_register_changed": ["kind"], "org_register_deleted": ["kind"], "org_state_saved": ["bytes"],
        "org_index_built": ["files", "skipped", "vectors"], "org_change_restored": ["entity"],
        "org_setup_invites": ["n"], "org_setup_done": ["org_teams"],
    ]
    public static var sink: UsageSink?
    public static var enabled = true

    /// The line to write, or nil when the event is unknown, a parameter is not allowed or a string is over 80 characters.
    public static func line(_ event: String, _ params: [String: Any] = [:], at: Date = Date()) -> [String: Any]? {
        guard let allowed = events[event] else { return nil }
        var p: [String: Any] = [:]
        for (k, v) in params {
            guard allowed.contains(k) else { return nil }
            switch v {
            case let s as String: guard s.count <= 80 else { return nil }; p[k] = s
            case let b as Bool: p[k] = b
            case let i as Int: p[k] = i
            case let d as Double: p[k] = (d * 10).rounded() / 10
            default: return nil
            }
        }
        return ["t": ISO8601DateFormatter().string(from: at), "e": event, "p": p]
    }

    /// 0.19.0 (S4): every logged event also goes to product analytics v2 (AnalyticsTracker decides, with the
    /// organization's policy, whether it is kept). Called before the local switch: D45 may send for an organization.
    public static var onLog: ((String, [String: Any]) -> Void)?

    public static func log(_ event: String, _ params: [String: Any] = [:]) {
        onLog?(event, params)
        guard enabled, let s = sink, let l = line(event, params) else { return }
        s.write(l)
    }

    /// How many times each event was logged (all kept months), for "Used N times".
    public static func counts(dir: URL) -> [String: Int] {
        var out: [String: Int] = [:]
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return out }
        for n in names where n.hasSuffix(".jsonl") {
            guard let t = try? String(contentsOf: dir.appendingPathComponent(n), encoding: .utf8) else { continue }
            for ln in t.split(separator: "\n") {
                if let o = try? JSONSerialization.jsonObject(with: Data(ln.utf8)) as? [String: Any], let e = o["e"] as? String { out[e, default: 0] += 1 }
            }
        }
        return out
    }
}
