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
**Context:** Installing Vercel agent skills into `<PROJECT_ROOT>/.agents/skills/` during design infrastructure sprint.  
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

**Resolution (2026-04):** Makefile `install` no longer runs `killall NotionBridge` (only `killall Dock` for icon refresh after ditto). Copy-only path remains `make install-copy`; **`make install-agent-safe`** is an alias for the same target (see `AGENTS.md`). Agents should still prefer `install-copy` / `install-agent-safe` over full `make install` when a notary/signing chain is unnecessary, to avoid long-running steps and session drops.

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


### 2026-04-02 — MAC Keepr v1.7.0 Sprint Session

| ID | Tool | Type | Detail | Evidence |
|----|------|------|--------|----------|
| F14 | `file_copy` | Friction | No overwrite flag — fails with "item already exists" when destination exists. Required fallback to `shell_exec` with `cp -f`. | Headshot copy to kup.solutions public dir |
| F15 | `shell_exec` (sed) | Friction | macOS `sed -i ''` with `\a` append command mangles tabs in Makefile recipe lines — inserts spaces instead of tabs. Required Python workaround for any Makefile modifications. | install-copy target insertion |
| F16 | `file_write` | Enhancement | `file_write` creates files but `file_append` requires existing files. A "create-or-append" mode would reduce two-step patterns. | Build script creation workflow |



### 2026-04-02 | Agent: MAC Keepr | Session: kup-solutions-v2-restructure

**Category:** Bug
**Tool:** file_write
**Severity:** High
**Description:** `file_write` encodes HTML entities in JSX/TSX files — `<` becomes literal `&lt;`, `>` becomes `&gt;`. Vite dev server is lenient and serves the file without error (HTTP 200), but esbuild production build (`npm run build:client`) rejects it: `ERROR: Unexpected "&"`. This creates a false-positive dev verification — file looks fine in dev but fails at build time.
**Context:** Writing `products.tsx` with JSX angle brackets via `file_write` tool. Dev server returned HTTP 200, but production build failed on the encoded entities.
**Suggested Fix:** The `file_write` handler in FileModule.swift uses `content.write(to: url, atomically: true, encoding: .utf8)` which should write raw UTF-8. The encoding may be happening in the MCP parameter serialization layer (JSON string → Swift String conversion). Investigate whether the MCP SDK's `Value.string()` decoder is performing HTML entity decoding/encoding. Workaround: use `shell_exec` with `cat << 'DELIM' > path` heredoc for any file containing angle brackets.

**Category:** Friction
**Tool:** screen_capture
**Severity:** Low
**Description:** `screen_capture` with `target: "window"` and `windowId: 0` returns "Window ID 0 not found in capturable windows." No documentation on how to discover valid window IDs. Had to fall back to `target: "display"` (full screen capture).
**Context:** Trying to capture the Preview.app window showing the trophy icon for visual review.
**Suggested Fix:** Add a `list_windows` tool or include valid window IDs in the error message. Alternatively, document that window IDs come from `ax_tree` or `process_list` pid → CGWindowListCopyWindowInfo.



### 2026-04-03 | Agent: Cursor Composer | Session: keepr-bridge-closeout-sk-close-agent

**Category:** Friction  
**Tool:** notion_page_read  
**Severity:** Low  
**Description:** Reading skill page `sk-close-agent` (6673dba8-26b1-4b1d-aa0a-6aad084a861c) with default pagination returned `blockCount: 200` and truncated; full protocol extends beyond first 200 blocks. Agent relied on partial content + headings to execute phases.  
**Context:** Phase 1.5 MCP feedback scan during sk close agent run.  
**Suggested Fix:** Support higher `maxBlocks` for long skill sheets, or document "read in chunks" for skills >200 blocks.

---

**Category:** Enhancement  
**Tool:** (workflow)  
**Severity:** Low  
**Description:** Phases 5–7 (AI LOG database, PACKETS, packet finalize) require Notion database IDs not present in this Cursor session; executed hub write-back to FOCUS page only.  
**Context:** sk close agent full UEP chain in external IDE without Keepr packet context.  
**Suggested Fix:** None for bridge — operator should run full closeout from Keepr with active packet when DB writes are required.


### 2026-04-04 | Agent: MAC Keepr | Session: notion-4-close-agent

