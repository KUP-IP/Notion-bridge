# Wave 1 Design — The Broker Becomes Law

Contract: `~/Claude/Projects/The Bridge/Wave-1-Broker-Contract.md` (governed by Bridge-Evolution-Contract v1.1: D4, D9a–d, D10a–d)
Status: DESIGN — checkpoint artifact for Plan step 1. No code authorized by this doc alone.
Grounding: live recon 2026-07-05 of `BridgeInitializeModule.swift` (PKT-1065A), `SSETransport.swift` (PKT-810 remote classification), `ToolRouter`/`SecurityGate` pipeline, `StandingOrdersStore.swift`, AGENTS.md architecture.

## 1. Principle: extend PKT-1065A, don't reinvent

`bridge_initialize` v1 already: locates + loads the on-disk doctrine (orders.md + manifest.json + metadata.json), verifies SHA-256, enforces required-source policy, inspects roster + supplemental orders, runs intent-sensitive capability preflight, persists a receipt, emits telemetry. **v2 = v1 + (a) constitution content in the response, (b) session records with declared mode, (c) advisory governance annotation, (d) remote control-plane block.** The store, integrity, and receipt machinery is reused as-is.

## 2. Constitution store (D4, kernel-boundary checked)

Reuse the existing on-disk doctrine root as the constitution store; add two compiled artifacts:

```
<doctrine root>/
  orders.md            # existing — on-disk doctrine
  manifest.json        # existing — source roles + expected SHA-256 (extend entries)
  metadata.json        # existing — doctrine version
  tier0.md             # NEW — Tier-0 Baseline text, version-stamped
  doctrine-core.md     # NEW — compiled doctrine core (≤ ~3K tokens), version-stamped
```

- **Notion mirror (single-writer):** a sync routine (manual trigger in W1: `standing_orders` module tool or Settings action; scheduled later) pulls the doctrine page from Notion, compiles to `doctrine-core.md`, stamps `{doctrineVersion, syncedAt, notionPageId, notionLastEdited}` into metadata.json, recomputes manifest hashes. The sync job is the ONLY writer of doctrine files. App-side doctrine edit tools: none (single-writer holds by absence).
- **Standing orders** remain in `StandingOrdersStore` (app-authored; Notion mirror read-only per contract — mirror export is W2+, out of W1).
- **Kernel boundary:** manifest/metadata schemas stay generic (`sources[]`, `artifacts[]`, version stamps). No KEEP OS-specific keys; all KEEP OS content lives inside the markdown payloads.
- Sync failure → keep last-good files, mark `doctrineFreshness: stale` in the receipt (never silently normalized).

> **RT-A1 (substrate unverified):** §2 is inferred from the `bridge_initialize` tool description, NOT from reading `BridgeInitializeService.swift` (exceeded fetch cap this session). The build session's **step 0** is to open the service + the real doctrine root and reconcile this section against what exists before trusting the file layout. If the service stores doctrine differently, §2 is authoritative for *intent* (compiled tier0 + core artifacts, single-writer, version-stamped); the file mechanics are re-derived from source.
> **RT-S2 (interim core accepted):** `doctrine-core.md` depends on the parallel v9 packet for a clean ≤3K core. Until v9 lands, the interim Quickload capsule ships with `doctrineFreshness: "interim"`. The contract DoD "bundle matches live state" is satisfied by the interim state — an honestly-flagged interim core is passing, not failing. W1 does not block on v9.

## 3. `bridge_initialize` v2 payload (schemaVersion bump)

New optional params: `mode` (`"recon" | "execute" | "background" | "general"`, default `"general"`), `includeConstitution` (default `true`). Existing `client` and `intent` params unchanged.

Receipt extends v1 (all existing fields preserved) with:

```json
{
  "schemaVersion": <v1+1>,
  "session": { "sessionId": "uuid", "mode": "execute", "client": "claude-ai",
               "transportSessionId": "<Mcp-Session-Id|stdio>", "startedAt": "ISO8601",
               "governed": true },
  "constitution": {
    "tier0": "<tier0.md text>",
    "doctrineCore": "<doctrine-core.md text>",
    "doctrineVersion": "…", "doctrineFreshness": "fresh|stale",
    "orders": [ { "id", "title", "scope", "body", "updatedAt" } ],   // active only, full bodies
    "commandsIndex": [ { "slug", "name", "keySlot" } ],               // index only
    "roster": <existing routingRoster payload>,
    "telemetryId": "<active telemetry ref if resolvable, else null>"
  }
}
```

Budget: tier0 ~0.5K + core ≤3K tokens + orders — must be MEASURED, not assumed (RT-A2). Before finalizing the payload the build session computes `sum(len(order.body))` over active orders; if `core + orders` approaches the MCP output cap (the cap that bit skill-body fetches 3× this session), serve orders as **summaries with on-demand body fetch** (the skills system already does exactly this — reuse that pattern), not full bodies inline. If `doctrine-core.md` is missing (pre-first-sync), serve the Quickload capsule interim and flag `doctrineFreshness: "interim"`.

## 4. Session registry + advisory annotation (D10a advisory posture)

