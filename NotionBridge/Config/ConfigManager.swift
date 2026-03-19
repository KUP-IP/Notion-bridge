// ConfigManager.swift — Centralized config read/write
// NotionBridge · Configuration
// PKT-363 D1: Manages ~/.config/notion-bridge/config.json
// Thread-safe via concurrent DispatchQueue with barrier writes.
// Atomic file writes via Data.write(options: .atomic).

import Foundation

/// Centralized configuration manager for ~/.config/notion-bridge/config.json.
/// Shared by SecurityGate (runtime path reads) and SettingsWindow (UI edits).
public final class ConfigManager: @unchecked Sendable {

    public static let shared = ConfigManager()

    /// The 5 original sensitive paths shipped as defaults.
    public static let defaultSensitivePaths: [String] = [
        "~/.ssh",
        "~/.aws",
        "~/.gnupg",
        "~/.config",
        "~/Library/Keychains"
    ]

    private let configURL: URL
    private let queue = DispatchQueue(label: "com.notionbridge.config", attributes: .concurrent)

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        configURL = home.appendingPathComponent(".config/notion-bridge/config.json")
    }

    // MARK: - Raw Config I/O

    private func readConfig() -> [String: Any] {
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[ConfigManager] ⚠️ Failed to read config.json — returning empty config")
            return [:]
        }
        return json
    }

    /// Atomic write via Data.write(options: .atomic) — writes to temp file, then renames.
    private func writeConfig(_ config: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: configURL, options: .atomic)
    }

    // MARK: - Sensitive Paths (PKT-363 D1 + D2)

    /// Read sensitive paths from config.
    /// Falls back to hardcoded defaults if key is missing, wrong type, or JSON is malformed.
    /// Logs a warning on fallback.
    public var sensitivePaths: [String] {
        get {
            queue.sync {
                let config = readConfig()
                guard let paths = config["sensitivePaths"] as? [String] else {
                    print("[ConfigManager] ⚠️ sensitivePaths missing or malformed — falling back to defaults")
                    return Self.defaultSensitivePaths
                }
                return paths
            }
        }
        set {
            queue.sync(flags: .barrier) {
                var config = readConfig()
                config["sensitivePaths"] = newValue
                do {
                    try writeConfig(config)
                } catch {
                    print("[ConfigManager] ⚠️ Failed to write sensitivePaths: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Seed sensitivePaths into config if key is absent.
    /// Called on first launch with new schema to populate defaults.
    public func seedDefaultsIfNeeded() {
        queue.sync(flags: .barrier) {
            let config = readConfig()
            if config["sensitivePaths"] == nil {
                var updated = config
                updated["sensitivePaths"] = Self.defaultSensitivePaths
                do {
                    try writeConfig(updated)
                    print("[ConfigManager] Seeded sensitivePaths with \(Self.defaultSensitivePaths.count) defaults")
                } catch {
                    print("[ConfigManager] ⚠️ Failed to seed defaults: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Merge default paths back into the current list without removing custom paths.
    /// PKT-363 D4: "Restore Defaults" merges originals back without wiping additions.
    /// Returns the merged list.
    @discardableResult
    public func restoreDefaults() -> [String] {
        var current = sensitivePaths
        for defaultPath in Self.defaultSensitivePaths {
            if !current.contains(defaultPath) {
                current.append(defaultPath)
            }
        }
        sensitivePaths = current
        return current
    }
}
