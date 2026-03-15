// SSETransport.swift — SSE Server Transport on :9700
// KeeprBridge · Server
//
// Built-in SSE support via MCP Swift SDK v0.11.0 StatefulHTTPServerTransport.
// NIO HTTP server with per-session MCP Server instances sharing one ToolRouter.
// PKT-318: V1-10 SSE Transport Implementation
// PKT-332: Added graceful bind-failure handling — SSE is optional, stdio continues
// PKT-336: Added legacy SSE transport (GET /sse + POST /messages) for Notion compatibility
// PKT-338: V1-SSE-FIX — Fixed NIO ChannelPipeline precondition crash by removing actor
//          reference from SSEHTTPHandler. Handler now stores non-actor references only.

import Foundation
import MCP
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOHTTP1

// MARK: - Legacy SSE Bridge (PKT-336)

/// Thread-safe storage for legacy SSE channel references.
/// Handles SSE event writing directly to NIO channels on their event loops.
/// V1: supports multiple concurrent connections mapped by session ID.
public final class LegacySSEBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [String: Channel] = [:]

    /// Register a new SSE stream connection. Returns the assigned session ID.
    func register(channel: Channel) -> String {
        let id = UUID().uuidString
        lock.withLock { channels[id] = channel }
        print("[SSE-Legacy] Client connected — session \(id.prefix(8))… (total: \(channels.count))")
        return id
    }

    /// Remove a disconnected SSE session.
    func remove(sessionID: String) {
        let remaining: Int = lock.withLock {
            channels.removeValue(forKey: sessionID)
            return channels.count
        }
        print("[SSE-Legacy] Client disconnected — session \(sessionID.prefix(8))… (remaining: \(remaining))")
    }

    /// Send an SSE event to the client's stream.
    /// If sessionID is nil and only one client is connected, sends to that client (V1 fallback).
    func sendEvent(sessionID: String?, event: String, data: String) {
        let channel: Channel? = lock.withLock {
            if let id = sessionID, let ch = channels[id] { return ch }
            return channels.count == 1 ? channels.values.first : nil
        }
        guard let channel = channel else {
            print("[SSE-Legacy] No channel for session — event dropped")
            return
        }
        let payload = "event: \(event)\ndata: \(data)\n\n"
        channel.eventLoop.execute {
            var buffer = channel.allocator.buffer(capacity: payload.utf8.count)
            buffer.writeString(payload)
            let part = HTTPServerResponsePart.body(IOData.byteBuffer(buffer))
            channel.writeAndFlush(part, promise: nil)
        }
    }

    /// Number of active legacy SSE connections.
    var activeCount: Int {
        lock.withLock { channels.count }
    }
}

// MARK: - SSE Server

