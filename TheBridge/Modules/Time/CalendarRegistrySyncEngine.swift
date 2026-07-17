// CalendarRegistrySyncEngine.swift — disabled registry-first recovery core
//
// Scope: one caller-classified, private, non-recurring, timed EventKit item
// paired with one Notion EVENT. No public tool registration or activation.

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
    public var operationFingerprint: String?
    public var title: String
    public var start: Date
    public var end: Date
    public var timeZoneIdentifier: String
    public var location: String?
    public var notes: String?
    public var organizer: String?
    public var attendees: [String]
    public var updatedAt: Date
    public var isRecurring: Bool
    public var isAllDay: Bool
    public var isDetached: Bool

    public init(
        provider: String,
        calendarId: String,
        localEventId: String,
        providerExternalId: String? = nil,
        itemURL: String? = nil,
        syncKey: String? = nil,
        operationFingerprint: String? = nil,
        title: String,
        start: Date,
        end: Date,
        timeZoneIdentifier: String,
        location: String? = nil,
        notes: String? = nil,
        organizer: String? = nil,
        attendees: [String] = [],
        updatedAt: Date,
        isRecurring: Bool = false,
        isAllDay: Bool = false,
        isDetached: Bool = false
    ) {
        self.provider = provider
        self.calendarId = calendarId
        self.localEventId = localEventId
        self.providerExternalId = providerExternalId
        self.itemURL = itemURL
        self.syncKey = syncKey
        self.operationFingerprint = operationFingerprint
        self.title = title
        self.start = start
        self.end = end
        self.timeZoneIdentifier = timeZoneIdentifier
        self.location = location
        self.notes = notes
        self.organizer = organizer
        self.attendees = attendees
        self.updatedAt = updatedAt
        self.isRecurring = isRecurring
        self.isAllDay = isAllDay
        self.isDetached = isDetached
    }
}

public struct ExternalCalendarDraft: Sendable, Equatable {
    public var title: String
    public var start: Date
    public var end: Date
    public var timeZoneIdentifier: String
    public var calendarId: String
    public var location: String?
    public var notes: String?
    public var syncKey: String
    public var operationFingerprint: String

    public init(
        title: String,
        start: Date,
        end: Date,
        timeZoneIdentifier: String,
        calendarId: String,
        location: String? = nil,
        notes: String? = nil,
        syncKey: String,
        operationFingerprint: String
    ) {
        self.title = title
        self.start = start
        self.end = end
        self.timeZoneIdentifier = timeZoneIdentifier
        self.calendarId = calendarId
        self.location = location
        self.notes = notes
        self.syncKey = syncKey
        self.operationFingerprint = operationFingerprint
    }
}

public struct CalendarRecoveryQuery: Sendable, Equatable {
    public var localEventId: String?
    public var providerExternalId: String?
    public var syncKey: String
    public var operationFingerprint: String
    public var calendarId: String
    public var title: String
    public var start: Date
    public var end: Date

    public init(
        localEventId: String? = nil,
        providerExternalId: String? = nil,
        syncKey: String,
        operationFingerprint: String,
        calendarId: String,
        title: String,
        start: Date,
        end: Date
    ) {
        self.localEventId = localEventId
        self.providerExternalId = providerExternalId
        self.syncKey = syncKey
        self.operationFingerprint = operationFingerprint
        self.calendarId = calendarId
        self.title = title
        self.start = start
        self.end = end
    }
}

public struct CalendarQualification: Sendable, Equatable {
    public var calendarId: String
    public var title: String
    public var allowsModify: Bool
    public var explicitlyAllowlisted: Bool
    public var calendarType: String
    public var sourceType: String?
    public var qualifiedForPrivateSmoke: Bool

