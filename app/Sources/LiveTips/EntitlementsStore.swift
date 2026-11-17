import AppKit
import Foundation
import LiveTipsCore

/// 0.18.0 (B3, D41; contract claude/b6-entitlements-contract.md 2): the person's signed entitlements. Fetched at launch,
/// after sign-in, when the organizations change, every 6 hours, after any 402/403 plan or quota answer and when
/// `entitlements_etag` in /v1/me differs from the cache. The signed strings are cached as they came in
/// `<app root>/state/entitlements.json` and checked again on every read (Entitlements.resolve): a file edited on this
/// Mac, copied from another Mac or another account does not count. Offline nothing is taken away (spec 6.3).
@MainActor
final class EntitlementsStore: ObservableObject {
    static let shared = EntitlementsStore()

    @Published private(set) var rights = Entitlements.resolve(nil, userID: nil, deviceID: nil)
    @Published private(set) var lastError: String?
    private var timer: Timer?
    private var inFlight = false
    private var lastPlanAnswer = Date.distantPast

    static var path: String {
        let c = AppConfig.load(from: AppPaths.config)
        return ((c.effectiveAppRoot(appSupport: AppPaths.support.path) as NSString).appendingPathComponent("state") as NSString)
            .appendingPathComponent("entitlements.json")
    }
    private func loadCache() -> Entitlements.Cache? { Entitlements.Cache.decode(FileManager.default.contents(atPath: Self.path)) }
    private func save(_ c: Entitlements.Cache) {
        try? FileManager.default.createDirectory(atPath: (Self.path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let d = c.encoded() { try? d.write(to: URL(fileURLWithPath: Self.path), options: .atomic) }
    }

    private init() {}

    /// At launch: what the cache says now, then a fetch when due; every 6 hours after that.
    func start() {
        if SheetShots.active { return }
        reload()
        Task { await refresh() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Entitlements.refreshEvery, repeats: true) { _ in
            Task { @MainActor in await EntitlementsStore.shared.refresh(force: true) }
        }
        NotificationCenter.default.addObserver(forName: PacenoteAccount.orgsChanged, object: nil, queue: .main) { _ in
            Task { @MainActor in await EntitlementsStore.shared.refresh(force: true) }
        }
    }

    /// Reads the cache again with the current session (signature, person and Mac checked).
    func reload() {
        let s = PacenoteAccount.shared.session
        rights = Entitlements.resolve(loadCache(), userID: s?.userID, deviceID: s?.deviceID)
    }

    /// /v1/me came: a changed or new `entitlements_etag` asks again, and so does a cache that is not valid.
    func meLoaded(_ me: PacenoteServer.Me) {
        reload()
        if rights.needsRefresh || Entitlements.due(loadCache(), now: Date(), meETags: me.entitlementsETags) {
            Task { await refresh(force: true) }
        }
    }

    /// Any 402/403 plan or quota answer: the rights changed on the server. At most once a minute.
    func planAnswer() {
        guard Date().timeIntervalSince(lastPlanAnswer) > 60 else { return }
        lastPlanAnswer = Date()
        Task { await refresh(force: true) }
    }

    func signedOut() {
        try? FileManager.default.removeItem(atPath: Self.path)
        rights = Entitlements.resolve(nil, userID: nil, deviceID: nil)
    }

    /// GET /v1/entitlements (If-None-Match) and /v1/catalog (If-None-Match). A bad signature is no answer: the cache
    /// stays and the next check tries again.
    func refresh(force: Bool = false) async {
        let acct = PacenoteAccount.shared
        guard acct.signedIn, !inFlight else { return }
        let old = loadCache()
        guard force || rights.needsRefresh || Entitlements.due(old, now: Date(), meETags: acct.me?.entitlementsETags ?? [:]) else { return }
        inFlight = true; defer { inFlight = false }
        do {
            var c = old ?? Entitlements.Cache()
            let (cd, cc, ch) = try await acct.apiWithHeaders("GET", Entitlements.catalogPath,
                                                            headers: c.catalog.isEmpty ? [:] : ["If-None-Match": c.catalogETag])
            if cc == 200, let o = (try? JSONSerialization.jsonObject(with: cd)) as? [String: Any], let signed = o["signed"] as? String,
               Entitlements.verify(signed) != nil {
                c.catalog = signed; c.catalogETag = ch["etag"] ?? ""
            }
            let (d, code, h) = try await acct.apiWithHeaders("GET", Entitlements.entitlementsPath,
                                                            headers: (old?.etag.isEmpty ?? true) || rights.needsRefresh ? [:] : ["If-None-Match": old!.etag])
            switch code {
            case 304:
                c.fetchedAt = Date()
            case 200:
                guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { throw PacenoteAccountError.server(code, "bad body") }
                let n = Entitlements.cache(from: o, etag: h["etag"] ?? "", now: Date(), keeping: c)
                let s = acct.session
                let check = Entitlements.resolve(n, userID: s?.userID, deviceID: s?.deviceID)
                guard check.basis == .live else {
                    lastError = "signature"
                    UsageLog.log("entitlements_refresh", ["ok": false, "why": "signature"])
                    save(c); reload(); return
                }
                c = n
            default:
                throw PacenoteAccountError.server(code, PacenoteServer.problem(d, status: code))
            }
            save(c); reload(); lastError = nil
            UsageLog.log("entitlements_refresh", ["ok": true, "why": code == 304 ? "same" : "new"])
        } catch {
            lastError = error.localizedDescription
            UsageLog.log("entitlements_refresh", ["ok": false, "why": "network"])
            let code = Analytics.errorCode(error)                                      // 0.19.0 (S4)
            AnalyticsTracker.onMain { AnalyticsTracker.shared.error("entitlements", code, provider: "pacenote") }
        }
    }
}
