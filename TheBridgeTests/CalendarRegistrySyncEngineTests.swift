// CalendarRegistrySyncEngineTests.swift — reduced registry-first durability matrix

import Foundation
import MCP
import TheBridgeLib

private actor SyncTestRegistry: TimeInstanceRegistryStoring {
    private var records: [String: TimeInstanceRecord] = [:]
    private var sequence = 0
    private var failNextSave = false
    private var lookupSource: RegistryLookupSource = .live
    private(set) var createCount = 0

    func setFailNextSave(_ value: Bool) { failNextSave = value }
    func setLookupSource(_ source: RegistryLookupSource) { lookupSource = source }
    func count() -> Int { records.count }
    func createdCount() -> Int { createCount }
    func allRecords() -> [TimeInstanceRecord] { Array(records.values) }

    func findBySyncKey(_ syncKey: String) async throws -> RegistryIdentityLookup {
        RegistryIdentityLookup(
            records: records.values.filter { $0.syncKey == syncKey },
            source: lookupSource
        )
    }

    func get(id: String, forceRefresh: Bool) async throws -> TimeInstanceRecord? {
        _ = forceRefresh
        return records[id]
    }

    func create(_ record: TimeInstanceRecord) async throws -> TimeInstanceRecord {
        sequence += 1
        createCount += 1
        var created = record
        created.id = "notion-event-\(sequence)"
        records[created.id] = created
        return created
    }

    func save(_ record: TimeInstanceRecord) async throws -> TimeInstanceRecord {
        if failNextSave {
            failNextSave = false
            throw SyncTestError.forcedRegistrySave
        }
        records[record.id] = record
        return record
    }
}

private enum SyncTestError: Error, LocalizedError {
    case forcedCalendarCreate
    case forcedRegistrySave
    case forcedVerificationMiss

    var errorDescription: String? {
        switch self {
        case .forcedCalendarCreate: return "forced calendar create failure"
        case .forcedRegistrySave: return "forced registry save failure"
        case .forcedVerificationMiss: return "forced verification miss"
        }
    }
}

