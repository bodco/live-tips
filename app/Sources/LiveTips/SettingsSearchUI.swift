import AppKit
import SwiftUI
import LiveTipsCore

// 0.15.0 (D2): search in Settings, the segments of the long panes, the consent section (moved from General to
// Call recording) and a project's own page.

extension SettingsModel {
    /// The result's title in both interface languages (a query in either finds it), the current one first.
    static func searchTitles(_ e: SettingsSearchEntry) -> [String] {
        let cur = L(e.titleKey), other = L10n.table(L10n.lang == "uk" ? "en" : "uk")[e.titleKey] ?? ""
        return other.isEmpty || other == cur ? [cur] : [cur, other]
    }

    /// The pane and group names in both languages, so "AI" or "Notion" finds what lives there.
    static func searchExtra(_ e: SettingsSearchEntry) -> String {
        var keys = ["settings.tab." + e.pane]
        if let g = e.group { keys.append(groupKey(e, g)) }
        return keys.flatMap { k in [L10n.table("en")[k] ?? "", L10n.table("uk")[k] ?? ""] }.joined(separator: " ")
            + " " + (e.integration ?? "")
    }

    /// The string of a result's group: "Advanced" (0.25 R5) or a HubSpot tab.
    static func groupKey(_ e: SettingsSearchEntry, _ g: String) -> String {
        g == "advanced" ? "set.advanced" : "hs.group." + g
    }

    /// "Integrations › Notion › Advanced", "Projects › Orbit".
    func searchPath(_ e: SettingsSearchEntry) -> String {
        var parts = [L("settings.tab." + e.pane)]
        if let i = e.integration, let it = IntegrationRegistry.items.first(where: { $0.id == i }) { parts.append(it.title) }
        if let g = e.group { parts.append(L(Self.groupKey(e, g))) }
        if e.projectPage, let p = searchProject { parts.append(p.name) }
        return parts.joined(separator: " › ")
    }

    /// The project a project setting opens: the one open now, else the first active one.
    var searchProject: Project? {
        if let s = projectDetail, let p = registry.projects.first(where: { $0.slug == s }) { return p }
        return registry.projects.first { $0.status != "archived" } ?? registry.projects.first
    }

    var searchResults: [SettingsSearchEntry] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return SettingsSearch.find(q, titles: Self.searchTitles, extra: Self.searchExtra)
            .filter { !$0.projectPage || searchProject != nil }
    }

    /// Opens the pane and group of a result and marks the row for a moment.
    func jump(_ e: SettingsSearchEntry) {
        let project = e.projectPage ? searchProject?.slug : nil
        for (k, v) in e.defaults { UserDefaults.standard.set(v, forKey: k) }
        tab = e.pane
        integration = e.integration
        projectDetail = project
        highlight = nil
        DispatchQueue.main.async { self.highlight = e.id }
    }
}

/// Marks a row or a section header as a search target: it scrolls into view and glows for a moment.
struct SettingsAnchor: ViewModifier {
    let id: String
    @ObservedObject var model = SettingsWindow.model
    func body(content: Content) -> some View {
        content
            .id(id)
            .background(
                RoundedRectangle(cornerRadius: PN.r(6))
                    .fill(Color.yellow.opacity(model.highlight == id ? 0.28 : 0))
                    .padding(-4)
                    .animation(.easeOut(duration: 0.3), value: model.highlight)
            )
    }
}

extension View {
    func settingsAnchor(_ id: String) -> some View { modifier(SettingsAnchor(id: id)) }
}

/// The search field on top of the Settings sidebar. Command-F focuses it, Escape clears it, Return opens the first result.
struct SettingsSearchField: View {
    @ObservedObject var model: SettingsModel
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(PN.sys(12)).foregroundStyle(PN.C.text3)
            TextField("", text: $model.search, prompt: Text(L("search.placeholder")))
                .textFieldStyle(.plain).focused($focused)
                .onSubmit { if let e = model.searchResults.first { model.jump(e) } }
                .onExitCommand { model.search = "" }
            if !model.search.isEmpty {
                Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(PN.C.text3) }
                    .buttonStyle(.plain).accessibilityLabel(L("search.clear"))
            }
        }
        .padding(.horizontal, 7).frame(height: 26)
        .background(RoundedRectangle(cornerRadius: PN.r(7)).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: PN.r(7)).stroke(Color.secondary.opacity(focused ? 0.5 : 0.2)))
        .background(Button("") { focused = true }.keyboardShortcut("f", modifiers: .command).opacity(0).frame(width: 0, height: 0))
        .padding(.bottom, 6)
    }
}

