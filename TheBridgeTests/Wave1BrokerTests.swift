// Wave1BrokerTests.swift — Bridge Evolution Contract W1
// Session broker + constitution bundle + remote control-plane block.

import Foundation
import MCP
import TheBridgeLib

func runWave1BrokerTests() async {
    print("\n[Wave 1 Broker] Session broker + constitution bundle")

    // The remote control-plane hard block is an operator opt-in. Keep the
    // original predicate/gate coverage active without making the test process
    // depend on (or permanently mutate) the operator's real preference domain.
    let remoteBlockKey = BridgeDefaults.brokerRemoteControlPlaneBlock
    let governedSessionKey = BridgeDefaults.brokerRemoteGovernedSessionRequired
    let previousRemoteBlock = UserDefaults.standard.object(forKey: remoteBlockKey)
    let previousGovernedSession = UserDefaults.standard.object(forKey: governedSessionKey)
    UserDefaults.standard.set(true, forKey: remoteBlockKey)
    UserDefaults.standard.set(true, forKey: governedSessionKey)
    defer {
        if let previousRemoteBlock {
            UserDefaults.standard.set(previousRemoteBlock, forKey: remoteBlockKey)
        } else {
            UserDefaults.standard.removeObject(forKey: remoteBlockKey)
        }
        if let previousGovernedSession {
            UserDefaults.standard.set(previousGovernedSession, forKey: governedSessionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: governedSessionKey)
        }
    }

    await test("W1 remote control-plane block defaults OFF and remains opt-in") {
        let current = UserDefaults.standard.object(forKey: remoteBlockKey)
        UserDefaults.standard.removeObject(forKey: remoteBlockKey)
        defer {
            if let current {
                UserDefaults.standard.set(current, forKey: remoteBlockKey)
            } else {
                UserDefaults.standard.removeObject(forKey: remoteBlockKey)
            }
        }

        try expect(BridgeDefaults.brokerRemoteControlPlaneBlockEnabled == false,
                   "missing preference must preserve full remote connector parity")
        UserDefaults.standard.set(true, forKey: remoteBlockKey)
        try expect(BridgeDefaults.brokerRemoteControlPlaneBlockEnabled == true,
                   "operator must still be able to opt into the remote hard block")
    }

    await test("W1 remote governed-session requirement remains fail-closed by default") {
        let current = UserDefaults.standard.object(forKey: governedSessionKey)
        UserDefaults.standard.removeObject(forKey: governedSessionKey)
        defer {
            if let current {
                UserDefaults.standard.set(current, forKey: governedSessionKey)
            } else {
                UserDefaults.standard.removeObject(forKey: governedSessionKey)
            }
        }

        try expect(BridgeDefaults.brokerRemoteGovernedSessionRequiredEnabled == true,
                   "missing preference must require remote sessions to initialize")
        UserDefaults.standard.set(false, forKey: governedSessionKey)
        try expect(BridgeDefaults.brokerRemoteGovernedSessionRequiredEnabled == false,
                   "operator must retain an explicit governance kill switch")
    }

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

            try expect(receipt.schemaVersion == 4)
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
            let router = ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: log, sessionRegistry: registry)
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
            let router = ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: log, sessionRegistry: registry)
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

    await test("W1 ToolRouter: governed remote shell reaches SecurityGate when hard block is off") {
        let currentRemoteBlock = UserDefaults.standard.object(forKey: remoteBlockKey)
        UserDefaults.standard.set(false, forKey: remoteBlockKey)
        defer {
            if let currentRemoteBlock {
                UserDefaults.standard.set(currentRemoteBlock, forKey: remoteBlockKey)
            } else {
                UserDefaults.standard.removeObject(forKey: remoteBlockKey)
            }
        }

        try await withWave1TempHome { tmp in
            let registry = SessionRegistry(path: tmp.appendingPathComponent("sessions.sqlite"))
            try await registry.resetForTesting()
            let log = AuditLog()
            let router = ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: log, sessionRegistry: registry)
            await router.register(ToolRegistration(
                name: "shell_exec",
                module: "shell",
                tier: .open,
                description: "shell",
                inputSchema: .object(["type": .string("object")]),
                handler: { _ in .object(["stdout": .string("BRIDGE_REMOTE_SHELL_OK")]) }
            ))

            _ = try await registry.open(
                transportSessionId: "remote-shell-session",
                client: "remote",
                mode: .execute
            )
            let remote = await router.dispatchFormatted(
                toolName: "shell_exec",
                arguments: .object([:]),
                context: .init(
                    transportSessionId: "remote-shell-session",
                    origin: .remote,
                    client: "remote"
                )
            )

            try expect(!remote.isError, "governed remote shell must reach normal dispatch when hard block is off")
            try expect(remote.text.contains("BRIDGE_REMOTE_SHELL_OK"))
            try expect(!remote.text.contains("control_plane_remote_blocked"))
        }
    }

    await test("W1 ToolRouter: ungoverned remote notify/request tools fail closed") {
        let currentRemoteBlock = UserDefaults.standard.object(forKey: remoteBlockKey)
        UserDefaults.standard.set(false, forKey: remoteBlockKey)
        defer {
            if let currentRemoteBlock {
                UserDefaults.standard.set(currentRemoteBlock, forKey: remoteBlockKey)
            } else {
                UserDefaults.standard.removeObject(forKey: remoteBlockKey)
            }
        }

        try await withWave1TempHome { tmp in
            let registry = SessionRegistry(path: tmp.appendingPathComponent("sessions.sqlite"))
            try await registry.resetForTesting()
            let log = AuditLog()
            let router = ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: log, sessionRegistry: registry)
            await router.register(ToolRegistration(
                name: "memory_remember",
                module: "memory",
                tier: .notify,
                description: "remember",
                inputSchema: .object(["type": .string("object")]),
                handler: { _ in .object(["ok": .bool(true)]) }
            ))
            await router.register(ToolRegistration(
                name: "messages_send",
                module: "messages",
                tier: .request,
                description: "send",
                inputSchema: .object(["type": .string("object")]),
                handler: { _ in .object(["ok": .bool(true)]) }
            ))

            for blocked in ["memory_remember", "messages_send"] {
                let remote = await router.dispatchFormatted(
                    toolName: blocked,
                    arguments: .object([:]),
                    context: .init(transportSessionId: "remote-session", origin: .remote, client: "remote")
                )
                try expect(remote.isError, "\(blocked) should reject before an ungoverned remote write")
                try expect(remote.text.contains("ungoverned_remote_session"))
            }

            _ = try await registry.open(transportSessionId: "remote-session", client: "remote", mode: .execute)
            let governedRemote = await router.dispatchFormatted(
                toolName: "memory_remember",
                arguments: .object([:]),
                context: .init(transportSessionId: "remote-session", origin: .remote, client: "remote")
            )
            try expect(!governedRemote.isError, "governed remote notify-tier tool should run")

            let local = await router.dispatchFormatted(
                toolName: "memory_remember",
                arguments: .object([:]),
                context: .localDefault
            )
            try expect(!local.isError, "local notify-tier tool should not require broker governance")

            let rejected = await log.entries(withStatus: .rejected)
            try expect(rejected.count == 2)
            try expect(rejected.allSatisfy { $0.governanceNote == "ungoverned_remote_session" })
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

    await test("W1 tools/list: broker bootstrap tools are ordered first") {
        let registered: [ToolRegistration] = [
            .init(name: "shell_exec", module: "shell", tier: .open, description: "", inputSchema: .null, handler: { _ in .null }),
            .init(name: "memory_remember", module: "memory", tier: .notify, description: "", inputSchema: .null, handler: { _ in .null }),
            .init(name: "session_info", module: "session", tier: .open, description: "", inputSchema: .null, handler: { _ in .null }),
            .init(name: "bridge_initialize", module: "standing_orders", tier: .open, description: "", inputSchema: .null, handler: { _ in .null }),
            .init(name: "tools_list", module: "session", tier: .open, description: "", inputSchema: .null, handler: { _ in .null }),
            .init(name: "bridge_status", module: "cloud", tier: .open, description: "", inputSchema: .null, handler: { _ in .null }),
            .init(name: "contacts_search", module: "contacts", tier: .open, description: "", inputSchema: .null, handler: { _ in .null }),
        ]

        let ordered = BrokerBootstrapToolOrdering.prioritize(registered).map(\.name)
        try expect(Array(ordered.prefix(4)) == [
            "bridge_initialize",
            "bridge_status",
            "tools_list",
            "session_info",
        ])
        try expect(Array(ordered.dropFirst(4)) == [
            "contacts_search",
            "memory_remember",
            "shell_exec",
        ], "non-bootstrap tools must use deterministic alphabetical order")
    }

    await test("W1 doctrine_sync: request-tier writer refreshes doctrine core") {
        try await withWave1TempHome { _ in
            try StandingOrdersStore.shared.resetForTesting()
            _ = try StandingOrdersStore.shared.write("# Orders\n\n> **Amendment record:** v8.0.2\n\nRoot doctrine.")

            let router = ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog())
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
