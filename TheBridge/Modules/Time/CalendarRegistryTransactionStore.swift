// CalendarRegistryTransactionStore.swift — fenced registry-first transaction ledger

import CryptoKit
import Foundation
import SQLite3

private let calendarRegistrySQLiteTransient = unsafeBitCast(
    OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self
)

public enum CalendarRegistryTransactionStage: String, Codable, Sendable, CaseIterable {
    case prepared
    case registryVerified
    case calendarCreateIntent
    case calendarEffectUnknown
    case calendarCreated
    case pairPersisted
    case verified
    case synced
    case recoverableError
    case conflict
    case abandoned

    fileprivate var progressRank: Int? {
        switch self {
        case .prepared: return 0
        case .registryVerified: return 1
        case .calendarCreateIntent: return 2
        case .calendarCreated: return 3
        case .pairPersisted: return 4
        case .verified: return 5
        case .synced: return 6
        case .calendarEffectUnknown, .recoverableError, .conflict, .abandoned: return nil
        }
    }

    fileprivate func permitsTransition(to next: Self) -> Bool {
        if self == next { return true }
        if next == .conflict || next == .abandoned { return true }
        switch self {
        case .conflict, .abandoned:
            return false
        case .calendarCreateIntent:
            return next == .calendarEffectUnknown || next == .calendarCreated
                || next == .recoverableError || next == .conflict || next == .abandoned
        case .calendarEffectUnknown:
            return next == .calendarCreated || next == .conflict || next == .abandoned
        case .recoverableError:
            return next == .registryVerified || next == .conflict || next == .abandoned
        default:
            if next == .recoverableError { return true }
            guard let current = progressRank, let target = next.progressRank else { return false }
            return target >= current
        }
    }
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

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    public var canonicalized: CalendarRegistryOperationManifest {
        var copy = self
        copy.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.calendarId = calendarId.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.timeZoneIdentifier = timeZoneIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.location = Self.normalizedOptional(location)
        copy.notes = Self.normalizedOptional(notes)
        copy.eventClass = eventClass.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.meetingType = Self.normalizedOptional(meetingType)
        copy.primaryBlockId = primaryBlockId.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.blockIds = Array(Set(blockIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } + [copy.primaryBlockId].filter { !$0.isEmpty })).sorted()
        copy.projectIds = Array(Set(projectIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })).sorted()
        copy.contactIds = Array(Set(contactIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })).sorted()
        return copy
    }

    public var fingerprint: String {
        let value = canonicalized
        func field(_ raw: String) -> String { "\(raw.utf8.count):\(raw)" }
        func optional(_ raw: String?) -> String { raw.map { "1:" + field($0) } ?? "0:" }
        func list(_ values: [String]) -> String { values.map(field).joined(separator: "|") }
        let canonical = [
            field(value.title),
            field(CalendarRegistryISO.string(value.start)),
            field(CalendarRegistryISO.string(value.end)),
            field(value.timeZoneIdentifier),
            field(value.calendarId),
            optional(value.location),
            optional(value.notes),
            field(value.eventClass),
            optional(value.meetingType),
            field(value.primaryBlockId),
            list(value.blockIds),
            list(value.projectIds),
            list(value.contactIds)
        ].joined(separator: "\u{1F}")
        return CalendarRegistryDigest.sha256(canonical)
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
    public var revision: Int
    public var leaseOwner: String?
    public var leaseToken: String?
    public var leaseExpiresAt: Date?
    public var heartbeatAt: Date?

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
        partialEffects: [String] = [],
        revision: Int = 0,
        leaseOwner: String? = nil,
        leaseToken: String? = nil,
        leaseExpiresAt: Date? = nil,
        heartbeatAt: Date? = nil
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
        self.revision = revision
        self.leaseOwner = leaseOwner
        self.leaseToken = leaseToken
        self.leaseExpiresAt = leaseExpiresAt
        self.heartbeatAt = heartbeatAt
    }
}