/// What the sidebar shows while there is a query: "Title" over "Pane › Group".
struct SettingsSearchResults: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        let rs = model.searchResults
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                Text(L("search.results", ["n": "\(rs.count)"])).pnLabel().foregroundStyle(PN.C.text3)
                    .padding(.horizontal, 8).padding(.bottom, 2)
                ForEach(rs, id: \.id) { e in
                    Button { model.jump(e) } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L(e.titleKey)).lineLimit(2).foregroundStyle(model.highlight == e.id ? PNSelect.ink : PN.C.text)
                            Text(model.searchPath(e)).font(PN.Font.caption)
                                .foregroundStyle(model.highlight == e.id ? PNSelect.ink.opacity(0.75) : PN.C.text3).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .background(RoundedRectangle(cornerRadius: PN.r(6)).fill(model.highlight == e.id ? PNSelect.fill : .clear))
                    }
                    .buttonStyle(.plain)
                }
                if rs.isEmpty {
                    Text(L("search.none")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 8).padding(.top, 4)
                }
            }
        }
    }
}

/// The segments on top of a long pane and one line about the group shown (AI, General, Notion, HubSpot).
struct SettingsSegments: View {
    @Binding var selection: String
    let groups: [String]
    /// "gen.group." reads gen.group.<g> and gen.group.sub.<g>
    let prefix: String
    var caption = true
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PNTabs(selection: $selection, options: groups.map { ($0, L(prefix + $0)) })
            .labelsHidden().fixedSize()
            if caption { Text(L(prefix + "sub." + selection)).font(PN.Font.caption).foregroundStyle(PN.C.text3) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { if !groups.contains(selection) { selection = groups[0] } }
    }
}

/// 0.15.0 (D2): the recording consent, moved from General to Call recording (the text for recorded calls was there).
struct ConsentSection: View {
    @ObservedObject var model: SettingsModel
    var body: some View {
        Section {
            Toggle(isOn: $model.config.consentSay) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("set.playAnAudioConsent"))
                    Text(L("set.whenARecordingStarts"))
                        .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                }
            }
            Toggle(isOn: $model.config.consentChat) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("set.copyAConsentMessage"))
                    Text(L("set.whenARecordingStarts2"))
                        .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                }
            }
            if model.config.consentSay || model.config.consentChat {
                TextField("English", text: $model.config.consentTextEN, axis: .vertical).lineLimit(2...4)
                TextField("Українська", text: $model.config.consentTextUK, axis: .vertical).lineLimit(2...4)
                // 0.9.5: the same message when the call is also recorded
                Text(L("set.consentRecorded")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                TextField("English", text: $model.config.consentRecTextEN, axis: .vertical).lineLimit(2...4)
                TextField("Українська", text: $model.config.consentRecTextUK, axis: .vertical).lineLimit(2...4)
            }
        } header: { Text(L("set.recordingConsent")).settingsAnchor("rec.consent") } footer: {
            Text(L("set.offByDefaultThe"))
                .font(PN.Font.caption).foregroundStyle(PN.C.text3)
        }
    }
}

