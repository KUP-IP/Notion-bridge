// main.swift – V1-04 KeeprServer Entry Point
// KeeprBridge · Server
//
// Pipeline: Transport -> ToolRouter -> SecurityGate -> Handler -> AuditLog -> Response

import Foundation
import MCP
import KeeprLib

// MARK: - Bootstrap

// 1. Create core components
let securityGate = SecurityGate()
let auditLog = AuditLog(logFilePath: nil) // In-memory for now; file path configurable later
let router = ToolRouter(securityGate: securityGate, auditLog: auditLog, batchThreshold: 3)

// 2. Register modules (V1-04: Shell + File + Session complete)
await ShellModule.register(on: router)
await FileModule.register(on: router)
await SessionModule.register(on: router, auditLog: auditLog)
await MessagesModule.register(on: router)
await SystemModule.register(on: router)
await NotionModule.register(on: router)

// 3. Register the V1-01 echo tool (preserved for backward compatibility)
await router.register(ToolRegistration(
    name: "echo",
    module: "builtin",
    tier: .green,
    description: "Echoes back the input message. Useful for connectivity testing.",
    inputSchema: .object([
        "type": .string("object"),
        "properties": .object([
            "message": .object([
                "type": .string("string"),
                "description": .string("The message to echo back")
            ])
        ]),
        "required": .array([.string("message")])
    ]),
    handler: { arguments in
        if case .object(let args) = arguments,
           case .string(let message) = args["message"] {
            return .object(["echo": .string(message)])
        }
        return .object(["error": .string("Missing 'message' parameter")])
    }
))

// 4. Build MCP Server with tool handlers wired through the router pipeline
let server = Server(
    name: "KeeprServer",
    version: "0.5.0",
    capabilities: .init(tools: .init())
)

// ListTools handler: expose all registered tools as MCP Tool definitions
await server.withMethodHandler(ListTools.self) { _ in
    let registrations = await router.allRegistrations()
    let tools = registrations.map { reg in
        Tool(
            name: reg.name,
            description: reg.description,
            inputSchema: reg.inputSchema
        )
    }
    return .init(tools: tools)
}

// CallTool handler: dispatch through ToolRouter pipeline
await server.withMethodHandler(CallTool.self) { params in
    let toolName = params.name
    let arguments: Value = {
        if let args = params.arguments {
            return .object(args)
        } else {
            return .object([:])
        }
    }()

    do {
        let result = try await router.dispatch(toolName: toolName, arguments: arguments)

        // Convert result Value to CallTool response content
        let text: String
        switch result {
        case .string(let s):
            text = s
        default:
            // Serialize to JSON for structured results
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(result),
               let json = String(data: data, encoding: .utf8) {
                text = json
            } else {
                text = String(describing: result)
            }
        }

        return .init(content: [.text(.init(text))])
    } catch let error as ToolRouterError {
        return .init(content: [.text(.init("Error: \(error.localizedDescription)"))], isError: true)
    } catch {
        return .init(content: [.text(.init("Error: \(error.localizedDescription)"))], isError: true)
    }
}

// 5. Start transport (stdio mode; SSE/HTTP requires NIO adapter, deferred)
let transport = StdioTransport()
try await server.start(transport: transport)
