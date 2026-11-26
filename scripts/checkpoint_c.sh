#!/usr/bin/env bash
# checkpoint_c.sh: QR key exchange on two simulators, with screenshots.
#
# The simulator has no camera, so codes travel as text: the UI test taps "Copy code as text" on one
# simulator, this script reads that simulator's pasteboard (simctl pbpaste) and the UI test on the
# other simulator types it into "Or paste a code". Pasted codes add contacts as Unverified.
#
# Usage: scripts/checkpoint_c.sh <output-dir>
# Creates (or reuses) two simulators named "Checkpoint A" and "Checkpoint B". They are booted once and
# never erased; each attempt starts clean by uninstalling the app, resetting the simulator keychain
# (keychain items survive an uninstall) and reinstalling. Each attempt writes to its own folder,
# <output-dir>/attempts/<timestamp>/, and earlier attempts are never deleted.
set -euo pipefail

OUT="${1:?usage: scripts/checkpoint_c.sh <output-dir>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
APP_ID="com.meltemiapps.epistoli"
RUNNER_ID="com.meltemiapps.epistoli.uitests.xctrunner"
WARMUP_SECONDS=20
# The only failures that get one retry: simulator start-up errors, before the test touches the app.
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
echo "checkpoint_c: attempt folder $ATTEMPT"

sim() {  # sim <name>: UDID of the named simulator, creating it if needed
  local udid
  udid="$(xcrun simctl list devices -j | python3 -I -c '
import json, sys
name = sys.argv[1]
for devs in json.load(sys.stdin)["devices"].values():
    for d in devs:
        if d["name"] == name and d["isAvailable"]:
            print(d["udid"]); sys.exit()' "$1")"
  [[ -n "$udid" ]] || udid="$(xcrun simctl create "$1" "$DEVICE_TYPE" "$RUNTIME")"
  echo "$udid"
}

A="$(sim "Checkpoint A")"
B="$(sim "Checkpoint B")"
for d in "$A" "$B"; do
  xcrun simctl bootstatus "$d" -b >/dev/null   # boots it if needed, waits until ready
done
echo "checkpoint_c: A=$A B=$B runtime=$RUNTIME"

# Export whatever screenshots exist, even when a step fails, named <run>--<shot>.png.
export_shots() {
  local bundle label tmp
  for bundle in "$RESULTS"/*.xcresult; do
    [[ -e "$bundle" ]] || continue
    label="$(basename "$bundle" .xcresult)"
    tmp="$ATTEMPT/tmp-$label"
    rm -rf "$tmp"
    xcrun xcresulttool export attachments --path "$bundle" --output-path "$tmp" >/dev/null 2>&1 || continue
    python3 -I - "$tmp" "$SHOTS" "$label" <<'PY'
import json, pathlib, shutil, sys
tmp, shots, label = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
manifest = tmp / "manifest.json"
if manifest.exists():
    for test in json.loads(manifest.read_text()):
        for a in test["attachments"]:
            name = a["suggestedHumanReadableName"].split("_")[0]
            shutil.copy(tmp / a["exportedFileName"], shots / f"{label}--{name}.png")
PY
    rm -rf "$tmp"
  done
  echo "checkpoint_c: screenshots in $SHOTS"
  ls "$SHOTS"
}
trap export_shots EXIT

cd "$ROOT"
xcodebuild build-for-testing -project Epistoli.xcodeproj -scheme EpistoliScreenshots \
  -destination "id=$A" -derivedDataPath "$BUILD" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= -quiet
APP="$BUILD/Build/Products/Debug-iphonesimulator/Epistoli.app"

# Clean state: uninstall, reset keychain, reinstall, then launch once and wait so the first UI test
# doesn't meet a cold simulator.
for d in "$A" "$B"; do
  xcrun simctl terminate "$d" "$APP_ID" 2>/dev/null || true
  xcrun simctl uninstall "$d" "$APP_ID" 2>/dev/null || true
  xcrun simctl uninstall "$d" "$RUNNER_ID" 2>/dev/null || true
  xcrun simctl keychain "$d" reset
  xcrun simctl install "$d" "$APP"
  xcrun simctl launch "$d" "$APP_ID" >/dev/null
done
echo "checkpoint_c: warm-up ${WARMUP_SECONDS}s"
sleep "$WARMUP_SECONDS"
for d in "$A" "$B"; do xcrun simctl terminate "$d" "$APP_ID" 2>/dev/null || true; done

attempt_test() {  # attempt_test <udid> <bundle-label> <test> [VAR=value ...]
  local udid="$1" label="$2" test="$3"; shift 3
  local vars=()
  for kv in "$@"; do vars+=("TEST_RUNNER_$kv"); done
  env ${vars[@]+"${vars[@]}"} xcodebuild test-without-building -project Epistoli.xcodeproj -scheme EpistoliScreenshots \
    -destination "id=$udid" -derivedDataPath "$BUILD" -resultBundlePath "$RESULTS/$label.xcresult" \
    -only-testing "EpistoliUITests/CheckpointScreenshots/$test" -quiet >"$LOGS/$label.log" 2>&1
}

startup_error() {  # startup_error <bundle-label>: true if the run failed with a simulator start-up error
  local label="$1"
  { cat "$LOGS/$label.log"
    xcrun xcresulttool get test-results summary --path "$RESULTS/$label.xcresult" 2>/dev/null || true
  } | grep -Eq "$STARTUP_ERRORS"
}

run() {  # run <udid> <label> <test> [VAR=value ...]
  local udid="$1" label="$2" test="$3"; shift 3
  echo "checkpoint_c: $label ($test)"
  if attempt_test "$udid" "$label" "$test" "$@"; then return 0; fi
  if startup_error "$label"; then
    echo "checkpoint_c: $label hit a simulator start-up error; retrying once"
    if attempt_test "$udid" "$label-retry" "$test" "$@"; then return 0; fi
    label="$label-retry"
  fi
  echo "checkpoint_c: $label FAILED; log: $LOGS/$label.log"
  tail -20 "$LOGS/$label.log"
  return 1
}

run "$A" a1-onboard test1_OnboardAndShowMyCode "USER_NAME=Maria"
CODE_A="$(xcrun simctl pbpaste "$A")"
run "$B" b1-onboard test1_OnboardAndShowMyCode "USER_NAME=Nikos"
CODE_B="$(xcrun simctl pbpaste "$B")"
printf '%s' "$CODE_A" > "$ATTEMPT/code-maria.txt"
printf '%s' "$CODE_B" > "$ATTEMPT/code-nikos.txt"

run "$B" b2-add-maria test2_PasteCode "PEER_CODE=$CODE_A" "SHOT_TAG=b-add-maria"
run "$A" a2-add-nikos test2_PasteCode "PEER_CODE=$CODE_B" "SHOT_TAG=a-add-nikos"

run "$A" a3-new-phone test3_SimulateNewPhoneAndShowCode
CODE_A2="$(xcrun simctl pbpaste "$A")"
printf '%s' "$CODE_A2" > "$ATTEMPT/code-maria-new-phone.txt"
run "$B" b3-key-change test2_PasteCode "PEER_CODE=$CODE_A2" "SHOT_TAG=b-keychange"

run "$B" b4-acknowledgements test4_Acknowledgements
run "$A" a4-own-code test5_OwnCodeRefused "OWN_CODE=$CODE_A2"
echo "checkpoint_c: all steps passed"
