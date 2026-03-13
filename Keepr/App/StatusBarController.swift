// StatusBarController.swift — Observable State for Menu Bar + Popover
// V1-02: Manages connection count, tool count, uptime, and tool call count
// PKT-317: Added totalToolCalls counter for live server status in DashboardView

import Foundation
import Observation

/// Observable state controller for the menu bar app.
/// Provides live connection count, registered tool count, total tool calls,
/// and server uptime to the DashboardView popover. All state updates are
/// main-actor-isolated for safe SwiftUI binding.
@MainActor
@Observable
public final class StatusBarController {

    public init() {}

    // MARK: - Live Status

    /// Number of active client connections (SSE + stdio)
    public var activeConnections: Int = 0

    /// Number of registered MCP tools
    public var registeredToolCount: Int = 0

    /// Total number of tool calls dispatched since server start
    public var totalToolCalls: Int = 0

    /// Server start time (nil if server not running)
    public var serverStartTime: Date? = nil

    /// Formatted uptime string
    public var uptimeString: String {
        guard let start = serverStartTime else { return "Not running" }
        let interval = Date().timeIntervalSince(start)
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        let seconds = Int(interval) % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }

    /// Whether the MCP server is currently running
    public var isServerRunning: Bool {
        serverStartTime != nil
    }

    // MARK: - Server Lifecycle

    /// Mark the server as started with the given tool count.
    public func markServerStarted(toolCount: Int) {
        serverStartTime = Date()
        registeredToolCount = toolCount
        totalToolCalls = 0
    }

    /// Mark the server as stopped. Resets connections and uptime.
    public func markServerStopped() {
        serverStartTime = nil
        activeConnections = 0
    }

    /// Update the active connection count.
    public func updateConnections(_ count: Int) {
        activeConnections = count
    }

    /// Increment the tool call counter. Called by ServerManager after each dispatch.
    public func incrementToolCalls() {
        totalToolCalls += 1
    }
}
