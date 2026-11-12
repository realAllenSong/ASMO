#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
derived="$PWD/DerivedData/mac"
app="$derived/Build/Products/Debug/ASMO.app"
xcodebuild -project ASMO.xcodeproj -scheme ASMO -destination 'platform=macOS' \
    -derivedDataPath "$derived" CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= -skipMacroValidation -skipPackagePluginValidation build

/usr/bin/pkill -f "^$app/Contents/MacOS/ASMO$" 2>/dev/null || true
/usr/bin/open -n "$app"
if [[ "${1:-}" == --verify ]]; then
    for attempt in {1..15}; do
        if /usr/bin/pgrep -f "^$app/Contents/MacOS/ASMO$" >/dev/null; then exit 0; fi
        sleep 0.25
    done
    printf 'ASMO did not stay running.\n' >&2
    exit 1
fi
