#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-unsigned}"
if [[ "$mode" != unsigned && "$mode" != signed ]]; then
  echo 'Usage: bash scripts/build_ipa.sh unsigned|signed' >&2; exit 2
fi
if [[ "$(uname -s)" != Darwin ]] || ! command -v xcodebuild >/dev/null 2>&1; then
  echo 'A real iOS IPA needs macOS + Xcode + the iPhoneOS SDK. This script does not fabricate an IPA from source.' >&2
  exit 2
fi
xcrun --sdk iphoneos --find swiftc >/dev/null
xcodebuild -version
artifact_dir="$PWD/build"
archive_path="$artifact_dir/GLens.xcarchive"
mkdir -p "$artifact_dir"
bundle_id="${IOS_BUNDLE_ID:-com.gstudio.glens}"
build_args=(-project GLens.xcodeproj -scheme GLens -configuration Release -destination 'generic/platform=iOS' -archivePath "$archive_path" "PRODUCT_BUNDLE_IDENTIFIER=$bundle_id" ONLY_ACTIVE_ARCH=NO)
if [[ "$mode" == signed ]]; then
  : "${IOS_TEAM_ID:?Signing preparation must set IOS_TEAM_ID}"
  : "${IOS_PROFILE_UUID:?Signing preparation must set IOS_PROFILE_UUID}"
  : "${IOS_CODE_SIGN_IDENTITY:?Signing preparation must set IOS_CODE_SIGN_IDENTITY}"
  : "${EXPORT_OPTIONS_PLIST:?Signing preparation must set EXPORT_OPTIONS_PLIST}"
  test -f "$EXPORT_OPTIONS_PLIST"
  build_args+=(CODE_SIGN_STYLE=Manual "DEVELOPMENT_TEAM=$IOS_TEAM_ID" "PROVISIONING_PROFILE_SPECIFIER=$IOS_PROFILE_UUID" "CODE_SIGN_IDENTITY=$IOS_CODE_SIGN_IDENTITY")
else
  build_args+=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
fi
xcodebuild "${build_args[@]}" archive 2>&1 | tee "$artifact_dir/archive.log"
app_path="$archive_path/Products/Applications/GLens.app"
test -d "$app_path"
executable_name="$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$app_path/Info.plist")"
test -s "$app_path/$executable_name"
file "$app_path/$executable_name" | tee "$artifact_dir/executable.txt"
file "$app_path/$executable_name" | /usr/bin/grep -q 'Mach-O'
/usr/libexec/PlistBuddy -c 'Print NSCameraUsageDescription' "$app_path/Info.plist" >/dev/null
if [[ "$mode" == signed ]]; then
  xcodebuild -exportArchive -archivePath "$archive_path" -exportOptionsPlist "$EXPORT_OPTIONS_PLIST" -exportPath "$artifact_dir/export" 2>&1 | tee "$artifact_dir/export.log"
  exported_ipa="$(find "$artifact_dir/export" -maxdepth 1 -name '*.ipa' -type f -print -quit)"
  test -n "$exported_ipa"
  ipa_path="$artifact_dir/G_LENS_v0.2_SIGNED.ipa"
  cp "$exported_ipa" "$ipa_path"
  verify_dir="$(mktemp -d "${TMPDIR:-/tmp}/glens-verify.XXXXXX")"
  trap 'rm -rf "$verify_dir"' EXIT
  ditto -xk "$ipa_path" "$verify_dir"
  codesign --verify --deep --strict "$verify_dir/Payload/GLens.app"
  test -f "$verify_dir/Payload/GLens.app/embedded.mobileprovision"
  echo 'Signed IPA exported and code signature verified. Device installation still requires a matching valid profile.'
else
  payload_dir="$(mktemp -d "${TMPDIR:-/tmp}/glens-payload.XXXXXX")"
  trap 'rm -rf "$payload_dir"' EXIT
  mkdir -p "$payload_dir/Payload"
  ditto "$app_path" "$payload_dir/Payload/GLens.app"
  ipa_path="$artifact_dir/G_LENS_v0.2_UNSIGNED_REQUIRES_SIGNING.ipa"
  (cd "$payload_dir" && /usr/bin/zip -qyr "$ipa_path" Payload)
  echo 'Unsigned IPA built from a real Mach-O application. It requires signing and is not directly installable.'
fi
/usr/bin/unzip -tq "$ipa_path"
shasum -a 256 "$ipa_path" > "$ipa_path.sha256"
printf 'IPA output: %s\n' "$ipa_path"
