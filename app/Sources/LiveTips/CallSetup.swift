import AppKit
import SwiftUI
import LiveTipsCore

// Pacenote 0.8 (F4, REDESIGN-SPEC 5): one form for Prepare, Start call and Plan a call. Always in sight: the
// project, the call's name, its date and time (with the calendar event it comes from), What matters on this call
// with the added folders and files, and the brief in one line. The rest is under Options, with labels. Hints only
// where something is wrong; longer explanations behind (i).

enum CallSetupMode { case start, prepare, plan }

struct CallSetupView: View {
    @ObservedObject var model: StartCallModel
    @ObservedObject var runner = PrepRunner.shared
    @ObservedObject var upnext = UpNext.shared
    @ObservedObject private var cal = CalendarService.shared
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
    @FocusState private var titleFocus: Bool

    private var saved: Bool { upnext.contains(model) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if live { liveBanner }
                    // 0.8.5 (P1): block 1 and block 2 never move; the type section is always last, so switching
                    // the type changes only that section, below everything already filled.
                    block(1) { titleRow; timeRow; typeRow }
                    block(2, title: L("start.context")) { projectRow; contextBox }
                    block(3) { typeSection }
                    briefLine
                    if let h = problemHint { Label(h, systemImage: "info.circle").font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true) }
                    options
                }
                .padding(24)
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(mode == .prepare ? L("call.title.prepare") : mode == .plan ? L("call.title.plan") : saved ? L("call.title.upcoming") : L("call.title.start"))
                .font(.system(size: 22, weight: .bold)).foregroundStyle(PN.C.text)
            if mode != .start {
                Text(mode == .prepare ? L("call.sub.prepare") : L("call.sub.plan")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
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
                .padding(10).contentShape(Rectangle())
                .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.s))
                .overlay(RoundedRectangle(cornerRadius: PN.Radius.s).stroke(Color.primary.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $picking, arrowEdge: .bottom) { projectPicker }
        }
    }

    private var projectPicker: some View {
        let q = search.lowercased()
        let ws = model.registry.workspaces.filter { q.isEmpty || $0.name.lowercased().contains(q) }
        let ps = model.registry.projects.filter { $0.status != "archived" && (q.isEmpty || $0.name.lowercased().contains(q)) }
        return VStack(alignment: .leading, spacing: 6) {
            TextField("", text: $search, prompt: Text(L("call.findProject"))).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !ps.isEmpty { Text(L("stats.projects")).font(PN.Font.caption).foregroundStyle(PN.C.text3).padding(.top, 4) }
                    ForEach(ps, id: \.slug) { p in pickRow("folder", p.name, p.workspace, "project:" + p.slug) }
                    if !ws.isEmpty { Text(L("stats.workspaces")).font(PN.Font.caption).foregroundStyle(PN.C.text3).padding(.top, 6) }
                    ForEach(ws, id: \.name) { w in pickRow("square.stack.3d.up", w.name, L("call.generalCalls"), "workspace:" + w.name) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(width: 340, height: 360)
    }

    private func pickRow(_ symbol: String, _ name: String, _ sub: String, _ tag: String) -> some View {
        Button { model.target = tag; picking = false } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(PN.C.accent).frame(width: 18)
                Text(name).foregroundStyle(PN.C.text)
                if !sub.isEmpty { Text(sub).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
                Spacer()
                if model.target == tag { Image(systemName: "checkmark").foregroundStyle(PN.C.accent) }
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(model.target == tag ? PN.C.accent.opacity(0.12) : .clear))
        }
        .buttonStyle(.plain)
    }

    // MARK: 2-3. name, date and time (from the calendar)

    private var titleRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(L("call.name"))
            TextField("", text: $model.title, prompt: Text(L("call.namePlaceholder")))
                .textFieldStyle(.roundedBorder).font(.system(size: 15))
                .focused($titleFocus)
                .onChange(of: model.title) { model.scanPrep(); copied = false }
            if let e = model.rememberedForTitle {
                HStack(spacing: 6) {
                    Text(L("call.remembered", ["title": e.title])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    Button(L("call.useSettings")) { model.apply(e); model.scanPrep() }.buttonStyle(.pnTertiary)
                }
            }
        }
    }

    private var timeRow: some View {
        let evs = cal.access == .granted ? cal.aroundNow() : []
        let tf = DateFormatter(); tf.dateFormat = "HH:mm"
        let from = model.calEventID.flatMap { id in cal.events.first { $0.id == id } }
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

    private func block<C: View>(_ n: Int, title: String? = nil, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)").font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.text3)
                .frame(width: 20, height: 20).background(Circle().fill(PN.C.surface2)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 14) {
                if let t = title { Text(t).font(PN.Font.section).foregroundStyle(PN.C.text) }
                content()
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Call type, Audience and Language next to the title and the time (P1 block 1).
    private var typeRow: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                fieldLabel(L("start.callType"))
                Picker("", selection: $model.callType) {
                    Text(L("start.type.regular")).tag("auto")
                    Text(L("start.type.presentation")).tag("presentation")
                    Text(L("callSettings.type.interview")).tag("interview")
                    Text(L("callSettings.type.transcript")).tag("transcript")
                }.labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            GridRow {
                fieldLabel(L("start.audience"))
                Picker("", selection: $model.audience) {
                    Text(L("callSettings.audience.auto")).tag("auto")
                    Text(L("callSettings.audience.client")).tag("client")
                    Text(L("callSettings.audience.team")).tag("team")
                }.labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            GridRow {
                fieldLabel(L("start.language"))
                // 0.8.7 (G4): a pop-up (suggested languages, More… with search), not a chip
                LanguageMenu(codes: Binding(get: { model.language.split(separator: "+").map(String.init) },
                                            set: { model.language = $0.joined(separator: "+"); model.languageTouched = true }))
            }
        }
    }

    /// The type section (P1 block 3): Regular hint, the Presentation block, or the interview role.
    @ViewBuilder private var typeSection: some View {
        switch model.callType {
        case "presentation":
            DeckBlock(model: model, onNeedPrep: { if !needProject() { prepareNow() } })
        case "interview":
            VStack(alignment: .leading, spacing: 6) {
                Text(L("callSettings.type.interview")).font(PN.Font.section).foregroundStyle(PN.C.text)
                Picker(L("callSettings.role"), selection: $model.hiringRole) {
                    Text(L("callSettings.role.observer")).tag("observer")
                    Text(L("callSettings.role.interviewer")).tag("interviewer")
                    Text(L("callSettings.role.coach")).tag("coach")
                }.fixedSize()
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.m))
        case "transcript":
            // rules/meeting.yaml > call_type.transcript: no tips, the summary and the follow-up after the call
            VStack(alignment: .leading, spacing: 4) {
                Text(L("callSettings.type.transcript")).font(PN.Font.section).foregroundStyle(PN.C.text)
                Text(L("start.transcriptHint")).font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.m))
        default:
            VStack(alignment: .leading, spacing: 4) {
                Text(L("start.type.regular")).font(PN.Font.section).foregroundStyle(PN.C.text)
                Text(L("start.regularHint")).font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.m))
        }
    }

    private func fieldLabel(_ s: String) -> some View {
        Text(s).font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.text2)
    }

    // MARK: 4. what matters on this call, with the added folders and files

    private var contextBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                fieldLabel(L("call.whatMatters"))
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
                .padding(6)
                .frame(height: 110)
                .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.s))
                .overlay(RoundedRectangle(cornerRadius: PN.Radius.s).stroke(Color.primary.opacity(0.12)))
            chips
            CRMCallRow(model: model)        // 0.8.7 (G7): only when a CRM is connected
        }
    }

    private func chip(_ symbol: String, _ name: String, on: Bool = true, help: String, toggle: @escaping () -> Void, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(name).lineLimit(1).strikethrough(!on)
            Button(action: toggle) { Image(systemName: icon) }.buttonStyle(.plain).accessibilityLabel(icon == "xmark" ? L("call.remove") : L("call.include"))
        }
        .font(PN.Font.caption)
        .foregroundStyle(on ? PN.C.accent : PN.C.text3)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: PN.Radius.s).fill(on ? PN.C.accent.opacity(0.12) : PN.C.surface2))
        .help(help)
    }

    private var chips: some View {
        HStack(alignment: .center, spacing: 6) {
            Button { model.addFolders() } label: { Label(L("call.addFolder"), systemImage: "folder.badge.plus") }
                .buttonStyle(.pnTertiary).disabled(model.target.isEmpty)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
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
                }
            }
        }
    }

    // MARK: 5. the brief, a status line (0.8.7 G2: "No brief yet" / "Brief ready · 09:40 · Open")

    @ViewBuilder private var briefLine: some View {
        let st = upnext.prepState(model)
        HStack(alignment: .center, spacing: 10) {
            if runner.running && runner.callID == model.id {
                ProgressView(value: runner.progress).frame(width: 60)
                Text(L("call.brief.writing", ["stage": runner.stage.lowercased()])).font(PN.Font.body).foregroundStyle(PN.C.text2).lineLimit(1)
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
            } else {
                Image(systemName: "doc.badge.clock").foregroundStyle(PN.C.onMe)
                Text(model.target.isEmpty ? L("call.chooseProjectFirst") : L("home.check.noBrief")).font(PN.Font.body).foregroundStyle(PN.C.text2)
                if let p = model.prep {
                    Text(L("call.brief.other", ["heading": p.heading])).font(PN.Font.caption).foregroundStyle(PN.C.text3).lineLimit(1)
                }
                Spacer()
            }
        }
        // 0.8.7 (G2): a status line, not a card; Prepare lives in the footer only
        .padding(.horizontal, 4)
    }

    private var canPrepare: Bool {
        !model.target.isEmpty && PrepRunner.claudePath != nil && (runner.useAPI ? runner.hasAPIKey : runner.loggedIn != false)
            && upnext.prepState(model) != .queued
    }

    /// Only where something is wrong (spec 5: no cryptic status line).
    private var problemHint: String? {
        if !model.note.isEmpty { return model.note }
        if PrepRunner.claudePath == nil { return L("call.hint.noClaudeCode") }
        if !runner.useAPI && runner.loggedIn == false { return L("call.hint.notSignedIn") }
        if runner.useAPI && !runner.hasAPIKey { return L("call.hint.noKey") }
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

    private func prepareNow() {
        model.note = upnext.prepare(model) ?? ""
        if !saved && model.note.isEmpty { upnext.save(model) }   // kept in Up next until the call; the window stays
    }

    // MARK: Options (with labels)

    private var proactive: Binding<Bool> {
        Binding(get: { ((UserDefaults.standard.dictionary(forKey: "prompterPrefs") ?? [:])["proactive"] as? String) == "1" },
                set: { var p = UserDefaults.standard.dictionary(forKey: "prompterPrefs") ?? [:]; p["proactive"] = $0 ? "1" : "0"
                       UserDefaults.standard.set(p, forKey: "prompterPrefs") })
    }

    private var options: some View {
        DisclosureGroup(isExpanded: $showOptions) {
            Form {
                // 0.8.7 (H2): Sales mode on top of any call type, with the method and its description
                Toggle(isOn: Binding(get: { model.salesEnabled }, set: { model.salesEnabled = $0; model.salesTouched = true })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("sales.toggle"))
                        Text(L("sales.toggle.hint")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    }
                }
                if model.salesEnabled {
                    HStack {
                        SalesMethodPicker(selection: $model.salesMethod)
                        Button { showMethod.toggle() } label: { Image(systemName: "info.circle") }.buttonStyle(.borderless)
                            .accessibilityLabel(L("sales.method.about"))
                            .popover(isPresented: $showMethod, arrowEdge: .trailing) { SalesMethodInfo(key: model.salesMethod) }
                    }
                }
                Picker(L("callSettings.mic"), selection: $model.micDevice) {
                    Text(L("callSettings.mic.default") + (model.defaultInputName.map { " (\($0))" } ?? "")).tag("default")
                    Text(L("callSettings.mic.builtin")).tag("builtin")
                    ForEach(model.micInputs.filter { !$0.builtin }, id: \.uid) { d in Text(d.name).tag("uid:" + d.uid) }
                    if model.micDevice.hasPrefix("uid:") && !model.micInputs.contains(where: { "uid:" + $0.uid == model.micDevice }) {
                        Text(L("call.mic.missing", ["name": String(model.micDevice.dropFirst(4))])).tag(model.micDevice)
                    }
                }
                Toggle(isOn: proactive) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("callSettings.proactive"))
                        Text(L("callSettings.proactive.hint")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    }
                }
                // 0.8.2 (owner): models and the way to Claude live in Settings > AI only, not per call.
                Picker(L("call.startRecording"), selection: $model.standby) {
                    Text(L("call.startRecording.whenSpeaks")).tag(true)
                    Text(L("call.startRecording.now")).tag(false)
                }
                Toggle(L("call.publicCall"), isOn: $model.publicCall)
                if let r = model.root {           // 0.8.7 (G3): the project folder in the preparation, here instead of a chip
                    Toggle(L("call.useProjectFolder"), isOn: $model.useProjectFolder)
                        .help(model.useProjectFolder ? L("call.projectFolder.on", ["path": r]) : L("call.projectFolder.off"))
                }
                if !model.prepList.isEmpty {
                    Picker(L("call.useBrief"), selection: Binding(get: { model.chosenPrep ?? "" },
                                                                 set: { model.chosenPrep = $0.isEmpty ? nil : $0; model.scanPrep() })) {
                        Text(L("call.useBrief.auto")).tag("")
                        ForEach(model.prepList, id: \.file) { p in Text("\(p.heading) · \(p.made.formatted(date: .abbreviated, time: .shortened))").tag(p.file) }
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
            }
            .formStyle(.grouped)
        } label: {
            Text(L("call.options")).font(PN.Font.section).foregroundStyle(PN.C.text)
        }
    }

    // MARK: buttons by mode (spec 5)

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 10) {
            switch mode {
            case .prepare:
                Spacer()
                Button(L("common.cancel"), action: onCancel).buttonStyle(.pnSecondary).keyboardShortcut(.cancelAction)
                Button(L("menubar.prepare")) { if !needProject() { onPrepare() } }
                    .buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction).disabled(!canPrepare && !model.target.isEmpty)
            case .start:
                Button(saved ? L("common.save") : L("call.saveForLater"), action: onSave).buttonStyle(.pnTertiary).disabled(model.target.isEmpty)
                if saved { Button(L("home.removeUpNext"), action: onRemove).buttonStyle(.pnTertiary) }
                Spacer()
                Button(L("common.cancel"), action: onCancel).buttonStyle(.pnTertiary).keyboardShortcut(.cancelAction)
                // 2026-10-29 (owner): once the brief is ready the same button prepares again (with one previous version kept).
                Button(model.prep?.matches == true ? L("talk.prepareAgain") : L("call.prepare")) {
                    if needProject() { return }
                    if model.prep?.matches == true { againClicked() } else { prepareNow() }
                }
                .buttonStyle(.pnSecondary)
                .disabled(!canPrepare || (runner.running && runner.callID == model.id))
                .confirmationDialog(L("again.title"), isPresented: $confirmAgain) {
                    Button(L("talk.prepareAgain")) { prepareNow() }
                    Button(L("common.cancel"), role: .cancel) {}
                } message: { Text(againMessage) }
                // 0.8.5 (P6, entry 1): Rehearse next to Start call as soon as the talk exists.
                // 0.8.7 (L2): Rehearse is always there; until the talk is prepared it is greyed out with the reason
                if let path = PrepDocWindow.path(for: model), model.callType == "presentation", TalkWindow.available(base: String(path.dropLast(9))) {
                    Button(L("rehearse.button")) { RehearsalWindow.show(base: String(path.dropLast(9)), title: model.effectiveTitle, call: model) }.buttonStyle(.pnSecondary)
                } else {
                    VStack(spacing: 1) {
                        Button(L("rehearse.button")) { if model.callType == "presentation" { if !needProject() { prepareNow() } } else { model.callType = "presentation" } }
                            .buttonStyle(.pnSecondary).opacity(0.5)
                        Text(model.callType == "presentation" ? L("rehearse.needPrep") : L("rehearse.onlyPresentation")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    }
                    .help(model.callType == "presentation" ? L("rehearse.needPrep") : L("rehearse.onlyPresentation"))
                }
                Button(L("home.startCall")) { if !needProject() { onStart() } }.buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
            case .plan:
                if saved { Button(L("home.removeUpNext"), action: onRemove).buttonStyle(.pnTertiary) }
                Spacer()
                Button(L("common.cancel"), action: onCancel).buttonStyle(.pnTertiary).keyboardShortcut(.cancelAction)
                Button(live ? L("call.switch") : L("home.startNow"), action: live ? onSwitch : onStart).buttonStyle(.pnSecondary).disabled(model.target.isEmpty)
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

    /// One window for the three forms. While a call is live it plans an upcoming call (Save, or switch with a
    /// confirmation); Prepare asks first what the preparation is based on (owner, 2026-10-27).
    static func show(delegate: AppDelegate, prepared: StartCallModel? = nil, planOnly: Bool = false, mode wanted: CallSetupMode? = nil) {
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
            UpNext.shared.save(model)
            let err = UpNext.shared.prepare(model)
            if let e = err { model.note = e } else { window?.close() }
        })
        let host = NSHostingController(rootView: Localized { view })
        let w = window ?? NSWindow(contentViewController: host)
        w.tabbingMode = .disallowed      // 0.8.7 (A1): never tabs
        w.contentViewController = host
        w.styleMask.insert(.resizable)
        w.setContentSize(NSSize(width: 640, height: 820))
        w.title = mode == .prepare ? L("call.title.prepare") : mode == .plan ? L("call.title.plan") : L("call.title.start")
        w.isReleasedWhenClosed = false
        window = w
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
