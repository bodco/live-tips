import Foundation

/// 0.16.0 (D3, updates): the release notes of an appcast item (HTML in `<description>`) as plain lines for
/// About > Updates: the `<li>` items, else the paragraphs, at most six, tags and the common entities removed.
public enum AppcastNotes {
    public static func bullets(_ html: String?) -> [String] {
        guard let html, !html.isEmpty else { return [] }
        func strip(_ s: String) -> String {
            s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&amp;", with: "&")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let items = html.components(separatedBy: "<li>").dropFirst().map { strip($0.components(separatedBy: "</li>")[0]) }
        let lines = items.isEmpty ? html.components(separatedBy: "</p>").map(strip) : Array(items)
        return Array(lines.filter { !$0.isEmpty }.prefix(6))
    }
}
