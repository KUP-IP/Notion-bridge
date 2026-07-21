// W5BCutoverContinuityTests.swift — ACL heal sentinel-first + access-group allowlist

import Foundation
import Security
import TheBridgeLib

func runW5BCutoverContinuityTests() async {
    print("\n🔐 W5B Cutover Continuity Tests (ACL heal + access groups)")

    await test("W5B: ACL heal begin sets sentinel before any walk would run") {
        let suite = "kup.solutions.the-bridge.tests.w5b.acl.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        try expect(defaults.bool(forKey: KeychainManager.aclHealedKey) == false)
        let shouldWalk = KeychainManager.beginACLHealIfNeeded(defaults: defaults)
        try expect(shouldWalk == true)
        try expect(defaults.bool(forKey: KeychainManager.aclHealedKey) == true)

        // Second call must refuse the walk even if a prior force-quit interrupted it.
        let again = KeychainManager.beginACLHealIfNeeded(defaults: defaults)
        try expect(again == false)
        try expect(defaults.bool(forKey: KeychainManager.aclHealedKey) == true)
    }

    await test("W5B: suppressACLHeal marks sentinel without requiring a walk") {
        let suite = "kup.solutions.the-bridge.tests.w5b.acl.suppress.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        KeychainManager.suppressACLHeal(defaults: defaults)
        try expect(defaults.bool(forKey: KeychainManager.aclHealedKey) == true)
        try expect(KeychainManager.beginACLHealIfNeeded(defaults: defaults) == false)
    }

    await test("W5B: accessGroupsOwned includes prior + canonical bundle ids") {
        let groups = CredentialManager.accessGroupsOwned(
            prefix: "TEAMID.",
            currentBundleID: "kup.solutions.the-bridge"
        )
        try expect(groups.contains("TEAMID.kup.solutions.the-bridge"))
        try expect(groups.contains("TEAMID.kup.solutions.notion-bridge"))
        try expect(groups.count == 2)
    }

    await test("W5B: accessGroupsOwned still lists both when current is prior id") {
        let groups = CredentialManager.accessGroupsOwned(
            prefix: "ABC.",
            currentBundleID: "kup.solutions.notion-bridge"
        )
        try expect(groups == [
            "ABC.kup.solutions.notion-bridge",
            "ABC.kup.solutions.the-bridge",
        ])
    }

    await test("W5B: matchesAccessGroup accepts prior-id group after cutover") {
        let priorGroup = "VP24Z9CS22.kup.solutions.notion-bridge"
        let item: [String: Any] = [
            kSecAttrAccessGroup as String: priorGroup,
            kSecAttrService as String: "license-ed25519",
            kSecAttrAccount as String: "private",
        ]
        try expect(CredentialManager.matchesAccessGroup(item: item, expected: priorGroup) == true)
        try expect(
            CredentialManager.matchesAccessGroup(
                item: item,
                expected: "VP24Z9CS22.kup.solutions.the-bridge"
            ) == false
        )
        // Owned-list semantics: either group counts as ours.
        let owned = CredentialManager.accessGroupsOwned(
            prefix: "VP24Z9CS22.",
            currentBundleID: "kup.solutions.the-bridge"
        )
        try expect(owned.contains { CredentialManager.matchesAccessGroup(item: item, expected: $0) })
    }

    await test("W5B: KeychainManager legacyServices still include prior id") {
        try expect(KeychainManager.legacyServices.contains("kup.solutions.notion-bridge"))
        try expect(KeychainManager.service == "kup.solutions.the-bridge")
    }
}
