# A0 — Bridge Execution Integrity Architecture Map

**Project:** Bridge Execution Integrity Hardening (`3abcbb58-889e-81eb-a303-e53aedc26033`)  
**Packet:** A0 — Baseline, worktree, and architecture map (`3abcbb58-889e-817b-8d3d-f36518078610`)  
**Evidence time:** 2026-07-27 22:20 CT  
**Source SHA:** `3143a6562a16cb3dad5402b17595c841483d1fc2`

## 1. Executive finding

A0 established a safe isolated worktree and proved that the repository and installed runtime are not the same product state even though both report version `4.0.2` / build `84`.

The current source contains transitional `session`↔`packet` alias logic and a tested Packet Runner decision kernel/specification. The installed runtime at `df286d1656f9b11e28fca853b519021fa9acdee5` is five commits behind source, exposes PACKETS only as registry entity `session`, rejects `registry_hydrate(entity: "packet")`, and exposes no `packet_runner_status` or `packet_runner_run` tool. Runtime acquisition, worker dispatch, receipt reconciliation, worktree claims, and Git mutation fencing therefore remain downstream implementation work.

No downstream implementation, schema mutation, application installation, release, PR, merge, tag, command edit, or skill edit was performed.

## 2. Exact worktree tuple

| Field | Value | Classification |
|---|---|---|
| `repoRoot` | `/Users/keepup/Developer/the-bridge` | Confirmed |
| `worktreePath` | `/Users/keepup/Developer/worktrees/the-bridge/a0-baseline-architecture-map` | Confirmed |
| `branch` | `packet/a0-baseline-architecture-map` | Confirmed |
| `baseSHA` | `3143a6562a16cb3dad5402b17595c841483d1fc2` | Confirmed |
| Integration line | `origin/main` | Confirmed |

The worktree was created by `git worktree add -b packet/a0-baseline-architecture-map ... origin/main`. The primary checkout was not switched, reset, stashed, cleaned, or rewritten.

## 3. Repository and installed identity

### Confirmed

- Primary checkout: `/Users/keepup/Developer/the-bridge`.
- Primary branch: `main`.
- Primary HEAD at pickup: `ef579a13beb2e3dd68d3c3474e62cc25c09a33d4`.
- Primary worktree/index: clean.
- Upstream: `origin/main`.
- Primary was `0` ahead / `5` behind; local `main` was a direct ancestor of `origin/main`.
- Integration SHA used for A0: `3143a6562a16cb3dad5402b17595c841483d1fc2`.
- Installed bundle: `/Applications/The Bridge.app`.
- Installed marketing version/build: `4.0.2` / `84`.
- Installed provenance: `BridgeGitSHA=df286d1656f9b11e28fca853b519021fa9acdee5`, `BridgeGitDirty=false`.
- Installed binary SHA-256: `f343c89f06a086663c915b1615f7edd0a76ee7a1a558095e127d258afea6967f`.
- Codesign identifier/team: `kup.solutions.the-bridge` / `VP24Z9CS22`.
- Source Info.plist: `4.0.2` / `84`.
- Installed commit exists in source history and is an ancestor of A0 source HEAD.
- Installed identity does **not** match source HEAD despite version/build parity.

### Smallest seams

| Surface | Source | Why this is the smallest credible seam | Consequence |
|---|---|---|---|
| Build provenance stamp | `scripts/stamp-build-provenance.sh:4-29`; invoked by `Makefile:169` | Existing single writer for `BridgeGitSHA` and `BridgeGitDirty` | Promotion verification must compare this stamp to the exact tested SHA. |
| Source/install cleanliness gate | `Makefile:285-300` (`check-clean-tree`) | Existing branch/dirty policy before install | Later install packets should extend evidence, not bypass this target. |
| Installed readback | bundle `Info.plist` plus live `bridge_status` | Proves both on-disk and running-tool provenance | Exact tool inventory must be paired with installed SHA, not version alone. |

