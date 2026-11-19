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
    static func show(_ m: StartCallModel, mode: SheetMode? = nil, step: Int = 1, live: Bool = false) {
        // 0.18.0 (B3): Quick needs meeting_sheet, Expert its expert level; with Expert closed the default rules fall to Quick
        var mode = mode
        if mode == .expert { guard ModuleGate.allow("meeting_sheet", "expert") else { return } }
        else { guard ModuleGate.allow("meeting_sheet") else { return } }
        if mode == nil, !EntitlementsStore.shared.rights.can("meeting_sheet", "expert", org: ModuleGate.org) { mode = .quick }
        SheetLibrary.shared.reload()
        let d = SheetDraft(model: m)
        d.live = live
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
        w.level = live ? .floating : .normal       // 0.10.1 (A4): during the call, next to the tips window that floats too
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
                // Theme pass stage 2: the one way into Expert is this switch (the link under the form is gone)
                PNSegmented(selection: $draft.mode, options: [
                    (SheetMode.quick, L("sheet.ui.quick")),
                    (SheetMode.expert, L("sheet.ui.expertAll"))
                ]).labelsHidden().fixedSize().help(L("sheet.ui.expertAll.help"))
                if draft.mode == .expert { SheetStepBar(draft: draft).padding(.leading, 12) }
                Spacer()
            }
            .padding(.horizontal, 24).frame(minHeight: 52)
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
    @ObservedObject var ready = CallReadyState.shared        // 0.24.1 (F6)
    @State private var fixing: String?

    private var m: StartCallModel { draft.model }

    @Environment(\.pnTheme) private var th

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    head
                    if let j = draft.job { SheetQuickDone(draft: draft, job: j) } else { setup }
                }
                .padding(24).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity)
            }
            if draft.job == nil { footer }   // theme pass stage 2: the actions sit in a footer band, as in the prototype
        }
        .trackScreen("sheet_quick")
    }

    private var head: some View {
        let t = DateFormatter(); t.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US"); t.setLocalizedDateFormatFromTemplate("EEEMMMdHHmm")
        let mins = Int(m.callDate.timeIntervalSinceNow / 60)
        return VStack(alignment: .leading, spacing: 6) {
            // 0.25 (R3b, board QP): the date in mono capitals; during the call, how long it has run
            Text(th.style == .classic ? whenLine(t, mins) : whenLine(t, mins).uppercased())
                .font(th.style == .classic ? PN.sys(13, .semibold) : th.homeMono(12, .semibold)).tracking(th.style == .classic ? 0 : 0.6)
                .foregroundStyle(PN.C.accent)
            Text(m.effectiveTitle).font(th.homeDisplay(34, th.titleWeight)).tracking(th.dTrack * 34).foregroundStyle(PN.C.text)
                .fixedSize(horizontal: false, vertical: true)
            // the live head already says what happens; "Same as last time" is for the setup before the call only
            if draft.job == nil && !(draft.live && problems.isEmpty) {
                Text(problems.isEmpty ? (draft.remembered ? L("sheet.ui.quick.same") : L("sheet.ui.quick.first", ["title": m.effectiveTitle])) : L("sheet.ui.quick.attention"))
                    .font(th.homeText(16)).foregroundStyle(problems.isEmpty ? PN.C.text2 : PN.C.pending).fixedSize(horizontal: false, vertical: true)
            }
            if draft.live {
                Label(L("sheet.ui.live.head"), systemImage: "record.circle").font(PN.Font.caption).foregroundStyle(PN.C.rec)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func whenLine(_ f: DateFormatter, _ mins: Int) -> String {
        if draft.live, let since = EngineStatus.load(path: CallEngine.shared.statusPath).startedAt.flatMap({ ISO8601DateFormatter().date(from: $0) }) {
            return f.string(from: m.callDate) + " · " + L("qp.onCallFor", ["n": "\(max(1, Int(-since.timeIntervalSinceNow / 60)))"])
        }
        return f.string(from: m.callDate) + (mins > 0 && mins < 180 ? " · " + L("sheet.ui.inMin", ["n": "\(mins)"]) : "")
    }

    private var problems: [String] {
        var p: [String] = []
        if let r = SheetRoutes.problem(draft.route) { p.append(r) }
        if draft.sources.contains(where: { $0.checked && ["denied", "unsupported"].contains($0.access) }) { p.append("access") }
        return p
    }

    // 0.14.0 (D1, Get Ready redesign): three short lines (people, sources, setup), each opens in place with Change.
    // Orange only where something needs you; tokens only in a tooltip.
    @State private var open: String?

    private var setup: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 0.25 (R3b, board QP): a flat section under the heavy rule, rows split by thin rules
            VStack(alignment: .leading, spacing: 0) {
                peopleRow
                sourcesRow
                setupRow
            }
            .overlay(alignment: .top) { Rectangle().fill(PN.C.ruleStrong).frame(height: th.ruleHeavy) }
            .accessibilityElement(children: .contain).accessibilityLabel(L("sheet.quick.setup"))
            special
        }
    }

    private var total: Int { draft.sources.filter(\.checked).compactMap(\.tokens).reduce(0, +) }
    private var tooMuch: Bool { total > SheetRoutes.window(draft.route) - 12_000 }

    private var peopleRow: some View {
        let theirs = PeopleSides.summary(draft.theirs.map(\.name)), ours = PeopleSides.summary(draft.ours.map(\.name))
        let line = theirs.isEmpty && ours.isEmpty ? L("sheet.quick.noPeople")
            : theirs.isEmpty ? L("sheet.quick.peopleOurs", ["ours": ours])     // 0.14.0: an internal call, one side
            : L("sheet.quick.peopleLine", ["theirs": theirs, "ours": ours.isEmpty ? "-" : ours])
        return summaryRow("people", L("sheet.quick.people"), line, ok: true) { SheetPeopleView(draft: draft).padding(.top, 4) }
    }

    private var sourcesRow: some View {
        let checked = draft.sources.filter(\.checked)
        let bad = checked.filter { ["denied", "unsupported"].contains($0.access) }
        let line = checked.isEmpty ? L("sheet.ui.quick.noSources") : PeopleSides.summary(checked.map(\.title), first: 3)
        let problem: String? = checked.isEmpty ? L("sheet.ui.quick.noSourcesSub")
            : bad.isEmpty ? nil : bad.map { $0.title + ": " + ($0.reason ?? SheetLabels.access(source: $0)) }.joined(separator: "; ")
        return summaryRow("sources", L("sheet.ui.row.sources"), line, ok: problem == nil, problem: problem,
                          fixLabel: checked.isEmpty ? L("sheet.ui.quick.add") : (bad.isEmpty ? nil : L("sheet.ui.fix")),
                          fix: { if checked.isEmpty { draft.chooseFiles() } else { draft.mode = .expert; draft.step = 3 } }) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(checked) { src in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(src.title).font(PN.Font.body).foregroundStyle(PN.C.text).lineLimit(1).truncationMode(.middle)
                        if let f = src.folder { Text(SheetLabels.folderLine(f)).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true) }
                    }
                }
                Button(L("sheet.quick.addMore")) { draft.chooseFiles() }.buttonStyle(.pnTertiary)
            }
        }
    }

    private var setupRow: some View {
        let routeProblem = SheetRoutes.problem(draft.route)
        let project = m.target.isEmpty ? nil : m.targetName
        let line = ([project, draft.preset?.name ?? draft.presetID, liveLine] as [String?]).compactMap { $0 }.joined(separator: " · ")
        let problem: String? = m.target.isEmpty ? L("call.chooseProject") : (routeProblem ?? (tooMuch ? L("sheet.ui.size.tooMuch") : nil))
        return summaryRow("setup", L("sheet.quick.setup"), line, ok: problem == nil, problem: problem,
                          fixLabel: routeProblem != nil || (tooMuch && !m.target.isEmpty) ? L("sheet.ui.fix") : nil,
                          fix: { draft.mode = .expert; draft.step = 4 }) {
            VStack(alignment: .leading, spacing: 8) {
                projectRow
                meetingRows
                row(L("sheet.ui.row.preset"), draft.preset?.name ?? draft.presetID,
                    (draft.preset?.blocks ?? []).map { SheetLibrary.shared.title($0) }.prefix(5).joined(separator: ", "), ok: true, fix: nil)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(L("sheet.ui.row.size")).font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.text3).frame(width: Self.quickLabelW, alignment: .leading)
                    Text(L(tooMuch ? "sheet.ui.size.tooMuch" : "sheet.ui.size.fits") + " · " + L("sheet.quick.runsOn", ["route": AIRoute.name(draft.route)]))
                        .font(PN.Font.body).foregroundStyle(tooMuch ? PN.C.pending : PN.C.text)
                        .help(L("sheet.ui.quick.size", ["t": SheetLabels.tokens(total), "route": AIRoute.name(draft.route)]))
                }
            }
        }
    }

    private func summaryRow<C: View>(_ id: String, _ label: String, _ line: String, ok: Bool, problem: String? = nil,
                                     fixLabel: String? = nil, fix: @escaping () -> Void = {}, @ViewBuilder detail: () -> C) -> some View {
        let on = open == id
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                // 0.25 (R3b, board QP): a square status mark (a dot in Classic), the mono label, the line at 16
                RoundedRectangle(cornerRadius: th.statusSquare ? 0 : 5).fill(ok ? PN.C.ready : PN.C.pendingFill)
                    .frame(width: 10, height: 10).padding(.top, 6).accessibilityHidden(true)
                PrepFieldLabel(text: label).frame(width: 72, alignment: .leading).padding(.top, 4)
                VStack(alignment: .leading, spacing: 3) {
                    Text(line).font(th.homeText(16)).foregroundStyle(PN.C.text).lineLimit(1).truncationMode(.tail)
                    if let problem {
                        Text(problem).font(th.homeText(14, .semibold)).foregroundStyle(PN.C.pending).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if let fixLabel { Button(fixLabel, action: fix).buttonStyle(.pnSecondary) }
                Button(L(on ? "sheet.quick.done" : "sheet.quick.change")) { withAnimation(.easeOut(duration: 0.15)) { open = on ? nil : id } }
                    .buttonStyle(.pnTertiary)
                    .accessibilityLabel(L(on ? "sheet.quick.done" : "sheet.quick.change") + " " + label)
            }
            if on { detail().padding(.leading, 94) }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { if id != "people" { Rectangle().fill(PN.C.rule).frame(height: 1) } }
        .accessibilityValue(ok ? L("sheet.ui.ok") : L("sheet.ui.needsYou"))
    }

    @ViewBuilder private var special: some View {
        VStack(alignment: .leading, spacing: 4) {
            if draft.live {
                (Text(L("sheet.quick.whatChanged")).font(PN.Font.body.weight(.semibold))
                 + Text("  " + L("sheet.ui.quick.mattersSub")).font(PN.Font.caption).foregroundColor(PN.C.text3))
                TextField(L("sheet.ui.quick.specialPh"), text: $draft.special).textFieldStyle(.plain).font(th.homeText(15)).prepField(height: 36)
            } else {
                // 0.24.1 (F5, decision 6): the same "What matters on this call" as the Start call form, the call's context
                WhatMattersField(model: m, draft: draft)
            }
            ForEach(draft.linksInText, id: \.self) { l in SheetLinkSuggestion(draft: draft, link: l) }
        }
    }

    /// Theme pass stage 2 (prototype "Get ready"): Cancel on the left; "No time?", Start without prep and
    /// Prepare brief on the right, in a band under the form.
    @ViewBuilder private var footer: some View {
        let routeProblem = SheetRoutes.problem(draft.route)
        VStack(alignment: .leading, spacing: 8) {
            CallReadyBanner()        // 0.24.1 (F6): no start without the base set; transcript only without an AI
            if !draft.remembered {
                Label(L("sheet.ui.quick.remember", ["title": m.effectiveTitle]), systemImage: "arrow.triangle.2.circlepath").font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
            if !draft.note.isEmpty { Text(draft.note).font(PN.Font.caption).foregroundStyle(PN.C.pending).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 12) {
                HomeLink(L("common.cancel")) { SheetPrepWindow.close(m) }.keyboardShortcut(.cancelAction)
                Spacer()
                if !draft.live {
                    Text(L("sheet.ui.quick.noTime")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                        .multilineTextAlignment(.trailing).frame(maxWidth: 200, alignment: .trailing).fixedSize(horizontal: false, vertical: true)
                }
                if draft.live {
                    // 0.10.1 (A4): the old one-click run stays, as the second action
                    Button(L("sheet.ui.live.same")) {
                        if let e = LivePrep.start() { draft.note = e } else { SheetPrepWindow.close(m) }
                    }.buttonStyle(.pnSecondary).help(L("sheet.ui.live.sameHelp"))
                } else {
                    Button(L("sheet.ui.startWithout")) { startCall() }.buttonStyle(.pnSecondary)
                        .disabled(ready.blocked)
                }
                Button(L("sheet.ui.quick.prepareBrief", ["n": "\(draft.estimateSeconds)"])) { if let e = draft.build() { draft.note = e } }
                    .buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction).disabled(routeProblem != nil || draft.checking)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PN.C.surface2)
        .overlay(alignment: .top) { Rectangle().fill(PN.C.rule).frame(height: 1) }
    }

    /// 0.14.0 (D1 smoke): one label column for the rows under Change; 70 pt wrapped "Meeting name" / "Назва зустрічі".
    static let quickLabelW: CGFloat = 100

    /// 0.10.1 (A5, roadmap п.7): Quick with a minimal setup: name, date and time, people, the same fields as Expert.
    @ViewBuilder private var meetingRows: some View {
        quickField(L("sheet.ui.s1.name")) {
            TextField(m.effectiveTitle, text: Binding(get: { m.title }, set: { m.title = $0; draft.objectWillChange.send() }))
                .textFieldStyle(.plain).font(th.homeText(15)).prepField(height: 32).frame(minWidth: 300, maxWidth: 420)
        }
        quickField(L("sheet.ui.s1.when")) {
            DatePicker("", selection: Binding(get: { m.callDate }, set: { m.callDate = $0; draft.objectWillChange.send() })).labelsHidden().fixedSize()
        }
    }

    private func quickField<C: View>(_ k: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(k).font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.text3).frame(width: Self.quickLabelW, alignment: .leading)
            c()
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    /// 0.10.1 (A5): no "Ok" when nothing is there to read: what the sheet will rest on, and Add.
    private var noSourcesRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(L("sheet.ui.row.sources")).font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.text3).frame(width: Self.quickLabelW, alignment: .leading).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("sheet.ui.quick.noSources")).font(PN.Font.body).foregroundStyle(PN.C.text)
                Text(L("sheet.ui.quick.noSourcesSub")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Label(L("sheet.ui.quick.thin"), systemImage: "circle.dashed")
                .font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.pending).fixedSize()
            Button(L("sheet.ui.quick.add")) { draft.chooseFiles() }.buttonStyle(.pnSecondary)
        }
        .padding(.vertical, 2)
    }

    /// A1 (2026-11-14): "Start a call now" lands here with no project; the picker is the same as Expert step 1.
    private var projectRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(L("sheet.ui.s1.project")).font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.text3).frame(width: Self.quickLabelW, alignment: .leading)
            Picker("", selection: Binding(get: { m.target }, set: { m.target = $0; m.applyProjectDefaults(); draft.note = ""; draft.objectWillChange.send() })) {
                if m.target.isEmpty { Text(L("call.chooseProject")).tag("") }
                ForEach(m.registry.workspaces, id: \.name) { w in Text(w.name).tag("workspace:" + w.name) }
                ForEach(m.registry.projects.filter { $0.status != "archived" }, id: \.slug) { p in Text(p.name).tag("project:" + p.slug) }
            }.labelsHidden().fixedSize()
            Spacer()
            if m.target.isEmpty {
                Label(L("sheet.ui.needsYou"), systemImage: "exclamationmark.triangle.fill")
                    .font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.pending).fixedSize()
            }
        }
        .padding(.vertical, 2)
    }

    /// 0.10.0 (Meeting Sheet, folders): folder lines are long, one per line; plain titles stay comma-separated.
    private var s3Sep: String { draft.sources.filter(\.checked).prefix(3).contains { $0.folder != nil } ? "\n" : ", " }

    private var liveLine: String {
        var parts = [m.callType == "presentation" ? L("start.type.presentation") : m.callType == "interview" ? L("callSettings.type.interview") : L("sheet.ui.live.regular")]
        if m.salesActive { parts.append(L("page.salesMode")) }
        return parts.joined(separator: " · ")
    }

    private func row(_ k: String, _ v: String, _ sub: String, ok: Bool, fix: String?, add: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(k).font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.text3).frame(width: Self.quickLabelW, alignment: .leading).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(v).font(PN.Font.body).foregroundStyle(PN.C.text)
                if !sub.isEmpty { Text(sub).font(PN.Font.caption).foregroundStyle(ok ? PN.C.text3 : PN.C.pending).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer()
            Label(ok ? L("sheet.ui.ok") : L("sheet.ui.needsYou"), systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(PN.Font.caption.weight(.semibold)).foregroundStyle(ok ? PN.C.turn : PN.C.pending).fixedSize()
            if add { Button(L("sheet.ui.quick.add")) { draft.chooseFiles() }.buttonStyle(.pnTertiary) }      // 0.10.1 (A5)
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
    /// 0.10.0 (Meeting Sheet, folders): "12 recent files for the preparation (last 7 days) · 340 searchable during the call".
    static func folderLine(_ i: SheetFolderInfo) -> String {
        let l = SheetFolders.line(i, days: SheetPrefs.storedFolderDays)
        var s = L(l.key, l.args)
        if (i.overBudget ?? 0) > 0 { s += " · " + L("sheet.ui.folder.over", l.args) }
        return s
    }

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
/// 0.25 (R3b, board QP): flat sections under the heavy rule; building shows the share in the display face with the
/// spinner and what is left; a failed build says why and offers the other AI route when one is ready.
struct SheetQuickDone: View {
    @ObservedObject var draft: SheetDraft
    @ObservedObject var job: SheetJob
    @ObservedObject private var runner = SheetRunner.shared
    @Environment(\.pnTheme) private var th

    var body: some View {
        if job.done, let p = job.sheetPath, let s = SheetCache.shared.load(p) {
            done(s)
        } else if let e = job.failed {
            failed(e)
        } else if let sw = runner.pendingSwitch, sw.callID == draft.model.id {
            failed(sw.reason, switchTo: sw.to)
        } else {
            building
        }
    }

    private func done(_ s: MeetingSheet) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                Text(L("qp.sheet")).pnSection().foregroundStyle(PN.C.text).accessibilityAddTraits(.isHeader)
                SheetReadinessTag(badge: s.readinessBadge)
                Spacer(minLength: 8)
                Text(builtLine(s)).font(th.homeMono(11)).foregroundStyle(PN.C.text3).lineLimit(1)
            }
            .padding(.top, 12).padding(.bottom, 10)
            ForEach(s.shownBlocks.prefix(4)) { b in
                HStack(alignment: .top, spacing: 14) {
                    Text(b.title).font(th.homeText(13, .semibold)).foregroundStyle(PN.C.text3).frame(width: 150, alignment: .leading).padding(.top, 2)
                    Text(b.facts.filter { $0.supersededBy == nil }.prefix(2).map(\.text).joined(separator: "\n"))      // 0.10.0 (smoke): no replaced values
                        .font(th.homeText(15)).foregroundStyle(PN.C.text).lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .pageRow(10)
            }
            footer {
                Button(L("sheet.ui.quick.openFull")) {
                    SheetPrepWindow.close(draft.model)
                    UpcomingCallPage.openTab[draft.model.id.uuidString] = "sheet"
                    UpcomingPages.open(draft.model)
                }.buttonStyle(.pnSecondary)
                Spacer()
                Button {
                    if let app = NSApp.delegate as? AppDelegate, app.launch(draft.model) == nil { SheetPrepWindow.close(draft.model) }
                } label: {
                    HStack(spacing: 8) {
                        Text(L("home.startCall"))
                        Text("↵").font(th.homeMono(11)).accessibilityHidden(true)
                    }
                }
                .buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .overlay(alignment: .top) { Rectangle().fill(PN.C.ruleStrong).frame(height: th.ruleHeavy) }
    }

    /// "built in 38 s · 6 sources read"
    private func builtLine(_ s: MeetingSheet) -> String {
        let secs = max(1, Int((job.finishedAt ?? Date()).timeIntervalSince(job.started)))
        let took = secs < 90 ? L("qp.took.s", ["n": "\(secs)"]) : L("qp.took.m", ["m": "\(secs / 60)", "s": "\(secs % 60)"])
        let read = s.sources.filter { $0.access == .ok }.count
        return th.style == .classic ? L("qp.built", ["took": took, "n": "\(read)"]) : L("qp.built", ["took": took, "n": "\(read)"]).uppercased()
    }

    private func failed(_ why: String, switchTo: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Text("!").font(th.homeMono(15, .semibold)).foregroundStyle(PN.C.pending)
                    .frame(width: 26, height: 26)
                    .background(PN.C.pendingFill.opacity(0.18))
                    .overlay(Rectangle().strokeBorder(PN.C.pending, lineWidth: 1.5))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("qp.failed.title")).font(th.homeText(17, .semibold)).foregroundStyle(PN.C.text).accessibilityAddTraits(.isHeader)
                    Text(why).font(th.homeText(15)).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
                    if let to = switchTo {
                        Text(L("qp.failed.other", ["route": AIRoute.name(to)])).font(th.homeText(15)).foregroundStyle(PN.C.text).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            footer {
                Button(L("sheet.ui.build.again")) { if switchTo != nil { runner.declineSwitch() }; draft.job = nil }.buttonStyle(.pnSecondary)
                Spacer()
                Button(L("sheet.ui.startWithout")) {
                    if switchTo != nil { runner.declineSwitch() }
                    if let app = NSApp.delegate as? AppDelegate, app.launch(draft.model) == nil { SheetPrepWindow.close(draft.model) }
                }.buttonStyle(.pnSecondary)
                if let to = switchTo {
                    Button(L("qp.failed.buildOn", ["route": AIRoute.name(to)])) { runner.acceptSwitch() }
                        .buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.top, 14)
        .overlay(alignment: .top) { Rectangle().fill(PN.C.pending).frame(height: th.ruleHeavy) }
    }

    private var building: some View {
        let pct = Int((job.progress * 100).rounded())
        let left = max(5, Int(Double(draft.estimateSeconds) * (1 - job.progress)))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                PNSpinner(size: 40)
                Text("\(pct)%").font(th.homeDisplay(th.bigNum, th.heroWeight)).tracking(th.numTrack * th.bigNum).monospacedDigit()
                    .foregroundStyle(PN.C.text).accessibilityHidden(true)
                Text(job.stage.isEmpty ? L("sheet.ui.build.starting") : job.stage).font(th.homeText(16)).foregroundStyle(PN.C.text)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Rectangle().fill(PN.C.rule).frame(height: 8)
                .overlay(alignment: .leading) {
                    GeometryReader { g in Rectangle().fill(PN.C.accentFill).frame(width: max(0, min(1, job.progress)) * g.size.width) }
                }
                .accessibilityElement().accessibilityLabel(L("qp.building.a11y")).accessibilityValue("\(pct)%")
            Text(L("qp.building.left", ["n": "\(left)", "route": AIRoute.name(draft.route)])).font(th.homeText(14)).foregroundStyle(PN.C.text3)
                .fixedSize(horizontal: false, vertical: true)
            footer {
                Button(L("call.stop")) { job.stop() }.buttonStyle(.pnTertiary)
                Spacer()
                Button(L("sheet.ui.build.closeNotify")) { job.notifyWhenDone = true; SheetPrepWindow.close(draft.model) }.buttonStyle(.pnSecondary)
            }
        }
        .padding(.top, 14)
        .overlay(alignment: .top) { Rectangle().fill(PN.C.ruleStrong).frame(height: th.ruleHeavy) }
    }

    private func footer<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 10) { c() }
            .padding(.top, 14)
            .overlay(alignment: .top) { Rectangle().fill(PN.C.rule).frame(height: 1) }
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
        .padding(8).background(RoundedRectangle(cornerRadius: PN.r(8)).fill(PN.C.accent.opacity(0.06)))
    }
}