private actor SyncTestCalendar: CalendarSyncProviding {
    private var items: [String: ExternalCalendarItem] = [:]
    private var sequence = 0
    private var failNextCreate = false
    private var missNextItem = false
    private var ambiguousRecovery = false
    private(set) var createCount = 0

    func setFailNextCreate(_ value: Bool) { failNextCreate = value }
    func setMissNextItem(_ value: Bool) { missNextItem = value }
    func setAmbiguousRecovery(_ value: Bool) { ambiguousRecovery = value }
    func createdCount() -> Int { createCount }
    func count() -> Int { items.count }

    func create(_ draft: ExternalCalendarDraft) async throws -> ExternalCalendarItem {
        if failNextCreate {
            failNextCreate = false
            throw SyncTestError.forcedCalendarCreate
        }
        sequence += 1
        createCount += 1
        let id = "calendar-event-\(sequence)"
        let item = ExternalCalendarItem(
            provider: "Fixture Calendar",
            calendarId: draft.calendarId ?? "cal-private",
            localEventId: id,
            providerExternalId: "provider-\(sequence)",
            syncKey: draft.syncKey,
            title: draft.title,
            start: draft.start,
            end: draft.end,
            timeZoneIdentifier: draft.timeZoneIdentifier,
            location: draft.location,
            notes: draft.notes,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        items[id] = item
        return item
    }

    func item(id: String) async throws -> ExternalCalendarItem? {
        if missNextItem {
            missNextItem = false
            return nil
        }
        return items[id]
    }

    func recover(_ query: CalendarRecoveryQuery) async throws -> [ExternalCalendarItem] {
        if ambiguousRecovery {
            let base = ExternalCalendarItem(
                provider: "Fixture Calendar", calendarId: query.calendarId ?? "cal-private",
                localEventId: "ambiguous-a", syncKey: query.syncKey,
                title: query.title, start: query.start, end: query.end,
                updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
            var other = base
            other.localEventId = "ambiguous-b"
            return [base, other]
        }
        if let id = query.localEventId, let direct = items[id] { return [direct] }
        let byKey = items.values.filter { $0.syncKey == query.syncKey }
        if !byKey.isEmpty { return Array(byKey) }
        if let external = query.providerExternalId {
            let byExternal = items.values.filter { $0.providerExternalId == external }
            if !byExternal.isEmpty { return Array(byExternal) }
        }
        return items.values.filter {
            $0.title == query.title && $0.start == query.start && $0.end == query.end
        }
    }
}

private func syncRequest(
    key: String = "operation-lift-2027-01-15",
    title: String = "LIFT"
) -> RegistryFirstTimeInstanceRequest {
    RegistryFirstTimeInstanceRequest(
        idempotencyKey: key,
        title: title,
        start: Date(timeIntervalSince1970: 1_800_010_000),
        end: Date(timeIntervalSince1970: 1_800_013_600),
        timeZoneIdentifier: "America/Chicago",
        calendarId: "cal-private",
        location: "Private Gym",
        notes: "Disposable fixture",
        semantics: TimeInstanceSemantics(
            eventClass: .focus,
            primaryBlockId: "block-lift",
            blockIds: ["block-lift"]
        )
    )
}

private func makeSyncEngine(
    registry: SyncTestRegistry = SyncTestRegistry(),
    calendar: SyncTestCalendar = SyncTestCalendar(),
    transactions: any CalendarRegistryTransactionStoring = InMemoryCalendarRegistryTransactionStore(),
    operationGate: CalendarRegistryOperationGate = CalendarRegistryOperationGate()
) -> CalendarRegistrySyncEngine {
    CalendarRegistrySyncEngine(
        registry: registry,
        calendar: calendar,
        transactions: transactions,
        operationGate: operationGate,
        clock: { Date(timeIntervalSince1970: 1_800_000_000) },
        makeOperationId: { "operation-id-fixture" }
    )
}

private func withTempTransactionJournal(
    _ body: (URL) async throws -> Void
) async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("bridge-calendar-sync-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory.appendingPathComponent("transactions.json"))
}

// MARK: - Notion adapter fixture

private actor SyncRegistryGateway: RegistryNotionGateway {
    nonisolated var supportsAuthoritativeFiltering: Bool { true }
    var pages: [String: NotionRow] = [:]
    var failUpdate = false
    var filteredQueryCalls = 0
    var lastFilter: Data?
    private var sequence = 0
    private(set) var lastUpdatedFields: [BoundField] = []

    func setFailUpdate(_ value: Bool) { failUpdate = value }
    func updatedFields() -> [BoundField] { lastUpdatedFields }

    func schema(dataSourceId: String, workspace: String?) async throws -> DataSourceSchema {
        _ = dataSourceId; _ = workspace
        return DataSourceSchema(columnsByName: [:])
    }

    func query(dataSourceId: String, workspace: String?, pageSize: Int, startCursor: String?) async throws -> (rows: [NotionRow], nextCursor: String?) {
        _ = dataSourceId; _ = workspace; _ = pageSize; _ = startCursor
        return (Array(pages.values), nil)
    }

    func query(dataSourceId: String, workspace: String?, filter: Data, pageSize: Int, startCursor: String?) async throws -> (rows: [NotionRow], nextCursor: String?) {
        _ = dataSourceId; _ = workspace; _ = pageSize; _ = startCursor
        filteredQueryCalls += 1
        lastFilter = filter
        let object = (try? JSONSerialization.jsonObject(with: filter) as? [String: Any]) ?? [:]
        let rich = object["rich_text"] as? [String: Any]
        let wanted = rich?["equals"] as? String
        let rows = pages.values.filter { row in
            row.cells.values.contains { cell in
                cell.type == "rich_text" && cell.value == .string(wanted ?? "")
            }
        }
        return (Array(rows), nil)
    }

    func page(pageId: String, workspace: String?) async throws -> NotionRow {
        _ = workspace
        guard let row = pages[pageId] ?? pages[CachedRow.normalize(pageId)] else {
            throw SyncTestError.forcedVerificationMiss
        }
        return row
    }

    func create(dataSourceId: String, workspace: String?, fields: [BoundField]) async throws -> NotionRow {
        _ = dataSourceId; _ = workspace
        sequence += 1
        let id = String(format: "%032d", sequence)
        let row = Self.row(id: id, existing: nil, fields: fields)
        pages[id] = row
        return row
    }

    func update(pageId: String, workspace: String?, fields: [BoundField]) async throws -> NotionRow {
        _ = workspace
        if failUpdate {
            failUpdate = false
            throw SyncTestError.forcedRegistrySave
        }
        lastUpdatedFields = fields
        let row = Self.row(id: pageId, existing: pages[pageId], fields: fields)
        pages[pageId] = row
        return row
    }

    func archive(pageId: String, workspace: String?) async throws { pages[pageId] = nil }
    func markdown(pageId: String, workspace: String?) async throws -> String { "" }
    func writeMarkdown(pageId: String, workspace: String?, markdown: String) async throws {}

    private static func row(id: String, existing: NotionRow?, fields: [BoundField]) -> NotionRow {
        var cells = existing?.cells ?? [:]
        for field in fields {
            cells[field.notionName] = NotionCell(
                id: field.propertyId, type: field.type, value: field.value
            )
        }
        return NotionRow(
            id: id, url: "https://notion.fixture/\(id)",
            lastEditedTime: "2027-01-15T08:00:00.000Z", cells: cells
        )
    }
}

private func scheduleEntityForSyncTests() -> RegistryEntity {
    let definitions: [(String, String, String, RegistryPropertyRole)] = [
        ("title", "EVENT TITLE", "title", .title),
        ("date", "EVENT DATE", "date", .date),
        ("status", "Status", "status", .status),
        ("syncKey", "Sync Key", "rich_text", .generic),
        ("eventClass", "Event Class", "select", .generic),
        ("meetingType", "Meeting Type", "select", .generic),
        ("primaryBlock", "Primary BLOCK", "relation", .relation),
        ("blocks", "BLOCKS", "relation", .relation),
        ("projects", "PROJECTS", "relation", .relation),
        ("contacts", "CONTACTS", "relation", .relation),
        ("schedulingAuthority", "Scheduling Authority", "select", .generic),
        ("syncState", "Sync State", "select", .generic),
        ("registryUpdatedAt", "Registry Updated At", "date", .date),
        ("syncHash", "Sync Hash", "rich_text", .generic),
        ("scheduledDuration", "Scheduled Duration", "number", .generic),
        ("description", "Description", "rich_text", .generic),
        ("calendarLocation", "Calendar Location", "rich_text", .generic),
        ("calendarProvider", "Calendar Provider", "select", .generic),
        ("calendarId", "Calendar ID", "rich_text", .generic),
        ("calendarEventId", "Calendar Event ID", "rich_text", .generic),
        ("providerExternalId", "Provider External ID", "rich_text", .generic),
        ("calendarUrl", "Calendar URL", "url", .generic),
        ("lastSyncError", "Last Sync Error", "rich_text", .generic),
        ("lastSyncedAt", "Last Synced At", "date", .date),
        ("calendarUpdatedAt", "Calendar Updated At", "date", .date)
    ]
    return RegistryEntity(
        key: "schedule", displayName: "EVENTS", dataSourceId: "events-ds",
        properties: definitions.enumerated().map { index, item in
            RegistryProperty(
                key: item.0, notionName: item.1,
                notionPropertyId: "property-\(index)", type: item.2, role: item.3
            )
        },
        cacheTTLSeconds: 0
    )
}

func runCalendarRegistrySyncEngineTests() async {
    print("\n🗓 Calendar–Registry Sync — reduced durability slice")

    await test("CR1 atomic transaction journal survives store reconstruction") {
        try await withTempTransactionJournal { url in
            let first = try JSONCalendarRegistryTransactionStore(url: url)
            var transaction = try await first.claim(
                idempotencyKey: "same-key", manifestFingerprint: "manifest",
                operationId: "op-1", now: Date(timeIntervalSince1970: 100)
            )
            transaction.stage = .calendarCreated
            transaction.calendarEventId = "calendar-1"
            try await first.save(transaction)

            let second = try JSONCalendarRegistryTransactionStore(url: url)
            let loaded = try await second.get(idempotencyKey: "same-key")
            try expect(loaded?.stage == .calendarCreated)
            try expect(loaded?.calendarEventId == "calendar-1")
        }
    }

    await test("CR2 ten sequential retries create exactly one pair") {
        let registry = SyncTestRegistry()
        let calendar = SyncTestCalendar()
        let engine = makeSyncEngine(registry: registry, calendar: calendar)
        for _ in 0..<10 {
            let receipt = try await engine.registryFirstCreate(syncRequest())
            try expect(receipt.succeeded)
            try expect(receipt.stageAfter == .synced)
        }
        try expect(await registry.createdCount() == 1)
        try expect(await calendar.createdCount() == 1)
    }

    await test("CR3 concurrent same-key calls across engines create one pair") {
        let registry = SyncTestRegistry()
        let calendar = SyncTestCalendar()
        let transactions = InMemoryCalendarRegistryTransactionStore()
        let gate = CalendarRegistryOperationGate()
        let first = makeSyncEngine(registry: registry, calendar: calendar, transactions: transactions, operationGate: gate)
        let second = makeSyncEngine(registry: registry, calendar: calendar, transactions: transactions, operationGate: gate)
        async let a = first.registryFirstCreate(syncRequest())
        async let b = second.registryFirstCreate(syncRequest())
        let receipts = try await [a, b]
        try expect(receipts.allSatisfy(\.succeeded))
        try expect(await registry.createdCount() == 1)
        try expect(await calendar.createdCount() == 1)
    }

    await test("CR4 reusing an idempotency key for a different manifest conflicts") {
        let engine = makeSyncEngine()
        _ = try await engine.registryFirstCreate(syncRequest())
        let receipt = try await engine.registryFirstCreate(syncRequest(title: "Different"))
        try expect(!receipt.succeeded)
        try expect(receipt.stageAfter == .conflict)
        try expect(receipt.discrepancy?.contains("different manifest") == true)
    }

    await test("CR5 calendar create failure resumes without a second EVENT") {
        let registry = SyncTestRegistry()
        let calendar = SyncTestCalendar()
        await calendar.setFailNextCreate(true)
        let engine = makeSyncEngine(registry: registry, calendar: calendar)
        let first = try await engine.registryFirstCreate(syncRequest())
        try expect(!first.succeeded)
        let second = try await engine.registryFirstCreate(syncRequest())
        try expect(second.succeeded)
        try expect(await registry.createdCount() == 1)
        try expect(await calendar.createdCount() == 1)
    }

    await test("CR6 failure after calendar creation recovers the calendar item") {
        let registry = SyncTestRegistry()
        let calendar = SyncTestCalendar()
        await registry.setFailNextSave(true)
        let engine = makeSyncEngine(registry: registry, calendar: calendar)
        let first = try await engine.registryFirstCreate(syncRequest())
        try expect(!first.succeeded)
        try expect(first.partialEffects.contains(where: { $0.contains("calendar") }))
        let second = try await engine.registryFirstCreate(syncRequest())
        try expect(second.succeeded)
        try expect(await registry.createdCount() == 1)
        try expect(await calendar.createdCount() == 1)
    }

    await test("CR7 failed verification never reports Synced") {
        let registry = SyncTestRegistry()
        let calendar = SyncTestCalendar()
        await calendar.setMissNextItem(true)
        let engine = makeSyncEngine(registry: registry, calendar: calendar)
        let receipt = try await engine.registryFirstCreate(syncRequest())
        try expect(!receipt.succeeded)
        try expect(receipt.stageAfter == .recoverableError)
        let records = await registry.allRecords()
        try expect(records.allSatisfy { $0.syncState != .synced })
    }

    await test("CR8 fresh EventKit provider recovers an event after provider restart") {
        let store = MockCalendarStore()
        let firstProvider = CalendarStoringSyncProvider(store: store)
        var request = syncRequest()
        request.calendarId = "cal-home"
        let created = try await firstProvider.create(ExternalCalendarDraft(
            title: request.title, start: request.start, end: request.end,
            timeZoneIdentifier: request.timeZoneIdentifier,
            calendarId: request.calendarId, location: request.location,
            notes: request.notes, syncKey: request.idempotencyKey
        ))
        let restartedProvider = CalendarStoringSyncProvider(store: store)
        let recovered = try await restartedProvider.recover(CalendarRecoveryQuery(
            localEventId: created.localEventId,
            providerExternalId: created.providerExternalId,
            syncKey: request.idempotencyKey,
            calendarId: request.calendarId,
            title: request.title, start: request.start, end: request.end
        ))
        try expect(recovered.count == 1)
        try expect(recovered.first?.syncKey == request.idempotencyKey)
    }

    await test("CR9 ambiguous provider recovery stops in Conflict") {
        let registry = SyncTestRegistry()
        let calendar = SyncTestCalendar()
        await calendar.setAmbiguousRecovery(true)
        let engine = makeSyncEngine(registry: registry, calendar: calendar)
        let receipt = try await engine.registryFirstCreate(syncRequest())
        try expect(!receipt.succeeded)
        try expect(receipt.stageAfter == .conflict)
        try expect(await calendar.createdCount() == 0)
    }

    await test("CR10 degraded registry identity lookup refuses creation") {
        let registry = SyncTestRegistry()
        await registry.setLookupSource(.staleCache)
        let calendar = SyncTestCalendar()
        let engine = makeSyncEngine(registry: registry, calendar: calendar)
        let receipt = try await engine.registryFirstCreate(syncRequest())
        try expect(!receipt.succeeded)
        try expect(receipt.discrepancy?.contains("not live") == true)
        try expect(await registry.createdCount() == 0)
        try expect(await calendar.createdCount() == 0)
    }

    await test("CR11 date ranges preserve start, end, and timezone") {
        let property: [String: Any] = [
            "date": [
                "start": "2027-01-15T08:00:00-06:00",
                "end": "2027-01-15T09:00:00-06:00",
                "time_zone": "America/Chicago"
            ]
        ]
        let decoded = RegistryPropertyCodec.decode(type: "date", property: property)
        guard case .object(let range) = decoded else {
            throw TestError.assertion("date range did not decode as an object")
        }
        try expect(range["start"] == .string("2027-01-15T08:00:00-06:00"))
        try expect(range["end"] == .string("2027-01-15T09:00:00-06:00"))
        try expect(range["timeZone"] == .string("America/Chicago"))
    }

    await test("CR12 Notion adapter uses filtered identity lookup beyond list caps") {
        let gateway = SyncRegistryGateway()
        let entity = scheduleEntityForSyncTests()
        let store = NotionTimeInstanceRegistryStore(entity: entity, gateway: gateway)
        let record = TimeInstanceRecord(
            title: "LIFT", scheduledStart: syncRequest().start,
            scheduledEnd: syncRequest().end, timeZoneIdentifier: "America/Chicago",
            syncKey: "target-key", semantics: syncRequest().semantics,
            schedulingAuthority: .registry, syncState: .pendingCreate,
            registryUpdatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let created = try await store.create(record)
        let found = try await store.findBySyncKey("target-key")
        try expect(found.source == .live)
        try expect(found.records.map(\.id) == [created.id])
        try expect(await gateway.filteredQueryCalls == 1)
    }

    await test("CR13 Notion adapter emits explicit clears for nullable fields") {
        let gateway = SyncRegistryGateway()
        let entity = scheduleEntityForSyncTests()
        let store = NotionTimeInstanceRegistryStore(entity: entity, gateway: gateway)
        var record = TimeInstanceRecord(
            id: "existing", title: "LIFT", scheduledStart: syncRequest().start,
            scheduledEnd: syncRequest().end, timeZoneIdentifier: "America/Chicago",
            syncKey: "clear-key", semantics: syncRequest().semantics,
            schedulingAuthority: .registry, syncState: .error,
            registryUpdatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastSyncError: "old error"
        )
        _ = try await gateway.create(dataSourceId: "events-ds", workspace: nil, fields: [
            BoundField(propertyId: "property-0", notionName: "EVENT TITLE", type: "title", value: .string("LIFT"), isTitle: true)
        ])
        record.notes = nil
        record.location = nil
        record.lastSyncError = nil
        _ = try await store.save(record)
        let fields = await gateway.updatedFields()
        let values = Dictionary(uniqueKeysWithValues: fields.map { ($0.notionName, $0.value) })
        try expect(values["Description"] == .null)
        try expect(values["Calendar Location"] == .null)
        try expect(values["Last Sync Error"] == .null)
    }

    await test("CR14 partial Notion create exposes the created page identity") {
        let gateway = SyncRegistryGateway()
        await gateway.setFailUpdate(true)
        let store = NotionTimeInstanceRegistryStore(
            entity: scheduleEntityForSyncTests(), gateway: gateway
        )
        let record = TimeInstanceRecord(
            title: "LIFT", scheduledStart: syncRequest().start,
            scheduledEnd: syncRequest().end, timeZoneIdentifier: "America/Chicago",
            syncKey: "partial-key", semantics: syncRequest().semantics,
            schedulingAuthority: .registry, syncState: .pendingCreate,
            registryUpdatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        do {
            _ = try await store.create(record)
            throw TestError.assertion("expected partial create failure")
        } catch let error as PartialRegistryCreateError {
            try expect(!error.pageId.isEmpty)
        }
    }

    await test("CR15 internal composition is disabled by default and validates bindings") {
        let entity = scheduleEntityForSyncTests()
        let gateway = SyncRegistryGateway()
        do {
            _ = try CalendarRegistrySyncComposition.build(
                entity: entity, registryGateway: gateway,
                calendarStore: MockCalendarStore(), environment: [:]
            )
            throw TestError.assertion("composition should be disabled")
        } catch CalendarRegistrySyncCompositionError.disabled {
            // expected
        }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("calendar-composition-\(UUID().uuidString)")
        _ = try CalendarRegistrySyncComposition.build(
            entity: entity, registryGateway: gateway,
            calendarStore: MockCalendarStore(),
            environment: [CalendarRegistrySyncComposition.enableEnvironmentKey: "1"],
            journalURL: directory.appendingPathComponent("journal.json")
        )
    }

    await test("CR16 route ownership remains explicit") {
        try expect(CalendarRegistryRouteClassifier.owner(for: .semanticScheduling) == .timeKeepr)
        try expect(CalendarRegistryRouteClassifier.owner(for: .calendarMechanics) == .macKeepr)
        try expect(CalendarRegistryRouteClassifier.owner(for: .schemaChange) == .notionKeepr)
    }
}
