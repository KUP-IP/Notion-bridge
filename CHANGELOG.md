# Changelog

## [1.5.5] — 2026-03-31

### Added
- **StripeModule** — 4 new Stripe catalog MCP tools (`stripe_product_read`, `stripe_product_update`, `stripe_price_read`, `stripe_prices_list`). Separate module from PaymentModule.
- **StripeClient** — 4 new methods: `retrieveProduct`, `updateProduct`, `retrievePrice`, `listPrices`. Reuses existing `authorizedRequest` helper.
- **StripeProduct** and **StripePrice** response structs for type-safe Stripe catalog data.
- Stripe connection capabilities expanded: `stripe_product_read`, `stripe_product_update`, `stripe_price_read`, `stripe_prices_list`.

### Fixed
- **Credential namespace bridge** — `CredentialManager.read()` now returns infrastructure keys (service `com.notionbridge`) instead of throwing `invalidType`. Enables agents to access Stripe API key and other infrastructure credentials via `credential_read` MCP tool.
- **Credential list visibility** — `CredentialManager.list()` now surfaces `com.notionbridge` infrastructure keys as metadata-only entries. No secrets exposed in list results.

All notable changes to NotionBridge will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.5.4] — 2026-03-31

### Fixed
- **KI-07: notion_page_markdown_write HTTP 400** — Changed API request body format from `page_content` to `replace_content` to match Notion API 2026-03-11 spec. Full page markdown replacement now works correctly.

### Added
- **Parent field in notion_page_read** — Response now includes `parent` object from the Notion API, enabling data source ID resolution from any page without additional API calls.

## [1.5.3] — 2026-03-30

### Added
- **Streamable HTTP tunnel compatibility** — When **Settings → Connections → Remote access** has a non-empty **tunnel URL** (`tunnelURL` in app storage), `POST /mcp` validation extends the default localhost-only **Origin** / **Host** allowlist to include that tunnel’s hostname (e.g. Cloudflare quick tunnels). The server still binds to **127.0.0.1** only; traffic must reach the app via a tunnel or reverse proxy to loopback. No `0.0.0.0` bind.
- **Mandatory MCP bearer when tunnel is active** — If the tunnel URL **parses** (same condition as the extended allowlist) and **no** MCP bearer is configured, Streamable HTTP **`POST /mcp`** is rejected (**401**). When a bearer is set (**Keychain** `mcp_bearer_token`, with **`com.notionbridge.mcpBearerToken`** as legacy/migration read), clients must send **`Authorization: Bearer …`**. With an **empty** tunnel URL, bearer is optional (setting a token still enforces it for localhost clients).
- **Remote access UI** — **MCP remote token** field (SecureField) with Generate / Copy / Clear when a tunnel URL is present; persists to Keychain + UserDefaults mirror.
- **`MCPHTTPValidation`** — Shared builder for the Streamable HTTP `StandardValidationPipeline` used by session creation in `SSETransport`; exposes **`streamableHTTPBearerPhase()`** for tests and diagnostics.
- **Tests** — `MCPHTTPValidationTests` for tunnel URL → host/origin allowlist parsing and bearer phase (remote missing token / bearer required / local optional).
- **Operator doc** — `docs/operator/cloudflare-access-notion-bridge.md` (Cloudflare Access in front of the tunnel; no secrets).

### Changed
- **`SSETransport` `createSession`** — Uses `MCPHTTPValidation.streamableHTTPPipeline(ssePort:)` instead of only `OriginValidator.localhost()`.

### Notes (distribution)
- After **`make dmg`**, confirm **`make verify-sparkle-feed`** and that **`length`** / **`sparkle:edSignature`** in `appcast.xml` match the uploaded GitHub release asset (regenerate with **`make appcast`** if the DMG changed).
- **Version / Sparkle** — Marketing **1.5.3**, build **10** (`Version.swift`, `Info.plist`). **`appcast.xml`** includes **1.5.3** (newest) plus prior **1.5.2** / **1.5.1** items. Upload **`notion-bridge-v1.5.3.dmg`** to the **v1.5.3** GitHub release so the enclosure URL resolves.
- **Purchase download (kup.solutions)** — When publishing this build to paid fulfillment, set `workers/nb-fulfillment/wrangler.toml` **`DMG_OBJECT_KEY`** to **`notion-bridge-v1.5.3.dmg`** (or keep the prior filename if you intentionally reuse it), re-upload the object, then deploy the worker if needed.