// MARK: - Expert (S1-S5)

/// 0.25 (R3c-2, boards EA/EB): the number in a square frame, a passed step ticked, the open one on the selection
/// plate with a 3 pt line under it.
struct SheetStepBar: View {
    @ObservedObject var draft: SheetDraft
    @Environment(\.pnTheme) private var th

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { n in
                let on = draft.step == n, done = n < draft.step
                let shape = RoundedRectangle(cornerRadius: th.style == .classic ? 4 : 0)
                Button {
                    draft.step = n
                    if n == 4 { draft.checkSize() }
                } label: {
                    HStack(spacing: 7) {
                        ZStack {
                            shape.fill(on ? PNSelect.fill : Color.clear)
                            if !on { shape.strokeBorder(done ? PN.C.turn : PN.C.text2, lineWidth: 1) }
                            if done && !on {
                                Image(systemName: "checkmark").font(PN.sys(9, .bold)).foregroundStyle(PN.C.turn)
                            } else {
                                Text("\(n)").font(th.homeMono(11, .semibold)).foregroundStyle(on ? PNSelect.ink : PN.C.text2)
                            }
                        }
                        .frame(width: 18, height: 18)
                        Text(L("sheet.ui.step.\(n)")).font(th.homeText(14, on ? .semibold : .regular))
                            .foregroundStyle(on ? PN.C.text : PN.C.text2).lineLimit(1)
                    }
                    .padding(.horizontal, 8).frame(height: 50)
                    .overlay(alignment: .bottom) { if on { Rectangle().fill(PN.C.text).frame(height: 3) } }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(n == 5 && draft.job == nil)
                .accessibilityLabel(L("sheet.ui.step.\(n)"))
                .accessibilityValue(done ? L("ea.step.done") : "")
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : [.isButton])
            }
        }
    }
}

