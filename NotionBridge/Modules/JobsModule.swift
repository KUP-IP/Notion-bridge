// JobsModule.swift — Job Scheduling MCP Tools (PKT-340 · SEQ 8 · V2-SCHEDULER)
// NotionBridge · Modules
//
// SCAFFOLD STATUS: Wave 1 of 4 (UEP v3.2.0 wave plan, see PKT-340 discussion).
// This file registers the 8 job_* tools at the correct SecurityGate tiers and
// dispatches to JobsManager. Handler bodies are stubs that throw `.notImplemented`
// pending Waves 2–4 (cron translation, plist writer, SMAppService lifecycle, UI).
//
// DoD coverage (see PKT-340):
//  ✅ DoD-2  : 8 MCP tools registered with correct tiers
//  ⏳ DoD-1,3,4,5,6,7,8 : pending Waves 2–4
//
// Tier assignments (per packet spec):
//   job_create  → .notify  (creates LaunchAgent + plist)
//   job_delete  → .notify  (unregisters + removes plist)
//   job_get,    → .open
//   job_list,   → .open
//   job_pause,  → .open
//   job_resume, → .open
//   job_history,→ .open
//   job_templates → .open

import Foundation
import MCP

public enum JobsModule {
    public static let moduleName = "scheduler"

    // MARK: - Registration

    public static func register(on router: ToolRouter) async {
        await router.register(makeJobCreate())
        await router.register(makeJobGet())
        await router.register(makeJobList())
        await router.register(makeJobDelete())
        await router.register(makeJobPause())
        await router.register(makeJobResume())
        await router.register(makeJobHistory())
        await router.register(makeJobTemplates())
    }

    // MARK: - Tool factories

    private static func makeJobCreate() -> ToolRegistration {
        ToolRegistration(
            name: "job_create",
            module: moduleName,
            tier: .notify,
            description: "Create a scheduled job. Accepts a 5-field cron expression and an action chain (sequence of MCP tool calls with $prev_result templating, max 10 steps).",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("name"), .string("schedule"), .string("actions")]),
                "properties": .object([
                    "name": .object(["type": .string("string"), "description": .string("Human-readable job name")]),
                    "schedule": .object(["type": .string("string"), "description": .string("5-field cron expression (min hour day month weekday)")]),
                    "actions": .object([
                        "type": .string("array"),
                        "maxItems": .int(10),
                        "description": .string("Ordered tool calls. Each step: { tool, arguments, onFail?: 'stop'|'continue' }. Use $prev_result to template values from the previous step."),
                        "items": .object(["type": .string("object")])
                    ]),
                    "skipOnBattery": .object(["type": .string("boolean"), "default": .bool(false)])
                ])
            ]),
            handler: { args in
                try await JobsManager.shared.createJob(args: args)
            }
        )
    }

    private static func makeJobGet() -> ToolRegistration {
        ToolRegistration(
            name: "job_get", module: moduleName, tier: .open,
            description: "Get details for a single job by ID, including next run time and recent execution history.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("id")]),
                "properties": .object(["id": .object(["type": .string("string")])])
            ]),
            handler: { args in try await JobsManager.shared.getJob(args: args) }
        )
    }

    private static func makeJobList() -> ToolRegistration {
        ToolRegistration(
            name: "job_list", module: moduleName, tier: .open,
            description: "List all scheduled jobs with name, schedule, next run time, and status (active/paused).",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
            handler: { args in try await JobsManager.shared.listJobs(args: args) }
        )
    }

    private static func makeJobDelete() -> ToolRegistration {
        ToolRegistration(
            name: "job_delete", module: moduleName, tier: .notify,
            description: "Delete a job: unregister via SMAppService, remove plist from ~/Library/LaunchAgents/, delete DB record.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("id")]),
                "properties": .object(["id": .object(["type": .string("string")])])
            ]),
            handler: { args in try await JobsManager.shared.deleteJob(args: args) }
        )
    }

    private static func makeJobPause() -> ToolRegistration {
        ToolRegistration(
            name: "job_pause", module: moduleName, tier: .open,
            description: "Pause a job without deleting it. Unregisters the LaunchAgent but keeps DB record + plist.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("id")]),
                "properties": .object(["id": .object(["type": .string("string")])])
            ]),
            handler: { args in try await JobsManager.shared.pauseJob(args: args) }
        )
    }

    private static func makeJobResume() -> ToolRegistration {
        ToolRegistration(
            name: "job_resume", module: moduleName, tier: .open,
            description: "Resume a paused job. Re-registers via SMAppService.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("id")]),
                "properties": .object(["id": .object(["type": .string("string")])])
            ]),
            handler: { args in try await JobsManager.shared.resumeJob(args: args) }
        )
    }

    private static func makeJobHistory() -> ToolRegistration {
        ToolRegistration(
            name: "job_history", module: moduleName, tier: .open,
            description: "Get last N executions for a job, with timestamps, per-step results, success/failure.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("id")]),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "limit": .object(["type": .string("integer"), "default": .int(20), "maximum": .int(200)])
                ])
            ]),
            handler: { args in try await JobsManager.shared.jobHistory(args: args) }
        )
    }

    private static func makeJobTemplates() -> ToolRegistration {
        ToolRegistration(
            name: "job_templates", module: moduleName, tier: .open,
            description: "List common job presets (e.g., daily desktop cleanup, weekly screenshot tidy, hourly email summary).",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
            handler: { args in try await JobsManager.shared.listTemplates(args: args) }
        )
    }
}

// MARK: - Errors

public enum JobsModuleError: Error, CustomStringConvertible {
    case notImplemented(String)
    case invalidSchedule(String)
    case invalidActionChain(String)
    case jobNotFound(String)
    case storageFailure(String)
    case launchAgentFailure(String)

    public var description: String {
        switch self {
        case .notImplemented(let what): return "Not yet implemented: \(what) — pending PKT-340 Wave 2+"
        case .invalidSchedule(let s): return "Invalid cron schedule: \(s)"
        case .invalidActionChain(let s): return "Invalid action chain: \(s)"
        case .jobNotFound(let id): return "Job not found: \(id)"
        case .storageFailure(let s): return "Job storage error: \(s)"
        case .launchAgentFailure(let s): return "LaunchAgent error: \(s)"
        }
    }
}
