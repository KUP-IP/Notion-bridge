// CalendarRegistrySyncEngine.swift — disabled-by-default registry-first pairing core
//
// Scope is intentionally narrow: one private, non-recurring, timed EventKit
// event paired with one Notion EVENT. Calendar-first import, recurrence,
// destructive rollback, attendees, RSVP writes, and public MCP registration are
// outside this implementation.

import Foundation
import MCP

public enum TimeInstanceEventClass: String, Codable, Sendable, CaseIterable {
    case focus = "FOCUS"
    case please = "PLEASE"
    case meeting = "Meeting"
    case presentation = "Presentation"
    case appointment = "Appointment"
    case travel = "Travel"
    case buffer = "Buffer"
}

public enum TimeInstanceSchedulingAuthority: String, Codable, Sendable {
    case registry = "Registry"
    case calendar = "Calendar"
    case externalOrganizer = "External Organizer"
}

public enum TimeInstanceSyncState: String, Codable, Sendable {
    case pendingCreate = "Pending Create"
    case synced = "Synced"
    case conflict = "Conflict"
    case detached = "Detached"
    case error = "Error"
}

public struct TimeInstanceSemantics: Codable, Sendable, Equatable {
    public var eventClass: TimeInstanceEventClass
    public var meetingType: String?
    public var primaryBlockId: String
    public var blockIds: [String]
    public var projectIds: [String]
    public var contactIds: [String]

    public init(
        eventClass: TimeInstanceEventClass,
        meetingType: String? = nil,
        primaryBlockId: String,
        blockIds: [String] = [],
        projectIds: [String] = [],
        contactIds: [String] = []
    ) {
        self.eventClass = eventClass
        self.meetingType = meetingType
        self.primaryBlockId = primaryBlockId
        self.blockIds = blockIds.isEmpty ? [primaryBlockId] : blockIds
        self.projectIds = projectIds
        self.contactIds = contactIds
    }
}

public struct ExternalCalendarItem: Sendable, Equatable {
    public var provider: String
    public var calendarId: String
    public var localEventId: String
    public var providerExternalId: String?
    public var itemURL: String?
    public var syncKey: String?
    public var title: String
    public var start: Date
    public var end: Date
    public var timeZoneIdentifier: String
    public var location: String?
    public var notes: String?
    public var updatedAt: Date
    public var isRecurring: Bool

    public init(
        provider: String,
        calendarId: String,
        localEventId: String,
        providerExternalId: String? = nil,
        itemURL: String? = nil,
        syncKey: String? = nil,
        title: String,
        start: Date,
        end: Date,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        location: String? = nil,
        notes: String? = nil,
        updatedAt: Date,
        isRecurring: Bool = false
    ) {
        self.provider = provider
        self.calendarId = calendarId
        self.localEventId = localEventId
        self.providerExternalId = providerExternalId
        self.itemURL = itemURL
        self.syncKey = syncKey
        self.title = title
        self.start = start
        self.end = end
        self.timeZoneIdentifier = timeZoneIdentifier
        self.location = location
        self.notes = notes
        self.updatedAt = updatedAt
        self.isRecurring = isRecurring
    }
}

public struct ExternalCalendarDraft: Sendable, Equatable {
    public var title: String
    public var start: Date
    public var end: Date
    public var timeZoneIdentifier: String
    public var calendarId: String?
    public var location: String?
    public var notes: String?
    public var syncKey: String

    public init(
        title: String,
        start: Date,
        end: Date,
        timeZoneIdentifier: String,
        calendarId: String? = nil,
        location: String? = nil,
        notes: String? = nil,
        syncKey: String
    ) {
        self.title = title
        self.start = start
        self.end = end
        self.timeZoneIdentifier = timeZoneIdentifier
        self.calendarId = calendarId
        self.location = location
        self.notes = notes
        self.syncKey = syncKey
    }
}

public struct CalendarRecoveryQuery: Sendable, Equatable {
    public var localEventId: String?
    public var providerExternalId: String?
    public var syncKey: String
    public var calendarId: String?
    public var title: String
    public var start: Date
    public var end: Date

    public init(
        localEventId: String? = nil,
        providerExternalId: String? = nil,
        syncKey: String,
        calendarId: String?,
        title: String,
        start: Date,
        end: Date
    ) {
        self.localEventId = localEventId
        self.providerExternalId = providerExternalId
        self.syncKey = syncKey
        self.calendarId = calendarId
        self.title = title
        self.start = start
        self.end = end
    }
}

public struct TimeInstanceRecord: Sendable, Equatable {
    public var id: String
    public var title: String
    public var scheduledStart: Date
    public var scheduledEnd: Date
    public var timeZoneIdentifier: String
    public var location: String?
    public var notes: String?
    public var lifecycleStatus: String
    public var syncKey: String
    public var calendarProvider: String?
    public var calendarId: String?
    public var calendarEventId: String?
    public var providerExternalId: String?
    public var calendarItemURL: String?
    public var semantics: TimeInstanceSemantics
    public var schedulingAuthority: TimeInstanceSchedulingAuthority
    public var syncState: TimeInstanceSyncState
    public var lastSyncedAt: Date?
    public var registryUpdatedAt: Date
    public var calendarUpdatedAt: Date?
    public var syncHash: String
    public var lastSyncError: String?

