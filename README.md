# 🌉 Notion Bridge

**A native macOS menu bar app that replaces the Python + ngrok MCP server, serving as the persistent bidirectional bridge between Notion agents and the local Mac.**

Version 1.1.4 · macOS 26+ · Apple Silicon · Swift 6.2

---

## Overview

Notion Bridge is a native SwiftUI menu bar app that exposes 40 tools across 10 modules over MCP (Model Context Protocol) transports. It replaces the previous Python + ngrok bridge with a single binary that auto-launches on login, routes every tool call through a 2-tier security gate, and logs every action to an append-only audit trail.

### Architecture

```text
Remote Agent (Notion)  ──SSE :9700──►  ┌──────────────────────┐
                                       │   NotionBridge.app          │
Local Client (Claude)  ──stdio──────►  │                      │
                                       │   Transport Layer    │
                                       │      ↓               │
                                       │   Tool Router        │
                                       │      ↓               │
                                       │   Security Gate      │
                                       │      ↓               │
                                       │   Module Handler     │
                                       │      ↓               │
                                       │   Audit Log          │
                                       └──────────────────────┘
                                              ↓
                                       macOS APIs / Notion REST
```

**Data flow:** All requests route through Transport → Tool Router → Security Gate → Module Handler → Audit Log → Response. The router is transport-agnostic — modules never know which transport delivered the request.

---

## Prerequisites

| Requirement | Version | Notes |
|-------------|---------|-------|
| **macOS** | 26.0+ (Tahoe) | Required for current UI/runtime target |
| **Xcode** | 26.0+ | Swift 6.2 toolchain |
| **Swift** | 6.2+ | Strict concurrency enforced |
| **Hardware** | Apple Silicon (M1+) | ARM64 only |
| **Git** | 2.39+ | Trunk-based development |

### TCC Permissions Required

Notion Bridge requires the following macOS permissions (granted interactively at first launch):

| Permission | Purpose | Tools Affected |
|-----------|---------|----------------|
| **Full Disk Access** | Messages chat.db, file operations | FileModule, MessagesModule |
| **Accessibility** | AXUIElement tree inspection | AccessibilityModule |
| **Automation** | AppleScript → Messages, Shortcuts | MessagesModule (send) |
| **Screen Recording** | Screen capture, OCR | ScreenModule |
| **Contacts** | Contact search | Deferred: contacts_search |

---

## Quick Start

### Build

```bash
# Clone and build
git clone https://github.com/KUP-IP/notion-bridge.git
cd notion-bridge
swift build

# Build release binary
swift build -c release -Xswiftc -strict-concurrency=complete
```

### Run

```bash
# Start MCP server (stdio transport)
swift run NotionBridge

# Run tests
swift run NotionBridgeTests

# Or use Make targets
make build
make test
```

### Connect from Claude Code / Cursor

Add to your MCP client configuration:

```json
{
  "mcpServers": {
    "notion-bridge": {
      "command": "/path/to/notion-bridge/.build/release/NotionBridge",
      "args": []
    }
  }
}
```

---

## Tool Reference

### Current Surface: 40 tools across 10 modules

#### ShellModule (2 tools)

| Tool | Tier | Description |
|------|------|-------------|
| `shell_exec` | 🟠 Write-Confirm | Execute a shell command with timeout and working directory |
| `run_script` | 🟢 Read-Only | Execute a pre-approved script from ~/.mcp_scripts |

#### FileModule (12 tools)

| Tool | Tier | Description |
|------|------|-------------|
| `file_list` | 🟢 Read-Only | List directory contents (recursive, hidden files) |
| `file_search` | 🟢 Read-Only | Search for files by name pattern |
| `file_metadata` | 🟢 Read-Only | Get file/directory metadata (size, dates, type) |
| `file_read` | 🟢 Read-Only | Read file contents with encoding support |
| `file_write` | 🟠 Write-Confirm | Write text to file with optional parent dir creation |
| `file_append` | 🟠 Write-Confirm | Append text to existing file |
| `file_move` | 🟠 Write-Confirm | Move file or directory |
| `file_rename` | 🟠 Write-Confirm | Rename file or directory in place |
| `file_copy` | 🟡 Write-Auto | Copy file or directory |
| `dir_create` | 🟠 Write-Confirm | Create directory with intermediates |
| `clipboard_read` | 🟢 Read-Only | Read system clipboard |
| `clipboard_write` | 🟡 Write-Auto | Write to system clipboard |

#### MessagesModule (6 tools)

