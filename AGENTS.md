# AGENTS.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Project Overview

NotionBridge is a native macOS menu bar app (Swift 6, macOS 26+, Apple Silicon) that runs an MCP (Model Context Protocol) server. It exposes 40 tools across 10 modules via both stdio and SSE transports, routing every call through a security gate with an append-only audit log.

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
make install    # Build .app and install to /Applications (also clears legacy TCC)
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

Set the SSE port (default 9700):
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

**`ToolRouter`** (`NotionBridge/Server/ToolRouter.swift`) — actor. Central registry and dispatch hub. Each `ToolRegistration` carries a name, module, `SecurityTier`, description, JSON input schema, and a `@Sendable` async handler closure. `dispatchFormatted()` is the shared helper used by all transports (returns `(text: String, isError: Bool)` for MCP `CallTool` responses). Batch gate triggers at ≥3 planned calls.

**`SecurityGate`** (`NotionBridge/Security/SecurityGate.swift`) — actor. Enforces a 2-tier model:
- `.open` — execute immediately, no prompt
- `.notify` — request user approval via `UNUserNotificationCenter` (falls back to `NSAlert`); 30-second timeout defaults to deny

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

## Cursor Cloud specific instructions

### Platform constraint

NotionBridge is **macOS-only**. The Cloud Agent VM runs Ubuntu 24.04 x86_64, so building, testing, and running the app are not possible in this environment. Sixteen source files import macOS-exclusive frameworks (AppKit, SwiftUI, ScreenCaptureKit, ApplicationServices, Vision, ServiceManagement, CoreGraphics, UserNotifications). There are no `#if os(Linux)` guards.

### What works on Linux

- **Swift 6.2.4** is installed at `/opt/swift-6.2.4-RELEASE-ubuntu24.04/usr/bin/swift` (added to `PATH` via `~/.bashrc`).
- **`swift package resolve`** succeeds — all SPM dependencies (MCP Swift SDK, swift-nio, swift-log, swift-collections, swift-async-algorithms, etc.) download and resolve.
- **Dependency compilation** succeeds — all third-party targets compile on Linux. The build only fails when compiling the project's own source files that import macOS frameworks.
- **`swift package dump-package`** and other SPM introspection commands work for validating `Package.swift`.

### What does not work on Linux

| Command | Failure reason |
|---------|---------------|
| `make debug` / `swift build` | `no such module 'AppKit'` (and other macOS frameworks) |
| `make test` / `swift run NotionBridgeTests` | Depends on NotionBridgeLib which cannot compile |
| `make build` (release) | Same framework errors |
| `make app` / `make install` | Requires successful build + macOS bundle tooling |

### Recommended workflow for Cloud Agents

1. **Code review and static analysis** — read/edit Swift source files, validate `Package.swift`, resolve dependencies.
2. **Dependency validation** — run `swift package resolve` after modifying `Package.swift`.
3. **Build/test verification** — defer to CI (GitHub Actions on `macos-14` runners). See `.github/workflows/ci.yml`.
4. For build/test commands, refer to the Commands section at the top of this file.
