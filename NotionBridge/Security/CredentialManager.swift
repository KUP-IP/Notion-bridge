// CredentialManager.swift — Polymorphic Credential Vault
// NotionBridge · Security
// PKT-372: kSecClassGenericPassword CRUD with type discriminator,
// LAContext biometric gate, and Stripe card tokenization.
//
// Two-class Keychain strategy:
// - KeychainManager: API tokens, service "com.notionbridge". Untouched.
// - CredentialManager: User credentials, user-defined service names.
//   No collision — different kSecAttrService values.

import Foundation
import Security
import LocalAuthentication

// MARK: - CredentialType

/// Discriminator for polymorphic credential storage.
/// Persisted as `kSecAttrLabel` on each Keychain item.
public enum CredentialType: String, Sendable, Codable, CaseIterable {
    case password = "password"
    case card = "card"
}

// MARK: - CredentialMetadata

/// Type-erased metadata stored as JSON in `kSecAttrComment`.
/// For `.password`: empty `{}`. For `.card`: brand, last4, expiry, stripe_pm.
public struct CredentialMetadata: Codable, Sendable, Equatable {
    public var brand: String?
    public var last4: String?
    public var expMonth: Int?
    public var expYear: Int?
    public var stripePm: String?

    public init(
        brand: String? = nil,
        last4: String? = nil,
        expMonth: Int? = nil,
        expYear: Int? = nil,
        stripePm: String? = nil
    ) {
        self.brand = brand
        self.last4 = last4
        self.expMonth = expMonth
        self.expYear = expYear
        self.stripePm = stripePm
    }

    enum CodingKeys: String, CodingKey {
        case brand, last4
        case expMonth = "exp_month"
        case expYear = "exp_year"
        case stripePm = "stripe_pm"
    }

    /// Empty metadata for password-type credentials.
    public static let empty = CredentialMetadata()
}

// MARK: - CredentialEntry

/// A credential retrieved from the Keychain (read/list results).
public struct CredentialEntry: Sendable {
    public let service: String
    public let account: String
    public let type: CredentialType
    public let metadata: CredentialMetadata
    public let password: String?      // nil for list results (metadata-only)
    public let createdAt: Date?
    public let modifiedAt: Date?
}

// MARK: - CredentialError

public enum CredentialError: Error, LocalizedError {
    case biometricFailed(String)
    case biometricUnavailable
    case keychainError(OSStatus)
    case encodingError(String)
    case stripeTokenizationFailed(String)
    case stripeKeyMissing
    case notFound
    case invalidType(String)

    public var errorDescription: String? {
        switch self {
        case .biometricFailed(let msg): return "Biometric authentication failed: \(msg)"
        case .biometricUnavailable: return "Biometric authentication unavailable on this device"
        case .keychainError(let status): return "Keychain error: OSStatus \(status)"
        case .encodingError(let msg): return "Encoding error: \(msg)"
        case .stripeTokenizationFailed(let msg): return "Stripe tokenization failed: \(msg)"
        case .stripeKeyMissing: return "STRIPE_API_KEY not found in KeychainManager"
        case .notFound: return "Credential not found"
        case .invalidType(let t): return "Invalid credential type: \(t)"
        }
    }
}

// MARK: - CredentialManager

/// Polymorphic credential vault using `kSecClassGenericPassword`.
/// Supports multiple credential types via `kSecAttrLabel` (type) and
/// `kSecAttrComment` (metadata JSON). Coexists with KeychainManager
/// (different service names, no collision).
public final class CredentialManager: Sendable {

    public static let shared = CredentialManager()

    private init() {}

    /// When running outside an .app bundle (e.g. test binary), keychain ops
    /// return safe no-ops to avoid password prompt storms from mismatched code signatures.
    private var isAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    // MARK: - Biometric Gate

