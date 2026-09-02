// MCPHTTPValidationTests.swift — tunnel Origin/Host allowlist parsing
import Foundation
import MCP
import TheBridgeLib

private let tunnelURLKey = "tunnelURL"

private func withMCPHTTPDefaults(
    tunnelURL: String?,
    mcpBearer: String?,
    _ body: () throws -> Void
) rethrows {
    let ud = UserDefaults.standard
    let prevTunnel = ud.string(forKey: tunnelURLKey)
    let prevBearer = ud.string(forKey: MCPHTTPValidation.mcpBearerTokenUserDefaultsKey)
    if let tunnelURL {
        ud.set(tunnelURL, forKey: tunnelURLKey)
    } else {
        ud.removeObject(forKey: tunnelURLKey)
    }
    if let mcpBearer {
        ud.set(mcpBearer, forKey: MCPHTTPValidation.mcpBearerTokenUserDefaultsKey)
    } else {
        ud.removeObject(forKey: MCPHTTPValidation.mcpBearerTokenUserDefaultsKey)
    }
    defer {
        if let prevTunnel {
            ud.set(prevTunnel, forKey: tunnelURLKey)
        } else {
            ud.removeObject(forKey: tunnelURLKey)
        }
        if let prevBearer {
            ud.set(prevBearer, forKey: MCPHTTPValidation.mcpBearerTokenUserDefaultsKey)
        } else {
            ud.removeObject(forKey: MCPHTTPValidation.mcpBearerTokenUserDefaultsKey)
        }
    }
    try body()
}

