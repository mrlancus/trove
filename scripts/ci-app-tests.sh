#!/usr/bin/env bash
# Runs the apps' tests on GitHub's Macs (docs/PERF_AUDIT.md step 0): the Mac unit and performance
# tests (TroveMacTests), then the UI tests (TroveiOSUITests) on an iPhone SE, an iPhone Pro Max, an
# iPad mini and a 13-inch iPad simulator. Writes build/tests: logs, summary.txt, perf.json (the
# performance tests' medians) and shots/<device>/ (screenshots for docs/UI_AUDIT.md).
set -uo pipefail
cd "$(dirname "$0")/.."
OUT=build/tests
mkdir -p "$OUT/shots"
status=0

(cd App && xcodegen generate) > "$OUT/xcodegen.log" 2>&1 || { cat "$OUT/xcodegen.log"; exit 1; }

nosign=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= ENABLE_HARDENED_RUNTIME=NO)

echo "▶ Mac unit and performance tests"
TEST_RUNNER_TROVE_PERF_OUT="$PWD/$OUT/perf.json" xcodebuild -project App/Trove.xcodeproj -scheme TroveMacTests \
  -destination 'platform=macOS' -derivedDataPath build/tdd -resultBundlePath "$OUT/mac.xcresult" \
  -skipPackagePluginValidation -skipMacroValidation "${nosign[@]}" test > "$OUT/mac.log" 2>&1 || status=1
grep -E "error:|Test Case .*(passed|failed)|Executed [0-9]+ test" "$OUT/mac.log" | head -100 > "$OUT/mac-summary.txt"
cat "$OUT/mac-summary.txt"

# The newest simulator whose name matches.
pick() {
  xcrun simctl list devices available -j | python3 -c '
import json, re, sys
d = json.load(sys.stdin)["devices"]
names = [x["name"] for k, v in d.items() if "iOS" in k for x in v]
m = [n for n in names if re.search(sys.argv[1], n)]
print(m[-1] if m else "")' "$1"
}

echo "▶ UI tests: build once"
xcodebuild -project App/Trove.xcodeproj -scheme TroveiOSUITests -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/udd -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO \
  build-for-testing > "$OUT/ui-build.log" 2>&1 || { status=1; grep -E "error:" "$OUT/ui-build.log" | head -80; }

for pattern in "iPhone SE" "iPhone [0-9]+ Pro Max" "iPad mini" "iPad Pro 13|iPad Pro \\(13|iPad Air 13"; do
  device=$(pick "$pattern")
  [ -n "$device" ] || { echo "no simulator like '$pattern'"; continue; }
  slug=$(echo "$device" | tr ' ()' '___')
  echo "▶ UI tests on $device"
  skip=()
  # The launch-time test runs on one iPhone only (it launches the app six times).
  [[ "$pattern" == "iPhone SE" ]] || skip=(-skip-testing:TroveUITests/TroveUITests/testLaunchTime)
  xcodebuild -project App/Trove.xcodeproj -scheme TroveiOSUITests -destination "platform=iOS Simulator,name=$device" \
    -derivedDataPath build/udd -resultBundlePath "$OUT/ui-$slug.xcresult" ${skip[@]+"${skip[@]}"} \
    test-without-building > "$OUT/ui-$slug.log" 2>&1 || status=1
  grep -E "Test Case .*(passed|failed)|error:|Executed [0-9]+ test" "$OUT/ui-$slug.log" | head -60 | sed "s/^/[$device] /" >> "$OUT/ui-summary.txt"
  mkdir -p "$OUT/shots/$slug"
  xcrun xcresulttool export attachments --path "$OUT/ui-$slug.xcresult" --output-path "$OUT/shots/$slug" > /dev/null 2>&1 || true
done
cat "$OUT/ui-summary.txt" 2>/dev/null
{ cat "$OUT/mac-summary.txt"; cat "$OUT/ui-summary.txt" 2>/dev/null; } > "$OUT/summary.txt"
echo "$status" > "$OUT/STATUS"
exit $status
