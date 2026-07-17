// CalendarRegistryTransactionStore.swift — durable registry-first operation journal

import CryptoKit
import Foundation

public enum CalendarRegistryTransactionStage: String, Codable, Sendable, CaseIterable {
    case prepared
    case registryCreated
    case calendarCreated
    case pairPersisted
    case verified
    case synced
    case recoverableError
    case conflict
    case abandoned
}

public struct CalendarRegistryOperationManifest: Codable, Sendable, Equatable {
    public var title: String
    public var start: Date
    public var end: Date
    public var timeZoneIdentifier: String
    public var calendarId: String?
    public var location: String?
    public var notes: String?
    public var eventClass: String
    public var primaryBlockId: String
    public var blockIds: [String]
    public var projectIds: [String]
    public var contactIds: [String]

    public var fingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "" }
        return CalendarRegistryDigest.sha256(data)
    }
}

public struct CalendarRegistryTransaction: Codable, Sendable, Equatable {
    public var operationId: String
    public var idempotencyKey: String
    public var manifestFingerprint: String
    public var stage: CalendarRegistryTransactionStage
    public var registryEventId: String?
    public var calendarEventId: String?
    public var calendarId: String?
    public var providerExternalId: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var lastVerifiedAt: Date?
    public var lastError: String?
    public var partialEffects: [String]

    public init(
        operationId: String,
        idempotencyKey: String,
        manifestFingerprint: String,
        stage: CalendarRegistryTransactionStage = .prepared,
        registryEventId: String? = nil,
        calendarEventId: String? = nil,
        calendarId: String? = nil,
        providerExternalId: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        lastVerifiedAt: Date? = nil,
        lastError: String? = nil,
        partialEffects: [String] = []
    ) {
        self.operationId = operationId
        self.idempotencyKey = idempotencyKey
        self.manifestFingerprint = manifestFingerprint
        self.stage = stage
        self.registryEventId = registryEventId
        self.calendarEventId = calendarEventId
        self.calendarId = calendarId
        self.providerExternalId = providerExternalId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastVerifiedAt = lastVerifiedAt
        self.lastError = lastError
        self.partialEffects = partialEffects
    }
}

public enum CalendarRegistryTransactionStoreError: Error, LocalizedError, Equatable {
    case idempotencyConflict(String)
    case corruptJournal(String)

    public var errorDescription: String? {
        switch self {
        case .idempotencyConflict(let key):
            return "idempotency key already belongs to a different manifest: \(key)"
        case .corruptJournal(let reason):
            return "calendar-registry transaction journal is corrupt: \(reason)"
        }
    }
}

public protocol CalendarRegistryTransactionStoring: Sendable {
    func claim(
        idempotencyKey: String,
        manifestFingerprint: String,
        operationId: String,
        now: Date
    ) async throws -> CalendarRegistryTransaction
    func get(idempotencyKey: String) async throws -> CalendarRegistryTransaction?
    func save(_ transaction: CalendarRegistryTransaction) async throws
}

public actor JSONCalendarRegistryTransactionStore: CalendarRegistryTransactionStoring {
    private let url: URL
    private var transactions: [String: CalendarRegistryTransaction]

    public init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                self.transactions = try JSONDecoder().decode(
                    [String: CalendarRegistryTransaction].self, from: data
                )
            } catch {
                throw CalendarRegistryTransactionStoreError.corruptJournal(error.localizedDescription)
            }
        } else {
            self.transactions = [:]
        }
    }

    public func claim(
        idempotencyKey: String,
        manifestFingerprint: String,
        operationId: String,
        now: Date
    ) throws -> CalendarRegistryTransaction {
        if let existing = transactions[idempotencyKey] {
            guard existing.manifestFingerprint == manifestFingerprint else {
                throw CalendarRegistryTransactionStoreError.idempotencyConflict(idempotencyKey)
            }
            return existing
        }
        let transaction = CalendarRegistryTransaction(
            operationId: operationId,
            idempotencyKey: idempotencyKey,
            manifestFingerprint: manifestFingerprint,
            createdAt: now,
            updatedAt: now
        )
        transactions[idempotencyKey] = transaction
        try persist()
        return transaction
    }

    public func get(idempotencyKey: String) -> CalendarRegistryTransaction? {
        transactions[idempotencyKey]
    }

    public func save(_ transaction: CalendarRegistryTransaction) throws {
        transactions[transaction.idempotencyKey] = transaction
        try persist()
    }

    private func persist() throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(transactions)
        try data.write(to: url, options: .atomic)
    }
}

public actor InMemoryCalendarRegistryTransactionStore: CalendarRegistryTransactionStoring {
    private var transactions: [String: CalendarRegistryTransaction] = [:]

    public init() {}

    public func claim(
        idempotencyKey: String,
        manifestFingerprint: String,
        operationId: String,
        now: Date
    ) throws -> CalendarRegistryTransaction {
        if let existing = transactions[idempotencyKey] {
            guard existing.manifestFingerprint == manifestFingerprint else {
                throw CalendarRegistryTransactionStoreError.idempotencyConflict(idempotencyKey)
            }
            return existing
        }
        let transaction = CalendarRegistryTransaction(
            operationId: operationId,
            idempotencyKey: idempotencyKey,
            manifestFingerprint: manifestFingerprint,
            createdAt: now,
            updatedAt: now
        )
        transactions[idempotencyKey] = transaction
        return transaction
    }

    public func get(idempotencyKey: String) -> CalendarRegistryTransaction? {
        transactions[idempotencyKey]
    }

    public func save(_ transaction: CalendarRegistryTransaction) {
        transactions[transaction.idempotencyKey] = transaction
    }
}


public enum CalendarRegistryDigest {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(_ value: String) -> String {
        sha256(Data(value.utf8))
    }
}

public enum CalendarRegistryISO {
    public static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}


public actor CalendarRegistryOperationGate {
    public static let shared = CalendarRegistryOperationGate()

    private var locked: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    public init() {}

    public func acquire(_ key: String) async {
        if !locked.contains(key) {
            locked.insert(key)
            return
        }
        await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
        }
    }

    public func release(_ key: String) {
        guard var queued = waiters[key], !queued.isEmpty else {
            locked.remove(key)
            waiters[key] = nil
            return
        }
        let next = queued.removeFirst()
        waiters[key] = queued.isEmpty ? nil : queued
        next.resume()
    }
}
