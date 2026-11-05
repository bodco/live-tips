import AppKit
import LiveTipsCore

/// 0.9.4 (owner, rules/usage.yaml > telemetry): sends the weekly batch when Help improve Pacenote is on.
/// Checked at launch and every 6 hours; a failed send is tried again at the next check. Nothing else is sent.
@MainActor enum TelemetrySender {
    private static var timer: Timer?

    static var statePath: String {
        let c = AppConfig.load(from: AppPaths.config)
        return ((c.effectiveAppRoot(appSupport: AppPaths.support.path) as NSString).appendingPathComponent("state") as NSString)
            .appendingPathComponent("telemetry.json")
    }
    static func load() -> Telemetry.State {
        FileManager.default.contents(atPath: statePath).flatMap { try? JSONDecoder().decode(Telemetry.State.self, from: $0) } ?? .init()
    }
    static func save(_ s: Telemetry.State) {
        try? FileManager.default.createDirectory(atPath: (statePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(s) { try? d.write(to: URL(fileURLWithPath: statePath), options: .atomic) }
    }

    static func start() {
        tick()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
    }

    /// The switch in Settings: turning it on starts from today (nothing older is ever sent) and makes the install id; off forgets both.
    static func setOn(_ on: Bool) {
        var s = load()
        if on { if s.since.isEmpty { s.since = Telemetry.day(Date()) } } else { s = .init() }
        save(s)
    }

    static func batch(from: String, to: String, state: Telemetry.State) -> [String: Any] {
        let c = AppConfig.load(from: AppPaths.config)
        let ctx = EditLog.context()
        return Telemetry.batch(usageDir: FeatureRegistry.usageDir, from: from, to: to, install: state.install,
                               appVersion: ctx["app_version"] as? String ?? "dev", rulesVersion: ctx["rules_version"] as? String ?? "",
                               uiLang: String(c.uiLanguage.prefix(8)), routes: ctx["route"] as? [String: String] ?? [:])
    }

    /// Writes the batch that would go next (or the last 7 days when nothing is due) and shows it in Finder.
    static func preview() {
        let s = Telemetry.ensured(load(), now: Date())
        let to = Telemetry.day(Date().addingTimeInterval(-86400))
        let w = Telemetry.due(s, now: Date().addingTimeInterval(Double(Telemetry.everyDays) * 86400)) ?? (Telemetry.day(Date().addingTimeInterval(-7 * 86400)), to)
        let b = batch(from: w.from, to: w.to, state: s)
        let url = FeatureRegistry.usageDir.appendingPathComponent("next-batch.json")
        try? FileManager.default.createDirectory(at: FeatureRegistry.usageDir, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: b, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: url, options: .atomic) }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func tick() {
        let c = AppConfig.load(from: AppPaths.config)
        guard c.shareUsage, c.usageLog else { return }
        var s = Telemetry.ensured(load(), now: Date())
        if s.since.isEmpty { s.since = Telemetry.day(Date()) }
        save(s)
        guard let w = Telemetry.due(s, now: Date()), let url = URL(string: Telemetry.endpoint) else { return }
        let b = batch(from: w.from, to: w.to, state: s)
        let n = (b["events"] as? [Any])?.count ?? 0
        guard let body = try? JSONSerialization.data(withJSONObject: b) else { return }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"; req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Pacenote", forHTTPHeaderField: "User-Agent")
        Task { @MainActor in
            guard let (_, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
            var s2 = load()
            s2.sentUntil = w.to; s2.sentAt = ISO8601DateFormatter().string(from: Date())
            save(s2)
            UsageLog.log("telemetry_sent", ["lines": n])
        }
    }
}
