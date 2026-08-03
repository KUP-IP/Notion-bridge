// CommandCustodyTests.swift — A0 / GitHub #140
//
// These fixtures deliberately use the exact v1 production seed catalog and
// then exercise the state that v1 could actually persist: body overrides,
// custom commands, hidden defaults, hot-key assignments, and recency data.

import Foundation
import TheBridgeLib

func runCommandCustodyTests() async {
    print("\n[Command custody A0 / #140]")

    await test("A0 identity map covers every production default exactly") {
        let defaults = CommandStore.defaultProductCatalog
        try expect(defaults.count == 10, "expected the complete ten-command production catalog")
        try expect(CommandStore.legacyBuiltInIdentityMap.count == defaults.count)
        for item in defaults {
            try expect(
                CommandStore.legacyBuiltInIdentityMap[item.slug] == item.id,
                "legacy slug \(item.slug) must map to \(item.id)"
            )
            try expect(item.id.hasPrefix("bridge.command.builtin."))
        }
    }

    await test("A0 migrates an opt-in read-only copy of the live legacy fixture") {
        guard let rawRoot = ProcessInfo.processInfo.environment["BRIDGE_A0_LEGACY_FIXTURE_ROOT"],
              !rawRoot.isEmpty
        else {
            print("  ⏭️  BRIDGE_A0_LEGACY_FIXTURE_ROOT not set; live fixture copy skipped")
            return
        }

        let sourceRoot = URL(fileURLWithPath: rawRoot, isDirectory: true)
        let sourceIndexURL = sourceRoot.appendingPathComponent("index.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sourceIndex = try decoder.decode(
            [LegacyFixtureEntry].self,
            from: Data(contentsOf: sourceIndexURL)
        )
        try expect(!sourceIndex.isEmpty, "live legacy fixture has no commands")

        try await withCustodyStore { store, copiedRoot in
            // Copy bytes into an isolated fixture root. The source root is
            // read-only for this test; migration only ever writes copiedRoot.
            try Data(contentsOf: sourceIndexURL).write(
                to: copiedRoot.appendingPathComponent("index.json"),
                options: .atomic
            )
            var beforeCommands: [CommandStore.Command] = []
            var sourceBodies: [String: Data] = [:]
            for entry in sourceIndex {
                let data = try Data(contentsOf: sourceRoot.appendingPathComponent("\(entry.slug).md"))
                guard let body = String(data: data, encoding: .utf8) else {
                    throw TestError.assertion("live legacy body is not UTF-8 for \(entry.slug)")
                }
                try data.write(
                    to: copiedRoot.appendingPathComponent("\(entry.slug).md"),
                    options: .atomic
                )
                sourceBodies[entry.slug] = data
                beforeCommands.append(
                    CommandStore.Command(
                        slug: entry.slug,
                        name: entry.name,
                        icon: entry.icon,
                        color: entry.color,
                        keySlot: entry.keySlot,
                        lastUsedAt: entry.lastUsedAt,
                        body: body
                    )
                )
            }

            let readableLegacy = try store.list()
            try expect(effectiveState(readableLegacy) == effectiveState(beforeCommands),
                       "live legacy effective state changed before migration")
            try expect(try store.stateDataForTesting() == nil,
                       "a read-only live fixture check activated custody")
            try activateCustodyForTesting(store, commands: readableLegacy)
            let migrated = try store.list()
            try expect(effectiveState(migrated) == effectiveState(beforeCommands),
                       "live legacy effective state changed in the isolated migration")
            try expect(Set(migrated.map(\.id)).count == migrated.count)

            let defaultsByID = Dictionary(
                uniqueKeysWithValues: CommandStore.defaultProductCatalog.map { ($0.id, $0) }
            )
            for original in beforeCommands {
                guard let migratedCommand = migrated.first(where: { $0.slug == original.slug }) else {
                    throw TestError.assertion("live legacy command disappeared: \(original.slug)")
                }
                guard let sourceBody = sourceBodies[original.slug] else {
                    throw TestError.assertion("live legacy body disappeared from the copy: \(original.slug)")
                }
                if let expectedID = CommandStore.legacyBuiltInIdentityMap[original.slug] {
                    try expect(migratedCommand.id == expectedID)
                    if let productDefault = defaultsByID[expectedID],
                       !matchesProductDefault(original, productDefault)
                    {
                        try expect(
                            try store.activeBodyDataForTesting(commandID: migratedCommand.id)
                                == sourceBody,
                            "live override body changed: \(original.slug)"
                        )
                    }
                } else {
                    try expect(migratedCommand.id.hasPrefix("bridge.command.legacy."))
                    try expect(
                        try store.activeBodyDataForTesting(commandID: migratedCommand.id)
                            == sourceBody,
                        "live custom body changed: \(original.slug)"
                    )
                }
            }

            let observedBuiltInIDs = Set(
                beforeCommands.compactMap { CommandStore.legacyBuiltInIdentityMap[$0.slug] }
            )
            for defaultCommand in CommandStore.defaultProductCatalog where !observedBuiltInIDs.contains(defaultCommand.id) {
                try expect(try store.get(slug: defaultCommand.slug) == nil,
                           "live hidden default resurrected: \(defaultCommand.slug)")
            }
        }
    }

    await test("A0 migrates the production fixture byte-for-byte without duplicate or effective-state drift") {
        try await withCustodyStore { store, root in
            var fixture = CommandStore.currentLegacyProductionFixture
            guard let executeIndex = fixture.firstIndex(where: { $0.slug == "execute" }),
                  let scopeCutIndex = fixture.firstIndex(where: { $0.slug == "scope-cut" })
            else {
                throw TestError.assertion("production fixture is missing expected built-ins")
            }

            // A v1 local override: its immutable ID must be the product ID,
            // while its literal payload is retained outside ordinary metadata.
            fixture[executeIndex].body = "OVERRIDE-BODY-A0\r\nPreserve every byte.\n\n🧪\n"
            fixture[executeIndex].name = "Execute Locally"
            fixture[executeIndex].icon = .symbol("bolt.fill")
            fixture[executeIndex].color = .purple
            fixture[executeIndex].lastUsedAt = Date(timeIntervalSince1970: 1_234_567)

            // This models v1's slot eviction: Scope Cut was unbound before a
            // local custom command took slot 3.
            fixture[scopeCutIndex].keySlot = nil
            let customBody = "CUSTOM-BODY-A0\r\nLiteral custom payload.\n\nλ\n"
            fixture.append(
                CommandStore.Command(
                    slug: "operator-custody",
                    name: "Operator Custody",
                    icon: .emoji("🗃️"),
                    color: .brown,
                    keySlot: 3,
                    lastUsedAt: Date(timeIntervalSince1970: 2_345_678),
                    body: customBody
                )
            )
            let before = effectiveState(fixture)
            try store.installLegacyFixtureForTesting(fixture)
            let legacyOverrideBytes = try store.legacyBodyDataForTesting(slug: "execute")
            let legacyCustomBytes = try store.legacyBodyDataForTesting(slug: "operator-custody")

            let readableLegacy = try store.list()
            try expect(effectiveState(readableLegacy) == before,
                       "legacy effective command state changed before migration")
            try expect(try store.stateDataForTesting() == nil,
                       "legacy read activated custody before a command-state mutation")
            try activateCustodyForTesting(store, commands: readableLegacy)
            let migrated = try store.list()
            try expect(effectiveState(migrated) == before, "pre/post effective command state changed")
            try expect(Set(migrated.map(\.id)).count == migrated.count, "migration created duplicate IDs")

            let builtInMap = Dictionary(uniqueKeysWithValues: migrated
                .filter { CommandStore.legacyBuiltInIdentityMap[$0.slug] != nil }
                .map { ($0.slug, $0.id) })
            try expect(builtInMap == CommandStore.legacyBuiltInIdentityMap, "production built-in mapping drifted")

            guard let migratedOverride = migrated.first(where: { $0.slug == "execute" }),
                  let migratedCustom = migrated.first(where: { $0.slug == "operator-custody" })
            else {
                throw TestError.assertion("migrated override or custom command is missing")
            }
            try expect(migratedOverride.id == "bridge.command.builtin.execute")
            try expect(migratedCustom.id.hasPrefix("bridge.command.legacy."))
            try expect(try store.activeBodyDataForTesting(commandID: migratedOverride.id) == legacyOverrideBytes)
            try expect(try store.activeBodyDataForTesting(commandID: migratedCustom.id) == legacyCustomBytes)
            try expect(try store.command(forKeySlot: 3)?.id == migratedCustom.id)

            guard let initialRevision = try store.activeRevisionIDForTesting() else {
                throw TestError.assertion("migration did not activate a custody revision")
            }
            let layersURL = root
                .appendingPathComponent("custody/revisions/\(initialRevision)/layers.json")
            let layers = try String(contentsOf: layersURL, encoding: .utf8)
            try expect(!layers.contains("OVERRIDE-BODY-A0"), "override body leaked into metadata layer")
            try expect(!layers.contains("CUSTOM-BODY-A0"), "custom body leaked into metadata layer")
            try expect(layers.contains(migratedCustom.id), "favorite layout does not reference immutable command ID")

            // Favorite layout must survive a body rewrite independently.
            var rewrittenCustom = migratedCustom
            rewrittenCustom.body = "CUSTOM-BODY-A0-REWRITTEN\n"
            let updatedCustom = try store.update(rewrittenCustom)
            try expect(updatedCustom.id == migratedCustom.id)
            try expect(try store.command(forKeySlot: 3)?.id == migratedCustom.id)

            // Usage is live telemetry only: it must not activate a revision or
            // rewrite a locally-custodied body / state pointer.
            guard let revisionBeforeTelemetry = try store.activeRevisionIDForTesting(),
                  let stateBeforeTelemetry = try store.stateDataForTesting()
            else {
                throw TestError.assertion("missing active state before telemetry test")
            }
            let bodyBeforeTelemetry = try store.activeBodyDataForTesting(commandID: migratedCustom.id)
            try store.recordUse(slug: migratedCustom.slug, at: Date(timeIntervalSince1970: 3_456_789))
            try expect(try store.activeRevisionIDForTesting() == revisionBeforeTelemetry)
            try expect(try store.stateDataForTesting() == stateBeforeTelemetry)
            try expect(try store.activeBodyDataForTesting(commandID: migratedCustom.id) == bodyBeforeTelemetry)

            try assertRestrictivePermissions(root: root)

            // A fresh application object, even with a changed product-default
            // body, may read the store but cannot mutate the local custody tree.
            let beforeReplacement = try custodyTree(root: root)
            var replacementCatalog = CommandStore.defaultProductCatalog
            replacementCatalog[0].body = "replacement bundle product default"
            let replacement = CommandStore(storageRoot: root, productDefaults: replacementCatalog)
            _ = try replacement.list()
            try expect(try custodyTree(root: root) == beforeReplacement, "application replacement mutated local custody")

            // Reopening after migration is idempotent: no new revision and no
            // duplicate command identity is created merely by reading.
            let reopened = CommandStore(storageRoot: root)
            let reopenedCommands = try reopened.list()
            try expect(try reopened.activeRevisionIDForTesting() == revisionBeforeTelemetry)
            try expect(Set(reopenedCommands.map(\.id)).count == reopenedCommands.count)
            try expect(reopenedCommands.count == migrated.count)
        }
    }

    await test("A0 command reads and seeding leave a legacy store byte-identical until mutation") {
        try await withCustodyStore { store, root in
            var fixture = CommandStore.currentLegacyProductionFixture
            guard let executeIndex = fixture.firstIndex(where: { $0.slug == "execute" }) else {
                throw TestError.assertion("fixture missing Execute")
            }
            fixture[executeIndex].body = "legacy-read-override\\r\\nexact"
            try store.installLegacyFixtureForTesting(fixture)
            let beforeLegacy = try legacyTree(root: root)

            let listed = try store.list()
            _ = try store.get(slug: "execute")
            _ = try store.search("exec")
            _ = try store.command(forKeySlot: 5)
            try store.seedIfEmpty()

            var replacementCatalog = CommandStore.defaultProductCatalog
            replacementCatalog[0].body = "replacement bundle product default"
            let replacement = CommandStore(storageRoot: root, productDefaults: replacementCatalog)
            _ = try replacement.list()

            try expect(try store.stateDataForTesting() == nil,
                       "read-only command access activated custody")
            try expect(!FileManager.default.fileExists(
                atPath: root.appendingPathComponent("custody", isDirectory: true).path
            ), "read-only command access created a custody tree")
            try expect(try legacyTree(root: root) == beforeLegacy,
                       "read-only command access changed legacy bytes")

            try activateCustodyForTesting(store, commands: listed)
            try expect(try store.activeRevisionIDForTesting() != nil,
                       "requested command-state mutation did not activate custody")
            try expect(try legacyTree(root: root) == beforeLegacy,
                       "migration rewrote legacy source bytes")
        }
    }

    await test("A0 migrates legacy absence into a hidden-default tombstone without resurrection") {
        try await withCustodyStore { store, _ in
            var fixture = CommandStore.currentLegacyProductionFixture
            fixture.removeAll { $0.slug == "scope-cut" }
            try store.installLegacyFixtureForTesting(fixture)

            try expect(try store.get(slug: "scope-cut") == nil)
            try store.seedIfEmpty()
            try expect(try store.get(slug: "scope-cut") == nil, "hidden default resurrected after reseed")

            let listed = try store.list()
            try activateCustodyForTesting(store, commands: listed)
            try expect(try store.get(slug: "scope-cut") == nil,
                       "hidden default resurrected during migration")

            let replacement = CommandStore(storageRoot: store.custodyRootForTesting().deletingLastPathComponent())
            try expect(try replacement.get(slug: "scope-cut") == nil, "hidden default resurrected after restart")
        }
    }

    await test("A0 interrupted revision write keeps the prior revision active") {
        try await withCustodyStore { store, _ in
            let stable = try store.create(name: "Stable", icon: .emoji("🧱"), body: "stable")
            guard let priorRevision = try store.activeRevisionIDForTesting() else {
                throw TestError.assertion("baseline revision missing")
            }

            store.setFaultPointForTesting(.beforeActivation)
            do {
                _ = try store.create(name: "Interrupted", icon: .emoji("⛔"), body: "must not activate")
                throw TestError.assertion("expected injected interruption")
            } catch CommandStore.StoreError.injectedFailure(.beforeActivation) {
                // Expected: the finalized orphan is not reachable from state.json.
            }
            store.setFaultPointForTesting(nil)

            try expect(try store.activeRevisionIDForTesting() == priorRevision)
            try expect(try store.get(slug: stable.slug)?.id == stable.id)
            try expect(try store.get(slug: "interrupted") == nil)
        }
    }

    await test("A0 rejects a corrupt new revision without mutating reads, then recovers on mutation") {
        try await withCustodyStore { store, root in
            let original = try store.create(name: "Recoverable", icon: .emoji("🛟"), body: "body-v1")
            guard let priorRevision = try store.activeRevisionIDForTesting() else {
                throw TestError.assertion("baseline revision missing")
            }

            var revisionTwo = original
            revisionTwo.body = "body-v2"
            _ = try store.update(revisionTwo)
            guard let corruptRevision = try store.activeRevisionIDForTesting() else {
                throw TestError.assertion("new revision missing")
            }
            try expect(corruptRevision != priorRevision)
            try store.corruptActiveBodyForTesting(commandID: original.id)

            let reopened = CommandStore(storageRoot: root)
            let stateBeforeRead = try reopened.stateDataForTesting()
            let recovered = try reopened.get(slug: original.slug)
            try expect(recovered?.body == "body-v1", "corrupt revision was accepted instead of rejected")
            try expect(try reopened.stateDataForTesting() == stateBeforeRead,
                       "a read repaired the active pointer")
            try expect(try reopened.activeRevisionIDForTesting() == corruptRevision,
                       "a read changed the active revision")

            guard let recovered else {
                throw TestError.assertion("prior valid revision was not readable")
            }
            try reopened.setKeySlot(slug: recovered.slug, slot: recovered.keySlot)
            try expect(try reopened.activeRevisionIDForTesting() != corruptRevision,
                       "command-state mutation did not repair the corrupt active revision")
            try expect(try reopened.get(slug: recovered.slug)?.body == "body-v1")
        }
    }

    await test("A0 never promotes an unactivated orphan revision during recovery") {
        try await withCustodyStore { store, root in
            let active = try store.create(name: "Active", icon: .emoji("✅"), body: "active-body")
            guard let activeRevision = try store.activeRevisionIDForTesting() else {
                throw TestError.assertion("active revision missing")
            }

            // This creates a fully hashed revision directory but deliberately
            // stops before the atomic state-pointer activation.
            store.setFaultPointForTesting(.beforeActivation)
            do {
                _ = try store.create(name: "Orphan", icon: .emoji("👻"), body: "must-stay-unactivated")
                throw TestError.assertion("expected injected interruption")
            } catch CommandStore.StoreError.injectedFailure(.beforeActivation) {
                // Expected.
            }
            store.setFaultPointForTesting(nil)
            try expect(try store.activeRevisionIDForTesting() == activeRevision)

            try store.corruptActiveBodyForTesting(commandID: active.id)
            let reopened = CommandStore(storageRoot: root)
            do {
                _ = try reopened.list()
                throw TestError.assertion("recovery promoted an unactivated orphan revision")
            } catch CommandStore.StoreError.corruptRevision {
                // With no activated prior revision, the only safe result is a
                // fail-closed error; an orphan must never become authoritative.
            }
            try expect(try reopened.activeRevisionIDForTesting() == activeRevision)
        }
    }

    await test("A0 failed migration leaves the legacy source byte-identical and retryable") {
        try await withCustodyStore { store, _ in
            var fixture = CommandStore.currentLegacyProductionFixture
            guard let executeIndex = fixture.firstIndex(where: { $0.slug == "execute" }) else {
                throw TestError.assertion("fixture missing Execute")
            }
            fixture[executeIndex].body = "failed-migration-rollback\r\nexact"
            try store.installLegacyFixtureForTesting(fixture)
            let before = try store.legacyBodyDataForTesting(slug: "execute")

            let readableLegacy = try store.list()
            store.setFaultPointForTesting(.beforeRevisionFinalize)
            do {
                try activateCustodyForTesting(store, commands: readableLegacy)
                throw TestError.assertion("expected injected migration failure")
            } catch CommandStore.StoreError.injectedFailure(.beforeRevisionFinalize) {
                // Expected: no active pointer and no legacy mutation.
            }
            store.setFaultPointForTesting(nil)

            try expect(try store.stateDataForTesting() == nil, "failed migration activated a revision")
            try expect(try store.legacyBodyDataForTesting(slug: "execute") == before)
            try expect(try store.list().first(where: { $0.slug == "execute" })?.body == "failed-migration-rollback\r\nexact")
        }
    }

    await test("A0 stops fail-closed for an ambiguous legacy identity") {
        try await withCustodyStore { store, _ in
            var fixture = CommandStore.currentLegacyProductionFixture
            var duplicate = fixture[0]
            duplicate.name = "Duplicate legacy identity"
            fixture.append(duplicate)
            try store.installLegacyFixtureForTesting(fixture)

            do {
                _ = try store.list()
                throw TestError.assertion("ambiguous legacy identity was migrated")
            } catch CommandStore.StoreError.legacyIdentityAmbiguous {
                // Expected: no guess, no state activation.
            }
            try expect(try store.stateDataForTesting() == nil)
        }
    }
}

