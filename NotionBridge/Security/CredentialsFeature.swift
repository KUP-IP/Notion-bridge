// CredentialsFeature.swift — Opt-in gate for Keychain-backed credential MCP tools
// NotionBridge · Security

import Foundation

/// User-controlled flag for credential storage + MCP tools (`credential_*` + `payment_execute`).
public enum CredentialsFeature: Sendable {
    public static let userDefaultsKey = "com.notionbridge.credentialsEnabled"
    private static let migrationDoneKey = "com.notionbridge.credentialsEnabledMigration1"

    /// MCP tools hidden / fail-closed when disabled.
    public static let gatedToolNames: Set<String> = [
        "credential_save",
        "credential_read",
        "credential_list",
        "credential_delete",
        "payment_execute",
    ]

    /// Whether the Credentials feature is on (Keychain + MCP tools).
    public static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: userDefaultsKey)
    }

    /// Disabled tool names for ListTools: user-disabled ∪ gated credentials when feature is off.
    public static func mergedDisabledToolNames() -> Set<String> {
        var names = Set(UserDefaults.standard.stringArray(forKey: BridgeDefaults.disabledTools) ?? [])
        if !isEnabled {
            names.formUnion(gatedToolNames)
        }
        return names
    }

    /// One-time migration: explicit default for `credentialsEnabled`. Fresh installs start off;
    /// upgrades with a completed onboarding prior to this flag keep credentials on.
    public static func migrateIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migrationDoneKey) else { return }
        UserDefaults.standard.set(true, forKey: migrationDoneKey)
        guard UserDefaults.standard.object(forKey: userDefaultsKey) == nil else { return }
        let priorOnboarding = UserDefaults.standard.bool(forKey: BridgeDefaults.hasCompletedOnboarding)
        UserDefaults.standard.set(priorOnboarding, forKey: userDefaultsKey)
    }
}
