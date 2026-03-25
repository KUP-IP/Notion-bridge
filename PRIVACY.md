# Privacy Policy — NotionBridge

**Effective Date:** March 25, 2026
**Last Updated:** 2026-03-25

---

## 1. Introduction

This Privacy Policy describes how KUP Solutions ("we," "us," or "our") handles information in connection with **NotionBridge**, a native macOS application distributed via direct purchase at [kup.solutions](https://kup.solutions). We are committed to transparency about our data practices — and the short version is: **your data stays on your Mac.**

---

## 2. What NotionBridge Does

NotionBridge is a native macOS menu bar application that acts as a local bridge between AI agents (such as Notion AI) and your Mac's capabilities. It runs a local MCP (Model Context Protocol) server on your machine and provides tools for file management, messaging, screen capture, accessibility automation, and more — all processed locally.

---

## 3. Data Processing Model

**NotionBridge processes all data locally on your Mac.** There is no hosted backend, no cloud processing, and no intermediary servers operated by us.

**Local-only processing means:**

- All tool executions (file operations, screen captures, message reads, accessibility actions) happen entirely on your device
- No data from tool executions is transmitted to our servers — we operate zero servers
- The MCP server runs on `localhost` and is not network-accessible by default
- Your files, messages, clipboard contents, screen captures, and accessibility data never leave your machine through NotionBridge

**Three categories of outbound network connections exist, all user-initiated:**

1. **Notion API** — When you configure a Notion integration token, NotionBridge communicates directly with the Notion REST API (`api.notion.com`) to read and write Notion pages, databases, and comments. This connection is between your Mac and Notion's servers. We have no access to your Notion data.

2. **Stripe API** — If you use the optional payment execution tool, NotionBridge communicates with Stripe's API (`api.stripe.com`) to process payment intents using tokenized payment methods stored in your macOS Keychain. Raw card numbers are never stored — only Stripe payment method tokens (`pm_` prefixed) persist locally.

3. **Cloudflare Tunnel (optional)** — If you configure a Cloudflare Tunnel for remote access, your MCP traffic routes through Cloudflare's network to reach your Mac. You own and control your Cloudflare account and tunnel configuration. We do not operate, monitor, or have access to your tunnel.

---

## 4. macOS Permissions

NotionBridge requests the following macOS permissions (TCC grants) to function. Each permission is requested individually, and you can deny or revoke any permission at any time through System Settings:

| Permission | Purpose | Data Accessed |
|---|---|---|
| **Full Disk Access** | Read Messages history, perform file operations across your filesystem | Messages `chat.db`, user files |
| **Accessibility** | Inspect and interact with UI elements in other applications | AX tree (element roles, titles, positions) |
| **Screen Recording** | Capture screenshots and perform OCR text extraction | Screen pixel data (processed locally via Apple Vision) |
| **Automation** | Control other apps via AppleScript (Messages, Chrome, Finder) | AppleScript command execution in target apps |
| **Contacts** | Search your contacts by name, phone, or email | Contact records via CNContactStore |

**Screen Recording re-authorization:** macOS 15+ requires periodic re-authorization for Screen Recording access. NotionBridge's Permission Manager will surface this when re-grant is needed.

**You are always in control.** Denying a permission disables the associated tools but does not affect the rest of the application.

---

## 5. What We Do NOT Collect

- ❌ **No telemetry.** We do not collect usage statistics, crash reports, analytics, or behavioral data.
- ❌ **No account creation.** NotionBridge does not require an account with us.
- ❌ **No tracking.** No cookies, pixels, fingerprinting, or advertising identifiers.
- ❌ **No data transmission to us.** We operate zero servers that receive data from NotionBridge.
- ❌ **No AI processing.** NotionBridge does not contain or run AI models. It is a tool bridge — intelligence stays in the AI agent (e.g., Notion AI), not in our app.

---

## 6. Security Model

NotionBridge implements a **3-tier security gate** for all tool executions:

- **Open tier** — Read-only operations (file reads, screen captures, search queries) execute immediately with no user interaction required.
- **Notify tier** — Write operations (file writes, shell commands, sending messages) trigger a macOS notification informing you of the action.
- **Request tier** — High-impact operations (shell commands, sending messages, payment execution) require explicit user confirmation before execution.

**Additional protections:**

- **Auto-escalation patterns** — Commands containing `rm`, `kill`, `sudo`, `chmod 777`, or pipes to `sh`/`bash`/`eval` are automatically blocked or escalated.
- **Forbidden paths** — Write access to `~/.ssh`, `~/.gnupg`, `~/.aws`, `.env` files, `/System`, and `/Library` is denied.
- **Audit log** — Every tool call is recorded in an append-only local audit log with timestamp, tool name, input summary, output summary, and duration. This log is stored locally and never transmitted.

---

## 7. Credential Storage

If you use the Credential Manager (CredentialModule), passwords and payment tokens are stored in your **macOS Keychain** — Apple's built-in encrypted credential storage. NotionBridge uses standard `SecItem` APIs and does not implement its own encryption. Payment card numbers are tokenized via Stripe before storage — raw card numbers are never persisted.

---

## 8. Auto-Updates

NotionBridge uses the **Sparkle framework** for automatic updates. Update checks connect to our update feed to check for new versions. The Sparkle framework may transmit your macOS version and app version during update checks. No other data is transmitted. You can disable automatic update checks in Settings.

---

## 9. Third-Party Services

| Service | Purpose | Their Privacy Policy |
|---|---|---|
| **Notion** | API integration for reading/writing Notion workspace data | [notion.so/privacy](https://www.notion.so/privacy) |
| **Stripe** | Payment processing for direct purchases and PaymentModule | [stripe.com/privacy](https://stripe.com/privacy) |
| **Cloudflare** | Optional tunnel for remote MCP access | [cloudflare.com/privacypolicy](https://www.cloudflare.com/privacypolicy/) |
| **Sparkle** | Auto-update framework | [sparkle-project.org](https://sparkle-project.org) |

We do not share, sell, or provide your data to any third party. The connections listed above are initiated by you or your configured agents, and the data flows directly between your Mac and the third-party service.

---

## 10. Children's Privacy

NotionBridge is a developer and productivity tool and is not directed at children under 13. We do not knowingly collect information from children.

---

## 11. Changes to This Policy

We may update this Privacy Policy from time to time. Changes will be posted at [kup.solutions/privacy](https://kup.solutions/privacy) and noted in the app's release notes. Your continued use of NotionBridge after changes constitutes acceptance.

---

## 12. Contact

For questions about this Privacy Policy:

**Email:** [isaiah@kup.solutions](mailto:isaiah@kup.solutions)
**Web:** [kup.solutions](https://kup.solutions)