## [1.5.2] — 2026-03-30

### Removed
- **Skill visibility `adminOnly`** — Same behavior as Standard for MCP discovery; removed from UI and tool schema. Persisted registry entries and MCP calls using `adminOnly` are read as **standard**.

### Added
- **[SECURITY.md](SECURITY.md)** — Vulnerability reporting scope, out-of-scope items, Sparkle channel guidance.
- **GitHub issue templates** — Bug and feature forms under `.github/ISSUE_TEMPLATE/`.
- **`make verify-sparkle-feed`** and **`scripts/verify_sparkle_feed.sh`** — Confirms `SUFeedURL` from `Info.plist` returns HTTP 200 and XML-shaped content (run before/after publishing `appcast.xml`).
- **Skills MCP metadata** — `summary`, `triggerPhrases`, and `antiTriggerPhrases` stored with each skill (UserDefaults); Notion `rich_text` mirror properties **`Bridge Summary`**, **`Bridge Triggers`**, **`Bridge Anti-triggers`**. New `manage_skill` actions: `set_metadata`, `sync_metadata_to_notion`, `sync_metadata_from_notion`. `list_routing_skills`, `manage_skill list`, and `fetch_skill` expose metadata; `fetch_skill` cache key includes a metadata fingerprint.
- **SkillNotionMetadata** — Shared encode/decode for Notion page property patches (2000-char rich_text chunks).

### Changed
- **[README.md](README.md)** — Canonical tool counts (**73** = 72 module + `echo`); SkillsModule **3** tools; **Public updates (Sparkle)** and **Security disclosures** sections.
- **[AGENTS.md](AGENTS.md)** — Aligned MCP tool count with runtime (`echo` as builtin).
- **[PRIVACY.md](PRIVACY.md)**, **[TERMS.md](TERMS.md)** — Stripe as primary processor; Lemon Squeezy described only where applicable as merchant of record.
- **[Version.swift](NotionBridge/Config/Version.swift)** — Build constant kept in sync with `Info.plist`.
- **Settings → Connections** — Sections clarified: Notion workspaces vs API connections (Stripe); footers explain tunnel vs tokens. **API connections** list uses `ConnectionRegistry` `kind: .api` with provider badges.
- **Settings → Skills** — Footer explains Standard / Routing visibility; optional summary line in skill rows.
- **Settings → Advanced → Network** — Copy explains local SSE port vs remote tunnel; tunnel must forward to the same port after changes.
- **Permissions → Notifications** — `PermissionManager` maps `UNAuthorizationStatus` consistently; one-shot `requestAuthorization` when still `notDetermined` to sync System Settings–only grants; remediation text when status is unknown.

### Notes (distribution)
- Sparkle requires the appcast URL to be **publicly readable** (e.g. public GitHub repo for `raw.githubusercontent.com/.../appcast.xml`, or host `appcast.xml` on your own HTTPS origin and set `SUFeedURL`). See README.
- **GitHub repository** `KUP-IP/Notion-bridge` is **public**, so the default `SUFeedURL` is anonymously reachable; run **`make verify-sparkle-feed`** to confirm after changes to `appcast.xml`.

### Notes (UEP closeout)
- Documentation and tooling delivered in-repo; sync **Status** / **Summary** on any linked Notion packet or project if this work was tracked in KUP·OS DOCS.

