// CalendarRegistryFeature.swift — Env gate for Calendar–Registry private-smoke MCP tool
// TheBridge · Security

import Foundation

/// Env-controlled discoverability for `calendar_registry_pair`.
/// When `BRIDGE_INTERNAL_CALENDAR_REGISTRY_SYNC != 1`, the tool is omitted from
/// ListTools and dispatch fail-closes (credential-style filter).
public enum CalendarRegistryFeature: Sendable {
    public static let gatedToolNames: Set<String> = [
        CalendarRegistryModule.toolName,
    ]

    /// Test seam — when set, overrides `ProcessInfo` for enablement checks.
    public nonisolated(unsafe) static var environmentOverride: [String: String]?

    public static var currentEnvironment: [String: String] {
        environmentOverride ?? ProcessInfo.processInfo.environment
    }

    public static var isEnabled: Bool {
        CalendarRegistrySyncComposition.featureState(
            environment: currentEnvironment
        ) == .enabledForPrivateSmoke
    }

    /// Tool names to hide from ListTools when the private-smoke env is off.
    public static func disabledToolNamesIfGated(
        environment: [String: String]? = nil
    ) -> Set<String> {
        let env = environment ?? currentEnvironment
        return CalendarRegistrySyncComposition.featureState(environment: env) == .enabledForPrivateSmoke
            ? []
            : gatedToolNames
    }
}

/// Combined ListTools disable set: user-disabled ∪ credential gate ∪ calendar-registry gate.
public enum ToolListingGates: Sendable {
    public static func mergedDisabledToolNames() -> Set<String> {
        var names = CredentialsFeature.mergedDisabledToolNames()
        names.formUnion(CalendarRegistryFeature.disabledToolNamesIfGated())
        return names
    }
}
