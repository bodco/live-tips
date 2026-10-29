import AppKit
import Foundation

/// 0.8.5 (owner: "Install Gemma" and local models in every model list): a model on this Mac through Ollama
/// (rules/ai.yaml > routes.local). Ollama itself comes from ollama.com (the app is not bundled); the app starts it,
/// lists its models and downloads one with progress through Ollama's own API (/api/tags, /api/pull).
@MainActor
final class LocalLLM: ObservableObject {
    static let shared = LocalLLM()
    static let url = "http://127.0.0.1:11434"
    /// The model the app suggests: about 16 GB, fits a 32 GB Mac (docs 14.1g).
    static let suggested = "gemma4:26b"
    static let suggestedLabel = "Gemma 4 26B"

    @Published private(set) var installed = false      // the Ollama app is on this Mac
    @Published private(set) var running = false
    @Published private(set) var models: [String] = []
    @Published private(set) var pulling: String? = nil
    @Published private(set) var progress: Double = 0    // 0...1 while pulling
    @Published private(set) var note = ""

    /// The chosen local model, shared by the preparation and the after-the-call jobs (one key since 0.8.5).
    static var model: String {
        get { UserDefaults.standard.string(forKey: "prepLocalModel") ?? suggested }
        set { UserDefaults.standard.set(newValue, forKey: "prepLocalModel") }
    }

    private init() { refresh() }

    static var appPath: String? {
        ["/Applications/Ollama.app", NSHomeDirectory() + "/Applications/Ollama.app"].first { FileManager.default.fileExists(atPath: $0) }
    }

    func refresh() {
        installed = Self.appPath != nil || FileManager.default.fileExists(atPath: "/usr/local/bin/ollama")
            || FileManager.default.fileExists(atPath: "/opt/homebrew/bin/ollama")
        var req = URLRequest(url: URL(string: Self.url + "/api/tags")!); req.timeoutInterval = 3
        URLSession.shared.dataTask(with: req) { d, _, e in
            let names = (d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["models"] as? [[String: Any]])?
                .compactMap { $0["name"] as? String }.map { $0.hasSuffix(":latest") ? String($0.dropLast(7)) : $0 }
            DispatchQueue.main.async { MainActor.assumeIsolated {
                self.running = e == nil
                self.models = (names ?? []).filter { !$0.contains("embed") && !$0.hasPrefix("bge") }.sorted()
            } }
        }.resume()
    }

    var hasSuggested: Bool { models.contains(Self.suggested) }

    /// Opens the Ollama app in the background (it serves on 127.0.0.1:11434), then refreshes.
    func start() {
        guard let p = Self.appPath else { NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!); return }
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: p), configuration: {
            let c = NSWorkspace.OpenConfiguration(); c.activates = false; return c }()) { _, _ in }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.refresh() }
    }

    /// Downloads a model through Ollama with progress; it then shows in every local model list.
    func install(_ name: String = suggested) {
        guard pulling == nil else { return }
        if !running { start() }
        pulling = name; progress = 0; note = L("local.pull.starting")
        var req = URLRequest(url: URL(string: Self.url + "/api/pull")!)
        req.httpMethod = "POST"; req.timeoutInterval = 6 * 3600
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["name": name, "stream": true])
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Task.detached {
            var err: String? = nil
            do {
                // Ollama may need a few seconds to come up after start()
                var bytes: URLSession.AsyncBytes? = nil
                for _ in 0..<10 {
                    if let (b, _) = try? await URLSession.shared.bytes(for: req) { bytes = b; break }
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                }
                guard let lines = bytes?.lines else { throw NSError(domain: "ollama", code: 1, userInfo: [NSLocalizedDescriptionKey: "Ollama does not answer"]) }
                for try await line in lines {
                    guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                    if let e = o["error"] as? String { err = e; break }
                    let total = (o["total"] as? NSNumber)?.doubleValue ?? 0, done = (o["completed"] as? NSNumber)?.doubleValue ?? 0
                    let status = o["status"] as? String ?? ""
                    await MainActor.run {
                        if total > 0 { self.progress = done / total }
                        self.note = total > 0 ? String(format: "%.1f / %.1f GB", done / 1e9, total / 1e9) : status
                    }
                }
            } catch { err = error.localizedDescription }
            await MainActor.run {
                self.pulling = nil
                self.note = err.map { L("local.pull.failed", ["err": $0]) } ?? L("local.pull.done")
                if err == nil { LocalLLM.model = name }
                self.refresh()
            }
        }
    }
}
