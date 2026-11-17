// 0.17.0 (server 0.8.0, plan 2026-11-16 item 4): the Console tab. The web console (pacenote-admin.bodco.pm) inside a
// WKWebView, no separate UI in the app. Shown only to someone who runs something in an organization (owner, admin,
// C-level, team lead; contract 6) or to Pacenote staff.
//
// Sign-in without Google: the app asks POST /v1/console/handoff with its own access token for a one-time link (60 s,
// one use, bound to this person and this Mac) and opens it; the console sets its usual session cookie. The web view
// has a non-persistent data store, so the console session lives while the app runs. Signing out of the app, or this
// Mac being revoked, ends the console session too (the server checks the device on every page). Links that leave the
// console open in the browser. The Platform zone (staff) still asks for Google there, never in the app.
// 0.17.2: "Manage organization" (Settings > Account) and "Open the console" (the organization wizard) open this tab on
// the organization's page (ConsoleLink); the browser only when the app does not show the tab.
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
    }

    /// 0.17.2: the tab on a console page (a path such as /org/<id>). With the console open, the page loads in it; else
    /// the one-time link goes straight there; while a link is opening, the page loads once it has finished.
    func show(path: String) {
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
                if PacenoteServer.consoleLoginWantsPlatform(url) {
                    // 0.17.1: the Platform zone asks for Google, in the browser (a session from the app never opens it)
                    NSWorkspace.shared.open(URL(string: "https://" + PacenoteServer.consoleHost + "/platform")!)
                } else if Date().timeIntervalSince(lastHandoff) > 5 {
                    Task { await self.open(force: true) }
                }
                return
            }
            decisionHandler(.allow); return
        }
        decisionHandler(.cancel)
        if url.host?.lowercased() == "accounts.google.com" {
            // The Platform zone asks for Google: that happens in the browser, on the console's own page
            NSWorkspace.shared.open(URL(string: "https://" + PacenoteServer.consoleHost + "/platform")!)
        } else if ["https", "http", "mailto"].contains(url.scheme ?? "") {
            NSWorkspace.shared.open(url)
        }
    }

    // 0.17.2: a page asked for while the one-time link was opening loads after the console's own page
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if wanted != nil, phase == .ready, PacenoteServer.isConsoleURL(webView.url), webView.url?.path != "/auth/app" { loadWanted() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { phase = .failed(error.localizedDescription) }
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
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(L("console.tab")).font(.system(size: 15, weight: .semibold)).foregroundStyle(PN.C.text)
                Text(L("console.note")).font(PN.Font.caption).foregroundStyle(PN.C.text2).lineLimit(1)
                Spacer()
                Button { session.web.goBack() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.pnTertiary).help(L("console.back")).accessibilityLabel(L("console.back"))
                Button { Task { await session.open(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.pnTertiary).help(L("console.reload")).accessibilityLabel(L("console.reload"))
                Button(L("console.browser")) { session.openInBrowser() }.buttonStyle(.pnTertiary).help(L("console.browser.help"))
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
            Divider()
            ZStack {
                ConsoleWeb(web: session.web)
                switch session.phase {
                case .idle, .opening:
                    ProgressView(L("console.opening")).padding(24).background(PN.C.bg)
                case .failed(let why):
                    VStack(spacing: 10) {
                        Text(L("console.failed")).font(PN.Font.section)
                        Text(why).font(PN.Font.body).foregroundStyle(PN.C.text2).multilineTextAlignment(.center).frame(maxWidth: 420)
                        Button(L("console.retry")) { Task { await session.open(force: true) } }.buttonStyle(.pnSecondary)
                    }
                    .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(PN.C.bg)
                case .ready:
                    EmptyView()
                }
            }
        }
        .task { await session.open() }
    }
}
