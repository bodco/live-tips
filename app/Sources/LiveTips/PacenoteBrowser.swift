// 0.10.0 (Meeting Sheet, phase 6): the Pacenote browser. A separate window with its own WKWebView and a
// non-persistent WKWebsiteDataStore: the session lives only in this window and ends when it closes; Pacenote never
// signs in for the user and keeps no password. "Add this page to sources" captures the page the user is on, one page
// at a time, by a plan shown first: scroll to the end (lazy loading), open "see more" / "show all", and for a LinkedIn
// profile the detail pages the user ticked (experience, education, skills, certifications, languages), with a
// 3-6 s pause between pages. The capture (URL, title, time, visible text, cleaned main HTML, contacts removed) is
// saved to <project>/live/sources/<slug>-<yyyyMMdd-HHmmss>.html + .txt and handed back to the caller.
//
// API for the Sources screen:
//   PacenoteBrowser.open(url: URL, liveFolder: URL?, onCapture: (CapturedPage) -> Void)
// liveFolder is the call's <project>/live folder (nil: Application Support/LiveTips/browser). The sidecar turns the
// capture into a source: `webfetch` with {"captured": [page.sidecarItem]} (LinkedIn pages are parsed there).
import AppKit
import LiveTipsCore
import SwiftUI
import WebKit

@MainActor
final class PacenoteBrowser: NSObject, NSWindowDelegate {
    private static var current: PacenoteBrowser?

