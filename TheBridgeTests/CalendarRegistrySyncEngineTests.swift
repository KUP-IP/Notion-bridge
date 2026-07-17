// CalendarRegistrySyncEngineTests.swift — registry-first recovery contract

import Foundation
import MCP
import SQLite3
import TheBridgeLib

private enum SyncTestError: Error, LocalizedError {
    case forcedCalendarCreate
    case forcedRegistrySave
    case forcedVerificationMiss
    case forcedLedgerSave

    var errorDescription: String? {
        switch self {
        case .forcedCalendarCreate: return "forced calendar create failure"
        case .forcedRegistrySave: return "forced registry save failure"
        case .forcedVerificationMiss: return "forced verification miss"
        case .forcedLedgerSave: return "forced ledger save failure"
        }
    }
}

private actor SyncTestRegistry: TimeInstanceRegistryStoring {
    private var records: [String: TimeInstanceRecord] = [:]
    private var partialByKey: [String: (id: String, fingerprint: String)] = [:]
    private var identityOverrides: [String: RegistryRecordIdentityRead] = [:]
    private var sequence = 0
    private var failNextCreatePatch = false
    private var failAllSaves = false
    private var lookupSource: RegistryLookupSource = .live
    private var dropFinalSyncHash = false
    private(set) var createCount = 0

    func setFailNextCreatePatch(_ value: Bool) { failNextCreatePatch = value }
    func setFailAllSaves(_ value: Bool) { failAllSaves = value }
    func setLookupSource(_ source: RegistryLookupSource) { lookupSource = source }
    func setDropFinalSyncHash(_ value: Bool) { dropFinalSyncHash = value }
    func put(_ record: TimeInstanceRecord) { records[record.id] = record }
    func setIdentityOverride(id: String, value: RegistryRecordIdentityRead?) { identityOverrides[id] = value }
    func count() -> Int { records.count + partialByKey.count }
    func createdCount() -> Int { createCount }
    func allRecords() -> [TimeInstanceRecord] { Array(records.values) }
    func record(for key: String) -> TimeInstanceRecord? { records.values.first { $0.syncKey == key } }

    func findBySyncKey(_ syncKey: String) async throws -> RegistryIdentityLookup {
        RegistryIdentityLookup(
            records: records.values.filter { $0.syncKey == syncKey },
            unresolvedIdentities: partialByKey[syncKey].map {
                [RegistryUnresolvedIdentity(pageId: $0.id, syncKey: syncKey, operationFingerprint: $0.fingerprint)]
            } ?? [],
            source: lookupSource
        )
    }

    func readIdentity(id: String, forceRefresh: Bool) async throws -> RegistryRecordIdentityRead {
        _ = forceRefresh
        if let override = identityOverrides[id] { return override }
        if let record = records[id] { return .decoded(record) }
        if let partial = partialByKey.first(where: { $0.value.id == id }) {
            return .partial(pageId: id, syncKey: partial.key, operationFingerprint: partial.value.fingerprint)
        }
        return .missing
    }

    func get(id: String, forceRefresh: Bool) async throws -> TimeInstanceRecord? {
        if case .decoded(let record) = try await readIdentity(id: id, forceRefresh: forceRefresh) { return record }
        return nil
    }

    func create(_ record: TimeInstanceRecord) async throws -> TimeInstanceRecord {
        sequence += 1
        createCount += 1
        let id = "notion-event-\(sequence)"
        if failNextCreatePatch {
            failNextCreatePatch = false
            partialByKey[record.syncKey] = (id, record.operationFingerprint)
            throw PartialRegistryCreateError(pageId: id, message: "forced semantic PATCH failure")
        }
        var created = record
        created.id = id
        records[id] = created
        return created
    }

    func repair(id: String, from record: TimeInstanceRecord) async throws -> TimeInstanceRecord {
        var repaired = record
        repaired.id = id
        partialByKey[record.syncKey] = nil
        identityOverrides[id] = nil
        records[id] = repaired
        return repaired
    }

    func save(_ record: TimeInstanceRecord) async throws -> TimeInstanceRecord {
        if failAllSaves { throw SyncTestError.forcedRegistrySave }
        var saved = record
        if dropFinalSyncHash && saved.syncState == .synced { saved.syncHash = "" }
        records[saved.id] = saved
        return saved
    }

    func mutateCalendarRange(key: String, start: Date, end: Date) {
        guard let id = records.first(where: { $0.value.syncKey == key })?.key else { return }
        records[id]?.scheduledStart = start
        records[id]?.scheduledEnd = end
    }
}

private actor SyncTestCalendar: CalendarSyncProviding {
    private var items: [String: ExternalCalendarItem] = [:]
    private var sequence = 0
    private var qualified = true
    private var failNextCreate = false
    private var nextShape: (recurring: Bool, allDay: Bool, detached: Bool) = (false, false, false)
    private(set) var createCount = 0

    func setQualified(_ value: Bool) { qualified = value }
    func setFailNextCreate(_ value: Bool) { failNextCreate = value }
    func setNextShape(recurring: Bool = false, allDay: Bool = false, detached: Bool = false) {
        nextShape = (recurring, allDay, detached)
    }
    func createdCount() -> Int { createCount }
    func count() -> Int { items.count }
    func allItems() -> [ExternalCalendarItem] { Array(items.values) }

    func qualify(calendarId: String) async throws -> CalendarQualification {
        CalendarQualification(
            calendarId: calendarId,
            title: "Private Smoke",
            allowsModify: qualified,
            explicitlyAllowlisted: qualified,
            calendarType: qualified ? "local" : "caldav",
            sourceType: qualified ? "local" : "caldav",
            qualifiedForPrivateSmoke: qualified
        )
    }

    func create(_ draft: ExternalCalendarDraft) async throws -> ExternalCalendarItem {
        if failNextCreate {
            failNextCreate = false
            throw SyncTestError.forcedCalendarCreate
        }
        sequence += 1
        createCount += 1
        let id = "calendar-event-\(sequence)"
        let shape = nextShape
        nextShape = (false, false, false)
        let item = ExternalCalendarItem(
            provider: "Fixture Calendar",
            calendarId: draft.calendarId,
            localEventId: id,
            providerExternalId: "provider-\(sequence)",
            syncKey: draft.syncKey,
            operationFingerprint: draft.operationFingerprint,
            title: draft.title,
            start: draft.start,
            end: draft.end,
            timeZoneIdentifier: draft.timeZoneIdentifier,
            location: draft.location,
            notes: draft.notes,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            isRecurring: shape.recurring,
            isAllDay: shape.allDay,
            isDetached: shape.detached
        )
        items[id] = item
        return item
    }

    func item(id: String) async throws -> ExternalCalendarItem? { items[id] }

    func recover(_ query: CalendarRecoveryQuery) async throws -> [ExternalCalendarItem] {
        if let id = query.localEventId, let direct = items[id] { return [direct] }
        let byIdentity = items.values.filter {
            $0.syncKey == query.syncKey && $0.operationFingerprint == query.operationFingerprint
        }
        if !byIdentity.isEmpty { return Array(byIdentity) }
        if let external = query.providerExternalId {
            let byExternal = items.values.filter { $0.providerExternalId == external }
            if !byExternal.isEmpty { return Array(byExternal) }
        }
        return items.values.filter {
            $0.calendarId == query.calendarId && $0.title == query.title
                && $0.start == query.start && $0.end == query.end
        }
    }

    func mutateStart(id: String, start: Date, end: Date) {
        items[id]?.start = start
        items[id]?.end = end
    }

    func duplicateIdentity(from id: String) {
        guard var copy = items[id] else { return }
        copy.localEventId = id + "-duplicate"
        items[copy.localEventId] = copy
    }
}


