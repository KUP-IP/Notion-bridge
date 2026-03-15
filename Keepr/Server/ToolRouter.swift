// ToolRouter.swift – V1-03 Tool Registration & Dispatch
// KeeprBridge · Server
// V1-QUALITY-C1: Updated for 2-tier security model + .handoff support

import Foundation
import MCP

// MARK: - Tool Registration

/// Metadata + handler for a single registered tool.
public struct ToolRegistration: Sendable {
    public let name: String
    public let module: String
    public let tier: SecurityTier
    public let description: String
    public let inputSchema: Value
    public let handler: @Sendable (Value) async throws -> Value

    public init(
        name: String,
        module: String,
        tier: SecurityTier,
        description: String,
        inputSchema: Value,
        handler: @escaping @Sendable (Value) async throws -> Value
    ) {
        self.name = name
        self.module = module
        self.tier = tier
        self.description = description
        self.inputSchema = inputSchema
        self.handler = handler
    }
}

/// A single entry in a batch execution plan.
public struct ExecutionPlanEntry: Sendable {
    public let toolName: String
    public let tier: SecurityTier
    public let inputSummary: String

    public init(toolName: String, tier: SecurityTier, inputSummary: String) {
        self.toolName = toolName
        self.tier = tier
        self.inputSummary = inputSummary
    }
}

// MARK: - ToolRouter Actor

/// Central dispatch hub. Every tool call flows through here.
public actor ToolRouter {
    private var registry: [String: ToolRegistration] = [:]
    private let securityGate: SecurityGate
    private let auditLog: AuditLog
    public var batchThreshold: Int

    public init(
        securityGate: SecurityGate,
        auditLog: AuditLog,
        batchThreshold: Int = 3
    ) {
        self.securityGate = securityGate
        self.auditLog = auditLog
        self.batchThreshold = batchThreshold
    }

    // MARK: Registration

    /// Register a tool. Overwrites any existing registration with the same name.
    public func register(_ tool: ToolRegistration) {
        registry[tool.name] = tool
    }

    /// All currently registered tools.
    public func allRegistrations() -> [ToolRegistration] {
        Array(registry.values)
    }

    /// Registrations filtered by module name.
    public func registrations(forModule module: String) -> [ToolRegistration] {
        registry.values.filter { $0.module == module }
    }

    // MARK: Dispatch

    /// Dispatch a single tool call through the security -> execute -> audit pipeline.
    /// Returns the tool result or throws on rejection / handler error.
    /// For nuclear commands, returns a handoff response (not an error).
    public func dispatch(toolName: String, arguments: Value) async throws -> Value {
        let start = ContinuousClock.now

        guard let tool = registry[toolName] else {
            throw ToolRouterError.unknownTool(toolName)
        }

        // SecurityGate enforcement (now async for notification approval)
        let decision = await securityGate.enforce(
            toolName: toolName,
            tier: tool.tier,
            arguments: arguments
        )

        switch decision {
        case .allow:
            break // proceed to execution

        case .reject(let reason):
            let duration = ContinuousClock.now - start
            let ms = Double(duration.components.attoseconds) / 1_000_000_000_000_000.0
                + Double(duration.components.seconds) * 1000.0
            await auditLog.append(AuditEntry(
                timestamp: Date(),
                toolName: toolName,
                tier: tool.tier,
                inputSummary: stringifySummary(arguments),
                outputSummary: "REJECTED: \(reason)",
                durationMs: ms,
                approvalStatus: .rejected
            ))
            throw ToolRouterError.securityRejection(toolName: toolName, reason: reason)

        case .handoff(let command, let explanation, let warning):
            // Nuclear handoff: return a helpful response, NOT an error
            let duration = ContinuousClock.now - start
            let ms = Double(duration.components.attoseconds) / 1_000_000_000_000_000.0
                + Double(duration.components.seconds) * 1000.0
            await auditLog.append(AuditEntry(
                timestamp: Date(),
                toolName: toolName,
                tier: tool.tier,
                inputSummary: stringifySummary(arguments),
                outputSummary: "HANDOFF: \(command)",
                durationMs: ms,
                approvalStatus: .escalated
            ))
            return .object([
                "status": .string("handoff"),
                "command": .string(command),
                "explanation": .string(explanation),
                "warning": .string(warning),
                "action_required": .string("Run this command manually in Terminal.app")
            ])
        }

        // Execute handler
        do {
            let result = try await tool.handler(arguments)
            let duration = ContinuousClock.now - start
            let ms = Double(duration.components.attoseconds) / 1_000_000_000_000_000.0
                + Double(duration.components.seconds) * 1000.0
            await auditLog.append(AuditEntry(
                timestamp: Date(),
                toolName: toolName,
                tier: tool.tier,
                inputSummary: stringifySummary(arguments),
                outputSummary: stringifySummary(result),
                durationMs: ms,
                approvalStatus: .approved
            ))
            return result
        } catch {
            let duration = ContinuousClock.now - start
            let ms = Double(duration.components.attoseconds) / 1_000_000_000_000_000.0
                + Double(duration.components.seconds) * 1000.0
            await auditLog.append(AuditEntry(
                timestamp: Date(),
                toolName: toolName,
                tier: tool.tier,
                inputSummary: stringifySummary(arguments),
                outputSummary: "ERROR: \(error.localizedDescription)",
                durationMs: ms,
                approvalStatus: .error
            ))
            throw error
        }
    }

    // MARK: Batch Gate

    /// Evaluate whether a set of planned calls exceeds the batch threshold.
    /// Returns an execution plan if the threshold is met or exceeded.
    public func batchGate(planned: [ExecutionPlanEntry]) -> [ExecutionPlanEntry]? {
        if planned.count >= batchThreshold {
            return planned
        }
        return nil
    }

    // MARK: Helpers

    private func stringifySummary(_ value: Value) -> String {
        switch value {
        case .string(let s):
            return s.count > 200 ? String(s.prefix(200)) + "..." : s
        case .object(let dict):
            let keys = dict.keys.sorted().joined(separator: ", ")
            return "{\(keys)}"
        case .array(let arr):
            return "[\(arr.count) items]"
        case .int(let i):
            return String(i)
        case .double(let d):
            return String(d)
        case .bool(let b):
            return String(b)
        case .null:
            return "null"
        case .data:
            return "<binary data>"
        }
    }
}

// MARK: - Errors

public enum ToolRouterError: Error, LocalizedError {
    case unknownTool(String)
    case securityRejection(toolName: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            return "Unknown tool: \(name)"
        case .securityRejection(let name, let reason):
            return "Security gate rejected \(name): \(reason)"
        }
    }
}
