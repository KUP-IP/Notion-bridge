// CalendarRegistryTransactionStore.swift — transactional registry-first recovery ledger

import CryptoKit
import Foundation
import SQLite3

private let calendarRegistrySQLiteTransient = unsafeBitCast(
    OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self
)

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
    public var calendarId: String
    public var location: String?
    public var notes: String?
    public var eventClass: String
    public var meetingType: String?
    public var primaryBlockId: String
    public var blockIds: [String]
    public var projectIds: [String]
    public var contactIds: [String]

    public var canonicalized: CalendarRegistryOperationManifest {
        var copy = self
        copy.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.calendarId = calendarId.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.timeZoneIdentifier = timeZoneIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.location = location?.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.meetingType = meetingType?.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.primaryBlockId = primaryBlockId.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.blockIds = Array(Set(blockIds)).sorted()
        copy.projectIds = Array(Set(projectIds)).sorted()
        copy.contactIds = Array(Set(contactIds)).sorted()
        return copy
    }

    public var fingerprint: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(canonicalized) else { return "" }
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
    case corruptLedger(String)
    case storageFailure(String)
    case missingTransaction(String)

    public var errorDescription: String? {
        switch self {
        case .idempotencyConflict(let key):
            return "idempotency key already belongs to a different manifest: \(key)"
        case .corruptLedger(let reason):
            return "calendar-registry transaction ledger is corrupt: \(reason)"
        case .storageFailure(let reason):
            return "calendar-registry transaction ledger failed: \(reason)"
        case .missingTransaction(let key):
            return "calendar-registry transaction is missing: \(key)"
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

/// SQLite-backed recovery ledger. SQLite's unique key and `BEGIN IMMEDIATE`
/// transaction are the correctness boundary across actors and processes. The
/// process-local operation gate is only a latency optimization.
public actor SQLiteCalendarRegistryTransactionStore: CalendarRegistryTransactionStoring {
    public static let schemaVersion = 1

    private let url: URL
    nonisolated(unsafe) private var db: OpaquePointer?

    public init(url: URL) throws {
        self.url = url
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 rc=\(rc)"
            if let handle { sqlite3_close_v2(handle) }
            throw CalendarRegistryTransactionStoreError.storageFailure(message)
        }
        self.db = handle
        sqlite3_busy_timeout(handle, 5_000)
        do {
            try Self.bootstrap(handle)
        } catch {
            sqlite3_close_v2(handle)
            self.db = nil
            throw error
        }
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    private static func bootstrap(_ db: OpaquePointer) throws {
        func exec(_ sql: String) throws {
            var error: UnsafeMutablePointer<Int8>?
            let rc = sqlite3_exec(db, sql, nil, nil, &error)
            guard rc == SQLITE_OK else {
                let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
                if let error { sqlite3_free(error) }
                throw CalendarRegistryTransactionStoreError.storageFailure(message)
            }
        }
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=FULL;")
        try exec("PRAGMA foreign_keys=ON;")
        try exec("CREATE TABLE IF NOT EXISTS calendar_registry_schema (version INTEGER NOT NULL);")
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT version FROM calendar_registry_schema LIMIT 1;", -1, &stmt, nil) == SQLITE_OK else {
            throw CalendarRegistryTransactionStoreError.storageFailure(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE {
            try exec("INSERT INTO calendar_registry_schema(version) VALUES (\(Self.schemaVersion));")
        } else if rc == SQLITE_ROW {
            let version = Int(sqlite3_column_int64(stmt, 0))
            guard version == Self.schemaVersion else {
                throw CalendarRegistryTransactionStoreError.corruptLedger(
                    "unsupported schema version \(version); expected \(Self.schemaVersion)"
                )
            }
        } else {
            throw CalendarRegistryTransactionStoreError.storageFailure(String(cString: sqlite3_errmsg(db)))
        }
        try exec("""
        CREATE TABLE IF NOT EXISTS calendar_registry_transactions (
            idempotency_key TEXT PRIMARY KEY NOT NULL,
            operation_id TEXT NOT NULL,
            manifest_fingerprint TEXT NOT NULL,
            stage TEXT NOT NULL,
            registry_event_id TEXT,
            calendar_event_id TEXT,
            calendar_id TEXT,
            provider_external_id TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            last_verified_at TEXT,
            last_error TEXT,
            partial_effects_json TEXT NOT NULL
        );
        """)
    }

    public func claim(
        idempotencyKey: String,
        manifestFingerprint: String,
        operationId: String,
        now: Date
    ) throws -> CalendarRegistryTransaction {
        try beginImmediate()
        do {
            if let existing = try select(idempotencyKey: idempotencyKey) {
                guard existing.manifestFingerprint == manifestFingerprint else {
                    try rollback()
                    throw CalendarRegistryTransactionStoreError.idempotencyConflict(idempotencyKey)
                }
                try commit()
                return existing
            }
            let transaction = CalendarRegistryTransaction(
                operationId: operationId,
                idempotencyKey: idempotencyKey,
                manifestFingerprint: manifestFingerprint,
                createdAt: now,
                updatedAt: now
            )
            try insert(transaction)
            try commit()
            return transaction
        } catch {
            try? rollback()
            throw error
        }
    }

    public func get(idempotencyKey: String) throws -> CalendarRegistryTransaction? {
        try select(idempotencyKey: idempotencyKey)
    }

    public func save(_ transaction: CalendarRegistryTransaction) throws {
        try beginImmediate()
        do {
            guard let existing = try select(idempotencyKey: transaction.idempotencyKey) else {
                throw CalendarRegistryTransactionStoreError.missingTransaction(transaction.idempotencyKey)
            }
            guard existing.manifestFingerprint == transaction.manifestFingerprint else {
                throw CalendarRegistryTransactionStoreError.idempotencyConflict(transaction.idempotencyKey)
            }
            try update(transaction)
            try commit()
        } catch {
            try? rollback()
            throw error
        }
    }

    private func migrate() throws {
        try execute("CREATE TABLE IF NOT EXISTS calendar_registry_schema (version INTEGER NOT NULL);")
        let version = try scalarInt("SELECT version FROM calendar_registry_schema LIMIT 1;")
        if version == nil {
            try execute("INSERT INTO calendar_registry_schema(version) VALUES (\(Self.schemaVersion));")
        } else if version != Self.schemaVersion {
            throw CalendarRegistryTransactionStoreError.corruptLedger(
                "unsupported schema version \(version ?? -1); expected \(Self.schemaVersion)"
            )
        }
        try execute("""
        CREATE TABLE IF NOT EXISTS calendar_registry_transactions (
            idempotency_key TEXT PRIMARY KEY NOT NULL,
            operation_id TEXT NOT NULL,
            manifest_fingerprint TEXT NOT NULL,
            stage TEXT NOT NULL,
            registry_event_id TEXT,
            calendar_event_id TEXT,
            calendar_id TEXT,
            provider_external_id TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            last_verified_at TEXT,
            last_error TEXT,
            partial_effects_json TEXT NOT NULL
        );
        """)
    }

    private func insert(_ transaction: CalendarRegistryTransaction) throws {
        let sql = """
        INSERT INTO calendar_registry_transactions (
            idempotency_key, operation_id, manifest_fingerprint, stage,
            registry_event_id, calendar_event_id, calendar_id, provider_external_id,
            created_at, updated_at, last_verified_at, last_error, partial_effects_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        try withStatement(sql) { stmt in try bind(transaction, to: stmt); try stepDone(stmt) }
    }

    private func update(_ transaction: CalendarRegistryTransaction) throws {
        let sql = """
        UPDATE calendar_registry_transactions SET
            operation_id=?, manifest_fingerprint=?, stage=?, registry_event_id=?,
            calendar_event_id=?, calendar_id=?, provider_external_id=?, created_at=?,
            updated_at=?, last_verified_at=?, last_error=?, partial_effects_json=?
        WHERE idempotency_key=?;
        """
        try withStatement(sql) { stmt in
            try bindText(stmt, 1, transaction.operationId)
            try bindText(stmt, 2, transaction.manifestFingerprint)
            try bindText(stmt, 3, transaction.stage.rawValue)
            try bindOptionalText(stmt, 4, transaction.registryEventId)
            try bindOptionalText(stmt, 5, transaction.calendarEventId)
            try bindOptionalText(stmt, 6, transaction.calendarId)
            try bindOptionalText(stmt, 7, transaction.providerExternalId)
            try bindText(stmt, 8, CalendarRegistryISO.string(transaction.createdAt))
            try bindText(stmt, 9, CalendarRegistryISO.string(transaction.updatedAt))
            try bindOptionalText(stmt, 10, transaction.lastVerifiedAt.map(CalendarRegistryISO.string))
            try bindOptionalText(stmt, 11, transaction.lastError)
            try bindText(stmt, 12, try partialEffectsJSON(transaction.partialEffects))
            try bindText(stmt, 13, transaction.idempotencyKey)
            try stepDone(stmt)
        }
    }

    private func bind(_ transaction: CalendarRegistryTransaction, to stmt: OpaquePointer?) throws {
        try bindText(stmt, 1, transaction.idempotencyKey)
        try bindText(stmt, 2, transaction.operationId)
        try bindText(stmt, 3, transaction.manifestFingerprint)
        try bindText(stmt, 4, transaction.stage.rawValue)
        try bindOptionalText(stmt, 5, transaction.registryEventId)
        try bindOptionalText(stmt, 6, transaction.calendarEventId)
        try bindOptionalText(stmt, 7, transaction.calendarId)
        try bindOptionalText(stmt, 8, transaction.providerExternalId)
        try bindText(stmt, 9, CalendarRegistryISO.string(transaction.createdAt))
        try bindText(stmt, 10, CalendarRegistryISO.string(transaction.updatedAt))
        try bindOptionalText(stmt, 11, transaction.lastVerifiedAt.map(CalendarRegistryISO.string))
        try bindOptionalText(stmt, 12, transaction.lastError)
        try bindText(stmt, 13, try partialEffectsJSON(transaction.partialEffects))
    }

    private func select(idempotencyKey: String) throws -> CalendarRegistryTransaction? {
        let sql = """
        SELECT operation_id, idempotency_key, manifest_fingerprint, stage,
               registry_event_id, calendar_event_id, calendar_id, provider_external_id,
               created_at, updated_at, last_verified_at, last_error, partial_effects_json
        FROM calendar_registry_transactions WHERE idempotency_key=? LIMIT 1;
        """
        return try withStatement(sql) { stmt in
            try bindText(stmt, 1, idempotencyKey)
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return nil }
            guard rc == SQLITE_ROW else { throw sqliteError("select", rc: rc) }
            guard
                let stage = CalendarRegistryTransactionStage(rawValue: text(stmt, 3) ?? ""),
                let createdAt = text(stmt, 8).flatMap(CalendarRegistryISO.date),
                let updatedAt = text(stmt, 9).flatMap(CalendarRegistryISO.date)
            else {
                throw CalendarRegistryTransactionStoreError.corruptLedger(
                    "invalid transaction row for \(idempotencyKey)"
                )
            }
            let effectsData = Data((text(stmt, 12) ?? "[]").utf8)
            let effects = (try? JSONDecoder().decode([String].self, from: effectsData)) ?? []
            return CalendarRegistryTransaction(
                operationId: text(stmt, 0) ?? "",
                idempotencyKey: text(stmt, 1) ?? idempotencyKey,
                manifestFingerprint: text(stmt, 2) ?? "",
                stage: stage,
                registryEventId: text(stmt, 4),
                calendarEventId: text(stmt, 5),
                calendarId: text(stmt, 6),
                providerExternalId: text(stmt, 7),
                createdAt: createdAt,
                updatedAt: updatedAt,
                lastVerifiedAt: text(stmt, 10).flatMap(CalendarRegistryISO.date),
                lastError: text(stmt, 11),
                partialEffects: effects
            )
        }
    }

    private func partialEffectsJSON(_ effects: [String]) throws -> String {
        String(decoding: try JSONEncoder().encode(effects), as: UTF8.self)
    }

    private func beginImmediate() throws { try execute("BEGIN IMMEDIATE;") }
    private func commit() throws { try execute("COMMIT;") }
    private func rollback() throws { try execute("ROLLBACK;") }

    private func execute(_ sql: String) throws {
        guard let db else { throw CalendarRegistryTransactionStoreError.storageFailure("database is closed") }
        var error: UnsafeMutablePointer<Int8>?
        let rc = sqlite3_exec(db, sql, nil, nil, &error)
        guard rc == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            if let error { sqlite3_free(error) }
            throw CalendarRegistryTransactionStoreError.storageFailure(message)
        }
    }

    private func scalarInt(_ sql: String) throws -> Int? {
        try withStatement(sql) { stmt in
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return nil }
            guard rc == SQLITE_ROW else { throw sqliteError("scalar", rc: rc) }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer?) throws -> T) throws -> T {
        guard let db else { throw CalendarRegistryTransactionStoreError.storageFailure("database is closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK else { throw sqliteError("prepare", rc: rc) }
        defer { sqlite3_finalize(stmt) }
        return try body(stmt)
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) throws {
        let rc = sqlite3_bind_text(stmt, index, value, -1, calendarRegistrySQLiteTransient)
        guard rc == SQLITE_OK else { throw sqliteError("bind text", rc: rc) }
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) throws {
        if let value { try bindText(stmt, index, value) }
        else {
            let rc = sqlite3_bind_null(stmt, index)
            guard rc == SQLITE_OK else { throw sqliteError("bind null", rc: rc) }
        }
    }

    private func stepDone(_ stmt: OpaquePointer?) throws {
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else { throw sqliteError("step", rc: rc) }
    }

    private func text(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let raw = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: raw)
    }

    private func sqliteError(_ operation: String, rc: Int32) -> CalendarRegistryTransactionStoreError {
        let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite rc=\(rc)"
        return .storageFailure("\(operation): \(message)")
    }
}

public actor InMemoryCalendarRegistryTransactionStore: CalendarRegistryTransactionStoring {
    private var transactions: [String: CalendarRegistryTransaction] = [:]
    private var failNextSaveMessage: String?

    public init() {}

    public func setFailNextSave(_ message: String?) { failNextSaveMessage = message }

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

    public func save(_ transaction: CalendarRegistryTransaction) throws {
        if let message = failNextSaveMessage {
            failNextSaveMessage = nil
            throw CalendarRegistryTransactionStoreError.storageFailure(message)
        }
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