public enum CalendarRegistryTransactionStoreError: Error, LocalizedError, Equatable {
    case idempotencyConflict(String)
    case operationActive(String, Date)
    case staleRevision(String)
    case leaseLost(String)
    case stageRegression(String)
    case identityRegression(String)
    case corruptLedger(String)
    case storageFailure(String)
    case missingTransaction(String)

    public var errorDescription: String? {
        switch self {
        case .idempotencyConflict(let key): return "idempotency key already belongs to a different manifest: \(key)"
        case .operationActive(let key, let until): return "calendar-registry operation is already active for \(key) until \(CalendarRegistryISO.string(until))"
        case .staleRevision(let key): return "calendar-registry transaction revision is stale: \(key)"
        case .leaseLost(let key): return "calendar-registry transaction lease is absent, expired, or fenced: \(key)"
        case .stageRegression(let reason): return "calendar-registry stage regression refused: \(reason)"
        case .identityRegression(let reason): return "calendar-registry identity regression refused: \(reason)"
        case .corruptLedger(let reason): return "calendar-registry transaction ledger is corrupt: \(reason)"
        case .storageFailure(let reason): return "calendar-registry transaction ledger failed: \(reason)"
        case .missingTransaction(let key): return "calendar-registry transaction is missing: \(key)"
        }
    }
}

public protocol CalendarRegistryTransactionStoring: Sendable {
    func claim(
        idempotencyKey: String,
        manifestFingerprint: String,
        operationId: String,
        leaseOwner: String,
        leaseToken: String,
        leaseDuration: TimeInterval,
        exclusiveProcessLockHeld: Bool
    ) async throws -> CalendarRegistryTransaction
    func renew(_ transaction: CalendarRegistryTransaction, leaseDuration: TimeInterval) async throws -> CalendarRegistryTransaction
    func get(idempotencyKey: String) async throws -> CalendarRegistryTransaction?
    func save(_ transaction: CalendarRegistryTransaction) async throws -> CalendarRegistryTransaction
    func release(_ transaction: CalendarRegistryTransaction) async throws -> CalendarRegistryTransaction
}

