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

_No entries yet. First entry will be appended by sk close-agent Phase 1.5._

### 2026-03-28 | Agent: MAC Keepr | Session: PKT-513-results-refinement

**Category:** Friction  
**Tool:** shell_exec (sed)  
**Severity:** Medium  
**Description:** Complex sed patterns with HTML entities (`&lt;`) and multi-line text fail silently or produce partial replacements when passed through shell_exec. Backslash escaping gets mangled through the MCP parameter chain — `\\` in single quotes is literal `\\`, not `\`, so patterns don't match. Multiple sed commands in Sub-cycle 2 either failed silently or partially applied, leaving broken text in the file.  
**Context:** Attempting to replace `"&lt;48hr"` with `"<48hr"` and multi-line hero subtitle text in results.tsx during PKT-513 refinement cycle.  
**Suggested Fix:** Document in tool docs that sed with special characters is unreliable via shell_exec. Recommend Python `open()/read()/replace()/write()` pattern via shell_exec for any text replacement involving HTML entities, multi-line strings, or complex escaping. Could also consider a dedicated `file_replace` tool that accepts old/new strings natively without shell escaping.


### 2026-03-29 — sk close agent (web-dev evolution sprint)

**Bugs:**
- `manage_skill` SecurityGate notification timed out twice (30s cap) when user was away from Mac. Tool invocation succeeded on 3rd attempt when user returned. The notification-based approval model doesn't work for triggered/automated sessions where the user may not be physically present.

**Friction:**
- `fetch_skill` name matching: `fetch_skill("sk web design")` returned "Skill not found" — actual registered name was `web-design` (no "sk" prefix, hyphens not spaces). Took 2 failed attempts to discover the correct naming convention. Error message could suggest closest matches.
- `shell_exec` timeout on Playwright browser launch — Chromium download + launch exceeds the 30s default timeout. Workaround: use `applescript_exec` with `nohup` to run Playwright in background. Consider a longer timeout option or async shell execution mode.
- `shell_exec` via AppleScript: `npx: command not found` because AppleScript shell doesn't inherit user PATH. Required explicit `export PATH="/opt/homebrew/bin:$PATH"` prefix. Document this as a known pattern.

**Enhancements:**
- `manage_skill` could support a `--no-confirm` or `--batch` flag for operations within an already-approved execution plan (e.g., UEP sprint with user approval on record).
- `fetch_skill` error response should include available skill names or fuzzy match suggestions when a name isn't found.

**Feature Requests:**
- None this session.


### 2026-03-29 | Agent: FOCUS Keepr | Session: EVNT-11549

**Category:** Friction  
**Tool:** shell_exec (npx)  
**Severity:** Low  
**Description:** `npx skills add vercel-labs/skills` triggered an interactive agent-selection prompt, blocking non-interactive execution. The agent had to re-run with `--yes` flag to bypass. Expected: non-interactive by default when only one agent directory exists.  
**Context:** Installing Vercel agent skills into `/Users/keepup/kup.solutions/.agents/skills/` during design infrastructure sprint.  
**Suggested Fix:** Document `--yes` flag requirement for non-interactive `npx skills add` in agent skill install workflows. Consider adding to sk dev-init Bootstrap Protocol as a known pattern.

---

**Category:** Friction  
**Tool:** fetch_skill  
**Severity:** Low  
**Description:** Skill name lookup is exact-match only. `fetch_skill("web dev")` returned "Skill not found: 'web dev'" — the correct name was "web-dev" (hyphenated). No fuzzy matching, partial matching, or suggestion of close matches.  
**Context:** Attempting to load sk web-dev skill content during design infrastructure sprint.  
**Suggested Fix:** Add fuzzy/partial matching or return a list of close matches when exact match fails. Alternatively, normalize input (strip spaces, try hyphenated variants) before failing.


### 2026-03-29 | Agent: MAC Keepr | Session: thread-604

**Category:** Bug  
**Tool:** messages_send  
**Severity:** High  
**Description:** Sending to a raw group `chat_identifier` instead of a resolved participant thread caused Messages to surface a malformed alias-style thread (`any;-;chat984968143276816826`) alongside the real group thread (`any;+;chat984968143276816826`). The user saw a grayed-out, unclickable thread that jumped to a weird numeric chat entry. Expected: sending to an existing group should preserve the canonical thread presentation and never expose raw backend identifiers in the UI.  
**Context:** The agent was replying to the Grace Gang group chat after triaging text messages. The first send used the raw recent-messages chat identifier and created visible confusion in Apple Messages.  
**Suggested Fix:** Add a guard that rejects raw `chat...` identifiers in `messages_send`, or resolve them to the canonical `Messages` chat object first. If group sends are supported, normalize to the real group thread before dispatch and return a warning when `verified:false` is encountered for group targets.

### 2026-03-29 | Agent: MAC Keepr | Session: thread-604

**Category:** Friction  
**Tool:** applescript_exec (Messages chat inspection)  
**Severity:** Medium  
**Description:** Attempts to inspect recent messages from the canonical and malformed group chat IDs failed with AppleScript parse/runtime errors (`Expected class name but found number.` / error `-2741`). This blocked direct verification of which thread held the sent message and forced fallback to recent-message inspection instead of chat-level introspection. Expected: chat inspection by known `Messages` chat id should either work consistently or fail with a clearer identifier-format error.  
**Context:** The agent was debugging the malformed Grace Gang thread after the bad group send and needed to compare the real group chat object with the malformed alias-style chat object.  
**Suggested Fix:** Document the exact `Messages` AppleScript id formats that are safe for chat inspection, or add a dedicated MCP tool for listing and reading group chats by canonical id so agents do not have to hand-roll brittle AppleScript lookups.

### 2026-03-31 | Agent: MAC Keepr | Session: NAV-002-iterative-ui

**Category:** Friction  
**Tool:** screen_analyze  
**Severity:** Low  
**Description:** Color quantization buckets (e.g., `#181839` instead of exact `#1a1f36`) make pixel-perfect comparison difficult. Dominant color percentages vary significantly based on text content in the region, requiring interpretation rather than direct comparison.  
**Context:** Iterative nav/hero color matching — needed to verify nav background matched hero background across 7 pages. Had to compare dominant color hex values between two regions and judge "close enough" rather than getting an exact match score.  
**Suggested Fix:** Add an `averageRGB` or `averageHex` field to screen_analyze output that reports the mean color of the sampled region (ignoring text/UI elements). Or add a `screen_diff` tool that compares two captured regions and returns a similarity percentage.

