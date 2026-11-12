import AppKit
import LiveTipsCore
import SwiftUI
import UniformTypeIdentifiers

// 0.10.0 (Meeting Sheet, phase 4): the two entries into one preparation. Quick (S1a): one screen that repeats the
// series' setup, "Anything special today?", Prepare. Expert (S1-S5): Meeting, Blocks, Sources, Size, Build, the
// steps are clickable. The Quick / Expert switch sits in the header; the default comes from Settings > Meeting Sheet.
// Mockups: ms/mockups/S1Quick, Main (S1), S2Blocks, S3Sources, S4Budget, S5Build.

@MainActor
enum SheetPrepWindow {
    static var windows: [UUID: NSWindow] = [:]

    /// Get ready: Quick or Expert by the default rules (mode nil), or the one asked for; step for Expert.
    static func show(_ m: StartCallModel, mode: SheetMode? = nil, step: Int = 1) {
        SheetLibrary.shared.reload()
        let d = SheetDraft(model: m)
        if let mode { d.mode = mode }
        d.step = step
        let host = NSHostingController(rootView: Localized { SheetPrepView(draft: d) })
        let w = windows[m.id] ?? NSWindow(contentViewController: host)
        w.contentViewController = host
        w.tabbingMode = .disallowed
        w.styleMask.insert(.resizable)
        w.title = L("sheet.ui.window", ["title": m.effectiveTitle])
        w.setContentSize(NSSize(width: 860, height: 760))
        w.isReleasedWhenClosed = false
        windows[m.id] = w
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func close(_ m: StartCallModel) { windows[m.id]?.close() }
}

struct SheetPrepView: View {
    @ObservedObject var draft: SheetDraft
    @ObservedObject var lib = SheetLibrary.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $draft.mode) {
                    Text(L("sheet.ui.quick")).tag(SheetMode.quick)
                    Text(L("sheet.ui.expert")).tag(SheetMode.expert)
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
                if draft.mode == .expert { SheetStepBar(draft: draft) }
                Spacer()
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
            Divider()
            if draft.mode == .quick { SheetQuickView(draft: draft) } else { SheetExpertView(draft: draft) }
        }
        .background(PN.C.bg)
        .frame(minWidth: 720, minHeight: 600)
        .onAppear { draft.checkSources() }
        .onChange(of: lib.loaded) { if draft.presetSuggested { draft.applyPreset(draft.presetID) } }
    }
}

// MARK: - Quick (S1a)

struct SheetQuickView: View {
    @ObservedObject var draft: SheetDraft
    @ObservedObject var jobs = SheetJobs.shared
    @State private var fixing: String?

