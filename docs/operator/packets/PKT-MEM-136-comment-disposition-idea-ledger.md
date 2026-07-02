# PKT-MEM-136 — Comment disposition + idea-thread ledger

**Execution Class:** REVIEW-FIRST
**Status:** Done
**Blocked by:** PKT-MEM-135 (registry_resolve_and_update) — entity resolution for the comment's target page should be built on the new primitive, not the pattern PKT-MEM-135 exists to replace
**PROJECT:** Ship The Bridge v4

## Goal Contract

New `VoiceMemoIntentKind.comment` with a required `purpose: idea | reflow` field. `idea`-purpose comments post a new top-level Notion page comment (`notion_comment_create`) against the resolved entity's page and log `{memoId, discussion_id, targetEntityKey, targetPageId, postedAt, signedOffAt: nil}` to a new local JSON ledger. `reflow`-purpose comments post the same way but are never logged to the ledger (fire-and-forget). No automatic sign-off trigger — fully agent-initiated for v1 (D51).

## GOAL_CONDITION

Both purposes post correctly to the resolved target page. `idea` comments appear in the new ledger; `reflow` comments never do. Entity resolution for the comment's target reuses `registry_resolve_and_update` (PKT-MEM-135) rather than a bespoke resolution path. Unit tests cover both purposes, ledger read/write, and entity-resolution failure (graceful BLOCKED routing to REVIEW, not a crash — consistent with the PKT-1064 precedent).

## Current System State

`notion_comment_create` (top-level page comment) and `notion_discussion_create` / `notion_comments_list` (reply into an existing `discussion_id`) already exist as general Bridge tools but are not wired into the voice-memo intent model at all. Notion's API cannot resolve/close a comment thread, and cannot retrieve resolved comments once a human closes one in the UI — confirmed against the current Notion API docs (2026-03-11) during the design conversation. "Closed" is therefore permanently a human/Notion-UI action; the ledger's `signedOffAt` field tracks only the agent's own sign-off reply, not actual resolution state.

## Scope IN

- New `VoiceMemoIntentKind.comment` case + `purpose` field
- `VoiceMemoIdeaThreadStore` (new, mirrors `VoiceMemoReviewStore`'s load/save/enqueue shape) — file `idea-threads.json` alongside `review.json`/`processed.json`
- `executeComment` write path, using `registry_resolve_and_update` (PKT-MEM-135) for target-page resolution

## Scope OUT

- Automatic sign-off triggers of any kind (D51 — explicitly manual for v1)
- A `voice_memo_idea_threads_list` read tool (flagged as a follow-on need in D51, not required for this packet's DoD — note for the next reflow pass)
- Any attempt to detect or read Notion's native comment-resolved state (confirmed unavailable via API)

## Dependencies

PKT-MEM-135 (registry_resolve_and_update).

## Definition of Done

- [ ] `comment` intent kind + `purpose` field implemented
- [ ] `idea`-purpose comments logged to `idea-threads.json`
- [ ] `reflow`-purpose comments never logged
- [ ] Entity/target-page resolution goes through `registry_resolve_and_update`
- [ ] Resolution failure routes to REVIEW gracefully (no crash)
- [ ] Tests for both purposes + ledger + failure case
- [ ] Floor raised with dated provenance

## Verification

`make test-floor` green with new suite; manual smoke: process a memo that references an existing project, confirm an `idea` comment appears on that project's Notion page and in `idea-threads.json`.

## Packet Runner Output

### Current Canonical Result

REVIEW-ready on branch `pkt-mem-136-comment-disposition` (commit `feb80ab`), stacked on `pkt-mem-135-registry-resolve-and-update`. New `VoiceMemoIntentKind.comment` + `purpose` field (idea|reflow); idea comments logged to a new `VoiceMemoIdeaThreadStore` ledger, reflow comments never logged. Target-page resolution goes through `registry_resolve_and_update` (PKT-MEM-135), not a bespoke path. `make test-floor` independently re-verified in isolation: 2962/2962 passed, 0 failed (an earlier 6-way-parallel verification pass showed 1 failure on an unrelated clipboard test — confirmed as cross-worktree contention over the real macOS clipboard, not a defect here; solo re-run is clean).

### Artifact Manifest

New: `VoiceMemoIdeaThreadStore.swift`, `TheBridgeTests/VoiceMemoCommentTests.swift`. Modified: `VoiceMemoModels.swift`, `VoiceMemoProcessor.swift`, `NotionModule.swift`, `VoiceMemoModule.swift`, `MemoryHubGuardrails.swift`, `MemoryHubCockpitLabels.swift`, `MemoryProcessCockpit.swift`, `MemoryHubMemoTitle.swift`, `scripts/test-floor-gate.sh` (FLOOR 2940→2962).

### Exceptional History

Locked via choice-to-contract survey (D48, D50, D51), 2026-07-02. Notion Comments API capabilities researched live during design (see conversation + `docs/operator/MEMORY-HUB-UX-RECONSTRUCTION-SPEC.md`).
