// CommandDirectionalCatalogTests.swift — B0 / GitHub #140
//
// Repository-backed directional defaults: five-part bodies, length and
// prohibited-content validation, coding and knowledge-work neutrality,
// and A0/A1 override preservation.

import Foundation
import TheBridgeLib

func runCommandDirectionalCatalogTests() async {
    print("\n[Command directional catalog B0 / #140]")

    await test("B0 live built-ins have stable repository identities") {
        let catalog = CommandStore.defaultProductCatalog
        try expect(catalog.count == 10)
        try expect(CommandStore.legacyBuiltInIdentityMap.count == 10)
        let expectedSlugs = [
            "initiate", "propose", "scope-cut", "validate", "execute",
            "review", "refocus", "open-loops", "close-agent", "hand-off",
        ]
        try expect(catalog.map(\.slug) == expectedSlugs)
        for item in catalog {
            try expect(CommandStore.legacyBuiltInIdentityMap[item.slug] == item.id)
            try expect(item.id.hasPrefix("bridge.command.builtin."))
            try expect(item.schemaVersion == 1)
            try expect(item.behaviorVersion == 2)
            try expect(item.requiredCapabilities.isEmpty)
        }
        try expect(catalog[0].initialKeySlot == 1)
        try expect(catalog[9].initialKeySlot == 0)
    }

    await test("B0 every default meets the directional content contract") {
        let issues = CommandProductCatalog.validateAll()
        try expect(issues.isEmpty, issues.map { "\($0.slug): \($0.reason)" }.joined(separator: "; "))
        for item in CommandStore.defaultProductCatalog {
            try expect(CommandProductCatalog.wordCount(item.body) <= 120)
            for label in CommandProductCatalog.requiredSectionLabels {
                try expect(
                    item.body.split(whereSeparator: \.isNewline).contains {
                        $0.trimmingCharacters(in: .whitespaces).hasPrefix(label)
                    },
                    "\(item.slug) missing \(label)"
                )
            }
        }
    }

    await test("B0 defaults stay useful for coding and knowledge-work tasks") {
        let codingTask = "Ship the failing payment test without expanding scope."
        let knowledgeTask = "Decide whether to keep the weekly review ritual."
        for item in CommandStore.defaultProductCatalog {
            try expect(!item.body.isEmpty)
            try expect(
                CommandProductCatalog.validate(item).isEmpty,
                "\(item.slug) is not domain-neutral"
            )
            // The body is a lens, not a procedure: both task types can use it.
            try expect(item.body.contains("Use when:"))
            _ = codingTask
            _ = knowledgeTask
        }
        let execute = CommandStore.defaultProductCatalog.first { $0.slug == "execute" }!
        try expect(execute.body.contains("code, writing, research, or other shipping work"))
        let openLoops = CommandStore.defaultProductCatalog.first { $0.slug == "open-loops" }!
        try expect(openLoops.body.contains("shipping, research, or personal systems"))
    }

    await test("B0 exact-name and ID lookup resolve the live palette") {
        try await withDirectionalStore { store, _ in
            try store.seedIfEmpty()
            let byName = try store.search("Initiate")
            try expect(byName.contains { $0.slug == "initiate" && $0.name == "Initiate" })
            let bySlug = try store.get(slug: "close-agent")
            try expect(bySlug?.id == "bridge.command.builtin.close-agent")
            let listed = try store.list()
            try expect(listed.contains { $0.id == "bridge.command.builtin.hand-off" && $0.slug == "hand-off" })
            try expect(listed.contains { $0.name == "Scope Cut" && $0.id == "bridge.command.builtin.scope-cut" })
        }
    }

    await test("B0 installed-store fixture keeps overrides while defaults stay repository-backed") {
        try await withDirectionalStore { store, root in
            try store.seedIfEmpty()
            var local = try requireDirectionalCommand(store, slug: "execute")
            local.body = "operator-execute-override\nexact-bytes"
            _ = try store.update(local)
            try expect(try requireDirectionalCommand(store, slug: "execute").body
                       == "operator-execute-override\nexact-bytes")

            let incoming = CommandStore(storageRoot: root)
            try expect(try requireDirectionalCommand(incoming, slug: "execute").body
                       == "operator-execute-override\nexact-bytes",
                       "B0 catalog rewrite overwrote a local override")
            try expect(try requireDirectionalCommand(incoming, slug: "initiate").body
                       == CommandStore.defaultProductCatalog[0].body)
            let issues = CommandProductCatalog.validateAll()
            try expect(issues.isEmpty)
            let state = try incoming.reconciliation(slug: "execute")
            try expect(state?.local?.body == "operator-execute-override\nexact-bytes")
            try expect(state?.incoming.body == CommandStore.defaultProductCatalog[4].body)
            try expect(state?.executionGate == .open)
        }
    }

    await test("B0 validation rejects tool IDs, paths, retries, and overlong bodies") {
        var item = CommandStore.defaultProductCatalog[0]
        item.body = """
        # Initiate
        Mode: arrival.
        Use when: starting.
        Aim: ground.
        Boundary: none.
        Exit: next.
        Run fetch_skill then retry ~/Library/Application Support/The Bridge.
        """
        let issues = CommandProductCatalog.validate(item)
        try expect(issues.contains { $0.reason.contains("prohibited") })

        item.body = (["word"] + Array(repeating: "padding", count: 120)).joined(separator: " ")
        let longIssues = CommandProductCatalog.validate(item)
        try expect(longIssues.contains { $0.reason.contains("words") })
    }
}

private func withDirectionalStore(
    _ body: (CommandStore, URL) async throws -> Void
) async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory
        .appendingPathComponent("CommandDirectional-B0-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try await body(CommandStore(storageRoot: root), root)
}

private func requireDirectionalCommand(
    _ store: CommandStore,
    slug: String
) throws -> CommandStore.Command {
    guard let command = try store.get(slug: slug) else {
        throw TestError.assertion("missing command \(slug)")
    }
    return command
}
