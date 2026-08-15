# Bridge Command Engineering Palette

Operator reference for the 10-slot Command Bridge palette (keys **1–0**).
Product defaults live in the repository (`CommandProductCatalog`). Local
overrides and custom commands live in durable custody and are never overwritten
by an app update. This page must match the live catalog.

## Slot map

| Key | Slug | Display name | Mode |
|-----|------|--------------|------|
| **1** | `initiate` | Initiate | Arrival. Orient before work moves. |
| **2** | `propose` | Propose | Shaping. Do not build yet. |
| **3** | `scope-cut` | Scope Cut | Trim required work from adjacent work. |
| **4** | `validate` | Validate | Hardening. Is the plan ready to run? |
| **5** | `execute` | Execute | Delivery of an approved contract. |
| **6** | `review` | Review | Checkpoint before an irreversible step. |
| **7** | `refocus` | Refocus | Re-anchor a drifted session. |
| **8** | `open-loops` | Open Loops | Inventory unresolved threads. |
| **9** | `close-agent` | Close Agent | Preserve what should survive the session. |
| **0** | `hand-off` | Hand Off | Prepare the next agent without rediscovery. |

Each body is a five-part directional goal condition: **Mode**, **Use when**,
**Aim**, **Boundary**, **Exit**. ≤120 words. No tool IDs, paths, retries, or
historical patches. Repeatable procedures belong in skills and standing orders.

## Lifecycle

```
Initiate → Propose → Scope Cut → Validate → Execute → Review → Refocus → Open Loops → Close Agent → Hand Off
                              ↘ Execute (fast ship) ↗
```

The same palette is for coding and non-coding work. Nothing in a default body
assumes a repository, a database, or a particular host.

## Stacking (multi-key paste)

Command Bridge fires one body per key. Paste keys back-to-back in one prompt.

| Stack | Keys | When |
|-------|------|------|
| Full pipeline | 2 → 3 → 4 → 5 | Big or multi-domain work |
| Fast ship | 2 → 5 | Scope already tight; skip validate |
| Scope trim | 2 → 3 → 2 | Propose overscoped — cut then re-propose |
| Post-ship | 5 → 6 | Execute then review checkpoint |
| Continue | 6 → 7 → 2 | Review → refocus → new propose |
| Loop inventory | 8 | List unresolved threads |
| Session end | 8 → 9 | Inventory then closeout |
| Continue elsewhere | 9 → 0 | Closeout then handoff brief |
| End only | 9 | Session ends at closeout |

## Composition rules

- **Propose** does not start material work.
- **Execute** runs only after an approved contract.
- **Validate** is optional; the default path is **2 → 5**, not **2 → 4 → 5**.
- **Hand Off (0)** does not run closeout — that is **Close Agent (9)**.
- Local overrides stay local. Incoming defaults are inspectable through A1
  reconciliation; bodies are never auto-merged.

## Test harness note

`CommandsModuleTests` must use `BridgePaths.overrideHomeForTesting` before
`CommandStore.shared.resetForTesting()`. Without it, `make test` wipes the live
command store. Fixed 2026-06-29 after a production wipe from an un-sandboxed
test run.

## Related

- [`../../docs/commands-directional-b0.md`](../commands-directional-b0.md) — B0 contract
- [`../../docs/commands-custody-a0.md`](../commands-custody-a0.md) — custody
- [`../../docs/commands-reconciliation-a1.md`](../commands-reconciliation-a1.md) — reconciliation
- [`skill-command-routing-schema.md`](skill-command-routing-schema.md) — slug naming
- [`TheBridge/App/CommandBridge.swift`](../../TheBridge/App/CommandBridge.swift) — hot-key UI
- [`TheBridge/Modules/Commands/CommandProductCatalog.swift`](../../TheBridge/Modules/Commands/CommandProductCatalog.swift) — live defaults
