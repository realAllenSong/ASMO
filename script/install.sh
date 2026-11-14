#!/bin/bash
# Build Release and replace /Applications/ASMO.app (data lives in the app container and is kept); install the
# `asmo` command and its agent skill.
set -euo pipefail
cd "$(dirname "$0")/.."
derived="$PWD/DerivedData/release"
xcodebuild -project ASMO.xcodeproj -scheme ASMO -configuration Release -destination 'platform=macOS' \
    -derivedDataPath "$derived" CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= ARCHS=arm64 ONLY_ACTIVE_ARCH=YES -skipMacroValidation -skipPackagePluginValidation build > "$derived.log" 2>&1 || true
grep -E "error:|BUILD" "$derived.log" | head -20 || true
grep -q "BUILD SUCCEEDED" "$derived.log" || { echo "build failed" >&2; exit 1; }
built="$derived/Build/Products/Release/ASMO.app"
[[ -d "$built" ]] || { echo "build failed" >&2; exit 1; }
# Sign with this Mac's Apple Development certificate when there is one: macOS remembers permissions (Calendar,
# Reminders) by the signer, so a stable signature keeps them across reinstalls. An ad-hoc build looks like a new
# app every time and asks again.
identity=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" | sed -E 's/.*"(.*)"/\1/')
if [[ -n "$identity" ]]; then
    codesign --force --deep --options runtime --entitlements Config/ASMO.Mac.entitlements --sign "$identity" "$built" > /dev/null 2>&1 \
        && echo "Signed with $identity" || echo "Signing failed; keeping the ad-hoc build" >&2
fi
/usr/bin/pkill -x ASMO 2>/dev/null || true
sleep 0.5
if [[ -d /Applications/ASMO.app ]]; then
    mkdir -p dist && rm -rf dist/ASMO.previous.app && mv /Applications/ASMO.app dist/ASMO.previous.app
fi
cp -R "$built" /Applications/ASMO.app
# Only the installed copy should be found by Spotlight/Launchpad.
for copy in "$built" "$PWD/dist/ASMO.previous.app" "$PWD/DerivedData/mac/Build/Products/Debug/ASMO.app"; do
    [[ -e "$copy" ]] && /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$copy" 2>/dev/null || true
done
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/ASMO.app
/usr/bin/open -g /Applications/ASMO.app
# Building registers the copies in DerivedData again; leave only the installed one.
sleep 1
for copy in "$PWD"/DerivedData/*/Build/Products/*/ASMO.app; do
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$copy" 2>/dev/null || true
done
echo "Installed /Applications/ASMO.app"
# The `asmo` command and the skill that teaches coding agents to use it.
swift build -c release --product asmo > /dev/null
mkdir -p ~/.local/bin && rm -f ~/.local/bin/asmo && cp .build/release/asmo ~/.local/bin/asmo
echo "Installed ~/.local/bin/asmo"
# The skill for Claude Code and Codex, and the Claude desktop app's MCP entry.
~/.local/bin/asmo setup --skill skill/asmo/SKILL.md
# Don't let build leftovers pile up.
"$(dirname "$0")/clean.sh"