    public init(
        calendarId: String,
        title: String,
        allowsModify: Bool,
        explicitlyAllowlisted: Bool,
        calendarType: String,
        sourceType: String?,
        qualifiedForPrivateSmoke: Bool
    ) {
        self.calendarId = calendarId
        self.title = title
        self.allowsModify = allowsModify
        self.explicitlyAllowlisted = explicitlyAllowlisted
        self.calendarType = calendarType
        self.sourceType = sourceType
        self.qualifiedForPrivateSmoke = qualifiedForPrivateSmoke
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
    public var operationFingerprint: String
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
        operationFingerprint: String,
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
        self.operationFingerprint = operationFingerprint
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

public struct RegistryUnresolvedIdentity: Sendable, Equatable {
    public var pageId: String
    public var operationFingerprint: String?

    public init(pageId: String, operationFingerprint: String?) {
        self.pageId = pageId
        self.operationFingerprint = operationFingerprint
    }
}

public struct RegistryIdentityLookup: Sendable, Equatable {
    public var records: [TimeInstanceRecord]
    public var unresolvedIdentities: [RegistryUnresolvedIdentity]
    public var source: RegistryLookupSource

    public init(
        records: [TimeInstanceRecord],
        unresolvedIdentities: [RegistryUnresolvedIdentity] = [],
        source: RegistryLookupSource
    ) {
        self.records = records
        self.unresolvedIdentities = unresolvedIdentities
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
        "Notion created identity envelope \(pageId) but the semantic PATCH failed: \(message)"
    }
}

public protocol TimeInstanceRegistryStoring: Sendable {
    func findBySyncKey(_ syncKey: String) async throws -> RegistryIdentityLookup
    func get(id: String, forceRefresh: Bool) async throws -> TimeInstanceRecord?
    func create(_ record: TimeInstanceRecord) async throws -> TimeInstanceRecord
    func repair(id: String, from record: TimeInstanceRecord) async throws -> TimeInstanceRecord
    func save(_ record: TimeInstanceRecord) async throws -> TimeInstanceRecord
}

public protocol CalendarSyncProviding: Sendable {
    func qualify(calendarId: String) async throws -> CalendarQualification
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
    public var calendarId: String
    public var location: String?
    public var notes: String?
    public var semantics: TimeInstanceSemantics

    public init(
        idempotencyKey: String,
        title: String,
        start: Date,
        end: Date,
        timeZoneIdentifier: String,
        calendarId: String,
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
            meetingType: semantics.meetingType,
            primaryBlockId: semantics.primaryBlockId,
            blockIds: semantics.blockIds,
            projectIds: semantics.projectIds,
            contactIds: semantics.contactIds
        ).canonicalized
    }
}

public struct CalendarRegistrySyncReceipt: Sendable, Equatable {
    public var succeeded: Bool
    public var infrastructureFault: Bool
    public var recoveryStatePersisted: Bool
    public var registryFailureStatePersisted: Bool
    public var operationId: String
    public var idempotencyKey: String
    public var operationFingerprint: String
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
    case invalidTimeZone(String)
    case missingPrimaryBlock
    case invalidIdempotencyKey
    case missingCalendarId
    case calendarNotQualified(String)
    case ambiguousRegistryIdentity([String])
    case undecodableRegistryIdentity([String])
    case ambiguousCalendarIdentity([String])
    case degradedRegistryLookup
    case recurringEventUnsupported
    case allDayEventUnsupported
    case detachedEventUnsupported
    case participantConsequencesUnsupported
    case identityConflict(String)
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidTimeRange: return "scheduled end must be after scheduled start"
        case .invalidTimeZone(let value): return "invalid timezone identifier: \(value)"
        case .missingPrimaryBlock: return "Primary BLOCK is required"
        case .invalidIdempotencyKey: return "idempotency key must be 1–128 characters using letters, digits, period, underscore, colon, or hyphen"
        case .missingCalendarId: return "an explicit allowlisted calendar ID is required"
        case .calendarNotQualified(let reason): return "calendar is not qualified for a private smoke: \(reason)"
        case .ambiguousRegistryIdentity(let ids): return "multiple registry EVENTS matched: \(ids.joined(separator: ", "))"
        case .undecodableRegistryIdentity(let ids): return "matching registry EVENTS could not be decoded safely: \(ids.joined(separator: ", "))"
        case .ambiguousCalendarIdentity(let ids): return "multiple calendar events matched: \(ids.joined(separator: ", "))"
        case .degradedRegistryLookup: return "registry identity lookup was not live; creation refused"
        case .recurringEventUnsupported: return "recurring events are outside the registry-first v1 slice"
        case .allDayEventUnsupported: return "all-day events are outside the registry-first v1 slice"
        case .detachedEventUnsupported: return "detached recurring occurrences are outside the registry-first v1 slice"
        case .participantConsequencesUnsupported: return "attendee or organizer consequences are outside the registry-first v1 slice"
        case .identityConflict(let reason): return "calendar-registry identity conflict: \(reason)"
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
            let isConflict: Bool
            if case .idempotencyConflict = conflict { isConflict = true } else { isConflict = false }
            await operationGate.release(request.idempotencyKey)
            return CalendarRegistrySyncReceipt(
                succeeded: false,
                infrastructureFault: !isConflict,
                recoveryStatePersisted: existing != nil,
                registryFailureStatePersisted: false,
                operationId: existing?.operationId ?? "",
                idempotencyKey: request.idempotencyKey,
                operationFingerprint: request.manifest.fingerprint,
                stageBefore: existing?.stage ?? .prepared,
                stageAfter: isConflict ? .conflict : .recoverableError,
                record: nil,
                calendarItem: nil,
                registryFieldsWritten: [],
                calendarFieldsWritten: [],
                verificationEvidence: [],
                partialEffects: existing?.partialEffects ?? [],
                recoveryAction: isConflict
                    ? "use a new idempotency key for a materially different manifest"
                    : "inspect the SQLite recovery ledger before retrying",
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
        let fingerprint = request.manifest.fingerprint
        var transaction = try await transactions.claim(
            idempotencyKey: request.idempotencyKey,
            manifestFingerprint: fingerprint,
            operationId: makeOperationId(),
            now: clock()
        )
        let stageBefore = transaction.stage
        var record: TimeInstanceRecord?
        var calendarItem: ExternalCalendarItem?
        var registryFields: [String] = []
        var calendarFields: [String] = []
        var evidence: [String] = []

        do {
            let qualification = try await calendar.qualify(calendarId: request.calendarId)
            guard qualification.qualifiedForPrivateSmoke else {
                throw CalendarRegistrySyncError.calendarNotQualified(
                    "calendar must be explicitly allowlisted, writable, local, and non-subscribed"
                )
            }
            evidence.append("qualified explicit private-smoke calendar \(qualification.calendarId)")

            record = try await resolveOrCreateRegistry(
                request: request, transaction: &transaction, fieldsWritten: &registryFields
            )
            calendarItem = try await resolveOrCreateCalendar(
                request: request,
                record: record!,
                transaction: &transaction,
                fieldsWritten: &calendarFields
            )

            guard var pair = record, let calendarItem else {
                throw CalendarRegistrySyncError.verificationFailed("pair resolution returned an empty surface")
            }
            try assertCalendarMatchesManifest(calendarItem, request: request)
            applyIdentity(calendarItem, to: &pair)
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
            evidence.append(contentsOf: verified.evidence)
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

            let final = try await verify(
                request: request,
                recordId: verifiedRecord.id,
                calendarEventId: verified.item.localEventId
            )
            guard final.record.syncState == .synced else {
                throw CalendarRegistrySyncError.verificationFailed("final Notion read did not retain Synced state")
            }

            transaction.stage = .synced
            transaction.lastVerifiedAt = clock()
            transaction.updatedAt = clock()
            try await transactions.save(transaction)
            evidence.append("final fresh reads repeated the complete manifest and pair comparison")

            return CalendarRegistrySyncReceipt(
                succeeded: true,
                infrastructureFault: false,
                recoveryStatePersisted: true,
                registryFailureStatePersisted: true,
                operationId: transaction.operationId,
                idempotencyKey: transaction.idempotencyKey,
                operationFingerprint: fingerprint,
                stageBefore: stageBefore,
                stageAfter: transaction.stage,
                record: final.record,
                calendarItem: final.item,
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
                transaction.partialEffects.append("Notion identity envelope exists: \(partial.pageId)")
            }
            transaction.stage = Self.isConflict(error) ? .conflict : .recoverableError
            transaction.lastError = error.localizedDescription
            transaction.updatedAt = clock()

            var ledgerError: Error?
            do { try await transactions.save(transaction) }
            catch { ledgerError = error }

            var registryError: Error?
            if var failed = record {
                failed.syncState = transaction.stage == .conflict ? .conflict : .error
                failed.lastSyncError = error.localizedDescription
                failed.registryUpdatedAt = clock()
                do { record = try await registry.save(failed) }
                catch { registryError = error }
            }

            let persisted = ledgerError == nil
            let registryPersisted = record == nil ? false : registryError == nil
            let combined = [
                error.localizedDescription,
                ledgerError.map { "recovery ledger write failed: \($0.localizedDescription)" },
                registryError.map { "registry failure-state write failed: \($0.localizedDescription)" }
            ].compactMap { $0 }.joined(separator: " | ")

            return CalendarRegistrySyncReceipt(
                succeeded: false,
                infrastructureFault: !persisted,
                recoveryStatePersisted: persisted,
                registryFailureStatePersisted: registryPersisted,
                operationId: transaction.operationId,
                idempotencyKey: transaction.idempotencyKey,
                operationFingerprint: fingerprint,
                stageBefore: stageBefore,
                stageAfter: transaction.stage,
                record: record,
                calendarItem: calendarItem,
                registryFieldsWritten: Array(Set(registryFields)).sorted(),
                calendarFieldsWritten: Array(Set(calendarFields)).sorted(),
                verificationEvidence: evidence,
                partialEffects: transaction.partialEffects,
                recoveryAction: persisted
                    ? "retry with the same idempotency key; resume from \(transaction.stage.rawValue)"
                    : "do not retry automatically; inspect Notion by Sync Key and Calendar by Bridge metadata before reconstructing the ledger",
                discrepancy: combined
            )
        }
    }

