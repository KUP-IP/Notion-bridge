# Command custody A0

GitHub issue #140, packet A0 establishes a durable local authority boundary
for Command Bridge state. It deliberately does not add product-default
reconciliation UI, Search authoring, installation, or any downstream packet
surface.

## Authority and layout

The application bundle owns `CommandStore.defaultProductCatalog`. The local
store never writes a copy of an unmodified product body merely because an app
bundle is replaced.

The local authority is:

```text
~/Library/Application Support/The Bridge/commands/
  index.json, <legacy-slug>.md       legacy source retained, read-only to A0
  custody/
    state.json                       atomic active-revision pointer
    revisions/revision-<uuid>/
      layers.json                    local overrides, customs metadata,
                                     tombstones, favorite ID layout
      telemetry/usage.json           revision-bound non-body activity data
      bodies/<immutable-id>.md       local override and custom bodies only
      manifest.json                  SHA-256 for every revision payload
    live-telemetry/usage.json        ordinary activity overlay only
```

`state.json`, `layers.json`, `telemetry/usage.json`, and `manifest.json` carry
schema version 2. Custody directories are created `0700`; custody files are
created `0600`.

`layers.json` never contains a command body. Product-default bodies remain in
the app catalog; local body bytes live only in `bodies/`. A usage stamp writes
only `live-telemetry/usage.json`, so telemetry cannot rewrite command bodies,
override metadata, tombstones, favorites, or the active revision.

The layer also records whether product defaults have been activated. A fresh
`seedIfEmpty()` activation exposes the catalog and its initial slots. A
custom-only pre-seed store remains custom-only, preserving the former API's
behavior instead of silently materializing defaults during an unrelated create.
An existing legacy index is already an initialized palette: `seedIfEmpty()`,
startup, and command reads leave it untouched.

## Immutable production mapping

| Legacy slug | Immutable ID |
| --- | --- |
| `initiate` | `bridge.command.builtin.initiate` |
| `propose` | `bridge.command.builtin.propose` |
| `scope-cut` | `bridge.command.builtin.scope-cut` |
| `validate` | `bridge.command.builtin.validate` |
| `execute` | `bridge.command.builtin.execute` |
| `review` | `bridge.command.builtin.review` |
| `refocus` | `bridge.command.builtin.refocus` |
| `open-loops` | `bridge.command.builtin.open-loops` |
| `close-agent` | `bridge.command.builtin.close-agent` |
| `hand-off` | `bridge.command.builtin.hand-off` |

Legacy custom commands receive a deterministic identity:
`bridge.command.legacy.<sha256("bridge-command-v1:<slug>")>`. New customs
receive `bridge.command.custom.<uuid>`. A favorite maps `slot -> immutable ID`,
never `slot -> body` or `slot -> mutable display name`.

## Migration and recovery

Command observation is non-mutating. `list`, `get`, `search`, key-slot lookup,
constitution assembly for `bridge_initialize`, app startup, and application
replacement may read legacy or custody state but cannot create a custody
revision, rewrite legacy bytes, or repair an active pointer. A command fire may
write the separate live-telemetry overlay; it never writes a custody revision
or a command body.

The first requested command-state mutation (`create`, `update`, `delete`, or
favorite reassignment) is the migration boundary:

1. Read and validate the complete legacy index and every UTF-8 body before
   writing local custody. Duplicate/unsafe slugs, duplicate slots, missing
   bodies, and mapping conflicts fail closed.
2. Build an effective snapshot. Existing production slugs become the mapping
   above; changed built-ins become local overrides; non-production slugs become
   custom commands; absent production commands become tombstones.
3. Write a fully-contained staging revision, hash every payload, and rename it
   into `revisions/`. It is not active until the atomic `state.json` write.
4. Keep prior revision IDs in `state.json`. On a hash, manifest, or payload
   failure, a read may serve the first manifest-valid prior revision without
   changing `state.json`; the next command-state mutation atomically repairs
   the pointer before publishing its new revision. No valid prior revision is
   treated as corruption, not as an empty command set. Recovery never scans
   arbitrary revision directories, so a revision finalized before an
   interrupted activation can never be promoted.

The legacy files are not removed or rewritten by A0. Thus a migration failure
before activation leaves the previous source exactly available for a retry; an
interrupted post-finalization write leaves its orphan revision unreachable from
the still-active pointer.

## Proof surface

`CommandCustodyTests.swift` uses `CommandStore.currentLegacyProductionFixture`
as the v1 production fixture and proves exact effective-state read-back,
byte-for-byte custom and override body survival, hidden-default behavior,
favorite independence, non-mutating legacy reads and seeding, idempotence,
app-replacement non-mutation, permissions, interrupted-write rollback,
non-mutating corrupt-revision fallback plus mutation-time repair,
failed-migration retry, and fail-closed ambiguous identities.
`BridgeInitializeTests.swift` invokes `BridgeInitializeService.run` with an
isolated legacy command store and proves that `bridge_initialize` builds its
command index without creating custody or changing any legacy byte.

For an operator-specific verification without committing private command bodies,
run the same suite with `BRIDGE_A0_LEGACY_FIXTURE_ROOT` set to the legacy
`commands/` directory. The test copies that index and its bodies into a fresh
temporary root, migrates only the copy, and compares its effective state and
locally-custodied body bytes against the source. It never writes the supplied
directory.

A1 (`docs/commands-reconciliation-a1.md`) adds optional `adoptedBases` on
`layers.json` and `adopted-bases/<id>.md` bodies. Schema version remains 2.
Existing A0 revisions without those keys stay valid.

B0 (`docs/commands-directional-b0.md`) rewrites catalog bodies to the
directional contract and sets `behaviorVersion` to 2. Schema version stays 1
on the catalog; custody schema stays 2.
