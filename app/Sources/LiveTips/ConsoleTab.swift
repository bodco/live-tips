// 0.17.0 (server 0.8.0, plan 2026-11-16 item 4): the Console tab. The web console (pacenote-admin.bodco.pm) inside a
// WKWebView, no separate UI in the app. Shown only to someone who runs something in an organization (owner, admin,
// C-level, team lead; contract 6) or to Pacenote staff.
//
// Sign-in without Google: the app asks POST /v1/console/handoff with its own access token for a one-time link (60 s,
// one use, bound to this person and this Mac) and opens it; the console sets its usual session cookie. The web view
// has a non-persistent data store, so the console session lives while the app runs. Signing out of the app, or this
// Mac being revoked, ends the console session too (the server checks the device on every page). Links that leave the
// console open in the browser. The Platform zone (staff) asked for Google in the browser until 0.19.0 (below).
// 0.17.2: "Manage organization" (Settings > Account) and "Open the console" (the organization wizard) open this tab on
// the organization's page (ConsoleLink); the browser only when the app does not show the tab.
// 0.19.0 (server 0.11.0, Bohdan 17.11): the tab for everyone signed in (someone who runs nothing gets /me). Staff get
// two tabs, Organization and Platform. Platform opens from the app only on this (not revoked) Mac with Google at most
// 12 hours old: older, the app asks Google again itself (the same sign-in as the first one, the account preselected),
// over the Console, then opens Platform. No error page and no Platform in the browser; Google never runs in the web
// view (Google refuses OAuth in an embedded WKWebView, disallowed_useragent).
import AppKit
import Combine
import LiveTipsCore
import SwiftUI
import WebKit

