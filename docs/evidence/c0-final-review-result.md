> **Historical evidence — superseded.** This file records an earlier C0 candidate, review, or blocker and is retained for provenance only. It does **not** describe the current candidate on base `850d58aca71ddf28ff6010bc334121b6936555ef`. Current authority is `c0-implementation-receipt.md`, `c0-delivery-todo.md`, and the externally retained 2026-07-30 review/test receipts.

# C0 Final Independent Review Result

Review job: `20260729-040012206-cd32746a`
Mode: detached Codex, approval never, sandbox read-only, exact current uncommitted worktree
Exit: `0`
Verdict: **REJECT**

## Closed prior findings

Prior findings 1–10 were assessed CLOSED. The reviewer confirmed the wrapper, Git operand, direct-tool registration, multi-option shell, Git fail-closed, read-form, Git directory target, invalid repository, ordinary shell mutation, and standard wrapper-directory findings were addressed.

## Open High findings

1. **`env -S` authorization bypass**
   - The resolver treats `-S` as an option plus value and can skip the embedded command entirely.
   - Example: `env -C /foreign/worktree -S 'touch owned.txt'` may return no executable/target authorization.
   - Required direction: reject `env -S` as unresolved or parse its command string safely before process startup.

2. **Live tuple TOCTOU at claim and authorization**
   - `claim` obtains live identity before `BEGIN IMMEDIATE` and does not re-probe inside the transaction before insertion.
   - `authorize` obtains live identity before reading the ledger row and can race a branch switch; base ancestry alone does not prove the branch remained the recorded branch.
   - Required direction: redesign the transaction/verification sequence so the live tuple used for persistence or handler authorization cannot be invalidated by a concurrent worktree identity change.

3. **Direct copy/archive path policy is incomplete**
   - `file_copy` authorizes only `destinationPath`.
   - `file_zip` authorizes only `archivePath`.
   - `file_unzip` authorizes only `destinationPath`.
   - The independent review contract required both declared paths to be covered. Current inventory documents the narrower policy.

## Evidence before review

- Debug build passed.
- Fresh-process harness: `3514 passed, 0 failed, 3514 total`.
- `git diff --check` passed.
- Candidate remained uncommitted.

## Execution disposition

No source changes were made after the review began. No test-floor update, commit, push, merge, install, tag, release, packet promotion, or Ship Gate transition occurred.

The first finding fits the approved shell-remediation contract. Findings 2 and 3 reopen surfaces explicitly excluded from that contract: the claim-ledger transaction model and direct-tool path policy. They require a revised proposal before further implementation.
