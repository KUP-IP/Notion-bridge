# `codex/cloud-oauth-readiness` — merged, then defaulted back off

Status: **RESOLVED — merged via PR #92 (2026-07-09), default reverted to `false` via PR #95 (2026-07-09) per explicit operator direction; strict-scope code preserved as opt-in**
Originally decided: 2026-07-07 (deferred to Wave 4). Superseded: 2026-07-09, same day it was picked back up.

## What this branch does

Flips `ConnectorAuthContext.strictScopes` default from `false` (full tool parity for any authenticated connector, gated only by per-tool SecurityGate) to `true`, restricting remote/OAuth connector tool calls to allowlisted buckets (`directory`, `runnerExec`, `contactsRead`, `voiceResolve`, `bootstrap`, `bridgeSessionTools`). Everything outside those buckets is denied outright for remote callers, regardless of SecurityGate tier.

## What actually happened

1. **Merged 2026-07-09 via PR #92** ("Cloud OAuth readiness: strict connector-scope allowlist (rebased + fixed)") — rebased onto main + w1-broker. Fixed the allowlist gap that caused the original 2026-07-07 incident (`bridge_status`/`session_info` were missing from the bootstrap bucket). An adversarial audit during review caught two more real bugs before merge: phantom tool names in `runnerExecTools` (`bg_process_*`/`jobs_pause_all`/`devserver_*` matched nothing in the live registry) and a missing `session_clear` entry. Verified against the live 202-tool registry: 35 reachable, 167 denied under `strictScopes: true`. 3118 tests passing.
2. **Reverted to `false` same day via PR #95** ("fix(connectors): restore full Claude Connectors tool parity (v3.9.9)") — per explicit operator direction. The v3.9.8-era 36-tool allowlist is preserved as an opt-in (set `strictScopes: true` explicitly to enable it); it is no longer the default. w1-broker's origin-based control-plane block + governed-session gate remain fully active regardless of this flag — that's a separate, unaffected mechanism (session governance, not OAuth scope).

## Why the original deferral turned out to be premature

The original call (below) was to leave this unmerged until Wave 4. In practice the underlying fixes were needed sooner — the same 2026-07-09 session that resolved a live connector-parity incident also fixed and merged this branch's allowlist gaps. The operator then chose tool-parity-by-default over scope-restriction-by-default for the current wave — a product call, not a technical blocker. The code is in `main` either way; only the *default* changed back.

## Revisit trigger

Re-open the *default* question (opt-in → default-on) when Wave 4 (per-client credentials + tier ceilings) is actually scheduled, or sooner if there's a concrete driver for restricting connector scope by default.

---

<details>
<summary>Original deferral record (2026-07-07) — superseded by the above</summary>

Decided: 2026-07-07, in the course of a git-branch audit + cross-platform connector verification session.

### Why it was deferred, not merged (at the time)

1. **It was the root cause of a live incident.** The installed `/Applications/The Bridge.app` was very likely built from this branch's uncommitted working tree (file-mtime correlation: last edit 2026-07-06 18:59:47, app bundle rebuilt 2026-07-06 19:09:09 — ~9.5 minutes later), with no commit, review, or record anywhere in git. Both ChatGPT and Claude web connectors broke as a result (`bridge_status`/`session_info` denied with `insufficient_scope`; Claude.ai showed a dead-end "Connect" loop, since WorkOS/AuthKit cannot mint the Bridge-custom scopes this branch's allowlist requires). Fixed same-day by rebuilding from clean, committed `main`.
2. **It was superseded for the current wave.** feat/w1-broker (PR #88) — a formally-governed security architecture (its own contract, threat model, degraded-mode spec, Red Team review markers) — already closed the exact allowlist gap that caused the incident: its `ConnectorScopeGate` addition includes a `bridgeSessionTools` bucket (`bridge_initialize`, `bridge_status`, `tools_list`, `session_info`) that this branch's `bootstrap` bucket (`bridge_initialize` only) was missing. w1-broker solves "what can a remote caller do" via session governance + a hard module blocklist (`shell`/`applescript`/`computer`/`credential`) layered on top of full-parity default — a different, more conservative-by-exception model than this branch's allowlist-by-default model.
3. **The project's own roadmap agreed it was early.** w1-broker's `docs/wave1/TUNNEL-THREAT-MODEL.md` explicitly assigns "per-client revocable credentials, per-client tier ceilings" (i.e., what this branch's `strictScopes` flip does) to **Wave 4**, not Wave 1.

### Known gap noted at the time (fixed in PR #92 before merge)

Its own allowlist was missing `bridge_status`/`session_info`/`tools_list` — the same gap that broke things originally. Resolved as part of PR #92.

</details>
