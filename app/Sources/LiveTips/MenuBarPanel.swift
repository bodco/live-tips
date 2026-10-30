import AppKit
import AVFoundation
import SwiftUI
import LiveTipsCore

// Pacenote 0.8 (F1): the menu bar panel. Replaces the plain NSMenu (macOS draws an NSMenu background itself,
// on macOS 26 a grey Liquid Glass). The app keeps its AppKit delegate and the NSStatusItem (the CLI modes and
// the shot mode stay as they are), so the panel is an NSPanel under the status item instead of a SwiftUI
// MenuBarExtra; it looks the same. Based on design/pacenote-0.8/swift/MenuBarPanel.swift, section 9a.

/// A call ahead: a calendar event (with its Up next setup, if any) or an Up next call without an event.
struct AheadCall: Identifiable {
    var id: String
    var event: CalendarService.CalEvent?
    var model: StartCallModel?
    var start: Date
    @MainActor var title: String { model?.effectiveTitle ?? event?.title ?? "" }

    /// The same list as Home's "Ahead": the calendars and Up next, without the call being recorded.
    @MainActor static func list(now: Date = Date()) -> [AheadCall] {
        let cal = CalendarService.shared, upnext = UpNext.shared, ce = CallEngine.shared
        var rows: [AheadCall] = []
        var used = Set<ObjectIdentifier>()
        let liveKey = ce.isRunning ? EditLog.seriesKey(ce.renamed ?? (ce.callRequest["title"] as? String) ?? "") : ""
        for e in cal.upcoming(now) where e.start > now.addingTimeInterval(-10 * 60) {
            if ce.isRunning, e.id == ce.liveEventID || (!liveKey.isEmpty && EditLog.seriesKey(e.title) == liveKey && e.start <= now.addingTimeInterval(15 * 60)) { continue }
            let m = upnext.visible.first { $0.calEventID == e.id }
            if let m = m { used.insert(ObjectIdentifier(m)) }
            rows.append(AheadCall(id: e.id, event: e, model: m, start: e.start))
        }
        for m in upnext.visible where !used.contains(ObjectIdentifier(m)) {
            rows.append(AheadCall(id: m.id.uuidString, event: nil, model: m, start: m.callDate))
        }
        return rows.sorted { $0.start < $1.start }
    }

    /// The Up next call behind a row; for a calendar event one is made (set up like the last call of its series).
    @MainActor func setup() -> StartCallModel {
        if let m = model { return m }
        let m = StartCallModel()
        if let e = event { m.applyEvent(e) }
        return m
    }
}

@MainActor
final class MenuBarModel: ObservableObject {
    struct Call: Identifiable {
        let id: String
        var title: String
        var startsAt: Date
        var state: UpNext.PrepState
        var note: String
        var ahead: AheadCall
    }

    @Published var isRecording = false        // the recorder writes the call
    @Published var isLive = false             // recording, waiting for the call or loading the model
    @Published var elapsed = "00:00"
    @Published var statusLine = ""            // "Waiting for the call", the audio warning
    @Published var warning = false
    @Published var liveTitle = ""
    @Published var liveLine = ""              // project · lines · tips
    @Published var next: Call?
    @Published var later: [Call] = []
    @Published var monthSpend: Double = 0
    @Published var monthCap: Double = 100
    @Published var lastCallLine = ""
    @Published var lastCallDetail: String?
    @Published var thisCallSpend: Double = 0
    @Published var canSendNotion = false
    @Published var notionResult = ""
    @Published var micMissing = false
    @Published var showDev = false
    @Published var helpKey = "⌃⌥H"
    @Published var pauseKey = "⌃⌥P"
    @Published var compactKey = "⌃⌥T"
    weak var app: AppDelegate?
    var close: () -> Void = {}

    func run(_ f: @escaping (AppDelegate) -> Void) {
        close()
        if let a = app { f(a) }
    }
}

