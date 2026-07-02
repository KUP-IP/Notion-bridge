# PKT-MEM-131 — registry_find row-resolution swap

**Execution Class:** REVIEW-FIRST
**Status:** REVIEW
**Blocked by:** None
**PROJECT:** Ship The Bridge v4

## Goal Contract

Replace `VoiceMemoProcessor.resolveRegistryRowId`'s hand-rolled `registry_list` + client-side containment/regex matching with a call to `registry_find` (PKT-1041, shipped 2026-07-02), deleting the duplicate matching logic it predates.

## GOAL_CONDITION

`resolveRegistryRowId(entityKey:hint:router:)` calls `registry_find` instead of `registry_list`. Ambiguity behavior is preserved exactly: a single match returns that row id, ≥2 distinct matches throws `VoiceMemoError.registryAmbiguous`, no match throws `VoiceMemoError.registryMatchFailed`. Existing `RegistryModuleTests` / voice-memo registry-update tests remain green.

## Current System State

`resolveRegistryRowId` (VoiceMemoProcessor.swift, `executeRegistryUpdate`'s helper) fetches up to 100 rows via `registry_list` and does containment-then-regex matching in Swift, pre-dating `registry_find`'s bound-property-id server-side matching (same exact/none/multi semantics, better implementation).

## Scope IN

- `VoiceMemoProcessor.resolveRegistryRowId` only

## Scope OUT

- `mergeAppendRegistryFields`, the `executeRegistryUpdate` write call itself
- PKT-MEM-135's new combined tool (separate packet)

## Dependencies

None.

## Definition of Done

- [ ] `resolveRegistryRowId` calls `registry_find`
- [ ] Old containment/regex matching code deleted (no dead code left behind)
- [ ] Ambiguity/no-match error semantics unchanged from the caller's perspective
- [ ] Tests green, floor raised with dated provenance

## Verification

Unit tests: exact hint match, no match, ambiguous (≥2) match — same three cases the old implementation covered, now exercised against `registry_find`.

## Packet Runner Output

### Current Canonical Result

REVIEW-ready on branch `pkt-mem-131-registry-find-swap` (commit `faf34f6`). `resolveRegistryRowId` now dispatches `registry_find` instead of `registry_list`; old containment/regex matching deleted outright. Ambiguity/no-match semantics preserved byte-identically. `make test-floor` independently re-verified in isolation: 2919/2919 passed, 0 failed.

### Artifact Manifest

`TheBridge/Modules/VoiceMemo/VoiceMemoProcessor.swift`, `TheBridgeTests/VoiceMemoHubTrustTests.swift`, `scripts/test-floor-gate.sh` (FLOOR 2917→2919).

### Exceptional History

Locked via choice-to-contract survey (D55), 2026-07-02. See `docs/operator/MEMORY-HUB-UX-RECONSTRUCTION-SPEC.md`.
