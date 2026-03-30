# AGENTS.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Project Overview

NotionBridge is a native macOS menu bar app (Swift 6.2, macOS 26+, Apple Silicon) that runs an MCP (Model Context Protocol) server. It exposes **73** MCP tools in total — **72** from registered feature modules plus **1** builtin tool (`echo`) — over Streamable HTTP, legacy SSE, and stdio, routing every call through a security gate with an append-only audit log. Feature code is organized in **14** Swift modules (`*Module`); `echo` is registered separately as `builtin`.

Bundle ID: `kup.solutions.notion-bridge` (legacy: `solutions.kup.keepr`)

## Commands

### Build

```bash
# Debug build (fast iteration)
make debug
# or: swift build -c debug

# Release build (strict concurrency enforced)
make build
# or: swift build -c release -Xswiftc -strict-concurrency=complete
```

### Test

The test suite is a **standalone executable**, not XCTest. It must be compiled and run as a binary:

```bash
make test
# Equivalent to: swift build -c debug && .build/debug/NotionBridgeTests
```

There is no way to run a single test file in isolation — all tests run from `NotionBridgeTests/main.swift`, which calls module-level `run*Tests()` functions.

### App Bundle & Distribution

```bash
make app        # Package .app bundle (requires make build first)
make install    # Build .app and install to /Applications (resets TCC for legacy + current bundle IDs)
make dmg        # Create distributable DMG
make sign       # Code-sign with Developer ID
make notarize   # Submit to Apple notarization (requires keychain profile)
make release    # Full pipeline: clean → test → app → sign → notarize → dmg → verify
```

### Maintenance

```bash
make clean      # Remove build artifacts
make clean-tcc  # Reset TCC permissions for both legacy (solutions.kup.keepr) and current bundle IDs
```

### Configuration

Set the HTTP/SSE port (default 9700):
```bash
NOTION_BRIDGE_PORT=9701 .build/release/NotionBridge
```

Set the Notion API token (resolution priority order):
1. `NOTION_API_TOKEN` environment variable
2. `NOTION_API_KEY` environment variable (legacy)
3. `~/.config/notion-bridge/config.json` — key: `notion_api_token`

## Architecture

### Package Structure

`Package.swift` defines three targets:
- **`NotionBridgeLib`** — shared library containing all core logic. Covers everything in `NotionBridge/` except `App/NotionBridgeApp.swift` and `Server/main.swift`. Both the app and the test executable depend on this.
- **`NotionBridge`** — app executable. Entry point is `App/NotionBridgeApp.swift`.
- **`NotionBridgeTests`** — test executable. Entry point is `NotionBridgeTests/main.swift`.

Dependencies: `MCP` (MCP Swift SDK 0.11.0), `NIOCore/NIOPosix/NIOHTTP1` (swift-nio 2.65+).

### Request Data Flow

Every tool call follows this pipeline regardless of transport:

```
Client → Transport (stdio or SSE) → ServerManager → ToolRouter.dispatch()
       → SecurityGate.enforce() → Module handler → AuditLog.append() → Response
```

`ToolRouter` is the central dispatch hub and is transport-agnostic. Modules never know which transport delivered the request.

### Core Components

**`ServerManager`** (`NotionBridge/Server/ServerManager.swift`) — actor that orchestrates startup: creates `SecurityGate`, `AuditLog`, and `ToolRouter`; registers all modules; wires MCP `ListTools`/`CallTool` handlers; starts both transports concurrently via `TaskGroup`. The `NOTION_BRIDGE_PORT` env var is read here.

**`ToolRouter`** (`NotionBridge/Server/ToolRouter.swift`) — actor. Central registry and dispatch hub. Each `ToolRegistration` carries a name, module, `SecurityTier`, description, JSON input schema, and a `@Sendable` async handler closure. `dispatchFormatted()` is the shared helper used by all transports (returns `(text: String, isError: Bool)` for MCP `CallTool` responses).

**`SecurityGate`** (`NotionBridge/Security/SecurityGate.swift`) — actor. Enforces a 3-tier model:
- `.open` — execute immediately, no user interaction
- `.notify` — execute immediately, then send a fire-and-forget notification via `UNUserNotificationCenter`
- `.request` — request explicit user approval before execution; 30-second timeout defaults to deny

Three decision outcomes: `.allow`, `.reject(reason:)`, `.handoff(command:explanation:warning:)`. Handoff is **not an error** — it returns a JSON response to the caller with instructions to run the command manually. Nuclear patterns (e.g., `diskutil erasedisk`, `csrutil disable`, `dd if=`, fork bomb, recursive delete of `/`) always produce handoff regardless of tier or trusted mode. `sudo` is always a handoff. **Trusted mode** (UserDefaults key `com.notionbridge.security.trustedMode`) auto-allows all `.notify` tier calls; nuclear and dangerous command patterns are still enforced.

