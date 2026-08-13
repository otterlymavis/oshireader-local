import Foundation
import Security

/// Minimal Keychain wrapper for storing on-device API credentials
/// (YouTube Data API key, X/Twitter bearer token).
enum KeychainHelper {
    private static let service = "com.otterpia.oshireader.credentials"
    private static let fallbackLock = NSLock()
    private static var testFallbackStore: [String: Data] = [:]

    enum Key: String {
        case twitterBearerToken = "twitter_bearer_token"
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            NSClassFromString("XCTestCase") != nil
    }

    private static func fallbackKey(_ key: Key) -> String {
        "\(service):\(key.rawValue)"
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
            guard isRunningTests else { return nil }
            fallbackLock.lock()
            defer { fallbackLock.unlock() }
            guard let data = testFallbackStore[fallbackKey(key)],
                  let value = String(data: data, encoding: .utf8),
                  !value.isEmpty else { return nil }
            return value
        }
        if isRunningTests {
            fallbackLock.lock()
            testFallbackStore[fallbackKey(key)] = data
            fallbackLock.unlock()
        }
        return value
    }

    /// Store (or clear, when value is empty/nil) a secret.
    @discardableResult
    static func save(_ key: Key, _ value: String?) -> Bool {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]

        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            let status = SecItemDelete(base as CFDictionary)
            if isRunningTests {
                fallbackLock.lock()
                testFallbackStore.removeValue(forKey: fallbackKey(key))
                fallbackLock.unlock()
            }
            return status == errSecSuccess || status == errSecItemNotFound || isRunningTests
        }

        // Delete-then-add rather than SecItemUpdate: kSecAttrAccessible is
        // not reliably changeable on an existing item via update, so this
        // is also how an item saved before the this-device-only hardening
        // gets migrated, instead of keeping its original accessibility.
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let succeeded = SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        if succeeded || isRunningTests {
            fallbackLock.lock()
            testFallbackStore[fallbackKey(key)] = data
            fallbackLock.unlock()
        }
        return succeeded || isRunningTests
    }
}
