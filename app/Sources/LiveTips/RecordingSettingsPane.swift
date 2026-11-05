import AppKit
import SwiftUI
import LiveTipsCore

/// 0.9.5 (owner): Settings > Call recording. Everything about recording calls on one page: on by default for every call
/// or chosen per call, sound or sound and screen, the quality with what an hour takes, the screen or the window, Google
/// Drive, the macOS permission and the consent message.
struct RecordingSettingsPane: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var google = GoogleService.shared
    @State private var permission = ScreenPermission.granted()
    @State private var displays = RecTargets.displays()

    private var r: Binding<RecordingSettings> { $model.config.recording }
    private var accounts: [GoogleAccount] { google.accounts.filter { $0.has(GoogleScopes.export) } }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: r.auto) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("rec.set.auto"))
                        Text(L("rec.set.auto.sub")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Picker(L("rec.set.kind"), selection: r.kind) {
                    Text(L("rec.kind.audio")).tag("audio")
                    Text(L("rec.kind.video")).tag("video")
                }
                Toggle(L("rec.set.mic"), isOn: r.mic)
            } header: { Text(L("rec.set.what")) } footer: {
                Text(L("rec.set.where")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }

            if model.config.recording.kind == "video" {
                Section {
                    Picker(L("rec.set.source"), selection: r.source) {
                        Text(L("rec.source.display")).tag("display")
                        Text(L("rec.source.window")).tag("window")
                    }
                    if model.config.recording.source == "display" {
                        Picker(L("rec.set.display"), selection: r.display) {
                            Text(L("rec.display.main")).tag("")
                            ForEach(displays) { d in Text(d.name).tag(d.uuid) }
                            if !model.config.recording.display.isEmpty && !displays.contains(where: { $0.uuid == model.config.recording.display }) {
                                Text(L("rec.display.gone")).tag(model.config.recording.display)
                            }
                        }
                        Text(L("rec.set.display.sub")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Picker(L("rec.set.windowPick"), selection: r.windowPick) {
                            Text(L("rec.windowPick.ask")).tag("ask")
                            Text(L("rec.windowPick.auto")).tag("auto")
                        }
                        Text(L("rec.set.window.sub")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                    }
                } header: { Text(L("rec.set.picture")) }

                Section {
                    Picker(L("rec.set.quality"), selection: r.quality) {
                        ForEach(RecordingPreset.all, id: \.id) { p in
                            Text(L("rec.quality." + p.id) + " (\(p.maxWidth) px) · " + L("rec.perHour", ["mb": Self.size(p.mbPerHour(model.config.recording.codec))])).tag(p.id)
                        }
                    }
                    Picker(L("rec.set.codec"), selection: r.codec) {
                        Text(L("rec.codec.h264")).tag("h264")
                        Text(L("rec.codec.hevc")).tag("hevc")
                    }
                } header: { Text(L("rec.set.qualityHead")) }
            } else {
                Section {
                    Text(L("rec.set.audioSize", ["mb": Self.size(RecordingPreset.audioMBPerHour)]))
                        .font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                Picker(L("rec.set.drive"), selection: r.drive) {
                    Text(L("rec.drive.manual")).tag("manual")
                    Text(L("rec.drive.auto")).tag("auto")
                }
                if accounts.isEmpty {
                    HStack {
                        Text(L("rec.drive.connect")).font(PN.Font.caption).foregroundStyle(PN.C.onMe)
                        Spacer()
                        Button(L("rec.drive.connectButton")) { SettingsWindow.show(tab: "google") }.buttonStyle(.pnTertiary)
                    }
                } else {
                    Picker(L("rec.set.driveAccount"), selection: r.driveAccount) {
                        Text(L("rec.drive.firstAccount", ["email": accounts[0].email])).tag("")
                        ForEach(accounts, id: \.email) { a in Text(a.email).tag(a.email) }
                    }
                }
            } header: { Text("Google Drive") } footer: {
                Text(L("rec.set.drive.sub")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            }

            Section {
                HStack {
                    Image(systemName: permission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(permission ? PN.C.turn : PN.C.onMe)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("rec.set.permission"))
                        Text(L(permission ? "rec.set.permission.on" : "rec.set.permission.off")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if !permission {
                        Button(L("rec.set.permission.allow")) {
                            if !ScreenPermission.request() { ScreenPermission.openSettings() }
                            permission = ScreenPermission.granted()
                        }
                    }
                }
                HStack {
                    Text(L("rec.set.consent")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(L("rec.set.consent.open")) { model.tab = "general" }.buttonStyle(.pnTertiary)
                }
            } header: { Text(L("rec.set.privacy")) }
        }
        .formStyle(.grouped)
        .onAppear { permission = ScreenPermission.granted(); displays = RecTargets.displays() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in permission = ScreenPermission.granted() }
    }

    static func size(_ mb: Int) -> String { mb >= 1000 ? String(format: "%.1f GB", Double(mb) / 1000) : "\(mb) MB" }
}
