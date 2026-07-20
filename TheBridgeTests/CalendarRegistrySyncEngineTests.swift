// CalendarRegistrySyncEngineTests.swift — forward-only registry-first pairing contract

import Foundation
import Darwin
import MCP
import SQLite3
import Synchronization
import TheBridgeLib

private enum SyncTestError: Error, LocalizedError {
    case forcedCalendarCreate
    case forcedRegistrySave
    case forcedLedgerSave
    case forcedVerificationMiss

    var errorDescription: String? {
        switch self {
        case .forcedCalendarCreate: return "forced calendar create failure"
        case .forcedRegistrySave: return "forced registry save failure"
        case .forcedLedgerSave: return "forced ledger save failure"
        case .forcedVerificationMiss: return "forced verification miss"
        }
    }
}

private actor SyncTestRegistry: TimeInstanceRegistryStoring {
    private var records: [String: TimeInstanceRecord] = [:]
    private var identityOverrides: [String: RegistryRecordIdentityRead] = [:]
    private var lookupExtras: [TimeInstanceRecord] = []
    private var lookupUnresolved: [RegistryUnresolvedIdentity] = []
    private var lookupSource: RegistryLookupSource = .live
    private var lookupCallCount = 0
    private var injectDuplicateOnLookupCall: Int?
    private var failAllSaves = false
    private var dropFinalSyncHash = false
    private var mutateProviderOnFinalRead = false
    private var mutateSyncedAtOnFinalRead = false
    private var syncedReadCount = 0
    private var revisionSequence = 1
    private(set) var saveCount = 0

    func put(_ record: TimeInstanceRecord) {
        var stored = record
        if stored.registryRevision == nil {
            stored.registryRevision = "revision-\(revisionSequence)"
            revisionSequence += 1
        }
        records[stored.id] = stored
    }
    func setIdentityOverride(id: String, value: RegistryRecordIdentityRead?) { identityOverrides[id] = value }
    func setLookupExtras(_ values: [TimeInstanceRecord]) { lookupExtras = values }
    func setLookupUnresolved(_ values: [RegistryUnresolvedIdentity]) { lookupUnresolved = values }
    func setLookupSource(_ value: RegistryLookupSource) { lookupSource = value }
    func setInjectDuplicateOnLookupCall(_ value: Int?) { injectDuplicateOnLookupCall = value }
    func mutateTitle(_ value: String) {
        guard var current = records.values.first else { return }
        current.title = value
        current.registryRevision = "revision-\(revisionSequence)"
        revisionSequence += 1
        records[current.id] = current
    }
    func setFailAllSaves(_ value: Bool) { failAllSaves = value }
    func setDropFinalSyncHash(_ value: Bool) { dropFinalSyncHash = value }
    func setMutateProviderOnFinalRead(_ value: Bool) { mutateProviderOnFinalRead = value }
    func setMutateSyncedAtOnFinalRead(_ value: Bool) { mutateSyncedAtOnFinalRead = value }
    func record(id: String) -> TimeInstanceRecord? { records[id] }
    func savedCount() -> Int { saveCount }

    func findBySyncKey(_ syncKey: String) async throws -> RegistryIdentityLookup {
        lookupCallCount += 1
        var matches = records.values.filter { $0.syncKey == syncKey }
            + lookupExtras.filter { $0.syncKey == syncKey }
        if injectDuplicateOnLookupCall == lookupCallCount, var duplicate = matches.first {
            duplicate.id += "-duplicate"
            duplicate.registryRevision = "duplicate-revision"
            matches.append(duplicate)
        }
        return RegistryIdentityLookup(
            records: matches,
            unresolvedIdentities: lookupUnresolved.filter { $0.syncKey == syncKey },
            source: lookupSource
        )
    }

    func readIdentity(id: String, forceRefresh: Bool) async throws -> RegistryRecordIdentityRead {
        _ = forceRefresh
        if let override = identityOverrides[id] { return override }
        if let record = records[id] { return .decoded(record) }
        return .missing
    }

    func get(id: String, forceRefresh: Bool) async throws -> TimeInstanceRecord? {
        _ = forceRefresh
        guard var record = records[id] else { return nil }
        if record.syncState == .synced {
            syncedReadCount += 1
            if mutateProviderOnFinalRead && syncedReadCount >= 1 {
                record.calendarProvider = "Mutated Provider"
            }
            if mutateSyncedAtOnFinalRead && syncedReadCount >= 1 {
                record.lastSyncedAt = record.lastSyncedAt?.addingTimeInterval(120)
            }
        }
        return record
    }

    func savePairing(_ record: TimeInstanceRecord, expectedRevision: String?) async throws -> TimeInstanceRecord {
        if failAllSaves { throw SyncTestError.forcedRegistrySave }
        guard var saved = records[record.id], saved.registryRevision == expectedRevision else {
            throw CalendarRegistrySyncError.identityConflict("fixture revision mismatch")
        }
        saved.calendarProvider = record.calendarProvider
        saved.calendarId = record.calendarId
        saved.calendarEventId = record.calendarEventId
        saved.providerExternalId = record.providerExternalId
        saved.calendarItemURL = record.calendarItemURL
        saved.createInvocationId = record.createInvocationId
        saved.syncWriterToken = record.syncWriterToken
        saved.syncRevision = record.syncRevision
        saved.syncState = record.syncState
        saved.registryUpdatedAt = record.registryUpdatedAt
        saved.syncHash = record.syncHash
        saved.lastSyncError = record.lastSyncError
        saved.lastSyncedAt = record.lastSyncedAt
        saved.calendarUpdatedAt = record.calendarUpdatedAt
        if dropFinalSyncHash && saved.syncState == .synced { saved.syncHash = "" }
        saved.registryRevision = "revision-\(revisionSequence)"
        revisionSequence += 1
        records[saved.id] = saved
        saveCount += 1
        return saved
    }
}