private actor AsyncTestLatch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !opened else { return }
        opened = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor PausingRegistry: TimeInstanceRegistryStoring {
    let base: SyncTestRegistry
    let entered: AsyncTestLatch
    let release: AsyncTestLatch
    private var hasPaused = false

    init(base: SyncTestRegistry, entered: AsyncTestLatch, release: AsyncTestLatch) {
        self.base = base
        self.entered = entered
        self.release = release
    }

    func findBySyncKey(_ syncKey: String) async throws -> RegistryIdentityLookup {
        if !hasPaused {
            hasPaused = true
            await entered.open()
            await release.wait()
        }
        return try await base.findBySyncKey(syncKey)
    }
    func readIdentity(id: String, forceRefresh: Bool) async throws -> RegistryRecordIdentityRead {
        try await base.readIdentity(id: id, forceRefresh: forceRefresh)
    }
    func get(id: String, forceRefresh: Bool) async throws -> TimeInstanceRecord? {
        try await base.get(id: id, forceRefresh: forceRefresh)
    }
    func create(_ record: TimeInstanceRecord) async throws -> TimeInstanceRecord { try await base.create(record) }
    func repair(id: String, from record: TimeInstanceRecord) async throws -> TimeInstanceRecord { try await base.repair(id: id, from: record) }
    func save(_ record: TimeInstanceRecord) async throws -> TimeInstanceRecord { try await base.save(record) }
}


private actor PausingCalendarBeforeCreate: CalendarSyncProviding {
    private let base = SyncTestCalendar()
    let entered = AsyncTestLatch()
    let release = AsyncTestLatch()
    private var paused = false

    func qualify(calendarId: String) async throws -> CalendarQualification { try await base.qualify(calendarId: calendarId) }
    func create(_ draft: ExternalCalendarDraft) async throws -> ExternalCalendarItem { try await base.create(draft) }
    func item(id: String) async throws -> ExternalCalendarItem? { try await base.item(id: id) }
    func recover(_ query: CalendarRecoveryQuery) async throws -> [ExternalCalendarItem] {
        if !paused {
            paused = true
            await entered.open()
            await release.wait()
        }
        return try await base.recover(query)
    }
    func createdCount() async -> Int { await base.createdCount() }
}

private actor PostEffectCancellingCalendar: CalendarSyncProviding {
    private let base = SyncTestCalendar()
    let created = AsyncTestLatch()

    func qualify(calendarId: String) async throws -> CalendarQualification { try await base.qualify(calendarId: calendarId) }
    func create(_ draft: ExternalCalendarDraft) async throws -> ExternalCalendarItem {
        let item = try await base.create(draft)
        await created.open()
        try await Task.sleep(nanoseconds: 10_000_000_000)
        return item
    }
    func item(id: String) async throws -> ExternalCalendarItem? { try await base.item(id: id) }
    func recover(_ query: CalendarRecoveryQuery) async throws -> [ExternalCalendarItem] { try await base.recover(query) }
    func count() async -> Int { await base.count() }
}

private func seedTransaction(
    _ store: any CalendarRegistryTransactionStoring,
    request: RegistryFirstTimeInstanceRequest,
    registryEventId: String
) async throws {
    var tx = try await store.claim(
        idempotencyKey: request.idempotencyKey,
        manifestFingerprint: request.manifest.fingerprint,
        operationId: "seed-operation",
        leaseOwner: "seed-owner",
        leaseToken: "seed-token",
        leaseDuration: 600
    )
    tx.registryEventId = registryEventId
    tx.stage = .registryCreated
    tx = try await store.save(tx)
    _ = try await store.release(tx)
}

