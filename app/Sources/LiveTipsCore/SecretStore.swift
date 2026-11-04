import Foundation
import Security

/// Keychain storage for secrets (generic passwords under one service). Values are never logged.
public struct SecretStore {
    public enum Key: String, CaseIterable {
        case claudeAPIKey = "claude_api_key"
        case openaiAPIKey = "openai_api_key"
        case claudeWorkspaceID = "claude_workspace_id"
        case notionToken = "notion_token"
        case hubspotKey = "hubspot_service_key"     // 0.8.7 (I2): a HubSpot service key
        case googleAccounts = "google_accounts"     // 0.9.1: JSON list of the connected Google accounts (refresh tokens)
    }

    public let service: String
    public init(service: String) { self.service = service }

    /// 0.8.8: every secret lives in ONE generic password (this account, the value a JSON object of the keys). macOS
    /// asks "allow access" once per item after each update of a self-signed app (the item's partition list holds the
    /// cdhash of each build that was allowed), so one item means at most one prompt. The item's generic attribute
    /// holds only the key NAMES, so has() reads attributes and never prompts. The old per-key items stay as a fallback
    /// while the combined item is missing.
    public static let combinedAccount = "pacenote_secrets"

    // 0.8.7.1: values read once are kept in memory, so a view or a timer on the main thread does not go to the Keychain
    // again (after an app update each first read can wait on macOS's "allow access" prompt). warm() reads them at start
    // off the main thread; set() and remove() keep the cache right.
    private static var cache: [String: String] = [:]
    private static var present: [String: Bool] = [:]     // 0.8.7.1: has() answers from here while warm() waits on a prompt
    private static var combinedLoaded = Set<String>()    // 0.8.8: services whose combined item was read (or is missing)
    private static var combinedExists: [String: Bool] = [:]
    private static var combinedUnread = Set<String>()    // 0.8.8: exists, but its value could not be read (Deny)
    private static let lock = NSLock()
    private func ck(_ key: Key) -> String { service + "|" + key.rawValue }
    private static var demo: Bool { ProcessInfo.processInfo.environment["LT_SUPPORT_DIR"] != nil }

    // MARK: pure helpers (CoreChecks)

    /// The combined item's value: a JSON object, keys sorted, empty values left out.
    public static func pack(_ values: [String: String]) -> Data {
        let clean = values.filter { !$0.value.isEmpty }
        return (try? JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    /// The keys of a combined value; nil when it is not a JSON object of strings.
    public static func unpack(_ data: Data) -> [String: String]? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var out: [String: String] = [:]
        for (k, v) in o { if let s = v as? String, !s.isEmpty { out[k] = s } }
        return out
    }

    /// Key names only (never values), for the item's generic attribute.
    public static func namesAttribute(_ values: [String: String]) -> Data { Data(values.keys.sorted().joined(separator: ",").utf8) }
    public static func names(from attr: Data?) -> Set<String> {
        Set((attr.flatMap { String(data: $0, encoding: .utf8) } ?? "").split(separator: ",").map(String.init).filter { !$0.isEmpty })
    }

    public enum Plan: Equatable { case useCombined, migrate([String]), nothing }
    /// What warm() does at start: the combined item wins; without it the old per-key items are read once and packed.
    public static func plan(combinedExists: Bool, oldPresent: [String]) -> Plan {
        if combinedExists { return .useCombined }
        return oldPresent.isEmpty ? .nothing : .migrate(oldPresent.sorted())
    }

    // MARK: Keychain

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    /// Attributes only (no prompt): does the item exist, and the generic attribute.
    private func attributes(_ account: String) -> (exists: Bool, generic: Data?) {
        var q = query(account)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return (false, nil) }
        return (true, (out as? [String: Any])?[kSecAttrGeneric as String] as? Data)
    }