    /// Opens the window on `url` (or brings it to the front and goes to `url`). Static, on the main actor.
    static func open(url: URL, liveFolder: URL? = nil, onCapture: @escaping (CapturedPage) -> Void) {
        if let b = current {
            b.model.onCapture = onCapture
            if let l = liveFolder { b.model.liveFolder = l }
            b.model.go(url)
            b.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let b = PacenoteBrowser(liveFolder: liveFolder, onCapture: onCapture)
        current = b
        b.model.go(url)
        b.window.center()
        b.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static var isOpen: Bool { current != nil }

    let model: BrowserModel
    let window: NSWindow

    private init(liveFolder: URL?, onCapture: @escaping (CapturedPage) -> Void) {
        let m = BrowserModel(liveFolder: liveFolder, onCapture: onCapture)
        model = m
        window = NSWindow(contentViewController: NSHostingController(rootView: Localized { PacenoteBrowserView(model: m) }))
        super.init()
        window.title = L("sheet.browser.window")
        window.tabbingMode = .disallowed
        window.styleMask.insert(.resizable)
        window.setContentSize(NSSize(width: 1120, height: 800))
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        _ = window.setFrameAutosaveName("PacenoteBrowser")
        window.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        // The session (cookies, storage) lives in a non-persistent store owned by this window: closing drops it.
        model.close()
        Self.current = nil
    }
}

@MainActor
final class BrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    enum Phase: Equatable {
        case browsing
        case confirming(CapturePlan)
        case working(String)
        case pausing(Int, Int, Int)          // seconds left, next page, pages
        case saved(String)
        case failed(String)
    }

    @Published var address = ""
    @Published var title = ""
    @Published var canBack = false
    @Published var canForward = false
    @Published var loading = false
    @Published var phase: Phase = .browsing
    @Published var sections: Set<String> = Set(LinkedInSection.all)

    let web: WKWebView
    var liveFolder: URL?
    var onCapture: (CapturedPage) -> Void
    private var observers: [NSKeyValueObservation] = []
    private var task: Task<Void, Never>?

    init(liveFolder: URL?, onCapture: @escaping (CapturedPage) -> Void) {
        self.liveFolder = liveFolder
        self.onCapture = onCapture
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()          // this window's session only, gone when it closes
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        web = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        observers = [
            web.observe(\.url, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.syncFromWeb() } },
            web.observe(\.title, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.syncFromWeb() } },
            web.observe(\.isLoading, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.syncFromWeb() } },
            web.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.syncFromWeb() } },
            web.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in MainActor.assumeIsolated { self?.syncFromWeb() } },
        ]
    }

    private func syncFromWeb() {
        if let u = web.url, !isBusy { address = u.absoluteString }
        title = web.title ?? ""
        loading = web.isLoading
        canBack = web.canGoBack
        canForward = web.canGoForward
    }

    var isConfirming: Bool {
        if case .confirming = phase { return true }
        return false
    }

    var isBusy: Bool {
        switch phase {
        case .working, .pausing: return true
        default: return false
        }
    }

    func go(_ url: URL) {
        address = url.absoluteString
        web.load(URLRequest(url: url))
    }

    func submitAddress() {
        guard let u = BrowserURL.fromInput(address) else { NSSound.beep(); return }
        go(u)
    }

    func back() { web.goBack() }
    func forward() { web.goForward() }
    func reloadOrStop() { if web.isLoading { web.stopLoading() } else { web.reload() } }

    func close() {
        task?.cancel()
        task = nil
        web.stopLoading()
        observers.removeAll()
    }

    // MARK: capture

    func addTapped() {
        guard !isBusy, let u = web.url, u.scheme == "http" || u.scheme == "https" else { NSSound.beep(); return }
        let plan = CapturePlan.make(for: u, sections: LinkedInSection.all)
        if plan.offersSections { sections = Set(LinkedInSection.all); phase = .confirming(plan) }
        else { start(plan) }
    }

    func confirm() {
        guard case .confirming(let p) = phase else { return }
        start(CapturePlan.make(for: p.start, sections: LinkedInSection.all.filter { sections.contains($0) }))
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .browsing
    }

    func dismissNote() { if !isBusy { phase = .browsing } }

    private func start(_ plan: CapturePlan) {
        task = Task { [weak self] in await self?.run(plan) }
    }

    private func run(_ plan: CapturePlan) async {
        var parts: [CapturedPart] = []
        var signedIn = false
        let total = plan.steps.count
        for (i, step) in plan.steps.enumerated() {
            if Task.isCancelled { return }
            if i > 0 {                                       // a human pace between pages
                let secs = Int(CapturePlan.pause(Double.random(in: 0...1)).rounded())
                for s in stride(from: secs, to: 0, by: -1) {
                    phase = .pausing(s, i + 1, total)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { return }
                }
            }
            let n = ["n": "\(i + 1)", "total": "\(total)"]
            phase = .working(L("sheet.browser.step.loading", n))
            if !Self.same(web.url, step.url) {
                web.load(URLRequest(url: step.url))
                await waitLoaded()
            }
            if Task.isCancelled { return }
            phase = .working(L("sheet.browser.step.scrolling", n))
            await scrollToEnd()
            phase = .working(L("sheet.browser.step.expanding", n))
            for _ in 0..<3 {
                let clicked = Int(await js(Self.expandJS) ?? "0") ?? 0
                if clicked == 0 { break }
                try? await Task.sleep(nanoseconds: 900_000_000)
                await scrollToEnd()
            }
            if Task.isCancelled { return }
            phase = .working(L("sheet.browser.step.reading", n))
            guard let raw = await js(Self.extractJS), let d = raw.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
                phase = .failed(L("sheet.browser.failed", ["reason": L("sheet.browser.failed.read")]))
                return
            }
            signedIn = signedIn || (o["signedIn"] as? Bool ?? false)
            parts.append(CapturedPart(url: o["url"] as? String ?? step.url.absoluteString, title: o["title"] as? String ?? "",
                                      html: o["html"] as? String ?? "", text: o["text"] as? String ?? "", section: step.section))
            _ = await js("window.scrollTo(0, 0); ''")
        }
        if Task.isCancelled { return }
        let live = liveFolder ?? AppPaths.support.appendingPathComponent("browser", isDirectory: true)
        let folder = CaptureFiles.folder(live: live)
        let r = CaptureFiles.assemble(start: plan.start, kind: plan.kind, parts: parts, signedIn: signedIn, at: Date(), folder: folder)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try r.htmlDoc.write(toFile: r.page.htmlPath, atomically: true, encoding: .utf8)
            try r.textDoc.write(toFile: r.page.textPath, atomically: true, encoding: .utf8)
        } catch {
            phase = .failed(L("sheet.browser.failed", ["reason": error.localizedDescription]))
            return
        }
        phase = .saved(L("sheet.browser.saved", ["title": r.page.title.isEmpty ? r.page.url : r.page.title]))
        onCapture(r.page)
    }

    static func same(_ a: URL?, _ b: URL) -> Bool {
        guard let a else { return false }
        func k(_ u: URL) -> String {
            var s = (u.host ?? "").lowercased().replacingOccurrences(of: "www.", with: "") + u.path
            while s.hasSuffix("/") { s.removeLast() }
            return s
        }
        return k(a) == k(b)
    }

    private func waitLoaded() async {
        try? await Task.sleep(nanoseconds: 400_000_000)
        var waited = 0
        while web.isLoading && waited < 300 && !Task.isCancelled {      // up to 30 s
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
        try? await Task.sleep(nanoseconds: 1_200_000_000)             // single-page apps render after load
    }

    /// Scrolls step by step until the height stops growing (lazy sections such as Education load on the way).
    private func scrollToEnd() async {
        var lastHeight = -1
        var still = 0
        for _ in 0..<CapturePlan.maxScrolls {
            if Task.isCancelled { return }
            let r = await js("(function(){var e=document.scrollingElement||document.documentElement;window.scrollBy(0,Math.max(400,window.innerHeight*0.9));"
                             + "return JSON.stringify([e.scrollHeight, Math.ceil(window.scrollY+window.innerHeight)]);})()") ?? "[0,0]"
            let nums = r.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: ",").compactMap { Int($0) }
            let h = nums.first ?? 0
            let bottom = nums.count > 1 ? nums[1] : 0
            try? await Task.sleep(nanoseconds: 650_000_000)
            if bottom >= h - 4 {
                if h == lastHeight { still += 1 } else { still = 0 }
                if still >= 2 { return }
            }
            lastHeight = h
        }
    }

    private func js(_ source: String) async -> String? {
        await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            web.evaluateJavaScript(source) { result, _ in c.resume(returning: result as? String) }
        }
    }

    /// Clicks "see more", "show more", "show all" buttons (not links: links to other pages come only from the plan).
    static let expandJS = """
    (function(){var n=0;var rx=/^(\\u2026\\s*|\\.\\.\\.\\s*)?(see more|show more|show all|read more|see all|more)$/i;
    document.querySelectorAll('button,[role=button],summary').forEach(function(b){
      var t=((b.innerText||'')+'').trim()||(b.getAttribute('aria-label')||'').trim();
      if(!t||t.length>48)return; var low=t.toLowerCase();
      var ok=rx.test(t)||/^(see|show) (more|all)\\b/i.test(t)||/(\\u2026|\\.\\.\\.)\\s*(see )?more$/i.test(t);
      if(!ok)return; if(low==='more'||low==='show all filters')return;
      if(/connect|follow|message|sign|join|apply|download|subscribe/i.test(t))return;
      if(b.closest('a[href],form,nav,header,[role=dialog]'))return;
      if(b.getAttribute('aria-expanded')==='true')return;
      try{b.click();n++;}catch(e){}
    });return String(n);})()
    """

    /// The main content, cleaned: no scripts, media, forms, hidden duplicates, mailto/tel links; few attributes.
    static let extractJS = """
    (function(){
      var root=document.querySelector('main')||document.querySelector('[role=main]')||document.body;
      var clone=root.cloneNode(true);
      clone.querySelectorAll('script,style,noscript,template,svg,iframe,canvas,video,audio,img,picture,source,input,textarea,select,.visually-hidden,[hidden],a[href^="mailto:"],a[href^="tel:"]').forEach(function(e){e.remove();});
      var keep={href:1,id:1,role:1,'aria-label':1,'data-view-name':1,datetime:1};
      clone.querySelectorAll('*').forEach(function(e){
        Array.prototype.slice.call(e.attributes).forEach(function(a){
          if(a.name==='class'){var c=a.value.split(/\\s+/).filter(function(x){return /^(pv-|artdeco-card|text-body|ad-banner)/.test(x);}).join(' ');
            if(c)e.setAttribute('class',c);else e.removeAttribute('class');}
          else if(!keep[a.name])e.removeAttribute(a.name);
        });
        if(e.hasAttribute('href')){try{e.setAttribute('href',new URL(e.getAttribute('href'),location.href).href);}catch(x){}}
      });
      var signed=!!document.querySelector('.global-nav,#global-nav,[data-test-global-nav]');
      return JSON.stringify({url:location.href,title:document.title,html:'<main>'+clone.innerHTML+'</main>',
        text:(root.innerText||'').replace(/\\n{3,}/g,'\\n\\n'),signedIn:signed});
    })()
    """

    // MARK: WKNavigationDelegate, WKUIDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        decisionHandler(["http", "https", "about", "blob", "data"].contains(scheme) ? .allow : .cancel)
    }

    /// target=_blank opens in this window: one window, one session.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = navigationAction.request.url { webView.load(URLRequest(url: u)) }
        return nil
    }
}

