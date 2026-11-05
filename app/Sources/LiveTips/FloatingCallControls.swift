import AppKit
import SwiftUI
import LiveTipsCore

/// Independent of the tips web view: pausing works even after its window was closed.
@MainActor
final class FloatingCallController {
    let model = FloatingCallModel()
    let window: NSPanel

    init(app: AppDelegate) {
        model.app = app
        // 2026-11-05 (owner): a narrow vertical strip with the mark on top instead of a wide card with empty space.
        let host = NSHostingView(rootView: FloatingCallControls(model: model))
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: FloatingCallControls.width, height: 300),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.contentView = host
        window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.setContentSize(host.fittingSize)
        if let screen = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: screen.maxX - FloatingCallControls.width - 16, y: screen.midY - window.frame.height / 2))
        }
        // a new name: the old card's saved frame (348 pt wide) must not size the strip
        _ = window.setFrameUsingName("PacenoteFloatingStrip")
        _ = window.setFrameAutosaveName("PacenoteFloatingStrip")
    }

    func refresh(_ status: EngineStatus, config: AppConfig) {
        let live = CallEngine.shared.isRunning || ["recording", "standby", "loading_model"].contains(status.state)
        guard config.floatingCallControls, live else { window.orderOut(nil); return }
        model.status = status
        let fit = (window.contentView as? NSHostingView<FloatingCallControls>)?.fittingSize ?? window.frame.size
        if abs(fit.height - window.frame.height) > 0.5 {      // keep the top edge where it is
            let top = window.frame.maxY
            window.setFrame(NSRect(x: window.frame.minX, y: top - fit.height, width: fit.width, height: fit.height), display: true)
        }
        model.title = CallEngine.shared.renamed ?? (CallEngine.shared.callRequest["title"] as? String) ?? status.project ?? L("app.name")
        // Follow the current call's sharing choice, including changes made in Call settings.
        window.sharingType = model.app?.tips?.window?.sharingType ?? (config.stealthDefault ? .none : .readOnly)
        // Recover a saved position after unplugging a display, keeping the whole panel reachable.
        let frame = window.frame
        let screen = NSScreen.screens.first { $0.visibleFrame.intersects(frame) } ?? NSScreen.main
        if let bounds = screen?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: min(max(frame.minX, bounds.minX), bounds.maxX - frame.width),
                                          y: min(max(frame.minY, bounds.minY), bounds.maxY - frame.height)))
        }
        if !window.isVisible { window.orderFrontRegardless() }
    }
}

@MainActor
final class FloatingCallModel: ObservableObject {
    @Published var status = EngineStatus()
    @Published var title = ""
    weak var app: AppDelegate?
    private var awaitingPause: Bool?
    private var pauseSentAt = Date.distantPast

    var pausePending: Bool {
        awaitingPause != nil && awaitingPause != status.transcriptPaused && Date().timeIntervalSince(pauseSentAt) < 3
    }

    func pauseTranscript() {
        guard status.state == "recording", !pausePending,
              let inbox = status.inboxFile, !inbox.isEmpty else { return }
        let paused = !status.transcriptPaused
        appendLine(jsonLine(["t": nowHMS(), "kind": "setting", "key": "tips_paused", "value": paused ? "on" : "off"]), to: inbox)
        awaitingPause = paused
        pauseSentAt = Date()
        objectWillChange.send()
    }
}

struct FloatingCallControls: View {
    static let width: CGFloat = 52
    @ObservedObject var model: FloatingCallModel
    @ObservedObject private var recording = CallRecorder.shared
    @State private var hover: String?

    var body: some View {
        VStack(spacing: 4) {
            PacenoteSymbol(height: 26, dot: dotColor)
                .frame(width: 36, height: 34)
                .help(model.title + " · " + stateLabel)
                .accessibilityLabel(model.title + ", " + stateLabel)
                .contextMenu {
                    Button(L("floating.disable")) { SettingsWindow.model.config.floatingCallControls = false; model.app?.refresh() }
                    Button(L("menubar.settings")) { model.app?.openSettings() }
                }
            sep
            control("home", "house", "menubar.home") {
                HomeNav.shared.path = []; HomeNav.shared.followUp = nil
                model.app?.openHome()
            }
            control("tips", "text.bubble", "menubar.showTips") { model.app?.showTips() }
            control("pause", model.status.transcriptPaused ? "play.fill" : "pause.fill",
                    model.status.transcriptPaused ? "floating.resume" : "floating.pause",
                    tint: model.status.transcriptPaused ? PN.C.pending : nil) { model.pauseTranscript() }
                .disabled(model.status.state != "recording" || model.status.inboxFile?.isEmpty != false || model.pausePending)
            recordButton
            sep
            control("end", "stop.fill", "menubar.endCall", tint: PN.C.danger) { model.app?.endCall() }
        }
        .padding(.vertical, 8)
        .frame(width: Self.width)
        .foregroundStyle(PN.C.text2)
        .background(PN.C.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
    }

    private var sep: some View { Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 26, height: 1).padding(.vertical, 3) }

