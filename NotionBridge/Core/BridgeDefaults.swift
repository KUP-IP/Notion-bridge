// BridgeDefaults.swift — Shared UserDefaults key constants
// NotionBridge · Core
//
// Centralizes UserDefaults keys used across multiple files.
// Prevents silent key-mismatch bugs from typos in raw string literals.

import Foundation

/// Canonical UserDefaults keys shared across Security, Server, UI, and Module layers.
public enum BridgeDefaults {
    // MARK: - Tool & Security Configuration

    /// Per-tool tier overrides (Open/Notify/Request). Dictionary<String, String>.
    /// Written by SecurityGate (Always Allow), read by ToolRouter and ToolRegistryView.
    public static let tierOverrides = "com.notionbridge.tierOverrides"

    /// User-disabled tool names. Array<String>.
    /// Written by ToolRegistryView, read by CredentialsFeature and ListTools handlers.
    public static let disabledTools = "com.notionbridge.disabledTools"

    // MARK: - Skills

    /// Encoded skills list. Data (JSON-encoded [Skill]).
    /// Written by SkillsManager and SkillsModule, read at startup.
    public static let skills = "com.notionbridge.skills"

    // MARK: - Onboarding & Legal

    /// Whether the user has completed the onboarding wizard. Bool.
    public static let hasCompletedOnboarding = "hasCompletedOnboarding"

    /// Whether the user has accepted legal terms. Bool.
    public static let hasAcceptedLegalTerms = "hasAcceptedLegalTerms"
}