@MainActor
final class ConsoleSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    static let shared = ConsoleSession()

    enum Phase: Equatable { case idle, opening, ready, failed(String) }
    @Published private(set) var phase: Phase = .idle
    /// 0.19.0: which zone the page is in (staff see the two tabs), and a quiet line when Platform did not open.
    enum Zone: Equatable { case organization, platform }
    @Published private(set) var zone: Zone = .organization
    @Published private(set) var platformNote: String?
    @Published private(set) var platformBusy = false
    @Published private(set) var web: WKWebView
    private var signedOut: AnyCancellable?
    private var lastHandoff = Date.distantPast
    private var wanted: String?       // 0.17.2: the console page asked for (ConsoleLink), opened next

    private override init() {
        web = Self.makeWeb()
        super.init()
        web.navigationDelegate = self
        web.uiDelegate = self
        // Signing out of the app (or deleting the account) drops the console session at once.
        signedOut = PacenoteAccount.shared.$session.removeDuplicates { ($0 == nil) == ($1 == nil) }.dropFirst()
            .sink { [weak self] s in if s == nil { self?.reset() } }
    }

    private static func makeWeb() -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()     // nothing of the console is kept on disk
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.customUserAgent = "Pacenote/\(PacenoteAccount.appVersion) (macOS) Console"
        return w
    }

    /// A fresh web view and store: the console's cookie is gone.
    func reset() {
        web.stopLoading()
        web = Self.makeWeb()
        web.navigationDelegate = self
        web.uiDelegate = self
        wanted = nil
        phase = .idle
        zone = .organization
        platformNote = nil
    }

    /// 0.17.2: the tab on a console page (a path such as /org/<id>). With the console open, the page loads in it; else
    /// the one-time link goes straight there; while a link is opening, the page loads once it has finished.
    func show(path: String) {
        AnalyticsTracker.shared.action("open_console", scr: AnalyticsTracker.shared.lastScreen)   // 0.19.0 (S4)
        AnalyticsTracker.shared.begin("console_open")
        wanted = path
        HomeNav.shared.open(.console)
        if phase == .ready { loadWanted() } else if phase != .opening { Task { await open(force: true) } }
    }

    private func loadWanted() {
        guard let p = wanted else { return }
        wanted = nil
        if let u = PacenoteServer.consolePageURL(p) { web.load(URLRequest(url: u)) }
    }

    /// Opens the console with a one-time link. `force` asks for a new link even when a page is open.
    func open(force: Bool = false) async {
        if phase == .opening || (phase == .ready && !force) { return }
        guard PacenoteAccount.shared.signedIn, let me = PacenoteAccount.shared.me else {
            phase = .failed(L("console.err.signIn")); return
        }
        phase = .opening
        lastHandoff = Date()
        do {
            let (d, code) = try await PacenoteAccount.shared.api("POST", "/v1/console/handoff",
                                                                 body: PacenoteServer.consoleHandoffBody(next: takeWanted() ?? me.consolePath))
            guard code == 200, let url = PacenoteServer.consoleHandoffURL(d) else {
                phase = .failed(code == 404 ? L("console.err.old") : L("console.err.server", ["code": String(code)])); return
            }
            web.load(URLRequest(url: url))
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// 0.19.0 (Bohdan 17.11): the Platform zone, for staff. A one-time link that asks for Platform; when this Mac's
    /// Google is older than 12 hours, Google again in the app, then the link again. On cancel the Organization page
    /// stays and a line says why Platform did not open.
    func openPlatform(next: String = "/platform") async {
        guard PacenoteAccount.shared.me?.staff == true, !platformBusy else { return }
        platformBusy = true; platformNote = nil
        defer { platformBusy = false }
        let path = PacenoteServer.isPlatformPath(next) ? next : "/platform"
        for attempt in 0..<2 {
            do {
                let (d, code) = try await PacenoteAccount.shared.api("POST", "/v1/console/handoff",
                                                                     body: PacenoteServer.consoleHandoffBody(next: path, platform: true))
                if code == 200, let url = PacenoteServer.consoleHandoffURL(d) {
                    UsageLog.log("console_platform", ["google": attempt > 0])
                    lastHandoff = Date()
                    web.load(URLRequest(url: url))
                    phase = .ready; zone = .platform
                    return
                }
                if attempt == 0, PacenoteServer.needsGoogleAgain(d, status: code) {
                    if let why = await PacenoteAccount.shared.confirmGoogle() { platformNote = why; zone = currentZone(); return }
                    continue
                }
                platformNote = code == 403 ? L("console.platform.notStaff") : L("console.err.server", ["code": String(code)])
                zone = currentZone(); return
            } catch {
                platformNote = error.localizedDescription; zone = currentZone(); return
            }
        }
    }

    /// The Organization tab: the person's organization page (or their own page).
    func openOrganization() {
        platformNote = nil
        zone = .organization
        if let me = PacenoteAccount.shared.me, let u = PacenoteServer.consolePageURL(me.consolePath), phase == .ready {
            web.load(URLRequest(url: u))
        } else {
            Task { await open(force: true) }
        }
    }

    private func currentZone() -> Zone {
        PacenoteServer.isPlatformPath(web.url?.path ?? "") && PacenoteServer.isConsoleURL(web.url) ? .platform : .organization
    }

    private func takeWanted() -> String? { defer { wanted = nil }; return wanted.flatMap { PacenoteServer.consolePageURL($0) != nil ? $0 : nil } }

    /// The console in the browser (Google sign-in there): the page the tab shows, or the console's start.
    func openInBrowser() {
        let u = PacenoteServer.isConsoleURL(web.url) && web.url?.path != "/auth/app" ? web.url! : URL(string: "https://" + PacenoteServer.consoleHost + "/")!
        NSWorkspace.shared.open(u)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.cancel); return }
        if url.scheme == "about" { decisionHandler(.allow); return }
        if PacenoteServer.isConsoleURL(url) {
            // The session ended (8 hours, or Sign out and then Sign in): a new one-time link, not Google in a web view.
            if url.path == "/login", action.targetFrame?.isMainFrame != false {
                decisionHandler(.cancel)
                if let next = PacenoteServer.platformNext(url) {
                    // 0.19.0: Platform for staff right here (Google again in the app when older than 12 hours); anyone
                    // else stays where they are
                    if PacenoteAccount.shared.me?.staff == true { Task { await self.openPlatform(next: next) } }
                } else if Date().timeIntervalSince(lastHandoff) > 5 {
                    Task { await self.open(force: true) }
                }
                return
            }
            decisionHandler(.allow); return
        }
        decisionHandler(.cancel)
        if url.host?.lowercased() == "accounts.google.com" {
            // Google never runs in the web view (disallowed_useragent): staff get Platform the app's way (0.19.0)
            if PacenoteAccount.shared.me?.staff == true { Task { await self.openPlatform() } }
        } else if ["https", "http", "mailto"].contains(url.scheme ?? "") {
            NSWorkspace.shared.open(url)
        }
    }

    // 0.17.2: a page asked for while the one-time link was opening loads after the console's own page
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if PacenoteServer.isConsoleURL(webView.url), webView.url?.path != "/auth/app" { zone = currentZone(); AnalyticsTracker.shared.end("console_open") }
        if wanted != nil, phase == .ready, PacenoteServer.isConsoleURL(webView.url), webView.url?.path != "/auth/app" { loadWanted() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled {
            phase = .failed(error.localizedDescription)
            AnalyticsTracker.shared.end("console_open", ok: false)
            AnalyticsTracker.shared.error("server", Analytics.errorCode(error))      // 0.19.0 (S4): the area and code, never the text
        }
    }

    // target=_blank and window.open: the browser
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = action.request.url, ["https", "http", "mailto"].contains(u.scheme ?? "") { NSWorkspace.shared.open(u) }
        return nil
    }
}

/// 0.17.2: "Manage organization" and "Open the console": the Console tab on the organization's page, or the browser when
/// the app does not show the tab (signed out, or the person runs nothing there).
@MainActor
enum ConsoleLink {
    static func openOrg(_ orgID: String) {
        let acct = PacenoteAccount.shared
        if PacenoteServer.consoleOpensInApp(signedIn: acct.signedIn, me: acct.me) {
            ConsoleSession.shared.show(path: PacenoteServer.orgConsolePath(orgID: orgID))
        } else {
            NSWorkspace.shared.open(PacenoteServer.adminURL(orgID: orgID))
        }
    }

