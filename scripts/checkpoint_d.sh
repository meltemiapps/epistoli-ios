#!/usr/bin/env bash
# checkpoint_d.sh: two simulators chatting over the loopback transport, with screenshots.
#
# Maria (simulator A, Aegean) and Nikos (simulator B, Sunset) exchange codes as text, as in
# checkpoint_c.sh, then the UI tests take turns: a message and a photo each way, PGP off and on,
# Maria's "new phone" and the key-change banner in Nikos's chat with her, and a group.
# Both apps get the same folder with -loopback.root, so envelopes and blobs written by one appear in
# the other's mailbox. The folder is <attempt>/loopback, kept with the screenshots for inspection.
#
# Usage: scripts/checkpoint_d.sh <output-dir>
# Same simulator handling as checkpoint_c.sh: "Checkpoint A" and "Checkpoint B" are booted once and
# never erased; each attempt uninstalls, resets the simulator keychain and reinstalls, and writes to
# its own folder, <output-dir>/attempts/<timestamp>/. Earlier attempts are never deleted.
# A step is retried once only for the two simulator start-up errors below; anything else stops the run.
set -euo pipefail

OUT="${1:?usage: scripts/checkpoint_d.sh <output-dir>}"
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
LOOP="$ATTEMPT/loopback"
mkdir -p "$RESULTS" "$SHOTS" "$LOGS" "$LOOP"
echo "checkpoint_d: attempt folder $ATTEMPT"

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
echo "checkpoint_d: A=$A B=$B runtime=$RUNTIME"

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
  echo "checkpoint_d: screenshots in $SHOTS"
  ls "$SHOTS"
}
trap export_shots EXIT

cd "$ROOT"
xcodegen generate --quiet   # picks up new test files
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
echo "checkpoint_d: warm-up ${WARMUP_SECONDS}s"
sleep "$WARMUP_SECONDS"
for d in "$A" "$B"; do xcrun simctl terminate "$d" "$APP_ID" 2>/dev/null || true; done

attempt_test() {  # attempt_test <udid> <bundle-label> <test> [VAR=value ...]
  local udid="$1" label="$2" test="$3"; shift 3
  local vars=()
  for kv in "$@"; do vars+=("TEST_RUNNER_$kv"); done
  env ${vars[@]+"${vars[@]}"} xcodebuild test-without-building -project Epistoli.xcodeproj -scheme EpistoliScreenshots \
    -destination "id=$udid" -derivedDataPath "$BUILD" -resultBundlePath "$RESULTS/$label.xcresult" \
    -only-testing "EpistoliUITests/ChatDemo/$test" -quiet >"$LOGS/$label.log" 2>&1 || return 1
  # -only-testing a test that isn't in the build runs nothing and still succeeds.
  local ran
  ran="$(xcrun xcresulttool get test-results summary --path "$RESULTS/$label.xcresult" \
    | python3 -I -c 'import json, sys; print(json.load(sys.stdin).get("passedTests", 0))')"
  [[ "$ran" -ge 1 ]] || { echo "checkpoint_d: $label ran no tests" | tee -a "$LOGS/$label.log"; return 1; }
}

startup_error() {  # startup_error <bundle-label>: true if the run failed with a simulator start-up error
  local label="$1"
  { cat "$LOGS/$label.log"
    xcrun xcresulttool get test-results summary --path "$RESULTS/$label.xcresult" 2>/dev/null || true
  } | grep -Eq "$STARTUP_ERRORS"
}

run() {  # run <udid> <label> <test> [VAR=value ...]
  local udid="$1" label="$2" test="$3"; shift 3
  echo "checkpoint_d: $label ($test)"
  if attempt_test "$udid" "$label" "$test" "$@"; then return 0; fi
  if startup_error "$label"; then
    echo "checkpoint_d: $label hit a simulator start-up error; retrying once"
    if attempt_test "$udid" "$label-retry" "$test" "$@"; then return 0; fi
    label="$label-retry"
  fi
  echo "checkpoint_d: $label FAILED; log: $LOGS/$label.log"
  tail -20 "$LOGS/$label.log"
  return 1
}

A_ENV=("LOOPBACK_ROOT=$LOOP" "BG=aegean")
B_ENV=("LOOPBACK_ROOT=$LOOP" "BG=sunset")

run "$A" a01-onboard test1_Onboard "${A_ENV[@]}" "USER_NAME=Maria"
CODE_A="$(xcrun simctl pbpaste "$A")"
run "$B" b01-onboard test1_Onboard "${B_ENV[@]}" "USER_NAME=Nikos"
CODE_B="$(xcrun simctl pbpaste "$B")"
printf '%s' "$CODE_A" > "$ATTEMPT/code-maria.txt"
printf '%s' "$CODE_B" > "$ATTEMPT/code-nikos.txt"
run "$B" b02-add-maria test2_AddContact "${B_ENV[@]}" "PEER_CODE=$CODE_A" "TAG=b02"
run "$A" a02-add-nikos test2_AddContact "${A_ENV[@]}" "PEER_CODE=$CODE_B" "TAG=a02"

run "$A" a03-send test3_SendTextAndPhoto "${A_ENV[@]}" "PEER=Nikos" "TEXT=Kalispera! Did the beach photos arrive?" "TAG=a03"
run "$B" b03-reply test4_ReceiveAndReply "${B_ENV[@]}" "PEER=Maria" "EXPECT=Did the beach photos arrive?" "TEXT=Yes, all of them. Sending my favourite." "TAG=b03"
run "$A" a04-photo test5_ReceiveAndOpenPhoto "${A_ENV[@]}" "PEER=Nikos" "EXPECT=Sending my favourite." "TAG=a04"
# Quick Look stays open at the end of a04; this step starts from a fresh launch.
run "$A" a04b-pgp-off test5b_PGPOff "${A_ENV[@]}" "PEER=Nikos" "TEXT=PGP is off for this one." "TAG=a04b"
run "$B" b04-pgp-on test6_SeePGPOffThenOn "${B_ENV[@]}" "PEER=Maria" "EXPECT=PGP is off for this one." "TAG=b04"

run "$A" a05-new-phone test7_SimulateNewPhone "${A_ENV[@]}" "TAG=a05"
CODE_A2="$(xcrun simctl pbpaste "$A")"
printf '%s' "$CODE_A2" > "$ATTEMPT/code-maria-new-phone.txt"
run "$B" b05-accept-new-key test2_AddContact "${B_ENV[@]}" "PEER_CODE=$CODE_A2" "TAG=b05"
run "$B" b06-keychange-chat test8_KeyChangeInChat "${B_ENV[@]}" "PEER=Maria" "TEXT=Is this your new phone?" "TAG=b06"
run "$A" a06-new-phone-receives test9_ReceiveOnNewPhone "${A_ENV[@]}" "PEER=Nikos" "EXPECT=Is this your new phone?" "TAG=a06"

run "$A" a07-group test10_CreateGroup "${A_ENV[@]}" "PEER=Nikos" "GROUP=Family" "TEXT=Dinner on Sunday at 8?" "TAG=a07"
run "$B" b07-group test11_SeeGroup "${B_ENV[@]}" "GROUP=Family" "EXPECT=Dinner on Sunday at 8?" "TAG=b07"
echo "checkpoint_d: all steps passed"