struct SheetExpertView: View {
    @ObservedObject var draft: SheetDraft
    @Environment(\.pnTheme) private var th

    var body: some View {
        Group {
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
                    // Board: "Preset: Sales intro · 12 blocks" in mono; the count is the blocks the sheet shows.
                    Text(L("sheet.ui.footer.preset", ["name": draft.preset?.name ?? draft.presetID, "n": "\(draft.blocks.filter(\.visible).count)"]))
                        .font(th.style == .classic ? PN.Font.caption : th.homeMono(11)).foregroundStyle(PN.C.text3)
                    Spacer()
                    Button(L("common.cancel")) { SheetPrepWindow.close(draft.model) }.buttonStyle(.pnTertiary).keyboardShortcut(.cancelAction)
                    // 2026-11-13 (owner): Plan a call opens here; Save keeps the call in Up next without preparing it
                    Button(L("common.save")) {
                        let m = draft.model
                        guard !m.target.isEmpty else { draft.note = L("call.needProject"); draft.step = 1; return }
                        if m.context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !draft.goal.isEmpty { m.context = draft.goal }
                        UpNext.shared.save(m)
                        SheetPrepWindow.close(m)
                    }.buttonStyle(.pnSecondary)
                    if draft.step > 1 { Button(L("sheet.ui.back")) { draft.step -= 1 }.buttonStyle(.pnSecondary) }
                    next
                }
                .padding(.horizontal, 24).padding(.vertical, 12).background(PN.C.bg)
            }
        }
    }
        .trackScreen("sheet_expert", sub: "\(draft.step)")
    }

    /// The main button carries "↵" outside Classic, as on the boards (Return presses it).
    private func nextLabel(_ key: String) -> String { L(key) + (th.style == .classic ? "" : "  ↵") }

    @ViewBuilder private var next: some View {
        switch draft.step {
        case 1: Button(nextLabel("sheet.ui.next.blocks")) { draft.step = 2 }.buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
        case 2: Button(nextLabel("sheet.ui.next.sources")) { draft.step = 3; draft.loadCandidates() }.buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
        case 3: Button(nextLabel("sheet.ui.next.size")) { draft.step = 4; draft.checkSize() }.buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
        default:
            Button(nextLabel("sheet.ui.build")) {
                if let e = draft.build() { draft.note = e } else { draft.step = 5 }
            }
            .buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
            .disabled(draft.size?.state == .tooMuch && draft.plan.isEmpty || SheetRoutes.problem(draft.route) != nil)
        }
    }
}

// MARK: S1 Meeting

/// 0.25 (R3c-2, board EA step 1): event or not, Meeting name / When / Project in one row, the kind of meeting as
/// chips, what matters (the 0.24 field, decision 19.11), who is on the call, then Sheet language and Remind me.
struct SheetMeetingStep: View {
    @ObservedObject var draft: SheetDraft
    @ObservedObject var lib = SheetLibrary.shared
    @Environment(\.pnTheme) private var th
    private var m: StartCallModel { draft.model }

