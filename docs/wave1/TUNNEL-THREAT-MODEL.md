# Tunnel Threat Model (D9b/D9c) — Gates Hub Expansion

Requirement (Bridge-Evolution-Contract v1.1 + Red Team F3): this document must pass Ship Gate **before the hub takes on any new role.** Scope: the Cloudflare tunnel path (`tunnelURL` → 127.0.0.1:9700 `/mcp`).

## Assets behind the tunnel (why this matters)

Keychain credentials + payment execution · iMessage/Mail identity (send-as-operator) · full user-dir filesystem + shell · UI automation (synthetic input = everything else transitively) · the constitution stores themselves (the governed hands could rewrite the brain — D9c exists to prevent exactly this).

## Current controls (verified in code, 2026-07-05)

- HTTP binds **127.0.0.1 only**; no LAN bind (`ServerManager`).
- Remote classification: Cloudflare tunnel header (`SSEServer.isRemoteTunnelRequest`, PKT-810); loopback-without-header is local by contract.
- **Fail-closed bearer:** tunnel configured + no bearer token ⇒ all `POST /mcp` 401 (`MCPHTTPValidation`, Keychain `mcp_bearer_token`). OAuth gate for remote; DNS-rebinding host/origin allowlist (localhost + parsed tunnel host).
- SecurityGate tiers + nuclear-pattern handoffs apply to all calls regardless of origin; append-only audit log.
- Legacy SSE endpoints refuse tunnel-origin requests (verified in `SSETransport` guards).

## Threats → mitigations

| # | Threat | Vector | Mitigation (state) |
|---|---|---|---|
| T1 | Bearer/OAuth token theft | leaked client config, MCP client compromise | **W1:** D9c blocklist caps blast radius (no shell/credentials/orders/synthetic input remotely — see W1-DESIGN §5). **W4:** per-client revocable credentials (D9b), per-client tier ceilings. Today: single shared bearer = single blast radius — accepted only until W4. |
| T2 | Constitution rewrite via tunnel | `standing_orders_save` / `commands_update` remotely | **W1: closed** (D9c blocklist). |
| T3 | Exfiltration via agent + injection | hostile content in a remote-governed session steers agent to `credential_read`/`mail_send` | Partially: `credential_read` remote-blocked (W1); send tools remain remote-callable at `.request` tier (operator approves on-Mac). Residual risk accepted for W1; revisit with W4 ceilings + D3d injection tests. |
| T4 | Cloudflare Access / tunnel misconfig | tunnel exposed without Access policy | Operational: Access policy on the hostname per `docs/operator/cloudflare-access-notion-bridge.md`; verify at Ship Gate. Header spoofing is not a bypass (loopback bind means all remote traffic transits cloudflared; a caller who can hit 127.0.0.1 directly is already local). |
| T5 | DNS rebinding / origin confusion | browser-based attacker | Existing host/origin allowlist (localhost + tunnel host only). |
| T6 | Replay/long-lived sessions | stolen `Mcp-Session-Id` | Bearer still required per request; W1 session rows give audit visibility; W4 adds expiry policy. |
| T7 | Availability (DoS on tunnel) | flood | Out of W1 scope; Cloudflare-side rate limiting available; local process unaffected for stdio callers. |

## Ship Gate checklist (W1)

1. Live remote test: every D9c-blocklisted tool rejected from a real tunnel-origin call; allowed tool passes; local caller unaffected.
2. Bearer fail-closed re-verified (unset token ⇒ 401).
3. Cloudflare Access policy present on the tunnel hostname.
4. Audit log shows origin + governed flags on remote calls.

## Standing rule

Any expansion of the hub role (new clients, background runs calling remotely, W4 ceilings) re-opens this document; it is versioned with the release that changes the surface.
