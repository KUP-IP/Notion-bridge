import Foundation

public enum DialedTransport: String, Sendable, Codable {
    case local
    case tunnel
}

public enum ConnectionRuntimeEventKind: String, Sendable, Codable {
    case accept
    case reconnect
    case reset
    case disconnect
}

public struct ConnectionRuntimeEvent: Sendable, Codable, Equatable {
    public let kind: ConnectionRuntimeEventKind
    public let origin: ToolDispatchOrigin
    public let transportSessionId: String
    public let dialedTransport: DialedTransport
    public let clientName: String?
    public let timestamp: Date
}

public struct ConnectionSessionObservation: Sendable, Codable, Equatable {
    public let transportSessionId: String
    public let origin: ToolDispatchOrigin
    public let dialedTransport: DialedTransport
    public let clientName: String?
    public let acceptedAt: Date
    public let authMode: String
    public let tokenExpiresAt: Date?
    public let lastRefreshOutcome: String
    public let governed: Bool

    public func tokenAgeSeconds(now: Date = Date()) -> Int? {
        guard authMode == "oauth" else { return nil }
        return max(0, Int(now.timeIntervalSince(acceptedAt)))
    }
}

public struct ConnectionRuntimeSnapshot: Sendable, Equatable {
    public let authMode: String
    public let sessions: [ConnectionSessionObservation]
    public let recentEvents: [ConnectionRuntimeEvent]
}