For `shell_exec`/`cli_exec` tools, commands matching `safeCommandPatterns` (read-only: `ls`, `cat`, `git status`, etc.) auto-allow. Commands matching `dangerousCommandPatterns` (pipe to shell, `chmod 777`, etc.) produce handoff.

**`AuditLog`** (`NotionBridge/Security/AuditLog.swift`) — actor. Append-only in-memory log with disk persistence via `LogManager`. Writes to `~/Library/Logs/NotionBridge/notion-bridge.log` (JSON lines, 10MB rotation with one backup). Every tool call gets an `AuditEntry` regardless of outcome (approved / rejected / escalated / error).

**`SSEServer`** (`NotionBridge/Server/SSETransport.swift`) — actor. NIO-based HTTP server with two transport modes:
- **Streamable HTTP**: `POST /mcp` with `Mcp-Session-Id` header — each session gets its own `StatefulHTTPServerTransport` and `Server` instance, all sharing one `ToolRouter`
- **Legacy SSE**: `GET /sse` + `POST /messages` — for clients like Notion that use the standard split SSE spec
- **Health endpoint**: `GET /health` returns JSON `{status, tools, uptime, version, clients}`

`LegacySSEBridge` is `@unchecked Sendable` (uses `NSLock`) to safely write SSE events to NIO channels from async contexts.

**`AppDelegate`** (`NotionBridge/App/AppDelegate.swift`) — single-instance guard (PID check), `SMAppService` login item registration, signal handlers (SIGTERM/SIGABRT → `fsync` for crash breadcrumbs), launches both transports in a `Task.detached` group.

### Module Registration Pattern

Every module exposes a `static func register(on router: ToolRouter) async` method (some take additional parameters, e.g., `SessionModule.register(on:auditLog:)`). `ServerManager.setup()` calls all of them in sequence. Adding a new tool means adding a `ToolRegistration` inside the module's `register` method.

### Skills MCP tools (`SkillsModule`)

MCP metadata (`summary`, `triggerPhrases`, `antiTriggerPhrases`) is **authoritative** in app storage (`com.notionbridge.skills`). Optional Notion page `rich_text` properties mirror it for humans: **`Bridge Summary`**, **`Bridge Triggers`**, **`Bridge Anti-triggers`** (one phrase per line in the latter two). Use `manage_skill` **`sync_metadata_to_notion`** / **`sync_metadata_from_notion`** to copy in either direction; create those properties on the skill page if missing.

- **`list_routing_skills`** (`.open`) — Returns enabled skills with `visibility == routing` and a non-empty Notion page id, including MCP metadata fields. Does not fetch page bodies.
- **`fetch_skill`** (`.open`) — Loads a configured skill page: paginates blocks, returns `summary` / `triggerPhrases` / `antiTriggerPhrases` next to `content`. Cache key includes a metadata fingerprint so metadata edits do not reuse stale fetches.
- **`manage_skill`** (`.request`) — Registry CRUD, `set_visibility`, **`set_metadata`** (partial updates), and Notion sync actions above. Not a secrecy boundary: approved calls still see all skills.

`notion_page_read` uses the same block collection as skills: paginated siblings; optional nesting via `includeNested` (default false). Prefer `notion_page_markdown_read` for full prose when block structure is unnecessary.

### Notion Token Configuration

`NotionTokenResolver` (`NotionBridge/Notion/NotionClient.swift`) handles token resolution at runtime. To update the token from the UI, call `NotionTokenResolver.writeToken(_:)` (writes to `~/.config/notion-bridge/config.json`) and post `Notification.Name.notionTokenDidChange` to trigger re-validation. Token format must start with `ntn_` or `secret_` and be ≥20 characters.

### Swift 6 Concurrency Notes

The project enforces Swift 6 strict concurrency (`-strict-concurrency=complete`). Key patterns to follow:
- All shared mutable state lives in `actor` types (`ToolRouter`, `SecurityGate`, `AuditLog`, `ServerManager`, `SSEServer`, `LogManager`).
- `StatusBarController` is `@MainActor @Observable`.
- Closures passed across actor boundaries must be `@Sendable`.
- `LegacySSEBridge` uses `@unchecked Sendable` with `NSLock` — this is intentional to avoid passing actor references into NIO pipeline handlers (see PKT-338 comment in `SSETransport.swift`).
- NIO `ChannelHandlerContext` references stored in closures must be marked `nonisolated(unsafe)`.

### TCC Permissions

The app requires Full Disk Access, Automation, and optionally Screen Recording and Accessibility. During development, after frequent rebuilds that change the code signature, run `make clean-tcc` to clear stale TCC grants for both the current (`kup.solutions.notion-bridge`) and legacy (`solutions.kup.keepr`) bundle IDs.
