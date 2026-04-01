// MCPHTTPValidationTests.swift — tunnel Origin/Host allowlist parsing
import Foundation
import NotionBridgeLib

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
}