private actor AlwaysFailingTransactionStore: CalendarRegistryTransactionStoring {
    private var transaction: CalendarRegistryTransaction?

    func claim(
        idempotencyKey: String,
        manifestFingerprint: String,
        operationId: String,
        leaseOwner: String,
        leaseToken: String,
        leaseDuration: TimeInterval
    ) async throws -> CalendarRegistryTransaction {
        if let transaction { return transaction }
        let now = Date()
        let created = CalendarRegistryTransaction(
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
        transaction = created
        return created
    }

    func renew(_ transaction: CalendarRegistryTransaction, leaseDuration: TimeInterval) async throws -> CalendarRegistryTransaction {
        _ = leaseDuration
        throw SyncTestError.forcedLedgerSave
    }

    func get(idempotencyKey: String) async throws -> CalendarRegistryTransaction? {
        guard transaction?.idempotencyKey == idempotencyKey else { return nil }
        return transaction
    }

    func save(_ transaction: CalendarRegistryTransaction) async throws -> CalendarRegistryTransaction {
        throw SyncTestError.forcedLedgerSave
    }

    func release(_ transaction: CalendarRegistryTransaction) async throws -> CalendarRegistryTransaction {
        throw SyncTestError.forcedLedgerSave
    }
}

private func syncRequest(
    key: String = "operation-lift-2027-01-15",
    title: String = "LIFT",
    start: Date = Date(timeIntervalSince1970: 1_800_010_000),
    end: Date = Date(timeIntervalSince1970: 1_800_013_600),
    timeZone: String = "America/Chicago",
    calendarId: String = "cal-private"
) -> RegistryFirstTimeInstanceRequest {
    RegistryFirstTimeInstanceRequest(
        idempotencyKey: key,
        title: title,
        start: start,
        end: end,
        timeZoneIdentifier: timeZone,
        calendarId: calendarId,
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
    registry: any TimeInstanceRegistryStoring = SyncTestRegistry(),
    calendar: any CalendarSyncProviding = SyncTestCalendar(),
    transactions: any CalendarRegistryTransactionStoring = InMemoryCalendarRegistryTransactionStore(),
    operationGate: CalendarRegistryOperationGate = CalendarRegistryOperationGate()
) -> CalendarRegistrySyncEngine {
    CalendarRegistrySyncEngine(
        registry: registry,
        calendar: calendar,
        transactions: transactions,
        operationGate: operationGate,
        clock: { Date(timeIntervalSince1970: 1_800_000_000) },
        makeOperationId: { UUID().uuidString.lowercased() },
        makeLeaseToken: { UUID().uuidString.lowercased() },
        leaseDuration: 600
    )
}

private func withTempDirectory(_ body: (URL) async throws -> Void) async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("bridge-calendar-sync-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory)
}

// MARK: - Notion adapter fixture

private actor SyncRegistryGateway: RegistryNotionGateway {
    nonisolated var supportsAuthoritativeFiltering: Bool { true }
    var pages: [String: NotionRow] = [:]
    var failUpdate = false
    var failCreateResponseAfterPersist = false
    var filteredQueryCalls = 0
    private var sequence = 0
    private(set) var lastCreatedFields: [BoundField] = []
    private(set) var lastUpdatedFields: [BoundField] = []

    func setFailUpdate(_ value: Bool) { failUpdate = value }
    func setFailCreateResponseAfterPersist(_ value: Bool) { failCreateResponseAfterPersist = value }
    func pageCount() -> Int { pages.count }
    func createdFields() -> [BoundField] { lastCreatedFields }

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
        lastCreatedFields = fields
        let row = Self.row(id: id, existing: nil, fields: fields)
        pages[id] = row
        if failCreateResponseAfterPersist {
            failCreateResponseAfterPersist = false
            throw RegistryGatewayError.invalidResponse("simulated malformed create response after remote success")
        }
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
            id: id,
            url: "https://notion.fixture/\(id)",
            lastEditedTime: "2027-01-15T08:00:00.000Z",
            cells: cells
        )
    }
}

private func scheduleEntityForSyncTests() -> RegistryEntity {
    let definitions: [(String, String, String, RegistryPropertyRole)] = [
        ("title", "EVENT TITLE", "title", .title),
        ("date", "EVENT DATE", "date", .date),
        ("status", "Status", "status", .status),
        ("syncKey", "Sync Key", "rich_text", .generic),
        ("operationFingerprint", "Operation Fingerprint", "rich_text", .generic),
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
        key: "schedule",
        displayName: "EVENTS",
        dataSourceId: "events-ds",
        properties: definitions.enumerated().map { index, item in
            RegistryProperty(
                key: item.0,
                notionName: item.1,
                notionPropertyId: "property-\(index)",
                type: item.2,
                role: item.3
            )
        },
        cacheTTLSeconds: 0
    )
}

