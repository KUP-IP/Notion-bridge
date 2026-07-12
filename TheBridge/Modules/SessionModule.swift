// SessionModule.swift – V1-04 Session Tools (complete)
// TheBridge · Modules

import Foundation
import MCP

// MARK: - SessionModule

/// Provides session tools: tools_list, session_info, audit_recent, session_clear.
public enum SessionModule {

    public static let auditRecentDefaultLimit = 20
    public static let auditRecentMaximumLimit = 100

    public struct RuntimeDiagnostics: Sendable {
        public let connections: Int
        public let activeClients: Int

        public init(connections: Int, activeClients: Int) {
            self.connections = connections
            self.activeClients = activeClients
        }
    }

    public static let moduleName = "session"

    /// Register all session module tools on the given router.
    /// V1-04: now accepts auditLog for session_info and session_clear.
    public static func register(
        on router: ToolRouter,
        auditLog: AuditLog,
        diagnosticsProvider: (@Sendable () async -> RuntimeDiagnostics)? = nil
    ) async {
        // Captured HERE (register() runs once, at server boot) rather than as a
        // lazily-initialized `static let` referenced only inside the handler
        // closures below — a lazy static's first-access moment is whenever a
        // client first calls session_info/session_clear, not process launch,
        // so uptime silently measured "time since first call" instead of
        // "time since boot".
        let sessionStartTime = Date()

        // tools_list – open (V1-03, preserved)
        await router.register(ToolRegistration(
            name: "tools_list",
            module: moduleName,
            tier: .open,
            description: "List MCP tools the bridge exposes. COMPACT by default (name, module, tier, one-line summary) to stay well under client output-token caps. Pass `module` to scope to one family, or `detail:true` for full descriptions + input schemas.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "module": .object([
                        "type": .string("string"),
                        "description": .string("Optional module name to filter by. If omitted, returns all tools. Scoping to a module implies detail:true.")
                    ]),
                    "detail": .object([
                        "type": .string("boolean"),
                        "description": .string("When true (or when `module` is set) each entry carries full description, input schema, tier, and output. Default false returns a compact summary so the full catalog stays under the ~25k MCP output cap.")
                    ])
                ]),
                "required": .array([])
            ]),
            handler: { arguments in
                let moduleFilter: String?
                var wantDetail = false
                if case .object(let args) = arguments {
                    if case .string(let m) = args["module"] { moduleFilter = m } else { moduleFilter = nil }
                    if case .bool(let d) = args["detail"] { wantDetail = d }
                } else {
                    moduleFilter = nil
                }
                // Scoping to a single module implies the caller wants full detail.
                let fullDetail = wantDetail || (moduleFilter != nil)

                let registrations: [ToolRegistration]
                if let filter = moduleFilter {
                    registrations = await router.registrations(forModule: filter)
                } else {
                    registrations = await router.allRegistrations()
                }

                func summarize(_ s: String) -> String {
                    let oneLine = s.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).joined(separator: " ")
                    return oneLine.count <= 100 ? oneLine : String(oneLine.prefix(99)) + "…"
                }

                let toolEntries: [Value] = registrations.map { reg in
                    guard fullDetail else {
                        return .object([
                            "name": .string(reg.name),
                            "module": .string(reg.module),
                            "tier": .string(reg.tier.rawValue),
                            "summary": .string(summarize(reg.description))
                        ])
                    }
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

        // session_info – open (V1-04; PKT-1065B: explicit field scopes)
        await router.register(ToolRegistration(
            name: "session_info",
            module: moduleName,
            tier: .open,
            description: "Return this bridge PROCESS's diagnostics. IMPORTANT — scopes differ per field: "
                + "`uptimeSeconds` is the whole bridge process's uptime (not a per-caller session). "
                + "`connections`/`activeClients` count ONLY live HTTP (/mcp) + legacy SSE network sessions; "
                + "a stdio-attached client (e.g. this local MCP connection) is NOT counted, so 0 clients is "
                + "expected and normal when the only caller is on stdio — it does NOT contradict bridge_status. "
                + "`toolCalls`/`auditLogSize` are the audit-log entry count accumulated since process start (or "
                + "the last session_clear). This tool describes the LOCAL bridge process; `bridge_status` "
                + "describes the CLOUD tunnel channel — the two are orthogonal. See the `scopes` field in the "
                + "response for the authoritative per-field definitions.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([])
            ]),
            handler: { _ in
                let uptime = max(0, Date().timeIntervalSince(sessionStartTime))
                let auditSize = await auditLog.count()
                // No diagnostics provider (e.g. stdio-only assembly / unit tests) means
                // there is no HTTP/SSE server to enumerate network sessions — report 0,
                // NOT a fabricated 1. The `scopes` field explains why 0 is correct.
                let diagnostics = await diagnosticsProvider?() ?? RuntimeDiagnostics(connections: 0, activeClients: 0)
                let hours = Int(uptime) / 3600
                let minutes = (Int(uptime) % 3600) / 60
                let seconds = Int(uptime) % 60
                let uptimeStr = String(format: "%dh %dm %ds", hours, minutes, seconds)

                return .object([
                    "uptime": .string(uptimeStr),
                    "uptimeSeconds": .double(uptime),
                    "connections": .int(diagnostics.connections),
                    "toolCalls": .int(auditSize),
                    "activeClients": .int(diagnostics.activeClients),
                    "auditLogSize": .int(auditSize),
                    // Explicit per-field scope so a caller never has to guess why, e.g.,
                    // activeClients is 0 while bridge_status reports the tunnel online.
                    "scopes": .object([
                        "uptimeSeconds": .string("Whole bridge PROCESS uptime in seconds (not a per-caller session)."),
                        "uptime": .string("Same as uptimeSeconds, formatted as 'Hh Mm Ss'."),
                        "connections": .string("Count of live HTTP (/mcp) + legacy SSE network sessions. Excludes stdio callers."),
                        "activeClients": .string("Same population as `connections`: HTTP + legacy SSE sessions only. A stdio-attached caller is NOT counted, so 0 is normal and does not conflict with bridge_status."),
                        "toolCalls": .string("Audit-log entry count since process start or last session_clear. Equal to auditLogSize."),
                        "auditLogSize": .string("Number of audit-log entries retained for this process (since start or last session_clear)."),
                        "note": .string("session_info describes the LOCAL bridge process; bridge_status describes the CLOUD tunnel channel. They are independent — neither implies the other.")
                    ])
                ])
            }
        ))

        // audit_recent — open (PKT-1116). Read-only projection of the
        // already-retained in-memory audit trail. Deliberately omits
        // `inputSummary`: agents need the refusal/result trail, not a replay of
        // caller-supplied material. Credential-tool output summaries are also
        // redacted defensively even though ToolRouter normally stores only an
        // object-key summary.
        await router.register(ToolRegistration(
            name: "audit_recent",
            module: moduleName,
            tier: .open,
            description: "Return the most-recent in-memory audit entries so an agent can diagnose why a tool call was approved, rejected, escalated, or failed. Filter by exact tool name, approval status, or security tier. Input summaries are never returned; credential-tool output summaries are redacted.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "limit": .object([
                        "type": .string("integer"),
                        "description": .string("Maximum entries to return (default 20, range 1...100).")
                    ]),
                    "tool": .object([
                        "type": .string("string"),
                        "description": .string("Optional exact tool-name filter.")
                    ]),
                    "status": .object([
                        "type": .string("string"),
                        "enum": .array(ApprovalStatus.allCases.map { .string($0.rawValue) }),
                        "description": .string("Optional approval status: approved | rejected | escalated | error.")
                    ]),
                    "tier": .object([
                        "type": .string("string"),
                        "enum": .array(SecurityTier.allCases.map { .string($0.rawValue) }),
                        "description": .string("Optional security tier: open | notify | request.")
                    ])
                ]),
                "required": .array([])
            ]),
            metadata: ToolMetadata(
                title: "Recent Audit Trail",
                whenToUse: ["Diagnose why a recent Bridge tool call was blocked, escalated, or failed."],
                whenNotToUse: ["Clearing audit history (use session_clear with explicit confirmation)."],
                relatedTools: ["session_info", "session_clear"]
            ),
            handler: { arguments in
                let args: [String: Value]
                if case .object(let object) = arguments { args = object } else { args = [:] }

                let limit: Int = {
                    guard case .int(let requested) = args["limit"] else {
                        return auditRecentDefaultLimit
                    }
                    return max(1, min(requested, auditRecentMaximumLimit))
                }()
                let toolFilter: String? = {
                    guard case .string(let value) = args["tool"], !value.isEmpty else { return nil }
                    return value
                }()
                let statusFilter: ApprovalStatus?
                if case .string(let raw) = args["status"] {
                    guard let parsed = ApprovalStatus(rawValue: raw) else {
                        return .object(["error": .string("Invalid status '\(raw)'. Expected approved, rejected, escalated, or error.")])
                    }
                    statusFilter = parsed
                } else {
                    statusFilter = nil
                }
                let tierFilter: SecurityTier?
                if case .string(let raw) = args["tier"] {
                    guard let parsed = SecurityTier(rawValue: raw) else {
                        return .object(["error": .string("Invalid tier '\(raw)'. Expected open, notify, or request.")])
                    }
                    tierFilter = parsed
                } else {
                    tierFilter = nil
                }

                // Use AuditLog's indexed read seams for the first available
                // filter, then compose any remaining predicates locally.
                var entries: [AuditEntry]
                if let toolFilter {
                    entries = await auditLog.entries(forTool: toolFilter)
                } else if let statusFilter {
                    entries = await auditLog.entries(withStatus: statusFilter)
                } else if let tierFilter {
                    entries = await auditLog.entries(forTier: tierFilter)
                } else {
                    entries = await auditLog.allEntries()
                }
                if let toolFilter { entries.removeAll { $0.toolName != toolFilter } }
                if let statusFilter { entries.removeAll { $0.approvalStatus != statusFilter } }
                if let tierFilter { entries.removeAll { $0.tier != tierFilter } }

                let recent = entries
                    .sorted { $0.timestamp > $1.timestamp }
                    .prefix(limit)
                    .map(auditEntryValue)
                return .object([
                    "entries": .array(Array(recent)),
                    "count": .int(recent.count),
                    "limit": .int(limit),
                    "inputSummaryIncluded": .bool(false)
                ])
            }
        ))

        // session_clear – notify (V1-04)
        await router.register(ToolRegistration(
            name: "session_clear",
            module: moduleName,
            tier: .notify,
            description: "Clear this session's audit log. Requires confirm: true. Irreversible for the current session only.",
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

                let previousUptime = max(0, Date().timeIntervalSince(sessionStartTime))
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

    /// Public pure projection for secrecy/shape tests. `inputSummary` and
    /// `governanceNote` are intentionally absent from the wire response.
    public static func auditEntryValue(_ entry: AuditEntry) -> Value {
        let outputSummary = entry.toolName.hasPrefix("credential_")
            ? "<redacted: credential tool>"
            : entry.outputSummary
        return .object([
            "timestamp": .string(ISO8601DateFormatter().string(from: entry.timestamp)),
            "toolName": .string(entry.toolName),
            "tier": .string(entry.tier.rawValue),
            "approvalStatus": .string(entry.approvalStatus.rawValue),
            "outputSummary": .string(outputSummary),
            "durationMs": .double(entry.durationMs),
            "origin": entry.origin.map { .string($0.rawValue) } ?? .null,
            "transportSessionId": entry.transportSessionId.map(Value.string) ?? .null
        ])
    }
}
