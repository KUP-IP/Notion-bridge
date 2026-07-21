# Tool Smoke Receipt + Demo Gate

Use this checklist in any PR that adds MCP tools (or user-visible features).  
Agent self-checks are required; **operator PASS/FAIL is required** for anything a human can see.

## Receipt (paste into PR body)

```markdown
### Tool Smoke Receipt

**Tools:** `<exact names>`
**Installed SHA / version:** `<BridgeGitSHA>` / `<marketing>`

| Layer | Result |
|-------|--------|
| Hermetic (`make test-floor`) | PASS / FAIL — floor ___ |
| Annotation audit | PASS / FAIL |
| Live success call | PASS / FAIL — evidence ___ |
| Live reject call | PASS / FAIL |
| Demo Gate | PASS / FAIL / N/A (non-visible) |
| Not smoked | _(must be empty for Ship Gate GO)_ |

#### Demo Gate (mutating / visible tools)
- **URL(s):** 
- **Expected look:** _(one sentence)_
- **Agent critique:** expected vs actual
- **Operator verdict:** PASS / FAIL _(silence ≠ PASS)_
```

## Rules

1. Hermetic green is necessary, not sufficient for create/update-class tools.
2. Demo Gate: open or link the page, say how it should look, ask PASS/FAIL, **stop** until answered.
3. If operator FAILs, do not close the smoke — Unblock / fix / re-demo.
4. Pure read/reject tools may skip browser open but still offer chat PASS/FAIL when Ship Gate needs trust.
5. Never dump secrets in receipts.
