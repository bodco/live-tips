import AppKit
import SwiftUI
import LiveTipsCore

// 0.26.0 (block 2): questions to the PM without system alerts. One open question at a time, shown where the PM clicked
// (AskRules.place): a row in the tips card, a strip in the tips window, a bar on top of Home or Start call, a row in
// the menu bar panel. Nothing modal, the focus stays where it was. A new question replaces the open one (as Cancel).

struct Ask: Identifiable, Equatable {
    struct Choice: Equatable {
        enum Role: String { case primary, danger, cancel }
        let id: String
        let title: String
        let role: Role
        static func cancel() -> Choice { Choice(id: AskRules.cancel, title: L("common.cancel"), role: .cancel) }
    }
    let id = UUID()
    let kind: String            // "end-call", "switch", "remove-upnext", "quit", "unsaved", "trash", "notion-new-page"
    let origin: AskOrigin
    let title: String
    let info: String
    let choices: [Choice]

    static func == (a: Ask, b: Ask) -> Bool { a.id == b.id }

    /// For the tips page (LiveTips.setAsk).
    var js: [String: Any] {
        ["id": id.uuidString, "text": title, "info": info,
         "buttons": choices.map { ["id": $0.id, "label": $0.title, "role": $0.role.rawValue] }]
    }
}

@MainActor
final class AskCenter: ObservableObject {
    static let shared = AskCenter()

    @Published private(set) var current: Ask?
    private var done: ((String) -> Void)?
    private var cancelled: (() -> Void)?

    // Set by AppDelegate: the tips window, the menu bar panel.
    static var tipsVisible: () -> Bool = { false }
    static var showPanel: () -> Void = {}
    static var changed: () -> Void = {}

    static var windowVisible: Bool {
        [HomeWindow.window, SettingsWindow.window, StartCallWindow.window].contains { w in w?.isVisible == true && w?.isMiniaturized == false }
    }

    /// Where the open question is now (nil: none).
    var place: AskPlace? {
        current.map { AskRules.place(origin: $0.origin, tipsVisible: Self.tipsVisible(), windowVisible: Self.windowVisible) }
    }
    func shows(_ p: AskPlace) -> Bool { place == p }

    /// Asks; `done` gets the chosen button's id, never Cancel. `cancelled` (block 3) runs on Cancel, also when the
    /// question is replaced or its place goes away: for questions that must always get an answer (Quit, Unsaved).
    func ask(kind: String, origin: AskOrigin, title: String, info: String = "", choices: [Ask.Choice],
             cancelled: (() -> Void)? = nil, done: @escaping (String) -> Void) {
        if let old = current { AppLog.app("ask: \(old.kind) replaced"); answer(old.id, AskRules.cancel) }
        current = Ask(kind: kind, origin: origin, title: title, info: info, choices: choices)
        self.done = done
        self.cancelled = cancelled
        AppLog.app("ask: \(kind) in \(origin.rawValue)")
        if place == .panel { Self.showPanel() }
        Self.changed()
    }

    func answer(_ id: UUID, _ choice: String) {
        guard let a = current, a.id == id else { return }
        let d = done, c = cancelled
        current = nil; done = nil; cancelled = nil
        AppLog.app("ask: \(a.kind) -> \(choice)")
        Self.changed()
        if choice != AskRules.cancel { d?(choice) } else { c?() }
    }

    /// Closes the open question as Cancel: of these kinds, from this origin, or any.
    func cancel(kinds: Set<String>? = nil, origin: AskOrigin? = nil) {
        guard let a = current else { return }
        if let k = kinds, !k.contains(a.kind) { return }
        if let o = origin, a.origin != o { return }
        answer(a.id, AskRules.cancel)
    }

    /// The menu bar panel closed: a question that was shown there goes with it.
    func panelClosed() { if place == .panel { cancel() } }

    // 0.26.0 (review 1): a window that closes takes its bar with it. Unsaved is answered as Cancel (saves); any other
    // question asked there moves to the menu bar panel instead of staying invisible.
    private(set) static var windowClosing = false
    private static var watched = Set<ObjectIdentifier>()

    /// Called once per Pacenote window (Home, Settings, Start call) that shows an AskBar.
    static func watch(_ w: NSWindow) {
        guard watched.insert(ObjectIdentifier(w)).inserted else { return }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { shared.windowWillClose() }
        }
    }

    private func windowWillClose() {
        Self.windowClosing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Self.windowClosing = false }
        cancel(kinds: ["unsaved"], origin: .window)
        DispatchQueue.main.async { self.reevaluate() }
    }

    /// The open question's place may have changed (a window closed): open the panel when it is the place now.
    func reevaluate() {
        guard current != nil else { return }
        if place == .panel { Self.showPanel() }
        Self.changed()
    }
}

/// One question as a row: the question, the detail, the buttons (Cancel last). Used by the bar and the panel.
struct AskRow: View {
    let ask: Ask
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "questionmark.circle").foregroundStyle(PN.C.text2).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ask.title).font(compact ? PN.sys(12, .semibold) : PN.sys(13, .semibold)).foregroundStyle(PN.C.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if !ask.info.isEmpty {
                        Text(ask.info).font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ForEach(ask.choices, id: \.id) { c in
                    button(c)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ask.title)
    }

    @ViewBuilder private func button(_ c: Ask.Choice) -> some View {
        let run = { AskCenter.shared.answer(ask.id, c.id) }
        switch c.role {
        case .cancel: Button(c.title, action: run).buttonStyle(.pnSecondary).keyboardShortcut(.cancelAction)
        case .primary: Button(c.title, action: run).buttonStyle(.pnPrimary)
        case .danger:
            Button(action: run) {
                Text(c.title).font(PN.sys(13, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: PN.r(8)).fill(PN.C.danger))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// The bar on top of an open Pacenote window (Home, Settings, Start call) while a question asked there is open.
struct AskBar: View {
    @ObservedObject private var center = AskCenter.shared

    var body: some View {
        if let a = center.current, center.shows(.window) {
            AskRow(ask: a)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PN.C.surface2)
                .overlay(alignment: .leading) { Rectangle().fill(PN.C.danger).frame(width: 3) }
                .overlay(alignment: .bottom) { Rectangle().fill(PN.C.rule).frame(height: 1) }
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// The menu bar panel's part: the open question asked in the panel (or with no other place on screen).
struct AskPanelSection: View {
    @ObservedObject private var center = AskCenter.shared
    var relayout: () -> Void = {}

    var body: some View {
        Group {
            if let a = center.current, center.shows(.panel) {
                AskRow(ask: a, compact: true)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(PN.C.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: PN.Radius.s))
                    .padding(.bottom, 10)
            }
        }
        .onChange(of: center.current?.id) { _, _ in DispatchQueue.main.async { relayout() } }
    }
}

extension View {
    /// 0.26.0 (block 2): a window that shows a question asked in it on top (Home, Settings, Start call).
    func askBar() -> some View {
        VStack(spacing: 0) {
            AskBar()
            self
        }
    }
}
