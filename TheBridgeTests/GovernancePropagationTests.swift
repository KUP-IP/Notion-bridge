// GovernancePropagationTests.swift — PKT-1124 / W2C
// Real Streamable-HTTP session proof for bridge_initialize governance keying.

import Foundation
import MCP
import TheBridgeLib

func runGovernancePropagationTests() async {
    print("\n🧭 Governance Propagation (PKT-1124)")

    await test("PKT-1124 same Streamable-HTTP session stays governed after bridge_initialize") {
        try await withGovernancePropagationHarness { harness in
            let sessionID = try await harness.initialize(client: "pkt-1124-same-session")

            let initializeResult = try await harness.call(
                sessionID: sessionID,
                tool: BridgeInitializeModule.toolName,
                arguments: ["client": "pkt-1124-same-session"]
            )
            try expect(!initializeResult.contains("has not called bridge_initialize"),
                       "bridge_initialize itself must never carry the advisory")
            try expect(try await harness.registry.isGoverned(transportSessionId: sessionID),
                       "bridge_initialize must govern the exact MCP session id")

            let subsequent = try await harness.call(
                sessionID: sessionID,
                tool: "governance_probe"
            )
            try expect(subsequent.contains("probe-ok"),
                       "post-initialize probe must execute on the same MCP session")
            try expect(!subsequent.contains("has not called bridge_initialize"),
                       "same-session post-initialize call must not carry the false advisory: \(subsequent)")
        }
    }

    await test("PKT-1124 reconnect gets a new ungoverned session even with the same client identity") {
        try await withGovernancePropagationHarness { harness in
            let governedID = try await harness.initialize(client: "pkt-1124-reconnect")
            _ = try await harness.call(
                sessionID: governedID,
                tool: BridgeInitializeModule.toolName,
                arguments: ["client": "pkt-1124-reconnect"]
            )
            try expect(try await harness.registry.isGoverned(transportSessionId: governedID))

            let reconnectedID = try await harness.initialize(client: "pkt-1124-reconnect")
            try expect(reconnectedID != governedID,
                       "a fresh MCP initialize must mint a distinct transport session")
            let firstPostReconnect = try await harness.call(
                sessionID: reconnectedID,
                tool: "governance_probe"
            )
            try expect(firstPostReconnect.contains("has not called bridge_initialize"),
                       "new session must remain advisory until it initializes: \(firstPostReconnect)")
            try expect(!(try await harness.registry.isGoverned(transportSessionId: reconnectedID)),
                       "matching clientInfo must never carry governance to a fresh session")
        }
    }

    await test("PKT-1124 spoofed session never reads governed or reaches a remote write") {
        try await withGovernancePropagationHarness { harness in
            let forgedID = "forged-\(UUID().uuidString)"
            let local = await harness.router.dispatchFormatted(
                toolName: "governance_probe",
                arguments: .object([:]),
                context: .init(
                    transportSessionId: forgedID,
                    origin: .local,
                    client: "pkt-1124-spoof"
                )
            )
            try expect(local.text.contains("has not called bridge_initialize"),
                       "forged local context must carry the uninitialized advisory")
            try expect(!(try await harness.registry.isGoverned(transportSessionId: forgedID)))

            let remote = await harness.router.dispatchFormatted(
                toolName: "governance_write_probe",
                arguments: .object([:]),
                context: .init(
                    transportSessionId: forgedID,
                    origin: .remote,
                    client: "pkt-1124-spoof"
                )
            )
            try expect(remote.isError, "ungoverned remote write must fail closed")
            try expect(remote.text.contains("ungoverned_remote_session"),
                       "ungoverned remote write must fail at the broker gate: \(remote.text)")
        }
    }

    await test("PKT-1124 stdio synthetic session governs only after bridge_initialize") {
        try await withGovernancePropagationHarness { harness in
            let context = ToolDispatchContext(
                transportSessionId: ServerManager.stdioSessionID,
                origin: .local,
                client: "stdio"
            )
            let before = await harness.router.dispatchFormatted(
                toolName: "governance_probe",
                arguments: .object([:]),
                context: context
            )
            try expect(before.text.contains("has not called bridge_initialize"),
                       "stdio must begin ungoverned in the isolated registry")

            let initialized = await harness.router.dispatchFormatted(
                toolName: BridgeInitializeModule.toolName,
                arguments: .object(["client": .string("stdio")]),
                context: context
            )
            try expect(!initialized.isError, "stdio bridge_initialize must succeed")
            try expect(try await harness.registry.isGoverned(
                transportSessionId: ServerManager.stdioSessionID
            ))

            let after = await harness.router.dispatchFormatted(
                toolName: "governance_probe",
                arguments: .object([:]),
                context: context
            )
            try expect(!after.text.contains("has not called bridge_initialize"),
                       "stdio post-initialize call must not carry the advisory")
        }
    }
}

