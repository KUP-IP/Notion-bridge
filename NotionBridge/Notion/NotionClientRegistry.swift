// NotionClientRegistry.swift – V2-NOTION-CORE Multi-Workspace Token Registry
// NotionBridge · Notion
//
// PKT-367: Multi-workspace connection manager.
// Manages N named NotionClient connections with optional workspace selection.
// Handles config.json schema migration: flat "notion_api_token" → "connections" array.
// Zero data loss backward-compat: old flat key preserved as read fallback.
//
// Uses actor isolation for thread-safety (no NSLock needed).

import Foundation

// MARK: - NotionClientRegistry

/// Thread-safe manager for multiple Notion workspace connections.
/// Each connection has its own `NotionClient` instance with independent rate limiting.
public actor NotionClientRegistry {

    /// Shared singleton for app-wide access.
    public static let shared = NotionClientRegistry()

    private var clients: [String: NotionClient] = [:]
    private var connectionConfigs: [NotionConnection] = []
    private var primaryName: String?
    private var initialized = false

    public init() {}

    // MARK: - Client Access

    /// Get a NotionClient for the specified workspace, or the primary connection.
    /// Lazy-initializes connections on first access.
    public func getClient(workspace: String? = nil) throws -> NotionClient {
        if !initialized {
            try loadConnections()
            initialized = true
        }

        if let name = workspace {
            guard let client = clients[name] else {
                throw NotionClientError.connectionNotFound(name)
            }
            return client
        }

        // Return primary connection
        if let primary = primaryName, let client = clients[primary] {
            return client
        }

        // Fallback: try env var / single config token
        if clients.isEmpty {
            let client = try NotionClient()
            clients["default"] = client
            primaryName = "default"
            connectionConfigs.append(NotionConnection(name: "default", token: "", primary: true))
            return client
        }

        throw NotionClientError.missingAPIKey
    }

    // MARK: - Connection Management

    /// List all configured connections with status info.
    public func listConnections() throws -> [NotionConnectionInfo] {
        if !initialized {
            try loadConnections()
            initialized = true
        }

        return connectionConfigs.map { config in
            let masked = config.token.isEmpty
                ? "env/fallback"
                : NotionJSON.maskToken(config.token)
            let status = clients[config.name] != nil ? "connected" : "error"
            return NotionConnectionInfo(
                name: config.name,
                isPrimary: config.primary,
                status: status,
                maskedToken: masked
            )
        }
    }

    /// Add a new named connection. Persists to config.json.
    public func addConnection(name: String, token: String, primary: Bool = false) throws {
        let client = try NotionClient(apiKey: token)
        clients[name] = client
        connectionConfigs.append(NotionConnection(name: name, token: token, primary: primary))
        if primary || primaryName == nil {
            primaryName = name
        }
        try persistConfig()
    }

    /// Remove a named connection. Persists to config.json.
    public func removeConnection(name: String) throws {
        clients.removeValue(forKey: name)
        connectionConfigs.removeAll { $0.name == name }
        if primaryName == name {
            primaryName = connectionConfigs.first?.name
        }
        try persistConfig()
    }

    // MARK: - Config Loading & Migration

    /// Load connections from config.json, handling both old and new formats.
    private func loadConnections() throws {
        let path = NotionTokenResolver.configFilePath

        guard FileManager.default.fileExists(atPath: path),
              let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // No config file — try environment variable fallback
            if let resolved = NotionTokenResolver.resolve() {
                let client = try NotionClient(apiKey: resolved.token)
                clients["default"] = client
                connectionConfigs = [NotionConnection(name: "default", token: resolved.token, primary: true)]
                primaryName = "default"
                print("[NotionClientRegistry] Initialized from token resolver: \(resolved.source)")
                return
            }
            print("[NotionClientRegistry] No config file found — will use env vars on first access")
            return
        }

        // New format: { "connections": [{ "name": "...", "token": "...", "primary": true }] }
        if let connections = json["connections"] as? [[String: Any]] {
            print("[NotionClientRegistry] Loading \(connections.count) connection(s) from new format")
            for conn in connections {
                guard let name = conn["name"] as? String,
                      let token = conn["token"] as? String,
                      !token.isEmpty else { continue }
                let isPrimary = conn["primary"] as? Bool ?? false
                do {
                    let client = try NotionClient(apiKey: token)
                    clients[name] = client
                    connectionConfigs.append(NotionConnection(name: name, token: token, primary: isPrimary))
                    if isPrimary || primaryName == nil {
                        primaryName = name
                    }
                    print("[NotionClientRegistry] Loaded connection '\(name)'\(isPrimary ? " (primary)" : "")")
                } catch {
                    print("[NotionClientRegistry] Failed to create client for '\(name)': \(error)")
                    connectionConfigs.append(NotionConnection(name: name, token: token, primary: isPrimary))
                }
            }
            return
        }

        // Old format: { "notion_api_token": "ntn_..." }
        let oldToken = (json["notion_api_token"] as? String) ?? (json["notion_api_key"] as? String)
        if let token = oldToken, !token.isEmpty {
            print("[NotionClientRegistry] Detected old config format — migrating to connections array")
            do {
                let client = try NotionClient(apiKey: token)
                clients["primary"] = client
                connectionConfigs.append(NotionConnection(name: "primary", token: token, primary: true))
                primaryName = "primary"
                migrateConfig(token: token, path: path, existingJSON: json)
            } catch {
                print("[NotionClientRegistry] Failed to create client from legacy token: \(error)")
            }
        }
    }

    /// Migrate old flat config to new connections array format.
    /// Preserves the old key for backward compatibility.
    private func migrateConfig(token: String, path: String, existingJSON: [String: Any]) {
        var config = existingJSON
        config["connections"] = [
            ["name": "primary", "token": token, "primary": true] as [String: Any]
        ]
        if let jsonData = try? JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? jsonData.write(to: URL(fileURLWithPath: path))
            print("[NotionClientRegistry] Config migrated — connections array added, old key preserved")
        }
    }

    /// Persist current connections to config.json.
    private func persistConfig() throws {
        let path = NotionTokenResolver.configFilePath
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)

        var config: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: path),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            config = existing
        }

        config["connections"] = connectionConfigs.map { conn -> [String: Any] in
            ["name": conn.name, "token": conn.token, "primary": conn.primary]
        }

        if let primaryToken = connectionConfigs.first(where: { $0.primary })?.token {
            config["notion_api_token"] = primaryToken
        }

        let jsonData = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try jsonData.write(to: URL(fileURLWithPath: path))
        print("[NotionClientRegistry] Config persisted — \(connectionConfigs.count) connection(s)")
    }

    /// Number of configured connections.
    public var connectionCount: Int {
        return clients.count
    }
}
