# Runtime Exposure Test-Seam Delivery Todo

- [x] Resolve FOCUS and MAC route stack.
- [x] Pass one-shot Mac capability gate.
- [x] Create dedicated worktree from current `origin/main`.
- [ ] Reproduce the 13 fixture failures with live production exposure state present.
- [ ] Add focused failing tests for explicit nil, allow, deny, and surface separation.
- [ ] Add immutable gate injection to `RegistrySkillsCommandProvider`.
- [ ] Add explicit-gate helper to `SkillsModule.mergedRoutingSkills`.
- [ ] Update affected fixtures without mutating production exposure state.
- [ ] Run focused tests and Runtime Exposure authority tests.
- [ ] Run debug build, full fresh-process suite, and `git diff --check`.
- [ ] Run detached read-only independent review.
- [ ] Reconcile floor only from a zero-failure run; run `make test-floor`.
- [ ] Commit once and rerun clean exact-SHA verification.
- [ ] Finalize receipt and stop at Ship Gate.

## Boundaries

No C0 ownership source changes. No production exposure policy changes. No mutation of the production active generation or emergency denylist. No merge, push, install, release, tag, reset, clean, stash, branch switch, or worktree deletion.

## Baseline reproduction — 2026-07-29 14:20 CDT

- Job: `20260729-191559249-2d470fb2`
- Result: `3488 passed, 13 failed, 3501 total`
- Branch/base: `task/runtime-exposure-test-seam` at `e0a49bc409c4f649d555556dd6883a814fe3d01e`
- The 13 failures are the expected command-provider and merged-routing fixture failures caused by shared Runtime Exposure state.
- [x] Reproduce the 13 fixture failures with live production exposure state present.

## Implementation checkpoint — 2026-07-29

- [x] Add focused failing tests for explicit nil, allow, deny, and surface separation.
- [x] Add immutable gate injection to `RegistrySkillsCommandProvider` while preserving all production initializer signatures and shared-gate behavior.
- [x] Add explicit-gate helper to `SkillsModule.mergedRoutingSkills` while preserving the public zero-argument production function.
- [x] Update affected fixtures without mutating production exposure state.
- [x] Run debug build.
- [x] Run full fresh-process suite: job `20260729-192626165-4e2127ed`, `3504 passed, 0 failed, 3504 total`.
- [x] Verify `git diff --check` passed.
- [x] Verify no C0 ownership source or evidence path is present in this remediation.

## Independent review and floor checkpoint

- [x] Run detached read-only independent review: job `20260729-193029419-9840717c`, verdict `APPROVE`, no Critical/High/Medium/Low findings.
- [x] Reconcile the test floor from `3482` to the measured green count `3504`.
- [x] Append floor provenance describing 13 restored fixtures plus 3 new policy tests.
- [ ] Run `make test-floor` with the reconciled floor.

## Floor gate result

- [x] Run `make test-floor`: job `20260729-193357712-4180571f`, `3504 passed, 0 failed, 3504 total`; `passed=3504 >= floor=3504`.
- [ ] Create the single local commit.
- [ ] Rerun debug build, full harness, `make test-floor`, and diff/status checks from the clean exact SHA.
- [ ] Finalize the external Ship Gate receipt; do not merge, push, install, tag, or release.
