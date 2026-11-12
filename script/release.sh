#!/bin/bash
# Builds the downloadable app: Release, signed with your Developer ID, the asmo command and its skill inside,
# notarized by Apple and stapled. Output: dist/ASMO-v<version>-macOS.zip (the file to attach to a GitHub release).
#
# Needs a "Developer ID Application" certificate in the keychain and a notarytool keychain profile:
#   xcrun notarytool store-credentials <profile> --apple-id … --team-id … --password <app-specific password>
#   NOTARY_PROFILE=<profile> script/release.sh        (NOTARIZE=0 skips notarizing, for a quick local check)
set -euo pipefail
cd "$(dirname "$0")/.."
profile="${NOTARY_PROFILE:-ThunderTalk-notary}"
identity=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
[[ -n "$identity" ]] || { echo "No \"Developer ID Application\" certificate in the keychain." >&2; exit 1; }
team=$(echo "$identity" | sed -E 's/.*\(([A-Z0-9]+)\)$/\1/')
version=$(awk -F' = ' '/^MARKETING_VERSION/ {print $2}' Config/Base.xcconfig)
derived="$PWD/DerivedData/distribution"
app="$derived/Build/Products/Release/ASMO.app"
zip="dist/ASMO-v$version-macOS.zip"

echo "Building ASMO $version for $identity"
xcodebuild -project ASMO.xcodeproj -scheme ASMO -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="$team" PROVISIONING_PROFILE_SPECIFIER= \
    ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp" CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    -skipMacroValidation -skipPackagePluginValidation build > "$derived.log" 2>&1 || true
grep -q "BUILD SUCCEEDED" "$derived.log" || { grep -E "error:" "$derived.log" | sort -u | head -10; exit 1; }

# The command and the skill ride inside the app; `asmo setup` installs them from there.
swift build -c release --product asmo --arch arm64 > /dev/null
mkdir -p "$app/Contents/Helpers"
cp "$(swift build -c release --product asmo --arch arm64 --show-bin-path)/asmo" "$app/Contents/Helpers/asmo"
cp skill/asmo/SKILL.md "$app/Contents/Resources/asmo-skill.md"
codesign --force --timestamp --options runtime --sign "$identity" "$app/Contents/Helpers/asmo"
# Re-seal the app around the added files, keeping its entitlements.
codesign -d --entitlements :- "$app" > "$derived/entitlements.plist" 2>/dev/null
# A debugging entitlement never ships (notarization refuses it).
/usr/libexec/PlistBuddy -c "Delete :com.apple.security.get-task-allow" "$derived/entitlements.plist" 2>/dev/null || true
codesign --force --timestamp --options runtime --entitlements "$derived/entitlements.plist" --sign "$identity" "$app"
codesign --verify --strict --deep "$app"

mkdir -p dist
rm -f "$zip"
if [[ "${NOTARIZE:-1}" == 1 ]]; then
    ditto -c -k --keepParent "$app" "$derived/notarize.zip"
    xcrun notarytool submit "$derived/notarize.zip" --keychain-profile "$profile" --wait
    xcrun stapler staple "$app"
    for _ in 1 2 3 4 5 6; do spctl --assess --type execute "$app" 2>/dev/null && break; sleep 5; done
    spctl --assess --type execute --verbose "$app"
fi
ditto -c -k --keepParent "$app" "$zip"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$app" 2>/dev/null || true
echo "Built $zip ($(du -h "$zip" | cut -f1))"
