// WorktreeCommandModule.swift — claim-aware, argv-only build/test execution.

import CryptoKit
import Darwin
import Foundation
import MCP

public enum WorktreeCommandError: Error, LocalizedError, Sendable, Equatable {
    case invalid(String)
    case identityChanged(String)
    case ownershipRequired(String)
    case spawnFailed(String)

    public var code: String {
        switch self {
        case .invalid: return "invalid_arguments"
        case .identityChanged: return "worktree_identity_changed"
        case .ownershipRequired: return "worktree_ownership_required"
        case .spawnFailed: return "worktree_command_spawn_failed"
        }
    }

    public var errorDescription: String? {
        let detail: String
        switch self {
        case .invalid(let value), .identityChanged(let value),
             .ownershipRequired(let value), .spawnFailed(let value):
            detail = value
        }
        return "\(code): \(detail)"
    }
}

public struct WorktreeCommandInvocation: Sendable, Equatable {
    public let worktreePath: String
    public let ownerSession: String
    public let expectedBranch: String
    public let expectedHead: String
    public let executable: String
    public let argv: [String]
    public let declaredWriteRoots: [String]
    public let timeoutSeconds: Int

    public init(
        worktreePath: String,
        ownerSession: String,
        expectedBranch: String,
        expectedHead: String,
        executable: String,
        argv: [String],
        declaredWriteRoots: [String],
        timeoutSeconds: Int
    ) {
        self.worktreePath = worktreePath
        self.ownerSession = ownerSession
        self.expectedBranch = expectedBranch
        self.expectedHead = expectedHead
        self.executable = executable
        self.argv = argv
        self.declaredWriteRoots = declaredWriteRoots
        self.timeoutSeconds = timeoutSeconds
    }
}

private final class WorktreeCommandProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var didTimeOut = false

    func markTimedOut() {
        lock.lock()
        didTimeOut = true
        lock.unlock()
    }

    func timedOut() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return didTimeOut
    }
}

private final class WorktreeCommandDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func set(_ data: Data) {
        lock.lock()
        storage = data
        lock.unlock()
    }

    func get() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private struct WorktreeCommandProcessResult: Sendable {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
    let timedOut: Bool
    let durationMilliseconds: Int
}

private struct WorktreeCommandRepositorySnapshot: Sendable {
    let statusSHA256: String
    let contentSHA256: String
    let fileSHA256: [String: String]
}

public enum WorktreeCommandContract {
    private static let makeTargets: Set<String> = ["debug", "test", "test-floor", "build"]
    private static let swiftArgv: Set<[String]> = [
        ["build", "-c", "debug"],
        ["build", "-c", "release", "-Xswiftc", "-strict-concurrency=complete"],
    ]

    public static func validate(_ invocation: WorktreeCommandInvocation) throws -> WorktreeCommandInvocation {
        guard invocation.worktreePath.hasPrefix("/"),
              !invocation.ownerSession.isEmpty,
              !invocation.expectedBranch.isEmpty,
              invocation.expectedHead.range(of: "^[0-9a-fA-F]{40}$", options: .regularExpression) != nil else {
            throw WorktreeCommandError.invalid("worktreePath, ownerSession, expectedBranch, and a 40-character expectedHead are required")
        }
        guard (1...3600).contains(invocation.timeoutSeconds) else {
            throw WorktreeCommandError.invalid("timeoutSeconds must be within 1...3600")
        }
        guard !invocation.declaredWriteRoots.isEmpty else {
            throw WorktreeCommandError.invalid("declaredWriteRoots must contain at least one bounded path")
        }
        for value in [invocation.executable] + invocation.argv + invocation.declaredWriteRoots {
            guard !value.isEmpty,
                  !value.unicodeScalars.contains(where: { $0.value == 0 || $0.value == 10 || $0.value == 13 }) else {
                throw WorktreeCommandError.invalid("executable, argv, and declaredWriteRoots must be non-empty and contain no control separators")
            }
        }

        let worktree = try canonicalDirectory(invocation.worktreePath)
        let executable = URL(fileURLWithPath: invocation.executable).standardizedFileURL.path
        let allowed: Bool
        switch executable {
        case "/usr/bin/make":
            allowed = invocation.argv.count == 1 && makeTargets.contains(invocation.argv[0])
        case "/usr/bin/swift":
            allowed = swiftArgv.contains(invocation.argv)
        default:
            let debugTests = worktree + "/.build/debug/TheBridgeTests"
            allowed = executable == debugTests && invocation.argv.isEmpty
        }
        guard allowed else {
            throw WorktreeCommandError.invalid(
                "executable/argv is outside the reviewed build-test allowlist; shell strings, Git, install, push, merge, tag, release, and arbitrary scripts are not supported"
            )
        }
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw WorktreeCommandError.invalid("approved executable is not available at the requested absolute path")
        }

