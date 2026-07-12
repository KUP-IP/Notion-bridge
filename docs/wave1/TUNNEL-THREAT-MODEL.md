# Tunnel Threat Model (D9b/D9c) — Gates Hub Expansion

Requirement (Bridge-Evolution-Contract v1.1 + Red Team F3): this document must pass Ship Gate **before the hub takes on any new role.** Scope: the Cloudflare tunnel path (`tunnelURL` → 127.0.0.1:9700 `/mcp`).

## Assets behind the tunnel (why this matters)

Keychain credentials + payment execution · iMessage/Mail identity (send-as-operator) · full user-dir filesystem + shell · UI automation (synthetic input = everything else transitively) · the constitution stores themselves (the governed hands could rewrite the brain — D9c exists to prevent exactly this).

## Current controls (verified in code, 2026-07-10)

- HTTP binds **127.0.0.1 only**; no LAN bind (`ServerManager`).
- Remote classification: Cloudflare tunnel header (`SSEServer.isRemoteTunnelRequest`, PKT-810); loopback-without-header is local by contract.
- **Fail-closed bearer:** tunnel configured + no bearer token ⇒ all `POST /mcp` 401 (`MCPHTTPValidation`, Keychain `mcp_bearer_token`). OAuth gate for remote; DNS-rebinding host/origin allowlist (localhost + parsed tunnel host).
- **Fail-closed broker gate for remote writes:** tunnel-origin notify/request-tier tools require a governed session row from `bridge_initialize`; otherwise `ToolRouter` rejects with `ungoverned_remote_session` before SecurityGate/module execution and writes an audit entry.
- **Full connector tool parity by default:** authenticated, governed remote callers
  can reach the registered tool surface, including shell, credentials, synthetic
  input, and constitution writes. Each call still passes through its normal
  SecurityGate tier. Operators can explicitly enable
  `com.notionbridge.broker.remoteControlPlaneBlock` to restore the origin-based
  hard ceiling without changing governed-session enforcement.
- **Broker-first import surface:** `tools/list` advertises `bridge_initialize`, `bridge_status`, `tools_list`, and `session_info` first so remote clients can import the broker before any catalog cap or refresh friction.
- SecurityGate tiers + nuclear-pattern handoffs apply to all calls regardless of origin; append-only audit log.
- Legacy SSE endpoints refuse tunnel-origin requests (verified in `SSETransport` guards).

## Threats → mitigations

| # | Threat | Vector | Mitigation (state) |
|---|---|---|---|
| T1 | Bearer/OAuth token theft | leaked client config, MCP client compromise | Authentication + governed-session requirement + per-tool SecurityGate. Full tool parity intentionally increases the authenticated connector's blast radius; the origin block remains an operator opt-in and W4 per-client revocation/ceilings remain planned. |
| T2 | Constitution rewrite via tunnel | `standing_orders_save` / `commands_update` remotely | Governed session + request-tier SecurityGate approval. Optional origin block closes this path when enabled. |
| T3 | Exfiltration via agent + injection | hostile content in a remote-governed session steers agent to `credential_read`/`mail_send` | Credential and send/write tools retain request-tier approval; ungoverned remote writes fail closed. Residual authenticated-agent risk is explicitly accepted for full connector parity; revisit with W4 ceilings + D3d injection tests. |
| T4 | Cloudflare Access / tunnel misconfig | tunnel exposed without Access policy | Operational: Access policy on the hostname per `docs/operator/cloudflare-access-notion-bridge.md`; verify at Ship Gate. Header spoofing is not a bypass (loopback bind means all remote traffic transits cloudflared; a caller who can hit 127.0.0.1 directly is already local). |
| T5 | DNS rebinding / origin confusion | browser-based attacker | Existing host/origin allowlist (localhost + tunnel host only). |
| T6 | Replay/long-lived sessions | stolen `Mcp-Session-Id` | Bearer still required per request; W1 session rows give audit visibility; W4 adds expiry policy. |
| T7 | Availability (DoS on tunnel) | flood | Out of W1 scope; Cloudflare-side rate limiting available; local process unaffected for stdio callers. |

## Ship Gate checklist (W1)

1. Live remote test: `bridge_initialize` is callable from the remote client;
   governed `shell_exec` reaches normal SecurityGate dispatch and succeeds after
   approval; an ungoverned remote notify/request tool is rejected; an allowed
   open/read tool passes; local callers remain unaffected. When the optional
   origin block is enabled, its predicate fixture must still reject the expected
   control-plane surface.
2. Bearer fail-closed re-verified (unset token ⇒ 401).
3. Cloudflare Access policy present on the tunnel hostname.
4. Audit log shows origin + governed flags on remote calls.

## Standing rule

Any expansion of the hub role (new clients, background runs calling remotely, W4 ceilings) re-opens this document; it is versioned with the release that changes the surface.