private actor SyncTestCalendar: CalendarSyncProviding {
    enum CreateMode { case normal, throwWithoutPersist, persistThenThrow, persistThenSuspend, delayReturn }

    private var items: [String: ExternalCalendarItem] = [:]
    private var sequence = 0
    private var qualified = true
    private var createMode: CreateMode = .normal
    private var nextShape: (recurring: Bool, allDay: Bool, detached: Bool, organizer: String?, attendees: [String]) =
        (false, false, false, nil, [])
    private var mutateProviderOnFinalRead = false
    private var mutateURLOnFinalRead = false
    private var itemReadCount = 0
    private var itemCallCount = 0
    private var qualifyCallCount = 0
    private var recoverCallCount = 0
    private var injectDuplicateOnRecoverCall: Int?
    private(set) var createAttempts = 0
    private(set) var persistedCreates = 0
    let createEntered = AsyncTestLatch()

    func setQualified(_ value: Bool) { qualified = value }
    func setCreateMode(_ value: CreateMode) { createMode = value }
    func setNextShape(
        recurring: Bool = false,
        allDay: Bool = false,
        detached: Bool = false,
        organizer: String? = nil,
        attendees: [String] = []
    ) { nextShape = (recurring, allDay, detached, organizer, attendees) }
    func setMutateProviderOnFinalRead(_ value: Bool) { mutateProviderOnFinalRead = value }
    func setMutateURLOnFinalRead(_ value: Bool) { mutateURLOnFinalRead = value }
    func setInjectDuplicateOnRecoverCall(_ value: Int?) { injectDuplicateOnRecoverCall = value }
    func seed(_ item: ExternalCalendarItem) { items[item.localEventId] = item }
    func removeAll() { items.removeAll() }
    func attempts() -> Int { createAttempts }
    func persistedCount() -> Int { persistedCreates }
    func count() -> Int { items.count }
    func accessCounts() -> (qualify: Int, item: Int, recover: Int, create: Int) {
        (qualifyCallCount, itemCallCount, recoverCallCount, createAttempts)
    }

    func qualify(calendarId: String) async throws -> CalendarQualification {
        qualifyCallCount += 1
        return CalendarQualification(
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
        createAttempts += 1
        await createEntered.open()
        if createMode == .throwWithoutPersist { throw SyncTestError.forcedCalendarCreate }
        sequence += 1
        let id = "calendar-event-\(sequence)"
        let shape = nextShape
        nextShape = (false, false, false, nil, [])
        let item = ExternalCalendarItem(
            provider: "Fixture Calendar",
            calendarId: draft.calendarId,
            localEventId: id,
            providerExternalId: "provider-\(sequence)",
            itemURL: "calshow:\(id)",
            syncKey: draft.syncKey,
            operationFingerprint: draft.operationFingerprint,
            createInvocationId: draft.createInvocationId,
            title: draft.title,
            start: draft.start,
            end: draft.end,
            timeZoneIdentifier: draft.timeZoneIdentifier,
            location: draft.location,
            notes: draft.notes,
            organizer: shape.organizer,
            attendees: shape.attendees,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            isRecurring: shape.recurring,
            isAllDay: shape.allDay,
            isDetached: shape.detached
        )
        items[id] = item
        persistedCreates += 1
        if createMode == .persistThenThrow { throw SyncTestError.forcedCalendarCreate }
        if createMode == .persistThenSuspend {
            try await Task.sleep(nanoseconds: 10_000_000_000)
        }
        if createMode == .delayReturn {
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        return item
    }

    func item(id: String) async throws -> ExternalCalendarItem? {
        itemCallCount += 1
        guard var item = items[id] else { return nil }
        itemReadCount += 1
        if mutateProviderOnFinalRead && itemReadCount >= 2 { item.provider = "Mutated Provider" }
        if mutateURLOnFinalRead && itemReadCount >= 2 { item.itemURL = "calshow:mutated" }
        return item
    }

    func recover(_ query: CalendarRecoveryQuery) async throws -> [ExternalCalendarItem] {
        recoverCallCount += 1
        if injectDuplicateOnRecoverCall == recoverCallCount, var duplicate = items.values.first {
            duplicate.localEventId += "-duplicate"
            duplicate.providerExternalId = (duplicate.providerExternalId ?? "provider") + "-duplicate"
            items[duplicate.localEventId] = duplicate
        }
        var matches: [String: ExternalCalendarItem] = [:]
        if let id = query.localEventId, let direct = items[id] { matches[id] = direct }
        for item in items.values {
            let identity = item.syncKey == query.syncKey
                && item.operationFingerprint == query.operationFingerprint
            let invocation = query.createInvocationId.map { item.createInvocationId == $0 } ?? false
            let external = query.providerExternalId.map { item.providerExternalId == $0 } ?? false
            let fallback = item.calendarId == query.calendarId && item.title == query.title
                && abs(item.start.timeIntervalSince(query.start)) < 1
                && abs(item.end.timeIntervalSince(query.end)) < 1
            if identity || invocation || external || fallback { matches[item.localEventId] = item }
        }
        return matches.values.sorted { $0.localEventId < $1.localEventId }
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

private actor AlwaysFailingTransactionStore: CalendarRegistryTransactionStoring {
    private var transaction: CalendarRegistryTransaction?

    func claim(
        idempotencyKey: String,
        manifestFingerprint: String,
        operationId: String,
        leaseOwner: String,
        leaseToken: String,
        leaseDuration: TimeInterval,
        exclusiveProcessLockHeld: Bool
    ) async throws -> CalendarRegistryTransaction {
        _ = exclusiveProcessLockHeld
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
        _ = transaction; _ = leaseDuration
        throw SyncTestError.forcedLedgerSave
    }
    func get(idempotencyKey: String) async throws -> CalendarRegistryTransaction? {
        transaction?.idempotencyKey == idempotencyKey ? transaction : nil
    }
    func save(_ transaction: CalendarRegistryTransaction) async throws -> CalendarRegistryTransaction {
        _ = transaction
        throw SyncTestError.forcedLedgerSave
    }
    func release(_ transaction: CalendarRegistryTransaction) async throws -> CalendarRegistryTransaction {
        _ = transaction
        throw SyncTestError.forcedLedgerSave
    }
}

private func syncRequest(
    key: String = "operation-lift-2027-01-15",
    registryEventId: String? = nil,
    title: String = "LIFT",
    start: Date = Date(timeIntervalSince1970: 1_800_010_000),
    end: Date = Date(timeIntervalSince1970: 1_800_013_600),
    timeZone: String = "America/Chicago",
    calendarId: String = "cal-private"
) -> RegistryFirstTimeInstanceRequest {
    RegistryFirstTimeInstanceRequest(
        idempotencyKey: key,
        registryEventId: registryEventId ?? "notion-\(key)",
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

private func canonicalRecord(_ request: RegistryFirstTimeInstanceRequest) -> TimeInstanceRecord {
    TimeInstanceRecord(
        id: request.registryEventId,
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
        registryUpdatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        registryRevision: "revision-initial"
    )
}

private func calendarItem(
    _ request: RegistryFirstTimeInstanceRequest,
    id: String = "calendar-existing",
    provider: String = "Fixture Calendar",
    external: String? = "provider-existing",
    url: String? = "calshow:existing",
    recurring: Bool = false,
    allDay: Bool = false,
    detached: Bool = false,
    organizer: String? = nil,
    attendees: [String] = [],
    updatedAt: Date? = Date(timeIntervalSince1970: 1_800_000_000)
) -> ExternalCalendarItem {
    ExternalCalendarItem(
        provider: provider,
        calendarId: request.calendarId,
        localEventId: id,
        providerExternalId: external,
        itemURL: url,
        syncKey: request.idempotencyKey,
        operationFingerprint: request.manifest.fingerprint,
        createInvocationId: "create-invocation",
        title: request.title,
        start: request.start,
        end: request.end,
        timeZoneIdentifier: request.timeZoneIdentifier,
        location: request.location,
        notes: request.notes,
        organizer: organizer,
        attendees: attendees,
        updatedAt: updatedAt,
        isRecurring: recurring,
        isAllDay: allDay,
        isDetached: detached
    )
}

private func makeSyncEngine(
    registry: any TimeInstanceRegistryStoring,
    calendar: any CalendarSyncProviding = SyncTestCalendar(),
    transactions: any CalendarRegistryTransactionStoring = InMemoryCalendarRegistryTransactionStore(),
    processLocks: any CalendarRegistryProcessLocking = InMemoryCalendarRegistryProcessLockCoordinator(),
    operationGate: CalendarRegistryOperationGate = CalendarRegistryOperationGate(),
    leaseDuration: TimeInterval = 600
) -> CalendarRegistrySyncEngine {
    CalendarRegistrySyncEngine(
        registry: registry,
        calendar: calendar,
        transactions: transactions,
        processLocks: processLocks,
        operationGate: operationGate,
        clock: { Date(timeIntervalSince1970: 1_800_000_000) },
        makeOperationId: { UUID().uuidString.lowercased() },
        makeLeaseToken: { UUID().uuidString.lowercased() },
        makeCreateInvocationId: { "create-invocation" },
        makeSyncWriterToken: { UUID().uuidString.lowercased() },
        leaseDuration: leaseDuration
    )
}

private func seededRegistry(_ request: RegistryFirstTimeInstanceRequest) async -> SyncTestRegistry {
    let registry = SyncTestRegistry()
    await registry.put(canonicalRecord(request))
    return registry
}

private func withTempDirectory(_ body: (URL) async throws -> Void) async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .resolvingSymlinksInPath()
        .appendingPathComponent("bridge-calendar-sync-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory)
}

private func claim(
    _ store: any CalendarRegistryTransactionStoring,
    key: String,
    fingerprint: String = "fingerprint",
    operation: String = "operation",
    token: String = "token",
    exclusive: Bool = false,
    duration: TimeInterval = 600
) async throws -> CalendarRegistryTransaction {
    try await store.claim(
        idempotencyKey: key,
        manifestFingerprint: fingerprint,
        operationId: operation,
        leaseOwner: operation,
        leaseToken: token,
        leaseDuration: duration,
        exclusiveProcessLockHeld: exclusive
    )
}

// MARK: - Registry gateway fixture

private actor SyncRegistryGateway: RegistryNotionGateway {
    nonisolated var supportsAuthoritativeFiltering: Bool { true }
    private var pages: [String: NotionRow] = [:]
    private(set) var createCalls = 0
    private(set) var updateCalls = 0
    private var lastUpdateNames: [String] = []
    private var dropWriterTokenOnUpdate = false
    private var truncateSyncedAtToMinute = false
    private var revisionSequence = 1

    func seed(_ row: NotionRow) {
        pages[row.id] = row
        pages[CachedRow.normalize(row.id)] = row
    }
    func createCount() -> Int { createCalls }
    func updateCount() -> Int { updateCalls }
    func updatedFieldNames() -> [String] { lastUpdateNames }
    func setDropWriterTokenOnUpdate(_ value: Bool) { dropWriterTokenOnUpdate = value }
    func setTruncateSyncedAtToMinute(_ value: Bool) { truncateSyncedAtToMinute = value }

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
        let object = try JSONSerialization.jsonObject(with: filter) as? [String: Any]
        let wanted = (object?["rich_text"] as? [String: Any])?["equals"] as? String
        return (pages.values.filter { row in
            row.cells.values.contains { $0.type == "rich_text" && $0.value == .string(wanted ?? "") }
        }, nil)
    }
    func page(pageId: String, workspace: String?) async throws -> NotionRow {
        _ = workspace
        guard let row = pages[pageId] ?? pages[CachedRow.normalize(pageId)] else {
            throw SyncTestError.forcedVerificationMiss
        }
        return row
    }
    func create(dataSourceId: String, workspace: String?, fields: [BoundField]) async throws -> NotionRow {
        _ = dataSourceId; _ = workspace; _ = fields
        createCalls += 1
        throw SyncTestError.forcedRegistrySave
    }
    func update(pageId: String, workspace: String?, fields: [BoundField]) async throws -> NotionRow {
        _ = workspace
        updateCalls += 1
        lastUpdateNames = fields.map(\.notionName).sorted()
        var applied = dropWriterTokenOnUpdate
            ? fields.filter { $0.notionName != "Sync Writer Token" }
            : fields
        if truncateSyncedAtToMinute {
            applied = applied.map { field in
                guard ["Last Synced At", "Registry Updated At"].contains(field.notionName),
                      case .string(let raw) = field.value,
                      let date = CalendarRegistryISO.date(raw) else { return field }
                let truncated = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
                return BoundField(
                    propertyId: field.propertyId,
                    notionName: field.notionName,
                    type: field.type,
                    value: .string(CalendarRegistryISO.string(truncated)),
                    isTitle: field.isTitle
                )
            }
        }
        revisionSequence += 1
        let row = Self.row(
            id: pageId, existing: pages[pageId], fields: applied,
            lastEditedTime: String(format: "2027-01-15T08:00:%02d.000Z", revisionSequence)
        )
        pages[pageId] = row
        return row
    }
    func archive(pageId: String, workspace: String?) async throws { pages[pageId] = nil }
    func markdown(pageId: String, workspace: String?) async throws -> String { "" }
    func writeMarkdown(pageId: String, workspace: String?, markdown: String) async throws {}

    static func row(
        id: String, existing: NotionRow?, fields: [BoundField],
        lastEditedTime: String = "2027-01-15T08:00:00.000Z"
    ) -> NotionRow {
        var cells = existing?.cells ?? [:]
        for field in fields {
            cells[field.notionName] = NotionCell(id: field.propertyId, type: field.type, value: field.value)
        }
        return NotionRow(
            id: id,
            url: "https://notion.fixture/\(id)",
            lastEditedTime: lastEditedTime,
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
        ("createInvocationId", "Calendar Create Invocation ID", "rich_text", .generic),
        ("syncWriterToken", "Sync Writer Token", "rich_text", .generic),
        ("syncRevision", "Sync Revision", "number", .generic),
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

private func notionRow(for record: TimeInstanceRecord, entity: RegistryEntity) throws -> NotionRow {
    let gateway = SyncRegistryGateway()
    _ = gateway
    let store = NotionTimeInstanceRegistryStore(entity: entity, gateway: SyncRegistryGateway())
    let mirror = Mirror(reflecting: store)
    _ = mirror
    let fields: [String: Value] = [
        "title": .string(record.title),
        "date": .object([
            "start": .string(CalendarRegistryISO.string(record.scheduledStart)),
            "end": .string(CalendarRegistryISO.string(record.scheduledEnd)),
            "timeZone": .string(record.timeZoneIdentifier)
        ]),
        "status": .string(record.lifecycleStatus),
        "syncKey": .string(record.syncKey),
        "operationFingerprint": .string(record.operationFingerprint),
        "eventClass": .string(record.semantics.eventClass.rawValue),
        "meetingType": record.semantics.meetingType.map(Value.string) ?? .null,
        "primaryBlock": .array([.string(record.semantics.primaryBlockId)]),
        "blocks": .array(record.semantics.blockIds.map(Value.string)),
        "projects": .array(record.semantics.projectIds.map(Value.string)),
        "contacts": .array(record.semantics.contactIds.map(Value.string)),
        "schedulingAuthority": .string(record.schedulingAuthority.rawValue),
        "syncState": .string(record.syncState.rawValue),
        "registryUpdatedAt": .string(CalendarRegistryISO.string(record.registryUpdatedAt)),
        "syncHash": .string(record.syncHash),
        "scheduledDuration": .double(record.scheduledDurationMinutes),
        "description": record.notes.map(Value.string) ?? .null,
        "calendarLocation": record.location.map(Value.string) ?? .null,
        "calendarProvider": record.calendarProvider.map(Value.string) ?? .null,
        "calendarId": record.calendarId.map(Value.string) ?? .null,
        "calendarEventId": record.calendarEventId.map(Value.string) ?? .null,
        "providerExternalId": record.providerExternalId.map(Value.string) ?? .null,
        "calendarUrl": record.calendarItemURL.map(Value.string) ?? .null,
        "createInvocationId": record.createInvocationId.map(Value.string) ?? .null,
        "syncWriterToken": record.syncWriterToken.map(Value.string) ?? .null,
        "syncRevision": .double(Double(record.syncRevision)),
        "lastSyncError": record.lastSyncError.map(Value.string) ?? .null,
        "lastSyncedAt": record.lastSyncedAt.map { .string(CalendarRegistryISO.string($0)) } ?? .null,
        "calendarUpdatedAt": record.calendarUpdatedAt.map { .string(CalendarRegistryISO.string($0)) } ?? .null
    ]
    let bound = RegistryWriter.resolve(fields, entity: entity).fields
    return SyncRegistryGateway.row(id: record.id, existing: nil, fields: bound)
}

private func mutateNotionRow(
    _ row: NotionRow,
    cellName: String? = nil,
    value: Value? = nil,
    remove: Bool = false,
    lastEditedTime: String? = nil
) -> NotionRow {
    var cells = row.cells
    if let cellName {
        if remove {
            cells[cellName] = nil
        } else {
            let existing = cells[cellName]
            cells[cellName] = NotionCell(
                id: existing?.id ?? "mutated-property",
                type: existing?.type ?? "rich_text",
                value: value ?? .null
            )
        }
    }
    return NotionRow(
        id: row.id,
        url: row.url,
        lastEditedTime: lastEditedTime ?? row.lastEditedTime,
        cells: cells,
        archived: row.archived
    )
}


// MARK: - Calendar store fixture

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
        let lower = try CalendarISOParsing.parse(query.start)
        let upper = try CalendarISOParsing.parse(query.end)
        return eventsById.values.filter { event in
            guard query.calendarId == nil || event.calendarId == query.calendarId,
                  let start = try? CalendarISOParsing.parse(event.start),
                  let end = try? CalendarISOParsing.parse(event.end) else { return false }
            return end >= lower && start <= upper
        }
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
            lastModified: nil
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

// MARK: - Tests

func runCalendarRegistrySyncEngineTests() async {
    await test("CR1 SQLite ledger survives independent handles") {
        try await withTempDirectory { directory in
            let url = directory.appendingPathComponent("ledger.sqlite3")
            let first = try SQLiteCalendarRegistryTransactionStore(url: url)
            let tx = try await claim(first, key: "same-key", exclusive: true)
            _ = try await first.release(tx)
            let second = try SQLiteCalendarRegistryTransactionStore(url: url)
            try expect(try await second.get(idempotencyKey: "same-key") != nil)
        }
    }

    await test("CR2 SQLite key rejects a different manifest") {
        try await withTempDirectory { directory in
            let store = try SQLiteCalendarRegistryTransactionStore(url: directory.appendingPathComponent("ledger.sqlite3"))
            let tx = try await claim(store, key: "same-key", fingerprint: "a", exclusive: true)
            _ = try await store.release(tx)
            do {
                _ = try await claim(store, key: "same-key", fingerprint: "b", exclusive: true)
                throw TestError.assertion("different manifest should conflict")
            } catch CalendarRegistryTransactionStoreError.idempotencyConflict("same-key") {}
        }
    }

    await test("CR3 SQLite preserves concurrent different-key rows") {
        try await withTempDirectory { directory in
            let url = directory.appendingPathComponent("ledger.sqlite3")
            let first = try SQLiteCalendarRegistryTransactionStore(url: url)
            let second = try SQLiteCalendarRegistryTransactionStore(url: url)
            async let a = claim(first, key: "a", operation: "a", token: "a", exclusive: true)
            async let b = claim(second, key: "b", operation: "b", token: "b", exclusive: true)
            _ = try await (a, b)
            try expect(try await first.get(idempotencyKey: "a") != nil)
            try expect(try await second.get(idempotencyKey: "b") != nil)
        }
    }

    await test("CR4 process lock path is deterministic and key-safe") {
        try await withTempDirectory { directory in
            let locks = try FileCalendarRegistryProcessLockCoordinator(rootURL: directory)
            let a = locks.lockURL(idempotencyKey: "a/b")
            let b = locks.lockURL(idempotencyKey: "a:b")
            try expect(a != b)
            try expect(a.lastPathComponent.count == 69)
            try expect(!a.lastPathComponent.contains("/"))
        }
    }

    await test("CR5 in-memory process lock refuses a second owner") {
        let locks = InMemoryCalendarRegistryProcessLockCoordinator()
        let first = try locks.acquire(idempotencyKey: "key")
        do {
            _ = try locks.acquire(idempotencyKey: "key")
            throw TestError.assertion("second owner should fail")
        } catch CalendarRegistryProcessLockError.operationActive("key") {}
        try first.release()
        let second = try locks.acquire(idempotencyKey: "key")
        try second.release()
    }

    await test("CR6 file process lock refuses a second owner") {
        try await withTempDirectory { directory in
            let locks = try FileCalendarRegistryProcessLockCoordinator(rootURL: directory)
            let first = try locks.acquire(idempotencyKey: "key")
            do {
                _ = try locks.acquire(idempotencyKey: "key")
                throw TestError.assertion("second file owner should fail")
            } catch CalendarRegistryProcessLockError.operationActive("key") {}
            try first.release()
        }
    }

    await test("CR7 missing supplied EVENT fails before calendar write") {
        let request = syncRequest(key: "missing")
        let registry = SyncTestRegistry()
        let calendar = SyncTestCalendar()
        let receipt = try await makeSyncEngine(registry: registry, calendar: calendar).registryFirstCreate(request)
        try expect(!receipt.succeeded && receipt.stageAfter == .conflict)
        try expect(await calendar.attempts() == 0)
    }

    await test("CR8 partial supplied EVENT fails without repair") {
        let request = syncRequest(key: "partial")
        let registry = SyncTestRegistry()
        await registry.setIdentityOverride(id: request.registryEventId, value: .partial(
            pageId: request.registryEventId,
            syncKey: request.idempotencyKey,
            operationFingerprint: request.manifest.fingerprint
        ))
        let calendar = SyncTestCalendar()
        let receipt = try await makeSyncEngine(registry: registry, calendar: calendar).registryFirstCreate(request)
        try expect(!receipt.succeeded && receipt.stageAfter == .conflict)
        try expect(await calendar.attempts() == 0)
    }

    await test("CR9 malformed supplied EVENT fails without repair") {
        let request = syncRequest(key: "malformed")
        let registry = SyncTestRegistry()
        await registry.setIdentityOverride(id: request.registryEventId, value: .malformed(
            pageId: request.registryEventId, reason: "broken relation"
        ))
        let receipt = try await makeSyncEngine(registry: registry).registryFirstCreate(request)
        try expect(!receipt.succeeded && receipt.stageAfter == .conflict)
    }

    await test("CR10 duplicate Sync Key query fails before calendar write") {
        let request = syncRequest(key: "duplicate")
        let registry = await seededRegistry(request)
        var duplicate = canonicalRecord(request)
        duplicate.id = "other-page"
        await registry.setLookupExtras([duplicate])
        let calendar = SyncTestCalendar()
        let receipt = try await makeSyncEngine(registry: registry, calendar: calendar).registryFirstCreate(request)
        try expect(!receipt.succeeded && receipt.stageAfter == .conflict)
        try expect(await calendar.attempts() == 0)
    }

    await test("CR11 supplied page must equal the unique Sync Key result") {
        let request = syncRequest(key: "wrong-page")
        let registry = SyncTestRegistry()
        var other = canonicalRecord(request)
        other.id = "different-page"
        await registry.put(other)
        await registry.setIdentityOverride(id: request.registryEventId, value: .decoded(canonicalRecord(request)))
        let receipt = try await makeSyncEngine(registry: registry).registryFirstCreate(request)
        try expect(!receipt.succeeded && receipt.stageAfter == .conflict)
    }

    await test("CR12 degraded registry lookup refuses calendar creation") {
        let request = syncRequest(key: "stale")
        let registry = await seededRegistry(request)
        await registry.setLookupSource(.staleCache)
        let calendar = SyncTestCalendar()
        let receipt = try await makeSyncEngine(registry: registry, calendar: calendar).registryFirstCreate(request)
        try expect(!receipt.succeeded)
        try expect(await calendar.attempts() == 0)
    }

    await test("CR13 canonical pre-existing EVENT pairs successfully") {
        let request = syncRequest(key: "happy")
        let registry = await seededRegistry(request)
        let calendar = SyncTestCalendar()
        let receipt = try await makeSyncEngine(registry: registry, calendar: calendar).registryFirstCreate(request)
        try expect(receipt.succeeded)
        try expect(await calendar.persistedCount() == 1)
        try expect(receipt.record?.id == request.registryEventId)
    }

    await test("CR14 smoke path performs no Notion create") {
        let request = syncRequest(key: "no-notion-create", registryEventId: "00000000000000000000000000000014")
        let entity = scheduleEntityForSyncTests()
        let gateway = SyncRegistryGateway()
        await gateway.seed(try notionRow(for: canonicalRecord(request), entity: entity))
        let store = NotionTimeInstanceRegistryStore(entity: entity, gateway: gateway)
        let receipt = try await makeSyncEngine(registry: store).registryFirstCreate(request)
        try expect(receipt.succeeded)
        try expect(await gateway.createCount() == 0)
        try expect(await gateway.updateCount() >= 2)
    }

    await test("CR15 ten retries create one calendar item") {
        let request = syncRequest(key: "retries")
        let registry = await seededRegistry(request)
        let calendar = SyncTestCalendar()
        let engine = makeSyncEngine(registry: registry, calendar: calendar)
        for _ in 0..<10 {
            let receipt = try await engine.registryFirstCreate(request)
            try expect(receipt.succeeded)
        }
        try expect(await calendar.persistedCount() == 1)
    }

    await test("CR16 calendar create intent is persisted before provider failure") {
        let request = syncRequest(key: "intent")
        let registry = await seededRegistry(request)
        let calendar = SyncTestCalendar()
        await calendar.setCreateMode(.throwWithoutPersist)
        let store = InMemoryCalendarRegistryTransactionStore()
        let receipt = try await makeSyncEngine(registry: registry, calendar: calendar, transactions: store)
            .registryFirstCreate(request)
        let tx = await store.get(idempotencyKey: request.idempotencyKey)
        try expect(!receipt.succeeded && receipt.stageAfter == .calendarEffectUnknown)
        try expect(tx?.partialEffects.contains { $0.contains("persisted Create Invocation ID") } == true)
    }

    await test("CR17 provider persist-then-error records unknown effect") {
        let request = syncRequest(key: "persist-error")
        let registry = await seededRegistry(request)
        let calendar = SyncTestCalendar()
        await calendar.setCreateMode(.persistThenThrow)
        let receipt = try await makeSyncEngine(registry: registry, calendar: calendar).registryFirstCreate(request)
        try expect(!receipt.succeeded && receipt.stageAfter == .calendarEffectUnknown)
        try expect(await calendar.persistedCount() == 1)
        try expect(receipt.recoveryAction?.contains("recovery only") == true)
    }

    await test("CR18 unknown effect retry recovers the existing calendar item") {
        let request = syncRequest(key: "recover-unknown")
        let registry = await seededRegistry(request)
        let calendar = SyncTestCalendar()
        await calendar.setCreateMode(.persistThenThrow)
        let store = InMemoryCalendarRegistryTransactionStore()
        let engine = makeSyncEngine(registry: registry, calendar: calendar, transactions: store)
        let first = try await engine.registryFirstCreate(request)
        try expect(first.stageAfter == .calendarEffectUnknown)
        await calendar.setCreateMode(.normal)
        let second = try await engine.registryFirstCreate(request)
        try expect(second.succeeded)
        try expect(await calendar.attempts() == 1)
        try expect(await calendar.persistedCount() == 1)
    }

    await test("CR19 unknown effect with zero candidates never recreates") {
        let request = syncRequest(key: "unknown-zero")
        let registry = await seededRegistry(request)
        let calendar = SyncTestCalendar()
        await calendar.setCreateMode(.throwWithoutPersist)
        let store = InMemoryCalendarRegistryTransactionStore()
        let engine = makeSyncEngine(registry: registry, calendar: calendar, transactions: store)
        let first = try await engine.registryFirstCreate(request)
        try expect(first.stageAfter == .calendarEffectUnknown)
        await calendar.setCreateMode(.normal)
        let second = try await engine.registryFirstCreate(request)
        try expect(!second.succeeded && second.stageAfter == .operatorReview)
        try expect(await calendar.attempts() == 1)
    }

    await test("CR20 restart after create intent is recovery-only") {
        let request = syncRequest(key: "intent-restart")
        let registry = await seededRegistry(request)
        var invoked = canonicalRecord(request)
        invoked.createInvocationId = "create-invocation"
        invoked.syncWriterToken = "writer-intent-restart"
        invoked.syncRevision = 1
        await registry.put(invoked)
        let calendar = SyncTestCalendar()
        let store = InMemoryCalendarRegistryTransactionStore()
        var tx = try await claim(
            store,
            key: request.idempotencyKey,
            fingerprint: request.manifest.fingerprint,
            exclusive: true
        )
        tx.registryEventId = request.registryEventId
        tx.stage = .registryAuthorized
        tx = try await store.save(tx)
        tx.createInvocationId = "create-invocation"
        tx.syncWriterToken = "writer-intent-restart"
        tx.syncRevision = 1
        tx.stage = .createInvocationPersisted
        tx = try await store.save(tx)
        _ = try await store.release(tx)
        let receipt = try await makeSyncEngine(registry: registry, calendar: calendar, transactions: store)
            .registryFirstCreate(request)
        try expect(!receipt.succeeded && receipt.stageAfter == .operatorReview)
        try expect(receipt.recoveryAction?.contains("operator review") == true)
        try expect(await calendar.attempts() == 0)
    }

    await test("CR21 multiple recovered calendar identities conflict") {
        let request = syncRequest(key: "ambiguous-calendar")
        let registry = await seededRegistry(request)
        let calendar = SyncTestCalendar()
        await calendar.seed(calendarItem(request, id: "one"))
        await calendar.seed(calendarItem(request, id: "two"))
        let receipt = try await makeSyncEngine(registry: registry, calendar: calendar).registryFirstCreate(request)
        try expect(!receipt.succeeded && receipt.stageAfter == .conflict)
        try expect(await calendar.attempts() == 0)
    }

    await test("CR22 identity-bearing unsupported shapes conflict") {
        for shape in ["recurring", "all-day", "detached", "participant"] {
            let request = syncRequest(key: "shape-\(shape)")
            let registry = await seededRegistry(request)
            let calendar = SyncTestCalendar()
            await calendar.seed(calendarItem(
                request,
                recurring: shape == "recurring",
                allDay: shape == "all-day",
                detached: shape == "detached",
                organizer: shape == "participant" ? "owner@example.com" : nil,
                attendees: shape == "participant" ? ["person@example.com"] : []
            ))
            let receipt = try await makeSyncEngine(registry: registry, calendar: calendar).registryFirstCreate(request)
            try expect(!receipt.succeeded && receipt.stageAfter == .conflict)
            try expect(await calendar.attempts() == 0)
        }
    }

    await test("CR23 established registry EVENT id cannot be substituted") {
        let store = InMemoryCalendarRegistryTransactionStore()
        var tx = try await claim(store, key: "immutable-registry", exclusive: true)
        tx.registryEventId = "page-a"
        tx.stage = .registryAuthorized
        tx = try await store.save(tx)
        tx.registryEventId = "page-b"
        do { _ = try await store.save(tx); throw TestError.assertion("substitution should fail") }
        catch CalendarRegistryTransactionStoreError.identityRegression {}
    }

    await test("CR24 established calendar event id cannot be substituted") {
        let store = InMemoryCalendarRegistryTransactionStore()
        var tx = try await claim(store, key: "immutable-event", exclusive: true)
        tx.registryEventId = "page"
        tx.stage = .registryAuthorized
        tx = try await store.save(tx)
        tx.stage = .calendarIdentified
        tx.calendarEventId = "event-a"
        tx.calendarId = "cal"
        tx = try await store.save(tx)
        tx.calendarEventId = "event-b"
        do { _ = try await store.save(tx); throw TestError.assertion("substitution should fail") }
        catch CalendarRegistryTransactionStoreError.identityRegression {}
    }

    await test("CR25 established calendar id cannot be substituted") {
        let store = InMemoryCalendarRegistryTransactionStore()
        var tx = try await claim(store, key: "immutable-cal", exclusive: true)
        tx.registryEventId = "page"
        tx.stage = .registryAuthorized
        tx = try await store.save(tx)
        tx.stage = .calendarIdentified
        tx.calendarEventId = "event"
        tx.calendarId = "cal-a"
        tx = try await store.save(tx)
        tx.calendarId = "cal-b"
        do { _ = try await store.save(tx); throw TestError.assertion("substitution should fail") }
        catch CalendarRegistryTransactionStoreError.identityRegression {}
    }

    await test("CR26 established provider external id cannot be substituted") {
        let store = InMemoryCalendarRegistryTransactionStore()
        var tx = try await claim(store, key: "immutable-provider", exclusive: true)
        tx.registryEventId = "page"
        tx.stage = .registryAuthorized
        tx = try await store.save(tx)
        tx.stage = .calendarIdentified
        tx.calendarEventId = "event"
        tx.calendarId = "cal"
        tx.providerExternalId = "external-a"
        tx = try await store.save(tx)
        tx.providerExternalId = "external-b"
        do { _ = try await store.save(tx); throw TestError.assertion("substitution should fail") }
        catch CalendarRegistryTransactionStoreError.identityRegression {}
    }

    await test("CR27 established identifiers cannot be cleared") {
        let store = InMemoryCalendarRegistryTransactionStore()
        var tx = try await claim(store, key: "immutable-clear", exclusive: true)
        tx.registryEventId = "page"
        tx.stage = .registryAuthorized
        tx = try await store.save(tx)
        tx.registryEventId = nil
        do { _ = try await store.save(tx); throw TestError.assertion("clearing should fail") }
        catch CalendarRegistryTransactionStoreError.identityRegression {}
    }

    await test("CR28 final success recomputes Sync Hash") {
        let request = syncRequest(key: "final-hash")
        let registry = await seededRegistry(request)
        let receipt = try await makeSyncEngine(registry: registry).registryFirstCreate(request)
        try expect(receipt.succeeded)
        try expect(receipt.verifiedSyncHash?.count == 64)
        try expect(receipt.record?.syncHash == receipt.verifiedSyncHash)
    }

    await test("CR29 dropped final Sync Hash prevents success") {
        let request = syncRequest(key: "drop-hash")
        let registry = await seededRegistry(request)
        await registry.setDropFinalSyncHash(true)
        let receipt = try await makeSyncEngine(registry: registry).registryFirstCreate(request)
        try expect(!receipt.succeeded)
        try expect(receipt.discrepancy?.contains("recomputed Synced evidence") == true)
    }

    await test("CR30 final provider mutation prevents success") {
        let request = syncRequest(key: "mutate-provider")
        let registry = await seededRegistry(request)
        let calendar = SyncTestCalendar()
        await calendar.setMutateProviderOnFinalRead(true)
        let receipt = try await makeSyncEngine(registry: registry, calendar: calendar).registryFirstCreate(request)
        try expect(!receipt.succeeded)
    }

    await test("CR31 observational Calendar URL mutation does not change pair identity") {
        let request = syncRequest(key: "mutate-url")
        let registry = await seededRegistry(request)
        let calendar = SyncTestCalendar()
        await calendar.setMutateURLOnFinalRead(true)
        let receipt = try await makeSyncEngine(registry: registry, calendar: calendar).registryFirstCreate(request)
        try expect(receipt.succeeded)
    }

    await test("CR32 final Last Synced At mutation prevents success") {
        let request = syncRequest(key: "mutate-synced-at")
        let registry = await seededRegistry(request)
        await registry.setMutateSyncedAtOnFinalRead(true)
        let receipt = try await makeSyncEngine(registry: registry).registryFirstCreate(request)
        try expect(!receipt.succeeded)
    }

    await test("CR33 conflict receipt prohibits automatic retry") {
        let request = syncRequest(key: "conflict-action")
        let registry = await seededRegistry(request)
        var duplicate = canonicalRecord(request)
        duplicate.id = "duplicate"
        await registry.setLookupExtras([duplicate])
        let receipt = try await makeSyncEngine(registry: registry).registryFirstCreate(request)
        try expect(receipt.stageAfter == .conflict)
        try expect(receipt.recoveryAction?.contains("automatic retry is prohibited") == true)
    }

    await test("CR34 unknown-effect receipt is recovery-only") {
        let request = syncRequest(key: "unknown-action")
        let registry = await seededRegistry(request)
        let calendar = SyncTestCalendar()
        await calendar.setCreateMode(.throwWithoutPersist)
        let receipt = try await makeSyncEngine(registry: registry, calendar: calendar).registryFirstCreate(request)
        try expect(receipt.stageAfter == .calendarEffectUnknown)
        try expect(receipt.recoveryAction?.contains("automatic recreation is prohibited") == true)
    }

    await test("CR35 cancellation before EventKit create produces no calendar item") {
        let request = syncRequest(key: "cancel-before-calendar")
        let registry = await seededRegistry(request)
        let calendar = SyncTestCalendar()
        let locks = InMemoryCalendarRegistryProcessLockCoordinator()
        let gate = CalendarRegistryOperationGate()
        try await gate.acquire(request.idempotencyKey)
        let engine = makeSyncEngine(registry: registry, calendar: calendar, processLocks: locks, operationGate: gate)
        let task = Task { try await engine.registryFirstCreate(request) }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        await gate.release(request.idempotencyKey)
        do { _ = try await task.value } catch is CancellationError {}
        try expect(await calendar.persistedCount() == 0)
    }

    await test("CR36 cancellation after calendar side effect records unknown state") {
        let request = syncRequest(key: "cancel-after-effect")
        let registry = await seededRegistry(request)
        let calendar = SyncTestCalendar()
        await calendar.setCreateMode(.persistThenSuspend)
        let task = Task { try await makeSyncEngine(registry: registry, calendar: calendar).registryFirstCreate(request) }
        await calendar.createEntered.wait()
        task.cancel()
        let receipt = try await task.value
        try expect(!receipt.succeeded && receipt.stageAfter == .calendarEffectUnknown)
        try expect(await calendar.persistedCount() == 1)
    }

    await test("CR37 exact malformed metadata target conflicts") {
        let request = syncRequest(key: "malformed-target")
        let store = PersistentCalendarStore()
        await store.seed(CalendarEvent(
            id: "target", title: request.title,
            start: CalendarRegistryISO.string(request.start), end: CalendarRegistryISO.string(request.end),
            allDay: false, calendarId: request.calendarId, calendarTitle: "Private Smoke",
            location: request.location,
            notes: CalendarRegistryCalendarMetadata.beginMarker + "\nSync-Key: \(request.idempotencyKey)",
            timeZoneIdentifier: request.timeZoneIdentifier
        ))
        let provider = CalendarStoringSyncProvider(store: store, allowlistedCalendarIds: [request.calendarId])
        do {
            _ = try await provider.recover(CalendarRecoveryQuery(
                syncKey: request.idempotencyKey,
                operationFingerprint: request.manifest.fingerprint,
                calendarId: request.calendarId,
                title: request.title,
                start: request.start,
                end: request.end
            ))
            throw TestError.assertion("target metadata should conflict")
        } catch CalendarRegistrySyncError.identityConflict {}
    }

    await test("CR38 arbitrary user-note substring does not poison recovery") {
        let request = syncRequest(key: "substring-key")
        let store = PersistentCalendarStore()
        await store.seed(CalendarEvent(
            id: "unrelated", title: "Other",
            start: CalendarRegistryISO.string(request.start), end: CalendarRegistryISO.string(request.end),
            allDay: false, calendarId: request.calendarId, calendarTitle: "Private Smoke",
            location: nil,
            notes: "Discuss \(request.idempotencyKey)\n" + CalendarRegistryCalendarMetadata.beginMarker + "\ninvalid",
            timeZoneIdentifier: request.timeZoneIdentifier
        ))
        let provider = CalendarStoringSyncProvider(store: store, allowlistedCalendarIds: [request.calendarId])
        let recovered = try await provider.recover(CalendarRecoveryQuery(
            syncKey: request.idempotencyKey,
            operationFingerprint: request.manifest.fingerprint,
            calendarId: request.calendarId,
            title: request.title,
            start: request.start,
            end: request.end
        ))
        try expect(recovered.isEmpty)
    }

    await test("CR39 absent provider modification time remains nil") {
        let request = syncRequest(key: "provider-time")
        let store = PersistentCalendarStore()
        let provider = CalendarStoringSyncProvider(store: store, allowlistedCalendarIds: [request.calendarId])
        let created = try await provider.create(ExternalCalendarDraft(
            title: request.title,
            start: request.start,
            end: request.end,
            timeZoneIdentifier: request.timeZoneIdentifier,
            calendarId: request.calendarId,
            location: request.location,
            notes: request.notes,
            syncKey: request.idempotencyKey,
            operationFingerprint: request.manifest.fingerprint,
            createInvocationId: "create-invocation"
        ))
        try expect(created.updatedAt == nil)
    }

    await test("CR40 composition remains disabled by default") {
        do {
            _ = try CalendarRegistrySyncComposition.build(
                entity: scheduleEntityForSyncTests(),
                registryGateway: SyncRegistryGateway(),
                calendarStore: PersistentCalendarStore(),
                environment: [:]
            )
            throw TestError.assertion("composition should be disabled")
        } catch CalendarRegistrySyncCompositionError.disabled {}
    }

    await test("CR41 composition builds only with local canonical coordinator") {
        try await withTempDirectory { directory in
            let engine = try CalendarRegistrySyncComposition.build(
                entity: scheduleEntityForSyncTests(),
                registryGateway: SyncRegistryGateway(),
                calendarStore: PersistentCalendarStore(),
                environment: [CalendarRegistrySyncComposition.enableEnvironmentKey: "1"],
                allowedCalendarIds: ["cal-private"]
            )
            _ = engine
            try expect(CalendarRegistrySyncComposition.canonicalLedgerURL.lastPathComponent == "transactions.sqlite3")
            try expect(CalendarRegistrySyncComposition.canonicalCoordinatorDirectory.lastPathComponent == "calendar-registry-coordinator")
        }
    }

    await test("CR42 migration artifact decodes against registry roles") {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("docs/migrations/calendar-registry-v1/registry-entity-patch.json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let properties = object?["additiveProperties"] as? [[String: Any]] ?? []
        try expect(object?["schemaVersion"] as? Int == 3)
        try expect(properties.count == 5)
        let byKey = Dictionary(uniqueKeysWithValues: properties.compactMap { property -> (String, [String: Any])? in
            guard let key = property["key"] as? String else { return nil }
            return (key, property)
        })
        try expect(byKey["createInvocationId"]?["type"] as? String == "rich_text")
        try expect(byKey["syncWriterToken"]?["type"] as? String == "rich_text")
        try expect(byKey["syncRevision"]?["type"] as? String == "number")
        for property in properties {
            let role = property["role"] as? String
            try expect(role == RegistryPropertyRole.generic.rawValue)
        }
    }

    await test("CR43 strict query decoder rejects malformed rows") {
        let malformed = try JSONSerialization.data(withJSONObject: [
            "results": [["id": "page-without-properties"]], "has_more": false
        ])
        do {
            _ = try RegistryQueryResponseDecoder.decode(malformed)
            throw TestError.assertion("malformed query row should fail")
        } catch RegistryGatewayError.invalidResponse {}
    }

    await test("CR44 schema v2 registry-created rows migrate to registry-verified") {
        try await withTempDirectory { directory in
            let url = directory.appendingPathComponent("migration.sqlite3")
            var db: OpaquePointer?
            try expect(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
            defer { if let db { sqlite3_close_v2(db) } }
            let sql = """
            CREATE TABLE calendar_registry_schema (id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL);
            INSERT INTO calendar_registry_schema(id,version) VALUES(1,2);
            CREATE TABLE calendar_registry_transactions (
              idempotency_key TEXT PRIMARY KEY NOT NULL, operation_id TEXT NOT NULL,
              manifest_fingerprint TEXT NOT NULL, stage TEXT NOT NULL, registry_event_id TEXT,
              calendar_event_id TEXT, calendar_id TEXT, provider_external_id TEXT,
              created_at TEXT NOT NULL, updated_at TEXT NOT NULL, last_verified_at TEXT,
              last_error TEXT, partial_effects_json TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 1,
              lease_owner TEXT, lease_token TEXT, lease_expires_at REAL, heartbeat_at REAL
            );
            INSERT INTO calendar_registry_transactions VALUES(
              'legacy','op','fingerprint','registryCreated','page',NULL,NULL,NULL,
              '2027-01-01T00:00:00.000Z','2027-01-01T00:00:00.000Z',NULL,NULL,'[]',1,NULL,NULL,NULL,NULL
            );
            """
            try expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
            if let db { sqlite3_close_v2(db) }
            db = nil
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let store = try SQLiteCalendarRegistryTransactionStore(url: url)
            let migrated = try await store.get(idempotencyKey: "legacy")
            try expect(migrated?.stage == .registryAuthorized)
        }
    }

    await test("CR45 unknown future ledger schema is refused") {
        try await withTempDirectory { directory in
            let url = directory.appendingPathComponent("future.sqlite3")
            var db: OpaquePointer?
            try expect(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
            try expect(sqlite3_exec(db, "CREATE TABLE calendar_registry_schema (id INTEGER PRIMARY KEY, version INTEGER NOT NULL); INSERT INTO calendar_registry_schema(id,version) VALUES(1,99);", nil, nil, nil) == SQLITE_OK)
            if let db { sqlite3_close_v2(db) }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            do {
                _ = try SQLiteCalendarRegistryTransactionStore(url: url)
                throw TestError.assertion("future schema should fail")
            } catch CalendarRegistryTransactionStoreError.corruptLedger {}
        }
    }

    await test("CR46 corrupted partial-effect evidence is refused") {
        try await withTempDirectory { directory in
            let url = directory.appendingPathComponent("corrupt.sqlite3")
            let store = try SQLiteCalendarRegistryTransactionStore(url: url)
            _ = try await claim(store, key: "corrupt", exclusive: true)
            var db: OpaquePointer?
            try expect(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
            defer { if let db { sqlite3_close_v2(db) } }
            try expect(sqlite3_exec(db, "UPDATE calendar_registry_transactions SET partial_effects_json='bad' WHERE idempotency_key='corrupt';", nil, nil, nil) == SQLITE_OK)
            do {
                _ = try await store.get(idempotencyKey: "corrupt")
                throw TestError.assertion("corrupt evidence should fail")
            } catch CalendarRegistryTransactionStoreError.corruptLedger {}
        }
    }

    await test("CR47 OS lock permits exclusive takeover despite stale SQLite lease") {
        try await withTempDirectory { directory in
            let store = try SQLiteCalendarRegistryTransactionStore(url: directory.appendingPathComponent("ledger.sqlite3"))
            let first = try await claim(store, key: "takeover", operation: "first", token: "first", exclusive: false, duration: 600)
            let second = try await claim(store, key: "takeover", operation: "second", token: "second", exclusive: true, duration: 600)
            try expect(second.revision > first.revision)
            try expect(second.leaseToken == "second")
        }
    }

    await test("CR48 expired lease alone does not authorize a second writer") {
        try await withTempDirectory { directory in
            let store = try SQLiteCalendarRegistryTransactionStore(url: directory.appendingPathComponent("ledger.sqlite3"))
            _ = try await claim(store, key: "no-exclusive", operation: "first", token: "first", exclusive: false, duration: 600)
            do {
                _ = try await claim(store, key: "no-exclusive", operation: "second", token: "second", exclusive: false, duration: 600)
                throw TestError.assertion("active lease should fail without OS ownership")
            } catch CalendarRegistryTransactionStoreError.operationActive {}
        }
    }

    await test("CR49 route ownership remains explicit") {
        try expect(CalendarRegistryRouteClassifier.owner(for: .semanticScheduling) == .timeKeepr)
        try expect(CalendarRegistryRouteClassifier.owner(for: .calendarMechanics) == .macKeepr)
        try expect(CalendarRegistryRouteClassifier.owner(for: .schemaChange) == .notionKeepr)
    }

    await test("CR50 child processes hold one external writer beyond lease duration") {
        try await withTempDirectory { directory in
            let binary = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            let key = "child-process-lock"
            let first = Process()
            first.executableURL = binary
            first.arguments = ["--calendar-registry-process-probe", directory.path, key, "1500"]
            try first.run()

            let entered = directory.appendingPathComponent("provider-entered")
            let deadline = Date().addingTimeInterval(10)
            while !FileManager.default.fileExists(atPath: entered.path), Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            try expect(FileManager.default.fileExists(atPath: entered.path), "first child did not enter provider create")

            let second = Process()
            second.executableURL = binary
            second.arguments = ["--calendar-registry-process-probe", directory.path, key, "0"]
            try second.run()
            second.waitUntilExit()
            first.waitUntilExit()

            try expect(first.terminationStatus == 0)
            try expect(second.terminationStatus == 42)
            let countURL = directory.appendingPathComponent("calendar-create-count")
            let count = Int((try String(contentsOf: countURL, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines))
            try expect(count == 1)
        }
    }

    await test("CR51 final calendar uniqueness detects a late duplicate") {
        let request = syncRequest(key: "late-calendar-duplicate")
        let registry = await seededRegistry(request)
        let calendar = SyncTestCalendar()
        await calendar.setInjectDuplicateOnRecoverCall(3)
        let receipt = try await makeSyncEngine(registry: registry, calendar: calendar).registryFirstCreate(request)
        try expect(!receipt.succeeded)
        try expect(receipt.stageAfter == .conflict)
        try expect(receipt.recoveryAction?.contains("automatic retry is prohibited") == true)
        try expect(await calendar.count() == 2)
    }

    await test("CR52 final registry uniqueness detects a late duplicate") {
        let request = syncRequest(key: "late-registry-duplicate")
        let registry = await seededRegistry(request)
        await registry.setInjectDuplicateOnLookupCall(6)
        let calendar = SyncTestCalendar()
        let receipt = try await makeSyncEngine(registry: registry, calendar: calendar).registryFirstCreate(request)
        try expect(!receipt.succeeded)
        try expect(receipt.stageAfter == .conflict)
        try expect(receipt.recoveryAction?.contains("automatic retry is prohibited") == true)
        try expect(await calendar.count() == 1)
    }

    await test("CR53 external-organizer authority fails before calendar access") {
        let request = syncRequest(key: "external-authority")
        let registry = SyncTestRegistry()
        var record = canonicalRecord(request)
        record.schedulingAuthority = .externalOrganizer
        await registry.put(record)
        let calendar = SyncTestCalendar()
        let receipt = try await makeSyncEngine(registry: registry, calendar: calendar).registryFirstCreate(request)
        try expect(!receipt.succeeded && receipt.stageAfter == .conflict)
        try expect(await calendar.attempts() == 0)
    }

    await test("CR54 partial Notion pair identity fails before calendar access") {
        let request = syncRequest(key: "partial-pair")
        let registry = SyncTestRegistry()
        var record = canonicalRecord(request)
        record.calendarProvider = "Fixture Calendar"
        await registry.put(record)
        let calendar = SyncTestCalendar()
        let receipt = try await makeSyncEngine(registry: registry, calendar: calendar).registryFirstCreate(request)
        try expect(!receipt.succeeded && receipt.stageAfter == .conflict)
        try expect(await calendar.attempts() == 0)
    }

    await test("CR55 false pre-existing Synced state fails before calendar access") {
        let request = syncRequest(key: "false-synced")
        let registry = SyncTestRegistry()
        var record = canonicalRecord(request)
        record.syncState = .synced
        await registry.put(record)
        let calendar = SyncTestCalendar()
        let receipt = try await makeSyncEngine(registry: registry, calendar: calendar).registryFirstCreate(request)
        try expect(!receipt.succeeded && receipt.stageAfter == .conflict)
        try expect(await calendar.attempts() == 0)
    }

    await test("CR56 concurrent semantic edit is preserved and conflicts") {
        let request = syncRequest(key: "concurrent-notion-edit")
        let registry = await seededRegistry(request)
        let calendar = SyncTestCalendar()
        await calendar.setCreateMode(.delayReturn)
        let task = Task { try await makeSyncEngine(registry: registry, calendar: calendar).registryFirstCreate(request) }
        await calendar.createEntered.wait()
        await registry.mutateTitle("USER EDIT")
        let receipt = try await task.value
        try expect(!receipt.succeeded && receipt.stageAfter == .conflict)
        try expect(await registry.record(id: request.registryEventId)?.title == "USER EDIT")
        try expect(await calendar.count() == 1)
    }

    await test("CR57 production pairing patch never rewrites semantic fields") {
        let entity = scheduleEntityForSyncTests()
        let gateway = SyncRegistryGateway()
        let request = syncRequest(key: "narrow-pairing-patch", registryEventId: "6168af95-595f-4fa1-81d8-7ccdeeee7777")
        let original = canonicalRecord(request)
        await gateway.seed(try notionRow(for: original, entity: entity))
        let store = NotionTimeInstanceRegistryStore(entity: entity, gateway: gateway)
        guard var desired = try await store.get(id: original.id, forceRefresh: true) else {
            throw TestError.assertion("fixture row did not decode")
        }
        let expectedRevision = desired.registryRevision
        desired.title = "SHOULD NOT WRITE"
        desired.semantics = TimeInstanceSemantics(eventClass: .meeting, primaryBlockId: "different-block")
        desired.calendarProvider = "Fixture Calendar"
        desired.calendarId = request.calendarId
        desired.calendarEventId = "calendar-narrow"
        desired.providerExternalId = "provider-narrow"
        desired.syncState = .pendingCreate
        let saved = try await store.savePairing(desired, expectedRevision: expectedRevision)
        try expect(saved.title == original.title)
        try expect(saved.semantics == original.semantics)
        let names = await gateway.updatedFieldNames()
        try expect(!names.contains("EVENT TITLE") && !names.contains("EVENT DATE"))
        try expect(!names.contains("BLOCKS") && !names.contains("Primary BLOCK"))
        try expect(names.contains("Calendar Event ID"))
    }

    await test("CR58 authority participates in the immutable fingerprint") {
        let request = syncRequest(key: "authority-fingerprint")
        var changed = request.manifest
        changed.schedulingAuthority = TimeInstanceSchedulingAuthority.calendar.rawValue
        try expect(changed.fingerprint != request.manifest.fingerprint)
    }

    await test("CR59 transaction identity is stable while attempt identity rotates") {
        let request = syncRequest(key: "stable-transaction-id")
        let registry = await seededRegistry(request)
        let calendar = SyncTestCalendar()
        let store = InMemoryCalendarRegistryTransactionStore()
        let locks = InMemoryCalendarRegistryProcessLockCoordinator(coordinatorNamespace: "receipt-test")
        let engine = makeSyncEngine(registry: registry, calendar: calendar, transactions: store, processLocks: locks)
        let first = try await engine.registryFirstCreate(request)
        let second = try await engine.registryFirstCreate(request)
        try expect(first.succeeded && second.succeeded)
        try expect(!first.operationId.isEmpty && first.operationId == second.operationId)
        try expect(first.attemptId != nil && second.attemptId != nil && first.attemptId != second.attemptId)
    }

    await test("CR60 success receipt exposes coordinator and uniqueness evidence") {
        let request = syncRequest(key: "receipt-evidence")
        let registry = await seededRegistry(request)
        let locks = InMemoryCalendarRegistryProcessLockCoordinator(coordinatorNamespace: "receipt-namespace")
        let receipt = try await makeSyncEngine(registry: registry, processLocks: locks).registryFirstCreate(request)
        try expect(receipt.succeeded)
        try expect(receipt.coordinatorNamespace == "receipt-namespace")
        try expect(receipt.registryIdentityCount == 1 && receipt.calendarIdentityCount == 1)
        try expect(receipt.finalRegistryRevision?.isEmpty == false)
    }

    await test("CR61 successful receipt does not claim a failure-state write") {
        let request = syncRequest(key: "receipt-failure-state-na")
        let registry = await seededRegistry(request)
        let receipt = try await makeSyncEngine(registry: registry).registryFirstCreate(request)
        try expect(receipt.succeeded)
        try expect(!receipt.registryFailureStatePersisted)
    }

    await test("CR62 strict production decoding blocks malformed authority state and revision before EventKit") {
        let entity = scheduleEntityForSyncTests()
        let request = syncRequest(key: "strict-production-decode", registryEventId: "6168af95-595f-4fa1-81d8-7ccdeeee6262")
        let base = try notionRow(for: canonicalRecord(request), entity: entity)
        let variants: [NotionRow] = [
            mutateNotionRow(base, cellName: "Scheduling Authority", remove: true),
            mutateNotionRow(base, cellName: "Scheduling Authority", value: .string("Unknown Authority")),
            mutateNotionRow(base, cellName: "Sync State", remove: true),
            mutateNotionRow(base, cellName: "Sync State", value: .string("Unknown State")),
            mutateNotionRow(base, lastEditedTime: ""),
            mutateNotionRow(base, lastEditedTime: "not-a-date")
        ]
        for row in variants {
            let gateway = SyncRegistryGateway()
            await gateway.seed(row)
            let calendar = SyncTestCalendar()
            let store = NotionTimeInstanceRegistryStore(entity: entity, gateway: gateway)
            let receipt = try await makeSyncEngine(registry: store, calendar: calendar).registryFirstCreate(request)
            try expect(!receipt.succeeded && receipt.stageAfter == .conflict)
            let counts = await calendar.accessCounts()
            try expect(counts.qualify == 0 && counts.item == 0 && counts.recover == 0 && counts.create == 0)
        }
    }

    await test("CR63 non-registry authority performs zero EventKit calls") {
        let request = syncRequest(key: "authority-zero-access")
        let registry = SyncTestRegistry()
        var record = canonicalRecord(request)
        record.schedulingAuthority = .externalOrganizer
        await registry.put(record)
        let calendar = SyncTestCalendar()
        let receipt = try await makeSyncEngine(registry: registry, calendar: calendar).registryFirstCreate(request)
        try expect(!receipt.succeeded && receipt.stageAfter == .conflict)
        let counts = await calendar.accessCounts()
        try expect(counts.qualify == 0 && counts.item == 0 && counts.recover == 0 && counts.create == 0)
    }

    await test("CR64 ledger loss with durable Notion invocation enters operator review") {
        let request = syncRequest(key: "ledger-loss-invocation")
        let registry = SyncTestRegistry()
        var record = canonicalRecord(request)
        record.createInvocationId = "create-invocation"
        record.syncWriterToken = "writer-ledger-loss"
        record.syncRevision = 1
        await registry.put(record)
        let calendar = SyncTestCalendar()
        let receipt = try await makeSyncEngine(registry: registry, calendar: calendar).registryFirstCreate(request)
        try expect(!receipt.succeeded && receipt.stageAfter == .operatorReview)
        try expect(receipt.recoveryAction?.contains("operator review") == true)
        let counts = await calendar.accessCounts()
        try expect(counts.qualify == 0 && counts.item == 0 && counts.recover == 0 && counts.create == 0)
    }

    await test("CR65 restart from pair identity persisted continues forward without recreate") {
        let request = syncRequest(key: "restart-pair-persisted")
        let registry = SyncTestRegistry()
        var record = canonicalRecord(request)
        record.createInvocationId = "create-invocation"
        record.syncWriterToken = "writer-pair"
        record.syncRevision = 2
        record.calendarProvider = "Fixture Calendar"
        record.calendarId = request.calendarId
        record.calendarEventId = "calendar-existing"
        record.providerExternalId = "provider-existing"
        record.calendarItemURL = "calshow:existing"
        await registry.put(record)
        let calendar = SyncTestCalendar()
        await calendar.seed(calendarItem(request))
        let store = InMemoryCalendarRegistryTransactionStore()
        var tx = try await claim(store, key: request.idempotencyKey, fingerprint: request.manifest.fingerprint, exclusive: true)
        tx.registryEventId = request.registryEventId
        tx.stage = .registryAuthorized
        tx = try await store.save(tx)
        tx.createInvocationId = "create-invocation"
        tx.syncWriterToken = "writer-pair"
        tx.syncRevision = 2
        tx.stage = .createInvocationPersisted
        tx = try await store.save(tx)
        tx.calendarEventId = "calendar-existing"
        tx.calendarId = request.calendarId
        tx.providerExternalId = "provider-existing"
        tx.stage = .calendarIdentified
        tx = try await store.save(tx)
        tx.stage = .pairIdentityPersisted
        tx = try await store.save(tx)
        _ = try await store.release(tx)
        let receipt = try await makeSyncEngine(registry: registry, calendar: calendar, transactions: store)
            .registryFirstCreate(request)
        try expect(receipt.succeeded && receipt.stageAfter == .complete)
        try expect(await calendar.attempts() == 0)
    }

    await test("CR66 restart from synced Notion and sync-evidence ledger reconciles complete") {
        let request = syncRequest(key: "restart-sync-evidence")
        let sourceRegistry = await seededRegistry(request)
        let sourceCalendar = SyncTestCalendar()
        let first = try await makeSyncEngine(registry: sourceRegistry, calendar: sourceCalendar).registryFirstCreate(request)
        guard let finalRecord = first.record, let finalItem = first.calendarItem else {
            throw TestError.assertion("source pair did not complete")
        }
        let registry = SyncTestRegistry()
        await registry.put(finalRecord)
        let calendar = SyncTestCalendar()
        await calendar.seed(finalItem)
        let store = InMemoryCalendarRegistryTransactionStore()
        var tx = try await claim(store, key: request.idempotencyKey, fingerprint: request.manifest.fingerprint, exclusive: true)
        tx.registryEventId = request.registryEventId
        tx.stage = .registryAuthorized
        tx = try await store.save(tx)
        tx.createInvocationId = finalRecord.createInvocationId
        tx.syncWriterToken = finalRecord.syncWriterToken
        tx.syncRevision = finalRecord.syncRevision
        tx.stage = .createInvocationPersisted
        tx = try await store.save(tx)
        tx.calendarEventId = finalItem.localEventId
        tx.calendarId = finalItem.calendarId
        tx.providerExternalId = finalItem.providerExternalId
        tx.stage = .calendarIdentified
        tx = try await store.save(tx)
        tx.stage = .pairIdentityPersisted
        tx = try await store.save(tx)
        tx.lastVerifiedAt = finalRecord.lastSyncedAt
        tx.stage = .syncEvidencePersisted
        tx = try await store.save(tx)
        _ = try await store.release(tx)
        let receipt = try await makeSyncEngine(registry: registry, calendar: calendar, transactions: store)
            .registryFirstCreate(request)
        try expect(receipt.succeeded && receipt.stageAfter == .complete)
        try expect(await calendar.attempts() == 0)
        try expect(await registry.savedCount() == 0)
    }

    await test("CR67 production pairing PATCH refuses lost writer token") {
        let entity = scheduleEntityForSyncTests()
        let request = syncRequest(key: "lost-writer-token", registryEventId: "6168af95-595f-4fa1-81d8-7ccdeeee6767")
        let gateway = SyncRegistryGateway()
        await gateway.seed(try notionRow(for: canonicalRecord(request), entity: entity))
        let store = NotionTimeInstanceRegistryStore(entity: entity, gateway: gateway)
        guard var desired = try await store.get(id: request.registryEventId, forceRefresh: true) else {
            throw TestError.assertion("strict fixture did not decode")
        }
        let expectedRevision = desired.registryRevision
        desired.createInvocationId = "create-invocation"
        desired.syncWriterToken = "writer-expected"
        desired.syncRevision = 1
        await gateway.setDropWriterTokenOnUpdate(true)
        do {
            _ = try await store.savePairing(desired, expectedRevision: expectedRevision)
            throw TestError.assertion("lost writer token should conflict")
        } catch CalendarRegistrySyncError.identityConflict {}
    }

    await test("CR68 EventKit metadata v2 round-trips Create Invocation ID") {
        let request = syncRequest(key: "metadata-v2")
        let identity = CalendarRegistryCalendarMetadata.Identity(
            syncKey: request.idempotencyKey,
            operationFingerprint: request.manifest.fingerprint,
            createInvocationId: "create-invocation"
        )
        let notes = try CalendarRegistryCalendarMetadata.append(to: "User note", identity: identity)
        try expect(try CalendarRegistryCalendarMetadata.parse(notes) == identity)
        try expect(try CalendarRegistryCalendarMetadata.userNotes(from: notes) == "User note")
        try expect(notes.contains("BRIDGE-CALENDAR-REGISTRY v2"))
    }

    await test("CR69 production EventKit recovery is bounded and does not claim global absence") {
        let request = syncRequest(key: "bounded-recovery")
        let store = PersistentCalendarStore()
        let farStart = request.start.addingTimeInterval(90 * 86_400)
        let farEnd = request.end.addingTimeInterval(90 * 86_400)
        let notes = try CalendarRegistryCalendarMetadata.append(
            to: request.notes,
            identity: .init(
                syncKey: request.idempotencyKey,
                operationFingerprint: request.manifest.fingerprint,
                createInvocationId: "create-invocation"
            )
        )
        await store.seed(CalendarEvent(
            id: "far-event",
            title: request.title,
            start: CalendarRegistryISO.string(farStart),
            end: CalendarRegistryISO.string(farEnd),
            allDay: false,
            calendarId: request.calendarId,
            calendarTitle: "Private Smoke",
            location: request.location,
            notes: notes,
            timeZoneIdentifier: request.timeZoneIdentifier,
            externalId: "far-external"
        ))
        let provider = CalendarStoringSyncProvider(store: store, allowlistedCalendarIds: [request.calendarId])
        let matches = try await provider.recover(CalendarRecoveryQuery(
            syncKey: request.idempotencyKey,
            operationFingerprint: request.manifest.fingerprint,
            createInvocationId: "create-invocation",
            calendarId: request.calendarId,
            title: request.title,
            start: request.start,
            end: request.end
        ))
        try expect(matches.isEmpty)
    }

    await test("CR70 success receipt reports bounded owned-identity evidence") {
        let request = syncRequest(key: "bounded-receipt")
        let registry = await seededRegistry(request)
        let receipt = try await makeSyncEngine(registry: registry).registryFirstCreate(request)
        try expect(receipt.succeeded)
        try expect(receipt.createInvocationId == "create-invocation")
        try expect(receipt.syncWriterToken?.isEmpty == false && (receipt.syncRevision ?? 0) > 0)
        try expect(receipt.calendarSearchScopes.contains { $0.contains("window=") && $0.contains("channels=") })
        try expect(!receipt.calendarSearchScopes.contains { $0.lowercased().contains("global") })
    }

    await test("CR71 permissive pre-existing ledger is refused") {
        try await withTempDirectory { directory in
            let url = directory.appendingPathComponent("permissive.sqlite3")
            try Data().write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            do {
                _ = try SQLiteCalendarRegistryTransactionStore(url: url)
                throw TestError.assertion("permissive ledger should fail trust validation")
            } catch CalendarRegistryTransactionStoreError.storageFailure {}
        }
    }

    await test("CR72 symlinked ledger is refused") {
        try await withTempDirectory { directory in
            let target = directory.appendingPathComponent("target.sqlite3")
            let link = directory.appendingPathComponent("linked.sqlite3")
            try Data().write(to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            do {
                _ = try SQLiteCalendarRegistryTransactionStore(url: link)
                throw TestError.assertion("symlinked ledger should fail trust validation")
            } catch CalendarRegistryTransactionStoreError.storageFailure {}
        }
    }

    await test("CR73 hard-linked ledger is refused") {
        try await withTempDirectory { directory in
            let target = directory.appendingPathComponent("target.sqlite3")
            let link = directory.appendingPathComponent("hard.sqlite3")
            try Data().write(to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            try FileManager.default.linkItem(at: target, to: link)
            do {
                _ = try SQLiteCalendarRegistryTransactionStore(url: link)
                throw TestError.assertion("hard-linked ledger should fail trust validation")
            } catch CalendarRegistryTransactionStoreError.storageFailure {}
        }
    }

    await test("CR74 coordinator namespace derives from filesystem identity") {
        try await withTempDirectory { directory in
            let aRoot = directory.appendingPathComponent("a", isDirectory: true)
            let bRoot = directory.appendingPathComponent("b", isDirectory: true)
            let first = try FileCalendarRegistryProcessLockCoordinator(rootURL: aRoot)
            let second = try FileCalendarRegistryProcessLockCoordinator(rootURL: aRoot)
            let other = try FileCalendarRegistryProcessLockCoordinator(rootURL: bRoot)
            try expect(first.coordinatorNamespace == second.coordinatorNamespace)
            try expect(first.coordinatorNamespace != other.coordinatorNamespace)
        }
    }

    await test("CR75 SQLite v4 round-trips invocation and writer evidence") {
        try await withTempDirectory { directory in
            let url = directory.appendingPathComponent("v4.sqlite3")
            let first = try SQLiteCalendarRegistryTransactionStore(url: url)
            var tx = try await claim(first, key: "v4-roundtrip", exclusive: true)
            tx.registryEventId = "page-v4"
            tx.stage = .registryAuthorized
            tx = try await first.save(tx)
            tx.createInvocationId = "create-v4"
            tx.syncWriterToken = "writer-v4"
            tx.syncRevision = 3
            tx.stage = .createInvocationPersisted
            tx = try await first.save(tx)
            _ = try await first.release(tx)
            let second = try SQLiteCalendarRegistryTransactionStore(url: url)
            let stored = try await second.get(idempotencyKey: "v4-roundtrip")
            try expect(stored?.createInvocationId == "create-v4")
            try expect(stored?.syncWriterToken == "writer-v4")
            try expect(stored?.syncRevision == 3)
        }
    }

    await test("CR76 pairing source exposes no public Notion create or repair") {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("TheBridge/Modules/Time/CalendarRegistrySyncEngine.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        try expect(!source.contains("public func create(_ record: TimeInstanceRecord)"))
        try expect(!source.contains("public func repair(id: String, from record: TimeInstanceRecord)"))
        try expect(!source.contains("public struct PartialRegistryCreateError"))
    }

    await test("CR77 symlinked coordinator root is refused") {
        try await withTempDirectory { directory in
            let target = directory.appendingPathComponent("real-root", isDirectory: true)
            let link = directory.appendingPathComponent("linked-root", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            do {
                _ = try FileCalendarRegistryProcessLockCoordinator(rootURL: link)
                throw TestError.assertion("symlinked coordinator root should fail")
            } catch CalendarRegistryProcessLockError.storageFailure {}
        }
    }

    await test("CR78 unsafe SQLite WAL sidecar is refused") {
        try await withTempDirectory { directory in
            let url = directory.appendingPathComponent("sidecar.sqlite3")
            do {
                let store = try SQLiteCalendarRegistryTransactionStore(url: url)
                let tx = try await claim(store, key: "sidecar-seed", exclusive: true)
                _ = try await store.release(tx)
            }
            let sidecar = URL(fileURLWithPath: url.path + "-wal")
            try Data("unsafe".utf8).write(to: sidecar)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sidecar.path)
            do {
                _ = try SQLiteCalendarRegistryTransactionStore(url: url)
                throw TestError.assertion("unsafe WAL sidecar should fail")
            } catch CalendarRegistryTransactionStoreError.storageFailure {}
        }
    }

    await test("CR79 owned coordinator directory permissions are repaired to 0700") {
        try await withTempDirectory { directory in
            let root = directory.appendingPathComponent("repair-root", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            _ = try FileCalendarRegistryProcessLockCoordinator(rootURL: root)
            let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
            try expect(mode & 0o077 == 0)
        }
    }

    await test("CR80 lock owner evidence omits raw idempotency key") {
        try await withTempDirectory { directory in
            let locks = try FileCalendarRegistryProcessLockCoordinator(rootURL: directory)
            let key = "sensitive-operation-label"
            let handle = try locks.acquire(idempotencyKey: key)
            defer { try? handle.release() }
            let lockURL = locks.lockURL(idempotencyKey: key)
            let evidence = try String(contentsOf: lockURL, encoding: .utf8)
            try expect(!evidence.contains(key))
            try expect(evidence.contains("pid=") && evidence.contains("lock="))
        }
    }

    let crashCheckpoints = CalendarRegistryDurableCheckpoint.allCases
    for (offset, checkpoint) in crashCheckpoints.enumerated() {
        await test("CR\(81 + offset) process termination after \(checkpoint.rawValue) remains at-most-once") {
            try await withTempDirectory { directory in
                let binary = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
                let key = "crash-\(checkpoint.rawValue)"

                let crashed = Process()
                crashed.executableURL = binary
                crashed.arguments = [
                    "--calendar-registry-crash-probe", directory.path, key, checkpoint.rawValue
                ]
                try crashed.run()
                crashed.waitUntilExit()
                try expect(
                    crashed.terminationReason == .exit && crashed.terminationStatus == 86,
                    "checkpoint child did not terminate at \(checkpoint.rawValue): reason=\(crashed.terminationReason) status=\(crashed.terminationStatus)"
                )

                for attempt in 1...2 {
                    let recovery = Process()
                    recovery.executableURL = binary
                    recovery.arguments = [
                        "--calendar-registry-crash-probe", directory.path, key, "recover"
                    ]
                    try recovery.run()
                    recovery.waitUntilExit()
                    try expect(
                        recovery.terminationReason == .exit && recovery.terminationStatus == 0,
                        "recovery \(attempt) failed after \(checkpoint.rawValue): reason=\(recovery.terminationReason) status=\(recovery.terminationStatus)"
                    )
                }

                let outcomeURL = directory.appendingPathComponent("crash-probe-outcome.json")
                let outcome = try JSONDecoder().decode(
                    CrashProbeOutcome.self, from: Data(contentsOf: outcomeURL)
                )
                let reviewOnly = checkpoint == .createInvocationRegistryPersisted
                    || checkpoint == .createInvocationLedgerPersisted
                try expect(outcome.calendarCreateCount == (reviewOnly ? 0 : 1))
                try expect(outcome.succeeded == !reviewOnly)
                try expect(outcome.stage == (reviewOnly
                    ? CalendarRegistryTransactionStage.operatorReview.rawValue
                    : CalendarRegistryTransactionStage.complete.rawValue))
            }
        }
    }

    await test("CR96 legacy procedural recovery helpers are absent") {
        let sourceURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("TheBridge/Modules/Time/CalendarRegistrySyncEngine.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        try expect(!source.contains("func resolveOrCreateCalendar("))
        try expect(!source.contains("func adoptExistingCalendarIdentity("))
    }

    await test("CR97 offset-only Notion date without timeZone still pairs") {
        let request = syncRequest(
            key: "offset-only-date",
            registryEventId: "00000000000000000000000000000097"
        )
        let entity = scheduleEntityForSyncTests()
        let base = try notionRow(for: canonicalRecord(request), entity: entity)
        // Live Notion often returns offset ISO datetimes with time_zone=null.
        let offsetOnlyDate = Value.object([
            "start": .string(CalendarRegistryISO.string(request.start)),
            "end": .string(CalendarRegistryISO.string(request.end))
        ])
        let row = mutateNotionRow(base, cellName: "EVENT DATE", value: offsetOnlyDate)
        let gateway = SyncRegistryGateway()
        await gateway.seed(row)
        let calendar = SyncTestCalendar()
        let store = NotionTimeInstanceRegistryStore(entity: entity, gateway: gateway)
        let receipt = try await makeSyncEngine(registry: store, calendar: calendar).registryFirstCreate(request)
        try expect(receipt.succeeded)
        try expect(await calendar.persistedCount() == 1)
    }

    await test("CR98 Notion minute-truncated Last Synced At still completes") {
        let request = syncRequest(
            key: "minute-truncated-synced-at",
            registryEventId: "00000000000000000000000000000098"
        )
        let entity = scheduleEntityForSyncTests()
        let gateway = SyncRegistryGateway()
        await gateway.setTruncateSyncedAtToMinute(true)
        await gateway.seed(try notionRow(for: canonicalRecord(request), entity: entity))
        let calendar = SyncTestCalendar()
        let store = NotionTimeInstanceRegistryStore(entity: entity, gateway: gateway)
        // Sub-minute clock; gateway truncates Last Synced At to :00 like live Notion.
        let engine = CalendarRegistrySyncEngine(
            registry: store,
            calendar: calendar,
            transactions: InMemoryCalendarRegistryTransactionStore(),
            processLocks: InMemoryCalendarRegistryProcessLockCoordinator(),
            operationGate: CalendarRegistryOperationGate(),
            clock: { Date(timeIntervalSince1970: 1_800_000_045) },
            makeOperationId: { UUID().uuidString.lowercased() },
            makeLeaseToken: { UUID().uuidString.lowercased() },
            makeCreateInvocationId: { "create-invocation" },
            makeSyncWriterToken: { UUID().uuidString.lowercased() },
            leaseDuration: 600
        )
        let receipt = try await engine.registryFirstCreate(request)
        try expect(receipt.succeeded)
        try expect(await calendar.persistedCount() == 1)
        try expect(receipt.stageAfter == .complete)
    }

}

// MARK: - Child-process probe

func calendarRegistryProcessProbeExitCodeIfRequested() -> Int32? {
    let args = CommandLine.arguments
    if let index = args.firstIndex(of: "--calendar-registry-crash-probe"), args.count >= index + 4 {
        return calendarRegistryCrashProbeExitCode(
            root: URL(fileURLWithPath: args[index + 1], isDirectory: true),
            key: args[index + 2],
            checkpointRawValue: args[index + 3]
        )
    }
    guard let index = args.firstIndex(of: "--calendar-registry-process-probe"), args.count >= index + 4 else {
        return nil
    }
    let root = URL(fileURLWithPath: args[index + 1], isDirectory: true)
    let key = args[index + 2]
    let holdMilliseconds = UInt64(args[index + 3]) ?? 0
    let semaphore = DispatchSemaphore(value: 0)
    let result = Mutex<Int32>(1)
    Task.detached {
        do {
            let request = RegistryFirstTimeInstanceRequest(
                idempotencyKey: key,
                registryEventId: "probe-event",
                title: "Probe",
                start: Date(timeIntervalSince1970: 1_800_010_000),
                end: Date(timeIntervalSince1970: 1_800_013_600),
                timeZoneIdentifier: "America/Chicago",
                calendarId: "cal-private",
                notes: "Probe",
                semantics: TimeInstanceSemantics(eventClass: .focus, primaryBlockId: "block-probe")
            )
            let registry = ProbeRegistry(request: request)
            let calendar = ProbeCalendar(root: root, holdMilliseconds: holdMilliseconds)
            let ledger = try SQLiteCalendarRegistryTransactionStore(url: root.appendingPathComponent("probe.sqlite3"))
            let locks = try FileCalendarRegistryProcessLockCoordinator(
                rootURL: root.appendingPathComponent("locks", isDirectory: true)
            )
            let engine = CalendarRegistrySyncEngine(
                registry: registry,
                calendar: calendar,
                transactions: ledger,
                processLocks: locks,
                operationGate: CalendarRegistryOperationGate(),
                clock: { Date(timeIntervalSince1970: 1_800_000_000) },
                leaseDuration: 0.1
            )
            let receipt = try await engine.registryFirstCreate(request)
            result.withLock { value in
                if receipt.succeeded { value = 0 }
                else if receipt.discrepancy?.contains("already active in another process") == true { value = 42 }
                else { value = 2 }
            }
        } catch {
            fputs("probe failed: \(error)\n", stderr)
            result.withLock { $0 = 3 }
        }
        semaphore.signal()
    }
    semaphore.wait()
    return result.withLock { $0 }
}

private struct CrashProbeOutcome: Codable {
    var succeeded: Bool
    var stage: String
    var calendarCreateCount: Int
}

private struct CrashRegistryState: Codable {
    var calendarProvider: String?
    var calendarId: String?
    var calendarEventId: String?
    var providerExternalId: String?
    var calendarItemURL: String?
    var createInvocationId: String?
    var syncWriterToken: String?
    var syncRevision: Int
    var syncState: TimeInstanceSyncState
    var lastSyncedAt: Date?
    var registryUpdatedAt: Date
    var calendarUpdatedAt: Date?
    var syncHash: String
    var lastSyncError: String?
    var registryRevision: String?

    init(_ record: TimeInstanceRecord) {
        calendarProvider = record.calendarProvider
        calendarId = record.calendarId
        calendarEventId = record.calendarEventId
        providerExternalId = record.providerExternalId
        calendarItemURL = record.calendarItemURL
        createInvocationId = record.createInvocationId
        syncWriterToken = record.syncWriterToken
        syncRevision = record.syncRevision
        syncState = record.syncState
        lastSyncedAt = record.lastSyncedAt
        registryUpdatedAt = record.registryUpdatedAt
        calendarUpdatedAt = record.calendarUpdatedAt
        syncHash = record.syncHash
        lastSyncError = record.lastSyncError
        registryRevision = record.registryRevision
    }

    func applying(to base: TimeInstanceRecord) -> TimeInstanceRecord {
        var record = base
        record.calendarProvider = calendarProvider
        record.calendarId = calendarId
        record.calendarEventId = calendarEventId
        record.providerExternalId = providerExternalId
        record.calendarItemURL = calendarItemURL
        record.createInvocationId = createInvocationId
        record.syncWriterToken = syncWriterToken
        record.syncRevision = syncRevision
        record.syncState = syncState
        record.lastSyncedAt = lastSyncedAt
        record.registryUpdatedAt = registryUpdatedAt
        record.calendarUpdatedAt = calendarUpdatedAt
        record.syncHash = syncHash
        record.lastSyncError = lastSyncError
        record.registryRevision = registryRevision
        return record
    }
}

private func calendarRegistryCrashProbeExitCode(
    root: URL,
    key: String,
    checkpointRawValue: String
) -> Int32 {
    let semaphore = DispatchSemaphore(value: 0)
    let result = Mutex<Int32>(1)
    Task.detached {
        do {
            let request = RegistryFirstTimeInstanceRequest(
                idempotencyKey: key,
                registryEventId: "crash-probe-event",
                title: "Crash Probe",
                start: Date(timeIntervalSince1970: 1_800_020_000),
                end: Date(timeIntervalSince1970: 1_800_023_600),
                timeZoneIdentifier: "America/Chicago",
                calendarId: "cal-private",
                notes: "Crash Probe",
                semantics: TimeInstanceSemantics(eventClass: .focus, primaryBlockId: "block-crash-probe")
            )
            let registry = try CrashProbeRegistry(root: root, request: request)
            let calendar = ProbeCalendar(root: root, holdMilliseconds: 0)
            let ledger = try SQLiteCalendarRegistryTransactionStore(
                url: root.appendingPathComponent("crash-ledger.sqlite3")
            )
            let locks = try FileCalendarRegistryProcessLockCoordinator(
                rootURL: root.appendingPathComponent("crash-locks", isDirectory: true)
            )
            let selected = CalendarRegistryDurableCheckpoint(rawValue: checkpointRawValue)
            let engine = CalendarRegistrySyncEngine(
                registry: registry,
                calendar: calendar,
                transactions: ledger,
                processLocks: locks,
                operationGate: CalendarRegistryOperationGate(),
                clock: { Date(timeIntervalSince1970: 1_800_000_000) },
                durableCheckpoint: { observed in
                    if observed == selected { _exit(86) }
                },
                leaseDuration: 0.1
            )
            let receipt = try await engine.registryFirstCreate(request)
            let count = crashProbeCalendarCreateCount(root: root)
            let outcome = CrashProbeOutcome(
                succeeded: receipt.succeeded,
                stage: receipt.stageAfter.rawValue,
                calendarCreateCount: count
            )
            try JSONEncoder().encode(outcome).write(
                to: root.appendingPathComponent("crash-probe-outcome.json"), options: .atomic
            )
            result.withLock { value in
                if selected != nil {
                    value = 4
                } else if receipt.succeeded || receipt.stageAfter == .operatorReview {
                    value = count <= 1 ? 0 : 5
                } else {
                    value = 6
                }
            }
        } catch {
            fputs("crash probe failed: \(error)\n", stderr)
            result.withLock { $0 = 7 }
        }
        semaphore.signal()
    }
    semaphore.wait()
    return result.withLock { $0 }
}

private func crashProbeCalendarCreateCount(root: URL) -> Int {
    let url = root.appendingPathComponent("calendar-create-count")
    return (try? String(contentsOf: url, encoding: .utf8))
        .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
}

private actor CrashProbeRegistry: TimeInstanceRegistryStoring {
    private let stateURL: URL
    private let request: RegistryFirstTimeInstanceRequest

    init(root: URL, request: RegistryFirstTimeInstanceRequest) throws {
        self.stateURL = root.appendingPathComponent("crash-registry-state.json")
        self.request = request
        if !FileManager.default.fileExists(atPath: stateURL.path) {
            try JSONEncoder().encode(CrashRegistryState(canonicalRecord(request)))
                .write(to: stateURL, options: .atomic)
        }
    }

    private func load() throws -> TimeInstanceRecord {
        let state = try JSONDecoder().decode(
            CrashRegistryState.self, from: Data(contentsOf: stateURL)
        )
        return state.applying(to: canonicalRecord(request))
    }

    private func persist(_ record: TimeInstanceRecord) throws {
        try JSONEncoder().encode(CrashRegistryState(record)).write(to: stateURL, options: .atomic)
    }

    func findBySyncKey(_ syncKey: String) async throws -> RegistryIdentityLookup {
        let record = try load()
        return RegistryIdentityLookup(records: record.syncKey == syncKey ? [record] : [], source: .live)
    }

    func readIdentity(id: String, forceRefresh: Bool) async throws -> RegistryRecordIdentityRead {
        _ = forceRefresh
        let record = try load()
        return id == record.id ? .decoded(record) : .missing
    }

    func get(id: String, forceRefresh: Bool) async throws -> TimeInstanceRecord? {
        _ = forceRefresh
        let record = try load()
        return id == record.id ? record : nil
    }

    func savePairing(_ proposed: TimeInstanceRecord, expectedRevision: String?) async throws -> TimeInstanceRecord {
        var saved = try load()
        guard saved.registryRevision == expectedRevision else {
            throw CalendarRegistrySyncError.identityConflict("crash probe revision mismatch")
        }
        saved.calendarProvider = proposed.calendarProvider
        saved.calendarId = proposed.calendarId
        saved.calendarEventId = proposed.calendarEventId
        saved.providerExternalId = proposed.providerExternalId
        saved.calendarItemURL = proposed.calendarItemURL
        saved.createInvocationId = proposed.createInvocationId
        saved.syncWriterToken = proposed.syncWriterToken
        saved.syncRevision = proposed.syncRevision
        saved.syncState = proposed.syncState
        saved.registryUpdatedAt = proposed.registryUpdatedAt
        saved.syncHash = proposed.syncHash
        saved.lastSyncError = proposed.lastSyncError
        saved.lastSyncedAt = proposed.lastSyncedAt
        saved.calendarUpdatedAt = proposed.calendarUpdatedAt
        saved.registryRevision = "crash-revision-\(UUID().uuidString.lowercased())"
        try persist(saved)
        return saved
    }
}

private actor ProbeRegistry: TimeInstanceRegistryStoring {
    private var record: TimeInstanceRecord
    init(request: RegistryFirstTimeInstanceRequest) { record = canonicalRecord(request) }
    func findBySyncKey(_ syncKey: String) async throws -> RegistryIdentityLookup {
        RegistryIdentityLookup(records: record.syncKey == syncKey ? [record] : [], source: .live)
    }
    func readIdentity(id: String, forceRefresh: Bool) async throws -> RegistryRecordIdentityRead {
        _ = forceRefresh
        return id == record.id ? .decoded(record) : .missing
    }
    func get(id: String, forceRefresh: Bool) async throws -> TimeInstanceRecord? {
        _ = forceRefresh
        return id == record.id ? record : nil
    }
    func savePairing(_ record: TimeInstanceRecord, expectedRevision: String?) async throws -> TimeInstanceRecord {
        guard self.record.registryRevision == expectedRevision else {
            throw CalendarRegistrySyncError.identityConflict("probe revision mismatch")
        }
        var saved = self.record
        saved.calendarProvider = record.calendarProvider
        saved.calendarId = record.calendarId
        saved.calendarEventId = record.calendarEventId
        saved.providerExternalId = record.providerExternalId
        saved.calendarItemURL = record.calendarItemURL
        saved.createInvocationId = record.createInvocationId
        saved.syncWriterToken = record.syncWriterToken
        saved.syncRevision = record.syncRevision
        saved.syncState = record.syncState
        saved.registryUpdatedAt = record.registryUpdatedAt
        saved.syncHash = record.syncHash
        saved.lastSyncError = record.lastSyncError
        saved.lastSyncedAt = record.lastSyncedAt
        saved.calendarUpdatedAt = record.calendarUpdatedAt
        saved.registryRevision = UUID().uuidString
        self.record = saved
        return saved
    }
}

private actor ProbeCalendar: CalendarSyncProviding {
    private let root: URL
    private let holdMilliseconds: UInt64
    init(root: URL, holdMilliseconds: UInt64) {
        self.root = root
        self.holdMilliseconds = holdMilliseconds
    }
    func qualify(calendarId: String) async throws -> CalendarQualification {
        CalendarQualification(
            calendarId: calendarId, title: "Private", allowsModify: true,
            explicitlyAllowlisted: true, calendarType: "local", sourceType: "local",
            qualifiedForPrivateSmoke: true
        )
    }
    func create(_ draft: ExternalCalendarDraft) async throws -> ExternalCalendarItem {
        let item = ExternalCalendarItem(
            provider: "Probe Calendar",
            calendarId: draft.calendarId,
            localEventId: "probe-calendar-event",
            providerExternalId: "probe-external",
            syncKey: draft.syncKey,
            operationFingerprint: draft.operationFingerprint,
            createInvocationId: draft.createInvocationId,
            title: draft.title,
            start: draft.start,
            end: draft.end,
            timeZoneIdentifier: draft.timeZoneIdentifier,
            location: draft.location,
            notes: draft.notes,
            updatedAt: nil
        )
        let payload: [String: Any] = [
            "syncKey": draft.syncKey,
            "fingerprint": draft.operationFingerprint,
            "createInvocationId": draft.createInvocationId,
            "title": draft.title,
            "start": CalendarRegistryISO.string(draft.start),
            "end": CalendarRegistryISO.string(draft.end),
            "timezone": draft.timeZoneIdentifier,
            "calendarId": draft.calendarId,
            "location": draft.location as Any,
            "notes": draft.notes as Any
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        try data.write(to: root.appendingPathComponent("calendar-item.json"), options: .atomic)
        let countURL = root.appendingPathComponent("calendar-create-count")
        let old = (try? String(contentsOf: countURL, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        try String(old + 1).write(to: countURL, atomically: true, encoding: .utf8)
        try Data().write(to: root.appendingPathComponent("provider-entered"), options: .atomic)
        if holdMilliseconds > 0 {
            try await Task.sleep(nanoseconds: holdMilliseconds * 1_000_000)
        }
        return item
    }
    func item(id: String) async throws -> ExternalCalendarItem? {
        guard id == "probe-calendar-event" else { return nil }
        return try load()
    }
    func recover(_ query: CalendarRecoveryQuery) async throws -> [ExternalCalendarItem] {
        guard let item = try load() else { return [] }
        return item.syncKey == query.syncKey
            && item.operationFingerprint == query.operationFingerprint
            && (query.createInvocationId == nil || item.createInvocationId == query.createInvocationId) ? [item] : []
    }
    private func load() throws -> ExternalCalendarItem? {
        let url = root.appendingPathComponent("calendar-item.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        guard let object,
              let key = object["syncKey"] as? String,
              let fingerprint = object["fingerprint"] as? String,
              let createInvocationId = object["createInvocationId"] as? String,
              let title = object["title"] as? String,
              let startRaw = object["start"] as? String,
              let endRaw = object["end"] as? String,
              let start = CalendarRegistryISO.date(startRaw),
              let end = CalendarRegistryISO.date(endRaw),
              let timezone = object["timezone"] as? String,
              let calendarId = object["calendarId"] as? String else { return nil }
        return ExternalCalendarItem(
            provider: "Probe Calendar",
            calendarId: calendarId,
            localEventId: "probe-calendar-event",
            providerExternalId: "probe-external",
            syncKey: key,
            operationFingerprint: fingerprint,
            createInvocationId: createInvocationId,
            title: title,
            start: start,
            end: end,
            timeZoneIdentifier: timezone,
            location: object["location"] as? String,
            notes: object["notes"] as? String,
            updatedAt: nil
        )
    }
}
