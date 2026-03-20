// ConnectionHealthChecker.swift — Connection Health Status & Validation
// NotionBridge · Config
// PKT-368 D1: Per-connection health badge logic
//
// Provides health status enum and validation utilities for workspace connections.
// Supports Notion (via NotionClientRegistry) and Google Drive (via token check).
// Uses actor isolation for thread-safe caching of health results.

import Foundation

// MARK: - Connection Health Status

/// Health status for a configured connection.
/// Used by the Connections tab to display colored badges per connection.
public enum ConnectionHealth: String, Sendable {
    case healthy       // Token valid, API reachable — 🟢 green
    case warning       // Token expiring soon or intermittent — 🟡 yellow
    case error         // Token invalid/expired, API unreachable — 🔴 red
    case unconfigured  // No token set — ⚪ gray
    case checking      // Currently validating — 🟠 orange (transient)

    public var label: String {
        switch self {
        case .healthy:       return "Connected"
        case .warning:       return "Token Expiring"
        case .error:         return "Disconnected"
        case .unconfigured:  return "Not Configured"
        case .checking:      return "Checking…"
        }
    }

    public var systemImage: String {
        switch self {
        case .healthy:       return "circle.fill"
        case .warning:       return "exclamationmark.circle.fill"
        case .error:         return "xmark.circle.fill"
        case .unconfigured:  return "circle.dashed"
        case .checking:      return "circle.dotted"
        }
    }

    /// Whether this status represents a usable connection.
    public var isUsable: Bool {
        self == .healthy || self == .warning
    }
}

// MARK: - Connection Health Checker

/// Actor-based health checker with time-based caching.
/// Validates connections by attempting lightweight API calls.
public actor ConnectionHealthChecker {

    public static let shared = ConnectionHealthChecker()

    private var cache: [String: (health: ConnectionHealth, timestamp: Date)] = [:]
    private let cacheDuration: TimeInterval = 60  // Cache for 60 seconds

    private init() {}

    // MARK: - Notion Connection Health

    /// Check health of a Notion connection by attempting a lightweight API call.
    /// Uses NotionClientRegistry to get the client, then calls getMe().
    public func checkNotionHealth(connectionName: String) async -> ConnectionHealth {
        let key = "notion:\(connectionName)"
        if let cached = cache[key],
           Date().timeIntervalSince(cached.timestamp) < cacheDuration {
            return cached.health
        }

        do {
            let client = try await NotionClientRegistry.shared.getClient(workspace: connectionName)
            // Attempt lightweight validate() — cheapest health check on NotionClient
            let result = await client.validate()
            guard result.success else {
                let health = ConnectionHealth.error
                cache[key] = (health, Date())
                return health
            }
            let health = ConnectionHealth.healthy
            cache[key] = (health, Date())
            return health
        } catch {
            let errorStr = error.localizedDescription.lowercased()
            let health: ConnectionHealth
            if errorStr.contains("no token") || errorStr.contains("not configured") || errorStr.contains("not found") {
                health = .unconfigured
            } else {
                health = .error
            }
            cache[key] = (health, Date())
            return health
        }
    }


    // MARK: - Cache Management

    /// Invalidate cached health for a specific connection.
    public func invalidate(connectionName: String) {
        cache.removeValue(forKey: "notion:\(connectionName)")
    }

    /// Invalidate all cached health statuses.
    public func invalidateAll() {
        cache.removeAll()
    }
}
