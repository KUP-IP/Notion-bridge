// CommandProductPublicationTests.swift — D0 / GitHub #140
//
// Developer publication is gated, reviewable, and never silent. Standard mode
// has no GitHub controls. Local command state stays until explicit reconcile.

import Foundation
import TheBridgeLib

func runCommandProductPublicationTests() async {
    print("\n[Command product publication D0 / #140]")

    await test("D0 standard mode hides GitHub and branch controls") {
        try expect(CommandProductPublication.developerControlsVisible(developerMode: false) == false)
        try expect(CommandProductPublication.developerControlsVisible(developerMode: true) == true)
        let draft = sampleDraft()
        try expect(CommandProductPublication.canBecomeReady(draft, developerMode: false) == false)
        try expect(CommandProductPublication.intendedGitAction(
            draft, developerMode: false, hasRepo: true, repoIdentity: "/tmp/repo"
        ) == nil)
    }

    await test("D0 offline updates remain available without a repo") {
        try expect(CommandProductPublication.canUseOfflineUpdatesWithoutGit(hasRepo: false))
        try expect(CommandProductPublication.canUseOfflineUpdatesWithoutGit(hasRepo: true))
        try expect(CommandProductPublication.repositoryIdentity(repoRoot: "  ") == nil)
        try expect(CommandProductPublication.repositoryIdentity(repoRoot: nil) == nil)
        try expect(CommandProductPublication.repositoryIdentity(repoRoot: "/Users/keepup/Developer/the-bridge") != nil)
    }

    await test("D0 privacy scan blocks secrets until acknowledged") {
        let hits = CommandProductPublication.scanPrivacy(
            body: "read ~/.ssh/id_ed25519 and sk_live_secret",
            sensitivePaths: ["~/.ssh"],
            extraSecrets: []
        )
        try expect(hits.contains(where: { $0.token == "~/.ssh" }))
        try expect(hits.contains(where: { $0.token == "sk_live_" }))
        var proposal = sampleDraft(body: "read ~/.ssh/id_ed25519")
        proposal.findings = hits.filter { $0.token == "~/.ssh" }
        proposal.issueNumber = 140
        proposal.branch = "feat/issue-140-d0-test"
        proposal.diff.intendedProductOutcome = "Ship a safer default"
        try expect(CommandProductPublication.privacyBlocks(proposal))
        try expect(CommandProductPublication.canBecomeReady(proposal, developerMode: true) == false)
        proposal.approvals.privacyAcknowledged = true
        try expect(CommandProductPublication.canBecomeReady(proposal, developerMode: true))
    }

    await test("D0 commit and push never run without explicit approval") {
        var proposal = readyProposal()
        var executed: [String] = []
        let silent = CommandProductPublication.applyApprovedGit(
            proposal,
            developerMode: true,
            hasRepo: true,
            repoIdentity: "/tmp/the-bridge",
            execute: { executed.append($0); return true }
        )
        try expect(executed.isEmpty)
        try expect(silent.state == .ready)
        try expect(silent.recordedGitActions.isEmpty)

        proposal.approvals.commitApproved = true
        let committed = CommandProductPublication.applyApprovedGit(
            proposal,
            developerMode: true,
            hasRepo: true,
            repoIdentity: "/tmp/the-bridge",
            execute: { executed.append($0); return true }
        )
        try expect(executed == ["commit"])
        try expect(committed.state == .ready)

        executed = []
        proposal.approvals.pushApproved = true
        let published = CommandProductPublication.applyApprovedGit(
            proposal,
            developerMode: true,
            hasRepo: true,
            repoIdentity: "/tmp/the-bridge",
            execute: { executed.append($0); return true }
        )
        try expect(executed == ["commit-and-push"])
        try expect(published.state == .published)
        try expect(published.recordedGitActions == ["commit-and-push"])
    }

    await test("D0 patch omits favorite layout and usage history") {
        let draft = sampleDraft()
        try expect(draft.diff.includesFavoriteLayout == false)
        try expect(draft.diff.includesUsageHistory == false)
        try expect(draft.diff.outboundBody == "local-body")
        try expect(!draft.diff.outboundBody.contains("keySlot"))
        let patch = CommandProductPublication.reviewablePatch(draft)
        try expect(patch.contains("local-body"))
        try expect(!patch.contains("keySlot"))
        try expect(!patch.contains("lastUsedAt"))
    }

    await test("D0 missing repo or Git flag refuses commit even with approvals") {
        var proposal = readyProposal()
        proposal.approvals.commitApproved = true
        proposal.approvals.pushApproved = true
        var executed: [String] = []
        let noRepo = CommandProductPublication.applyApprovedGit(
            proposal,
            developerMode: true,
            hasRepo: false,
            repoIdentity: nil,
            execute: { executed.append($0); return true }
        )
        try expect(executed.isEmpty)
        try expect(noRepo.state == .ready)
        try expect(CommandProductPublication.gitExecutionEnabled(environment: [:]) == false)
        try expect(CommandProductPublication.productRepoIdentity(environment: [:]) == nil)
        try expect(CommandProductPublication.gitExecutionEnabled(
            environment: ["BRIDGE_COMMAND_PUBLICATION_GIT": "1"]
        ))
        try expect(CommandProductPublication.productRepoIdentity(
            environment: ["BRIDGE_PRODUCT_REPO": "/tmp/the-bridge"]
        ) == "/tmp/the-bridge")
    }

    await test("D0 local override remains until shipped default is reconciled") {
        try await withTempHomeD0 { _ in
            try CommandStore.shared.resetForTesting()
            let created = try CommandStore.shared.create(
                name: "Local Ship", icon: .emoji("s"), body: "operator override")
            var proposal = CommandProductPublication.draft(
                command: created,
                baseBody: "product default",
                intendedProductOutcome: "Promote the override",
                sensitivePaths: []
            )
            proposal.issueNumber = 140
            proposal.branch = "feat/issue-140-d0-test"
            proposal.approvals = CommandPublicationApprovals(
                issueAssociated: true,
                branchSelected: true,
                commitApproved: true,
                pushApproved: true,
                privacyAcknowledged: true
            )
            proposal = CommandProductPublication.markReady(proposal, developerMode: true)!
            proposal = CommandProductPublication.applyApprovedGit(
                proposal,
                developerMode: true,
                hasRepo: true,
                repoIdentity: "/tmp/the-bridge",
                execute: { _ in true }
            )
            try expect(proposal.state == .published)
            try expect(try CommandStore.shared.get(slug: created.slug)?.body == "operator override")
            proposal = CommandProductPublication.simulateShippedDefault(
                proposal, localStillPresent: true)
            try expect(proposal.state == .shipped)
            try expect(try CommandStore.shared.get(slug: created.slug)?.body == "operator override")
            proposal = CommandProductPublication.reconcileAfterShipped(
                proposal, localMatchesShipped: true)
            try expect(proposal.state == .reconciled)
        }
    }
}

private func sampleDraft(body: String = "local-body") -> CommandProductProposal {
    CommandProductPublication.draft(
        command: CommandStore.Command(
            id: "bridge.command.user.local-ship",
            slug: "local-ship",
            name: "Local Ship",
            icon: .emoji("s"),
            body: body
        ),
        baseBody: "product default",
        intendedProductOutcome: "",
        sensitivePaths: ["~/.ssh"]
    )
}

private func readyProposal() -> CommandProductProposal {
    var proposal = sampleDraft()
    proposal.diff.intendedProductOutcome = "Promote the override"
    proposal.issueNumber = 140
    proposal.branch = "feat/issue-140-d0-test"
    proposal.findings = []
    proposal.approvals.issueAssociated = true
    proposal.approvals.branchSelected = true
    return CommandProductPublication.markReady(proposal, developerMode: true)!
}

private func withTempHomeD0(_ body: (URL) async throws -> Void) async throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory
        .appendingPathComponent("CommandProductPublication-test-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    BridgePaths.overrideHomeForTesting(tmp)
    defer {
        BridgePaths.overrideHomeForTesting(nil)
        try? fm.removeItem(at: tmp)
    }
    try await body(tmp)
}
