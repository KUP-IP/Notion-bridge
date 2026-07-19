# PKT-CALL-001 — Prospecting Call Tools Suite (7)

**Slug:** `pkt-call-001-prospecting-call-tools`
**Execution Class:** REVIEW-FIRST
**Status:** REVIEW — Wave 1R merged via PR #111 (`6d8bd96`); Waves 2–3 deliberately deferred; W1R ≠ W2 authorized
**Priority:** 80
**Classification:** Standard (suite) · sequential waves inside one packet
**SKILLS:** orchestrator · executor · mac-keepr · people-keepr (consumer contract)
**PROJECT:** The Bridge (platform tools) · related ops: KUP Solutions prospecting
**Agent Type:** Implementation (Bridge MCP tools)

**Orchestrator source:** `focus-keepr/orchestrator` v7.1.x (packet architect protocol)
**Origin session:** 2026-07-16 — Prospect Execute + CallHistory recon

---

## Goal Contract

**Outcome:** Seven Bridge MCP tools ship so an agent can read Mac call history, log prospecting call touches into PROSPECTS/OUTREACH, run a Prospect Execute loop, join call+Messages timelines, prep dials, follow up after VM, and recommend next best actions — without inventing CONTACTS or auto-sending.

**Scope (in):**
1. `calls_recent` — read CallHistoryDB
2. `log_call_touch` — write OUTREACH + update PROSPECT from a call or operator claim
3. `prospect_execute_loop` — boot / tick / close for a Prospect block
4. `handle_timeline` — calls + Messages (+ optional mail later) for one handle
5. `dial_prep` — brief + talk track + open `tel:` via Phone
6. `vm_followup` — draft SMS/email after VM; wrong-number fork
7. `next_best_action` — call vs text vs pause vs warm intro for one prospect or queue

**Scope (out):**
- Call recording / live transcription
- Auto-dial spam or unattended mass dialing
- Auto-send SMS/email without operator confirm
- Auto-create CONTACT / CLIENT (conversion remains create+dispose with human or explicit GO)
- Treating CallHistory “answered” as full Phone Verified identity
- AppleScript Phone recents (dead end — use CallHistoryDB)
- iOS-only private APIs

**Constraints:**
- Local-first: CallHistory path `~/Library/Application Support/CallHistoryDB/CallHistory.storedata`
- TCC: Full Disk Access for The Bridge if required on some macOS versions
- Governance: read tools open/notify; write/log notify; send paths request + confirm
- Conversion law (ops): never move DS rows; create downstream + Status=Converted on source
- Tool count / floor gate: bump `staticFeatureModuleToolCount` + `make test-floor`
- Prefer shared primitives over one-off VoiceMemo-style triple round trips

**Success Criteria:**
1. All seven tools registered in ToolAnnotationCatalog with governance tiers
2. `calls_recent` returns Jeff-class rows (e.g. outbound unanswered ~74s to 6128403028 when present in history)
3. `log_call_touch` creates OUTREACH linked to PROSPECT and updates Last Touched / Next Action
4. `prospect_execute_loop` boot returns Top queue + unlogged dials since `since`
5. `handle_timeline` merges call + messages for a known number without inventing contacts
6. `dial_prep` opens Phone with `tel:` (system default Phone.app)
7. `vm_followup` returns draft text only (no send) unless confirm path used
8. `next_best_action` returns ranked options with reasons grounded in history
9. Unit/integration tests for parse/normalize/match; floor green
10. Operator brief documents how Prospect Execute uses the suite

**Verification:**
- `make test` / `make test-floor` green
- Live MCP smoke: `calls_recent` limit 10; match Jeff if in DB
- Live smoke: `log_call_touch` dryRun then real against a test PROSPECT
- Manual: dial_prep opens Phone; no Google Voice handler required
- Docs: AGENTS.md or operator packet note updated

**Execution Class:** REVIEW-FIRST
Ship to reviewable PR stack + smoke evidence; operator GO before merge to main / release.

**Review Requirement:**
- Reviewer: Isaiah (or Bridge code owner)
- Artifact: PR(s) + smoke transcript + tool catalog entries
- Decisions: Approve merge · Request changes · Park

