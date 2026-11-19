import AppKit
import SwiftUI
import LiveTipsCore

// 0.26.0 (block 1): the app's notices instead of system alerts. One center; three places to show (NoticeRules.surface):
// a line in the tips card or window during a call, a banner on top of Home or Settings, otherwise a dot on the
// menu bar icon with the notice waiting in the menu bar panel. Never modal, never takes the focus, never a macOS
// notification. Each notice has at most one action.

struct Notice: Identifiable, Equatable {
    enum Action: Equatable {
        case url(String, title: String)      // Open in Notion, Open in Drive
        case settings(String)                // a Settings tab
        case retry                           // the closure kept by the center
        case finder(String)                  // a file or folder
    }
    let id = UUID()
    let level: NoticeLevel
    let text: String
    let action: Action?
    let at = Date()
    var dismissed = false
    var shownAt: Date?

    var actionTitle: String? {
        switch action {
        case .url(_, let t): return t
        case .settings: return L("common.openSettings")
        case .retry: return L("notice.tryAgain")
        case .finder: return L("notice.showInFinder")
        case nil: return nil
        }
    }
    /// For the tips page (LiveTips.setNotice).
    var js: [String: Any] {
        var d: [String: Any] = ["id": id.uuidString, "level": level.rawValue, "text": text, "close": L("common.close")]
        if let t = actionTitle { d["act"] = t }
        return d
    }
}

@MainActor
final class NoticeCenter: ObservableObject {
    static let shared = NoticeCenter()

    /// Newest first: what is still open and the recent history (NoticeRules.historyLimit).
    @Published private(set) var items: [Notice] = []
    private var retries: [UUID: () -> Void] = [:]

    // Set by AppDelegate: the tips window and the menu bar icon live there.
    static var tipsVisible: () -> Bool = { false }
    static var changed: () -> Void = {}

    var active: [Notice] { items.filter { !$0.dismissed } }
    var recent: [Notice] { items.filter { $0.dismissed } }
    /// The menu bar dot: the highest level among the notices nobody saw yet.
    var unread: NoticeLevel? { active.filter { $0.shownAt == nil }.max { $0.level.rank < $1.level.rank }?.level }

    static var windowVisible: Bool {
        [HomeWindow.window, SettingsWindow.window].contains { w in w?.isVisible == true && w?.isMiniaturized == false }
    }

    /// Thread-safe entry for code that is not on the main actor (CallEngine, the recorder, Drive).
    nonisolated static func post(_ text: String, level: NoticeLevel = .info, action: Notice.Action? = nil, retry: (() -> Void)? = nil) {
        let run = { MainActor.assumeIsolated { _ = NoticeCenter.shared.post(text, level: level, action: action, retry: retry) } }
        if Thread.isMainThread { run() } else { DispatchQueue.main.async(execute: run) }
    }

    @discardableResult
    func post(_ text: String, level: NoticeLevel = .info, action: Notice.Action? = nil, retry: (() -> Void)? = nil) -> UUID {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        AppLog.app("notice: \(level.rawValue) \(text.prefix(200))")
        let now = Date()
        for old in items where !old.dismissed && old.text == text && now.timeIntervalSince(old.at) < NoticeRules.repeatWindow {
            retries[old.id] = nil
        }
        items.removeAll { !$0.dismissed && $0.text == text && now.timeIntervalSince($0.at) < NoticeRules.repeatWindow }
        let n = Notice(level: level, text: text, action: action == .retry && retry == nil ? nil : action)
        items.insert(n, at: 0)
        if let r = retry { retries[n.id] = r }
        trim()
        switch NoticeRules.surface(tipsVisible: Self.tipsVisible(), windowVisible: Self.windowVisible) {
        case .tips, .window: markShown(n.id)
        case .menuBar: break
        }
        Self.changed()
        return n.id
    }

    /// On screen now: info goes by itself after a while.
    func markShown(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].shownAt == nil else { return }
        items[i].shownAt = Date()
        if let s = items[i].level.autoDismissSeconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + s) { [weak self] in MainActor.assumeIsolated { self?.dismiss(id) } }
        }
        Self.changed()
    }

    func dismiss(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }), !items[i].dismissed else { return }
        items[i].dismissed = true
        retries[id] = nil
        Self.changed()
    }

    func perform(_ id: UUID) {
        guard let n = items.first(where: { $0.id == id }), let a = n.action else { return }
        let retry = retries[id]
        dismiss(id)
        switch a {
        case .url(let u, _): if let link = URL(string: u) { NSWorkspace.shared.open(link) }
        case .settings(let tab): SettingsWindow.show(tab: tab)
        case .retry: retry?()
        case .finder(let p): NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
        }
    }

    /// The menu bar panel opened: everything in it has been seen.
    func panelOpened() { for n in active where n.shownAt == nil { markShown(n.id) } }

    func clearRecent() { items.removeAll { $0.dismissed }; Self.changed() }

    private func trim() {
        while items.count > NoticeRules.historyLimit, let i = items.lastIndex(where: { $0.dismissed }) ?? items.indices.last {
            retries[items[i].id] = nil
            items.remove(at: i)
        }
    }

    static func color(_ l: NoticeLevel) -> Color {
        switch l { case .error: return PN.C.recText; case .warning: return PN.C.onMe; case .info: return PN.C.text2 }
    }
    static func symbol(_ l: NoticeLevel) -> String {
        switch l { case .error: return "exclamationmark.octagon"; case .warning: return "exclamationmark.triangle"; case .info: return "info.circle" }
    }
}

