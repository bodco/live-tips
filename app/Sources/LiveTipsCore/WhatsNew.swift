import Foundation

/// 0.16.0 (D3, rules/whatsnew.yaml): What's new, personal. After the first launch of a new version the app shows the
/// items newer than the last version this person saw, that apply to them (`when`) and, for a setup step, that they
/// have not done yet. Pure: the file is parsed here so CoreChecks reads the same rules the app ships.
public enum WhatsNew {
    public struct Item: Equatable, Sendable {
        public var id = ""
        public var version = ""
        public var titleEN = "", titleUK = ""
        public var bodyEN = "", bodyUK = ""
        /// A FeatureRegistry id: the item's "Try it".
        public var tryIt: String?
        /// An onboarding step this item lets the person finish ("addons"); shown only while it is not done.
        public var setupStep: String?
        /// Conditions, all must hold: "provider:claude", "module:tracker", "os:15"; empty = everyone.
        public var when: [String] = []
        public init() {}
        public func title(_ lang: String) -> String { lang == "uk" ? titleUK : titleEN }
        public func body(_ lang: String) -> String { lang == "uk" ? bodyUK : bodyEN }
    }

    /// The last version before What's new existed: a person with no saved version updated from it or earlier.
    public static let baseline = "0.15.0"
    public static let lastSeenKey = "whatsNewLastSeenVersion"

    /// Reads the subset of YAML whatsnew.yaml uses: `items:`, then `  - key: value` starting an item and
    /// `    key: value` inside it. Values are plain or double-quoted on one line; `#` starts a comment outside quotes.
    public static func parse(_ text: String) -> [Item] {
        var out: [Item] = [], cur: Item?, inItems = false
        func value(_ raw: Substring) -> String {
            var s = raw.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("\"") {
                var r = "", esc = false
                for ch in s.dropFirst() {
                    if esc { r.append(ch == "n" ? "\n" : ch); esc = false } else if ch == "\\" { esc = true } else if ch == "\"" { break } else { r.append(ch) }
                }
                return r
            }
            if let i = s.range(of: " #") { s = String(s[..<i.lowerBound]) }
            return s.trimmingCharacters(in: .whitespaces)
        }
        func set(_ k: String, _ v: String) {
            guard cur != nil else { return }
            switch k {
            case "id": cur!.id = v
            case "version": cur!.version = v
            case "title_en": cur!.titleEN = v
            case "title_uk": cur!.titleUK = v
            case "body_en": cur!.bodyEN = v
            case "body_uk": cur!.bodyUK = v
            case "try": cur!.tryIt = v.isEmpty ? nil : v
            case "setup_step": cur!.setupStep = v.isEmpty ? nil : v
            case "when": cur!.when = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != "always" }
            default: break
            }
        }
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            if !line.hasPrefix(" ") { inItems = t == "items:"; continue }
            guard inItems else { continue }
            var body = Substring(t)
            if body.hasPrefix("- ") {
                if let c = cur { out.append(c) }
                cur = Item(); body = body.dropFirst(2)
            }
            guard let colon = body.firstIndex(of: ":") else { continue }
            set(String(body[..<colon]).trimmingCharacters(in: .whitespaces), value(body[body.index(after: colon)...]))
        }
        if let c = cur { out.append(c) }
        return out
    }

    /// Whether every condition of an item holds for this person.
    public static func applies(_ item: Item, facts: Set<String>) -> Bool { item.when.allSatisfy(facts.contains) }

    /// The items to show after an update: newer than `lastSeen` (nil: the baseline), not newer than `current`,
    /// applying to this person, a setup step only while it is not done ("done:<step>" in facts). Newest first.
    public static func pending(_ items: [Item], lastSeen: String?, current: String, facts: Set<String>) -> [Item] {
        let seen = lastSeen ?? baseline
        return items.filter { i in
            AppVersion.isNewer(i.version, than: seen) && !AppVersion.isNewer(i.version, than: current)
                && applies(i, facts: facts) && !(i.setupStep.map { facts.contains("done:" + $0) } ?? false)
        }.sorted { AppVersion.isNewer($0.version, than: $1.version) }
    }

    /// Whether the window opens at launch: onboarding done (a new person sets lastSeen when it finishes), and
    /// something pending.
    public static func shouldShow(onboardingDone: Bool, pending: [Item]) -> Bool { onboardingDone && !pending.isEmpty }

    /// The full history for Help > What's new: every item, grouped by version, newest first.
    public static func history(_ items: [Item]) -> [(version: String, items: [Item])] {
        var order: [String] = [], by: [String: [Item]] = [:]
        for i in items { if by[i.version] == nil { order.append(i.version) }; by[i.version, default: []].append(i) }
        return order.sorted { AppVersion.isNewer($0, than: $1) }.map { ($0, by[$0] ?? []) }
    }

    /// "0.16.0" -> "0.16" for the badge.
    public static func short(_ v: String) -> String {
        let p = v.split(separator: ".")
        return p.count >= 3 && p[2] == "0" ? p.prefix(2).joined(separator: ".") : v
    }
}
