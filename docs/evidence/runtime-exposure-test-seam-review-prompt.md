# Independent Review — Runtime Exposure Hermetic Test Seam

## Reviewer mandate

Perform a read-only, diff-first review of the exact dirty candidate in:

`/Users/keepup/Developer/worktrees/the-bridge/runtime-exposure-test-seam`

Inspect tracked and untracked files. Do not modify the worktree, run formatters, create commits, change branches, or alter production Runtime Exposure state.

Return exactly one verdict: `APPROVE` or `REJECT`.

List findings by severity: Critical, High, Medium, Low. Approval requires no open Critical, High, or Medium findings.

## Objective

Restore a truthful zero-failure test floor by making Runtime Exposure filtering explicit and injectable at the two affected registry-projection boundaries, without changing default production behavior or the independently approved C0 ownership source.

## Approved scope

- `RegistrySkillsCommandProvider`: production initializers retain signatures and dynamically resolve `SkillRuntimeGenerationStore.shared.gate()`; SPI testing paths accept an explicit immutable `SkillRuntimeExposureGate?`.
- `SkillsModule.mergedRoutingSkills()`: public production function resolves the shared gate and delegates to an SPI helper accepting an explicit gate value.
- Affected registry projection fixtures explicitly supply `nil` or a constructed gate.
- Tests prove nil isolation and command/routing allow-deny surface separation.
- No production exposure policy, compiler, generation store, promotion, rollback, denylist, exact-fetch, body-cache, specialist, C0 ownership, or filesystem-skill behavior change.

## Required checks

1. Production defaults cannot accidentally disable Runtime Exposure enforcement.
2. Explicit gate injection is limited to SPI/test surfaces and introduces no mutable global override.
3. `nil` retains the intended pre-generation compatibility behavior; non-nil gates enforce the correct command/routing surfaces.
4. Tests do not mutate the production active generation, generation files, or emergency denylist.
5. Existing fixture semantics—disabled rows, blank IDs, legacy decoding, ordering, file-source routing, shadows, and sorting—remain intact.
6. Swift concurrency and `Sendable` behavior are sound.
7. No C0 ownership source or evidence is included.
8. Scope is the smallest true fix; flag any unnecessary public API or broad refactor.

## Evidence

Baseline unmodified current-main run:
- Job `20260729-191559249-2d470fb2`
- `3488 passed, 13 failed, 3501 total`

Candidate run with live production exposure state still present:
- Job `20260729-192626165-4e2127ed`
- `3504 passed, 0 failed, 3504 total`

Additional checks:
- Debug build passed.
- `git diff --check` passed.
- No C0 path appears in `git status`.
- Base/HEAD before commit: `e0a49bc409c4f649d555556dd6883a814fe3d01e` (`origin/main`).

## Changed files expected

Production:
- `TheBridge/Modules/Commands/RegistrySkillsCommandProvider.swift`
- `TheBridge/Modules/Skills/SkillsModuleFileSource.swift`

Tests:
- `TheBridgeTests/SkillExposureProjectionTestSupport.swift`
- `TheBridgeTests/CommandPaletteTests.swift`
- `TheBridgeTests/CommandVisibilityTests.swift`
- `TheBridgeTests/FlagVisibilityMigrationTests.swift`
- `TheBridgeTests/ListRoutingSkillsMergeTests.swift`

Evidence only:
- `docs/evidence/runtime-exposure-test-seam-todo.md`
- this review prompt

## Output format

```text
VERDICT: APPROVE|REJECT

Critical
- ... or None

High
- ... or None

Medium
- ... or None

Low
- ... or None

Scope assessment
- ...

Evidence assessment
- ...
```
