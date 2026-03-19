// ServerManager.swift — Unified MCP Server Lifecycle
// Notion Bridge v1: Manages server setup, module registration, and transport
// Created by PKT-317: Merge NotionBridge app + server into single binary
// Updated by PKT-318: Added SSE transport on :9700
// Updated by PKT-329: Configurable port via NOTION_BRIDGE_PORT env var
// Updated by PKT-341: Version from Bundle (single source of truth), AuditLog simplified
// V1-QUALITY-C2: Added onClientConnected callback for client identification.
//   SSEServer and legacy RPC now extract clientInfo from initialize requests.
// PKT-354: Added ScreenModule registration (screen_capture + screen_ocr). 32 tools across 8 modules.
// PKT-356: Added AccessibilityModule (5 AX tools) + screen recording (2 tools). 39 tools across 9 modules.
// PKT-356-hotfix: Added AppleScriptModule (1 tool) for in-process AppleScript — fixes TCC prompt storm. 40 tools across 10 modules.

import Foundation
import MCP

/// Encapsulates the MCP server lifecycle: component creation, module registration,
/// handler wiring, and transport startup. Designed to run in a background Task
/// from AppDelegate while exposing status to the UI via StatusBarController.
///
/// Pattern: Nudge Server — SwiftUI + async MCP server coexistence.
/// The actor isolates all server state; UI updates flow through a MainActor callback.
public actor ServerManager {
    private var server: Server?
    private var router: ToolRouter?
    private var sseServer: SSEServer?
    private var auditLog: AuditLog?
    private var securityGate: SecurityGate?

    /// The configured SSE port (from NOTION_BRIDGE_PORT env var, default 9700).
    public nonisolated let ssePort: Int

    /// Callback invoked on the main actor after each successful tool dispatch.
    private let onToolCall: @MainActor @Sendable () -> Void

    /// V1-QUALITY-C2: Callback invoked on the main actor when a client connects.
    /// Parameters: (clientName: String, clientVersion: String)
    private let onClientConnected: @MainActor @Sendable (String, String) -> Void

    /// PKT-366 F13: Callback invoked on the main actor when a client disconnects.
    private let onClientDisconnected: @MainActor @Sendable (String) -> Void

    /// - Parameter onToolCall: Closure called on MainActor after each tool call completes.
    ///   Use this to increment StatusBarController.totalToolCalls.
    /// - Parameter onClientConnected: Closure called on MainActor when an MCP client connects.
    ///   Use this to update StatusBarController.connectedClients.
    public init(
        onToolCall: @escaping @MainActor @Sendable () -> Void,
        onClientConnected: @escaping @MainActor @Sendable (String, String) -> Void = { _, _ in },
        onClientDisconnected: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) {
        self.onToolCall = onToolCall
        self.onClientConnected = onClientConnected
        self.onClientDisconnected = onClientDisconnected
        self.ssePort = Int(ProcessInfo.processInfo.environment["NOTION_BRIDGE_PORT"] ?? "") ?? 9700
    }

    // MARK: - Setup

    /// Set up server components, register all modules, wire MCP handlers.
    /// Returns the number of registered tools.
    public func setup() async -> Int {
        // 1. Create core components
        let securityGate = SecurityGate()
        self.securityGate = securityGate
        let auditLog = AuditLog()
        self.auditLog = auditLog
        let router = ToolRouter(securityGate: securityGate, auditLog: auditLog, batchThreshold: 3)
        self.router = router

        // 2. Register modules — GoogleDriveModule added by PKT-368
        await ShellModule.register(on: router)
        await FileModule.register(on: router)
        await SessionModule.register(on: router, auditLog: auditLog)
        await MessagesModule.register(on: router)
        await SystemModule.register(on: router)
        await NotionModule.register(on: router)
        await ScreenModule.register(on: router)
        await ScreenModule.registerRecording(on: router)
        await AccessibilityModule.register(on: router)
        await AppleScriptModule.register(on: router)
        await ChromeModule.register(on: router)
        await SkillsModule.register(on: router)
        await GoogleDriveModule.register(on: router)

        // 3. Register echo tool (backward compatibility from V1-01)
        await router.register(ToolRegistration(
            name: "echo",
            module: "builtin",
            tier: .open,
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

        // 4. Build MCP Server — version from Bundle (single source of truth)
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.0"
        let server = Server(
            name: "NotionBridge",
            version: appVersion,
            capabilities: .init(tools: .init())
        )
        self.server = server

        // 5. Wire ListTools handler — PKT-350: filter disabled tools
        await server.withMethodHandler(ListTools.self) { [router] _ in
            let disabledNames = Set(UserDefaults.standard.stringArray(forKey: "com.notionbridge.disabledTools") ?? [])
            let registrations = await router.enabledRegistrations(disabledNames: disabledNames)
            let tools = registrations.map { reg in
                Tool(
                    name: reg.name,
                    description: reg.description,
                    inputSchema: reg.inputSchema
                )
            }
            return .init(tools: tools)
        }

        // 6. Wire CallTool handler with tool-call notification (uses dispatchFormatted)
        let onToolCall = self.onToolCall
        await server.withMethodHandler(CallTool.self) { [router] params in
            let arguments: Value = params.arguments.map { .object($0) } ?? .object([:])
            let (text, isError) = await router.dispatchFormatted(toolName: params.name, arguments: arguments)
            if !isError { await MainActor.run { onToolCall() } }
            return .init(content: [.text(.init(text))], isError: isError)
        }

        // 7. Create SSE server (configurable port via NOTION_BRIDGE_PORT)
        // V1-QUALITY-C2: Pass onClientConnected callback for client identification
        self.sseServer = SSEServer(
            host: "127.0.0.1",
            port: ssePort,
            router: router,
            onToolCall: onToolCall,
            onClientConnected: onClientConnected,
            onClientDisconnected: onClientDisconnected
        )

        return await router.allRegistrations().count
    }

    // MARK: - Tool Info (PKT-350: F2)

    /// Get all tool metadata for UI display.
    public func allToolInfo() async -> [ToolInfo] {
        guard let router = self.router else { return [] }
        return await router.allRegistrations().map { reg in
            ToolInfo(name: reg.name, module: reg.module, tier: reg.tier.rawValue, description: reg.description)
        }
    }

    // MARK: - Run

    /// Start the stdio transport. Blocks until the server stops or the task is cancelled.
    public func run() async throws {
        guard let server = self.server else {
            throw ServerManagerError.notSetUp
        }
        let transport = StdioTransport()
        try await server.start(transport: transport)
    }

    /// Start the SSE transport. Blocks until the server stops or the task is cancelled.
    public func runSSE() async throws {
        guard let sseServer = self.sseServer else {
            throw ServerManagerError.notSetUp
        }
        try await sseServer.start()
    }

    /// Request notification permission for the same SecurityGate used by ToolRouter.
    public func requestSecurityNotificationPermission() async {
        await securityGate?.requestNotificationPermission()
    }

    /// Stop the SSE server gracefully.
    public func stopSSE() async {
        await sseServer?.stop()
    }
}

// MARK: - Errors

public enum ServerManagerError: Error, LocalizedError {
    case notSetUp

    public var errorDescription: String? {
        switch self {
        case .notSetUp:
            return "ServerManager.setup() must be called before run()"
        }
    }
}
