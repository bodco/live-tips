import Foundation

// 0.26.0 (block 2): a question to the PM (End the call?, End and start, Remove from Up next) is asked inline, in the
// place where the PM clicked, instead of a system alert: a row in the tips card, a strip in the tips window, a bar on top
// of an open Pacenote window or a row in the menu bar panel. One open question at a time; nothing modal.

/// Where the click came from.
public enum AskOrigin: String, Sendable {
    case tips          // the tips card or window
    case window        // Home, Start call, the call page, the floating controls
    case panel         // the menu bar panel
}

/// Where the question shows.
public enum AskPlace: Equatable, Sendable {
    case tips, window, panel
}

public enum AskRules {
    public static let cancel = "cancel"

    /// The question shows where the PM clicked; when that place is not on screen, the menu bar panel opens with it.
    public static func place(origin: AskOrigin, tipsVisible: Bool, windowVisible: Bool) -> AskPlace {
        switch origin {
        case .tips: return tipsVisible ? .tips : .panel
        case .window: return windowVisible ? .window : .panel
        case .panel: return .panel
        }
    }

    /// End the call?: End call, End and start <next> when a call is planned in Up next, Cancel. Cancel is always last.
    public static func endCallButtons(hasNext: Bool) -> [String] {
        hasNext ? ["end", "end-start", cancel] : ["end", cancel]
    }

    /// A call that the recorder still runs (or the app still owns) can be ended; otherwise End call only closes the window.
    public static func isLive(running: Bool, state: String) -> Bool {
        running || ["recording", "standby", "loading_model"].contains(state)
    }

    /// The questions about the running call go away when the call has ended by itself.
    public static let callKinds: Set<String> = ["end-call", "switch"]
}