    public init(
        id: String = "",
        title: String,
        scheduledStart: Date,
        scheduledEnd: Date,
        timeZoneIdentifier: String,
        location: String? = nil,
        notes: String? = nil,
        lifecycleStatus: String = "Propose",
        syncKey: String,
        calendarProvider: String? = nil,
        calendarId: String? = nil,
        calendarEventId: String? = nil,
        providerExternalId: String? = nil,
        calendarItemURL: String? = nil,
        semantics: TimeInstanceSemantics,
        schedulingAuthority: TimeInstanceSchedulingAuthority,
        syncState: TimeInstanceSyncState,
        lastSyncedAt: Date? = nil,
        registryUpdatedAt: Date,
        calendarUpdatedAt: Date? = nil,
        syncHash: String = "",
        lastSyncError: String? = nil
    ) {
        self.id = id
        self.title = title
        self.scheduledStart = scheduledStart
        self.scheduledEnd = scheduledEnd
        self.timeZoneIdentifier = timeZoneIdentifier
        self.location = location
        self.notes = notes
        self.lifecycleStatus = lifecycleStatus
        self.syncKey = syncKey
        self.calendarProvider = calendarProvider
        self.calendarId = calendarId
        self.calendarEventId = calendarEventId
        self.providerExternalId = providerExternalId
        self.calendarItemURL = calendarItemURL
        self.semantics = semantics
        self.schedulingAuthority = schedulingAuthority
        self.syncState = syncState
        self.lastSyncedAt = lastSyncedAt
        self.registryUpdatedAt = registryUpdatedAt
        self.calendarUpdatedAt = calendarUpdatedAt
        self.syncHash = syncHash
        self.lastSyncError = lastSyncError
    }

    public var scheduledDurationMinutes: Double {
        scheduledEnd.timeIntervalSince(scheduledStart) / 60
    }
}

public enum RegistryLookupSource: String, Sendable, Equatable {
    case live
    case staleCache
}

public struct RegistryIdentityLookup: Sendable, Equatable {
    public var records: [TimeInstanceRecord]
    public var source: RegistryLookupSource

    public init(records: [TimeInstanceRecord], source: RegistryLookupSource) {
        self.records = records
        self.source = source
    }
}

public struct PartialRegistryCreateError: Error, LocalizedError, Sendable, Equatable {
    public var pageId: String
    public var message: String

    public init(pageId: String, message: String) {
        self.pageId = pageId
        self.message = message
    }

    public var errorDescription: String? {
        "Notion created EVENT \(pageId) but the follow-up property update failed: \(message)"
    }
}

public protocol TimeInstanceRegistryStoring: Sendable {
    func findBySyncKey(_ syncKey: String) async throws -> RegistryIdentityLookup
    func get(id: String, forceRefresh: Bool) async throws -> TimeInstanceRecord?
    func create(_ record: TimeInstanceRecord) async throws -> TimeInstanceRecord
    func save(_ record: TimeInstanceRecord) async throws -> TimeInstanceRecord
}

public protocol CalendarSyncProviding: Sendable {
    func create(_ draft: ExternalCalendarDraft) async throws -> ExternalCalendarItem
    func item(id: String) async throws -> ExternalCalendarItem?
    func recover(_ query: CalendarRecoveryQuery) async throws -> [ExternalCalendarItem]
}

public struct RegistryFirstTimeInstanceRequest: Sendable, Equatable {
    public var idempotencyKey: String
    public var title: String
    public var start: Date
    public var end: Date
    public var timeZoneIdentifier: String
    public var calendarId: String?
    public var location: String?
    public var notes: String?
    public var semantics: TimeInstanceSemantics

    public init(
        idempotencyKey: String,
        title: String,
        start: Date,
        end: Date,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        calendarId: String? = nil,
        location: String? = nil,
        notes: String? = nil,
        semantics: TimeInstanceSemantics
    ) {
        self.idempotencyKey = idempotencyKey
        self.title = title
        self.start = start
        self.end = end
        self.timeZoneIdentifier = timeZoneIdentifier
        self.calendarId = calendarId
        self.location = location
        self.notes = notes
        self.semantics = semantics
    }

    public var manifest: CalendarRegistryOperationManifest {
        CalendarRegistryOperationManifest(
            title: title,
            start: start,
            end: end,
            timeZoneIdentifier: timeZoneIdentifier,
            calendarId: calendarId,
            location: location,
            notes: notes,
            eventClass: semantics.eventClass.rawValue,
            primaryBlockId: semantics.primaryBlockId,
            blockIds: semantics.blockIds,
            projectIds: semantics.projectIds,
            contactIds: semantics.contactIds
        )
    }
}

