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
            let linked = meta.parts.first { !$0.driveLink.isEmpty }
            let link = linked?.driveLink
            let linkAccount = (linked?.driveAccount).flatMap { $0.isEmpty ? nil : $0 } ?? drive.account
            let gone = meta.parts.contains { $0.driveError == RecordingMeta.Part.folderUnavailable }
            // 0.25 (R2, board SL): one status line under the title: what the recording is, its problem, its actions
            let problem: String? = gone && !uploading ? L("rec.drive.folderGone")
                : (drive.errors[file] ?? meta.parts.first(where: { !$0.driveError.isEmpty })?.driveError).flatMap { uploading ? nil : L("rec.drive.failed", ["err": $0]) }
            PageStatusLine(key: L("rec.page.title"), kind: problem == nil ? .ready : .notReady,
                           value: problem.map { _ in L("rec.line.notUploaded") } ?? summary(meta),
                           sub: problem ?? (drive.progress[file] ?? "")) {
                PageLineLink(L("rec.page.play")) { if let p = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) { NSWorkspace.shared.open(URL(fileURLWithPath: p)) } }
                PageLineLink(L("home.recent.finder")) { NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) }) }
                if let l = link { PageLineLink(L("rec.page.openDrive")) { MeetingLauncher.shared.openGoogle(l, account: linkAccount) } }
                if let l = drive.transcriptLink(file) { PageLineLink(L("rec.page.openTranscript")) { MeetingLauncher.shared.openGoogle(l, account: drive.transcriptAccount(file)) } }
                if gone && !uploading && !(rec.isActive && rec.transcript == file) {
                    Button(L("rec.drive.newFolder")) { drive.recreateFolder(transcript: file); tick += 1 }
                        .buttonStyle(.pnRow).help(L("rec.drive.newFolder.help"))
                } else if !meta.notUploaded.isEmpty && !(rec.isActive && rec.transcript == file) {
                    Button(uploading ? L("rec.page.uploading") : L("rec.page.upload")) { drive.upload(transcript: file); tick += 1 }
                        .buttonStyle(.pnRow).disabled(uploading)
                        .help(drive.account.map { L("rec.page.uploadTo", ["email": $0]) } ?? L("rec.drive.noAccount"))
                }
            }
            .onReceive(drive.objectWillChange) { _ in DispatchQueue.main.async { tick += 1 } }
        } else if let l = drive.transcriptLink(file) {
            // 0.11.0 (B7b): a call without a recording whose transcript is in Drive ("For every call").
            PageStatusLine(key: L("rec.page.title"), kind: .neutral, value: L("rec.page.transcriptInDrive")) {
                PageLineLink(L("rec.page.openTranscript")) { MeetingLauncher.shared.openGoogle(l, account: drive.transcriptAccount(file)) }
            }
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
