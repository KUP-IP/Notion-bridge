// CommandProductPublication.swift — GitHub #140 D0
//
// Developer-mode publication of a local command override as a product change.
// Ordinary updates stay Git-free. No commit, push, or branch work happens
// without an explicit approval. Favorite layout and usage history never ship.

import Foundation

public enum CommandProposalState: String, Equatable, Sendable, Codable {
    case draft
    case ready
    case published
    case merged
    case shipped
    case reconciled
}

public struct CommandProductDiff: Equatable, Sendable {
    public var commandID: String
    public var slug: String
    public var name: String
    public var baseBody: String?
    public var localBody: String
    public var intendedProductOutcome: String

    public init(
        commandID: String,
        slug: String,
        name: String,
        baseBody: String? = nil,
        localBody: String,
        intendedProductOutcome: String
    ) {
        self.commandID = commandID
        self.slug = slug
        self.name = name
        self.baseBody = baseBody
        self.localBody = localBody
        self.intendedProductOutcome = intendedProductOutcome
    }

    public var outboundBody: String { localBody }

    public var includesFavoriteLayout: Bool { false }
    public var includesUsageHistory: Bool { false }
}

public struct CommandPrivacyFinding: Equatable, Sendable {
    public var token: String
    public var requiresAcknowledgement: Bool

    public init(token: String, requiresAcknowledgement: Bool = true) {
        self.token = token
        self.requiresAcknowledgement = requiresAcknowledgement
    }
}

public struct CommandPublicationApprovals: Equatable, Sendable {
    public var issueAssociated: Bool
    public var branchSelected: Bool
    public var commitApproved: Bool
    public var pushApproved: Bool
    public var privacyAcknowledged: Bool

    public init(
        issueAssociated: Bool = false,
        branchSelected: Bool = false,
        commitApproved: Bool = false,
        pushApproved: Bool = false,
        privacyAcknowledged: Bool = false
    ) {
        self.issueAssociated = issueAssociated
        self.branchSelected = branchSelected
        self.commitApproved = commitApproved
        self.pushApproved = pushApproved
        self.privacyAcknowledged = privacyAcknowledged
    }
}

public struct CommandProductProposal: Equatable, Sendable {
    public var diff: CommandProductDiff
    public var issueNumber: Int?
    public var branch: String?
    public var findings: [CommandPrivacyFinding]
    public var approvals: CommandPublicationApprovals
    public var state: CommandProposalState
    public var recordedGitActions: [String]

    public init(
        diff: CommandProductDiff,
        issueNumber: Int? = nil,
        branch: String? = nil,
        findings: [CommandPrivacyFinding] = [],
        approvals: CommandPublicationApprovals = CommandPublicationApprovals(),
        state: CommandProposalState = .draft,
        recordedGitActions: [String] = []
    ) {
        self.diff = diff
        self.issueNumber = issueNumber
        self.branch = branch
        self.findings = findings
        self.approvals = approvals
        self.state = state
        self.recordedGitActions = recordedGitActions
    }
}

public enum CommandProductPublication {
    public static func developerControlsVisible(developerMode: Bool) -> Bool {
        developerMode
    }

    public static func canUseOfflineUpdatesWithoutGit(hasRepo: Bool) -> Bool {
        true
    }

    public static func repositoryIdentity(repoRoot: String?) -> String? {
        guard let repoRoot else { return nil }
        let trimmed = repoRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func productRepoIdentity(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        repositoryIdentity(repoRoot: environment["BRIDGE_PRODUCT_REPO"])
    }

    /// Real Git stays opt-in. Absent this flag, Settings copies a patch and
    /// never commits or pushes.
    public static func gitExecutionEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["BRIDGE_COMMAND_PUBLICATION_GIT"] == "1"
    }

    public static func reviewablePatch(_ proposal: CommandProductProposal) -> String {
        let issue = proposal.issueNumber.map(String.init) ?? "unassociated"
        let branch = proposal.branch ?? "unset"
        return [
            "command-id: \(proposal.diff.commandID)",
            "slug: \(proposal.diff.slug)",
            "name: \(proposal.diff.name)",
            "issue: \(issue)",
            "branch: \(branch)",
            "outcome: \(proposal.diff.intendedProductOutcome)",
            "---",
            proposal.diff.outboundBody,
        ].joined(separator: "\n")
    }

