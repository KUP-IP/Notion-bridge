// TunnelLaunchAgentHealerTests.swift — sleep/wake LaunchAgent tunnel heal
// Pure decision + injectable kickstart. No real launchd / sleep.

import Foundation
import TheBridgeLib

func runTunnelLaunchAgentHealerTests() async {
    print("\n🔌 TunnelLaunchAgentHealer (wake cloudflared LaunchAgent)")

    let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    await test("decide: disabled never kicks") {
        let d = TunnelLaunchAgentHealer.decide(
            enabled: false,
            networkAvailable: true,
            now: now,
            lastKickAt: nil,
            throttleSeconds: 90
        )
        try expect(d == .skippedDisabled)
    }

    await test("decide: no network skips without kick") {
        let d = TunnelLaunchAgentHealer.decide(
            enabled: true,
            networkAvailable: false,
            now: now,
            lastKickAt: nil,
            throttleSeconds: 90
        )
        try expect(d == .skippedNoNetwork)
    }

    await test("decide: within throttle window skips") {
        let last = now.addingTimeInterval(-30)
        let d = TunnelLaunchAgentHealer.decide(
            enabled: true,
            networkAvailable: true,
            now: now,
            lastKickAt: last,
            throttleSeconds: 90
        )
        try expect(d == .skippedThrottled)
    }

    await test("decide: past throttle or never kicked → kick (not 'agent running' probe)") {
        let d1 = TunnelLaunchAgentHealer.decide(
            enabled: true,
            networkAvailable: true,
            now: now,
            lastKickAt: nil,
            throttleSeconds: 90
        )
        try expect(d1 == .kick, "first wake must kick — process-running is not health")
        let d2 = TunnelLaunchAgentHealer.decide(
            enabled: true,
            networkAvailable: true,
            now: now,
            lastKickAt: now.addingTimeInterval(-120),
            throttleSeconds: 90
        )
        try expect(d2 == .kick, "after throttle elapses must kick again")
    }

    await test("launchctlDomain builds gui/uid/label") {
        let domain = TunnelLaunchAgentHealer.launchctlDomain(uid: 501, label: "com.kup.cloudflared-bridge")
        try expect(domain == "gui/501/com.kup.cloudflared-bridge")
    }

    await test("handleWake: kick path records kick and returns kicked") {
        var kickLabels: [String] = []
        var recorded: Date?
        let outcome = TunnelLaunchAgentHealer.handleWake(
            enabled: true,
            networkAvailable: true,
            now: now,
            lastKickAt: nil,
            throttleSeconds: 90,
            label: "com.example.tunnel",
            recordKick: { recorded = $0 },
            kickstart: { label in kickLabels.append(label) },
            log: { _ in }
        )
        try expect(outcome == .kicked)
        try expect(kickLabels == ["com.example.tunnel"])
        try expect(recorded == now)
    }

    await test("handleWake: throttle path does not call kickstart") {
        var kicks = 0
        let outcome = TunnelLaunchAgentHealer.handleWake(
            enabled: true,
            networkAvailable: true,
            now: now,
            lastKickAt: now.addingTimeInterval(-10),
            throttleSeconds: 90,
            label: "com.example.tunnel",
            recordKick: { _ in },
            kickstart: { _ in kicks += 1 },
            log: { _ in }
        )
        try expect(outcome == .skippedThrottled)
        try expect(kicks == 0)
    }

    await test("handleWake: kickstart failure does not record kick") {
        var recorded = false
        let outcome = TunnelLaunchAgentHealer.handleWake(
            enabled: true,
            networkAvailable: true,
            now: now,
            lastKickAt: nil,
            throttleSeconds: 90,
            label: "com.example.tunnel",
            recordKick: { _ in recorded = true },
            kickstart: { _ in
                throw TunnelLaunchAgentHealer.HealError.kickstartFailed(status: 5, domain: "gui/501/x")
            },
            log: { _ in }
        )
        guard case .failed(let message) = outcome else {
            throw TestError.assertion("expected .failed, got \(outcome)")
        }
        try expect(message.contains("kickstartFailed") || message.contains("5"),
                   "failure message should mention kickstart error: \(message)")
        try expect(recorded == false, "failed kick must not advance throttle clock")
    }

    await test("handleWake: no network does not kick") {
        var kicks = 0
        let outcome = TunnelLaunchAgentHealer.handleWake(
            enabled: true,
            networkAvailable: false,
            now: now,
            lastKickAt: nil,
            throttleSeconds: 90,
            kickstart: { _ in kicks += 1 },
            log: { _ in }
        )
        try expect(outcome == .skippedNoNetwork)
        try expect(kicks == 0)
    }

    await test("BridgeDefaults: label falls back to default when empty") {
        let key = BridgeDefaults.tunnelLaunchAgentLabel
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.removeObject(forKey: key)
        try expect(BridgeDefaults.tunnelLaunchAgentLabelValue == TunnelLaunchAgentHealer.defaultLabel)
        UserDefaults.standard.set("  ", forKey: key)
        try expect(BridgeDefaults.tunnelLaunchAgentLabelValue == TunnelLaunchAgentHealer.defaultLabel)
        UserDefaults.standard.set("com.custom.tunnel", forKey: key)
        try expect(BridgeDefaults.tunnelLaunchAgentLabelValue == "com.custom.tunnel")
    }

    await test("BridgeDefaults: heal enabled defaults ON") {
        let key = BridgeDefaults.tunnelWakeHealEnabled
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.removeObject(forKey: key)
        try expect(BridgeDefaults.tunnelWakeHealEnabledValue == true)
        UserDefaults.standard.set(false, forKey: key)
        try expect(BridgeDefaults.tunnelWakeHealEnabledValue == false)
    }
}