        var roots: [String] = []
        for rawRoot in invocation.declaredWriteRoots {
            let root = try canonicalWriteRoot(rawRoot, worktree: worktree)
            guard root != worktree, root != worktree + "/.git" else {
                throw WorktreeCommandError.invalid("declaredWriteRoots may not grant the entire worktree or Git metadata")
            }
            if !roots.contains(root) { roots.append(root) }
        }
        return WorktreeCommandInvocation(
            worktreePath: worktree,
            ownerSession: invocation.ownerSession,
            expectedBranch: invocation.expectedBranch,
            expectedHead: invocation.expectedHead.lowercased(),
            executable: executable,
            argv: invocation.argv,
            declaredWriteRoots: roots.sorted(),
            timeoutSeconds: invocation.timeoutSeconds
        )
    }

    private static func canonicalDirectory(_ raw: String) throws -> String {
        let url = URL(fileURLWithPath: raw).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WorktreeCommandError.invalid("worktreePath must be an existing directory")
        }
        return url.path
    }

    private static func canonicalWriteRoot(_ raw: String, worktree: String) throws -> String {
        let candidate = raw.hasPrefix("/")
            ? URL(fileURLWithPath: raw)
            : URL(fileURLWithPath: worktree).appendingPathComponent(raw)
        let standardized = candidate.standardizedFileURL
        let resolved: URL
        if FileManager.default.fileExists(atPath: standardized.path) {
            resolved = standardized.resolvingSymlinksInPath()
        } else {
            let parent = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
            resolved = parent.appendingPathComponent(standardized.lastPathComponent).standardizedFileURL
        }
        guard resolved.path.hasPrefix(worktree + "/") else {
            throw WorktreeCommandError.invalid("declaredWriteRoots must remain inside the claimed worktree and may not escape through .. or symlinks")
        }
        return resolved.path
    }
}

public enum WorktreeCommandModule {
    public static let moduleName = "dev"
    private static let maxReturnedBytes = 64 * 1024

