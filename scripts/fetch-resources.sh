#!/bin/bash
# Downloads the small helper model that ships inside the app bundle:
#   silero-vad.gguf  (1.2 MB)  finds speech in the recording
# It is fetched instead of committed to keep the repository small. The checksum is verified.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Nabra/Resources"

fetch() {
  local name="$1" url="$2" sha="$3"
  local file="$DEST/$name"
  if [ -f "$file" ] && [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" = "$sha" ]; then
    return 0
  fi
  echo "Downloading $name..."
  curl -fL --retry 3 --progress-bar -o "$file.part" "$url"
  if [ "$(shasum -a 256 "$file.part" | cut -d' ' -f1)" != "$sha" ]; then
    rm -f "$file.part"
    echo "error: checksum mismatch for $name" >&2
    exit 1
  fi
  mv "$file.part" "$file"
}

fetch silero-vad.gguf \
  "https://huggingface.co/handy-computer/silero-vad-v6.2-gguf/resolve/main/silero-vad-v6.2-F32.gguf" \
  0d871a800c420fdd5d1b17a3aea4296d1c39608f0ff4a9295eb76457eb1c88e6
# An earlier version also bundled a language-identification model; it is no longer used.
rm -f "$DEST/lang-id.gguf"