    public static func scanPrivacy(
        body: String,
        sensitivePaths: [String],
        extraSecrets: [String] = []
    ) -> [CommandPrivacyFinding] {
        var findings: [CommandPrivacyFinding] = []
        var seen = Set<String>()
        let haystack = body.lowercased()
        for path in sensitivePaths {
            let needle = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty, haystack.contains(needle.lowercased()) else { continue }
            if seen.insert(path).inserted {
                findings.append(CommandPrivacyFinding(token: path))
            }
        }
        for secret in extraSecrets where body.contains(secret) {
            if seen.insert(secret).inserted {
                findings.append(CommandPrivacyFinding(token: secret))
            }
        }
        let markers = ["-----BEGIN ", "sk_live_", "sk_test_", "ghp_", "AKIA"]
        for marker in markers where body.contains(marker) {
            if seen.insert(marker).inserted {
                findings.append(CommandPrivacyFinding(token: marker))
            }
        }
        return findings
    }

    public static func draft(
        command: CommandStore.Command,
        baseBody: String?,
        intendedProductOutcome: String,
        sensitivePaths: [String]
    ) -> CommandProductProposal {
        let diff = CommandProductDiff(
            commandID: command.id,
            slug: command.slug,
            name: command.name,
            baseBody: baseBody,
            localBody: command.body,
            intendedProductOutcome: intendedProductOutcome
        )
        return CommandProductProposal(
            diff: diff,
            findings: scanPrivacy(body: command.body, sensitivePaths: sensitivePaths),
            state: .draft
        )
    }

    public static func privacyBlocks(_ proposal: CommandProductProposal) -> Bool {
        !proposal.findings.isEmpty && !proposal.approvals.privacyAcknowledged
    }

    public static func canBecomeReady(_ proposal: CommandProductProposal, developerMode: Bool) -> Bool {
        guard developerMode else { return false }
        guard !proposal.diff.intendedProductOutcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard proposal.issueNumber != nil, let branch = proposal.branch, !branch.isEmpty else {
            return false
        }
        return !privacyBlocks(proposal)
    }

    public static func markReady(_ proposal: CommandProductProposal, developerMode: Bool) -> CommandProductProposal? {
        guard canBecomeReady(proposal, developerMode: developerMode) else { return nil }
        var next = proposal
        next.state = .ready
        return next
    }

    /// Git never runs unless every approval for that action is explicit.
    public static func intendedGitAction(
        _ proposal: CommandProductProposal,
        developerMode: Bool,
        hasRepo: Bool,
        repoIdentity: String?
    ) -> String? {
        guard developerMode else { return nil }
        guard hasRepo, repositoryIdentity(repoRoot: repoIdentity) != nil else { return nil }
        guard proposal.state == .ready else { return nil }
        if proposal.approvals.commitApproved && proposal.approvals.pushApproved {
            return "commit-and-push"
        }
        if proposal.approvals.commitApproved {
            return "commit"
        }
        return nil
    }

    public static func applyApprovedGit(
        _ proposal: CommandProductProposal,
        developerMode: Bool,
        hasRepo: Bool,
        repoIdentity: String?,
        execute: (String) -> Bool
    ) -> CommandProductProposal {
        var next = proposal
        guard let action = intendedGitAction(
            proposal,
            developerMode: developerMode,
            hasRepo: hasRepo,
            repoIdentity: repoIdentity
        ) else { return next }
        guard execute(action) else { return next }
        next.recordedGitActions.append(action)
        if action == "commit-and-push" || (action == "commit" && proposal.approvals.pushApproved) {
            next.state = .published
        }
        return next
    }

    public static func simulateShippedDefault(
        _ proposal: CommandProductProposal,
        localStillPresent: Bool
    ) -> CommandProductProposal {
        var next = proposal
        if proposal.state == .published || proposal.state == .merged {
            next.state = .shipped
        }
        _ = localStillPresent
        return next
    }

    public static func reconcileAfterShipped(
        _ proposal: CommandProductProposal,
        localMatchesShipped: Bool
    ) -> CommandProductProposal {
        var next = proposal
        guard proposal.state == .shipped, localMatchesShipped else { return next }
        next.state = .reconciled
        return next
    }
}