    var body: some View {
        VStack(alignment: .leading, spacing: 36) {      // 0.26.0 (owner 19.11): more room between the sections
            VStack(alignment: .leading, spacing: 16) {
                PrepPageHead(title: L("sheet.ui.s1.title"), sub: L("sheet.ui.s1.sub"))
                HStack(alignment: .center, spacing: 14) {
                    // 0.25 (QA): without an event the choice was a disabled, unreadable switch; the note says it alone
                    if m.calEventID != nil {
                        PrepChoice(selection: $draft.withEvent, options: [
                            (true, L("sheet.ui.s1.fromCalendar")),
                            (false, L("sheet.ui.s1.noEvent"))
                        ])
                    }
                    Text(draft.withEvent && m.calEventID != nil ? L("sheet.ui.s1.event") : L("sheet.ui.s1.noEventNote"))
                        .font(th.homeText(13)).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .top, spacing: 14) {
                    labeled(L("sheet.ui.s1.name")) {
                        TextField(m.effectiveTitle, text: Binding(get: { m.title }, set: { m.title = $0 }))
                            .textFieldStyle(.plain).font(th.homeText(15)).prepField(height: 36)
                            .accessibilityLabel(L("sheet.ui.s1.name"))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    labeled(L("sheet.ui.s1.when")) {
                        DatePicker("", selection: Binding(get: { m.callDate }, set: { m.callDate = $0 }))
                            .datePickerStyle(.field).labelsHidden().font(th.homeText(15)).prepField(height: 36)
                            .accessibilityLabel(L("sheet.ui.s1.when"))
                    }
                    .fixedSize()
                    labeled(L("sheet.ui.s1.project")) {
                        PrepMenuField(value: m.target.isEmpty ? L("call.chooseProject") : m.targetName) {
                            ForEach(m.registry.workspaces, id: \.name) { w in
                                Button(w.name) { m.target = "workspace:" + w.name; m.applyProjectDefaults(); draft.objectWillChange.send() }
                            }
                            ForEach(m.registry.projects.filter { $0.status != "archived" }, id: \.slug) { p in
                                Button(p.name) { m.target = "project:" + p.slug; m.applyProjectDefaults(); draft.objectWillChange.send() }
                            }
                        }
                        .accessibilityLabel(L("sheet.ui.s1.project"))
                    }
                    .fixedSize()
                }
            }
            kind
            VStack(alignment: .leading, spacing: 10) {
                PrepSectionHead(number: nil, title: L("call.whatMatters"))
                // 0.24.1 (F5, decision 6): one field for the goal and what matters, the call's context (as in Start call)
                WhatMattersField(model: m, draft: draft, showLabel: false)
                ForEach(draft.linksInText, id: \.self) { l in SheetLinkSuggestion(draft: draft, link: l) }
            }
            VStack(alignment: .leading, spacing: 12) {
                PrepSectionHead(number: nil, title: L("sheet.people.title"))
                SheetPeopleView(draft: draft, head: false)      // 0.14.0 (D1)
            }
            HStack(alignment: .top, spacing: 28) {
                labeled(L("sheet.ui.s1.language")) {
                    PrepMenuField(value: L(draft.language == "uk" ? "sheet.ui.lang.uk" : "sheet.ui.lang.en")) {
                        Button(L("sheet.ui.lang.en")) { draft.language = "en" }
                        Button(L("sheet.ui.lang.uk")) { draft.language = "uk" }
                    }
                    .accessibilityLabel(L("sheet.ui.s1.language"))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                labeled(L("sheet.ui.s1.remind")) {
                    PrepMenuField(value: remindName(draft.remind)) {
                        ForEach([30, 60, 0] + ([0, 30, 60].contains(draft.remind) ? [] : [draft.remind]), id: \.self) { n in
                            Button(remindName(n)) { draft.remind = n }
                        }
                    }
                    .accessibilityLabel(L("sheet.ui.s1.remind"))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func remindName(_ n: Int) -> String {
        switch n {
        case 0: return L("sheet.ui.remind.off")
        case 30: return L("sheet.ui.remind.30")
        case 60: return L("sheet.ui.remind.60")
        default: return L("sheet.ui.remind.n", ["n": "\(n)"])
        }
    }

    private func labeled<C: View>(_ t: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            PrepFieldLabel(text: t)
            c()
        }
    }

    /// The kind of meeting as chips (name and mode), the suggestion under them, then my presets.
    private var kind: some View {
        let mine = lib.presets.filter(\.mine)
        return VStack(alignment: .leading, spacing: 12) {
            PrepSectionHead(number: nil, title: L("sheet.ui.s1.kind"), note: L("sheet.ui.s1.kindSub"))
            FlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(lib.presets.filter { !$0.mine }) { p in presetChip(p) }
            }
            if !mine.isEmpty {
                PrepFieldLabel(text: L("sheet.ui.s1.myPresets")).padding(.top, 2)
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(mine) { p in presetChip(p) }
                }
            }
            let line = (draft.presetSuggested ? L("sheet.ui.s1.suggested", ["name": draft.preset?.name ?? draft.presetID]) + " " : "")
                + (mine.isEmpty ? L("ea.s1.mineNone") : "")
            if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(line).font(th.homeText(13)).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func presetChip(_ p: SheetPresetInfo) -> some View {
        let on = draft.presetID == p.id
        return PrepChip(on: on, action: { draft.applyPreset(p.id); draft.presetSuggested = false }) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(p.name).font(th.homeText(15, .semibold)).lineLimit(1)
                Text(p.mode == "expert" ? L("ea.s1.mode.expert") : L("ea.s1.mode.quick")).font(th.homeMono(10)).opacity(0.7)
            }
        }
        .help(L("sheet.ui.s1.blocks", ["n": "\(p.blocks.count)"]) + " · " + (p.mode == "expert" ? L("sheet.ui.expert") : L("sheet.ui.quick")))
    }
}

// MARK: S2 Blocks

/// 0.25 (R3c-2, board EA step 2): My focus on top, the shown blocks (drag to reorder), the hidden ones crossed out,
/// + Add a block; on the right what Ready means for this preset and Save as my preset right on the page.
struct SheetBlocksStep: View {
    @ObservedObject var draft: SheetDraft
    @ObservedObject var lib = SheetLibrary.shared
    @ObservedObject var prefs = SheetPrefs.shared
    @Environment(\.pnTheme) private var th
    @State private var presetName = ""
    @State private var suggestNew = false
    @State private var saveNote = ""
    @State private var saved = ""
    @State private var adding = false
    /// 0.26.0 (owner 19.11): a row with the block's title and what the preparation puts in it (rules/meeting-sheet.yaml fields)
    private static let rowH: CGFloat = 60

    /// The header and My focus are not rows on the board: the header is always there, My focus has its own plate.
    private static let fixed: Set<String> = ["header", "my_focus"]
    private var shown: [DraftBlock] { draft.blocks.filter { $0.visible && !Self.fixed.contains($0.type) } }
    private var hidden: [DraftBlock] { draft.blocks.filter { !$0.visible && !Self.fixed.contains($0.type) } }
    private var focusShown: Bool { draft.blocks.contains { $0.type == "my_focus" && $0.visible } }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PrepPageHead(title: L("sheet.ui.s2.title"), sub: L("sheet.ui.s2.sub", ["name": draft.preset?.name ?? draft.presetID]))
            // 0.26.0 (owner 19.11): what a block is, what happens to one that is hidden or not added, what "Only if there is data" does
            Text(L("sheet.ui.s2.how")).font(th.homeText(14)).foregroundStyle(PN.C.text2)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 680, alignment: .leading)
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 28) {
                    focusPlate
                    shownList
                    if !hidden.isEmpty { hiddenList }
                    addBlock
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 22) {
                    readyMeans
                    saveBox
                }
                .frame(width: 270, alignment: .topLeading)
            }
        }
    }

    private func bind(_ id: String) -> Binding<DraftBlock> {
        Binding(get: { draft.blocks.first { $0.id == id } ?? DraftBlock(type: id, title: id) },
                set: { v in if let i = draft.blocks.firstIndex(where: { $0.id == id }) { draft.blocks[i] = v } })
    }

    /// Reorders the shown blocks among their own places; hidden and fixed blocks keep theirs.
    private func moveShown(_ from: IndexSet, _ to: Int) {
        var ids = shown.map(\.id)
        ids.move(fromOffsets: from, toOffset: to)
        let slots = draft.blocks.indices.filter { draft.blocks[$0].visible && !Self.fixed.contains(draft.blocks[$0].type) }
        let byID = Dictionary(draft.blocks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var b = draft.blocks
        for (k, slot) in slots.enumerated() where k < ids.count { if let x = byID[ids[k]] { b[slot] = x } }
        draft.blocks = b
    }

    private var focusPlate: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(L("sheet.ui.myFocus")).pnSection().foregroundStyle(PN.C.text).accessibilityAddTraits(.isHeader)
                Text(L("sheet.ui.s2.focusSub")).font(th.homeText(13)).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            }
            Text(prefs.focus.isEmpty ? L("ea.s2.focusNone") : prefs.focus.joined(separator: " · ")).font(th.homeText(15)).foregroundStyle(PN.C.text)
            PrepLink(text: L("sheet.ui.s2.focusEdit")) { SettingsWindow.show(tab: "sheet") }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PN.C.surface2)
        .overlay(alignment: .top) { Rectangle().fill(PN.C.ruleStrong).frame(height: th.ruleHeavy) }
        .opacity(focusShown ? 1 : 0.6)
    }

    private var shownList: some View {
        let list = shown
        return VStack(alignment: .leading, spacing: 0) {
            PrepSectionHead(number: nil, title: L("ea.s2.shown"),
                            note: L(focusShown ? "ea.s2.shownCountFocus" : "ea.s2.shownCount", ["n": "\(list.count)"]), mono: true)
            List {
                ForEach(list) { b in
                    blockRow(bind(b.id))
                        .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
                }
                .onMove { moveShown($0, $1) }
            }
            .listStyle(.plain).scrollContentBackground(.hidden).scrollDisabled(true)
            .environment(\.defaultMinListRowHeight, Self.rowH + 1)
            .frame(height: CGFloat(max(1, list.count)) * (Self.rowH + 1))
        }
    }

    private func blockRow(_ b: Binding<DraftBlock>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").font(PN.sys(11)).foregroundStyle(PN.C.text3).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(b.wrappedValue.title).font(th.homeText(15, .semibold)).foregroundStyle(PN.C.text).lineLimit(1)
                if let f = lib.blockFields[b.wrappedValue.type], !f.isEmpty {
                    Text(f).font(th.homeText(12)).foregroundStyle(PN.C.text3).lineLimit(2).help(f)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 8)
            if b.wrappedValue.type == "qualification" {
                PrepMenuField(value: SalesMethods.shared.label(b.wrappedValue.method ?? "bant")) {
                    ForEach(lib.methods, id: \.self) { k in Button(SalesMethods.shared.label(k)) { b.wrappedValue.method = k } }   // S1: names, not keys
                }
                .onAppear { SalesMethods.shared.load() }
            }
            Toggle(L("sheet.ui.s2.onlyIfData"), isOn: b.onlyIfData).toggleStyle(.pnCheckbox).font(th.homeText(13)).foregroundStyle(PN.C.text2)
                .fixedSize().help(L("sheet.ui.s2.onlyIfDataHelp"))
            Button { b.wrappedValue.visible = false } label: {
                Image(systemName: "eye").foregroundStyle(PN.C.text2).frame(width: 22, height: 22)
            }
            .buttonStyle(.plain).help(L("sheet.ui.s2.hide")).accessibilityLabel(L("sheet.ui.s2.hide") + ": " + b.wrappedValue.title)
        }
        .frame(height: Self.rowH)
        .overlay(alignment: .top) { Rectangle().fill(PN.C.rule).frame(height: 1) }
    }

    private var hiddenList: some View {
        VStack(alignment: .leading, spacing: 0) {
            PrepSectionHead(number: nil, title: L("sheet.ui.s2.hidden"), note: "\(hidden.count)", mono: true)
            ForEach(hidden) { b in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(b.title).font(th.homeText(15)).strikethrough().foregroundStyle(PN.C.text3).lineLimit(1)
                        if let f = lib.blockFields[b.type], !f.isEmpty {
                            Text(f).font(th.homeText(12)).foregroundStyle(PN.C.text3).lineLimit(2).help(f)
                        }
                    }
                    .padding(.leading, 21)
                    Spacer(minLength: 8)
                    Button { bind(b.id).wrappedValue.visible = true } label: {
                        Image(systemName: "eye.slash").foregroundStyle(PN.C.text3).frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain).help(L("sheet.ui.s2.show")).accessibilityLabel(L("sheet.ui.s2.show") + ": " + b.title)
                }
                .frame(height: Self.rowH)
                .overlay(alignment: .top) { Rectangle().fill(PN.C.rule).frame(height: 1) }
            }
        }
    }

    /// 0.26.0 (owner 19.11): Add a block lists every free block with what it holds (a menu showed titles only).
    private var addBlock: some View {
        let free = BlockType.known.map(\.rawValue).filter { t in !Self.fixed.contains(t) && !draft.blocks.contains { $0.type == t } }
        return Button { adding = true } label: {
            Text("+ " + L("sheet.ui.s2.add")).font(th.homeText(13, .semibold)).underline().foregroundStyle(PN.C.text)
        }
        .buttonStyle(.plain).fixedSize()
        .disabled(free.isEmpty)
        .popover(isPresented: $adding, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                Text(L("sheet.ui.s2.addHint")).font(th.homeText(12)).foregroundStyle(PN.C.text3)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 14).padding(.vertical, 10)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(free, id: \.self) { t in
                            Button {
                                draft.blocks.append(DraftBlock(type: t, title: lib.title(t), method: t == "qualification" ? "bant" : nil))
                                adding = false
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(lib.title(t)).font(th.homeText(14, .semibold)).foregroundStyle(PN.C.text)
                                    Text(lib.blockFields[t] ?? "").font(th.homeText(12)).foregroundStyle(PN.C.text2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .overlay(alignment: .top) { Rectangle().fill(PN.C.rule).frame(height: 1) }
                            .accessibilityLabel(lib.title(t) + ". " + (lib.blockFields[t] ?? ""))
                        }
                    }
                }
                .frame(maxHeight: 440)
            }
            .frame(width: 420)
            .background(PN.C.bg)
        }
    }

    @ViewBuilder private var readyMeans: some View {
        VStack(alignment: .leading, spacing: 0) {
            PrepSectionHead(number: nil, title: L("sheet.ui.s2.readyMeans"))
            let rules = draft.preset?.readiness ?? []
            if rules.isEmpty {
                Text(L("ea.s2.noRules")).font(th.homeText(13)).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true).pageRow(9)
            }
            ForEach(rules, id: \.self) { r in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    PrepTick().alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                    Text(ruleName(r)).font(th.homeText(14)).foregroundStyle(PN.C.text).fixedSize(horizontal: false, vertical: true)
                }
                .pageRow(8)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func ruleName(_ r: String) -> String { let k = "sheet.ui.rule." + r; let t = L(k); return t == k ? (lib.ruleGaps[r] ?? r) : t }

    private var saveBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("sheet.ui.s2.save")).font(th.homeText(15, .semibold)).foregroundStyle(PN.C.text).accessibilityAddTraits(.isHeader)
            TextField(L("sheet.ui.s2.name"), text: $presetName).textFieldStyle(.plain).font(th.homeText(14)).prepField(height: 32)
                .accessibilityLabel(L("sheet.ui.s2.name"))
            Toggle(L("sheet.ui.s2.suggestNew"), isOn: $suggestNew).toggleStyle(.pnCheckbox).font(th.homeText(13))
                .fixedSize(horizontal: false, vertical: true)
            Text(L("sheet.ui.s2.saveNote", ["n": "\(draft.blocks.filter(\.visible).count)"])).font(th.homeText(12)).foregroundStyle(PN.C.text3)
                .fixedSize(horizontal: false, vertical: true)
            if !saveNote.isEmpty { Text(saveNote).font(th.homeText(12, .semibold)).foregroundStyle(PN.C.pending).fixedSize(horizontal: false, vertical: true) }
            if !saved.isEmpty { Text(saved).font(th.homeText(12, .semibold)).foregroundStyle(PN.C.turn).fixedSize(horizontal: false, vertical: true) }
            Button(L("sheet.ui.s2.savePreset"), action: savePreset)
                .buttonStyle(.pnSecondary).disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: th.style == .classic ? PN.Radius.s : 0).strokeBorder(PN.C.field, lineWidth: 1.5))
    }

    private func savePreset() {
        let name = presetName.trimmingCharacters(in: .whitespaces)
        let req: [String: Any] = ["action": "save", "name": name, "blocks": draft.blocks.map(\.type),
                                  "hidden": draft.blocks.filter { !$0.visible }.map(\.type),
                                  "only_if_data": draft.blocks.filter(\.onlyIfData).map(\.type),
                                  "mode": draft.mode.rawValue, "readiness": draft.preset?.readiness ?? [], "base": draft.presetID,
                                  "method": draft.blocks.first { $0.type == "qualification" }?.method ?? "bant",
                                  "suggest_new_domains": suggestNew]
        saveNote = ""; saved = ""
        lib.change(req) { e in
            if let e { saveNote = e } else { saved = L("ea.s2.saved", ["name": name]); presetName = "" }
        }
    }
}

