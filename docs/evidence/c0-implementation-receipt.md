# C0 Implementation Receipt — Precommit Reviewed Source

## Candidate identity

- Packet: `3abcbb58-889e-814a-a55e-c1880bbe34d0`
- Worktree: `/Users/keepup/Developer/worktrees/the-bridge/c0-runtime-worktree-ownership-current-main`
- Branch: `packet/c0-runtime-worktree-ownership-current-main`
- Base / HEAD / `origin/main` before commit: `850d58aca71ddf28ff6010bc334121b6936555ef`
- Runtime Exposure prerequisite: `30bf9a8c5ec3b825ce8e962c686cae9bb5618e04`, verified ancestor. Its product source and tests are untouched; the shared `scripts/test-floor-gate.sh` and append-only history are the only intentional overlap, required for `3504 → 3553` floor reconciliation.

## Delivered behavior

- Public `worktree_claim` and `worktree_release` tools persist a canonical Git-worktree tuple in a dedicated SQLite/WAL ledger.
- Stable identity derives from the common and per-worktree Git administrative filesystem identities, distinguishing linked worktrees while collapsing symlink and lexical path aliases.
- Same-path claims are atomic across processes; a foreign live owner is rejected while separate worktrees in one repository remain concurrently usable.
- Claim acquisition re-probes the canonical repo/worktree/branch/HEAD after acquiring the C0 lock; a new claim persists only the locked live tuple, while exact same-owner retries remain idempotent after legitimate later commits.
- Expiry creates stale metadata only. Claim, expiry, recovery, and release never reset, clean, stash, switch, delete, or edit the worktree.
- Release records evidence-backed disposition and append-only history.
- `ToolRouter` acquires ownership authorization immediately before the registered handler and holds exclusion through nested authorized dispatch.

## Mutation coverage

- Direct: `git_apply_patch`, `git_create_branch`, file edit/write/append/move/rename/copy, directory creation, zip, and unzip.
- Command execution: `shell_exec` and `bg_run` analyze the complete statically resolvable target union before startup; governed background execution is denied before process artifacts are created.
- Git: effective `-C`, `--git-dir`, `--work-tree`, environment/config paths, worktree operands, and mutating verbs.
- Shell: command chains, output redirection, ordinary mutation commands, wrappers, directory transitions, direct executable paths, and bash/sh/zsh script operands.
- Interpreter stdin: only a static `< file` source is accepted and authorized; ambient, pipe-fed, dynamic, malformed, heredoc/here-string, and descriptor forms fail closed.
- Build/promotion: SwiftPM paths and Make/Just directory controls; GNU Make resolves every relative Makefile against the final sequential `-C`/`--directory` result regardless of argument order.
- Opaque `run_script`: registered for API compatibility but always fails before handler invocation because arbitrary script effects cannot prove a complete worktree target set. `shell_exec` is the supported verifiable alternative.
- Dedicated read-only Git and dry-run edit/patch operations remain claim-free.

## Verification

- Isolated source run: `3553 passed, 0 failed, 3553 total`; C0 `49/49` — `/Users/keepup/Library/Logs/TheBridge/c0-current-main/c0-claim-reprobe-fix-20260730T124508Z.log`
- Corrected-source floor: `3553 passed, 0 failed`; floor `3553` — `/Users/keepup/Library/Logs/TheBridge/c0-current-main/c0-claim-reprobe-floor-20260730T124915Z.log`
- Independent source/test review: **APPROVE**, zero Critical/High/Medium/Low findings — `/Users/keepup/Library/Logs/TheBridge/c0-current-main/c0-source-review-toctou-20260730T125315Z.log`
- Frozen source patch SHA-256: `b6be5c903c9bb2201bf5c55d023d0af37548f0c2ff55e24a24f9f54fd102dcef`
- Frozen source manifest SHA-256: `1ea1c2ee24016afbddc281e340975561194cb5a8df623b68513e35dd4eefb900`
- Raised floor: `3504 → 3553`
- Raised-floor verification: `3553 passed, 0 failed`, floor `3553` — `/Users/keepup/Library/Logs/TheBridge/c0-current-main/c0-claim-reprobe-floor-20260730T124915Z.log`
- `git diff --check`: passed.

## Current disposition

This receipt describes the complete precommit source candidate and proven floor. It intentionally does not claim a final commit SHA or complete-diff review verdict. Those are produced externally after the complete intended repository diff is frozen and approved. C0 remains FOCUS until exact-SHA verification succeeds.

No push, merge, install, tag, release, integration, destructive Git operation, or worktree cleanup occurred.