/// Manages an SSE-based MCP server on a configurable port.
/// Each connecting client gets its own MCP session backed by StatefulHTTPServerTransport.
/// All sessions share the same ToolRouter for tool dispatch.
///
/// PKT-336: Also serves legacy SSE transport (GET /sse + POST /messages) for clients
/// like Notion that use the standard split SSE spec instead of Streamable HTTP.
public actor SSEServer {
    private let host: String
    private let port: Int
    private let router: ToolRouter
    private let onToolCall: @MainActor @Sendable () -> Void
    private var channel: Channel?
    private var sessions: [String: SessionContext] = [:]
    private let sessionTimeout: TimeInterval = 3600

    public nonisolated let endpoint: String = "/mcp"

    /// PKT-336: Thread-safe bridge for legacy SSE connections (no actor boundary for channels).
    public nonisolated let legacy = LegacySSEBridge()

    private struct SessionContext {
        let server: Server
        let transport: StatefulHTTPServerTransport
        let createdAt: Date
        var lastAccessedAt: Date
    }

    public init(
        host: String = "127.0.0.1",
        port: Int = 9700,
        router: ToolRouter,
        onToolCall: @escaping @MainActor @Sendable () -> Void
    ) {
        self.host = host
        self.port = port
        self.router = router
        self.onToolCall = onToolCall
    }

    // MARK: - Lifecycle

    /// Start accepting SSE connections. Blocks until the channel is closed.
    /// PKT-332: Graceful bind-failure handling — if the port is in use or bind fails,
    /// logs a clear message and returns without crashing. stdio transport continues.
    public func start() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

        // PKT-338 V1-SSE-FIX: Capture non-actor references BEFORE the bootstrap closure.
        // SSEHTTPHandler must not store a reference to SSEServer (actor) because NIO's
        // childChannelInitializer runs on the channel's event loop, and crossing the actor
        // boundary there triggers NIOCore/ChannelPipeline.swift:159 precondition failure.
        let bridge = self.legacy  // LegacySSEBridge is a plain class, safe to pass
        let endpointPath = self.endpoint  // nonisolated let, safe to capture

        let rpcHandler: @Sendable (Data) async -> Data? = { [weak self] data in
            await self?.processLegacyRPC(data)
        }

        let httpRequestHandler: @Sendable (HTTPRequest) async -> HTTPResponse = { [weak self] request in
            guard let self else {
                return .error(statusCode: 503, .internalError("Server unavailable"))
            }
            return await self.handleHTTPRequest(request)
        }

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(SSEHTTPHandler(
                        legacyBridge: bridge,
                        endpoint: endpointPath,
                        rpcHandler: rpcHandler,
                        httpRequestHandler: httpRequestHandler
                    ))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)

        do {
            let channel = try await bootstrap.bind(host: host, port: port).get()
            self.channel = channel
            print("[SSE] Listening on \(host):\(port)")
            print("[SSE] Streamable HTTP: POST \(endpoint)")
            print("[SSE] Legacy SSE:      GET /sse + POST /messages")

            Task { await sessionCleanupLoop() }

            try await channel.closeFuture.get()
        } catch {
            // PKT-332: Graceful degradation — SSE is optional, stdio still works
            print("[SSE] Port \(port) in use — SSE transport disabled, stdio still active")
            print("[SSE] Bind error detail: \(error) (\(error.localizedDescription))")
        }
    }

    /// Stop the SSE server gracefully.
    public func stop() async {
        for (id, session) in sessions {
            await session.transport.disconnect()
            sessions.removeValue(forKey: id)
        }
        try? await channel?.close()
        channel = nil
        print("[SSE] Server stopped")
    }

    /// Number of active sessions (Streamable HTTP + legacy SSE).
    public var activeSessionCount: Int { sessions.count + legacy.activeCount }

    // MARK: - Request Routing (Streamable HTTP — POST /mcp)

    func handleHTTPRequest(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = request.header(HTTPHeaderName.sessionID)

        // Route to existing session
        if let sessionID, var session = sessions[sessionID] {
            session.lastAccessedAt = Date()
            sessions[sessionID] = session

            let response = await session.transport.handleRequest(request)

            if request.method.uppercased() == "DELETE" && response.statusCode == 200 {
                sessions.removeValue(forKey: sessionID)
                print("[SSE] Session closed: \(sessionID.prefix(8))…")
            }

            return response
        }

        // No session — check for initialize request
        if request.method.uppercased() == "POST",
           let body = request.body,
           isInitializeRequest(body)
        {
            return await createSession(request)
        }

        // Unknown session or missing header
        if sessionID != nil {
            return .error(statusCode: 404, .invalidRequest("Session not found or expired"))
        }
        return .error(statusCode: 400, .invalidRequest("Missing Mcp-Session-Id header"))
    }

    // MARK: - Session Factory (Streamable HTTP)

    private func createSession(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = UUID().uuidString

        let validationPipeline = StandardValidationPipeline(validators: [
            OriginValidator.localhost(),
            AcceptHeaderValidator(mode: .sseRequired),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
            SessionValidator(),
        ])

        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedIDGenerator(id: sessionID),
            validationPipeline: validationPipeline
        )

        let server = Server(
            name: "KeeprSSE",
            version: "0.6.0",
            capabilities: .init(tools: .init())
        )

        let router = self.router
        let onToolCall = self.onToolCall

        // Wire ListTools
        await server.withMethodHandler(ListTools.self) { _ in
            let registrations = await router.allRegistrations()
            return .init(tools: registrations.map { reg in
                Tool(name: reg.name, description: reg.description, inputSchema: reg.inputSchema)
            })
        }

        // Wire CallTool
        await server.withMethodHandler(CallTool.self) { params in
            let toolName = params.name
            let arguments: Value = params.arguments.map { .object($0) } ?? .object([:])

            do {
                let result = try await router.dispatch(toolName: toolName, arguments: arguments)
                await MainActor.run { onToolCall() }

                let text: String
                switch result {
                case .string(let s):
                    text = s
                default:
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
            } catch {
                return .init(content: [.text(.init("Error: \(error.localizedDescription)"))], isError: true)
            }
        }

        do {
            try await server.start(transport: transport)

            sessions[sessionID] = SessionContext(
                server: server,
                transport: transport,
                createdAt: Date(),
                lastAccessedAt: Date()
            )

            print("[SSE] Session created: \(sessionID.prefix(8))… (total: \(sessions.count))")

            let response = await transport.handleRequest(request)

            if case .error = response {
                sessions.removeValue(forKey: sessionID)
                await transport.disconnect()
            }

            return response
        } catch {
            await transport.disconnect()
            return .error(
                statusCode: 500,
                .internalError("Failed to create session: \(error.localizedDescription)")
            )
        }
    }

    // MARK: - Legacy SSE JSON-RPC Processing (PKT-336)

    /// Process a legacy JSON-RPC request (from POST /messages).
    /// Routes through the shared ToolRouter. Returns serialized JSON-RPC response, or nil for notifications.
    func processLegacyRPC(_ body: Data) async -> Data? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let method = json["method"] as? String else {
            return buildRPCError(id: nil, code: -32700, message: "Parse error")
        }

        let requestId = json["id"]

        switch method {
        case "initialize":
            return buildRPCResponse(id: requestId, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:] as [String: Any]] as [String: Any],
                "serverInfo": ["name": "KeeprBridge", "version": "0.6.0"] as [String: Any]
            ] as [String: Any])

        case "notifications/initialized":
            // Notification — no response needed
            return nil

        case "tools/list":
            let regs = await router.allRegistrations()
            let tools: [[String: Any]] = regs.map { reg in
                var t: [String: Any] = [
                    "name": reg.name,
                    "description": reg.description
                ]
                if let data = try? JSONEncoder().encode(reg.inputSchema),
                   let schema = try? JSONSerialization.jsonObject(with: data) {
                    t["inputSchema"] = schema
                }
                return t
            }
            return buildRPCResponse(id: requestId, result: ["tools": tools])

        case "tools/call":
            let params = json["params"] as? [String: Any] ?? [:]
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]

            let argsValue: Value
            if let d = try? JSONSerialization.data(withJSONObject: args),
               let v = try? JSONDecoder().decode(Value.self, from: d) {
                argsValue = v
            } else {
                argsValue = .object([:])
            }

            do {
                let result = try await router.dispatch(toolName: name, arguments: argsValue)
                await MainActor.run { onToolCall() }

                let text: String
                switch result {
                case .string(let s):
                    text = s
                default:
                    let enc = JSONEncoder()
                    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                    text = (try? enc.encode(result))
                        .flatMap { String(data: $0, encoding: .utf8) }
                        ?? String(describing: result)
                }
                return buildRPCResponse(id: requestId, result: [
                    "content": [["type": "text", "text": text] as [String: Any]],
                    "isError": false
                ] as [String: Any])
            } catch {
                return buildRPCResponse(id: requestId, result: [
                    "content": [["type": "text", "text": "Error: \(error.localizedDescription)"] as [String: Any]],
                    "isError": true
                ] as [String: Any])
            }

        case "ping":
            return buildRPCResponse(id: requestId, result: [:] as [String: Any])

        default:
            return buildRPCError(id: requestId, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func buildRPCResponse(id: Any?, result: Any) -> Data? {
        var resp: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id = id { resp["id"] = id }
        return try? JSONSerialization.data(withJSONObject: resp)
    }

    private func buildRPCError(id: Any?, code: Int, message: String) -> Data? {
        var resp: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message] as [String: Any]
        ]
        if let id = id { resp["id"] = id }
        return try? JSONSerialization.data(withJSONObject: resp)
    }

    // MARK: - Session Cleanup

    private func sessionCleanupLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            let now = Date()
            let expired = sessions.filter { _, ctx in
                now.timeIntervalSince(ctx.lastAccessedAt) > sessionTimeout
            }
            for (id, _) in expired {
                if let session = sessions.removeValue(forKey: id) {
                    await session.transport.disconnect()
                    print("[SSE] Session expired: \(id.prefix(8))…")
                }
            }
        }
    }

    // MARK: - Helpers

    private func isInitializeRequest(_ body: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let method = json["method"] as? String else { return false }
        return method == "initialize"
    }

    private struct FixedIDGenerator: SessionIDGenerator {
        let id: String
        func generateSessionID() -> String { id }
    }
}