/// One notice as a row: the level's mark, the text, the action, Close. Used by the banner and the menu bar panel.
struct NoticeRow: View {
    let notice: Notice
    var compact = false
    var onAction: () -> Void
    var onClose: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: NoticeCenter.symbol(notice.level))
                .foregroundStyle(NoticeCenter.color(notice.level))
                .accessibilityLabel(L("notice.level." + notice.level.rawValue))
            Text(notice.text)
                .font(compact ? PN.Font.caption : PN.Font.body)
                .foregroundStyle(notice.level == .error ? PN.C.recText : PN.C.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if let t = notice.actionTitle {
                Button(t, action: onAction).buttonStyle(.pnTertiary)
            }
            if let c = onClose {
                Button(action: c) { Image(systemName: "xmark").font(PN.sys(10, .semibold)).foregroundStyle(PN.C.text3) }
                    .buttonStyle(.borderless)
                    .help(L("common.close")).accessibilityLabel(L("common.close"))
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// The banner on top of an open Pacenote window: the newest open notice, "+n more" when there are others.
struct NoticeBanner: View {
    @ObservedObject private var center = NoticeCenter.shared

    var body: some View {
        if let n = center.active.first {
            let more = center.active.count - 1
            VStack(alignment: .leading, spacing: 4) {
                NoticeRow(notice: n, onAction: { center.perform(n.id) }, onClose: { center.dismiss(n.id) })
                if more > 0 {
                    Text(L("notice.more", ["n": "\(more)"])).font(PN.Font.caption).foregroundStyle(PN.C.text3).padding(.leading, 24)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PN.C.surface2)
            .overlay(alignment: .leading) { Rectangle().fill(NoticeCenter.color(n.level)).frame(width: 3) }
            .overlay(alignment: .bottom) { Rectangle().fill(PN.C.rule).frame(height: 1) }
            .onAppear { center.markShown(n.id) }
            .onChange(of: n.id) { _, id in center.markShown(id) }
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityAddTraits(.isStaticText)
        }
    }
}

extension View {
    /// 0.26.0: a window that shows the app's notices on top (Home, Settings).
    func noticeBanner() -> some View {
        VStack(spacing: 0) {
            AskBar()              // 0.26.0 (block 2): a question asked in this window
            NoticeBanner()
            self
        }
    }
}

/// The menu bar panel's part: open notices first, then the recent ones behind a disclosure.
struct NoticePanelSection: View {
    @ObservedObject private var center = NoticeCenter.shared
    @State private var showRecent = false
    var relayout: () -> Void = {}

    var body: some View {
        let active = center.active, recent = center.recent
        if !active.isEmpty || !recent.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(active.prefix(3)) { n in
                    NoticeRow(notice: n, compact: true, onAction: { center.perform(n.id) }, onClose: { center.dismiss(n.id) })
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(NoticeCenter.color(n.level).opacity(0.10), in: RoundedRectangle(cornerRadius: PN.Radius.s))
                }
                if active.count > 3 {
                    Text(L("notice.more", ["n": "\(active.count - 3)"])).font(PN.Font.caption).foregroundStyle(PN.C.text3).padding(.leading, 10)
                }
                if !recent.isEmpty {
                    Button { showRecent.toggle() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showRecent ? "chevron.down" : "chevron.right").font(PN.sys(9, .semibold))
                            Text(L("notice.recent", ["n": "\(recent.count)"]))
                        }
                        .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    }
                    .buttonStyle(.borderless).padding(.leading, 6)
                    .accessibilityAddTraits(.isHeader)
                    if showRecent {
                        ForEach(recent.prefix(5)) { n in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(Self.time(n.at)).font(PN.sys(11)).monospacedDigit().foregroundStyle(PN.C.text3)
                                Text(n.text).font(PN.Font.caption).foregroundStyle(PN.C.text2).lineLimit(3)
                                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                            }
                            .padding(.horizontal, 10)
                        }
                        Button(L("notice.clear")) { center.clearRecent() }.buttonStyle(.pnTertiary).padding(.leading, 6)
                    }
                }
            }
            .padding(.bottom, 10)
            .onChange(of: center.items.count) { _, _ in DispatchQueue.main.async { relayout() } }
            .onChange(of: showRecent) { _, _ in DispatchQueue.main.async { relayout() } }
        }
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }
}
