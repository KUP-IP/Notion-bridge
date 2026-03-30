#!/usr/bin/env bash
# Verifies Info.plist SUFeedURL returns HTTP 200 and XML-shaped content (Sparkle appcast).
# Usage: from repo root, ./scripts/verify_sparkle_feed.sh [path/to/Info.plist]
set -euo pipefail
PLIST="${1:-Info.plist}"
if [[ ! -f "$PLIST" ]]; then
  echo "❌ Plist not found: $PLIST"
  exit 1
fi
URL=$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$PLIST")
echo "📡 SUFeedURL: $URL"
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
code=$(curl -fsS -o "$TMP" -w "%{http_code}" "$URL" || true)
if [[ "$code" != "200" ]]; then
  echo "❌ Expected HTTP 200 from appcast URL, got: $code"
  if [[ "$code" == "404" ]]; then
    echo "   Hint: GitHub raw URLs return 404 for private repositories. Use README «Public updates (Sparkle)»: make the repo public, or host appcast.xml on a public HTTPS URL and update SUFeedURL."
  fi
  exit 1
fi
if ! grep -qE '<rss|<\?xml' "$TMP"; then
  echo "❌ Response does not look like XML / Sparkle appcast (first 240 bytes):"
  head -c 240 "$TMP" | cat -v
  echo
  exit 1
fi
echo "✅ Appcast URL is reachable and looks like XML (Sparkle feed)."
