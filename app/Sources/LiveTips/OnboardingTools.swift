import AppKit
import LiveTipsCore
import SwiftUI

// INT S3 (Bohdan 19.11): an optional onboarding step "Connect your tools" (Google calendars, Notion, HubSpot) with Skip,
// and the INT5 offer of a local copy of Notion that follows "Connect with Notion" (here and in Settings).

/// "Keep a local copy of Notion?" after Connect: Turn on / Later / Not now (NotionLocalCopyOffer). Turn on runs the same
/// setup as Settings > Integrations > Notion > Local copy; without Control Tower the mirror runs in Pacenote mode.
struct NotionLocalCopyOfferCard: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var auth = NotionAuth.shared
    @AppStorage(NotionLocalCopyOffer.choiceKey) private var choice = ""
    @AppStorage(NotionLocalCopyOffer.laterKey) private var laterAt: Double = 0

    private var show: Bool {
        !auth.busy && !auth.offerChoice && !auth.needsReconnect &&
            NotionLocalCopyOffer.shouldShow(connected: auth.record != nil, mirrorMode: NotionMirrorService.mode(workRoot: model.config.workRoot),
                                            choice: choice, laterAt: laterAt > 0 ? Date(timeIntervalSince1970: laterAt) : nil)
    }

    var body: some View {
        if show {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("nlc.title")).font(.callout.weight(.medium))
                Text(L("nlc.body", ["folder": folder])).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                    .fixedSize(horizontal: false, vertical: true)
                if model.config.workRoot.isEmpty {
                    Text(L("set.workFirst") + ".").font(PN.Font.caption).foregroundStyle(PN.C.onMe)
                }
                HStack {
                    Button(L("nlc.on")) {
                        choice = "on"
                        UsageLog.log("notion_local_copy", ["choice": "turn_on"])
                        model.setUpMirror()
                    }.buttonStyle(.pnPrimary).disabled(model.config.workRoot.isEmpty)
                    Button(L("nlc.later")) {
                        choice = "later"; laterAt = Date().timeIntervalSince1970
                        UsageLog.log("notion_local_copy", ["choice": "later"])
                    }.buttonStyle(.pnSecondary)
                    Button(L("nlc.no")) {
                        choice = "no"
                        UsageLog.log("notion_local_copy", ["choice": "not_now"])
                    }.buttonStyle(.pnTertiary)
                }
            }
            .padding(.vertical, 4)
        } else if choice == "on" && !model.mirrorNote.isEmpty {
            Text(model.mirrorNote).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var folder: String {
        let w = model.config.workRoot.isEmpty ? "~/work" : (model.config.workRoot as NSString).abbreviatingWithTildeInPath
        return (w as NSString).appendingPathComponent("_notion")
    }
}

/// The optional step before Ready: Google calendars, Notion and HubSpot in one place. Nothing here is required; Skip
/// (the main button while nothing is connected) moves on, and every row lives in Settings > Integrations later.
struct OnboardingToolsStep: View {
    @ObservedObject var settings: SettingsModel
    @ObservedObject var g = GoogleService.shared
    @ObservedObject var auth = NotionAuth.shared
    @ObservedObject var account = PacenoteAccount.shared
    @State private var hubspotOpen = false

    var body: some View {
        VStack(spacing: 10) {
            row("calendar", "Google", L("onb.tools.google.sub"), done: g.connected) {
                switch g.signIn {
                case .waiting:
                    HStack(spacing: 6) {
                        PNSpinner(size: 14)
                        Button(L("common.cancel")) { g.cancelSignIn() }.buttonStyle(.pnTertiary)
                    }
                default:
                    Button(g.connected ? L("google.addAnother") : L("onb.tools.connect")) { g.addAccount() }
                        .buttonStyle(.pnSecondary).disabled(!g.configured)
                }
            } extra: {
                if case .failed(let e) = g.signIn { note(e, danger: true) }
                if !g.configured { note(L("google.err.noClient"), danger: false) }
            }
            row("doc.text", "Notion", L("onb.tools.notion.sub"), done: auth.record != nil || settings.notionConnected) {
                if auth.record == nil {
                    HStack(spacing: 6) {
                        if auth.busy { PNSpinner(size: 14) }
                        if auth.state == .waiting { Button(L("common.cancel")) { auth.cancel() }.buttonStyle(.pnTertiary) }
                        if account.signedIn {
                            Button(L("onb.tools.connect")) { auth.connect() }.buttonStyle(.pnSecondary).disabled(auth.busy)
                        } else {
                            Button(L("onb.tools.signIn")) { SignInWindow.show() }.buttonStyle(.pnSecondary)
                        }
                    }
                } else if auth.busy {
                    PNSpinner(size: 14)
                }
            } extra: {
                if auth.record == nil && !account.signedIn { note(L("onb.tools.notion.signIn"), danger: false) }
                if auth.state == .waiting { note(L("ntauth.waiting"), danger: false) }
                if case .failed(let e) = auth.state { note(e, danger: true) }
                else if !auth.note.isEmpty { note(auth.note, danger: false) }
                if auth.offerChoice {
                    // shared databases are visible (Control Tower): the choice is made in Settings, not here
                    HStack {
                        Button(L("ntauth.choice.create")) { Task { await auth.setUp() } }.buttonStyle(.pnPrimary).disabled(auth.busy)
                        Button(L("ntauth.choice.pick")) {
                            auth.offerChoice = false
                            UserDefaults.standard.set("1", forKey: SettingsSearch.advancedKey("notion"))
                            SettingsWindow.show(tab: "notion")
                        }.buttonStyle(.pnSecondary)
                    }
                }
                NotionLocalCopyOfferCard(model: settings)
            }
            row("briefcase", "HubSpot", L("onb.tools.hubspot.sub"), done: settings.isSet(.hubspotKey)) {
                if !settings.isSet(.hubspotKey) {
                    Button(hubspotOpen ? L("common.cancel") : L("onb.tools.addKey")) { hubspotOpen.toggle() }.buttonStyle(.pnSecondary)
                }
            } extra: {
                if hubspotOpen && !settings.isSet(.hubspotKey) {
                    KeyRow(title: L("int.hubspot.key"), hint: L("int.hubspot.keyHint"), key: .hubspotKey, model: settings)
                    Button(L("onb.tools.hubspot.how")) { SettingsWindow.show(tab: "hubspot") }.buttonStyle(.pnTertiary)
                }
            }
            Text(L("onb.tools.foot")).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    static var anyConnected: Bool {
        GoogleService.shared.connected || NotionAuth.connected || SettingsWindow.model.isSet(.hubspotKey)
    }

    private func note(_ t: String, danger: Bool) -> some View {
        Text(t).font(PN.Font.caption).foregroundStyle(danger ? PN.C.danger : PN.C.text3).fixedSize(horizontal: false, vertical: true)
    }

    private func row<B: View, E: View>(_ symbol: String, _ name: String, _ sub: String, done: Bool,
                                       @ViewBuilder button: () -> B, @ViewBuilder extra: () -> E) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: done ? "checkmark.circle.fill" : symbol).font(PN.sys(16))
                    .foregroundStyle(done ? PN.C.turn : PN.C.text2).frame(width: 22).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(PN.Font.body).foregroundStyle(PN.C.text)
                    Text(done ? L("keys.connected") : sub).font(PN.Font.caption).foregroundStyle(PN.C.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                button()
            }
            extra()
        }
        .padding(12)
        .background(PN.C.surface, in: RoundedRectangle(cornerRadius: PN.Radius.m))
        .accessibilityElement(children: .contain)
    }
}
