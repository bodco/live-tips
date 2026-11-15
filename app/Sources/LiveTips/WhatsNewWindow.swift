import AppKit
import LiveTipsCore
import SwiftUI

/// 0.16.0 (D3, rules/whatsnew.yaml): What's new after an update, personal. The items newer than the last version this
/// person saw that apply to them, and setup steps not done yet ("Choose optional add-ons" with its checkboxes right
/// here). A new person does not see it after the onboarding (the onboarding marks the version seen). The full list
/// is Settings > Help > What's new.
@MainActor
enum WhatsNewStore {
    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    static var lastSeen: String? { UserDefaults.standard.string(forKey: WhatsNew.lastSeenKey) }
    static func markSeen() { UserDefaults.standard.set(current, forKey: WhatsNew.lastSeenKey) }

    /// The rules file inside the app (engine/rules), else the repository's copy when run from the build folder.
    static var items: [WhatsNew.Item] {
        let bundled = ((Bundle.main.resourcePath ?? "") as NSString).appendingPathComponent("engine/rules/whatsnew.yaml")
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("rules/whatsnew.yaml").path
        for p in [bundled, repo] { if let t = try? String(contentsOfFile: p, encoding: .utf8) { return WhatsNew.parse(t) } }
        return []
    }

    /// What is true for this person: the provider of the preparation, modules on, the macOS version, setup done.
    static var facts: Set<String> {
        var f = Set<String>()
        let prep = SettingsWindow.model.config.ai.prep
        f.insert("provider:" + ([AIRoute.codex, AIRoute.openai].contains(prep) ? "chatgpt" : ["gemini", "agy"].contains(prep) ? "gemini" : "claude"))
        if UserDefaults.standard.object(forKey: "moduleTracker") as? Bool ?? true { f.insert("module:tracker") }
        f.insert("os:\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)")
        let oc = OptionalComponents.shared
        if UserDefaults.standard.bool(forKey: ComponentsChecklist.chosenKey) || ComponentCatalog.optional.contains(where: oc.isInstalled) { f.insert("done:addons") }
        return f
    }

    static var pending: [WhatsNew.Item] { WhatsNew.pending(items, lastSeen: lastSeen, current: current, facts: facts) }
}

struct WhatsNewView: View {
    var close: (_ seen: Bool) -> Void
    @State private var items: [WhatsNew.Item]
    @State private var open: String?
    @State private var doneSteps: Set<String> = []
    private let from: String

    /// `items` and `from` are given only by the offscreen smoke shots; the window takes what is pending for this person.
    init(items: [WhatsNew.Item]? = nil, from: String? = nil, close: @escaping (_ seen: Bool) -> Void) {
        _items = State(initialValue: items ?? WhatsNewStore.pending)
        self.from = from ?? WhatsNewStore.lastSeen ?? WhatsNew.baseline
        self.close = close
    }

