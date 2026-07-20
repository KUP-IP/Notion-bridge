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
        self.meetingType = Self.optional(meetingType)
        self.primaryBlockId = primaryBlockId.trimmingCharacters(in: .whitespacesAndNewlines)
        self.blockIds = Array(Set((blockIds + [self.primaryBlockId])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })).sorted()
        self.projectIds = Array(Set(projectIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })).sorted()
        self.contactIds = Array(Set(contactIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })).sorted()
    }

    private static func optional(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
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
    public var createInvocationId: String?
    public var title: String
    public var start: Date
    public var end: Date
    public var timeZoneIdentifier: String
    public var location: String?
    public var notes: String?
    public var organizer: String?
    public var attendees: [String]
    public var updatedAt: Date?
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
        createInvocationId: String? = nil,
        title: String,
        start: Date,
        end: Date,
        timeZoneIdentifier: String,
        location: String? = nil,
        notes: String? = nil,
        organizer: String? = nil,
        attendees: [String] = [],
        updatedAt: Date? = nil,
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
        self.createInvocationId = createInvocationId
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
    public var createInvocationId: String

    public init(
        title: String,
        start: Date,
        end: Date,
        timeZoneIdentifier: String,
        calendarId: String,
        location: String? = nil,
        notes: String? = nil,
        syncKey: String,
        operationFingerprint: String,
        createInvocationId: String
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
        self.createInvocationId = createInvocationId
    }
}

public struct CalendarRecoveryQuery: Sendable, Equatable {
    public var localEventId: String?
    public var providerExternalId: String?
    public var syncKey: String
    public var operationFingerprint: String
    public var createInvocationId: String?
    public var calendarId: String
    public var title: String
    public var start: Date
    public var end: Date

    public init(
        localEventId: String? = nil,
        providerExternalId: String? = nil,
        syncKey: String,
        operationFingerprint: String,
        createInvocationId: String? = nil,
        calendarId: String,
        title: String,
        start: Date,
        end: Date
    ) {
        self.localEventId = localEventId
        self.providerExternalId = providerExternalId
        self.syncKey = syncKey
        self.operationFingerprint = operationFingerprint
        self.createInvocationId = createInvocationId
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
    public var createInvocationId: String?
    public var syncWriterToken: String?
    public var syncRevision: Int
    public var semantics: TimeInstanceSemantics
    public var schedulingAuthority: TimeInstanceSchedulingAuthority
    public var syncState: TimeInstanceSyncState
    public var lastSyncedAt: Date?
    public var registryUpdatedAt: Date
    public var calendarUpdatedAt: Date?
    public var syncHash: String
    public var lastSyncError: String?
    public var registryRevision: String?

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
        createInvocationId: String? = nil,
        syncWriterToken: String? = nil,
        syncRevision: Int = 0,
        semantics: TimeInstanceSemantics,
        schedulingAuthority: TimeInstanceSchedulingAuthority,
        syncState: TimeInstanceSyncState,
        lastSyncedAt: Date? = nil,
        registryUpdatedAt: Date,
        calendarUpdatedAt: Date? = nil,
        syncHash: String = "",
        lastSyncError: String? = nil,
        registryRevision: String? = nil
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
        self.createInvocationId = createInvocationId
        self.syncWriterToken = syncWriterToken
        self.syncRevision = syncRevision
        self.semantics = semantics
        self.schedulingAuthority = schedulingAuthority
        self.syncState = syncState
        self.lastSyncedAt = lastSyncedAt
        self.registryUpdatedAt = registryUpdatedAt
        self.calendarUpdatedAt = calendarUpdatedAt
        self.syncHash = syncHash
        self.lastSyncError = lastSyncError
        self.registryRevision = registryRevision
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
    public var syncKey: String?
    public var operationFingerprint: String?

    public init(pageId: String, syncKey: String? = nil, operationFingerprint: String?) {
        self.pageId = pageId
        self.syncKey = syncKey
        self.operationFingerprint = operationFingerprint
    }
}

public enum RegistryRecordIdentityRead: Sendable, Equatable {
    case decoded(TimeInstanceRecord)
    case partial(pageId: String, syncKey: String?, operationFingerprint: String?)
    case missing
    case malformed(pageId: String, reason: String)
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

package struct PartialRegistryCreateError: Error, LocalizedError, Sendable, Equatable {
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
    func readIdentity(id: String, forceRefresh: Bool) async throws -> RegistryRecordIdentityRead
    func get(id: String, forceRefresh: Bool) async throws -> TimeInstanceRecord?
    func savePairing(_ record: TimeInstanceRecord, expectedRevision: String?) async throws -> TimeInstanceRecord
}

public protocol CalendarSyncProviding: Sendable {
    func qualify(calendarId: String) async throws -> CalendarQualification
    func create(_ draft: ExternalCalendarDraft) async throws -> ExternalCalendarItem
    func item(id: String) async throws -> ExternalCalendarItem?
    func recover(_ query: CalendarRecoveryQuery) async throws -> [ExternalCalendarItem]
}

public struct RegistryFirstTimeInstanceRequest: Sendable, Equatable {
    public var idempotencyKey: String
    public var registryEventId: String
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
        registryEventId: String,
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
        self.registryEventId = registryEventId
        self.title = title
        self.start = start
        self.end = end
        self.timeZoneIdentifier = timeZoneIdentifier
        self.calendarId = calendarId
        self.location = location
        self.notes = notes
        self.semantics = semantics
    }

