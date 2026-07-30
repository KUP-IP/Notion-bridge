> **Historical evidence — superseded.** This file records an earlier C0 candidate, review, or blocker and is retained for provenance only. It does **not** describe the current candidate on base `850d58aca71ddf28ff6010bc334121b6936555ef`. Current authority is `c0-implementation-receipt.md`, `c0-delivery-todo.md`, and the externally retained 2026-07-30 review/test receipts.

# C0 Floor-Gate Blocker

Recorded: 2026-07-29 13:45 CDT

## Failing layer

Test contract / harness environment on current `origin/main`, outside the C0 ownership implementation.

## Reproduction

Command:

```sh
make test-floor
```

Durable job: `20260729-184022382-173524cb`

Expected: zero failing tests, then a passing count at or above the recorded floor.

Actual:

```text
Results: 3537 passed, 13 failed, 3550 total
```

The gate exited nonzero and retained the full log at:

```text
/Users/keepup/Library/Logs/TheBridge/test-floor-failures/test-floor-20260729T184253Z-7060.log
```

All `49/49` C0 tests passed. The 13 failures are the same current-main Runtime Exposure / skills-registry baseline failures previously reproduced on a clean checkout.

## Isolation and eliminations

- C0 source regression eliminated: all C0 tests passed.
- Branch drift eliminated: candidate HEAD and `origin/main` were both `e0a49bc409c4f649d555556dd6883a814fe3d01e` before commit; ahead/behind `0/0`.
- Transport failure eliminated: the durable test job completed normally and returned its exit code and complete log.
- Live-home contamination alone eliminated: the failing command-palette tests seed named isolated `UserDefaults` suites.
- Random scheduler failure eliminated: the same 13 failures recur on clean current main.

## Root cause

Runtime Exposure authority added a process-global dependency that the older tests do not isolate:

- `RegistrySkillsCommandProvider.descriptors()` reads its injected registry blob but then consults `SkillRuntimeGenerationStore.shared.gate()`.
- `SkillsModule.mergedRoutingSkills()` also consults the shared exposure generation.
- The failing tests inject registry rows but do not inject or neutralize the exposure gate, so valid fixture page IDs are filtered to an empty result when the machine has an active generation.

The tests' stated “zero process-global coupling” contract is therefore no longer true after current-main commits `1b7d907` / `920aa03`.

## Required remediation

Choose and verify one current-main fix outside C0:

1. Inject an exposure-gate provider into `RegistrySkillsCommandProvider` and the merged-routing test seam; tests supply an explicit allow-all or isolated gate. **Recommended.**
2. Give tests an isolated `SkillRuntimeGenerationStore` rooted in a temporary directory and route the tested APIs through it.
3. Rewrite fixtures to publish a matching temporary generation, with reliable restoration of global state.

Acceptance condition:

- The 13 named skills-registry tests pass in a fresh process both with and without a live production exposure generation.
- `make test-floor` reports zero failures on current main.
- C0 is then resumed without changing its reviewed ownership source, floor is reconciled to the resulting green count, the candidate is committed, and exact-SHA verification runs.

## Disposition

No floor change or commit was made. C0 remains preserved, dirty, and uncommitted. No push, merge, install, tag, release, reset, clean, stash, branch switch, or worktree deletion occurred.