public struct CalendarRegistrySyncReceipt: Sendable, Equatable {
    public var succeeded: Bool
    public var operationId: String
    public var idempotencyKey: String
    public var stageBefore: CalendarRegistryTransactionStage
    public var stageAfter: CalendarRegistryTransactionStage
    public var record: TimeInstanceRecord?
    public var calendarItem: ExternalCalendarItem?
    public var registryFieldsWritten: [String]
    public var calendarFieldsWritten: [String]
    public var verificationEvidence: [String]
    public var partialEffects: [String]
    public var recoveryAction: String?
    public var discrepancy: String?
}

public enum CalendarRegistrySyncError: Error, LocalizedError, Equatable {
    case invalidTimeRange
    case missingPrimaryBlock
    case missingIdempotencyKey
    case ambiguousRegistryIdentity([String])
    case ambiguousCalendarIdentity([String])
    case degradedRegistryLookup
    case recurringEventUnsupported
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidTimeRange: return "scheduled end must be after scheduled start"
        case .missingPrimaryBlock: return "Primary BLOCK is required"
        case .missingIdempotencyKey: return "a stable idempotency key is required"
        case .ambiguousRegistryIdentity(let ids): return "multiple registry EVENTS matched: \(ids.joined(separator: ", "))"
        case .ambiguousCalendarIdentity(let ids): return "multiple calendar events matched: \(ids.joined(separator: ", "))"
        case .degradedRegistryLookup: return "registry identity lookup was not live; creation refused"
        case .recurringEventUnsupported: return "recurring events are outside the registry-first v1 slice"
        case .verificationFailed(let reason): return "paired verification failed: \(reason)"
        }
    }
}

public enum CalendarRegistryRouteOwner: String, Sendable, Equatable {
    case timeKeepr = "time-keepr"
    case macKeepr = "mac-keepr"
    case notionKeepr = "notion-keepr"
}

public enum CalendarRegistryRouteIntent: Sendable, Equatable {
    case semanticScheduling
    case calendarMechanics
    case schemaChange
}

public enum CalendarRegistryRouteClassifier {
    public static func owner(for intent: CalendarRegistryRouteIntent) -> CalendarRegistryRouteOwner {
        switch intent {
        case .semanticScheduling: return .timeKeepr
        case .calendarMechanics: return .macKeepr
        case .schemaChange: return .notionKeepr
        }
    }
}

