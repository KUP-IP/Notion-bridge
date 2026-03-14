// SSETransport.swift — SSE Server Transport on :9700
// KeeprBridge · Server
//
// Built-in SSE support via MCP Swift SDK v0.11.0 StatefulHTTPServerTransport.
// NIO HTTP server with per-session MCP Server instances sharing one ToolRouter.
// PKT-318: V1-10 SSE Transport Implementation

import Foundation
import MCP
@preconcurrency import NIOCore
@preconcurrency import NIOPosix
@preconcurrency import NIOHTTP1

// MARK: - SSE Server

/// Manages an SSE-based MCP server on a configurable port.
/// Each connecting client gets its own MCP session backed by StatefulHTTPServerTransport.
/// All sessions share the same ToolRouter for tool dispatch.
public actor SSEServer {
    private let host: String
    private let port: Int
    private let router: ToolRouter
    private let onToolCall: @MainActor @Sendable () -> Void
    private var channel: Channel?
    private var sessions: [String: SessionContext] = [:]
    private let sessionTimeout: TimeInterval = 3600

    public nonisolated let endpoint: String = "/mcp"

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
    public func start() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(SSEHTTPHandler(sseServer: self))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)

        let channel = try await bootstrap.bind(host: host, port: port).get()
        self.channel = channel
        print("[SSE] Listening on \(host):\(port)\(endpoint)")

        Task { await sessionCleanupLoop() }

        try await channel.closeFuture.get()
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

    /// Number of active sessions.
    public var activeSessionCount: Int { sessions.count }

    // MARK: - Request Routing

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

    // MARK: - Session Factory

    private func createSession(_ request: HTTPRequest) async -> HTTPResponse {
        let sessionID = UUID().uuidString

        // Use a permissive validation pipeline for localhost:
        // - OriginValidator.localhost() with wildcard port (curl doesn't send Origin — that's OK,
        //   OriginValidator only rejects if Origin IS present and doesn't match)
        // - AcceptHeaderValidator, ContentTypeValidator, ProtocolVersionValidator, SessionValidator
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

        // Create a new MCP Server for this session, wired to the shared ToolRouter
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

    /// Detect JSON-RPC initialize request without using package-internal JSONRPCMessageKind.
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

/// Thin NIO adapter: converts between NIO HTTP types and MCP SDK HTTPRequest/HTTPResponse.
/// Delegates all logic to SSEServer actor.
private final class SSEHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let sseServer: SSEServer

    private struct PendingRequest {
        var head: HTTPRequestHead
        var bodyBuffer: ByteBuffer
    }

    private var pending: PendingRequest?

    init(sseServer: SSEServer) {
        self.sseServer = sseServer
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
            nonisolated(unsafe) let ctx = context
            Task {
                await self.processRequest(req, context: ctx)
            }
        }
    }

    private func processRequest(_ req: PendingRequest, context: ChannelHandlerContext) async {
        let path = req.head.uri.split(separator: "?").first.map(String.init) ?? req.head.uri

        guard path == sseServer.endpoint else {
            await writeResponse(
                .error(statusCode: 404, .invalidRequest("Not Found")),
                version: req.head.version,
                context: context
            )
            return
        }

        // Convert NIO request → MCP HTTPRequest
        var headers: [String: String] = [:]
        for (name, value) in req.head.headers {
            if let existing = headers[name] {
                headers[name] = existing + ", " + value
            } else {
                headers[name] = value
            }
        }

        let body: Data?
        if req.bodyBuffer.readableBytes > 0,
           let bytes = req.bodyBuffer.getBytes(at: 0, length: req.bodyBuffer.readableBytes) {
            body = Data(bytes)
        } else {
            body = nil
        }

        let httpRequest = HTTPRequest(method: req.head.method.rawValue, headers: headers, body: body)
        let response = await sseServer.handleHTTPRequest(httpRequest)
        await writeResponse(response, version: req.head.version, context: context)
    }

    private func writeResponse(
        _ response: HTTPResponse,
        version: HTTPVersion,
        context: ChannelHandlerContext
    ) async {
        nonisolated(unsafe) let ctx = context
        let eventLoop = ctx.eventLoop

        switch response {
        case .stream(let stream, _):
            // SSE streaming response — send head, then pipe chunks as they arrive
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
            // Non-streaming response (accepted, ok, data, error)
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
