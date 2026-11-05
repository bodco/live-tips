import Foundation

/// 0.9.3 (owner): pure helpers for the Gemini account through Google's Antigravity CLI (`agy`). Credentials stay with
/// agy (its own sign-in); Pacenote never reads them and never passes an API key to it.
public enum AgyCLI {
    public static let defaultModel = "gemini-3.8-flash-medium"

    public static func candidates(home: String, path: String) -> [String] {
        [home + "/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
            + path.split(separator: ":").map { String($0) + "/agy" }
    }

    /// The child's environment without any API key, so the signed-in Google account is what answers and pays.
    public static func environment(_ base: [String: String]) -> [String: String] {
        let hidden = Set(["GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GENAI_USE_VERTEXAI", "GOOGLE_APPLICATION_CREDENTIALS",
                          "GOOGLE_CLOUD_PROJECT", "GOOGLE_GEMINI_BASE_URL", "OPENAI_API_KEY", "CODEX_API_KEY",
                          "CODEX_ACCESS_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_CUSTOM_HEADERS",
                          "CLAUDE_API", "NOTION_TOKEN"])
        return base.filter { !hidden.contains($0.key) }
    }

    /// `agy models` prints "<id>\t<name>" per line once signed in; the Gemini ones, in its order.
    public static func models(output: String) -> [(id: String, name: String)] {
        output.split(separator: "\n").compactMap { line -> (id: String, name: String)? in
            let parts = line.split(separator: "\t", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0].hasPrefix("gemini-"), !parts[0].contains(" ") else { return nil }
            return (id: parts[0], name: parts[1])
        }
    }

    /// The sign-in runs in Terminal in an empty temporary folder (agy asks to trust the folder it starts in).
    public static func loginCommand(cli: String) -> String {
        let quoted = "'" + cli.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "cd \"$(mktemp -d)\" && env -u GEMINI_API_KEY -u GOOGLE_API_KEY " + quoted
    }
}