- **`SessionRegistry`** — new actor + SQLite (follow `jobs.sqlite` pattern → `sessions.sqlite`): `sessionId, transportSessionId, client, mode, startedAt, governed, closedAt?`. Registered in `ServerManager.setup()`; `bridge_initialize` v2 writes a row; keyed to transport session.
- **RT-G1 (session identity is unverified — build session MUST resolve before coding §4):** the correlation key between `bridge_initialize` and later tool calls is assumed to be `Mcp-Session-Id`, but (a) **stdio has no session id**, and (b) claude.ai lazy-loading may not carry a stable `Mcp-Session-Id` across calls. If the key isn't stable, EVERY call reads ungoverned and the annotation becomes constant noise — the exact lazy-load reality that forced the bootstrap skill to exist. **Empirically confirm what identifier each transport (stdio, streamable-HTTP, tunnel) actually carries call-to-call before implementing.** Concrete fallbacks: stdio → the process connection is the session (one row per connection, `transportSessionId: "stdio:<pid|conn>"`); HTTP without stable session-id → fall back to `(client, bearer)` correlation or accept coarser session granularity, documented. Do not ship §4 on the assumption; ship it on the observed identifier.
- **RT-S1 (concurrent sessions, one transport):** two clients sharing a bearer/tunnel may collide on `transportSessionId`. Low-frequency for a solo operator now; real at the universal-hub endgame. W1: tolerate (latest-writer row) + note; uniqueness policy lands with W4 per-client credentials.
- **Advisory annotation:** in `ToolRouter.dispatchFormatted()` (single choke point, transport-agnostic): if the calling transport session has no broker session → append a `governance` note to the response envelope (`{"initialized": false, "note": "ungoverned session — call bridge_initialize"}`) and mark the `AuditEntry` `governed: false`. Local callers and remote open/read bootstrap tools stay advisory in W1 (the broad hard flip is a Wave-4 metric event). Requires threading a transport-session identifier into dispatch context — see IMPLEMENTATION-MAP §3.
- **Remote ungoverned write guard:** tunnel-origin notify/request-tier tools require a governed session row. If a remote client cannot or does not call `bridge_initialize`, the router returns `ungoverned_remote_session` before SecurityGate/module execution and writes a rejected `AuditEntry`. This is the fail-closed counterpart to the degraded-mode rule: no remote local-machine or write operations when initialization is unavailable.
- **Metric 1 instrumentation:** receipt timestamp + first-tool-call timestamp per session, derivable from AuditLog; expose via `session_info` extension or log query.

## 5. Remote control-plane block (D9c, enforced in W1)

- Transport already classifies remote: `SSEServer.isRemoteTunnelRequest` (Cloudflare tunnel header, PKT-810; loopback peer + no header = local by contract).
- Thread `origin: .local | .remote` from the HTTP layer into dispatch context (same plumbing as §4's session identifier — one context struct, two fields).
- In dispatch (before SecurityGate): if `origin == .remote && toolName ∈ ControlPlaneBlocklist` → structured rejection `{"error": "control_plane_remote_blocked", "tool": …}` + audit entry. Separately, if `origin == .remote && governed != true && tier ∈ {notify, request}` → structured rejection `{"error": "ungoverned_remote_session", "tool": …}` + audit entry.
- **Blocklist = PREDICATE, not a name list (RT-G2 — decided, don't ship both).** Reject when `origin == .remote && ( module ∈ {shell, applescript, computer, credential} || tool ∈ ControlWrites )` where `ControlWrites = {standing_orders_save, standing_orders_delete, commands_create, commands_update, commands_delete}`. The predicate is rename-proof for the module-based half (a renamed `shell_exec` stays in module `shell`); only the five store-write tool names are enumerated, and those are the ones this very project renames — so they get a test that asserts the set matches the registered `standing_orders`/`commands` write tools. The 14-name list from the prior draft becomes a **test fixture only**, asserting the predicate catches each.
- stdio and loopback callers unaffected. Override path: none in W1 (arrives with D10 override design in W4) — remote control-plane is simply closed, matching contract.
- **RT-G3 (kill switch for the new behaviors):** both new dispatch behaviors gate behind UserDefaults flags following the codebase's established pattern (`cloudAccessEnabled`, `trustedMode`): `com.notionbridge.broker.remoteControlPlaneBlock` (default **on**) and `com.notionbridge.broker.advisoryAnnotation` (default **on**). A misbehaving annotation or an over-broad block can be disabled without reverting the shared-surface transport plumbing (AGENTS.md flags `ToolRouter`/`SSETransport` as incident-prone). Flag reads are cheap and already idiomatic here.

## 6. Tests (standalone executable pattern, `TheBridgeTests/main.swift`)

`runWave1BrokerTests()`: (1) constitution assembly — bundle matches store files + StandingOrdersStore live read-back; (2) session row written with declared mode/client; (3) ungoverned dispatch carries annotation, governed doesn't; (4) remote-flagged dispatch of each blocklisted tool rejects, local passes, non-blocklisted remote passes; (5) missing doctrine-core → interim capsule + flag; (6) stale sync → `doctrineFreshness: stale`. Integration: full cold handshake < 2s asserted. Tunnel live test is manual (Ship Gate checklist, from an actual remote caller).

## 7. Explicitly out (per contract)

Profiles/hard enforcement (W4) · per-client credentials (W4) · skill compilation (W2) · telemetry pipe (W3) · background runs (W5) · doctrine v9 editorial (parallel packet) · orders/commands Notion mirror export (W2+).
