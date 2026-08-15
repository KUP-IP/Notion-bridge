// CommandCalibrateReport.swift — GitHub #140 B1
//
// Bounded whole-product Calibrate report. Skills and standing orders own
// the procedure; this type is the checkable shape. It never writes
// AGENT_FEEDBACK.md and never treats AI LOG telemetry as an issue ledger.

import Foundation

public struct CommandCalibrateReport: Equatable, Sendable {
    public static let maxSprintOutcomes = 5

    public struct Identity: Equatable, Sendable {
        public var sourceSHA: String
        public var sourceBranch: String
        public var sourceDirty: Bool
        public var installedSHA: String?
        public var installedPath: String?
        public var identitiesMatch: Bool

        public init(
            sourceSHA: String,
            sourceBranch: String,
            sourceDirty: Bool,
            installedSHA: String?,
            installedPath: String?,
            identitiesMatch: Bool
        ) {
            self.sourceSHA = sourceSHA
            self.sourceBranch = sourceBranch
            self.sourceDirty = sourceDirty
            self.installedSHA = installedSHA
            self.installedPath = installedPath
            self.identitiesMatch = identitiesMatch
        }
    }

    public struct GitHubState: Equatable, Sendable {
        public var openIssues: [String]
        public var openPullRequests: [String]
        public var ciConclusion: String?

        public init(openIssues: [String], openPullRequests: [String], ciConclusion: String?) {
            self.openIssues = openIssues
            self.openPullRequests = openPullRequests
            self.ciConclusion = ciConclusion
        }
    }

    public struct Workspace: Equatable, Sendable {
        public var branches: [String]
        public var worktrees: [String]

        public init(branches: [String], worktrees: [String]) {
            self.branches = branches
            self.worktrees = worktrees
        }
    }

    public struct ReleasePosture: Equatable, Sendable {
        public var installAllowed: Bool
        public var reason: String

        public init(installAllowed: Bool, reason: String) {
            self.installAllowed = installAllowed
            self.reason = reason
        }
    }

    public var identity: Identity
    public var github: GitHubState
    public var workspace: Workspace
    public var release: ReleasePosture
    public var coherenceNotes: [String]
    public var sprintOutcomes: [String]

    public init(
        identity: Identity,
        github: GitHubState,
        workspace: Workspace,
        release: ReleasePosture,
        coherenceNotes: [String],
        sprintOutcomes: [String]
    ) {
        self.identity = identity
        self.github = github
        self.workspace = workspace
        self.release = release
        self.coherenceNotes = coherenceNotes
        self.sprintOutcomes = sprintOutcomes
    }

    public var isBounded: Bool {
        sprintOutcomes.count <= Self.maxSprintOutcomes
    }

    /// Render a short operator-facing report. AI LOG stays telemetry-only;
    /// actionable leftovers belong in GitHub Issues.
    public func render() -> String {
        var lines: [String] = [
            "# Calibrate",
            "",
            "## Identity",
            "- source: \(identity.sourceBranch) \(identity.sourceSHA) dirty=\(identity.sourceDirty)",
            "- installed: \(identity.installedSHA ?? "unproven") \(identity.installedPath ?? "")",
            "- source==installed: \(identity.identitiesMatch)",
            "",
            "## GitHub",
            "- issues: \(github.openIssues.isEmpty ? "none" : github.openIssues.joined(separator: ", "))",
            "- pull requests: \(github.openPullRequests.isEmpty ? "none" : github.openPullRequests.joined(separator: ", "))",
            "- CI: \(github.ciConclusion ?? "unproven")",
            "",
            "## Workspace",
            "- branches: \(workspace.branches.joined(separator: ", "))",
            "- worktrees: \(workspace.worktrees.joined(separator: ", "))",
            "",
            "## Install / release",
            "- allowed: \(release.installAllowed) — \(release.reason)",
            "",
            "## Coherence",
        ]
        if coherenceNotes.isEmpty {
            lines.append("- none")
        } else {
            lines.append(contentsOf: coherenceNotes.map { "- \($0)" })
        }
        lines.append("")
        lines.append("## Sprint outcomes (max \(Self.maxSprintOutcomes))")
        if sprintOutcomes.isEmpty {
            lines.append("- none")
        } else {
            lines.append(contentsOf: sprintOutcomes.prefix(Self.maxSprintOutcomes).map { "- \($0)" })
        }
        return lines.joined(separator: "\n")
    }
}

public enum CommandCalibrateError: Error, Equatable {
    case tooManySprintOutcomes(Int)
}

public enum CommandCalibrate {
    public static func make(
        identity: CommandCalibrateReport.Identity,
        github: CommandCalibrateReport.GitHubState,
        workspace: CommandCalibrateReport.Workspace,
        release: CommandCalibrateReport.ReleasePosture,
        coherenceNotes: [String],
        sprintOutcomes: [String]
    ) throws -> CommandCalibrateReport {
        guard sprintOutcomes.count <= CommandCalibrateReport.maxSprintOutcomes else {
            throw CommandCalibrateError.tooManySprintOutcomes(sprintOutcomes.count)
        }
        return CommandCalibrateReport(
            identity: identity,
            github: github,
            workspace: workspace,
            release: release,
            coherenceNotes: coherenceNotes,
            sprintOutcomes: sprintOutcomes
        )
    }
}

public enum CommandFeedbackLedger {
    /// Instructions that would still send agents to write AGENT_FEEDBACK.md.
    /// Historical provenance mentions are allowed; these writer verbs are not.
    public static let activeWriterPatterns: [NSRegularExpression] = {
        let sources = [
            #"append to [^.\n]*AGENT_FEEDBACK\.md"#,
            #"log in AGENT_FEEDBACK\.md"#,
            #"filed AGENT_FEEDBACK\.md"#,
            #"write(?:s|n)? to [^.\n]*AGENT_FEEDBACK\.md"#,
            #"file_append[^\n]*AGENT_FEEDBACK\.md"#,
        ]
        return sources.map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }()

    public static func activeWriterHits(in text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return activeWriterPatterns.compactMap { regex in
            guard let match = regex.firstMatch(in: text, options: [], range: range),
                  let swiftRange = Range(match.range, in: text)
            else { return nil }
            return String(text[swiftRange])
        }
    }
}