private struct BrowserWebView: NSViewRepresentable {
    let web: WKWebView
    func makeNSView(context: Context) -> WKWebView { web }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct PacenoteBrowserView: View {
    @ObservedObject var model: BrowserModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { model.back() } label: { Image(systemName: "chevron.left") }
                    .help(L("sheet.browser.back")).disabled(!model.canBack || model.isBusy)
                Button { model.forward() } label: { Image(systemName: "chevron.right") }
                    .help(L("sheet.browser.forward")).disabled(!model.canForward || model.isBusy)
                Button { model.reloadOrStop() } label: { Image(systemName: model.loading ? "xmark" : "arrow.clockwise") }
                    .help(model.loading ? L("sheet.browser.stop") : L("sheet.browser.reload")).disabled(model.isBusy)
                TextField(L("sheet.browser.address"), text: $model.address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.submitAddress() }
                    .disabled(model.isBusy)
                Button { model.addTapped() } label: { Label(L("sheet.browser.add"), systemImage: "plus.circle.fill") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.isBusy || model.web.url == nil)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10).padding(.vertical, 8)
            strip
            Divider()
            BrowserWebView(web: model.web)
        }
        .sheet(isPresented: Binding<Bool>(get: { model.isConfirming },
                                          set: { (on: Bool) in if !on && model.isConfirming { model.phase = .browsing } })) {
            planSheet
        }
    }

    @ViewBuilder private var strip: some View {
        HStack(spacing: 8) {
            switch model.phase {
            case .browsing, .confirming:
                Image(systemName: "lock.shield").foregroundStyle(.secondary)
                Text(L("sheet.browser.session")).foregroundStyle(.secondary)
            case .working(let s):
                ProgressView().controlSize(.small)
                Text(s)
                Spacer()
                Button(L("sheet.browser.cancel")) { model.cancel() }
            case .pausing(let secs, let next, let total):
                Image(systemName: "pause.circle").foregroundStyle(.secondary)
                Text(L("sheet.browser.step.pause", ["seconds": "\(secs)", "n": "\(next)", "total": "\(total)"]))
                Spacer()
                Button(L("sheet.browser.cancel")) { model.cancel() }
            case .saved(let s):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(s)
                Spacer()
                Button(L("sheet.browser.ok")) { model.dismissNote() }
            case .failed(let s):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(s)
                Spacer()
                Button(L("sheet.browser.ok")) { model.dismissNote() }
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .lineLimit(2)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var planSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("sheet.browser.plan.title")).font(.headline)
            Text(model.address).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Text(L("sheet.browser.plan.sections"))
            ForEach(LinkedInSection.all, id: \.self) { s in
                Toggle(L("sheet.browser.section." + s), isOn: Binding(get: { model.sections.contains(s) },
                                                                      set: { if $0 { model.sections.insert(s) } else { model.sections.remove(s) } }))
            }
            Text(planText).font(.callout).fixedSize(horizontal: false, vertical: true)
            Text(L("sheet.browser.session")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L("sheet.browser.cancel")) { model.phase = .browsing }.keyboardShortcut(.cancelAction)
                Button(L("sheet.browser.plan.start")) { model.confirm() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var planText: String {
        let chosen = LinkedInSection.all.filter { model.sections.contains($0) }
        if chosen.isEmpty { return L("sheet.browser.plan.web") }
        return L("sheet.browser.plan.linkedin", ["count": "\(chosen.count)",
                                                  "sections": chosen.map { L("sheet.browser.section." + $0) }.joined(separator: ", ")])
    }
}
