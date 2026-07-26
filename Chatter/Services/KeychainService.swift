import Foundation
import Security

/// Stores the Ollama Cloud API key in the keychain. The item is marked to sync
/// through iCloud Keychain so it follows the user across their devices.
///
/// Items live in the data-protection keychain (`kSecUseDataProtectionKeychain`):
/// unlike the legacy login keychain, access there is granted by app identity
/// (team + bundle ID) instead of per-binary ACLs, so rebuilt dev builds don't
/// trigger the macOS "enter your keychain password" prompt. Legacy items from
/// older builds are migrated over on first read.
enum KeychainService {
    private static let service = "team.budo.chatter"
    private static let apiKeyAccount = "ollamaApiKey"

    /// In-memory cache: the key is read on every Ollama request; without this
    /// each read hits the keychain (and, for legacy items, a password prompt).
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedKey: String?
    nonisolated(unsafe) private static var cacheValid = false

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: apiKeyAccount,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// Same item coordinates, but addressing the legacy (login) keychain.
    private static var legacyQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: apiKeyAccount,
        ]
    }

    static func saveAPIKey(_ key: String) throws {
        // Pasted keys often carry a trailing newline/space; Ollama's /api/chat
        // rejects the resulting header with 401 (while /api/tags tolerates it).
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = key.data(using: .utf8) else { return }

        // Remove any previous item (synced, local, or legacy) so re-saving
        // never hits errSecDuplicateItem.
        deleteAPIKey()

        var addQuery = baseQuery
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
        setCache(key)
    }

    static func loadAPIKey() -> String? {
        #if DEBUG
        // Screenshot/demo runs pass the key via environment so the real
        // keychain item is never read, written, or overwritten.
        if let demoKey = ScreenshotDemo.apiKey { return demoKey }
        #endif
        cacheLock.lock()
        if cacheValid {
            defer { cacheLock.unlock() }
            return cachedKey
        }
        cacheLock.unlock()

        // Prefer the synced item, then the local data-protection one.
        var key = load(query: baseQuery, synchronizable: true)
            ?? load(query: baseQuery, synchronizable: false)

        // Older builds stored the fallback item in the login keychain, whose
        // per-binary ACL prompts for the keychain password on every rebuild.
        // Read it once (may prompt one last time) and move it over.
        if key == nil, let legacy = load(query: legacyQuery, synchronizable: false) {
            migrateLegacyItem(legacy)
            key = legacy
        }

        setCache(key)
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
    private static func migrateLegacyItem(_ key: String) {
        guard let data = key.data(using: .utf8) else { return }
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        addQuery[kSecAttrSynchronizable as String] = true

        var status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecMissingEntitlement {
            addQuery[kSecAttrSynchronizable as String] = nil
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        guard status == errSecSuccess else { return }
        SecItemDelete(legacyQuery as CFDictionary)
    }

    static func deleteAPIKey() {
        var syncedQuery = baseQuery
        syncedQuery[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        SecItemDelete(syncedQuery as CFDictionary)
        SecItemDelete(baseQuery as CFDictionary)
        SecItemDelete(legacyQuery as CFDictionary)
        setCache(nil)
    }

    /// Drops the cached key so the next `loadAPIKey()` re-reads the keychain.
    /// Called on HTTP 401: the item syncs through iCloud Keychain, so a key
    /// changed or revoked on another device would otherwise stay invisible
    /// until the app restarts.
    static func invalidateCache() {
        cacheLock.lock()
        cacheValid = false
        cacheLock.unlock()
    }

    static var hasAPIKey: Bool {
        guard let key = loadAPIKey() else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func setCache(_ key: String?) {
        cacheLock.lock()
        cachedKey = key
        cacheValid = true
        cacheLock.unlock()
    }

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