    private var m: StartCallModel { draft.model }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                head
                if let j = draft.job { SheetQuickDone(draft: draft, job: j) } else { setup }
            }
            .padding(24).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
        }
    }

    private var head: some View {
        let t = DateFormatter(); t.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US"); t.setLocalizedDateFormatFromTemplate("EEEMMMdHHmm")
        let mins = Int(m.callDate.timeIntervalSinceNow / 60)
        return VStack(alignment: .leading, spacing: 6) {
            Text(t.string(from: m.callDate) + (mins > 0 && mins < 180 ? " · " + L("sheet.ui.inMin", ["n": "\(mins)"]) : ""))
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(PN.C.accent)
            Text(m.effectiveTitle).font(.system(size: 26, weight: .bold)).foregroundStyle(PN.C.text)
            let people = HomeView.peopleLine(m.participants)
            if !people.isEmpty { Text(L("home.card.with", ["people": people])).font(PN.Font.body).foregroundStyle(PN.C.text2) }
        }
    }

    private var problems: [String] {
        var p: [String] = []
        if let r = SheetRoutes.problem(draft.route) { p.append(r) }
        if draft.sources.contains(where: { $0.checked && ["denied", "unsupported"].contains($0.access) }) { p.append("access") }
        return p
    }

    private var setup: some View {
        PageCard(spacing: 10) {
            HStack(spacing: 8) {
                Text(L("sheet.ui.quick.title")).font(PN.Font.section)
                if !draft.remembered { PagePill(text: L("sheet.ui.quick.suggested"), color: PN.C.accent) }
                Spacer()
            }
            Text(problems.isEmpty ? (draft.remembered ? L("sheet.ui.quick.same") : L("sheet.ui.quick.first", ["title": m.effectiveTitle]))
                 : L("sheet.ui.quick.attention"))
                .font(PN.Font.caption).foregroundStyle(problems.isEmpty ? PN.C.text3 : PN.C.pending).fixedSize(horizontal: false, vertical: true)
            Divider()
            rows
            Divider()
            special
            actions
        }
    }

    @ViewBuilder private var rows: some View {
        VStack(alignment: .leading, spacing: 8) {
            row(L("sheet.ui.row.preset"), draft.preset?.name ?? draft.presetID,
                (draft.preset?.blocks ?? []).map { SheetLibrary.shared.title($0) }.prefix(5).joined(separator: ", "), ok: true, fix: nil)
            let bad = draft.sources.filter { $0.checked && ["denied", "unsupported"].contains($0.access) }
            row(L("sheet.ui.row.sources"), L("sheet.ui.quick.sources", ["n": "\(draft.sources.filter(\.checked).count)"]),
                bad.isEmpty ? draft.sources.filter(\.checked).prefix(3).map(\.title).joined(separator: ", ") : bad.map { $0.title + ": " + ($0.reason ?? SheetLabels.access(source: $0)) }.joined(separator: "; "),
                ok: bad.isEmpty, fix: bad.isEmpty ? nil : "sources")
            let total = draft.sources.filter(\.checked).compactMap(\.tokens).reduce(0, +)
            let routeProblem = SheetRoutes.problem(draft.route)
            row(L("sheet.ui.row.size"), L("sheet.ui.quick.size", ["t": SheetLabels.tokens(total), "route": AIRoute.name(draft.route)]),
                routeProblem ?? (total > SheetRoutes.window(draft.route) - 12_000 ? L("sheet.ui.size.tooMuch") : L("sheet.ui.size.fits")),
                ok: routeProblem == nil && total <= SheetRoutes.window(draft.route) - 12_000, fix: routeProblem == nil ? (total > SheetRoutes.window(draft.route) - 12_000 ? "size" : nil) : "route")
            row(L("sheet.ui.row.live"), liveLine, "", ok: true, fix: nil)
        }
    }

    @ViewBuilder private var special: some View {
        VStack(alignment: .leading, spacing: 4) {
                Text(L("sheet.ui.quick.special")).font(PN.Font.body.weight(.semibold))
                TextField(L("sheet.ui.quick.specialPh"), text: $draft.special).textFieldStyle(.roundedBorder)
                ForEach(draft.linksInText, id: \.self) { l in SheetLinkSuggestion(draft: draft, link: l) }
        }
    }

    @ViewBuilder private var actions: some View {
        let routeProblem = SheetRoutes.problem(draft.route)
        VStack(alignment: .leading, spacing: 8) {
            if !draft.remembered {
                Label(L("sheet.ui.quick.remember", ["title": m.effectiveTitle]), systemImage: "arrow.triangle.2.circlepath").font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            if !draft.note.isEmpty { Text(draft.note).font(PN.Font.caption).foregroundStyle(PN.C.pending).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 10) {
                Button(L("sheet.ui.quick.openExpert")) { draft.mode = .expert }.buttonStyle(.pnTertiary)
                Spacer()
                Button(L("sheet.ui.startWithout")) { startCall() }.buttonStyle(.pnSecondary)
                Button(L("sheet.ui.quick.prepare", ["n": "\(draft.estimateSeconds)"])) { if let e = draft.build() { draft.note = e } }
                    .buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction).disabled(routeProblem != nil || draft.checking)
            }
            .padding(.top, 6)
            Text(L("sheet.ui.quick.defaults")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var liveLine: String {
        var parts = [m.callType == "presentation" ? L("start.type.presentation") : m.callType == "interview" ? L("callSettings.type.interview") : L("sheet.ui.live.regular")]
        if m.salesEnabled { parts.append(L("page.salesMode")) }
        return parts.joined(separator: " · ")
    }

    private func row(_ k: String, _ v: String, _ sub: String, ok: Bool, fix: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(k).font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.text3).frame(width: 70, alignment: .leading).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(v).font(PN.Font.body).foregroundStyle(PN.C.text)
                if !sub.isEmpty { Text(sub).font(PN.Font.caption).foregroundStyle(ok ? PN.C.text3 : PN.C.pending).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer()
            Label(ok ? L("sheet.ui.ok") : L("sheet.ui.needsYou"), systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(PN.Font.caption.weight(.semibold)).foregroundStyle(ok ? PN.C.turn : PN.C.pending).fixedSize()
            if let f = fix {
                Button(L("sheet.ui.fix")) {
                    draft.mode = .expert
                    draft.step = f == "sources" ? 3 : 4
                }.buttonStyle(.pnSecondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func startCall() {
        guard let app = NSApp.delegate as? AppDelegate else { return }
        m.useDefaultTargetIfEmpty()
        if let e = app.launch(m) { draft.note = e } else { SheetPrepWindow.close(m) }
    }
}

extension SheetLabels {
    static func access(source s: DraftSource) -> String {
        switch s.access {
        case "ok": return L("sheet.ui.access.ok")
        case "denied": return L("sheet.ui.access.denied")
        case "unsupported": return L("sheet.ui.access.unsupported")
        default: return L("sheet.ui.access.pending")
        }
    }
}

/// Quick, done: the short sheet and the two next steps (or the progress while it builds).
struct SheetQuickDone: View {
    @ObservedObject var draft: SheetDraft
    @ObservedObject var job: SheetJob

    var body: some View {
        PageCard(spacing: 10) {
            if job.done, let p = job.sheetPath, let s = SheetCache.shared.load(p) {
                HStack {
                    Text(s.title).font(PN.Font.section)
                    SheetReadinessPill(badge: s.readinessBadge)
                    Spacer()
                }
                ForEach(s.shownBlocks.prefix(6)) { b in
                    HStack(alignment: .top, spacing: 12) {
                        Text(b.title).font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.text3).frame(width: 140, alignment: .leading)
                        Text(b.facts.prefix(2).map(\.text).joined(separator: "\n")).font(PN.Font.body).foregroundStyle(PN.C.text).lineLimit(3)
                    }
                }
                HStack {
                    Button(L("sheet.ui.quick.openFull")) {
                        SheetPrepWindow.close(draft.model)
                        UpcomingCallPage.openTab[draft.model.id.uuidString] = "sheet"
                        UpcomingPages.open(draft.model)
                    }.buttonStyle(.pnSecondary)
                    Spacer()
                    Button(L("home.startCall")) {
                        if let app = NSApp.delegate as? AppDelegate, app.launch(draft.model) == nil { SheetPrepWindow.close(draft.model) }
                    }.buttonStyle(.pnPrimary)
                }
            } else if let e = job.failed {
                Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(PN.C.pending).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(L("sheet.ui.build.again")) { draft.job = nil }.buttonStyle(.pnSecondary)
                    Spacer()
                    Button(L("sheet.ui.startWithout")) { if let app = NSApp.delegate as? AppDelegate { _ = app.launch(draft.model) } }.buttonStyle(.pnSecondary)
                }
            } else {
                Text(job.stage.isEmpty ? L("sheet.ui.build.starting") : job.stage).font(PN.Font.body)
                PageProgress(value: job.progress)
                HStack {
                    Button(L("call.stop")) { job.stop() }.buttonStyle(.pnTertiary)
                    Spacer()
                    Button(L("sheet.ui.build.closeNotify")) { job.notifyWhenDone = true; SheetPrepWindow.close(draft.model) }.buttonStyle(.pnSecondary)
                }
            }
        }
    }
}

/// A link found in the goal or the context: Move to Sources (checked in full) or Keep as text.
struct SheetLinkSuggestion: View {
    @ObservedObject var draft: SheetDraft
    let link: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "link").foregroundStyle(PN.C.accent)
            Text(L("sheet.ui.link.found", ["kind": SheetLabels.kind(SourceType(rawValue: SheetDraft.linkType(link))), "link": String(link.prefix(48))]))
                .font(PN.Font.caption).foregroundStyle(PN.C.text2).lineLimit(2)
            Spacer()
            Button(L("sheet.ui.link.move")) { draft.add(pasted: link) }.buttonStyle(.pnSecondary)
            Button(L("sheet.ui.link.keep")) { draft.keptLink.insert(link) }.buttonStyle(.pnTertiary)
        }
        .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(PN.C.accent.opacity(0.06)))
    }
}

