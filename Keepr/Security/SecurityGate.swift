// SecurityGate.swift – V1-03 4-Tier Security Enforcement
// KeeprBridge · Security

import Foundation
import MCP

// MARK: - Security Tier

/// The four security tiers for tool classification.
public enum SecurityTier: String, Sendable, CaseIterable, Codable {
    case green = "green"    // 🟢 Read-Only: execute immediately
    case yellow = "yellow"  // 🟡 Write-Auto: execute + post-log
    case orange = "orange"  // 🟠 Write-Confirm: pause + confirm
    case red = "red"        // 🔴 Destructive-Confirm: hard stop + confirm
}

// MARK: - Gate Decision

/// Result of a security gate evaluation.
public enum GateDecision: Sendable {
    case allow
    case reject(reason: String)
}

// MARK: - SecurityGate Actor

/// Enforces security policies on every tool call.
/// No tool can bypass this gate — it is not optional.
public actor SecurityGate {

    // MARK: Forbidden Paths

    private static let forbiddenPaths: [String] = [
        "~/.ssh",
        "~/.gnupg",
        "~/.aws",
        "~/.config/gcloud",
        ".env",
        "/System",
        "/Library"
    ]

    // MARK: Auto-Escalation Patterns

    /// Command strings that trigger auto-escalation to 🔴 red tier.
    private static let autoEscalationCommands: [String] = [
        "chmod 777"
    ]

    /// Command prefixes that trigger escalation when followed by whitespace.
    private static let autoEscalationPrefixes: [String] = [
        "rm",
        "kill"
    ]

    /// Pipe-to-interpreter patterns.
    private static let pipePatterns: [String] = [
        "| sh", "|sh",
        "| bash", "|bash",
        "| eval", "|eval",
        "pipe to sh",
        "pipe to bash",
        "pipe to eval"
    ]

    private static let hardBlockKeyword = "sudo"

    public init() {}

    // MARK: Enforcement

    /// Evaluate a tool call against security policies.
    /// Returns `.allow` or `.reject(reason:)`.
    public func enforce(
        toolName: String,
        tier: SecurityTier,
        arguments: Value
    ) -> GateDecision {
        let allStrings = extractStrings(from: arguments)
        let combined = allStrings.joined(separator: " ")
        let lowered = combined.lowercased()

        // Hard block: sudo is ALWAYS rejected
        if containsHardBlockedPattern(lowered) {
            return .reject(reason: "sudo is hard blocked — always rejected, never executed")
        }

        // Forbidden path check
        if let forbidden = checkForbiddenPaths(allStrings) {
            return .reject(reason: "Forbidden path targeted: \(forbidden)")
        }

        // Auto-escalation check: escalate to red
        let effectiveTier = checkAutoEscalation(lowered) ? .red : tier

        // Tier-based enforcement
        switch effectiveTier {
        case .green:
            // 🟢 Execute immediately, no interaction
            return .allow
        case .yellow:
            // 🟡 Execute immediately, post-log confirmation
            return .allow
        case .orange:
            // 🟠 In a real implementation: pause + confirm
            // For V1-03 core: allow (confirmation UI deferred)
            return .allow
        case .red:
            // 🔴 In a real implementation: hard stop + explicit approval
            // For V1-03 core: allow (approval UI deferred)
            // Auto-escalated commands still pass through;
            // the audit log captures the escalation
            return .allow
        }
    }

    // MARK: Pattern Checks

    /// Check if input contains the hard-blocked `sudo` pattern.
    public func containsHardBlockedPattern(_ input: String) -> Bool {
        let lowered = input.lowercased()
        let keyword = SecurityGate.hardBlockKeyword

        // Exact match
        if lowered == keyword { return true }

        // Starts with keyword + whitespace
        if lowered.hasPrefix(keyword + " ") || lowered.hasPrefix(keyword + "\t") { return true }

        // Contains keyword preceded by space/pipe
        let spacePrefixed = " " + keyword + " "
        let pipePrefixed = "|" + keyword
        let pipeSpacePrefixed = "| " + keyword
        if lowered.contains(spacePrefixed) { return true }
        if lowered.contains(pipePrefixed) { return true }
        if lowered.contains(pipeSpacePrefixed) { return true }

        // Contains keyword followed by whitespace anywhere
        if lowered.contains(keyword + " ") || lowered.contains(keyword + "\t") || lowered.contains(keyword + "\n") {
            return true
        }

        return false
    }

    /// Check if any auto-escalation pattern is present.
    public func checkAutoEscalation(_ input: String) -> Bool {
        let lowered = input.lowercased()

        // Check command patterns (e.g., "chmod 777")
        for pattern in SecurityGate.autoEscalationCommands {
            if lowered.contains(pattern) { return true }
        }

        // Check prefix commands followed by whitespace
        for prefix in SecurityGate.autoEscalationPrefixes {
            if lowered.hasPrefix(prefix + " ") || lowered.hasPrefix(prefix + "\t") { return true }
            if lowered.contains(" " + prefix + " ") || lowered.contains(" " + prefix + "\t") { return true }
        }

        // Check pipe-to-interpreter patterns
        for pattern in SecurityGate.pipePatterns {
            if lowered.contains(pattern) { return true }
        }

        return false
    }

    /// Check if any argument targets a forbidden path.
    /// Returns the matched forbidden path or nil.
    public func checkForbiddenPaths(_ strings: [String]) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for str in strings {
            let expanded: String
            if str.hasPrefix("~/") {
                expanded = home + str.dropFirst(1)
            } else if str.hasPrefix("~") {
                expanded = home + str.dropFirst(1)
            } else {
                expanded = str
            }

            for forbidden in SecurityGate.forbiddenPaths {
                let expandedForbidden: String
                if forbidden.hasPrefix("~/") {
                    expandedForbidden = home + String(forbidden.dropFirst(1))
                } else {
                    expandedForbidden = forbidden
                }

                // Check .env files (special case — filename match)
                if forbidden == ".env" {
                    if str.hasSuffix(".env") || str.contains(".env/") || str.contains("/.env") {
                        return forbidden
                    }
                    continue
                }

                // Path containment check
                if expanded.hasPrefix(expandedForbidden) || expanded.hasPrefix(expandedForbidden + "/") {
                    return forbidden
                }
                if str.hasPrefix(forbidden) || str.hasPrefix(forbidden + "/") {
                    return forbidden
                }
            }

            // Application bundles (.app)
            if str.contains(".app/") || str.hasSuffix(".app") {
                if str.contains("/Applications/") || expanded.contains("/Applications/") {
                    return "application bundle"
                }
            }
        }
        return nil
    }

    // MARK: String Extraction

    /// Recursively extract all string values from a Value tree.
    private func extractStrings(from value: Value) -> [String] {
        var results: [String] = []
        switch value {
        case .string(let s):
            results.append(s)
        case .object(let dict):
            for (_, v) in dict {
                results.append(contentsOf: extractStrings(from: v))
            }
        case .array(let arr):
            for v in arr {
                results.append(contentsOf: extractStrings(from: v))
            }
        case .int, .double, .bool, .null:
            break
        case .data:
            break
        }
        return results
    }
}
