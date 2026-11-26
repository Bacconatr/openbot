#!/usr/bin/env bash
# Puts a home-screen widget on fresh iPhone simulators and screenshots it, one simulator per size.
#
#   shots.sh --search TEXT --out DIR [--sizes small,medium,large] [--app PATH.app]
#            [--page-by-index] [--launch-wait SECONDS] [--device NAME]
#
# With --app it installs the app on a base simulator, launches it once so it can publish widget
# data, and checks its App Group. Each size then gets a clone of that simulator, so every
# screenshot shows exactly one widget. --page-by-index adds gallery page 0, 1 or 2 for small, medium
# or large instead of reading the preview size (right for an app with one widget).
set -euo pipefail

search="" out="" sizes="small,medium,large" app="" page_by_index="" launch_wait=15 device="iPhone 18 Pro"
bundle_id="run.openbot.mobile" app_group="group.run.openbot.mobile"
while (($#)); do
  case "$1" in
    --search) search=$2; shift ;;
    --out) out=$2; shift ;;
    --sizes) sizes=$2; shift ;;
    --app) app=$2; shift ;;
    --page-by-index) page_by_index=1 ;;
    --launch-wait) launch_wait=$2; shift ;;
    --device) device=$2; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
[[ -n $search && -n $out ]] || { echo "--search and --out are required" >&2; exit 2; }

here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$out"/{screens,steps,logs,results}
out=$(cd "$out" && pwd)
summary="$out/summary.md"
log() { printf '[shots %s] %s\n' "$(date +%T)" "$*"; }
note() { printf '%s\n' "$*" >> "$summary"; log "$*"; }
timed() { local start=$SECONDS; "$@"; log "took $((SECONDS - start)) s: $*"; }

note "## Widget lab: \`$search\`"
note ""
note "- Xcode: $(xcodebuild -version | tr '\n' ' ')"

read -r runtime device_type < <(xcrun simctl list -j runtimes | python3 -c '
import json, sys
want = sys.argv[1]
ios = [r for r in json.load(sys.stdin)["runtimes"] if r.get("platform") == "iOS" and r.get("isAvailable")]
ios.sort(key=lambda r: [int(p) for p in r["version"].split(".")])
runtime = ios[-1]
types = runtime.get("supportedDeviceTypes", [])
match = [t for t in types if t["name"] == want] or [t for t in types if t.get("productFamily") == "iPhone"]
print(runtime["identifier"], match[0]["identifier"])
' "$device")
[[ -n ${device_type:-} ]] || { echo "found no iOS simulator runtime with an iPhone" >&2; exit 1; }
note "- Simulator: $device_type on $runtime"

# The driver: a UI test that drives SpringBoard. Built once, run once per size.
driver_dd="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/widget-driver-dd"
(cd "$here/driver" && xcodegen generate --quiet)
timed xcodebuild build-for-testing -project "$here/driver/WidgetDriver.xcodeproj" -scheme WidgetDriver \
  -destination "generic/platform=iOS Simulator" -derivedDataPath "$driver_dd" -quiet \
  > "$out/logs/driver-build.log" 2>&1 || { tail -40 "$out/logs/driver-build.log"; exit 1; }

boot() {
  xcrun simctl boot "$1"
  xcrun simctl bootstatus "$1" -b > /dev/null
}

base=$(xcrun simctl create widget-lab-base "$device_type" "$runtime")
timed boot "$base"

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
    (cd "$group" && find . -type f | sort) > "$out/logs/app-group-files.txt" 2>&1 || true
    note "- App Group files after launch: $(wc -l < "$out/logs/app-group-files.txt" | tr -d ' ') (logs/app-group-files.txt)"
  fi
  xcrun simctl terminate "$base" "$bundle_id" || true
fi
xcrun simctl shutdown "$base"

status=0
IFS=, read -ra size_list <<< "$sizes"
for index in "${!size_list[@]}"; do
  size=${size_list[$index]}
  sim=$(xcrun simctl clone "$base" "widget-lab-$size")
  timed boot "$sim"
  xcrun simctl ui "$sim" appearance light
  xcrun simctl status_bar "$sim" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100
  sleep 10
  page=""
  if [[ -n $page_by_index ]]; then
    case $size in small) page=0 ;; medium) page=1 ;; large) page=2 ;; esac
  fi
  start=$SECONDS
  if TEST_RUNNER_WIDGET_SEARCH="$search" TEST_RUNNER_WIDGET_SIZE="$size" TEST_RUNNER_WIDGET_PAGE="$page" \
    TEST_RUNNER_LAB_OUT_DIR="$out/steps" TEST_RUNNER_LAB_LABEL="$size" \
    xcodebuild test-without-building -project "$here/driver/WidgetDriver.xcodeproj" -scheme WidgetDriver \
      -derivedDataPath "$driver_dd" -destination "id=$sim" \
      -only-testing:WidgetDriverUITests/WidgetDriver/testAddWidget \
      -test-timeouts-enabled YES -maximum-test-execution-time-allowance 300 \
      -resultBundlePath "$out/results/$size.xcresult" > "$out/logs/driver-$size.log" 2>&1; then
    result="added"
  else
    result="**driver failed**"
    status=1
    grep -E '\[widget-driver\]|error:|failed' "$out/logs/driver-$size.log" | tail -25 || true
  fi
  if ! ls "$out/steps/$size"-* > /dev/null 2>&1; then
    xcrun xcresulttool export attachments --path "$out/results/$size.xcresult" \
      --output-path "$out/steps/$size-attachments" > /dev/null 2>&1 || true
  fi
  # The runner and its host app put icons on the page; remove them before the screenshots.
  xcrun simctl uninstall "$sim" lab.widgetdriver.uitests.xctrunner || true
  xcrun simctl uninstall "$sim" lab.widgetdriver.host || true
  sleep 3
  for appearance in light dark; do
    xcrun simctl ui "$sim" appearance "$appearance"
    sleep 5
    xcrun simctl io "$sim" screenshot "$out/screens/$size-$appearance.png" > /dev/null
  done
  note "- $size: $result in $((SECONDS - start)) s; screens/$size-light.png, screens/$size-dark.png"
  xcrun simctl shutdown "$sim"
  xcrun simctl delete "$sim"
done
exit $status