**Category:** Friction  
**Tool:** notion_query / notion_page_read / notion_page_markdown_read  
**Severity:** Medium  
**Description:** Close-agent preflight encountered intermittent Bridge MCP failures while resolving AI LOGS and SKILLS targets. `notion_query` returned transient HTTP 404s for candidate database IDs, and multiple Bridge tool calls failed with `Failed to connect to MCP server` before succeeding on retry. Expected: closeout-critical Notion reads should be resilient enough to complete without repeated manual retries.  
**Context:** Running the close-agent sequence after the remote MCP remediation and QA session. The agent was trying to resolve the AI LOGS data source, inspect an existing AI LOG entry, and confirm the SKILLS record before writing the final closeout artifacts.  
**Suggested Fix:** Add automatic retry logic and connection-health recovery for Bridge Notion read tools used during closeout, and expose authoritative AI LOGS / SKILLS target IDs without requiring discovery through flaky reads.

### [2026-04-04] MAC Keepr — Sprint v1.8.0 Bridge MCP Intermittent Failures
- **Symptom:** ~50% of Bridge MCP tool calls fail with "Failed to connect to MCP server" during sprint execution.
- **Affects:** All tools (file_read, file_list, shell_exec, fetch_skill) — not tool-specific.
- **Pattern:** Failures are random; calls in the same parallel batch can have mixed success/failure. Not correlated with tool type, payload size, or time.
- **Server-side diagnosis:**
  - NotionBridge process healthy (PID 99011, running since 12:32 PM)
  - Cloudflare tunnel active (cloudflared PID 94410), health endpoint returns HTTP 200
  - 8 active SSE connections on port 9700
  - No error/disconnect/timeout entries in NotionBridge or cloudflared system logs
- **Conclusion:** Server and tunnel are healthy. Failure is on the **Notion AI MCP client side** — likely SSE connection pooling, timeout, or reconnect logic in the Notion platform's MCP client implementation.
- **Not KI-01** (SecurityGate 30s timeout) — this is a connection-level failure before any tool handler executes.
- **Workaround:** Retry failed calls (works 100% of the time on retry). The sprint completed successfully despite ~50% first-attempt failure rate.
- **Recommended:** File with Notion platform team as MCP client SSE reliability issue.


### 2026-04-04 | Agent: MAC Keepr | Session: code-review-v1.8 (Notion AI)

**Category:** Friction
**Tool:** MCP Transport (all tools)
**Severity:** High
**Description:** ~50% of Bridge MCP tool calls fail with "Failed to connect to MCP server" throughout multi-hour sprint. Failures are random, affect all tools equally, and succeed on retry. 4 agent freezes occurred during the session (Phases 2→3, mid-Phase 4, mid-Phase 6, and mid-Phase 7). NotionBridge process and Cloudflare tunnel remained healthy throughout — failure is on the Notion AI MCP client side.
**Context:** Executing 8-phase code review sprint (v1.8.0) via Notion AI agent → Bridge MCP. Sprint completed successfully despite ~50% first-attempt failure rate and 4 freezes, but elapsed time was significantly extended by retries.
**Suggested Fix:** 1. Investigate Notion AI MCP client SSE connection pooling/reconnect logic. 2. Add client-side automatic retry with exponential backoff for transient connection failures. 3. Investigate agent freeze root cause — may be correlated with parallel MCP call failures.

---

**Category:** Friction
**Tool:** session_info
**Severity:** Low
**Description:** `session_info` failed 6 consecutive times during Phase 7 tool validation while all other session module tools (`tools_list`, `session_clear`) worked. Other tools in the same parallel batches succeeded, suggesting a tool-specific issue rather than pure connection noise.
**Context:** Live tool validation across all 15 modules during Phase 7.
**Suggested Fix:** Investigate whether `session_info`'s uptime/connections/toolCalls aggregation introduces a timing window that exacerbates the MCP connection instability. Consider simplifying the response payload or adding a timeout guard.

---

**Category:** Friction
**Tool:** file_search
**Severity:** Low
**Description:** `file_search` parameter naming mismatch: tool expects `query` + `directory` but the input schema also lists `pattern` and `maxResults` as valid parameters. Passing `{directory: "...", pattern: "*.md", maxResults: 10}` returns error "missing 'directory' or 'query'". The `query` parameter name is not intuitive for file glob patterns.
**Context:** Phase 7 tool validation — attempting to search for .md files in project root.
**Suggested Fix:** Either accept `pattern` as an alias for `query`, or update the input schema description to clarify that `query` is the substring search parameter.