// MARK: - Expert (S1-S5)

struct SheetStepBar: View {
    @ObservedObject var draft: SheetDraft
    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { n in
                let on = draft.step == n
                Button {
                    draft.step = n
                    if n == 4 { draft.checkSize() }
                } label: {
                    HStack(spacing: 5) {
                        Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundStyle(on ? .white : PN.C.text2)
                            .frame(width: 18, height: 18).background(Circle().fill(on ? PN.C.accentFill : PN.C.surface2))
                        Text(L("sheet.ui.step.\(n)")).font(PN.Font.caption.weight(on ? .semibold : .regular)).foregroundStyle(on ? PN.C.text : PN.C.text2)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 4).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(n == 5 && draft.job == nil)
            }
        }
    }
}

struct SheetExpertView: View {
    @ObservedObject var draft: SheetDraft

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch draft.step {
                    case 2: SheetBlocksStep(draft: draft)
                    case 3: SheetSourcesStep(draft: draft)
                    case 4: SheetSizeStep(draft: draft)
                    case 5: SheetBuildStep(draft: draft)
                    default: SheetMeetingStep(draft: draft)
                    }
                    if !draft.note.isEmpty { Text(draft.note).font(PN.Font.caption).foregroundStyle(PN.C.pending).fixedSize(horizontal: false, vertical: true) }
                }
                .padding(24).frame(maxWidth: 860, alignment: .leading).frame(maxWidth: .infinity)
            }
            if draft.step < 5 {
                Divider()
                HStack(spacing: 10) {
                    Text(L("sheet.ui.footer.preset", ["name": draft.preset?.name ?? draft.presetID, "n": "\(draft.blocks.filter(\.visible).count)"]))
                        .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    Spacer()
                    Button(L("common.cancel")) { SheetPrepWindow.close(draft.model) }.buttonStyle(.pnTertiary).keyboardShortcut(.cancelAction)
                    if draft.step > 1 { Button(L("sheet.ui.back")) { draft.step -= 1 }.buttonStyle(.pnSecondary) }
                    next
                }
                .padding(.horizontal, 24).padding(.vertical, 12).background(PN.C.bg)
            }
        }
    }

    @ViewBuilder private var next: some View {
        switch draft.step {
        case 1: Button(L("sheet.ui.next.blocks")) { draft.step = 2 }.buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
        case 2: Button(L("sheet.ui.next.sources")) { draft.step = 3; draft.loadCandidates() }.buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
        case 3: Button(L("sheet.ui.next.size")) { draft.step = 4; draft.checkSize() }.buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
        default:
            Button(L("sheet.ui.build")) {
                if let e = draft.build() { draft.note = e } else { draft.step = 5 }
            }
            .buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
            .disabled(draft.size?.state == .tooMuch && draft.plan.isEmpty || SheetRoutes.problem(draft.route) != nil)
        }
    }
}

// MARK: S1 Meeting

struct SheetMeetingStep: View {
    @ObservedObject var draft: SheetDraft
    @ObservedObject var lib = SheetLibrary.shared
    @State private var newOurs = ""
    @State private var newTheirs = ""

