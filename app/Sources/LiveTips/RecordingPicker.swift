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
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 500), styleMask: [.titled, .closable, .nonactivatingPanel],
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

extension RecordingPicker {
    private static var flashWindow: NSWindow?

    /// 2026-11-05 (owner): "Show on screen": a blue frame with the name around the real window or screen for a moment,
    /// to tell two similar windows apart. The frame itself is never recorded (sharingType none).
    @MainActor static func flash(_ src: RecSource, windows: [RecTargets.Window], label: String) {
        guard let primary = NSScreen.screens.first else { return }
        var r: NSRect
        switch src {
        case .window(let id):
            guard let w = windows.first(where: { $0.id == id }), w.frame.width > 0 else { return }
            r = NSRect(x: w.frame.minX, y: primary.frame.maxY - w.frame.maxY, width: w.frame.width, height: w.frame.height)
        case .display(let id):
            guard let s = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }) else { return }
            r = s.frame.insetBy(dx: 8, dy: 8)
        case .soundOnly: return
        }
        r = r.insetBy(dx: -5, dy: -5)
        r.size.height += 28                     // room for the name above the frame
        flashWindow?.orderOut(nil)
        let w = NSWindow(contentRect: r, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
        w.level = .screenSaver; w.ignoresMouseEvents = true; w.sharingType = .none
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.contentView = NSHostingView(rootView: FlashFrame(label: label))
        w.alphaValue = 0
        w.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; w.animator().alphaValue = 1 }
        flashWindow = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard flashWindow === w else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; w.animator().alphaValue = 0 }, completionHandler: { w.orderOut(nil) })
        }
    }
}

private struct FlashFrame: View {
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(PN.C.accentFill, in: RoundedRectangle(cornerRadius: 6))
            RoundedRectangle(cornerRadius: 10).stroke(PN.C.accentFill, lineWidth: 4)
                .background(RoundedRectangle(cornerRadius: 10).fill(PN.C.accentFill.opacity(0.08)))
                .shadow(color: PN.C.accentFill.opacity(0.35), radius: 6)
        }
    }
}

/// 2026-11-05 (owner): the list on the left (Windows / Screens), on the right a picture of exactly what will be
/// recorded with its size, and Show on screen.
struct RecordingPickerView: View {
    let windows: [RecTargets.Window]
    let displays: [RecTargets.Display]
    @State var selected: String
    let done: ((RecSource, String)?) -> Void
    @State private var tab = "windows"
    @State private var preview: CGImage?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("", selection: $tab) {
                        Text(L("rec.pick.windows")).tag("windows")
                        Text(L("rec.pick.screens")).tag("screens")
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                    ScrollView {
                        VStack(spacing: 2) {
                            if tab == "windows" {
                                if windows.isEmpty { Text(L("rec.pick.noWindows")).font(PN.Font.body).foregroundStyle(PN.C.text3).padding(12) }
                                ForEach(windows) { w in
                                    row("w\(w.id)", icon: AnyView(Image(nsImage: NSRunningApplication(processIdentifier: w.pid)?.icon ?? NSImage()).resizable().frame(width: 26, height: 26)),
                                        title: w.app, sub: w.title, call: MeetingWindow.score(.init(id: w.id, bundle: w.bundle, app: w.app, title: w.title, width: w.width, height: w.height)) > 0)
                                }
                            } else {
                                ForEach(displays) { d in
                                    row("d\(d.id)", icon: AnyView(Image(systemName: "display").font(.system(size: 18)).foregroundStyle(PN.C.accent).frame(width: 26, height: 26)),
                                        title: d.name, sub: d.main ? L("rec.display.main") : "", call: false)
                                }
                            }
                        }
                        .padding(6)
                    }
                    .background(RoundedRectangle(cornerRadius: 12).fill(PN.C.surface))
                }
                .frame(width: 300)
                previewPane
            }
            .padding(16)
            HStack(spacing: 8) {
                Text(L("rec.pick.body")).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(2)
                Spacer()
                Button(L("common.cancel")) { done(nil) }.keyboardShortcut(.cancelAction).buttonStyle(.pnSecondary)
                Button(L("rec.pick.record")) { done(choice) }.keyboardShortcut(.defaultAction).buttonStyle(.pnPrimary).disabled(choice == nil)
            }
            .padding(.horizontal, 16).padding(.bottom, 16)
        }
        .frame(width: 760, height: 500)
        .background(PN.C.bg)
        .onAppear {
            if selected.isEmpty { selected = windows.first.map { "w\($0.id)" } ?? displays.first.map { "d\($0.id)" } ?? "" }
            if selected.hasPrefix("d") { tab = "screens" }
            load()
        }
        .onChange(of: selected) { _, _ in load() }
    }

    private func row(_ tag: String, icon: AnyView, title: String, sub: String, call: Bool) -> some View {
        let on = selected == tag
        return Button { selected = tag } label: {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(PN.Font.body.weight(.medium)).foregroundStyle(PN.C.text).lineLimit(1)
                    if !sub.isEmpty { Text(sub).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(1) }
                }
                Spacer(minLength: 4)
                if call {
                    Text(L("rec.pick.call")).font(.system(size: 11, weight: .semibold)).foregroundStyle(PN.C.turn)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(PN.C.turn.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? PN.C.accent.opacity(0.10) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? PN.C.accent : Color.clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(PN.C.surface2)
                if let p = preview {
                    Image(decorative: p, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(PN.C.accent, lineWidth: 2))
                        .padding(6)
                } else if loading {
                    ProgressView().controlSize(.small)
                } else {
                    Text(L("rec.pick.noPreview")).font(PN.Font.caption).foregroundStyle(PN.C.text3).multilineTextAlignment(.center).padding(20)
                }
            }
            .frame(maxWidth: .infinity).frame(height: 260)
            if let c = choice {
                Text(c.1).font(PN.Font.body.weight(.semibold)).foregroundStyle(PN.C.text).lineLimit(2)
                Text(detail).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                Button { RecordingPicker.flash(c.0, windows: windows, label: c.1) } label: { Label(L("rec.pick.show"), systemImage: "viewfinder") }
                    .buttonStyle(.pnSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(PN.C.surface))
    }

    private var detail: String {
        if selected.hasPrefix("w"), let id = UInt32(selected.dropFirst()), let w = windows.first(where: { $0.id == id }) {
            return "\(Int(w.width)) × \(Int(w.height)) · " + L("rec.pick.covered")
        }
        if selected.hasPrefix("d"), let id = UInt32(selected.dropFirst()) {
            return "\(CGDisplayPixelsWide(id)) × \(CGDisplayPixelsHigh(id)) · " + L("rec.pick.ownHidden")
        }
        return ""
    }

    private func load() {
        guard let c = choice else { preview = nil; return }
        loading = true; preview = nil
        let want = selected
        Task { @MainActor in
            let img = await RecTargets.thumbnail(c.0, width: 760)
            if selected == want { preview = img; loading = false }
        }
    }

    var choice: (RecSource, String)? {
        if selected.hasPrefix("w"), let id = UInt32(selected.dropFirst()), let w = windows.first(where: { $0.id == id }) { return (.window(id), w.label) }
        if selected.hasPrefix("d"), let id = UInt32(selected.dropFirst()), let d = displays.first(where: { $0.id == id }) { return (.display(id), d.name) }
        return nil
    }
}
