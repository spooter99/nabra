#!/bin/bash
# Builds Scribe's writing runtime: llama.cpp's server as one self-contained binary (Metal, static),
# installed into the app as Contents/MacOS/nabra-writer. Output: vendor/writer-dist/nabra-writer
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vendor/llama.cpp"
OUT="$ROOT/vendor/writer-dist"
TAG="b12602"

if [ ! -d "$SRC" ]; then
  git clone --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp.git "$SRC"
fi

# Keep absolute folder paths (and with them the builder's user name) out of the binary.
MAP="-ffile-prefix-map=$SRC=llama.cpp"
cmake -S "$SRC" -B "$SRC/build-app" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS="$MAP" -DCMAKE_CXX_FLAGS="$MAP" -DCMAKE_OBJC_FLAGS="$MAP" \
  -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_CCACHE=OFF \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_SERVER=ON \
  -DLLAMA_BUILD_UI=OFF -DLLAMA_USE_PREBUILT_UI=OFF -DLLAMA_OPENSSL=OFF \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DCMAKE_OSX_ARCHITECTURES=arm64 >/dev/null
cmake --build "$SRC/build-app" --config Release --target llama-server -j "$(sysctl -n hw.ncpu)" >/dev/null

mkdir -p "$OUT"
cp "$SRC/build-app/bin/llama-server" "$OUT/nabra-writer"
strip -x "$OUT/nabra-writer" 2>/dev/null || true
echo "Writing runtime built: $OUT/nabra-writer"