    /// 0.19.0: any console page (such as /me or /plans) in the tab, or the browser when the app does not show the tab.
    static func open(path: String) {
        let acct = PacenoteAccount.shared
        if PacenoteServer.consoleOpensInApp(signedIn: acct.signedIn, me: acct.me) {
            ConsoleSession.shared.show(path: path)
        } else if let u = PacenoteServer.consolePageURL(path) {
            NSWorkspace.shared.open(u)
        }
    }

    /// 0.18.0 (B3): the organization's Plan page in the console, where owner and admin request another plan.
    static func openPlan(_ orgID: String) {
        let acct = PacenoteAccount.shared
        let path = PacenoteServer.orgConsolePath(orgID: orgID) + "/plan"
        if PacenoteServer.consoleOpensInApp(signedIn: acct.signedIn, me: acct.me) {
            ConsoleSession.shared.show(path: path)
        } else if let u = PacenoteServer.consolePageURL(path) {
            NSWorkspace.shared.open(u)
        }
    }
}

/// The web view itself; the same WKWebView stays alive between visits to the tab.
private struct ConsoleWeb: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        attach(web, to: host)
        return host
    }
    func updateNSView(_ host: NSView, context: Context) {
        if web.superview !== host { host.subviews.forEach { $0.removeFromSuperview() }; attach(web, to: host) }
    }
    private func attach(_ w: WKWebView, to host: NSView) {
        w.removeFromSuperview()
        w.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(w)
        NSLayoutConstraint.activate([w.leadingAnchor.constraint(equalTo: host.leadingAnchor), w.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                                     w.topAnchor.constraint(equalTo: host.topAnchor), w.bottomAnchor.constraint(equalTo: host.bottomAnchor)])
    }
}

struct ConsoleTabView: View {
    @ObservedObject var session = ConsoleSession.shared
    @ObservedObject var acct = PacenoteAccount.shared

    var body: some View {
        Group {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(L("console.tab")).font(PN.sys(15, .semibold)).foregroundStyle(PN.C.text)
                if acct.me?.staff == true {
                    // 0.19.0: staff, two tabs (Platform asks Google again in the app after 12 hours)
                    PNSegmented(selection: Binding(get: { session.zone }, set: { z in
                        if z == .platform { Task { await session.openPlatform() } } else { session.openOrganization() }
                    }), options: [
                        (ConsoleSession.Zone.organization, L("console.zone.org")),
                        (ConsoleSession.Zone.platform, L("console.zone.platform"))
                    ]).labelsHidden().fixedSize().disabled(session.platformBusy)
                    .accessibilityLabel(L("console.zone"))
                    if session.platformBusy { PNSpinner(size: 16) }
                } else {
                    Text(L(acct.me.map(PacenoteServer.consoleNoteKey) ?? "console.note")).font(PN.Font.caption).foregroundStyle(PN.C.text2).lineLimit(1)
                }
                Spacer()
                Button { session.web.goBack() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.pnTertiary).help(L("console.back")).accessibilityLabel(L("console.back"))
                Button { Task { await session.open(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.pnTertiary).help(L("console.reload")).accessibilityLabel(L("console.reload"))
                Button(L("console.browser")) { session.openInBrowser() }.buttonStyle(.pnTertiary).help(L("console.browser.help"))
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
            if let n = session.platformNote {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield").foregroundStyle(PN.C.pending).accessibilityHidden(true)
                    Text(n).font(PN.Font.caption).foregroundStyle(PN.C.text2).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(L("console.platform.retry")) { Task { await session.openPlatform() } }.buttonStyle(.pnTertiary)
                }
                .padding(.horizontal, 16).padding(.bottom, 6)
            }
            Divider()
            ZStack {
                ConsoleWeb(web: session.web)
                switch session.phase {
                case .idle, .opening:
                    VStack(spacing: 12) { PNSpinner(size: 40); Text(L("console.opening")).foregroundStyle(PN.C.text2) }.padding(24).background(PN.C.bg)
                case .failed(let why):
                    VStack(spacing: 10) {
                        Text(L("console.failed")).pnSection()
                        Text(why).font(PN.Font.body).foregroundStyle(PN.C.text2).multilineTextAlignment(.center).frame(maxWidth: 420)
                        Button(L("console.retry")) { Task { await session.open(force: true) } }.buttonStyle(.pnSecondary)
                    }
                    .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(PN.C.bg)
                case .ready:
                    EmptyView()
                }
                if acct.confirmingGoogle {
                    // over the Console while Google is asked again (the same sign-in as the first one)
                    VStack(spacing: 10) {
                        PNSpinner(size: 40)
                        Text(L("console.platform.google")).pnSection().foregroundStyle(PN.C.text)
                        Text(L("console.platform.google.sub")).font(PN.Font.body).foregroundStyle(PN.C.text2)
                            .multilineTextAlignment(.center).frame(maxWidth: 420)
                        Button(L("common.cancel")) { acct.cancelConfirmGoogle() }.buttonStyle(.pnSecondary)
                    }
                    .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(PN.C.bg.opacity(0.96))
                }
            }
        }
        .task { await session.open() }
    }
        .trackScreen("console_tab")
    }
}
