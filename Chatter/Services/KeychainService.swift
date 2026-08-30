import Foundation
import Security

/// Stores API keys in the keychain. Items are marked to sync through iCloud
/// Keychain so they follow the user across their devices.
///
/// Items live in the data-protection keychain (`kSecUseDataProtectionKeychain`):
/// unlike the legacy login keychain, access there is granted by app identity
/// (team + bundle ID) instead of per-binary ACLs, so rebuilt dev builds don't
/// trigger the macOS "enter your keychain password" prompt. Legacy items from
/// older builds are migrated over on first read.
enum KeychainService {
    /// Which stored credential an operation addresses. The Ollama key keeps
    /// the original API (`saveAPIKey()` etc.) as thin wrappers.
    enum KeyAccount: String {
        case ollama = "ollamaApiKey"
        case openRouter = "openRouterApiKey"
    }

    private static let service = "team.budo.chatter"

    /// In-memory cache per account: the key is read on every API request;
    /// without this each read hits the keychain (and, for legacy items, a
    /// password prompt). A present entry is authoritative — even when nil.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [KeyAccount: String?] = [:]

    private static func baseQuery(account: KeyAccount) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// Same item coordinates, but addressing the legacy (login) keychain.
    private static func legacyQuery(account: KeyAccount) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
    }

    static func save(_ key: String, account: KeyAccount) throws {
        // Pasted keys often carry a trailing newline/space; Ollama's /api/chat
        // rejects the resulting header with 401 (while /api/tags tolerates it).
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = key.data(using: .utf8) else { return }

        // Remove any previous item (synced, local, or legacy) so re-saving
        // never hits errSecDuplicateItem.
        delete(account: account)

        var addQuery = baseQuery(account: account)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        addQuery[kSecAttrSynchronizable as String] = true

        var status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecMissingEntitlement {
            // iCloud Keychain sync needs a provisioned keychain access group.
            // Fall back to a local (non-syncing) data-protection item.
            addQuery[kSecAttrSynchronizable as String] = nil
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        if status == errSecMissingEntitlement {
            // No application identifier at all (unsigned build) — last resort:
            // legacy login-keychain item.
            addQuery[kSecUseDataProtectionKeychain as String] = nil
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
        setCache(key, account: account)
    }

    static func load(account: KeyAccount) -> String? {
        #if DEBUG
        // Screenshot/demo runs pass the key via environment so the real
        // keychain item is never read, written, or overwritten.
        if account == .ollama, let demoKey = ScreenshotDemo.apiKey { return demoKey }
        #endif
        cacheLock.lock()
        if let cached = cache[account] {
            defer { cacheLock.unlock() }
            return cached
        }
        cacheLock.unlock()

        // Prefer the synced item, then the local data-protection one.
        var key = load(query: baseQuery(account: account), synchronizable: true)
            ?? load(query: baseQuery(account: account), synchronizable: false)

        // Older builds stored the fallback item in the login keychain, whose
        // per-binary ACL prompts for the keychain password on every rebuild.
        // Read it once (may prompt one last time) and move it over.
        if key == nil, let legacy = load(query: legacyQuery(account: account), synchronizable: false) {
            migrateLegacyItem(legacy, account: account)
            key = legacy
        }

        setCache(key, account: account)
        return key
    }

    private static func load(query: [String: Any], synchronizable: Bool) -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if synchronizable {
            query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        return key
    }

    /// Copies a legacy login-keychain item into the data-protection keychain;
    /// the legacy item is only removed once the copy succeeded.
    private static func migrateLegacyItem(_ key: String, account: KeyAccount) {
        guard let data = key.data(using: .utf8) else { return }
        var addQuery = baseQuery(account: account)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        addQuery[kSecAttrSynchronizable as String] = true

        var status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecMissingEntitlement {
            addQuery[kSecAttrSynchronizable as String] = nil
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        guard status == errSecSuccess else { return }
        SecItemDelete(legacyQuery(account: account) as CFDictionary)
    }

    static func delete(account: KeyAccount) {
        var syncedQuery = baseQuery(account: account)
        syncedQuery[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        SecItemDelete(syncedQuery as CFDictionary)
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        SecItemDelete(legacyQuery(account: account) as CFDictionary)
        setCache(nil, account: account)
    }

    /// Drops the cached key so the next `load` re-reads the keychain.
    /// Called on HTTP 401: the item syncs through iCloud Keychain, so a key
    /// changed or revoked on another device would otherwise stay invisible
    /// until the app restarts.
    static func invalidateCache(account: KeyAccount) {
        cacheLock.lock()
        cache[account] = nil
        cacheLock.unlock()
    }

    static func hasKey(account: KeyAccount) -> Bool {
        guard let key = load(account: account) else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func setCache(_ key: String?, account: KeyAccount) {
        cacheLock.lock()
        cache[account] = key
        cacheLock.unlock()
    }

    // MARK: - Ollama (original API, kept as wrappers)

    static func saveAPIKey(_ key: String) throws { try save(key, account: .ollama) }
    static func loadAPIKey() -> String? { load(account: .ollama) }
    static func deleteAPIKey() { delete(account: .ollama) }
    static func invalidateCache() { invalidateCache(account: .ollama) }
    static var hasAPIKey: Bool { hasKey(account: .ollama) }

    // MARK: - OpenRouter

    static func saveOpenRouterAPIKey(_ key: String) throws { try save(key, account: .openRouter) }
    static func loadOpenRouterAPIKey() -> String? { load(account: .openRouter) }
    static func deleteOpenRouterAPIKey() { delete(account: .openRouter) }
    static func invalidateOpenRouterCache() { invalidateCache(account: .openRouter) }
    static var hasOpenRouterAPIKey: Bool { hasKey(account: .openRouter) }

    enum KeychainError: Error, LocalizedError {
        case saveFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .saveFailed(let status):
                return "Keychain save failed with status: \(status)"
            }
        }
    }
}
