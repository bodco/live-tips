import AppKit
import SwiftUI
import LiveTipsCore

// Pacenote 0.8.7 (I3-I5, rules/crm.yaml): the call's link to the CRM, the snapshot <base>.crm.md that the preparation
// and the engine read, and Update <CRM> after the call: a review with checkboxes, Apply, Undo for 8 seconds.
// Nothing is written to the CRM without the PM's click.

/// <base>.crm.json: which company, deal and contacts this call is linked to (ids only, no key, no text).
struct CRMLink: Codable, Equatable {
    var provider = "hubspot"
    var companyId = "", companyName = ""
    var dealId = "", dealName = ""
    var contactIds: [String] = []

    static func url(base: String) -> URL { URL(fileURLWithPath: base + ".crm.json") }
    static func load(base: String) -> CRMLink? { (try? Data(contentsOf: url(base: base))).flatMap { try? JSONDecoder().decode(CRMLink.self, from: $0) } }
    func save(base: String) { if let d = try? JSONEncoder().encode(self) { try? d.write(to: Self.url(base: base), options: .atomic) } }
}

extension CRMService {
    /// The PM's own domains (from the name aliases' emails is not known): the domains of the calendar accounts.
    static var ownDomains: Set<String> {
        Set(CalendarService.shared.calendars.compactMap { c -> String? in
            let s = c.source.title.lowercased(); guard let at = s.lastIndex(of: "@") else { return nil }; return String(s[s.index(after: at)...]) })
    }

    /// 0.8.7 (I6.2): the user's own emails (calendar accounts), to pick the CRM owner.
    static var ownEmails: [String] {
        CalendarService.shared.calendars.map { $0.source.title.lowercased() }.filter { $0.contains("@") }
    }

    /// Finds the company (attendee domains, else the name), its freshest open deal and the contacts; keeps a link the
    /// PM chose. Writes <base>.crm.md and <base>.crm.json. Returns the link or an error line.
    func refresh(base: String, emails: [String], name: String, keep: CRMLink?) async -> (CRMLink?, String) {
        guard let c = connector() else { return (nil, L("crm.notConnected")) }
        do {
            var link = keep ?? CRMLink()
            var company: CRMCompany? = nil
            if !link.companyId.isEmpty { company = CRMCompany(id: link.companyId, name: link.companyName, domain: "") }
            if company == nil, SettingsWindow.model.config.crm.matchByDomain {   // 0.8.7 (I6.2): the toggle in Matching
                for d in CRMSnapshot.clientDomains(emails: emails, ownDomains: Self.ownDomains) {
                    if let co = try await c.findCompany(domain: d, name: "") { company = co; break }
                }
            }
            if company == nil, !name.isEmpty { company = try await c.findCompany(domain: "", name: name) }
            let contacts = try await c.findContacts(emails: emails)
            var deal: CRMDeal? = nil
            if link.dealId == "none" { deal = nil }
            else if !link.dealId.isEmpty { deal = try await c.deal(id: link.dealId) }
            else if let co = company { deal = try await c.deals(companyId: co.id).filter { $0.open }.max { $0.updated < $1.updated } }
            if let d = deal, d.stageName.isEmpty, let names = try? await c.pipelines() { deal?.stageName = names[d.stage] ?? "" }
            var refs: [CRMRef] = []
            if let d = deal { refs.append(CRMRef("deals", d.id)) } else if let co = company { refs.append(CRMRef("companies", co.id)) }
            let acts = (try? await c.recentActivity(refs: refs, limit: 10)) ?? []
            link.companyId = company?.id ?? ""; link.companyName = company?.name ?? ""
            if link.dealId != "none" { link.dealId = deal?.id ?? ""; link.dealName = deal?.name ?? "" }
            link.contactIds = contacts.map(\.id)
            let md = CRMSnapshot.render(provider: c.providerName, company: company, deal: deal, contacts: contacts, activity: acts, taken: Date())
            try? md.replacingOccurrences(of: "\u{2014}", with: "-").write(toFile: base + ".crm.md", atomically: true, encoding: .utf8)
            link.save(base: base)
            return (link, "")
        } catch {
            return (nil, (error as? CRMError)?.message ?? error.localizedDescription)
        }
    }
}

/// G7: "CRM: Northwind · Deal: Orbit renewal" in Start call, with Refresh and a menu to change the deal or say No deal.
struct CRMCallRow: View {
    @ObservedObject var model: StartCallModel
    @ObservedObject var crm = CRMService.shared
    @State private var link: CRMLink? = nil
    @State private var deals: [CRMDeal] = []
    @State private var busy = false
    @State private var err = ""

