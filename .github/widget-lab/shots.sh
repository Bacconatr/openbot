#!/usr/bin/env bash
# Puts a home-screen widget on fresh iPhone simulators, screenshots it and films it.
#
#   shots.sh --search TEXT --out DIR --phases P[,P...] [--app PATH.app] [--launch-wait SECONDS]
#            [--device NAME]
#
# Phases, each on its own clone of a base simulator:
#   small, medium, large  add that size, shoot it light, dark and on a Tinted Home Screen.
#                         large also films the gallery; medium also taps a row (app only).
#   live                  films the medium widget re-sorting when an agent starts waiting (app only).
#   lock                  adds the accessory widgets on the Lock Screen and films it.
#   combo                 small and medium on one page, for a still.
# With --app it installs the app on the base simulator and launches it once so it publishes.
set -uo pipefail

search="" out="" phases="small,medium,large" app="" launch_wait=15 device="iPhone 18 Pro"
bundle_id="run.openbot.mobile" app_group="group.run.openbot.mobile"
tap_row="Finance bot" tap_agent="lab-fin"
while (($#)); do
  case "$1" in
    --search) search=$2; shift ;;
    --out) out=$2; shift ;;
    --phases) phases=$2; shift ;;
    --app) app=$2; shift ;;
    --launch-wait) launch_wait=$2; shift ;;
    --device) device=$2; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
[[ -n $search && -n $out ]] || { echo "--search and --out are required" >&2; exit 2; }

here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$out"/{screens,clips,steps,logs,results}
out=$(cd "$out" && pwd)
summary="$out/summary.md"
status=0
log() { printf '[shots %s] %s\n' "$(date +%T)" "$*"; }
note() { printf '%s\n' "$*" >> "$summary"; log "$*"; }
fail() { note "- **FAILED** $*"; status=1; }
now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

note "## Widget lab: \`$search\`, phases \`$phases\`"
note ""
note "- Xcode: $(xcodebuild -version | tr '\n' ' ')"