// MARK: S3 Sources

/// 0.25 (R3c-2, board EA step 3): two tiles (drop or choose files, paste a link or text), In this sheet with the
/// count and size, the LinkedIn card with its form, then the suggestions from the project folder.
struct SheetSourcesStep: View {
    @ObservedObject var draft: SheetDraft
    @Environment(\.pnTheme) private var th
    @State private var paste = ""
    @State private var dropping = false
    @State private var showAll = false
    @State private var canAdd = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PrepPageHead(title: L("sheet.ui.s3.title"), sub: L("sheet.ui.s3.sub"))
            ForEach(draft.linksInText, id: \.self) { l in SheetLinkSuggestion(draft: draft, link: l) }
            HStack(alignment: .top, spacing: 14) {
                dropTile.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                pasteTile.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .fixedSize(horizontal: false, vertical: true)
            inSheet
            ForEach($draft.sources) { $s in
                if s.type == "linkedin" || s.type == "linkedin_manual" { SheetLinkedInCard(draft: draft, source: $s) }
            }
            candidates
        }
        .onAppear { if draft.candidates.isEmpty { draft.loadCandidates() } }
    }

    private func addPaste() { draft.add(pasted: paste); paste = "" }

    private var dropTile: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("sheet.ui.s3.drop")).font(th.homeText(16, .semibold)).foregroundStyle(PN.C.text)
            Text(L("sheet.ui.s3.dropSub")).font(th.homeText(13)).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
            Button(L("sheet.ui.s3.choose")) { draft.chooseFiles() }.buttonStyle(.pnSecondary).padding(.top, 2)
        }
        .padding(14)
        .background(dropping ? PNSelect.fill.opacity(0.35) : Color.clear)
        .overlay(RoundedRectangle(cornerRadius: th.style == .classic ? PN.Radius.s : 0)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])).foregroundStyle(dropping ? PN.C.text : PN.C.field))
        .onDrop(of: [UTType.fileURL], isTargeted: $dropping) { items in
            for it in items {
                _ = it.loadObject(ofClass: URL.self) { u, _ in
                    guard let u else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { draft.add(paths: [u.path]) } }
                }
            }
            return true
        }
        .accessibilityElement(children: .contain)
    }

    private var pasteTile: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("ea.s3.pasteTitle")).font(th.homeText(16, .semibold)).foregroundStyle(PN.C.text)
            HStack(spacing: 8) {
                TextField(L("ea.s3.pastePh"), text: $paste).textFieldStyle(.plain).font(th.homeText(14)).prepField(height: 34)
                    .onSubmit(addPaste).accessibilityLabel(L("ea.s3.pasteTitle"))
                Button(L("sheet.ui.add"), action: addPaste).buttonStyle(.pnSecondary).disabled(paste.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            PrepLink(text: L("ea.s3.whatCanI")) { canAdd = true }
                .popover(isPresented: $canAdd, arrowEdge: .bottom) { whatYouCanAdd }
        }
        .padding(14)
        .overlay(RoundedRectangle(cornerRadius: th.style == .classic ? PN.Radius.s : 0).strokeBorder(PN.C.ruleStrong, lineWidth: 1.5))
    }

    private var inSheet: some View {
        let on = draft.sources.filter(\.checked)
        let tokens = on.compactMap(\.tokens).reduce(0, +)
        return VStack(alignment: .leading, spacing: 0) {
            PrepSectionHead(number: nil, title: L("ea.s3.inSheet"),
                            note: L("ea.s3.inSheetCount", ["n": "\(on.count)", "t": SheetSizeStep.short(tokens)]), mono: true)
            if draft.checking {
                HStack(spacing: 6) { PNSpinner(size: 16); Text(L("common.checking")).font(th.homeText(13)).foregroundStyle(PN.C.text2) }.pageRow(8)
            }
            ForEach($draft.sources) { $s in SheetDraftSourceRow(draft: draft, source: $s) }
            if draft.sources.isEmpty {
                Text(L("ea.s3.none")).font(th.homeText(13)).foregroundStyle(PN.C.text3).pageRow(10)
            }
            if !draft.hasLinkedIn {
                Text(L("sheet.ui.s3.noLinkedIn")).font(th.homeText(13)).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true).pageRow(10)
            }
        }
    }

    @ViewBuilder private var candidates: some View {
        let list = showAll ? draft.candidates : Array(draft.candidates.prefix(8))
        let ticked = draft.candidates.filter(\.checked).count
        VStack(alignment: .leading, spacing: 0) {
            PrepSectionHead(number: nil, title: L("sheet.ui.s3.fromFolder", ["name": draft.model.targetName]), note: draft.candidateNote, mono: true)
            ForEach(list) { c in
                let i = draft.candidates.firstIndex { $0.id == c.id }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if let i { Toggle("", isOn: $draft.candidates[i].checked).toggleStyle(.pnCheckbox).labelsHidden().accessibilityLabel(c.title) }
                    (Text(c.title).font(th.homeText(15)).foregroundStyle(PN.C.text)
                     + Text(c.why.isEmpty ? "" : " · " + c.why.joined(separator: " · ")).font(th.homeText(13)).foregroundStyle(PN.C.text3))
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Text(c.tokens.map { "~" + SheetSizeStep.short($0) } ?? "").font(th.homeMono(11)).foregroundStyle(PN.C.text3)
                }
                .pageRow(8)
            }
            if draft.candidates.isEmpty && draft.candidateNote.isEmpty {
                Text(L("sheet.ui.s3.noCandidates")).font(th.homeText(13)).foregroundStyle(PN.C.text3).pageRow(10)
            }
            HStack(spacing: 14) {
                Button(L("sheet.ui.s3.addTicked", ["n": "\(ticked)"])) { draft.addTickedCandidates() }.buttonStyle(.pnSecondary).disabled(ticked == 0)
                if draft.candidates.count > 8 && !showAll {
                    PrepLink(text: L("sheet.ui.s3.showAll", ["n": "\(draft.candidates.count)"])) { showAll = true }
                }
                Spacer(minLength: 8)
                Text(L("ea.s3.never")).font(th.homeText(12)).foregroundStyle(PN.C.text3).multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .pageRow(10)
        }
    }

    private var whatYouCanAdd: some View {
        VStack(alignment: .leading, spacing: 8) {
            PrepFieldLabel(text: L("sheet.ui.s3.canAdd"))
            ForEach(["files", "folders", "google", "notion", "web", "linkedin", "text"], id: \.self) { k in
                Text(L("sheet.ui.s3.can." + k)).font(th.homeText(13)).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16).frame(width: 300)
    }
}