### Unknown

- Which process instance currently serves the connector could not be proven solely from `pgrep` path matching. `bridge_status` proves the Bridge channel is live and reports installed provenance; process attribution should use the Bridge session/connection observability layer in a later live verification.

## 4. Registry and PACKETS

### Live registry identity — Confirmed

The installed registry has no canonical entity named `packet`.

| Entity | Data source | `hasBody` | Cache TTL | Binding state |
|---|---|---:|---:|---|
| `session` | `078e7c9e-e53e-4c83-a893-af64f82b5123` | true | 300 seconds | Partially bound |
| `packet` | absent in installed registry | — | — | unavailable |

Installed behavior:

- `registry_hydrate(entity: "packet", id: A0)` → unknown entity / unavailable.
- `registry_hydrate(entity: "session", id: A0)` → successful `packet-registry-v1` envelope with properties, complete body, PROJECT/SKILLS/blocker projections, and provenance.

The transitional `session` binding was used only for A0 baseline execution and reconciliation.

### Current source alias behavior — Confirmed

- `TheBridge/Modules/Registry/RegistryModels.swift:216-245` implements `RegistryConfig.entity(forKey:)` compatibility:
  - direct entity match first;
  - request for `packet` can synthesize an alias from legacy `session` when its display name is packet-like;
  - request for `session` can synthesize an alias from canonical `packet`.
- This is the smallest credible alias seam because every registry tool resolves an entity through the same config lookup.
- Coupling: aliasing alone does not bind newly required packet properties; introspection/property-map migration remains necessary.

### Registry implementation seams — Confirmed

| Concern | Exact source | Symbol / range | Why smallest credible insertion point |
|---|---|---|---|
| Entity registration/config persistence | `TheBridge/Modules/Registry/RegistryConfigStore.swift:19-165` | `RegistryConfigStore` | Single atomic JSON config owner; seeded entities and property maps converge here. |
| Entity lookup/alias | `TheBridge/Modules/Registry/RegistryModels.swift:216-245` | `RegistryConfig.entity(forKey:)` | Every registry read/write depends on resolved `RegistryEntityConfig`. |
| Required entity gate | `TheBridge/Modules/Registry/RegistryModule.swift:321-355` | `requireEntity` | Central fail-closed tool entry guard after alias resolution. |
| Hydration | `TheBridge/Modules/Registry/RegistryReader.swift:241-340` | `hydrate(entity:pageId:)` | Existing primary row + body + curated one-hop relation envelope. |
| Hydrate tool registration | `TheBridge/Modules/Registry/RegistryModule.swift:809-842` | `registry_hydrate` registration | Public MCP contract seam. |
| Schema introspection/binding | `TheBridge/Modules/Registry/RegistrySchemaBinder.swift:64-135` | schema bind/drift pass | Authoritative property-name→property-ID binding and unbinding. |
| Cache identity | `TheBridge/Modules/Registry/RegistryRowCache.swift:22-150` | per-entity row cache | Cache files are keyed by entity identity; alias convergence must prevent split packet/session caches. |
| Config encoding | `RegistryConfigStore` JSON encoder with `.sortedKeys` | deterministic persisted config | Useful for stable config diffs, not mission hashing by itself. |

### Live PACKETS property audit — Confirmed

Data source: `078e7c9e-e53e-4c83-a893-af64f82b5123`.

