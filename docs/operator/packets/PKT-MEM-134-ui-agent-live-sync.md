# PKT-MEM-134 — UI↔agent live processing sync

**Execution Class:** REVIEW-FIRST
**Status:** Done
**Blocked by:** None (parallelizable with every other packet in this batch)
**PROJECT:** Ship The Bridge v4

## Goal Contract

Give the Process tab a live view of agent-driven processing: a "considering" event when `voice_memo_get` runs, a "committed" event when `voice_memo_commit` runs, both visually distinguished in the same feed, delivered via a new dedicated notification channel — not the existing review-changed one. No menu-bar badge or macOS notification work (explicitly deferred, D54).

## GOAL_CONDITION

Opening the Process tab on a memo currently being worked by a connected MCP agent shows live proposal and commit events without a manual reload. The notification channel is separate from `voiceMemoReviewDidChange`. `MemoryProcessLayoutAXTests` extended to cover the new live states.

## Current System State

`NotificationCenter` posts of `.voiceMemoReviewDidChange` (MemorySection.swift:401, 431) only fire from operator button-clicks inside the Settings UI — nothing in `VoiceMemoProcessor`'s get/commit path posts any notification today. `MemoryHubActivityLog.swift` already writes a structured event stream to disk, but nothing pushes it live to an open UI. `voice_memo_triage_open`/`voice_memo_triage_await` (PKT-MEM-122) already model agent→UI handoff and are the closest existing primitive to build on.

## Scope IN

- New `MemoryHubActivityEventType` case(s) for proposal vs. commit
- New `Notification.Name`, posted from `VoiceMemoProcessor.get` and `.commit`
- `MemoryProcessTab` / `MemorySection` subscription + rendering (visual distinction between proposed and committed entries for the same memoId)

## Scope OUT

- Menu-bar badge, macOS notifications (D54 — explicitly deferred to a future decision if unattended/scheduled agent processing becomes a real use case)

## Dependencies

None — independent of every other packet in this batch.

## Definition of Done

- [ ] Proposal event emitted from `voice_memo_get`
- [ ] Commit event emitted from `voice_memo_commit`
- [ ] Dedicated notification channel, separate from `voiceMemoReviewDidChange`
- [ ] Process tab live-renders both event types, visually distinct, while open
- [ ] `MemoryProcessLayoutAXTests` extended for the new states
- [ ] Floor raised with dated provenance

## Verification

Live smoke: with the Process tab open on a specific memo, call `voice_memo_get` then `voice_memo_commit` via MCP from a separate session; confirm both events render without a manual UI reload.

## Packet Runner Output

### Current Canonical Result

REVIEW-ready on branch `pkt-mem-134-ui-agent-live-sync` (commit `7bfd555`). New dedicated notification channel (`memoryHubLiveProcessingDidChange`) posts "considering"/"committed" events from `voice_memo_get`/`commit`; Process tab live-renders both, visually distinct, via a new `liveProcessingBadge`. `make test-floor` independently re-verified in isolation: 2926/2926 passed, 0 failed.

### Artifact Manifest

`MemoryHubActivityLog.swift`, `MemorySection.swift`, `VoiceMemoProcessor.swift`, `MemoryProcessTab.swift`, `BridgeShell.swift`, `TheBridgeTests/MemoryHubLiveProcessingTests.swift` (new), `scripts/test-floor-gate.sh` (FLOOR 2917→2926).

### Artifact Manifest

### Exceptional History

Locked via choice-to-contract survey (D52, D53, D54), 2026-07-02. See `docs/operator/MEMORY-HUB-UX-RECONSTRUCTION-SPEC.md`.