read -r runtime device_type < <(xcrun simctl list -j runtimes | python3 -c '
import json, sys
want = sys.argv[1]
ios = [r for r in json.load(sys.stdin)["runtimes"] if r.get("platform") == "iOS" and r.get("isAvailable")]
# The newest runtime that runs the wanted device. A device-specific runtime of the same version
# (iOS-27-2-iPhone19-4, iPhone Duo only) is also listed; an unfiltered pick got it once.
ios = [r for r in ios if any(t["name"] == want for t in r.get("supportedDeviceTypes", []))]
ios.sort(key=lambda r: [int(p) for p in r["version"].split(".")])
runtime = ios[-1]
match = [t for t in runtime["supportedDeviceTypes"] if t["name"] == want]
print(runtime["identifier"], match[0]["identifier"])
' "$device")
[[ -n ${device_type:-} ]] || { echo "found no iOS simulator runtime with an iPhone" >&2; exit 1; }
note "- Simulator: $device_type on $runtime"

# The driver: a UI test that drives SpringBoard. Built once, run once per scene.
driver_dd="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/widget-driver-dd"
(cd "$here/driver" && xcodegen generate --quiet)
xcodebuild build-for-testing -project "$here/driver/WidgetDriver.xcodeproj" -scheme WidgetDriver \
  -destination "generic/platform=iOS Simulator" -derivedDataPath "$driver_dd" -quiet \
  > "$out/logs/driver-build.log" 2>&1 || { tail -40 "$out/logs/driver-build.log"; exit 1; }

boot() {
  xcrun simctl boot "$1"
  xcrun simctl bootstatus "$1" -b > /dev/null
}

is_booted() { xcrun simctl list devices | grep "$1" | grep -q Booted; }

# drive SIM LABEL TEST [NAME=VALUE...]: runs one driver test; the runner and its host leave after.
drive() {
  local sim=$1 label=$2 test=$3 start=$SECONDS
  shift 3
  local -a vars=()
  for pair in "$@"; do vars+=("TEST_RUNNER_$pair"); done
  log "driver $test ($label)"
  if env ${vars[@]+"${vars[@]}"} TEST_RUNNER_WIDGET_SEARCH="$search" TEST_RUNNER_LAB_OUT_DIR="$out/steps" \
    TEST_RUNNER_LAB_LABEL="$label" \
    xcodebuild test-without-building -project "$here/driver/WidgetDriver.xcodeproj" -scheme WidgetDriver \
      -derivedDataPath "$driver_dd" -destination "id=$sim" \
      -only-testing:"WidgetDriverUITests/WidgetDriver/$test" \
      -test-timeouts-enabled YES -maximum-test-execution-time-allowance 420 -parallel-testing-enabled NO \
      -resultBundlePath "$out/results/$label.xcresult" > "$out/logs/driver-$label.log" 2>&1; then
    local ok=0
  else
    local ok=1
    grep -E '\[widget-driver\]|error:|failed' "$out/logs/driver-$label.log" | tail -25 || true
  fi
  if ! ls "$out/steps/$label"-* > /dev/null 2>&1; then
    xcrun xcresulttool export attachments --path "$out/results/$label.xcresult" \
      --output-path "$out/steps/$label-attachments" > /dev/null 2>&1 || true
  fi
  # A failed test run has left the simulator shut down (measured in run 45874010586).
  if ! is_booted "$sim"; then
    log "the simulator was shut down after the driver; booting it again"
    boot "$sim"
  fi
  xcrun simctl uninstall "$sim" lab.widgetdriver.uitests.xctrunner > /dev/null 2>&1 || true
  xcrun simctl uninstall "$sim" lab.widgetdriver.host > /dev/null 2>&1 || true
  sleep 3
  log "driver $test ($label) exit $ok in $((SECONDS - start)) s"
  return $ok
}

fresh_sim() {
  local sim
  sim=$(xcrun simctl clone "$base" "widget-lab-$1")
  {
    boot "$sim"
    xcrun simctl ui "$sim" appearance light
    xcrun simctl status_bar "$sim" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
      --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
    sleep 10
  } >&2
  echo "$sim"
}

done_sim() {
  xcrun simctl shutdown "$1" > /dev/null 2>&1 || true
  xcrun simctl delete "$1" > /dev/null 2>&1 || true
}

shoot() {
  xcrun simctl io "$1" screenshot "$out/screens/$2.png" > /dev/null || fail "screenshot $2"
}

shoot_both() {
  local sim=$1 name=$2
  for appearance in light dark; do
    xcrun simctl ui "$sim" appearance "$appearance" || true
    sleep 5
    shoot "$sim" "$name-$appearance"
  done
  xcrun simctl ui "$sim" appearance light || true
  sleep 3
}

rec_pid=""
rec_start() {
  rm -f "$out/clips/$2.mp4"
  xcrun simctl io "$1" recordVideo --codec=h264 --force "$out/clips/$2.mp4" > "$out/logs/rec-$2.log" 2>&1 &
  rec_pid=$!
  rec_started=$(now_ms)
  sleep 2
  log "recording $2 since $rec_started"
}

rec_stop() {
  [[ -n $rec_pid ]] || return 0
  kill -INT "$rec_pid" 2> /dev/null || true
  wait "$rec_pid" 2> /dev/null || true
  rec_pid=""
  [[ -s "$out/clips/$1.mp4" ]] || fail "clip $1 is empty (logs/rec-$1.log)"
}

app_data() { xcrun simctl get_app_container "$1" "$bundle_id" data; }

# --- the base simulator ---------------------------------------------------------------

base=$(xcrun simctl create widget-lab-base "$device_type" "$runtime")
boot "$base"

if [[ -n $app ]]; then
  xcrun simctl install "$base" "$app"
  if group=$(xcrun simctl get_app_container "$base" "$bundle_id" "$app_group" 2>/dev/null); then
    note "- App Group \`$app_group\` container after install: \`$group\`"
  else
    group=""
    note "- App Group \`$app_group\`: **no container after install** (the app's entitlements did not reach the simulator)"
  fi
  xcrun simctl launch "$base" "$bundle_id" > "$out/logs/launch.txt"
  log "waiting $launch_wait s for the app to publish its widget data"
  sleep "$launch_wait"
  xcrun simctl io "$base" screenshot "$out/screens/app-after-launch.png" > /dev/null
  xcrun simctl spawn "$base" log show --last 3m --style compact \
    --predicate 'process == "OpenBot" OR process == "ExpoWidgetsTarget"' > "$out/logs/app-log.txt" 2>&1 || true
  if [[ -n $group ]]; then
    xcrun simctl spawn "$base" defaults read "$group/Library/Preferences/$app_group" \
      > "$out/logs/app-group-defaults.txt" 2>&1 || true
    keys=$(grep -o '"\{0,1\}__expo_widgets_[A-Za-z0-9_]*' "$out/logs/app-group-defaults.txt" | tr -d '"' | sort -u | tr '\n' ' ' || true)
    note "- App Group defaults after launch: ${keys:-no __expo_widgets_ keys}"
  fi
  data=$(app_data "$base")
  note "- Fixture files after launch: $(cd "$data/Documents" 2>/dev/null && ls widget-lab-* 2>/dev/null | tr '\n' ' ')"
  cat "$data/Documents/widget-lab-published.txt" > "$out/logs/base-published.txt" 2>/dev/null || true
  xcrun simctl terminate "$base" "$bundle_id" || true
fi

# New apps go to the App Library only, so the driver's runner never puts an icon in a shot or clip.
if drive "$base" base testNewAppsToAppLibrary; then
  note "- New apps go to the App Library only"
else
  note "- Could not set new apps to the App Library only; the runner's icon may show while it runs"
fi
xcrun simctl shutdown "$base"

# --- phases ---------------------------------------------------------------------------

phase_size() {
  local size=$1 sim start=$SECONDS
  sim=$(fresh_sim "$size")
  [[ $size == large ]] && rec_start "$sim" gallery
  local added=1
  drive "$sim" "$size" testAddWidget "WIDGET_SIZE=$size" "PAGE_HOLD=$([[ $size == large ]] && echo 4 || echo 1)" || added=0
  [[ $size == large ]] && { sleep 2; rec_stop gallery; note "- clips/gallery.mp4: adding the $size widget from the gallery; driver timeline steps/$size-driver.log, recording began at $rec_started ms"; }
  if ((added == 0)); then
    fail "$size: the driver could not add the widget"
    shoot "$sim" "$size-failed"
    done_sim "$sim"
    return
  fi
  shoot_both "$sim" "$size"
  note "- $size: added in $((SECONDS - start)) s; screens/$size-light.png, screens/$size-dark.png"

  if [[ $size == medium && -n $app ]]; then
    local data
    data=$(app_data "$sim")
    rm -f "$data/Documents/widget-lab-links.txt"
    rec_start "$sim" tap
    if drive "$sim" tap testTapRow "WIDGET_ROW=$tap_row" "APP_BUNDLE=$bundle_id"; then
      sleep 2
      rec_stop tap
      shoot "$sim" tap-opened
      sleep 4
      local links
      links=$(cat "$data/Documents/widget-lab-links.txt" 2>/dev/null || true)
      cp "$data/Documents/widget-lab-links.txt" "$out/logs/tap-links.txt" 2>/dev/null || true
      if grep -q "agent=$tap_agent" <<< "$links"; then
        note "- tap: tapping '$tap_row' brought OpenBot to the foreground opened with \`$(grep "agent=$tap_agent" <<< "$links" | head -1 | cut -d' ' -f2-)\`; screens/tap-opened.png, clips/tap.mp4"
      else
        fail "tap: OpenBot came to the foreground but recorded no link for agent=$tap_agent (links: ${links:-none})"
      fi
    else
      rec_stop tap
      fail "tap: the driver could not tap '$tap_row' into OpenBot"
    fi
    xcrun simctl terminate "$sim" "$bundle_id" > /dev/null 2>&1 || true
    sleep 3
  fi

  if drive "$sim" "$size-tint" testTintHomeScreen; then
    shoot_both "$sim" "$size-tinted"
    note "- $size tinted: screens/$size-tinted-light.png, screens/$size-tinted-dark.png"
  else
    fail "$size: could not set the Home Screen to Tinted"
  fi
  done_sim "$sim"
}

phase_live() {
  local sim data published after
  sim=$(fresh_sim live)
  if ! drive "$sim" live testAddWidget WIDGET_SIZE=medium; then
    fail "live: the driver could not add the medium widget"
    done_sim "$sim"
    return
  fi
  data=$(app_data "$sim")
  echo live > "$data/Documents/widget-lab-scene.txt"
  rm -f "$data/Documents/widget-lab-published.txt"
  xcrun simctl launch "$sim" "$bundle_id" > /dev/null
  for _ in $(seq 60); do
    [[ -s "$data/Documents/widget-lab-published.txt" ]] && break
    sleep 1
  done
  published=$(cat "$data/Documents/widget-lab-published.txt" 2>/dev/null || true)
  if [[ $published != live* ]]; then
    fail "live: the app did not publish the live scene (published: ${published:-nothing})"
    done_sim "$sim"
    return
  fi
  after=$(cut -d' ' -f3 <<< "$published")
  log "live scene published: $published"
  sleep 3
  xcrun simctl terminate "$sim" "$bundle_id" > /dev/null 2>&1 || true
  sleep 3
  shoot "$sim" live-before
  rec_start "$sim" live
  while (($(now_ms) < after + 5000)); do sleep 1; done
  rec_stop live
  shoot "$sim" live-after
  rm -f "$data/Documents/widget-lab-scene.txt"
  if cmp -s "$out/screens/live-before.png" "$out/screens/live-after.png"; then
    fail "live: the Home Screen did not change between live-before.png and live-after.png"
  else
    note "- live: re-sort due $((after - rec_started)) ms into clips/live.mp4; screens/live-before.png, screens/live-after.png differ"
  fi
  done_sim "$sim"
}

phase_lock() {
  local sim
  sim=$(fresh_sim lock)
  rec_start "$sim" lock-customize
  local ok=1
  drive "$sim" lock testLockScreenWidgets || ok=0
  sleep 2
  rec_stop lock-customize
  shoot "$sim" lock-after-driver
  if ((ok)); then
    rec_start "$sim" lock
    sleep 4
    rec_stop lock
    shoot_both "$sim" lock
    note "- lock: Lock Screen widgets; screens/lock-light.png, screens/lock-dark.png, clips/lock.mp4, clips/lock-customize.mp4"
  else
    fail "lock: the driver could not finish the Lock Screen editor (steps/lock-*, clips/lock-customize.mp4)"
  fi
  done_sim "$sim"
}

phase_combo() {
  local sim
  sim=$(fresh_sim combo)
  if drive "$sim" combo-small testAddWidget WIDGET_SIZE=small && drive "$sim" combo-medium testAddWidget WIDGET_SIZE=medium; then
    shoot_both "$sim" combo
    note "- combo: small and medium on one page; screens/combo-light.png, screens/combo-dark.png"
  else
    fail "combo: could not add both widgets"
  fi
  done_sim "$sim"
}

IFS=, read -ra phase_list <<< "$phases"
for phase in "${phase_list[@]}"; do
  log "=== phase $phase"
  case "$phase" in
    small | medium | large) phase_size "$phase" ;;
    live) phase_live ;;
    lock) phase_lock ;;
    combo) phase_combo ;;
    *) fail "unknown phase $phase" ;;
  esac
done
exit $status
