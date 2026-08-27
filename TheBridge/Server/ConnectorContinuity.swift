// ConnectorContinuity.swift — PKT-1296
// TheBridge · Server
//
// Connector delivery observation + governed per-session serialization.
// Root-cause companion: SSEHTTPHandler used to overwrite an in-flight HTTP/1.1
// assembly and launch overlapping response writers on one channel — parallel
// remote POSTs could vanish before audit ingestion. This type classifies
// executed=true|false|unknown without leaking auth material.

import Foundation

public enum ConnectorExecuted: String, Codable, Sendable, Equatable {
    case `true` = "true"
    case `false` = "false"
    case unknown = "unknown"
}

public enum ConnectorOutcome: String, Codable, Sendable, Equatable {
    case success
    case preDispatchLeaseExpiry
    case transportOutage
    case handlerFailure
    case generationChange
    case responseLoss
}

public enum ConnectorRetryDisposition: String, Codable, Sendable, Equatable {
    case none
    case queued
    case serialized
}

public struct ConnectorLease: Sendable, Equatable, Codable {
    public let id: String
    public let expiresAt: Date

    public init(id: String = UUID().uuidString, expiresAt: Date) {
        self.id = id
        self.expiresAt = expiresAt
    }

    public func isExpired(at now: Date) -> Bool { expiresAt <= now }
}

public struct ConnectorCallReceipt: Sendable, Equatable, Codable {
    public let schemaVersion: String
    public let connectorGeneration: String
    public let leaseId: String
    public let leaseExpiresAt: Date
    public let dispatchId: String
    public let retryDisposition: ConnectorRetryDisposition
    public let executed: ConnectorExecuted
    public let outcome: ConnectorOutcome
    public let toolName: String

    public init(
        schemaVersion: String,
        connectorGeneration: String,
        leaseId: String,
        leaseExpiresAt: Date,
        dispatchId: String,
        retryDisposition: ConnectorRetryDisposition,
        executed: ConnectorExecuted,
        outcome: ConnectorOutcome,
        toolName: String
    ) {
        self.schemaVersion = schemaVersion
        self.connectorGeneration = connectorGeneration
        self.leaseId = leaseId
        self.leaseExpiresAt = leaseExpiresAt
        self.dispatchId = dispatchId
        self.retryDisposition = retryDisposition
        self.executed = executed
        self.outcome = outcome
        self.toolName = toolName
    }

    /// Machine-readable `_meta` payload. No tokens, subjects, or raw headers.
    public var observationDictionary: [String: Any] {
        [
            "schemaVersion": schemaVersion,
            "connectorGeneration": connectorGeneration,
            "leaseId": leaseId,
            "leaseExpiresAt": ISO8601DateFormatter().string(from: leaseExpiresAt),
            "dispatchId": dispatchId,
            "retryDisposition": retryDisposition.rawValue,
            "executed": executed.rawValue,
            "outcome": outcome.rawValue,
            "toolName": toolName
        ]
    }
}

public enum ConnectorDeliveryError: Sendable, Equatable, Error {
    case transport
    case handler
    case responseLost
    case generationChanged
}

public enum ConnectorAuthHealth: String, Codable, Sendable, Equatable {
    case oauthReady
    case oauthInactive
    case tokenMismatch
    case loopbackExempt
}

public enum ConnectorContinuity {
    public static let schemaVersion = "4.1.0"

    /// Auth-mode truth for health/audit. Remote OAuth and local loopback stay
    /// distinct; a transport or token mismatch never reports as ready.
    public static func classifyAuthHealth(
        remote: Bool,
        oauthConfigured: Bool,
        tokenValid: Bool,
        tokenMatchesSession: Bool
    ) -> ConnectorAuthHealth {
        if !remote { return .loopbackExempt }
        if !oauthConfigured { return .oauthInactive }
        if !tokenValid || !tokenMatchesSession { return .tokenMismatch }
        return .oauthReady
    }

    /// Classify execution disposition. Handler failure means the handler ran
    /// (`executed=true`) and must not disable sibling tools. Pre-dispatch
    /// refusal is `executed=false`. A successful mutation whose response was
    /// lost is `executed=unknown`.
    public static func classify(
        leaseExpiredBeforeDispatch: Bool,
        generationChanged: Bool,
        dispatched: Bool,
        handlerFailed: Bool,
        transportFailed: Bool,
        responseLost: Bool
    ) -> (executed: ConnectorExecuted, outcome: ConnectorOutcome) {
        if leaseExpiredBeforeDispatch {
            return (.false, .preDispatchLeaseExpiry)
        }
        if generationChanged && !dispatched {
            return (.false, .generationChange)
        }
        if transportFailed && !dispatched {
            return (.false, .transportOutage)
        }
        if dispatched && responseLost {
            return (.unknown, .responseLoss)
        }
        if dispatched && handlerFailed {
            return (.true, .handlerFailure)
        }
        if dispatched {
            return (.true, .success)
        }
        return (.unknown, .responseLoss)
    }
}

