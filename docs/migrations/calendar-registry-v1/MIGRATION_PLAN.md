# Calendar–Registry v1 registry migration

Status: prepared, not production-applied by this branch.

## Purpose

Add two rename-safe canonical bindings to the `schedule` registry entity: `providerExternalId` → `Provider External ID` and `operationFingerprint` → `Operation Fingerprint`. Both are rich text. The provider field stores EventKit's provider/server external identifier; the fingerprint stores the immutable SHA-256 operation manifest and is independent of the local recovery ledger.

## Apply

1. Read the live EVENTS schema and current `schedule` registry entity.
2. Confirm all `requiredExistingKeys` from `registry-entity-patch.json` are bound with the expected types.
3. Add the Notion rich-text properties `Provider External ID` and `Operation Fingerprint` only when absent.
4. Add or update both local canonical property mappings with role `generic` and their live introspected property IDs.
5. Re-read the schema and registry entity; require full binding and zero type drift.

## Rollback

Remove the local `providerExternalId` and `operationFingerprint` bindings first. Remove either Notion property only after proving every row is empty. Removing a populated property destroys data and requires a separate destructive approval.

## Activation boundary

This migration does not register a public MCP tool, install a Bridge build, or authorize live calendar writes. The internal composition root remains disabled unless `BRIDGE_INTERNAL_CALENDAR_REGISTRY_SYNC=1` is set in an isolated smoke environment.
