# NotionBridge

**A native macOS menu-bar app that turns your Mac into an MCP server for Notion AI agents and local coding clients.**

NotionBridge exposes local Mac capabilities and connected services as MCP tools over **Streamable HTTP**, **legacy SSE**, and **stdio**. It is built in Swift 6.2 for macOS 26+ on Apple Silicon and is designed to be always-on, auto-launched, and safe enough for daily operator use.

**73+N tools** (72 module tools + `echo` + **N** Stripe MCP tools when discovery succeeds) · **3 transports** · **3-tier security model** · **Customer-owned Cloudflare Tunnel support**

**Product page:** https://kup.solutions/notion-bridge

---

## What this repo is

This is the product repository for **NotionBridge**.

It is not a generic Swift experiment and it is not an open-source demo server. It is the source-available codebase for a commercial macOS product that bridges Notion agents, local coding tools, and the user's Mac.

Current commercial posture:
- Direct purchase is the primary distribution path.
- No free tier is planned.
- Setapp distribution may follow later.

---

## Current product surface

NotionBridge currently ships the following module surface:

| Module | Tools | Notes |
|---|---:|---|
| ShellModule | 2 | shell execution and approved scripts |
| FileModule | 12 | files, directories, metadata, clipboard |
| MessagesModule | 6 | iMessage and SMS read/send tooling |
| SystemModule | 4 | system info, processes, notifications, contacts |
| NotionModule | 16 | Notion pages, blocks, comments, files, queries |
| SessionModule | 3 | session status and tool registry introspection |
| AppleScriptModule | 1 | in-process AppleScript execution |
| AccessibilityModule | 5 | AX tree, inspection, and actions |
| ScreenModule | 5 | capture, OCR, recording, screen analysis |
| ChromeModule | 5 | tabs, navigation, page reads, JS, screenshots |
| CredentialModule | 4 | Keychain-backed credential storage |
| PaymentModule | 1 | Stripe payment execution |
| SkillsModule | 3 | `fetch_skill`, `list_routing_skills`, `manage_skill` |
| ConnectionsModule | 5 | connection inventory, health, validation |
| BuiltinModule | 1 | `echo` (registered in `ServerManager`, not a Swift `*Module` type) |
| **Total** | **73+N** | 72 from feature modules + 1 builtin `echo` + **N** dynamic Stripe MCP tools (0 if not configured) |

Core product traits:
- Native macOS menu-bar app with onboarding, settings, and a status popover
- Auto-launch via `SMAppService`
- Streamable HTTP and legacy SSE on the same local server surface
- stdio support for local clients such as Claude Code and Cursor
- Local-first security gate with audit logging
- Optional remote access through a customer-owned Cloudflare Tunnel

---

## Installation

### Option 1: Download a release