| Required/live field | Property ID | Live type | Registry binding |
|---|---|---|---|
| Packet Name | `title` | title | bound as `name` |
| Packet Title | `_zbO` | rich_text | bound as `title` |
| Status | `y<xv` | status | bound |
| Objective | `jr~M` | rich_text | bound |
| Source of Truth | `ntM=` | rich_text | bound |
| Agent Type | `jbC~` | select | bound |
| Model | `u{<R` | select | bound |
| Complexity | `ySOP` | number | bound |
| Context Size | `DMV@` | number | bound |
| Duration | `BRDz` | number | bound |
| Tokens | live | number | bound |
| Packet Output | `VyF|` | rich_text | bound |
| PROJECT | `NkiO` | relation | bound |
| SKILLS | `\\oj` | relation | bound |
| AI LOGS | `f@av` | relation | bound |
| EVENT | `K>AT` | relation | bound |
| Blocked by | `?S??` | relation | bound |
| Blocking | `qjgT` | relation | bound |
| Lifecycle Checked At | `nrEw` | date | bound |
| Execution Class | `WHc}` | select | bound |
| Priority | `Dmn~` | number | **present but unbound** |
| Mirror Status | `t>]<` | status | **present but unbound** |
| Last Executed At | `hhpb` | date | present, not in installed registry map |
| Last Execution URL | `iTpe` | url | present, not in installed registry map |
| Cleanup Eligible At | `pq~Y` | date | present, not in installed registry map |
| Execute Date | `M^Ri` | date | present, not in installed registry map |
| PKT-ID | `FDqm` | unique_id | present, not in installed registry map |
| `fromStatus` | absent | — | absent |
| Execution Window | absent | — | absent |
| Mission Revision | absent | — | absent |
| Mission Hash | absent | — | absent |

Status options are legacy `Backlog`, `QUEUE`, `REVIEW`, `BLOCKED`, `FOCUS`, `Done`, `Decline`; canonical uppercase `DONE`/`CANCELED` are not live options.

### Consequence

A1 requires both a registry-config migration and a PACKETS schema migration. Adding only the alias would leave priority, lifecycle compatibility, mission integrity, and terminal-state semantics incomplete.

## 5. Mission integrity

### Current hydration path — Confirmed

- Packet properties are loaded through registry row reads/property codecs.
- Packet body is fetched because `session.hasBody=true`.
- `RegistryReader.hydrate` combines the row, full body, and curated one-hop relations into `packet-registry-v1`.
- A0 body currently contains the mission contract and a reserved `## Packet Runner Output` section.

### Current material-revision guard — Confirmed

No installed runtime guard exists.

The repository contains a deterministic reference implementation only:

- `packet-runner/controller/decisions.py:89-116` — material-change and approval-snapshot validity logic.
- `packet-runner/controller/test_decisions.py` — behavior tests.

This decision kernel is not registered as a Swift runtime module and cannot currently prevent an installed worker from executing a materially revised packet.

### Deterministic serialization/hash candidates — Confirmed

| Utility | Source | Reuse value |
|---|---|---|
| CryptoKit SHA-256 pattern | `TheBridge/Modules/Registry/RegistryModule.swift` (CryptoKit import and markdown digest helper) | Already in the registry domain. |
| Canonical sorted JSON + SHA | `TheBridge/Modules/SecurityApprovalReceipt.swift` | Proven canonical receipt digest pattern. |
| Canonical manifest digest | `TheBridge/Modules/Time/CalendarRegistryTransactionStore.swift` (`CalendarRegistryDigest.sha256`) | Strongest existing precedent for durable operation fingerprinting and recovery. |
| Sorted-key JSON persistence | `RegistryConfigStore`, `RegistryRowCache` | Stable encoding pattern, but not a mission contract. |

### Smallest credible implementation seam — Inference

A1 should introduce a packet-mission canonicalizer adjacent to the new Packet Runner runtime, consuming the hydrated registry envelope rather than raw Notion JSON. Store a monotonic `Mission Revision` number and `Mission Hash` rich-text property in PACKETS, then bind both in the canonical `packet` registry entity.

### Hash membership — Inference

Include operator-owned mission fields: outcome/goal, scope, constraints, success criteria/DoD, verification, execution class, source of truth, dependency/blocker identity, project identity, and relevant skill requirements.