    /// Evaluate LAContext biometric on the write path (save/delete).
    /// Bounded MainActor hop — explicitly scoped, not open-ended blocking.
    /// Falls back to device passcode if biometric is unavailable.
    private func requireBiometric(reason: String) async throws {
        // Skip biometric in non-app context (tests)
        guard isAppBundle else { return }

        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"

        do {
            try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
        } catch let laError as LAError {
            switch laError.code {
            case .biometryNotAvailable, .biometryNotEnrolled, .biometryLockout:
                // Fall back to device passcode
                let fallbackContext = LAContext()
                do {
                    try await fallbackContext.evaluatePolicy(
                        .deviceOwnerAuthentication,
                        localizedReason: reason
                    )
                } catch {
                    throw CredentialError.biometricFailed(error.localizedDescription)
                }
            case .userCancel, .appCancel:
                throw CredentialError.biometricFailed("Authentication cancelled")
            default:
                throw CredentialError.biometricFailed(laError.localizedDescription)
            }
        }
    }

    // MARK: - CRUD Operations

    /// Save or update a credential. Invokes biometric gate before writing.
    /// For card type, tokenizes via Stripe before storing — raw card number
    /// never touches Keychain.
    public func save(
        service: String,
        account: String,
        password: String,
        type: CredentialType = .password,
        metadata: CredentialMetadata = .empty,
        syncToiCloud: Bool = false
    ) async throws -> CredentialEntry {
        guard isAppBundle else {
            return CredentialEntry(
                service: service, account: account, type: type,
                metadata: metadata, password: nil,
                createdAt: Date(), modifiedAt: Date()
            )
        }

        // Biometric gate (write path)
        try await requireBiometric(reason: "Save credential for \(service)")

        var finalPassword = password
        var finalMetadata = metadata

        // Stripe tokenization for card type
        if type == .card {
            let tokenResult = try await tokenizeCard(
                number: password,
                expMonth: metadata.expMonth ?? 1,
                expYear: metadata.expYear ?? 2030,
                brand: metadata.brand
            )
            finalPassword = tokenResult.pmToken
            finalMetadata.stripePm = tokenResult.pmToken
            finalMetadata.last4 = tokenResult.last4
            finalMetadata.brand = tokenResult.brand
        }

        // Encode metadata to JSON
        let metadataJSON: String
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(finalMetadata)
            metadataJSON = String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            throw CredentialError.encodingError(error.localizedDescription)
        }

        // Delete existing item first (SecItemAdd fails on duplicate)
        deleteInternal(service: service, account: account)

