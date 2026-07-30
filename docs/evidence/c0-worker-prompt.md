> **Historical evidence — superseded.** This file records an earlier C0 candidate, review, or blocker and is retained for provenance only. It does **not** describe the current candidate on base `850d58aca71ddf28ff6010bc334121b6936555ef`. Current authority is `c0-implementation-receipt.md`, `c0-delivery-todo.md`, and the externally retained 2026-07-30 review/test receipts.

# C0 Worker Instructions

You are an app-dev implementation worker inside exactly one repository worktree:

- repoRoot: `/Users/keepup/Developer/the-bridge`
- worktreePath: `/Users/keepup/Developer/worktrees/the-bridge/c0-runtime-worktree-ownership`
- branch: `packet/c0-runtime-worktree-ownership`
- baseSHA: `01fd3984b91ca3c9e3ff16160d2a80a3d42f6261`

Read `AGENTS.md`, `CLAUDE.md`, `docs/AGENT_PLAYBOOK.md`, and the current source before editing. Maintain `docs/evidence/c0-delivery-todo.md` as work advances.

## Goal

Implement and test runtime worktree ownership so one active owner controls a canonical worktree path, multiple isolated worktrees remain usable, and consequential Git/source-promotion mutations fail closed on missing or changed identity.

## Required public operations

Add read/write tool contracts for:

- `worktree_claim`
- `worktree_release`

Claim tuple must include at least:

- canonical repoRoot
- canonical worktreePath
- branch
- baseSHA
- ownerSession
- bounded expiry

Conflict identity is the canonical worktree path. Same owner+same tuple retries must be idempotent. A different unexpired owner must be rejected. Two distinct worktree paths under one repo must be concurrently claimable.

Release dispositions:

- clean/releasable
- preserve for review
- preserve with unique commits
- abandoned with recovery note

Release and expiry must never delete, reset, clean, switch, stash, or mutate files/Git. Expired claims remain stale metadata until explicit recovery; never silently seize a live worktree based only on timeout.

## Enforcement

Use a shared, auditable guard seam. At minimum cover every consequential mutation actually exposed by current source, including:

- Git module mutations: apply patch, create branch, and any current branch/switch/stash/reset/commit/rebase/merge/clean operations if exposed.
- generic shell/background execution when command/cwd resolves to a protected repository and the command is a consequential Git mutation or source install/promotion command.
- direct file mutation tools when target resolves inside a claimed worktree.
- source install/candidate promotion seams (`make install`, `make install-copy`, `make install-agent-safe`, release/promotion targets and wrappers actually exposed).

Read-only Git (`git_status`, `git_diff`, `git_log`, `git_show`, `git_blame`) must remain available without a claim.

Before protected mutation, prove the current tuple still matches claim data. Branch, base, repo root, or worktree path drift must fail before mutation with stable code `worktree_identity_changed`. Missing ownership must fail closed with a stable ownership-required code. Foreign ownership must fail closed.

Do not duplicate existing app-dev tuple checks; make them enforceable through the runtime.

## Persistence and concurrency

Use a domain-specific durable store under BridgePaths/Application Support. Reuse established SQLite/WAL/process-lock patterns where appropriate, but keep this domain independent from calendar/thread stores. Acquisition must be atomic across concurrent tasks/processes. Canonicalization must resolve symlinks and standardized paths safely.

Keep the implementation strict-concurrency clean and testable through `BridgePaths.overrideHomeForTesting` or an equivalent hermetic seam.

## Tests-first / Definition of Done

Write failing tests before implementation where practical. Add coverage for:

1. first claim success and idempotent same-owner retry;
2. same-path concurrent claim race: exactly one owner succeeds;
3. symlink/path-normalization collision;
4. distinct-worktree concurrency in one repo;
5. branch/base/path drift -> `worktree_identity_changed` before mutation;
6. missing/foreign claim blocks protected mutation;
7. read-only Git bypass remains available;
8. expiry leaves stale metadata and leaves files/Git unchanged;
9. explicit stale recovery semantics are fail-closed and evidence preserving;
10. release dispositions, unique commits, and recovery note preservation;
11. mutation inventory matrix for current Git/file/shell/bg/install/promotion surfaces;
12. tool annotation and static tool-count invariants;
13. regression suite remains green.

Use the existing custom test harness. Update `scripts/test-floor-gate.sh` only after measuring the net-new green count; never lower the floor.

## Boundaries

- Do not install or relaunch The Bridge.
- Do not merge, push, tag, release, or create a PR.
- Do not commit; supervisor owns the commit.
- Do not reset, clean, stash, switch the current branch, delete a worktree, or delete user files.
- Do not edit outside this worktree.
- Do not alter packet/Notion state.
- Do not expand into Packet Runner orchestration, distributed/multi-Mac locking, GitHub branch protection, a general scheduler, automatic stale reclaim, or automatic worktree deletion.

## Evidence

Create/update:

- `docs/evidence/c0-guarded-operation-inventory.md`
- `docs/evidence/c0-implementation-receipt.md`
- `docs/evidence/c0-delivery-todo.md`

Report exact files changed, design choices, focused/full test results, remaining risks, and any contract delta. Stop with the worktree uncommitted for supervisor review.