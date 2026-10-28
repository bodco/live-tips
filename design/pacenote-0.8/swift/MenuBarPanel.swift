// Pacenote menu bar panel, v0.8. Reference skeleton, wire to real models.
// Replaces the plain NSMenu: macOS draws an NSMenu background itself, so a styled panel
// needs MenuBarExtra with .menuBarExtraStyle(.window). See the "Menu bar panel" artboard.
//
// Usage in the App:
//   MenuBarExtra { MenuBarPanel(model: menuModel) } label: { MenuBarLabel(model: menuModel) }
//       .menuBarExtraStyle(.window)
//
// Assets: add brand/menubar/PacenoteTemplate.pdf and PacenoteRecordingTemplate.pdf to
// Assets.xcassets as image sets with "Render As: Template Image".

import SwiftUI

@MainActor
final class MenuBarModel: ObservableObject {
    struct NextCall { var title: String; var startsAt: Date; var ready: Bool; var note: String }
    struct LaterCall: Identifiable { let id = UUID(); var time: String; var title: String; var badge: String; var ready: Bool }

    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0
    @Published var liveTitle = ""
    @Published var liveAgendaLine = ""      // "Agenda 2 of 3 · not raised: test accounts"
    @Published var onMe: [String] = []
    @Published var next: NextCall?
    @Published var later: [LaterCall] = []
    @Published var monthSpend: Double = 0
    @Published var monthCap: Double = 100
    @Published var lastCallLine = ""        // "Last call $0.47 · 2 tips · rated 1.0 of 5"
    @Published var thisCallSpend: Double = 0

    // Actions: connect to existing app commands.
    var startTips: () -> Void = {}
    var openBrief: () -> Void = {}
    var showTips: () -> Void = {}
    var togglePause: () -> Void = {}
    var endCall: () -> Void = {}
    var prepareNext: () -> Void = {}
    var openHome: () -> Void = {}
    var startCall: () -> Void = {}
    var helpNow: () -> Void = {}
    var toggleCompact: () -> Void = {}
    var openSettings: () -> Void = {}
    var openSetup: () -> Void = {}
    var openWelcomeTour: () -> Void = {}
    var openAbout: () -> Void = {}
}

struct MenuBarLabel: View {
    @ObservedObject var model: MenuBarModel
    var body: some View {
        if model.isRecording {
            HStack(spacing: 4) {
                Image("PacenoteRecordingTemplate")
                Text(Self.format(model.elapsed)).monospacedDigit()
            }
        } else {
            Image("PacenoteTemplate")
        }
    }
    static func format(_ t: TimeInterval) -> String {
        let s = Int(t); return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
                                         : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

struct MenuBarPanel: View {
    @ObservedObject var model: MenuBarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if model.isRecording { liveCard; onMeList } else { nextCard; laterList }
            Divider()
            if model.isRecording {
                row("Help now", "⌃⌥H", model.helpNow)
                row("Compact tips", "⌃⌥T", model.toggleCompact)
            } else {
                row("Open Home", "⌘0", model.openHome)
                row("Start a call…", "⌘N", model.startCall)
                Divider()
                spend
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if model.isRecording {
                Circle().fill(PN.C.rec).frame(width: 8, height: 8)
                Text("Recording · \(MenuBarLabel.format(model.elapsed))").font(.system(size: 13, weight: .semibold)).monospacedDigit()
            } else {
                Image("PacenoteSymbol").resizable().scaledToFit().frame(height: 18)   // brand/symbol/pacenote-symbol-ink.svg
                Text("Pacenote").font(.system(size: 15, weight: .bold))
                Text("· not recording").font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            Spacer()
            Button(action: model.openSettings) { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help("Settings… ⌘,")
        }
    }

    @ViewBuilder private var nextCard: some View {
        if let n = model.next {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Up next · \(n.startsAt, style: .relative) · \(n.startsAt, style: .time)")
                        .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    Spacer()
                    PNBadge(text: n.ready ? "Ready" : "Not prepared", kind: n.ready ? .ready : .notPrepared)
                }
                Text(n.title).font(.system(size: 15, weight: .semibold))
                Text(n.note).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                HStack(spacing: 8) {
                    Button("Start tips", action: model.startTips).buttonStyle(.pnPrimary)
                    Button(n.ready ? "Open brief" : "Prepare", action: n.ready ? model.openBrief : model.prepareNext).buttonStyle(.pnSecondary)
                }.padding(.top, 6)
            }
            .padding(12)
            .background(PN.C.surface, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var laterList: some View {
        VStack(spacing: 2) {
            ForEach(model.later) { c in
                HStack(spacing: 10) {
                    Text(c.time).font(PN.Font.caption).foregroundStyle(PN.C.text3).frame(width: 42, alignment: .leading)
                    Text(c.title).font(PN.Font.body).lineLimit(1)
                    Spacer()
                    PNBadge(text: c.badge, kind: c.ready ? .ready : .notPrepared)
                }.padding(.horizontal, 8)
            }
        }
    }

    private var liveCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.liveTitle).font(.system(size: 15, weight: .semibold))
            Text(model.liveAgendaLine).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            HStack(spacing: 8) {
                Button("Show tips", action: model.showTips).buttonStyle(.pnPrimary)
                Button("Pause", action: model.togglePause).buttonStyle(.pnSecondary)
                Button("End call", role: .destructive, action: model.endCall).buttonStyle(.pnSecondary)
            }.padding(.top, 6)
        }
        .padding(12)
        .background(PN.C.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    private var onMeList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ON ME · \(model.onMe.count)").font(PN.Font.label).foregroundStyle(PN.C.onMe)
            ForEach(model.onMe, id: \.self) { Text($0).font(PN.Font.body) }
        }.padding(.horizontal, 8)
    }

    private var spend: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("This month").font(PN.Font.caption).foregroundStyle(PN.C.text2)
                Spacer()
                Text("$\(model.monthSpend, specifier: "%.2f") of $\(Int(model.monthCap))").font(PN.Font.caption).monospacedDigit()
            }
            ProgressView(value: min(model.monthSpend / max(model.monthCap, 1), 1)).tint(PN.C.brand)
            Text(model.lastCallLine).font(PN.Font.caption).foregroundStyle(PN.C.text3)
        }.padding(.horizontal, 8)
    }

    private var footer: some View {
        HStack {
            if model.isRecording {
                Text("This call $\(model.thisCallSpend, specifier: "%.2f")").font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            Menu("Help and About") {
                Button("Setup…", action: model.openSetup)
                Button("Welcome tour", action: model.openWelcomeTour)
                Divider()
                Button("About Pacenote", action: model.openAbout)
            }.menuStyle(.borderlessButton).fixedSize()
            Spacer()
            if !model.isRecording {
                Button("Quit Pacenote") { NSApp.terminate(nil) }.buttonStyle(.borderless).keyboardShortcut("q")
            }
        }.font(PN.Font.body)
    }

    private func row(_ title: String, _ key: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { Text(title); Spacer(); Text(key).foregroundStyle(PN.C.text3) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless).foregroundStyle(PN.C.text)
        .padding(.horizontal, 8).frame(height: 28)
    }
}
