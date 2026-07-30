> **Historical evidence — superseded.** This file records an earlier C0 candidate, review, or blocker and is retained for provenance only. It does **not** describe the current candidate on base `850d58aca71ddf28ff6010bc334121b6936555ef`. Current authority is `c0-implementation-receipt.md`, `c0-delivery-todo.md`, and the externally retained 2026-07-30 review/test receipts.

# C0 Independent Review Unblock Receipt

Timestamp: `2026-07-29T02:24:28Z`

## Preserved candidate

- Worktree: `/Users/keepup/Developer/worktrees/the-bridge/c0-runtime-worktree-ownership`
- Branch: `packet/c0-runtime-worktree-ownership`
- Base / current HEAD: `01fd3984b91ca3c9e3ff16160d2a80a3d42f6261`
- Source state: uncommitted; no push, merge, install, release, tag, reset, clean, stash, branch switch, or worktree deletion.
- Last authoritative source run: job `20260729-013456345-0a94d495` — `3507 passed, 0 failed, 3507 total`.
- Inherited test floor: `3482`; measured candidate count: `3507`; potential floor delta: `+25`. The floor was not changed because independent review did not complete.

## Review attempts

Three distinct read-only reviewer approaches failed before inspecting the candidate:

1. Claude Code print/plan reviewer: authentication failed because the local OAuth session expired and could not refresh.
2. Codex dedicated `review --uncommitted` path: the installed CLI rejected a custom stdin prompt despite advertising a prompt argument in help.
3. Codex read-only `exec` path: invocation failed on CLI option placement before agent startup.

Per the delivery blocker gate, execution stopped after the third failed approach. No review verdict was produced and no reviewer mutated the repository.

## Unblock condition

Use one verified reviewer path only, then resume from the preserved candidate:

- refresh Claude Code authentication and rerun the read-only prompt; or
- invoke Codex with global approval flags before the `exec` subcommand, read-only sandbox, and the prompt from `docs/evidence/c0-final-review-prompt.md`.

Required outcome before further delivery mutation: an independent verdict of `APPROVE` with no open Critical/High/Medium findings. After approval: raise the floor `3482 → 3507` with append-only provenance, run `make test-floor`, commit, rerun the exact commit SHA from a clean worktree, finalize evidence, and transition C0 to REVIEW.
