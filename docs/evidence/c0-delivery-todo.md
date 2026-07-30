# C0 Delivery Todo — Current Candidate

Packet: `3abcbb58-889e-814a-a55e-c1880bbe34d0`
Worktree: `/Users/keepup/Developer/worktrees/the-bridge/c0-runtime-worktree-ownership-current-main`
Branch: `packet/c0-runtime-worktree-ownership-current-main`
Base / current `origin/main`: `850d58aca71ddf28ff6010bc334121b6936555ef`

## Completed

- [x] Preserve the dedicated current-main worktree and verify exact base, branch, prerequisite ancestry, and changed-path scope; Runtime Exposure product source/tests are untouched and only the shared floor gate/history intentionally overlap.
- [x] Implement durable canonical worktree claim/release, cross-process exclusion, evidence-preserving release, and pre-handler execution permits.
- [x] Govern direct Git, file, code-edit, archive, shell, background, build, promotion, and installation-command targets while preserving dedicated read-only operations.
- [x] Close direct and interpreted script-path authorization, wrapper working-directory propagation, GNU Make final-directory semantics, and static shell-stdin authorization.
- [x] Fail closed for opaque `run_script` execution; handler invocation is impossible until a verifiable target contract exists.
- [x] Close claim live-tuple TOCTOU by re-probing repo/worktree/branch/HEAD after lock acquisition; deterministic branch/HEAD interleavings persist no claim.
- [x] Pass isolated source verification: `3553 passed, 0 failed, 3553 total`; C0 `49/49`.
- [x] Pass corrected-source floor verification: `3553 passed, 0 failed` at floor `3553`.
- [x] Obtain independent source/test review: **APPROVE**, zero Critical/High/Medium/Low findings.
- [x] Raise the repository floor `3504 → 3553` with append-only provenance.
- [x] Pass the raised floor gate: `3553 passed, 0 failed`, floor `3553`.
- [x] Classify current versus historical C0 evidence.

## Remaining before REVIEW

- [ ] Freeze the complete intended commit, including source, tests, floor, and evidence.
- [ ] Obtain independent read-only review of that exact complete diff with zero Critical/High/Medium findings.
- [ ] Create exactly one local commit without changing the reviewed tree.
- [ ] Verify the committed tree matches the reviewed manifest.
- [ ] Run isolated exact-SHA `make test` and `make test-floor`; require `3553/0/3553`.
- [ ] Verify clean tree, commit-range `git diff --check`, and no Runtime Exposure overlap.
- [ ] Rehydrate C0, confirm it is still FOCUS, transition only C0 to REVIEW, and verify downstream statuses unchanged.

## Authoritative receipts

- Source artifact patch SHA-256: `b6be5c903c9bb2201bf5c55d023d0af37548f0c2ff55e24a24f9f54fd102dcef`
- Source artifact manifest SHA-256: `1ea1c2ee24016afbddc281e340975561194cb5a8df623b68513e35dd4eefb900`
- Source test: `/Users/keepup/Library/Logs/TheBridge/c0-current-main/c0-claim-reprobe-fix-20260730T124508Z.log`
- Corrected-source floor: `/Users/keepup/Library/Logs/TheBridge/c0-current-main/c0-claim-reprobe-floor-20260730T124915Z.log`
- Source review: `/Users/keepup/Library/Logs/TheBridge/c0-current-main/c0-source-review-toctou-20260730T125315Z.log`
- Raised-floor verification: `/Users/keepup/Library/Logs/TheBridge/c0-current-main/c0-claim-reprobe-floor-20260730T124915Z.log`

## Hard boundaries

No push, merge, installation, integration into `main`, tag, release, reset, clean, stash, branch switch, worktree deletion, or destructive recovery is authorized.