/// Redacted, in-memory connection diagnostics. It stores only derived metadata:
/// origin, transport identity, client label, timestamps, auth mode and expiry.
/// Raw Authorization headers, bearer/JWT bodies and refresh tokens have no field
/// in this model and therefore cannot leak through `connections_list` or Settings.
public actor ConnectionRuntimeObservability {
    public static let shared = ConnectionRuntimeObservability()

    private struct MutableSession: Sendable {
        var transportSessionId: String
        var origin: ToolDispatchOrigin
        var dialedTransport: DialedTransport
        var clientName: String?
        var acceptedAt: Date
        var authMode: String
        var tokenExpiresAt: Date?
        var lastRefreshOutcome: String
    }

    private var configuredAuthMode = "inactive"
    private var sessions: [String: MutableSession] = [:]
    private var events: [ConnectionRuntimeEvent] = []
    private let eventLimit: Int

    public init(eventLimit: Int = 100) {
        self.eventLimit = max(10, eventLimit)
    }

    public func configure(authMode: String) {
        configuredAuthMode = authMode
    }

    public func recordAccept(
        transportSessionId: String,
        origin: ToolDispatchOrigin,
        clientName: String?,
        authMode: String,
        tokenExpiresAt: Date?,
        at timestamp: Date = Date()
    ) {
        let dialed: DialedTransport = origin == .remote ? .tunnel : .local
        sessions[transportSessionId] = MutableSession(
            transportSessionId: transportSessionId,
            origin: origin,
            dialedTransport: dialed,
            clientName: clientName,
            acceptedAt: timestamp,
            authMode: authMode,
            tokenExpiresAt: tokenExpiresAt,
            lastRefreshOutcome: authMode == "oauth" ? "client_managed_not_observed" : "not_applicable"
        )
        append(.init(
            kind: .accept,
            origin: origin,
            transportSessionId: transportSessionId,
            dialedTransport: dialed,
            clientName: clientName,
            timestamp: timestamp
        ))
        let clientLabel = clientName ?? "unknown"
        print("[Connection] accept origin=\(origin.rawValue) dialedTransport=\(dialed.rawValue) transportSessionId=\(transportSessionId) client=\(clientLabel) ts=\(Self.iso(timestamp))")
    }

    public func recordReconnect(
        transportSessionId: String,
        origin: ToolDispatchOrigin,
        clientName: String?,
        at timestamp: Date = Date()
    ) {
        let dialed: DialedTransport = origin == .remote ? .tunnel : .local
        append(.init(kind: .reconnect, origin: origin, transportSessionId: transportSessionId,
                     dialedTransport: dialed, clientName: clientName, timestamp: timestamp))
        let clientLabel = clientName ?? "unknown"
        print("[Connection] reconnect origin=\(origin.rawValue) dialedTransport=\(dialed.rawValue) transportSessionId=\(transportSessionId) client=\(clientLabel) ts=\(Self.iso(timestamp))")
    }

    public func recordReset(
        transportSessionId: String,
        clientName: String?,
        at timestamp: Date = Date()
    ) {
        append(.init(kind: .reset, origin: .local, transportSessionId: transportSessionId,
                     dialedTransport: .local, clientName: clientName, timestamp: timestamp))
        let clientLabel = clientName ?? "unknown"
        print("[Connection] reset origin=local dialedTransport=local transportSessionId=\(transportSessionId) client=\(clientLabel) ts=\(Self.iso(timestamp))")
    }

    public func recordDisconnect(transportSessionId: String, at timestamp: Date = Date()) {
        guard let session = sessions.removeValue(forKey: transportSessionId) else { return }
        append(.init(kind: .disconnect, origin: session.origin,
                     transportSessionId: transportSessionId,
                     dialedTransport: session.dialedTransport,
                     clientName: session.clientName, timestamp: timestamp))
    }

    public func snapshot(
        sessionRegistry: SessionRegistry = .shared,
        eventLimit requestedLimit: Int = 20
    ) async -> ConnectionRuntimeSnapshot {
        // Snapshot every actor-owned collection/value before the first await.
        // SessionRegistry lookups yield this actor, so iterating `sessions.values`
        // directly across those suspension points would let accept/disconnect
        // calls re-enter and produce a mixed or mutating traversal.
        let stableSessions = Array(sessions.values)
        let stableAuthMode = configuredAuthMode
        let limit = max(1, min(requestedLimit, eventLimit))
        let stableEvents = Array(events.suffix(limit).reversed())

        var observations: [ConnectionSessionObservation] = []
        for session in stableSessions {
            let governed = (try? await sessionRegistry.isGoverned(
                transportSessionId: session.transportSessionId
            )) == true
            observations.append(.init(
                transportSessionId: session.transportSessionId,
                origin: session.origin,
                dialedTransport: session.dialedTransport,
                clientName: session.clientName,
                acceptedAt: session.acceptedAt,
                authMode: session.authMode,
                tokenExpiresAt: session.tokenExpiresAt,
                lastRefreshOutcome: session.lastRefreshOutcome,
                governed: governed
            ))
        }
        observations.sort { $0.acceptedAt > $1.acceptedAt }
        return ConnectionRuntimeSnapshot(
            authMode: stableAuthMode,
            sessions: observations,
            recentEvents: stableEvents
        )
    }

    public func resetForTesting() {
        configuredAuthMode = "inactive"
        sessions.removeAll()
        events.removeAll()
    }

    private func append(_ event: ConnectionRuntimeEvent) {
        events.append(event)
        if events.count > eventLimit { events.removeFirst(events.count - eventLimit) }
    }

    private nonisolated static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

public struct ConnectionResetReceipt: Sendable, Equatable {
    public let transportSessionId: String
    public let previousBrokerSessionId: String?
    public let brokerSessionId: String
    public let governed: Bool
    public let idempotent: Bool
}

/// Narrow W2B seam: rotate the broker-governance record for an already-local
/// transport and run the same canonical initialization service that normally
/// marks a session governed. The HTTP stream stays alive long enough to return
/// the reset receipt; third-party URL selection/re-dial remains client-owned.
public actor ConnectionSessionResetService {
    public static let shared = ConnectionSessionResetService()

    private let sessionRegistry: SessionRegistry
    private let observability: ConnectionRuntimeObservability
    private let receiptStore: HandshakeReceiptStore

    public init(
        sessionRegistry: SessionRegistry = .shared,
        observability: ConnectionRuntimeObservability = .shared,
        receiptStore: HandshakeReceiptStore = .shared
    ) {
        self.sessionRegistry = sessionRegistry
        self.observability = observability
        self.receiptStore = receiptStore
    }

    public func reset(context: ToolDispatchContext) async throws -> ConnectionResetReceipt {
        guard context.origin == .local else {
            throw ConnectionResetError.remoteBlocked
        }
        let transportSessionId = context.transportSessionId ?? ServerManager.stdioSessionID
        let previous = try await sessionRegistry.current(transportSessionId: transportSessionId)
        // Do not close the governed row before replacement. SessionRegistry.open
        // uses ON CONFLICT to atomically upsert this transport id when canonical
        // initialization runs below, preserving governance continuously even if
        // receipt assembly yields or fails before the replacement write.
        let now = Date()
        let receipt = await ToolDispatchContext.$current.withValue(context) {
            await BridgeInitializeService.run(
                context: BridgeInitializeContext(
                    client: context.client ?? previous?.client,
                    connectionState: "local",
                    macToolsAvailable: true,
                    bridgeState: "running",
                    now: now
                ),
                mode: previous?.mode ?? .general,
                includeConstitution: false,
                sessionRegistry: sessionRegistry,
                receiptStore: receiptStore
            )
        }
        guard let session = receipt.session, session.governed else {
            throw ConnectionResetError.rebindFailed
        }
        await observability.recordReset(
            transportSessionId: transportSessionId,
            clientName: context.client ?? previous?.client,
            at: now
        )
        return .init(
            transportSessionId: transportSessionId,
            previousBrokerSessionId: previous?.sessionId,
            brokerSessionId: session.sessionId,
            governed: session.governed,
            idempotent: true
        )
    }
}

public enum ConnectionResetError: Error, LocalizedError {
    case remoteBlocked
    case rebindFailed

    public var errorDescription: String? {
        switch self {
        case .remoteBlocked: return "control_plane_remote_blocked"
        case .rebindFailed: return "Local session governance rebind failed"
        }
    }
}
