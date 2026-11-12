#!/bin/bash
# Build 逐日 for your iPhone and install it (iPhone unlocked, on the same Wi-Fi or plugged in, Developer Mode on).
# Needs your Apple developer team: ASMO_TEAM=XXXXXXXXXX script/install-iphone.sh, or put
# DEVELOPMENT_TEAM = XXXXXXXXXX in Config/Personal.xcconfig (not tracked).
# First time only: accept the latest Program License Agreement at https://developer.apple.com/account
# (otherwise Xcode can't make the install profile).
set -euo pipefail
cd "$(dirname "$0")/.."
team="${ASMO_TEAM:-$(awk -F= '/^DEVELOPMENT_TEAM/ {gsub(/[ \t]/, "", $2); print $2}' Config/Personal.xcconfig 2>/dev/null || true)}"
[[ -n "$team" ]] || { echo "Set your Apple developer team: ASMO_TEAM=XXXXXXXXXX $0 (or DEVELOPMENT_TEAM in Config/Personal.xcconfig)." >&2; exit 1; }
derived="$PWD/DerivedData/iphone"
device=$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && $0 !~ /unavailable/ {print $3; exit}')
[[ -n "$device" ]] || { echo "No iPhone available: unlock it, keep it on the same Wi-Fi (or plug it in), then run again." >&2; exit 1; }
xcodebuild -project ASMO.xcodeproj -scheme ASMO -configuration Release -destination 'generic/platform=iOS' \
    -derivedDataPath "$derived" DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates \
    -skipMacroValidation -skipPackagePluginValidation build > "$derived.log" 2>&1 || true
if ! grep -q "BUILD SUCCEEDED" "$derived.log"; then
    grep -E "error:" "$derived.log" | sort -u | head -5
    grep -q "Program License Agreement" "$derived.log" && echo "→ Accept the new agreement at https://developer.apple.com/account, then run again."
    exit 1
fi
xcrun devicectl device install app --device "$device" "$derived/Build/Products/Release-iphoneos/ASMO.app"
echo "Installed 逐日 on your iPhone. (If it won't open: Settings › General › VPN & Device Management › trust the developer.)"
"$(dirname "$0")/clean.sh" >/dev/null
