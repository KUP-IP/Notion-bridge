// CallHistoryModule.swift — Bridge v4 stabilization · calls_recent Wave 1
// TheBridge · Modules
//
// Read-only access to the local macOS CallHistoryDB store. This module never
// mutates the database, never joins Contacts, and never claims that a number
// belongs to a person. The raw ZNAME column is intentionally neither selected
// nor exposed.

import Foundation
import SQLite3
import MCP

public enum CallHistoryDirection: String, Sendable, CaseIterable {
    case inbound
    case outbound
    case all
}

public struct CallHistoryQuery: Sendable, Equatable {
    public let limit: Int
    public let since: Date?
    public let number: String?
    public let direction: CallHistoryDirection

    public init(limit: Int, since: Date?, number: String?, direction: CallHistoryDirection) {
        self.limit = limit
        self.since = since
        self.number = number
        self.direction = direction
    }
}

public struct CallHistoryRawRecord: Sendable, Equatable {
    public let primaryKey: Int64
    public let uniqueID: String?
    public let date: Date
    public let durationSeconds: Double
    public let address: String?
    public let originated: Bool
    public let answered: Bool
    public let callType: Int
    public let serviceProvider: String?

    public init(
        primaryKey: Int64,
        uniqueID: String?,
        date: Date,
        durationSeconds: Double,
        address: String?,
        originated: Bool,
        answered: Bool,
        callType: Int,
        serviceProvider: String?
    ) {
        self.primaryKey = primaryKey
        self.uniqueID = uniqueID
        self.date = date
        self.durationSeconds = durationSeconds
        self.address = address
        self.originated = originated
        self.answered = answered
        self.callType = callType
        self.serviceProvider = serviceProvider
    }
}

public enum CallHistoryReadError: Error, Sendable, Equatable {
    /// Path does not exist on disk (distinguish from FDA / open denial).
    case missing(String)
    /// Database exists but cannot be opened (typically Full Disk Access).
    case unavailable(String)
    case unsupportedSchema(missingColumns: [String])
    case queryFailed(String)
}

public enum CallHistoryModule {
    public static let moduleName = "calls"
    public static let defaultLimit = 20
    public static let maximumLimit = 100

    public static let requiredColumns: Set<String> = [
        "Z_PK", "ZUNIQUE_ID", "ZDATE", "ZDURATION", "ZADDRESS",
        "ZORIGINATED", "ZANSWERED", "ZCALLTYPE", "ZSERVICE_PROVIDER"
    ]

