// SystemModule.swift – V1-05 System Tools
// NotionBridge · Modules
//
// Three tools: system_info (green), process_list (green), notify (yellow).
// Uses sw_vers, sysctl, ps, and osascript for macOS integration.

import Foundation
import MCP

// MARK: - SystemModule

/// Provides macOS system information, process listing, and notification tools.
public enum SystemModule {

    public static let moduleName = "system"

    /// Register all SystemModule tools on the given router.
    public static func register(on router: ToolRouter) async {

        // MARK: 1. system_info – 🟢 Green
        await router.register(ToolRegistration(
            name: "system_info",
            module: moduleName,
            tier: .open,
            description: "Returns macOS system information: OS version, hardware model, CPU, memory, hostname, and uptime.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "required": .array([])
            ]),
            handler: { _ in
                var info: [String: Value] = [:]

                // OS version via sw_vers
                if let swVers = try? shellOutput("/usr/bin/sw_vers") {
                    let lines = swVers.components(separatedBy: "\n")
                    for line in lines {
                        let parts = line.split(separator: ":", maxSplits: 1)
                        if parts.count == 2 {
                            let key = parts[0].trimmingCharacters(in: .whitespaces)
                            let val = parts[1].trimmingCharacters(in: .whitespaces)
                            switch key {
                            case "ProductName": info["osName"] = .string(val)
                            case "ProductVersion": info["osVersion"] = .string(val)
                            case "BuildVersion": info["osBuild"] = .string(val)
                            default: break
                            }
                        }
                    }
                }

                // Hostname
                info["hostname"] = .string(ProcessInfo.processInfo.hostName)

                // CPU info via sysctl
                if let cpuBrand = try? shellOutput("/usr/sbin/sysctl", args: ["-n", "machdep.cpu.brand_string"]) {
                    info["cpu"] = .string(cpuBrand.trimmingCharacters(in: .whitespacesAndNewlines))
                }

                // CPU core count
                info["cpuCores"] = .int(ProcessInfo.processInfo.processorCount)
                info["cpuActiveCores"] = .int(ProcessInfo.processInfo.activeProcessorCount)

                // Physical memory
                let memBytes = ProcessInfo.processInfo.physicalMemory
                let memGB = Double(memBytes) / (1024 * 1024 * 1024)
                info["memoryGB"] = .double((memGB * 100).rounded() / 100)

                // System uptime
                let uptime = ProcessInfo.processInfo.systemUptime
                let days = Int(uptime) / 86400
                let hours = (Int(uptime) % 86400) / 3600
                let minutes = (Int(uptime) % 3600) / 60
                info["uptime"] = .string("\(days)d \(hours)h \(minutes)m")
                info["uptimeSeconds"] = .double(uptime)

                // Hardware model via sysctl
                if let model = try? shellOutput("/usr/sbin/sysctl", args: ["-n", "hw.model"]) {
                    info["hardwareModel"] = .string(model.trimmingCharacters(in: .whitespacesAndNewlines))
                }

                return .object(info)
            }
        ))

        // MARK: 2. process_list – 🟢 Green
        await router.register(ToolRegistration(
            name: "process_list",
            module: moduleName,
            tier: .open,
            description: "List running processes. Supports optional filter by name and limit on results. Returns PID, name, CPU%, MEM%, and user.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "filter": .object(["type": .string("string"), "description": .string("Optional process name filter (case-insensitive substring match)")]),
                    "limit": .object(["type": .string("integer"), "description": .string("Max processes to return (default: 50)")]),
                    "sortBy": .object(["type": .string("string"), "description": .string("Sort by: cpu, mem, pid, name (default: cpu)")])
                ]),
                "required": .array([])
            ]),
            handler: { arguments in
                let filter: String? = {
                    if case .object(let args) = arguments,
                       case .string(let f) = args["filter"] { return f }
                    return nil
                }()
                let limit: Int = {
                    if case .object(let args) = arguments,
                       case .int(let l) = args["limit"] { return l }
                    return 50
                }()
                let sortBy: String = {
                    if case .object(let args) = arguments,
                       case .string(let s) = args["sortBy"] { return s }
                    return "cpu"
                }()

                // ps output sorted by CPU by default
                let sortFlag: String
                switch sortBy.lowercased() {
                case "mem": sortFlag = "-m"
                case "pid": sortFlag = "-p"
                default: sortFlag = "-r" // sort by CPU
                }

                guard let output = try? shellOutput("/bin/ps", args: ["aux", sortFlag]) else {
                    return .object(["error": .string("Failed to execute ps")])
                }

                var lines = output.components(separatedBy: "\n")
                // Remove header
                let header = lines.removeFirst()
                _ = header // suppress unused warning

                var processes: [Value] = []
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty { continue }

                    // Parse ps aux columns: USER PID %CPU %MEM VSZ RSS TT STAT STARTED TIME COMMAND
                    let parts = trimmed.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: true)
                    if parts.count < 11 { continue }

                    let user = String(parts[0])
                    let pid = String(parts[1])
                    let cpu = String(parts[2])
                    let mem = String(parts[3])
                    let command = String(parts[10])

                    // Apply filter
                    if let f = filter {
                        let lowerFilter = f.lowercased()
                        if !command.lowercased().contains(lowerFilter) &&
                           !user.lowercased().contains(lowerFilter) {
                            continue
                        }
                    }

                    processes.append(.object([
                        "user": .string(user),
                        "pid": .string(pid),
                        "cpu": .string(cpu),
                        "mem": .string(mem),
                        "command": .string(command)
                    ]))

                    if processes.count >= limit { break }
                }

                return .object([
                    "count": .int(processes.count),
                    "sortedBy": .string(sortBy),
                    "processes": .array(processes)
                ])
            }
        ))

        // MARK: 3. notify – 🟡 Yellow (Write-Auto)
        await router.register(ToolRegistration(
            name: "notify",
            module: moduleName,
            tier: .open,
            description: "Send a macOS notification via osascript. Displays a system notification with title and body text.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "title": .object(["type": .string("string"), "description": .string("Notification title")]),
                    "body": .object(["type": .string("string"), "description": .string("Notification body text")]),
                    "sound": .object(["type": .string("string"), "description": .string("Optional sound name (e.g., 'Glass', 'Basso', 'Ping')")])
                ]),
                "required": .array([.string("title"), .string("body")])
            ]),
            handler: { arguments in
                guard case .object(let args) = arguments,
                      case .string(let title) = args["title"],
                      case .string(let body) = args["body"] else {
                    throw ToolRouterError.unknownTool("notify: missing 'title' or 'body'")
                }

                let sound: String? = {
                    if case .string(let s) = args["sound"] { return s }
                    return nil
                }()

                // Sanitize for AppleScript
                let safeTitle = title
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
                let safeBody = body
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")

                var script = "display notification \"\(safeBody)\" with title \"\(safeTitle)\""
                if let sound = sound {
                    let safeSound = sound
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
                    script += " sound name \"\(safeSound)\""
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]

                let stderrPipe = Pipe()
                process.standardOutput = Pipe() // suppress stdout
                process.standardError = stderrPipe

                try process.run()
                process.waitUntilExit()

                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                if process.terminationStatus == 0 {
                    return .object([
                        "sent": .bool(true),
                        "title": .string(title),
                        "bodyLength": .int(body.utf8.count)
                    ])
                } else {
                    return .object([
                        "sent": .bool(false),
                        "error": .string(stderr.isEmpty ? "osascript failed" : stderr)
                    ])
                }
            }
        ))
    }

    // MARK: - Shell Helper

    /// Run a command and capture stdout.
    private static func shellOutput(_ executable: String, args: [String] = []) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
