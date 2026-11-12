#!/bin/bash
# The phone experience eval: runs UITests/PhoneUXEvalUITests (and the two walkthroughs for screenshots) on a
# headless simulator, in light and dark, and prints a scorecard. Usage: script/ux-eval.sh [screenshot folder]
set -uo pipefail
cd "$(dirname "$0")/.."
shots="${1:-}"
sim=$(xcrun simctl list devices available | awk -F'[()]' '/iPhone 17 Pro Max/ {print $2; exit}')
[[ -n "$sim" ]] || { echo "No iPhone 17 Pro Max simulator." >&2; exit 1; }
xcrun simctl boot "$sim" 2>/dev/null || true
log=$(mktemp)
status=0
for look in light dark; do
    xcrun simctl ui "$sim" appearance "$look"
    TEST_RUNNER_ASMO_SHOTS="${shots:+$shots/$look}" xcodebuild -project ASMO.xcodeproj -scheme ASMO -destination "id=$sim" \
        -derivedDataPath DerivedData/sim CODE_SIGNING_ALLOWED=NO \
        -only-testing:ASMOUITests/PhoneUXEvalUITests ${shots:+-only-testing:ASMOUITests/PhoneWalkthroughUITests -only-testing:ASMOUITests/PhoneChaosUITests} \
        test > "$log" 2>&1 || status=1
    echo "== $look =="
    grep -E "Test Case .*PhoneUXEval.*(passed|failed)" "$log" | sed -E "s/.*test(E[0-9]+)_([A-Za-z]+)\]' (passed|failed).*/\3  \1 \2/" | sort -t' ' -k3,3V
    grep -E "error: .*XCTAssert" "$log" | sed -E 's/.*: (XCTAssert[A-Za-z]+ failed.*)/   ↳ \1/' | cut -c1-220
    grep -q "BUILD FAILED\|error: .*\.swift" "$log" && grep -E "error:" "$log" | sort -u | head -5
done
xcrun simctl ui "$sim" appearance light
xcrun simctl shutdown "$sim" 2>/dev/null || true
rm -f "$log"
exit $status
