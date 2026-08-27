// ProcessLifecycleTruth.swift — PKT-1196
// TheBridge · Modules
//
// Residual process-lifecycle contract on top of already-shipped process-group
// ownership (BgProcessRuntime posix_spawn SETPGROUP + SIGTERM→SIGKILL
// killpg). This file does not reimplement group identity or bg_kill. It
// classifies terminal truth, timeout outcomes, and descendant-cleanup evidence
// so receipts cannot report stillRunning=false while a requested workload
// remains alive.

import CryptoKit
import Darwin
import Foundation

public enum ProcessLifecycleState: String, Codable, Sendable, Equatable {
    case starting
    case running
    case exited
    case signaled
    case launchFailed = "launch_failed"
    case orphaned
}

public enum TimeoutOutcome: String, Codable, Sendable, Equatable {
    /// Request window elapsed; the requested workload is still alive.
    case requestTimeoutWorkloadContinuing = "request_timeout_workload_continuing"
    /// Request window elapsed and the process group is proven gone.
    case verifiedGroupTermination = "verified_group_termination"
    /// Request window elapsed; wrapper vs descendants cannot be reconciled.
    case ambiguous = "timeout_ambiguous"
}

public enum DescendantCleanupEvidence: String, Codable, Sendable, Equatable {
    case verified
    case incomplete
    case notApplicable = "not_applicable"
}

public struct ProcessLifecycleReceipt: Sendable, Equatable {
    public let state: ProcessLifecycleState
    public let exitCode: Int32?
    public let signal: Int32?
    public let launchError: String?
    public let orphanReason: String?
    public let commandHash: String
    public let startedAt: Date
    public let endedAt: Date?
    public let supervisorPid: Int32
    public let rootPid: Int32?
    public let pgid: Int32?
    public let logPath: String?
    public let terminalReceiptPath: String?
    public let observedAt: Date
    public let timeoutOutcome: TimeoutOutcome?
    public let stillRunning: Bool
    public let descendantCleanup: DescendantCleanupEvidence

    public init(
        state: ProcessLifecycleState,
        exitCode: Int32?,
        signal: Int32?,
        launchError: String?,
        orphanReason: String?,
        commandHash: String,
        startedAt: Date,
        endedAt: Date?,
        supervisorPid: Int32,
        rootPid: Int32?,
        pgid: Int32?,
        logPath: String?,
        terminalReceiptPath: String?,
        observedAt: Date,
        timeoutOutcome: TimeoutOutcome?,
        stillRunning: Bool,
        descendantCleanup: DescendantCleanupEvidence
    ) {
        self.state = state
        self.exitCode = exitCode
        self.signal = signal
        self.launchError = launchError
        self.orphanReason = orphanReason
        self.commandHash = commandHash
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.supervisorPid = supervisorPid
        self.rootPid = rootPid
        self.pgid = pgid
        self.logPath = logPath
        self.terminalReceiptPath = terminalReceiptPath
        self.observedAt = observedAt
        self.timeoutOutcome = timeoutOutcome
        self.stillRunning = stillRunning
        self.descendantCleanup = descendantCleanup
    }
}