/// 0.15.0 (D2): one line under a project's name in Settings > Projects: Notion, Sales, cards, what is off.
enum ProjectMeta {
    @MainActor static func line(_ p: Project, model: SettingsModel) -> String {
        var parts: [String] = []
        if p.sample { parts.append(L("proj.meta.sample")) }            // 0.17.0 (5.1)
        if p.status == "archived" { parts.append(L("proj.meta.off")) }
        if p.root.isEmpty { parts.append(L("set.noFolder")) }
        if model.notionConnected { parts.append(L("proj.meta.notion", ["name": p.notionValue.isEmpty ? p.name : p.notionValue])) }
        if p.salesEnabled {
            let m = SalesMethods.shared.methods.first { $0.key == p.salesMethod }?.name ?? p.salesMethod
            parts.append(m.isEmpty ? L("proj.sales") : L("proj.meta.sales", ["method": m]))
        }
        if !p.root.isEmpty { let n = AnswerCards.count(root: p.root); if n > 0 { parts.append(L("proj.meta.cards", ["n": "\(n)"])) } }
        if !p.apiAllowed { parts.append(L("proj.meta.aiOff")) }
        if p.serverSync { parts.append(L("proj.meta.sync")) }
        if p.linkedToOrgProject { parts.append(p.orgProjectName.isEmpty ? L("proj.org.head") : p.orgProjectName) }   // 0.17.0 (D38)
        return parts.joined(separator: " · ")
    }
}

/// 0.15.0 (D2): a project's own page (Settings > Projects > a project). Everything the row used to carry inline
/// and in its "…" menu, in short sections.
struct ProjectSettingsPage: View {
    @ObservedObject var model: SettingsModel
    let slug: String
    @ObservedObject private var account = PacenoteAccount.shared
    @State private var removing = false          // 0.17.0 (Bohdan 16.11): Remove asks first; the folder stays by default
    var body: some View {
        if let i = model.registry.projects.firstIndex(where: { $0.slug == slug }) {
            let p = model.registry.projects[i]
            VStack(alignment: .leading, spacing: 0) {
                Button { model.projectDetail = nil } label: {
                    HStack(spacing: 4) { Image(systemName: "chevron.left"); Text(L("proj.back")).lineLimit(1) }
                }
                .buttonStyle(.pnTertiary).keyboardShortcut("[", modifiers: .command)
                .help(L("nav.back.help"))
                .padding(.horizontal, 20).padding(.top, 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).font(PN.sys(20, .semibold))
                    Text(p.root.isEmpty ? L("set.noFolder") : p.root).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                        .lineLimit(1).truncationMode(.middle)
                }
                .padding(.horizontal, 28).padding(.top, 4)
                Form {
                    ProjectCardSection(model: model, index: i)       // 0.17.0 (5.2, 5.1): name, card, links; the sample note
                    if p.linkedToOrgProject {
                        OrgCardSection(model: model, index: i)       // 0.17.0 (contract 9 block 3): the organization project's card
                        OrgStateSection(project: p)                  // 0.17.0 (contract 9 blocks 5-6): state, sources, index, history
                        OrgSourcesSection(project: p)
                        OrgIndexSection(project: p)
                        OrgHistorySection(project: p)
                    }
                    Section {
                        Toggle(L("proj.offer"), isOn: Binding(get: { model.registry.projects[i].status != "archived" },
                                                              set: { model.registry.projects[i].status = $0 ? "active" : "archived" }))
                            .help(L("set.activeOfferedInStart"))
                        LabeledContent(L("proj.inNotion")) {
                            NotionValuePicker(value: $model.registry.projects[i].notionValue, fallback: p.name, model: model)
                                .disabled(!model.notionConnected)
                        }
                        .help(L("proj.inNotion.help")).settingsAnchor("pr.notion")
                        Toggle(L("proj.sales"), isOn: $model.registry.projects[i].salesEnabled)
                            .help(L("proj.sales.help")).settingsAnchor("pr.sales")
                        if p.salesEnabled { SalesMethodPicker(selection: $model.registry.projects[i].salesMethod) }
                        LabeledContent(L("search.cards")) {
                            Button(L("proj.cards", ["n": "\(AnswerCards.count(root: p.root))"])) { AnswerCards.show(project: p) }
                                .disabled(p.root.isEmpty)
                        }
                        .help(L("proj.cards.help")).settingsAnchor("pr.cards")
                    }
                    ProjectOrgSection(model: model, index: i)      // 0.17.0 (B6b, D38): organization, link, private
                    Section {
                        Toggle(L("set.useClaudeForTips"), isOn: $model.registry.projects[i].apiAllowed).settingsAnchor("pr.ai")
                        Toggle(isOn: $model.registry.projects[i].index.enabled) {
                            HStack {
                                Text(L("set.searchThisFolder"))
                                Spacer()
                                Button(L("set.reindexNow")) { IndexService.shared.reindex(p.root) }
                                    .buttonStyle(.pnTertiary).disabled(!p.index.enabled || p.root.isEmpty)
                            }
                        }
                        .settingsAnchor("pr.index")
                        // 0.12.0 (B8b): off by default; only with a Pacenote account (Settings > Account)
                        Toggle(isOn: $model.registry.projects[i].serverSync) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L("set.syncToServer"))
                                if !account.signedIn && !p.serverSync {
                                    Text(L("proj.syncNeedsAccount", ["account": L("settings.tab.account")]))
                                        .font(PN.Font.caption).foregroundStyle(PN.C.text3)
                                }
                            }
                        }
                        .disabled(!account.signedIn && !p.serverSync)
                        .settingsAnchor("pr.sync")
                    } header: { Text(L("proj.leaves")) }
                    Section {
                        HStack {
                            Button(L("home.recent.finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p.root)]) }
                                .buttonStyle(.pnTertiary).disabled(p.root.isEmpty)
                            Spacer()
                            Button(L("set.removeProjectFromPacenote"), role: .destructive) { removing = true }
                                .buttonStyle(.pnTertiary)
                                .sheet(isPresented: $removing) {
                                    RemoveProjectSheet(project: p) { trash in
                                        removing = false
                                        guard let trash else { return }
                                        model.projectDetail = nil
                                        model.excludeProject(p.slug)
                                        if trash, !p.root.isEmpty {
                                            NSWorkspace.shared.recycle([URL(fileURLWithPath: p.root)]) { _, err in
                                                if let err { MainActor.assumeIsolated { model.note = L("proj.remove.trashErr", ["e": err.localizedDescription]) } }
                                            }
                                        }
                                        UsageLog.log("project_removed", ["sample": p.sample, "trash": trash])
                                    }
                                }
                        }
                    }
                }
                .formStyle(.grouped).toggleStyle(.pnSwitch)
                // S5: a project linked to an organization project is that project's page (card, registers, state,
                // sources, index, history in one scroll, so no part); other projects stay settings > projects
                .trackScreen("org_project", o: p.orgProjectOrg, on: p.linkedToOrgProject)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Color.clear.onAppear { model.projectDetail = nil }
        }
    }
}

