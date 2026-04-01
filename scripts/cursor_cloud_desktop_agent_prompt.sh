#!/usr/bin/env bash
# Open Cursor Cloud Agents in Chrome and paste a desktop-cleanup prompt from the clipboard path.
# Does not run file commands locally — intended for a Cloud Agent with notion-bridge MCP enabled.
#
# Usage:
#   ./scripts/cursor_cloud_desktop_agent_prompt.sh
# Optional: second argument "paste" tries Cmd+V via System Events (requires Accessibility for the caller app).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PROMPT_FILE="${1:-scripts/desktop_agent_prompt.txt}"
if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "Missing prompt file: $PROMPT_FILE" >&2
  exit 1
fi

/usr/bin/pbcopy < "$PROMPT_FILE"
echo "Copied prompt ($(wc -c < "$PROMPT_FILE") bytes) — opening Chrome → Cursor Agents…"

open -a "Google Chrome" "https://cursor.com/agents"

if [[ "${2:-}" == "paste" ]]; then
  sleep 2
  osascript <<'OSA'
tell application "Google Chrome" to activate
delay 0.6
tell application "System Events"
  keystroke "v" using command down
end tell
OSA
  echo "Sent Cmd+V (if Accessibility allows)."
else
  echo "Focus the agent composer and press Cmd+V to paste, or run: $0 \"$PROMPT_FILE\" paste"
fi