        guard let passwordData = finalPassword.data(using: .utf8) else {
            throw CredentialError.encodingError("Failed to encode password as UTF-8")
        }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: passwordData,
            kSecAttrLabel as String: type.rawValue,
            kSecAttrComment as String: metadataJSON,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        if syncToiCloud {
            query[kSecAttrSynchronizable as String] = kCFBooleanTrue
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        }

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            print("[CredentialManager] ⚠️ Save failed for '\(service)/\(account)': OSStatus \(status)")
            throw CredentialError.keychainError(status)
        }

        return CredentialEntry(
            service: service, account: account, type: type,
            metadata: finalMetadata, password: nil,
            createdAt: Date(), modifiedAt: Date()
        )
    }

    /// Read a credential by service+account.
    /// No biometric — SecurityGate `.request` tier is sufficient.
    public func read(service: String, account: String) throws -> CredentialEntry {
        guard isAppBundle else { throw CredentialError.notFound }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let item = result as? [String: Any] else {
            if status == errSecItemNotFound { throw CredentialError.notFound }
            throw CredentialError.keychainError(status)
        }

        return try parseKeychainItem(item, includePassword: true)
    }

    /// List credentials, optionally filtered by type.
    /// Returns metadata only — no passwords or tokens exposed.
    public func list(type: CredentialType? = nil) throws -> [CredentialEntry] {
        guard isAppBundle else { return [] }

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        // Filter by type via kSecAttrLabel if specified
        if let type = type {
            query[kSecAttrLabel as String] = type.rawValue
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            if status == errSecItemNotFound { return [] }
            throw CredentialError.keychainError(status)
        }

        // Filter to items with a valid CredentialType label.
        // Excludes KeychainManager items which don't set kSecAttrLabel
        // to a CredentialType value.
        return items.compactMap { item in
            try? parseKeychainItem(item, includePassword: false)
        }
    }

    /// Delete a credential. Invokes biometric gate before deleting.
    public func deleteCredential(
        service: String,
        account: String
    ) async throws -> Bool {
        guard isAppBundle else { return true }

        // Biometric gate (write path)
        try await requireBiometric(reason: "Delete credential for \(service)")

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound {
            throw CredentialError.notFound
        }
        guard status == errSecSuccess else {
            throw CredentialError.keychainError(status)
        }
        return true
    }

    // MARK: - Private: Internal Delete (no biometric, for save overwrites)

    @discardableResult
    private func deleteInternal(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Private: Parse Keychain Item

    private func parseKeychainItem(
        _ item: [String: Any],
        includePassword: Bool
    ) throws -> CredentialEntry {
        guard let service = item[kSecAttrService as String] as? String,
              let account = item[kSecAttrAccount as String] as? String else {
            throw CredentialError.encodingError("Missing service or account in keychain item")
        }

        // Parse type from kSecAttrLabel
        let typeRaw = item[kSecAttrLabel as String] as? String ?? ""
        guard let credType = CredentialType(rawValue: typeRaw) else {
            throw CredentialError.invalidType(typeRaw)
        }

        // Parse metadata from kSecAttrComment
        let commentJSON = item[kSecAttrComment as String] as? String ?? "{}"
        let metadata: CredentialMetadata
        if let data = commentJSON.data(using: .utf8) {
            metadata = (try? JSONDecoder().decode(CredentialMetadata.self, from: data)) ?? .empty
        } else {
            metadata = .empty
        }

        // Password (only for read, not list)
        var password: String? = nil
        if includePassword, let data = item[kSecValueData as String] as? Data {
            password = String(data: data, encoding: .utf8)
        }

        let createdAt = item[kSecAttrCreationDate as String] as? Date
        let modifiedAt = item[kSecAttrModificationDate as String] as? Date

        return CredentialEntry(
            service: service, account: account, type: credType,
            metadata: metadata, password: password,
            createdAt: createdAt, modifiedAt: modifiedAt
        )
    }

    // MARK: - Stripe Tokenization

    private struct StripeTokenResult {
        let pmToken: String
        let last4: String
        let brand: String
    }

    /// Tokenize card via Stripe POST /v1/payment_methods.
    /// Raw card number never persists — only the pm_ token is stored.
    private func tokenizeCard(
        number: String,
        expMonth: Int,
        expYear: Int,
        brand: String?
    ) async throws -> StripeTokenResult {
        guard let apiKey = KeychainManager.shared.read(key: "STRIPE_API_KEY") else {
            throw CredentialError.stripeKeyMissing
        }

        let url = URL(string: "https://api.stripe.com/v1/payment_methods")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let cleanNumber = number
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")

        let body = [
            "type=card",
            "card[number]=\(cleanNumber)",
            "card[exp_month]=\(expMonth)",
            "card[exp_year]=\(expYear)"
        ].joined(separator: "&")

        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CredentialError.stripeTokenizationFailed("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw CredentialError.stripeTokenizationFailed(
                "HTTP \(httpResponse.statusCode): \(errorBody)"
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pmId = json["id"] as? String else {
            throw CredentialError.stripeTokenizationFailed(
                "Missing payment method ID in response"
            )
        }

        // Extract card details from Stripe response
        let cardInfo = json["card"] as? [String: Any]
        let last4 = cardInfo?["last4"] as? String ?? String(cleanNumber.suffix(4))
        let detectedBrand = cardInfo?["brand"] as? String ?? brand ?? "unknown"

        return StripeTokenResult(
            pmToken: pmId,
            last4: last4,
            brand: detectedBrand
        )
    }
}
