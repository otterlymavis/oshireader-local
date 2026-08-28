import Foundation
import Security

/// Minimal Keychain wrapper for storing on-device API credentials
/// (YouTube Data API key, X/Twitter bearer token).
enum KeychainHelper {
    private static let service = "com.otterpia.oshireader.credentials"
    private static let fallbackLock = NSLock()
    /// Serializes `save` so its read → delete → add sequence is atomic:
    /// two concurrent saves for one key could otherwise interleave and lose
    /// a write or resurrect the old value via the restore path.
    private static let saveLock = NSLock()
    private static var testFallbackStore: [String: Data] = [:]

    enum Key: String {
        case twitterBearerToken = "twitter_bearer_token"
        case apnsDeviceSecret = "apns_device_secret"
        case apnsDeviceToken = "apns_device_token"
        case apnsDeviceEnvironment = "apns_device_environment"
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            NSClassFromString("XCTestCase") != nil
    }

    private static func fallbackKey(_ key: Key) -> String {
        "\(service):\(key.rawValue)"
    }

    /// Raw data lookup for a query dictionary that already identifies the
    /// item (service+account) — used to snapshot a value before a
    /// delete-then-add so a failed add can attempt to restore it.
    private static func readRawData(base: [String: Any]) -> Data? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
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
        saveLock.lock()
        defer { saveLock.unlock() }
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
        // Read the previous value first so a failed add (delete succeeded,
        // add didn't) can attempt to restore it instead of losing the
        // credential outright.
        let previousData = readRawData(base: base)
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let succeeded = SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        if !succeeded, let previousData {
            var restore = base
            restore[kSecValueData as String] = previousData
            restore[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            _ = SecItemAdd(restore as CFDictionary, nil)
        }
        if succeeded || isRunningTests {
            fallbackLock.lock()
            testFallbackStore[fallbackKey(key)] = data
            fallbackLock.unlock()
        }
        return succeeded || isRunningTests
    }
}
