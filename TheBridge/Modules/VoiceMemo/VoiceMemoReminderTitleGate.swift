// VoiceMemoReminderTitleGate.swift — SC6 reminder title quality (Voice Memo Reliability)
// Rejects sentence-middle / conjunction-led fragments; supplies a stable fallback.

import Foundation

public enum VoiceMemoReminderTitleGate {

    public enum Verdict: Equatable, Sendable {
        case ok(String)
        case rejected(reason: String, fallback: String)
    }

    /// Leading tokens that usually mean the title was sliced from mid-clause.
    public static let midClauseOpeners: Set<String> = [
        "too", "but", "and", "or", "so", "because", "anyway", "well",
        "also", "then", "just", "like", "uh", "um", "okay", "ok",
    ]

    public static func evaluate(_ title: String, transcript: String) -> Verdict {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = stableFallbackTitle(transcript: transcript)
        guard !trimmed.isEmpty else {
            return .rejected(reason: "reminder title is empty", fallback: fallback)
        }

        let words = trimmed
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard words.count >= 2 else {
            return .rejected(reason: "reminder title is only \(words.count) word(s)", fallback: fallback)
        }

        let first = words[0]
            .trimmingCharacters(in: .punctuationCharacters)
            .lowercased()
        if midClauseOpeners.contains(first) {
            return .rejected(
                reason: "reminder title opens with mid-clause fragment ‘\(words[0])’",
                fallback: fallback
            )
        }

        // Leading lowercase letter + comma shortly after → classic mid-sentence cut.
        if let firstScalar = trimmed.unicodeScalars.first,
           CharacterSet.lowercaseLetters.contains(firstScalar),
           trimmed.contains(",") {
            return .rejected(
                reason: "reminder title looks like a sentence-middle fragment",
                fallback: fallback
            )
        }

        return .ok(trimmed)
    }

    /// Prefer an imperative “Remind …” / block-phrase style line; else first clean sentence.
    public static func stableFallbackTitle(transcript: String) -> String {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "Follow up from voice memo" }

        let lower = text.lowercased()
        if let range = lower.range(of: #"remind(?:\s+me)?\s+to\s+"#, options: .regularExpression) {
            let after = text[range.upperBound...]
            let snippet = String(after.prefix(80))
                .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if snippet.count >= 4 {
                return VoiceMemoParser.sanitizeTitle("Remind me to \(snippet)", fallback: "Follow up from voice memo")
            }
        }

        let sentence = VoiceMemoParser.firstSentencePublic(in: text, maxLen: 72)
        let cleaned = VoiceMemoParser.sanitizeTitle(sentence, fallback: "Follow up from voice memo")
        let words = cleaned.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        if let first = words.first?
            .trimmingCharacters(in: .punctuationCharacters)
            .lowercased(),
           midClauseOpeners.contains(first) {
            return "Follow up from voice memo"
        }
        return cleaned.isEmpty ? "Follow up from voice memo" : cleaned
    }
}