### 2026-04-04 | Agent: MAC Keepr | Session: remediation-sprint-v1.8.0-b (Notion AI)

**Category:** Friction
**Tool:** MCP Transport (all tools)
**Severity:** High
**Description:** ~40% of Bridge MCP tool calls fail with "Failed to connect to MCP server" throughout multi-hour session (continued from prior session). Failures are random, affect all tools equally, and succeed on retry. `make install` and `make dmg` consistently timeout at MCP's transport limit (~30s) due to notarization taking 35-40s. Workaround: break `make install` into sequential stages (build → sign → notarize → install) and create DMG manually from pre-notarized app bundle.
**Context:** Executing 4 sequential sprints: open-loop remediation, settings UI changes, debounce fix, and production deployment. Each sprint completed successfully despite intermittent failures.
**Suggested Fix:** 1. Increase MCP transport timeout for long-running operations (current ~30s limit is too short for notarization). 2. Consider a `shell_exec_async` tool variant that returns a job ID for polling, enabling long-running commands without transport timeouts.

---

**Category:** Enhancement
**Tool:** shell_exec
**Severity:** Medium
**Description:** `shell_exec` `timeout` parameter is accepted but the MCP transport itself has a hard ~30s limit that overrides any tool-level timeout. Passing `timeout: 180` does not prevent transport-level timeouts. The parameter creates a false expectation that long operations will be supported.
**Context:** `make install` and `make dmg` both exceed the transport limit during Apple notarization (35-40s).
**Suggested Fix:** Either honor the tool-level timeout at the transport layer, or document the hard transport limit clearly in the tool description so agents can plan around it.

---

**Category:** Friction
**Tool:** notion_query
**Severity:** Low
**Description:** `notion_query` parameter naming is `dataSourceId` (camelCase) but first attempt with `data_source_id` (snake_case) returned "missing 'dataSourceId'" error. The tool description/schema should clarify the exact parameter name format.
**Context:** Phase 0.5 DB preflight during sk close-agent execution.
**Suggested Fix:** Accept both camelCase and snake_case parameter names, or prominently document the exact format in the tool's input schema.

### 2026-04-05 | Agent: MAC Keepr | Session: paid-ad-sprint-infra (Notion AI)

**Category:** Friction
**Tool:** MCP Transport (all tools)
**Severity:** High
**Description:** ~50% of Bridge MCP tool calls fail with "Failed to connect to MCP server" throughout multi-hour session. Consistent with prior sessions (2026-04-04). Failures are random, affect all tools equally, and succeed on retry. No correlation with tool type or payload size. NotionBridge process healthy throughout.
**Context:** Executing paid ad infrastructure sprint — Reddit/X account setup, billing, pixel installation, and ad platform configuration via Chrome automation.
**Suggested Fix:** Same as prior entries — Notion AI MCP client SSE connection pooling/reconnect issue. Auto-retry with backoff needed on platform side.

---

**Category:** Friction
**Tool:** applescript_exec
**Severity:** Low
**Description:** Tool name is `applescript_exec` but agent initially tried `applescript` (without `_exec` suffix), causing "tool not found" error. Tool naming convention is inconsistent — most tools use bare names (e.g., `shell_exec`, `file_read`) but the AppleScript tool requires the `_exec` suffix.
**Context:** First AppleScript invocation of the session to make Chrome full screen.
**Suggested Fix:** Register `applescript` as an alias for `applescript_exec`, or rename to just `applescript` for consistency.

---

**Category:** Friction
**Tool:** chrome_execute_js
**Severity:** Low
**Description:** Parameter name is `javascript` but agent initially used `code`, causing silent failure (empty return). No error message indicating wrong parameter name.
**Context:** Executing JavaScript in Chrome to interact with X Ads billing form.
**Suggested Fix:** Accept `code` as an alias for `javascript`, or return a clear error when required parameter `javascript` is missing.

---

