# Runtime Exposure Hermetic Test-Seam Implementation Receipt

## Objective

Make registry-projection tests independent of live machine Runtime Exposure state without changing default production enforcement.

## Source tuple before commit

- Worktree: `/Users/keepup/Developer/worktrees/the-bridge/runtime-exposure-test-seam`
- Branch: `task/runtime-exposure-test-seam`
- Base/HEAD/origin-main: `e0a49bc409c4f649d555556dd6883a814fe3d01e`

## Implemented

- `RegistrySkillsCommandProvider` now carries an asynchronous gate reader.
  - Every existing production initializer retains its signature and dynamically resolves `SkillRuntimeGenerationStore.shared.gate()`.
  - `@_spi(Testing)` overloads accept an explicit immutable `SkillRuntimeExposureGate?`.
- `SkillsModule.mergedRoutingSkills()` retains its public zero-argument production behavior and delegates to an `@_spi(Testing)` explicit-gate helper.
- A shared test support file constructs real Runtime Exposure generation/gate values.
- Affected command and routing fixtures now state their exposure context explicitly.
- New tests prove:
  - explicit `nil` is hermetic from the host generation;
  - command projection includes `.command` and excludes `.routing`;
  - routing projection includes `.routing` and excludes `.command`.
- Test floor reconciled from `3482` to `3504` with append-only provenance.

## Boundaries preserved

- No Runtime Exposure compiler, policy, storage, publication, rollback, expiry, or emergency-denylist change.
- No exact-fetch, body-cache, specialist, or filesystem-skill behavior change.
- No production exposure state was mutated by tests.
- No C0 ownership source or evidence was included.
- No merge, push, install, release, tag, reset, clean, stash, branch switch, or worktree deletion.

## Verification before commit

- Baseline job `20260729-191559249-2d470fb2`: `3488 passed, 13 failed, 3501 total`.
- Candidate job `20260729-192626165-4e2127ed`: `3504 passed, 0 failed, 3504 total`.
- Independent read-only review job `20260729-193029419-9840717c`: **APPROVE**, no Critical/High/Medium/Low findings.
- Reconciled floor job `20260729-193357712-4180571f`: `3504 passed, 0 failed, 3504 total`; `passed=3504 >= floor=3504`.
- Debug build passed.
- `git diff --check` passed.

## Exact-SHA evidence location

The single source commit cannot contain its own Git SHA. The clean exact-SHA verification and final disposition are recorded in the external Execute/Ship Gate receipt after this immutable commit is created. No evidence-only follow-up commit is permitted.
