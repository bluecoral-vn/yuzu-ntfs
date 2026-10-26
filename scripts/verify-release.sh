#!/bin/bash
set -euo pipefail
APP="$1"
PLIST="$APP/Contents/Info.plist"
# Check architecture before signatures so a thinned or incomplete bundle fails
# with the offending binary, even when modifying it also invalidated signing.
python3 - "$APP" <<'PY'
import pathlib, subprocess, sys
app = pathlib.Path(sys.argv[1])
if not app.is_dir():
    sys.exit(f'App bundle not found: {app}')
mach_o_count = 0
for binary in sorted(app.rglob('*')):
    if binary.is_symlink() or not binary.is_file():
        continue
    kind = subprocess.check_output(['/usr/bin/file', '-b', str(binary)], text=True)
    if 'Mach-O' not in kind:
        continue
    mach_o_count += 1
    result = subprocess.run(['/usr/bin/lipo', '-archs', str(binary)], text=True, capture_output=True)
    if result.returncode or not {'arm64', 'x86_64'}.issubset(result.stdout.split()):
        sys.exit(f'Universal architecture check failed: {binary} (architectures: {result.stdout.strip() or result.stderr.strip() or "unknown"}; required: arm64 x86_64)')
if not mach_o_count:
    sys.exit(f'Universal architecture check failed: no Mach-O binaries in {app}')
print(f'Universal architecture check passed: {mach_o_count} Mach-O binaries contain arm64 and x86_64')
PY
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
