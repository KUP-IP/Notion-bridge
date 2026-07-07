# PKT-1065D — Initiate/Execute Command Alignment (Proposal, NOT applied)

Status: **PROPOSAL — awaiting SKILLS Keepr route receipt**
Packet: Notion `38ecbb58-889e-81b3-8ac9-c2dc9bb3c34d` — "Bridge V4 · Deterministic
Initialization Architecture" (executionClass REVIEW-FIRST)
Sub-packet: **D** of 4 (A/B/C already merged — commits `c8039b2`, `9e0c69a`,
`fabc4d6`, PRs #77/#78/#79)
Author: app-dev executor session, 2026-07-03

## Why this is a proposal doc, not a code/command change

The packet's own Stop Condition is explicit:

> Stop in REVIEW if command alignment requires a skill-governance change not
> covered by a current route receipt.

`Initiate` and `Execute` are **user-authored governed commands** — markdown
bodies living in `CommandStore` (`~/Library/Application Support/The Bridge/
commands/{initiate,execute}.md`, mirrored to Notion), not compiled Swift. Per
live `skills_routing_list`, `skill-keepr` (SKILLS Keepr) is:

> "the mandatory front door for any request that creates, changes, inspects,
> tests, registers, routes, or governs a KEEP OS skill or **command**."

Editing these two command bodies is exactly that. This session has no SKILLS
Keepr route receipt and cannot self-issue one (that is an operator/routing
decision, not an app-dev executor action). So this document specifies the
exact proposed change — for a human or a SKILLS-Keepr-routed session to apply
— rather than editing the live command store or the Notion mirror.

There is also **no remaining code-level work** for this sub-packet: sub-packets
A/B/C already built and shipped every primitive D needs to delegate to
(`bridge_initialize` MCP tool, live routing roster via `skills_routing_list`,
`executor`'s packet-only placement per `docs/operator/agent-handshake-
contract.md` Decision 3). D is a pure content/governance change.

## Current state (verified live, 2026-07-03)

**Initiate** (`commands_search` → slug `initiate`, current body on disk):
tells the agent to separately call `bridge_status`, read standing-orders
doctrine, call `skills_routing_list`, call `standing_orders_list`, then
**narratively construct its own init receipt** (Bridge state, doctrine
version, routing roster, supplemental count, COMPLETE/DEGRADED/INCOMPLETE) —
i.e. it re-implements, in prose, exactly what `bridge_initialize`
(PKT-1065A, live since `c8039b2`) already computes and durably persists in
one call. This is the "duplicated startup-protocol prose" the packet's Core
Scope calls out to eliminate.

**Execute** (slug `execute`, current body on disk): "Set in stone:
`fetch_skill('executor')`. Size gate: more than 3 files or more than 2
domains → `fetch_skill('orchestrator')` and dispatch before material work.
Otherwise executor solo." This fetches the executor specialist directly. Per
the live routing roster, `executor`'s own anti-trigger phrases list "Scope or
author a packet" and require a SKILLS Keepr route receipt for skill-system
writes — and `docs/operator/agent-handshake-contract.md` Decision 3 already
established `executor` is deliberately **packet-only, not a routing owner**:
"exposing executor as a routing owner invites agents to bypass
orchestration." Jumping straight to executor skips resolving the parent
Keepr (content-keepr / focus-keepr / mac-keepr / notion-keepr / people-keepr
/ skill-keepr / time-keepr) that should own the request first — the exact
drift the packet's Observed System State records: "The Execute command
directly fetches executor, while the loaded doctrine requires parent-Keepr
routing before specialist selection."

## Proposed `initiate.md` (replaces "Set in stone" paragraph only)

```diff
 Set in stone:
-Run the full Bridge initialization sequence — bridge_status, standing orders
-doctrine, skills_routing_list, standing_orders_list, then emit a complete
-init receipt (Bridge state, doctrine version, routing roster, supplemental
-count, COMPLETE or DEGRADED or INCOMPLETE).
+Call bridge_initialize once (pass `intent` only if the opening request
+names a concrete domain need, e.g. reminders — omit it for a universal,
+data-minimal handshake). Render its receipt: bridgeState, doctrineVersion,
+finalState (COMPLETE/DEGRADED/INCOMPLETE), capabilityState (FULL/LIMITED/
+UNAVAILABLE — reported separately from finalState), routingRosterState +
+routingWarnings, supplementalOrderCounts (found/operative/ignored), and any
+capabilityNotes. Do not re-derive these fields by calling bridge_status,
+skills_routing_list, or standing_orders_list separately — bridge_initialize
+already calls through to them and persists one durable receipt per
+handshake.
```

Rationale: this is the minimum edit that removes the duplicated sequence
without touching the rest of Initiate's voice/identity/exit contract (Success
Criterion: "The Initiate command delegates to the canonical initializer and
does not maintain a second startup sequence"). `intent` stays optional and
undirected by default, matching PKT-1065C's data-minimal-by-default design —
Initiate should NOT hardcode a reminders (or any) intent; it should pass
through whatever the opening request actually signals, or omit it.

## Proposed `execute.md` (replaces "Set in stone" paragraph only)

```diff
 Set in stone:
-fetch_skill('executor'). Size gate: more than 3 files or more than 2
-domains → fetch_skill('orchestrator') and dispatch before material work.
-Otherwise executor solo.
+Resolve the parent Keepr first: call skills_routing_list (or reuse the
+roster from this session's bridge_initialize receipt) and match the
+approved plan's domain to a routing owner (content-keepr, focus-keepr,
+mac-keepr, notion-keepr, people-keepr, skill-keepr, time-keepr). Let that
+Keepr select the executor or orchestrator — do not fetch_skill('executor')
+directly. Size gate (more than 3 files or more than 2 domains → dispatch
+via orchestrator) is a secondary heuristic the parent Keepr applies, not a
+replacement for domain ownership. Any skill/command-governing change
+(create/change/inspect/test/register/route a skill or command) routes
+through skill-keepr regardless of size.
```

Rationale: matches the packet's Success Criterion — "The Execute command
follows parent-Keepr routing and uses executor or orchestrator only after
domain ownership is resolved" — and closes the exact gap the Observed System
State names. File/domain counts stay as a secondary heuristic per the
packet's Core Scope ("File and domain counts may remain secondary
heuristics"), now applied by the parent Keepr rather than replacing routing.

## What this does NOT change

- Initiate's identity/voice/exit-condition prose (untouched — only the "Set
  in stone" mechanical paragraph is replaced).
- Execute's "Define done with tests," "Agency," "Creative latitude," and
  final-summary paragraphs (untouched).
- No Swift/tool-surface code changes — `bridge_initialize`, `skills_routing_
  list`, and the routing roster are all already live from A/B/C.
- No `CommandStore.swift` schema or `firstRunSeeds` change — this proposal
  is about the *content* of the live/mirrored command bodies, which is data,
  not code. (`firstRunSeeds` seeds a shorter "Execute" variant for first-run
  UX; whether to update that seed template too is an open question below.)

## Open questions for the operator / SKILLS Keepr route

1. **Route mechanics**: should this proposal be applied by (a) the operator
   editing the command bodies directly in Settings → Commands / Notion, or
   (b) a fresh session routed through `skill-keepr` with this doc as the
   change manifest? The packet's Stop Condition implies (b) is the doctrinal
   path; (a) is faster but bypasses the front door this packet's own
   architecture depends on.
2. **`firstRunSeeds` in `CommandStore.swift`** ships a condensed "Execute"
   body (`.emoji("⚡")`, orange) for brand-new installs that never touch
   Notion. Should that seed also get the parent-Keepr-routing edit, so a
   fresh install doesn't regress the moment it seeds? This IS a code change
   (a Swift string literal) and would NOT need a SKILLS Keepr receipt in the
   same way — it's app-shipped scaffolding, not a live governed command —
   but it's still worth an explicit decision since it's the same prose
   living in two places (seed template vs. live/Notion-mirrored command).
3. **Intent classification for Initiate**: `PreflightIntent.classify(_:)`
   (PKT-1065C) currently only recognizes reminders-shaped intent. If Initiate
   starts passing through free-text `intent`, should the classifier's
   `.none` fallback be considered final for this sub-packet, or does
   broadening the intent taxonomy belong to a future capability-preflight
   adapter (packet explicitly scopes Reminders as "the first implemented
   adapter" — implying more will come)?
4. **Verification of the applied change**: once a SKILLS Keepr route
   receipt authorizes the edit, the acceptance check is behavioral (does a
   live Initiate/Execute invocation actually call `bridge_initialize` /
   resolve parent-Keepr first?) rather than a Swift unit test, since command
   bodies are prose interpreted by the calling agent, not code. Suggest a
   manual on-device transcript check (dated, filed under
   `docs/operator/`) as the closeout evidence for D, mirroring how A/B/C
   closed with live-verify evidence rather than only green CI.

## Relationship to the rest of the epic

Sub-packets A (`c8039b2`), B (`9e0c69a`), C (`fabc4d6`) are merged to `main`
and independently verified in this session:
- `bridge_initialize` MCP tool exists, live, tier `.open`
  (`TheBridge/Modules/StandingOrders/BridgeInitializeModule.swift`).
- `session_info` now returns an explicit `scopes` block documenting uptime/
  clients/auditLogSize semantics and its independence from `bridge_status`
  (live-verified 2026-07-03: `session_info` → `scopes.note` present).
- `notion:default` is the live primary connection with `isPrimary: true`
  (live-verified via `connections_list`).
- Capability preflight (Reminders adapter) is wired into
  `BridgeInitializeService.run` via `CapabilityPreflightRegistry` /
  `RemindersCapabilityProbe`.

D is the last of four and is content-only. Once applied (by whichever route
the operator selects per Open Question 1), the epic's Success Criteria are
fully met and the packet can move to Done.
