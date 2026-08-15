// CommandProductCatalog.swift — repository-backed built-in command defaults.
//
// GitHub #140 B0. Bodies are directional goal conditions (Mode, Use when,
// Aim, Boundary, Exit). Repeatable procedures live in skills and standing
// orders, not here. Local overrides are never written from this catalog.

import Foundation

public enum CommandProductCatalog {
    public static let maxWordCount = 120

    public static let requiredSectionLabels = [
        "Mode:",
        "Use when:",
        "Aim:",
        "Boundary:",
        "Exit:",
    ]

    /// Tokens that would pull a protocol, tool, path, retry loop, or patch
    /// history into a command body. Keep this list explicit so a wording
    /// change cannot silently reintroduce a banned class.
    static let prohibitedPatterns: [NSRegularExpression] = {
        let sources = [
            #"\b[a-z][a-z0-9]*_[a-z0-9_]+\b"#,
            #"\bfetch_skill\b"#,
            #"\bbridge_initialize\b"#,
            #"\bexecutor\b"#,
            #"\bAGENT_FEEDBACK\b"#,
            #"\bPKT-\d+\b"#,
            #"\bretr(?:y|ies|ied|ying)\b"#,
            #"~/Library"#,
            #"/Users/"#,
            #"Application Support"#,
            #"\bWave \d+\b"#,
        ]
        return sources.map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }()

    static let domainExclusivePatterns: [NSRegularExpression] = {
        let sources = [
            #"\bgit(?:hub)?\b"#,
            #"\bswift\b"#,
            #"\bnotion\b"#,
            #"\bkeepr\b"#,
            #"\bmcp\b"#,
            #"\bcommit\b"#,
            #"\bpull request\b"#,
            #"\bwebhook\b"#,
        ]
        return sources.map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }()

    public struct ValidationIssue: Equatable, Sendable {
        public var slug: String
        public var reason: String

        public init(slug: String, reason: String) {
            self.slug = slug
            self.reason = reason
        }
    }

    struct Seed: Sendable {
        var name: String
        var icon: CommandStore.Icon
        var color: CommandStore.NotionColor?
        var body: String
    }

    static let seeds: [Seed] = [
        Seed(name: "Initiate", icon: .emoji("🧭"), color: .purple, body: initiateBody),
        Seed(name: "Propose", icon: .emoji("🧩"), color: .blue, body: proposeBody),
        Seed(name: "Scope Cut", icon: .emoji("✂️"), color: .gray, body: scopeCutBody),
        Seed(name: "Validate", icon: .emoji("🔎"), color: .yellow, body: validateBody),
        Seed(name: "Execute", icon: .emoji("⚡"), color: .orange, body: executeBody),
        Seed(name: "Review", icon: .emoji("🧪"), color: .red, body: reviewBody),
        Seed(name: "Refocus", icon: .emoji("🎯"), color: .blue, body: refocusBody),
        Seed(name: "Open Loops", icon: .emoji("📋"), color: .green, body: openLoopsBody),
        Seed(name: "Close Agent", icon: .emoji("✅"), color: .green, body: closeAgentBody),
        Seed(name: "Hand Off", icon: .emoji("📨"), color: .brown, body: handOffBody),
    ]

    public static var defaults: [CommandStore.ProductDefault] {
        seeds.enumerated().map { index, seed in
            let slug = CommandStore.slugify(seed.name)
            let slot = index == 9 ? 0 : index + 1
            return CommandStore.ProductDefault(
                id: CommandStore.legacyBuiltInIdentityMap[slug]!,
                slug: slug,
                name: seed.name,
                icon: seed.icon,
                color: seed.color,
                initialKeySlot: slot,
                body: seed.body,
                schemaVersion: CommandStore.ProductDefault.currentCatalogSchemaVersion,
                behaviorVersion: CommandStore.ProductDefault.currentCatalogBehaviorVersion,
                requiredCapabilities: []
            )
        }
    }

    public static func wordCount(_ body: String) -> Int {
        body.split { $0.isWhitespace || $0.isNewline }.count
    }

