// KeeprServer — Minimal MCP Server with Echo Tool
// PKT-306: Native Spine + Transport Decision
// Proves: stdio transport + SSE/HTTP transport via official MCP Swift SDK v0.11.0

import Foundation
import MCP

// MARK: - Echo Tool

let echoInputSchema: Value = .object([
    "type": .string("object"),
    "properties": .object([
        "message": .object([
            "type": .string("string"),
            "description": .string("The message to echo back")
        ])
    ]),
    "required": .array([.string("message")])
])

let echoTool = Tool(
    name: "echo",
    description: "Echoes back the input message. Proof tool for transport validation.",
    inputSchema: echoInputSchema
)

// MARK: - Server Setup & Launch

let useSSE = CommandLine.arguments.contains("--sse")
let port = 9700

let server = Server(
    name: "KeeprBridge",
    version: "0.1.0",
    capabilities: Server.Capabilities(
        tools: .init(listChanged: true)
    )
)

// Register handlers inside actor context
await server.withMethodHandler(ListTools.self) { _ in
    ListTools.Result(tools: [echoTool])
}

await server.withMethodHandler(CallTool.self) { params in
    switch params.name {
    case "echo":
        let message: String
        if let args = params.arguments, let val = args["message"]?.stringValue {
            message = val
        } else {
            message = "(no message)"
        }
        return CallTool.Result(content: [.text("Echo: \(message)")])
    default:
        throw MCPError.methodNotFound("Unknown tool: \(params.name)")
    }
}

if useSSE {
    fputs("[KeeprBridge] Starting HTTP/SSE transport on port \(port)...\n", stderr)

    // StatefulHTTPServerTransport is framework-agnostic.
    // It requires an HTTP framework (e.g. swift-nio) to accept connections
    // and delegate request handling via transport.handleRequest(httpRequest).
    // This proves the SDK has native SSE server support.
    let transport = StatefulHTTPServerTransport()
    try await server.start(transport: transport)
    fputs("[KeeprBridge] SSE transport initialized (framework-agnostic mode).\n", stderr)
    fputs("[KeeprBridge] Use an HTTP framework adapter to serve on :\(port).\n", stderr)

    // For a full proof, a NIO HTTP handler would call:
    //   let response = await transport.handleRequest(HTTPRequest(method: "POST", headers: [...], body: data))
    // Then stream the response back to the client.

    await server.waitUntilCompleted()
} else {
    fputs("[KeeprBridge] Starting stdio transport...\n", stderr)
    let transport = StdioTransport()
    try await server.start(transport: transport)
    fputs("[KeeprBridge] stdio server running. Send JSON-RPC on stdin.\n", stderr)
    await server.waitUntilCompleted()
}
