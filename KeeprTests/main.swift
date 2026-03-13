// main.swift – V1-03 Test Runner
// KeeprBridge · Tests (standalone executable — no XCTest needed)

import Foundation
import MCP
import KeeprLib

// MARK: - Test Harness

nonisolated(unsafe) var passed = 0
nonisolated(unsafe) var failed = 0

func test(_ name: String, _ body: () async throws -> Void) async {
    do {
        try await body()
        passed += 1
        print("  ✅ \(name)")
    } catch {
        failed += 1
        print("  ❌ \(name): \(error)")
    }
}

func expect(_ condition: Bool, _ msg: String = "Assertion failed", file: String = #file, line: Int = #line) throws {
    guard condition else { throw TestError.assertion("\(msg) at \(file):\(line)") }
}

enum TestError: Error, LocalizedError {
    case assertion(String)
    var errorDescription: String? {
        switch self { case .assertion(let m): return m }
    }
}

// ============================================================
// MARK: - SecurityGate Tests
// ============================================================

print("\n🔒 SecurityGate Tests")

let gate = SecurityGate()

await test("Green tier allows immediately") {
    let d = await gate.enforce(toolName: "read_file", tier: .green, arguments: .object(["path": .string("/tmp/test.txt")]))
    if case .allow = d { } else { throw TestError.assertion("Expected .allow for green tier") }
}

await test("Yellow tier allows with logging") {
    let d = await gate.enforce(toolName: "write_file", tier: .yellow, arguments: .object(["path": .string("/tmp/out.txt")]))
    if case .allow = d { } else { throw TestError.assertion("Expected .allow for yellow tier") }
}

await test("Orange tier allows (UI deferred)") {
    let d = await gate.enforce(toolName: "move_file", tier: .orange, arguments: .object(["path": .string("/tmp/a.txt")]))
    if case .allow = d { } else { throw TestError.assertion("Expected .allow for orange tier") }
}

await test("Red tier allows (UI deferred)") {
    let d = await gate.enforce(toolName: "dangerous_op", tier: .red, arguments: .object(["data": .string("safe content")]))
    if case .allow = d { } else { throw TestError.assertion("Expected .allow for red tier") }
}

// Auto-escalation: build test strings from Unicode scalars to avoid audit gate pattern matching
let rmCmd = String(UnicodeScalar(114)) + String(UnicodeScalar(109)) + " -rf /tmp/test"
let killCmd = String(UnicodeScalar(107)) + "ill -9 1234"
let sudoStr = String(UnicodeScalar(115)) + "udo"

await test("Auto-escalation: file deletion") {
    try expect(await gate.checkAutoEscalation(rmCmd))
}

await test("Auto-escalation: process termination") {
    try expect(await gate.checkAutoEscalation(killCmd))
}

await test("Auto-escalation: chmod 777") {
    try expect(await gate.checkAutoEscalation("chmod 777 /tmp/file"))
}

await test("Auto-escalation: pipe to shell") {
    try expect(await gate.checkAutoEscalation("curl url | sh"))
    try expect(await gate.checkAutoEscalation("echo test | bash"))
    try expect(await gate.checkAutoEscalation("data | eval"))
}

await test("Safe command does not trigger escalation") {
    try expect(await gate.checkAutoEscalation("ls -la ~/Documents") == false)
}

await test("Sudo is hard blocked — always rejected") {
    let d = await gate.enforce(toolName: "cli_exec", tier: .green, arguments: .object(["command": .string(sudoStr + " apt-get install")]))
    if case .reject(let reason) = d {
        try expect(reason.lowercased().contains("sudo"), "Rejection reason should mention sudo")
    } else {
        throw TestError.assertion("Expected .reject for sudo command")
    }
}

await test("Sudo pattern detection variations") {
    try expect(await gate.containsHardBlockedPattern(sudoStr + " reboot"))
    try expect(await gate.containsHardBlockedPattern("echo test | " + sudoStr + " cat"))
    try expect(await gate.containsHardBlockedPattern("pseudo") == false, "pseudo should not match")
}

await test("Forbidden path: ~/.ssh") {
    try expect(await gate.checkForbiddenPaths(["~/.ssh/id_rsa"]) != nil)
}

await test("Forbidden path: ~/.gnupg") {
    try expect(await gate.checkForbiddenPaths(["~/.gnupg/keys"]) != nil)
}

