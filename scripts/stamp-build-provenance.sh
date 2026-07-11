#!/bin/bash
set -euo pipefail

PLIST_PATH="${1:?usage: stamp-build-provenance.sh <Info.plist> [repo-root] [git-sha] [git-dirty]}"
REPO_ROOT="${2:-$(pwd)}"

if [[ ! -f "$PLIST_PATH" ]]; then
  echo "error: build provenance plist not found: $PLIST_PATH" >&2
  exit 1
fi

GIT_SHA="${3:-$(git -C "$REPO_ROOT" rev-parse --verify HEAD)}"
if [[ $# -ge 4 ]]; then
  GIT_DIRTY="$4"
else
  GIT_DIRTY=false
  if [[ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=normal)" ]]; then
    GIT_DIRTY=true
  fi
fi
if [[ "$GIT_DIRTY" != "true" && "$GIT_DIRTY" != "false" ]]; then
  echo "error: git-dirty must be true or false, got: $GIT_DIRTY" >&2
  exit 1
fi

/usr/libexec/PlistBuddy -c "Delete :BridgeGitSHA" "$PLIST_PATH" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Delete :BridgeGitDirty" "$PLIST_PATH" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :BridgeGitSHA string $GIT_SHA" "$PLIST_PATH"
/usr/libexec/PlistBuddy -c "Add :BridgeGitDirty bool $GIT_DIRTY" "$PLIST_PATH"

echo "Build provenance: git=$GIT_SHA dirty=$GIT_DIRTY"
