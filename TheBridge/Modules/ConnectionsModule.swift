import Foundation
import MCP

public enum ConnectionsModule {
    public static let moduleName = "connections"

    public static func register(
        on router: ToolRouter,
        observability: ConnectionRuntimeObservability = .shared,
        resetService: ConnectionSessionResetService = .shared
    ) async {
        await router.register(ToolRegistration(
            name: "connections_list",
            module: moduleName,
            tier: .open,
            description: "List all bridge connections across kinds (workspace, api, remote_access). Filterable by kind or provider.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "provider": .object([
                        "type": .string("string"),
                        "description": .string("Optional provider filter: notion, stripe, tunnel")
                    ]),
                    "kind": .object([
                        "type": .string("string"),
                        "description": .string("Optional kind filter: workspace, api, remote_access")
                    ])
                ])
            ]),
            handler: { arguments in
                let (provider, kind) = parseConnectionFilters(arguments)
                let connections = try await ConnectionRegistry.shared.listConnections(
                    provider: provider,
                    kind: kind,
                    validateLive: true
                )
                let runtime = await observability.snapshot()
                return .object([
                    "count": .int(connections.count),
                    "connections": .array(connections.map(connectionValue)),
                    "runtime": runtimeValue(runtime)
                ])
            }
        ))

        await router.register(ToolRegistration(
            name: "connections_get",
            module: moduleName,
            tier: .open,
            description: "Fetch one bridge connection's full record by ID (kind, provider, status, config).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "connectionId": .object([
                        "type": .string("string"),
                        "description": .string("Connection id like notion:<name> or stripe:default. The symbolic alias notion:primary resolves to the live primary Notion workspace (rename-safe).")
                    ])
                ]),
                "required": .array([.string("connectionId")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let connectionId) = args["connectionId"] else {
                    throw ToolRouterError.invalidArguments(toolName: "connections_get", reason: "missing 'connectionId'")
                }
                let connection = try await ConnectionRegistry.shared.getConnection(id: connectionId, validateLive: true)
                return connectionValue(connection)
            }
        ))

        await router.register(ToolRegistration(
            name: "connections_health",
            module: moduleName,
            tier: .open,
            description: "Cached health check for one or all bridge connections. Fast; doesn't hit the live service — use connections_validate for that.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "connectionId": .object([
                        "type": .string("string"),
                        "description": .string("Optional connection id")
                    ])
                ])
            ]),
            handler: { arguments in
                // Cached per the tool description above — validateLive:false reads
                // last-known status (ConnectionHealthChecker's cache), no network
                // round-trip. connections_validate is the live counterpart.
                if case .object(let args) = arguments,
                   case .string(let connectionId) = args["connectionId"] {
                    let connection = try await ConnectionRegistry.shared.getConnection(id: connectionId, validateLive: false)
                    return .object([
                        "id": .string(connection.id),
                        "provider": .string(connection.provider.rawValue),
                        "status": .string(connection.status.rawValue),
                        "lastValidatedAt": stringOrNull(connection.lastValidatedAt)
                    ])
                }

                let connections = try await ConnectionRegistry.shared.listConnections(validateLive: false)
                let items = connections.map { connection in
                    Value.object([
                        "id": .string(connection.id),
                        "provider": .string(connection.provider.rawValue),
                        "status": .string(connection.status.rawValue),
                        "lastValidatedAt": stringOrNull(connection.lastValidatedAt)
                    ])
                }
                return .object([
                    "count": .int(items.count),
                    "connections": .array(items)
                ])
            }
        ))

        await router.register(ToolRegistration(
            name: "connections_validate",
            module: moduleName,
            tier: .open,
            description: "Live round-trip validation against the remote service. Slower than connections_health; forces a fresh auth/token check.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "connectionId": .object([
                        "type": .string("string"),
                        "description": .string("Connection id")
                    ])
                ]),
                "required": .array([.string("connectionId")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let connectionId) = args["connectionId"] else {
                    throw ToolRouterError.invalidArguments(toolName: "connections_validate", reason: "missing 'connectionId'")
                }
                let connection = try await ConnectionRegistry.shared.validateConnection(id: connectionId)
                return connectionValue(connection)
            }
        ))

        await router.register(ToolRegistration(
            name: "connections_capabilities",
            module: moduleName,
            tier: .open,
            description: "List the tools and modules a given connection exposes. Use to discover a provider's surface.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "connectionId": .object([
                        "type": .string("string"),
                        "description": .string("Connection id")
                    ])
                ]),
                "required": .array([.string("connectionId")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let connectionId) = args["connectionId"] else {
                    throw ToolRouterError.invalidArguments(toolName: "connections_capabilities", reason: "missing 'connectionId'")
                }
                let capabilities = try await ConnectionRegistry.shared.capabilities(forConnectionId: connectionId)
                return .object([
                    "connectionId": .string(connectionId),
                    "count": .int(capabilities.count),
                    "capabilities": .array(capabilities.map(Value.string))
                ])
            }
        ))

        await router.register(ToolRegistration(
            name: "connections_reset",
            module: moduleName,
            tier: .request,
            description: "Reset and re-run canonical Bridge initialization for the current LOCAL broker session. Rotates the governance record while keeping the response-capable transport alive; safe to repeat. Remote tunnel callers are always refused by the control-plane policy.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([])
            ]),
            metadata: ToolMetadata(
                title: "Reset Local Connection Session",
                whenToUse: ["Recover a local MCP session whose governance state is stale without restarting The Bridge."],
                whenNotToUse: ["Changing a third-party client's reconnect URL or resetting a remote tunnel session."],
                relatedTools: ["connections_list", "bridge_initialize", "session_info"]
            ),
            handler: { _ in
                let context = ToolDispatchContext.current ?? .localDefault
                let receipt = try await resetService.reset(context: context)
                var value: [String: Value] = [
                    "ok": .bool(true),
                    "transportSessionId": .string(receipt.transportSessionId),
                    "brokerSessionId": .string(receipt.brokerSessionId),
                    "governed": .bool(receipt.governed),
                    "idempotent": .bool(receipt.idempotent),
                    "transportKeptAlive": .bool(true),
                    "clientRedialRequired": .bool(false)
                ]
                value["previousBrokerSessionId"] = receipt.previousBrokerSessionId.map(Value.string) ?? .null
                return .object(value)
            }
        ))
    }

    /// Stable redacted projection shared by the MCP response and focused tests.
    /// The snapshot type has no raw credential field; this serializer likewise
    /// emits only derived auth/session diagnostics.
    public static func runtimeValue(_ snapshot: ConnectionRuntimeSnapshot) -> Value {
        let now = Date()
        let sessions: [Value] = snapshot.sessions.map { session in
            .object([
                "transportSessionId": .string(session.transportSessionId),
                "origin": .string(session.origin.rawValue),
                "dialedTransport": .string(session.dialedTransport.rawValue),
                "clientName": session.clientName.map(Value.string) ?? .null,
                "acceptedAt": .string(ISO8601DateFormatter().string(from: session.acceptedAt)),
                "authMode": .string(session.authMode),
                "tokenAgeSeconds": session.tokenAgeSeconds(now: now).map(Value.int) ?? .null,
                "tokenAgeBasis": .string(session.authMode == "oauth" ? "accepted_at" : "not_applicable"),
                "tokenExpiresAt": session.tokenExpiresAt.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
                "lastRefreshOutcome": .string(session.lastRefreshOutcome),
                "governed": .bool(session.governed)
            ])
        }
        let events: [Value] = snapshot.recentEvents.map { event in
            .object([
                "kind": .string(event.kind.rawValue),
                "origin": .string(event.origin.rawValue),
                "transportSessionId": .string(event.transportSessionId),
                "dialedTransport": .string(event.dialedTransport.rawValue),
                "clientName": event.clientName.map(Value.string) ?? .null,
                "timestamp": .string(ISO8601DateFormatter().string(from: event.timestamp))
            ])
        }
        return .object([
            "authMode": .string(snapshot.authMode),
            "tokenMaterialIncluded": .bool(false),
            "refreshObservation": .string("OAuth refresh is client-managed; Bridge reports only outcomes it directly observes."),
            "sessions": .array(sessions),
            "recentSessionEvents": .array(events)
        ])
    }
}

