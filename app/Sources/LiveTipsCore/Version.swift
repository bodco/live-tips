import Foundation

/// Version numbers in release tags ("v0.8.1", "pacenote-0.8.1") and their order (Pacenote 0.8, Check for updates).
public enum AppVersion {
    /// The first dotted number in a tag or a version string.
    public static func number(in s: String) -> String? {
        s.range(of: "[0-9]+(\\.[0-9]+)+", options: .regularExpression).map { String(s[$0]) }
    }

    /// true when `a` is a later version than `b` (1.10 > 1.9, 0.8 == 0.8.0).
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let x = (number(in: a) ?? a).split(separator: ".").map { Int($0) ?? 0 }
        let y = (number(in: b) ?? b).split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}
