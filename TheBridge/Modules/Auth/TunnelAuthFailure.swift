// TunnelAuthFailure.swift — W2A coarse tunnel auth failures + local diagnosis
// TheBridge · Modules · Auth

import Foundation

/// Stable, machine-readable reasons retained only on the operator's Mac.
/// Tunnel callers never receive these values; they see `auth_failed` plus a
/// correlation id that can be resolved through the local diagnostic audit.
public enum TunnelAuthFailureReason: String, Sendable, Equatable, CaseIterable {
    case oauthExpired = "oauth_expired"
    case issuerMismatch = "issuer_mismatch"
    case oauthInactive = "oauth_inactive"
    case oauthRevoked = "oauth_revoked"
    case staticBearerMismatch = "static_bearer_mismatch"

    public init(_ error: BearerValidationError) {
        switch error {
        case .expired:
            self = .oauthExpired
        case .issuerMismatch, .audienceMismatch:
            self = .issuerMismatch
        case .misconfigured:
            self = .oauthInactive
        case .missingBearer, .malformedAuthorizationHeader, .signatureInvalid,
             .notYetValid, .subjectMissing, .malformedToken:
            self = .oauthRevoked
        }
    }
}

public struct TunnelAuthFailureRecord: Sendable, Equatable {
    public let correlationID: String
    public let reason: TunnelAuthFailureReason
    public let recordedAt: Date
}

/// Process-local, capped audit that joins a coarse tunnel response to its
/// detailed reason. Synchronous by design: the MCP SDK's HTTP validators are
/// synchronous, so the legacy static-bearer gate must be able to record before
/// returning its response. NSLock protects all mutable state.
public final class TunnelAuthFailureAudit: @unchecked Sendable {
    public static let shared = TunnelAuthFailureAudit()

    private let lock = NSLock()
    private let cap: Int
    private var records: [TunnelAuthFailureRecord] = []

    public init(cap: Int = 256) {
        self.cap = max(8, cap)
    }

    @discardableResult
    public func record(
        _ reason: TunnelAuthFailureReason,
        correlationID: String = UUID().uuidString.lowercased(),
        at date: Date = Date()
    ) -> String {
        lock.withLock {
            records.append(TunnelAuthFailureRecord(
                correlationID: correlationID,
                reason: reason,
                recordedAt: date
            ))
            if records.count > cap {
                records.removeFirst(records.count - cap)
            }
        }
        return correlationID
    }

    public func recent(limit: Int = 20) -> [TunnelAuthFailureRecord] {
        lock.withLock { Array(records.suffix(max(1, min(limit, cap))).reversed()) }
    }

    public func record(correlationID: String) -> TunnelAuthFailureRecord? {
        lock.withLock { records.last { $0.correlationID == correlationID } }
    }

    public func clear() {
        lock.withLock { records.removeAll(keepingCapacity: true) }
    }
}