| Tool | Tier | Description |
|------|------|-------------|
| `messages_search` | 🟢 Read-Only | Search messages by keyword |
| `messages_recent` | 🟢 Read-Only | List recent conversations |
| `messages_chat` | 🟢 Read-Only | Get message thread with contact |
| `messages_content` | 🟢 Read-Only | Get single message with metadata |
| `messages_participants` | 🟢 Read-Only | List chat participants |
| `messages_send` | 🔴 Destructive | Send iMessage/SMS (requires confirm='SEND') |

#### SystemModule (3 tools)

| Tool | Tier | Description |
|------|------|-------------|
| `system_info` | 🟢 Read-Only | OS, CPU, memory, disk, battery, uptime |
| `process_list` | 🟢 Read-Only | Running processes sorted by CPU/memory |
| `notify` | 🟡 Write-Auto | Send macOS notification |

#### NotionModule (3 tools)

| Tool | Tier | Description |
|------|------|-------------|
| `notion_search` | 🟢 Read-Only | Search Notion workspace pages/databases |
| `notion_page_read` | 🟢 Read-Only | Read Notion page properties and content |
| `notion_page_update` | 🟠 Write-Confirm | Update Notion page properties |

#### SessionModule (3 tools)

| Tool | Tier | Description |
|------|------|-------------|
| `tools_list` | 🟢 Read-Only | Runtime tool registry (all tools with metadata) |
| `session_info` | 🟢 Read-Only | Uptime, connections, tool call count |
| `session_clear` | 🟠 Write-Confirm | Clear session state (requires confirm) |

#### ScreenModule (4 tools)

| Tool | Tier | Description |
|------|------|-------------|
| `screen_capture` | 🟢 Read-Only | Capture display/window/region screenshots |
| `screen_ocr` | 🟢 Read-Only | OCR text extraction from captured screen |
| `screen_record_start` | 🟠 Write-Confirm | Start screen recording session |
| `screen_record_stop` | 🟠 Write-Confirm | Stop recording and finalize output |

#### AccessibilityModule (5 tools)

| Tool | Tier | Description |
|------|------|-------------|
| `ax_focused_app` | 🟢 Read-Only | Inspect focused app and focused element |
| `ax_tree` | 🟢 Read-Only | Dump accessibility element tree |
| `ax_find_element` | 🟢 Read-Only | Find AX elements by role/title/label |
| `ax_element_info` | 🟢 Read-Only | Inspect attributes/actions for one AX element |
| `ax_perform_action` | 🟠 Write-Confirm | Execute AX actions (press/focus/setValue/etc.) |

#### AppleScriptModule (1 tool)

| Tool | Tier | Description |
|------|------|-------------|
| `applescript_exec` | 🟠 Write-Confirm | Execute AppleScript in-process (stable TCC behavior) |

#### BuiltinModule (1 tool)

| Tool | Tier | Description |
|------|------|-------------|
| `echo` | 🟢 Read-Only | Echo input for connectivity testing |

---

## Security Model

### 2-Tier Security Gate

Every tool call passes through the Security Gate before execution. No exceptions.

| Tier | Name | Behavior |
|------|------|----------|
| 🟢 | **open** | Execute immediately after policy checks. |
| 🟠 | **notify** | Requires approval flow unless trusted mode is enabled. |

### Auto-Escalation Patterns

Commands containing these patterns are escalated to manual handoff:

- `rm` (file deletion)
- `kill` (process termination)
- `chmod 777` (open permissions)
- Pipe to `sh` / `bash` / `eval` (arbitrary execution)

**`sudo` is hard blocked** — always rejected, never executed, regardless of tier.

### Forbidden Paths

These paths are blocked across all tiers:

- `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.config/gcloud`
- `.env` files containing secrets
- `/System`, `/Library` (write operations)
- Application bundles in `/Applications`

### Batch Gate

If a single request triggers **3 or more tool calls**, the router presents the full execution plan before starting.

### Audit Log

Every tool call is recorded with:

- Timestamp, tool name, security tier
- Input summary, output summary
- Duration (milliseconds)
- Approval status (approved / rejected / escalated / error)

---

## Transport Configuration

### stdio (default)

Used by local clients (Claude Code, Cursor). The server reads JSON-RPC from stdin and writes responses to stdout.

```bash
swift run NotionBridge
```

### SSE / HTTP (:9700)

Used by remote agents (Notion). Server-Sent Events on port 9700.

Native SSE is implemented in Swift and supports both:

- Streamable HTTP on `POST /mcp` (session-aware MCP transport)
- Legacy SSE compatibility (`GET /sse` + `POST /messages`)
- Health endpoint: `GET /health`

---

## Project Structure

