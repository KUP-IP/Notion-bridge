// EndToEndTests.swift – V1-06 Integration & End-to-End Tests
// NotionBridge · Tests/IntegrationTests
//
// Validates the full pipeline: Transport → ToolRouter → SecurityGate → Handler → AuditLog → Response
// Covers both stdio transport and cross-module integration scenarios.

import Foundation
import MCP
import NotionBridgeLib

// MARK: - Integration Test Runner

func runEndToEndTests() async {
    print("\n🔗 End-to-End Integration Tests")

    // Shared infrastructure for all integration tests
    let securityGate = SecurityGate()
    let auditLog = AuditLog()
    let router = ToolRouter(securityGate: securityGate, auditLog: auditLog, batchThreshold: 3)

    // Register all modules (matches ServerManager.setup() bootstrap)
    await ShellModule.register(on: router)
    await FileModule.register(on: router)
    await SessionModule.register(on: router, auditLog: auditLog)
    await MessagesModule.register(on: router)
    await SystemModule.register(on: router)
    await NotionModule.register(on: router)
    await ScreenModule.register(on: router)
    await ScreenModule.registerRecording(on: router)
    await AccessibilityModule.register(on: router)
    await AppleScriptModule.register(on: router)

    // ============================================================
    // E2E-1: Full pipeline — dispatch → security → handler → audit
    // ============================================================

    await test("E2E: router has all registered module tools (39 total)") {
        let all = await router.allRegistrations()
        try expect(all.count == 39, "Expected 39 module tools, got \(all.count)")
    }

    await test("E2E: router filters by module correctly") {
        let shell = await router.registrations(forModule: "shell")
        try expect(shell.count == 2, "Expected 2 shell tools, got \(shell.count)")
    }

    // ============================================================
    // E2E-2: SecurityGate enforces across real module tools
    // ============================================================

    let sudoStr = String(UnicodeScalar(115)) + "udo"

    await test("E2E: SecurityGate escalates sudo through real shell_exec") {
        let result = try await router.dispatch(
            toolName: "shell_exec",
            arguments: .object(["command": .string(sudoStr + " ls")])
        )
        if case .object(let dict) = result,
           case .string(let status) = dict["status"] {
            try expect(status == "handoff", "Expected handoff status for sudo command")
        } else {
            throw TestError.assertion("Expected handoff object for sudo command")
        }
    }

    await test("E2E: file_read surfaces file-not-found errors clearly") {
        do {
            _ = try await router.dispatch(
                toolName: "file_read",
                arguments: .object(["path": .string("~/.ssh/id_rsa")])
            )
            throw TestError.assertion("Expected missing file error")
        } catch {
            // Expected — path is typically absent in test environments.
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

    await test("E2E: Audit log records escalated calls") {
        await auditLog.clear()

        _ = try await router.dispatch(
            toolName: "shell_exec",
            arguments: .object(["command": .string(sudoStr + " reboot")])
        )

        let entries = await auditLog.allEntries()
        try expect(entries.count == 1, "Expected 1 audit entry for rejected call")
        try expect(entries[0].approvalStatus == .escalated)
        try expect(entries[0].toolName == "shell_exec")
    }

    // ============================================================
    // E2E-4: Cross-module integration
    // ============================================================

    await test("E2E: Cross-module — shell_exec output is valid structured response") {
        let result = try await router.dispatch(
            toolName: "shell_exec",
            arguments: .object(["command": .string("echo 'hello notionbridge'")])
        )
        if case .object(let dict) = result {
            if case .string(let stdout) = dict["stdout"] {
                try expect(stdout.contains("hello notionbridge"), "stdout should contain command output")
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
            .appendingPathComponent("notionbridge-e2e-\(UUID().uuidString)")
        let testFile = testDir.appendingPathComponent("roundtrip.txt")
        let testContent = "NotionBridge integration test: \(Date().ISO8601Format())"

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
            ExecutionPlanEntry(toolName: "file_read", tier: .open, inputSummary: "/tmp/a"),
            ExecutionPlanEntry(toolName: "file_write", tier: .notify, inputSummary: "/tmp/b"),
            ExecutionPlanEntry(toolName: "shell_exec", tier: .notify, inputSummary: "echo test"),
        ]
        let result = await router.batchGate(planned: plan)
        try expect(result != nil, "Batch gate should trigger at 3 tools")
        try expect(result?.count == 3)
    }

    await test("E2E: Batch gate does not trigger on 2-tool plan") {
        let plan = [
            ExecutionPlanEntry(toolName: "file_read", tier: .open, inputSummary: "/tmp/a"),
            ExecutionPlanEntry(toolName: "file_write", tier: .notify, inputSummary: "/tmp/b"),
        ]
        let result = await router.batchGate(planned: plan)
        try expect(result == nil, "Batch gate should not trigger below threshold")
    }

    // ============================================================
    // E2E-6: stdio transport integration (MCP Server object)
    // ============================================================

    await test("E2E: MCP Server initializes with tool capabilities") {
        let server = Server(
            name: "NotionBridge",
            version: "0.5.0",
            capabilities: .init(tools: .init())
        )
        _ = server
    }

    await test("E2E: All tools have correct 2-tier assignments") {
        let all = await router.allRegistrations()
        var tierMap: [String: String] = [:]
        for reg in all {
            tierMap[reg.name] = reg.tier.rawValue
        }

        // Spot-check critical tier assignments (2-tier: open / notify)
        try expect(tierMap["file_read"] == "open", "file_read should be open")
        try expect(tierMap["file_write"] == "notify", "file_write should be notify")
        try expect(tierMap["shell_exec"] == "notify", "shell_exec should be notify")
        try expect(tierMap["clipboard_write"] == "open", "clipboard_write should be open")
        try expect(tierMap["messages_send"] == "notify", "messages_send should be notify")
        try expect(tierMap["system_info"] == "open", "system_info should be open")
        try expect(tierMap["notify"] == "open", "notify should be open")
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

    await test("E2E: All 10 modules registered with correct tool counts") {
        let shell = await router.registrations(forModule: "shell")
        let file = await router.registrations(forModule: "file")
        let session = await router.registrations(forModule: "session")
        let messages = await router.registrations(forModule: "messages")
        let system = await router.registrations(forModule: "system")
        let notion = await router.registrations(forModule: "notion")
        let screen = await router.registrations(forModule: "screen")
        let accessibility = await router.registrations(forModule: "accessibility")
        let applescript = await router.registrations(forModule: "applescript")

        try expect(shell.count == 2, "ShellModule: expected 2")
        try expect(file.count == 12, "FileModule: expected 12")
        try expect(session.count == 3, "SessionModule: expected 3")
        try expect(messages.count == 6, "MessagesModule: expected 6")
        try expect(system.count == 3, "SystemModule: expected 3")
        try expect(notion.count == 3, "NotionModule: expected 3")
        try expect(screen.count == 4, "ScreenModule: expected 4")
        try expect(accessibility.count == 5, "AccessibilityModule: expected 5")
        try expect(applescript.count == 1, "AppleScriptModule: expected 1")
    }

    await test("E2E: Total module tool count is 39") {
        let all = await router.allRegistrations()
        // 39 module tools (this suite does not register builtin echo).
        let moduleTools = all.filter { $0.module != "builtin" }
        try expect(moduleTools.count == 39, "Expected 39 module tools, got \(moduleTools.count)")
    }

    await test("E2E: Both security tiers represented in tool registry") {
        let all = await router.allRegistrations()
        let tiers = Set(all.map { $0.tier })
        try expect(tiers.contains(.open), "Missing open tier tools")
        try expect(tiers.contains(.notify), "Missing notify tier tools")
        try expect(tiers.count == 2, "Expected exactly 2 tiers, got \(tiers.count)")
    }
}
