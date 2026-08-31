// MCPInboundAudit.swift — issue #189 discriminating inbound counter
// TheBridge · Modules · Auth
//
// Counts Streamable HTTP `/mcp` responses that reached this process.
// Public `/health` exposes only counts + last status + last timestamp
// (no Cf-Ray, path, or body). A Notion "Failed to connect" whose
// mcpInboundCount does not move never reached origin.

import Foundation

public struct MCPInboundSnapshot: Sendable, Equatable {
    public let count: Int
    public let lastStatus: Int?
    public let lastAt: Date?

    public init(count: Int, lastStatus: Int?, lastAt: Date?) {
        self.count = count
        self.lastStatus = lastStatus
        self.lastAt = lastAt
    }
}

public final class MCPInboundAudit: @unchecked Sendable {
    public static let shared = MCPInboundAudit()

    private let lock = NSLock()
    private var count = 0
    private var lastStatus: Int?
    private var lastAt: Date?

    public init() {}

    public func record(status: Int, at date: Date = Date()) {
        lock.withLock {
            count += 1
            lastStatus = status
            lastAt = date
        }
    }

    public func snapshot() -> MCPInboundSnapshot {
        lock.withLock {
            MCPInboundSnapshot(count: count, lastStatus: lastStatus, lastAt: lastAt)
        }
    }

    public func clear() {
        lock.withLock {
            count = 0
            lastStatus = nil
            lastAt = nil
        }
    }
}
