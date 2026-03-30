# Changelog

All notable changes to NotionBridge will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.5.3] — 2026-03-30

### Added
- **[SECURITY.md](SECURITY.md)** — Vulnerability reporting scope, out-of-scope items, Sparkle channel guidance.
- **GitHub issue templates** — Bug and feature forms under `.github/ISSUE_TEMPLATE/`.
- **`make verify-sparkle-feed`** and **`scripts/verify_sparkle_feed.sh`** — Confirms `SUFeedURL` from `Info.plist` returns HTTP 200 and XML-shaped content (run before/after publishing `appcast.xml`).

### Changed
- **[README.md](README.md)** — Canonical tool counts (**73** = 72 module + `echo`); SkillsModule **3** tools; **Public updates (Sparkle)** and **Security disclosures** sections.
- **[AGENTS.md](AGENTS.md)** — Aligned MCP tool count with runtime (`echo` as builtin).
- **[PRIVACY.md](PRIVACY.md)**, **[TERMS.md](TERMS.md)** — Stripe as primary processor; Lemon Squeezy described only where applicable as merchant of record.
- **[Version.swift](NotionBridge/Config/Version.swift)** — Build constant aligned with `Info.plist` (8).

### Notes (distribution)
- Sparkle requires the appcast URL to be **publicly readable** (e.g. public GitHub repo for `raw.githubusercontent.com/.../appcast.xml`, or host `appcast.xml` on your own HTTPS origin and set `SUFeedURL`). See README.
- **GitHub repository** `KUP-IP/Notion-bridge` is **public**, so the default `SUFeedURL` is anonymously reachable; run **`make verify-sparkle-feed`** to confirm after changes to `appcast.xml`.

### Notes (UEP closeout)
- Documentation and tooling delivered in-repo; sync **Status** / **Summary** on any linked Notion packet or project if this work was tracked in KUP·OS DOCS.

## [1.5.2] — 2026-03-30

### Added
- **Skills MCP metadata** — `summary`, `triggerPhrases`, and `antiTriggerPhrases` stored with each skill (UserDefaults); Notion `rich_text` mirror properties **`Bridge Summary`**, **`Bridge Triggers`**, **`Bridge Anti-triggers`**. New `manage_skill` actions: `set_metadata`, `sync_metadata_to_notion`, `sync_metadata_from_notion`. `list_routing_skills`, `manage_skill list`, and `fetch_skill` expose metadata; `fetch_skill` cache key includes a metadata fingerprint.
- **SkillNotionMetadata** — Shared encode/decode for Notion page property patches (2000-char rich_text chunks).

### Changed
- **Settings → Connections** — Sections clarified: Notion workspaces vs API connections (Stripe); footers explain tunnel vs tokens. **API connections** list uses `ConnectionRegistry` `kind: .api` with provider badges.
- **Settings → Skills** — Footer explains Standard / Routing / Admin visibility; optional summary line in skill rows.
- **Settings → Advanced → Network** — Copy explains local SSE port vs remote tunnel; tunnel must forward to the same port after changes.
- **Permissions → Notifications** — `PermissionManager` maps `UNAuthorizationStatus` consistently; one-shot `requestAuthorization` when still `notDetermined` to sync System Settings–only grants; remediation text when status is unknown.

### Changed (release)
- Version bump: 1.5.1 → **1.5.2**, build 7 → **8** (`Version.swift`, `Info.plist`).
- **Sparkle (`appcast.xml`)** — Item for 1.5.2 (build 8). If the release DMG from `make dmg` differs in size from the committed appcast, run `sign_update` on the exact uploaded `.dmg` and update `length` / `sparkle:edSignature` before publishing the GitHub release.
- **Purchase download (kup.solutions)** — In the `kup.solutions` repo, `workers/nb-fulfillment/wrangler.toml` `DMG_OBJECT_KEY` is set to `notion-bridge-v1.5.2.dmg`. Upload that file to R2 bucket `nb-downloads`, then deploy the `nb-fulfillment` worker.

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
