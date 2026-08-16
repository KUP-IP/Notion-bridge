// CommandIntegrationE0Tests.swift — E0 / GitHub #140
//
// A0–D0 coexist on one SHA. Standard mode stays Git-free. Favorite layout
// never enters a publication patch. Promoted install is still G0.

import Foundation
import TheBridgeLib

func runCommandIntegrationE0Tests() async {
    print("\n[Command integration E0 / #140]")

    await test("E0 standard mode, Search Return, and publication stay uncoupled") {
        try expect(CommandProductPublication.developerControlsVisible(developerMode: false) == false)
        try expect(CommandSearchCreate.returnCreatesCommand == false)
        try expect(CommandProductPublication.canUseOfflineUpdatesWithoutGit(hasRepo: false))
        let draft = CommandProductPublication.draft(
            command: CommandStore.Command(
                id: "bridge.command.user.e0",
                slug: "e0-ship",
                name: "E0 Ship",
                icon: .emoji("e"),
                keySlot: 3,
                lastUsedAt: Date(),
                body: "operator override"
            ),
            baseBody: "product default",
            intendedProductOutcome: "Keep the override local until Ready",
            sensitivePaths: []
        )
        try expect(draft.diff.includesFavoriteLayout == false)
        try expect(draft.diff.includesUsageHistory == false)
        let patch = CommandProductPublication.reviewablePatch(draft)
        try expect(patch.contains("operator override"))
        try expect(!patch.contains("keySlot"))
        try expect(!patch.contains("lastUsedAt"))
    }

    await test("E0 local override, favorite slot, and catalog default coexist") {
        try await withTempHomeE0 { _ in
            try CommandStore.shared.resetForTesting()
            try CommandStore.shared.seedIfEmpty()
            var local = try CommandStore.shared.get(slug: "initiate")
            try expect(local != nil, "seeded catalog missing initiate")
            local!.body = "e0-local-override"
            _ = try CommandStore.shared.update(local!)
            try CommandStore.shared.setKeySlot(slug: "initiate", slot: 4)
            let rec = try CommandStore.shared.reconciliation(slug: "initiate")
            try expect(rec?.local?.body == "e0-local-override")
            let current = try CommandStore.shared.get(slug: "initiate")
            try expect(current?.body == "e0-local-override")
            try expect(current?.keySlot == 4)
            let draft = CommandProductPublication.draft(
                command: current!,
                baseBody: rec?.base?.body,
                intendedProductOutcome: "Keep the override local",
                sensitivePaths: []
            )
            try expect(draft.diff.includesFavoriteLayout == false)
            try expect(!CommandProductPublication.reviewablePatch(draft).contains("keySlot"))
            let close = CommandStore.defaultProductCatalog.first { $0.slug == "close-agent" }
            try expect(close != nil)
            try expect(CommandProductCatalog.validate(close!).isEmpty)
        }
    }

    await test("E0 live fixture store migrates without rewriting the override") {
        try await withTempHomeE0 { tmp in
            let root = tmp.appendingPathComponent("commands-e0-fixture", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let store = CommandStore(storageRoot: root)
            var fixture = CommandStore.currentLegacyProductionFixture
            guard let executeIndex = fixture.firstIndex(where: { $0.slug == "execute" }) else {
                throw TestError.assertion("fixture missing Execute")
            }
            fixture[executeIndex].body = "e0-legacy-override\r\nexact"
            try store.installLegacyFixtureForTesting(fixture)
            try store.setKeySlot(slug: "execute", slot: fixture[executeIndex].keySlot)
            try expect(try store.get(slug: "execute")?.body == "e0-legacy-override\r\nexact")
            let state = try store.reconciliation(slug: "execute")
            try expect(state?.local?.body == "e0-legacy-override\r\nexact")
            try expect(try store.get(slug: "execute")?.keySlot == fixture[executeIndex].keySlot)
        }
    }

    await test("E0 Calibrate still refuses promoted install") {
        let report = try CommandCalibrate.make(
            identity: .init(
                sourceSHA: "34a9ce010f75d7b475d4b4535a0f0d4be7fc0f2e",
                sourceBranch: "main",
                sourceDirty: false,
                installedSHA: nil,
                installedPath: nil,
                identitiesMatch: false
            ),
            github: .init(openIssues: ["#140"], openPullRequests: [], ciConclusion: "success"),
            workspace: .init(branches: ["main"], worktrees: []),
            release: .init(installAllowed: false, reason: "E0 is a review candidate; G0 owns promoted install"),
            coherenceNotes: ["A0–D0 are on the integration line"],
            sprintOutcomes: ["A0", "A1", "B0", "B1", "C0"]
        )
        try expect(!report.release.installAllowed)
        try expect(!report.render().contains("AGENT_FEEDBACK.md"))
    }
}

private func withTempHomeE0(_ body: (URL) async throws -> Void) async throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory
        .appendingPathComponent("CommandIntegrationE0-test-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(tmp)
    defer {
        BridgePaths.overrideHomeForTesting(nil)
        try? fm.removeItem(at: tmp)
    }
    try await body(tmp)
}