```text
notion-bridge/
├── NotionBridge/
│   ├── App/                    # SwiftUI app, lifecycle, menu bar
│   │   ├── NotionBridgeApp.swift
│   │   ├── AppDelegate.swift
│   │   ├── StatusBarController.swift
│   │   └── Resources/
│   │       ├── Assets.xcassets
│   │       ├── NotionBridge.icns
│   │       └── *.png (icon assets)
│   ├── Modules/                # 10 tool modules (40 tools)
│   │   ├── ShellModule.swift       # 2 tools
│   │   ├── FileModule.swift        # 12 tools
│   │   ├── MessagesModule.swift    # 6 tools
│   │   ├── SystemModule.swift      # 3 tools (partial)
│   │   ├── NotionModule.swift      # 3 tools (narrow)
│   │   ├── SessionModule.swift     # 3 tools
│   │   ├── AppleScriptModule.swift # 1 tool
│   │   ├── AccessibilityModule.swift # 5 tools
│   │   ├── ScreenModule.swift      # 4 tools
│   │   └── ScreenRecording.swift   # ScreenCaptureKit helper
│   ├── Security/               # Gate, audit, permissions
│   │   ├── SecurityGate.swift
│   │   ├── AuditLog.swift
│   │   ├── PermissionManager.swift
│   │   └── LogManager.swift
│   ├── Server/                 # MCP server + transports
│   │   ├── SSETransport.swift      # Legacy SSE + Streamable HTTP on :9700
│   │   ├── ToolRouter.swift        # Dispatch + security gating
│   │   └── ServerManager.swift     # Server lifecycle + multi-client
│   ├── Notion/                 # REST API client
│   │   ├── NotionClient.swift
│   │   └── NotionModels.swift
│   └── UI/                     # Dashboard + settings views
│       ├── DashboardView.swift
│       ├── PermissionView.swift
│       ├── SettingsWindow.swift
│       ├── ConnectionSetupView.swift
│       ├── OnboardingWindow.swift
│       ├── BridgeTheme.swift
│       └── ToolRegistryView.swift
├── NotionBridgeTests/
│   ├── main.swift              # Test runner (unit + integration)
│   ├── ShellModuleTests.swift
│   ├── FileModuleTests.swift
│   ├── MessagesModuleTests.swift
│   ├── SystemModuleTests.swift
│   ├── NotionModuleTests.swift
│   ├── SessionModuleTests.swift
│   ├── PermissionManagerTests.swift
│   └── IntegrationTests/
│       └── EndToEndTests.swift
├── Package.swift               # SPM (swift-tools-version 6.2, macOS 26)
├── Makefile                    # build, test, sign, notarize, dmg
├── README.md
└── .github/workflows/ci.yml   # GitHub Actions pipeline
```

---

## Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) | 0.11.0 | MCP protocol, stdio transport |

All other functionality uses Apple frameworks only (Foundation, AppKit, SwiftUI, ServiceManagement).

---

## Troubleshooting

### Cleaning Stale TCC Entries

If you previously ran the app under the old bundle ID (`solutions.kup.keepr`, from the Keepr era) or need to reset all TCC permission grants for a fresh start, use the `clean-tcc` make target:

```bash
make clean-tcc
```

This resets TCC entries for **both** the legacy bundle ID (`solutions.kup.keepr`) and the current bundle ID (`kup.solutions.notion-bridge`). After running this command, all permissions will be re-requested on the next app launch.

**When to use:**

- After migrating from Keepr to Notion Bridge — stale TCC entries under the old bundle ID can cause macOS to silently deny permissions
- After code signing identity changes that invalidate existing TCC grants
- When permission indicators in Settings → Permissions show red despite granting access in System Settings
- During development after frequent rebuilds that change the code signature

**What it does:**

```bash
tccutil reset All solutions.kup.keepr       # Legacy Keepr bundle ID
tccutil reset All kup.solutions.notion-bridge  # Current Notion Bridge bundle ID
```

> **Note:** `tccutil reset All` removes all TCC grants for the specified bundle ID. The app will prompt for each permission again on next launch. This is safe — no data is lost, only permission state is cleared.

### `make install` vs `make clean-tcc`

- **`make install`** — Builds the release `.app`, copies it to `/Applications/Notion Bridge.app`, then runs the same two `tccutil reset All` commands as `clean-tcc` (legacy `solutions.kup.keepr` and current `kup.solutions.notion-bridge`). Use this after a fresh build when you want the installed app and a clean TCC slate in one step.
- **`make clean-tcc`** — Resets TCC only; does not build or install. Use when permissions feel stale but you are not reinstalling.

If `tccutil` prints **No such bundle identifier** for the legacy ID (`-10814`), that is expected when Keepr was never installed; the line is ignored and the reset for the current ID still runs.

