# PKT-1119 — W4 Test-Floor Consolidation Evidence

Date: 2026-07-14

Branch: `codex/pkt-1119-floor-consolidation`

Base: `origin/main` at `7bdd7d0062ebb4ce224386e30b060fb7bf925661`

## Result

The local implementation is ready for REVIEW. The gate script now has one
authoritative, unconditional assignment:

```bash
FLOOR="${BRIDGE_TEST_FLOOR:-3202}"
```

The append-only provenance ledger was relocated to
`scripts/test-floor-gate-history.md` in its original ledger order. The
executable gate logic from `BIN=".build/debug/TheBridgeTests"` through EOF is
byte-identical to the pre-change script.

## Before and after

| Check | Before | After |
| --- | --- | --- |
| Gate script line count | 2,408 | 114 |
| Unconditional stacked FLOOR assignments | 15 | 1 |
| Effective default floor | 3,202 | 3,202 |
| Real `make test-floor` verdict | PASS | PASS |
| Test result | 3,202 passed / 0 failed | 3,202 passed / 0 failed |
| Sidecar line count | absent | 2,287 |

No floor was raised, lowered, or re-measured for this packet.

## Mechanical provenance proof

The comparison extracts the original ledger from the committed base, excludes
only the executable stacked assignment lines, and hashes those bytes against
the relocated sidecar after its six-line explanatory header:

```bash
git show 7bdd7d0062ebb4ce224386e30b060fb7bf925661:scripts/test-floor-gate.sh |
  awk '/^# FLOOR provenance:/{p=1}
       /^BIN="\.build\/debug\/TheBridgeTests"/{p=0}
       p && $0 !~ /^FLOOR="\$\{BRIDGE_TEST_FLOOR:-[0-9]+\}"$/' |
  shasum -a 256

tail -n +7 scripts/test-floor-gate-history.md | shasum -a 256
```

Both produced:

```text
7b3a8ea3a5555b267abeb9d6d823734cd5d1093a19b3f8f50f55186b004303b2
```

Additional mechanical checks:

- `grep -cF 'FLOOR="${BRIDGE_TEST_FLOOR' scripts/test-floor-gate.sh` → `1`.
- `rg -n '^FLOOR=' scripts/test-floor-gate.sh` → line 12, default 3,202.
- `cmp` of the original and current `BIN=`-through-EOF regions → identical.
- Script executable mode remains `-rwxr-xr-x`.

## Verification ledger

- Pre-change environment-scrubbed `make test-floor` — PASS:
  3,202 passed, 0 failed, floor 3,202.
- Post-change environment-scrubbed `make test-floor` — PASS:
  3,202 passed, 0 failed, floor 3,202.
- `git diff --check` — PASS.
- `make check-counter-collisions` — PASS: no duplicate claims.
- Environment-unset strict-concurrency `make build` — PASS;
  release product built at `.build/release/TheBridge`.
- Tracked diff is limited to the gate script, provenance sidecar, and this
  evidence document.

## Review boundary

No push, merge, install, tag, release, or publish occurred. The packet remains
FOCUS until the controller independently verifies this receipt and writes the
REVIEW transition last.
