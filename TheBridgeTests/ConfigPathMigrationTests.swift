// ConfigPathMigrationTests.swift — PKT-1121 XDG config-home migration.
// Every case uses BridgePaths.overrideHomeForTesting; no operator config path
// is read, enumerated, moved, or written.

import Foundation
import TheBridgeLib

func runConfigPathMigrationTests() async {
    print("\n[ConfigPathMigration]")

    await test("ConfigManager default resolves to ~/.config/the-bridge/config.json") {
        try await withTempConfigHome { home in
            let url = ConfigManager.resolveConfigFileURL(environment: [:], homeRoot: home)
            try expect(url == home.appendingPathComponent(".config/the-bridge/config.json"))
        }
    }

    await test("BRIDGE_CONFIG_PATH remains the highest-precedence config location") {
        try await withTempConfigHome { home in
            let custom = home.appendingPathComponent("custom/operator.json")
            let url = ConfigManager.resolveConfigFileURL(
                environment: ["BRIDGE_CONFIG_PATH": custom.path],
                homeRoot: home
            )
            try expect(url == custom)
        }
    }

    await test("fresh install records completion without creating canonical config directory") {
        try await withTempConfigHome { home in
            let report = try ConfigPathMigration.runOnce(environment: [:], log: { _ in })
            try expect(!report.alreadyComplete)
            try expect(report.itemsCopied == 0)
            let canonical = home.appendingPathComponent(".config/the-bridge")
            try expect(!FileManager.default.fileExists(atPath: canonical.path),
                       "canonical directory must remain lazy on a fresh install")
            let configRoot = home.appendingPathComponent(".config")
            let names = try FileManager.default.contentsOfDirectory(atPath: configRoot.path)
            try expect(!names.contains(where: { $0.contains(".legacy-") }))
        }
    }

    await test("legacy config, memory DB, WAL, SHM, and hidden files migrate with a full retained archive") {
        try await withTempConfigHome { home in
            let fm = FileManager.default
            let legacy = home.appendingPathComponent(".config/notion-bridge", isDirectory: true)
            try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
            let configBytes = Data(#"{"notion_api_token":"ntn_test_token_value_12345"}"#.utf8)
            try configBytes.write(to: legacy.appendingPathComponent("config.json"))
            try Data("db".utf8).write(to: legacy.appendingPathComponent("memory.sqlite"))
            try Data("wal".utf8).write(to: legacy.appendingPathComponent("memory.sqlite-wal"))
            try Data("shm".utf8).write(to: legacy.appendingPathComponent("memory.sqlite-shm"))
            try Data("hidden".utf8).write(to: legacy.appendingPathComponent(".operator-state"))

            let report = try ConfigPathMigration.runOnce(environment: [:], log: { _ in })
            let canonical = home.appendingPathComponent(".config/the-bridge", isDirectory: true)
            try expect(report.itemsCopied == 5, "expected all five entries, got \(report.itemsCopied)")
            try expect(!fm.fileExists(atPath: legacy.path))
            guard let archive = report.legacyArchive else {
                throw TestError.assertion("migration did not report its retained archive")
            }
            for name in ["config.json", "memory.sqlite", "memory.sqlite-wal", "memory.sqlite-shm", ".operator-state"] {
                let original = try Data(contentsOf: archive.appendingPathComponent(name))
                let migrated = try Data(contentsOf: canonical.appendingPathComponent(name))
                try expect(original == migrated, "byte mismatch for \(name)")
            }
            let attrs = try fm.attributesOfItem(atPath: canonical.appendingPathComponent("config.json").path)
            let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
            try expect(mode & 0o777 == 0o600, "migrated config mode must be 0600")
        }
    }

    await test("migrated MemoryStore retains recallable rows") {
        try await withTempConfigHome { home in
            let fm = FileManager.default
            let legacy = home.appendingPathComponent(".config/notion-bridge", isDirectory: true)
            try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
            let oldURL = legacy.appendingPathComponent("memory.sqlite")
            let oldStore = MemoryStore(path: oldURL, embedder: StubMemoryEmbedder())
            _ = try await oldStore.remember(
                text: "PKT 1121 migration retains this durable row",
                scope: "project",
                entity: "PKT-1121",
                source: "migration-test"
            )
            await oldStore.close()

            _ = try ConfigPathMigration.runOnce(environment: [:], log: { _ in })
            let newURL = home.appendingPathComponent(".config/the-bridge/memory.sqlite")
            let newStore = MemoryStore(path: newURL, embedder: StubMemoryEmbedder())
            let recalled = try await newStore.recall(
                query: "migration retains durable row",
                scope: "project",
                entity: "PKT-1121",
                limit: 5
            )
            await newStore.close()
            try expect(recalled.contains(where: { $0.text == "PKT 1121 migration retains this durable row" }),
                       "migrated memory row was not recallable")
        }
    }

    await test("second successful migration is a byte-identical no-op") {
        try await withTempConfigHome { home in
            let fm = FileManager.default
            let legacy = home.appendingPathComponent(".config/notion-bridge", isDirectory: true)
            try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
            try Data("stable".utf8).write(to: legacy.appendingPathComponent("config.json"))
            _ = try ConfigPathMigration.runOnce(environment: [:], log: { _ in })
            let before = try configTreeSnapshot(home)
            let second = try ConfigPathMigration.runOnce(environment: [:], log: { _ in })
            let after = try configTreeSnapshot(home)
            try expect(second.alreadyComplete)
            try expect(before == after, "second launch changed the migrated filesystem")
        }
    }

    await test("canonical collisions never overwrite and retain both recovery copies") {
        try await withTempConfigHome { home in
            let fm = FileManager.default
            let canonical = home.appendingPathComponent(".config/the-bridge", isDirectory: true)
            let legacy = home.appendingPathComponent(".config/notion-bridge", isDirectory: true)
            try fm.createDirectory(at: canonical, withIntermediateDirectories: true)
            try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
            try Data("canonical".utf8).write(to: canonical.appendingPathComponent("config.json"))
            try Data("legacy".utf8).write(to: legacy.appendingPathComponent("config.json"))

            let report = try ConfigPathMigration.runOnce(environment: [:], log: { _ in })
            try expect(report.collisionsPreserved == 1)
            try expect(try Data(contentsOf: canonical.appendingPathComponent("config.json")) == Data("canonical".utf8))
            let names = try fm.contentsOfDirectory(atPath: canonical.path)
            guard let collision = names.first(where: { $0.hasPrefix("config.json.pre-migrate-") }) else {
                throw TestError.assertion("missing pre-migrate collision copy: \(names)")
            }
            try expect(try Data(contentsOf: canonical.appendingPathComponent(collision)) == Data("legacy".utf8))
            guard let archive = report.legacyArchive else { throw TestError.assertion("missing archive") }
            try expect(try Data(contentsOf: archive.appendingPathComponent("config.json")) == Data("legacy".utf8))
        }
    }

    await test("BRIDGE_CONFIG_PATH skips default migration without consuming it") {
        try await withTempConfigHome { home in
            let fm = FileManager.default
            let legacy = home.appendingPathComponent(".config/notion-bridge", isDirectory: true)
            try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
            try Data("legacy".utf8).write(to: legacy.appendingPathComponent("config.json"))
            let custom = home.appendingPathComponent("custom/config.json")

            let skipped = try ConfigPathMigration.runOnce(
                environment: ["BRIDGE_CONFIG_PATH": custom.path],
                log: { _ in }
            )
            try expect(skipped.skippedForOverride)
            try expect(fm.fileExists(atPath: legacy.path), "override must leave default legacy home untouched")
            try expect(!fm.fileExists(atPath: home.appendingPathComponent(".config/the-bridge").path))

            let later = try ConfigPathMigration.runOnce(environment: [:], log: { _ in })
            try expect(later.itemsCopied == 1, "skip must not consume the future migration")
        }
    }

    await test("interrupted journal resumes from its retained archive") {
        try await withTempConfigHome { home in
            let fm = FileManager.default
            let root = home.appendingPathComponent(".config", isDirectory: true)
            let archive = root.appendingPathComponent("notion-bridge.legacy-100", isDirectory: true)
            try fm.createDirectory(at: archive, withIntermediateDirectories: true)
            try Data("resume".utf8).write(to: archive.appendingPathComponent("config.json"))
            let journal: [String: Any] = ["archivePath": archive.path, "completedEntries": [String: String]()]
            let data = try JSONSerialization.data(withJSONObject: journal, options: [.sortedKeys])
            try data.write(to: root.appendingPathComponent(ConfigPathMigration.journalName), options: .atomic)

            let report = try ConfigPathMigration.runOnce(environment: [:], log: { _ in })
            try expect(report.itemsCopied == 1)
            try expect(try Data(contentsOf: home.appendingPathComponent(".config/the-bridge/config.json")) == Data("resume".utf8))
            try expect(!fm.fileExists(atPath: root.appendingPathComponent(ConfigPathMigration.journalName).path))
            try expect(fm.fileExists(atPath: archive.path), "resume must retain the full archive")
        }
    }

    await test("interrupted journal before legacy rename resumes without data loss") {
        try await withTempConfigHome { home in
            let fm = FileManager.default
            let root = home.appendingPathComponent(".config", isDirectory: true)
            let legacy = root.appendingPathComponent("notion-bridge", isDirectory: true)
            let archive = root.appendingPathComponent("notion-bridge.legacy-101", isDirectory: true)
            try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
            try Data("pre-rename".utf8).write(to: legacy.appendingPathComponent("config.json"))
            let journal: [String: Any] = ["archivePath": archive.path, "completedEntries": [String: String]()]
            let data = try JSONSerialization.data(withJSONObject: journal, options: [.sortedKeys])
            try data.write(to: root.appendingPathComponent(ConfigPathMigration.journalName), options: .atomic)

            let report = try ConfigPathMigration.runOnce(environment: [:], log: { _ in })
            try expect(report.itemsCopied == 1)
            try expect(!fm.fileExists(atPath: legacy.path), "legacy source should complete its pending atomic rename")
            try expect(fm.fileExists(atPath: archive.path), "full retained archive must be created")
            let canonical = home.appendingPathComponent(".config/the-bridge/config.json")
            try expect(try Data(contentsOf: canonical) == Data("pre-rename".utf8))
            try expect(try Data(contentsOf: archive.appendingPathComponent("config.json")) == Data("pre-rename".utf8))
        }
    }
}

private func withTempConfigHome(_ body: (URL) async throws -> Void) async throws {
    let fm = FileManager.default
    let home = fm.temporaryDirectory
        .appendingPathComponent("ConfigPathMigration-test-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: home, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(home)
    defer {
        BridgePaths.overrideHomeForTesting(nil)
        try? fm.removeItem(at: home)
    }
    try await body(home)
}

private func configTreeSnapshot(_ home: URL) throws -> [String: Data] {
    let root = home.appendingPathComponent(".config", isDirectory: true)
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
        return [:]
    }
    var result: [String: Data] = [:]
    for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        let relative = String(url.path.dropFirst(root.path.count + 1))
        result[relative] = values.isDirectory == true ? Data("<dir>".utf8) : try Data(contentsOf: url)
    }
    return result
}
