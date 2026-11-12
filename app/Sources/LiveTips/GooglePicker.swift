import AppKit
import SwiftUI
import WebKit
import LiveTipsCore

// 0.10.0 (Meeting Sheet, Google Picker): "Confirm in Google" for a Drive file link (PDF, Word and other files that
// the read-only Docs, Sheets and Slides scopes cannot open). No restricted scope (drive.readonly needs CASA): a small
// window hosts Google Picker (Resources/google/picker.html, which loads https://apis.google.com/js/api.js) with the
// account's drive.file token, opened on that one file (DocsView.setFileIds). When the PM confirms it, drive.file gives
// Pacenote access to that file only; the app downloads it (files/<id>?alt=media, or the export of a Google-native
// file) to <project>/live/google/google-file-<id16>.<ext> and the source is checked again (access ok).
// Without the Picker values in the build (PACENOTE_GOOGLE_PICKER_API_KEY, PACENOTE_GOOGLE_APP_ID) the file opens in
// the browser with one line saying so and the source stays "No access". rules/google.yaml > picker.

/// The Picker values of this build: Resources/google_oauth.json (bundle.sh) or the same file in the support folder.
enum GooglePickerConfig {
    /// The page's origin for the Picker (setOrigin): the product's own site; the page itself is the bundled file.
    static let origin = "https://pacenote.bodco.pm"

    static func load() -> GooglePickerKeys? {
        let candidates = [Bundle.main.url(forResource: "google_oauth", withExtension: "json"),
                          AppPaths.support.appendingPathComponent("google_oauth.json")]
        for u in candidates.compactMap({ $0 }) { if let d = try? Data(contentsOf: u), let k = GooglePickerKeys.parse(d) { return k } }
        return nil
    }

    /// The bundled page; a development build (swift run) reads it from the source tree.
    static func page() -> String? {
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/google/picker.html")
        let candidates = [Bundle.main.url(forResource: "picker", withExtension: "html", subdirectory: "google"), dev]
        for u in candidates.compactMap({ $0 }) { if let s = try? String(contentsOf: u, encoding: .utf8) { return s } }
        return nil
    }
}

/// What came of one "Confirm in Google".
enum GooglePickerOutcome {
    case copied(path: String, name: String)   // the file is on this Mac: check the sources again
    case note(String)                         // one honest line for the Sources step (nothing changed)
    case cancelled
}

/// The page's messages (a plain NSObject like the tips window's handler; the work hops to the main actor).
private final class PickerMessages: NSObject, WKScriptMessageHandler {
    var on: ((Any) -> Void)?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        DispatchQueue.main.async { self.on?(body) }
    }
}

@MainActor
final class GooglePicker: NSObject, ObservableObject, NSWindowDelegate {
    private static var open: [String: GooglePicker] = [:]      // one window per Drive file

    let fileID: String
    let url: String
    let folder: String
    let keys: GooglePickerKeys
    @Published var account: String
    @Published var accounts: [String]
    @Published var status = ""
    @Published var busy = false
    let web: WKWebView
    private let messages = PickerMessages()
    private var window: NSWindow?
    private var done: (GooglePickerOutcome) -> Void
    private var finished = false

    /// <project>/live/google, the folder of the other Google copies; the support folder without a project.
    static func folder(root: String?) -> String {
        if let r = root, !r.isEmpty { return ((r as NSString).appendingPathComponent("live") as NSString).appendingPathComponent("google") }
        return AppPaths.support.appendingPathComponent("google").path
    }

    /// The copies already confirmed for these links, for the sidecar's google.copies (by Drive file id).
    static func copies(for links: [String], root: String?) -> [String: String] {
        let dir = folder(root: root)
        var out: [String: String] = [:]
        for u in links { if let id = GooglePickerPlan.fileID(u), let p = GoogleDriveCopy.existing(in: dir, id: id) { out[id] = p } }
        return out
    }

