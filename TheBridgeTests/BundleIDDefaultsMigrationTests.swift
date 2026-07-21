// BundleIDDefaultsMigrationTests.swift — W5B UserDefaults suite cutover

import Foundation
import TheBridgeLib

func runBundleIDDefaultsMigrationTests() async {
    print("\n📦 BundleIDDefaultsMigration Tests (W5B)")

    await test("W5B: skips when current bundle id is not the-bridge") {
        let suite = "kup.solutions.the-bridge.tests.w5b.skip.\(UUID().uuidString)"
        let current = UserDefaults(suiteName: suite)!
        defer { current.removePersistentDomain(forName: suite) }
        let report = BundleIDDefaultsMigration.runOnce(
            currentBundleID: "kup.solutions.notion-bridge",
            current: current,
            priorDomain: ["com.notionbridge.credentialsEnabled": true],
            log: { _ in }
        )
        try expect(report.skipped)
        try expect(current.object(forKey: BundleIDDefaultsMigration.sentinelKey) == nil)
    }

    await test("W5B: skips when bundle id is nil") {
        let suite = "kup.solutions.the-bridge.tests.w5b.nil.\(UUID().uuidString)"
        let current = UserDefaults(suiteName: suite)!
        defer { current.removePersistentDomain(forName: suite) }
        let report = BundleIDDefaultsMigration.runOnce(
            currentBundleID: nil,
            current: current,
            priorDomain: ["k": "v"],
            log: { _ in }
        )
        try expect(report.skipped)
    }

    await test("W5B: empty prior domain still sets sentinel (no thrash)") {
        let suite = "kup.solutions.the-bridge.tests.w5b.empty.\(UUID().uuidString)"
        let current = UserDefaults(suiteName: suite)!
        defer { current.removePersistentDomain(forName: suite) }
        let report = BundleIDDefaultsMigration.runOnce(
            currentBundleID: BundleIDDefaultsMigration.canonicalBundleID,
            current: current,
            priorDomain: [:],
            log: { _ in }
        )
        try expect(!report.alreadyComplete)
        try expect(report.keysCopied == 0)
        try expect(current.bool(forKey: BundleIDDefaultsMigration.sentinelKey) == true)
        let second = BundleIDDefaultsMigration.runOnce(
            currentBundleID: BundleIDDefaultsMigration.canonicalBundleID,
            current: current,
            priorDomain: ["com.notionbridge.credentialsEnabled": true],
            log: { _ in }
        )
        try expect(second.alreadyComplete)
        try expect(current.object(forKey: "com.notionbridge.credentialsEnabled") == nil)
    }

    await test("W5B: copies prior suite keys once, then no-ops") {
        let suite = "kup.solutions.the-bridge.tests.w5b.cur.\(UUID().uuidString)"
        let current = UserDefaults(suiteName: suite)!
        defer { current.removePersistentDomain(forName: suite) }

        let prior: [String: Any] = [
            "com.notionbridge.credentialsEnabled": true,
            "tunnelURL": "https://example.test/mcp",
        ]
        current.set("keep-me", forKey: "alreadyOnNew")

        let first = BundleIDDefaultsMigration.runOnce(
            currentBundleID: BundleIDDefaultsMigration.canonicalBundleID,
            current: current,
            priorDomain: prior,
            log: { _ in }
        )
        try expect(!first.alreadyComplete)
        try expect(first.keysCopied == 2)
        try expect(current.bool(forKey: "com.notionbridge.credentialsEnabled") == true)
        try expect(current.string(forKey: "tunnelURL") == "https://example.test/mcp")
        try expect(current.string(forKey: "alreadyOnNew") == "keep-me")
        try expect(current.bool(forKey: BundleIDDefaultsMigration.sentinelKey) == true)

        let second = BundleIDDefaultsMigration.runOnce(
            currentBundleID: BundleIDDefaultsMigration.canonicalBundleID,
            current: current,
            priorDomain: [
                "com.notionbridge.credentialsEnabled": false,
                "tunnelURL": "https://should-not-apply.test/mcp",
            ],
            log: { _ in }
        )
        try expect(second.alreadyComplete)
        try expect(current.bool(forKey: "com.notionbridge.credentialsEnabled") == true)
        try expect(current.string(forKey: "tunnelURL") == "https://example.test/mcp")
    }
}
