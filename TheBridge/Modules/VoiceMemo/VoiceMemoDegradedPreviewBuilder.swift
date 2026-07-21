// VoiceMemoDegradedPreviewBuilder.swift — SC5 structured preview when LLM is degraded

import Foundation

public enum VoiceMemoDegradedPreviewBuilder {

    public struct Preview: Equatable, Sendable {
        public var summary: String
        public var actions: [String]
        public var decisions: [String]

        public init(summary: String, actions: [String], decisions: [String]) {
            self.summary = summary
            self.actions = actions
            self.decisions = decisions
        }
    }

    /// Build a usable sectioned preview from raw transcript without an LLM.
    public static func build(from transcript: String, maxSummaryLen: Int = 400) -> Preview {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return Preview(summary: "", actions: [], decisions: [])
        }

        let sentences = splitSentences(text)
        var actions: [String] = []
        var decisions: [String] = []
        var topicBits: [String] = []

        let actionHints = ["remind", "follow up", "call ", "email", "text ", "schedule", "need to", "have to", "should "]
        let decisionHints = ["decided", "going to", "will ", "won't", "instead", "chose", "picking"]

        for sentence in sentences {
            let lower = sentence.lowercased()
            let clipped = String(sentence.prefix(160)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard clipped.count >= 8 else { continue }
            if actionHints.contains(where: { lower.contains($0) }) {
                actions.append(clipped)
            } else if decisionHints.contains(where: { lower.contains($0) }) {
                decisions.append(clipped)
            } else if topicBits.count < 4 {
                topicBits.append(clipped)
            }
        }

        if actions.isEmpty {
            actions = Array(VoiceMemoParser.extractActionBulletsPublic(from: text).prefix(5))
        }

        var summaryParts: [String] = []
        if !topicBits.isEmpty {
            summaryParts.append("Topics: " + topicBits.prefix(3).joined(separator: " · "))
        }
        if !decisions.isEmpty {
            summaryParts.append("Decisions: " + decisions.prefix(2).joined(separator: " · "))
        }
        if !actions.isEmpty {
            summaryParts.append("Actions: " + actions.prefix(3).joined(separator: " · "))
        }
        if summaryParts.isEmpty {
            summaryParts.append(VoiceMemoParser.firstSentencePublic(in: text, maxLen: maxSummaryLen))
        }

        var summary = summaryParts.joined(separator: "\n")
        if summary.count > maxSummaryLen {
            summary = String(summary.prefix(maxSummaryLen - 1)) + "…"
        }

        return Preview(
            summary: summary,
            actions: Array(actions.prefix(8)),
            decisions: Array(decisions.prefix(6))
        )
    }

    private static func splitSentences(_ text: String) -> [String] {
        text
            .replacingOccurrences(of: "\n", with: ". ")
            .components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
