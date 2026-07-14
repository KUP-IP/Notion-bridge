# PKT-1125 — W3 Hint-Only Tool-Argument Aliases Evidence

Date: 2026-07-14

Branch: `codex/pkt-1125-hint-only-aliases`

Base: `origin/main` at `5f53df2db4bcc31eb1ff2057af7abde2395df545`

## Result

The local implementation is ready for REVIEW. It preserves the operator's
hint-only decision: argument aliases are inspected only after a handler has
already failed, and the router returns an advisory without mutating arguments,
retrying the handler, or replacing the original error with a rewritten success.

The existing exact mappings for `content` to `text`, `page` to `pageId`,
`block` to `blockId`, and `data_source_id` to `dataSourceId` remain intact.
`parent_id` to `parentId` is added as one precise new mapping.

## Contract evidence

| Requirement | Evidence |
| --- | --- |
| Advisory only after error | `ToolRouter.dispatchFormatted` derives hints only inside its existing `catch` block after the one handler invocation throws. |
| No argument mutation | The exact caller-supplied `Value` is passed once to the handler. A regression test records the canonical argument object and proves byte-for-byte value equality at the handler boundary. |
| No handler retry | Source and runtime tests prove one `try await tool.handler(arguments)` call site and one invocation for both known and unknown invalid keys. |
| No rewritten success | Throwing handlers remain `isError == true`; the advisory is appended to the original error text. |
| Accepted dual keys stay accepted | The hint filter derives accepted keys from the current tool registration's input-schema properties. A tool such as `notion_comment_create`, which accepts both `content` and `text`, no longer receives a false `content` to `text` advisory when a different validation fails. |
| Exact, deterministic hints | Known mappings are sorted and emitted exactly; unknown keys receive no fabricated suggestion. |
| Live schema coverage | Tests inspect registered Notion schemas for `content`/`text`, append aliases, and `dataSourceId`/`parentId`/`parentType`. |
| No tool-count or identity drift | `BridgeConstants.staticFeatureModuleToolCount` remains 205, `Version.swift` is unchanged, and `RemoteAccessIdentity.swift` has no diff. |

## Verification ledger

- `git diff --check` — PASS.
- `make check-counter-collisions` — PASS: no duplicate claims.
- Environment-unset debug build — PASS.
- `make test` — PASS: 3,202 passed, 0 failed.
- `make test-floor` after the authoritative floor raise — PASS: 3,202 passed,
  0 failed at floor 3,202.
- FLOOR provenance — 3,194 to 3,202 for exactly eight net-new regression tests.
- Environment-unset strict-concurrency `make build` — PASS.

## Review boundary

No app install, push, merge, tag, release, or publication was permitted for this
REVIEW-FIRST packet. Integration and any installed-runtime smoke proof remain
behind packet-specific operator approval.