---

**Category:** Friction  
**Tool:** file_write / chat output  
**Severity:** Medium  
**Description:** Double curly brace expressions (`$ `) in file content and chat output are stripped by the Notion URL compression system. This breaks GitHub Actions YAML files that require `$ github.ref ` style expressions. Workaround: use `shell_exec` with `python3 -c` and `chr(123)*2` to write files containing these expressions.  
**Context:** Writing `.github/workflows/ci.yml` — file_write stripped all `$ ` expressions, producing invalid YAML. Required python3 workaround for every CI file write.  
**Suggested Fix:** Add an escape mechanism or raw-write mode to file_write that bypasses URL compression for file content.

---

**Category:** Bug  
**Tool:** shell_exec  
**Severity:** Low  
**Description:** `nohup` commands via shell_exec timeout even when the background process starts successfully. The tool waits for the full timeout period rather than returning immediately after the background process is launched.  
**Context:** Starting dev server with `nohup ./scripts/dev-local.sh &` — server started fine but tool timed out at 30s.  
**Suggested Fix:** Detect `nohup` or `&` patterns and return immediately after process launch confirmation rather than waiting for process completion.

---

**Category:** Enhancement  
**Tool:** screen_capture  
**Severity:** Low  
**Description:** Region coordinates require manual trial-and-error to target the right area, especially on multi-monitor setups. No way to specify a CSS selector or AX element path to auto-calculate the capture region.  
**Context:** Capturing nav bar and hero regions separately for color analysis — had to guess pixel coordinates for display index 1 (secondary monitor).  
**Suggested Fix:** Add optional `selector` (CSS) or `axPath` parameter that auto-resolves to screen coordinates before capture.


---

### Stripe Catalog Gap — RESOLVED (v1.5.5)
**Date:** 2026-03-31
**Agent:** MAC Keepr v5.3.0
**Session:** PKT-527 execution sprint

**Problem:** StripeClient only supported payment_intents and account endpoints. No product or price management. Agents forced to use `shell_exec` with raw curl commands to update Stripe products, descriptions, metadata, and marketing features. Additionally, `credential_read` threw `invalidType` for `com.notionbridge` infrastructure keys, blocking programmatic access to the Stripe API key.

**Resolution:** Added StripeModule (4 tools: `stripe_product_read`, `stripe_product_update`, `stripe_price_read`, `stripe_prices_list`). Added credential namespace bridge for `com.notionbridge` service in `CredentialManager.read()` and `list()`. Tool count: 73 → 77.

**Impact:** Eliminates Stripe dashboard context-switching for all catalog operations. Every NotionBridge customer selling via Stripe benefits.

### 2026-03-31 | Agent: MAC Keepr | Session: stripe-mcp-proxy-sprint

**Category:** Enhancement
**Tool:** StripeMcpProxy (new), StripeMcpModule (new)
**Severity:** N/A (feature delivery)
**Description:** Replaced hardcoded StripeModule (4 static tools) with dynamic MCP proxy architecture. StripeMcpProxy discovers tools from Stripe's remote MCP server at registration time, StripeMcpModule registers them with SecurityGate. StripeClient cleaned to payment-only. Tool count is now dynamic rather than hardcoded.
**Context:** Production sprint to migrate from static Stripe tool catalog to dynamic MCP proxy pattern. Enables automatic adoption of new Stripe MCP tools without code changes.
**Suggested Fix:** N/A — delivered as designed.