    public var canonicalized: RegistryFirstTimeInstanceRequest {
        let manifest = self.manifest
        return RegistryFirstTimeInstanceRequest(
            idempotencyKey: idempotencyKey,
            registryEventId: registryEventId.trimmingCharacters(in: .whitespacesAndNewlines),
            title: manifest.title,
            start: manifest.start,
            end: manifest.end,
            timeZoneIdentifier: manifest.timeZoneIdentifier,
            calendarId: manifest.calendarId,
            location: manifest.location,
            notes: manifest.notes,
            semantics: TimeInstanceSemantics(
                eventClass: semantics.eventClass,
                meetingType: manifest.meetingType,
                primaryBlockId: manifest.primaryBlockId,
                blockIds: manifest.blockIds,
                projectIds: manifest.projectIds,
                contactIds: manifest.contactIds
            )
        )
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
            schedulingAuthority: TimeInstanceSchedulingAuthority.registry.rawValue,
            expectedInitialSyncState: TimeInstanceSyncState.pendingCreate.rawValue,
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
    public var fencingToken: String?
    public var ledgerRevision: Int?
    public var verifiedSyncHash: String?
    public var verifiedAt: Date?
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
    public var coordinatorNamespace: String? = nil
    public var registryIdentityCount: Int? = nil
    public var calendarIdentityCount: Int? = nil
    public var finalRegistryRevision: String? = nil
    public var attemptId: String? = nil
    public var createInvocationId: String? = nil
    public var syncWriterToken: String? = nil
    public var syncRevision: Int? = nil
    public var calendarSearchScopes: [String] = []
    public var ledgerOutcomePersisted: Bool = false
    public var notionOutcomePersisted: Bool = false
    public var pairIdentityPersisted: Bool = false
    public var coordinatorReleaseSucceeded: Bool = false
}

public enum CalendarRegistrySyncError: Error, LocalizedError, Equatable {
    case invalidTimeRange
    case invalidTimeZone(String)
    case missingPrimaryBlock
    case invalidIdempotencyKey
    case missingCalendarId
    case missingRegistryEventId
    case calendarNotQualified(String)
    case ambiguousRegistryIdentity([String])
    case undecodableRegistryIdentity([String])
    case ambiguousCalendarIdentity([String])
    case degradedRegistryLookup
    case recurringEventUnsupported
    case allDayEventUnsupported
    case detachedEventUnsupported
    case participantConsequencesUnsupported
    case calendarEffectUnknown(String)
    case operatorReview(String)
    case identityConflict(String)
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidTimeRange: return "scheduled end must be after scheduled start"
        case .invalidTimeZone(let value): return "invalid timezone identifier: \(value)"
        case .missingPrimaryBlock: return "Primary BLOCK is required"
        case .invalidIdempotencyKey: return "idempotency key must be 1–128 characters using letters, digits, period, underscore, colon, or hyphen"
        case .missingCalendarId: return "an explicit allowlisted calendar ID is required"
        case .missingRegistryEventId: return "a pre-existing Notion EVENT page ID is required"
        case .calendarNotQualified(let reason): return "calendar is not qualified for a private smoke: \(reason)"
        case .ambiguousRegistryIdentity(let ids): return "multiple registry EVENTS matched: \(ids.joined(separator: ", "))"
        case .undecodableRegistryIdentity(let ids): return "matching registry EVENTS could not be decoded safely: \(ids.joined(separator: ", "))"
        case .ambiguousCalendarIdentity(let ids): return "multiple calendar events matched: \(ids.joined(separator: ", "))"
        case .degradedRegistryLookup: return "registry identity lookup was not live; creation refused"
        case .recurringEventUnsupported: return "recurring events are outside the registry-first v1 slice"
        case .allDayEventUnsupported: return "all-day events are outside the registry-first v1 slice"
        case .detachedEventUnsupported: return "detached recurring occurrences are outside the registry-first v1 slice"
        case .participantConsequencesUnsupported: return "attendee or organizer consequences are outside the registry-first v1 slice"
        case .calendarEffectUnknown(let reason): return "calendar create effect is unknown; recovery only: \(reason)"
        case .operatorReview(let reason): return "calendar-registry operator review required: \(reason)"
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

/// Package-scoped crash-injection seam for proving forward recovery across
/// durable writes and the EventKit external effect. Production composition uses
/// the no-op default; no public tool or runtime setting can select a checkpoint.
package enum CalendarRegistryDurableCheckpoint: String, CaseIterable, Sendable {
    case claimPersisted
    case registryAuthorizationPersisted
    case createInvocationHeartbeatPersisted
    case createInvocationRegistryPersisted
    case createInvocationLedgerPersisted
    case calendarCreateReturned
    case calendarIdentityLedgerPersisted
    case pairIdentityHeartbeatPersisted
    case pairIdentityRegistryPersisted
    case pairIdentityLedgerPersisted
    case syncEvidenceHeartbeatPersisted
    case syncEvidenceRegistryPersisted
    case syncEvidenceLedgerPersisted
    case completionLedgerPersisted
    case completionLeaseReleased
}

public actor CalendarRegistrySyncEngine {
    private let registry: any TimeInstanceRegistryStoring
    private let calendar: any CalendarSyncProviding
    private let transactions: any CalendarRegistryTransactionStoring
    private let processLocks: any CalendarRegistryProcessLocking
    private let operationGate: CalendarRegistryOperationGate
    private let clock: @Sendable () -> Date
    private let makeOperationId: @Sendable () -> String
    private let makeLeaseToken: @Sendable () -> String
    private let makeCreateInvocationId: @Sendable () -> String
    private let makeSyncWriterToken: @Sendable () -> String
    private let durableCheckpoint: @Sendable (CalendarRegistryDurableCheckpoint) -> Void
    private let leaseDuration: TimeInterval

    package init(
        registry: any TimeInstanceRegistryStoring,
        calendar: any CalendarSyncProviding,
        transactions: any CalendarRegistryTransactionStoring,
        processLocks: any CalendarRegistryProcessLocking,
        operationGate: CalendarRegistryOperationGate = .shared,
        clock: @Sendable @escaping () -> Date = { Date() },
        makeOperationId: @Sendable @escaping () -> String = { UUID().uuidString.lowercased() },
        makeLeaseToken: @Sendable @escaping () -> String = { UUID().uuidString.lowercased() },
        makeCreateInvocationId: @Sendable @escaping () -> String = { UUID().uuidString.lowercased() },
        makeSyncWriterToken: @Sendable @escaping () -> String = { UUID().uuidString.lowercased() },
        durableCheckpoint: @Sendable @escaping (CalendarRegistryDurableCheckpoint) -> Void = { _ in },
        leaseDuration: TimeInterval = 600
    ) {
        self.registry = registry
        self.calendar = calendar
        self.transactions = transactions
        self.processLocks = processLocks
        self.operationGate = operationGate
        self.clock = clock
        self.makeOperationId = makeOperationId
        self.makeLeaseToken = makeLeaseToken
        self.makeCreateInvocationId = makeCreateInvocationId
        self.makeSyncWriterToken = makeSyncWriterToken
        self.durableCheckpoint = durableCheckpoint
        self.leaseDuration = leaseDuration
    }

    public func registryFirstCreate(
        _ rawRequest: RegistryFirstTimeInstanceRequest
    ) async throws -> CalendarRegistrySyncReceipt {
        let request = rawRequest.canonicalized
        try validate(request)
        let attemptId = makeOperationId()
        try await operationGate.acquire(request.idempotencyKey)

        let processLock: any CalendarRegistryProcessLockHandle
        do {
            processLock = try processLocks.acquire(idempotencyKey: request.idempotencyKey)
        } catch let error as CalendarRegistryProcessLockError {
            await operationGate.release(request.idempotencyKey)
            var receipt = Self.processLockFailureReceipt(request: request, error: error)
            receipt.attemptId = attemptId
            receipt.coordinatorNamespace = processLocks.coordinatorNamespace
            return receipt
        } catch {
            await operationGate.release(request.idempotencyKey)
            throw error
        }

        do {
            var receipt = try await performRegistryFirstCreate(request, attemptId: attemptId)
            receipt.attemptId = attemptId
            receipt.coordinatorNamespace = processLocks.coordinatorNamespace
            receipt.finalRegistryRevision = receipt.record?.registryRevision
            if receipt.succeeded {
                receipt.registryIdentityCount = 1
                receipt.calendarIdentityCount = 1
            }
            do {
                try processLock.release()
                receipt.coordinatorReleaseSucceeded = true
            } catch {
                receipt.succeeded = false
                receipt.infrastructureFault = true
                receipt.recoveryAction = "pair state is unchanged; inspect the process lock before retrying"
                receipt.discrepancy = [receipt.discrepancy, error.localizedDescription]
                    .compactMap { $0 }.joined(separator: " | ")
            }
            await operationGate.release(request.idempotencyKey)
            return receipt
        } catch let storeError as CalendarRegistryTransactionStoreError {
            let existing = try? await transactions.get(idempotencyKey: request.idempotencyKey)
            let releaseError = Result { try processLock.release() }.failure
            await operationGate.release(request.idempotencyKey)
            var receipt = Self.storeFailureReceipt(
                request: request,
                storeError: storeError,
                existing: existing,
                processReleaseError: releaseError
            )
            receipt.attemptId = attemptId
            receipt.coordinatorNamespace = processLocks.coordinatorNamespace
            receipt.finalRegistryRevision = receipt.record?.registryRevision
            return receipt
        } catch {
            let releaseError = Result { try processLock.release() }.failure
            await operationGate.release(request.idempotencyKey)
            if let releaseError {
                throw CalendarRegistryProcessLockError.releaseFailure(
                    "operation failed: \(error.localizedDescription) | lock release failed: \(releaseError.localizedDescription)"
                )
            }
            throw error
        }
    }

    private func performRegistryFirstCreate(
        _ request: RegistryFirstTimeInstanceRequest,
        attemptId: String
    ) async throws -> CalendarRegistrySyncReceipt {
        let fingerprint = request.manifest.fingerprint
        var transaction = try await transactions.claim(
            idempotencyKey: request.idempotencyKey,
            manifestFingerprint: fingerprint,
            operationId: attemptId,
            leaseOwner: attemptId,
            leaseToken: makeLeaseToken(),
            leaseDuration: leaseDuration,
            exclusiveProcessLockHeld: true
        )
        durableCheckpoint(.claimPersisted)
        let stageBefore = transaction.stage
        let fencingToken = transaction.leaseToken
        var record: TimeInstanceRecord?
        var calendarItem: ExternalCalendarItem?
        var registryFields: [String] = []
        var calendarFields: [String] = []
        var evidence: [String] = []
        var searchScopes: [String] = []
        var notionOutcomePersisted = false
        var pairPersisted = [.pairIdentityPersisted, .syncEvidencePersisted, .complete].contains(transaction.stage)
        var createAuthorizedThisAttempt = false

        if [.conflict, .operatorReview, .abandoned].contains(transaction.stage) {
            let released = try await transactions.release(transaction)
            return makeReceipt(
                succeeded: false, infrastructureFault: false, ledgerPersisted: true,
                notionPersisted: false, pairPersisted: pairPersisted,
                transaction: released, fencingToken: fencingToken, stageBefore: stageBefore,
                record: nil, item: nil, registryFields: [], calendarFields: [],
                evidence: [], searchScopes: [], recoveryAction: Self.recoveryAction(for: stageBefore, persisted: true),
                discrepancy: transaction.lastError ?? "transaction requires explicit operator resolution"
            )
        }

        do {
            while true {
                switch transaction.stage {
                case .claimed:
                    record = try await resolveExistingRegistry(request: request, transaction: transaction)
                    guard record?.createInvocationId == nil else {
                        throw CalendarRegistrySyncError.operatorReview(
                            "Notion contains a Create Invocation ID that is absent from the claimed ledger state"
                        )
                    }
                    transaction.registryEventId = request.registryEventId
                    transaction.stage = .registryAuthorized
                    transaction.lastError = nil
                    transaction.partialEffects.append("strictly authorized pre-existing Notion EVENT \(request.registryEventId)")
                    transaction = try await transactions.save(transaction)
                    durableCheckpoint(.registryAuthorizationPersisted)
                    evidence.append("Notion authority and admissibility were proven before EventKit access")

                case .registryAuthorized:
                    record = try await requireRegistryRecord(request: request, transaction: transaction)
                    if let notionInvocation = record?.createInvocationId {
                        guard notionInvocation == transaction.createInvocationId else {
                            throw CalendarRegistrySyncError.operatorReview(
                                "Notion and SQLite disagree about the Create Invocation ID"
                            )
                        }
                        transaction.stage = .createInvocationPersisted
                        transaction = try await transactions.save(transaction)
                        continue
                    }
                    let qualification = try await calendar.qualify(calendarId: request.calendarId)
                    guard qualification.qualifiedForPrivateSmoke else {
                        throw CalendarRegistrySyncError.calendarNotQualified(
                            "calendar must be explicitly allowlisted, writable, local, and non-subscribed"
                        )
                    }
                    evidence.append("qualified explicit private-smoke calendar \(qualification.calendarId)")
                    guard var authorized = record else {
                        throw CalendarRegistrySyncError.verificationFailed("authorized registry record disappeared")
                    }
                    let invocationId = makeCreateInvocationId()
                    let writerToken = makeSyncWriterToken()
                    authorized.createInvocationId = invocationId
                    authorized.syncRevision += 1
                    authorized.syncWriterToken = writerToken
                    authorized.registryUpdatedAt = clock()
                    try await heartbeat(&transaction)
                    durableCheckpoint(.createInvocationHeartbeatPersisted)
                    authorized = try await registry.savePairing(authorized, expectedRevision: authorized.registryRevision)
                    durableCheckpoint(.createInvocationRegistryPersisted)
                    try assertWriterEvidence(
                        authorized, expectedInvocationId: invocationId,
                        expectedWriterToken: writerToken, expectedSyncRevision: authorized.syncRevision
                    )
                    notionOutcomePersisted = true
                    registryFields.append(contentsOf: ["createInvocationId", "syncWriterToken", "syncRevision"])
                    record = authorized
                    transaction.createInvocationId = invocationId
                    transaction.syncWriterToken = writerToken
                    transaction.syncRevision = authorized.syncRevision
                    transaction.stage = .createInvocationPersisted
                    transaction.partialEffects.append("persisted Create Invocation ID \(invocationId) before EventKit create")
                    transaction = try await transactions.save(transaction)
                    durableCheckpoint(.createInvocationLedgerPersisted)
                    createAuthorizedThisAttempt = true

                case .createInvocationPersisted, .calendarEffectUnknown:
                    record = try await requireRegistryRecord(request: request, transaction: transaction)
                    guard let invocationId = transaction.createInvocationId,
                          invocationId == record?.createInvocationId else {
                        throw CalendarRegistrySyncError.operatorReview(
                            "Create Invocation ID is not durably consistent across Notion and SQLite"
                        )
                    }
                    let query = recoveryQuery(request: request, transaction: transaction, record: record)
                    searchScopes.append(Self.searchScopeDescription(query))
                    let recovered = try await calendar.recover(query)
                    if recovered.count > 1 {
                        throw CalendarRegistrySyncError.ambiguousCalendarIdentity(recovered.map { $0.localEventId })
                    }
                    if let existing = recovered.first {
                        try assertCalendarMatchesManifest(existing, request: request, createInvocationId: invocationId)
                        try setCalendarIdentity(existing, on: &transaction)
                        calendarItem = existing
                        transaction.stage = .calendarIdentified
                        transaction.lastError = nil
                        transaction.partialEffects.append("identified owned calendar event \(existing.localEventId)")
                        transaction = try await transactions.save(transaction)
                        continue
                    }
                    if transaction.stage == .calendarEffectUnknown || !createAuthorizedThisAttempt {
                        throw CalendarRegistrySyncError.operatorReview(
                            "Create Invocation ID exists but no owned EventKit candidate is recoverable; automatic recreation is prohibited"
                        )
                    }
                    try Task.checkCancellation()
                    do {
                        let created = try await calendar.create(ExternalCalendarDraft(
                            title: request.title,
                            start: request.start,
                            end: request.end,
                            timeZoneIdentifier: request.timeZoneIdentifier,
                            calendarId: request.calendarId,
                            location: request.location,
                            notes: request.notes,
                            syncKey: request.idempotencyKey,
                            operationFingerprint: request.manifest.fingerprint,
                            createInvocationId: invocationId
                        ))
                        durableCheckpoint(.calendarCreateReturned)
                        try assertCalendarMatchesManifest(created, request: request, createInvocationId: invocationId)
                        try setCalendarIdentity(created, on: &transaction)
                        calendarItem = created
                        transaction.stage = .calendarIdentified
                        transaction.lastError = nil
                        transaction.partialEffects.append("invoked EventKit create once for \(invocationId) and identified \(created.localEventId)")
                        transaction = try await transactions.save(transaction)
                        durableCheckpoint(.calendarIdentityLedgerPersisted)
                        calendarFields.append(contentsOf: [
                            "title", "start", "end", "timeZone", "calendarId", "location", "notes",
                            "syncKey", "operationFingerprint", "createInvocationId"
                        ])
                    } catch {
                        transaction.stage = .calendarEffectUnknown
                        transaction.lastError = error.localizedDescription
                        transaction = try await transactions.save(transaction)
                        throw CalendarRegistrySyncError.calendarEffectUnknown(error.localizedDescription)
                    }

                case .calendarIdentified:
                    record = try await requireRegistryRecord(request: request, transaction: transaction)
                    calendarItem = try await requireCalendarItem(request: request, transaction: transaction, record: record)
                    guard var pair = record, let item = calendarItem else {
                        throw CalendarRegistrySyncError.verificationFailed("identified pair surface disappeared")
                    }
                    try applyIdentity(item, to: &pair)
                    pair.createInvocationId = transaction.createInvocationId
                    pair.syncState = .pendingCreate
                    pair.lastSyncError = nil
                    pair.syncRevision += 1
                    pair.syncWriterToken = makeSyncWriterToken()
                    pair.registryUpdatedAt = clock()
                    try await heartbeat(&transaction)
                    durableCheckpoint(.pairIdentityHeartbeatPersisted)
                    pair = try await registry.savePairing(pair, expectedRevision: record?.registryRevision)
                    durableCheckpoint(.pairIdentityRegistryPersisted)
                    try assertWriterEvidence(
                        pair, expectedInvocationId: transaction.createInvocationId,
                        expectedWriterToken: pair.syncWriterToken, expectedSyncRevision: pair.syncRevision
                    )
                    notionOutcomePersisted = true
                    registryFields.append(contentsOf: Self.pairingFieldNames + ["createInvocationId", "syncWriterToken", "syncRevision"])
                    record = pair
                    transaction.registryEventId = pair.id
                    transaction.syncWriterToken = pair.syncWriterToken
                    transaction.syncRevision = pair.syncRevision
                    transaction.stage = .pairIdentityPersisted
                    transaction.partialEffects.append("persisted immutable pair identity to Notion")
                    transaction = try await transactions.save(transaction)
                    durableCheckpoint(.pairIdentityLedgerPersisted)
                    pairPersisted = true

                case .pairIdentityPersisted:
                    guard let recordId = transaction.registryEventId,
                          let eventId = transaction.calendarEventId else {
                        throw CalendarRegistrySyncError.identityConflict("pair-persisted ledger is missing pair identifiers")
                    }
                    let preliminary = try await verify(
                        request: request, recordId: recordId, calendarEventId: eventId,
                        requireSyncedEvidence: false, expectedSyncedAt: nil,
                        expectedCreateInvocationId: transaction.createInvocationId
                    )
                    evidence.append(contentsOf: preliminary.evidence)
                    searchScopes.append(contentsOf: preliminary.searchScopes)
                    if preliminary.record.syncState == .synced {
                        guard preliminary.record.syncHash == preliminary.recomputedHash,
                              preliminary.record.lastSyncedAt != nil else {
                            throw CalendarRegistrySyncError.identityConflict(
                                "Notion claims Synced but final synchronization evidence is incomplete"
                            )
                        }
                        transaction.lastVerifiedAt = preliminary.record.lastSyncedAt
                        transaction.syncWriterToken = preliminary.record.syncWriterToken
                        transaction.syncRevision = preliminary.record.syncRevision
                        transaction.stage = .syncEvidencePersisted
                        transaction = try await transactions.save(transaction)
                        continue
                    }
                    var syncedRecord = preliminary.record
                    let verifiedAt = clock()
                    syncedRecord.syncState = .synced
                    syncedRecord.lastSyncedAt = verifiedAt
                    syncedRecord.registryUpdatedAt = verifiedAt
                    syncedRecord.lastSyncError = nil
                    syncedRecord.syncHash = preliminary.recomputedHash
                    syncedRecord.syncRevision += 1
                    syncedRecord.syncWriterToken = makeSyncWriterToken()
                    try await heartbeat(&transaction)
                    durableCheckpoint(.syncEvidenceHeartbeatPersisted)
                    syncedRecord = try await registry.savePairing(
                        syncedRecord, expectedRevision: preliminary.record.registryRevision
                    )
                    durableCheckpoint(.syncEvidenceRegistryPersisted)
                    try assertWriterEvidence(
                        syncedRecord, expectedInvocationId: transaction.createInvocationId,
                        expectedWriterToken: syncedRecord.syncWriterToken,
                        expectedSyncRevision: syncedRecord.syncRevision
                    )
                    notionOutcomePersisted = true
                    record = syncedRecord
                    transaction.lastVerifiedAt = verifiedAt
                    transaction.syncWriterToken = syncedRecord.syncWriterToken
                    transaction.syncRevision = syncedRecord.syncRevision
                    transaction.stage = .syncEvidencePersisted
                    transaction.lastError = nil
                    transaction = try await transactions.save(transaction)
                    durableCheckpoint(.syncEvidenceLedgerPersisted)

                case .syncEvidencePersisted:
                    guard let recordId = transaction.registryEventId,
                          let eventId = transaction.calendarEventId else {
                        throw CalendarRegistrySyncError.identityConflict("sync-evidence ledger is missing pair identifiers")
                    }
                    let final = try await verify(
                        request: request, recordId: recordId, calendarEventId: eventId,
                        requireSyncedEvidence: true, expectedSyncedAt: transaction.lastVerifiedAt,
                        expectedCreateInvocationId: transaction.createInvocationId
                    )
                    record = final.record
                    calendarItem = final.item
                    evidence.append(contentsOf: final.evidence)
                    searchScopes.append(contentsOf: final.searchScopes)
                    transaction.stage = .complete
                    transaction.lastVerifiedAt = final.record.lastSyncedAt
                    transaction.lastError = nil
                    transaction = try await transactions.save(transaction)
                    durableCheckpoint(.completionLedgerPersisted)

                case .complete:
                    guard let recordId = transaction.registryEventId,
                          let eventId = transaction.calendarEventId else {
                        throw CalendarRegistrySyncError.identityConflict("complete ledger is missing pair identifiers")
                    }
                    let final = try await verify(
                        request: request, recordId: recordId, calendarEventId: eventId,
                        requireSyncedEvidence: true, expectedSyncedAt: transaction.lastVerifiedAt,
                        expectedCreateInvocationId: transaction.createInvocationId
                    )
                    let released = try await transactions.release(transaction)
                    durableCheckpoint(.completionLeaseReleased)
                    return makeReceipt(
                        succeeded: true, infrastructureFault: false, ledgerPersisted: true,
                        notionPersisted: notionOutcomePersisted, pairPersisted: true,
                        transaction: released, fencingToken: fencingToken, stageBefore: stageBefore,
                        record: final.record, item: final.item,
                        registryFields: registryFields, calendarFields: calendarFields,
                        evidence: evidence + final.evidence + ["forward-only transaction reached Complete"],
                        searchScopes: Array(Set(searchScopes + final.searchScopes)).sorted(),
                        recoveryAction: nil, discrepancy: nil,
                        verifiedHash: final.recomputedHash, verifiedAt: final.record.lastSyncedAt,
                        registryCount: 1, calendarCount: 1
                    )

                case .conflict, .operatorReview, .abandoned:
                    let released = try await transactions.release(transaction)
                    return makeReceipt(
                        succeeded: false, infrastructureFault: false, ledgerPersisted: true,
                        notionPersisted: notionOutcomePersisted, pairPersisted: pairPersisted,
                        transaction: released, fencingToken: fencingToken, stageBefore: stageBefore,
                        record: record, item: calendarItem, registryFields: registryFields,
                        calendarFields: calendarFields, evidence: evidence,
                        searchScopes: searchScopes,
                        recoveryAction: Self.recoveryAction(for: transaction.stage, persisted: true),
                        discrepancy: transaction.lastError
                    )
                }
            }
        } catch {
            let targetStage: CalendarRegistryTransactionStage
            switch error {
            case CalendarRegistrySyncError.operatorReview:
                targetStage = .operatorReview
            case CalendarRegistrySyncError.calendarEffectUnknown:
                targetStage = .calendarEffectUnknown
            default:
                targetStage = Self.isConflict(error) ? .conflict : transaction.stage
            }
            transaction.stage = targetStage
            transaction.lastError = error.localizedDescription
            var ledgerError: Error?
            do { transaction = try await transactions.save(transaction) }
            catch { ledgerError = error }
            var releaseError: Error?
            if ledgerError == nil {
                do { transaction = try await transactions.release(transaction) }
                catch { releaseError = error }
            }
            let persisted = ledgerError == nil
            let discrepancy = [
                error.localizedDescription,
                ledgerError.map { "recovery ledger write failed: \($0.localizedDescription)" },
                releaseError.map { "SQLite lease release failed: \($0.localizedDescription)" }
            ].compactMap { $0 }.joined(separator: " | ")
            return makeReceipt(
                succeeded: false,
                infrastructureFault: !persisted || releaseError != nil,
                ledgerPersisted: persisted,
                notionPersisted: notionOutcomePersisted,
                pairPersisted: pairPersisted,
                transaction: transaction,
                fencingToken: fencingToken,
                stageBefore: stageBefore,
                record: record,
                item: calendarItem,
                registryFields: registryFields,
                calendarFields: calendarFields,
                evidence: evidence,
                searchScopes: searchScopes,
                recoveryAction: Self.recoveryAction(for: targetStage, persisted: persisted),
                discrepancy: discrepancy
            )
        }
    }

    private func makeReceipt(
        succeeded: Bool,
        infrastructureFault: Bool,
        ledgerPersisted: Bool,
        notionPersisted: Bool,
        pairPersisted: Bool,
        transaction: CalendarRegistryTransaction,
        fencingToken: String?,
        stageBefore: CalendarRegistryTransactionStage,
        record: TimeInstanceRecord?,
        item: ExternalCalendarItem?,
        registryFields: [String],
        calendarFields: [String],
        evidence: [String],
        searchScopes: [String],
        recoveryAction: String?,
        discrepancy: String?,
        verifiedHash: String? = nil,
        verifiedAt: Date? = nil,
        registryCount: Int? = nil,
        calendarCount: Int? = nil
    ) -> CalendarRegistrySyncReceipt {
        var receipt = CalendarRegistrySyncReceipt(
            succeeded: succeeded,
            infrastructureFault: infrastructureFault,
            recoveryStatePersisted: ledgerPersisted,
            registryFailureStatePersisted: false,
            operationId: transaction.operationId,
            idempotencyKey: transaction.idempotencyKey,
            operationFingerprint: transaction.manifestFingerprint,
            fencingToken: fencingToken,
            ledgerRevision: transaction.revision,
            verifiedSyncHash: verifiedHash,
            verifiedAt: verifiedAt,
            stageBefore: stageBefore,
            stageAfter: transaction.stage,
            record: record,
            calendarItem: item,
            registryFieldsWritten: Array(Set(registryFields)).sorted(),
            calendarFieldsWritten: Array(Set(calendarFields)).sorted(),
            verificationEvidence: evidence,
            partialEffects: transaction.partialEffects,
            recoveryAction: recoveryAction,
            discrepancy: discrepancy
        )
        receipt.createInvocationId = transaction.createInvocationId ?? record?.createInvocationId
        receipt.syncWriterToken = record?.syncWriterToken ?? transaction.syncWriterToken
        receipt.syncRevision = record?.syncRevision ?? transaction.syncRevision
        receipt.calendarSearchScopes = Array(Set(searchScopes)).sorted()
        receipt.ledgerOutcomePersisted = ledgerPersisted
        receipt.notionOutcomePersisted = notionPersisted
        receipt.pairIdentityPersisted = pairPersisted
        receipt.registryIdentityCount = registryCount
        receipt.calendarIdentityCount = calendarCount
        receipt.finalRegistryRevision = record?.registryRevision
        return receipt
    }

    private func heartbeat(_ transaction: inout CalendarRegistryTransaction) async throws {
        try Task.checkCancellation()
        transaction = try await transactions.renew(transaction, leaseDuration: leaseDuration)
        try Task.checkCancellation()
    }

    private func resolveExistingRegistry(
        request: RegistryFirstTimeInstanceRequest,
        transaction: CalendarRegistryTransaction
    ) async throws -> TimeInstanceRecord {
        if let existingId = transaction.registryEventId, existingId != request.registryEventId {
            throw CalendarRegistrySyncError.identityConflict("ledger registry EVENT differs from the supplied page")
        }
        let direct: TimeInstanceRecord
        switch try await registry.readIdentity(id: request.registryEventId, forceRefresh: true) {
        case .decoded(let value): direct = value
        case .partial:
            throw CalendarRegistrySyncError.identityConflict("supplied Notion EVENT is partial; automatic repair is disabled")
        case .missing:
            throw CalendarRegistrySyncError.identityConflict("supplied Notion EVENT is missing")
        case .malformed(_, let reason):
            throw CalendarRegistrySyncError.identityConflict("supplied Notion EVENT is malformed: \(reason)")
        }
        let lookup = try await registry.findBySyncKey(request.idempotencyKey)
        guard lookup.source == .live else { throw CalendarRegistrySyncError.degradedRegistryLookup }
        guard lookup.unresolvedIdentities.isEmpty else {
            throw CalendarRegistrySyncError.undecodableRegistryIdentity(lookup.unresolvedIdentities.map { $0.pageId })
        }
        guard lookup.records.count == 1, let queried = lookup.records.first else {
            if lookup.records.count > 1 {
                throw CalendarRegistrySyncError.ambiguousRegistryIdentity(lookup.records.map { $0.id })
            }
            throw CalendarRegistrySyncError.identityConflict("Sync Key query did not return the supplied pre-existing EVENT")
        }
        guard queried.id == request.registryEventId, direct.id == request.registryEventId else {
            throw CalendarRegistrySyncError.identityConflict("supplied EVENT differs from the unique Sync Key result")
        }
        if transaction.stage == .claimed, direct.createInvocationId != nil {
            throw CalendarRegistrySyncError.operatorReview(
                "Notion contains a Create Invocation ID but the local ledger has no corresponding durable authorization"
            )
        }
        if transaction.stage == .registryAuthorized,
           direct.createInvocationId != nil, transaction.createInvocationId == nil {
            throw CalendarRegistrySyncError.operatorReview(
                "Notion persisted Create Invocation ID before SQLite could record the same authorization"
            )
        }
        try assertRegistryMatchesManifest(direct, request: request)
        try assertRegistryMatchesManifest(queried, request: request)
        try assertRegistryAdmissibleForPairing(direct, request: request, transaction: transaction)
        try assertRegistryAdmissibleForPairing(queried, request: request, transaction: transaction)
        return direct
    }

    private func requireRegistryRecord(
        request: RegistryFirstTimeInstanceRequest,
        transaction: CalendarRegistryTransaction
    ) async throws -> TimeInstanceRecord {
        try await resolveExistingRegistry(request: request, transaction: transaction)
    }

    private func assertWriterEvidence(
        _ record: TimeInstanceRecord,
        expectedInvocationId: String?,
        expectedWriterToken: String?,
        expectedSyncRevision: Int
    ) throws {
        guard record.createInvocationId == expectedInvocationId,
              record.syncWriterToken == expectedWriterToken,
              record.syncRevision == expectedSyncRevision,
              record.registryRevision?.isEmpty == false else {
            throw CalendarRegistrySyncError.identityConflict(
                "Notion synchronization write did not retain the expected invocation, writer token, revision, and page revision"
            )
        }
    }

    private func recoveryQuery(
        request: RegistryFirstTimeInstanceRequest,
        transaction: CalendarRegistryTransaction,
        record: TimeInstanceRecord?
    ) -> CalendarRecoveryQuery {
        CalendarRecoveryQuery(
            localEventId: transaction.calendarEventId ?? record?.calendarEventId,
            providerExternalId: transaction.providerExternalId ?? record?.providerExternalId,
            syncKey: request.idempotencyKey,
            operationFingerprint: request.manifest.fingerprint,
            createInvocationId: transaction.createInvocationId ?? record?.createInvocationId,
            calendarId: request.calendarId,
            title: request.title,
            start: request.start,
            end: request.end
        )
    }

    private static func searchScopeDescription(_ query: CalendarRecoveryQuery) -> String {
        let lower = query.start.addingTimeInterval(-30 * 86_400)
        let upper = query.end.addingTimeInterval(30 * 86_400)
        return "calendar=\(query.calendarId) window=\(CalendarRegistryISO.string(lower))...\(CalendarRegistryISO.string(upper)) channels=localId,providerId,createInvocationId,syncKey+fingerprint,exact-time"
    }

    private func requireCalendarItem(
        request: RegistryFirstTimeInstanceRequest,
        transaction: CalendarRegistryTransaction,
        record: TimeInstanceRecord?
    ) async throws -> ExternalCalendarItem {
        let query = recoveryQuery(request: request, transaction: transaction, record: record)
        let matches = try await calendar.recover(query)
        if matches.count > 1 {
            throw CalendarRegistrySyncError.ambiguousCalendarIdentity(matches.map { $0.localEventId })
        }
        guard let item = matches.first else {
            throw CalendarRegistrySyncError.operatorReview(
                "the durable pair identity exists but no owned EventKit item is recoverable within the declared search scope"
            )
        }
        try assertCalendarMatchesManifest(item, request: request, createInvocationId: transaction.createInvocationId)
        return item
    }

    private func setCalendarIdentity(
        _ item: ExternalCalendarItem,
        on transaction: inout CalendarRegistryTransaction
    ) throws {
        for (name, existing, candidate) in [
            ("calendar event id", transaction.calendarEventId, Optional(item.localEventId)),
            ("calendar id", transaction.calendarId, Optional(item.calendarId)),
            ("provider external id", transaction.providerExternalId, item.providerExternalId)
        ] where existing?.isEmpty == false && candidate?.isEmpty == false && existing != candidate {
            throw CalendarRegistrySyncError.identityConflict("established \(name) differs from recovered provider identity")
        }
        transaction.calendarEventId = transaction.calendarEventId ?? item.localEventId
        transaction.calendarId = transaction.calendarId ?? item.calendarId
        transaction.providerExternalId = transaction.providerExternalId ?? item.providerExternalId
    }

    private func verify(
        request: RegistryFirstTimeInstanceRequest,
        recordId: String,
        calendarEventId: String,
        requireSyncedEvidence: Bool = false,
        expectedSyncedAt: Date? = nil,
        expectedCreateInvocationId: String? = nil
    ) async throws -> (
        record: TimeInstanceRecord,
        item: ExternalCalendarItem,
        recomputedHash: String,
        evidence: [String],
        searchScopes: [String]
    ) {
        guard let record = try await registry.get(id: recordId, forceRefresh: true) else {
            throw CalendarRegistrySyncError.identityConflict("Notion EVENT missing during verification")
        }
        guard let item = try await calendar.item(id: calendarEventId) else {
            throw CalendarRegistrySyncError.operatorReview("calendar item missing during verification")
        }
        try assertRegistryMatchesManifest(record, request: request)
        try assertCalendarMatchesManifest(item, request: request, createInvocationId: expectedCreateInvocationId)
        guard record.createInvocationId == expectedCreateInvocationId,
              record.calendarProvider == item.provider,
              record.calendarEventId == item.localEventId,
              record.calendarId == item.calendarId,
              record.providerExternalId == item.providerExternalId else {
            throw CalendarRegistrySyncError.identityConflict("authoritative pair identity is not persisted consistently")
        }
        let registryLookup = try await registry.findBySyncKey(request.idempotencyKey)
        guard registryLookup.source == .live, registryLookup.unresolvedIdentities.isEmpty else {
            throw CalendarRegistrySyncError.identityConflict("final registry uniqueness lookup was degraded or undecodable")
        }
        guard registryLookup.records.count == 1, registryLookup.records.first?.id == record.id else {
            throw CalendarRegistrySyncError.ambiguousRegistryIdentity(registryLookup.records.map { $0.id })
        }
        let query = CalendarRecoveryQuery(
            localEventId: item.localEventId,
            providerExternalId: item.providerExternalId,
            syncKey: request.idempotencyKey,
            operationFingerprint: request.manifest.fingerprint,
            createInvocationId: expectedCreateInvocationId,
            calendarId: request.calendarId,
            title: request.title,
            start: request.start,
            end: request.end
        )
        let calendarMatches = try await calendar.recover(query)
        guard calendarMatches.count == 1, calendarMatches.first?.localEventId == item.localEventId else {
            throw CalendarRegistrySyncError.ambiguousCalendarIdentity(calendarMatches.map { $0.localEventId })
        }
        let recomputedHash = Self.syncFingerprint(record: record, item: item)
        if requireSyncedEvidence {
            guard record.syncState == .synced,
                  record.syncHash == recomputedHash,
                  let lastSyncedAt = record.lastSyncedAt,
                  record.syncWriterToken?.isEmpty == false,
                  record.syncRevision > 0 else {
                throw CalendarRegistrySyncError.identityConflict("final Notion read did not retain recomputed Synced evidence")
            }
            if let expectedSyncedAt,
               abs(lastSyncedAt.timeIntervalSince(expectedSyncedAt)) >= 1 {
                throw CalendarRegistrySyncError.identityConflict("Last Synced At does not match the verification transaction")
            }
        }
        return (
            record,
            item,
            recomputedHash,
            [
                "fresh Notion read confirmed EVENT \(record.id)",
                "provider read confirmed calendar event \(item.localEventId)",
                "canonical manifest, Create Invocation ID, and pair identity match",
                "authoritative Notion uniqueness and owned EventKit uniqueness within declared search scope passed"
            ],
            [Self.searchScopeDescription(query)]
        )
    }

    private func validate(_ request: RegistryFirstTimeInstanceRequest) throws {
        let pattern = #"^[A-Za-z0-9._:-]{1,128}$"#
        guard request.idempotencyKey.range(of: pattern, options: .regularExpression) != nil else {
            throw CalendarRegistrySyncError.invalidIdempotencyKey
        }
        guard !request.registryEventId.isEmpty else { throw CalendarRegistrySyncError.missingRegistryEventId }
        guard !request.title.isEmpty else {
            throw CalendarRegistrySyncError.identityConflict("title is empty after canonicalization")
        }
        guard request.end > request.start else { throw CalendarRegistrySyncError.invalidTimeRange }
        guard TimeZone(identifier: request.timeZoneIdentifier) != nil else {
            throw CalendarRegistrySyncError.invalidTimeZone(request.timeZoneIdentifier)
        }
        guard !request.calendarId.isEmpty else { throw CalendarRegistrySyncError.missingCalendarId }
        guard !request.semantics.primaryBlockId.isEmpty else { throw CalendarRegistrySyncError.missingPrimaryBlock }
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
        guard record.id == request.registryEventId else {
            throw CalendarRegistrySyncError.identityConflict("Notion page ID differs from the supplied EVENT")
        }
        guard record.syncKey == request.idempotencyKey else {
            throw CalendarRegistrySyncError.identityConflict("Notion Sync Key differs")
        }
        guard !record.operationFingerprint.isEmpty,
              record.operationFingerprint == fingerprint else {
            throw CalendarRegistrySyncError.identityConflict("Notion operation fingerprint differs or is missing")
        }
        guard record.schedulingAuthority == .registry else {
            throw CalendarRegistrySyncError.identityConflict("Notion Scheduling Authority is not Registry")
        }
        guard record.title == request.title,
              abs(record.scheduledStart.timeIntervalSince(request.start)) < 1,
              abs(record.scheduledEnd.timeIntervalSince(request.end)) < 1,
              record.timeZoneIdentifier == request.timeZoneIdentifier,
              record.location == request.location,
              record.notes == request.notes,
              record.semantics == request.semantics else {
            throw CalendarRegistrySyncError.identityConflict("Notion semantic state differs from the canonical manifest")
        }
        if let calendarId = record.calendarId, calendarId != request.calendarId {
            throw CalendarRegistrySyncError.identityConflict("Notion calendar ID differs from the canonical manifest")
        }
    }

    private func assertRegistryAdmissibleForPairing(
        _ record: TimeInstanceRecord,
        request: RegistryFirstTimeInstanceRequest,
        transaction: CalendarRegistryTransaction
    ) throws {
        let pairValues = [
            record.calendarProvider, record.calendarId, record.calendarEventId,
            record.providerExternalId, record.calendarItemURL
        ]
        let pairPresence = pairValues.map { $0?.isEmpty == false }
        let anyPairEvidence = pairPresence.contains(true)
        let completeCoreIdentity = pairPresence[0] && pairPresence[1] && pairPresence[2]
        let invocationPresent = record.createInvocationId?.isEmpty == false
        let writerEvidencePresent = record.syncWriterToken?.isEmpty == false && record.syncRevision > 0

        if let ledgerInvocation = transaction.createInvocationId,
           invocationPresent, record.createInvocationId != ledgerInvocation {
            throw CalendarRegistrySyncError.identityConflict("Notion and SQLite Create Invocation IDs differ")
        }
        if let ledgerEvent = transaction.calendarEventId,
           record.calendarEventId?.isEmpty == false, record.calendarEventId != ledgerEvent {
            throw CalendarRegistrySyncError.identityConflict("Notion and SQLite calendar event IDs differ")
        }

        switch transaction.stage {
        case .claimed:
            guard !invocationPresent, !writerEvidencePresent, !anyPairEvidence,
                  record.syncState == .pendingCreate,
                  record.syncHash.isEmpty, record.lastSyncedAt == nil,
                  record.calendarUpdatedAt == nil else {
                throw CalendarRegistrySyncError.identityConflict(
                    "initial EVENT is not a clean Pending Create registry-authority record"
                )
            }

        case .registryAuthorized:
            if invocationPresent {
                guard writerEvidencePresent, !anyPairEvidence,
                      record.createInvocationId == transaction.createInvocationId,
                      record.syncState == .pendingCreate,
                      record.syncHash.isEmpty, record.lastSyncedAt == nil else {
                    throw CalendarRegistrySyncError.identityConflict(
                        "registry-authorized EVENT contains inconsistent Create Invocation evidence"
                    )
                }
            } else {
                guard !writerEvidencePresent, !anyPairEvidence,
                      record.syncState == .pendingCreate,
                      record.syncHash.isEmpty, record.lastSyncedAt == nil,
                      record.calendarUpdatedAt == nil else {
                    throw CalendarRegistrySyncError.identityConflict(
                        "registry-authorized EVENT is not a clean Pending Create record"
                    )
                }
            }

        case .createInvocationPersisted, .calendarEffectUnknown:
            guard invocationPresent, writerEvidencePresent,
                  record.createInvocationId == transaction.createInvocationId,
                  !anyPairEvidence,
                  record.syncState == .pendingCreate,
                  record.syncHash.isEmpty, record.lastSyncedAt == nil else {
                throw CalendarRegistrySyncError.identityConflict(
                    "Create Invocation state is incomplete or contains premature pair evidence"
                )
            }

        case .calendarIdentified:
            guard invocationPresent, writerEvidencePresent,
                  record.createInvocationId == transaction.createInvocationId,
                  record.syncState == .pendingCreate else {
                throw CalendarRegistrySyncError.identityConflict("calendar-identified EVENT has inconsistent invocation evidence")
            }
            if anyPairEvidence && !completeCoreIdentity {
                throw CalendarRegistrySyncError.identityConflict("Notion EVENT contains a partial calendar identity")
            }

        case .pairIdentityPersisted:
            guard invocationPresent, writerEvidencePresent, completeCoreIdentity,
                  record.calendarId == request.calendarId,
                  record.syncState == .pendingCreate || record.syncState == .synced else {
                throw CalendarRegistrySyncError.identityConflict("pair-persisted EVENT is incomplete or contradictory")
            }
            if record.syncState == .pendingCreate {
                guard record.syncHash.isEmpty, record.lastSyncedAt == nil else {
                    throw CalendarRegistrySyncError.identityConflict("Pending Create EVENT contains final synchronization evidence")
                }
            } else {
                guard !record.syncHash.isEmpty, record.lastSyncedAt != nil else {
                    throw CalendarRegistrySyncError.identityConflict("Synced EVENT is missing final synchronization evidence")
                }
            }

        case .syncEvidencePersisted, .complete:
            guard invocationPresent, writerEvidencePresent, completeCoreIdentity,
                  record.calendarId == request.calendarId,
                  record.syncState == .synced,
                  !record.syncHash.isEmpty, record.lastSyncedAt != nil else {
                throw CalendarRegistrySyncError.identityConflict("final EVENT evidence is incomplete or contradictory")
            }

        case .conflict, .operatorReview, .abandoned:
            throw CalendarRegistrySyncError.identityConflict("terminal transaction is not admissible for automatic mutation")
        }
    }

    private func assertCalendarMatchesManifest(
        _ item: ExternalCalendarItem,
        request: RegistryFirstTimeInstanceRequest,
        createInvocationId: String? = nil
    ) throws {
        if item.isRecurring { throw CalendarRegistrySyncError.recurringEventUnsupported }
        if item.isAllDay { throw CalendarRegistrySyncError.allDayEventUnsupported }
        if item.isDetached { throw CalendarRegistrySyncError.detachedEventUnsupported }
        if item.organizer != nil || !item.attendees.isEmpty {
            throw CalendarRegistrySyncError.participantConsequencesUnsupported
        }
        guard item.syncKey == request.idempotencyKey,
              item.operationFingerprint == request.manifest.fingerprint,
              createInvocationId == nil || item.createInvocationId == createInvocationId else {
            throw CalendarRegistrySyncError.identityConflict("calendar metadata identity differs or is missing")
        }
        guard item.title == request.title,
              abs(item.start.timeIntervalSince(request.start)) < 1,
              abs(item.end.timeIntervalSince(request.end)) < 1,
              item.timeZoneIdentifier == request.timeZoneIdentifier,
              item.calendarId == request.calendarId,
              item.location == request.location,
              item.notes == request.notes else {
            throw CalendarRegistrySyncError.identityConflict("calendar state differs from the canonical manifest")
        }
    }

    private func applyIdentity(_ item: ExternalCalendarItem, to record: inout TimeInstanceRecord) throws {
        for (name, existing, candidate) in [
            ("calendar provider", record.calendarProvider, Optional(item.provider)),
            ("calendar id", record.calendarId, Optional(item.calendarId)),
            ("calendar event id", record.calendarEventId, Optional(item.localEventId)),
            ("provider external id", record.providerExternalId, item.providerExternalId)
        ] where existing?.isEmpty == false && candidate?.isEmpty == false && existing != candidate {
            throw CalendarRegistrySyncError.identityConflict("Notion \(name) is immutable once established")
        }
        record.calendarProvider = record.calendarProvider ?? item.provider
        record.calendarId = record.calendarId ?? item.calendarId
        record.calendarEventId = record.calendarEventId ?? item.localEventId
        record.providerExternalId = record.providerExternalId ?? item.providerExternalId
        record.calendarItemURL = item.itemURL
        record.calendarUpdatedAt = item.updatedAt
    }

    private static func isConflict(_ error: Error) -> Bool {
        if let sync = error as? CalendarRegistrySyncError {
            switch sync {
            case .ambiguousRegistryIdentity, .undecodableRegistryIdentity,
                 .ambiguousCalendarIdentity, .identityConflict,
                 .recurringEventUnsupported, .allDayEventUnsupported,
                 .detachedEventUnsupported, .participantConsequencesUnsupported:
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
            record.operationFingerprint,
            record.syncKey,
            item.provider,
            item.calendarId,
            item.localEventId,
            item.providerExternalId ?? ""
        ].joined(separator: "\u{1F}")
        return CalendarRegistryDigest.sha256(canonical)
    }

    private static func recoveryAction(
        for stage: CalendarRegistryTransactionStage,
        persisted: Bool
    ) -> String {
        guard persisted else {
            return "do not retry automatically; inspect Notion, EventKit, and the local coordinator"
        }
        switch stage {
        case .createInvocationPersisted, .calendarEffectUnknown:
            return "recovery only: inspect EventKit by Bridge identity; automatic recreation is prohibited"
        case .conflict:
            return "resolve the recorded identity discrepancy; automatic retry is prohibited"
        case .operatorReview:
            return "operator review is required; automatic create, repair, and retry are prohibited"
        case .abandoned:
            return "explicit operator decision is required before any further action"
        case .claimed:
            return "retry with the same idempotency key after the process lock is released"
        case .complete:
            return "pair is verified; inspect coordinator release state before retrying"
        default:
            return "retry with the same idempotency key after the process lock is released"
        }
    }

    private static func processLockFailureReceipt(
        request: RegistryFirstTimeInstanceRequest,
        error: CalendarRegistryProcessLockError
    ) -> CalendarRegistrySyncReceipt {
        let active: Bool
        if case .operationActive = error { active = true } else { active = false }
        return CalendarRegistrySyncReceipt(
            succeeded: false,
            infrastructureFault: !active,
            recoveryStatePersisted: false,
            registryFailureStatePersisted: false,
            operationId: "",
            idempotencyKey: request.idempotencyKey,
            operationFingerprint: request.manifest.fingerprint,
            fencingToken: nil,
            ledgerRevision: nil,
            verifiedSyncHash: nil,
            verifiedAt: nil,
            stageBefore: .claimed,
            stageAfter: .claimed,
            record: nil,
            calendarItem: nil,
            registryFieldsWritten: [],
            calendarFieldsWritten: [],
            verificationEvidence: [],
            partialEffects: [],
            recoveryAction: active
                ? "another process owns this operation; retry only after that process exits"
                : "inspect the canonical process-lock directory before retrying",
            discrepancy: error.localizedDescription
        )
    }

    private static func storeFailureReceipt(
        request: RegistryFirstTimeInstanceRequest,
        storeError: CalendarRegistryTransactionStoreError,
        existing: CalendarRegistryTransaction?,
        processReleaseError: Error?
    ) -> CalendarRegistrySyncReceipt {
        let conflict: Bool
        let active: Bool
        switch storeError {
        case .idempotencyConflict: conflict = true; active = false
        case .operationActive: conflict = false; active = true
        default: conflict = false; active = false
        }
        let stage = conflict ? CalendarRegistryTransactionStage.conflict : (existing?.stage ?? .claimed)
        return CalendarRegistrySyncReceipt(
            succeeded: false,
            infrastructureFault: (!conflict && !active) || processReleaseError != nil,
            recoveryStatePersisted: existing != nil,
            registryFailureStatePersisted: false,
            operationId: existing?.operationId ?? "",
            idempotencyKey: request.idempotencyKey,
            operationFingerprint: request.manifest.fingerprint,
            fencingToken: nil,
            ledgerRevision: existing?.revision,
            verifiedSyncHash: nil,
            verifiedAt: nil,
            stageBefore: existing?.stage ?? .claimed,
            stageAfter: stage,
            record: nil,
            calendarItem: nil,
            registryFieldsWritten: [],
            calendarFieldsWritten: [],
            verificationEvidence: [],
            partialEffects: existing?.partialEffects ?? [],
            recoveryAction: active
                ? "another SQLite owner is recorded; inspect the process lock and coordinator"
                : recoveryAction(for: stage, persisted: existing != nil),
            discrepancy: [storeError.localizedDescription, processReleaseError?.localizedDescription]
                .compactMap { $0 }.joined(separator: " | ")
        )
    }

    private static let pairingFieldNames = [
        "calendarProvider", "calendarId", "calendarEventId", "providerExternalId",
        "calendarUrl", "calendarUpdatedAt", "syncState", "lastSyncError"
    ]
}

private extension Result where Success == Void, Failure == Error {
    var failure: Error? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

// MARK: - Versioned calendar metadata

public enum CalendarRegistryCalendarMetadata {
    public static let beginMarker = "--- BRIDGE-CALENDAR-REGISTRY v2 ---"
    public static let endMarker = "--- END BRIDGE-CALENDAR-REGISTRY ---"

    public struct Identity: Sendable, Equatable {
        public var syncKey: String
        public var operationFingerprint: String
        public var createInvocationId: String

        public init(syncKey: String, operationFingerprint: String, createInvocationId: String) {
            self.syncKey = syncKey
            self.operationFingerprint = operationFingerprint
            self.createInvocationId = createInvocationId
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
            "Create-Invocation-ID: \(identity.createInvocationId)",
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
        var createInvocationId: String?
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
            } else if line.hasPrefix("Create-Invocation-ID:") {
                guard createInvocationId == nil else {
                    throw CalendarRegistrySyncError.identityConflict("calendar contains duplicate Create Invocation ID metadata")
                }
                createInvocationId = String(line.dropFirst("Create-Invocation-ID:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        let keyPattern = #"^[A-Za-z0-9._:-]{1,128}$"#
        let hexPattern = #"^[0-9a-f]{64}$"#
        guard let syncKey, let fingerprint, let createInvocationId,
              syncKey.range(of: keyPattern, options: .regularExpression) != nil,
              fingerprint.range(of: hexPattern, options: .regularExpression) != nil,
              createInvocationId.range(of: keyPattern, options: .regularExpression) != nil else {
            throw CalendarRegistrySyncError.identityConflict("calendar Bridge metadata is incomplete or invalid")
        }
        return Identity(syncKey: syncKey, operationFingerprint: fingerprint, createInvocationId: createInvocationId)
    }
}

// MARK: - EventKit adapter

public actor CalendarStoringSyncProvider: CalendarSyncProviding {
    private let store: any CalendarStoring
    private let providerName: String
    private let allowlistedCalendarIds: Set<String>

    public init(
        store: any CalendarStoring,
        providerName: String = "Apple Calendar",
        allowlistedCalendarIds: Set<String>
    ) {
        self.store = store
        self.providerName = providerName
        self.allowlistedCalendarIds = allowlistedCalendarIds
    }

    public func qualify(calendarId: String) async throws -> CalendarQualification {
        guard let info = try await store.calendars().first(where: { $0.id == calendarId }) else {
            throw CalendarModuleError.calendarNotFound(calendarId)
        }
        let allowlisted = allowlistedCalendarIds.contains(calendarId)
        // Private smoke: allowlisted + writable + non-subscribed. Prefer On My Mac
        // (local) when present; many Macs only expose private CalDAV/iCloud calendars
        // with no EK local source — those remain admissible when explicitly allowlisted.
        let subscribedFamily =
            info.calendarType == "subscription"
            || info.calendarType == "birthday"
            || info.sourceType == "subscribed"
            || info.sourceType == "birthdays"
        let privateWritable = info.allowsModify && !subscribedFamily
        return CalendarQualification(
            calendarId: info.id,
            title: info.title,
            allowsModify: info.allowsModify,
            explicitlyAllowlisted: allowlisted,
            calendarType: info.calendarType,
            sourceType: info.sourceType,
            qualifiedForPrivateSmoke: allowlisted && privateWritable
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
                operationFingerprint: draft.operationFingerprint,
                createInvocationId: draft.createInvocationId
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
        var candidates: [String: ExternalCalendarItem] = [:]
        if let id = query.localEventId, let direct = try await item(id: id) {
            candidates[direct.localEventId] = direct
        }

        let lower = query.start.addingTimeInterval(-30 * 86_400)
        let upper = query.end.addingTimeInterval(30 * 86_400)
        let events = try await store.events(CalendarEventQuery(
            start: Self.iso(lower), end: Self.iso(upper), calendarId: nil
        ))
        var mapped: [ExternalCalendarItem] = []
        for event in events {
            do {
                mapped.append(try map(event))
            } catch {
                if Self.matchesTargetEvidence(event, query: query) {
                    throw CalendarRegistrySyncError.identityConflict(
                        "target-related calendar metadata is malformed for event \(event.id)"
                    )
                }
                continue
            }
        }

        for item in mapped {
            let identityMatch = item.syncKey == query.syncKey
                && item.operationFingerprint == query.operationFingerprint
            let invocationMatch = query.createInvocationId.map { item.createInvocationId == $0 } ?? false
            let externalMatch = query.providerExternalId.map { item.providerExternalId == $0 } ?? false
            let fallbackMatch = item.calendarId == query.calendarId
                && item.title.caseInsensitiveCompare(query.title) == .orderedSame
                && abs(item.start.timeIntervalSince(query.start)) < 1
                && abs(item.end.timeIntervalSince(query.end)) < 1
            if identityMatch || invocationMatch || externalMatch || fallbackMatch {
                candidates[item.localEventId] = item
            }
        }
        return candidates.values.sorted { $0.localEventId < $1.localEventId }
    }

    private static func matchesTargetEvidence(_ event: CalendarEvent, query: CalendarRecoveryQuery) -> Bool {
        if event.id == query.localEventId { return true }
        if let external = query.providerExternalId, event.externalId == external { return true }
        if malformedMetadataClaimsTarget(event.notes, query: query) { return true }
        guard event.calendarId == query.calendarId,
              event.title.caseInsensitiveCompare(query.title) == .orderedSame,
              let start = try? CalendarISOParsing.parse(event.start),
              let end = try? CalendarISOParsing.parse(event.end) else { return false }
        return abs(start.timeIntervalSince(query.start)) < 1 && abs(end.timeIntervalSince(query.end)) < 1
    }

    private static func malformedMetadataClaimsTarget(
        _ notes: String?,
        query: CalendarRecoveryQuery
    ) -> Bool {
        guard let notes,
              let begin = notes.range(of: CalendarRegistryCalendarMetadata.beginMarker) else {
            return false
        }
        let tail = notes[begin.upperBound...]
        let body: Substring
        if let end = tail.range(of: CalendarRegistryCalendarMetadata.endMarker) {
            body = tail[..<end.lowerBound]
        } else {
            body = tail
        }
        for rawLine in body.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("Sync-Key:") {
                let value = String(line.dropFirst("Sync-Key:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if value == query.syncKey { return true }
            }
            if line.hasPrefix("Operation-Fingerprint:") {
                let value = String(line.dropFirst("Operation-Fingerprint:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if value == query.operationFingerprint { return true }
            }
            if line.hasPrefix("Create-Invocation-ID:"), let expected = query.createInvocationId {
                let value = String(line.dropFirst("Create-Invocation-ID:".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if value == expected { return true }
            }
        }
        return false
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
            createInvocationId: metadata?.createInvocationId,
            title: event.title,
            start: start,
            end: end,
            timeZoneIdentifier: event.timeZoneIdentifier ?? "",
            location: event.location,
            notes: try CalendarRegistryCalendarMetadata.userNotes(from: event.notes),
            organizer: event.organizer,
            attendees: event.attendees,
            updatedAt: event.lastModified.flatMap { try? CalendarISOParsing.parse($0) },
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
                    let rawSyncKey: String?
                    if case .object(let properties) = cached.properties {
                        rawSyncKey = Self.string(properties["syncKey"])
                    } else {
                        rawSyncKey = nil
                    }
                    unresolved.append(RegistryUnresolvedIdentity(
                        pageId: row.id,
                        syncKey: rawSyncKey,
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

    public func readIdentity(id: String, forceRefresh: Bool) async throws -> RegistryRecordIdentityRead {
        let row: CachedRow
        do {
            row = try await reader.get(entity: entity, pageId: id, forceRefresh: forceRefresh)
        } catch let error as RegistryReader.RegistryReadError {
            if case .deleted = error { return .missing }
            throw error
        }
        if let decoded = Self.decode(row) { return .decoded(decoded) }
        guard case .object(let properties) = row.properties else {
            return .malformed(pageId: row.pageId, reason: "projected properties are not an object")
        }
        let syncKey = Self.string(properties["syncKey"])
        let fingerprint = Self.string(properties["operationFingerprint"])
        if syncKey != nil || fingerprint != nil {
            return .partial(pageId: row.pageId, syncKey: syncKey, operationFingerprint: fingerprint)
        }
        return .malformed(pageId: row.pageId, reason: "Sync Key and Operation Fingerprint are absent")
    }

    public func get(id: String, forceRefresh: Bool) async throws -> TimeInstanceRecord? {
        switch try await readIdentity(id: id, forceRefresh: forceRefresh) {
        case .decoded(let record): return record
        case .partial, .missing, .malformed: return nil
        }
    }

    package func create(_ record: TimeInstanceRecord) async throws -> TimeInstanceRecord {
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

    package func repair(id: String, from record: TimeInstanceRecord) async throws -> TimeInstanceRecord {
        var repair = record
        repair.id = id
        _ = try await writer.update(entity: entity, pageId: id, fields: fields(repair))
        guard let fresh = try await get(id: id, forceRefresh: true) else {
            throw CalendarRegistrySyncError.verificationFailed("repaired Notion EVENT could not be decoded")
        }
        return fresh
    }

    public func savePairing(
        _ record: TimeInstanceRecord,
        expectedRevision: String?
    ) async throws -> TimeInstanceRecord {
        guard let expectedRevision, !expectedRevision.isEmpty else {
            throw CalendarRegistrySyncError.identityConflict("Notion revision evidence is missing before pairing write")
        }
        switch try await readIdentity(id: record.id, forceRefresh: true) {
        case .decoded(let current):
            guard current.registryRevision == expectedRevision else {
                throw CalendarRegistrySyncError.identityConflict("Notion EVENT changed concurrently before pairing write")
            }
        case .partial:
            throw CalendarRegistrySyncError.identityConflict("Notion EVENT became partial before pairing write")
        case .missing:
            throw CalendarRegistrySyncError.identityConflict("Notion EVENT disappeared before pairing write")
        case .malformed(_, let reason):
            throw CalendarRegistrySyncError.identityConflict("Notion EVENT became malformed before pairing write: \(reason)")
        }
        _ = try await writer.update(entity: entity, pageId: record.id, fields: pairingFields(record))
        guard let fresh = try await get(id: record.id, forceRefresh: true) else {
            throw CalendarRegistrySyncError.verificationFailed("updated Notion EVENT could not be read back")
        }
        guard fresh.createInvocationId == record.createInvocationId,
              fresh.syncWriterToken == record.syncWriterToken,
              fresh.syncRevision == record.syncRevision else {
            throw CalendarRegistrySyncError.identityConflict("Notion pairing PATCH lost writer fencing evidence")
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

    private func pairingFields(_ record: TimeInstanceRecord) -> [String: Value] {
        [
            "calendarProvider": Self.nullable(record.calendarProvider),
            "calendarId": Self.nullable(record.calendarId),
            "calendarEventId": Self.nullable(record.calendarEventId),
            "providerExternalId": Self.nullable(record.providerExternalId),
            "calendarUrl": Self.nullable(record.calendarItemURL),
            "createInvocationId": Self.nullable(record.createInvocationId),
            "syncWriterToken": Self.nullable(record.syncWriterToken),
            "syncRevision": .double(Double(record.syncRevision)),
            "syncState": .string(record.syncState.rawValue),
            "registryUpdatedAt": .string(CalendarRegistryISO.string(record.registryUpdatedAt)),
            "syncHash": .string(record.syncHash),
            "lastSyncError": Self.nullable(record.lastSyncError),
            "lastSyncedAt": Self.nullableDate(record.lastSyncedAt),
            "calendarUpdatedAt": Self.nullableDate(record.calendarUpdatedAt)
        ]
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
            "createInvocationId": Self.nullable(record.createInvocationId),
            "syncWriterToken": Self.nullable(record.syncWriterToken),
            "syncRevision": .double(Double(record.syncRevision)),
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
              let registryRevisionDate = CalendarRegistryISO.date(row.lastEditedTime),
              let range = dateRange(properties["date"]),
              TimeZone(identifier: range.timeZone) != nil,
              let syncKey = string(properties["syncKey"]),
              let fingerprint = string(properties["operationFingerprint"]),
              let primaryBlock = strings(properties["primaryBlock"]).first,
              let eventClassRaw = string(properties["eventClass"]),
              let eventClass = TimeInstanceEventClass(rawValue: eventClassRaw),
              let authorityRaw = string(properties["schedulingAuthority"]),
              let authority = TimeInstanceSchedulingAuthority(rawValue: authorityRaw),
              let stateRaw = string(properties["syncState"]),
              let state = TimeInstanceSyncState(rawValue: stateRaw),
              let syncRevision = integer(properties["syncRevision"]), syncRevision >= 0 else { return nil }
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
            createInvocationId: string(properties["createInvocationId"]),
            syncWriterToken: string(properties["syncWriterToken"]),
            syncRevision: syncRevision,
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
                ?? registryRevisionDate,
            calendarUpdatedAt: date(properties["calendarUpdatedAt"]),
            syncHash: string(properties["syncHash"]) ?? "",
            lastSyncError: string(properties["lastSyncError"]),
            registryRevision: row.lastEditedTime
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

    private static func integer(_ value: Value?) -> Int? {
        if case .double(let number)? = value, number.isFinite, number >= 0, number.rounded() == number {
            return Int(number)
        }
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
        "lastSyncError", "scheduledDuration", "calendarLocation",
        "createInvocationId", "syncWriterToken", "syncRevision"
    ]
}