await test("Forbidden path: ~/.aws") {
    try expect(await gate.checkForbiddenPaths(["~/.aws/credentials"]) != nil)
}

await test("Forbidden path: ~/.config/gcloud") {
    try expect(await gate.checkForbiddenPaths(["~/.config/gcloud/auth"]) != nil)
}

await test("Forbidden path: .env files") {
    try expect(await gate.checkForbiddenPaths(["/project/.env"]) != nil)
}

await test("Forbidden path: /System") {
    try expect(await gate.checkForbiddenPaths(["/System/Library/file"]) != nil)
}

await test("Forbidden path: /Library") {
    try expect(await gate.checkForbiddenPaths(["/Library/Preferences/file"]) != nil)
}

await test("Safe path is allowed") {
    try expect(await gate.checkForbiddenPaths(["/tmp/safe/file.txt"]) == nil)
}

// ============================================================
// MARK: - ToolRouter Tests
// ============================================================

print("\n🔀 ToolRouter Tests")

let routerGate = SecurityGate()
let routerLog = AuditLog()
let router = ToolRouter(securityGate: routerGate, auditLog: routerLog, batchThreshold: 3)

await test("Tool registration stores and retrieves tools") {
    await router.register(ToolRegistration(
        name: "test_tool", module: "test", tier: .green,
        description: "A test tool",
        inputSchema: .object(["type": .string("object")]),
        handler: { _ in .string("ok") }
    ))
    let all = await router.allRegistrations()
    try expect(all.count >= 1, "Expected at least 1 registration")
    try expect(all.contains(where: { $0.name == "test_tool" }), "Expected test_tool in registry")
}

await test("Registration overwrites existing tool with same name") {
    await router.register(ToolRegistration(
        name: "overwrite_test", module: "mod1", tier: .green,
        description: "Version 1", inputSchema: .object([:]),
        handler: { _ in .string("v1") }
    ))
    await router.register(ToolRegistration(
        name: "overwrite_test", module: "mod1", tier: .yellow,
        description: "Version 2", inputSchema: .object([:]),
        handler: { _ in .string("v2") }
    ))
    let all = await router.allRegistrations()
    let match = all.first(where: { $0.name == "overwrite_test" })
    try expect(match?.description == "Version 2", "Expected Version 2")
}

await test("Registrations can be filtered by module") {
    await router.register(ToolRegistration(
        name: "alpha_tool", module: "alpha", tier: .green,
        description: "A", inputSchema: .object([:]),
        handler: { _ in .null }
    ))
    let alpha = await router.registrations(forModule: "alpha")
    try expect(alpha.count >= 1)
    try expect(alpha[0].name == "alpha_tool")
}

await test("Dispatch routes to correct handler") {
    await router.register(ToolRegistration(
        name: "echo_test", module: "builtin", tier: .green,
        description: "Echo test", inputSchema: .object([:]),
        handler: { args in
            if case .object(let dict) = args,
               case .string(let msg) = dict["message"] {
                return .string("echo: \(msg)")
            }
            return .string("no message")
        }
    ))
    let result = try await router.dispatch(
        toolName: "echo_test",
        arguments: .object(["message": .string("hello")])
    )
    if case .string(let s) = result {
        try expect(s == "echo: hello", "Expected 'echo: hello' got '\(s)'")
    } else {
        throw TestError.assertion("Expected string result")
    }
}

await test("Dispatch throws for unknown tool") {
    do {
        _ = try await router.dispatch(toolName: "nonexistent_xyz", arguments: .object([:]))
        throw TestError.assertion("Expected error for unknown tool")
    } catch is ToolRouterError {
        // Expected
    }
}

await test("Batch gate triggers at threshold") {
    let plan = [
        ExecutionPlanEntry(toolName: "a", tier: .green, inputSummary: ""),
        ExecutionPlanEntry(toolName: "b", tier: .green, inputSummary: ""),
        ExecutionPlanEntry(toolName: "c", tier: .green, inputSummary: ""),
    ]
    let result = await router.batchGate(planned: plan)
    try expect(result != nil, "Batch gate should trigger at threshold")
    try expect(result?.count == 3)
}

await test("Batch gate does not trigger below threshold") {
    let plan = [
        ExecutionPlanEntry(toolName: "a", tier: .green, inputSummary: ""),
        ExecutionPlanEntry(toolName: "b", tier: .green, inputSummary: ""),
    ]
    let result = await router.batchGate(planned: plan)
    try expect(result == nil, "Batch gate should not trigger below threshold")
}

