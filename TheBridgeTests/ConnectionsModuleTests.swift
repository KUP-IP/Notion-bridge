import Foundation
import MCP
import TheBridgeLib

func runConnectionsModuleTests() async {
    print("\n🔌 ConnectionsModule Tests")

    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await ConnectionsModule.register(on: router)

    await test("ConnectionsModule registers 6 tools") {
        let tools = await router.registrations(forModule: "connections")
        try expect(tools.count == 6, "Expected 6 connections tools, got \(tools.count)")
    }

    let expectedOpenTools = [
        "connections_list",
        "connections_get",
        "connections_health",
        "connections_validate",
        "connections_capabilities"
    ]
    let expectedTools = expectedOpenTools + ["connections_reset"]

    for toolName in expectedTools {
        await test("Tool \(toolName) is registered") {
            let tools = await router.registrations(forModule: "connections")
            try expect(tools.contains(where: { $0.name == toolName }), "Missing \(toolName)")
        }
    }

    for toolName in expectedOpenTools {
        await test("\(toolName) tier is open") {
            let tools = await router.registrations(forModule: "connections")
            guard let tool = tools.first(where: { $0.name == toolName }) else {
                throw TestError.assertion("Tool \(toolName) not found")
            }
            try expect(tool.tier == .open, "Expected open tier for \(toolName)")
        }
    }

    await test("connections_reset is request-tier and never auto-approved") {
        let tools = await router.registrations(forModule: "connections")
        guard let tool = tools.first(where: { $0.name == "connections_reset" }) else {
            throw TestError.assertion("connections_reset not found")
        }
        try expect(tool.tier == .request, "reset must remain operator-gated")
        try expect(tool.neverAutoApprove, "reset must not inherit an always-allow grant")
        try expect(RemoteControlPlanePolicy.isAlwaysBlocked(tool: tool), "reset must be unconditionally local-only")
    }

    await test("connection runtime projection distinguishes local/tunnel and excludes token material") {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pkt-1123-observability-\(UUID().uuidString)", isDirectory: true)
        let registry = SessionRegistry(path: temp.appendingPathComponent("sessions.sqlite"))
        let observability = ConnectionRuntimeObservability(eventLimit: 20)
        defer { try? FileManager.default.removeItem(at: temp) }

        try await registry.resetForTesting()
        _ = try await registry.open(transportSessionId: "local-session", client: "Codex", mode: .execute)
        await observability.configure(authMode: "oauth")
        await observability.recordAccept(
            transportSessionId: "local-session",
            origin: .local,
            clientName: "Codex",
            authMode: "loopback_exempt",
            tokenExpiresAt: nil,
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )
        await observability.recordAccept(
            transportSessionId: "tunnel-session",
            origin: .remote,
            clientName: "Claude",
            authMode: "oauth",
            tokenExpiresAt: Date(timeIntervalSince1970: 1_800_003_600),
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let snapshot = await observability.snapshot(sessionRegistry: registry)
        try expect(snapshot.authMode == "oauth")
        try expect(snapshot.sessions.first(where: { $0.transportSessionId == "local-session" })?.dialedTransport == .local)
        try expect(snapshot.sessions.first(where: { $0.transportSessionId == "local-session" })?.authMode == "loopback_exempt")
        try expect(snapshot.sessions.first(where: { $0.transportSessionId == "local-session" })?.governed == true)
        try expect(snapshot.sessions.first(where: { $0.transportSessionId == "tunnel-session" })?.dialedTransport == .tunnel)
        try expect(snapshot.sessions.first(where: { $0.transportSessionId == "tunnel-session" })?.lastRefreshOutcome == "client_managed_not_observed")

        let value = ConnectionsModule.runtimeValue(snapshot)
        let encoded = try JSONEncoder().encode(value)
        let text = String(decoding: encoded, as: UTF8.self)
        try expect(text.contains("tokenMaterialIncluded"))
        try expect(text.contains("tokenAgeBasis"))
        try expect(!text.lowercased().contains("authorization"), "projection must not expose Authorization material")
        try expect(!text.lowercased().contains("refresh_token"), "projection must not expose refresh tokens")
        try expect(!text.lowercased().contains("access_token"), "projection must not expose access tokens")
    }

    await test("local reset upserts without a governance gap and remains repeatable") {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pkt-1123-reset-\(UUID().uuidString)", isDirectory: true)
        let registry = SessionRegistry(path: temp.appendingPathComponent("sessions.sqlite"))
        let observability = ConnectionRuntimeObservability(eventLimit: 20)
        let receiptStore = HandshakeReceiptStore(baseDir: temp.appendingPathComponent("receipts", isDirectory: true))
        let service = ConnectionSessionResetService(
            sessionRegistry: registry,
            observability: observability,
            receiptStore: receiptStore
        )
        defer { try? FileManager.default.removeItem(at: temp) }

        try await registry.resetForTesting()
        let original = try await registry.open(
            transportSessionId: "local-reset-session",
            client: "Codex",
            mode: .execute
        )
        let context = ToolDispatchContext(
            transportSessionId: "local-reset-session",
            origin: .local,
            client: "Codex"
        )
        let first = try await service.reset(context: context)
        let second = try await service.reset(context: context)

        try expect(first.previousBrokerSessionId == original.sessionId)
        try expect(first.brokerSessionId != original.sessionId)
        try expect(second.previousBrokerSessionId == first.brokerSessionId)
        try expect(second.brokerSessionId != first.brokerSessionId)
        try expect(first.governed && second.governed && second.idempotent)
        let current = try await registry.current(transportSessionId: "local-reset-session")
        try expect(current?.sessionId == second.brokerSessionId)
        try expect(current?.governed == true)
        let snapshot = await observability.snapshot(sessionRegistry: registry)
        try expect(snapshot.recentEvents.filter { $0.kind == .reset }.count == 2)
    }

    await test("connection reset service refuses remote context directly") {
        let service = ConnectionSessionResetService()
        do {
            _ = try await service.reset(context: .init(
                transportSessionId: "remote-reset-session",
                origin: .remote,
                client: "remote"
            ))
            throw TestError.assertion("remote reset unexpectedly succeeded")
        } catch let error as ConnectionResetError {
            try expect(error == .remoteBlocked)
        }
    }

    await test("connections_reset is tunnel-blocked even when the broad hardening switch is off") {
        let remoteBlockKey = BridgeDefaults.brokerRemoteControlPlaneBlock
        let previous = UserDefaults.standard.object(forKey: remoteBlockKey)
        UserDefaults.standard.set(false, forKey: remoteBlockKey)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: remoteBlockKey)
            } else {
                UserDefaults.standard.removeObject(forKey: remoteBlockKey)
            }
        }

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pkt-1123-remote-block-\(UUID().uuidString)", isDirectory: true)
        let registry = SessionRegistry(path: temp.appendingPathComponent("sessions.sqlite"))
        defer { try? FileManager.default.removeItem(at: temp) }
        try await registry.resetForTesting()
        let isolatedRouter = ToolRouter(
            securityGate: SecurityGate(),
            auditLog: AuditLog(),
            sessionRegistry: registry
        )
        await ConnectionsModule.register(on: isolatedRouter)
        let result = await isolatedRouter.dispatchFormatted(
            toolName: "connections_reset",
            arguments: .object([:]),
            context: .init(transportSessionId: "remote-reset-session", origin: .remote, client: "remote")
        )
        try expect(result.isError)
        try expect(result.text.contains("control_plane_remote_blocked"))
    }

    await test("Connection Settings exposes redacted runtime and local reset controls") {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: repository
            .appendingPathComponent("TheBridge/UI/Sections/ConnectionsSection.swift"), encoding: .utf8)
        try expect(source.contains("Connection runtime"))
        try expect(source.contains("Reset local sessions"))
        try expect(source.contains("Auth mode"))
        try expect(source.contains("Token material is never shown"))
        try expect(source.contains("governed "))
        try expect(source.contains("refresh "))

        let runtimeSource = try String(contentsOf: repository
            .appendingPathComponent("TheBridge/Server/ConnectionRuntimeObservability.swift"), encoding: .utf8)
        try expect(runtimeSource.contains("let stableSessions = Array(sessions.values)"),
                   "snapshot must copy actor-owned sessions before governance awaits")
        try expect(!runtimeSource.contains("sessionRegistry.close"),
                   "reset must preserve the governed row until ON CONFLICT replacement")
    }

    await test("connections_get rejects missing connectionId") {
        do {
            _ = try await router.dispatch(
                toolName: "connections_get",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing connectionId")
        } catch is ToolRouterError {
            // Expected
        }
    }

    await test("connections_validate rejects missing connectionId") {
        do {
            _ = try await router.dispatch(
                toolName: "connections_validate",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing connectionId")
        } catch is ToolRouterError {
            // Expected
        }
    }

    await test("connections_capabilities rejects missing connectionId") {
        do {
            _ = try await router.dispatch(
                toolName: "connections_capabilities",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing connectionId")
        } catch is ToolRouterError {
            // Expected
        }
    }

    // PKT-1065B: primary-connection symbolic alias resolution (pure, hermetic).
    struct FakeConn { let id: String; let primary: Bool }
    let fakeConns = [
        FakeConn(id: "notion:default", primary: true),
        FakeConn(id: "notion:work", primary: false)
    ]

    await test("isPrimaryAlias recognizes notion:primary (case-insensitive)") {
        try expect(ConnectionRegistry.isPrimaryAlias(id: "notion:primary"), "notion:primary should be the alias")
        try expect(ConnectionRegistry.isPrimaryAlias(id: "notion:PRIMARY"), "alias match should be case-insensitive")
        try expect(!ConnectionRegistry.isPrimaryAlias(id: "notion:default"), "a real name is not the alias")
        try expect(!ConnectionRegistry.isPrimaryAlias(id: "notion"), "id without a name segment is not the alias")
    }

    await test("resolve maps notion:primary to the live primary connection") {
        let resolved = ConnectionRegistry.resolve(
            id: "notion:primary",
            in: fakeConns,
            idOf: { $0.id },
            isPrimary: { $0.primary }
        )
        try expect(resolved?.id == "notion:default", "notion:primary should resolve to the primary (notion:default), got \(resolved?.id ?? "nil")")
    }

    await test("resolve exact-id match wins over primary alias") {
        // A connection literally named "primary" must not be shadowed by the alias.
        let withLiteralPrimary = [
            FakeConn(id: "notion:primary", primary: false),
            FakeConn(id: "notion:default", primary: true)
        ]
        let resolved = ConnectionRegistry.resolve(
            id: "notion:primary",
            in: withLiteralPrimary,
            idOf: { $0.id },
            isPrimary: { $0.primary }
        )
        try expect(resolved?.id == "notion:primary" && resolved?.primary == false,
                   "Exact id should win, resolving to the literally-named 'primary' connection")
    }

    await test("resolve returns nil for an unknown non-alias id") {
        let resolved = ConnectionRegistry.resolve(
            id: "notion:missing",
            in: fakeConns,
            idOf: { $0.id },
            isPrimary: { $0.primary }
        )
        try expect(resolved == nil, "Unknown non-alias id should not resolve")
    }

    // connections_health must stay cached (validateLive:false) per its own tool
    // description ("doesn't hit the live service"). Regression guard for a bug
    // where the handler passed validateLive:true — indistinguishable from
    // connections_validate. `lastValidatedAt` is the deterministic signal:
    // ConnectionRegistry sets it to a fresh timestamp ONLY on the live path
    // (validateLive:true) and to nil on the cached path, for every Notion
    // connection. This assertion only fires when a real Notion connection is
    // configured (no test seam exists for ConnectionRegistry.shared), but it
    // is a real regression guard on any machine with a live workspace.
    await test("connections_health does not force a live re-validation") {
        let result = try await router.dispatch(
            toolName: "connections_health",
            arguments: .object([:])
        )
        guard case .object(let dict) = result, case .array(let connections) = dict["connections"] else {
            throw TestError.assertion("Expected a connections array from connections_health")
        }
        for entry in connections {
            guard case .object(let conn) = entry, case .string(let provider) = conn["provider"] else {
                continue
            }
            if provider == "notion" {
                let lastValidatedAt = conn["lastValidatedAt"] ?? .null
                try expect(
                    lastValidatedAt == .null,
                    "connections_health should report lastValidatedAt: null for cached Notion connections (validateLive:false), got \(lastValidatedAt)"
                )
            }
        }
    }

    await test("resolve returns nil for primary alias when no primary exists") {
        let noPrimary = [FakeConn(id: "notion:a", primary: false)]
        let resolved = ConnectionRegistry.resolve(
            id: "notion:primary",
            in: noPrimary,
            idOf: { $0.id },
            isPrimary: { $0.primary }
        )
        try expect(resolved == nil, "primary alias should not resolve when nothing is primary")
    }
}