**Failure / Stop Conditions:**
- CallHistory unreadable after FDA granted → BLOCKED with exact TCC steps
- Schema drift in ZCALLRECORD without adapter → REVIEW with mapping gap
- Any path that would auto-send or auto-convert CONTACT → stop, fix design
- Ambiguous multi-match prospect for a number → no silent write; return ambiguous

**Output / Brief Contract:**
- PR description with tool list + tiers
- Operator one-pager: Prospect Execute with tools
- Packet Runner Output sections filled on completion

## GOAL_CONDITION

Ship seven Bridge MCP tools (`calls_recent`, `log_call_touch`, `prospect_execute_loop`, `handle_timeline`, `dial_prep`, `vm_followup`, `next_best_action`) so Prospect Execute can read Mac CallHistory, log touches to PROSPECTS/OUTREACH, and recommend next actions within scope, proven by test-floor green and live MCP smoke on CallHistory + a PROSPECT row; REVIEW-FIRST before release; stop if FDA/schema blocks or auto-send/auto-convert would be required.

---

## Current System State & Context

**Proven on operator Mac (2026-07-16):**
- CallHistory SQLite readable at `CallHistoryDB/CallHistory.storedata`
- Columns usable: ZDATE, ZDURATION, ZORIGINATED, ZANSWERED, ZADDRESS, ZNAME, ZSERVICE_PROVIDER, ZORIGINATINGDEVICENAME
- Jeff O’Neill (6128403028): outbound, unanswered, ~74s VM-class duration logged same day
- PROSPECTS registry entity `prospect` bound to DS `97a4ae02-…`
- OUTREACH has PROSPECT relation; Status/Outcome include Voicemail
- Messages tools exist (`messages_chat`, `messages_recent`, …)
- Phone.app opens via `open -a Phone tel:…`; system `tel:` should be Phone (not Google Voice)
- No Bridge `calls_*` tools today

**Ops doctrine:**
- Invent PROSPECTS only after verification gate
- Contact = quality relationship; Client = paid
- Convert = create + dispose (Status=Converted), never move/delete
- Prospect Execute Top 5 from trades Excel + open PROSPECTS

**Context relevance list:**
- This packet + Bridge repo `Sources/` Mac/Registry modules
- `docs/operator/packets/PKT-MEM-135-…` as pattern for new tools
- Prospect aura invent/convert law
- Sales strategy pipeline / conversion law

---

## Material decisions (recommended defaults — operator may override)

| ID | Decision | Recommended | Impact if otherwise |
|---|---|---|---|
| D1 | Module home | New **Calls** feature surface under Mac tooling (or MacModule extension), not Notion-only | Wrong module → messy ownership |
| D2 | Packet shape | **One suite packet**, sequential waves W1→W3 (not 7 micro-packets) | More packets → more runner overhead |
| D3 | FDA | Document FDA requirement; fail with actionable error if DB unreadable | Silent empty lists mislead agents |
| D4 | Number match | Normalize to digits; match last-10 US; multi-prospect → ambiguous error | Wrong person logged |
| D5 | Auto Phone Verified | **Never** set true from unanswered/VM; optional suggest after answered + duration ≥ threshold | False identity claims |
| D6 | Sends | `vm_followup` drafts only unless existing messages_send confirm path | Accidental customer SMS |

**Assumed GO on D1–D6 unless operator objects before QUEUE.**

---

## Decomposition / Waves (sequential)

### Wave 1 — Call truth (unblocks all)
**Tools:** `calls_recent`
**Deliverables:** Reader for CallHistory.storedata; filters limit/since/number/direction; ToolAnnotationCatalog; tests with fixture DB or mocked rows; FDA error path.

### Wave 2 — Log + block loop
**Tools:** `log_call_touch`, `prospect_execute_loop`
**Depends on:** Wave 1
**Deliverables:**
- `log_call_touch`: input call id or {number, at, outcome claim}; resolve PROSPECT; create OUTREACH; update Last Touched / Next Action; dryRun
- `prospect_execute_loop`: mode boot|tick|close; boot = queue + recent calls; tick = unlogged dials since; close = digest + scoreboard

### Wave 3 — Context, prep, recovery, judgment
**Tools:** `handle_timeline`, `dial_prep`, `vm_followup`, `next_best_action`
**Depends on:** Wave 1–2
**Deliverables:**
- Timeline merge calls + messages_chat/recent
- dial_prep: registry prospect brief + open tel
- vm_followup: draft only
- next_best_action: ranked options with evidence fields

