#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export LC_ALL=en_US.UTF-8
scripts/fetch-ntfsprogs.sh
SOURCE="$ROOT/vendor/ntfs-3g_ntfsprogs-2022.10.3"
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -Wno-deprecated-declarations \
    -I "$SOURCE" -I "$SOURCE/include/ntfs-3g" \
    tools/fixturegen/main.c "$SOURCE/libntfs-3g/.libs/libntfs-3g.a" \
    -framework CoreFoundation -o tools/bin/fixturegen
mkdir -p fixtures
# Changes to authoring code invalidate the cache. Checksums also reject images
# modified by driver tests or VM chkdsk; never reuse such images as ground truth.
SIGNATURE="$(shasum -a 256 scripts/make-fixtures.sh scripts/fetch-ntfsprogs.sh tools/fixturegen/main.c | shasum -a 256 | cut -d ' ' -f 1)"
STAMP="fixtures/.generated-$SIGNATURE"
if [[ -f "$STAMP" && -f fixtures/.checksums.sha256 ]] && \
    shasum -a 256 -c fixtures/.checksums.sha256; then
    echo "Fixture corpus unchanged; reusing verified images"
    scripts/check-fixtures.py
    exit 0
fi
TEMP_IMAGE=""
TEMP_MANIFEST=""
trap 'rm -f "$TEMP_IMAGE" "$TEMP_MANIFEST"' EXIT
make_image() {
    local name="$1" size="$2" sector="$3" cluster="$4" mode="$5"
    TEMP_IMAGE="fixtures/$name.img.incomplete"
    TEMP_MANIFEST="fixtures/$name.manifest.json.incomplete"
    rm -f "$TEMP_IMAGE" "$TEMP_MANIFEST"
    mkfile -n "$size" "$TEMP_IMAGE"
    tools/bin/mkntfs -F -Q -s "$sector" -c "$cluster" -L "Yuzu-$name" "$TEMP_IMAGE"
    tools/bin/fixturegen "$mode" "$TEMP_IMAGE" "$TEMP_MANIFEST"
    tools/bin/ntfsinfo -m "$TEMP_IMAGE"
    mv "$TEMP_IMAGE" "fixtures/$name.img"
    mv "$TEMP_MANIFEST" "fixtures/$name.manifest.json"
}
make_image basic-512 256m 512 4096 basic
make_image 4kn 256m 4096 4096 basic
make_image c64k 256m 512 65536 basic
# Author directly with libntfs-3g: no FUSE mount and no Windows VM required.
make_image bigdir 512m 512 4096 bigdir
make_image names 256m 512 4096 names
scripts/check-fixtures.py
shasum -a 256 fixtures/*.img fixtures/*.manifest.json > fixtures/.checksums.sha256
touch "$STAMP"
echo "Five offline NTFS fixtures and manifests ready"
