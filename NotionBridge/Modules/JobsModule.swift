// JobsModule.swift — Job Scheduling MCP Tools
// NotionBridge · Modules
//
// History:
//   PKT-340 (v1.9.0) — Initial 8 tools (create/get/list/delete/pause/resume/history/templates).
//   Jobs UI v1.10.0 — +7 tools (run/update/duplicate/export/import/pause_all/resume_all).
//                      Total: 15 scheduler tools.
//
// Tier assignments:
//   job_create, job_delete, job_update, job_duplicate, job_run, job_import,
//   jobs_pause_all, jobs_resume_all → .notify (mutating)
//   job_get, job_list, job_pause, job_resume, job_history, job_templates,
//   job_export → .open (read)

import Foundation
import MCP

public enum JobsModule {
    public static let moduleName = "scheduler"

    // MARK: - Registration

    public static func register(on router: ToolRouter) async {
        // v1.9.0 tools
        await router.register(makeJobCreate())
        await router.register(makeJobGet())
        await router.register(makeJobList())
        await router.register(makeJobDelete())
        await router.register(makeJobPause())
        await router.register(makeJobResume())
        await router.register(makeJobHistory())
        await router.register(makeJobTemplates())
        // v1.10.0 tools
        await router.register(makeJobRun())
        await router.register(makeJobUpdate())
        await router.register(makeJobDuplicate())
        await router.register(makeJobExport())
        await router.register(makeJobImport())
        await router.register(makeJobsPauseAll())
        await router.register(makeJobsResumeAll())
    }

    // MARK: - v1.9.0 tool factories

    private static func makeJobCreate() -> ToolRegistration {
        ToolRegistration(
            name: "job_create",
            module: moduleName,
            tier: .notify,
            description: "Create a scheduled job. 5-field cron + action chain (≤1–0 steps) with $prev_result templating.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("name"), .string("schedule"), .string("actions")]),
                "properties": .object([
                    "name": .object(["type": .string("string")]),
                    "schedule": .object(["type": .string("string")]),
                    "actions": .object([
                        "type": .string("array"),
                        "maxItems": .int(10),
                        "items": .object(["type": .string("object")])
                    ]),
                    "skipOnBattery": .object(["type": .string("boolean"), "default": .bool(false)])
                ])
            ]),
            handler: { args in try await JobsManager.shared.createJob(args: args) }
        )
    }

    private static func makeJobGet() -> ToolRegistration {
        ToolRegistration(
            name: "job_get", module: moduleName, tier: .open,
            description: "Get a job by id with last 10 executions.",
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
            description: "List all scheduled jobs.",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
            handler: { args in try await JobsManager.shared.listJobs(args: args) }
        )
    }

    private static func makeJobDelete() -> ToolRegistration {
        ToolRegistration(
            name: "job_delete", module: moduleName, tier: .notify,
            description: "Delete a job: unregister LaunchAgent, remove plist, delete DB record (cascades executions).",
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
            description: "Pause a job (unregister LaunchAgent, keep DB record + plist).",
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
            description: "Resume a paused job (re-register LaunchAgent).",
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
            description: "Get last N executions for a job.",
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
            description: "List common job presets.",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
            handler: { args in try await JobsManager.shared.listTemplates(args: args) }
        )
    }

    // MARK: - v1.10.0 tool factories

    private static func makeJobRun() -> ToolRegistration {
        ToolRegistration(
            name: "job_run", module: moduleName, tier: .notify,
            description: "Trigger a job to run immediately, bypassing its schedule. Uses the stored router from bootstrap.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("id")]),
                "properties": .object(["id": .object(["type": .string("string")])])
            ]),
            handler: { args in try await JobsManager.shared.runNowTool(args: args) }
        )
    }

    private static func makeJobUpdate() -> ToolRegistration {
        ToolRegistration(
            name: "job_update", module: moduleName, tier: .notify,
            description: "Patch a job's name, schedule, action chain, or skipOnBattery. Schedule changes trigger atomic LaunchAgent re-registration with rollback on failure.",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("id")]),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "name": .object(["type": .string("string")]),
                    "schedule": .object(["type": .string("string")]),
                    "actions": .object(["type": .string("array"), "maxItems": .int(10), "items": .object(["type": .string("object")])]),
                    "skipOnBattery": .object(["type": .string("boolean")])
                ])
            ]),
            handler: { args in try await JobsManager.shared.updateJobTool(args: args) }
        )
    }

    private static func makeJobDuplicate() -> ToolRegistration {
        ToolRegistration(
            name: "job_duplicate", module: moduleName, tier: .notify,
            description: "Clone a job with a fresh id and new LaunchAgent registration. Optional nameSuffix appended to the duplicated job's name (default ' (copy)').",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("id")]),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                    "nameSuffix": .object(["type": .string("string")])
                ])
            ]),
            handler: { args in try await JobsManager.shared.duplicateJobTool(args: args) }
        )
    }

    private static func makeJobExport() -> ToolRegistration {
        ToolRegistration(
            name: "job_export", module: moduleName, tier: .open,
            description: "Export jobs as a JSON envelope (version, exportedAt, jobs[]). Provide 'ids' to export a subset; omit to export all.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "ids": .object(["type": .string("array"), "items": .object(["type": .string("string")])])
                ])
            ]),
            handler: { args in try await JobsManager.shared.exportJobsTool(args: args) }
        )
    }

    private static func makeJobImport() -> ToolRegistration {
        ToolRegistration(
            name: "job_import", module: moduleName, tier: .notify,
            description: "Import jobs from a JSON envelope. IDs are regenerated to avoid collisions. Returns counts of imported vs skipped (with reasons).",
            inputSchema: .object([
                "type": .string("object"),
                "required": .array([.string("json")]),
                "properties": .object(["json": .object(["type": .string("string")])])
            ]),
            handler: { args in try await JobsManager.shared.importJobsTool(args: args) }
        )
    }

    private static func makeJobsPauseAll() -> ToolRegistration {
        ToolRegistration(
            name: "jobs_pause_all", module: moduleName, tier: .notify,
            description: "Kill-switch: pause every active job in parallel via a TaskGroup.",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
            handler: { args in try await JobsManager.shared.pauseAllTool(args: args) }
        )
    }

    private static func makeJobsResumeAll() -> ToolRegistration {
        ToolRegistration(
            name: "jobs_resume_all", module: moduleName, tier: .notify,
            description: "Resume every paused job in parallel via a TaskGroup.",
            inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
            handler: { args in try await JobsManager.shared.resumeAllTool(args: args) }
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
        case .notImplemented(let what): return "Not yet implemented: \(what)"
        case .invalidSchedule(let s): return "Invalid cron schedule: \(s)"
        case .invalidActionChain(let s): return "Invalid action chain: \(s)"
        case .jobNotFound(let id): return "Job not found: \(id)"
        case .storageFailure(let s): return "Job storage error: \(s)"
        case .launchAgentFailure(let s): return "LaunchAgent error: \(s)"
        }
    }
}
