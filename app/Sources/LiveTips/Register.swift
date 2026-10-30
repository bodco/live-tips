import AppKit
import LiveTipsCore

/// Pacenote 0.8 (F5, idea 01): the commitments register for Home and the windows. The file format and the fold
/// live in LiveTipsCore (CommitmentRegister, rules/commitments.yaml); this reads every project's live folder,
/// caches by file date and writes the PM's ticks. Nothing leaves the Mac.
@MainActor
final class Register: ObservableObject {
    static let shared = Register()
    @Published private(set) var version = 0
    private var cache: [String: (Date, [Commitment])] = [:]

    /// The live folders of every active project and workspace (each once).
    var folders: [String] {
        let reg = ProjectRegistry.load(from: AppPaths.projects)
        var roots = reg.projects.filter { $0.status != "archived" && !$0.root.isEmpty }.map { $0.root }
        roots += reg.workspaces.map { $0.root }
        var seen = Set<String>(), out: [String] = []
        for r in roots {
            let f = (r as NSString).appendingPathComponent("live")
            if seen.insert(f).inserted { out.append(f) }
        }
        return out
    }

    func items(in folder: String) -> [Commitment] {
        let p = CommitmentRegister.path(folder: folder)
        let m = ((try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date) ?? .distantPast
        if let c = cache[folder], c.0 == m { return c.1 }
        let items = m == .distantPast ? [] : CommitmentRegister.load(folder: folder)
        cache[folder] = (m, items)
        return items
    }

    /// Open items, sorted by rules/commitments.yaml > order. `mine`: nil both, true the PM's, false on them.
    func open(mine: Bool? = true, folder: String? = nil, series: String? = nil) -> [Commitment] {
        let all = (folder.map { [$0] } ?? folders).flatMap { items(in: $0) }
        var seen = Set<String>()
        let open = all.filter { c in
            c.status == "open" && (mine == nil || c.mine == mine!) && (series == nil || c.series == series!) && seen.insert(c.id).inserted
        }
        return CommitmentRegister.sorted(open)
    }

    func mark(_ c: Commitment, _ op: String = "done", source: String = "manual", call: String = "") {
        CommitmentRegister.mark(folder: c.folder, id: c.id, op: op, source: source, call: call)
        cache[c.folder] = nil
        version += 1
    }

    /// The register next to a call's transcript, for the tips window (Mark done on a "Done?" card).
    func markDone(id: String, callFile: String) {
        let folder = (callFile as NSString).deletingLastPathComponent
        CommitmentRegister.mark(folder: folder, id: id, op: "done", source: "detected", call: callFile)
        cache[folder] = nil
        version += 1
    }

    /// 0.8.6: the file changed outside mark() (link, unlink): read it again.
    func touch(_ folder: String) {
        cache[folder] = nil
        version += 1
    }

    /// 0.8.6: the call's title for "From the call <title>" (the history's title, else the file name).
    func callTitle(_ c: Commitment) -> String? {
        let key = CommitmentRegister.callKey(c.call)
        return CallHistory.shared.visible.first { CommitmentRegister.callKey($0.file) == key }?.title
    }

    /// The project's display name for a register item.
    func projectName(_ c: Commitment) -> String {
        let reg = ProjectRegistry.load(from: AppPaths.projects)
        if let p = reg.projects.first(where: { $0.slug == c.project }) { return p.name }
        if let w = reg.workspaces.first(where: { $0.name.lowercased() == c.project.lowercased() }) { return w.name }
        return c.project
    }

    /// The transcript the item came from, when it is still there.
    func transcript(_ c: Commitment) -> String? {
        let p = (c.folder as NSString).appendingPathComponent(c.call)
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    /// The due date as people say it: an ISO date becomes "27 Oct"; free text ("Friday") stays as it is.
    nonisolated static func dueText(_ due: String) -> String {
        guard due.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil else { return due }
        let i = DateFormatter(); i.dateFormat = "yyyy-MM-dd"; i.locale = Locale(identifier: "en_US_POSIX")
        guard let d = i.date(from: due) else { return due }
        let o = DateFormatter(); o.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US"); o.setLocalizedDateFormatFromTemplate("dMMM")
        return o.string(from: d)
    }

    func copyText(_ c: Commitment) {
        var s = c.mine ? c.text : c.owner + ": " + c.text
        if !c.due.isEmpty { s += " (" + Self.dueText(c.due) + ")" }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    /// One time, when 0.8 first runs: what the PM took on in the calls of the last two weeks (read from their call
    /// picture until now) goes into the register, so On you keeps its items. Ticks made on Home before stay closed.
    func importOnce() {
        guard !UserDefaults.standard.bool(forKey: "registerImported") else { return }
        UserDefaults.standard.set(true, forKey: "registerImported")
        let since = Date().addingTimeInterval(-14 * 86400)
        let ticked = Set(UserDefaults.standard.stringArray(forKey: "homeOnYouDone") ?? [])
        let reg = ProjectRegistry.load(from: AppPaths.projects)
        let f = ISO8601DateFormatter(); f.timeZone = .current
        for r in CallHistory.shared.visible where r.start > since {
            guard let o = CallOutcome.read(transcript: r.file), !o.onMe.isEmpty else { continue }
            let folder = (r.file as NSString).deletingLastPathComponent
            let have = CommitmentRegister.load(folder: folder)
            let slug = reg.projects.first { $0.name == r.project || $0.slug == r.project || ($0.root as NSString).lastPathComponent == r.project }?.slug ?? r.project
            var ev: [[String: Any]] = []
            for t in o.onMe {
                let id = CommitmentRegister.makeID(call: r.file, owner: "me", text: t)
                guard !have.contains(where: { $0.id == id || (CommitmentRegister.callKey($0.call) == CommitmentRegister.callKey(r.file) && CommitmentRegister.similar($0.text, t)) }) else { continue }
                ev.append(["op": "add", "id": id, "text": String(t.prefix(120)), "owner": "me", "project": slug,
                           "series": CommitmentRegister.seriesKey(project: slug, title: r.title), "call": (r.file as NSString).lastPathComponent,
                           "t": "", "created": f.string(from: r.start), "due": "", "by": "app"])
                if ticked.contains(r.file + "|" + t.lowercased().trimmingCharacters(in: .whitespaces)) {
                    ev.append(["op": "done", "id": id, "at": CommitmentRegister.nowISO(), "source": "manual"])
                }
            }
            CommitmentRegister.append(folder: folder, ev)
        }
        version += 1
    }
}