// MARK: - NIO HTTP Handler

/// PKT-338 V1-SSE-FIX: SSEHTTPHandler no longer stores a reference to SSEServer (actor).
/// Instead it stores non-actor references:
/// - legacyBridge: LegacySSEBridge (plain class with NSLock — safe for NIO event loop)
/// - endpoint: String (nonisolated value)
/// - rpcHandler: closure that calls back into the actor via Task
/// - httpRequestHandler: closure that calls back into the actor via Task
/// This avoids the actor isolation crossing that caused the NIO pipeline precondition failure.
private final class SSEHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let legacyBridge: LegacySSEBridge
    private let endpoint: String
    private let rpcHandler: @Sendable (Data) async -> Data?
    private let httpRequestHandler: @Sendable (HTTPRequest) async -> HTTPResponse

    private struct PendingRequest {
        var head: HTTPRequestHead
        var bodyBuffer: ByteBuffer
    }

    private var pending: PendingRequest?

    /// PKT-336: Track if this channel is a legacy SSE stream for cleanup on disconnect.
    private var legacySessionID: String?

    init(
        legacyBridge: LegacySSEBridge,
        endpoint: String,
        rpcHandler: @escaping @Sendable (Data) async -> Data?,
        httpRequestHandler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse
    ) {
        self.legacyBridge = legacyBridge
        self.endpoint = endpoint
        self.rpcHandler = rpcHandler
        self.httpRequestHandler = httpRequestHandler
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            pending = PendingRequest(
                head: head,
                bodyBuffer: context.channel.allocator.buffer(capacity: 0)
            )
        case .body(var buffer):
            pending?.bodyBuffer.writeBuffer(&buffer)
        case .end:
            guard let req = pending else { return }
            pending = nil
            
            let head = req.head
            let bodyData: Data? = req.bodyBuffer.readableBytes > 0 
                ? req.bodyBuffer.getBytes(at: 0, length: req.bodyBuffer.readableBytes).map { Data($0) }
                : nil
            
            nonisolated(unsafe) let ctx = context
            Task {
                await self.processRequest(head: head, body: bodyData, context: ctx)
            }
        }
    }

    /// PKT-336: Clean up legacy SSE session when channel closes.
    func channelInactive(context: ChannelHandlerContext) {
        if let sessionID = legacySessionID {
            legacyBridge.remove(sessionID: sessionID)
        }
        context.fireChannelInactive()
    }

    private func processRequest(head: HTTPRequestHead, body: Data?, context: ChannelHandlerContext) async {
        let fullURI = head.uri
        let path = fullURI.split(separator: "?").first.map(String.init) ?? fullURI

        // PKT-336: CORS preflight for legacy SSE endpoints
        if head.method == .OPTIONS {
            await writeCORSPreflight(version: head.version, context: context)
            return
        }

        // PKT-336: Legacy SSE stream (GET /sse)
        if head.method == .GET && path == "/sse" {
            await handleLegacySSE(head: head, context: context)
            return
        }

        // PKT-336: Legacy SSE messages (POST /messages)
        if head.method == .POST && path == "/messages" {
            await handleLegacyMessage(head: head, body: body, uri: fullURI, context: context)
            return
        }

        // Streamable HTTP (POST /mcp) — existing behavior
        guard path == endpoint else {
            await writeResponse(
                .error(statusCode: 404, .invalidRequest("Not Found")),
                version: head.version,
                context: context
            )
            return
        }

        var headers: [String: String] = [:]
        for (name, value) in head.headers {
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }

        let httpRequest = HTTPRequest(method: head.method.rawValue, headers: headers, body: body)
        let response = await httpRequestHandler(httpRequest)
        await writeResponse(response, version: head.version, context: context)
    }

    // MARK: - Legacy SSE Handlers (PKT-336)

    /// Handle GET /sse — establish SSE stream, send endpoint event, keep channel alive.
    private func handleLegacySSE(head: HTTPRequestHead, context: ChannelHandlerContext) async {
        // PKT-339: All context.channel access must happen on the event loop.
        // context.channel triggers assertInEventLoop() — accessing it from a Task crashes.
        nonisolated(unsafe) let ctx = context
        ctx.eventLoop.execute {
            let sessionID = self.legacyBridge.register(channel: ctx.channel)
            self.legacySessionID = sessionID

            var responseHead = HTTPResponseHead(version: head.version, status: .ok)
            responseHead.headers.add(name: "Content-Type", value: "text/event-stream")
            responseHead.headers.add(name: "Cache-Control", value: "no-cache")
            responseHead.headers.add(name: "Connection", value: "keep-alive")
            responseHead.headers.add(name: "Access-Control-Allow-Origin", value: "*")
            ctx.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)

            // Send endpoint event: tells client where to POST messages
            let endpointData = "event: endpoint\ndata: /messages?sessionId=\(sessionID)\n\n"
            var buffer = ctx.channel.allocator.buffer(capacity: endpointData.utf8.count)
            buffer.writeString(endpointData)
            ctx.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)

            // Channel stays open — no .end sent. SSE events stream until client disconnects.
        }
    }

    /// Handle POST /messages — process JSON-RPC, send response via SSE stream, return 202.
    private func handleLegacyMessage(
        head: HTTPRequestHead,
        body: Data?,
        uri: String,
        context: ChannelHandlerContext
    ) async {
        // Extract sessionId from query params
        let sessionID: String? = {
            guard let qIdx = uri.firstIndex(of: "?") else { return nil }
            let query = uri[uri.index(after: qIdx)...]
            for param in query.split(separator: "&") {
                let parts = param.split(separator: "=", maxSplits: 1)
                if parts.count == 2 && parts[0] == "sessionId" {
                    return String(parts[1])
                }
            }
            return nil
        }()

        // Extract request body
        guard let bodyData = body else {
            await writeSimpleResponse(statusCode: 400, version: head.version, context: context)
            return
        }

        // PKT-338: Process JSON-RPC through closure (avoids actor reference)
        if let responseData = await rpcHandler(bodyData),
           let responseString = String(data: responseData, encoding: .utf8) {
            legacyBridge.sendEvent(sessionID: sessionID, event: "message", data: responseString)
        }

        // Return 202 Accepted on the POST channel
        await writeSimpleResponse(statusCode: 202, version: head.version, context: context)
    }

    /// Write a simple status-only HTTP response with CORS headers.
    private func writeSimpleResponse(
        statusCode: Int,
        version: HTTPVersion,
        context: ChannelHandlerContext
    ) async {
        nonisolated(unsafe) let ctx = context
        ctx.eventLoop.execute {
            var head = HTTPResponseHead(
                version: version,
                status: HTTPResponseStatus(statusCode: statusCode)
            )
            head.headers.add(name: "Access-Control-Allow-Origin", value: "*")
            ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)
            ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }
    }

    /// Write CORS preflight response for legacy SSE endpoints.
    private func writeCORSPreflight(version: HTTPVersion, context: ChannelHandlerContext) async {
        nonisolated(unsafe) let ctx = context
        ctx.eventLoop.execute {
            var head = HTTPResponseHead(version: version, status: .noContent)
            head.headers.add(name: "Access-Control-Allow-Origin", value: "*")
            head.headers.add(name: "Access-Control-Allow-Methods", value: "GET, POST, OPTIONS")
            head.headers.add(name: "Access-Control-Allow-Headers", value: "Content-Type, Authorization, Mcp-Session-Id")
            head.headers.add(name: "Access-Control-Max-Age", value: "86400")
            ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)
            ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
        }
    }

    // MARK: - Response Writing (Streamable HTTP)

    private func writeResponse(
        _ response: HTTPResponse,
        version: HTTPVersion,
        context: ChannelHandlerContext
    ) async {
        nonisolated(unsafe) let ctx = context
        let eventLoop = ctx.eventLoop

        switch response {
        case .stream(let stream, _):
            eventLoop.execute {
                var head = HTTPResponseHead(
                    version: version,
                    status: HTTPResponseStatus(statusCode: response.statusCode)
                )
                for (name, value) in response.headers {
                    head.headers.add(name: name, value: value)
                }
                ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)
                ctx.flush()
            }

            do {
                for try await chunk in stream {
                    eventLoop.execute {
                        var buffer = ctx.channel.allocator.buffer(capacity: chunk.count)
                        buffer.writeBytes(chunk)
                        ctx.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                    }
                }
            } catch {
                // Stream ended with error — close connection
            }

            eventLoop.execute {
                ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }

        default:
            let bodyData = response.bodyData
            eventLoop.execute {
                var head = HTTPResponseHead(
                    version: version,
                    status: HTTPResponseStatus(statusCode: response.statusCode)
                )
                for (name, value) in response.headers {
                    head.headers.add(name: name, value: value)
                }
                ctx.write(self.wrapOutboundOut(.head(head)), promise: nil)

                if let body = bodyData {
                    var buffer = ctx.channel.allocator.buffer(capacity: body.count)
                    buffer.writeBytes(body)
                    ctx.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                }

                ctx.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }
}
