# Wave 1 Implementation Map — Build Handoff

For the next Execute session (Claude Code on this repo recommended). Design authority: `W1-DESIGN.md` (this dir) + Wave-1-Broker-Contract. Read `AGENTS.md` first — branching (worktree, never park primary checkout off main), `make test` (standalone executable, no XCTest), Swift 6 strict concurrency, install ladder.

## File-level changes

| # | File | Change |
|---|---|---|
| 1 | `TheBridge/Modules/StandingOrders/ConstitutionStore.swift` (NEW) | Loads tier0.md + doctrine-core.md + metadata stamps from the doctrine root; assembles the `constitution` payload (orders via `StandingOrdersStore`, commands index via CommandStore, roster via existing service); freshness logic (fresh/stale/interim + Quickload fallback). |
| 2 | `TheBridge/Modules/StandingOrders/DoctrineSync.swift` (NEW) | Notion → doctrine-core.md pull (page → markdown via existing Notion client), version stamps, manifest hash recompute. Manual trigger: new `.request`-tier tool `doctrine_sync` (or Settings button). Single writer of doctrine files. |
| 3 | `TheBridge/Modules/StandingOrders/BridgeInitializeModule.swift` | Add `mode` + `includeConstitution` params; call SessionRegistry.open; embed `session` + `constitution` in receipt; schemaVersion bump. Keep v1 fields intact (existing receipt consumers). |
| 4 | `TheBridge/Modules/StandingOrders/BridgeInitializeService.swift` (locate exact name via `rg BridgeInitializeService`) | Accept session/constitution inputs; wire freshness into finalState policy (stale ⇒ DEGRADED, per existing required-source policy). |
| 5 | `TheBridge/Server/SessionRegistry.swift` (NEW) | Actor + `sessions.sqlite` (copy `jobs.sqlite` bootstrap pattern). Schema per W1-DESIGN §4. Register in `ServerManager.setup()`. |
| 6 | `TheBridge/Server/ToolRouter.swift` | Dispatch context struct gains `{transportSessionId?, origin: .local/.remote}`; `dispatchFormatted()` consults SessionRegistry → advisory `governance` annotation + `governed:false` audit flag; independently enforces the default-ON governed-session requirement and the opt-in control-plane block before SecurityGate when `origin == .remote`. |
| 7 | `TheBridge/Server/SSETransport.swift` | Thread `Mcp-Session-Id` + `isRemoteTunnelRequest` result into the dispatch context (PKT-810 classification already computed here — pass it down, don't recompute). stdio path (ServerManager) passes `origin: .local, transportSessionId: "stdio"`. |
| 8 | `TheBridge/Server/ToolAnnotations.swift` + `BridgeModuleRegistry.swift` | Annotations/registration for `doctrine_sync`; bump `staticFeatureModuleToolCount`. |
| 9 | `TheBridgeTests/Wave1BrokerTests.swift` (NEW) + `main.swift` | `runWave1BrokerTests()` per W1-DESIGN §6. Mock seams already exist (PreflightProvider/ContextProvider pattern). |
| 10 | Doctrine root | Author `tier0.md` (Tier-0 v2.0.0 text from Standing-Orders-v2-Evolutionary-Update.md §A); first `doctrine_sync` run produces doctrine-core.md. |

## Step 0 — MANDATORY substrate verification (before any code; Red Team A1/G1)

The design has two unverified assumptions that must be resolved by reading source, not trusting descriptions:
1. **Doctrine storage (A1):** `rg BridgeInitializeService` → read the service + open the real doctrine root on disk. Reconcile W1-DESIGN §2's file layout (orders.md/manifest.json/metadata.json + new tier0.md/doctrine-core.md) against what exists. §2's *intent* holds; its *mechanics* are re-derived from source.
2. **Session identity (G1):** empirically confirm the correlation key each transport carries call-to-call — stdio (no session id), streamable-HTTP (`Mcp-Session-Id` stability), tunnel. Implement §4 on the observed identifier, with the documented fallbacks. If no stable key exists on claude.ai, the annotation must not fire per-call as noise — resolve granularity first.
3. **Token budget (A2):** measure `sum(len(order.body))` over active orders; decide inline-bodies vs. summaries-with-fetch before finalizing the payload.

Only after step 0 do the file mechanics below become authoritative.

## Order of work (test-first per contract)

1. Branch per AGENTS.md (`git switch -c feat/w1-broker origin/main` in a worktree).
2. Tests 9 (red) → 5 SessionRegistry (green) → 1 ConstitutionStore (green) → 3+4 initialize v2 (green) → 6+7 dispatch context + annotation + blocklist (green) → 2 DoctrineSync → 8 registration → 10 content.
3. `make test` floor green; `make app && make install-copy`; live checks: cold handshake from claude.ai (<2s, metric 1), tunnel blocklist test (threat-model checklist), stdio unaffected.
4. Post-ship: patch the Bridge Initialization Contract registry order ("step 1 = call bridge_initialize"), verify-back; then bootstrap-skill thin-pointer rewrite.
5. Red Team the build → Ship Gate with both docs/wave1/ documents.

## Cautions

- `SSETransport`/`MCPHTTPValidation` are shared surfaces — single owner rule + rebase before touching (AGENTS.md v3.7.10 incident).
- Do not recompute remote classification at dispatch; pass PKT-810's result down (two lockstep implementations already exist — don't add a third).
- Blocklist rejection must produce an AuditEntry (never a silent drop) — No Silent Failures.
- AGENTS.md tool count (81) predates current surface (~190 via tools_list); trust `tools_list`, update AGENTS.md only in a docs commit.