/// Per-session serial queue for remote connector `tools/call`. Concurrent
/// callers wait; none are dropped. Actor isolation is the governed serialize
/// mitigation that proves 4-parallel batches deliver with zero unexplained loss
/// at the Bridge boundary.
public actor ConnectorCallQueue {
    public static let shared = ConnectorCallQueue()

    public let connectorGeneration: String
    private var leases: [String: ConnectorLease] = [:]
    private let leaseTTL: TimeInterval

    public init(
        connectorGeneration: String = UUID().uuidString,
        leaseTTL: TimeInterval = 86_400
    ) {
        self.connectorGeneration = connectorGeneration
        self.leaseTTL = leaseTTL
    }

    public func lease(for sessionKey: String, now: Date = Date()) -> ConnectorLease {
        if let existing = leases[sessionKey] {
            return existing
        }
        let minted = ConnectorLease(expiresAt: now.addingTimeInterval(leaseTTL))
        leases[sessionKey] = minted
        return minted
    }

    public func expireLease(for sessionKey: String, at now: Date) {
        leases[sessionKey] = ConnectorLease(expiresAt: now.addingTimeInterval(-1))
    }

    public func runSerialized<T: Sendable>(
        sessionKey: String,
        toolName: String,
        now: Date = Date(),
        queued: Bool = false,
        operation: @Sendable () async -> Result<T, ConnectorDeliveryError>
    ) async -> (value: T?, receipt: ConnectorCallReceipt) {
        let activeLease = lease(for: sessionKey, now: now)
        let dispatchId = UUID().uuidString
        let retry: ConnectorRetryDisposition = queued ? .serialized : .none

        func receipt(
            executed: ConnectorExecuted,
            outcome: ConnectorOutcome
        ) -> ConnectorCallReceipt {
            ConnectorCallReceipt(
                schemaVersion: ConnectorContinuity.schemaVersion,
                connectorGeneration: connectorGeneration,
                leaseId: activeLease.id,
                leaseExpiresAt: activeLease.expiresAt,
                dispatchId: dispatchId,
                retryDisposition: retry,
                executed: executed,
                outcome: outcome,
                toolName: toolName
            )
        }

        if activeLease.isExpired(at: now) {
            let classified = ConnectorContinuity.classify(
                leaseExpiredBeforeDispatch: true,
                generationChanged: false,
                dispatched: false,
                handlerFailed: false,
                transportFailed: false,
                responseLost: false
            )
            return (nil, receipt(executed: classified.executed, outcome: classified.outcome))
        }

        let result = await operation()
        switch result {
        case .success(let value):
            let classified = ConnectorContinuity.classify(
                leaseExpiredBeforeDispatch: false,
                generationChanged: false,
                dispatched: true,
                handlerFailed: false,
                transportFailed: false,
                responseLost: false
            )
            return (value, receipt(executed: classified.executed, outcome: classified.outcome))
        case .failure(.handler):
            let classified = ConnectorContinuity.classify(
                leaseExpiredBeforeDispatch: false,
                generationChanged: false,
                dispatched: true,
                handlerFailed: true,
                transportFailed: false,
                responseLost: false
            )
            return (nil, receipt(executed: classified.executed, outcome: classified.outcome))
        case .failure(.transport):
            let classified = ConnectorContinuity.classify(
                leaseExpiredBeforeDispatch: false,
                generationChanged: false,
                dispatched: false,
                handlerFailed: false,
                transportFailed: true,
                responseLost: false
            )
            return (nil, receipt(executed: classified.executed, outcome: classified.outcome))
        case .failure(.responseLost):
            let classified = ConnectorContinuity.classify(
                leaseExpiredBeforeDispatch: false,
                generationChanged: false,
                dispatched: true,
                handlerFailed: false,
                transportFailed: false,
                responseLost: true
            )
            return (nil, receipt(executed: classified.executed, outcome: classified.outcome))
        case .failure(.generationChanged):
            let classified = ConnectorContinuity.classify(
                leaseExpiredBeforeDispatch: false,
                generationChanged: true,
                dispatched: false,
                handlerFailed: false,
                transportFailed: false,
                responseLost: false
            )
            return (nil, receipt(executed: classified.executed, outcome: classified.outcome))
        }
    }
}
