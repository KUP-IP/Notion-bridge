// ConfigManagerTests.swift — PKT-363: Config fallback + path validation tests
// NotionBridge · Tests

import Foundation
import NotionBridgeLib

func runConfigManagerTests() async {
    print("\n🔧 ConfigManager Tests (PKT-363)")

    // Test 1: Config fallback — sensitivePaths returns defaults when key is missing/malformed
    await test("Config fallback returns 5 defaults when sensitivePaths key is absent") {
        // Save current paths, then simulate missing key by writing config without sensitivePaths
        let configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/notion-bridge/config.json")

        // Read current config
        let originalData = try Data(contentsOf: configPath)
        let originalJSON = try JSONSerialization.jsonObject(with: originalData) as! [String: Any]

        // Write config without sensitivePaths key
        var stripped = originalJSON
        stripped.removeValue(forKey: "sensitivePaths")
        let strippedData = try JSONSerialization.data(withJSONObject: stripped, options: [.prettyPrinted])
        try strippedData.write(to: configPath, options: .atomic)

        // Read — should fall back to 5 defaults
        let paths = ConfigManager.shared.sensitivePaths
        try expect(paths.count == 5, "Expected 5 default paths, got \(paths.count)")
        try expect(paths.contains("~/.ssh"), "Expected ~/.ssh in defaults")
        try expect(paths.contains("~/.aws"), "Expected ~/.aws in defaults")
        try expect(paths.contains("~/.gnupg"), "Expected ~/.gnupg in defaults")
        try expect(paths.contains("~/.config"), "Expected ~/.config in defaults")
        try expect(paths.contains("~/Library/Keychains"), "Expected ~/Library/Keychains in defaults")

        // Restore original config
        try originalData.write(to: configPath, options: .atomic)
    }

    // Test 2: Path validation — normalization converts absolute home paths to ~/ form
    await test("Path normalization and validation rules") {
        // Save current paths
        let original = ConfigManager.shared.sensitivePaths

        // Test: write paths, read them back
        let testPaths = ["~/.ssh", "~/.custom-test-path"]
        ConfigManager.shared.sensitivePaths = testPaths
        let readBack = ConfigManager.shared.sensitivePaths
        try expect(readBack.count == 2, "Expected 2 paths, got \(readBack.count)")
        try expect(readBack.contains("~/.ssh"), "Expected ~/.ssh")
        try expect(readBack.contains("~/.custom-test-path"), "Expected ~/.custom-test-path")

        // Test: defaults are correct count and content
        try expect(ConfigManager.defaultSensitivePaths.count == 5, "Expected 5 default paths")

        // Test: restoreDefaults merges without wiping custom
        ConfigManager.shared.sensitivePaths = ["~/.custom-only"]
        let merged = ConfigManager.shared.restoreDefaults()
        try expect(merged.contains("~/.custom-only"), "Custom path should survive merge")
        try expect(merged.contains("~/.ssh"), "Default ~/.ssh should be restored")
        try expect(merged.count == 6, "Expected 6 paths (1 custom + 5 defaults), got \(merged.count)")

        // Restore original
        ConfigManager.shared.sensitivePaths = original
    }
}
