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
            if ce.isRunning, e.has(ce.liveEventID) || (!liveKey.isEmpty && EditLog.seriesKey(e.title) == liveKey && e.start <= now.addingTimeInterval(15 * 60)) { continue }
            let m = upnext.visible.first { e.has($0.calEventID) }
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
    @Published var agentOn = false             // 0.9.6: the call agent's flag or any API key (Б1): the economy leaf shows
    @Published var economy = false             // 0.9.6: economy mode (state/economy)
    @Published var canSendNotion = false
    @Published var notionResult = ""
    @Published var micMissing = false
    @Published var showDev = false
    @Published var helpKey = "⌃⌥H"
    @Published var pauseKey = "⌃⌥P"
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
    @ObservedObject private var recording = CallRecorder.shared

    // 2026-11-05 (owner): redesigned in the style of Home: the call as a full-width card with its three actions, the
    // calls ahead as rows with their state, actions with icons and shortcuts, the money and Help in the footer.
    // No running time here: it is in the tips window only.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 10)
            if model.micMissing { micBanner.padding(.bottom, 10) }
            if model.isLive { liveCard } else { nextCard }
            let rows = model.isLive ? ([model.next].compactMap { $0 } + model.later) : model.later
            if !rows.isEmpty {
                label(model.isLive ? L("home.comingUp") : L("home.later"))
                laterList(Array(rows.prefix(4)))
            }
            label(L("app.name"))
            VStack(spacing: 1) {
                if model.isLive {
                    if model.isRecording {
                        row(L("menubar.helpNow"), model.helpKey, icon: "lifepreserver") { $0.helpNow() }
                        row(L("menubar.pause"), model.pauseKey, icon: "pause") { $0.togglePause() }
                    }
                    row(L("menubar.planCall"), "⌘N", icon: "plus") { $0.startCall() }.keyboardShortcut("n")
                    row(L("menubar.home"), "⌘0", icon: "house") { $0.openHome() }.keyboardShortcut("0")
                } else {
                    row(L("menubar.startCall"), "⌘N", icon: "play") { $0.startCall() }.keyboardShortcut("n")
                    row(L("menubar.home"), "⌘0", icon: "house") { $0.openHome() }.keyboardShortcut("0")
                    row(L("tr.window"), "", icon: "waveform") { $0.openTranscribe() }
                    if model.canSendNotion {
                        row(L("menubar.sendNotion"), "", icon: "arrow.up.doc") { $0.sendToNotion() }.help(model.notionResult)
                    }
                }
            }
            Divider().padding(.top, 8)
            footer.padding(.top, 8)
        }
        .padding(12)
        .frame(width: 330)
        .background(PN.C.bg, in: RoundedRectangle(cornerRadius: PN.Radius.l))
        .overlay(RoundedRectangle(cornerRadius: PN.Radius.l).stroke(Color.primary.opacity(0.12)))
        .onExitCommand { model.close() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            PacenoteSymbol(height: 18)
            Text(L("app.name")).font(.system(size: 15, weight: .bold)).foregroundStyle(PN.C.text)
            Spacer()
            Button { model.run { $0.openSettings() } } label: { Image(systemName: "gearshape").foregroundStyle(PN.C.text2) }
                .buttonStyle(.borderless).keyboardShortcut(",")
                .help(L("menubar.settings") + " ⌘,").accessibilityLabel(L("menubar.settings"))
        }
        .padding(.horizontal, 4)
    }

    private func label(_ t: String) -> some View {
        Text(t.uppercased()).font(PN.Font.label).kerning(0.4).foregroundStyle(PN.C.text3)
            .padding(.horizontal, 6).padding(.top, 14).padding(.bottom, 4)
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

    private func card<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 3) { c() }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PN.C.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06)))
    }

    private func kicker(_ t: String, _ c: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(c).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(t.uppercased()).font(.system(size: 11, weight: .semibold)).kerning(0.3).foregroundStyle(c).lineLimit(1)
        }
    }

    @ViewBuilder private var nextCard: some View {
        if let n = model.next {
            card {
                HStack(alignment: .firstTextBaseline) {
                    kicker(L("menubar.upNext", ["relative": Self.relative(n.startsAt), "time": Self.time(n.startsAt)]), PN.C.accent)
                    Spacer()
                    badge(n.state)
                }
                Button { openPage(n) } label: {
                    Text(n.title).font(.system(size: 15, weight: .bold)).foregroundStyle(PN.C.text).lineLimit(2).multilineTextAlignment(.leading)
                }.buttonStyle(.plain).help(L("home.openCall.help")).padding(.top, 2)
                if !n.note.isEmpty { Text(n.note).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(1) }
                // 0.9.0: the same rule as Home: one main button and one more next to it
                HStack(spacing: 8) {
                    let st = CallState.of(n.state, ai: HomeView.aiReadyNow())
                    switch st {
                    case .noBrief:
                        wide(L("home.startCall"), primary: true) { start(n) }.keyboardShortcut(.defaultAction)
                        wide(L("home.connectClaude")) { model.run { _ in SettingsWindow.show(tab: "ai") } }
                    case .ready:
                        wide(L("home.startCall"), primary: true) { start(n) }.keyboardShortcut(.defaultAction)
                        wide(L("talk.prepareAgain")) { prepare(n) }
                    case .preparing, .queued:
                        wide(L("home.startCall"), primary: true) { start(n) }.keyboardShortcut(.defaultAction)
                    default:
                        wide(L("home.getReady"), primary: true) { prepare(n) }.keyboardShortcut(.defaultAction)
                        wide(L("home.startWithout")) { start(n) }
                    }
                }
                .padding(.top, 8)
            }
        } else {
            card {
                Text(L("menubar.nothingAhead")).font(PN.Font.body).foregroundStyle(PN.C.text3)
                HStack(spacing: 8) { wide(L("menubar.startCall"), primary: true) { model.run { $0.startCall() } } }.padding(.top, 6)
            }
        }
    }

    private func laterList(_ rows: [MenuBarModel.Call]) -> some View {
        VStack(spacing: 1) {
            ForEach(rows) { c in
                Button { openPage(c) } label: {
                    HStack(spacing: 10) {
                        Text(Self.time(c.startsAt)).font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(PN.C.accent)
                            .frame(width: 58, alignment: .leading)
                        Text(c.title).font(PN.Font.body).foregroundStyle(PN.C.text).lineLimit(1)
                        Spacer(minLength: 6)
                        badge(c.state)
                    }
                    .padding(.horizontal, 6).frame(height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var liveCard: some View {
        let recOn = ["recording", "paused", "starting"].contains(recording.state)
        let (txt, col): (String, Color) = model.warning ? (L("menubar.status.audioFailing"), PN.C.danger)
            : !model.isRecording ? (model.statusLine.isEmpty ? L("floating.starting") : model.statusLine, PN.C.text3)
            : recOn ? (RecordingMenu.label(recording), PN.C.rec) : (L("floating.transcribing"), PN.C.turn)
        return card {
            kicker(txt, col)
            Text(model.liveTitle).font(.system(size: 15, weight: .bold)).foregroundStyle(PN.C.text).lineLimit(2).padding(.top, 2)
            if !model.liveLine.isEmpty && !model.warning {
                Text(model.liveLine).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(2)
            }
            HStack(spacing: 6) {
                wide(L("menubar.showTips"), primary: true) { model.run { $0.showTips() } }.keyboardShortcut(.defaultAction)
                Button { RecordingMenu.pop(app: model.app) } label: {
                    HStack(spacing: 5) {
                        ZStack {
                            Circle().stroke(recOn ? PN.C.rec : PN.C.text2, lineWidth: 1.5).frame(width: 11, height: 11)
                            Circle().fill(recOn ? PN.C.rec : PN.C.text2).frame(width: 5, height: 5)
                        }
                        Text(L(recOn ? "rec.short.on" : "rec.short.off")).font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(recOn ? PN.C.rec : PN.C.text2)
                    .frame(maxWidth: .infinity).frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(recOn ? PN.C.rec.opacity(0.12) : PN.C.surface2))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(recording.state == "choosing" || !model.isRecording && !recOn)
                // End call asks for confirmation first (AppDelegate.endCall / the tips window).
                wide(L("menubar.endCall"), danger: true) { model.run { $0.endCall() } }
            }
            .padding(.top, 8)
        }
    }

    private func wide(_ t: String, primary: Bool = false, danger: Bool = false, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(t).font(.system(size: 12, weight: primary ? .semibold : .medium)).lineLimit(1).minimumScaleFactor(0.85)
                .foregroundStyle(primary ? Color.white : danger ? PN.C.danger : PN.C.text2)
                .frame(maxWidth: .infinity).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(primary ? PN.C.accentFill : danger ? PN.C.danger.opacity(0.1) : PN.C.surface2))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Group {
                if model.isLive {
                    Text(L("menubar.thisCall", ["cost": String(format: "%.2f", model.thisCallSpend)]))
                } else {
                    Text(L("menubar.thisMonth", ["spent": String(format: "%.2f", model.monthSpend), "cap": String(format: "%.0f", model.monthCap)]))
                        .help(model.lastCallLine + (model.lastCallDetail.map { "\n" + $0 } ?? ""))
                }
            }
            .font(PN.Font.caption).monospacedDigit().foregroundStyle(PN.C.text3).lineLimit(1).layoutPriority(1)
            if model.agentOn || model.economy {
                // 0.9.6 (owner): economy mode by hand, also during a call: the call agent stops, the lookups answer
                Button {
                    model.economy.toggle()
                    MainActor.assumeIsolated { SpendWatch.setEconomy(model.economy) }
                } label: {
                    // 2026-11-06 (GUI check): the leaf alone; with its label the panel wrapped "Econom / y on" and cut the
                    // month's spend. Green and filled = on; the state is in the tooltip and for VoiceOver.
                    Image(systemName: model.economy ? "leaf.fill" : "leaf")
                        .font(PN.Font.caption).foregroundStyle(model.economy ? PN.C.turn : PN.C.text3)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain).fixedSize()
                .help(L(model.economy ? "economy.on" : "economy.off") + "\n" + L("economy.help"))
                .accessibilityLabel(L("economy.title")).accessibilityValue(L(model.economy ? "economy.on" : "economy.off"))
            }
            Spacer()
            Menu(L("menubar.helpAbout")) {
                Button(L("menubar.setup")) { model.run { $0.openSetup() } }
                Button(L("menubar.welcomeTour")) { model.run { $0.openOnboarding() } }
                Button(L("feat.title")) { model.run { _ in FeaturesWindow.show() } }
                Button(L("settings.how.title")) { model.run { _ in HowItWorksWindow.show() } }
                Divider()
                Button(L("menubar.about")) { model.run { $0.openAbout() } }
                Divider()       // 0.8.7 (L1): the demo calls are always here, no Option key
                Button(L("menubar.demo")) { model.run { $0.showDemo() } }
                Button(L("menubar.demoPresentation")) { model.run { $0.showDemoPresentation() } }
                if !model.isLive {
                    Divider()
                    Button(L("menubar.quit")) { NSApp.terminate(nil) }.keyboardShortcut("q")
                }
            }
            .menuStyle(.borderlessButton).fixedSize().font(PN.Font.caption)
        }
        .padding(.horizontal, 6)
    }

    private func row(_ title: String, _ key: String, icon: String, _ action: @escaping (AppDelegate) -> Void) -> some View {
        Button { model.run(action) } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 12, weight: .medium)).foregroundStyle(PN.C.accent)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 7).fill(PN.C.surface))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.08)))
                Text(title).foregroundStyle(PN.C.text).lineLimit(1)
                Spacer()
                Text(key).foregroundStyle(PN.C.text3)
            }
            .font(PN.Font.body)
            .padding(.horizontal, 6).frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowStyle())
    }

    /// 0.9.0: the soft pill of Home (Ready / Not ready), no loud fills.
    private func badge(_ s: UpNext.PrepState) -> some View { StatePill(state: CallState.of(s, ai: HomeView.aiReadyNow())) }

    private func link(_ t: String, run: @escaping () -> Void) -> some View {
        Button(action: run) { Text(t).font(PN.Font.caption).foregroundStyle(PN.C.accent) }.buttonStyle(.plain)
    }

    /// The call's page in Home (Setup, Brief, Tasks, Earlier calls).
    private func openPage(_ c: MenuBarModel.Call) {
        model.run { app in HomeWindow.show(delegate: app); UpcomingPages.open(c.ahead.setup()) }
    }

    private func start(_ c: MenuBarModel.Call) {
        model.run { app in
            let m = c.ahead.setup()
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

/// A row of the menu bar panel: a soft highlight under the pointer, like a menu.
private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Hover(configuration: configuration) }
    private struct Hover: View {
        let configuration: ButtonStyle.Configuration
        @State private var on = false
        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(configuration.isPressed ? 0.1 : on ? 0.06 : 0)))
                .onHover { on = $0 }
        }
    }
}
