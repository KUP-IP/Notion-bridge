// RemoteGovernanceContinuityTests.swift — principal-keyed remote governance +
// routing-manifest continuity across Mcp-Session-Id churn (Red Team hardened).

import Foundation
import MCP
import TheBridgeLib

func runRemoteGovernanceContinuityTests() async {
    print("\n🔐 Remote Governance Continuity (principal key)")

    await test("principalKey rejects empty/whitespace subjects") {
        try expect(SessionRegistry.principalKey(subject: "") == nil)
        try expect(SessionRegistry.principalKey(subject: "   ") == nil)
        try expect(SessionRegistry.principalKey(subject: "user-123") == "oauth-sub:user-123")
        try expect(SessionRegistry.normalizedPrincipalKey("oauth-sub:") == nil)
        try expect(SessionRegistry.normalizedPrincipalKey("oauth-sub:user-123") == "oauth-sub:user-123")
    }

    await test("same OAuth principal governs notify across rotated transport sessions") {
        try await withRemoteGovernanceHarness { harness in
            let principal = SessionRegistry.principalKey(subject: "continuity-user")!
            let sessionA = "sess-a-\(UUID().uuidString)"
            let sessionB = "sess-b-\(UUID().uuidString)"

            let initResult = await harness.router.dispatchFormatted(
                toolName: BridgeInitializeModule.toolName,
                arguments: .object(["client": .string("connectors-manager")]),
                context: .init(
                    transportSessionId: sessionA,
                    origin: .remote,
                    client: "connectors-manager",
                    governancePrincipal: principal
                )
            )
            try expect(!initResult.isError, "bridge_initialize must succeed: \(initResult.text)")
            try expect(try await harness.registry.isGoverned(
                transportSessionId: sessionA,
                principalKey: principal
            ))
            try expect(try await harness.registry.isGoverned(
                transportSessionId: sessionB,
                principalKey: principal
            ), "principal continuity must cover a fresh transport session id")

            let write = await harness.router.dispatchFormatted(
                toolName: "governance_write_probe",
                arguments: .object([:]),
                context: .init(
                    transportSessionId: sessionB,
                    origin: .remote,
                    client: "connectors-manager",
                    governancePrincipal: principal
                )
            )
            try expect(!write.isError, "same-principal notify on session B must execute: \(write.text)")
            try expect(write.text.contains("write-ok"), "unexpected write body: \(write.text)")
            try expect(!write.text.contains("ungoverned_remote_session"))
        }
    }

    await test("different OAuth principal stays fail-closed on notify") {
        try await withRemoteGovernanceHarness { harness in
            let principalA = SessionRegistry.principalKey(subject: "alice")!
            let principalB = SessionRegistry.principalKey(subject: "bob")!
            let sessionA = "sess-alice-\(UUID().uuidString)"
            let sessionB = "sess-bob-\(UUID().uuidString)"

            _ = await harness.router.dispatchFormatted(
                toolName: BridgeInitializeModule.toolName,
                arguments: .object(["client": .string("alice-client")]),
                context: .init(
                    transportSessionId: sessionA,
                    origin: .remote,
                    governancePrincipal: principalA
                )
            )

            let rejected = await harness.router.dispatchFormatted(
                toolName: "governance_write_probe",
                arguments: .object([:]),
                context: .init(
                    transportSessionId: sessionB,
                    origin: .remote,
                    governancePrincipal: principalB
                )
            )
            try expect(rejected.isError)
            try expect(rejected.text.contains("ungoverned_remote_session"),
                       "cross-principal notify must fail closed: \(rejected.text)")
        }
    }

    await test("empty principal never inherits another session's governance") {
        try await withRemoteGovernanceHarness { harness in
            let realPrincipal = SessionRegistry.principalKey(subject: "real-user")!
            let sessionA = "sess-real-\(UUID().uuidString)"
            let sessionEmpty = "sess-empty-\(UUID().uuidString)"

            _ = await harness.router.dispatchFormatted(
                toolName: BridgeInitializeModule.toolName,
                arguments: .object(["client": .string("real")]),
                context: .init(
                    transportSessionId: sessionA,
                    origin: .remote,
                    governancePrincipal: realPrincipal
                )
            )

            // Spoof / missing-sub path: governancePrincipal nil (empty subject → nil).
            let rejected = await harness.router.dispatchFormatted(
                toolName: "governance_write_probe",
                arguments: .object([:]),
                context: .init(
                    transportSessionId: sessionEmpty,
                    origin: .remote,
                    governancePrincipal: nil
                )
            )
            try expect(rejected.isError)
            try expect(rejected.text.contains("ungoverned_remote_session"))

            // Explicit empty string must normalize away and not match.
            let emptyNormalized = ToolDispatchContext(
                transportSessionId: sessionEmpty,
                origin: .remote,
                governancePrincipal: ""
            )
            try expect(emptyNormalized.governancePrincipal == nil)
            let rejectedEmpty = await harness.router.dispatchFormatted(
                toolName: "governance_write_probe",
                arguments: .object([:]),
                context: emptyNormalized
            )
            try expect(rejectedEmpty.text.contains("ungoverned_remote_session"))
        }
    }

    await test("routing-manifest marker follows principal across session rotation") {
        try await withRemoteGovernanceHarness { harness in
            let principal = SessionRegistry.principalKey(subject: "manifest-user")!
            let sessionA = "manifest-a-\(UUID().uuidString)"
            let sessionB = "manifest-b-\(UUID().uuidString)"

            let initResult = await harness.router.dispatchFormatted(
                toolName: BridgeInitializeModule.toolName,
                arguments: .object(["client": .string("connectors-manager")]),
                context: .init(
                    transportSessionId: sessionA,
                    origin: .remote,
                    governancePrincipal: principal
                )
            )
            try expect(!initResult.isError)
            try expect(await harness.router.hasRoutingManifestMarker(sessionID: sessionA))
            try expect(await harness.router.hasRoutingManifestMarker(sessionID: principal),
                       "bridge_initialize must mark the verified principal for churn continuity")

            let bound = await harness.router.dispatchFormatted(
                toolName: "notion_page_create",
                arguments: .object([:]),
                context: .init(
                    transportSessionId: sessionB,
                    origin: .remote,
                    governancePrincipal: principal
                )
            )
            try expect(!bound.isError, "manifest-bound notify on rotated session must pass: \(bound.text)")
            try expect(bound.text.contains("notion-create-ok"), "unexpected body: \(bound.text)")
            try expect(!bound.text.contains("routing manifest"),
                       "must not re-demand routing manifest after principal-marked initialize: \(bound.text)")
        }
    }

    await test("clientInfo alone still does not carry governance (PKT-1124 invariant)") {
        try await withRemoteGovernanceHarness { harness in
            let sessionA = "clientinfo-a-\(UUID().uuidString)"
            let sessionB = "clientinfo-b-\(UUID().uuidString)"

            _ = await harness.router.dispatchFormatted(
                toolName: BridgeInitializeModule.toolName,
                arguments: .object(["client": .string("spoofable-name")]),
                context: .init(
                    transportSessionId: sessionA,
                    origin: .remote,
                    client: "spoofable-name"
                )
            )

            let rejected = await harness.router.dispatchFormatted(
                toolName: "governance_write_probe",
                arguments: .object([:]),
                context: .init(
                    transportSessionId: sessionB,
                    origin: .remote,
                    client: "spoofable-name"
                )
            )
            try expect(rejected.text.contains("ungoverned_remote_session"),
                       "matching clientInfo must never grant remote governance: \(rejected.text)")
        }
    }
}