    private var m: StartCallModel { draft.model }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("sheet.ui.s1.title")).font(.system(size: 24, weight: .bold))
                Text(L("sheet.ui.s1.sub")).font(PN.Font.body).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
            }
            PageCard(spacing: 10) {
                Picker("", selection: $draft.withEvent) {
                    Text(L("sheet.ui.s1.fromCalendar")).tag(true)
                    Text(L("sheet.ui.s1.noEvent")).tag(false)
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize().disabled(m.calEventID == nil)
                if draft.withEvent, m.calEventID != nil {
                    Label(L("sheet.ui.s1.event"), systemImage: "calendar").font(PN.Font.caption).foregroundStyle(PN.C.text3)
                } else {
                    Text(L("sheet.ui.s1.noEventNote")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                }
                field(L("sheet.ui.s1.name")) { TextField(m.effectiveTitle, text: Binding(get: { m.title }, set: { m.title = $0 })).textFieldStyle(.roundedBorder) }
                field(L("sheet.ui.s1.when")) { DatePicker("", selection: Binding(get: { m.callDate }, set: { m.callDate = $0 })).labelsHidden().fixedSize() }
                people(L("sheet.ui.s1.ours"), $draft.ours, $newOurs)
                people(L("sheet.ui.s1.theirs"), $draft.theirs, $newTheirs)
                field(L("sheet.ui.s1.goal")) {
                    TextField(L("sheet.ui.s1.goalPh"), text: $draft.goal, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...4)
                }
                ForEach(draft.linksInText, id: \.self) { l in SheetLinkSuggestion(draft: draft, link: l) }
            }
            PageCard(spacing: 10) {
                PageLabel(text: L("sheet.ui.s1.kind"))
                Text(L("sheet.ui.s1.kindSub")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                if draft.presetSuggested {
                    Text(L("sheet.ui.s1.suggested", ["name": draft.preset?.name ?? draft.presetID])).font(PN.Font.caption).foregroundStyle(PN.C.accent)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(lib.presets.filter { !$0.mine }) { p in presetTile(p) }
                }
                let mine = lib.presets.filter(\.mine)
                if !mine.isEmpty {
                    PageLabel(text: L("sheet.ui.s1.myPresets")).padding(.top, 6)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(mine) { p in presetTile(p) }
                    }
                }
            }
            PageCard(spacing: 10) {
                field(L("sheet.ui.s1.project")) {
                    Picker("", selection: Binding(get: { m.target }, set: { m.target = $0; m.applyProjectDefaults() })) {
                        ForEach(m.registry.workspaces, id: \.name) { w in Text(w.name).tag("workspace:" + w.name) }
                        ForEach(m.registry.projects.filter { $0.status != "archived" }, id: \.slug) { p in Text(p.name).tag("project:" + p.slug) }
                    }.labelsHidden().fixedSize()
                }
                field(L("sheet.ui.s1.language")) {
                    Picker("", selection: $draft.language) {
                        Text(L("sheet.ui.lang.en")).tag("en")
                        Text(L("sheet.ui.lang.uk")).tag("uk")
                    }.labelsHidden().pickerStyle(.segmented).fixedSize()
                }
                field(L("sheet.ui.s1.remind")) {
                    Picker("", selection: $draft.remind) {
                        Text(L("sheet.ui.remind.30")).tag(30)
                        Text(L("sheet.ui.remind.60")).tag(60)
                        Text(L("sheet.ui.remind.off")).tag(0)
                        if ![0, 30, 60].contains(draft.remind) { Text(L("sheet.ui.remind.n", ["n": "\(draft.remind)"])).tag(draft.remind) }
                    }.labelsHidden().pickerStyle(.segmented).fixedSize()
                }
            }
        }
    }

    private func field<C: View>(_ t: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(t).font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.text2).frame(width: 110, alignment: .leading)
            c()
            Spacer(minLength: 0)
        }
    }

    private func people(_ t: String, _ list: Binding<[DraftPerson]>, _ new: Binding<String>) -> some View {
        field(t) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(list.wrappedValue) { p in
                        HStack(spacing: 4) {
                            Text(p.name + (p.company.isEmpty ? "" : " · " + p.company))
                            Button { list.wrappedValue.removeAll { $0.id == p.id } } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel(L("call.remove"))
                        }
                        .font(PN.Font.caption).padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(PN.C.surface2))
                    }
                }
                HStack(spacing: 6) {
                    TextField(L("sheet.ui.s1.personPh"), text: new).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
                        .onSubmit { addPerson(list, new) }
                    Button(L("sheet.ui.add")) { addPerson(list, new) }.buttonStyle(.pnTertiary)
                }
            }
        }
    }

    private func addPerson(_ list: Binding<[DraftPerson]>, _ new: Binding<String>) {
        let t = new.wrappedValue.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        let parts = t.split(separator: "·", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        list.wrappedValue.append(DraftPerson(name: parts[0], company: parts.count > 1 ? parts[1] : ""))
        new.wrappedValue = ""
    }

    private func presetTile(_ p: SheetPresetInfo) -> some View {
        let on = draft.presetID == p.id
        return Button {
            draft.applyPreset(p.id); draft.presetSuggested = false
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(PN.Font.body.weight(.semibold)).foregroundStyle(PN.C.text)
                Text(L("sheet.ui.s1.blocks", ["n": "\(p.blocks.count)"]) + " · " + (p.mode == "expert" ? L("sheet.ui.expert") : L("sheet.ui.quick")))
                    .font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(on ? PN.C.accent.opacity(0.1) : PN.C.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? PN.C.accent : Color.primary.opacity(0.12), lineWidth: on ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: S2 Blocks

struct SheetBlocksStep: View {
    @ObservedObject var draft: SheetDraft
    @ObservedObject var lib = SheetLibrary.shared
    @ObservedObject var prefs = SheetPrefs.shared
    @State private var saving = false
    @State private var presetName = ""
    @State private var suggestNew = false
    @State private var saveNote = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("sheet.ui.s2.title")).font(.system(size: 24, weight: .bold))
                Text(L("sheet.ui.s2.sub", ["name": draft.preset?.name ?? draft.presetID])).font(PN.Font.body).foregroundStyle(PN.C.text2)
            }
            PageCard(spacing: 0) {
                List {
                    ForEach($draft.blocks) { $b in blockRow($b) }
                        .onMove { draft.blocks.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
                .frame(height: CGFloat(max(3, draft.blocks.count)) * 52)
                HStack {
                    Menu(L("sheet.ui.s2.add")) {
                        ForEach(BlockType.known.map(\.rawValue).filter { t in !draft.blocks.contains { $0.type == t } }, id: \.self) { t in
                            Button(lib.title(t)) { draft.blocks.append(DraftBlock(type: t, title: lib.title(t), method: t == "qualification" ? "bant" : nil)) }
                        }
                    }
                    .fixedSize()
                    Spacer()
                    Button(L("sheet.ui.s2.save")) { presetName = ""; saving = true }.buttonStyle(.pnSecondary)
                }
                .padding(.top, 10)
            }
            PageCard(spacing: 6) {
                PageLabel(text: L("sheet.ui.myFocus"))
                Text(L("sheet.ui.s2.focusSub")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                Text(prefs.focus.joined(separator: " · ")).font(PN.Font.body)
                Button(L("sheet.ui.s2.focusEdit")) { SettingsWindow.show(tab: "sheet") }.buttonStyle(.pnTertiary)
            }
            if let p = draft.preset, !p.readiness.isEmpty {
                PageCard(spacing: 6) {
                    PageLabel(text: L("sheet.ui.s2.readyMeans"))
                    Text(p.readiness.map { r in let k = "sheet.ui.rule." + r; let t = L(k); return t == k ? (lib.ruleGaps[r] ?? r) : t }.joined(separator: " · "))
                        .font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .sheet(isPresented: $saving) { saveSheet }
    }

    private func blockRow(_ b: Binding<DraftBlock>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").foregroundStyle(PN.C.text3).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(b.wrappedValue.title).font(PN.Font.body.weight(.medium)).foregroundStyle(b.wrappedValue.visible ? PN.C.text : PN.C.text3)
                Text(b.wrappedValue.visible ? (lib.blockFields[b.wrappedValue.type] ?? "") : L("sheet.ui.s2.hidden")).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(1)
            }
            Spacer()
            if b.wrappedValue.type == "qualification" {
                Picker("", selection: Binding(get: { b.wrappedValue.method ?? "bant" }, set: { b.wrappedValue.method = $0 })) {
                    ForEach(lib.methods, id: \.self) { Text($0.uppercased()).tag($0) }
                }.labelsHidden().fixedSize()
            }
            Toggle(L("sheet.ui.s2.onlyIfData"), isOn: b.onlyIfData).toggleStyle(.checkbox).font(PN.Font.caption)
            Button { b.wrappedValue.visible.toggle() } label: {
                Image(systemName: b.wrappedValue.visible ? "eye" : "eye.slash").foregroundStyle(b.wrappedValue.visible ? PN.C.text2 : PN.C.pending)
            }
            .buttonStyle(.plain).help(b.wrappedValue.visible ? L("sheet.ui.s2.hide") : L("sheet.ui.s2.show"))
            .accessibilityLabel(b.wrappedValue.visible ? L("sheet.ui.s2.hide") : L("sheet.ui.s2.show"))
            Button { draft.blocks.removeAll { $0.type == b.wrappedValue.type } } label: { Image(systemName: "xmark").foregroundStyle(PN.C.text3) }
                .buttonStyle(.plain).accessibilityLabel(L("call.remove"))
        }
        .padding(.vertical, 6)
    }

    private var saveSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("sheet.ui.s2.save")).font(PN.Font.section)
            TextField(L("sheet.ui.s2.name"), text: $presetName).textFieldStyle(.roundedBorder)
            Text(L("sheet.ui.s2.saveNote", ["n": "\(draft.blocks.filter(\.visible).count)"])).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            Toggle(L("sheet.ui.s2.suggestNew"), isOn: $suggestNew).toggleStyle(.checkbox)
            if !saveNote.isEmpty { Text(saveNote).font(PN.Font.caption).foregroundStyle(PN.C.pending) }
            HStack {
                Spacer()
                Button(L("common.cancel")) { saving = false }.buttonStyle(.pnTertiary)
                Button(L("sheet.ui.s2.savePreset")) {
                    let req: [String: Any] = ["action": "save", "name": presetName, "blocks": draft.blocks.map(\.type),
                                              "hidden": draft.blocks.filter { !$0.visible }.map(\.type),
                                              "only_if_data": draft.blocks.filter(\.onlyIfData).map(\.type),
                                              "mode": draft.mode.rawValue, "readiness": draft.preset?.readiness ?? [], "base": draft.presetID,
                                              "method": draft.blocks.first { $0.type == "qualification" }?.method ?? "bant",
                                              "suggest_new_domains": suggestNew]
                    lib.change(req) { e in if let e { saveNote = e } else { saving = false } }
                }
                .buttonStyle(.pnPrimary).disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 420)
    }
}

// MARK: S3 Sources

struct SheetSourcesStep: View {
    @ObservedObject var draft: SheetDraft
    @State private var paste = ""
    @State private var dropping = false
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("sheet.ui.s3.title")).font(.system(size: 24, weight: .bold))
                Text(L("sheet.ui.s3.sub")).font(PN.Font.body).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(draft.linksInText, id: \.self) { l in SheetLinkSuggestion(draft: draft, link: l) }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    PageCard(spacing: 10) {
                        HStack(spacing: 8) {
                            TextField(L("sheet.ui.s3.pastePh"), text: $paste).textFieldStyle(.roundedBorder).onSubmit(addPaste)
                            Button(L("sheet.ui.add"), action: addPaste).buttonStyle(.pnSecondary)
                            Button(L("sheet.ui.s3.choose")) { draft.chooseFiles() }.buttonStyle(.pnSecondary)
                        }
                        dropZone
                        if draft.checking { HStack(spacing: 6) { ProgressView().controlSize(.small); Text(L("common.checking")).font(PN.Font.caption) } }
                        ForEach($draft.sources) { $s in SheetDraftSourceRow(draft: draft, source: $s) }
                        if !draft.hasLinkedIn {
                            Label(L("sheet.ui.s3.noLinkedIn"), systemImage: "person.crop.square").font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    ForEach($draft.sources) { $s in
                        if s.type == "linkedin" || s.type == "linkedin_manual" { SheetLinkedInCard(draft: draft, source: $s) }
                    }
                    candidates
                }
                .frame(maxWidth: .infinity)
                whatYouCanAdd.frame(width: 220)
            }
        }
        .onAppear { if draft.candidates.isEmpty { draft.loadCandidates() } }
    }

    private func addPaste() { draft.add(pasted: paste); paste = "" }

    private var dropZone: some View {
        VStack(spacing: 4) {
            Image(systemName: "tray.and.arrow.down").font(.system(size: 20)).foregroundStyle(dropping ? PN.C.accent : PN.C.text3)
            Text(L("sheet.ui.s3.drop")).font(PN.Font.body.weight(.medium))
            Text(L("sheet.ui.s3.dropSub")).font(PN.Font.caption).foregroundStyle(PN.C.text3).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(16)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5])).foregroundStyle(dropping ? PN.C.accent : Color.primary.opacity(0.2)))
        .onDrop(of: [UTType.fileURL], isTargeted: $dropping) { items in
            for it in items {
                _ = it.loadObject(ofClass: URL.self) { u, _ in
                    guard let u else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { draft.add(paths: [u.path]) } }
                }
            }
            return true
        }
    }

    @ViewBuilder private var candidates: some View {
        PageCard(spacing: 6) {
            PageLabel(text: L("sheet.ui.s3.fromFolder", ["name": draft.model.targetName])) {
                if draft.candidates.contains(where: \.checked) {
                    Button(L("sheet.ui.s3.addTicked", ["n": "\(draft.candidates.filter(\.checked).count)"])) { draft.addTickedCandidates() }.buttonStyle(.pnSecondary)
                }
            }
            Text(L("sheet.ui.s3.folderNote")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            if !draft.candidateNote.isEmpty { Text(draft.candidateNote).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true) }
            let list = showAll ? draft.candidates : Array(draft.candidates.prefix(8))
            ForEach(list) { c in
                let i = draft.candidates.firstIndex { $0.id == c.id }
                HStack(alignment: .top, spacing: 8) {
                    if let i { Toggle("", isOn: $draft.candidates[i].checked).toggleStyle(.checkbox).labelsHidden() }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.title).font(PN.Font.body)
                        Text(([SheetLabels.tokens(c.tokens)] + c.why).filter { !$0.isEmpty }.joined(separator: " · ")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    }
                }
            }
            if draft.candidates.count > 8 && !showAll {
                Button(L("sheet.ui.s3.showAll", ["n": "\(draft.candidates.count)"])) { showAll = true }.buttonStyle(.pnTertiary)
            }
            if draft.candidates.isEmpty && draft.candidateNote.isEmpty { Text(L("sheet.ui.s3.noCandidates")).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
        }
    }

    private var whatYouCanAdd: some View {
        PageCard(spacing: 6) {
            PageLabel(text: L("sheet.ui.s3.canAdd"))
            ForEach(["files", "folders", "google", "notion", "web", "linkedin", "text"], id: \.self) { k in
                Text(L("sheet.ui.s3.can." + k)).font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One source before the run: icon, title, kind and size, access as icon and text, one action.
struct SheetDraftSourceRow: View {
    @ObservedObject var draft: SheetDraft
    @Binding var source: DraftSource
    @State private var pasting = false
    @State private var pasted = ""

    var body: some View {
        let st = SourceType(rawValue: source.type)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 10) {
                Toggle("", isOn: $source.checked).toggleStyle(.checkbox).labelsHidden()
                Image(systemName: SheetLabels.icon(st)).foregroundStyle(PN.C.text3).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(source.title).font(PN.Font.body.weight(.medium)).lineLimit(1)
                        if source.deck { PagePill(text: L("sheet.ui.deck"), color: PN.C.docs) }
                    }
                    Text(([SheetLabels.kind(st), SheetLabels.tokens(source.tokens)] + source.why).filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(2)
                    if let r = source.reason { Text(r).font(PN.Font.caption).foregroundStyle(source.access == "ok" ? PN.C.text3 : PN.C.pending).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 6)
                Label(SheetLabels.access(source: source), systemImage: icon).font(PN.Font.caption.weight(.semibold)).foregroundStyle(color).fixedSize()
                action
                Button { draft.sources.removeAll { $0.id == source.id } } label: { Image(systemName: "xmark").foregroundStyle(PN.C.text3) }
                    .buttonStyle(.plain).accessibilityLabel(L("call.remove"))
            }
            if draft.model.callType == "presentation" && ["pptx", "pdf", "key"].contains(((source.path ?? "") as NSString).pathExtension.lowercased()) {
                Toggle(L("sheet.ui.s3.isDeck"), isOn: $source.deck).toggleStyle(.checkbox).font(PN.Font.caption).padding(.leading, 52)
                if source.deck {
                    // The deck row carries its slide owners, minutes and Q&A: the same DeckBlock as Start call (0.8.5).
                    DeckBlock(model: draft.model).padding(.leading, 52)
                }
            }
            if pasting {
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $pasted).font(PN.Font.body).frame(height: 90)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
                    HStack {
                        Spacer()
                        Button(L("common.cancel")) { pasting = false }.buttonStyle(.pnTertiary)
                        Button(L("sheet.ui.s3.saveText")) {
                            source.text = pasted; source.access = "ok"; source.reason = nil; source.fix = nil; source.tokens = max(1, pasted.count / 4)
                            pasting = false
                        }.buttonStyle(.pnSecondary).disabled(pasted.isEmpty)
                    }
                }
                .padding(.leading, 52)
            }
        }
        .padding(.vertical, 4)
    }

    private var icon: String {
        switch source.access { case "ok": return "checkmark.circle.fill"; case "denied": return "lock.circle"; case "unsupported": return "nosign"; default: return "hourglass" }
    }
    private var color: Color { source.access == "ok" ? PN.C.turn : source.access == "pending" ? PN.C.text3 : PN.C.pending }

    @ViewBuilder private var action: some View {
        switch source.fix {
        case "connect_notion", "connect_google": Button(SheetLabels.fix(FixAction(rawValue: source.fix!))) { SettingsWindow.show(tab: "integrations") }.buttonStyle(.pnSecondary)
        case "confirm_google": Button(SheetLabels.fix(.confirmGoogle)) { if let u = source.uri, let url = URL(string: u) { NSWorkspace.shared.open(url) }; draft.checkSources() }.buttonStyle(.pnSecondary)
        case "paste_text", "save_as_pdf": Button(SheetLabels.fix(.pasteText)) { pasting = true }.buttonStyle(.pnSecondary)
        case "retry": Button(SheetLabels.fix(.retry)) { draft.checkSources() }.buttonStyle(.pnSecondary)
        case "open_in_browser": Button(SheetLabels.fix(.openInBrowser)) { if let u = source.uri, let url = URL(string: u) { NSWorkspace.shared.open(url) } }.buttonStyle(.pnSecondary)
        default: EmptyView()
        }
    }
}

