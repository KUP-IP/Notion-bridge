// CommandGitHubFirstFeedbackTests.swift — B1 / GitHub #140
//
// GitHub Issues is the only actionable development-feedback ledger.
// Calibrate is a bounded whole-product report. AI LOG stays telemetry.

import Foundation
import TheBridgeLib

func runCommandGitHubFirstFeedbackTests() async {
    print("\n[Command GitHub-first feedback B1 / #140]")

    await test("B1 Calibrate report is bounded and names identity, GitHub, workspace, install") {
        let report = try CommandCalibrate.make(
            identity: .init(
                sourceSHA: "2be6542d6d7ed25ff2fd0b6a03e9329149830982",
                sourceBranch: "main",
                sourceDirty: false,
                installedSHA: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                installedPath: "/Applications/The Bridge.app",
                identitiesMatch: false
            ),
            github: .init(
                openIssues: ["#140"],
                openPullRequests: [],
                ciConclusion: "success"
            ),
            workspace: .init(
                branches: ["main"],
                worktrees: ["/Users/keepup/Developer/the-bridge"]
            ),
            release: .init(
                installAllowed: false,
                reason: "promoted install remains a G0 gate"
            ),
            coherenceNotes: ["A1 and B0 are on the integration line"],
            sprintOutcomes: [
                "A0 custody on main",
                "A1 reconciliation on main",
                "B0 directional catalog on main",
                "B1 GitHub-first feedback",
                "C0 Search favorites next",
            ]
        )
        try expect(report.isBounded)
        let text = report.render()
        try expect(text.contains("# Calibrate"))
        try expect(text.contains("## Identity"))
        try expect(text.contains("## GitHub"))
        try expect(text.contains("#140"))
        try expect(text.contains("## Workspace"))
        try expect(text.contains("## Install / release"))
        try expect(text.contains("## Coherence"))
        try expect(text.contains("## Sprint outcomes"))
        try expect(!text.contains("AGENT_FEEDBACK.md"))
        try expect(!report.identity.identitiesMatch)
        try expect(!report.release.installAllowed)
    }

    await test("B1 Calibrate refuses more than five sprint outcomes") {
        var threw = false
        do {
            _ = try CommandCalibrate.make(
                identity: .init(
                    sourceSHA: "deadbeef",
                    sourceBranch: "main",
                    sourceDirty: false,
                    installedSHA: nil,
                    installedPath: nil,
                    identitiesMatch: false
                ),
                github: .init(openIssues: [], openPullRequests: [], ciConclusion: nil),
                workspace: .init(branches: ["main"], worktrees: []),
                release: .init(installAllowed: false, reason: "unproven"),
                coherenceNotes: [],
                sprintOutcomes: ["1", "2", "3", "4", "5", "6"]
            )
        } catch CommandCalibrateError.tooManySprintOutcomes(let count) {
            threw = true
            try expect(count == 6)
        }
        try expect(threw)
    }

    await test("B1 close-agent bundled skill no longer appends AGENT_FEEDBACK.md") {
        let root = try CommandFeedbackScan.repoRoot()
        let closeAgent = root
            .appendingPathComponent("packet-runner/skills/close-agent-v3.2.0.md")
        try expect(
            FileManager.default.fileExists(atPath: closeAgent.path),
            "missing close-agent at \(closeAgent.path) root=\(root.path)"
        )
        let text = try String(contentsOf: closeAgent, encoding: .utf8)
        try expect(
            CommandFeedbackLedger.activeWriterHits(in: text).isEmpty,
            "writer hits in close-agent"
        )
        try expect(
            text.range(of: "search-before-create", options: .caseInsensitive) != nil,
            "close-agent missing search-before-create; bytes=\(text.count) root=\(root.path)"
        )
        try expect(
            text.range(of: "GitHub Issues", options: .caseInsensitive) != nil,
            "close-agent missing GitHub Issues ledger"
        )
        try expect(!text.contains("append to `~/Developer/the-bridge/AGENT_FEEDBACK.md`"))
    }

    await test("B1 tracked instructions do not write AGENT_FEEDBACK.md") {
        let root = try CommandFeedbackScan.repoRoot()
        let hits = try CommandFeedbackScan.activeWriterFiles(under: root)
        try expect(
            hits.isEmpty,
            hits.map { "\($0.path): \($0.match)" }.joined(separator: "; ")
        )
    }

    await test("B1 Close Agent command still forbids a second backlog") {
        let close = CommandStore.defaultProductCatalog.first { $0.slug == "close-agent" }!
        try expect(close.body.contains("Do not invent a second backlog"))
        try expect(CommandProductCatalog.validate(close).isEmpty)
    }
}

private enum CommandFeedbackScan {
    static func repoRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<8 {
            url.deleteLastPathComponent()
            let marker = url.appendingPathComponent("Package.swift")
            let closeAgent = url.appendingPathComponent("packet-runner/skills/close-agent-v3.2.0.md")
            if FileManager.default.fileExists(atPath: marker.path),
               FileManager.default.fileExists(atPath: closeAgent.path) {
                return url
            }
        }
        throw TestError.assertion("could not locate repo root from \(#filePath)")
    }

    static func activeWriterFiles(under root: URL) throws -> [(path: String, match: String)] {
        let skipNames: Set<String> = [
            "CommandGitHubFirstFeedbackTests.swift",
            "CommandIntegrationE0Tests.swift",
            "CommandCalibrateReport.swift",
            "CHANGELOG.md",
            "test-floor-gate-history.md",
        ]
        var hits: [(path: String, match: String)] = []
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let item = enumerator?.nextObject() as? URL {
            let name = item.lastPathComponent
            if skipNames.contains(name) { continue }
            if item.path.contains("/.build/") { continue }
            guard item.pathExtension == "md" || item.pathExtension == "swift" else { continue }
            let text = (try? String(contentsOf: item, encoding: .utf8)) ?? ""
            if let match = CommandFeedbackLedger.activeWriterHits(in: text).first {
                let relative = item.path.replacingOccurrences(of: root.path + "/", with: "")
                hits.append((relative, match))
            }
        }
        return hits
    }
}
