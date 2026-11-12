#!/bin/bash
# Ask a running Debug ASMO to write its window to a PNG, then copy it: script/snapshot.sh /path/out.png
set -euo pipefail
out="${1:?output path}"
dir="$HOME/Library/Caches/com.realallensong.asmo"
rm -f "$dir/asmo-snapshot.png"
touch "$dir/asmo-snapshot.request"
for _ in {1..25}; do [[ -f "$dir/asmo-snapshot.png" ]] && { sleep 0.3; cp "$dir/asmo-snapshot.png" "$out"; exit 0; }; sleep 0.2; done
echo "no snapshot written" >&2; exit 1
