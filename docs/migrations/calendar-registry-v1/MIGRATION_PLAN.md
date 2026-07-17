# Calendar–Registry v1 registry migration

Status: prepared, not production-applied by this branch.

## Purpose

Add the rename-safe canonical binding `providerExternalId` to the `schedule` registry entity and bind it to the EVENTS rich-text property `Provider External ID`. This field stores EventKit's provider/server external identifier. It is deliberately not named `iCal UID`.

## Apply

1. Read the live EVENTS schema and current `schedule` registry entity.
2. Confirm all `requiredExistingKeys` from `registry-entity-patch.json` are bound with the expected types.
3. Add the Notion rich-text property `Provider External ID` only when absent.
4. Add or update the local canonical property map:
   - key: `providerExternalId`
   - Notion name: `Provider External ID`
   - type: `rich_text`
   - bound property ID: the live introspected ID
5. Re-read the schema and registry entity; require full binding and zero type drift.

## Rollback

Remove the local `providerExternalId` binding first. Remove the Notion property only after proving every row is empty. Removing a populated property destroys data and requires a separate destructive approval.

## Activation boundary

This migration does not register a public MCP tool, install a Bridge build, or authorize live calendar writes. The internal composition root remains disabled unless `BRIDGE_INTERNAL_CALENDAR_REGISTRY_SYNC=1` is set in an isolated smoke environment.
