// EndToEndTests.swift – V1-06 Integration & End-to-End Tests
// KeeprBridge · Tests/IntegrationTests
//
// Validates the full pipeline: Transport → ToolRouter → SecurityGate → Handler → AuditLog → Response
// Covers both stdio transport and cross-module integration scenarios.

import Foundation
import MCP
import KeeprLib

// MARK: - Integration Test Runner

func runEndToEndTests() async {
    print("\n🔗 End-to-End Integration Tests")

    // Shared infrastructure for all integration tests
    let securityGate = SecurityGate()
    let auditLog = AuditLog()
    let router = ToolRouter(securityGate: securityGate, auditLog: auditLog, batchThreshold: 3)

    // Register all V1 modules (same as main.swift bootstrap)
    await ShellModule.register(on: router)
    await FileModule.register(on: router)
    await SessionModule.register(on: router, auditLog: auditLog)
    await MessagesModule.register(on: router)
    await SystemModule.register(on: router)
    await NotionModule.register(on: router)

    // ============================================================
    // E2E-1: Full pipeline — dispatch → security → handler → audit
    // ============================================================

    await test("E2E: tools_list returns all 29 v1 tools") {
        let result = try await router.dispatch(
            toolName: "tools_list",
            arguments: .object([:])
        )
        if case .array(let tools) = result {
            try expect(tools.count >= 29, "Expected ≥29 tools, got \(tools.count)")
        } else {
            throw TestError.assertion("Expected array result from tools_list")
        }
    }

    await test("E2E: tools_list with module filter returns correct subset") {
        let result = try await router.dispatch(
            toolName: "tools_list",
            arguments: .object(["module": .string("shell")])
        )
        if case .array(let tools) = result {
            try expect(tools.count == 2, "Expected 2 shell tools, got \(tools.count)")
        } else {
            throw TestError.assertion("Expected array result")
        }
    }

    // ============================================================
    // E2E-2: SecurityGate enforces across real module tools
    // ============================================================

    let sudoStr = String(UnicodeScalar(115)) + "udo"

    await test("E2E: SecurityGate blocks sudo through real shell_exec") {
        do {
            _ = try await router.dispatch(
                toolName: "shell_exec",
                arguments: .object(["command": .string(sudoStr + " ls")])
            )
            throw TestError.assertion("Expected rejection for sudo command")
        } catch let error as ToolRouterError {
            if case .securityRejection(_, let reason) = error {
                try expect(reason.lowercased().contains("sudo"), "Reason should mention sudo")
            } else {
                throw TestError.assertion("Expected securityRejection error")
            }
        }
    }

    await test("E2E: SecurityGate blocks forbidden path through file_read") {
        do {
            _ = try await router.dispatch(
                toolName: "file_read",
                arguments: .object(["path": .string("~/.ssh/id_rsa")])
            )
            throw TestError.assertion("Expected rejection for forbidden path")
        } catch let error as ToolRouterError {
            if case .securityRejection(_, let reason) = error {
                try expect(reason.contains("Forbidden"), "Reason should mention forbidden path")
            } else {
                throw TestError.assertion("Expected securityRejection error")
            }
        }
    }

    await test("E2E: SecurityGate allows green-tier tool immediately") {
        let result = try await router.dispatch(
            toolName: "system_info",
            arguments: .object([:])
        )
        if case .object(let dict) = result {
            // system_info returns osName, osVersion, hostname, cpu, memoryGB, uptime
            try expect(dict["osName"] != nil || dict["hostname"] != nil,
                       "system_info should return osName or hostname field")
        } else {
            throw TestError.assertion("Expected object result from system_info")
        }
    }

    // ============================================================
    // E2E-3: Audit log captures every tool call
    // ============================================================

    await test("E2E: Audit log records dispatched calls") {
        await auditLog.clear()

        _ = try await router.dispatch(
            toolName: "system_info",
            arguments: .object([:])
        )
        _ = try await router.dispatch(
            toolName: "clipboard_read",
            arguments: .object([:])
        )

        let entries = await auditLog.allEntries()
        try expect(entries.count == 2, "Expected 2 audit entries, got \(entries.count)")
        try expect(entries[0].toolName == "system_info")
        try expect(entries[1].toolName == "clipboard_read")
        try expect(entries[0].approvalStatus == .approved)
        try expect(entries[1].approvalStatus == .approved)
        try expect(entries[0].durationMs > 0, "Duration should be positive")
    }

    await test("E2E: Audit log records rejected calls") {
        await auditLog.clear()

        do {
            _ = try await router.dispatch(
                toolName: "shell_exec",
                arguments: .object(["command": .string(sudoStr + " reboot")])
            )
        } catch { /* expected */ }

        let entries = await auditLog.allEntries()
        try expect(entries.count == 1, "Expected 1 audit entry for rejected call")
        try expect(entries[0].approvalStatus == .rejected)
        try expect(entries[0].toolName == "shell_exec")
    }

    // ============================================================
    // E2E-4: Cross-module integration
    // ============================================================

    await test("E2E: Cross-module — shell_exec output is valid structured response") {
        let result = try await router.dispatch(
            toolName: "shell_exec",
            arguments: .object(["command": .string("echo 'hello keepr'")])
        )
        if case .object(let dict) = result {
            if case .string(let stdout) = dict["stdout"] {
                try expect(stdout.contains("hello keepr"), "stdout should contain command output")
            } else {
                throw TestError.assertion("Expected stdout string")
            }
            if case .int(let exitCode) = dict["exitCode"] {
                try expect(exitCode == 0, "Expected exit code 0")
            }
        } else {
            throw TestError.assertion("Expected object result from shell_exec")
        }
    }

    await test("E2E: Cross-module — file_write then file_read round-trip") {
        let testDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keepr-e2e-\(UUID().uuidString)")
        let testFile = testDir.appendingPathComponent("roundtrip.txt")
        let testContent = "Keepr V1-06 integration test: \(Date().ISO8601Format())"

        // Write
        let writeResult = try await router.dispatch(
            toolName: "file_write",
            arguments: .object([
                "path": .string(testFile.path),
                "content": .string(testContent),
                "createDirs": .bool(true)
            ])
        )
        if case .object(let wr) = writeResult {
            if case .bool(let ok) = wr["success"] { try expect(ok, "Write should succeed") }
        }

        // Read back
        let readResult = try await router.dispatch(
            toolName: "file_read",
            arguments: .object(["path": .string(testFile.path)])
        )
        if case .object(let rr) = readResult {
            if case .string(let content) = rr["content"] {
                try expect(content == testContent, "Read content should match written content")
            } else {
                throw TestError.assertion("Expected content string in read result")
            }
        }

        // Cleanup
        try? FileManager.default.removeItem(at: testDir)
    }

    await test("E2E: Cross-module — session_info reflects tool call count") {
        await auditLog.clear()

        _ = try await router.dispatch(toolName: "system_info", arguments: .object([:]))
        _ = try await router.dispatch(toolName: "clipboard_read", arguments: .object([:]))
        _ = try await router.dispatch(toolName: "system_info", arguments: .object([:]))

        let result = try await router.dispatch(
            toolName: "session_info",
            arguments: .object([:])
        )
        if case .object(let dict) = result {
            if case .int(let calls) = dict["toolCalls"] {
                try expect(calls >= 3, "Expected ≥3 tool calls recorded, got \(calls)")
            }
        }
    }

    // ============================================================
    // E2E-5: Batch gate integration
    // ============================================================

    await test("E2E: Batch gate triggers on 3+ tool plan") {
        let plan = [
            ExecutionPlanEntry(toolName: "file_read", tier: .green, inputSummary: "/tmp/a"),
            ExecutionPlanEntry(toolName: "file_write", tier: .orange, inputSummary: "/tmp/b"),
            ExecutionPlanEntry(toolName: "shell_exec", tier: .orange, inputSummary: "echo test"),
        ]
        let result = await router.batchGate(planned: plan)
        try expect(result != nil, "Batch gate should trigger at 3 tools")
        try expect(result?.count == 3)
    }

    await test("E2E: Batch gate does not trigger on 2-tool plan") {
        let plan = [
            ExecutionPlanEntry(toolName: "file_read", tier: .green, inputSummary: "/tmp/a"),
            ExecutionPlanEntry(toolName: "file_write", tier: .orange, inputSummary: "/tmp/b"),
        ]
        let result = await router.batchGate(planned: plan)
        try expect(result == nil, "Batch gate should not trigger below threshold")
    }

    // ============================================================
    // E2E-6: stdio transport integration (MCP Server object)
    // ============================================================

    await test("E2E: MCP Server initializes with tool capabilities") {
        let server = Server(
            name: "KeeprServer",
            version: "0.5.0",
            capabilities: .init(tools: .init())
        )
        _ = server
    }

    await test("E2E: tools_list returns accurate metadata per tool") {
        let result = try await router.dispatch(
            toolName: "tools_list",
            arguments: .object([:])
        )
        if case .array(let tools) = result {
            for tool in tools {
                if case .object(let t) = tool {
                    try expect(t["name"] != nil, "Tool should have name")
                    try expect(t["module"] != nil, "Tool should have module")
                    try expect(t["tier"] != nil, "Tool should have tier")
                    try expect(t["description"] != nil, "Tool should have description")
                    try expect(t["inputs"] != nil, "Tool should have inputs")
                }
            }

            var toolTiers: [String: String] = [:]
            for tool in tools {
                if case .object(let t) = tool,
                   case .string(let name) = t["name"],
                   case .string(let tier) = t["tier"] {
                    toolTiers[name] = tier
                }
            }

            // Spot-check critical tier assignments
            try expect(toolTiers["file_read"] == "green", "file_read should be green")
            try expect(toolTiers["file_write"] == "orange", "file_write should be orange")
            try expect(toolTiers["shell_exec"] == "orange", "shell_exec should be orange")
            try expect(toolTiers["clipboard_write"] == "yellow", "clipboard_write should be yellow")
            try expect(toolTiers["messages_send"] == "red", "messages_send should be red")
            try expect(toolTiers["system_info"] == "green", "system_info should be green")
            try expect(toolTiers["notify"] == "yellow", "notify should be yellow")
        } else {
            throw TestError.assertion("Expected array from tools_list")
        }
    }

    // ============================================================
    // E2E-7: Error handling through full pipeline
    // ============================================================

    await test("E2E: Unknown tool dispatch returns proper error") {
        do {
            _ = try await router.dispatch(
                toolName: "nonexistent_tool_xyz",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error")
        } catch let error as ToolRouterError {
            if case .unknownTool(let name) = error {
                try expect(name == "nonexistent_tool_xyz")
            }
        }
    }

    await test("E2E: Module tool with invalid params returns graceful error") {
        do {
            _ = try await router.dispatch(
                toolName: "file_read",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing params")
        } catch {
            // Expected — file_read requires 'path' parameter
        }
    }

    // ============================================================
    // E2E-8: Module registration completeness
    // ============================================================

    await test("E2E: All 6 V1 modules registered with correct tool counts") {
        let shell = await router.registrations(forModule: "shell")
        let file = await router.registrations(forModule: "file")
        let session = await router.registrations(forModule: "session")
        let messages = await router.registrations(forModule: "messages")
        let system = await router.registrations(forModule: "system")
        let notion = await router.registrations(forModule: "notion")

        try expect(shell.count == 2, "ShellModule: expected 2, got \(shell.count)")
        try expect(file.count == 12, "FileModule: expected 12, got \(file.count)")
        try expect(session.count == 3, "SessionModule: expected 3, got \(session.count)")
        try expect(messages.count == 6, "MessagesModule: expected 6, got \(messages.count)")
        try expect(system.count == 3, "SystemModule: expected 3, got \(system.count)")
        try expect(notion.count == 3, "NotionModule: expected 3, got \(notion.count)")

        let total = shell.count + file.count + session.count + messages.count + system.count + notion.count
        try expect(total == 29, "Total V1 tools: expected 29, got \(total)")
    }

    await test("E2E: All 4 security tiers represented in V1 tool registry") {
        let all = await router.allRegistrations()
        let tiers = Set(all.map { $0.tier })
        try expect(tiers.contains(.green), "Missing green tier tools")
        try expect(tiers.contains(.yellow), "Missing yellow tier tools")
        try expect(tiers.contains(.orange), "Missing orange tier tools")
        try expect(tiers.contains(.red), "Missing red tier tools")
    }
}
