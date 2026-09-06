#!/bin/bash
# tools/spike.sh ISO_PATH_ON_SERVER — measures sacd_extract on musicplayer. Read-only apart from /tmp.
set -euo pipefail
ISO="$1"
HOST="musicplayer@10.73.254.20"
BIN_LOCAL="$(cd "$(dirname "$0")/.." && pwd)/Bin/darwin/sacd_extract"
scp -q "$BIN_LOCAL" "$HOST:/tmp/sacd_extract"
ssh "$HOST" "chmod 755 /tmp/sacd_extract; /tmp/sacd_extract -v" || true
echo "== -P timing"
ssh "$HOST" "time /tmp/sacd_extract -P -i \"$ISO\"" > /tmp/spike-print.txt 2>/tmp/spike-print.err || true
cat /tmp/spike-print.err | tail -3
echo "== track 1, stereo area"
ssh "$HOST" "rm -rf /tmp/sacd-spike && mkdir -p /tmp/sacd-spike && time /tmp/sacd_extract -2 -s -c -t 1 -i \"$ISO\" -o /tmp/sacd-spike && find /tmp/sacd-spike -name '*.dsf' -exec ls -l {} \;"
echo "== track 1, multichannel area (DST expected)"
ssh "$HOST" "rm -rf /tmp/sacd-spike-m && mkdir -p /tmp/sacd-spike-m && time /tmp/sacd_extract -m -s -c -t 1 -i \"$ISO\" -o /tmp/sacd-spike-m && find /tmp/sacd-spike-m -name '*.dsf' -exec ls -l {} \;"
echo "-P output saved to /tmp/spike-print.txt"