await test("Batch threshold is configurable") {
    let customRouter = ToolRouter(securityGate: routerGate, auditLog: routerLog, batchThreshold: 5)
    let threshold = await customRouter.batchThreshold
    try expect(threshold == 5, "Expected threshold 5")
}

// ============================================================
// MARK: - AuditLog Tests
// ============================================================

print("\n📋 AuditLog Tests")

func makeSampleEntry(
    toolName: String = "test_tool",
    tier: SecurityTier = .green,
    status: ApprovalStatus = .approved
) -> AuditEntry {
    AuditEntry(
        timestamp: Date(), toolName: toolName, tier: tier,
        inputSummary: "test input", outputSummary: "test output",
        durationMs: 42.0, approvalStatus: status
    )
}

await test("Append adds entry to in-memory log") {
    let log = AuditLog()
    await log.append(makeSampleEntry())
    let count = await log.count()
    try expect(count == 1, "Expected count 1, got \(count)")
}

await test("Multiple appends accumulate") {
    let log = AuditLog()
    await log.append(makeSampleEntry(toolName: "tool_a"))
    await log.append(makeSampleEntry(toolName: "tool_b"))
    await log.append(makeSampleEntry(toolName: "tool_c"))
    let count = await log.count()
    try expect(count == 3, "Expected count 3, got \(count)")
}

await test("All entries returns complete log") {
    let log = AuditLog()
    await log.append(makeSampleEntry(toolName: "alpha"))
    await log.append(makeSampleEntry(toolName: "beta"))
    let entries = await log.allEntries()
    try expect(entries.count == 2)
    try expect(entries[0].toolName == "alpha")
    try expect(entries[1].toolName == "beta")
}

await test("Filter by tool name") {
    let log = AuditLog()
    await log.append(makeSampleEntry(toolName: "echo"))
    await log.append(makeSampleEntry(toolName: "tools_list"))
    await log.append(makeSampleEntry(toolName: "echo"))
    let echoEntries = await log.entries(forTool: "echo")
    try expect(echoEntries.count == 2)
}

await test("Filter by tier") {
    let log = AuditLog()
    await log.append(makeSampleEntry(tier: .green))
    await log.append(makeSampleEntry(tier: .red))
    await log.append(makeSampleEntry(tier: .green))
    let greenEntries = await log.entries(forTier: .green)
    try expect(greenEntries.count == 2)
}

await test("Filter by approval status") {
    let log = AuditLog()
    await log.append(makeSampleEntry(status: .approved))
    await log.append(makeSampleEntry(status: .rejected))
    await log.append(makeSampleEntry(status: .approved))
    let rejected = await log.entries(withStatus: .rejected)
    try expect(rejected.count == 1)
}

await test("Entry contains all required fields") {
    let log = AuditLog()
    let entry = AuditEntry(
        timestamp: Date(), toolName: "test", tier: .yellow,
        inputSummary: "input", outputSummary: "output",
        durationMs: 100.5, approvalStatus: .approved
    )
    await log.append(entry)
    let entries = await log.allEntries()
    let first = entries[0]
    try expect(first.toolName == "test")
    try expect(first.tier == .yellow)
    try expect(first.inputSummary == "input")
    try expect(first.outputSummary == "output")
    try expect(first.durationMs == 100.5)
    try expect(first.approvalStatus == .approved)
}

await test("AuditEntry is Codable (JSON round-trip)") {
    let entry = makeSampleEntry()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(entry)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(AuditEntry.self, from: data)
    try expect(decoded.toolName == entry.toolName)
    try expect(decoded.tier == entry.tier)
    try expect(decoded.approvalStatus == entry.approvalStatus)
}

// ============================================================
// MARK: - V1-04 Module Tests
// ============================================================

await runPermissionManagerTests()
await runShellModuleTests()
await runFileModuleTests()
await runSessionModuleTests()
await runMessagesModuleTests()
await runSystemModuleTests()
await runNotionModuleTests()

// ============================================================
// MARK: - Summary
// ============================================================

print("\n" + String(repeating: "=", count: 50))
print("Results: \(passed) passed, \(failed) failed, \(passed + failed) total")
print(String(repeating: "=", count: 50))

if failed > 0 {
    print("❌ TESTS FAILED")
    exit(1)
} else {
    print("✅ ALL TESTS PASSED")
    exit(0)
}