public actor CalendarRegistrySyncEngine {
    public let registry: any TimeInstanceRegistryStoring
    public let calendar: any CalendarSyncProviding
    public let transactions: any CalendarRegistryTransactionStoring
    private let operationGate: CalendarRegistryOperationGate
    private let clock: @Sendable () -> Date
    private let makeOperationId: @Sendable () -> String

    public init(
        registry: any TimeInstanceRegistryStoring,
        calendar: any CalendarSyncProviding,
        transactions: any CalendarRegistryTransactionStoring,
        operationGate: CalendarRegistryOperationGate = .shared,
        clock: @Sendable @escaping () -> Date = { Date() },
        makeOperationId: @Sendable @escaping () -> String = { UUID().uuidString.lowercased() }
    ) {
        self.registry = registry
        self.calendar = calendar
        self.transactions = transactions
        self.operationGate = operationGate
        self.clock = clock
        self.makeOperationId = makeOperationId
    }

    public func registryFirstCreate(
        _ request: RegistryFirstTimeInstanceRequest
    ) async throws -> CalendarRegistrySyncReceipt {
        try validate(request)
        await operationGate.acquire(request.idempotencyKey)
        do {
            let receipt = try await performRegistryFirstCreate(request)
            await operationGate.release(request.idempotencyKey)
            return receipt
        } catch let conflict as CalendarRegistryTransactionStoreError {
            let existing = try? await transactions.get(idempotencyKey: request.idempotencyKey)
            await operationGate.release(request.idempotencyKey)
            return CalendarRegistrySyncReceipt(
                succeeded: false,
                operationId: existing?.operationId ?? "",
                idempotencyKey: request.idempotencyKey,
                stageBefore: existing?.stage ?? .prepared,
                stageAfter: .conflict,
                record: nil,
                calendarItem: nil,
                registryFieldsWritten: [],
                calendarFieldsWritten: [],
                verificationEvidence: [],
                partialEffects: existing?.partialEffects ?? [],
                recoveryAction: "use a new idempotency key for a materially different manifest",
                discrepancy: conflict.localizedDescription
            )
        } catch {
            await operationGate.release(request.idempotencyKey)
            throw error
        }
    }

    private func performRegistryFirstCreate(
        _ request: RegistryFirstTimeInstanceRequest
    ) async throws -> CalendarRegistrySyncReceipt {
        let now = clock()
        var transaction = try await transactions.claim(
            idempotencyKey: request.idempotencyKey,
            manifestFingerprint: request.manifest.fingerprint,
            operationId: makeOperationId(),
            now: now
        )
        let stageBefore = transaction.stage
        var record: TimeInstanceRecord?
        var calendarItem: ExternalCalendarItem?
        var registryFields: [String] = []
        var calendarFields: [String] = []
        var evidence: [String] = []

        do {
            record = try await resolveOrCreateRegistry(
                request: request, transaction: &transaction, fieldsWritten: &registryFields
            )
            calendarItem = try await resolveOrCreateCalendar(
                request: request, transaction: &transaction, fieldsWritten: &calendarFields
            )

            guard var pair = record, let calendarItem else {
                throw CalendarRegistrySyncError.verificationFailed("pair resolution returned an empty surface")
            }
            apply(calendarItem, to: &pair)
            pair.syncState = .pendingCreate
            pair.lastSyncError = nil
            pair.registryUpdatedAt = clock()
            pair = try await registry.save(pair)
            record = pair
            registryFields.append(contentsOf: Self.pairingFieldNames)
            transaction.registryEventId = pair.id
            transaction.stage = .pairPersisted
            transaction.updatedAt = clock()
            transaction.partialEffects.append("pair identity persisted to Notion EVENT")
            try await transactions.save(transaction)

            let verified = try await verify(
                request: request, recordId: pair.id, calendarEventId: calendarItem.localEventId
            )
            evidence = verified.evidence
            var verifiedRecord = verified.record
            verifiedRecord.syncState = .synced
            verifiedRecord.lastSyncedAt = clock()
            verifiedRecord.registryUpdatedAt = clock()
            verifiedRecord.lastSyncError = nil
            verifiedRecord.syncHash = Self.syncFingerprint(record: verifiedRecord, item: verified.item)
            verifiedRecord = try await registry.save(verifiedRecord)

            transaction.stage = .verified
            transaction.lastVerifiedAt = clock()
            transaction.updatedAt = clock()
            transaction.lastError = nil
            try await transactions.save(transaction)

            guard let finalRecord = try await registry.get(id: verifiedRecord.id, forceRefresh: true),
                  finalRecord.syncState == .synced,
                  let finalItem = try await calendar.item(id: verified.item.localEventId)
            else {
                throw CalendarRegistrySyncError.verificationFailed("final fresh read did not confirm Synced state")
            }

            transaction.stage = .synced
            transaction.lastVerifiedAt = clock()
            transaction.updatedAt = clock()
            try await transactions.save(transaction)
            evidence.append("final fresh reads confirm one Synced EVENT and one calendar item")

            return CalendarRegistrySyncReceipt(
                succeeded: true,
                operationId: transaction.operationId,
                idempotencyKey: transaction.idempotencyKey,
                stageBefore: stageBefore,
                stageAfter: transaction.stage,
                record: finalRecord,
                calendarItem: finalItem,
                registryFieldsWritten: Array(Set(registryFields)).sorted(),
                calendarFieldsWritten: Array(Set(calendarFields)).sorted(),
                verificationEvidence: evidence,
                partialEffects: transaction.partialEffects,
                recoveryAction: nil,
                discrepancy: nil
            )
        } catch {
            if let partial = error as? PartialRegistryCreateError {
                transaction.registryEventId = partial.pageId
                transaction.partialEffects.append("Notion EVENT created: \(partial.pageId)")
            }
            transaction.stage = error is CalendarRegistryTransactionStoreError
                ? .conflict : .recoverableError
            if let syncError = error as? CalendarRegistrySyncError {
                switch syncError {
                case .ambiguousRegistryIdentity, .ambiguousCalendarIdentity:
                    transaction.stage = .conflict
                default:
                    break
                }
            }
            transaction.lastError = error.localizedDescription
            transaction.updatedAt = clock()
            try? await transactions.save(transaction)

            if var failed = record {
                failed.syncState = transaction.stage == .conflict ? .conflict : .error
                failed.lastSyncError = error.localizedDescription
                failed.registryUpdatedAt = clock()
                record = try? await registry.save(failed)
            }

            return CalendarRegistrySyncReceipt(
                succeeded: false,
                operationId: transaction.operationId,
                idempotencyKey: transaction.idempotencyKey,
                stageBefore: stageBefore,
                stageAfter: transaction.stage,
                record: record,
                calendarItem: calendarItem,
                registryFieldsWritten: Array(Set(registryFields)).sorted(),
                calendarFieldsWritten: Array(Set(calendarFields)).sorted(),
                verificationEvidence: evidence,
                partialEffects: transaction.partialEffects,
                recoveryAction: "retry with the same idempotency key; the journal will resume from \(transaction.stage.rawValue)",
                discrepancy: error.localizedDescription
            )
        }
    }

    private func resolveOrCreateRegistry(
        request: RegistryFirstTimeInstanceRequest,
        transaction: inout CalendarRegistryTransaction,
        fieldsWritten: inout [String]
    ) async throws -> TimeInstanceRecord {
        if let id = transaction.registryEventId,
           let existing = try await registry.get(id: id, forceRefresh: true) {
            return existing
        }

        let lookup = try await registry.findBySyncKey(request.idempotencyKey)
        guard lookup.source == .live else { throw CalendarRegistrySyncError.degradedRegistryLookup }
        if lookup.records.count > 1 {
            throw CalendarRegistrySyncError.ambiguousRegistryIdentity(lookup.records.map(\.id))
        }
        if let existing = lookup.records.first {
            transaction.registryEventId = existing.id
            transaction.stage = .registryCreated
            transaction.updatedAt = clock()
            transaction.partialEffects.append("reused existing Notion EVENT \(existing.id)")
            try await transactions.save(transaction)
            return existing
        }

        var created = TimeInstanceRecord(
            title: request.title,
            scheduledStart: request.start,
            scheduledEnd: request.end,
            timeZoneIdentifier: request.timeZoneIdentifier,
            location: request.location,
            notes: request.notes,
            syncKey: request.idempotencyKey,
            semantics: request.semantics,
            schedulingAuthority: .registry,
            syncState: .pendingCreate,
            registryUpdatedAt: clock()
        )
        do {
            created = try await registry.create(created)
        } catch let partial as PartialRegistryCreateError {
            transaction.registryEventId = partial.pageId
            transaction.stage = .registryCreated
            transaction.updatedAt = clock()
            transaction.partialEffects.append("Notion EVENT created before follow-up PATCH failure: \(partial.pageId)")
            try? await transactions.save(transaction)
            throw partial
        }
        transaction.registryEventId = created.id
        transaction.stage = .registryCreated
        transaction.updatedAt = clock()
        transaction.partialEffects.append("created Notion EVENT \(created.id)")
        try await transactions.save(transaction)
        fieldsWritten.append(contentsOf: Self.semanticFieldNames)
        return created
    }

    private func resolveOrCreateCalendar(
        request: RegistryFirstTimeInstanceRequest,
        transaction: inout CalendarRegistryTransaction,
        fieldsWritten: inout [String]
    ) async throws -> ExternalCalendarItem {
        let query = CalendarRecoveryQuery(
            localEventId: transaction.calendarEventId,
            providerExternalId: transaction.providerExternalId,
            syncKey: request.idempotencyKey,
            calendarId: request.calendarId,
            title: request.title,
            start: request.start,
            end: request.end
        )
        let recovered = try await calendar.recover(query)
        if recovered.count > 1 {
            throw CalendarRegistrySyncError.ambiguousCalendarIdentity(recovered.map(\.localEventId))
        }
        if let existing = recovered.first {
            guard !existing.isRecurring else { throw CalendarRegistrySyncError.recurringEventUnsupported }
            transaction.calendarEventId = existing.localEventId
            transaction.calendarId = existing.calendarId
            transaction.providerExternalId = existing.providerExternalId
            transaction.stage = .calendarCreated
            transaction.updatedAt = clock()
            transaction.partialEffects.append("recovered calendar event \(existing.localEventId)")
            try await transactions.save(transaction)
            return existing
        }

        let created = try await calendar.create(ExternalCalendarDraft(
            title: request.title,
            start: request.start,
            end: request.end,
            timeZoneIdentifier: request.timeZoneIdentifier,
            calendarId: request.calendarId,
            location: request.location,
            notes: request.notes,
            syncKey: request.idempotencyKey
        ))
        guard !created.isRecurring else { throw CalendarRegistrySyncError.recurringEventUnsupported }
        transaction.calendarEventId = created.localEventId
        transaction.calendarId = created.calendarId
        transaction.providerExternalId = created.providerExternalId
        transaction.stage = .calendarCreated
        transaction.updatedAt = clock()
        transaction.partialEffects.append("created calendar event \(created.localEventId)")
        try await transactions.save(transaction)
        fieldsWritten.append(contentsOf: ["title", "start", "end", "timeZone", "calendarId", "location", "notes", "syncKey"])
        return created
    }

    private func verify(
        request: RegistryFirstTimeInstanceRequest,
        recordId: String,
        calendarEventId: String
    ) async throws -> (record: TimeInstanceRecord, item: ExternalCalendarItem, evidence: [String]) {
        guard let record = try await registry.get(id: recordId, forceRefresh: true) else {
            throw CalendarRegistrySyncError.verificationFailed("Notion EVENT missing after write")
        }
        guard let item = try await calendar.item(id: calendarEventId) else {
            throw CalendarRegistrySyncError.verificationFailed("calendar item missing after write")
        }
        guard !item.isRecurring else { throw CalendarRegistrySyncError.recurringEventUnsupported }
        guard record.syncKey == request.idempotencyKey, item.syncKey == request.idempotencyKey else {
            throw CalendarRegistrySyncError.verificationFailed("idempotency identity differs between surfaces")
        }
        guard record.title == item.title,
              abs(record.scheduledStart.timeIntervalSince(item.start)) < 1,
              abs(record.scheduledEnd.timeIntervalSince(item.end)) < 1
        else {
            throw CalendarRegistrySyncError.verificationFailed("title or scheduled range differs")
        }
        guard record.calendarEventId == item.localEventId,
              record.calendarId == item.calendarId
        else {
            throw CalendarRegistrySyncError.verificationFailed("pair identity is not persisted in Notion")
        }
        return (
            record,
            item,
            [
                "fresh Notion read confirmed EVENT \(record.id)",
                "provider read confirmed calendar event \(item.localEventId)",
                "Sync Key, title, start, end, calendar ID, and event ID match"
            ]
        )
    }

    private func validate(_ request: RegistryFirstTimeInstanceRequest) throws {
        guard !request.idempotencyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CalendarRegistrySyncError.missingIdempotencyKey
        }
        guard request.end > request.start else { throw CalendarRegistrySyncError.invalidTimeRange }
        guard !request.semantics.primaryBlockId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CalendarRegistrySyncError.missingPrimaryBlock
        }
    }

    private func apply(_ item: ExternalCalendarItem, to record: inout TimeInstanceRecord) {
        record.calendarProvider = item.provider
        record.calendarId = item.calendarId
        record.calendarEventId = item.localEventId
        record.providerExternalId = item.providerExternalId
        record.calendarItemURL = item.itemURL
        record.scheduledStart = item.start
        record.scheduledEnd = item.end
        record.timeZoneIdentifier = item.timeZoneIdentifier
        record.calendarUpdatedAt = item.updatedAt
    }

    private static func syncFingerprint(record: TimeInstanceRecord, item: ExternalCalendarItem) -> String {
        let canonical = [
            record.syncKey, item.calendarId, item.localEventId,
            item.providerExternalId ?? "", item.title,
            CalendarRegistryISO.string(item.start), CalendarRegistryISO.string(item.end),
            item.timeZoneIdentifier, record.semantics.primaryBlockId,
            record.semantics.eventClass.rawValue
        ].joined(separator: "\u{1F}")
        return CalendarRegistryDigest.sha256(canonical)
    }

    private static let semanticFieldNames = [
        "title", "date", "status", "syncKey", "eventClass", "meetingType",
        "primaryBlock", "blocks", "projects", "contacts", "schedulingAuthority",
        "syncState", "registryUpdatedAt", "scheduledDuration", "calendarLocation", "description"
    ]

    private static let pairingFieldNames = [
        "calendarProvider", "calendarId", "calendarEventId", "providerExternalId",
        "calendarUrl", "calendarUpdatedAt", "syncState", "lastSyncError"
    ]
}