func runMCPHTTPValidationTests() async {
    print("\n\u{1F310} MCPHTTPValidation (tunnel / Streamable HTTP)")

    await test("tunnelOriginAllowlist is nil for empty URL") {
        try expect(MCPHTTPValidation.tunnelOriginAllowlist(from: "") == nil)
        try expect(MCPHTTPValidation.tunnelOriginAllowlist(from: "   ") == nil)
    }

    await test("tunnelOriginAllowlist parses https host and origin") {
        guard let r = MCPHTTPValidation.tunnelOriginAllowlist(from: "https://abc.trycloudflare.com/path")
        else {
            throw TestError.assertion("expected non-nil allowlist")
        }
        try expect(r.origins.contains("https://abc.trycloudflare.com"))
        try expect(r.hosts.contains("abc.trycloudflare.com"))
        try expect(r.hosts.contains("abc.trycloudflare.com:*"))
    }

    await test("tunnelOriginAllowlist adds scheme if omitted") {
        guard let r = MCPHTTPValidation.tunnelOriginAllowlist(from: "tunnel.example.com")
        else {
            throw TestError.assertion("expected non-nil")
        }
        try expect(r.origins.contains("https://tunnel.example.com"))
    }

    await test("tunnelOriginAllowlist handles explicit port") {
        guard let r = MCPHTTPValidation.tunnelOriginAllowlist(from: "https://h.example:8443")
        else {
            throw TestError.assertion("expected non-nil")
        }
        try expect(r.origins.contains("https://h.example:8443"))
        try expect(r.hosts.contains("h.example:8443"))
    }

    await test("tunnelOriginAllowlist supports dedicated MCP hostname") {
        guard let r = MCPHTTPValidation.tunnelOriginAllowlist(from: "https://mcp.kup.solutions")
        else {
            throw TestError.assertion("expected non-nil")
        }
        try expect(r.origins.contains("https://mcp.kup.solutions"))
        try expect(r.hosts.contains("mcp.kup.solutions"))
        try expect(r.hosts.contains("mcp.kup.solutions:*"))
    }


    await test("isRemoteTunnelActive is false when tunnel URL empty") {
        try withMCPHTTPDefaults(tunnelURL: nil, mcpBearer: nil) {
            try expect(MCPHTTPValidation.isRemoteTunnelActive() == false)
        }
    }

    await test("streamableHTTPBearerPhase is none when tunnel inactive and no token") {
        try withMCPHTTPDefaults(tunnelURL: nil, mcpBearer: nil) {
            try expect(MCPHTTPValidation.streamableHTTPBearerPhase() == .none)
        }
    }

    await test("remote tunnel active + empty token → remoteTunnelMissingToken") {
        try withMCPHTTPDefaults(tunnelURL: "https://bridge.example.com", mcpBearer: nil) {
            try expect(MCPHTTPValidation.isRemoteTunnelActive() == true)
            try expect(MCPHTTPValidation.resolveMCPBearerToken().isEmpty)
            try expect(MCPHTTPValidation.streamableHTTPBearerPhase() == .remoteTunnelMissingToken)
        }
    }

    await test("remote tunnel active + token → bearerRequired") {
        try withMCPHTTPDefaults(tunnelURL: "https://t.example", mcpBearer: "secret-token") {
            try expect(MCPHTTPValidation.streamableHTTPBearerPhase() == .bearerRequired("secret-token"))
        }
    }

    await test("tunnel inactive + token → optional bearer (bearerRequired phase)") {
        try withMCPHTTPDefaults(tunnelURL: nil, mcpBearer: "local-only") {
            try expect(MCPHTTPValidation.isRemoteTunnelActive() == false)
            try expect(MCPHTTPValidation.streamableHTTPBearerPhase() == .bearerRequired("local-only"))
        }
    }

    await test("invalid tunnel URL string does not activate remote (no extra allowlist)") {
        try withMCPHTTPDefaults(tunnelURL: "not a url !!!", mcpBearer: nil) {
            try expect(MCPHTTPValidation.tunnelOriginAllowlist(from: "not a url !!!") == nil)
            try expect(MCPHTTPValidation.isRemoteTunnelActive() == false)
            try expect(MCPHTTPValidation.streamableHTTPBearerPhase() == .none)
        }
    }

    // MARK: - Three-state remote access status tests

    await test("three-state: no URL → notConfigured (phase .none)") {
        try withMCPHTTPDefaults(tunnelURL: nil, mcpBearer: nil) {
            try expect(MCPHTTPValidation.isRemoteTunnelActive() == false)
            try expect(MCPHTTPValidation.streamableHTTPBearerPhase() == .none)
        }
    }

    await test("three-state: URL + no token → misconfigured (phase .remoteTunnelMissingToken)") {
        try withMCPHTTPDefaults(tunnelURL: "https://mcp.example.com", mcpBearer: nil) {
            try expect(MCPHTTPValidation.isRemoteTunnelActive() == true)
            try expect(MCPHTTPValidation.streamableHTTPBearerPhase() == .remoteTunnelMissingToken)
        }
    }

    await test("three-state: URL + token → active (phase .bearerRequired)") {
        try withMCPHTTPDefaults(tunnelURL: "https://mcp.example.com", mcpBearer: "test-token-123") {
            try expect(MCPHTTPValidation.isRemoteTunnelActive() == true)
            try expect(MCPHTTPValidation.streamableHTTPBearerPhase() == .bearerRequired("test-token-123"))
        }
    }

    await test("three-state: empty-string token treated as missing") {
        try withMCPHTTPDefaults(tunnelURL: "https://mcp.example.com", mcpBearer: "   ") {
            try expect(MCPHTTPValidation.resolveMCPBearerToken().isEmpty)
            try expect(MCPHTTPValidation.streamableHTTPBearerPhase() == .remoteTunnelMissingToken)
        }
    }

    await test("constant-time comparison: equal strings") {
        try expect(MCPHTTPValidation.constantTimeEqual("abc123", "abc123") == true)
    }

    await test("constant-time comparison: unequal strings") {
        try expect(MCPHTTPValidation.constantTimeEqual("abc123", "abc124") == false)
    }

    await test("constant-time comparison: different lengths") {
        try expect(MCPHTTPValidation.constantTimeEqual("short", "longer-string") == false)
    }

    // PKT-810 R5 — legacy bearer phase is origin-split too: with `tunnelURL` + a
    // static bearer configured (the cloud-connector operator install) and NO
    // connector OAuth path (connectorAuth == nil), a DIRECT-LOOPBACK /mcp request
    // is served token-free, while a REMOTE (Cloudflare-tunnel) request fails
    // remote OAuth readiness instead of falling through as a local/legacy session.
    await test("StreamableHTTP: loopback exempt; tunnel without connector auth fails OAuth readiness") {
        let ud = UserDefaults.standard
        let prevTunnel = ud.string(forKey: tunnelURLKey)
        let prevBearer = ud.string(forKey: MCPHTTPValidation.mcpBearerTokenUserDefaultsKey)
        ud.set("https://mcp.example.com/mcp", forKey: tunnelURLKey)
        ud.set("legacy-static-secret", forKey: MCPHTTPValidation.mcpBearerTokenUserDefaultsKey)
        defer {
            if let prevTunnel { ud.set(prevTunnel, forKey: tunnelURLKey) }
            else { ud.removeObject(forKey: tunnelURLKey) }
            if let prevBearer { ud.set(prevBearer, forKey: MCPHTTPValidation.mcpBearerTokenUserDefaultsKey) }
            else { ud.removeObject(forKey: MCPHTTPValidation.mcpBearerTokenUserDefaultsKey) }
        }
        // No connectorAuth (BRIDGE_ENABLE_HTTP unset). Loopback remains local and
        // token-free; tunnel-origin traffic must now fail remote OAuth readiness
        // before it can fall through to a local/legacy auth model.
        let server = SSEServer(
            router: ToolRouter(securityGate: SecurityGate(approvalProvider: TestSecurityApprovalProvider()), auditLog: AuditLog()),
            onToolCall: {}
        )
        let initBody = Data("""
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"\(BridgeConstants.mcpProtocolVersion)","capabilities":{},"clientInfo":{"name":"legacy-loopback","version":"t"}}}
        """.utf8)
        let localHeaders = [
            "Host": "127.0.0.1:\(BridgeConstants.defaultSSEPort)",
            "Accept": "application/json, text/event-stream",
            "Content-Type": "application/json",
        ]
        // LOOPBACK (no Cf header) + NO bearer ⇒ served token-free (not 401).
        let localResp = await server.handleHTTPRequest(
            HTTPRequest(method: "POST", headers: localHeaders, body: initBody))
        try expect(localResp.statusCode != 401,
                   "loopback must be exempt from the legacy static bearer, got \(localResp.statusCode)")
        try expect(localResp.headers[HTTPHeaderName.sessionID] != nil,
                   "loopback initialize must mint a session id token-free")
        // TUNNEL (Cf header) + NO connector auth ⇒ 503 fail-closed readiness.
        var tunnelHeaders = localHeaders
        tunnelHeaders["Cf-Connecting-Ip"] = "203.0.113.7"
        let tunnelResp = await server.handleHTTPRequest(
            HTTPRequest(method: "POST", headers: tunnelHeaders, body: initBody))
        try expect(tunnelResp.statusCode == 503,
                   "tunnel must fail remote OAuth readiness without connector auth, got \(tunnelResp.statusCode)")
        let body = String(data: tunnelResp.bodyData ?? Data(), encoding: .utf8) ?? ""
        try expect(body.contains("auth_failed") && body.contains("correlation_id="),
                   "503 body must stay coarse and correlated, got: \(body)")
        try expect(!body.contains("Remote OAuth") && !body.contains("oauth_inactive"),
                   "tunnel body must not disclose the detailed readiness reason, got: \(body)")
    }

    await test("MCPInboundAudit counts only recorded /mcp replies") {
        let audit = MCPInboundAudit()
        let empty = audit.snapshot()
        try expect(empty.count == 0)
        try expect(empty.lastStatus == nil)
        try expect(empty.lastAt == nil)
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        audit.record(status: 406, at: t1)
        audit.record(status: 200, at: t1.addingTimeInterval(1))
        let snap = audit.snapshot()
        try expect(snap.count == 2)
        try expect(snap.lastStatus == 200)
        try expect(snap.lastAt == t1.addingTimeInterval(1))
        audit.clear()
        try expect(audit.snapshot().count == 0)
    }

    await test("health JSON names mcpInboundCount without Cf-Ray") {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("TheBridge/Server/SSETransport.swift"),
            encoding: .utf8
        )
        try expect(source.contains("mcpInboundCount"),
                   "/health must expose mcpInboundCount for the #189 discriminating test")
        try expect(source.contains("MCPInboundAudit.shared.record(status:"),
                   "/mcp replies that reach origin must increment the inbound audit")
        try expect(!source.contains("mcpInboundCfRay"),
                   "public /health must not expose Cf-Ray")
    }
}
