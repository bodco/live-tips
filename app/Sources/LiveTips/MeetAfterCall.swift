import Foundation
import LiveTipsCore

/// Pacenote 0.9.4 (owner, rules/voices.yaml > meet): after End call the Google Meet record is read by itself
/// (it was a click on the call page): the participants and, when Meet's transcript was on, who spoke when.
/// Meet writes the record a few minutes after the call, so it is asked again after 1.5, 4, 10 and 20 minutes.
/// The voices of this Mac's transcript get the Meet names (MeetSpeakers.match), marked named_by "meet": the voice
/// library does not learn from them (it learns during a call, from names the PM gives). Nothing is sent anywhere.
@MainActor enum MeetAfterCall {
    static let waits: [UInt64] = [90, 150, 360, 600]      // seconds between the tries: 1.5, 4, 10 and 20 min after the end

    static func schedule(stem: String, event: CalendarService.CalEvent?) {
        guard let e = event, GoogleService.shared.accounts.contains(where: { $0.has(GoogleScopes.meet) }) else { return }
        let code = e.link.flatMap(GoogleEvent.meetCode)
        guard code != nil || (e.link ?? "").contains("meet.google.com") else { return }      // a Zoom or Teams call has no Meet record
        let end = max(e.end, Date())
        Task { @MainActor in
            var applied = false
            for (i, w) in waits.enumerated() {
                try? await Task.sleep(nanoseconds: w * 1_000_000_000)
                guard let m = try? await GoogleService.shared.meet(code: code, start: e.start, end: end), !m.participants.isEmpty else { continue }
                let n = apply(stem: stem, meet: m)
                if !applied { UsageLog.log("meet_participants", ["n": m.participants.count, "named": n]) }
                applied = true
                if !m.spoken.isEmpty || i == waits.count - 1 { return }   // the transcript may come later than the participants
            }
        }
    }

    /// Writes <stem>.meet.md and names the voices in <stem>.speakers.json. Returns how many voices were named.
    @discardableResult static func apply(stem: String, meet m: GoogleService.MeetResult, title: String = "") -> Int {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"
        var md = "# Google Meet" + (title.isEmpty ? "" : ": " + title) + "\n\n" + f.string(from: m.started) + " · " + m.account + "\n\n## " + L("meet.participants") + "\n\n"
        md += m.participants.map { "- " + $0 }.joined(separator: "\n") + "\n"
        md += "\n## " + L("meet.transcript") + "\n\n" + (m.transcript.isEmpty ? L("meet.noTranscript") : m.transcript) + "\n"
        try? md.write(toFile: stem + ".meet.md", atomically: true, encoding: .utf8)

        let spPath = stem + ".speakers.json"
        guard let d = FileManager.default.contents(atPath: spPath), var o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              var clusters = o["clusters"] as? [String: Any],
              let text = try? String(contentsOfFile: stem + ".md", encoding: .utf8) else { return 0 }
        let lib: [String: Any] = {
            let p = (CallEngine.shared.appRoot as NSString).appendingPathComponent("voices/voices.json")
            return FileManager.default.contents(atPath: p).flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
        }()
        var named: [String: String] = [:]
        for (sid, v) in clusters { if let n = (v as? [String: Any])?["name"] as? String, !n.isEmpty { named[sid] = n } }
        let me = AppConfig.load(from: AppPaths.config).nameAliases
        let got = MeetSpeakers.match(lines: MeetSpeakers.lines(text), spoken: m.spoken, participants: m.participants, named: named,
                                     merged: (o["merged"] as? [String: String]) ?? [:], me: me, resolve: { VoiceBook.resolve(lib, $0) })
        // every unnamed voice offers the participants first (one click in the window or on the call page)
        let offer = m.participants.map { VoiceBook.resolve(lib, $0) }.filter { n in !me.contains { MeetSpeakers.normal($0) == MeetSpeakers.normal(n) } }
        for (sid, v) in clusters {
            guard var c = v as? [String: Any] else { continue }
            if let n = got[sid] { c["name"] = n; c["named_by"] = "meet" }
            else if ((c["name"] as? String) ?? "").isEmpty {
                let old = ((c["suggestions"] as? [[String: Any]]) ?? []).filter { x in !offer.contains { $0 == (x["name"] as? String) } }
                c["suggestions"] = Array((offer.map { ["name": $0, "source": "meet"] as [String: Any] } + old).prefix(4))
            }
            clusters[sid] = c
        }
        o["clusters"] = clusters
        o["meet"] = ["participants": m.participants, "named": got.count, "transcript": !m.spoken.isEmpty]
        o["rev"] = ((o["rev"] as? Int) ?? 0) + 1
        if let out = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) { try? out.write(to: URL(fileURLWithPath: spPath), options: .atomic) }
        return got.count
    }
}
