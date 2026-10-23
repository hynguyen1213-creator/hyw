#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/screenshots
xcodebuild -project GLens.xcodeproj -scheme GLens -configuration Debug -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath build/simulator CODE_SIGNING_ALLOWED=NO build > build/simulator.log 2>&1
xcrun simctl list --json > build/simulators.json
readarray_compat() { :; }
runtime_id="$(python3 -c 'import json; d=json.load(open("build/simulators.json")); print([r["identifier"] for r in d["runtimes"] if r.get("isAvailable") and "iOS" in r["name"]][-1])')"
device_type="$(python3 -c 'import json; d=json.load(open("build/simulators.json")); a=[r["identifier"] for r in d["devicetypes"] if "iPhone" in r["name"]]; print(next((v for v in a if v.endswith("iPhone-17-Pro")),a[-1]))')"
sim_id="$(xcrun simctl create G-LENS-QA "$device_type" "$runtime_id")"
trap 'xcrun simctl shutdown "$sim_id" >/dev/null 2>&1 || true; xcrun simctl delete "$sim_id" >/dev/null 2>&1 || true' EXIT
xcrun simctl boot "$sim_id"
xcrun simctl bootstatus "$sim_id" -b
xcrun simctl status_bar "$sim_id" override --time '09:41' --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
xcrun simctl install "$sim_id" build/simulator/Build/Products/Debug-iphonesimulator/GLens.app
for surface in camera pro-controls pro-settings; do
  xcrun simctl launch --terminate-running-process "$sim_id" com.gstudio.glens --ui-smoke "--$surface"
  sleep 4
  xcrun simctl io "$sim_id" screenshot "build/screenshots/$surface.png"
done