struct MenuBarPanel: View {
    @ObservedObject var model: MenuBarModel
    @ObservedObject private var lang = LangModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if model.micMissing { micBanner }
            if model.isLive { liveCard } else { nextCard; laterList }
            Divider()
            if model.isLive {
                if model.isRecording {
                    row(L("menubar.helpNow"), model.helpKey) { $0.helpNow() }
                    row(L("menubar.compact"), model.compactKey) { $0.toggleCompact() }
                    row(L("menubar.pause"), model.pauseKey) { $0.togglePause() }
                }
                row(L("menubar.planCall"), "⌘N") { $0.startCall() }.keyboardShortcut("n")
                row(L("menubar.home"), "⌘0") { $0.openHome() }.keyboardShortcut("0")
            } else {
                row(L("menubar.home"), "⌘0") { $0.openHome() }.keyboardShortcut("0")
                row(L("menubar.startCall"), "⌘N") { $0.startCall() }.keyboardShortcut("n")
                row(L("tr.window"), "") { $0.openTranscribe() }
                Divider()
                spend
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 340)
        .background(PN.C.bg, in: RoundedRectangle(cornerRadius: PN.Radius.l))
        .overlay(RoundedRectangle(cornerRadius: PN.Radius.l).stroke(Color.primary.opacity(0.12)))
        .onExitCommand { model.close() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if model.isRecording {
                Circle().fill(PN.C.rec).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(L("menubar.status.recording", ["elapsed": model.elapsed]))
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit().foregroundStyle(PN.C.text)
            } else {
                PacenoteSymbol(height: 18)
                Text(L("app.name")).font(.system(size: 15, weight: .bold)).foregroundStyle(PN.C.text)
                Text("· " + (model.isLive ? model.statusLine : L("menubar.status.idle")))
                    .font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(1)
            }
            Spacer()
            Button { model.run { $0.openSettings() } } label: { Image(systemName: "gearshape").foregroundStyle(PN.C.text2) }
                .buttonStyle(.borderless).keyboardShortcut(",")
                .help(L("menubar.settings") + " ⌘,").accessibilityLabel(L("menubar.settings"))
        }
    }

    private var micBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "mic.slash").foregroundStyle(PN.C.onMe).accessibilityHidden(true)
            Text(L("menubar.micMissing")).font(PN.Font.caption).foregroundStyle(PN.C.text2)
            Spacer()
            Button(L("menubar.allowMic")) { model.run { $0.requestMic() } }.buttonStyle(.pnTertiary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(PN.C.onMe.opacity(0.12), in: RoundedRectangle(cornerRadius: PN.Radius.s))
    }

    @ViewBuilder private var nextCard: some View {
        if let n = model.next {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L("menubar.upNext", ["relative": Self.relative(n.startsAt), "time": Self.time(n.startsAt)]))
                        .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    Spacer()
                    badge(n.state)
                }
                Text(n.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(PN.C.text).lineLimit(2)
                if !n.note.isEmpty { Text(n.note).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(1) }
                HStack(spacing: 8) {
                    Button(L("menubar.startTips")) { start(n) }.buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
                    if n.state == .ready, let m = n.ahead.model, PrepDocWindow.path(for: m) != nil {
                        Button(L("menubar.openBrief")) { openBrief(n) }.buttonStyle(.pnSecondary)
                    } else if n.state != .running && n.state != .queued {
                        Button(L("menubar.prepare")) { prepare(n) }.buttonStyle(.pnSecondary)
                    }
                }
                .padding(.top, 6)
            }
            .padding(12)
            .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.m))
        } else {
            Text(L("menubar.nothingAhead")).font(PN.Font.caption).foregroundStyle(PN.C.text3).padding(.horizontal, 8)
        }
    }

    private var laterList: some View {
        VStack(spacing: 2) {
            ForEach(model.later) { c in
                Button { model.run { app in StartCallWindow.show(delegate: app, prepared: c.ahead.setup()) } } label: {
                    HStack(spacing: 10) {
                        Text(Self.time(c.startsAt)).font(PN.Font.caption).monospacedDigit().foregroundStyle(PN.C.text3)
                            .frame(width: 42, alignment: .leading)
                        Text(c.title).font(PN.Font.body).foregroundStyle(PN.C.text).lineLimit(1)
                        Spacer()
                        badge(c.state)
                    }
                    .padding(.horizontal, 8).frame(height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var liveCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.liveTitle).font(.system(size: 15, weight: .semibold)).foregroundStyle(PN.C.text).lineLimit(2)
            if !model.liveLine.isEmpty {
                Text(model.liveLine).font(PN.Font.caption).foregroundStyle(model.warning ? PN.C.danger : PN.C.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(L("menubar.showTips")) { model.run { $0.showTips() } }.buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
                if model.isRecording { Button(L("menubar.pauseShort")) { model.run { $0.togglePause() } }.buttonStyle(.pnSecondary) }
                // End call asks for confirmation first (AppDelegate.endCall / the tips window).
                Button(L("menubar.endCall")) { model.run { $0.endCall() } }.buttonStyle(.pnSecondary)
            }
            .padding(.top, 6)
        }
        .padding(12)
        .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.m))
    }

    private var spend: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("menubar.thisMonth", ["spent": String(format: "%.2f", model.monthSpend), "cap": String(format: "%.0f", model.monthCap)]))
                .font(PN.Font.caption).monospacedDigit().foregroundStyle(PN.C.text2)
            ProgressView(value: min(model.monthSpend / max(model.monthCap, 1), 1)).tint(PN.C.brand)
                .accessibilityLabel(L("menubar.thisMonth", ["spent": String(format: "%.2f", model.monthSpend), "cap": String(format: "%.0f", model.monthCap)]))
            if !model.lastCallLine.isEmpty {
                Text(model.lastCallLine).font(PN.Font.caption).foregroundStyle(PN.C.text3).help(model.lastCallDetail ?? "")
            }
            if model.canSendNotion {
                Button(L("menubar.sendNotion")) { model.run { $0.sendToNotion() } }.buttonStyle(.pnTertiary)
                    .help(model.notionResult)
            }
        }
        .padding(.horizontal, 8)
    }

    private var footer: some View {
        HStack {
            if model.isLive {
                Text(L("menubar.thisCall", ["cost": String(format: "%.2f", model.thisCallSpend)]))
                    .font(PN.Font.caption).monospacedDigit().foregroundStyle(PN.C.text3)
            }
            Menu(L("menubar.helpAbout")) {
                Button(L("menubar.setup")) { model.run { $0.openSetup() } }
                Button(L("menubar.welcomeTour")) { model.run { $0.openOnboarding() } }
                Button(L("settings.how.title")) { model.run { _ in HowItWorksWindow.show() } }
                Divider()
                Button(L("menubar.about")) { model.run { $0.openAbout() } }
                if model.showDev {      // Option held while opening: the tips window on demo data
                    Divider()
                    Button(L("menubar.demo")) { model.run { $0.showDemo() } }
                    Button(L("menubar.demoPresentation")) { model.run { $0.showDemoPresentation() } }
                }
            }
            .menuStyle(.borderlessButton).fixedSize()
            Spacer()
            if !model.isLive {
                Button(L("menubar.quit")) { NSApp.terminate(nil) }.buttonStyle(.pnTertiary).keyboardShortcut("q")
            }
        }
        .font(PN.Font.body)
    }

    private func row(_ title: String, _ key: String, _ action: @escaping (AppDelegate) -> Void) -> some View {
        Button { model.run(action) } label: {
            HStack {
                Text(title).foregroundStyle(PN.C.text)
                Spacer()
                Text(key).foregroundStyle(PN.C.text3)
            }
            .font(PN.Font.body)
            .padding(.horizontal, 8).frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func badge(_ s: UpNext.PrepState) -> some View {
        switch s {
        case .ready: PNBadge(text: L("badge.ready"), kind: .ready)
        case .running: PNBadge(text: L("badge.preparing"), kind: .stale)
        case .queued: PNBadge(text: L("badge.queued"), kind: .stale)
        case .failed: PNBadge(text: L("badge.failed"), kind: .live)
        case .none: PNBadge(text: L("badge.notPrepared"), kind: .notPrepared)
        }
    }

    private func start(_ c: MenuBarModel.Call) {
        model.run { app in
            let m = c.ahead.setup()
            guard !m.target.isEmpty else { StartCallWindow.show(delegate: app, prepared: m); return }
            if let e = app.launch(m) { CallEngine.shared.notify(e) }
        }
    }

    private func prepare(_ c: MenuBarModel.Call) {
        // 2026-10-27 (owner): a preparation asks first (project, what matters): the call's setup window.
        model.run { app in StartCallWindow.show(delegate: app, prepared: c.ahead.setup()) }
    }

    private func openBrief(_ c: MenuBarModel.Call) {
        model.run { _ in
            if let m = c.ahead.model, let p = PrepDocWindow.path(for: m) { PrepDocWindow.show(path: p, title: m.effectiveTitle) }
        }
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "EEE HH:mm"
        f.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US")
        return f.string(from: d)
    }

    static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US")
        f.unitsStyle = .short
        return d <= Date() ? L("menubar.now") : f.localizedString(for: d, relativeTo: Date())
    }
}