    var body: some View {
        VStack(spacing: 12) {
            Text(L("wn.updated", ["v": WhatsNewStore.current])).font(PN.Font.label).foregroundStyle(PN.C.text3).padding(.top, 16)
            PacenoteSymbol(height: 44)
            Text(L("wn.title", ["v": WhatsNew.short(WhatsNewStore.current)])).font(.title.weight(.semibold)).foregroundStyle(PN.C.text)
            Text(items.contains { $0.setupStep != nil } ? L("wn.sub.setup", ["from": from]) : L("wn.sub", ["from": from]))
                .font(.body).foregroundStyle(PN.C.text2).multilineTextAlignment(.center).frame(maxWidth: 560)
            ScrollView {
                VStack(spacing: 10) { ForEach(items, id: \.id) { card($0) } }.frame(width: 620)
            }
            Text(L("wn.foot")).font(PN.Font.caption).foregroundStyle(PN.C.text3)
            HStack(spacing: 10) {
                Button(L("wn.later")) { close(false) }.buttonStyle(.pnSecondary)
                Button { close(true) } label: { Text(L("wn.done")).frame(minWidth: 200) }.buttonStyle(.pnPrimary).keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 24)
        .frame(width: 760, height: 680)
        .background(PN.C.bg)
    }

    func card(_ i: WhatsNew.Item) -> some View {
        let lang = L10n.lang
        let stepDone = i.setupStep.map { doneSteps.contains($0) } ?? false
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon(i)).font(.system(size: 16)).foregroundStyle(PN.C.accent).frame(width: 20).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(i.title(lang)).font(PN.Font.section).foregroundStyle(PN.C.text)
                        Text(WhatsNew.short(i.version)).font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.text2)
                            .padding(.horizontal, 6).background(PN.C.surface2, in: RoundedRectangle(cornerRadius: 6))
                    }
                    Text(i.body(lang)).font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if stepDone {
                    Text(L("wn.stepDone")).font(PN.Font.caption.weight(.semibold)).foregroundStyle(PN.C.turn)
                        .padding(.horizontal, 8).padding(.vertical, 2).background(PN.C.turn.opacity(0.13), in: RoundedRectangle(cornerRadius: 6))
                } else if i.setupStep != nil {
                    Button(open == i.id ? L("wn.hide") : L("wn.choose")) { open = open == i.id ? nil : i.id }.buttonStyle(.pnPrimary)
                } else if let t = i.tryIt, let f = FeatureRegistry.all.first(where: { $0.id == t }) {
                    Button(t == "components" ? L("wn.open") : L("feat.try")) { FeatureRegistry.tryIt(f) }.buttonStyle(.pnSecondary)
                }
            }
            if open == i.id, i.setupStep == "addons", !stepDone {
                Divider().padding(.leading, 32)
                ComponentsChecklist(provider: WhatsNewStore.facts.contains("provider:claude") ? "claude" : "chatgpt", compact: true) {
                    doneSteps.insert("addons"); open = nil
                }
                .padding(.leading, 32)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.m))
    }

    func icon(_ i: WhatsNew.Item) -> String {
        switch i.id {
        case "components": return "shippingbox"
        case "addons": return "checklist"
        case "settings_search": return "magnifyingglass"
        case "practice": return "play.circle"
        case "updates": return "arrow.down.circle"
        default: return "sparkles"
        }
    }
}

@MainActor
enum WhatsNewWindow {
    static var window: NSWindow?

    /// At launch: after an update, when something is new for this person and no call is live. Nothing pending:
    /// the version counts as seen at once.
    static func showIfNeeded(callIsLive: Bool) {
        // Smoke 15.11: people who closed the onboarding with "Set up later" before 0.16 have only "onboarded";
        // they count as set up too, or they would never see What's new.
        let d = UserDefaults.standard
        guard d.bool(forKey: "onboardingDone") || d.bool(forKey: "onboarded"), !callIsLive else { return }
        guard WhatsNewStore.lastSeen != WhatsNewStore.current else { return }
        if WhatsNew.shouldShow(onboardingDone: true, pending: WhatsNewStore.pending) { show() } else { WhatsNewStore.markSeen() }
    }

    static func show() {
        UsageLog.log("whatsnew_shown", ["from": WhatsNewStore.lastSeen ?? WhatsNew.baseline, "to": WhatsNewStore.current])
        let w = NSWindow(contentViewController: NSHostingController(rootView: Localized { WhatsNewView { seen in
            if seen { WhatsNewStore.markSeen() }
            UsageLog.log("whatsnew_closed", ["seen": seen])
            window?.close()
        } }))
        w.tabbingMode = .disallowed
        w.title = L("wn.window")
        w.styleMask.remove(.resizable)
        w.isReleasedWhenClosed = false
        window = w
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Settings > Help > What's new: every change, newest version first.
struct WhatsNewHistory: View {
    var body: some View {
        let lang = L10n.lang
        VStack(alignment: .leading, spacing: 10) {
            Text(L("wn.history")).font(PN.Font.title).foregroundStyle(PN.C.text)
            ForEach(WhatsNew.history(WhatsNewStore.items), id: \.version) { g in
                VStack(alignment: .leading, spacing: 6) {
                    Text("Pacenote " + g.version).font(PN.Font.section).foregroundStyle(PN.C.text)
                    ForEach(g.items, id: \.id) { i in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(i.title(lang)).font(PN.Font.body.weight(.medium)).foregroundStyle(PN.C.text)
                                Text(i.body(lang)).font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            if let t = i.tryIt, let f = FeatureRegistry.all.first(where: { $0.id == t }) {
                                Button(L("feat.try")) { FeatureRegistry.tryIt(f) }.buttonStyle(.pnTertiary)
                            }
                        }
                    }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.m))
            }
        }
        .settingsAnchor("help.whatsnew")
    }
}
