# NotionBridge

**macOS-native MCP server for Notion AI agents.**

> Local tool execution with 3-tier security · 58 tools across 12 modules · Swift 6 + Vapor

[![Version](https://img.shields.io/badge/version-1.1.5_build_3-blue)]()
[![Platform](https://img.shields.io/badge/platform-macOS_14%2B-lightgrey)]()
[![Swift](https://img.shields.io/badge/Swift-6.0-orange)]()
[![License](https://img.shields.io/badge/license-Proprietary-red)]()

---

## Overview

NotionBridge is a **Model Context Protocol (MCP) server** that runs locally on macOS, giving Notion AI agents direct access to your machine — files, shell, screen, messages, accessibility, Chrome automation, and more. It bridges the gap between cloud-based AI and local system capabilities through a secure, tiered permission model.

### Key Features

- **58 tools** organized into 12 purpose-built modules
- **3-tier SecurityGate** (open → notify → request) with pattern-based auto-escalation
- **Server-Sent Events (SSE)** transport for real-time streaming
- **Notion Skills** system for dynamic prompt/instruction loading
- **Screen capture & recording** via ScreenCaptureKit
- **Chrome DevTools** automation (tabs, navigation, JS execution, screenshots)
- **iMessage/SMS** read access via native SQLite
- **Accessibility tree** inspection and UI automation
- **Full Notion API** integration (16 tools for pages, blocks, comments, files)

---

## Requirements

- macOS 14.0 (Sonoma) or later
- Swift 6.0+
- Xcode 16+
- Notion workspace with MCP server integration

### Permissions Required

| Permission | Purpose |
|---|---|
| Full Disk Access | File operations, Messages database |
| Screen Recording | Screen capture, OCR, recording |
| Accessibility | AX tree inspection, UI automation |
| Automation (Chrome) | Chrome tab control, JS execution |

---

## Installation

### Build from Source

```bash
git clone <repo-url>
cd keepr-bridge
swift build -c release
```

### Install via Makefile

```bash
make install    # Build, sign, and install to /Applications
make uninstall  # Remove from /Applications and LaunchAgent
```

### TCC Permissions

```bash
make clean-tcc  # Reset TCC permissions (uses both current and legacy bundle IDs)
```

---

## Architecture

```
┌─────────────────────────────────────┐
│          Notion AI Agent            │
│         (Cloud / Workspace)         │
└──────────────┬──────────────────────┘
               │ SSE (HTTP)
┌──────────────▼──────────────────────┐
│         NotionBridge Server         │
│  ┌───────────┐  ┌────────────────┐  │
│  │  Vapor    │  │  SecurityGate  │  │
│  │  Router   │──│  (3-tier)      │  │
│  └───────────┘  └────────────────┘  │
│  ┌──────────────────────────────┐   │
│  │     12 Tool Modules (58)     │   │
│  └──────────────────────────────┘   │
└──────────────┬──────────────────────┘
               │ Native APIs
┌──────────────▼──────────────────────┐
│            macOS System             │
│  Files · Shell · Screen · AX · ... │
└─────────────────────────────────────┘
```

---

## Modules & Tools

NotionBridge provides **58 tools** across **12 modules**:

| Module | Tools | Tier | Description |
|---|---|---|---|
| **FileModule** | 12 | open | File CRUD, search, copy, move, metadata |
| **ShellModule** | 2 | open | Shell execution with timeout, working directory |
| **NotionModule** | 16 | open/notify | Full Notion API — pages, blocks, comments, files |
| **MessagesModule** | 6 | open | iMessage/SMS read access via chat.db |
| **ChromeModule** | 5 | open | Tab management, navigation, JS execution, screenshots |
| **AccessibilityModule** | 5 | open | AX tree traversal, element inspection, actions |
| **ScreenModule** | 4 | open | Screenshot, OCR, screen recording start/stop |
| **SystemModule** | 3 | open | System info, process list, clipboard |
| **SessionModule** | 3 | open | Session info, clear, notify |
| **AppleScriptModule** | 1 | open | Execute arbitrary AppleScript |
| **SkillsModule** | 1 | open | Fetch named Notion skill pages |
| **BuiltinModule** | 1 | open | Echo (connectivity test) |

### NotionModule (16 tools)

The Notion module provides comprehensive API coverage:

**Open tier (read-only):**

| Tool | Description |
|---|---|
| `notion_search` | Search workspace for pages and databases |
| `notion_query` | Query a data source with optional filter/sort |
| `notion_page_read` | Read page properties and child blocks |
| `notion_page_markdown_read` | Read page content as markdown |
| `notion_users_list` | List all workspace users |
| `notion_comments_list` | List comments on a page or block |
| `notion_token_introspect` | Introspect current API token |
| `notion_connections_list` | List configured workspace connections |

**Notify tier (write operations):**

| Tool | Description |
|---|---|
| `notion_page_create` | Create a new page under a parent |
| `notion_page_update` | Update page properties |
| `notion_page_move` | Move page to a new parent |
| `notion_page_markdown_write` | Replace page body from markdown |
| `notion_blocks_append` | Append child blocks to a page/block |
| `notion_block_delete` | Delete (trash) a block |
| `notion_comment_create` | Create a comment on a page |
| `notion_file_upload` | Upload a local file to Notion |

### ChromeModule (5 tools)

| Tool | Description |
|---|---|
| `chrome_tabs` | List all open tabs across windows |
| `chrome_navigate` | Navigate a tab to a URL or open new tab |
| `chrome_read_page` | Extract page content (text or HTML) |
| `chrome_execute_js` | Execute JavaScript in a tab |
| `chrome_screenshot_tab` | Capture visible tab content as PNG |

### FileModule (12 tools)

| Tool | Description |
|---|---|
| `file_read` | Read text content from a file |
| `file_write` | Write text content to a file |
| `file_append` | Append content to an existing file |
| `file_copy` | Copy a file or directory |
| `file_move` | Move a file or directory |
| `file_rename` | Rename a file or directory |
| `file_list` | List directory contents |
| `file_search` | Search for files by name |
| `file_metadata` | Get file/directory metadata |
| `dir_create` | Create a directory with intermediates |
| `clipboard_read` | Read from system clipboard |
| `clipboard_write` | Write to system clipboard |

---

## Security Model

NotionBridge enforces a **3-tier SecurityGate** that governs every tool invocation:

### Tiers

| Tier | Color | Behavior |
|---|---|---|
| **`.open`** | 🟢 Green | Execute immediately, no confirmation |
| **`.notify`** | 🟡 Orange | Execute immediately, send macOS notification |
| **`.request`** | 🔴 Red | Block until user approves via dialog |

### Auto-Escalation

Certain input patterns automatically escalate a tool's tier regardless of its default:

- **Destructive shell patterns** — `rm -rf /`, recursive force-deletes targeting system paths
- **Fork-bomb patterns** — self-replicating shell constructs (e.g. bash function bombs) that exhaust system resources
- **Privilege escalation** — commands attempting to gain root access
- **Forbidden path access** — operations targeting `/System`, `/usr`, or other protected directories

When auto-escalation triggers, the tool is promoted to `.request` (red tier) and requires explicit user approval before execution.

### Notification Behavior

- **Green tier:** Silent execution, logged to audit trail
- **Orange tier:** macOS notification via `UNUserNotificationCenter` with tool name and summary
- **Red tier:** Modal dialog blocks execution until the user clicks Allow or Deny

---

## Configuration

### Environment Variables

| Variable | Required | Description |
|---|---|---|
| `NOTION_API_TOKEN` | Yes | Notion internal integration token |
| `NOTIONBRIDGE_PORT` | No | Server port (default: 1989) |

### Skills System

NotionBridge supports a **Skills** system for dynamic prompt loading. Skills are Notion pages configured in Settings → Skills. The `fetch_skill` tool retrieves skill content by name, enabling agents to load context-specific instructions at runtime.

---

## MCP Transport

NotionBridge uses **Server-Sent Events (SSE)** as its MCP transport layer:

- **Endpoint:** `http://localhost:1989/sse`
- **Messages endpoint:** `http://localhost:1989/messages`
- **Protocol:** MCP 2024-11-05
- **Streaming:** Real-time tool results via SSE

---

## Project Structure

```
keepr-bridge/
├── NotionBridge/
│   ├── Config/
│   │   ├── AppConstants.swift
│   │   ├── Version.swift
│   │   └── FeatureFlags.swift
│   ├── Core/
│   │   ├── NotionBridgeApp.swift
│   │   ├── AppDelegate.swift
│   │   ├── ServerManager.swift
│   │   ├── ToolRouter.swift
│   │   └── MCPProtocol.swift
│   ├── Security/
│   │   ├── SecurityGate.swift
│   │   ├── SecurityPatterns.swift
│   │   └── AuditLog.swift
│   ├── Modules/
│   │   ├── ShellModule.swift
│   │   ├── FileModule.swift
│   │   ├── MessagesModule.swift
│   │   ├── SystemModule.swift
│   │   ├── NotionModule.swift
│   │   ├── SessionModule.swift
│   │   ├── ScreenModule.swift
│   │   ├── AccessibilityModule.swift
│   │   ├── AppleScriptModule.swift
│   │   ├── ChromeModule.swift
│   │   ├── SkillsModule.swift
│   │   └── BuiltinModule.swift
│   ├── Notion/
│   │   ├── NotionClient.swift
│   │   ├── NotionModels.swift
│   │   └── NotionFileUploader.swift
│   ├── Skills/
│   │   ├── SkillsManager.swift
│   │   └── SkillsConfig.swift
│   ├── Helpers/
│   │   ├── ProcessRunner.swift
│   │   ├── ChromeHelper.swift
│   │   ├── MessageDBReader.swift
│   │   └── ScreenRecorder.swift
│   └── Resources/
│       └── Assets.xcassets/
├── AGENTS.md
├── README.md
├── Package.swift
├── Makefile
├── .gitignore
└── NotionBridge.xcodeproj/
```

---

## Dependencies

| Package | Purpose |
|---|---|
| [Vapor](https://github.com/vapor/vapor) | HTTP server framework |
| [swift-nio](https://github.com/apple/swift-nio) | Async networking (Vapor dependency) |

System frameworks: Foundation, AppKit, ScreenCaptureKit, Vision, SQLite3, UniformTypeIdentifiers

---

## Development

### Build & Run

```bash
swift build              # Debug build
swift build -c release   # Release build
make install             # Full install to /Applications
```

### Debug

```bash
# Check if server is running
curl http://localhost:1989/sse

# Test connectivity
curl -X POST http://localhost:1989/messages \
  -H "Content-Type: application/json" \
  -d '{"method":"tools/call","params":{"name":"echo","arguments":{"message":"hello"}}}'
```

---

## License

Proprietary. All rights reserved.