Exclude controller-owned mutable fields: Status, Lifecycle Checked At, Last Executed At/URL, Packet Output, Cleanup Eligible At, Mirror Status, model, duration, tokens, context size, telemetry links, and controller-managed timestamps. Including those would make every acquisition/reconciliation mutate the mission hash.

### Unknown assigned to A1

- Final canonical body normalization rules for headings, whitespace, checkboxes, and reserved managed-output exclusion.
- Whether body and property duplication is resolved by strict equality or explicit property precedence.
- Exact revision increment semantics for relation-only changes.

## 6. Packet Runner

### Existing architecture — Confirmed

The repository has a specification/reference package, not an installed controller:

- `packet-runner/controller/decisions.py`
- `packet-runner/controller/test_decisions.py`
- supporting acceptance/contracts/fixtures under `packet-runner/`.

Confirmed decision seams:

| Behavior | Symbol / lines |
|---|---|
| Receipt→status mapping | `map_receipt_to_status`, `decisions.py:28-55` |
| Replay classification | `classify_replay_state`, `58-72` |
| Safe-resume gate | `safe_resume_gate`, `75-87` |
| Material change | `material_change`, `89-93` |
| Eligibility | `classify_eligibility`, `119-151` |
| Blocker graph validity | `_blocker_fully_known` / `validate_graph`, `153-169` |
| Ordering | `order_candidates`, `176-187` |
| Stale queue/FOCUS labels | `is_stale_queue` / `stale_label`, `212-233` |
| Source-of-truth/DONE gate | `requires_sot` / `gate_done`, `248-276` |
| Cleanup/archive eligibility | `cleanup_eligible_at` through `archive_due`, `337-389` |
| Output split/composition | `split_output`, `392-399`; `compose_output`, `524-545` |
| Schema preflight | `preflight_schema`, `415-439` |
| Overlap/pause controls | `overlap_gate` through `may_reenable`, `601-648` |

Narrow reference tests: `57 passed, 0 failed`.

### Missing runtime implementation — Confirmed

- No Swift `PacketRunnerModule`, controller actor, scheduler routine, or dispatch adapter was found.
- No live `packet_runner_status` tool.
- No live `packet_runner_run` tool.
- No installed stale-FOCUS reconciler.
- No installed receipt parser/reconciler that owns final status and managed output.
- No installed worker-dispatch mechanism that binds packet ID, revision/hash, worktree, branch, and base SHA.

### Tool registration seam — Confirmed

- `TheBridge/Server/BridgeModuleRegistry.swift:45-82` is the static feature-module registration list. A Packet Runner module belongs beside Registry/Jobs/Commands.
- `TheBridge/Server/ToolAnnotations.swift:412-420` resolves explicit annotations and fails closed on a miss. Both new tools require explicit annotations.
- The public inventory verification method is `tools_list(detail:false)` against the installed runtime, paired with `bridge_status` provenance.

### Smallest credible decomposition

- **B0:** productize controller runtime around the existing decision kernel contract; implement status/run tools, eligibility/order, coupled acquisition, worker dispatch, receipt validation/reconciliation, stale-FOCUS behavior, and managed-output writes.
- **A1:** complete registry/schema/mission preflight first so B0 does not embed transitional schema assumptions.
- **C0:** supply worktree ownership/lease enforcement consumed by B0 and mutation tools.

The existing decision package materially reduces design uncertainty; it does not eliminate the need for a Swift runtime implementation and live integration tests.

## 7. Worktree and Git mutations

### Public Git tools — Confirmed

`TheBridge/Modules/GitModule.swift` registers:

- `git_status` (`:42`)
- `git_diff` (`:78`)
- `git_log` (`:153`)
- `git_show` (`:426`)
- `git_blame` (`:518`)
- `git_apply_patch` (`:586`)
- `git_create_branch` (`:676`)

### Shared internal execution layer — Confirmed

