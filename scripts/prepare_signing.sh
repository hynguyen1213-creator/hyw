#!/bin/bash
# Run only on an ephemeral macOS CI runner. Actual secrets stay in Actions Secrets.
set -euo pipefail
: "${RUNNER_TEMP:?Run this script inside a GitHub macOS runner}"
: "${GITHUB_ENV:?Run this script inside GitHub Actions}"
: "${IOS_P12_BASE64:?Missing IOS_P12_BASE64 Actions secret}"
: "${IOS_P12_PASSWORD:?Missing IOS_P12_PASSWORD Actions secret}"
: "${IOS_PROFILE_BASE64:?Missing IOS_PROFILE_BASE64 Actions secret}"
signing_dir="$RUNNER_TEMP/glens-signing"
mkdir -p "$signing_dir"
chmod 700 "$signing_dir"
export GLENS_SIGNING_DIR="$signing_dir"
python3 - <<'PY'
import os,base64
from pathlib import Path
p=Path(os.environ['GLENS_SIGNING_DIR'])
for key,name in [('IOS_P12_BASE64','certificate.p12'),('IOS_PROFILE_BASE64','profile.mobileprovision')]:
    raw=base64.b64decode(''.join(os.environ[key].split()),validate=True)
    if not raw:raise SystemExit(f'{key} is empty')
    target=p/name;target.write_bytes(raw);target.chmod(0o600)
PY
security cms -D -i "$signing_dir/profile.mobileprovision" > "$signing_dir/profile.plist"
xcodebuild -help > "$signing_dir/xcode-help.txt" 2>&1 || true
python3 - <<'PY'
import os,plistlib,datetime,fnmatch,re
from pathlib import Path
p=Path(os.environ['GLENS_SIGNING_DIR'])
profile=plistlib.loads((p/'profile.plist').read_bytes())
team=profile['TeamIdentifier'][0];uuid=profile['UUID']
if not re.fullmatch(r'[A-Z0-9]{10}',team) or not re.fullmatch(r'[A-Fa-f0-9-]{36}',uuid):raise SystemExit('Invalid signing metadata')
expiry=profile['ExpirationDate'].replace(tzinfo=datetime.timezone.utc)
if expiry<=datetime.datetime.now(datetime.timezone.utc):raise SystemExit('Provisioning profile has expired')
bundle=os.environ.get('IOS_BUNDLE_ID','com.gstudio.glens')
ent=profile['Entitlements'];allowed=ent['application-identifier'].split('.',1)[1]
if not fnmatch.fnmatchcase(bundle,allowed):raise SystemExit('Profile App ID does not match IOS_BUNDLE_ID')
if not profile.get('ProvisionedDevices') and not profile.get('ProvisionsAllDevices'):raise SystemExit('An App Store-only profile cannot install directly. Use registered-device distribution.')
help_text=(p/'xcode-help.txt').read_text()
development=bool(ent.get('get-task-allow',False))
identity='Apple Development' if development else 'Apple Distribution'
if profile.get('ProvisionsAllDevices'):method='enterprise'
elif development:method='debugging' if 'debugging' in help_text else 'development'
else:method='release-testing' if 'release-testing' in help_text else 'ad-hoc'
options={'method':method,'signingStyle':'manual','teamID':team,'signingCertificate':identity,'provisioningProfiles':{bundle:uuid},'manageAppVersionAndBuildNumber':False}
(p/'ExportOptions.plist').write_bytes(plistlib.dumps(options))
profiles=Path.home()/'Library/MobileDevice/Provisioning Profiles';profiles.mkdir(parents=True,exist_ok=True)
(profiles/f'{uuid}.mobileprovision').write_bytes((p/'profile.mobileprovision').read_bytes())
with open(os.environ['GITHUB_ENV'],'a') as f:
    for key,value in {'IOS_TEAM_ID':team,'IOS_PROFILE_UUID':uuid,'IOS_CODE_SIGN_IDENTITY':identity,'EXPORT_OPTIONS_PLIST':str(p/'ExportOptions.plist')}.items():f.write(f'{key}={value}\n')
PY
keychain_path="$signing_dir/build.keychain-db"
keychain_password="$(openssl rand -hex 24)"
security create-keychain -p "$keychain_password" "$keychain_path"
security set-keychain-settings -lut 21600 "$keychain_path"
security unlock-keychain -p "$keychain_password" "$keychain_path"
security import "$signing_dir/certificate.p12" -P "$IOS_P12_PASSWORD" -A -t cert -f pkcs12 -k "$keychain_path" >/dev/null
security set-key-partition-list -S apple-tool:,apple: -k "$keychain_password" "$keychain_path" >/dev/null
security list-keychain -d user -s "$keychain_path" login.keychain-db
# No private certificate, profile, password or decoded secret is printed or uploaded.
