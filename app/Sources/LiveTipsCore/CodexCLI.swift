import Foundation

/// Pure helpers shared by account discovery and its checks. Credentials stay with the Codex CLI.
public enum CodexCLI {
    public static func candidates(home: String, path: String) -> [String] {
        [home + "/.local/bin/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
         "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
         "/Applications/Codex.app/Contents/Resources/codex",
         home + "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
         home + "/Applications/Codex.app/Contents/Resources/codex"]
            + path.split(separator: ":").map { String($0) + "/codex" }
    }

    public static func isChatGPT(status: Int32, output: String) -> Bool {
        status == 0 && output.lowercased().contains("logged in using chatgpt")
    }

    public static func environment(_ base: [String: String]) -> [String: String] {
        let hidden = Set(["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN", "OPENAI_BASE_URL",
                          "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_API", "NOTION_TOKEN"])
        return base.filter { !hidden.contains($0.key) }
    }

    public static func loginCommand(cli: String) -> String {
        let quoted = "'" + cli.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "env -u OPENAI_API_KEY -u CODEX_API_KEY -u CODEX_ACCESS_TOKEN " + quoted
            + " -c 'forced_login_method=\"chatgpt\"' login"
    }
}
