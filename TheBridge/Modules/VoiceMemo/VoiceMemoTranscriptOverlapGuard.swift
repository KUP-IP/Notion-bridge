// VoiceMemoTranscriptOverlapGuard.swift — pre-write transcript-overlap check (D49)
// TheBridge · Modules · VoiceMemo
//
// `resolvedMemoryKeepFields` returns an agent-supplied `intent.fields` map
// verbatim when the caller (voice_memo_commit / voice_memo_review_resolve)
// provides one, bypassing the plan-derived heuristic summary entirely.
// `executeMemoryKeep` / `executeRegistryUpdate` then write those field values
// straight into Notion (registry property + page body) with no length cap or
// content check. That is safe on the automated batch path (heuristic-derived
// fields never contain the raw transcript) but has NO guard at all on the
// agent-commit path — an agent could paste the full raw transcript into
// `fields.summary` and have it land verbatim in Notion.
//
// D49 (locked via choice-to-contract survey, 2026-07-02): a length +
// contiguous-substring hybrid check. Pure, UI-free, no Notion/network access —
// mirrors the MemoryHubCommitGuardrails / MemoryHubRegistryDiff style (named
// constants, no magic numbers, Equatable/Sendable result types).

import Foundation

public enum VoiceMemoTranscriptOverlapGuard {

    /// Below this length a proposed value is never checked — short summaries
    /// that legitimately reuse a handful of real transcript terms (names,
    /// dates, a quoted phrase) must always pass. Guards against false
    /// positives on genuinely short, original text.
    public static let minimumLengthFloor = 80

    /// A contiguous verbatim run at or above this length, found in both the
    /// proposed text AND the transcript, is treated as a raw-transcript paste
    /// rather than an original summary and is rejected. Chosen well above any
    /// plausible shared sentence fragment/quote, so genuinely original
    /// summaries that happen to reuse a few consecutive real words never trip
    /// it.
    public static let contiguousRunThreshold = 200

    public enum Verdict: Equatable, Sendable {
        case ok
        /// The length (in characters) of the offending contiguous verbatim
        /// run, carried for diagnostics/error messages.
        case rejected(runLength: Int)
    }

    /// Whether `text` may be written to Notion given `transcript`. Runs the
    /// check ONLY when `text` clears `minimumLengthFloor` (short text always
    /// passes); rejects when a contiguous verbatim run of at least
    /// `contiguousRunThreshold` characters appears in both `text` and
    /// `transcript` (case/whitespace-normalized so re-casing or re-wrapping
    /// the same paste does not evade the check).
    public static func evaluate(text: String, transcript: String) -> Verdict {
        guard text.count >= minimumLengthFloor else { return .ok }
        guard !transcript.isEmpty else { return .ok }

        let normalizedText = normalize(text)
        let normalizedTranscript = normalize(transcript)
        guard normalizedText.count >= contiguousRunThreshold,
              !normalizedTranscript.isEmpty else { return .ok }

        if let runLength = longestSharedContiguousRun(
            normalizedText,
            normalizedTranscript,
            minLength: contiguousRunThreshold
        ) {
            return .rejected(runLength: runLength)
        }
        return .ok
    }

    /// True when ANY of `fields`' values fail `evaluate` against `transcript`.
    /// Convenience for callers checking a whole Notion-bound field map in one
    /// pass (memory_keep / registry_update both write `[String: String]`).
    public static func firstRejectedField(
        in fields: [String: String],
        transcript: String
    ) -> (key: String, runLength: Int)? {
        for key in fields.keys.sorted() {
            guard let value = fields[key] else { continue }
            if case .rejected(let runLength) = evaluate(text: value, transcript: transcript) {
                return (key, runLength)
            }
        }
        return nil
    }

    /// Collapse whitespace runs to a single space and lowercase, so a paste
    /// that only differs by re-wrapping/re-casing the same transcript text
    /// still trips the contiguous-run match.
    private static func normalize(_ s: String) -> String {
        let collapsed = s
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.lowercased()
    }

    /// Whether `a` and `b` share a contiguous run of at least `minLength`
    /// characters, and if so its length (the length of the FIRST such run
    /// found in `a`, scanning left to right — sufficient to answer "does an
    /// over-threshold run exist", which is all the guard needs; not the
    /// global longest-common-substring).
    ///
    /// Implementation: slide a `minLength`-wide window across the shorter
    /// string and probe containment in the longer one (`String.range(of:)`),
    /// then greedily extend a hit forward. This avoids an O(n·m) DP table for
    /// transcript-length inputs while still being exact for the
    /// above-threshold question the guard actually asks.
    private static func longestSharedContiguousRun(_ a: String, _ b: String, minLength: Int) -> Int? {
        // Scan windows over the shorter string against the longer string —
        // fewer, cheaper `range(of:)` probes either way.
        let (needleSource, haystack) = a.count <= b.count ? (a, b) : (b, a)
        guard needleSource.count >= minLength else { return nil }

        let chars = Array(needleSource)
        var start = 0
        while start + minLength <= chars.count {
            let windowEnd = start + minLength
            let window = String(chars[start..<windowEnd])
            guard haystack.range(of: window) != nil else {
                start += 1
                continue
            }
            // Extend the match forward as far as it stays verbatim, so the
            // reported run length is accurate (not just >= minLength).
            var end = windowEnd
            while end < chars.count {
                let extended = String(chars[start..<(end + 1)])
                if haystack.range(of: extended) != nil {
                    end += 1
                } else {
                    break
                }
            }
            return end - start
        }
        return nil
    }
}
