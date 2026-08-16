# Command integration E0

GitHub issue #140, packet E0. A0–D0 are on one integration SHA. This packet
does not install, tag, or close the issue.

## Integrated streams

| Packet | Contract kept |
| --- | --- |
| A0 / A1 | Durable custody and explicit reconciliation. Local overrides stay until adopted. |
| B0 | Directional catalog defaults. Local overrides are never written from the catalog. |
| B1 | GitHub Issues is the feedback ledger. No `AGENT_FEEDBACK.md` writer. |
| C0 | Search favorite slots are reversible and do not mutate command bodies. |
| C1 | Ordinary Return never creates. Edit deep-links by immutable command ID. |
| D0 | Developer publication is off by default. No silent Git. |

Issue #129 cursor-insert coverage stays hooked (`CommandCursorInsertTests`).
Promoted install remains G0.

## Installed-store meaning

“Installed-store” here is the local command custody store (revisioned
overrides + adopted bases), not `/Applications/The Bridge.app`. Replacing
the application bundle must not rewrite operator overrides.

## Out of scope

Promoted install, tags, Sparkle, and closing issue #140.
