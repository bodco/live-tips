import AppKit
import SwiftUI
import LiveTipsCore

/// 0.9.5: the call page's recording line: how long, how big, Play, Show in Finder and the Google Drive copy.
/// Found by itself from the transcript's name (<project>/video/<stem>.recording.json).
struct RecordingRow: View {
    let file: String
    @ObservedObject private var drive = DriveRecordings.shared
    @ObservedObject private var rec = CallRecorder.shared
    @State private var tick = 0

    var body: some View {
        let _ = tick
        if let meta = RecordingMeta.load(RecordingFiles.metaPath(transcript: file)), !meta.parts.isEmpty {
            let folder = RecordingFiles.folder(transcript: file)
            let paths = meta.parts.map { (folder as NSString).appendingPathComponent($0.file) }
            let uploading = drive.isUploading(file)
            let link = meta.parts.compactMap { $0.driveLink.isEmpty ? nil : $0.driveLink }.first
            let gone = meta.parts.contains { $0.driveError == RecordingMeta.Part.folderUnavailable }
            HStack(spacing: 8) {
                Image(systemName: meta.parts.contains { $0.kind == "video" } ? "video" : "waveform").foregroundStyle(PN.C.text3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("rec.page.title")).font(PN.Font.body.weight(.semibold)).foregroundStyle(PN.C.text)
                    Text(summary(meta)).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    if let p = drive.progress[file] { Text(p).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
                    if gone && !uploading {
                        Text(L("rec.drive.folderGone")).font(PN.Font.caption).foregroundStyle(PN.C.onMe).lineLimit(2)
                    } else if let e = drive.errors[file] ?? meta.parts.first(where: { !$0.driveError.isEmpty })?.driveError, !uploading {
                        Text(L("rec.drive.failed", ["err": e])).font(PN.Font.caption).foregroundStyle(PN.C.onMe).lineLimit(2)
                    }
                }
                Spacer()
                Button(L("rec.page.play")) { if let p = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) { NSWorkspace.shared.open(URL(fileURLWithPath: p)) } }
                    .buttonStyle(.pnSecondary)
                Button(L("home.recent.finder")) { NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) }) }
                    .buttonStyle(.pnTertiary)
                if gone && !uploading && !(rec.isActive && rec.transcript == file) {
                    Button(L("rec.drive.newFolder")) { drive.recreateFolder(transcript: file); tick += 1 }
                        .buttonStyle(.pnSecondary).help(L("rec.drive.newFolder.help"))
                } else if !meta.notUploaded.isEmpty && !(rec.isActive && rec.transcript == file) {
                    Button(uploading ? L("rec.page.uploading") : L("rec.page.upload")) { drive.upload(transcript: file); tick += 1 }
                        .buttonStyle(.pnSecondary).disabled(uploading)
                        .help(drive.account.map { L("rec.page.uploadTo", ["email": $0]) } ?? L("rec.drive.noAccount"))
                }
                if let l = link, let u = URL(string: l) {
                    Button(L("rec.page.openDrive")) { NSWorkspace.shared.open(u) }.buttonStyle(.pnTertiary)
                }
                if let l = drive.transcriptLink(file), let u = URL(string: l) {
                    Button(L("rec.page.openTranscript")) { NSWorkspace.shared.open(u) }.buttonStyle(.pnTertiary)
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 14)          // the call page's cards (PageCard), one line high
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PageStyle.radius))
            .onReceive(drive.objectWillChange) { _ in DispatchQueue.main.async { tick += 1 } }
        } else if let l = drive.transcriptLink(file), let u = URL(string: l) {
            // 0.11.0 (B7b): a call without a recording whose transcript is in Drive ("For every call").
            HStack(spacing: 8) {
                Image(systemName: "doc.text").foregroundStyle(PN.C.text3)
                Text(L("rec.page.transcriptInDrive")).font(PN.Font.body.weight(.semibold)).foregroundStyle(PN.C.text)
                Spacer()
                Button(L("rec.page.openTranscript")) { NSWorkspace.shared.open(u) }.buttonStyle(.pnTertiary)
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PageStyle.radius))
            .onReceive(drive.objectWillChange) { _ in DispatchQueue.main.async { tick += 1 } }
        }
    }

    private func summary(_ m: RecordingMeta) -> String {
        let min = max(1, Int((m.totalSeconds / 60).rounded()))
        let mb = Double(m.totalBytes) / 1_000_000
        let size = mb >= 1000 ? String(format: "%.1f GB", mb / 1000) : "\(Int(mb.rounded())) MB"
        let kind = m.parts.contains { $0.kind == "video" } ? L("rec.kind.video") : L("rec.kind.audio")
        var s = [L("call.page.minutes", ["n": "\(min)"]), size, kind]
        if m.parts.count > 1 { s.append(L("rec.page.parts", ["n": "\(m.parts.count)"])) }
        if m.notUploaded.isEmpty { s.append(L("rec.page.inDrive")) }
        return s.joined(separator: " · ")
    }
}
