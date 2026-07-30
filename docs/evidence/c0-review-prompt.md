> **Historical evidence — superseded.** This file records an earlier C0 candidate, review, or blocker and is retained for provenance only. It does **not** describe the current candidate on base `850d58aca71ddf28ff6010bc334121b6936555ef`. Current authority is `c0-implementation-receipt.md`, `c0-delivery-todo.md`, and the externally retained 2026-07-30 review/test receipts.

# C0 Independent Review Instructions

Review the uncommitted C0 candidate in:

- worktree: `/Users/keepup/Developer/worktrees/the-bridge/c0-runtime-worktree-ownership`
- branch: `packet/c0-runtime-worktree-ownership`
- base: `01fd3984b91ca3c9e3ff16160d2a80a3d42f6261`

Do not edit files, commit, push, install, reset, clean, stash, switch branches, or mutate external state. Inspect `git diff`, source, tests, `docs/evidence/c0-guarded-operation-inventory.md`, and the packet contract below. Return a severity-ranked review with exact file/line evidence. If no material findings remain, state APPROVE.

## Contract to audit

1. Add durable public `worktree_claim` and `worktree_release` operations.
2. Claim identity includes canonical repoRoot, canonical worktreePath, branch, exact starting baseSHA, ownerSession, and bounded expiry.
3. Canonical worktree path is the atomic conflict key. Same-owner/same-tuple retry is idempotent and does not extend expiry. Different live owner is rejected. Distinct worktrees under one repository can be owned concurrently.
4. Acquisition is atomic across concurrent tasks/processes and persisted in a domain-specific SQLite/WAL store under BridgePaths/Application Support.
5. Symlink and path normalization cannot create duplicate ownership identities.
6. Missing ownership, foreign ownership, expiry, branch drift, path drift, repo-root drift, or base-history drift fail before protected mutation with stable codes; identity drift uses `worktree_identity_changed`.
7. Read-only Git (`git_status`, `git_diff`, `git_log`, `git_show`, `git_blame`) remains usable without a claim.
8. Consequential current mutations are guarded through one auditable seam: direct Git mutations, file edits/writes/moves/copies/archive outputs inside worktrees, shell/background Git mutations, and source install/promotion commands.
9. Cross-worktree operations authorize every repository they can mutate.
10. Expiry never grants automatic takeover. Expired claims remain stale metadata until explicit owner recovery.
11. Release dispositions are evidence-backed: clean/releasable, preserve for review, preserve with unique commits, abandoned with recovery note.
12. Claim/release/expiry/recovery never delete, reset, clean, switch, stash, or edit worktree files/Git. Release evidence/history remains durable across later claims.
13. Tool schemas expose ownerSession where required, annotations are truthful, and static tool count is correct.
14. Existing read-only behavior and unrelated suite behavior are preserved.
15. No install, integration, merge, push, release, tag, automatic worktree deletion, distributed locking, or Packet Runner orchestration is introduced.

## Review focus

- SQLite transaction correctness, busy/race behavior, schema migration, and evidence retention.
- Exact live Git identity derivation for primary and linked worktrees.
- Claim/base semantics and post-commit authorization.
- Shell/background classifier bypasses, command chains, `-C`, `cd`, wrappers, and multi-repo mutations.
- Direct file/archive target coverage and argument-name accuracy.
- ToolRouter ordering relative to license/governance/security approval and auditing.
- Release disposition validation and stale recovery.
- Test adequacy, false positives/false negatives, and untested high-risk paths.
- Any Critical/High/Medium defects or contract deltas.

Output format:

- Findings, ordered Critical → High → Medium → Low, each with file/line and concrete failure scenario.
- Contract coverage summary.
- Verdict: APPROVE, APPROVE WITH REQUIRED FIXES, or REJECT.
