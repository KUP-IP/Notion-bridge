# Command GitHub-first feedback B1

GitHub issue #140, packet B1. GitHub Issues is the sole actionable Bridge
development-feedback ledger. `AGENT_FEEDBACK.md` is retired as a write
target. AI LOG remains telemetry. Calibrate is a bounded whole-product
report, not a second backlog.

## Authority

| Surface | Role after B1 |
| --- | --- |
| GitHub Issues | Actionable defects, product asks, search-before-create |
| AI LOG | Session telemetry only |
| Calibrate | Bounded identity / GitHub / workspace / install / sprint report |
| Close / Open Loops / close-agent | Route leftovers to Issues; do not invent a second backlog |
| `AGENT_FEEDBACK.md` | Removed as an active writer; historical gitignored local copy is not SSOT |

Built-in command bodies stay directional (B0). They must not name GitHub or
`AGENT_FEEDBACK` — domain-exclusive / prohibited catalogs still apply.

## Migration ledger

| Item | Disposition |
| --- | --- |
| 2026-07-17 audit clusters already implemented or verified | Dismiss — see `docs/operator/agent-feedback-audit-2026-07-17.md` |
| Client / host MCP reconnect after install | Dismiss — client-owned; documented in AGENTS.md |
| Draft PR merge freeze | Dismiss — process note; not a product defect |
| 2026-08-14 `registry_find` compact vs hyphenated UUID | Issue [#160](https://github.com/KUP-IP/the-bridge/issues/160) — not fixed in B1 |
| Historical CHANGELOG / test-floor provenance mentions | Keep — not active writers |
| Root `AGENT_FEEDBACK.md` | gitignored local file; removed after this ledger |

## Calibrate

See `docs/operator/calibrate.md`. The checkable shape is
`CommandCalibrateReport` (≤5 sprint outcomes). Source SHA ≠ installed SHA
is named, never collapsed.

## Out of scope

No merge/tag/install in the original packet contract. Operator GO for honest
Done may land this branch after Source Tested evidence. No Search UI. No
developer publication.
