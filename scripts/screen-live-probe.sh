#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TIMEOUT_SECONDS="${SCREEN_LIVE_PROBE_TIMEOUT_SECONDS:-150}"
LOG_PATH="${SCREEN_LIVE_PROBE_LOG:-$ROOT/.build/screen-live-probe.log}"

cd "$ROOT"
swift build --product TheBridgeTests

BINARY="$ROOT/.build/debug/TheBridgeTests"
if [[ ! -x "$BINARY" ]]; then
  echo "screen-live-probe: missing executable $BINARY" >&2
  exit 2
fi

mkdir -p "$(dirname "$LOG_PATH")"
: > "$LOG_PATH"

# Job control gives the probe its own process group. The deadline terminates
# that entire group so a framework or descendant process cannot leak into
# later verification runs.
set -m
BRIDGE_SCREEN_LIVE_PROBE=1 "$BINARY" >"$LOG_PATH" 2>&1 &
PID=$!
PGID="$(ps -o pgid= -p "$PID" | tr -d ' ')"
DEADLINE=$((SECONDS + TIMEOUT_SECONDS))

while kill -0 "$PID" 2>/dev/null; do
  if (( SECONDS >= DEADLINE )); then
    echo "screen-live-probe: deadline exceeded after ${TIMEOUT_SECONDS}s" >&2
    kill -TERM -- "-$PGID" 2>/dev/null || kill -TERM "$PID" 2>/dev/null || true

    GRACE_DEADLINE=$((SECONDS + 5))
    while kill -0 "$PID" 2>/dev/null && (( SECONDS < GRACE_DEADLINE )); do
      sleep 1
    done
    if kill -0 "$PID" 2>/dev/null; then
      kill -KILL -- "-$PGID" 2>/dev/null || kill -KILL "$PID" 2>/dev/null || true
    fi
    wait "$PID" 2>/dev/null || true
    set +m
    cat "$LOG_PATH"
    echo "SCREEN_LIVE_PROBE_STATUS=timeout"
    echo "SCREEN_LIVE_PROBE_LOG=$LOG_PATH"
    exit 124
  fi
  sleep 1
done

set +e
wait "$PID"
STATUS=$?
set -e
set +m

cat "$LOG_PATH"
if (( STATUS != 0 )); then
  echo "SCREEN_LIVE_PROBE_STATUS=failed"
  echo "SCREEN_LIVE_PROBE_EXIT=$STATUS"
  echo "SCREEN_LIVE_PROBE_LOG=$LOG_PATH"
  exit "$STATUS"
fi

RECEIPT="$(grep '^SCREEN_LIVE_PROBE_RECEIPT=' "$LOG_PATH" | tail -n 1 || true)"
if [[ -z "$RECEIPT" ]]; then
  echo "screen-live-probe: process exited successfully without a receipt" >&2
  echo "SCREEN_LIVE_PROBE_STATUS=missing_receipt"
  echo "SCREEN_LIVE_PROBE_LOG=$LOG_PATH"
  exit 3
fi

echo "SCREEN_LIVE_PROBE_STATUS=passed"
echo "SCREEN_LIVE_PROBE_LOG=$LOG_PATH"
echo "$RECEIPT"
