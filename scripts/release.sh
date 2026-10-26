#!/bin/bash
set -euo pipefail
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="$ROOT/build/direct"
BUILD_SETTINGS=()
if [[ "${YUZU_QA_RELEASE:-0}" == 1 ]]; then
  OUT="$ROOT/build/update-qa"
  BUILD_SETTINGS=(MARKETING_VERSION=0.1.3 CURRENT_PROJECT_VERSION=5)
fi
TOOLS="$ROOT/build/sparkle/2.10.0"
mkdir -p "$OUT" "$TOOLS"
if [[ ! -x "$TOOLS/bin/generate_appcast" ]]; then
  curl --fail --location https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz --output "$TOOLS/Sparkle.tar.xz"
  printf '%s  %s\n' c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c "$TOOLS/Sparkle.tar.xz" | shasum -a 256 --check
  tar -xJf "$TOOLS/Sparkle.tar.xz" -C "$TOOLS"
  rm "$TOOLS/Sparkle.tar.xz"
fi
xcodegen generate
xcodebuild -project YuzuNTFS.xcodeproj -scheme YuzuNTFS -configuration Release-Direct -destination 'generic/platform=macOS' -derivedDataPath "$OUT/DerivedData" -archivePath "$OUT/YuzuNTFS.xcarchive" archive ${BUILD_SETTINGS[@]+"${BUILD_SETTINGS[@]}"}
APP="$OUT/YuzuNTFS.xcarchive/Products/Applications/Yuzu NTFS.app"
"$ROOT/scripts/verify-release.sh" "$APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$OUT/YuzuNTFS-$VERSION-beta.dmg"
STAGE="$(mktemp -d "$OUT/stage.XXXXXX")"
FEED="$(mktemp -d "$OUT/feed.XXXXXX")"
trap 'rm -rf "$STAGE" "$FEED"' EXIT
ditto "$APP" "$STAGE/Yuzu NTFS.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname 'Yuzu NTFS beta' -srcfolder "$STAGE" -format UDZO -ov "$DMG"
codesign --force --sign 'Developer ID Application: Nguyen Le (37PX6W22C5)' --timestamp "$DMG"
xcrun notarytool submit "$DMG" --key "$HOME/.appstoreconnect/private_keys/AuthKey_5Y9N24UTB9.p8" --key-id 5Y9N24UTB9 --issuer e8671c23-6675-4e90-84ff-ce9e70887b9a --wait --output-format json > "$OUT/notarization.json"
python3 - "$OUT/notarization.json" <<'PY'
import json, sys
result=json.load(open(sys.argv[1]))
print(result)
assert result['status']=='Accepted', result
PY
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG"
cp "$DMG" "$FEED/"
"$TOOLS/bin/generate_appcast" --account yuzu-ntfs --download-url-prefix https://yuzu.today/ntfs/download/ --maximum-deltas 0 --release-notes-url-prefix https://github.com/bluecoral-vn/yuzu-ntfs/releases/tag/v --link "https://github.com/bluecoral-vn/yuzu-ntfs/releases/tag/v$VERSION-beta" -o "$OUT/appcast.xml" "$FEED"
if [[ "${YUZU_QA_RELEASE:-0}" != 1 ]]; then
  OFFICIAL=/Users/rom/Projects/yuzu-apps/Official
  mkdir -p "$OFFICIAL"
  cp "$DMG" "$OFFICIAL/"
  find "$OFFICIAL" -maxdepth 1 -name 'YuzuNTFS-*-beta.dmg' ! -name "$(basename "$DMG")" -delete
fi
shasum -a 256 "$DMG"

python3 - "$OUT/appcast.xml" "$VERSION" <<'PY'
import sys, xml.etree.ElementTree as ET
namespace='http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', namespace)
tree=ET.parse(sys.argv[1])
for item in tree.findall('./channel/item'):
    if item.findtext('{'+namespace+'}shortVersionString') != sys.argv[2]:
        continue
    tag='{'+namespace+'}releaseNotesLink'
    notes=item.find(tag)
    if notes is None:
        notes=ET.SubElement(item, tag)
    notes.text='https://github.com/bluecoral-vn/yuzu-ntfs/releases/tag/v'+sys.argv[2]+'-beta'
tree.write(sys.argv[1], encoding='utf-8', xml_declaration=True)
PY