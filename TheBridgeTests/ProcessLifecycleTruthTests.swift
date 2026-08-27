// ProcessLifecycleTruthTests.swift — PKT-1196
// Residual terminal-state / timeout / descendant-cleanup contract.
// Does not reimplement BgProcessRuntime process-group ownership.

import Darwin
import Foundation
import TheBridgeLib

func runProcessLifecycleTruthTests() async {
    print("\n📟 ProcessLifecycleTruth (PKT-1196 · residual terminal receipt)")

    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    let t1 = Date(timeIntervalSince1970: 1_700_000_010)

    await test("Lifecycle: stillRunning cannot be false while pid or group is alive") {
        try expect(ProcessLifecycleTruth.stillRunning(pidAlive: true, processGroupAlive: false))
        try expect(ProcessLifecycleTruth.stillRunning(pidAlive: false, processGroupAlive: true))
        try expect(!ProcessLifecycleTruth.stillRunning(pidAlive: false, processGroupAlive: false))
    }

    await test("Lifecycle: descendant cleanup is incomplete while any requested workload lives") {
        try expect(ProcessLifecycleTruth.descendantCleanup(pidAlive: false, processGroupAlive: true) == .incomplete)
        try expect(ProcessLifecycleTruth.descendantCleanup(pidAlive: false, processGroupAlive: false) == .verified)
    }

    await test("Lifecycle: timeout receipts distinguish continuation, verified termination, and ambiguous") {
        try expect(ProcessLifecycleTruth.classifyTimeout(requestTimedOut: true, pidAlive: true, processGroupAlive: true)
                   == .requestTimeoutWorkloadContinuing)
        try expect(ProcessLifecycleTruth.classifyTimeout(requestTimedOut: true, pidAlive: false, processGroupAlive: false)
                   == .verifiedGroupTermination)
        try expect(ProcessLifecycleTruth.classifyTimeout(requestTimedOut: true, pidAlive: false, processGroupAlive: true)
                   == .ambiguous)
        try expect(ProcessLifecycleTruth.classifyTimeout(requestTimedOut: false, pidAlive: false, processGroupAlive: false) == nil)
    }

    await test("Lifecycle: no terminal fixture remains unclassified") {
        let cases: [(ProcessLifecycleState, () -> ProcessLifecycleState)] = [
            (.launchFailed, { ProcessLifecycleTruth.classifyTerminal(
                launchFailed: true, launchError: "posix_spawn", pidAssigned: false,
                pidAlive: false, processGroupAlive: false, exitCode: nil, signal: nil, missedWait: false) }),
            (.starting, { ProcessLifecycleTruth.classifyTerminal(
                launchFailed: false, launchError: nil, pidAssigned: false,
                pidAlive: false, processGroupAlive: false, exitCode: nil, signal: nil, missedWait: false) }),
            (.running, { ProcessLifecycleTruth.classifyTerminal(
                launchFailed: false, launchError: nil, pidAssigned: true,
                pidAlive: true, processGroupAlive: true, exitCode: nil, signal: nil, missedWait: false) }),
            (.exited, { ProcessLifecycleTruth.classifyTerminal(
                launchFailed: false, launchError: nil, pidAssigned: true,
                pidAlive: false, processGroupAlive: false, exitCode: 0, signal: nil, missedWait: false) }),
            (.signaled, { ProcessLifecycleTruth.classifyTerminal(
                launchFailed: false, launchError: nil, pidAssigned: true,
                pidAlive: false, processGroupAlive: false, exitCode: -1, signal: SIGTERM, missedWait: false) }),
            (.orphaned, { ProcessLifecycleTruth.classifyTerminal(
                launchFailed: false, launchError: nil, pidAssigned: true,
                pidAlive: false, processGroupAlive: false, exitCode: nil, signal: nil, missedWait: true) }),
        ]
        for (expected, classify) in cases {
            try expect(classify() == expected, "expected \(expected.rawValue), got \(classify().rawValue)")
        }
    }

    await test("Lifecycle: wrapper exit with live descendants is ambiguous and stillRunning") {
        let receipt = ProcessLifecycleTruth.classifyShell(
            command: "wrapper",
            timedOut: true,
            pid: 42,
            pidAlive: false,
            processGroupAlive: true,
            exitCode: 0,
            signaled: nil,
            launchError: nil,
            startedAt: t0,
            endedAt: t1,
            now: t1
        )
        try expect(receipt.timeoutOutcome == .ambiguous)
        try expect(receipt.stillRunning, "descendants alive ⇒ stillRunning must stay true")
        try expect(receipt.descendantCleanup == .incomplete)
        try expect(receipt.state == .running)
    }

    await test("Lifecycle: shipped bg unknown maps to orphaned without replacing BgProcessStatus") {
        let receipt = ProcessLifecycleTruth.classifyBgJob(
            status: .unknown,
            pidAlive: false,
            processGroupAlive: false,
            exitCode: nil,
            killSignal: nil,
            note: "orphan reconciled on relaunch — pid 9 absent",
            command: "sleep 9",
            pid: 9,
            pgid: 9,
            startedAt: t0,
            endedAt: t1,
            logPath: "/tmp/job/stdout",
            now: t1
        )
        try expect(receipt.state == .orphaned)
        try expect(receipt.orphanReason?.contains("absent") == true)
        try expect(!receipt.stillRunning)
        try expect(BgProcessStatus.unknown.rawValue == "unknown", "shipped status enum must remain")
    }

    await test("Lifecycle: bg killed maps to signaled; incomplete cleanup is a failure state") {
        let dirty = ProcessLifecycleTruth.classifyBgJob(
            status: .killed,
            pidAlive: false,
            processGroupAlive: true,
            exitCode: -1,
            killSignal: SIGKILL,
            note: nil,
            command: "sleep 99",
            pid: 11,
            pgid: 11,
            startedAt: t0,
            endedAt: t1,
            logPath: nil,
            now: t1
        )
        try expect(dirty.state == .signaled)
        try expect(dirty.descendantCleanup == .incomplete)
        try expect(dirty.stillRunning, "group still alive is unreported workload")
    }

    await test("Lifecycle: nonzero empty-output exit and zero exit are both exited") {
        let zero = ProcessLifecycleTruth.classifyTerminal(
            launchFailed: false, launchError: nil, pidAssigned: true,
            pidAlive: false, processGroupAlive: false, exitCode: 0, signal: nil, missedWait: false)
        let nonzero = ProcessLifecycleTruth.classifyTerminal(
            launchFailed: false, launchError: nil, pidAssigned: true,
            pidAlive: false, processGroupAlive: false, exitCode: 1, signal: nil, missedWait: false)
        try expect(zero == .exited && nonzero == .exited)
    }

    await test("Lifecycle: command hash is durable and command-sensitive") {
        let a = ProcessLifecycleTruth.commandHash("echo hi")
        let b = ProcessLifecycleTruth.commandHash("echo ho")
        try expect(a.count == 64 && a != b)
    }
}
