// CommandCustodyBackend.swift
//
// Immutable, layered local custody for CommandStore.
//
// Product defaults remain repository/application-owned. Operator state is
// revisioned beneath Application Support/The Bridge/commands/custody:
//
//   state.json                         atomic active-revision pointer
//   revisions/revision-<uuid>/
//     layers.json                       overrides, custom metadata, tombstones,
//                                       favorite command IDs, and optional
//                                       adopted-base descriptors (A1; decodeIfPresent)
//     telemetry/usage.json             non-body activity data
//     bodies/<immutable-command-id>.md command-body payloads only
//     adopted-bases/<immutable-id>.md  last-adopted product body (A1; optional)
//     manifest.json                     SHA-256 for every payload file
//   live-telemetry/usage.json          ordinary activity overlay only
//
// The old commands/index.json plus <slug>.md files remain untouched after a
// successful migration. They are the rollback source until an operator decides
// otherwise; no normal application path deletes or rewrites them.

import CryptoKit
import Foundation

final class CommandCustodyBackend: @unchecked Sendable {
    private static let schemaVersion = 2
    private static let revisionPrefix = "revision-"
    private static let layersFile = "layers.json"
    private static let revisionTelemetryFile = "telemetry/usage.json"
    private static let manifestFile = "manifest.json"
    private static let adoptedBasesDirectory = "adopted-bases"

    private let storageRoot: URL?
    private let productDefaultsOverride: [CommandStore.ProductDefault]?
    private let lock = NSLock()
    private var faultPoint: CommandStore.TestFaultPoint?

    init(
        storageRoot: URL?,
        productDefaults: [CommandStore.ProductDefault]?
    ) {
        self.storageRoot = storageRoot
        self.productDefaultsOverride = productDefaults
    }

    private var root: URL {
        storageRoot ?? BridgePaths.applicationSupport(.commands)
    }

    private var custodyRoot: URL {
        root.appendingPathComponent("custody", isDirectory: true)
    }

    private var stateURL: URL {
        custodyRoot.appendingPathComponent("state.json", isDirectory: false)
    }

    private var revisionsRoot: URL {
        custodyRoot.appendingPathComponent("revisions", isDirectory: true)
    }

    private var liveTelemetryURL: URL {
        custodyRoot
            .appendingPathComponent("live-telemetry", isDirectory: true)
            .appendingPathComponent("usage.json", isDirectory: false)
    }

    private var legacyIndexURL: URL {
        root.appendingPathComponent("index.json", isDirectory: false)
    }

    private func legacyBodyURL(_ slug: String) -> URL {
        root.appendingPathComponent("\(slug).md", isDirectory: false)
    }

    private var productDefaults: [CommandStore.ProductDefault] {
        productDefaultsOverride ?? CommandStore.defaultProductCatalog
    }

    // MARK: - Public bridge used by CommandStore

    func resetForTesting() throws {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
    }

    func seedIfEmpty() throws {
        lock.lock()
        defer { lock.unlock() }
        // Seeding is an app-startup convenience, not an authorization to
        // convert an existing operator store. A legacy index is already an
        // initialized palette and must stay readable until a command-state
        // mutation explicitly enters the migration boundary.
        if try activeSnapshotLocked(repairing: false) != nil { return }
        if legacyExistsLocked() {
            return
        }

        var snapshot = Snapshot.empty
        snapshot.productDefaultsActive = true
        for item in productDefaults {
            if let slot = item.initialKeySlot {
                snapshot.favorites[slot] = item.id
            }
        }
        try publishLocked(snapshot)
    }

    func list() throws -> [CommandStore.Command] {
        lock.lock()
        defer { lock.unlock() }
        guard let snapshot = try readableSnapshotLocked() else { return [] }
        return effectiveCommands(snapshot)
    }

    func get(slug: String) throws -> CommandStore.Command? {
        lock.lock()
        defer { lock.unlock() }
        guard let snapshot = try readableSnapshotLocked() else { return nil }
        return effectiveCommands(snapshot).first { $0.slug == slug }
    }

    func create(
        name: String,
        icon: CommandStore.Icon,
        color: CommandStore.NotionColor?,
        body: String,
        keySlot: Int?
    ) throws -> CommandStore.Command {
        lock.lock()
        defer { lock.unlock() }

        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CommandStore.StoreError.invalidName(name) }
        let slug = CommandStore.slugify(trimmed)
        guard !slug.isEmpty else { throw CommandStore.StoreError.invalidName(name) }

        var snapshot = try mutableSnapshotLocked()
        guard !effectiveCommands(snapshot).contains(where: { $0.slug == slug }) else {
            throw CommandStore.StoreError.slugTaken(slug)
        }
        if let keySlot { try assertSlot(keySlot) }