- `TheBridge/Modules/GitRuntime.swift:85-96` — shared actor.
- `GitRuntime.runGit`, `:148-153` — central entry for registered Git tools.
- `GitRuntime.spawn`, `:155-212` — process invocation.

`GitRuntime.runGit` is the smallest common guard for mutations performed through `GitModule`, especially `git_apply_patch` and `git_create_branch`.

### Existing guards — Confirmed

- Structured Git status distinguishes worktree cleanliness from upstream synchronization (`GitRuntime.swift:59-72`).
- Makefile install guards enforce clean source and main-branch policy.
- No worktree claim, lease, branch ownership, or packet identity check exists in GitRuntime.

### Direct mutation bypasses — Confirmed

A GitRuntime-only guard is insufficient because the following public tools can mutate repository content without passing GitRuntime:

- `shell_exec` / `bg_run` — arbitrary process execution.
- `file_edit`.
- `file_write`, `file_append`, `file_move`, `file_copy`, `file_rename`.
- dedicated build/install wrappers can produce artifacts or invoke Make targets.

C0 therefore needs a shared path/cwd mutation policy plus direct checks in bypass modules where a target resolves inside a claimed repository.

### Reusable lease/persistence precedent — Confirmed

The best existing implementation precedent is not the registry cache; it is the fenced transaction infrastructure:

- `TheBridge/Modules/ThreadMessagesReceiptStore.swift:58-60, 199-201, 219-314, 330-371` — persisted lease owner/token/expiry, revision fencing, acquire/release.
- `TheBridge/Modules/Time/CalendarRegistryTransactionStore.swift:238-241, 364-378, 413-576` — SQLite recovery ledger, lease renewal/release, stale-lease override only under an exclusive process lock.
- `TheBridge/Modules/Time/CalendarRegistryProcessLock.swift:24-31, 77-189` — process-shared file lock coordinator.

These are the smallest credible patterns for `worktree_claim`, `worktree_release`, fencing-token validation, expiry recovery, and process-restart durability. A new worktree-claim store should be domain-specific rather than coupling Git ownership to calendar/thread records.

### Recovery behavior — Inference assigned to C0

- Persist claims in Application Support using SQLite with `{repoRoot, worktreePath, branch, packetId, owner/session, leaseToken, acquiredAt, heartbeatAt, expiresAt, revision}`.
- Acquire under an exclusive process lock.
- Reject an unexpired foreign lease.
- Allow expired lease takeover only after verifying the worktree tuple and no live matching owner.
- Require fencing token on every protected mutation.
- On restart, expired claims remain inspectable and recoverable; they are not silently deleted.

## 8. Closeout and commands

### close-agent source of truth — Confirmed

Notion skill:

- ID `6673dba8-26b1-4b1d-aa0a-6aad084a861c`
- slug `close-agent`
- version `3.6.0`
- status `Testing`

Current mode ownership:

- WORKER: immediate no-op because the executor receipt is canonical.
- CYCLE: consumes receipts, writes the cycle brief/selective AI LOG, and never writes packet Status.
- INTERACTIVE Phase 7: packet finalization only for interactive closeout; CYCLE suspends it because Packet Runner owns reconciliation.

### Final Housekeeping insertion point — Confirmed/Inference

The interactive order is Phase 5 AI LOG → Phase 6 audit proposals → Phase 7 terminal packet finalization. The current Close command explicitly requires final housekeeping **after continuity artifacts are durable**.

The smallest compatible insertion is a named Final Housekeeping phase after durable continuity writes (Phase 5 and any approved Phase 6 effects) and immediately before terminal packet finalization. CYCLE mode must keep housekeeping separate from packet Status reconciliation.

### Current Close command — Confirmed

Command slug `close-agent`, name `Close`. Its body already:

1. produces a closeout receipt;
2. scans AGENT_FEEDBACK;
3. delegates session memory/AI LOG mechanics to `fetch_skill('close-agent')`;
4. performs final housekeeping after continuity artifacts are durable;
5. emits terminal or baton-specific output.

