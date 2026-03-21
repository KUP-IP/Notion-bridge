// Version.swift – Single source of truth for app versioning
// NotionBridge · Config
//
// All runtime version references should use AppVersion constants.
// Info.plist CFBundleShortVersionString must be kept in sync (stamped at build time or manually).
// Hardcoded fallback strings (e.g. ?? "1.1.0") are eliminated — use AppVersion.marketing instead.

import Foundation

/// Central version constants for NotionBridge.
public enum AppVersion {
    /// Marketing version (CFBundleShortVersionString equivalent).
    /// Format: MAJOR.MINOR.PATCH (Semantic Versioning).
    public static let marketing = "1.1.6"

    /// Build number (CFBundleVersion equivalent).
    /// Monotonically increasing integer per release.
    public static let build = "2"

    /// Combined display string for UI and logs.
    public static var display: String { "\(marketing) (\(build))" }

    /// Fallback for Bundle.main lookups — use this instead of hardcoded strings.
    public static var resolved: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? marketing
    }
}

/// Shared constants used across UI + transport layers.
public enum BridgeConstants {
    /// Current MCP protocol version advertised by Notion Bridge.
    public static let mcpProtocolVersion = "2024-11-05"

    /// Default local SSE/MCP port when no override is provided.
    public static let defaultSSEPort = 9700
}
