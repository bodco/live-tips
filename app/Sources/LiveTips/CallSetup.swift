import AppKit
import SwiftUI
import LiveTipsCore

// Pacenote 0.8 (F4, REDESIGN-SPEC 5): one form for Prepare, Start call and Plan a call. Always in sight: the
// project, the call's name, its date and time (with the calendar event it comes from), What matters on this call
// with the added folders and files, and the brief in one line. The rest is under Options, with labels. Hints only
// where something is wrong; longer explanations behind (i).

enum CallSetupMode { case start, prepare, plan, page }     // 0.9.0: page = the Setup tab of a call page

struct CallSetupView: View {
    @ObservedObject var model: StartCallModel
    @ObservedObject var runner = PrepRunner.shared
    @ObservedObject var upnext = UpNext.shared
    @ObservedObject private var cal = CalendarService.shared
    @ObservedObject private var jobs = SheetJobs.shared       // 0.10.0 (Meeting Sheet, phase 4)
    var mode: CallSetupMode
    var live = false                 // a call is being recorded (plan mode switches to it only when confirmed)
    var liveTitle = ""
    var liveSince: Date?
    var onStart: () -> Void
    var onCancel: () -> Void
    var onSave: () -> Void = {}
    var onSwitch: () -> Void = {}
    var onRemove: () -> Void = {}
    var onPrepare: () -> Void = {}

    @AppStorage("callSetupOptions") private var showOptions = false
    @State private var showMethod = false
    @State private var picking = false
    @State private var search = ""
    @State private var copied = false
    @State private var info = false
    @State private var datePop = false
    @State private var confirmAgain = false
    @State private var rehearseInfo = false
    @FocusState private var titleFocus: Bool
    @Environment(\.pnTheme) private var t

    private var saved: Bool { upnext.contains(model) }

