# Calendar–Registry Candidate-Readiness Receipt

Status: **Candidate-Ready Source**. This is not a candidate build, install, activation, or live smoke receipt.

## Integrated source

- Base: current `origin/main` plus the six installed/review integration commits.
- Calendar line: the six reviewed Calendar–Registry commits from `3785605` through `a8d15ac`.
- Excluded: unrelated commit `21fc72c`.
- Conflict surface: append-only test-floor provenance and the numeric floor only; Calendar source merged without a content conflict.

## Safety contract

- Scope is one disabled, registry-first, single-machine transaction pairing one pre-existing Registry-authority Notion EVENT with at most one qualified private local EventKit item.
- One canonical local coordinator owns an OS advisory lock plus a SQLite transaction ledger. SQLite provides atomic compare-and-swap progression.
- Notion does not provide atomic compare-and-swap here. Each narrow pairing write uses optimistic fencing: a fresh `last_edited_time` expectation plus writer-token/read-back verification. A mismatch conflicts and preserves concurrent semantic edits.
- Every material success-path durable-write or EventKit-effect boundary has a package-scoped, production-no-op crash checkpoint. The test executable terminates a child process at each checkpoint and performs two fresh-process recoveries.
- Recovery never performs a second automatic create. Thirteen checkpoints recover to `Complete` with exactly one calendar item; the two gaps after Create Invocation reaches Notion but before complete ledger evidence stop at `Operator Review` with zero creates.
- The source-controlled registry prerequisite is schema version 3 and contains five fields: rich-text `Provider External ID`, `Operation Fingerprint`, `Calendar Create Invocation ID`, and `Sync Writer Token`, plus numeric `Sync Revision`.
- The local transaction ledger is schema version 4.

## Verification contract

Candidate readiness requires all of the following on one clean commit:

1. The focused Calendar–Registry matrix, including CR81–CR96, passes.
2. `make test-floor` passes without lowering the inherited floor.
3. `swift build -c release -Xswiftc -strict-concurrency=complete` succeeds.
4. `git diff --check` is clean and the unrelated commit remains outside the candidate graph.
5. The installed application and live EVENTS schema remain unchanged.

The exact commit, assertion count, and command results belong in the final execution receipt because embedding a commit SHA in its own commit is self-referential.

## Deferred ship gates

- Apply and bind the five-field EVENTS migration.
- Build, sign, install, or activate the candidate.
- Run an installed disposable Notion/EventKit smoke.
- Register a public MCP operation or recurring/background job.
- Push, merge, tag, publish, or release.
- Expand beyond single-machine coordination or the narrow registry-first capability.
