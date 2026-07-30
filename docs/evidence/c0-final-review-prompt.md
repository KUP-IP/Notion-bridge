# C0 Complete-Diff Independent Review Contract

Review the frozen complete intended C0 commit in read-only mode. The externally supplied patch and manifest are authoritative and include source, tests, floor, and evidence. Do not edit, stage, commit, install, push, merge, reset, clean, stash, switch branches, or delete anything. Do not apply the patch to the already-modified candidate tree.

## Identity

- Worktree: `/Users/keepup/Developer/worktrees/the-bridge/c0-runtime-worktree-ownership-current-main`
- Branch: `packet/c0-runtime-worktree-ownership-current-main`
- Base / HEAD / `origin/main`: `850d58aca71ddf28ff6010bc334121b6936555ef`
- Runtime Exposure prerequisite: `30bf9a8c5ec3b825ce8e962c686cae9bb5618e04`

## Source approval already obtained

- Source patch SHA-256: `b6be5c903c9bb2201bf5c55d023d0af37548f0c2ff55e24a24f9f54fd102dcef`
- Source manifest SHA-256: `1ea1c2ee24016afbddc281e340975561194cb5a8df623b68513e35dd4eefb900`
- Source review: `/Users/keepup/Library/Logs/TheBridge/c0-current-main/c0-source-review-toctou-20260730T125315Z.log`
- Verdict: APPROVE; zero Critical, High, Medium, or Low findings.

## Current evidence

- Source test: `/Users/keepup/Library/Logs/TheBridge/c0-current-main/c0-claim-reprobe-fix-20260730T124508Z.log` — `3553 passed, 0 failed`; C0 `49/49`.
- Corrected-source floor: `/Users/keepup/Library/Logs/TheBridge/c0-current-main/c0-claim-reprobe-floor-20260730T124915Z.log` — `3553 passed, 0 failed`, floor `3553`.
- Raised-floor gate: `/Users/keepup/Library/Logs/TheBridge/c0-current-main/c0-claim-reprobe-floor-20260730T124915Z.log` — `3553 passed, 0 failed`, floor `3553`.

## Required complete-diff inspection

1. Recompute the externally supplied complete patch and manifest hashes and every per-file hash.
2. Confirm the current tree contains exactly the manifest files and `git diff --check` passes.
3. Confirm the source portion remains byte-identical to the approved source manifest.
4. Confirm the floor change is exactly `3504 → 3553`, the history is append-only, and retained evidence proves 3553 green tests.
5. Confirm current evidence makes no future commit-SHA or unproduced final-review claim.
6. Confirm every superseded C0 evidence file is explicitly marked historical and cannot be mistaken for current authority.
7. Confirm no Runtime Exposure product source or test path changed. The only approved prerequisite-path overlap is `scripts/test-floor-gate.sh` and `scripts/test-floor-gate-history.md`, exactly for the measured `3504 → 3553` floor update.
8. Inspect for any Critical, High, or Medium correctness, security, compatibility, evidence-integrity, or audit-chain defect.

## Verdict rule

Return APPROVE only with zero Critical, High, or Medium findings. Every finding must include file:line, impact, and a bounded correction.

Output:

- `VERDICT: APPROVE` or `VERDICT: REJECT`
- Critical / High / Medium / Low
- Artifact and source-manifest verification
- Floor/evidence verification
- Runtime Exposure source/test and approved shared-floor overlap verification
- Residual risks or explicit deferrals
