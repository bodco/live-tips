import Foundation

// 0.26.0 (block 1): the rules of the app's own notices, which replace system alerts. No window of their own, nothing modal:
// a line in the tips card or window during a call, a banner in an open Pacenote window, otherwise a dot on the
// menu bar icon and the notice waiting in the menu bar panel. macOS notifications are not used for these.

public enum NoticeLevel: String, Codable, CaseIterable, Sendable {
    case info, warning, error

    /// Info goes by itself once it was on screen; a warning or an error stays until the PM closes it.
    public var autoDismissSeconds: Double? { self == .info ? 8 : nil }
    /// The higher level wins on the menu bar dot.
    public var rank: Int { self == .error ? 2 : self == .warning ? 1 : 0 }
}

public enum NoticeSurface: Equatable, Sendable {
    case tips          // the tips card or window (a call is on or its Call ended screen is open)
    case window        // a banner in Home or Settings
    case menuBar       // a dot on the icon, the notice waits in the panel
}

public enum NoticeRules {
    public static let historyLimit = 20
    /// Where a new notice shows. The tips window wins: during a call the PM looks there and nowhere else.
    public static func surface(tipsVisible: Bool, windowVisible: Bool) -> NoticeSurface {
        tipsVisible ? .tips : windowVisible ? .window : .menuBar
    }
    /// The same text again within this many seconds replaces the older notice instead of stacking.
    public static let repeatWindow: Double = 120
}

/// 0.26.0: a call this short gets no Notion page (wrapup_notion.py refuses below the same number of real lines).
public enum NotionGate {
    public static let minLines = 5
    /// nil lines = not known (a call picked up after a restart): the sidecar decides.
    public static func tooShort(lines: Int?) -> Bool {
        guard let n = lines else { return false }
        return n < minLines
    }
}

/// 0.26.0: the raw error of wrapup_notion.py or notion_move ("RuntimeError: POST https://api.notion.com/v1/pages -> 401: ...")
/// becomes a cause the app can say in words, with the one action that helps.
public enum NotionFailure: String, CaseIterable {
    case tooShort, token, access, layout, noDatabase, busy, server, network, ai, other

    public enum Fix: Equatable { case settings, retry, none }

    public var fix: Fix {
        switch self {
        case .token, .access, .layout, .noDatabase: return .settings
        case .busy, .server, .network, .ai, .other: return .retry
        case .tooShort: return .none
        }
    }
    /// Too short is not a failure: nothing was meant to be written.
    public var level: NoticeLevel { self == .tooShort ? .info : .error }

    public static func classify(_ raw: String) -> NotionFailure {
        let s = raw.lowercased()
        func has(_ any: String...) -> Bool { any.contains { s.contains($0) } }
        if has("fewer than 5 transcript lines") { return .tooShort }
        if has("no meetings database", "no destination", "choose where meeting pages go") { return .noDatabase }
        if has("-> 401", "unauthorized", "api token is invalid", "no token", "notion token") { return .token }
        if has("-> 403", "-> 404", "object_not_found", "restricted_resource", "not_shared", "could not find database", "could not find page") { return .access }
        if has("-> 400", "validation_error") { return .layout }
        if has("-> 429", "rate_limited") { return .busy }
        if has("-> 500", "-> 502", "-> 503", "-> 504", "internal_server_error", "service_unavailable") { return .server }
        if has("urlopen error", "timed out", "timeout", "name or service not known", "nodename nor servname",
               "network is unreachable", "connection reset", "connection refused", "temporary failure in name resolution",
               "remotedisconnected", "sslerror", "ssl:") { return .network }
        if has("summary request failed", "summary json", "no json object in the reply", "usage limit") { return .ai }
        return .other
    }
}