    /// The "Confirm in Google" button of a source. `done` gets the outcome on the main actor.
    static func confirm(url: String, root: String?, done: @escaping (GooglePickerOutcome) -> Void) {
        let g = GoogleService.shared
        let keys = GooglePickerConfig.load()
        switch GooglePickerPlan.decide(url: url, keys: keys, accounts: g.accounts) {
        case .notDrive:
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
            done(.cancelled)
        case .browser:
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
            done(.note(L("sheet.google.notSetUp")))
        case .connect:
            SettingsWindow.show(tab: "google")
            done(.note(L("sheet.google.connect")))
        case .consent(let a):
            // incremental consent: the same sign-in as Settings asks Google again (include_granted_scopes), drive.file included
            g.addAccount(hint: a)
            done(.note(L("sheet.google.consent")))
        case .picker(let a):
            guard let id = GooglePickerPlan.fileID(url), let k = keys else { done(.cancelled); return }
            if let w = open[id] { w.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
            let list = g.accounts.filter { $0.has(GoogleScopes.export) }.map(\.email)
            let p = GooglePicker(fileID: id, url: url, folder: folder(root: root), keys: k, account: a, accounts: list, done: done)
            open[id] = p
            p.show()
            p.load()
        }
    }

    private init(fileID: String, url: String, folder: String, keys: GooglePickerKeys, account: String, accounts: [String],
                 done: @escaping (GooglePickerOutcome) -> Void) {
        self.fileID = fileID; self.url = url; self.folder = folder; self.keys = keys
        self.account = account; self.accounts = accounts; self.done = done
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()      // nothing of Google's page stays after the window closes
        cfg.userContentController.add(messages, name: "pacenotePicker")
        web = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        messages.on = { [weak self] body in MainActor.assumeIsolated { self?.handle(body) } }
    }

    private func show() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = L("sheet.google.picker.title")
        w.isReleasedWhenClosed = false
        w.tabbingMode = .disallowed
        w.minSize = NSSize(width: 560, height: 420)
        w.contentView = NSHostingView(rootView: GooglePickerView(p: self))
        w.delegate = self
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// (Re)loads the page with the chosen account's token. The token goes into the page only, never into a file.
    func load() {
        busy = false
        status = ""
        let acc = account
        Task { @MainActor in
            do {
                let token = try await GoogleService.shared.accessToken(acc)
                guard let html = GooglePickerConfig.page() else { status = L("sheet.google.picker.failed"); return }
                var cfg = GooglePickerPlan.config(fileID: fileID, token: token, keys: keys, origin: GooglePickerConfig.origin, locale: L10n.lang)
                cfg["opening"] = L("sheet.google.picker.opening")
                cfg["failed"] = L("sheet.google.picker.failed")
                guard let d = try? JSONSerialization.data(withJSONObject: cfg), let js = String(data: d, encoding: .utf8) else { return }
                let uc = web.configuration.userContentController
                uc.removeAllUserScripts()
                uc.addUserScript(WKUserScript(source: "window.PN_PICKER = " + js + ";", injectionTime: .atDocumentStart, forMainFrameOnly: true))
                web.loadHTMLString(html, baseURL: URL(string: GooglePickerConfig.origin + "/")!)
            } catch {
                status = L("sheet.google.err", ["e": error.localizedDescription])
            }
        }
    }

    private func handle(_ body: Any) {
        switch GooglePickerPlan.message(body) {
        case .picked(let id, let name, let mime):
            guard id == fileID else { status = L("sheet.google.wrongFile"); load(); return }
            busy = true
            status = L("sheet.google.downloading")
            let acc = account
            Task { @MainActor in
                do {
                    let path = try await GoogleService.shared.downloadDriveFile(id: id, account: acc, folder: folder, mimeType: mime, name: name)
                    finish(.copied(path: path, name: name))
                } catch {
                    busy = false
                    status = L("sheet.google.err", ["e": error.localizedDescription])
                }
            }
        case .cancelled: finish(.cancelled)
        case .failed(let e): status = L("sheet.google.err", ["e": e])
        default: break      // loaded, or a message this version does not know
        }
    }

    private func finish(_ o: GooglePickerOutcome) {
        guard !finished else { return }
        finished = true
        done(o)
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        if !finished { finished = true; done(.cancelled) }
        web.configuration.userContentController.removeScriptMessageHandler(forName: "pacenotePicker")
        web.configuration.userContentController.removeAllUserScripts()
        messages.on = nil
        Self.open[fileID] = nil
    }
}

private struct GooglePickerView: View {
    @ObservedObject var p: GooglePicker

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Text(L("sheet.google.picker.hint")).font(PN.Font.caption).foregroundStyle(PN.C.text2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if p.accounts.count > 1 {
                    Picker(L("sheet.google.picker.account"), selection: Binding(get: { p.account }, set: { p.account = $0; p.load() })) {
                        ForEach(p.accounts, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(maxWidth: 300)
                }
            }
            .padding(10)
            if !p.status.isEmpty {
                HStack(spacing: 8) {
                    if p.busy { ProgressView().controlSize(.small) }
                    Text(p.status).font(PN.Font.caption).foregroundStyle(p.busy ? PN.C.text2 : PN.C.pending).lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.bottom, 8)
            }
            PickerWebView(web: p.web)
        }
    }
}

private struct PickerWebView: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
