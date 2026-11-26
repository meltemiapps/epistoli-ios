#!/usr/bin/env bash
# checkpoint_c.sh: QR key exchange on two simulators, with screenshots.
#
# The simulator has no camera, so codes travel as text: the UI test taps "Copy code as text" on one
# simulator, this script reads that simulator's pasteboard (simctl pbpaste) and the UI test on the
# other simulator types it into "Or paste a code". Pasted codes add contacts as Unverified.
#
# Usage: scripts/checkpoint_c.sh <output-dir>
# Creates (or reuses) two simulators named "Checkpoint A" and "Checkpoint B" and ERASES them first.
set -euo pipefail

OUT="${1:?usage: scripts/checkpoint_c.sh <output-dir>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
RUNTIME="$(xcrun simctl list runtimes -j | python3 -I -c '
import json, sys
rs = [r for r in json.load(sys.stdin)["runtimes"] if r["platform"] == "iOS" and r["isAvailable"]]
print(sorted(rs, key=lambda r: [int(x) for x in r["version"].split(".")])[-1]["identifier"])')"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
BUILD="$OUT/build"
RESULTS="$OUT/results"
rm -rf "$RESULTS"; mkdir -p "$RESULTS"

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
  xcrun simctl shutdown "$d" 2>/dev/null || true
  xcrun simctl erase "$d"
  xcrun simctl boot "$d"
done
xcrun simctl bootstatus "$A" -b >/dev/null
xcrun simctl bootstatus "$B" -b >/dev/null
echo "checkpoint_c: A=$A B=$B runtime=$RUNTIME"

cd "$ROOT"
xcodebuild build-for-testing -project Epistoli.xcodeproj -scheme EpistoliScreenshots \
  -destination "id=$A" -derivedDataPath "$BUILD" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= -quiet

run() {  # run <udid> <label> <test> [VAR=value ...]
  local udid="$1" label="$2" test="$3"; shift 3
  local vars=()
  for kv in "$@"; do vars+=("TEST_RUNNER_$kv"); done
  echo "checkpoint_c: $label ($test)"
  env "${vars[@]}" xcodebuild test-without-building -project Epistoli.xcodeproj -scheme EpistoliScreenshots \
    -destination "id=$udid" -derivedDataPath "$BUILD" -resultBundlePath "$RESULTS/$label.xcresult" \
    -only-testing "EpistoliUITests/CheckpointScreenshots/$test" -quiet
}

run "$A" a1-onboard test1_OnboardAndShowMyCode "USER_NAME=Maria"
CODE_A="$(xcrun simctl pbpaste "$A")"
run "$B" b1-onboard test1_OnboardAndShowMyCode "USER_NAME=Nikos"
CODE_B="$(xcrun simctl pbpaste "$B")"
printf '%s' "$CODE_A" > "$OUT/code-maria.txt"
printf '%s' "$CODE_B" > "$OUT/code-nikos.txt"

run "$B" b2-add-maria test2_PasteCode "PEER_CODE=$CODE_A" "SHOT_TAG=b-add-maria"
run "$A" a2-add-nikos test2_PasteCode "PEER_CODE=$CODE_B" "SHOT_TAG=a-add-nikos"

run "$A" a3-new-phone test3_SimulateNewPhoneAndShowCode
CODE_A2="$(xcrun simctl pbpaste "$A")"
printf '%s' "$CODE_A2" > "$OUT/code-maria-new-phone.txt"
run "$B" b3-key-change test2_PasteCode "PEER_CODE=$CODE_A2" "SHOT_TAG=b-keychange"

run "$B" b4-acknowledgements test4_Acknowledgements
run "$A" a4-own-code test5_OwnCodeRefused "OWN_CODE=$CODE_A2"

# Export the screenshots, named <run>-<shot>.png.
SHOTS="$OUT/screenshots"
rm -rf "$SHOTS"; mkdir -p "$SHOTS"
for bundle in "$RESULTS"/*.xcresult; do
  label="$(basename "$bundle" .xcresult)"
  tmp="$OUT/tmp-$label"
  rm -rf "$tmp"
  xcrun xcresulttool export attachments --path "$bundle" --output-path "$tmp" >/dev/null
  python3 -I - "$tmp" "$SHOTS" "$label" <<'PY'
import json, pathlib, shutil, sys
tmp, shots, label = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
for test in json.loads((tmp / "manifest.json").read_text()):
    for a in test["attachments"]:
        name = a["suggestedHumanReadableName"].split("_")[0]
        shutil.copy(tmp / a["exportedFileName"], shots / f"{label}--{name}.png")
PY
  rm -rf "$tmp"
done
ls "$SHOTS"