    /// Green: transcribing, orange: paused, red: the call is recorded, grey: waiting for the call.
    private var dotColor: Color {
        if ["recording", "paused", "starting"].contains(recording.state) { return PN.C.rec }
        if model.status.transcriptPaused { return PN.C.pending }
        return model.status.state == "recording" ? Color(red: 0x16 / 255, green: 0xA3 / 255, blue: 0x4A / 255) : PN.C.text3
    }

    /// 2026-11-05 (owner): one button for the recording. Off: what to record. On: pause, another window, stop only the
    /// recording, or end the whole call.
    private var recordButton: some View {
        let on = ["recording", "paused", "starting"].contains(recording.state)
        return Menu { RecordingMenu(app: model.app) } label: {
            ZStack {
                Circle().stroke(on ? PN.C.rec : PN.C.text2, lineWidth: 1.8).frame(width: 15, height: 15)
                Circle().fill(on ? PN.C.rec : PN.C.text2).frame(width: on ? 8 : 6, height: on ? 8 : 6)
                    .opacity(recording.state == "paused" ? 0.4 : 1)
            }
            .frame(width: 36, height: 36)
            .background(RoundedRectangle(cornerRadius: 10).fill(on ? PN.C.rec.opacity(0.13) : (hover == "rec" ? Color.primary.opacity(0.07) : .clear)))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .onHover { hover = $0 ? "rec" : nil }
        .disabled(recording.state == "choosing")
        .help(on ? RecordingMenu.label(recording) : L("rec.menu.start"))
        .accessibilityLabel(on ? RecordingMenu.label(recording) : L("rec.menu.start"))
    }

    private var stateLabel: String {
        if model.app?.panel?.model.warning == true { return L("menubar.status.audioFailing") }
        if model.status.transcriptPaused { return L("floating.paused") }
        switch model.status.state {
        case "recording": return L("floating.transcribing")
        case "standby": return L("menubar.status.waiting")
        default: return L("floating.starting")
        }
    }

    private func control(_ id: String, _ symbol: String, _ label: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                .foregroundStyle(tint ?? PN.C.text2)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 10).fill(tint == PN.C.pending ? PN.C.pending.opacity(0.14) : (hover == id ? Color.primary.opacity(0.07) : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 ? id : (hover == id ? nil : hover) }
        .help(L(label)).accessibilityLabel(L(label))
    }
}

/// 2026-11-05: the recording menu of the floating strip and the menu bar panel (the tips window has its own in HTML).
struct RecordingMenu: View {
    weak var app: AppDelegate?
    @ObservedObject private var r = CallRecorder.shared

    static func label(_ r: CallRecorder) -> String {
        let kind = L(r.kind == "video" ? "rec.kind.video" : "rec.kind.audio")
        let src = r.sourceLabel.isEmpty ? "" : " · " + r.sourceLabel
        switch r.state {
        case "paused": return kind + " · " + L("floating.paused") + src
        case "starting": return kind + " · " + L("floating.starting")
        default: return L("rec.menu.recording", ["kind": kind]) + src
        }
    }

    var body: some View {
        if ["recording", "paused", "starting"].contains(r.state) {
            Text(Self.label(r))
            Divider()
            if r.state == "paused" { Button(L("floating.recordingResume")) { r.resume() } }
            else { Button(L("floating.recordingPause")) { r.pause() }.disabled(r.state != "recording") }
            if r.kind == "video" { Button(L("rec.menu.source")) { r.changeSource() }.disabled(r.state == "starting") }
            Divider()
            Button(L("rec.menu.stopOnly")) { r.stop() }
            Button(L("rec.menu.endCall")) { app?.endCall() }
        } else {
            Button(L("rec.screen.now")) { r.beginLive(kind: "video") }
            Button(L("rec.sound.now")) { r.beginLive(kind: "audio") }
            Divider()
            Button(L("rec.menu.settings")) { SettingsWindow.show(tab: "recording") }
        }
    }
}
