#!/bin/bash
# Builds Nabra.app into ./build/Products/<config>. Usage: scripts/build.sh [Debug|Release]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-Release}"
cd "$ROOT"

# --- Prerequisites ---------------------------------------------------------------------------
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
  # Use Xcode even when the Command Line Tools are the selected toolchain.
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "error: Xcode is required (install it from the App Store, then open it once)." >&2
  exit 1
fi
missing=()
for tool in xcodegen cmake; do command -v "$tool" >/dev/null 2>&1 || missing+=("$tool"); done
if [ ${#missing[@]} -gt 0 ]; then
  if command -v brew >/dev/null 2>&1; then
    echo "Installing build tools with Homebrew: ${missing[*]}"
    brew install "${missing[@]}" || exit 1
  else
    echo "error: missing ${missing[*]}. Install Homebrew (https://brew.sh), then: brew install ${missing[*]}" >&2
    exit 1
  fi
fi

# --- Speech engine and bundled helper models -------------------------------------------------
[ -f vendor/engine-dist/lib/libtranscribe.a ] || { echo "Building the speech engine (first build only, a few minutes)..."; scripts/build-engine.sh || exit 1; }
scripts/fetch-resources.sh || exit 1

# --- App -------------------------------------------------------------------------------------
xcodegen generate --quiet || exit 1
LOG="$ROOT/build/last-build.log"
mkdir -p "$ROOT/build"
xcodebuild -project Nabra.xcodeproj -scheme Nabra -configuration "$CONFIG" \
  -derivedDataPath "$ROOT/build/DerivedData" \
  SYMROOT="$ROOT/build/Products" \
  build > "$LOG" 2>&1
STATUS=$?
grep -E "^[^ ].*\.(swift|m|h|c|cpp):[0-9]+:[0-9]+: (error|warning): |^(ld|clang): (error|warning)|^error: " "$LOG" | sort -u | head -60
if [ $STATUS -eq 0 ]; then
  echo "BUILD SUCCEEDED: $ROOT/build/Products/$CONFIG/Nabra.app"
else
  echo "BUILD FAILED (full log: $LOG)"
  grep -E "error" "$LOG" | grep -v "Werror" | head -20
fi
exit $STATUS