Update mechanism:

- `TheBridge/Modules/Commands/CommandStore.swift` — markdown-backed command persistence and lookup.
- `TheBridge/Modules/Commands/CommandsModule.swift:15` registration; `commands_get` around `115-137`; `commands_update` around `204-243`.
- `BridgeModuleRegistry.swift:71` registers CommandsModule.

A later Close-command packet should delegate housekeeping to a single close-agent contract instead of duplicating mechanics in both artifacts.

### Session/process provenance — Confirmed

- `TheBridge/Server/SessionRegistry.swift:94-95` is the live session registry actor.
- `TheBridge/Server/ConnectionRuntimeObservability.swift` records origin, transport identity, client label, timestamps, auth mode, and expiry.
- `TheBridge/Modules/SessionModule.swift:148-185` documents scope limitations of `connections`/`activeClients`.
- `process_list`, bg-process receipts, and audit logs provide local process/action evidence, but do not alone prove packet ownership.

### Duplicate resolution/reversible archive — Confirmed

- `registry_find` provides resolve-before-create matching.
- `registry_delete` is a Notion soft archive, implemented through `RegistryWriter.swift:120` and `RegistryGateway.swift:81,163`.
- Agent memory uses expiry tombstones rather than hard deletion (`MemoryStore.swift`).
- Housekeeping should use these reversible primitives and stop on ambiguous ownership.

## 9. Tests and promotion

### Exact-SHA baseline — Confirmed

At `3143a6562a16cb3dad5402b17595c841483d1fc2`:

- `python3 packet-runner/controller/test_decisions.py` → **57 passed, 0 failed**.
- `make test-floor` → **3,462 passed, 0 failed**.
- Required floor: **3,416**.
- Test-floor job log: `~/Library/Application Support/The Bridge/bg-process/20260728-031858048-8518510c.log`.

### Test infrastructure by domain — Confirmed

| Domain | Existing tests / fixtures | Gap / downstream owner |
|---|---|---|
| Registry/config/cache/property codec | `RegistryConfigTests.swift`, `RegistryDataPathTests.swift`, `RegistryEdgeCaseTests.swift`, `RegistryHydrationTests.swift`, `RegistryModuleTests.swift`, `RegistryPropertyCodecTests.swift`, `RegistryRowCacheTests.swift` | A1 adds packet alias, schema-preflight, mission consistency/migration fixtures. |
| Notion behavior | Registry gateway fakes and hydration fixtures in registry tests | A1 adds exact PACKETS property-ID/type/status-option fixtures. |
| Packet decisions | `packet-runner/controller/test_decisions.py` plus acceptance fixtures | B0 adds Swift runtime/controller-cycle and live-tool integration tests. |
| Git | `TheBridgeTests/GitModuleTests.swift` | C0 adds claimed/unclaimed/expired/fenced worktree mutation tests and bypass-tool coverage. |
| Persistent leases | Thread Messages and Calendar Registry transaction/process-lock tests | C0 reuses patterns with domain-specific claim tests. |
| Commands | `CommandStoreTests.swift`, `CommandStoreSecurityTests.swift`, `CommandsModuleTests.swift`, UI command tests | Close-command packet adds exact delegation/body test. |
| close-agent | Notion skill test matrix; no Swift runtime tests | Close-agent packet must live-prove WORKER/CYCLE/housekeeping modes. |
| Jobs/scheduler | `TheBridgeTests/JobsModuleTests.swift` | B0 may reuse scheduler fixtures but needs Packet Runner-specific overlap/cycle tests. |

### Build, signing, install, rollback candidates — Confirmed

