#!/usr/bin/env bash
# test-floor-gate.sh — WS-C (v2.3, PKT-798)
#
# Locks the green test baseline as a CI gate. The custom harness
# (.build/debug/TheBridgeTests) already exits non-zero on any failing
# test, but that does NOT catch tests being silently deleted or disabled —
# a suite that shrinks from 710 → 600 with 0 failures would otherwise pass
# CI unnoticed. This gate fails the build if the passing count drops below
# the floor OR any test fails.
#
# Full append-only FLOOR provenance: scripts/test-floor-gate-history.md
FLOOR="${BRIDGE_TEST_FLOOR:-3202}"
BIN=".build/debug/TheBridgeTests"

echo "🧪 test-floor-gate: building debug + running suite (floor=${FLOOR})..."
swift build -c debug

LOG="$(mktemp -t bridge-test-floor.XXXXXX)"
trap 'rm -f "$LOG"' EXIT

# Watchdog: cap the test binary at DEADLINE seconds (default 1500 = 25 min;
# local run is ~5 min, CI macos-26 is ~3x slower). Override with
# TEST_WATCHDOG_SECONDS — a short value (e.g. 5) makes the watchdog testable.
#
# This is a REAL EXTERNAL watchdog, not `perl -e 'alarm N; exec'`. On macOS the
# SIGALRM timer set by alarm() is CLEARED by exec() (the new image starts with no
# pending alarm), so the old pattern never actually killed a hung binary — it ran
# until the CI step/job timeout. Instead we now: launch the binary in the
# background, capture its PID, start a separate killer subshell that SIGKILLs that
# PID after DEADLINE, and `wait` on the binary. On normal completion we KILL THE
# KILLER so a finished run leaves no stray `sleep` and the script never blocks on
# it. On a watchdog kill we FAIL FAST with the last logged test line so the hang
# is diagnosable instead of an opaque multi-hour cancel.
DEADLINE="${TEST_WATCHDOG_SECONDS:-1500}"
#
# Bounded retry on the harness teardown flake: the runner emits its summary from
# a tail that, on a fully-completed suite, can intermittently lose a race with
# process teardown and drop the final `Results:` line — the binary still exits 0
# and every test ran (the per-test ✅ lines are all present). That is NOT a test
# failure, so re-run up to ATTEMPTS times until the summary is captured. A real
# hang (watchdog) or a genuine non-zero exit fails immediately with no retry, and
# the floor/failure checks below are unchanged.
ATTEMPTS=3
LINE=""
for attempt in $(seq 1 "$ATTEMPTS"); do
  set +e
  # Run the binary in the background, tee'ing its combined output to the log so
  # the timeout path can print the last test line. `$!` is the binary's PID.
  "$BIN" > >(tee "$LOG") 2>&1 &
  BIN_PID=$!

  # External killer: SIGKILL the binary if it outlives DEADLINE. Captured PID so
  # we can cancel it on a clean finish.
  ( sleep "$DEADLINE"; kill -9 "$BIN_PID" 2>/dev/null ) &
  KILLER_PID=$!

  # Block until the binary exits (normally, or via the killer's SIGKILL).
  wait "$BIN_PID"
  RC=$?

  # Cleanup: cancel + reap the killer so a completed run leaves no stray sleep
  # and the script doesn't block waiting on it. Kill the killer's `sleep` CHILD
  # first (while the subshell is still alive so `pkill -P` can resolve it),
  # otherwise killing only the subshell orphans the `sleep` and it keeps running
  # for the full DEADLINE. Then kill + reap the subshell itself.
  pkill -P "$KILLER_PID" 2>/dev/null
  kill "$KILLER_PID" 2>/dev/null
  wait "$KILLER_PID" 2>/dev/null
  set -e

  # SIGKILL from the watchdog surfaces as 137 (128+9). (128+SIGALRM=142 / 14 are
  # kept as a defensive fallback in case a future change reintroduces an alarm.)
  if [ "$RC" -eq 137 ] || [ "$RC" -eq 142 ] || [ "$RC" -eq 14 ]; then
    echo "::error::test-floor-gate: test binary exceeded ${DEADLINE}s watchdog and was killed"
    echo "--- last 60 lines of test output (so you can see which test hung) ---"
    tail -60 "$LOG" || true
    echo "--- end of test output tail ---"
    exit 124
  fi
  if [ "$RC" -ne 0 ]; then
    echo "::error::test-floor-gate: test binary exited with code $RC (non-zero, non-timeout)"
    echo "--- last 60 lines of test output ---"
    tail -60 "$LOG" || true
    echo "--- end of test output tail ---"
    exit "$RC"
  fi

  LINE="$(grep -E '^Results: [0-9]+ passed, [0-9]+ failed, [0-9]+ total' "$LOG" | tail -1 || true)"
  if [ -n "$LINE" ]; then
    break
  fi
  echo "::warning::test-floor-gate: attempt ${attempt}/${ATTEMPTS} exited 0 but emitted no 'Results:' line (known harness teardown flake) — retrying"
done

LINE="$(tr -d '\000-\010\013\014\016-\037' < "$LOG" | grep -aE 'Results: [0-9]+ passed, [0-9]+ failed, [0-9]+ total' | tail -1 || true)"
if [ -z "$LINE" ]; then
  echo "::error::test-floor-gate: no 'Results:' summary line after ${ATTEMPTS} attempts"
  exit 2
fi

PASSED="$(printf '%s\n' "$LINE" | sed -E 's/^Results: ([0-9]+) passed.*/\1/')"
FAILED="$(printf '%s\n' "$LINE" | sed -E 's/^Results: [0-9]+ passed, ([0-9]+) failed.*/\1/')"

if [ "$FAILED" -ne 0 ]; then
  echo "::error::test-floor-gate: ${FAILED} failing test(s) — green bar broken"
  exit 1
fi

if [ "$PASSED" -lt "$FLOOR" ]; then
  echo "::error::test-floor-gate: passed=${PASSED} is BELOW floor=${FLOOR} — tests were removed or disabled. If this drop is intentional, lower the floor in scripts/test-floor-gate.sh in the same change and record why."
  exit 1
fi

echo "✅ test-floor-gate OK: passed=${PASSED} >= floor=${FLOOR}, failed=0"
