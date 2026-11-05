import AppKit
import SwiftUI
import LiveTipsCore

/// 0.9.5: "What to record": the windows on screen (the call app's first) and the screens. Opens when a video recording
/// starts with Settings > Call recording > Window > Ask every time, and from the tips window's recording menu.
enum RecordingPicker {
    private static var panel: NSPanel?
    private static var onPick: (((RecSource, String)?) -> Void)?

    @MainActor static func show(windows: [RecTargets.Window], preselect: CGWindowID?, done: @escaping ((RecSource, String)?) -> Void) {
        close(nil)
        onPick = done
        let view = Localized { RecordingPickerView(windows: windows, displays: RecTargets.displays(), selected: preselect.map { "w\($0)" } ?? "") { close($0) } }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460), styleMask: [.titled, .closable, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.title = L("rec.pick.title")
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView: view)
        p.center()
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { _ in
            MainActor.assumeIsolated { if panel === p { panel = nil; let f = onPick; onPick = nil; f?(nil) } }
        }
        panel = p
    }

    @MainActor static func close(_ choice: (RecSource, String)?) {
        let f = onPick; onPick = nil
        let p = panel; panel = nil
        p?.close()
        f?(choice)
    }
}

struct RecordingPickerView: View {
    let windows: [RecTargets.Window]
    let displays: [RecTargets.Display]
    @State var selected: String
    let done: ((RecSource, String)?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("rec.pick.body")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            List(selection: Binding(get: { selected.isEmpty ? nil : selected }, set: { selected = $0 ?? "" })) {
                Section(L("rec.pick.windows")) {
                    if windows.isEmpty { Text(L("rec.pick.noWindows")).foregroundStyle(PN.C.text3) }
                    ForEach(windows) { w in
                        HStack(spacing: 8) {
                            Image(nsImage: NSRunningApplication(processIdentifier: w.pid)?.icon ?? NSImage()).resizable().frame(width: 20, height: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(w.app).font(PN.Font.body)
                                if !w.title.isEmpty { Text(w.title).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(1) }
                            }
                            Spacer()
                            if MeetingWindow.score(.init(id: w.id, bundle: w.bundle, app: w.app, title: w.title, width: w.width, height: w.height)) > 0 {
                                Text(L("rec.pick.call")).font(PN.Font.caption).foregroundStyle(PN.C.turn)
                            }
                        }
                        .tag("w\(w.id)")
                    }
                }
                Section(L("rec.pick.screens")) {
                    ForEach(displays) { d in
                        Label(d.name + (d.main ? " (" + L("rec.display.main") + ")" : ""), systemImage: "display").tag("d\(d.id)")
                    }
                }
            }
            .frame(minHeight: 300)
            HStack {
                Spacer()
                Button(L("common.cancel")) { done(nil) }.keyboardShortcut(.cancelAction)
                Button(L("rec.pick.record")) { done(choice) }.keyboardShortcut(.defaultAction).buttonStyle(.pnPrimary).disabled(choice == nil)
            }
        }
        .padding(18)
        .frame(width: 520, height: 460)
    }

    var choice: (RecSource, String)? {
        if selected.hasPrefix("w"), let id = UInt32(selected.dropFirst()), let w = windows.first(where: { $0.id == id }) { return (.window(id), w.label) }
        if selected.hasPrefix("d"), let id = UInt32(selected.dropFirst()), let d = displays.first(where: { $0.id == id }) { return (.display(id), d.name) }
        return nil
    }
}
