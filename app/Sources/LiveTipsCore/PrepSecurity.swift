import Foundation

/// 0.17.0 (SEC-01, research/pacenote-security-audit-2026-11-16.md): what the preparation agent (claude -p) may read and
/// fetch. Untrusted text reaches the agent (a prospect's page, a shared document, an invite, and with B6b the project
/// card colleagues edit), so the three parts of the "lethal trifecta" are kept apart: reading is narrowed (secret folders
/// and other projects' folders denied), and WebFetch goes only to the hosts the PM typed himself, never Google (Google
/// links are read through the connected accounts before the preparation) and never a host found in a calendar invite,
/// a source or a project card. The same rules are passed to the Meeting Sheet build (livetips_m0/sheet/build.py).
public enum PrepSecurity {
    /// Claude Code before 2.1.163 lets WebFetch send data through a pre-allowed host (CVE-2026-54316).
    public static let minClaude = "2.1.163"

    /// Folders under the home folder that hold keys, tokens or other apps' data.
    public static let secretDirs = [".ssh", ".aws", ".config", ".codex", ".claude", ".gnupg", ".docker", ".kube", ".gemini",
                                    ".azure", "Library"]
    /// Single files with tokens under the home folder.
    public static let secretFiles = [".netrc", ".npmrc", ".pypirc", ".git-credentials", ".claude.json", ".zsh_history",
                                     ".bash_history", ".claude/.credentials.json"]

    static func clean(_ p: String) -> String {
        var s = (p as NSString).standardizingPath
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// `a` is `b` or inside it.
    static func within(_ a: String, _ b: String) -> Bool { a == b || a.hasPrefix(b.hasSuffix("/") ? b : b + "/") }

    /// Claude Code's absolute path rule ("//Users/example/x/**"); the path starts with "/".
    static func rule(_ tool: String, _ path: String, tree: Bool) -> String { tool + "(/" + path + (tree ? "/**" : "") + ")" }

    /// Read denies for the preparation. `allowed`: the folders it is given (--add-dir and the project); a secret folder
    /// that holds one of them is not denied as a whole (its secret files still are). `otherRoots`: the other projects'
    /// folders (a client's data never reaches another client's preparation). `workRoot`: its Secrets folder is denied.
    public static func readDenies(home: String, workRoot: String, allowed: [String], otherRoots: [String]) -> [String] {
        let h = clean(home), ok = allowed.filter { !$0.isEmpty }.map(clean)
        var dirs: [String] = secretDirs.map { h + "/" + $0 }
        if !workRoot.isEmpty { dirs.append(clean(workRoot) + "/Secrets") }
        dirs.append(h + "/work/Secrets")
        dirs += otherRoots.filter { !$0.isEmpty }.map(clean)
        var out: [String] = [], seen = Set<String>()
        for d in dirs where !seen.contains(d) {
            seen.insert(d)
            // never deny a folder the preparation is given, or one that holds it
            if ok.contains(where: { within($0, d) }) { continue }
            if d == h || d == "/" { continue }
            for t in ["Read", "Grep", "Glob"] { out.append(rule(t, d, tree: true)) }
        }
        for f in secretFiles {
            let p = h + "/" + f
            if !seen.insert(p).inserted { continue }
            out.append(rule("Read", p, tree: false))
        }
        return out
    }

    /// Read allows, one per folder the preparation is given (instead of a bare Read).
    public static func readAllows(_ dirs: [String]) -> [String] {
        var out: [String] = [], seen = Set<String>()
        for d in dirs.filter({ !$0.isEmpty }).map(clean) where d != "/" && seen.insert(d).inserted {
            out += ["Read", "Grep", "Glob"].map { rule($0, d, tree: true) }
        }
        return out
    }

    /// Hosts of the http(s) links in text the PM typed himself (the call context). Google hosts are left out: Google
    /// links are read through the connected accounts, and docs.google.com would let a form collect what the agent read.
    public static func webHosts(in text: String) -> [String] {
        var hosts: Set<String> = []
        let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        det?.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { m, _, _ in
            guard let u = m?.url, let sc = u.scheme?.lowercased(), sc == "https" || sc == "http", let h = u.host?.lowercased() else { return }
            // only a link the PM wrote with its scheme: a bare "x.example.io" in pasted text is not a permission
            let typed = (text as NSString).substring(with: m!.range).lowercased()
            guard typed.hasPrefix("http://") || typed.hasPrefix("https://") else { return }
            guard h.range(of: "^[a-z0-9.-]+\\.[a-z]{2,}$", options: .regularExpression) != nil, !blocked(h) else { return }
            hosts.insert(h)
        }
        return hosts.sorted()
    }

    /// Hosts never given to WebFetch: Google (read through the accounts), form and paste services, link shorteners.
    public static func blocked(_ h: String) -> Bool {
        let bad = ["google.com", "googleusercontent.com", "googleapis.com", "forms.gle", "goo.gl", "bit.ly", "tinyurl.com",
                   "pastebin.com", "webhook.site", "requestbin.com", "ngrok.io", "ngrok-free.app", "pipedream.net"]
        return bad.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    /// The sales preparation's fetch: only the company's own domain, when the CRM gives one ("northwind.example").
    public static func salesFetchHosts(company: String) -> [String] {
        var c = company.trimmingCharacters(in: .whitespaces).lowercased()
        for p in ["https://", "http://"] where c.hasPrefix(p) { c.removeFirst(p.count) }
        c = String(c.split(separator: "/").first ?? "")
        if c.hasPrefix("www.") { c.removeFirst(4) }
        guard c.range(of: "^[a-z0-9-]+(\\.[a-z0-9-]+)+$", options: .regularExpression) != nil, !blocked(c) else { return [] }
        return [c, "www." + c]
    }

    /// The version from `claude --version` ("2.1.170 (Claude Code)"); nil when it does not read as one.
    public static func version(_ s: String) -> [Int]? {
        guard let r = s.range(of: "[0-9]+\\.[0-9]+\\.[0-9]+", options: .regularExpression) else { return nil }
        return s[r].split(separator: ".").compactMap { Int($0) }
    }

    /// Is this Claude Code new enough? nil when its version cannot be read (then nothing is blocked).
    public static func claudeOK(_ versionOutput: String) -> Bool? {
        guard let v = version(versionOutput), let m = version(minClaude) else { return nil }
        for (a, b) in zip(v, m) where a != b { return a > b }
        return true
    }
}