/// LinkedIn: only when a LinkedIn source exists. Save to PDF, the Pacenote browser, paste the text, fill in by hand
/// (all optional, source linkedin_manual), skip. The states come from the source's access reason.
struct SheetLinkedInCard: View {
    @ObservedObject var draft: SheetDraft
    @Binding var source: DraftSource
    @State private var way = ""
    @State private var role = ""
    @State private var location = ""
    @State private var experience = ""
    @State private var other = ""
    @State private var pasted = ""

    private var state: String {
        if source.type == "linkedin_manual" || source.access == "ok" { return "read" }
        let r = (source.reason ?? "").lowercased()
        if r.contains("robots") { return "robots" }
        if r.contains("authwall") || r.contains("sign in") || r.contains("join") { return "authwall" }
        if r.contains("hidden") || r.contains("owner") { return "hidden" }
        if r.contains("empty") { return "empty" }
        return "robots"
    }

    var body: some View {
        PageCard(spacing: 8, tint: PN.C.pending) {
            PageLabel(text: L("sheet.ui.li.title", ["name": source.title]))
            Text(L("sheet.ui.li.state." + state)).font(PN.Font.body.weight(.semibold))
            Text(L("sheet.ui.li.state." + state + ".body")).font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
            if state != "read" {
                HStack(spacing: 8) {
                    Button(L("sheet.ui.li.pdf")) { way = "pdf" }.buttonStyle(.pnSecondary)
                    if SheetBrowserBridge.available {
                        Button(L("sheet.ui.li.browser")) { if let u = source.uri { SheetBrowserBridge.open(u, draft: draft, replacing: source.id) } }.buttonStyle(.pnSecondary)
                    }
                    Button(L("sheet.ui.li.paste")) { way = "paste" }.buttonStyle(.pnSecondary)
                    Button(L("sheet.ui.li.hand")) { way = "hand" }.buttonStyle(.pnSecondary)
                    Button(L("sheet.ui.li.skip")) { source.checked = false; source.reason = L("sheet.ui.li.skipped") }.buttonStyle(.pnTertiary)
                }
            }
            switch way {
            case "pdf":
                Text(L("sheet.ui.li.pdfHow")).font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
                Button(L("sheet.ui.s3.choose")) { draft.chooseFiles() }.buttonStyle(.pnSecondary)
            case "paste":
                TextEditor(text: $pasted).font(PN.Font.body).frame(height: 100).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
                Button(L("sheet.ui.s3.saveText")) { saveManual(pasted) }.buttonStyle(.pnSecondary).disabled(pasted.isEmpty)
            case "hand":
                TextField(L("sheet.ui.li.role"), text: $role).textFieldStyle(.roundedBorder)
                TextField(L("sheet.ui.li.location"), text: $location).textFieldStyle(.roundedBorder)
                TextField(L("sheet.ui.li.experience"), text: $experience, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...5)
                TextField(L("sheet.ui.li.other"), text: $other, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...4)
                Text(L("sheet.ui.li.handNote")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(L("common.cancel")) { way = "" }.buttonStyle(.pnTertiary)
                    Button(L("sheet.ui.li.save")) {
                        let lines = [(L("sheet.ui.li.role"), role), (L("sheet.ui.li.location"), location), (L("sheet.ui.li.experience"), experience), (L("sheet.ui.li.other"), other)]
                            .filter { !$0.1.trimmingCharacters(in: .whitespaces).isEmpty }.map { $0.0 + ": " + $0.1 }
                        saveManual(lines.joined(separator: "\n"))
                    }.buttonStyle(.pnSecondary)
                }
            default: EmptyView()
            }
        }
    }

