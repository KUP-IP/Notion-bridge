> **Historical evidence — superseded.** This file records an earlier C0 candidate, review, or blocker and is retained for provenance only. It does **not** describe the current candidate on base `850d58aca71ddf28ff6010bc334121b6936555ef`. Current authority is `c0-implementation-receipt.md`, `c0-delivery-todo.md`, and the externally retained 2026-07-30 review/test receipts.

# C0 Final Transactional Re-review Result

- Job: `20260729-155517186-57595370`
- Reviewer: Codex CLI 0.144.6, detached
- Approval policy: never
- Sandbox: read-only
- Exit: 0
- Verdict: `APPROVE`

## Critical

None.

## High

None.

## Medium

None.

## Low

- The documented same-EUID namespace-replacement limitation remains: a hostile local process can replace the lock-directory pathname before a later opener reaches it. Held permits remain bound to the retained verified directory FD; later opens fail closed rather than join the replaced namespace. This is Low under the stated ordinary Bridge-process threat model.

## Reviewer conclusion

The v3 identity uses APFS creation-relevant metadata for both Git administrative directories, materially addressing pathname, symlink, move, branch-switch, and remove/recreate reuse. Lock acquisition, post-lock identity/claim validation, lease-counted nested dispatch, TTL admission, and supported target resolution satisfy the stated C0 boundary.

## Evidence reviewed

- Clean current-main baseline job `20260729-132948421-dbd8f37a`: 3488 passed, 13 failed, 3501 total.
- Final candidate job `20260729-155042655-4f39fb5a`: 3537 passed, 13 failed, 3550 total.
- Same 13 baseline Runtime Exposure / skills-registry failures only.
- C0: 49/49 passed, zero failures.
- `git diff --check`: pass.
- Base/HEAD and `origin/main`: `e0a49bc409c4f649d555556dd6883a814fe3d01e`.

## Disposition

No source changes occurred while review was active. The candidate remains intentionally uncommitted and dirty. No push, merge, install, tag, release, packet promotion, or Ship Gate transition occurred.
