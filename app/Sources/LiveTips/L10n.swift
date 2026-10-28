import Foundation
import SwiftUI
import LiveTipsCore

/// Interface strings in English and Ukrainian (Pacenote 0.8). The app builds with the Command Line Tools,
/// which cannot compile .xcstrings, so the catalog is two JSON files, Resources/i18n/en.json and uk.json
/// (copied into the bundle by bundle.sh). The language is Settings > General > Interface language
/// (config.uiLanguage), the same switch as the tips window's; windows pick it up when they redraw.
/// Every key exists in both files (CoreChecks fails otherwise). Placeholders: {name}.
enum L10n {
    static var lang: String = AppConfig.load(from: AppPaths.config).uiLanguage == "uk" ? "uk" : "en"
    static let changed = Notification.Name("PacenoteLanguageChanged")
    private static var tables: [String: [String: String]] = [:]

    static func set(_ language: String) {
        let l = language == "uk" ? "uk" : "en"
        guard l != lang else { return }
        lang = l
        LangModel.shared.lang = l
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func t(_ key: String, _ args: [String: String] = [:]) -> String {
        var s = table(lang)[key] ?? table("en")[key] ?? key
        for (k, v) in args { s = s.replacingOccurrences(of: "{" + k + "}", with: v) }
        return s
    }

    static func table(_ l: String) -> [String: String] {
        if let t = tables[l] { return t }
        var t: [String: String] = [:]
        for url in candidates(l) {
            if let d = try? Data(contentsOf: url), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                t = o.compactMapValues { $0 as? String }
                break
            }
        }
        tables[l] = t
        return t
    }

    /// The bundle first; during development (swift run) the source tree next to this file.
    static func candidates(_ l: String) -> [URL] {
        var c: [URL] = []
        if let r = Bundle.main.resourceURL { c.append(r.appendingPathComponent("i18n/\(l).json")) }
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        c.append(app.appendingPathComponent("Resources/i18n/\(l).json"))
        return c
    }
}

/// A localized interface string: L("menubar.quit"), L("tips.ready.status", ["time": "12:18"]).
func L(_ key: String, _ args: [String: String] = [:]) -> String { L10n.t(key, args) }

/// Publishes the interface language so open windows redraw in the new language.
final class LangModel: ObservableObject {
    static let shared = LangModel()
    @Published var lang = L10n.lang
}

/// Wraps a window's root view: the whole view is rebuilt when the interface language changes.
struct Localized<Content: View>: View {
    @ObservedObject private var model = LangModel.shared
    let content: () -> Content
    init(@ViewBuilder _ content: @escaping () -> Content) { self.content = content }
    var body: some View { content().id(model.lang) }
}
