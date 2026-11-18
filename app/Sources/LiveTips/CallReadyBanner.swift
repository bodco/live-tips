import LiveTipsCore
import SwiftUI

/// 0.24.1 (F6, decision 9): what a start button shows when a call cannot start yet, or only as a transcript: the
/// reason and one way out in place (Install with the loader, Connect AI). The answer is CallEngine.readiness(), the
/// same that AppDelegate.launch applies, so a start from the menu bar, the hot key or Up next behaves the same.
@MainActor
final class CallReadyState: ObservableObject {
    static let shared = CallReadyState()
    @Published var verdict: CallReadiness.Verdict = .ready
    @Published var degraded: [String] = []
    func refresh() {
        let v = CallEngine.shared.readiness()
        if v != verdict { verdict = v }
        let d = CallReadiness.degraded(missing: CallEngine.shared.baseMissing)
        if d != degraded { degraded = d }
    }
    var blocked: Bool { if case .blocked = verdict { return true }; return false }
}

struct CallReadyBanner: View {
    @ObservedObject var state = CallReadyState.shared
    @ObservedObject var setup = SetupWindow.model

    var body: some View {
        Group {
            switch state.verdict {
            case .blocked(let missing):
                card(icon: "exclamationmark.triangle.fill", tint: PN.C.onMe,
                     title: L("ready.blocked.title"),
                     text: L("ready.blocked", ["parts": names(missing)])) {
                    SetupLoader(model: setup, compact: true)
                }
            case .transcriptOnly(let why):
                card(icon: "waveform", tint: PN.C.text3, title: L("ready.transcript.title"), text: L("ready.transcript.\(why)")) {
                    Button(L("ready.connectAI")) { SettingsWindow.show(tab: "ai") }.buttonStyle(.pnSecondary)
                }
            case .ready:
                if !state.degraded.isEmpty {
                    HStack(spacing: 8) {
                        Text(L("ready.degraded", ["parts": names(state.degraded)])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                        if !setup.busy { Button(L("setup.installAll")) { Task { await setup.installMissing() } }.buttonStyle(.pnTertiary) }
                        else { SetupLoader(model: setup, showButton: false, compact: true).frame(maxWidth: 260) }
                    }
                }
            }
        }
        .onAppear { state.refresh() }
        .onChange(of: setup.busy) { state.refresh() }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in state.refresh() }
    }

    func names(_ ids: [String]) -> String { ids.compactMap { setup.step($0)?.title }.joined(separator: ", ") }

    func card<A: View>(icon: String, tint: Color, title: String, text: String, @ViewBuilder action: () -> A) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(PN.Font.body.weight(.semibold)).foregroundStyle(PN.C.text)
                Text(text).font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
                action()
            }
            Spacer(minLength: 0)
        }
        .padding(12).background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.m))
    }
}
