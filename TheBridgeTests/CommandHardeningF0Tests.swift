// CommandHardeningF0Tests.swift — F0 / GitHub #140
//
// Adversarial rehearsal of the integrated command system. No promoted install.

import Foundation
import TheBridgeLib

func runCommandHardeningF0Tests() async {
    print("\n[Command hardening F0 / #140]")

    await test("F0 two forward catalog updates keep the local override") {
        try await withHardeningStore { store, root in
            try store.seedIfEmpty()
            var local = try requireCommandF0(store, slug: "initiate")
            local.body = "f0-override-v1\nexact"
            _ = try store.update(local)
            var first = CommandStore.defaultProductCatalog
            first[0].body = "incoming-forward-1"
            let afterFirst = CommandStore(storageRoot: root, productDefaults: first)
            try expect(try requireCommandF0(afterFirst, slug: "initiate").body == "f0-override-v1\nexact")
            var second = first
            second[0].body = "incoming-forward-2"
            let afterSecond = CommandStore(storageRoot: root, productDefaults: second)
            let kept = try requireCommandF0(afterSecond, slug: "initiate")
            try expect(kept.body == "f0-override-v1\nexact")
            let rec = try requireReconciliationF0(afterSecond, slug: "initiate")
            try expect(rec.local?.body == "f0-override-v1\nexact")
            try expect(rec.incoming.body == "incoming-forward-2")
        }
    }

    await test("F0 interrupted write and corrupt revision do not lose the prior body") {
        try await withHardeningStore { store, root in
            let stable = try store.create(name: "F0 Stable", icon: .emoji("s"), body: "f0-prior-valid")
            store.setFaultPointForTesting(.beforeActivation)
            var threwInterrupt = false
            do {
                _ = try store.create(name: "F0 Interrupted", icon: .emoji("x"), body: "must not activate")
            } catch CommandStore.StoreError.injectedFailure(.beforeActivation) {
                threwInterrupt = true
            }
            store.setFaultPointForTesting(nil)
            try expect(threwInterrupt)
            try expect(try store.get(slug: stable.slug)?.body == "f0-prior-valid")
            try expect(try store.get(slug: "f0-interrupted") == nil)

            var revisionTwo = stable
            revisionTwo.body = "f0-should-not-win"
            _ = try store.update(revisionTwo)
            try store.corruptActiveBodyForTesting(commandID: stable.id)
            let reopened = CommandStore(storageRoot: root)
            try expect(try reopened.get(slug: stable.slug)?.body == "f0-prior-valid")
            try reopened.setKeySlot(slug: stable.slug, slot: nil)
            try expect(try reopened.get(slug: stable.slug)?.body == "f0-prior-valid")
        }
    }

    await test("F0 tombstone, favorite undo, and Search collision stay coherent") {
        try await withHardeningStore { store, _ in
            try store.seedIfEmpty()
            let before = try requireCommandF0(store, slug: "review")
            try store.delete(slug: "review")
            try expect(try store.get(slug: "review") == nil)
            try store.seedIfEmpty()
            try expect(try store.get(slug: "review") == nil, "hidden default resurrected")
            try expect(before.body.isEmpty == false)

            var session = FavoriteLayoutSession(current: FavoriteLayout(slots: [1: "initiate", 2: "execute"]))
            _ = session.chooseSlot(1, for: "execute")
            let replaced = session.resolveReplace()
            try expect(replaced?.slug(in: 1) == "execute")
            try expect(replaced?.slot(of: "initiate") == nil)
            let undone = session.undo()
            try expect(undone?.slug(in: 1) == "initiate")
            try expect(undone?.slug(in: 2) == "execute")

            let existing = try store.list()
            let collision = CommandSearchCreate.assess(
                draft: CommandCreateDraft(name: "Initiate", body: "other"),
                existing: existing,
                sensitivePaths: []
            )
            try expect(!collision.canProposeSave)
            try expect(CommandSearchCreate.returnCreatesCommand == false)
        }
    }

    await test("F0 compatibility-required is a true positive; editorial stays executable") {
        try await withHardeningStore { store, root in
            try store.seedIfEmpty()
            var local = try requireCommandF0(store, slug: "initiate")
            local.body = "f0-local"
            _ = try store.update(local)

            var editorial = CommandStore.defaultProductCatalog
            editorial[0].body = "wording-only"
            let editorialStore = CommandStore(storageRoot: root, productDefaults: editorial)
            let editorialState = try requireReconciliationF0(editorialStore, slug: "initiate")
            try expect(editorialState.classification == .editorial)
            try expect(editorialState.executionGate == .open)
            try expect(try editorialStore.get(slug: "initiate")?.body == "f0-local")

            var incompatible = editorial
            incompatible[0].schemaVersion = 2
            incompatible[0].requiredCapabilities = ["commands.hardening.v2"]
            let gated = CommandStore(storageRoot: root, productDefaults: incompatible)
            let gatedState = try requireReconciliationF0(gated, slug: "initiate")
            try expect(gatedState.classification == .compatibilityRequired)
            guard case .compatibilityRequired(let evidence) = gatedState.executionGate else {
                throw TestError.assertion("expected compatibility-required gate")
            }
            try expect(evidence.contains("schemaVersion"))
            try expect(try gated.get(slug: "initiate")?.body == "f0-local")
        }
    }

    await test("F0 publication privacy and Calibrate still refuse silent ship") {
        var proposal = CommandProductPublication.draft(
            command: CommandStore.Command(
                id: "bridge.command.user.f0",
                slug: "f0-ship",
                name: "F0 Ship",
                icon: .emoji("f"),
                body: "read ~/.ssh/id_ed25519"
            ),
            baseBody: "product default",
            intendedProductOutcome: "Harden publication",
            sensitivePaths: ["~/.ssh"]
        )
        proposal.issueNumber = 140
        proposal.branch = "feat/issue-140-f0-hardening"
        try expect(CommandProductPublication.developerControlsVisible(developerMode: false) == false)
        try expect(CommandProductPublication.privacyBlocks(proposal))
        try expect(CommandProductPublication.canBecomeReady(proposal, developerMode: true) == false)
        proposal.approvals.privacyAcknowledged = true
        try expect(CommandProductPublication.canBecomeReady(proposal, developerMode: true))
        try expect(CommandProductPublication.intendedGitAction(
            proposal, developerMode: false, hasRepo: true, repoIdentity: "/tmp/repo"
        ) == nil)

        let report = try CommandCalibrate.make(
            identity: .init(
                sourceSHA: "5bf864b86e017f3d89510f818ede8d41ee5ebda1",
                sourceBranch: "main",
                sourceDirty: false,
                installedSHA: nil,
                installedPath: nil,
                identitiesMatch: false
            ),
            github: .init(openIssues: ["#140"], openPullRequests: [], ciConclusion: "success"),
            workspace: .init(branches: ["main"], worktrees: []),
            release: .init(installAllowed: false, reason: "F0 may sign a candidate; G0 owns promoted install"),
            coherenceNotes: ["E0 is on the integration line"],
            sprintOutcomes: ["E0", "F0 hardening"]
        )
        try expect(report.isBounded)
        try expect(!report.release.installAllowed)
        try expect(CommandFeedbackLedger.activeWriterHits(in: report.render()).isEmpty)
    }
}

private func withHardeningStore(
    _ body: (CommandStore, URL) async throws -> Void
) async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory
        .appendingPathComponent("CommandHardening-F0-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    try await body(CommandStore(storageRoot: root), root)
}

private func requireCommandF0(_ store: CommandStore, slug: String) throws -> CommandStore.Command {
    guard let command = try store.get(slug: slug) else {
        throw TestError.assertion("missing command \(slug)")
    }
    return command
}

private func requireReconciliationF0(
    _ store: CommandStore,
    slug: String
) throws -> CommandStore.CommandReconciliation {
    guard let state = try store.reconciliation(slug: slug) else {
        throw TestError.assertion("missing reconciliation for \(slug)")
    }
    return state
}
