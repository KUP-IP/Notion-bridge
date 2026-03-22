# Notion Bridge

**macOS-native MCP server for Notion AI agents.**

Notion Bridge exposes local system capabilities — files, shell, screen, accessibility, messages, Chrome, Notion API, and more — as MCP tools that Notion AI agents can call over SSE. Built in Swift 6.2 as a menu-bar app targeting macOS 26 (Tahoe).

**Version 1.1.5 build 3** · 59 tools across 12 modules · 3-tier security model

---

## Table of Contents

- [Architecture](#architecture)
- [Modules](#modules)
- [Security Model](#security-model)
- [Getting Started](#getting-started)
- [Build & Test](#build--test)
- [Makefile Targets](#makefile-targets)
- [Project Structure](#project-structure)
- [Dependencies](#dependencies)
- [Configuration](#configuration)
- [License](#license)

---

## Architecture

Notion Bridge runs as a menu-bar app (`NSApplication`) with no dock icon. An SSE transport layer (`NIO`-backed) listens on `:9700` and speaks the Model Context Protocol. Every inbound tool call passes through `SecurityGate` before reaching the target module via `ToolRouter`.

```
Notion AI Agent
      │
      ▼
SSE Transport (:9700)
      │
      ▼
  ToolRouter
      │
      ▼
 SecurityGate ─── 3-tier enforcement
      │
      ▼
   Modules (12)
```

**Key components:**

| Component | Path | Role |
|-----------|------|------|
| SSETransport | `Server/SSETransport.swift` | NIO-based HTTP/SSE server on port 9700 |
| ToolRouter | `Server/ToolRouter.swift` | Dispatches tool calls to registered modules |
| SecurityGate | `Security/SecurityGate.swift` | Enforces security policies on every tool call |
| ConfigManager | `Config/ConfigManager.swift` | JSON-backed app configuration and sensitive paths |
| NotionClient | `Notion/NotionClient.swift` | Notion API wrapper for multi-workspace connections |

---

## Modules

### Overview

| # | Module | Tools | Tier(s) | Description |
|---|--------|-------|---------|-------------|
| 1 | **ShellModule** | 2 | request | Shell command execution and pre-approved script runner |
| 2 | **FileModule** | 12 | open / notify | File system operations, directory management, clipboard |
| 3 | **ChromeModule** | 5 | open / notify | Chrome tab control, page reading, JS execution, screenshots |
| 4 | **NotionModule** | 16 | open / notify | Full Notion API: pages, blocks, comments, search, queries |
| 5 | **MessagesModule** | 6 | open / request | iMessage/SMS: search, read, chat threads, send |
| 6 | **ScreenModule** | 4 | open / notify | Screenshots, OCR, screen recording (SCStream + AVAssetWriter) |
| 7 | **AccessibilityModule** | 5 | open / notify | macOS Accessibility API: AX tree, element inspection, actions |
| 8 | **AppleScriptModule** | 1 | request | In-process AppleScript execution via NSAppleScript |
| 9 | **SystemModule** | 3 | open | System info, process listing, macOS notifications |
| 10 | **SessionModule** | 3 | open / notify | Session info, tool registry introspection, session clear |
| 11 | **SkillsModule** | 1 | open | Fetch named Notion skill pages (cached 10 min) |
| 12 | **BuiltinModule** | 1 | open | Connectivity test (echo) |
| | **Total** | **59** | | |

> **CredentialModule** (`Modules/CredentialModule.swift`) provides internal credential infrastructure but does not register MCP tools.

### ShellModule (2 tools)

| Tool | Tier | Description |
|------|------|-------------|
| `shell_exec` | request | Execute a shell command with optional timeout and working directory |
| `run_script` | request | Execute a pre-approved script from the scripts directory |

### FileModule (12 tools)

| Tool | Tier | Description |
|------|------|-------------|
| `file_read` | open | Read text content from a file |
| `file_write` | notify | Write text content to a file |
| `file_append` | notify | Append text content to an existing file |
| `file_copy` | notify | Copy a file or directory |
| `file_move` | notify | Move a file or directory |
| `file_rename` | notify | Rename a file or directory in place |
| `file_list` | open | List directory contents (recursive, hidden) |
| `file_search` | open | Search for files by name substring |
| `file_metadata` | open | Get file/directory metadata (size, dates, type) |
| `dir_create` | notify | Create a directory with intermediate parents |
| `clipboard_read` | open | Read text from system clipboard |
| `clipboard_write` | open | Write text to system clipboard |

### ChromeModule (5 tools)

| Tool | Tier | Description |
|------|------|-------------|
| `chrome_tabs` | open | List all open Chrome tabs across windows |
| `chrome_read_page` | open | Extract page content via JS (text or HTML, optional CSS selector) |
| `chrome_execute_js` | notify | Execute arbitrary JavaScript in a Chrome tab |
| `chrome_navigate` | notify | Navigate a tab to a URL or open a new tab |
| `chrome_screenshot_tab` | open | Capture visible Chrome tab content as PNG |

### NotionModule (16 tools)

| Tool | Tier | Description |
|------|------|-------------|
| `notion_search` | open | Search workspace for pages and databases |
| `notion_query` | open | Query a data source with optional filter and sort |
| `notion_page_read` | open | Read page properties and child blocks |
| `notion_page_markdown_read` | open | Get page content as markdown |
| `notion_page_markdown_write` | notify | Replace page body with markdown content |
| `notion_page_create` | notify | Create a new page under a parent page or database |
| `notion_page_update` | notify | Update a page's properties |
| `notion_page_move` | notify | Move a page to a new parent |
| `notion_blocks_append` | notify | Append child blocks to a page or block |
| `notion_block_delete` | notify | Delete (trash) a block by ID |
| `notion_comments_list` | open | List comments on a page or block |
| `notion_comment_create` | notify | Create a comment on a page |
| `notion_users_list` | open | List all workspace users |
| `notion_file_upload` | notify | Upload a local file to Notion (max 20 MB) |
| `notion_connections_list` | open | List configured workspace connections with health status |
| `notion_token_introspect` | open | Introspect the current Notion API token |

### MessagesModule (6 tools)

| Tool | Tier | Description |
|------|------|-------------|
| `messages_recent` | open | List recent conversations with last message preview |
| `messages_chat` | open | Get message thread with a specific contact |
| `messages_content` | open | Get a single message by ROWID with full metadata |
| `messages_search` | open | Search messages by keyword (native SQLite on chat.db) |
| `messages_participants` | open | List participants in a chat |
| `messages_send` | request | Send an iMessage or SMS/RCS via AppleScript |

### ScreenModule (4 tools)

| Tool | Tier | Description |
|------|------|-------------|
| `screen_capture` | open | Screenshot display, window, or region (ScreenCaptureKit) |
| `screen_ocr` | open | Capture screen and extract text via Vision framework OCR |
| `screen_record_start` | notify | Begin screen recording (SCStream + AVAssetWriter, 60s safety cap) |
| `screen_record_stop` | notify | Stop active recording, return file path and duration |

### AccessibilityModule (5 tools)

| Tool | Tier | Description |
|------|------|-------------|
| `ax_focused_app` | open | Get frontmost app name, bundle ID, PID, and focused element |
| `ax_tree` | open | Dump AX element hierarchy (configurable depth, tree or flat) |
| `ax_find_element` | open | Search AX tree by role, title, and/or label |
| `ax_element_info` | open | Deep inspect a single AX element (attributes, actions, state) |
| `ax_perform_action` | notify | Perform an action on an AX element (press, setValue, focus, etc.) |

### AppleScriptModule (1 tool)

| Tool | Tier | Description |
|------|------|-------------|
| `applescript_exec` | request | Execute AppleScript in-process via NSAppleScript |

### SystemModule (3 tools)

| Tool | Tier | Description |
|------|------|-------------|
| `system_info` | open | macOS system information (OS, hardware, CPU, memory, uptime) |
| `process_list` | open | List running processes (filter, sort by CPU/mem/pid/name) |
| `notify` | open | Send a local macOS notification via UNUserNotificationCenter |

### SessionModule (3 tools)

| Tool | Tier | Description |
|------|------|-------------|
| `session_info` | open | Session uptime, connections, tool calls, active clients |
| `tools_list` | open | Live tool registry with names, modules, tiers, and schemas |
| `session_clear` | notify | Clear session audit log (requires confirmation) |

### SkillsModule (1 tool)

| Tool | Tier | Description |
|------|------|-------------|
| `fetch_skill` | open | Fetch a named Notion skill page by name (cached 10 min) |

### BuiltinModule (1 tool)

| Tool | Tier | Description |
|------|------|-------------|
| `echo` | open | Echo back input message (connectivity testing) |

---

## Security Model

Notion Bridge enforces a **3-tier security model** on every tool call. No tool can bypass the SecurityGate — it is not optional.

### Tiers

| Tier | Behavior | Use Case |
|------|----------|----------|
| **Open** | Execute immediately. No user interaction. | Read-only operations (file_read, screen_capture, searches) |
| **Notify** | Execute immediately, then send a fire-and-forget macOS notification. | Write operations that are non-destructive (file_write, page updates) |
| **Request** | Require explicit pre-execution approval via macOS notification. 30 s timeout → deny. | Sensitive operations (shell_exec, applescript_exec, messages_send) |

### Enforcement Order

SecurityGate evaluates every tool call in this order:

1. **Nuclear pattern check** — Fork bomb detection. Matched patterns are handed off to manual Terminal execution (never run in-process).
2. **Safe command auto-allow** — For `shell_exec`, read-only commands (`cat`, `ls`, `git status`, etc.) are auto-allowed regardless of tier.
3. **Sensitive path check** — Access to configured sensitive paths prompts for session or permanent allow (config.json-backed, with UserDefaults for permanent grants).
4. **Tier-based logic** — Open → allow, Notify → allow + notification, Request → interactive approval (Allow / Deny / Always Allow).

### Approval Flow

Request-tier approval uses `UNUserNotificationCenter` with three actions:

- **Allow** — One-time approval for this call.
- **Deny** — Reject the call (also triggered on 30 s timeout).
- **Always Allow** — Learn the command prefix and auto-allow future matches.

Falls back to synchronous `NSAlert` if notification permission is denied or when running outside a bundled app context.

### Additional Protections

- **Learned allow prefixes** — "Always Allow" responses are stored in config and used for prefix-based auto-approval of recognized commands.
- **Sensitive paths** — Dynamic list in `ConfigManager` (config.json-backed, seeded with defaults on first launch). Session-scoped and permanent allow grants.
- **Audit log** — Every tool call is logged via `AuditLog` for session review.

---

## Getting Started

### Requirements

- macOS 26 (Tahoe) or later
- Swift 6.2+ toolchain
- Xcode 26+ (for AppKit / ScreenCaptureKit / Vision frameworks)
- A Notion API integration token

### Quick Start

```bash
# Clone
git clone https://github.com/isaiahpeterscode/keepr-bridge.git
cd keepr-bridge

# Build and run (debug)
make debug
.build/debug/NotionBridge

# Or build the app bundle
make app
open .build/NotionBridge.app
```

On first launch, Notion Bridge will:
1. Prompt for Notion API token via the onboarding window
2. Request notification permission (for SecurityGate approval flow)
3. Start the SSE server on port 9700
4. Appear in the menu bar

### Connecting to Notion

Add Notion Bridge as an MCP server integration in your Notion AI agent settings. Point it at `http://localhost:9700/sse`.

---

## Build & Test

```bash
# Debug build
make debug

# Release build (strict concurrency)
make build

# Run test suite (custom executable harness, not XCTest)
make test

# Build unsigned .app bundle
make app

# Build signed + notarized DMG for distribution
make release
```

> **Note:** Tests use a custom executable harness (`NotionBridgeTests/main.swift`), not XCTest. Run via `make test` or `swift run NotionBridgeTests`.

---

## Makefile Targets

| Target | Description |
|--------|-------------|
| `make debug` | Debug build |
| `make build` | Release build with strict concurrency |
| `make test` | Run test suite via custom harness |
| `make app` | Package unsigned .app bundle |
| `make dmg` | Create DMG from app bundle |
| `make sign` | Code sign with Developer ID |
| `make notarize` | Submit for Apple notarization |
| `make verify` | Verify notarization and signing |
| `make release` | Full pipeline: clean → test → app → dmg → sign → notarize → verify |
| `make install` | Install to /Applications |
| `make clean` | Remove build artifacts |
| `make clean-tcc` | Reset TCC permissions for bundle ID `kup.solutions.notion-bridge` |

---

## Project Structure

```
keepr-bridge/
├── Package.swift                    # SPM manifest (swift-tools-version 6.2)
├── Package.resolved                 # Dependency lock file
├── Makefile                         # Build, test, sign, notarize, release
├── Info.plist                       # App bundle metadata
├── NotionBridge.entitlements        # App sandbox entitlements
├── README.md                        # This file
├── AGENTS.md                        # AI agent coding guidelines
├── appicon_master_1024.png          # App icon source
├── menubar_master_54.png            # Menu bar icon (1x)
├── menubar_master_hires.png         # Menu bar icon (hi-res)
├── patches/                         # Patch files
├── .github/                         # GitHub config
├── .cursor/                         # Cursor IDE config
│
├── NotionBridge/                    # Main source
│   ├── App/                         # Application lifecycle
│   │   ├── NotionBridgeApp.swift    # Entry point (@main)
│   │   ├── AppDelegate.swift        # NSApplicationDelegate
│   │   ├── StatusBarController.swift # Menu bar icon + menu
│   │   └── WindowTracker.swift      # Window lifecycle management
│   │
│   ├── Config/                      # Configuration
│   │   ├── ConfigManager.swift      # JSON-backed config (sensitive paths, learned allows)
│   │   ├── ConnectionHealthChecker.swift # Notion connection health monitoring
│   │   └── Version.swift            # Single source of truth for app versioning
│   │
│   ├── Modules/                     # Tool modules (12 active + 1 infrastructure)
│   │   ├── AccessibilityModule.swift
│   │   ├── AppleScriptModule.swift
│   │   ├── ChromeModule.swift
│   │   ├── CredentialModule.swift   # Internal credential infrastructure (no MCP tools)
│   │   ├── FileModule.swift
│   │   ├── MessagesModule.swift
│   │   ├── NotionModule.swift
│   │   ├── ScreenModule.swift       # Screenshots + OCR
│   │   ├── ScreenRecording.swift    # Screen recording (SCStream + AVAssetWriter)
│   │   ├── SessionModule.swift
│   │   ├── ShellModule.swift
│   │   ├── SkillsManager.swift      # Skills caching and lookup helper
│   │   ├── SkillsModule.swift
│   │   └── SystemModule.swift
│   │
│   ├── Notion/                      # Notion API client
│   │   ├── NotionClient.swift       # API wrapper (multi-workspace)
│   │   ├── NotionClientRegistry.swift # Connection registry
│   │   └── NotionModels.swift       # API data models
│   │
│   ├── Security/                    # Security subsystem
│   │   ├── SecurityGate.swift       # 3-tier enforcement engine
│   │   ├── AuditLog.swift           # Tool call audit logging
│   │   ├── CredentialManager.swift  # Credential storage and retrieval
│   │   ├── KeychainManager.swift    # macOS Keychain integration
│   │   ├── LogManager.swift         # Application logging
│   │   └── PermissionManager.swift  # Permission grants and checks
│   │
│   ├── Server/                      # MCP server infrastructure
│   │   ├── SSETransport.swift       # NIO-based SSE transport on :9700
│   │   ├── ServerManager.swift      # Server lifecycle management
│   │   └── ToolRouter.swift         # Tool dispatch and module registration
│   │
│   └── UI/                          # SwiftUI + AppKit views
│       ├── BridgeTheme.swift        # Shared theme constants
│       ├── ConnectionSetupView.swift # New connection wizard
│       ├── ConnectionsManagementView.swift # Connection list management
│       ├── CredentialsView.swift    # Credential management UI
│       ├── DashboardView.swift      # Main dashboard
│       ├── OnboardingWindow.swift   # First-launch onboarding
│       ├── PermissionView.swift     # Permission management UI
│       ├── SettingsWindow.swift     # Settings window
│       ├── SettingsWindow+Components.swift # Settings UI components
│       ├── SettingsWindow+Sections.swift   # Settings sections
│       ├── SkillsView.swift         # Skills configuration UI
│       └── ToolRegistryView.swift   # Live tool registry inspector
│
└── NotionBridgeTests/               # Test suite (custom harness)
    ├── main.swift                   # Test runner entry point
    ├── IntegrationTests/            # Integration test suite
    ├── AccessibilityModuleTests.swift
    ├── AppleScriptModuleTests.swift
    ├── BuiltinModuleTests.swift
    ├── ChromeModuleTests.swift
    ├── ConfigManagerTests.swift
    ├── CredentialManagerTests.swift
    ├── CredentialModuleTests.swift
    ├── FileModuleTests.swift
    ├── MessagesModuleTests.swift
    ├── NotionModuleTests.swift
    ├── PermissionManagerTests.swift
    ├── ScreenModuleTests.swift
    ├── SessionModuleTests.swift
    ├── ShellModuleTests.swift
    ├── SkillsModuleTests.swift
    └── SystemModuleTests.swift
```

### Package.swift Targets

| Target | Type | Description |
|--------|------|-------------|
| `NotionBridgeLib` | library | Shared library containing all modules, security, server, and Notion client code |
| `NotionBridge` | executable | App entry point (`NotionBridgeApp.swift`) — depends on `NotionBridgeLib` |
| `NotionBridgeTests` | executable | Custom test harness — depends on `NotionBridgeLib` |

---

## Dependencies

| Package | Version | Usage |
|---------|---------|-------|
| [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) | ≥ 0.11.0 | Model Context Protocol types, tool definitions, transport abstractions |
| [swift-nio](https://github.com/apple/swift-nio) | ≥ 2.65.0 | NIOCore, NIOPosix, NIOHTTP1 for SSE transport |

---

## Configuration

Notion Bridge stores configuration in `config.json` (managed by `ConfigManager`).

### Sensitive Paths

Sensitive paths are directories that trigger a SecurityGate approval prompt when accessed. Defaults are seeded on first launch and can be modified via config.

### Learned Allow Prefixes

When a user chooses "Always Allow" on a Request-tier approval, the command prefix is stored and used for automatic approval of future matching commands.

### Connections

Multi-workspace Notion connections are managed through the Settings UI. Each connection stores its API token in the macOS Keychain via `KeychainManager`.

---

## License

Private. All rights reserved.
