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
    public static let marketing = "1.5.0"

    /// Build number (CFBundleVersion equivalent).
    /// Monotonically increasing integer per release.
    public static let build = "6"

    /// Combined display string for UI and logs.
    public static var display: String { "\(marketing) (\(build))" }

    /// Fallback for Bundle.main lookups — use this instead of hardcoded strings.
    public static var resolved: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? marketing
    }
}

/// Protocol and networking constants for NotionBridge.
public enum BridgeConstants {
    /// MCP protocol version supported by this build.
    public static let mcpProtocolVersion = "2024-11-05"
    /// Default SSE server port.
    public static let defaultSSEPort = 9700
}
