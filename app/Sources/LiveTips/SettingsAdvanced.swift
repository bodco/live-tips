import AVFoundation
import AppKit
import SwiftUI
import LiveTipsCore

// 0.25 (R5, owner 18.11): Settings with what is needed on top of each pane and the rest under one collapsed
// Advanced at the bottom (its state is kept per pane, the search opens it), the "Pacenote is ready" card on top of
// General, the AI pane as three provider cards with one "Pacenote uses" line (the F3 rule), and Who is speaking,
// moved from AI to Transcription.

/// The row that opens and closes a pane's Advanced. The pane shows its Advanced sections while
/// `@AppStorage(SettingsSearch.advancedKey(scope))` is "1" (both read the same UserDefaults key).
struct SettingsAdvancedHeader: View {
    let summary: String
    var inForm = true
    @AppStorage private var raw: String

    init(_ scope: String, summary: String, inForm: Bool = true) {
        self.summary = summary
        self.inForm = inForm
        _raw = AppStorage(wrappedValue: "0", SettingsSearch.advancedKey(scope))
    }

    private var open: Bool { raw == "1" }

    private var row: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { raw = open ? "0" : "1" } } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "chevron.right").font(PN.sys(11, .semibold)).foregroundStyle(PN.C.text3)
                    .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("set.advanced")).font(PN.sys(13, .semibold)).foregroundStyle(PN.C.text)
                    Text(summary).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("set.advanced"))
        .accessibilityValue(L(open ? "adv.open" : "adv.closed"))
        .accessibilityHint(summary)
    }

    var body: some View {
        if inForm { Section { row } } else { row.padding(.horizontal, 14).padding(.vertical, 10) }
    }
}

// MARK: - Pacenote is ready

