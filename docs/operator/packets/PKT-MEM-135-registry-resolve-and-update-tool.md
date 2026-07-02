# PKT-MEM-135 — registry_resolve_and_update combined tool

**Execution Class:** REVIEW-FIRST
**Status:** REVIEW
**Blocked by:** None (hard dependency) — sequencing note: land after PKT-MEM-131 if both are in flight, since both touch the same row-resolution code path and concurrent edits there would conflict
**PROJECT:** Bridge Platform (general-purpose registry primitive — explicitly not Memory-Hub-scoped, per D57)

## Goal Contract

New general-purpose MCP tool `registry_resolve_and_update`: entity + match predicate (field=value, reusing `registry_find`'s bound-property-id matching) + fields + optional append-keys config → resolves the row, merges append-style fields against current values, writes — all in one call. Collapses the find-then-get-then-update three-round-trip pattern currently duplicated inside `VoiceMemoProcessor`.

## GOAL_CONDITION

One MCP call replaces the find-then-get-then-update pattern. Ambiguity/no-match semantics match `registry_find` exactly (single match writes, ≥2 matches returns an ambiguous error without writing, no match returns a clear not-found error without writing). Append-merge behavior matches `VoiceMemoProcessor.mergeAppendRegistryFields` exactly (configured append-keys get existing-value-plus-new-content merge; all other fields overwrite). New `RegistryModuleTests` cover exact/none/multi/append-merge/plain-overwrite cases. `ToolAnnotationCatalog` entry added. `staticFeatureModuleToolCount` bumped with dated provenance. Floor raised.

## Current System State

`VoiceMemoProcessor.executeRegistryUpdate` (VoiceMemoProcessor.swift:497-573) does this today as three sequential dispatches: `resolveRegistryRowId` (registry_list-and-filter, or `registry_find` post-PKT-MEM-131), `mergeAppendRegistryFields` (a separate `registry_get`), then `registry_update`. This is the only place in the codebase implementing "resolve by hint, then update," but the pattern is not voice-memo-specific — any future agent workflow doing the same thing pays the same three-round-trip cost.

## Scope IN

- New tool in `RegistryModule.swift`, alongside `registry_find`/`get`/`create`/`update`
- Append-merge logic (extracted from `VoiceMemoProcessor.mergeAppendRegistryFields` into a shared, reusable location — likely `RegistryWriter.swift`)

## Scope OUT

- Create-on-no-match (upsert) semantics — explicitly out of scope per D56's rationale; a separate, larger design problem
- Rewiring `VoiceMemoProcessor.executeRegistryUpdate` to actually use this tool (that's PKT-MEM-136's dependency, not this packet's DoD — though a reviewer may choose to fold a thin caller-side swap in here if trivial)

## Dependencies

None hard. Sequencing note only (see Blocked by).

## Definition of Done

- [ ] New tool registered with full `ToolAnnotationCatalog` entry
- [ ] Resolve + merge + write in one MCP call
- [ ] Tests: exact match, no match, ambiguous match, append-merge, plain overwrite
- [ ] `staticFeatureModuleToolCount` bumped with dated provenance comment
- [ ] Floor raised with dated provenance

## Verification

`make test-floor` green with new suite; manual smoke via MCP call against a known contact/project row.

## Packet Runner Output

### Current Canonical Result

REVIEW-ready on branch `pkt-mem-135-registry-resolve-and-update` (commit `1327bb7`). New MCP tool `registry_resolve_and_update` collapses find+get+update into one call, reusing `registry_find`'s exact matching plus a new shared `RegistryAppendMerge` primitive. `staticFeatureModuleToolCount` 199→200. `make test-floor` independently re-verified in isolation: 2940/2940 passed, 0 failed. **Gap:** no live MCP smoke against real Notion was run (sandboxed worktree, no credentials) — worth doing before merge.

### Artifact Manifest

New: `RegistryAppendMerge` (in `RegistryWriter.swift`), `makeResolveAndUpdate()` (in `RegistryModule.swift`). Modified: `ToolAnnotations.swift`, `Version.swift`, `RegistryModuleTests.swift`, `TestRunner.swift`, `scripts/test-floor-gate.sh` (FLOOR 2917→2940).

### Exceptional History

Locked via choice-to-contract survey (D56, D57), 2026-07-02. See `docs/operator/MEMORY-HUB-UX-RECONSTRUCTION-SPEC.md`.
