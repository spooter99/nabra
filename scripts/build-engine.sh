#!/bin/bash
# Builds the speech engine, transcribe.cpp (ggml + Metal), as static libraries for the app.
# Output: vendor/engine-dist/{lib,include}
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vendor/transcribe.cpp"
OUT="$ROOT/vendor/engine-dist"
TAG="v0.4.2"
PATCH="$ROOT/vendor/patches/transcribe.cpp-v0.4.2-nabra.patch"

if [ ! -d "$SRC" ]; then
  git clone --depth 1 --branch "$TAG" https://github.com/handy-computer/transcribe.cpp.git "$SRC"
  # Local addition: expose the decoder's confidence and let a second decode reuse the encoder output,
  # so one clip can be decoded under two language hints cheaply and the results compared.
  git -C "$SRC" apply "$PATCH"
fi

# Keep absolute folder paths (and with them the builder's user name) out of the compiled library.
MAP="-ffile-prefix-map=$SRC=transcribe.cpp"
cmake -S "$SRC" -B "$SRC/build-app" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="$MAP" -DCMAKE_CXX_FLAGS="$MAP" -DCMAKE_OBJC_FLAGS="$MAP" \
  -DTRANSCRIBE_BUILD_TESTS=OFF -DTRANSCRIBE_BUILD_EXAMPLES=OFF \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DCMAKE_OSX_ARCHITECTURES=arm64 >/dev/null
cmake --build "$SRC/build-app" -j "$(sysctl -n hw.ncpu)" >/dev/null

rm -rf "$OUT" && mkdir -p "$OUT/lib" "$OUT/include"
find "$SRC/build-app" -name "*.a" -exec cp {} "$OUT/lib/" \;
cp -R "$SRC/include/transcribe.h" "$SRC/include/transcribe" "$OUT/include/"
echo "Speech engine built: $OUT/lib"
