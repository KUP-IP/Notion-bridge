// AuditLog.swift – V1-03/V1-04 Append-Only Structured Audit Log
// KeeprBridge · Security

import Foundation

// MARK: - Approval Status

public enum ApprovalStatus: String, Sendable, Codable {
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

    public init(
        timestamp: Date,
        toolName: String,
        tier: SecurityTier,
        inputSummary: String,
        outputSummary: String,
        durationMs: Double,
        approvalStatus: ApprovalStatus
    ) {
        self.timestamp = timestamp
        self.toolName = toolName
        self.tier = tier
        self.inputSummary = inputSummary
        self.outputSummary = outputSummary
        self.durationMs = durationMs
        self.approvalStatus = approvalStatus
    }
}

// MARK: - AuditLog Actor

/// Append-only structured log for every tool call.
/// File writes are detached to avoid blocking the main request path.
public actor AuditLog {
    private var entries: [AuditEntry] = []
    private let logFileURL: URL?
    private let encoder: JSONEncoder

    /// Initialize with an optional file path for persistent storage.
    /// If nil, entries are only kept in memory.
    public init(logFilePath: String? = nil) {
        if let path = logFilePath {
            self.logFileURL = URL(fileURLWithPath: path)
        } else {
            self.logFileURL = nil
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        self.encoder = enc
    }

    // MARK: Append

    /// Append an entry to the in-memory log and (async) to the file.
    public func append(_ entry: AuditEntry) {
        entries.append(entry)

        // Non-blocking file write
        if let fileURL = logFileURL {
            let enc = self.encoder
            Task.detached {
                do {
                    let data = try enc.encode(entry)
                    guard var line = String(data: data, encoding: .utf8) else { return }
                    line += "\n"
                    if let lineData = line.data(using: .utf8) {
                        if FileManager.default.fileExists(atPath: fileURL.path) {
                            let handle = try FileHandle(forWritingTo: fileURL)
                            handle.seekToEndOfFile()
                            handle.write(lineData)
                            handle.closeFile()
                        } else {
                            try lineData.write(to: fileURL, options: .atomic)
                        }
                    }
                } catch {
                    // Audit log write failure is non-fatal — log to stderr
                    FileHandle.standardError.write(
                        Data("AuditLog write error: \(error)\n".utf8)
                    )
                }
            }
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

    /// Count of all entries.
    public func count() -> Int {
        entries.count
    }

    // MARK: Clear (V1-04)

    /// Clear all in-memory entries. Does not affect the persistent file log.
    public func clear() {
        entries.removeAll()
    }
}
