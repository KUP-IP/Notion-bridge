// SessionRegistry.swift — Bridge Evolution Contract W1 session broker
// TheBridge · Server
//
// Durable broker sessions are separate from MCP transport resumability. The
// existing SessionPersistenceStore keeps Streamable HTTP session IDs alive
// across app restarts; this registry records whether a caller has completed
// bridge_initialize and is therefore governed.
//
// Remote OAuth connectors often rotate Mcp-Session-Id between tool calls.
// Governance therefore also keys on a verified principal (`oauth-sub:<sub>`)
// when present — never on spoofable clientInfo.

import Foundation
import SQLite3

private let SESSION_SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

public enum BrokerSessionMode: String, Codable, Sendable, CaseIterable {
    case recon
    case execute
    case background
    case general
}

public struct BrokerSessionRecord: Codable, Sendable, Equatable {
    public let sessionId: String
    public let transportSessionId: String
    public let client: String?
    public let principalKey: String?
    public let mode: BrokerSessionMode
    public let startedAt: Date
    public let governed: Bool
    public let closedAt: Date?

    public init(
        sessionId: String = UUID().uuidString,
        transportSessionId: String,
        client: String?,
        principalKey: String? = nil,
        mode: BrokerSessionMode,
        startedAt: Date = Date(),
        governed: Bool = true,
        closedAt: Date? = nil
    ) {
        self.sessionId = sessionId
        self.transportSessionId = transportSessionId
        self.client = client
        self.principalKey = principalKey
        self.mode = mode
        self.startedAt = startedAt
        self.governed = governed
        self.closedAt = closedAt
    }
}

public enum ToolDispatchOrigin: String, Codable, Sendable, Equatable {
    case local
    case remote
}

public struct ToolDispatchContext: Sendable, Equatable {
    @TaskLocal public static var current: ToolDispatchContext?

    public let transportSessionId: String?
    public let origin: ToolDispatchOrigin
    public let client: String?
    public let clientVersion: String?
    /// Verified OAuth subject key (`oauth-sub:<sub>`). Never request-supplied.
    public let governancePrincipal: String?

    public init(
        transportSessionId: String?,
        origin: ToolDispatchOrigin,
        client: String? = nil,
        clientVersion: String? = nil,
        governancePrincipal: String? = nil
    ) {
        self.transportSessionId = transportSessionId
        self.origin = origin
        self.client = client
        self.clientVersion = clientVersion
        self.governancePrincipal = SessionRegistry.normalizedPrincipalKey(governancePrincipal)
    }

    public static let localDefault = ToolDispatchContext(
        transportSessionId: nil,
        origin: .local,
        client: nil,
        clientVersion: nil,
        governancePrincipal: nil
    )
}

