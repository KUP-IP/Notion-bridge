// ConfigPathMigration.swift — non-destructive XDG config-home migration.
//
// PKT-1121: ~/.config/notion-bridge/ → ~/.config/the-bridge/
//
// The source directory is renamed atomically to a timestamped `.legacy-*`
// archive before any canonical writes. Every source byte remains in that
// archive. Entries are then copied into the canonical directory; collisions
// are retained as `.pre-migrate-*` siblings and never overwrite canonical
// data. A small journal makes an interrupted pass resumable.

import Foundation

public enum ConfigPathMigration {
    public struct Report: Equatable, Sendable {
        public let itemsCopied: Int
        public let collisionsPreserved: Int
        public let alreadyComplete: Bool
        public let skippedForOverride: Bool
        public let legacyArchive: URL?

        public static let noop = Report(
            itemsCopied: 0,
            collisionsPreserved: 0,
            alreadyComplete: true,
            skippedForOverride: false,
            legacyArchive: nil
        )
    }

    private struct Journal: Codable {
        var archivePath: String
        var completedEntries: [String: String]
    }

    public static let sentinelName = ".the-bridge-config-migration-v4-complete"
    public static let journalName = ".the-bridge-config-migration-v4-in-progress.json"

    public static var canonicalDirectory: URL {
        BridgePaths.homeRoot.appendingPathComponent(".config/the-bridge", isDirectory: true)
    }

    public static var legacyDirectory: URL {
        BridgePaths.homeRoot.appendingPathComponent(".config/notion-bridge", isDirectory: true)
    }

    private static var configRoot: URL {
        BridgePaths.homeRoot.appendingPathComponent(".config", isDirectory: true)
    }

    private static var sentinelURL: URL { configRoot.appendingPathComponent(sentinelName) }
    private static var journalURL: URL { configRoot.appendingPathComponent(journalName) }

    /// Run before ConfigManager or MemoryStore is initialized. An explicit
    /// BRIDGE_CONFIG_PATH is a separate operator-selected home and suppresses
    /// the default-path migration without recording the migration complete.
    @discardableResult
    public static func runOnce(
        fileManager fm: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        log: (String) -> Void = { print("[ConfigPathMigration] \($0)") }
    ) throws -> Report {
        if let override = environment["BRIDGE_CONFIG_PATH"], !override.isEmpty {
            log("BRIDGE_CONFIG_PATH is set — default-path migration skipped")
            return Report(
                itemsCopied: 0,
                collisionsPreserved: 0,
                alreadyComplete: false,
                skippedForOverride: true,
                legacyArchive: nil
            )
        }

        if fm.fileExists(atPath: sentinelURL.path) {
            return .noop
        }

        try fm.createDirectory(at: configRoot, withIntermediateDirectories: true)

        var journal: Journal
        let archive: URL
        if fm.fileExists(atPath: journalURL.path) {
            journal = try readJournal(from: journalURL)
            archive = URL(fileURLWithPath: journal.archivePath, isDirectory: true)
            if !fm.fileExists(atPath: archive.path) {
                guard fm.fileExists(atPath: legacyDirectory.path) else {
                    throw CocoaError(.fileNoSuchFile, userInfo: [
                        NSFilePathErrorKey: archive.path,
                        NSLocalizedDescriptionKey: "Config migration journal exists but neither its retained archive nor legacy source is present"
                    ])
                }
                try fm.moveItem(at: legacyDirectory, to: archive)
                log("resumed pending legacy snapshot at \(archive.lastPathComponent)")
            } else {
                log("resuming from retained archive \(archive.lastPathComponent)")
            }
        } else if fm.fileExists(atPath: legacyDirectory.path) {
            archive = uniqueSibling(
                parent: configRoot,
                baseName: "notion-bridge.legacy-\(Int(Date().timeIntervalSince1970))",
                fileManager: fm
            )
            journal = Journal(archivePath: archive.path, completedEntries: [:])
            try writeJournal(journal, to: journalURL)
            try fm.moveItem(at: legacyDirectory, to: archive)
            log("retained complete legacy snapshot at \(archive.lastPathComponent)")
        } else {
            try writeSentinel(archive: nil, copied: 0, collisions: 0, to: sentinelURL)
            return Report(
                itemsCopied: 0,
                collisionsPreserved: 0,
                alreadyComplete: false,
                skippedForOverride: false,
                legacyArchive: nil
            )
        }

        try fm.createDirectory(at: canonicalDirectory, withIntermediateDirectories: true)
        let entries = try fm.contentsOfDirectory(
            at: archive,
            includingPropertiesForKeys: nil,
            options: []
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        var copied = journal.completedEntries.count
        var collisions = journal.completedEntries.values.filter { $0.contains(".pre-migrate-") }.count

        for source in entries {
            let name = source.lastPathComponent
            if journal.completedEntries[name] != nil { continue }

            let preferred = canonicalDirectory.appendingPathComponent(name)
            let destination: URL
            if fm.fileExists(atPath: preferred.path) {
                destination = uniqueSibling(
                    parent: canonicalDirectory,
                    baseName: "\(name).pre-migrate-\(Int(Date().timeIntervalSince1970))",
                    fileManager: fm
                )
                collisions += 1
                log("canonical collision at \(name) — preserved legacy copy as \(destination.lastPathComponent)")
            } else {
                destination = preferred
            }

            try fm.copyItem(at: source, to: destination)
            if destination == canonicalDirectory.appendingPathComponent("config.json") {
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            }
            journal.completedEntries[name] = destination.lastPathComponent
            try writeJournal(journal, to: journalURL)
            copied += 1
        }

        try writeSentinel(archive: archive, copied: copied, collisions: collisions, to: sentinelURL)
        try fm.removeItem(at: journalURL)
        log("migration complete — copied:\(copied) collisions:\(collisions) archive:\(archive.lastPathComponent)")

        return Report(
            itemsCopied: copied,
            collisionsPreserved: collisions,
            alreadyComplete: false,
            skippedForOverride: false,
            legacyArchive: archive
        )
    }

    /// Test/maintenance hook. It removes only the generated completion marker;
    /// retained legacy archives are never removed by this type.
    public static func resetSentinel(fileManager fm: FileManager = .default) throws {
        if fm.fileExists(atPath: sentinelURL.path) {
            try fm.removeItem(at: sentinelURL)
        }
    }

    private static func uniqueSibling(parent: URL, baseName: String, fileManager fm: FileManager) -> URL {
        var candidate = parent.appendingPathComponent(baseName)
        var suffix = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(baseName)-\(suffix)")
            suffix += 1
        }
        return candidate
    }

    private static func readJournal(from url: URL) throws -> Journal {
        try JSONDecoder().decode(Journal.self, from: Data(contentsOf: url))
    }

    private static func writeJournal(_ journal: Journal, to url: URL) throws {
        let data = try JSONEncoder().encode(journal)
        try data.write(to: url, options: .atomic)
    }

    private static func writeSentinel(
        archive: URL?,
        copied: Int,
        collisions: Int,
        to url: URL
    ) throws {
        var payload: [String: Any] = [
            "completedAt": ISO8601DateFormatter().string(from: Date()),
            "itemsCopied": copied,
            "collisionsPreserved": collisions,
        ]
        if let archive {
            payload["legacyArchive"] = archive.path
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