/// One source before the run (board EA step 3): tick, title, kind and size in mono, the note, the access as a
/// status mark and one action.
struct SheetDraftSourceRow: View {
    @ObservedObject var draft: SheetDraft
    @Binding var source: DraftSource
    @Environment(\.pnTheme) private var th
    @State private var pasting = false
    @State private var pasted = ""

    var body: some View {
        let st = SourceType(rawValue: source.type)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Toggle("", isOn: $source.checked).toggleStyle(.pnCheckbox).labelsHidden().accessibilityLabel(source.title)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(source.title).font(th.homeText(15, .semibold)).foregroundStyle(PN.C.text).lineLimit(1).truncationMode(.middle)
                        if source.deck { PagePill(text: L("sheet.ui.deck"), color: PN.C.docs) }
                    }
                    Text(([SheetLabels.kind(st), source.tokens.map { "~" + SheetLabels.tokens($0) } ?? ""] + source.why).filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(th.homeMono(11)).foregroundStyle(PN.C.text3).lineLimit(2)
                    if let f = source.folder {
                        Text(SheetLabels.folderLine(f)).font(th.homeText(13)).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
                    } else if let r = source.reason {
                        Text(r).font(th.homeText(13)).foregroundStyle(source.access == "ok" ? PN.C.text2 : PN.C.pending).fixedSize(horizontal: false, vertical: true)
                    }
                    if source.type == SourceType.folder.rawValue { daysMenu }
                }
                Spacer(minLength: 8)
                PrepStatusTag(text: SheetLabels.access(source: source), color: color)
                action
                Button { draft.sources.removeAll { $0.id == source.id } } label: {
                    Image(systemName: "xmark").font(PN.sys(10, .semibold)).foregroundStyle(PN.C.text3).frame(width: 20, height: 20)
                }
                .buttonStyle(.plain).help(L("call.remove")).accessibilityLabel(L("call.remove") + ": " + source.title)
            }
            if draft.model.callType == "presentation" && ["pptx", "pdf", "key"].contains(((source.path ?? "") as NSString).pathExtension.lowercased()) {
                Toggle(L("sheet.ui.s3.isDeck"), isOn: $source.deck).toggleStyle(.pnCheckbox).font(th.homeText(13)).padding(.leading, 30)
                if source.deck {
                    // The deck row carries its slide owners, minutes and Q&A: the same DeckBlock as Start call (0.8.5).
                    DeckBlock(model: draft.model).padding(.leading, 30)
                }
            }
            if pasting {
                VStack(alignment: .leading, spacing: 6) {
                    TextEditor(text: $pasted).font(th.homeText(14)).frame(height: 90).scrollContentBackground(.hidden).prepField()
                    HStack {
                        Spacer()
                        Button(L("common.cancel")) { pasting = false }.buttonStyle(.pnTertiary)
                        Button(L("sheet.ui.s3.saveText")) {
                            source.text = pasted; source.access = "ok"; source.reason = nil; source.fix = nil; source.tokens = max(1, pasted.count / 4)
                            pasting = false
                        }.buttonStyle(.pnSecondary).disabled(pasted.isEmpty)
                    }
                }
                .padding(.leading, 30)
            }
        }
        .pageRow(10)
    }

    /// 0.10.0 (Meeting Sheet, folders): this folder's own window; the default is Settings > Meeting Sheet.
    /// 0.25 (R3c-2): a short menu under the folder line instead of the field (board EA shows only the line).
    private var daysMenu: some View {
        let def = SheetPrefs.shared.folderDays
        let now = source.days ?? def
        return Menu {
            Button(L("ea.s3.daysDefault", ["n": "\(def)"])) { source.days = nil; draft.checkSources() }
            // 0.25 (review): a remembered custom value stays on the list
            ForEach(Array(Set([3, 7, 14, 30] + (source.days.map { [$0] } ?? []))).filter { $0 != def }.sorted(), id: \.self) { n in
                Button(L("ea.s3.daysN", ["n": "\(n)"])) { source.days = n; draft.checkSources() }
            }
        } label: {
            Text(L("ea.s3.days", ["n": "\(now)"]) + " ▾").font(th.homeText(12, .semibold)).underline().foregroundStyle(PN.C.text2)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(L("ea.s3.days", ["n": "\(now)"]))
    }

    private var color: Color { source.access == "ok" ? PN.C.turn : source.access == "pending" ? PN.C.text3 : PN.C.pending }

    @ViewBuilder private var action: some View {
        switch source.fix {
        case "connect_notion", "connect_google": Button(SheetLabels.fix(FixAction(rawValue: source.fix!))) { SettingsWindow.show(tab: "integrations") }.buttonStyle(.pnSecondary)
        // 0.10.0 (Meeting Sheet, Google Picker): Google Picker on this one Drive file; a read copy makes the source ok
        case "confirm_google": Button(SheetLabels.fix(.confirmGoogle)) {
            GooglePicker.confirm(url: source.uri ?? "", root: draft.model.root) { o in
                switch o { case .copied: draft.checkSources(); case .note(let m): draft.note = m; case .cancelled: break }
            }
        }.buttonStyle(.pnSecondary)
        case "paste_text", "save_as_pdf": Button(SheetLabels.fix(.pasteText)) { pasting = true }.buttonStyle(.pnSecondary)
        case "retry": Button(SheetLabels.fix(.retry)) { draft.retryGoogle() }.buttonStyle(.pnSecondary)
        case "open_in_browser": Button(SheetLabels.fix(.openInBrowser)) { if let u = source.uri, let url = URL(string: u) { NSWorkspace.shared.open(url) } }.buttonStyle(.pnSecondary)
        default: EmptyView()
        }
    }
}

