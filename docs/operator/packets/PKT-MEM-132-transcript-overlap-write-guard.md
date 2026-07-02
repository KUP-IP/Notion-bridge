# PKT-MEM-132 — Transcript-overlap write guard

**Execution Class:** REVIEW-FIRST
**Status:** Done
**Blocked by:** None
**PROJECT:** Ship The Bridge v4

## Goal Contract

Add a pre-write overlap check between any Notion-bound text (memory_keep body/summary, registry_update text fields) and the memo's raw transcript. Reject writes with excessive verbatim overlap instead of silently allowing an agent-supplied `fields` override to write the raw transcript into Notion.

## GOAL_CONDITION

Implement the length + contiguous-substring hybrid check locked as D49: the check runs only when the proposed text is above a minimum length floor, and rejects when a contiguous verbatim run above a threshold length matches the transcript. A new `VoiceMemoError.transcriptOverlapRejected` routes the memo to REVIEW (the existing graceful-BLOCKED pattern established by PKT-1064's `playerRelationUnbound`) rather than crashing or silently writing.

## Current System State

`resolvedMemoryKeepFields` (VoiceMemoProcessor.swift:596) returns `intent.fields` verbatim whenever the caller supplies a non-empty `fields` map, bypassing the plan-derived heuristic summary entirely. `appendSummaryBodyToNotionPage` (line 668) then writes `fields["summary"] ?? plan.summary` into both the registry property and the Notion page body with no length cap or content check. This is safe on the automated path (heuristic-derived fields never contain the raw transcript) but has no guard at all on the agent-commit path (`voice_memo_commit`'s `fields` parameter), which is the primary path this whole redesign is built around.

## Scope IN

- `executeMemoryKeep`, `executeRegistryUpdate` (both write paths)
- A new small pure-function overlap checker (named constants for the two thresholds, not magic numbers)

## Scope OUT

- PKT-MEM-135's combined registry tool
- PKT-MEM-136's comment path (comments carry short idea/reflow text, not registry field text — confirm in scope during execution whether the guard should apply there too; default assumption is no, since comment text is agent-authored prose, not a `fields` override)

## Dependencies

None.

## Definition of Done

- [ ] Overlap checker implemented as a pure function with named, documented threshold constants
- [ ] Wired into both `executeMemoryKeep` and `executeRegistryUpdate` write paths
- [ ] New `VoiceMemoError.transcriptOverlapRejected` case, routes to REVIEW (queueReview), no crash
- [ ] Unit tests: verbatim transcript paste → rejected; short summary reusing a few real terms → passes; long-but-genuinely-original summary → passes
- [ ] Floor raised with dated provenance

## Verification

`make test-floor` green with new test cases above; manual smoke: attempt a `voice_memo_commit` with `fields.summary` set to the full transcript, confirm rejection + REVIEW routing.

## Packet Runner Output

### Current Canonical Result

REVIEW-ready on branch `pkt-mem-132-transcript-overlap-guard` (commit `56a44b1`). New `VoiceMemoTranscriptOverlapGuard.swift` (length + contiguous-substring hybrid, D49) wired into both `executeMemoryKeep` and `executeRegistryUpdate`; also closed a second write vector in `VoiceMemoReviewResolver.swift` that would have bypassed the guard entirely. `make test-floor` independently re-verified in isolation: 2937/2937 passed, 0 failed.

### Artifact Manifest

New: `TheBridge/Modules/VoiceMemo/VoiceMemoTranscriptOverlapGuard.swift`, `TheBridgeTests/VoiceMemoTranscriptOverlapGuardTests.swift`. Modified: `VoiceMemoProcessor.swift`, `VoiceMemoReviewResolver.swift`, `scripts/test-floor-gate.sh` (FLOOR 2917→2937).

### Exceptional History

Locked via choice-to-contract survey (D46, D49), 2026-07-02. See `docs/operator/MEMORY-HUB-UX-RECONSTRUCTION-SPEC.md`.
