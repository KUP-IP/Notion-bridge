// ShellModule.swift – V1-04 Shell Command Execution
// NotionBridge · Modules
//
// Two tools: shell_exec (notify), run_script (open).
// Auto-escalation and forbidden path enforcement handled by SecurityGate.

import Foundation
import MCP

// MARK: - ShellModule

/// Provides shell command execution and approved script running.
/// Security enforcement (tier gating, auto-escalation, forbidden paths)
/// is handled by SecurityGate at the ToolRouter dispatch level.
public enum ShellModule {

    public static let moduleName = "shell"

    /// Register all ShellModule tools on the given router.
    public static func register(on router: ToolRouter) async {

        // MARK: shell_exec – notify
        await router.register(ToolRegistration(
            name: "shell_exec",
            module: moduleName,
            tier: .notify,
            description: "Execute a shell command with optional timeout and working directory. Returns stdout, stderr, exit code, and duration in seconds. SecurityGate enforces auto-escalation patterns and forbidden path restrictions.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "command": .object([
                        "type": .string("string"),
                        "description": .string("The shell command to execute")
                    ]),
                    "timeout": .object([
                        "type": .string("integer"),
                        "description": .string("Timeout in seconds (default: 30)")
                    ]),
                    "workingDir": .object([
                        "type": .string("string"),
                        "description": .string("Working directory for command execution")
                    ])
                ]),
                "required": .array([.string("command")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let command) = args["command"] else {
                    throw ToolRouterError.invalidArguments(toolName: "shell_exec", reason: "missing required 'command' parameter")
                }

                let timeout: Int = {
                    if case .int(let t) = args["timeout"] { return t }
                    return 30
                }()

                let workingDir: String? = {
                    if case .string(let dir) = args["workingDir"] { return dir }
                    return nil
                }()

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = ["-c", command]

                if let dir = workingDir {
                    process.currentDirectoryURL = URL(fileURLWithPath: dir)
                }

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                let startTime = ContinuousClock.now

                try process.run()

                // Timeout enforcement — terminate process if it exceeds the limit
                let timeoutItem = DispatchWorkItem {
                    if process.isRunning {
                        process.terminate()
                    }
                }
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + .seconds(timeout),
                    execute: timeoutItem
                )

                // Read pipe data BEFORE waitUntilExit to prevent buffer deadlock
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                process.waitUntilExit()
                timeoutItem.cancel()

                let elapsed = ContinuousClock.now - startTime
                let durationSec = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000.0
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                return .object([
                    "stdout": .string(stdout),
                    "stderr": .string(stderr),
                    "exitCode": .int(Int(process.terminationStatus)),
                    "duration": .double(durationSec)
                ])
            }
        ))

        // MARK: run_script – open
        await router.register(ToolRegistration(
            name: "run_script",
            module: moduleName,
            tier: .open,
            description: "Execute a pre-approved script from the scripts directory. Only scripts listed in the approved scripts file can run. Returns stdout, stderr, and exit code.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "scriptName": .object([
                        "type": .string("string"),
                        "description": .string("Name of the script file to execute (e.g., cleanup.py)")
                    ]),
                    "args": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Optional arguments to pass to the script")
                    ])
                ]),
                "required": .array([.string("scriptName")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let scriptName) = args["scriptName"] else {
                    throw ToolRouterError.invalidArguments(toolName: "run_script", reason: "missing required 'scriptName' parameter")
                }

                // Validate scripts directory exists
                let scriptsDir = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".mcp_scripts")
                guard FileManager.default.fileExists(atPath: scriptsDir.path) else {
                    return .object([
                        "error": .string("Scripts directory does not exist: \(scriptsDir.path)")
                    ])
                }

                // Load approved scripts list
                let approvedListPath = scriptsDir.appendingPathComponent(".approved_scripts")
                let approvedScripts: [String]
                if FileManager.default.fileExists(atPath: approvedListPath.path),
                   let data = FileManager.default.contents(atPath: approvedListPath.path),
                   let content = String(data: data, encoding: .utf8) {
                    approvedScripts = content.components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                } else {
                    return .object([
                        "error": .string("No approved scripts list found at \(approvedListPath.path)")
                    ])
                }

                // Reject if not on approved list
                guard approvedScripts.contains(scriptName) else {
                    return .object([
                        "error": .string("Script '\(scriptName)' is not on the approved list. Approved: \(approvedScripts.joined(separator: ", "))")
                    ])
                }

                let scriptPath = scriptsDir.appendingPathComponent(scriptName)

                // PKT-373 P1-2: Path traversal prevention -- resolve to canonical path
                let resolvedPath = scriptPath.standardizedFileURL.path
                let resolvedDir = scriptsDir.standardizedFileURL.path
                guard resolvedPath.hasPrefix(resolvedDir + "/") || resolvedPath == resolvedDir else {
                    return .object([
                        "error": .string("Path traversal blocked: resolved path is outside scripts directory")
                    ])
                }

                guard FileManager.default.fileExists(atPath: scriptPath.path) else {
                    return .object([
                        "error": .string("Script file not found: \(scriptPath.path)")
                    ])
                }

                // Parse optional args
                var scriptArgs: [String] = []
                if case .array(let argsArray) = args["args"] {
                    for arg in argsArray {
                        if case .string(let s) = arg {
                            scriptArgs.append(s)
                        }
                    }
                }

                let process = Process()
                process.executableURL = scriptPath
                process.arguments = scriptArgs
                process.currentDirectoryURL = scriptsDir

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                try process.run()

                // PKT-373 P1-3: Timeout enforcement (default 30s, matching shell_exec)
                let scriptTimeout: Int = {
                    if case .int(let t) = args["timeout"] { return max(1, t) }
                    return 30
                }()
                let timeoutItem = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + .seconds(scriptTimeout),
                    execute: timeoutItem
                )

                // PKT-373 P0-3: Read pipes BEFORE waitUntilExit to prevent deadlock
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                process.waitUntilExit()
                timeoutItem.cancel()
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                return .object([
                    "stdout": .string(stdout),
                    "stderr": .string(stderr),
                    "exitCode": .int(Int(process.terminationStatus))
                ])
            }
        ))
    }
}