    private func saveManual(_ text: String) {
        draft.sources.append(DraftSource(type: "linkedin_manual", uri: source.uri, title: L("sheet.ui.li.manualTitle", ["name": source.title]),
                                         text: text, access: "ok", tokens: max(1, text.count / 4)))
        source.checked = false
        way = ""
    }
}

/// The Pacenote browser (phase 6): one page, opened by the person, with their own session. The captured page
/// becomes a source (its text file, type linkedin or web_page) in place of the link it came from.
@MainActor
enum SheetBrowserBridge {
    static var available: Bool { true }
    static func open(_ s: String, draft: SheetDraft? = nil, replacing id: String? = nil) {
        guard let u = URL(string: s) else { return }
        let live = draft.flatMap { SheetFiles.liveFolder($0.model) }.map { URL(fileURLWithPath: $0) }
        PacenoteBrowser.open(url: u, liveFolder: live) { page in
            guard let d = draft else { return }
            let type = page.url.lowercased().contains("linkedin.com/") ? "linkedin" : "web_page"
            var src = DraftSource(type: type, path: page.textPath, uri: page.url, title: page.title.isEmpty ? page.url : page.title,
                                  text: nil, access: "ok", reason: L("sheet.ui.li.captured", ["at": SheetLabels.date(page.capturedAt)]),
                                  tokens: max(1, page.text.count / 4))
            if let id { src.id = id; d.sources.removeAll { $0.id == id } }
            d.sources.append(src)
        }
    }
}