    var base: String? { PrepDocWindow.path(for: model).map { String($0.dropLast(9)) } ?? model.prepBase }
    var emails: [String] { model.calEventID.flatMap { id in CalendarService.shared.events.first { $0.id == id }?.emails } ?? [] }

    var body: some View {
        if crm.connected {
            HStack(spacing: 8) {
                Image(systemName: "briefcase").foregroundStyle(PN.C.text3)
                Text(line).font(PN.Font.caption).foregroundStyle(PN.C.text2).lineLimit(1)
                if !deals.isEmpty {
                    Menu {
                        ForEach(deals) { d in Button(d.name) { setDeal(d.id, d.name) } }
                        Divider()
                        Button(L("crm.noDeal")) { setDeal("none", "") }
                    } label: { Image(systemName: "chevron.down") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel(L("crm.changeDeal"))
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(L("crm.refresh")) { refresh() }.buttonStyle(.pnTertiary).disabled(busy || base == nil)
                    .help(base == nil ? L("crm.refresh.needBase") : L("crm.refresh.help"))
            }
            .onAppear { if let b = base { link = CRMLink.load(base: b) } }
        }
    }

    var line: String {
        if !err.isEmpty { return err }
        guard let l = link else { return L("crm.notLinked") }
        let co = l.companyName.isEmpty ? L("crm.noCompany") : l.companyName
        let deal = l.dealId == "none" ? L("crm.noDeal") : (l.dealName.isEmpty ? L("crm.noDeal") : l.dealName)
        return L("crm.line", ["company": co, "deal": deal])
    }

    func refresh() {
        guard let b = base else { return }
        busy = true; err = ""
        let name = model.project?.crmCompanyName.isEmpty == false ? model.project!.crmCompanyName : (model.project?.name ?? "")
        Task {
            let (l, e) = await crm.refresh(base: b, emails: emails, name: name, keep: link)
            link = l; err = e; busy = false
            if let co = l?.companyId, !co.isEmpty, let c = crm.connector() { deals = ((try? await c.deals(companyId: co)) ?? []).filter { $0.open } }
        }
    }

    func setDeal(_ id: String, _ name: String) {
        guard let b = base else { return }
        var l = link ?? CRMLink(); l.dealId = id; l.dealName = name; l.save(base: b); link = l
        refresh()
    }
}

// MARK: - Update <CRM> (I5)

@MainActor
enum CRMUpdateWindow {
    static var window: NSWindow?
    static func show(file: String) {
        let w = window ?? NSWindow(contentViewController: NSHostingController(rootView: AnyView(EmptyView())))
        w.contentViewController = NSHostingController(rootView: Localized { CRMUpdateView(file: file) })
        w.tabbingMode = .disallowed
        w.title = L("crm.update.title", ["crm": "HubSpot"])
        w.setContentSize(NSSize(width: 560, height: 520))
        w.isReleasedWhenClosed = false
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct CRMUpdateView: View {
    let file: String
    @ObservedObject var crm = CRMService.shared
    @State private var plan: CRMUpdatePlan? = nil
    @State private var link: CRMLink? = nil
    @State private var stage = ""
    @State private var busy = false
    @State private var status = ""
    @State private var undo: [(String, String, [String: String])] = []    // (type, id, old fields)
    @State private var undoUntil: Date? = nil
    @State private var applied = false     // 0.8.7.1: a second Apply wrote the note and the task twice

    var base: String { file.hasSuffix(".md") ? String(file.dropLast(3)) : file }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("crm.update.sub")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            if let l = link, let p = plan {
                Text(L("crm.line", ["company": l.companyName.isEmpty ? L("crm.noCompany") : l.companyName, "deal": l.dealName.isEmpty ? L("crm.noDeal") : l.dealName]))
                    .font(PN.Font.body.weight(.semibold))
                ForEach(p.rows.indices, id: \.self) { i in
                    Toggle(isOn: Binding(get: { plan?.rows[i].on ?? false }, set: { plan?.rows[i].on = $0 })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("crm.row." + p.rows[i].id))
                            if !p.rows[i].detail.isEmpty { Text(p.rows[i].detail).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(p.rows[i].id == "deal" && (l.dealId.isEmpty || l.dealId == "none"))
                }
                TextField(L("crm.stage"), text: $stage, prompt: Text(L("crm.stage.prompt"))).help(L("crm.stage.help"))
            } else {
                Text(L("crm.update.noLink")).foregroundStyle(PN.C.text3)
            }
            Spacer()
            HStack {
                Text(status).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(2)
                Spacer()
                if let u = undoUntil, u > Date() { Button(L("crm.undo")) { runUndo() }.buttonStyle(.pnSecondary) }
                Button(L("crm.apply")) { apply() }.buttonStyle(.pnPrimary).disabled(busy || applied || plan == nil || link == nil)
            }
        }
        .padding(18)
        .onAppear { load() }
    }

    func load() {
        link = CRMLink.load(base: base) ?? CRMLink.load(base: file)
        let o = CallOutcome.read(transcript: file) ?? CallOutcome()     // the call page as edited (E)
        let rec = CallHistory.shared.records.first { $0.file == file }
        let sales = (try? Data(contentsOf: URL(fileURLWithPath: base + ".sales.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let next = (sales["next_step"] as? String) ?? ((sales["next_step"] as? [String: Any])?["what"] as? String) ?? ""
        // 0.8.7 (I6.5): the qualification of the call page (criterion -> what) through the mapping of its method
        var qual: [String: String] = [:]
        for c in (sales["criteria"] as? [[String: Any]]) ?? [] {
            if let k = c["criterion"] as? String, let w = c["what"] as? String, !w.isEmpty { qual[k] = w }
        }
        let crmCfg = SettingsWindow.model.config.crm
        let mapping = crmCfg.qualification[(sales["method"] as? String) ?? ""] ?? [:]
        let transcript = SettingsWindow.model.config.crm.transcriptInNote ? (try? String(contentsOfFile: file, encoding: .utf8)) : nil
        plan = CRMUpdatePlan.build(title: CallPageView.title(file), date: rec.map { CallPageView.fmt("dMMMyyyy").string(from: $0.start) } ?? "",
                                   summary: o.onMe, decisions: o.decisions, nextSteps: o.onMe + o.theirs.map { $0.who + ": " + $0.what },
                                   notionURL: rec?.notionURL ?? "", transcript: transcript, nextStep: next, closeDate: "", stage: nil,
                                   qualification: qual, mapping: mapping, followUp: next.isEmpty ? nil : (next, nil),
                                   writeNote: crmCfg.writeNote, writeDeal: crmCfg.writeDeal, writeTask: crmCfg.writeTask)
    }

    func apply() {
        guard var p = plan, let l = link, let c = crm.connector() else { return }
        if !stage.isEmpty { p.dealFields["dealstage"] = stage }
        busy = true; status = L("crm.writing")
        Task {
            var done: [(String, String, [String: String])] = []
            var fields = 0
            do {
                var refs: [CRMRef] = []
                if !l.dealId.isEmpty && l.dealId != "none" { refs.append(CRMRef("deals", l.dealId)) }
                if !l.companyId.isEmpty { refs.append(CRMRef("companies", l.companyId)) }
                refs += l.contactIds.map { CRMRef("contacts", $0) }
                if p.rows.first(where: { $0.id == "note" })?.on == true {
                    let id = try await c.createNote(text: p.note, associations: refs); done.append(("notes", id, [:]))
                }
                if p.rows.first(where: { $0.id == "deal" })?.on == true, !l.dealId.isEmpty, l.dealId != "none", !p.dealFields.isEmpty {
                    let old = try await c.updateDeal(id: l.dealId, fields: p.dealFields); done.append(("deals", l.dealId, old)); fields = p.dealFields.count
                }
                if p.rows.first(where: { $0.id == "task" })?.on == true, let t = p.task {
                    let id = try await c.createTask(subject: t.subject, due: t.due, associations: refs); done.append(("tasks", id, [:]))
                }
                UsageLog.log("update_crm", ["fields": fields])
                undo = done; undoUntil = Date().addingTimeInterval(8); applied = true
                status = L("crm.updated", ["crm": c.providerName])
                DispatchQueue.main.asyncAfter(deadline: .now() + 8.2) { undoUntil = nil }
            } catch {
                undo = done; undoUntil = done.isEmpty ? nil : Date().addingTimeInterval(8)
                status = (error as? CRMError)?.message ?? error.localizedDescription
            }
            busy = false
        }
    }

    /// Undo: notes and tasks are deleted, deal fields get their old values back.
    func runUndo() {
        guard let c = crm.connector() else { return }
        let items = undo; undo = []; undoUntil = nil
        Task {
            var failed = 0      // 0.8.7.1: a failed undo is said, not hidden behind "Undone"
            for (type, id, old) in items.reversed() {
                do {
                    if type == "deals" { _ = try await c.updateDeal(id: id, fields: old) } else { try await c.delete(type: type, id: id) }
                } catch { failed += 1 }
            }
            status = failed == 0 ? L("crm.undone") : L("crm.undoFailed", ["n": "\(failed)", "crm": c.providerName])
            if failed == 0 { applied = false }
        }
    }
}
extension CRMDeal: Identifiable {}