**Merge points:** shared phone normalize + CallHistory reader + prospect match helper (extract once in W1, reuse W2–W3).

---

## Definition of Done (checklist)

### Wave 1
- [x] `calls_recent` implemented and registered
- [x] Returns newest-first rows with stable field names
- [x] Filters: limit, since, number (normalized), direction
- [x] Unreadable DB → structured error with FDA hint
- [x] Tests + floor bump

### Wave 1R
- [x] Compatible SQLite fixture exercises adapter/date decoding
- [x] Permission, missing, corrupt/schema, and query errors are distinguishable
- [x] Stable call ID is proven and documented, including fallback
- [x] Canonical contract, tip evidence, and smoke evidence agree (PR #109 retired; tip via #110 + W1R branch)
- [x] Test suite + floor + live read-only smoke are green (3359 passed, floor 3359; live MCP UUID ids)
- [x] Reviewer decision recorded — Approve 2026-07-19; merged PR #111 (`6d8bd96`)

### Wave 2
- [ ] `log_call_touch` dryRun + write paths
- [ ] OUTREACH linked to PROSPECT when relation exists
- [ ] Does not set Phone Verified on VM/unanswered
- [ ] `prospect_execute_loop` boot/tick/close
- [ ] Tick lists unlogged outbound calls matched to prospects
- [ ] Tests + floor bump

### Wave 3
- [ ] `handle_timeline` for a handle
- [ ] `dial_prep` returns brief + opens Phone (or returns tel URL if open fails)
- [ ] `vm_followup` draft body + optional Ready OUTREACH without send
- [ ] `next_best_action` returns ≥1 ranked option with reason
- [ ] Operator brief markdown in repo
- [ ] Tests + floor bump
- [ ] REVIEW artifact ready for merge GO

---

## Required Capabilities

- `repo:the-bridge` — Swift MCP tool modules, tests, annotations, version/floor
- Local filesystem read: CallHistoryDB (operator machine)
- Bridge registry: `prospect` read/write; Notion OUTREACH create via existing paths
- messages_* read for timeline (existing)

## Prohibited Actions

- No merge to main without REVIEW GO
- No production deploy from this packet
- No messages_send / mail_send without operator confirm:'SEND'
- No bulk invent CONTACTS from call history
- No deletion of CallHistory or prospect rows
- No secret values in packet or logs

---

## Replay and Recovery

1. **Detect prior work:** tools exist in catalog + tests green + Version/floor comments dated PKT-CALL-001
2. **Stable keys:** tool names exact as listed; CallHistory reader module path documented
3. **Safe resume:** land waves in order; if W2 mid-flight, do not start W3 tools depending on missing APIs
4. **Unsafe:** partial catalog registration without tests → REVIEW before more tools

---

## Review Contract

| Item | Value |
|---|---|
| Who | Isaiah / Bridge owner |
| Artifact | PR stack + smoke notes + this packet Output section |
| Approve | Merge + optional release notes |
| Request changes | List gaps; keep branch |
| Park | Leave Draft/REVIEW with reason |

---

## Brief Contract (operator-facing after ship)

1. How to run Prospect Execute with the suite
2. What CallHistory can/can’t prove (identity)
3. FDA one-liner if empty results
4. Continuity note: Mac vs iPhone call chooser is OS UX, not tool failure

---

## Dependencies

| Depends on | State |
|---|---|
| CallHistoryDB present on operator Mac | Available (verified 2026-07-16) |
| PROSPECTS + OUTREACH live | Available |
| Messages tools | Available |
| tel: → Phone.app | Operator preference (fixed once; re-check if Chrome steals handler) |

**Blocked by:** none hard. Soft: FDA if tool returns empty erroneously.

---

## Tool contracts (authoritative for implementers)

### 1. `calls_recent`
```
in:  { limit?: number, since?: ISO8601, number?: string, direction?: "inbound"|"outbound"|"all" }
out: { success, source: "CallHistoryDB", identityResolved: false, count, calls: [{ id, startedAt, durationSeconds, number, normalizedNumber, direction, answered, callType, serviceProvider }], filters }
errors: database_missing | full_disk_access_required | unsupported_call_history_schema | call_history_query_failed
id: ZUNIQUE_ID preferred; fallback String(Z_PK)
tier: open | notify
```

### 2. `log_call_touch`
```
in:  { callId?: string, number?: string, at?: ISO8601, outcome: "Connected"|"Voicemail"|"No answer"|"Wrong number"|"Booked", prospectId?: string, dryRun?: bool, nextAction?: string }
out: { outreachId?, prospectId?, updated: string[], suggestions?: string[] }
tier: notify (write)
```

### 3. `prospect_execute_loop`
```
in:  { mode: "boot"|"tick"|"close", since?: ISO8601, brand?: string }
out: boot → { queue, recentCalls, openProspects }; tick → { unloggedCalls, suggestions }; close → { scoreboard, digest }
tier: open/notify
```

### 4. `handle_timeline`
```
in:  { number: string, limit?: number }
out: { events: [{ at, channel: "call"|"message", summary, ref }] }
tier: open
```

### 5. `dial_prep`
```
in:  { prospectId: string, openPhone?: bool }
out: { brief, talkTrack, telUrl, opened?: bool }
tier: notify if opens Phone
```

### 6. `vm_followup`
```
in:  { prospectId: string, channel?: "Text"|"Email", createOutreachDraft?: bool }
out: { draftBody, subject?, outreachId? }
tier: notify if writes draft row; never send
```

### 7. `next_best_action`
```
in:  { prospectId?: string, queue?: bool }
out: { actions: [{ rank, action, reason, evidence[] }] }
tier: open
```

---

## Packet Runner Output

### Current Canonical Result

`calls_recent` is on `origin/main` via PR **#110** (merged 2026-07-18; tip
`4fb9b03`). Draft PR **#109** is CLOSED and is not live evidence.

