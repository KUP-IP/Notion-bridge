// CommandSearchCreateTests.swift — C1 / GitHub #140
//
// Search creation is explicit. Return never writes. Duplicates and sensitive
// paths are assessed before Save. Edit deep-links resolve by immutable ID.

import Foundation
import TheBridgeLib

func runCommandSearchCreateTests() async {
    print("\n[Command Search create C1 / #140]")

    await test("C1 ordinary Return does not create a command") {
        try expect(CommandSearchCreate.returnCreatesCommand == false)
    }

    await test("C1 empty or failed search text still requires an explicit name") {
        let empty = CommandSearchCreate.assess(
            draft: CommandCreateDraft(name: "  ", body: "no match for xyz"),
            existing: [],
            sensitivePaths: []
        )
        try expect(!empty.canProposeSave)
        let fromQuery = CommandSearchCreate.draft(fromSearchText: "ship the palette")
        try expect(fromQuery.name == "ship the palette")
        try expect(fromQuery.body.isEmpty, "single-line search fills name only")
    }

    await test("C1 exact slug and name duplicates are actionable") {
        let existing = [
            CommandStore.Command(id: "id-alpha", slug: "alpha", name: "Alpha", icon: .emoji("a"), body: "body-a")
        ]
        let slugHit = CommandSearchCreate.assess(
            draft: CommandCreateDraft(name: "Alpha", body: "other"),
            existing: existing,
            sensitivePaths: []
        )
        try expect(slugHit.duplicates.contains(.exactSlug("alpha")))
        try expect(!slugHit.canProposeSave)
        let nameHit = CommandSearchCreate.assess(
            draft: CommandCreateDraft(name: "ALPHA", body: "other"),
            existing: existing,
            sensitivePaths: []
        )
        try expect(!nameHit.duplicates.isEmpty)
        try expect(!nameHit.canProposeSave)
    }

    await test("C1 multiline search text becomes name plus body") {
        let draft = CommandSearchCreate.draft(fromSearchText: "Ship palette\nkeep the body")
        try expect(draft.name == "Ship palette")
        try expect(draft.body == "keep the body")
    }

    await test("C1 single-line search truncates the name to 80 and leaves body empty") {
        let long = String(repeating: "n", count: 90)
        let draft = CommandSearchCreate.draft(fromSearchText: long)
        try expect(draft.name == String(repeating: "n", count: 80))
        try expect(draft.body.isEmpty)
        let assessed = CommandSearchCreate.assess(
            draft: draft,
            existing: [],
            sensitivePaths: []
        )
        try expect(assessed.canProposeSave)
    }

    await test("C1 near-duplicate names are flagged without blocking the draft") {
        let existing = [
            CommandStore.Command(id: "id-close", slug: "close-agent", name: "Close Agent", icon: .emoji("c"), body: "x")
        ]
        let near = CommandSearchCreate.assess(
            draft: CommandCreateDraft(name: "Close Agnt", body: "y"),
            existing: existing,
            sensitivePaths: []
        )
        try expect(near.canProposeSave)
        try expect(near.duplicates.contains(.nearName("close-agent")))
    }

    await test("C1 sensitive path tokens surface a warning and do not enter the assessment as a save") {
        let assessed = CommandSearchCreate.assess(
            draft: CommandCreateDraft(name: "Keys", body: "read ~/.ssh/id_ed25519 then continue"),
            existing: [],
            sensitivePaths: ["~/.ssh", "~/.aws"]
        )
        try expect(assessed.sensitiveHits.contains("~/.ssh"))
        try expect(assessed.draft.sensitive)
        try expect(assessed.canProposeSave)
        try expect(assessed.requiresConfirmation)
    }

    await test("C1 duplicate copies the body and does not delete the source") {
        try await withTempHomeC1 { _ in
            try CommandStore.shared.resetForTesting()
            let source = try CommandStore.shared.create(
                name: "Source", icon: .emoji("s"), body: "keep-this-body", keySlot: 2)
            let copy = CommandSearchCreate.duplicateBody(
                of: source,
                existingNames: [source.name]
            )
            let created = try CommandStore.shared.create(
                name: copy.name, icon: .emoji("c"), body: copy.body)
            try expect(created.body == "keep-this-body")
            try expect(try CommandStore.shared.get(slug: source.slug)?.body == "keep-this-body")
            try expect(try CommandStore.shared.get(slug: source.slug)?.keySlot == 2)
            try expect(created.slug != source.slug)
            try expect(created.id != source.id)
        }
    }

    await test("C1 removing a favorite does not delete the command") {
        try await withTempHomeC1 { _ in
            try CommandStore.shared.resetForTesting()
            let created = try CommandStore.shared.create(
                name: "Keep", icon: .emoji("k"), body: "alive", keySlot: 4)
            try CommandStore.shared.setKeySlot(slug: created.slug, slot: nil)
            try expect(try CommandStore.shared.get(slug: created.slug)?.body == "alive")
            try expect(try CommandStore.shared.get(slug: created.slug)?.keySlot == nil)
        }
    }

    await test("C1 Settings deep link selects by immutable ID not a renamed slug") {
        let commands = [
            CommandStore.Command(id: "bridge.command.user.keep", slug: "old-name", name: "New Name", icon: .emoji("n"), body: "x")
        ]
        let anchor = CommandSettingsDeepLink.anchor(commandID: "bridge.command.user.keep")
        try expect(CommandSettingsDeepLink.commandID(fromAnchor: anchor) == "bridge.command.user.keep")
        try expect(CommandSettingsDeepLink.slug(forID: "bridge.command.user.keep", in: commands) == "old-name")
        try expect(CommandSettingsDeepLink.commandID(fromAnchor: "job:123") == nil)
    }

    await test("C1 sensitive body never becomes a Search subtitle") {
        let subtitle = CommandSearchCreate.searchSubtitle(
            slot: 3,
            body: "cat ~/.ssh/id_ed25519",
            sensitivePaths: ["~/.ssh"]
        )
        try expect(subtitle == "slot 3 · Sensitive")
        try expect(!subtitle!.contains("id_ed25519"))
        try expect(CommandSearchCreate.shouldSuppressBodyPreview(
            body: "cat ~/.ssh/id_ed25519",
            sensitivePaths: ["~/.ssh"]
        ))
        let quiet = CommandSearchCreate.searchSubtitle(
            slot: nil,
            body: "echo hello",
            sensitivePaths: ["~/.ssh"]
        )
        try expect(quiet == nil)
    }

    await test("C1 ViewModel ordinary commit does not create") {
        try await withTempHomeC1 { _ in
            try CommandStore.shared.resetForTesting()
            let before = try CommandStore.shared.list().count
            await MainActor.run {
                let vm = CommandBridgeViewModel(
                    store: CommandStore.shared,
                    recents: CommandBridgeRecents(cap: 1)
                )
                vm.queryDidChange("no such command xyzzy-c1")
                vm.commitSelected()
            }
            try expect(try CommandStore.shared.list().count == before)
        }
    }

    await test("C1 ViewModel Save after explicit create writes and survives update") {
        try await withTempHomeC1 { _ in
            try CommandStore.shared.resetForTesting()
            let created = await MainActor.run { () -> CommandStore.Command? in
                let vm = CommandBridgeViewModel(
                    store: CommandStore.shared,
                    recents: CommandBridgeRecents(cap: 1)
                )
                vm.queryDidChange("Ship palette")
                vm.beginCreateFromQuery()
                vm.createDraft.body = "do the thing"
                vm.refreshCreateAssessment()
                return vm.confirmCreate()
            }
            try expect(created?.name == "Ship palette")
            try expect(created?.body == "do the thing")
            guard var live = created else {
                throw TestError.assertion("expected created command")
            }
            live.body = "updated body"
            let saved = try CommandStore.shared.update(live)
            try expect(saved.id == live.id)
            try expect(try CommandStore.shared.get(slug: saved.slug)?.body == "updated body")
        }
    }
}

private func withTempHomeC1(_ body: (URL) async throws -> Void) async throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory
        .appendingPathComponent("CommandSearchCreate-test-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(tmp)
    defer {
        BridgePaths.overrideHomeForTesting(nil)
        try? fm.removeItem(at: tmp)
    }
    try await body(tmp)
}
