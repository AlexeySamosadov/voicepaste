import Foundation
import Security

/// Tiny wrapper around the macOS Keychain for storing per-provider API keys.
///
/// Each provider (`openrouter`, `openai`, `groq`, ...) gets its own keychain
/// entry under a shared service name. We use `kSecClassGenericPassword` since
/// these are not internet credentials in the strict sense (no host/port/realm).
enum KeychainStore {
    static let service = "com.alexey.voicepaste.providerKeys"

    enum KeychainError: Error, LocalizedError {
        case unexpectedStatus(OSStatus)
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let s): return "Keychain error (\(s))"
            case .encodingFailed: return "Failed to encode key as UTF-8"
            }
        }
    }

    /// Save (insert or update) the API key for a provider. Empty string deletes.
    static func setKey(_ key: String, forProvider providerId: String) throws {
        if key.isEmpty {
            try deleteKey(forProvider: providerId)
            return
        }
        guard let data = key.data(using: .utf8) else { throw KeychainError.encodingFailed }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerId
        ]

        // Try update first (idempotent), fall back to add.
        let updateAttrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
            return
        }
        throw KeychainError.unexpectedStatus(updateStatus)
    }

    /// Read the API key for a provider; nil if missing.
    static func getKey(forProvider providerId: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Remove the API key for a provider (no-op if missing).
    static func deleteKey(forProvider providerId: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerId
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