- Build: `make build` (`Makefile:102`).
- Unit floor: `make test-floor` (`:141`).
- Clean-tree gate: `make check-clean-tree` (`:285`).
- Signed/notarized install: `make install` (`:337`).
- Copy install for controlled development: `make install-copy` (`:351`); non-main requires explicit `ALLOW_NON_MAIN_INSTALL=1` and remains prohibited for A0.
- Sign: `make sign` (`:438`).
- Notarize: `make notarize` (`:461`).
- Verify: `make verify` (`:471`).
- Release: `make release` (`:499`).
- Sparkle/feed verification: `make verify-sparkle-feed` (`:494`).
- Rollback runbook: `docs/operator/release-rollback.md`; first action is revert the bad appcast commit on `main`, then verify the restored feed.

### Installed verification method — Confirmed

After a downstream installation:

1. read `/Applications/The Bridge.app/Contents/Info.plist` version/build/provenance;
2. call `bridge_status` for live embedded SHA/dirty state;
3. call `tools_list(detail:false)` and assert exact new tool names;
4. run narrow smoke calls against `packet_runner_status`/`packet_runner_run` in non-mutating or bounded test mode;
5. bind all results to the installed SHA.

A0 performed no install and the live inventory still lacks both Packet Runner tools.

## 10. Downstream ownership map

| Finding / unknown | Owner |
|---|---|
| Canonical `packet` entity, transitional `session` alias migration, cache convergence | A1 |
| PACKETS schema preflight, bind Priority/Mirror and new runtime fields | A1 |
| Mission revision/hash/body-property normalization | A1 |
| Runtime Packet Runner controller, status/run tools, acquisition, dispatch, receipts, stale FOCUS | B0 |
| Worktree claim/release store and fencing | C0 |
| GitRuntime guard and direct mutation bypass protection | C0 |
| close-agent Final Housekeeping phase and CYCLE/WORKER live tests | downstream close-agent packet (E0 per project contract) |
| Close command delegation/body update | downstream Close-command packet (F0 per project contract) |
| Build/install/readback/promotion and rollback execution | downstream promotion packet; not A0 |

## 11. Confirmed / inference / unknown summary

### Confirmed

- Safe isolated worktree tuple exists from current `origin/main`.
- Primary checkout was clean and preserved.
- Installed/runtime SHA is five commits behind source.
- Installed registry exposes PACKETS only as `session`; source contains alias logic.
- Live PACKETS schema lacks mission revision/hash, `fromStatus`, and Execution Window; several present fields are unbound.
- Packet decision logic/specification exists and passes 57 tests; runtime controller/tools do not exist.
- Git mutations have a common GitRuntime seam but multiple direct bypasses.
- Mature persisted/fenced lease patterns already exist in other domains.
- close-agent and Close are registry-backed operator artifacts with explicit ownership boundaries.
- Exact-SHA floor passes 3,462/0.

### Inference

- A1 should canonicalize mission content from the hydrated envelope and use sorted canonical JSON + CryptoKit SHA-256.
- C0 should create a domain-specific SQLite lease store modeled on Calendar Registry/Thread Messages, plus a process lock and fencing token.
- B0 should preserve the tested decision kernel semantics while implementing a native Swift controller/module.

### Unknown

- Final packet-mission normalization and revision increment contract — A1.
- Final worktree lease TTL/heartbeat and owner identity format — C0.
- Exact worker transport/launch adapter and cycle scheduler integration — B0.
- Exact Close/close-agent migration text and live mode acceptance — E0/F0.

## 12. A0 Definition of Done assessment

A0 satisfies its baseline Definition of Done:

- dedicated worktree from verified integration SHA;
- source/install/registry/schema/controller/worktree ground truth;
- concrete smallest insertion seams with file/symbol/range evidence;
- test and promotion map;
- explicit confirmed/inference/unknown separation;
- downstream ownership for every material unknown;
- no prohibited implementation or installation.

Packet Runner should reconcile this receipt and independently reassess A1 and C0 against the now-confirmed source/runtime split.