# Calendar–Registry Candidate-Readiness Receipt

Status: **Integrated Candidate-Ready Source** — migration applied (2026-07-18); activation pending env-filtered MCP + disposable live smoke. Composition remains disabled by default. This is not an always-on sync receipt.

## Integrated source

- Base: current `origin/main` plus the six installed/review integration commits.
- Calendar line: the six reviewed Calendar–Registry commits from `3785605` through `a8d15ac`, replayed onto the integration lineage, plus the literal crash-recovery proof.
- Skills line: unique commit `21fc72c` is replayed after the Calendar candidate so specialist metadata mutations resolve and refresh the shared caches.
- Conflict surface: the skills replay merged automatically; the Calendar replay changed only append-only test-floor provenance and its numeric floor outside the Calendar implementation.

## Safety contract

- Scope is one disabled-by-default, registry-first, single-machine transaction pairing one pre-existing Registry-authority Notion EVENT with at most one qualified private local EventKit item.
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
4. `git diff --check` is clean and the unique skills fix is present exactly once on the candidate graph.
5. The live EVENTS schema has all five additive fields bound through the `schedule` registry with zero drift.

The exact commit, assertion count, and command results belong in the final execution receipt because embedding a commit SHA in its own commit is self-referential.

The first integrated-source run measured 3,355 passed and 0 failed. The locked floor advances by the eight net-new specialist-mutation tests, from 3,334 to 3,342; the final release SHA must rerun the gate.

## Live migration receipt — 2026-07-18

- EVENTS data source `898f03a6-abb2-486a-861e-3086466a0d06` received the five
  additive properties with their declared types; no existing property changed.
- `registry_introspect(entity: "schedule")` reported 41/41 canonical bindings,
  `fullyBound: true`, and an empty drift list.
- The internal composition remains disabled by default. No EVENT row or EventKit item was
  created, updated, or deleted by the migration itself.

## Activation posture (next)

- Env-filtered MCP registration for a private-smoke pairing path (composition still requires
  `BRIDGE_INTERNAL_CALENDAR_REGISTRY_SYNC=1` plus an explicit calendar allowlist).
- One disposable live Notion↔EventKit smoke with sticky-env off-ramp after the window.
- Tool name and smoke receipt are recorded only after those waves land.

## Deferred ship gates

- Always-on sync, recurring jobs, or background reconciliation.
- R10–R15 (import, reschedule, reconciliation, cancel/detach, Google API, bulk, recurrence/attendees).
- Push, merge, tag, publish, or Sparkle release as part of this readiness document.
- Expand beyond single-machine coordination or the narrow registry-first capability.
