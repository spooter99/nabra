#!/bin/bash
# Runs the whole dictation loop unattended and reports what happened: the app presses its own
# dictation key (in-process, nothing is posted to the system), records, recognises and "inserts".
# Nothing is typed into any app, no sounds are played, the indicator stays off screen, and it
# uses a throwaway profile, so your history and settings are not touched.
#
#   scripts/check-loop.sh                 a spoken test clip stands in for the microphone
#   scripts/check-loop.sh --microphone    the real microphone: shows start-up timing in the log
#   scripts/check-loop.sh clip.wav        your own clip
#
# Extra NAME=value arguments are passed to the app, for example NABRA_ROBOT_ONLY=hold,overlap
# or NABRA_STANDBY=always. Needs a built app (scripts/build.sh) and an installed speech model.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Products/Release/Nabra.app"
MODELS="$HOME/Library/Application Support/Nabra/Models"

[ -d "$APP" ] || { echo "error: build the app first (scripts/build.sh)" >&2; exit 1; }
MODEL="$(ls "$MODELS"/*.gguf 2>/dev/null | head -1)"
[ -n "$MODEL" ] || { echo "error: no speech model in $MODELS (open Nabra once and download it)" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/nabra-check.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/support/Models"
# An APFS clone: instant and takes no extra space. Falls back to a plain copy elsewhere.
cp -c "$MODEL" "$WORK/support/Models/" 2>/dev/null || cp "$MODEL" "$WORK/support/Models/" || exit 1
# Run a copy, so rebuilding meanwhile cannot disturb it.
cp -R "$APP" "$WORK/Nabra.app" || exit 1

ARGS=(--env "NABRA_SUPPORT_DIR=$WORK/support" --env "NABRA_ROBOT=$WORK/report.txt")
CLIP=""
for argument in "$@"; do
  case "$argument" in
    --microphone) CLIP="microphone" ;;
    *=*) ARGS+=(--env "$argument") ;;
    *) CLIP="$argument" ;;
  esac
done
if [ -z "$CLIP" ]; then
  CLIP="$WORK/clip.aiff"
  say -o "$CLIP" "Testing one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen" || exit 1
fi
[ "$CLIP" = "microphone" ] || ARGS+=(--env "NABRA_ROBOT_AUDIO=$CLIP")

# Through `open`, so the app runs under its own Microphone permission rather than the terminal's.
open -n -g "$WORK/Nabra.app" "${ARGS[@]}" || exit 1
for _ in $(seq 1 300); do
  sleep 1
  grep -q "^done" "$WORK/report.txt" 2>/dev/null && break
done
cat "$WORK/report.txt" 2>/dev/null || { echo "error: the app wrote no report" >&2; exit 1; }
echo
echo "--- log"
grep -v "  language:" "$WORK/support/nabra.log" 2>/dev/null
grep -q "^PASS" "$WORK/report.txt"