Wave 1R merged to `main` via PR **#111** (2026-07-19, merge `6d8bd96`):

- Compatible SQLite fixture exercises real `readDatabase` + Apple reference-date
  decoding and durable `id` (uniqueID preferred; `Z_PK` string fallback).
- Distinguishable errors: `database_missing`, `full_disk_access_required`,
  `unsupported_call_history_schema`, `call_history_query_failed`.
- Operator guide `docs/operator/calls-recent.md` documents `id` + error taxonomy.
- Live MCP smoke on install SHA `3f60f85`: UUID `id` values, `identityResolved: false`.
- Hermetic suite: 3359 passed; floor 3359.

**W1R complete ≠ W2 authorized.** Schema mutation / `log_call_touch` remain
blocked pending separate GO + registry reconcile. Tag/release still OUT.

### Artifact Manifest

- **Canonical mission surface:** [PACKETS · PKT-CALL-001](https://app.notion.com/p/PKT-CALL-001-Prospecting-Call-Tools-Suite-7-39fcbb58889e81cb9c9cca1dfee73cc6)
- DOCS dual `pkt-call-001` **deleted** 2026-07-16 (standing order: Packet Mission Surface)
- Repo mirror only (not a second SSOT)

- This file: `docs/operator/packets/PKT-CALL-001-prospecting-call-tools-suite.md`
- Notion packet page: https://app.notion.com/p/PKT-CALL-001-Prospecting-Call-Tools-Suite-7-39fcbb58889e81cb9c9cca1dfee73cc6

### Exceptional History

- 2026-07-16: Scoped via orchestrator protocol from seven-tool consolidation; CallHistory recon confirmed readable; Jeff VM call present in DB.
- 2026-07-17: Stabilization scope locked to Wave 1 only. Implemented and tested
  `calls_recent`; retained Waves 2–3 as future review work rather than silently
  expanding the branch.

---

## Fresh-Agent Test

A fresh executor with this packet + Bridge repo can implement Wave 1 without asking material questions (path, schema columns, and tool names are specified). Waves 2–3 reuse Wave 1 helpers. Operator review required before merge (REVIEW-FIRST).

## Autonomy Gate

- Material decisions D1–D6 recommended and assumed
- Execution Class set
- Verification named
- No customer auto-send
- PROJECT relation: The Bridge (set on Notion row)
- Ready for QUEUE after operator confirms D1–D6 (or silence = accept defaults)
