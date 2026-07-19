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

Successful response shape (field names are authoritative):

```json
{
  "success": true,
  "source": "CallHistoryDB",
  "identityResolved": false,
  "count": 1,
  "calls": [
    {
      "id": "754D6E7D-3764-49FC-823E-8710CFD8AA76",
      "startedAt": "2026-07-19T04:37:51.072Z",
      "durationSeconds": 0,
      "number": "+15073847875",
      "normalizedNumber": "15073847875",
      "direction": "inbound",
      "answered": false,
      "callType": 1,
      "serviceProvider": "com.apple.Telephony"
    }
  ]
}
```

Call direction, answered state, duration, and service-provider metadata are call
facts only; none proves who owns the number.

## Durable call `id`

- Prefer CallHistory `ZUNIQUE_ID` when present (UUID string observed on macOS).
- If `ZUNIQUE_ID` is null/empty, fall back to `Z_PK` as a decimal string.
- The same source row yields the same `id` across repeated reads on an unchanged
  database. Follow-on tools (e.g. future `log_call_touch`) must treat `id` as
  the idempotency key and must not invent a second identity scheme.

## Error taxonomy

Failures never degrade to an empty-success list. Codes are distinguishable:

| Code | When |
|---|---|
| `database_missing` | Path does not exist on disk |
| `full_disk_access_required` | DB exists but open is denied (typically FDA) |
| `unsupported_call_history_schema` | Required `ZCALLRECORD` columns missing |
| `call_history_query_failed` | Open succeeded; prepare/step failed |

Grant Full Disk Access to The Bridge in **System Settings > Privacy & Security >
Full Disk Access**, relaunch The Bridge, reconnect MCP clients, and retry when
you see `full_disk_access_required`.

## Scope boundary

Wave 1 / Wave 1R stop at read-only call truth. Prospect matching, outreach
writes, dialing, message drafts, and next-action recommendations belong to later
reviewed waves in `PKT-CALL-001`; they are not implied by this tool. W1R success
does not authorize Wave 2 schema or `log_call_touch`.
