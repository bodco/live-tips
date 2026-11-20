import Foundation
import SwiftUI
import LiveTipsCore

/// Pacenote 0.26.2 (speakers on the call page, B3): Rewrite notes. A speaker change only marks the notes as out of date
/// (the owner's rule: the notes are written again by AI on a button, never by a text swap). One per call file, so the
/// running rewrite survives leaving the page and both the Transcript and the Meeting notes tabs show the same state.
@MainActor
final class NotesRewrite: ObservableObject {
    private static var all: [String: NotesRewrite] = [:]
    static func of(_ file: String) -> NotesRewrite {
        if let r = all[file] { return r }
        let r = NotesRewrite(file: file); all[file] = r; return r
    }
    /// Posted with the file as object when new notes are on disk (the pages read them again).
    static let finished = Notification.Name("pacenote.notesRewritten")

    let file: String
    @Published private(set) var running = false
    @Published private(set) var failed: String? = nil
    init(file: String) { self.file = file }

    /// The PM changed the speakers after the notes were written (speakers.json edited_at newer than <stem>.notes.md).
    static func stale(_ file: String) -> Bool {
        let snap = FileManager.default.contents(atPath: CallLayout.sidecar(of: file, ".speakers.json"))
            .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        let notes = (try? FileManager.default.attributesOfItem(atPath: CallNotes.path(file)))?[.modificationDate] as? Date
        return CallSpeakers.notesStale(editedAt: CallSpeakers.editedAt(snapshot: snap), notesWritten: notes)
    }

    func start() {
        guard !running else { return }
        running = true; failed = nil
        CallEngine.shared.rewriteCallNotes(file: file) { [weak self] err in
            guard let self else { return }
            self.running = false
            self.failed = err
            if err == nil { NotificationCenter.default.post(name: Self.finished, object: self.file) }
        }
    }
}

/// The bar under the page header when the notes are out of date: what happened, Rewrite notes, its progress and error.
/// Shown only after the call (while it records, the recorder owns the speakers).
struct NotesStaleBar: View {
    let file: String
    @ObservedObject var job: NotesRewrite
    @Environment(\.pnTheme) private var t

    init(file: String) { self.file = file; job = NotesRewrite.of(file) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L(job.running ? "transcript.spk.rewriting" : "transcript.spk.stale"))
                .font(t.homeText(13)).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                if job.running {
                    PNSpinner(size: 18)
                } else {
                    HomeLink(L(job.failed == nil ? "transcript.spk.rewrite" : "transcript.spk.rewriteAgain"), size: 13) { job.start() }
                        .help(L("transcript.spk.rewriteHelp"))
                }
            }
            if let f = job.failed {
                Text(f).font(t.homeText(13)).foregroundStyle(PN.C.notreadyText).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