// MARK: - EventKit adapter

public actor CalendarStoringSyncProvider: CalendarSyncProviding {
    private let store: any CalendarStoring
    private let providerName: String
    private let clock: @Sendable () -> Date
    private var cache: [String: ExternalCalendarItem] = [:]

    public init(
        store: any CalendarStoring,
        providerName: String = "Apple Calendar",
        clock: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.providerName = providerName
        self.clock = clock
    }

    public func create(_ draft: ExternalCalendarDraft) async throws -> ExternalCalendarItem {
        let event = try await store.create(CalendarEventDraft(
            title: draft.title,
            start: Self.iso(draft.start),
            end: Self.iso(draft.end),
            calendarId: draft.calendarId,
            location: draft.location,
            notes: Self.notes(draft.notes, syncKey: draft.syncKey),
            timeZoneIdentifier: draft.timeZoneIdentifier
        ))
        let item = try map(event)
        cache[item.localEventId] = item
        return item
    }

    public func item(id: String) async throws -> ExternalCalendarItem? {
        guard let event = try await store.event(id: id) else {
            cache[id] = nil
            return nil
        }
        let item = try map(event)
        cache[id] = item
        return item
    }

    public func recover(_ query: CalendarRecoveryQuery) async throws -> [ExternalCalendarItem] {
        if let id = query.localEventId, let direct = try await item(id: id) {
            return [direct]
        }
        let lower = query.start.addingTimeInterval(-86_400)
        let upper = query.end.addingTimeInterval(86_400)
        let events = try await store.events(CalendarEventQuery(
            start: Self.iso(lower), end: Self.iso(upper), calendarId: query.calendarId
        ))
        let mapped = try events.map(map)
        let nonRecurring = mapped.filter { !$0.isRecurring }

        let bySyncKey = nonRecurring.filter { $0.syncKey == query.syncKey }
        if !bySyncKey.isEmpty { return bySyncKey }

        if let external = query.providerExternalId {
            let byExternal = nonRecurring.filter { $0.providerExternalId == external }
            if !byExternal.isEmpty { return byExternal }
        }

        return nonRecurring.filter {
            $0.title.caseInsensitiveCompare(query.title) == .orderedSame
                && abs($0.start.timeIntervalSince(query.start)) < 1
                && abs($0.end.timeIntervalSince(query.end)) < 1
        }
    }

    private func map(_ event: CalendarEvent) throws -> ExternalCalendarItem {
        guard let start = try? CalendarISOParsing.parse(event.start),
              let end = try? CalendarISOParsing.parse(event.end)
        else { throw CalendarModuleError.invalidDate("\(event.start) – \(event.end)") }
        return ExternalCalendarItem(
            provider: providerName,
            calendarId: event.calendarId,
            localEventId: event.id,
            providerExternalId: event.externalId,
            itemURL: event.conferenceURL,
            syncKey: Self.syncKey(from: event.notes),
            title: event.title,
            start: start,
            end: end,
            timeZoneIdentifier: TimeZone.current.identifier,
            location: event.location,
            notes: event.notes,
            updatedAt: event.lastModified.flatMap { try? CalendarISOParsing.parse($0) } ?? clock(),
            isRecurring: event.isRecurring
        )
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func notes(_ notes: String?, syncKey: String) -> String {
        let marker = "Bridge Sync Key: \(syncKey)"
        guard let notes, !notes.isEmpty else { return marker }
        if notes.contains(marker) { return notes }
        return notes + "\n\n" + marker
    }

    private static func syncKey(from notes: String?) -> String? {
        guard let notes else { return nil }
        let prefix = "Bridge Sync Key:"
        guard let line = notes.split(whereSeparator: \.isNewline)
            .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(prefix) })
        else { return nil }
        return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Notion registry adapter

public struct NotionTimeInstanceRegistryStore: TimeInstanceRegistryStoring {
    public let entity: RegistryEntity
    public let gateway: any RegistryNotionGateway
    public let reader: RegistryReader
    public let writer: RegistryWriter

    public init(entity: RegistryEntity, gateway: any RegistryNotionGateway) {
        self.entity = entity
        self.gateway = gateway
        self.reader = RegistryReader(gateway: gateway)
        self.writer = RegistryWriter(gateway: gateway)
    }

    public func findBySyncKey(_ syncKey: String) async throws -> RegistryIdentityLookup {
        guard gateway.supportsAuthoritativeFiltering else {
            throw CalendarRegistrySyncError.degradedRegistryLookup
        }
        guard let property = entity.property("syncKey") else {
            throw RegistryWriter.RegistryWriteError.unknownFields(entity: entity.key, keys: ["syncKey"])
        }
        let filterObject: [String: Any] = [
            "property": property.notionPropertyId ?? property.notionName,
            "rich_text": ["equals": syncKey]
        ]
        let filter = try JSONSerialization.data(withJSONObject: filterObject)
        var cursor: String? = nil
        var records: [TimeInstanceRecord] = []
        repeat {
            let result = try await gateway.query(
                dataSourceId: entity.dataSourceId,
                workspace: entity.workspace,
                filter: filter,
                pageSize: 100,
                startCursor: cursor
            )
            records.append(contentsOf: result.rows.compactMap { row in
                let cached = CachedRow(
                    entity: entity.key,
                    pageId: row.id,
                    title: RegistryReader.project(row, entity: entity).title,
                    url: row.url,
                    properties: RegistryReader.project(row, entity: entity).properties,
                    lastEditedTime: row.lastEditedTime,
                    writtenAt: Date(),
                    ttlSeconds: entity.cacheTTLSeconds,
                    callCount: 1
                )
                return Self.decode(cached)
            })
            cursor = result.nextCursor
        } while cursor != nil
        return RegistryIdentityLookup(records: records, source: .live)
    }

    public func get(id: String, forceRefresh: Bool) async throws -> TimeInstanceRecord? {
        let row = try await reader.get(entity: entity, pageId: id, forceRefresh: forceRefresh)
        return Self.decode(row)
    }

    public func create(_ record: TimeInstanceRecord) async throws -> TimeInstanceRecord {
        let resolved = RegistryWriter.resolve(fields(record), entity: entity)
        if !resolved.unknown.isEmpty {
            throw RegistryWriter.RegistryWriteError.unknownFields(entity: entity.key, keys: resolved.unknown)
        }
        if !resolved.unbound.isEmpty {
            throw RegistryWriter.RegistryWriteError.notFullyBound(entity: entity.key, unbound: resolved.unbound)
        }
        let titleFields = resolved.fields.filter(\.isTitle)
        let rest = resolved.fields.filter { !$0.isTitle }
        let created = try await gateway.create(
            dataSourceId: entity.dataSourceId,
            workspace: entity.workspace,
            fields: titleFields.isEmpty ? resolved.fields : titleFields
        )
        _ = await RegistryReader.store(created, entity: entity, into: reader.cache)
        if !titleFields.isEmpty, !rest.isEmpty {
            do {
                _ = try await gateway.update(pageId: created.id, workspace: entity.workspace, fields: rest)
            } catch {
                throw PartialRegistryCreateError(pageId: created.id, message: error.localizedDescription)
            }
        }
        guard let fresh = try await get(id: created.id, forceRefresh: true) else {
            throw CalendarRegistrySyncError.verificationFailed("created Notion EVENT could not be read back")
        }
        return fresh
    }

    public func save(_ record: TimeInstanceRecord) async throws -> TimeInstanceRecord {
        _ = try await writer.update(entity: entity, pageId: record.id, fields: fields(record))
        return record
    }

    private func fields(_ record: TimeInstanceRecord) -> [String: Value] {
        var out: [String: Value] = [
            "title": .string(record.title),
            "date": .object([
                "start": .string(CalendarRegistryISO.string(record.scheduledStart)),
                "end": .string(CalendarRegistryISO.string(record.scheduledEnd)),
                "timeZone": .string(record.timeZoneIdentifier)
            ]),
            "status": .string(record.lifecycleStatus),
            "syncKey": .string(record.syncKey),
            "eventClass": .string(record.semantics.eventClass.rawValue),
            "primaryBlock": .array([.string(record.semantics.primaryBlockId)]),
            "blocks": .array(record.semantics.blockIds.map(Value.string)),
            "projects": .array(record.semantics.projectIds.map(Value.string)),
            "contacts": .array(record.semantics.contactIds.map(Value.string)),
            "schedulingAuthority": .string(record.schedulingAuthority.rawValue),
            "syncState": .string(record.syncState.rawValue),
            "registryUpdatedAt": .string(CalendarRegistryISO.string(record.registryUpdatedAt)),
            "syncHash": .string(record.syncHash),
            "scheduledDuration": .double(record.scheduledDurationMinutes),
            "description": Self.nullable(record.notes),
            "calendarLocation": Self.nullable(record.location),
            "calendarProvider": Self.nullable(record.calendarProvider),
            "calendarId": Self.nullable(record.calendarId),
            "calendarEventId": Self.nullable(record.calendarEventId),
            "calendarUrl": Self.nullable(record.calendarItemURL),
            "meetingType": Self.nullable(record.semantics.meetingType),
            "lastSyncError": Self.nullable(record.lastSyncError),
            "lastSyncedAt": Self.nullableDate(record.lastSyncedAt),
            "calendarUpdatedAt": Self.nullableDate(record.calendarUpdatedAt)
        ]
        if entity.property("providerExternalId") != nil {
            out["providerExternalId"] = Self.nullable(record.providerExternalId)
        }
        return out
    }

    private static func decode(_ row: CachedRow) -> TimeInstanceRecord? {
        guard case .object(let properties) = row.properties,
              let range = dateRange(properties["date"]),
              let syncKey = string(properties["syncKey"]),
              let primaryBlock = strings(properties["primaryBlock"]).first,
              let eventClassRaw = string(properties["eventClass"]),
              let eventClass = TimeInstanceEventClass(rawValue: eventClassRaw)
        else { return nil }
        let authority = TimeInstanceSchedulingAuthority(
            rawValue: string(properties["schedulingAuthority"]) ?? ""
        ) ?? .registry
        let state = TimeInstanceSyncState(
            rawValue: string(properties["syncState"]) ?? ""
        ) ?? .error
        return TimeInstanceRecord(
            id: row.pageId,
            title: row.title,
            scheduledStart: range.start,
            scheduledEnd: range.end,
            timeZoneIdentifier: range.timeZone,
            location: string(properties["calendarLocation"]),
            notes: string(properties["description"]),
            lifecycleStatus: string(properties["status"]) ?? "Propose",
            syncKey: syncKey,
            calendarProvider: string(properties["calendarProvider"]),
            calendarId: string(properties["calendarId"]),
            calendarEventId: string(properties["calendarEventId"]),
            providerExternalId: string(properties["providerExternalId"]),
            calendarItemURL: string(properties["calendarUrl"]),
            semantics: TimeInstanceSemantics(
                eventClass: eventClass,
                meetingType: string(properties["meetingType"]),
                primaryBlockId: primaryBlock,
                blockIds: strings(properties["blocks"]),
                projectIds: strings(properties["projects"]),
                contactIds: strings(properties["contacts"])
            ),
            schedulingAuthority: authority,
            syncState: state,
            lastSyncedAt: date(properties["lastSyncedAt"]),
            registryUpdatedAt: date(properties["registryUpdatedAt"])
                ?? CalendarRegistryISO.date(row.lastEditedTime) ?? .distantPast,
            calendarUpdatedAt: date(properties["calendarUpdatedAt"]),
            syncHash: string(properties["syncHash"]) ?? "",
            lastSyncError: string(properties["lastSyncError"])
        )
    }

    private static func nullable(_ value: String?) -> Value {
        guard let value, !value.isEmpty else { return .null }
        return .string(value)
    }

    private static func nullableDate(_ value: Date?) -> Value {
        guard let value else { return .null }
        return .string(CalendarRegistryISO.string(value))
    }

    private static func string(_ value: Value?) -> String? {
        if case .string(let string)? = value, !string.isEmpty { return string }
        return nil
    }

    private static func strings(_ value: Value?) -> [String] {
        guard case .array(let values)? = value else { return [] }
        return values.compactMap(string)
    }

    private static func date(_ value: Value?) -> Date? {
        string(value).flatMap(CalendarRegistryISO.date)
    }

    private static func dateRange(_ value: Value?) -> (start: Date, end: Date, timeZone: String)? {
        if case .object(let object)? = value,
           case .string(let startString)? = object["start"],
           case .string(let endString)? = object["end"],
           let start = CalendarRegistryISO.date(startString),
           let end = CalendarRegistryISO.date(endString) {
            let timeZone: String
            if case .string(let identifier)? = object["timeZone"] { timeZone = identifier }
            else { timeZone = TimeZone.current.identifier }
            return (start, end, timeZone)
        }
        if let startString = string(value), let start = CalendarRegistryISO.date(startString) {
            return (start, start, TimeZone.current.identifier)
        }
        return nil
    }
}

public extension CalendarRegistrySyncEngine {
    static let requiredScheduleCanonicalFields: Set<String> = [
        "syncKey", "calendarProvider", "calendarId", "calendarEventId",
        "providerExternalId", "calendarUrl", "eventClass", "meetingType",
        "primaryBlock", "schedulingAuthority", "syncState", "lastSyncedAt",
        "registryUpdatedAt", "calendarUpdatedAt", "syncHash", "lastSyncError",
        "scheduledDuration", "calendarLocation"
    ]
}
