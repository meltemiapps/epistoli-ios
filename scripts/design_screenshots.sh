#!/usr/bin/env bash
# design_screenshots.sh: every restyled screen, once per background, on one simulator.
#
# Usage: scripts/design_screenshots.sh <output-dir> <code-A> <code-B> <code-B-new-phone> [background ...]
#   code files: contact codes (public keys only), e.g. the ones scripts/checkpoint_c.sh saves.
#   backgrounds default to: aegean sunset
# Creates (or reuses) a simulator named "Design review". It is booted once and never erased; each
# background starts clean by uninstalling the app, resetting the simulator keychain (keychain items
# survive an uninstall) and reinstalling. Each attempt writes to <output-dir>/attempts/<timestamp>/
# and earlier attempts are never deleted.
set -euo pipefail

OUT="${1:?usage: scripts/design_screenshots.sh <output-dir> <code-A> <code-B> <code-B-new> [bg ...]}"
CODE_A="$(cat "${2:?code-A file}")"
CODE_B="$(cat "${3:?code-B file}")"
CODE_B2="$(cat "${4:?code-B-new-phone file}")"
shift 4
BACKGROUNDS=("$@")
[[ ${#BACKGROUNDS[@]} -gt 0 ]] || BACKGROUNDS=(aegean sunset)

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
APP_ID="com.meltemiapps.epistoli"
RUNNER_ID="com.meltemiapps.epistoli.uitests.xctrunner"
WARMUP_SECONDS=20
STARTUP_ERRORS='Timed out while acquiring background assertion|Failed to establish communication with the test runner'

RUNTIME="$(xcrun simctl list runtimes -j | python3 -I -c '
import json, sys
rs = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]]
print(sorted(rs, key=lambda r: [int(x) for x in r["version"].split(".")])[-1]["identifier"])')"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
BUILD="$OUT/build"
ATTEMPT="$OUT/attempts/$(date +%Y%m%d-%H%M%S)"
RESULTS="$ATTEMPT/results"
SHOTS="$ATTEMPT/screenshots"
LOGS="$ATTEMPT/logs"
mkdir -p "$RESULTS" "$SHOTS" "$LOGS"
echo "design_screenshots: attempt folder $ATTEMPT"

SIM="$(xcrun simctl list devices -j | python3 -I -c '
import json, sys
for devs in json.load(sys.stdin)["devices"].values():
    for d in devs:
        if d["name"] == "Design review" and d["isAvailable"]:
            print(d["udid"]); sys.exit()')"
[[ -n "$SIM" ]] || SIM="$(xcrun simctl create "Design review" "$DEVICE_TYPE" "$RUNTIME")"
xcrun simctl bootstatus "$SIM" -b >/dev/null
echo "design_screenshots: simulator $SIM runtime=$RUNTIME"

export_shots() {
  local bundle label tmp
  for bundle in "$RESULTS"/*.xcresult; do
    [[ -e "$bundle" ]] || continue
    label="$(basename "$bundle" .xcresult)"
    tmp="$ATTEMPT/tmp-$label"
    rm -rf "$tmp"
    xcrun xcresulttool export attachments --path "$bundle" --output-path "$tmp" >/dev/null 2>&1 || continue
    python3 -I - "$tmp" "$SHOTS" <<'PY'
import json, pathlib, shutil, sys
tmp, shots = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
manifest = tmp / "manifest.json"
if manifest.exists():
    for test in json.loads(manifest.read_text()):
        for a in test["attachments"]:
            name = a["suggestedHumanReadableName"].split("_")[0]
            shutil.copy(tmp / a["exportedFileName"], shots / f"{name}.png")
PY
    rm -rf "$tmp"
  done
  echo "design_screenshots: screenshots in $SHOTS"
  ls "$SHOTS"
}
trap export_shots EXIT

cd "$ROOT"
xcodebuild build-for-testing -project Epistoli.xcodeproj -scheme EpistoliScreenshots \
  -destination "id=$SIM" -derivedDataPath "$BUILD" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= -quiet
APP="$BUILD/Build/Products/Debug-iphonesimulator/Epistoli.app"

clean_install() {
  xcrun simctl terminate "$SIM" "$APP_ID" 2>/dev/null || true
  xcrun simctl uninstall "$SIM" "$APP_ID" 2>/dev/null || true
  xcrun simctl uninstall "$SIM" "$RUNNER_ID" 2>/dev/null || true
  xcrun simctl keychain "$SIM" reset
  xcrun simctl install "$SIM" "$APP"
  xcrun simctl launch "$SIM" "$APP_ID" >/dev/null
  sleep "$WARMUP_SECONDS"
  xcrun simctl terminate "$SIM" "$APP_ID" 2>/dev/null || true
}

attempt_test() {  # attempt_test <bundle-label> <bg>
  local label="$1" bg="$2"
  env TEST_RUNNER_BG="$bg" TEST_RUNNER_USER_NAME="Eleni" \
    TEST_RUNNER_CODE_A="$CODE_A" TEST_RUNNER_CODE_B="$CODE_B" TEST_RUNNER_CODE_B2="$CODE_B2" \
    xcodebuild test-without-building -project Epistoli.xcodeproj -scheme EpistoliScreenshots \
    -destination "id=$SIM" -derivedDataPath "$BUILD" -resultBundlePath "$RESULTS/$label.xcresult" \
    -only-testing "EpistoliUITests/DesignScreenshots/testDesignTour" -quiet >"$LOGS/$label.log" 2>&1 || return 1
  # -only-testing a test that isn't in the build runs nothing and still succeeds.
  local ran
  ran="$(xcrun xcresulttool get test-results summary --path "$RESULTS/$label.xcresult" \
    | python3 -I -c 'import json, sys; print(json.load(sys.stdin).get("passedTests", 0))')"
  [[ "$ran" -ge 1 ]] || { echo "design_screenshots: $label ran no tests" | tee -a "$LOGS/$label.log"; return 1; }
}

startup_error() {
  local label="$1"
  { cat "$LOGS/$label.log"
    xcrun xcresulttool get test-results summary --path "$RESULTS/$label.xcresult" 2>/dev/null || true
  } | grep -Eq "$STARTUP_ERRORS"
}

for bg in "${BACKGROUNDS[@]}"; do
  echo "design_screenshots: $bg"
  clean_install
  if attempt_test "$bg" "$bg"; then continue; fi
  label="$bg"
  if startup_error "$bg"; then
    echo "design_screenshots: $bg hit a simulator start-up error; retrying once"
    clean_install
    if attempt_test "$bg-retry" "$bg"; then continue; fi
    label="$bg-retry"
  fi
  echo "design_screenshots: $label FAILED; log: $LOGS/$label.log"
  tail -20 "$LOGS/$label.log"
  exit 1
done
echo "design_screenshots: all backgrounds passed"

# White text must reach 4.5:1 on every screen. Skipped, because the white there isn't app text:
#   04-scan        the system Paste button (grey, its own styling; left as the system draws it)
#   11-appearance  the white selection ring around the chosen swatch (the labels below it are checked)
export_shots
trap - EXIT
swift "$ROOT/scripts/contrast_check.swift" \
  --skip "04-scan:40,1990,330,200" --skip "11-appearance:90,640,1030,170" \
  "$SHOTS"/*.png | tee "$ATTEMPT/contrast.txt"
