#!/bin/bash
# Builds Nabra and installs it to /Applications, replacing any previous copy.
# Usage: scripts/install.sh [--background | --no-launch]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build.sh" Release
APP="$ROOT/build/Products/Release/Nabra.app"
DEST="/Applications/Nabra.app"

osascript -e 'tell application id "app.nabra.Nabra" to quit' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Nabra >/dev/null || break; sleep 0.3; done
pkill -x Nabra >/dev/null 2>&1 || true

rm -rf "$DEST"
ditto "$APP" "$DEST"
codesign --verify --deep --strict "$DEST" && echo "Installed: $DEST"
case "${1:-}" in
  --no-launch) ;;
  --background) open -g "$DEST" --args --background ;;   # relaunch without bringing the window forward
  *) open "$DEST" ;;
esac