// MARK: S4 Size

struct SheetSizeStep: View {
    @ObservedObject var draft: SheetDraft
    @State private var tooMuch = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("sheet.ui.s4.title")).font(.system(size: 24, weight: .bold))
                Text(L("sheet.ui.s4.sub")).font(PN.Font.body).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
            }
            PageCard(spacing: 8) {
                HStack {
                    Text(L("sheet.ui.s4.runsOn")).font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.text2)
                    Picker("", selection: $draft.route) {
                        ForEach(SheetRoutes.all, id: \.self) { r in
                            Text(AIRoute.name(r) + (SheetRoutes.ready(r) ? "" : " · " + L("sheet.ui.route.out"))).tag(r)
                        }
                    }
                    .labelsHidden().fixedSize()
                    .onChange(of: draft.route) { draft.checkSize() }
                    Text(L("sheet.ui.s4.default")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                }
                if let p = SheetRoutes.problem(draft.route) {
                    HStack(spacing: 8) {
                        Label(p, systemImage: "exclamationmark.triangle.fill").font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.pending)
                        // Never switched silently: the other route is offered, the person decides.
                        if let alt = SheetRoutes.firstReady(), alt != draft.route {
                            Button(L("sheet.ui.route.useOther", ["route": AIRoute.name(alt)])) { draft.route = alt }.buttonStyle(.pnSecondary)
                        }
                        Button(L("common.openSettings")) { SettingsWindow.show(tab: "ai") }.buttonStyle(.pnTertiary)
                    }
                }
            }
            if let s = draft.size { scale(s) } else if draft.checking { ProgressView() }
            biggest
        }
        .onAppear { if draft.size == nil { draft.checkSize() } }
        .sheet(isPresented: $tooMuch) { SheetTooMuch(draft: draft, done: { tooMuch = false }) }
    }

    private func scale(_ s: SizeReport) -> some View {
        let total = s.totalTokens ?? 0, w = max(1, s.window ?? SheetRoutes.window(draft.route))
        let st = s.state ?? .fits
        return PageCard(spacing: 8, tint: st == .fits ? nil : PN.C.pending) {
            Label(L("sheet.ui.size." + (st == .tooMuch ? "tooMuch" : st == .near ? "near" : "fits")),
                  systemImage: st == .fits ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(PN.Font.body.weight(.semibold)).foregroundStyle(st == .fits ? PN.C.turn : PN.C.pending)
            Text(L("sheet.ui.s4.of", ["t": SheetLabels.tokens(total), "w": SheetLabels.tokens(w)])).font(PN.Font.body)
            Capsule().fill(PN.C.surface2).frame(height: 8).overlay(alignment: .leading) {
                GeometryReader { g in
                    Capsule().fill(st == .fits ? PN.C.turn : PN.C.pendingFill).frame(width: min(1, Double(total) / Double(w)) * g.size.width)
                }
            }
            Text(L("sheet.ui.s4.reserve", ["r": SheetLabels.tokens(s.reserve ?? 12_000)])).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            if st == .tooMuch {
                HStack {
                    Text(draft.plan.isEmpty ? L("sheet.ui.s4.pickPlan") : L("sheet.ui.s4.plan." + draft.plan)).font(PN.Font.caption).foregroundStyle(PN.C.pending)
                    Spacer()
                    Button(L("sheet.ui.s4.whatToDo")) { tooMuch = true }.buttonStyle(.pnSecondary)
                }
            }
        }
        .onAppear { if st == .tooMuch && draft.plan.isEmpty { tooMuch = true } }
    }

    private var biggest: some View {
        PageCard(spacing: 6) {
            PageLabel(text: L("sheet.ui.s4.biggest"))
            ForEach(draft.sources.filter(\.checked).sorted { ($0.tokens ?? 0) > ($1.tokens ?? 0) }.prefix(5)) { s in
                HStack {
                    Text(s.title).font(PN.Font.body).lineLimit(1)
                    Spacer()
                    Text(SheetLabels.tokens(s.tokens)).font(PN.Font.caption.monospacedDigit()).foregroundStyle(PN.C.text3)
                }
            }
            Button(L("sheet.ui.s4.back")) { draft.step = 3 }.buttonStyle(.pnTertiary)
        }
    }
}

