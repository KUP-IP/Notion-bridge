# PKT-1123 — W2B Reconnect Observability and Recovery Evidence

Date: 2026-07-13

Branch: `codex/pkt-1123-reconnect-observability`

Base: `origin/main` at `1e3d633c9d6c02b209d078977729a953613d0ff2`

## Result

The local implementation is ready for REVIEW. It adds redacted connection
accept/reconnect/session diagnostics to `connections_list` and Connection
Settings, plus one request-tier `connections_reset` action that rotates the
current local broker-governance record through the canonical
`BridgeInitializeService`. The transport stays alive long enough to return the
receipt. Tunnel callers are rejected unconditionally, even when the broader
remote control-plane hardening preference is disabled.

This packet does not redefine W1 `audit_recent`, alter connector session keying,
choose a third-party client's reconnect URL, install an app, or perform a
release.

## Contract evidence

| Requirement | Evidence |
| --- | --- |
| Accept/reconnect log identifies client, session, and dialed transport | `ConnectionRuntimeObservability` records capped redacted events and emits `[Connection] accept/reconnect ... origin=... dialedTransport=... transportSessionId=... client=... ts=...`. |
| Auth/session diagnostics | `connections_list.runtime` and the Settings Connection runtime card show configured/per-session auth mode, accepted-at token-age basis, token expiry when the verified OAuth claim is available, truthful client-managed refresh status, and live broker governance. |
| Actor-coherent snapshot | `snapshot` copies sessions, auth mode, and recent events before its first `SessionRegistry` await, so actor reentrancy cannot mutate the collection traversal or mix snapshot generations. |
| No token leakage | The runtime model has no Authorization, bearer/JWT body, access-token, or refresh-token field. The projection test encodes the actual MCP `Value` and rejects those key names. |
| Governed local recovery | Two successive resets rotate broker session IDs through `SessionRegistry.open`'s `ON CONFLICT` upsert, remain governed, are marked idempotent, and retain the MCP transport. The prior row is not preemptively closed, so there is no avoidable ungoverned window. |
| Remote reset forbidden | Both the reset service and `ToolRouter` refuse remote origin. The router test disables `brokerRemoteControlPlaneBlock` and still receives `control_plane_remote_blocked`. |
| Operator surface | Connection Settings adds a redacted runtime card, refresh control, and `Reset local sessions`; the app routes the local UI request to the same reset service. |
| New tool bookkeeping | `connections_reset` has an explicit annotation; static feature count is 202 → 203; ConnectionsModule expectation is 5 → 6. |

## Raw focused evidence

The standalone test executable emitted:

```text
[Connection] accept origin=local dialedTransport=local transportSessionId=local-session client=Codex ts=2027-01-15T08:00:00Z
[Connection] accept origin=remote dialedTransport=tunnel transportSessionId=tunnel-session client=Claude ts=2027-01-15T08:00:00Z
✅ connection runtime projection distinguishes local/tunnel and excludes token material
[Connection] reset origin=local dialedTransport=local transportSessionId=local-reset-session client=Codex ...
[Connection] reset origin=local dialedTransport=local transportSessionId=local-reset-session client=Codex ...
✅ local reset upserts without a governance gap and remains repeatable
✅ connection reset service refuses remote context directly
✅ connections_reset is tunnel-blocked even when the broad hardening switch is off
✅ Connection Settings exposes redacted runtime and local reset controls
Results: 3163 passed, 0 failed, 3163 total
```

The timestamps above are deterministic fixture time for accept coverage; reset
timestamps are live test-run time. No token text is logged.

## Verification ledger

- `git diff --check` — PASS.
- `make check-counter-collisions` — PASS: no duplicate claims across 0 parsed claims.
- Lead hardening review — actor-owned snapshot inputs are copied before the first
  await; reset preserves the prior governed row until atomic replacement.
- Environment-unset debug build — PASS.
- Focused/full executable — PASS: 3,163 passed, 0 failed.
- Environment-unset strict-concurrency `make build` — PASS; post-review release
  binary built in 137.69s.
- `make test-floor` with `FLOOR=3163` — first attempt reported 3,162/1 but its
  truncated output did not retain the failing row; immediate retained-log rerun
  passed 3,163/0 and the floor gate. No floor was lowered and no failure was
  suppressed. The post-review hardening rerun also passed 3,163/0 at floor 3,163;
  that final run is the current acceptance result.
- FLOOR provenance — 3,156 → 3,163 for exactly seven net-new harness tests.

## Review boundary

No `/Applications` install was permitted for this REVIEW-FIRST packet, so the
Settings card has compile-time/source-contract coverage but no installed-app
screenshot. Live visual inspection belongs to the operator-approved integration
or install smoke pass. The branch has not been pushed or merged.
