> **Historical evidence — superseded.** This file records an earlier C0 candidate, review, or blocker and is retained for provenance only. It does **not** describe the current candidate on base `850d58aca71ddf28ff6010bc334121b6936555ef`. Current authority is `c0-implementation-receipt.md`, `c0-delivery-todo.md`, and the externally retained 2026-07-30 review/test receipts.

# C0 Final Independent Re-review — Transactional Worktree Ownership

You are an independent read-only security and correctness reviewer. Review the complete current uncommitted diff in this worktree. Do not edit files, install, commit, push, merge, tag, release, change packet state, or run destructive Git commands.

## Exact source under review

- Worktree: `/Users/keepup/Developer/worktrees/the-bridge/c0-runtime-worktree-ownership-v2`
- Branch: `packet/c0-runtime-worktree-ownership-v2`
- Base/HEAD: `e0a49bc409c4f649d555556dd6883a814fe3d01e`
- `origin/main`: `e0a49bc409c4f649d555556dd6883a814fe3d01e`
- Candidate is intentionally uncommitted and dirty.
- `git diff --check` passes.

## Authoritative scope boundary

C0 is a **worktree ownership and concurrency control**, not an arbitrary-language sandbox.

It guarantees that a Bridge foreground mutation cannot start until ownership is verified for:

1. every statically resolved Git worktree in which a supported shell segment executes;
2. every supported explicit mutation/control target inside a Git worktree;
3. every declared direct-tool mutation target governed by the policy below.

It intentionally does **not** prove arbitrary scripts, interpreters, plugins, compilers, binaries, network services, or code strings read-only. Hidden side effects in arbitrary executables are OUT OF SCOPE. Unknown foreground commands remain permitted when their execution worktree and all supported statically resolved targets are owned. Do not classify examples such as Perl/Python/Ruby code strings hiding an undeclared external write as an implementation defect; they are the explicit non-sandbox limitation. You may state that limitation as Low/informational, but it is not a Critical/High/Medium rejection basis.

Still review aggressively for bypasses through **supported/static control surfaces**, including shell working directories, tool `env`, `cd`, redirection, known mutation commands, Git options/config/environment variables, build-tool directory/output options, `env`/`sudo` chdir wrappers, nested shells, direct tool arguments, and any route that claims to be governed.

## Required contract

### 1. Stable worktree identity

- Identity must survive symlink aliases, branch switches, and `git worktree move`.
- Remove/recreate at the same pathname must produce a new identity.
- The current v3 identity combines, for both the common Git directory and worktree Git administrative directory:
  - filesystem device;
  - inode;
  - filesystem generation (`st_gen`);
  - birth timestamp seconds and nanoseconds.
- Path, branch, repo root, and base SHA remain provenance, not mutex identity.
- Assess whether this is an equivalent non-reusable filesystem creation identity on supported macOS/APFS, including generation/birth semantics and practical wrap/collision risk.

### 2. Transactional authorization

- Foreground mutating handlers hold one permit from final post-lock identity/claim validation through handler completion.
- Claim and release contend on the same per-worktree lock.
- Same-process tasks and independent Bridge processes exclude correctly.
- Multiple identities lock in deterministic order; partial acquisition unwinds.
- Distinct worktrees remain concurrent.
- A permit admitted before TTL expiry may finish; no new permit starts after expiry.
- Thrown/cancelled handlers release authorization.

### 3. Nested dispatch and lease lifetime

- TaskLocal permit reuse is allowed only for the same owner and a subset of held stable identities.
- Every nested dispatch receives a distinct `WorktreeExecutionAuthorization` lease.
- The root authorization may close admission, but physical/process locks must remain held until every already-admitted nested authorization completes and releases.
- A released/closed root permit cannot admit a later inherited child task.
- Nested widening to another worktree must fail before handler invocation.
- Review atomicity and double-release/deinit behavior of `rootReleased`, `nestedAuthorizationCount`, and resource teardown.

### 4. Lock storage

- The lock directory is opened and retained with `O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC`.
- Type and effective-user ownership are checked with `fstat`; mode is forced to 0700 with `fchmod`.
- Lock files are opened relative to the retained directory FD using `openat`.
- Existing/opened lock files must be regular, effective-user-owned, mode 0600, and link count 1.
- Symlinked directory/file and hard-linked file cases fail closed.
- Concurrent first creation uses open-existing → `O_CREAT|O_EXCL` → retry on `EEXIST`; no path-based reopen occurs.
- Stale ordinary lock files are harmless.
- Assess intermediate-directory assumptions and whether any replacement can split exclusion after the directory FD is held.

### 5. Shell and background closure

- `env -S`, `env --split-string`, and attached forms fail as `worktree_target_unresolved`.
- Known Git path environment variables are resolved and governed both when written inline in the command and when supplied through `shell_exec.env`/`bg_run.env`:
  - `GIT_DIR`
  - `GIT_WORK_TREE`
  - `GIT_COMMON_DIR`
  - `GIT_INDEX_FILE`
  - `GIT_OBJECT_DIRECTORY`
- Git administrative files/directories resolve to the affected worktree rather than being treated as executable working directories.
- Dynamic/non-string values for supported path controls fail unresolved.
- `git -c core.worktree=<absolute static path>` and attached `-ccore.worktree=...` are governed; relative/dynamic `core.worktree` controls fail unresolved.
- `git --config-env` for `core.worktree` fails unresolved because the path is indirect.
- SwiftPM path controls are governed in split and attached forms:
  - `--package-path`
  - `--scratch-path`
  - `--build-path`
  - `--cache-path`
  - `--config-path`
  - `--security-path`