/// Too much for one pass: nothing is cut on its own, the person picks.
struct SheetTooMuch: View {
    @ObservedObject var draft: SheetDraft
    var done: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("sheet.ui.size.tooMuch")).font(PN.Font.section)
            Text(L("sheet.ui.s4.tooMuchSub")).font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
            option("passes", icon: "square.split.2x1") { draft.plan = "passes" }
            option("compress", icon: "text.redaction") { draft.plan = "compress" }
            option("remove", icon: "minus.circle") { draft.step = 3 }
            if let big = [AIRoute.gemini, AIRoute.agy].first(where: { SheetRoutes.ready($0) && $0 != draft.route }) {
                option("bigger", icon: "arrow.up.right.circle", args: ["route": AIRoute.name(big)]) { draft.route = big; draft.plan = "one"; draft.checkSize() }
            }
            HStack { Spacer(); Button(L("common.cancel"), action: done).buttonStyle(.pnTertiary) }
        }
        .padding(20).frame(width: 460)
    }

    private func option(_ k: String, icon: String, args: [String: String] = [:], run: @escaping () -> Void) -> some View {
        Button { run(); done() } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon).foregroundStyle(PN.C.accent).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("sheet.ui.s4.opt." + k, args)).font(PN.Font.body.weight(.semibold)).foregroundStyle(PN.C.text)
                    Text(L("sheet.ui.s4.opt." + k + ".sub", args)).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(PN.C.surface)).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: S5 Build

struct SheetBuildStep: View {
    @ObservedObject var draft: SheetDraft
    var body: some View {
        if let j = draft.job { SheetBuildProgress(draft: draft, job: j) } else {
            PageEmpty(icon: "hammer", title: L("sheet.ui.s5.notStarted"), text: L("sheet.ui.s5.notStartedSub"))
        }
    }
}

struct SheetBuildProgress: View {
    @ObservedObject var draft: SheetDraft
    @ObservedObject var job: SheetJob

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L("sheet.ui.s5.title")).font(.system(size: 24, weight: .bold))
                Spacer()
                if !job.done && job.failed == nil {
                    Button(L("call.stop")) { job.stop() }.buttonStyle(.pnTertiary)
                    Button(L("sheet.ui.build.closeNotify")) { job.notifyWhenDone = true; SheetPrepWindow.close(draft.model) }.buttonStyle(.pnSecondary)
                }
            }
            PageCard(spacing: 8) {
                if let n = job.pass, let all = job.passes { Text(L("sheet.ui.s5.pass", ["n": "\(n)", "all": "\(all)"])).font(PN.Font.caption.weight(.semibold)) }
                Text(job.done ? L("sheet.ui.s5.done") : job.failed ?? (job.stage.isEmpty ? L("sheet.ui.build.starting") : job.stage))
                    .font(PN.Font.body).foregroundStyle(job.failed == nil ? PN.C.text : PN.C.pending).fixedSize(horizontal: false, vertical: true)
                PageProgress(value: job.progress)
                Text(L("sheet.ui.s5.note", ["route": AIRoute.name(draft.route)])).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            }
            PageCard(spacing: 4) {
                PageLabel(text: L("sheet.ui.row.sources"))
                ForEach(draft.sources.filter(\.checked)) { s in
                    let st = job.sourceState[s.id] ?? (job.done ? "read" : "waiting")
                    HStack(spacing: 8) {
                        Image(systemName: SheetLabels.icon(SourceType(rawValue: s.type))).foregroundStyle(PN.C.text3).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.title).font(PN.Font.body).lineLimit(1)
                            if let n = job.sourceNote[s.id] { Text(n).font(PN.Font.caption).foregroundStyle(st == "failed" ? PN.C.pending : PN.C.text3) }
                        }
                        Spacer()
                        Label(L("sheet.ui.s5.state." + st), systemImage: st == "failed" ? "exclamationmark.triangle.fill" : st == "read" ? "checkmark.circle.fill" : st == "skipped" ? "minus.circle" : "hourglass")
                            .font(PN.Font.caption.weight(.semibold)).foregroundStyle(st == "failed" || st == "skipped" ? PN.C.pending : st == "read" ? PN.C.turn : PN.C.text3)
                        if st == "failed" {
                            Button(L("sheet.ui.s5.retry")) { job.control("retry", source: s.id) }.buttonStyle(.pnSecondary)
                            Button(L("sheet.ui.s5.skip")) { job.control("skip", source: s.id) }.buttonStyle(.pnTertiary)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
            if job.done {
                HStack {
                    Spacer()
                    Button(L("sheet.ui.s5.open")) {
                        SheetPrepWindow.close(draft.model)
                        UpcomingCallPage.openTab[draft.model.id.uuidString] = "sheet"
                        UpcomingPages.open(draft.model)
                    }.buttonStyle(.pnPrimary)
                }
            } else if job.failed != nil {
                HStack {
                    Spacer()
                    Button(L("sheet.ui.build.again")) { draft.job = nil; draft.step = 4 }.buttonStyle(.pnSecondary)
                }
            }
        }
    }
}
