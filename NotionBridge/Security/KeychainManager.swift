// KeychainManager.swift — Keychain CRUD Wrapper
// NotionBridge · Security
// V3-QUALITY B1: Secure token storage via macOS Keychain (SecItem API).
// Thread-safe — all operations are synchronous via Security framework.

import Foundation
import Security

/// Provides CRUD operations for storing sensitive values in the macOS Keychain.
/// Uses kSecClassGenericPassword with service "com.notionbridge".
public final class KeychainManager: Sendable {

    public static let shared = KeychainManager()

    /// Keychain service identifier.
    private static let service = "com.notionbridge"

    private init() {}

    /// When running outside an .app bundle (e.g. test binary), keychain ops
    /// return safe no-ops to avoid password prompt storms from mismatched code signatures.
    private var isAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    // MARK: - CRUD Operations

    /// Save a value to the Keychain. Overwrites if key already exists.
    @discardableResult
    public func save(key: String, value: String) -> Bool {
        guard isAppBundle else { return true }
        guard let data = value.data(using: .utf8) else { return false }

        // Delete existing item first (SecItemAdd fails if duplicate)
        delete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            print("[KeychainManager] ⚠️ Save failed for '\(key)': OSStatus \(status)")
        }
        return status == errSecSuccess
    }

    /// Read a value from the Keychain. Returns nil if not found.
    public func read(key: String) -> String? {
        guard isAppBundle else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    /// Delete a value from the Keychain. Returns true if deleted or not found.
    @discardableResult
    public func delete(key: String) -> Bool {
        guard isAppBundle else { return true }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Check if a key exists in the Keychain.
    public func exists(key: String) -> Bool {
        guard isAppBundle else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: false
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Update an existing value in the Keychain. Falls back to save if not found.
    @discardableResult
    public func update(key: String, value: String) -> Bool {
        guard isAppBundle else { return true }
        guard let data = value.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            return save(key: key, value: value)
        }
        return status == errSecSuccess
    }

    // MARK: - Convenience

    /// Well-known key constants for token storage.
    public enum Key {
        public static let notionAPIToken = "notion_api_token"
    }

    /// List all keys stored under this service.
    public func allKeys() -> [String] {
        guard isAppBundle else { return [] }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return []
        }

        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// Delete all items stored under this service.
    @discardableResult
    public func deleteAll() -> Bool {
        guard isAppBundle else { return true }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
