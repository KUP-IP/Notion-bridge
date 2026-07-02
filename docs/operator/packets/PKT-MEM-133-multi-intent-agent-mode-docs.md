# PKT-MEM-133 — Multi-intent agent-mode documentation

**Execution Class:** AUTO (doc/metadata-only, no behavior change)
**Status:** Done
**Blocked by:** None
**PROJECT:** Ship The Bridge v4

## Goal Contract

Update `voice_memo_get` / `voice_memo_commit` tool descriptions and metadata to state explicitly that committing multiple intents per memo (one `voice_memo_commit` call per intent) is normal, expected agent-mode behavior — not an edge case — mirroring the UI's existing batch-confirm cockpit model.

## GOAL_CONDITION

Tool descriptions and `whenToUse` metadata for both tools mention multi-intent-per-memo explicitly. No election/suppression logic (`VoiceMemoIntentElection`) changes — this packet is documentation only.

## Current System State

`VoiceMemoIntentElection.split()` already elects one primary and suppresses the rest to review, and nothing prevents an agent from calling `voice_memo_commit` multiple times for the same `memoId` with different `intentKind` values today. The gap is purely that neither tool's description says this is expected — an agent reading only the tool surface would reasonably assume one commit per memo.

## Scope IN

- `VoiceMemoModule.swift` tool registration metadata (`description`, `whenToUse`) for `voice_memo_get` and `voice_memo_commit` only

## Scope OUT

- Any change to `VoiceMemoIntentElection` or the election/suppression algorithm

## Dependencies

None.

## Definition of Done

- [ ] `voice_memo_get` description/metadata documents that the returned plan may contain multiple committable intents
- [ ] `voice_memo_commit` description/metadata documents that repeated calls per memo (one per intent) are expected in agent mode
- [ ] No behavior change; existing tests remain green as-is

## Verification

Read the updated tool descriptions back via `tools_list` or equivalent; confirm no `.swift` logic files outside `VoiceMemoModule.swift`'s registration blocks changed.

## Packet Runner Output

### Current Canonical Result

REVIEW-ready on branch `pkt-mem-133-multi-intent-docs` (commit `3d23df1`). Doc-only: `voice_memo_get`/`voice_memo_commit` descriptions now state multi-intent-per-memo is expected agent-mode behavior. No logic changed, no floor bump. `make test-floor` independently re-verified in isolation: 2917/2917 passed, 0 failed (unchanged from main).

### Artifact Manifest

`TheBridge/Modules/VoiceMemo/VoiceMemoModule.swift` (registration metadata only).

### Exceptional History

Locked via choice-to-contract survey (D47), 2026-07-02. See `docs/operator/MEMORY-HUB-UX-RECONSTRUCTION-SPEC.md`.
