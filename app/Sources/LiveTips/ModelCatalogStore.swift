import Foundation
import LiveTipsCore
import SwiftUI

/// 0.26.2 (owner, 2026-11-20): the model lists of the Claude, OpenAI and Gemini API pickers come from the provider
/// itself (GET /models with the key), so a new model appears without an app update. The list is read when a picker is
/// shown (at most every 6 hours), when a key is tested and on the Refresh button; the last answer is kept in
/// state/models-<provider>.json, and the built-in list shows until the provider has been reached once. Only text models
/// are listed, newest first (ModelCatalog). The key is read off the main thread and never logged.
@MainActor
final class ModelCatalogStore: ObservableObject {
    static let shared = ModelCatalogStore()

    enum Status: Equatable { case idle, loading, live(Int), failed }

    @Published private(set) var lists: [ModelCatalog.Provider: [ModelCatalog.Entry]] = [:]
    @Published private(set) var status: [ModelCatalog.Provider: Status] = [:]
    private var fetchedAt: [ModelCatalog.Provider: Double] = [:]
    private let dir: String

    private init() {
        dir = SpendWatch.stateDir
        for p in ModelCatalog.Provider.allCases {
            if let c = ModelCatalog.loadCache(dir: dir, provider: p) {
                lists[p] = ModelCatalog.relabel(c.entries)      // a price added by an app update shows at once
                fetchedAt[p] = c.fetchedAt
            }
        }
    }

    func entries(_ p: ModelCatalog.Provider) -> [ModelCatalog.Entry] { lists[p] ?? [] }

    /// Reads the provider's list unless it is fresh; `force` (the Refresh button, a key just tested) reads it anyway.
    /// Nothing happens without a key: the built-in or the cached list stays.
    func refresh(_ p: ModelCatalog.Provider, force: Bool = false) {
        if status[p] == .loading { return }
        if !force, let t = fetchedAt[p], ModelCatalog.isFresh(fetchedAt: t) { return }
        let service = Bundle.main.bundleIdentifier ?? "io.github.example.livetips"
        status[p] = .loading
        Task {
            let creds = await Task.detached(priority: .utility) { Self.credentials(p, service: service) }.value
            guard let key = creds.key, !key.isEmpty else { status[p] = .idle; return }
            let fetched = await Self.fetch(p, key: key, workspace: creds.workspace)
            if let list = fetched, !list.isEmpty {
                let now = Date().timeIntervalSince1970
                lists[p] = list
                fetchedAt[p] = now
                ModelCatalog.saveCache(list, fetchedAt: now, dir: dir, provider: p)
                status[p] = .live(list.count)
            } else {
                status[p] = .failed
            }
        }
    }

    func refreshAll(force: Bool = false) {
        for p in ModelCatalog.Provider.allCases { refresh(p, force: force) }
    }

    nonisolated private static func credentials(_ p: ModelCatalog.Provider, service: String) -> (key: String?, workspace: String?) {
        let s = SecretStore(service: service)      // has() reads attributes only, so no Keychain prompt without a key
        switch p {
        case .claude:
            if s.has(.claudeAPIKey) { return (s.get(.claudeAPIKey), s.get(.claudeWorkspaceID)) }
        case .openai:
            if s.has(.openaiAPIKey) { return (s.get(.openaiAPIKey), nil) }
        case .gemini:
            if s.has(.geminiAPIKey) { return (s.get(.geminiAPIKey), nil) }
        }
        return (nil, nil)
    }

    /// Every page of the provider's list (a handful at most), or nil when any request fails.
    nonisolated private static func fetch(_ p: ModelCatalog.Provider, key: String, workspace: String?) async -> [ModelCatalog.Entry]? {
        var all: [ModelCatalog.Entry] = []
        var cursor: String? = nil
        for _ in 0..<8 {
            guard let got = await loadPage(p, key: key, workspace: workspace, cursor: cursor) else { return nil }
            all += got.entries
            guard let next = got.next else { break }
            cursor = next
        }
        return ModelCatalog.unique(ModelCatalog.sorted(all))
    }

    nonisolated private static func loadPage(_ p: ModelCatalog.Provider, key: String, workspace: String?, cursor: String?) async -> ModelCatalog.Page? {
        var req: URLRequest
        switch p {
        case .gemini:
            var c = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")
            var q = [URLQueryItem(name: "pageSize", value: "200")]
            if let t = cursor { q.append(URLQueryItem(name: "pageToken", value: t)) }
            c?.queryItems = q
            guard let url = c?.url else { return nil }
            req = URLRequest(url: url)
            req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        case .openai:
            guard let url = URL(string: "https://api.openai.com/v1/models") else { return nil }
            req = URLRequest(url: url)
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .claude:
            var c = URLComponents(string: "https://api.anthropic.com/v1/models")
            var q = [URLQueryItem(name: "limit", value: "100")]
            if let t = cursor { q.append(URLQueryItem(name: "after_id", value: t)) }
            c?.queryItems = q
            guard let url = c?.url else { return nil }
            req = URLRequest(url: url)
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            if let w = workspace, !w.isEmpty { req.setValue(w, forHTTPHeaderField: "anthropic-workspace-id") }
        }
        req.timeoutInterval = 15
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return ModelCatalog.parse(p, data)
        } catch { return nil }
    }
}

/// The picker text of a model: its label, "price unknown" when the app has no price for it, "(recommended)".
enum ModelLabel {
    static func text(_ m: ModelCatalog.Entry, recommended: Bool = false) -> String {
        m.label + (m.known ? "" : L("ai.model.priceUnknown")) + (recommended ? L("ai.route.recommended") : "")
    }
}

/// Under a model picker: where the list comes from and a Refresh button.
struct ModelListNote: View {
    let provider: ModelCatalog.Provider
    @ObservedObject var catalog = ModelCatalogStore.shared

    var body: some View {
        HStack(spacing: 8) {
            Text(line).font(PN.Font.caption).foregroundStyle(PN.C.text3).fixedSize(horizontal: false, vertical: true)
            Button(L("ai.models.refresh")) { catalog.refresh(provider, force: true) }
                .buttonStyle(.link).font(PN.Font.caption)
                .disabled(catalog.status[provider] == .loading)
        }
    }

    private var line: String {
        let n = catalog.entries(provider).count
        switch catalog.status[provider] ?? .idle {
        case .loading: return L("ai.models.loading")
        case .live(let count): return L("ai.models.live", ["n": "\(count)"])
        case .failed: return n == 0 ? L("ai.models.failed.builtin") : L("ai.models.failed", ["n": "\(n)"])
        case .idle: return n == 0 ? L("ai.models.builtin") : L("ai.models.cached", ["n": "\(n)"])
        }
    }
}
