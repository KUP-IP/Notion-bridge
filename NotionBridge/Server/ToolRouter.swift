// ToolRouter.swift – Tool Registration & Dispatch
// NotionBridge · Server
// PKT-376: Updated for 3-tier security model + .handoff support

import Foundation
import MCP

// MARK: - Tool Registration

/// Metadata + handler for a single registered tool.
public struct ToolRegistration: Sendable {
    public let name: String
    public let module: String
    public let tier: SecurityTier
    public let neverAutoApprove: Bool
    public let description: String
    public let inputSchema: Value
    public let handler: @Sendable (Value) async throws -> Value

    public init(
        name: String,
        module: String,
        tier: SecurityTier,
        neverAutoApprove: Bool = false,
        description: String,
        inputSchema: Value,
        handler: @escaping @Sendable (Value) async throws -> Value
    ) {
        self.name = name
        self.module = module
        self.tier = tier
        self.neverAutoApprove = neverAutoApprove
        self.description = description
        self.inputSchema = inputSchema
        self.handler = handler
    }
}

// PKT-373 P1-5: ExecutionPlanEntry removed (was dead code)

// MARK: - ToolRouter Actor

/// Central dispatch hub. Every tool call flows through here.
public actor ToolRouter {
    private var registry: [String: ToolRegistration] = [:]
    private let securityGate: SecurityGate
    private let auditLog: AuditLog
    public init(
        securityGate: SecurityGate,
        auditLog: AuditLog
    ) {
        self.securityGate = securityGate
        self.auditLog = auditLog
    }

    // MARK: Registration

    /// Register a tool. Overwrites any existing registration with the same name.
    public func register(_ tool: ToolRegistration) {
        registry[tool.name] = tool
    }

    /// Remove a tool registration by name.
    public func deregister(name: String) {
        registry.removeValue(forKey: name)
    }

    /// All currently registered tools.
    public func allRegistrations() -> [ToolRegistration] {
        Array(registry.values)
    }

    /// Registrations filtered by module name.
    public func registrations(forModule module: String) -> [ToolRegistration] {
        registry.values.filter { $0.module == module }
    }

    /// Enabled registrations excluding disabled tools (PKT-350: F2).
    public func enabledRegistrations(disabledNames: Set<String>) -> [ToolRegistration] {
        registry.values.filter { !disabledNames.contains($0.name) }
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

        if tool.module == CredentialModule.moduleName && !CredentialsFeature.isEnabled {
            throw ToolRouterError.invalidArguments(
                toolName: toolName,
                reason: "Credentials are disabled. Turn on “Keychain credentials” in Notion Bridge Settings → Credentials."
            )
        }

        // F1: Resolve effective tier — user override takes precedence over registered default.
        // Overrides are stored as [String: String] in UserDefaults by ToolRegistryView.
        let overrides = UserDefaults.standard.dictionary(
            forKey: BridgeDefaults.tierOverrides
        ) as? [String: String] ?? [:]
        let overriddenTier = overrides[toolName].flatMap { SecurityTier(rawValue: $0) } ?? tool.tier
        let effectiveTier: SecurityTier = tool.neverAutoApprove ? .request : overriddenTier

        // SecurityGate enforcement (async for request-tier approvals)
        let decision = await securityGate.enforce(
            toolName: toolName,
            tier: effectiveTier,
            neverAutoApprove: tool.neverAutoApprove,
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
                tier: effectiveTier,
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
                tier: effectiveTier,
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

            // F2: Fire-and-forget notification for Notify-tier executions.
            // Runs after successful execution — informational only.
            if effectiveTier == .notify {
                await securityGate.sendExecutionNotification(toolName: toolName)
            }

            let duration = ContinuousClock.now - start
            let ms = Double(duration.components.attoseconds) / 1_000_000_000_000_000.0
                + Double(duration.components.seconds) * 1000.0
            await auditLog.append(AuditEntry(
                timestamp: Date(),
                toolName: toolName,
                tier: effectiveTier,
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
                tier: effectiveTier,
                inputSummary: stringifySummary(arguments),
                outputSummary: "ERROR: \(error.localizedDescription)",
                durationMs: ms,
                approvalStatus: .error
            ))
            throw error
        }
    }

    // PKT-373 P1-5: batchGate removed (was dead code, never wired into dispatch pipeline)

    // MARK: CallTool Dispatch Helper

    /// Dispatch a tool call and format the result as a CallTool-compatible tuple.
    /// Centralizes the dispatch → JSON encode → text conversion pipeline
    /// used by ServerManager (stdio), SSEServer (Streamable HTTP), and legacy RPC.
    /// Returns: (text: String, isError: Bool)
    public func dispatchFormatted(toolName: String, arguments: Value) async -> (text: String, isError: Bool) {
        do {
            let result = try await dispatch(toolName: toolName, arguments: arguments)
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
            return (text: text, isError: false)
        } catch {
            return (text: "Error: \(error.localizedDescription)", isError: true)
        }
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
    case invalidArguments(toolName: String, reason: String)
    case securityRejection(toolName: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .unknownTool(let name):
            return "Unknown tool: \(name)"
        case .invalidArguments(let name, let reason):
            return "\(name): \(reason)"
        case .securityRejection(let name, let reason):
            return "Security gate rejected \(name): \(reason)"
        }
    }
}
