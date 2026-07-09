# Cloud Execution Tier — Design Proposal

Status: **PROPOSAL — reopens D5 and D9, does not implement.** Awaiting operator decision on
the open questions in §8 before wave 1 work starts.
Author: Claude (subagent), for Isaiah Peters
Date: 2026-07-09
Supersedes (pending operator sign-off): `docs/product-strategy.md` §4 **D5** ("V1 scope is
LOCAL-ONLY"); `docs/wave1/DEGRADED-MODE-SPEC.md`'s citation of **Evolution Contract D9**
("no secondary broker, no cloud replica of the runtime").
Does **not** touch: **D3** (two-tier custody / client-SLA ruling — reaffirmed, see §5) or
**D9a** (`DEGRADED-MODE-SPEC.md`'s own scope — constitution availability during Mac-down
intervals, a different and narrower guarantee than D9's "no cloud replica," see §2).
Reads on: `docs/product-strategy.md` §4 (D3, D4, D5, Supersession Log), `docs/neutral-layer/NL-2-local-vs-cloud-split.md`,
`docs/neutral-layer/NL-3-cloud-mac-delegation-authpassdown.md`, `docs/wave1/DEGRADED-MODE-SPEC.md`,
`docs/wave1/TUNNEL-THREAT-MODEL.md` (the convention this proposal's threat model extends),
plus a direct code read of `/Users/keepup/Developer/kup-worker` (`src/identity.ts`, `handlers.ts`,
`router.ts`, `store.ts`, `catalog.ts`, `capability.ts`, `liveness.ts`, `auth-exchange.ts`,
`wrangler.toml`, `index.ts`) and `/Users/keepup/Developer/the-bridge`
(`TheBridge/Modules/Cloud/*`, `TheBridge/UI/Sections/RemoteAccessSection.swift`,
`TheBridge/Modules/JobsManager.swift`, `TheBridge/Modules/JobsModule.swift`).

---

## 0. What this document is answering

Isaiah has decided, today, to reopen D5 ("cloud execution tier is a next-version feature") and
D9 ("no secondary broker, no cloud replica of the runtime"). That's his call to make — he's the
sole owner and operator, and `product-strategy.md` itself says these are decisions, not laws of
physics. This document's job is not to rubber-stamp the reopening or to silently relitigate it,
but to do what the doc's own **Supersession Log** convention asks: show the reasoning, name
what changes, and hold the new design to at least the bar the last comparable decision
(`TUNNEL-THREAT-MODEL.md`, gating the *existing* Cloudflare tunnel) was held to.

Two things are true at once, and both matter:

1. **The infrastructure for a cloud execution tier already exists**, half-built, in a sibling
   repo (`/Users/keepup/Developer/kup-worker`) that describes itself as "the cloud
   control-plane... the Mac is an optional execution node" — this is not a greenfield ask.
2. **The specific trigger condition D5 names has no recorded evidence trail.** D5's own text
   is precise: *"the operator's own async work genuinely needs to run without the laptop
   awake."* I searched this repo (git log, `product-strategy.md`'s Supersession Log, the
   `docs/` tree) for a named task, packet, or incident that meets that bar and found none. That
   doesn't mean it isn't true — Isaiah is the authority on his own workflow and this session
   was explicitly told the decision is made — but it does mean the trigger is currently
   *asserted*, not *evidenced*, and `product-strategy.md`'s whole point in keeping a
   Supersession Log is that decisions of this weight get a paper trail instead of drifting
   silently. §1 below turns that gap into one concrete, low-cost ask rather than either
   blocking on it or pretending it isn't there.

**Bottom line up front:** proceed, but scoped narrowly (§4), gated on one specific enforcement
fix that is currently missing from the existing worker code (§2, T3) and one recorded decision
entry (§1) — not as a full re-architecture, and explicitly not as the "cloud replica of the
runtime" D9 rejected (§3).

---

## 1. Is D5's trigger actually met?

D5's graduation marker is two-part: **(a)** the idea is validated, **(b)** the operator's own
async work genuinely needs laptop-off execution. Re-reading `product-strategy.md`'s own
Supersession Log entry from 2026-05-30 ("Graduation marker scope tightened") shows this bar was
deliberately set narrow and deliberately excludes client SLAs — so the question is specifically
whether *Isaiah's own* tooling has hit a wall the Mac-must-be-on model can't clear.

**Honest answer: I found no recorded instance of that wall being hit.** No packet, decision-log
line, or Supersession Log entry names a concrete task. That is a real gap relative to how this
project usually operates — every other major swing in this repo (the WorkOS IdP switch, the
client-SLA tightening, the PKT-810 R5 loopback fix) has a dated entry with a *reason*, not just
a *decision*.

I'm not going to block on that gap, for two reasons: first, the operator explicitly told this
session the decision is made, and second, unlike the tunnel-threat-model precedent (a proposal
reacting to something that had *already gone wrong in production*), this is a forward-looking
build — there's no incident to autopsy, only a stated need. But shipping a new trust surface on
an *unrecorded* trigger repeats exactly the pattern the Supersession Log exists to prevent. So:

**Non-negotiable before wave 1 ships (not before this proposal is approved — before code goes
live):** add one Supersession Log entry to `product-strategy.md`, in the existing format, naming
the concrete async task that motivated this. If there genuinely isn't one yet — if this is
being built ahead of a validated need rather than in response to one — say that in the entry
instead of manufacturing a retroactive justification; an honest "built proactively, first real
use case pending" is a defensible entry, a fabricated one is not.

Suggested entry shape:

> **2026-07-XX — D5 graduation marker met: [name the concrete operator-own-async task, or
> record "proactive build, no validated use case yet" if that's the honest state].** Cloud
> execution tier scoped per `docs/proposals/cloud-execution-tier-design.md`: cloud-only,
> operator's-own-scope tools only, wave-1 allowlist. D3's client-SLA carve-out is unchanged —
> client-account work remains permanently Mac-present; this graduation does not touch NL-2 row
> 19 and does not enable NL-3 Mac-delegation (`RemoteAccessSection.modelAEnabled` stays `false`
> pending the device-binding fix in §2 T4).

---

## 2. What D9 actually rejected, and why this proposal doesn't repeat it

`DEGRADED-MODE-SPEC.md` cites **Bridge-Evolution-Contract D9**: *"No secondary broker, no cloud
replica of the runtime (rejected in Evolution Contract D9 — 'cloud-native core' lost)."* That
spec itself is scoped to a narrower, still-live guarantee — **D9a**, constitution availability
during Mac-down intervals (`LIVE`/`DEGRADED`/`DOWN`, per its own state table) — which this
proposal does not touch at all. D9 proper is the broader rejection: don't build a second,
independently-maintained implementation of Bridge's routing/security/tool logic in the cloud.

That's a real risk, and it's *already half-happening* by accident, not by design: `kup-worker`'s
`src/catalog.ts` is a **hand-copied 19-entry stand-in** for NL-2's 19-row table (`TOOL_CATALOG`
in `catalog.ts:21-84`), maintained independently of the source table in
`docs/neutral-layer/NL-2-local-vs-cloud-split.md` and independently of the Mac's own
`ToolAnnotationCatalog`. Two catalogs that are supposed to agree but have no shared source of
truth is exactly the shadow-authority shape D9 was written to prevent — it just hasn't drifted
yet because nothing downstream of it does real work.

**This proposal reopens D9 only this far:** real execution behind the *already-designed*
`site: "cloud"` branch (`kup-worker/src/handlers.ts:227-237`), for a small, explicit,
server-enumerated allowlist of low-blast-radius, operator-own-scope tools — not a new
architecture, not a parallel reimplementation of routing/security logic, not a Mac replica. If
what Isaiah has in mind is broader than that — an independent cloud brain, not a thin executor
behind an existing, narrowly-scoped branch — that's a materially different ask than what's
designed below, and should be named explicitly before build starts, because it would need its
own threat model, not an extension of this one.

**Recommendation for the catalog-drift problem specifically (small, cheap, do it in wave 1
regardless of anything else in this doc):** stop hand-maintaining `catalog.ts` as prose-derived
data. Either generate it from `NL-2-local-vs-cloud-split.md`'s table at build time, or — cheaper
— add a CI check (mirroring the `ToolAnnotationCatalog` hard-fail pattern already used for the
Mac's tool surface) that fails when a tool exists in one catalog and not the other, or when
`requiresMac` disagrees between the two. This doesn't have to ship before wave 1; it should ship
before wave 2 adds any tool to the allowlist, because that's when drift starts costing real
authorization mistakes instead of just discrepancies on paper.

---

## 3. The one finding that gates everything else

Before any architecture discussion: **`kup-worker/src/handlers.ts`'s `handleRoute` never
consults `TOOL_CATALOG`.** Confirmed by direct read (`handlers.ts:199-279`) and by grep — zero
references to `TOOL_CATALOG` anywhere in `handlers.ts` or `router.ts` (`catalog.ts` is imported
only by `liveness.ts`, for the `/t/:tenantId/tools` *listing* endpoint, not the `/route`
*execution* endpoint). The boolean that decides whether a call executes cloud-side or gets
Mac-delegated — `requiresMac` — is read directly from the **client-supplied request body**:

```ts
// handlers.ts:209-214
let body: {
  operation?: string;
  connectionId?: string;
  paramsHash?: string;
  requiresMac?: boolean;
} = {};
...
// handlers.ts:227-237
// Cloud-only call: execute in control plane, never wake the Mac (NL-2 inv 5).
if (!body.requiresMac) {
  return { status: 200, body: { tenantId: tenant.tenantId, site: "cloud" as const, operation: body.operation } };
}
```

`catalog.ts`'s NL-2 classification exists only as data served to the `/t/:tenantId/tools`
listing endpoint (via `liveness.ts`'s `buildToolsList`). It is **never used as an authorization
check** at the one endpoint that actually routes execution.

This is inert today only because the `site: "cloud"` branch is a no-op echo with no real Notion
I/O — there's nothing to bypass into yet. The moment this proposal's own deliverable (real
execution behind that branch) ships, this becomes a live authorization bypass: any client —
malicious or merely buggy — can set `requiresMac: false` for an operation NL-2 classifies as
Mac-delegated, including **NL-2 row 19: any client-scoped call**, the one thing D3 promises
never leaves the Mac. `resolveOwnedTenant` (`router.ts:33-46`) correctly stops a caller from
routing to *another owner's* tenant — that check is real and good — but it does nothing about a
caller misclassifying *their own* call's routing tier.

Per NL-2 itself, this is a violation of two invariants the document already states as
requirements, not suggestions:

> **Invariant 2 — Scope before split.** Vendor scope is resolved first; the two-clause rule
> runs against the resolved scope.
> **Invariant 3 — Fail closed on client scope.** If scope resolves to a client, the call is
> Mac-delegated even if a cloud path exists... never default to cloud.

`handleRoute` does neither: it never resolves scope server-side, and it takes the client's word
for which branch to take. **Fixing this — moving routing authority server-side, keyed by
`operation` against the catalog, with the catalog also fixed to not silently drift (§2) — is the
prerequisite for everything in §4, not a follow-up.** See the Ship Gate in §6, item 1.

---

## 4. Design — the narrow, real version

### 4.1 Shape

Not a new architecture. NL-2/NL-3 already specify the correct split: cloud-only tools execute in
the control plane; Mac-delegated tools get a minted capability relayed to the Mac and never
execute cloud-side. What's missing is (a) the §3 enforcement fix that makes the split
trustworthy instead of merely documented, and (b) real execution behind the cloud-only branch,
for a narrow allowlist. This proposal is scoped to exactly those two things.

**Explicitly out of scope for this wave:**
- Any execution of NL-2 row 19 (client-scoped) calls cloud-side, ever — D3 is not V1-scoped, it
  is permanent (§5).
- Turning on `RemoteAccessSection.modelAEnabled` / any Mac-delegated flow through this worker —
  blocked on the device-binding gap (§4.2, T4).
- A parallel reimplementation of Bridge's routing/security-tier logic in the worker (§2).
- Any tool whose real implementation is Mac-resident regardless of its NL-2 row label (§4.3 —
  this is a real, separate gap from T3, see below).

### 4.2 Threat model (mirrors `TUNNEL-THREAT-MODEL.md`'s structure, applied to the cloud tier)

**Assets behind the cloud tier:** the WorkOS JWKS trust root (anything that verifies as a valid
owner session) · `CAPABILITY_SIGNING_SECRET` (authority to mint a capability commanding *any*
registered Mac node, once Mac-delegation is ever turned on) · `WORKOS_API_KEY` (scope
unconfirmed, see T2) · the tenant registry (owner↔device↔connection map) · once wave 1 ships:
read access to the operator's own Notion workspace via a cloud-held token.

| # | Threat | Confirmed / Theoretical | State today | Mitigation (proposed) |
|---|---|---|---|---|
| **T1** | `CAPABILITY_SIGNING_SECRET` compromise → attacker mints arbitrary capabilities for any owner/device/operation | Theoretical — path dormant, `modelAEnabled = false` | Not deployed; secret is a Wrangler secret, never committed (verified) | Rotation is the kill switch — HMAC verify fails instantly for all outstanding capabilities on rotation. Document this as an incident-response primitive (not written down today). Restrict who can `wrangler secret put` it. Do not flip `modelAEnabled` until T4 is fixed. |
| **T2** | `WORKOS_API_KEY` compromise — scope may extend beyond this one exchange grant to broader org/IdP control | Real secret confirmed (`auth-exchange.ts:20-21,51-60`); scope **unconfirmed** from this repo | Never logged (verified — only `workosError` code relayed, never raw payload); Wrangler secret | Confirm with WorkOS whether a restricted-scope key exists limited to the `authenticate` grant. If not, treat as tier-0 (root-equivalent): gate deploy access, add use-volume alerting. |
| **T3** | **`handleRoute` trusts client-supplied `requiresMac`; `TOOL_CATALOG` never consulted at the enforcement point** | **CONFIRMED live gap** (`handlers.ts:213,228`; zero `TOOL_CATALOG` references in `handlers.ts`/`router.ts`, confirmed by grep) | Inert only because `site:"cloud"` is a no-op echo | **Priority 0, blocking.** Server resolves `requiresMac` from the catalog keyed by `operation`, never from the client. Mismatch (client claims `false`, catalog says `true`) is rejected **and logged as a security event**, not silently corrected. Ships in the same PR as any real execution wiring, not after. See §3, §6.1. |
| **T3b** | **A tool's NL-2 catalog label can disagree with what it actually touches** — e.g. `job_list` is labeled cloud-only (`catalog.ts:82-83`, "row 18") but the real Bridge `job_list` tool (`TheBridge/Modules/JobsModule.swift:83-87`) reads `JobsManager.shared`, which is backed by a raw SQLite3 file at `~/Library/Application Support/The Bridge/jobs/jobs.sqlite` (`JobsManager.swift:38-40`), tied to real per-job LaunchAgents, with **zero cloud copy of job state anywhere**. Fixing T3 makes the catalog authoritative for *routing*, but the catalog can still be *wrong* about a tool's real locality. | **CONFIRMED** (this specific tool; treat as a class of risk, not a one-off) | N/A — no cloud executor exists for this tool today | Do not build a cloud executor for `job_*`/`snippets_*` by "following the catalog." These stay a **permanent scope carve-out**, not a wave-2 deferral — the catalog's row-18 "cloud-only" label describes an aspirational architecture (a cloud-stored job registry) that was never built; the concrete implementation is Mac-resident by construction and would need its own migration project (replicating or moving job state itself) before it could honestly be cloud-executed. See §4.3. |
| **T4** | Device-binding / proof-of-possession is not real anywhere. NL-3 D-NL3.4 specifies `cnf` = a device **public-key thumbprint** (proof-of-possession); the actual mint (`capability.ts` via `handlers.ts:259`) sets `cnf` to `` `dev:${tenant.deviceId}` `` — a string derived from a client-self-reported `deviceId` at `/provision`, not a cryptographic key. `TheBridge/Modules/Cloud/DelegatedCapability.swift`'s `deviceMismatch` check (line 213-215) is a bare `capability.deviceID == node.deviceID` string compare — no key material on either side. NL-3's own end-to-end sequence (step 5: "the Mac proves possession of its device key (`cnf`) on the channel") describes a guarantee that doesn't exist in code on either side. | **CONFIRMED, end-to-end** | Pure placeholder, both sides | Out of *this* proposal's execution path (cloud-only tools only, no Mac-delegation) but a **hard blocker for ever setting `modelAEnabled = true`**, and for ever routing row-19/client-scope work through this worker. Track as its own prerequisite packet before NL-3 delegation is turned on for real. |
| **T5** | No rate limiting on `/provision`, `/heartbeat`, `/route`, `/auth/exchange` | Confirmed — no rate-limit code, no Cloudflare rule referenced in repo | None | Cloudflare-native rate-limit rules per route. Zero application code required. Day-1, not optional — this is now a secret-holding, JWT-terminating surface, a materially bigger prize than the tunnel's T7 (which was accepted as out-of-scope for a *reverse proxy*, not a compute+identity surface). |
| **T6** | `InMemoryStore` hardcoded in prod (`index.ts:17,56`) despite `wrangler.toml` already provisioning a real `TENANTS` KV binding (`id = "8e40ac0680b04987b59b56df54c09bde"`) that's never referenced anywhere in `src/`. Liveness state is per-isolate — doesn't survive cold start or replicate across colos. | **CONFIRMED** | Dead binding | Wire the KV/DO store for real before any execution ships. Add an integration test exercising liveness across a simulated multi-isolate scenario — today's "fail closed when Mac offline" (NL-3 step 3) is not reliably enforced in a real multi-region deploy. |
| **T7** | No monitoring / alerting / logging anywhere in the worker | **CONFIRMED** — zero hits for sentry/alert/monitor/logtail/axiom/datadog across `src/`, `wrangler.toml`, README, runbook | None | See §6.4 — non-negotiable, not optional. |
| **T8** | `/auth/exchange` is unauthenticated-by-design (necessarily — it's pre-session) and proxies a WorkOS `authorization_code` grant (`auth-exchange.ts:56-63`) with no visible replay protection beyond whatever WorkOS enforces upstream; PKCE usage is not verifiable from this repo | Partially confirmed — sound *if* PKCE is used Mac-side; **unconfirmed either way** | Relies entirely on WorkOS's own code single-use/short-TTL semantics | Confirm Mac-side PKCE (`code_verifier`) is in use in `TheBridge/Modules/Cloud/CloudAuth.swift` before go-live. If absent, add it — a leaked/logged `code` should not be redeemable by whoever reaches this endpoint first. |
| **T9** | `wrangler.toml`'s own header says *"CONFIG ONLY. This repo does not deploy as part of its build"* yet it contains live production identifiers (real WorkOS client/tenant IDs, a real KV namespace id, a real zone route on `bridge.kup.solutions`) checked into git, and `deploy.sh` exists and will act on them with none of this repo's review ceremony (no test-floor-gate equivalent, no `ToolAnnotationCatalog`-style hard-fail audit) | **CONFIRMED** | `deploy.sh` has a `DRY_RUN` mode (good) | Add the Ship Gate checklist below as a required, scripted step — not just a runbook a human can skip — before `deploy.sh` ever runs against `bridge.kup.solutions` for real traffic. |

### 4.3 Tool scope — narrow, and honest about what's actually cloud-resident

Order by blast radius, not convenience, and — per T3b — by *actual* implementation locality, not
just the catalog label:

- **Wave 1 (ship first):** `fetch_skill` / routing reads (NL-2 row 13 — pure reads against the
  cloud skill registry, which genuinely is cloud-resident), `http_fetch` (row 17 — no vendor
  credential involved at all), `notion_query` / `notion_search` / `notion_page_read`
  **read-only** (row 16, operator's own token only).
- **Held back to wave 2+**, after a burn-in period on wave 1 with the monitoring in §6.4 live:
  `skill_create`/`skill_update`/`skill_delete` (row 12 — mutates the cloud registry),
  `plugin_install` (row 14 — provisions new trust relationships, arguably the highest-leverage
  single action in the whole catalog since it can add new credential-bearing connectors), any
  Notion *write* (`page_update`, block writes).
- **Permanent carve-out, not a wave-2 deferral:** `job_*` / `snippets_*` (row 18). Per T3b, the
  concrete implementations are Mac-resident SQLite + LaunchAgents with zero cloud copy of state.
  Building a cloud executor "because the catalog says row 18 is cloud-only" would mean either
  quietly building a second, divergent job store (the D9 shadow-authority failure mode again) or
  silently no-op'ing writes. Neither is acceptable. If a cloud-resident jobs registry is ever
  wanted, that's its own project — state migration, not routing.
- **Never, regardless of wave:** row 19 (any client-scoped call, any vendor) — see §5.

### 4.4 Credentials — scoped and short-lived over long-lived

- Owner sessions: already a real WorkOS RS256 JWT verifier (`identity.ts` — signature check,
  `iss`/`aud`/`exp`/`nbf`, JWKS caching with rotation-on-miss). This is a genuine strength, not a
  gap — call it out. Confirm access-token TTL is short (WorkOS defaults are minutes) and that
  `/auth/exchange` rotates the refresh token on each use.
- Inter-service secrets (`CAPABILITY_SIGNING_SECRET`, `WORKOS_API_KEY`): already Wrangler
  secrets, never committed — keep it that way, add a rotation runbook (T1/T2), and treat
  rotation as the standing incident-response primitive for capability compromise.
- **New for this wave:** the cloud tier's Notion access should use a **separate, more narrowly
  scoped Notion integration token** from whatever the Mac's `NotionClientRegistry` uses — not
  the same credential reused across trust boundaries. A worker compromise should not inherit the
  Mac's full Notion capability. This is the concrete "prefer scoped over long-lived" answer for
  the one vendor credential wave 1 actually touches.
- No caching of Notion content or tokens cloud-side in wave 1 (ties to §4.5) — hold no vendor
  token in memory longer than one call's duration.

### 4.5 Data at rest — minimum viable, encrypted where it exists

Today: `InMemoryStore` only (T6) — ephemeral, but also not durable enough to trust for the
offline-fail-closed guarantee across cold starts. Before go-live: wire the already-provisioned
KV binding for real, and store the **minimum**: `tenant_id`, `owner_id` (opaque IdP subject),
`device_id`, `connectionRef`, `lastSeenAt`. No tokens, no Notion content, no vendor payloads
persisted cloud-side, ever — this is the same "relay carries no payload at rest" principle NL-2
Invariant 4 already commits to for the Mac-delegated path; hold the cloud-only path to the same
bar. If a future wave needs caching (e.g. to reduce Notion rate-limit pressure), it must be
TTL-bounded, per-tenant isolated (extend the existing `isolation.test.ts` to cover the real KV
store, not just `InMemoryStore`), and envelope-encrypted per D4's own language ("per-tenant keys
in a KMS, decrypt-in-memory-only, never logged") if it ever holds anything token-shaped.

### 4.6 Enforcement & anti-replay — the load-bearing section

This is where T3 and T4 live, restated as the design requirement: **the server decides routing,
never the client.** `operation` resolves against the (now-fixed, non-drifting per §2) catalog; a
mismatch between what the client claims and what the catalog says is a rejected request and a
logged security event, full stop. This is not a hardening pass to schedule later — it's the
difference between "the cloud tier executes what NL-2 says it may" and "the cloud tier executes
whatever any client tells it to," which is a straight authorization bypass onto exactly the
class of work (row 19, client accounts) D3 promises never leaves the Mac. Ship in the same
change as real execution, not as a follow-up ticket.

Secondary, cheap, worth doing now: add a cloud-side `jti` issuance ledger (redemption-checking
stays Mac-side per NL-3 D-NL3.7) so there's an administrative revoke primitive. Today there is no
way to invalidate one already-minted capability short of rotating the signing secret for
*everyone*. A `POST /admin/revoke {tenantId}` (or equivalent) closes a real operational gap
cheaply, even though wave 1's tool scope never mints capabilities at all (T4 blocks that path).

### 4.7 Vocabulary — three names for the same thing today

Right now the same underlying "is the Mac reachable" question is answered by three different,
unreconciled vocabularies:

- **The Mac's own `CloudConnectionState`** (`BridgeCloudManager.swift:35-40`):
  `disabled`/`connecting`/`online`/`degraded`/`offline`.
- **The worker's `liveness`** (`kup-worker/src/liveness.ts:18-19,26-28`): binary
  `"online"`/`"offline"`, threshold-based (30s of silence).
- **`DEGRADED-MODE-SPEC.md`'s** own client-facing states (D9a): `LIVE` / `DEGRADED (bridge up,
  source stale)` / `DOWN (bridge unreachable)`.

None of these map onto each other cleanly (e.g. what does the Mac's `degraded` mean to a client
reading the worker's binary `online`/`offline`, or to D9a's three-state model?). A client
juggling all three today gets an inconsistent story depending on which surface it asks. Before
wave 1 ships a client-visible status anywhere, write a one-page mapping (even just a table) that
says which Mac states map to which worker liveness value and which D9a tier, and pick one
vocabulary as the one clients are told about — probably D9a's three-state model, since it's
already the one meant to be client-facing. This is cheap and avoids a confusing user-facing
"why does it say online but not connected" experience once there's real traffic to be confused
about.

---

## 5. The D3 client-work carve-out — explicitly reaffirmed, not reopened

D3 is not touched by this proposal. Restated precisely because it's the thing most likely to
erode by accident as this ships:

- **Client-account work is permanently Mac-present.** The 2026-05-30 client-SLA ruling in
  `product-strategy.md` §4 D3 is explicit: "there is no laptop-off mode for client accounts, and
  the answer to 'can it run for my client overnight?' is **no**." This proposal does not change
  that answer. Nothing in wave 1's allowlist (§4.3) touches a client account, by construction —
  every wave-1 tool operates on the operator's own token/scope only.
- **NL-2 row 19 stays Mac-delegated, always**, regardless of what T3's fix classifies any other
  tool as. The T3 fix (§3, §6.1) is precisely what makes this guarantee real instead of aspirational
  — today a client *could* claim `requiresMac: false` for a row-19 call and the worker would
  comply, which is a live path to violating D3 the instant real execution ships. Fixing T3 is
  what closes that path.
- **NL-3 Mac-delegation stays off** (`modelAEnabled = false`) through this entire proposal. Even
  once wave 1's cloud-only tools are live, no client-scoped or Mac-delegated call routes through
  `kup-worker` until T4 (device binding) is a real cryptographic guarantee, not a string compare.
  This is a second, independent backstop for D3: even if T3's catalog check somehow had a bug,
  D3-protected work still can't execute cloud-side because the delegation path itself is
  hardcoded off.
- **The carve-out belongs in the Supersession Log entry itself** (§1) so it can't quietly widen
  in a later edit — the suggested entry text explicitly restates it.

If a future wave ever proposes touching row 19 or flipping `modelAEnabled`, that is not an
extension of this proposal — it's a new D3 decision, and it reopens both this document's threat
model and D3 itself, with its own Ship Gate pass.

---

## 6. Phased implementation plan (design, not implementation)

### Phase 0 — Prerequisite fixes (block wave 1 tool traffic)
1. **T3 fix**: server-side catalog enforcement in `handleRoute`, replacing the client-trusted
   `requiresMac` field. Land as its own PR against `kup-worker`, independent of everything else
   — it's a correctness/security fix in code that already exists, valuable regardless of whether
   the rest of this proposal proceeds.
2. **Catalog drift guard** (§2): CI check or generation step so `catalog.ts` can't silently
   diverge from `NL-2-local-vs-cloud-split.md` or the Mac's `ToolAnnotationCatalog` again.
3. **T3b carve-out documented** in `catalog.ts` itself (comment + a `neverCloudExecutable: true`
   flag or equivalent) for `job_*`/`snippets_*`, so the next person touching this file doesn't
   quietly build the cloud executor the label implies.

### Phase 1 — Infrastructure (no product surface yet)
4. Wire the real KV/DO store (T6), replacing `InMemoryStore` in prod.
5. Rate limiting live on all four endpoints (T5), verified against the actual Cloudflare config.
6. Structured logging + the alert set in §6.4 wired to a real notification channel (T7).
7. Kill switch (`CLOUD_TIER_ENABLED` or equivalent, checked first in `handleRoute`)
   implemented and drilled once — flip it, confirm 503s within a chosen SLA.
8. `WORKOS_API_KEY` scope confirmed/minimized with WorkOS support (T2); if unscoped, documented
   as tier-0 and access-restricted.
9. Confirm Mac-side PKCE is in use for `/auth/exchange` (T8); add it if absent.
10. Vocabulary mapping written (§4.7).

### Phase 2 — Wave-1 tool allowlist, canary of one
11. Ship the read-only allowlist from §4.3 wave 1, hardcoded server-side (not "everything
    the catalog marks cloud-only minus the risky ones" — an actual enumerated list `handleRoute`
    checks against, separate from and stricter than the general T3 catalog check).
12. Separate, narrowly-scoped Notion integration token for the cloud tier (§4.4).
13. Supersession Log entry committed (§1) — alongside this step, not before, so it points at
    something real rather than a promise.
14. Canary-of-one burn-in: Isaiah is the only tenant. No second tenant provisioned until the
    alerting in §6.4 has run clean for a deliberate window (recommend at least one full week
    with zero unexplained signal).

### Phase 3 — Everything else stays a separate, later decision
15. Wave-2 tools (skill mutation, plugin install, Notion writes) — each is its own go/no-go
    against the burn-in data from Phase 2.
16. T4's device-binding fix (real proof-of-possession) — its own prerequisite packet.
17. Ever flipping `modelAEnabled` — reopens this document, D3, and NL-3's Ship Gate, together.

**Ship Gate checklist** (mirrors `TUNNEL-THREAT-MODEL.md`'s convention; commit this proposal's
threat model as `docs/wave1/CLOUD-TIER-THREAT-MODEL.md` before Phase 2 traffic goes live):

1. T3 fix shipped **and integration-tested** — a request claiming `requiresMac: false` for a
   catalog-`true` operation is rejected, verified against a real request, not just a unit test
   with matched pairs (all that exists today).
2. Real KV/DO store wired; liveness verified consistent under a simulated cold-start/multi-isolate scenario.
3. Rate limiting live, verified against the actual Cloudflare config.
4. Structured logging + the §6.4 alert set wired to a real channel.
5. Kill switch implemented and drilled once.
6. `WORKOS_API_KEY` scope confirmed/minimized or documented as tier-0.
7. Wave-1 tool allowlist hardcoded server-side — no write/mutating/trust-provisioning tool
   reachable through the cloud-only path.
8. Supersession Log entry added (§1).
9. `job_*`/`snippets_*` carve-out documented in `catalog.ts` (§2, §4.3).

**Standing rule** (mirrors the tunnel doc verbatim in spirit): any expansion of cloud-tier tool
scope, any move to wire Mac-delegation through this worker, or any change to the custody model
re-opens this document and requires a new Ship Gate pass.

---

## 7. Alerting and rollback — non-negotiable, not optional

- **Structured logging** on every `/provision`, `/heartbeat`, `/route`, `/auth/exchange` call:
  status, latency, `operation`, and — critically — the client-claimed `requiresMac` vs. the
  catalog-resolved value, so mismatches are visible, not just rejected.
- **Alerting**, wired to a real channel before go-live:
  - any `requiresMac` mismatch (should be zero in steady state — page on any occurrence; it's
    either an active bypass attempt or a shipped bug);
  - `/auth/exchange` failure-rate spike (stolen-code / credential-probing signal);
  - per-tenant capability-mint rate anomalies (build the hook now even though wave 1 never mints
    capabilities — T4 blocks that path, not the observability for it);
  - worker 5xx rate (Cloudflare Analytics is sufficient — just needs a threshold and destination);
  - secret-rotation reminders for `CAPABILITY_SIGNING_SECRET` / `WORKOS_API_KEY` (calendar-based,
    e.g. 90 days).
- **Kill switch:** a single env-checked flag gating the whole tenant-execution surface, drilled
  once before go-live. Mirrors the exact pattern already proven useful on the Mac side
  (`RemoteAccessSection.modelAEnabled = false` — cheap, effective, already caught one bad
  rollout per its own code comment).
- **Staging + integration tests against real dependencies:** today's tests are all unit-level
  with injected fakes (`InMemoryStore`, injected `fetch`). Add at least one integration test path
  against a real (test-tenant) WorkOS JWKS endpoint and a real KV namespace before trusting this
  in production.

---

## 8. Open questions for the operator

These require Isaiah's judgment, not another investigation pass:

1. **Is there actually a concrete task behind D5's trigger, or is this a proactive build?** Name
   it for the Supersession Log entry (§1) — or say plainly it's proactive. Either is fine; a
   fabricated one isn't.
2. **Budget for an always-on Worker + KV/DO.** Cloudflare Workers paid-tier pricing scales with
   requests/duration; a real KV or Durable Object store adds its own cost line. Worth pricing out
   before Phase 1 wiring starts, not after.
3. **Who else, if anyone, is meant to use this?** The design above assumes canary-of-one
   (Isaiah only) through the whole burn-in window. If there's a nearer-term plan to onboard a
   second tenant (e.g. "Sell The Bridge" territory), that changes the priority ordering — T4
   (device binding) and the isolation tests move up, because multi-tenant makes T3/T4 gaps
   externally exploitable rather than self-inflicted.
4. **WorkOS key scoping (T2)** — this requires an actual support conversation with WorkOS, not
   something resolvable by reading this repo. Worth doing early since it may change how tier-0
   the key needs to be treated.
5. **Does "reopening D9" mean anything broader than what's scoped in §3?** If the intent is a
   genuinely independent cloud brain rather than a thin executor behind the existing
   `site: "cloud"` branch, that's a different, bigger proposal — worth confirming the scope
   before Phase 0 starts, since the two designs diverge from the first line of code.

---

## Key files referenced

- `/Users/keepup/Developer/kup-worker/src/handlers.ts` — T3, the enforcement gap (`handleRoute`, line ~199-279, esp. 213/228)
- `/Users/keepup/Developer/kup-worker/src/router.ts` — `resolveOwnedTenant`, cross-tenant guard that exists but doesn't cover T3
- `/Users/keepup/Developer/kup-worker/src/catalog.ts` — the unconsulted classification table (`TOOL_CATALOG`, lines 21-84)
- `/Users/keepup/Developer/kup-worker/src/capability.ts` and `/Users/keepup/Developer/the-bridge/TheBridge/Modules/Cloud/DelegatedCapability.swift` — T4, device-binding unimplemented on both sides
- `/Users/keepup/Developer/kup-worker/src/store.ts` and `wrangler.toml` — T6, dead KV binding
- `/Users/keepup/Developer/kup-worker/src/identity.ts` — verified real RS256/JWKS verifier, not a stub
- `/Users/keepup/Developer/kup-worker/src/auth-exchange.ts` — T8, `/auth/exchange` code→token relay
- `/Users/keepup/Developer/kup-worker/src/liveness.ts` and `/Users/keepup/Developer/the-bridge/TheBridge/Modules/Cloud/BridgeCloudManager.swift` — §4.7, the three unreconciled liveness vocabularies
- `/Users/keepup/Developer/the-bridge/TheBridge/Modules/JobsManager.swift`, `JobsModule.swift` — T3b, `job_list`'s real Mac-resident SQLite implementation vs. its cloud-only catalog label
- `/Users/keepup/Developer/the-bridge/docs/wave1/TUNNEL-THREAT-MODEL.md` — the convention this document extends
- `/Users/keepup/Developer/the-bridge/docs/product-strategy.md` §4 (D3, D4, D5, Supersession Log)
- `/Users/keepup/Developer/the-bridge/docs/neutral-layer/NL-2-local-vs-cloud-split.md`, `NL-3-cloud-mac-delegation-authpassdown.md`
- `/Users/keepup/Developer/the-bridge/docs/wave1/DEGRADED-MODE-SPEC.md` — D9a, the narrower guarantee this proposal doesn't touch
- `/Users/keepup/Developer/the-bridge/TheBridge/UI/Sections/RemoteAccessSection.swift` — `modelAEnabled = false`, the existing kill-switch pattern this proposal reuses
