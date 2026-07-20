# Calendar–Registry Live Smoke Receipt

Status: **smoke-complete** (2026-07-20). One succeeded disposable pair; env off-ramp proved. R10–R15 remain deferred. Not an always-on sync enablement.

## Tip / install

| Field | Value |
|---|---|
| Tip SHA | `903c0ee7dddb0b234b501ef111806d123ba90a89` (`feat/calendar-registry-sprint`) |
| Floor | 3368 (CR97 offset-only date + CR98 minute-truncated Last Synced At) |
| Tool | `calendar_registry_pair` (module family `calendar`, tier `.request`) |
| Install | `ALLOW_NON_MAIN_INSTALL=1 make install-copy` from clean tip |
| Session env | `BRIDGE_INTERNAL_CALENDAR_REGISTRY_SYNC=1` |
| | `BRIDGE_INTERNAL_CALENDAR_REGISTRY_ALLOWED_CALENDARS=A33CAC6E-9D15-44F4-BC35-54F204F4DA39` |
| | `BRIDGE_INTERNAL_CALENDAR_REGISTRY_AUTO_APPROVE=1` (private-smoke hatch only) |

## Fixtures

| Field | Value |
|---|---|
| Notion EVENT | `3a3cbb58889e8166ba5fc30451086e14` (“Bridge Registry Smoke Disposable 2”) |
| Scheduling Authority | Registry |
| Sync State (pre) | Pending Create |
| Primary BLOCK | `ed579ce7-369c-4c0a-bbe9-87624301a043` |
| Window | 2026-08-02 15:00–15:30 America/Chicago |
| Calendar | FOCUS `A33CAC6E-9D15-44F4-BC35-54F204F4DA39` (CalDAV, writable, non-subscribed) |
| Idempotency key | `smoke-2026-07-20-pair-3` |
| Operation fingerprint | `f00d1bed1f94e4a5c4b25e3b341f9c87584fd3b8b1ecde7c6763f9fbfff30439` |

Pre-seed required by engine: Sync Key = idempotency key, Operation Fingerprint = manifest fingerprint, Sync Revision = 0 (matches CR13 hermetic path).

## Results

| Check | Result |
|---|---|
| First `calendar_registry_pair` | `succeeded: true`, `stageAfter: complete` |
| EventKit uniqueness | exactly **1** item (`305A17D8-38F0-4A51-B0CF-B44DB346A65A:C8F7C880-B051-4ECB-A468-AD52E4E9775E`) |
| Registry uniqueness | `registryIdentityCount: 1` |
| Idempotent retry | `succeeded: true`, same `localEventId`, no second create |
| Notion sync fields | Sync State → Synced; calendar identity written; semantic title/date/Primary BLOCK unchanged |
| Coordinator | `singleMachineCoordinator: true`, namespace `local-27acd5eda141a170fa86ba6b` |

## Off-ramp (proved)

1. Quit The Bridge; relaunch **without** any `BRIDGE_INTERNAL_CALENDAR_REGISTRY_*` keys (not present in `solutions.kup.bridge-env.plist`).
2. Process env: no smoke keys.
3. `tools/list`: `calendar_registry_pair` **absent** (209 tools listed).
4. Forced dispatch fail-closed: disabled message requiring sync env + allowlist.

## EventKit / EVENT leftover policy

- **Keep Notion EVENT** `3a3cbb58889e8166ba5fc30451086e14` (and conflicted sibling `3a3cbb58889e8137a5fac7d1885d06cf`) with sync identity for evidence (do not strip Sync Key / fingerprint / calendar ids unless intentionally retiring the receipt).
- **EventKit cleanup done (2026-07-20 closeout):** both disposable items deleted via `calendar_delete`; FOCUS calendar Aug 1–2 query returned 0 events.
  - Deleted success pair: `305A17D8-38F0-4A51-B0CF-B44DB346A65A:C8F7C880-B051-4ECB-A468-AD52E4E9775E`
  - Conflicted key `smoke-2026-07-20-pair-2` must not be retried (ledger remains conflict).

## Live learnings folded into tip

1. Notion EVENT DATE often returns offset ISO with `time_zone=null` → decode must allow empty IANA zone when absolute instants match (CR97).
2. Notion date properties truncate sub-minute precision → ledger must anchor `lastVerifiedAt` to Notion read-back (CR98).

## Still deferred

R10–R15, always-on sync, Sparkle tag / `v4.0.0`, creating BLOCKs as product behavior, public activation without env gate.