/// SQLite-backed single-machine recovery ledger. The unique key, lease metadata,
/// monotonic revision, and compare-and-swap saves preserve transaction evidence.
/// Cross-process external-effect exclusion is provided by the separate OS advisory
/// lock; callers may override a stale SQLite lease only while holding that lock.
public actor SQLiteCalendarRegistryTransactionStore: CalendarRegistryTransactionStoring {
    public static let schemaVersion = 3

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
        sqlite3_busy_timeout(handle, 10_000)
        do { try Self.bootstrap(handle) }
        catch {
            sqlite3_close_v2(handle)
            self.db = nil
            throw error
        }
    }

    deinit {
        if let db {
            let rc = sqlite3_close_v2(db)
            assert(rc == SQLITE_OK, "SQLite close failed with rc=\(rc)")
        }
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
        func columns(_ table: String) throws -> Set<String> {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK else {
                throw CalendarRegistryTransactionStoreError.storageFailure(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }
            var result: Set<String> = []
            while sqlite3_step(statement) == SQLITE_ROW, let raw = sqlite3_column_text(statement, 1) {
                result.insert(String(cString: raw))
            }
            return result
        }

        func scalarInt(_ sql: String) throws -> Int? {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw CalendarRegistryTransactionStoreError.storageFailure(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { return nil }
            guard rc == SQLITE_ROW else {
                throw CalendarRegistryTransactionStoreError.storageFailure(String(cString: sqlite3_errmsg(db)))
            }
            return Int(sqlite3_column_int64(statement, 0))
        }

        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=FULL;")
        try exec("PRAGMA foreign_keys=ON;")
        try exec("BEGIN IMMEDIATE;")
        do {
            try exec("CREATE TABLE IF NOT EXISTS calendar_registry_schema (version INTEGER NOT NULL);")
            let schemaRows = try scalarInt("SELECT COUNT(*) FROM calendar_registry_schema;") ?? 0
            guard schemaRows <= 1 else {
                throw CalendarRegistryTransactionStoreError.corruptLedger("schema metadata contains multiple rows")
            }
            if schemaRows == 1 {
                let existingVersion = try scalarInt("SELECT version FROM calendar_registry_schema LIMIT 1;") ?? -1
                guard (1...Self.schemaVersion).contains(existingVersion) else {
                    throw CalendarRegistryTransactionStoreError.corruptLedger(
                        "unsupported schema version \(existingVersion); expected 1...\(Self.schemaVersion)"
                    )
                }
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
                partial_effects_json TEXT NOT NULL,
                revision INTEGER NOT NULL DEFAULT 1,
                lease_owner TEXT,
                lease_token TEXT,
                lease_expires_at REAL,
                heartbeat_at REAL
            );
            """)
            let existingColumns = try columns("calendar_registry_transactions")
            let additions: [(String, String)] = [
                ("revision", "INTEGER NOT NULL DEFAULT 1"),
                ("lease_owner", "TEXT"),
                ("lease_token", "TEXT"),
                ("lease_expires_at", "REAL"),
                ("heartbeat_at", "REAL")
            ]
            for (name, definition) in additions where !existingColumns.contains(name) {
                try exec("ALTER TABLE calendar_registry_transactions ADD COLUMN \(name) \(definition);")
            }
            try exec("UPDATE calendar_registry_transactions SET revision=1 WHERE revision IS NULL OR revision < 1;")
            try exec("UPDATE calendar_registry_transactions SET stage='registryVerified' WHERE stage='registryCreated';")

            try exec("DROP TABLE IF EXISTS calendar_registry_schema_new;")
            try exec("CREATE TABLE calendar_registry_schema_new (id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL);")
            try exec("INSERT INTO calendar_registry_schema_new(id, version) VALUES (1, \(Self.schemaVersion));")
            try exec("DROP TABLE IF EXISTS calendar_registry_schema;")
            try exec("ALTER TABLE calendar_registry_schema_new RENAME TO calendar_registry_schema;")
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    public func claim(
        idempotencyKey: String,
        manifestFingerprint: String,
        operationId: String,
        leaseOwner: String,
        leaseToken: String,
        leaseDuration: TimeInterval,
        exclusiveProcessLockHeld: Bool
    ) throws -> CalendarRegistryTransaction {
        try validateIdentity(idempotencyKey, manifestFingerprint, operationId, leaseOwner, leaseToken)
        guard leaseDuration > 0 else { throw CalendarRegistryTransactionStoreError.storageFailure("lease duration must be positive") }
        try beginImmediate()
        do {
            let now = try currentEpoch()
            if let existing = try select(idempotencyKey: idempotencyKey) {
                guard existing.manifestFingerprint == manifestFingerprint else {
                    throw CalendarRegistryTransactionStoreError.idempotencyConflict(idempotencyKey)
                }
                if !exclusiveProcessLockHeld,
                   let expiry = existing.leaseExpiresAt?.timeIntervalSince1970,
                   existing.leaseToken?.isEmpty == false,
                   expiry > now {
                    throw CalendarRegistryTransactionStoreError.operationActive(
                        idempotencyKey, Date(timeIntervalSince1970: expiry)
                    )
                }
                let sql = """
                UPDATE calendar_registry_transactions SET
                    operation_id=?, lease_owner=?, lease_token=?, lease_expires_at=?, heartbeat_at=?,
                    updated_at=?, revision=revision+1
                WHERE idempotency_key=? AND revision=?;
                """
                try withStatement(sql) { stmt in
                    try bindText(stmt, 1, operationId)
                    try bindText(stmt, 2, leaseOwner)
                    try bindText(stmt, 3, leaseToken)
                    try bindDouble(stmt, 4, now + leaseDuration)
                    try bindDouble(stmt, 5, now)
                    try bindText(stmt, 6, CalendarRegistryISO.string(Date(timeIntervalSince1970: now)))
                    try bindText(stmt, 7, idempotencyKey)
                    try bindInt(stmt, 8, existing.revision)
                    try stepDone(stmt)
                }
                guard sqlite3_changes(db) == 1 else { throw CalendarRegistryTransactionStoreError.staleRevision(idempotencyKey) }
                try commit()
                return try requiredSelect(idempotencyKey)
            }

            let nowDate = Date(timeIntervalSince1970: now)
            let transaction = CalendarRegistryTransaction(
                operationId: operationId,
                idempotencyKey: idempotencyKey,
                manifestFingerprint: manifestFingerprint,
                createdAt: nowDate,
                updatedAt: nowDate,
                revision: 1,
                leaseOwner: leaseOwner,
                leaseToken: leaseToken,
                leaseExpiresAt: Date(timeIntervalSince1970: now + leaseDuration),
                heartbeatAt: nowDate
            )
            try insert(transaction)
            try commit()
            return transaction
        } catch {
            try? rollback()
            throw error
        }
    }

    public func renew(_ transaction: CalendarRegistryTransaction, leaseDuration: TimeInterval) throws -> CalendarRegistryTransaction {
        guard leaseDuration > 0 else { throw CalendarRegistryTransactionStoreError.storageFailure("lease duration must be positive") }
        try beginImmediate()
        do {
            let now = try currentEpoch()
            let sql = """
            UPDATE calendar_registry_transactions SET
                lease_expires_at=?, heartbeat_at=?, updated_at=?, revision=revision+1
            WHERE idempotency_key=? AND revision=? AND lease_token=? AND lease_owner=?;
            """
            try withStatement(sql) { stmt in
                try bindDouble(stmt, 1, now + leaseDuration)
                try bindDouble(stmt, 2, now)
                try bindText(stmt, 3, CalendarRegistryISO.string(Date(timeIntervalSince1970: now)))
                try bindText(stmt, 4, transaction.idempotencyKey)
                try bindInt(stmt, 5, transaction.revision)
                try bindText(stmt, 6, transaction.leaseToken ?? "")
                try bindText(stmt, 7, transaction.leaseOwner ?? "")
                try stepDone(stmt)
            }
            guard sqlite3_changes(db) == 1 else { throw try ownershipError(for: transaction) }
            try commit()
            return try requiredSelect(transaction.idempotencyKey)
        } catch {
            try? rollback()
            throw error
        }
    }

    public func get(idempotencyKey: String) throws -> CalendarRegistryTransaction? {
        try select(idempotencyKey: idempotencyKey)
    }

    public func save(_ transaction: CalendarRegistryTransaction) throws -> CalendarRegistryTransaction {
        try beginImmediate()
        do {
            guard let existing = try select(idempotencyKey: transaction.idempotencyKey) else {
                throw CalendarRegistryTransactionStoreError.missingTransaction(transaction.idempotencyKey)
            }
            try validateMutation(from: existing, to: transaction)
            let now = try currentEpoch()
            let sql = """
            UPDATE calendar_registry_transactions SET
                operation_id=?, manifest_fingerprint=?, stage=?, registry_event_id=?,
                calendar_event_id=?, calendar_id=?, provider_external_id=?, created_at=?,
                updated_at=?, last_verified_at=?, last_error=?, partial_effects_json=?,
                heartbeat_at=?, revision=revision+1
            WHERE idempotency_key=? AND revision=? AND lease_token=? AND lease_owner=?;
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
                try bindText(stmt, 9, CalendarRegistryISO.string(Date(timeIntervalSince1970: now)))
                try bindOptionalText(stmt, 10, transaction.lastVerifiedAt.map(CalendarRegistryISO.string))
                try bindOptionalText(stmt, 11, transaction.lastError)
                try bindText(stmt, 12, try partialEffectsJSON(transaction.partialEffects))
                try bindDouble(stmt, 13, now)
                try bindText(stmt, 14, transaction.idempotencyKey)
                try bindInt(stmt, 15, transaction.revision)
                try bindText(stmt, 16, transaction.leaseToken ?? "")
                try bindText(stmt, 17, transaction.leaseOwner ?? "")
                try stepDone(stmt)
            }
            guard sqlite3_changes(db) == 1 else { throw try ownershipError(for: transaction) }
            try commit()
            return try requiredSelect(transaction.idempotencyKey)
        } catch {
            try? rollback()
            throw error
        }
    }

    public func release(_ transaction: CalendarRegistryTransaction) throws -> CalendarRegistryTransaction {
        try beginImmediate()
        do {
            let now = try currentEpoch()
            let sql = """
            UPDATE calendar_registry_transactions SET
                lease_owner=NULL, lease_token=NULL, lease_expires_at=NULL,
                heartbeat_at=?, updated_at=?, revision=revision+1
            WHERE idempotency_key=? AND revision=? AND lease_token=? AND lease_owner=?;
            """
            try withStatement(sql) { stmt in
                try bindDouble(stmt, 1, now)
                try bindText(stmt, 2, CalendarRegistryISO.string(Date(timeIntervalSince1970: now)))
                try bindText(stmt, 3, transaction.idempotencyKey)
                try bindInt(stmt, 4, transaction.revision)
                try bindText(stmt, 5, transaction.leaseToken ?? "")
                try bindText(stmt, 6, transaction.leaseOwner ?? "")
                try stepDone(stmt)
            }
            guard sqlite3_changes(db) == 1 else { throw try ownershipError(for: transaction, requireUnexpired: false) }
            try commit()
            return try requiredSelect(transaction.idempotencyKey)
        } catch {
            try? rollback()
            throw error
        }
    }

    private func validateIdentity(_ key: String, _ fingerprint: String, _ operation: String, _ owner: String, _ token: String) throws {
        let values = [("idempotency key", key), ("manifest fingerprint", fingerprint), ("operation id", operation), ("lease owner", owner), ("lease token", token)]
        if let invalid = values.first(where: { $0.1.isEmpty }) {
            throw CalendarRegistryTransactionStoreError.corruptLedger("\(invalid.0) must not be empty")
        }
    }

    private func validateMutation(from existing: CalendarRegistryTransaction, to incoming: CalendarRegistryTransaction) throws {
        guard existing.manifestFingerprint == incoming.manifestFingerprint else {
            throw CalendarRegistryTransactionStoreError.idempotencyConflict(incoming.idempotencyKey)
        }
        guard existing.revision == incoming.revision else {
            throw CalendarRegistryTransactionStoreError.staleRevision(incoming.idempotencyKey)
        }
        guard existing.leaseToken == incoming.leaseToken, existing.leaseOwner == incoming.leaseOwner,
              incoming.leaseToken?.isEmpty == false, incoming.leaseOwner?.isEmpty == false else {
            throw CalendarRegistryTransactionStoreError.leaseLost(incoming.idempotencyKey)
        }
        guard existing.stage.permitsTransition(to: incoming.stage) else {
            throw CalendarRegistryTransactionStoreError.stageRegression("\(existing.stage.rawValue) → \(incoming.stage.rawValue)")
        }
        for (name, old, new) in [
            ("registry event id", existing.registryEventId, incoming.registryEventId),
            ("calendar event id", existing.calendarEventId, incoming.calendarEventId),
            ("calendar id", existing.calendarId, incoming.calendarId),
            ("provider external id", existing.providerExternalId, incoming.providerExternalId)
        ] where old?.isEmpty == false && new != old {
            throw CalendarRegistryTransactionStoreError.identityRegression("\(name) is immutable once established")
        }
    }

    private func ownershipError(for transaction: CalendarRegistryTransaction, requireUnexpired _: Bool = true) throws -> CalendarRegistryTransactionStoreError {
        guard let current = try select(idempotencyKey: transaction.idempotencyKey) else {
            return .missingTransaction(transaction.idempotencyKey)
        }
        if current.revision != transaction.revision { return .staleRevision(transaction.idempotencyKey) }
        if current.leaseToken != transaction.leaseToken || current.leaseOwner != transaction.leaseOwner {
            return .leaseLost(transaction.idempotencyKey)
        }
        return .storageFailure("compare-and-swap update changed no rows")
    }

    private func insert(_ transaction: CalendarRegistryTransaction) throws {
        let sql = """
        INSERT INTO calendar_registry_transactions (
            idempotency_key, operation_id, manifest_fingerprint, stage,
            registry_event_id, calendar_event_id, calendar_id, provider_external_id,
            created_at, updated_at, last_verified_at, last_error, partial_effects_json,
            revision, lease_owner, lease_token, lease_expires_at, heartbeat_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        try withStatement(sql) { stmt in try bind(transaction, to: stmt); try stepDone(stmt) }
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
        try bindInt(stmt, 14, transaction.revision)
        try bindOptionalText(stmt, 15, transaction.leaseOwner)
        try bindOptionalText(stmt, 16, transaction.leaseToken)
        try bindOptionalDouble(stmt, 17, transaction.leaseExpiresAt?.timeIntervalSince1970)
        try bindOptionalDouble(stmt, 18, transaction.heartbeatAt?.timeIntervalSince1970)
    }

    private func requiredSelect(_ key: String) throws -> CalendarRegistryTransaction {
        guard let selected = try select(idempotencyKey: key) else { throw CalendarRegistryTransactionStoreError.missingTransaction(key) }
        return selected
    }

    private func select(idempotencyKey: String) throws -> CalendarRegistryTransaction? {
        let sql = """
        SELECT operation_id, idempotency_key, manifest_fingerprint, stage,
               registry_event_id, calendar_event_id, calendar_id, provider_external_id,
               created_at, updated_at, last_verified_at, last_error, partial_effects_json,
               revision, lease_owner, lease_token, lease_expires_at, heartbeat_at
        FROM calendar_registry_transactions WHERE idempotency_key=? LIMIT 1;
        """
        return try withStatement(sql) { stmt in
            try bindText(stmt, 1, idempotencyKey)
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return nil }
            guard rc == SQLITE_ROW else { throw sqliteError("select", rc: rc) }
            guard let operationId = text(stmt, 0), !operationId.isEmpty,
                  let storedKey = text(stmt, 1), !storedKey.isEmpty,
                  let fingerprint = text(stmt, 2), !fingerprint.isEmpty,
                  let stage = CalendarRegistryTransactionStage(rawValue: text(stmt, 3) ?? ""),
                  let createdAt = text(stmt, 8).flatMap(CalendarRegistryISO.date),
                  let updatedAt = text(stmt, 9).flatMap(CalendarRegistryISO.date),
                  let effectsRaw = text(stmt, 12),
                  let effects = try? JSONDecoder().decode([String].self, from: Data(effectsRaw.utf8)),
                  sqlite3_column_type(stmt, 13) != SQLITE_NULL else {
                throw CalendarRegistryTransactionStoreError.corruptLedger("invalid transaction row for \(idempotencyKey)")
            }
            let revision = Int(sqlite3_column_int64(stmt, 13))
            guard revision >= 1 else { throw CalendarRegistryTransactionStoreError.corruptLedger("invalid revision for \(idempotencyKey)") }
            let leaseExpiry = optionalDouble(stmt, 16).map(Date.init(timeIntervalSince1970:))
            let heartbeat = optionalDouble(stmt, 17).map(Date.init(timeIntervalSince1970:))
            return CalendarRegistryTransaction(
                operationId: operationId,
                idempotencyKey: storedKey,
                manifestFingerprint: fingerprint,
                stage: stage,
                registryEventId: text(stmt, 4),
                calendarEventId: text(stmt, 5),
                calendarId: text(stmt, 6),
                providerExternalId: text(stmt, 7),
                createdAt: createdAt,
                updatedAt: updatedAt,
                lastVerifiedAt: text(stmt, 10).flatMap(CalendarRegistryISO.date),
                lastError: text(stmt, 11),
                partialEffects: effects,
                revision: revision,
                leaseOwner: text(stmt, 14),
                leaseToken: text(stmt, 15),
                leaseExpiresAt: leaseExpiry,
                heartbeatAt: heartbeat
            )
        }
    }

    private func partialEffectsJSON(_ effects: [String]) throws -> String {
        String(decoding: try JSONEncoder().encode(effects), as: UTF8.self)
    }

    private func currentEpoch() throws -> TimeInterval {
        try withStatement("SELECT CAST(strftime('%s','now') AS REAL);") { stmt in
            guard sqlite3_step(stmt) == SQLITE_ROW else { throw sqliteError("clock", rc: sqlite3_errcode(db)) }
            return sqlite3_column_double(stmt, 0)
        }
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
        else { guard sqlite3_bind_null(stmt, index) == SQLITE_OK else { throw sqliteError("bind null", rc: sqlite3_errcode(db)) } }
    }

    private func bindInt(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int) throws {
        let rc = sqlite3_bind_int64(stmt, index, sqlite3_int64(value))
        guard rc == SQLITE_OK else { throw sqliteError("bind int", rc: rc) }
    }

    private func bindDouble(_ stmt: OpaquePointer?, _ index: Int32, _ value: Double) throws {
        let rc = sqlite3_bind_double(stmt, index, value)
        guard rc == SQLITE_OK else { throw sqliteError("bind double", rc: rc) }
    }

    private func bindOptionalDouble(_ stmt: OpaquePointer?, _ index: Int32, _ value: Double?) throws {
        if let value { try bindDouble(stmt, index, value) }
        else { guard sqlite3_bind_null(stmt, index) == SQLITE_OK else { throw sqliteError("bind null", rc: sqlite3_errcode(db)) } }
    }

    private func stepDone(_ stmt: OpaquePointer?) throws {
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else { throw sqliteError("step", rc: rc) }
    }

    private func text(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL, let raw = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: raw)
    }

    private func optionalDouble(_ stmt: OpaquePointer?, _ index: Int32) -> Double? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, index)
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
        leaseOwner: String,
        leaseToken: String,
        leaseDuration: TimeInterval,
        exclusiveProcessLockHeld: Bool
    ) throws -> CalendarRegistryTransaction {
        let now = Date()
        if var existing = transactions[idempotencyKey] {
            guard existing.manifestFingerprint == manifestFingerprint else { throw CalendarRegistryTransactionStoreError.idempotencyConflict(idempotencyKey) }
            if !exclusiveProcessLockHeld,
               let expiry = existing.leaseExpiresAt, existing.leaseToken != nil, expiry > now {
                throw CalendarRegistryTransactionStoreError.operationActive(idempotencyKey, expiry)
            }
            existing.operationId = operationId
            existing.leaseOwner = leaseOwner
            existing.leaseToken = leaseToken
            existing.leaseExpiresAt = now.addingTimeInterval(leaseDuration)
            existing.heartbeatAt = now
            existing.updatedAt = now
            existing.revision += 1
            transactions[idempotencyKey] = existing
            return existing
        }
        let transaction = CalendarRegistryTransaction(
            operationId: operationId,
            idempotencyKey: idempotencyKey,
            manifestFingerprint: manifestFingerprint,
            createdAt: now,
            updatedAt: now,
            revision: 1,
            leaseOwner: leaseOwner,
            leaseToken: leaseToken,
            leaseExpiresAt: now.addingTimeInterval(leaseDuration),
            heartbeatAt: now
        )
        transactions[idempotencyKey] = transaction
        return transaction
    }

    public func renew(_ transaction: CalendarRegistryTransaction, leaseDuration: TimeInterval) throws -> CalendarRegistryTransaction {
        var current = try owned(transaction)
        current.leaseExpiresAt = Date().addingTimeInterval(leaseDuration)
        current.heartbeatAt = Date()
        current.updatedAt = Date()
        current.revision += 1
        transactions[current.idempotencyKey] = current
        return current
    }

    public func get(idempotencyKey: String) -> CalendarRegistryTransaction? { transactions[idempotencyKey] }

    public func save(_ transaction: CalendarRegistryTransaction) throws -> CalendarRegistryTransaction {
        if let message = failNextSaveMessage {
            failNextSaveMessage = nil
            throw CalendarRegistryTransactionStoreError.storageFailure(message)
        }
        let current = try owned(transaction)
        guard current.stage.permitsTransition(to: transaction.stage) else {
            throw CalendarRegistryTransactionStoreError.stageRegression("\(current.stage.rawValue) → \(transaction.stage.rawValue)")
        }
        for (name, old, new) in [
            ("registry event id", current.registryEventId, transaction.registryEventId),
            ("calendar event id", current.calendarEventId, transaction.calendarEventId),
            ("calendar id", current.calendarId, transaction.calendarId),
            ("provider external id", current.providerExternalId, transaction.providerExternalId)
        ] where old?.isEmpty == false && new != old {
            throw CalendarRegistryTransactionStoreError.identityRegression("\(name) is immutable once established")
        }
        var saved = transaction
        saved.revision += 1
        saved.updatedAt = Date()
        saved.heartbeatAt = Date()
        transactions[saved.idempotencyKey] = saved
        return saved
    }

    public func release(_ transaction: CalendarRegistryTransaction) throws -> CalendarRegistryTransaction {
        var current = try owned(transaction, requireUnexpired: false)
        current.leaseOwner = nil
        current.leaseToken = nil
        current.leaseExpiresAt = nil
        current.heartbeatAt = Date()
        current.updatedAt = Date()
        current.revision += 1
        transactions[current.idempotencyKey] = current
        return current
    }

    private func owned(_ transaction: CalendarRegistryTransaction, requireUnexpired _: Bool = true) throws -> CalendarRegistryTransaction {
        guard let current = transactions[transaction.idempotencyKey] else { throw CalendarRegistryTransactionStoreError.missingTransaction(transaction.idempotencyKey) }
        guard current.revision == transaction.revision else { throw CalendarRegistryTransactionStoreError.staleRevision(transaction.idempotencyKey) }
        guard current.leaseToken == transaction.leaseToken, current.leaseOwner == transaction.leaseOwner,
              transaction.leaseToken?.isEmpty == false else { throw CalendarRegistryTransactionStoreError.leaseLost(transaction.idempotencyKey) }
        return current
    }
}

public enum CalendarRegistryDigest {
    public static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func sha256(_ value: String) -> String { sha256(Data(value.utf8)) }
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

    private final class WaiterState: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    private struct Waiter {
        let id: UUID
        let state: WaiterState
        let continuation: CheckedContinuation<Void, Error>
    }
    private var locked: Set<String> = []
    private var waiters: [String: [Waiter]] = [:]
    private var cancelled: Set<UUID> = []

    public init() {}

    public func acquire(_ key: String) async throws {
        try Task.checkCancellation()
        if !locked.contains(key) {
            locked.insert(key)
            return
        }
        let id = UUID()
        let state = WaiterState()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if state.isCancelled() || cancelled.remove(id) != nil || Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[key, default: []].append(Waiter(id: id, state: state, continuation: continuation))
                }
            }
        } onCancel: {
            state.cancel()
            Task { await self.cancel(key: key, id: id) }
        }
    }

    private func cancel(key: String, id: UUID) {
        if let index = waiters[key]?.firstIndex(where: { $0.id == id }) {
            let waiter = waiters[key]!.remove(at: index)
            if waiters[key]?.isEmpty == true { waiters[key] = nil }
            waiter.continuation.resume(throwing: CancellationError())
        } else {
            cancelled.insert(id)
        }
    }

    public func release(_ key: String) {
        while var queued = waiters[key], !queued.isEmpty {
            let next = queued.removeFirst()
            waiters[key] = queued.isEmpty ? nil : queued
            let cancellationMarker = cancelled.remove(next.id) != nil
            if next.state.isCancelled() || cancellationMarker {
                next.continuation.resume(throwing: CancellationError())
                continue
            }
            next.continuation.resume()
            return
        }
        locked.remove(key)
        waiters[key] = nil
    }
}
