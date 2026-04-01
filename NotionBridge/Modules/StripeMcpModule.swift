// StripeMcpModule.swift — Dynamic Stripe MCP Tool Registration
// NotionBridge · Modules
// v1.6.0: Replaces native StripeModule with proxy to Stripe's hosted MCP server.
// Tools are discovered dynamically via mcp.stripe.com — no hardcoded tool definitions.

import Foundation
import MCP

// MARK: - StripeMcpModule

public enum StripeMcpModule {
    public static let moduleName = "stripe"

    /// Register all discovered Stripe MCP tools on the given router.
    /// If discovery fails (no API key, network error), logs a warning and registers zero tools.
    /// The app continues to function — tools become available once the API key is configured.
    public static func register(on router: ToolRouter) async {
        do {
            let tools = try await StripeMcpProxy.shared.discoverTools()
            for tool in tools {
                let tier = securityTier(for: tool.name)
                let isDestructive = isDestructiveOperation(tool.name)

                await router.register(ToolRegistration(
                    name: tool.name,
                    module: moduleName,
                    tier: tier,
                    neverAutoApprove: isDestructive,
                    description: tool.description,
                    inputSchema: tool.inputSchema,
                    handler: { [name = tool.name] arguments in
                        do {
                            return try await StripeMcpProxy.shared.callTool(
                                name: name,
                                arguments: arguments
                            )
                        } catch {
                            return .object(["error": .string(error.localizedDescription)])
                        }
                    }
                ))
            }
            if !tools.isEmpty {
                print("[StripeMcpModule] Registered \(tools.count) tools from Stripe MCP server")
            }
        } catch {
            print("[StripeMcpModule] Discovery failed: \(error.localizedDescription). No Stripe tools registered.")
        }
    }

    /// Returns the list of currently discovered tool names (for ConnectionRegistry capabilities).
    public static func discoveredToolNames() async -> [String] {
        do {
            let tools = try await StripeMcpProxy.shared.discoverTools()
            return tools.map { $0.name }
        } catch {
            return []
        }
    }

    // MARK: - Security Tier Mapping

    /// Map tool names to SecurityGate tiers based on operation semantics.
    /// Read → .notify (user sees notification, no approval needed)
    /// Write → .request (user must approve)
    /// Delete → .request + neverAutoApprove (always confirm, never auto-approve)
    private static func securityTier(for toolName: String) -> SecurityTier {
        let lower = toolName.lowercased()

        // Read-only operations
        if lower.hasPrefix("list") || lower.hasPrefix("get") || lower.hasPrefix("retrieve")
            || lower.hasPrefix("search") || lower.hasPrefix("read")
            || lower.contains("_list") || lower.contains("_read") || lower.contains("_get") {
            return .notify
        }

        // Destructive operations
        if lower.hasPrefix("delete") || lower.hasPrefix("remove")
            || lower.hasPrefix("cancel") || lower.hasPrefix("void") {
            return .request
        }

        // Write operations (create, update, set, etc.)
        if lower.hasPrefix("create") || lower.hasPrefix("update")
            || lower.hasPrefix("set") || lower.hasPrefix("add")
            || lower.hasPrefix("modify") || lower.hasPrefix("edit") {
            return .request
        }

        // Default to .request for safety on unknown operations
        return .request
    }

    /// Check if a tool name represents a destructive (irreversible) operation.
    private static func isDestructiveOperation(_ toolName: String) -> Bool {
        let lower = toolName.lowercased()
        return lower.hasPrefix("delete") || lower.hasPrefix("remove")
            || lower.hasPrefix("cancel") || lower.hasPrefix("void")
            || lower.hasPrefix("archive")
    }
}
