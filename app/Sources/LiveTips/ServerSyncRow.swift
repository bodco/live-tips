import SwiftUI
import LiveTipsCore

/// 0.12.1 (B8): the call page's line about the call's copy on the Pacenote server. Shown only when the call's project
/// has "Sync to Pacenote server" on and the PM is signed in; says synced (when), syncing, waiting, the error with Retry,
/// skipped for this call, or deleted on another device (never sent again by itself).
struct ServerSyncRow: View {
    let file: String
    @ObservedObject private var sync = CallSyncService.shared

    var body: some View {
        if let s = sync.status(file) {
            HStack(spacing: 8) {
                Image(systemName: icon(s)).foregroundStyle(warn(s) ? PN.C.onMe : PN.C.text3)
                Text(text(s)).font(PN.Font.caption).foregroundStyle(warn(s) ? PN.C.onMe : PN.C.text3).lineLimit(2)
                Spacer()
                switch s {
                case .failed, .waiting:
                    Button(L("sync.page.retry")) { sync.sync(file) }.buttonStyle(.pnTertiary)
                case .skipped:
                    Button(L("sync.call.allow")) { sync.setSkip(false, transcript: file) }.buttonStyle(.pnTertiary)
                default:
                    EmptyView()
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func warn(_ s: CallSync.Status) -> Bool { if case .failed = s { return true }; return false }

    private func icon(_ s: CallSync.Status) -> String {
        switch s {
        case .synced: return "checkmark.icloud"
        case .syncing: return "arrow.triangle.2.circlepath.icloud"
        case .waiting: return "icloud"
        case .failed: return "exclamationmark.icloud"
        case .skipped: return "icloud.slash"
        case .deletedElsewhere: return "trash.slash"
        case .removed: return "trash"
        }
    }

    private func text(_ s: CallSync.Status) -> String {
        switch s {
        case .synced(let d):
            let f = DateFormatter(); f.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US")
            f.setLocalizedDateFormatFromTemplate(Calendar.current.isDateInToday(d) ? "HHmm" : "dMMMHHmm")
            return L("sync.page.synced", ["when": f.string(from: d)])
        case .syncing: return L("sync.page.syncing")
        case .waiting: return L("sync.page.waiting")
        case .failed(let e): return L("sync.page.failed", ["err": e])
        case .skipped: return L("sync.page.skipped")
        case .deletedElsewhere: return L("sync.page.deleted")
        case .removed: return L("sync.page.removed")
        }
    }
}