    private func desiredRecord(_ request: RegistryFirstTimeInstanceRequest) -> TimeInstanceRecord {
        TimeInstanceRecord(
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
            registryUpdatedAt: clock()
        )
    }

    private func resolveOrCreateRegistry(
        request: RegistryFirstTimeInstanceRequest,
        transaction: inout CalendarRegistryTransaction,
        fieldsWritten: inout [String]
    ) async throws -> TimeInstanceRecord {
        let desired = desiredRecord(request)
        if let id = transaction.registryEventId {
            if let existing = try await registry.get(id: id, forceRefresh: true) {
                try assertRegistryMatchesManifest(existing, request: request)
                return existing
            }
            let repaired = try await registry.repair(id: id, from: desired)
            try assertRegistryMatchesManifest(repaired, request: request)
            fieldsWritten.append(contentsOf: Self.semanticFieldNames)
            return repaired
        }

        let lookup = try await registry.findBySyncKey(request.idempotencyKey)
        guard lookup.source == .live else { throw CalendarRegistrySyncError.degradedRegistryLookup }
        let totalMatches = lookup.records.count + lookup.unresolvedIdentities.count
        if totalMatches > 1 {
            throw CalendarRegistrySyncError.ambiguousRegistryIdentity(
                lookup.records.map(\.id) + lookup.unresolvedIdentities.map(\.pageId)
            )
        }
        if let unresolved = lookup.unresolvedIdentities.first {
            guard unresolved.operationFingerprint == request.manifest.fingerprint else {
                throw CalendarRegistrySyncError.identityConflict(
                    "partial Notion EVENT fingerprint differs or is missing"
                )
            }
            let repaired = try await registry.repair(id: unresolved.pageId, from: desired)
            transaction.registryEventId = repaired.id
            transaction.stage = .registryCreated
            transaction.updatedAt = clock()
            transaction.partialEffects.append("repaired partial Notion EVENT \(repaired.id)")
            try await transactions.save(transaction)
            fieldsWritten.append(contentsOf: Self.semanticFieldNames)
            return repaired
        }
        if let existing = lookup.records.first {
            try assertRegistryMatchesManifest(existing, request: request)
            transaction.registryEventId = existing.id
            transaction.calendarEventId = existing.calendarEventId
            transaction.calendarId = existing.calendarId
            transaction.providerExternalId = existing.providerExternalId
            transaction.stage = .registryCreated
            transaction.updatedAt = clock()
            transaction.partialEffects.append("reused existing Notion EVENT \(existing.id)")
            try await transactions.save(transaction)
            return existing
        }

        do {
            let created = try await registry.create(desired)
            transaction.registryEventId = created.id
            transaction.stage = .registryCreated
            transaction.updatedAt = clock()
            transaction.partialEffects.append("created Notion EVENT \(created.id)")
            try await transactions.save(transaction)
            fieldsWritten.append(contentsOf: Self.semanticFieldNames)
            return created
        } catch let partial as PartialRegistryCreateError {
            transaction.registryEventId = partial.pageId
            transaction.stage = .registryCreated
            transaction.updatedAt = clock()
            transaction.partialEffects.append("Notion identity envelope created before semantic PATCH failure: \(partial.pageId)")
            try await transactions.save(transaction)
            throw partial
        }
    }