private func testRecord(key: String = "adapter-key") -> TimeInstanceRecord {
    let request = syncRequest(key: key)
    return TimeInstanceRecord(
        title: request.title,
        scheduledStart: request.start,
        scheduledEnd: request.end,
        timeZoneIdentifier: request.timeZoneIdentifier,
        location: request.location,
        notes: request.notes,
        syncKey: request.idempotencyKey,
        operationFingerprint: request.manifest.fingerprint,
        semantics: request.semantics,
        schedulingAuthority: .registry,
        syncState: .pendingCreate,
        registryUpdatedAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
}

func runCalendarRegistrySyncEngineTests() async {
    print("\n🗓 Calendar–Registry Sync — recovery hardening")

    await test("CR1 SQLite ledger survives independent handles") {
        try await withTempDirectory { directory in
            let url = directory.appendingPathComponent("ledger.sqlite3")
            let first = try SQLiteCalendarRegistryTransactionStore(url: url)
            let created = try await first.claim(
                idempotencyKey: "same-key",
                manifestFingerprint: "fingerprint-a",
                operationId: "op-1",
                leaseOwner: "worker-1", leaseToken: "token-1", leaseDuration: 600
            )
            var updated = created
            updated.stage = .calendarCreated
            updated.calendarEventId = "event-1"
            _ = try await first.save(updated)

            let second = try SQLiteCalendarRegistryTransactionStore(url: url)
            let loaded = try await second.get(idempotencyKey: "same-key")
            try expect(loaded?.stage == .calendarCreated)
            try expect(loaded?.calendarEventId == "event-1")
        }
    }

    await test("CR2 SQLite unique key rejects a different manifest across handles") {
        try await withTempDirectory { directory in
            let url = directory.appendingPathComponent("ledger.sqlite3")
            let first = try SQLiteCalendarRegistryTransactionStore(url: url)
            let second = try SQLiteCalendarRegistryTransactionStore(url: url)
            _ = try await first.claim(
                idempotencyKey: "same-key",
                manifestFingerprint: "fingerprint-a",
                operationId: "op-a",
                leaseOwner: "worker-a", leaseToken: "token-a", leaseDuration: 600
            )
            do {
                _ = try await second.claim(
                    idempotencyKey: "same-key",
                    manifestFingerprint: "fingerprint-b",
                    operationId: "op-b",
                    leaseOwner: "worker-b", leaseToken: "token-b", leaseDuration: 600
                )
                throw TestError.assertion("expected idempotency conflict")
            } catch CalendarRegistryTransactionStoreError.idempotencyConflict("same-key") {
                // expected
            }
        }
    }

    await test("CR3 concurrent different-key SQLite writes preserve all rows") {
        try await withTempDirectory { directory in
            let url = directory.appendingPathComponent("ledger.sqlite3")
            let first = try SQLiteCalendarRegistryTransactionStore(url: url)
            let second = try SQLiteCalendarRegistryTransactionStore(url: url)
            async let a = first.claim(
                idempotencyKey: "key-a", manifestFingerprint: "fp-a",
                operationId: "op-a", leaseOwner: "worker-a", leaseToken: "token-a", leaseDuration: 600
            )
            async let b = second.claim(
                idempotencyKey: "key-b", manifestFingerprint: "fp-b",
                operationId: "op-b", leaseOwner: "worker-b", leaseToken: "token-b", leaseDuration: 600
            )
            _ = try await [a, b]
            try expect(try await first.get(idempotencyKey: "key-a") != nil)
            try expect(try await second.get(idempotencyKey: "key-b") != nil)
        }
    }

    await test("CR4 ten retries create one pair") {
        let registry = SyncTestRegistry()
        let calendar = SyncTestCalendar()
        let engine = makeSyncEngine(registry: registry, calendar: calendar)
        for _ in 0..<10 {
            let receipt = try await engine.registryFirstCreate(syncRequest())
            try expect(receipt.succeeded)
        }
        try expect(await registry.createdCount() == 1)
        try expect(await calendar.createdCount() == 1)
    }

    await test("CR5 partial Notion create repairs one page on retry") {
        let registry = SyncTestRegistry()
        await registry.setFailNextCreatePatch(true)
        let calendar = SyncTestCalendar()
        let transactions = InMemoryCalendarRegistryTransactionStore()
        let engine = makeSyncEngine(registry: registry, calendar: calendar, transactions: transactions)
        let first = try await engine.registryFirstCreate(syncRequest())
        try expect(!first.succeeded)
        let second = try await engine.registryFirstCreate(syncRequest())
        try expect(second.succeeded)
        try expect(await registry.count() == 1)
        try expect(await registry.createdCount() == 1)
        try expect(await calendar.createdCount() == 1)
    }

    await test("CR6 ledger loss reconstructs the same manifest from external fingerprints") {
        let registry = SyncTestRegistry()
        let calendar = SyncTestCalendar()
        let first = makeSyncEngine(registry: registry, calendar: calendar)
        try expect(try await first.registryFirstCreate(syncRequest()).succeeded)
        let restarted = makeSyncEngine(
            registry: registry,
            calendar: calendar,
            transactions: InMemoryCalendarRegistryTransactionStore()
        )
        let receipt = try await restarted.registryFirstCreate(syncRequest())
        try expect(receipt.succeeded)
        try expect(await registry.createdCount() == 1)
        try expect(await calendar.createdCount() == 1)
    }

    await test("CR7 ledger loss plus different manifest conflicts") {
        let registry = SyncTestRegistry()
        let calendar = SyncTestCalendar()
        try expect(try await makeSyncEngine(registry: registry, calendar: calendar)
            .registryFirstCreate(syncRequest()).succeeded)
        let restarted = makeSyncEngine(
            registry: registry,
            calendar: calendar,
            transactions: InMemoryCalendarRegistryTransactionStore()
        )
        let receipt = try await restarted.registryFirstCreate(syncRequest(title: "Different"))
        try expect(!receipt.succeeded)
        try expect(receipt.stageAfter == .conflict)
        try expect(await registry.createdCount() == 1)
        try expect(await calendar.createdCount() == 1)
    }

    await test("CR8 calendar drift conflicts without overwriting registry schedule") {
        let registry = SyncTestRegistry()
        let calendar = SyncTestCalendar()
        let engine = makeSyncEngine(registry: registry, calendar: calendar)
        let first = try await engine.registryFirstCreate(syncRequest())
        guard let id = first.calendarItem?.localEventId else {
            throw TestError.assertion("calendar item missing")
        }
        let driftedStart = syncRequest().start.addingTimeInterval(7_200)
        let driftedEnd = syncRequest().end.addingTimeInterval(7_200)
        await calendar.mutateStart(id: id, start: driftedStart, end: driftedEnd)
        let receipt = try await engine.registryFirstCreate(syncRequest())
        try expect(!receipt.succeeded)
        try expect(receipt.stageAfter == .conflict)
        let record = await registry.record(for: syncRequest().idempotencyKey)
        try expect(record?.scheduledStart == syncRequest().start)
        try expect(record?.scheduledEnd == syncRequest().end)
    }

    await test("CR9 non-local timezone survives full transaction") {
        let request = syncRequest(timeZone: "Pacific/Honolulu")
        let receipt = try await makeSyncEngine().registryFirstCreate(request)
        try expect(receipt.succeeded)
        try expect(receipt.record?.timeZoneIdentifier == "Pacific/Honolulu")
        try expect(receipt.calendarItem?.timeZoneIdentifier == "Pacific/Honolulu")
    }

    await test("CR10 invalid timezone and injected keys are rejected before writes") {
        let registry = SyncTestRegistry()
        let calendar = SyncTestCalendar()
        let engine = makeSyncEngine(registry: registry, calendar: calendar)
        do {
            _ = try await engine.registryFirstCreate(syncRequest(timeZone: "Mars/Olympus"))
            throw TestError.assertion("invalid timezone should fail")
        } catch CalendarRegistrySyncError.invalidTimeZone("Mars/Olympus") {}
        do {
            _ = try await engine.registryFirstCreate(syncRequest(key: "bad\nkey"))
            throw TestError.assertion("invalid key should fail")
        } catch CalendarRegistrySyncError.invalidIdempotencyKey {}
        try expect(await registry.count() == 0)
        try expect(await calendar.count() == 0)
    }

    await test("CR11 recurring, all-day, and detached items fail closed") {
        for shape in [(true, false, false), (false, true, false), (false, false, true)] {
            let registry = SyncTestRegistry()
            let calendar = SyncTestCalendar()
            await calendar.setNextShape(recurring: shape.0, allDay: shape.1, detached: shape.2)
            let receipt = try await makeSyncEngine(registry: registry, calendar: calendar)
                .registryFirstCreate(syncRequest(key: "shape-\(shape.0)-\(shape.1)-\(shape.2)"))
            try expect(!receipt.succeeded)
            try expect(receipt.stageAfter == .conflict)
        }
    }

    await test("CR12 unqualified calendar refuses all writes") {
        let registry = SyncTestRegistry()
        let calendar = SyncTestCalendar()
        await calendar.setQualified(false)
        let receipt = try await makeSyncEngine(registry: registry, calendar: calendar)
            .registryFirstCreate(syncRequest())
        try expect(!receipt.succeeded)
        try expect(await registry.count() == 0)
        try expect(await calendar.count() == 0)
    }

    await test("CR13 unpersisted ledger failure is an infrastructure fault") {
        let registry = SyncTestRegistry()
        let calendar = SyncTestCalendar()
        let receipt = try await makeSyncEngine(
            registry: registry,
            calendar: calendar,
            transactions: AlwaysFailingTransactionStore()
        ).registryFirstCreate(syncRequest())
        try expect(!receipt.succeeded)
        try expect(receipt.infrastructureFault)
        try expect(!receipt.recoveryStatePersisted)
        try expect(receipt.recoveryAction?.contains("do not retry automatically") == true)
    }

    await test("CR14 registry failure-state write is reported separately") {
        let registry = SyncTestRegistry()
        await registry.setFailAllSaves(true)
        let receipt = try await makeSyncEngine(registry: registry)
            .registryFirstCreate(syncRequest())
        try expect(!receipt.succeeded)
        try expect(receipt.recoveryStatePersisted)
        try expect(!receipt.registryFailureStatePersisted)
        try expect(receipt.discrepancy?.contains("registry failure-state write failed") == true)
    }

    await test("CR15 versioned metadata rejects duplicates and round-trips identity") {
        let identity = CalendarRegistryCalendarMetadata.Identity(
            syncKey: "safe-key",
            operationFingerprint: String(repeating: "a", count: 64)
        )
        let notes = try CalendarRegistryCalendarMetadata.append(to: "hello", identity: identity)
        try expect(try CalendarRegistryCalendarMetadata.parse(notes) == identity)
        do {
            _ = try CalendarRegistryCalendarMetadata.parse(notes + "\n" + notes)
            throw TestError.assertion("duplicate metadata should conflict")
        } catch CalendarRegistrySyncError.identityConflict {}
    }

    await test("CR16 live registry gateway advertises authoritative filtering") {
        try expect(LiveRegistryGateway().supportsAuthoritativeFiltering)
    }

    await test("CR17 strict query decoder rejects malformed or broken pagination") {
        do {
            _ = try RegistryQueryResponseDecoder.decode(Data("{}".utf8))
            throw TestError.assertion("missing results should fail")
        } catch RegistryGatewayError.invalidResponse {}
        do {
            let data = try JSONSerialization.data(withJSONObject: [
                "results": [], "has_more": true, "next_cursor": NSNull()
            ])
            _ = try RegistryQueryResponseDecoder.decode(data)
            throw TestError.assertion("missing cursor should fail")
        } catch RegistryGatewayError.invalidResponse {}
        let valid = try JSONSerialization.data(withJSONObject: [
            "results": [], "has_more": false, "next_cursor": NSNull()
        ])
        let decoded = try RegistryQueryResponseDecoder.decode(valid)
        try expect(decoded.rows.isEmpty && decoded.nextCursor == nil)
    }

    await test("CR18 Notion identity envelope contains four critical fields") {
        let gateway = SyncRegistryGateway()
        let store = NotionTimeInstanceRegistryStore(
            entity: scheduleEntityForSyncTests(), gateway: gateway
        )
        _ = try await store.create(testRecord())
        let names = Set(await gateway.createdFields().map(\.notionName))
        try expect(names == Set(["EVENT TITLE", "Sync Key", "Operation Fingerprint", "Sync State"]))
    }

    await test("CR19 real Notion adapter partial create can be found and repaired") {
        let gateway = SyncRegistryGateway()
        await gateway.setFailUpdate(true)
        let store = NotionTimeInstanceRegistryStore(
            entity: scheduleEntityForSyncTests(), gateway: gateway
        )
        let record = testRecord(key: "partial-key")
        do {
            _ = try await store.create(record)
            throw TestError.assertion("expected partial create")
        } catch let partial as PartialRegistryCreateError {
            let lookup = try await store.findBySyncKey("partial-key")
            try expect(lookup.records.isEmpty)
            try expect(lookup.unresolvedIdentities.map(\.pageId) == [partial.pageId])
            try expect(lookup.unresolvedIdentities.first?.operationFingerprint == record.operationFingerprint)
            let repaired = try await store.repair(id: partial.pageId, from: record)
            try expect(repaired.syncKey == "partial-key")
            try expect(await gateway.pageCount() == 1)
        }
    }

    await test("CR20 migration artifact decodes against registry roles") {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let url = root.appendingPathComponent("docs/migrations/calendar-registry-v1/registry-entity-patch.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        try expect(object?["schemaVersion"] as? Int == 2)
        let additions = object?["additiveProperties"] as? [[String: Any]] ?? []
        try expect(Set(additions.compactMap { $0["key"] as? String }) == Set(["providerExternalId", "operationFingerprint"]))
        for addition in additions {
            guard let role = addition["role"] as? String,
                  RegistryPropertyRole(rawValue: role) != nil else {
                throw TestError.assertion("migration role does not decode")
            }
        }
    }

    await test("CR21 composition remains disabled and requires an allowlist") {
        let entity = scheduleEntityForSyncTests()
        let gateway = SyncRegistryGateway()
        do {
            _ = try CalendarRegistrySyncComposition.build(
                entity: entity,
                registryGateway: gateway,
                calendarStore: PersistentCalendarStore(),
                environment: [:]
            )
            throw TestError.assertion("composition should be disabled")
        } catch CalendarRegistrySyncCompositionError.disabled {}
        do {
            _ = try CalendarRegistrySyncComposition.build(
                entity: entity,
                registryGateway: gateway,
                calendarStore: PersistentCalendarStore(),
                environment: [CalendarRegistrySyncComposition.enableEnvironmentKey: "1"]
            )
            throw TestError.assertion("allowlist should be required")
        } catch CalendarRegistrySyncCompositionError.missingAllowedCalendars {}
    }


    await test("CR22 same-key independent engines permit one external writer") {
        try await withTempDirectory { directory in
            let url = directory.appendingPathComponent("race.sqlite3")
            let firstStore = try SQLiteCalendarRegistryTransactionStore(url: url)
            let secondStore = try SQLiteCalendarRegistryTransactionStore(url: url)
            let baseRegistry = SyncTestRegistry()
            let entered = AsyncTestLatch()
            let release = AsyncTestLatch()
            let registry = PausingRegistry(base: baseRegistry, entered: entered, release: release)
            let calendar = SyncTestCalendar()
            let firstEngine = makeSyncEngine(registry: registry, calendar: calendar, transactions: firstStore)
            let secondEngine = makeSyncEngine(registry: registry, calendar: calendar, transactions: secondStore)

            let first = Task { try await firstEngine.registryFirstCreate(syncRequest(key: "race-key")) }
            await entered.wait()
            let second = Task { try await secondEngine.registryFirstCreate(syncRequest(key: "race-key")) }
            try await Task.sleep(nanoseconds: 50_000_000)
            await release.open()
            let receipts = try await [first.value, second.value]
            try expect(receipts.filter(\.succeeded).count == 1)
            try expect(receipts.contains { $0.discrepancy?.contains("already active") == true })
            try expect(await baseRegistry.createdCount() == 1)
            try expect(await calendar.createdCount() == 1)
        }
    }

    await test("CR23 stale revisions, fencing tokens, stage regression, and identity clearing are refused") {
        try await withTempDirectory { directory in
            let store = try SQLiteCalendarRegistryTransactionStore(url: directory.appendingPathComponent("cas.sqlite3"))
            let claimed = try await store.claim(
                idempotencyKey: "cas-key", manifestFingerprint: "fingerprint",
                operationId: "op", leaseOwner: "worker", leaseToken: "fence-a", leaseDuration: 600
            )
            var progressed = claimed
            progressed.stage = .calendarCreated
            progressed.calendarEventId = "event-1"
            let saved = try await store.save(progressed)

            var stale = claimed
            stale.stage = .registryCreated
            do { _ = try await store.save(stale); throw TestError.assertion("stale revision should fail") }
            catch CalendarRegistryTransactionStoreError.staleRevision("cas-key") {}

            var wrongFence = saved
            wrongFence.leaseToken = "fence-b"
            do { _ = try await store.save(wrongFence); throw TestError.assertion("wrong fence should fail") }
            catch CalendarRegistryTransactionStoreError.leaseLost("cas-key") {}

            var regressed = saved
            regressed.stage = .registryCreated
            do { _ = try await store.save(regressed); throw TestError.assertion("stage regression should fail") }
            catch CalendarRegistryTransactionStoreError.stageRegression {}

            var cleared = saved
            cleared.stage = .pairPersisted
            cleared.calendarEventId = nil
            do { _ = try await store.save(cleared); throw TestError.assertion("identity clearing should fail") }
            catch CalendarRegistryTransactionStoreError.identityRegression {}
        }
    }

    await test("CR24 expired lease can be fenced and resumed once") {
        try await withTempDirectory { directory in
            let url = directory.appendingPathComponent("expiry.sqlite3")
            let first = try SQLiteCalendarRegistryTransactionStore(url: url)
            let second = try SQLiteCalendarRegistryTransactionStore(url: url)
            let original = try await first.claim(
                idempotencyKey: "expiry-key", manifestFingerprint: "fingerprint",
                operationId: "op-a", leaseOwner: "worker-a", leaseToken: "token-a", leaseDuration: 0.1
            )
            try await Task.sleep(nanoseconds: 1_100_000_000)
            let resumed = try await second.claim(
                idempotencyKey: "expiry-key", manifestFingerprint: "fingerprint",
                operationId: "op-b", leaseOwner: "worker-b", leaseToken: "token-b", leaseDuration: 600
            )
            try expect(resumed.leaseToken == "token-b")
            try expect(resumed.revision > original.revision)
            do { _ = try await first.save(original); throw TestError.assertion("expired worker should be fenced") }
            catch CalendarRegistryTransactionStoreError.staleRevision("expiry-key") {}
        }
    }

    await test("CR25 canonical manifest normalizes relations, primary block, and empty optionals") {
        let requestA = RegistryFirstTimeInstanceRequest(
            idempotencyKey: "canonical-key", title: "  LIFT  ",
            start: syncRequest().start, end: syncRequest().end,
            timeZoneIdentifier: " America/Chicago ", calendarId: " cal-private ",
            location: "   ", notes: " note ",
            semantics: TimeInstanceSemantics(
                eventClass: .focus, meetingType: " ", primaryBlockId: " block-primary ",
                blockIds: ["block-b", "block-primary", "block-b"],
                projectIds: ["project-b", "project-a", "project-b"],
                contactIds: ["contact-b", "contact-a"]
            )
        ).canonicalized
        let requestB = RegistryFirstTimeInstanceRequest(
            idempotencyKey: "canonical-key", title: "LIFT",
            start: syncRequest().start, end: syncRequest().end,
            timeZoneIdentifier: "America/Chicago", calendarId: "cal-private",
            location: nil, notes: "note",
            semantics: TimeInstanceSemantics(
                eventClass: .focus, primaryBlockId: "block-primary",
                blockIds: ["block-primary", "block-b"],
                projectIds: ["project-a", "project-b"],
                contactIds: ["contact-a", "contact-b"]
            )
        ).canonicalized
        try expect(requestA == requestB)
        try expect(requestA.manifest.fingerprint == requestB.manifest.fingerprint)
        try expect(requestA.semantics.blockIds == ["block-b", "block-primary"])
        try expect(requestA.location == nil && requestA.semantics.meetingType == nil)
    }

    await test("CR26 final success verifies Sync Hash and Last Synced At") {
        let receipt = try await makeSyncEngine().registryFirstCreate(syncRequest(key: "evidence-key"))
        try expect(receipt.succeeded)
        try expect(receipt.verifiedSyncHash?.count == 64)
        try expect(receipt.record?.syncHash == receipt.verifiedSyncHash)
        try expect(receipt.record?.lastSyncedAt == receipt.verifiedAt)
        try expect(receipt.fencingToken?.isEmpty == false)
        try expect((receipt.ledgerRevision ?? 0) > 1)
    }

    await test("CR27 a dropped final Sync Hash prevents success") {
        let registry = SyncTestRegistry()
        await registry.setDropFinalSyncHash(true)
        let receipt = try await makeSyncEngine(registry: registry)
            .registryFirstCreate(syncRequest(key: "dropped-hash"))
        try expect(!receipt.succeeded)
        try expect(receipt.discrepancy?.contains("Synced evidence") == true)
    }

    await test("CR28 ledger-known matching partial page repairs; mismatched, malformed, and missing pages do not") {
        for mode in ["matching", "mismatch", "malformed", "missing"] {
            let request = syncRequest(key: "known-\(mode)")
            let registry = SyncTestRegistry()
            let calendar = SyncTestCalendar()
            let store = InMemoryCalendarRegistryTransactionStore()
            let id = "known-page-\(mode)"
            switch mode {
            case "matching":
                await registry.setIdentityOverride(id: id, value: .partial(
                    pageId: id, syncKey: request.idempotencyKey,
                    operationFingerprint: request.manifest.fingerprint
                ))
            case "mismatch":
                await registry.setIdentityOverride(id: id, value: .partial(
                    pageId: id, syncKey: request.idempotencyKey,
                    operationFingerprint: String(repeating: "b", count: 64)
                ))
            case "malformed":
                await registry.setIdentityOverride(id: id, value: .malformed(pageId: id, reason: "broken relation"))
            default:
                await registry.setIdentityOverride(id: id, value: .missing)
            }
            try await seedTransaction(store, request: request, registryEventId: id)
            let receipt = try await makeSyncEngine(registry: registry, calendar: calendar, transactions: store)
                .registryFirstCreate(request)
            if mode == "matching" {
                try expect(receipt.succeeded)
                try expect(await registry.createdCount() == 0)
                try expect(await calendar.createdCount() == 1)
            } else {
                try expect(!receipt.succeeded)
                try expect(receipt.stageAfter == .conflict)
                try expect(await registry.createdCount() == 0)
                try expect(await calendar.createdCount() == 0)
            }
        }
    }

    await test("CR29 remotely successful Notion create with invalid response recovers without duplication") {
        let gateway = SyncRegistryGateway()
        await gateway.setFailCreateResponseAfterPersist(true)
        let registry = NotionTimeInstanceRegistryStore(entity: scheduleEntityForSyncTests(), gateway: gateway)
        let calendar = SyncTestCalendar()
        let transactions = InMemoryCalendarRegistryTransactionStore()
        let engine = makeSyncEngine(registry: registry, calendar: calendar, transactions: transactions)
        let request = syncRequest(key: "uncertain-create")
        let first = try await engine.registryFirstCreate(request)
        try expect(!first.succeeded)
        let second = try await engine.registryFirstCreate(request)
        try expect(second.succeeded)
        try expect(await gateway.pageCount() == 1)
        try expect(await calendar.createdCount() == 1)
    }

    await test("CR30 strict row decoders reject malformed synchronization responses") {
        for data in [Data("{}".utf8), Data("{\"id\":\"page\"}".utf8)] {
            do {
                _ = try RegistryRowResponseDecoder.decode(data, context: "test")
                throw TestError.assertion("malformed row should fail")
            } catch RegistryGatewayError.invalidResponse {}
        }
        let malformedResult = try JSONSerialization.data(withJSONObject: [
            "results": [["id": "page-without-properties"]], "has_more": false
        ])
        do {
            _ = try RegistryQueryResponseDecoder.decode(malformedResult)
            throw TestError.assertion("malformed query row should fail")
        } catch RegistryGatewayError.invalidResponse {}
    }

    await test("CR31 identity-bearing unsupported calendar shapes conflict instead of duplicating") {
        for shape in ["recurring", "all-day", "detached", "participant"] {
            let request = syncRequest(key: "shape-existing-\(shape)")
            let store = PersistentCalendarStore()
            let identity = CalendarRegistryCalendarMetadata.Identity(
                syncKey: request.idempotencyKey,
                operationFingerprint: request.manifest.fingerprint
            )
            let notes = try CalendarRegistryCalendarMetadata.append(to: request.notes, identity: identity)
            await store.seed(CalendarEvent(
                id: "existing-\(shape)", title: request.title,
                start: CalendarRegistryISO.string(request.start), end: CalendarRegistryISO.string(request.end),
                allDay: shape == "all-day", calendarId: request.calendarId,
                calendarTitle: "Private Smoke", location: request.location, notes: notes,
                timeZoneIdentifier: request.timeZoneIdentifier, externalId: "external-\(shape)",
                organizer: shape == "participant" ? "owner@example.com" : nil,
                attendees: shape == "participant" ? ["person@example.com"] : [],
                lastModified: CalendarRegistryISO.string(Date()),
                isRecurring: shape == "recurring", isDetached: shape == "detached"
            ))
            let provider = CalendarStoringSyncProvider(store: store, allowlistedCalendarIds: [request.calendarId])
            let receipt = try await makeSyncEngine(registry: SyncTestRegistry(), calendar: provider)
                .registryFirstCreate(request)
            try expect(!receipt.succeeded)
            try expect(receipt.stageAfter == .conflict)
            try expect(await store.count() == 1)
        }
    }

    await test("CR32 unrelated malformed calendar metadata does not poison target recovery") {
        let request = syncRequest(key: "target-metadata")
        let store = PersistentCalendarStore()
        await store.seed(CalendarEvent(
            id: "unrelated", title: "Other", start: CalendarRegistryISO.string(request.start),
            end: CalendarRegistryISO.string(request.end), allDay: false,
            calendarId: request.calendarId, calendarTitle: "Private Smoke", location: nil,
            notes: CalendarRegistryCalendarMetadata.beginMarker + "\ninvalid",
            timeZoneIdentifier: request.timeZoneIdentifier
        ))
        let identity = CalendarRegistryCalendarMetadata.Identity(
            syncKey: request.idempotencyKey, operationFingerprint: request.manifest.fingerprint
        )
        await store.seed(CalendarEvent(
            id: "target", title: request.title, start: CalendarRegistryISO.string(request.start),
            end: CalendarRegistryISO.string(request.end), allDay: false,
            calendarId: request.calendarId, calendarTitle: "Private Smoke", location: request.location,
            notes: try CalendarRegistryCalendarMetadata.append(to: request.notes, identity: identity),
            timeZoneIdentifier: request.timeZoneIdentifier, externalId: "target-external"
        ))
        let provider = CalendarStoringSyncProvider(store: store, allowlistedCalendarIds: [request.calendarId])
        let recovered = try await provider.recover(CalendarRecoveryQuery(
            syncKey: request.idempotencyKey, operationFingerprint: request.manifest.fingerprint,
            calendarId: request.calendarId, title: request.title, start: request.start, end: request.end
        ))
        try expect(recovered.map(\.localEventId) == ["target"])
    }

    await test("CR33 invalid partial-effect JSON is ledger corruption") {
        try await withTempDirectory { directory in
            let url = directory.appendingPathComponent("corrupt.sqlite3")
            let store = try SQLiteCalendarRegistryTransactionStore(url: url)
            _ = try await store.claim(
                idempotencyKey: "corrupt-key", manifestFingerprint: "fingerprint",
                operationId: "op", leaseOwner: "worker", leaseToken: "token", leaseDuration: 600
            )
            var db: OpaquePointer?
            try expect(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK)
            defer { if let db { sqlite3_close_v2(db) } }
            try expect(sqlite3_exec(db, "UPDATE calendar_registry_transactions SET partial_effects_json='not-json' WHERE idempotency_key='corrupt-key';", nil, nil, nil) == SQLITE_OK)
            do {
                _ = try await store.get(idempotencyKey: "corrupt-key")
                throw TestError.assertion("corrupt effects should fail")
            } catch CalendarRegistryTransactionStoreError.corruptLedger {}
        }
    }

    await test("CR34 cancelled gate waiter never acquires later") {
        let gate = CalendarRegistryOperationGate()
        try await gate.acquire("cancel-key")
        let waiter = Task { try await gate.acquire("cancel-key") }
        try await Task.sleep(nanoseconds: 20_000_000)
        waiter.cancel()
        await gate.release("cancel-key")
        do { try await waiter.value; throw TestError.assertion("cancelled waiter should fail") }
        catch is CancellationError {}
        try await gate.acquire("cancel-key")
        await gate.release("cancel-key")
    }

    await test("CR35 cancellation before Notion create produces no external write") {
        let base = SyncTestRegistry()
        let entered = AsyncTestLatch()
        let release = AsyncTestLatch()
        let registry = PausingRegistry(base: base, entered: entered, release: release)
        let calendar = SyncTestCalendar()
        let engine = makeSyncEngine(registry: registry, calendar: calendar)
        let task = Task { try await engine.registryFirstCreate(syncRequest(key: "cancel-before-create")) }
        await entered.wait()
        task.cancel()
        await release.open()
        let receipt = try await task.value
        try expect(!receipt.succeeded)
        try expect(await base.createdCount() == 0)
        try expect(await calendar.createdCount() == 0)
    }

    await test("CR36 cancellation after calendar side effect persists recovery evidence") {
        let registry = SyncTestRegistry()
        let calendar = PostEffectCancellingCalendar()
        let engine = makeSyncEngine(registry: registry, calendar: calendar)
        let task = Task { try await engine.registryFirstCreate(syncRequest(key: "cancel-after-calendar")) }
        await calendar.created.wait()
        task.cancel()
        let receipt = try await task.value
        try expect(!receipt.succeeded)
        try expect(receipt.recoveryStatePersisted)
        try expect(await calendar.count() == 1)
    }


    await test("CR37 cancellation before EventKit create produces no calendar write") {
        let registry = SyncTestRegistry()
        let calendar = PausingCalendarBeforeCreate()
        let engine = makeSyncEngine(registry: registry, calendar: calendar)
        let task = Task { try await engine.registryFirstCreate(syncRequest(key: "cancel-before-calendar")) }
        await calendar.entered.wait()
        task.cancel()
        await calendar.release.open()
        let receipt = try await task.value
        try expect(!receipt.succeeded)
        try expect(receipt.recoveryStatePersisted)
        try expect(await registry.createdCount() == 1)
        try expect(await calendar.createdCount() == 0)
    }

    await test("CR38 target-related malformed calendar metadata conflicts") {
        let request = syncRequest(key: "target-malformed")
        let store = PersistentCalendarStore()
        await store.seed(CalendarEvent(
            id: "target-malformed-event", title: request.title,
            start: CalendarRegistryISO.string(request.start), end: CalendarRegistryISO.string(request.end),
            allDay: false, calendarId: request.calendarId, calendarTitle: "Private Smoke",
            location: request.location,
            notes: CalendarRegistryCalendarMetadata.beginMarker + "\nSync-Key: \(request.idempotencyKey)",
            timeZoneIdentifier: request.timeZoneIdentifier
        ))
        let provider = CalendarStoringSyncProvider(store: store, allowlistedCalendarIds: [request.calendarId])
        do {
            _ = try await provider.recover(CalendarRecoveryQuery(
                syncKey: request.idempotencyKey, operationFingerprint: request.manifest.fingerprint,
                calendarId: request.calendarId, title: request.title, start: request.start, end: request.end
            ))
            throw TestError.assertion("target-related malformed metadata should conflict")
        } catch CalendarRegistrySyncError.identityConflict {}
    }

    await test("CR39 unknown future ledger schema is refused without downgrade") {
        try await withTempDirectory { directory in
            let url = directory.appendingPathComponent("future.sqlite3")
            var db: OpaquePointer?
            try expect(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
            try expect(sqlite3_exec(db, "CREATE TABLE calendar_registry_schema (id INTEGER PRIMARY KEY, version INTEGER NOT NULL); INSERT INTO calendar_registry_schema(id,version) VALUES(1,99);", nil, nil, nil) == SQLITE_OK)
            if let db { sqlite3_close_v2(db) }
            do {
                _ = try SQLiteCalendarRegistryTransactionStore(url: url)
                throw TestError.assertion("future schema should be refused")
            } catch CalendarRegistryTransactionStoreError.corruptLedger(let reason) {
                try expect(reason.contains("unsupported schema version 99"))
            }
        }
    }

    await test("CR40 route ownership remains explicit") {
        try expect(CalendarRegistryRouteClassifier.owner(for: .semanticScheduling) == .timeKeepr)
        try expect(CalendarRegistryRouteClassifier.owner(for: .calendarMechanics) == .macKeepr)
        try expect(CalendarRegistryRouteClassifier.owner(for: .schemaChange) == .notionKeepr)
    }
}

private actor PersistentCalendarStore: CalendarStoring {
    private var eventsById: [String: CalendarEvent] = [:]

    func seed(_ event: CalendarEvent) { eventsById[event.id] = event }
    func count() -> Int { eventsById.count }

    nonisolated func authorizationStatus() -> CalendarAuthStatus { .authorized }
    func ensureAccess() async throws {}
    func calendars() async throws -> [CalendarInfo] {
        [CalendarInfo(
            id: "cal-private",
            title: "Private Smoke",
            isDefault: false,
            allowsModify: true,
            calendarType: "local",
            sourceIdentifier: "source-local",
            sourceTitle: "On My Mac",
            sourceType: "local"
        )]
    }
    func events(_ query: CalendarEventQuery) async throws -> [CalendarEvent] {
        eventsById.values.filter { query.calendarId == nil || $0.calendarId == query.calendarId }
    }
    func event(id: String) async throws -> CalendarEvent? { eventsById[id] }
    func create(_ draft: CalendarEventDraft) async throws -> CalendarEvent {
        let id = "event-\(eventsById.count + 1)"
        let event = CalendarEvent(
            id: id,
            title: draft.title ?? "",
            start: draft.start ?? "",
            end: draft.end ?? "",
            allDay: draft.allDay ?? false,
            calendarId: draft.calendarId ?? "",
            calendarTitle: "Private Smoke",
            location: draft.location,
            notes: draft.notes,
            timeZoneIdentifier: draft.timeZoneIdentifier,
            externalId: "external-\(id)",
            lastModified: "2027-01-15T08:00:00Z"
        )
        eventsById[id] = event
        return event
    }
    func update(id: String, _ draft: CalendarEventDraft) async throws -> CalendarEvent {
        guard var event = eventsById[id] else { throw CalendarModuleError.notFound(id) }
        if let title = draft.title { event.title = title }
        if let start = draft.start { event.start = start }
        if let end = draft.end { event.end = end }
        if let zone = draft.timeZoneIdentifier { event.timeZoneIdentifier = zone }
        eventsById[id] = event
        return event
    }
    func delete(id: String) async throws { eventsById[id] = nil }
}
