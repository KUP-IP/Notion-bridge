# Command directional catalog B0

GitHub issue #140, packet B0 rewrites the ten built-in Command Bridge defaults
as concise directional goal conditions. Skills and standing orders own
repeatable procedures. A0 identities and A1 reconciliation stay in force.
There is no Search UI, developer publication, merge, tag, or install in this
packet.

## Authority

`CommandProductCatalog` is the repository SSOT for built-in bodies. 
`CommandStore.defaultProductCatalog` is a façade over that catalog.

| Layer | Owner | B0 change |
| --- | --- | --- |
| Immutable ID / slug / slot / icon / color | A0 | Unchanged |
| Body contract | B0 | Mode, Use when, Aim, Boundary, Exit. ≤120 words. No tool IDs, paths, retries, or patch history |
| `schemaVersion` | A1 | Stays **1** |
| `behaviorVersion` | B0 | **2** — directional contract vs the A0 protocol-style bodies |
| Local overrides | A0/A1 | Never overwritten by the catalog rewrite |

Unmodified built-ins adopt the incoming directional body at read time (A1
Current). Overrides stay byte-for-byte. An A0-era override against behavior 1
classifies as Behavioral, not Compatibility-required; the fire path stays open.

## Live palette

| Slot | Slug | Name | Mode |
| --- | --- | --- | --- |
| 1 | `initiate` | Initiate | arrival |
| 2 | `propose` | Propose | shaping |
| 3 | `scope-cut` | Scope Cut | trim |
| 4 | `validate` | Validate | hardening |
| 5 | `execute` | Execute | delivery |
| 6 | `review` | Review | checkpoint |
| 7 | `refocus` | Refocus | realignment |
| 8 | `open-loops` | Open Loops | inventory |
| 9 | `close-agent` | Close Agent | closeout |
| 0 | `hand-off` | Hand Off | transfer |

Decide and Synthesize are out of scope. Hotkeys are unchanged.

## Validation

`CommandProductCatalog.validateAll()` is the static gate: word count, required
section labels, prohibited tool/path/retry/patch tokens, and domain-exclusive
terms that would make a default coding-only or knowledge-work-only.

## Related

- [`commands-custody-a0.md`](commands-custody-a0.md)
- [`commands-reconciliation-a1.md`](commands-reconciliation-a1.md)
- [`operator/commands-engineering-palette.md`](operator/commands-engineering-palette.md)
