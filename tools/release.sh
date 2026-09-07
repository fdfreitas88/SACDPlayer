#!/bin/bash
# tools/release.sh X.Y.Z — package dist/SACDPlayer-X.Y.Z.zip in the layout LMS expects
# (zip root = SACDPlayer/ with the .pm files at its top, same as tools/deploy.sh stages)
# and write the zip's SHA-1 into repo.xml. Requires Bin/darwin/sacd_extract to be built.
set -euo pipefail
V="${1:?version}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -x "$ROOT/Bin/darwin/sacd_extract" ] || { echo "Bin/darwin/sacd_extract missing; run tools/build-sacd-extract.sh"; exit 1; }
grep -q "<version>$V</version>" "$ROOT/install.xml" || { echo "install.xml is not at $V"; exit 1; }
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
P="$STAGE/SACDPlayer"; mkdir -p "$P/Bin/darwin" "$P/HTML"
cp "$ROOT"/install.xml "$ROOT"/custom-types.conf "$ROOT"/strings.txt "$ROOT"/LICENSE "$P/"
cp "$ROOT"/lib/Plugins/SACDPlayer/*.pm "$P/"
cp "$ROOT/Bin/darwin/sacd_extract" "$P/Bin/darwin/"
cp -R "$ROOT/HTML/." "$P/HTML/"
find "$STAGE" -type d -exec chmod 755 {} \; ; find "$STAGE" -type f -exec chmod 644 {} \; ; chmod 755 "$P/Bin/darwin/sacd_extract"
mkdir -p "$ROOT/dist"; OUT="$ROOT/dist/SACDPlayer-$V.zip"; rm -f "$OUT"
(cd "$STAGE" && zip -qr "$OUT" SACDPlayer -x '*.DS_Store')
SHA="$(shasum -a 1 "$OUT" | cut -d' ' -f1)"
sed -i '' -e "s|<sha>[^<]*</sha>|<sha>$SHA</sha>|" -e "s|<plugin name=\"SACDPlayer\" version=\"[0-9.]*\"|<plugin name=\"SACDPlayer\" version=\"$V\"|" -e "s|v[0-9.]*/SACDPlayer-[0-9.]*\.zip|v$V/SACDPlayer-$V.zip|" "$ROOT/repo.xml"
echo "$OUT"; echo "sha1 $SHA"
