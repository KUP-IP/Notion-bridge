# Command reconciliation A1

GitHub issue #140, packet A1 adds product-default reconciliation on top of A0
custody. Schema version stays **2**. There is no automatic natural-language
body merge, Search UI, developer publication, or install.

## Authority

| Reference | Meaning |
| --- | --- |
| **Incoming** | Current application catalog (`CommandStore.defaultProductCatalog`, or a test-injected catalog). |
| **Local** | Operator override in `localOverrides`. Absent when the built-in is unmodified. |
| **Base** | Last-adopted product default, snapshotted when an override is first created. Stored as metadata in `layers.json` (`adoptedBases`, `decodeIfPresent`) and body bytes in `adopted-bases/<id>.md`. Never inlined into `layers.json`. |

Unmodified built-ins have no local override. The effective body is always the
incoming catalog entry, so application updates advance those defaults at read
time without writing custody. A0 already behaved this way; A1 makes incoming
inspectable as a first-class Settings model.

## Classification

Classification compares **incoming structured metadata** to the last-adopted
base (A0-era overrides with no snapshot fall back to catalog schema 1 /
behavior 1 / no required capabilities):

1. Incoming `schemaVersion` or `requiredCapabilities` differ → **Compatibility-required**. Execution gate closes. Evidence is the concrete schema/capability delta.
2. Else incoming `behaviorVersion` differs → **Behavioral**. Gate stays open.
3. Else an override exists → **Editorial** (name, icon, color, or wording). Gate stays open.
4. Else → **Current**. No update available.

Wording-only catalog edits never disable a command.

## Actions

All three are explicit. None merge body hunks.

| Action | Effect | Reverse |
| --- | --- | --- |
| `restoreBase` | Local := adopted base. Drops the override when that equals incoming. Fails closed if no adopted base is on file. | Re-apply the previous local via `update`, or `copySelectedChange`. |
| `adoptIncoming` | Drop the override. Incoming becomes effective. | Re-apply the previous local via `update`. |
| `copySelectedChange(source, field)` | Copy one whole field (`name` / `icon` / `color` / `body`) from base or incoming. | Copy the same field from the other source. |

Prior A0 revisions remain in `state.json` history; none of these actions
rewrite legacy `index.json` / `<slug>.md`.

## Execution gating

`CommandBridgeController.fireSlug` / `fireSlot` consult
`CommandStore.executionGate(slug:)`. Compatibility-required commands commit
`.unavailable` and do not insert. Editorial and behavioral updates stay
fireable. Custom commands are not reconciled and stay open.

## Settings model

`CommandReconciliation` is the Settings-facing contract: `base`, `local`,
`incoming`, `classification`, `updateAvailable`, `executionGate`. This packet
does not add Search UI.

## Compatibility with A0

Existing schema-2 revisions without `adoptedBases` decode as an empty map and
remain valid. Restore/copy-from-base are unavailable until an A1 override
creation snapshots a base; adopt-incoming and copy-from-incoming still work.
Operator override bodies are never rewritten by catalog replacement.