/// LinkedIn: only when a LinkedIn source exists. Save to PDF, the Pacenote browser, paste the text, fill in by hand
/// (all optional, source linkedin_manual), skip. The states come from the source's access reason.
/// 0.25 (R3c-2, board EA step 3): an orange frame, the ways as chips in one row, the form in two columns.
struct SheetLinkedInCard: View {
    @ObservedObject var draft: SheetDraft
    @Binding var source: DraftSource
    @Environment(\.pnTheme) private var th
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
        let shape = RoundedRectangle(cornerRadius: th.style == .classic ? PN.Radius.s : 0)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(L("sheet.ui.li.title", ["name": source.title])).font(th.homeText(16, .semibold)).foregroundStyle(PN.C.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let u = source.uri {
                    Text(Self.short(u)).font(th.homeMono(11)).foregroundStyle(PN.C.text3).lineLimit(1).truncationMode(.middle)
                }
            }
            (Text(L("sheet.ui.li.state." + state) + ". ").font(th.homeText(15, .semibold)).foregroundStyle(state == "read" ? PN.C.turn : PN.C.pending)
             + Text(L("sheet.ui.li.state." + state + ".body")).font(th.homeText(15)).foregroundStyle(PN.C.text))
                .fixedSize(horizontal: false, vertical: true)
            if state != "read" {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    wayChip("pdf", L("sheet.ui.li.pdf"))
                    if SheetBrowserBridge.available {
                        PrepChip(on: false, action: { if let u = source.uri { SheetBrowserBridge.open(u, draft: draft, replacing: source.id) } }) {
                            Text(L("sheet.ui.li.browser")).font(th.homeText(14, .medium)).lineLimit(1)
                        }
                    }
                    wayChip("paste", L("sheet.ui.li.paste"))
                    wayChip("hand", L("sheet.ui.li.hand"))
                    PrepChip(on: false, action: { source.checked = false; source.reason = L("sheet.ui.li.skipped"); way = "" }) {
                        Text(L("sheet.ui.li.skip")).font(th.homeText(14, .medium)).lineLimit(1)
                    }
                }
            }
            switch way {
            case "pdf":
                Text(L("sheet.ui.li.pdfHow")).font(th.homeText(13)).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
                Button(L("sheet.ui.s3.choose")) { draft.chooseFiles() }.buttonStyle(.pnSecondary)
            case "paste":
                TextEditor(text: $pasted).font(th.homeText(14)).frame(height: 100).scrollContentBackground(.hidden).prepField()
                    .accessibilityLabel(L("sheet.ui.li.paste"))
                HStack {
                    Spacer()
                    Button(L("sheet.ui.s3.saveText")) { saveManual(pasted) }.buttonStyle(.pnSecondary).disabled(pasted.isEmpty)
                }
            case "hand":
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                    GridRow {
                        field(L("sheet.ui.li.role"), $role)
                        field(L("sheet.ui.li.location"), $location)
                    }
                    GridRow {
                        field(L("sheet.ui.li.experience"), $experience)
                        field(L("sheet.ui.li.other"), $other, placeholder: L("ea.li.optional"))
                    }
                }
                HStack(alignment: .center, spacing: 12) {
                    Text(L("sheet.ui.li.handNote")).font(th.homeText(12)).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(L("common.cancel")) { way = "" }.buttonStyle(.pnTertiary)
                    Button(L("sheet.ui.li.save")) {
                        let lines = [(L("sheet.ui.li.role"), role), (L("sheet.ui.li.location"), location), (L("sheet.ui.li.experience"), experience), (L("sheet.ui.li.other"), other)]
                            .filter { !$0.1.trimmingCharacters(in: .whitespaces).isEmpty }.map { $0.0 + ": " + $0.1 }
                        saveManual(lines.joined(separator: "\n"))
                    }.buttonStyle(.pnPrimary)
                }
            default: EmptyView()
            }
        }
        .padding(16)
        .overlay(shape.strokeBorder(state == "read" ? PN.C.field : PN.C.pending, lineWidth: 1.5))
    }

    static func short(_ u: String) -> String {
        var s = u
        for p in ["https://", "http://", "www."] where s.hasPrefix(p) { s.removeFirst(p.count) }
        return s.hasSuffix("/") ? String(s.dropLast()) : s
    }

    private func wayChip(_ k: String, _ title: String) -> some View {
        PrepChip(on: way == k, action: { way = way == k ? "" : k }) {
            Text(title).font(th.homeText(14, .medium)).lineLimit(1)
        }
    }

    private func field(_ label: String, _ text: Binding<String>, placeholder: String = "") -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(th.homeText(13, .semibold)).foregroundStyle(PN.C.text2)
            TextField(placeholder, text: text).textFieldStyle(.plain).font(th.homeText(14)).prepField(height: 32)
                .accessibilityLabel(label)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// 0.25 (R3c, board EB step 4): the count large over a bar with the one-pass mark, Runs on under it, the biggest
/// sources with their share and, when it is too much, the plan picked right on the page (no dialog since 0.25):
/// nothing is cut on its own, Build the sheet waits for a plan.
struct SheetSizeStep: View {
    @ObservedObject var draft: SheetDraft
    @Environment(\.pnTheme) private var th

    private var state: SizeState { draft.size?.state ?? .fits }
    private var reserve: Int { draft.size?.reserve ?? 12_000 }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PrepPageHead(title: L("sheet.ui.s4.title"), sub: L("sheet.ui.s4.sub"))
            VStack(alignment: .leading, spacing: 14) {
                if let s = draft.size { scale(s) } else if draft.checking { PNSpinner(size: 24).padding(.vertical, 8) }
                runsOn
            }
            .padding(.top, 16)
            .overlay(alignment: .top) { Rectangle().fill(PN.C.ruleStrong).frame(height: th.ruleHeavy) }
            if state == .tooMuch {
                HStack(alignment: .top, spacing: 28) {
                    biggest.frame(maxWidth: .infinity, alignment: .topLeading)
                    whatToDo.frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                biggest
                Text(L("sheet.ui.s4.reserve", ["r": Self.short(reserve)])).font(th.homeText(12)).foregroundStyle(PN.C.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { if draft.size == nil { draft.checkSize() } }
    }

    /// "236K": the count without the unit, for the big number and the mark.
    static func short(_ n: Int) -> String { n >= 1000 ? "\(Int((Double(n) / 1000).rounded()))K" : "\(n)" }

    private func scale(_ s: SizeReport) -> some View {
        let total = s.totalTokens ?? 0, w = max(1, s.window ?? SheetRoutes.window(draft.route))
        let kept = s.reserve ?? 12_000, pass = max(1, w - kept), st = s.state ?? .fits
        let span = Double(max(total, w)), mark = Double(pass) / span, fill = Double(total) / span
        let key = st == .tooMuch ? "tooMuch" : st == .near ? "near" : "fits"
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .lastTextBaseline, spacing: 12) {
                Text("~" + Self.short(total)).font(th.homeDisplay(56, th.heroWeight)).tracking(th.dTrack * 56).monospacedDigit()
                    .foregroundStyle(PN.C.text)
                Text(L("eb.s4.ofPass", ["w": Self.short(w)])).font(th.homeText(15)).foregroundStyle(PN.C.text2)
                Spacer(minLength: 8)
                PrepStatusTag(text: L("sheet.ui.size." + key), color: st == .fits ? PN.C.turn : PN.C.pending)
            }
            GeometryReader { g in
                let wide = g.size.width
                ZStack(alignment: .leading) {
                    Rectangle().fill(PN.C.rule)
                    Rectangle().fill(PN.C.text.opacity(0.75)).frame(width: wide * min(fill, mark))
                    if fill > mark { Rectangle().fill(PN.C.pendingFill).frame(width: wide * (min(1, fill) - mark)).offset(x: wide * mark) }
                    Rectangle().fill(PN.C.text).frame(width: 2, height: 26).offset(x: max(0, wide * mark - 1))
                }
            }
            .frame(height: 18)
            .accessibilityElement().accessibilityLabel(L("sheet.ui.size." + key))
            .accessibilityValue(L("sheet.ui.s4.of", ["t": SheetLabels.tokens(total), "w": SheetLabels.tokens(w)]))
            GeometryReader { g in
                HStack(spacing: 8) {
                    Text("0")
                    Spacer(minLength: 8)
                    Text(L("eb.s4.limit", ["p": Self.short(pass), "r": Self.short(kept)]) + " ↑").lineLimit(1)
                }
                .font(th.homeMono(11)).foregroundStyle(PN.C.text3)
                .frame(width: max(min(g.size.width, 340), g.size.width * mark + 8), alignment: .leading)
            }
            .frame(height: 14).accessibilityHidden(true)
        }
    }