### 2026-03-31 | Agent: MAC Keepr | Session: v1.6.0-sprint-dmg-deploy

**Category:** Friction  
**Tool:** shell_exec  
**Severity:** Medium  
**Description:** `make install` consistently exits with code 15 (SIGTERM) when it runs `killall NotionBridge` as part of the install step. This kills the MCP transport mid-execution, causing the shell_exec call to timeout or return SIGTERM. Happened multiple times across v1.5.5 and v1.6.0 sprints.  
**Context:** Running `make install` after build+sign+notarize to copy the app to /Applications. The Makefile's install target kills the running NotionBridge process before copying, which severs the MCP connection.  
**Suggested Fix:** Split `make install` into `make install-copy` (just ditto copy, no killall) and `make install-restart` (killall + relaunch). Agents can use `install-copy` safely, then instruct the user to restart manually. Alternatively, add a `--no-kill` flag.

---

**Category:** Friction  
**Tool:** shell_exec (create-dmg)  
**Severity:** Low  
**Description:** `create-dmg` times out at default 30s shell_exec timeout. Requires 120s+ due to disk image creation, compression, and AppleScript Finder styling. First attempt also failed because `Resources/NotionBridge.icns` path doesn't exist — the icon is inside the app bundle at `.build/NotionBridge.app/Contents/Resources/NotionBridge.icns`.  
**Context:** Building DMG for landing page distribution after v1.6.0 notarized build.  
**Suggested Fix:** Document in Makefile that `make dmg` requires the icon path to be correct. Consider extracting the icon to `Resources/` during build so the DMG target doesn't depend on the app bundle path.

---

**Category:** Bug  
**Tool:** credential_read / credential_list  
**Severity:** Medium  
**Description:** `credential_read` returns "Invalid credential type: com.notionbridge" because `parseKeychainItem()` requires `kSecAttrLabel` to be "password" or "card". `credential_list` returns 0 results for Stripe keys because `list()` filters to items with valid CredentialType labels only. Items stored with `security add-generic-password` without the expected label format are invisible to the credential module.  
**Context:** Trying to read the Stripe API key stored in macOS Keychain (service: com.notionbridge, account: stripe_api_key). Had to use `shell_exec` with `security find-generic-password -w` as workaround.  
**Suggested Fix:** Either (a) make `parseKeychainItem()` handle arbitrary label formats gracefully, or (b) add a `credential_read_raw` tool that reads any keychain item by service+account without type validation.

---

**Category:** Friction  
**Tool:** file_read  
**Severity:** Low  
**Description:** `file_read` has a 20KB limit. Larger source files (e.g., full React components) require workarounds via `shell_exec` with `sed`, `head`, or `cat`.  
**Context:** Reading large .tsx files during PKT-527 website remediation work.  
**Suggested Fix:** Increase default `maxBytes` or add a `file_read_range` tool with offset+length parameters for reading specific sections of large files.



### 2026-03-31 | Agent: MAC Keepr | Session: PKT-527-website-remediation

**Category:** Bug
**Tool:** credential_read / credential_list
**Severity:** Medium
**Description:** `credential_list` returns 0 results for items stored with service `com.notionbridge` because `list()` filters to items with a valid `CredentialType` label ("password" or "card"). Items stored with non-standard labels are silently excluded. `credential_read` returns `"Invalid credential type: com.notionbridge"` because `parseKeychainItem()` requires `kSecAttrLabel` to match a known type. The Stripe API key (service: `com.notionbridge`, account: `stripe_api_key`) was inaccessible through both tools.
**Context:** Attempting to read the Stripe API key during v1.5.5 sprint to validate catalog operations. Had to fall back to `shell_exec` → `security find-generic-password -s "com.notionbridge" -a "stripe_api_key" -w` as a workaround.
**Suggested Fix:** 1. `credential_list` should return items with unknown type labels using `type: "unknown"` instead of filtering them out. 2. `credential_read` should fall back to raw keychain retrieval when type parsing fails, returning the value with a `type: "raw"` flag. 3. Alternatively, add a `credential_read_raw` tool that bypasses type validation entirely.

**Category:** Friction
**Tool:** notion_query
**Severity:** Medium
**Description:** `notion_query` returns HTTP 404 with message "Could not find database... Make sure the relevant pages and databases are shared with your integration" even when the integration IS connected. The 404 was transient — retrying the exact same query minutes later succeeded. The error message is indistinguishable from a genuine "not shared" error, leading to a 20+ minute debug session investigating permissions that were never actually broken.
**Context:** Querying SKILLS database (da15143d) and AI LOGS database (16fcbb58) during sk close agent Phase 5 write-backs. Both queries returned 404. Later retries with identical parameters succeeded.
**Suggested Fix:** 1. If the error is transient/propagation-related, the Bridge could auto-retry once before surfacing the 404. 2. If possible, distinguish "database not found/not shared" (permanent) from "temporary unavailable" (transient) in the error response. 3. Add a `retryOnce` parameter to notion_query for resilience.
