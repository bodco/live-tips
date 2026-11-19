import Foundation

/// Theme pass (19.11): how long a preparation usually takes, for "Prepare brief · ~40 s" on Home.
/// Read from state/spend-ledger.jsonl (one line per preparation, PrepRunner.ledger): the median `duration_s` of the
/// last successful runs of the job "prep". No estimate (nil) with fewer than 2 such runs: Home then says "Prepare brief".
public enum PrepEstimate {
    public static func seconds(ledger text: String, last n: Int = 10) -> Int? {
        var ds: [Double] = []
        for line in text.split(separator: "\n") {
            guard let d = String(line).data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  (o["job"] as? String) == "prep", (o["error"] as? Bool) != true else { continue }
            let v = (o["duration_s"] as? NSNumber)?.doubleValue ?? 0
            if v > 0 { ds.append(v) }
        }
        let tail = Array(ds.suffix(n)).sorted()
        guard tail.count >= 2 else { return nil }
        let mid = tail.count / 2
        let med = tail.count % 2 == 1 ? tail[mid] : (tail[mid - 1] + tail[mid]) / 2
        return Int(med.rounded())
    }

    /// Under 90 s: seconds rounded to 10 (at least 10); otherwise whole minutes. (value, isMinutes)
    public static func rounded(_ s: Int) -> (Int, Bool) {
        if s < 90 { return (max(10, Int((Double(s) / 10).rounded()) * 10), false) }
        return (Int((Double(s) / 60).rounded()), true)
    }
}
