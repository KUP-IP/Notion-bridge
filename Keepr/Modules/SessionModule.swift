// SessionModule.swift – V1-04 Session Tools (complete)
// KeeprBridge · Modules

import Foundation
import MCP

// MARK: - SessionModule

/// Provides session tools: tools_list (V1-03), session_info (V1-04), session_clear (V1-04).
public enum SessionModule {

    public static let moduleName = "session"

    /// Session start timestamp for uptime tracking.
    private static let sessionStartTime = Date()

    /// Register all session module tools on the given router.
    /// V1-04: now accepts auditLog for session_info and session_clear.
    public static func register(on router: ToolRouter, auditLog: AuditLog) async {

        // tools_list – 🟢 Green (V1-03, preserved)
        await router.register(ToolRegistration(
            name: "tools_list",
            module: moduleName,
            tier: .open,
            description: "Returns the live tool registry. Lists all registered tools with their name, module, tier, description, and input schema. Supports optional module filter.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "module": .object([
                        "type": .string("string"),
                        "description": .string("Optional module name to filter by. If omitted, returns all tools.")
                    ])
                ]),
                "required": .array([])
            ]),
            handler: { arguments in
                let moduleFilter: String?
                if case .object(let args) = arguments,
                   case .string(let m) = args["module"] {
                    moduleFilter = m
                } else {
                    moduleFilter = nil
                }

                let registrations: [ToolRegistration]
                if let filter = moduleFilter {
                    registrations = await router.registrations(forModule: filter)
                } else {
                    registrations = await router.allRegistrations()
                }

                let toolEntries: [Value] = registrations.map { reg in
                    let inputs: Value
                    if case .object(let schema) = reg.inputSchema,
                       case .object(let props) = schema["properties"] {
                        let required: [String]
                        if case .array(let reqArr) = schema["required"] {
                            required = reqArr.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
                        } else {
                            required = []
                        }
                        let inputItems: [Value] = props.map { key, val in
                            let propType: String
                            if case .object(let propDict) = val,
                               case .string(let t) = propDict["type"] {
                                propType = t
                            } else {
                                propType = "unknown"
                            }
                            return .object([
                                "name": .string(key),
                                "type": .string(propType),
                                "required": .bool(required.contains(key))
                            ])
                        }
                        inputs = .array(inputItems)
                    } else {
                        inputs = .array([])
                    }

                    return .object([
                        "name": .string(reg.name),
                        "module": .string(reg.module),
                        "tier": .string(reg.tier.rawValue),
                        "description": .string(reg.description),
                        "inputs": inputs,
                        "output": .string("Value")
                    ])
                }

                return .array(toolEntries)
            }
        ))

        // session_info – 🟢 Green (V1-04)
        await router.register(ToolRegistration(
            name: "session_info",
            module: moduleName,
            tier: .open,
            description: "Returns session information: uptime, connections, toolCalls (from audit log), activeClients, and auditLogSize.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([])
            ]),
            handler: { _ in
                let uptime = Date().timeIntervalSince(sessionStartTime)
                let auditSize = await auditLog.count()
                let hours = Int(uptime) / 3600
                let minutes = (Int(uptime) % 3600) / 60
                let seconds = Int(uptime) % 60
                let uptimeStr = String(format: "%dh %dm %ds", hours, minutes, seconds)

                return .object([
                    "uptime": .string(uptimeStr),
                    "uptimeSeconds": .double(uptime),
                    "connections": .int(1),
                    "toolCalls": .int(auditSize),
                    "activeClients": .int(1),
                    "auditLogSize": .int(auditSize)
                ])
            }
        ))

        // session_clear – 🟠 Orange (V1-04)
        await router.register(ToolRegistration(
            name: "session_clear",
            module: moduleName,
            tier: .notify,
            description: "Clear session state (audit log entries). Requires confirm: true parameter. Returns previous uptime and audit log size before clearing.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "confirm": .object([
                        "type": .string("boolean"),
                        "description": .string("Must be true to confirm session clear")
                    ])
                ]),
                "required": .array([.string("confirm")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .bool(let confirm) = args["confirm"],
                      confirm else {
                    return .object([
                        "error": .string("session_clear requires confirm: true"),
                        "cleared": .bool(false)
                    ])
                }

                let previousUptime = Date().timeIntervalSince(sessionStartTime)
                let previousAuditSize = await auditLog.count()
                await auditLog.clear()

                return .object([
                    "cleared": .bool(true),
                    "previousUptimeSeconds": .double(previousUptime),
                    "previousAuditLogSize": .int(previousAuditSize)
                ])
            }
        ))
    }
}
