#!/usr/bin/env bash
# Fail if appcast.xml newest item does not match Info.plist marketing + build numbers.
# Usage: from repo root, ./scripts/check_appcast_version.sh [Info.plist] [appcast.xml]
set -euo pipefail
PLIST="${1:-Info.plist}"
CAST="${2:-appcast.xml}"
if [[ ! -f "$PLIST" || ! -f "$CAST" ]]; then
  echo "❌ Missing $PLIST or $CAST"
  exit 1
fi
MARKETING=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")
CAST_SHORT=$(grep -oE '<sparkle:shortVersionString>[^<]+' "$CAST" | head -1 | sed 's/.*>//')
CAST_BUILD=$(grep -oE '<sparkle:version>[0-9]+' "$CAST" | head -1 | sed 's/.*>//')
if [[ "$CAST_SHORT" != "$MARKETING" ]]; then
  echo "❌ appcast sparkle:shortVersionString ($CAST_SHORT) ≠ Info.plist CFBundleShortVersionString ($MARKETING)"
  exit 1
fi
if [[ "$CAST_BUILD" != "$BUILD" ]]; then
  echo "❌ appcast sparkle:version ($CAST_BUILD) ≠ Info.plist CFBundleVersion ($BUILD)"
  exit 1
fi
echo "✅ appcast matches Info.plist ($MARKETING build $BUILD)"