private struct RemoteGovernanceHarness {
    let root: URL
    let registry: SessionRegistry
    let router: ToolRouter
}

private func withRemoteGovernanceHarness(
    _ body: (RemoteGovernanceHarness) async throws -> Void
) async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("remote-gov-continuity-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(root)

    let governedKey = BridgeDefaults.brokerRemoteGovernedSessionRequired
    let advisoryKey = BridgeDefaults.brokerAdvisoryAnnotation
    let previousGoverned = UserDefaults.standard.object(forKey: governedKey)
    let previousAdvisory = UserDefaults.standard.object(forKey: advisoryKey)
    UserDefaults.standard.set(true, forKey: governedKey)
    UserDefaults.standard.set(true, forKey: advisoryKey)

    defer {
        if let previousGoverned {
            UserDefaults.standard.set(previousGoverned, forKey: governedKey)
        } else {
            UserDefaults.standard.removeObject(forKey: governedKey)
        }
        if let previousAdvisory {
            UserDefaults.standard.set(previousAdvisory, forKey: advisoryKey)
        } else {
            UserDefaults.standard.removeObject(forKey: advisoryKey)
        }
        BridgePaths.overrideHomeForTesting(nil)
        try? fileManager.removeItem(at: root)
    }

    try StandingOrdersStore.shared.resetForTesting()
    _ = try StandingOrdersStore.shared.write(
        "# Orders\n\n> **Amendment record:** v8.0.1\n\nRoot doctrine for remote governance continuity tests."
    )

    let registry = SessionRegistry(path: root.appendingPathComponent("broker-sessions.sqlite"))
    try await registry.resetForTesting()
    let router = ToolRouter(
        securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()),
        auditLog: AuditLog(),
        sessionRegistry: registry
    )
    let receiptStore = HandshakeReceiptStore(
        baseDir: root.appendingPathComponent("handshakes", isDirectory: true)
    )

    await router.register(ToolRegistration(
        name: BridgeInitializeModule.toolName,
        module: BridgeInitializeModule.moduleName,
        tier: .open,
        description: "remote governance continuity bridge_initialize",
        inputSchema: .object(["type": .string("object")]),
        handler: { arguments in
            let client: String? = {
                guard case .object(let object) = arguments,
                      case .string(let value)? = object["client"] else { return nil }
                return value
            }()
            let receipt = await BridgeInitializeService.run(
                context: BridgeInitializeContext(
                    client: client,
                    connectionState: "remote",
                    macToolsAvailable: true,
                    bridgeState: "running",
                    now: Date()
                ),
                mode: .execute,
                includeConstitution: false,
                sessionRegistry: registry,
                receiptStore: receiptStore,
                routingSnapshot: remoteGovernanceHealthyRoutingSnapshot()
            )
            return BridgeInitializeModule.receiptValue(receipt)
        }
    ))
    await router.register(ToolRegistration(
        name: "governance_write_probe",
        module: "test",
        tier: .notify,
        description: "unbound notify probe",
        inputSchema: .object(["type": .string("object")]),
        handler: { _ in .object(["value": .string("write-ok")]) }
    ))
    // Manifest-bound notify tool — same name as a live binding so
    // ToolSkillBindingRegistry.requiresManifestFetch is true.
    await router.register(ToolRegistration(
        name: "notion_page_create",
        module: "notion",
        tier: .notify,
        description: "manifest-bound notify probe",
        inputSchema: .object(["type": .string("object")]),
        handler: { _ in .object(["value": .string("notion-create-ok")]) }
    ))

    try await body(.init(root: root, registry: registry, router: router))
}

private func remoteGovernanceHealthyRoutingSnapshot() -> SkillRoutingSnapshot {
    .init(
        metadata: .init(
            status: .healthy,
            source: .runtimeExposureGeneration,
            snapshotID: "remote-governance-test",
            count: 3,
            reason: "test"
        ),
        skills: (0..<3).map { .object(["name": .string("Routing \($0)")]) }
    )
}
