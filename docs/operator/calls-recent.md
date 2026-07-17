# `calls_recent` operator guide

`calls_recent` is The Bridge's read-only view of the local macOS CallHistoryDB.
It returns phone records; it does not resolve a number to a person and does not
modify call history.

## Usage

```json
{
  "limit": 20,
  "since": "2026-07-17T00:00:00Z",
  "number": "+1 (605) 555-0123",
  "direction": "outbound"
}
```

Every field is optional. `limit` defaults to 20 and is capped at 100.
`direction` accepts `inbound`, `outbound`, or `all`. The number filter removes
non-decimal characters and then requires an exact normalized match. Results are
newest-first.

The response includes `identityResolved: false`. Call direction, answered
state, duration, and service-provider metadata are call facts only; none proves
who owns the number.

## Full Disk Access

If the database cannot be opened, the tool returns
`full_disk_access_required` with remediation instead of an empty list. Grant
Full Disk Access to The Bridge in **System Settings > Privacy & Security > Full
Disk Access**, relaunch The Bridge, reconnect MCP clients, and retry.

An incompatible database returns `unsupported_call_history_schema` with the
missing columns. Do not treat that response as evidence that there were no
calls.

## Scope boundary

Wave 1 intentionally stops at read-only call truth. Prospect matching, outreach
writes, dialing, message drafts, and next-action recommendations belong to later
reviewed waves in `PKT-CALL-001`; they are not implied by this tool.
