// VoiceMemoContentQualityGate.swift — minimum-information quality gate (GH #81)
// TheBridge · Modules · VoiceMemo
//
// GH #81: `voice_memo_commit` could mark a `memory_keep` record
// `markedProcessed: true` even when the resulting Notion Memory page body was
// a weak transcript-opening fragment ("I'm having fun with this idea") or
// disfluency-dominated filler ("We, uh, terrible the sea") standing in for a
// substantive summary. `appendSummaryBodyToNotionPage` already skips
// appending an EMPTY summary (`guard !trimmed.isEmpty`), but nothing blocked
// `markedProcessed: true` for a NON-empty-but-worthless one — the exact gap
// this file closes.
//
// Mirrors `VoiceMemoTranscriptOverlapGuard`'s style (D49): pure, UI-free, no
// Notion/network access, named constants (no magic numbers), an
// Equatable/Sendable Verdict, evaluated BEFORE any processed-gate write.
//
// THE RULE (explicit, reviewable — not ad-hoc judgment; see also
// VoiceMemoContentQualityGateTests.swift for the calibration evidence):
//
// A candidate memory_keep summary/body FAILS the gate (routes to review,
// never marks processed) when it fails ANY of:
//   1. Non-empty after trimming whitespace.
//   2. At least `minimumWordCount` (8) whitespace-separated words. Below this,
//      text cannot carry the "structured key points, dates, decisions" the
//      GH #81 write-up asks for — it's definitionally a fragment.
//   3. Disfluency ratio below `disfluencyRatioCeiling` (40%): the fraction of
//      words that are verbal-disfluency tokens (um, uh, okay, like, …) must
//      stay under the ceiling. This catches "We, uh, terrible the sea"
//      (2/5 = 40%, "uh" is the sole disfluency word) without penalizing a
//      real sentence that happens to contain one incidental "uh".
//
// Calibration: all 3 real GH #81 filler summaries fail on word count alone
// (5–6 words, well under the 8-word floor — including "At these at these
// days, okay" at 6 words, which needs no disfluency reasoning at all). The
// disfluency check is a second, independent line of defense for a
// longer-but-still-hollow summary (e.g. repeated filler padded past 8
// words), deliberately restricted to genuine verbal disfluencies rather than
// any word from a specific repro string, so it can't become a false-positive
// trap on ordinary content words. A genuine short-but-real memo ("Call Sarah
// about the Q3 budget by Friday" — 8 words, 0% disfluency) passes both
// checks — the packet's "zero regression on memos that already produce good
// summaries" constraint.

import Foundation

public enum VoiceMemoContentQualityGate {

    /// Below this word count, text is rejected outright — a transcript
    /// fragment or single filler clause cannot meet it. Calibrated so all 3
    /// GH #81 repro summaries (5–6 words each) fail, while a genuine short
    /// memo ("Call Sarah about the Q3 budget by Friday", 8 words) passes.
    public static let minimumWordCount = 8

    /// At or above this fraction of disfluency-token words, text is treated
    /// as filler-dominated even if it clears the word-count floor.
    public static let disfluencyRatioCeiling = 0.40

    /// Case-insensitive whole-word disfluency/filler vocabulary. Deliberately
    /// narrow (verbal disfluencies only) — NOT a generic stopword list, so
    /// real content words are never penalized. Reviewed and pruned 2026-07-03:
    /// an earlier draft also included "at"/"these" to specifically trip the
    /// GH #81 "At these at these days, okay" repro — but that string is only
    /// 6 words, already rejected by `minimumWordCount` before this check ever
    /// runs, so those two entries were inert for their stated purpose and
    /// pure false-positive risk (ordinary function words that appear in any
    /// legitimate summary). Removed rather than kept as dead weight.
    public static let disfluencyTokens: Set<String> = [
        "um", "uh", "uhh", "umm", "erm", "er",
        "okay", "ok",
        "like", "y'know", "yknow",
    ]

    public enum Verdict: Equatable, Sendable {
        case ok
        /// Reason the text failed, carried for the review-queue entry / error message.
        case rejected(reason: String)
    }

    /// Evaluate one candidate summary/body against the gate. Pass the
    /// generated title as a fallback signal is NOT needed here — the gate
    /// evaluates the text that would actually be written to Notion.
    public static func evaluate(_ text: String) -> Verdict {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .rejected(reason: "summary is empty")
        }

        let words = trimmed
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        guard words.count >= minimumWordCount else {
            return .rejected(reason: "summary is only \(words.count) word(s) — below the \(minimumWordCount)-word minimum-information floor")
        }

        let disfluencyCount = words.filter { word in
            let normalized = word.trimmingCharacters(in: .punctuationCharacters).lowercased()
            return disfluencyTokens.contains(normalized)
        }.count
        let ratio = Double(disfluencyCount) / Double(words.count)
        guard ratio < disfluencyRatioCeiling else {
            let pct = Int((ratio * 100).rounded())
            return .rejected(reason: "summary is \(pct)% filler/disfluency words — below the minimum-information bar")
        }

        return .ok
    }
}
