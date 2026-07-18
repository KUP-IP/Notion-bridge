# Agent feedback disposition audit — 2026-07-17

This audit closes the historical `AGENT_FEEDBACK.md` backlog without treating
old observations as current defects. Every entry was checked against current
`origin/main`, the open review branches, current tests, or its owning system.
The original prose remains recoverable from git history.

## Implemented in `codex/feedback-v4`

| Feedback cluster | Resolution |
|---|---|
| Job `$prev_result` whole-object/blank-body failure | Added fail-closed `$prev_result.stdout` and indexed paths such as `$prev_result.content[0].text`; corrected the seeded running-report job. |
| Test-floor log loss | Failed runs now retain the complete log under `~/Library/Logs/TheBridge/test-floor-failures`, print the stable path, and extract failure rows from the full output. The first validation run in this branch proved the retained-log path against a real failing assertion. |
| Worktree cache contamination | Added `make test-clean`; operator guidance now names it for branch changes that alter the tool surface. |
| Stale client catalog after install | Install banners and the playbook now require reconnect plus fresh `initialize`/`tools/list`. |
| Oversized `fetch_skill` / markdown section misses | Section misses return a bounded heading index instead of the full body; `notion_page_markdown_read` now supports the same section contract; fenced code headings are ignored. |
| Skill cache stale after writes | Successful page and block mutations evict affected skill bodies; page writes also evict the same page from every registry entity cache. An explicit invalidation tool was considered and rejected because correct automatic write-through invalidation removes the operator burden without expanding the public surface. |
| Exact skill marked low-confidence / contradictory metadata | An exact canonical parent with no specialist roster is no longer marked low-confidence. Notion properties are named as the authoritative metadata source and body/property version, status, or maturity drift is returned as a structured warning. |
| PACKETS exposed only as `session` | `packet` is canonical with a guarded `session` compatibility alias; a real Sessions data source is never misclassified. |
| Recent Messages identity guess | `messages_recent` returns resolved name, source, confidence, and failure reason; it uses Messages metadata first and only attempts exact-handle Contacts lookup when permission already exists. Loose name inference is prohibited. |
| Attachment-only Messages | `messages_content` returns attachment id, local path, MIME type, transfer name, count, mode, and a typed metadata-only limitation; bytes are never silently extracted. |
| Invalid Notion token remediation | HTTP 401 guidance now points to Settings > Connections and `notion_token_introspect`. |
| Operator docs drift | Corrected background-process, settings-tool, clean-test, install, and reconnect guidance. |

## Verified already resolved on current main

These entries required no duplicate code change:

- Notion aliases and write ergonomics: comment `content` alias and chunking,
  query data-source alias, blocks append aliases, bulk delete, create-body
  materialization guidance, `appendKeys`, and projected registry identity.
- Local tool correctness: shell PATH and `bg_run`/`bg_poll`/`bg_kill`, credential
  sentinel detection, calendar parsing, Reminders/Calendar permission rows,
  `bridge_focus_settings`, screen app identity, stale-PID AX errors, main-actor AX
  execution, child/byte traversal caps, and coordinate-safe AX-path clicking.
- Connection and governance: resumable session contract, registration gate,
  `connections_reset`, same-session governance propagation tests, origin-aware
  initialization, OAuth boot-order self-heal, git SHA/dirty provenance, and
  dirty/non-main install guards.
- Delivery and routing: messages send confirmation, fields identity retention,
  routing archive/canonical precedence, routing cache refresh surfaces, tool
  annotation audit, counter-collision checks, and packet/worktree playbook rules.
- Security approval behavior: module-scoped Always Allow, coalesced prompts,
  90-second timeout, time-sensitive delivery, visible/revocable grants, and
  `neverAutoApprove` protection for destructive tools.

## Considered and intentionally not implemented here

These are handled by ownership or design disposition, not silently left open.

### Client or host owned

Client auto-reinitialize, cached tool descriptors, raw oversized-result dump
format, dynamic UI click coordinates, the AskUserQuestion cap, spoken model
identity, and capability claims are MCP client/host behavior. The Bridge now
provides reconnect/reset primitives, current provenance, bounded responses, and
explicit install instructions; it cannot force a third-party client to refresh
or change its runtime self-description.

### External service or another repository

Google Drive connector authorization/CloudStorage writes, kup.solutions portal
schema/deploy polling/dead-route status, GitHub stacked-PR detection, and macOS
27 mouse-driver behavior belong to their respective connector, website, GitHub,
or OS/driver owners. No Bridge code change can truthfully close them.

### Live workspace doctrine or workflow data

Stale `project-keepr` route text, close-agent path text, specialist relation
content, packet lifecycle status, active-telemetry pointers, and initializer
roster warnings depend on live Notion skill/standing-order data. They must be
corrected through the governed skill/doctrine owner, not by baking a second
copy into this repo. Current Bridge surfaces expose the detailed roster,
telemetry event reference, cache refresh, and registry force-refresh needed for
that owner to reconcile them.

### Correct fail-closed behavior or low-evidence observations

Malformed Notion table rows rejecting atomically, destructive delete approval
timeouts, exact relation validation, TCC denial, and no-contact/no-message
results are correct fail-closed outcomes. `job_delete` denial versus timeout was
considered; the security boundary intentionally exposes one rejection result so
callers do not infer notification-delivery internals or auto-retry a destructive
operation. One-off transport drops and intermittent calendar updates have no
current reproducible defect and retain the existing retry-once guidance.

### Material product expansions outside the locked proposal

Messages reactions, first-class Google Drive mutation, Memory Process UI
redesign, voice-curator settings tools, service-by-port management, automatic
packet lifecycle transitions, and richer telemetry continuation are valid
product ideas, but each changes product scope or safety semantics. They were
reviewed and not smuggled into the stabilization release. The source log is
preserved in git history if the product owner chooses to contract any of them.

## Verification contract

- No open GitHub issues existed at audit time.
- PR #106 and PR #107 were inspected separately; neither is merged without a
  review decision.
- Every changed behavior above has a focused regression test or a source-level
  contract test.
- Full `make test-floor`, integration-branch release build, installed MCP smoke,
  and git/worktree reconciliation are required before this audit is considered
  complete.
