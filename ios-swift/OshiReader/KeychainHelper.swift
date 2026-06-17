import Foundation
import Security

/// Minimal Keychain wrapper for storing on-device API credentials
/// (YouTube Data API key, X/Twitter bearer token). Replaces the old
/// backend `/api/credentials` endpoint now that ingestion runs locally.
enum KeychainHelper {
    private static let service = "com.otterpia.oshireader.credentials"

    enum Key: String {
        case twitterBearerToken = "twitter_bearer_token"
    }

    /// Read a stored secret. Returns nil when absent or empty.
    static func read(_ key: Key) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Store (or clear, when value is empty/nil) a secret.
    static func save(_ key: Key, _ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]

        // Delete any existing entry first, then re-add if we have a value.
        SecItemDelete(base as CFDictionary)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return }

        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
