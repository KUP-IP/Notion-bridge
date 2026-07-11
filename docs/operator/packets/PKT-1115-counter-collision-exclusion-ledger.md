# PKT-1115 — Counter-Collision Guard Exclusion Ledger

Live-verified against `origin/main` at `5cbef137cacee11b2b675c013357ea8988055c2e` on 2026-07-11. These five reported gaps remain closed; no Swift source or monotonic counter was changed by PKT-1115.

| Claim | Current source evidence | Named covering test | Verdict |
| --- | --- | --- | --- |
| `shell_exec` is not limited to 60 seconds; long detached work has `bg_run`. | `TheBridge/Modules/ShellModule.swift:108-174` sets a 600-second foreground default, keeps only trailing-`&` work at 5 seconds, accepts an explicit timeout, and enforces it. `TheBridge/Modules/BgProcessModule.swift:182-229` registers `bg_run` as a detached process tool. | `TheBridgeTests/ShellModuleTests.swift:128-147` — `shell_exec timeout terminates long-running process`; `TheBridgeTests/BgProcessModuleTests.swift:176-200` — `LIVE: bg_run → bg_poll reaches exited with exitCode 0 + captured output`. | CLOSED |
| `registry_update` supports `appendKeys` using the shared append-merge primitive. | `TheBridge/Modules/Registry/RegistryModule.swift:639-676` declares/parses `appendKeys`; `TheBridge/Modules/Registry/RegistryWriter.swift:126-151` delegates to `RegistryAppendMerge.merge`. | `TheBridgeTests/RegistryModuleTests.swift:732-839` — `registry_update` original-shape, append, overwrite, empty-list, invalid-arg, and schema cases; `:1166-1186` — `RegistryAppendMerge.merge` append/overwrite cases. | CLOSED |
| `notion_page_create` verifies children materialization and self-repairs an empty result. | `TheBridge/Modules/NotionModule.swift:399-462` forwards children, reads blocks back, and appends the original children when the create produced zero blocks. | `TheBridgeTests/NotionModuleTests.swift:1123-1148` — `notion_page_create: <block type> children materialize (verified, auto-repaired if needed)`. | CLOSED |
| `notion_blocks_append` accepts `pageId`/`markdown` aliases. | `TheBridge/Modules/NotionModule.swift:649-650,665-679` defines and resolves the aliases while retaining the original `blockId`/`children` shape. | `TheBridgeTests/NotionModuleTests.swift:833-849` — `notion_blocks_append: pageId+markdown alias is accepted (not rejected as invalid-arguments)`. | CLOSED |
| Raw Accessibility API calls are main-actor isolated in the only two modules that use them. | `TheBridge/Modules/AccessibilityModule.swift:121-673` contains 24 `@MainActor` annotations around its AX paths; `TheBridge/Modules/MouseClickModule.swift:111-226` contains 6. A repo-wide Swift grep finds raw `AXUIElementCopyAttributeValue`/`AXUIElementPerformAction` calls only in those two files. | `TheBridgeTests/AccessibilityModuleTests.swift:60-76` — `ax_focused_app (revived) returns same shape as ax_inspect(focused_app)` plus traversal-budget cases at `:134-229`; `TheBridgeTests/MouseClickModuleTests.swift:74-89` — `mouse_click returns capability_missing or success on valid input`. Strict-concurrency compilation enforces the actor annotations. | CLOSED |

## Reproduction commands

```bash
rg -n 'staticFeatureModule(Tool|Family)Count' TheBridge/Config/Version.swift
rg -n '^FLOOR=' scripts/test-floor-gate.sh
rg -c '^\s*@MainActor' TheBridge/Modules/AccessibilityModule.swift TheBridge/Modules/MouseClickModule.swift
rg -l 'AXUIElementCopyAttributeValue|AXUIElementPerformAction' TheBridge --glob '*.swift'
rg -n 'registry_update:|RegistryAppendMerge.merge:|children materialize|pageId\+markdown alias|ax_focused_app \(revived\)|mouse_click returns capability_missing' TheBridgeTests
```
