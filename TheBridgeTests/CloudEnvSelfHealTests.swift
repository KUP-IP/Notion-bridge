// CloudEnvSelfHealTests.swift — boot-order cloud-env self-heal
// TheBridge · Tests
//
// Live-caught regression (2026-07-02): a restart raced The Bridge's own
// relaunch ahead of the `solutions.kup.bridge-env` LaunchAgent, so the app
// spawned with no WorkOS/cloud env, connectorAuth stayed nil for that
// process's life, and every real connector token (ChatGPT, Claude.ai) was
// rejected — surfacing as a confusing "reconnect" error with no path back to
// the cause. `launchctl getenv WORKOS_CLIENT_ID` was confirmed empty
// immediately after the restart; manually bootstrapping the LaunchAgent
// fixed it instantly. This suite covers the pure decision logic + the
// injectable-seam wiring of the repair action — never touches real launchd,
// NSWorkspace, or NSApplication.

import Foundation
import TheBridgeLib

func runCloudEnvSelfHealTests() async {
    print("\n🩹 CloudEnvSelfHeal — boot-order cloud-env repair")

    // MARK: - shouldAttemptRepair (pure decision)

    await test("shouldAttemptRepair: cloud access OFF never repairs, even with env missing") {
        let should = CloudEnvSelfHeal.shouldAttemptRepair(
            cloudAccessEnabled: false,
            environment: [:],
            alreadyAttempted: false
        )
        try expect(should == false, "a default (cloud-off) install must never trigger a relaunch over missing cloud env")
    }

    await test("shouldAttemptRepair: cloud ON + BRIDGE_ENABLE_HTTP present -> no repair needed") {
        let should = CloudEnvSelfHeal.shouldAttemptRepair(
            cloudAccessEnabled: true,
            environment: ["BRIDGE_ENABLE_HTTP": "1"],
            alreadyAttempted: false
        )
        try expect(should == false, "env is present — nothing to repair")
    }

    await test("shouldAttemptRepair: cloud ON + BRIDGE_ENABLE_HTTP absent + not yet attempted -> repair") {
        let should = CloudEnvSelfHeal.shouldAttemptRepair(
            cloudAccessEnabled: true,
            environment: [:],
            alreadyAttempted: false
        )
        try expect(should == true, "this is exactly the live-caught boot-race signature")
    }

    await test("shouldAttemptRepair: cloud ON + env absent + ALREADY attempted -> loop guard fires, no repair") {
        let should = CloudEnvSelfHeal.shouldAttemptRepair(
            cloudAccessEnabled: true,
            environment: [:],
            alreadyAttempted: true
        )
        try expect(should == false, "must never attempt a second relaunch in the same boot — the LaunchAgent may genuinely be broken, and a loop would be worse than a degraded session")
    }

    await test("shouldAttemptRepair: other env vars present but BRIDGE_ENABLE_HTTP specifically absent -> repair") {
        // BRIDGE_ENABLE_HTTP is the single canary ServerManager.setup() gates
        // connectorAuth on — a partial/corrupted env is still a repair case.
        let should = CloudEnvSelfHeal.shouldAttemptRepair(
            cloudAccessEnabled: true,
            environment: ["WORKOS_CLIENT_ID": "client_abc"],
            alreadyAttempted: false
        )
        try expect(should == true, "BRIDGE_ENABLE_HTTP missing is the trigger regardless of which other vars are present")
    }

    // MARK: - wasRelaunchedBySelfHeal

    await test("wasRelaunchedBySelfHeal: true when the marker argument is present") {
        let was = CloudEnvSelfHeal.wasRelaunchedBySelfHeal(arguments: ["/path/to/TheBridge", CloudEnvSelfHeal.relaunchMarkerArg])
        try expect(was == true, "marker argument must be detected")
    }

    await test("wasRelaunchedBySelfHeal: false on a normal launch with no marker") {
        let was = CloudEnvSelfHeal.wasRelaunchedBySelfHeal(arguments: ["/path/to/TheBridge"])
        try expect(was == false, "a normal launch must never be treated as a post-repair relaunch")
    }

    // MARK: - attemptRepairAndRelaunch (injected-seam wiring)

    await test("attemptRepairAndRelaunch: calls bootstrap with the expected plist URL, then relaunch, then terminate, in order") {
        // Plain (non-actor) recorder: attemptRepairAndRelaunch is @MainActor
        // and calls bootstrap/scheduleDetachedRelaunch/terminate SYNCHRONOUSLY
        // in source order — no Task{} indirection needed or wanted here. An
        // earlier version of this test wrapped each record in `Task { await
        // actor.record(...) }`, which raced independently-scheduled tasks
        // against each other with no ordering guarantee and produced a false
        // failure (order came back scrambled) despite the real synchronous
        // call sequence being correct — a lesson in not adding concurrency
        // machinery a test doesn't actually need.
        var calls: [String] = []
        var bootstrapURL: URL?
        let expectedPlist = URL(fileURLWithPath: "/Users/fixture/Library/LaunchAgents/solutions.kup.bridge-env.plist")

        await CloudEnvSelfHeal.attemptRepairAndRelaunch(
            launchAgentPlist: expectedPlist,
            bootstrap: { url in
                bootstrapURL = url
                calls.append("bootstrap")
            },
            scheduleDetachedRelaunch: { calls.append("relaunch") },
            terminate: { calls.append("terminate") }
        )

        try expect(calls == ["bootstrap", "relaunch", "terminate"], "must repair, then relaunch, then terminate — in exactly that order, got: \(calls)")
        try expect(bootstrapURL == expectedPlist, "must bootstrap the injected plist URL, not a hardcoded path")
    }

    await test("attemptRepairAndRelaunch: default plist URL points at solutions.kup.bridge-env.plist under the real LaunchAgents dir") {
        var capturedURL: URL?
        await CloudEnvSelfHeal.attemptRepairAndRelaunch(
            bootstrap: { url in capturedURL = url },
            scheduleDetachedRelaunch: {},
            terminate: {}
        )
        try expect(capturedURL?.lastPathComponent == "solutions.kup.bridge-env.plist", "default plist target must match the real LaunchAgent's label")
        try expect(capturedURL?.path.contains("Library/LaunchAgents") == true, "default plist target must live under ~/Library/LaunchAgents")
    }
}
