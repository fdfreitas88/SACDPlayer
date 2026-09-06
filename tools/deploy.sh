#!/bin/bash
# tools/deploy.sh — rsync the plugin to musicplayer. Does NOT restart LMS (Felipe does that by hand).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${SACD_HOST:-musicplayer@10.73.254.20}"
DEST="~/Library/Caches/Squeezebox/InstalledPlugins/Plugins/SACDPlayer"
[ -x "$ROOT/Bin/darwin/sacd_extract" ] || { echo "Bin/darwin/sacd_extract missing; run tools/build-sacd-extract.sh"; exit 1; }
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp "$ROOT"/install.xml "$ROOT"/custom-types.conf "$ROOT"/strings.txt "$STAGE/"
cp "$ROOT"/lib/Plugins/SACDPlayer/*.pm "$STAGE/"
mkdir -p "$STAGE/Bin/darwin" "$STAGE/HTML"
cp "$ROOT/Bin/darwin/sacd_extract" "$STAGE/Bin/darwin/"
cp -R "$ROOT/HTML/." "$STAGE/HTML/"
# Remote permissions come from this staging dir: rsync copies the modes set here (and the
# server's umask 022 covers anything it has to create), so we never chmod on the server.
find "$STAGE" -type d -exec chmod 755 {} \; ; find "$STAGE" -type f -exec chmod 644 {} \; ; chmod 755 "$STAGE/Bin/darwin/sacd_extract"
ssh "$HOST" "mkdir -p $DEST"
rsync -rlt --delete "$STAGE/" "$HOST:$DEST/" || rsync -rt --delete "$STAGE/" "$HOST:$DEST/"
ssh "$HOST" "cd $DEST && ls && Bin/darwin/sacd_extract -v 2>&1 | head -1"
echo "Deployed. Ask Felipe to restart LMS: open -a 'Lyrion Music Server' after quitting it."