    public static var defaultDatabasePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CallHistoryDB/CallHistory.storedata")
            .path
    }

    private static func makeISO8601() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    public static func normalizePhoneNumber(_ value: String) -> String {
        String(value.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) })
    }

    /// Durable call identity for idempotent follow-on tools.
    /// Prefer `ZUNIQUE_ID` when present; fall back to `Z_PK` as a string.
    public static func stableCallID(uniqueID: String?, primaryKey: Int64) -> String {
        if let uniqueID, !uniqueID.isEmpty {
            return uniqueID
        }
        return String(primaryKey)
    }

    public static func parseQuery(_ arguments: Value) throws -> CallHistoryQuery {
        let args: [String: Value]
        if case .object(let object) = arguments {
            args = object
        } else {
            args = [:]
        }

        let requestedLimit: Int
        if let value = args["limit"] {
            guard case .int(let limit) = value, limit > 0 else {
                throw ToolRouterError.invalidArguments(
                    toolName: "calls_recent",
                    reason: "'limit' must be a positive integer"
                )
            }
            requestedLimit = limit
        } else {
            requestedLimit = defaultLimit
        }

        let since: Date?
        if let value = args["since"] {
            guard case .string(let raw) = value else {
                throw ToolRouterError.invalidArguments(
                    toolName: "calls_recent",
                    reason: "'since' must be an ISO-8601 timestamp string"
                )
            }
            let fractional = makeISO8601()
            let ordinary = ISO8601DateFormatter()
            guard let parsed = fractional.date(from: raw) ?? ordinary.date(from: raw) else {
                throw ToolRouterError.invalidArguments(
                    toolName: "calls_recent",
                    reason: "'since' must be a valid ISO-8601 timestamp"
                )
            }
            since = parsed
        } else {
            since = nil
        }

        let number: String?
        if let value = args["number"] {
            guard case .string(let raw) = value else {
                throw ToolRouterError.invalidArguments(
                    toolName: "calls_recent",
                    reason: "'number' must be a phone-number string"
                )
            }
            let normalized = normalizePhoneNumber(raw)
            guard !normalized.isEmpty else {
                throw ToolRouterError.invalidArguments(
                    toolName: "calls_recent",
                    reason: "'number' must contain at least one decimal digit"
                )
            }
            number = normalized
        } else {
            number = nil
        }

        let direction: CallHistoryDirection
        if let value = args["direction"] {
            guard case .string(let raw) = value,
                  let parsed = CallHistoryDirection(rawValue: raw.lowercased()) else {
                throw ToolRouterError.invalidArguments(
                    toolName: "calls_recent",
                    reason: "'direction' must be inbound, outbound, or all"
                )
            }
            direction = parsed
        } else {
            direction = .all
        }

        return CallHistoryQuery(
            limit: min(requestedLimit, maximumLimit),
            since: since,
            number: number,
            direction: direction
        )
    }

    public static func filteredRecords(
        _ records: [CallHistoryRawRecord],
        query: CallHistoryQuery
    ) -> [CallHistoryRawRecord] {
        records
            .filter { record in
                if let since = query.since, record.date < since { return false }
                if query.direction == .inbound, record.originated { return false }
                if query.direction == .outbound, !record.originated { return false }
                if let number = query.number {
                    guard let address = record.address else { return false }
                    return normalizePhoneNumber(address) == number
                }
                return true
            }
            .sorted { lhs, rhs in
                if lhs.date == rhs.date { return lhs.primaryKey > rhs.primaryKey }
                return lhs.date > rhs.date
            }
            .prefix(query.limit)
            .map { $0 }
    }

    public static func response(
        arguments: Value,
        databasePath: String = defaultDatabasePath,
        reader: (String) throws -> [CallHistoryRawRecord] = readDatabase
    ) throws -> Value {
        let query = try parseQuery(arguments)

        do {
            let records = filteredRecords(try reader(databasePath), query: query)
            let iso = makeISO8601()
            let calls: [Value] = records.map { record in
                let identifier = stableCallID(uniqueID: record.uniqueID, primaryKey: record.primaryKey)
                return .object([
                    "id": .string(identifier),
                    "startedAt": .string(iso.string(from: record.date)),
                    "durationSeconds": .double(record.durationSeconds),
                    "number": record.address.map(Value.string) ?? .null,
                    "normalizedNumber": record.address.map(normalizePhoneNumber).map(Value.string) ?? .null,
                    "direction": .string(record.originated ? CallHistoryDirection.outbound.rawValue : CallHistoryDirection.inbound.rawValue),
                    "answered": .bool(record.answered),
                    "callType": .int(record.callType),
                    "serviceProvider": record.serviceProvider.map(Value.string) ?? .null
                ])
            }

            var filters: [String: Value] = [
                "limit": .int(query.limit),
                "direction": .string(query.direction.rawValue)
            ]
            filters["since"] = query.since.map { .string(iso.string(from: $0)) } ?? .null
            filters["number"] = query.number.map(Value.string) ?? .null

            return .object([
                "success": .bool(true),
                "source": .string("CallHistoryDB"),
                "identityResolved": .bool(false),
                "filters": .object(filters),
                "count": .int(calls.count),
                "calls": .array(calls)
            ])
        } catch CallHistoryReadError.missing(let detail) {
            return errorResponse(
                code: "database_missing",
                message: "The local CallHistory database was not found.",
                remediation: "Confirm macOS Call History exists for this user, then retry. If the path is unexpected, report it to The Bridge developer.",
                details: detail
            )
        } catch CallHistoryReadError.unavailable(let detail) {
            return errorResponse(
                code: "full_disk_access_required",
                message: "The Bridge could not read the local CallHistory database.",
                remediation: "Grant Full Disk Access to The Bridge in System Settings > Privacy & Security > Full Disk Access, then relaunch the app.",
                details: detail
            )
        } catch CallHistoryReadError.unsupportedSchema(let missing) {
            return errorResponse(
                code: "unsupported_call_history_schema",
                message: "This macOS CallHistoryDB schema is not supported; no partial or empty result was returned.",
                remediation: "Update The Bridge or report the missing schema columns before relying on call data.",
                details: "Missing columns: \(missing.sorted().joined(separator: ", "))",
                missingColumns: missing.sorted()
            )
        } catch CallHistoryReadError.queryFailed(let detail) {
            return errorResponse(
                code: "call_history_query_failed",
                message: "The Bridge could not query the local CallHistory database.",
                remediation: "Retry once. If the error persists, report the schema and query error to The Bridge developer.",
                details: detail
            )
        }
    }

    private static func errorResponse(
        code: String,
        message: String,
        remediation: String,
        details: String,
        missingColumns: [String]? = nil
    ) -> Value {
        var error: [String: Value] = [
            "code": .string(code),
            "message": .string(message),
            "remediation": .string(remediation),
            "details": .string(details)
        ]
        if let missingColumns {
            error["missingColumns"] = .array(missingColumns.map(Value.string))
        }
        return .object([
            "success": .bool(false),
            "source": .string("CallHistoryDB"),
            "identityResolved": .bool(false),
            "error": .object(error)
        ])
    }

    public static func readDatabase(at path: String) throws -> [CallHistoryRawRecord] {
        guard FileManager.default.fileExists(atPath: path) else {
            throw CallHistoryReadError.missing("CallHistory database not found at \(path)")
        }

        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil)
        guard openResult == SQLITE_OK, let database else {
            let detail = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            if let database { sqlite3_close(database) }
            throw CallHistoryReadError.unavailable(detail)
        }
        defer { sqlite3_close(database) }

        let columns = try schemaColumns(database: database)
        let missing = requiredColumns.subtracting(columns)
        guard missing.isEmpty else {
            throw CallHistoryReadError.unsupportedSchema(missingColumns: missing.sorted())
        }

        let sql = """
            SELECT Z_PK, ZUNIQUE_ID, ZDATE, ZDURATION, ZADDRESS,
                   ZORIGINATED, ZANSWERED, ZCALLTYPE, ZSERVICE_PROVIDER
            FROM ZCALLRECORD
            ORDER BY ZDATE DESC, Z_PK DESC
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw CallHistoryReadError.queryFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        var records: [CallHistoryRawRecord] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw CallHistoryReadError.queryFailed(String(cString: sqlite3_errmsg(database)))
            }

            records.append(CallHistoryRawRecord(
                primaryKey: sqlite3_column_int64(statement, 0),
                uniqueID: stringColumn(statement, index: 1),
                date: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 2)),
                durationSeconds: sqlite3_column_double(statement, 3),
                address: stringColumn(statement, index: 4),
                originated: sqlite3_column_int(statement, 5) != 0,
                answered: sqlite3_column_int(statement, 6) != 0,
                callType: Int(sqlite3_column_int64(statement, 7)),
                serviceProvider: stringColumn(statement, index: 8)
            ))
        }
        return records
    }

    private static func schemaColumns(database: OpaquePointer) throws -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(ZCALLRECORD)", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw CallHistoryReadError.queryFailed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        var columns: Set<String> = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw CallHistoryReadError.queryFailed(String(cString: sqlite3_errmsg(database)))
            }
            if let name = stringColumn(statement, index: 1) { columns.insert(name) }
        }
        return columns
    }

    private static func stringColumn(_ statement: OpaquePointer, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let bytes = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: bytes)
    }

    public static func register(on router: ToolRouter) async {
        await router.register(ToolRegistration(
            name: "calls_recent",
            module: moduleName,
            tier: .open,
            description: "Read recent macOS call-history records newest-first. Supports bounded time, normalized-number, and direction filters. Returns phone records only; it never resolves or claims contact identity.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "limit": .object([
                        "type": .string("integer"),
                        "minimum": .int(1),
                        "maximum": .int(maximumLimit),
                        "description": .string("Maximum records to return (default 20, hard maximum 100).")
                    ]),
                    "since": .object([
                        "type": .string("string"),
                        "format": .string("date-time"),
                        "description": .string("Only calls at or after this ISO-8601 timestamp.")
                    ]),
                    "number": .object([
                        "type": .string("string"),
                        "description": .string("Exact phone filter after removing all non-decimal characters; no contact identity lookup is performed.")
                    ]),
                    "direction": .object([
                        "type": .string("string"),
                        "enum": .array(CallHistoryDirection.allCases.map { .string($0.rawValue) }),
                        "description": .string("Filter inbound, outbound, or all calls (default all).")
                    ])
                ]),
                "required": .array([]),
                "additionalProperties": .bool(false)
            ]),
            metadata: ToolMetadata(
                title: "Calls: Recent",
                whenToUse: [
                    "reviewing recent inbound or outbound call records on this Mac",
                    "checking whether a normalized phone number appears in local call history"
                ],
                whenNotToUse: [
                    "identifying who owns a phone number (use contacts_resolve_handle separately)",
                    "dialing, messaging, drafting, recording, or modifying call history"
                ],
                relatedTools: ["contacts_resolve_handle", "messages_chat"]
            ),
            handler: { arguments in
                try response(arguments: arguments)
            }
        ))
    }
}
