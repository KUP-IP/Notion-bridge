# Views write smoke + Demo Gate — 2026-07-21 (W5B install)

Installed SHA: `7a13c67f5babdc22d3933f6b9a6f380e3b4d104f` · bundle `kup.solutions.the-bridge` · tools 212

| Step | Result |
|------|--------|
| Parent / disposable DB | `3982caff-a7e6-4ccc-ab45-223220191813` |
| Data source | `f0c936c6-4fd8-447c-af0c-ba198e343c36` |
| Create `notion_view_create` | view `3a4cbb58-889e-8118-838c-000c5bf1db77` **W5B Demo Table 2026-07-21** |
| Create Demo Gate | **PASS** (operator 2026-07-21) |
| DS add props | Smoke Priority / Score / Flag / URL / Date via `notion_datasource_update` |
| Update `notion_view_update` | renamed **W5B Demo Table — RESIZED**; widths 120/90/200/70/60/360/250/160; wrap=false; frozen=2 |
| Reject (no parent) | Error: at least one of databaseId or dataSourceId is required |
| Update Demo Gate | **PENDING operator PASS/FAIL** |

**View URL:** https://app.notion.com/p/3982caffa7e64cccab45223220191813?v=3a4cbb58889e8118838c000c5bf1db77

**Never wrote to production PACKETS/EVENTS.**

## W5B feature smoke

`./scripts/w5b-live-smoke.sh` → 14/14 PASS on `7a13c67`.  
Keychain storm Demo Gate: still awaiting explicit PASS/FAIL (create PASS recorded separately).