1. Download the latest DMG from [GitHub Releases](https://github.com/KUP-IP/Notion-bridge/releases).
2. Open the DMG.
3. Drag `NotionBridge.app` into `/Applications`.
4. Launch the app and complete onboarding.

### Option 2: Build from source

```bash
git clone https://github.com/KUP-IP/Notion-bridge.git
cd Notion-bridge
make app
```

The app bundle is written to `.build/NotionBridge.app`.

> **Install naming:** The Swift target is `NotionBridge` (no space), so build output and DMG contents use `NotionBridge.app`. The Finder display name is **Notion Bridge** (with space), set by `CFBundleName` / `CFBundleDisplayName` in `Info.plist`. `make install` places the app at `/Applications/Notion Bridge.app` to match the display name. Both names refer to the same product.

---

## Requirements

| Requirement | Version | Notes |
|---|---|---|
| macOS | 26.0+ | Tahoe or later |
| Hardware | Apple Silicon | ARM64 only |
| Xcode | 26.0+ | Needed for building from source |
| Swift | 6.2+ | Defined by `Package.swift` |
| Git | 2.39+ | For cloning and release workflows |

---

## Configuration

Primary configuration path:

```text
~/.config/notion-bridge/config.json
```

NotionBridge supports:
- Notion workspace connections
- connection health checks
- customer-owned remote-access configuration
- local security preferences

If you are using Notion tools, add a valid Notion integration token through the app's connection flow or config file.

---

## Transport surface

### Streamable HTTP

```text
POST http://127.0.0.1:9700/mcp
```

This is the primary HTTP MCP endpoint. The listener is bound to **loopback** only. For remote agents (e.g. cloud IDEs) that reach your Mac through an **HTTPS tunnel** to that port, set **Settings → Connections → Remote access → Tunnel URL** to your tunnel’s base URL (for example `https://xyz.trycloudflare.com`). That extends Streamable HTTP **Origin** / **Host** validation to include the tunnel hostname while keeping the default localhost-only behavior when the field is empty.

### Remote MCP security

When a tunnel URL is set, **`POST /mcp` requires** a configured **MCP remote token** in the same settings section (generate/copy there) and matching **`Authorization: Bearer …`** in your MCP client. Without a token, new MCP sessions are rejected (fail closed). With an **empty** tunnel URL, local use is unchanged and a bearer is optional (you can still set a token to harden localhost-only clients). Tokens are stored in the **Keychain** in the app; **`com.notionbridge.mcpBearerToken`** remains a legacy read path. For defense in depth at the edge, operators can put **Cloudflare Access** in front of the tunnel hostname — see [docs/operator/cloudflare-access-notion-bridge.md](docs/operator/cloudflare-access-notion-bridge.md).

### Legacy SSE

```text
GET  http://127.0.0.1:9700/sse
POST http://127.0.0.1:9700/messages
```

This is retained for clients that still use split SSE transport behavior.

### stdio

Use stdio when connecting local clients such as Claude Code or Cursor directly to the app process.

---

## Security model

NotionBridge currently uses a **3-tier execution model**:

- **Open**
	- Executes immediately
	- Intended for read-only or low-risk operations
- **Notify**
	- Executes immediately
	- Sends a post-execution macOS notification
- **Request**
	- Requires explicit approval before execution
	- Used for sensitive or high-impact actions

The security gate also enforces command-aware escalation rules, sensitive-path handling, and handoff behavior for commands that should not run automatically.

---

## Permissions

Depending on the tools you use, NotionBridge may require:
- Auto-prompted on first launch: Contacts, Notifications, and Automation target registration
- Manual in System Settings: Accessibility, Screen Recording, and Full Disk Access
- Separate grants for Contacts privacy access and Automation access to Contacts.app

The onboarding flow and Settings window surface current grant state, trigger native prompts when macOS allows it, and deep-link to recovery panes when manual re-authorization is required.

---

## Build and test

```bash
make build
make test
make app
make dmg
```

Other useful targets:

```bash
make clean
make install
make release
```

---

## Repo structure

```text
Notion-bridge/
├── NotionBridge/
│   ├── App/
│   ├── Config/
│   ├── Modules/
│   ├── Notion/
│   ├── Security/
│   ├── Server/
│   └── UI/
├── NotionBridgeTests/
├── .github/
├── Package.swift
├── Makefile
├── README.md
├── SECURITY.md
└── AGENTS.md
```

---

## Security disclosures

Report security issues per [SECURITY.md](SECURITY.md) (scope, out-of-scope, and contact).

## Public updates (Sparkle)

The app’s `SUFeedURL` (see `Info.plist`) points at the **Sparkle appcast** (`appcast.xml`). For automatic updates to work for end users, that URL must return valid XML **without** logging into GitHub:

- **Option A — Public GitHub repo:** Keep the default `https://raw.githubusercontent.com/KUP-IP/Notion-bridge/main/appcast.xml` and set the repository to **public** (anonymous `curl` / incognito browser must show XML).
- **Option B — Private repo:** Host `appcast.xml` at any **public HTTPS** URL you control (e.g. CDN or static site), then set `SUFeedURL` to that URL and ship a new build. The file must match the repo’s generated appcast (`make dmg` / `make appcast`); **`length`** and **`sparkle:edSignature`** must match the exact DMG you publish.

Verify locally: `make verify-sparkle-feed` (reads `SUFeedURL` from `Info.plist`).

## License and distribution

NotionBridge is **source-available commercial software**.

See `LICENSE.rtf`, `PRIVACY.md`, and `TERMS.md` for the governing materials included in this repo.
