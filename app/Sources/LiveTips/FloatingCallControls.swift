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
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 348, height: 132),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: FloatingCallControls(model: model))
        window.level = .floating
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        if let screen = NSScreen.main?.visibleFrame {
            window.setFrameOrigin(NSPoint(x: screen.maxX - 368, y: screen.minY + 24))
        }
        _ = window.setFrameUsingName("PacenoteFloatingCallControls")
        _ = window.setFrameAutosaveName("PacenoteFloatingCallControls")
    }

    func refresh(_ status: EngineStatus, config: AppConfig) {
        let live = CallEngine.shared.isRunning || ["recording", "standby", "loading_model"].contains(status.state)
        guard config.floatingCallControls, live else { window.orderOut(nil); return }
        model.status = status
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

private struct FloatingCallControls: View {
    @ObservedObject var model: FloatingCallModel
    @ObservedObject private var recording = CallRecorder.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Circle().fill(model.status.transcriptPaused ? Color.orange : Color.green).frame(width: 7, height: 7)
                Text(model.title).font(PN.Font.body.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Text(AppDelegate.elapsed(model.status)).monospacedDigit().font(PN.Font.caption)
                Menu {
                    Button(L("floating.disable")) { SettingsWindow.model.config.floatingCallControls = false; model.app?.refresh() }
                    Button(L("menubar.settings")) { model.app?.openSettings() }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().help(L("menubar.settings"))
            }
            HStack(spacing: 6) {
                Text(stateLabel).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(1)
                Spacer(minLength: 0)
                control("house", "menubar.home") {
                    HomeNav.shared.path = []; HomeNav.shared.followUp = nil
                    model.app?.openHome()
                }
                control("text.bubble", "menubar.showTips") { model.app?.showTips() }
                control(model.status.transcriptPaused ? "play.fill" : "pause.fill",
                        model.status.transcriptPaused ? "floating.resume" : "floating.pause") { model.pauseTranscript() }
                    .disabled(model.status.state != "recording" || model.status.inboxFile?.isEmpty != false || model.pausePending)
                control("stop.fill", "menubar.endCall") { model.app?.endCall() }
            }
            if recording.state != "off" {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: recording.kind == "video" ? "video" : "waveform")
                    Text(recordingLabel).font(PN.Font.caption).lineLimit(1)
                    Spacer(minLength: 0)
                    control(recording.state == "paused" ? "play.fill" : "pause.fill",
                            recording.state == "paused" ? "floating.recordingResume" : "floating.recordingPause") {
                        if recording.state == "paused" { recording.resume() } else { recording.pause() }
                    }.disabled(!["recording", "paused"].contains(recording.state))
                    control("stop.fill", "floating.recordingStop") { recording.stop() }
                        .disabled(!recording.isActive)
                }
            }
        }
        .padding(12)
        .frame(width: 348, height: 132, alignment: .topLeading)
        .foregroundStyle(PN.C.text)
        .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.m))
        .overlay(RoundedRectangle(cornerRadius: PN.Radius.m).stroke(PN.C.text3.opacity(0.2)))
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

    private var recordingLabel: String {
        let kind = L(recording.kind == "video" ? "rec.kind.video" : "rec.kind.audio")
        // 0.9.5: the same clock as the tips window (hours after the first hour), kept on pause
        switch recording.state {
        case "paused": return kind + " · " + CallRecorder.clock(recording.elapsedSec) + " · " + L("floating.paused")
        case "recording": return kind + " · " + CallRecorder.clock(recording.elapsedSec)
        default: return kind + " · " + L("floating.starting")
        }
    }

    private func control(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 24, height: 24) }
            .buttonStyle(.borderless).help(L(label)).accessibilityLabel(L(label))
    }
}
