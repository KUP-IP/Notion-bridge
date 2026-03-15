// ShellModuleTests.swift – V1-04 ShellModule Tests
// NotionBridge · Tests

import Foundation
import MCP
import NotionBridgeLib

// MARK: - ShellModule Tests

func runShellModuleTests() async {
    print("\n🐚 ShellModule Tests")

    // Set up a fresh router with SecurityGate + AuditLog
    let gate = SecurityGate()
    let log = AuditLog()
    let router = ToolRouter(securityGate: gate, auditLog: log, batchThreshold: 10)
    await ShellModule.register(on: router)

    // Verify registration
    await test("ShellModule registers 2 tools") {
        let tools = await router.registrations(forModule: "shell")
        try expect(tools.count == 2, "Expected 2 shell tools, got \(tools.count)")
        let names = Set(tools.map(\.name))
        try expect(names.contains("shell_exec"), "Missing shell_exec")
        try expect(names.contains("run_script"), "Missing run_script")
    }

    await test("shell_exec tier is orange") {
        let tools = await router.registrations(forModule: "shell")
        let shellExec = tools.first(where: { $0.name == "shell_exec" })!
        try expect(shellExec.tier == .notify, "Expected orange, got \(shellExec.tier.rawValue)")
    }

    await test("run_script tier is green") {
        let tools = await router.registrations(forModule: "shell")
        let runScript = tools.first(where: { $0.name == "run_script" })!
        try expect(runScript.tier == .open, "Expected green, got \(runScript.tier.rawValue)")
    }

    // shell_exec: basic command
    await test("shell_exec runs echo and returns stdout") {
        let result = try await router.dispatch(
            toolName: "shell_exec",
            arguments: .object(["command": .string("echo hello_notionbridge")])
        )
        if case .object(let dict) = result,
           case .string(let stdout) = dict["stdout"],
           case .int(let exitCode) = dict["exitCode"] {
            try expect(stdout.contains("hello_notionbridge"), "stdout should contain hello_notionbridge")
            try expect(exitCode == 0, "Expected exit code 0, got \(exitCode)")
        } else {
            throw TestError.assertion("Unexpected result format")
        }
    }

    // shell_exec: stderr capture
    await test("shell_exec captures stderr") {
        let result = try await router.dispatch(
            toolName: "shell_exec",
            arguments: .object(["command": .string("echo err_msg >&2")])
        )
        if case .object(let dict) = result,
           case .string(let stderr) = dict["stderr"] {
            try expect(stderr.contains("err_msg"), "stderr should contain err_msg")
        } else {
            throw TestError.assertion("Unexpected result format")
        }
    }

    // shell_exec: exit code
    await test("shell_exec returns non-zero exit code") {
        let result = try await router.dispatch(
            toolName: "shell_exec",
            arguments: .object(["command": .string("exit 42")])
        )
        if case .object(let dict) = result,
           case .int(let exitCode) = dict["exitCode"] {
            try expect(exitCode == 42, "Expected exit code 42, got \(exitCode)")
        } else {
            throw TestError.assertion("Unexpected result format")
        }
    }

    // shell_exec: duration is returned
    await test("shell_exec returns duration field") {
        let result = try await router.dispatch(
            toolName: "shell_exec",
            arguments: .object(["command": .string("echo fast")])
        )
        if case .object(let dict) = result,
           case .double(let duration) = dict["duration"] {
            try expect(duration >= 0, "Duration should be non-negative")
        } else {
            throw TestError.assertion("Expected duration field in result")
        }
    }

    // shell_exec: working directory
    await test("shell_exec respects workingDir") {
        let result = try await router.dispatch(
            toolName: "shell_exec",
            arguments: .object([
                "command": .string("pwd"),
                "workingDir": .string("/tmp")
            ])
        )
        if case .object(let dict) = result,
           case .string(let stdout) = dict["stdout"] {
            try expect(stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "/private/tmp"
                     || stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "/tmp",
                     "Expected /tmp, got \(stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
        } else {
            throw TestError.assertion("Unexpected result format")
        }
    }

    // shell_exec: timeout (use short timeout with sleep)
    await test("shell_exec timeout terminates long-running process") {
        let result = try await router.dispatch(
            toolName: "shell_exec",
            arguments: .object([
                "command": .string("sleep 10 && echo done"),
                "timeout": .int(1)
            ])
        )
        if case .object(let dict) = result,
           case .int(let exitCode) = dict["exitCode"] {
            // Process terminated by signal should have non-zero exit code
            try expect(exitCode != 0, "Expected non-zero exit code for timed-out process")
        } else {
            throw TestError.assertion("Unexpected result format")
        }
    }

    // shell_exec: missing command param
    await test("shell_exec rejects missing command") {
        do {
            _ = try await router.dispatch(
                toolName: "shell_exec",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing command")
        } catch is ToolRouterError {
            // Expected
        }
    }

    // run_script: rejects unapproved script
    await test("run_script rejects unapproved script name") {
        let result = try await router.dispatch(
            toolName: "run_script",
            arguments: .object(["scriptName": .string("nonexistent_xyz_script.sh")])
        )
        if case .object(let dict) = result,
           case .string(let error) = dict["error"] {
            try expect(error.contains("not on the approved list") || error.contains("does not exist") || error.contains("No approved scripts"),
                       "Expected rejection message, got: \(error)")
        } else {
            throw TestError.assertion("Expected error object for unapproved script")
        }
    }

    // run_script: missing scriptName param
    await test("run_script rejects missing scriptName") {
        do {
            _ = try await router.dispatch(
                toolName: "run_script",
                arguments: .object([:])
            )
            throw TestError.assertion("Expected error for missing scriptName")
        } catch is ToolRouterError {
            // Expected
        }
    }

    // Auto-escalation: these are tested via SecurityGate, but verify the tier assignment is correct
    await test("shell_exec is registered at orange tier (auto-escalation eligible)") {
        let tools = await router.allRegistrations()
        let shellExec = tools.first(where: { $0.name == "shell_exec" })!
        try expect(shellExec.tier == .notify, "shell_exec must be orange tier")
    }
}