    private func resolveOrCreateCalendar(
        request: RegistryFirstTimeInstanceRequest,
        record: TimeInstanceRecord,
        transaction: inout CalendarRegistryTransaction,
        fieldsWritten: inout [String]
    ) async throws -> ExternalCalendarItem {
        let priorEvidence = [
            transaction.calendarEventId, transaction.providerExternalId,
            record.calendarEventId, record.providerExternalId
        ].contains { $0?.isEmpty == false }
        let query = CalendarRecoveryQuery(
            localEventId: transaction.calendarEventId ?? record.calendarEventId,
            providerExternalId: transaction.providerExternalId ?? record.providerExternalId,
            syncKey: request.idempotencyKey,
            operationFingerprint: request.manifest.fingerprint,
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
            try assertCalendarMatchesManifest(existing, request: request)
            transaction.calendarEventId = existing.localEventId
            transaction.calendarId = existing.calendarId
            transaction.providerExternalId = existing.providerExternalId
            transaction.stage = .calendarCreated
            transaction.updatedAt = clock()
            transaction.partialEffects.append("recovered calendar event \(existing.localEventId)")
            try await transactions.save(transaction)
            return existing
        }
        if priorEvidence {
            throw CalendarRegistrySyncError.identityConflict(
                "prior calendar identity exists but no unique provider item could be recovered"
            )
        }

        let created = try await calendar.create(ExternalCalendarDraft(
            title: request.title,
            start: request.start,
            end: request.end,
            timeZoneIdentifier: request.timeZoneIdentifier,
            calendarId: request.calendarId,
            location: request.location,
            notes: request.notes,
            syncKey: request.idempotencyKey,
            operationFingerprint: request.manifest.fingerprint
        ))
        try assertCalendarMatchesManifest(created, request: request)
        transaction.calendarEventId = created.localEventId
        transaction.calendarId = created.calendarId
        transaction.providerExternalId = created.providerExternalId
        transaction.stage = .calendarCreated
        transaction.updatedAt = clock()
        transaction.partialEffects.append("created calendar event \(created.localEventId)")
        try await transactions.save(transaction)
        fieldsWritten.append(contentsOf: [
            "title", "start", "end", "timeZone", "calendarId", "location", "notes",
            "syncKey", "operationFingerprint"
        ])
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
        try assertRegistryMatchesManifest(record, request: request)
        try assertCalendarMatchesManifest(item, request: request)
        guard record.calendarEventId == item.localEventId,
              record.calendarId == item.calendarId,
              record.providerExternalId == item.providerExternalId else {
            throw CalendarRegistrySyncError.verificationFailed("pair identity is not persisted consistently")
        }
        return (
            record,
            item,
            [
                "fresh Notion read confirmed EVENT \(record.id)",
                "provider read confirmed calendar event \(item.localEventId)",
                "Sync Key, operation fingerprint, title, start, end, timezone, calendar ID, event ID, and event shape match the immutable manifest"
            ]
        )
    }

