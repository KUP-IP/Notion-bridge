> **Historical evidence — superseded.** This file records an earlier C0 candidate, review, or blocker and is retained for provenance only. It does **not** describe the current candidate on base `850d58aca71ddf28ff6010bc334121b6936555ef`. Current authority is `c0-implementation-receipt.md`, `c0-delivery-todo.md`, and the externally retained 2026-07-30 review/test receipts.

# C0 Independent Review — Transactional Worktree Ownership

You are an independent read-only security and correctness reviewer. Review the complete uncommitted diff in this worktree. Do not edit files, run destructive Git commands, install, commit, push, merge, tag, release, or change packet state.

## Worktree and baseline

- Worktree: `/Users/keepup/Developer/worktrees/the-bridge/c0-runtime-worktree-ownership-v2`
- Branch: `packet/c0-runtime-worktree-ownership-v2`
- Base/HEAD: `e0a49bc409c4f649d555556dd6883a814fe3d01e`
- Base tree is current `origin/main`.
- Candidate is intentionally uncommitted and dirty.
- `git diff --check` passes.

## Objective

Determine whether C0 now reliably prevents concurrent Bridge dispatches/processes from mutating the same Git worktree while preserving concurrent use of distinct worktrees, without treating branch or pathname as the lifetime identity and without a live-tuple TOCTOU gap.

## Required implementation contract

1. **Stable worktree identity**
   - Authorization identity must survive symlink aliases, branch switches, and `git worktree move`.
   - Removing and recreating a worktree at the same path must create a different identity.
   - Path, branch, repo root, and base SHA remain claim/release provenance, not the mutex key.

2. **Transactional authorization**
   - A foreground mutating handler must hold one non-transferable execution permit from final identity/claim validation until handler completion.
   - Claim and release must contend on the same per-worktree exclusion mechanism.
   - A permit admitted before TTL expiry may finish; no new permit may start after expiry.
   - Same-process tasks and separate Bridge processes must both exclude correctly.
   - Multiple worktree locks must be acquired deterministically and partial acquisition must unwind.
   - Distinct worktrees must remain concurrently usable.

3. **Nested dispatch**
   - Task-local permit propagation may permit nested mutation only for the same owner and a subset of already-held identities.
   - Nested widening to an additional worktree must fail before handler execution.

4. **Lock storage safety**
   - Private lock directory/files, bounded deterministic names, no symlink traversal, stale lock files harmless.

5. **Shell/background closure**
   - `env -S`, `--split-string`, and attached forms must fail as `worktree_target_unresolved` rather than hide an executable.
   - `bg_run` targeting/executing in any governed Git worktree must fail before job/log/done/child creation with `worktree_background_unsupported`; foreground `shell_exec` remains the supported governed path.

6. **Direct copy/archive policy**
   - `file_copy` authorizes the destination only.
   - `file_zip` authorizes the archive output only.
   - `file_unzip` authorizes the extraction destination only.
   - Their source/archive inputs are read-only and do not require ownership unless also mutated by another declared operation.

7. **No regression of existing boundaries**
   - Proven dedicated read-only Git/file tools stay claim-free.
   - Unknown foreground shell commands remain usable when all affected worktrees are owned.
   - Expiry/release never resets, cleans, stashes, switches, deletes, or edits user work.

## Evidence already obtained

- Clean current-main baseline job `20260729-132948421-dbd8f37a`: **3488 passed, 13 failed, 3501 total**.
- Candidate confirmation job `20260729-133254857-883b5c9d`: **3530 passed, 13 failed, 3543 total**.
- All **42/42 C0 worktree ownership tests passed**; zero C0 failures.
- The same 13 failures occur on clean current main and are confined to Runtime Exposure / skills registry command and routing tests. Treat them as baseline unless the C0 diff causally affects them.

## Review focus

Inspect at minimum:

- `TheBridge/Modules/WorktreeOwnership.swift`
- `TheBridge/Server/ToolRouter.swift`
- every C0-related module/schema edit
- `TheBridgeTests/WorktreeOwnershipTests.swift`
- affected audit/meta-tests and integration tests

Adversarially check:

- inode/device identity correctness for main and linked worktrees, aliases, moves, deletion/recreation, Git admin paths, filesystem reuse, and unsupported repository shapes;
- lock ordering, same-process reservation, POSIX `lockf` semantics, descriptor lifetime, double release, cancellation, thrown handlers, nested dispatch, and actor/task boundaries;
- pre-lock analysis versus post-lock reprobe, claim lookup races, claim/release transaction ordering, expiry edge cases, and whether any mutation can occur outside the permit lifetime;
- lock-directory/file permissions, ownership assumptions, symlink/hard-link attacks, replacement races, path containment, and stale artifacts;
- any direct mutating tool or shell route that still bypasses the shared seam;
- whether `bg_run` denial occurs before all artifacts and child startup;
- whether `env -S` or alternate wrappers still conceal targets;
- whether tests genuinely exercise separate processes rather than recursively running the suite or only testing mocks;
- whether the clean-main baseline comparison is valid.

## Output contract

Return exactly one verdict: `APPROVE` or `REJECT`.

Then list findings by severity: Critical, High, Medium, Low. For every Critical/High/Medium finding, provide:

- exact file and line range;
- concrete exploit/failure sequence;
- why existing tests do not close it;
- smallest correct remediation.

`APPROVE` requires no open Critical, High, or Medium findings. Low findings may remain but must be explicit. Do not approve based only on test results.