    private var runsOn: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                PrepFieldLabel(text: L("sheet.ui.s4.runsOn"))
                Picker("", selection: $draft.route) {
                    ForEach(SheetRoutes.all, id: \.self) { r in
                        Text(AIRoute.name(r) + (SheetRoutes.ready(r) ? "" : " · " + L("sheet.ui.route.out"))).tag(r)
                    }
                }
                .labelsHidden().fixedSize()
                .onChange(of: draft.route) { draft.checkSize() }
                Text(L("sheet.ui.s4.default")).font(th.homeText(13)).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
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
    }

    private var biggest: some View {
        let list = Array(draft.sources.filter(\.checked).sorted { ($0.tokens ?? 0) > ($1.tokens ?? 0) }.prefix(5))
        let top = Double(max(1, list.first?.tokens ?? 1))
        return VStack(alignment: .leading, spacing: 0) {
            PrepSectionHead(number: nil, title: L("sheet.ui.s4.biggest"))
            ForEach(list) { s in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(s.title).font(th.homeText(15)).foregroundStyle(PN.C.text).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(s.tokens.map { "~" + Self.short($0) } ?? "").font(th.homeMono(11)).foregroundStyle(PN.C.text3)
                    }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(PN.C.rule)
                            Rectangle().fill(PN.C.text2).frame(width: g.size.width * min(1, Double(s.tokens ?? 0) / top))
                        }
                    }
                    .frame(height: 4).accessibilityHidden(true)
                }
                .pageRow(10)
                .accessibilityElement(children: .combine)
            }
            Button(L("sheet.ui.s4.back")) { draft.step = 3 }.buttonStyle(.pnTertiary).padding(.top, 8)
        }
    }

    private var whatToDo: some View {
        let big = [AIRoute.gemini, AIRoute.agy].first { SheetRoutes.ready($0) && $0 != draft.route }
        return VStack(alignment: .leading, spacing: 0) {
            PrepSectionHead(number: nil, title: L("sheet.ui.s4.whatToDo"))
            Text(L("sheet.ui.s4.tooMuchSub")).font(th.homeText(14)).foregroundStyle(PN.C.text2)
                .fixedSize(horizontal: false, vertical: true).padding(.vertical, 8)
            option("passes", on: draft.plan == "passes") { draft.plan = "passes" }
            option("compress", on: draft.plan == "compress") { draft.plan = "compress" }
            option("remove", on: false) { draft.step = 3 }
            if let big {
                option("bigger", on: false, args: ["route": AIRoute.name(big)]) { draft.route = big; draft.plan = "one"; draft.checkSize() }
            }
            Text(draft.plan.isEmpty ? L("sheet.ui.s4.pickPlan") : L("sheet.ui.s4.plan." + draft.plan))
                .font(th.homeText(14, .semibold)).foregroundStyle(draft.plan.isEmpty ? PN.C.pending : PN.C.text)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 14)
            Text(L("sheet.ui.s4.reserve", ["r": Self.short(reserve)])).font(th.homeText(12)).foregroundStyle(PN.C.text3)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
        }
    }

    /// A radio row of the board: the picked plan on surface2 with a heavy line on the left.
    private func option(_ k: String, on: Bool, args: [String: String] = [:], run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().strokeBorder(PN.C.text, lineWidth: 1.5)
                    if on { Circle().fill(PN.C.text) }
                }
                .frame(width: 14, height: 14).padding(.top, 3).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("sheet.ui.s4.opt." + k, args)).font(th.homeText(15, .semibold)).foregroundStyle(PN.C.text)
                    Text(L("sheet.ui.s4.opt." + k + ".sub", args)).font(th.homeText(13)).foregroundStyle(PN.C.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(on ? PN.C.surface2 : Color.clear)
            .overlay(alignment: .leading) { if on { Rectangle().fill(PN.C.text).frame(width: th.ruleHeavy) } }
            .overlay(alignment: .bottom) { Rectangle().fill(PN.C.rule).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : [.isButton])
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

/// 0.25 (R3c, board EB step 5): the pass in mono, the percent large with the stage, a thick bar (yellow while it
/// runs, orange when it stopped, green when done), the sources as rows type | title | status mark, and a footer
/// with the readiness. A waiting route switch reads as the failure with "Build on <route>", as in Quick.
struct SheetBuildProgress: View {
    @ObservedObject var draft: SheetDraft
    @ObservedObject var job: SheetJob
    @ObservedObject private var runner = SheetRunner.shared
    @Environment(\.pnTheme) private var th

    private var switchTo: String? {
        if let sw = runner.pendingSwitch, sw.callID == draft.model.id { return sw.to }
        return nil
    }
    private var failure: String? {
        if let e = job.failed { return e }
        if let sw = runner.pendingSwitch, sw.callID == draft.model.id { return sw.reason }
        return nil
    }
    private var running: Bool { !job.done && failure == nil }
    private var sheet: MeetingSheet? { job.done ? job.sheetPath.flatMap { SheetCache.shared.load($0) } : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 10) {
                PrepPageHead(title: L("sheet.ui.s5.title"), sub: subLine)
                Spacer(minLength: 8)
                if running {
                    Button(L("call.stop")) { job.stop() }.buttonStyle(.pnTertiary)
                    Button(L("sheet.ui.build.closeNotify")) { job.notifyWhenDone = true; SheetPrepWindow.close(draft.model) }.buttonStyle(.pnSecondary)
                }
            }
            progress
            sourcesList
            if !running { footer }
        }
    }

    private var subLine: String {
        let f = DateFormatter(); f.locale = Locale(identifier: L10n.lang == "uk" ? "uk_UA" : "en_US"); f.setLocalizedDateFormatFromTemplate("EEEdMMMHHmm")
        return draft.model.effectiveTitle + " · " + f.string(from: draft.model.callDate)
    }

    private var progress: some View {
        let pct = job.done ? 100 : Int((job.progress * 100).rounded())
        let tint = job.done ? PN.C.turn : PN.C.text
        let bar = job.done ? PN.C.ready : failure != nil ? PN.C.pendingFill : PN.C.accentFill
        return VStack(alignment: .leading, spacing: 10) {
            if let n = job.pass, let all = job.passes, all > 1, !job.done {
                PrepFieldLabel(text: L("sheet.ui.s5.pass", ["n": "\(n)", "all": "\(all)"]))
            }
            if let e = failure {
                Text(e).font(th.homeText(17, .semibold)).foregroundStyle(PN.C.pending).fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .lastTextBaseline, spacing: 16) {
                    Text("\(pct)%").font(th.homeDisplay(th.bigNum, th.heroWeight)).tracking(th.numTrack * th.bigNum).monospacedDigit()
                        .foregroundStyle(tint).accessibilityHidden(true)
                    Text(job.done ? L("sheet.ui.s5.done") : job.stage.isEmpty ? L("sheet.ui.build.starting") : job.stage)
                        .font(th.homeText(17, .semibold)).foregroundStyle(tint).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Rectangle().fill(PN.C.rule).frame(height: 10)
                .overlay(alignment: .leading) {
                    GeometryReader { g in Rectangle().fill(bar).frame(width: (job.done ? 1 : max(0, min(1, job.progress))) * g.size.width) }
                }
                .accessibilityElement().accessibilityLabel(L("qp.building.a11y")).accessibilityValue("\(pct)%")
            if job.done {
                note(builtLine, PN.C.text3)
            } else if let to = switchTo {
                note(L("qp.failed.other", ["route": AIRoute.name(to)]), PN.C.text)
            } else if failure == nil {
                note(L("sheet.ui.s5.note", ["route": AIRoute.name(draft.route)]), PN.C.text3)
            }
            if failure == nil, let n = runner.switchNotice, runner.callID == draft.model.id { note(n, PN.C.text2) }
        }
        .padding(.top, 16)
        .overlay(alignment: .top) { Rectangle().fill(failure != nil ? PN.C.pending : PN.C.ruleStrong).frame(height: th.ruleHeavy) }
    }

    private func note(_ s: String, _ c: Color) -> some View {
        Text(s).font(th.homeText(13)).foregroundStyle(c).fixedSize(horizontal: false, vertical: true)
    }

    /// "Built in 1 min 52 s on Claude account · 2 passes · 6 read, 1 skipped"
    private var builtLine: String {
        let secs = max(1, Int((job.finishedAt ?? Date()).timeIntervalSince(job.started)))
        let took = secs < 90 ? L("qp.took.s", ["n": "\(secs)"]) : L("qp.took.m", ["m": "\(secs / 60)", "s": "\(secs % 60)"])
        var parts = [L("eb.s5.built", ["took": took, "route": AIRoute.name(draft.route)])]
        if let p = job.passes, p > 1 { parts.append(L("eb.s5.passes", ["n": "\(p)"])) }
        parts.append(countLine)
        return parts.joined(separator: " · ")
    }

    private var checked: [DraftSource] { draft.sources.filter(\.checked) }

    private func state(_ s: DraftSource) -> String { job.sourceState[s.id] ?? (job.done ? "read" : "waiting") }

    /// "6 read, 1 skipped" (only the counts that are not zero, read always)
    private var countLine: String {
        let st = checked.map(state)
        let read = st.filter { $0 == "read" || $0 == "summarized" }.count, skipped = st.filter { $0 == "skipped" }.count
        let failed = st.filter { $0 == "failed" }.count
        var p = [L("eb.s5.nRead", ["n": "\(read)"])]
        if skipped > 0 { p.append(L("eb.s5.nSkipped", ["n": "\(skipped)"])) }
        if failed > 0 { p.append(L("eb.s5.nFailed", ["n": "\(failed)"])) }
        return p.joined(separator: ", ")
    }

    private var sourcesList: some View {
        VStack(alignment: .leading, spacing: 0) {
            PrepSectionHead(number: nil, title: L("sheet.ui.row.sources")) {
                Text("\(checked.count) · " + countLine).font(th.homeMono(11)).foregroundStyle(PN.C.text3).lineLimit(1)
            }
            ForEach(checked) { s in
                let st = state(s)
                HStack(alignment: .center, spacing: 12) {
                    Text(SheetLabels.kind(SourceType(rawValue: s.type) ?? .file)).font(th.homeMono(11)).foregroundStyle(PN.C.text3)
                        .lineLimit(1).frame(width: 110, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).font(th.homeText(15)).foregroundStyle(PN.C.text).lineLimit(1).truncationMode(.middle)
                        if let n = job.sourceNote[s.id] {
                            Text(n).font(th.homeText(13)).foregroundStyle(st == "failed" ? PN.C.pending : PN.C.text3).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    PrepStatusTag(text: Self.stateText(st), color: Self.stateColor(st))
                    if st == "failed" {
                        Button(L("sheet.ui.s5.retry")) { job.control("retry", source: s.id) }.buttonStyle(.pnSecondary)
                        Button(L("sheet.ui.s5.skip")) { job.control("skip", source: s.id) }.buttonStyle(.pnTertiary)
                    }
                }
                .pageRow(10)
                .accessibilityElement(children: .contain)
            }
        }
    }

    static func stateText(_ st: String) -> String {
        ["waiting", "reading", "read", "failed", "skipped", "summarized"].contains(st) ? L("sheet.ui.s5.state." + st) : L("sheet.ui.s5.state.reading")
    }

    static func stateColor(_ st: String) -> Color {
        switch st {
        case "read", "summarized": return PN.C.turn
        case "failed", "skipped": return PN.C.pending
        case "waiting": return PN.C.text3
        default: return PN.C.accent
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(sheet.map { L("eb.readiness", ["r": SheetLabels.readinessLine($0.readinessBadge)]) } ?? L("eb.readiness.none"))
                .font(th.homeText(14)).foregroundStyle(PN.C.text2)
            Spacer()
            if job.done {
                Button(L("sheet.ui.s5.open")) {
                    SheetPrepWindow.close(draft.model)
                    UpcomingCallPage.openTab[draft.model.id.uuidString] = "sheet"
                    UpcomingPages.open(draft.model)
                }
                .buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
            } else if let to = switchTo {
                Button(L("sheet.ui.build.again")) { runner.declineSwitch(); draft.job = nil; draft.step = 4 }.buttonStyle(.pnSecondary)
                Button(L("qp.failed.buildOn", ["route": AIRoute.name(to)])) { runner.acceptSwitch() }
                    .buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
            } else {
                Button(L("sheet.ui.build.again")) { draft.job = nil; draft.step = 4 }
                    .buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.top, 14)
        .overlay(alignment: .top) { Rectangle().fill(PN.C.rule).frame(height: 1) }
    }
}


/// 0.24.1 (F5, decision 6): "What matters on this call" in the Meeting Sheet (Quick and Expert step 1), bound to the
/// call's context like the Start call form (CallSetup), so the brief and the tips get it. The goal for the build is
/// read from it (SheetDraft.goalLine), no second field.
struct WhatMattersField: View {
    @ObservedObject var model: StartCallModel
    @ObservedObject var draft: SheetDraft
    /// 0.25 (R3c-2): Expert step 1 puts the field under its own section head.
    var showLabel = true
    @Environment(\.pnTheme) private var th
    var body: some View {
        // 0.25 (R3b, decision 19.11): the 0.24 field (the call's context) in the look of the QP board's field
        VStack(alignment: .leading, spacing: 6) {
            if showLabel { Text(L("call.whatMatters")).font(th.homeText(15, .semibold)) }
            TextField(L("call.whatMatters.placeholder"), text: Binding(get: { model.context }, set: {
                model.context = $0
                draft.goal = SheetDraft.goalLine(model.cleanContext)
                draft.objectWillChange.send()
            }), axis: .vertical)
            .textFieldStyle(.plain).font(th.homeText(15)).lineLimit(3...6)
            .padding(.vertical, 8).prepField(height: 36)
            .accessibilityLabel(L("call.whatMatters"))
        }
    }
}
