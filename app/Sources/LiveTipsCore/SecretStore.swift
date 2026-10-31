import Foundation
import Security

/// Keychain storage for secrets (generic passwords under one service). Values are never logged.
public struct SecretStore {
    public enum Key: String, CaseIterable {
        case claudeAPIKey = "claude_api_key"
        case claudeWorkspaceID = "claude_workspace_id"
        case notionToken = "notion_token"
        case hubspotKey = "hubspot_service_key"     // 0.8.7 (I2): a HubSpot service key
    }

    public let service: String
    public init(service: String) { self.service = service }

    // 0.8.7.1: values read once are kept in memory, so a view or a timer on the main thread does not go to the Keychain
    // again (after an app update each first read can wait on macOS's "allow access" prompt). warm() reads them at start
    // off the main thread; set() and remove() keep the cache right.
    private static var cache: [String: String] = [:]
    private static var present: [String: Bool] = [:]     // 0.8.7.1: has() answers from here while warm() waits on a prompt
    private static let lock = NSLock()
    private func ck(_ key: Key) -> String { service + "|" + key.rawValue }

    /// 0.8.7.1: reads every saved key off the main thread, then calls done on the main thread.
    public static func warm(service: String, done: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let s = SecretStore(service: service)
            let found = Key.allCases.filter { s.has($0) }      // attributes first: no prompt, fills `present`
            for k in found { _ = s.get(k) }
            DispatchQueue.main.async(execute: done)
        }
    }

    public func get(_ key: Key) -> String? {
        // Screenshot mode (demo data) never touches the Keychain: no prompt, and no real key on a picture.
        if ProcessInfo.processInfo.environment["LT_SUPPORT_DIR"] != nil { return nil }
        Self.lock.lock(); let hit = Self.cache[ck(key)]; Self.lock.unlock()
        if let hit { return hit }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key.rawValue, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data,
              let v = String(data: d, encoding: .utf8) else { return nil }
        Self.lock.lock(); Self.cache[ck(key)] = v; Self.lock.unlock()
        return v
    }

    /// 0.8.7.1: presence only. Reads the item's attributes, not its secret, so it never needs the Keychain's
    /// "allow access" prompt; Home's status line and other checks used get() in a view body and froze the app
    /// on that prompt (a new build, or a key saved by another tool).
    public func has(_ key: Key) -> Bool {
        if ProcessInfo.processInfo.environment["LT_SUPPORT_DIR"] != nil { return false }
        Self.lock.lock(); let known = Self.present[ck(key)]; Self.lock.unlock()
        if let known { return known }      // 0.8.7.1: the Keychain blocks every call while a prompt is open
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key.rawValue, kSecReturnAttributes as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        let ok = SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
        Self.lock.lock(); Self.present[ck(key)] = ok; Self.lock.unlock()
        return ok
    }

    @discardableResult
    public func set(_ key: Key, _ value: String) -> Bool {
        if ProcessInfo.processInfo.environment["LT_SUPPORT_DIR"] != nil { return false }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: key.rawValue]
        let data = Data(value.utf8)
        Self.lock.lock(); Self.cache[ck(key)] = nil; Self.present[ck(key)] = nil; Self.lock.unlock()     // 0.8.7.1: the next get reads the new value
        if SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess { return true }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public func remove(_ key: Key) -> Bool {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key.rawValue]
        Self.lock.lock(); Self.cache[ck(key)] = nil; Self.present[ck(key)] = nil; Self.lock.unlock()     // 0.8.7.1
        let st = SecItemDelete(q as CFDictionary)
        return st == errSecSuccess || st == errSecItemNotFound
    }
}
