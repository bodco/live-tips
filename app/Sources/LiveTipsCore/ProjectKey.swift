import Foundation

/// Pacenote 0.8.7 (B2): one key per project for every count, legend and filter. A call history row keeps the name it
/// was saved with (Bink, bink, Volya, volya); it is read as the registry's slug: the exact slug first, then the name or
/// slug without case, spaces, dashes and underscores. Unknown names keep their own folded form.
public enum ProjectKey {
    public static func fold(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "[\\s_\\-]+", with: "", options: .regularExpression)
    }

    /// projects: (slug, name); workspaces: names. A workspace key is "workspace:<name>".
    public static func key(_ raw: String, projects: [(slug: String, name: String)], workspaces: [String]) -> String {
        if projects.contains(where: { $0.slug == raw }) { return raw }
        let f = fold(raw)
        if let p = projects.first(where: { fold($0.slug) == f || fold($0.name) == f }) { return p.slug }
        if let w = workspaces.first(where: { fold($0) == f }) { return "workspace:" + w }
        return f.isEmpty ? "" : "other:" + f
    }

    public static func name(_ key: String, projects: [(slug: String, name: String)], fallback: String) -> String {
        if key.hasPrefix("workspace:") { return String(key.dropFirst(10)) }
        return projects.first { $0.slug == key }?.name ?? fallback
    }
}
