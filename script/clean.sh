#!/bin/bash
# Frees disk space after a build/install: removes everything that is rebuilt on demand or no longer used.
# Keeps: DerivedData/mac (Debug, for testing) and DerivedData/release (for installs), and all user data.
# Safe to run any time.
set -uo pipefail
cd "$(dirname "$0")/.."
before=$(df -k / | awk 'NR==2 {print $4}')
# Build products that are rebuilt when needed.
for dir in DerivedData/*/; do
    case "$dir" in DerivedData/mac/|DerivedData/release/) ;; *) rm -rf "$dir" ;; esac
done
rm -f DerivedData/*.log
rm -rf .build
# Xcode's own DerivedData for this project (builds from the Xcode app).
rm -rf ~/Library/Developer/Xcode/DerivedData/ASMO-*
# Debug-only test files the app wrote into its caches.
caches=~/Library/Containers/com.realallensong.asmo/Data/Library/Caches
rm -f "$caches"/asmo-image-*.png "$caches"/asmo-voice-running.aiff "$caches"/asmo-snapshot.png "$caches"/asmo-*.txt
# Model weights from when the app ran its own models (it no longer does).
rm -rf "$caches/huggingface" "$caches/qwen3-speech"
after=$(df -k / | awk 'NR==2 {print $4}')
echo "Cleaned: freed $(( (after - before) / 1024 )) MB"