/// 0.17.0 (Bohdan 16.11): "Remove <project> from Pacenote?" The folder on the Mac stays unless the PM ticks "Also move
/// the folder to the Trash" (off by default). `done(nil)` cancels; `done(true)` removes and moves the folder to the Trash.
struct RemoveProjectSheet: View {
    let project: Project
    var done: (Bool?) -> Void
    @State private var trash = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("proj.remove.title", ["name": project.name])).font(PN.sys(.headline, 13, .semibold))
            Text(L("proj.remove.sub")).font(PN.Font.body).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
            if !project.root.isEmpty {
                Toggle(L("proj.remove.trash"), isOn: $trash).toggleStyle(.pnCheckbox)
                Text(trash ? L("proj.remove.trashSub", ["path": project.root.replacingOccurrences(of: NSHomeDirectory(), with: "~")])
                           : L("proj.remove.keepSub", ["path": project.root.replacingOccurrences(of: NSHomeDirectory(), with: "~")]))
                    .font(PN.Font.caption).foregroundStyle(trash ? PN.C.danger : PN.C.text3).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(L("common.cancel")) { done(nil) }.buttonStyle(.pnTertiary).keyboardShortcut(.cancelAction)
                if trash {      // moving files to the Trash is never the Return key
                    Button(L("proj.remove.okTrash"), role: .destructive) { done(true) }.buttonStyle(.pnPrimary)
                } else {
                    Button(L("proj.remove.ok")) { done(false) }.buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20).frame(width: 440)
    }
}