private struct GovernancePropagationHarness {
    let root: URL
    let registry: SessionRegistry
    let router: ToolRouter
    let server: SSEServer

    func initialize(client: String) async throws -> String {
        let body = Data("""
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\(BridgeConstants.mcpProtocolVersion)","capabilities":{},"clientInfo":{"name":"\(client)","version":"test"}}}
        """.utf8)
        let response = await server.handleHTTPRequest(HTTPRequest(
            method: "POST",
            headers: Self.baseHeaders,
            body: body
        ))
        guard let sessionID = response.headers[HTTPHeaderName.sessionID] else {
            throw TestError.assertion("MCP initialize did not return Mcp-Session-Id (status \(response.statusCode))")
        }
        _ = try await Self.responseText(response)
        return sessionID
    }

    func call(
        sessionID: String,
        tool: String,
        arguments: [String: Any] = [:]
    ) async throws -> String {
        var headers = Self.baseHeaders
        headers[HTTPHeaderName.sessionID] = sessionID
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": ["name": tool, "arguments": arguments]
        ])
        let response = await server.handleHTTPRequest(HTTPRequest(
            method: "POST",
            headers: headers,
            body: body
        ))
        return try await Self.responseText(response)
    }

    private static let baseHeaders = [
        "Host": "127.0.0.1:\(BridgeConstants.defaultSSEPort)",
        "Accept": "application/json, text/event-stream",
        "Content-Type": "application/json"
    ]

    private static func responseText(_ response: HTTPResponse) async throws -> String {
        if case .stream(let stream, _) = response {
            var text = ""
            for try await data in stream {
                text += String(decoding: data, as: UTF8.self)
            }
            return text
        }
        if let data = response.bodyData {
            return String(decoding: data, as: UTF8.self)
        }
        return ""
    }
}

private func withGovernancePropagationHarness(
    _ body: (GovernancePropagationHarness) async throws -> Void
) async throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
        .appendingPathComponent("PKT-1124-governance-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(root)

    let advisoryKey = BridgeDefaults.brokerAdvisoryAnnotation
    let previousAdvisory = UserDefaults.standard.object(forKey: advisoryKey)
    UserDefaults.standard.set(true, forKey: advisoryKey)

    defer {
        if let previousAdvisory {
            UserDefaults.standard.set(previousAdvisory, forKey: advisoryKey)
        } else {
            UserDefaults.standard.removeObject(forKey: advisoryKey)
        }
        BridgePaths.overrideHomeForTesting(nil)
        try? fileManager.removeItem(at: root)
    }

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
        description: "PKT-1124 canonical bridge_initialize transport harness",
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
                    connectionState: "local",
                    macToolsAvailable: true,
                    bridgeState: "running",
                    now: Date()
                ),
                mode: .execute,
                includeConstitution: false,
                sessionRegistry: registry,
                receiptStore: receiptStore
            )
            return BridgeInitializeModule.receiptValue(receipt)
        }
    ))
    await router.register(ToolRegistration(
        name: "governance_probe",
        module: "test",
        tier: .open,
        description: "PKT-1124 governance probe",
        inputSchema: .object(["type": .string("object")]),
        handler: { _ in .object(["value": .string("probe-ok")]) }
    ))
    await router.register(ToolRegistration(
        name: "governance_write_probe",
        module: "test",
        tier: .notify,
        description: "PKT-1124 remote governed-write probe",
        inputSchema: .object(["type": .string("object")]),
        handler: { _ in .object(["value": .string("write-ok")]) }
    ))

    let server = SSEServer(
        router: router,
        onToolCall: {},
        sessionTimeout: .infinity,
        sessionStore: SessionPersistenceStore(
            storeURL: root.appendingPathComponent("active-sessions.json")
        ),
        connectionObservability: ConnectionRuntimeObservability(eventLimit: 20)
    )
    try await body(.init(root: root, registry: registry, router: router, server: server))
}
