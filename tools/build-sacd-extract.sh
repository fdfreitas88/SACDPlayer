#!/bin/bash
# tools/build-sacd-extract.sh — cross-build sacd_extract for x86_64 macOS on an arm64 Mac.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${SACD_SRC:-$ROOT/build/sacd-extract}"
OUT="$ROOT/Bin/darwin"
if [ ! -d "$SRC" ]; then
  git clone --depth 1 https://github.com/Sound-Linux-More/sacd-extract.git "$SRC"
fi
cmake -S "$SRC" -B "$SRC/build-x86_64" \
  -DCMAKE_OSX_ARCHITECTURES=x86_64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=10.13 \
  -DCMAKE_BUILD_TYPE=Release
cmake --build "$SRC/build-x86_64" --config Release -j4
mkdir -p "$OUT"
cp "$SRC/build-x86_64/sacd_extract" "$OUT/sacd_extract"
chmod 755 "$OUT/sacd_extract"
file "$OUT/sacd_extract"
otool -L "$OUT/sacd_extract"
