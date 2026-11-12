import LiveTipsCore
import SwiftUI

/// 0.10.0 (Meeting Sheet, hardening): the route question of a build, inline (never a modal alert): "Claude cannot
/// run now: ... Use ChatGPT / Not now". Shown in the build views and on the call page; also the line about a route
/// switched without asking (during a call, or queued).
struct SheetSwitchPrompt: View {
    @ObservedObject var runner = SheetRunner.shared
    var callID: UUID?

    var body: some View {
        if let p = runner.pendingSwitch, callID == nil || p.callID == callID {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("sheet.switch.title")).font(PN.Font.body).bold()
                Text(L("sheet.switch.body", ["from": AIRoute.name(p.from), "to": AIRoute.name(p.to), "why": p.reason]))
                    .font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button(L("sheet.switch.ok", ["to": AIRoute.name(p.to)])) { runner.acceptSwitch() }.buttonStyle(.pnPrimary)
                    Button(L("sheet.switch.cancel")) { runner.declineSwitch() }.buttonStyle(.pnSecondary)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(PN.C.pending.opacity(0.10)))
        } else if let n = runner.switchNotice, callID == nil || runner.callID == callID {
            Label(n, systemImage: "arrow.triangle.swap").font(PN.Font.caption).foregroundStyle(PN.C.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
