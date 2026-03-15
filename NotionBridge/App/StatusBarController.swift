// StatusBarController.swift — Observable State for Menu Bar + Popover
// V1-02: Manages connection count, tool count, uptime, and tool call count
// PKT-317: Added totalToolCalls counter for live server status in DashboardView
// PKT-320: Added notionTokenStatus for Notion API token health indicator
// V1-QUALITY-C2: Added connectedClients array for client identification.
//   Stores client name, version, and connection time from MCP initialize clientInfo.

import Foundation
import Observation

/// Lightweight tool metadata for UI display (PKT-350: F2).
public struct ToolInfo: Sendable, Identifiable {
    public let name: String
    public let module: String
    public let tier: String
    public let description: String
    public var id: String { name }

    public init(name: String, module: String, tier: String, description: String) {
        self.name = name
        self.module = module
        self.tier = tier
        self.description = description
    }
}

/// Connected client info parsed from MCP initialize request's clientInfo field.
public struct ConnectedClient: Sendable, Equatable {
    public let name: String
    public let version: String
    public let connectedAt: Date

    public init(name: String, version: String, connectedAt: Date = Date()) {
        self.name = name
        self.version = version
        self.connectedAt = connectedAt
    }
}

/// Observable state controller for the menu bar app.
/// Provides live connection count, registered tool count, total tool calls,
/// Notion token status, connected client info, and server uptime to the DashboardView popover.
/// All state updates are main-actor-isolated for safe SwiftUI binding.
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

    /// Notion API token status: "connected", "disconnected", or "missing"
    public var notionTokenStatus: String = "missing"

    /// Detail message for Notion token status (e.g., source or error)
    public var notionTokenDetail: String = ""

    /// Full tool list for ToolRegistryView (PKT-350: F2).
    public var toolInfoList: [ToolInfo] = []

    // MARK: - Client Identification (V1-QUALITY-C2)

    /// Connected clients with name, version, and connection time.
    /// Populated from MCP initialize request's clientInfo field.
    public var connectedClients: [ConnectedClient] = []

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
        connectedClients = []
    }

    /// Mark the server as stopped. Resets connections and uptime.
    public func markServerStopped() {
        serverStartTime = nil
        activeConnections = 0
        connectedClients = []
    }

    /// Update the active connection count.
    public func updateConnections(_ count: Int) {
        activeConnections = count
    }

    /// Increment the tool call counter. Called by ServerManager after each dispatch.
    public func incrementToolCalls() {
        totalToolCalls += 1
    }

    /// Update Notion token status.
    public func updateNotionTokenStatus(_ status: String, detail: String = "") {
        notionTokenStatus = status
        notionTokenDetail = detail
    }

    // MARK: - Client Identification (V1-QUALITY-C2)

    /// Add a connected client. Called when MCP initialize request contains clientInfo.
    public func addClient(name: String, version: String) {
        let client = ConnectedClient(name: name, version: version)
        // Replace existing entry with same name (reconnection)
        connectedClients.removeAll { $0.name == name }
        connectedClients.append(client)
        activeConnections = connectedClients.count
        print("[StatusBar] Client connected: \(name) v\(version) (total: \(connectedClients.count))")
    }

    /// Remove a disconnected client by name.
    public func removeClient(name: String) {
        connectedClients.removeAll { $0.name == name }
        activeConnections = connectedClients.count
        print("[StatusBar] Client disconnected: \(name) (remaining: \(connectedClients.count))")
    }

    /// Remove a disconnected client by session ID (best-effort match by index).
    /// Used when we don't have the client name at disconnect time.
    public func removeLastClient() {
        if !connectedClients.isEmpty {
            let removed = connectedClients.removeLast()
            activeConnections = connectedClients.count
            print("[StatusBar] Client disconnected: \(removed.name) (remaining: \(connectedClients.count))")
        }
    }
}
