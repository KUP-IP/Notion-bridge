// Wave1BrokerTests.swift — Bridge Evolution Contract W1
// Session broker + constitution bundle + remote control-plane block.

import Foundation
import MCP
import TheBridgeLib

func runWave1BrokerTests() async {
    print("\n[Wave 1 Broker] Session broker + constitution bundle")

    await test("W1 SessionRegistry: open writes a governed row keyed by transport session") {
        try await withWave1TempHome { tmp in
            let registry = SessionRegistry(path: tmp.appendingPathComponent("sessions.sqlite"))
            try await registry.resetForTesting()

            let started = Date(timeIntervalSince1970: 1_800_000_000)
            let row = try await registry.open(
                transportSessionId: "http-session-1",
                client: "codex",
                mode: .execute,
                startedAt: started
            )

            try expect(row.governed == true)
            try expect(row.transportSessionId == "http-session-1")
            try expect(row.client == "codex")
            try expect(row.mode == .execute)

            let fetched = try await registry.current(transportSessionId: "http-session-1")
            try expect(fetched?.sessionId == row.sessionId)
            try expect(fetched?.startedAt == started)
        }
    }

    await test("W1 ConstitutionStore: interim bundle matches live files and active standing-order bodies") {
        try await withWave1TempHome { _ in
            try StandingOrdersStore.shared.resetForTesting()
            try CommandStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\n> **Amendment record:** v8.0.0\n\nRoot doctrine.")

            let store = StandingOrdersRecordStore(storeURL: BridgePaths.applicationSupport(.standingOrders)
                .appendingPathComponent("orders.json"))
            let active = try await store.save(title: "Active Order", body: "Keep it true.", scope: .global)
            let archived = try await store.save(title: "Archived Order", body: "Not shipped.", scope: .global)
            _ = try await store.delete(id: archived.id)

            _ = try CommandStore.shared.create(
                name: "Daily Brief",
                icon: .symbol("sun.max"),
                body: "Brief me.",
                keySlot: 2
            )

            let bundle = try await ConstitutionStore().assemble(
                supplementalStore: store,
                commandStore: .shared
            )

            try expect(bundle.tier0.contains("Tier-0"), "tier0 fallback must be present")
            try expect(bundle.doctrineCore.contains("Quickload"), "missing doctrine-core should use interim Quickload capsule")
            try expect(bundle.doctrineFreshness == .interim)
            try expect(bundle.doctrineVersion == "v8.0.0")
            try expect(bundle.orders.count == 1)
            try expect(bundle.orders.first?.id == active.id)
            try expect(bundle.orders.first?.body == "Keep it true.")
            try expect(bundle.commandsIndex.map(\.slug) == ["daily-brief"])
            try expect(bundle.commandsIndex.first?.keySlot == 2)
        }
    }

    await test("W1 bridge_initialize v2: writes session and returns constitution by default") {
        try await withWave1TempHome { tmp in
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\n> **Amendment record:** v8.0.1\n\nRoot doctrine.")
            let registry = SessionRegistry(path: tmp.appendingPathComponent("sessions.sqlite"))
            try await registry.resetForTesting()
            let receiptStore = HandshakeReceiptStore(baseDir: tmp.appendingPathComponent("handshakes", isDirectory: true))
            receiptStore.resetForTesting()

            let receipt = await ToolDispatchContext.$current.withValue(
                .init(transportSessionId: "http-session-2", origin: .local, client: "codex")
            ) {
                await BridgeInitializeService.run(
                    context: BridgeInitializeContext(
                        client: "codex",
                        connectionState: "local",
                        macToolsAvailable: true,
                        bridgeState: "running",
                        now: Date(timeIntervalSince1970: 1_800_000_010)
                    ),
                    mode: .execute,
                    includeConstitution: true,
                    sessionRegistry: registry,
                    receiptStore: receiptStore
                )
            }

            try expect(receipt.schemaVersion == 2)
            try expect(receipt.session?.transportSessionId == "http-session-2")
            try expect(receipt.session?.mode == .execute)
            try expect(receipt.session?.governed == true)
            try expect(receipt.constitution?.doctrineVersion == "v8.0.1")
            try expect(try await registry.current(transportSessionId: "http-session-2")?.sessionId == receipt.session?.sessionId)
        }
    }

    await test("W1 ToolRouter: ungoverned dispatch gets advisory annotation and governed dispatch does not") {
        try await withWave1TempHome { tmp in
            let registry = SessionRegistry(path: tmp.appendingPathComponent("sessions.sqlite"))
            try await registry.resetForTesting()
            let log = AuditLog()
            let router = ToolRouter(securityGate: SecurityGate(), auditLog: log, sessionRegistry: registry)
            await router.register(ToolRegistration(
                name: "probe",
                module: "test",
                tier: .open,
                description: "probe",
                inputSchema: .object(["type": .string("object")]),
                handler: { _ in .object(["ok": .bool(true)]) }
            ))

            let ungoverned = await router.dispatchFormatted(
                toolName: "probe",
                arguments: .object([:]),
                context: .init(transportSessionId: "missing-session", origin: .local, client: "codex")
            )
            let ungovernedObject = try jsonObject(ungoverned.text)
            try expect(ungoverned.isError == false)
            try expect((ungovernedObject["governance"] as? [String: Any])?["initialized"] as? Bool == false)

            _ = try await registry.open(transportSessionId: "governed-session", client: "codex", mode: .execute)
            let governed = await router.dispatchFormatted(
                toolName: "probe",
                arguments: .object([:]),
                context: .init(transportSessionId: "governed-session", origin: .local, client: "codex")
            )
            let governedObject = try jsonObject(governed.text)
            try expect(governedObject["governance"] == nil, "governed call should not carry advisory annotation")

            let entries = await log.entries(forTool: "probe")
            try expect(entries.count == 2)
            try expect(entries.first?.governed == false)
            try expect(entries.last?.governed == true)
        }
    }

    await test("W1 ToolRouter: remote control-plane predicate blocks only remote high-risk tools") {
        try await withWave1TempHome { tmp in
            let registry = SessionRegistry(path: tmp.appendingPathComponent("sessions.sqlite"))
            try await registry.resetForTesting()
            let log = AuditLog()
            let router = ToolRouter(securityGate: SecurityGate(), auditLog: log, sessionRegistry: registry)
            await router.register(ToolRegistration(
                name: "shell_exec",
                module: "shell",
                tier: .open,
                description: "shell",
                inputSchema: .object(["type": .string("object")]),
                handler: { _ in .object(["ok": .bool(true)]) }
            ))
            await router.register(ToolRegistration(
                name: "standing_orders_save",
                module: "standing_orders",
                tier: .notify,
                description: "standing-orders save",
                inputSchema: .object(["type": .string("object")]),
                handler: { _ in .object(["ok": .bool(true)]) }
            ))
            await router.register(ToolRegistration(
                name: "safe_read",
                module: "test",
                tier: .open,
                description: "safe",
                inputSchema: .object(["type": .string("object")]),
                handler: { _ in .object(["ok": .bool(true)]) }
            ))

            for blocked in ["shell_exec", "standing_orders_save"] {
                let remote = await router.dispatchFormatted(
                    toolName: blocked,
                    arguments: .object([:]),
                    context: .init(transportSessionId: "remote-session", origin: .remote, client: "remote")
                )
                try expect(remote.isError, "\(blocked) should be rejected remotely")
                try expect(remote.text.contains("control_plane_remote_blocked"))

                let local = await router.dispatchFormatted(
                    toolName: blocked,
                    arguments: .object([:]),
                    context: .init(transportSessionId: "local-session", origin: .local, client: "local")
                )
                try expect(!local.isError, "\(blocked) should still run locally")
            }

            let allowed = await router.dispatchFormatted(
                toolName: "safe_read",
                arguments: .object([:]),
                context: .init(transportSessionId: "remote-session", origin: .remote, client: "remote")
            )
            try expect(!allowed.isError, "non-blocklisted remote read should pass")
            try expect(await log.entries(withStatus: .rejected).count == 2)
        }
    }

    await test("W1 remote control-plane fixture: predicate catches the expected tool surface") {
        let registered: [ToolRegistration] = [
            .init(name: "shell_exec", module: "shell", tier: .open, description: "", inputSchema: .null, handler: { _ in .null }),
            .init(name: "run_script", module: "shell", tier: .open, description: "", inputSchema: .null, handler: { _ in .null }),
            .init(name: "applescript_exec", module: "applescript", tier: .open, description: "", inputSchema: .null, handler: { _ in .null }),
            .init(name: "credential_read", module: "credential", tier: .open, description: "", inputSchema: .null, handler: { _ in .null }),
            .init(name: "credential_save", module: "credential", tier: .open, description: "", inputSchema: .null, handler: { _ in .null }),
            .init(name: "credential_delete", module: "credential", tier: .open, description: "", inputSchema: .null, handler: { _ in .null }),
            .init(name: "standing_orders_save", module: "standing_orders", tier: .open, description: "", inputSchema: .null, handler: { _ in .null }),
            .init(name: "standing_orders_delete", module: "standing_orders", tier: .open, description: "", inputSchema: .null, handler: { _ in .null }),
            .init(name: "doctrine_sync", module: "standing_orders", tier: .open, description: "", inputSchema: .null, handler: { _ in .null }),
            .init(name: "commands_create", module: "commands", tier: .open, description: "", inputSchema: .null, handler: { _ in .null }),
            .init(name: "commands_update", module: "commands", tier: .open, description: "", inputSchema: .null, handler: { _ in .null }),
            .init(name: "commands_delete", module: "commands", tier: .open, description: "", inputSchema: .null, handler: { _ in .null }),
            .init(name: "commands_list", module: "commands", tier: .open, description: "", inputSchema: .null, handler: { _ in .null }),
        ]

        let blocked = registered
            .filter { RemoteControlPlanePolicy.isBlocked(tool: $0) }
            .map(\.name)
            .sorted()
        try expect(blocked == [
            "applescript_exec",
            "commands_create",
            "commands_delete",
            "commands_update",
            "credential_delete",
            "credential_read",
            "credential_save",
            "doctrine_sync",
            "run_script",
            "shell_exec",
            "standing_orders_delete",
            "standing_orders_save",
        ])
    }

    await test("W1 doctrine_sync: request-tier writer refreshes doctrine core") {
        try await withWave1TempHome { _ in
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\n> **Amendment record:** v8.0.2\n\nRoot doctrine.")

            let router = ToolRouter(securityGate: SecurityGate(), auditLog: AuditLog())
            await DoctrineSyncModule.register(on: router)
            let registration = await router.allRegistrations().first(where: { $0.name == "doctrine_sync" })
            try expect(registration?.tier == .request)
            try expect(registration?.neverAutoApprove == true)

            let report = try DoctrineSync().sync(markdown: nil)
            try expect(report.ok)
            try expect(report.doctrineVersion == "v8.0.2")

            let bundle = try await ConstitutionStore().assemble()
            try expect(bundle.doctrineFreshness == .fresh)
            try expect(bundle.doctrineCore.contains("Root doctrine."))
        }
    }
}

private func withWave1TempHome(_ body: (URL) async throws -> Void) async throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory
        .appendingPathComponent("Wave1Broker-test-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(tmp)
    defer {
        BridgePaths.overrideHomeForTesting(nil)
        try? fm.removeItem(at: tmp)
    }
    try await body(tmp)
}

private func jsonObject(_ text: String) throws -> [String: Any] {
    guard let data = text.data(using: .utf8),
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        throw TestError.assertion("expected JSON object text, got: \(text.prefix(200))")
    }
    return object
}
