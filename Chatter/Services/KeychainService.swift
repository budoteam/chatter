import Foundation
import Security

/// Stores the Ollama Cloud API key in the keychain. The item is marked to sync
/// through iCloud Keychain so it follows the user across their devices.
enum KeychainService {
    private static let service = "team.budo.chatter"
    private static let apiKeyAccount = "ollamaApiKey"

    private static var baseQuery: [String: Any] {
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

        // Remove any previous item (synced or local) so re-saving never hits
        // errSecDuplicateItem.
        deleteAPIKey()

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        addQuery[kSecAttrSynchronizable as String] = true

        var status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecMissingEntitlement {
            // iCloud Keychain sync needs a provisioned keychain access group.
            // Without a signing team (ad-hoc/dev builds) fall back to a local,
            // non-syncing item.
            addQuery[kSecAttrSynchronizable as String] = nil
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    static func loadAPIKey() -> String? {
        // Prefer the synced item, fall back to a local one.
        if let key = load(synchronizable: true) { return key }
        return load(synchronizable: false)
    }

    private static func load(synchronizable: Bool) -> String? {
        var query = baseQuery
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

    static func deleteAPIKey() {
        var syncedQuery = baseQuery
        syncedQuery[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        SecItemDelete(syncedQuery as CFDictionary)
        SecItemDelete(baseQuery as CFDictionary)
    }

    static var hasAPIKey: Bool {
        guard let key = loadAPIKey() else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