**Category:** Friction
**Tool:** ax_find_element
**Severity:** Medium
**Description:** `ax_find_element` cannot discover elements inside Stripe payment iframes (cross-origin). Search for AXPopUpButton returned 16 matches — all Chrome toolbar elements, none from the Stripe iframe. Stripe iframe elements are invisible to the macOS accessibility tree, making programmatic interaction with dropdowns and inputs inside Stripe forms extremely difficult.
**Context:** Trying to change the State dropdown from "South Carolina" to "South Dakota" inside a Stripe billing iframe on X Ads. All approaches failed: typing, click+arrow, Tab+arrow, double-click, ax_find_element, ax_perform_action.
**Suggested Fix:** Document that cross-origin iframe contents are not accessible via AX tools. For Stripe-style iframes, recommend chrome_execute_js with frame targeting as the only viable approach (though cross-origin restrictions may block this too).

---

**Category:** Friction
**Tool:** screen_ocr + applescript_exec (coordinate systems)
**Severity:** Medium
**Description:** screen_ocr returns coordinates with bottom-left origin (y=0 at bottom), while AppleScript click commands use top-left origin (y=0 at top). Agent had to manually convert: `screen_y = (1 - y_ocr) * screen_height`. No documentation warns about this mismatch. Multiple click attempts landed on wrong elements before the conversion formula was discovered.
**Context:** Using OCR to locate form fields and buttons on Reddit/X billing pages, then clicking via AppleScript.
**Suggested Fix:** Either normalize OCR output to top-left origin (matching AppleScript/screen conventions), or add a conversion helper tool, or prominently document the coordinate system difference in tool descriptions.

---

**Category:** Bug
**Tool:** chrome_execute_js (Stripe iframe interaction)
**Severity:** High
**Description:** Card number entry into Stripe payment iframe produced inconsistent results. Typing full 16-digit card number via AppleScript keystroke resulted in digits splitting across Card Number, Expiration, and CVC fields — Stripe's auto-advance behavior moved focus to the next field mid-entry. Multiple retry approaches (click to refocus, clear and retype, JS-based entry) all failed to produce a clean 16-digit entry. Final state: card number shows partial digits, expiration shows wrong values, CVC empty.
**Context:** Entering payment card details (4031631605063293, exp 02/31, CVV 796) into X Ads Stripe billing form.
**Suggested Fix:** For Stripe card entry, recommend: 1) Type digits in small batches (4 at a time) with delays between batches to allow Stripe's formatting to settle. 2) Use Stripe.js API directly if possible. 3) Consider a dedicated `form_fill` tool that understands auto-advancing fields.

### 2026-04-05 | Agent: MAC Keepr | Session: thread-68

**Category:** Friction  
**Tool:** shell_exec (MCP connection)  
**Severity:** High  
**Description:** MCP server connection failures occurred at approximately 40% rate throughout the session. Commands would fail with "Failed to connect to MCP server" requiring immediate retry. Pattern was non-deterministic — same command would succeed on retry. This caused significant execution overhead during the security scan and remediation sprint.  
**Context:** Executing a multi-wave security remediation sprint with 10+ sequential shell_exec calls for file patching, git operations, and verification.  
**Suggested Fix:** Investigate MCP server keepalive/timeout configuration. Consider automatic retry with backoff in the MCP transport layer. The Bridge app may be dropping idle connections too aggressively.

---

**Category:** Friction  
**Tool:** fetch_skill  
**Severity:** Medium  
**Description:** fetch_skill timed out twice (MCP error -32001: Request timed out) when loading the close-agent skill (~440 blocks). Succeeded on 4th attempt. Large skill pages may exceed the default MCP request timeout.  
**Context:** Loading sk close-agent (440 blocks) for session closeout.  
**Suggested Fix:** Increase timeout for fetch_skill or implement chunked loading for large skill pages. Consider caching recently-fetched skills.

---

**Category:** Friction  
**Tool:** shell_exec (git add)  
**Severity:** Low  
**Description:** `git add` silently refuses to stage files matching .gitignore patterns (even for modifications to already-tracked files). Required `git add -f` for .cursor/rules after .cursor/ was added to .gitignore. Error message was helpful but required an extra round-trip.  
**Context:** Staging security remediation changes that included edits to .cursor/rules (now in .gitignore).  
**Suggested Fix:** None — this is standard git behavior. Document as a known pattern for agents doing git operations on files that transition into .gitignore coverage.
