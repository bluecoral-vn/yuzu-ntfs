#!/bin/bash
set -euo pipefail
APP="$1"
PLIST="$APP/Contents/Info.plist"
codesign --verify --strict --verbose=2 "$APP"
test -d "$APP/Contents/Frameworks/Sparkle.framework"
if find "$APP/Contents/Extensions" -name Sparkle.framework | /usr/bin/grep -q .; then echo 'Sparkle embedded in FSKit extension' >&2; exit 1; fi
test "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$PLIST")" = https://yuzu.today/ntfs/appcast.xml
test "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST")" = Xn34tDBWHQSFOu1+/uRuDEU9VSr3eLlCzgR6q8su8tc=
python3 - "$APP" <<'PY'
import pathlib, plistlib, subprocess, sys
app = pathlib.Path(sys.argv[1])
modules = list(app.glob('Contents/Extensions/*.appex'))
assert len(modules) == 1, 'Exactly one FSKit module must be embedded'
for bundle in [app, *modules]:
    subprocess.run(['codesign', '--verify', '--strict', str(bundle)], check=True)
    if bundle != app:
        info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
        linked = subprocess.check_output(['otool', '-L', str(bundle / 'Contents/MacOS' / info['CFBundleExecutable'])], text=True)
        assert 'Sparkle' not in linked, 'FSKit module must not link Sparkle'
    result = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(bundle)], check=True, capture_output=True)
    data = result.stdout
    if data:
        entitlements = plistlib.loads(data)
        if any('get-task-allow' in key for key in entitlements):
            sys.exit(f'get-task-allow present: {bundle}')
PY