public actor SessionRegistry {
    public static let shared = SessionRegistry()

    private var db: OpaquePointer?
    private var isOpen = false
    private let path: URL

    public init(path: URL = SessionRegistry.defaultStoreURL()) {
        self.path = path
    }

    public nonisolated static func defaultStoreURL() -> URL {
        BridgePaths.applicationSupport(.sessions)
            .appendingPathComponent("sessions.sqlite", isDirectory: false)
    }

    /// Build a governance principal key from a verified OAuth subject.
    /// Returns nil for empty/whitespace subjects so they cannot share a bucket.
    public nonisolated static func principalKey(subject: String) -> String? {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return "oauth-sub:\(trimmed)"
    }

    public nonisolated static func normalizedPrincipalKey(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("oauth-sub:") {
            let suffix = trimmed.dropFirst("oauth-sub:".count)
            guard !suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return trimmed
        }
        return principalKey(subject: trimmed)
    }

    @discardableResult
    public func open(
        transportSessionId: String,
        client: String?,
        mode: BrokerSessionMode,
        startedAt: Date = Date(),
        principalKey: String? = nil
    ) throws -> BrokerSessionRecord {
        try ensureOpen()
        let record = BrokerSessionRecord(
            transportSessionId: transportSessionId,
            client: client,
            principalKey: Self.normalizedPrincipalKey(principalKey),
            mode: mode,
            startedAt: startedAt,
            governed: true
        )
        let sql = """
        INSERT INTO broker_sessions(
            session_id, transport_session_id, client, mode, started_at, governed, closed_at, principal_key
        ) VALUES(?,?,?,?,?,?,NULL,?)
        ON CONFLICT(transport_session_id) DO UPDATE SET
            session_id=excluded.session_id,
            client=excluded.client,
            mode=excluded.mode,
            started_at=excluded.started_at,
            governed=excluded.governed,
            closed_at=NULL,
            principal_key=excluded.principal_key;
        """
        try bindAndStep(sql) { stmt in
            sqlite3_bind_text(stmt, 1, record.sessionId, -1, SESSION_SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, record.transportSessionId, -1, SESSION_SQLITE_TRANSIENT)
            if let client = record.client {
                sqlite3_bind_text(stmt, 3, client, -1, SESSION_SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            sqlite3_bind_text(stmt, 4, record.mode.rawValue, -1, SESSION_SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, Self.iso(record.startedAt), -1, SESSION_SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 6, record.governed ? 1 : 0)
            if let principalKey = record.principalKey {
                sqlite3_bind_text(stmt, 7, principalKey, -1, SESSION_SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 7)
            }
        }
        return record
    }

    public func current(transportSessionId: String) throws -> BrokerSessionRecord? {
        try ensureOpen()
        let rows = try query("""
        SELECT session_id, transport_session_id, client, mode, started_at, governed, closed_at, principal_key
        FROM broker_sessions
        WHERE transport_session_id=? AND closed_at IS NULL
        LIMIT 1;
        """) { stmt in
            sqlite3_bind_text(stmt, 1, transportSessionId, -1, SESSION_SQLITE_TRANSIENT)
        }
        return rows.compactMap(Self.record(from:)).first
    }

    public func isGoverned(
        transportSessionId: String?,
        principalKey: String? = nil
    ) throws -> Bool {
        try ensureOpen()
        let principal = Self.normalizedPrincipalKey(principalKey)
        if let transportSessionId, !transportSessionId.isEmpty {
            if try current(transportSessionId: transportSessionId)?.governed == true {
                return true
            }
        }
        guard let principal, !principal.isEmpty else { return false }
        let rows = try query("""
        SELECT session_id, transport_session_id, client, mode, started_at, governed, closed_at, principal_key
        FROM broker_sessions
        WHERE principal_key=? AND closed_at IS NULL AND governed=1
        LIMIT 1;
        """) { stmt in
            sqlite3_bind_text(stmt, 1, principal, -1, SESSION_SQLITE_TRANSIENT)
        }
        return rows.compactMap(Self.record(from:)).first != nil
    }

    public func close(transportSessionId: String, at date: Date = Date()) throws {
        try ensureOpen()
        try bindAndStep("UPDATE broker_sessions SET closed_at=? WHERE transport_session_id=?;") { stmt in
            sqlite3_bind_text(stmt, 1, Self.iso(date), -1, SESSION_SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, transportSessionId, -1, SESSION_SQLITE_TRANSIENT)
        }
    }

    public func resetForTesting() throws {
        if let db {
            sqlite3_close_v2(db)
            self.db = nil
        }
        isOpen = false
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
    }

    private func ensureOpen() throws {
        if isOpen { return }
        let parent = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            throw SessionRegistryError.storage("sqlite3_open_v2 failed: \(rc)")
        }
        db = handle
        isOpen = true
        try exec("PRAGMA journal_mode=WAL;")
        try exec("""
        CREATE TABLE IF NOT EXISTS broker_sessions (
            session_id TEXT PRIMARY KEY,
            transport_session_id TEXT NOT NULL UNIQUE,
            client TEXT,
            mode TEXT NOT NULL,
            started_at TEXT NOT NULL,
            governed INTEGER NOT NULL,
            closed_at TEXT,
            principal_key TEXT
        );
        """)
        // Pre-existing DBs created before principal continuity lack the column.
        try? exec("ALTER TABLE broker_sessions ADD COLUMN principal_key TEXT;")
        try exec("""
        CREATE INDEX IF NOT EXISTS idx_broker_sessions_transport
        ON broker_sessions(transport_session_id, closed_at);
        """)
        try exec("""
        CREATE INDEX IF NOT EXISTS idx_broker_sessions_principal
        ON broker_sessions(principal_key, closed_at, governed);
        """)
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<Int8>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let message = err.map { String(cString: $0) } ?? "sqlite3_exec rc=\(rc)"
            sqlite3_free(err)
            throw SessionRegistryError.storage(message)
        }
    }

    private func bindAndStep(_ sql: String, bind: (OpaquePointer?) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SessionRegistryError.storage("prepare failed: \(sqliteErrorMessage())")
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            throw SessionRegistryError.storage("step rc=\(rc): \(sqliteErrorMessage())")
        }
    }

    private func query(_ sql: String, bind: (OpaquePointer?) -> Void) throws -> [[String?]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SessionRegistryError.storage("prepare failed: \(sqliteErrorMessage())")
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        var rows: [[String?]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let count = sqlite3_column_count(stmt)
            var row: [String?] = []
            for i in 0..<count {
                if sqlite3_column_type(stmt, i) == SQLITE_NULL {
                    row.append(nil)
                } else if let text = sqlite3_column_text(stmt, i) {
                    row.append(String(cString: text))
                } else {
                    row.append(nil)
                }
            }
            rows.append(row)
        }
        return rows
    }

    private func sqliteErrorMessage() -> String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "no sqlite handle"
    }

    private static func record(from row: [String?]) -> BrokerSessionRecord? {
        guard row.count >= 7,
              let sessionId = row[0],
              let transportSessionId = row[1],
              let modeRaw = row[3],
              let mode = BrokerSessionMode(rawValue: modeRaw),
              let startedRaw = row[4],
              let started = isoDate(startedRaw),
              let governedRaw = row[5]
        else { return nil }
        let principalKey = row.count >= 8 ? row[7] : nil
        return BrokerSessionRecord(
            sessionId: sessionId,
            transportSessionId: transportSessionId,
            client: row[2] ?? nil,
            principalKey: principalKey ?? nil,
            mode: mode,
            startedAt: started,
            governed: governedRaw == "1",
            closedAt: (row[6] ?? nil).flatMap(isoDate)
        )
    }

    private static func iso(_ date: Date) -> String {
        bridgeFormatter().string(from: date)
    }

    private static func isoDate(_ raw: String) -> Date? {
        bridgeFormatter().date(from: raw)
    }

    private static func bridgeFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

public enum SessionRegistryError: Error, LocalizedError, Sendable {
    case storage(String)

    public var errorDescription: String? {
        switch self {
        case .storage(let message): return "Session registry storage failed: \(message)"
        }
    }
}
