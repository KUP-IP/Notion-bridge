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