    public static func register(on router: ToolRouter) async {
        await router.register(ToolRegistration(
            name: "worktree_command_run",
            module: moduleName,
            tier: .request,
            description: "Run one reviewed build or test command in an already-claimed Git worktree. Accepts an absolute executable plus argv (never a shell string), verifies owner/branch/HEAD before and after, bounds declared write roots to the worktree, and returns exact command/output/status digests. It cannot run Git, install, push, merge, tag, release, destructive commands, or arbitrary scripts.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "worktreePath": stringProperty("Canonical claimed worktree path."),
                    "ownerSession": stringProperty("Owner session of the active worktree claim."),
                    "expectedBranch": stringProperty("Exact branch expected before and after execution."),
                    "expectedHead": stringProperty("Exact 40-character HEAD SHA expected before and after execution."),
                    "executable": stringProperty("Absolute allow-listed executable path; no shell is used."),
                    "argv": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Argument vector. Shell syntax, substitution, and glob expansion are never interpreted.")
                    ]),
                    "declaredWriteRoots": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Bounded absolute or worktree-relative paths expected to receive build/test writes.")
                    ]),
                    "timeoutSeconds": .object([
                        "type": .string("integer"),
                        "minimum": .int(1),
                        "maximum": .int(3600),
                        "description": .string("Foreground execution timeout.")
                    ])
                ]),
                "required": .array([
                    "worktreePath", "ownerSession", "expectedBranch", "expectedHead",
                    "executable", "argv", "declaredWriteRoots", "timeoutSeconds"
                ].map(Value.string)),
                "additionalProperties": .bool(false)
            ]),
            handler: { arguments in
                do {
                    let invocation = try parse(arguments)
                    return try await execute(invocation)
                } catch let error as WorktreeCommandError {
                    return errorValue(error)
                } catch {
                    return errorValue(.spawnFailed(error.localizedDescription))
                }
            }
        ))
    }

    private static func parse(_ arguments: Value) throws -> WorktreeCommandInvocation {
        guard case .object(let object) = arguments,
              let worktreePath = string(object["worktreePath"]),
              let ownerSession = string(object["ownerSession"]),
              let expectedBranch = string(object["expectedBranch"]),
              let expectedHead = string(object["expectedHead"]),
              let executable = string(object["executable"]),
              let argv = strings(object["argv"]),
              let roots = strings(object["declaredWriteRoots"]),
              case .int(let timeoutSeconds) = object["timeoutSeconds"] else {
            throw WorktreeCommandError.invalid("required worktree command tuple is incomplete")
        }
        return try WorktreeCommandContract.validate(.init(
            worktreePath: worktreePath,
            ownerSession: ownerSession,
            expectedBranch: expectedBranch,
            expectedHead: expectedHead,
            executable: executable,
            argv: argv,
            declaredWriteRoots: roots,
            timeoutSeconds: timeoutSeconds
        ))
    }

    private static func execute(_ invocation: WorktreeCommandInvocation) async throws -> Value {
        let beforeIdentity = try WorktreeOwnershipGuard.liveIdentity(for: invocation.worktreePath)
        try verifyIdentity(beforeIdentity, invocation: invocation, phase: "preflight")
        guard let permit = WorktreeOwnershipGuard.currentPermit,
              permit.ownerSession == invocation.ownerSession,
              permit.stableIDs.contains(beforeIdentity.stableID) else {
            throw WorktreeCommandError.ownershipRequired("an active task-local permit for this exact owner and worktree is required")
        }

        let beforeSnapshot = try await repositorySnapshot(invocation.worktreePath)
        let startedAt = Date()
        let process = try await runProcess(invocation)
        let finishedAt = Date()
        let afterIdentity = try WorktreeOwnershipGuard.liveIdentity(for: invocation.worktreePath)
        try verifyIdentity(afterIdentity, invocation: invocation, phase: "readback")
        let afterSnapshot = try await repositorySnapshot(invocation.worktreePath)
        let outsideChanges = changedPaths(beforeSnapshot.fileSHA256, afterSnapshot.fileSHA256).filter {
            !isInsideDeclaredRoots($0, invocation: invocation)
        }
        let commandDigest = digest(
            Data(([invocation.executable] + invocation.argv).joined(separator: "\u{0}").utf8)
        )
        let stdoutDigest = digest(process.stdout)
        let stderrDigest = digest(process.stderr)
        let success = process.exitCode == 0 && !process.timedOut && outsideChanges.isEmpty
        let status: String
        if !outsideChanges.isEmpty { status = "write_scope_violation" }
        else if process.timedOut { status = "timed_out" }
        else if process.exitCode == 0 { status = "success" }
        else { status = "failed" }

        return .object([
            "ok": .bool(success),
            "status": .string(status),
            "worktreePath": .string(invocation.worktreePath),
            "ownerSession": .string(invocation.ownerSession),
            "branch": .string(afterIdentity.branch),
            "headSHA": .string(afterIdentity.headSHA),
            "executable": .string(invocation.executable),
            "argv": .array(invocation.argv.map(Value.string)),
            "commandSHA256": .string(commandDigest),
            "declaredWriteRoots": .array(invocation.declaredWriteRoots.map(Value.string)),
            "outsideDeclaredWriteRoots": .array(outsideChanges.sorted().map(Value.string)),
            "preGitStatusSHA256": .string(beforeSnapshot.statusSHA256),
            "postGitStatusSHA256": .string(afterSnapshot.statusSHA256),
            "preWorktreeContentSHA256": .string(beforeSnapshot.contentSHA256),
            "postWorktreeContentSHA256": .string(afterSnapshot.contentSHA256),
            "exitCode": .int(Int(process.exitCode)),
            "timedOut": .bool(process.timedOut),
            "terminationReason": .string(process.timedOut ? "timeout_killed" : (process.exitCode == 0 ? "exited" : "non_zero_exit")),
            "timeoutSeconds": .int(invocation.timeoutSeconds),
            "durationMilliseconds": .int(process.durationMilliseconds),
            "startedAt": .string(ISO8601DateFormatter().string(from: startedAt)),
            "finishedAt": .string(ISO8601DateFormatter().string(from: finishedAt)),
            "stdout": .string(boundedText(process.stdout)),
            "stderr": .string(boundedText(process.stderr)),
            "stdoutSHA256": .string(stdoutDigest),
            "stderrSHA256": .string(stderrDigest),
            "stdoutBytes": .int(process.stdout.count),
            "stderrBytes": .int(process.stderr.count),
            "stdoutTruncated": .bool(process.stdout.count > maxReturnedBytes),
            "stderrTruncated": .bool(process.stderr.count > maxReturnedBytes)
        ])
    }

    private static func verifyIdentity(
        _ identity: WorktreeOwnershipGuard.LiveIdentity,
        invocation: WorktreeCommandInvocation,
        phase: String
    ) throws {
        guard identity.worktreePath == invocation.worktreePath,
              identity.branch == invocation.expectedBranch,
              identity.headSHA.lowercased() == invocation.expectedHead else {
            throw WorktreeCommandError.identityChanged(
                "\(phase) expected {path=\(invocation.worktreePath), branch=\(invocation.expectedBranch), head=\(invocation.expectedHead)} but observed {path=\(identity.worktreePath), branch=\(identity.branch), head=\(identity.headSHA)}"
            )
        }
    }

    private static func runProcess(_ invocation: WorktreeCommandInvocation) async throws -> WorktreeCommandProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: invocation.executable)
                process.arguments = invocation.argv
                process.currentDirectoryURL = URL(fileURLWithPath: invocation.worktreePath)
                let inherited = ProcessInfo.processInfo.environment
                var environment: [String: String] = [
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin",
                    "LANG": inherited["LANG"] ?? "en_US.UTF-8",
                    "LC_ALL": inherited["LC_ALL"] ?? "en_US.UTF-8"
                ]
                for key in ["HOME", "TMPDIR", "DEVELOPER_DIR", "SDKROOT"] {
                    if let value = inherited[key] { environment[key] = value }
                }
                process.environment = environment
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                let state = WorktreeCommandProcessBox()
                let outData = WorktreeCommandDataBox()
                let errData = WorktreeCommandDataBox()
                let ioGroup = DispatchGroup()
                let started = Date()
                do {
                    try process.run()
                    ioGroup.enter()
                    DispatchQueue.global(qos: .utility).async {
                        outData.set(stdout.fileHandleForReading.readDataToEndOfFile())
                        ioGroup.leave()
                    }
                    ioGroup.enter()
                    DispatchQueue.global(qos: .utility).async {
                        errData.set(stderr.fileHandleForReading.readDataToEndOfFile())
                        ioGroup.leave()
                    }
                    let timeout = DispatchWorkItem {
                        if process.isRunning {
                            state.markTimedOut()
                            process.terminate()
                            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                            }
                        }
                    }
                    DispatchQueue.global().asyncAfter(
                        deadline: .now() + .seconds(invocation.timeoutSeconds),
                        execute: timeout
                    )
                    process.waitUntilExit()
                    timeout.cancel()
                    ioGroup.wait()
                    continuation.resume(returning: WorktreeCommandProcessResult(
                        exitCode: process.terminationStatus,
                        stdout: outData.get(),
                        stderr: errData.get(),
                        timedOut: state.timedOut(),
                        durationMilliseconds: Int(Date().timeIntervalSince(started) * 1000)
                    ))
                } catch {
                    continuation.resume(throwing: WorktreeCommandError.spawnFailed(error.localizedDescription))
                }
            }
        }
    }

    private static func repositorySnapshot(_ path: String) async throws -> WorktreeCommandRepositorySnapshot {
        let status = try await GitRuntime.spawn(
            executable: "/usr/bin/git",
            args: ["status", "--porcelain=v1", "--untracked-files=all"],
            cwd: path,
            stdin: nil
        )
        guard status.exitCode == 0 else {
            throw WorktreeCommandError.identityChanged("git status readback failed: \(status.stderr)")
        }
        let listing = try await GitRuntime.spawn(
            executable: "/usr/bin/git",
            args: ["ls-files", "-co", "--exclude-standard", "-z"],
            cwd: path,
            stdin: nil
        )
        guard listing.exitCode == 0 else {
            throw WorktreeCommandError.identityChanged("git file inventory readback failed: \(listing.stderr)")
        }
        var files: [String: String] = [:]
        for relative in listing.stdout.split(separator: "\0", omittingEmptySubsequences: true).map(String.init) {
            let absolute = URL(fileURLWithPath: path).appendingPathComponent(relative).standardizedFileURL
            guard absolute.path.hasPrefix(path + "/") else {
                throw WorktreeCommandError.identityChanged("git inventory contained a path outside the worktree")
            }
            if let attributes = try? FileManager.default.attributesOfItem(atPath: absolute.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                let destination = (try? FileManager.default.destinationOfSymbolicLink(atPath: absolute.path)) ?? "<unreadable>"
                files[relative] = digest(Data(("symlink\0" + destination).utf8))
            } else if let data = try? Data(contentsOf: absolute, options: [.mappedIfSafe]) {
                files[relative] = digest(data)
            } else {
                files[relative] = digest(Data("<missing-or-unreadable>".utf8))
            }
        }
        let canonical = files.keys.sorted().map { "\($0)\0\(files[$0]!)" }.joined(separator: "\n")
        return WorktreeCommandRepositorySnapshot(
            statusSHA256: digest(Data(status.stdout.utf8)),
            contentSHA256: digest(Data(canonical.utf8)),
            fileSHA256: files
        )
    }

    private static func changedPaths(
        _ before: [String: String],
        _ after: [String: String]
    ) -> [String] {
        Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }
    }

    private static func isInsideDeclaredRoots(_ relativePath: String, invocation: WorktreeCommandInvocation) -> Bool {
        let absolute = URL(fileURLWithPath: invocation.worktreePath)
            .appendingPathComponent(relativePath)
            .standardizedFileURL.path
        return invocation.declaredWriteRoots.contains { absolute == $0 || absolute.hasPrefix($0 + "/") }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func boundedText(_ data: Data) -> String {
        let clipped = data.prefix(maxReturnedBytes)
        return String(decoding: clipped, as: UTF8.self)
    }

    private static func string(_ value: Value?) -> String? {
        guard case .string(let string) = value, !string.isEmpty else { return nil }
        return string
    }

    private static func strings(_ value: Value?) -> [String]? {
        guard case .array(let values) = value else { return nil }
        var result: [String] = []
        for value in values {
            guard case .string(let string) = value else { return nil }
            result.append(string)
        }
        return result
    }

    private static func stringProperty(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func errorValue(_ error: WorktreeCommandError) -> Value {
        .object([
            "ok": .bool(false),
            "status": .string(error.code),
            "tool": .string("worktree_command_run"),
            "error": .string(error.localizedDescription)
        ])
    }
}
