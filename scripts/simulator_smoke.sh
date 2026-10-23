#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/screenshots
xcodebuild -project GLens.xcodeproj -scheme GLens -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath build/simulator ONLY_ACTIVE_ARCH=YES "ARCHS=$(uname -m)" CODE_SIGNING_ALLOWED=NO build 2>&1 | tee build/simulator.log
xcrun simctl list --json > build/simulators.json
runtime_id="$(python3 -c 'import json; d=json.load(open("build/simulators.json")); print([r["identifier"] for r in d["runtimes"] if r.get("isAvailable") and "iOS" in r["name"]][-1])')"
device_type="$(python3 -c 'import json; d=json.load(open("build/simulators.json")); a=[r["identifier"] for r in d["devicetypes"] if "iPhone" in r["name"]]; print(next((v for v in a if v.endswith("iPhone-17-Pro")),a[-1]))')"
sim_id="$(xcrun simctl create G-LENS-QA "$device_type" "$runtime_id")"
trap 'xcrun simctl shutdown "$sim_id" >/dev/null 2>&1 || true; xcrun simctl delete "$sim_id" >/dev/null 2>&1 || true' EXIT
xcrun simctl boot "$sim_id"
xcrun simctl bootstatus "$sim_id" -b
xcrun simctl status_bar "$sim_id" override --time '09:41' --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
xcrun simctl install "$sim_id" build/simulator/Build/Products/Debug-iphonesimulator/GLens.app
for surface in camera pro-controls pro-settings night-settings pano lux-quick film-looks mode-picker; do
  xcrun simctl launch --terminate-running-process "$sim_id" com.gstudio.glens --ui-smoke "--$surface"
  sleep 4
  xcrun simctl io "$sim_id" screenshot "build/screenshots/$surface.png"
done

xcrun simctl launch --terminate-running-process "$sim_id" com.gstudio.glens --ui-smoke --self-check
container_path="$(xcrun simctl get_app_container "$sim_id" com.gstudio.glens data)"
for attempt in $(seq 1 120); do
  if [ -f "$container_path/Documents/SimulatorChecks.json" ]; then break; fi
  sleep 1
done
cp "$container_path/Documents/SimulatorChecks.json" build/SimulatorChecks.json
python3 - <<'CHECK'
import json
r=json.load(open('build/SimulatorChecks.json'))
print(json.dumps(r,ensure_ascii=False,indent=2))
assert r['passed'], 'Native image/video pipeline checks failed'
CHECK