    private func validate(_ request: RegistryFirstTimeInstanceRequest) throws {
        let pattern = #"^[A-Za-z0-9._:-]{1,128}$"#
        guard request.idempotencyKey.range(of: pattern, options: .regularExpression) != nil else {
            throw CalendarRegistrySyncError.invalidIdempotencyKey
        }
        guard request.end > request.start else { throw CalendarRegistrySyncError.invalidTimeRange }
        guard TimeZone(identifier: request.timeZoneIdentifier) != nil else {
            throw CalendarRegistrySyncError.invalidTimeZone(request.timeZoneIdentifier)
        }
        guard !request.calendarId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CalendarRegistrySyncError.missingCalendarId
        }
        guard !request.semantics.primaryBlockId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CalendarRegistrySyncError.missingPrimaryBlock
        }
        if let notes = request.notes,
           notes.contains(CalendarRegistryCalendarMetadata.beginMarker) ||
           notes.contains(CalendarRegistryCalendarMetadata.endMarker) {
            throw CalendarRegistrySyncError.identityConflict("caller notes contain reserved Bridge metadata markers")
        }
    }

    private func assertRegistryMatchesManifest(
        _ record: TimeInstanceRecord,
        request: RegistryFirstTimeInstanceRequest
    ) throws {
        let fingerprint = request.manifest.fingerprint
        guard record.syncKey == request.idempotencyKey else {
            throw CalendarRegistrySyncError.identityConflict("Notion Sync Key differs")
        }
        guard !record.operationFingerprint.isEmpty,
              record.operationFingerprint == fingerprint else {
            throw CalendarRegistrySyncError.identityConflict("Notion operation fingerprint differs or is missing")
        }
        guard record.title == request.title,
              abs(record.scheduledStart.timeIntervalSince(request.start)) < 1,
              abs(record.scheduledEnd.timeIntervalSince(request.end)) < 1,
              record.timeZoneIdentifier == request.timeZoneIdentifier,
              record.location == request.location,
              record.notes == request.notes,
              record.semantics == request.semantics else {
            throw CalendarRegistrySyncError.identityConflict("Notion semantic state differs from the immutable manifest")
        }
        if let calendarId = record.calendarId, calendarId != request.calendarId {
            throw CalendarRegistrySyncError.identityConflict("Notion calendar ID differs from the immutable manifest")
        }
    }

    private func assertCalendarMatchesManifest(
        _ item: ExternalCalendarItem,
        request: RegistryFirstTimeInstanceRequest
    ) throws {
        if item.isRecurring { throw CalendarRegistrySyncError.recurringEventUnsupported }
        if item.isAllDay { throw CalendarRegistrySyncError.allDayEventUnsupported }
        if item.isDetached { throw CalendarRegistrySyncError.detachedEventUnsupported }
        if item.organizer != nil || !item.attendees.isEmpty {
            throw CalendarRegistrySyncError.participantConsequencesUnsupported
        }
        guard item.syncKey == request.idempotencyKey,
              item.operationFingerprint == request.manifest.fingerprint else {
            throw CalendarRegistrySyncError.identityConflict("calendar metadata identity differs or is missing")
        }
        guard item.title == request.title,
              abs(item.start.timeIntervalSince(request.start)) < 1,
              abs(item.end.timeIntervalSince(request.end)) < 1,
              item.timeZoneIdentifier == request.timeZoneIdentifier,
              item.calendarId == request.calendarId,
              item.location == request.location,
              item.notes == request.notes else {
            throw CalendarRegistrySyncError.identityConflict("calendar state differs from the immutable manifest")
        }
    }

    private func applyIdentity(_ item: ExternalCalendarItem, to record: inout TimeInstanceRecord) {
        record.calendarProvider = item.provider
        record.calendarId = item.calendarId
        record.calendarEventId = item.localEventId
        record.providerExternalId = item.providerExternalId
        record.calendarItemURL = item.itemURL
        record.calendarUpdatedAt = item.updatedAt
    }

    private static func isConflict(_ error: Error) -> Bool {
        if let sync = error as? CalendarRegistrySyncError {
            switch sync {
            case .ambiguousRegistryIdentity, .undecodableRegistryIdentity,
                 .ambiguousCalendarIdentity, .identityConflict:
                return true
            default:
                return false
            }
        }
        if case CalendarRegistryTransactionStoreError.idempotencyConflict = error { return true }
        return false
    }

    private static func syncFingerprint(record: TimeInstanceRecord, item: ExternalCalendarItem) -> String {
        let canonical = [
            record.syncKey, record.operationFingerprint, item.calendarId, item.localEventId,
            item.providerExternalId ?? "", item.title,
            CalendarRegistryISO.string(item.start), CalendarRegistryISO.string(item.end),
            item.timeZoneIdentifier, record.semantics.primaryBlockId,
            record.semantics.eventClass.rawValue
        ].joined(separator: "\u{1F}")
        return CalendarRegistryDigest.sha256(canonical)
    }

    private static let semanticFieldNames = [
        "title", "date", "status", "syncKey", "operationFingerprint", "eventClass",
        "meetingType", "primaryBlock", "blocks", "projects", "contacts",
        "schedulingAuthority", "syncState", "registryUpdatedAt", "scheduledDuration",
        "calendarLocation", "description"
    ]

    private static let pairingFieldNames = [
        "calendarProvider", "calendarId", "calendarEventId", "providerExternalId",
        "calendarUrl", "calendarUpdatedAt", "syncState", "lastSyncError"
    ]
}