        let id = "bridge.command.custom.\(UUID().uuidString.lowercased())"
        snapshot.customCommands[id] = StoredCommand(
            id: id,
            slug: slug,
            name: trimmed,
            icon: icon,
            color: color,
            body: body
        )
        assignFavorite(commandID: id, slot: keySlot, snapshot: &snapshot)
        try publishLocked(snapshot)
        return try commandByID(id, in: snapshot)
    }

    func update(_ command: CommandStore.Command) throws -> CommandStore.Command {
        lock.lock()
        defer { lock.unlock() }

        var snapshot = try mutableSnapshotLocked()
        guard let existing = effectiveCommands(snapshot).first(where: { $0.slug == command.slug }) else {
            throw CommandStore.StoreError.slugNotFound(command.slug)
        }
        if let slot = command.keySlot { try assertSlot(slot) }

        let id = existing.id
        let updated = StoredCommand(
            id: id,
            slug: existing.slug,
            name: command.name,
            icon: command.icon,
            color: command.color,
            body: command.body
        )

        if let defaultCommand = productDefaults.first(where: { $0.id == id }) {
            if isEquivalent(updated, to: defaultCommand) {
                snapshot.localOverrides.removeValue(forKey: id)
                snapshot.adoptedBases.removeValue(forKey: id)
            } else {
                if snapshot.localOverrides[id] == nil {
                    snapshot.adoptedBases[id] = AdoptedBase(defaultCommand)
                }
                snapshot.localOverrides[id] = updated
            }
        } else {
            snapshot.customCommands[id] = updated
        }

        if command.lastUsedAt != existing.lastUsedAt {
            if let lastUsedAt = command.lastUsedAt {
                snapshot.usage[id] = lastUsedAt
            } else {
                snapshot.usage.removeValue(forKey: id)
            }
        }
        assignFavorite(commandID: id, slot: command.keySlot, snapshot: &snapshot)
        try publishLocked(snapshot)
        return try commandByID(id, in: snapshot)
    }

    func delete(slug: String) throws {
        lock.lock()
        defer { lock.unlock() }

        var snapshot = try mutableSnapshotLocked()
        guard let existing = effectiveCommands(snapshot).first(where: { $0.slug == slug }) else {
            throw CommandStore.StoreError.slugNotFound(slug)
        }
        let id = existing.id
        snapshot.favorites = snapshot.favorites.filter { $0.value != id }
        snapshot.usage.removeValue(forKey: id)

        if productDefaults.contains(where: { $0.id == id }) {
            snapshot.localOverrides.removeValue(forKey: id)
            snapshot.adoptedBases.removeValue(forKey: id)
            snapshot.tombstones.insert(id)
        } else {
            snapshot.customCommands.removeValue(forKey: id)
        }
        try publishLocked(snapshot)
    }

    func setKeySlot(slug: String, slot: Int?) throws {
        lock.lock()
        defer { lock.unlock() }

        if let slot { try assertSlot(slot) }
        var snapshot = try mutableSnapshotLocked()
        guard let existing = effectiveCommands(snapshot).first(where: { $0.slug == slug }) else {
            throw CommandStore.StoreError.slugNotFound(slug)
        }
        assignFavorite(commandID: existing.id, slot: slot, snapshot: &snapshot)
        try publishLocked(snapshot)
    }

    func recordUse(slug: String, at date: Date) throws {
        lock.lock()
        defer { lock.unlock() }

        guard var snapshot = try readableSnapshotLocked(),
              let existing = effectiveCommands(snapshot).first(where: { $0.slug == slug })
        else {
            throw CommandStore.StoreError.slugNotFound(slug)
        }
        snapshot.usage[existing.id] = date
        // This is deliberately not a revision write. Ordinary telemetry cannot
        // rewrite command bodies, metadata, tombstones, or favorite layout.
        try writeLiveTelemetryLocked(snapshot.usage)
    }

    // MARK: - Product-default reconciliation (A1)

    func reconciliations() throws -> [CommandStore.CommandReconciliation] {
        lock.lock()
        defer { lock.unlock() }
        guard let snapshot = try readableSnapshotLocked() else { return [] }
        return productDefaults.compactMap { makeReconciliationLocked(incoming: $0, snapshot: snapshot) }
    }

    func reconciliation(slug: String) throws -> CommandStore.CommandReconciliation? {
        lock.lock()
        defer { lock.unlock() }
        guard let incoming = productDefaults.first(where: { $0.slug == slug }) else { return nil }
        guard let snapshot = try readableSnapshotLocked() else {
            return makeReconciliationLocked(incoming: incoming, snapshot: .empty)
        }
        return makeReconciliationLocked(incoming: incoming, snapshot: snapshot)
    }

    func applyReconciliation(
        slug: String,
        action: CommandStore.ReconciliationAction
    ) throws -> CommandStore.CommandReconciliation {
        lock.lock()
        defer { lock.unlock() }

        guard let incoming = productDefaults.first(where: { $0.slug == slug }) else {
            throw CommandStore.StoreError.reconciliationNotApplicable(slug)
        }
        var snapshot = try mutableSnapshotLocked()
        guard snapshot.productDefaultsActive, !snapshot.tombstones.contains(incoming.id) else {
            throw CommandStore.StoreError.reconciliationNotApplicable(slug)
        }

        switch action {
        case .restoreBase:
            guard let adopted = snapshot.adoptedBases[incoming.id] else {
                throw CommandStore.StoreError.adoptedBaseMissing(slug)
            }
            let restored = StoredCommand(adopted, id: incoming.id, slug: incoming.slug)
            if isEquivalent(restored, to: incoming) {
                snapshot.localOverrides.removeValue(forKey: incoming.id)
                snapshot.adoptedBases.removeValue(forKey: incoming.id)
            } else {
                snapshot.localOverrides[incoming.id] = restored
            }

        case .adoptIncoming:
            snapshot.localOverrides.removeValue(forKey: incoming.id)
            snapshot.adoptedBases.removeValue(forKey: incoming.id)

        case .copySelectedChange(let source, let field):
            let sourceDefault: CommandStore.ProductDefault
            switch source {
            case .base:
                guard let adopted = snapshot.adoptedBases[incoming.id] else {
                    throw CommandStore.StoreError.adoptedBaseMissing(slug)
                }
                sourceDefault = adopted.asProductDefault(
                    id: incoming.id,
                    slug: incoming.slug,
                    initialKeySlot: incoming.initialKeySlot
                )
            case .incoming:
                sourceDefault = incoming
            }

            var local = snapshot.localOverrides[incoming.id] ?? StoredCommand(incoming)
            if snapshot.localOverrides[incoming.id] == nil {
                snapshot.adoptedBases[incoming.id] = AdoptedBase(incoming)
            }
            switch field {
            case .name: local.name = sourceDefault.name
            case .icon: local.icon = sourceDefault.icon
            case .color: local.color = sourceDefault.color
            case .body: local.body = sourceDefault.body
            }
            if isEquivalent(local, to: incoming) {
                snapshot.localOverrides.removeValue(forKey: incoming.id)
                snapshot.adoptedBases.removeValue(forKey: incoming.id)
            } else {
                snapshot.localOverrides[incoming.id] = local
            }
        }

        try publishLocked(snapshot)
        guard let result = makeReconciliationLocked(incoming: incoming, snapshot: snapshot) else {
            throw CommandStore.StoreError.reconciliationNotApplicable(slug)
        }
        return result
    }

    func executionGate(slug: String) throws -> CommandStore.ExecutionGate {
        lock.lock()
        defer { lock.unlock() }
        guard let incoming = productDefaults.first(where: { $0.slug == slug }) else {
            return .open
        }
        guard let snapshot = try readableSnapshotLocked() else { return .open }
        return makeReconciliationLocked(incoming: incoming, snapshot: snapshot)?.executionGate ?? .open
    }

    // MARK: - Test seams

    func installLegacyFixtureForTesting(_ commands: [CommandStore.Command]) throws {
        lock.lock()
        defer { lock.unlock() }

        guard !FileManager.default.fileExists(atPath: stateURL.path) else {
            throw CommandStore.StoreError.legacyIdentityAmbiguous(
                "cannot install a legacy fixture after custody activation"
            )
        }
        try ensureDirectory(root)
        var index: [LegacyIndexEntry] = []
        for command in commands {
            guard isSafeSlug(command.slug) else {
                throw CommandStore.StoreError.legacyIdentityAmbiguous(
                    "fixture has unsafe legacy slug '\(command.slug)'"
                )
            }
            index.append(LegacyIndexEntry(command: command))
            try writeData(Data(command.body.utf8), to: legacyBodyURL(command.slug))
        }
        try writeJSON(index, to: legacyIndexURL)
    }

    func setFaultPointForTesting(_ fault: CommandStore.TestFaultPoint?) {
        lock.lock()
        defer { lock.unlock() }
        faultPoint = fault
    }

    func activeRevisionIDForTesting() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return nil }
        return try readStateLocked().activeRevisionID
    }

    func custodyRootForTesting() -> URL {
        custodyRoot
    }

    func legacyBodyDataForTesting(slug: String) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        return try Data(contentsOf: legacyBodyURL(slug))
    }

    func activeBodyDataForTesting(commandID: String) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        let state = try readStateLocked()
        let snapshot = try readRevisionLocked(id: state.activeRevisionID, mergeLiveTelemetry: false)
        guard snapshot.localOverrides[commandID] != nil || snapshot.customCommands[commandID] != nil else {
            throw CommandStore.StoreError.corruptRevision(
                "command \(commandID) has no locally-custodied body"
            )
        }
        return try Data(contentsOf: bodyURL(revisionID: state.activeRevisionID, commandID: commandID))
    }

    func corruptActiveBodyForTesting(commandID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let state = try readStateLocked()
        let url = bodyURL(revisionID: state.activeRevisionID, commandID: commandID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CommandStore.StoreError.corruptRevision("missing body to corrupt")
        }
        try Data("tampered-by-test".utf8).write(to: url, options: [])
        try setFilePermissions(url)
    }

    func stateDataForTesting() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return nil }
        return try Data(contentsOf: stateURL)
    }

    // MARK: - Read / migration

    private func readableSnapshotLocked() throws -> Snapshot? {
        if let active = try activeSnapshotLocked(repairing: false) {
            return active
        }
        if legacyExistsLocked() {
            // Reads—including bridge_initialize's constitution bundle—must
            // observe legacy state without creating custody revisions.
            return try readLegacySnapshotLocked()
        }
        return nil
    }

    private func mutableSnapshotLocked() throws -> Snapshot {
        if let active = try activeSnapshotLocked(repairing: true) {
            return active
        }
        if legacyExistsLocked() {
            // The first requested command-state mutation is the sole legacy
            // migration boundary. Publication remains atomic and fail-closed.
            return try migrateLegacyLocked()
        }
        return .empty
    }

    private func legacyExistsLocked() -> Bool {
        FileManager.default.fileExists(atPath: legacyIndexURL.path)
    }

    private func activeSnapshotLocked(repairing: Bool) throws -> Snapshot? {
        guard FileManager.default.fileExists(atPath: stateURL.path) else { return nil }
        do {
            let state = try readStateLocked()
            return try readRevisionLocked(id: state.activeRevisionID, mergeLiveTelemetry: true)
        } catch {
            // A read may select a valid prior revision for its response, but
            // only a command-state mutation may repair the active pointer.
            return try recoverPriorValidRevisionLocked(after: error, activating: repairing)
        }
    }

    private func migrateLegacyLocked() throws -> Snapshot {
        let legacy = try readLegacySnapshotLocked()
        try publishLocked(legacy)
        return legacy
    }

    private func readLegacySnapshotLocked() throws -> Snapshot {
        let decoder = configuredDecoder()
        let data: Data
        do {
            data = try Data(contentsOf: legacyIndexURL)
        } catch {
            throw CommandStore.StoreError.ioFailure(underlying: error)
        }

        let index: [LegacyIndexEntry]
        do {
            index = try decoder.decode([LegacyIndexEntry].self, from: data)
        } catch {
            throw CommandStore.StoreError.legacyIdentityAmbiguous(
                "legacy index cannot be decoded safely: \(error.localizedDescription)"
            )
        }

        var seenSlugs = Set<String>()
        var seenSlots = Set<Int>()
        var seenBuiltInIDs = Set<String>()
        var snapshot = Snapshot.empty
        // Any legacy index was an already-initialized command palette. Its
        // absence entries are therefore tombstones, never a cue to defer or
        // repeat first-run seeding.
        snapshot.productDefaultsActive = true

        for entry in index {
            guard isSafeSlug(entry.slug), seenSlugs.insert(entry.slug).inserted else {
                throw CommandStore.StoreError.legacyIdentityAmbiguous(
                    "legacy slug '\(entry.slug)' is unsafe or duplicated"
                )
            }
            let bodyData: Data
            do {
                bodyData = try Data(contentsOf: legacyBodyURL(entry.slug))
            } catch {
                throw CommandStore.StoreError.legacyIdentityAmbiguous(
                    "legacy command '\(entry.slug)' has no readable body"
                )
            }
            guard let body = String(data: bodyData, encoding: .utf8) else {
                throw CommandStore.StoreError.legacyIdentityAmbiguous(
                    "legacy command '\(entry.slug)' is not valid UTF-8"
                )
            }
            if let slot = entry.keySlot {
                try assertSlot(slot)
                guard seenSlots.insert(slot).inserted else {
                    throw CommandStore.StoreError.legacyIdentityAmbiguous(
                        "legacy favorite slot \(slot) has more than one command"
                    )
                }
            }

            if let id = CommandStore.legacyBuiltInIdentityMap[entry.slug] {
                guard seenBuiltInIDs.insert(id).inserted else {
                    throw CommandStore.StoreError.legacyIdentityAmbiguous(
                        "multiple legacy commands map to immutable ID \(id)"
                    )
                }
                let migrated = StoredCommand(
                    id: id,
                    slug: entry.slug,
                    name: entry.name,
                    icon: entry.icon,
                    color: entry.color,
                    body: body
                )
                guard let productDefault = productDefaults.first(where: { $0.id == id }) else {
                    throw CommandStore.StoreError.legacyIdentityAmbiguous(
                        "no product default exists for legacy built-in \(entry.slug)"
                    )
                }
                if !isEquivalent(migrated, to: productDefault) {
                    snapshot.localOverrides[id] = migrated
                }
                if let slot = entry.keySlot {
                    snapshot.favorites[slot] = id
                }
                if let lastUsedAt = entry.lastUsedAt {
                    snapshot.usage[id] = lastUsedAt
                }
            } else {
                let id = legacyCustomID(for: entry.slug)
                snapshot.customCommands[id] = StoredCommand(
                    id: id,
                    slug: entry.slug,
                    name: entry.name,
                    icon: entry.icon,
                    color: entry.color,
                    body: body
                )
                if let slot = entry.keySlot {
                    snapshot.favorites[slot] = id
                }
                if let lastUsedAt = entry.lastUsedAt {
                    snapshot.usage[id] = lastUsedAt
                }
            }
        }

        let representedBuiltIns = Set(snapshot.localOverrides.keys).union(seenBuiltInIDs)
        for defaultCommand in productDefaults where !representedBuiltIns.contains(defaultCommand.id) {
            // Absence from an existing legacy index is a user-hidden default,
            // not a request to seed it again.
            snapshot.tombstones.insert(defaultCommand.id)
        }
        // A command fire may write ordinary usage telemetry before a later
        // command-state mutation activates custody. Merge that overlay while
        // reading legacy so recency remains visible and is captured exactly
        // when migration eventually occurs.
        if let live = readLiveTelemetryLocked() {
            for (id, date) in live {
                snapshot.usage[id] = date
            }
        }
        try validate(snapshot)
        return snapshot
    }

    private func recoverPriorValidRevisionLocked(
        after error: Error,
        activating: Bool
    ) throws -> Snapshot {
        // Recovery authority is the atomically activated state pointer alone.
        // A directory that exists beneath `revisions/` may be an orphan from a
        // write interrupted after finalization but before activation, so it
        // must never be promoted by directory enumeration. If state itself is
        // unreadable or it names no prior revision, fail closed rather than
        // silently resurrecting an unactivated or historical command set.
        guard let decodedState = try? readStateLocked() else {
            throw CommandStore.StoreError.corruptRevision(
                "active state cannot identify a prior valid recovery target: \(error.localizedDescription)"
            )
        }

        for id in decodedState.priorRevisionIDs {
            if let snapshot = try? readRevisionLocked(id: id, mergeLiveTelemetry: true) {
                if activating {
                    let history = unique(
                        [decodedState.activeRevisionID]
                        + decodedState.priorRevisionIDs
                        + [id]
                    ).filter { $0 != id }
                    try writeStateLocked(
                        ActiveState(
                            schemaVersion: Self.schemaVersion,
                            activeRevisionID: id,
                            priorRevisionIDs: history
                        )
                    )
                }
                return snapshot
            }
        }
        throw CommandStore.StoreError.corruptRevision(
            "active revision has no manifest-valid prior recovery target: \(error.localizedDescription)"
        )
    }

    private func readRevisionLocked(
        id: String,
        mergeLiveTelemetry: Bool
    ) throws -> Snapshot {
        guard isSafeID(id) else {
            throw CommandStore.StoreError.corruptRevision("unsafe revision ID")
        }
        let revisionRoot = revisionsRoot.appendingPathComponent(id, isDirectory: true)
        let manifest: RevisionManifest
        do {
            manifest = try configuredDecoder().decode(
                RevisionManifest.self,
                from: Data(contentsOf: revisionRoot.appendingPathComponent(Self.manifestFile))
            )
        } catch {
            throw CommandStore.StoreError.corruptRevision(
                "cannot read manifest for \(id): \(error.localizedDescription)"
            )
        }
        guard manifest.schemaVersion == Self.schemaVersion, manifest.revisionID == id else {
            throw CommandStore.StoreError.corruptRevision("manifest version or ID mismatch for \(id)")
        }
        let requiredMetadataPaths = [Self.layersFile, Self.revisionTelemetryFile]
        guard requiredMetadataPaths.allSatisfy({ manifest.payloadSHA256[$0] != nil }) else {
            throw CommandStore.StoreError.corruptRevision("manifest is missing required metadata hashes for \(id)")
        }
        for (relativePath, expectedSHA) in manifest.payloadSHA256 {
            guard isSafeRelativePath(relativePath) else {
                throw CommandStore.StoreError.corruptRevision("unsafe manifest path \(relativePath)")
            }
            let url = revisionRoot.appendingPathComponent(relativePath)
            guard let data = try? Data(contentsOf: url), sha256(data) == expectedSHA else {
                throw CommandStore.StoreError.corruptRevision(
                    "payload hash mismatch for \(id)/\(relativePath)"
                )
            }
        }

        let layers: Layers
        let telemetry: Telemetry
        do {
            layers = try configuredDecoder().decode(
                Layers.self,
                from: Data(contentsOf: revisionRoot.appendingPathComponent(Self.layersFile))
            )
            telemetry = try configuredDecoder().decode(
                Telemetry.self,
                from: Data(contentsOf: revisionRoot.appendingPathComponent(Self.revisionTelemetryFile))
            )
        } catch {
            throw CommandStore.StoreError.corruptRevision(
                "cannot decode revision \(id): \(error.localizedDescription)"
            )
        }
        guard layers.schemaVersion == Self.schemaVersion, telemetry.schemaVersion == Self.schemaVersion else {
            throw CommandStore.StoreError.corruptRevision("schema mismatch in revision \(id)")
        }
        let requiredBodyPaths = (Array(layers.localOverrides.keys) + Array(layers.customCommands.keys))
            .map(bodyRelativePath(for:))
            + layers.adoptedBases.keys.map(adoptedBaseRelativePath(for:))
        guard requiredBodyPaths.allSatisfy({ manifest.payloadSHA256[$0] != nil }) else {
            throw CommandStore.StoreError.corruptRevision("manifest is missing a command-body hash for \(id)")
        }

        var snapshot = Snapshot(
            productDefaultsActive: layers.productDefaultsActive,
            localOverrides: try readStoredCommands(
                layers.localOverrides,
                revisionID: id,
                revisionRoot: revisionRoot
            ),
            customCommands: try readStoredCommands(
                layers.customCommands,
                revisionID: id,
                revisionRoot: revisionRoot
            ),
            tombstones: Set(layers.hiddenDefaultTombstones),
            favorites: try favoriteMap(from: layers.favoriteLayout),
            usage: telemetry.lastUsedAt,
            adoptedBases: try readAdoptedBases(
                layers.adoptedBases,
                revisionID: id,
                revisionRoot: revisionRoot
            )
        )
        if mergeLiveTelemetry, let live = readLiveTelemetryLocked() {
            for (id, date) in live {
                snapshot.usage[id] = date
            }
        }
        try validate(snapshot)
        return snapshot
    }

    // MARK: - Atomic publication

    private func publishLocked(_ snapshot: Snapshot) throws {
        try validate(snapshot)
        try ensureDirectory(custodyRoot)
        try ensureDirectory(revisionsRoot)

        let revisionID = "\(Self.revisionPrefix)\(UUID().uuidString.lowercased())"
        let staging = revisionsRoot.appendingPathComponent(".\(revisionID).staging", isDirectory: true)
        let final = revisionsRoot.appendingPathComponent(revisionID, isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: staging.path) {
            try fm.removeItem(at: staging)
        }
        try ensureDirectory(staging)

        do {
            let layers = Layers(
                schemaVersion: Self.schemaVersion,
                productDefaultsActive: snapshot.productDefaultsActive,
                localOverrides: snapshot.localOverrides.mapValues { $0.withoutBody },
                customCommands: snapshot.customCommands.mapValues { $0.withoutBody },
                hiddenDefaultTombstones: snapshot.tombstones.sorted(),
                favoriteLayout: snapshot.favorites.mapKeys { String($0) },
                adoptedBases: snapshot.adoptedBases.mapValues { $0.withoutBody }
            )
            let telemetry = Telemetry(
                schemaVersion: Self.schemaVersion,
                lastUsedAt: snapshot.usage
            )
            try writeJSON(layers, to: staging.appendingPathComponent(Self.layersFile))
            try writeJSON(
                telemetry,
                to: staging.appendingPathComponent(Self.revisionTelemetryFile)
            )
            for stored in Array(snapshot.localOverrides.values) + Array(snapshot.customCommands.values) {
                try writeData(
                    Data(stored.body.utf8),
                    to: staging.appendingPathComponent(bodyRelativePath(for: stored.id))
                )
            }
            for (id, adopted) in snapshot.adoptedBases {
                try writeData(
                    Data(adopted.body.utf8),
                    to: staging.appendingPathComponent(adoptedBaseRelativePath(for: id))
                )
            }

            let manifest = try makeManifestLocked(revisionID: revisionID, root: staging)
            try writeJSON(manifest, to: staging.appendingPathComponent(Self.manifestFile))
            try injectFaultIfNeeded(.beforeRevisionFinalize)
            try fm.moveItem(at: staging, to: final)

            // Directory rename makes a complete, hash-verified revision visible,
            // but it is not active until state.json changes atomically below.
            try injectFaultIfNeeded(.beforeActivation)
            let previous = try? readStateLocked()
            let history = unique(
                ([previous?.activeRevisionID].compactMap { $0 })
                + (previous?.priorRevisionIDs ?? [])
            ).filter { $0 != revisionID }
            try writeStateLocked(
                ActiveState(
                    schemaVersion: Self.schemaVersion,
                    activeRevisionID: revisionID,
                    priorRevisionIDs: history
                )
            )

            // A failed telemetry-overlay refresh cannot invalidate the newly
            // active revision; that revision already contains its exact usage.
            try? writeLiveTelemetryLocked(snapshot.usage)
        } catch {
            if fm.fileExists(atPath: staging.path) {
                try? fm.removeItem(at: staging)
            }
            throw error
        }
    }

    private func makeManifestLocked(revisionID: String, root: URL) throws -> RevisionManifest {
        let fm = FileManager.default
        let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        var hashes: [String: String] = [:]
        while let url = enumerator?.nextObject() as? URL {
            guard url.lastPathComponent != Self.manifestFile else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let relative = try relativePath(of: url, under: root)
            hashes[relative] = sha256(try Data(contentsOf: url))
        }
        return RevisionManifest(
            schemaVersion: Self.schemaVersion,
            revisionID: revisionID,
            createdAt: Date(),
            payloadSHA256: hashes
        )
    }

    private func readStateLocked() throws -> ActiveState {
        let state: ActiveState
        do {
            state = try configuredDecoder().decode(ActiveState.self, from: Data(contentsOf: stateURL))
        } catch {
            throw CommandStore.StoreError.corruptRevision(
                "cannot decode active state: \(error.localizedDescription)"
            )
        }
        guard state.schemaVersion == Self.schemaVersion,
              isSafeID(state.activeRevisionID),
              state.priorRevisionIDs.allSatisfy(isSafeID)
        else {
            throw CommandStore.StoreError.corruptRevision("invalid active-state schema or revision ID")
        }
        return state
    }

    private func writeStateLocked(_ state: ActiveState) throws {
        try writeJSON(state, to: stateURL)
    }

    // MARK: - Effective state

    private func effectiveCommands(_ snapshot: Snapshot) -> [CommandStore.Command] {
        var entries: [CommandStore.Command] = []
        let slotByID = Dictionary(uniqueKeysWithValues: snapshot.favorites.map { ($0.value, $0.key) })
        if snapshot.productDefaultsActive {
            for productDefault in productDefaults where !snapshot.tombstones.contains(productDefault.id) {
                let stored = snapshot.localOverrides[productDefault.id] ?? StoredCommand(productDefault)
                entries.append(
                    CommandStore.Command(
                        id: stored.id,
                        slug: stored.slug,
                        name: stored.name,
                        icon: stored.icon,
                        color: stored.color,
                        keySlot: slotByID[stored.id],
                        lastUsedAt: snapshot.usage[stored.id],
                        body: stored.body
                    )
                )
            }
        }
        for stored in snapshot.customCommands.values {
            entries.append(
                CommandStore.Command(
                    id: stored.id,
                    slug: stored.slug,
                    name: stored.name,
                    icon: stored.icon,
                    color: stored.color,
                    keySlot: slotByID[stored.id],
                    lastUsedAt: snapshot.usage[stored.id],
                    body: stored.body
                )
            )
        }
        return entries.sortedByRecency()
    }

    private func commandByID(_ id: String, in snapshot: Snapshot) throws -> CommandStore.Command {
        guard let command = effectiveCommands(snapshot).first(where: { $0.id == id }) else {
            throw CommandStore.StoreError.corruptRevision("published command \(id) cannot be read back")
        }
        return command
    }

    private func assignFavorite(commandID: String, slot: Int?, snapshot: inout Snapshot) {
        snapshot.favorites = snapshot.favorites.filter { $0.value != commandID }
        if let slot {
            snapshot.favorites[slot] = commandID
        }
    }

    private func validate(_ snapshot: Snapshot) throws {
        let defaultsByID = Dictionary(uniqueKeysWithValues: productDefaults.map { ($0.id, $0) })
        guard defaultsByID.count == productDefaults.count else {
            throw CommandStore.StoreError.corruptRevision("product default IDs are not unique")
        }

        var allIDs = Set<String>()
        var allSlugs = Set<String>()
        if snapshot.productDefaultsActive {
            for defaultCommand in productDefaults {
                guard isSafeID(defaultCommand.id), isSafeSlug(defaultCommand.slug),
                      allIDs.insert(defaultCommand.id).inserted,
                      allSlugs.insert(defaultCommand.slug).inserted
                else {
                    throw CommandStore.StoreError.corruptRevision("invalid product default identity")
                }
            }
        }
        for (id, stored) in snapshot.localOverrides {
            guard snapshot.productDefaultsActive,
                  defaultsByID[id] != nil, stored.id == id, isSafeStoredCommand(stored) else {
                throw CommandStore.StoreError.corruptRevision("invalid local override \(id)")
            }
        }
        for (id, adopted) in snapshot.adoptedBases {
            guard snapshot.localOverrides[id] != nil, isSafeID(id), isSafeAdoptedBase(adopted) else {
                throw CommandStore.StoreError.corruptRevision("invalid adopted base \(id)")
            }
        }
        for (id, stored) in snapshot.customCommands {
            guard defaultsByID[id] == nil, stored.id == id, isSafeStoredCommand(stored),
                  allIDs.insert(id).inserted, allSlugs.insert(stored.slug).inserted
            else {
                throw CommandStore.StoreError.corruptRevision("invalid custom command \(id)")
            }
        }
        for id in snapshot.tombstones {
            guard snapshot.productDefaultsActive, defaultsByID[id] != nil else {
                throw CommandStore.StoreError.corruptRevision("unknown hidden default \(id)")
            }
        }
        var favoriteIDs = Set<String>()
        for (slot, id) in snapshot.favorites {
            try assertSlot(slot)
            guard allIDs.contains(id),
                  !snapshot.tombstones.contains(id),
                  favoriteIDs.insert(id).inserted
            else {
                throw CommandStore.StoreError.corruptRevision("invalid or duplicate favorite reference \(id)")
            }
        }
    }

    private func isEquivalent(
        _ stored: StoredCommand,
        to productDefault: CommandStore.ProductDefault
    ) -> Bool {
        stored.id == productDefault.id
            && stored.slug == productDefault.slug
            && stored.name == productDefault.name
            && stored.icon == productDefault.icon
            && stored.color == productDefault.color
            && stored.body == productDefault.body
    }

    private func makeReconciliationLocked(
        incoming: CommandStore.ProductDefault,
        snapshot: Snapshot
    ) -> CommandStore.CommandReconciliation? {
        if snapshot.productDefaultsActive == false { return nil }
        if snapshot.tombstones.contains(incoming.id) { return nil }

        let localStored = snapshot.localOverrides[incoming.id]
        let adopted = snapshot.adoptedBases[incoming.id]
        let localCommand = localStored.map { stored in
            CommandStore.Command(
                id: stored.id,
                slug: stored.slug,
                name: stored.name,
                icon: stored.icon,
                color: stored.color,
                keySlot: snapshot.favorites.first(where: { $0.value == stored.id })?.key,
                lastUsedAt: snapshot.usage[stored.id],
                body: stored.body
            )
        }
        let base = adopted.map {
            $0.asProductDefault(
                id: incoming.id,
                slug: incoming.slug,
                initialKeySlot: incoming.initialKeySlot
            )
        }
        let (classification, gate, updateAvailable) = classifyLocked(
            local: localStored,
            incoming: incoming,
            adopted: adopted
        )
        return CommandStore.CommandReconciliation(
            commandID: incoming.id,
            slug: incoming.slug,
            base: base ?? (localStored == nil ? incoming : nil),
            local: localCommand,
            incoming: incoming,
            classification: classification,
            updateAvailable: updateAvailable,
            executionGate: gate
        )
    }

    private func classifyLocked(
        local: StoredCommand?,
        incoming: CommandStore.ProductDefault,
        adopted: AdoptedBase?
    ) -> (CommandStore.UpdateClassification, CommandStore.ExecutionGate, Bool) {
        guard local != nil else {
            return (.current, .open, false)
        }

        let adoptedSchema = adopted?.schemaVersion
            ?? CommandStore.ProductDefault.currentCatalogSchemaVersion
        let adoptedBehavior = adopted?.behaviorVersion
            ?? CommandStore.ProductDefault.currentCatalogBehaviorVersion
        let adoptedCaps = Set(adopted?.requiredCapabilities ?? [])
        let incomingCaps = Set(incoming.requiredCapabilities)

        if incoming.schemaVersion != adoptedSchema || incomingCaps != adoptedCaps {
            let evidence = [
                "schemaVersion \(adoptedSchema)→\(incoming.schemaVersion)",
                "requiredCapabilities \(sortedCaps(adoptedCaps))→\(sortedCaps(incomingCaps))"
            ].joined(separator: "; ")
            return (
                .compatibilityRequired,
                .compatibilityRequired(evidence: evidence),
                true
            )
        }
        if incoming.behaviorVersion != adoptedBehavior {
            return (.behavioral, .open, true)
        }
        return (.editorial, .open, true)
    }

    private func sortedCaps(_ caps: Set<String>) -> String {
        "[" + caps.sorted().joined(separator: ",") + "]"
    }

    // MARK: - Revision payload parsing

    private func readStoredCommands(
        _ descriptors: [String: StoredDescriptor],
        revisionID: String,
        revisionRoot: URL
    ) throws -> [String: StoredCommand] {
        var result: [String: StoredCommand] = [:]
        for (id, descriptor) in descriptors {
            guard descriptor.id == id, isSafeID(id), isSafeSlug(descriptor.slug) else {
                throw CommandStore.StoreError.corruptRevision("invalid stored command descriptor")
            }
            let url = revisionRoot.appendingPathComponent(bodyRelativePath(for: id))
            guard let data = try? Data(contentsOf: url),
                  let body = String(data: data, encoding: .utf8)
            else {
                throw CommandStore.StoreError.corruptRevision(
                    "missing or invalid command body for \(revisionID)/\(id)"
                )
            }
            result[id] = StoredCommand(
                id: descriptor.id,
                slug: descriptor.slug,
                name: descriptor.name,
                icon: descriptor.icon,
                color: descriptor.color,
                body: body
            )
        }
        return result
    }

    private func readAdoptedBases(
        _ descriptors: [String: AdoptedBaseDescriptor],
        revisionID: String,
        revisionRoot: URL
    ) throws -> [String: AdoptedBase] {
        var result: [String: AdoptedBase] = [:]
        for (id, descriptor) in descriptors {
            guard isSafeID(id) else {
                throw CommandStore.StoreError.corruptRevision("invalid adopted-base identity \(id)")
            }
            let url = revisionRoot.appendingPathComponent(adoptedBaseRelativePath(for: id))
            guard let data = try? Data(contentsOf: url),
                  let body = String(data: data, encoding: .utf8)
            else {
                throw CommandStore.StoreError.corruptRevision(
                    "missing or invalid adopted base for \(revisionID)/\(id)"
                )
            }
            result[id] = AdoptedBase(
                schemaVersion: descriptor.schemaVersion,
                behaviorVersion: descriptor.behaviorVersion,
                requiredCapabilities: descriptor.requiredCapabilities,
                name: descriptor.name,
                icon: descriptor.icon,
                color: descriptor.color,
                body: body
            )
        }
        return result
    }

    private func favoriteMap(from layout: [String: String]) throws -> [Int: String] {
        var result: [Int: String] = [:]
        for (slot, id) in layout {
            guard let integerSlot = Int(slot), String(integerSlot) == slot else {
                throw CommandStore.StoreError.corruptRevision("favorite slot is not an integer")
            }
            result[integerSlot] = id
        }
        return result
    }

    private func readLiveTelemetryLocked() -> [String: Date]? {
        guard let data = try? Data(contentsOf: liveTelemetryURL),
              let telemetry = try? configuredDecoder().decode(Telemetry.self, from: data),
              telemetry.schemaVersion == Self.schemaVersion
        else {
            return nil
        }
        return telemetry.lastUsedAt
    }

    private func writeLiveTelemetryLocked(_ usage: [String: Date]) throws {
        try writeJSON(
            Telemetry(schemaVersion: Self.schemaVersion, lastUsedAt: usage),
            to: liveTelemetryURL
        )
    }

    // MARK: - File safety / serialization

    private func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }

    private func setFilePermissions(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func writeData(_ data: Data, to url: URL) throws {
        try ensureDirectory(url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
        try setFilePermissions(url)
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try writeData(try configuredEncoder().encode(value), to: url)
    }

    private func configuredEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func configuredDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func bodyRelativePath(for commandID: String) -> String {
        "bodies/\(commandID).md"
    }

    private func adoptedBaseRelativePath(for commandID: String) -> String {
        "\(Self.adoptedBasesDirectory)/\(commandID).md"
    }

    /// `FileManager` can enumerate the same temporary directory through its
    /// canonical `/private/var` spelling while the caller supplied `/var`.
    /// Never derive a manifest path with a blind string replacement: canonical
    /// both sides first, then require a true directory-prefix relationship.
    private func relativePath(of url: URL, under root: URL) throws -> String {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalURL = url.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = canonicalRoot + "/"
        guard canonicalURL.hasPrefix(prefix) else {
            throw CommandStore.StoreError.corruptRevision(
                "revision payload escaped its staging directory"
            )
        }
        return String(canonicalURL.dropFirst(prefix.count))
    }

    private func bodyURL(revisionID: String, commandID: String) -> URL {
        revisionsRoot
            .appendingPathComponent(revisionID, isDirectory: true)
            .appendingPathComponent(bodyRelativePath(for: commandID), isDirectory: false)
    }

    private func finalizedRevisionIDsLocked() -> [String] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: revisionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return contents.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  url.lastPathComponent.hasPrefix(Self.revisionPrefix),
                  isSafeID(url.lastPathComponent)
            else {
                return nil
            }
            return url.lastPathComponent
        }.sorted()
    }

    private func injectFaultIfNeeded(_ point: CommandStore.TestFaultPoint) throws {
        if faultPoint == point {
            throw CommandStore.StoreError.injectedFailure(point)
        }
    }

    private func legacyCustomID(for slug: String) -> String {
        "bridge.command.legacy.\(sha256(Data("bridge-command-v1:\(slug)".utf8)))"
    }

    private func assertSlot(_ slot: Int) throws {
        if slot < 0 || slot > 9 {
            throw CommandStore.StoreError.slotOutOfRange(slot)
        }
    }

    private func isSafeSlug(_ value: String) -> Bool {
        !value.isEmpty && CommandStore.slugify(value) == value
    }

    private func isSafeID(_ value: String) -> Bool {
        guard !value.isEmpty, !value.contains("..") else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            let value = scalar.value
            return (value >= 0x61 && value <= 0x7A)
                || (value >= 0x30 && value <= 0x39)
                || scalar == "."
                || scalar == "-"
        }
    }

    private func isSafeStoredCommand(_ command: StoredCommand) -> Bool {
        isSafeID(command.id) && isSafeSlug(command.slug)
    }

    private func isSafeAdoptedBase(_ base: AdoptedBase) -> Bool {
        base.schemaVersion >= 1 && base.behaviorVersion >= 1
    }

    private func isSafeRelativePath(_ value: String) -> Bool {
        !value.hasPrefix("/")
            && !value.contains("..")
            && !value.contains("//")
            && !value.split(separator: "/").contains(where: { $0.isEmpty })
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    // MARK: - Codable containers

    private struct ActiveState: Codable {
        var schemaVersion: Int
        var activeRevisionID: String
        var priorRevisionIDs: [String]
    }

    private struct RevisionManifest: Codable {
        var schemaVersion: Int
        var revisionID: String
        var createdAt: Date
        var payloadSHA256: [String: String]
    }

    private struct Layers: Codable {
        var schemaVersion: Int
        var productDefaultsActive: Bool
        var localOverrides: [String: StoredDescriptor]
        var customCommands: [String: StoredDescriptor]
        var hiddenDefaultTombstones: [String]
        var favoriteLayout: [String: String]
        var adoptedBases: [String: AdoptedBaseDescriptor]

        enum CodingKeys: String, CodingKey {
            case schemaVersion, productDefaultsActive, localOverrides, customCommands
            case hiddenDefaultTombstones, favoriteLayout, adoptedBases
        }

        init(
            schemaVersion: Int,
            productDefaultsActive: Bool,
            localOverrides: [String: StoredDescriptor],
            customCommands: [String: StoredDescriptor],
            hiddenDefaultTombstones: [String],
            favoriteLayout: [String: String],
            adoptedBases: [String: AdoptedBaseDescriptor]
        ) {
            self.schemaVersion = schemaVersion
            self.productDefaultsActive = productDefaultsActive
            self.localOverrides = localOverrides
            self.customCommands = customCommands
            self.hiddenDefaultTombstones = hiddenDefaultTombstones
            self.favoriteLayout = favoriteLayout
            self.adoptedBases = adoptedBases
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
            productDefaultsActive = try values.decode(Bool.self, forKey: .productDefaultsActive)
            localOverrides = try values.decode([String: StoredDescriptor].self, forKey: .localOverrides)
            customCommands = try values.decode([String: StoredDescriptor].self, forKey: .customCommands)
            hiddenDefaultTombstones = try values.decode([String].self, forKey: .hiddenDefaultTombstones)
            favoriteLayout = try values.decode([String: String].self, forKey: .favoriteLayout)
            adoptedBases = try values.decodeIfPresent(
                [String: AdoptedBaseDescriptor].self,
                forKey: .adoptedBases
            ) ?? [:]
        }
    }

    private struct Telemetry: Codable {
        var schemaVersion: Int
        var lastUsedAt: [String: Date]
    }

    private struct StoredDescriptor: Codable {
        var id: String
        var slug: String
        var name: String
        var icon: CommandStore.Icon
        var color: CommandStore.NotionColor?
    }

    private struct StoredCommand: Equatable {
        var id: String
        var slug: String
        var name: String
        var icon: CommandStore.Icon
        var color: CommandStore.NotionColor?
        var body: String

        init(
            id: String,
            slug: String,
            name: String,
            icon: CommandStore.Icon,
            color: CommandStore.NotionColor?,
            body: String
        ) {
            self.id = id
            self.slug = slug
            self.name = name
            self.icon = icon
            self.color = color
            self.body = body
        }

        init(_ productDefault: CommandStore.ProductDefault) {
            self.init(
                id: productDefault.id,
                slug: productDefault.slug,
                name: productDefault.name,
                icon: productDefault.icon,
                color: productDefault.color,
                body: productDefault.body
            )
        }

        init(_ adopted: AdoptedBase, id: String, slug: String) {
            self.init(
                id: id,
                slug: slug,
                name: adopted.name,
                icon: adopted.icon,
                color: adopted.color,
                body: adopted.body
            )
        }

        var withoutBody: StoredDescriptor {
            StoredDescriptor(id: id, slug: slug, name: name, icon: icon, color: color)
        }
    }

    private struct AdoptedBaseDescriptor: Codable {
        var schemaVersion: Int
        var behaviorVersion: Int
        var requiredCapabilities: [String]
        var name: String
        var icon: CommandStore.Icon
        var color: CommandStore.NotionColor?
    }

    private struct AdoptedBase: Equatable {
        var schemaVersion: Int
        var behaviorVersion: Int
        var requiredCapabilities: [String]
        var name: String
        var icon: CommandStore.Icon
        var color: CommandStore.NotionColor?
        var body: String

        init(
            schemaVersion: Int,
            behaviorVersion: Int,
            requiredCapabilities: [String],
            name: String,
            icon: CommandStore.Icon,
            color: CommandStore.NotionColor?,
            body: String
        ) {
            self.schemaVersion = schemaVersion
            self.behaviorVersion = behaviorVersion
            self.requiredCapabilities = requiredCapabilities
            self.name = name
            self.icon = icon
            self.color = color
            self.body = body
        }

        init(_ productDefault: CommandStore.ProductDefault) {
            self.init(
                schemaVersion: productDefault.schemaVersion,
                behaviorVersion: productDefault.behaviorVersion,
                requiredCapabilities: productDefault.requiredCapabilities,
                name: productDefault.name,
                icon: productDefault.icon,
                color: productDefault.color,
                body: productDefault.body
            )
        }

        var withoutBody: AdoptedBaseDescriptor {
            AdoptedBaseDescriptor(
                schemaVersion: schemaVersion,
                behaviorVersion: behaviorVersion,
                requiredCapabilities: requiredCapabilities,
                name: name,
                icon: icon,
                color: color
            )
        }

        func asProductDefault(
            id: String,
            slug: String,
            initialKeySlot: Int?
        ) -> CommandStore.ProductDefault {
            CommandStore.ProductDefault(
                id: id,
                slug: slug,
                name: name,
                icon: icon,
                color: color,
                initialKeySlot: initialKeySlot,
                body: body,
                schemaVersion: schemaVersion,
                behaviorVersion: behaviorVersion,
                requiredCapabilities: requiredCapabilities
            )
        }
    }

    private struct LegacyIndexEntry: Codable {
        var slug: String
        var name: String
        var icon: CommandStore.Icon
        var color: CommandStore.NotionColor?
        var keySlot: Int?
        var lastUsedAt: Date?

        init(command: CommandStore.Command) {
            self.slug = command.slug
            self.name = command.name
            self.icon = command.icon
            self.color = command.color
            self.keySlot = command.keySlot
            self.lastUsedAt = command.lastUsedAt
        }
    }

    private struct Snapshot {
        var productDefaultsActive: Bool
        var localOverrides: [String: StoredCommand]
        var customCommands: [String: StoredCommand]
        var tombstones: Set<String>
        var favorites: [Int: String]
        var usage: [String: Date]
        var adoptedBases: [String: AdoptedBase]

        static let empty = Snapshot(
            productDefaultsActive: false,
            localOverrides: [:],
            customCommands: [:],
            tombstones: [],
            favorites: [:],
            usage: [:],
            adoptedBases: [:]
        )
    }
}

private extension Dictionary where Key == Int, Value == String {
    func mapKeys<T: Hashable>(_ transform: (Int) -> T) -> [T: String] {
        var result: [T: String] = [:]
        for (key, value) in self {
            result[transform(key)] = value
        }
        return result
    }
}