private struct EffectiveCommandState: Equatable {
    var slug: String
    var name: String
    var icon: CommandStore.Icon
    var color: CommandStore.NotionColor?
    var keySlot: Int?
    var lastUsedAt: Date?
    var body: String

    init(_ command: CommandStore.Command) {
        slug = command.slug
        name = command.name
        icon = command.icon
        color = command.color
        keySlot = command.keySlot
        lastUsedAt = command.lastUsedAt
        body = command.body
    }
}

private func effectiveState(_ commands: [CommandStore.Command]) -> [EffectiveCommandState] {
    commands
        .map(EffectiveCommandState.init)
        .sorted { $0.slug < $1.slug }
}

/// Enter the migration boundary through a no-op favorite assignment, preserving
/// the effective command state while exercising the same requested mutation
/// path used by real command edits.
private func activateCustodyForTesting(
    _ store: CommandStore,
    commands: [CommandStore.Command]
) throws {
    guard let command = commands.first else {
        throw TestError.assertion("fixture has no command to reaffirm for migration")
    }
    try store.setKeySlot(slug: command.slug, slot: command.keySlot)
}

private func matchesProductDefault(
    _ command: CommandStore.Command,
    _ productDefault: CommandStore.ProductDefault
) -> Bool {
    command.slug == productDefault.slug
        && command.name == productDefault.name
        && command.icon == productDefault.icon
        && command.color == productDefault.color
        && command.body == productDefault.body
}