    var body: some View {
        Group {
        if mode == .page {
            // 0.25 (R2, board UP): the page scrolls itself; the form is flat sections with Save under them
            pageForm
                .onAppear { model.refreshTemplate(); model.scanPrep(); model.loadMicInputs(); PrepRunner.shared.refreshAuth() }
                .onChange(of: model.target) { model.applyProjectDefaults(); model.scanPrep(); copied = false; if !model.target.isEmpty { model.note = "" } }
                .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in model.scanPrep() }
        } else {
        VStack(spacing: 0) {
            ScrollView {
                Group {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if live { liveBanner }
                    // 0.8.5 (P1): block 1 and block 2 never move; the type section is always last, so switching
                    // the type changes only that section, below everything already filled.
                    // 0.25 (R3b, board SU): flat numbered sections under a heavy rule, mono labels, square fields
                    block(1, title: L("su.sec.call")) { titleRow; timeRow; typeRow }
                    block(2, title: L("start.context")) { projectRow; contextBox }
                    block(3, title: typeTitle) { typeSection }
                    // 2026-11-13 (owner, urgent): Plan a call showed the old "No brief yet" line with no way to prepare.
                    // Every form now shows the Meeting Sheet preparation; Plan a call also gets Quick / Expert (Start call
                    // and Prepare keep theirs in the footer).
                    if model.callType != "transcript" { block(4, title: L("sheet.ui.setup.prep")) { prepSection(buttons: mode == .plan) } } else { briefLine }
                    if let h = problemHint { Label(h, systemImage: "info.circle").font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true) }
                    options
                }
                .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 20)
                }
            }
            // 0.8.7 (G6): one scroll view for the whole form; the footer is pinned and the content ends above it
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    buttons.padding(.horizontal, 24).padding(.vertical, 14)
                }
                .background(PN.C.bg)
            }
        }
        .background(PN.C.bg)
        .frame(minWidth: 600, idealWidth: 640, maxWidth: .infinity, minHeight: 480, idealHeight: 820, maxHeight: .infinity)
        .onAppear { model.refreshTemplate(); model.scanPrep(); model.loadMicInputs(); PrepRunner.shared.refreshAuth() }
        .onChange(of: model.target) { model.applyProjectDefaults(); model.scanPrep(); copied = false; if !model.target.isEmpty { model.note = "" } }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in model.scanPrep() }
        }
    }
        .trackScreen("get_ready", sub: "\(mode)", on: mode != .page)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 0.25 (R3b, board SU): the display face at 34, in capitals where the style sets them
            Text(t.cased(mode == .prepare ? L("call.title.prepare") : mode == .plan ? L("call.title.plan") : saved ? L("call.title.upcoming") : L("call.title.start")))
                .font(t.homeDisplay(34, t.heroWeight)).tracking(t.dTrack * 34).foregroundStyle(PN.C.text)
                .accessibilityAddTraits(.isHeader)
            if mode != .start {
                Text(mode == .prepare ? L("call.sub.prepare") : L("call.sub.plan")).font(t.homeText(14)).foregroundStyle(PN.C.text2)
            }
        }
    }

    private var liveBanner: some View {
        HStack(spacing: 8) {
            Circle().fill(PN.C.rec).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(L("call.recording", ["title": liveTitle])).font(PN.Font.body.weight(.medium)).lineLimit(1)
            if let d = liveSince { Text(d, style: .timer).font(PN.Font.body.monospacedDigit()).foregroundStyle(PN.C.text3) }
            Spacer()
            Button(L("menubar.showTips")) { (NSApp.delegate as? AppDelegate)?.showTips() }.buttonStyle(.pnTertiary)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(PN.C.rec.opacity(0.10), in: RoundedRectangle(cornerRadius: PN.Radius.m))
    }

    // MARK: 1. project

    private var projectRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(L("call.project"))
            Button { search = ""; picking = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: model.workspace != nil ? "square.stack.3d.up" : "folder").foregroundStyle(PN.C.accent).frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.project?.name ?? model.workspace?.name ?? L("call.chooseProject"))
                            .font(PN.Font.body.weight(.medium)).foregroundStyle(model.target.isEmpty ? PN.C.onMe : PN.C.text)
                        Text(model.workspace != nil ? L("call.workspaceHint") : (model.project.map { $0.workspace.isEmpty ? L("call.projectWord") : L("call.projectIn", ["ws": $0.workspace]) } ?? L("call.projectHint")))
                            .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    }
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").foregroundStyle(PN.C.text3)
                }
                .padding(.vertical, 8).contentShape(Rectangle())
                .prepField(height: 40, border: model.target.isEmpty ? PN.C.accent : nil)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $picking, arrowEdge: .bottom) { projectPicker }
            // 0.25 (R3b, board SU): with no project Start call still works; say where the call goes
            if model.target.isEmpty && mode == .start {
                Text((try? AttributedString(markdown: L("su.noProject", ["ws": ProjectRegistry.defaultWorkspaceName]))) ?? AttributedString(L("su.noProject", ["ws": ProjectRegistry.defaultWorkspaceName])))
                    .font(t.homeText(14)).foregroundStyle(PN.C.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(PN.C.surface2)
                    .overlay(alignment: .leading) { Rectangle().fill(PN.C.accent).frame(width: 3) }
            }
        }
    }

    /// 0.10.1 (A3): the same list as the call page's "change project" picker (CallReassignUI.swift).
    private var projectPicker: some View {
        ProjectTargetList(current: model.target) { tag in model.target = tag; picking = false }
            .padding(12)
            .frame(width: 340, height: 360)
    }

    // MARK: 2-3. name, date and time (from the calendar)

    private var titleRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(L("call.name"))
            TextField("", text: $model.title, prompt: Text(L("call.namePlaceholder")))
                .textFieldStyle(.plain).font(PN.sys(15))
                .prepField(height: 36)
                .focused($titleFocus)
                .onChange(of: model.title) { model.scanPrep(); copied = false }
            if let e = model.rememberedForTitle {
                HStack(spacing: 6) {
                    Text(L("call.remembered", ["title": e.title])).font(t.homeText(13)).foregroundStyle(PN.C.text3)
                    Button(L("call.useSettings")) { model.apply(e); model.scanPrep() }.buttonStyle(.pnTertiary)
                }
            }
        }
    }

    private var timeRow: some View {
        let evs = cal.hasSource ? cal.aroundNow() : []
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        let from = model.calEventID.flatMap { cal.event($0) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 14) {
                // 0.8.7 (G4): fields without steppers; the date opens a calendar on click
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel(L("start.date"))
                    HStack(spacing: 4) {
                        DatePicker("", selection: $model.callDate, displayedComponents: [.date]).labelsHidden()
                            .datePickerStyle(.field).fixedSize()
                        Button { datePop = true } label: { Image(systemName: "calendar") }
                            .buttonStyle(.borderless).help(L("start.pickDate")).accessibilityLabel(L("start.pickDate"))
                            .popover(isPresented: $datePop, arrowEdge: .bottom) {
                                DatePicker("", selection: $model.callDate, displayedComponents: [.date]).labelsHidden()
                                    .datePickerStyle(.graphical).padding(10)
                                    .onChange(of: model.callDate) { datePop = false }
                            }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    fieldLabel(L("start.time"))
                    DatePicker("", selection: $model.callDate, displayedComponents: [.hourAndMinute]).labelsHidden()
                        .datePickerStyle(.field).fixedSize()
                }
                .onChange(of: model.callDate) { copied = false }
                Spacer()
                if let e = from {
                    Text(L("start.fromCalendar", ["app": model.calendarApp ?? e.calendar])).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(1)
                        .help(L("call.fromCalendar", ["title": e.title, "time": tf.string(from: e.start)]))
                }
                if !evs.isEmpty {
                    Menu {
                        ForEach(evs) { e in
                            Button(e.timeRange + "  " + e.title + (e.recurring ? "  ↻" : "")) { model.applyEvent(e); copied = false }
                        }
                    } label: { Text(L("call.pickFromCalendar")) }
                    .menuStyle(.borderlessButton).fixedSize()
                } else if cal.access == .unknown {
                    Button(L("onboarding.permissions.calendarsButton")) { cal.connect() }.buttonStyle(.pnTertiary)
                }
            }
            if let a = model.appliedFrom { Text(a).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
        }
    }

    // MARK: 0.8.5 blocks (P1)

    /// 0.25 (R3b, board SU): a flat section: the heavy rule, the mono number and the title, then its fields.
    private func block<C: View>(_ n: Int, title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            PrepSectionHead(number: n, title: title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The title of section 3 is the call type (board: Regular / Presentation).
    private var typeTitle: String {
        switch model.callType {
        case "presentation": return L("start.type.presentation")
        case "interview": return L("callSettings.type.interview")
        case "transcript": return L("callSettings.type.transcript")
        default: return L("start.type.regular")
        }
    }

    /// Call type, Audience and Language next to the title and the time (P1 block 1).
    private var typeRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                fieldLabel(L("start.callType"))
                PNSegmented(selection: $model.callType, options: [
                    ("auto", L("start.type.regular")),
                    ("presentation", L("start.type.presentation")),
                    ("interview", L("callSettings.type.interview")),
                    ("transcript", L("callSettings.type.transcript"))
                ]).labelsHidden().fixedSize()
            }
            HStack(alignment: .bottom, spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel(L("start.audience"))
                    PNSegmented(selection: $model.audience, options: [
                        ("auto", L("callSettings.audience.auto")),
                        ("client", L("callSettings.audience.client")),
                        ("team", L("callSettings.audience.team"))
                    ]).labelsHidden().fixedSize()
                }
                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel(L("start.language"))
                    // 0.8.7 (G4): a pop-up (suggested languages, More… with search), not a chip
                    LanguageMenu(codes: Binding(get: { model.language.split(separator: "+").map(String.init) },
                                                set: { model.language = $0.joined(separator: "+"); model.languageTouched = true }))
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// The type section (P1 block 3): Regular hint, the Presentation block, or the interview role.
    @ViewBuilder private var typeSection: some View {
        // 0.25 (R3b, board SU): the section title is the type; its body is flat, no card
        switch model.callType {
        case "presentation":
            DeckBlock(model: model, onNeedPrep: { if !needProject() { prepareNow() } })
        case "interview":
            VStack(alignment: .leading, spacing: 5) {
                fieldLabel(L("callSettings.role"))
                Picker(L("callSettings.role"), selection: $model.hiringRole) {
                    Text(L("callSettings.role.observer")).tag("observer")
                    Text(L("callSettings.role.interviewer")).tag("interviewer")
                    Text(L("callSettings.role.coach")).tag("coach")
                }.labelsHidden().fixedSize()
            }
        case "transcript":
            // rules/meeting.yaml > call_type.transcript: no tips, the summary and the follow-up after the call
            Text(L("start.transcriptHint")).font(t.homeText(14)).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
        default:
            Text(L("start.regularHint")).font(t.homeText(14)).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
        }
        if model.callType != "transcript" { salesRow }
    }

    /// 0.25 (R3b, board SU): Sales mode sits with the call type it changes, not under Options (0.8.7 H2: any type).
    @ViewBuilder private var salesRow: some View {
        Toggle(isOn: Binding(get: { model.salesEnabled }, set: { model.salesEnabled = $0; model.salesTouched = true })) {
            Text(L("su.sales")).font(t.homeText(14)).foregroundStyle(PN.C.text)
        }
        .toggleStyle(.pnCheckbox)
        if model.salesEnabled {
            HStack {
                SalesMethodPicker(selection: $model.salesMethod)
                Button { showMethod.toggle() } label: { Image(systemName: "info.circle") }.buttonStyle(.borderless)
                    .accessibilityLabel(L("sales.method.about"))
                    .popover(isPresented: $showMethod, arrowEdge: .trailing) { SalesMethodInfo(key: model.salesMethod) }
            }
            .padding(.leading, 24)
        }
    }

    private func fieldLabel(_ s: String) -> some View { PrepFieldLabel(text: s) }

    // MARK: 4. what matters on this call, with the added folders and files

    private var contextBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if mode != .page { fieldLabel(L("call.whatMatters")) }      // 0.9.0: the page asks it as a question above
                Button { info.toggle() } label: { Image(systemName: "info.circle").foregroundStyle(PN.C.text3) }
                    .buttonStyle(.borderless).accessibilityLabel(L("call.about"))
                    .popover(isPresented: $info, arrowEdge: .trailing) {
                        Text(L("call.whatMatters.info", ["participants": StartCallModel.uiLang == "uk" ? "Учасники:" : "Participants:"]))
                            .font(PN.Font.body).padding(14).frame(width: 320).fixedSize(horizontal: false, vertical: true)
                    }
            }
            TextEditor(text: $model.context)
                .font(PN.Font.body)
                .overlay(alignment: .topLeading) {      // 0.8.7 (G1): an empty field with a hint, no template text
                    if model.context.isEmpty {
                        Text(L("call.whatMatters.placeholder")).font(PN.Font.body).foregroundStyle(PN.C.text3).padding(.horizontal, 5).padding(.vertical, 1).allowsHitTesting(false)
                    }
                }
                .scrollContentBackground(.hidden)
                .padding(.vertical, 6).padding(.horizontal, -4)
                .frame(height: 100)
                .prepField()
            chips
            CRMCallRow(model: model)        // 0.8.7 (G7): only when a CRM is connected
        }
    }

    /// 0.25 (R3b, board SU): a framed chip; a left-out one is struck through with "+" to include it again.
    private func chip(_ symbol: String, _ name: String, on: Bool = true, help: String, toggle: @escaping () -> Void, icon: String) -> some View {
        HStack(spacing: 6) {
            Text(name).lineLimit(1).strikethrough(!on)
            Button(action: toggle) { Image(systemName: icon).font(.system(size: 10, weight: .semibold)).frame(width: 18, height: 18).contentShape(Rectangle()) }
                .buttonStyle(.plain).foregroundStyle(PN.C.text3)
                .accessibilityLabel((icon == "xmark" ? L("call.remove") : L("call.include")) + " " + name)
        }
        .font(t.homeText(13))
        .foregroundStyle(on ? PN.C.text : PN.C.text3)
        .padding(.leading, 10).padding(.trailing, 4).frame(height: 28)
        .overlay(RoundedRectangle(cornerRadius: t.style == .classic ? PN.Radius.s : 0).strokeBorder(on ? PN.C.field : PN.C.rule, lineWidth: 1.5))
        .help(help)
    }

    private var chips: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            // 0.8.7 (G3): the folder of the project chosen above is not repeated; only when left out
            if let r = model.root, !model.useProjectFolder {
                chip("folder", (r as NSString).lastPathComponent, on: model.useProjectFolder,
                     help: model.useProjectFolder ? L("call.projectFolder.on", ["path": r]) : L("call.projectFolder.off"),
                     toggle: { model.useProjectFolder.toggle() }, icon: model.useProjectFolder ? "xmark" : "plus")
            }
            ForEach(model.folders, id: \.self) { f in
                chip(StartCallModel.isDir(f) ? "folder" : "doc", (f as NSString).lastPathComponent, help: f,
                     toggle: { model.folders.removeAll { $0 == f } }, icon: "xmark")
            }
            Button("+ " + L("call.addFolder")) { model.addFolders() }
                .buttonStyle(.plain).font(t.homeText(13, .semibold)).foregroundStyle(PN.C.accent)
                .frame(height: 28).disabled(model.target.isEmpty)
        }
    }

    // MARK: 5. the brief, a status line (0.8.7 G2: "No brief yet" / "Brief ready · 09:40 · Open")

    @ViewBuilder private var briefLine: some View {
        let st = upnext.prepState(model)
        let sheet = SheetFiles.path(for: model).flatMap { SheetCache.shared.load($0) }
        HStack(alignment: .center, spacing: 10) {
            // 0.10.0 (Meeting Sheet, phase 4): the sheet first: building, or its readiness with Open
            if let j = jobs.job(for: model.id) {
                ProgressView(value: j.progress).frame(width: 60)
                Text(L("sheet.ui.building", ["p": "\(Int(j.progress * 100))"])).font(PN.Font.body).foregroundStyle(PN.C.text2).lineLimit(1)
                Spacer()
                Button(L("call.stop")) { j.stop() }.buttonStyle(.pnTertiary)
                SheetSwitchPrompt(callID: model.id)       // 0.10.0 (Meeting Sheet, hardening): the route question inline
            } else if let s = sheet {
                // 0.25 (R3b, board SU block 4): a square status mark, when it was built and which version
                SheetReadinessTag(badge: s.readinessBadge)
                Text(s.builtAt.map { L("su.prep.built", ["at": SheetLabels.date($0), "n": "\(s.versions?.map(\.n).max() ?? 1)"]) } ?? s.title)
                    .font(t.homeText(14)).foregroundStyle(PN.C.text2).lineLimit(1)
                Spacer()
                Button(L("common.open")) { openSheet() }.buttonStyle(.pnTertiary)
            } else if runner.running && runner.callID == model.id {
                ProgressView(value: runner.progress).frame(width: 60)
                Text(L("call.brief.writing", ["stage": runner.stage.prefix(1).lowercased() + runner.stage.dropFirst()])).font(PN.Font.body).foregroundStyle(PN.C.text2).lineLimit(1)   // 2026-11-11: keeps "ChatGPT"
                Spacer()
                Button(L("call.stop")) { runner.cancel() }.buttonStyle(.pnTertiary)
            } else if st == .queued {
                Image(systemName: "clock").foregroundStyle(PN.C.text3)
                Text(L("call.brief.queued")).font(PN.Font.body).foregroundStyle(PN.C.text2)
                Spacer()
                Button(L("call.brief.unqueue")) { upnext.unqueue(model) }.buttonStyle(.pnTertiary)
            } else if model.prep?.matches == true, let fr = Freshness.check(model), fr.stale {
                // Pacenote 0.8 (idea 03): an old brief says so and offers Refresh; it never refreshes by itself.
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(PN.C.onMe)
                Text(fr.line).font(PN.Font.body).foregroundStyle(PN.C.text).lineLimit(1)
                    .help(fr.changes.prefix(8).map { ($0 as NSString).lastPathComponent }.joined(separator: "\n"))
                Spacer()
                if let path = PrepDocWindow.path(for: model) { Button(L("common.open")) { PrepDocWindow.show(path: path, title: model.effectiveTitle) }.buttonStyle(.pnTertiary) }
            } else if let p = model.prep, p.matches {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(PN.C.turn)
                Text(L("home.check.briefReady", ["at": p.made.formatted(date: Calendar.current.isDateInToday(p.made) ? .omitted : .abbreviated, time: .shortened)]))
                    .font(PN.Font.body).foregroundStyle(PN.C.text)
                Spacer()
                if let path = PrepDocWindow.path(for: model) { Button(L("common.open")) { PrepDocWindow.show(path: path, title: model.effectiveTitle) }.buttonStyle(.pnTertiary) }
                if model.callType == "presentation", let path = PrepDocWindow.path(for: model) {
                    let base = String(path.dropLast(9))
                    if TalkWindow.available(base: base) {
                        Button(L("talk.open")) { TalkWindow.show(base: base, title: model.effectiveTitle, call: model) }.buttonStyle(.pnTertiary)
                    }
                    Button(L("rehearse.button")) { RehearsalWindow.show(base: base, title: model.effectiveTitle, call: model) }.buttonStyle(.pnTertiary)
                }
            } else if model.target.isEmpty {
                // 0.25 (R3b, board SU): no project, no sheet; say what the tips use instead
                Text(L("su.prep.none")).font(t.homeText(14)).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            } else {
                Image(systemName: "doc.badge.clock").foregroundStyle(PN.C.onMe)
                Text(L("sheet.ui.none")).font(PN.Font.body).foregroundStyle(PN.C.text2)
                if let p = model.prep {
                    Text(L("call.brief.other", ["heading": p.heading])).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(1)
                }
                Spacer()
            }
        }
        // 0.8.7 (G2): a status line, not a card; Prepare lives in the footer only
        .padding(.horizontal, 4)
    }

    /// 0.10.0 (Meeting Sheet, phase 4): any AI route counts (Settings > AI > Preparation first), not Claude Code only;
    /// Get ready opens Quick or Expert, where the route is shown before the run. Transcript calls have nothing to prepare.
    private var canPrepare: Bool {
        !model.target.isEmpty && model.callType != "transcript" && SheetRoutes.firstReady() != nil
            && jobs.job(for: model.id) == nil && upnext.prepState(model) != .queued
    }

    private var hasSheet: Bool { SheetFiles.path(for: model) != nil }

    /// The sheet's page (Meeting Sheet tab), from the Start call window.
    private func openSheet() {
        upnext.save(model)
        StartCallWindow.window?.close()
        UpcomingCallPage.openTab[model.id.uuidString] = "sheet"
        UpcomingPages.open(model)
    }

    /// Only where something is wrong (spec 5: no cryptic status line).
    private var problemHint: String? {
        if !model.note.isEmpty { return model.note }
        // 0.10.0 (Meeting Sheet, phase 4): the route of Settings > AI > Preparation, whichever it is
        if let p = SheetRoutes.problem(SheetRoutes.preferred) {
            return SheetRoutes.firstReady().map { L("sheet.ui.route.otherReady", ["problem": p, "route": AIRoute.name($0)]) } ?? p
        }
        if SettingsWindow.model.config.notionMeetingsDB.isEmpty && !model.target.isEmpty { return L("call.hint.noNotion") }
        if !runner.result.isEmpty && !runner.running { return runner.result }
        return nil
    }

    /// Prepare again: a presentation with a talk opens Your talk (Keep my edits, replace the deck); any other call asks first.
    private func againClicked() {
        if model.callType == "presentation", let path = PrepDocWindow.path(for: model), TalkWindow.available(base: String(path.dropLast(9))) {
            TalkWindow.show(base: String(path.dropLast(9)), title: model.effectiveTitle, call: model, openAgain: true)
        } else { confirmAgain = true }
    }
    private var againMessage: String {
        guard let path = PrepDocWindow.path(for: model), let made = Freshness.preparedAt(brief: path) else { return L("again.keepBrief") }
        let days = max(0, Calendar.current.dateComponents([.day], from: made, to: Date()).day ?? 0)
        let n = Freshness.check(model)?.changes.count ?? 0
        return L("again.age", ["d": "\(days)", "n": "\(n)"]) + "\n" + L("again.keepBrief")
    }

    /// 0.10.0 (Meeting Sheet, phase 4): Prepare = Get ready: the call is kept in Up next and Quick or Expert opens
    /// (by Settings > Meeting Sheet). No brief is written any more; the sheet is.
    private func prepareNow() {
        if !saved { upnext.save(model) }
        model.note = ""
        SheetPrepWindow.show(model)
    }

    private func refreshSheet() {
        guard let p = SheetFiles.path(for: model) else { prepareNow(); return }
        SheetActions.refresh(doc: SheetDoc(path: p), call: model)
    }

    // MARK: Options (with labels)

    private var proactive: Binding<Bool> {
        Binding(get: { ((UserDefaults.standard.dictionary(forKey: "prompterPrefs") ?? [:])["proactive"] as? String) == "1" },
                set: { var p = UserDefaults.standard.dictionary(forKey: "prompterPrefs") ?? [:]; p["proactive"] = $0 ? "1" : "0"
                       UserDefaults.standard.set(p, forKey: "prompterPrefs") })
    }

    /// 0.25 (R3b, board SU): Options closed show what is set in one line; open, a plain list of label | control rows.
    /// The set stays the app's (nothing is dropped); Sales moved to section 3, next to the call type.
    private var options: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.15)) { showOptions.toggle() } } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: showOptions ? "chevron.down" : "chevron.right").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PN.C.text2).frame(width: 12).accessibilityHidden(true)
                    Text(L("call.options")).font(t.homeText(15, .semibold)).foregroundStyle(PN.C.text)
                    if !showOptions {
                        Text(optionsSummary).font(t.homeText(13)).foregroundStyle(PN.C.text3).lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 10).padding(.bottom, 6).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .top) { Rectangle().fill(PN.C.rule).frame(height: 1) }
            .accessibilityValue(showOptions ? L("su.opt.open") : optionsSummary)
            if showOptions {
                optRow(L("call.record"), sub: L("su.opt.record.sub")) {
                    Picker("", selection: $model.recording) {
                        Text(L("call.record.off")).tag("off")
                        Text(L("rec.kind.audio")).tag("audio")
                        Text(L("rec.kind.video")).tag("video")
                    }.labelsHidden().fixedSize().help(L("call.record.help"))
                }
                optRow(L("call.startRecording")) {
                    Picker("", selection: $model.standby) {
                        Text(L("call.startRecording.whenSpeaks")).tag(true)
                        Text(L("call.startRecording.now")).tag(false)
                    }.labelsHidden().fixedSize()
                }
                optRow(L("callSettings.mic")) {
                    Picker("", selection: $model.micDevice) {
                        Text(L("callSettings.mic.default") + (model.defaultInputName.map { " (\($0))" } ?? "")).tag("default")
                        Text(L("callSettings.mic.builtin")).tag("builtin")
                        ForEach(model.micInputs.filter { !$0.builtin }, id: \.uid) { d in Text(d.name).tag("uid:" + d.uid) }
                        if model.micDevice.hasPrefix("uid:") && !model.micInputs.contains(where: { "uid:" + $0.uid == model.micDevice }) {
                            Text(L("call.mic.missing", ["name": String(model.micDevice.dropFirst(4))])).tag(model.micDevice)
                        }
                    }.labelsHidden().fixedSize()
                }
                optRow(L("su.opt.proactive"), sub: L("callSettings.proactive.hint")) {
                    Toggle("", isOn: proactive).labelsHidden().toggleStyle(.pnSwitch)
                }
                optRow(L("su.opt.publicCall"), sub: L("su.opt.publicCall.sub")) {
                    Toggle("", isOn: $model.publicCall).labelsHidden().toggleStyle(.pnSwitch)
                }
                // 0.8.7 (G3): the project folder in the preparation; with no project it says why it is off
                optRow(L("su.opt.projectFolder"), sub: model.root == nil ? L("su.opt.projectFolder.none") : "") {
                    Toggle("", isOn: $model.useProjectFolder).labelsHidden().toggleStyle(.pnSwitch).disabled(model.root == nil)
                        .help(model.root.map { model.useProjectFolder ? L("call.projectFolder.on", ["path": $0]) : L("call.projectFolder.off") } ?? "")
                }
                if !model.prepList.isEmpty {
                    optRow(L("call.useBrief")) {
                        Picker("", selection: Binding(get: { model.chosenPrep ?? "" },
                                                      set: { model.chosenPrep = $0.isEmpty ? nil : $0; model.scanPrep() })) {
                            Text(L("call.useBrief.auto")).tag("")
                            ForEach(model.prepList, id: \.file) { p in Text("\(p.heading) · \(p.made.formatted(date: .abbreviated, time: .shortened))").tag(p.file) }
                        }.labelsHidden().fixedSize()
                    }
                }
                HStack(spacing: 14) {
                    Button(copied ? L("call.copied") : L("call.copyCowork")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.prepPhrase, forType: .string)
                        copied = true
                    }
                    .buttonStyle(.pnTertiary).disabled(model.target.isEmpty)
                    Button(L("call.prepSettings")) { SettingsWindow.show(tab: "ai") }.buttonStyle(.pnTertiary)
                }
                .pageRow(10)
            }
        }
    }

    /// One row of the open Options: the label on the left (190 pt), the control and a note on the right.
    private func optRow<C: View>(_ label: String, sub: String = "", @ViewBuilder _ control: () -> C) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label).font(t.homeText(14)).foregroundStyle(PN.C.text2)
                .frame(width: 190, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 2) {
                control()
                if !sub.isEmpty { Text(sub).font(t.homeText(12)).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .pageRow(8)
        .accessibilityElement(children: .contain)
    }

    /// Options closed (board): the recording, when it starts, and whether tips come on their own.
    private var optionsSummary: String {
        let rec = model.recording == "video" ? L("rec.kind.video") : model.recording == "audio" ? L("rec.kind.audio") : L("su.opt.sum.noRecord")
        let start = model.standby ? L("call.startRecording.whenSpeaks") : L("call.startRecording.now")
        let tips = proactive.wrappedValue ? L("su.opt.sum.tipsOn") : L("su.opt.sum.tipsAsk")
        return [rec, start.prefix(1).lowercased() + start.dropFirst(), tips].joined(separator: " · ")
    }

    // MARK: 0.9.0 page mode: three questions, the rest under More settings, Save applies

    @State private var pageMore = false
    @State private var useForSeries = false

    private func question<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(PN.Font.body.weight(.semibold)).foregroundStyle(PN.C.text)
            c()
        }
    }

    /// 0.25 (R2, board UP): the Setup tab of the upcoming call page as flat sections in two columns: The call and
    /// People on the left, Preparation and More settings on the right; Save and Cancel under them.
    @ViewBuilder private var pageForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageColumns {
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 0) {
                        PageSectionHead(title: L("page.sec.call"))
                        setupRow(L("call.project")) {
                            Button { search = ""; picking = true } label: {
                                HomeField(text: model.project?.name ?? model.workspace?.name ?? L("call.chooseProject"), height: 32)
                            }
                            .buttonStyle(.plain).accessibilityLabel(L("call.project"))
                            .popover(isPresented: $picking, arrowEdge: .bottom) { projectPicker }
                        }
                        setupRow(L("call.name")) {
                            TextField("", text: $model.title, prompt: Text(L("call.namePlaceholder"))).labelsHidden().pageField(32)
                                .onChange(of: model.title) { model.scanPrep(); copied = false }
                        }
                        setupRow(L("page.row.when")) {
                            DatePicker("", selection: $model.callDate, displayedComponents: [.date, .hourAndMinute]).labelsHidden()
                                .datePickerStyle(.field).fixedSize()
                                .onChange(of: model.callDate) { copied = false }
                        }
                        setupRow(L("page.row.kind")) {
                            menuField(kinds.first { $0.0 == model.callType }?.1 ?? L("start.type.regular")) {
                                ForEach(kinds, id: \.0) { k in Button(k.1) { model.callType = k.0 } }
                            }
                        }
                        setupRow(L("start.audience")) {
                            menuField(audiences.first { $0.0 == model.audience }?.1 ?? L("callSettings.audience.auto")) {
                                ForEach(audiences, id: \.0) { k in Button(k.1) { model.audience = k.0 } }
                            }
                        }
                        setupRow(L("start.language")) {
                            LanguageMenu(codes: Binding(get: { model.language.split(separator: "+").map(String.init) },
                                                        set: { model.language = $0.joined(separator: "+"); model.languageTouched = true }))
                        }
                        setupRow(L("page.row.opensIn")) {
                            Text(opensIn).font(t.homeText(15)).foregroundStyle(opensIn == L("page.opensIn.none") ? PN.C.text3 : PN.C.text)
                                .lineLimit(1)
                        }
                        setupRow(L("page.row.sales")) {
                            Toggle(isOn: Binding(get: { model.salesEnabled }, set: { model.salesEnabled = $0; model.salesTouched = true })) {
                                Text(L("page.salesMode")).font(t.homeText(15))
                            }
                            .toggleStyle(.pnCheckbox)
                        }
                        if model.callType != "auto" { typeSection.pageRow(12) }
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        PageSectionHead(title: L("page.sec.people"))
                        sideRow(L("sheet.ui.s1.ours"), [L("sheet.ui.you")] + SheetDraft.ourPeople(model))
                        sideRow(L("sheet.ui.s1.theirs"), SheetDraft.theirPeople(model).map { p in (p.company ?? "").isEmpty ? p.name : p.name + " · " + (p.company ?? "") })
                        HStack(spacing: 16) {
                            Text(L("page.people.note2")).font(t.homeText(13)).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            HomeLink(L("page.people.change")) { if !needProject() { upnext.save(model); SheetPrepWindow.show(model, mode: .quick) } }
                        }
                        .pageRow(10)
                    }
                }
            } right: {
                VStack(alignment: .leading, spacing: 28) {
                    if model.callType != "transcript" {
                        VStack(alignment: .leading, spacing: 0) {
                            PageSectionHead(title: L("sheet.ui.setup.prep")) {
                                HomeLink(L("page.prep.expert")) {
                                    if !needProject() { upnext.save(model); SheetPrepWindow.show(model, mode: .expert) }
                                }
                            }
                            briefLine.pageRow(10)
                            VStack(alignment: .leading, spacing: 6) {
                                (Text(L("page.q.special")) + Text("  " + L("page.q.specialSub")).foregroundColor(PN.C.text3))
                                    .font(t.homeText(15)).foregroundStyle(PN.C.text2)
                                contextBox
                            }
                            .pageRow(12)
                            HStack(spacing: 10) {
                                Button(L("sheet.ui.quickPrep")) { if !needProject() { upnext.save(model); SheetPrepWindow.show(model, mode: .quick) } }
                                    .buttonStyle(.pnBar).disabled(!canPrepare)
                                Button(L("sheet.ui.expertPrep")) { if !needProject() { upnext.save(model); SheetPrepWindow.show(model, mode: .expert) } }
                                    .buttonStyle(.pnBar).disabled(!canPrepare)
                            }
                            .pageRow(10)
                            Text(L("sheet.ui.setup.prepNote")).font(t.homeText(13)).foregroundStyle(PN.C.text3)
                                .fixedSize(horizontal: false, vertical: true).pageRow(10)
                        }
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        PageSectionHead(title: L("page.sec.recording"))
                        HStack(spacing: 10) {
                            Toggle(isOn: Binding(get: { model.recording != "off" },
                                                 set: { model.recording = $0 ? (recCfg.kind == "audio" ? "audio" : "video") : "off" })) {
                                Text(L("page.rec.this")).font(t.homeText(16))
                            }
                            .toggleStyle(.pnCheckbox)
                            Spacer(minLength: 8)
                            if model.recording != "off" {
                                menuField(L(model.recording == "audio" ? "rec.kind.audio" : "rec.kind.video")) {
                                    Button(L("rec.kind.video")) { model.recording = "video" }
                                    Button(L("rec.kind.audio")) { model.recording = "audio" }
                                }
                                if model.recording == "video" {
                                    Text(t.caps ? recQuality.uppercased() : recQuality).font(t.homeMono(12)).foregroundStyle(PN.C.text3).lineLimit(1)
                                }
                            }
                        }
                        .pageRow(10)
                        HStack(spacing: 16) {
                            Text(L(recCfg.drive == "auto" ? "page.rec.driveAuto" : "page.rec.driveManual")).font(t.homeText(15)).foregroundStyle(PN.C.text)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            HomeLink(L("page.rec.settings")) { SettingsWindow.show(tab: "recording") }
                        }
                        .pageRow(10)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        PageSectionHead(title: L("page.more"))
                        options.pageRow(8)
                        Text(L("page.files.note")).font(t.homeText(13)).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true).pageRow(10)
                        if let h = problemHint {
                            Text(h).font(t.homeText(13)).foregroundStyle(PN.C.notreadyText).fixedSize(horizontal: false, vertical: true).pageRow(10)
                        }
                    }
                }
            }
            // 0.25 (R2 tail, board UP): which AI does each job of this call, from Settings > AI
            VStack(alignment: .leading, spacing: 0) {
                PageSectionHead(title: L("page.sec.runsOn")) {
                    Text(L("page.runs.note")).font(t.homeText(13)).foregroundStyle(PN.C.text3)
                    Spacer()
                    HomeLink(L("page.runs.change")) { SettingsWindow.show(tab: "ai") }
                }
                HStack(spacing: 40) {
                    ForEach([("prep", L("page.runs.prep")), ("tips", L("page.runs.tips")), ("after", L("page.runs.after"))], id: \.0) { job, name in
                        HStack(spacing: 12) {
                            Text(name).font(t.homeText(15)).foregroundStyle(PN.C.text2)
                            let r = runsOn(job)
                            Text(r.map { AIRoute.name($0) } ?? L("ai.route.none")).font(t.homeText(15, .medium))
                                .foregroundStyle(r == nil ? PN.C.notreadyText : PN.C.text)
                                .padding(.horizontal, 10).frame(height: 32)
                                .background(PN.C.surface)
                                .overlay(RoundedRectangle(cornerRadius: t.style == .classic ? 6 : 0).strokeBorder(PN.C.field, lineWidth: 1.5))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .pageRow(12)
            }
            .padding(.top, 28)
            HStack(spacing: 10) { pageButtons }
                .padding(.top, 14)
                .overlay(alignment: .top) { Rectangle().fill(PN.C.ruleStrong).frame(height: t.ruleHeavy) }
                .padding(.top, 28)
        }
    }

    private var recCfg: RecordingSettings { AppConfig.load(from: AppPaths.config).recording }
    /// "Light (1280 px)": the quality of the screen recording from Settings > Call recording.
    private var recQuality: String {
        let p = recCfg.preset
        return L("rec.quality." + p.id) + " (\(p.maxWidth) px)"
    }

    /// The AI that really does a job of this call (Settings > AI, F3), nil when none may.
    private func runsOn(_ job: String) -> String? {
        let ai = AppConfig.load(from: AppPaths.config).ai
        return RoutePicker.runs(job: job, chosen: job == "prep" ? ai.prep : job == "tips" ? ai.tips : ai.after)
    }

    /// Where the meeting opens (board UP "Opens in"): the platform of the invite's link and the way Pacenote opens it.
    private var opensIn: String {
        guard let e = model.calEventID.flatMap({ cal.event($0) }), let link = e.link, !link.isEmpty else { return L("page.opensIn.none") }
        let p = MeetingPlatform.of(link)
        let name = L("page.platform." + p.rawValue)
        guard let w = MeetingLauncher.shared.environment().ways(for: p, invited: e.accounts).first else { return name }
        return name + ", " + MeetingLauncher.label(w)
    }

    /// One side of People (board UP): the side's name in the 130 pt column, the people as chips.
    private func sideRow(_ label: String, _ people: [String]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).font(t.homeText(15)).foregroundStyle(PN.C.text2).frame(width: 130, alignment: .leading).padding(.top, 5)
            if people.isEmpty {
                Text(L("page.people.none")).font(t.homeText(15)).foregroundStyle(PN.C.text3).padding(.top, 5)
            } else {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(people, id: \.self) { p in
                        Text(p).font(t.homeText(15, .medium)).foregroundStyle(PN.C.text).lineLimit(1)
                            .padding(.horizontal, 10).frame(height: 32)
                            .background(PN.C.surface)
                            .overlay(RoundedRectangle(cornerRadius: t.style == .classic ? 6 : 0).strokeBorder(PN.C.field, lineWidth: 1.5))
                    }
                }
            }
        }
        .pageRow(10)
    }

    private var kinds: [(String, String)] {
        [("auto", L("start.type.regular")), ("presentation", L("start.type.presentation")),
         ("interview", L("callSettings.type.interview")), ("transcript", L("callSettings.type.transcript"))]
    }
    private var audiences: [(String, String)] {
        [("auto", L("callSettings.audience.auto")), ("client", L("callSettings.audience.client")), ("team", L("callSettings.audience.team"))]
    }

    /// One row of The call (board UP): the name in a 130 pt column, the control after it.
    private func setupRow<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label).font(t.homeText(15)).foregroundStyle(PN.C.text2).frame(width: 130, alignment: .leading)
            c().frame(maxWidth: .infinity, alignment: .leading)
        }
        .pageRow()
    }

    /// A menu that looks like the boards' field: the value and ▾ in a 1.5 pt frame.
    private func menuField<C: View>(_ value: String, @ViewBuilder _ items: () -> C) -> some View {
        Menu { items() } label: {
            Text(value + " ▾").font(t.homeText(15, .medium)).foregroundStyle(PN.C.text)
                .padding(.horizontal, 10).frame(height: 32)
                .background(PN.C.surface)
                .overlay(RoundedRectangle(cornerRadius: t.style == .classic ? 6 : 0).strokeBorder(PN.C.field, lineWidth: 1.5))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    /// 0.10.0 (Meeting Sheet): the preparation block, the same on the call page and in Start / Plan / Prepare.
    @ViewBuilder private func prepSection(buttons: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            briefLine
            if buttons {
                HStack(spacing: 8) {
                    Button(L("sheet.ui.quickPrep")) { if !needProject() { upnext.save(model); SheetPrepWindow.show(model, mode: .quick); if mode != .page { StartCallWindow.window?.close() } } }
                        .buttonStyle(.pnSecondary).disabled(!canPrepare)
                    Button(L("sheet.ui.expertPrep")) { if !needProject() { upnext.save(model); SheetPrepWindow.show(model, mode: .expert); if mode != .page { StartCallWindow.window?.close() } } }
                        .buttonStyle(.pnSecondary).disabled(!canPrepare)
                }
                Text(L("sheet.ui.setup.prepNote")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var pageButtons: some View {
        Toggle(L("page.useForSeries", ["title": model.effectiveTitle]), isOn: $useForSeries).toggleStyle(.pnCheckbox)
            .help(L("page.useForSeries.help"))
        Spacer()
        Button(L("common.cancel"), action: onCancel).buttonStyle(.pnSecondary).keyboardShortcut(.cancelAction)
        Button(L("common.save")) {
            model.useDefaultTargetIfEmpty()
            if useForSeries { SeriesMemory.shared.remember(model) }
            onSave()
        }.buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
    }

    // MARK: buttons by mode (spec 5)

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 10) {
            switch mode {
            case .page:
                pageButtons
            case .prepare:
                // 0.25 (R3b, board SU): Cancel on the left, the way forward on the right
                Button(L("common.cancel"), action: onCancel).buttonStyle(.pnTertiary).keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("menubar.prepare")) { if !needProject() { onPrepare() } }
                    .buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction).disabled(!canPrepare && !model.target.isEmpty)
            case .start:
                // 0.25 (R3b, board SU): Cancel (and Remove) on the left; Save for later, Prepare, Start call on the right
                Button(L("common.cancel"), action: onCancel).buttonStyle(.pnTertiary).keyboardShortcut(.cancelAction)
                if saved { Button(L("home.removeUpNext"), action: onRemove).buttonStyle(.pnTertiary) }
                Spacer()
                Button(saved ? L("common.save") : L("call.saveForLater"), action: onSave).buttonStyle(.pnTertiary).disabled(model.target.isEmpty)
                    .fixedSize()     // 0.8.7.1: never "Зберегти на..."
                // 2026-10-29 (owner): once the brief is ready the same button prepares again (with one previous version kept).
                // 0.10.0 (Meeting Sheet, phase 4): Get ready (Quick or Expert); with a sheet it prepares again (a new version, edits kept).
                Button(hasSheet ? L("talk.prepareAgain") : L("menubar.prepare")) {
                    if needProject() { return }
                    if hasSheet { refreshSheet() } else if model.callType == "presentation" && model.prep?.matches == true { againClicked() } else { prepareNow() }
                }
                .buttonStyle(.pnSecondary)
                .disabled(!canPrepare || (runner.running && runner.callID == model.id))
                .help(problemHint ?? "")
                .confirmationDialog(L("again.title"), isPresented: $confirmAgain) {
                    Button(L("talk.prepareAgain")) { prepareNow() }
                    Button(L("common.cancel"), role: .cancel) {}
                } message: { Text(againMessage) }
                // 0.8.5 (P6, entry 1): Rehearse next to Start call as soon as the talk exists.
                // 0.8.7 (L2): Rehearse is always there; until the talk is prepared it is greyed out with the reason
                if let path = PrepDocWindow.path(for: model), model.callType == "presentation", TalkWindow.available(base: String(path.dropLast(9))) {
                    Button(L("rehearse.button")) { RehearsalWindow.show(base: String(path.dropLast(9)), title: model.effectiveTitle, call: model) }.buttonStyle(.pnSecondary)
                } else if model.callType == "presentation" {
                    // 2026-11-01 (owner): Rehearse only exists for Presentation calls. Until the talk is prepared it is greyed,
                    // and the (i) says how to get there: attach the deck, press Prepare.
                    HStack(spacing: 4) {
                        Button(L("rehearse.button")) {}.buttonStyle(.pnSecondary).disabled(true)
                        Button { rehearseInfo.toggle() } label: { Image(systemName: "info.circle").foregroundStyle(PN.C.text3) }
                            .buttonStyle(.borderless).accessibilityLabel(L("rehearse.needPrep"))
                            .popover(isPresented: $rehearseInfo, arrowEdge: .top) {
                                Text(L("rehearse.howTo")).font(PN.Font.body).padding(14).frame(width: 320).fixedSize(horizontal: false, vertical: true)
                            }
                    }
                    .help(L("rehearse.needPrep"))
                }
                Button(L("home.startCall")) { model.useDefaultTargetIfEmpty(); onStart() }.buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
                    .fixedSize()     // 0.8.7.1: "Почати дзвінок" broke into two lines in Ukrainian
            case .plan:
                Button(L("common.cancel"), action: onCancel).buttonStyle(.pnTertiary).keyboardShortcut(.cancelAction)
                if saved { Button(L("home.removeUpNext"), action: onRemove).buttonStyle(.pnTertiary) }
                Spacer()
                Button(live ? L("call.switch") : L("home.startNow")) { model.useDefaultTargetIfEmpty(); (live ? onSwitch : onStart)() }.buttonStyle(.pnSecondary)
                Button(L("common.save")) { if !needProject() { onSave() } }.buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
            }
        }
    }

    /// No project or workspace yet: open the list and say why (never a dead button).
    private func needProject() -> Bool {
        guard model.target.isEmpty else { return false }
        model.note = L("call.needProject")
        search = ""; picking = true
        return true
    }
}

