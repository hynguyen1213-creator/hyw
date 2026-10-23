#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo 'Cần macOS và Xcode để kiểm tra build iOS.' >&2
  exit 1
fi
xcodebuild -project GLens.xcodeproj -scheme GLens -configuration Debug \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/GLensDerivedData CODE_SIGNING_ALLOWED=NO build