### Changed (release)
- Version: marketing **1.5.2**; build **7 → 8 → 9** (`Version.swift`, `Info.plist`). Build **9** is the current shipping binary for 1.5.2 (includes `adminOnly` removal and doc/tooling updates above).
- **Sparkle (`appcast.xml`)** — Item for 1.5.2 (build **9**). If the release DMG from `make dmg` differs in size from the committed appcast, run `sign_update` / `generate_appcast` on the exact uploaded `.dmg` and update `length` / `sparkle:edSignature` before publishing the GitHub release.
- **Purchase download (kup.solutions)** — In the `kup.solutions` repo, `workers/nb-fulfillment/wrangler.toml` `DMG_OBJECT_KEY` is set to `notion-bridge-v1.5.2.dmg`. Re-upload that object after each new DMG build (same filename), then deploy the `nb-fulfillment` worker if needed.

## [1.5.1] — 2026-03-26

### Added
- **`screen_analyze` tool** — Dominant color extraction from screenshot files using CoreGraphics pixel sampling. Returns hex colors with percentages, average luminance (0-1), dark/light theme detection, and image dimensions. Open tier (read-only). Input: file path from `screen_capture`. Algorithm: 5-bit RGB quantization → frequency sort → top-N.

### Changed
- Version bump: 1.5.0 → 1.5.1, build 6 → 7.
- ServerManager: Added `ScreenModule.registerAnalyze(on:)` registration.

## [1.5.0] — 2026-03-25

### Added
- **TCC csreq mismatch detection** — `PermissionManager` now detects stale TCC entries where `auth_value=2` but runtime probe returns false. New "Reset & Re-authorize" UI banner in PermissionView.
- **reminders-bridge.swift** — Full EventKit CLI for Apple Reminders (8 commands: list-lists, create-list, create, read, update, complete, delete, search). Supports recurrence rules, location alarms, URL, priority, due dates.
- `Version.swift` as single source of truth for app versioning (replaces hardcoded fallback strings).

### Fixed
- **reminders-bridge v1.1.0** — `listId` UUID resolution fix + `notes` param alias (`notes` takes priority over `body`).
- **TCC csreq stale grants** — Automation targets with approved-but-stale code signing requirements now detected and resettable from UI.

### Changed
- **66 MCP tool descriptions rewritten** (PKT-488) — Every tool description now leads with action, names return shape, embeds behavioral gotchas, includes workflow hints. Removed all security tier badges (SecurityGate enforces at runtime).
- Version bump: 1.4.0 → 1.5.0, build 5 → 6.
- Info.plist synced with Version.swift (was stale at 1.4.0).

## [1.4.0] — 2026-03-24

### Added
- **ChromeModule Space-awareness** — Tab listing now reports which macOS Space each Chrome window occupies via ScreenCaptureKit `onScreen` field. `chrome_navigate` falls back to `open` when the target window isn't on the active Space.
- `.cursor/rules` for Cursor agent project context.
- `RELEASE_HANDOFF.md` with build/sign/notarize instructions.

### Fixed
- **Makefile rpath** — Corrected `@executable_path` → `@loader_path` for proper framework resolution.
- **Stripe payment tests** — Refactored `StripeTokenizationTests` to use shared `readRequestBody()` helper instead of inline body parsing.

### Changed
- **Swift 6.3 compatibility** — Compiler fixes, SkillsModule fix, added `patch-deps` Makefile target.
- **Module/tool count reconciliation** — Audited and corrected counts: 63 → 65 tools, 14 → 13 modules. Updated AGENTS.md and all E2E test assertions.
- Version bump: 1.2.0 → 1.4.0, build 4 → 5.
- DMG size reduced from ~12.9 MB to ~10.2 MB.

## [1.3.0] — 2026-03-20

### Added
- `contacts_search` tool via CNContactStore (#51).
- Reminders (`com.apple.reminders`) as 5th automation target.

## [1.2.0] — 2026-03-22

### Added
- Settings tweaks, `manage_skill` tool, Connection Manager guards.

## [1.1.5] — 2026-03-15

_Initial tracked release._

[1.5.0]: https://github.com/KUP-IP/Notion-bridge/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/KUP-IP/Notion-bridge/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/KUP-IP/Notion-bridge/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/KUP-IP/Notion-bridge/compare/v1.1.5...v1.2.0
[1.1.5]: https://github.com/KUP-IP/Notion-bridge/releases/tag/v1.1.5