    public static func validate(_ item: CommandStore.ProductDefault) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let body = item.body
        let count = wordCount(body)
        if count > maxWordCount {
            issues.append(.init(slug: item.slug, reason: "body has \(count) words; max is \(maxWordCount)"))
        }
        for label in requiredSectionLabels {
            if !hasSection(label, in: body) {
                issues.append(.init(slug: item.slug, reason: "missing \(label) section"))
            }
        }
        for regex in prohibitedPatterns {
            if let match = firstMatch(regex, in: body) {
                issues.append(.init(slug: item.slug, reason: "prohibited content: \(match)"))
            }
        }
        for regex in domainExclusivePatterns {
            if let match = firstMatch(regex, in: body) {
                issues.append(.init(slug: item.slug, reason: "domain-exclusive content: \(match)"))
            }
        }
        return issues
    }

    public static func validateAll(
        _ items: [CommandStore.ProductDefault] = defaults
    ) -> [ValidationIssue] {
        items.flatMap(validate)
    }

    private static func hasSection(_ label: String, in body: String) -> Bool {
        body.split(whereSeparator: \.isNewline).contains { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix(label)
        }
    }

    private static func firstMatch(_ regex: NSRegularExpression, in body: String) -> String? {
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        guard let match = regex.firstMatch(in: body, options: [], range: range),
              let swiftRange = Range(match.range, in: body)
        else { return nil }
        return String(body[swiftRange])
    }

    private static let initiateBody = """
    # Initiate

    Mode: arrival. Orient before work moves.

    Use when: the session is starting, the target is unclear, or current context is not yet grounded.

    Aim: a shared picture of where we are and what the next move should be.

    Boundary: do not implement, plan a delivery sprint, or invent a target. Ask at most one clarifying question.

    Exit: the operator fires another command, names a concrete target, or explicitly asks to move.
    """

    private static let proposeBody = """
    # Propose

    Mode: shaping. Do not build yet.

    Use when: the objective exists but the contract is still open, including both making and thinking work.

    Aim: restate the objective, name the smallest coherent scope, surface real forks, and show the cost of being wrong.

    Boundary: do not start material work or choose a fork the operator should choose.

    Exit: a proposed contract is on the table, or the operator cuts scope or asks to proceed.
    """

    private static let scopeCutBody = """
    # Scope Cut

    Mode: trim. Separate what is required from what is only adjacent.

    Use when: the proposed work is wider than the next verifiable slice, in code or in knowledge work.

    Aim: return IN / OUT / LATER with the reason each boundary exists.

    Boundary: do not add work back in to keep a larger plan intact. Prefer a smaller contract that can be checked.

    Exit: the operator accepts the cut, restores an item with a reason, or asks for a new proposal.
    """

    private static let validateBody = """
    # Validate

    Mode: hardening. Check whether the plan is ready to run.

    Use when: a contract exists and the next step would be material work, across any domain.

    Aim: confirm source of truth, dependencies, gates, tests or checks, and likely failure modes.

    Boundary: do not begin delivery. If more than one domain is in play, say so and stop for routing.

    Exit: the plan is ready, blocked on a named gap, or returned for a smaller cut.
    """

    private static let executeBody = """
    # Execute

    Mode: delivery. A contract is approved and material work may begin.

    Use when: the operator has approved the plan for code, writing, research, or other shipping work.

    Aim: do the approved work, prove it with evidence, and stop at the contract.

    Boundary: do not expand scope, skip the check that defines done, or continue past a failed proof.

    Exit: done is evidenced, a named blocker stops the work, or the operator calls a review.
    """

    private static let reviewBody = """
    # Review

    Mode: checkpoint. Verify before release, deletion, or any irreversible action.

    Use when: work claims to be done and a gate, publish, or irreversible step is next.

    Aim: lead with findings and evidence. Confirm checks, live state, external gates, and any operator decision still required.

    Boundary: do not merge, publish, delete, or otherwise make the step irreversible without an explicit go.

    Exit: the operator accepts, requests a fix, or withholds the irreversible step.
    """

    private static let refocusBody = """
    # Refocus

    Mode: realignment. Re-anchor the session.

    Use when: the thread has drifted, context is stale, or the next move is no longer obvious.

    Aim: restate the original objective, current evidence, what changed, and the next smallest move. Flag drift plainly.

    Boundary: do not start a new plan or resume delivery until the original aim is restated.

    Exit: the operator confirms the re-anchor, names a new aim, or fires the next command.
    """

    private static let openLoopsBody = """
    # Open Loops

    Mode: inventory. List every unresolved thread from the current session or project.

    Use when: work has accumulated loose ends in shipping, research, or personal systems.

    Aim: separate loops that need action, loops that need a decision, and loops that can close with evidence already present.

    Boundary: do not close a loop by guessing, and do not start new work from the inventory.

    Exit: the list is complete and each loop has a next owner, or the operator picks one loop to handle.
    """

    private static let closeAgentBody = """
    # Close Agent

    Mode: closeout. Preserve what should survive this session.

    Use when: the session is ending and shipped work, evidence, or learning must outlive the chat.

    Aim: summarize shipped work, evidence, unresolved decisions, friction, and reusable learning.

    Boundary: write durable notes only where the active protocol requires them. Do not invent a second backlog.

    Exit: the surviving record is written, leftovers are named, and the session can stop.
    """

    private static let handOffBody = """
    # Hand Off

    Mode: transfer. Prepare the next agent to continue without rediscovery.

    Use when: work continues in another session, person, or thread.

    Aim: include objective, current state, artifacts touched, exact evidence, blockers, and the next best action.

    Boundary: do not run closeout from this command, and do not resume delivery in this turn.

    Exit: a successor can start from the brief alone, or the operator stays and names the next command.
    """
}
