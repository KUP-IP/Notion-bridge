# `codex/cloud-oauth-readiness` — deferred, not merged

Status: **DECIDED — deferred to a future wave, branch preserved (not merged, not deleted)**
Decided: 2026-07-07, in the course of a git-branch audit + cross-platform connector verification session.

## What this branch does

Flips `ConnectorAuthContext.strictScopes` default from `false` (today's committed-main behavior: full tool parity for any authenticated connector, gated only by per-tool SecurityGate) to `true`, and restricts remote/OAuth connector tool calls to five allowlisted buckets (`directory`, `runnerExec`, `contactsRead`, `voiceResolve`, `bootstrap`). Everything outside those buckets is denied outright for remote callers, regardless of SecurityGate tier.

## Why it's deferred, not merged

1. **It was the root cause of a live incident.** The installed `/Applications/The Bridge.app` was very likely built from this branch's uncommitted working tree (file-mtime correlation: last edit 2026-07-06 18:59:47, app bundle rebuilt 2026-07-06 19:09:09 — ~9.5 minutes later), with no commit, review, or record anywhere in git. Both ChatGPT and Claude web connectors broke as a result (`bridge_status`/`session_info` denied with `insufficient_scope`; Claude.ai showed a dead-end "Connect" loop, since WorkOS/AuthKit cannot mint the Bridge-custom scopes this branch's allowlist requires). Fixed same-day by rebuilding from clean, committed `main`.
2. **It's superseded for the current wave.** [feat/w1-broker](https://github.com/KUP-IP/the-bridge/pull/88) — a formally-governed security architecture (its own contract, threat model, degraded-mode spec, Red Team review markers) — already closes the exact allowlist gap that caused the incident: its `ConnectorScopeGate` addition includes a `bridgeSessionTools` bucket (`bridge_initialize`, `bridge_status`, `tools_list`, `session_info`) that this branch's `bootstrap` bucket (`bridge_initialize` only) is missing. w1-broker solves "what can a remote caller do" via session governance + a hard module blocklist (`shell`/`applescript`/`computer`/`credential`) layered on top of today's full-parity default — a different, more conservative-by-exception model than this branch's allowlist-by-default model.
3. **The project's own roadmap agrees it's early.** w1-broker's `docs/wave1/TUNNEL-THREAT-MODEL.md` explicitly assigns "per-client revocable credentials, per-client tier ceilings" (i.e., what this branch's `strictScopes` flip does) to **Wave 4**, not Wave 1. Shipping a global allowlist flip now would front-run the project's own staged plan, on top of being an unreviewed, incomplete implementation of it.

## What's preserved

The branch is committed and pushed to `origin/codex/cloud-oauth-readiness` (was previously uncommitted-only, which is itself how it ended up silently deployed). Not merged, not deleted — it's a legitimate starting point for Wave 4 per-client scope-ceiling work.

**Known gap if ever revisited:** its own allowlist is missing `bridge_status`/`session_info`/`tools_list` — the same gap that broke things today. Whatever Wave 4 work picks this up needs to fix that before it's safe to enable, independent of anything else.

**Small pieces salvageable independently of the broader allowlist decision**, if anyone wants a standalone follow-up PR:
- `ConnectorBearerValidator.hasConfiguredKeys` — a read-only diagnostic property (does this validator have verification keys configured), useful for cloud-readiness reporting, no behavior change.
- The `CloudStatusModule`/`ServerManager` `.connecting`-state fix — today, `.connecting` is treated as "mac tools available"; this branch correctly narrows that to only `.online`/`.degraded`. Looks like a legitimate, independent correctness fix, unrelated to the scope/allowlist question.

## Revisit trigger

Re-open this question when Wave 4 (per-client credentials + tier ceilings) is actually scheduled — not before.
