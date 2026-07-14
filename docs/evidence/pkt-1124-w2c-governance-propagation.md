# PKT-1124 W2C governance propagation evidence

Date: 2026-07-14
Base: `eccbffd5183bd77f480e7efaf7de225f3dfc421d` (`origin/main`)

## Verdict

The packet's required authentic pre-fix reproduction did **not** fail on the
current base. A real Streamable-HTTP exchange using the production
`SSEServer.handleHTTPRequest` path completed MCP `initialize`, called the
canonical `BridgeInitializeService.run` implementation through
`bridge_initialize`, and then called a second tool with the same
`Mcp-Session-Id`. The second call was governed and carried no false advisory.

The first run on otherwise-unmodified production code passed at **3,164/0**.
Because the demanded RED state was not reproducible, this packet makes no
production change. It adds four regression tests and raises the measured floor
from 3,163 to 3,167.

## Root-cause classification

The live code rules out the packet's keying defects:

- `SSETransport.swift:750-758` binds the request's stable
  `Mcp-Session-Id` into `ToolDispatchContext` for every established-session
  request.
- `SSETransport.swift:1329-1338` passes that context into the shared router,
  with the session resource ID as the fallback.
- `ToolRouter.swift:242-250` rebinds the same context around dispatch.
- `BridgeInitializeService.swift:379-386` opens governance against that exact
  transport session ID.

`git blame` attributes all four keying surfaces to the original W1 broker
commit `27983304becaacdf4649d3a109e2bd5f7c689bef`. There is no live evidence for
(a) server-object keying or (b) reconnect replacement within an established
session. The observed report is therefore consistent only with (c): a new
transport session created by reconnect. A fresh session intentionally remains
ungoverned until it calls `bridge_initialize`; client-name carryover would make
governance spoofable.

## Regression proof

`TheBridgeTests/GovernancePropagationTests.swift` proves:

1. Same Streamable-HTTP session: initialize -> `bridge_initialize` -> second
   `tools/call` is governed and has no advisory.
2. Fresh reconnect with the same client identity receives a distinct session
   ID and remains ungoverned until initialization.
3. A forged session ID never reads as governed; a remote notify-tier probe
   fails closed with `ungoverned_remote_session`.
4. The stdio synthetic session has the same before/after initialization
   semantics.

The tests use isolated registry, persistence, receipt, and observability stores.
They exercise the real HTTP transport and canonical initialization service;
they do not mutate installed runtime state.

## Acceptance gates

- `git diff --check`: pass
- `make check-counter-collisions`: pass, no duplicate claims
- strict env-unset `make build`: pass
- `make test`: 3,167 passed, 0 failed
- `make test-floor`: 3,167 passed, 0 failed; floor 3,167

## Scope guardrails

- No production source changed.
- PR #96 origin reporting remains untouched.
- Remote control-plane policy remains untouched.
- `audit_recent` semantics remain untouched.
- No install, tag, release, publish, or `/Applications` mutation occurred.
- Installed-runtime reproduction is deferred by the closure run's explicit
  no-install gate. There is no before/after production capture because the
  authentic pre-change path was green and no production fix exists.
