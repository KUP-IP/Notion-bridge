# PKT-1120 — W3 Tool Ergonomics Evidence

Date: 2026-07-14

Branch: `codex/pkt-1120-tool-ergonomics`

Base: `origin/main` at `2935c3d1ae9c39f38ae1c00edb9981cfc87f0d91`

## Result

The local implementation is ready for REVIEW. It makes the five packeted
corrective changes, adds the governed `voice_memo_settings_get` and
`voice_memo_settings_set` pair, and clarifies the Memory Settings mode/toggle
relationship. No application bundle was installed or launched, no operator
defaults were mutated, and no tag, release, publish, push, or merge occurred.

## Contract evidence

| Requirement | Evidence |
| --- | --- |
| Dead AX process fails clearly | `ax_inspect` `find_element` and `element_info` now verify the resolved PID with `NSRunningApplication` and return the existing `appNotFound` contract instead of a zero-match payload. Two hermetic dead-PID tests use `Int32.max`. |
| Deterministic window selection | Both `screen_capture` and `screen_ocr` accept `windowId`, `bundleId`, and `appName`. Explicit ID wins; bundle ID is preferred over a case-insensitive exact app-name match. Zero and multiple matches return distinct errors with capturable window IDs, names, and bundle IDs instead of guessing. |
| No phantom body result | A `registry_create` call with no body request omits `bodyWrite`. Body-requested, idempotent-replay, and partial-failure paths retain their existing response contract. |
| AX click geometry | Successful `mouse_click` calls using `axPath` add `elementRect` with the same `x`/`y`/`width`/`height` logical-point shape as `ax_inspect`. Coordinate and window-relative modes remain unchanged. |
| Voice Memo settings tools | `voice_memo_settings_get` is open/read-only/idempotent. `voice_memo_settings_set` is notify/non-destructive/idempotent, validates all inputs before writing, supports partial updates, derives valid mode values from `VoiceMemoCuratorMode.allCases`, and returns the complete post-write snapshot. |
| Settings clarity | Auto and Cloud mode help point to Cloud enhancement. Auto is identified as the only mode that reads the Ollama toggle; Local explains that it forces Ollama on, while Heuristics, Agent, and Cloud explain that they force it off. |
| Tool bookkeeping | Static feature-module count is 203 → 205, the Voice module surface is 10 → 12, both tools have explicit annotations, and suite/tool-surface inventories include them. |

## Hermetic coverage

Seventeen net-new tests cover:

1. two dead-PID Accessibility paths;
2. both screen schemas and six deterministic selection outcomes;
3. AX click geometry without changing coordinate-mode output;
4. settings registration, tiers, schemas, annotations, defaults, partial writes,
   invalid-mode atomicity, persistence/readback, all five mode annotations, and
   Cloud-enhancement cross-references.

The first full suite measured 3,194 total with one stale pre-change Voice module
count assertion. Updating that inventory assertion from 10 to 12 produced the
accepted rerun:

```text
Results: 3194 passed, 0 failed, 3194 total
ALL TESTS PASSED
test-floor-gate OK: passed=3194 >= floor=3194, failed=0
```

The test FLOOR moved from 3,177 to 3,194, exactly matching the seventeen
net-new tests.

## Verification ledger

- `git diff --check` — PASS.
- `make check-counter-collisions` before the counter edit — PASS.
- `make check-counter-collisions` after the 203 → 205 edit — PASS.
- Environment-unset debug build — PASS.
- Full standalone suite — PASS: 3,194 passed, 0 failed.
- Environment-unset `make test-floor` — PASS at FLOOR 3,194.
- Environment-unset strict-concurrency `make build` — PASS; release product
  built in 257.59s at `.build/release/TheBridge`.
- Final source/diff review — PASS: only packet-scoped source, tests, bookkeeping,
  FLOOR provenance, and this evidence file changed.

## Review boundary

The closure run forbids install and real operator-surface mutation. TCC-gated
live AX/screen/mouse behavior and installed Settings visual proof are therefore
deferred to the operator-approved integration/install smoke pass. The hermetic
tests exercise the new selection, error, serialization, persistence, and copy
contracts without clicking the real mouse, capturing the real screen, or
changing the operator's Voice Memo settings.
