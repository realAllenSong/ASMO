#!/bin/bash
# Launch the Debug build against a separate test store, so manual testing never touches real data.
set -euo pipefail
cd "$(dirname "$0")/.."
app="$PWD/DerivedData/mac/Build/Products/Debug/ASMO.app"
# Only the Debug copy: never the installed app.
/usr/bin/pkill -f "DerivedData/mac/Build/Products/Debug/ASMO.app" 2>/dev/null || true
sleep 0.5
/usr/bin/open -g -n --env ASMO_TEST_STORE=1 "$app"
# Keep the Debug copy out of Spotlight/Launchpad, so "ASMO" always opens /Applications/ASMO.app (with the real data).
sleep 1
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$app" 2>/dev/null || true