/// The panel window under the status item. It closes on a click outside, on Esc and after an action.
@MainActor
final class MenuBarPanelController: NSObject, NSWindowDelegate {
    final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    let model = MenuBarModel()
    private var panel: KeyPanel?
    private var host: NSHostingView<MenuBarPanel>?
    private var monitor: Any?
    private var closedAt = Date.distantPast
    weak var button: NSStatusBarButton?

    init(app: AppDelegate, button: NSStatusBarButton?) {
        self.button = button
        super.init()
        model.app = app
        model.close = { [weak self] in self?.close() }
    }

    var isOpen: Bool { panel?.isVisible == true }

    func toggle() {
        if isOpen { close(); return }
        guard Date().timeIntervalSince(closedAt) > 0.25 else { return }   // the click that closed it
        show()
    }

    func show() {
        model.showDev = NSEvent.modifierFlags.contains(.option)
        let p = panel ?? make()
        place(p)
        p.makeKeyAndOrderFront(nil)
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        guard let p = panel, p.isVisible else { return }
        p.orderOut(nil)
        closedAt = Date()
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    /// Keeps the top edge under the status item when the content changes height.
    func place(_ p: NSPanel? = nil) {
        guard let p = p ?? panel, let host = host else { return }
        let size = host.fittingSize
        var frame = NSRect(origin: .zero, size: size)
        if let b = button, let w = b.window {
            let r = w.convertToScreen(b.convert(b.bounds, to: nil))
            let vis = w.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? r
            frame.origin.x = min(max(vis.minX + 8, r.midX - size.width / 2), vis.maxX - size.width - 8)
            frame.origin.y = r.minY - size.height - 6
        } else if let vis = NSScreen.main?.visibleFrame {
            frame.origin = NSPoint(x: vis.maxX - size.width - 12, y: vis.maxY - size.height - 6)
        }
        p.setFrame(frame, display: true)
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    private func make() -> KeyPanel {
        let h = NSHostingView(rootView: MenuBarPanel(model: model))
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 300),
                         styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.contentView = h
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.delegate = self
        host = h
        panel = p
        return p
    }

    /// The panel as a window, for the shot mode.
    func windowForShots() -> NSWindow? {
        let p = panel ?? make()
        place(p)
        p.orderFrontRegardless()
        return p
    }
}
