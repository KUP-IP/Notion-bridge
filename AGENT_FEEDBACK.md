# AGENT_FEEDBACK.md — Notion Bridge MCP Tool Feedback Log

> **Purpose:** Append-only structured feedback from KUP·OS agents during session closeout (sk close-agent Phase 1.5).  
> **Consumers:** Development sprints — review, triage, and execute during Notion Bridge dev cycles.  
> **Format:** Each entry is a timestamped block filed by an agent. Do not edit existing entries — curate during sprints only.

---

## Schema

Each entry follows this structure:

```
### [YYYY-MM-DD] | Agent: <agent-name> | Session: <event-id>

**Category:** Bug | Friction | Enhancement | Feature Request  
**Tool:** <tool_name>  
**Severity:** Low | Medium | High | Critical  
**Description:** <what happened, expected vs actual>  
**Context:** <what the agent was trying to do>  
**Suggested Fix:** <optional — agent's best guess at resolution>  
```

---

## Entries

_Pruned during v1.8.1 release (2026-04-06). All prior entries reviewed and resolved or tracked externally._

### 2026-04-07 — MAC Keepr session (NotionBridge v1.8.2 release sprint)

**Friction:**
- `ax_perform_action` could not dismiss Apple Passwords modal windows (AuthenticationServices-owned). AX path resolution failed for system-owned overlays even when `ax_find_element` located them. Had to fall back to `kill -9`. Consider documenting this as a known limitation.
- `sed` command escaping for strings containing backticks, apostrophes, and pipe characters is error-prone via `shell_exec`. Python `str.replace()` was more reliable for complex string substitutions. This is expected shell behavior but worth noting for agent guidance.
- `file_search` timed out on broad `/Users/keepup` searches. Consider adding a timeout parameter or documenting the limitation for large directory trees.

**Enhancements:**
- `credential_save` worked well for overwriting keychain entries — no friction.
- `screen_capture` + `screen_ocr` + `ax_tree` pipeline was effective for diagnosing the Passwords modal deadlock — good composability.
- `tools_list` with module filter was very useful for verifying description changes post-restart.

**Feature Requests:**
- An `ax_close_window` tool (or window-targeted close action) would have helped dismiss the stuck Passwords modals without force-killing the process.

### 2026-04-08 — MAC Keepr session (Ad-1 Video Production)

**Friction:**
1. `screen_capture` returns a local file path but Notion-side agent cannot view the image contents. The agent can capture screenshots but has no vision on local PNG files — only images pasted directly into Notion chat are viewable. This creates a two-step workflow (capture → user pastes) that defeats the purpose of screen_capture for remote assistance.
2. `applescript_exec` failed to automate Descript (Electron app). Menu item lookups returned errors ("Can't get menu item 'Import'"), and keyboard shortcuts (Cmd+I, Cmd+Shift+I) did not trigger expected file dialogs. Electron apps have non-standard accessibility trees that don't respond reliably to AppleScript menu/keystroke automation.

**Enhancements:**
1. `screen_capture`: Add an option to return base64-encoded image data inline (not just file path) so the agent can process the image without requiring the user to paste it into chat.
2. `screen_ocr`: Worked reliably as a workaround for screen_capture's vision gap. Consider documenting screen_ocr as the recommended first tool for screen-aware assistance, with screen_capture reserved for when actual image files are needed.

**Feature Requests:**
1. Descript-aware automation: Given Descript's Electron architecture resists AppleScript, a dedicated Descript helper (even just shell-based CLI wrapping `descript-api`) could bypass the UI automation layer entirely.