- `bg_run` executing in or targeting any governed worktree fails before child/job/log/done creation as `worktree_background_unsupported`.
- Foreground `shell_exec` is the supported governed path.

### 6. Direct copy/archive policy

This is intentional and must be judged as written:

- `file_copy`: destination is the mutation target; source is read-only.
- `file_zip`: archive output is the mutation target; source inputs are read-only.
- `file_unzip`: extraction destination is the mutation target; input archive is read-only.
- A source requires ownership only if another declared operation mutates it.

### 7. Compatibility and safety

- Dedicated proven read-only Git/file tools stay claim-free.
- Unknown foreground commands remain usable when governed execution/static targets are owned.
- Claim expiry/release never resets, cleans, stashes, switches, deletes, or edits user work.
- No install, integration, push, tag, or release behavior is introduced.

## Prior review findings and remediation

### First review — job `20260729-133648981-0556cf73`

1. High: arbitrary interpreter code could hide an external write.
   - Disposition: outside the authoritative scope above; no sandbox expansion.
2. Medium: `(device,inode)` identity reuse.
   - Remediated by v3 generation + birth identity.
3. Medium: path-based lock-directory TOCTOU.
   - Remediated by retained verified directory FD + `openat`.

Additional first-round remediation:

- inactive released permits close TaskLocal escape;
- supported inline Git environment paths are governed;
- hard-linked lock files are refused;
- concurrent first-open `ENOENT` was reproduced and corrected with the `O_EXCL` convergence sequence.

### Second re-review — job `20260729-140749198-514a4eec`

1. High: nested dispatch reused the same permit without retaining a lease, allowing the outer dispatch to release exclusion while a nested handler still ran.
   - Remediated by lease-counted `WorktreeExecutionAuthorization` objects. Root release defers physical/process lock teardown until all admitted nested authorizations release.
2. Medium: Git path variables passed through `shell_exec.env` were not analyzed.
   - Remediated by merging tool-environment analysis with command analysis and mapping Git administrative paths to affected worktrees.
3. Medium: `git -c core.worktree=...` was not governed.
   - Remediated for split and attached static absolute forms; relative and indirect/dynamic forms fail unresolved.
4. Medium: SwiftPM package and output directory controls were not governed.
   - Remediated for the supported package, scratch, build, cache, config, and security path options.
5. Low: a same-EUID cooperating process could replace the lock directory pathname and create a namespace split.
   - This remains a documented local same-user integrity limitation. The held directory FD prevents replacement from redirecting an admitted permit, and replacement is detected/fails closed for later opens. Review whether this remains Low under the stated ordinary Bridge-process threat model.

### Third re-review — job `20260729-154533195-9cb859fb`

1. High: GNU `cp`/`mv` target-directory forms (`-t`, attached `-tDIR`, `--target-directory DIR`, and `--target-directory=DIR`) discarded the destination operand during authorization.
   - Remediated by explicit target-directory parsing. `cp` governs the destination only; `mv` governs all source operands plus the destination. Missing/empty target-directory operands fail as `worktree_target_unresolved`.
   - Regression coverage exercises split and attached short/long forms and malformed forms.

## Evidence

Clean current-main baseline:

- Job `20260729-132948421-dbd8f37a`
- `3488 passed, 13 failed, 3501 total`
- The 13 failures are Runtime Exposure / skills-registry command and routing tests.

Final candidate:

- Job `20260729-155042655-4f39fb5a`
- `3537 passed, 13 failed, 3550 total`
- Same 13 baseline failures only.
- All **49/49 C0 tests passed**; zero C0 failures.
- Standalone simultaneous first-open stress from the prior hardened run: **100/100 two-process claim races converged**.
- `git diff --check`: pass.

Superseded candidate runs `20260729-153622174-81925f8c` and `20260729-154002195-ff526cd8` were used to expose and close prior normalization and target-surface defects. Do not treat them as final evidence.

## Required inspection

Inspect at minimum:

- `TheBridge/Modules/WorktreeOwnership.swift`
- `TheBridge/Server/ToolRouter.swift`
- all C0-related module/schema edits
- `TheBridgeTests/WorktreeOwnershipTests.swift`
- relevant audit/meta/integration tests
- `docs/evidence/c0-transactional-review-result.md`
- `docs/evidence/c0-transactional-rereview-result.md`

Adversarially examine:

- final validation occurs after lock acquisition and before handler invocation;
- no mutation occurs outside root or nested authorization lifetime;
- root/nested lease accounting under concurrent completion, cancellation, thrown handlers, deinit, and double release;
- claim/release/expiry transaction ordering;
- process-local versus POSIX record-lock semantics;
- descriptor lifetime and TaskLocal inheritance;
- lock directory/file creation and replacement races;
- stable identity behavior for main/linked worktrees, alias, move, remove/recreate, filesystem generation and birth identity;
- supported shell/tool-env/Git/SwiftPM/build/wrapper targeting forms and dynamic rejection;
- direct-tool guarded inventory completeness;
- `bg_run` denial before every artifact/child side effect;
- validity of baseline-delta evidence.

## Output contract

Return exactly one verdict: `APPROVE` or `REJECT`.

Then list findings under Critical, High, Medium, and Low. For every Critical/High/Medium finding provide:

- exact file and line range;
- concrete failure/exploit sequence within the authoritative scope;
- why existing tests do not close it;
- smallest correct remediation.

`APPROVE` requires no open Critical, High, or Medium findings within the authoritative scope. Low findings and explicit limitations may remain.
