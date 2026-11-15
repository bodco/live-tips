import AppKit
import SwiftUI
import LiveTipsCore

/// 0.9.5 (owner): Settings > Call recording. Everything about recording calls on one page: on by default for every call
/// or chosen per call, sound or sound and screen, the quality with what an hour takes, the screen or the window, Google
/// Drive, the macOS permission and the consent message.
struct RecordingSettingsPane: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var google = GoogleService.shared
    @ObservedObject private var drive = DriveRecordings.shared
    @ObservedObject private var pacenote = PacenoteAccount.shared
    @State private var confirmDefault = false
    @State private var permission = ScreenPermission.granted()
    @State private var displays = RecTargets.displays()

    private var r: Binding<RecordingSettings> { $model.config.recording }
    private var accounts: [GoogleAccount] { Self.shotAccounts ?? google.accounts.filter { $0.has(GoogleScopes.export) } }
    /// 0.11.0 (smoke shots): demo Google accounts instead of the real ones.
    nonisolated(unsafe) static var shotAccounts: [GoogleAccount]?
    /// The account the recordings go to (Settings' choice, else the first one).
    private var driveAccount: String? {
        accounts.first { $0.email == model.config.recording.driveAccount }?.email ?? accounts.first?.email
    }

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
            } header: { Text(L("rec.set.what")).settingsAnchor("rec.what") } footer: {
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
                    if let a = driveAccount { folderRow(a) }
                    transcriptRow
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
            } header: { Text(L("rec.set.privacy")).settingsAnchor("rec.privacy") }
            // 0.15.0 (D2): the consent message lives here now (was General)
            ConsentSection(model: model)
        }
        .formStyle(.grouped)
        .onAppear {
            permission = ScreenPermission.granted(); displays = RecTargets.displays()
            if let a = driveAccount { drive.refreshRoot(account: a) }
        }
        .onChange(of: model.config.recording.driveAccount) { _, _ in if let a = driveAccount { drive.refreshRoot(account: a) } }
        .confirmationDialog(L("rec.set.folder.defaultAsk"), isPresented: $confirmDefault) {
            Button(L("rec.set.folder.default")) { if let a = driveAccount { drive.useDefault(account: a) } }
            Button(L("common.cancel"), role: .cancel) {}
        } message: { Text(L("rec.set.folder.defaultAsk.sub")) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in permission = ScreenPermission.granted() }
    }

    /// 0.11.0 (B7b, server ADR 3.7): where the recordings go. Pacenote makes My Drive > Pacenote; the PM moves or shares
    /// that folder in Drive (to a shared drive, to a lead) and Pacenote goes on writing into it by its id.
    @ViewBuilder private func folderRow(_ a: String) -> some View {
        let root = drive.store.account(a).root
        let gone = drive.rootState[a.lowercased()] == .unavailable
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(L("rec.set.folder"))
                    if let r = root, !r.driveId.isEmpty {
                        Text(L("rec.set.folder.shared")).font(PN.Font.caption).foregroundStyle(PN.C.text2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(PN.C.surface2, in: Capsule())
                    }
                }
                Text(root.map { L("rec.set.folder.saved", ["name": $0.name.isEmpty ? DriveFolderStore.rootName : $0.name]) } ?? L("rec.set.folder.none"))
                    .font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                if gone {
                    Text(L("rec.drive.folderGone")).font(PN.Font.caption).foregroundStyle(PN.C.onMe).fixedSize(horizontal: false, vertical: true)
                }
                if let e = drive.errors["settings"] {
                    Text(e).font(PN.Font.caption).foregroundStyle(PN.C.onMe).lineLimit(2)
                }
            }
            Spacer()
            if gone {
                Button(L("rec.drive.newFolder")) { drive.recreateRoot(account: a) }.buttonStyle(.pnSecondary)
            } else {
                Button(L("rec.set.folder.open")) { drive.openRoot(account: a) }.buttonStyle(.pnTertiary)
            }
            if root != nil {
                Button(L("rec.set.folder.default")) { confirmDefault = true }.buttonStyle(.pnTertiary)
            }
        }
        Text(L("rec.set.folder.sub")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
    }

    /// 0.11.0 (B7b, server ADR 3.4): the call's transcript as .md next to the video. An organization can require it.
    @ViewBuilder private var transcriptRow: some View {
        let org = pacenote.me?.transcriptRequiredBy
        Picker(L("rec.set.transcript"), selection: org == nil ? r.transcriptDrive : .constant(TranscriptInDrive.everyCall.rawValue)) {
            Text(L("rec.transcript.off")).tag(TranscriptInDrive.off.rawValue)
            Text(L("rec.transcript.withRecording")).tag(TranscriptInDrive.withRecording.rawValue)
            Text(L("rec.transcript.everyCall")).tag(TranscriptInDrive.everyCall.rawValue)
        }
        .disabled(org != nil)
        Text(org.map { L("rec.set.transcript.required", ["org": $0]) } ?? L("rec.set.transcript.sub"))
            .font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
    }

    static func size(_ mb: Int) -> String { mb >= 1000 ? String(format: "%.1f GB", Double(mb) / 1000) : "\(mb) MB" }
}
