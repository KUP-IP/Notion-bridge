# Notion Views capability matrix (Closeout-A A2)

Evidence date: **2026-07-20**. Smoke: [`views-write-smoke-2026-07-20.md`](views-write-smoke-2026-07-20.md).

| Capability | Public API | Bridge tool | Status |
|------------|------------|-------------|--------|
| List views | `GET /v1/views` | `notion_views_list` | **Implemented** |
| Get view (filter/sorts/config) | `GET /v1/views/{id}` | `notion_view_get` | **Implemented** |
| Create view | `POST /v1/views` | `notion_view_create` | **Implemented** (this PR) |
| Update view config | `PATCH /v1/views/{id}` | `notion_view_update` | **Implemented** (this PR) |
| Delete view | `DELETE /v1/views/{id}` | — | **Not yet** (follow-on) |
| Column `width` / `visible` | config.properties[] | via create/update + get | **Proven** (smoke PASS) |
| `wrap_cells` | configuration | via create/update + get | **Proven** |
| `frozen_column_index` | configuration | via create/update + get | **Proven** |
| Layouts / conditional format / property icons | UI | — | **UI-only** |

## Closeout-A disposition

- **Fork4=A:** Partial acceptable. Shipped subset = list/get/create/update + config fields proven on disposable DB.
- **OUT:** delete tool; production PACKETS/EVENTS write experiments.
- **Follow-on packet:** `notion_view_delete` + optional query-via-view if product needs it.

## Operator rules

1. Prefer disposable databases (see smoke parent `3a3cbb58889e8166ba5fc30451086e14`).
2. Configuration property entries require Notion **`property_id`** (resolve via `notion_datasource_get`).
3. Never smoke-write against production PACKETS (72 views).