/// On top of General: the account, the AI, the microphone and the call's sound, the screen when calls are recorded
/// with the screen, Notion's meeting database when Notion is connected, and the components. Fix next to each problem.
struct PacenoteReadyCard: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var acct = PacenoteAccount.shared
    @ObservedObject private var runner = PrepRunner.shared
    @ObservedObject private var codex = CodexAccount.shared
    @ObservedObject private var agy = AgyAccount.shared
    @ObservedObject private var setup = SetupWindow.model
    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var sysAudio = SystemAudioPermission.granted()
    @State private var screen = ScreenPermission.granted()

    struct Item: Identifiable {
        let id: String
        let title: String
        let detail: String
        let ok: Bool?            // nil: nothing to fix yet (asked at the first call, still checking)
        var fix: (() -> Void)?
    }

    var items: [Item] {
        var out: [Item] = []
        if let s = acct.session {
            out.append(Item(id: "account", title: L("ready.account"), detail: L("ready.account.ok", ["email": s.email.isEmpty ? s.name : s.email]), ok: true))
        } else {
            out.append(Item(id: "account", title: L("ready.account"), detail: L("ready.account.no"), ok: false, fix: { model.tab = "account" }))
        }
        let conn = AIRoute.confirmed()
        if conn.isEmpty {
            out.append(Item(id: "ai", title: L("ready.ai"), detail: L("ready.ai.no"), ok: false, fix: { model.tab = "ai" }))
        } else {
            let missing = AIUsesSection.jobMissing(model.config.ai, conn)
            var it = Item(id: "ai", title: L("ready.ai"), detail: AIUsesSection.usesText(model.config.ai, conn), ok: !missing)
            if missing { it.fix = { model.tab = "ai" } }
            out.append(it)
        }
        switch mic {
        case .authorized: out.append(Item(id: "mic", title: L("ready.mic"), detail: L("ready.allowed"), ok: true))
        case .notDetermined:
            out.append(Item(id: "mic", title: L("ready.mic"), detail: L("ready.notAsked"), ok: false, fix: {
                AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { mic = AVCaptureDevice.authorizationStatus(for: .audio) } }
            }))
        default:
            out.append(Item(id: "mic", title: L("ready.mic"), detail: L("ready.notAllowed"), ok: false, fix: {
                Self.openPrivacy("Privacy_Microphone")
            }))
        }
        switch sysAudio {
        case .some(true): out.append(Item(id: "sound", title: L("ready.sound"), detail: L("ready.allowed"), ok: true))
        case .some(false): out.append(Item(id: "sound", title: L("ready.sound"), detail: L("ready.notAllowed"), ok: false, fix: { Self.openPrivacy("Privacy_AudioCapture") }))
        case .none: out.append(Item(id: "sound", title: L("ready.sound"), detail: L("ready.sound.later"), ok: nil))
        }
        if model.config.recording.kind == "video" {
            out.append(screen ? Item(id: "screen", title: L("ready.screen"), detail: L("ready.allowed"), ok: true)
                       : Item(id: "screen", title: L("ready.screen"), detail: L("ready.notAllowed"), ok: false, fix: {
                           if !ScreenPermission.request() { ScreenPermission.openSettings() }
                           screen = ScreenPermission.granted()
                       }))
        }
        if model.isSet(.notionToken) {
            out.append(model.config.notionMeetingsDB.isEmpty
                       ? Item(id: "notion", title: "Notion", detail: L("int.notion.noDB"), ok: false, fix: { model.tab = "integrations"; model.integration = "notion" })
                       : Item(id: "notion", title: "Notion", detail: L("ready.notion.ok", ["name": model.config.notionMeetingsName.isEmpty ? "Notion" : model.config.notionMeetingsName]), ok: true))
        }
        let checking = setup.steps.allSatisfy { $0.state == .unknown || $0.state == .checking }
        if setup.allRequiredOK {
            out.append(Item(id: "components", title: L("ready.components"), detail: L("ready.components.ok"), ok: true))
        } else if checking {
            out.append(Item(id: "components", title: L("ready.components"), detail: L("common.checking"), ok: nil))
        } else {
            out.append(Item(id: "components", title: L("ready.components"), detail: L("ready.components.no"), ok: false, fix: { model.tab = "components" }))
        }
        return out
    }

    static func openPrivacy(_ anchor: String) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + anchor) { NSWorkspace.shared.open(u) }
    }

    func refresh() {
        mic = AVCaptureDevice.authorizationStatus(for: .audio)
        sysAudio = SystemAudioPermission.granted()
        screen = ScreenPermission.granted()
    }

    var body: some View {
        let its = items
        let todo = its.filter { $0.ok == false }.count
        Section {
            HStack(spacing: 8) {
                Image(systemName: todo == 0 ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(todo == 0 ? PN.C.turn : PN.C.onMe)
                Text(todo == 0 ? L("ready.title") : L("ready.title.todo", ["n": "\(todo)"])).font(PN.sys(15, .semibold))
                Spacer()
                Button(L("ready.check")) { refresh(); Task { await setup.checkAll() }; runner.refreshAuth(); codex.refresh(); agy.refresh() }
                    .buttonStyle(.pnTertiary).disabled(setup.busy)
            }
            .accessibilityElement(children: .combine)
            ForEach(its) { it in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: it.ok == true ? "checkmark.circle.fill" : (it.ok == false ? "exclamationmark.circle.fill" : "circle.dotted"))
                        .foregroundStyle(it.ok == true ? PN.C.turn : (it.ok == false ? PN.C.onMe : PN.C.text3))
                        .frame(width: 16)
                    Text(it.title).frame(width: 130, alignment: .leading)
                    Text(it.detail).font(PN.Font.caption).foregroundStyle(it.ok == false ? PN.C.text : PN.C.text3)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if let f = it.fix, it.ok == false {
                        Button(L("ready.fix"), action: f).buttonStyle(.pnSecondary)
                            .accessibilityLabel(L("ready.fix") + ": " + it.title)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .onAppear {
            refresh()
            if setup.steps.allSatisfy({ $0.state == .unknown }) { Task { await setup.checkAll() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }
}

// MARK: - AI: what Pacenote uses, three provider cards

/// "Pacenote uses: X" over the AIs that are surely connected (AIRoute.confirmed), by the F3 rule (AIDefaults.pick).
struct AIUsesSection: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var runner = PrepRunner.shared
    @ObservedObject private var codex = CodexAccount.shared
    @ObservedObject private var agy = AgyAccount.shared

    /// One AI for every job, or the preparation (and notes) and the tips apart.
    static func usesText(_ r: AppConfig.AIRoutes, _ conn: Set<String>) -> String {
        let prep = AIDefaults.pick(job: "prep", chosen: r.prep, connected: conn)
        let after = AIDefaults.pick(job: "after", chosen: r.after, connected: conn)
        let tips = AIDefaults.pick(job: "tips", chosen: r.tips, connected: conn)
        // R5 shots 18.11: pick() falls back to the chosen AI when nothing connected may do the job (only the model on
        // this Mac, which never gives tips), so a job without a connected AI is named as such, not as the chosen one.
        func name(_ id: String) -> String { conn.contains(id) ? AIRoute.name(id) : L("ai.uses.missing") }
        if prep == tips && after == prep { return name(prep) }
        if after == prep { return L("ai.uses.two", ["prep": name(prep), "tips": name(tips)]) }
        return L("ai.uses.three", ["prep": name(prep), "tips": name(tips), "after": name(after)])
    }

    /// Whether some job (preparation, tips, after the call) has no connected AI that may do it.
    static func jobMissing(_ r: AppConfig.AIRoutes, _ conn: Set<String>) -> Bool {
        [("prep", r.prep), ("after", r.after), ("tips", r.tips)].contains { !conn.contains(AIDefaults.pick(job: $0.0, chosen: $0.1, connected: conn)) }
    }

    var body: some View {
        let conn = AIRoute.confirmed()
        let warn = conn.isEmpty || Self.jobMissing(model.config.ai, conn)
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: warn ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(warn ? PN.C.onMe : PN.C.turn)
                VStack(alignment: .leading, spacing: 2) {
                    Text(conn.isEmpty ? L("ai.uses.none") : L("ai.uses", ["name": Self.usesText(model.config.ai, conn)]))
                        .font(PN.sys(13, .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(L("ai.uses.sub")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        }
        .onAppear { runner.refreshAuth() }
    }
}

/// One provider: its name, what is connected (account, API key) and Connect; Connect or Manage opens the account row
/// and the key.
struct AIProviderCard: View {
    let provider: String          // claude | chatgpt | gemini
    @ObservedObject var model: SettingsModel
    @ObservedObject private var runner = PrepRunner.shared
    @ObservedObject private var codex = CodexAccount.shared
    @ObservedObject private var agy = AgyAccount.shared
    @State private var open = false

    private var key: SecretStore.Key { provider == "claude" ? .claudeAPIKey : provider == "chatgpt" ? .openaiAPIKey : .geminiAPIKey }
    private var name: String { provider == "claude" ? "Claude" : provider == "chatgpt" ? "ChatGPT" : "Gemini" }
    private var accountOn: Bool {
        switch provider {
        case "claude": return PrepRunner.claudePath != nil && runner.loggedIn == true
        case "chatgpt": return CodexAccount.cliPath != nil && codex.signedIn == true
        default: return AgyAccount.cliPath != nil && agy.signedIn == true
        }
    }
    private var status: String {
        var parts: [String] = []
        if accountOn { parts.append(L("ai.card.account")) }
        if model.isSet(key) { parts.append(L("ai.card.key")) }
        return parts.isEmpty ? L("int.notConnected") : parts.joined(separator: " · ")
    }
    private var connected: Bool { accountOn || model.isSet(key) }
    private var anchor: String { provider == "claude" ? "ai.claude" : provider == "chatgpt" ? "ai.openai" : "ai.gemini" }

    var body: some View {
        Section {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(PN.sys(14, .semibold))
                    Text(L("ai.card.sub." + provider)).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                IntegrationStatus(text: status, ok: connected ? true : nil).fixedSize()
                if connected {
                    Button(L(open ? "ai.card.done" : "ai.card.manage")) { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } }.buttonStyle(.pnTertiary)
                } else {
                    Button(L(open ? "ai.card.done" : "int.connect")) { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } }
                        .buttonStyle(open ? AnyButtonStyle(.pnTertiary) : AnyButtonStyle(.pnPrimary))
                }
            }
            .modifier(ProviderAnchor(provider: provider))
            .accessibilityElement(children: .contain)
            if open {
                switch provider {
                case "claude":
                LabeledContent(L("ai.access.account")) {
                    HStack(spacing: 8) {
                        if PrepRunner.claudePath == nil {
                            Text(L("set.cc.notInstalled")).foregroundStyle(PN.C.text3)
                            Button(L("acct.connect")) { AccountLogin.shared.connect("claude") }       // 0.24.1 (F1): installs Claude Code, then signs in
                        } else {
                            Image(systemName: runner.loggedIn == true ? "checkmark.circle.fill" : (runner.loggedIn == false ? "exclamationmark.triangle.fill" : "circle.dotted"))
                                .foregroundStyle(runner.loggedIn == true ? PN.C.turn : (runner.loggedIn == false ? PN.C.onMe : PN.C.text3))
                            Text(runner.loggedIn == true ? L("set.cc.signedIn") + (runner.authInfo.isEmpty ? "" : " (\(runner.authInfo))")
                                 : runner.loggedIn == false ? L("set.cc.notSignedIn") : L("set.cc.checking"))
                                .foregroundStyle(PN.C.text3)
                            if runner.loggedIn == false { Button(L("set.logIn")) { runner.openLogin() } }
                            Button(L("set.check")) { runner.refreshAuth() }
                        }
                    }
                }
                .help(L("ai.access.accountHelp"))
                    .help(L("ai.access.accountHelp"))
                    AccountLoginStatus(kind: "claude")
                    KeyRow(title: L("keys.claude.title"), hint: L("keys.claude.hint"), key: .claudeAPIKey, model: model)
                case "chatgpt":
                    CodexAccountRow()
                    KeyRow(title: L("keys.openai.title"), hint: L("keys.openai.hint"), key: .openaiAPIKey, model: model)
                default:
                    AgyAccountRow()
                    KeyRow(title: L("keys.gemini.title"), hint: L("keys.gemini.hint"), key: .geminiAPIKey, model: model)
                }
                Text(L("ai.access.footer." + provider)).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: model.highlight) { _, id in if id == anchor { open = true } }
    }
}

/// The search target of a provider card (the ids the search entries name).
private struct ProviderAnchor: ViewModifier {
    let provider: String
    @ViewBuilder func body(content: Content) -> some View {
        switch provider {
        case "claude": content.settingsAnchor("ai.claude")
        case "chatgpt": content.settingsAnchor("ai.openai")
        default: content.settingsAnchor("ai.gemini")
        }
    }
}

/// A button style chosen at run time (Connect is the primary button until the card is open).
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView
    init<S: ButtonStyle>(_ s: S) { make = { AnyView(s.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

// MARK: - Transcription: who is speaking (moved from AI > On this Mac)

struct SpeakersSection: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
            Section {
                Toggle(L("set.identifySpeakers"), isOn: $model.config.speakersEnabled)
                    .help(L("set.tellsTheVoicesOn"))
                    .onChange(of: model.config.speakersEnabled) { LocalAIService.shared.apply() }
                LabeledContent(L("set.status")) {
                    let st = LocalAIService.shared.speakersLine()
                    HStack(spacing: 6) {
                        Image(systemName: st.ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(st.ok ? PN.C.turn : (model.config.speakersEnabled ? PN.C.onMe : PN.C.text3))
                        Text(st.text).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                        Spacer()
                        Button(L("set.voiceLibrary")) {
                            NSWorkspace.shared.open(URL(fileURLWithPath: (CallEngine.shared.appRoot as NSString).appendingPathComponent("voices")))
                        }.controlSize(.small)
                    }
                }
                DisclosureGroup(L("set.voiceLibraryN", ["n": "\(model.voices.count)"])) {
                    if model.voices.isEmpty { Text(L("set.nobodyYetNamesYou")).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
                    ForEach(model.voices) { v in
                        HStack {
                            Text(v.name)
                            Spacer()
                            Menu(v.side == "team" ? L("set.sideTeam") : (v.side == "client" ? L("set.sideClient") : L("set.sideUnknown"))) {
                                Button { model.setVoiceSide(v.name, "team") } label: { v.side == "team" ? Label(L("set.teamOurs"), systemImage: "checkmark") : Label(L("set.teamOurs"), systemImage: "person.2") }
                                Button { model.setVoiceSide(v.name, "client") } label: { v.side == "client" ? Label(L("set.clientSide"), systemImage: "checkmark") : Label(L("set.clientSide"), systemImage: "building.2") }
                            }
                            .menuStyle(.borderlessButton).fixedSize().font(PN.Font.caption)
                            .foregroundStyle(v.side == "team" ? Color.accentColor : .primary)
                            .disabled(CallEngine.shared.isRunning)
                            .help(L("set.whichSideThisPerson"))
                            Menu(SettingsModel.whereLabel(v.wherer)) {
                                ForEach(model.voiceWheres, id: \.tag) { sc in
                                    Button { model.toggleVoiceWhere(v.name, sc.tag) } label: {
                                        if v.wherer.contains(sc.tag) { Label(sc.label, systemImage: "checkmark") } else { Text(sc.label) }
                                    }
                                }
                            }
                            .menuStyle(.borderlessButton).fixedSize().font(PN.Font.caption)
                            .disabled(CallEngine.shared.isRunning)
                            .help(L("set.theCallsThisVoice"))
                            Text("\(v.calls) call\(v.calls == 1 ? "" : "s")").font(PN.Font.caption).foregroundStyle(PN.C.text3)
                            Menu(L("set.mergeInto")) {
                                ForEach(model.voices.filter { $0.name != v.name }) { o in
                                    Button(o.name) { model.mergeAsk = .init(a: v.name, b: o.name) }
                                }
                            }
                            .menuStyle(.borderlessButton).fixedSize().font(PN.Font.caption)
                            .disabled(CallEngine.shared.isRunning || model.voices.count < 2)
                            .help(L("set.mergeHelp", ["name": v.name]))
                            Button(L("people.names")) { model.personSheet = v.name }.controlSize(.small).disabled(CallEngine.shared.isRunning)
                                .help(L("people.namesHelp", ["name": v.name]))
                            Button(L("set.forget")) { model.forgetVoice(v.name) }.controlSize(.small).disabled(CallEngine.shared.isRunning)
                                .help(L("set.removesThisPersonS"))
                        }
                    }
                let al = model.voiceAliases
                if !al.isEmpty {
                    Text(L("set.aliases", ["list": al.sorted { $0.key < $1.key }.map { "\($0.key) → \($0.value)" }.joined(separator: ", ")]))
                        .font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                }
                }
                .onAppear { model.loadVoices() }
                .sheet(item: $model.mergeAsk) { ask in MergeNameSheet(model: model, ask: ask) }
                .sheet(item: Binding(get: { model.personSheet.map { PersonName(name: $0) } }, set: { model.personSheet = $0?.name })) { p in
                    PersonNamesSheet(model: model, name: p.name)
                }
            } header: { Text(L("set.speakers")).settingsAnchor("tr.speakers") } footer: {
                Text(L("set.inTheTipsWindow"))
                    .font(PN.Font.caption).foregroundStyle(PN.C.text3)
            }
    }
}