@MainActor
final class StartCallWindow {
    static var window: NSWindow?
    static var model: StartCallModel?

    /// A1 (2026-11-14, owner п.5): "Start a call now" opens the Meeting Sheet (Quick) like every other entry.
    /// While a call is live the old form stays: it is the one that can switch to the new call.
    static func startNow(delegate: AppDelegate, prepared: StartCallModel? = nil) {
        if delegate.callIsLive { show(delegate: delegate, prepared: prepared); return }
        window?.close()
        SheetPrepWindow.show(prepared ?? StartCallModel(), mode: .quick)
    }

    /// A1 (2026-11-14): Get ready for a known call. Without a project it opens Expert at step 1 (the project picker
    /// is there), not the old Prepare form; with one, Quick or Expert by the default rules.
    static func getReady(_ m: StartCallModel) {
        if m.target.isEmpty { SheetPrepWindow.show(m, mode: .expert, step: 1); return }
        UpNext.shared.save(m)
        SheetPrepWindow.show(m)
    }

    /// One window for the three forms. While a call is live it plans an upcoming call (Save, or switch with a
    /// confirmation); Prepare asks first what the preparation is based on (owner, 2026-10-27).
    static func show(delegate: AppDelegate, prepared: StartCallModel? = nil, planOnly: Bool = false, mode wanted: CallSetupMode? = nil) {
        // 2026-11-13 (owner, urgent): Plan a call opens the Meeting Sheet (Expert, step 1 Meeting), not the old form.
        // While a call is live the old form stays: it is the one that can switch to the planned call.
        if planOnly && prepared == nil && wanted == nil && !delegate.callIsLive {
            window?.close()
            SheetPrepWindow.show(StartCallModel(), mode: .expert, step: 1)
            return
        }
        let model = prepared ?? StartCallModel()
        Self.model = model
        let live = delegate.callIsLive
        let mode: CallSetupMode = wanted ?? (live || planOnly ? .plan : .start)
        let liveTitle = CallEngine.shared.renamed ?? (CallEngine.shared.callRequest["title"] as? String) ?? ""
        let since = EngineStatus.load(path: CallEngine.shared.statusPath).startedAt.flatMap { ISO8601DateFormatter().date(from: $0) }
        let view = CallSetupView(model: model, mode: mode, live: live, liveTitle: liveTitle, liveSince: since, onStart: {
            if let err = delegate.launch(model) { model.note = err } else { window?.close() }
        }, onCancel: {
            // A call with a preparation running or waiting is kept, so the preparation is not lost.
            if !UpNext.shared.contains(model), [.running, .queued].contains(UpNext.shared.prepState(model)) { UpNext.shared.save(model) }
            window?.close()
        }, onSave: {
            guard !model.target.isEmpty else { return }
            UpNext.shared.save(model)
            model.note = ""
            window?.close()
        }, onSwitch: {
            UpNext.shared.save(model)
            delegate.confirmSwitch(to: model, on: window)
        }, onRemove: {
            UpNext.shared.remove(model)
            window?.close()
        }, onPrepare: {
            // 0.10.0 (Meeting Sheet, phase 4): Prepare opens Quick or Expert for this call
            AnalyticsTracker.shared.action("prepare", scr: "get_ready")       // 0.19.0 (S4)
            UpNext.shared.save(model)
            window?.close()
            SheetPrepWindow.show(model)
        })
        let host = NSHostingController(rootView: Localized { view.askBar() })   // 0.26.0: End and start asked inline
        let w = window ?? NSWindow(contentViewController: host)
        w.tabbingMode = .disallowed      // 0.8.7 (A1): never tabs
        w.contentViewController = host
        w.styleMask.insert(.resizable)
        w.setContentSize(NSSize(width: 640, height: 820))
        w.title = mode == .prepare ? L("call.title.prepare") : mode == .plan ? L("call.title.plan") : L("call.title.start")
        w.isReleasedWhenClosed = false
        window = w
        AskCenter.watch(w)      // 0.26.0 (review 1)
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
