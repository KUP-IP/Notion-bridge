// AuditLog.swift – V1-03/V1-04 Append-Only Structured Audit Log
// TheBridge · Security
// PKT-341: Disk writes now routed through LogManager for crash resilience

import Foundation

// MARK: - Approval Status

public enum ApprovalStatus: String, Sendable, Codable, CaseIterable {
    case approved = "approved"
    case rejected = "rejected"
    case escalated = "escalated"
    case error = "error"
}

// MARK: - Audit Entry

/// A single structured audit log entry.
public struct AuditEntry: Sendable, Codable {
    public let timestamp: Date
    public let toolName: String
    public let tier: SecurityTier
    public let inputSummary: String
    public let outputSummary: String
    public let durationMs: Double
    public let approvalStatus: ApprovalStatus
    public let governed: Bool?
    public let origin: ToolDispatchOrigin?
    public let transportSessionId: String?
    public let governanceNote: String?
    /// Optional discriminator for non-tool-call events such as a pre-dispatch miss.
    public let eventType: String?
    /// Self-reported MCP clientInfo fields; labels, not authenticated identity.
    public let reportedClientName: String?
    public let reportedClientVersion: String?

    public init(
        timestamp: Date,
        toolName: String,
        tier: SecurityTier,
        inputSummary: String,
        outputSummary: String,
        durationMs: Double,
        approvalStatus: ApprovalStatus,
        governed: Bool? = nil,
        origin: ToolDispatchOrigin? = nil,
        transportSessionId: String? = nil,
        governanceNote: String? = nil,
        eventType: String? = nil,
        reportedClientName: String? = nil,
        reportedClientVersion: String? = nil
    ) {
        self.timestamp = timestamp
        self.toolName = toolName
        self.tier = tier
        self.inputSummary = inputSummary
        self.outputSummary = outputSummary
        self.durationMs = durationMs
        self.approvalStatus = approvalStatus
        self.governed = governed
        self.origin = origin
        self.transportSessionId = transportSessionId
        self.governanceNote = governanceNote
        self.eventType = eventType
        self.reportedClientName = reportedClientName
        self.reportedClientVersion = reportedClientVersion
    }
}

// MARK: - AuditLog Actor

/// Append-only structured log for every tool call.
/// In-memory array for fast queries + disk persistence via LogManager.
public actor AuditLog {
    private var entries: [AuditEntry] = []

    public init() {}

    // MARK: Append

    /// Append an entry to the in-memory log and persist to disk via LogManager.
    public func append(_ entry: AuditEntry) {
        entries.append(entry)

        // PKT-341: Persist to ~/Library/Logs/The Bridge/ via LogManager
        Task.detached {
            await LogManager.shared.write(entry)
        }
    }

    // MARK: Read

    /// All entries in memory.
    public func allEntries() -> [AuditEntry] {
        entries
    }

    /// Entries filtered by tool name.
    public func entries(forTool toolName: String) -> [AuditEntry] {
        entries.filter { $0.toolName == toolName }
    }

    /// Entries filtered by tier.
    public func entries(forTier tier: SecurityTier) -> [AuditEntry] {
        entries.filter { $0.tier == tier }
    }

    /// Entries filtered by approval status.
    public func entries(withStatus status: ApprovalStatus) -> [AuditEntry] {
        entries.filter { $0.approvalStatus == status }
    }

    /// Entries filtered by transport/session id.
    public func entries(forSessionID sessionID: String) -> [AuditEntry] {
        entries.filter { $0.transportSessionId == sessionID }
    }

    /// Count of all entries.
    public func count() -> Int {
        entries.count
    }

    // MARK: Clear (V1-04)

    /// Clear all in-memory entries. Does not affect the persistent log file.
    public func clear() {
        entries.removeAll()
    }
}
