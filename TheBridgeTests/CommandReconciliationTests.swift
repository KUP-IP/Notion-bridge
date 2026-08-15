// CommandReconciliationTests.swift — A1 / GitHub #140
//
// Product-default reconciliation: unmodified defaults advance, local
// overrides stay byte-for-byte, incoming stays inspectable, and only
// schema/capability evidence closes the execution gate.

import AppKit
import Foundation
import TheBridgeLib

func runCommandReconciliationTests() async {
    print("\n[Command reconciliation A1 / #140]")

    await test("A1 unmodified defaults advance when the catalog body changes") {
        try await withReconciliationStore { store, root in
            try store.seedIfEmpty()
            let original = try requireCommand(store, slug: "initiate")
            var incomingCatalog = CommandStore.defaultProductCatalog
            incomingCatalog[0].body = "incoming-unmodified-body"
            let incomingStore = CommandStore(storageRoot: root, productDefaults: incomingCatalog)
            let advanced = try requireCommand(incomingStore, slug: "initiate")
            try expect(advanced.body == "incoming-unmodified-body")
            try expect(advanced.id == original.id)
            let state = try requireReconciliation(incomingStore, slug: "initiate")
            try expect(state.local == nil)
            try expect(state.incoming.body == "incoming-unmodified-body")
            try expect(state.classification == .current)
            try expect(state.updateAvailable == false)
            try expect(state.executionGate == .open)
        }
    }

    await test("A1 modified defaults retain the local body byte-for-byte") {
        try await withReconciliationStore { store, root in
            try store.seedIfEmpty()
            var local = try requireCommand(store, slug: "initiate")
            local.body = "operator-override-body\nexact-bytes"
            _ = try store.update(local)
            let retained = try requireCommand(store, slug: "initiate")
            try expect(retained.body == "operator-override-body\nexact-bytes")

            var incomingCatalog = CommandStore.defaultProductCatalog
            incomingCatalog[0].body = "incoming-catalog-body"
            let incomingStore = CommandStore(storageRoot: root, productDefaults: incomingCatalog)
            let afterUpdate = try requireCommand(incomingStore, slug: "initiate")
            try expect(afterUpdate.body == "operator-override-body\nexact-bytes",
                       "catalog replacement overwrote the local override")
            let state = try requireReconciliation(incomingStore, slug: "initiate")
            try expect(state.local?.body == "operator-override-body\nexact-bytes")
            try expect(state.incoming.body == "incoming-catalog-body")
            try expect(state.base?.body == CommandStore.defaultProductCatalog[0].body)
            try expect(state.updateAvailable == true)
        }
    }

    await test("A1 incoming defaults remain inspectable separately from local") {
        try await withReconciliationStore { store, root in
            try store.seedIfEmpty()
            var local = try requireCommand(store, slug: "propose")
            local.body = "local-propose"
            _ = try store.update(local)
            var incomingCatalog = CommandStore.defaultProductCatalog
            incomingCatalog[1].body = "incoming-propose"
            let incomingStore = CommandStore(storageRoot: root, productDefaults: incomingCatalog)
            let state = try requireReconciliation(incomingStore, slug: "propose")
            try expect(state.local?.body == "local-propose")
            try expect(state.incoming.body == "incoming-propose")
            try expect(state.local?.body != state.incoming.body)
            try expect(try incomingStore.get(slug: "propose")?.body == "local-propose")
        }
    }

    await test("A1 has no automatic body-merge path") {
        try await withReconciliationStore { store, root in
            try store.seedIfEmpty()
            var local = try requireCommand(store, slug: "review")
            local.body = "LOCAL-ONLY"
            local.name = "Review Local"
            _ = try store.update(local)
            var incomingCatalog = CommandStore.defaultProductCatalog
            incomingCatalog[5].body = "INCOMING-ONLY"
            let incomingStore = CommandStore(storageRoot: root, productDefaults: incomingCatalog)
            let effective = try requireCommand(incomingStore, slug: "review")
            try expect(effective.body == "LOCAL-ONLY")
            try expect(!effective.body.contains("INCOMING-ONLY"))
            let copied = try incomingStore.applyReconciliation(
                slug: "review",
                action: .copySelectedChange(source: .incoming, field: .body)
            )
            try expect(copied.local?.body == "INCOMING-ONLY",
                       "copy-selected-change must copy the whole body field")
            try expect(copied.local?.name == "Review Local",
                       "copying body must not rewrite other local fields")
            try expect(copied.local?.body != "LOCAL-ONLY\nINCOMING-ONLY")
            try expect(copied.local?.body != "LOCAL-ONLYINCOMING-ONLY")
        }
    }

    await test("A1 wording-only incoming changes classify as editorial and stay executable") {
        try await withReconciliationStore { store, root in
            try store.seedIfEmpty()
            var local = try requireCommand(store, slug: "initiate")
            local.body = "custom-initiate"
            _ = try store.update(local)
            var incomingCatalog = CommandStore.defaultProductCatalog
            incomingCatalog[0].body = "wording-only incoming"
            let incomingStore = CommandStore(storageRoot: root, productDefaults: incomingCatalog)
            let state = try requireReconciliation(incomingStore, slug: "initiate")
            try expect(state.classification == .editorial)
            try expect(state.executionGate == .open)
            try expect(try incomingStore.executionGate(slug: "initiate") == .open)
        }
    }

    await test("A1 behaviorVersion changes classify as behavioral without closing the gate") {
        try await withReconciliationStore { store, root in
            try store.seedIfEmpty()
            var local = try requireCommand(store, slug: "initiate")
            local.body = "custom-initiate"
            _ = try store.update(local)
            var incomingCatalog = CommandStore.defaultProductCatalog
            incomingCatalog[0].behaviorVersion = CommandStore.ProductDefault.currentCatalogBehaviorVersion + 1
            incomingCatalog[0].body = "behavioral incoming"
            let incomingStore = CommandStore(storageRoot: root, productDefaults: incomingCatalog)
            let state = try requireReconciliation(incomingStore, slug: "initiate")
            try expect(state.classification == .behavioral)
            try expect(state.executionGate == .open)
            try expect(try incomingStore.get(slug: "initiate")?.body == "custom-initiate")
        }
    }

    await test("A1 schema/capability evidence classifies compatibility-required and gates fire") {
        try await withReconciliationStore { store, root in
            try store.seedIfEmpty()
            var local = try requireCommand(store, slug: "initiate")
            local.body = "custom-initiate"
            _ = try store.update(local)
            var incomingCatalog = CommandStore.defaultProductCatalog
            incomingCatalog[0].schemaVersion = 2
            incomingCatalog[0].requiredCapabilities = ["commands.reconciliation.v2"]
            incomingCatalog[0].body = "incompatible incoming"
            let incomingStore = CommandStore(storageRoot: root, productDefaults: incomingCatalog)
            let state = try requireReconciliation(incomingStore, slug: "initiate")
            try expect(state.classification == .compatibilityRequired)
            try expect(state.updateAvailable == true)
            guard case .compatibilityRequired(let evidence) = state.executionGate else {
                throw TestError.assertion("expected compatibility-required gate")
            }
            try expect(evidence.contains("schemaVersion 1→2"))
            try expect(evidence.contains("commands.reconciliation.v2"))

            let cb = InMemoryClipboard(initial: "prior")
            let inserter = RecordingTextInserter()
            let coord = CommandPaletteCoordinator(
                provider: StaticCommandDescriptorProvider(),
                manager: CommandsManager(fetcher: { _ in "{}" })
            )
            let ctrl = await CommandBridgeController(
                hotkey: .productionDefault,
                clipboard: cb,
                inserter: inserter,
                coordinator: coord,
                store: incomingStore
            )
            await ctrl.fireSlug("initiate")
            try expect(await ctrl.lastInsertedText == nil,
                       "compatibility-required must not insert")
            try expect(cb.writeCount == 0)
            try expect(cb.readString() == "prior")
        }
    }

    await test("A1 restore/adopt/copy-selected-change are explicit and reversible") {
        try await withReconciliationStore { store, root in
            try store.seedIfEmpty()
            let originalBody = try requireCommand(store, slug: "initiate").body
            var local = try requireCommand(store, slug: "initiate")
            local.body = "override-v1"
            local.name = "Initiate Local"
            _ = try store.update(local)
            var incomingCatalog = CommandStore.defaultProductCatalog
            incomingCatalog[0].body = "incoming-v2"
            incomingCatalog[0].name = "Initiate Incoming"
            let incomingStore = CommandStore(storageRoot: root, productDefaults: incomingCatalog)

            let before = try requireReconciliation(incomingStore, slug: "initiate")
            try expect(before.local?.body == "override-v1")

            let restored = try incomingStore.applyReconciliation(slug: "initiate", action: .restoreBase)
            try expect(restored.local?.body == originalBody || restored.local == nil)
            let afterRestore = try requireCommand(incomingStore, slug: "initiate")
            try expect(afterRestore.body == originalBody)
            _ = try incomingStore.update(local)
            try expect(try requireCommand(incomingStore, slug: "initiate").body == "override-v1")

            let copied = try incomingStore.applyReconciliation(
                slug: "initiate",
                action: .copySelectedChange(source: .incoming, field: .name)
            )
            try expect(copied.local?.name == "Initiate Incoming")
            try expect(copied.local?.body == "override-v1")
            let reversedName = try incomingStore.applyReconciliation(
                slug: "initiate",
                action: .copySelectedChange(source: .base, field: .name)
            )
            try expect(reversedName.local?.name == "Initiate")
            try expect(reversedName.local?.body == "override-v1")

            let adopted = try incomingStore.applyReconciliation(slug: "initiate", action: .adoptIncoming)
            try expect(adopted.local == nil)
            try expect(try requireCommand(incomingStore, slug: "initiate").body == "incoming-v2")
            _ = try incomingStore.update(local)
            try expect(try requireCommand(incomingStore, slug: "initiate").body == "override-v1")
        }
    }

    await test("A1 replays an A0 legacy override without rewriting it") {
        try await withReconciliationStore { store, root in
            var fixture = CommandStore.currentLegacyProductionFixture
            guard let executeIndex = fixture.firstIndex(where: { $0.slug == "execute" }) else {
                throw TestError.assertion("fixture missing Execute")
            }
            fixture[executeIndex].body = "a0-legacy-override\r\nexact"
            try store.installLegacyFixtureForTesting(fixture)
            try store.setKeySlot(slug: "execute", slot: fixture[executeIndex].keySlot)
            try expect(try requireCommand(store, slug: "execute").body == "a0-legacy-override\r\nexact")

            var incomingCatalog = CommandStore.defaultProductCatalog
            incomingCatalog[4].body = "a1-incoming-execute"
            let incomingStore = CommandStore(storageRoot: root, productDefaults: incomingCatalog)
            let state = try requireReconciliation(incomingStore, slug: "execute")
            try expect(state.local?.body == "a0-legacy-override\r\nexact")
            try expect(state.incoming.body == "a1-incoming-execute")
            try expect(state.classification == .editorial)
            try expect(state.executionGate == .open)
            try expect(try requireCommand(incomingStore, slug: "execute").body
                       == "a0-legacy-override\r\nexact")
        }
    }
}

private func withReconciliationStore(
    _ body: (CommandStore, URL) async throws -> Void
) async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory
        .appendingPathComponent("CommandReconciliation-A1-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try await body(CommandStore(storageRoot: root), root)
}

private func requireCommand(_ store: CommandStore, slug: String) throws -> CommandStore.Command {
    guard let command = try store.get(slug: slug) else {
        throw TestError.assertion("missing command \(slug)")
    }
    return command
}

private func requireReconciliation(
    _ store: CommandStore,
    slug: String
) throws -> CommandStore.CommandReconciliation {
    guard let state = try store.reconciliation(slug: slug) else {
        throw TestError.assertion("missing reconciliation for \(slug)")
    }
    return state
}
