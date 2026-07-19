// CallHistoryModuleTests.swift — Bridge v4 stabilization · calls_recent Wave 1

import Foundation
import MCP
import SQLite3
import TheBridgeLib

private func callRecord(
    id: Int64,
    seconds: TimeInterval,
    number: String?,
    outbound: Bool
) -> CallHistoryRawRecord {
    CallHistoryRawRecord(
        primaryKey: id,
        uniqueID: "call-\(id)",
        date: Date(timeIntervalSince1970: seconds),
        durationSeconds: Double(id),
        address: number,
        originated: outbound,
        answered: id.isMultiple(of: 2),
        callType: Int(id),
        serviceProvider: "provider"
    )
}

private func object(_ value: Value) throws -> [String: Value] {
    guard case .object(let result) = value else {
        throw TestError.assertion("Expected object response")
    }
    return result
}

func runCallHistoryModuleTests() async {
    print("\n☎️ CallHistoryModule Tests")

    let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
    await CallHistoryModule.register(on: router)

    await test("calls_recent registers as one open-tier calls tool") {
        let tools = await router.registrations(forModule: "calls")
        try expect(tools.count == 1)
        try expect(tools.first?.name == "calls_recent")
        try expect(tools.first?.tier == .open)
    }

    await test("calls_recent schema exposes every locked Wave 1 filter") {
        let registrations = await router.registrations(forModule: "calls")
        guard let tool = registrations.first(where: { $0.name == "calls_recent" }) else {
            throw TestError.assertion("Missing calls_recent registration")
        }
        guard case .object(let schema) = tool.inputSchema,
              case .object(let properties) = schema["properties"] else {
            throw TestError.assertion("Missing input properties")
        }
        try expect(Set(properties.keys) == Set(["limit", "since", "number", "direction"]))
        guard case .object(let direction) = properties["direction"],
              case .array(let values) = direction["enum"] else {
            throw TestError.assertion("Missing direction enum")
        }
        try expect(Set(values) == Set([.string("inbound"), .string("outbound"), .string("all")]))
    }

    await test("calls_recent annotation is read-only, ungated, and time-dependent") {
        guard let annotation = ToolAnnotationCatalog.annotations(for: "calls_recent") else {
            throw TestError.assertion("Missing calls_recent annotation")
        }
        try expect(annotation.readOnlyHint)
        try expect(!annotation.destructiveHint)
        try expect(!annotation.idempotentHint)
        try expect(!annotation.requiresConfirmation)
        try expect(annotation.openWorld)
    }

    await test("phone normalization removes punctuation without resolving identity") {
        try expect(CallHistoryModule.normalizePhoneNumber("+1 (605) 555-0123") == "16055550123")
        try expect(CallHistoryModule.normalizePhoneNumber("abc") == "")
    }

    await test("query parser defaults and hard-clamps the limit") {
        let defaults = try CallHistoryModule.parseQuery(.object([:]))
        try expect(defaults.limit == 20)
        try expect(defaults.direction == .all)
        let clamped = try CallHistoryModule.parseQuery(.object(["limit": .int(1_000)]))
        try expect(clamped.limit == 100)
    }

    await test("query parser rejects invalid limit, since, number, and direction") {
        for args: Value in [
            .object(["limit": .int(0)]),
            .object(["since": .string("yesterday-ish")]),
            .object(["number": .string("no digits")]),
            .object(["direction": .string("sideways")])
        ] {
            do {
                _ = try CallHistoryModule.parseQuery(args)
                throw TestError.assertion("Expected invalid arguments")
            } catch is ToolRouterError {
                // Expected.
            }
        }
    }

    let records = [
        callRecord(id: 1, seconds: 100, number: "+1 (605) 555-0100", outbound: false),
        callRecord(id: 2, seconds: 300, number: "+1 605 555 0200", outbound: true),
        callRecord(id: 3, seconds: 200, number: "16055550100", outbound: true)
    ]

    await test("records are newest-first and limit is applied after sorting") {
        let result = CallHistoryModule.filteredRecords(
            records,
            query: CallHistoryQuery(limit: 2, since: nil, number: nil, direction: .all)
        )
        try expect(result.map(\.primaryKey) == [2, 3])
    }

    await test("since filter is inclusive") {
        let result = CallHistoryModule.filteredRecords(
            records,
            query: CallHistoryQuery(limit: 10, since: Date(timeIntervalSince1970: 200), number: nil, direction: .all)
        )
        try expect(result.map(\.primaryKey) == [2, 3])
    }

    await test("normalized-number filter is exact and formatting-insensitive") {
        let result = CallHistoryModule.filteredRecords(
            records,
            query: CallHistoryQuery(limit: 10, since: nil, number: "16055550100", direction: .all)
        )
        try expect(result.map(\.primaryKey) == [3, 1])
    }

    await test("direction filters distinguish inbound, outbound, and all") {
        let inbound = CallHistoryModule.filteredRecords(
            records,
            query: CallHistoryQuery(limit: 10, since: nil, number: nil, direction: .inbound)
        )
        let outbound = CallHistoryModule.filteredRecords(
            records,
            query: CallHistoryQuery(limit: 10, since: nil, number: nil, direction: .outbound)
        )
        let all = CallHistoryModule.filteredRecords(
            records,
            query: CallHistoryQuery(limit: 10, since: nil, number: nil, direction: .all)
        )
        try expect(inbound.map(\.primaryKey) == [1])
        try expect(outbound.map(\.primaryKey) == [2, 3])
        try expect(all.map(\.primaryKey) == [2, 3, 1])
    }

    await test("successful response is structured and makes no identity claim") {
        let value = try CallHistoryModule.response(
            arguments: .object(["limit": .int(1)]),
            databasePath: "/fixture",
            reader: { _ in records }
        )
        let result = try object(value)
        try expect(result["success"] == .bool(true))
        try expect(result["identityResolved"] == .bool(false))
        guard case .array(let calls) = result["calls"],
              case .object(let first) = calls.first else {
            throw TestError.assertion("Missing calls array")
        }
        try expect(first["id"] == .string("call-2"))
        try expect(first["name"] == nil)
        try expect(first["resolvedName"] == nil)
    }

    await test("database denial returns structured Full Disk Access guidance") {
        let value = try CallHistoryModule.response(
            arguments: .object([:]),
            databasePath: "/denied",
            reader: { _ in throw CallHistoryReadError.unavailable("authorization denied") }
        )
        let result = try object(value)
        try expect(result["success"] == .bool(false))
        guard case .object(let error) = result["error"] else {
            throw TestError.assertion("Missing error object")
        }
        try expect(error["code"] == .string("full_disk_access_required"))
        guard case .string(let remediation) = error["remediation"] else {
            throw TestError.assertion("Missing remediation")
        }
        try expect(remediation.contains("Full Disk Access"))
    }

    await test("schema drift fails explicitly instead of returning an empty success") {
        let value = try CallHistoryModule.response(
            arguments: .object([:]),
            databasePath: "/fixture",
            reader: { _ in throw CallHistoryReadError.unsupportedSchema(missingColumns: ["ZDATE", "ZADDRESS"]) }
        )
        let result = try object(value)
        try expect(result["success"] == .bool(false))
        try expect(result["calls"] == nil)
        guard case .object(let error) = result["error"],
              case .array(let missing) = error["missingColumns"] else {
            throw TestError.assertion("Missing structured schema error")
        }
        try expect(Set(missing) == Set([.string("ZADDRESS"), .string("ZDATE")]))
    }

    await test("real SQLite adapter rejects an incompatible fixture schema") {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calls-recent-schema-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("CallHistory.storedata").path
        var database: OpaquePointer?
        try expect(sqlite3_open(path, &database) == SQLITE_OK)
        defer { if let database { sqlite3_close(database) } }
        try expect(sqlite3_exec(database, "CREATE TABLE ZCALLRECORD (Z_PK INTEGER)", nil, nil, nil) == SQLITE_OK)
        do {
            _ = try CallHistoryModule.readDatabase(at: path)
            throw TestError.assertion("Expected unsupported schema")
        } catch CallHistoryReadError.unsupportedSchema(let missing) {
            try expect(missing.contains("ZDATE"))
            try expect(missing.contains("ZADDRESS"))
        }
    }

    await test("missing database is distinguishable from Full Disk Access denial") {
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("calls-recent-missing-\(UUID().uuidString)/CallHistory.storedata")
            .path
        let missing = try CallHistoryModule.response(
            arguments: .object([:]),
            databasePath: missingPath
        )
        let missingResult = try object(missing)
        try expect(missingResult["success"] == .bool(false))
        guard case .object(let missingError) = missingResult["error"] else {
            throw TestError.assertion("Missing database_missing error")
        }
        try expect(missingError["code"] == .string("database_missing"))

        let denied = try CallHistoryModule.response(
            arguments: .object([:]),
            databasePath: "/denied",
            reader: { _ in throw CallHistoryReadError.unavailable("authorization denied") }
        )
        let deniedResult = try object(denied)
        guard case .object(let deniedError) = deniedResult["error"] else {
            throw TestError.assertion("Missing full_disk_access_required error")
        }
        try expect(deniedError["code"] == .string("full_disk_access_required"))
        try expect(missingError["code"] != deniedError["code"])
    }

    await test("query failure returns a distinct structured error code") {
        let value = try CallHistoryModule.response(
            arguments: .object([:]),
            databasePath: "/fixture",
            reader: { _ in throw CallHistoryReadError.queryFailed("sqlite prepare failed") }
        )
        let result = try object(value)
        try expect(result["success"] == .bool(false))
        try expect(result["calls"] == nil)
        guard case .object(let error) = result["error"] else {
            throw TestError.assertion("Missing query failed error")
        }
        try expect(error["code"] == .string("call_history_query_failed"))
    }

    await test("stable call ID prefers uniqueID and falls back to primary key") {
        try expect(CallHistoryModule.stableCallID(uniqueID: "754D6E7D-3764-49FC-823E-8710CFD8AA76", primaryKey: 42)
            == "754D6E7D-3764-49FC-823E-8710CFD8AA76")
        try expect(CallHistoryModule.stableCallID(uniqueID: "", primaryKey: 42) == "42")
        try expect(CallHistoryModule.stableCallID(uniqueID: nil, primaryKey: 7) == "7")
    }

    await test("compatible SQLite fixture exercises adapter date decoding and durable ids") {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("calls-recent-compatible-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("CallHistory.storedata").path

        var database: OpaquePointer?
        try expect(sqlite3_open(path, &database) == SQLITE_OK)
        guard let database else { throw TestError.assertion("Failed to open fixture DB") }
        defer { sqlite3_close(database) }

        let createSQL = """
            CREATE TABLE ZCALLRECORD (
                Z_PK INTEGER PRIMARY KEY,
                ZUNIQUE_ID TEXT,
                ZDATE REAL,
                ZDURATION REAL,
                ZADDRESS TEXT,
                ZORIGINATED INTEGER,
                ZANSWERED INTEGER,
                ZCALLTYPE INTEGER,
                ZSERVICE_PROVIDER TEXT
            );
            """
        try expect(sqlite3_exec(database, createSQL, nil, nil, nil) == SQLITE_OK)

        let startedAt = ISO8601DateFormatter().date(from: "2026-07-17T12:00:00Z")!
        let zDate = startedAt.timeIntervalSinceReferenceDate
        let insertWithID = """
            INSERT INTO ZCALLRECORD
            (Z_PK, ZUNIQUE_ID, ZDATE, ZDURATION, ZADDRESS, ZORIGINATED, ZANSWERED, ZCALLTYPE, ZSERVICE_PROVIDER)
            VALUES (1, 'AAAA1111-BBBB-CCCC-DDDD-EEEEEEEEEEEE', \(zDate), 12.5, '+16055550123', 1, 1, 1, 'com.apple.Telephony');
            """
        let insertFallback = """
            INSERT INTO ZCALLRECORD
            (Z_PK, ZUNIQUE_ID, ZDATE, ZDURATION, ZADDRESS, ZORIGINATED, ZANSWERED, ZCALLTYPE, ZSERVICE_PROVIDER)
            VALUES (2, NULL, \(zDate - 60), 0, '6055550199', 0, 0, 1, 'com.apple.Telephony');
            """
        try expect(sqlite3_exec(database, insertWithID, nil, nil, nil) == SQLITE_OK)
        try expect(sqlite3_exec(database, insertFallback, nil, nil, nil) == SQLITE_OK)

        let firstRead = try CallHistoryModule.readDatabase(at: path)
        try expect(firstRead.count == 2)
        try expect(firstRead[0].uniqueID == "AAAA1111-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        try expect(abs(firstRead[0].date.timeIntervalSince(startedAt)) < 0.001)

        let secondRead = try CallHistoryModule.readDatabase(at: path)
        try expect(firstRead.map(\.uniqueID) == secondRead.map(\.uniqueID))
        try expect(firstRead.map(\.primaryKey) == secondRead.map(\.primaryKey))

        let value = try CallHistoryModule.response(
            arguments: .object(["limit": .int(10)]),
            databasePath: path
        )
        let result = try object(value)
        try expect(result["success"] == .bool(true))
        guard case .array(let calls) = result["calls"],
              case .object(let newest) = calls.first,
              case .object(let oldest) = calls.last else {
            throw TestError.assertion("Expected two structured calls from fixture")
        }
        try expect(newest["id"] == .string("AAAA1111-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        try expect(oldest["id"] == .string("2"))
        try expect(newest["normalizedNumber"] == .string("16055550123"))
        try expect(newest["direction"] == .string("outbound"))
        guard case .string(let startedAtString) = newest["startedAt"] else {
            throw TestError.assertion("Missing startedAt")
        }
        try expect(startedAtString.hasPrefix("2026-07-17T12:00:00"))
    }
}
