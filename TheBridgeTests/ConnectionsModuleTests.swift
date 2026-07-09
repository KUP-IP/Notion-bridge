import Foundation
import MCP
import TheBridgeLib

func runConnectionsModuleTests() async {
    print("\n🔌 ConnectionsModule Tests")

    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log)
    await ConnectionsModule.register(on: router)

    await test("ConnectionsModule registers 5 tools") {
        let tools = await router.registrations(forModule: "connections")
        try expect(tools.count == 5, "Expected 5 connections tools, got \(tools.count)")
    }

    let expectedTools = [
        "connections_list",
        "connections_get",
        "connections_health",
        "connections_validate",
        "connections_capabilities"
    ]

    for toolName in expectedTools {
        await test("Tool \(toolName) is registered") {
            let tools = await router.registrations(forModule: "connections")
            try expect(tools.contains(where: { $0.name == toolName }), "Missing \(toolName)")
        }
    }

    for toolName in expectedTools {
        await test("\(toolName) tier is open") {
            let tools = await router.registrations(forModule: "connections")
            guard let tool = tools.first(where: { $0.name == toolName }) else {
                throw TestError.assertion("Tool \(toolName) not found")
            }
            try expect(tool.tier == .open, "Expected open tier for \(toolName)")
        }
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
