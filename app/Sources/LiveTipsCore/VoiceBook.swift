import Foundation

/// Pacenote 0.9.4 (owner, rules/voices.yaml > people): one person, many spellings. voices.json keeps people under
/// one name (the primary) and every other spelling as an alias ("m. t." -> "Mike Turner"), so a name typed on a
/// call, a calendar participant or a Meet display name all mean that person on every next call. Pure functions
/// over the file's object; SettingsModel reads and writes the file (never during a call, the recorder owns it then).
public enum VoiceBook {
    static func people(_ o: [String: Any]) -> [String: Any] { (o["people"] as? [String: Any]) ?? [:] }
    static func aliases(_ o: [String: Any]) -> [String: String] { (o["aliases"] as? [String: String]) ?? [:] }
    static func key(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

    /// The name a spelling is kept under (aliases followed, at most 5 steps, as the recorder does).
    public static func resolve(_ o: [String: Any], _ name: String) -> String {
        let al = aliases(o); var n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0..<5 { guard let nx = al[key(n)], key(nx) != key(n) else { break }; n = nx }
        return n
    }

    /// The other spellings of a person, sorted.
    public static func aliasesOf(_ o: [String: Any], _ name: String) -> [String] {
        aliases(o).filter { key(resolve(o, $0.value)) == key(name) && $0.key != key(name) }.map(\.key).sorted()
    }

    /// Points every alias that meant `from` (or `from` itself) at `to`.
    static func repoint(_ al: inout [String: String], from: [String], to: String) {
        let olds = Set(from.map(key))
        for (k, v) in al where olds.contains(key(v)) { al[k] = to }
        for f in from where key(f) != key(to) { al[key(f)] = to }
        al.removeValue(forKey: key(to))
    }

    static func join(_ a: [String: Any], into b: [String: Any]) -> [String: Any] {
        var b = b
        b["embeddings"] = Array((((b["embeddings"] as? [Any]) ?? []) + ((a["embeddings"] as? [Any]) ?? [])).suffix(20))
        b["calls"] = ((b["calls"] as? Int) ?? 0) + ((a["calls"] as? Int) ?? 0)
        let wa = (a["where"] as? [String]) ?? [], wb = (b["where"] as? [String]) ?? []
        if !wa.isEmpty || !wb.isEmpty { let w = wb + wa.filter { !wb.contains($0) }; b["where"] = w.contains("all") ? ["all"] : w }
        if ((b["side"] as? String) ?? "").isEmpty, let s = a["side"] as? String, !s.isEmpty { b["side"] = s }
        if b["scope"] == nil, let s = a["scope"] { b["scope"] = s }
        return b
    }

    /// Two entries are one person: the voice prints join under `keep` (either name, or a new full name), both old
    /// names and all their aliases become aliases of `keep`.
    public static func merge(_ o: [String: Any], _ a: String, _ b: String, keep: String) -> [String: Any] {
        let keep = keep.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keep.isEmpty, key(a) != key(b) else { return o }
        var o = o, p = people(o), al = aliases(o)
        let ea = p.removeValue(forKey: a) as? [String: Any], eb = p.removeValue(forKey: b) as? [String: Any]
        var merged = (p.removeValue(forKey: keep) as? [String: Any]) ?? [:]
        for e in [eb, ea].compactMap({ $0 }) { merged = merged.isEmpty ? e : join(e, into: merged) }
        p[keep] = merged
        repoint(&al, from: [a, b], to: keep)
        o["people"] = p; o["aliases"] = al
        return o
    }

    /// The primary name changes; the old one becomes an alias.
    public static func rename(_ o: [String: Any], _ old: String, to new: String) -> [String: Any] {
        let new = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty, old != new else { return o }
        var o = o, p = people(o), al = aliases(o)
        if let e = p.removeValue(forKey: old) as? [String: Any] { p[new] = (p[new] as? [String: Any]).map { join(e, into: $0) } ?? e }
        repoint(&al, from: [old], to: new)
        o["people"] = p; o["aliases"] = al
        return o
    }

    /// Another spelling of a person ("M. T."). A spelling that is somebody's primary name is refused (merge instead);
    /// a spelling that already means another person is moved only with `force`.
    public enum AddResult: Equatable { case added, isPerson, otherPerson(String) }
    public static func addAlias(_ o: [String: Any], _ alias: String, to name: String, force: Bool = false) -> ([String: Any], AddResult) {
        let k = key(alias)
        guard !k.isEmpty, k != key(name) else { return (o, .added) }
        if people(o).keys.contains(where: { key($0) == k }) { return (o, .isPerson) }
        if let cur = aliases(o)[k], key(resolve(o, cur)) != key(name), !force { return (o, .otherPerson(resolve(o, cur))) }
        var o = o, al = aliases(o); al[k] = name; o["aliases"] = al
        return (o, .added)
    }

    public static func removeAlias(_ o: [String: Any], _ alias: String) -> [String: Any] {
        var o = o, al = aliases(o); al.removeValue(forKey: key(alias)); o["aliases"] = al
        return o
    }
}