private struct LegacyFixtureEntry: Codable {
    var slug: String
    var name: String
    var icon: CommandStore.Icon
    var color: CommandStore.NotionColor?
    var keySlot: Int?
    var lastUsedAt: Date?
}

private func withCustodyStore(
    _ body: (CommandStore, URL) async throws -> Void
) async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory
        .appendingPathComponent("CommandCustody-A0-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try await body(CommandStore(storageRoot: root), root)
}

private func custodyTree(root: URL) throws -> [String: Data] {
    let custodyRoot = root.appendingPathComponent("custody", isDirectory: true)
    let fm = FileManager.default
    let enumerator = fm.enumerator(
        at: custodyRoot,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    )
    var result: [String: Data] = [:]
    while let url = enumerator?.nextObject() as? URL {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { continue }
        let relative = url.path.replacingOccurrences(of: custodyRoot.path + "/", with: "")
        result[relative] = try Data(contentsOf: url)
    }
    return result
}

private func legacyTree(root: URL) throws -> [String: Data] {
    let fm = FileManager.default
    let custodyRoot = root.appendingPathComponent("custody", isDirectory: true).standardizedFileURL.path
    let enumerator = fm.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    )
    var result: [String: Data] = [:]
    while let url = enumerator?.nextObject() as? URL {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { continue }
        let path = url.standardizedFileURL.path
        guard path != custodyRoot, !path.hasPrefix(custodyRoot + "/") else { continue }
        let relative = path.replacingOccurrences(of: root.standardizedFileURL.path + "/", with: "")
        result[relative] = try Data(contentsOf: url)
    }
    return result
}

private func assertRestrictivePermissions(root: URL) throws {
    let custodyRoot = root.appendingPathComponent("custody", isDirectory: true)
    let fm = FileManager.default
    let enumerator = fm.enumerator(
        at: custodyRoot,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: []
    )
    var urls = [custodyRoot]
    while let url = enumerator?.nextObject() as? URL { urls.append(url) }
    for url in urls {
        let attributes = try fm.attributesOfItem(atPath: url.path)
        guard let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue else {
            throw TestError.assertion("missing permissions for \(url.path)")
        }
        try expect((mode & 0o077) == 0, "custody path is group/world-readable: \(url.path)")
    }
}