### Permissions feel tied to the wrong app

1. **Quit** every running instance (menu bar and any CLI `NotionBridge` you started from Terminal).
2. Confirm identity: in the app, open **Settings** and check **Bundle ID** and bundle path — it should be `kup.solutions.notion-bridge` and your intended `.app` location.
3. **Prefer one launch path** for normal use: `/Applications/Notion Bridge.app`. Running the raw `.build/release/NotionBridge` binary is a different executable path; macOS can treat TCC grants separately from the bundled app.
4. Run **`make clean-tcc`** or **`make install`**, then reopen only the `/Applications` app and re-grant in **System Settings** (Accessibility, Full Disk Access, Automation per target app, Screen Recording, Notifications as needed).

---

## Known Limitations

### Current Scope Boundaries

- Confirmation handling uses notification/alert flow and trusted-mode policy; no advanced multi-step approval UI yet
- Notion API token must be present via env (`NOTION_API_TOKEN`) or config file

### Deferred Tools (remain on Python bridge)

| Tool | Reason |
|------|--------|
| `log_parse` (was `interpret_logs`) | Requires Ollama/Llama integration — lower priority |
| `contacts_search` | Requires CNContactStore framework — higher complexity |
| `run_shortcut` | Requires Shortcuts framework integration |

### Expansion Modules (post-v1)

- **BrowserModule** (7 tools) — WKWebView automation
- Remaining NotionModule (4 additional tools: `notion_page_create`, `notion_db_query`, `notion_block_append`, `notion_comment_add`)
- Remaining SystemModule (3 additional tools: `log_parse`, `contacts_search`, `run_shortcut`)

---

## Development

### Running Tests

```bash
# All tests (unit + integration + E2E)
make test

# Or directly
swift run NotionBridgeTests
```

### Test Suites

| Suite | File | Coverage |
|-------|------|----------|
| SecurityGate | `main.swift` | 2-tier model, nuclear handoff, sensitive paths, session/permanent permissions |
| ToolRouter | `main.swift` | Registration, dispatch, overwrite, module filter |
| AuditLog | `main.swift` | Append, filter by tool/tier/status, Codable round-trip |
| PermissionManager | `PermissionManagerTests.swift` | Grant enum, TCC checks, async notifications, evidence loop |
| ShellModule | `ShellModuleTests.swift` | Tool registration, security tiers |
| FileModule | `FileModuleTests.swift` | Tool registration, security tiers |
| SessionModule | `SessionModuleTests.swift` | Tool registration, security tiers |
| MessagesModule | `MessagesModuleTests.swift` | Tool registration, security tiers |
| SystemModule | `SystemModuleTests.swift` | Tool registration, security tiers |
| NotionModule | `NotionModuleTests.swift` | 16 tools, security tiers, model validation |
| AccessibilityModule | `AccessibilityModuleTests.swift` | Tool registration, security tiers |
| ScreenModule | `ScreenModuleTests.swift` | Tool registration, security tiers |
| AppleScriptModule | `AppleScriptModuleTests.swift` | Tool registration, security tiers |
| ChromeModule | `ChromeModuleTests.swift` | Tool registration, tiers, schemas |
| SkillsModule | `SkillsModuleTests.swift` | Tool registration, tier, schema |
| BuiltinModule | `BuiltinModuleTests.swift` | Tool registration, security tiers |
| ConfigManager | `ConfigManagerTests.swift` | Singleton, config read/write, accessors |
| Integration/E2E | `IntegrationTests/` | End-to-end tool dispatch flows |

> **Note:** Tests use a custom harness (`swift run NotionBridgeTests`), not XCTest.
> The `checkNotifications()` async test is skipped in CLI context (no app bundle).

### Release Pipeline

```bash
# Full pipeline: build → test → sign → notarize → DMG
make release

# Individual steps
make build       # Release build with strict concurrency
make sign        # Developer ID code signing
make notarize    # Apple notarization submission
make dmg         # Create distributable DMG
make verify      # Gatekeeper assessment
```

### Maintenance

```bash
make install     # Build .app, install to /Applications, reset TCC (legacy + current bundle IDs)
make clean-tcc   # Reset TCC only (same two bundle IDs as install)
make clean       # Remove build artifacts
```

### CI/CD

GitHub Actions runs on push to `main` and pull requests:

- **Build** with strict concurrency
- **Test** full suite (unit + integration)
- **Sign** (conditional on certificate availability)
- **Notarize** (conditional on credentials)
- **Artifact** DMG uploaded

---

## License

Copyright © 2026 KUP Solutions. All rights reserved.