public enum ProcessLifecycleTruth {
    public static func commandHash(_ command: String) -> String {
        SHA256.hash(data: Data(command.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Invariant: stillRunning is true whenever the requested pid OR its
    /// process group still answers kill(…, 0). Callers must not report a
    /// finished receipt while this is true.
    public static func stillRunning(pidAlive: Bool, processGroupAlive: Bool) -> Bool {
        pidAlive || processGroupAlive
    }

    public static func descendantCleanup(pidAlive: Bool, processGroupAlive: Bool) -> DescendantCleanupEvidence {
        if pidAlive { return .incomplete }
        if processGroupAlive { return .incomplete }
        return .verified
    }

    public static func classifyTimeout(
        requestTimedOut: Bool,
        pidAlive: Bool,
        processGroupAlive: Bool
    ) -> TimeoutOutcome? {
        guard requestTimedOut else { return nil }
        let workloadAlive = stillRunning(pidAlive: pidAlive, processGroupAlive: processGroupAlive)
        if workloadAlive && pidAlive { return .requestTimeoutWorkloadContinuing }
        if workloadAlive { return .ambiguous }
        return .verifiedGroupTermination
    }

    public static func classifyTerminal(
        launchFailed: Bool,
        launchError: String?,
        pidAssigned: Bool,
        pidAlive: Bool,
        processGroupAlive: Bool,
        exitCode: Int32?,
        signal: Int32?,
        missedWait: Bool
    ) -> ProcessLifecycleState {
        if launchFailed || (!pidAssigned && launchError != nil) { return .launchFailed }
        if stillRunning(pidAlive: pidAlive, processGroupAlive: processGroupAlive) {
            return pidAssigned ? .running : .starting
        }
        if missedWait { return .orphaned }
        if signal != nil { return .signaled }
        if exitCode != nil { return .exited }
        if !pidAssigned { return .starting }
        return .orphaned
    }

    /// Map shipped `BgProcessStatus` without replacing it. Residual truth lives
    /// on the receipt; runtime status values stay as they are.
    public static func classifyBgJob(
        status: BgProcessStatus,
        pidAlive: Bool,
        processGroupAlive: Bool,
        exitCode: Int32?,
        killSignal: Int32?,
        note: String?,
        command: String,
        pid: Int32,
        pgid: Int32,
        startedAt: Date,
        endedAt: Date?,
        logPath: String?,
        now: Date
    ) -> ProcessLifecycleReceipt {
        let workloadAlive = stillRunning(pidAlive: pidAlive, processGroupAlive: processGroupAlive)
        let state: ProcessLifecycleState
        switch status {
        case .running:
            state = workloadAlive ? .running : .orphaned
        case .done:
            state = .exited
        case .failed:
            state = killSignal != nil ? .signaled : .exited
        case .killed:
            state = .signaled
        case .unknown:
            state = .orphaned
        }
        let cleanup: DescendantCleanupEvidence
        if status == .running && workloadAlive {
            cleanup = .notApplicable
        } else {
            cleanup = descendantCleanup(pidAlive: pidAlive, processGroupAlive: processGroupAlive)
        }
        return ProcessLifecycleReceipt(
            state: state,
            exitCode: exitCode,
            signal: killSignal,
            launchError: nil,
            orphanReason: state == .orphaned ? (note ?? "pid absent or wait missed") : nil,
            commandHash: commandHash(command),
            startedAt: startedAt,
            endedAt: endedAt,
            supervisorPid: getpid(),
            rootPid: pid,
            pgid: pgid,
            logPath: logPath,
            terminalReceiptPath: logPath,
            observedAt: now,
            timeoutOutcome: nil,
            stillRunning: workloadAlive,
            descendantCleanup: cleanup
        )
    }

    public static func classifyShell(
        command: String,
        timedOut: Bool,
        pid: Int32,
        pidAlive: Bool,
        processGroupAlive: Bool,
        exitCode: Int32,
        signaled: Int32?,
        launchError: String?,
        startedAt: Date,
        endedAt: Date,
        now: Date
    ) -> ProcessLifecycleReceipt {
        let state = classifyTerminal(
            launchFailed: launchError != nil,
            launchError: launchError,
            pidAssigned: pid > 0,
            pidAlive: pidAlive,
            processGroupAlive: processGroupAlive,
            exitCode: launchError == nil ? exitCode : nil,
            signal: signaled,
            missedWait: false
        )
        let workloadAlive = stillRunning(pidAlive: pidAlive, processGroupAlive: processGroupAlive)
        return ProcessLifecycleReceipt(
            state: state,
            exitCode: launchError == nil ? exitCode : nil,
            signal: signaled,
            launchError: launchError,
            orphanReason: nil,
            commandHash: commandHash(command),
            startedAt: startedAt,
            endedAt: endedAt,
            supervisorPid: getpid(),
            rootPid: pid > 0 ? pid : nil,
            pgid: pid > 0 ? pid : nil,
            logPath: nil,
            terminalReceiptPath: nil,
            observedAt: now,
            timeoutOutcome: classifyTimeout(
                requestTimedOut: timedOut,
                pidAlive: pidAlive,
                processGroupAlive: processGroupAlive
            ),
            stillRunning: workloadAlive,
            descendantCleanup: timedOut || signaled != nil
                ? descendantCleanup(pidAlive: pidAlive, processGroupAlive: processGroupAlive)
                : .notApplicable
        )
    }

    public static func processAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return Darwin.kill(pid, 0) == 0
    }

    public static func processGroupAlive(_ pgid: Int32) -> Bool {
        guard pgid > 0 else { return false }
        return Darwin.kill(-pgid, 0) == 0
    }
}