private func parseConnectionFilters(_ arguments: Value) -> (BridgeConnectionProvider?, BridgeConnectionKind?) {
    guard case .object(let args) = arguments else {
        return (nil, nil)
    }

    let provider: BridgeConnectionProvider? = {
        guard case .string(let raw) = args["provider"] else {
            return nil
        }
        return BridgeConnectionProvider(rawValue: raw.lowercased())
    }()

    let kind: BridgeConnectionKind? = {
        guard case .string(let raw) = args["kind"] else {
            return nil
        }
        return BridgeConnectionKind(rawValue: raw.lowercased())
    }()

    return (provider, kind)
}

private func connectionValue(_ connection: BridgeConnection) -> Value {
    var object: [String: Value] = [
        "id": .string(connection.id),
        "provider": .string(connection.provider.rawValue),
        "kind": .string(connection.kind.rawValue),
        "name": .string(connection.name),
        "isPrimary": .bool(connection.isPrimary),
        "status": .string(connection.status.rawValue),
        "statusLabel": .string(connection.status.label),
        "authType": .string(connection.authType),
        "capabilities": .array(connection.capabilities.map(Value.string)),
        "metadata": .object(connection.metadata.reduce(into: [:]) { partialResult, item in
            partialResult[item.key] = .string(item.value)
        })
    ]

    object["maskedCredential"] = stringOrNull(connection.maskedCredential)
    object["lastValidatedAt"] = stringOrNull(connection.lastValidatedAt)
    object["summary"] = stringOrNull(connection.summary)
    return .object(object)
}

private func stringOrNull(_ value: String?) -> Value {
    guard let value else {
        return .null
    }
    return .string(value)
}
