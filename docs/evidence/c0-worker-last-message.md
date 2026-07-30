> **Historical evidence — superseded.** This file records an earlier C0 candidate, review, or blocker and is retained for provenance only. It does **not** describe the current candidate on base `850d58aca71ddf28ff6010bc334121b6936555ef`. Current authority is `c0-implementation-receipt.md`, `c0-delivery-todo.md`, and the externally retained 2026-07-30 review/test receipts.

Partial implementation is uncommitted and not REVIEW-ready.

Delivered:
- Durable SQLite/WAL ownership ledger and `worktree_claim` / `worktree_release`.
- Shared pre-handler guard in `ToolRouter`.
- Registry, annotation, static count updates (211 → 213).
- Initial focused ownership tests and required evidence files.

Key files: [WorktreeOwnership.swift](/Users/keepup/Developer/worktrees/the-bridge/c0-runtime-worktree-ownership/TheBridge/Modules/WorktreeOwnership.swift), [ToolRouter.swift](/Users/keepup/Developer/worktrees/the-bridge/c0-runtime-worktree-ownership/TheBridge/Server/ToolRouter.swift), [implementation receipt](/Users/keepup/Developer/worktrees/the-bridge/c0-runtime-worktree-ownership/docs/evidence/c0-implementation-receipt.md).

Verification:
- `git diff --check` passed.
- Debug build reached compilation of the C0 source/test target without a C0 diagnostic in captured output.
- A deterministic follow-up build was blocked by sandbox-denied SwiftPM manifest/module-cache access, so focused tests and `make test-floor` are not green or claimed complete.

Remaining material gaps are documented in the receipt: real-Git drift/symlink/expiry/no-mutation tests, full mutation-inventory proof, and full regression/test-floor run. No install, Git-state mutation, commit, push, or release was performed.