# Views write smoke — 2026-07-20

Closeout-A Track A2 disposable write smoke (Fork4=A Partial bar).

| Step | Result |
|------|--------|
| Parent page | `3a3cbb58889e8166ba5fc30451086e14` (Registry Smoke Disposable 2) |
| Disposable database | `3982caff-a7e6-4ccc-ab45-223220191813` |
| Data source | `f0c936c6-4fd8-447c-af0c-ba198e343c36` |
| Notion-Version | `2025-09-03` |
| POST create view | `3a4cbb58-889e-818e-9b49-000c662fe33b` with width/visible/wrap/frozen |
| PATCH update | width 320 / Status hidden / Notes visible / wrap=false / frozen=1 |
| GET round-trip | wrap=`False` frozen=`1` props=`[('Name', 'title', True, 320), ('Status', 'KanS', False, None), ('Notes', 'sahG', True, 200)]` |
| Verdict | **PASS** |

**Never wrote to production PACKETS/EVENTS.**

**API note:** create requires `property_id` (not name). Initial DB create via POST /databases only materialised title; Status/Notes added via `notion_datasource_update`.

**Bridge gap:** tools today = `notion_views_list` + `notion_view_get` only. Write tools not registered → Closeout-A ships **Partial** (read proven + write API matrix) unless write tools land in follow-on PR.