// MARK: - Versioned calendar metadata

public enum CalendarRegistryCalendarMetadata {
    public static let beginMarker = "--- BRIDGE-CALENDAR-REGISTRY v1 ---"
    public static let endMarker = "--- END BRIDGE-CALENDAR-REGISTRY ---"

    public struct Identity: Sendable, Equatable {
        public var syncKey: String
        public var operationFingerprint: String

        public init(syncKey: String, operationFingerprint: String) {
            self.syncKey = syncKey
            self.operationFingerprint = operationFingerprint
        }
    }

    public static func append(to notes: String?, identity: Identity) throws -> String {
        if let notes,
           notes.contains(beginMarker) || notes.contains(endMarker) {
            throw CalendarRegistrySyncError.identityConflict("notes already contain reserved Bridge metadata")
        }
        let block = [
            beginMarker,
            "Sync-Key: \(identity.syncKey)",
            "Operation-Fingerprint: \(identity.operationFingerprint)",
            endMarker
        ].joined(separator: "\n")
        guard let notes, !notes.isEmpty else { return block }
        return notes + "\n\n" + block
    }

    public static func userNotes(from notes: String?) throws -> String? {
        guard let notes else { return nil }
        guard let begin = notes.range(of: beginMarker),
              let end = notes.range(of: endMarker),
              begin.upperBound <= end.lowerBound else {
            if notes.contains(beginMarker) || notes.contains(endMarker) {
                throw CalendarRegistrySyncError.identityConflict("calendar contains malformed Bridge metadata")
            }
            return notes.isEmpty ? nil : notes
        }
        _ = try parse(notes)
        var cleaned = notes
        let removal = begin.lowerBound..<end.upperBound
        cleaned.removeSubrange(removal)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    public static func parse(_ notes: String?) throws -> Identity? {
        guard let notes else { return nil }
        let beginCount = notes.components(separatedBy: beginMarker).count - 1
        let endCount = notes.components(separatedBy: endMarker).count - 1
        if beginCount == 0 && endCount == 0 { return nil }
        guard beginCount == 1, endCount == 1,
              let begin = notes.range(of: beginMarker),
              let end = notes.range(of: endMarker),
              begin.upperBound <= end.lowerBound else {
            throw CalendarRegistrySyncError.identityConflict("calendar contains malformed or duplicate Bridge metadata")
        }
        let body = notes[begin.upperBound..<end.lowerBound]
        var syncKey: String?
        var fingerprint: String?
        for raw in body.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("Sync-Key:") {
                guard syncKey == nil else {
                    throw CalendarRegistrySyncError.identityConflict("calendar contains duplicate Sync-Key metadata")
                }
                syncKey = String(line.dropFirst("Sync-Key:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Operation-Fingerprint:") {
                guard fingerprint == nil else {
                    throw CalendarRegistrySyncError.identityConflict("calendar contains duplicate fingerprint metadata")
                }
                fingerprint = String(line.dropFirst("Operation-Fingerprint:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let syncKey, let fingerprint, !syncKey.isEmpty, fingerprint.count == 64 else {
            throw CalendarRegistrySyncError.identityConflict("calendar Bridge metadata is incomplete")
        }
        return Identity(syncKey: syncKey, operationFingerprint: fingerprint)
    }
}

// MARK: - EventKit adapter

public actor CalendarStoringSyncProvider: CalendarSyncProviding {
    private let store: any CalendarStoring
    private let providerName: String
    private let allowlistedCalendarIds: Set<String>
    private let clock: @Sendable () -> Date

    public init(
        store: any CalendarStoring,
        providerName: String = "Apple Calendar",
        allowlistedCalendarIds: Set<String>,
        clock: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.store = store
        self.providerName = providerName
        self.allowlistedCalendarIds = allowlistedCalendarIds
        self.clock = clock
    }

    public func qualify(calendarId: String) async throws -> CalendarQualification {
        guard let info = try await store.calendars().first(where: { $0.id == calendarId }) else {
            throw CalendarModuleError.calendarNotFound(calendarId)
        }
        let allowlisted = allowlistedCalendarIds.contains(calendarId)
        let local = info.calendarType == "local" && (info.sourceType == nil || info.sourceType == "local")
        return CalendarQualification(
            calendarId: info.id,
            title: info.title,
            allowsModify: info.allowsModify,
            explicitlyAllowlisted: allowlisted,
            calendarType: info.calendarType,
            sourceType: info.sourceType,
            qualifiedForPrivateSmoke: allowlisted && info.allowsModify && local
        )
    }

    public func create(_ draft: ExternalCalendarDraft) async throws -> ExternalCalendarItem {
        let qualification = try await qualify(calendarId: draft.calendarId)
        guard qualification.qualifiedForPrivateSmoke else {
            throw CalendarRegistrySyncError.calendarNotQualified(draft.calendarId)
        }
        let notes = try CalendarRegistryCalendarMetadata.append(
            to: draft.notes,
            identity: .init(
                syncKey: draft.syncKey,
                operationFingerprint: draft.operationFingerprint
            )
        )
        let event = try await store.create(CalendarEventDraft(
            title: draft.title,
            start: Self.iso(draft.start),
            end: Self.iso(draft.end),
            allDay: false,
            calendarId: draft.calendarId,
            location: draft.location,
            notes: notes,
            timeZoneIdentifier: draft.timeZoneIdentifier
        ))
        return try map(event)
    }

    public func item(id: String) async throws -> ExternalCalendarItem? {
        guard let event = try await store.event(id: id) else { return nil }
        return try map(event)
    }

    public func recover(_ query: CalendarRecoveryQuery) async throws -> [ExternalCalendarItem] {
        if let id = query.localEventId, let direct = try await item(id: id) {
            return [direct]
        }
        let lower = query.start.addingTimeInterval(-30 * 86_400)
        let upper = query.end.addingTimeInterval(30 * 86_400)
        let events = try await store.events(CalendarEventQuery(
            start: Self.iso(lower), end: Self.iso(upper), calendarId: nil
        ))
        let mapped = try events.map(map)
        let eligible = mapped.filter { !$0.isRecurring && !$0.isAllDay && !$0.isDetached }

        let byIdentity = eligible.filter {
            $0.syncKey == query.syncKey && $0.operationFingerprint == query.operationFingerprint
        }
        if !byIdentity.isEmpty { return byIdentity }

        if let external = query.providerExternalId {
            let byExternal = eligible.filter { $0.providerExternalId == external }
            if !byExternal.isEmpty { return byExternal }
        }

        return eligible.filter {
            $0.calendarId == query.calendarId
                && $0.title.caseInsensitiveCompare(query.title) == .orderedSame
                && abs($0.start.timeIntervalSince(query.start)) < 1
                && abs($0.end.timeIntervalSince(query.end)) < 1
        }
    }

    private func map(_ event: CalendarEvent) throws -> ExternalCalendarItem {
        guard let start = try? CalendarISOParsing.parse(event.start),
              let end = try? CalendarISOParsing.parse(event.end) else {
            throw CalendarModuleError.invalidDate("\(event.start) – \(event.end)")
        }
        let metadata = try CalendarRegistryCalendarMetadata.parse(event.notes)
        return ExternalCalendarItem(
            provider: providerName,
            calendarId: event.calendarId,
            localEventId: event.id,
            providerExternalId: event.externalId,
            itemURL: event.conferenceURL,
            syncKey: metadata?.syncKey,
            operationFingerprint: metadata?.operationFingerprint,
            title: event.title,
            start: start,
            end: end,
            timeZoneIdentifier: event.timeZoneIdentifier ?? "",
            location: event.location,
            notes: try CalendarRegistryCalendarMetadata.userNotes(from: event.notes),
            organizer: event.organizer,
            attendees: event.attendees,
            updatedAt: event.lastModified.flatMap { try? CalendarISOParsing.parse($0) } ?? clock(),
            isRecurring: event.isRecurring,
            isAllDay: event.allDay,
            isDetached: event.isDetached
        )
    }

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
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
        var cursor: String?
        var records: [TimeInstanceRecord] = []
        var unresolved: [RegistryUnresolvedIdentity] = []
        repeat {
            let result = try await gateway.query(
                dataSourceId: entity.dataSourceId,
                workspace: entity.workspace,
                filter: filter,
                pageSize: 100,
                startCursor: cursor
            )
            for row in result.rows {
                let cached = Self.cached(row, entity: entity)
                if let record = Self.decode(cached) {
                    records.append(record)
                } else {
                    let fingerprint: String?
                    if case .object(let properties) = cached.properties {
                        fingerprint = Self.string(properties["operationFingerprint"])
                    } else {
                        fingerprint = nil
                    }
                    unresolved.append(RegistryUnresolvedIdentity(
                        pageId: row.id,
                        operationFingerprint: fingerprint
                    ))
                }
            }
            cursor = result.nextCursor
        } while cursor != nil
        return RegistryIdentityLookup(
            records: records,
            unresolvedIdentities: unresolved,
            source: .live
        )
    }

    public func get(id: String, forceRefresh: Bool) async throws -> TimeInstanceRecord? {
        let row = try await reader.get(entity: entity, pageId: id, forceRefresh: forceRefresh)
        return Self.decode(row)
    }

    public func create(_ record: TimeInstanceRecord) async throws -> TimeInstanceRecord {
        let all = try resolvedFields(record)
        let identityNames = Set(["title", "syncKey", "operationFingerprint", "syncState"].compactMap {
            entity.property($0)?.notionName
        })
        let identity = all.filter { identityNames.contains($0.notionName) }
        let rest = all.filter { !identityNames.contains($0.notionName) }
        guard identity.count == identityNames.count else {
            throw RegistryWriter.RegistryWriteError.notFullyBound(
                entity: entity.key,
                unbound: ["title", "syncKey", "operationFingerprint", "syncState"]
            )
        }
        let created = try await gateway.create(
            dataSourceId: entity.dataSourceId,
            workspace: entity.workspace,
            fields: identity
        )
        _ = await RegistryReader.store(created, entity: entity, into: reader.cache)
        if !rest.isEmpty {
            do {
                _ = try await gateway.update(
                    pageId: created.id,
                    workspace: entity.workspace,
                    fields: rest
                )
            } catch {
                throw PartialRegistryCreateError(pageId: created.id, message: error.localizedDescription)
            }
        }
        guard let fresh = try await get(id: created.id, forceRefresh: true) else {
            throw CalendarRegistrySyncError.verificationFailed("created Notion EVENT could not be read back")
        }
        return fresh
    }

    public func repair(id: String, from record: TimeInstanceRecord) async throws -> TimeInstanceRecord {
        var repair = record
        repair.id = id
        _ = try await writer.update(entity: entity, pageId: id, fields: fields(repair))
        guard let fresh = try await get(id: id, forceRefresh: true) else {
            throw CalendarRegistrySyncError.verificationFailed("repaired Notion EVENT could not be decoded")
        }
        return fresh
    }

    public func save(_ record: TimeInstanceRecord) async throws -> TimeInstanceRecord {
        _ = try await writer.update(entity: entity, pageId: record.id, fields: fields(record))
        guard let fresh = try await get(id: record.id, forceRefresh: true) else {
            throw CalendarRegistrySyncError.verificationFailed("updated Notion EVENT could not be read back")
        }
        return fresh
    }

    private func resolvedFields(_ record: TimeInstanceRecord) throws -> [BoundField] {
        let resolved = RegistryWriter.resolve(fields(record), entity: entity)
        if !resolved.unknown.isEmpty {
            throw RegistryWriter.RegistryWriteError.unknownFields(entity: entity.key, keys: resolved.unknown)
        }
        if !resolved.unbound.isEmpty {
            throw RegistryWriter.RegistryWriteError.notFullyBound(entity: entity.key, unbound: resolved.unbound)
        }
        return resolved.fields
    }

    private func fields(_ record: TimeInstanceRecord) -> [String: Value] {
        [
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
            "providerExternalId": Self.nullable(record.providerExternalId),
            "calendarUrl": Self.nullable(record.calendarItemURL),
            "meetingType": Self.nullable(record.semantics.meetingType),
            "lastSyncError": Self.nullable(record.lastSyncError),
            "lastSyncedAt": Self.nullableDate(record.lastSyncedAt),
            "calendarUpdatedAt": Self.nullableDate(record.calendarUpdatedAt)
        ]
    }

    private static func cached(_ row: NotionRow, entity: RegistryEntity) -> CachedRow {
        let projected = RegistryReader.project(row, entity: entity)
        return CachedRow(
            entity: entity.key,
            pageId: row.id,
            title: projected.title,
            url: row.url,
            properties: projected.properties,
            lastEditedTime: row.lastEditedTime,
            writtenAt: Date(),
            ttlSeconds: entity.cacheTTLSeconds,
            callCount: 1
        )
    }

    private static func decode(_ row: CachedRow) -> TimeInstanceRecord? {
        guard case .object(let properties) = row.properties,
              let range = dateRange(properties["date"]),
              let syncKey = string(properties["syncKey"]),
              let fingerprint = string(properties["operationFingerprint"]),
              let primaryBlock = strings(properties["primaryBlock"]).first,
              let eventClassRaw = string(properties["eventClass"]),
              let eventClass = TimeInstanceEventClass(rawValue: eventClassRaw) else { return nil }
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
            operationFingerprint: fingerprint,
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
        guard case .object(let object)? = value,
              case .string(let startString)? = object["start"],
              case .string(let endString)? = object["end"],
              case .string(let timeZone)? = object["timeZone"],
              let start = CalendarRegistryISO.date(startString),
              let end = CalendarRegistryISO.date(endString) else { return nil }
        return (start, end, timeZone)
    }
}

public extension CalendarRegistrySyncEngine {
    static let requiredScheduleCanonicalFields: Set<String> = [
        "syncKey", "operationFingerprint", "calendarProvider", "calendarId",
        "calendarEventId", "providerExternalId", "calendarUrl", "eventClass",
        "meetingType", "primaryBlock", "schedulingAuthority", "syncState",
        "lastSyncedAt", "registryUpdatedAt", "calendarUpdatedAt", "syncHash",
        "lastSyncError", "scheduledDuration", "calendarLocation"
    ]
}