    private func readData(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private func writeData(_ account: String, _ data: Data, generic: Data? = nil) -> Bool {
        var upd: [String: Any] = [kSecValueData as String: data]
        if let generic { upd[kSecAttrGeneric as String] = generic }
        let st = SecItemUpdate(query(account) as CFDictionary, upd as CFDictionary)
        if st == errSecSuccess { return true }
        guard st == errSecItemNotFound else { return false }
        var add = query(account)
        add.merge(upd) { a, _ in a }
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "Pacenote secrets"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    /// Reads the combined item once per run (one prompt at most) into the cache. false when it does not exist.
    @discardableResult
    private func loadCombined() -> Bool {
        Self.lock.lock()
        if Self.combinedLoaded.contains(service) { let e = Self.combinedExists[service] ?? false; Self.lock.unlock(); return e }
        Self.lock.unlock()
        let exists = attributes(Self.combinedAccount).exists
        let parsed = exists ? readData(Self.combinedAccount).flatMap(Self.unpack) : nil
        let values = parsed ?? [:]
        Self.lock.lock()
        if exists && parsed == nil { Self.combinedUnread.insert(service) } else { Self.combinedUnread.remove(service) }
        for k in Key.allCases where exists {
            let v = values[k.rawValue]
            Self.cache[ck(k)] = v
            Self.present[ck(k)] = v != nil
        }
        Self.combinedLoaded.insert(service); Self.combinedExists[service] = exists
        Self.lock.unlock()
        return exists
    }

    /// Every value known now (the cache after loadCombined), for a write of the whole item.
    private func currentValues() -> [String: String] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var out: [String: String] = [:]
        for k in Key.allCases { if let v = Self.cache[ck(k)] { out[k.rawValue] = v } }
        return out
    }

    private func writeCombined(_ values: [String: String]) -> Bool {
        let ok = writeData(Self.combinedAccount, Self.pack(values), generic: Self.namesAttribute(values))
        if ok { Self.lock.lock(); Self.combinedLoaded.insert(service); Self.combinedExists[service] = true; Self.lock.unlock() }
        return ok
    }

    /// 0.8.7.1, 0.8.8: off the main thread at start. Reads the combined item (one prompt at most); without it, reads
    /// the old per-key items once and writes the combined item (the migration). Then calls done on the main thread.
    public static func warm(service: String, done: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let s = SecretStore(service: service)
            if !demo {
                let exists = s.attributes(combinedAccount).exists
                let old = Key.allCases.filter { s.attributes($0.rawValue).exists }.map { $0.rawValue }
                switch plan(combinedExists: exists, oldPresent: old) {
                case .useCombined:
                    s.loadCombined()
                case .migrate(let names):
                    var values: [String: String] = [:]
                    for n in names { if let d = s.readData(n), let v = String(data: d, encoding: .utf8), !v.isEmpty { values[n] = v } }
                    lock.lock()
                    for k in Key.allCases { cache[s.ck(k)] = values[k.rawValue]; present[s.ck(k)] = values[k.rawValue] != nil }
                    lock.unlock()
                    if !values.isEmpty { _ = s.writeCombined(values) }
                case .nothing:
                    lock.lock(); combinedLoaded.insert(service); combinedExists[service] = false
                    for k in Key.allCases { present[s.ck(k)] = false }
                    lock.unlock()
                }
            }
            DispatchQueue.main.async(execute: done)
        }
    }

    public func get(_ key: Key) -> String? {
        // Screenshot mode (demo data) never touches the Keychain: no prompt, and no real key on a picture.
        if Self.demo { return nil }
        Self.lock.lock(); let hit = Self.cache[ck(key)]; let known = Self.present[ck(key)]; Self.lock.unlock()
        if let hit { return hit }
        if known == false { return nil }
        if loadCombined() {
            Self.lock.lock(); let v = Self.cache[ck(key)]; Self.lock.unlock()
            return v
        }
        // fallback while the combined item is missing: the old per-key item
        guard let d = readData(key.rawValue), let v = String(data: d, encoding: .utf8) else { return nil }
        Self.lock.lock(); Self.cache[ck(key)] = v; Self.present[ck(key)] = true; Self.lock.unlock()
        return v
    }

    /// 0.8.7.1: presence only. Reads attributes, not the secret, so it never needs the Keychain's "allow access"
    /// prompt. 0.8.8: the combined item's key names first, then the old per-key item.
    public func has(_ key: Key) -> Bool {
        if Self.demo { return false }
        Self.lock.lock(); let known = Self.present[ck(key)]; Self.lock.unlock()
        if let known { return known }      // 0.8.7.1: the Keychain blocks every call while a prompt is open
        let c = attributes(Self.combinedAccount)
        let ok = c.exists ? Self.names(from: c.generic).contains(key.rawValue) : attributes(key.rawValue).exists
        Self.lock.lock(); Self.present[ck(key)] = ok; Self.lock.unlock()
        return ok
    }

    /// 0.8.8: the combined item exists but was not read (the prompt was denied): read it again before a write, so a
    /// write never drops the other keys. false when it still cannot be read.
    private func readyToWrite() -> Bool {
        loadCombined()
        Self.lock.lock(); let unread = Self.combinedUnread.contains(service); Self.lock.unlock()
        guard unread else { return true }
        Self.lock.lock(); Self.combinedLoaded.remove(service); Self.lock.unlock()
        loadCombined()
        Self.lock.lock(); defer { Self.lock.unlock() }
        return !Self.combinedUnread.contains(service)
    }

    private var combinedThere: Bool { Self.lock.lock(); defer { Self.lock.unlock() }; return Self.combinedExists[service] ?? false }

    @discardableResult
    public func set(_ key: Key, _ value: String) -> Bool {
        if Self.demo { return false }
        guard readyToWrite() else { return false }
        var values = currentValues()
        if !combinedThere {      // not migrated yet: keep the other old keys in the new item
            for k in Key.allCases where values[k.rawValue] == nil && k != key { if let v = get(k) { values[k.rawValue] = v } }
        }
        values[key.rawValue] = value
        guard writeCombined(values) else { return false }
        Self.lock.lock(); Self.cache[ck(key)] = value.isEmpty ? nil : value; Self.present[ck(key)] = !value.isEmpty; Self.lock.unlock()
        return true
    }

    @discardableResult
    public func remove(_ key: Key) -> Bool {
        if Self.demo { return false }
        guard readyToWrite() else { return false }
        var values = currentValues()
        values[key.rawValue] = nil
        let ok = combinedThere ? writeCombined(values) : true
        Self.lock.lock(); Self.cache[ck(key)] = nil; Self.present[ck(key)] = false; Self.lock.unlock()
        let st = SecItemDelete(query(key.rawValue) as CFDictionary)        // the old per-key item, when there is one
        return ok && (st == errSecSuccess || st == errSecItemNotFound)
    }
}
