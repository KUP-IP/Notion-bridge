# Calendar–Registry vNext registry migration

Status: applied and verified on 2026-07-18; activation remains disabled.

## Purpose

Add five rename-safe canonical bindings to the `schedule` registry entity:

| Canonical key | Notion property | Type | Purpose |
|---|---|---|---|
| `providerExternalId` | `Provider External ID` | rich text | EventKit/provider external identity when available |
| `operationFingerprint` | `Operation Fingerprint` | rich text | Immutable SHA-256 canonical operation manifest |
| `createInvocationId` | `Calendar Create Invocation ID` | rich text | Durable one-time authorization for the sole automatic EventKit create invocation |
| `syncWriterToken` | `Sync Writer Token` | rich text | Post-write optimistic fencing evidence for synchronization-owned Notion PATCHes |
| `syncRevision` | `Sync Revision` | number | Monotonic synchronization-owned write revision |

These fields are independent of the local SQLite ledger. The Create Invocation ID is the durable no-recreate boundary: once present on Notion or SQLite, automatic EventKit creation is prohibited on later attempts.

## Apply

The live migration followed this Ship Gate sequence:

1. Read the live EVENTS schema and current `schedule` registry entity.
2. Confirm every `requiredExistingKeys` entry in `registry-entity-patch.json` is bound with its expected type.
3. For each additive property, inspect by exact name before creating anything.
4. If absent, add the property with the declared type. If present with another type, stop; do not coerce or replace it.
5. Add or update the local canonical mappings using the live introspected property IDs and role `generic`.
6. Re-read the live schema and registry entity.
7. Require all five bindings, exact types, unique canonical keys, and zero unresolved required fields.
8. Keep the Calendar–Registry composition disabled until installation and disposable smoke are separately approved.

## Rollback

1. Disable the internal composition.
2. Remove local canonical mappings only after preserving any evidence needed for incident review.
3. Remove a Notion property only after proving every row is empty and obtaining separate destructive approval.

Removing a populated property destroys identity or synchronization evidence. No automatic rollback may clear Create Invocation ID, pair identity, Sync Writer Token, Sync Revision, Sync Hash, or Last Synced At.

## Activation boundary

Applying the migration did not:

- Register a public MCP operation.
- Install or activate a Bridge build.
- Create or modify an EVENT row.
- Create, update, or delete an EventKit item.

The internal composition remains disabled unless `BRIDGE_INTERNAL_CALENDAR_REGISTRY_SYNC=1` and an explicit private local calendar allowlist are supplied in a separately approved disposable-smoke environment.
