> **Historical evidence — superseded.** This file records an earlier C0 candidate, review, or blocker and is retained for provenance only. It does **not** describe the current candidate on base `850d58aca71ddf28ff6010bc334121b6936555ef`. Current authority is `c0-implementation-receipt.md`, `c0-delivery-todo.md`, and the externally retained 2026-07-30 review/test receipts.

# C0 Transactional Review Result — First Pass

- Job: `20260729-133648981-0556cf73`
- Reviewer: Codex CLI 0.144.6, detached, ephemeral, `-a never -s read-only`
- Exit: 0
- Verdict: `REJECT`

## Findings

### Critical

None.

### High — disputed as outside the approved C0 boundary

The reviewer demonstrated that an arbitrary interpreter can conceal an external mutation in a code string, for example Perl launched from owned worktree A writing to unowned worktree B. The approved contract explicitly excludes proving arbitrary shell commands read-only and excludes hidden behavior in arbitrary scripts, interpreters, and binaries. C0 governs the execution worktree plus supported statically resolved control and mutation targets; it is not an interpreter sandbox. This finding is carried as an explicit product limitation, not silently remediated by banning unknown executables.

### Medium — remediated

1. Stable identity based only on `(device,inode)` could collide after inode reuse.
   - Remediation: stable identity v3 includes filesystem device, inode, filesystem generation (`st_gen`), and birth timestamp for both the common Git directory and worktree Git administrative directory.
   - Branch switches and worktree moves retain identity; remove/recreate produces a new creation identity.

2. Lock-directory path validation had a TOCTOU window.
   - Remediation: open and retain a verified `O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC` directory FD, validate type/euid via `fstat`, secure via `fchmod`, and open lock files with `openat` relative to that FD.
   - Lock files must be regular, same-euid, mode 0600, and link count 1.

## Additional hardening found during remediation

- Released TaskLocal permits are inactive, preventing inherited child tasks from using a permit after handler completion.
- Known Git path environment controls (`GIT_DIR`, `GIT_WORK_TREE`, `GIT_COMMON_DIR`, `GIT_INDEX_FILE`, `GIT_OBJECT_DIRECTORY`) are statically resolved and authorized; dynamic values fail unresolved.
- Concurrent first creation of a lock file uses open-existing / `O_EXCL` create / retry-on-`EEXIST`; a standalone two-process stress reproduced the prior macOS `ENOENT` race and the corrected sequence passed 100/100 races.
